import Foundation
import GRDB

/// Applies AI tagging to items (FR-5.7/5.9): on-demand per selection, or as
/// an explicit batch over untagged items — never automatically on scan.
/// Concurrency-limited (default 2, safe for local Ollama).
public actor AITaggingService {
    public struct Progress: Sendable, Equatable {
        public var processed = 0
        public var total = 0
        public var failed = 0

        public init(processed: Int = 0, total: Int = 0, failed: Int = 0) {
            self.processed = processed
            self.total = total
            self.failed = failed
        }
    }

    private let database: DatabaseManager
    private let cache: ThumbnailCache

    public init(database: DatabaseManager, cache: ThumbnailCache) {
        self.database = database
        self.cache = cache
    }

    /// Runs AI tagging over the given items. Returns per-item errors keyed by
    /// item id (empty on full success).
    public func tagItems(
        itemIds: [Int64],
        client: AIClient,
        onProgress: (@Sendable (Progress) -> Void)? = nil
    ) async -> [Int64: String] {
        var errors: [Int64: String] = [:]
        var progress = Progress(total: itemIds.count)
        let limit = max(1, client.config.maxConcurrent)

        await withTaskGroup(of: (Int64, String?).self) { group in
            var iterator = itemIds.makeIterator()
            var active = 0
            func addNext() {
                guard let itemId = iterator.next() else { return }
                active += 1
                group.addTask { [self] in
                    do {
                        try await tagOne(itemId: itemId, client: client)
                        return (itemId, nil)
                    } catch {
                        return (itemId, error.localizedDescription)
                    }
                }
            }
            for _ in 0..<limit { addNext() }
            while active > 0 {
                guard let (itemId, error) = await group.next() else { break }
                active -= 1
                progress.processed += 1
                if let error {
                    progress.failed += 1
                    errors[itemId] = error
                    NSLog("PolyShelf AI: item %lld failed — %@", itemId, error)
                }
                onProgress?(progress)
                addNext()
            }
        }
        return errors
    }

    /// Item ids eligible for batch mode: no AI tag yet, status ok.
    public func untaggedItemIds() async throws -> [Int64] {
        try await database.writer.read { db in
            try Int64.fetchAll(db, sql: """
                SELECT items.id FROM items
                WHERE items.status = 'ok'
                  AND NOT EXISTS (
                    SELECT 1 FROM item_tags
                    WHERE item_tags.itemId = items.id AND item_tags.provenance = 'ai'
                  )
                ORDER BY items.id
                """)
        }
    }

    private func tagOne(itemId: Int64, client: AIClient) async throws {
        guard let item = try await database.writer.read({ db in
            try ItemRecord.fetchOne(db, key: itemId)
        }) else { return }

        // Preview image + filename + structural stats (FR-5.6).
        let png = ThumbnailCache.key(for: item).flatMap { cache.data(forKey: $0) }
        var statLines = ["Format: .\(item.ext)", "File size: \(item.sizeBytes) bytes"]
        if let x = item.bboxX, let y = item.bboxY, let z = item.bboxZ {
            statLines.append(String(format: "Bounding box: %.0f × %.0f × %.0f mm", x, y, z))
        }
        if let t = item.triangleCount { statLines.append("Triangles: \(t)") }
        if let p = item.partCount { statLines.append("Parts: \(p)") }

        let result = try await client.generateTags(
            filename: item.originalName,
            stats: statLines.joined(separator: "\n"),
            previewPNG: png
        )

        try await database.writer.write { db in
            for name in Set(result.tags) {
                try db.execute(
                    sql: "INSERT INTO tags (name, kind) VALUES (?, 'ai') ON CONFLICT(name) DO NOTHING",
                    arguments: [name]
                )
                let tagId = try Int64.fetchOne(db, sql: "SELECT id FROM tags WHERE name = ?", arguments: [name])!
                // DO NOTHING keeps user suppressions authoritative (FR-5.9).
                try db.execute(
                    sql: """
                        INSERT INTO item_tags (itemId, tagId, provenance, suppressed)
                        VALUES (?, ?, 'ai', 0)
                        ON CONFLICT(itemId, tagId) DO NOTHING
                        """,
                    arguments: [itemId, tagId]
                )
            }
            // Description recorded; suggested name only OFFERED (FR-5.9).
            try db.execute(
                sql: "UPDATE items SET aiDescription = ?, aiSuggestedName = ? WHERE id = ?",
                arguments: [result.description, result.suggestedDisplayName, itemId]
            )
            try DatabaseManager.refreshFTS(db, itemIds: [itemId])
        }
    }
}
