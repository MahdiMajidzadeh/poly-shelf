import XCTest
import GRDB
@testable import PolyShelfCore

final class LibraryScannerTests: XCTestCase {
    private var tempRoot: URL!
    private var database: DatabaseManager!
    private var folderManager: FolderManager!
    private var scanner: LibraryScanner!

    override func setUpWithError() throws {
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("polyshelf-scan-\(UUID().uuidString)", isDirectory: true)
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

    private func addFolder() throws -> Int64 {
        guard case .added(let id) = try folderManager.addFolder(at: tempRoot) else {
            XCTFail("expected .added")
            throw ScanError.folderNotFound
        }
        return id
    }

    func testInitialScanDiscoversEnabledFormats() async throws {
        try write("dragon.stl", "solid dragon endsolid dragon")
        try write("nested/benchy.3mf", "not-really-a-3mf")
        try write("notes.txt", "ignore me")
        try write("model.step", "cad file, disabled by default")

        let folderId = try addFolder()
        let summary = try await scanner.scan(folderId: folderId, enabledExtensions: ["stl", "3mf"])

        XCTAssertEqual(summary.added, 2)
        XCTAssertEqual(summary.discovered, 2)

        let items = try await database.writer.read { try ItemRecord.fetchAll($0) }
        XCTAssertEqual(Set(items.map(\.relPath)), ["dragon.stl", "nested/benchy.3mf"])
        XCTAssertTrue(items.allSatisfy { $0.xxhash64 != nil && $0.status == .ok })
    }

    func testIncrementalRescanOnlyTouchesChangedFile() async throws {
        try write("a.stl", "aaa")
        try write("b.stl", "bbb")
        let folderId = try addFolder()
        _ = try await scanner.scan(folderId: folderId, enabledExtensions: ["stl"])

        let hashesBefore = try await database.writer.read { db in
            Dictionary(uniqueKeysWithValues: try ItemRecord.fetchAll(db).map { ($0.relPath, $0.xxhash64) })
        }

        // Touch one file with new content (and nudge mtime to be safe).
        try write("b.stl", "bbb-changed")
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(5)],
            ofItemAtPath: tempRoot.appendingPathComponent("b.stl").path
        )

        let summary = try await scanner.scan(folderId: folderId, enabledExtensions: ["stl"])
        XCTAssertEqual(summary.unchanged, 1, "a.stl must be skipped")
        XCTAssertEqual(summary.updated, 1, "only b.stl re-parsed")

