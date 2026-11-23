// Notes24ResultsHostedTests — ★ his iPad notes 2026-11-23 (img 4, 5, 6), hosted at his two iPad sizes (13″ landscape, and
// portrait 820 × 1180): the Versions page's card for a version with a print file (its own result, never greyed) and its tap
// (Results in the Lattice stage); the notification's tap (straight to that Results); the Lattice stage's ⌃ "Results" and the
// way back to editing; the Lattice button's Approved from the saved file; Results never mounted behind the app. Model tests:
// Notes24ResultsTests.
#if canImport(AppKit) && canImport(MetalKit)
import XCTest
import SwiftUI
import AppKit
@testable import TopOptFlows
@testable import TopOptKit

// MARK: - hosted, his two iPad sizes

@MainActor
final class Notes24ResultsHostedTests: XCTestCase {
    private var root: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("topopt-notes24h-\(UUID().uuidString)", isDirectory: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    static let sizes: [(String, CGSize)] = [("13″ landscape", AppBuildHost.landscape13), ("portrait", CGSize(width: 820, height: 1180))]

    /// His stand's lookalike part (a box, never his files): v1 with a Topology result, v2 with the print file's result (a
    /// Structural lattice), v3 a draft from it; grouped, its numbers read, on its part page.
    private func part(_ tag: String, passes: Bool = true) throws -> (AppModel, [String: UUID]) {
        let dir = root.appendingPathComponent(tag, isDirectory: true)
        let store = ProjectStore(rootDir: dir.appendingPathComponent("store", isDirectory: true))
        let src = dir.appendingPathComponent("import", isDirectory: true)
        try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
        let model = src.appendingPathComponent("Stand.stl")
        try ParityLibraryShots.boxSTL(SIMD3(60, 30, 20)).write(to: model, atomically: true, encoding: .utf8)
        var lattice = LatticeSettings()
        lattice.chooseLatticeType(.structural)
        func save(_ t: Double, _ outcome: OptimizeOutcome?, lattice l: LatticeSettings? = nil) throws -> UUID {
            var snap = ProjectSnapshot(id: UUID(), name: "2040 Extrusion Stand", material: "PA12", process: .fdm,
                                       modelFileName: "model.stl", originalFileName: "Stand.stl",
                                       savedAt: Date(timeIntervalSince1970: t), selection: SelectionModel(), force: ForceModel(),
                                       quality: .fast, optimized: outcome != nil)
            snap.lattice = l
            try store.save(snap, modelSource: model)
            if let outcome { try store.saveResults(try OutcomeCodec.encode(OutcomeCodec.dto(from: outcome)), id: snap.id) }
            return snap.id
        }
        var f: [String: UUID] = [:]
        f["1"] = try save(100, AppBuildFixtures.outcome(1))
        let file = try Notes24ResultsTests.printFile(passes: passes)
        f["2"] = try save(200, file, lattice: lattice)
        f["3"] = try save(300, nil, lattice: lattice)
        let app = AppModel(materialsPath: Notes24ResultsTests.materialsPath, store: store,
                           remoteJobDefaults: UserDefaults(suiteName: "topopt.notes24h.\(UUID().uuidString)")!)
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

    @discardableResult
    private func waitFor(_ h: AppBuildHost, _ key: String, seconds: Double = 10) -> CGRect? {
        var waited = 0.0
        while h.frames.all[key] == nil, waited < seconds { h.pump(0.25); waited += 0.25 }
        return h.frames.all[key]
    }

    /// ★ Results up in the LATTICE stage: its Export on screen, the Lattice stage's capsule (Setup │ Lattice) over it, never
    /// Topology's (Setup │ Results).
    /// ★ RE-PINNED (notes25, his 11-23 Img 4: the Results tab is the Lattice stage's own, next to Setup and Lattice): the Lattice
    /// stage's capsule is Setup │ Lattice │ Results — a "Results" tab is there, with its "Lattice" (Topology's has none).
    private func assertResultsInTheLatticeStage(_ h: AppBuildHost, _ what: String) {
        XCTAssertNotNil(waitFor(h, "resultsExport"), "★ \(what): Results is up")
        XCTAssertNotNil(waitFor(h, "capsuleLattice", seconds: 3), "★ \(what): in the Lattice stage (its capsule over Results)")
        XCTAssertNotNil(h.frames.all["capsuleResults"], "★ \(what): the Lattice stage's own Results tab")
    }

    /// ★ "The result should NOT be greyed out on the version screen" / "accessible from the Versions page just by tapping onto
    /// the version": the print file's version is a version with its result (its OWN picture, never a draft's), and a tap on it
    /// opens its Results in the Lattice stage. RED CONTROL: the Topology result's version opens on Topology.
    func testTheVersionsCardShowsItsOwnResultAndItsTapOpensResultsInTheLatticeStage() throws {
        for (name, size) in Self.sizes {
            let (app, f) = try part("card-\(Int(size.width))")
            let h = AppBuildHost(AppBuildRoot(model: app), size: size, test: self)
            h.pump(3)
            XCTAssertFalse(app.library.isDraft(try XCTUnwrap(app.library.version(try XCTUnwrap(f["2"])))), "\(name): ★ not a draft")
            XCTAssertNil(h.frames.all["library-version-v2-draft"], "\(name): ★ no Draft tag")
            let mini = try h.probe("library-mini-v2a", "\(name): ★ v2's OWN result picture, a 44 pt target")
            h.click(CGPoint(x: mini.midX, y: mini.midY), settle: 2)
            XCTAssertEqual(app.project?.id, f["2"], "\(name): v2 opened")
            assertResultsInTheLatticeStage(h, "\(name): v2's tap")

            // RED CONTROL: the Topology result's version
            let (app1, f1) = try part("card1-\(Int(size.width))")
            let h1 = AppBuildHost(AppBuildRoot(model: app1), size: size, test: self)
            h1.pump(3)
            let m1 = try h1.probe("library-mini-v1a", "\(name): v1's picture")
            h1.click(CGPoint(x: m1.midX, y: m1.midY), settle: 2)
            XCTAssertEqual(app1.project?.id, f1["1"])
            XCTAssertNotNil(waitFor(h1, "capsuleResults"), "\(name): RED CONTROL: a Topology result opens on Topology")
            XCTAssertNil(h1.frames.all["capsuleLattice"], "\(name): RED CONTROL: Topology's capsule (★ notes25)")
        }
        let src = try FlexibleSource.code("LibraryViews.swift")
        XCTAssertTrue(src.contains("LibraryPicture(image: parentPicture, dim: false)"), "★ a draft's card is never greyed either")
    }

    /// ★ "If going to edit it, the "results" screen should be in the Lattice Stage": from Results the Lattice stage's capsule
    /// goes back to editing (Setup), and there ⌃ always has "Results", which opens it again — never a new run. The Lattice
    /// button reads Approved from the SAVED print file (this launch never made it). RED CONTROL: a print file that failed its
    /// checks is not Approved.
    /// ★ RE-PINNED (notes25, his follow-up: "when adding the Results tab to lattice, remove it from the ^ menu"): the ⌃ has no
    /// "Results" any more; the capsule's Results tab opens it again — never a new run.
    func testTheLatticeStagesArrowOpensResultsAndTheButtonIsApprovedFromTheSavedFile() throws {
        for (name, size) in Self.sizes {
            for passes in [true, false] {
                let (app, f) = try part("arrow-\(Int(size.width))-\(passes)", passes: passes)
                let h = AppBuildHost(AppBuildRoot(model: app), size: size, test: self)
                h.pump(3)
                let mini = try h.probe("library-mini-v2a", "\(name): v2's picture")
                h.click(CGPoint(x: mini.midX, y: mini.midY), settle: 2)
                assertResultsInTheLatticeStage(h, "\(name)")
                try h.tap("capsuleSetup", "\(name): ★ the Lattice stage's Setup, over Results", settle: 1.5)
                XCTAssertNil(h.frames.all["resultsExport"], "\(name): ★ back to editing in the Lattice stage")
                _ = try h.onScreen("latticeSplit", "\(name): the Lattice stage's corner")
                if passes {
                    XCTAssertNotNil(waitFor(h, "latticeApproved", seconds: 3), "\(name): ★ Approved, from the saved print file")
                } else {
                    XCTAssertNil(h.frames.all["latticeApproved"], "\(name): RED CONTROL: a file that failed its checks")
                    continue
                }
                let run = try XCTUnwrap(app.project?.run)
                let offered = try h.pickFromMenu("latticeSplitMore", "no such item", what: "\(name): ⌃")
                XCTAssertFalse(offered.isEmpty, "\(name): the ⌃ was read")
                XCTAssertFalse(offered.contains { $0.hasPrefix(LatticeResultsTab.title) }, "\(name): ★ no Results row: \(offered)")
                // (this lookalike's gravity is not set, so the stage's capsule waits for it: Approved's tap opens it here; the
                // capsule's Results tab is Notes25FlowHostedTests', on a part with its gravity)
                try h.tap("latticeButton", "\(name): ★ Approved's tap", settle: 1.5)
                XCTAssertNotNil(waitFor(h, "resultsExport"), "\(name): ★ it opens the result again")
                XCTAssertEqual(run.phase, .idle, "\(name): ★ never a new run")
                XCTAssertEqual(app.project?.id, f["2"])
            }
        }
    }

    /// ★ "Tapping the notification should bring you RIGHT to the result screen. Nothing else.": the app on the Library, his
    /// tap opens the print file's version on its Results in the Lattice stage.
    func testTheNotificationsTapOpensTheResultInTheLatticeStage() throws {
        for (name, size) in Self.sizes {
            let (app, f) = try part("tap-\(Int(size.width))")
            let h = AppBuildHost(RootView(model: app), size: size, test: self)
            h.pump(3)
            XCTAssertEqual(app.screen, .home, "premise: on the Library")
            RunNotificationRouter.shared.tapped(userInfo: RunResultRoute(projectID: try XCTUnwrap(f["2"]), lattice: true).userInfo)
            h.pump(1)
            XCTAssertEqual(app.project?.id, f["2"], "\(name): ★ the run's version")
            assertResultsInTheLatticeStage(h, "\(name): the tap")
            XCTAssertNil(h.frames.all["resultOpeningCover"], "\(name): the cover is gone")
            XCTAssertNil(RunNotificationRouter.shared.pending, "taken")
            // (362, release 16: this size's app closed before the next one's — two RootViews alive at once both hear the one
            // router, and the first, whose store lacks the next app's version, took its tap)
            h.window.orderOut(nil); h.window.contentView = nil
        }
    }

    /// ★ The Results screen never MOUNTS while the app is not in front (its big mesh behind Sidecar ended his app): asked to
    /// open then, it opens as the app comes back. RED CONTROL: in front, it opens at once.
    func testResultsNeverMountBehindTheAppAndOpenWhenItComesBack() throws {
        for (name, size) in Self.sizes {
            let (app, _) = try part("behind-\(Int(size.width))")
            let h = AppBuildHost(AppBuildRoot(model: app), size: size, test: self)
            h.pump(3)
            app.sceneChanged(active: false)
            let mini = try h.probe("library-mini-v2a", "\(name): v2's picture")
            h.click(CGPoint(x: mini.midX, y: mini.midY), settle: 2)
            XCTAssertEqual(app.screen, .workspace, "\(name): the version opened")
            h.pump(1)
            XCTAssertNil(h.frames.all["resultsExport"], "\(name): ★ Results not mounted behind the app")
            app.sceneChanged(active: true)
            XCTAssertNotNil(waitFor(h, "resultsExport"), "\(name): ★ it opens as the app comes back")
        }
    }
}
#endif
