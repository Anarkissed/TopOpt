// Notes25FlowTests — ★ his iPad notes 2026-11-23 15:35 EST on release 16 (notes25, builder "flow"), model tests and pins:
//   A1 (Img 1) "When making a print-accurate version there are *two* pop-ups, one behind the other. There should only be one.
//      ... a single pop-up that contains everything - including a "Run in the Background" and "Cancel" button."
//   A2 (Img 4/5) "The results tab should ONLY be in the Lattice stage so that I can ALSO run TO results and have *them* be in
//      the Topology stage - keeping both in the same version if I wanted to." + "remove it from the ^ menu".
//   A3 (Img 4) "With "Print-accurate Preview" selected, and the "exact" laid down, it still says "Make print accurate" ... The
//      button should just say "Lattice" to send to the mac and generate it."
//   A4 (362's numbers investigation) "The drawing follows the print file. Always." (Print-accurate preview on): the print
//      file made for the settings on screen is what the Lattice stage draws; the preview's line counts strands.
// Hosted (his two iPad sizes): Notes25FlowHostedTests.
#if canImport(AppKit) && canImport(MetalKit)
import XCTest
import Combine
import simd
@testable import TopOptFlows
@testable import TopOptKit

@MainActor
final class Notes25FlowTests: XCTestCase {

    private var accurateBefore = false
    private var dir: URL!
    private var store: ProjectStore!

    override func setUpWithError() throws {
        accurateBefore = AppSettings.shared.latticePrintAccurate
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("topopt-notes25-\(UUID().uuidString)", isDirectory: true)
        store = ProjectStore(rootDir: dir.appendingPathComponent("store", isDirectory: true))
    }
    override func tearDownWithError() throws {
        AppSettings.shared.latticePrintAccurate = accurateBefore
        LatticeMacMake.shared.reset()
        LatticeSavedFileDrawing.shared.reset()
        if let dir { try? FileManager.default.removeItem(at: dir) }
    }

    private func request(_ id: UUID?, lattice: Bool) -> RunRequest {
        let r = RunRequest(modelPath: Notes24ResultsTests.cubeSTL, material: "PLA", materialsPath: Notes24ResultsTests.materialsPath,
                           rulesPath: Notes24ResultsTests.rulesPath, resolution: 32, projectName: "Cube", projectID: id)
        return lattice ? r.withJobMode(LatticeFileButton.jobMode) : r
    }

    private func syncRun() -> RunModel {
        RunModel(scheduler: SynchronousRunScheduler(), notifier: SilentRunNotifier(), watchdog: DisabledRunWatchdog())
    }

    // MARK: A2 · one version keeps both results, each stage its own

