import AVFoundation
import CryptoKit
import Foundation
import ImageIO
import UIKit

// Disk work and image decoding run away from the main actor. These are disposable
// JPEG previews; no operation in this actor writes to the original media files.
private actor MediaThumbnailDiskCache {
    private let directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("WorkCameraThumbnails/v1", isDirectory: true)

    private func hash(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private func itemDirectory(_ item: MediaItem) -> URL {
        directory.appendingPathComponent(hash(item.url.absoluteString), isDirectory: true)
    }

    private func thumbnailURL(_ item: MediaItem) -> URL? {
        guard let values = try? item.url.resourceValues(forKeys: [
            .creationDateKey, .contentModificationDateKey, .fileSizeKey
        ]), let modifiedAt = values.contentModificationDate, let size = values.fileSize else { return nil }
        let fingerprint = "\(values.creationDate?.timeIntervalSinceReferenceDate.bitPattern ?? 0):\(modifiedAt.timeIntervalSinceReferenceDate.bitPattern):\(size)"
        return itemDirectory(item).appendingPathComponent(hash(fingerprint) + ".jpg")
    }

    private func readImage(at url: URL) -> UIImage? {
        guard FileManager.default.fileExists(atPath: url.path),
              let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, [
                kCGImageSourceShouldCacheImmediately: true
              ] as CFDictionary) else { return nil }
        return UIImage(cgImage: image)
    }

    func image(for item: MediaItem) async -> UIImage? {
        guard !Task.isCancelled, let destination = thumbnailURL(item) else { return nil }
        if let image = readImage(at: destination) { return image }

        let image: UIImage?
        if item.kind == .photo {
            if let source = CGImageSourceCreateWithURL(item.url as CFURL, nil),
               let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceThumbnailMaxPixelSize: 256
               ] as CFDictionary) {
                image = UIImage(cgImage: thumbnail)
            } else {
                image = nil
            }
        } else {
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: item.url))
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 256, height: 256)
            if let result = try? await generator.image(at: .zero) {
                image = UIImage(cgImage: result.image)
            } else {
                image = nil
            }
        }

        // A source may be edited or deleted while a video frame is being generated.
        guard !Task.isCancelled, thumbnailURL(item) == destination else { return nil }
        if let data = image?.jpegData(compressionQuality: 0.85) {
            do {
                let folder = destination.deletingLastPathComponent()
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                try data.write(to: destination, options: .atomic)
                // Keep only the preview matching the current source revision.
                for old in (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
                    where old != destination {
                    try? FileManager.default.removeItem(at: old)
                }
            } catch {
                // A preview write failure must not fail a successful photo/video save.
            }
        }
        return image
    }

    func prepare(_ items: [MediaItem]) async {
        await withTaskGroup(of: Void.self) { group in
            var iterator = items.makeIterator()
            for _ in 0..<4 {
                guard !Task.isCancelled, let item = iterator.next() else { break }
                group.addTask { await self.prepare(item) }
            }
            for await _ in group {
                if !Task.isCancelled, let item = iterator.next() {
                    group.addTask { await self.prepare(item) }
                }
            }
        }
    }

    private func prepare(_ item: MediaItem) async {
        guard !Task.isCancelled, let url = thumbnailURL(item),
              !FileManager.default.fileExists(atPath: url.path) else { return }
        _ = await image(for: item)
    }

    func removeUnused(for items: [MediaItem]) {
        guard !Task.isCancelled else { return }
        let active = Set(items.map { hash($0.url.absoluteString) })
        let folders = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        for folder in folders where !active.contains(folder.lastPathComponent) {
            try? FileManager.default.removeItem(at: folder)
        }
    }
}

@MainActor
final class MediaThumbnailCache {
    // Immutable image results are shared by loading tasks and SwiftUI views.
    final class Entry: @unchecked Sendable {
        let item: MediaItem
        let image: UIImage?

        init(item: MediaItem, image: UIImage?) {
            self.item = item
            self.image = image
        }
    }

    static let shared = MediaThumbnailCache()
    private let memoryThumbnailLimit = 80
    private let preloadThumbnailCount = 40
    private let images = NSCache<NSURL, Entry>()
    private let disk = MediaThumbnailDiskCache()
    private var pending: [MediaItem: Task<Entry, Never>] = [:]
    private var reconciledItems: [MediaItem]?
    private var currentItems: [URL: MediaItem] = [:]
    private var preparationTask: Task<Void, Never>?

    private init() {
        images.countLimit = memoryThumbnailLimit
        images.totalCostLimit = 32 * 1024 * 1024
    }

    func cached(for item: MediaItem) -> Entry? {
        guard let entry = images.object(forKey: item.url as NSURL), entry.item == item else { return nil }
        return entry
    }

    func reconcile(items: [MediaItem]) {
        guard reconciledItems != items else { return }
        let activeItems = Set(items)
        for old in reconciledItems ?? [] where !activeItems.contains(old) {
            images.removeObject(forKey: old.url as NSURL)
        }
        reconciledItems = items
        currentItems = Dictionary(uniqueKeysWithValues: items.map { ($0.url, $0) })
        preparationTask?.cancel()
        preparationTask = Task(priority: .utility) {
            // Warm the first screen in RAM; build the remaining previews on disk
            // without evicting those first-screen images from the memory cache.
            _ = await loadBatch(Array(items.prefix(preloadThumbnailCount)))
            guard !Task.isCancelled else { return }
            await disk.removeUnused(for: items)
            guard !Task.isCancelled else { return }
            await disk.prepare(Array(items.dropFirst(preloadThumbnailCount)))
        }
    }

    func load(_ item: MediaItem) async -> Entry {
        if let entry = cached(for: item) { return entry }
        if let task = pending[item] { return await task.value }
        let task = Task { Entry(item: item, image: await disk.image(for: item)) }
        pending[item] = task
        let entry = await task.value
        pending[item] = nil
        // Do not resurrect a deleted capture or publish a stale edit's result.
        guard reconciledItems == nil || currentItems[item.url] == item else {
            return Entry(item: item, image: nil)
        }
        let cost: Int
        if let image = entry.image?.cgImage {
            cost = image.bytesPerRow * image.height
        } else {
            cost = 1
        }
        images.setObject(entry, forKey: item.url as NSURL, cost: cost)
        return entry
    }

    func loadBatch(_ items: [MediaItem]) async -> [MediaItem: Entry] {
        await withTaskGroup(of: Entry.self) { group in
            var iterator = items.makeIterator()
            var result: [MediaItem: Entry] = [:]
            for _ in 0..<4 {
                guard !Task.isCancelled, let item = iterator.next() else { break }
                group.addTask { await self.load(item) }
            }
            for await entry in group {
                result[entry.item] = entry
                if !Task.isCancelled, let item = iterator.next() {
                    group.addTask { await self.load(item) }
                }
            }
            return result
        }
    }
}
