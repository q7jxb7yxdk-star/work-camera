import AVFoundation
import Combine
import Foundation
import ImageIO
import UniformTypeIdentifiers

struct VideoCaptureDetails: Codable {
    let capturedAt: Date
    let device: String
    let lens: String?
    let focalLength35mm: Double?
    let aperture: Double?
    let latitude: Double?
    let longitude: Double?

    static func deviceDisplayName(_ storedName: String) -> String {
        let name = storedName.trimmingCharacters(in: .whitespacesAndNewlines)
        // Accept both QuickTime model identifiers and the existing sidecar's wrapped name.
        let pattern = #"^(?:Apple\s+)?(?:iPhone\s*\(\s*)?(iPhone\s*[0-9]+\s*,\s*[0-9]+)\s*\)?$"#
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)),
              let range = Range(match.range(at: 1), in: name) else { return storedName }
        let identifier = name[range].components(separatedBy: .whitespacesAndNewlines).joined()
        // Hardware identifiers are not product generation numbers. Keep unknown names intact.
        // Verified against https://github.com/devicekit/DeviceKit/blob/master/Source/Device.generated.swift
        let models = [
            "iPhone13,1": "iPhone 12 mini",
            "iPhone13,2": "iPhone 12",
            "iPhone13,3": "iPhone 12 Pro",
            "iPhone13,4": "iPhone 12 Pro Max",
            "iPhone14,2": "iPhone 13 Pro",
            "iPhone14,3": "iPhone 13 Pro Max",
            "iPhone14,4": "iPhone 13 mini",
            "iPhone14,5": "iPhone 13",
            "iPhone14,6": "iPhone SE (3rd generation)",
            "iPhone14,7": "iPhone 14",
            "iPhone14,8": "iPhone 14 Plus",
            "iPhone15,2": "iPhone 14 Pro",
            "iPhone15,3": "iPhone 14 Pro Max",
            "iPhone15,4": "iPhone 15",
            "iPhone15,5": "iPhone 15 Plus",
            "iPhone16,1": "iPhone 15 Pro",
            "iPhone16,2": "iPhone 15 Pro Max",
            "iPhone17,1": "iPhone 16 Pro",
            "iPhone17,2": "iPhone 16 Pro Max",
            "iPhone17,3": "iPhone 16",
            "iPhone17,4": "iPhone 16 Plus",
            "iPhone17,5": "iPhone 16e",
            "iPhone18,1": "iPhone 17 Pro",
            "iPhone18,2": "iPhone 17 Pro Max",
            "iPhone18,3": "iPhone 17",
            "iPhone18,4": "iPhone Air",
            "iPhone18,5": "iPhone 17e",
            "iPhone19,2": "iPhone 18 Pro",
            "iPhone19,3": "iPhone 18 Pro Max",
            "iPhone19,7": "iPhone 18 Pro Max"
        ]
        guard let model = models[identifier] else { return storedName }
        return "Apple \(model)"
    }
}

struct MediaItem: Identifiable, Hashable {
    enum Kind: String {
        case photo = "HEIC"
        case video = "MOV"
    }

    let url: URL
    let kind: Kind
    let createdAt: Date
    var modifiedAt: Date = .distantPast

    var id: String { filename }
    var filename: String { url.lastPathComponent }
    var stem: String { url.deletingPathExtension().lastPathComponent }
}

struct MediaAlbum: Codable, Identifiable {
    let id: UUID
    var name: String
    var memberKeys: Set<String>
}

@MainActor
final class MediaStore: ObservableObject {
    let searchIndex = PhotoSearchIndex()
    @Published private(set) var items: [MediaItem] = []
    @Published private(set) var albums: [MediaAlbum] = []
    private var albumsLoaded = false

    private let fileManager = FileManager.default
    private let nextNumberKey = "nextCaptureNumber"

    private var mediaDirectory: URL {
        fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Media", isDirectory: true)
    }

