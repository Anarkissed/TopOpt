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

    /// ★ THE CLIP IS NOW A PROPERTY OF THE BAKE, NOT A PER-FRAME LEVER — and that
    /// is why this helper takes a SCENE rather than a region list.
    ///
    /// These two tests used to bake once and vary `renderer.shellClipRegions`
    /// between arms, because the region was a rectangle the shader evaluated in
    /// closed form. It no longer is: a face region is its real OUTLINE
    /// (`LatticeFaceOutline`), which has no closed form a fragment can afford, so
    /// `LatticeSDFScene` bakes the union to a distance field and both the march
    /// and the shell sample THAT. A per-frame region list would be a second
    /// description of the region — exactly the drift the field exists to prevent
    /// — so the lever was removed rather than kept working.
    ///
    /// The assertions below are unchanged in what they claim. Only how the two
    /// arms are produced moved: one bake per region, which is also how the app
    /// produces them.
    @MainActor
    private func renderedLatticePixels(_ mesh: ViewerMesh,
                                       scene: LatticeSDFScene,
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
        let dump = try XCTUnwrap(renderer.latticeMaskDump(size: 512),
                                 "the lattice must reach the G-buffer at all")
        return dump.covered
    }

    /// A solid axis-aligned block, `mm` on a side, as a `ViewerMesh`.
    ///
    /// ★★ WHY THIS FIXTURE EXISTS AT ALL — and it is the only synthetic mesh in this
    /// file, added reluctantly (task 2026-08-21). See
    /// `testASubCellShrinkMovesTheRenderedLattice` for the full argument. In short:
    /// the sub-cell claim needs a cell MUCH coarser than a pixel, a coarse cell needs
    /// N* × cell of material, and his part does not have 40 mm of material anywhere a
    /// declared region's in-plane edge still cuts. Measured, on his own mesh:
    ///
    ///     region                    widest member    core's ceiling W / N*
    ///     halfU  40, depth 11 ....       10.39 mm            2.08 mm
    ///     halfU  40, depth 60 ....       13.86 mm            2.77 mm
    ///     halfU 100, depth 60 ....       45.03 mm            9.01 mm  ← edge is a
    ///                                                                   knife edge:
    ///                                                                   a 1 mm shrink
    ///                                                                   takes ALL 72
    ///                                                                   cells to zero
    ///
    /// At every cell his part CAN hold (≤ 2.77 mm) the cell is about four pixels wide
    /// at this dump size, so the quantiser and the picture move together and there is
    /// no window in which one is blind and the other is not — measured at 512, 1024 and
    /// 1536 px, where a grid-blind 0.3 mm shrink moved 1, 5 and 8 pixels out of 6,654.
    static func block(_ mm: Float) -> ViewerMesh {
        let h = mm * 0.5
        let c: [SIMD3<Float>] = [
            [-h, -h, -h], [h, -h, -h], [h, h, -h], [-h, h, -h],
            [-h, -h, h], [h, -h, h], [h, h, h], [-h, h, h]]
        let quads: [[Int]] = [[0, 3, 2, 1], [4, 5, 6, 7], [0, 1, 5, 4],
                              [1, 2, 6, 5], [2, 3, 7, 6], [3, 0, 4, 7]]
        var v: [Float] = [], idx: [Int32] = [], fids: [Int32] = []
        for (f, q) in quads.enumerated() {
            let b = Int32(v.count / 3)
            for i in q { v.append(contentsOf: [c[i].x, c[i].y, c[i].z]) }
            idx.append(contentsOf: [b, b + 1, b + 2, b, b + 2, b + 3])
            fids.append(contentsOf: [Int32(f), Int32(f)])
        }
        return ViewerMesh(vertices: v, indices: idx, faceIDs: fids, faceGeometry: [])
    }

    /// ★★ THE ONE THAT ANSWERS HIS WORDS. Two frames from ONE bake, differing only
    /// in the declared region: the full slab, and the same slab pulled in 3 mm —
    /// well under the 8 mm cell. The rendered lattice MUST shrink.
    ///
    /// Before the march was clipped this was impossible: the struts were bounded by
    /// the cell grid, which the in-test control below shows is byte-identical across
    /// this change. Both arms drew the same pixels.
    ///
    /// ★★ THE FIXTURE MOVED TO A BLOCK, AND THE CLAIM DID NOT (task 2026-08-21).
    /// It ran on his part. Once the cells-per-member floor began asking every voxel
    /// under the cell, his part rendered NOTHING at 8 mm and both arms became 0 — so
    /// `shrunk < full` was 0 < 0. That is not a fixture that can be nudged back: core
    /// leaves his material solid at 8 mm too (N* = 5 wants a 40 mm member; his widest
    /// is 10.39 mm under this region), which
    /// `LatticePreviewFloorVsCoreTests.testCoreLeavesThisFixturesMaterialSolidToo`
    /// establishes from core's own two laws. The preview was right and the fixture was
    /// wrong.
    ///
    /// Every attempt to keep his mesh was measured and rejected, and the numbers are
    /// recorded on `block(_:)` above. What is asserted here is IDENTICAL to what was
    /// asserted before — same 8 mm cell, same 3 mm sub-cell shrink, same direction,
    /// plus the quantiser control now inlined on the SAME fixture so the pair cannot
    /// drift onto different geometry. Only the mesh under it is one that can hold an
    /// 8 mm cell: a 120 mm block, whose material is thicker than core's EDT cap and so
    /// clears the floor by core's own `+inf` sentinel.
    ///
    /// ★ AND HIS PART STILL COVERS THE NEIGHBOURING CLAIM.
    /// `testTheStrutsAreBoundedByTheRegionAndNotByTheCellGrid` and
    /// `testTheCellGridAloneCannotSeeASubCellShrink` both still run on his own mesh, so
    /// this block buys the sub-cell RESOLUTION claim without taking real geometry out
    /// of the file.
    @MainActor
    func testASubCellShrinkMovesTheRenderedLattice() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal device") }
        let mesh = Self.block(120)
        let cell = LatticePreviewConfettiTests.hisParams().cellMM      // 8.0 mm
        let shrink = 3.0
        XCTAssertLessThan(shrink, cell,
                          "★ the shrink must be SMALLER than one cell, or this stops "
                          + "being a sub-cell test")
        let b = mesh.bounds
        let mid = (b.min + b.max) * 0.5
        func bake(_ half: Double) -> LatticeSDFScene {
            LatticeSDFScene(
                mesh: mesh, field: nil, latticeID: "octet",
                regions: [Self.slab(halfU: half, halfW: half, depth: 40,
                                    origin: SIMD3<Double>(Double(b.max.x),
                                                          Double(mid.y), Double(mid.z)),
                                    normal: SIMD3<Double>(-1, 0, 0))],
                whenEmpty: .latticeNothing)
        }
        // ★ THE CONTROL, ON THIS FIXTURE. The baked per-cell grid must be BLIND to the
        // shrink, or the pixel change below could be explained by the grid alone and
        // proves nothing about the march.
        func activeCells(_ s: LatticeSDFScene) -> Int {
            LatticePreviewOccupancy.cellField(occupancy: s.occupancy, demand: s.demand,
                                              cellMM: cell).values.filter { $0 >= 0 }.count
        }
        let cellsFull = activeCells(bake(40)), cellsShrunk = activeCells(bake(40 - shrink))
        let full = try renderedLatticePixels(mesh, scene: bake(40), device: device)
        let shrunkPixels = try renderedLatticePixels(mesh, scene: bake(40 - shrink),
                                                     device: device)
        print("""

        ================================================================================
        A SUB-CELL SHRINK, IN PIXELS (cell \(cell) mm, shrink \(shrink) mm, 120 mm block)
          CONTROL — active CELLS
            region as declared ....... \(cellsFull)
            region pulled in \(shrink) mm .. \(cellsShrunk)   (must be identical)
          THE PICTURE — lattice pixels
            region as declared ....... \(full)
            region pulled in \(shrink) mm .. \(shrunkPixels)
        ================================================================================
        """)
        XCTAssertGreaterThan(cellsFull, 0,
                             "positive control: the cell grid must have cells, or the "
                             + "equality below holds between two empty sets")
        XCTAssertEqual(cellsShrunk, cellsFull,
                       "★ THE CONTROL: the cell grid cannot express a \(shrink) mm "
                       + "change against a \(cell) mm cell. If this ever differs, the "
                       + "pixel bound below stops being evidence about the MARCH.")
        XCTAssertGreaterThan(full, 0, "the unshrunk arm must draw a lattice at all")
        XCTAssertLessThan(shrunkPixels, full,
                          "★ HIS REPORT: pulling the region in must pull the LATTICE in. "
                          + "The struts were bounded by the \(cell) mm cell grid, which "
                          + "cannot express a \(shrink) mm change, so the picture did "
                          + "not move.")
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
        // No region declared at all: the march is bounded only by the part and the
        // cell grid, which is the behaviour that produced the artifacts.
        let cellBound = try renderedLatticePixels(
            mesh,
            scene: LatticeSDFScene(mesh: mesh, field: nil, latticeID: "octet"),
            device: device)
        // A region cut to a sliver.
        let sliver = try renderedLatticePixels(
            mesh,
            scene: LatticeSDFScene(mesh: mesh, field: nil, latticeID: "octet",
                                   regions: [Self.hisSlab(mesh, halfU: 2, halfW: 2)],
                                   whenEmpty: .latticeNothing),
            device: device)
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

    /// ★★ THE MARCH IS BIT-EXACT, AND THAT IS THE HALF OF THE PICTURE THAT IS
    /// CURRENTLY TRUSTWORTHY.
    ///
    /// ★ WHY THIS EXISTS (maintainer, 2026-08-19: "I can see the lattices from
    /// behind the back wall shown as artifacts"). The speckle he photographed was
    /// measured to be lattice pixels — and the render producing them is NOT
    /// REPRODUCIBLE: the same frame, same camera, same scene, twelve times in one
    /// process with an OPAQUE shell gave 3,768 … 15,315 lattice pixels. A picture
    /// that changes when nothing changes cannot be reasoned about, so the first
    /// question was which participant is unstable.
    ///
    /// ★ THE BISECT: with the shell ABSENT the march returns the SAME number every
    /// time, spread 0, zero pixel disagreements. So the march, the region field
    /// and the clip are deterministic; the instability lives entirely in the
    /// shell-vs-lattice resolution in the shared depth buffer. This test pins the
    /// half that is exact, so a regression in the march cannot hide inside the
    /// half that is not. The shell interaction is recorded as open — deliberately
    /// NOT asserted here, because asserting a bound on a number that is currently
    /// unstable would be a test that passes by luck.
    @MainActor
    func testTheMarchAloneIsBitExactAcrossRepeatedRenders() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal device") }
        let mesh = try LatticePreviewConfettiTests.hisMesh()
        let scene = LatticeSDFScene(mesh: mesh, field: nil, latticeID: "octet",
                                    regions: [Self.hisSlab(mesh)],
                                    whenEmpty: .latticeNothing)
        guard let renderer = MeshRenderer(device: device, sampleCount: 1) else {
            throw XCTSkip("MeshRenderer init: \(MeshRenderer.lastInitError ?? "?")")
        }
        try XCTSkipUnless(renderer.latticePipelinesDidBuild, "lattice MSL must compile")
        renderer.setMesh(mesh)
        renderer.camera.setOrientation(azimuth: 0.7, elevation: 0.4)
        renderer.setBodyAlpha(0)          // ★ the shell OUT — that is the point
        renderer.setLatticeScene(scene, token: 1)
        // ★★ A CELL HIS PART CAN HOLD (task 2026-08-21). This read `hisParams()`, whose
        // cell is the shipped 8.00 mm default — and core builds NO lattice over this
        // slab at 8 mm (N* = 5 wants 40 mm of member; the widest material here measures
        // 10.39 mm, measured in `LatticePreviewFloorVsCoreTests`). All six renders
        // agreed on ZERO: a bit-exactness bar passing because there was nothing to be
        // exact about. The determinism claim has not moved — it is now asked of a
        // lattice the run would actually build.
        renderer.latticeParams = LatticePreviewConfettiTests.hisParamsAtACellHisPartCanHold()

        var counts: [Int] = []
        var first: [Bool]? = nil
        var disagreements = 0
        for _ in 0..<6 {
            guard let d = renderer.latticeMaskDump(size: 384) else { continue }
            counts.append(d.covered)
            if let f = first {
                for i in 0..<Swift.min(f.count, d.mask.count) where f[i] != d.mask[i] {
                    disagreements += 1
                }
            } else { first = d.mask }
        }
        XCTAssertEqual(counts.count, 6, "every render must produce a dump")
        XCTAssertGreaterThan(counts.first ?? 0, 100, "there must be a lattice to compare")
        XCTAssertEqual(Set(counts).count, 1,
                       "★ the march must be BIT-EXACT across repeated renders — got \(counts). "
                       + "A preview that changes when nothing changes cannot be diagnosed, "
                       + "and every measurement taken against it is worthless.")
        XCTAssertEqual(disagreements, 0,
                       "★ …and not merely equal in COUNT: the same pixels, every time.")
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
        let px = try renderedLatticePixels(mesh, scene: sample, device: device)
        XCTAssertGreaterThan(px, 0,
                             "★ a scene with NO declared regions must still draw its "
                             + "lattice — 'no regions' means the clip removes nothing, "
                             + "for the march exactly as for the shell")
    }
}
