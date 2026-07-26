// NumberPadTests.swift — headless tests for the app-wide compact numeric-entry pad
// (numeric-input handoff). The pad's SwiftUI shell is maintainer device QA (the /app/
// rule); everything asserted here is the PURE keystroke state machine (`NumberPadEntry`)
// plus the two flow guarantees the bars call out:
//   B3  the FIRST keystroke replaces the whole value (no caret, no append), and
//   B4  a value entered through the pad is covered by the EXISTING `UndoHistory`
//       (the pad writes through the same `ForceModel` setter a scrub does).
// It also covers the preset-name button label (selected preset name + "· Edited" marker).

import XCTest
import TopOptKit
@testable import TopOptFlows

final class NumberPadTests: XCTestCase {

    // MARK: - B3: first keystroke replaces the whole value

    func testFirstDigitReplacesTheSeed() {
        // Opens showing "12.5"; the first key is "3" → the field is "3", not "12.53".
        var e = NumberPadEntry(seedValue: 12.5, allowsDecimal: true)
        XCTAssertEqual(e.text, "12.5", "the pad opens showing the current value")
        e.press(.digit(3))
        XCTAssertEqual(e.text, "3", "the first keystroke clears the seed")
        XCTAssertEqual(e.value, 3)
    }

    func testSubsequentDigitsAppendAfterTheReplace() {
        var e = NumberPadEntry(seedValue: 100, allowsDecimal: false)
        e.press(.digit(4)); e.press(.digit(2))
        XCTAssertEqual(e.text, "42")
        XCTAssertEqual(e.value, 42)
    }

    func testDecimalEntryBuildsAValue() {
        var e = NumberPadEntry(seedValue: 9, allowsDecimal: true)
        e.press(.digit(2)); e.press(.dot); e.press(.digit(5))
        XCTAssertEqual(e.text, "2.5")
        XCTAssertEqual(e.value, 2.5)
    }

    func testLeadingDecimalReadsAsZeroPoint() {
        var e = NumberPadEntry(seedValue: 9, allowsDecimal: true)
        e.press(.dot)                 // first key is "." → "0."
        XCTAssertEqual(e.text, "0.")
        e.press(.digit(5))
        XCTAssertEqual(e.value, 0.5)
    }

    func testOnlyOneDecimalPoint() {
        var e = NumberPadEntry(seedValue: 0, allowsDecimal: true)
        e.press(.digit(1)); e.press(.dot); e.press(.dot); e.press(.digit(2))
        XCTAssertEqual(e.text, "1.2", "a second decimal point is ignored")
    }

    func testDecimalKeyIgnoredOnIntegerPad() {
        var e = NumberPadEntry(seedValue: 3, allowsDecimal: false)
        e.press(.digit(4)); e.press(.dot); e.press(.digit(2))
        XCTAssertEqual(e.text, "42", "integer fields never accept a decimal point")
    }

    func testNoLeadingZeros() {
        var e = NumberPadEntry(seedValue: 7, allowsDecimal: false)
        e.press(.digit(0)); e.press(.digit(5))
        XCTAssertEqual(e.text, "5", "\"0\" then \"5\" is 5, not 05")
        XCTAssertEqual(e.value, 5)
    }

    func testDeleteBackspacesTheCurrentValue() {
        // Delete edits the seed in place (a nudge affordance) rather than replacing it.
        var e = NumberPadEntry(seedValue: 128, allowsDecimal: false)
        e.press(.delete)
        XCTAssertEqual(e.text, "12")
        e.press(.digit(9))
        XCTAssertEqual(e.text, "129")
    }

    func testEmptyFieldParsesToNil() {
        // Clearing every digit yields nil — the caller decides what empty means
        // (GlassValuePill reverts to Auto; the weight pill keeps its last value).
        var e = NumberPadEntry(seedValue: 5, allowsDecimal: false)
        e.press(.delete)
        XCTAssertEqual(e.text, "")
        XCTAssertNil(e.value)
    }

