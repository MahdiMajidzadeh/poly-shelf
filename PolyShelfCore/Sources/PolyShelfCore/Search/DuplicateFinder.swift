import Foundation
import GRDB

public struct DuplicateGroup: Identifiable, Equatable, Sendable {
    public var id: String { sha256 }
    public let sha256: String
    public let items: [ItemRecord]

    public init(sha256: String, items: [ItemRecord]) {
        self.sha256 = sha256
        self.items = items
    }
}

/// Duplicate detection (FR-10.1): groups by SHA-256. Report-only — deleting
/// stays in Finder, consistent with the non-destructive rule.
public struct DuplicateFinder: Sendable {
    private let database: DatabaseManager
    private let folderManager: FolderManager

    public init(database: DatabaseManager, folderManager: FolderManager) {
        self.database = database
        self.folderManager = folderManager
    }

    /// Computes any missing SHA-256s (size-collision candidates only — a
    /// unique file size can't have a duplicate), then returns groups of
    /// content-identical items across all folders.
    public func findDuplicates() async throws -> [DuplicateGroup] {
        // Only files sharing a size with another file can be duplicates.
        let candidates: [ItemRecord] = try await database.writer.read { db in
            try ItemRecord.fetchAll(db, sql: """
                SELECT * FROM items
                WHERE status = 'ok' AND sizeBytes IN (
                    SELECT sizeBytes FROM items WHERE status = 'ok'
                    GROUP BY sizeBytes HAVING COUNT(*) > 1
                )
                """)
        }

        // Hash unhashed candidates, folder by folder (one access scope each).
        let byFolder = Dictionary(grouping: candidates.filter { $0.sha256 == nil }, by: \.folderId)
        for (folderId, items) in byFolder {
            guard let folder = try await database.writer.read({ db in
                try FolderRecord.fetchOne(db, key: folderId)
            }), case .available(let rootURL) = folderManager.beginAccess(folder) else { continue }
            defer { rootURL.stopAccessingSecurityScopedResource() }
            for item in items {
                _ = await SHA256Hasher.ensureSHA256(item: item, rootURL: rootURL, database: database)
            }
        }

        let groups: [DuplicateGroup] = try await database.writer.read { db in
            let rows = try ItemRecord.fetchAll(db, sql: """
                SELECT * FROM items
                WHERE status = 'ok' AND sha256 IN (
                    SELECT sha256 FROM items
                    WHERE sha256 IS NOT NULL AND status = 'ok'
                    GROUP BY sha256 HAVING COUNT(*) > 1
                )
                ORDER BY sha256, folderId, relPath
                """)
            return Dictionary(grouping: rows, by: { $0.sha256! })
                .map { DuplicateGroup(sha256: $0.key, items: $0.value) }
                .sorted { $0.items[0].sizeBytes > $1.items[0].sizeBytes }
        }
        return groups
    }
}
