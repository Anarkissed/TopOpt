// LatticePreviewFloorVsCoreTests — ★ THE OPEN QUESTION FROM 83c1f142, ANSWERED BY
// MEASUREMENT (task 2026-08-21).
//
// 83c1f142 committed RED on purpose. Five render fixtures (nine assertions) stopped
// drawing any lattice once the cells-per-member floor began asking EVERY voxel under
// the cell instead of the centre one, and they failed their own positive controls
// ("there must be a lattice to dress"). That commit refused to tune them green before
// settling which side was wrong:
//
//   * either core would ALSO leave that material solid — the fixtures assert a lattice
//     the run never builds, and the FIXTURES are what must change; or
//   * `LatticePreviewOccupancy.cellField`'s worst-voxel rule is STRICTER than core's,
//     and the PREVIEW is what must change.
//
// ★★ THE ANSWER IS THE FIRST ONE. Measured on the very scene `LatticeFinishRendersTests`
// fails on — his part, face 15, depth 11.0 mm, at the fixture's own 8.00 mm cell:
//
//     occupancy voxels in the region ........ 30,676
//     member width  min / median / max ...... 3.46 / 10.39 / 10.39 mm
//     a 8.00 mm cell needs (N* = 5) ......... 40.00 mm
//     core's UNIFORM law latticeS ........... 0 of 30,676 voxels
//     core's SWEPT planner latticeS ......... 0 base cells (638 "member too thin")
//     the preview draws ..................... 0 cells
//
// The widest material anywhere under that region is 10.39 mm against a 40 mm
// requirement — not marginal, off by a factor of four. The run leaves every voxel of it
// SOLID. The preview drawing nothing is CORRECT, and the fixtures were asserting a
// lattice that has never been buildable at their cell size.
//
// ★ THE HYPOTHESIS I CAME IN WITH, RECORDED AS REFUTED. Core does carry TWO
// cells-per-member rules, and they genuinely differ:
//
//   SWEPT / FIT — `plan_cell_sizes` (core/src/simp/cell_plan.cpp) aggregates each base
//     cell's candidate voxels to `width_min[c]`, the THINNEST member anywhere in it, and
//     caps the level on that: `if (width_min[c] / S >= n_star) cap[c] = L`. Whole-cell,
//     worst-voxel — exactly what the preview does.
//
//   FIXED / AUTO — `grade_lattice`'s uniform branch (core/src/simp/grading.cpp:414-475)
//     decides PER VOXEL on that voxel's own width, with no aggregation at all:
//     `cpm = width[e] / cell; if (cpm < n_star) { ...solid...; continue; }`.
//
// The fixtures are on the uniform path (`cellSweep` is nil), so I expected the preview's
// whole-cell rule to be refusing material core's per-voxel rule would lattice. It is
// not. `drawnAny` below is that counterfactual — cells holding at least one voxel core
// would lattice — and it is ZERO too. When not one voxel qualifies, no aggregation rule
// (worst, any, or mean) can produce a cell, so the difference between the two laws
// cannot be what empties these fixtures. The distinction is real and worth knowing; it
// is not the cause here, and this file says so rather than leaving a plausible story
// standing next to a number that does not support it.
//
// ★ SO WHAT CHANGED. The render fixtures now declare a cell his part can actually hold,
// derived from core's own ceiling W / N* rather than tuned until the picture came back.
// Each one carries the reason at its own call site. Nothing in `cellField` moved.

import XCTest
import simd
import TopOptKit
@testable import TopOptFlows

final class LatticePreviewFloorVsCoreTests: XCTestCase {

    // MARK: - the fixture the red tests actually use

    /// ★ THE VERY SCENE `LatticeFinishRendersTests.testEachFinishRendersDifferently`
    /// builds — his own part, his face 15, at the depth that test declares. Measuring a
    /// DIFFERENT scene and reasoning across would be the "one reading, wrong quantity"
    /// mistake this branch has already paid for twice.
    @MainActor
    private func hisFinishScene() throws -> (LatticeSDFScene, LatticeProxyParams) {
        let mesh = try LatticePreviewConfettiTests.hisMesh()
        guard let r15 = LatticeRegionEmission.planeFor(face: FaceID(15), in: mesh),
              let spec = LatticeRegionEmission.spec(for: r15, role: .include,
                                                    depthMM: 11.0, faceID: 15)
        else { throw XCTSkip("no region for face 15 in this fixture") }
        let scene = LatticeSDFScene(mesh: mesh, field: nil, latticeID: "octet",
                                    regions: [spec], whenEmpty: .latticeNothing)
        return (scene, LatticePreviewConfettiTests.hisParams())
    }

