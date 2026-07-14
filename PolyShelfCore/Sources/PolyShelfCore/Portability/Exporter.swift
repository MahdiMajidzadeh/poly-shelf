import Foundation
import GRDB

/// Metadata export (FR-9.1/9.3): whole library or a single root folder.
public struct Exporter: Sendable {
    private let database: DatabaseManager
    private let folderManager: FolderManager

    public init(database: DatabaseManager, folderManager: FolderManager) {
        self.database = database
        self.folderManager = folderManager
    }

    /// Exports all (non-detached) folders, or just `folderId` when given.
    /// Computes missing SHA-256s for reachable files along the way so the
    /// export carries maximum matching fidelity.
    public func export(folderId: Int64? = nil) async throws -> LibraryExport {
        let folders: [FolderRecord] = try await database.writer.read { db in
            var request = FolderRecord.filter(Column("detachedAt") == nil)
            if let folderId {
                request = request.filter(Column("id") == folderId)
            }
            return try request.fetchAll(db)
        }

        var exportedFolders: [ExportedFolder] = []
        for folder in folders {
            exportedFolders.append(try await exportFolder(folder))
        }
        return LibraryExport(folders: exportedFolders)
    }

    private func exportFolder(_ folder: FolderRecord) async throws -> ExportedFolder {
        let items: [ItemRecord] = try await database.writer.read { db in
            try ItemRecord.filter(Column("folderId") == folder.id!).fetchAll(db)
        }

        // Root access is best-effort: offline folders export with the hashes
        // they already have.
        var rootURL: URL?
        if case .available(let url) = folderManager.beginAccess(folder) {
            rootURL = url
        }
        defer { rootURL?.stopAccessingSecurityScopedResource() }

        var exportedItems: [ExportedItem] = []
        exportedItems.reserveCapacity(items.count)
        for item in items {
            var sha = item.sha256
            if sha == nil, item.status == .ok, let rootURL {
                sha = await SHA256Hasher.ensureSHA256(item: item, rootURL: rootURL, database: database)
            }
            let tags: [ExportedTag] = try await database.writer.read { db in
                let rows = try Row.fetchAll(db, sql: """
                    SELECT tags.name AS name, item_tags.provenance AS provenance, item_tags.suppressed AS suppressed
                    FROM tags JOIN item_tags ON item_tags.tagId = tags.id
                    WHERE item_tags.itemId = ?
                    ORDER BY tags.name
                    """, arguments: [item.id!])
                return rows.map { ExportedTag(name: $0["name"], provenance: $0["provenance"], suppressed: $0["suppressed"]) }
            }
            exportedItems.append(ExportedItem(
                sha256: sha,
                xxhash64: item.xxhash64.map { String(format: "%016llx", UInt64(bitPattern: $0)) },
                sizeBytes: item.sizeBytes,
                relPath: item.relPath,
                originalName: item.originalName,
                displayName: item.displayName,
                notes: item.notes,
                aiDescription: item.aiDescription,
                format: item.ext,
                tags: tags
            ))
        }

        return ExportedFolder(
            displayName: folder.displayName,
            settingsJson: folder.settingsJson,
            items: exportedItems
        )
    }

    /// Serializes with stable key order so identical libraries produce
    /// byte-identical exports (helps diffing and the idempotency test).
    public static func encode(_ export: LibraryExport) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(export)
    }

    public static func decode(_ data: Data) throws -> LibraryExport {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        // Version guard first (forward compatibility, FR-9 acceptance).
        struct VersionProbe: Decodable { let schemaVersion: Int? }
        guard let probe = try? decoder.decode(VersionProbe.self, from: data),
              let version = probe.schemaVersion else {
            throw PortabilityError.malformedFile("missing schemaVersion")
        }
        guard version <= LibraryExport.currentSchemaVersion else {
            throw PortabilityError.newerSchema(found: version, supported: LibraryExport.currentSchemaVersion)
        }
        do {
            return try decoder.decode(LibraryExport.self, from: data)
        } catch {
            throw PortabilityError.malformedFile(String(describing: error))
        }
    }
}
