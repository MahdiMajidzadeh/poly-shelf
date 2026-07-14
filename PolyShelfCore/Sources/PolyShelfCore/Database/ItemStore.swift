import Foundation
import GRDB

/// Focused write API for item metadata edits. Every write here touches ONLY
/// the database — never the file on disk (FR-6.3: the non-destructive rule).
public struct ItemStore: Sendable {
    private let database: DatabaseManager

    public init(database: DatabaseManager) {
        self.database = database
    }

    /// Virtual rename (FR-6.1/6.2). Empty or whitespace-only clears back to
    /// the original name (FR-6.4).
    public func setDisplayName(_ name: String?, itemId: Int64) async throws {
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        let value = (trimmed?.isEmpty ?? true) ? nil : trimmed
        try await database.writer.write { db in
            try db.execute(
                sql: "UPDATE items SET displayName = ? WHERE id = ?",
                arguments: [value, itemId]
            )
            try DatabaseManager.refreshFTS(db, itemIds: [itemId])
        }
    }

    public func setNotes(_ notes: String?, itemId: Int64) async throws {
        let value = (notes?.isEmpty ?? true) ? nil : notes
        try await database.writer.write { db in
            try db.execute(
                sql: "UPDATE items SET notes = ? WHERE id = ?",
                arguments: [value, itemId]
            )
            try DatabaseManager.refreshFTS(db, itemIds: [itemId])
        }
    }

    /// Resolves an item's absolute file URL inside an active security scope.
    /// Returns nil if the folder is offline/detached. Caller must call
    /// `stopAccessingSecurityScopedResource()` on the folder root when done.
    public func beginFileAccess(item: ItemRecord, folderManager: FolderManager) async throws -> (root: URL, file: URL)? {
        guard let folder = try await database.writer.read({ db in
            try FolderRecord.fetchOne(db, key: item.folderId)
        }) else { return nil }
        guard case .available(let rootURL) = folderManager.beginAccess(folder) else { return nil }
        return (rootURL, rootURL.appendingPathComponent(item.relPath))
    }
}
