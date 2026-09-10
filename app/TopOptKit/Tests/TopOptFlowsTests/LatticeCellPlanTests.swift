// LatticeCellPlanTests — ★ B4: "AUTO" GRADES, AND THE OBJECTIVE PICKS THE WINDOW.
//
// (maintainer, 2026-08-19: "Cell size = Auto should absolutely be *any* number -
// as needed based on the stress map, not just a single cell size. Swept should
// limit it to a smaller range but still automatically selected based on the sim,
// and only *manual* should force a single number through the entire lattice."
// And: "If 'minimize_plastic' is on … cells as large as possible and as least
// dense as possible … If minimize_plastic is off then the goal is to make it as
// strong as possible.")
//
// ★ THE FACT THAT DECIDES THE DESIGN: core's own `auto` is ONE UNIFORM CELL and
// says so in a throw — `plan_cell_sizes` refuses every mode but `Swept` ("the
// Fixed and Auto paths are one uniform cell and stay in grade_lattice",
// core/src/simp/cell_plan.cpp:114). Core DOES grade, under `swept`: a dyadic
// ladder where each block takes the coarsest level printability asks for. So the
// app's Auto maps onto SWEPT with a window the app derives — no second grading
// law, and the "unloaded wall goes coarse" behaviour is core's existing one.

import XCTest
import TopOptKit
@testable import TopOptFlows

final class LatticeCellPlanTests: XCTestCase {

    private var limits: TopOptKit.LatticeLimits { TopOptKit.latticeLimits(topology: "octet") }

    private func settings(_ mode: LatticeCellSizeMode) -> LatticeSettings {
        var s = LatticeSettings(enabled: true)
        s.topologyID = "octet"
        s.cellMM = 4
        s.cellSizeMode = mode
        s.densityMode = .sim
        s.simulateStresses = true
        return s
    }

    private func bounds(_ s: LatticeSettings) -> LatticeBounds {
        LatticeBounds.compute(settings: s, limits: limits, lineWidthMM: 0.42)
    }

    /// ★ AUTO IS SWEPT, AND WITH MINIMISE-PLASTIC ON IT OPENS A REAL LADDER.
    func testAutoGradesAndIsNotOneCell() {
        let s = settings(.auto)
        let plan = s.resolvedCellPlan(bounds: bounds(s), minimizePlastic: true)
        XCTAssertEqual(plan.mode, .swept,
                       "★ Auto must reach core as SWEPT — core's own `auto` is one "
                       + "uniform cell and cannot grade")
        XCTAssertGreaterThan(plan.hiMM, plan.loMM,
                             "★ …and with a real window, or the dyadic ladder holds "
                             + "exactly one level and every block takes it")
        // A ladder of more than one level is what "any number" needs.
        XCTAssertGreaterThanOrEqual(plan.hiMM / plan.loMM, 2.0,
                                    "★ at least one doubling, or there is no ladder")
    }

    /// ★ AND WITH THE OBJECTIVE OFF IT PINS THE FINEST PRINTABLE CELL.
    func testStrengthFirstHoldsTheFinestCell() {
        let s = settings(.auto)
        let b = bounds(s)
        let strong = s.resolvedCellPlan(bounds: b, minimizePlastic: false)
        let light = s.resolvedCellPlan(bounds: b, minimizePlastic: true)
        XCTAssertEqual(strong.loMM, strong.hiMM, accuracy: 1e-9,
                       "★ strength first ⇒ one level ⇒ the finest printable cell "
                       + "everywhere, with the density still graded")
        XCTAssertEqual(strong.loMM, light.loMM, accuracy: 1e-9,
                       "both start at the same floor — the objective moves the CEILING")
        XCTAssertGreaterThan(light.hiMM, strong.hiMM,
                             "★ minimising plastic must allow coarser cells")
    }

    /// Swept keeps the user's window; Manual and Fit stay single-valued.
    func testTheOtherThreeModesAreUnchanged() {
        var sw = settings(.swept)
        sw.cellMinMM = 3; sw.cellMaxMM = 9
        let p = sw.resolvedCellPlan(bounds: bounds(sw), minimizePlastic: true)
        XCTAssertEqual(p.mode, .swept)
        XCTAssertEqual(p.hiMM, 9, accuracy: 1e-9, "★ Swept is the USER's window")

        for m in [LatticeCellSizeMode.fixed, .fit] {
            let s = settings(m)
            let q = s.resolvedCellPlan(bounds: bounds(s), minimizePlastic: true)
            XCTAssertEqual(q.mode, m, "★ \(m) must pass through untouched")
            XCTAssertEqual(q.loMM, 0, "★ …and carries no window")
        }
    }

    /// ★ AND IT REACHES THE EMITTED JOB — a plan that stopped at the struct would
    /// be the decorative-control defect again.
    func testTheObjectiveReachesTheEmittedSpec() throws {
        var s = settings(.auto)
        s.maxRelativeDensity = 0.5
        let light = try XCTUnwrap(s.runSpec(limits: limits, generatable: true,
                                            lineWidthMM: 0.42, minimizePlastic: true))
        let strong = try XCTUnwrap(s.runSpec(limits: limits, generatable: true,
                                             lineWidthMM: 0.42, minimizePlastic: false))
        XCTAssertEqual(light.cellSizeMode, "swept")
        XCTAssertEqual(strong.cellSizeMode, "swept")
        XCTAssertGreaterThan(light.cellMaxMM, strong.cellMaxMM,
                             "★ the objective must change the WINDOW core receives")
        XCTAssertEqual(strong.cellMinMM, strong.cellMaxMM, accuracy: 1e-9)
    }
}
