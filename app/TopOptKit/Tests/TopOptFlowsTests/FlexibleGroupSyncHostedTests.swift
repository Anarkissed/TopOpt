// FlexibleGroupSyncHostedTests — round 6 ITEM 4 on the SETTINGS page as he sees it, hosted in a window (offscreen, never
// the app), on HIS pad (A1_0003 restored as he saved it; H18 runs inside): the rail names each group by its one hand
// (several: "Group N"), the Pending tab lists a main-page group with no role with its two fixes on one line each, and a
// face a main-page Anchor holds asks once in its card ("Face 0 rests (main page: Bottom)"). Written BEFORE the code.
// FLEX_I4_EVIDENCE_DIR=<dir> writes the pages (and FlexibleGroupSyncEvidence the main page).
#if canImport(AppKit) && canImport(MetalKit)
import XCTest
import SwiftUI
import AppKit
import MetalKit
import simd
import TopOptDesign
@testable import TopOptFlows
@testable import TopOptKit

private final class I4HostWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

@MainActor
final class FlexibleGroupSyncHostedTests: XCTestCase {

    final class Frames { var all: [String: CGRect] = [:] }
    struct Host { let window: NSWindow; let view: NSView; let size: CGSize; let frames: Frames }

    static var dir: URL? { ProcessInfo.processInfo.environment["FLEX_I4_EVIDENCE_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) } }
    /// His 13" portrait first (his img4's iPad), then the 11" both ways.
    static let sizes: [(String, CGSize)] = [("13p", CGSize(width: 1032, height: 1376)), ("11l", CGSize(width: 1194, height: 834)),
                                            ("11p", CGSize(width: 834, height: 1194))]

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
        let w = I4HostWindow(contentRect: CGRect(x: -20000, y: -20000, width: size.width, height: size.height),
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

    func snapshot(_ h: Host, _ name: String) {
        guard let dir = Self.dir else { return }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        h.view.layoutSubtreeIfNeeded()
        guard let rep = h.view.bitmapImageRepForCachingDisplay(in: h.view.bounds) else { return }
        h.view.cacheDisplay(in: h.view.bounds, to: rep)
        if let data = rep.representation(using: .png, properties: [:]) {
            try? data.write(to: dir.appendingPathComponent(name))
            print("FLEX-I4 wrote \(dir.appendingPathComponent(name).path)")
        }
    }

    /// His pad (H18 inside the restore), its scene, stacks and designs settled.
    func hisPad() throws -> (FlexibleHisProject.Restored, FlexibleStageModel) {
        let r = try FlexiblePressFixtures.a1Project(3, self)
        let m = FlexibleStageModel(project: r.project, materialsPath: FlexibleHisProject.materialsPath,
                                   stampsPath: FlexibleHisProject.stampsPath, persist: {})
        addTeardownBlock { @MainActor in await m.waitForIdle() }
        m.openScene()
        XCTAssertTrue(pumpUntil(180) {
            m.sceneState == .ready && m.loadedKeys.allSatisfy { m.stacks[$0] != nil && m.geometry[$0] != nil }
                && !m.readiness.designing && !m.designsInFlight
        }, "the scene, stacks and designs")
        pump(0.3)
        return (r, m)
    }

    /// He makes a group on the MAIN page with no role yet: face 5, out of its hand ("Group 3 · Face 5").
    func pendingOnTheMainPage(_ p: ProjectModel, _ m: FlexibleStageModel) -> UUID {
        let id = p.selection.addGroup()
        p.selection.addFaces([5], to: id)
        p.selection.rename(id, to: "Group D")
        p.selection.clearActive()
        m.adoptMainPageLoads(recompute: false)
        return id
    }

    // MARK: - the Pending tab

    /// ★ HIS ANSWER: "Pending shown in Settings with [Squeeze it] [It rests]". A main-page group with no role is on the
    /// rail's Pending tab, its line and its two buttons on screen, one line each, inside the panel — at his 13" portrait
    /// and on the 11" both ways. RED before the code: no Pending tab.
    func testThePendingTabCarriesItsTwoFixes() throws {
        let (r, m) = try hisPad()
        let p = r.project
        _ = pendingOnTheMainPage(p, m)
        let tabs = FlexibleSettingsRailView.tabs(model: m)
        print("FLEX-I4 rail with Group D pending: \(tabs.map { "\($0.title)\($0.detail.map { " (\($0))" } ?? "")" })")
        XCTAssertTrue(tabs.contains { $0.tab == .pending }, "★ a Pending tab on the rail")
        m.rail = .pending
        var lines: [String] = []
        for (tag, size) in Self.sizes {
            let h = host(FlexibleStagePage(project: p, model: m, onExit: {}), size: size)
            pump(2.0)
            let panel = try XCTUnwrap(local(h, "panel"), "\(tag): the panel")
            for name in ["pendingLine-0", "pendingSqueeze-0", "pendingRest-0"] {
                let f = try XCTUnwrap(local(h, name), "★ \(tag): \(name) on the page")
                XCTAssertTrue(panel.insetBy(dx: -1, dy: -1).contains(f), "\(tag): \(name) inside the panel (\(f) vs \(panel))")
                XCTAssertGreaterThanOrEqual(f.height, name == "pendingLine-0" ? 14 : 44, "\(tag): \(name) a real target")
                if name == "pendingLine-0" { XCTAssertLessThanOrEqual(f.height, 22, "\(tag): one line") }
                lines.append("\(tag) \(name) \(f.integral)")
            }
            snapshot(h, "I4_\(tag)_settings_pending_tab.png")
        }
        print("FLEX-I4 pending tab: " + lines.joined(separator: " · "))
    }

    // MARK: - the anchored face asks once, in its card

    /// ★ An anchored face pressed in Settings asks first, in its card: "Face 0 rests (main page: Bottom)" [Squeeze it]
    /// [Keep it resting]. RED before the code: nothing asks.
    func testAnAnchoredFaceAsksInItsCard() throws {
        let (r, m) = try hisPad()
        m.refreshMainPageLoads()
        m.select(0)
        XCTAssertTrue(m.press(0))
        XCTAssertEqual(m.restsAsk?.line, "Face 0 rests (main page: Bottom)")
        let size = Self.sizes[0].1
        let h = host(FlexibleStagePage(project: r.project, model: m, onExit: {}), size: size)
        pump(2.0)
        for name in ["restsAsk", "restsAskSqueeze", "restsAskKeep"] {
            XCTAssertNotNil(local(h, name), "★ \(name) in face 0's card")
        }
        snapshot(h, "I4_13p_settings_rests_ask.png")
    }
}
#endif
