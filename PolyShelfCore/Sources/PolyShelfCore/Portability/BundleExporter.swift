import Foundation
import GRDB

/// Bundle export (FR-9.4): copies a folder's files plus the metadata sidecar
/// into a destination folder — suitable for handing to a friend. Originals
/// are COPIED, never moved or modified.
public struct BundleExporter: Sendable {
    public struct Summary: Equatable, Sendable {
        public var copied = 0
        public var skipped = 0
    }

    private let database: DatabaseManager
    private let folderManager: FolderManager

    public init(database: DatabaseManager, folderManager: FolderManager) {
        self.database = database
        self.folderManager = folderManager
    }

    public func exportBundle(folderId: Int64, to destination: URL) async throws -> Summary {
        guard let folder = try await database.writer.read({ db in
            try FolderRecord.fetchOne(db, key: folderId)
        }) else {
            throw PortabilityError.folderNotFound("#\(folderId)")
        }
        guard case .available(let rootURL) = folderManager.beginAccess(folder) else {
            throw ScanError.folderOffline
        }
        defer { rootURL.stopAccessingSecurityScopedResource() }

        let items: [ItemRecord] = try await database.writer.read { db in
            try ItemRecord
                .filter(Column("folderId") == folderId && Column("status") == ItemStatus.ok.rawValue)
                .fetchAll(db)
        }

        let fm = FileManager.default
        try fm.createDirectory(at: destination, withIntermediateDirectories: true)

        var summary = Summary()
        for item in items {
            let source = rootURL.appendingPathComponent(item.relPath)
            let target = destination.appendingPathComponent(item.relPath)
            do {
                try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                if fm.fileExists(atPath: target.path) {
                    summary.skipped += 1
                } else {
                    try fm.copyItem(at: source, to: target)
                    summary.copied += 1
                }
            } catch {
                summary.skipped += 1
                NSLog("PolyShelf bundle: failed to copy %@ — %@", item.relPath, String(describing: error))
            }
        }

        // Metadata sidecar alongside the files.
        let exporter = Exporter(database: database, folderManager: folderManager)
        let export = try await exporter.export(folderId: folderId)
        let sidecarURL = destination.appendingPathComponent("\(folder.displayName).polyshelf.json")
        try Exporter.encode(export).write(to: sidecarURL, options: .atomic)

        return summary
    }
}
