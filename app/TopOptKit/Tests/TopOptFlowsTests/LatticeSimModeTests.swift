// LatticeSimModeTests.swift — ★ THE SIM PROCESS (maintainer, 2026-08-17).
//
// ★ HIS SPEC: "Add a dark glass on/off check with a 'Simulate Stresses' at the
// top of the 'Lattice Settings' modal (above the 'type') … The idea is that if
// the SIM option is selected, you can offer any variable for the AI to use, but
// can set some values yourself and keep them hard coded."
//
// ★ AND THE RENAME HE ASKED FOR, CONDITIONALLY: "If Density's 'auto' is meant to
// be 'Sim' I think it should change names. However, if there is a way to
// automate *without* using an FEA sim, then keep the 'Auto'." There is no such
// way — `gradingDictionary()` returns nil unless this mode is on, and core's
// grading law is a map from a per-voxel demand field — so the name changed.

import XCTest
import TopOptKit
@testable import TopOptFlows

final class LatticeDensityModeRenameTests: XCTestCase {

    /// ★★ EVERY PROJECT ON DISK SAYS "auto" AND MUST KEEP OPENING. The rename is
    /// a LABEL change, not a data migration: the mode is the one it always was.
    func testAStoredAutoStillDecodesAsSim() throws {
        let m = try JSONDecoder().decode(LatticeDensityMode.self,
                                         from: Data("\"auto\"".utf8))
        XCTAssertEqual(m, .sim, "★ an old project opens, unchanged in meaning")
    }

    /// The new spelling decodes too, and the other modes are untouched.
    func testTheNewSpellingAndTheOtherModesRoundTrip() throws {
        for (raw, want) in [("sim", LatticeDensityMode.sim),
                            ("uniform", .uniform),
                            ("perRegion", .perRegion)] {
            XCTAssertEqual(try JSONDecoder().decode(LatticeDensityMode.self,
                                                    from: Data("\"\(raw)\"".utf8)),
                           want)
        }
    }

    /// ★ AND A GENUINELY UNKNOWN MODE STILL THROWS. The back-compat branch is one
    /// named alias, not a blanket "anything I don't recognise is Sim" — that
    /// would turn a corrupt project into a silently wrong one.
    func testAnUnknownModeIsStillRefused() {
        XCTAssertThrowsError(try JSONDecoder().decode(
            LatticeDensityMode.self, from: Data("\"telepathy\"".utf8)))
    }

    /// Encoding writes the NEW word, so a project re-saved once stops carrying
    /// the old one — but nothing forces that, and nothing needs to.
    func testItEncodesTheNewSpelling() throws {
        let d = try JSONEncoder().encode(LatticeDensityMode.sim)
        XCTAssertEqual(String(decoding: d, as: UTF8.self), "\"sim\"")
    }

    /// ★ THE LABEL SAYS WHAT THE MECHANISM IS. "Auto" described the interaction
    /// ("I don't type a number") and hid the mechanism ("a finite-element solve
    /// decides it") — the half that matters when deciding whether to trust it.
    func testTheTitleSaysSim() {
        XCTAssertEqual(LatticeDensityMode.sim.title, "Sim")
        XCTAssertEqual(LatticeDensityMode.uniform.title, "Uniform")
        XCTAssertEqual(LatticeDensityMode.perRegion.title, "Per region")
    }

    /// ★ ONE PROPERTY ANSWERS "does this need a solve?", so the settings sheet,
    /// the solve trigger and the preview cannot each decide it differently.
    func testOnlySimNeedsASolve() {
        XCTAssertTrue(LatticeDensityMode.sim.needsSimulation)
        XCTAssertFalse(LatticeDensityMode.uniform.needsSimulation)
        XCTAssertFalse(LatticeDensityMode.perRegion.needsSimulation)
    }
}

// ─────────────────────────────────────────────────────────────────────────
// MARK: ★ THE "SIMULATE STRESSES" PERMISSION

final class LatticeSimPermissionTests: XCTestCase {

    /// ★ IT IS A PERMISSION, NOT A MODE. It does not say "grade everything by
    /// stress"; it says "a solve may decide the axes I left to it". Each axis
    /// still chooses for itself — his "set some values yourself and keep them
    /// hard coded" — and this is what makes Sim available to any of them.
    func testTheSwitchIsOnByDefaultBecauseTheGradedModeAlwaysWas() {
        let s = LatticeSettings(enabled: true)
        XCTAssertTrue(s.simulateStresses,
                      "★ a false default would silently change every existing "
                      + "project's lattice — the graded density mode has been "
                      + "the default since it shipped")
        XCTAssertEqual(s.densityMode, .sim)
        XCTAssertTrue(s.needsStressSolve)
    }

    /// ★ TURNING IT OFF MOVES EVERY SIM AXIS to its nearest manual equivalent,
    /// rather than leaving a mode the job cannot honestly express.
    func testTurningItOffMigratesEverySimAxis() {
        var s = LatticeSettings(enabled: true)
        s.cellSizeMode = .swept
        s.setSimulateStresses(false)
        XCTAssertFalse(s.simulateStresses)
        XCTAssertEqual(s.densityMode, .uniform,
                       "★ a field-graded density has no meaning without a field")
        XCTAssertEqual(s.cellSizeMode, .fixed,
                       "★ swept IS the stress-graded cell ladder")
        XCTAssertFalse(s.needsStressSolve)
    }