    /// The cell a world point belongs to, in `cellField`'s own convention: cells are
    /// CENTRED at `occ.origin + i·cell`, so the owner is the rounded quotient. Written
    /// out rather than assumed — a half-cell offset would silently move every count here.
    private static func cellIndex(of w: SIMD3<Float>, origin: SIMD3<Float>,
                                  cell: Float, nx: Int, ny: Int, nz: Int) -> Int? {
        let g = (w - origin) / cell
        let i = Int(g.x.rounded()), j = Int(g.y.rounded()), k = Int(g.z.rounded())
        guard i >= 0, i < nx, j >= 0, j < ny, k >= 0, k < nz else { return nil }
        return (k * ny + j) * nx + i
    }

    /// Core's UNIFORM law, per voxel: `width[e] / cell >= n_star`. `+inf` is core's
    /// "thicker than the EDT cap measured" sentinel and clears, as core's own comment
    /// states.
    private static func coreLatticesVoxel(_ w: Double, cell: Double, nStar: Double)
        -> Bool { !w.isFinite || (w > 0 && w / cell >= nStar) }

    // MARK: - ★★ THE MEASUREMENT

    /// ★★ CORE'S TWO LAWS AND THE PREVIEW'S ONE, over the failing fixture, in counts.
    /// This is the test the open question asked for, kept as a test so the answer cannot
    /// rot into a paragraph nobody re-runs.
    @MainActor
    func testCoreLeavesThisFixturesMaterialSolidToo() throws {
        let (scene, params) = try hisFinishScene()
        try XCTSkipIf(scene.memberThicknessMM.isEmpty, "core gave no widths in this build")
        let occ = scene.occupancy
        let cell = params.cellMM
        let nStar = scene.minCellsPerMember
        XCTAssertGreaterThan(nStar, 0, "positive control: core must state an N*")
        XCTAssertGreaterThan(cell, 0, "positive control: the fixture must have a cell")

        // ── the material ────────────────────────────────────────────────────────────
        let inside = (0..<occ.count).filter { occ.values[$0] > 0.5 }
        XCTAssertFalse(inside.isEmpty, "positive control: the region has material")
        let widths = inside.map { scene.memberThicknessMM[$0] }
        let finite = widths.filter { $0.isFinite && $0 > 0 }.sorted()
        let capped = widths.filter { !$0.isFinite }.count
        XCTAssertFalse(finite.isEmpty,
                       "positive control: some material must be MEASURED, or every "
                       + "width is core's +inf sentinel and no rule can bind")

        // ── 1 · CORE'S UNIFORM LAW (Fixed/Auto), PER VOXEL ──────────────────────────
        let coreLatticedVoxels = inside.filter {
            Self.coreLatticesVoxel(scene.memberThicknessMM[$0], cell: cell, nStar: nStar)
        }.count

        // ── 2 · THE PREVIEW AS IT STANDS — worst voxel under the cell ───────────────
        let drawnWorst = LatticePreviewOccupancy.cellField(
            occupancy: occ, demand: scene.demand, cellMM: cell,
            memberThickness: scene.memberThicknessMM,
            minCellsPerMember: nStar).values.filter { $0 >= 0 }.count

        // ── 3 · THE FLOOR DISARMED — how many cells there are to gate at all ────────
        let unfloored = LatticePreviewOccupancy.cellField(
            occupancy: occ, demand: scene.demand, cellMM: cell)
        let drawnNoFloor = unfloored.values.filter { $0 >= 0 }.count
        XCTAssertGreaterThan(drawnNoFloor, 0,
                             "positive control: without the floor there ARE cells here "
                             + "— otherwise this fixture is empty for some other reason "
                             + "and none of the numbers below mean what they say")

        // ── 4 · THE COUNTERFACTUAL — cells holding at least one core-latticed voxel ──
        // What the run builds, binned onto the preview's own cell grid. This is the
        // number that would have supported the "worst-voxel is too strict" story.
        var cellHasLatticedVoxel = [Bool](repeating: false, count: unfloored.values.count)
        for e in inside where Self.coreLatticesVoxel(scene.memberThicknessMM[e],
                                                     cell: cell, nStar: nStar) {
            let ix = e % occ.nx, iy = (e / occ.nx) % occ.ny, iz = e / (occ.nx * occ.ny)
            let p = occ.origin + SIMD3<Float>(Float(ix), Float(iy), Float(iz)) * occ.spacing
            if let c = Self.cellIndex(of: p, origin: unfloored.origin, cell: Float(cell),
                                      nx: unfloored.nx, ny: unfloored.ny,
                                      nz: unfloored.nz) {
                cellHasLatticedVoxel[c] = true
            }
        }
        let drawnAny = cellHasLatticedVoxel.filter { $0 }.count

        // ── 5 · CORE'S SWEPT PLANNER over the same fixture, at the same cell ────────
        // A degenerate ladder (min == max == the fixture's cell) is the uniform cell put
        // through the SWEPT law, so both of core's rules are asked of ONE input.
        var candidate = [Bool](repeating: false, count: occ.count)
        var rho = [Double](repeating: 0, count: occ.count)
        for e in inside { candidate[e] = true; rho[e] = params.uniformRelativeDensity }
        let plan = TopOptKit.latticeCellSizePlan(
            nx: occ.nx, ny: occ.ny, nz: occ.nz, spacing: occ.spacing,
            origin: occ.origin, candidate: candidate, relativeDensity: rho,
            memberWidthMM: scene.memberThicknessMM,
            minCellMM: cell, maxCellMM: cell,
            // His own nozzle, stated — the preview params carry no bead.
            minExtrudableWidthMM: 0.42,
            capRadiusVoxels: 16, topology: params.latticeID)
        // Unwrapped explicitly: core returning NO plan and core returning an EMPTY plan
        // are different answers, and -1 is how this probe says "no answer at all".
        var planLatticed = -1, planThin = -1, planUnprintable = -1
        if let p = plan {
            planLatticed = p.level.filter { $0 >= 0 }.count
            planThin = p.rejectReason.filter { $0 == 1 }.count
            planUnprintable = p.rejectReason.filter { $0 == 2 }.count
        }

        // ── 6 · THE SWEEP — where does core START latticing this material? ──────────
        // The fixture's cell is a DEFAULT (8 mm), not a number his part chose. Core's
        // ceiling is W / N*, so this is arithmetic; it is swept rather than asserted so
        // the fixture repair is DERIVED from core's law instead of tuned until the
        // picture came back.
        var sweep: [(Double, Int, Int)] = []
        for c in [8.0, 4.0, 3.0, 2.5, 2.0, 1.5, 1.0] {
            let voxels = inside.filter {
                Self.coreLatticesVoxel(scene.memberThicknessMM[$0], cell: c, nStar: nStar)
            }.count
            let cells = LatticePreviewOccupancy.cellField(
                occupancy: occ, demand: scene.demand, cellMM: c,
                memberThickness: scene.memberThicknessMM,
                minCellsPerMember: nStar).values.filter { $0 >= 0 }.count
            sweep.append((c, voxels, cells))
        }

        func mm(_ v: Double) -> String { String(format: "%.2f", v) }
        print("""

        ================================================================================
        THE OPEN QUESTION FROM 83c1f142 — core's plan vs the preview's floor
        fixture: LatticeFinishRendersTests' scene (his part, face 15, depth 11.0 mm)
        --------------------------------------------------------------------------------
        cell size ....................... \(mm(cell)) mm   (the DEFAULT, uniform path)
        N* (core, octet) ................ \(mm(nStar))
        a \(mm(cell)) mm cell needs a member of \(mm(cell * nStar)) mm
        occupancy voxels inside ......... \(inside.count)
          measured widths ............... \(finite.count)
          +inf (thicker than the cap) ... \(capped)
          width  min / median / max ..... \(mm(finite.first ?? 0)) / \
        \(mm(finite.isEmpty ? 0 : finite[finite.count / 2])) / \(mm(finite.last ?? 0)) mm
        --------------------------------------------------------------------------------
        CORE, UNIFORM LAW (Fixed/Auto, grading.cpp:423) — decided PER VOXEL
          voxels the run LATTICES ....... \(coreLatticedVoxels) of \(inside.count)
        CORE, SWEPT PLANNER (plan_cell_sizes) — per BASE CELL, worst voxel
          base cells latticed ........... \(planLatticed)
          rejected: member too thin ..... \(planThin)
          rejected: strut unprintable ... \(planUnprintable)
        --------------------------------------------------------------------------------
        THE PREVIEW, on this uniform fixture
          cells with no floor at all .... \(drawnNoFloor)
          cells drawn, WORST-voxel ...... \(drawnWorst)      <- what ships today
          cells holding >=1 latticed vox. \(drawnAny)      <- what the RUN builds
        --------------------------------------------------------------------------------
        CELL SWEEP over the same region
          cell mm    core latticeS (of \(inside.count))    preview cells drawn
        \(sweep.map { String(format: "  %7.2f    %19d    %19d", $0.0, $0.1, $0.2) }
              .joined(separator: "\n"))
          core's ceiling W / N* = \(mm((finite.last ?? 0) / nStar)) mm on the widest
          material here, \(mm((finite.first ?? 0) / nStar)) mm on the thinnest
        ================================================================================
        """)

        // ── ★★ THE ANSWER, AND IT IS NOT THE ONE I EXPECTED ─────────────────────────
        // I went in holding the second hypothesis — core's per-voxel uniform law would
        // lattice material the preview's worst-voxel rule refuses — and the measurement
        // KILLED it. Recorded as refuted rather than quietly dropped.
        XCTAssertEqual(coreLatticedVoxels, 0,
                       "★ THE ANSWER: at this fixture's \(mm(cell)) mm cell core's own "
                       + "uniform law latticeS NOTHING — the run leaves every voxel "
                       + "solid. The preview drawing nothing is CORRECT.")
        XCTAssertEqual(drawnWorst, 0, "and the preview agrees, which is the point")
        XCTAssertEqual(drawnAny, 0,
                       "★ REFUTED, explicitly: not one voxel qualifies, so no "
                       + "aggregation rule — worst, any or mean — could draw a cell "
                       + "here. The two-core-laws divergence is real but is NOT what "
                       + "empties this fixture.")
        XCTAssertGreaterThan(planLatticed, -1,
                             "positive control: core's planner must have ANSWERED, or "
                             + "the rows above compare against nothing")
        XCTAssertEqual(planLatticed, 0,
                       "★ core's SWEPT planner refuses it too, for the same reason")
        XCTAssertGreaterThan(planThin, 0,
                             "★ and it names the reason: member too thin")

        // ── ★ THE FIXTURE REPAIR IS DERIVED, NOT TUNED ──────────────────────────────
        // A cell at core's own ceiling W / N* on the widest material here is one core
        // WILL lattice. That is where the repaired render fixtures sit.
        let ceiling = (finite.last ?? 0) / nStar
        XCTAssertGreaterThan(ceiling, 0, "core's ceiling must be a real length")
        let atCeiling = inside.filter {
            Self.coreLatticesVoxel(scene.memberThicknessMM[$0], cell: ceiling,
                                   nStar: nStar)
        }.count
        XCTAssertGreaterThan(atCeiling, 0,
                             "★ at W / N* core latticeS real material — this is the cell "
                             + "the repaired render fixtures use, and it comes from "
                             + "core's law rather than from tuning")
    }

