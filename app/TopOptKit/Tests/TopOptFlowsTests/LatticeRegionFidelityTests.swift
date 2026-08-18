// LatticeRegionFidelityTests — ★ THE LATTICE MUST BE EXACTLY THE DECLARED REGION,
// AND NOTHING ELSE (maintainer, 2026-08-18, with three photographs).
//
// He set a NEGATIVE expand so the wall's edges would stay solid and the lattice sit
// only in the centre, and reported two things:
//
//   (1) "the lattice doesn't change and allow for that extra space. There needs to
//       be this type of fidelity and control."
//   (2) "there are a number of artifacts — these are a result of the lattices being
//       made *behind* the 3d model. So you have not hidden the other parts of the
//       latticed area. You need to make *only* the face's area turned into a
//       lattice."
//
// ★ THEY ARE TWO DEFECTS AND THEY COMPOUND, which is why the picture looked so
// wrong:
//
//   (1) `LatticeRegionEmission.spec` clamped the expand with `expandMM > 0 ?
//       expandMM : 0` — a hand-rolled duplicate of `LatticeSlabExpand.expanded`
//       that dropped the sign. Every shrink the user typed became a zero before it
//       reached the slab, so the region never moved. (`LatticeSlabExpand` itself
//       has handled the negative correctly since the sign was freed; it was simply
//       not called.)
//
//   (2) The struts were bounded only by the baked per-CELL activation grid, while
//       the shell's hole was cut by the EXACT region. A cell activates when as
//       little as 2% of it overlaps the region (`cellField`'s `insideFraction`), so
//       the lattice was rounded UP to whole cells and overhung the hole by up to
//       half a cell in every direction. Measured on his own part below: ~20% of the
//       strut-bearing volume sat OUTSIDE the region, i.e. inside still-solid shell.
//       Those are the artifacts. It also meant a sub-cell change to the region
//       moved NOTHING — which is defect (1)'s symptom even once (1) is fixed.

import XCTest
import Foundation
import Metal
import MetalKit
import simd
import TopOptKit
@testable import TopOptFlows
@testable import TopOptDesign

final class LatticeRegionFidelityTests: XCTestCase {

    static func slab(halfU: Double, halfW: Double, depth: Double,
                     origin: SIMD3<Double>, normal: SIMD3<Double>) -> LatticeRegionSpec {
        var s = LatticeRegionSpec(role: .include, kind: .face)
        s.origin = origin; s.normal = normal
        s.halfUMM = halfU; s.halfWMM = halfW; s.depthMM = depth
        return s
    }

    /// One slab off his part's +X wall, reaching 11.0 mm in — the shape of his Face 15.
    static func hisSlab(_ mesh: ViewerMesh, halfU: Double = 40, halfW: Double = 40)
        -> LatticeRegionSpec {
        let b = mesh.bounds
        let mid = (b.min + b.max) * 0.5
        return slab(halfU: halfU, halfW: halfW, depth: 11.0,
                    origin: SIMD3<Double>(Double(b.max.x), Double(mid.y), Double(mid.z)),
                    normal: SIMD3<Double>(-1, 0, 0))
    }

    // MARK: - (1) THE SIGN REACHES THE SLAB

    /// ★ THE MIRROR OF `testTheExpandGrowsTheEmittedRegionInPlaneAndNotInDepth`,
    /// which only ever tried +3. The negative half of a control whose sign was
    /// deliberately freed was never asserted at the EMISSION, and that is exactly
    /// where it was being thrown away.
    func testANegativeExpandShrinksTheEmittedSlabInPlaneAndNotInDepth() throws {
        let plane = LatticeRegionEmission.ResolvedFace.plane(
            center: SIMD3<Double>(0, 0, 0), normal: SIMD3<Double>(0, 0, 1),
            halfUMM: 10, halfWMM: 4)

        let zero = try XCTUnwrap(LatticeRegionEmission.spec(
            for: plane, role: .include, depthMM: 6, faceID: 1, expandMM: 0))
        XCTAssertEqual(zero.halfUMM, 10, accuracy: 1e-12, "zero is exactly the face")
        XCTAssertEqual(zero.halfWMM, 4, accuracy: 1e-12)

        let shrunk = try XCTUnwrap(LatticeRegionEmission.spec(
            for: plane, role: .include, depthMM: 6, faceID: 1, expandMM: -3))
        XCTAssertEqual(shrunk.halfUMM, 7, accuracy: 1e-9,
                       "★ THE DEFECT: a negative expand must PULL THE SLAB IN. It was "
                       + "clamped to zero by a hand-rolled copy of "
                       + "`LatticeSlabExpand.expanded`, so every shrink the user typed "
                       + "was discarded before it reached the region.")
        XCTAssertEqual(shrunk.halfWMM, 1, accuracy: 1e-9, "★ …on both in-plane axes")
        XCTAssertEqual(shrunk.depthMM, zero.depthMM, accuracy: 1e-12,
                       "★★ and the DEPTH still does not move — his one explicit exclusion")

        // And it floors per axis rather than inverting, which is the shared
        // expander's rule and now the emission's too.
        let past = try XCTUnwrap(LatticeRegionEmission.spec(
            for: plane, role: .include, depthMM: 6, faceID: 1, expandMM: -50))
        XCTAssertGreaterThan(past.halfUMM, 0, "a shrink past the face collapses, never inverts")
        XCTAssertGreaterThan(past.halfWMM, 0)
        XCTAssertEqual(past.halfUMM, LatticeSlabExpand.minHalfExtentMM, accuracy: 1e-12)
    }

