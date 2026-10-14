// FlexibleR7SettingsHostedTests — round 7 batch S, the Settings page HOSTED in a window (offscreen, never the app) on HIS
// pad (A1_0003 as he saved it, plus I2's Edge 9 edges group), at 11" and 13", portrait and landscape. Written BEFORE the
// code (his img3 words of 2026-10-14: "All groups should have a trash icon next to them and their names should be editable
// by tapping "group 1" or whatever the default name is."; img4: "I should only be able to view numbers associated to what
// I'm working on.").
//   * every group's header has a trash of at least 44 pt — including the ONLY group's (RED: today's × is 32 pt and shows
//     only with two or more groups);
//   * the name is one line, and a tap on it opens a one-line field;
//   * the edges group's tab mounts no face's depth chip ('flexible-depth-chip', his img4's "3.0 mm").
// FLEX_R7S_EVIDENCE_DIR=<dir> also writes the panel at each size.
#if canImport(AppKit)
import XCTest
import SwiftUI
import AppKit
import simd
import TopOptDesign
@testable import TopOptFlows
@testable import TopOptKit

private final class R7SHostWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

@MainActor
final class FlexibleR7SettingsHostedTests: XCTestCase {
    typealias G = FlexibleAngledGoldens

    final class Frames { var all: [String: CGRect] = [:]; var marks: [String: CGRect] = [:] }
    struct Host { let window: NSWindow; let view: NSView; let size: CGSize; let frames: Frames }

    static var dir: URL? { ProcessInfo.processInfo.environment["FLEX_R7S_EVIDENCE_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) } }

    func pump(_ seconds: Double) {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end { _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.02)) }
    }

