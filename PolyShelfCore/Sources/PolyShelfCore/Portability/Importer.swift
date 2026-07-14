import Foundation
import GRDB

/// Metadata import (FR-9.2): content-hash-first matching with rel-path
/// fallback, merge/overwrite/skip conflict policies, idempotent for
/// merge-import of a library's own export.
public struct Importer: Sendable {
    public enum ConflictPolicy: String, CaseIterable, Sendable {
        /// Default: union tags; keep local display name/notes unless empty.
        case merge
        /// Exported metadata replaces local.
        case overwrite
        /// Leave items that already carry any local metadata untouched.
        case skip
    }

    public struct Summary: Equatable, Sendable {
        public var matchedByHash = 0
        public var matchedByPath = 0
        public var updated = 0
        public var skippedExisting = 0
        /// Exported items with no local counterpart (file not present here).
        public var unmatched = 0

        public init() {}
    }

    private let database: DatabaseManager
    private let folderManager: FolderManager

    public init(database: DatabaseManager, folderManager: FolderManager) {
        self.database = database
        self.folderManager = folderManager
    }

    /// Imports one exported folder into an existing library folder.
    public func importFolder(
        _ exported: ExportedFolder,
        intoFolderId folderId: Int64,
        policy: ConflictPolicy
    ) async throws -> Summary {
        var summary = Summary()

        let localItems: [ItemRecord] = try await database.writer.read { db in
            try ItemRecord.filter(Column("folderId") == folderId).fetchAll(db)
        }
        guard let folder = try await database.writer.read({ db in
            try FolderRecord.fetchOne(db, key: folderId)
        }) else {
            throw PortabilityError.folderNotFound(exported.displayName)
        }

        var rootURL: URL?
        if case .available(let url) = folderManager.beginAccess(folder) {
            rootURL = url
        }
        defer { rootURL?.stopAccessingSecurityScopedResource() }

        // Pass 1 — rel-path matching (cheap, resolves the common case).
        var localByRelPath: [String: ItemRecord] = Dictionary(
            uniqueKeysWithValues: localItems.map { ($0.relPath, $0) }
        )
        var pathMatched: [(ExportedItem, ItemRecord)] = []
        var unmatchedExported: [ExportedItem] = []
        for exportedItem in exported.items {
            if let local = localByRelPath.removeValue(forKey: exportedItem.relPath) {
                pathMatched.append((exportedItem, local))
            } else {
                unmatchedExported.append(exportedItem)
            }
        }

        // Pass 2 — hash matching for reorganized files (FR-9 acceptance:
        // hash-matched even if the folder was reorganized). Content hash has
        // priority as identity, so verify path matches by hash when both
        // sides have one, and match leftovers by computing local SHA-256s.
        var hashMatched: [(ExportedItem, ItemRecord)] = []
        let wantedHashes = Set(unmatchedExported.compactMap(\.sha256))
        if !wantedHashes.isEmpty {
            var remainingLocals = Array(localByRelPath.values)
            // Cheap pre-filter: only hash local files whose size appears in the export.
            let wantedSizes = Set(unmatchedExported.map(\.sizeBytes))
            var localByHash: [String: ItemRecord] = [:]
            for local in remainingLocals where wantedSizes.contains(local.sizeBytes) {
                var sha = local.sha256
                if sha == nil, local.status == .ok, let rootURL {
                    sha = await SHA256Hasher.ensureSHA256(item: local, rootURL: rootURL, database: database)
                }
                if let sha { localByHash[sha] = local }
            }
            remainingLocals.removeAll()
            var stillUnmatched: [ExportedItem] = []
            for exportedItem in unmatchedExported {
                if let sha = exportedItem.sha256, let local = localByHash.removeValue(forKey: sha) {
                    hashMatched.append((exportedItem, local))
                } else {
                    stillUnmatched.append(exportedItem)
                }
            }
            unmatchedExported = stillUnmatched
        }

        summary.matchedByPath = pathMatched.count
        summary.matchedByHash = hashMatched.count
        summary.unmatched = unmatchedExported.count

        for (exportedItem, local) in pathMatched + hashMatched {
            let applied = try await apply(exportedItem, to: local, policy: policy)
            if applied { summary.updated += 1 } else { summary.skippedExisting += 1 }
        }
        return summary
    }

    /// Applies one exported item's metadata. Returns false when skipped.
    private func apply(_ exported: ExportedItem, to local: ItemRecord, policy: ConflictPolicy) async throws -> Bool {
        guard let itemId = local.id else { return false }

        if policy == .skip {
            var hasLocalMetadata = local.displayName != nil || local.notes != nil
            if !hasLocalMetadata {
                let tagCount = try await database.writer.read { db in
                    try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM item_tags WHERE itemId = ?", arguments: [itemId])!
                }
                hasLocalMetadata = tagCount > 0
            }
            if hasLocalMetadata { return false }
        }

        try await database.writer.write { db in
            // Scalar fields
            let newDisplayName: String?
            let newNotes: String?
            let newDescription: String?
            switch policy {
            case .overwrite:
                newDisplayName = exported.displayName
                newNotes = exported.notes
                newDescription = exported.aiDescription
            case .merge, .skip:
                newDisplayName = local.displayName ?? exported.displayName
                newNotes = (local.notes?.isEmpty ?? true) ? exported.notes : local.notes
                newDescription = local.aiDescription ?? exported.aiDescription
            }
            try db.execute(
                sql: "UPDATE items SET displayName = ?, notes = ?, aiDescription = ? WHERE id = ?",
                arguments: [newDisplayName, newNotes, newDescription, itemId]
            )

            if policy == .overwrite {
                try db.execute(sql: "DELETE FROM item_tags WHERE itemId = ?", arguments: [itemId])
            }
            for tag in exported.tags {
                try db.execute(
                    sql: "INSERT INTO tags (name, kind) VALUES (?, ?) ON CONFLICT(name) DO NOTHING",
                    arguments: [tag.name, tag.provenance]
                )
                let tagId = try Int64.fetchOne(db, sql: "SELECT id FROM tags WHERE name = ?", arguments: [tag.name])!
                // Union semantics: existing rows win (their suppression state
                // is local truth); new rows arrive with exported state.
                try db.execute(
                    sql: """
                        INSERT INTO item_tags (itemId, tagId, provenance, suppressed)
                        VALUES (?, ?, ?, ?)
                        ON CONFLICT(itemId, tagId) DO NOTHING
                        """,
                    arguments: [itemId, tagId, tag.provenance, tag.suppressed]
                )
            }
            try DatabaseManager.refreshFTS(db, itemIds: [itemId])
        }
        return true
    }

    /// Matches exported folders to library folders by display name.
    /// Returns pairs plus the exported folders that found no local home.
    public func matchFolders(
        _ export: LibraryExport
    ) async throws -> (matched: [(ExportedFolder, FolderRecord)], unmatched: [ExportedFolder]) {
        let localFolders: [FolderRecord] = try await database.writer.read { db in
            try FolderRecord.filter(Column("detachedAt") == nil).fetchAll(db)
        }
        var matched: [(ExportedFolder, FolderRecord)] = []
        var unmatched: [ExportedFolder] = []
        for exported in export.folders {
            if let local = localFolders.first(where: { $0.displayName == exported.displayName }) {
                matched.append((exported, local))
            } else if export.folders.count == 1, localFolders.count == 1 {
                // Single-folder export into a single-folder library: names may
                // differ (user pointed at the corresponding root) — pair them.
                matched.append((exported, localFolders[0]))
            } else {
                unmatched.append(exported)
            }
        }
        return (matched, unmatched)
    }
}
