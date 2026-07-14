import Foundation

/// The `.polyshelf.json` schema (FR-9.1). Schema-versioned; contains NO API
/// keys and NO absolute machine paths — only root-relative structure.
public struct LibraryExport: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var exportedAt: Date
    public var appVersion: String?
    public var folders: [ExportedFolder]

    public init(schemaVersion: Int = LibraryExport.currentSchemaVersion, exportedAt: Date = Date(), appVersion: String? = nil, folders: [ExportedFolder]) {
        self.schemaVersion = schemaVersion
        self.exportedAt = exportedAt
        self.appVersion = appVersion
        self.folders = folders
    }
}

public struct ExportedFolder: Codable, Equatable, Sendable {
    public var displayName: String
    public var settingsJson: String?
    public var items: [ExportedItem]

    public init(displayName: String, settingsJson: String? = nil, items: [ExportedItem]) {
        self.displayName = displayName
        self.settingsJson = settingsJson
        self.items = items
    }
}

public struct ExportedItem: Codable, Equatable, Sendable {
    /// Primary matcher (FR-9.2): content identity, survives reorganization.
    public var sha256: String?
    /// Secondary content hint (hex xxHash64 + size guards against sha absence).
    public var xxhash64: String?
    public var sizeBytes: Int64
    /// Fallback matcher: path relative to the root folder.
    public var relPath: String
    public var originalName: String
    public var displayName: String?
    public var notes: String?
    public var aiDescription: String?
    public var format: String
    public var tags: [ExportedTag]

    public init(
        sha256: String?, xxhash64: String?, sizeBytes: Int64, relPath: String,
        originalName: String, displayName: String?, notes: String?,
        aiDescription: String?, format: String, tags: [ExportedTag]
    ) {
        self.sha256 = sha256
        self.xxhash64 = xxhash64
        self.sizeBytes = sizeBytes
        self.relPath = relPath
        self.originalName = originalName
        self.displayName = displayName
        self.notes = notes
        self.aiDescription = aiDescription
        self.format = format
        self.tags = tags
    }
}

public struct ExportedTag: Codable, Equatable, Sendable {
    public var name: String
    public var provenance: String
    /// Suppressions travel too — an auto tag the user killed stays killed
    /// on the new machine.
    public var suppressed: Bool

    public init(name: String, provenance: String, suppressed: Bool) {
        self.name = name
        self.provenance = provenance
        self.suppressed = suppressed
    }
}

public enum PortabilityError: Error, LocalizedError, Equatable {
    case newerSchema(found: Int, supported: Int)
    case malformedFile(String)
    case folderNotFound(String)

    public var errorDescription: String? {
        switch self {
        case .newerSchema(let found, let supported):
            return "This file was exported by a newer version of Poly Shelf (schema v\(found); this app reads up to v\(supported)). Update the app to import it."
        case .malformedFile(let detail):
            return "The file isn’t a valid Poly Shelf export: \(detail)"
        case .folderNotFound(let name):
            return "No matching library folder for “\(name)”. Add that folder first, then import again."
        }
    }
}
