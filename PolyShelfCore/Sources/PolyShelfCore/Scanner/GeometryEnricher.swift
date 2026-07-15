import Foundation
import GRDB

/// Post-scan enrichment stage: routes each new/changed item to its format
/// parser, writes geometry stats back, and flags corrupt files `unreadable`
/// (edge case: never crashes the scanner; errors are logged per file).
/// Runs while the scanner still holds security-scoped access to the root.
public final class GeometryEnricher: ScanEnrichmentStage, Sendable {
    public static let parsers: [ModelFileParser] = [
        STLParser(),
        ThreeMFParser(),
        GCodeThumbnailParser(),
        BlendThumbnailParser(),
        ModelIOStatsParser(),
    ]

    private let database: DatabaseManager
    /// Bounded parse concurrency; parsing is CPU/IO heavy.
    private let maxConcurrent: Int
    /// Sink for embedded thumbnails, wired to the thumbnail cache (M4).
    private let thumbnailSink: (@Sendable (_ itemId: Int64, _ imageData: Data) -> Void)?

    private static let parserByExt: [String: ModelFileParser] = {
        var map: [String: ModelFileParser] = [:]
        for parser in parsers {
            for ext in parser.extensions { map[ext] = parser }
        }
        return map
    }()

    public init(
        database: DatabaseManager,
        maxConcurrent: Int = max(2, ProcessInfo.processInfo.activeProcessorCount / 2),
        thumbnailSink: (@Sendable (Int64, Data) -> Void)? = nil
    ) {
        self.database = database
        self.maxConcurrent = maxConcurrent
        self.thumbnailSink = thumbnailSink
    }

    /// Parses the given items (ids of rows just added/updated by the scanner).
    /// `rootURL` must be inside an active security scope.
    /// Results are written in batches: one transaction per item means one WAL
    /// commit — and one full UI observation refetch — per parsed file.
    public func enrich(itemIds: [Int64], rootURL: URL) async {
        guard !itemIds.isEmpty else { return }
        let items: [ItemRecord] = (try? await database.writer.read { db in
            try ItemRecord.filter(itemIds.contains(Column("id"))).fetchAll(db)
        }) ?? []

        var statUpdates: [(id: Int64, stats: GeometryStats)] = []
        var unreadableIds: [Int64] = []
        let flushThreshold = 50

        await withTaskGroup(of: (Int64, GeometryStats?).self) { group in
            var active = 0
            for item in items {
                guard Self.parserByExt[item.ext] != nil, let itemId = item.id else { continue }
                if active >= maxConcurrent, let (id, stats) = await group.next() {
                    active -= 1
                    if let stats { statUpdates.append((id, stats)) } else { unreadableIds.append(id) }
                    if statUpdates.count + unreadableIds.count >= flushThreshold {
                        await flush(stats: statUpdates, unreadable: unreadableIds)
                        statUpdates.removeAll()
                        unreadableIds.removeAll()
                    }
                }
                active += 1
                group.addTask { [self] in
                    (itemId, parseOne(item, rootURL: rootURL))
                }
            }
            for await (id, stats) in group {
                if let stats { statUpdates.append((id, stats)) } else { unreadableIds.append(id) }
            }
        }
        await flush(stats: statUpdates, unreadable: unreadableIds)
    }

    /// Parses one file; embedded thumbnails go straight to the sink (no DB).
    /// Returns nil for corrupt input (caller marks the item unreadable).
    private func parseOne(_ item: ItemRecord, rootURL: URL) -> GeometryStats? {
        guard let parser = Self.parserByExt[item.ext], let itemId = item.id else { return nil }
        let fileURL = rootURL.appendingPathComponent(item.relPath)
        do {
            let stats = try parser.parse(fileURL: fileURL) // ParseError on corrupt input
            if let thumbnail = stats.embeddedThumbnail {
                thumbnailSink?(itemId, thumbnail)
            }
            return stats
        } catch {
            NSLog("PolyShelf: unreadable %@ — %@", item.relPath, String(describing: error))
            return nil
        }
    }

    private func flush(stats: [(id: Int64, stats: GeometryStats)], unreadable: [Int64]) async {
        guard !stats.isEmpty || !unreadable.isEmpty else { return }
        try? await database.writer.write { db in
            for (itemId, stats) in stats {
                try db.execute(
                    sql: """
                        UPDATE items
                        SET bboxX = ?, bboxY = ?, bboxZ = ?, triangleCount = ?, partCount = ?
                        WHERE id = ?
                        """,
                    arguments: [stats.bboxX, stats.bboxY, stats.bboxZ, stats.triangleCount, stats.partCount, itemId]
                )
            }
            for itemId in unreadable {
                try db.execute(
                    sql: "UPDATE items SET status = ? WHERE id = ?",
                    arguments: [ItemStatus.unreadable.rawValue, itemId]
                )
            }
        }
    }
}
