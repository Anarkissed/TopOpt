// FlexibleSettingsPageHostedTests — the Settings page HOSTED in a window (offscreen, never the
// app), on HIS project 0004, read through the page's own frames (task
// 2026-09-29-flexible-screens, round 4 batch D1 verification; the verifier's harness).
//
//   * the BLOCKER: after a tap on a face in the list (and as the page opens), every row of that
//     face — its [Pressed | Rests], weight, Shape, the stamp's rows, the depth — is ON the panel
//     at 11" and 13", portrait and landscape. D1 listed seven 48 pt rows above them: on 11"
//     landscape none of them showed, and nothing scrolled to them;
//   * the legend folds to a bar SMALLER than itself, and a click on the bar brings it back.
#if canImport(AppKit)
import XCTest
import SwiftUI
import AppKit
import simd
import TopOptDesign
@testable import TopOptFlows
@testable import TopOptKit

private final class FlexHostWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

@MainActor
final class FlexibleSettingsPageHostedTests: XCTestCase {

    final class Frames { var all: [String: CGRect] = [:] }
    struct Host { let window: NSWindow; let view: NSView; let size: CGSize; let frames: Frames }

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
        let w = FlexHostWindow(contentRect: CGRect(x: -20000, y: -20000, width: size.width, height: size.height),
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

    /// A frame in the page's own space (top-left origin).
    func local(_ h: Host, _ name: String) -> CGRect? {
        guard let f = h.frames.all[name] else { return nil }
        guard let page = h.frames.all["page"] else { return f }
        return f.offsetBy(dx: -page.minX, dy: -page.minY)
    }

    func click(_ h: Host, _ p: CGPoint) {
        let loc = NSPoint(x: p.x, y: h.size.height - p.y)
        for t in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let e = NSEvent.mouseEvent(with: t, location: loc, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                       windowNumber: h.window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
            h.window.sendEvent(e)
            pump(0.06)
        }
    }

    /// The main page's ONE shared model for `project`, opened and settled (the page's own pipeline).
    func settledModel(_ project: ProjectModel) -> FlexibleStageModel {
        let stage = FlexibleMainStage()
        stage.reduceMotion = { true }
        let m = stage.model(for: project, materialsPath: FlexibleHisProject.materialsPath,
                            stampsPath: FlexibleHisProject.stampsPath, persist: {})
        addTeardownBlock { @MainActor in await m.waitForIdle() }
        m.openScene()
        settle(m)
        return m
    }

    func settle(_ m: FlexibleStageModel) {
        XCTAssertTrue(pumpUntil(120) {
            m.sceneState == .ready && m.loadedKeys.allSatisfy { m.stacks[$0] != nil && m.geometry[$0] != nil }
                && !m.readiness.designing && !m.designsInFlight
        }, "the scene, stacks and designs")
        pump(0.3)
    }

    static let sizes: [(String, CGSize)] = [("11l", CGSize(width: 1194, height: 834)), ("11p", CGSize(width: 834, height: 1194)),
                                             ("13p", CGSize(width: 1032, height: 1376)), ("13l", CGSize(width: 1376, height: 1032))]

    // MARK: - the BLOCKER: the selected face's rows are on the panel

    func testTheSelectedFacesRowsAreOnThePanelOnHisProject() throws {
        let his = try FlexibleHisProject.restore()
        addTeardownBlock { @MainActor in his.cleanup() }
        let m = settledModel(his.project)
        let a = FlexibleHisProject.topA
        // ★ RED CONTROL: his Face tab is far taller than the panel's scroll at 11" landscape, so a
        // face's rows below the list (D1) — or anywhere, unscrolled — can sit below the fold
        m.select(5)
        let content = FlexibleSettingsRound4Tests.height(FlexibleFacePanel(model: m, padTarget: .constant(nil)),
                                                         proposed: CGSize(width: FlexibleSettingsPanel.width - 2 * DS.Space.ml, height: 5000))
        let cap11l = 834 * 0.62
        print(String(format: "FLEX-HOSTED his Face tab %.0f pt tall · the panel's cap at 11\" landscape %.0f pt", content, cap11l))
        XCTAssertGreaterThan(content, cap11l, "control: the rows cannot all show at once — the card must be brought to view")
        var report: [String] = []
        for (tag, size) in Self.sizes {
            let h = host(FlexibleStagePage(project: his.project, model: m, onExit: {}), size: size)
            pump(2.5)
            // as the page opens (the fix pop-up has selected a face), then a list tap on each kind
            let steps: [(String, () -> Void)] = [
                ("as opened", {}),
                ("top A", { m.select(a) }),
                ("top A · Stamp", { m.setShape(a, "stamp") }),
                ("face 5 (last pressed)", { m.select(5) }),
                ("face 4 (last row)", { m.select(4) }),
            ]
            for (name, act) in steps {
                act()
                if name.contains("Stamp") { pumpUntil(30) { m.stampFootprint(a) != nil } }
                // the rows must ARRIVE in what the panel's scroll SHOWS (under its header and tabs,
                // above its bottom padding) within 2 s of the tap
                func isOn() -> Bool {
                    guard let v = local(h, "panelScroll"), let c = local(h, "faceCard") else { return false }
                    return c.minY >= v.minY - 1 && c.maxY <= v.maxY + 1
                }
                let start = Date()
                while !isOn() && Date().timeIntervalSince(start) < 2 { pump(0.1) }
                pump(0.3)
                let panel = try XCTUnwrap(local(h, "panelScroll"), "\(tag) \(name): the panel's scroll frame")
                let card = try XCTUnwrap(local(h, "faceCard"), "\(tag) \(name): the selected face's card")
                let on = isOn()
                report.append(String(format: "%@ %@: card %.0f–%.0f in the panel's scroll %.0f–%.0f (%.0f pt) %@", tag, name,
                                     card.minY, card.maxY, panel.minY, panel.maxY, card.height, on ? "✓" : "✗ OFF"))
                XCTAssertTrue(on, "\(tag) \(name): the selected face's rows must be on the panel — card \(card) · scroll \(panel)")
            }
            m.setShape(a, "curves")
            pump(0.5)
            h.window.orderOut(nil); h.window.contentView = nil
        }
        print("FLEX-HOSTED\n  " + report.joined(separator: "\n  "))
    }

    // MARK: - the legend folds SMALLER, and the bar brings it back

    func testTheLegendFoldsToASmallerBarAndTheBarBringsItBack() throws {
        var s = FlexibleStageSettings(materialID: "varioshore_tpu")
        let probe = try FlexibleHisProject.padProject(s)
        let top = FlexibleHisProject.topFace(try XCTUnwrap(probe.viewerMesh))
        s.setFace(FlexibleFaceSettings(faceRegionID: top, weightKg: 10, deepestMM: 3))
        let project = try FlexibleHisProject.padProject(s)
        let m = settledModel(project)
        let h = host(FlexibleStagePage(project: project, model: m, onExit: {}), size: CGSize(width: 1032, height: 1376))
        pump(2.5)
        let open = try XCTUnwrap(local(h, "legend"), "the legend is shown (a dent)")
        click(h, CGPoint(x: open.maxX - 22, y: open.minY + 22))          // its chevron
        pump(0.8)
        let folded = try XCTUnwrap(local(h, "legend"))
        click(h, CGPoint(x: folded.midX, y: folded.midY))                 // the bar
        pump(0.8)
        let back = try XCTUnwrap(local(h, "legend"))
        print(String(format: "FLEX-LEGEND open %.0f × %.0f · folded %.0f × %.0f · after a click on the bar %.0f × %.0f",
                     open.width, open.height, folded.width, folded.height, back.width, back.height))
        XCTAssertLessThan(folded.width, 80, "folded: the lattice legend's narrow bar")
        XCTAssertLessThan(folded.height, open.height, "folding makes it SMALLER")
        XCTAssertEqual(back.size.width, open.size.width, accuracy: 1, "a click on the bar brings it back")
        XCTAssertEqual(back.size.height, open.size.height, accuracy: 1)
        // ★ RED CONTROL: D1's 150 pt bar was taller than the open legend
        let bar = NSHostingController(rootView: FlexibleLegendBar(fraction: nil)).sizeThatFits(in: CGSize(width: 400, height: 900))
        let d1 = bar.height - FlexibleLegendBar.barHeight + 150
        XCTAssertGreaterThan(d1, open.height, "control: D1's folded legend (\(d1) pt) was taller than the open one")
    }
}
#endif
