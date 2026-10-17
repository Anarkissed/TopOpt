// FlexibleRound7ViewsHostedTests — round 7, batch R7-V (2026-10-14), the hosted half (offscreen, never the app): the
// views on both pages, on HIS pad (A1_0003 as he saved it), at 11" and 13" in both orientations. Written BEFORE the code;
// each with its RED control run inside the test. His words are in FlexibleRound7ViewsTests' header.
//   H1 no worded control in any view row (the two toggles gone) — the row is icons only; one legend card on each page.
//   H2 the play bar only with Play, on both pages (one shared view), clear of every keep-out.
//   H3 the Settings page's own loop keeps his pause across an edit and a rebuilt lattice.
//   H4 Settings' Heat icon: a tap cycles group → off → group; a 3 s hold shows every group's, and its release tap does
//      not undo it.
//   H5 Bend alone shows only the bent model (no curve, chip or tag); Bend with Heat brings them back.
//   H6 X-ray off with the Covered finish is the plain model: the lattice adds no pixel (the shipping renderer).
// FLEX_R7V_EVIDENCE_DIR=<dir> also writes the hosted pages.
#if canImport(AppKit) && canImport(MetalKit)
import XCTest
import SwiftUI
import AppKit
import Combine
import MetalKit
import simd
import TopOptDesign
@testable import TopOptFlows
@testable import TopOptKit

private final class R7VHostWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

@MainActor
final class FlexibleRound7ViewsHostedTests: XCTestCase {

    final class Frames { var all: [String: CGRect] = [:] }
    struct Host { let window: NSWindow; let view: NSView; let size: CGSize; let frames: Frames }

