import Foundation
import GRDB

/// Owns the single SQLite database. All reads/writes go through this type.
/// UI observes queries via GRDB ValueObservation.
public final class DatabaseManager: Sendable {
    /// DatabasePool on disk (app), DatabaseQueue in memory (tests).
    public let writer: any DatabaseWriter

    /// Opens (creating if needed) the library database at the given URL.
    public init(databaseURL: URL) throws {
        try FileManager.default.createDirectory(
            at: databaseURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        var config = Configuration()
        config.foreignKeysEnabled = true
        writer = try DatabasePool(path: databaseURL.path, configuration: config)
        try Self.migrator.migrate(writer)
    }

    /// In-memory database for tests.
    public init(inMemory: Bool) throws {
        precondition(inMemory)
        var config = Configuration()
        config.foreignKeysEnabled = true
        writer = try DatabaseQueue(configuration: config)
        try Self.migrator.migrate(writer)
    }

    // MARK: - Schema

    static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()

        migrator.registerMigration("v1") { db in
            try db.create(table: "folders") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("bookmarkData", .blob).notNull()
                t.column("displayName", .text).notNull()
                t.column("pathHint", .text).notNull()
                t.column("addedAt", .datetime).notNull()
                t.column("settingsJson", .text)
                t.column("detachedAt", .datetime)
            }

            try db.create(table: "items") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("folderId", .integer).notNull()
                    .references("folders", onDelete: .cascade)
                t.column("relPath", .text).notNull()
                t.column("originalName", .text).notNull()
                t.column("displayName", .text)
                t.column("ext", .text).notNull()
                t.column("sizeBytes", .integer).notNull()
                t.column("createdAt", .datetime)
                t.column("modifiedAt", .datetime)
                t.column("xxhash64", .integer)
                t.column("inode", .integer)
                t.column("sha256", .text)
                t.column("status", .text).notNull().defaults(to: ItemStatus.ok.rawValue)
                t.column("missingSince", .datetime)
                t.column("bboxX", .double)
                t.column("bboxY", .double)
                t.column("bboxZ", .double)
                t.column("triangleCount", .integer)
                t.column("partCount", .integer)
                t.column("notes", .text)
                t.column("aiDescription", .text)
                t.column("aiSuggestedName", .text)
                t.column("indexedAt", .datetime).notNull()
                t.uniqueKey(["folderId", "relPath"])
            }
            try db.create(index: "idx_items_ext", on: "items", columns: ["ext"])
            try db.create(index: "idx_items_sha256", on: "items", columns: ["sha256"])
            try db.create(index: "idx_items_status", on: "items", columns: ["status"])

            try db.create(table: "tags") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("name", .text).notNull().unique().collate(.nocase)
                t.column("kind", .text).notNull()
            }

            try db.create(table: "item_tags") { t in
                t.column("itemId", .integer).notNull()
                    .references("items", onDelete: .cascade)
                t.column("tagId", .integer).notNull()
                    .references("tags", onDelete: .cascade)
                t.column("provenance", .text).notNull()
                t.column("suppressed", .boolean).notNull().defaults(to: false)
                t.primaryKey(["itemId", "tagId"])
            }

            try db.create(table: "saved_searches") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("name", .text).notNull()
                t.column("queryJson", .text).notNull()
                t.column("createdAt", .datetime).notNull()
            }

            // Standalone FTS5 table, rowid == items.id. Kept in sync manually
            // (same transaction as item/tag writes) because tags are a
            // denormalized aggregate that triggers can't maintain cleanly.
            try db.execute(sql: """
                CREATE VIRTUAL TABLE items_fts USING fts5(
                    display_name,
                    original_name,
                    notes,
                    rel_path,
                    tags,
                    tokenize = 'unicode61 remove_diacritics 2',
                    prefix = '2 3 4'
                )
                """)
        }

        return migrator
    }

    // MARK: - FTS sync

    /// Rebuilds the FTS row for the given items inside an open transaction.
    /// Must be called after any change to an item's names, notes, or tags.
    public static func refreshFTS(_ db: Database, itemIds: [Int64]) throws {
        guard !itemIds.isEmpty else { return }
        for itemId in itemIds {
            try db.execute(sql: "DELETE FROM items_fts WHERE rowid = ?", arguments: [itemId])
            guard let item = try ItemRecord.fetchOne(db, key: itemId) else { continue }
            let tags = try String.fetchAll(db, sql: """
                SELECT tags.name FROM tags
                JOIN item_tags ON item_tags.tagId = tags.id
                WHERE item_tags.itemId = ? AND item_tags.suppressed = 0
                """, arguments: [itemId])
            try db.execute(
                sql: """
                    INSERT INTO items_fts(rowid, display_name, original_name, notes, rel_path, tags)
                    VALUES (?, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    itemId,
                    item.displayName ?? "",
                    item.originalName,
                    item.notes ?? "",
                    item.relPath,
                    tags.joined(separator: " "),
                ]
            )
        }
    }
}
