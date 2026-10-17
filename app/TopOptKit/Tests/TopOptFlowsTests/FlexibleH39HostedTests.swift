// FlexibleH39HostedTests — round 7, the H39 hotfix (2026-10-17), the hosted half (offscreen, never the app), on HIS pad
// (A1_0003, FlexiblePressFixtures.a1Project(3, self)) with the WHOLE app page hosted (WorkspacePlaceholder) at 13" portrait.
// Written BEFORE the code (the red run: round7/batch_h39/h39_red_run.txt).
//
// The reviewer's ruling 1 (2026-10-17 20:25, approved by the maintainer): "nothing on Flexible can set regionsOpen (today's
// carry-over pops the Regions panel on Topology — a leak; he uses this build now)". D1's handoff said it in his words: "The
// Regions icon (the dashed squares in the Selections header) is still on this stage. Tapping it only turns it blue. If you
// then go to Topology, its Regions panel opens there."
//
//   R1  a Flexible session, then Topology, never shows the Regions panel unless he opens it there:
//       * on Topology the toggle is drawn and opens the panel (the POSITIVE control: the probe sees the toggle and the panel);
//       * on the Flexible stage the toggle is NOT drawn (no ink where Topology draws it), and a tap where it was does nothing;
//       * back on Topology (the capsule's own menu, ‹ Topology) the Regions panel is NOT up;
//       * and he can still open it there himself.
//       RED CONTROL: today's carry-over — at the base commit the toggle is drawn on the Flexible stage, the tap sets it, and
//       the panel pops up on Topology (the red run).
//
// (A test process builds no accessibility tree for SwiftUI on macOS and #354's views publish no frames, so the toggle and
// the panel are found in the page's own pixels: the Selections card's top edge, the toggle's ink in its header, the panel's
// fill where #354 places it — 320 pt from the left, 96 pt above the bottom.)
#if canImport(AppKit) && canImport(MetalKit)
import XCTest
import SwiftUI
import AppKit
import TopOptDesign
@testable import TopOptFlows
@testable import TopOptKit

private final class H39HostWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