    func host<V: View>(_ v: V, size: CGSize) -> Host {
        let frames = Frames()
        let root = AnyView(v.onPreferenceChange(FlexibleKeepOutKey.self) { frames.all = $0 }
            .onPreferenceChange(FlexibleViewMarksKey.self) { frames.marks = $0 }
            .environment(\.colorScheme, .dark))
        let hv = NSHostingView(rootView: root)
        hv.frame = CGRect(origin: .zero, size: size)
        _ = NSApplication.shared
        let w = R7SHostWindow(contentRect: CGRect(x: -20000, y: -20000, width: size.width, height: size.height),
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

    static let sizes: [(String, CGSize)] = [("11l", CGSize(width: 1194, height: 834)), ("11p", CGSize(width: 834, height: 1194)),
                                             ("13p", CGSize(width: 1032, height: 1376)), ("13l", CGSize(width: 1376, height: 1032))]

    @discardableResult
    func pumpUntil(_ timeout: Double, _ cond: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while !cond() {
            if Date() > end { return false }
            _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }
        return true
    }

    /// His pad opened the app's way (the main page's shared model) — SYNCHRONOUS, the run loop pumped (the page's Metal view
    /// publishes its projection only so: an async test drew no overlay at all).
    func hisPadOpened() throws -> (FlexibleHisProject.Restored, FlexibleStageModel) {
        let r = try FlexiblePressFixtures.a1Project(3, self)
        let stage = FlexibleMainStage()
        stage.reduceMotion = { true }
        let m = stage.model(for: r.project, materialsPath: FlexibleHisProject.materialsPath,
                            stampsPath: FlexibleHisProject.stampsPath, persist: {})
        addTeardownBlock { @MainActor in await m.waitForIdle() }
        m.openScene()
        XCTAssertTrue(pumpUntil(120) { m.sceneState == .ready && m.loadedKeys.allSatisfy { m.stacks[$0] != nil && m.geometry[$0] != nil } },
                      "the scene and stacks")
        return (r, m)
    }

    /// His pad opened, then I2's Edge 9 picked and [Done].
    func hisPadWithEdges() throws -> (FlexibleHisProject.Restored, FlexibleStageModel, UUID) {
        let (r, m) = try hisPadOpened()
        m.rail = .newGroup
        m.startEdgePick()
        XCTAssertTrue(pumpUntil(240) { m.edgePick.map { !$0.loading && !$0.checking } ?? false }, "the edges and corners listed")
        let c = try XCTUnwrap(m.edgePick?.candidates.first { $0.kind == .edge && Set($0.members) == [1, 2] })
        m.toggleEdgePick(c.number)
        m.setEdgePickWeight(5)
        var done = false
        var why: String?
        Task { @MainActor in why = await m.finishEdgePick(); done = true }
        XCTAssertTrue(pumpUntil(240) { done && m.sceneState == .ready && m.openedKey == m.currentSceneKey
            && m.loadedKeys.allSatisfy { m.stacks[$0] != nil && m.geometry[$0] != nil } }, "the part open on the strips")
        XCTAssertNil(why)
        pump(0.5)
        return (r, m, try XCTUnwrap(m.presses.first { $0.strip != nil }).id)
    }

    func testEveryGroupHeaderHasAFingerSizedTrashAndAOneLineName() throws {
        let (r, m, pid) = try hisPadWithEdges()
        var report: [String] = []
        var clicked = 0
        var faceChips = 0
        for (tag, size) in Self.sizes {
            let h = host(FlexibleStagePage(project: r.project, model: m, onExit: {}), size: size)
            pump(2.5)
            for g in m.squeezeGroups {
                m.rail = .group(g.id)
                pump(0.8)
                let n = g.number
                let trash = try XCTUnwrap(local(h, "groupRemove-\(n)"), "\(tag): Group \(n)'s trash")
                XCTAssertGreaterThanOrEqual(trash.width, 44, "\(tag): Group \(n)'s trash is a finger's target")
                XCTAssertGreaterThanOrEqual(trash.height, 44, "\(tag): Group \(n)'s trash is a finger's target")
                let name = try XCTUnwrap(local(h, "groupLine-\(n)"), "\(tag): Group \(n)'s name")
                XCTAssertLessThanOrEqual(name.height, 30, "\(tag): Group \(n)'s name is one line")
                let chips = h.frames.marks.keys.filter { $0.hasPrefix("depthChip-") }.sorted()
                if g.kind == .edges {
                    XCTAssertTrue(chips.isEmpty, "\(tag): the edges tab mounts no face's depth chip: \(chips)")
                    snapshot(h, "R7S_\(tag)_edges_tab.png")
                } else {
                    XCTAssertTrue(chips.allSatisfy { k in g.regions.contains { k == "depthChip-\($0)" } },
                                  "\(tag): Group \(n)'s tab mounts only its own face's chip: \(chips)")
                    faceChips += chips.count
                }
                report.append(String(format: "%@ Group %d (%@): trash %.0f×%.0f · name %.0f pt · chips %@", tag, n, g.kind.rawValue,
                                     trash.width, trash.height, name.height, chips.joined(separator: ",")))
            }
            // ★ RED CONTROL (13" landscape): today's gate on the selection alone — his img4, Face 1's chip over the edges tab
            if tag == "13l", let e = m.squeezeGroups.first(where: { $0.kind == .edges }),
               let top = m.settings.faces.first(where: { m.regions.faces(of: $0.faceRegionID, mesh: m.project.viewerMesh) == [1] })?.faceRegionID {
                FlexibleStageOverlays.controlGateOnSelectionOnly = true
                m.rail = .group(e.id)
                m.selectedRegion = top
                pump(0.8)
                let chips = h.frames.marks.keys.filter { $0.hasPrefix("depthChip-") }.sorted()
                XCTAssertEqual(chips, ["depthChip-\(top)"], "control: Face 1's chip over the edges tab (his img4)")
                snapshot(h, "R7S_13l_control_img4_chip_over_edges_tab.png")
                FlexibleStageOverlays.controlGateOnSelectionOnly = false
                report.append("13l control: chips over the edges tab \(chips)")
            }
            // a tap on the name opens a one-line field (where the header is in the scroll's view: the open card scrolls
            // the list, and a header above the fold takes no click)
            let g1 = try XCTUnwrap(m.squeezeGroups.first { $0.kind == .faces && $0.regions.count > 1 } ?? m.squeezeGroups.first)
            m.rail = .group(g1.id)
            pump(0.6)
            let name = try XCTUnwrap(local(h, "groupLine-\(g1.number)"))
            let view = local(h, "panelScroll") ?? .null
            var field = CGRect.zero
            if view.contains(CGPoint(x: name.midX, y: name.midY)) {
                click(h, CGPoint(x: name.midX, y: name.midY))
                pump(0.5)
                field = try XCTUnwrap(local(h, "groupNameField-\(g1.number)"), "\(tag): a tap on the name opens its field")
                XCTAssertLessThanOrEqual(field.height, 36, "\(tag): the field is one line")
                clicked += 1
                snapshot(h, "R7S_\(tag)_rename_field.png")
            } else {
                report.append("\(tag): Group \(g1.number)'s name above the scroll's view (\(name) vs \(view)) — not clicked")
            }
            h.window.orderOut(nil); h.window.contentView = nil
            report.append(String(format: "%@ rename field %.0f×%.0f", tag, field.width, field.height))
        }
        XCTAssertGreaterThan(clicked, 0, "the name was tapped at one size at least")
        // ★ POSITIVE CONTROL: the check sees a chip where one is drawn (a faces tab's own face)
        XCTAssertGreaterThan(faceChips, 0, "a faces tab mounts its face's chip (the check can see one)")
        // the ONLY group has its trash: Reset all, the top starts Group 1
        m.resetAll()
        XCTAssertTrue(pumpUntil(240) { m.sceneState == .ready && m.openedKey == m.currentSceneKey }, "the part open again")
        m.rail = .newGroup
        m.tapFace(1)
        XCTAssertEqual(m.squeezeGroups.count, 1, "one group")
        let h = host(FlexibleStagePage(project: r.project, model: m, onExit: {}), size: CGSize(width: 1194, height: 834))
        pump(2.5)
        let only = try XCTUnwrap(local(h, "groupRemove-1"), "the only group has its trash")
        XCTAssertGreaterThanOrEqual(min(only.width, only.height), 44)
        snapshot(h, "R7S_11l_only_group_trash.png")
        _ = pid
        print("FLEX-R7-HOSTED\n  " + report.joined(separator: "\n  "))
    }

    // MARK: - the verify of R7-S (2026-10-14): the name field, the rail's tab, Reset all's page

    /// The rail tab's title as DRAWN (what it says, its frame) for group `id`.
    func railTitle(_ h: Host, _ id: Int) -> (text: String, frame: CGRect)? {
        let p = "railTitle:\(FlexibleSettingsRailView.tabID(.group(id))):"
        guard let k = h.frames.all.keys.first(where: { $0.hasPrefix(p) }), let f = h.frames.all[k] else { return nil }
        return (String(k.dropFirst(p.count)), f)
    }

    /// How tall `name` is, whole, at the rail tab's width (the lines it needs).
    func railNeeds(_ name: String) -> CGFloat {
        NSHostingView(rootView: Text(name).font(FlexibleSettingsRailView.titleFont)
            .frame(width: FlexibleSettingsRailView.width - 4).fixedSize(horizontal: false, vertical: true)).fittingSize.height
    }

    /// A tap on group `g`'s name, then `text` typed into its field (all he typed replaced). The field's text view.
    func typeName(_ h: Host, _ m: FlexibleStageModel, _ g: FlexibleSqueezeGroup, _ text: String) throws -> NSTextView {
        m.rail = .group(g.id)
        pump(0.8)
        let name = try XCTUnwrap(local(h, "groupLine-\(g.number)"), "Group \(g.number)'s name")
        click(h, CGPoint(x: name.midX, y: name.midY))
        pump(0.5)
        let tv = try XCTUnwrap(h.window.firstResponder as? NSTextView, "Group \(g.number)'s field has the keyboard")
        tv.selectAll(nil)
        tv.insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0))
        pump(0.4)
        return tv
    }

