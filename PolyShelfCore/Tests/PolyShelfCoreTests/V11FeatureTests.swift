import XCTest
import GRDB
@testable import PolyShelfCore

final class V11FeatureTests: XCTestCase {
    private var tempRoot: URL!
    private var database: DatabaseManager!
    private var folderManager: FolderManager!
    private var scanner: LibraryScanner!

    override func setUpWithError() throws {
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("polyshelf-v11-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        database = try DatabaseManager(inMemory: true)
        folderManager = FolderManager(database: database)
        scanner = LibraryScanner(database: database, folderManager: folderManager)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempRoot)
    }

    private func write(_ relPath: String, _ contents: String) throws {
        let url = tempRoot.appendingPathComponent(relPath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try contents.data(using: .utf8)!.write(to: url)
    }

    private func addAndScan() async throws -> Int64 {
        guard case .added(let id) = try folderManager.addFolder(at: tempRoot) else { fatalError() }
        _ = try await scanner.scan(folderId: id, enabledExtensions: ["stl"])
        return id
    }

    // MARK: - Duplicates (FR-10.1)

    func testDuplicateGroups() async throws {
        try write("a/dragon.stl", "identical-content")
        try write("b/dragon_copy.stl", "identical-content")
        try write("unique.stl", "different-content!")
        _ = try await addAndScan()

        let finder = DuplicateFinder(database: database, folderManager: folderManager)
        let groups = try await finder.findDuplicates()
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].items.count, 2)
        XCTAssertEqual(
            Set(groups[0].items.map(\.relPath)),
            ["a/dragon.stl", "b/dragon_copy.stl"]
        )
    }

    func testNoDuplicatesInDistinctContent() async throws {
        try write("x.stl", "content-x")
        try write("y.stl", "content-yy")
        _ = try await addAndScan()
        let finder = DuplicateFinder(database: database, folderManager: folderManager)
        let groups = try await finder.findDuplicates()
        XCTAssertTrue(groups.isEmpty)
    }

    // MARK: - Tag rename/merge

    func testTagRename() async throws {
        try write("a.stl", "a")
        _ = try await addAndScan()
        let store = TagStore(database: database)
        let item = try await database.writer.read { try ItemRecord.fetchOne($0)! }
        try await store.addUserTag("dragonz", toItem: item.id!)
        let tagId = try await store.tags(forItem: item.id!).first { $0.name == "dragonz" }!.tagId

        try await store.renameTag(tagId: tagId, to: "dragons")
        let names = try await store.tags(forItem: item.id!).map(\.name)
        XCTAssertTrue(names.contains("dragons"))
        XCTAssertFalse(names.contains("dragonz"))
    }

    func testTagMergeOnRenameCollision() async throws {
        try write("a.stl", "a")
        try write("b.stl", "bb")
        _ = try await addAndScan()
        let store = TagStore(database: database)
        let items = try await database.writer.read { try ItemRecord.order(Column("relPath")).fetchAll($0) }
        try await store.addUserTag("flexy", toItem: items[0].id!)
        try await store.addUserTag("flexi", toItem: items[1].id!)
        let flexyId = try await store.tags(forItem: items[0].id!).first { $0.name == "flexy" }!.tagId

        try await store.renameTag(tagId: flexyId, to: "flexi")

        let tagsA = try await store.tags(forItem: items[0].id!).map(\.name)
        let tagsB = try await store.tags(forItem: items[1].id!).map(\.name)
        XCTAssertTrue(tagsA.contains("flexi"), "merged onto existing tag")
        XCTAssertTrue(tagsB.contains("flexi"))
        let flexyCount = try await database.writer.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM tags WHERE name = 'flexy'")!
        }
        XCTAssertEqual(flexyCount, 0, "old tag removed after merge")
    }

    // MARK: - Saved searches

    func testSavedSearchRoundTrip() async throws {
        var query = LibraryQuery()
        query.searchText = "dragon"
        query.formats = ["stl"]
        query.sort = .fileSize
        query.sortDescending = true

        let saved = try SavedSearch(name: "Big dragons", query: query)
        let restored = try await database.writer.write { db -> SavedSearch? in
            var record = saved
            try record.insert(db)
            return try SavedSearch.fetchOne(db, key: record.id)
        }
        XCTAssertEqual(restored?.query, query)
    }

    // MARK: - Bundle export (FR-9.4)

    func testBundleExportCopiesFilesAndSidecarWithoutTouchingOriginals() async throws {
        try write("dragon.stl", "dragon-bytes")
        try write("sub/benchy.stl", "benchy-bytes")
        let folderId = try await addAndScan()

        let originalAttrs = try FileManager.default.attributesOfItem(
            atPath: tempRoot.appendingPathComponent("dragon.stl").path
        )

        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("polyshelf-bundle-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: destination) }

        let exporter = BundleExporter(database: database, folderManager: folderManager)
        let summary = try await exporter.exportBundle(folderId: folderId, to: destination)
        XCTAssertEqual(summary.copied, 2)

        // Copies exist with identical content.
        XCTAssertEqual(
            try String(contentsOf: destination.appendingPathComponent("dragon.stl"), encoding: .utf8),
            "dragon-bytes"
        )
        XCTAssertEqual(
            try String(contentsOf: destination.appendingPathComponent("sub/benchy.stl"), encoding: .utf8),
            "benchy-bytes"
        )
        // Sidecar present and parseable.
        let sidecars = try FileManager.default.contentsOfDirectory(at: destination, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasSuffix(".polyshelf.json") }
        XCTAssertEqual(sidecars.count, 1)
        XCTAssertNoThrow(try Exporter.decode(Data(contentsOf: sidecars[0])))

        // Originals untouched (content + mtime).
        let afterAttrs = try FileManager.default.attributesOfItem(
            atPath: tempRoot.appendingPathComponent("dragon.stl").path
        )
        XCTAssertEqual(
            originalAttrs[.modificationDate] as? Date,
            afterAttrs[.modificationDate] as? Date,
            "original mtime changed — non-destructive rule violated"
        )
    }
}
