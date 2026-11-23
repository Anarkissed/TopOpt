// NumberPadNotes1122Tests — ★ his iPad notes 2026-11-22 (img 5: the Lattice settings panel with Apple's full keyboard over
// the lower half of the screen): "When I tap on a field to enter a number it covers the field/area I want to actually fill in.
// Why is the full alpha-numeric keyboard being used? It should just be the numeric."
//
// The numbers that still opened the system keyboard (a TextField) are the app's PadNumberBox now: a tap opens the app's
// number pad BESIDE the number (never over it, whole in the window), its keys type a draft, Done commits it through the
// field's own code (a refusal still refused), and nothing else on the page moves. Checked with real clicks at his two iPad
// windows (13″ landscape, 11″ portrait) on the Lattice settings panel (Organic, Manual: Seeds) and on the strength check's
// values (Settings), plus a keyboard connected (it takes typing in place); the draft rules and the commit rules pure.
import XCTest
import SwiftUI
@testable import TopOptFlows
@testable import TopOptKit

/// The draft and the commit (pure).
final class NumberPadNotes1122Tests: XCTestCase {

    func testTheDraftTakesThePointOnceTheMinusOnlyWhereAllowedAndDeletes() {
        var e = NumberPadEntry(seed: "1.75", allowsDecimal: true)
        e.press(.digit(3)); e.press(.dot); e.press(.digit(2)); e.press(.dot); e.press(.digit(5))
        XCTAssertEqual(e.text, "3.25", "★ the first key replaces the value; the point only once")
        e.press(.negate)
        XCTAssertEqual(e.text, "3.25", "★ no minus where the number cannot be negative")
        e.press(.delete)
        XCTAssertEqual(e.text, "3.2", "★ delete takes the last character")
        e.press(.delete); e.press(.delete); e.press(.delete)
        XCTAssertEqual(e.text, "", "deleted to empty")
        XCTAssertNil(e.value)

        var signed = NumberPadEntry(seed: "", allowsDecimal: true, allowsNegative: true)
        signed.press(.negate); signed.press(.digit(4))
        XCTAssertEqual(signed.text, "-4", "★ the minus where the number can be negative")
        XCTAssertEqual(signed.value, -4)

        var count = NumberPadEntry(seed: "3", allowsDecimal: false)
        count.press(.digit(2)); count.press(.dot)
        XCTAssertEqual(count.text, "2", "no point on a whole number")
    }

    func testTheStrengthValuesTakeTheirSmallestNumberAsPlainDecimals() {
        func type(_ s: String, _ e: inout NumberPadEntry) {
            for c in s { if c == "." { e.press(.dot) } else { e.press(.digit(Int(String(c))!)) } }
        }
        var short = NumberPadEntry(seed: "", allowsDecimal: true)
        type("0.00000000001", &short)
        XCTAssertEqual(short.text.count, NumberPadEntry.maxLength, "RED CONTROL: every other pad stops at nine characters")
        var long = NumberPadEntry(seed: "", allowsDecimal: true, limit: PadNumberBox.longLimit)
        type("0.00000000001", &long)
        XCTAssertEqual(long.value, 1e-11, "★ the strength check's smallest value types whole")
        XCTAssertEqual(PadNumberBox.plain(1e-9), "0.000000001", "★ the pad opens with every digit (the box shows 10⁻⁹)")
        XCTAssertEqual(PadNumberBox.plain(1e-11), "0.00000000001")
        XCTAssertEqual(PadNumberBox.plain(0.55), "0.55")
        XCTAssertEqual(PadNumberBox.plain(200000), "200000")
        XCTAssertEqual(PadNumberBox.plain(1e8), "100000000")
        for v in StrengthCheckDocs.variables where v.editable && v.kind == .number {
            for x in [v.min, v.max].compactMap({ $0 }) {
                XCTAssertLessThanOrEqual(PadNumberBox.plain(x).count, PadNumberBox.longLimit, "\(v.key): \(x) fits the pad")
                XCTAssertEqual(Double(PadNumberBox.plain(x)), x, "\(v.key): \(x) reads back")
            }
        }
    }

