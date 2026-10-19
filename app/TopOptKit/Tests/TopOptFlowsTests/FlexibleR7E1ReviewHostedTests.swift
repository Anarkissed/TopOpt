// FlexibleR7E1ReviewHostedTests — round 7, the review of R7-E1, the hosted half (offscreen, never the app) on HIS pad (A1_0003):
// the whole Squish page with its own camera. Written FIRST, against stubs; each RED CONTROL inside its test.
//   V1 [Done] turns the camera to the new flat prism (D-AP-13 as ruled); a fix pop-up that fires by itself once the scene settles
//      ("Group 2 would squish ~14.3 of 15.9 mm …" on his pad) is shown but no longer turns the camera to the back.
//   V2 in his working views — the home view (45°, 30° up) and his steeper ~55° — the angle knob and its two boxes are ON the
//      screen (the arrow points at the camera, so its true tail was off the bottom), ≥ 56 pt from the chip, clear of the chrome;
//      the chip itself clear of the chrome (it sat 19 pt under the panel).
#if canImport(AppKit) && canImport(MetalKit)
import XCTest
import SwiftUI
import AppKit
import MetalKit
import simd
import TopOptDesign
@testable import TopOptFlows
@testable import TopOptKit

private final class E1RHostWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

@MainActor
final class FlexibleR7E1ReviewHostedTests: XCTestCase {
    final class Frames { var all: [String: CGRect] = [:]; var marks: [String: CGRect] = [:] }
    struct Host { let window: NSWindow; let view: NSView; let size: CGSize; let frames: Frames }
    static let p13 = CGSize(width: 1032, height: 1376), l11 = CGSize(width: 1194, height: 834)

    override func tearDown() {
        FlexibleStagePage.controlPopupTurnsCamera = false
        FlexibleFlatPrismUI.controlKnobAtTailOnly = false
        super.tearDown()
    }

