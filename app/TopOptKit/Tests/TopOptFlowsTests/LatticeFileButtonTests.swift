// LatticeFileButtonTests — ★ HIS YES 11-17 (Install 3): "Should the main Lattice button make the new engine's file and run the
// strength check?" → "1. Yes." For a regular lattice on a STEP part the Lattice button sends the print file's job (with the
// strength check on Structural) to the Mac, and what the Mac made is the Results screen's one result. His ruling on "pass"
// ("Yes, but only in the structural lattice stage"): the struts must pass too — three states (pass, solid only, fail), the
// file made in all three; Aesthetic is never checked.
//   * the strength block's line says the three states; a core from before the ruling reads as the old gate alone;
//   * the button takes a regular lattice on a STEP part only, with the switch on (RED CONTROLS: Organic, an STL part, the
//     switch off);
//   * the Mac's file, report and views become one result: its mesh, the check's verdict, margins, mass and views, and the
//     struts said on the Results screen (Strength tab and the checks); a "fail" is the not-strong-enough card with the file
//     kept; Aesthetic has no margin and its weight from the file's own volume; an unreadable file is refused;
//   * on the real Lattice Setup with a STEP part: the switch on, the Lattice button never starts the old run (with no Mac it
//     says so in one line); RED CONTROL, the switch off: the old `lattice_part` run starts;
//   * OPT-IN LATTICE_FILE_WORKER=host:port: the button's runner through the real worker makes the result.
#if canImport(AppKit) && canImport(MetalKit)
import XCTest
import SwiftUI
@testable import TopOptFlows
@testable import TopOptKit

@MainActor
final class LatticeFileButtonTests: XCTestCase {

    override func setUp() async throws {
        addTeardownBlock { @MainActor in LatticeFileButton.testWired = nil; RunModel.hostedTestRunner = nil }
    }

    // MARK: fixtures

    static func strength(_ verdict: String?, accepted: Bool = true, margin: Double = 1.8, strut: [String: Any]? = nil,
                         strutsPass: Bool = false) -> [String: Any] {
        var b: [String: Any] = ["accepted": accepted, "margin_worst_case": margin, "safety_margin": 1.5, "not_certified": false,
                                "mass_grams": 42.0, "max_effective_von_mises_mpa": 12.5, "margin_in_plane": 2.4,
                                "margin_interlayer": margin, "max_interlayer_tension_mpa": 3.25, "build_direction": [0, 0, 1],
                                "struts_pass": strutsPass, "fields": "fields.bin"]
        if let verdict { b["verdict"] = verdict }
        if let strut { b["strut"] = strut }
        return b
    }

    static func report(_ strength: [String: Any]?) throws -> Data {
        var o: [String: Any] = ["ok": true, "why": "", "layout": ["bars": 120], "mesh": ["mm3": 2000.0, "part_mm3": 8000.0],
                                "print_check": ["clean": true, "posts": []]]
        if let strength { o["strength"] = strength }
        return try JSONSerialization.data(withJSONObject: o)
    }

    /// A binary STL of one triangle.
    static func stl() -> Data {
        var d = Data(count: 80)
        func u32(_ v: UInt32) { var x = v.littleEndian; d.append(Data(bytes: &x, count: 4)) }
        func f32(_ v: Float) { var x = v.bitPattern.littleEndian; d.append(Data(bytes: &x, count: 4)) }
        u32(1)
        for v: Float in [0, 0, 1, 0, 0, 0, 10, 0, 0, 0, 10, 0] { f32(v) }
        d.append(Data(count: 2))
        return d
    }

    /// fields.bin v1 (core/include/topopt/fields.hpp): a 2×2×2 grid, one block.
    static func fields() -> Data {
        var d = Data([1, 0, 0, 0])
        func i32(_ v: Int32) { var x = v.littleEndian; d.append(Data(bytes: &x, count: 4)) }
        func i64(_ v: Int64) { var x = v.littleEndian; d.append(Data(bytes: &x, count: 8)) }
        func f64(_ v: Double) { var x = v.bitPattern.littleEndian; d.append(Data(bytes: &x, count: 8)) }
        func f32(_ v: Float) { var x = v.bitPattern.littleEndian; d.append(Data(bytes: &x, count: 4)) }
        i32(2); i32(2); i32(2); f64(0); f64(0); f64(0); f64(5); f64(125); i32(1); i32(0)
        f64(0.25); f64(41); i32(3); i32(0); i64(8); i64(0); i64(81)
        for k in 0..<8 { f32(Float(k)) }
        for _ in 0..<81 { f32(0.01) }
        return d
    }