    func testACloseCommitsOnlyWhatWasTyped() {
        XCTAssertNil(PadNumberBox.toCommit(typed: nil, seed: "1.75"), "★ nothing typed: nothing committed")
        XCTAssertNil(PadNumberBox.toCommit(typed: "1.75", seed: "1.75"), "the value it opened with: nothing committed")
        XCTAssertEqual(PadNumberBox.toCommit(typed: "3.5", seed: "1.75"), "3.5")
        XCTAssertEqual(PadNumberBox.toCommit(typed: "", seed: "1.75"), "", "★ cleared: the field's empty rule runs")
    }

    func testTheOrganicCommitIsItsReturnsRule() {
        XCTAssertEqual(OrganicNumberField.parse(""), .some(nil), "★ cleared: back to Auto, as Return did")
        XCTAssertEqual(OrganicNumberField.parse(" 2,5 "), .some(2.5))
        XCTAssertEqual(OrganicNumberField.parse("3."), .some(3))
        XCTAssertNil(OrganicNumberField.parse("-"), "not a number: nothing applied")
        // the checks the commit runs, as before (a refusal: not applied, said in a pop-up)
        XCTAssertNotNil(LatticeOrganicLook.Check.seeds(25), "★ out of range is still refused")
        XCTAssertNil(LatticeOrganicLook.Check.seeds(3.5))
        XCTAssertEqual(LatticeOrganicControls.bare("Seeds (feet apart) (0 = off)"), "Seeds (feet apart)", "the pad's header")
    }

    /// ★ The two text fields that took numbers are gone (their names stay text fields).
    func testNoNumberOpensTheSystemKeyboard() throws {
        for file in ["LatticeOrganicControls.swift", "StrengthCheckPage.swift"] {
            let code = try FlexibleSource.code(file)
            XCTAssertFalse(code.contains("TextField("), "★ \(file): no text field for a number")
            XCTAssertTrue(code.contains("PadNumberBox("), "★ \(file): the app's pad")
        }
    }
}

#if canImport(AppKit) && canImport(MetalKit)
import AppKit

@MainActor
final class NumberPadNotes1122HostedTests: XCTestCase {

    static let sizes: [(String, CGSize)] = [("13L", AppBuildHost.landscape13), ("11P", CGSize(width: 820, height: 1180))]
    static let seeds = "Seeds (feet apart) (0 = off)"

    override func setUp() async throws {
        try await super.setUp()
        await MainActor.run { FlexibleSaid.recording = true; HardwareKeyboard.override = false; AppPopups.shared.current = nil }
    }

    override func tearDown() async throws {
        await MainActor.run {
            FlexibleSaid.recording = false; HardwareKeyboard.override = nil; NumberPadProbe.lastOpen = nil
            AppPopups.shared.current = nil
        }
        try await super.tearDown()
    }

    final class Probe { var all: [String: CGRect] = [:] }

    /// A part with Organic on, Manual, one lattice group on its own tab (LatticeOrganicPageHostedTests' way).
    func organicProject() throws -> (ProjectModel, UUID) {
        let p = try FlexiblePressFixtures.a1Project(3, self, facePrism: false).project
        p.lattice.flexible = nil
        p.lattice.chooseLatticeType(.structural)
        p.lattice.algorithm = "organic"
        p.latticePageManual = true
        let f = try XCTUnwrap(p.selection.groups.first?.faces.first, "premise: a face")
        _ = p.latticeStageTap(face: f, loop: [f])
        let g = try XCTUnwrap(p.latticeList.activeGroupID)
        p.lattice.groupRoles[g] = .include
        p.latticeList.clearActive()
        XCTAssertEqual(p.latticeAreaGroups.map(\.id), [g], "premise: one group, its own tab")
        return (p, g)
    }

    /// The Lattice settings panel, the group's tab open.
    func latticePanel(_ p: ProjectModel, _ size: CGSize) -> (AppBuildHost, Probe) {
        let pr = Probe()
        let v = LatticeSetupWizard(project: p, onExit: {}).cellsPage(regions: p.latticeAreaGroups.map(\.name), closeToken: 0)
            .onPreferenceChange(LatticeProbeKey.self) { pr.all = $0 }
        let h = AppBuildHost(v, size: size, test: self)
        h.pump(1.2)
        for id in ["wizard-stage-\(LatticeWizardStage.allCases.last!.rawValue)", "lattice-page-tab-area-0"] {
            if let f = pr.all[id] ?? h.frames.all[id], f.width > 1 { h.click(CGPoint(x: f.midX, y: f.midY), settle: 0.6) }
        }
        h.pump(0.6)
        return (h, pr)
    }

