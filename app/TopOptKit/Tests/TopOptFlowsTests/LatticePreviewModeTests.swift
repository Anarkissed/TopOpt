// LatticePreviewModeTests — ★ his ask 2026-11-16 ("It kills my ipad when [I] have the lattice view on … impossibly slow and
// laggy and drops frames") and his picks the same night (LatticePreviewMode.swift): Live preview / Click to refresh on the
// Lattice button's ⌃ (Click to refresh by default), the glow's two breaths then held, Live's half-second wait, the 0.2 mm
// nozzle check only when asked, half resolution while the view turns with a lattice in it.
#if canImport(AppKit) && canImport(MetalKit)
import XCTest
import SwiftUI
import AppKit
import MetalKit
@testable import TopOptFlows
@testable import TopOptKit

final class LatticePreviewModeTests: XCTestCase {
    /// (2) Refresh Lattice shows only under Click to refresh, with the lattice view up, the preview out of date and no run.
    func testRefreshShowsOnlyWhenClickToRefreshAndOutOfDate() {
        XCTAssertTrue(LatticePreviewMode.showsRefresh(live: false, previewUp: true, stale: true, running: false))
        XCTAssertFalse(LatticePreviewMode.showsRefresh(live: true, previewUp: true, stale: true, running: false), "Live keeps up")
        XCTAssertFalse(LatticePreviewMode.showsRefresh(live: false, previewUp: false, stale: true, running: false), "no view up")
        XCTAssertFalse(LatticePreviewMode.showsRefresh(live: false, previewUp: true, stale: false, running: false), "up to date")
        XCTAssertFalse(LatticePreviewMode.showsRefresh(live: false, previewUp: true, stale: true, running: true), "a run's button wins")
    }

    /// (2) His default: Click to refresh — an absent key reads false (not Live).
    @MainActor
    func testClickToRefreshIsTheDefault() throws {
        let d = try XCTUnwrap(UserDefaults(suiteName: "LatticePreviewModeTests.\(UUID().uuidString)"))
        XCTAssertFalse(AppSettings(defaults: d).latticeLivePreview, "★ his pick: Click to refresh by default")
        d.set(true, forKey: AppSettings.livePreviewKey)
        XCTAssertTrue(AppSettings(defaults: d).latticeLivePreview, "his choice is kept")
    }

    /// (4) Live preview waits half a second.
    func testLiveWaitsHalfASecond() {
        XCTAssertEqual(LatticePreviewMode.liveDelay, .milliseconds(500))
    }

    /// (6) Half the screen's resolution only while turning with a lattice drawn; never below 1.
    func testHalfResolutionOnlyWhileTurningALattice() {
        XCTAssertEqual(LatticePreviewMode.drawScale(native: 2, turning: true, latticeShown: true), 1)
        XCTAssertEqual(LatticePreviewMode.drawScale(native: 3, turning: true, latticeShown: true), 1.5)
        XCTAssertEqual(LatticePreviewMode.drawScale(native: 2, turning: false, latticeShown: true), 2, "let go: full")
        XCTAssertEqual(LatticePreviewMode.drawScale(native: 2, turning: true, latticeShown: false), 2, "no lattice: full")
        XCTAssertEqual(LatticePreviewMode.drawScale(native: 1, turning: true, latticeShown: true), 1, "never below 1")
    }

    /// (3) The glow breathes two breaths, then holds at its brightest: the end lands on a breath's peak, two or three
    /// breaths after it came on.
    func testTheGlowStopsBreathingOnAPeak() {
        for now in [0.0, 1.3, 7.77, 1234.5] {
            let end = LatticePreviewMode.glowBreathEnd(now: now)
            XCTAssertGreaterThanOrEqual(end, now + 2 * 2.6 - 1e-9)
            XCTAssertLessThan(end, now + 3 * 2.6 + 1e-9)
            XCTAssertEqual(MeshRenderer.glowBreathe(at: end), 1, accuracy: 1e-4, "★ held at its brightest, no jump (\(now))")
        }
    }

    /// (3) The renderer's glow: breathing, then held (no longer animating, still drawn), then gone.
    @MainActor
    func testTheRendererHoldsTheGlowAfterItsBreaths() throws {
        guard let d = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal device") }
        let r = try XCTUnwrap(MeshRenderer(device: d))
        r.startGlow(now: 100)
        XCTAssertTrue(r.glowBreathe, "it breathes first")
        r.settleGlow(now: 101)
        XCTAssertTrue(r.glowBreathe, "still breathing a second later")
        r.settleGlow(now: r.glowBreathEnds)
        XCTAssertFalse(r.glowBreathe, "★ after its breaths it no longer keeps the view drawing")
        XCTAssertTrue(r.glowHeld && r.glowPresent, "★ …and the glow is still there, held")
        r.stopGlow()
        XCTAssertFalse(r.glowPresent, "gone")
    }

