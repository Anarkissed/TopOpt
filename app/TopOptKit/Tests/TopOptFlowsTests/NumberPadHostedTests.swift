// NumberPadHostedTests — B2, U15 (approved design 2026-11-02, design-system §4.33 and §6 U15; his Phase 3 note P1: "All
// numerical input places should open a numerical input keyboard when tapped, unless a keyboard is connected to the ipad").
//
// On Topology Setup, Safety margin › Custom… (a number, 150 % and up, app-map §7), with real clicks:
//   • with no keyboard connected the app's pad opens beside the number (below it, or above), 276 pt, its keys ≥ 44 pt;
//   • Done keeps the number (a tap anywhere else closes it through the same binding: UIKit's, checked on his iPad);
//   • out of range keeps the nearest allowed value and the page says so ("Kept 150 % (150 % and up)");
//   • with a keyboard connected no pad opens: the number takes typing, Return keeps it, Esc cancels.
// The pad is a popover (its own window): the clicks go to that window (`AppBuildHost.padTap`).
// RED: `NumberPadProbe.controlOldPad` (and the saved run, NUMBERPAD_RED=1) puts the old pad back — no range, no keyboard path.
#if canImport(AppKit) && canImport(MetalKit)
import XCTest
import SwiftUI
import AppKit
@testable import TopOptFlows
@testable import TopOptKit

@MainActor
final class NumberPadHostedTests: XCTestCase {

    override func tearDown() async throws {
        await MainActor.run { HardwareKeyboard.override = nil; NumberPadProbe.controlOldPad = false }
        try await super.tearDown()
    }

    func host(_ size: CGSize) throws -> (AppBuildHost, ProjectModel, AppModel) {
        HardwareKeyboard.override = false
        if ProcessInfo.processInfo.environment["NUMBERPAD_RED"] != nil { NumberPadProbe.controlOldPad = true }
        let r = try FlexiblePressFixtures.a1Project(3, self, facePrism: false)
        let p = r.project
        p.lattice.flexible = nil
        let h = AppBuildHost(WorkspacePlaceholder(model: r.app, project: p), size: size, test: self)
        h.pump(3)
        return (h, p, r.app)
    }

    /// Safety margin › Custom… (the number, with its pad open at once).
    func custom(_ h: AppBuildHost) throws {
        let offered = try h.pickFromMenu("safetyMargin", "Custom", what: "Safety margin")
        XCTAssertTrue(offered.contains(where: { $0.contains("Custom") }), "the menu offers Custom…: \(offered)")
        h.pump(0.8)
    }

    func press(_ h: AppBuildHost, _ keys: String) throws {
        for c in keys { try h.padTap("numberPad-key-\(c == "." ? "dot" : String(c))", "the pad's \(c) key") }
    }

    func testTheNumberOpensThePadBesideItAndDoneKeepsIt() throws {
        for size in AppBuildHost.probeSizes {
            let (h, p, _) = try host(size)
            try custom(h)
            let field = try h.onScreen("numberField-safety-custom", "\(size): the Custom number")
            let pad = try XCTUnwrap(h.padFrame("numberPad"), "\(size): ★ U15 — the app's number pad opens")
            XCTAssertEqual(pad.width, 276, accuracy: 0.5, "\(size): §4.33 — 276 pt wide")
            XCTAssertFalse(pad.intersects(field.insetBy(dx: 1, dy: 1)), "\(size): ★ the pad never covers its number: \(pad) vs \(field)")
            // ★ his iPad 11-09 (3.3): "it moves to the side and ALWAYS shows whole, never cut at the bottom or top" — beside
            // its number, on the side with room (it opened below, or above: below cut it off at the window's foot)
            XCTAssertTrue(pad.minX >= field.maxX - 0.5 || pad.maxX <= field.minX + 0.5,
                          "\(size): ★ beside it — to its side: \(pad) vs \(field)")
            for k in ["0", "1", "2", "3", "4", "5", "6", "7", "8", "9", "delete", "done"] {
                let key = k == "done" ? "numberPad-done" : "numberPad-key-\(k)"
                let f = try XCTUnwrap(h.padFrame(key), "\(size): the pad's \(k) key")
                XCTAssertGreaterThanOrEqual(f.width, 44 - 0.5, "\(size): \(k) is ≥ 44 pt wide")
                XCTAssertGreaterThanOrEqual(f.height, 44 - 0.5, "\(size): \(k) is ≥ 44 pt tall")
                XCTAssertTrue(pad.insetBy(dx: -0.5, dy: -0.5).contains(f), "\(size): \(k) inside the pad")
            }
            try press(h, "250")
            try h.padTap("numberPad-done", "Done")
            XCTAssertNil(h.padWindow, "\(size): Done closes the pad")
            XCTAssertEqual(p.force.safetyMarginValue, 2.5, accuracy: 1e-9, "\(size): ★ Done keeps the number (250 %)")
        }
    }

