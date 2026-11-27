// FlexibleFreezeHostedTests — ★ notes30 FF1 (the Flexible page froze after a "This face" change; builder F1's finding of
// 11-26, the maintainer's yes: "move that work off the main thread"). On HIS pad (the check test's page: A1_0003 + his live
// lattice, Group C = Face 3 + Face 5), the whole page (WorkspacePlaceholder) at 13" landscape, in the APP's mode (the
// picture made on its worker — FlexiblePictureWorker.inline off):
//   * a tap on "Lattice" made WHILE a squish answer lands (the answers of Face 3 Off held back, released between the
//     mouse-down and the mouse-up) lands: Face 3 is Lattice again;
//   * and no Flexible main-thread phase (the gather, the commit, the H4' tints, applyFlexibleLattice) takes 100 ms or more
//     (Apple's guideline for a discrete interaction), in a Debug build.
// RED CONTROL `FlexiblePictureWorker.controlPictureOnMain` (today's path: the picture made on the main thread inside the
// refresh, every field's GPU texture made again on main): the landing's work runs inside the press — a phase of 100 ms or
// more, every run (whether the tap is lost is reported, not gated — it depends on how long the hold lasts).
#if canImport(AppKit) && canImport(MetalKit)
import XCTest
import SwiftUI
import AppKit
import TopOptDesign
@testable import TopOptFlows
@testable import TopOptKit

private final class FreezeWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

@MainActor
final class FlexibleFreezeHostedTests: XCTestCase {
    final class Frames { var all: [String: CGRect] = [:] }
    struct Host { let window: NSWindow; let view: NSView; let size: CGSize; let frames: Frames }

