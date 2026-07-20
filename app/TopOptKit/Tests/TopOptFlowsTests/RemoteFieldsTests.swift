// Handoff 122 — the Swift `fields.bin` parser (RemoteFieldsContainer) must decode
// exactly what the core writer (core/src/io/fields.cpp) produces, and must degrade
// to nil on anything malformed (fields are enrichment, never worth a crash). This
// test writes the v1 byte layout by hand — an INDEPENDENT encoder, so a drift in
// either the parser or the format is caught from both ends — round-trips it, and
// exercises the failure modes (short buffer, wrong version, bad count).

import XCTest
@testable import TopOptFlows

final class RemoteFieldsTests: XCTestCase {

    // A little-endian encoder mirroring core/src/io/fields.cpp (v1).
    private struct Enc {
        var bytes = [UInt8]()
        mutating func u8(_ v: UInt8) { bytes.append(v) }
        mutating func pad(_ n: Int) { bytes.append(contentsOf: [UInt8](repeating: 0, count: n)) }
        mutating func i32(_ v: Int32) { le(UInt64(UInt32(bitPattern: v)), 4) }
        mutating func i64(_ v: Int64) { le(UInt64(bitPattern: v), 8) }
        mutating func f64(_ v: Double) { le(v.bitPattern, 8) }
        mutating func f32(_ v: Float) { le(UInt64(v.bitPattern), 4) }
        mutating func f32s(_ a: [Float]) { for x in a { f32(x) } }
        private mutating func le(_ v: UInt64, _ n: Int) {
            for i in 0..<n { bytes.append(UInt8((v >> (8 * UInt64(i))) & 0xff)) }
        }
    }

    private func encode(nx: Int32, ny: Int32, nz: Int32, origin: (Double, Double, Double),
                        spacing: Double, voxelVol: Double,
                        variants: [(vf: Double, mass: Double, support: Int32,
                                    vm: [Float], st: [Float], disp: [Float])]) -> Data {
        var e = Enc()
        e.u8(RemoteFieldsContainer.formatVersion)
        e.pad(3)
        e.i32(nx); e.i32(ny); e.i32(nz)
        e.f64(origin.0); e.f64(origin.1); e.f64(origin.2)
        e.f64(spacing); e.f64(voxelVol)
        e.i32(Int32(variants.count))
        e.pad(4)
        for v in variants {
            e.f64(v.vf); e.f64(v.mass); e.i32(v.support); e.pad(4)
            e.i64(Int64(v.vm.count)); e.i64(Int64(v.st.count)); e.i64(Int64(v.disp.count))
            e.f32s(v.vm); e.f32s(v.st); e.f32s(v.disp)
        }
        return Data(e.bytes)
    }

    func testRoundTripTwoVariants() throws {
        let data = encode(nx: 3, ny: 2, nz: 2, origin: (1, -2, 0.5), spacing: 2.5,
                          voxelVol: 2.5 * 2.5 * 2.5,
                          variants: [
                            (vf: 0.68, mass: 12.5, support: 7,
                             vm: [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12], st: [],
                             disp: (0..<108).map { Float($0) * 0.25 }),
                            (vf: 0.38, mass: 6.25, support: 0,
                             vm: (0..<12).map { Float(100 + $0) }, st: [],
                             disp: (0..<108).map { -Float($0) })])
        let c = try XCTUnwrap(RemoteFieldsContainer.parse(data))
        XCTAssertEqual(c.gridNx, 3); XCTAssertEqual(c.gridNy, 2); XCTAssertEqual(c.gridNz, 2)
        XCTAssertEqual(c.gridOrigin, SIMD3(1, -2, 0.5))
        XCTAssertEqual(c.spacing, 2.5)
        XCTAssertEqual(c.voxelVolumeMM3, 2.5 * 2.5 * 2.5)
        XCTAssertEqual(c.variants.count, 2)

        let a = c.variants[0]
        XCTAssertEqual(a.requestedVF, 0.68)
        XCTAssertEqual(a.massGrams, 12.5)
        XCTAssertEqual(a.supportVolumeVoxels, 7)
        XCTAssertEqual(a.vonMises, [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12])
        XCTAssertEqual(a.stressTensor, [])          // v1 omits the tensor
        XCTAssertEqual(a.displacement.count, 108)
        XCTAssertEqual(a.displacement[4], 1.0)      // 4 * 0.25

        // Lookup by ladder rung is the join RemoteRunner uses.
        XCTAssertEqual(c.variant(forRequestedVF: 0.38)?.massGrams, 6.25)
        XCTAssertNil(c.variant(forRequestedVF: 0.5), "no block within tolerance → nil, not nearest")
    }

    func testEmptyContainerParses() throws {
        let data = encode(nx: 4, ny: 4, nz: 4, origin: (0, 0, 0), spacing: 1,
                          voxelVol: 1, variants: [])
        let c = try XCTUnwrap(RemoteFieldsContainer.parse(data))
        XCTAssertEqual(c.gridNx, 4)
        XCTAssertTrue(c.variants.isEmpty)
    }

    func testRejectsUnknownVersion() {
        var data = encode(nx: 2, ny: 2, nz: 2, origin: (0, 0, 0), spacing: 1,
                          voxelVol: 1, variants: [])
        data[0] = 99                                 // clobber the version byte
        XCTAssertNil(RemoteFieldsContainer.parse(data), "unknown version must not parse")
    }

    func testRejectsTruncatedBuffer() {
        let full = encode(nx: 2, ny: 2, nz: 2, origin: (0, 0, 0), spacing: 1, voxelVol: 1,
                          variants: [(vf: 0.5, mass: 1, support: 1,
                                      vm: [1, 2, 3, 4, 5, 6, 7, 8], st: [],
                                      disp: (0..<81).map { Float($0) })])
        // Cut the array payload short — the header/counts promise more than remains.
        let truncated = full.prefix(full.count - 40)
        XCTAssertNil(RemoteFieldsContainer.parse(Data(truncated)), "a short buffer must not parse")
        XCTAssertNil(RemoteFieldsContainer.parse(Data()), "empty data must not parse")
    }
}
