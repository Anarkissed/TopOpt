// FlexibleR7MergeTests — round 7's MERGE step: R7-S (the open tab is the master and the group that plays; an edges group's tab
// shows only its own numbers) and R7-V (the Settings page's [Heat] shows the CURRENT group's heat) TOGETHER, on his pad
// (A1_0003 as he saved it, plus I2's Edge 9 edges group), the Settings page hosted at his 13" portrait (offscreen, never the
// app). Written BEFORE the fix, against a stub that keeps the merged code's rule.
// His img4 words (2026-10-14): "What is this 3mm? I don't see anything listed in the group with that number? I should only be
// able to view numbers associated to what I'm working on."
// What looking at the merged page found: on the edges group's tab the part wears NO heat (the current group's heat is none —
// an edges group has no stacks until AP9) and no chip — yet the legend card still said "What you drew · shown ×1 · 0 mm …
// 28.4 mm" (the other groups' scale) and its TAP TO READ took a tap; a reading begun on Group 2 stayed on over the edges tab.
//   * the edges tab: no heat drawn → no legend card, and a reading begun on another tab ends;
//   * a faces group's tab: its heat drawn → its card (the positive control);
//   * the 3 s hold (every group's heat) on the edges tab: heat drawn → the card;
//   * RED CONTROL `FlexibleStagePage.controlLegendIgnoresDrawnHeat` (the merged code's rule, Heat on = the card).
#if canImport(AppKit)
import XCTest
import SwiftUI
import AppKit
import TopOptDesign
@testable import TopOptFlows
@testable import TopOptKit

private final class R7MergeHostWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

@MainActor
final class FlexibleR7MergeTests: XCTestCase {
    final class Frames { var all: [String: CGRect] = [:] }
    struct Host { let window: NSWindow; let view: NSView; let frames: Frames }

