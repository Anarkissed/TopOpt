// LatticeAutoIsGradedTests — ★★ AUTO MEANS GRADED (maintainer, 2026-08-20: "Auto
// should also mean *GRADED*").
//
// ★ WHAT IT COST HIM BEFORE. Auto resolved to FIT the moment any region was declared
// — always, on his parts. Fit gives each region ONE cell, and core refuses Fit
// alongside sub-floor retention, so choosing Auto silently switched retention off
// before the job was built: his quiet upright could not keep its lattice, and the
// switch could not help him, for a reason nothing on screen stated.

import XCTest
@testable import TopOptFlows
@testable import TopOptKit

final class LatticeAutoIsGradedTests: XCTestCase {

    private func settings() -> LatticeSettings {
        var s = LatticeSettings(enabled: true)
        s.topologyID = "octet"
        s.cellSizeMode = .auto
        s.densityMode = .sim
        return s
    }

    /// ★ AUTO NO LONGER TURNS RETENTION OFF — the regression that made this urgent.
    func testAutoWithRegionsKeepsRetention() {
        var s = settings()
        s.retainSubfloorInUnloadedRegions = true
        let out = LatticeAutoPosture.applied(to: s, includeRegionCount: 2,
                                             regionWidthsMM: [13, 20], lineWidthMM: 0.42)
        XCTAssertEqual(out.cellSizeMode, .swept,
                       "★ Auto is swept-without-typing, which is what graded means")
        XCTAssertTrue(out.retainSubfloorInUnloadedRegions,
                      "★ and it must NOT be dropped — core refuses only fit + retention")
    }

    /// ★ THE WINDOW IS DERIVED FROM CORE, and it must actually be able to sweep.
    func testTheDerivedWindowSpansAtLeastOneDoubling() throws {
        let w = try XCTUnwrap(LatticeAutoPosture.autoWindowMM(
            regionWidthsMM: [13, 20], lineWidthMM: 0.42, topology: "octet"))
        XCTAssertGreaterThan(w.min, 0)
        // ★★ THE FINE END MUST BE FINE ENOUGH FOR THE REGIONS TO HOLD IT. Auto's
        // first version used core's `printabilityFloorMM` (4.6026 mm at this bead),
        // which needs 23 mm of member — so his 13 mm regions got a cell they could
        // not hold and the part graded back to SOLID. Every assertion in this file
        // passed while that was true.
        for width in [13.0, 20.0] {
            let n = TopOptKit.latticeLimits(topology: "octet").minCellsPerMember
            XCTAssertLessThanOrEqual(w.min, width / n,
                                     "★ a \(width) mm region must be able to hold the "
                                     + "FINEST cell Auto sweeps to")
        }
        // The coarse end is Fit's own answer for the widest region: 20 / N*.
        let fit = TopOptKit.latticeRegionDerivation(topology: "octet",
                                                    memberWidthMM: 20,
                                                    minExtrudableWidthMM: 0.42)
        if fit.valid, fit.cellMM > w.min * 2 {
            XCTAssertEqual(w.max, fit.cellMM, accuracy: 1e-9,
                           "★ the ladder's top is the cell Fit would have chosen")
        }
        // ★★ AND THE FINEST RUNG MUST BE A LATTICE, NOT A FILLED WALL. At
        // `bead / phi(rho_max)` the only printable density is the band's ceiling —
        // struts fill the cell and his wall rendered solid. Every rung must leave
        // room to grade BELOW the top of the band.
        let limits = TopOptKit.latticeLimits(topology: "octet")
        let dia = TopOptKit.latticeStrutDiameterMM(topology: "octet",
                                                   relativeDensity: limits.rhoMax,
                                                   cellMM: w.min)
        XCTAssertGreaterThan(dia, 0.42,
                             "★ at the finest rung the band's TOP must print with "
                             + "room to spare — a cell whose only legal lattice is "
                             + "the densest one renders as solid")
        print("AUTO WINDOW \(w.min) – \(w.max) mm  (fit at 20 mm = \(fit.cellMM); "
              + "rho_max strut at the fine rung = \(dia) mm vs 0.42 bead)")
    }

    /// ★ NO BEAD, NO WINDOW — the app must not invent a nozzle.
    func testNoLineWidthMeansNoDerivedWindow() {
        XCTAssertNil(LatticeAutoPosture.autoWindowMM(regionWidthsMM: [13],
                                                     lineWidthMM: 0, topology: "octet"))
        var s = settings()
        s.cellMinMM = 0; s.cellMaxMM = 0
        let out = LatticeAutoPosture.applied(to: s, includeRegionCount: 1,
                                             regionWidthsMM: [13], lineWidthMM: 0)
        XCTAssertEqual(out.cellMinMM, 0, "the window is left alone, not guessed")
    }

    /// ★ AND CHOOSING FIT STILL GIVES FIT — "Manual, fixed and swept remain
    /// available and must not be removed" cuts both ways.
    func testChoosingFitIsStillHonoured() {
        var s = settings()
        s.cellSizeMode = .fit
        let out = LatticeAutoPosture.applied(to: s, includeRegionCount: 2,
                                             regionWidthsMM: [13, 20], lineWidthMM: 0.42)
        XCTAssertEqual(out.cellSizeMode, .fit, "an explicit choice is not overridden")
    }
}
