// Headless tests for the true-geometry sample patch (handoff 2026-07-28-lattice-
// viewer-proxy). The patch is the "this is what the cells look like" reference — a
// few cells, a few thousand triangles — so these pin its counts, determinism, and
// that its strut thickness follows the grading density.

import XCTest
import simd
@testable import TopOptFlows

final class LatticeSamplePatchTests: XCTestCase {

    /// The advertised triangle count equals the mesh actually built (so the cost
    /// table's proxy number is the real one).
    func testTriangleCountMatchesBuiltMesh() {
        for id in ["octet", "bcc", "sc", "diamond"] {
            let lat = LatticeType.named(id)
            let declared = LatticeSamplePatch.triangleCount(lattice: lat, cells: 2)
            let mesh = LatticeSamplePatch.mesh(lattice: lat, cellMM: 8, cells: 2, relativeDensity: 0.4)
            XCTAssertEqual(mesh.triangleCount, declared, "\(id) declared vs built tris")
        }
    }

    /// Each strut is a 32-triangle capped 8-gon prism, each node a 20-triangle
    /// icosahedron (the worker's primitives).
    func testPrimitiveTriangleCounts() {
        let (struts, nodes) = LatticeSamplePatch.counts(lattice: .octet, cells: 1)
        let tris = LatticeSamplePatch.triangleCount(lattice: .octet, cells: 1)
        XCTAssertEqual(tris, struts * 32 + nodes * 20)
        XCTAssertGreaterThan(struts, 0)
        XCTAssertGreaterThan(nodes, 0)
    }

    /// A sample patch stays small — a few thousand triangles, orders below the full
    /// lattice — for the cell counts the inset uses.
    func testPatchStaysSmall() {
        let tris = LatticeSamplePatch.triangleCount(lattice: .octet, cells: 2)
        XCTAssertLessThan(tris, 20_000, "2³ octet patch must be a few thousand tris")
    }

    /// Deterministic: same inputs → byte-identical geometry (the worker's S2).
    func testDeterministic() {
        let a = LatticeSamplePatch.mesh(lattice: .octet, cellMM: 8, cells: 2, relativeDensity: 0.4)
        let b = LatticeSamplePatch.mesh(lattice: .octet, cellMM: 8, cells: 2, relativeDensity: 0.4)
        XCTAssertEqual(a.positions, b.positions)
        XCTAssertEqual(a.indices, b.indices)
    }

    /// Strut thickness follows density: a denser patch has a larger bounding radius
    /// about a strut, so the mesh's bounds grow with ρ (thicker struts push the outer
    /// surface out).
    func testThicknessGrowsWithDensity() {
        let thin = LatticeSamplePatch.mesh(lattice: .octet, cellMM: 8, cells: 1, relativeDensity: 0.1)
        let thick = LatticeSamplePatch.mesh(lattice: .octet, cellMM: 8, cells: 1, relativeDensity: 0.5)
        let thinR = thin.bounds.radius
        let thickR = thick.bounds.radius
        XCTAssertGreaterThan(thickR, thinR)
    }

    /// The patch is centred on the origin (so the inset frames it symmetrically).
    func testCentredOnOrigin() {
        let m = LatticeSamplePatch.mesh(lattice: .octet, cellMM: 8, cells: 2, relativeDensity: 0.4)
        XCTAssertEqual(m.bounds.center.x, 0, accuracy: 0.2)
        XCTAssertEqual(m.bounds.center.y, 0, accuracy: 0.2)
        XCTAssertEqual(m.bounds.center.z, 0, accuracy: 0.2)
    }
}