    func pump(_ seconds: Double) {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end { _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.02)) }
    }

    @discardableResult
    func pumpUntil(_ timeout: Double, _ cond: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while !cond() {
            if Date() > end { return false }
            _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }
        return true
    }

    func host<V: View>(_ v: V, size: CGSize) -> Host {
        let frames = Frames()
        let root = AnyView(v.onPreferenceChange(FlexibleKeepOutKey.self) { frames.all = $0 }.environment(\.colorScheme, .dark))
        let hv = NSHostingView(rootView: root)
        hv.frame = CGRect(origin: .zero, size: size)
        _ = NSApplication.shared
        let w = R7MergeHostWindow(contentRect: CGRect(x: -20000, y: -20000, width: size.width, height: size.height),
                                  styleMask: [.borderless], backing: .buffered, defer: false)
        w.appearance = NSAppearance(named: .darkAqua)
        w.contentView = hv
        w.setFrameOrigin(NSPoint(x: -20000, y: -20000))
        w.orderFrontRegardless()
        hv.layoutSubtreeIfNeeded()
        addTeardownBlock { @MainActor in w.orderOut(nil); w.contentView = nil }
        return Host(window: w, view: hv, frames: frames)
    }

    /// His pad opened the app's way (the main page's shared model), then I2's Edge 9 picked and [Done] — R7-S's fixture,
    /// synchronous with the run loop pumped (the page's Metal view publishes its projection only so).
    func hisPadWithEdges() throws -> (FlexibleHisProject.Restored, FlexibleStageModel) {
        let r = try FlexiblePressFixtures.a1Project(3, self)
        let stage = FlexibleMainStage()
        stage.reduceMotion = { true }
        let m = stage.model(for: r.project, materialsPath: FlexibleHisProject.materialsPath,
                            stampsPath: FlexibleHisProject.stampsPath, persist: {})
        addTeardownBlock { @MainActor in await m.waitForIdle() }
        m.openScene()
        XCTAssertTrue(pumpUntil(120) { m.sceneState == .ready && m.loadedKeys.allSatisfy { m.stacks[$0] != nil && m.geometry[$0] != nil } },
                      "the scene and stacks")
        m.rail = .newGroup
        m.startEdgePick()
        XCTAssertTrue(pumpUntil(240) { m.edgePick.map { !$0.loading && !$0.checking } ?? false }, "the edges and corners listed")
        let c = try XCTUnwrap(m.edgePick?.candidates.first { $0.kind == .edge && Set($0.members) == [1, 2] })
        m.toggleEdgePick(c.number)
        m.setEdgePickWeight(5)
        var done = false
        var why: String?
        Task { @MainActor in why = await m.finishEdgePick(); done = true }
        XCTAssertTrue(pumpUntil(240) { done && m.sceneState == .ready && m.openedKey == m.currentSceneKey
            && m.loadedKeys.allSatisfy { m.stacks[$0] != nil && m.geometry[$0] != nil } }, "the part open on the strips")
        XCTAssertNil(why)
        pump(0.5)
        return (r, m)
    }

    func testTheDentScaleAndItsReadingShowOnlyWhereTheOpenGroupsHeatIsDrawn() throws {
        addTeardownBlock { @MainActor in FlexibleStagePage.controlLegendIgnoresDrawnHeat = false }
        let (r, m) = try hisPadWithEdges()
        let edges = try XCTUnwrap(m.squeezeGroups.first { $0.kind == .edges }, "premise: I2's Edge 9 group")
        let g2 = try XCTUnwrap(m.squeezeGroups.first { $0.kind == .faces && $0.regions.contains(4) }, "premise: his Group 2 (Face 4 + Face 2)")
        let loop = FlexibleSquishLoop()
        let h = host(FlexibleStagePage(project: r.project, model: m, loop: loop, onExit: {}), size: CGSize(width: 1032, height: 1376))
        pump(2.5)
        var report: [String] = []
        func look(_ tag: String) -> (drawn: Bool, card: Bool, reading: Bool) {
            let s = (FlexibleStagePage.heatDrawn(model: m, views: m.views), h.frames.all["legend"] != nil, loop.reading)
            report.append("\(tag): tab \(m.rail) · heat \(m.views.heatScope) · drawn on \(FlexibleStageHeat.shown(model: m, views: m.views).sorted())"
                + " · heatDrawn \(s.0) · card \(s.1) · reading \(s.2)")
            return s
        }
        func run(control: Bool) throws -> [String: (drawn: Bool, card: Bool, reading: Bool)] {
            FlexibleStagePage.controlLegendIgnoresDrawnHeat = control
            defer { FlexibleStagePage.controlLegendIgnoresDrawnHeat = false }
            var out: [String: (drawn: Bool, card: Bool, reading: Bool)] = [:]
            let c = control ? " (control)" : ""
            m.views = []                                     // R7-V's default: the current group's heat, Play off
            FlexibleStagePage.testDrill.send(false)
            // ★ a faces group's tab: its heat is drawn — the card (the positive control)
            m.rail = .group(g2.id)
            m.select(4)
            pump(1.2)
            out["group2"] = look("Group 2's tab" + c)
            // ★ he reads Group 2's dent (TAP TO READ — the harness's clicks land on the MTKView, so the page's test seam)
            FlexibleStagePage.testDrill.send(true)
            pump(0.5)
            out["group2 reading"] = look("Group 2's tab, reading" + c)
            // ★ he opens the edges group's tab: no heat on the part
            m.rail = .group(edges.id)
            pump(1.2)
            out["edges"] = look("the edges tab" + c)
            FlexibleStagePage.testDrill.send(false)
            pump(0.3)
            // ★ his 3 s hold on [Heat]: every group's heat, drawn — the card
            m.views = [.heatAll]
            pump(1.0)
            out["edges all"] = look("the edges tab, every group's heat" + c)
            m.views = []
            pump(0.5)
            return out
        }
        let fixed = try run(control: false)
        XCTAssertEqual(fixed["group2"]?.drawn, true, "premise: Group 2's heat is drawn on its tab")
        XCTAssertEqual(fixed["group2"]?.card, true, "positive control: Group 2's tab shows the card (its scale)")
        XCTAssertEqual(fixed["group2 reading"]?.reading, true, "premise: the reading began on Group 2's tab")
        XCTAssertEqual(fixed["edges"]?.drawn, false, "★ the edges tab: no heat is drawn on the part")
        XCTAssertEqual(fixed["edges"]?.card, false, "★ the edges tab: no scale for heat the part does not wear (his img4 'numbers')")
        XCTAssertEqual(fixed["edges"]?.reading, false, "★ a reading begun on Group 2 ends on the edges tab (a tap on the part selects)")
        XCTAssertEqual(fixed["edges all"]?.drawn, true, "the 3 s hold: every group's heat is drawn")
        XCTAssertEqual(fixed["edges all"]?.card, true, "the 3 s hold: the card shows its scale")
        let red = try run(control: true)
        XCTAssertEqual(red["edges"]?.card, true, "★ RED CONTROL: the merged code's rule — the card over the edges tab")
        XCTAssertEqual(red["edges"]?.reading, true, "★ RED CONTROL: the merged code's rule — the reading stayed on over the edges tab")
        print("FLEX-R7-MERGE legend\n  " + report.joined(separator: "\n  "))
    }
}
#endif
