// LatticeGradingWiringTests — ★★★ THE FOUR THINGS THAT WERE DECLARED AND NOT CONNECTED.
//
// (maintainer, 2026-08-22: "I have a feeling minimize plastic isn't wired up and that
// the thickness of the struts / the density is hard wired to the absolute stress when
// this is the relative stress and should be divided as such".)
//
// He was right that something in the relative/absolute chain was not connected. The
// audit found three gaps and none of them was the one anyone would have guessed:
//
//   1. `demand(...)` defaults `intent` to 1 (AESTHETIC) and BOTH call sites took the
//      default — so the grading denominator was the field's own percentile in EVERY
//      mode. `LatticeStageMode` leads with "THE DENOMINATOR … so the same part grades
//      differently"; that was written down and not implemented.
//   2. `minimizePlastic` reached the optimizer and the cell-plan helper and had NO path
//      to the lattice's density.
//   3. Core culls a cell whose member cannot hold N* of it, and the bridge never set
//      `cells_per_member_floor_override` — so the planner used the ACCURACY floor of 5
//      however far the mode had relaxed.
//
// These are one bar per link. A comment claiming a value is wired is worth nothing; a
// test that fails when the argument is dropped is the only thing that holds it.

import XCTest
import simd
import TopOptKit
@testable import TopOptFlows

final class LatticeGradingWiringTests: XCTestCase {

    /// A uniform grid with a UNIFORM stress field far below yield. Uniform is the point:
    /// a relative reference makes every voxel read ~1.0 (each is the 95th percentile of
    /// itself), while an absolute one reads the true small fraction. The two answers are
    /// maximally far apart here, which is what makes the wiring visible.
    private func field(_ n: Int, mpa: Float) -> StressField {
        StressField(nx: n, ny: n, nz: n, origin: .zero, spacing: 1,
                    values: [Float](repeating: mpa, count: n * n * n))
    }

    private func grid(_ n: Int) -> LatticeVoxelGrid {
        LatticeVoxelGrid(nx: n, ny: n, nz: n, origin: .zero,
                         spacing: SIMD3<Float>(repeating: 1),
                         values: [Float](repeating: 1, count: n * n * n))
    }

    /// ★★★ LINK 1: the intent reaches core, and the two denominators differ.
    func testTheDenominatorActuallyFollowsTheIntent() throws {
        let g = grid(8), f = field(8, mpa: 5)      // 5 MPa against a 50 MPa allowable
        let relative = try XCTUnwrap(
            LatticePreviewOccupancy.demand(like: g, field: f, intent: 1))
        let absolute = try XCTUnwrap(
            LatticePreviewOccupancy.demand(like: g, field: f, intent: 0, allowableMPa: 50))
        let r = Double(relative.values[0]), a = Double(absolute.values[0])
        print("── uniform 5 MPa, allowable 50 MPa: relative \(r), absolute \(a)")
        XCTAssertEqual(r, 1.0, accuracy: 1e-6,
                       "★ a uniform field IS its own percentile — relative must read 1")
        XCTAssertEqual(a, 0.1, accuracy: 1e-6,
                       "★ 5 / 50 — absolute must read the true utilisation")
        XCTAssertLessThan(a, r, "★ the two intents produced the same answer; the "
                              + "denominator is not following the intent")
    }

    /// ★ AND STRUCTURAL WITHOUT AN ALLOWABLE MUST NOT FLATTEN THE PART. Core returns 0
    /// for every voxel when the reference is not positive, so asking for the absolute
    /// denominator with no yield strength would silently drop the whole lattice to the
    /// band floor. The scene keeps the relative reference there instead — this pins that
    /// the hazard is real, so the guard is not removed as redundant.
    func testTheAbsoluteDenominatorCollapsesWithNoAllowable() throws {
        let g = grid(8), f = field(8, mpa: 5)
        let none = try XCTUnwrap(
            LatticePreviewOccupancy.demand(like: g, field: f, intent: 0, allowableMPa: 0))
        XCTAssertEqual(none.values.max() ?? -1, 0,
                       "★ core no longer zeroes an unreferenced structural demand — the "
                     + "scene's guard may be reconsidered")
    }

