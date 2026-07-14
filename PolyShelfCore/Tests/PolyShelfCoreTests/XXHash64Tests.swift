import XCTest
@testable import PolyShelfCore

final class XXHash64Tests: XCTestCase {
    // Reference vectors from the canonical xxHash implementation.
    func testKnownVectors() {
        XCTAssertEqual(XXHash64.hash(Data()), 0xEF46DB3751D8E999)
        XCTAssertEqual(XXHash64.hash(Data("a".utf8)), 0xD24EC4F1A98C6E5B)
        XCTAssertEqual(XXHash64.hash(Data("abc".utf8)), 0x44BC2CF5AD770999)
    }

    func testStreamingMatchesOneShot() {
        // Cover all code paths: empty, <32B tail combos, exact block, big.
        for size in [0, 1, 4, 7, 31, 32, 33, 63, 64, 100, 1024, (1 << 20) + 7] {
            var data = Data(capacity: size)
            var x: UInt8 = 7
            for _ in 0..<size {
                x = x &* 31 &+ 11
                data.append(x)
            }
            let oneShot = XXHash64.hash(data)

            var state = XXHash64.StreamingState()
            // Feed in uneven chunks to exercise buffering.
            var offset = 0
            var chunk = 13
            while offset < data.count {
                let end = min(offset + chunk, data.count)
                state.update(data.subdata(in: offset..<end))
                offset = end
                chunk = chunk * 2 + 1
            }
            XCTAssertEqual(state.finalize(), oneShot, "mismatch at size \(size)")
        }
    }

    func testHashFileMatchesInMemory() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("xxhash-test-\(UUID().uuidString).bin")
        defer { try? FileManager.default.removeItem(at: url) }
        let data = Data((0..<100_000).map { UInt8(truncatingIfNeeded: $0 &* 2654435761) })
        try data.write(to: url)
        XCTAssertEqual(try XXHash64.hashFile(at: url), XXHash64.hash(data))
    }
}