    /// The same value, through the PROJECT, is what core is asked to lattice.
    func testTheShrunkSlabIsWhatReachesTheJob() throws {
        let plane = LatticeRegionEmission.ResolvedFace.plane(
            center: .zero, normal: SIMD3<Double>(0, 0, 1), halfUMM: 10, halfWMM: 10)
        let grown = try XCTUnwrap(LatticeRegionEmission.spec(
            for: plane, role: .include, depthMM: 5, expandMM: 4))
        let shrunk = try XCTUnwrap(LatticeRegionEmission.spec(
            for: plane, role: .include, depthMM: 5, expandMM: -4))
        XCTAssertEqual(grown.halfUMM - 10, 4, accuracy: 1e-9)
        XCTAssertEqual(10 - shrunk.halfUMM, 4, accuracy: 1e-9,
                       "★ the two directions are symmetric — one control, one sign")
        // The wire the job is built from carries the shrunk number, not the face's.
        let w = shrunk.wireDictionary["geometry"] as? [String: Any]
        XCTAssertEqual(w?["half_u_mm"] as? Double, shrunk.halfUMM,
                       "★ a preview that shrank while the JOB did not would be a lie")
    }

    // MARK: - (2) THE QUANTISER, MEASURED — why the cell grid could never do this

    /// ★ THE POSITIVE CONTROL FOR THE GPU TEST BELOW, and the measurement that
    /// says the fix had to go in the MARCH. The baked per-cell grid is blind to a
    /// sub-cell change: shrinking the region by 1 mm or 3 mm against an 8 mm cell
    /// leaves the active-cell set BYTE-IDENTICAL. So any test that measured cells
    /// would report "no change" for a working fix and for a broken one alike.
    func testTheCellGridAloneCannotSeeASubCellShrink() throws {
        let mesh = try LatticePreviewConfettiTests.hisMesh()
        let params = LatticePreviewConfettiTests.hisParams()
        func activeCells(_ halfExtent: Double) -> Int {
            let scene = LatticeSDFScene(mesh: mesh, field: nil, latticeID: "octet",
                                        regions: [Self.hisSlab(mesh, halfU: halfExtent,
                                                               halfW: halfExtent)],
                                        whenEmpty: .latticeNothing)
            return LatticePreviewOccupancy.cellField(
                occupancy: scene.occupancy, demand: scene.demand,
                cellMM: params.cellMM).values.filter { $0 >= 0 }.count
        }
        let full = activeCells(40), one = activeCells(39), three = activeCells(37)
        print("""

        ================================================================================
        THE QUANTISER — active CELLS at cell size \(params.cellMM) mm
          expand   0 mm  ->  \(full)
          expand  -1 mm  ->  \(one)
          expand  -3 mm  ->  \(three)
        ★ identical: the cell grid cannot express a sub-cell region change, which is
          why the region had to become a cutting solid in the MARCH.
        ================================================================================
        """)
        XCTAssertEqual(one, full,
                       "the cell grid is blind to a 1 mm change against an 8 mm cell")
        XCTAssertEqual(three, full,
                       "…and to a 3 mm one. This is the CONTROL: it is why the "
                       + "rendered-pixel test below is the only honest measure.")
    }

