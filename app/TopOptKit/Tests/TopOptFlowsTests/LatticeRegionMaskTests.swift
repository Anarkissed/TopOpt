// LatticeRegionMaskTests.swift — ★ THE PREVIEW SHOWS THE LATTICE WHERE IT WILL BE
// (maintainer, 2026-08-17: "Can you confirm that the preview will only show what
// is *actually* set to lattice (i.e. the primitives)").
//
// ★ THE ANSWER WAS NO. `LatticeSDFScene` baked occupancy from the WHOLE PART
// mesh and no region reached the preview path at all, so the raymarched struts
// filled the entire interior regardless of which selectables carried a lattice
// role. On a page whose whole purpose is that the picture predicts the run, that
// is a defect and not a cosmetic one.

import XCTest
import simd
@testable import TopOptFlows

final class LatticeRegionMaskTests: XCTestCase {

    // MARK: the predicate — core's own geometry, evaluated pointwise

    private func faceSlab(origin: SIMD3<Double> = .zero,
                          normal: SIMD3<Double> = SIMD3(0, 0, 1),
                          halfU: Double = 5, halfW: Double = 5,
                          depth: Double = 10,
                          role: LatticeGroupRole = .include) -> LatticeRegionSpec {
        var s = LatticeRegionSpec(role: role, kind: .face)
        s.origin = origin; s.normal = normal
        s.halfUMM = halfU; s.halfWMM = halfW; s.depthMM = depth
        return s
    }

    func testAFaceSlabContainsOnlyWhatIsInsideItsDepthAndItsExtents() {
        let s = faceSlab()
        XCTAssertTrue(LatticeRegionMask.contains(SIMD3(0, 0, 5), region: s),
                      "mid-slab, on the axis")
        XCTAssertTrue(LatticeRegionMask.contains(SIMD3(4, 4, 1), region: s),
                      "inside both in-plane extents")
        XCTAssertFalse(LatticeRegionMask.contains(SIMD3(0, 0, -1), region: s),
                       "★ BEHIND the face — the slab runs inward only")
        XCTAssertFalse(LatticeRegionMask.contains(SIMD3(0, 0, 11), region: s),
                       "★ past the depth")
        XCTAssertFalse(LatticeRegionMask.contains(SIMD3(6, 0, 5), region: s),
                       "★ outside the in-plane extent — this is the chamfer case")
    }

    func testABoltRegionIsACylinderAboutItsAxis() {
        var s = LatticeRegionSpec(role: .include, kind: .bolt)
        s.axisPoint = .zero; s.axisDir = SIMD3(0, 0, 1)
        s.radiusMM = 3; s.halfLengthMM = 4
        XCTAssertTrue(LatticeRegionMask.contains(SIMD3(0, 0, 0), region: s))
        XCTAssertTrue(LatticeRegionMask.contains(SIMD3(2.9, 0, 3.9), region: s))
        XCTAssertFalse(LatticeRegionMask.contains(SIMD3(3.1, 0, 0), region: s),
                       "outside the radius")
        XCTAssertFalse(LatticeRegionMask.contains(SIMD3(0, 0, 4.1), region: s),
                       "past the axial half-length")
    }

    /// ★ AN EXCLUDE REGION IS FROZEN SOLID — it carries no lattice, so showing
    /// struts there would be the same lie in the other direction.
    func testAnExcludeRegionNeverShowsALattice() {
        let ex = faceSlab(role: .exclude)
        XCTAssertTrue(LatticeRegionMask.contains(SIMD3(0, 0, 5), region: ex),
                      "the GEOMETRY still contains the point…")
        XCTAssertFalse(LatticeRegionMask.contains(SIMD3(0, 0, 5), regions: [ex]),
                       "★ …but it is not a place the lattice goes")
    }

    // MARK: clipping the grid

    private func fullGrid(n: Int = 12, spacing: Float = 1) -> LatticeVoxelGrid {
        LatticeVoxelGrid(nx: n, ny: n, nz: n, origin: .zero,
                         spacing: SIMD3(spacing, spacing, spacing),
                         values: [Float](repeating: 1, count: n * n * n))
    }

