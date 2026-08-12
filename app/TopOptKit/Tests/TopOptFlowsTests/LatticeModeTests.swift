// LatticeModeTests — headless proof of the lattice-mode bars (handoff
// 2026-07-29-lattice-mode-ui). Covers the parts that are pure/logic-testable without a
// device: the controls are bounded by CORE at runtime with reasons (U2), LATTICE OFF is
// byte-identical (U1), settings + report round-trip (U3), and the edit slice carries the
// lattice for undo (U4). The SwiftUI panel/gizmo layout (U5/U6) and the device screenshot
// (U7) are the maintainer's on-device QA, per the /app/ rule.

import XCTest
import Foundation
import simd
import TopOptKit
@testable import TopOptFlows

@MainActor
final class LatticeModeTests: XCTestCase {

    // MARK: U2 — every bound comes from CORE at runtime, and says why

    func testCertifiableBandComesFromCore() {
        // The band the controls clamp to must equal core's own numbers, not app copies.
        let core = TopOptKit.latticeLimits(topology: "octet")
        XCTAssertTrue(core.certifiable)
        XCTAssertGreaterThan(core.rhoMin, 0)
        XCTAssertGreaterThan(core.rhoMax, core.rhoMin)

        var s = LatticeSettings(enabled: true, topologyID: "octet")
        // Ask for a range WIDER than the band on both ends.
        s.minRelativeDensity = 0.0
        s.maxRelativeDensity = 1.0
        let b = LatticeBounds.compute(settings: s, limits: core)
        XCTAssertEqual(b.densityLo, core.rhoMin, accuracy: 1e-9, "low end clamps to the core band")
        XCTAssertEqual(b.densityHi, core.rhoMax, accuracy: 1e-9, "high end clamps to the core band")
        XCTAssertEqual(b.bandLo, core.rhoMin, accuracy: 1e-9)
        XCTAssertEqual(b.bandHi, core.rhoMax, accuracy: 1e-9)
    }

    func testClampsSayWhy() {
        let core = TopOptKit.latticeLimits(topology: "octet")
        var s = LatticeSettings(enabled: true, topologyID: "octet")
        s.minRelativeDensity = 0.0            // below the band
        s.maxRelativeDensity = 0.99           // above the band
        let b = LatticeBounds.compute(settings: s, limits: core)
        XCTAssertNotNil(b.densityLoReason, "a clamped low end must state the reason")
        XCTAssertNotNil(b.densityHiReason, "a clamped high end must state the reason")
        XCTAssertTrue(b.densityLoReason!.lowercased().contains("certifiable"))
        XCTAssertTrue(b.densityHiReason!.lowercased().contains("certifiable"))

        // A range already inside the band pins nothing (no gratuitous reason).
        s.minRelativeDensity = core.rhoMin + 0.02
        s.maxRelativeDensity = core.rhoMax - 0.02
        let inside = LatticeBounds.compute(settings: s, limits: core)
        XCTAssertNil(inside.densityLoReason)
        XCTAssertNil(inside.densityHiReason)
    }

    func testNonCertifiableTopologyIsPreviewOnlyWithReason() {
        // A topology the core certification library does NOT cover: certifiable == false,
        // no runnable spec, and the UI is handed a reason. (This used "bcc" when core
        // certified octet only; tensor-library-nine made the seven cubic topologies
        // certifiable, so the genuinely non-certifiable tetragonal bccz carries the
        // same intent now — the assertion itself is unchanged.)
        let limits = TopOptKit.latticeLimits(topology: "bccz")
        XCTAssertFalse(limits.certifiable, "bccz is tetragonal — generate-but-not-certify")
        let s = LatticeSettings(enabled: true, topologyID: "bccz")
        let b = LatticeBounds.compute(settings: s, limits: limits)
        XCTAssertFalse(b.certifiable)
        XCTAssertFalse(b.runnableAsCertified)
        XCTAssertNotNil(b.topologyReason)
        XCTAssertTrue(b.topologyReason!.lowercased().contains("preview"))
    }