    func load() throws {
        try fileManager.createDirectory(at: mediaDirectory, withIntermediateDirectories: true)
        let urls = try fileManager.contentsOfDirectory(
            at: mediaDirectory,
            includingPropertiesForKeys: [.creationDateKey, .contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        )
        items = urls.compactMap { url in
            guard url.lastPathComponent.range(of: #"^IMG_[0-9]{4}\.(HEIC|MOV)$"#, options: .regularExpression) != nil,
                  let kind = MediaItem.Kind(rawValue: url.pathExtension),
                  (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
            else { return nil }
            let createdAt = (try? url.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
            let modifiedAt = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return MediaItem(url: url, kind: kind, createdAt: createdAt, modifiedAt: modifiedAt)
        }
        items.sort { $0.createdAt > $1.createdAt }
        searchIndex.reconcile(items: items)
        MediaThumbnailCache.shared.reconcile(items: items)
        try loadAlbums()
    }

    private var albumsURL: URL { mediaDirectory.appendingPathComponent("Albums.json") }

    private func memberKey(for item: MediaItem) -> String {
        // Capture identity includes its date so a reused filename does not inherit an album.
        "\(item.id).\(item.createdAt.timeIntervalSince1970)"
    }

    private func loadAlbums() throws {
        guard !albumsLoaded else { return }
        if fileManager.fileExists(atPath: albumsURL.path) {
            albums = try JSONDecoder().decode([MediaAlbum].self, from: Data(contentsOf: albumsURL))
        }
        albumsLoaded = true
    }

    private func saveAlbums(_ updated: [MediaAlbum]) throws {
        try fileManager.createDirectory(at: mediaDirectory, withIntermediateDirectories: true)
        try JSONEncoder().encode(updated).write(to: albumsURL, options: .atomic)
        albums = updated
    }

    func items(in album: MediaAlbum) -> [MediaItem] {
        items.filter { album.memberKeys.contains(memberKey(for: $0)) }
    }

    var unassignedItems: [MediaItem] {
        let assigned = albums.reduce(into: Set<String>()) { $0.formUnion($1.memberKeys) }
        return items.filter { !assigned.contains(memberKey(for: $0)) }
    }

    private func validatedAlbumName(_ name: String, excluding id: UUID? = nil) throws -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.localizedCaseInsensitiveCompare("Not in an Album") != .orderedSame,
              !albums.contains(where: { $0.id != id && $0.name.localizedCaseInsensitiveCompare(trimmed) == .orderedSame })
        else { throw MediaStoreError.invalidAlbumName }
        return trimmed
    }

    func createAlbum(named name: String) throws {
        try loadAlbums()
        let album = MediaAlbum(id: UUID(), name: try validatedAlbumName(name), memberKeys: [])
        try saveAlbums(albums + [album])
    }

    func renameAlbum(_ id: UUID, to name: String) throws {
        try loadAlbums()
        guard let index = albums.firstIndex(where: { $0.id == id }) else { throw MediaStoreError.missingAlbum }
        var updated = albums
        updated[index].name = try validatedAlbumName(name, excluding: id)
        try saveAlbums(updated)
    }

    func updateAlbum(_ id: UUID, itemIDs: Set<String>, adding: Bool) throws {
        try loadAlbums()
        guard let index = albums.firstIndex(where: { $0.id == id }) else { throw MediaStoreError.missingAlbum }
        let keys = Set(items.filter { itemIDs.contains($0.id) }.map { memberKey(for: $0) })
        var updated = albums
        if adding { updated[index].memberKeys.formUnion(keys) }
        else { updated[index].memberKeys.subtract(keys) }
        try saveAlbums(updated)
    }

    func deleteAlbum(_ id: UUID, includingMedia: Bool) throws {
        try loadAlbums()
        guard let album = albums.first(where: { $0.id == id }) else { throw MediaStoreError.missingAlbum }
        if includingMedia {
            for item in items(in: album) {
                try delete(item)
                UserDefaults.standard.removeObject(forKey: "favorite.\(item.id).\(item.createdAt.timeIntervalSince1970)")
            }
        }
        try saveAlbums(albums.filter { $0.id != id })
    }

    func savePhoto(_ data: Data) throws {
        let url = try nextAvailableURL(extension: "HEIC")
        let temporaryURL = mediaDirectory.appendingPathComponent(UUID().uuidString)
        try data.write(to: temporaryURL, options: .atomic)
        defer { try? fileManager.removeItem(at: temporaryURL) }
        try fileManager.linkItem(at: temporaryURL, to: url)
        try load()
    }

    func saveEditedPhoto(_ data: Data, for item: MediaItem, overwrite: Bool) throws {
        guard item.kind == .photo,
              items.contains(where: { $0.id == item.id }),
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetType(source) as String? == UTType.heic.identifier,
              CGImageSourceGetCount(source) == 1,
              CGImageSourceGetStatus(source) == .statusComplete else {
            throw MediaStoreError.invalidEditedPhoto
        }
        if overwrite {
            try data.write(to: item.url, options: .atomic)
            // Retain the original capture's library order after atomic replacement.
            try? fileManager.setAttributes([.creationDate: item.createdAt], ofItemAtPath: item.url.path)
            if let index = items.firstIndex(where: { $0.id == item.id }) {
                items[index].modifiedAt = Date()
            }
            searchIndex.reconcile(items: items)
            MediaThumbnailCache.shared.reconcile(items: items)
        } else {
            try savePhoto(data)
        }
    }

    func saveVideo(from temporaryURL: URL, captureDetails: VideoCaptureDetails? = nil) throws {
        let url = try nextAvailableURL(extension: "MOV")
        let infoURL = url.deletingPathExtension().appendingPathExtension("INFO.json")
        // Commit metadata first: a metadata failure leaves the original temporary movie intact.
        if let captureDetails {
            let detailsData = try JSONEncoder().encode(captureDetails)
            let details = try JSONSerialization.jsonObject(with: detailsData)
            let data = try JSONSerialization.data(withJSONObject: ["captureDetails": details])
            try data.write(to: infoURL, options: .atomic)
        }
        do {
            try fileManager.moveItem(at: temporaryURL, to: url)
        } catch {
            if captureDetails != nil { try? fileManager.removeItem(at: infoURL) }
            throw error
        }
        // Keep a successfully saved movie visible even if refreshing the directory fails.
        let values = try? url.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey])
        items.insert(MediaItem(url: url, kind: .video,
                               createdAt: values?.creationDate ?? captureDetails?.capturedAt ?? Date(),
                               modifiedAt: values?.contentModificationDate ?? Date()), at: 0)
        try? load()
        MediaThumbnailCache.shared.reconcile(items: items)
    }

    func saveEditedVideo(from temporaryURL: URL, for item: MediaItem, overwrite: Bool) async throws {
        guard item.kind == .video, temporaryURL != item.url,
              items.contains(where: { $0.id == item.id }) else { throw MediaStoreError.missingCapture }
        let asset = AVURLAsset(url: temporaryURL)
        let duration = try await asset.load(.duration)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        guard duration.seconds.isFinite, duration.seconds > 0, !tracks.isEmpty else {
            throw MediaStoreError.invalidEditedVideo
        }
        // Recheck after suspension; the source must still exist before committing.
        guard items.contains(where: { $0.id == item.id }), fileManager.fileExists(atPath: item.url.path) else {
            throw MediaStoreError.missingCapture
        }
        let stagedURL = mediaDirectory.appendingPathComponent(UUID().uuidString + ".MOV")
        try fileManager.copyItem(at: temporaryURL, to: stagedURL)
        defer { try? fileManager.removeItem(at: stagedURL) }
        if overwrite {
            try fileManager.setAttributes([.creationDate: item.createdAt], ofItemAtPath: stagedURL.path)
            _ = try fileManager.replaceItemAt(item.url, withItemAt: stagedURL, backupItemName: nil,
                                             options: .usingNewMetadataOnly)
            if let index = items.firstIndex(where: { $0.id == item.id }) {
                items[index].modifiedAt = Date()
            }
        } else {
            // Validate existing metadata before making copies; never replace malformed JSON.
            _ = try readInfo(for: item)
            let destination = try nextAvailableURL(extension: "MOV")
            var copiedSidecars: [URL] = []
            do {
                for source in [infoURL(for: item), reportURL(for: item)] where fileManager.fileExists(atPath: source.path) {
                    let suffix = source.lastPathComponent.dropFirst(item.stem.count)
                    let target = mediaDirectory.appendingPathComponent(destination.deletingPathExtension().lastPathComponent + suffix)
                    try fileManager.copyItem(at: source, to: target)
                    copiedSidecars.append(target)
                }
                // Publish the movie last, after both sidecars are ready.
                try fileManager.linkItem(at: stagedURL, to: destination)
            } catch {
                for url in copiedSidecars { try? fileManager.removeItem(at: url) }
                throw error
            }
            items.insert(MediaItem(url: destination, kind: .video, createdAt: Date(), modifiedAt: Date()), at: 0)
        }
        MediaThumbnailCache.shared.reconcile(items: items)
    }

    func videoCaptureDetails(for item: MediaItem) -> VideoCaptureDetails? {
        guard let info = try? readInfo(for: item), let details = info["captureDetails"],
              let data = try? JSONSerialization.data(withJSONObject: details) else { return nil }
        return try? JSONDecoder().decode(VideoCaptureDetails.self, from: data)
    }

    func keywords(for item: MediaItem) -> [String] {
        (try? readInfo(for: item)["keywords"] as? [String]) ?? []
    }

    func hasSavedKeywords(for item: MediaItem) -> Bool {
        (try? readInfo(for: item)["keywords"] as? [String]) != nil
    }

    func saveKeywords(_ keywords: [String], for item: MediaItem) throws {
        guard items.contains(where: { $0.id == item.id }) else {
            throw MediaStoreError.missingCapture
        }
        // Preserve capture details and any future fields; malformed existing JSON is never replaced.
        var info = try readInfo(for: item)
        var seen = Set<String>()
        info["keywords"] = keywords.compactMap { keyword -> String? in
            let trimmed = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, seen.insert(trimmed).inserted else { return nil }
            return trimmed
        }
        let data = try JSONSerialization.data(withJSONObject: info, options: [.sortedKeys])
        try data.write(to: infoURL(for: item), options: .atomic)
    }

    private func readInfo(for item: MediaItem) throws -> [String: Any] {
        let url = infoURL(for: item)
        guard fileManager.fileExists(atPath: url.path) else { return [:] }
        let data = try Data(contentsOf: url)
        guard let info = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw MediaStoreError.invalidInfo
        }
        return info
    }

