import Foundation
import AppKit
import GRDB
import QuickLookThumbnailing

extension Notification.Name {
    /// Posted (on the main queue) when a thumbnail lands in the cache.
    /// userInfo: ["key": String]
    public static let polyShelfThumbnailReady = Notification.Name("polyShelfThumbnailReady")
}

/// Bounded, low-priority thumbnail generation queue (FR-4.5): tiered
/// rendering, resumable (re-request anytime; cache hits are free), max N
/// concurrent where N = performance-core count. Oversized files render one
/// at a time to bound transient memory (FR-4 acceptance).
public actor ThumbnailPipeline {
    private let database: DatabaseManager
    private let folderManager: FolderManager
    private let cache: ThumbnailCache
    private let maxConcurrent: Int

    /// Files above this render serially (memory bound for 100 MB+ STLs).
    private let largeFileThreshold: Int64 = 50 * 1024 * 1024

    private var pending: [Int64] = []
    private var enqueued: Set<Int64> = []
    private var workersRunning = 0
    private var largeFileBusy = false
    /// Folder security scopes held open while the queue drains — resolving a
    /// security-scoped bookmark per item is far too expensive at queue scale.
    private var folderRoots: [Int64: URL] = [:]

    public init(database: DatabaseManager, folderManager: FolderManager, cache: ThumbnailCache) {
        self.database = database
        self.folderManager = folderManager
        self.cache = cache
        self.maxConcurrent = Self.performanceCoreCount()
    }

    static func performanceCoreCount() -> Int {
        var count: Int32 = 0
        var size = MemoryLayout<Int32>.size
        if sysctlbyname("hw.perflevel0.physicalcpu", &count, &size, nil, 0) == 0, count > 0 {
            return Int(count)
        }
        return max(2, ProcessInfo.processInfo.activeProcessorCount / 2)
    }

    // MARK: - Public API

    /// Direct store for embedded thumbnails found during enrichment.
    public nonisolated func storeEmbedded(itemId: Int64, imageData: Data) {
        Task(priority: .utility) {
            await self.storeEmbeddedInternal(itemId: itemId, imageData: imageData)
        }
    }

    private func storeEmbeddedInternal(itemId: Int64, imageData: Data) async {
        guard let item = try? await database.writer.read({ try ItemRecord.fetchOne($0, key: itemId) }),
              let key = ThumbnailCache.key(for: item) else { return }
        cache.store(imageData: imageData, forKey: key)
        notifyReady(key: key)
    }

    /// Requests generation for any of the given items not already cached.
    public func request(itemIds: [Int64]) {
        for id in itemIds where !enqueued.contains(id) {
            enqueued.insert(id)
            pending.append(id)
        }
        spawnWorkers()
    }

    // MARK: - Worker loop

    private func spawnWorkers() {
        while workersRunning < maxConcurrent, !pending.isEmpty {
            workersRunning += 1
            Task(priority: .background) {
                await self.workLoop()
            }
        }
    }

    private func workLoop() async {
        while let itemId = nextItem() {
            await process(itemId: itemId)
            enqueued.remove(itemId)
        }
        workersRunning -= 1
        if workersRunning == 0 { releaseFolderRoots() }
    }

    /// Resolves (once) and caches security-scoped access for a folder.
    private func rootURL(forFolderId folderId: Int64) async -> URL? {
        if let cached = folderRoots[folderId] { return cached }
        guard let folder = try? await database.writer.read({ try FolderRecord.fetchOne($0, key: folderId) }),
              case .available(let url) = folderManager.beginAccess(folder) else { return nil }
        // Another worker may have resolved the same folder during the await
        // (actor reentrancy) — keep the first scope, release this one.
        if let cached = folderRoots[folderId] {
            url.stopAccessingSecurityScopedResource()
            return cached
        }
        folderRoots[folderId] = url
        return url
    }

    private func releaseFolderRoots() {
        for url in folderRoots.values { url.stopAccessingSecurityScopedResource() }
        folderRoots.removeAll()
    }

    private func nextItem() -> Int64? {
        pending.isEmpty ? nil : pending.removeFirst()
    }

    private func process(itemId: Int64) async {
        guard let item = try? await database.writer.read({ try ItemRecord.fetchOne($0, key: itemId) }),
              item.status == .ok,
              let key = ThumbnailCache.key(for: item) else { return }
        guard !cache.contains(key: key) else {
            notifyReady(key: key)
            return
        }
        guard let spec = FormatRegistry.spec(forExtension: item.ext), spec.previewTier != .icon else {
            return
        }
        guard let rootURL = await rootURL(forFolderId: item.folderId) else { return }
        let fileURL = rootURL.appendingPathComponent(item.relPath)

        // One oversized render at a time.
        let isLarge = item.sizeBytes > largeFileThreshold
        if isLarge {
            while largeFileBusy {
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
            largeFileBusy = true
        }
        defer { if isLarge { largeFileBusy = false } }

        if let png = await generate(fileURL: fileURL, spec: spec) {
            cache.store(imageData: png, forKey: key)
            notifyReady(key: key)
        }
    }

    /// Tiered generation (FR-4.2), first success wins:
    /// mesh render → embedded thumbnail → QuickLook → (icon handled by UI).
    private func generate(fileURL: URL, spec: FormatSpec) async -> Data? {
        // Tier 1: offscreen mesh render
        if spec.previewTier == .meshRender || MeshRenderer.renderableExtensions.contains(spec.ext) {
            if let png = MeshRenderer.renderThumbnail(fileURL: fileURL) {
                return png
            }
        }
        // Tier 2: embedded thumbnail extraction
        if let parser = GeometryEnricher.parsers.first(where: { $0.extensions.contains(spec.ext) }),
           let stats = try? parser.parse(fileURL: fileURL),
           let embedded = stats.embeddedThumbnail {
            return embedded
        }
        // Tier 3: QuickLook
        if let png = await quickLookThumbnail(fileURL: fileURL) {
            return png
        }
        return nil
    }

    private func quickLookThumbnail(fileURL: URL, size: CGFloat = 512) async -> Data? {
        let request = QLThumbnailGenerator.Request(
            fileAt: fileURL,
            size: CGSize(width: size, height: size),
            scale: 1,
            representationTypes: .thumbnail
        )
        guard let representation = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request) else {
            return nil
        }
        let cgImage = representation.cgImage
        let rep = NSBitmapImageRep(cgImage: cgImage)
        return rep.representation(using: .png, properties: [:])
    }

    private nonisolated func notifyReady(key: String) {
        DispatchQueue.main.async {
            NotificationCenter.default.post(
                name: .polyShelfThumbnailReady,
                object: nil,
                userInfo: ["key": key]
            )
        }
    }
}
