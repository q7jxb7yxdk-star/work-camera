import Combine
import Foundation
import ImageIO
import Vision

// Explicitly independent of the project's default MainActor isolation.
nonisolated private struct PhotoSearchRecord: Codable, Sendable {
    let fingerprint: String
    let text: String
    let labels: [String]
    let complete: Bool
}

nonisolated private struct PhotoSearchCache: Codable, Sendable {
    let version: Int
    let records: [String: PhotoSearchRecord]
}

@MainActor
final class PhotoSearchIndex: ObservableObject {
    @Published private(set) var isIndexing = false
    @Published private(set) var completedCount = 0
    @Published private(set) var totalCount = 0
    @Published private(set) var failedCount = 0
    @Published private(set) var cacheError: String?
    @Published private var records: [String: PhotoSearchRecord] = [:]

    private var photos: [MediaItem] = []
    private var failedFingerprints: Set<String> = []
    private var started = false
    private var loaded = false
    private var cacheNeedsSave = false
    private var worker: Task<Void, Never>?
    private let cacheURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("PhotoSearchIndex.json")

    func start(items: [MediaItem]) {
        started = true
        reconcile(items: items)
    }

    func reconcile(items: [MediaItem]) {
        photos = items.filter { $0.kind == .photo }
        // Purge persisted records on every media change, even before Search opens.
        // A failed read must not replace an existing cache with empty results.
        guard loadCacheIfNeeded() else { return }
        let fingerprints = Dictionary(uniqueKeysWithValues: photos.map { ($0.id, fingerprint($0)) })
        let retained = records.filter { fingerprints[$0.key] == $0.value.fingerprint }
        if retained.count != records.count {
            records = retained
            cacheNeedsSave = true
        }
        if cacheNeedsSave { persist() }
        failedFingerprints.formIntersection(Set(fingerprints.values))
        updateProgress()
        guard started, worker == nil, nextPhoto() != nil else { return }
        isIndexing = true
        worker = Task { [weak self] in
            guard let self else { return }
            // One Vision job at a time; reconciliation can change the queue during suspension.
            while let photo = self.nextPhoto() {
                let expected = self.fingerprint(photo)
                let url = photo.url
                let result = await Task.detached(priority: .utility) {
                    Result { try Self.analyze(url: url, fingerprint: expected) }
                }.value
                // An edited, deleted, or reused file must never receive stale results.
                guard self.photos.contains(where: { $0.id == photo.id && self.fingerprint($0) == expected }) else {
                    continue
                }
                switch result {
                case .success(let record):
                    self.records[photo.id] = record
                    if !record.complete { self.failedFingerprints.insert(expected) }
                    self.persist()
                case .failure:
                    self.failedFingerprints.insert(expected)
                }
                self.updateProgress()
            }
            self.isIndexing = false
            self.worker = nil
        }
    }

    func retry(items: [MediaItem]) {
        failedFingerprints.removeAll()
        start(items: items)
        persist()
    }

    func matches(_ item: MediaItem, query: String) -> Bool {
        let terms = Self.normalized(query).split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard !terms.isEmpty else { return true }
        var searchable = item.filename
        if let record = records[item.id], record.fingerprint == fingerprint(item) {
            searchable += " " + record.text + " " + record.labels.joined(separator: " ")
        }
        let haystack = Self.normalized(searchable)
        return terms.allSatisfy { haystack.contains($0) }
    }

    private func fingerprint(_ item: MediaItem) -> String {
        "\(item.id)|\(item.createdAt.timeIntervalSince1970)|\(item.modifiedAt.timeIntervalSince1970)"
    }

    private func nextPhoto() -> MediaItem? {
        photos.first {
            let key = fingerprint($0)
            return !failedFingerprints.contains(key) &&
                (records[$0.id]?.fingerprint != key || records[$0.id]?.complete != true)
        }
    }

    private func updateProgress() {
        totalCount = photos.count
        failedCount = photos.filter { failedFingerprints.contains(fingerprint($0)) }.count
        completedCount = photos.filter { records[$0.id]?.fingerprint == fingerprint($0) && records[$0.id]?.complete == true }.count
    }