    func openFields(_ h: Host) -> [String] { h.frames.all.keys.filter { $0.hasPrefix("groupNameField-") }.sorted() }

    /// ★ VERIFY (findings: "A name typed for one group gets saved on another group"; "The rail tab still says 'Group N'
    /// right after a rename"; "Long names are cut off in the rail tab"): on his pad at his 13" portrait —
    ///   * he types "Thumbs" on Group 2's name, changes his mind and taps Group 1's tab, then Return: GROUP 2 is "Thumbs",
    ///     Group 1 is unchanged, and no field is left open on Group 1's header (RED: today's field — Group 1 named, the
    ///     field open on a header he never tapped);
    ///   * a rename through the field and Return, nothing else in between: the rail's tab says the name AT ONCE (RED: a
    ///     rename that publishes nothing — the tab kept "Group 3");
    ///   * a name is 12 characters at most, and the rail's tab draws it WHOLE — the widest 12 on two lines (RED: today's
    ///     one-line title cuts it).
    func testTheNameFieldNamesItsOwnGroupAndTheRailTabSaysItWhole() throws {
        let (r, m) = try hisPadOpened()
        let h = host(FlexibleStagePage(project: r.project, model: m, onExit: {}), size: CGSize(width: 1032, height: 1376))
        pump(2.5)
        let gs = m.squeezeGroups
        XCTAssertEqual(gs.count, 3, "premise: his three groups")
        let g1 = gs[0], g2 = gs[1], g3 = gs[2]
        func names() -> [String] { m.squeezeGroups.map { m.groupName($0) } }
        var report: [String] = []
        // ★ HIS CASE
        _ = try typeName(h, m, g2, "Thumbs")
        withAnimation(.easeInOut(duration: 0.15)) { m.rail = .group(g1.id) }   // the rail tab's own action
        pump(0.8)
        let left = openFields(h)
        (h.window.firstResponder as? NSTextView)?.insertNewline(nil)
        pump(0.6)
        XCTAssertEqual(names(), ["Group 1", "Thumbs", "Group 3"], "what he typed names the group he typed it on — never the tab he moved to")
        XCTAssertTrue(left.isEmpty, "no field left open on Group 1's header: \(left)")
        XCTAssertEqual(railTitle(h, g2.id)?.text, "Thumbs", "Group 2's rail tab says it")
        report.append("his case: names \(names()) · fields after the switch \(left)")
        // ★ THE RAIL'S TAB AT ONCE, and the 12-character cap: "Index finger pad" typed is "Index finger"
        var tv = try typeName(h, m, g3, "Index finger pad")
        tv.insertNewline(nil)
        pump(0.6)
        XCTAssertEqual(m.groupName(try XCTUnwrap(m.railGroup(g3.id))), "Index finger", "12 characters at most")
        XCTAssertEqual(railTitle(h, g3.id)?.text, "Index finger", "the rail's tab says it at once (nothing else changed)")
        // ★ WHOLE on the rail: a realistic 12 and the widest 12
        for name in ["Index finger", "WWWWWWWWWWWW"] {
            if m.groupName(try XCTUnwrap(m.railGroup(g3.id))) != name {
                tv = try typeName(h, m, g3, name)
                tv.insertNewline(nil)
                pump(0.6)
            }
            let t = try XCTUnwrap(railTitle(h, g3.id), "Group 3's rail title")
            XCTAssertEqual(t.text, name)
            let need = railNeeds(name)
            XCTAssertGreaterThanOrEqual(t.frame.height + 0.5, need, "'\(name)' is drawn whole on the rail (\(t.frame.height) of \(need) pt)")
            XCTAssertLessThanOrEqual(t.frame.width, FlexibleSettingsRailView.width, "…inside its tab")
            report.append(String(format: "rail '%@': drawn %.0f×%.0f, needs %.0f pt tall", name, t.frame.width, t.frame.height, need))
        }
        snapshot(h, "R7S_verify_rail_widest_name.png")
        // the player's line beside a long name (a probe: the player's layout is R7-V's)
        if let note = local(h, "playerNote") {
            report.append(String(format: "player note drawn %.0f pt beside '%@'", note.width, m.groupName(try XCTUnwrap(m.railGroup(g3.id)))))
        }

        // ★ RED CONTROL 1: today's field — it stays open on the header he moved to and names THAT group
        FlexibleGroupNameField.controlCommitsToTheHeadersGroup = true
        _ = try typeName(h, m, g2, "Palms")
        withAnimation(.easeInOut(duration: 0.15)) { m.rail = .group(g1.id) }
        pump(0.8)
        let leftC = openFields(h)
        (h.window.firstResponder as? NSTextView)?.insertNewline(nil)
        pump(0.6)
        FlexibleGroupNameField.controlCommitsToTheHeadersGroup = false
        XCTAssertEqual(leftC, ["groupNameField-1"], "control: the field open on Group 1's header")
        XCTAssertEqual(names().first, "Palms", "control: Group 1 named with what he typed on Group 2")
        report.append("control 1: names \(names()) · fields \(leftC)")
        // ★ RED CONTROL 2: a rename that publishes nothing — the rail's tab keeps the old name
        FlexibleStageModel.controlNameEditPublishesNothing = true
        tv = try typeName(h, m, g3, "Ring finger")
        tv.insertNewline(nil)
        pump(0.6)
        FlexibleStageModel.controlNameEditPublishesNothing = false
        XCTAssertEqual(m.groupName(try XCTUnwrap(m.railGroup(g3.id))), "Ring finger")
        XCTAssertNotEqual(railTitle(h, g3.id)?.text, "Ring finger", "control: the rail's tab still says the old name")
        report.append("control 2: rail \(railTitle(h, g3.id)?.text ?? "-")")
        // ★ RED CONTROL 3: today's one-line title cuts the widest 12
        FlexibleSettingsRailView.controlOneLineTitle = true
        defer { FlexibleSettingsRailView.controlOneLineTitle = false }
        m.setGroupName(g3.id, "WWWWWWWWWWWW")
        pump(0.8)
        let c3 = try XCTUnwrap(railTitle(h, g3.id))
        XCTAssertLessThan(c3.frame.height + 0.5, railNeeds("WWWWWWWWWWWW"), "control: one line — the widest 12 is cut")
        report.append(String(format: "control 3: one line %.0f pt tall", c3.frame.height))
        print("FLEX-R7-VERIFY-NAME\n  " + report.joined(separator: "\n  "))
    }