    static func made(_ strength: [String: Any]?, stl given: Data? = nil) throws -> LatticeFileRun.Made {
        let rd = try report(strength)
        return LatticeFileRun.Made(stl: given ?? stl(), report: try XCTUnwrap(LatticeFileReport.parse(rd)), reportJSON: rd,
                                   fields: strength == nil ? nil : fields(), scenarioFields: nil,
                                   timing: RunTiming(queuedSeconds: 2, solveSeconds: 30))
    }

    // MARK: the three states

    func testHisThreeStatesEachInOneLine() throws {
        let pass = LatticeFileStrength(block: Self.strength("pass", strut: ["margin_worst_case": 2.1], strutsPass: true))
        XCTAssertEqual(pass.verdict, .pass)
        XCTAssertEqual(pass.line, "Strong enough · margin 1.8× · 42 g")
        XCTAssertEqual(pass.strutsLine, "Keep the margin · 2.1×")

        let solid = LatticeFileStrength(block: Self.strength("solid_only", strut: ["margin_worst_case": 1.2]))
        XCTAssertEqual(solid.verdict, .solidOnly)
        XCTAssertEqual(solid.strutsLine, "Do not keep the margin · 1.2×, needs 1.5×", "★ solid only: the struts' own margin")
        XCTAssertEqual(solid.line, "Solid strong enough · margin 1.8× · struts: do not keep the margin · 1.2×, needs 1.5×")

        let noRule = LatticeFileStrength(block: Self.strength("solid_only", strut: ["uncertified": true]))
        XCTAssertEqual(noRule.strutsLine, "This lattice type has no strut rule", "★ or that this type has no strut rule")
        XCTAssertEqual(noRule.line, "Solid strong enough · margin 1.8× · struts: this lattice type has no strut rule")

        let fail = LatticeFileStrength(block: Self.strength("fail", accepted: false, margin: 0.7))
        XCTAssertEqual(fail.verdict, .fail)
        XCTAssertEqual(fail.line, "Not strong enough · margin 0.7×, needs 1.5×")

        // a core from before the ruling: the old gate's word alone (the Export bar's lines stand)
        XCTAssertEqual(LatticeFileStrength(block: Self.strength(nil)).verdict, .pass)
        XCTAssertEqual(LatticeFileStrength(block: Self.strength(nil, accepted: false)).verdict, .fail)
        XCTAssertNil(LatticeFileStrength(block: Self.strength(nil)).strutsLine, "no strut block: nothing said about them")
    }

    // MARK: which parts

    func testTheButtonTakesARegularLatticeOnAStepPartOnly() {
        let l = LatticeSettings()
        XCTAssertTrue(LatticeFileButton.takes(l, modelPath: "/a/l bracket 3.step", wired: true), "★ a regular lattice, a STEP part")
        XCTAssertTrue(LatticeFileButton.takes(l, modelPath: "/a/PART.STP", wired: true))
        var aesthetic = l
        aesthetic.chooseLatticeType(.aesthetic)
        XCTAssertTrue(LatticeFileButton.takes(aesthetic, modelPath: "/a/p.step", wired: true), "Aesthetic too (never checked)")
        var organic = l
        organic.algorithm = "organic"
        XCTAssertFalse(LatticeFileButton.takes(organic, modelPath: "/a/p.step", wired: true), "RED CONTROL: Organic keeps the old run")
        XCTAssertFalse(LatticeFileButton.takes(l, modelPath: "/a/model.stl", wired: true), "RED CONTROL: an STL part keeps the old run")
        XCTAssertFalse(LatticeFileButton.takes(l, modelPath: nil, wired: true))
        XCTAssertFalse(LatticeFileButton.takes(l, modelPath: "/a/p.step", wired: false), "RED CONTROL: the switch off")
        XCTAssertFalse(LatticeFileButton.takes(l, modelPath: "/a/p.step"), "★ production: off until the strength core is merged")
    }