    func testCellsPerMemberCeilingComesFromCoreAndEngages() {
        // The bridge FORWARDS core's own scale-separation floor
        // (topopt::lattice_cells_per_member_min — the stub that returned 0 with a
        // stale "core exposes no accessor" claim is fixed, handoff 2026-07-30-
        // lattice-page). The clamp machinery this test always exercised (via the
        // simulated future value below) now ALSO engages on the live number.
        let core = TopOptKit.latticeLimits(topology: "octet")
        XCTAssertGreaterThan(core.minCellsPerMember, 0,
                             "core certifies a cells-per-member floor — forwarded, not invented")
        var s = LatticeSettings(enabled: true, topologyID: "octet")
        s.cellMM = 16
        let b = LatticeBounds.compute(settings: s, limits: core, memberMM: 9.4)
        XCTAssertNotNil(b.cellCeilingMM, "a real core ceiling → a hard ceiling")
        XCTAssertEqual(b.cellCeilingMM ?? 0, 9.4 / core.minCellsPerMember, accuracy: 1e-9,
                       "ceiling = member width / core's floor")
        XCTAssertTrue(b.cellOverCeiling, "a 16 mm cell over a 9.4 mm member breaches it")
        XCTAssertNotNil(b.cellReason)
        XCTAssertGreaterThan(b.cellsAcrossMember, 0)

        // Simulate a FUTURE core that certifies a ceiling: the same math then clamps + names it.
        let future = TopOptKit.LatticeLimits(rhoMin: core.rhoMin, rhoMax: core.rhoMax,
                                             certifiable: true, minCellsPerMember: 3)
        let fb = LatticeBounds.compute(settings: s, limits: future, memberMM: 9.4)
        XCTAssertNotNil(fb.cellCeilingMM)
        XCTAssertTrue(fb.cellOverCeiling, "16mm cell over a 9.4mm member at 3 cells/member is too coarse")
        XCTAssertFalse(fb.runnableAsCertified, "a real cell-ceiling breach blocks a certified run")
        XCTAssertTrue(fb.cellReason!.lowercased().contains("member"))
    }

    func testNoHardcodedCertifiableBandLiteralsInControlSources() throws {
        // U2 grep, as a test: the files that DEFINE the controls must contain none of the
        // certifiable-band numbers — they must be read from core. (The proxy's own preview
        // defaults are a different concern; these are the control BOUNDS.)
        let sources = Self.sourcesDir()
        // The lattice page replaced LatticeControlsPanel (handoff 2026-07-30-lattice-
        // page); every file that defines lattice controls is scanned.
        let files = ["LatticeSettings.swift", "LatticePage.swift", "LatticePageModel.swift"]
        let forbidden = ["0.148", "0.14764", "0.591", "0.59093", "0.15", "0.62"]
        for f in files {
            let text = try String(contentsOf: sources.appendingPathComponent(f), encoding: .utf8)
            for lit in forbidden {
                XCTAssertFalse(text.contains(lit),
                               "\(f) hardcodes band literal \(lit) — read it from core instead")
            }
        }
    }

    // MARK: U1 — LATTICE OFF is byte-identical

    func testLatticeOffProducesNoLatticeKey() throws {
        let job = try jobDict(lattice: nil)
        XCTAssertNil(job["lattice"], "a non-lattice run adds no lattice key")
    }

    func testLatticeOnAddsOnlyTheLatticeBlock() throws {
        let base = try jobDict(lattice: nil)
        let spec = LatticeSpec(topologyID: "octet", cellMM: 8, strutRadiusMM: 1.2,
                               generateRelativeDensity: 0.5, minRelativeDensity: 0.2,
                               maxRelativeDensity: 0.5)
        var withLattice = try jobDict(lattice: spec)
        let block = try XCTUnwrap(withLattice["lattice"] as? [String: Any])
        XCTAssertEqual(block["topology"] as? String, "octet")
        XCTAssertEqual(block["cell_mm"] as? Double, 8)
        XCTAssertEqual(block["strut_radius_mm"] as? Double, 1.2)
        XCTAssertEqual(block["emit_stl"] as? Bool, true)
        XCTAssertEqual(block["emit_3mf"] as? Bool, false)
        // Removing the lattice block leaves a job byte-identical to the lattice-off one.
        withLattice.removeValue(forKey: "lattice")
        XCTAssertTrue(NSDictionary(dictionary: withLattice).isEqual(to: base),
                      "the ONLY difference vs a non-lattice job is the lattice block (U1)")
    }

