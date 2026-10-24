// FlexibleRound9HookTests — the eyeball / re-run / Duplicate hooks laid in shared files, pinned by text,
// and their behaviour. The reviewer's ruling of 2026-10-24 04:31 (approved by the maintainer):
//   (1) each hook once at its anchor with its comment; a gate-removed copy goes red.
//   (2) the eye is VIEW-ONLY: the Topology job is identical with a group hidden and shown.
//   (3) a finished project is never re-run without the card; [Cancel] changes nothing; [Save as new
//       project] only on Optimize's card, never the Lattice run's; takeRunOnOpen is one-shot.
//   (4) a copy carries the WHOLE setup and no results; the original's files stay byte-identical; the
//       copy's thumbnail shows no result (it is the imported part's, never re-rendered after a run).
//   (5) H53: a switch to a DIFFERENT project gets a fresh workspace; the same project keeps its own.
import XCTest
import CryptoKit
import TopOptKit
@testable import TopOptFlows

@MainActor
final class FlexibleRound9HookTests: XCTestCase {

    struct Hook { let id: String; let file: String; let pin: String; let gate: String? }

    static let ws = "app/TopOptKit/Sources/TopOptFlows/WorkspacePlaceholder.swift"
    static let home = "app/TopOptKit/Sources/TopOptFlows/HomeView.swift"
    static let root = "app/TopOptKit/Sources/TopOptFlows/RootView.swift"
    static let app = "app/TopOptKit/Sources/TopOptFlows/AppModel.swift"

    static let hooks: [Hook] = [
        Hook(id: "H49a", file: ws, pin: "        return project.groupView.showing(project.clearanceVolumes()) { $0.groupID }.map {   // Flexible (PR #362) H49a",
             gate: "project.groupView.showing("),
        Hook(id: "H49b", file: ws, pin: "        for entry in project.groupView.showing(project.clearanceHandles(), group: { $0.groupID }) {   // Flexible (PR #362) H49b",
             gate: "project.groupView.showing("),
        Hook(id: "H49c", file: ws, pin: "        if let proj = projection, let gid = selection.activeGroupID, project.groupView.drawsPrimitiveKnobs(forActive: gid) {   // Flexible (PR #362) H49c",
             gate: ", project.groupView.drawsPrimitiveKnobs(forActive: gid)"),
        Hook(id: "H50a", file: ws, pin: "        if let last = lastRunRequest, RerunCard.greysOut(sameInputsAsLastRun: model.makeRunRequest() == last, existing: run.outcome) { return false }   // Flexible (PR #362) H50a",
             gate: "RerunCard.greysOut("),
        Hook(id: "H50b", file: ws, pin: "        .alert(RerunCard.title, isPresented: replacementPromptBinding) {   // Flexible (PR #362) H50b", gate: nil),
        Hook(id: "H50b-copy", file: ws, pin: "            if rerunOffersCopy { Button(RerunCard.saveAsNewLabel) { pendingReplacement = nil; if let copy = model.duplicateProject(id: project.id) { RerunCard.runOnOpen(copy.id); model.open(copy) } else { model.toast = RerunCard.copyFailedToast } } }   // Flexible (PR #362) H50b",
             gate: "if rerunOffersCopy { "),
        Hook(id: "H50b-cancel", file: ws, pin: "            Button(RerunCard.cancelLabel, role: .cancel) { pendingReplacement = nil }   // Flexible (PR #362) H50b", gate: nil),
        Hook(id: "H50c", file: ws, pin: "                .onAppear { if RerunCard.takeRunOnOpen(for: project.id) { if canOptimize { startRun() } else { model.toast = RerunCard.copyNotReadyToast } } }   // Flexible (PR #362) H50c",
             gate: "if RerunCard.takeRunOnOpen(for: project.id) "),
        Hook(id: "H50d-state", file: ws, pin: "    @State private var rerunOffersCopy = false   // Flexible (PR #362) H50d", gate: nil),
        Hook(id: "H50d-optimize", file: ws, pin: "            rerunOffersCopy = true; pendingReplacement = prompt   // Flexible (PR #362) H50d", gate: nil),
        Hook(id: "H50d-lattice", file: ws, pin: "            rerunOffersCopy = false; pendingReplacement = prompt   // Flexible (PR #362) H50d", gate: nil),
        Hook(id: "H51-param", file: home, pin: "    var onDuplicate: () -> Void = {}   // Flexible (PR #362) H51", gate: nil),
        Hook(id: "H51-menu", file: home, pin: "            Button { onDuplicate() } label: { Label(\"Duplicate\", systemImage: \"plus.square.on.square\") }   // Flexible (PR #362) H51", gate: nil),
        Hook(id: "H51-call", file: home, pin: "                                          onDuplicate: { _ = model.duplicateProject(id: proj.id) })   // Flexible (PR #362) H51", gate: nil),
        Hook(id: "H52", file: app, pin: "    @discardableResult public func duplicateProject(id: UUID) -> RecentProject? {   // Flexible (PR #362) H52", gate: nil),
        Hook(id: "H53", file: root, pin: "                        .id(project.id)   // Flexible (PR #362) H53", gate: nil),
    ]

