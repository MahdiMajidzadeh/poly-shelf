import Foundation
import GRDB

/// Saved search / smart folder (FR-8.5): a named, persisted LibraryQuery.
public struct SavedSearch: Codable, Identifiable, Equatable, Sendable, FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "saved_searches"

    public var id: Int64?
    public var name: String
    /// JSON-encoded LibraryQuery.
    public var queryJson: String
    public var createdAt: Date

    public init(id: Int64? = nil, name: String, query: LibraryQuery, createdAt: Date = Date()) throws {
        self.id = id
        self.name = name
        self.queryJson = String(data: try JSONEncoder().encode(query), encoding: .utf8)!
        self.createdAt = createdAt
    }

    public var query: LibraryQuery? {
        try? JSONDecoder().decode(LibraryQuery.self, from: Data(queryJson.utf8))
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}