@MainActor
final class FlexibleH39HostedTests: XCTestCase {
    final class Frames { var all: [String: CGRect] = [:] }
    struct Host { let window: NSWindow; let view: NSView; let size: CGSize; let frames: Frames }
    /// The page's pixels (RGBA, top row first) at `scale` px per pt.
    struct Shot {
        let px: [UInt8]; let w: Int; let h: Int; let scale: CGFloat
        func at(_ x: CGFloat, _ y: CGFloat) -> (Int, Int, Int) {
            let i = (min(h - 1, max(0, Int(y * scale))) * w + min(w - 1, max(0, Int(x * scale)))) * 4
            return (Int(px[i]), Int(px[i + 1]), Int(px[i + 2]))
        }
        static func diff(_ a: (Int, Int, Int), _ b: (Int, Int, Int)) -> Int { max(abs(a.0 - b.0), abs(a.1 - b.1), abs(a.2 - b.2)) }
    }

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
        let w = H39HostWindow(contentRect: CGRect(x: -20000, y: -20000, width: size.width, height: size.height),
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
        pump(1.0)
    }
    func shot(_ h: Host) throws -> Shot {
        h.view.layoutSubtreeIfNeeded()
        let rep = try XCTUnwrap(h.view.bitmapImageRepForCachingDisplay(in: h.view.bounds))
        h.view.cacheDisplay(in: h.view.bounds, to: rep)
        let cg = try XCTUnwrap(rep.cgImage)
        var buf = [UInt8](repeating: 0, count: cg.width * cg.height * 4)
        let ctx = try XCTUnwrap(CGContext(data: &buf, width: cg.width, height: cg.height, bitsPerComponent: 8, bytesPerRow: cg.width * 4,
                                          space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
        return Shot(px: buf, w: cg.width, h: cg.height, scale: CGFloat(cg.width) / h.size.width)
    }

    /// Opt-in (FLEX_H39_DIR=<dir>): the page's pixels as a PNG (the evidence pictures).
    func write(_ s: Shot, _ name: String) throws {
        guard let dir = ProcessInfo.processInfo.environment["FLEX_H39_DIR"].map({ URL(fileURLWithPath: $0, isDirectory: true) }) else { return }
        var px = s.px
        let ctx = try XCTUnwrap(CGContext(data: &px, width: s.w, height: s.h, bitsPerComponent: 8, bytesPerRow: s.w * 4,
                                          space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let img = try XCTUnwrap(ctx.makeImage())
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)
        let dest = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(dest, img, nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
    }

    /// The page's ground (a pixel no chrome covers: the left edge, half way down).
    static func ground(_ s: Shot, _ size: CGSize) -> (Int, Int, Int) { s.at(4, size.height * 0.55) }

    /// The Selections card's top edge: the first pixel off the ground down the column x = 150 pt (right of "Selections",
    /// left of the header's icons), below the name row and the capsule.
    static func cardTop(_ s: Shot, _ size: CGSize) -> CGFloat? {
        let g = ground(s, size)
        var y: CGFloat = 130
        while y < size.height - 120 {
            if Shot.diff(s.at(150, y), g) > 6 { return y }
            y += 0.5
        }
        return nil
    }

    /// The Regions toggle's ink in the card's header: x 156…196 pt (between "Selections" and the Keep clear pill), the header's
    /// middle ± 12 pt. Returns the ink's centre, or nil when nothing is drawn there.
    static func toggleInk(_ s: Shot, top: CGFloat) -> CGPoint? {
        let fill = s.at(150, top + 20)
        var xs: [CGFloat] = [], ys: [CGFloat] = []
        var y = top + 19
        while y <= top + 43 {
            var x: CGFloat = 156
            while x <= 196 {
                if Shot.diff(s.at(x, y), fill) > 25 { xs.append(x); ys.append(y) }
                x += 0.5
            }
            y += 0.5
        }
        guard xs.count >= 8 else { return nil }
        return CGPoint(x: (xs.min()! + xs.max()!) / 2, y: (ys.min()! + ys.max()!) / 2)
    }

    /// The toggle's picture as Topology draws it: 22 × 22 pt around its ink, one sample per pt.
    static func patch(_ s: Shot, at c: CGPoint) -> [(Int, Int, Int)] {
        var out: [(Int, Int, Int)] = []
        for dy in -11...10 { for dx in -11...10 { out.append(s.at(c.x + CGFloat(dx), c.y + CGFloat(dy))) } }
        return out
    }
    /// Where `tpl` best matches inside the band (centres every 1 pt), and its mean difference there (0 = the same picture).
    static func find(_ tpl: [(Int, Int, Int)], in s: Shot, x: ClosedRange<CGFloat>, y: ClosedRange<CGFloat>) -> (at: CGPoint, diff: Double) {
        var best = (at: CGPoint.zero, diff: Double.infinity)
        var cy = y.lowerBound
        while cy <= y.upperBound {
            var cx = x.lowerBound
            while cx <= x.upperBound {
                var sum = 0, i = 0
                for dy in -11...10 { for dx in -11...10 {
                    sum += Shot.diff(s.at(cx + CGFloat(dx), cy + CGFloat(dy)), tpl[i]); i += 1
                } }
                let d = Double(sum) / Double(tpl.count)
                if d < best.diff { best = (CGPoint(x: cx, y: cy), d) }
                cx += 1
            }
            cy += 1
        }
        return best
    }

    /// The share of #354's Regions panel's place that is off the ground: the panel's foot (320 pt from the left, 96 pt above
    /// the bottom, 360 wide) — x 326…674, the 110 pt above its foot.
    static func panelCover(_ s: Shot, _ size: CGSize) -> Double {
        let g = ground(s, size)
        var on = 0, all = 0
        var y = size.height - 96 - 112
        while y <= size.height - 96 - 4 {
            var x: CGFloat = 326
            while x <= 674 {
                all += 1
                if Shot.diff(s.at(x, y), g) > 6 { on += 1 }
                x += 2
            }
            y += 2
        }
        return Double(on) / Double(max(1, all))
    }

    /// The capsule's ● Flexible menu, ‹ Topology picked (the native menu, driven while it tracks).
    func pickTopologyFromTheCapsule(_ h: Host) throws {
        let menu = try XCTUnwrap(h.frames.all["capsuleMenu"], "the capsule's menu (the Flexible stage)")
        let obs = NotificationCenter.default.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: nil) { n in
            guard let m = n.object as? NSMenu else { return }
            RunLoop.main.perform(inModes: [.eventTracking, .default, .modalPanel]) {
                guard let i = m.items.firstIndex(where: { $0.title.contains("Topology") }) else { m.cancelTracking(); return }
                m.cancelTracking()
                m.performActionForItem(at: i)
            }
        }
        defer { NotificationCenter.default.removeObserver(obs) }
        click(h, CGPoint(x: menu.midX, y: menu.midY))
        pump(2)
    }

    // MARK: - R1

    func testAFlexibleSessionThenTopologyNeverShowsTheRegionsPanelUnlessHeOpensItThere() throws {
        let size = CGSize(width: 1032, height: 1376)
        let r = try FlexiblePressFixtures.a1Project(3, self)
        let h = host(WorkspacePlaceholder(model: r.app, project: r.project), size: size)
        pump(4)
        var log: [String] = []

        // ── Topology: the toggle is drawn; it opens the panel (POSITIVE control), and closes it again
        let t0 = try shot(h)
        let topT = try XCTUnwrap(Self.cardTop(t0, size), "Topology: the Selections card")
        let ink = try XCTUnwrap(Self.toggleInk(t0, top: topT), "★ POSITIVE CONTROL: Topology draws the Regions toggle in the Selections header")
        let base = Self.panelCover(t0, size)
        XCTAssertLessThan(base, 0.1, "Topology at open: no Regions panel (\(base))")
        try write(t0, "H39_R1_1_topology_at_open.png")
        click(h, ink)
        let openedShot = try shot(h)
        try write(openedShot, "H39_R1_2_topology_his_tap_opens_regions.png")
        let opened = Self.panelCover(openedShot, size)
        XCTAssertGreaterThan(opened, 0.6, "★ POSITIVE CONTROL: on Topology the toggle opens #354's Regions panel and the probe sees it (\(opened))")
        click(h, ink)
        let closed = Self.panelCover(try shot(h), size)
        XCTAssertLessThan(closed, 0.1, "Topology: a second tap closes it (\(closed))")
        log.append("Topology: card top \(topT) · toggle at \(ink) · panel cover open \(opened) / closed \(closed)")

        // ── the Flexible stage (Topology's top-right Lattice button)
        click(h, CGPoint(x: size.width - PageChrome.gizmoClearance - 62, y: PageChrome.gizmoAlignedTop + PageChrome.compactButton / 2))
        pump(3)
        if let s = FlexibleMainStage.lastMade { addTeardownBlock { @MainActor in await s.model?.waitForIdle() } }
        XCTAssertNotNil(h.frames.all["capsule"], "premise: the Flexible stage (its capsule)")
        let f0 = try shot(h)
        try write(f0, "H39_R1_3_flexible_no_regions_toggle.png")
        let topF = try XCTUnwrap(Self.cardTop(f0, size), "the Flexible stage: the Selections card (still #354's until D2)")
        // the toggle's own picture, searched for along the Flexible card's header (the Keep clear pill may take its room: with the
        // toggle gone the pill's words fit on one line — the red run's first check, "no ink between Selections and the pill",
        // saw the wider pill; corrected after the code, said in the handoff)
        let at = CGPoint(x: ink.x.rounded(), y: ink.y.rounded())   // whole points: the search's own grid
        let tpl = Self.patch(t0, at: at)
        let selfMatch = Self.find(tpl, in: t0, x: 140...330, y: (topT + 15).rounded()...(topT + 50).rounded())
        XCTAssertLessThan(selfMatch.diff, 1, "★ POSITIVE CONTROL: the matcher finds the toggle on Topology (\(selfMatch))")
        let onFlexible = Self.find(tpl, in: f0, x: 140...330, y: (topF + 15).rounded()...(topF + 50).rounded())
        let drawn = onFlexible.diff < 8
        XCTAssertFalse(drawn, "★ H39: the Flexible stage draws no Regions toggle in the Selections header (best match \(onFlexible))")
        // ★ today's carry-over (the red run): where the toggle IS drawn on the Flexible stage, he taps it
        if drawn { click(h, onFlexible.at) }
        log.append("Flexible: card top \(topF) · the toggle's best match \(onFlexible.at) diff \(String(format: "%.1f", onFlexible.diff)) (Topology's own \(String(format: "%.1f", selfMatch.diff))) · tapped \(drawn)")

        // ── back to Topology through the capsule's own menu: no Regions panel
        try pickTopologyFromTheCapsule(h)
        XCTAssertNil(h.frames.all["capsule"], "premise: back on Topology (no capsule)")
        let t1 = try shot(h)
        try write(t1, "H39_R1_4_topology_after_flexible_no_panel.png")
        let carried = Self.panelCover(t1, size)
        XCTAssertLessThan(carried, 0.1, "★ after a Flexible session Topology shows no Regions panel he did not open there (cover \(carried))")
        // …and he can still open it there himself
        let topT1 = try XCTUnwrap(Self.cardTop(t1, size), "Topology again: the Selections card")
        let ink1 = try XCTUnwrap(Self.toggleInk(t1, top: topT1), "Topology again: the toggle is drawn")
        click(h, ink1)
        let mine = Self.panelCover(try shot(h), size)
        XCTAssertGreaterThan(mine, 0.6, "★ on Topology his own tap still opens the Regions panel (\(mine))")
        click(h, ink1)
        log.append("Topology again: carried cover \(carried) · his own tap \(mine)")
        print("FLEX-H39-HOSTED-R1 " + log.joined(separator: " | "))
        h.window.orderOut(nil)
    }
}
#endif
