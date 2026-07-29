// JobJSONEquivalenceTests — the mesh-job-params regression gate.
//
// THE BUG this pins (docs/handoffs/2026-07-25-mesh-job-params.md): `RemoteRunner
// .buildJobJSON()` gated the ENTIRE `loads` block behind `RunRequest.isStepModel`.
// A mesh part (.stl/.3mf) therefore serialized to a SKELETON job —
// `{"loads": {"build_dir": [0,0,1]}}` — dropping the anchors, load groups, infill,
// clearances and protections the app had correctly packed. The CLI then fell back
// to the worst-case self-weight / 100%-infill / cold run that OOM-killed. STEP jobs
// carried everything; only the mesh path regressed.
//
// THE CONTRACT this asserts: a mesh job.json and a STEP job.json built from the
// SAME logical RunRequest (same anchors / loads / infill / resolution / design box
// / clearances / protections) are FIELD-EQUIVALENT except the model path. The
// pseudo-face ids the segmenter manufactures ride the SAME face-id fields the STEP
// B-rep ids do (the contract is shared, handoff 134), so with the same selection
// the two job dicts are byte-for-byte equal once `model` is set aside.
//
// This runs with NO worker — it exercises `buildJobJSON()` directly (exposed
// `internal` for exactly this), so it is part of the ordinary `swift test` suite,
// unlike the worker-gated RemoteRunnerE2ETests.

import XCTest
import TopOptKit
@testable import TopOptFlows

@MainActor
final class JobJSONEquivalenceTests: XCTestCase {

    /// One logical run, parameterized only by the model file it points at. Every
    /// physics input — anchors, load groups (with forces), infill, resolution, design
    /// box + keep-outs, clearances, face protections, build direction — is identical
    /// across the two model sources, so any difference in the emitted job.json (beyond
    /// the model path) is a serialization bug, not a difference in the request.
    private func request(modelPath: String) -> RunRequest {
        RunRequest(
            modelPath: modelPath, material: "PLA", materialsPath: "", rulesPath: "",
            resolution: 96, projectName: "field-equivalence",
            anchorFaceIDs: [3, 7],
            loadGroups: [
                TopOptKit.LoadGroupSpec(faceIDs: [11], force: SIMD3(0, 0, -250)),
                TopOptKit.LoadGroupSpec(faceIDs: [12, 13], force: SIMD3(40, 0, 0)),
            ],
            minimizePlastic: true,
            buildDirection: SIMD3(0, 0, 1),
            infillPercent: 40,
            wallLoops: 5,
            // Non-default, DISTINCT outer/inner widths so the parity + carry tests catch
            // a front-end that drops one or swaps them (handoff line-width-plumbing).
            wallLineWidthOuterMM: 0.4,
            wallLineWidthInnerMM: 0.5,
            designBox: TopOptKit.DesignBoxSpec(min: SIMD3(-5, -5, -5),
                                               max: SIMD3(30, 20, 10)),
            keepOutBoxes: [TopOptKit.DesignBoxSpec(min: SIMD3(0, 0, 0),
                                                   max: SIMD3(2, 2, 2))],
            clearances: [
                TopOptKit.ClearanceSpec(faceID: 3, kind: .bolt,
                                        concentricMarginMM: 1.5, axialClearanceMM: 4),
                TopOptKit.ClearanceSpec(faceID: 7, kind: .face, slabDepthMM: 3),
            ],
            faceProtections: [11, 12],
            faceProtectionDepthMM: 5)
    }