    /// ★ A print file's run on a version with a Topology result keeps that result (the Topology stage's), and an Optimize after
    /// it keeps the print file's (the Lattice stage's); each stage reads its own. A run of the SAME stage replaces only its own.
    /// RED CONTROLS: a run that produced nothing leaves both exactly as they were; `reset` (a move to the next version) drops both.
    func testOneVersionKeepsBothResultsEachStageItsOwn() throws {
        let run = syncRun()
        let topo = Notes24ResultsTests.topologyResult(), file = try Notes24ResultsTests.printFile()
        run.runner = { _, _, _ in topo }
        run.start(request(UUID(), lattice: false))
        XCTAssertEqual(run.outcome(lattice: false)?.variants.count, 2, "premise: Topology's result")
        XCTAssertNil(run.outcome(lattice: true))
        XCTAssertFalse(run.outcomeIsPrintFile)

        run.runner = { _, _, _ in file }
        run.start(request(UUID(), lattice: true))
        XCTAssertEqual(run.phase, .succeeded)
        XCTAssertTrue(LatticeSavedResult.isPrintFile(run.outcome), "the last run's result is the print file's")
        XCTAssertEqual(run.otherOutcome?.variants.count, 2, "★ Topology's result KEPT beside it")
        XCTAssertEqual(run.outcome(lattice: false)?.variants.count, 2, "★ Topology reads its own")
        XCTAssertTrue(LatticeSavedResult.isPrintFile(run.outcome(lattice: true)), "★ the Lattice stage reads its own")

        // an Optimize after it: the print file's stays
        let topo2 = OptimizeOutcome(variants: [topo.variants[0]], stoppedOnMargin: false, cancelled: false, acceptedCount: 1,
                                    computedRemotely: true, reportJSON: Data("{}".utf8))
        run.runner = { _, _, _ in topo2 }
        run.start(request(UUID(), lattice: false))
        XCTAssertEqual(run.outcome(lattice: false)?.variants.count, 1, "★ the new Topology result replaced only Topology's")
        XCTAssertTrue(LatticeSavedResult.isPrintFile(run.outcome(lattice: true)), "★ the print file's still there")
        XCTAssertTrue(LatticeSavedResult.isPrintFile(run.otherOutcome))

        // RED CONTROL: a print file's run that produced nothing leaves both as they were
        run.runner = { _, _, _ in throw LatticeFileRun.Failure("The file could not be made") }
        run.start(request(UUID(), lattice: true))
        XCTAssertEqual(run.phase, .failed)
        XCTAssertEqual(run.outcome?.variants.count, 1, "RED CONTROL: Topology's result back where it was")
        XCTAssertFalse(run.outcomeIsPrintFile)
        XCTAssertTrue(LatticeSavedResult.isPrintFile(run.otherOutcome), "RED CONTROL: the print file's where it was")
        run.dismissFailure()
        XCTAssertEqual(run.outcome?.variants.count, 1, "dismissing the failure moves nothing")
        XCTAssertTrue(LatticeSavedResult.isPrintFile(run.otherOutcome))

        // a print file's run over a print file's: replaces only that one
        let file2 = try Notes24ResultsTests.printFile(passes: false)
        run.runner = { _, _, _ in file2 }
        run.start(request(UUID(), lattice: true))
        XCTAssertEqual(run.outcome(lattice: false)?.variants.count, 1, "★ Topology's untouched")
        XCTAssertFalse(run.outcome(lattice: true)?.variants.first?.v3Passes ?? true, "★ the new print file's")

        run.reset()
        XCTAssertNil(run.outcome); XCTAssertNil(run.otherOutcome, "RED CONTROL: the next version starts with neither")
    }

    /// ★ Both are saved in the version's folder (results.plist the last run's, as the Library reads it; the other stage's beside
    /// it) and both come back on reopening; Approved still reads the print file's. RED CONTROL: a version with one result has
    /// no second file.
    func testBothResultsAreSavedAndComeBack() throws {
        let m = AppModel(materialsPath: Notes24ResultsTests.materialsPath, rulesPath: Notes24ResultsTests.rulesPath, store: store,
                         remoteJobDefaults: UserDefaults(suiteName: "topopt.notes25.\(UUID().uuidString)")!,
                         backgroundTime: BackgroundTimeSpy())
        m.loadMaterials()
        m.newTopOpt(); m.selectMaterial("PLA")
        m.pickedFile(atPath: Notes24ResultsTests.cubeSTL, displayName: "cube.stl")
        XCTAssertTrue(m.resolveUnits(.millimetres))
        m.continueToWorkspace()
        m.closePrintParams()
        let p = try XCTUnwrap(m.project)
        let topo = Notes24ResultsTests.topologyResult()
        p.run.runner = { _, _, _ in topo }
        p.run.start(request(p.id, lattice: false), remote: true, workerName: "Mac")
        waitUntil("Topology's saved") { self.store.hasPersistedResults(id: p.id) && !self.busy(m) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.otherResultsURL(id: p.id).path), "RED CONTROL: one result, one file")

