import XCTest
@testable import PolyShelfCore

final class ParserTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("polyshelf-parse-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func writeTemp(_ name: String, _ data: Data) throws -> URL {
        let url = tempDir.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }

    // MARK: - STL fixtures

    /// One triangle spanning (0,0,0)–(10,20,5).
    private func binarySTL(triangles: [(Float, Float, Float)]...) -> Data {
        var data = Data(count: 80) // header
        var count = UInt32(triangles.count).littleEndian
        data.append(Data(bytes: &count, count: 4))
        for tri in triangles {
            data.append(Data(count: 12)) // normal
            for v in tri {
                for f in [v.0, v.1, v.2] {
                    var bits = f.bitPattern.littleEndian
                    data.append(Data(bytes: &bits, count: 4))
                }
            }
            data.append(Data(count: 2)) // attribute
        }
        return data
    }

    func testBinarySTL() throws {
        let stl = binarySTL(
            [(0, 0, 0), (10, 0, 0), (0, 20, 5)],
            [(0, 0, 0), (10, 0, 0), (10, 20, 0)]
        )
        let url = try writeTemp("bin.stl", stl)
        let stats = try STLParser().parse(fileURL: url)
        XCTAssertEqual(stats.triangleCount, 2)
        XCTAssertEqual(stats.bboxX!, 10, accuracy: 0.001)
        XCTAssertEqual(stats.bboxY!, 20, accuracy: 0.001)
        XCTAssertEqual(stats.bboxZ!, 5, accuracy: 0.001)
    }

    func testASCIISTL() throws {
        let ascii = """
        solid demo
          facet normal 0 0 1
            outer loop
              vertex 0 0 0
              vertex 240 0 0
              vertex 0 50 12.5
            endloop
          endfacet
        endsolid demo
        """
        let url = try writeTemp("ascii.stl", Data(ascii.utf8))
        let stats = try STLParser().parse(fileURL: url)
        XCTAssertEqual(stats.triangleCount, 1)
        XCTAssertEqual(stats.bboxX!, 240, accuracy: 0.001)
    }

    /// Binary STL whose content begins with "solid" — sniffing must not trust it.
    func testBinarySTLStartingWithSolid() throws {
        var stl = binarySTL([(0, 0, 0), (1, 0, 0), (0, 1, 1)])
        stl.replaceSubrange(0..<5, with: Data("solid".utf8))
        let url = try writeTemp("tricky.stl", stl)
        let stats = try STLParser().parse(fileURL: url)
        XCTAssertEqual(stats.triangleCount, 1, "header-sniffed as binary despite 'solid' prefix")
    }

    func testCorruptSTLThrowsUnreadable() throws {
        // Claims 1000 triangles but has no body.
        var data = Data(count: 80)
        var count = UInt32(1000).littleEndian
        data.append(Data(bytes: &count, count: 4))
        data.append(Data(repeating: 0xAB, count: 37)) // garbage, wrong size
        let url = try writeTemp("corrupt.stl", data)
        XCTAssertThrowsError(try STLParser().parse(fileURL: url)) { error in
            guard case ParseError.unreadable = error else {
                return XCTFail("expected .unreadable, got \(error)")
            }
        }
    }

    // MARK: - ZIP / 3MF

    /// Minimal ZIP writer (stored entries only) for building 3MF fixtures.
    private func storedZip(_ files: [(path: String, data: Data)]) -> Data {
        var out = Data()
        var centralDirectory = Data()
        var offsets: [Int] = []

        func le16(_ v: Int) -> Data { withUnsafeBytes(of: UInt16(v).littleEndian) { Data($0) } }
        func le32(_ v: Int) -> Data { withUnsafeBytes(of: UInt32(v).littleEndian) { Data($0) } }

        for (path, data) in files {
            offsets.append(out.count)
            let name = Data(path.utf8)
            out.append(le32(0x04034B50))
            out.append(le16(20)); out.append(le16(0)); out.append(le16(0)) // version, flags, method=stored
            out.append(le16(0)); out.append(le16(0))                      // time, date
            out.append(le32(0))                                            // crc (unchecked by reader)
            out.append(le32(data.count)); out.append(le32(data.count))
            out.append(le16(name.count)); out.append(le16(0))
            out.append(name)
            out.append(data)
        }
        for (i, (path, data)) in files.enumerated() {
            let name = Data(path.utf8)
            centralDirectory.append(le32(0x02014B50))
            centralDirectory.append(le16(20)); centralDirectory.append(le16(20))
            centralDirectory.append(le16(0)); centralDirectory.append(le16(0)) // flags, method
            centralDirectory.append(le16(0)); centralDirectory.append(le16(0)) // time, date
            centralDirectory.append(le32(0))
            centralDirectory.append(le32(data.count)); centralDirectory.append(le32(data.count))
            centralDirectory.append(le16(name.count)); centralDirectory.append(le16(0)); centralDirectory.append(le16(0))
            centralDirectory.append(le16(0)); centralDirectory.append(le16(0)) // disk, internal attrs
            centralDirectory.append(le32(0))                                    // external attrs
            centralDirectory.append(le32(offsets[i]))
            centralDirectory.append(name)
        }
        let cdOffset = out.count
        out.append(centralDirectory)
        out.append(le32(0x06054B50))
        out.append(le16(0)); out.append(le16(0))
        out.append(le16(files.count)); out.append(le16(files.count))
        out.append(le32(centralDirectory.count)); out.append(le32(cdOffset))
        out.append(le16(0))
        return out
    }

    private let modelXML = """
    <?xml version="1.0" encoding="UTF-8"?>
    <model unit="millimeter" xmlns="http://schemas.microsoft.com/3dmanufacturing/core/2015/02">
      <resources>
        <object id="1" type="model">
          <mesh>
            <vertices>
              <vertex x="0" y="0" z="0"/><vertex x="100" y="0" z="0"/>
              <vertex x="0" y="40" z="0"/><vertex x="0" y="0" z="25"/>
            </vertices>
            <triangles>
              <triangle v1="0" v2="1" v3="2"/><triangle v1="0" v2="1" v3="3"/>
            </triangles>
          </mesh>
        </object>
        <object id="2" type="model">
          <mesh>
            <vertices><vertex x="0" y="0" z="0"/><vertex x="5" y="5" z="5"/><vertex x="1" y="2" z="3"/></vertices>
            <triangles><triangle v1="0" v2="1" v3="2"/></triangles>
          </mesh>
        </object>
      </resources>
      <build><item objectid="1"/><item objectid="2"/></build>
    </model>
    """

    func test3MFParsing() throws {
        let fakePNG = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 1, 2, 3])
        let zip = storedZip([
            ("[Content_Types].xml", Data("<Types/>".utf8)),
            ("3D/3dmodel.model", Data(modelXML.utf8)),
            ("Metadata/thumbnail.png", fakePNG),
        ])
        let url = try writeTemp("model.3mf", zip)
        let stats = try ThreeMFParser().parse(fileURL: url)
        XCTAssertEqual(stats.partCount, 2, "two objects → multi-part")
        XCTAssertEqual(stats.triangleCount, 3)
        XCTAssertEqual(stats.bboxX!, 100, accuracy: 0.001)
        XCTAssertEqual(stats.embeddedThumbnail, fakePNG)
    }

    func testCorrupt3MFThrows() throws {
        let url = try writeTemp("bad.3mf", Data("this is not a zip archive at all".utf8))
        XCTAssertThrowsError(try ThreeMFParser().parse(fileURL: url))
    }

    // MARK: - GCODE

    func testGcodeThumbnailExtraction() throws {
        let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) + Data((0..<64).map { UInt8($0) })
        let b64 = png.base64EncodedString()
        // Split base64 across comment lines like PrusaSlicer does.
        let mid = b64.index(b64.startIndex, offsetBy: b64.count / 2)
        let gcode = """
        ; generated by PrusaSlicer
        ; thumbnail begin 16x16 \(b64.count)
        ; \(b64[..<mid])
        ; \(b64[mid...])
        ; thumbnail end
        G28 ; home
        G1 X10 Y10
        """
        let url = try writeTemp("print.gcode", Data(gcode.utf8))
        let stats = try GCodeThumbnailParser().parse(fileURL: url)
        XCTAssertEqual(stats.embeddedThumbnail, png)
    }

    func testGcodePicksLargestThumbnail() throws {
        let small = Data([0x01]).base64EncodedString()
        let bigData = Data([0x02, 0x03])
        let big = bigData.base64EncodedString()
        let gcode = """
        ; thumbnail begin 16x16 4
        ; \(small)
        ; thumbnail end
        ; thumbnail begin 220x124 8
        ; \(big)
        ; thumbnail end
        G28
        """
        let url = try writeTemp("multi.gcode", Data(gcode.utf8))
        let stats = try GCodeThumbnailParser().parse(fileURL: url)
        XCTAssertEqual(stats.embeddedThumbnail, bigData)
    }

    func testGcodeWithoutThumbnailYieldsNone() throws {
        let url = try writeTemp("plain.gcode", Data("G28\nG1 X0 Y0\n".utf8))
        let stats = try GCodeThumbnailParser().parse(fileURL: url)
        XCTAssertNil(stats.embeddedThumbnail)
    }

    // MARK: - blend

    func testCompressedBlendFallsBackSilently() throws {
        // gzip magic — modern compressed .blend
        let url = try writeTemp("model.blend", Data([0x1F, 0x8B, 0x08, 0x00, 1, 2, 3, 4, 5, 6, 7, 8, 9]))
        let stats = try BlendThumbnailParser().parse(fileURL: url)
        XCTAssertNil(stats.embeddedThumbnail, "compressed blend → silent icon fallback")
    }

    func testBlendWithTESTBlock() throws {
        // Handcrafted minimal 64-bit little-endian .blend with a 2x2 TEST preview.
        var blend = Data("BLENDER-v305".utf8)
        let width = 2, height = 2
        let rgba = Data((0..<(width * height * 4)).map { UInt8($0 * 10) })
        func le32(_ v: Int) -> Data { withUnsafeBytes(of: UInt32(v).littleEndian) { Data($0) } }
        blend.append(Data("TEST".utf8))
        blend.append(le32(8 + rgba.count))          // block length
        blend.append(Data(count: 8))                 // old pointer (64-bit)
        blend.append(le32(0)); blend.append(le32(1)) // SDNA index, count
        blend.append(le32(width)); blend.append(le32(height))
        blend.append(rgba)
        blend.append(Data("ENDB".utf8)); blend.append(le32(0)); blend.append(Data(count: 8))
        blend.append(le32(0)); blend.append(le32(0))

        let url = try writeTemp("preview.blend", blend)
        let stats = try BlendThumbnailParser().parse(fileURL: url)
        XCTAssertNotNil(stats.embeddedThumbnail, "expected PNG-encoded preview")
        // PNG signature
        XCTAssertEqual(stats.embeddedThumbnail?.prefix(4), Data([0x89, 0x50, 0x4E, 0x47]))
    }
}