    func testRunSpecGating() throws {
        // Disabled → nil.
        var s = LatticeSettings(enabled: false, topologyID: "octet")
        XCTAssertNil(s.runSpec())
        // Enabled, certifiable octet → a spec whose radius is the grading law at the dense end.
        s.enabled = true
        // ★ STATED, not inherited. Task 2026-08-12 §4b moved the DENSITY
        // default to `.auto`, and an auto spec needs a strut line width
        // (core's grading floor) that these fixtures do not supply. This
        // test is about the UNIFORM run spec — it asserts
        // `generateRelativeDensity` and `strutRadiusMM`, which only a uniform
        // spec carries, not about which density mode is default —
        // so it names the mode it means. The new default's own end-to-end
        // coverage is `LatticeWizardTests
        // .testTheNewDefaultPostureEmitsALatticeBlockWithItsRegions`.
        s.densityMode = .uniform
        let core = TopOptKit.latticeLimits(topology: "octet")
        s.minRelativeDensity = 0.0; s.maxRelativeDensity = 1.0
        let spec = try XCTUnwrap(s.runSpec(), "an enabled certifiable octet run has a spec")
        XCTAssertEqual(spec.generateRelativeDensity, core.rhoMax, accuracy: 1e-9,
                       "the uniform build fills at the clamped dense end")
        let expected = LatticeType.octet.strutRadiusMM(relativeDensity: core.rhoMax, cellMM: s.cellMM)
        XCTAssertEqual(spec.strutRadiusMM, expected, accuracy: 1e-9)
        // Enabled but a topology the GENERATOR can't emit → nil (bcc now certifies,
        // but core's LatticeGenTopology is octet-only — the B0 generatable gate).
        s.topologyID = "bcc"
        XCTAssertNil(s.runSpec())
        // And a topology that certifies nothing at all → nil too.
        s.topologyID = "bccz"
        XCTAssertNil(s.runSpec())
    }

    // MARK: U3 — settings + report round-trip

    func testSettingsRoundTripThroughSnapshot() throws {
        let region = ManualPrimitive.defaultBolt(at: SIMD3(1, 2, 3), radiusMM: 4, halfLengthMM: 8)
        let s = LatticeSettings(enabled: true, topologyID: "octet", cellMM: 10,
                                minRelativeDensity: 0.2, maxRelativeDensity: 0.5, region: region)
        let snap = ProjectSnapshot(id: UUID(), name: "p", material: "PLA", process: .fdm,
                                   modelFileName: "model.stl", originalFileName: "p.stl",
                                   savedAt: Date(timeIntervalSince1970: 0),
                                   selection: SelectionModel(), force: ForceModel(),
                                   lattice: s)
        let data = try JSONEncoder().encode(snap)
        let back = try JSONDecoder().decode(ProjectSnapshot.self, from: data)
        XCTAssertEqual(back.lattice, s)
    }

    func testPreLatticeSnapshotStillDecodes() throws {
        // A project.json written before this field (no "lattice" key) must decode, with the
        // lattice treated as default-off (byte-identical persistence for non-lattice projects).
        let snap = ProjectSnapshot(id: UUID(), name: "p", material: "PLA", process: .fdm,
                                   modelFileName: "model.stl", originalFileName: "p.stl",
                                   savedAt: Date(timeIntervalSince1970: 0),
                                   selection: SelectionModel(), force: ForceModel())
        XCTAssertNil(snap.lattice)
        let data = try JSONEncoder().encode(snap)
        let back = try JSONDecoder().decode(ProjectSnapshot.self, from: data)
        XCTAssertNil(back.lattice)
    }

    func testLatticeReportRoundTripThroughOutcomeStore() throws {
        let report = LatticeReport(
            topologyID: "octet", cellMM: 8, generateRelativeDensity: 0.5,
            minRelativeDensity: 0.2, maxRelativeDensity: 0.5, regionScoped: true,
            generated: .init(emitSTL: true, emit3MF: false, latticedCells: 1234,
                             regionVoxels: 5678, triangles: 987654,
                             strutRadiusMinMM: 0.8, strutRadiusMaxMM: 1.4))
        let o = OptimizeOutcome(variants: [], stoppedOnMargin: false, cancelled: false,
                                acceptedCount: 0, latticeReport: report)
        let back = try OutcomeCodec.decode(try OutcomeCodec.encode(OutcomeCodec.dto(from: o)))
        XCTAssertEqual(back.latticeReport, report)

        // Honest notes name what the run WAS and generated.
        let notes = ResultsModel.latticeNotes(back.latticeReport)
        XCTAssertEqual(notes.count, 2)
        XCTAssertTrue(notes[0].contains("Octet"))
        XCTAssertTrue(notes[1].contains("987654"))
    }