    /// ★ THE FIX ITSELF: solid voxels outside every declared region are dropped.
    func testClippingKeepsOnlyWhatIsInsideADeclaredRegion() {
        let g = fullGrid()
        // A slab over x,y ∈ [−2, 2] about (5,5,·), running z 0…4.
        let s = faceSlab(origin: SIMD3(5, 5, 0), normal: SIMD3(0, 0, 1),
                         halfU: 2, halfW: 2, depth: 4)
        let c = LatticeRegionMask.clipped(g, to: [s])
        XCTAssertLessThan(c.values.filter { $0 != 0 }.count,
                          g.values.filter { $0 != 0 }.count,
                          "★ the preview is smaller than the whole part")
        XCTAssertGreaterThan(c.values.filter { $0 != 0 }.count, 0,
                             "…and is not empty — a blank preview is not the fix")
        // Spot-check both sides of the boundary through the grid's own indexing.
        func at(_ x: Int, _ y: Int, _ z: Int) -> Float {
            c.values[x + y * c.nx + z * c.nx * c.ny]
        }
        XCTAssertNotEqual(at(5, 5, 2), 0, "inside the slab: kept")
        XCTAssertEqual(at(9, 9, 2), 0, "outside the extents: dropped")
        XCTAssertEqual(at(5, 5, 8), 0, "past the depth: dropped")
    }

    /// ★ EMPTY MEANS NO CLIPPING, DELIBERATELY. The lattice SETTINGS page previews
    /// a sample block with no regions declared ("A sample part. Your settings, not
    /// your result."); clipping that to nothing would blank a preview whose job is
    /// to show the cell.
    func testNoDeclaredRegionsLeavesTheGridExactlyAsItWas() {
        let g = fullGrid()
        XCTAssertEqual(LatticeRegionMask.clipped(g, to: []).values, g.values)
        // …and an exclude-only list is the same case: nothing is latticed.
        XCTAssertEqual(LatticeRegionMask.clipped(g, to: [faceSlab(role: .exclude)]).values,
                       g.values)
    }

    /// Two regions union rather than intersect — a group with a face and a
    /// primitive shows both.
    func testTwoRegionsUnion() {
        let g = fullGrid()
        let a = faceSlab(origin: SIMD3(2, 2, 0), halfU: 1, halfW: 1, depth: 3)
        let b = faceSlab(origin: SIMD3(9, 9, 0), halfU: 1, halfW: 1, depth: 3)
        let both = LatticeRegionMask.clipped(g, to: [a, b]).values.filter { $0 != 0 }.count
        let justA = LatticeRegionMask.clipped(g, to: [a]).values.filter { $0 != 0 }.count
        XCTAssertGreaterThan(both, justA, "★ the second region ADDS lattice")
    }

    /// A zero-depth or degenerate region contains nothing — it must not silently
    /// swallow the whole part by failing open.
    func testADegenerateRegionContainsNothing() {
        XCTAssertFalse(LatticeRegionMask.contains(
            SIMD3(0, 0, 0), region: faceSlab(depth: 0)))
        XCTAssertFalse(LatticeRegionMask.contains(
            SIMD3(0, 0, 0), region: faceSlab(normal: .zero)))
    }

    /// ★ AND THE EXPAND REACHES THE PICTURE TOO. The in-plane expand grows
    /// `halfU`/`halfW` on the emitted region, and the preview reads that same
    /// spec — so a chamfer taken in by the expand shows struts.
    func testTheInPlaneExpandWidensWhatThePreviewShows() {
        let g = fullGrid()
        let narrow = faceSlab(origin: SIMD3(5, 5, 0), halfU: 1, halfW: 1, depth: 4)
        var wide = narrow
        let e = LatticeSlabExpand.expanded(halfUMM: 1, halfWMM: 1, by: 3)
        wide.halfUMM = e.halfUMM; wide.halfWMM = e.halfWMM
        XCTAssertGreaterThan(
            LatticeRegionMask.clipped(g, to: [wide]).values.filter { $0 != 0 }.count,
            LatticeRegionMask.clipped(g, to: [narrow]).values.filter { $0 != 0 }.count,
            "★ expanding the slab expands the preview with it")
    }
}
