import XCTest
import GRDB
@testable import PolyShelfCore

final class DatabaseManagerTests: XCTestCase {
    func testMigrationCreatesSchema() throws {
        let manager = try DatabaseManager(inMemory: true)
        try manager.writer.read { db in
            for table in ["folders", "items", "tags", "item_tags"] {
                XCTAssertTrue(try db.tableExists(table), "missing table \(table)")
            }
            XCTAssertTrue(try db.tableExists("items_fts"), "missing FTS table")
        }
    }

    func testInsertItemAndSearchViaFTS() throws {
        let manager = try DatabaseManager(inMemory: true)
        try manager.writer.write { db in
            var folder = FolderRecord(bookmarkData: Data(), displayName: "3D Models", pathHint: "/tmp/models")
            try folder.insert(db)
            var item = ItemRecord(
                folderId: folder.id!,
                relPath: "dragons/flexi_dragon_presupported.stl",
                originalName: "flexi_dragon_presupported.stl",
                ext: "stl",
                sizeBytes: 1234
            )
            try item.insert(db)
            item.displayName = "Articulated Dragon — small"
            try item.update(db)

            var tag = TagRecord(name: "flexi", kind: .auto)
            try tag.insert(db)
            try ItemTagRecord(itemId: item.id!, tagId: tag.id!, provenance: .auto).insert(db)

            try DatabaseManager.refreshFTS(db, itemIds: [item.id!])
        }

        try manager.writer.read { db in
            // Prefix match on display name, diacritic-insensitive
            let byDisplay = try Int64.fetchAll(db, sql: "SELECT rowid FROM items_fts WHERE items_fts MATCH ?", arguments: ["articul*"])
            XCTAssertEqual(byDisplay.count, 1)
            // Match on original filename token
            let byOriginal = try Int64.fetchAll(db, sql: "SELECT rowid FROM items_fts WHERE items_fts MATCH ?", arguments: ["presupported"])
            XCTAssertEqual(byOriginal.count, 1)
            // Match on tag
            let byTag = try Int64.fetchAll(db, sql: "SELECT rowid FROM items_fts WHERE items_fts MATCH ?", arguments: ["flexi"])
            XCTAssertEqual(byTag.count, 1)
        }
    }

    func testSuppressedTagExcludedFromFTS() throws {
        let manager = try DatabaseManager(inMemory: true)
        try manager.writer.write { db in
            var folder = FolderRecord(bookmarkData: Data(), displayName: "M", pathHint: "/tmp/m")
            try folder.insert(db)
            var item = ItemRecord(folderId: folder.id!, relPath: "a.stl", originalName: "a.stl", ext: "stl", sizeBytes: 1)
            try item.insert(db)
            var tag = TagRecord(name: "vase", kind: .auto)
            try tag.insert(db)
            try ItemTagRecord(itemId: item.id!, tagId: tag.id!, provenance: .auto, suppressed: true).insert(db)
            try DatabaseManager.refreshFTS(db, itemIds: [item.id!])

            let hits = try Int64.fetchAll(db, sql: "SELECT rowid FROM items_fts WHERE items_fts MATCH ?", arguments: ["vase"])
            XCTAssertTrue(hits.isEmpty, "suppressed tag must not be searchable")
        }
    }

    func testFormatRegistryDefaults() throws {
        XCTAssertEqual(FormatRegistry.spec(forExtension: "STL")?.group, .printMesh)
        XCTAssertTrue(FormatRegistry.defaultEnabledExtensions.contains("gcode"))
        XCTAssertFalse(FormatRegistry.defaultEnabledExtensions.contains("step"))
        // No duplicate extensions in the registry
        XCTAssertEqual(FormatRegistry.all.count, Set(FormatRegistry.all.map(\.ext)).count)
    }
}