    static func source(_ file: String) throws -> String {
        try String(contentsOf: FlexibleHisProject.repoRoot.appendingPathComponent(file), encoding: .utf8)
    }

    static func failures(_ files: [String: String]) -> [String] {
        var out: [String] = []
        for h in hooks {
            let n = (files[h.file] ?? "").components(separatedBy: h.pin).count - 1
            if n != 1 { out.append("\(h.id): the hook appears \(n) times (must be exactly once)") }
            if let g = h.gate, !h.pin.contains(g) { out.append("\(h.id): its gate is not in it") }
        }
        let ws = files[Self.ws] ?? ""
        // the old, ungated forms are gone
        for old in ["        return project.clearanceVolumes().map {\n",
                    "        for entry in project.clearanceHandles() {\n",
                    "        if let last = lastRunRequest, model.makeRunRequest() == last { return false }\n",
                    "Button(\"Optimize anyway\"", "Button(\"Keep my results\""] where ws.contains(old) {
            out.append("an old ungated line is still there: \(old.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        // H50d: Optimize's request sets the flag true, the Lattice run's false — in that order in the file.
        let optimize = ws.range(of: "    private func requestRun() {")
        let lattice = ws.range(of: "    private func requestLatticeRun() {")
        let setTrue = ws.range(of: "rerunOffersCopy = true; pendingReplacement = prompt")
        let setFalse = ws.range(of: "rerunOffersCopy = false; pendingReplacement = prompt")
        if let o = optimize, let l = lattice, let t = setTrue, let f = setFalse {
            if !(o.upperBound < t.lowerBound && t.lowerBound < l.lowerBound && l.upperBound < f.lowerBound) {
                out.append("H50d: the flag is not set inside the right request")
            }
        } else { out.append("H50d: requestRun / requestLatticeRun / the flag lines not found") }
        // every replacement prompt goes through a flag line (no ungated `pendingReplacement = prompt`)
        let bare = ws.components(separatedBy: "\n").filter {
            $0.trimmingCharacters(in: .whitespaces) == "pendingReplacement = prompt"
        }
        if !bare.isEmpty { out.append("H50d: \(bare.count) prompt(s) raised without setting the flag") }
        return out
    }

    private func files() throws -> [String: String] {
        var f: [String: String] = [:]
        for h in Self.hooks where f[h.file] == nil { f[h.file] = try Self.source(h.file) }
        return f
    }

    // ── (1) pins ────────────────────────────────────────────────────────────

    func testEveryHookIsPinnedOnceWithItsGate() throws {
        XCTAssertEqual(Self.failures(try files()), [])
    }

    func testAGateRemovedCopyGoesRed() throws {
        let real = try files()
        for h in Self.hooks {
            guard let g = h.gate else { continue }
            var f = real
            f[h.file] = f[h.file]!.replacingOccurrences(of: h.pin, with: h.pin.replacingOccurrences(of: g, with: ""))
            XCTAssertFalse(Self.failures(f).isEmpty, "\(h.id): removing its gate must go red")
        }
        var f = real
        f[Self.ws] = f[Self.ws]!.replacingOccurrences(of: "rerunOffersCopy = false; pendingReplacement = prompt",
                                                      with: "pendingReplacement = prompt")
        XCTAssertFalse(Self.failures(f).isEmpty, "H50d: a Lattice prompt without the flag must go red")
    }

    // ── fixtures ────────────────────────────────────────────────────────────

    private static var materialsPath: String { FlexibleHisProject.repoRoot.appendingPathComponent("core/src/materials/materials.json").path }
    private static var rulesPath: String { FlexibleHisProject.repoRoot.appendingPathComponent("core/src/settings/rules.json").path }
    private static var cubeSTL: String { FlexibleHisProject.repoRoot.appendingPathComponent("core/tests/fixtures/stl/cube_10mm.stl").path }

    private var tempDir: URL!
    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("topopt-round9-\(UUID().uuidString)", isDirectory: true)
    }
    override func tearDownWithError() throws {
        if let tempDir { try? FileManager.default.removeItem(at: tempDir) }
    }

    /// A cube project with a full load case (anchor + load + gravity).
    private func loadedProject(name: String = "Cube.stl") throws -> (AppModel, ProjectModel, anchor: UUID, load: UUID) {
        let m = AppModel(materialsPath: Self.materialsPath, rulesPath: Self.rulesPath,
                         store: ProjectStore(rootDir: tempDir))
        m.loadMaterials()
        m.newTopOpt()
        m.selectMaterial("PLA")
        XCTAssertTrue(m.importFile(atPath: Self.cubeSTL, displayName: name))
        m.continueToWorkspace()
        let p = try XCTUnwrap(m.project)
        let anchor = p.selection.addGroup()
        p.selection.pickFace(10)
        p.force.makeAnchor(anchor)
        let load = p.selection.addGroup()
        p.selection.pickFace(20)
        p.force.makeLoad(load)
        p.force.setWeight(load, kg: 4.2)
        p.force.setGravity(direction: SIMD3<Float>(0, -1, 0))
        return (m, p, anchor, load)
    }

    private func jobJSON(_ m: AppModel) throws -> Data {
        let req = try XCTUnwrap(m.makeRunRequest())
        let cfg = RemoteRunnerConfig(host: "127.0.0.1", port: 8757, expectedFingerprint: "test")
        return try RemoteRun(config: cfg, request: req, progress: { _, _, _ in true }, onVariant: { _ in }).buildJobJSON()
    }

    // ── (2) the eye is view-only ────────────────────────────────────────────

    func testAHiddenGroupStillTakesPartInTheRun() throws {
        let (m, p, anchor, load) = try loadedProject()
        let shown = try jobJSON(m)
        p.groupView.toggleHidden(anchor)
        p.groupView.toggleHidden(load)
        XCTAssertTrue(p.groupView.isHidden(anchor) && p.groupView.isHidden(load), "premise: both hidden")
        let hidden = try jobJSON(m)
        XCTAssertEqual(try JSONSerialization.jsonObject(with: hidden) as? NSDictionary,
                       try JSONSerialization.jsonObject(with: shown) as? NSDictionary,
                       "the Topology job is identical with the groups hidden and shown")
        XCTAssertEqual(m.makeRunRequest(), { p.groupView.toggleHidden(anchor); p.groupView.toggleHidden(load); return m.makeRunRequest() }())
    }

    func testShowingTheGroupAgainRestoresItsItemsExactly() {
        let a = UUID(), b = UUID()
        let items = [(a, 1), (b, 2), (a, 3)]
        var v = GroupViewState()
        v.toggleHidden(a)
        XCTAssertEqual(v.showing(items) { $0.0 }.map(\.1), [2])
        v.toggleHidden(a)
        XCTAssertEqual(v.showing(items) { $0.0 }.map(\.1), [1, 2, 3])
        XCTAssertTrue(v.drawsPrimitiveKnobs(forActive: a))
    }

    // ── (3) re-run ──────────────────────────────────────────────────────────

    /// The only path from a finished project to `startRun` is the card: requestRun raises it when results
    /// exist, and startRun is reached directly only through [Re-run here] and the copy's one-shot onAppear.
    func testAFinishedProjectIsNeverReRunWithoutTheCard() throws {
        let ws = try Self.source(Self.ws)
        let body = try XCTUnwrap(ws.range(of: "    private func requestRun() {").map { String(ws[$0.lowerBound...].prefix(400)) })
        let prompt = try XCTUnwrap(body.range(of: "ResultsReplacementPrompt.forNewRun(existing: run.outcome)"))
        let start = try XCTUnwrap(body.range(of: "startRun()"))
        XCTAssertLessThan(prompt.lowerBound, start.lowerBound, "the card is asked for before the run starts")
        let callers = ws.components(separatedBy: "startRun()").count - 1
        // requestRun's fall-through, [Re-run here], the copy's onAppear, and startRun's own declaration.
        XCTAssertEqual(callers, 4, "a new startRun() caller must be reviewed against the card")
    }

    func testCancelChangesNothing() throws {
        let ws = try Self.source(Self.ws)
        XCTAssertTrue(ws.contains("Button(RerunCard.cancelLabel, role: .cancel) { pendingReplacement = nil }"),
                      "Cancel only dismisses the card")
    }

    func testTheCopysRunIsOneShot() {
        let copy = UUID()
        RerunCard.runOnOpen(copy)
        XCTAssertTrue(RerunCard.takeRunOnOpen(for: copy), "the copy runs as it opens")
        XCTAssertFalse(RerunCard.takeRunOnOpen(for: copy), "reopening the copy later does not run it again")
    }

    // ── (4) duplicate ───────────────────────────────────────────────────────

    private func folderHashes(_ dir: URL) throws -> [String: String] {
        var out: [String: String] = [:]
        for name in try FileManager.default.contentsOfDirectory(atPath: dir.path) {
            let d = try Data(contentsOf: dir.appendingPathComponent(name))
            out[name] = SHA256.hash(data: d).map { String(format: "%02x", $0) }.joined()
        }
        return out
    }

    /// The decoded setup with only the four fields a copy changes normalised. Compared as VALUES, not JSON
    /// text: sets encode in hash order, so two saves of one setup can differ byte-for-byte.
    private func setup(_ store: ProjectStore, _ id: UUID) throws -> ProjectSnapshot {
        var s = try XCTUnwrap(store.snapshot(id: id))
        s.id = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!
        s.name = ""; s.savedAt = Date(timeIntervalSince1970: 0); s.optimized = nil
        return s
    }

    func testTheCopyCarriesTheWholeSetupAndTheOriginalIsUntouched() throws {
        let (m, p, _, _) = try loadedProject()
        p.printParams.strutLineWidthMM = 0.62
        p.lattice.enabled = true
        p.lattice.flexible = FlexibleStageSettings(materialID: "varioshore_tpu")
        m.persistCurrentProject()
        XCTAssertNotNil(try XCTUnwrap(ProjectStore(rootDir: tempDir).snapshot(id: p.id)).lattice?.flexible, "premise: the Flexible settings are saved")
        let srcDir = tempDir.appendingPathComponent(p.id.uuidString)
        m.backHome()   // the Library path: on Home, the original is not re-saved by a Duplicate
        // a paint + clearance sidecar and full results beside the original (after Home's save, which syncs
        // sidecars from the import path)
        let model = srcDir.appendingPathComponent(try XCTUnwrap(ProjectStore(rootDir: tempDir).snapshot(id: p.id)).modelFileName)
        try Data("faces".utf8).write(to: URL(fileURLWithPath: model.path + ".faces"))
        try Data("{}".utf8).write(to: URL(fileURLWithPath: model.path + ".clearances.json"))
        let store = ProjectStore(rootDir: tempDir)
        try store.saveResults(Data("results".utf8), id: p.id)
        try store.saveRelatticeArtifacts(jobJSON: Data("{}".utf8), designBin: Data([1]), id: p.id)
        let before = try folderHashes(srcDir)

        let copy = try XCTUnwrap(m.duplicateProject(id: p.id))
        let copyDir = tempDir.appendingPathComponent(copy.id.uuidString)

        XCTAssertEqual(try folderHashes(srcDir), before, "the original's files are byte-identical")
        XCTAssertEqual(try setup(store, copy.id), try setup(store, p.id),
                       "groups, loads, face regions, lattice + Flexible settings, print settings all carried")
        let names = Set(try FileManager.default.contentsOfDirectory(atPath: copyDir.path))
        XCTAssertTrue(names.contains(model.lastPathComponent + ".faces"))
        XCTAssertTrue(names.contains(model.lastPathComponent + ".clearances.json"))
        XCTAssertFalse(names.contains("results.plist"))
        XCTAssertFalse(names.contains("run_job.json"))
        XCTAssertFalse(names.contains("run_design.bin"))
        XCTAssertFalse(copy.optimized)
        XCTAssertEqual(copy.name, "Cube copy")
        let idx = try XCTUnwrap(m.recentProjects.firstIndex { $0.id == p.id })
        XCTAssertEqual(m.recentProjects[idx + 1].id, copy.id, "the copy sits beside the original")
    }

    /// The Library thumbnail is the IMPORTED part's (`viewerMesh`), rendered once and never re-rendered
    /// after a run — so the copy's reused thumbnail cannot show a result.
    func testThumbnailsAreOnlyEverRenderedFromTheImportedPart() throws {
        let src = try Self.source(Self.app)
        let calls = src.components(separatedBy: "generateThumbnail(for: ").dropFirst().map { $0.prefix(60) }
        XCTAssertEqual(calls.count, 2, "continueToWorkspace + open")
        for c in calls { XCTAssertTrue(c.contains("viewerMesh"), "\(c)") }
    }

    // ── (5) H53 ─────────────────────────────────────────────────────────────

    /// The workspace's identity is the project id: a switch to the copy is a new id (fresh state, its own
    /// onAppear); reopening the same project from Home keeps the same id, as today.
    func testTheWorkspaceIdentityFollowsTheProject() throws {
        let (m, p, _, _) = try loadedProject()
        let copy = try XCTUnwrap(m.duplicateProject(id: p.id))
        m.open(copy)
        XCTAssertEqual(m.project?.id, copy.id)
        XCTAssertNotEqual(m.project?.id, p.id, "Save as new switches to a different identity")
        m.backHome()
        let original = try XCTUnwrap(m.recentProjects.first { $0.id == p.id })
        m.open(original)
        let first = m.project.map(ObjectIdentifier.init)
        m.backHome()
        m.open(original)
        XCTAssertEqual(m.project?.id, p.id)
        XCTAssertEqual(m.project.map(ObjectIdentifier.init), first, "the same project reopens as the same live model")
    }
}