    /// ★★ THE GUARD ON THE FIXTURE REPAIR. `renderableCellMM` is the cell the five
    /// repaired render fixtures use; it is only legitimate while it sits at or under
    /// core's own ceiling W / N* on this fixture's material. Re-measured from core here,
    /// so a change to the mesh, to N*, or to core's width law FAILS THIS TEST rather
    /// than silently emptying five render fixtures again — which is precisely what
    /// happened in 83c1f142 and cost two days to attribute.
    @MainActor
    func testTheRenderFixtureCellStaysUnderCoresCeiling() throws {
        let (scene, _) = try hisFinishScene()
        try XCTSkipIf(scene.memberThicknessMM.isEmpty, "core gave no widths in this build")
        let occ = scene.occupancy
        let nStar = scene.minCellsPerMember
        let inside = (0..<occ.count).filter { occ.values[$0] > 0.5 }
        let widest = inside.map { scene.memberThicknessMM[$0] }
            .filter { $0.isFinite && $0 > 0 }.max() ?? 0
        XCTAssertGreaterThan(widest, 0, "positive control: measured material")
        XCTAssertGreaterThan(nStar, 0, "positive control: core states an N*")

        let ceiling = widest / nStar
        let cell = LatticePreviewConfettiTests.renderableCellMM
        XCTAssertLessThanOrEqual(
            cell, ceiling,
            String(format: "★ the render fixtures' cell (%.2f mm) must stay at or under "
                   + "core's ceiling W / N* = %.2f / %.2f = %.2f mm. Above it core "
                   + "latticeS nothing and every render fixture goes empty.",
                   cell, widest, nStar, ceiling))

        // ★ AND IT MUST ACTUALLY PRODUCE A LATTICE — a cell under the ceiling that still
        // drew nothing would satisfy the line above and leave the fixtures broken.
        let drawn = LatticePreviewOccupancy.cellField(
            occupancy: occ, demand: scene.demand, cellMM: cell,
            memberThickness: scene.memberThicknessMM,
            minCellsPerMember: nStar).values.filter { $0 >= 0 }.count
        XCTAssertGreaterThan(drawn, 1000,
                             "★ at \(cell) mm the preview must draw a real lattice over "
                             + "this region — got \(drawn) cells")
    }

