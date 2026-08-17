// DensityModeAndSweptTests.swift — task 2026-08-15-lattice-and-face-ui §8 / §9.
//
//   R10  ★ THREE DENSITY MODES, AUTO DEFAULT, "PER REGION" REVEALS THE DRAWER
//        ROW. The other two modes leave the drawer byte-identical.
//   R11  ★ THE SWEPT WINDOW REACHES THE JOB, and a window that cannot sweep says
//        so BEFORE the run.

import XCTest
import TopOptKit
@testable import TopOptFlows

final class DensityModeAndSweptTests: XCTestCase {

    // ─────────────────────────────────────────────────────────────────────
    // MARK: §8 — three modes, and "Swept" is not one of them

    /// ★ §8 — THREE, NOT FOUR. And "SWEPT" IS NOT ONE OF THEM: it belongs to
    /// CELL SIZE and only to cell size.
    func testThereAreExactlyThreeDensityModes() {
        XCTAssertEqual(Set(["uniform", "auto", "perRegion"]),
                       Set([LatticeDensityMode.uniform, .auto, .perRegion]
                            .map(\.rawValue)))
        XCTAssertNil(LatticeDensityMode(rawValue: "swept"),
                     "§8(a): there is no swept DENSITY mode — swept is a cell-size "
                   + "mode and nothing else")
    }

    /// ★ §8(b) — AUTO REMAINS THE DEFAULT and must never produce a refusal.
    func testAutoIsTheDefaultOnTheWizard() {
        XCTAssertEqual(LatticeWizardModel().densityMode, .auto)
    }

    // ─────────────────────────────────────────────────────────────────────
    // MARK: §8(c)/(d) — the wiring, and what must NOT move

    private func card() -> LatticeFaceCard {
        LatticeFaceCard(faceID: 1, depthMM: 6, heldVoxels: 900,
                        heldVolumeMM3: 4_000, heldMassG: 5, cellMM: 2,
                        relativeDensity: 0.3, strutDiameterMM: 0.6,
                        cellsPerMember: 6, verdict: .certified)
    }

    /// ★ §8(c) — SELECTING "PER REGION" IS WHAT MAKES PR 334's DRAWER ROW APPEAR.
    /// Two EXACT cases, never relaxed to "one or more" — PR 334's invariant, kept.
    func testPerRegionRevealsTheDensityRowAndNothingElseDoes() {
        for mode in [LatticeDensityMode.auto, .uniform] {
            let d = LatticeRegionDrawer.make(card: card(), depthMM: 6, held: false,
                                             perRegionDensity: mode == .perRegion)
            XCTAssertEqual(d.modifiableRows.map(\.label), ["Depth", "Expand"],
                           "§8(d): \(mode.rawValue) leaves the drawer as PR 331 "
                         + "shipped it — exactly one control")
        }
        let perRegion = LatticeRegionDrawer.make(card: card(), depthMM: 6,
                                                 held: false,
                                                 perRegionDensity: true)
        XCTAssertEqual(perRegion.modifiableRows.map(\.label), ["Depth", "Density", "Expand"],
                       "§8(c): per-region adds the Density control, and only it")
    }

    /// ★ §8(d) — AND THE VALUES DO NOT MOVE. Turning the mode on changes WHICH
    /// rows are controls, never what any of them says.
    func testTheOtherTwoModesLeaveTheDrawerByteIdentical() {
        let plain = LatticeRegionDrawer.make(card: card(), depthMM: 6, held: false)
        let perRegion = LatticeRegionDrawer.make(card: card(), depthMM: 6,
                                                 held: false,
                                                 perRegionDensity: true)
        XCTAssertEqual(plain.rows.map(\.label), perRegion.rows.map(\.label))
        XCTAssertEqual(plain.rows.map(\.value), perRegion.rows.map(\.value))
        XCTAssertEqual(plain.collapsedValue, perRegion.collapsedValue)
        XCTAssertEqual(plain.verdict, perRegion.verdict)
    }

    // ─────────────────────────────────────────────────────────────────────
    // MARK: §9 — the swept window

    /// ★ §9(a) — THE WINDOW REACHES THE PROJECT. The wizard model never carried
    /// `cellMinMM`/`cellMaxMM`, so its "Swept" segment had nothing to show and
    /// `applied(to:)` handed back whatever the project already had. That absence
    /// IS the "no range fields at all" screenshot.
    func testTheWizardCarriesTheSweepWindowBothWays() {
        var s = LatticeSettings()
        s.cellSizeMode = .swept
        s.cellMinMM = 2.0
        s.cellMaxMM = 4.0
        var m = LatticeWizardModel(settings: s)
        XCTAssertEqual(m.cellMinMM, 2.0, "the wizard READS the stored window")
        XCTAssertEqual(m.cellMaxMM, 4.0)

        m.cellMinMM = 1.5
        m.cellMaxMM = 6.0
        let out = m.applied(to: s)
        XCTAssertEqual(out.cellMinMM, 1.5, "and WRITES it back")
        XCTAssertEqual(out.cellMaxMM, 6.0)
    }

