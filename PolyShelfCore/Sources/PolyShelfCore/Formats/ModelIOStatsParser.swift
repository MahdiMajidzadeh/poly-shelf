import Foundation
import ModelIO

/// Geometry stats via MDLAsset for formats ModelIO actually loads
/// (OBJ, PLY, USD/USDZ, ABC — see §7). STL is handled by the cheaper
/// streaming STLParser; formats ModelIO can't load (glTF, FBX, DAE, AMF)
/// are deliberately absent and fall back to QuickLook/icon tiers.
public struct ModelIOStatsParser: ModelFileParser {
    public let extensions: Set<String> = ["obj", "ply", "usd", "usdz", "abc"]

    /// MDLAsset loads eagerly; cap input size to bound transient memory.
    private static let maxFileSize: Int64 = 500 * 1024 * 1024

    public init() {}

    public func parse(fileURL: URL) throws -> GeometryStats {
        let size = (try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
        guard size <= Self.maxFileSize else {
            return GeometryStats() // too big for eager load; skip stats, keep item ok
        }
        guard MDLAsset.canImportFileExtension(fileURL.pathExtension.lowercased()) else {
            return GeometryStats()
        }

        let asset = MDLAsset(url: fileURL)
        guard asset.count > 0 else {
            throw ParseError.unreadable("ModelIO loaded no objects")
        }

        let bounds = asset.boundingBox
        var triangles: Int64 = 0
        var parts: Int64 = 0
        for i in 0..<asset.count {
            for mesh in Self.meshes(in: asset.object(at: i)) {
                parts += 1
                for case let submesh as MDLSubmesh in mesh.submeshes ?? [] {
                    switch submesh.geometryType {
                    case .triangles:
                        triangles += Int64(submesh.indexCount / 3)
                    case .quads:
                        triangles += Int64(submesh.indexCount / 4 * 2)
                    default:
                        break
                    }
                }
            }
        }

        let extents = (
            Double(bounds.maxBounds.x - bounds.minBounds.x),
            Double(bounds.maxBounds.y - bounds.minBounds.y),
            Double(bounds.maxBounds.z - bounds.minBounds.z)
        )
        return GeometryStats(
            bboxX: extents.0.isFinite && extents.0 >= 0 ? extents.0 : nil,
            bboxY: extents.1.isFinite && extents.1 >= 0 ? extents.1 : nil,
            bboxZ: extents.2.isFinite && extents.2 >= 0 ? extents.2 : nil,
            triangleCount: triangles > 0 ? triangles : nil,
            partCount: parts > 0 ? parts : nil
        )
    }

    private static func meshes(in object: MDLObject) -> [MDLMesh] {
        var result: [MDLMesh] = []
        if let mesh = object as? MDLMesh { result.append(mesh) }
        for child in object.children.objects {
            result.append(contentsOf: meshes(in: child))
        }
        return result
    }
}
