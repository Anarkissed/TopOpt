// LatticeRetentionControlTests — the device can finally ASK for sub-floor
// retention, and the receipt of it can finally reach the screen (task
// 2026-08-05-lattice-retention-app-control).
//
// EVERY TEST HERE DRIVES THE REAL SERIALIZER. Not a hand-assembled dictionary:
// `RemoteRun.buildJobJSON()` and `RelatticeJobBuilder.build` are the two
// functions that produce the bytes a worker receives, and a test that asserts
// against a dictionary a test built itself proves nothing about either. Four
// consecutive PRs on this project shipped app-side defects behind green checks
// and one passed 31 tests against a code path the maintainer could not reach.
//
// The capability probe is INJECTED (`LatticeRetentionCapability.all` / `.none`)
// rather than read from the vendored core, so the emission is pinned regardless
// of which core happens to be built — and the probe itself is tested separately
// against the core that IS built.

import XCTest
import simd
import TopOptKit
@testable import TopOptFlows

@MainActor
final class LatticeRetentionControlTests: XCTestCase {

    // MARK: - harness: the REAL job-building paths

    /// A run request identical in every physics input, parameterized only by the
    /// lattice spec — so any difference in the emitted job.json is the lattice
    /// serializer's doing and nothing else's.
    private static func request(lattice: LatticeSpec?) -> RunRequest {
        RunRequest(
            modelPath: "/tmp/part.step", material: "PLA", materialsPath: "",
            rulesPath: "", resolution: 64, projectName: "retention",
            anchorFaceIDs: [3],
            loadGroups: [TopOptKit.LoadGroupSpec(faceIDs: [11],
                                                force: SIMD3(0, 0, -250))],
            minimizePlastic: true,
            buildDirection: SIMD3(0, 0, 1),
            infillPercent: 40, wallLoops: 3,
            wallLineWidthOuterMM: 0.45, wallLineWidthInnerMM: 0.45,
            lattice: lattice)
    }

    /// The optimize path's own serializer.
    private static func optimizeJob(lattice: LatticeSpec?) throws -> [String: Any] {
        let cfg = RemoteRunnerConfig(host: "127.0.0.1", port: 8757,
                                     expectedFingerprint: "test")
        let run = RemoteRun(config: cfg, request: request(lattice: lattice),
                            progress: { _, _, _ in true }, onVariant: { _ in })
        return try XCTUnwrap(
            JSONSerialization.jsonObject(with: try run.buildJobJSON())
                as? [String: Any])
    }

    /// The RE-LATTICE path's own serializer, from a retained job document.
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

    /// Settings that produce a GRADED spec (retention lives in the `grading`
    /// block, which only a graded job carries).
    private static func gradedSettings() -> LatticeSettings {
        var s = LatticeSettings(enabled: true)
        s.densityMode = .auto
        // ★ STATED, not inherited (task 2026-08-12 §4b moved the default to
        // `.auto`). These tests are about the SUB-FLOOR controls being untouched;
        // the cell mode is a different control, and a fixture that silently
        // tracks a default measures whichever default is current rather than the
        // thing it names. The legacy-snapshot side decodes to `.fixed` as it
        // always has, so the comparison is still like for like.
        s.cellSizeMode = .fixed
        // ★ STATED for the same reason, one control later (task
        // 2026-08-15-lattice-and-face-ui): the maintainer moved the boundary
        // default from `.fullSkin` to `.none` ("it should default to 'none'").
        // The legacy snapshot this is compared against names `"boundary":
        // "fullSkin"` explicitly, so the fixture names it too — otherwise this
        // test stops measuring "the SUB-FLOOR controls are untouched" and starts
        // measuring which finish happens to be the current default.
        s.boundary = .fullSkin
        s.minRelativeDensity = 0.2
        s.maxRelativeDensity = 0.5
        return s
    }

    private static func spec(_ s: LatticeSettings,
                             capability: LatticeRetentionCapability) throws
        -> LatticeSpec {
        try XCTUnwrap(s.runSpec(lineWidthMM: 0.45, capability: capability),
                      "these settings must produce a runnable graded spec")
    }

    // MARK: - S1 · the four keys reach the job the worker receives

    func testArmedRetentionReachesTheOptimizeJob() throws {
        var s = Self.gradedSettings()
        s.retainSubfloorInUnloadedRegions = true
        s.subfloorStressFraction = 0.12
        s.subfloorPerRegion = true
        s.reportRegionCells = true
        let job = try Self.optimizeJob(
            lattice: try Self.spec(s, capability: .all))
        let grading = try XCTUnwrap(job["grading"] as? [String: Any],
                                    "a graded lattice run carries a grading block")
        XCTAssertEqual(grading["retain_subfloor_in_unloaded_regions"] as? Bool, true,
                       "the switch itself must reach the worker")
        XCTAssertEqual(grading["subfloor_stress_fraction"] as? Double, 0.12,
                       "a ceiling the user MOVED must reach the worker")
        XCTAssertEqual(grading["subfloor_per_region"] as? Bool, true)
        XCTAssertEqual(grading["report_region_cells"] as? Bool, true)
    }

    /// The re-lattice MIRROR. A re-lattice of a finished variant that silently
    /// drops the posture is the same class of bug as the ladder-position-in-a-
    /// fraction-shaped-key failure that killed every re-lattice in 48 ms.
    func testArmedRetentionReachesTheRelatticeJob() throws {
        var s = Self.gradedSettings()
        s.retainSubfloorInUnloadedRegions = true
        s.subfloorStressFraction = 0.12
        s.subfloorPerRegion = true
        s.reportRegionCells = true
        let job = try Self.relatticeJob(
            lattice: try Self.spec(s, capability: .all))
        let grading = try XCTUnwrap(job["grading"] as? [String: Any])
        XCTAssertEqual(grading["retain_subfloor_in_unloaded_regions"] as? Bool, true,
                       "a re-lattice must carry the same posture as the optimize run")
        XCTAssertEqual(grading["subfloor_stress_fraction"] as? Double, 0.12)
        XCTAssertEqual(grading["subfloor_per_region"] as? Bool, true)
        XCTAssertEqual(grading["report_region_cells"] as? Bool, true)
    }

