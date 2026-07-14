import Foundation

/// Lightweight 3MF reader (§7): ZIP container + streaming XML parse of
/// 3D/3dmodel.model for object/triangle counts and bounding box, plus
/// /Metadata/thumbnail.png extraction (FR-4.2 tier 2).
public struct ThreeMFParser: ModelFileParser {
    public let extensions: Set<String> = ["3mf"]

    public init() {}

    public func parse(fileURL: URL) throws -> GeometryStats {
        let zip = try ZipReader(fileURL: fileURL)

        // Model part is conventionally 3D/3dmodel.model; fall back to any
        // *.model entry (the spec allows other names via relationships).
        let modelEntry = zip.entry(at: "3D/3dmodel.model")
            ?? zip.entries.first { $0.path.lowercased().hasSuffix(".model") }
        guard let modelEntry else {
            throw ParseError.unreadable("no model part in 3MF")
        }
        let modelXML = try zip.extract(modelEntry)

        let delegate = ModelXMLDelegate()
        let parser = XMLParser(data: modelXML)
        parser.delegate = delegate
        parser.shouldProcessNamespaces = false
        guard parser.parse() || delegate.objectCount > 0 else {
            throw ParseError.unreadable("3MF model XML unparseable")
        }

        var stats = GeometryStats(
            triangleCount: delegate.triangleCount > 0 ? Int64(delegate.triangleCount) : nil,
            partCount: Int64(delegate.objectCount)
        )
        if delegate.minV.0.isFinite {
            stats.bboxX = delegate.maxV.0 - delegate.minV.0
            stats.bboxY = delegate.maxV.1 - delegate.minV.1
            stats.bboxZ = delegate.maxV.2 - delegate.minV.2
        }

        // Package thumbnail: standard location, else any package PNG under Metadata.
        let thumbEntry = zip.entry(at: "Metadata/thumbnail.png")
            ?? zip.entries.first { $0.path.lowercased().hasPrefix("metadata/") && $0.path.lowercased().hasSuffix(".png") }
        if let thumbEntry, let png = try? zip.extract(thumbEntry) {
            stats.embeddedThumbnail = png
        }

        return stats
    }
}

/// Streaming SAX delegate: counts <object> (top-level parts), <triangle>,
/// and accumulates vertex bounds without materializing geometry.
private final class ModelXMLDelegate: NSObject, XMLParserDelegate {
    var objectCount = 0
    var triangleCount = 0
    var minV = (Double.infinity, Double.infinity, Double.infinity)
    var maxV = (-Double.infinity, -Double.infinity, -Double.infinity)

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        switch elementName {
        case "object":
            // Count mesh objects only; "other"-type objects (support etc.) still count as parts.
            objectCount += 1
        case "triangle":
            triangleCount += 1
        case "vertex":
            if let xs = attributeDict["x"], let ys = attributeDict["y"], let zs = attributeDict["z"],
               let x = Double(xs), let y = Double(ys), let z = Double(zs) {
                if x < minV.0 { minV.0 = x }; if x > maxV.0 { maxV.0 = x }
                if y < minV.1 { minV.1 = y }; if y > maxV.1 { maxV.1 = y }
                if z < minV.2 { minV.2 = z }; if z > maxV.2 { maxV.2 = z }
            }
        default:
            break
        }
    }
}