        let file = try Notes24ResultsTests.printFile()
        p.run.runner = { _, _, _ in file }
        p.run.start(request(p.id, lattice: true), remote: true, workerName: "Mac")
        waitUntil("★ both saved") {
            (self.store.loadResultsData(id: p.id).flatMap { try? OutcomeCodec.decode($0) }).map(LatticeSavedResult.isPrintFile) == true
                && FileManager.default.fileExists(atPath: self.store.otherResultsURL(id: p.id).path)
        }
        let other = try OutcomeCodec.decode(try Data(contentsOf: store.otherResultsURL(id: p.id)))
        XCTAssertEqual(other.variants.count, 2, "★ Topology's result beside the print file's")
        XCTAssertTrue(m.latticeResultApproved(p))
        let id = p.id
        m.backHome()

        let again = AppModel(materialsPath: Notes24ResultsTests.materialsPath, rulesPath: Notes24ResultsTests.rulesPath, store: store,
                             remoteJobDefaults: UserDefaults(suiteName: "topopt.notes25b.\(UUID().uuidString)")!,
                             backgroundTime: BackgroundTimeSpy())
        again.loadMaterials()
        again.open(try XCTUnwrap(again.recentProjects.first { $0.id == id }))
        let back = try XCTUnwrap(again.project)
        waitUntil("both read back") { back.run.outcome != nil && back.run.otherOutcome != nil }
        XCTAssertTrue(LatticeSavedResult.isPrintFile(back.run.outcome(lattice: true)), "★ the Lattice stage's, after a relaunch")
        XCTAssertEqual(back.run.outcome(lattice: false)?.variants.count, 2, "★ Topology's, after a relaunch")
        XCTAssertTrue(again.latticeResultApproved(back), "★ Approved from the saved print file still")
    }

    private func busy(_ m: AppModel) -> Bool { (m.backgroundTime as? BackgroundTimeSpy).map { !$0.open.isEmpty } ?? false }

    private func waitUntil(_ what: String, seconds: Double = 30, _ done: () -> Bool) {
        let end = Date().addingTimeInterval(seconds)
        while !done(), Date() < end { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
        XCTAssertTrue(done(), what)
    }

    /// ★ The workspace: each stage's Results reads its own result; the re-run cards ask only about their own stage's; the ⌃
    /// has no "Results" row; the Lattice stage's capsule carries the tab (hidden with no lattice result, as Topology's is);
    /// "Lattice an optimized result" offers Topology's results only; the wizard is the Lattice stage's.
    func testTheWorkspaceReadsEachStagesOwnResult() throws {
        let ws = try FlexibleSource.code("WorkspacePlaceholder.swift")
        XCTAssertTrue(ws.contains("if let outcome = stageOutcome, outcome.variants.contains(where: { $0.accepted }), !viewOriginal,"))
        XCTAssertTrue(ws.contains("var stageOutcome: OptimizeOutcome? { stage == .lattice ? latticeOutcome : topologyOutcome }"))
        XCTAssertTrue(ws.contains("var acceptedVariantCount: Int { topologyOutcome?.variants.filter { $0.accepted }.count ?? 0 }"))
        XCTAssertTrue(ws.contains("ResultsReplacementPrompt.forNewRun(existing: topologyOutcome)"))
        XCTAssertTrue(ws.contains("ResultsReplacementPrompt.forNewRun(existing: latticeOutcome)"))
        XCTAssertFalse(ws.contains("ResultsReplacementPrompt.forNewRun(existing: run.outcome)"), "RED CONTROL: never the other stage's")
        XCTAssertFalse(ws.contains("items.append(latticeResultsItem)"), "★ no ⌃ Results row")
        XCTAssertFalse(ws.contains("lattice-split-results"))
        let cap = try XCTUnwrap(ws.range(of: "@ViewBuilder var latticeCapsuleOverlay: some View {"))
        let capsule = String(ws[cap.lowerBound...].prefix(2600))
        XCTAssertTrue(capsule.contains("tertiaryTitle: LatticeResultsTab.title, tertiary: { leaveLatticeCells(); viewOriginal = false }"))
        XCTAssertTrue(capsule.contains("hidden: LatticeResultsTab.hidden(hasResult: latticeResultCount > 0)"))
        XCTAssertTrue(capsule.contains("let page: StageCapsule.Page = latticeResultsPageUp ? .tertiary"))
        XCTAssertTrue(ws.contains("guard let o = topologyOutcome else { return [] }"), "Lattice an optimized result")
        XCTAssertTrue(ws.contains("certify: stage == .lattice ? certifyCard : nil)"))
        XCTAssertTrue(ws.contains(".id(stage)"))
        XCTAssertEqual(LatticeResultsTab.title, TopologyPage.results.title, "★ Topology's own word")
        XCTAssertEqual(LatticeResultsTab.hidden(hasResult: false), [.tertiary], "★ hidden, not greyed, with no result (Topology's B8)")
        XCTAssertEqual(LatticeResultsTab.hidden(hasResult: true), [])
        XCTAssertEqual(TopologyPage.hiddenSegments(hasResults: false).contains(.secondary), true, "the rule mirrored")
    }

    // MARK: A1 · one card for the whole chain

    /// ★ The card from his press to the run's end: it carries the run (its own card stays away), says each step (the check's
    /// too, after the file is drawn), goes to the background and comes back, and goes the moment the run ends; Cancel stops
    /// the whole chain. RED CONTROL: another run is never carried.
    func testOneCardCarriesTheRunToItsEnd() throws {
        let m = LatticeMacMake.shared
        let run = RunModel(scheduler: Notes25HeldScheduler(), notifier: SilentRunNotifier(), watchdog: DisabledRunWatchdog())
        let id = UUID()
        var cancels = 0
        m.begin(project: id, path: "/p/part.step", run: run, cancel: { cancels += 1; run.cancel() })
        XCTAssertTrue(m.shown); XCTAssertTrue(m.covers(run))
        XCTAssertFalse(m.covers(syncRun()), "RED CONTROL: another run keeps its own card")
        run.start(request(id, lattice: true), remote: true)
        XCTAssertTrue(m.shown, "the run started: the same card")
        m.said(LatticeMacMakeCopy.laying)
        XCTAssertEqual(m.stage, LatticeMacMakeCopy.laying)
        m.fileArrived()
        m.drawn(checkFollows: true)
        XCTAssertTrue(m.shown, "★ the file drawn: the card stays")
        XCTAssertEqual(m.stage, LatticeMacMakeCopy.checking, "★ it says the check")
        m.said(LatticeMacMakeCopy.saving)
        XCTAssertEqual(m.stage, LatticeMacMakeCopy.checking, "an earlier step never comes back after the check began")

        m.sendToBackground()
        XCTAssertFalse(m.shown, "★ Run in the Background: the card goes")
        XCTAssertTrue(m.isMaking(id), "★ the chain goes on (the button shows it)")
        XCTAssertTrue(m.covers(run), "★ and still no card of the run's own")
        m.said(LatticeMacMakeCopy.checking)
        m.reopen()
        XCTAssertTrue(m.shown, "★ the Lattice button's tap: the same card back")

        m.cancel()
        XCTAssertEqual(cancels, 1, "★ Cancel stops the chain's run")
        XCTAssertFalse(m.shown); XCTAssertFalse(m.isMaking(id)); XCTAssertFalse(m.covers(run))

        // the run ends: the card goes at once (before the workspace hears it)
        let run2 = RunModel(scheduler: SynchronousRunScheduler(), notifier: SilentRunNotifier(), watchdog: DisabledRunWatchdog())
        m.begin(project: id, path: nil, run: run2, cancel: {})
        let file = try Notes24ResultsTests.printFile()
        run2.runner = { _, _, _ in file }
        run2.start(request(id, lattice: true), remote: true)
        XCTAssertFalse(m.shown, "★ the run ended: the card is gone")
        XCTAssertTrue(m.isMaking(id), "the workspace ends the chain (its no-Mac pop-up reads it first)")
        m.ended()
        XCTAssertFalse(m.isMaking(id))
        m.reopen()
        XCTAssertFalse(m.shown, "nothing to bring back")
    }

    /// The words: his own on the button, five at most on each.
    func testTheCardsWords() {
        XCTAssertEqual(LatticeMacMakeCopy.background, "Run in the Background", "★ his words")
        XCTAssertEqual(LatticeMacMakeCopy.cancel, "Cancel")
        for w in [LatticeMacMakeCopy.background, LatticeMacMakeCopy.fileTitle] {
            XCTAssertLessThanOrEqual(w.split(separator: " ").count, 5, w)
        }
        let m = LatticeMacMake.shared
        m.begin(project: UUID(), path: nil, cancel: {})
        XCTAssertEqual(m.title, LatticeMacMakeCopy.title)
        m.begin(project: UUID(), path: nil, fileOnly: true, cancel: {})
        XCTAssertEqual(m.title, LatticeMacMakeCopy.fileTitle, "★ A3: the print-accurate lattice on screen: the print file alone")
    }

    /// ★ The pieces in place: the card at the root, the run's own card away while the card carries it, the button's tap brings
    /// the card back, the press begins the card with the run (and a cancel while the lattice is readied stops there).
    func testTheChainsPiecesAreWired() throws {
        let rs = try FlexibleSource.code("RunScreen.swift")
        XCTAssertTrue(rs.contains("if !(model.outcome?.variants.isEmpty ?? true) || mac.covers(model) {"))
        let flow = try FlexibleSource.code("LatticePrintFlow.swift")
        XCTAssertTrue(flow.contains("if mac.isMaking(projectID) { mac.reopen(); return }"))
        let ws = try FlexibleSource.code("WorkspacePlaceholder.swift")
        let start = try XCTUnwrap(ws.range(of: "    private func startLatticeRun(_ request: RunRequest) {"))
        let body = String(ws[start.upperBound...].prefix(4800))
        XCTAssertTrue(body.contains("LatticeMacMake.shared.begin(project: project.id, path: project.importedFile?.path, run: r,"))
        XCTAssertTrue(body.contains("fileOnly: newEngine.showsFile || latticeExactOnScreen, cancel: { r.cancel() })"))
        XCTAssertTrue(body.contains("guard LatticeMacMake.shared.isMaking(project.id) else { LatticePrintFlow.shared.ended(); return }"))
        let mac = try FlexibleSource.code("LatticeMacMake.swift")
        XCTAssertFalse(mac.contains(".alert(") || mac.contains(".confirmationDialog("))
        XCTAssertTrue(mac.contains("publish(\"macMakeBackground\")") && mac.contains("publish(\"macMakeCancel\")"))
    }

    // MARK: A3 · "Lattice" once the print-accurate lattice is on screen

    /// ★ "Make print-accurate" only with the quick stand-in on screen; with the ⌃ switch on and the iPad's exact laid for these
    /// settings (or the Mac's file drawn) the button is "Lattice". RED CONTROLS: the exact out of date, a Draft, the switch off,
    /// still laying — as today.
    func testTheButtonIsLatticeWithTheExactOnScreen() {
        func exact(_ on: Bool, _ q: LatticeLayoutSession.Organic.Quality?, _ cur: Bool, _ lay: Bool) -> Bool {
            LatticeMacStep.exactOnScreen(printAccurate: on, quality: q, current: cur, laying: lay)
        }
        XCTAssertTrue(exact(true, .exact, true, false), "★ the exact laid, current, the switch on")
        XCTAssertFalse(exact(true, .exact, false, false), "RED CONTROL: settings changed since")
        XCTAssertFalse(exact(true, .draft, true, false), "RED CONTROL: a Draft only")
        XCTAssertFalse(exact(false, .exact, true, false), "RED CONTROL: the switch off")
        XCTAssertFalse(exact(true, .exact, true, true), "RED CONTROL: laying")
        func step(_ exactOnScreen: Bool, showsFile: Bool = false) -> Bool {
            LatticeMacStep.makesPrintAccurate(ready: true, organic: true, laid: true, laying: false, showsFile: showsFile,
                                              exactOnScreen: exactOnScreen)
        }
        XCTAssertTrue(step(false), "a Draft on screen: Make print-accurate, as today")
        XCTAssertFalse(step(true), "★ the exact on screen: Lattice")
        XCTAssertFalse(step(false, showsFile: true), "the Mac's file on screen: Lattice, as today")
        XCTAssertFalse(LatticeMacStep.makesPrintAccurate(ready: true, organic: false, laid: true, laying: false, showsFile: false,
                                                         exactOnScreen: false), "a regular lattice: Lattice")
    }

    /// ★ The press in that state is the Mac's run for the print file and its check: the same press as after a Mac-made file
    /// (requestLatticeRun → startLatticeRun's Mac run), its card and button saying the print file. Pinned where the button's
    /// label is decided.
    func testThePressGoesStraightToThePrintFile() throws {
        let ws = try FlexibleSource.code("WorkspacePlaceholder.swift")
        XCTAssertTrue(ws.contains("let macStep = !refresh && !runs && LatticeMacStep.makesPrintAccurate(ready: ok, organic: LatticeLayoutPreview.organic(project.lattice),"))
        XCTAssertTrue(ws.contains("laid: newEngine.bars != nil, laying: newEngine.laying, showsFile: newEngine.showsFile, exactOnScreen: latticeExactOnScreen)"))
        XCTAssertTrue(ws.contains(": macStep ? LatticeMacMakeCopy.button : \"Lattice\","), "the label: Make print-accurate or Lattice")
        XCTAssertTrue(ws.contains("if ok { requestLatticeRun() }"), "the press: the Lattice run (the Mac's file and check)")
        let x = try XCTUnwrap(ws.range(of: "    var latticeExactOnScreen: Bool {"))
        XCTAssertTrue(String(ws[x.upperBound...].prefix(400)).contains("printAccurate: appSettings.latticePrintAccurate, quality: newEngine.organicQuality"))
        XCTAssertEqual(ws.components(separatedBy: "exact: true").count - 1, 2, "no new exact lay asked (Notes23PrintFlowTests' two)")
        // the button while it runs: the print file's words
        let normal = LatticePrintFlow.Look(title: "Lattice", subtitle: "Organic Grown · 1 group", state: .ready, progress: nil)
        let flow = LatticePrintFlow()
        let id = UUID()
        flow.begin(project: id, key: nil)
        LatticeMacMake.shared.begin(project: id, path: nil, fileOnly: true, cancel: {})
        let v = LatticeRunButtonFlow(flow: flow, projectID: id, normal: normal, layProgress: nil, fileRunning: false,
                                     current: { nil }, tap: { _ in })
        XCTAssertEqual(v.look().subtitle, LatticePrintFlowCopy.making, "★ \"Making the print file\", never print-accurate again")
        LatticeMacMake.shared.begin(project: id, path: nil, fileOnly: false, cancel: {})
        XCTAssertEqual(v.look().subtitle, LatticeMacMakeCopy.making, "RED CONTROL: from a Draft: Making print-accurate")
    }

    // MARK: A4 · the drawing follows the print file; the line counts strands

    /// A print file's result whose report says its first two triangles are the solid's: a quad (the solid), then a closed
    /// tetrahedron (the lattice).
    static func fileResult(base: Int? = 2) -> OptimizeOutcome {
        let v: [Float] = [0, 0, 0, 1, 0, 0, 1, 1, 0, 0, 1, 0,
                          10, 10, 10, 11, 10, 10, 10, 11, 10, 10, 10, 11]
        let t: [Int32] = [0, 1, 2, 0, 2, 3, 4, 6, 5, 4, 5, 7, 4, 7, 6, 5, 6, 7]
        var report: [String: Any] = ["layout": [:] as [String: Any], "mesh": [:] as [String: Any],
                                     "print_check": [:] as [String: Any]]
        if let base { report["base_triangles"] = base }
        let variant = OptimizeVariant(requestedVolumeFraction: 0.5, achievedVolumeFraction: 0.5, massGrams: 10, supportVolumeVoxels: 0,
                                      meshTriangleCount: 6, worstCaseMargin: 2, accepted: true, v3Passes: true,
                                      meshVertices: v, meshIndices: t)
        return OptimizeOutcome(variants: [variant], stoppedOnMargin: false, cancelled: false, acceptedCount: 1,
                               computedRemotely: true,
                               reportJSON: try? JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]))
    }

    /// The saved file's lattice: the triangles after the solid's. RED CONTROL: a file without "base_triangles" draws nothing.
    func testTheSavedFilesLatticeIsItsShells() throws {
        let o = Self.fileResult()
        XCTAssertTrue(LatticeSavedResult.isPrintFile(o), "premise: a print file's result")
        XCTAssertEqual(LatticeSavedFile.baseTriangles(o), 2)
        let mesh = try XCTUnwrap(try LatticeSavedFile.mesh(o, token: 1))
        XCTAssertEqual(mesh.triangleCount, 4, "★ the lattice alone")
        XCTAssertNil(try LatticeSavedFile.mesh(Self.fileResult(base: nil), token: 1), "RED CONTROL: no base, nothing drawn")
        XCTAssertTrue(LatticeSavedFile.drawn(printAccurate: true, organic: true, laid: true, laying: false, showsFile: false, madeForNow: true))
        XCTAssertFalse(LatticeSavedFile.drawn(printAccurate: false, organic: true, laid: true, laying: false, showsFile: false,
                                              madeForNow: true), "RED CONTROL: Print-accurate preview off: the quick stand-in")
        XCTAssertFalse(LatticeSavedFile.drawn(printAccurate: true, organic: true, laid: true, laying: false, showsFile: false,
                                              madeForNow: false), "RED CONTROL: settings changed since the file")
        XCTAssertFalse(LatticeSavedFile.drawn(printAccurate: true, organic: true, laid: true, laying: true, showsFile: false,
                                              madeForNow: true), "never over a lay going")
        let ws = try FlexibleSource.code("WorkspacePlaceholder.swift")
        XCTAssertTrue(ws.contains(".onChange(of: savedPrintFileKey) { _ in drawSavedPrintFile() }"), "★ wired where the page always is")
        XCTAssertTrue(ws.contains("let o = LatticeSavedResult.madeForNow(project, ranWith: model.resultRanWith[project.id]) else { return }"))
    }

    /// ★ His part, Organic, Print-accurate preview on: the exact lattice laid on the iPad; the version's print file made for
    /// these settings is what is drawn (the file's mesh). A settings change lays the iPad's own preview again. The line under the
    /// preview counts strands. RED CONTROL: after the change no file is made for these settings.
    func testTheDrawingFollowsThePrintFileForTheseSettings() async throws {
        AppSettings.shared.latticePrintAccurate = true
        let p = try FlexiblePressFixtures.a1Project(3, self, facePrism: false).project
        p.lattice.flexible = nil
        p.lattice.chooseLatticeType(.structural)
        p.lattice.algorithm = "organic"
        p.lattice.wholePart = true
        var look = LatticeOrganicLook(); look.mode = .traced; look.lookPercent = 5
        p.lattice.organicLook = look
        let st = try Self.stress(p, key: 251)
        let preview = LatticeLayoutPreview()
        preview.update(project: p, on: true, stress: st)
        try await Self.settle(preview, "the exact lattice")
        XCTAssertEqual(preview.organicQuality, .exact, "premise: the exact lattice (Print-accurate preview on)")
        let strands = try XCTUnwrap(preview.organicNumbers?.strands)
        let line = try XCTUnwrap(preview.timing?.line)
        XCTAssertTrue(line.hasSuffix(NumberFormatter.localizedString(from: NSNumber(value: strands), number: .decimal) + " strands"),
                      "★ the line counts strands: \(line)")
        XCTAssertFalse(line.contains("struts"), "RED CONTROL: never the drawn pieces as struts: \(line)")
        XCTAssertFalse(preview.showsFile, "premise: the iPad's own lattice")

        // the version's print file, made for these settings
        let file = Self.fileResult()
        p.run.restoreOutcome(file)
        let ranWith = try XCTUnwrap(p.snapshot(savedAt: Date()))
        let made = try XCTUnwrap(LatticeSavedResult.madeForNow(p, ranWith: ranWith), "★ made for these settings")
        LatticeSavedFileDrawing.shared.draw(made, project: p, preview: preview, stress: st)
        let end = Date().addingTimeInterval(20)
        while !preview.showsFile, Date() < end { try await Task.sleep(nanoseconds: 50_000_000) }
        XCTAssertTrue(preview.showsFile, "★ the print file's lattice is what is drawn")
        XCTAssertEqual(preview.bars?.fileMesh?.triangleCount, 4, "★ the file's own mesh")

        // a settings change: the iPad's own preview again
        look.lookPercent = 7
        p.lattice.organicLook = look
        XCTAssertNil(LatticeSavedResult.madeForNow(p, ranWith: ranWith), "RED CONTROL: the file is not these settings' any more")
        preview.update(project: p, on: true, stress: st)
        try await Self.settle(preview, "the new settings' lattice")
        XCTAssertFalse(preview.showsFile, "★ after a change: the iPad's own preview")
        XCTAssertNotNil(preview.bars)
    }

    /// The line's words, and a lattice kept from before (its line saved saying "struts") says strands too.
    func testTheLineCountsStrands() {
        XCTAssertEqual(LatticeLayoutPreview.organicTimeLine(mode: .grown, draft: true, ms: 10_900, strands: 12_605),
                       "Organic Grown \u{00B7} Draft \u{00B7} laid in 10.9 s \u{00B7} 12,605 strands")
        var t = LatticeLayoutPreview.Timing(openMS: 0, readMS: 0, cellsMS: 0, barsMS: 0, bars: 66_519)
        t.organicLine = "Organic Grown \u{00B7} Draft \u{00B7} laid in 10.9 s \u{00B7} 66,519 struts"
        let n = LatticeLayoutPreview.OrganicNumbers(strands: 12_605, segments: 66_519, ms: 10_900, draft: true, limitsMeasured: true)
        XCTAssertEqual(LatticeLayoutPreview.inStrands(t, n)?.organicLine,
                       "Organic Grown \u{00B7} Draft \u{00B7} laid in 10.9 s \u{00B7} 12,605 strands")
        XCTAssertEqual(LatticeLayoutPreview.inStrands(t, nil)?.organicLine, t.organicLine, "nothing to count with: kept")
    }

    // MARK: helpers

    /// A stress pulling along x everywhere over the part's box (PreviewSpeedStage1Tests').
    static func stress(_ p: ProjectModel, key: Int) throws -> LatticeLayoutPreview.Stress {
        let b = try XCTUnwrap(LatticeLayoutPreview.box(p.importedMesh?.vertices ?? []))
        let h = 2.0
        let lo = SIMD3<Double>(b.lo) - 2, size = SIMD3<Double>(b.hi - b.lo) + 4
        let n = SIMD3<Int>(Int((size.x / h).rounded(.up)) + 1, Int((size.y / h).rounded(.up)) + 1, Int((size.z / h).rounded(.up)) + 1)
        let count = n.x * n.y * n.z
        var t = [Double](repeating: 0, count: 6 * count)
        for i in 0..<count { t[6 * i] = 10 }
        let f = LatticeDemandField(vonMises: [Float](repeating: 10, count: count), stressTensor: t, nx: n.x, ny: n.y, nz: n.z,
                                   origin: lo, spacingMM: h, provenance: .solidSim(date: Date(), resolution: 64))
        return .init(key: key, field: f, referenceMPa: 20)
    }

    static func settle(_ preview: LatticeLayoutPreview, _ what: String) async throws {
        let end = Date().addingTimeInterval(600)
        while preview.laying, Date() < end { try await Task.sleep(nanoseconds: 50_000_000) }
        XCTAssertFalse(preview.laying, "\(what): laid within 10 min")
    }
}

/// A scheduler that holds the run's work (it stays in flight until cancelled from the test).
struct Notes25HeldScheduler: RunScheduler {
    func runInBackground(_ work: @escaping () -> Void) {}
    func runOnMain(_ work: @escaping () -> Void) { work() }
}
#endif