    /// (A tap anywhere else closes the popover through the same binding as Done; on the iPad UIKit does that on the tap — an
    /// offscreen Mac window can't fake an outside click to NSPopover, so that one is on his iPad list.)
    func testOutOfRangeKeepsTheNearestAndSaysSo() throws {
        let (h, p, app) = try host(AppBuildHost.landscape13)
        try custom(h)
        try press(h, "100")
        try h.padTap("numberPad-done", "Done")
        XCTAssertEqual(p.force.safetyMarginValue, 1.5, accuracy: 1e-9, "★ 100 % is out of range: the nearest allowed (150 %) is kept")
        XCTAssertEqual(app.toast, "Kept 150 % (150 % and up)", "★ and the page says so: the number kept, then the range")
    }

    func testWithAKeyboardConnectedNoPadOpensAndReturnKeepsIt() throws {
        let (h, p, _) = try host(AppBuildHost.landscape13)
        HardwareKeyboard.override = true
        h.pump(0.4)
        try custom(h)
        XCTAssertNil(h.padWindow, "★ a keyboard is connected: no pad")
        _ = try h.onScreen("numberPad-typing", "★ the number takes typing in place")
        let editor = try XCTUnwrap(h.window.firstResponder as? NSTextView, "the number has the keyboard's focus")
        editor.selectAll(nil)
        editor.insertText("225", replacementRange: editor.selectedRange())
        key(h, 36, "\r")   // Return
        h.pump(0.6)
        XCTAssertEqual(p.force.safetyMarginValue, 2.25, accuracy: 1e-9, "★ Return keeps it")
        XCTAssertNil(h.frames.all["numberPad-typing"], "and the typing closes")

        try custom(h)
        let editor2 = try XCTUnwrap(h.window.firstResponder as? NSTextView)
        editor2.selectAll(nil)
        editor2.insertText("400", replacementRange: editor2.selectedRange())
        key(h, 53, "\u{1b}")   // Esc
        h.pump(0.6)
        XCTAssertEqual(p.force.safetyMarginValue, 2.25, accuracy: 1e-9, "★ Esc cancels")
    }

    func key(_ h: AppBuildHost, _ code: UInt16, _ chars: String) {
        for t in [NSEvent.EventType.keyDown, .keyUp] {
            let e = NSEvent.keyEvent(with: t, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                     windowNumber: h.window.windowNumber, context: nil, characters: chars,
                                     charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code)!
            h.window.sendEvent(e)
            h.pump(0.05)
        }
    }
}

/// The pad's words (pure).
final class NumberPadLayoutTests: XCTestCase {
    func testTheHeaderNamesTheSettingAndItsRange() {
        XCTAssertEqual(NumberPad.Config(title: "Depth", unit: "mm", range: NumberRange(1, 40)).header, "Depth · 1 to 40 mm")
        XCTAssertEqual(NumberPad.Config(title: "Safety margin", unit: "%", range: NumberRange(150, nil)).header,
                       "Safety margin · 150 % and up")
        XCTAssertEqual(NumberPad.Config(title: "Port").header, "Port", "no range: the name alone")
        XCTAssertEqual(NumberRange(1, 40).keptNote(40, unit: "mm"), "Kept 40 (1 to 40 mm)")
        XCTAssertEqual(NumberRange(150, nil).keptNote(150, unit: "%"), "Kept 150 % (150 % and up)")
        XCTAssertEqual(NumberRange(1, 40).clamp(55), 40)
        XCTAssertEqual(NumberRange(150, nil).clamp(100), 150)
        XCTAssertEqual(NumberRange(150, nil).clamp(9000), 9000)
        XCTAssertEqual(NumberPad.width, 276)
        XCTAssertEqual(NumberPad.keyHeight, 50)
    }
}
#endif
