import Foundation
import CoreServices

/// Live folder monitoring via FSEvents (FR-2.4). Folder-level events are
/// enough: the incremental scanner (mtime/hash + inode rename matching) works
/// out what actually changed. Events are debounced so bursts (unzipping a
/// model pack) trigger one rescan, not hundreds.
public final class FolderWatcher: @unchecked Sendable {
    public typealias RescanHandler = @Sendable (_ folderId: Int64) -> Void

    private final class WatchedFolder {
        let folderId: Int64
        let rootURL: URL // security scope held for the watcher's lifetime
        var stream: FSEventStreamRef?
        var debounce: DispatchWorkItem?

        init(folderId: Int64, rootURL: URL) {
            self.folderId = folderId
            self.rootURL = rootURL
        }
    }

    private let queue = DispatchQueue(label: "polyshelf.fsevents")
    private let debounceInterval: TimeInterval
    private let onRescanNeeded: RescanHandler
    private var watched: [Int64: WatchedFolder] = [:]
    private let lock = NSLock()

    public init(debounceInterval: TimeInterval = 2.0, onRescanNeeded: @escaping RescanHandler) {
        self.debounceInterval = debounceInterval
        self.onRescanNeeded = onRescanNeeded
    }

    deinit {
        stopAll()
    }

    /// Starts watching a folder root. `folderManager.beginAccess` must have
    /// succeeded; the watcher keeps the security scope open until `stop`.
    public func start(folderId: Int64, rootURL: URL) {
        lock.lock()
        defer { lock.unlock() }
        guard watched[folderId] == nil else { return }

        let entry = WatchedFolder(folderId: folderId, rootURL: rootURL)
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil, release: nil, copyDescription: nil
        )

        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            let watcher = Unmanaged<FolderWatcher>.fromOpaque(info).takeUnretainedValue()
            watcher.handleEvents()
        }

        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            callback,
            &context,
            [rootURL.path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            1.0, // FSEvents-side coalescing latency
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagNone)
        ) else {
            rootURL.stopAccessingSecurityScopedResource()
            return
        }

        FSEventStreamSetDispatchQueue(stream, queue)
        FSEventStreamStart(stream)
        entry.stream = stream
        watched[folderId] = entry
    }

    /// All streams share one callback; folder-level granularity means any
    /// event just debounces a rescan of every watched folder whose tree it
    /// could belong to. With per-folder streams, we schedule per folder.
    private func handleEvents() {
        lock.lock()
        let entries = Array(watched.values)
        lock.unlock()
        for entry in entries {
            scheduleRescan(entry)
        }
    }

    private func scheduleRescan(_ entry: WatchedFolder) {
        entry.debounce?.cancel()
        let folderId = entry.folderId
        let handler = onRescanNeeded
        let work = DispatchWorkItem { handler(folderId) }
        entry.debounce = work
        queue.asyncAfter(deadline: .now() + debounceInterval, execute: work)
    }

    public func stop(folderId: Int64) {
        lock.lock()
        defer { lock.unlock() }
        guard let entry = watched.removeValue(forKey: folderId) else { return }
        tearDown(entry)
    }

    public func stopAll() {
        lock.lock()
        let entries = Array(watched.values)
        watched.removeAll()
        lock.unlock()
        for entry in entries { tearDown(entry) }
    }

    public var watchedFolderIds: Set<Int64> {
        lock.lock()
        defer { lock.unlock() }
        return Set(watched.keys)
    }

    private func tearDown(_ entry: WatchedFolder) {
        entry.debounce?.cancel()
        if let stream = entry.stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
        entry.rootURL.stopAccessingSecurityScopedResource()
    }
}