    /// Scroll the panel (as he would) until the number `key` sits in its shown part: below the page's head, above its Cancel /
    /// Save foot (the settings run on under the foot).
    func scrollIntoPanel(_ h: AppBuildHost, _ pr: Probe, _ key: String) {
        for _ in 0..<10 {
            guard let f = h.frames.all[key] else { return }
            let top = (pr.all["lattice-page-header"]?.maxY ?? 0) + 120
            let foot = (pr.all["lattice-page-cancel"]?.minY ?? h.size.height) - 12
            if f.minY >= top, f.maxY <= foot { return }
            var v = h.view.hitTest(NSPoint(x: f.midX, y: h.size.height - (top + foot) / 2))
            while let x = v, !(x is NSScrollView) { v = x.superview }
            guard let sv = v as? NSScrollView else { return }
            let clip = sv.contentView
            var o = clip.bounds.origin
            let dy = f.midY - (top + foot) / 2
            o.y += clip.isFlipped ? dy : -dy
            clip.scroll(to: o); sv.reflectScrolledClipView(clip)
            h.pump(0.4)
        }
    }

    func press(_ h: AppBuildHost, _ keys: String) throws {
        for c in keys { try h.padTap("numberPad-key-\(c == "." ? "dot" : String(c))", "the pad's \(c) key") }
    }

    /// Every frame on the page but the pad's own.
    func others(_ h: AppBuildHost, _ pr: Probe? = nil) -> [String: CGRect] {
        var all = h.frames.all
        for (k, v) in pr?.all ?? [:] { all["lattice:" + k] = v }
        return all.filter { !$0.key.hasPrefix("numberPad") }
    }

    /// ★ The pad beside its number: the side with room, measured in its own window; never over the number; whole on the screen.
    /// (An offscreen Mac window cannot show where a popover lands — it is kept on the Mac's screen — so the iPad's landing is
    /// worked out from what the page asked: its popover's arrow at the number, the pad on that side, slid up or down to stay
    /// whole, as UIKit places it.)
    func checkBeside(_ h: AppBuildHost, field: CGRect, _ name: String) throws {
        let pad = try XCTUnwrap(h.padFrame("numberPad"), "\(name): ★ the app's number pad opens (no system keyboard)")
        XCTAssertEqual(pad.width, NumberPad.width, accuracy: 0.5, "\(name): the app's pad, 276 pt")
        XCTAssertFalse(pad.intersects(field.insetBy(dx: 1, dy: 1)), "\(name): ★ the pad never covers its number: \(pad) vs \(field)")
        let open = try XCTUnwrap(NumberPadProbe.lastOpen, "\(name): the pad says how it opened")
        let edge = try XCTUnwrap(open.edge, "\(name): its number measured, it opens to a side")
        XCTAssertEqual(edge, NumberPadPlacement.arrowEdge(anchor: field, windowWidth: h.size.width), "\(name): ★ the side with room")
        XCTAssertEqual(open.anchor.midY, field.midY, accuracy: 2, "\(name): its own number")
        XCTAssertEqual(open.windowWidth, h.size.width, accuracy: 0.5, "\(name): its own window")
        let right = NumberPadPlacement.opensRight(anchor: field, windowWidth: h.size.width)
        let arrow: CGFloat = 13, margin: CGFloat = 10
        let y = min(max(field.midY - NumberPad.height / 2, margin), h.size.height - margin - NumberPad.height)
        let landing = CGRect(x: right ? field.maxX + arrow : field.minX - arrow - NumberPad.width, y: y,
                             width: NumberPad.width, height: NumberPad.height)
        XCTAssertTrue(CGRect(origin: .zero, size: h.size).contains(landing), "\(name): ★ the pad lands whole on the screen: \(landing)")
        XCTAssertFalse(landing.intersects(field), "\(name): ★ and beside its number, not over it: \(landing) vs \(field)")
        for k in ["0", "1", "5", "9", "dot", "delete"] {
            let f = try XCTUnwrap(h.padFrame("numberPad-key-\(k)"), "\(name): the pad's \(k) key")
            XCTAssertGreaterThanOrEqual(f.width, 44 - 0.5, "\(name): \(k) is at least 44 pt wide")
            XCTAssertGreaterThanOrEqual(f.height, 44 - 0.5, "\(name): \(k) is at least 44 pt tall")
        }
        let done = try XCTUnwrap(h.padFrame("numberPad-done"), "\(name): Done")
        XCTAssertGreaterThanOrEqual(done.height, 44 - 0.5)
    }