    func pump(_ s: Double) {
        let end = Date().addingTimeInterval(s)
        while Date() < end { _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.02)) }
    }
    @discardableResult
    func pumpUntil(_ t: Double, _ c: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(t)
        while !c() { if Date() > end { return false }; _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.05)) }
        return true
    }
    func host<V: View>(_ v: V, size: CGSize) -> Host {
        let frames = Frames()
        let root = AnyView(v.onPreferenceChange(FlexibleKeepOutKey.self) { frames.all = $0 }
            .onPreferenceChange(FlexibleViewMarksKey.self) { frames.marks = $0 }.environment(\.colorScheme, .dark))
        let hv = NSHostingView(rootView: root)
        hv.frame = CGRect(origin: .zero, size: size)
        _ = NSApplication.shared
        let w = E1RHostWindow(contentRect: CGRect(x: -20000, y: -20000, width: size.width, height: size.height),
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

    // the page's own camera (its Metal view's orbit gesture target)
    func mtkViews(_ v: NSView) -> [MTKView] {
        var out: [MTKView] = []
        if let m = v as? MTKView { out.append(m) }
        for s in v.subviews { out += mtkViews(s) }
        return out
    }
    func cameraModel(_ h: Host) -> OrbitCameraModel? {
        let views = mtkViews(h.view).filter { $0.delegate is MeshRenderer }
        guard let mtk = views.max(by: { $0.bounds.width * $0.bounds.height < $1.bounds.width * $1.bounds.height }) else { return nil }
        for g in mtk.gestureRecognizers {
            guard let t = g.target else { continue }
            for c in Mirror(reflecting: t).children where c.label == "cameraModel" {
                if let cm = c.value as? OrbitCameraModel { return cm }
            }
        }
        return nil
    }

    /// His pad (the Top's 20 mm face-prism), on the main stage, open.
    func openPad() throws -> (FlexibleHisProject.Restored, FlexibleStageModel) {
        let r = try FlexiblePressFixtures.a1Project(3, self)
        let stage = FlexibleMainStage()
        stage.reduceMotion = { true }
        let m = stage.model(for: r.project, materialsPath: FlexibleHisProject.materialsPath,
                            stampsPath: FlexibleHisProject.stampsPath, persist: {})
        addTeardownBlock { @MainActor in await m.waitForIdle() }
        m.openScene()
        XCTAssertTrue(pumpUntil(120) { m.sceneState == .ready && m.loadedKeys.allSatisfy { m.stacks[$0] != nil && m.geometry[$0] != nil } },
                      "the scene and stacks")
        return (r, m)
    }

    /// The Face 2 + Face 3 edge picked and [Done] (the run loop pumped): its press.
    func pickEdge(_ m: FlexibleStageModel) throws -> FlexiblePress {
        m.rail = .newGroup
        m.startEdgePick()
        XCTAssertTrue(pumpUntil(240) { m.edgePick.map { !$0.loading && !$0.checking } ?? false }, "listed")
        let pick = try XCTUnwrap(m.edgePick)
        let c = try XCTUnwrap(FlexibleM2Fixtures.edge(m, pick, faces: [3, 2]), "Face 3 + Face 2")
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
        return press
    }

    // MARK: - V1

    /// V1. The page is up; [Done] on Face 3 + Face 2 turns the camera to the press (D-AP-13's view). Once the scene settles the fix
    /// pop-up fires by itself — it is SHOWN, and the camera stays on the press. RED CONTROL (E1): the pop-up turns it away.
    func testAPopUpAfterDoneKeepsTheTurn() throws {
        for control in [true, false] {
            FlexibleStagePage.controlPopupTurnsCamera = control
            let (r, m) = try openPad()
            let h = host(FlexibleStagePage(project: r.project, model: m, onExit: {}), size: Self.p13)
            pump(3)
            let press = try pickEdge(m)
            let settle = r.project.force.settleRotation ?? simd_quatf(from: SIMD3<Float>(0, 0, -1), to: SIMD3<Float>(0, -1, 0))
            let g = try XCTUnwrap(FlexibleFlatPrismUI.camera(press: press, settle: settle), "D-AP-13's view")
            let popped = pumpUntil(60) { h.frames.all["popup"] != nil }
            pump(2)
            let cm = try XCTUnwrap(cameraModel(h), "the page's camera")
            let want = g.orientation(currentAzimuth: cm.camera.azimuth)
            print("FLEX-E1R-V1 control \(control): pop-up \(popped) · camera az \(cm.camera.azimuth) el \(cm.camera.elevation) · D-AP-13 \(g.id) az \(want.azimuth) el \(want.elevation)")
            XCTAssertTrue(popped, "the case: a pop-up fires by itself after [Done] on his pad")
            let off = abs(remainder(Double(cm.camera.azimuth - want.azimuth), 2 * .pi)) + abs(Double(cm.camera.elevation - want.elevation))
            if control {
                XCTAssertGreaterThan(off, 0.2, "★ RED CONTROL: the pop-up turned the camera away from the press")
            } else {
                XCTAssertLessThan(off, 0.02, "★ the camera stays on the new flat prism")
            }
        }
    }

    // MARK: - V2

    /// V2. In the home view (45°, 30° up) and his ~55° view, at 13" portrait and 11" landscape: the knob and its two boxes are drawn,
    /// on the screen, clear of the chrome, ≥ 56 pt from the chip; the chip clear of the chrome too. RED CONTROL (E1's knob at the
    /// true tail only): no knob in these views.
    func testTheKnobIsOnScreenInHisWorkingViews() throws {
        let (r, m) = try openPad()
        let press = try pickEdge(m)
        let label = try XCTUnwrap(press.strip?.label)
        for control in [true, false] {
            FlexibleFlatPrismUI.controlKnobAtTailOnly = control
            for (tag, size) in [("13p", Self.p13), ("11l", Self.l11)] {
                for (vtag, el) in [("home", Float.pi / 6), ("55°", Float(55 * Double.pi / 180))] {
                    m.selectedPress = press.id
                    let h = host(FlexibleStagePage(project: r.project, model: m, onExit: {}), size: size)
                    pump(2.5)
                    let cm = try XCTUnwrap(cameraModel(h))
                    var c = cm.camera
                    c.setOrientation(azimuth: .pi / 4, elevation: el)
                    cm.adopt(c)
                    pump(1.5)
                    pumpUntil(10) { h.frames.marks["flatArrow-\(label)"] != nil }
                    pump(0.5)
                    let mk = h.frames.marks
                    let chrome = FlexibleStagePage.playerKeepOut(h.frames.all)
                        + ["panel", "viewButtons", "legend", "exitRow", "capsule", "popup", "notice", "toast"].compactMap { h.frames.all[$0] }
                    let view = CGRect(origin: .zero, size: size)
                    print("FLEX-E1R-V2 control \(control) \(tag) \(vtag): marks \(mk.keys.filter { $0.hasPrefix("flat") }.sorted().map { "\($0) \(mk[$0]!.integral)" })")
                    if control {
                        if vtag == "home", tag == "13p" { XCTAssertNil(mk["flatKnob-\(label)"], "★ RED CONTROL: no knob in the home view (its tail is off the screen)") }
                        continue
                    }
                    let knob = try XCTUnwrap(mk["flatKnob-\(label)"], "★ \(tag) \(vtag): the knob is drawn")
                    let chip = try XCTUnwrap(mk["flatDepthChip-\(label)"], "\(tag) \(vtag): the chip")
                    for (name, t) in [("knob", knob), ("chip", chip)] + ["flatTiltBox", "flatTwistBox"].compactMap({ k in mk["\(k)-\(label)"].map { (k, $0) } }) {
                        XCTAssertTrue(view.insetBy(dx: 8, dy: 8).contains(t), "★ \(tag) \(vtag): the \(name) \(t.integral) is on the screen")
                        for c in chrome { XCTAssertFalse(t.intersects(c.insetBy(dx: 1, dy: 1)), "★ \(tag) \(vtag): the \(name) \(t.integral) clear of \(c.integral)") }
                    }
                    XCTAssertNotNil(mk["flatTiltBox-\(label)"], "★ \(tag) \(vtag): the tilt box")
                    XCTAssertNotNil(mk["flatTwistBox-\(label)"], "★ \(tag) \(vtag): the twist box")
                    XCTAssertGreaterThanOrEqual(hypot(knob.midX - chip.midX, knob.midY - chip.midY), 56 - 0.5, "★ \(tag) \(vtag): the knob ≥ 56 pt from the chip")
                }
            }
        }
    }
}
#endif
