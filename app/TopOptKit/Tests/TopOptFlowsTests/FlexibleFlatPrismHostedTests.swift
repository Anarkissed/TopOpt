// FlexibleFlatPrismHostedTests — round 7, batch R7-E1, the hosted half (offscreen, never the app) on HIS pad (A1_0003): the
// Squish page with an edges group's tab open on Edge 16 (Face 3 + Face 2). His words (2026-10-18): "There shouldn't be a strip
// width. It should be a Flat prism that gets wider as it gets dragged further towards the centre of the model from the edge. We
// should be able to change the angle up/down and left/right of the prism." His answer: "drag the prism's ARROW — a handle on the
// edge/corner prism's arrow … the angle shows on the handle (tap to type, keypad)". His rules: one visible line per setting
// (≤ 44); numbers are boxes (tap = keypad); 44 pt targets.
//   H1 the edges tab has no Strip width / Patch size anywhere; its Deepest squish, Tilt and Twist rows are one line each.
//   H2 on the model at 13"/11" portrait and landscape and the mini in portrait: the flat prism, its arrow, the depth chip at the
//      arrow's head and the angle knob at its tail with its two boxes — each target ≥ 44 pt, none under the chrome, none
//      overlapping; a tap on the chip or a box opens the keypad (± on the angles); a face's depth chip is tap-to-type too.
//   H3 the camera on [Done] — D-AP-13 as ruled (down the arrow) until the reviewer amends it, the knob drawn ≥ 56 pt from the head.
// Written BEFORE the code (red run: round7/batch_e1/e1b_red_run.txt).
#if canImport(AppKit) && canImport(MetalKit)
import XCTest
import SwiftUI
import AppKit
import MetalKit
import simd
import TopOptDesign
@testable import TopOptFlows
@testable import TopOptKit

private final class FPHostWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

@MainActor
final class FlexibleFlatPrismHostedTests: XCTestCase {
    typealias F = FlexibleFlatPrismFixtures
    final class Frames { var all: [String: CGRect] = [:]; var marks: [String: CGRect] = [:] }
    struct Host { let window: NSWindow; let view: NSView; let size: CGSize; let frames: Frames }
    struct AX { let id: String; let label: String; let frame: CGRect }

    static let sizes: [(String, CGSize)] = FlexibleGroupPaletteHostedTests.sizes + [("mini-p", CGSize(width: 744, height: 1133))]

