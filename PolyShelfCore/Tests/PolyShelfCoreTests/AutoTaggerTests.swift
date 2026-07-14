import XCTest
import GRDB
@testable import PolyShelfCore

final class AutoTaggerTests: XCTestCase {
    private var database: DatabaseManager!
    private var tagger: AutoTagger!

    override func setUpWithError() throws {
        database = try DatabaseManager(inMemory: true)
        tagger = AutoTagger(database: database, dictionary: .load())
    }

    private func makeItem(
        name: String,
        relPath: String? = nil,
        ext: String? = nil,
        bbox: (Double, Double, Double)? = nil,
        triangles: Int64? = nil,
        parts: Int64? = nil,
        status: ItemStatus = .ok
    ) -> ItemRecord {
        ItemRecord(
            folderId: 1,
            relPath: relPath ?? name,
            originalName: name,
            ext: ext ?? (name as NSString).pathExtension.lowercased(),
            sizeBytes: 100,
            xxhash64: 1,
            status: status,
            bboxX: bbox?.0, bboxY: bbox?.1, bboxZ: bbox?.2,
            triangleCount: triangles,
            partCount: parts
        )
    }

    /// PRD acceptance: flexi_dragon_presupported.stl, 240 mm long →
    /// flexi (or articulated), presupported, large, stl.
    func testFlexiDragonAcceptanceCase() {
        let item = makeItem(
            name: "flexi_dragon_presupported.stl",
            bbox: (240, 80, 40)
        )
        let tags = tagger.computeTags(for: item)
        XCTAssertTrue(tags.contains("flexi") || tags.contains("articulated"), "got \(tags)")
        XCTAssertTrue(tags.contains("presupported"))
        XCTAssertTrue(tags.contains("large"), "240mm longest edge → large; got \(tags)")
        XCTAssertTrue(tags.contains("stl"))
        XCTAssertTrue(tags.contains("dragon"))
    }

    func testEveryItemGetsAtLeastFormatTag() {
        let item = makeItem(name: "x9q7z.weirdname.stl")
        XCTAssertTrue(tagger.computeTags(for: item).contains("stl"))
    }

    func testStructuralTags() {
        let multiPart = makeItem(name: "kit.3mf", parts: 4)
        XCTAssertTrue(tagger.computeTags(for: multiPart).contains("multi-part"))

        let highPoly = makeItem(name: "scan.stl", triangles: 2_000_000)
        XCTAssertTrue(tagger.computeTags(for: highPoly).contains("high-poly"))

        let flat = makeItem(name: "sign.stl", bbox: (120, 60, 3))
        XCTAssertTrue(tagger.computeTags(for: flat).contains("flat"))

        let sliced = makeItem(name: "benchy.gcode")
        let slicedTags = tagger.computeTags(for: sliced)
        XCTAssertTrue(slicedTags.contains("presliced"))
        XCTAssertTrue(slicedTags.contains("benchy"))

        let tiny = makeItem(name: "ring.stl", bbox: (12, 12, 4))
        XCTAssertTrue(tagger.computeTags(for: tiny).contains("tiny"))
    }

    func testFolderNameContributesTags() {
        let item = makeItem(
            name: "part_a.stl",
            relPath: "Printables/Gridfinity Organizers/part_a.stl"
        )
        let tags = tagger.computeTags(for: item)
        XCTAssertTrue(tags.contains("printables"))
        XCTAssertTrue(tags.contains("gridfinity"))
    }

    func testThingiversePatternDetection() {
        XCTAssertTrue(AutoTagger.sourceTags(filename: "cool_thing-4980354.stl", parentFolders: []).contains("thingiverse"))
        XCTAssertTrue(AutoTagger.sourceTags(filename: "a.stl", parentFolders: ["thing_123456"]).contains("thingiverse"))
        XCTAssertFalse(AutoTagger.sourceTags(filename: "something.stl", parentFolders: []).contains("thingiverse"))
    }

    func testPrintInPlaceMultiWordMatching() {
        for name in ["dragon-print-in-place.stl", "dragon_print_in_place.stl", "DragonPrintInPlace.stl"] {
            let tags = tagger.computeTags(for: makeItem(name: name))
            XCTAssertTrue(tags.contains("print-in-place"), "\(name) → \(tags)")
        }
    }

    // MARK: - Suppression (FR-5.4 acceptance)

    func testSuppressedAutoTagNeverResurrects() async throws {
        // Seed folder + item
        let itemId: Int64 = try await database.writer.write { db in
            var folder = FolderRecord(bookmarkData: Data(), displayName: "F", pathHint: "/tmp/f")
            try folder.insert(db)
            var item = ItemRecord(
                folderId: folder.id!, relPath: "vase_mode.stl", originalName: "vase_mode.stl",
                ext: "stl", sizeBytes: 10, xxhash64: 42
            )
            try item.insert(db)
            return item.id!
        }

        // First tagging pass applies "vase".
        await tagger.enrich(itemIds: [itemId], rootURL: URL(fileURLWithPath: "/tmp"))
        let store = TagStore(database: database)
        var names = try await store.tags(forItem: itemId).map(\.name)
        XCTAssertTrue(names.contains("vase"))

        // User removes the auto tag → suppressed.
        let vaseId = try await database.writer.read { db in
            try Int64.fetchOne(db, sql: "SELECT id FROM tags WHERE name = 'vase'")!
        }
        try await store.removeTag(tagId: vaseId, fromItem: itemId)

        // Rescan/re-tag: must NOT resurrect.
        await tagger.enrich(itemIds: [itemId], rootURL: URL(fileURLWithPath: "/tmp"))
        names = try await store.tags(forItem: itemId).map(\.name)
        XCTAssertFalse(names.contains("vase"), "suppressed auto tag resurrected")

        // And it's excluded from search.
        let hits = try await database.writer.read { db in
            try Int64.fetchAll(db, sql: "SELECT rowid FROM items_fts WHERE items_fts MATCH 'vase'")
        }
        XCTAssertTrue(hits.isEmpty)
    }

    func testUserTagRemovalDeletesRow() async throws {
        let itemId: Int64 = try await database.writer.write { db in
            var folder = FolderRecord(bookmarkData: Data(), displayName: "F", pathHint: "/tmp/f")
            try folder.insert(db)
            var item = ItemRecord(folderId: folder.id!, relPath: "a.stl", originalName: "a.stl", ext: "stl", sizeBytes: 1)
            try item.insert(db)
            return item.id!
        }
        let store = TagStore(database: database)
        try await store.addUserTag("favorite", toItem: itemId)
        let tagId = try await store.tags(forItem: itemId).first!.tagId
        try await store.removeTag(tagId: tagId, fromItem: itemId)

        let rows = try await database.writer.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM item_tags WHERE itemId = ?", arguments: [itemId])!
        }
        XCTAssertEqual(rows, 0, "user tag rows are deleted, not suppressed")
    }
}
