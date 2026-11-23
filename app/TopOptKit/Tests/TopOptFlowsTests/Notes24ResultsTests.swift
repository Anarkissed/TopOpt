// Notes24ResultsTests — ★ his iPad notes 2026-11-23 (img 4, 5, 6; RESULTS_REPORT §1-§4): his v7 (Structural, Organic) print
// file was made on the Mac while TopOpt sat in the background behind Sidecar; the notification's tap opened the Library, v7's
// card greyed, v7 opening on Topology with no Results, the Lattice stage with none either — the result was never saved. His
// words: "Please find out what the hell is going on?" "Tapping the notification should bring you RIGHT to the result screen.
// Nothing else." "The result should be accessible from the Versions page just by tapping onto the version." "If going to edit
// it, the "results" screen should be in the Lattice Stage." "The result should NOT be greyed out on the version screen."
//
// Model tests (each with its RED control where the pattern exists):
//   1. a finished run's result is saved into its own version folder with the app in the background, inside background time
//      that ends when the file has landed (the run's own held for its whole length); a re-run on a version with results saves
//      its new result (markOptimized's early return never did);
//   2. the Lattice button's jobs are recorded; a recorded job is followed again on launch, fetched, read and saved to its
//      version (a print file's, and a strengthening's that goes on to make its file); a Mac out of reach keeps the record, a
//      job the Mac lost ends it;
//   3. the completion notification carries its version; its tap opens that version with its result to open (a print file's
//      in the Lattice stage);
//   5. the Lattice button's Approved from the SAVED result, across a relaunch.
// Hosted tests (his two iPad sizes): Notes24ResultsHostedTests.
#if canImport(AppKit) && canImport(MetalKit)
import XCTest
import SwiftUI
import AppKit
@testable import TopOptFlows
@testable import TopOptKit

/// Background time, as asked and given back, in order.
@MainActor
final class BackgroundTimeSpy: BackgroundTime {
    enum Event: Equatable { case begin(String, Int), end(Int) }
    private(set) var events: [Event] = []
    private(set) var open: Set<Int> = []
    private var next = 0
    func begin(_ name: String) -> Int {
        next += 1
        open.insert(next)
        events.append(.begin(name, next))
        return next
    }
    func end(_ token: Int) { if open.remove(token) != nil { events.append(.end(token)) } }
}

@MainActor
final class Notes24ResultsTests: XCTestCase {

    // MARK: fixtures

    static let repoRoot: URL = {
        var u = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { u.deleteLastPathComponent() }
        return u
    }()
    static var materialsPath: String { repoRoot.appendingPathComponent("core/src/materials/materials.json").path }
    static var rulesPath: String { repoRoot.appendingPathComponent("core/src/materials/print_rules.json").path }
    static var cubeSTL: String { repoRoot.appendingPathComponent("core/tests/fixtures/stl/cube_10mm.stl").path }