    /// ★ §9(b) — A WINDOW THAT CANNOT SWEEP SAYS SO, BEFORE THE RUN.
    ///
    /// `cell_plan_max_level` builds a DYADIC ladder (`min · 2^L`), so a window
    /// narrower than 2× holds exactly one level: every block takes it, and the
    /// receipt returns `distinct_cells: 1` with one strut radius.
    func testANarrowWindowIsWarnedAboutAndATwoTimesWindowIsNot() {
        var m = LatticeWizardModel()
        m.cellSizeMode = .swept

        m.cellMinMM = 2.0; m.cellMaxMM = 3.0
        XCTAssertEqual(m.sweptWindowWarning,
                       "This window holds one cell size. Widen it to 4.0 mm or more to sweep.")

        // ★ HIS OWN WINDOW is exactly 2x, which DOES hold two levels — so the
        // collapse he saw did not come from the window, and this test says so.
        m.cellMinMM = 2.0; m.cellMaxMM = 4.0
        XCTAssertNil(m.sweptWindowWarning,
                     "2.0–4.0 is exactly 2x and holds TWO dyadic levels")
    }

    /// The warning is scoped to the mode it is about.
    func testTheWarningOnlyFiresInSweptMode() {
        var m = LatticeWizardModel()
        m.cellSizeMode = .fixed
        m.cellMinMM = 2.0; m.cellMaxMM = 2.5
        XCTAssertNil(m.sweptWindowWarning)
    }

    /// ★ §9 — AND THE WINDOW REACHES THE JOB. `runSpec` emits `cell_min_mm` /
    /// `cell_max_mm` and NO `cell_mm` in swept mode, so the range the user typed
    /// is the range core plans against.
    func testTheSweptWindowReachesTheJobDocument() throws {
        var s = LatticeSettings()
        s.enabled = true
        s.densityMode = .auto
        s.cellSizeMode = .swept
        s.cellMinMM = 1.5
        s.cellMaxMM = 6.0
        let spec = try XCTUnwrap(s.runSpec(lineWidthMM: 0.45))
        let grading = try XCTUnwrap(spec.gradingDictionary())
        XCTAssertEqual(grading["cell_mode"] as? String, "swept")
        XCTAssertEqual(grading["cell_min_mm"] as? Double, 1.5)
        XCTAssertEqual(grading["cell_max_mm"] as? Double, 6.0)
        XCTAssertNil(grading["cell_mm"],
                     "swept carries a WINDOW, never a scalar cell")
    }

    /// ★★ §9(b) — THE COLLAPSE, PINNED. This is the regression test for the
    /// actual defect.
    ///
    /// `runSpec` clamped BOTH sweep ends up to `LatticeBounds.cellFloorMM` —
    /// core's LIGHT-end printability floor, 4.93 mm on his part. His 2.0 – 4.0 mm
    /// window therefore reached the job as 4.93 – 4.93: min == max, ONE dyadic
    /// level, and the receipt came back `distinct_cells: 1` with
    /// `strut_radius_min_mm == strut_radius_max_mm == 0.225`.
    ///
    /// The floor that belongs here is the DENSE one (`cellFloorDensestMM`,
    /// ~1.17 mm — PR 310), which is the floor `LatticeCellEntry.entryFloorMM`
    /// already bounded TYPED entry by. Two floors, two answers, one silent
    /// overwrite.
    ///
    /// ★ THE ASSERTION IS THAT A WINDOW SURVIVES AS A WINDOW. A test that only
    /// checked the low end would have passed on 4.93 – 4.93.
    func testASweptWindowIsNotFlattenedByTheWrongFloor() throws {
        var s = LatticeSettings()
        s.enabled = true
        s.densityMode = .auto
        s.cellSizeMode = .swept
        s.cellMinMM = 2.0      // ★ his own window
        s.cellMaxMM = 4.0
        let spec = try XCTUnwrap(s.runSpec(lineWidthMM: 0.45))
        let grading = try XCTUnwrap(spec.gradingDictionary())
        let lo = try XCTUnwrap(grading["cell_min_mm"] as? Double)
        let hi = try XCTUnwrap(grading["cell_max_mm"] as? Double)

        XCTAssertEqual(lo, 2.0, accuracy: 1e-9,
                       "§9(b): his 2.0 mm low end must reach the job. It became "
                     + "4.93 — core's LIGHT floor — which is the collapse.")
        XCTAssertEqual(hi, 4.0, accuracy: 1e-9)
        XCTAssertGreaterThanOrEqual(hi / lo, 2.0,
                                    "§9(c): the window must still span at least "
                                  + "one dyadic doubling, or the sweep emits ONE "
                                  + "cell however wide it was typed")
    }

    /// ★ §9(f) — AND WHEN THE CLAMP *DOES* FIRE, IT SAYS SO WITH THE NUMBER.
    /// A window genuinely below the dense floor is still raised — that part is
    /// correct — but never in silence.
    func testAWindowBelowTheDenseFloorIsClampedOutLoud() {
        let bounds = LatticeBounds.compute(
            settings: { var s = LatticeSettings(); s.enabled = true; return s }(),
            limits: TopOptKit.latticeLimits(topology: "octet"),
            generatable: true, memberMM: 0, lineWidthMM: 0.45)
        // Nothing to say when both ends clear the floor.
        XCTAssertNil(LatticeCellEntry.sweptClampNote(minMM: 2.0, maxMM: 4.0, bounds))
        // And a real clamp names the number it clamped to.
        let note = LatticeCellEntry.sweptClampNote(minMM: 0.2, maxMM: 4.0, bounds)
        XCTAssertNotNil(note, "§9(f): a clamp that fires must be on screen")
        XCTAssertTrue(note?.contains("Raised to") == true)
    }
}
