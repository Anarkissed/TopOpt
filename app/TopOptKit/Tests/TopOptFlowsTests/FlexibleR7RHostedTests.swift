// FlexibleR7RHostedTests — round 7, "the review of M2 and F", the hosted half (offscreen, never the app), on HIS pad
// (A1_0003 as he saved it: three squeeze groups) at 13" portrait and 11" landscape. Written BEFORE the code (the stubs' red
// run: round7/review_fix/r7r_red_run.txt); each with its RED control run inside. His words (tasks.md):
//   answer 10: "Face card group chips: show the group NAMES."   his rule: 44 pt targets.
//   2026-10-15 (1): "With Bend on, the depth chip and depth labels MOVE with the bend (everything goes to the full-bend pose)."
//   RH1 the face card's NAMED chips are drawn on his pad with his three groups (the review: at both sizes the row fell back to
//       one menu chip, "● Group 2 ⌄"). RED `FlexibleFaceGroupRow.controlMenuFallback`.
//   RH2 F's new controls are finger targets: the face row's take-out, the trash's [Delete] and [Keep], [Reset all] and its
//       [Reset] — each at least 44 × 44 pt. RED `FlexibleTargets.controlSmall`.
//   RH3 with Bend on, the depth chip is drawn where the bent face puts it. RED `FlexibleBendPose.controlInsideStays`.
// FLEX_R7R_EVIDENCE_DIR=<dir> also writes the hosted pages.
#if canImport(AppKit) && canImport(MetalKit)
import XCTest
import SwiftUI
import AppKit
import MetalKit
import simd
import TopOptDesign
@testable import TopOptFlows
@testable import TopOptKit

private final class R7RHostWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

@MainActor
final class FlexibleR7RHostedTests: XCTestCase {
    final class Frames { var all: [String: CGRect] = [:]; var marks: [String: CGRect] = [:] }
    struct Host { let window: NSWindow; let view: NSView; let size: CGSize; let frames: Frames }