    private func infoURL(for item: MediaItem) -> URL {
        mediaDirectory.appendingPathComponent(item.stem).appendingPathExtension("INFO.json")
    }

    func report(for item: MediaItem) -> String {
        (try? String(contentsOf: reportURL(for: item), encoding: .utf8)) ?? ""
    }

    func saveReport(_ text: String, for item: MediaItem) throws {
        try Self.normalizedReport(text).write(to: reportURL(for: item), atomically: true, encoding: .utf8)
    }

    static func normalizedReport(_ text: String) -> String {
        text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
    }

    func delete(at offsets: IndexSet) throws {
        let selected = offsets.map { items[$0] }
        for item in selected { try delete(item) }
    }

    func delete(_ item: MediaItem) throws {
        try loadAlbums()
        try fileManager.removeItem(at: item.url)
        // Keep the deleted capture out of the UI even if a later metadata update fails.
        defer {
            items.removeAll { $0.id == item.id }
            searchIndex.reconcile(items: items)
            MediaThumbnailCache.shared.reconcile(items: items)
        }
        var failures: [String] = []
        let key = memberKey(for: item)
        if albums.contains(where: { $0.memberKeys.contains(key) }) {
            var updated = albums
            for index in updated.indices { updated[index].memberKeys.remove(key) }
            do {
                try saveAlbums(updated)
            } catch {
                failures.append("Album membership could not be saved: \(error.localizedDescription)")
            }
        }
        // Each sidecar is independent of album persistence and the other sidecar.
        for (name, url) in [("Report", reportURL(for: item)), ("INFO", infoURL(for: item))] {
            do {
                try fileManager.removeItem(at: url)
            } catch let error as CocoaError where error.code == .fileNoSuchFile {
                // An optional sidecar that is already absent needs no cleanup.
            } catch {
                failures.append("\(name) could not be deleted: \(error.localizedDescription)")
            }
        }
        do {
            try load()
        } catch {
            failures.append("The library could not be refreshed: \(error.localizedDescription)")
        }
        if !failures.isEmpty { throw MediaStoreError.incompleteDeletion(failures) }
    }

