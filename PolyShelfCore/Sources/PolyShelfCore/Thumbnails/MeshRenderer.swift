import Foundation
import AppKit
import SceneKit
import SceneKit.ModelIO
import ModelIO

/// Offscreen SceneKit render for mesh formats (FR-4.2 tier 1): neutral studio
/// lighting, deterministic isometric camera framed from the bounding box,
/// matte single-color material for STL/mesh-only formats.
public enum MeshRenderer {
    public static let renderableExtensions: Set<String> = ["stl", "obj", "ply", "usd", "usdz", "abc"]

    /// Formats with no material/color of their own get the matte finish.
    private static let matteExtensions: Set<String> = ["stl", "ply"]

    public static func renderThumbnail(fileURL: URL, size: Int = 512) -> Data? {
        autoreleasepool {
            guard let scene = loadScene(fileURL: fileURL) else { return nil }
            return snapshot(scene: scene, size: size)
        }
    }

    /// Builds the presentation scene (also used by the interactive detail viewer).
    public static func loadScene(fileURL: URL) -> SCNScene? {
        let ext = fileURL.pathExtension.lowercased()
        guard MDLAsset.canImportFileExtension(ext) else { return nil }
        let asset = MDLAsset(url: fileURL)
        guard asset.count > 0 else { return nil }
        let scene = SCNScene(mdlAsset: asset)

        if matteExtensions.contains(ext) {
            let material = SCNMaterial()
            material.diffuse.contents = NSColor(calibratedRed: 0.72, green: 0.75, blue: 0.78, alpha: 1)
            material.roughness.contents = 0.6
            material.metalness.contents = 0.05
            material.lightingModel = .physicallyBased
            scene.rootNode.enumerateHierarchy { node, _ in
                node.geometry?.materials = [material]
            }
        }

        // Print formats are Z-up; SceneKit is Y-up. Rotate so models stand upright.
        if ["stl", "ply", "obj"].contains(ext) {
            let container = SCNNode()
            for child in scene.rootNode.childNodes {
                child.removeFromParentNode()
                container.addChildNode(child)
            }
            container.eulerAngles.x = -.pi / 2
            scene.rootNode.addChildNode(container)
        }

        return scene
    }

    public static func snapshot(scene: SCNScene, size: Int) -> Data? {
        guard let device = MTLCreateSystemDefaultDevice() else { return nil }

        applyStudioLighting(to: scene)
        let cameraNode = makeIsometricCamera(for: scene)
        scene.rootNode.addChildNode(cameraNode)
        scene.background.contents = NSColor(calibratedWhite: 0.96, alpha: 1)

        let renderer = SCNRenderer(device: device, options: nil)
        renderer.scene = scene
        renderer.pointOfView = cameraNode
        renderer.autoenablesDefaultLighting = false

        let image = renderer.snapshot(
            atTime: 0,
            with: CGSize(width: size, height: size),
            antialiasingMode: .multisampling4X
        )
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else {
            return nil
        }
        return png
    }

    // MARK: - Deterministic camera & lights

    /// Isometric-ish framing (~30° elevation, 45° azimuth) computed purely
    /// from the scene bounding sphere → identical files render identically.
    private static func makeIsometricCamera(for scene: SCNScene) -> SCNNode {
        var center = SCNVector3Zero
        var radius: CGFloat = 1
        let (minB, maxB) = scene.rootNode.boundingBox
        center = SCNVector3(
            (minB.x + maxB.x) / 2,
            (minB.y + maxB.y) / 2,
            (minB.z + maxB.z) / 2
        )
        let dx = maxB.x - minB.x, dy = maxB.y - minB.y, dz = maxB.z - minB.z
        radius = max(CGFloat(sqrt(dx * dx + dy * dy + dz * dz)) / 2, 0.001)

        let camera = SCNCamera()
        camera.fieldOfView = 40
        camera.zNear = Double(radius) * 0.01
        camera.zFar = Double(radius) * 20
        camera.wantsDepthOfField = false

        let node = SCNNode()
        node.camera = camera
        let distance = radius / tan(camera.fieldOfView / 2 * .pi / 180) * 1.15
        // 45° azimuth, ~30° elevation
        let azimuth = CGFloat.pi / 4
        let elevation = CGFloat.pi / 6
        node.position = SCNVector3(
            center.x + CGFloat(distance * cos(elevation) * sin(azimuth)),
            center.y + CGFloat(distance * sin(elevation)),
            center.z + CGFloat(distance * cos(elevation) * cos(azimuth))
        )
        node.look(at: center)
        return node
    }

    private static func applyStudioLighting(to scene: SCNScene) {
        let ambient = SCNNode()
        ambient.light = SCNLight()
        ambient.light!.type = .ambient
        ambient.light!.intensity = 250
        ambient.light!.color = NSColor.white
        scene.rootNode.addChildNode(ambient)

        let key = SCNNode()
        key.light = SCNLight()
        key.light!.type = .directional
        key.light!.intensity = 850
        key.eulerAngles = SCNVector3(-CGFloat.pi / 3, -CGFloat.pi / 5, 0)
        scene.rootNode.addChildNode(key)

        let fill = SCNNode()
        fill.light = SCNLight()
        fill.light!.type = .directional
        fill.light!.intensity = 350
        fill.eulerAngles = SCNVector3(-CGFloat.pi / 6, CGFloat.pi * 0.7, 0)
        scene.rootNode.addChildNode(fill)
    }
}