    // Strut-strength REPORT (task 2026-07-31-lattice-strut-strength-report): the
    // two margins survive the persist round-trip and surface SEPARATELY — never
    // collapsed to one number (which one binds is the point) — with the
    // unsourced-knockdown and out-of-regime caveats attached.
    func testStrutStrengthReportRoundTripAndSeparateNotes() throws {
        let report = LatticeReport(
            topologyID: "octet", cellMM: 4, generateRelativeDensity: 0.32,
            minRelativeDensity: 0.2, maxRelativeDensity: 0.5, regionScoped: false,
            strut: .init(marginInPlane: 0.6164, marginInterlayer: 0.3936,
                         zKnockdown: 0.55, minCellsPerMember: 1.5,
                         outOfRegime: true))
        let o = OptimizeOutcome(variants: [], stoppedOnMargin: false, cancelled: false,
                                acceptedCount: 0, latticeReport: report)
        let back = try OutcomeCodec.decode(try OutcomeCodec.encode(OutcomeCodec.dto(from: o)))
        XCTAssertEqual(back.latticeReport, report)

        let notes = ResultsModel.latticeNotes(back.latticeReport)
        // Base line + missing-export line + strut line + out-of-regime line.
        let strutLines = notes.filter { $0.contains("Strut strength") }
        XCTAssertEqual(strutLines.count, 1)
        XCTAssertTrue(strutLines[0].contains("in-plane margin 0.62"))
        XCTAssertTrue(strutLines[0].contains("interlayer margin 0.39"))
        XCTAssertTrue(strutLines[0].contains("unsourced"))
        XCTAssertTrue(notes.contains { $0.contains("Out of regime") && $0.contains("1.5 cells") })

        // An unbounded margin (an unloaded failure mode) round-trips as +inf and
        // renders honestly, not as a fake number.
        let unbounded = LatticeReport(
            topologyID: "octet", cellMM: 4, generateRelativeDensity: 0.32,
            minRelativeDensity: 0.2, maxRelativeDensity: 0.5, regionScoped: false,
            strut: .init(marginInPlane: 2.0, marginInterlayer: .infinity,
                         zKnockdown: 0.55, minCellsPerMember: 6.0,
                         outOfRegime: false))
        let o2 = OptimizeOutcome(variants: [], stoppedOnMargin: false, cancelled: false,
                                 acceptedCount: 0, latticeReport: unbounded)
        let back2 = try OutcomeCodec.decode(try OutcomeCodec.encode(OutcomeCodec.dto(from: o2)))
        XCTAssertEqual(back2.latticeReport, unbounded)
        let notes2 = ResultsModel.latticeNotes(back2.latticeReport)
        XCTAssertTrue(notes2.contains { $0.contains("interlayer margin unbounded") })
        XCTAssertFalse(notes2.contains { $0.contains("Out of regime") })
    }

    // Task 2026-08-04-variant-volume-fraction-mismatch, bars B3/B4/B6 — the app
    // half of "no silent degenerate output", for records already on disk.
    func testARunThatLatticedNothingIsNotSummarisedAsALattice() {
        // The maintainer's own numbers: worker run 4dabe3b8512d4d59 reported 132
        // cells at radii 0.00-0.65 mm with strut margins of 530.39 / 317.00 —
        // margins computed on a rung that had no material in it at all. Here the
        // degenerate case is the whole record.
        let report = LatticeReport(
            topologyID: "octet", cellMM: 8, generateRelativeDensity: 0,
            minRelativeDensity: 0.05, maxRelativeDensity: 0.9,
            regionScoped: false,
            generated: .init(emitSTL: true, emit3MF: false, latticedCells: 0,
                             regionVoxels: 284379, triangles: 134116,
                             strutRadiusMinMM: 0, strutRadiusMaxMM: 0),
            strut: .init(marginInPlane: 530.39, marginInterlayer: 317.00,
                         zKnockdown: 0.55, minCellsPerMember: 0.4,
                         outOfRegime: true))
        let notes = ResultsModel.latticeNotes(report)
        XCTAssertTrue(notes.contains { $0.contains("NO LATTICE WAS PRODUCED") },
                      "B3: a run with zero latticed cells is not summarised as a "
                      + "successful lattice")
        XCTAssertFalse(notes.contains { $0.contains("filled at 0% density") },
                       "B3: and the 0% density line — which read as a fact about "
                       + "the fill rather than an absence of one — is gone")
        XCTAssertFalse(notes.contains { $0.contains("Strut strength") },
                       "B4: strut margins computed on no material are withheld, "
                       + "not printed beside a lattice that does not exist")
    }