    /// ★ His shot: Seeds on the Lattice settings panel — the pad beside it, its keys type, Done keeps it, nothing else moves.
    func testLatticeSettingsSeedsTypesOnThePadBesideIt() throws {
        for (name, size) in Self.sizes {
            let (p, g) = try organicProject()
            let (h, pr) = latticePanel(p, size)
            let key = "numberPadBox-organic-field-" + Self.seeds
            scrollIntoPanel(h, pr, key)
            let field = try h.onScreen(key, "\(name): ★ Seeds' number on the Lattice settings panel")
            XCTAssertGreaterThanOrEqual(field.width, 44 - 0.5, "\(name): a 44 pt target")
            XCTAssertGreaterThanOrEqual(field.height, 44 - 0.5, "\(name): a 44 pt target")
            let before = others(h, pr)
            XCTAssertNil(p.lattice.organicLook(group: g).seeds, "premise: Seeds on Auto")
            NumberPadProbe.lastOpen = nil
            h.click(CGPoint(x: field.midX, y: field.midY), settle: 0.8)
            try checkBeside(h, field: field, name)
            try press(h, "3.5")
            XCTAssertNil(p.lattice.organicLook(group: g).seeds, "\(name): typing edits a draft (nothing applied yet)")
            h.pump(0.3)
            let during = others(h, pr)
            for (k, f) in before {
                guard let now = during[k] else { continue }
                // ★ RE-PINNED (release 16's whole suite): the sample's own line is centred and says its build — the engine's
                // faster Draft (release 16) can finish the sample while the pad is up, and "Making the sample… 3 s" becomes its
                // built caption (wider, the same centre). The line is held where it stood by its centre; the rest by their edges.
                if k.hasSuffix("lattice-sample-caption") {
                    XCTAssertEqual(now.midX, f.midX, accuracy: 0.5, "\(name): ★ nothing else moved: \(k)")
                } else {
                    XCTAssertEqual(now.minX, f.minX, accuracy: 0.5, "\(name): ★ nothing else moved: \(k)")
                }
                XCTAssertEqual(now.minY, f.minY, accuracy: 0.5, "\(name): ★ nothing else moved: \(k)")
                XCTAssertEqual(now.height, f.height, accuracy: 0.5, "\(name): ★ nothing else shrank: \(k)")
            }
            XCTAssertEqual(h.frames.all[key], field, "\(name): the number stays where it was")
            try h.padTap("numberPad-done", "Done")
            h.pump(0.4)
            XCTAssertNil(h.padWindow, "\(name): Done closes the pad")
            XCTAssertEqual(p.lattice.organicLook(group: g).seeds, 3.5, "\(name): ★ Done keeps it: Seeds 3.5")
            XCTAssertNil(AppPopups.shared.current, "\(name): a good number raises nothing")
        }
    }

    /// The commit is the field's own: a number the engine does not take is refused in the centred pop-up, nothing applied;
    /// a locked (Auto Sweep) number opens no pad.
    func testARefusedNumberIsNotAppliedAndALockedOneOpensNoPad() throws {
        let (p, g) = try organicProject()
        let (h, pr) = latticePanel(p, AppBuildHost.landscape13)
        scrollIntoPanel(h, pr, "numberPadBox-organic-field-" + Self.seeds)
        try h.tap("numberPadBox-organic-field-" + Self.seeds, "Seeds' number")
        try press(h, "25")
        try h.padTap("numberPad-done", "Done")
        h.pump(0.4)
        XCTAssertNil(p.lattice.organicLook(group: g).seeds, "★ 25 is over 20 spacings: not applied")
        XCTAssertEqual(AppPopups.shared.current?.title, "Seeds (feet apart): that number won’t work", "★ said front and centre")
        AppPopups.shared.current = nil

        let cell = "numberPadBox-organic-field-Cell size-small"
        XCTAssertEqual(p.lattice.organicLook(group: g).four(p.lattice.organicLook(group: g).cell, offered: LatticeOrganicLook.cellModes),
                       .autoSweep, "premise: Cell size on Auto Sweep (its numbers Auto's, greyed)")
        scrollIntoPanel(h, pr, cell)
        try h.tap(cell, "Cell size's small end")
        XCTAssertNil(h.padWindow, "★ a locked number opens no pad (as the text field took no typing)")
    }

