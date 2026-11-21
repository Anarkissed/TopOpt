// LibrarySameSettingsHostedTests — B5 (ledger note 3; the reviewer's (a), 11-04 02:44Z: a cached per-version check).
//
// His words (note 3): "after running an optimization, running it again doesn't work". The design: after a run lands, a
// change makes a draft and Optimize is live again ("Optimize as v2"); "If nothing changed, Optimize stays grey with one
// line under it: 'Same settings as v6'." B3 built that line for a project with no results to re-run over; a Library
// version WITH results offered "Optimize as v2" for the same settings (it would only make this version again), and a
// version reopened later never knew what it ran with. Now: in a Library version, the same setup as its run greys Optimize,
// in the session that ran it and after a reopen (its saved run_job.json against the job this setup would send).
//
// The REAL page, REAL clicks; the core is `RunModel.hostedTestRunner` (lookalike results, nothing sent anywhere).
#if canImport(AppKit) && canImport(MetalKit)
import XCTest
import SwiftUI
@testable import TopOptFlows
@testable import TopOptKit

@MainActor
final class LibrarySameSettingsHostedTests: XCTestCase {

    private func clickOptimize(_ h: AppBuildHost, _ what: String) throws {
        let f = try h.onScreen("optimizeSplit", what)
        h.click(CGPoint(x: f.minX + (f.width - 46) / 2, y: f.midY), settle: 1)
    }

    private func waitUntil(_ h: AppBuildHost, _ s: Double, _ what: String, _ cond: () -> Bool) {
        let end = Date().addingTimeInterval(s)
        while !cond(), Date() < end { h.pump(0.1) }
        XCTAssertTrue(cond(), "★ timed out: \(what)")
    }

    /// His grouped Library, one Structural part whose first run has landed and been saved (B1's fixture).
    private func landed() throws -> (AppBuildHost, AppModel, ProjectModel, ProjectStore, RerunAfterLandHostedTests.Runs) {
        let r = try FlexiblePressFixtures.a1Project(3, self, facePrism: false)
        let app = r.app, p = r.project, disk = ProjectStore(rootDir: r.root)
        p.lattice.flexible = nil
        p.lattice.chooseLatticeType(.structural)
        if let c = p.selection.groups.first(where: { $0.name == "Group C" }) { p.force.makeAnchor(c.id) }
        app.library.refresh()
        try app.library.group(projectName: "Squish Mechanism", partIDs: nil)
        let runs = RerunAfterLandHostedTests.Runs()
        RunModel.hostedTestRunner = { _, _, _ in runs.add(); return AppBuildFixtures.outcome() }
        addTeardownBlock { RunModel.hostedTestRunner = nil }
        // the app's root: Home shows the Library, so a reopen mounts a FRESH workspace, as on his iPad
        XCTAssertEqual(app.screen, .workspace, "the fixture opened the part")
        let h = AppBuildHost(AppBuildRoot(model: app), size: AppBuildHost.landscape13, test: self)
        h.pump(3)
        try clickOptimize(h, "Optimize, first run")
        waitUntil(h, 15, "the first run lands") { p.run.phase == .succeeded }
        waitUntil(h, 10, "its results are saved") { disk.hasPersistedResults(id: p.id) }
        h.pump(0.5)
        return (h, app, p, disk, runs)
    }

    /// Reopen the version as the Library does (a fresh workspace, its onAppear). `job`: the run_job.json a worker run leaves
    /// beside its results (the test runner reports none), written while the version is closed.
    private func reopen(_ h: AppBuildHost, _ app: AppModel, _ id: UUID, job: Data? = nil) throws -> ProjectModel {
        app.backHome()
        h.pump(0.5)
        XCTAssertNil(h.frames.all["optimizeSplit"], "Home: the workspace is gone (unmounted), as on his iPad")
        if let job { try app.library.store.saveRelatticeArtifacts(jobJSON: job, designBin: Data(), id: id) }
        app.open(try XCTUnwrap(app.recentProjects.first { $0.id == id }))
        waitUntil(h, 10, "the version reopens") { app.project?.id == id }
        h.pump(2)
        return try XCTUnwrap(app.project)
    }

