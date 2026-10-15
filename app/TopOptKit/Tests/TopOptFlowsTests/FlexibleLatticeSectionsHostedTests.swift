// FlexibleLatticeSectionsHostedTests — round 7 batch M2, the Squish page HOSTED in a window (offscreen, never the app) on HIS
// LIVE LATTICE. Written BEFORE the code. His img3 words: "when I tapped the top, it selected the model's top face, rather
// than one of the lattice's top faces." A tap on the solid middle of the Top selects nothing; the page says one line,
// "Solid here · only face-prisms get latticed", with ONE fix, [Go to Lattice], which leaves the page (its Exit — never
// Save & Exit's bake). RED (run here): today's tap selects Face 1 and says nothing.
// FLEX_M2_EVIDENCE_DIR=<dir> also writes the page.
#if canImport(AppKit)
import XCTest
import SwiftUI
import AppKit
import simd
@testable import TopOptFlows
@testable import TopOptKit

private final class M2HostWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

@MainActor
final class FlexibleLatticeSectionsHostedTests: XCTestCase {
    final class Frames { var all: [String: CGRect] = [:] }
    struct Host { let window: NSWindow; let view: NSView; let size: CGSize; let frames: Frames }

    static var dir: URL? { ProcessInfo.processInfo.environment["FLEX_M2_EVIDENCE_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) } }

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
        let w = M2HostWindow(contentRect: CGRect(x: -20000, y: -20000, width: size.width, height: size.height),
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

    func snapshot(_ h: Host, _ name: String) {
        guard let dir = Self.dir else { return }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        h.view.layoutSubtreeIfNeeded()
        guard let rep = h.view.bitmapImageRepForCachingDisplay(in: h.view.bounds) else { return }
        h.view.cacheDisplay(in: h.view.bounds, to: rep)
        if let data = rep.representation(using: .png, properties: [:]) { try? data.write(to: dir.appendingPathComponent(name)) }
    }

    /// His live lattice opened the app's way (the main page's shared model), synchronously.
    func liveOpened() throws -> (FlexibleHisProject.Restored, FlexibleStageModel) {
        let r = try FlexiblePressFixtures.a1Project(3, self, facePrism: false)
        try FlexibleR7M1Fixtures.hisLiveLattice(r.project)
        let stage = FlexibleMainStage()
        stage.reduceMotion = { true }
        let m = stage.model(for: r.project, materialsPath: FlexibleHisProject.materialsPath,
                            stampsPath: FlexibleHisProject.stampsPath, persist: {})
        addTeardownBlock { @MainActor in await m.waitForIdle() }
        m.openScene()
        XCTAssertTrue(pumpUntil(180) { m.sceneState == .ready && m.loadedKeys.allSatisfy { m.stacks[$0] != nil && m.geometry[$0] != nil } },
                      "the scene and stacks")
        pump(0.5)
        return (r, m)
    }

    func testASolidTapShowsTheLineAndOneFix() throws {
        let (r, m) = try liveOpened()
        var exited = 0
        let size = CGSize(width: 1032, height: 1376)
        let h = host(FlexibleStagePage(project: r.project, model: m, onExit: { exited += 1 }), size: size)
        pump(2.5)
        let b = r.project.viewerMesh!.bounds
        let centre = SIMD3<Double>(Double(b.min.x + b.max.x) / 2, Double(b.min.y + b.max.y) / 2, Double(b.max.z))
        let before = m.selectedRegion
        m.tapFace(1, point: centre)   // the page's onPickPoint hands the tap here (FlexibleStagePage.stage)
        pump(0.8)
        XCTAssertEqual(m.selectedRegion, before, "★ a tap on solid selects nothing")
        let line = h.frames.all.keys.first { $0.hasPrefix("toastLine:") }.map { String($0.dropFirst("toastLine:".count)) }
        XCTAssertEqual(line, FlexibleRowCopy.solidHere, "★ its one line is on the page")
        XCTAssertLessThanOrEqual(FlexibleRowCopy.solidHere.count, 44)
        let pill = try XCTUnwrap(local(h, "toast"), "the line's pill")
        XCTAssertLessThanOrEqual(pill.height, 44, "★ one line")
        let fix = try XCTUnwrap(local(h, "toastFix"), "★ its ONE fix: [Go to Lattice]")
        XCTAssertGreaterThanOrEqual(fix.height, 28)
        snapshot(h, "R7M2_13p_solid_tap_line_and_fix.png")
        click(h, CGPoint(x: fix.midX, y: fix.midY))
        pump(0.5)
        print("FLEX-M2-HOSTED line '\(line ?? "none")' pill \(pill) · fix \(fix) · exited \(exited)")
        XCTAssertEqual(exited, 1, "★ [Go to Lattice] leaves the page (its Exit)")

        // ★ RED CONTROL: today's whole face — the tap selects Face 1, no line
        FlexibleLatticeSections.controlWholeFace = true
        defer { FlexibleLatticeSections.controlWholeFace = false }
        let (r2, m2) = try liveOpened()
        let b2 = r2.project.viewerMesh!.bounds
        m2.tapFace(1, point: SIMD3<Double>(Double(b2.min.x + b2.max.x) / 2, Double(b2.min.y + b2.max.y) / 2, Double(b2.max.z)))
        XCTAssertEqual(m2.selectedRegion, 1, "control: the model's whole top face")
        XCTAssertNil(m2.toastFix, "control: no fix offered")
    }
}
#endif