    /// ★★ AND THE DEFECT 83c1f142 FOUND STAYS FIXED — the guard that keeps the fixture
    /// repair from quietly re-opening it.
    ///
    /// Its measurement: on his 13 mm region at a 4 mm cell, ZERO of 6,276 voxels clear
    /// N* = 5 (4 mm needs 20 mm; the material is at most ~13.9 mm) and the old centre
    /// sample drew 374 cells anyway, because a centre in free space measured 0 and
    /// `if t > 0` read that as consent. Asked of core's own per-voxel law, the answer on
    /// that scene is still zero.
    @MainActor
    func testTheOriginalDefectStaysFixedUnderCoresRule() throws {
        let mesh = try LatticePreviewConfettiTests.hisMesh()
        var region = LatticeRegionFidelityTests.hisSlab(mesh, halfU: 200, halfW: 200)
        region.depthMM = 13
        let scene = LatticeSDFScene(mesh: mesh, field: nil, latticeID: "octet",
                                    regions: [region], whenEmpty: .latticeNothing)
        try XCTSkipIf(scene.memberThicknessMM.isEmpty, "core gave no widths")
        let occ = scene.occupancy
        let inside = (0..<occ.count).filter { occ.values[$0] > 0.5 }
        XCTAssertGreaterThan(inside.count, 0, "positive control: the region has material")

        let latticed = inside.filter {
            Self.coreLatticesVoxel(scene.memberThicknessMM[$0], cell: 4.0,
                                   nStar: scene.minCellsPerMember)
        }.count
        XCTAssertEqual(latticed, 0,
                       "★ 83c1f142's own measurement, re-asked of core's per-voxel law: "
                       + "at a 4 mm cell NOTHING in this region qualifies. The run "
                       + "leaves it entirely solid.")

        let drawn = LatticePreviewOccupancy.cellField(
            occupancy: occ, demand: scene.demand, cellMM: 4.0,
            memberThickness: scene.memberThicknessMM,
            minCellsPerMember: scene.minCellsPerMember)
            .values.filter { $0 >= 0 }.count
        XCTAssertEqual(drawn, 0,
                       "★ no voxel qualifies, so no cell may be drawn — the 374 cells "
                       + "the centre sample drew must stay gone")

        // ★ POSITIVE CONTROL, so the line above is not passing because the scene has no
        // cells at all: with the floor disarmed there are plenty.
        XCTAssertGreaterThan(
            LatticePreviewOccupancy.cellField(occupancy: occ, demand: scene.demand,
                                              cellMM: 4.0)
                .values.filter { $0 >= 0 }.count, 100,
            "positive control: there ARE 4 mm cells over this region to refuse")
    }
}
