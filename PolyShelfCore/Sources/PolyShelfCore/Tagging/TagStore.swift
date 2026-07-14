import Foundation
import GRDB

/// A tag as shown on one item, with its per-item provenance.
public struct ItemTag: Identifiable, Equatable, Sendable {
    public var id: Int64 { tagId }
    public let tagId: Int64
    public let name: String
    public let provenance: TagProvenance

    public init(tagId: Int64, name: String, provenance: TagProvenance) {
        self.tagId = tagId
        self.name = name
        self.provenance = provenance
    }
}

public struct TagCount: Identifiable, Equatable, Sendable {
    public var id: Int64 { tagId }
    public let tagId: Int64
    public let name: String
    public let count: Int

    public init(tagId: Int64, name: String, count: Int) {
        self.tagId = tagId
        self.name = name
        self.count = count
    }
}

/// User-facing tag operations (FR-5.4): add manual tags, remove any tag —
/// removing an auto/ai tag suppresses it (never resurrected by rescans),
/// removing a user tag deletes the row.
public struct TagStore: Sendable {
    private let database: DatabaseManager

    public init(database: DatabaseManager) {
        self.database = database
    }

    public func tags(forItem itemId: Int64) async throws -> [ItemTag] {
        try await database.writer.read { db in
            try Self.fetchTags(db, itemId: itemId)
        }
    }

    static func fetchTags(_ db: Database, itemId: Int64) throws -> [ItemTag] {
        let rows = try Row.fetchAll(db, sql: """
            SELECT tags.id AS tagId, tags.name AS name, item_tags.provenance AS provenance
            FROM tags JOIN item_tags ON item_tags.tagId = tags.id
            WHERE item_tags.itemId = ? AND item_tags.suppressed = 0
            ORDER BY item_tags.provenance = 'user' DESC, tags.name
            """, arguments: [itemId])
        return rows.map {
            ItemTag(
                tagId: $0["tagId"],
                name: $0["name"],
                provenance: TagProvenance(rawValue: $0["provenance"]) ?? .auto
            )
        }
    }

    public func addUserTag(_ name: String, toItem itemId: Int64) async throws {
        let normalized = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else { return }
        try await database.writer.write { db in
            try db.execute(
                sql: "INSERT INTO tags (name, kind) VALUES (?, ?) ON CONFLICT(name) DO NOTHING",
                arguments: [normalized, TagProvenance.user.rawValue]
            )
            let tagId = try Int64.fetchOne(db, sql: "SELECT id FROM tags WHERE name = ?", arguments: [normalized])!
            // Upsert: un-suppresses and takes user provenance if it existed as auto.
            try db.execute(
                sql: """
                    INSERT INTO item_tags (itemId, tagId, provenance, suppressed)
                    VALUES (?, ?, 'user', 0)
                    ON CONFLICT(itemId, tagId)
                    DO UPDATE SET provenance = 'user', suppressed = 0
                    """,
                arguments: [itemId, tagId]
            )
            try DatabaseManager.refreshFTS(db, itemIds: [itemId])
        }
    }

    public func removeTag(tagId: Int64, fromItem itemId: Int64) async throws {
        try await database.writer.write { db in
            let provenance = try String.fetchOne(
                db,
                sql: "SELECT provenance FROM item_tags WHERE itemId = ? AND tagId = ?",
                arguments: [itemId, tagId]
            )
            switch provenance.flatMap(TagProvenance.init(rawValue:)) {
            case .user:
                try db.execute(
                    sql: "DELETE FROM item_tags WHERE itemId = ? AND tagId = ?",
                    arguments: [itemId, tagId]
                )
            case .auto, .ai:
                try db.execute(
                    sql: "UPDATE item_tags SET suppressed = 1 WHERE itemId = ? AND tagId = ?",
                    arguments: [itemId, tagId]
                )
            case nil:
                return
            }
            try DatabaseManager.refreshFTS(db, itemIds: [itemId])
        }
    }

    /// Renames a tag everywhere; renaming onto an existing tag merges into it
    /// (P1: tag rename/merge). Suppression states survive the merge.
    public func renameTag(tagId: Int64, to newName: String) async throws {
        let normalized = newName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else { return }
        try await database.writer.write { db in
            let existingTarget = try Int64.fetchOne(
                db, sql: "SELECT id FROM tags WHERE name = ? AND id != ?",
                arguments: [normalized, tagId]
            )
            var affectedItems: [Int64] = try Int64.fetchAll(
                db, sql: "SELECT itemId FROM item_tags WHERE tagId = ?", arguments: [tagId]
            )
            if let targetId = existingTarget {
                // Merge: move rows over; rows already carrying the target tag
                // just lose the old one (their state on the target wins).
                affectedItems += try Int64.fetchAll(
                    db, sql: "SELECT itemId FROM item_tags WHERE tagId = ?", arguments: [targetId]
                )
                try db.execute(
                    sql: "UPDATE OR IGNORE item_tags SET tagId = ? WHERE tagId = ?",
                    arguments: [targetId, tagId]
                )
                try db.execute(sql: "DELETE FROM item_tags WHERE tagId = ?", arguments: [tagId])
                try db.execute(sql: "DELETE FROM tags WHERE id = ?", arguments: [tagId])
            } else {
                try db.execute(sql: "UPDATE tags SET name = ? WHERE id = ?", arguments: [normalized, tagId])
            }
            try DatabaseManager.refreshFTS(db, itemIds: Array(Set(affectedItems)))
        }
    }

    /// Tag list with visible-item counts for the sidebar (FR-8.2).
    public static func tagCountsRequest(_ db: Database, enabledExtensions: Set<String>) throws -> [TagCount] {
        guard !enabledExtensions.isEmpty else { return [] }
        let placeholders = databaseQuestionMarks(count: enabledExtensions.count)
        let rows = try Row.fetchAll(db, sql: """
            SELECT tags.id AS tagId, tags.name AS name, COUNT(*) AS count
            FROM tags
            JOIN item_tags ON item_tags.tagId = tags.id AND item_tags.suppressed = 0
            JOIN items ON items.id = item_tags.itemId AND items.ext IN (\(placeholders))
            GROUP BY tags.id
            HAVING count > 0
            ORDER BY count DESC, name
            """, arguments: StatementArguments(Array(enabledExtensions)))
        return rows.map { TagCount(tagId: $0["tagId"], name: $0["name"], count: $0["count"]) }
    }
}