    /// ★★★ LINK 2: minimize plastic reaches the density, and only ever downward.
    func testMinimizePlasticCapsTheAestheticDemandAndNeverRaisesIt() throws {
        let mesh = try LatticePreviewConfettiTests.hisMesh()
        let f = StressField(nx: 8, ny: 8, nz: 8, origin: SIMD3<Float>(mesh.bounds.min),
                            spacing: Float((mesh.bounds.max.x - mesh.bounds.min.x) / 8),
                            values: [Float](repeating: 4, count: 512))   // far below yield
        func scene(_ minimize: Bool) -> LatticeSDFScene {
            LatticeSDFScene(mesh: mesh, field: f, latticeID: "octet",
                            stageMode: .aesthetic, allowableMPa: 50,
                            minimizePlastic: minimize, maxDim: 48)
        }
        let off = scene(false), on = scene(true)
        let a = try XCTUnwrap(off.demand), b = try XCTUnwrap(on.demand)
        XCTAssertEqual(a.values.count, b.values.count)
        var lowered = 0
        for i in 0..<a.values.count {
            XCTAssertLessThanOrEqual(b.values[i], a.values[i] + 1e-6,
                                     "★ minimize plastic ADDED material at \(i)")
            if b.values[i] < a.values[i] - 1e-6 { lowered += 1 }
        }
        print("── minimize plastic lowered \(lowered) of \(a.values.count) demands "
            + "(off max \(a.values.max() ?? 0), on max \(b.values.max() ?? 0))")
        XCTAssertGreaterThan(lowered, 0,
            "★ the checkbox changed NOTHING — it is still not wired to the density")
    }

    /// ★★★ LINK 3: the cells-per-member floor reaches CORE'S PLANNER, which is what
    /// decides whether a cell is kept or culled to solid. This is the one that left only
    /// the thick spine latticed: a 4.4 mm cell in an 11 mm wall needs 22 mm of member at
    /// N* = 5 and was culled, while at N* = 2 it needs 8.8 mm and survives.
    func testTheFloorReachesCoresPlannerAndChangesWhatSurvives() throws {
        // A slab 12 voxels (mm) thick — a member that clears 2 cells of 4 mm but not 5.
        let nx = 12, ny = 24, nz = 24
        let n = nx * ny * nz
        let candidate = [Bool](repeating: true, count: n)
        let rho = [Double](repeating: 0.3, count: n)
        let width = [Double](repeating: 12.0, count: n)      // 12 mm of member everywhere
        func activeCells(floor: Double) -> Int {
            guard let plan = TopOptKit.latticeCellSizePlan(
                nx: nx, ny: ny, nz: nz, spacing: SIMD3<Float>(repeating: 1),
                origin: .zero, candidate: candidate, relativeDensity: rho,
                memberWidthMM: width, minCellMM: 4, maxCellMM: 8,
                minExtrudableWidthMM: 0.42, capRadiusVoxels: 16, topology: "octet",
                cellsPerMemberFloor: floor) else { return -1 }
            return plan.level.filter { $0 >= 0 }.count
        }
        let atFive = activeCells(floor: 5)
        let atTwo = activeCells(floor: 2)
        print("── 12 mm member, 4-8 mm ladder: cells kept at N*=5 -> \(atFive), "
            + "at N*=2 -> \(atTwo)")
        XCTAssertGreaterThanOrEqual(atFive, 0)
        XCTAssertGreaterThan(atTwo, atFive,
            "★ core kept the SAME number of cells at both floors — the override is not "
          + "reaching `CellPlanParams.cells_per_member_floor_override`")
        XCTAssertEqual(atFive, 0,
            "★ a 12 mm member cannot hold 5 cells of the 4 mm base — if core keeps them "
          + "the control in this test is not controlling")
    }

    /// ★★★ LINK 4: the two inputs the denominator is made of are in the bake's
    /// fingerprint. A value the bake READS and the fingerprint IGNORES is a stale
    /// picture by construction — the box is ticked and nothing redraws.
    func testTheRebakeFingerprintCoversBothGradingInputs() throws {
        let src = try String(contentsOfFile:
            "Sources/TopOptFlows/WorkspacePlaceholder.swift", encoding: .utf8)
        guard let r = src.range(of: "private var latticeRegionInputsKey: Int {"),
              let end = src.range(of: "return h.finalize()",
                                  range: r.upperBound..<src.endIndex)
        else { return XCTFail("`latticeRegionInputsKey` not found") }
        let body = String(src[r.upperBound..<end.lowerBound])
        XCTAssertTrue(body.contains("h.combine(project.minimizePlastic)"),
                      "★ minimizePlastic feeds the demand and is not in the fingerprint")
        XCTAssertTrue(body.contains("h.combine(project.material)"),
                      "★ the material IS the allowable, and is not in the fingerprint")
        XCTAssertTrue(body.contains("h.combine(l.stageMode)"),
                      "★ the mode picks the denominator and is not in the fingerprint")
    }
}
