// FlexibleRound7D1ReviewHostedTests — round 7, the REVIEW of batch R7-D1 (2026-10-17), the hosted half (offscreen, never the
// app), on HIS pad (FlexiblePressFixtures.a1Project(3, self): Bottom anchors, Top carries 22 lb, Group C's Face 3 + Face 5
// face-prisms; his three squeeze groups), the lattice built the app's way.
//   P1  (the blocker) Play on and the Setup card or the Lattice card open: the squish player's drawn bar (and the line over
//       it) never touches the cube, the views row, the name row and capsule, or the open panel — at 13" and 11", portrait
//       and landscape. RED at 999c6025: in portrait the bar climbed under the cube (13" (526,174), 11" (427,176)).
//   L1  the one legend card and the open panel never overlap (RED at 999c6025: 13" landscape the card hid the key's ramp,
//       11" landscape the whole key).
//   FX  a blocker while the card is open: its 1–3 fixes are IN the card's Core row (the callout's own buttons — "Fix in
//       Squish ›" for a weight), and ① no longer shows a green "built" over a lattice the model has dropped. RED at
//       999c6025: an amber line and a "Show the fix" button (two taps), ① a green check.
//   RC  the chip column H24 stops drawing on the Flexible stage, MEASURED on his pad: on Topology the whole page draws it
//       (Quality, Minimize plastic, Plate up, Gravity, Design box, Paint — each chip's width published by #354's own reader);
//       on the Flexible stage none of it. (The review: D1's two "red controls" for the column compared hard-coded sets that
//       could never go red. This one is the column itself.)
#if canImport(AppKit) && canImport(MetalKit)
import XCTest
import SwiftUI
import AppKit
import MetalKit
import simd
import TopOptDesign
@testable import TopOptFlows
@testable import TopOptKit

private final class R7D1RHostWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

@MainActor
final class FlexibleRound7D1ReviewHostedTests: XCTestCase {
    final class Frames { var all: [String: CGRect] = [:]; var chips: [SettingsChipID: CGFloat] = [:]; var said: [String] = [] }
    struct Host { let window: NSWindow; let view: NSView; let size: CGSize; let frames: Frames }