    /// Build the job.json a real submit would post, without a worker: construct a
    /// RemoteRun and call the internal serializer.
    private func jobDict(modelPath: String) throws -> [String: Any] {
        let cfg = RemoteRunnerConfig(host: "127.0.0.1", port: 8757,
                                     expectedFingerprint: "test")
        let run = RemoteRun(config: cfg, request: request(modelPath: modelPath),
                            progress: { _, _, _ in true }, onVariant: { _ in })
        let data = try run.buildJobJSON()
        return try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any],
            "job.json must serialize to an object")
    }

    // MARK: the field-equivalence bar

    func testMeshAndStepJobsAreFieldEquivalentExceptModel() throws {
        var step = try jobDict(modelPath: "/tmp/part.step")
        var mesh = try jobDict(modelPath: "/tmp/part.stl")

        // Only the model path — the ONE permitted difference — should differ. (The
        // face-id provenance differs conceptually: STEP ids are B-rep faces, mesh ids
        // are segmentation pseudo-faces. With the same selection they are the same
        // integers, so the field VALUES match; the source is what differs.)
        XCTAssertEqual(step["model"] as? String, "part.step")
        XCTAssertEqual(mesh["model"] as? String, "part.stl")
        step["model"] = nil
        mesh["model"] = nil

        // Everything else must be byte-for-byte identical. NSDictionary.isEqual walks
        // the whole nested structure (loads, groups, clearances, design_box, …).
        XCTAssertEqual(
            (step as NSDictionary), (mesh as NSDictionary),
            "mesh and STEP jobs must be field-equivalent once the model path is set aside")
    }

    // MARK: source_format provenance (handoff 2026-07-26-3mf-optimize-path)

    // A 3MF normalised to an STL working copy ships model=part.stl but records
    // source_format="3mf", so the worker's run_info names the real source. A plain
    // STL/STEP part emits NO source_format key, keeping its job.json byte-identical
    // to before (M2) — the CLI derives "stl"/"step" from the model extension.
    func testSourceFormatEmittedOnlyForANormalisedPart() throws {
        // Plain STL: no source_format key at all.
        let stl = try jobDict(modelPath: "/tmp/part.stl")
        XCTAssertNil(stl["source_format"],
                     "a plain STL part must not add source_format (job stays byte-identical)")

        // 3MF normalised to STL: model is the .stl copy, provenance is "3mf".
        let cfg = RemoteRunnerConfig(host: "127.0.0.1", port: 8757,
                                     expectedFingerprint: "test")
        var req = request(modelPath: "/tmp/part.stl")
        req = RunRequest(
            modelPath: req.modelPath, material: req.material, materialsPath: "",
            rulesPath: "", resolution: req.resolution, projectName: req.projectName,
            anchorFaceIDs: req.anchorFaceIDs, loadGroups: req.loadGroups,
            minimizePlastic: req.minimizePlastic, buildDirection: req.buildDirection,
            infillPercent: req.infillPercent, wallLoops: req.wallLoops,
            wallLineWidthOuterMM: req.wallLineWidthOuterMM,
            wallLineWidthInnerMM: req.wallLineWidthInnerMM,
            designBox: req.designBox,
            keepOutBoxes: req.keepOutBoxes, clearances: req.clearances,
            faceProtections: req.faceProtections,
            faceProtectionDepthMM: req.faceProtectionDepthMM,
            sourceFormat: "3mf")
        let run = RemoteRun(config: cfg, request: req,
                            progress: { _, _, _ in true }, onVariant: { _ in })
        var threeMF = try XCTUnwrap(
            JSONSerialization.jsonObject(with: try run.buildJobJSON()) as? [String: Any])
        XCTAssertEqual(threeMF["model"] as? String, "part.stl",
                       "the optimize path reads the STL working copy, never the .3mf")
        XCTAssertEqual(threeMF["source_format"] as? String, "3mf",
                       "the true source format must ride to the worker's run_info")
        // Otherwise identical to the plain-STL job (only source_format differs).
        threeMF["source_format"] = nil
        XCTAssertEqual((stl as NSDictionary), (threeMF as NSDictionary),
                       "source_format must be the ONLY addition")
    }

    // MARK: the anti-skeleton guard (the exact shape the bug produced)

    func testMeshJobCarriesTheFullLoadCaseNotASkeleton() throws {
        let mesh = try jobDict(modelPath: "/tmp/part.stl")

        // resolution: the UI's choice, NOT the CLI's 128 default.
        XCTAssertEqual(mesh["resolution"] as? Int, 96, "the chosen resolution must be echoed")

        let loads = try XCTUnwrap(mesh["loads"] as? [String: Any],
                                  "a mesh job must carry a loads block")
        // The skeleton was `{"build_dir": [...]}` and nothing else. Assert the load
        // case is actually present.
        XCTAssertEqual(loads["anchor_face_ids"] as? [Int], [3, 7],
                       "anchors (pseudo-face ids) must survive for a mesh")
        XCTAssertEqual(loads["infill_percent"] as? Int, 40,
                       "the chosen infill must survive — not silently 100%")
        XCTAssertEqual(loads["wall_loops"] as? Int, 5,
                       "the chosen wall count must survive — not silently 0 (bare infill)")
        XCTAssertEqual(loads["wall_line_width_mm"] as? Double, 0.5,
                       "the chosen INNER line width must survive — not the 0.45 mm assumption")
        XCTAssertEqual(loads["wall_line_width_outer_mm"] as? Double, 0.4,
                       "the chosen OUTER line width must survive as its own key (the split)")
        XCTAssertEqual(loads["minimize_plastic"] as? Bool, true)

        let groups = try XCTUnwrap(loads["groups"] as? [[String: Any]],
                                   "load groups must survive for a mesh")
        XCTAssertEqual(groups.count, 2, "both load groups serialized")
        XCTAssertEqual(groups.first?["face_ids"] as? [Int], [11])
        XCTAssertEqual(groups.first?["force"] as? [Double], [0, 0, -250])

        let clearances = try XCTUnwrap(loads["clearances"] as? [[String: Any]],
                                       "clearances must survive for a mesh")
        XCTAssertEqual(clearances.count, 2)

        XCTAssertEqual(loads["face_protections"] as? [Int], [11, 12],
                       "face protections must survive for a mesh")
        XCTAssertEqual(loads["face_protection_depth_mm"] as? Double, 5)

        // design_box is emitted above the (former) gate, so it always survived — assert
        // it stays present so a future refactor can't drop it either.
        XCTAssertNotNil(mesh["design_box"], "design box must survive for a mesh")
        XCTAssertNotNil(mesh["keep_outs"], "keep-outs must survive for a mesh")
    }

    /// A mesh job with NO declared load case still carries a well-formed loads block
    /// (minimize_plastic + build_dir) — identical to the STEP no-load-case shape — so
    /// the CLI never mistakes it for the absent-loads self-weight fallback path.
    func testMeshNoLoadCaseMatchesStepNoLoadCase() throws {
        func bare(_ path: String) throws -> [String: Any] {
            let cfg = RemoteRunnerConfig(host: "127.0.0.1", port: 8757,
                                         expectedFingerprint: "test")
            let req = RunRequest(modelPath: path, material: "PLA", materialsPath: "",
                                 rulesPath: "", resolution: 64, projectName: "bare")
            let run = RemoteRun(config: cfg, request: req,
                                progress: { _, _, _ in true }, onVariant: { _ in })
            return try XCTUnwrap(
                JSONSerialization.jsonObject(with: try run.buildJobJSON()) as? [String: Any])
        }
        var step = try bare("/tmp/bare.step")
        var mesh = try bare("/tmp/bare.stl")
        step["model"] = nil
        mesh["model"] = nil
        XCTAssertEqual((step as NSDictionary), (mesh as NSDictionary),
                       "even with no load case, mesh and STEP jobs match once model is set aside")
        XCTAssertNotNil((mesh["loads"] as? [String: Any])?["build_dir"],
                        "the loads block is well-formed, not a skeleton")
    }

    // MARK: wall_loops — the CLI/bridge parity bar (handoff 2026-07-27-wall-loops-plumbing)

    /// W2 — BOTH front-ends agree on the wall-loop count for one project. The LAN
    /// worker path serializes it into `loads.wall_loops`; the on-device path sets it on
    /// `BridgeLoadCase.wall_loops` via `TopOptKit.bridgeWallLoops`. This asserts the two
    /// are the SAME value for the same RunRequest — the bridge/CLI-divergence class that
    /// bit knockdown_spec_for once (a bare scalar reached one path and not the other).
    /// It is the app-side twin of test_production_parity.cpp's knockdown-spec assertion:
    /// there the two front-ends share one C++ builder; here they share one Swift mapping.
    func testWallLoopsAgreeAcrossBridgeAndCLI() throws {
        let mesh = try jobDict(modelPath: "/tmp/part.stl")
        let step = try jobDict(modelPath: "/tmp/part.step")
        let cliMesh = (mesh["loads"] as? [String: Any])?["wall_loops"] as? Int
        let cliStep = (step["loads"] as? [String: Any])?["wall_loops"] as? Int

        // The LAN job.json carries the request's value on BOTH model sources.
        XCTAssertEqual(cliMesh, 5, "mesh LAN job carries the wall count")
        XCTAssertEqual(cliStep, 5, "STEP LAN job carries the wall count")

        // The on-device bridge POD carries the SAME value, through the shared mapping
        // minimizePlasticLoadCase uses to set BridgeLoadCase.wall_loops.
        let bridge = Int(TopOptKit.bridgeWallLoops(forOverride: request(modelPath: "/tmp/part.stl").wallLoops))
        XCTAssertEqual(bridge, 5, "the on-device bridge carries the wall count")
        XCTAssertEqual(cliMesh, bridge, "bridge and CLI must produce the same wall count")
        XCTAssertEqual(cliStep, bridge, "bridge and CLI must produce the same wall count")
    }

    /// W3 — a project that carries no explicit wall count (the reattach carrier, or a
    /// pre-PrintParams project whose params decode to `.fdmDefault`) serializes the FDM
    /// default of 3 walls, never the buggy 0. Both front-ends land on the same default.
    func testWallLoopsDefaultsToTheFDMDefaultNotZero() throws {
        let cfg = RemoteRunnerConfig(host: "127.0.0.1", port: 8757, expectedFingerprint: "test")
        let req = RunRequest(modelPath: "/tmp/bare.stl", material: "PLA", materialsPath: "",
                             rulesPath: "", resolution: 64, projectName: "bare")
        XCTAssertEqual(req.wallLoops, PrintParams.fdmDefault.wallLoops,
                       "an unspecified wall count defaults to the FDM default")
        XCTAssertEqual(req.wallLoops, 3, "the FDM default is 3 walls (the sheet's seed), not 0")
        let run = RemoteRun(config: cfg, request: req, progress: { _, _, _ in true }, onVariant: { _ in })
        let job = try XCTUnwrap(JSONSerialization.jsonObject(with: try run.buildJobJSON()) as? [String: Any])
        XCTAssertEqual((job["loads"] as? [String: Any])?["wall_loops"] as? Int, 3,
                       "the default project still emits a concrete non-zero wall count")
        XCTAssertEqual(Int(TopOptKit.bridgeWallLoops(forOverride: req.wallLoops)), 3,
                       "the on-device path agrees on the default")
    }

    // MARK: wall line widths — the CLI/bridge parity bar (handoff line-width-plumbing)

    /// N2 — BOTH front-ends agree on the outer AND inner wall LINE WIDTHS for one
    /// project, and keep them as SEPARATE keys (option b: the slicer lays down one outer
    /// bead + (loops-1) inner beads). The LAN worker path serializes them into
    /// `loads.wall_line_width_{outer_,}mm`; the on-device path sets them on
    /// `BridgeLoadCase.wall_line_width_{outer_,}mm` via the SAME TopOptKit mappings. This
    /// asserts the two are the same values for the same RunRequest — the bridge/CLI
    /// divergence class that bit knockdown_spec_for once. It is the app-side twin of
    /// test_production_parity.cpp's split-thickness assertion.
    func testWallLineWidthsAgreeAcrossBridgeAndCLI() throws {
        let mesh = try jobDict(modelPath: "/tmp/part.stl")
        let step = try jobDict(modelPath: "/tmp/part.step")
        let req = request(modelPath: "/tmp/part.stl")

        for (label, job) in [("mesh", mesh), ("step", step)] {
            let loads = try XCTUnwrap(job["loads"] as? [String: Any])
            XCTAssertEqual(loads["wall_line_width_mm"] as? Double, 0.5,
                           "\(label) LAN job carries the inner line width")
            XCTAssertEqual(loads["wall_line_width_outer_mm"] as? Double, 0.4,
                           "\(label) LAN job carries the outer line width as its own key")
        }

        // The on-device bridge POD carries the SAME values through the shared mappings
        // minimizePlasticLoadCase uses to set BridgeLoadCase.wall_line_width_{outer_,}mm.
        let bridgeInner = TopOptKit.bridgeWallLineWidthMM(forOverride: req.wallLineWidthInnerMM)
        let bridgeOuter = TopOptKit.bridgeWallLineWidthOuterMM(forOverride: req.wallLineWidthOuterMM)
        XCTAssertEqual(bridgeInner, 0.5, "the bridge carries the inner line width")
        XCTAssertEqual(bridgeOuter, 0.4, "the bridge carries the outer line width")
        XCTAssertEqual((mesh["loads"] as? [String: Any])?["wall_line_width_mm"] as? Double,
                       bridgeInner, "bridge and CLI must produce the same inner width")
        XCTAssertEqual((mesh["loads"] as? [String: Any])?["wall_line_width_outer_mm"] as? Double,
                       bridgeOuter, "bridge and CLI must produce the same outer width")
    }

    /// N4-adjacent — a request built with NO explicit widths (a pre-line-width project
    /// whose params decode to `.fdmDefault`) serializes the stated FDM defaults on both
    /// front-ends: outer 0.42 mm, inner 0.45 mm (the 0.4-nozzle Bambu/Orca profile), never
    /// a dropped key or a bare 0.
    func testWallLineWidthsDefaultToTheStatedFDMDefaults() throws {
        let cfg = RemoteRunnerConfig(host: "127.0.0.1", port: 8757, expectedFingerprint: "test")
        let req = RunRequest(modelPath: "/tmp/bare.stl", material: "PLA", materialsPath: "",
                             rulesPath: "", resolution: 64, projectName: "bare")
        XCTAssertEqual(req.wallLineWidthOuterMM, PrintParams.fdmDefault.wallLineWidthOuterMM)
        XCTAssertEqual(req.wallLineWidthInnerMM, PrintParams.fdmDefault.wallLineWidthInnerMM)
        XCTAssertEqual(req.wallLineWidthOuterMM, 0.42, "stated 0.4-nozzle outer default")
        XCTAssertEqual(req.wallLineWidthInnerMM, 0.45, "stated 0.4-nozzle inner default")
        let run = RemoteRun(config: cfg, request: req, progress: { _, _, _ in true }, onVariant: { _ in })
        let loads = try XCTUnwrap(
            (JSONSerialization.jsonObject(with: try run.buildJobJSON()) as? [String: Any])?["loads"] as? [String: Any])
        XCTAssertEqual(loads["wall_line_width_mm"] as? Double, 0.45,
                       "the default project still emits a concrete inner width")
        XCTAssertEqual(loads["wall_line_width_outer_mm"] as? Double, 0.42,
                       "the default project still emits a concrete outer width")
    }
}