    /// THE TWO SERIALIZERS MUST AGREE. They are the drift risk this task names by
    /// name; asserting the grading blocks are equal makes a one-sided edit fail.
    func testBothSerializersEmitTheSameGradingBlock() throws {
        var s = Self.gradedSettings()
        s.retainSubfloorInUnloadedRegions = true
        s.subfloorPerRegion = true
        s.reportRegionCells = true
        let spec = try Self.spec(s, capability: .all)
        let a = try XCTUnwrap(
            try Self.optimizeJob(lattice: spec)["grading"] as? [String: Any])
        let b = try XCTUnwrap(
            try Self.relatticeJob(lattice: spec)["grading"] as? [String: Any])
        // ★ POSITIVE CONTROL, because an equality bar between two things that are
        // both EMPTY passes vacuously — and on this project a comparison bar has
        // done exactly that. Assert the compared thing actually happened first.
        XCTAssertEqual(a["retain_subfloor_in_unloaded_regions"] as? Bool, true,
                       "the block being compared must actually carry the posture")
        let ja = try JSONSerialization.data(withJSONObject: a, options: [.sortedKeys])
        let jb = try JSONSerialization.data(withJSONObject: b, options: [.sortedKeys])
        XCTAssertEqual(ja, jb,
                       "optimize and re-lattice must build the SAME grading block")
    }

    /// Absent means "core takes its own constant at call time". Echoing core's
    /// default back would make the app the author of a number it merely read.
    func testTheCeilingIsOmittedWhenTheUserHasNotMovedIt() throws {
        var s = Self.gradedSettings()
        s.retainSubfloorInUnloadedRegions = true
        s.subfloorStressFraction = nil
        let grading = try XCTUnwrap(
            try Self.optimizeJob(lattice: try Self.spec(s, capability: .all))["grading"]
                as? [String: Any])
        XCTAssertEqual(grading["retain_subfloor_in_unloaded_regions"] as? Bool, true)
        XCTAssertNil(grading["subfloor_stress_fraction"],
                     "an untouched ceiling must not appear in the document at all")
    }

    /// Core's schema REFUSES `subfloor_per_region` without retention armed ("a job
    /// that means one thing and says another"). The app must not build that job.
    func testPerRegionIsNeverArmedWhileRetentionIsOff() throws {
        var s = Self.gradedSettings()
        s.retainSubfloorInUnloadedRegions = false
        s.subfloorPerRegion = true
        s.subfloorStressFraction = 0.3
        let grading = try XCTUnwrap(
            try Self.optimizeJob(lattice: try Self.spec(s, capability: .all))["grading"]
                as? [String: Any])
        XCTAssertNil(grading["retain_subfloor_in_unloaded_regions"])
        XCTAssertNil(grading["subfloor_per_region"],
                     "core refuses it without retention — never emit it")
        XCTAssertNil(grading["subfloor_stress_fraction"],
                     "core refuses it without retention — never emit it")
    }

    /// A key the LINKED core does not accept is never emitted: `reject_unknown_keys`
    /// fails the WHOLE job over one, so this is not a degraded run, it is a dead one.
    func testAKeyTheCoreDoesNotAcceptIsNeverEmitted() throws {
        var s = Self.gradedSettings()
        s.retainSubfloorInUnloadedRegions = true
        s.subfloorPerRegion = true
        s.reportRegionCells = true
        s.subfloorStressFraction = 0.1
        let grading = try XCTUnwrap(
            try Self.optimizeJob(lattice: try Self.spec(s, capability: .none))["grading"]
                as? [String: Any])
        for key in ["retain_subfloor_in_unloaded_regions", "subfloor_stress_fraction",
                    "subfloor_per_region", "report_region_cells"] {
            XCTAssertNil(grading[key],
                         "\(key) must not be emitted at a core that would refuse it")
        }
    }

    /// The half-supported case the two concurrent branches actually produce: a core
    /// that takes retention but not the cell-size-adaptation pair.
    func testAPartiallyCapableCoreGetsExactlyWhatItAccepts() throws {
        var s = Self.gradedSettings()
        s.retainSubfloorInUnloadedRegions = true
        s.subfloorPerRegion = true
        s.reportRegionCells = true
        let partial = LatticeRetentionCapability(
            retention: true, stressFraction: true, perRegion: false,
            regionCells: false, probeReliable: true)
        let grading = try XCTUnwrap(
            try Self.optimizeJob(lattice: try Self.spec(s, capability: partial))["grading"]
                as? [String: Any])
        XCTAssertEqual(grading["retain_subfloor_in_unloaded_regions"] as? Bool, true)
        XCTAssertNil(grading["subfloor_per_region"])
        XCTAssertNil(grading["report_region_cells"])
    }

    // MARK: - the document the app builds is a document CORE WILL RUN

