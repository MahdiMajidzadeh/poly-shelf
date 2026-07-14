import Foundation
import GRDB

/// Retention for missing files (edge case: metadata kept for 30 days,
/// configurable; user can relink — which happens automatically via hash/inode
/// rename matching on rescan — or purge).
public enum MissingItemPurge {
    public static let defaultRetentionDays = 30

    /// Deletes items that have been missing longer than the retention window.
    /// Returns the number purged. Call at launch and after rescans.
    @discardableResult
    public static func purgeExpired(
        database: DatabaseManager,
        retentionDays: Int = defaultRetentionDays
    ) async throws -> Int {
        guard retentionDays > 0 else { return 0 } // 0 → keep forever
        let cutoff = Calendar.current.date(byAdding: .day, value: -retentionDays, to: Date())!
        return try await database.writer.write { db in
            let ids = try Int64.fetchAll(
                db,
                sql: "SELECT id FROM items WHERE status = 'missing' AND missingSince < ?",
                arguments: [cutoff]
            )
            for id in ids {
                try db.execute(sql: "DELETE FROM items_fts WHERE rowid = ?", arguments: [id])
            }
            try db.execute(
                sql: "DELETE FROM items WHERE status = 'missing' AND missingSince < ?",
                arguments: [cutoff]
            )
            return ids.count
        }
    }

    /// Immediate user-driven purge of one missing item.
    public static func purge(itemId: Int64, database: DatabaseManager) async throws {
        try await database.writer.write { db in
            try db.execute(sql: "DELETE FROM items_fts WHERE rowid = ?", arguments: [itemId])
            try db.execute(sql: "DELETE FROM items WHERE id = ?", arguments: [itemId])
        }
    }
}
