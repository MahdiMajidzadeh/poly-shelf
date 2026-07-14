import Foundation

/// Extracts embedded preview images from slicer output (FR-4.2 tier 2).
/// - `.gcode`: PrusaSlicer/BambuStudio/OrcaSlicer "; thumbnail begin WxH size"
///   base64 PNG comment blocks — the largest resolution wins.
/// - `.bgcode`: binary G-code; the PNG payload is located by signature scan
///   (thumbnail blocks are stored uncompressed in practice; silent fallback).
/// - `.gx`: FlashForge container with a BMP preview at a fixed offset.
/// No geometry stats — items are tagged `presliced` by the tagger instead.
public struct GCodeThumbnailParser: ModelFileParser {
    public let extensions: Set<String> = ["gcode", "bgcode", "gx"]

    /// Thumbnails live near the top of the file; reading further is waste.
    private static let headLimit = 4 * 1024 * 1024

    public init() {}

    public func parse(fileURL: URL) throws -> GeometryStats {
        guard let handle = try? FileHandle(forReadingFrom: fileURL) else {
            throw ParseError.unreadable("cannot open")
        }
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: Self.headLimit), !head.isEmpty else {
            throw ParseError.unreadable("empty file")
        }

        let thumbnail: Data?
        switch fileURL.pathExtension.lowercased() {
        case "gcode":
            thumbnail = Self.extractAsciiThumbnail(from: head)
        case "bgcode":
            thumbnail = Self.extractPNGBySignature(from: head)
        case "gx":
            thumbnail = Self.extractGXBitmap(from: head)
        default:
            thumbnail = nil
        }
        return GeometryStats(embeddedThumbnail: thumbnail)
    }

    // MARK: - ASCII gcode comment blocks

    static func extractAsciiThumbnail(from data: Data) -> Data? {
        guard let text = String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .isoLatin1) else { return nil }

        var best: (pixels: Int, base64: String)?
        var current: (pixels: Int, lines: [String])?

        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix(";") else {
                // Thumbnails precede actual gcode; stop at the first command
                // once we've captured at least one block.
                if best != nil && !line.isEmpty { break }
                continue
            }
            let comment = line.dropFirst().trimmingCharacters(in: .whitespaces)

            if comment.lowercased().hasPrefix("thumbnail begin") {
                // "; thumbnail begin 220x124 5240"
                let parts = comment.split(separator: " ")
                var pixels = 0
                if parts.count >= 3 {
                    let dims = parts[2].lowercased().split(separator: "x")
                    if dims.count == 2, let w = Int(dims[0]), let h = Int(dims[1]) {
                        pixels = w * h
                    }
                }
                current = (pixels, [])
            } else if comment.lowercased().hasPrefix("thumbnail end") {
                if let block = current {
                    let joined = block.lines.joined()
                    if best == nil || block.pixels > best!.pixels {
                        best = (block.pixels, joined)
                    }
                }
                current = nil
            } else if current != nil {
                current!.lines.append(comment)
            }
        }

        guard let best, let png = Data(base64Encoded: best.base64) else { return nil }
        return png
    }

    // MARK: - Binary formats

    /// Finds the first complete PNG (signature → IEND) in a byte buffer.
    static func extractPNGBySignature(from data: Data) -> Data? {
        let pngMagic: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
        let iend: [UInt8] = [0x49, 0x45, 0x4E, 0x44] // "IEND"
        guard let start = data.firstRange(of: Data(pngMagic))?.lowerBound else { return nil }
        guard let iendRange = data[start...].firstRange(of: Data(iend)) else { return nil }
        // IEND chunk: length(4) + "IEND" + CRC(4); we found the type, so the
        // chunk ends 8 bytes after the type's start (4 type + 4 CRC).
        let end = iendRange.lowerBound + 8
        guard end <= data.endIndex else { return nil }
        return data.subdata(in: start..<end)
    }

    /// FlashForge .gx: fixed-layout header, 80×60 BMP preview at offset 0x3A.
    static func extractGXBitmap(from data: Data) -> Data? {
        let offset = 0x3A
        guard data.count > offset + 2,
              data[offset] == 0x42, data[offset + 1] == 0x4D else { return nil } // "BM"
        // BMP file size is stored little-endian at +2 from "BM".
        guard data.count >= offset + 6 else { return nil }
        let size = Int(data[offset + 2]) | (Int(data[offset + 3]) << 8)
            | (Int(data[offset + 4]) << 16) | (Int(data[offset + 5]) << 24)
        guard size > 0, size < 1_000_000, offset + size <= data.count else { return nil }
        return data.subdata(in: offset..<(offset + size))
    }
}
