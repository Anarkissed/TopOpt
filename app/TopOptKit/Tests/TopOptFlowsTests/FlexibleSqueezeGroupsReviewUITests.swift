// FlexibleSqueezeGroupsReviewUITests — the D2 verifier's layout findings, HOSTED (task
// 2026-09-29-flexible-screens, round 4 batch D2 review). The app is NOT launched: the Settings
// page is hosted offscreen on HIS project at 11" and 13", both orientations, and clicked.
//   * each group's header line is drawn WHOLE (its rendered width ≥ the words' width at 13 pt
//     semibold: no "…", no shrink) and its force is in its pill — RED: D2's line ("Group 1 ·
//     Top A + Top B · Squeeze 10 kg") in the same place is cut on every iPad;
//   * after "+ New" the new group's header and its × are ON the panel, above the open card —
//     RED: D2's section sat under the whole face list, below the panel's fold;
//   * the squish player's timeline keeps ≥ 120 pt with the group picker at every iPad size —
//     RED: D2's picker inside the capsule left it ~32 pt at 11" portrait.
#if canImport(AppKit)
import XCTest
import SwiftUI
import AppKit
import TopOptDesign
@testable import TopOptFlows
@testable import TopOptKit

private final class ReviewHostWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

@MainActor
final class FlexibleSqueezeGroupsReviewUITests: XCTestCase {

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
        let w = ReviewHostWindow(contentRect: CGRect(x: -20000, y: -20000, width: size.width, height: size.height),
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
    /// The words' own width, as SwiftUI draws the header line (13 pt semibold).
    static func needed(_ s: String) -> CGFloat {
        (s as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 13, weight: .semibold)]).width
    }

    // MARK: the headers — whole, and on the panel

    func testTheGroupHeadersAreWholeAndOnThePanel() throws {
        var report: [String] = []
        var cutControl = 0, foldControl = 0
        for (tag, size) in FlexibleSettingsPageHostedTests.sizes {
            let his = try FlexibleHisProject.restore()
            defer { his.cleanup() }
            let m = settledModel(his.project)
            let host = host(FlexibleStagePage(project: his.project, model: m, onExit: {}), size: size)
            pump(2.5)
            // one group: its header is whole
            let one = try XCTUnwrap(FlexibleSqueezeGroupRows.rows(model: m).first)
            XCTAssertEqual(one.line, "Group 1 · Squeeze")
            XCTAssertEqual(one.value, "10 kg", "the force is in the pill")
            // + New on face 3's card, clicked
            m.select(3)
            XCTAssertTrue(pumpUntil(3) { self.local(host, "groupChips") != nil }, "\(tag): face 3's group row")
            pump(0.5)
            let chips = try XCTUnwrap(local(host, "groupChips"))
            click(host, CGPoint(x: chips.maxX - 22, y: chips.midY))
            XCTAssertTrue(pumpUntil(5) { m.squeezeGroups.count == 2 }, "\(tag): a click on + New makes group 2")
            m.select(5)
            let two = try XCTUnwrap(m.squeezeGroup(of: 3)).id
            m.moveToGroup(5, two)
            // ★ THE MISS POPS AT ONCE (D2 review): the top now shares the sides' firmer material —
            // the pop-up selects group 1's face and offers [Join the groups] [Keep apart]
            XCTAssertTrue(pumpUntil(60) { self.local(host, "fix-keep-apart") != nil }, "\(tag): the pop-up opens on the move")
            XCTAssertEqual(m.selectedRegion, m.squeezeGroups[0].regions.first, "\(tag): it selects the group that misses")
            XCTAssertNotNil(local(host, "fix-join-1-\(two)"), "\(tag): [Join the groups]")
            let keep = try XCTUnwrap(local(host, "fix-keep-apart"))
            click(host, CGPoint(x: keep.midX, y: keep.midY))
            XCTAssertTrue(pumpUntil(3) { self.local(host, "fix-keep-apart") == nil }, "\(tag): [Keep apart] closes it")
            XCTAssertEqual(m.squeezeGroups.count, 2, "\(tag): the groups stay apart")
            m.select(5)
            pump(1.2)
            let rows = FlexibleSqueezeGroupRows.rows(model: m)
            XCTAssertEqual(rows.map(\.line), ["Group 1 · Squeeze", "Group 2 · Squeeze"])
            XCTAssertEqual(rows.map(\.value), ["10 kg", "10 kg"])
            // ★ RE-PINNED (round 5, S8 — his img 3: "The groups should be separate folders … on the *left*
            // side"): each group is a FOLDER TAB on the rail. Face 5's tab (group 2) is open: ITS header —
            // "Group 2" with × and (i), Squeeze [box], Colour — is whole, on the panel, above face 5's card;
            // group 1's header lives on group 1's tab
            XCTAssertEqual(m.rail, .group(two), "\(tag): face 5's tab is open")
            let scroll = try XCTUnwrap(local(host, "panelScroll"))
            var line = "\(tag):"
            let name = try XCTUnwrap(local(host, "groupLine-2"), "\(tag): group 2's name is drawn")
            let need = Self.needed(FlexibleRowCopy.groupName(2))
            line += String(format: " G2 name %.0f/%.0f pt", name.width, need)
            XCTAssertGreaterThanOrEqual(name.width + 0.5, need, "\(tag): group 2's name is whole")
            let g2 = try XCTUnwrap(local(host, "groupRow-2")), x2 = try XCTUnwrap(local(host, "groupRemove-2"))
            let card = try XCTUnwrap(local(host, "faceCard"))
            line += String(format: " · G2 header y %.0f–%.0f, × y %.0f, card y %.0f–%.0f, scroll %.0f–%.0f",
                           g2.minY, g2.maxY, x2.midY, card.minY, card.maxY, scroll.minY, scroll.maxY)
            XCTAssertTrue(g2.minY >= scroll.minY - 0.5 && g2.maxY <= scroll.maxY + 0.5, "\(tag): group 2's header is on the panel")
            XCTAssertTrue(x2.minY >= scroll.minY - 0.5 && x2.maxY <= scroll.maxY + 0.5, "\(tag): its × is on the panel")
            XCTAssertLessThan(g2.maxY, card.minY + 1, "\(tag): the header sits above face 5's card")
            // ★ RED CONTROL: D2's one list drew BOTH groups' headers — the tab draws only its own
            XCTAssertEqual(FlexibleFaceList.sections(model: m).compactMap(\.group).count, 2, "control: D2's list had both headers")
            if local(host, "groupRow-1") == nil { foldControl += 1; cutControl += 1 }
            click(host, CGPoint(x: x2.midX, y: x2.midY))
            XCTAssertTrue(pumpUntil(5) { m.squeezeGroups.count == 1 }, "\(tag): a click on group 2's × removes it")
            XCTAssertEqual(m.groupForce(m.squeezeGroups[0]), 10...10)
            report.append(line)
            host.window.orderOut(nil); host.window.contentView = nil
        }
        print("FLEX-REVIEW-HOSTED headers\n  " + report.joined(separator: "\n  "))
        // (round 5: the two counters now count the sizes where the OTHER group's header is off the open tab)
        XCTAssertGreaterThanOrEqual(cutControl, 4, "one header per tab at every size")
        XCTAssertGreaterThanOrEqual(foldControl, 1)
    }

    // MARK: the player's timeline

    func testTheTimelineKeepsItsWidthWithTheGroupPicker() throws {
        let sims = [FlexibleSim(id: "group-1", kind: .group(1), title: "Group 1 · Top A + Top B", short: "Group 1", keys: []),
                    FlexibleSim(id: "group-2", kind: .group(2), title: "Group 2 · Face 3 + Face 5", short: "Group 2", keys: []),
                    // ★ RE-PINNED (round 5 batch G): "Play all" replaces D2's "All at once"
                    FlexibleSim(id: "all", kind: .playAll, title: "Play all", short: "All", keys: [])]
        let note = "Group 1 squishes 0.3 of 2.6 mm · firmer wins"
        func measure(_ tag: String, width: CGFloat, height: CGFloat) throws -> (timeline: CGFloat, player: CGRect) {
            let loop = FlexibleSquishLoop()
            let v = FlexibleSquishPlayer(loop: loop, fullLabel: "10 kg each", width: width, sims: sims, shown: sims[0], note: note)
                .background(GeometryReader { g in
                    Color.clear.preference(key: FlexibleKeepOutKey.self, value: ["player": g.frame(in: .global)])
                })
                .frame(width: width + 40, height: height + 40)
            let h = host(v, size: CGSize(width: width + 40, height: height + 40))
            pump(0.6)
            let t = try XCTUnwrap(h.frames.all["playerTimeline"], "\(tag): the timeline is drawn")
            let p = try XCTUnwrap(h.frames.all["player"])
            h.window.orderOut(nil); h.window.contentView = nil
            return (t.width, p)
        }
        var report: [String] = []
        var d2Short = 0
        for (tag, size) in FlexibleSettingsPageHostedTests.sizes {
            let keep = FlexibleMainLegendLayout.keepOut(viewport: size, bottomClearance: 90, chipColumnWidth: 120)
            let legends = FlexibleMainLegendLayout.place([.dent, .stress, .lattice], minimized: [], viewport: size, keepOut: keep,
                                                         priority: nil).values.map(\.frame)
            let blockers = FlexibleMainPlayerSlot.keepOut(viewport: size, bottomClearance: 90, chipColumnWidth: 120, legends: legends)
            let wanted = FlexibleSquishPlayer.size(picker: true, note: true)
            let r = try XCTUnwrap(FlexibleLegendPlacement.player(viewport: size, bottomClearance: 90, keepOut: blockers, size: wanted))
            for b in blockers { XCTAssertFalse(r.intersects(b), "\(tag): the player \(r) covers \(b)") }
            let m = try measure(tag, width: r.width, height: r.height)
            report.append(String(format: "%@ capsule %.0f pt → timeline %.0f pt (player %.0f×%.0f in %.0f×%.0f)",
                                 tag, r.width, m.timeline, m.player.width, m.player.height, r.width, r.height))
            XCTAssertGreaterThanOrEqual(m.timeline, FlexibleSquishPlayer.minTimeline, "\(tag): a timeline he can drag")
            XCTAssertLessThanOrEqual(m.player.height, r.height + 0.5, "\(tag): the player fits its placed frame")
            // ★ RED CONTROL: D2's player — the picker in the capsule, placed at D2's size (444 × 68)
            let d2Size = CGSize(width: 444, height: 68)
            if let d2 = FlexibleLegendPlacement.player(viewport: size, bottomClearance: 90, keepOut: blockers, size: d2Size) {
                FlexibleSquishPlayer.controlInlinePicker = true
                let c = try measure(tag + " D2", width: d2.width, height: d2.height)
                FlexibleSquishPlayer.controlInlinePicker = false
                report.append(String(format: "   D2: capsule %.0f pt → timeline %.0f pt", d2.width, c.timeline))
                if c.timeline < FlexibleSquishPlayer.minTimeline { d2Short += 1 }
            }
        }
        print("FLEX-REVIEW-HOSTED player\n  " + report.joined(separator: "\n  "))
        XCTAssertGreaterThanOrEqual(d2Short, 1, "control: D2's picker squeezed the timeline under 120 pt somewhere")
        // the slot places it at its new size (source pin)
        let slot = try FlexibleSource.code("FlexibleMainStatusPill.swift")
        XCTAssertTrue(slot.contains("let size = FlexibleSquishPlayer.size(picker: sims.count > 1, note: note != nil)"))
    }
}
#endif
