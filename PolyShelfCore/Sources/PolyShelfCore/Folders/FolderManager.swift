import Foundation
import GRDB

public enum AddFolderResult: Equatable, Sendable {
    case added(folderId: Int64)
    /// Re-attached a previously removed folder whose metadata was kept.
    case reattached(folderId: Int64)
    /// The chosen folder is inside an already-watched folder (FR-1.4) — indexed once, not added.
    case nestedInsideExisting(existingDisplayName: String)
    /// The chosen folder contains already-watched folders; caller should ask
    /// the user before absorbing them.
    case containsExisting(existingDisplayNames: [String])
    case alreadyAdded
}

/// Adds/removes root folders and owns security-scoped bookmark lifecycle.
public final class FolderManager: Sendable {
    private let database: DatabaseManager

    public init(database: DatabaseManager) {
        self.database = database
    }

    // MARK: - Add

    /// `url` must come from NSOpenPanel or a drop (i.e. carry sandbox access).
    public func addFolder(at url: URL) throws -> AddFolderResult {
        let newPath = url.standardizedFileURL.path

        let active: [FolderRecord] = try database.writer.read { db in
            try FolderRecord.filter(Column("detachedAt") == nil).fetchAll(db)
        }

        // Exact duplicate / nesting checks against live folders (FR-1.4).
        for folder in active {
            let existing = folder.pathHint
            if existing == newPath { return .alreadyAdded }
            if newPath.hasPrefix(existing + "/") {
                return .nestedInsideExisting(existingDisplayName: folder.displayName)
            }
        }
        let contained = active.filter { $0.pathHint.hasPrefix(newPath + "/") }
        if !contained.isEmpty {
            return .containsExisting(existingDisplayNames: contained.map(\.displayName))
        }

        let bookmark = try url.bookmarkData(
            options: .withSecurityScope,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )

        // Re-attach a detached folder with the same path (fast path; hash-based
        // re-attach for reorganized folders happens through import matching).
        let detachedMatch: FolderRecord? = try database.writer.read { db in
            try FolderRecord
                .filter(Column("detachedAt") != nil && Column("pathHint") == newPath)
                .fetchOne(db)
        }
        if var folder = detachedMatch {
            folder.bookmarkData = bookmark
            folder.detachedAt = nil
            let updated = folder
            try database.writer.write { db in try updated.update(db) }
            return .reattached(folderId: folder.id!)
        }

        var folder = FolderRecord(
            bookmarkData: bookmark,
            displayName: url.lastPathComponent,
            pathHint: newPath
        )
        try database.writer.write { db in try folder.insert(db) }
        return .added(folderId: folder.id!)
    }

    // MARK: - Remove

    public func removeFolder(id: Int64, keepMetadata: Bool) throws {
        try database.writer.write { db in
            if keepMetadata {
                try db.execute(
                    sql: "UPDATE folders SET detachedAt = ? WHERE id = ?",
                    arguments: [Date(), id]
                )
            } else {
                // Cascades to items and item_tags; FTS rows cleaned explicitly.
                let itemIds = try Int64.fetchAll(db, sql: "SELECT id FROM items WHERE folderId = ?", arguments: [id])
                try FolderRecord.deleteOne(db, key: id)
                for itemId in itemIds {
                    try db.execute(sql: "DELETE FROM items_fts WHERE rowid = ?", arguments: [itemId])
                }
            }
        }
    }

    // MARK: - Access

    public enum FolderAccess {
        case available(URL)
        /// Bookmark resolved but the volume/path isn't reachable (external drive unmounted).
        case offline
        /// Bookmark data is invalid (folder gone for good, or permission revoked).
        case invalid
    }

    /// Resolves the folder's bookmark and starts security-scoped access.
    /// Caller must balance with `stopAccessingSecurityScopedResource()`.
    public func beginAccess(_ folder: FolderRecord) -> FolderAccess {
        var stale = false
        guard let url = try? URL(
            resolvingBookmarkData: folder.bookmarkData,
            options: .withSecurityScope,
            relativeTo: nil,
            bookmarkDataIsStale: &stale
        ) else {
            return .invalid
        }
        guard url.startAccessingSecurityScopedResource() else { return .invalid }
        if stale {
            // Refresh the bookmark while we hold access; best-effort.
            if let fresh = try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil),
               let id = folder.id {
                try? database.writer.write { db in
                    try db.execute(sql: "UPDATE folders SET bookmarkData = ? WHERE id = ?", arguments: [fresh, id])
                }
            }
        }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else {
            url.stopAccessingSecurityScopedResource()
            return .offline
        }
        return .available(url)
    }
}
