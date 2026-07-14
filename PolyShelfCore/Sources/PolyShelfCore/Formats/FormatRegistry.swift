import Foundation

public enum FormatGroup: String, Codable, CaseIterable, Sendable {
    case printMesh = "Print mesh"
    case universal = "Universal/DCC"
    case cad = "CAD"
    case source = "Source"
    case slicerOutput = "Slicer output"
    case archive = "Archive"
}

/// How a format's preview is produced (first matching tier wins at render time;
/// this is the *primary* tier the format routes to).
public enum PreviewTier: String, Codable, Sendable {
    case meshRender        // ModelIO/SceneKit offscreen render
    case embeddedThumbnail // extracted from the file (3MF, GCODE, .blend)
    case quickLook         // QuickLookThumbnailing
    case icon              // format-specific fallback icon only
}

public struct FormatSpec: Sendable, Equatable {
    /// Lowercase extension without dot.
    public let ext: String
    public let group: FormatGroup
    public let previewTier: PreviewTier
    public let defaultEnabled: Bool
    /// Whether ModelIO can load geometry for the interactive detail viewer.
    public let interactive3D: Bool

    public init(_ ext: String, _ group: FormatGroup, _ previewTier: PreviewTier, defaultEnabled: Bool, interactive3D: Bool = false) {
        self.ext = ext
        self.group = group
        self.previewTier = previewTier
        self.defaultEnabled = defaultEnabled
        self.interactive3D = interactive3D
    }
}

/// The single registry driving scan filtering, preview routing, settings UI,
/// and format tags (FR-3.x). Adding a future extension is a one-line change.
public enum FormatRegistry {
    public static let all: [FormatSpec] = [
        // Print mesh — full 3D render, on by default
        FormatSpec("stl", .printMesh, .meshRender, defaultEnabled: true, interactive3D: true),
        // 3MF: ModelIO can't load its geometry; slicer 3MFs carry a package
        // thumbnail (extracted by ThreeMFParser), so that's the primary tier.
        FormatSpec("3mf", .printMesh, .embeddedThumbnail, defaultEnabled: true),
        FormatSpec("obj", .printMesh, .meshRender, defaultEnabled: true, interactive3D: true),
        FormatSpec("ply", .printMesh, .meshRender, defaultEnabled: true, interactive3D: true),
        // AMF: ModelIO/SceneKit can't load it — icon tier in v1 (deviation
        // from the PRD's "full 3D render"; needs a custom parser later).
        FormatSpec("amf", .printMesh, .icon, defaultEnabled: true),

        // Universal/DCC
        FormatSpec("usdz", .universal, .quickLook, defaultEnabled: true, interactive3D: true),
        FormatSpec("usd", .universal, .quickLook, defaultEnabled: false, interactive3D: true),
        // glTF: neither ModelIO nor SceneKit loads it natively — QuickLook
        // tier (renders only if a QL plugin is installed), else icon.
        FormatSpec("gltf", .universal, .quickLook, defaultEnabled: true),
        FormatSpec("glb", .universal, .quickLook, defaultEnabled: true),
        FormatSpec("fbx", .universal, .quickLook, defaultEnabled: false),
        FormatSpec("dae", .universal, .quickLook, defaultEnabled: false),
        FormatSpec("abc", .universal, .meshRender, defaultEnabled: false, interactive3D: true),

        // CAD — metadata + icon in v1 (FR-4.4)
        FormatSpec("step", .cad, .icon, defaultEnabled: false),
        FormatSpec("stp", .cad, .icon, defaultEnabled: false),
        FormatSpec("iges", .cad, .icon, defaultEnabled: false),
        FormatSpec("igs", .cad, .icon, defaultEnabled: false),

        // Source
        FormatSpec("blend", .source, .embeddedThumbnail, defaultEnabled: false),
        FormatSpec("f3d", .source, .icon, defaultEnabled: false),
        FormatSpec("scad", .source, .icon, defaultEnabled: false),
        FormatSpec("shapr", .source, .icon, defaultEnabled: false),

        // Slicer output — embedded thumbnail, on by default
        FormatSpec("gcode", .slicerOutput, .embeddedThumbnail, defaultEnabled: true),
        FormatSpec("bgcode", .slicerOutput, .embeddedThumbnail, defaultEnabled: true),
        FormatSpec("gx", .slicerOutput, .embeddedThumbnail, defaultEnabled: true),

        // Archives — listed only when "show archives" is on, never unpacked (FR-2.5)
        FormatSpec("zip", .archive, .icon, defaultEnabled: false),
        FormatSpec("rar", .archive, .icon, defaultEnabled: false),
    ]

    public static let byExt: [String: FormatSpec] = Dictionary(
        uniqueKeysWithValues: all.map { ($0.ext, $0) }
    )

    public static func spec(forExtension ext: String) -> FormatSpec? {
        byExt[ext.lowercased()]
    }

    /// Extensions enabled by default on first launch.
    public static var defaultEnabledExtensions: Set<String> {
        Set(all.filter(\.defaultEnabled).map(\.ext))
    }
}
