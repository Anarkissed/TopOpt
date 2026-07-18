// Headless tests for MeshExport (EXPORT task): the binary-STL writer round-trips
// through the same reader the RemoteRunner mesh path uses, and the divergence-
// theorem volume is exact on a unit cube and scales correctly on a two-cube box.
// Pure value math — no bridge, no rendering (a manual open-in-a-slicer check is
// device/desktop QA, described in the handoff, not fabricated here).
import XCTest
import simd
@testable import TopOptFlows

final class MeshExportTests: XCTestCase {

    // A watertight axis-aligned box [0,sx]×[0,sy]×[0,sz]: 8 shared vertices, 12
    // triangles, consistent outward winding. `sx=sy=sz=1` is the unit cube.
    private func box(_ sx: Float, _ sy: Float, _ sz: Float) -> (verts: [Float], idx: [Int32]) {
        let verts: [Float] = [
            0, 0, 0,   sx, 0, 0,   sx, sy, 0,   0, sy, 0,   // z = 0
            0, 0, sz,  sx, 0, sz,  sx, sy, sz,  0, sy, sz,  // z = sz
        ]
        let idx: [Int32] = [
            0, 2, 1,  0, 3, 2,   // −Z
            4, 5, 6,  4, 6, 7,   // +Z
            0, 1, 5,  0, 5, 4,   // −Y
            2, 3, 7,  2, 7, 6,   // +Y
            0, 4, 7,  0, 7, 3,   // −X
            1, 2, 6,  1, 6, 5,   // +X
        ]
        return (verts, idx)
    }

    // MARK: - Round-trip: write → reparse → identical

    func testBinarySTLRoundTrip() {
        let (verts, idx) = box(1, 1, 1)
        let data = MeshExport.binarySTL(vertices: verts, indices: idx,
                                        header: MeshExport.header(detail: "Cube · PLA"))
        let (rv, ri) = MeshExport.parseBinarySTL(data)

        // Same triangle count (12 for a cube).
        XCTAssertEqual(idx.count / 3, 12)
        XCTAssertEqual(ri.count / 3, 12, "reparsed triangle count must match")
        XCTAssertEqual(rv.count / 3, 36, "STL is triangle-soup: 3 verts × 12 tris")

        // Every reparsed triangle's three vertex positions match the original indexed
        // triangle's, in order, within float tolerance.
        let tol: Float = 1e-5
        for t in 0..<12 {
            for corner in 0..<3 {
                let origIdx = Int(idx[t * 3 + corner])
                let ov = SIMD3<Float>(verts[origIdx * 3], verts[origIdx * 3 + 1], verts[origIdx * 3 + 2])
                let base = (t * 3 + corner) * 3
                let pv = SIMD3<Float>(rv[base], rv[base + 1], rv[base + 2])
                XCTAssertLessThan(simd_length(ov - pv), tol,
                                  "tri \(t) corner \(corner) drifted on round-trip")
            }
        }
    }

    func testHeaderIsExactly80BytesAndNamesApp() {
        let head = MeshExport.header(detail: "MyPart · PLA · −30% · mm")
        XCTAssertEqual(head.count, 80, "binary STL header is a fixed 80-byte field")
        let text = String(decoding: head.prefix { $0 != 0 }, as: UTF8.self)
        XCTAssertTrue(text.hasPrefix("TopOpt"), "header names the app")
        XCTAssertTrue(text.contains("MyPart"), "header names the variant")
        XCTAssertFalse(text.hasPrefix("solid"), "must not be sniffed as ASCII STL")
    }

