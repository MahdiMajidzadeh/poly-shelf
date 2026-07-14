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
    public func enrich(itemIds: [Int64], rootURL: URL) async {
        guard !itemIds.isEmpty else { return }
        let items: [ItemRecord] = (try? await database.writer.read { db in
            try ItemRecord.filter(itemIds.contains(Column("id"))).fetchAll(db)
        }) ?? []

        await withTaskGroup(of: Void.self) { group in
            var active = 0
            for item in items {
                guard Self.parserByExt[item.ext] != nil else { continue }
                if active >= maxConcurrent {
                    await group.next()
                    active -= 1
                }
                active += 1
                group.addTask { [self] in
                    await enrichOne(item, rootURL: rootURL)
                }
            }
            await group.waitForAll()
        }
    }

    private func enrichOne(_ item: ItemRecord, rootURL: URL) async {
        guard let parser = Self.parserByExt[item.ext], let itemId = item.id else { return }
        let fileURL = rootURL.appendingPathComponent(item.relPath)

        do {
            let stats = try parser.parse(fileURL: fileURL) // ParseError on corrupt input
            try? await database.writer.write { db in
                try db.execute(
                    sql: """
                        UPDATE items
                        SET bboxX = ?, bboxY = ?, bboxZ = ?, triangleCount = ?, partCount = ?
                        WHERE id = ?
                        """,
                    arguments: [stats.bboxX, stats.bboxY, stats.bboxZ, stats.triangleCount, stats.partCount, itemId]
                )
            }
            if let thumbnail = stats.embeddedThumbnail {
                thumbnailSink?(itemId, thumbnail)
            }
        } catch {
            NSLog("PolyShelf: unreadable %@ — %@", item.relPath, String(describing: error))
            try? await database.writer.write { db in
                try db.execute(
                    sql: "UPDATE items SET status = ? WHERE id = ?",
                    arguments: [ItemStatus.unreadable.rawValue, itemId]
                )
            }
        }
    }
}
