import Foundation

/// Pure-Swift xxHash64 (XXH64) — used for fast change detection at scan time.
/// Reference: https://github.com/Cyan4973/xxHash (spec, public domain).
public enum XXHash64 {
    private static let prime1: UInt64 = 0x9E3779B185EBCA87
    private static let prime2: UInt64 = 0xC2B2AE3D27D4EB4F
    private static let prime3: UInt64 = 0x165667B19E3779F9
    private static let prime4: UInt64 = 0x85EBCA77C2B2AE63
    private static let prime5: UInt64 = 0x27D4EB2F165667C5

    public static func hash(_ data: Data, seed: UInt64 = 0) -> UInt64 {
        data.withUnsafeBytes { hash($0, seed: seed) }
    }

    public static func hash(_ buffer: UnsafeRawBufferPointer, seed: UInt64 = 0) -> UInt64 {
        let count = buffer.count
        var h: UInt64
        var offset = 0

        if count >= 32 {
            var v1 = seed &+ prime1 &+ prime2
            var v2 = seed &+ prime2
            var v3 = seed
            var v4 = seed &- prime1
            let limit = count - 32
            repeat {
                v1 = round(v1, read64(buffer, offset)); offset += 8
                v2 = round(v2, read64(buffer, offset)); offset += 8
                v3 = round(v3, read64(buffer, offset)); offset += 8
                v4 = round(v4, read64(buffer, offset)); offset += 8
            } while offset <= limit
            h = rotl(v1, 1) &+ rotl(v2, 7) &+ rotl(v3, 12) &+ rotl(v4, 18)
            h = mergeRound(h, v1)
            h = mergeRound(h, v2)
            h = mergeRound(h, v3)
            h = mergeRound(h, v4)
        } else {
            h = seed &+ prime5
        }

        h &+= UInt64(count)

        while offset + 8 <= count {
            h ^= round(0, read64(buffer, offset))
            h = rotl(h, 27) &* prime1 &+ prime4
            offset += 8
        }
        if offset + 4 <= count {
            h ^= UInt64(read32(buffer, offset)) &* prime1
            h = rotl(h, 23) &* prime2 &+ prime3
            offset += 4
        }
        while offset < count {
            h ^= UInt64(buffer[offset]) &* prime5
            h = rotl(h, 11) &* prime1
            offset += 1
        }

        h ^= h >> 33
        h &*= prime2
        h ^= h >> 29
        h &*= prime3
        h ^= h >> 32
        return h
    }

    /// Streams a file in 1 MB chunks — memory-bounded for multi-GB files.
    public static func hashFile(at url: URL) throws -> UInt64 {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var state = StreamingState()
        while true {
            guard let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty else { break }
            state.update(chunk)
        }
        return state.finalize()
    }

    // MARK: - Streaming

    public struct StreamingState {
        private var v1 = UInt64(0) &+ prime1 &+ prime2
        private var v2 = UInt64(0) &+ prime2
        private var v3 = UInt64(0)
        private var v4 = UInt64(0) &- prime1
        private var buffer = Data()
        private var totalLength: UInt64 = 0
        private let seed: UInt64

        public init(seed: UInt64 = 0) {
            self.seed = seed
            v1 = seed &+ prime1 &+ prime2
            v2 = seed &+ prime2
            v3 = seed
            v4 = seed &- prime1
        }

        public mutating func update(_ data: Data) {
            totalLength += UInt64(data.count)
            // Fast path: nothing buffered → consume whole 32-byte stripes
            // straight from the input, only buffering the tail. Avoids
            // copying every chunk through `buffer` (hashFile reads 1 MB
            // chunks, so this is the steady-state path).
            if buffer.isEmpty {
                let usable = data.count - (data.count % 32)
                if usable > 0 {
                    data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
                        (v1, v2, v3, v4) = XXHash64.consumeStripes(raw, upTo: usable, state: (v1, v2, v3, v4))
                    }
                }
                if usable < data.count {
                    buffer.append(data.dropFirst(usable))
                }
                return
            }
            buffer.append(data)
            guard buffer.count >= 32 else { return }
            let usable = buffer.count - (buffer.count % 32)
            buffer.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
                (v1, v2, v3, v4) = XXHash64.consumeStripes(raw, upTo: usable, state: (v1, v2, v3, v4))
            }
            buffer.removeFirst(usable)
        }

        public mutating func finalize() -> UInt64 {
            var h: UInt64
            if totalLength >= 32 {
                h = XXHash64.rotl(v1, 1) &+ XXHash64.rotl(v2, 7) &+ XXHash64.rotl(v3, 12) &+ XXHash64.rotl(v4, 18)
                h = XXHash64.mergeRound(h, v1)
                h = XXHash64.mergeRound(h, v2)
                h = XXHash64.mergeRound(h, v3)
                h = XXHash64.mergeRound(h, v4)
            } else {
                h = seed &+ prime5
            }
            h &+= totalLength

            buffer.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
                var offset = 0
                let count = raw.count
                while offset + 8 <= count {
                    h ^= XXHash64.round(0, XXHash64.read64(raw, offset))
                    h = XXHash64.rotl(h, 27) &* prime1 &+ prime4
                    offset += 8
                }
                if offset + 4 <= count {
                    h ^= UInt64(XXHash64.read32(raw, offset)) &* prime1
                    h = XXHash64.rotl(h, 23) &* prime2 &+ prime3
                    offset += 4
                }
                while offset < count {
                    h ^= UInt64(raw[offset]) &* prime5
                    h = XXHash64.rotl(h, 11) &* prime1
                    offset += 1
                }
            }

            h ^= h >> 33
            h &*= prime2
            h ^= h >> 29
            h &*= prime3
            h ^= h >> 32
            return h
        }
    }

    // MARK: - Helpers

    private static func consumeStripes(
        _ raw: UnsafeRawBufferPointer,
        upTo usable: Int,
        state: (UInt64, UInt64, UInt64, UInt64)
    ) -> (UInt64, UInt64, UInt64, UInt64) {
        var (v1, v2, v3, v4) = state
        var offset = 0
        while offset < usable {
            v1 = round(v1, read64(raw, offset)); offset += 8
            v2 = round(v2, read64(raw, offset)); offset += 8
            v3 = round(v3, read64(raw, offset)); offset += 8
            v4 = round(v4, read64(raw, offset)); offset += 8
        }
        return (v1, v2, v3, v4)
    }

    private static func rotl(_ x: UInt64, _ r: UInt64) -> UInt64 {
        (x << r) | (x >> (64 - r))
    }

    private static func round(_ acc: UInt64, _ input: UInt64) -> UInt64 {
        var acc = acc &+ (input &* prime2)
        acc = rotl(acc, 31)
        return acc &* prime1
    }

    private static func mergeRound(_ acc: UInt64, _ val: UInt64) -> UInt64 {
        let acc = acc ^ round(0, val)
        return acc &* prime1 &+ prime4
    }

    private static func read64(_ buffer: UnsafeRawBufferPointer, _ offset: Int) -> UInt64 {
        buffer.loadUnaligned(fromByteOffset: offset, as: UInt64.self).littleEndian
    }

    private static func read32(_ buffer: UnsafeRawBufferPointer, _ offset: Int) -> UInt32 {
        buffer.loadUnaligned(fromByteOffset: offset, as: UInt32.self).littleEndian
    }
}
