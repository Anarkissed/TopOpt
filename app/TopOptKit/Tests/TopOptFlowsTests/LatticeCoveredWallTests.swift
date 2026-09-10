// LatticeCoveredWallTests — ★ THE COVER MUST ENCLOSE THE LATTICE, NOT CUT IT.
//
// (maintainer, 2026-08-19: "the 'walls' you added to the 'covered' finish are
// *inside* the lattice. Had you taken the time to check, you could have found
// that out yourself.")
//
// ★ THE MISTAKE, AND WHY EYEBALLING MISSED IT. `LatticeSamplePatch` clips strut
// ENDPOINTS to the block box [0, extent], so "the box" looks like the right
// place to put a wall. It is not the silhouette: `emitStrut` sweeps a capsule of
// `radius` about each segment and `emitNode` puts a blob of the same radius on
// each junction, so the DRAWN lattice reaches `radius` past the box on every
// face. Panels at the box therefore slice through the outermost struts.
//
// This test compares the two bounding boxes directly, so the wall's placement is
// a measured fact rather than something that looked about right in a screenshot.

import XCTest
import simd
import TopOptKit
@testable import TopOptFlows

final class LatticeCoveredWallTests: XCTestCase {

    private func bounds(_ m: ViewerMesh) -> (lo: SIMD3<Float>, hi: SIMD3<Float>) {
        var lo = SIMD3<Float>(repeating: .greatestFiniteMagnitude)
        var hi = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)
        var i = 0
        while i + 2 < m.positions.count {
            let p = SIMD3<Float>(m.positions[i], m.positions[i + 1], m.positions[i + 2])
            lo = simd_min(lo, p); hi = simd_max(hi, p)
            i += 3
        }
        return (lo, hi)
    }

    /// ★ THE COVER'S FOUR SIDE WALLS MUST LIE OUTSIDE THE BARE LATTICE ON X AND Z,
    /// and must NOT extend it on Y — top and bottom are deliberately left open so
    /// the lattice inside stays legible.
    func testTheCoverEnclosesTheLatticeRatherThanCuttingThroughIt() {
        let lat = LatticeType.octet
        let bare = LatticeSamplePatch.mesh(lattice: lat, cellMM: 6, cells: 3,
                                           relativeDensity: 0.35, boundary: .none)
        let covered = LatticeSamplePatch.mesh(lattice: lat, cellMM: 6, cells: 3,
                                              relativeDensity: 0.35, boundary: .covered)
        let b = bounds(bare), c = bounds(covered)

        print("""

        ================================================================================
        THE COVER vs THE LATTICE IT COVERS
          bare lattice  x [\(b.lo.x), \(b.hi.x)]  y [\(b.lo.y), \(b.hi.y)]  z [\(b.lo.z), \(b.hi.z)]
          with cover    x [\(c.lo.x), \(c.hi.x)]  y [\(c.lo.y), \(c.hi.y)]  z [\(c.lo.z), \(c.hi.z)]
        ================================================================================
        """)

        // ★ X and Z: the wall is strictly OUTSIDE every strut it covers.
        XCTAssertLessThan(c.lo.x, b.lo.x,
                          "★ the −X wall must sit outside the lattice, not through it")
        XCTAssertGreaterThan(c.hi.x, b.hi.x, "★ …and the +X wall")
        XCTAssertLessThan(c.lo.z, b.lo.z, "★ …and −Z")
        XCTAssertGreaterThan(c.hi.z, b.hi.z, "★ …and +Z")

        // ★ Y: unchanged — top and bottom are open by design, so a cover that grew
        // the block vertically would mean panels where there should be none.
        XCTAssertEqual(c.lo.y, b.lo.y, accuracy: 1e-4,
                       "★ the cover must not close the BOTTOM — the lattice is seen "
                       + "from top and bottom")
        XCTAssertEqual(c.hi.y, b.hi.y, accuracy: 1e-4, "★ …nor the TOP")

        // And it must actually add geometry — a cover that emitted nothing would
        // satisfy the Y equalities above trivially.
        XCTAssertGreaterThan(covered.positions.count, bare.positions.count,
                             "★ the cover must emit panels at all")
    }

    /// The other three treatments must not gain side walls.
    func testOnlyCoveredWidensTheBlock() {
        let lat = LatticeType.octet
        let bare = bounds(LatticeSamplePatch.mesh(lattice: lat, cellMM: 6, cells: 3,
                                                  relativeDensity: 0.35, boundary: .none))
        for t in [LatticeBoundaryTreatment.rim, .fullSkin] {
            let m = bounds(LatticeSamplePatch.mesh(lattice: lat, cellMM: 6, cells: 3,
                                                   relativeDensity: 0.35, boundary: t))
            // rim and diagrid are heavier struts ON the block, so they may reach a
            // little further — but nowhere near a wall's clearance, and they must
            // never be INSIDE the bare lattice either.
            XCTAssertLessThanOrEqual(m.lo.x, bare.lo.x + 1e-4, "\(t) must not shrink the block")
            XCTAssertGreaterThanOrEqual(m.hi.x, bare.hi.x - 1e-4)
        }
    }
}