    private func persist() {
        guard loaded else { return }
        cacheNeedsSave = true
        do {
            try FileManager.default.createDirectory(at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(PhotoSearchCache(version: 1, records: records)).write(to: cacheURL, options: .atomic)
            cacheNeedsSave = false
            cacheError = nil
        } catch {
            cacheError = "Search results could not be saved. Deleted records may remain in the saved cache."
        }
    }

    private func loadCacheIfNeeded() -> Bool {
        guard !loaded else { return true }
        do {
            let data = try Data(contentsOf: cacheURL)
            let cache = try JSONDecoder().decode(PhotoSearchCache.self, from: data)
            guard cache.version == 1 else {
                cacheError = "The saved search results use an unsupported version. The cache has been preserved; deleted records could not be cleared."
                return false
            }
            records = cache.records
            loaded = true
            cacheError = nil
            return true
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            // First launch has no cache. Other read/decode failures remain retryable.
            loaded = true
            cacheError = nil
            return true
        } catch {
            cacheError = "Saved search results could not be loaded. The cache has been preserved; deleted records could not be cleared."
            return false
        }
    }

    nonisolated private static func normalized(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .replacingOccurrences(of: "_", with: " ")
    }

    nonisolated private static func analyze(url: URL, fingerprint: String) throws -> PhotoSearchRecord {
        try autoreleasepool {
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: 2560
                  ] as CFDictionary) else {
                throw CocoaError(.fileReadCorruptFile)
            }
            // Thumbnail transform applies EXIF orientation before all three requests.
            let handler = VNImageRequestHandler(cgImage: image, options: [:])
            let textRequest = VNRecognizeTextRequest()
            textRequest.recognitionLevel = .accurate
            textRequest.usesLanguageCorrection = true
            textRequest.automaticallyDetectsLanguage = true
            let supported = try textRequest.supportedRecognitionLanguages()
            let preferred = ["zh-Hant", "zh-Hans", "en-US"].filter { supported.contains($0) }
            if !preferred.isEmpty { textRequest.recognitionLanguages = preferred }

            // Separate requests preserve successful results if another analysis fails.
            var succeeded = 0
            var text = ""
            var labels: Set<String> = []
            do {
                try handler.perform([textRequest])
                text = (textRequest.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
                succeeded += 1
            } catch { }
            let classification = VNClassifyImageRequest()
            do {
                try handler.perform([classification])
                let observations = (classification.results ?? []).filter { $0.confidence >= 0.2 }.prefix(20)
                for observation in observations {
                    let label = normalized(observation.identifier)
                    labels.insert(label)
                    for group in objectAliases where group.english.contains(where: { alias in
                        label == alias || label.hasPrefix(alias + " ") || label.hasSuffix(" " + alias)
                    }) {
                        labels.formUnion(group.english)
                        labels.formUnion(group.chinese)
                    }
                }
                succeeded += 1
            } catch { }
            let document = VNDetectDocumentSegmentationRequest()
            do {
                try handler.perform([document])
                if (document.results ?? []).contains(where: { $0.confidence >= 0.5 }) {
                    labels.formUnion(["document", "paper", "文件", "文檔", "文档", "紙張", "纸张"])
                }
                succeeded += 1
            } catch { }
            // Partial results remain searchable, but retry the photo on the next attempt.
            guard succeeded > 0 else { throw CocoaError(.featureUnsupported) }
            return PhotoSearchRecord(fingerprint: fingerprint, text: text, labels: labels.sorted(), complete: succeeded == 3)
        }
    }

    nonisolated private static let objectAliases: [(english: [String], chinese: [String])] = [
        (["document", "paper", "text", "page"], ["文件", "文檔", "文档", "紙張", "纸张"]),
        (["receipt"], ["收據", "收据", "單據", "单据"]),
        (["book", "books"], ["書", "书", "書本", "书本"]),
        (["people", "person", "face", "portrait"], ["人", "人物", "人像"]),
        (["cat", "cats"], ["貓", "猫"]),
        (["dog", "dogs"], ["狗"]),
        (["animal", "animals", "pet", "pets"], ["動物", "动物", "寵物", "宠物"]),
        (["food", "meal", "dish"], ["食物", "餐點", "餐点", "美食"]),
        (["car", "cars", "vehicle"], ["車", "车", "汽車", "汽车"]),
        (["building", "architecture"], ["建築", "建筑", "大廈", "大厦"]),
        (["flower", "flowers"], ["花", "花朵"]),
        (["plant", "plants", "tree", "trees"], ["植物", "樹", "树"]),
        (["computer", "laptop", "keyboard"], ["電腦", "电脑", "筆電", "笔电"]),
        (["phone", "mobile phone", "cell phone"], ["手機", "手机", "電話", "电话"]),
        (["screen", "monitor", "display"], ["螢幕", "屏幕"]),
        (["bottle"], ["瓶", "瓶子"]),
        (["cup", "mug"], ["杯", "杯子"]),
        (["chair"], ["椅", "椅子"]),
        (["table", "desk"], ["桌", "桌子"]),
        (["sign", "signage"], ["標誌", "标志", "招牌"])
    ]
}