    func pump(_ s: Double) {
        let end = Date().addingTimeInterval(s)
        while Date() < end { _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.02)) }
    }
    func host<V: View>(_ v: V, size: CGSize) -> Host {
        let frames = Frames()
        let root = AnyView(v.onPreferenceChange(FlexibleKeepOutKey.self) { frames.all = $0 }.environment(\.colorScheme, .dark))
        let hv = NSHostingView(rootView: root)
        hv.frame = CGRect(origin: .zero, size: size)
        _ = NSApplication.shared
        let w = FreezeWindow(contentRect: CGRect(x: -20000, y: -20000, width: size.width, height: size.height),
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
    func send(_ h: Host, _ t: NSEvent.EventType, _ p: CGPoint) {
        let e = NSEvent.mouseEvent(with: t, location: NSPoint(x: p.x, y: h.size.height - p.y), modifierFlags: [],
                                   timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: h.window.windowNumber,
                                   context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        h.window.sendEvent(e)
    }
    func click(_ h: Host, _ p: CGPoint) {
        send(h, .leftMouseDown, p); pump(0.06)
        send(h, .leftMouseUp, p); pump(0.06)
        pump(0.8)
    }
    func frame(_ h: Host, _ key: String, _ what: String) throws -> CGRect {
        try XCTUnwrap(h.frames.all[key], "no frame '\(key)' for \(what)")
    }
    /// Until the lattice is built and no sim runs (a held answer counts as landed), at most `maxS`.
    func settle(_ s: FlexibleMainStage, _ maxS: Double = 240, held: () -> Int = { 0 }) {
        let end = Date().addingTimeInterval(maxS)
        while Date() < end {
            pump(0.5)
            guard let m = s.model else { continue }
            let pending = m.squish.filter { $0.value == .pending }.count
            if !m.latticeBuilding, m.lattice != nil, !m.latticeIsStale, m.squishSolver.isIdle, pending <= held() { break }
        }
        pump(1.5)
    }

    func testATapDuringALandingLands() throws {
        let labels = [LatticeSetupCopy.lattice, LatticeSetupCopy.noLattice, LatticeSetupCopy.off]
        let size = CGSize(width: 1376, height: 1032)
        let wasInline = FlexiblePictureWorker.inline
        addTeardownBlock { @MainActor in
            FlexiblePictureWorker.inline = wasInline
            FlexiblePictureWorker.controlPictureOnMain = false
            FlexibleMainPhases.recording = false
        }
        var report: [String] = []
        for mode in ["off the main thread", "RED control: the picture on the main thread"] {
            let red = mode.hasPrefix("RED")
            FlexiblePictureWorker.inline = false
            FlexiblePictureWorker.controlPictureOnMain = red
            // his pad on the Flexible page, Group C picked, Face 3 open
            Bundle.r7m1vSwap
            let r = try FlexiblePressFixtures.a1Project(3, self, facePrism: false)
            let p = r.project
            let c = try FlexibleR7M1Fixtures.hisLiveLattice(p)
            let h = host(WorkspacePlaceholder(model: r.app, project: p), size: size)
            pump(4)
            try FlexiblePressFixtures.enterLatticeStage(p, click: { click(h, $0) })
            pump(3)
            let s = try XCTUnwrap(FlexibleMainStage.lastMade, "\(mode): the page's stage")
            let m = try XCTUnwrap(s.model, "\(mode): its model")
            addTeardownBlock { @MainActor in await m.waitForIdle() }
            s.faceUI.toastSeconds = 120
            s.pickGroup(c, project: p)
            pump(1.2)
            let r3 = LatticeSelectableRef.face(group: c, face: 3)
            let row3 = try frame(h, "flexSetupFace-\(r3.key)", "\(mode): Face 3's row")
            click(h, CGPoint(x: row3.minX + 70, y: row3.midY))
            settle(s)

            // Face 3 Off: the lattice rebuilds; its sims' answers are HELD (they land only when released, mid-tap) — the hook
            // is wrapped the moment the new lattice's sims are scheduled (the model sets it then)
            var held: [() -> Void] = []
            var holding = true
            let gen0 = m.lattice?.generation
            let segOn = try frame(h, "flexSetupFaceRole-\(r3.key)", "\(mode): This face")
            send(h, .leftMouseDown, Self.segmentCentre(segOn, labels: labels, at: 2)); pump(0.06)
            send(h, .leftMouseUp, Self.segmentCentre(segOn, labels: labels, at: 2))
            let wait = Date().addingTimeInterval(240)
            while Date() < wait, !(m.lattice.map { $0.generation != gen0 && m.squishScheduled == $0.generation } ?? false) {
                _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01))
            }
            let deliver = m.squishSolver.onResult
            m.squishSolver.onResult = { g, e, id, st in
                if holding { held.append { deliver(g, e, id, st) } } else { deliver(g, e, id, st) }
            }
            XCTAssertNil(p.latticeSelectableRole(r3, in: c), "premise \(mode): Face 3 Off")
            settle(s, held: { held.count })
            XCTAssertFalse(held.isEmpty, "premise \(mode): a squish answer is held back")

            // ★ THE TAP: mouse-down on Lattice — the held answers land — 0.3 s — mouse-up
            let seg = try frame(h, "flexSetupFaceRole-\(r3.key)", "\(mode): This face, Off")
            let at = Self.segmentCentre(seg, labels: labels, at: 0)
            let commits0 = s.picturesCommitted
            FlexibleMainPhases.recording = true
            let t0 = Date()
            send(h, .leftMouseDown, at)
            pump(0.06)
            holding = false
            let answers = held.count
            for land in held { land() }
            held = []
            let t1 = Date()
            pump(0.3)
            let pumped = Date().timeIntervalSince(t1)
            send(h, .leftMouseUp, at)
            let pressed = Date().timeIntervalSince(t0)
            pump(0.06)
            let role = p.latticeSelectableRole(r3, in: c)
            // the landing's picture comes after (on the worker in the app's mode)
            let end = Date().addingTimeInterval(120)
            while Date() < end, s.picturesCommitted == commits0 { pump(0.2) }
            pump(1)
            let phases = FlexibleMainPhases.log
            FlexibleMainPhases.recording = false
            let longest = phases.max { $0.ms < $1.ms }
            var byName: [String: (n: Int, max: Double)] = [:]
            for e in phases { let o = byName[e.name] ?? (0, 0); byName[e.name] = (o.n + 1, Swift.max(o.max, e.ms)) }
            report.append(String(format: "%@: %d answer(s) landed mid-press; the press lasted %.2f s (the 0.3 s pump took %.2f s); role after mouse-up %@; pictures committed %d; longest Flexible main-thread phase %@ %.1f ms; phases %@",
                                 mode, answers, pressed, pumped, role.map { "\($0)" } ?? "nil (TAP LOST)", s.picturesCommitted - commits0,
                                 longest?.name ?? "-", longest?.ms ?? 0,
                                 byName.keys.sorted().map { String(format: "%@ ×%d max %.1f ms", $0, byName[$0]!.n, byName[$0]!.max) }.joined(separator: ", ")))
            if red {
                XCTAssertGreaterThanOrEqual(longest?.ms ?? 0, 100, "★ RED (\(mode)): the landing holds the main thread 100 ms or more")
            } else {
                XCTAssertEqual(role, .include, "★ \(mode): the tap made while the answer landed lands — Face 3 is Lattice")
                XCTAssertLessThan(longest?.ms ?? 0, 100, "★ \(mode): no Flexible main-thread phase of 100 ms or more (\(longest?.name ?? "-"))")
                XCTAssertGreaterThan(s.picturesCommitted, commits0, "\(mode): the landing's picture was committed")
            }
            settle(s)
        }
        for l in report { print("FF1 FREEZE \(l)") }
    }

    /// Where a click lands on one segment of a small SegmentedGlass (its words at 12 pt, 10 pt each side, 2 apart, 3 in).
    static func segmentCentre(_ f: CGRect, labels: [String], at i: Int) -> CGPoint {
        let font = NSFont.systemFont(ofSize: 12, weight: .medium)
        let w = labels.map { ($0 as NSString).size(withAttributes: [.font: font]).width + 20 }
        let x = f.minX + 3 + w.prefix(i).reduce(0, +) + CGFloat(i) * 2 + w[i] / 2
        return CGPoint(x: x, y: f.midY)
    }
}
#endif
