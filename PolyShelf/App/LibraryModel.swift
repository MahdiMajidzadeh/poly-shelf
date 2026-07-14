import AppKit
import SwiftUI
import PolyShelfCore

/// UI-facing coordinator: folder actions, scans, and enabled-format state.
@Observable
@MainActor
final class LibraryModel {
    private let database: DatabaseManager
    let folderManager: FolderManager
    private let scanner: LibraryScanner
    let thumbnailCache: ThumbnailCache
    let thumbnailPipeline: ThumbnailPipeline
    let itemStore: ItemStore

    /// Folder ids currently being scanned (drives progress UI).
    private(set) var scanningFolderIds: Set<Int64> = []
    var lastScanSummary: ScanSummary?
    var alertMessage: String?
    private var watcher: FolderWatcher?

    /// Live watching toggle (FR-2.4), on by default.
    var watchingEnabled: Bool {
        UserDefaults.standard.object(forKey: "watchFolders") as? Bool ?? true
    }

    init(database: DatabaseManager) {
        self.database = database
        let folderManager = FolderManager(database: database)
        self.folderManager = folderManager
        self.itemStore = ItemStore(database: database)

        let cache = (try? ThumbnailCache.defaultCache())
            ?? (try! ThumbnailCache(directory: FileManager.default.temporaryDirectory
                .appendingPathComponent("PolyShelfThumbs")))
        self.thumbnailCache = cache
        let pipeline = ThumbnailPipeline(database: database, folderManager: folderManager, cache: cache)
        self.thumbnailPipeline = pipeline

        let supportDir = try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true
        ).appendingPathComponent("PolyShelf", isDirectory: true)

        self.scanner = LibraryScanner(
            database: database,
            folderManager: folderManager,
            enrichmentStages: [
                // Order matters: tagging reads geometry stats written here.
                GeometryEnricher(database: database, thumbnailSink: { itemId, data in
                    pipeline.storeEmbedded(itemId: itemId, imageData: data)
                }),
                AutoTagger(database: database, dictionary: .load(userOverrideDirectory: supportDir)),
            ]
        )

