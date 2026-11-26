// Notes25FlowHostedTests — ★ his iPad notes 2026-11-23 15:35 EST on release 16, hosted at his two iPad sizes (13″ landscape,
// and portrait 820 × 1180):
//   A1 (Img 1): ONE pop-up for the whole print-accurate chain — at each stage exactly one pop-up is on screen (the Mac's card;
//      never the run's own card or its top-lane pill behind it), with "Run in the Background" and "Cancel"; Run in the
//      Background hides it while the run goes on, the Lattice button brings it back; Cancel stops the chain.
//   A2 (Img 4/5): the Lattice stage's Results tab (Setup │ Lattice │ Results), none in the ⌃; Topology's Results shows Topology's
//      results only; a version with both keeps both; the ways in (Versions, the notification, Approved) land on the Lattice
//      stage's Results tab.
// Model tests and pins: Notes25FlowTests.
#if canImport(AppKit) && canImport(MetalKit)
import XCTest
import SwiftUI
import AppKit
@testable import TopOptFlows
@testable import TopOptKit

@MainActor
final class Notes25FlowHostedTests: XCTestCase {
    private var root: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("topopt-notes25h-\(UUID().uuidString)", isDirectory: true)
    }
    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
        LatticeMacMake.shared.reset()
        LatticePrintFlow.shared.reset()
        AppPopups.shared.current = nil
        LatticeFileSpot.shared.clear()
    }

    static let sizes: [(String, CGSize)] = [("13″ landscape", AppBuildHost.landscape13), ("portrait", CGSize(width: 820, height: 1180))]

    @discardableResult
    private func waitFor(_ h: AppBuildHost, _ key: String, seconds: Double = 10) -> CGRect? {
        var waited = 0.0
        while h.frames.all[key] == nil, waited < seconds { h.pump(0.25); waited += 0.25 }
        return h.frames.all[key]
    }
    private func waitGone(_ h: AppBuildHost, _ key: String, seconds: Double = 10) {
        var waited = 0.0
        while h.frames.all[key] != nil, waited < seconds { h.pump(0.25); waited += 0.25 }
    }

    // MARK: A1 · one pop-up for the whole chain

    /// Every pop-up that could be up while the Mac makes the print file: its card, the run's own card, the run's top-lane pill,
    /// a centred pop-up.
    static let popUps = ["macMakeModal", "runCard", "lane-run-status", "appPopup"]
    private func upNow(_ h: AppBuildHost) -> [String] { Self.popUps.filter { h.frames.all[$0] != nil } }

    /// ★ "There should only be a single pop-up that contains everything - including a "Run in the Background" and "Cancel"
    /// button": the chain's run in flight on his A1 pad (Structural, the Lattice stage), at each stage exactly ONE pop-up —
    /// the Mac's card — with both buttons; Run in the Background leaves NO pop-up (the Lattice button shows the run) and the
    /// button's tap brings the same card back; Cancel stops the run and every pop-up goes. RED CONTROL: the same run without
    /// the card is shown by the run's own card (the second pop-up of his Img 1).
    func testOnePopUpForTheWholeChain() throws {
        for (name, size) in Self.sizes {
            let r = try FlexiblePressFixtures.a1Project(3, self, facePrism: true)
            let p = r.project
            p.lattice.flexible = nil
            p.lattice.chooseLatticeType(.structural)
            if let c = p.selection.groups.first(where: { $0.name == "Group C" }) { p.force.makeAnchor(c.id) }
            let h = AppBuildHost(WorkspacePlaceholder(model: r.app, project: p).overlay { LatticeMacMakeModal() }, size: size, test: self)
            h.pump(3)
            try h.pickFromMenu("capsuleMenu", "Structural", what: "\(name): the stage menu")
            h.pump(1)
            _ = try h.onScreen("latticeButton", "\(name): the Lattice button")

            // his press: the flow and the card begin, the run goes to the Mac (held there until cancelled)
            let mac = LatticeMacMake.shared
            LatticePrintFlow.shared.begin(project: p.id, key: nil)
            let run = p.run
            mac.begin(project: p.id, path: p.importedFile?.path, run: run, cancel: { run.cancel() })
            h.pump(1)
            XCTAssertEqual(upNow(h), ["macMakeModal"], "\(name): ★ waiting for the Mac: one pop-up")
            run.runner = { _, progress, _ in
                while progress(0, 1, 0) { usleep(50_000) }
                return OptimizeOutcome(variants: [], stoppedOnMargin: false, cancelled: true, acceptedCount: 0, computedRemotely: true)
            }
            run.start(RunRequest(modelPath: p.importedFile?.path ?? "", material: "PLA", materialsPath: "", rulesPath: "",
                                 resolution: 64, projectName: p.name, projectID: p.id).withJobMode(LatticeFileButton.jobMode),
                      remote: true, workerName: "Mac")
            h.pump(1.5)
            XCTAssertEqual(run.phase, .running, "premise: the run is on the Mac")
            XCTAssertEqual(upNow(h), ["macMakeModal"], "\(name): ★ the run going: still one pop-up (never the run's own card)")
            let bg = try h.probe("macMakeBackground", "\(name): ★ Run in the Background")
            let cancel = try h.probe("macMakeCancel", "\(name): ★ Cancel")
            let card = try h.onScreen("macMakeModal", "\(name): the card")
            XCTAssertTrue(card.contains(bg) && card.contains(cancel), "\(name): ★ both buttons inside the one card")
            mac.said(LatticeMacMakeCopy.laying)
            h.pump(0.5)
            XCTAssertEqual(upNow(h), ["macMakeModal"], "\(name): ★ laying the lattice: one pop-up")
            mac.fileArrived(); mac.drawn(checkFollows: true)
            h.pump(1)
            XCTAssertEqual(upNow(h), ["macMakeModal"], "\(name): ★ the file drawn, the check going on: the SAME one pop-up")
            XCTAssertEqual(mac.stage, LatticeMacMakeCopy.checking, "\(name): ★ its line says the check")

            // Run in the Background, and back
            try h.tap("macMakeBackground", "\(name): Run in the Background", settle: 1)
            XCTAssertEqual(upNow(h), [], "\(name): ★ in the background: no pop-up at all")
            XCTAssertEqual(run.phase, .running, "\(name): ★ the run goes on")
            XCTAssertNotNil(h.frames.all["latticeMakingFile"], "\(name): ★ the Lattice button shows it")
            try h.tap("latticeButton", "\(name): the Lattice button while it runs", settle: 1)
            XCTAssertEqual(upNow(h), ["macMakeModal"], "\(name): ★ its tap brings the same card back")

            // Cancel stops the chain
            try h.tap("macMakeCancel", "\(name): Cancel", settle: 1)
            var waited = 0.0
            while run.phase == .running, waited < 10 { h.pump(0.25); waited += 0.25 }
            XCTAssertNotEqual(run.phase, .running, "\(name): ★ Cancel stopped the run")
            h.pump(1)
            XCTAssertEqual(upNow(h), [], "\(name): ★ nothing left up")
            XCTAssertFalse(mac.isMaking(p.id))

            // RED CONTROL: the same run, no card carrying it — the run's own card is up (his Img 1's second pop-up)
            run.runner = { _, progress, _ in
                while progress(0, 1, 0) { usleep(50_000) }
                return OptimizeOutcome(variants: [], stoppedOnMargin: false, cancelled: true, acceptedCount: 0, computedRemotely: true)
            }
            run.start(RunRequest(modelPath: p.importedFile?.path ?? "", material: "PLA", materialsPath: "", rulesPath: "",
                                 resolution: 64, projectName: p.name, projectID: p.id).withJobMode(LatticeFileButton.jobMode),
                      remote: true, workerName: "Mac")
            XCTAssertNotNil(waitFor(h, "runCard", seconds: 3), "\(name): RED CONTROL: without the card, the run's own card")
            run.cancel()
            waited = 0
            while run.phase == .running, waited < 10 { h.pump(0.25); waited += 0.25 }
            LatticePrintFlow.shared.reset()
        }
    }

    // MARK: A5 · the cell lattice's print file: the same one card; a stop ends in the centred pop-up

    /// His A1 pad, Structural with cells (never Organic), on the Lattice stage, the card and the pop-ups mounted as RootView
    /// mounts them. `aesthetic`: the Aesthetic lattice (walls cut cells) in place of Structural.
    private func cellStage(_ size: CGSize, organic: Bool = false, lattice: Bool = true,
                           aesthetic: Bool = false) throws -> (AppBuildHost, ProjectModel) {
        let r = try FlexiblePressFixtures.a1Project(3, self, facePrism: true)
        let p = r.project
        p.lattice.flexible = nil
        p.lattice.chooseLatticeType(aesthetic ? .aesthetic : .structural)
        if aesthetic { p.lattice.letWallsCutCells = true }
        if organic { p.lattice.algorithm = "organic" }
        if let c = p.selection.groups.first(where: { $0.name == "Group C" }) { p.force.makeAnchor(c.id) }
        let h = AppBuildHost(WorkspacePlaceholder(model: r.app, project: p).overlay { LatticeMacMakeModal() }.overlay { AppPopupLayer() },
                             size: size, test: self)
        h.pump(3)
        if lattice {
            try h.pickFromMenu("capsuleMenu", aesthetic ? "Aesthetic" : "Structural", what: "\(size): the stage menu")
            h.pump(1)
        }
        return (h, p)
    }

    private func fileRun(_ p: ProjectModel, failing: Error) {
        p.run.runner = { _, progress, _ in
            var n = 0
            while progress(0, 1, 0), n < 50 { usleep(50_000); n += 1 }
            throw failing
        }
        p.run.start(RunRequest(modelPath: p.importedFile?.path ?? "", material: "PLA", materialsPath: "", rulesPath: "",
                               resolution: 64, projectName: p.name, projectID: p.id).withJobMode(LatticeFileButton.jobMode),
                    remote: true, workerName: "Mac")
    }

    /// ★ "ensure that the regular lattice gets a similar export pop-up, with an animation and everything": a CELL lattice's
    /// print file wears the same one card — "Making the print file", the animation, one clock, Run in the Background · Cancel —
    /// never the run's own "LATTICING" card or its "Tap to view" pill. The Mac refuses it (his bridge, after ~7 min): the card
    /// ends in ONE centred pop-up with the reason in plain words, "Show me", "Change settings" and OK; the button is Lattice
    /// again (never "Couldn't finish"). "Show me" marks the spot on the part.
    func testACellLatticesPrintFileWearsTheSameCardAndARefusalEndsInThePopUp() throws {
        for (name, size) in Self.sizes {
            AppPopups.shared.current = nil
            // ★ RE-PINNED (notes30, R1): builder N2's notes29 cell floor with Allow quilt off (his 11-25 "limit both when 'Allow
            // quilt' is turned off"): Structural's 5 cells across his 20 mm pad would be 4 mm, under the 4.74 mm two-line floor,
            // so it lays nothing ("This lattice can't be laid" up, the button Cannot Lattice). Aesthetic's cells lay there.
            let (h, p) = try cellStage(size, aesthetic: true)
            XCTAssertFalse(LatticeLayoutPreview.organic(p.lattice), "premise: a cell lattice")
            XCTAssertNil(AppPopups.shared.current, "\(name): premise: the lattice lays (no pop-up says it can't)")
            let mac = LatticeMacMake.shared
            LatticePrintFlow.shared.begin(project: p.id, key: nil)
            let run = p.run
            mac.begin(project: p.id, path: p.importedFile?.path, run: run, fileOnly: true, cancel: { run.cancel() })
            let box = try XCTUnwrap(LatticeLayoutPreview.box(p.importedMesh?.vertices ?? []))
            let top: [Double] = [Double(box.lo.x + box.hi.x) / 2, Double(box.lo.y + box.hi.y) / 2, Double(box.hi.z)]
            let refusal = try XCTUnwrap(LatticeFileRefusal.parse(Notes25FlowTests.refusedReport(at: [top])))
            fileRun(p, failing: LatticeFileRun.Failure(refusal.plain, refusal: refusal))
            h.pump(1)
            XCTAssertEqual(run.phase, .running, "premise: the file is being made")
            XCTAssertEqual(upNow(h), ["macMakeModal"], "\(name): ★ one pop-up: the same card (never the run's own)")
            XCTAssertEqual(mac.title, LatticeMacMakeCopy.fileTitle, "\(name): ★ \"Making the print file\"")
            _ = try h.probe("macMakeBackground", "\(name): ★ Run in the Background")
            _ = try h.probe("macMakeCancel", "\(name): ★ Cancel")
            try h.tap("macMakeBackground", "\(name): Run in the Background", settle: 0.6)
            XCTAssertEqual(upNow(h), [], "\(name): ★ in the background: no card, no pill")
            try h.tap("latticeButton", "\(name): the Lattice button", settle: 0.6)
            XCTAssertEqual(upNow(h), ["macMakeModal"], "\(name): ★ the button brings it back")

            var waited = 0.0
            while run.phase == .running, waited < 15 { h.pump(0.25); waited += 0.25 }
            h.pump(1)
            XCTAssertEqual(upNow(h), ["appPopup"], "\(name): ★ the stop: ONE centred pop-up, never nothing")
            let pop = try XCTUnwrap(AppPopups.shared.current)
            XCTAssertEqual(pop.title, LatticeMacMakeCopy.failedTitle)
            XCTAssertEqual(pop.text, refusal.plain, "\(name): ★ the engine's reason, plainly")
            XCTAssertEqual(AppPopups.shared.action?.title, LatticeFileRefusal.showMe)
            XCTAssertEqual(AppPopups.shared.second?.title, LatticeFileRefusal.changeSettings)
            XCTAssertEqual(AppPopups.shared.dismissTitle, LatticeFileRefusal.ok)
            XCTAssertNil(h.frames.all["latticeMakingFile"], "\(name): ★ the button is Lattice again")
            XCTAssertNotEqual(p.run.phase, .failed, "the failure is not left up")

            let showMe = AppPopups.shared.action?.run, change = AppPopups.shared.second?.run
            AppPopups.shared.current = nil
            showMe?()
            XCTAssertNotNil(waitFor(h, "latticeFileSpot", seconds: 3), "\(name): ★ Show me: the spot marked on the part")
            if let spot = h.frames.all["latticeFileSpot"] {
                XCTAssertTrue(CGRect(origin: .zero, size: h.size).contains(CGPoint(x: spot.midX, y: spot.midY)), "\(name): on screen")
            }
            change?()
            XCTAssertNotNil(waitFor(h, "settingToChangeNote", seconds: 3),
                            "\(name): ★ Change settings: the Lattice page, the field named with what to try")
            XCTAssertEqual(SettingToChange.shared.ask?.field, LatticeWizardSetting.cellSize.rawValue)
            LatticeFileSpot.shared.clear()
            SettingToChange.shared.ask = nil

            // ★ Auto adjusted it (his words; the engine side is 362's): "Lattice again" first, then Change settings, Show me
            var auto = refusal
            auto.autoAdjusted = true
            auto.adjusted = [.init(setting: "Cell size", from: "4 mm", to: "5 mm")]
            mac.begin(project: p.id, path: p.importedFile?.path, run: run, fileOnly: true, cancel: { run.cancel() })
            fileRun(p, failing: LatticeFileRun.Failure(auto.plain, refusal: auto))
            waited = 0
            while run.phase == .running, waited < 15 { h.pump(0.25); waited += 0.25 }
            h.pump(1)
            XCTAssertEqual(upNow(h), ["appPopup"], "\(name): one pop-up")
            XCTAssertTrue(AppPopups.shared.current?.text.hasPrefix(LatticeFileRefusal.autoAdjustedText) ?? false, "\(name): ★ his words")
            XCTAssertEqual(AppPopups.shared.action?.title, LatticeFileRefusal.latticeAgain, "\(name): ★ Lattice again first")
            XCTAssertEqual(AppPopups.shared.second?.title, LatticeFileRefusal.changeSettings)
            XCTAssertEqual(AppPopups.shared.third?.title, LatticeFileRefusal.showMe)
            XCTAssertFalse(AppPopups.shared.dismissShown, "\(name): the three buttons, no fourth")
            AppPopups.shared.current = nil
        }
    }

    /// ★ notes30 (builder R1; his notes25 rule A1: one pop-up for the whole chain): a lay that lands while this part's print file
    /// is being made raises no pop-up of its own — its error card's backdrop sat over the chain's card and took "Run in the
    /// Background". (Structural on his 20 mm pad lays nothing since notes29's cell floor, so its "This lattice can't be laid"
    /// lands a moment after the stage opens.) The chain goes to the background, the stage opens, the lay lands: nothing pops
    /// up, and the Lattice button brings the card back alone. RED CONTROL (`controlLayPopUpOverTheChain`): the lay's pop-up.
    func testALayLandingWhileThePrintFileIsMadeRaisesNoPopUpOfItsOwn() throws {
        defer { LatticeLayoutPreview.controlLayPopUpOverTheChain = false }
        for control in [false, true] {
            let name = control ? "RED CONTROL" : "13″ landscape"
            AppPopups.shared.current = nil
            LatticeLayoutPreview.controlLayPopUpOverTheChain = control
            let (h, p) = try cellStage(AppBuildHost.landscape13, lattice: false)
            let mac = LatticeMacMake.shared
            LatticePrintFlow.shared.begin(project: p.id, key: nil)
            let run = p.run
            mac.begin(project: p.id, path: p.importedFile?.path, run: run, fileOnly: true, cancel: { run.cancel() })
            run.runner = { _, progress, _ in
                while progress(0, 1, 0) { usleep(50_000) }   // in flight until Cancel
                throw CancellationError()
            }
            run.start(RunRequest(modelPath: p.importedFile?.path ?? "", material: "PLA", materialsPath: "", rulesPath: "",
                                 resolution: 64, projectName: p.name, projectID: p.id).withJobMode(LatticeFileButton.jobMode),
                      remote: true, workerName: "Mac")
            h.pump(1)
            XCTAssertEqual(upNow(h), ["macMakeModal"], "\(name): premise: the chain's card")
            try h.tap("macMakeBackground", "\(name): Run in the Background", settle: 0.6)
            XCTAssertEqual(upNow(h), [], "\(name): premise: in the background")
            let held = LatticeLayoutPreview.solidPopUpsHeld, raised = LatticeLayoutPreview.solidPopUpsRaised
            try h.pickFromMenu("capsuleMenu", "Structural", what: "\(name): the stage menu")
            var waited = 0.0
            while LatticeLayoutPreview.solidPopUpsHeld == held, LatticeLayoutPreview.solidPopUpsRaised == raised, waited < 60 {
                h.pump(0.25); waited += 0.25
            }
            h.pump(0.5)
            XCTAssertEqual(run.phase, .running, "\(name): premise: the file is still being made")
            if control {
                XCTAssertGreaterThan(LatticeLayoutPreview.solidPopUpsRaised, raised, "RED CONTROL: the lay raised its pop-up")
                XCTAssertEqual(upNow(h), ["appPopup"], "RED CONTROL: the lay's pop-up over the chain")
            } else {
                XCTAssertGreaterThan(LatticeLayoutPreview.solidPopUpsHeld, held, "\(name): premise: the lay landed all solid")
                XCTAssertEqual(LatticeLayoutPreview.solidPopUpsRaised, raised, "\(name): ★ it raised nothing")
                XCTAssertEqual(upNow(h), [], "\(name): ★ in the background: still nothing up")
                try h.tap("latticeButton", "\(name): the Lattice button", settle: 0.6)
                XCTAssertEqual(upNow(h), ["macMakeModal"], "\(name): ★ the card comes back alone")
            }
            AppPopups.shared.current = nil
            run.cancel()
            waited = 0
            while run.phase == .running, waited < 10 { h.pump(0.25); waited += 0.25 }
            mac.reset()
            LatticePrintFlow.shared.reset()
            AppPopups.shared.current = nil
        }
    }

    /// ★ "the Mac did not answer" still asks as before (Organic): Try again, Make it on the iPad, Cancel.
    func testAMacThatDidNotAnswerStillAsksTryAgainOrTheIPad() throws {
        for (name, size) in Self.sizes {
            AppPopups.shared.current = nil
            let (h, p) = try cellStage(size, organic: true, lattice: false)
            let mac = LatticeMacMake.shared
            LatticePrintFlow.shared.begin(project: p.id, key: nil)
            let run = p.run
            mac.begin(project: p.id, path: p.importedFile?.path, run: run, cancel: { run.cancel() })
            mac.request = RunRequest(modelPath: p.importedFile?.path ?? "", material: "PLA", materialsPath: "", rulesPath: "",
                                     resolution: 64, projectName: p.name, projectID: p.id)
            fileRun(p, failing: LatticeFileRun.Failure("The Mac did not answer (timed out)", transient: true))
            var waited = 0.0
            while run.phase == .running, waited < 15 { h.pump(0.25); waited += 0.25 }
            h.pump(1)
            XCTAssertEqual(upNow(h), ["appPopup"], "\(name): one pop-up")
            XCTAssertEqual(AppPopups.shared.current?.title, LatticeMacMakeCopy.noMacTitle, "\(name): ★ the Mac's own pop-up")
            XCTAssertEqual(AppPopups.shared.action?.title, LatticeMacMakeCopy.tryAgain)
            XCTAssertEqual(AppPopups.shared.second?.title, LatticeMacMakeCopy.onIPad)
            AppPopups.shared.current = nil
        }
    }

    // MARK: A2 · the Lattice stage's Results tab

    /// His stand's lookalike part (a box, never his files), grouped: v1 a Topology result, v2 a print file's (Structural),
    /// v3 BOTH (the print file's last, Topology's kept beside it).
    private func part(_ tag: String) throws -> (AppModel, [String: UUID]) {
        let dir = root.appendingPathComponent(tag, isDirectory: true)
        let store = ProjectStore(rootDir: dir.appendingPathComponent("store", isDirectory: true))
        let src = dir.appendingPathComponent("import", isDirectory: true)
        try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
        let model = src.appendingPathComponent("Stand.stl")
        try ParityLibraryShots.boxSTL(SIMD3(60, 30, 20)).write(to: model, atomically: true, encoding: .utf8)
        var lattice = LatticeSettings()
        lattice.chooseLatticeType(.structural)
        var force = ForceModel()
        force.setGravity(direction: SIMD3(0, 0, -1))   // his part's gravity is set (the stage capsules show past setup)
        func save(_ t: Double, _ outcome: OptimizeOutcome?, other: OptimizeOutcome? = nil, lattice l: LatticeSettings? = nil) throws -> UUID {
            var snap = ProjectSnapshot(id: UUID(), name: "2040 Extrusion Stand", material: "PA12", process: .fdm,
                                       modelFileName: "model.stl", originalFileName: "Stand.stl",
                                       savedAt: Date(timeIntervalSince1970: t), selection: SelectionModel(), force: force,
                                       quality: .fast, optimized: outcome != nil)
            snap.lattice = l
            try store.save(snap, modelSource: model)
            if let outcome { try store.saveResults(try OutcomeCodec.encode(OutcomeCodec.dto(from: outcome)), id: snap.id) }
            if let other { try OutcomeCodec.encode(OutcomeCodec.dto(from: other)).write(to: store.otherResultsURL(id: snap.id)) }
            return snap.id
        }
        var f: [String: UUID] = [:]
        f["1"] = try save(100, AppBuildFixtures.outcome(2))
        f["2"] = try save(200, try Notes24ResultsTests.printFile(), lattice: lattice)
        f["3"] = try save(300, try Notes24ResultsTests.printFile(), other: AppBuildFixtures.outcome(2), lattice: lattice)
        let app = AppModel(materialsPath: Notes24ResultsTests.materialsPath, store: store,
                           remoteJobDefaults: UserDefaults(suiteName: "topopt.notes25h.\(UUID().uuidString)")!)
        app.loadMaterials()
        app.library.refresh()
        _ = app.library.proposal()
        try app.library.group(projectName: "Squish Mechanism", partIDs: nil)
        let exp = expectation(description: "summaries")
        app.library.loadSummaries { exp.fulfill() }
        wait(for: [exp], timeout: 30)
        app.library.route = .part(try XCTUnwrap(app.library.index.part(containing: try XCTUnwrap(f["2"]))).id)
        return (app, f)
    }

    /// Open a version from the Versions page with one tap on its picture.
    private func openVersion(_ h: AppBuildHost, _ mark: String, _ name: String) throws {
        let mini = try h.probe("library-mini-\(mark)", "\(name): \(mark)'s picture")
        h.click(CGPoint(x: mini.midX, y: mini.midY), settle: 2)
    }

    /// ★ The Lattice stage's Results is up: Results on screen, the Lattice stage's capsule over it with its Results tab right of
    /// Setup and Lattice, on one line.
    private func assertLatticeResultsTab(_ h: AppBuildHost, _ what: String) throws {
        XCTAssertNotNil(waitFor(h, "resultsExport"), "★ \(what): Results is up")
        let lattice = try XCTUnwrap(waitFor(h, "capsuleLattice", seconds: 3), "★ \(what): the Lattice stage's capsule")
        let setup = try h.onScreen("capsuleSetup", "\(what): Setup")
        let results = try h.probe("capsuleResults", "★ \(what): the Lattice stage's Results tab")
        XCTAssertGreaterThan(results.minX, lattice.maxX - 1, "★ \(what): next to Setup and Lattice, at their right")
        XCTAssertGreaterThan(lattice.minX, setup.maxX - 1)
        XCTAssertEqual(results.midY, lattice.midY, accuracy: 1, "★ \(what): one line")
    }

    /// ★ "It is meant to be next to the "Setting" tab at the very top, as it is in Topology" and "remove it from the ^ menu":
    /// the print file's version opens on the Lattice stage's Results tab; Setup goes back to editing; the ⌃ has no Results;
    /// the tab opens it again; Approved's tap lands there too. Topology's capsule has no Results for it (no Topology result).
    /// RED CONTROL: the Topology result's version opens on Topology's Results, with no Lattice capsule.
    func testTheLatticeStageHasItsResultsTabAndTheArrowHasNone() throws {
        for (name, size) in Self.sizes {
            let (app, f) = try part("tab-\(Int(size.width))")
            let h = AppBuildHost(AppBuildRoot(model: app), size: size, test: self)
            h.pump(3)
            try openVersion(h, "v2a", name)
            XCTAssertEqual(app.project?.id, f["2"])
            try assertLatticeResultsTab(h, "\(name): the Versions tap")
            try h.tap("capsuleLattice", "\(name): Lattice", settle: 1.5)
            XCTAssertNil(h.frames.all["resultsExport"], "\(name): back to editing")
            XCTAssertNotNil(h.frames.all["capsuleResults"], "\(name): ★ the tab stays while the version has its result")
            let offered = try h.pickFromMenu("latticeSplitMore", "no such item", what: "\(name): ⌃")
            XCTAssertFalse(offered.isEmpty, "\(name): the ⌃ was read")
            XCTAssertFalse(offered.contains { $0.hasPrefix("Results") }, "\(name): ★ no Results in the ⌃: \(offered)")
            try h.tap("capsuleResults", "\(name): the Results tab", settle: 1.5)
            try assertLatticeResultsTab(h, "\(name): the tab")
            XCTAssertEqual(app.project?.run.phase, .idle, "\(name): never a new run")
            // Approved's tap lands on the tab too
            try h.tap("capsuleLattice", "\(name): Lattice", settle: 1.5)
            XCTAssertNotNil(waitFor(h, "latticeApproved", seconds: 3), "\(name): Approved from the saved file")
            try h.tap("latticeButton", "\(name): Approved", settle: 1.5)
            try assertLatticeResultsTab(h, "\(name): Approved's tap")
            // Topology: no Results of its own for a print file
            try h.pickFromMenu("capsuleMenu", "Topology", what: "\(name): ● ‹ Topology")
            h.pump(1.5)
            XCTAssertNil(h.frames.all["resultsExport"], "\(name): ★ changing stage closes the Lattice stage's Results")
            XCTAssertNil(h.frames.all["capsuleLattice"], "\(name): on Topology")
            XCTAssertNil(h.frames.all["capsuleResults"], "\(name): ★ Topology's Results never shows the print file's result")

            // RED CONTROL: a Topology result opens on Topology
            let (app1, f1) = try part("tab1-\(Int(size.width))")
            let h1 = AppBuildHost(AppBuildRoot(model: app1), size: size, test: self)
            h1.pump(3)
            try openVersion(h1, "v1a", name)
            XCTAssertEqual(app1.project?.id, f1["1"])
            XCTAssertNotNil(waitFor(h1, "resultsExport"), "\(name): RED CONTROL: Topology's Results")
            XCTAssertNotNil(h1.frames.all["capsuleResults"])
            XCTAssertNil(h1.frames.all["capsuleLattice"], "\(name): RED CONTROL: Topology's capsule")
        }
    }

    /// ★ "so that I can ALSO run TO results and have *them* be in the Topology stage - keeping both in the same version": v3
    /// holds both. Its tap opens the print file's in the Lattice stage (its last); Topology's Results tab shows Topology's
    /// result (its two results, no print file's checks); back in the Lattice stage the print file's is still there.
    func testAVersionWithBothKeepsBothEachInItsStage() throws {
        for (name, size) in Self.sizes {
            let (app, f) = try part("both-\(Int(size.width))")
            let h = AppBuildHost(AppBuildRoot(model: app), size: size, test: self)
            h.pump(3)
            try openVersion(h, "v3a", name)
            XCTAssertEqual(app.project?.id, f["3"])
            try assertLatticeResultsTab(h, "\(name): v3's tap (its last result, the print file's)")
            let run = try XCTUnwrap(app.project?.run)
            XCTAssertTrue(LatticeSavedResult.isPrintFile(run.outcome(lattice: true)), "\(name): ★ the print file's")
            XCTAssertEqual(run.outcome(lattice: false)?.variants.count, 2, "\(name): ★ and Topology's, both kept")
            XCTAssertNotNil(waitFor(h, "resultsCheck-Print file ready", seconds: 3), "\(name): the print file's checks on screen")

            try h.pickFromMenu("capsuleMenu", "Topology", what: "\(name): ● ‹ Topology")
            h.pump(1.5)
            XCTAssertNil(h.frames.all["resultsExport"], "\(name): the stage change closed Results")
            try h.tap("capsuleResults", "\(name): ★ Topology's own Results tab", settle: 2)
            XCTAssertNotNil(waitFor(h, "resultsExport"), "\(name): ★ Topology's Results")
            XCTAssertNil(h.frames.all["capsuleLattice"], "\(name): on Topology")
            XCTAssertNil(h.frames.all["resultsCheck-Print file ready"], "\(name): ★ Topology's result, never the print file's")

            // (this lookalike has no anchor or load, so Topology's ● keeps its lattice row grey: back through the Versions page)
            app.backHome()
            app.library.route = .part(try XCTUnwrap(app.library.index.part(containing: try XCTUnwrap(f["3"]))).id)
            h.pump(2)
            try openVersion(h, "v3a", name)
            XCTAssertEqual(app.project?.id, f["3"])
            try assertLatticeResultsTab(h, "\(name): back in the Lattice stage")
            XCTAssertNotNil(waitFor(h, "resultsCheck-Print file ready", seconds: 3), "\(name): ★ the print file's, still")
            XCTAssertEqual(run.outcome(lattice: false)?.variants.count, 2, "\(name): ★ both still kept")
        }
    }

    /// ★ The notification after a Mac run lands on the Lattice stage's Results tab (the app on the Library).
    func testTheNotificationLandsOnTheLatticeResultsTab() throws {
        for (name, size) in Self.sizes {
            let (app, f) = try part("tap-\(Int(size.width))")
            let h = AppBuildHost(RootView(model: app), size: size, test: self)
            h.pump(3)
            RunNotificationRouter.shared.tapped(userInfo: RunResultRoute(projectID: try XCTUnwrap(f["2"]), lattice: true).userInfo)
            h.pump(1)
            XCTAssertEqual(app.project?.id, f["2"], "\(name): the run's version")
            try assertLatticeResultsTab(h, "\(name): the notification's tap")
            h.window.orderOut(nil); h.window.contentView = nil   // (one RootView alive at a time: Notes24ResultsHostedTests' note)
        }
    }
}
#endif
