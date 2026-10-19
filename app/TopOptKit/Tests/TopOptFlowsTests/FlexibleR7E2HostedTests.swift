// FlexibleR7E2HostedTests — round 7, batch R7-E2, the hosted half (offscreen, never the app) on HIS pad (A1_0003): Edge 16 (Face 3
// + Face 2) SENT to core. Written FIRST, against stubs (red run: round7/batch_e2/e2_red_run.txt). His rules: one visible line per
// setting (≤ 44); visual over text. The ruling's item 5 (2026-10-07): "Show that in plain words: 'Squish data were measured
// pressing straight down; angled presses are estimates until they're measured.'"
//   EH1 the arrow is SOLID when the press is sent, dashed when core's side is closed (or core refused it)
//   EH2 the card's side label: "Side press · gyroid only · estimate" (core's side flag on its press stack)
//   EH3 the ruling's sentence pops ONCE per session, and is on the limits sheet and under the Export step's caption
#if canImport(AppKit) && canImport(MetalKit)
import XCTest
import SwiftUI
import AppKit
import MetalKit
import simd
import TopOptDesign
@testable import TopOptFlows
@testable import TopOptKit

private final class E2HostWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

@MainActor
final class FlexibleR7E2HostedTests: XCTestCase {
    final class Frames { var all: [String: CGRect] = [:]; var marks: [String: CGRect] = [:] }
    struct Host { let window: NSWindow; let view: NSView; let size: CGSize; let frames: Frames }
    struct AX { let id: String; let label: String; let frame: CGRect }