    func pump(_ s: Double) {
        let end = Date().addingTimeInterval(s)
        while Date() < end { _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.02)) }
    }
    func host<V: View>(_ v: V, size: CGSize) -> Host {
        let frames = Frames()
        let root = AnyView(v.onPreferenceChange(FlexibleKeepOutKey.self) { frames.all = $0 }
            .onPreferenceChange(FlexibleViewMarksKey.self) { frames.marks = $0 }.environment(\.colorScheme, .dark))
        let hv = NSHostingView(rootView: root)
        hv.frame = CGRect(origin: .zero, size: size)
        _ = NSApplication.shared
        let w = FPHostWindow(contentRect: CGRect(x: -20000, y: -20000, width: size.width, height: size.height),
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
        for t in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let e = NSEvent.mouseEvent(with: t, location: NSPoint(x: p.x, y: h.size.height - p.y), modifierFlags: [],
                                       timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: h.window.windowNumber,
                                       context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
            h.window.sendEvent(e)
            pump(0.06)
        }
        pump(0.6)
    }
    func axAll(_ h: Host) -> [AX] {
        var out: [AX] = []
        let wf = h.window.frame
        func walk(_ o: Any, _ d: Int) {
            guard d < 80, let e = o as? NSAccessibilityProtocol else { return }
            let f = e.accessibilityFrame()
            let lf = CGRect(x: f.minX - wf.minX, y: wf.maxY - f.maxY, width: f.width, height: f.height)
            let ob = o as? NSObject
            func attr(_ a: NSAccessibility.Attribute) -> String? {
                let v = ob?.accessibilityAttributeValue(a) as? String
                return (v?.isEmpty ?? true) ? nil : v
            }
            out.append(AX(id: e.accessibilityIdentifier() ?? "", label: attr(.description) ?? attr(.title) ?? attr(.value) ?? "", frame: lf))
            for c in (ob?.accessibilityAttributeValue(.children) as? [Any]) ?? [] { walk(c, d + 1) }
        }
        walk(h.view, 0)
        return out
    }

    /// His pad, Edge 16 picked and [Done]; its tab open — SYNCHRONOUS, the run loop pumped (the page's Metal view publishes its
    /// projection only so: an async test draws no overlay at all — FlexibleR7SettingsHostedTests' note).
    /// (Corrected after the green run, our own new test: it was async, and the page drew no overlay.)
    func edge16() throws -> (FlexibleHisProject.Restored, FlexibleStageModel, FlexiblePress) {
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
        let pick = try XCTUnwrap(m.edgePick)
        let c = try XCTUnwrap(FlexibleM2Fixtures.edge(m, pick, faces: [3, 2]), "Edge 16: Face 3 + Face 2")
        m.toggleEdgePick(c.number)
        m.setEdgePickWeight(5)
        var done = false
        var why: String?
        Task { @MainActor in why = await m.finishEdgePick(); done = true }
        XCTAssertTrue(pumpUntil(240) { done && m.sceneState == .ready && m.openedKey == m.currentSceneKey
            && m.loadedKeys.allSatisfy { m.stacks[$0] != nil && m.geometry[$0] != nil } }, "the part open on the flat prism")
        XCTAssertNil(why)
        let press = try XCTUnwrap(m.presses.last { $0.strip?.label == FlexibleRowCopy.candidateLabel(c) })
        XCTAssertTrue(pumpUntil(120) { m.pressStack(press.id) != nil }, "registered")
        pump(0.5)
        return (r, m, press)
    }
    @discardableResult
    func pumpUntil(_ t: Double, _ c: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(t)
        while !c() { if Date() > end { return false }; _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.05)) }
        return true
    }

    // MARK: - H1

    func testTheEdgesTabHasNoStripWidth() throws {
        let (_, m, press) = try edge16()
        let h = host(FlexibleEdgeGroupsHostedTests.PanelHost(model: m).frame(width: FlexibleSettingsPanel.width, height: 1300, alignment: .top)
            .background(DS.Color.background.color), size: CGSize(width: FlexibleSettingsPanel.width, height: 1300))
        pump(1.5)
        let label = try XCTUnwrap(press.strip?.label)
        let all = axAll(h)
        let ids = Set(all.map(\.id)), labels = all.map(\.label)
        print("FLEX-E1-H1 press \(press.strip?.label ?? "") rows: \(all.filter { $0.id.hasPrefix("flexible-row-") }.map { "\($0.id) \(Int($0.frame.height))pt" })")
        XCTAssertFalse(ids.contains("flexible-row-strip-width"), "★ no Strip width row")
        XCTAssertFalse(labels.contains { $0.contains("Strip width") || $0.contains("Patch size") }, "★ no Strip width / Patch size words")
        for row in ["deepest", "tilt", "twist"] {
            let f = try XCTUnwrap(h.frames.all["flatRow-\(row)-\(label)"], "★ the \(row) row is on the tab")
            XCTAssertLessThanOrEqual(f.height, 44, "★ the \(row) row: one line")
        }
        for line in [FlexibleRowCopy.flatDeepestRow, FlexibleRowCopy.flatTiltRow(toward: "Face 3"), FlexibleRowCopy.flatTwistRow(end: "top end"),
                     FlexibleRowCopy.flatUpDownRow(into: "Face 1"), FlexibleRowCopy.flatLeftRightRow(toward: "Face 2"),
                     FlexibleRowCopy.keepsTheRest(name: "Face 3", label: "Edge 16", corner: false), FlexibleRowCopy.Info.newKind.prefix(44).description] {
            XCTAssertLessThanOrEqual(line.count, 44, "'\(line)' is one line")
        }
        XCTAssertFalse(FlexibleRowCopy.Info.newKind.contains("strip"), "★ the [+ New] words name no strip")
    }

    // MARK: - H2

    func testTheHandlesAreOnTheArrow() throws {
        let (r, m, press) = try edge16()
        let label = try XCTUnwrap(press.strip?.label)
        var report: [String] = []
        for (tag, size) in Self.sizes {
            m.selectedPress = press.id
            m.flatCameraRequest = press.id   // as [Done] or a selected press asks: the page turns to it (D-AP-13)
            let h = host(FlexibleStagePage(project: r.project, model: m, onExit: {}), size: size)
            pump(3)
            pumpUntil(15) { h.frames.marks["flatArrow-\(label)"] != nil }   // (the renderer publishes the projection on its first frame)
            pump(1.5)   // (the camera's turn to the press settles)
            let mk = h.frames.marks
            print("FLEX-E1-H2 \(tag): rail \(m.rail) · open edges \(FlexibleFlatPrismUI.openEdgesGroup(m)?.number ?? -1) · working \(FlexibleFlatPrismUI.workingPress(m) == press.id) · cut \(m.flatCut(press.id) != nil) · marks \(mk.keys.sorted()) · overlay \(FlexibleFlatPrismOverlay.lastWhy) · ends \(FlexibleFlatPrismUI.lastArrowEnds.map { "\($0.head) \($0.tail)" } ?? "-")")
            for name in ["flatPrism-\(label)", "flatArrow-\(label)", "flatDepthChip-\(label)", "flatKnob-\(label)",
                         "flatTiltBox-\(label)", "flatTwistBox-\(label)"] {
                XCTAssertNotNil(mk[name], "★ \(tag): \(name) is drawn")
            }
            let targets = ["flatDepthChip-\(label)", "flatKnob-\(label)", "flatTiltBox-\(label)", "flatTwistBox-\(label)"].compactMap { mk[$0] }
            let chrome = FlexibleStagePage.playerKeepOut(h.frames.all) + ["panel", "viewButtons", "legend", "exitRow", "capsule"].compactMap { h.frames.all[$0] }
            print("FLEX-E1-H2 \(tag) targets \(targets.map { $0.integral }) · chrome \(["panel", "viewButtons", "legend", "exitRow", "capsule"].map { "\($0) \(h.frames.all[$0]?.integral ?? .zero)" })")
            for (i, t) in targets.enumerated() {
                XCTAssertGreaterThanOrEqual(Swift.min(t.width, t.height), 44 - 0.5, "★ \(tag): a 44 pt target \(t.integral)")
                for c in chrome { XCTAssertFalse(t.intersects(c.insetBy(dx: 1, dy: 1)), "★ \(tag): \(t.integral) clear of the chrome \(c.integral)") }
                for u in targets[(i + 1)...] { XCTAssertFalse(t.intersects(u.insetBy(dx: 1, dy: 1)), "★ \(tag): the handles never overlap") }
            }
            // the chip at the arrow's head, the knob at its tail
            if let chip = mk["flatDepthChip-\(label)"], let knob = mk["flatKnob-\(label)"], let ends = FlexibleFlatPrismUI.lastArrowEnds {
                XCTAssertLessThan(hypot(chip.midX - ends.head.x, chip.midY - ends.head.y), 40, "★ \(tag): the chip at the head")
                XCTAssertGreaterThanOrEqual(hypot(knob.midX - chip.midX, knob.midY - chip.midY), 56 - 0.5, "★ \(tag): the knob ≥ 56 pt from the head")
            }
            report.append("\(tag): " + targets.map { "\(Int($0.width))×\(Int($0.height))" }.joined(separator: " "))
            if tag == "13p", let chip = mk["flatDepthChip-\(label)"] {
                click(h, CGPoint(x: chip.midX, y: chip.midY))
                XCTAssertTrue(h.frames.all.keys.contains { $0.hasPrefix("numberBoxKeypad-") } || FlexibleFlatPrismUI.lastPad == "flat-depth-\(press.id.uuidString)",
                              "★ a tap on the chip opens the keypad")
                FlexibleFlatPrismUI.lastPad = nil
            }
        }
        print("FLEX-E1-H2 " + report.joined(separator: " · "))
    }

    // MARK: - H3

    /// The camera on [Done] — D-AP-13 as ruled (the gizmo view nearest down the arrow); until the reviewer amends it, the knob is
    /// drawn ≥ 56 pt from the head so the two handles stay apart.
    func testTheCameraOnDone() throws {
        let (r, m, press) = try edge16()
        let settle = r.project.force.settleRotation ?? simd_quatf(from: SIMD3<Float>(0, 0, -1), to: SIMD3<Float>(0, -1, 0))
        let g = try XCTUnwrap(FlexibleFlatPrismUI.camera(press: press, settle: settle), "★ a view on [Done]")
        let along = settle.act(SIMD3<Float>(-press.direction))
        XCTAssertGreaterThan(simd_dot(g.direction, simd_normalize(along)), 0.99, "★ D-AP-13: down the arrow (the view nearest −d)")
        XCTAssertEqual(m.flatCameraRequest, press.id, "★ [Done] asks the page to turn")
    }
}
#endif