    static var dir: URL? { ProcessInfo.processInfo.environment["FLEX_R7V_EVIDENCE_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) } }
    static let sizes: [(String, CGSize)] = FlexibleGroupPaletteHostedTests.sizes
    static var his13p: (String, CGSize) { sizes.first { $0.0 == "13p" }! }
    static var his11l: (String, CGSize) { sizes.first { $0.0 == "11l" }! }

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
        let w = R7VHostWindow(contentRect: CGRect(x: -20000, y: -20000, width: size.width, height: size.height),
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
            print("FLEX-R7V wrote \(dir.appendingPathComponent(name).path)")
        }
    }

    /// A press at `p` (the page's points, y down) held `seconds`, then released, through the window.
    func press(_ h: Host, _ p: CGPoint, hold seconds: Double = 0) {
        let loc = NSPoint(x: p.x, y: h.size.height - p.y)
        func send(_ t: NSEvent.EventType) {
            let e = NSEvent.mouseEvent(with: t, location: loc, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                       windowNumber: h.window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
            h.window.sendEvent(e)
        }
        send(.leftMouseDown)
        pump(max(0.06, seconds))
        send(.leftMouseUp)
        pump(0.15)
    }

    struct Shot { let w: Int; let h: Int; let scale: CGFloat; let px: [UInt8] }
    func shot(_ h: Host) throws -> Shot {
        h.view.layoutSubtreeIfNeeded()
        let rep = try XCTUnwrap(h.view.bitmapImageRepForCachingDisplay(in: h.view.bounds))
        h.view.cacheDisplay(in: h.view.bounds, to: rep)
        let cg = try XCTUnwrap(rep.cgImage)
        let w = cg.width, hh = cg.height
        var buf = [UInt8](repeating: 0, count: w * hh * 4)
        let ctx = try XCTUnwrap(CGContext(data: &buf, width: w, height: hh, bitsPerComponent: 8, bytesPerRow: w * 4,
                                          space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: hh))
        return Shot(w: w, h: hh, scale: CGFloat(w) / h.view.bounds.width, px: buf)
    }
    /// Pixels inside `r` but outside every rect of `holes` that are drawn (alpha > 0 and not the clear ground).
    static func drawn(_ a: Shot, in r: CGRect, outside holes: [CGRect]) -> Int {
        let x0 = max(0, Int((r.minX * a.scale).rounded(.up))), x1 = min(a.w, Int((r.maxX * a.scale).rounded(.down)))
        let y0 = max(0, Int((r.minY * a.scale).rounded(.up))), y1 = min(a.h, Int((r.maxY * a.scale).rounded(.down)))
        guard x0 < x1, y0 < y1 else { return 0 }
        var n = 0
        for y in y0..<y1 {
            for x in x0..<x1 {
                let i = (y * a.w + x) * 4
                guard a.px[i + 3] > 8 else { continue }
                let p = CGPoint(x: (CGFloat(x) + 0.5) / a.scale, y: (CGFloat(y) + 0.5) / a.scale)
                if !holes.contains(where: { $0.contains(p) }) { n += 1 }
            }
        }
        return n
    }
    static func differing(_ a: Shot, _ b: Shot, threshold t: Int = 12) -> Int {
        guard a.w == b.w, a.h == b.h else { return -1 }
        var n = 0
        for i in stride(from: 0, to: a.px.count, by: 4) {
            let d = max(abs(Int(a.px[i]) - Int(b.px[i])), abs(Int(a.px[i + 1]) - Int(b.px[i + 1])), abs(Int(a.px[i + 2]) - Int(b.px[i + 2])))
            if d > t { n += 1 }
        }
        return n
    }

    /// A model over HIS pad, the scene, stacks and designs settled (the main stage's own).
    func hisPad(_ given: FlexibleMainStage? = nil) throws -> (FlexibleHisProject.Restored, FlexibleStageModel) {
        let stage = given ?? FlexibleMainStage()
        let r = try FlexiblePressFixtures.a1Project(3, self)
        stage.reduceMotion = { true }
        let m = stage.model(for: r.project, materialsPath: FlexibleHisProject.materialsPath, stampsPath: FlexibleHisProject.stampsPath, persist: {})
        addTeardownBlock { @MainActor in await m.waitForIdle() }
        m.openScene()
        XCTAssertTrue(pumpUntil(180) {
            m.sceneState == .ready && m.loadedKeys.allSatisfy { m.stacks[$0] != nil && m.geometry[$0] != nil }
                && !m.readiness.designing && !m.designsInFlight
        }, "the scene, stacks and designs")
        pump(0.3)
        return (r, m)
    }

    /// The model's lattice built (the Settings page draws none; its sims' fields are the 3D squish).
    func build(_ m: FlexibleStageModel) {
        m.generateLattice()
        XCTAssertTrue(pumpUntil(240) { (m.lattice != nil && !m.latticeBuilding) || m.latticeError != nil }, "the lattice")
        XCTAssertNil(m.latticeError)
    }

    // MARK: - H1: icons only, one legend card

    /// A row of the main page's view buttons with a worded chip beside it — the RED control of the scan (what batch V's
    /// "Role colours off" chip put in the row).
    struct WordedRow: View {
        let main: FlexibleMainStage
        static func underRow(_ v: CGSize) -> Bool {
            FlexibleMainViewToggles.noteFrame(viewport: v).minY >= FlexibleMainViewToggles.rowFrame(viewport: v).maxY
        }
        var body: some View {
            ZStack(alignment: .topTrailing) {
                FlexibleMainViewToggles(main: main, openSettings: {})
                GeometryReader { g in
                    let row = FlexibleMainViewToggles.rowFrame(viewport: g.size)
                    Button {} label: {
                        Text("Role colours off").font(.system(size: 12, weight: .semibold)).foregroundStyle(.white)
                            .padding(.horizontal, 12).frame(height: 40).background(Capsule().fill(DS.Surface.bar.color))
                    }
                    .buttonStyle(.plain)
                    // ★ RE-PINNED (round 7, R7-D1): the control chip goes where the note's band is NOT — under the row, or,
                    // where the note now sits under the row (11" portrait: one line of six 44 pt icons), left of it
                    .position(x: Self.underRow(g.size) ? row.minX - DS.Space.s - 75 : row.maxX - 75,
                              y: Self.underRow(g.size) ? row.midY : row.maxY + DS.Space.s + 20)
                }
            }
        }
    }

    func testEveryViewRowIsIconsOnlyAndEachPageHasOneLegendCard() throws {
        let s = FlexibleMainStage()
        let (r, m) = try hisPad(s)
        s.apply(r.project, owned: true, pageUp: false)
        // every view on
        s.heat = false; s.stress = true; s.latticeOn = true; s.xrayOn = true
        m.views = [.prisms, .play]
        s.refresh()
        // no worded toggle anywhere in the sources
        let flows = FlexibleSource.url("FlexibleMainStage.swift").deletingLastPathComponent()
        for f in try FileManager.default.contentsOfDirectory(atPath: flows.path) where f.hasSuffix(".swift") {
            let code = try FlexibleSource.code(f)
            XCTAssertFalse(code.contains("FlexibleMainViewSettingChip"), "★ \(f): the worded chip is gone")
            XCTAssertFalse(code.contains("mainRoleColoursOff") || code.contains("mainPrismAfterPick"), "★ \(f): its words are gone")
        }
        // the rows build only icon buttons: no Text in their bodies, nor in FlexibleViewButton's
        let pill = try FlexibleSource.code("FlexibleMainStatusPill.swift")
        let rowBody = try XCTUnwrap(pill.range(of: "struct FlexibleMainViewToggles")).upperBound
        let rowEnd = try XCTUnwrap(pill.range(of: "static func frame(viewport: CGSize)", range: rowBody..<pill.endIndex)).lowerBound
        XCTAssertFalse(pill[rowBody..<rowEnd].contains("Text("), "★ the main page's row draws no words")
        let controls = try FlexibleSource.code("FlexibleViewControls.swift")
        let button = try XCTUnwrap(controls.range(of: "struct FlexibleViewButton")).upperBound
        XCTAssertFalse(controls[button...].contains("Text("), "★ a view button is an icon, never a word")
        let views = try FlexibleSource.code("FlexibleStageViews.swift")
        let sb = try XCTUnwrap(views.range(of: "struct FlexibleStageViewButtons")).upperBound
        let se = try XCTUnwrap(views.range(of: "enum FlexibleLegendViewRows")).lowerBound
        XCTAssertFalse(views[sb..<se].contains("Text("), "★ the Settings row draws no words")
        // hosted: nothing is drawn in the band under the gizmo but the icon buttons (and the note's band, empty here)
        var lines: [String] = []
        for (tag, size) in Self.sizes {
            let h = host(FlexibleMainViewToggles(main: s, openSettings: {}), size: size)
            pump(0.4)
            XCTAssertNil(h.frames.all["mainSetting-roleColoursOff"], "★ \(tag): no 'Role colours off'")
            XCTAssertNil(h.frames.all["mainSetting-prismAfterPick"], "★ \(tag): no 'Prism after a pick'")
            let row = FlexibleMainViewToggles.rowFrame(viewport: size), note = FlexibleMainViewToggles.noteFrame(viewport: size)
            let band = CGRect(x: FlexibleMainLegendLayout.leftStrip(viewport: size).maxX, y: PageChrome.belowGizmo - 4,
                              width: size.width - FlexibleMainLegendLayout.leftStrip(viewport: size).maxX, height: row.height + 140)
            let extra = Self.drawn(try shot(h), in: band, outside: [row.insetBy(dx: -2, dy: -2), note])
            XCTAssertEqual(extra, 0, "★ \(tag): nothing but the icon row under the gizmo (\(extra) px)")
            // ★ RED CONTROL: a worded chip beside the row is found by the same scan
            let hw = host(WordedRow(main: s), size: size)
            pump(0.4)
            let worded = Self.drawn(try shot(hw), in: band, outside: [row.insetBy(dx: -2, dy: -2), note])
            XCTAssertGreaterThan(worded, 200, "★ RED CONTROL (\(tag)): a worded chip in the row is found")
            lines.append("\(tag) row \(row.integral) · extra px \(extra) (control \(worded))")
            snapshot(h, "R7V_\(tag)_main_icon_row_every_view.png")
        }
        // ONE legend card on each page: the main page's every scale rides one card; the Settings page builds one
        let v = Self.his13p.1
        let card = try XCTUnwrap(s.legendCard(viewport: v, bottomClearance: 94, chipColumnWidth: 222))
        XCTAssertTrue(s.legendFrames(viewport: v, bottomClearance: 94, chipColumnWidth: 222).values.allSatisfy { $0.frame == card.frame },
                      "★ the main page: every legend in the ONE card")
        let legends = try FlexibleSource.code("FlexibleMainLegends.swift")
        XCTAssertEqual(legends.components(separatedBy: "\"flexible-legend-card\"").count - 1, 1, "one card on the main page")
        let page = try FlexibleSource.code("FlexibleStagePage.swift")
        XCTAssertEqual(page.components(separatedBy: "FlexibleLegend(model:").count - 1, 1, "one card on the Settings page")
        m.views = [.prisms, .groups, .play, .heatAll, .bend]
        let hp = host(FlexibleStagePage(project: r.project, model: m, onExit: {}), size: v)
        pump(2.5)
        let legend = try XCTUnwrap(local(hp, "legend"), "the Settings card")
        for row in ["legendPrismsRow", "legendGroupsRow"] {
            let f = try XCTUnwrap(local(hp, row))
            XCTAssertTrue(legend.insetBy(dx: -1, dy: -1).contains(f), "\(row) in the one card")
        }
        let buttons = try XCTUnwrap(local(hp, "viewButtons"))
        XCTAssertEqual(buttons.width, FlexibleStageViews.frame(viewport: v).width, accuracy: 1, "the Settings row: \(FlexibleStageViews.buttons.count) icons")
        snapshot(hp, "R7V_13p_settings_every_view.png")
        m.views = []
        print("FLEX-R7V-H1 " + lines.joined(separator: " · ") + " · Settings row \(buttons.integral) of \(FlexibleStageViews.buttons.map(\.label))")
    }

    // MARK: - H2: the bar only with Play, both pages

    func testThePlayBarComesOnlyWithPlayOnBothPages() throws {
        let s = FlexibleMainStage()
        let (r, m) = try hisPad(s)
        build(m)
        s.apply(r.project, owned: true, pageUp: false)
        XCTAssertTrue(pumpUntil(30) { s.channels?.dents != nil }, "premise: a drawn lattice with its dent")
        XCTAssertTrue(FlexibleStageViews.buttons.contains { $0.view == .play }, "★ Settings has its Play icon")
        var lines: [String] = []
        for (tag, size) in [Self.his13p, Self.his11l] {
            // the main page's slot
            m.views = []
            s.refresh()
            let hm = host(FlexibleMainPlayerSlot(main: s, bottomClearance: 94, chipColumnWidth: 222), size: size)
            pump(0.5)
            XCTAssertNil(hm.frames.all["playerCapsule"], "★ \(tag), main page, Play off: no bar")
            s.togglePlay()
            pump(0.5)
            let cap = try XCTUnwrap(hm.frames.all["playerCapsule"], "★ \(tag), main page, Play on: the bar")
            let card = s.legendCard(viewport: size, bottomClearance: 94, chipColumnWidth: 222).map { [$0.frame] } ?? []
            for k in FlexibleMainPlayerSlot.keepOut(viewport: size, bottomClearance: 94, chipColumnWidth: 222, legends: card) {
                XCTAssertFalse(cap.intersects(k.insetBy(dx: 1, dy: 1)), "\(tag): the bar clear of \(k.integral)")
            }
            // the Settings page, the SAME model: Play on there too
            XCTAssertTrue(m.views.contains(.play), "the views are shared")
            let hs = host(FlexibleStagePage(project: r.project, model: m, onExit: {}), size: size)
            pump(2.5)
            let player = try XCTUnwrap(local(hs, "player"), "★ \(tag), Settings, Play on (from the main page): the bar")
            for k in FlexibleStagePage.playerKeepOut(hs.frames.all) {
                XCTAssertFalse(player.intersects(k.insetBy(dx: 1, dy: 1)), "\(tag): the Settings bar clear of \(k.integral)")
            }
            snapshot(hs, "R7V_\(tag)_settings_play_on.png")
            // Play off on Settings: the bar leaves both pages
            m.views.remove(.play)
            pump(1.0)
            XCTAssertNil(local(hs, "player"), "★ \(tag), Settings, Play off: no bar")
            XCTAssertFalse(s.playerShown, "★ …and none on the main page")
            snapshot(hs, "R7V_\(tag)_settings_play_off.png")
            lines.append("\(tag): main bar \(cap.integral) · Settings bar \(player.integral)")
        }
        print("FLEX-R7V-H2 " + lines.joined(separator: " · "))
    }

    // MARK: - H3: the Settings page's own loop keeps his pause

    func testTheSettingsPagesLoopKeepsHisPauseAcrossAnEditAndARebuild() throws {
        func run(control: Bool) throws -> (played: Int, playedBeforePause: Bool) {
            let (r, m) = try hisPad()
            build(m)
            let loop = FlexibleSquishLoop()
            loop.controlIgnoreHisPause = control
            m.views = [.play]
            m.select(1)
            let h = host(FlexibleStagePage(project: r.project, model: m, loop: loop, onExit: {}), size: Self.his13p.1)
            _ = h
            let playedBefore = pumpUntil(10) { loop.playing }
            loop.toggle()   // ★ his ❚❚
            var played = 0
            let watch = loop.$playing.sink { if $0 { played += 1 } }
            defer { watch.cancel() }
            // an edit (the deepest squish) → stale; a rebuilt lattice → a new freshKey; a group switch
            let f = try XCTUnwrap(m.settings.face(1))
            m.edit { s in var g = f; g.deepestMM = f.deepestMM + 1; s.setFace(g) }
            pump(1.0)
            build(m)
            pump(1.5)
            m.rail = .group(m.squeezeGroups[1].id); m.select(4)
            pump(1.0)
            return (played, playedBefore)
        }
        let fixed = try run(control: false)
        XCTAssertTrue(fixed.playedBeforePause, "premise: Play on — the Settings squish played")
        XCTAssertEqual(fixed.played, 0, "★ his pause held across the edit, the rebuilt lattice and a group switch")
        let red = try run(control: true)
        XCTAssertGreaterThan(red.played, 0, "★ RED CONTROL: the page's automatic starts over his pause")
        print("FLEX-R7V-H3 Settings: plays while paused \(fixed.played) (control \(red.played))")
    }

    // MARK: - H4: Heat — tap cycles, a 3 s hold shows every group's

    func testTheHeatIconTapCyclesAndAThreeSecondHoldShowsEveryGroup() throws {
        addTeardownBlock { @MainActor in FlexibleViewButton.controlNoSwallow = false }
        let (_, m) = try hisPad()
        let size = Self.his13p.1
        func heatPoint() throws -> CGPoint {
            let i = try XCTUnwrap(FlexibleStageViews.buttons.firstIndex { $0.view == .heatOff }, "★ the Heat icon on Settings")
            let f = FlexibleStageViews.frame(viewport: size)
            return CGPoint(x: f.minX + CGFloat(i) * (FlexibleStageViews.buttonSize + DS.Space.s) + FlexibleStageViews.buttonSize / 2, y: f.midY)
        }
        let h = host(FlexibleStageViewButtons(model: m), size: size)
        pump(0.4)
        let p = try heatPoint()
        // ★ RE-PINNED (round 7 batch F, his answer 12: "The curve should be viewed as nothing but the curve without any view
        // turned on. Turning heat map on shows colour."): the page opens with the heat OFF
        XCTAssertEqual(m.views.heatScope, .off, "★ F: the page opens with no colour")
        press(h, p)
        XCTAssertEqual(m.views.heatScope, .group, "★ a tap shows the current group's")
        press(h, p)
        XCTAssertEqual(m.views.heatScope, .off, "★ a tap hides it")
        press(h, p, hold: 3.4)
        pump(0.4)
        XCTAssertEqual(m.views.heatScope, .all, "★ a 3 s hold: every group's — and its release tap did not undo it")
        snapshot(h, "R7V_13p_settings_heat_all_buttons.png")
        // ★ RED CONTROL: the release tap NOT swallowed — it undoes the hold
        m.views = []
        FlexibleViewButton.controlNoSwallow = true
        press(h, p, hold: 3.4)
        pump(0.4)
        let control = m.views.heatScope
        FlexibleViewButton.controlNoSwallow = false
        XCTAssertNotEqual(control, .all, "★ RED CONTROL: the release tap undid the hold")
        m.views = []
        print("FLEX-R7V-H4 heat: tap off → tap group → hold all · control (release not swallowed): \(control)")
    }

    // MARK: - H5: Bend alone — ★ RE-PINNED (round 7 batch F, his answer: "If bend is on, all views move to the furthest bend.
    // Always."): what is drawn on the part STAYS under Bend, at the full bend (R7-V hid it: `controlBendRestPose`)

    func testBendAloneKeepsWhatIsDrawnOnThePartAtTheFullBend() throws {
        addTeardownBlock { @MainActor in FlexibleStagePage.controlNoOverlays = false; FlexibleStagePage.controlBendRestPose = false }
        let (r, m) = try hisPad()
        m.rail = .group(m.squeezeGroups[0].id)
        m.select(1)
        let h = host(FlexibleStagePage(project: r.project, model: m, onExit: {}), size: Self.his13p.1)
        pump(2.5)
        /// Pixels the layer drawn on the part (curves, chips, handle, tags) changes on the page.
        func overlayPixels() throws -> Int {
            FlexibleStagePage.controlNoOverlays = false
            m.objectWillChange.send(); pump(1.0)
            let a = try shot(h)
            FlexibleStagePage.controlNoOverlays = true
            m.objectWillChange.send(); pump(1.0)
            let b = try shot(h)
            FlexibleStagePage.controlNoOverlays = false
            m.objectWillChange.send(); pump(0.4)
            return Self.differing(a, b)
        }
        m.views = [.heatOff]
        let editing = try overlayPixels()
        XCTAssertGreaterThan(editing, 200, "premise: Face 1's curves and chip are drawn on the part")
        m.views = [.bend, .heatOff]
        XCTAssertFalse(FlexibleStagePage.overlaysHidden(views: m.views, edgePick: false), "★ F: Bend alone keeps the overlays")
        XCTAssertTrue(FlexibleStagePage.posesOverlays(views: m.views), "★ F: …at the full bend")
        let alone = try overlayPixels()
        snapshot(h, "R7V_13p_settings_bend_alone.png")

        XCTAssertGreaterThan(alone, 200, "★ F: Bend alone: the curves and chip on the bent model (\(alone) px)")
        m.views = [.bend]
        let withHeat = try overlayPixels()
        XCTAssertGreaterThan(withHeat, 200, "★ Bend with Heat: the curves and chips")
        snapshot(h, "R7V_13p_settings_bend_heat.png")
        // ★ F: what is drawn on the part is drawn where the BENT part puts it — the page at the full bend against the same page
        // with the overlays at the rest pose (R7-V's `controlBendRestPose`; the body and the heat are the same in both)
        m.objectWillChange.send(); pump(1.0)
        let posedShot = try shot(h)
        FlexibleStagePage.controlBendRestPose = true
        m.objectWillChange.send(); pump(1.0)
        let restShot = try shot(h)
        FlexibleStagePage.controlBendRestPose = false
        m.objectWillChange.send(); pump(1.0)
        let moved = Self.differing(posedShot, restShot)
        XCTAssertGreaterThan(moved, 200, "★ F: Bend moves what is drawn on the part (\(moved) px between the bent and the rest pose)")
        m.views = [.bend, .heatOff]
        XCTAssertFalse(FlexibleStageVolumes.items(model: m, k: 1, part: r.project.viewerMesh).isEmpty, "★ F: Bend alone: Face 1's prism and glass stay")
        // ★ RED CONTROL: R7-V's rule — Bend alone hides them all
        FlexibleStagePage.controlBendRestPose = true
        XCTAssertTrue(FlexibleStagePage.overlaysHidden(views: m.views, edgePick: false), "control: hidden")
        let control = try overlayPixels()
        XCTAssertEqual(control, 0, "control: no curve, chip or tag on the bent model (\(control) px)")

        XCTAssertEqual(FlexibleStageVolumes.items(model: m, k: 1, part: r.project.viewerMesh), [], "control: no prism or glass")
        FlexibleStagePage.controlBendRestPose = false
        m.views = []
        print("FLEX-R7V-H5 overlay px: editing \(editing) · Bend alone \(alone) · Bend + Heat \(withHeat) · control (R7-V) \(control) · bent vs rest pose \(moved) px")
    }

    // MARK: - H6: X-ray off, Finish Covered = the plain model (the shipping renderer)

    func testXrayOffUnderTheCoveredFinishIsThePlainModel() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let s = FlexibleMainStage()
        let (r, m) = try hisPad(s)
        // his pad as saved is Finish None (pure lattice: R7-X's printed view, step 2); step 1's claim is the Covered finish's
        print("FLEX-R7V-H6 his pad's finish as saved: \(m.settings.finishMode)")
        m.edit { $0.finish = FlexibleFinish.covered.rawValue }
        XCTAssertEqual(m.settings.finishMode, .covered, "premise: the Covered finish")
        build(m)
        s.apply(r.project, owned: true, pageUp: false)
        XCTAssertTrue(pumpUntil(30) { s.channels != nil && s.layer(r.project, stage: .lattice, pageUp: false) != nil })
        let probe = FlexibleRound6EvidenceProbe()
        let img1 = FlexibleRound6Tests.Cam(name: "img1", azimuth: .pi / 4, elevation: 0.62, zoom: 1)
        let settle = r.project.force.settleRotation ?? simd_quatf(from: SIMD3<Float>(0, 0, -1), to: SIMD3<Float>(0, -1, 0))
        func frame(lattice: Bool) throws -> [UInt8] {
            s.latticeOn = lattice
            s.refresh()
            let mesh = try XCTUnwrap(s.mesh(r.project, on: .lattice))
            let mr = try probe.renderer(mesh: mesh, tints: s.tints(r.project, on: .lattice, roles: [:], stress: nil),
                                        dents: s.dents(r.project, on: .lattice), scale: s.dentScale(r.project, on: .lattice),
                                        bodyAlpha: s.bodyAlpha(r.project, on: .lattice) ?? 1, settle: settle, cam: img1, device: device,
                                        items: s.volumes(r.project, on: .lattice, drilledIn: false),
                                        layer: s.layer(r.project, stage: .lattice, pageUp: false))
            let bg = DS.Color.background
            return try XCTUnwrap(mr.renderOffscreen(size: FlexibleRound6EvidenceProbe.size, clear: MTLClearColor(red: bg.r, green: bg.g, blue: bg.b, alpha: 1)))
        }
        func differ(_ a: [UInt8], _ b: [UInt8]) -> Int {
            var n = 0
            for i in stride(from: 0, to: min(a.count, b.count), by: 4) where max(abs(Int(a[i]) - Int(b[i])), abs(Int(a[i + 1]) - Int(b[i + 1])), abs(Int(a[i + 2]) - Int(b[i + 2]))) > 6 { n += 1 }
            return n
        }
        s.xrayOn = false
        let on = try frame(lattice: true), off = try frame(lattice: false)
        let d = differ(on, off)
        XCTAssertEqual(d, 0, "★ X-ray off, Covered: the lattice adds no pixel — the plain model (\(d) px)")
        // ★ RED CONTROL: C2 + M6's rule (the Lattice view IS the X-ray) — the ghost and its walls
        s.controlXrayIsLatticeView = true
        let con = try frame(lattice: true)
        s.controlXrayIsLatticeView = false
        let dc = differ(con, off)
        XCTAssertGreaterThan(dc, 5_000, "★ RED CONTROL: C2 / M6's lattice view ghosted the model")
        print("FLEX-R7V-H6 X-ray off, Covered: lattice on vs off \(d) px (control, C2/M6: \(dc) px)")
    }
}
#endif
