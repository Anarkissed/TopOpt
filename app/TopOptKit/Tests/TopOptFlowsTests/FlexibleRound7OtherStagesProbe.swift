// FlexibleRound7OtherStagesProbe — round 7, batch R7-D1, the reviewer's condition (e) (2026-10-14 19:45): "a simulator look
// at Topology, Structural and Surface" before "done", and the ruling's promise: "On Topology, on the Structural/Aesthetic
// lattice stage and on Surface, the code that runs is today's, byte for byte. A Flexible project on Topology or Surface also
// keeps today's screen: the old bottom bar, the H10 pill and the Export step."
//
// Opt-in (FLEX_R7D1_STAGES_DIR=<dir>): the WHOLE app page hosted offscreen (WorkspacePlaceholder), each stage reached by its
// own navigation buttons, and its CHROME written — the SwiftUI layer as drawn (the MetalMeshView's own pixels are not in a
// view cache, so the part is absent and the comparison is the chrome's alone). (No accessibility dump: in a test process
// SwiftUI builds no accessibility tree without an assistive client — checked, empty.) Run it once on the head BEFORE the hooks and once AFTER: the two folders must match (compare_stages.py).
//   his7/3418E167 'M2 verticalStand THICK' (Structural): Topology, the Structural lattice stage, Surface
//   his7/68BF7B74 'M2 verticalStand' (Aesthetic): the Aesthetic lattice stage
//   his7/887AC498 'shelvesb' (no lattice): Topology
//   A1_0003 his Flexible pad: Topology and Surface (the old bar with the H10 pill and Optimize)
#if canImport(AppKit) && canImport(MetalKit)
import XCTest
import SwiftUI
import AppKit
import TopOptDesign
@testable import TopOptFlows
@testable import TopOptKit

private final class R7D1StagesWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

@MainActor
final class FlexibleRound7OtherStagesProbe: XCTestCase {
    static var dir: URL? { ProcessInfo.processInfo.environment["FLEX_R7D1_STAGES_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) } }

    func pump(_ s: Double) {
        let end = Date().addingTimeInterval(s)
        while Date() < end { _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.02)) }
    }
    struct Host { let window: NSWindow; let view: NSView; let size: CGSize }
    func host<V: View>(_ v: V, size: CGSize) -> Host {
        let hv = NSHostingView(rootView: AnyView(v.environment(\.colorScheme, .dark)))
        hv.frame = CGRect(origin: .zero, size: size)
        _ = NSApplication.shared
        let w = R7D1StagesWindow(contentRect: CGRect(x: -20000, y: -20000, width: size.width, height: size.height),
                                 styleMask: [.borderless], backing: .buffered, defer: false)
        w.appearance = NSAppearance(named: .darkAqua)
        w.contentView = hv
        w.setFrameOrigin(NSPoint(x: -20000, y: -20000))
        w.orderFrontRegardless()
        w.makeKey()
        hv.layoutSubtreeIfNeeded()
        addTeardownBlock { @MainActor in w.orderOut(nil); w.contentView = nil }
        return Host(window: w, view: hv, size: size)
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
    func write(_ h: Host, _ name: String) {
        guard let dir = Self.dir else { return }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        h.view.layoutSubtreeIfNeeded()
        if let rep = h.view.bitmapImageRepForCachingDisplay(in: h.view.bounds) {
            h.view.cacheDisplay(in: h.view.bounds, to: rep)
            if let d = rep.representation(using: .png, properties: [:]) { try? d.write(to: dir.appendingPathComponent(name + ".png")) }
        }
    }

    /// One stage, from a fresh host: Topology as the project opens, or Topology's own top-right button (Lattice, or Surface
    /// under it) — the stage's navigation as he taps it.
    func shoot(_ folder: String, tag: String, size: CGSize, flexible: Bool, stage: WorkspaceStage) throws {
        let src = flexible ? FlexiblePressFixtures.a1Dir(3) : FlexiblePressFixtures.frozenDir.appendingPathComponent("his7/" + folder, isDirectory: true)
        let r = try FlexibleHisProject.restore(src, asSaved: true)
        addTeardownBlock { r.cleanup() }
        let h = host(WorkspacePlaceholder(model: r.app, project: r.project), size: size)
        pump(5)
        let x = size.width - PageChrome.gizmoClearance - 62
        switch stage {
        case .topology: break
        case .lattice: click(h, CGPoint(x: x, y: PageChrome.gizmoAlignedTop + PageChrome.compactButton / 2)); pump(5)
        case .surface: click(h, CGPoint(x: x, y: PageChrome.gizmoAlignedTop + PageChrome.compactButton * 1.5 + PageChrome.gap)); pump(5)
        }
        write(h, "\(tag)_\(stage.rawValue)")
        if let s = FlexibleMainStage.lastMade, flexible { await_(s) }
        h.window.orderOut(nil)
    }

    func run(_ folder: String, tag: String, size: CGSize, flexible: Bool) throws {
        try shoot(folder, tag: tag, size: size, flexible: flexible, stage: .topology)
        if folder == "887AC498-5B5D-4475-B6CB-893DC69B5FD6" { return }
        if !flexible { try shoot(folder, tag: tag, size: size, flexible: flexible, stage: .lattice) }
        if folder == "68BF7B74-3C2A-4ED6-A46D-AC040A9CA649" { return }
        try shoot(folder, tag: tag, size: size, flexible: flexible, stage: .surface)
    }
    func await_(_ s: FlexibleMainStage) { addTeardownBlock { @MainActor in await s.model?.waitForIdle() } }

    func testStructural13p() throws {
        guard Self.dir != nil else { throw XCTSkip("FLEX_R7D1_STAGES_DIR") }
        try run("3418E167-8524-4831-A809-827B6B0742D0", tag: "13p_structural3418", size: CGSize(width: 1032, height: 1376), flexible: false)
    }
    func testStructural11l() throws {
        guard Self.dir != nil else { throw XCTSkip("FLEX_R7D1_STAGES_DIR") }
        try run("3418E167-8524-4831-A809-827B6B0742D0", tag: "11l_structural3418", size: CGSize(width: 1194, height: 834), flexible: false)
    }
    func testAesthetic13p() throws {
        guard Self.dir != nil else { throw XCTSkip("FLEX_R7D1_STAGES_DIR") }
        try run("68BF7B74-3C2A-4ED6-A46D-AC040A9CA649", tag: "13p_aesthetic68BF", size: CGSize(width: 1032, height: 1376), flexible: false)
    }
    func testPlain13p() throws {
        guard Self.dir != nil else { throw XCTSkip("FLEX_R7D1_STAGES_DIR") }
        try run("887AC498-5B5D-4475-B6CB-893DC69B5FD6", tag: "13p_plain887A", size: CGSize(width: 1032, height: 1376), flexible: false)
    }
    func testFlexibleOnTopologyAndSurface13p() throws {
        guard Self.dir != nil else { throw XCTSkip("FLEX_R7D1_STAGES_DIR") }
        try run("", tag: "13p_flexiblePad0003", size: CGSize(width: 1032, height: 1376), flexible: true)
    }
    func testFlexibleOnTopologyAndSurface11l() throws {
        guard Self.dir != nil else { throw XCTSkip("FLEX_R7D1_STAGES_DIR") }
        try run("", tag: "11l_flexiblePad0003", size: CGSize(width: 1194, height: 834), flexible: true)
    }
}
#endif