    func testTriangleCountFieldIsCorrect() {
        let (verts, idx) = box(1, 1, 1)
        let data = MeshExport.binarySTL(vertices: verts, indices: idx,
                                        header: MeshExport.header(detail: "x"))
        // Bytes 80..84 hold the little-endian UInt32 triangle count.
        let count = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 80, as: UInt32.self) }
        XCTAssertEqual(count, 12)
        // Total length = 80 header + 4 count + 50 per triangle.
        XCTAssertEqual(data.count, 80 + 4 + 12 * 50)
    }

    // MARK: - Volume (divergence theorem)

    func testUnitCubeVolumeIsOne() {
        let (verts, idx) = box(1, 1, 1)
        XCTAssertEqual(MeshExport.meshVolume(vertices: verts, indices: idx), 1.0, accuracy: 1e-5)
    }

    func testTwoCubeBoxScalesCorrectly() {
        // A 2×1×1 box is two unit cubes' worth of volume.
        let (verts, idx) = box(2, 1, 1)
        XCTAssertEqual(MeshExport.meshVolume(vertices: verts, indices: idx), 2.0, accuracy: 1e-5)
        // Two DISJOINT unit cubes sum too (divergence theorem is additive over the
        // closed surface): translate a second cube and concatenate.
        let (v2, i2) = box(1, 1, 1)
        var verts2 = v2
        for k in stride(from: 0, to: verts2.count, by: 3) { verts2[k] += 10 } // shift +x by 10
        let merged = verts + verts2
        let offset = Int32(verts.count / 3)
        let mergedIdx = idx + i2.map { $0 + offset }
        XCTAssertEqual(MeshExport.meshVolume(vertices: merged, indices: mergedIdx), 2.0, accuracy: 1e-5)
    }

    func testVolumeIsOrientationIndependent() {
        // Reversed winding flips the signed sum; the reported volume is |·| so it stays
        // positive and equal.
        let (verts, idx) = box(1, 1, 1)
        var flipped = idx
        for t in 0..<(idx.count / 3) { flipped.swapAt(t * 3, t * 3 + 2) }
        XCTAssertEqual(MeshExport.meshVolume(vertices: verts, indices: flipped), 1.0, accuracy: 1e-5)
    }

    // MARK: - Mass

    func testMeshMassFromDensity() {
        // A 2 cm cube = 20 mm cube → 8000 mm³ = 8 cm³. At PLA 1.24 g/cm³ → 9.92 g.
        let (verts, idx) = box(20, 20, 20)
        let g = MeshExport.meshMassGrams(vertices: verts, indices: idx, densityGCm3: 1.24)
        XCTAssertEqual(g, 8.0 * 1.24, accuracy: 1e-4)
        // No density → no fabricated mass.
        XCTAssertEqual(MeshExport.meshMassGrams(vertices: verts, indices: idx, densityGCm3: 0), 0)
    }

    // MARK: - Facet normals

    func testFacetNormalsAreUnitAndAxisAligned() {
        let (verts, idx) = box(1, 1, 1)
        for t in 0..<(idx.count / 3) {
            func v(_ c: Int) -> SIMD3<Float> {
                let i = Int(idx[t * 3 + c]); return SIMD3(verts[i * 3], verts[i * 3 + 1], verts[i * 3 + 2])
            }
            let n = MeshExport.facetNormal(v(0), v(1), v(2))
            XCTAssertEqual(simd_length(n), 1.0, accuracy: 1e-5, "cube facet normal is unit length")
            // Each cube face is axis-aligned: exactly one component is ±1.
            let comps = [abs(n.x), abs(n.y), abs(n.z)].filter { $0 > 0.5 }
            XCTAssertEqual(comps.count, 1)
        }
    }

    func testDegenerateTriangleNormalIsZero() {
        let a = SIMD3<Float>(0, 0, 0), b = SIMD3<Float>(1, 0, 0)
        XCTAssertEqual(MeshExport.facetNormal(a, b, b), .zero)   // collinear → no area
    }

    // MARK: - Watertightness

    func testWatertightCubeIsWatertight() {
        let (verts, idx) = box(1, 1, 1)
        XCTAssertTrue(MeshExport.isWatertight(vertices: verts, indices: idx))
    }

    func testOpenMeshIsNotWatertight() {
        // Drop the last two triangles (the +X face) → boundary edges → open.
        let (verts, idx) = box(1, 1, 1)
        let open = Array(idx.prefix(idx.count - 6))
        XCTAssertFalse(MeshExport.isWatertight(vertices: verts, indices: open))
    }

    // MARK: - Defensive guards

    func testEmptyMeshExportsHeaderAndZeroCount() {
        let data = MeshExport.binarySTL(vertices: [], indices: [],
                                        header: MeshExport.header(detail: "empty"))
        let count = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 80, as: UInt32.self) }
        XCTAssertEqual(count, 0)
        XCTAssertEqual(MeshExport.meshVolume(vertices: [], indices: []), 0)
        XCTAssertFalse(MeshExport.isWatertight(vertices: [], indices: []))
    }

    func testOutOfRangeIndexTriangleIsDropped() {
        // One valid triangle + one referencing a nonexistent vertex → count field = 1.
        let verts: [Float] = [0, 0, 0, 1, 0, 0, 0, 1, 0]
        let idx: [Int32] = [0, 1, 2,  0, 1, 99]
        let data = MeshExport.binarySTL(vertices: verts, indices: idx,
                                        header: MeshExport.header(detail: "guard"))
        let count = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 80, as: UInt32.self) }
        XCTAssertEqual(count, 1, "the bad triangle is dropped and the count stays honest")
        XCTAssertEqual(data.count, 80 + 4 + 1 * 50)
    }
}