    /// ★ AN AXIS THE USER PINNED BY HAND IS LEFT ALONE — the switch only moves
    /// what it is responsible for.
    func testItLeavesManualAxesExactlyWhereTheyWere() {
        var s = LatticeSettings(enabled: true)
        s.densityMode = .perRegion
        s.cellSizeMode = .fit
        s.setSimulateStresses(false)
        XCTAssertEqual(s.densityMode, .perRegion, "★ untouched")
        XCTAssertEqual(s.cellSizeMode, .fit, "★ untouched")
    }

    /// ★★ THE SWITCH ON WITH EVERY AXIS PINNED NEEDS NO SOLVE. That is a
    /// legitimate state — his "offer any variable for the AI to use, but can set
    /// some values yourself" taken to its limit — and running an FEA nothing
    /// would read would be a cost with no consumer.
    func testPermissionWithoutATakerNeedsNoSolve() {
        var s = LatticeSettings(enabled: true)
        s.densityMode = .uniform
        s.cellSizeMode = .fixed
        XCTAssertTrue(s.simulateStresses, "★ the permission stands…")
        XCTAssertFalse(s.needsStressSolve, "★ …but nothing is asking for it")
    }

    /// Either axis alone is enough to need the solve.
    func testEitherAxisAloneCallsForTheSolve() {
        var byDensity = LatticeSettings(enabled: true)
        byDensity.cellSizeMode = .fixed
        XCTAssertTrue(byDensity.needsStressSolve)

        var byCell = LatticeSettings(enabled: true)
        byCell.densityMode = .uniform
        byCell.cellSizeMode = .swept
        XCTAssertTrue(byCell.needsStressSolve)
    }

    /// ★ AN OLDER SNAPSHOT PREDATES THE SWITCH and must keep the solve it has
    /// always had. Absent ⇒ true.
    func testASnapshotWithoutTheKeyDecodesAsPermitted() throws {
        let json = Data("""
        {"enabled":true,"topologyID":"octet","densityMode":"auto"}
        """.utf8)
        let s = try JSONDecoder().decode(LatticeSettings.self, from: json)
        XCTAssertTrue(s.simulateStresses)
        XCTAssertEqual(s.densityMode, .sim, "★ and the old mode name still opens")
    }

    /// A round trip through OFF and back ON leaves a usable state — the reason
    /// the flag is stored rather than derived from the modes.
    func testItSurvivesARoundTripThroughOff() {
        var s = LatticeSettings(enabled: true)
        s.setSimulateStresses(false)
        s.setSimulateStresses(true)
        XCTAssertTrue(s.simulateStresses)
    }
}

// ─────────────────────────────────────────────────────────────────────────
// MARK: ★ THE PERMISSION REACHES THE WIZARD, AND THE PREVIEW READS THE JOB'S γ

@MainActor
final class LatticeSimWizardTests: XCTestCase {

    /// ★ THE WIZARD BORROWS THE SETTINGS' OWN MIGRATION RULE rather than writing
    /// a second one. Two copies of one rule is exactly how this page ended up
    /// with two depth resolvers and two strut laws.
    func testTheWizardsSwitchMigratesThroughTheSettingsRule() {
        var m = LatticeWizardModel()
        m.cellSizeMode = .swept
        m.setSimulateStresses(false)
        XCTAssertFalse(m.simulateStresses)
        XCTAssertEqual(m.densityMode, .uniform)
        XCTAssertEqual(m.cellSizeMode, .fixed)
        XCTAssertFalse(m.needsStressSolve)
    }

    /// ★ IT ROUND-TRIPS THROUGH THE PROJECT. A switch the sheet shows but never
    /// saves is the decorative-control defect; `applied(to:)` is what makes it
    /// a setting.
    func testItSurvivesTheRoundTripThroughLatticeSettings() {
        var s = LatticeSettings(enabled: true)
        s.setSimulateStresses(false)
        let m = LatticeWizardModel(settings: s)
        XCTAssertFalse(m.simulateStresses, "★ the sheet opens on what is stored")
        XCTAssertFalse(m.applied(to: s).simulateStresses,
                       "★ …and hands it back unchanged")

        var on = LatticeWizardModel(settings: s)
        on.setSimulateStresses(true)
        XCTAssertTrue(on.applied(to: s).simulateStresses)
    }

    /// ★★ THE PREVIEW READS THE JOB'S OWN EXPONENT, not a hardcoded 1
    /// (maintainer: "Please use all variables as part of the preview to have as
    /// accurate a preview as possible").
    ///
    /// Core's grading law is `rho = rho_hi · (demand/demand_max)^gamma`. The
    /// preview pinned gamma at 1 — honest while nothing could set it, and wrong
    /// the moment anything could.
    func testThePreviewProxyCarriesTheDemandExponent() {
        var s = LatticeSettings(enabled: true)
        s.demandExponent = 0.5
        let p = s.proxyParams(limits: TopOptKit.latticeLimits(topology: s.topologyID))
        XCTAssertEqual(p.gamma, 0.5, accuracy: 1e-12,
                       "★ the preview grades by the number the job carries")
    }

    /// The default is core's own default, so an untouched project's preview is
    /// bit-identical to what it drew before the field existed.
    func testTheDefaultExponentIsCoresOwn() {
        let s = LatticeSettings(enabled: true)
        XCTAssertEqual(s.demandExponent, 1, accuracy: 1e-12)
        let p = s.proxyParams(limits: TopOptKit.latticeLimits(topology: s.topologyID))
        XCTAssertEqual(p.gamma, 1, accuracy: 1e-12)
    }
}
