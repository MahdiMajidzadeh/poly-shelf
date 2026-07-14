import Foundation
import GRDB

/// Lifecycle status of an indexed item. Mirrors the file's state on disk;
/// metadata is retained regardless of status (non-destructive guarantee).
public enum ItemStatus: String, Codable, CaseIterable, Sendable {
    case ok
    case missing    // file deleted outside the app; metadata retained for the grace period
    case offline    // parent volume unmounted (external drive)
    case unreadable // file exists but could not be parsed
}

public enum TagProvenance: String, Codable, CaseIterable, Sendable {
    case user
    case auto
    case ai
}

public struct FolderRecord: Codable, Identifiable, Equatable, Sendable, FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "folders"

    public var id: Int64?
    public var bookmarkData: Data
    public var displayName: String
    /// Last known absolute path, for display and offline detection only —
    /// access always goes through the security-scoped bookmark.
    public var pathHint: String
    public var addedAt: Date
    public var settingsJson: String?
    /// Set when the user removes the folder but chooses to keep metadata
    /// (FR-1.3). Detached folders are hidden everywhere; re-adding the same
    /// content re-attaches by hash.
    public var detachedAt: Date?

    public init(id: Int64? = nil, bookmarkData: Data, displayName: String, pathHint: String, addedAt: Date = Date(), settingsJson: String? = nil, detachedAt: Date? = nil) {
        self.id = id
        self.bookmarkData = bookmarkData
        self.displayName = displayName
        self.pathHint = pathHint
        self.addedAt = addedAt
        self.settingsJson = settingsJson
        self.detachedAt = detachedAt
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

public struct ItemRecord: Codable, Identifiable, Equatable, Sendable, FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "items"

    public var id: Int64?
    public var folderId: Int64
    /// Path relative to the root folder. Together with folderId, uniquely identifies the file.
    public var relPath: String
    /// Read-only mirror of the on-disk filename. Updated if the file is renamed on disk (P1 watching).
    public var originalName: String
    /// Virtual rename — only ever written to the database, never to disk.
    public var displayName: String?
    public var ext: String
    public var sizeBytes: Int64
    public var createdAt: Date?
    public var modifiedAt: Date?
    /// xxHash64 stored as Int64 bit pattern (eager, for change detection).
    public var xxhash64: Int64?
    /// File inode — survives on-disk renames, used for rename matching (FR-2.4).
    public var inode: Int64?
    /// SHA-256 hex, computed lazily (dedupe, export identity).
    public var sha256: String?
    public var status: ItemStatus
    /// When the item entered `missing` status; drives the retention grace period.
    public var missingSince: Date?
    public var bboxX: Double?
    public var bboxY: Double?
    public var bboxZ: Double?
    public var triangleCount: Int64?
    public var partCount: Int64?
    public var notes: String?
    /// AI-generated description (P1), provenance-tracked separately from notes.
    public var aiDescription: String?
    /// AI-suggested display name — offered in the UI, never applied silently (FR-5.9).
    public var aiSuggestedName: String?
    public var indexedAt: Date

    public init(
        id: Int64? = nil,
        folderId: Int64,
        relPath: String,
        originalName: String,
        displayName: String? = nil,
        ext: String,
        sizeBytes: Int64,
        createdAt: Date? = nil,
        modifiedAt: Date? = nil,
        xxhash64: Int64? = nil,
        inode: Int64? = nil,
        sha256: String? = nil,
        status: ItemStatus = .ok,
        missingSince: Date? = nil,
        bboxX: Double? = nil,
        bboxY: Double? = nil,
        bboxZ: Double? = nil,
        triangleCount: Int64? = nil,
        partCount: Int64? = nil,
        notes: String? = nil,
        aiDescription: String? = nil,
        aiSuggestedName: String? = nil,
        indexedAt: Date = Date()
    ) {
        self.id = id
        self.folderId = folderId
        self.relPath = relPath
        self.originalName = originalName
        self.displayName = displayName
        self.ext = ext
        self.sizeBytes = sizeBytes
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt
        self.xxhash64 = xxhash64
        self.inode = inode
        self.sha256 = sha256
        self.status = status
        self.missingSince = missingSince
        self.bboxX = bboxX
        self.bboxY = bboxY
        self.bboxZ = bboxZ
        self.triangleCount = triangleCount
        self.partCount = partCount
        self.notes = notes
        self.aiDescription = aiDescription
        self.aiSuggestedName = aiSuggestedName
        self.indexedAt = indexedAt
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }

    /// Name shown in the UI: display name when set, otherwise the on-disk name.
    public var effectiveName: String {
        if let displayName, !displayName.isEmpty { return displayName }
        return originalName
    }
}

public struct TagRecord: Codable, Identifiable, Equatable, Sendable, FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "tags"

    public var id: Int64?
    public var name: String
    /// Kind of the tag itself (who created it first). Per-item provenance lives on item_tags.
    public var kind: TagProvenance

    public init(id: Int64? = nil, name: String, kind: TagProvenance) {
        self.id = id
        self.name = name
        self.kind = kind
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

public struct ItemTagRecord: Codable, Equatable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "item_tags"

    public var itemId: Int64
    public var tagId: Int64
    public var provenance: TagProvenance
    /// A suppressed auto/ai tag was removed by the user; the row is kept so
    /// rescans never resurrect it (insert uses ON CONFLICT DO NOTHING).
    public var suppressed: Bool

    public init(itemId: Int64, tagId: Int64, provenance: TagProvenance, suppressed: Bool = false) {
        self.itemId = itemId
        self.tagId = tagId
        self.provenance = provenance
        self.suppressed = suppressed
    }
}