    private func reportURL(for item: MediaItem) -> URL {
        mediaDirectory.appendingPathComponent(item.stem).appendingPathExtension("TXT")
    }

    private func nextAvailableURL(extension fileExtension: String) throws -> URL {
        try fileManager.createDirectory(at: mediaDirectory, withIntermediateDirectories: true)
        let savedNext = UserDefaults.standard.integer(forKey: nextNumberKey)
        let next = savedNext == 0 ? 1 : max(1, min(9_999, savedNext))
        for offset in 0..<9_999 {
            let number = ((next - 1 + offset) % 9_999) + 1
            let stem = String(format: "IMG_%04d", number)
            let occupied = ["HEIC", "MOV", "TXT", "INFO.json"].contains {
                fileManager.fileExists(atPath: mediaDirectory.appendingPathComponent(stem).appendingPathExtension($0).path)
            }
            if !occupied {
                UserDefaults.standard.set(number == 9_999 ? 1 : number + 1, forKey: nextNumberKey)
                return mediaDirectory.appendingPathComponent(stem).appendingPathExtension(fileExtension)
            }
        }
        throw MediaStoreError.noAvailableFilename
    }
}

private enum MediaStoreError: LocalizedError {
    case noAvailableFilename
    case invalidEditedPhoto
    case invalidEditedVideo
    case missingCapture
    case invalidInfo
    case invalidAlbumName
    case missingAlbum
    case incompleteDeletion([String])

    var errorDescription: String? {
        switch self {
        case .noAvailableFilename:
            "All IMG_0001 through IMG_9999 filenames are in use. Delete captures to free space."
        case .invalidEditedPhoto:
            "The edited photo is not a valid HEIC image, or the original capture is no longer available."
        case .invalidEditedVideo:
            "The edited movie does not contain a valid video track."
        case .missingCapture:
            "The capture is no longer available."
        case .invalidInfo:
            "The existing capture information could not be read. It has been preserved."
        case .invalidAlbumName:
            "Enter a unique album name. Not in an Album is a reserved name."
        case .missingAlbum:
            "This album is no longer available."
        case .incompleteDeletion(let failures):
            "The media was deleted, but some cleanup failed. " + failures.joined(separator: " ")
        }
    }
}