    // MARK: the result

    func testTheMacsFileIsTheResultsScreensOneResult() throws {
        // solid only: accepted (the old gate), the struts said on the Results screen
        let o = try LatticeFileButton.outcome(try Self.made(Self.strength("solid_only", strut: ["margin_worst_case": 1.2])),
                                              densityGCm3: 1.24)
        XCTAssertEqual(o.variants.count, 1, "★ one result")
        let v = o.variants[0]
        XCTAssertEqual(v.meshIndices.count, 3, "★ the file's own mesh")
        XCTAssertEqual(v.meshVertices.count, 9)
        XCTAssertTrue(v.accepted)
        XCTAssertEqual(o.acceptedCount, 1)
        XCTAssertEqual(v.worstCaseMargin, 1.8)
        XCTAssertEqual(v.massGrams, 42, "the check's mass")
        XCTAssertEqual(v.inPlaneMargin, 2.4)
        XCTAssertEqual(v.interlayerMargin, 1.8)
        XCTAssertEqual(v.maxStressMPa, 12.5)
        XCTAssertEqual(v.maxInterlayerTensionMPa, 3.25)
        XCTAssertEqual(v.orientation, SIMD3(0, 0, 1))
        XCTAssertEqual(v.achievedVolumeFraction, 0.25, accuracy: 1e-12, "the file's plastic over the solid part's")
        XCTAssertEqual(v.vonMisesField.count, 8, "★ the check's own views")
        XCTAssertEqual(v.displacementField.count, 81)
        XCTAssertEqual(o.gridNx, 2)
        XCTAssertEqual(o.spacing, 5)
        XCTAssertTrue(o.computedRemotely)
        XCTAssertEqual(o.timing?.solveSeconds, 30, "the worker's own record")
        let b = try XCTUnwrap(o.reportJSON.flatMap(RunReportBlocks.decode(reportJSON:)))
        XCTAssertEqual(b.latticeFile?.verdict, .solidOnly)
        XCTAssertEqual(b.safetyMargin, 1.5, "Built for: the check's own safety margin")

        let m = ResultsModel(projectName: "Bracket", outcome: o)
        let rows = ResultsVersions.rows(tabs: m.tabs, blocks: m.reportBlocks, requestedVF: { m.requestedVolumeFraction(of: $0) })
        let details = m.detailRows(.strength, version: try XCTUnwrap(rows.first))
        XCTAssertTrue(details.contains { $0.label == "Struts" && $0.value == "Do not keep the margin · 1.2×, needs 1.5×" },
                      "★ the Strength tab says the struts: \(details)")
        let checks = ResultsChecks.checks(tab: m.selected, margin: 1.8, required: 1.5, safetyMargin: 1.5, scenarios: [],
                                          thinJoints: 0, bridged: false, struts: m.reportBlocks?.latticeFile)
        let strong = try XCTUnwrap(checks.firstIndex { $0.title == "Strong enough" }, "the solid keeps its margin")
        let struts = try XCTUnwrap(checks.firstIndex { $0.title == "Struts not strong enough" }, "★ and the struts do not: \(checks)")
        XCTAssertEqual(checks[struts].kind, .warn)
        XCTAssertEqual(struts, strong + 1, "said right under the solid's line")

        // pass: the struts' check is ok
        let p = try LatticeFileButton.outcome(try Self.made(Self.strength("pass", strut: ["margin_worst_case": 2.1], strutsPass: true)),
                                              densityGCm3: 1.24)
        let pc = ResultsChecks.checks(tab: ResultsModel(projectName: "B", outcome: p).selected, margin: 1.8, required: 1.5,
                                      safetyMargin: 1.5, scenarios: [], thinJoints: 0, bridged: false,
                                      struts: p.reportJSON.flatMap(RunReportBlocks.decode(reportJSON:))?.latticeFile)
        XCTAssertEqual(pc.first { $0.title == "Struts strong enough" }?.kind, .ok)

        // fail: not accepted — the not-strong-enough card, the file kept as its result
        let f = try LatticeFileButton.outcome(try Self.made(Self.strength("fail", accepted: false, margin: 0.7)), densityGCm3: 1.24)
        XCTAssertEqual(f.acceptedCount, 0, "★ fail: the old gate's not-strong-enough")
        XCTAssertFalse(f.variants[0].accepted)
        XCTAssertEqual(f.variants[0].meshIndices.count, 3, "★ never a refusal: the file is made")

        // Aesthetic: never checked — nothing refused, no margin claimed, the weight from the file's own volume
        let a = try LatticeFileButton.outcome(try Self.made(nil), densityGCm3: 1.24)
        XCTAssertTrue(a.variants[0].accepted)
        XCTAssertEqual(a.variants[0].worstCaseMargin, 0)
        XCTAssertEqual(a.variants[0].massGrams, 2.48, accuracy: 1e-9, "2000 mm³ of PLA-ish 1.24 g/cm³")
        XCTAssertNil(a.reportJSON.flatMap(RunReportBlocks.decode(reportJSON:))?.latticeFile, "no strength block")
        let am = ResultsModel(projectName: "A", outcome: a)
        let ar = ResultsVersions.rows(tabs: am.tabs, blocks: am.reportBlocks, requestedVF: { am.requestedVolumeFraction(of: $0) })
        XCTAssertFalse(am.detailRows(.strength, version: ar.first).contains { $0.label == "Struts" }, "Aesthetic: no struts row")

        // RED CONTROL: a file that cannot be read is refused, never an empty part
        XCTAssertThrowsError(try LatticeFileButton.outcome(try Self.made(nil, stl: Data(count: 40)), densityGCm3: 1.24))
    }

