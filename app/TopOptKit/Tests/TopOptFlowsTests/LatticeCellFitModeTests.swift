// LatticeCellFitModeTests — the device can finally select core's `fit` cell mode,
// and it cannot author the one job core throws on (task
// 2026-08-07-cell-mode-fit-and-swept-floor, S2).
//
// THE DEFECT. `LatticeCellSizeMode` carried auto / fixed / swept. Core has carried
// FOUR since PR 302: `fit` derives the cell PER DECLARED REGION from that region's
// own extent (core/src/cli/run_job.cpp's `fit_region_cells`). It is the mode the
// maintainer has been asking for by describing it — "a thin wall should get a fine
// lattice and a thick member a coarse one" — and it was unreachable from the iPad.
//
// EVERY TEST HERE DRIVES THE REAL SERIALIZER, for the reason the retention tests
// state at length: `RemoteRun.buildJobJSON()` and `RelatticeJobBuilder.build` produce
// the bytes a worker receives, and a test asserting against a dictionary the test
// built itself proves nothing about either. Several of them go one step further and
// hand the result to CORE'S OWN PARSER (`TopOptKit.jobSchemaError`), so the bar is
// "this core will run these bytes", not "these bytes contain the keys I expected".
//
// The capabilities are INJECTED (`.all` / `.none`) so the emission is pinned
// regardless of which core happens to be vendored; the probes themselves are tested
// separately against the core that IS built.

import XCTest
import simd
import TopOptKit
@testable import TopOptFlows

@MainActor
final class LatticeCellFitModeTests: XCTestCase {

    // MARK: - harness: the REAL job-building paths

    private static func request(lattice: LatticeSpec?) -> RunRequest {
        RunRequest(
            modelPath: "/tmp/part.step", material: "PLA", materialsPath: "",
            rulesPath: "", resolution: 64, projectName: "fitmode",
            anchorFaceIDs: [3],
            loadGroups: [TopOptKit.LoadGroupSpec(faceIDs: [11],
                                                force: SIMD3(0, 0, -250))],
            minimizePlastic: true,
            buildDirection: SIMD3(0, 0, 1),
            infillPercent: 40, wallLoops: 3,
            wallLineWidthOuterMM: 0.45, wallLineWidthInnerMM: 0.45,
            lattice: lattice)
    }

    private static func optimizeJobData(lattice: LatticeSpec?) throws -> Data {
        let cfg = RemoteRunnerConfig(host: "127.0.0.1", port: 8757,
                                     expectedFingerprint: "test")
        let run = RemoteRun(config: cfg, request: request(lattice: lattice),
                            progress: { _, _, _ in true }, onVariant: { _ in })
        return try run.buildJobJSON()
    }

    private static func optimizeJob(lattice: LatticeSpec?) throws -> [String: Any] {
        try XCTUnwrap(
            JSONSerialization.jsonObject(with: try optimizeJobData(lattice: lattice))
                as? [String: Any])
    }

