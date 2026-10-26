// LoadScenarioHostedTests — the reviewer's ruling 2026-10-26 13:22 ("a new control isn't done until a hosted test finds it on
// the screen he actually sees"). His iPad on 5cf6773b: the Topology Selections list showed his groups and NO "+ Add a load
// scenario": d2e6b945 had put the scenario UI in the old library card, which Topology no longer draws (B3). The string tests
// could not see it. These host the WHOLE workspace (offscreen, never the app) and find each control by its own laid-out frame.
//
// RED on 5cf6773b: no "addLoadScenario" frame is published on Topology at all (the control was never on screen).
#if canImport(AppKit) && canImport(MetalKit)
import XCTest
import SwiftUI
import AppKit
@testable import TopOptFlows
@testable import TopOptKit

private final class ScenarioHostWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

@MainActor
final class LoadScenarioHostedTests: XCTestCase {
    final class Frames { var all: [String: CGRect] = [:] }
    struct Host { let window: NSWindow; let view: NSView; let size: CGSize; let frames: Frames }

    func pump(_ s: Double) {
        let end = Date().addingTimeInterval(s)
        while Date() < end { _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.02)) }
    }
    func host<V: View>(_ v: V, size: CGSize) -> Host {
        let frames = Frames()
        let root = AnyView(v.onPreferenceChange(ChromeKeepOutKey.self) { frames.all = $0 }.environment(\.colorScheme, .dark))
        let hv = NSHostingView(rootView: root)
        hv.frame = CGRect(origin: .zero, size: size)
        _ = NSApplication.shared
        let w = ScenarioHostWindow(contentRect: CGRect(x: -20000, y: -20000, width: size.width, height: size.height),
                                   styleMask: [.borderless], backing: .buffered, defer: false)
        w.appearance = NSAppearance(named: .darkAqua)
        w.contentView = hv
        w.setFrameOrigin(NSPoint(x: -20000, y: -20000))
        w.orderFrontRegardless()
        w.makeKey()
        hv.layoutSubtreeIfNeeded()
        addTeardownBlock { @MainActor in w.orderOut(nil); w.contentView = nil }
        return Host(window: w, view: hv, size: size, frames: frames)
    }
    func click(_ h: Host, _ p: CGPoint) {
        let loc = NSPoint(x: p.x, y: h.size.height - p.y)
        for t in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let e = NSEvent.mouseEvent(with: t, location: loc, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                       windowNumber: h.window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
            h.window.sendEvent(e)
            pump(0.06)
        }
        pump(0.8)
    }

    /// Scroll the Selections list (the way he would) until `key` sits inside it. The list scrolls past 420 pt.
    func scrollIntoList(_ h: Host, _ key: String) {
        for _ in 0..<12 {
            guard let list = h.frames.all["selectionsList"], let f = h.frames.all[key] else { return }
            if list.insetBy(dx: -1, dy: -1).contains(f) { return }
            let probe = NSPoint(x: list.midX, y: h.size.height - (list.maxY - 60))
            var v = h.view.hitTest(probe)
            while let x = v, !(x is NSScrollView) { v = x.superview }
            guard let sv = v as? NSScrollView else { return }
            let clip = sv.contentView
            var o = clip.bounds.origin
            let dy = (f.maxY - (list.maxY - 8))
            o.y += clip.isFlipped ? dy : -dy
            clip.scroll(to: o); sv.reflectScrolledClipView(clip)
            pump(0.4)
        }
    }

    /// A frame he can see and tap: laid out, inside the window, inside the Selections list.
    func onScreen(_ h: Host, _ key: String, _ what: String) throws -> CGRect {
        scrollIntoList(h, key)
        let f = try XCTUnwrap(h.frames.all[key], "★ \(what) is not on the screen (no frame '\(key)'); frames: \(h.frames.all.keys.sorted())")
        XCTAssertGreaterThan(f.width, 4, what); XCTAssertGreaterThan(f.height, 4, what)
        XCTAssertTrue(CGRect(origin: .zero, size: h.size).contains(f), "★ \(what) lies outside the window: \(f)")
        if let list = h.frames.all["selectionsList"] {
            XCTAssertTrue(list.insetBy(dx: -1, dy: -1).contains(f), "★ \(what) lies outside the Selections list \(list): \(f)")
        }
        return f
    }

    /// His A1 part on Topology with three groups: Bottom (anchor), Top (load), and Group C — an anchor that is also Keep clear,
    /// with three hand-placed cylinders, OPEN (its rows expanded, the case that pushed the old row out of view).
    func project() throws -> FlexibleHisProject.Restored {
        let r = try FlexiblePressFixtures.a1Project(3, self, facePrism: false)
        let p = r.project
        let c = try XCTUnwrap(p.selection.groups.first { $0.name == "Group C" })
        p.force.makeAnchor(c.id)
        p.force.setKeepClearAffix(c.id, .on)
        for x in [-10.0, 0, 10] {
            p.force.addManualPrimitive(ManualPrimitive(kind: .bolt, center: SIMD3(x, 0, 0), axis: SIMD3(0, 0, 1),
                                                       radiusMM: 2, halfLengthMM: 5), to: c.id)
        }
        p.selection.setActive(c.id)
        return r
    }

    func testAddALoadScenarioIsOnHisScreenAndWorksEndToEnd() throws {
        for (label, size) in [("portrait", CGSize(width: 1032, height: 1376)), ("landscape", CGSize(width: 1376, height: 1032))] {
            let r = try project()
            let p = r.project
            let bottom = try XCTUnwrap(p.selection.groups.first { $0.name == "Bottom" }).id
            let c = try XCTUnwrap(p.selection.groups.first { $0.name == "Group C" }).id
            let h = host(WorkspacePlaceholder(model: r.app, project: p), size: size)
            pump(3)

            // ★ found on his screen, without scrolling, with Group C's three cylinders open
            let add = try onScreen(h, "addLoadScenario", "\(label): + Add a load scenario")
            click(h, CGPoint(x: add.midX, y: add.midY))
            XCTAssertEqual(p.force.scenarioList.map(\.name), ["Scenario 1", "Scenario 2"], "\(label): the tap adds Scenario 2")
            let s1 = p.force.scenarioList[0].id, s2 = p.force.scenarioList[1].id
            XCTAssertEqual(p.force.activeScenarioID, s2)

            // ★ Scenario 2's folder is drawn; the shared anchor's switch is on its line in the open scenario
            _ = try onScreen(h, "scenarioFolder-1", "\(label): Scenario 2's folder")
            _ = try onScreen(h, "addLoadScenario", "\(label): + Add a load scenario, still pinned after the add")
            let sw = try onScreen(h, "scenarioAnchorSwitch-\(c.uuidString)", "\(label): Group C's switch in Scenario 2")
            click(h, CGPoint(x: sw.midX, y: sw.midY))
            XCTAssertFalse(p.force.anchorIsOn(c, in: s2), "\(label): ★ switched off in Scenario 2")
            XCTAssertTrue(p.force.anchorIsOn(c, in: s1), "\(label): ★ Scenario 1 unchanged")
            XCTAssertTrue(p.force.anchorIsOn(bottom, in: s2))

            // ★ the job carries loads.scenarios, Scenario 2 holding by Bottom alone
            let req = try XCTUnwrap(r.app.makeRunRequest())
            let job = try XCTUnwrap(JSONSerialization.jsonObject(with: RemoteRun.buildJobJSON(req)) as? [String: Any])
            let sc = try XCTUnwrap((job["loads"] as? [String: Any])?["scenarios"] as? [[String: Any]], "\(label): loads.scenarios")
            XCTAssertEqual(sc.map { $0["name"] as? String }, ["Scenario 1", "Scenario 2"])
            let a1 = Set(sc[0]["anchor_face_ids"] as? [Int] ?? []), a2 = Set(sc[1]["anchor_face_ids"] as? [Int] ?? [])
            XCTAssertTrue(a2.isStrictSubset(of: a1), "\(label): Scenario 2 sends fewer anchors (\(a2) vs \(a1))")
        }
    }

    /// ★ HIS ASK (2026-10-26): every piece inside the open group — its face and each keep-out cylinder — is picked one at a
    /// time and has its own hide and delete, on his screen.
    func testEveryPieceInsideTheGroupHasPickHideAndDelete() throws {
        let r = try project()
        let p = r.project
        let c = try XCTUnwrap(p.selection.groups.first { $0.name == "Group C" })
        let h = host(WorkspacePlaceholder(model: r.app, project: p), size: CGSize(width: 1032, height: 1376))
        pump(3)
        let face = try XCTUnwrap(c.faces.first)
        _ = try onScreen(h, "piecePick-topology-face-pick-\(face)", "Face \(face)'s row")
        _ = try onScreen(h, "pieceEye-\(c.id.uuidString)-\(face)", "Face \(face)'s eye")
        _ = try onScreen(h, "pieceTrash-topology-face-trash-\(face)", "Face \(face)'s trash")
        let cylinders = p.force.manualPrimitives(for: c.id)
        XCTAssertEqual(cylinders.count, 3)
        for mp in cylinders {
            _ = try onScreen(h, "piecePick-pick-manual-\(mp.id.uuidString)", "a cylinder's row")
            _ = try onScreen(h, "pieceEye-\(c.id.uuidString)-\(ProjectModel.manualFaceKey(mp.id))", "a cylinder's eye")
            _ = try onScreen(h, "pieceTrash-delete-manual-\(mp.id.uuidString)", "a cylinder's trash")
        }
        // the trash deletes that one cylinder, nothing else
        let t = try onScreen(h, "pieceTrash-delete-manual-\(cylinders[1].id.uuidString)", "the middle cylinder's trash")
        click(h, CGPoint(x: t.midX, y: t.midY))
        XCTAssertEqual(p.force.manualPrimitives(for: c.id).map(\.id), [cylinders[0].id, cylinders[2].id], "★ one cylinder deleted")
        // the face's trash on the group's last face asks (the group's own in-place ask) — never deletes the group outright
        let ft = try onScreen(h, "pieceTrash-topology-face-trash-\(face)", "Face \(face)'s trash")
        click(h, CGPoint(x: ft.midX, y: ft.midY))
        XCTAssertNotNil(p.selection.groups.first { $0.id == c.id }, "the group is still there until he confirms")
    }

    /// The safety margin's row is on the same screen (ruling 13:12), pinned with the add row.
    func testTheSafetyMarginIsOnHisScreen() throws {
        let r = try project()
        let h = host(WorkspacePlaceholder(model: r.app, project: r.project), size: CGSize(width: 1032, height: 1376))
        pump(3)
        let add = try onScreen(h, "addLoadScenario", "+ Add a load scenario")
        guard SafetyMargin.jobKey != nil else {
            XCTAssertNil(h.frames.all["safetyMargin"], "★ no picker until the core that reads it ships (it would change nothing)")
            return
        }
        let sm = try onScreen(h, "safetyMargin", "the safety margin")
        XCTAssertGreaterThan(sm.minY, add.minY, "under the add row")
    }

    /// d2e6b945's other piece: "Worst case: …" is laid out on the real Results screen.
    func testWorstCaseIsOnTheResultsScreen() throws {
        let report: [String: Any] = ["scenarios": [
            ["name": "Scenario 1", "margin": 2.4, "governs": false, "unheld": false],
            ["name": "Left plate off", "margin": 1.31, "governs": true, "unheld": false]]]
        let v = OptimizeVariant(requestedVolumeFraction: 0.4, achievedVolumeFraction: 0.4, massGrams: 40, supportVolumeVoxels: 0,
                                meshTriangleCount: 100, worstCaseMargin: 1.31, accepted: true, v3Passes: true,
                                minFeatureViolations: 0, minFeatureWarning: "")
        let o = OptimizeOutcome(variants: [v], stoppedOnMargin: false, cancelled: false, acceptedCount: 1,
                                gridNx: 4, gridNy: 4, gridNz: 4, spacing: 1,
                                reportJSON: try JSONSerialization.data(withJSONObject: report))
        let rm = ResultsModel(projectName: "Arms", outcome: o)
        let size = CGSize(width: 1032, height: 1376)
        // the app presents Results full-screen; the bare view, unframed, lays out taller than the window
        let h = host(ResultsScreen(projectName: "Arms", outcome: o, resultsModel: rm).frame(width: size.width, height: size.height),
                     size: size)
        pump(2)
        XCTAssertEqual(rm.scenarioResults.count, 2)
        let f = try XCTUnwrap(h.frames.all["scenarioResults"], "★ the Worst case line is not on the Results screen")
        XCTAssertTrue(CGRect(origin: .zero, size: h.size).contains(f), "inside the window: \(f)")
    }
}
#endif
