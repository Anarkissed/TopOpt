// FlexibleRound5SettingsHostedTests — the round-5 Settings page HOSTED in a window (offscreen, never
// the app) on HIS project 0004, at 11" and 13", portrait and landscape, clicked (task
// 2026-09-29-flexible-screens, round 5 batch S):
//   * S8 the folder rail is on the panel's LEFT — [Model], one tab per group, [Rests], [+] — its tabs
//     select what shows beside it; six groups fit (the rail scrolls, it never leaves the panel);
//   * S6 top A and top B (the split sectors; top A is the main page's Top) have the trash, and a click
//     deletes them;
//   * S3 the deepest squish is a number box, and a click on it opens the keypad;
//   * S9 the exit button reads "Exit" as the page opens and a click leaves with nothing changed; after
//     an edit it reads "Save & Exit"; undoing back reads "Exit" again;
//   * S5 [Reset all] asks in one line, and [Reset] resets.
// FLEX_S_EVIDENCE_DIR=<dir> also writes the page (the panel's pixels; the model is Metal and is drawn
// by FlexibleRound5EvidenceProbe).
#if canImport(AppKit)
import XCTest
import SwiftUI
import AppKit
import simd
import TopOptDesign
@testable import TopOptFlows
@testable import TopOptKit

private final class R5HostWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

@MainActor
final class FlexibleRound5SettingsHostedTests: XCTestCase {

    final class Frames { var all: [String: CGRect] = [:] }
    struct Host { let window: NSWindow; let view: NSView; let size: CGSize; let frames: Frames }

