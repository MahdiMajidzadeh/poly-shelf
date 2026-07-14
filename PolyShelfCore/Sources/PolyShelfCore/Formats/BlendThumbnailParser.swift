import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// Best-effort `.blend` preview extraction (§10 Q4 — attempt, fall back
/// silently). Uncompressed .blend files store a "TEST" block containing the
/// file preview as width/height + RGBA pixels. Compressed files (gzip/zstd,
/// Blender 3.0+ default varies) are skipped → format icon.
public struct BlendThumbnailParser: ModelFileParser {
    public let extensions: Set<String> = ["blend"]

    public init() {}

    public func parse(fileURL: URL) throws -> GeometryStats {
        guard let data = try? Data(contentsOf: fileURL, options: .mappedIfSafe),
              data.count > 12 else {
            throw ParseError.unreadable("cannot read .blend")
        }
        // Header: "BLENDER" + pointer size ('_' 32-bit / '-' 64-bit) + endian ('v' little / 'V' big) + version
        guard data.prefix(7) == Data("BLENDER".utf8) else {
            // gzip (1F 8B) or zstd (28 B5 2F FD) compressed — silent fallback, not an error.
            return GeometryStats()
        }
        let pointerSize = data[7] == UInt8(ascii: "_") ? 4 : 8
        let littleEndian = data[8] == UInt8(ascii: "v")
        guard littleEndian else { return GeometryStats() } // big-endian blends are ancient; skip

        func u32(_ offset: Int) -> UInt32? {
            guard offset + 4 <= data.count else { return nil }
            return UInt32(data[offset]) | (UInt32(data[offset + 1]) << 8)
                | (UInt32(data[offset + 2]) << 16) | (UInt32(data[offset + 3]) << 24)
        }

        // Block headers: code[4] + len[4] + oldPtr[ptrSize] + SDNAnr[4] + nr[4]
        var offset = 12
        let headerSize = 4 + 4 + pointerSize + 4 + 4
        while offset + headerSize <= data.count {
            let code = data.subdata(in: offset..<(offset + 4))
            guard let length = u32(offset + 4) else { break }
            let bodyStart = offset + headerSize
            let bodyEnd = bodyStart + Int(length)
            guard bodyEnd <= data.count else { break }

            if code == Data("TEST".utf8) {
                guard let w32 = u32(bodyStart), let h32 = u32(bodyStart + 4) else { break }
                let width = Int(w32), height = Int(h32)
                let pixelBytes = width * height * 4
                guard width > 0, height > 0, width <= 1024, height <= 1024,
                      bodyStart + 8 + pixelBytes <= bodyEnd else { break }
                let rgba = data.subdata(in: (bodyStart + 8)..<(bodyStart + 8 + pixelBytes))
                if let png = Self.encodePNG(rgba: rgba, width: width, height: height) {
                    return GeometryStats(embeddedThumbnail: png)
                }
                break
            }
            if code == Data("ENDB".utf8) { break }
            offset = bodyEnd
        }
        return GeometryStats() // no preview — icon fallback, never an error
    }

    /// Blender previews are bottom-up RGBA8; flip vertically while encoding.
    static func encodePNG(rgba: Data, width: Int, height: Int) -> Data? {
        var flipped = Data(capacity: rgba.count)
        let rowBytes = width * 4
        for row in stride(from: height - 1, through: 0, by: -1) {
            flipped.append(rgba.subdata(in: (row * rowBytes)..<((row + 1) * rowBytes)))
        }
        guard let provider = CGDataProvider(data: flipped as CFData),
              let image = CGImage(
                width: width, height: height,
                bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: rowBytes,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
                provider: provider, decode: nil, shouldInterpolate: false,
                intent: .defaultIntent
              ) else { return nil }
        let output = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return output as Data
    }
}