        // Retention: drop items missing longer than the configured window.
        Task(priority: .utility) {
            let days = UserDefaults.standard.object(forKey: "missingRetentionDays") as? Int
                ?? MissingItemPurge.defaultRetentionDays
            _ = try? await MissingItemPurge.purgeExpired(database: database, retentionDays: days)
        }
    }

    /// Creates the FSEvents watcher (FR-2.4). Separate from init because the
    /// handler captures self, which Swift forbids before init completes.
    func activateWatching() {
        guard watcher == nil else { return }
        watcher = FolderWatcher { [weak self] folderId in
            Task { @MainActor [weak self] in
                self?.rescan(folderId: folderId)
            }
        }
    }

    /// Starts FSEvents watching for a folder (idempotent).
    func startWatching(folderId: Int64) {
        guard watchingEnabled, let watcher, !watcher.watchedFolderIds.contains(folderId) else { return }
        Task {
            guard let folder = try? await database.writer.read({ db in
                try FolderRecord.fetchOne(db, key: folderId)
            }), folder.detachedAt == nil else { return }
            // The watcher owns this security scope until stop().
            if case .available(let rootURL) = folderManager.beginAccess(folder) {
                watcher.start(folderId: folderId, rootURL: rootURL)
            }
        }
    }

    /// Queues thumbnail generation for every renderable item in a folder
    /// that isn't already cached (resumable, FR-4.5).
    func requestThumbnails(folderId: Int64) {
        Task(priority: .utility) {
            let ids: [Int64] = (try? await database.writer.read { db in
                try Int64.fetchAll(
                    db,
                    sql: "SELECT id FROM items WHERE folderId = ? AND status = 'ok'",
                    arguments: [folderId]
                )
            }) ?? []
            await thumbnailPipeline.request(itemIds: ids)
        }
    }

    // MARK: - Enabled formats

    /// Nonisolated: UserDefaults is thread-safe, and observation closures
    /// (which run off the main actor) need this.
    nonisolated var enabledExtensions: Set<String> {
        guard
            let data = UserDefaults.standard.data(forKey: "enabledFormats"),
            let set = try? JSONDecoder().decode(Set<String>.self, from: data)
        else {
            return FormatRegistry.defaultEnabledExtensions
        }
        return set
    }

    // MARK: - Folder actions

    func presentAddFolderPanel() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Add Folder"
        panel.message = "Choose folders containing 3D models. Files are indexed in place — never moved or modified."
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            addFolder(at: url)
        }
    }

    func addFolder(at url: URL) {
        do {
            switch try folderManager.addFolder(at: url) {
            case .added(let id), .reattached(let id):
                rescan(folderId: id)
            case .alreadyAdded:
                alertMessage = "“\(url.lastPathComponent)” is already in your library."
            case .nestedInsideExisting(let parent):
                alertMessage = "“\(url.lastPathComponent)” is inside “\(parent)”, which is already watched — its files are indexed there."
            case .containsExisting(let children):
                alertMessage = "“\(url.lastPathComponent)” contains folders already in your library (\(children.joined(separator: ", "))). Remove those first to add the parent."
            }
        } catch {
            alertMessage = "Couldn’t add folder: \(error.localizedDescription)"
        }
    }

    func removeFolder(id: Int64, keepMetadata: Bool) {
        watcher?.stop(folderId: id)
        do {
            try folderManager.removeFolder(id: id, keepMetadata: keepMetadata)
        } catch {
            alertMessage = "Couldn’t remove folder: \(error.localizedDescription)"
        }
    }

    func rescan(folderId: Int64) {
        guard !scanningFolderIds.contains(folderId) else { return }
        scanningFolderIds.insert(folderId)
        let extensions = enabledExtensions
        Task {
            defer { scanningFolderIds.remove(folderId) }
            do {
                lastScanSummary = try await scanner.scan(folderId: folderId, enabledExtensions: extensions)
                requestThumbnails(folderId: folderId)
                startWatching(folderId: folderId)
            } catch is CancellationError {
                // user cancelled; partial progress is already committed
            } catch ScanError.folderOffline {
                alertMessage = "That folder’s volume is offline. Items were marked offline; metadata is preserved."
            } catch {
                alertMessage = "Scan failed: \(error.localizedDescription)"
            }
        }
    }

    func rescanAll(folders: [FolderRecord]) {
        for folder in folders where folder.detachedAt == nil {
            if let id = folder.id { rescan(folderId: id) }
        }
    }

    // MARK: - Export / Import (FR-9)

    /// Exports the whole library, or one folder when `folderId` is given.
    func exportMetadata(folderId: Int64? = nil, suggestedName: String = "Library") {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(suggestedName).polyshelf.json"
        panel.allowedContentTypes = [.json]
        panel.title = "Export Poly Shelf Metadata"
        panel.message = "Tags, display names, and notes — no files are copied, no keys or absolute paths included."
        guard panel.runModal() == .OK, let url = panel.url else { return }

        Task {
            do {
                let exporter = Exporter(database: database, folderManager: folderManager)
                let export = try await exporter.export(folderId: folderId)
                let data = try Exporter.encode(export)
                try data.write(to: url, options: .atomic)
                let count = export.folders.reduce(0) { $0 + $1.items.count }
                alertMessage = "Exported metadata for \(count) models."
            } catch {
                alertMessage = "Export failed: \(error.localizedDescription)"
            }
        }
    }

    /// Bundle export (FR-9.4): copy files + sidecar into a chosen folder.
    func exportBundle(folderId: Int64, suggestedName: String) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Export Bundle Here"
        panel.message = "Files are copied (originals untouched) along with a metadata sidecar."
        guard panel.runModal() == .OK, let baseURL = panel.url else { return }
        let destination = baseURL.appendingPathComponent("\(suggestedName) Bundle", isDirectory: true)

        Task {
            do {
                let exporter = BundleExporter(database: database, folderManager: folderManager)
                let summary = try await exporter.exportBundle(folderId: folderId, to: destination)
                alertMessage = "Bundle exported: \(summary.copied) files copied" +
                    (summary.skipped > 0 ? ", \(summary.skipped) skipped." : ".")
            } catch {
                alertMessage = "Bundle export failed: \(error.localizedDescription)"
            }
        }
    }

    func importMetadata() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.canChooseDirectories = false
        panel.title = "Import Poly Shelf Metadata"
        guard panel.runModal() == .OK, let url = panel.url else { return }

        // Conflict policy prompt (FR-9.2): merge (default) / overwrite / skip.
        let alert = NSAlert()
        alert.messageText = "How should existing metadata be handled?"
        alert.informativeText = "Merge keeps your local display names and combines tags (recommended). Overwrite replaces local metadata with the imported values. Skip leaves items that already have metadata untouched."
        alert.addButton(withTitle: "Merge")
        alert.addButton(withTitle: "Overwrite")
        alert.addButton(withTitle: "Skip Existing")
        alert.addButton(withTitle: "Cancel")
        let policy: Importer.ConflictPolicy
        switch alert.runModal() {
        case .alertFirstButtonReturn: policy = .merge
        case .alertSecondButtonReturn: policy = .overwrite
        case .alertThirdButtonReturn: policy = .skip
        default: return
        }

        Task {
            do {
                let data = try Data(contentsOf: url)
                let export = try Exporter.decode(data)
                let importer = Importer(database: self.database, folderManager: self.folderManager)
                let (matched, unmatched) = try await importer.matchFolders(export)

                var totals = Importer.Summary()
                for (exportedFolder, localFolder) in matched {
                    let summary = try await importer.importFolder(
                        exportedFolder, intoFolderId: localFolder.id!, policy: policy
                    )
                    totals.matchedByHash += summary.matchedByHash
                    totals.matchedByPath += summary.matchedByPath
                    totals.updated += summary.updated
                    totals.skippedExisting += summary.skippedExisting
                    totals.unmatched += summary.unmatched
                }

                var lines = ["Restored metadata for \(totals.updated) models (\(totals.matchedByHash) matched by content, \(totals.matchedByPath) by path)."]
                if totals.unmatched > 0 {
                    lines.append("\(totals.unmatched) entries had no matching file here.")
                }
                if !unmatched.isEmpty {
                    lines.append("No library folder found for: \(unmatched.map(\.displayName).joined(separator: ", ")). Add those folders and import again.")
                }
                alertMessage = lines.joined(separator: "\n")
            } catch {
                alertMessage = "Import failed: \(error.localizedDescription)"
            }
        }
    }
}