    /// ★ HOW MUCH OF THE LATTICE WAS OUTSIDE THE DECLARED REGION, before the march
    /// clipped. Every one of these voxels is a strut drawn where the shell is still
    /// solid — the artifacts he photographed.
    func testTheOverhangThatProducedTheArtifactsIsMeasured() throws {
        let mesh = try LatticePreviewConfettiTests.hisMesh()
        let params = LatticePreviewConfettiTests.hisParams()
        let r = Self.hisSlab(mesh)
        let scene = LatticeSDFScene(mesh: mesh, field: nil, latticeID: "octet",
                                    regions: [r], whenEmpty: .latticeNothing)
        let cells = LatticePreviewOccupancy.cellField(
            occupancy: scene.occupancy, demand: scene.demand, cellMM: params.cellMM)
        let cell = Float(params.cellMM)
        // The march's own ownership rule: `baseCell = round((p - origin) / cell)`.
        func owningCellActive(_ p: SIMD3<Float>) -> Bool {
            let c = ((p - cells.origin) / cell).rounded(.toNearestOrAwayFromZero)
            let i = Int(c.x), j = Int(c.y), k = Int(c.z)
            guard i >= 0, i < cells.nx, j >= 0, j < cells.ny, k >= 0, k < cells.nz
            else { return false }
            return cells.values[(k * cells.ny + j) * cells.nx + i] >= 0
        }
        let solid = LatticePreviewOccupancy.occupancy(
            positions: mesh.positions, indices: mesh.indices,
            bounds: mesh.bounds, maxDim: 128)
        var bearing = 0, outside = 0
        var i = 0
        for k in 0..<solid.nz { for j in 0..<solid.ny { for x in 0..<solid.nx {
            defer { i += 1 }
            guard solid.values[i] > 0.5 else { continue }
            let p = solid.origin + SIMD3<Float>(Float(x), Float(j), Float(k)) * solid.spacing
            guard owningCellActive(p) else { continue }
            bearing += 1
            if !LatticeRegionMask.contains(SIMD3<Double>(Double(p.x), Double(p.y),
                                                         Double(p.z)), regions: [r]) {
                outside += 1
            }
        } } }
        let pct = bearing > 0 ? 100.0 * Double(outside) / Double(bearing) : 0
        print("""

        ================================================================================
        THE OVERHANG — where the struts were, before the march was clipped
        part-interior voxels whose OWNING CELL is active ... \(bearing)
          …of those, OUTSIDE the exact region ............... \(outside)  (\(pct)%)
        ★ each one is a strut drawn inside still-solid shell.
        ================================================================================
        """)
        XCTAssertGreaterThan(outside, 0,
                             "the cell grid DOES overhang the exact region — if this "
                             + "were zero the artifacts would have another cause and "
                             + "the march clip below would be treating a symptom")
    }

    // MARK: - (2) THE PIXELS: the march is clipped to the exact region

    @MainActor
    private func renderedLatticePixels(_ mesh: ViewerMesh,
                                       scene: LatticeSDFScene,
                                       clipTo regions: [LatticeRegionSpec],
                                       device: MTLDevice) throws -> Int {
        guard let renderer = MeshRenderer(device: device, sampleCount: 1) else {
            throw XCTSkip("MeshRenderer init: \(MeshRenderer.lastInitError ?? "?")")
        }
        try XCTSkipUnless(renderer.latticePipelinesDidBuild, "lattice MSL must compile")
        renderer.setMesh(mesh)
        // ★ A VIEWPOINT THAT PRESENTS THE SLAB. Down an axis the region is edge-on
        // and the whole lattice is a few hundred pixels, so the armed/disarmed
        // difference collapses to single digits and the comparison cannot resolve
        // anything. This is the confetti test's own orientation.
        renderer.camera.setOrientation(azimuth: 0.7, elevation: 0.4)
        renderer.setBodyAlpha(0)
        renderer.setLatticeScene(scene, token: 1)
        renderer.latticeParams = LatticePreviewConfettiTests.hisParams()
        // `setLatticeScene` takes the scene's own list; override it so the two arms
        // differ in the CLIP alone and share one bake.
        renderer.shellClipRegions = regions
        let dump = try XCTUnwrap(renderer.latticeMaskDump(size: 512),
                                 "the lattice must reach the G-buffer at all")
        return dump.covered
    }