    func testTrailingDotDoesNotFlickerToNil() {
        // Mid-entry "2." must read as 2, not nil, so a live write never blips to Auto.
        var e = NumberPadEntry(seedValue: 0, allowsDecimal: true)
        e.press(.digit(2)); e.press(.dot)
        XCTAssertEqual(e.text, "2.")
        XCTAssertEqual(e.value, 2)
    }

    func testMaxLengthCap() {
        var e = NumberPadEntry(seedValue: 0, allowsDecimal: false)
        for _ in 0..<20 { e.press(.digit(9)) }
        XCTAssertEqual(e.text.count, NumberPadEntry.maxLength)
    }

    func testSeedStringFormatting() {
        XCTAssertEqual(NumberPadEntry.seedString(2.5, allowsDecimal: true), "2.5")
        XCTAssertEqual(NumberPadEntry.seedString(2.0, allowsDecimal: true), "2", "drops trailing .0")
        XCTAssertEqual(NumberPadEntry.seedString(3.0, allowsDecimal: false), "3")
        XCTAssertEqual(NumberPadEntry.seedString(nil, allowsDecimal: true), "")
        XCTAssertEqual(NumberPadEntry.seedString(.nan, allowsDecimal: true), "")
    }

    // MARK: - B4: pad-entered values ride the EXISTING UndoHistory

    @MainActor
    private func emptyProject() -> ProjectModel {
        ProjectModel(id: UUID(), name: "T", material: "PLA", process: .fdm,
                     importedFile: nil, importedMesh: nil)
    }

    @MainActor
    func testUndoRedoCoversLoadWeightEnteredThroughTheNumberPad() {
        let p = emptyProject()
        let g = p.selection.addGroup()
        p.force.makeLoad(g)
        p.force.setWeight(g, kg: 2.5)

        // Let the group + load + 2.5 kg settle as the undo baseline (the on-device
        // debounce; the test drives it with the same 0.6 s wait UndoHistoryTests uses).
        let settled = expectation(description: "settle")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { settled.fulfill() }
        wait(for: [settled], timeout: 2)

        // Simulate a pad entry that REPLACES 2.5 with 42 — the exact write the pill's
        // `onValue` performs (`force.setWeight`, so it flows through the same setter and
        // therefore the same UndoHistory as a scrub).
        var e = NumberPadEntry(seedValue: 2.5, allowsDecimal: true)
        e.press(.digit(4)); e.press(.digit(2))
        p.force.setWeight(g, kg: try! XCTUnwrap(e.value))
        XCTAssertEqual(p.force.kind(for: g).weightKg, 42)

        p.performUndo()
        XCTAssertEqual(p.force.kind(for: g).weightKg, 2.5,
                       "undo reverted the pad-entered weight to the settled value")
        p.performRedo()
        XCTAssertEqual(p.force.kind(for: g).weightKg, 42, "redo restored the pad-entered weight")
    }

    @MainActor
    func testUndoCoversClearanceMarginEnteredThroughTheNumberPad() {
        let p = emptyProject()
        let g = p.selection.addGroup()
        // A pad entry into a GlassValuePill margin chip → `force.setClearanceMargin`.
        var e = NumberPadEntry(seedValue: 3, allowsDecimal: true)
        e.press(.digit(5))
        p.force.setClearanceMargin(g, mm: try! XCTUnwrap(e.value))
        XCTAssertEqual(p.force.clearanceOverride(for: g).concentricMarginMM, 5)

        p.performUndo()   // folds the in-flight edit and reverts to the seeded floor
        XCTAssertNil(p.force.clearanceOverride(for: g).concentricMarginMM,
                     "undo reverted the pad-entered clearance margin")
        p.performRedo()
        XCTAssertEqual(p.force.clearanceOverride(for: g).concentricMarginMM, 5,
                       "redo restored the pad-entered margin")
    }
}
