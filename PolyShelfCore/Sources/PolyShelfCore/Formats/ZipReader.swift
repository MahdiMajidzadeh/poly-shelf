import Foundation
import Compression

/// Minimal read-only ZIP container access — enough for 3MF packages
/// (stored + deflate entries, no zip64, no encryption). Reads the central
/// directory once; entries are extracted on demand.
public struct ZipReader {
    public struct Entry: Sendable {
        public let path: String
        let compressionMethod: UInt16
        let compressedSize: UInt32
        let uncompressedSize: UInt32
        let localHeaderOffset: UInt32
    }

    public let entries: [Entry]
    private let data: Data

    public init(fileURL: URL) throws {
        guard let data = try? Data(contentsOf: fileURL, options: .mappedIfSafe) else {
            throw ParseError.unreadable("cannot read zip")
        }
        try self.init(data: data)
    }

    public init(data: Data) throws {
        self.data = data
        // End-of-central-directory: signature 0x06054b50, within the last
        // 64 KB + 22 bytes (comment can pad the tail).
        guard data.count >= 22 else { throw ParseError.unreadable("zip too small") }
        let searchStart = max(0, data.count - 22 - 65_536)
        var eocdOffset = -1
        var i = data.count - 22
        while i >= searchStart {
            if data[i] == 0x50, data[i + 1] == 0x4B, data[i + 2] == 0x05, data[i + 3] == 0x06 {
                eocdOffset = i
                break
            }
            i -= 1
        }
        guard eocdOffset >= 0 else { throw ParseError.unreadable("no zip end-of-central-directory") }

        func u16(_ offset: Int) -> UInt16 {
            UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
        }
        func u32(_ offset: Int) -> UInt32 {
            UInt32(data[offset]) | (UInt32(data[offset + 1]) << 8)
                | (UInt32(data[offset + 2]) << 16) | (UInt32(data[offset + 3]) << 24)
        }

        let entryCount = Int(u16(eocdOffset + 10))
        var cdOffset = Int(u32(eocdOffset + 16))

        var entries: [Entry] = []
        entries.reserveCapacity(entryCount)
        for _ in 0..<entryCount {
            guard cdOffset + 46 <= data.count,
                  u32(cdOffset) == 0x02014B50 else {
                throw ParseError.unreadable("corrupt zip central directory")
            }
            let method = u16(cdOffset + 10)
            let compressedSize = u32(cdOffset + 20)
            let uncompressedSize = u32(cdOffset + 24)
            let nameLength = Int(u16(cdOffset + 28))
            let extraLength = Int(u16(cdOffset + 30))
            let commentLength = Int(u16(cdOffset + 32))
            let localOffset = u32(cdOffset + 42)
            guard cdOffset + 46 + nameLength <= data.count else {
                throw ParseError.unreadable("corrupt zip entry name")
            }
            let name = String(data: data[(cdOffset + 46)..<(cdOffset + 46 + nameLength)], encoding: .utf8) ?? ""
            entries.append(Entry(
                path: name,
                compressionMethod: method,
                compressedSize: compressedSize,
                uncompressedSize: uncompressedSize,
                localHeaderOffset: localOffset
            ))
            cdOffset += 46 + nameLength + extraLength + commentLength
        }
        self.entries = entries
    }

    /// Case-insensitive lookup, tolerant of a leading slash.
    public func entry(at path: String) -> Entry? {
        let normalized = path.hasPrefix("/") ? String(path.dropFirst()) : path
        return entries.first { $0.path.caseInsensitiveCompare(normalized) == .orderedSame }
    }

    public func extract(_ entry: Entry) throws -> Data {
        func u16(_ offset: Int) -> UInt16 {
            UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
        }
        let lh = Int(entry.localHeaderOffset)
        guard lh + 30 <= data.count,
              data[lh] == 0x50, data[lh + 1] == 0x4B, data[lh + 2] == 0x03, data[lh + 3] == 0x04 else {
            throw ParseError.unreadable("corrupt zip local header")
        }
        let nameLength = Int(u16(lh + 26))
        let extraLength = Int(u16(lh + 28))
        let dataStart = lh + 30 + nameLength + extraLength
        let dataEnd = dataStart + Int(entry.compressedSize)
        guard dataEnd <= data.count else { throw ParseError.unreadable("truncated zip entry") }
        let compressed = data.subdata(in: dataStart..<dataEnd)

        switch entry.compressionMethod {
        case 0: // stored
            return compressed
        case 8: // deflate
            return try inflate(compressed, uncompressedSize: Int(entry.uncompressedSize))
        default:
            throw ParseError.unreadable("unsupported zip compression method \(entry.compressionMethod)")
        }
    }

    private func inflate(_ compressed: Data, uncompressedSize: Int) throws -> Data {
        guard uncompressedSize > 0 else { return Data() }
        // Cap at 512 MB as a corruption guard (3MF model XML is never that big).
        guard uncompressedSize <= 512 * 1024 * 1024 else {
            throw ParseError.unreadable("zip entry implausibly large")
        }
        var output = Data(count: uncompressedSize)
        let written = output.withUnsafeMutableBytes { (dst: UnsafeMutableRawBufferPointer) in
            compressed.withUnsafeBytes { (src: UnsafeRawBufferPointer) in
                compression_decode_buffer(
                    dst.bindMemory(to: UInt8.self).baseAddress!, uncompressedSize,
                    src.bindMemory(to: UInt8.self).baseAddress!, compressed.count,
                    nil, COMPRESSION_ZLIB
                )
            }
        }
        guard written == uncompressedSize else {
            throw ParseError.unreadable("zip inflate failed")
        }
        return output
    }
}
