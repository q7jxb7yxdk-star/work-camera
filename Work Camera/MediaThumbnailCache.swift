import AVFoundation
import CryptoKit
import Foundation
import ImageIO
import UIKit

enum MediaThumbnailSize: Hashable, Sendable {
    case grid
    case collection(Int)

    nonisolated var pixelSize: Int {
        switch self {
        case .grid: 256
        case .collection(let pixels): pixels
        }
    }
}

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

    private func thumbnailURL(_ item: MediaItem, size thumbnailSize: MediaThumbnailSize = .grid) -> URL? {
        guard let values = try? item.url.resourceValues(forKeys: [
            .creationDateKey, .contentModificationDateKey, .fileSizeKey
        ]), let modifiedAt = values.contentModificationDate, let size = values.fileSize else { return nil }
        let fingerprint = "\(values.creationDate?.timeIntervalSinceReferenceDate.bitPattern ?? 0):\(modifiedAt.timeIntervalSinceReferenceDate.bitPattern):\(size)"
        let folder: URL
        switch thumbnailSize {
        case .grid: folder = itemDirectory(item)
        case .collection(let pixels):
            folder = itemDirectory(item).appendingPathComponent("collection-\(pixels)", isDirectory: true)
        }
        return folder.appendingPathComponent(hash(fingerprint) + ".jpg")
    }

    // Square covers need enough pixels on the short edge before aspect-fill cropping.
    private func maximumSize(sourceSize: CGSize, thumbnailSize: MediaThumbnailSize) -> CGSize {
        let pixels = CGFloat(thumbnailSize.pixelSize)
        guard case .collection = thumbnailSize,
              sourceSize.width > 0, sourceSize.height > 0 else {
            return CGSize(width: pixels, height: pixels)
        }
        let scale = min(1, pixels / min(sourceSize.width, sourceSize.height))
        return CGSize(width: sourceSize.width * scale, height: sourceSize.height * scale)
    }

    private func coverImage(_ image: UIImage?, size: MediaThumbnailSize) -> UIImage? {
        guard case .collection = size, let source = image?.cgImage else { return image }
        let edge = min(source.width, source.height)
        let rect = CGRect(x: CGFloat((source.width - edge) / 2), y: CGFloat((source.height - edge) / 2),
                          width: CGFloat(edge), height: CGFloat(edge))
        guard let cropped = source.cropping(to: rect) else { return image }
        return UIImage(cgImage: cropped)
    }

    private func readImage(at url: URL) -> UIImage? {
        guard FileManager.default.fileExists(atPath: url.path),
              let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, [
                kCGImageSourceShouldCacheImmediately: true
              ] as CFDictionary) else { return nil }
        return UIImage(cgImage: image)
    }

    func image(for item: MediaItem, size: MediaThumbnailSize = .grid) async -> UIImage? {
        guard !Task.isCancelled, let destination = thumbnailURL(item, size: size) else { return nil }
        if let image = readImage(at: destination) { return image }

        let image: UIImage?
        if item.kind == .photo {
            if let source = CGImageSourceCreateWithURL(item.url as CFURL, nil) {
                let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
                let width = (properties?[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue ?? 0
                let height = (properties?[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue ?? 0
                let target = maximumSize(sourceSize: CGSize(width: width, height: height), thumbnailSize: size)
                let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceShouldCacheImmediately: true,
                    kCGImageSourceThumbnailMaxPixelSize: Int(ceil(max(target.width, target.height)))
                ] as CFDictionary)
                image = thumbnail.map { UIImage(cgImage: $0) }
            } else {
                image = nil
            }
        } else {
            let asset = AVURLAsset(url: item.url)
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            var sourceSize = CGSize.zero
            if case .collection = size,
               let tracks = try? await asset.loadTracks(withMediaType: .video),
               let track = tracks.first,
               let naturalSize = try? await track.load(.naturalSize),
               let transform = try? await track.load(.preferredTransform) {
                let transformed = naturalSize.applying(transform)
                sourceSize = CGSize(width: abs(transformed.width), height: abs(transformed.height))
            }
            generator.maximumSize = maximumSize(sourceSize: sourceSize, thumbnailSize: size)
            if let result = try? await generator.image(at: .zero) {
                image = UIImage(cgImage: result.image)
            } else {
                image = nil
            }
        }

        // A source may be edited or deleted while a video frame is being generated.
        guard !Task.isCancelled, thumbnailURL(item, size: size) == destination else { return nil }
        let preview = coverImage(image, size: size)
        if let data = preview?.jpegData(compressionQuality: 0.85) {
            do {
                let folder = destination.deletingLastPathComponent()
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                try data.write(to: destination, options: .atomic)
                // Keep only the preview matching the current source revision.
                for old in (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
                    where old != destination && old.pathExtension == "jpg" {
                    try? FileManager.default.removeItem(at: old)
                }
            } catch {
                // A preview write failure must not fail a successful photo/video save.
            }
        }
        return preview
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
        let size: MediaThumbnailSize

        init(item: MediaItem, image: UIImage?, size: MediaThumbnailSize = .grid) {
            self.item = item
            self.image = image
            self.size = size
        }
    }

    private struct Request: Hashable {
        let item: MediaItem
        let size: MediaThumbnailSize
    }

    static let shared = MediaThumbnailCache()
    private let memoryThumbnailLimit = 80
    private let preloadThumbnailCount = 40
    private let images = NSCache<NSURL, Entry>()
    private let collectionImages = NSCache<NSString, Entry>()
    private let disk = MediaThumbnailDiskCache()
    private var pending: [Request: Task<Entry, Never>] = [:]
    private var reconciledItems: [MediaItem]?
    private var currentItems: [URL: MediaItem] = [:]
    private var preparationTask: Task<Void, Never>?

    private init() {
        images.countLimit = memoryThumbnailLimit
        images.totalCostLimit = 32 * 1024 * 1024
        collectionImages.countLimit = 16
        collectionImages.totalCostLimit = 32 * 1024 * 1024
    }

    private func collectionKey(_ item: MediaItem, size: MediaThumbnailSize) -> NSString {
        "\(size.pixelSize):\(item.url.absoluteString)" as NSString
    }

    func cached(for item: MediaItem, size: MediaThumbnailSize = .grid) -> Entry? {
        let entry: Entry?
        switch size {
        case .grid: entry = images.object(forKey: item.url as NSURL)
        case .collection: entry = collectionImages.object(forKey: collectionKey(item, size: size))
        }
        guard let entry, entry.item == item, entry.size == size else { return nil }
        return entry
    }

    func reconcile(items: [MediaItem]) {
        guard reconciledItems != items else { return }
        let activeItems = Set(items)
        for old in reconciledItems ?? [] where !activeItems.contains(old) {
            images.removeObject(forKey: old.url as NSURL)
        }
        collectionImages.removeAllObjects()
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

    func load(_ item: MediaItem, size: MediaThumbnailSize = .grid) async -> Entry {
        if let entry = cached(for: item, size: size) { return entry }
        let request = Request(item: item, size: size)
        if let task = pending[request] { return await task.value }
        let task = Task { Entry(item: item, image: await disk.image(for: item, size: size), size: size) }
        pending[request] = task
        let entry = await task.value
        pending[request] = nil
        // Do not resurrect a deleted capture or publish a stale edit's result.
        guard reconciledItems == nil || currentItems[item.url] == item else {
            return Entry(item: item, image: nil, size: size)
        }
        // Failed decoding is transient state, not a reusable thumbnail result.
        guard let image = entry.image else { return entry }
        let cost = image.cgImage.map { $0.bytesPerRow * $0.height } ?? 1
        switch size {
        case .grid: images.setObject(entry, forKey: item.url as NSURL, cost: cost)
        case .collection:
            collectionImages.setObject(entry, forKey: collectionKey(item, size: size), cost: cost)
        }
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
