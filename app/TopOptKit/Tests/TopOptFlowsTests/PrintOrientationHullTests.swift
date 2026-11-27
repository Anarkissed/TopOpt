// PrintOrientationHullTests — ★ notes27 P6 (builder H): the faces and edges "Manual orientation" offers (SPEC 2d, core's
// CandidateRule numbers): the part's convex hull, coplanar facets merged, small faces dropped, edges between two faces at least
// 10 mm long (held by supports); a face that does not hold the centre of mass "would tip".
import XCTest
import simd
@testable import TopOptFlows

final class PrintOrientationHullTests: XCTestCase {
    func testACubeHasSixFacesAndTwelveEdges() throws {
        let h = try XCTUnwrap(PrintHull.of(vertices: Self.box(40, 30, 20).vertices, indices: Self.box(40, 30, 20).indices))
        XCTAssertEqual(h.faces.count, 6, "★ coplanar hull triangles merged into one face each")
        XCTAssertEqual(h.edges.count, 12)
        XCTAssertEqual(h.faces.first?.areaMM2 ?? 0, 40 * 30, accuracy: 1e-6, "the largest first")
        for f in h.faces {
            XCTAssertTrue(h.stands(on: f), "a box stands on every face")
            XCTAssertEqual(f.outline.count, 4, "its outline: four corners")
        }
        let down = try XCTUnwrap(h.faces.first { simd_dot($0.normal, SIMD3(0, 0, -1)) > 0.999 })
        XCTAssertEqual(down.up, SIMD3(0, 0, 1), "★ the bottom face down: printed with +Z up")
        let e = try XCTUnwrap(h.edges.first { abs($0.lengthMM - 40) < 1e-6 && $0.up.z > 0.5 })
        XCTAssertEqual(simd_length(e.up), 1, accuracy: 1e-9)
        XCTAssertEqual(e.up.z, 0.5.squareRoot(), accuracy: 1e-9, "★ an edge: both faces lean equally (45°)")
    }

    func testTheStandsFacesAndAFaceThatWouldTip() throws {
        let s = PrintOrientationDrawnTests.standMesh()
        let h = try XCTUnwrap(PrintHull.of(vertices: s.vertices, indices: s.indices))
        XCTAssertEqual(h.faces.count, 7, "base, back, top, front, slope and the two ends")
        let base = try XCTUnwrap(h.faces.first { $0.normal.z < -0.999 })
        XCTAssertTrue(h.stands(on: base))
        // the narrow top (10 mm deep, over the back wall): the centre of mass is not over it
        let top = try XCTUnwrap(h.faces.first { $0.normal.z > 0.999 })
        XCTAssertFalse(h.stands(on: top), "★ it would tip")
        XCTAssertTrue(h.edges.allSatisfy { $0.lengthMM >= PrintHull.Rule.edgeMinMM })
        XCTAssertEqual(h.centreOfMass.x, 0, accuracy: 1e-6)
    }

    func testAPointCloudOnAPlaneHasNoHull() {
        XCTAssertNil(PrintHull.of(vertices: [0, 0, 0, 1, 0, 0, 0, 1, 0, 1, 1, 0], indices: [0, 1, 2, 1, 3, 2]))
    }

    /// A closed box [0, x] × [0, y] × [0, z], two triangles a side, outward.
    static func box(_ x: Float, _ y: Float, _ z: Float) -> (vertices: [Float], indices: [Int32]) {
        let c: [SIMD3<Float>] = [SIMD3(0, 0, 0), SIMD3(x, 0, 0), SIMD3(x, y, 0), SIMD3(0, y, 0),
                                 SIMD3(0, 0, z), SIMD3(x, 0, z), SIMD3(x, y, z), SIMD3(0, y, z)]
        let t: [Int32] = [0, 2, 1, 0, 3, 2, 4, 5, 6, 4, 6, 7, 0, 7, 3, 0, 4, 7, 1, 2, 6, 1, 6, 5, 0, 1, 5, 0, 5, 4, 3, 6, 2, 3, 7, 6]
        return (c.flatMap { [$0.x, $0.y, $0.z] }, t)
    }
}