    /// ★ VERIFY (finding: "Reset all at once pops a blocker and locks Exit as 'Fix 1 thing'" — his pad, the PAGE chrome, not
    /// the panel only): after [Reset all] → [Reset], the rail is [Model] [New] and NO pop-up opens (the [+ New] tab asks
    /// for exactly what the blocker says: "Tap the face that starts it"); still none while the keypad asks Face 3's weight.
    /// The top line and Exit still name it ("Fix 1 thing" — whether an empty setup may leave is asked of him). RED CONTROL:
    /// today's — the [Press Face 1] pop-up over [Model] [New].
    func testResetAllOnHisPadOpensNoPopUpOverModelAndNew() throws {
        let (r, m) = try hisPadOpened()
        let h = host(FlexibleStagePage(project: r.project, model: m, onExit: {}), size: CGSize(width: 1032, height: 1376))
        pump(2.5)
        func settled() -> Bool {
            m.sceneState == .ready && m.openedKey == m.currentSceneKey && !m.designsInFlight && !m.readiness.designing
        }
        func resetByHand() throws {
            let b = try XCTUnwrap(local(h, "resetAll"), "[Reset all]")
            click(h, CGPoint(x: b.midX, y: b.midY))
            pump(0.6)
            let c = try XCTUnwrap(local(h, "resetConfirm"), "[Reset]")
            click(h, CGPoint(x: c.midX, y: c.midY))
            pump(0.5)
            XCTAssertTrue(pumpUntil(240) { settled() }, "the part open on whole faces")
            pump(1.5)
        }
        func fixes() -> [String] { h.frames.all.keys.filter { $0.hasPrefix("fix-") }.sorted() }
        func exitTitle() -> String? { h.frames.all.keys.first { $0.hasPrefix("exitTitle:") }.map { String($0.dropFirst(10)) } }
        try resetByHand()
        XCTAssertEqual(FlexibleSettingsRailView.tabs(model: m).map(\.title), ["Model", "New"])
        XCTAssertEqual(fixes(), [], "no pop-up over [Model] [New]")
        XCTAssertEqual(exitTitle(), "Fix 1 thing", "Exit still names it (asked of him)")
        snapshot(h, "R7S_verify_reset_page_no_popup.png")
        m.tapFace(3)
        pump(1.2)
        XCTAssertEqual(m.newGroupAsk, 3, "the keypad asks Face 3's weight")
        XCTAssertEqual(fixes(), [], "…with no pop-up beside it")
        snapshot(h, "R7S_verify_reset_page_keypad_no_popup.png")
        print("FLEX-R7-VERIFY-RESET exit '\(exitTitle() ?? "-")' · fixes \(fixes())")
        // ★ RED CONTROL: today's — the pop-up opens on his Reset
        m.newGroupAsk = nil
        FlexibleStagePage.history(undo: true, project: r.project, model: m)
        XCTAssertTrue(pumpUntil(240) { settled() && !m.settings.faces.isEmpty }, "undo: his pad back")
        pump(1.5)
        FlexibleStagePage.controlPopOnNewTab = true
        defer { FlexibleStagePage.controlPopOnNewTab = false }
        try resetByHand()
        XCTAssertFalse(fixes().isEmpty, "control: today's [Press …] pop-up over [Model] [New]")
        print("FLEX-R7-VERIFY-RESET control fixes \(fixes())")
    }
}
#endif