        let hashesAfter = try await database.writer.read { db in
            Dictionary(uniqueKeysWithValues: try ItemRecord.fetchAll(db).map { ($0.relPath, $0.xxhash64) })
        }
        XCTAssertEqual(hashesBefore["a.stl"]!, hashesAfter["a.stl"]!)
        XCTAssertNotEqual(hashesBefore["b.stl"]!, hashesAfter["b.stl"]!)
    }

    func testDeletedFileMarkedMissingMetadataRetained() async throws {
        try write("gone.stl", "soon deleted")
        let folderId = try addFolder()
        _ = try await scanner.scan(folderId: folderId, enabledExtensions: ["stl"])

        try FileManager.default.removeItem(at: tempRoot.appendingPathComponent("gone.stl"))
        let summary = try await scanner.scan(folderId: folderId, enabledExtensions: ["stl"])

        XCTAssertEqual(summary.markedMissing, 1)
        let item = try await database.writer.read { try ItemRecord.fetchOne($0) }
        XCTAssertEqual(item?.status, .missing)
        XCTAssertNotNil(item?.missingSince)
        XCTAssertEqual(item?.originalName, "gone.stl", "metadata retained")
    }

    func testMissingFileComesBack() async throws {
        try write("wanderer.stl", "here")
        let folderId = try addFolder()
        _ = try await scanner.scan(folderId: folderId, enabledExtensions: ["stl"])
        try FileManager.default.removeItem(at: tempRoot.appendingPathComponent("wanderer.stl"))
        _ = try await scanner.scan(folderId: folderId, enabledExtensions: ["stl"])
        try write("wanderer.stl", "here")
        _ = try await scanner.scan(folderId: folderId, enabledExtensions: ["stl"])

        let item = try await database.writer.read { try ItemRecord.fetchOne($0) }
        XCTAssertEqual(item?.status, .ok)
        XCTAssertNil(item?.missingSince)
    }

    /// FR-2.4 acceptance: renaming a file on disk preserves the library item,
    /// its tags, and display name; only original_name updates.
    func testOnDiskRenamePreservesMetadata() async throws {
        try write("old_name.stl", "same content")
        let folderId = try addFolder()
        _ = try await scanner.scan(folderId: folderId, enabledExtensions: ["stl"])

        // Decorate with metadata.
        let original = try await database.writer.read { try ItemRecord.fetchOne($0)! }
        try await ItemStore(database: database).setDisplayName("My Dragon", itemId: original.id!)
        try await TagStore(database: database).addUserTag("favorite", toItem: original.id!)

        // Rename on disk (same inode) and rescan.
        try FileManager.default.moveItem(
            at: tempRoot.appendingPathComponent("old_name.stl"),
            to: tempRoot.appendingPathComponent("new_name.stl")
        )
        let summary = try await scanner.scan(folderId: folderId, enabledExtensions: ["stl"])
        XCTAssertEqual(summary.markedMissing, 0, "rename must not create a missing item")
        XCTAssertEqual(summary.added, 0, "rename must not create a new item")

        let items = try await database.writer.read { try ItemRecord.fetchAll($0) }
        XCTAssertEqual(items.count, 1)
        let item = items[0]
        XCTAssertEqual(item.id, original.id, "same library item")
        XCTAssertEqual(item.originalName, "new_name.stl", "original name mirrors disk")
        XCTAssertEqual(item.displayName, "My Dragon", "display name survives")
        let tags = try await TagStore(database: database).tags(forItem: item.id!)
        XCTAssertTrue(tags.map(\.name).contains("favorite"), "tags survive")
    }

    func testMoveToSubfolderPreservesMetadata() async throws {
        try write("wanderer.stl", "unique content here")
        let folderId = try addFolder()
        _ = try await scanner.scan(folderId: folderId, enabledExtensions: ["stl"])
        let original = try await database.writer.read { try ItemRecord.fetchOne($0)! }
        try await ItemStore(database: database).setNotes("keep me", itemId: original.id!)

        try FileManager.default.createDirectory(at: tempRoot.appendingPathComponent("sorted"), withIntermediateDirectories: true)
        try FileManager.default.moveItem(
            at: tempRoot.appendingPathComponent("wanderer.stl"),
            to: tempRoot.appendingPathComponent("sorted/wanderer.stl")
        )
        _ = try await scanner.scan(folderId: folderId, enabledExtensions: ["stl"])

        let items = try await database.writer.read { try ItemRecord.fetchAll($0) }
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0].relPath, "sorted/wanderer.stl")
        XCTAssertEqual(items[0].notes, "keep me")
    }

    func testNestedFolderRejected() throws {
        let nested = tempRoot.appendingPathComponent("inner", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        _ = try addFolder()
        let result = try folderManager.addFolder(at: nested)
        guard case .nestedInsideExisting = result else {
            return XCTFail("expected nestedInsideExisting, got \(result)")
        }
    }

    func testRemoveKeepMetadataAndReattach() throws {
        let folderId = try addFolder()
        try folderManager.removeFolder(id: folderId, keepMetadata: true)

        let detached = try database.writer.read { db in
            try FolderRecord.fetchOne(db, key: folderId)
        }
        XCTAssertNotNil(detached?.detachedAt)

        guard case .reattached(let reattachedId) = try folderManager.addFolder(at: tempRoot) else {
            return XCTFail("expected reattach")
        }
        XCTAssertEqual(reattachedId, folderId)
    }
}