    func testTheSameJobIsTheSameRunWhateverItsKeyOrderOrModelName() throws {
        func json(_ o: Any) throws -> Data { try JSONSerialization.data(withJSONObject: o) }
        let a = try json(["model": "Arm.stl", "resolution": 64, "loads": ["groups": [["faces": [3, 4], "fz": -9.8]]]] as [String: Any])
        let b = try json(["loads": ["groups": [["fz": -9.8, "faces": [3, 4]]]], "resolution": 64, "model": "model.stl"] as [String: Any])
        let c = try json(["model": "model.stl", "resolution": 96, "loads": ["groups": [["faces": [3, 4], "fz": -9.8]]]] as [String: Any])
        XCTAssertTrue(LibrarySameSettings.sameJob(a, b), "★ key order and the model's file name never make a different run")
        XCTAssertFalse(LibrarySameSettings.sameJob(a, c), "a changed setting is a different run")
        XCTAssertFalse(LibrarySameSettings.sameJob(a, Data("not json".utf8)), "an unreadable job is never the same")
    }

    /// In the session that ran it: nothing changed → grey, "Same settings as v1", and a tap makes no v2; a change → live again.
    func testAVersionWithResultsAndNothingChangedReadsSameSettings() throws {
        let (h, _, p, _, runs) = try landed()
        _ = try h.onScreen("optimizeSameSettings", "★ note 3: Optimize grey with \"Same settings as v1\"")
        try clickOptimize(h, "Optimize with nothing changed")
        XCTAssertNil(h.frames.all["nextVersionOptimize"], "★ no Optimize as v2 card: it would only make v1 again")
        XCTAssertEqual(runs.count, 1, "nothing ran")
        p.force.safetyMargin = 2.0
        h.pump(0.6)
        XCTAssertNil(h.frames.all["optimizeSameSettings"], "a change: Optimize is live again")
        try clickOptimize(h, "Optimize after a change")
        _ = try h.onScreen("nextVersionOptimize", "★ the Optimize as v2 card")
    }

    /// Reopened later (the reviewer's (a)): its saved job matches the job this setup would send → "Same settings as v1".
    func testAReopenedVersionWhoseSavedJobMatchesReadsSameSettings() throws {
        let (h, app, p, disk, runs) = try landed()
        let request = try XCTUnwrap(app.makeRunRequest(lattice: false))
        let again = try reopen(h, app, p.id, job: try RemoteRun.buildJobJSON(request))
        XCTAssertNotNil(disk.loadRelatticeArtifacts(id: p.id), "its job is beside its results")
        _ = try h.onScreen("optimizeSameSettings", "★ reopened, nothing changed: \"Same settings as v1\"")
        try clickOptimize(h, "Optimize in the reopened version")
        XCTAssertNil(h.frames.all["nextVersionOptimize"], "no v2 for the same settings")
        XCTAssertEqual(runs.count, 1)
        again.force.safetyMargin = 2.5
        h.pump(0.6)
        XCTAssertNil(h.frames.all["optimizeSameSettings"], "★ a change after the reopen: live again")
    }

    /// Reopened, but its saved job asked for something else (another resolution): Optimize is live, "Optimize as v2".
    func testAReopenedVersionWhoseSavedJobDiffersIsLive() throws {
        let (h, app, p, disk, _) = try landed()
        let request = try XCTUnwrap(app.makeRunRequest(lattice: false))
        var job = try XCTUnwrap(try JSONSerialization.jsonObject(with: try RemoteRun.buildJobJSON(request)) as? [String: Any])
        job["resolution"] = ((job["resolution"] as? Int) ?? 64) + 32
        _ = try reopen(h, app, p.id, job: try JSONSerialization.data(withJSONObject: job))
        XCTAssertNotNil(disk.loadRelatticeArtifacts(id: p.id), "its job is beside its results")
        XCTAssertNil(h.frames.all["optimizeSameSettings"], "★ the setup is not what it ran with")
        try clickOptimize(h, "Optimize in the reopened version")
        _ = try h.onScreen("nextVersionOptimize", "★ the Optimize as v2 card")
    }
}
#endif