    private static func relatticeJob(lattice: LatticeSpec?) throws -> [String: Any] {
        let original = try JSONSerialization.data(
            withJSONObject: try optimizeJob(lattice: nil), options: [.sortedKeys])
        let data = try RelatticeJobBuilder.build(
            original: original, designFingerprint: 0xDEAD_BEEF,
            achievedVolumeFraction: 0.42, designFileName: "design.bin",
            lattice: lattice)
        return try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    /// Settings that produce a GRADED spec — the only kind that carries a cell mode
    /// other than fixed, because core chooses the cell inside the grading pass.
    private static func gradedSettings() -> LatticeSettings {
        var s = LatticeSettings(enabled: true)
        s.densityMode = .sim
        s.minRelativeDensity = 0.2
        s.maxRelativeDensity = 0.5
        return s
    }

    /// ONE declared include region — core REFUSES `cell_mode: "fit"` without one
    /// ("a job that declares none states no requirement to fit"), so a fixture that
    /// omitted it would be testing that rule rather than this task's.
    private static func includeRegion() -> [LatticeRegionSpec] {
        var r = LatticeRegionSpec(role: .include, kind: .bolt)
        r.axisPoint = SIMD3(0, 0, 0)
        r.axisDir = SIMD3(1, 0, 0)
        r.radiusMM = 4
        r.halfLengthMM = 4
        return [r]
    }

    private static func spec(_ s: LatticeSettings,
                             capability: LatticeRetentionCapability = .all,
                             cellModes: LatticeCellModeCapability = .all,
                             regions: [LatticeRegionSpec]? = nil) throws
        -> LatticeSpec {
        try XCTUnwrap(s.runSpec(lineWidthMM: 0.45,
                                regions: regions ?? includeRegion(),
                                capability: capability, cellModes: cellModes),
                      "these settings must produce a runnable graded spec")
    }

    // MARK: - S2a · the mode reaches the job the worker receives

    /// THE HEADLINE BAR: selecting Per region emits `cell_mode: "fit"`.
    func testFitReachesTheOptimizeJob() throws {
        var s = Self.gradedSettings()
        s.cellSizeMode = .fit
        let job = try Self.optimizeJob(lattice: try Self.spec(s))
        let grading = try XCTUnwrap(job["grading"] as? [String: Any],
                                    "a graded lattice run carries a grading block")
        XCTAssertEqual(grading["cell_mode"] as? String, "fit",
                       "the mode the user picked must reach the worker")
        // Core REFUSES a target cell alongside fit ("core derives the cell from each
        // declared include region's own extent"), and refuses the ladder ends outside
        // swept. Emitting either would kill the whole job at validation.
        XCTAssertNil(grading["cell_mm"],
                     "fit takes no target cell — core refuses one alongside it")
        XCTAssertNil(grading["cell_min_mm"])
        XCTAssertNil(grading["cell_max_mm"])
    }

    /// The RE-LATTICE mirror. A re-lattice that silently drops the cell mode is the
    /// same class of bug as the ladder-position-in-a-fraction-shaped-key failure.
    func testFitReachesTheRelatticeJob() throws {
        var s = Self.gradedSettings()
        s.cellSizeMode = .fit
        let job = try Self.relatticeJob(lattice: try Self.spec(s))
        let grading = try XCTUnwrap(job["grading"] as? [String: Any])
        XCTAssertEqual(grading["cell_mode"] as? String, "fit",
                       "a re-lattice must carry the same cell mode as the run")
        XCTAssertNil(grading["cell_mm"])
    }

    /// THE TWO SERIALIZERS MUST AGREE, with a POSITIVE CONTROL first — an equality
    /// bar between two empty things passes vacuously, and on this project one has.
    func testBothSerializersEmitTheSameFitGradingBlock() throws {
        var s = Self.gradedSettings()
        s.cellSizeMode = .fit
        let spec = try Self.spec(s)
        let a = try XCTUnwrap(
            try Self.optimizeJob(lattice: spec)["grading"] as? [String: Any])
        let b = try XCTUnwrap(
            try Self.relatticeJob(lattice: spec)["grading"] as? [String: Any])
        XCTAssertEqual(a["cell_mode"] as? String, "fit",
                       "the block being compared must actually carry the mode")
        let ja = try JSONSerialization.data(withJSONObject: a, options: [.sortedKeys])
        let jb = try JSONSerialization.data(withJSONObject: b, options: [.sortedKeys])
        XCTAssertEqual(ja, jb, "one-sided edits to the two serializers must fail here")
    }

    /// And the bytes are bytes THIS core runs — asked of core's own parser, not of a
    /// key list this test wrote down.
    func testTheFitJobPassesCoresOwnSchema() throws {
        var s = Self.gradedSettings()
        s.cellSizeMode = .fit
        let data = try Self.optimizeJobData(lattice: try Self.spec(s))
        XCTAssertNil(TopOptKit.jobSchemaError(data),
                     "core must accept the document the app emits for fit")
    }

    // MARK: - S2c · the fit/retention pair is NOT EXPRESSIBLE

    /// `grade_lattice` THROWS on fit + retention (core/src/simp/grading.cpp:66-70).
    /// The app must not be able to author that job — proven on the emitted bytes,
    /// not on a UI state.
    func testFitWithRetentionArmedCannotBeExpressed() throws {
        var s = Self.gradedSettings()
        s.cellSizeMode = .fit
        s.retainSubfloorInUnloadedRegions = true
        s.subfloorStressFraction = 0.12
        s.subfloorPerRegion = true
        let job = try Self.optimizeJob(lattice: try Self.spec(s))
        let grading = try XCTUnwrap(job["grading"] as? [String: Any])
        // POSITIVE CONTROL: the thing being excluded must actually be selected, or
        // this bar passes because nothing was armed in the first place.
        XCTAssertTrue(s.retainSubfloorInUnloadedRegions,
                      "the settings under test must actually arm retention")
        XCTAssertEqual(grading["cell_mode"] as? String, "fit")
        XCTAssertNil(grading["retain_subfloor_in_unloaded_regions"],
                     "fit + retention is the job core throws on — it must not be "
                   + "expressible from the app")
        XCTAssertNil(grading["subfloor_stress_fraction"])
        XCTAssertNil(grading["subfloor_per_region"])
    }

    /// The re-lattice path carries the same exclusion — it shares the builder, and
    /// this asserts the sharing rather than trusting it.
    func testFitWithRetentionArmedCannotBeExpressedOnRelattice() throws {
        var s = Self.gradedSettings()
        s.cellSizeMode = .fit
        s.retainSubfloorInUnloadedRegions = true
        let job = try Self.relatticeJob(lattice: try Self.spec(s))
        let grading = try XCTUnwrap(job["grading"] as? [String: Any])
        XCTAssertEqual(grading["cell_mode"] as? String, "fit")
        XCTAssertNil(grading["retain_subfloor_in_unloaded_regions"])
    }

    /// THE COUNTERPART, so the exclusion is not just "retention never ships": on any
    /// other cell mode the same armed settings DO reach the worker.
    func testRetentionStillReachesTheWorkerOnEveryOtherCellMode() throws {
        for mode in [LatticeCellSizeMode.fixed, .auto, .swept] {
            var s = Self.gradedSettings()
            s.cellSizeMode = mode
            s.retainSubfloorInUnloadedRegions = true
            let job = try Self.optimizeJob(lattice: try Self.spec(s))
            let grading = try XCTUnwrap(job["grading"] as? [String: Any])
            XCTAssertEqual(grading["retain_subfloor_in_unloaded_regions"] as? Bool,
                           true,
                           "retention must be unaffected on \(mode.rawValue)")
        }
    }

    /// The CONTROL says which to use when, because from where the user sits the two
    /// solve the same problem.
    func testTheRetentionControlExplainsTheExclusion() throws {
        let c = LatticeRetentionControl.compute(
            armed: false, graded: true, capability: .all,
            belowFloorVoxels: 100, regionVoxels: 1000, ceilingFraction: nil,
            coreCeilingFraction: 0.2, cellMode: .fit)
        XCTAssertFalse(c.enabled, "retention cannot be armed while fit is selected")
        let why = try XCTUnwrap(c.disabledReason)
        XCTAssertTrue(why.contains("Per region"),
                      "the reason must name the control that is winning: \(why)")
        XCTAssertTrue(why.lowercased().contains("use per region when")
                      || why.contains("differ in thickness"),
                      "it must say WHICH to use WHEN, not only that they conflict: \(why)")
        XCTAssertFalse(why.lowercased().contains("advanced"))
        XCTAssertFalse(why.lowercased().contains("expert"))
        // And on any other mode the control is operable.
        let ok = LatticeRetentionControl.compute(
            armed: false, graded: true, capability: .all,
            belowFloorVoxels: 100, regionVoxels: 1000, ceilingFraction: nil,
            coreCeilingFraction: 0.2, cellMode: .swept)
        XCTAssertTrue(ok.enabled, "the exclusion must be scoped to fit alone")
    }

    // MARK: - S2e · the DEFAULT — the maintainer's decision, and he changed it

    /// S2e ORIGINALLY pinned `.fixed` ("the default cell mode is NOT changed by
    /// this task") because the default was the maintainer's call, not the
    /// cell-fit task's. He has since made that call the other way: task
    /// 2026-08-12-lattice-page-redesign §4b — "AUTO IS THE DEFAULT ON EVERY
    /// CONTROL… a user should be able to simply press Auto on everything after
    /// setting the faces section and it should work". So this pins the NEW
    /// default, at the same strength.
    func testDefaultCellModeIsAutoForANewProject() throws {
        XCTAssertEqual(LatticeSettings(enabled: true).cellSizeMode, .auto,
                       "§4b: Auto is the default on a NEW project")
        XCTAssertEqual(LatticeSettings(enabled: true).densityMode, .sim,
                       "§4b: on EVERY control, not just the cell")
    }

    /// ★ AND THE HALF THAT MUST NOT HAVE MOVED. A default describes a NEW
    /// project; it must never rewrite what an existing one had. A snapshot
    /// written before the flip still decodes to `.fixed` and still emits the
    /// identical document — no `cell_mode` key, `cell_mm` present.
    func testAnOlderSnapshotStillDecodesToFixedAndEmitsNoModeKey() throws {
        let legacyJSON = Data(#"""
        {"enabled": true, "topologyID": "octet", "cellMM": 8,
         "densityMode": "auto", "minRelativeDensity": 0.2,
         "maxRelativeDensity": 0.5, "boundary": "fullSkin"}
        """#.utf8)
        let legacy = try JSONDecoder().decode(LatticeSettings.self,
                                              from: legacyJSON)
        XCTAssertEqual(legacy.cellSizeMode, .fixed,
                       "an absent cell_mode key IS fixed — history is not rewritten")
        let job = try Self.optimizeJob(lattice: try Self.spec(legacy))
        let grading = try XCTUnwrap(job["grading"] as? [String: Any])
        XCTAssertNil(grading["cell_mode"],
                     "an absent cell_mode IS fixed — the untouched job is unchanged")
        XCTAssertNotNil(grading["cell_mm"])
    }

    /// FIT with NO declared include region is a job core refuses outright, so the
    /// spec falls back to the fixed cell rather than emitting bytes that die at
    /// validation. Found by handing the emitted document to core's own parser.
    func testFitFallsBackToFixedWithNoIncludeRegionDeclared() throws {
        var s = Self.gradedSettings()
        s.cellSizeMode = .fit
        let spec = try Self.spec(s, regions: [])
        XCTAssertEqual(spec.cellSizeMode, "fixed",
                       "core refuses fit with nothing declared to fit into")
        let data = try Self.optimizeJobData(lattice: spec)
        XCTAssertNil(TopOptKit.jobSchemaError(data),
                     "and the document that IS emitted must be one core runs")
    }

    /// A snapshot saved with fit, run against a core that does not carry the value,
    /// falls back to the fixed cell rather than dying at schema validation.
    func testFitFallsBackToFixedWhenTheLinkedCoreDoesNotTakeIt() throws {
        var s = Self.gradedSettings()
        s.cellSizeMode = .fit
        let spec = try Self.spec(s, cellModes: .none)
        XCTAssertEqual(spec.cellSizeMode, "fixed",
                       "an unknown cell_mode kills the whole job; degrade instead")
        let job = try Self.optimizeJob(lattice: spec)
        let grading = try XCTUnwrap(job["grading"] as? [String: Any])
        XCTAssertNil(grading["cell_mode"])
        XCTAssertNotNil(grading["cell_mm"])
    }

    // MARK: - the PROBE itself, against the core that IS built

    /// Two-sided, for the reason the retention probe carries its own scar: a probe
    /// that stopped reaching the grading block would report every value accepted.
    func testTheCellModeProbeAnswersAgainstTheLinkedCore() throws {
        try XCTSkipUnless(TopOptKit.gradingSchemaProbeIsReliable,
                          "the schema probe did not prove itself on this build")
        XCTAssertTrue(TopOptKit.gradingSchemaAcceptsCellMode("fixed"),
                      "positive control: every core takes fixed")
        XCTAssertFalse(
            TopOptKit.gradingSchemaAcceptsCellMode("topopt-app-probe-no-such-mode"),
            "negative control: a nonsense mode must be refused")
        XCTAssertTrue(TopOptKit.gradingSchemaAcceptsCellMode("fit"),
                      "the core in this worktree carries fit (PR 302) — if this "
                    + "fails, core is stale, rebuild it")
    }
}