    /// ★ THE STRONGEST FORM OF THIS BAR. Every other test asserts the emitted
    /// dictionary contains the keys the test expected. This one hands the actual
    /// bytes to CORE'S OWN PARSER (`topopt::parse_job`) and asserts core accepts
    /// them — because a job document can carry exactly the right key names and
    /// still die at schema validation on a value's SHAPE, which is precisely how
    /// every re-lattice of a growth variant died in 48 ms.
    ///
    /// Driven at the LINKED core's real capability, so on a core that takes all
    /// four keys all four are validated, and on an older one the subset it takes is
    /// validated — either way the app is proven not to be building a dead job.
    func testEveryJobTheAppBuildsIsAcceptedByCoresOwnParser() throws {
        let cap = LatticeRetentionCapability.fromCore
        try XCTSkipUnless(cap.probeReliable,
                          "the schema probe could not prove itself on this build")
        var armed = Self.gradedSettings()
        armed.retainSubfloorInUnloadedRegions = true
        armed.subfloorPerRegion = true
        armed.reportRegionCells = true
        var moved = armed
        moved.subfloorStressFraction = 0.12

        for (label, settings) in [("untouched", Self.gradedSettings()),
                                  ("armed", armed),
                                  ("armed + moved ceiling", moved)] {
            let spec = try Self.spec(settings, capability: cap)
            let cfg = RemoteRunnerConfig(host: "127.0.0.1", port: 8757,
                                         expectedFingerprint: "test")
            let run = RemoteRun(config: cfg, request: Self.request(lattice: spec),
                                progress: { _, _, _ in true }, onVariant: { _ in })
            let bytes = try run.buildJobJSON()
            XCTAssertNil(TopOptKit.jobSchemaError(bytes),
                         "core refused the \(label) optimize job the app built")

            // ...and the RE-LATTICE document built from it.
            let relattice = try RelatticeJobBuilder.build(
                original: bytes, designFingerprint: 0xDEAD_BEEF,
                achievedVolumeFraction: 0.42, designFileName: "design.bin",
                lattice: spec)
            XCTAssertNil(TopOptKit.jobSchemaError(relattice),
                         "core refused the \(label) re-lattice job the app built")
        }

        // POSITIVE CONTROL: the validator must actually be able to say no, or the
        // three passes above mean nothing.
        XCTAssertNotNil(TopOptKit.jobSchemaError(Data(#"{"model": 1}"#.utf8)),
                        "the validator must refuse a job core would refuse")
    }

    /// And the converse, measured rather than assumed: a job carrying a key the
    /// linked core does NOT accept is refused outright — which is why the
    /// capability gate exists at all.
    func testACoreThatDoesNotKnowAKeyRefusesTheWholeJob() throws {
        let cap = LatticeRetentionCapability.fromCore
        try XCTSkipUnless(cap.probeReliable)
        let spec = try Self.spec(Self.gradedSettings(), capability: cap)
        var job = try Self.optimizeJob(lattice: spec)
        var grading = try XCTUnwrap(job["grading"] as? [String: Any])
        grading["a-key-no-core-carries"] = true
        job["grading"] = grading
        let bytes = try JSONSerialization.data(withJSONObject: job,
                                               options: [.sortedKeys])
        let why = try XCTUnwrap(TopOptKit.jobSchemaError(bytes),
                                "one unknown grading key must kill the whole job")
        XCTAssertTrue(why.contains("unknown key"), why)
    }

    // MARK: - R1 · the default path is BYTE-IDENTICAL

    func testUntouchedControlsSerializeToTheIdenticalJob() throws {
        // The baseline: a graded lattice job built by settings that predate this
        // task's controls entirely (they decode from a snapshot with no such keys).
        let legacyJSON = Data("""
        {"enabled": true, "topologyID": "octet", "cellMM": 8, "densityMode": "auto",
         "minRelativeDensity": 0.2, "maxRelativeDensity": 0.5, "boundary": "fullSkin"}
        """.utf8)
        let legacy = try JSONDecoder().decode(LatticeSettings.self, from: legacyJSON)
        let baseline = try Self.optimizeJob(
            lattice: try Self.spec(legacy, capability: .all))

        // The same project through the NEW code with every control untouched.
        let today = try Self.optimizeJob(
            lattice: try Self.spec(Self.gradedSettings(), capability: .all))

        // POSITIVE CONTROL: both sides really are graded lattice jobs, so this is
        // not two empty documents agreeing with each other.
        XCTAssertNotNil(baseline["grading"] as? [String: Any])
        XCTAssertNotNil(today["grading"] as? [String: Any])

        let a = try JSONSerialization.data(withJSONObject: baseline, options: [.sortedKeys])
        let b = try JSONSerialization.data(withJSONObject: today, options: [.sortedKeys])
        XCTAssertEqual(a, b, "controls untouched ⇒ the SAME job document, byte for byte")

        // ...and the vocabulary is absent outright, not merely false.
        let text = try XCTUnwrap(String(data: b, encoding: .utf8))
        for key in ["retain_subfloor_in_unloaded_regions", "subfloor_stress_fraction",
                    "subfloor_per_region", "report_region_cells"] {
            XCTAssertFalse(text.contains(key),
                           "an untouched job must not mention \(key) at all")
        }
    }

    func testUntouchedControlsSerializeToTheIdenticalRelatticeJob() throws {
        let legacyJSON = Data("""
        {"enabled": true, "topologyID": "octet", "cellMM": 8, "densityMode": "auto",
         "minRelativeDensity": 0.2, "maxRelativeDensity": 0.5, "boundary": "fullSkin"}
        """.utf8)
        let legacy = try JSONDecoder().decode(LatticeSettings.self, from: legacyJSON)
        let a = try JSONSerialization.data(
            withJSONObject: try Self.relatticeJob(
                lattice: try Self.spec(legacy, capability: .all)),
            options: [.sortedKeys])
        let b = try JSONSerialization.data(
            withJSONObject: try Self.relatticeJob(
                lattice: try Self.spec(Self.gradedSettings(), capability: .all)),
            options: [.sortedKeys])
        XCTAssertEqual(a, b, "controls untouched ⇒ the SAME re-lattice document")
    }

    /// A NON-lattice job must not gain a single byte either — the blast radius
    /// stops at lattice runs.
    func testANonLatticeJobIsUntouched() throws {
        let job = try Self.optimizeJob(lattice: nil)
        let text = try XCTUnwrap(String(
            data: try JSONSerialization.data(withJSONObject: job,
                                             options: [.sortedKeys]),
            encoding: .utf8))
        XCTAssertFalse(text.contains("grading"))
        XCTAssertFalse(text.contains("subfloor"))
    }

    // MARK: - S2 · the dead forecast branch is LIVE

    /// THE BRANCH AT LatticeForecast.swift:202 COULD NOT FIRE ON THE DEVICE.
    /// `subfloorRequested` is core's echo of `grading.retain_subfloor_in_unloaded_
    /// regions`, and the app never sent that key — so the three paragraphs that
    /// explain retention to the user were unreachable code on every real path.
    ///
    /// This drives the REAL serializer, reads the flag core would echo straight out
    /// of the emitted document, and asserts the branch fires on it.
    func testTheForecastRetentionBranchIsReachableThroughTheRealSerializer() throws {
        var s = Self.gradedSettings()
        s.retainSubfloorInUnloadedRegions = true
        let job = try Self.relatticeJob(lattice: try Self.spec(s, capability: .all))
        let grading = try XCTUnwrap(job["grading"] as? [String: Any])

        // Core's own rule, verbatim (run_job.cpp: `const bool want_subfloor =
        // job.grading.retain_subfloor_in_unloaded_regions;`). So the forecast's
        // `requested` is a FUNCTION of what the serializer emitted, not a constant
        // this test chose.
        let requested = grading["retain_subfloor_in_unloaded_regions"] as? Bool ?? false
        XCTAssertTrue(requested,
                      "the job must carry the key, or core can never echo it back "
                      + "and the branch stays dead")

        let doc = Self.forecastDocument(requested: requested, belowFloor: 822,
                                        ceiling: 0.2)
        let f = try XCTUnwrap(LatticeForecast.parse(doc))
        XCTAssertTrue(f.subfloorRequested)
        let reasons = f.reasonLines
        XCTAssertTrue(reasons.contains { $0.contains("asked to lattice them anyway") },
                      "the requested-retention paragraph must appear: \(reasons)")
        XCTAssertTrue(reasons.contains { $0.contains("OUT OF REGIME") },
                      "the out-of-regime warning must appear: \(reasons)")
        XCTAssertTrue(reasons.contains { $0.contains("accepted unknown") },
                      "the 'the margin cannot see this' paragraph must appear")
        XCTAssertTrue(reasons.contains { $0.contains("20%") },
                      "the ceiling shown is CORE's echoed number: \(reasons)")
    }

    /// The other side: retention OFF still says the material is there, and says
    /// it stays solid — the branch that has always been reachable.
    func testTheNotRequestedBranchStillSaysWhatIsThere() throws {
        let doc = Self.forecastDocument(requested: false, belowFloor: 822,
                                        ceiling: 0)
        let f = try XCTUnwrap(LatticeForecast.parse(doc))
        XCTAssertFalse(f.subfloorRequested)
        XCTAssertTrue(f.reasonLines.contains { $0.contains("below the") },
                      "it must still name the material the choice is about")
    }

    /// A forecast document shaped exactly as core writes it (run_job.cpp's
    /// `lattice_forecast.json`), so the parse under test is the production parse.
    private static func forecastDocument(requested: Bool, belowFloor: Int,
                                         ceiling: Double) -> Data {
        let obj: [String: Any] = [
            "variant_volume_fraction": 0.42,
            "topology": "octet",
            "cell_mode": "auto",
            "cell_size_mm": 4.6,
            "printability_floor_mm": 4.6,
            "cells_per_member_floor": 5.0,
            "region_voxels": 1257,
            "would_lattice_voxels": 324,
            "would_stay_solid_voxels": 933,
            "would_stay_solid_by_reason": [
                "member_too_thin_for_cell": 822,
                "strut_unprintable_at_every_cell": 111,
                "irrecoverable_by_any_cell_size": 0,
                "widest_rejected_member_mm": 4.0,
                "member_width_needed_mm": 23.0,
            ],
            "subfloor_retention": [
                "requested": requested,
                "stress_fraction_ceiling": ceiling,
                "voxels_below_floor": belowFloor,
            ],
            "include_regions": 1,
            "exclude_regions": 0,
            "include_region_void_voxels": 0,
            "boundary": "diagrid",
            "boundary_can_emit": true,
            "counterfactuals": [],
        ]
        return try! JSONSerialization.data(withJSONObject: obj)
    }

    // MARK: - S2 · the control's own surface

    func testTheControlIsOffByDefaultAndSaysWhatChanges() {
        XCTAssertFalse(LatticeSettings().retainSubfloorInUnloadedRegions,
                       "OFF by default")
        let c = LatticeRetentionControl.compute(
            armed: false, graded: true, capability: .all,
            belowFloorVoxels: 822, regionVoxels: 1257,
            ceilingFraction: nil, coreCeilingFraction: 0.2)
        XCTAssertTrue(c.enabled)
        XCTAssertTrue(c.body.contains("certificate will not cover it"))
        XCTAssertTrue(c.body.contains("out of regime"))
        for banned in ["advanced", "expert", "unsafe", "Advanced", "Expert", "Unsafe"] {
            XCTAssertFalse(c.title.contains(banned), "the copy must say what changes")
            XCTAssertFalse(c.body.contains(banned), "the copy must say what changes")
        }
    }

    /// THE EXPOSURE, BEFORE HE COMMITS. Core's pre-flight already reports how much
    /// material is below the floor; the control must show it before the run.
    func testTheControlShowsTheExposureBeforeTheRun() throws {
        let armed = LatticeRetentionControl.compute(
            armed: true, graded: true, capability: .all,
            belowFloorVoxels: 822, regionVoxels: 1257,
            ceilingFraction: nil, coreCeilingFraction: 0.2)
        let e = try XCTUnwrap(armed.exposure)
        XCTAssertTrue(armed.exposureIsLive)
        XCTAssertTrue(e.contains("822"), "the count core measured: \(e)")
        XCTAssertTrue(e.contains("65.4%"), "its share of what the lattice covers: \(e)")
        XCTAssertTrue(e.contains("upper bound"),
                      "it is an upper bound — the predicate needs a solve")

        let off = LatticeRetentionControl.compute(
            armed: false, graded: true, capability: .all,
            belowFloorVoxels: 822, regionVoxels: 1257,
            ceilingFraction: nil, coreCeilingFraction: 0.2)
        XCTAssertFalse(off.exposureIsLive)
        XCTAssertTrue(try XCTUnwrap(off.exposure).contains("stay SOLID"))
    }

    func testTheCeilingRowNamesCoresNumberUntilTheUserMovesIt() {
        let core = LatticeRetentionControl.compute(
            armed: true, graded: true, capability: .all, belowFloorVoxels: 1,
            regionVoxels: 10, ceilingFraction: nil, coreCeilingFraction: 0.2)
        XCTAssertEqual(core.ceilingText, "core’s 20%")
        XCTAssertTrue(core.showsCeiling)
        let moved = LatticeRetentionControl.compute(
            armed: true, graded: true, capability: .all, belowFloorVoxels: 1,
            regionVoxels: 10, ceilingFraction: 0.12, coreCeilingFraction: 0.2)
        XCTAssertEqual(moved.ceilingText, "12%")
    }

    func testAUniformRunSaysWhyRetentionIsUnavailable() throws {
        let c = LatticeRetentionControl.compute(
            armed: false, graded: false, capability: .all, belowFloorVoxels: nil,
            regionVoxels: nil, ceilingFraction: nil, coreCeilingFraction: 0.2)
        XCTAssertFalse(c.enabled)
        XCTAssertTrue(try XCTUnwrap(c.disabledReason).contains("Density mode to Auto"))
    }

    func testAnOlderCoreSaysSoRatherThanFailingSilently() throws {
        let c = LatticeRetentionControl.compute(
            armed: false, graded: true, capability: .none, belowFloorVoxels: nil,
            regionVoxels: nil, ceilingFraction: nil, coreCeilingFraction: 0.2)
        XCTAssertFalse(c.enabled)
        XCTAssertNotNil(c.disabledReason)
    }

    // MARK: - S4 · the per-region receipt reaches the screen

    /// A receipt shaped exactly as core writes it: Stage E's `grading.regions[]`,
    /// and — when retention was armed — the `grading.subfloor_retention` block core
    /// has emitted alongside it since PR 295. The reader joins the two by region_id,
    /// so a fixture that carries only one of them is a fixture that cannot exercise
    /// the messages (review P2).
    private static func receiptJSON(rows: [[String: Any]],
                                    subfloor: [String: Any]? = nil) -> Data {
        var grading: [String: Any] = ["regions": rows]
        if let s = subfloor { grading["subfloor_retention"] = s }
        return try! JSONSerialization.data(withJSONObject: ["grading": grading])
    }

    /// The `grading.subfloor_retention` block, as core writes it.
    private static func subfloorBlock(ceiling: Double = 0.2,
                                      overBudget: Bool = false,
                                      regions: [[String: Any]]) -> [String: Any] {
        ["armed": true, "stress_fraction_ceiling": ceiling,
         "over_budget": overBudget, "regions": regions]
    }

    private static func subfloorRegion(id: Int, stress: Double, qualified: Bool,
                                       belowFloor: Int, retained: Int)
        -> [String: Any] {
        ["region_id": id, "candidate_voxels": 1257,
         "below_floor_voxels": belowFloor, "stress_fraction_measured": stress,
         "qualified": qualified, "retained_voxels": retained]
    }

    private static func row(id: Int, candidate: Int, latticed: Int, solid: Int,
                            verdict: String, stress: Double = 0.05,
                            exposure: Double = 0, nozzle: Double = 0,
                            feasible: Bool = true, minCell: Double = 1.09,
                            needed: Double = 5.47,
                            memberMM: Double = 4.0) -> [String: Any] {
        [
            "region_id": id, "candidate_voxels": candidate,
            "latticed_voxels": latticed, "solid_voxels": solid,
            "member_width_mm": ["min": memberMM, "max": memberMM],
            "stress_fraction": stress, "verdict": verdict,
            "exposure_fraction": exposure, "nozzle_needed_mm": nozzle,
            "at_thinnest_member": ["feasible": feasible,
                                   "min_printable_cell_mm": minCell,
                                   "min_member_width_mm": needed],
            "at_thickest_member": ["feasible": true,
                                   "min_printable_cell_mm": minCell,
                                   "min_member_width_mm": needed],
        ]
    }

    /// ★ THE NUMBER THAT WOULD HAVE SAVED A NIGHT. A region that received ZERO
    /// cells must say so BY NAME and FIRST — not be findable by scrolling.
    func testARegionThatReceivedNothingIsNamedAndComesFirst() throws {
        let data = Self.receiptJSON(rows: [
            Self.row(id: 1, candidate: 900, latticed: 900, solid: 0,
                     verdict: "certified"),
            Self.row(id: 2, candidate: 1257, latticed: 0, solid: 1257,
                     verdict: "no_pair", nozzle: 0.31),
            Self.row(id: 3, candidate: 0, latticed: 0, solid: 0,
                     verdict: "no_candidates"),
        ])
        let r = try XCTUnwrap(LatticeRegionCellReceipt.parse(data))
        XCTAssertEqual(r.rows.count, 3)
        XCTAssertEqual(r.emptyRegions.map(\.regionID), [2, 3])

        let labels = [1: "Web", 2: "Back wall", 3: "Boss"]
        let head = r.headline(labels: labels)
        XCTAssertTrue(head.contains("2 of 3 regions received NO lattice"), head)
        XCTAssertTrue(head.contains("Back wall"), head)
        XCTAssertTrue(head.contains("Boss"), head)

        let lines = r.lines(labels: labels)
        XCTAssertTrue(lines[0].contains("Back wall"), "empty regions FIRST: \(lines)")
        XCTAssertTrue(lines[1].contains("Boss"))
        XCTAssertTrue(lines[2].contains("Web"))
        XCTAssertTrue(lines[0].contains("0 of 1,257 voxels latticed"), lines[0])
        XCTAssertTrue(lines[0].contains("0.31 mm"),
                      "the nozzle that would change the answer: \(lines[0])")
        XCTAssertTrue(lines[1].contains("No material reached the lattice pass"),
                      lines[1])
        // ...and it does NOT assert one of three possible causes as fact.
        XCTAssertFalse(lines[1].contains("the optimizer left nothing"), lines[1])
    }

    func testAnOutOfRegimeRegionSaysTheCertificateDoesNotCoverIt() throws {
        let data = Self.receiptJSON(rows: [
            Self.row(id: 1, candidate: 1257, latticed: 1257, solid: 0,
                     verdict: "out_of_regime", exposure: 0.0289),
        ])
        let r = try XCTUnwrap(LatticeRegionCellReceipt.parse(data))
        let line = r.lines()[0]
        XCTAssertTrue(line.contains("does NOT cover it"), line)
        XCTAssertTrue(line.contains("2.89%"), "the exposure core measured: \(line)")
        // ★ It must say WHOSE 2.89% that is. `exposure_fraction` is the whole run's
        // retained share written onto every out-of-regime row, not this region's.
        XCTAssertTrue(line.contains("Across the whole run"), line)
        XCTAssertTrue(line.contains("margin reads the same"), line)
        XCTAssertTrue(r.headline().contains("all received lattice")
                      || r.headline().contains("received lattice"))
    }

    // MARK: - review P2 · the reason given must be the reason the code acted on

    /// ★ THE CONTRADICTION, PINNED. Two regions, the SAME 4.00 mm members: one was
    /// told "no cell size works here" and the other was latticed in full. Nothing
    /// geometric can separate them — `at_thinnest.feasible` is a pure function of
    /// (member width, nozzle), so identical members give identical feasibility. What
    /// actually differed is the RETENTION PREDICATE
    /// (`core/src/simp/grading.cpp:367`/`:502`, qualified at `:205`), a stress
    /// measurement.
    ///
    /// So the message must not claim a geometric impossibility, and must name the
    /// measurement that decided it.
    func testTwoRegionsWithIdenticalMembersGetNonContradictoryReasons() throws {
        let data = Self.receiptJSON(
            rows: [
                // Did not qualify: stress above the ceiling, so it stayed solid.
                Self.row(id: 1, candidate: 1257, latticed: 0, solid: 1257,
                         verdict: "no_pair", stress: 0.44, nozzle: 0.3073,
                         feasible: false, minCell: 1.1732, needed: 5.4748,
                         memberMM: 4.0),
                // Same 4.00 mm member; qualified, so it was kept.
                Self.row(id: 2, candidate: 1257, latticed: 1257, solid: 0,
                         verdict: "out_of_regime", stress: 0.04, exposure: 0.0289,
                         feasible: false, minCell: 1.1732, needed: 5.4748,
                         memberMM: 4.0),
            ],
            subfloor: Self.subfloorBlock(regions: [
                Self.subfloorRegion(id: 1, stress: 0.44, qualified: false,
                                    belowFloor: 1257, retained: 0),
                Self.subfloorRegion(id: 2, stress: 0.04, qualified: true,
                                    belowFloor: 1257, retained: 1257),
            ]))
        let r = try XCTUnwrap(LatticeRegionCellReceipt.parse(data))
        // Core's own percolation floor, read from core.
        let pf = TopOptKit.latticeCellBounds(topology: "octet",
                                             minExtrudableWidthMM: 0.45)
            .percolationCellsPerMemberFloor
        XCTAssertGreaterThan(pf, 0, "core must state a percolation floor")
        let lines = r.lines(percolationFloor: pf)
        let kept = try XCTUnwrap(lines.first { $0.contains("Region 2") })
        let solid = try XCTUnwrap(lines.first { $0.contains("Region 1") })

        // The un-latticed one must NOT claim nothing can be built here — the row
        // beside it is a 4.00 mm member that WAS latticed.
        XCTAssertFalse(solid.contains("No cell size works here"), solid)
        XCTAssertTrue(solid.contains("No cell size can CERTIFY this member"), solid)
        XCTAssertTrue(solid.contains("It CAN still be built"),
                      "a 4 mm member at a 1.17 mm cell is above percolation: \(solid)")
        XCTAssertTrue(solid.contains("3.4 cells"),
                      "the span core's own numbers give: \(solid)")

        // ...and it names the measurement that actually decided it, with the number
        // he can act on.
        XCTAssertTrue(solid.contains("did NOT qualify"), solid)
        XCTAssertTrue(solid.contains("44.0%"), "the measured fraction: \(solid)")
        XCTAssertTrue(solid.contains("20%"), "against core's ceiling: \(solid)")

        // The kept one is the proof the other row must not contradict.
        XCTAssertTrue(kept.contains("sub-floor material you asked to keep"), kept)
    }

    /// The case where "it cannot be built" is TRUE — below percolation, not merely
    /// below the accuracy floor. The two must not read alike.
    func testAMemberBelowPercolationIsToldItCannotBeBuilt() throws {
        let data = Self.receiptJSON(rows: [
            Self.row(id: 1, candidate: 100, latticed: 0, solid: 100,
                     verdict: "no_pair", nozzle: 0.09, feasible: false,
                     minCell: 1.1732, needed: 5.4748, memberMM: 0.8),
        ])
        let r = try XCTUnwrap(LatticeRegionCellReceipt.parse(data))
        let pf = TopOptKit.latticeCellBounds(topology: "octet",
                                             minExtrudableWidthMM: 0.45)
            .percolationCellsPerMemberFloor
        let line = r.lines(percolationFloor: pf)[0]
        XCTAssertTrue(line.contains("It cannot be built either"), line)
        XCTAssertTrue(line.contains("loose fragments"), line)
        XCTAssertFalse(line.contains("It CAN still be built"), line)
    }

    /// With no percolation floor to read, the buildable sentence is OMITTED rather
    /// than guessed in either direction.
    func testWithoutCoresPercolationFloorTheBuildableClaimIsNotMade() throws {
        let data = Self.receiptJSON(rows: [
            Self.row(id: 1, candidate: 100, latticed: 0, solid: 100,
                     verdict: "no_pair", feasible: false, memberMM: 4.0),
        ])
        let r = try XCTUnwrap(LatticeRegionCellReceipt.parse(data))
        let line = r.lines(percolationFloor: nil)[0]
        XCTAssertTrue(line.contains("No cell size can CERTIFY this member"), line)
        XCTAssertFalse(line.contains("CAN still be built"), line)
        XCTAssertFalse(line.contains("cannot be built"), line)
    }

    /// Retention OFF is a different sentence from "this region did not qualify" —
    /// with the switch off, the question was never asked of any region.
    func testRetentionOffSaysSoRatherThanBlamingTheRegion() throws {
        let data = Self.receiptJSON(rows: [
            Self.row(id: 1, candidate: 1257, latticed: 0, solid: 1257,
                     verdict: "no_pair", feasible: false, memberMM: 4.0),
        ])
        let r = try XCTUnwrap(LatticeRegionCellReceipt.parse(data))
        XCTAssertNil(r.rows[0].regionQualified,
                     "retention off ⇒ the question was never asked, not answered no")
        let line = r.lines()[0]
        XCTAssertFalse(line.contains("did NOT qualify"), line)
    }

    /// The aggregate cap is a RUN-level outcome. Blaming the region for it would be
    /// the same mis-attribution as the exposure fraction.
    func testTheAggregateCapIsNotBlamedOnTheRegion() throws {
        let data = Self.receiptJSON(
            rows: [Self.row(id: 1, candidate: 1257, latticed: 0, solid: 1257,
                            verdict: "no_pair", feasible: false, memberMM: 4.0)],
            subfloor: Self.subfloorBlock(overBudget: true, regions: [
                Self.subfloorRegion(id: 1, stress: 0.04, qualified: true,
                                    belowFloor: 1257, retained: 0)]))
        let r = try XCTUnwrap(LatticeRegionCellReceipt.parse(data))
        let line = r.lines()[0]
        XCTAssertTrue(line.contains("aggregate exposure cap"), line)
        XCTAssertTrue(line.contains("not this region’s doing"), line)
        XCTAssertFalse(line.contains("did NOT qualify"), line)
    }

    /// `solid_load` must state the measurement and the inference apart — core's own
    /// comment calls the load-carrying fallback an inference on that path.
    func testSolidLoadDoesNotAssertLoadAsAMeasuredFact() throws {
        let data = Self.receiptJSON(rows: [
            Self.row(id: 1, candidate: 900, latticed: 0, solid: 900,
                     verdict: "solid_load", stress: 0.61, feasible: true,
                     memberMM: 12.0),
        ])
        let r = try XCTUnwrap(LatticeRegionCellReceipt.parse(data))
        let line = r.lines()[0]
        XCTAssertTrue(line.contains("NOT because it is too thin"), line)
        XCTAssertTrue(line.contains("61%"), "the measured fraction: \(line)")
        XCTAssertFalse(line.contains("Kept solid because it is carrying load"), line)
    }

    /// A run that did not ask for the report must read as ABSENT, never as an
    /// empty report presented as "every region got something".
    func testAReceiptWithoutTheReportReadsAsAbsent() {
        let none = Data(#"{"grading": {}}"#.utf8)
        XCTAssertNil(LatticeRegionCellReceipt.parse(none))
        let empty = Data(#"{"grading": {"regions": []}}"#.utf8)
        XCTAssertNil(LatticeRegionCellReceipt.parse(empty))
    }

    /// Core's `null` member width means "thicker than the distance transform's
    /// cap". Flattening it to 0 would read as a vanishingly thin member.
    func testAnUnmeasuredMemberWidthStaysUnmeasured() throws {
        var r0 = Self.row(id: 1, candidate: 5, latticed: 5, solid: 0,
                          verdict: "certified")
        r0["member_width_mm"] = ["min": 4.0, "max": NSNull()]
        let r = try XCTUnwrap(LatticeRegionCellReceipt.parse(
            Self.receiptJSON(rows: [r0])))
        XCTAssertEqual(r.rows[0].minMemberWidthMM, 4.0)
        XCTAssertNil(r.rows[0].maxMemberWidthMM)
        XCTAssertTrue(r.rows[0].countsLine().contains("from 4.00 mm"))
    }

    /// The scope note must say VOXELS, because that is what core counts — calling
    /// them cells would be the relabelling this project keeps getting bitten by.
    func testTheScopeNoteDoesNotClaimCellCounts() {
        XCTAssertTrue(LatticeRegionCellReceipt.scopeNote.contains("VOXELS"))
        XCTAssertTrue(LatticeRegionCellReceipt.scopeNote.contains("not emitted cells"))
    }

    // MARK: - the capability probe, against the core that is actually built

    /// The probe is only worth anything if it proves itself. It answers false for
    /// EVERYTHING when it cannot — and this asserts the two-sided control passed on
    /// this build, so a probe that silently stopped reaching core's grading block
    /// (and would then report every key as accepted) is loud instead.
    func testTheSchemaProbeProvesItselfOnThisBuild() {
        XCTAssertTrue(TopOptKit.gradingSchemaProbeIsReliable,
                      "the probe's own two-sided control must pass, or every "
                      + "capability answer below is a conservative false")
        XCTAssertTrue(TopOptKit.gradingSchemaAccepts(key: "demand_exponent"),
                      "a key core has carried since the grading law landed")
        XCTAssertFalse(TopOptKit.gradingSchemaAccepts(key: "no-core-accepts-this"),
                      "a key no core carries")
        XCTAssertFalse(TopOptKit.gradingSchemaAccepts(key: ""))
    }

    // MARK: - S3 · can the user type the number the refusals name?

    private func bounds(lineWidthMM: Double, cellMM: Double = 8) -> LatticeBounds {
        var s = LatticeSettings(enabled: true)
        s.cellMM = cellMM
        return LatticeBounds.compute(settings: s,
                                     limits: TopOptKit.latticeLimits(topology: "octet"),
                                     generatable: true, memberMM: 0,
                                     lineWidthMM: lineWidthMM)
    }

    /// THE AUDIT'S ANSWER, PINNED. The pre-flight refusals name a cell of about
    /// 1.2 mm on the maintainer's part. Core accepts any positive cell. The control
    /// must be able to express it.
    func testTheCellControlCanReachTheValueTheRefusalsName() {
        let b = bounds(lineWidthMM: 0.45)
        XCTAssertEqual(LatticeCellEntry.typed(1.2, b), 1.2, accuracy: 1e-9,
                       "1.2 mm must survive being typed — the refusal names it")
        XCTAssertEqual(LatticeCellEntry.typed(1.25, b), 1.25, accuracy: 1e-9,
                       "two decimals, because that is what the refusals quote")
        // ...and a value BELOW core's own densest-end floor still clamps, to core's
        // number. The bound did not go away; it became the right one.
        XCTAssertEqual(LatticeCellEntry.typed(0.9, b),
                       try! XCTUnwrap(b.cellFloorDensestMM), accuracy: 1e-9)
        XCTAssertEqual(LatticeCellEntry.text(1.17), "1.17 mm",
                       "and it must READ BACK as what it is")
        XCTAssertEqual(LatticeCellEntry.text(8), "8.0 mm",
                       "an ordinary cell still reads exactly as it did")
    }

    /// The two floors are DIFFERENT numbers and the control must use the right one.
    /// Core's own `lattice_cell_printability_floor_mm` is evaluated at the band's
    /// LIGHTEST density; using it as the entry bound is what made the refusal's
    /// number unreachable.
    func testTheEntryFloorIsTheDensestEndNotCoresLightestEndFloor() throws {
        let b = bounds(lineWidthMM: 0.45)
        let light = try XCTUnwrap(b.cellFloorMM)
        let dense = try XCTUnwrap(b.cellFloorDensestMM)
        XCTAssertGreaterThan(light, 4.0,
                             "core's rho_min floor at 0.45 mm is around 4.93 mm")
        XCTAssertLessThan(dense, 1.2,
                          "the densest-end floor must be under the value the "
                          + "refusals name, or they stay unreachable: \(dense)")
        XCTAssertEqual(LatticeCellEntry.entryFloorMM(b), dense, accuracy: 1e-9)
        XCTAssertEqual(LatticeCellEntry.range(b).lowerBound, dense, accuracy: 1e-9)
        XCTAssertEqual(LatticeCellEntry.range(b).upperBound, 20)
    }

    /// The floors move with the user's OWN line width, both of them, because both
    /// are read rather than authored.
    func testBothFloorsTrackTheUsersLineWidth() throws {
        let fine = bounds(lineWidthMM: 0.4)
        let coarse = bounds(lineWidthMM: 0.6)
        XCTAssertLessThan(try XCTUnwrap(fine.cellFloorMM),
                          try XCTUnwrap(coarse.cellFloorMM))
        XCTAssertLessThan(try XCTUnwrap(fine.cellFloorDensestMM),
                          try XCTUnwrap(coarse.cellFloorDensestMM))
    }

    /// Dragging still feels the way it shipped — half-millimetre detents. Only
    /// TYPING became exact, so this is a widening with no change to the old gesture.
    func testDraggingStillLandsOnHalfMillimetres() {
        let b = bounds(lineWidthMM: 0.45)
        XCTAssertEqual(LatticeCellEntry.dragged(8.3, b), 8.5, accuracy: 1e-9)
        XCTAssertEqual(LatticeCellEntry.dragged(8.1, b), 8.0, accuracy: 1e-9)
    }

    /// With no line width there is no core floor to read, so the control keeps its
    /// own honest start of range rather than inventing one.
    func testWithNoLineWidthTheControlFallsBackToItsOwnStart() {
        let b = bounds(lineWidthMM: 0)
        XCTAssertNil(b.cellFloorMM)
        XCTAssertNil(b.cellFloorDensestMM)
        XCTAssertEqual(LatticeCellEntry.entryFloorMM(b),
                       LatticeCellEntry.fallbackFloorMM, accuracy: 1e-9)
        XCTAssertEqual(LatticeCellEntry.entryFloorMM(nil),
                       LatticeCellEntry.fallbackFloorMM, accuracy: 1e-9)
    }

    /// A cell under core's LIGHT floor is legal and says what actually happens on
    /// each path — it is not a prohibition, because core does not prohibit it.
    func testACellUnderTheLightFloorExplainsWhatEachPathDoes() throws {
        var s = LatticeSettings(enabled: true)
        s.cellMM = 1.2
        let b = LatticeBounds.compute(
            settings: s, limits: TopOptKit.latticeLimits(topology: "octet"),
            generatable: true, memberMM: 0, lineWidthMM: 0.45)
        let why = try XCTUnwrap(b.cellReason)
        XCTAssertTrue(why.contains("LIGHTEST"), why)
        XCTAssertTrue(why.contains("uniform run builds the cell you typed"), why)
        XCTAssertTrue(b.runnableAsCertified,
                      "a sub-floor cell was never a run gate and still is not")
    }

    /// Under the DENSE floor nothing prints at any density — a different fact, and
    /// it must not be dressed up as the light-floor message.
    func testACellUnderTheDenseFloorSaysNothingPrints() throws {
        var s = LatticeSettings(enabled: true)
        s.cellMM = 0.2
        let b = LatticeBounds.compute(
            settings: s, limits: TopOptKit.latticeLimits(topology: "octet"),
            generatable: true, memberMM: 0, lineWidthMM: 0.45)
        let why = try XCTUnwrap(b.cellReason)
        XCTAssertTrue(why.contains("no lattice prints"), why)
    }

    /// S3's second question: where does `min_extrudable_width_mm` come from, and
    /// does it match a real 0.45 mm bead? It is the user's OUTER wall line width,
    /// and the range covers it.
    func testTheExtrusionWidthTheGradingLawReadsIsTheUsersOuterWallWidth() throws {
        var p = PrintParams.fdmDefault
        p.wallLineWidthOuterMM = 0.45
        var s = Self.gradedSettings()
        s.retainSubfloorInUnloadedRegions = false
        let spec = try XCTUnwrap(s.runSpec(lineWidthMM: p.wallLineWidthOuterMM,
                                           capability: .all))
        XCTAssertEqual(spec.minExtrudableWidthMM, 0.45)
        let grading = try XCTUnwrap(
            try Self.optimizeJob(lattice: spec)["grading"] as? [String: Any])
        XCTAssertEqual(grading["min_extrudable_width_mm"] as? Double, 0.45,
                       "every derivation in the pre-flight messages is computed "
                       + "from this number, so it must be the user's own")
        XCTAssertTrue(PrintParams.lineWidthRange.contains(0.45),
                      "0.45 mm must be settable in print settings")
    }

    // MARK: - S4 · the receipt survives the trip to the screen

    func testThePerRegionBreakdownReachesTheResultsLines() throws {
        let receipt = Self.receiptJSON(rows: [
            Self.row(id: 1, candidate: 900, latticed: 900, solid: 0,
                     verdict: "certified"),
            Self.row(id: 2, candidate: 1257, latticed: 0, solid: 1257,
                     verdict: "no_pair", nozzle: 0.31),
        ])
        let report = LatticeReport(
            topologyID: "octet", cellMM: 4.6, generateRelativeDensity: 0.5,
            minRelativeDensity: 0.2, maxRelativeDensity: 0.5,
            regionScoped: true, emittedRegions: 2,
            generated: LatticeReport.Generated(
                emitSTL: true, emit3MF: false, latticedCells: 900,
                regionVoxels: 2157, triangles: 100_000,
                strutRadiusMinMM: 0.3, strutRadiusMaxMM: 0.6),
            strut: nil, regionCellsJSON: receipt)
        let lines = ResultsModel.latticeNotes(report)
        XCTAssertTrue(lines.contains { $0.contains("1 of 2 regions received NO lattice") },
                      "the empty region must be on the results screen: \(lines)")
        XCTAssertTrue(lines.contains { $0.contains("0 of 1,257 voxels latticed") })
        XCTAssertTrue(lines.contains { $0.contains("VOXELS") },
                      "the scope note must travel with the numbers")
    }

    /// ★ THE RUN THAT NEEDED IT MOST. A lattice that produced nothing takes an
    /// early return in the notes builder; the breakdown must still be there, or it
    /// is missing on exactly the run the maintainer would be reading it for.
    func testTheBreakdownAlsoShowsWhenTheLatticeProducedNothing() throws {
        let report = LatticeReport(
            topologyID: "octet", cellMM: 8, generateRelativeDensity: 0.5,
            minRelativeDensity: 0.2, maxRelativeDensity: 0.5,
            regionScoped: true, emittedRegions: 7,
            generated: LatticeReport.Generated(
                emitSTL: true, emit3MF: false, latticedCells: 0,
                regionVoxels: 1257, triangles: 0,
                strutRadiusMinMM: 0, strutRadiusMaxMM: 0),
            strut: nil,
            regionCellsJSON: Self.receiptJSON(rows: [
                Self.row(id: 1, candidate: 1257, latticed: 0, solid: 1257,
                         verdict: "no_pair", nozzle: 0.31)]))
        let lines = ResultsModel.latticeNotes(report)
        XCTAssertTrue(lines.contains { $0.contains("NO LATTICE WAS PRODUCED") })
        XCTAssertTrue(lines.contains { $0.contains("NONE of your regions received any lattice") },
                      "the per-region breakdown must survive the early return: \(lines)")
    }

    /// A run that did not ask for it adds no lines at all.
    func testAReportWithoutTheBreakdownAddsNothing() {
        let report = LatticeReport(
            topologyID: "octet", cellMM: 4.6, generateRelativeDensity: 0.5,
            minRelativeDensity: 0.2, maxRelativeDensity: 0.5,
            regionScoped: false, emittedRegions: 0,
            generated: LatticeReport.Generated(
                emitSTL: true, emit3MF: false, latticedCells: 900,
                regionVoxels: 900, triangles: 10,
                strutRadiusMinMM: 0.3, strutRadiusMaxMM: 0.6),
            strut: nil, regionCellsJSON: nil)
        let lines = ResultsModel.latticeNotes(report)
        XCTAssertFalse(lines.contains { $0.contains("Per region") })
    }

    /// THE OUTCOME STORE MUST MIRROR IT. A reopened run that forgot which of its
    /// regions got nothing would silently lose the one number this task exists to
    /// put on screen — the exact class of drop this store has shipped before.
    func testTheBreakdownSurvivesTheOutcomeStoreRoundTrip() throws {
        let receipt = Self.receiptJSON(rows: [
            Self.row(id: 1, candidate: 1257, latticed: 0, solid: 1257,
                     verdict: "no_pair", nozzle: 0.31)])
        let outcome = OptimizeOutcome(
            variants: [], stoppedOnMargin: false, cancelled: false,
            acceptedCount: 0,
            latticeReport: LatticeReport(
                topologyID: "octet", cellMM: 4.6, generateRelativeDensity: 0.5,
                minRelativeDensity: 0.2, maxRelativeDensity: 0.5,
                regionScoped: true, emittedRegions: 1,
                generated: nil, strut: nil, regionCellsJSON: receipt))
        let round = try OutcomeCodec.decode(
            try OutcomeCodec.encode(OutcomeCodec.dto(from: outcome)))
        XCTAssertEqual(round.latticeReport?.regionCellsJSON, receipt)
        XCTAssertTrue(ResultsModel.latticeNotes(round.latticeReport)
            .contains { $0.contains("NONE of your regions received any lattice") })
    }

    /// Retention itself has been in core since PR 295, so THIS is not conditional:
    /// if the vendored core cannot take the switch, the app is built against a core
    /// older than the feature and the whole task is moot — say so loudly.
    func testTheLinkedCoreTakesTheRetentionSwitch() {
        XCTAssertTrue(
            LatticeRetentionCapability.fromCore.retention,
            "core has parsed retain_subfloor_in_unloaded_regions since PR 295")
        XCTAssertTrue(LatticeRetentionCapability.fromCore.stressFraction)
        XCTAssertGreaterThan(LatticeRetentionCapability.coreStressFractionDefault, 0)
        XCTAssertLessThanOrEqual(LatticeRetentionCapability.coreStressFractionDefault, 1)
    }
}