    /// The wiring a value test cannot see: the draw loop settles the glow, the coordinator starts and stops it, the camera
    /// gestures set the drawing scale, the nozzle check waits to be asked.
    func testTheWiring() throws {
        let src = { (f: String) in try String(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Sources/TopOptFlows/\(f)"), encoding: .utf8) }
        let mm = try src("MetalMeshView.swift")
        let draw = try XCTUnwrap(mm.range(of: "func draw(in view: MTKView) {"))
        XCTAssertTrue(mm[draw.lowerBound...].prefix(400).contains("settleGlow()"), "★ the draw loop ends the breaths")
        XCTAssertTrue(mm.contains("if glows { renderer.startGlow() } else { renderer.stopGlow() }"), "the glow's switch")
        for h in ["@objc func handlePan(_ g: UIPanGestureRecognizer) {", "@objc func handlePinch(_ g: UIPinchGestureRecognizer) {"] {
            let r = try XCTUnwrap(mm.range(of: h), h)
            XCTAssertTrue(mm[r.lowerBound...].prefix(4000).contains("noteTurning(g, in: view)"), "★ \(h) sets the drawing scale")
        }
        let lp = try src("LatticeLayoutPreview.swift")
        XCTAssertTrue(lp.contains("if LatticePreviewMode.nozzleAfterLay(asked: nozzleWanted)"), "★ the nozzle check waits to be asked")
        XCTAssertFalse(lp.contains("await nozzleCheck(path: path, s, lattice: latticeAtLay)   // after the layout and its map"),
                       "the old unasked nozzle check after every layout is gone")
        let ws = try src("WorkspacePlaceholder.swift")
        XCTAssertTrue(ws.contains("if !forceRebuild, !latticeRefreshRequested, strutScene != nil, !appSettings.latticeLivePreview, !onlyStressMoved {"),
                      "★ the old preview's bake holds under Click to refresh")
        XCTAssertTrue(ws.contains("if !appSettings.latticeLivePreview, !latticeRefreshRequested, latticeSim.field != nil {"),
                      "★ …and so does an out-of-date stress check")
    }
}

/// The pad, Structural, on Lattice Setup with the lattice preview armed (AppAsks1114HostedTests' set-up).
@MainActor
private func armedLatticeSetup(_ size: CGSize, _ test: XCTestCase) throws -> (AppBuildHost, ProjectModel) {
    let r = try FlexiblePressFixtures.a1Project(3, test, facePrism: false)
    let p = r.project
    p.lattice.flexible = nil
    p.lattice.clearLatticeType()
    p.lattice.chooseLatticeType(.structural)
    p.lattice.gradingMode = .fitShape   // no stress result asked for: no solve lands mid-count
    p.lattice.enabled = true
    let h = AppBuildHost(WorkspacePlaceholder(model: r.app, project: p), size: size, test: test)
    h.pump(3)
    // ★ notes28: the stage now opens with its lattice view on; these set-ups ARM it by his tap (settings first, then their
    // Save), the flow they were written for — so the stage is entered as before
    WorkspacePlaceholder.controlLatticeViewStartsOff = true
    defer { WorkspacePlaceholder.controlLatticeViewStartsOff = false }
    try h.pickFromMenu("capsuleMenu", "Structural", what: "the stage menu")
    h.pump(1.5)
    if h.frames.all["view-Lattice preview-on"] == nil { try h.tap("view-Lattice preview", "the lattice preview", settle: 1.5) }
    if h.frames.all["latticeSettingsPanel"] != nil { try h.tap("capsuleLattice", "the page's Save", settle: 1.5) }
    XCTAssertNil(h.frames.all["latticeSettingsPanel"], "premise: on Lattice Setup")
    return (h, p)
}

/// ★ On the real page, the new engine (test) drawing: the ⌃ menu's two choices; under Click to refresh a change lays nothing
/// and turns the Lattice button into Refresh Lattice, which lays once (with the nozzle check) and goes back; under Live a
/// burst of changes lays once, half a second after the last (RED CONTROL: without the wait, one per change), and no nozzle
/// check runs unasked.
final class LatticePreviewModeHostedTests: XCTestCase {
    @MainActor
    func testClickToRefreshAndLiveOnThePage() throws {
        let settings = AppSettings.shared
        let wasEngine = settings.newEngineTest
        addTeardownBlock { @MainActor in
            AppSettings.shared.newEngineTest = wasEngine
            AppSettings.shared.latticeLivePreview = false
            LatticePreviewMode.controlNoLiveDelay = false
        }
        settings.newEngineTest = false
        let (h, p) = try armedLatticeSetup(AppBuildHost.landscape13, self)
        settings.newEngineTest = true
        let end = Date().addingTimeInterval(120)
        while h.frames.all["new-engine-timing"] == nil, Date() < end { h.pump(0.5) }
        XCTAssertNotNil(h.frames.all["new-engine-timing"], "premise: the new engine laid the part")
        h.pump(1)

        // the ⌃ menu: both choices, a check mark on the one in force (an inline picker)
        let offered = try h.pickFromMenu("latticeSplitMore", LatticePreviewMode.refresh, what: "the Lattice button's ⌃")
        print("MENU \(offered)")
        XCTAssertTrue(offered.contains { $0.contains(LatticePreviewMode.live) }, "★ the ⌃ offers Live preview: \(offered)")
        XCTAssertTrue(offered.contains { $0.contains(LatticePreviewMode.refresh) }, "★ …and Click to refresh preview")
        XCTAssertFalse(settings.latticeLivePreview, "★ picking Click to refresh preview sets it")
        h.pump(1)

        // Click to refresh: a change lays nothing; the button reads Refresh Lattice
        func flip() { p.lattice.gradingMode = p.lattice.gradingMode == .none ? .fitShape : .none }
        var n = LatticeLayoutPreview.laysStarted
        flip(); h.pump(3)
        XCTAssertEqual(LatticeLayoutPreview.laysStarted, n, "★ Click to refresh: a change lays nothing")
        let refresh = try h.onScreen("latticeRefreshButton", "★ the Lattice button reads Refresh Lattice")
        XCTAssertNotNil(h.frames.all["latticeButton"], "it is the Lattice button itself")
        print("REFRESH \(refresh)")
        let checks = LatticeLayoutPreview.nozzleChecksRun
        try h.tap("latticeRefreshButton", "★ Refresh Lattice", settle: 1)
        let end2 = Date().addingTimeInterval(60)
        while LatticeLayoutPreview.laysStarted == n, Date() < end2 { h.pump(0.5) }
        XCTAssertEqual(LatticeLayoutPreview.laysStarted, n + 1, "★ Refresh lays once")
        h.pump(2)
        XCTAssertNil(h.frames.all["latticeRefreshButton"], "★ …and the button goes back to Lattice")
        XCTAssertEqual(LatticeLayoutPreview.nozzleChecksRun, checks + 1, "★ Refresh runs the 0.2 mm nozzle check")

        // Live: a burst of three changes lays once, half a second after the last
        try h.pickFromMenu("latticeSplitMore", LatticePreviewMode.live, what: "the ⌃ again")
        XCTAssertTrue(settings.latticeLivePreview, "★ picking Live preview sets it")
        h.pump(3)
        n = LatticeLayoutPreview.laysStarted
        for _ in 0..<3 { flip(); h.pump(0.1) }
        h.pump(3)
        XCTAssertEqual(LatticeLayoutPreview.laysStarted, n + 1, "★ Live: one layout after he stops, not one per change")
        XCTAssertNil(h.frames.all["latticeRefreshButton"], "Live never asks for Refresh")
        XCTAssertEqual(LatticeLayoutPreview.nozzleChecksRun, checks + 1, "★ Live runs no nozzle check unasked")

        // RED CONTROL: Live without the wait lays on every change
        LatticePreviewMode.controlNoLiveDelay = true
        n = LatticeLayoutPreview.laysStarted
        for _ in 0..<3 { flip(); h.pump(0.1) }
        h.pump(3)
        XCTAssertGreaterThanOrEqual(LatticeLayoutPreview.laysStarted, n + 3, "RED CONTROL: without the wait, one per change")
        LatticePreviewMode.controlNoLiveDelay = false
        settings.newEngineTest = false
        h.pump(1)
    }
}

/// ★ His second ask of 11-16, picks A and E on the real page (the new engine's bars drawn): while he turns the view with a
/// lattice up, the page does not re-read itself on every step (A: the camera reaches the 3D view directly), its projection-led
/// chips are gone and come back where the model now is when he lets go, and frames are capped at 60 a second (E). RED
/// CONTROLS: the page following every step; frames as asked.
final class LatticeTurningHostedTests: XCTestCase {
    @MainActor
    func testTurningALatticeOnThePage() throws {
        let settings = AppSettings.shared
        let wasEngine = settings.newEngineTest
        addTeardownBlock { @MainActor in
            AppSettings.shared.newEngineTest = wasEngine
            LatticePreviewMode.controlPageFollowsCamera = false
            LatticePreviewMode.controlFullDetailWhileTurning = false
        }
        settings.newEngineTest = false
        let (h, _) = try armedLatticeSetup(AppBuildHost.landscape13, self)
        // the page's 3D view with a lattice in it (the old engine's preview; the page holds other Metal views too)
        func viewers() -> [(MTKView, MetalMeshView.Coordinator)] {
            var out: [(MTKView, MetalMeshView.Coordinator)] = []
            func walk(_ v: NSView) {
                if let m = v as? MTKView,
                   let c = m.gestureRecognizers.first(where: { ($0 as? NSClickGestureRecognizer)?.numberOfClicksRequired == 1 })?
                    .target as? MetalMeshView.Coordinator { out.append((m, c)) }
                v.subviews.forEach(walk)
            }
            walk(h.view)
            return out
        }
        var found: (MTKView, MetalMeshView.Coordinator)?
        let end = Date().addingTimeInterval(120)
        while found == nil, Date() < end {
            h.pump(0.5)
            found = viewers().first { $0.1.renderer?.latticeDrawnForScale == true }
        }
        print("TURNING viewers: \(viewers().map { "\($0.0.bounds.size) lattice \($0.1.renderer?.latticeDrawnForScale ?? false)" })")
        let (mtk, viewer) = try XCTUnwrap(found, "premise: a lattice is drawn in the page's 3D view")
        let renderer = try XCTUnwrap(viewer.renderer)
        let camera = try XCTUnwrap(viewer.cameraModel, "the page's camera")
        let keysAtRest = Set(h.frames.all.keys)

        func turn(steps: Int, pumping: Bool) -> (applies: Int, displays: Int) {
            let g = NSObject()
            let a0 = MetalMeshView.Coordinator.appliesRun, d0 = viewer.displayRequests
            viewer.cameraGesture(ObjectIdentifier(g), down: true, in: mtk)
            h.pump(0.3)
            let a1 = MetalMeshView.Coordinator.appliesRun, d1 = viewer.displayRequests
            for _ in 0..<steps {
                camera.orbit(dx: 3, dy: 0)
                if pumping { h.pump(0.02) }
            }
            let a2 = MetalMeshView.Coordinator.appliesRun, d2 = viewer.displayRequests
            _ = (a0, d0)
            viewer.cameraGesture(ObjectIdentifier(g), down: false, in: mtk)
            h.pump(0.5)
            return (a2 - a1, d2 - d1)
        }

        // A: thirty steps of a turn re-read the page (almost) never; the 3D view turns; the chips go and come back
        let yaw0 = camera.camera.azimuth
        let g = NSObject()
        viewer.cameraGesture(ObjectIdentifier(g), down: true, in: mtk)
        h.pump(0.5)
        XCTAssertTrue(viewer.latticeTurning && renderer.turning, "★ a turn with a lattice up is a lattice turn")
        let keysTurning = Set(h.frames.all.keys)
        viewer.cameraGesture(ObjectIdentifier(g), down: false, in: mtk)
        h.pump(1)
        XCTAssertFalse(viewer.latticeTurning || renderer.turning, "★ letting go ends it")
        print("TURNING frames hidden while turning: \(keysAtRest.subtracting(keysTurning).sorted())")
        XCTAssertTrue(keysTurning.isSubset(of: keysAtRest), "nothing new appears while turning")
        XCTAssertEqual(Set(h.frames.all.keys), keysAtRest, "★ everything that hid comes back when he lets go")

        let quiet = turn(steps: 30, pumping: true)
        XCTAssertNotEqual(camera.camera.azimuth, yaw0, "the camera turned")
        XCTAssertLessThanOrEqual(quiet.applies, 3, "★ A: thirty steps re-read the page at most a few times (got \(quiet.applies))")
        // E: thirty steps asked in one go draw at most two frames (one now, one at the gap's end)
        let burst = turn(steps: 30, pumping: false)
        XCTAssertLessThanOrEqual(burst.displays, 2, "★ E: at most 60 a second (got \(burst.displays) displays for 30 steps)")

        // RED CONTROLS
        LatticePreviewMode.controlPageFollowsCamera = true
        let loud = turn(steps: 30, pumping: true)
        XCTAssertGreaterThanOrEqual(loud.applies, 25, "RED CONTROL: the page re-reads itself on every step (got \(loud.applies))")
        LatticePreviewMode.controlPageFollowsCamera = false
        LatticePreviewMode.controlFullDetailWhileTurning = true
        let every = turn(steps: 30, pumping: false)
        XCTAssertGreaterThanOrEqual(every.displays, 30, "RED CONTROL: every step asks a frame")
        LatticePreviewMode.controlFullDetailWhileTurning = false
        settings.newEngineTest = false
        h.pump(1)
    }
}
#endif
