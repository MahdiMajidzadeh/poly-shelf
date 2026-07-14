import XCTest
import GRDB
@testable import PolyShelfCore

final class LibraryQueryTests: XCTestCase {
    private var database: DatabaseManager!
    private var folderId: Int64!

    override func setUpWithError() throws {
        database = try DatabaseManager(inMemory: true)
        folderId = try database.writer.write { db in
            var folder = FolderRecord(bookmarkData: Data(), displayName: "Models", pathHint: "/tmp/models")
            try folder.insert(db)
            return folder.id!
        }
    }

    @discardableResult
    private func seedItem(
        _ name: String,
        displayName: String? = nil,
        ext: String? = nil,
        tags: [String] = [],
        notes: String? = nil,
        status: ItemStatus = .ok,
        size: Int64 = 100
    ) throws -> Int64 {
        try database.writer.write { db in
            var item = ItemRecord(
                folderId: folderId,
                relPath: name,
                originalName: name,
                displayName: displayName,
                ext: ext ?? (name as NSString).pathExtension.lowercased(),
                sizeBytes: size,
                xxhash64: Int64(name.hashValue),
                status: status,
                notes: notes
            )
            try item.insert(db)
            for tag in tags {
                try db.execute(sql: "INSERT INTO tags (name, kind) VALUES (?, 'auto') ON CONFLICT(name) DO NOTHING", arguments: [tag])
                let tagId = try Int64.fetchOne(db, sql: "SELECT id FROM tags WHERE name = ?", arguments: [tag])!
                try db.execute(
                    sql: "INSERT INTO item_tags (itemId, tagId, provenance, suppressed) VALUES (?, ?, 'auto', 0)",
                    arguments: [item.id!, tagId]
                )
            }
            try DatabaseManager.refreshFTS(db, itemIds: [item.id!])
            return item.id!
        }
    }

    private func run(_ configure: (inout LibraryQuery) -> Void) throws -> [ItemRecord] {
        var query = LibraryQuery()
        query.formats = FormatRegistry.defaultEnabledExtensions
        configure(&query)
        return try database.writer.read { db in
            try LibraryQuery.fetch(db, query: query)
        }
    }

    func testSearchMatchesDisplayAndOriginalName() throws {
        try seedItem("dragon_v3_final_FINAL.stl", displayName: "Articulated Dragon — small")
        try seedItem("benchy.stl")

        XCTAssertEqual(try run { $0.searchText = "articul" }.count, 1, "prefix on display name")
        XCTAssertEqual(try run { $0.searchText = "dragon" }.count, 1, "original filename token")
        XCTAssertEqual(try run { $0.searchText = "final" }.count, 1)
        XCTAssertEqual(try run { $0.searchText = "artichoke" }.count, 0)
    }

    func testSearchMatchesTagsAndNotes() throws {
        try seedItem("a.stl", tags: ["vase", "calibration"])
        try seedItem("b.stl", notes: "prints best at 0.2mm layer height")

        XCTAssertEqual(try run { $0.searchText = "vase" }.count, 1)
        XCTAssertEqual(try run { $0.searchText = "layer" }.count, 1)
    }

    func testDiacriticInsensitive() throws {
        try seedItem("café_sign.stl")
        XCTAssertEqual(try run { $0.searchText = "cafe" }.count, 1)
    }

    func testFormatFilterHidesDisabled() throws {
        try seedItem("part.stl")
        try seedItem("print.gcode")
        let onlyStl = try run { $0.formats = ["stl"] }
        XCTAssertEqual(onlyStl.map(\.originalName), ["part.stl"])
    }

    func testMultiTagANDFilter() throws {
        let ids = try database.writer.read { db in
            try Row.fetchAll(db, sql: "SELECT id, name FROM tags")
        }
        _ = ids
        try seedItem("a.stl", tags: ["flexi", "large"])
        try seedItem("b.stl", tags: ["flexi"])
        let tagIds = try database.writer.read { db in
            try Int64.fetchAll(db, sql: "SELECT id FROM tags WHERE name IN ('flexi','large') ORDER BY name")
        }
        let both = try run { $0.requiredTagIds = tagIds }
        XCTAssertEqual(both.map(\.originalName), ["a.stl"], "AND semantics")
    }

    func testMissingOfflineScope() throws {
        try seedItem("here.stl")
        try seedItem("gone.stl", status: .missing)
        XCTAssertEqual(try run { $0.scope = .all }.map(\.originalName), ["here.stl"])
        XCTAssertEqual(try run { $0.scope = .missingOffline }.map(\.originalName), ["gone.stl"])
    }

    func testSortBySize() throws {
        try seedItem("small.stl", size: 10)
        try seedItem("big.stl", size: 1000)
        let sorted = try run { $0.sort = .fileSize; $0.sortDescending = true }
        XCTAssertEqual(sorted.map(\.originalName), ["big.stl", "small.stl"])
    }

    func testMatchExpressionSanitization() {
        XCTAssertNil(LibraryQuery.ftsMatchExpression("  "))
        XCTAssertEqual(LibraryQuery.ftsMatchExpression("drag arti"), "\"drag\"* \"arti\"*")
        // FTS syntax characters must not leak through as operators.
        XCTAssertEqual(LibraryQuery.ftsMatchExpression("a AND* (b"), "\"a\"* \"AND\"* \"b\"*")
    }

    /// FR-8 acceptance: <100 ms per keystroke at 10k items.
    func testSearchLatencyAt10kItems() throws {
        try database.writer.write { db in
            for i in 0..<10_000 {
                var item = ItemRecord(
                    folderId: folderId,
                    relPath: "bulk/model_\(i)_dragon_articulated_v\(i % 9).stl",
                    originalName: "model_\(i)_dragon_articulated_v\(i % 9).stl",
                    ext: "stl",
                    sizeBytes: Int64(i),
                    xxhash64: Int64(i)
                )
                try item.insert(db)
            }
            let ids = try Int64.fetchAll(db, sql: "SELECT id FROM items")
            try DatabaseManager.refreshFTS(db, itemIds: ids)
        }

        var query = LibraryQuery()
        query.formats = ["stl"]
        query.searchText = "dragon arti"

        let start = Date()
        let results = try database.writer.read { db in
            try LibraryQuery.fetch(db, query: query)
        }
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertEqual(results.count, 10_000)
        XCTAssertLessThan(elapsed, 0.1, "search took \(elapsed * 1000) ms")
    }
}
