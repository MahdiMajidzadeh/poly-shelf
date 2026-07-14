import Foundation
import GRDB

/// One library view: scope + instant search + filters + sort (FR-8.x).
/// Codable so saved searches (FR-8.5) can persist it.
public struct LibraryQuery: Equatable, Hashable, Codable, Sendable {
    public enum Scope: Equatable, Hashable, Codable, Sendable {
        case all
        case folder(Int64)
        case tag(Int64)
        case missingOffline
    }

    public enum SortKey: String, CaseIterable, Equatable, Codable, Sendable {
        case name = "Name"
        case dateModified = "Date Modified"
        case dateIndexed = "Date Indexed"
        case fileSize = "File Size"
        case triangleCount = "Triangles"
    }

    public var scope: Scope = .all
    public var searchText: String = ""
    /// Extensions visible in this view (enabled formats ∩ optional format filter).
    public var formats: Set<String> = []
    /// Multi-select AND tag filter (FR-8.3).
    public var requiredTagIds: [Int64] = []
    public var addedAfter: Date?
    public var sort: SortKey = .name
    public var sortDescending = false

    public init() {}

    // MARK: - Execution

    /// Instant search (FR-8.1): FTS5 over display/original name, notes, path,
    /// tags — prefix + substring-ish via token prefix match, diacritic- and
    /// case-insensitive (unicode61 remove_diacritics tokenizer).
    public static func fetch(_ db: Database, query: LibraryQuery) throws -> [ItemRecord] {
        var sql = "SELECT items.* FROM items"
        var args: [DatabaseValueConvertible] = []
        var conditions: [String] = []

        let match = ftsMatchExpression(query.searchText)
        if let match {
            sql += " JOIN items_fts ON items_fts.rowid = items.id AND items_fts MATCH ?"
            args.append(match)
        }

        switch query.scope {
        case .all:
            conditions.append("items.status NOT IN ('missing','offline')")
            conditions.append("EXISTS (SELECT 1 FROM folders WHERE folders.id = items.folderId AND folders.detachedAt IS NULL)")
        case .folder(let folderId):
            conditions.append("items.folderId = ?")
            args.append(folderId)
        case .tag(let tagId):
            conditions.append("""
                EXISTS (SELECT 1 FROM item_tags
                        WHERE item_tags.itemId = items.id
                          AND item_tags.tagId = ? AND item_tags.suppressed = 0)
                """)
            args.append(tagId)
            conditions.append("items.status NOT IN ('missing','offline')")
        case .missingOffline:
            conditions.append("items.status IN ('missing','offline')")
        }

        if !query.formats.isEmpty {
            let placeholders = databaseQuestionMarks(count: query.formats.count)
            conditions.append("items.ext IN (\(placeholders))")
            args.append(contentsOf: Array(query.formats))
        } else {
            conditions.append("0") // no enabled formats → nothing visible
        }

        for tagId in query.requiredTagIds {
            conditions.append("""
                EXISTS (SELECT 1 FROM item_tags
                        WHERE item_tags.itemId = items.id
                          AND item_tags.tagId = ? AND item_tags.suppressed = 0)
                """)
            args.append(tagId)
        }

        if let addedAfter = query.addedAfter {
            conditions.append("items.indexedAt >= ?")
            args.append(addedAfter)
        }

        if !conditions.isEmpty {
            sql += " WHERE " + conditions.joined(separator: " AND ")
        }

        let direction = query.sortDescending ? "DESC" : "ASC"
        switch query.sort {
        case .name:
            sql += " ORDER BY COALESCE(items.displayName, items.originalName) COLLATE NOCASE \(direction)"
        case .dateModified:
            sql += " ORDER BY items.modifiedAt \(direction)"
        case .dateIndexed:
            sql += " ORDER BY items.indexedAt \(direction)"
        case .fileSize:
            sql += " ORDER BY items.sizeBytes \(direction)"
        case .triangleCount:
            sql += " ORDER BY items.triangleCount IS NULL, items.triangleCount \(direction)"
        }

        return try ItemRecord.fetchAll(db, sql: sql, arguments: StatementArguments(args))
    }

    /// Builds a safe FTS5 MATCH expression: each user token becomes a quoted
    /// prefix query ("drag"*), tokens ANDed. Returns nil for empty input.
    public static func ftsMatchExpression(_ text: String) -> String? {
        let tokens = text
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
        guard !tokens.isEmpty else { return nil }
        return tokens
            .map { "\"\($0.replacingOccurrences(of: "\"", with: ""))\"*" }
            .joined(separator: " ")
    }
}