    static var dir: URL? { ProcessInfo.processInfo.environment["FLEX_R7R_EVIDENCE_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) } }
    static let sizes: [(String, CGSize)] = [("13p", CGSize(width: 1032, height: 1376)), ("11l", CGSize(width: 1194, height: 834))]

    override func tearDown() {
        FlexibleFaceGroupRow.controlMenuFallback = false
        FlexibleTargets.controlSmall = false
        FlexibleBendPose.controlInsideStays = false
        super.tearDown()
    }

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
        let root = AnyView(v.onPreferenceChange(FlexibleKeepOutKey.self) { frames.all = $0 }
            .onPreferenceChange(FlexibleViewMarksKey.self) { frames.marks = $0 }
            .environment(\.colorScheme, .dark))
        let hv = NSHostingView(rootView: root)
        hv.frame = CGRect(origin: .zero, size: size)
        _ = NSApplication.shared
        let w = R7RHostWindow(contentRect: CGRect(x: -20000, y: -20000, width: size.width, height: size.height),
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
        if let data = rep.representation(using: .png, properties: [:]) { try? data.write(to: dir.appendingPathComponent(name)) }
    }

    /// His pad on a main stage's model, the scene, stacks and designs settled; his three groups.
    func hisPad() throws -> (FlexibleHisProject.Restored, FlexibleStageModel) {
        let stage = FlexibleMainStage()
        let r = try FlexiblePressFixtures.a1Project(3, self)
        stage.reduceMotion = { true }
        let m = stage.model(for: r.project, materialsPath: FlexibleHisProject.materialsPath, stampsPath: FlexibleHisProject.stampsPath, persist: {})
        addTeardownBlock { @MainActor in await m.waitForIdle() }
        m.openScene()
        XCTAssertTrue(pumpUntil(180) {
            m.sceneState == .ready && m.loadedKeys.allSatisfy { m.stacks[$0] != nil && m.geometry[$0] != nil }
                && !m.readiness.designing && !m.designsInFlight
        }, "the scene, stacks and designs")
        XCTAssertEqual(m.squeezeGroups.map(\.regions), [[1], [4, 2], [3, 5]], "premise: his three groups")
        pump(0.3)
        return (r, m)
    }

    /// The Squish page on Group 2's tab, Face 4's card.
    func faceFour(_ m: FlexibleStageModel) throws {
        let g2 = try XCTUnwrap(m.squeezeGroups.first { $0.number == 2 })
        m.rail = .group(g2.id)
        m.select(4)
        m.tab = .face
    }

    // MARK: - RH1: the named chips on his pad

    func testTheFaceCardsNamedChipsAreDrawnOnHisPad() throws {
        var report: [String] = []
        for (tag, size) in Self.sizes {
            for control in [false, true] {
                FlexibleFaceGroupRow.controlMenuFallback = control
                let (r, m) = try hisPad()
                try faceFour(m)
                XCTAssertEqual(FlexibleFaceGroupRow.options(model: m, region: 4).map(\.label), ["Group 1", "Group 2", "Group 3", "+ New"],
                               "premise: three names and + New")
                let h = host(FlexibleStagePage(project: r.project, model: m, onExit: {}), size: size)
                pump(2.5)
                let chips = local(h, "groupChips"), menu = local(h, "groupMenu")
                let panel = local(h, "panel")
                report.append("\(tag)\(control ? " control" : ""): chips \(chips.map { "\($0)" } ?? "none") · menu \(menu.map { "\($0)" } ?? "none")")
                if control {
                    XCTAssertNotNil(menu, "control \(tag): F's one menu chip")
                    XCTAssertNil(chips, "control \(tag): no chips")
                } else {
                    snapshot(h, "R7R_\(tag)_face4_card_named_chips.png")
                    let c = try XCTUnwrap(chips, "★ \(tag): the named chips are drawn")
                    XCTAssertNil(menu, "★ \(tag): never the one-chip menu")
                    if let p = panel { XCTAssertTrue(p.insetBy(dx: -1, dy: -1).contains(c), "★ \(tag): the chips on the panel (\(c) in \(p))") }
                    XCTAssertGreaterThanOrEqual(c.height, 30, "\(tag): chips a finger can hit")
                }
                h.window.orderOut(nil)
            }
        }
        print("FLEX-R7R-H1 " + report.joined(separator: " | "))
    }

    // MARK: - RH2: F's new controls are 44 pt targets

    func testFsNewControlsAreFingerTargets() throws {
        var report: [String] = []
        for control in [false, true] {
            FlexibleTargets.controlSmall = control
            let (r, m) = try hisPad()
            try faceFour(m)
            let h = host(FlexibleStagePage(project: r.project, model: m, onExit: {}), size: Self.sizes[0].1)
            pump(2.5)
            var sizes: [String: CGSize] = [:]
            sizes["take-out"] = local(h, "faceRemove-4")?.size
            sizes["Reset all"] = local(h, "resetAll")?.size
            // the group trash's line (in the header's place), then Keep
            let g2 = try XCTUnwrap(m.squeezeGroups.first { $0.number == 2 })
            m.askDeleteGroup(g2.id)
            pump(1.0)
            sizes["Delete"] = local(h, "groupDeleteConfirm")?.size
            sizes["Keep"] = local(h, "groupDeleteKeep")?.size
            m.keepGroup()
            pump(1.0)
            // [Reset all] asks: its [Reset]
            if let b = local(h, "resetAll") {
                click(h, CGPoint(x: b.midX, y: b.midY))
                _ = pumpUntil(2) { self.local(h, "resetConfirm") != nil }
            }
            sizes["Reset"] = local(h, "resetConfirm")?.size
            report.append("\(control ? "control" : "now"): " + sizes.sorted { $0.key < $1.key }.map { "\($0.key) \(Int($0.value.width))x\(Int($0.value.height))" }.joined(separator: ", "))
            for name in ["take-out", "Reset all", "Reset", "Delete", "Keep"] {
                let s = try XCTUnwrap(sizes[name], "\(name) drawn")
                if control {
                    XCTAssertLessThan(min(s.width, s.height), 43.5, "control: F's \(name) under 44 pt")
                } else {
                    XCTAssertGreaterThanOrEqual(s.width, 43.5, "★ \(name) is at least 44 pt wide (\(s))")
                    XCTAssertGreaterThanOrEqual(s.height, 43.5, "★ \(name) is at least 44 pt tall (\(s))")
                }
            }
            h.window.orderOut(nil)
        }
        print("FLEX-R7R-H2 " + report.joined(separator: " | "))
    }

    // MARK: - RH3: with Bend on, the depth chip moves with the bend

    func testWithBendOnTheDepthChipIsDrawnWhereTheBentFacePutsIt() throws {
        var report: [String] = []
        for control in [false, true] {
            FlexibleBendPose.controlInsideStays = control
            let (r, m) = try hisPad()
            try faceFour(m)
            let h = host(FlexibleStagePage(project: r.project, model: m, onExit: {}), size: Self.sizes[0].1)
            m.views = [.heatOff]
            pump(3.0)
            let rest = try XCTUnwrap(h.frames.marks["depthChip-4"], "Face 4's depth chip at rest")
            m.views = [.bend, .heatOff]
            m.objectWillChange.send()
            pump(3.0)
            let bent = try XCTUnwrap(h.frames.marks["depthChip-4"], "Face 4's depth chip with Bend on")
            let moved = hypot(bent.midX - rest.midX, bent.midY - rest.midY)
            report.append("\(control ? "control" : "now"): rest \(rest.origin) · bent \(bent.origin) · \(String(format: "%.1f", moved)) pt")
            if control {
                XCTAssertLessThan(moved, 0.5, "control: the chip stays at rest")
            } else {
                snapshot(h, "R7R_13p_bend_on_chip_moves.png")
                XCTAssertGreaterThan(moved, 2, "★ with Bend on the depth chip moves with the bend (\(moved) pt)")
            }
            h.window.orderOut(nil)
        }
        print("FLEX-R7R-H3 " + report.joined(separator: " | "))
    }
}
#endif
