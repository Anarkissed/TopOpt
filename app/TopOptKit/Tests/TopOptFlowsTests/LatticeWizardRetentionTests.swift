// LatticeWizardRetentionTests — ★★ THE SWITCH IS ON THE PAGE WHERE THE LATTICE IS
// SET UP (maintainer, 2026-08-20: "If you're saying I need to actually first optimize
// a part THEN go to a lattice page, you're out of your fucking mind. That's
// untenable. Add it to the settings of the lattice stage").
//
// Sub-floor retention decides whether a part's thin members come out as lattice or as
// solid — on his own part, 228 cells or 417. It shipped on the RESULTS page, behind a
// completed run and a selected variant, while every other decision that shapes the
// lattice lives in the setup wizard. So the one setting that halves the lattice was
// the one setting you could not reach while setting the lattice up.

import XCTest
@testable import TopOptFlows

final class LatticeWizardRetentionTests: XCTestCase {

    /// It goes both ways through the wizard's model — in from the project, out to it.
    func testTheWizardCarriesRetentionBothWays() {
        var stored = LatticeSettings(enabled: true)
        stored.retainSubfloorInUnloadedRegions = true
        stored.densityMode = .sim
        stored.cellSizeMode = .swept

        let model = LatticeWizardModel(settings: stored)
        XCTAssertTrue(model.retainSubfloor, "★ opening the page must show what the "
                      + "project already has, not the page's default")

        var off = LatticeWizardModel(settings: stored)
        off.retainSubfloor = false
        XCTAssertFalse(off.applied(to: stored).retainSubfloorInUnloadedRegions,
                       "★ and turning it off must reach the project")
        XCTAssertTrue(model.applied(to: stored).retainSubfloorInUnloadedRegions)
    }

    /// ★ IT CAN NEVER AUTHOR A JOB CORE REFUSES. `grade_lattice` THROWS on "fit"
    /// alongside retention — two mechanisms deciding the same material, two receipts
    /// — so the wizard drops it exactly as `LatticeAutoPosture` does.
    func testFitDropsRetentionRatherThanEmittingAJobCoreThrowsOn() {
        var stored = LatticeSettings(enabled: true)
        stored.densityMode = .sim
        var model = LatticeWizardModel(settings: stored)
        model.retainSubfloor = true

        model.cellSizeMode = .swept
        XCTAssertTrue(model.applied(to: stored).retainSubfloorInUnloadedRegions,
                      "positive control: swept carries it")

        model.cellSizeMode = .fit
        let out = model.applied(to: stored)
        XCTAssertFalse(out.retainSubfloorInUnloadedRegions,
                       "★ core throws on fit + retention; the page must not emit it")
        XCTAssertFalse(out.subfloorPerRegion, "the dependents go with it")
        XCTAssertNil(out.subfloorStressFraction)
    }

    /// ★ AND THE GATE THE ROW DRAWS IS THE SAME GATE THE RESULTS PAGE DRAWS — one
    /// switch in two places must not grow two sets of rules about when it may be
    /// operated, nor two explanations of what it does.
    func testTheWizardsGateIsTheSharedOne() {
        func control(graded: Bool, cell: LatticeCellSizeMode) -> LatticeRetentionControl {
            LatticeRetentionControl.compute(
                armed: false, graded: graded,
                capability: LatticeRetentionCapability.fromCore,
                belowFloorVoxels: nil, regionVoxels: nil, ceilingFraction: nil,
                coreCeilingFraction: LatticeRetentionCapability.coreStressFractionDefault,
                cellMode: cell)
        }
        let uniform = control(graded: false, cell: .swept)
        XCTAssertFalse(uniform.enabled)
        XCTAssertNotNil(uniform.disabledReason,
                        "★ greying a row in silence teaches the user nothing")

        let fit = control(graded: true, cell: .fit)
        XCTAssertFalse(fit.enabled)
        XCTAssertTrue(fit.disabledReason?.contains("Per region") == true,
                      "the copy must name WHICH to use when: \(fit.disabledReason ?? "nil")")

        // His own configuration from the screenshot: Density Sim, Cell size Swept.
        let his = control(graded: true, cell: .swept)
        XCTAssertTrue(his.enabled, "★ Swept + Sim must be operable — that is what he "
                      + "had on screen when he could not find the switch")
        XCTAssertNil(his.disabledReason)
        XCTAssertEqual(his.title, LatticeRetentionControl.titleText)
        XCTAssertFalse(his.body.isEmpty, "the row must say what turning it on does")
    }
}