    static var dir: URL? { ProcessInfo.processInfo.environment["FLEX_S_EVIDENCE_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) } }

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
        let w = R5HostWindow(contentRect: CGRect(x: -20000, y: -20000, width: size.width, height: size.height),
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
    func click(_ h: Host, _ name: String, file: StaticString = #filePath, line: UInt = #line) throws {
        let f = try XCTUnwrap(local(h, name), "\(name) is on the page", file: file, line: line)
        click(h, CGPoint(x: f.midX, y: f.midY))
        pump(0.4)
    }

    func title(_ h: Host) -> String? {
        h.frames.all.keys.first { $0.hasPrefix("exitTitle:") }.map { String($0.dropFirst("exitTitle:".count)) }
    }

    func snapshot(_ h: Host, _ name: String) {
        guard let dir = Self.dir else { return }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        h.view.layoutSubtreeIfNeeded()
        guard let rep = h.view.bitmapImageRepForCachingDisplay(in: h.view.bounds) else { return }
        h.view.cacheDisplay(in: h.view.bounds, to: rep)
        if let data = rep.representation(using: .png, properties: [:]) {
            try? data.write(to: dir.appendingPathComponent(name))
        }
    }

    func settledModel(_ project: ProjectModel) -> FlexibleStageModel {
        let stage = FlexibleMainStage()
        stage.reduceMotion = { true }
        let m = stage.model(for: project, materialsPath: FlexibleHisProject.materialsPath,
                            stampsPath: FlexibleHisProject.stampsPath, persist: {})
        addTeardownBlock { @MainActor in await m.waitForIdle() }
        m.openScene()
        XCTAssertTrue(pumpUntil(120) {
            m.sceneState == .ready && m.loadedKeys.allSatisfy { m.stacks[$0] != nil && m.geometry[$0] != nil }
                && !m.readiness.designing && !m.designsInFlight
        }, "the scene, stacks and designs")
        pump(0.3)
        return m
    }

    static let sizes: [(String, CGSize)] = [("11l", CGSize(width: 1194, height: 834)), ("11p", CGSize(width: 834, height: 1194)),
                                             ("13p", CGSize(width: 1032, height: 1376)), ("13l", CGSize(width: 1376, height: 1032))]

    func testTheRailTheBoxesTheTrashAndTheExitOnHisProject() throws {
        var report: [String] = []
        for (tag, size) in Self.sizes {
            let his = try FlexibleHisProject.restore()
            addTeardownBlock { @MainActor in his.cleanup() }
            let m = settledModel(his.project)
            m.newGroup(with: 3)   // his img 4's split: Face 3 its own squeeze group
            XCTAssertTrue(pumpUntil(60) { !m.designsInFlight && !m.readiness.designing })
            var exited = 0
            let h = host(FlexibleStagePage(project: his.project, model: m, onExit: { exited += 1 }), size: size)
            pump(2.5)
            // S8: the rail on the panel's LEFT, the open tab beside it
            let panel = try XCTUnwrap(local(h, "panel"), "\(tag): the panel")
            let rail = try XCTUnwrap(local(h, "rail"), "\(tag): the rail")
            let scroll = try XCTUnwrap(local(h, "panelScroll"), "\(tag): the tab's scroll")
            let tabs = FlexibleSettingsRailView.tabs(model: m).map(\.id)
            XCTAssertEqual(tabs, ["flexible-rail-model", "flexible-rail-group-1", "flexible-rail-group-2", "flexible-rail-rests", "flexible-rail-new"])
            for t in tabs { XCTAssertNotNil(local(h, t), "\(tag): the \(t) tab is drawn") }
            XCTAssertLessThan(rail.minX - panel.minX, 20, "\(tag): the rail sits on the panel's LEFT edge")
            XCTAssertGreaterThanOrEqual(scroll.minX, rail.maxX, "\(tag): the tab's rows are beside it, to its right")
            XCTAssertLessThanOrEqual(rail.maxY, panel.maxY + 1)
            // S9: as it opens, nothing changed — "Exit"
            XCTAssertEqual(title(h), "Exit", "\(tag): as the page opens")
            snapshot(h, "S_\(tag)_opened.png")
            // the Group 2 tab: Face 3's rows
            try click(h, "flexible-rail-group-2")
            XCTAssertEqual(m.rail, .group(2), "\(tag): a click on the tab opens it")
            XCTAssertEqual(m.selectedRegion, 3, "\(tag): its face is the one selected (and the one that plays)")
            // S3: the deepest squish is a box; a click opens the keypad
            let box = "numberBox-deepest-3"
            XCTAssertNil(local(h, "numberBoxKeypad-deepest-3"), "\(tag): no keypad before the click")
            try click(h, box)
            XCTAssertNotNil(local(h, "numberBoxKeypad-deepest-3"), "\(tag): a click on the box opens the keypad")
            snapshot(h, "S_\(tag)_group2_keypad.png")
            // S6: the Group 1 tab, top A (the main page's Top) and top B have the trash
            try click(h, "flexible-rail-group-1")
            m.select(FlexibleHisProject.topA)
            pump(0.5)
            XCTAssertNotNil(local(h, "faceRemove-\(FlexibleHisProject.topA)"), "\(tag): top A has the trash")
            snapshot(h, "S_\(tag)_group1_topA_trash.png")
            try click(h, "faceRemove-\(FlexibleHisProject.topA)")
            XCTAssertNil(m.settings.face(FlexibleHisProject.topA), "\(tag): a click deletes top A")
            m.select(FlexibleHisProject.topB)
            pump(0.5)
            XCTAssertNotNil(local(h, "faceRemove-\(FlexibleHisProject.topB)"), "\(tag): top B has the trash")
            // S9: changed — "Save & Exit"
            pump(0.3)
            XCTAssertEqual(title(h), "Save & Exit", "\(tag): after a change")
            snapshot(h, "S_\(tag)_save_and_exit.png")
            // S5: [Reset all] asks, [Reset] resets
            try click(h, "resetAll")
            XCTAssertNotNil(local(h, "resetConfirm"), "\(tag): the one-line confirm")
            snapshot(h, "S_\(tag)_reset_confirm.png")
            let fresh = m.freshSettings()
            try click(h, "resetConfirm")
            XCTAssertEqual(m.settings, fresh, "\(tag): reset")
            XCTAssertNotNil(m.settings.face(FlexibleHisProject.topA), "\(tag): top A back")
            report.append(String(format: "%@: panel x %.0f–%.0f · rail x %.0f–%.0f · tab x %.0f–%.0f · %d tabs · titles Exit → Save & Exit", tag,
                                 panel.minX, panel.maxX, rail.minX, rail.maxX, scroll.minX, scroll.maxX, tabs.count))
            // the Model tab
            try click(h, "flexible-rail-model")
            XCTAssertEqual(m.rail, .model)
            XCTAssertEqual(m.tab, .more, "the old tab follows the rail (the curves leave the part)")
            snapshot(h, "S_\(tag)_model_tab.png")
            h.window.orderOut(nil); h.window.contentView = nil
            _ = exited
        }
        print("FLEX-R5-HOSTED\n  " + report.joined(separator: "\n  "))
    }

    /// S9 end to end: a click on Exit with nothing changed leaves (no save), and after an undo back to
    /// the original value the button reads "Exit" again.
    func testExitLeavesWithoutSavingAndUndoBackReadsExit() throws {
        let his = try FlexibleHisProject.restore()
        addTeardownBlock { @MainActor in his.cleanup() }
        let m = settledModel(his.project)
        var exited = 0
        let h = host(FlexibleStagePage(project: his.project, model: m, onExit: { exited += 1 }), size: CGSize(width: 1032, height: 1376))
        pump(2.5)
        XCTAssertEqual(title(h), "Exit")
        let d0 = try XCTUnwrap(m.settings.face(5)?.deepestMM)
        m.edit { s in guard var f = s.face(5) else { return }; f.deepestMM = d0 + 1; s.setFace(f) }
        pump(0.4)
        XCTAssertEqual(title(h), "Save & Exit")
        m.edit { s in guard var f = s.face(5) else { return }; f.deepestMM = d0; s.setFace(f) }
        pump(0.4)
        XCTAssertEqual(title(h), "Exit", "back to the original value: Exit again")
        try click(h, "exitButton")
        XCTAssertEqual(exited, 1, "Exit leaves")
        XCTAssertTrue(m.exitUnchanged, "…telling the main page nothing changed")
        // ★ RED CONTROL: after a real change the same click saves (no flag)
        m.exitUnchanged = false
        m.edit { s in guard var f = s.face(5) else { return }; f.deepestMM = d0 + 1; s.setFace(f) }
        pump(0.4)
        try click(h, "exitButton")
        XCTAssertEqual(exited, 2)
        XCTAssertFalse(m.exitUnchanged, "control: Save & Exit hands the main page a change")
    }

    /// S8: six squeeze groups fit — every tab is on the rail, the rail stays inside the panel and scrolls.
    func testSixGroupsFitTheRail() throws {
        let his = try FlexibleHisProject.restore()
        addTeardownBlock { @MainActor in his.cleanup() }
        let m = settledModel(his.project)
        for r in [2, 4] { _ = m.press(r) }
        for r in [3, 5, FlexibleHisProject.topB, 2, 4] { m.newGroup(with: r) }
        XCTAssertTrue(pumpUntil(60) { !m.designsInFlight })
        XCTAssertEqual(m.squeezeGroups.count, 6)
        let h = host(FlexibleStagePage(project: his.project, model: m, onExit: {}), size: CGSize(width: 1194, height: 834))
        pump(2.5)
        let panel = try XCTUnwrap(local(h, "panel")), rail = try XCTUnwrap(local(h, "rail"))
        let tabs = FlexibleSettingsRailView.tabs(model: m)
        XCTAssertEqual(tabs.count, 1 + 6 + 1 + 1 - (m.settings.faces.contains { !$0.isLoaded } ? 0 : 1))
        XCTAssertLessThanOrEqual(rail.maxY, panel.maxY + 1, "the rail stays inside the panel (it scrolls)")
        XCTAssertEqual(m.rail, .group(try XCTUnwrap(m.playingGroup).id), "the tab open is the group that plays")
        let colours = Set(m.squeezeGroups.prefix(4).map { "\(m.groupColour($0))" })
        XCTAssertEqual(colours.count, 4, "the first four groups wear four different colours")
        snapshot(h, "S_11l_six_groups.png")
        print("FLEX-R5-HOSTED six groups: rail \(rail) in panel \(panel) · \(tabs.map(\.title))")
    }
}
#endif
