import XCTest
import GRDB
@testable import PolyShelfCore

final class PortabilityTests: XCTestCase {
    private var tempRoot: URL!
    private var database: DatabaseManager!
    private var folderManager: FolderManager!
    private var scanner: LibraryScanner!

    override func setUpWithError() throws {
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("polyshelf-port-\(UUID().uuidString)", isDirectory: true)
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

    private func setUpLibrary() async throws -> Int64 {
        try write("dragon.stl", "dragon-content")
        try write("nested/benchy.stl", "benchy-content")
        guard case .added(let folderId) = try folderManager.addFolder(at: tempRoot) else {
            fatalError()
        }
        _ = try await scanner.scan(folderId: folderId, enabledExtensions: ["stl"])
        return folderId
    }

    private func decorate(_ folderId: Int64) async throws {
        let store = TagStore(database: database)
        let itemStore = ItemStore(database: database)
        let items = try await database.writer.read { try ItemRecord.fetchAll($0) }
        let dragon = items.first { $0.originalName == "dragon.stl" }!
        try await itemStore.setDisplayName("Articulated Dragon — small", itemId: dragon.id!)
        try await itemStore.setNotes("print at 0.16", itemId: dragon.id!)
        try await store.addUserTag("favorite", toItem: dragon.id!)
    }

    func testExportContainsNoAbsolutePaths() async throws {
        let folderId = try await setUpLibrary()
        try await decorate(folderId)
        let export = try await Exporter(database: database, folderManager: folderManager).export()
        let json = String(data: try Exporter.encode(export), encoding: .utf8)!
        XCTAssertFalse(json.contains(tempRoot.path), "export leaks absolute paths")
        XCTAssertFalse(json.contains("/Users/"), "export leaks user paths")
        XCTAssertTrue(json.contains("dragon.stl"))
    }

    func testRoundTripIsIdempotent() async throws {
        let folderId = try await setUpLibrary()
        try await decorate(folderId)
        let exporter = Exporter(database: database, folderManager: folderManager)
        let importer = Importer(database: database, folderManager: folderManager)

        let export1 = try await exporter.export()
        let summary = try await importer.importFolder(export1.folders[0], intoFolderId: folderId, policy: .merge)
        XCTAssertEqual(summary.unmatched, 0)

        let export2 = try await exporter.export()
        // exportedAt differs; compare folder payloads.
        XCTAssertEqual(export1.folders, export2.folders, "merge re-import must be a no-op")
    }

    /// FR-9 acceptance: export on Mac A → fresh library on Mac B (same files,
    /// reorganized) → import restores 100% of tags, display names, notes.
    func testCrossMachineRestoreWithReorganizedFolder() async throws {
        let folderId = try await setUpLibrary()
        try await decorate(folderId)
        let export = try await Exporter(database: database, folderManager: folderManager).export()
        let encoded = try Exporter.encode(export)

        // "Mac B": fresh DB, same files but dragon.stl moved to a subfolder.
        let dbB = try DatabaseManager(inMemory: true)
        let fmB = FolderManager(database: dbB)
        let scannerB = LibraryScanner(database: dbB, folderManager: fmB)
        try FileManager.default.createDirectory(at: tempRoot.appendingPathComponent("reorganized"), withIntermediateDirectories: true)
        try FileManager.default.moveItem(
            at: tempRoot.appendingPathComponent("dragon.stl"),
            to: tempRoot.appendingPathComponent("reorganized/dragon-renamed.stl")
        )
        guard case .added(let folderB) = try fmB.addFolder(at: tempRoot) else { fatalError() }
        _ = try await scannerB.scan(folderId: folderB, enabledExtensions: ["stl"])

        let decoded = try Exporter.decode(encoded)
        let importer = Importer(database: dbB, folderManager: fmB)
        let (matched, unmatched) = try await importer.matchFolders(decoded)
        XCTAssertEqual(matched.count, 1)
        XCTAssertTrue(unmatched.isEmpty)
        let summary = try await importer.importFolder(matched[0].0, intoFolderId: folderB, policy: .merge)

        XCTAssertEqual(summary.matchedByHash, 1, "moved+renamed file matched by content hash")
        XCTAssertEqual(summary.matchedByPath, 1)
        XCTAssertEqual(summary.unmatched, 0)

        let restored = try await dbB.writer.read { db in
            try ItemRecord.filter(Column("originalName") == "dragon-renamed.stl").fetchOne(db)
        }
        XCTAssertEqual(restored?.displayName, "Articulated Dragon — small")
        XCTAssertEqual(restored?.notes, "print at 0.16")
        let tags = try await TagStore(database: dbB).tags(forItem: restored!.id!)
        XCTAssertTrue(tags.map(\.name).contains("favorite"))
    }

    func testNewerSchemaRejectedGracefully() throws {
        let json = #"{"schemaVersion": 99, "exportedAt": "2030-01-01T00:00:00Z", "folders": []}"#
        XCTAssertThrowsError(try Exporter.decode(Data(json.utf8))) { error in
            guard case PortabilityError.newerSchema(let found, _) = error else {
                return XCTFail("expected newerSchema, got \(error)")
            }
            XCTAssertEqual(found, 99)
        }
    }

    func testMalformedFileRejected() {
        XCTAssertThrowsError(try Exporter.decode(Data("not json".utf8)))
        XCTAssertThrowsError(try Exporter.decode(Data(#"{"foo": 1}"#.utf8)))
    }

    func testOverwritePolicyReplacesLocal() async throws {
        let folderId = try await setUpLibrary()
        try await decorate(folderId)
        let exporter = Exporter(database: database, folderManager: folderManager)
        var export = try await exporter.export()

        // Mutate the export: different display name.
        export.folders[0].items = export.folders[0].items.map { item in
            var copy = item
            if copy.originalName == "dragon.stl" {
                copy.displayName = "Imported Name"
            }
            return copy
        }
        let importer = Importer(database: database, folderManager: folderManager)
        _ = try await importer.importFolder(export.folders[0], intoFolderId: folderId, policy: .overwrite)

        let item = try await database.writer.read { db in
            try ItemRecord.filter(Column("originalName") == "dragon.stl").fetchOne(db)
        }
        XCTAssertEqual(item?.displayName, "Imported Name")
    }

    func testMergeKeepsLocalDisplayName() async throws {
        let folderId = try await setUpLibrary()
        try await decorate(folderId)
        let exporter = Exporter(database: database, folderManager: folderManager)
        var export = try await exporter.export()
        export.folders[0].items = export.folders[0].items.map { item in
            var copy = item
            copy.displayName = "Should Not Win"
            return copy
        }
        let importer = Importer(database: database, folderManager: folderManager)
        _ = try await importer.importFolder(export.folders[0], intoFolderId: folderId, policy: .merge)

        let item = try await database.writer.read { db in
            try ItemRecord.filter(Column("originalName") == "dragon.stl").fetchOne(db)
        }
        XCTAssertEqual(item?.displayName, "Articulated Dragon — small", "merge keeps local display name")
    }
}
