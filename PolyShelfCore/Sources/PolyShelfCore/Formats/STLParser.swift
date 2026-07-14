import Foundation

/// STL stats extractor. Detects binary vs ASCII by content sniffing, never by
/// extension trust (§7): a binary STL is valid iff its 84-byte header's
/// triangle count matches the file size; "solid" prefix alone proves nothing
/// (many binary files start with "solid").
public struct STLParser: ModelFileParser {
    public let extensions: Set<String> = ["stl"]

    public init() {}

    public func parse(fileURL: URL) throws -> GeometryStats {
        guard let handle = try? FileHandle(forReadingFrom: fileURL) else {
            throw ParseError.unreadable("cannot open")
        }
        defer { try? handle.close() }

        let fileSize = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: 0)
        guard fileSize >= 15 else { throw ParseError.unreadable("too small for STL") }

        // Binary check: header(80) + count(4) + count * 50 == size
        if fileSize >= 84 {
            try? handle.seek(toOffset: 80)
            if let countData = try? handle.read(upToCount: 4), countData.count == 4 {
                let count = countData.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self).littleEndian }
                if UInt64(84) + UInt64(count) * 50 == fileSize {
                    return try parseBinary(handle: handle, triangleCount: count)
                }
            }
        }
        return try parseASCII(fileURL: fileURL, fileSize: fileSize)
    }

    // MARK: - Binary

    private func parseBinary(handle: FileHandle, triangleCount: UInt32) throws -> GeometryStats {
        var minV = (Double.infinity, Double.infinity, Double.infinity)
        var maxV = (-Double.infinity, -Double.infinity, -Double.infinity)

        try? handle.seek(toOffset: 84)
        // Each triangle record: normal(12) + 3 vertices(36) + attr(2) = 50 bytes.
        // Stream in ~1 MB chunks aligned to whole records.
        let recordSize = 50
        let recordsPerChunk = 20_000
        var remaining = Int(triangleCount)
        while remaining > 0 {
            let batch = min(remaining, recordsPerChunk)
            guard let chunk = try? handle.read(upToCount: batch * recordSize),
                  chunk.count == batch * recordSize else {
                throw ParseError.unreadable("truncated binary STL body")
            }
            chunk.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
                for r in 0..<batch {
                    let base = r * recordSize + 12 // skip normal
                    for v in 0..<3 {
                        let voff = base + v * 12
                        let x = Double(raw.loadUnaligned(fromByteOffset: voff, as: Float32.self))
                        let y = Double(raw.loadUnaligned(fromByteOffset: voff + 4, as: Float32.self))
                        let z = Double(raw.loadUnaligned(fromByteOffset: voff + 8, as: Float32.self))
                        if x < minV.0 { minV.0 = x }; if x > maxV.0 { maxV.0 = x }
                        if y < minV.1 { minV.1 = y }; if y > maxV.1 { maxV.1 = y }
                        if z < minV.2 { minV.2 = z }; if z > maxV.2 { maxV.2 = z }
                    }
                }
            }
            remaining -= batch
        }

        guard minV.0.isFinite else { throw ParseError.unreadable("no geometry") }
        return GeometryStats(
            bboxX: maxV.0 - minV.0,
            bboxY: maxV.1 - minV.1,
            bboxZ: maxV.2 - minV.2,
            triangleCount: Int64(triangleCount),
            partCount: 1
        )
    }

    // MARK: - ASCII

    private func parseASCII(fileURL: URL, fileSize: UInt64) throws -> GeometryStats {
        // ASCII STL grammar is line-based: "vertex x y z" lines carry all
        // geometry. Stream line-by-line to stay memory-bounded.
        guard fileSize < 512 * 1024 * 1024 else {
            throw ParseError.unreadable("ASCII STL too large")
        }
        guard let data = try? Data(contentsOf: fileURL, options: .mappedIfSafe),
              let head = String(data: data.prefix(64), encoding: .utf8),
              head.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().hasPrefix("solid") else {
            throw ParseError.unreadable("neither valid binary nor ASCII STL")
        }

        var minV = (Double.infinity, Double.infinity, Double.infinity)
        var maxV = (-Double.infinity, -Double.infinity, -Double.infinity)
        var triangles: Int64 = 0
        var vertexInFacet = 0

        // Fast byte-level line scan; ASCII STL is guaranteed 7-bit.
        var lineStart = data.startIndex
        let newline = UInt8(ascii: "\n")
        while lineStart < data.endIndex {
            let lineEnd = data[lineStart...].firstIndex(of: newline) ?? data.endIndex
            defer { lineStart = lineEnd == data.endIndex ? data.endIndex : data.index(after: lineEnd) }

            guard let line = String(data: data[lineStart..<lineEnd], encoding: .ascii) else { continue }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("vertex") {
                let comps = trimmed.split(separator: " ", omittingEmptySubsequences: true)
                guard comps.count >= 4,
                      let x = Double(comps[1]), let y = Double(comps[2]), let z = Double(comps[3]) else {
                    throw ParseError.unreadable("malformed vertex line")
                }
                if x < minV.0 { minV.0 = x }; if x > maxV.0 { maxV.0 = x }
                if y < minV.1 { minV.1 = y }; if y > maxV.1 { maxV.1 = y }
                if z < minV.2 { minV.2 = z }; if z > maxV.2 { maxV.2 = z }
                vertexInFacet += 1
                if vertexInFacet == 3 {
                    triangles += 1
                    vertexInFacet = 0
                }
            }
        }

        guard triangles > 0 else { throw ParseError.unreadable("no facets in ASCII STL") }
        return GeometryStats(
            bboxX: maxV.0 - minV.0,
            bboxY: maxV.1 - minV.1,
            bboxZ: maxV.2 - minV.2,
            triangleCount: triangles,
            partCount: 1
        )
    }
}