    /// ★ A keyboard connected: no pad; the number takes typing in place and Return keeps it (through the same commit).
    func testWithAKeyboardConnectedTheNumberTakesTyping() throws {
        let (p, g) = try organicProject()
        let (h, pr) = latticePanel(p, AppBuildHost.landscape13)
        HardwareKeyboard.override = true
        h.pump(0.4)
        scrollIntoPanel(h, pr, "numberPadBox-organic-field-" + Self.seeds)
        try h.tap("numberPadBox-organic-field-" + Self.seeds, "Seeds' number")
        XCTAssertNil(h.padWindow, "★ a keyboard is connected: no pad")
        let editor = try XCTUnwrap(h.window.firstResponder as? NSTextView, "the number has the keyboard's focus")
        editor.selectAll(nil)
        editor.insertText("4", replacementRange: editor.selectedRange())
        for t in [NSEvent.EventType.keyDown, .keyUp] {
            let e = NSEvent.keyEvent(with: t, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                     windowNumber: h.window.windowNumber, context: nil, characters: "\r",
                                     charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36)!
            h.window.sendEvent(e)
            h.pump(0.05)
        }
        h.pump(0.6)
        XCTAssertEqual(p.lattice.organicLook(group: g).seeds, 4, "★ Return keeps it")
    }

    /// ★ Elsewhere: the strength check's values (Settings) — the pad beside the value, Done keeps it, a refusal stays one line.
    func testTheStrengthCheckValueTypesOnThePadBesideIt() throws {
        for (name, size) in Self.sizes {
            let defaults = try XCTUnwrap(UserDefaults(suiteName: UUID().uuidString))
            let s = StrengthSettings(defaults: defaults)
            let h = AppBuildHost(StrengthValuesList(settings: s, focus: .constant(nil), howWorkedOut: { _ in })
                                    .padding(30).background(Color(white: 0.11)),
                                 size: size, test: self)
            h.pump(1)
            // the first editable number on the screen, and a value it takes
            let shown = StrengthCheckDocs.sections.flatMap { sec in StrengthCheckDocs.variables.filter { $0.section == sec } }
                .filter { v in
                    guard v.editable, v.kind == .number, case .number(_) = v.defaultValue,
                          let f = h.frames.all["numberPadBox-strength-field-" + v.key] else { return false }
                    return f.maxY < size.height - 20 && f.minY > 0
                }
            let v = try XCTUnwrap(shown.first, "\(name): an editable value on the screen")
            guard case .number(let was) = v.defaultValue else { return XCTFail() }
            let typed = try XCTUnwrap(["2", "0.5", "0.05", "0.005"].first { t in
                let x = Double(t)!
                return x != was && (v.min.map { x >= $0 } ?? true) && (v.max.map { x <= $0 } ?? true)
            }, "\(name): \(v.key) takes one of the test's values")
            let key = "numberPadBox-strength-field-" + v.key
            let field = try h.onScreen(key, "\(name): ★ \(v.name)'s value")
            let before = others(h)
            NumberPadProbe.lastOpen = nil
            h.click(CGPoint(x: field.midX, y: field.midY), settle: 0.8)
            try checkBeside(h, field: field, "\(name) \(v.key)")
            try press(h, typed)
            XCTAssertEqual(s.current(v), v.defaultValue, "\(name): typing edits a draft")
            let during = others(h)
            for (k, f) in before {
                guard let now = during[k] else { continue }
                XCTAssertEqual(now.origin.y, f.origin.y, accuracy: 0.5, "\(name): ★ nothing else moved: \(k)")
            }
            try h.padTap("numberPad-done", "Done")
            h.pump(0.4)
            XCTAssertNil(h.padWindow, "\(name): Done closes the pad")
            XCTAssertEqual(s.current(v), .number(Double(typed)!), "\(name): ★ Done keeps it: \(v.key) \(typed)")

            if let hi = v.max {   // over its top: refused (its one line), nothing kept
                let again = try h.onScreen(key, "\(name): the value (the list's head grew a Reset all)")
                h.click(CGPoint(x: again.midX, y: again.midY), settle: 0.8)
                try press(h, PadNumberBox.plain((hi * 10).rounded(.up) + 1))
                try h.padTap("numberPad-done", "Done")
                h.pump(0.4)
                XCTAssertEqual(s.current(v), .number(Double(typed)!), "\(name): ★ over \(hi): refused, the last value kept")
            }
        }
    }
}
#endif