    private var dir: URL!
    private var store: ProjectStore!
    private var inputs: URL!
    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("topopt-notes24-\(UUID().uuidString)", isDirectory: true)
        store = ProjectStore(rootDir: dir.appendingPathComponent("store", isDirectory: true))
        inputs = dir.appendingPathComponent("inputs", isDirectory: true)
    }
    override func tearDownWithError() throws { if let dir { try? FileManager.default.removeItem(at: dir) } }

    private func scratchDefaults() -> UserDefaults { UserDefaults(suiteName: "topopt.notes24.\(UUID().uuidString)")! }

    private func app(_ d: UserDefaults, _ time: BackgroundTime? = nil) -> AppModel {
        let m = AppModel(materialsPath: Self.materialsPath, rulesPath: Self.rulesPath, store: store, remoteJobDefaults: d,
                         backgroundTime: time ?? BackgroundTimeSpy(), latticeJobInputsRoot: inputs)
        m.loadMaterials()
        return m
    }

    /// A new part from the core's 10 mm cube, open in the workspace (its folder written).
    private func newPart(_ m: AppModel) throws -> ProjectModel {
        m.newTopOpt(); m.selectMaterial("PLA")
        m.pickedFile(atPath: Self.cubeSTL, displayName: "cube.stl")
        XCTAssertTrue(m.resolveUnits(.millimetres))
        m.continueToWorkspace()
        m.closePrintParams()
        return try XCTUnwrap(m.project)
    }

    private func request(_ p: ProjectModel?, mode: String = LatticeFileButton.jobMode) -> RunRequest {
        RunRequest(modelPath: Self.cubeSTL, material: "PLA", materialsPath: Self.materialsPath, rulesPath: Self.rulesPath,
                   resolution: 32, projectName: "Cube", projectID: p?.id).withJobMode(mode)
    }

    /// The Mac's print file, read as the Results screen's one result: a passing strength check, or (his v7) an Organic one
    /// that failed it — shown, its own verdict kept.
    static func printFile(passes: Bool = true) throws -> OptimizeOutcome {
        let s = passes ? LatticeFileButtonTests.strength("pass", strutsPass: true)
            : LatticeFileButtonTests.strength("fail", accepted: false, margin: 0.7)
        return try LatticeFileButton.outcome(try LatticeFileButtonTests.made(s), densityGCm3: 1.24, organic: !passes)
    }

    /// A Topology run's result (two variants).
    static func topologyResult() -> OptimizeOutcome {
        OptimizeOutcome(variants: (0..<2).map { i in
            OptimizeVariant(requestedVolumeFraction: 0.6, achievedVolumeFraction: 0.6, massGrams: 10 + Double(i),
                            supportVolumeVoxels: 0, meshTriangleCount: 1, worstCaseMargin: 2, accepted: true, v3Passes: true,
                            meshVertices: [0, 0, 0, 1, 0, 0, 0, 1, 0], meshIndices: [0, 1, 2])
        }, stoppedOnMargin: false, cancelled: false, acceptedCount: 2, computedRemotely: true, reportJSON: Data("{}".utf8))
    }

    private func waitUntil(_ what: String, seconds: Double = 30, _ done: () -> Bool) {
        let end = Date().addingTimeInterval(seconds)
        while !done(), Date() < end { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
        XCTAssertTrue(done(), what)
    }

    private func savedOutcome(_ id: UUID) throws -> OptimizeOutcome {
        try OutcomeCodec.decode(try XCTUnwrap(store.loadResultsData(id: id), "no results file"))
    }
    /// The same while polling (nothing recorded while it is not there yet).
    private func onDisk(_ id: UUID) -> OptimizeOutcome? { store.loadResultsData(id: id).flatMap { try? OutcomeCodec.decode($0) } }

    /// The Mac's job folder (out/): the print file, its report and its views; optionally a strengthening's files.
    private func macFiles(strengthening: Bool = false) throws -> URL {
        let out = dir.appendingPathComponent("mac/out", isDirectory: true)
        try FileManager.default.createDirectory(at: out.appendingPathComponent("r3"), withIntermediateDirectories: true)
        func put(_ name: String, _ d: Data) throws { try d.write(to: out.appendingPathComponent(name)) }
        try put(LatticeFileJob.reportName, try LatticeFileButtonTests.report(LatticeFileButtonTests.strength("pass", strutsPass: true)))
        try put(LatticeFileJob.outputName, LatticeFileButtonTests.stl())
        try put("fields.bin", LatticeFileButtonTests.fields())
        if strengthening {
            let summary: [String: Any] = ["ok": true, "code": "done", "why": "", "passing": true, "strengthened": "r3/strengthened.json",
                                          "rounds": [["round": 1], ["round": 2], ["round": 3]]]
            try put("strengthen.json", try JSONSerialization.data(withJSONObject: summary))
            try put("r3/strengthened.json", Data(#"{"version": 2, "additions": "additions.bin"}"#.utf8))
            try put("r3/additions.bin", Data([7, 7, 7, 7]))
        }
        return out
    }

    // MARK: 1 · the result saved as the run ends

    /// ★ With the app in the background (his Sidecar), a print file's run that lands is saved into ITS OWN version folder —
    /// project.json optimized, results.plist the print file — with no screen involved; the whole remote run held background
    /// time, the save's own began before the run's ended, and it ended only once the file had landed. RED CONTROL: a run that
    /// produced nothing writes nothing and asks no save time.
    func testAFinishedRunIsSavedInItsOwnFolderWithTheAppInTheBackground() throws {
        let time = BackgroundTimeSpy()
        let m = app(scratchDefaults(), time)
        let p = try newPart(m)
        m.sceneChanged(active: false)
        XCTAssertFalse(m.sceneActive, "premise: the app is behind Sidecar")
        XCTAssertFalse(store.hasPersistedResults(id: p.id), "premise: no result yet")

        let o = try Self.printFile()
        p.run.runner = { _, _, _ in o }
        p.run.start(request(p), remote: true, workerName: "Mac")
        waitUntil("★ the result landed in its own folder and every background time ended") {
            self.store.hasPersistedResults(id: p.id) && time.open.isEmpty && time.events.count == 4
        }
        XCTAssertEqual(store.snapshot(id: p.id)?.optimized, true, "★ its own project.json says it has results (never a draft)")
        let back = try savedOutcome(p.id)
        XCTAssertTrue(LatticeSavedResult.isPrintFile(back), "★ the print file's result, read back")
        XCTAssertEqual(back.variants.count, 1)
        XCTAssertEqual(time.events, [.begin("app.topopt.remote-run", 1), .begin("app.topopt.save-result", 2), .end(1), .end(2)],
                       "★ the run's time for its whole length; the save's began before it ended, and ended when the file landed")
        XCTAssertTrue(m.recentProjects.first { $0.id == p.id }?.optimized ?? false)

        // RED CONTROL: a run that produced nothing saves nothing (and asks no save time)
        let q = try newPart(m)
        let before = time.events.count
        q.run.runner = { _, _, _ in throw LatticeFileRun.Failure("The file could not be made") }
        q.run.start(request(q), remote: true, workerName: "Mac")
        waitUntil("the empty run ended") { q.run.phase == .failed && time.open.isEmpty && time.events.count == before + 2 }
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        XCTAssertFalse(store.hasPersistedResults(id: q.id), "RED CONTROL: nothing to save, nothing written")
        XCTAssertFalse(time.events.dropFirst(before).contains { if case .begin(let n, _) = $0 { return n.contains("save") }; return false })
    }

    /// ★ A re-run on a version that already had results saves its NEW result (the old path, `markOptimized`, returned early
    /// for an optimized version, so the new result waited for some later save). RED CONTROL: `markOptimized` alone writes
    /// nothing for it.
    func testAReRunOnAVersionWithResultsSavesItsNewResult() throws {
        let m = app(scratchDefaults())
        let p = try newPart(m)
        let topology = Self.topologyResult()
        p.run.runner = { _, _, _ in topology }
        p.run.start(request(p, mode: "minimize_plastic"), remote: true, workerName: "Mac")
        waitUntil("the first result landed") { self.onDisk(p.id)?.variants.count == 2 }

        let url = store.resultsURL(id: p.id)
        let stamp = try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date
        m.markOptimized(p.id)
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date, stamp,
                       "RED CONTROL: the old path writes nothing for a version already optimized")

        let file = try Self.printFile()
        p.run.runner = { _, _, _ in file }
        p.run.start(request(p), remote: true, workerName: "Mac")
        waitUntil("★ the re-run's own result replaced it on disk") { self.onDisk(p.id).map(LatticeSavedResult.isPrintFile) ?? false }
        XCTAssertEqual(try savedOutcome(p.id).variants.count, 1)
    }

    // MARK: 2 · the Lattice button's jobs recorded and followed again

    /// ★ The print file's job is recorded for its version from its submit (as the Optimize run's is), and stays until its
    /// result is saved; it is never offered on the Home banner. RED CONTROL: a run with no version (Export) records nothing.
    func testThePrintFilesJobIsRecordedForItsVersion() throws {
        let d = scratchDefaults()
        let w = try StubWorker(filesDir: try macFiles(), events: [], fingerprint: CoreFingerprint.value)
        defer { w.stop() }
        let config = RemoteRunnerConfig(host: "127.0.0.1", port: Int(w.port), expectedFingerprint: CoreFingerprint.value)
        let model = dir.appendingPathComponent("p.step")
        try Data("ISO-10303-21;".utf8).write(to: model)
        let job = LatticeFileJob.ForPart(json: Data(#"{"mode": "lattice_file"}"#.utf8), modelPath: model.path, demand: nil)
        let id = UUID()
        let runner = LatticeFileButton.runner(config: config, job: job, projectName: "Stand", strengthJob: nil, densityGCm3: 1.24,
                                              defaults: d, inputsRoot: inputs)
        let req = RunRequest(modelPath: model.path, material: "PA12", materialsPath: "", rulesPath: "", resolution: 64,
                             projectName: "Stand", projectID: id)
        let o = try runner(req, { _, _, _ in true }, { _ in })
        XCTAssertTrue(LatticeSavedResult.isPrintFile(o))
        let recs = RemoteJobStore.loadAll(defaults: d)
        XCTAssertEqual(recs.count, 1, "★ the job is recorded")
        XCTAssertEqual(recs.first?.kind, LatticeJobKind.file.rawValue)
        XCTAssertEqual(recs.first?.projectID, id, "★ for its version")
        XCTAssertEqual(recs.first?.jobID, w.jobID)
        XCTAssertEqual(recs.first?.port, Int(w.port))
        XCTAssertTrue(app(d).pendingReattachJobs.isEmpty, "★ never offered on the Home banner (it is followed by itself)")

        // RED CONTROL: no version, nothing recorded
        let d2 = scratchDefaults()
        let noVersion = RunRequest(modelPath: model.path, material: "PA12", materialsPath: "", rulesPath: "", resolution: 64,
                                   projectName: "Stand")
        _ = try LatticeFileButton.runner(config: config, job: job, projectName: "Stand", strengthJob: nil, densityGCm3: 1.24,
                                         defaults: d2, inputsRoot: inputs)(noVersion, { _, _, _ in true }, { _ in })
        XCTAssertTrue(RemoteJobStore.loadAll(defaults: d2).isEmpty, "RED CONTROL: a run with no version records nothing")
    }

    /// ★ HIS CASE: the app was gone before it saved the print file; the job's record points at the Mac. On the next launch
    /// the job is followed again (never submitted again): finished, its files are fetched at once, read as the result and
    /// saved into its version's folder, and the record ends. RED CONTROL: an Optimize run's record is not followed by itself
    /// (it stays the Home banner's).
    func testARecordedPrintFileIsFetchedAndSavedToItsVersionOnLaunch() throws {
        let d = scratchDefaults()
        let w = try StubWorker(filesDir: try macFiles(), events: [], fingerprint: CoreFingerprint.value)
        defer { w.stop() }
        let first = app(d)
        let p = try newPart(first)
        let id = p.id
        first.backHome()
        XCTAssertFalse(store.hasPersistedResults(id: id), "premise: the result was never saved")
        RemoteJobStore.save(PersistedRemoteJob(host: "127.0.0.1", port: Int(w.port), fingerprint: CoreFingerprint.value,
                                               jobID: w.jobID, submittedAt: Date(), projectID: id, projectName: "Cube",
                                               kind: LatticeJobKind.file.rawValue, organic: false), defaults: d)
        let optimize = PersistedRemoteJob(host: "10.0.0.4", port: 8757, fingerprint: "f", jobID: "optimize-job", projectID: id)
        RemoteJobStore.save(optimize, defaults: d)

        let relaunched = app(d)   // a fresh launch
        XCTAssertEqual(relaunched.pendingReattachJobs, [optimize], "RED CONTROL: the Optimize run's record is the banner's")
        relaunched.resumeLatticeJobs()
        waitUntil("★ the Mac's print file saved into its version") { self.store.hasPersistedResults(id: id) }
        waitUntil("★ its record ended once saved") { !RemoteJobStore.loadAll(defaults: d).contains { $0.isLatticeJob } }
        XCTAssertEqual(store.snapshot(id: id)?.optimized, true)
        XCTAssertTrue(LatticeSavedResult.isPrintFile(try savedOutcome(id)), "★ the print file's own result")
        XCTAssertFalse(w.log().contains { $0.hasPrefix("POST") }, "★ followed, never sent again")
        XCTAssertTrue(w.requested(suffix: "/files/\(LatticeFileJob.reportName)") && w.requested(suffix: "/files/\(LatticeFileJob.outputName)")
                      && w.requested(suffix: "/files/fields.bin"), "★ lattice_file.json, the file and fields.bin fetched")
        XCTAssertEqual(RemoteJobStore.loadAll(defaults: d), [optimize], "RED CONTROL: the Optimize record is left for its banner")
    }

    /// ★ Organic: the app was gone while the Mac STRENGTHENED the lattice. On the next launch the strengthening is followed to
    /// its end, its print file made from the inputs kept beside its record (one job sent: the file's, with the last round),
    /// read and saved; both records and the kept inputs end.
    func testARecordedStrengtheningGoesOnToMakeItsFileAndSavesIt() throws {
        let d = scratchDefaults()
        let w = try StubWorker(filesDir: try macFiles(strengthening: true), events: [], fingerprint: CoreFingerprint.value,
                               aliases: ["strengthjob"])
        defer { w.stop() }
        let first = app(d)
        let p = try newPart(first)
        let id = p.id
        first.backHome()
        RemoteJobStore.save(PersistedRemoteJob(host: "127.0.0.1", port: Int(w.port), fingerprint: CoreFingerprint.value,
                                               jobID: "strengthjob", submittedAt: Date(), projectID: id, projectName: "Cube",
                                               kind: LatticeJobKind.strengthen.rawValue, organic: true), defaults: d)
        LatticeJobInputs.save(.init(json: Data(#"{"mode": "lattice_file"}"#.utf8), strengthJob: Data(#"{"mode": "lattice_part"}"#.utf8),
                                    tensor: Data("TOTENSOR".utf8)), jobID: "strengthjob", root: inputs)

        let relaunched = app(d)
        relaunched.resumeLatticeJobs()
        waitUntil("★ the strengthened print file saved into its version") { self.store.hasPersistedResults(id: id) }
        waitUntil("★ both records ended") { RemoteJobStore.loadAll(defaults: d).isEmpty }
        let posts = w.posts().map { String(decoding: $0, as: UTF8.self) }
        XCTAssertEqual(posts.count, 1, "★ one job sent: the file's (the strengthening was already on the Mac)")
        XCTAssertTrue(posts.first?.contains("name=\"strengthened\"") ?? false, "★ with the last round")
        XCTAssertFalse(posts.first?.contains("name=\"run\"") ?? true, "never the strengthening again")
        let rep = try XCTUnwrap(try savedOutcome(id).reportJSON.flatMap { try JSONSerialization.jsonObject(with: $0) as? [String: Any] })
        XCTAssertNotNil(rep[LatticeFileButton.strengthenKey], "★ the strengthening rides the result, as the live run's does")
        XCTAssertNil(LatticeJobInputs.load(jobID: "strengthjob", root: inputs), "★ the kept inputs went with its record")
    }

    /// ★ A Mac out of reach keeps the record (the job is followed again when the app comes back); a job the Mac lost (no
    /// state, no files) ends it.
    func testAMacOutOfReachKeepsTheRecordAndALostJobEndsIt() throws {
        let d = scratchDefaults()
        let files = try macFiles()
        let w = try StubWorker(filesDir: files, events: [], fingerprint: CoreFingerprint.value)
        let port = Int(w.port)
        let rec = LatticeJobRecorder(projectID: UUID(), projectName: "Cube", organic: false, defaults: d, inputsRoot: inputs)
        let live = RemoteRunnerConfig(host: "127.0.0.1", port: port, expectedFingerprint: CoreFingerprint.value, controlTimeout: 2)
        rec.saved(.file, jobID: "lostjob", config: live)
        XCTAssertThrowsError(try LatticeFileRun.follow(config: live, jobID: "lostjob", record: rec)) { e in
            XCTAssertFalse((e as? LatticeFileRun.Failure)?.transient ?? true)
        }
        XCTAssertTrue(RemoteJobStore.loadAll(defaults: d).isEmpty, "★ a job the Mac lost ends its record")

        w.stop()   // the Mac goes away
        rec.saved(.file, jobID: w.jobID, config: live)
        XCTAssertThrowsError(try LatticeFileRun.follow(config: live, jobID: w.jobID, record: rec)) { e in
            XCTAssertTrue((e as? LatticeFileRun.Failure)?.transient ?? false, "\(e)")
        }
        XCTAssertEqual(RemoteJobStore.loadAll(defaults: d).map(\.jobID), [w.jobID], "★ out of reach: the record is kept")
    }

    // MARK: 3 · the notification carries its version, and its tap opens the result

    private final class NotifierSpy: RunNotifier {
        var routes: [RunResultRoute?] = []
        func willRunInBackground() {}
        func runDidComplete(summary: String) { XCTFail("the route is always handed over") }
        func runDidComplete(summary: String, route: RunResultRoute?) { routes.append(route) }
    }

    /// ★ Every completion notification carries where its result is: the version, and the Lattice stage for a print file's,
    /// Topology for an Optimize run's; its userInfo reads back the same. RED CONTROL: a run with no version carries none, and
    /// a notification without one routes nowhere.
    func testTheNotificationCarriesItsVersionAndTheStageItOpensIn() throws {
        let spy = NotifierSpy()
        let run = RunModel(scheduler: SynchronousRunScheduler(), notifier: spy, watchdog: DisabledRunWatchdog())
        let id = UUID()
        let file = try Self.printFile()
        run.runner = { _, _, _ in file }
        run.start(RunRequest(modelPath: "/p.step", material: "PA12", materialsPath: "", rulesPath: "", resolution: 64,
                             projectName: "Stand", projectID: id).withJobMode(LatticeFileButton.jobMode), remote: true)
        let topo = Self.topologyResult()
        run.runner = { _, _, _ in topo }
        run.start(RunRequest(modelPath: "/p.step", material: "PA12", materialsPath: "", rulesPath: "", resolution: 64,
                             projectName: "Stand", projectID: id), remote: true)
        run.start(RunRequest(modelPath: "/p.step", material: "PA12", materialsPath: "", rulesPath: "", resolution: 64,
                             projectName: "Stand"), remote: true)
        XCTAssertEqual(spy.routes, [RunResultRoute(projectID: id, lattice: true), RunResultRoute(projectID: id, lattice: false), nil],
                       "★ the print file's opens in the Lattice stage, the Optimize run's on Topology; RED CONTROL: no version")
        let r = RunResultRoute(projectID: id, lattice: true)
        XCTAssertEqual(RunResultRoute(userInfo: r.userInfo), r, "★ its userInfo reads back")

        let router = RunNotificationRouter()
        router.tapped(userInfo: ["aps": "x"])
        XCTAssertNil(router.pending, "RED CONTROL: a notification without a version routes nowhere")
        router.tapped(userInfo: r.userInfo)
        XCTAssertEqual(router.pending, r)
        XCTAssertEqual(router.take(), r)
        XCTAssertNil(router.pending, "taken once")
    }

    /// ★ The tap after a relaunch (the app had been closed): the screen is covered while the version and its result are read
    /// (no Library, no Topology on the way), then the version opens with its result to open; the print file's opens in the
    /// Lattice stage. RED CONTROL: a version that is gone says so in a pop-up and opens nothing.
    func testTheTapOpensTheVersionOnItsResultAfterARelaunch() throws {
        let d = scratchDefaults()
        let first = app(d)
        let p = try newPart(first)
        let id = p.id
        let file = try Self.printFile()
        p.run.runner = { _, _, _ in file }
        p.run.start(request(p), remote: true, workerName: "Mac")
        waitUntil("saved") { self.store.hasPersistedResults(id: id) }
        first.backHome()

        let relaunched = app(d)
        XCTAssertEqual(relaunched.screen, .home, "premise: a relaunch starts on the Library")
        let router = RunNotificationRouter()
        router.tapped(userInfo: RunResultRoute(projectID: id, lattice: true).userInfo)
        relaunched.openTappedResult(router)
        XCTAssertNotNil(relaunched.openingResult, "★ the screen is covered while the result is read")
        XCTAssertEqual(relaunched.screen, .home, "nothing opened before its result is in")
        waitUntil("★ the version opened") { relaunched.screen == .workspace }
        XCTAssertNil(relaunched.openingResult, "the cover goes as it opens")
        XCTAssertEqual(relaunched.project?.id, id)
        XCTAssertEqual(LibraryOpen.takeExport(for: id), 0, "★ with its result to open (the workspace takes it as it appears)")
        XCTAssertTrue(LatticeSavedResult.opensInLattice(relaunched.project?.run.outcome), "★ a print file's: in the Lattice stage")
        XCTAssertFalse(LatticeSavedResult.opensInLattice(Self.topologyResult()), "a Topology result opens on Topology")

        // RED CONTROL: gone
        AppPopups.shared.current = nil
        relaunched.backHome()
        relaunched.openResult(RunResultRoute(projectID: UUID(), lattice: true))
        XCTAssertEqual(relaunched.screen, .home)
        XCTAssertNil(relaunched.openingResult)
        XCTAssertEqual(AppPopups.shared.current?.title, KeepResultCopy.goneTitle, "RED CONTROL: it says so, plainly")
        AppPopups.shared.current = nil
    }

    // MARK: 5 · Approved from the saved result

    /// ★ The Lattice button's Approved is worked out from the version's SAVED print file — it passes its checks and was made
    /// from today's settings — so it is there after a relaunch. RED CONTROLS: a settings change takes it away; a print file
    /// that failed its checks is never Approved.
    func testApprovedComesFromTheSavedResultAndSurvivesARelaunch() throws {
        let d = scratchDefaults()
        let first = app(d)
        let p = try newPart(first)
        let id = p.id
        let file = try Self.printFile()
        p.run.runner = { _, _, _ in file }
        p.run.start(request(p), remote: true, workerName: "Mac")
        waitUntil("saved") { self.store.hasPersistedResults(id: id) }
        XCTAssertTrue(first.latticeResultApproved(p), "★ the saved print file passes, made from today's settings")
        p.printParams.wallLoops += 1
        XCTAssertFalse(first.latticeResultApproved(p), "RED CONTROL: a settings change gives the button back")
        p.printParams.wallLoops -= 1
        first.backHome()

        let relaunched = app(d)
        relaunched.open(try XCTUnwrap(relaunched.recentProjects.first { $0.id == id }))
        let reopened = try XCTUnwrap(relaunched.project)
        waitUntil("its result read back") { reopened.hasResults }
        XCTAssertTrue(relaunched.latticeResultApproved(reopened), "★ Approved after a relaunch (the button's memory is gone)")

        // RED CONTROL: a print file that failed its checks
        let q = try newPart(relaunched)
        let failing = try Self.printFile(passes: false)
        XCTAssertTrue(failing.variants[0].accepted && !failing.variants[0].v3Passes, "premise: shown, not strong enough")
        q.run.runner = { _, _, _ in failing }
        q.run.start(request(q), remote: true, workerName: "Mac")
        waitUntil("saved") { self.store.hasPersistedResults(id: q.id) }
        XCTAssertFalse(relaunched.latticeResultApproved(q), "RED CONTROL: one that failed its checks is never Approved")
    }
}
#endif