    /// ★★ THE ONE THAT ANSWERS HIS WORDS. Two frames from ONE bake, differing only
    /// in the declared region: the full slab, and the same slab pulled in 3 mm —
    /// well under the 8 mm cell. The rendered lattice MUST shrink.
    ///
    /// Before the march was clipped this was impossible: the struts were bounded by
    /// the cell grid, which `testTheCellGridAloneCannotSeeASubCellShrink` shows is
    /// byte-identical across this change. Both arms drew the same pixels.
    @MainActor
    func testASubCellShrinkMovesTheRenderedLattice() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal device") }
        let mesh = try LatticePreviewConfettiTests.hisMesh()
        // ONE bake, so nothing but the clip can differ.
        let scene = LatticeSDFScene(mesh: mesh, field: nil, latticeID: "octet",
                                    regions: [Self.hisSlab(mesh)],
                                    whenEmpty: .latticeNothing)
        let full = try renderedLatticePixels(mesh, scene: scene,
                                             clipTo: [Self.hisSlab(mesh)], device: device)
        let shrunk = try renderedLatticePixels(
            mesh, scene: scene,
            clipTo: [Self.hisSlab(mesh, halfU: 37, halfW: 37)], device: device)
        print("""

        ================================================================================
        A SUB-CELL SHRINK, IN PIXELS (cell 8.0 mm, shrink 3.0 mm)
          region as declared ....... \(full) lattice pixels
          region pulled in 3 mm .... \(shrunk) lattice pixels
        ================================================================================
        """)
        XCTAssertGreaterThan(full, 0, "the unshrunk arm must draw a lattice at all")
        XCTAssertLessThan(shrunk, full,
                          "★ HIS REPORT: pulling the region in must pull the LATTICE in. "
                          + "The struts were bounded by the 8 mm cell grid, which cannot "
                          + "express a 3 mm change, so the picture did not move.")
    }

    /// ★ AND THE LATTICE LIVES OR DIES BY THE REGION, not by the cell grid.
    ///
    /// ★ WHY THIS SHAPE AND NOT "ARMED DRAWS FEWER PIXELS THAN DISARMED". That was
    /// the first form of this test and it was REPLACED, because it measured
    /// something a single viewpoint cannot see: the whole-cell overhang lies
    /// INSIDE the part, behind the struts that are legitimately in the region, so
    /// from the camera it is occluded and both arms rendered 1344 identical pixels
    /// — a green run measuring nothing. The overhang is real (20% of the
    /// strut-bearing VOLUME, measured above); it simply is not a silhouette.
    ///
    /// So the claim is made where it is unambiguous and view-independent: clip the
    /// SAME bake to a region far too small to hold it, and the struts must very
    /// nearly all go. A march bounded by the cell grid instead of the region would
    /// be unmoved — that is precisely the disarmed number, asserted alongside.
    @MainActor
    func testTheStrutsAreBoundedByTheRegionAndNotByTheCellGrid() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal device") }
        let mesh = try LatticePreviewConfettiTests.hisMesh()
        let scene = LatticeSDFScene(mesh: mesh, field: nil, latticeID: "octet",
                                    regions: [Self.hisSlab(mesh)],
                                    whenEmpty: .latticeNothing)
        // The cell-grid behaviour: no region reaches the march at all.
        let cellBound = try renderedLatticePixels(mesh, scene: scene,
                                                  clipTo: [], device: device)
        // The same bake, clipped to a sliver of the declared slab.
        let sliver = try renderedLatticePixels(
            mesh, scene: scene,
            clipTo: [Self.hisSlab(mesh, halfU: 2, halfW: 2)], device: device)
        print("""

        ================================================================================
        BOUNDED BY THE REGION, NOT THE CELL GRID
          march clipped by the CELL GRID only ...... \(cellBound) lattice pixels
          same bake, region cut to a 2 mm sliver ... \(sliver) lattice pixels
        ================================================================================
        """)
        XCTAssertGreaterThan(cellBound, 100,
                             "the cell-bound arm must draw a real lattice to compare against")
        XCTAssertLessThan(sliver, cellBound / 4,
                          "★ HIS WORDS: 'You need to make *only* the face's area turned "
                          + "into a lattice.' A region cut to a sliver must take the "
                          + "struts with it. Bounded by the 8 mm cell grid instead, the "
                          + "picture would not move at all.")
    }

    /// ★ AND THE SAMPLE BLOCK IS UNTOUCHED. No regions ⇒ the clip is inert, not
    /// total: the settings page's cell has no declarations by construction and its
    /// entire subject is the lattice. A clip that defaulted to "remove everything"
    /// would blank it — the same class of implicit default `EmptyRegionPolicy`
    /// exists to prevent.
    @MainActor
    func testAPreviewWithNoRegionsIsNotClippedAway() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal device") }
        let mesh = try LatticePreviewConfettiTests.hisMesh()
        let sample = LatticeSDFScene(mesh: mesh, field: nil, latticeID: "octet")
        let px = try renderedLatticePixels(mesh, scene: sample, clipTo: [], device: device)
        XCTAssertGreaterThan(px, 0,
                             "★ a scene with NO declared regions must still draw its "
                             + "lattice — 'no regions' means the clip removes nothing, "
                             + "for the march exactly as for the shell")
    }
}
