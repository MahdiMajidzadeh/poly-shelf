import Foundation

/// Geometry/metadata extracted from a model file (FR-2.2).
public struct GeometryStats: Sendable, Equatable {
    /// Bounding box in the file's native units (mm for print formats).
    public var bboxX: Double?
    public var bboxY: Double?
    public var bboxZ: Double?
    public var triangleCount: Int64?
    /// Number of objects/parts (3MF objects, OBJ groups).
    public var partCount: Int64?
    /// Embedded preview image (3MF package thumbnail PNG, GCODE PNG, .gx BMP,
    /// .blend preview) — any format ImageIO can decode.
    public var embeddedThumbnail: Data?

    public init(
        bboxX: Double? = nil, bboxY: Double? = nil, bboxZ: Double? = nil,
        triangleCount: Int64? = nil, partCount: Int64? = nil,
        embeddedThumbnail: Data? = nil
    ) {
        self.bboxX = bboxX
        self.bboxY = bboxY
        self.bboxZ = bboxZ
        self.triangleCount = triangleCount
        self.partCount = partCount
        self.embeddedThumbnail = embeddedThumbnail
    }
}

public enum ParseError: Error, Equatable {
    case unreadable(String)
    case unsupported
}

/// A format-specific stats extractor. Implementations must be cheap on memory
/// (stream, don't slurp) and must throw `ParseError.unreadable` rather than
/// crash on corrupt input (edge case: unreadable files never kill the scanner).
public protocol ModelFileParser: Sendable {
    /// Extensions (lowercase, no dot) this parser handles.
    var extensions: Set<String> { get }
    func parse(fileURL: URL) throws -> GeometryStats
}
