import Foundation
import GRDB

/// Local auto-tagging pipeline (FR-5.1–5.3): filename/path keywords,
/// structural tags from parsed geometry, and source-site detection.
/// Fully offline; runs as an enrichment stage after GeometryEnricher so
/// bbox/triangle stats are already in the database.
public final class AutoTagger: ScanEnrichmentStage, Sendable {
    /// Size-class thresholds by longest bounding-box edge, in mm (FR-5.2;
    /// configurable via UserDefaults later — these are the shipped defaults).
    public struct SizeThresholds: Sendable {
        public var tiny: Double = 30
        public var small: Double = 80
        public var medium: Double = 150
        public var large: Double = 250 // ≥ this → xl
        public init() {}
    }

    private let database: DatabaseManager
    private let dictionary: TagDictionary
    private let thresholds: SizeThresholds

    public init(
        database: DatabaseManager,
        dictionary: TagDictionary = .load(),
        thresholds: SizeThresholds = SizeThresholds()
    ) {
        self.database = database
        self.dictionary = dictionary
        self.thresholds = thresholds
    }

    public func enrich(itemIds: [Int64], rootURL: URL) async {
        guard !itemIds.isEmpty else { return }
        let items: [ItemRecord] = (try? await database.writer.read { db in
            try ItemRecord.filter(itemIds.contains(Column("id"))).fetchAll(db)
        }) ?? []

        for item in items {
            guard let itemId = item.id else { continue }
            let tags = computeTags(for: item)
            try? await apply(tags: tags, toItem: itemId)
        }
    }

    // MARK: - Tag computation (pure — unit-testable)

    public func computeTags(for item: ItemRecord) -> Set<String> {
        var tags: Set<String> = []

        // Format tag — guarantees every indexed file gets ≥1 tag (acceptance).
        tags.insert(item.ext)

        // Keyword tags from filename + parent folder names.
        let parents = (item.relPath as NSString).deletingLastPathComponent
            .split(separator: "/").map(String.init)
        tags.formUnion(dictionary.matchTags(filename: item.originalName, parentFolders: parents))

        // Source-site tags (FR-5.3).
        tags.formUnion(Self.sourceTags(filename: item.originalName, parentFolders: parents))

        // Structural tags (FR-5.2).
        if let parts = item.partCount, parts > 1 { tags.insert("multi-part") }
        if let triangles = item.triangleCount, triangles > 1_000_000 { tags.insert("high-poly") }
        if ["gcode", "bgcode", "gx"].contains(item.ext) { tags.insert("presliced") }
        if ["zip", "rar"].contains(item.ext) { tags.insert("archive") }
        if ["step", "stp", "iges", "igs"].contains(item.ext) { tags.insert("cad") }
        if item.status == .unreadable { tags.insert("unreadable") }

        if let bx = item.bboxX, let by = item.bboxY, let bz = item.bboxZ,
           bx > 0 || by > 0 || bz > 0 {
            let longest = max(bx, by, bz)
            switch longest {
            case ..<thresholds.tiny: tags.insert("tiny")
            case ..<thresholds.small: tags.insert("small")
            case ..<thresholds.medium: tags.insert("medium")
            case ..<thresholds.large: tags.insert("large")
            default: tags.insert("xl")
            }
            // Flat: Z much smaller than the footprint (plates, lithophanes, signs).
            if bz > 0, bz <= 0.15 * min(bx, by), min(bx, by) > 20 {
                tags.insert("flat")
            }
        }

        return tags
    }

    static func sourceTags(filename: String, parentFolders: [String]) -> Set<String> {
        let haystack = ([filename] + parentFolders).joined(separator: "/").lowercased()
        var tags: Set<String> = []
        let sites = ["printables", "thingiverse", "makerworld", "thangs", "cults", "myminifactory"]
        for site in sites where haystack.contains(site) {
            tags.insert(site)
        }
        // Thingiverse download pattern: "thing-4980354" / "thing_4980354"
        if haystack.range(of: #"thing[-_]?\d{5,}"#, options: .regularExpression) != nil {
            tags.insert("thingiverse")
        }
        return tags
    }

    // MARK: - Persistence

    /// Inserts auto tags with ON CONFLICT DO NOTHING: a row the user
    /// suppressed keeps suppressed=1, so deleted auto tags never resurrect
    /// on rescan (FR-5.4 acceptance).
    private func apply(tags: Set<String>, toItem itemId: Int64) async throws {
        guard !tags.isEmpty else { return }
        try await database.writer.write { db in
            for name in tags.sorted() {
                try db.execute(
                    sql: "INSERT INTO tags (name, kind) VALUES (?, ?) ON CONFLICT(name) DO NOTHING",
                    arguments: [name, TagProvenance.auto.rawValue]
                )
                let tagId = try Int64.fetchOne(db, sql: "SELECT id FROM tags WHERE name = ?", arguments: [name])!
                try db.execute(
                    sql: """
                        INSERT INTO item_tags (itemId, tagId, provenance, suppressed)
                        VALUES (?, ?, ?, 0)
                        ON CONFLICT(itemId, tagId) DO NOTHING
                        """,
                    arguments: [itemId, tagId, TagProvenance.auto.rawValue]
                )
            }
            try DatabaseManager.refreshFTS(db, itemIds: [itemId])
        }
    }
}