    // MARK: on the page

    /// His 'l bracket 3' (a STEP part), through the app's own import, on Lattice Setup with one lattice group saved.
    func bracketOnLatticeSetup() throws -> (AppBuildHost, ProjectModel, AppModel) {
        let dir = FlexiblePressFixtures.frozenDir.appendingPathComponent("his7/92A8016E-FCCD-421D-B19E-4A1EC81C98A5", isDirectory: true)
        try FlexiblePressFixtures.assertFrozen(dir)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("lattice-button-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let core = FlexibleHisProject.repoRoot.appendingPathComponent("core")
        let app = AppModel(materialsPath: core.appendingPathComponent("src/materials/materials.json").path,
                           rulesPath: core.appendingPathComponent("src/settings/rules.json").path, store: ProjectStore(rootDir: root))
        app.loadMaterials()
        app.newTopOpt()
        guard app.importFile(atPath: dir.appendingPathComponent("model.step").path, displayName: "l bracket 3.step") else {
            throw XCTSkip("the STEP importer refused the l bracket: \(app.toast ?? "")")
        }
        app.continueToWorkspace()
        let p = try XCTUnwrap(app.project, "the bracket opens")
        p.force.setGravity(direction: SIMD3(0, 0, -1))
        // a load case (the Lattice stage opens with an anchor, a load and gravity): one face held, one pushed
        let m = try XCTUnwrap(p.viewerMesh, "the bracket's mesh")
        let faces = FaceTopology.faceIDs(in: m)
        XCTAssertGreaterThanOrEqual(faces.count, 3, "premise: the bracket has faces to hold, push and lattice")
        let held = p.selection.addGroup()
        p.selection.addFaces([faces[0]], to: held)
        p.force.makeAnchor(held)
        let pushed = p.selection.addGroup()
        p.selection.addFaces([faces[1]], to: pushed)
        p.force.makeLoad(pushed)
        p.force.setWeight(pushed, kg: 5)
        p.lattice.flexible = nil
        p.lattice.clearLatticeType()
        p.lattice.chooseLatticeType(.structural)
        let h = AppBuildHost(WorkspacePlaceholder(model: app, project: p), size: AppBuildHost.landscape13, test: self)
        h.pump(3)
        try h.pickFromMenu("capsuleMenu", "Structural", what: "the stage menu")
        h.pump(1)
        let f = faces[2]
        _ = p.latticeStageTap(face: f, loop: [f])
        let g = try XCTUnwrap(p.latticeList.activeGroupID)
        p.lattice.groupRoles[g] = .include
        p.lattice.enabled = true   // as Save on the Lattice page leaves it
        p.latticeList.clearActive()
        h.pump(1)
        if h.frames.all["latticeSettingsPanel"] != nil { try h.tap("capsuleSetup", "the page's Save", settle: 1) }
        XCTAssertTrue(p.importedFile?.path.lowercased().hasSuffix(".step") == true, "premise: a STEP part")
        return (h, p, app)
    }

    func testOnTheBracketTheLatticeButtonNeverStartsTheOldRunWithTheSwitchOn() throws {
        let (h, _, app) = try bracketOnLatticeSetup()
        let sent = TopologyEntriesSendNoLatticeHostedTests.Sent()
        RunModel.hostedTestRunner = { req, _, _ in sent.add(req); return AppBuildFixtures.outcome(1) }
        XCTAssertNil(h.frames.all["latticeRefreshButton"], "premise: the Lattice button, not Refresh Lattice")

        LatticeFileButton.testWired = true
        app.toast = nil
        try h.tap("latticeButton", "★ the Lattice button, the switch on", settle: 1)
        let end = Date().addingTimeInterval(8)
        while app.toast == nil, Date() < end { h.pump(0.25) }
        XCTAssertTrue(sent.requests.isEmpty, "★ the old run never starts for a regular lattice on a STEP part")
        XCTAssertEqual(app.toast, LatticeFileButton.noMacLine, "★ no Mac chosen: one line says so")

        LatticeFileButton.testWired = false   // RED CONTROL: the switch off — the old run
        app.toast = nil
        try h.tap("latticeButton", "RED CONTROL: the Lattice button, the switch off", settle: 1)
        let end2 = Date().addingTimeInterval(8)
        while sent.requests.isEmpty, Date() < end2 { h.pump(0.25) }
        XCTAssertEqual(sent.requests.map(\.jobMode), ["lattice_part"], "RED CONTROL: the old Lattice run starts")
    }

    // MARK: opt-in, the real worker

    /// ★ OPT-IN: the button's runner through the real worker on this Mac (no strength check: the release core does not read it).
    func testTheButtonsRunnerThroughTheWorker() throws {
        guard let hp = ProcessInfo.processInfo.environment["LATTICE_FILE_WORKER"], let colon = hp.lastIndex(of: ":"),
              let port = Int(hp[hp.index(after: colon)...]) else { throw XCTSkip("opt-in: LATTICE_FILE_WORKER=host:port") }
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { root.deleteLastPathComponent() }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("lattice-button-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let model = dir.appendingPathComponent("cube.step").path
        try FileManager.default.copyItem(atPath: root.appendingPathComponent("core/tests/fixtures/step/cube.step").path, toPath: model)
        var s = LatticeLayoutSession.Settings()
        s.allLattice = true
        s.cellMM = 5
        let job = try LatticeFileJob.build(s, modelName: "cube.step")
        let config = RemoteRunnerConfig(host: String(hp[..<colon]), port: port, expectedFingerprint: CoreFingerprint.value)
        let run = LatticeFileButton.runner(config: config, job: .init(json: job, modelPath: model, demand: nil),
                                           projectName: "Lattice button cube", strengthJob: nil, densityGCm3: 1.24)
        let req = RunRequest(modelPath: model, material: "PLA", materialsPath: "", rulesPath: "", resolution: 64,
                             projectName: "Lattice button cube")
        let o = try run(req, { _, _, _ in true }, { _ in })
        print("LATTICE-BUTTON cube via the worker: \((o.variants.first?.meshIndices.count ?? 0) / 3) triangles, "
              + "\(o.variants.first?.massGrams ?? 0) g")
        XCTAssertEqual(o.variants.count, 1)
        XCTAssertGreaterThan(o.variants[0].meshIndices.count, 0)
        XCTAssertTrue(o.variants[0].accepted, "Aesthetic-like: no check sent")
    }
}
#endif
