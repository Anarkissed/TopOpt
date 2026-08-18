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