    // B6: the two region cases read differently, because they ARE different.
    func testTheRegionScopeLineSaysWhichOfTheTwoCasesHappened() {
        func notes(regionScoped: Bool, emitted: Int) -> [String] {
            ResultsModel.latticeNotes(LatticeReport(
                topologyID: "octet", cellMM: 8, generateRelativeDensity: 0.3,
                minRelativeDensity: 0.05, maxRelativeDensity: 0.9,
                regionScoped: regionScoped, emittedRegions: emitted,
                generated: .init(emitSTL: true, emit3MF: false,
                                 latticedCells: 1234, regionVoxels: 5678,
                                 triangles: 987654, strutRadiusMinMM: 0.8,
                                 strutRadiusMaxMM: 1.4)))
        }
        XCTAssertTrue(notes(regionScoped: true, emitted: 2)[0]
                        .contains("Region-scoped, as previewed"),
                      "B6: regions that travelled with the job DID scope the build")
        XCTAssertTrue(notes(regionScoped: true, emitted: 0)[0]
                        .contains("no region travelled with the job"),
                      "B6: only a preview-only region leaves the build unscoped — "
                      + "the old copy claimed that unconditionally")
        XCTAssertFalse(notes(regionScoped: false, emitted: 0)[0]
                        .contains("Region"),
                      "B6: and a run with no regions at all says nothing about them")
    }

    func testPreLatticeOutcomeBlobDecodes() throws {
        // An outcome without a lattice report round-trips to nil (no lattice notes).
        let o = OptimizeOutcome(variants: [], stoppedOnMargin: false, cancelled: false, acceptedCount: 0)
        let back = try OutcomeCodec.decode(try OutcomeCodec.encode(OutcomeCodec.dto(from: o)))
        XCTAssertNil(back.latticeReport)
        XCTAssertTrue(ResultsModel.latticeNotes(back.latticeReport).isEmpty)
    }

    // MARK: U4 — the lattice rides the existing undo slice

    func testLatticeIsInTheUndoSlice() {
        let off = EditSnapshot(selection: SelectionModel(), force: ForceModel(),
                               designBox: DesignBoxModel(), lattice: LatticeSettings())
        var onSettings = LatticeSettings(); onSettings.enabled = true; onSettings.cellMM = 12
        let on = EditSnapshot(selection: SelectionModel(), force: ForceModel(),
                              designBox: DesignBoxModel(), lattice: onSettings)
        XCTAssertNotEqual(off, on, "a lattice change makes a distinct undo slice")

        var h = UndoHistory()
        h.reset(to: off)
        XCTAssertTrue(h.commit(on), "a lattice edit is a real undo step")
        XCTAssertEqual(h.undo(), off, "undo restores the pre-lattice slice")
        XCTAssertEqual(h.redo(), on, "redo re-applies the lattice edit")
    }

    // MARK: region reuses the manual-primitive value type (task requirement 2)

    func testRegionMemberWidthFromPrimitive() {
        var s = LatticeSettings(enabled: true, topologyID: "octet")
        XCTAssertNil(s.regionMemberMM, "no region → no faked member width (whole part)")
        s.region = ManualPrimitive.defaultBolt(at: .zero, radiusMM: 3, halfLengthMM: 10)
        XCTAssertEqual(s.regionMemberMM ?? 0, 6, accuracy: 1e-9, "a bolt region's member ≈ its diameter")
    }

    // MARK: helpers

    private func jobDict(lattice: LatticeSpec?) throws -> [String: Any] {
        let req = RunRequest(
            modelPath: "/tmp/part.stl", material: "PLA", materialsPath: "", rulesPath: "",
            resolution: 96, projectName: "lattice", anchorFaceIDs: [3], loadGroups: [],
            minimizePlastic: true, buildDirection: SIMD3(0, 0, 1), infillPercent: 40,
            clearances: [], faceProtections: [], faceProtectionDepthMM: -1, lattice: lattice)
        let cfg = RemoteRunnerConfig(host: "127.0.0.1", port: 8757, expectedFingerprint: "test")
        let run = RemoteRun(config: cfg, request: req, progress: { _, _, _ in true }, onVariant: { _ in })
        return try XCTUnwrap(JSONSerialization.jsonObject(with: try run.buildJobJSON()) as? [String: Any])
    }

    /// The Sources/TopOptFlows directory, derived from this test file's path.
    private static func sourcesDir() -> URL {
        URL(fileURLWithPath: #filePath)                 // …/Tests/TopOptFlowsTests/LatticeModeTests.swift
            .deletingLastPathComponent()                // …/Tests/TopOptFlowsTests
            .deletingLastPathComponent()                // …/Tests
            .deletingLastPathComponent()                // …/TopOptKit
            .appendingPathComponent("Sources/TopOptFlows")
    }
}