    static let sizes: [(String, CGSize)] = [("13p", CGSize(width: 1032, height: 1376)), ("11p", CGSize(width: 834, height: 1194)),
                                            ("13l", CGSize(width: 1376, height: 1032)), ("11l", CGSize(width: 1194, height: 834))]

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
            .onPreferenceChange(SettingsChipWidthKey.self) { frames.chips = $0 }
            .onPreferenceChange(FlexibleSaidKey.self) { frames.said = $0 }
            .environment(\.colorScheme, .dark))
        let hv = NSHostingView(rootView: root)
        hv.frame = CGRect(origin: .zero, size: size)
        _ = NSApplication.shared
        let w = R7D1RHostWindow(contentRect: CGRect(x: -20000, y: -20000, width: size.width, height: size.height),
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
        pump(0.6)
    }

    // MARK: - P1 + L1 on his pad

    func testOnHisPadThePlayerAndTheLegendKeepClearOfAnOpenCard() throws {
        let s = FlexibleMainStage()
        s.reduceMotion = { true }
        let r = try FlexiblePressFixtures.a1Project(3, self)
        let m = s.model(for: r.project, materialsPath: FlexibleHisProject.materialsPath, stampsPath: FlexibleHisProject.stampsPath, persist: {})
        addTeardownBlock { @MainActor in await m.waitForIdle() }
        m.openScene()
        XCTAssertTrue(pumpUntil(180) {
            m.sceneState == .ready && m.loadedKeys.allSatisfy { m.stacks[$0] != nil && m.geometry[$0] != nil }
                && !m.readiness.designing && !m.designsInFlight
        }, "the scene, stacks and designs")
        m.generateLattice()
        XCTAssertTrue(pumpUntil(240) { (m.lattice != nil && !m.latticeBuilding) || m.latticeError != nil }, "the lattice")
        XCTAssertNil(m.latticeError)
        s.apply(r.project, owned: true, pageUp: false)
        XCTAssertTrue(pumpUntil(30) { s.channels?.dents != nil }, "premise: a drawn lattice with its dent")
        if !s.playOn { s.togglePlay() }
        XCTAssertTrue(s.playerShown, "premise: Play on, the bar shows")
        var lines: [String] = []
        let clearance = FlexibleChromeLayout.barClearance
        for (tag, size) in Self.sizes {
            s.chrome.foldAll()
            s.chromeGeometry.note(size)
            let page = ZStack {
                FlexibleMainPlayerSlot(main: s, bottomClearance: clearance, chipColumnWidth: 0)
                HStack(alignment: .bottom) {
                    Spacer()
                    FlexibleCornerPair(main: s, project: r.project, app: r.app, openSquish: {}, changeGravity: {})
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                .padding(PageChrome.edge)
            }
            let h = host(page, size: size)
            pump(1.5)
            for card in [FlexibleChromeState.Card.setup, .latticeCard] {
                s.chrome.show(card)
                pump(1.5)
                let key = card == .setup ? "setupTray" : "latticeCard"
                let panel = try XCTUnwrap(h.frames.all[key], "\(tag): the \(key) is drawn")
                let bar = try XCTUnwrap(h.frames.all["playerCapsule"], "\(tag) \(key): the player's bar is drawn")
                let drawn = [bar] + [h.frames.all["playerTopRow"]].compactMap { $0 }.filter { $0.width > 1 }
                let avoid: [(String, CGRect)] = [("the cube", FlexibleLegendPlacement.gizmoFrame(viewport: size)),
                                                 ("the views row", FlexibleMainViewToggles.rowFrame(viewport: size)),
                                                 ("the name row and the capsule", FlexibleChromeLayout.topLeftChrome(size)),
                                                 ("the open \(key)", panel)]
                for d in drawn {
                    for (what, k) in avoid {
                        XCTAssertFalse(d.intersects(k), "★ \(tag), Play on, \(key) open: the player \(d.integral) is clear of \(what) \(k.integral)")
                    }
                }
                let legend = s.legendCard(viewport: size, bottomClearance: clearance, chipColumnWidth: 0)?.frame
                if let legend {
                    XCTAssertFalse(panel.intersects(legend), "★ \(tag): the open \(key) \(panel.integral) leaves the legend \(legend.integral) whole")
                }
                lines.append("\(tag) \(key) \(panel.integral): bar \(bar.integral) · legend \(legend.map { "\($0.integral)" } ?? "none")")
            }
            s.chrome.foldAll()
            h.window.orderOut(nil)
        }
        // FX: a blocker with the card open (13" portrait): the callout's fixes in the card's Core row, ① not "built"
        let size = Self.sizes[0].1
        s.chromeGeometry.note(size)
        FlexibleSaid.recording = true
        defer { FlexibleSaid.recording = false }
        let pair = HStack(alignment: .bottom) { Spacer(); FlexibleCornerPair(main: s, project: r.project, app: r.app, openSquish: {}, changeGravity: {}) }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom).padding(PageChrome.edge)
        let h = host(pair, size: size)
        pump(1)
        let own = try XCTUnwrap(m.settings.loadedFaces.first { $0.weightFrom == nil }?.faceRegionID, "a face of his own weight")
        m.edit { st in guard var f = st.face(own) else { return }; f.weightKg = 0; st.setFace(f) }
        XCTAssertTrue(pumpUntil(10) { s.status.tone == .fix }, "premise: the weight blocks")
        s.chrome.show(.latticeCard)
        pump(1.5)
        XCTAssertNotNil(h.frames.all["latticeCard"], "the card is open")
        XCTAssertTrue(h.frames.said.contains(FlexibleBlockerCallout.squishTitle),
                      "★ the blocker's fix is IN the card (\"\(FlexibleBlockerCallout.squishTitle)\") — RED at D1: only \"Show the fix\" (\(h.frames.said))")
        XCTAssertFalse(h.frames.said.contains("Show the fix"), "★ one tap, not two")
        XCTAssertTrue(h.frames.said.contains(FlexibleLatticeCard.waitsForTheFix), "★ ① says the preview waits for the fix (not a green 'built')")
        lines.append("FX: card says \(h.frames.said)")
        print("FLEX-R7D1R-HOSTED-P1L1\n" + lines.joined(separator: "\n"))
    }

    // MARK: - RC: the chip column, measured on his pad

    func testTheChipColumnH24TakesOffIsTodaysColumnMeasuredOnHisPad() throws {
        let size = CGSize(width: 1032, height: 1376)
        let r = try FlexiblePressFixtures.a1Project(3, self)
        let h = host(WorkspacePlaceholder(model: r.app, project: r.project), size: size)
        pump(4)
        let topology = Set(h.frames.chips.keys)
        // ★ SYNC #354 (89af86dd) B3: Topology draws NO chip column any more — its settings are the Setup chip's rows
        // (`visibleSettingsChips` returns none on Topology). The old red control ("Topology draws today's column, measured")
        // is gone with it; what stays is #354's own claim: none drawn on Topology, and the Setup panel's rows carry Quality,
        // Plate, Gravity and Minimize plastic (one of his removals on the Flexible stage).
        XCTAssertTrue(topology.isEmpty, "★ SYNC #354 B3: Topology draws no chip column (\(topology.map { "\($0)" }.sorted()))")
        let setupRows = TopologySetupRow.visible(protectCount: 0, isStep: false, designBoxDrawn: false)
        XCTAssertTrue(Set(setupRows).isSuperset(of: [.quality, .plate, .gravity, .minimizePlastic]),
                      "★ SYNC #354 B3: Topology's Setup rows carry today's column (\(setupRows.map(\.rawValue)))")
        // the Flexible stage (Topology's top-right Lattice button)
        try FlexiblePressFixtures.enterLatticeStage(r.project, click: { click(h, $0) })   // ★ SYNC #354 (89af86dd): no forward buttons since B5 — the ● Topology menu's lattice row
        pump(4)
        if let st = FlexibleMainStage.lastMade { addTeardownBlock { @MainActor in await st.model?.waitForIdle() } }
        XCTAssertNotNil(h.frames.all["setupChip"], "premise: the Flexible stage (the corner pair is drawn)")
        XCTAssertEqual(h.frames.chips.count, 0, "★ H24: no chip of the column on the Flexible stage (\(h.frames.chips.keys.map { "\($0)" }.sorted()))")
        print("FLEX-R7D1R-RC Topology column \(topology.map { "\($0)" }.sorted()) · Flexible \(h.frames.chips.count) chips")
    }
}
#endif