    override func tearDown() {
        FlexiblePressSupport.apiVersion = { FlexibleScene.pressApiVersion }
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
        let w = E2HostWindow(contentRect: CGRect(x: -20000, y: -20000, width: size.width, height: size.height),
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

    /// His pad on the main stage's shared model, `edges` picked at 5 kg ([Done]) and each in the job — SYNCHRONOUS, the run loop
    /// pumped (the page's Metal view publishes its projection only so).
    func sent(_ edges: [Set<Int>] = [[3, 2]]) throws -> (FlexibleHisProject.Restored, FlexibleMainStage, FlexibleStageModel, [FlexiblePress]) {
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
        var labels: [String] = []
        for faces in edges {
            let c = try XCTUnwrap(FlexibleM2Fixtures.edge(m, pick, faces: faces), "the edge on \(faces.sorted())")
            m.toggleEdgePick(c.number)
            labels.append(FlexibleRowCopy.candidateLabel(c))
        }
        m.setEdgePickWeight(5)
        var done = false
        var why: String?
        Task { @MainActor in why = await m.finishEdgePick(); done = true }
        XCTAssertTrue(pumpUntil(240) { done && m.sceneState == .ready && m.openedKey == m.currentSceneKey
            && m.loadedKeys.allSatisfy { m.stacks[$0] != nil && m.geometry[$0] != nil } }, "the part open on the flat prisms")
        XCTAssertNil(why)
        let presses = labels.compactMap { l in m.presses.last { $0.strip?.label == l } }
        XCTAssertEqual(presses.count, labels.count)
        XCTAssertTrue(pumpUntil(240) { presses.allSatisfy { m.pressSupport[$0.id]?.inJob == true } },
                      "★ in the job: \(presses.map { m.pressSupport[$0.id]?.line ?? "-" })")
        pump(0.5)
        return (r, stage, m, presses)
    }

    // MARK: - EH1

    /// The arrow on the model: SOLID while the press is in core's job, dashed while core's side is closed (an API stub of 1).
    func testTheArrowIsSolidWhenSentAndDashedOtherwise() throws {
        let (r, _, m, ps) = try sent()
        let press = try XCTUnwrap(ps.first)
        let label = try XCTUnwrap(press.strip?.label)
        m.selectedPress = press.id
        m.flatCameraRequest = press.id
        FlexibleFlatPrismUI.lastArrowSolid = [:]
        let h = host(FlexibleStagePage(project: r.project, model: m, onExit: {}), size: CGSize(width: 1024, height: 1366))
        pump(3)
        pumpUntil(15) { h.frames.marks["flatArrow-\(label)"] != nil }
        pump(1)
        print("FLEX-E2-H1 sent: solid \(String(describing: FlexibleFlatPrismUI.lastArrowSolid[label])) · marks \(h.frames.marks.keys.filter { $0.hasPrefix("flat") }.sorted())")
        XCTAssertEqual(FlexibleFlatPrismUI.lastArrowSolid[label], true, "★ sent: the arrow is solid")
        // ★ core's side closed (its press API answered 1): the same press is not sent — dashed
        FlexiblePressSupport.apiVersion = { 1 }
        m.pressSupportMemo = nil
        m.objectWillChange.send()
        m.selectedPress = nil
        pump(0.5)
        m.selectedPress = press.id
        pumpUntil(10) { FlexibleFlatPrismUI.lastArrowSolid[label] == false }
        print("FLEX-E2-H1 gated: solid \(String(describing: FlexibleFlatPrismUI.lastArrowSolid[label])) · '\(m.pressSupport[press.id]?.line ?? "-")'")
        XCTAssertEqual(FlexibleFlatPrismUI.lastArrowSolid[label], false, "★ not sent: the arrow is dashed")
        XCTAssertEqual(m.pressSupport[press.id]?.line, FlexibleRowCopy.pressNotSent)
    }

    // MARK: - EH2

    /// The edges tab, Edge 16 sent untwisted: its one warning line is core's side label (core's FaceFrame.side on its press stack).
    func testTheSideLabelLine() throws {
        let (_, _, m, ps) = try sent()
        let press = try XCTUnwrap(ps.first)
        let st = try XCTUnwrap(m.pressStack(press.id))
        XCTAssertTrue(st.side, "premise: core's side verdict on Edge 16's press stack (gravity −Z, a horizontal arrow)")
        guard let g = m.squeezeGroup(ofPress: press.id) else { return XCTFail("its group") }
        m.rail = .group(g.id)
        m.selectedPress = press.id
        let h = host(FlexibleEdgeGroupsHostedTests.PanelHost(model: m).frame(width: FlexibleSettingsPanel.width, height: 1300, alignment: .top)
            .background(DS.Color.background.color), size: CGSize(width: FlexibleSettingsPanel.width, height: 1300))
        pump(1.5)
        let labels = axAll(h).map(\.label)
        print("FLEX-E2-H2 the tab's lines: \(labels.filter { $0.contains("Side") || $0.contains("Set up") || $0.contains("Twisted") })")
        XCTAssertEqual(m.pressWarning(press.id)?.line, FlexibleRowCopy.sidePress, "★ the side label")
        XCTAssertTrue(labels.contains { $0.contains(FlexibleRowCopy.sidePress) }, "★ on the tab: '\(FlexibleRowCopy.sidePress)'")
        XCTAssertFalse(labels.contains { $0.contains(FlexibleRowCopy.pressNotSent) }, "★ never 'Set up · core support pending' once sent")
        XCTAssertLessThanOrEqual(FlexibleRowCopy.sidePress.count, 44)
    }

    // MARK: - EH3

    /// The ruling's sentence: popped ONCE per session (when a side press first goes into the job), never again for the next; on the
    /// limits sheet whole; under the Export step's caption once a side press is sent (its (i) the whole sentence).
    func testTheRulingsSentencePopsOncePerSession() throws {
        let (_, stage, m, ps) = try sent([[3, 2]])
        XCTAssertTrue(m.sideSentenceSaid, "★ said this session")
        XCTAssertEqual(m.toast, FlexibleRowCopy.angledEstimateShort, "★ the pop-up, in one line (≤ 44)")
        XCTAssertLessThanOrEqual(FlexibleRowCopy.angledEstimateShort.count, 44)
        m.toast = nil
        // a second press sent: not said again
        m.rail = .newGroup
        m.startEdgePick()
        XCTAssertTrue(pumpUntil(240) { m.edgePick.map { !$0.loading && !$0.checking } ?? false })
        let pick = try XCTUnwrap(m.edgePick)
        let c = try XCTUnwrap(FlexibleM2Fixtures.edge(m, pick, faces: [3, 4]), "Edge 18: Face 3 + Face 4")
        m.toggleEdgePick(c.number)
        m.setEdgePickWeight(5)
        var done = false
        Task { @MainActor in _ = await m.finishEdgePick(); done = true }
        XCTAssertTrue(pumpUntil(240) { done && m.sceneState == .ready && m.openedKey == m.currentSceneKey })
        let second = try XCTUnwrap(m.presses.last { $0.strip?.label == FlexibleRowCopy.candidateLabel(c) })
        XCTAssertTrue(pumpUntil(240) { m.pressSupport[second.id]?.inJob == true }, "the second press sent")
        pump(0.5)
        XCTAssertNotEqual(m.toast, FlexibleRowCopy.angledEstimateShort, "★ once per session: not popped again")
        // the limits sheet: the ruling's whole sentence
        XCTAssertTrue(FlexibleStageSheet.limitations.contains { $0.1.contains(FlexibleRowCopy.angledEstimateSentence) },
                      "★ the limits sheet says the ruling's sentence")
        // the Export step: a send that carries a side press says it under core's line, the whole sentence behind its (i)
        let run = stage.coreRun
        run.runner = { _, _, _, _ in FlexRunInfo(refusal: nil, receiptJSON: "{\"faces\":[{}],\"topology\":\"gyroid\"}", files: []) }
        let g = try XCTUnwrap(m.squeezeGroup(ofPress: ps[0].id))
        let fix = try XCTUnwrap(m.coreHold?.fixes.first { $0.scope == "Group \(g.number) only" }, "the edges group's send")
        run.send(m, fix: fix)
        XCTAssertTrue(pumpUntil(30) { !run.isSending })
        print("FLEX-E2-H3 export: '\(run.line)' · note '\(run.pressNote ?? "-")'")
        XCTAssertEqual(run.pressNote, FlexibleRowCopy.angledEstimateShort, "★ the Export caption says it")
        let h = host(FlexibleExportRows.PressNote(run: run).frame(width: 420), size: CGSize(width: 420, height: 120))
        pump(0.5)
        let ax = axAll(h)
        XCTAssertTrue(ax.contains { $0.label.contains(FlexibleRowCopy.angledEstimateShort) }, "★ drawn under core's line")
        XCTAssertTrue(ax.contains { $0.id == "flexible-export-press-note-info" }, "★ its (i) holds the whole sentence")
    }
}
#endif
