// BottomBarMeasurementTests.swift — ★ THE MEASUREMENT THAT MEASURED THE WHOLE
// SCREEN (task 2026-08-15-lattice-and-face-ui, found on device 2026-08-14).
//
// ── WHAT HAPPENED ────────────────────────────────────────────────────────────
//
// §12b item 3 replaced a hardcoded 50 pt clearance with a real measurement: the
// bottom bar publishes its own height so the chip cluster above it cannot be
// wrong at any size the bar becomes. The measuring `GeometryReader` was mounted
// AFTER the bar's `.frame(maxHeight: .infinity)`, so it measured the EXPANDED
// FRAME — the whole viewport — instead of the bar.
//
//   iPad Pro 13-inch, 1032 x 1376 pt
//   the bar               ~90 pt   (6.5% of the viewport)
//   what was published    1376 pt  (100%)
//
// Every view that cleared the bar then padded itself off the bottom of the
// screen, and the ZStack grew to twice the display: the top chrome, the
// orientation gizmo, the stage buttons, the settings chips and the bar ITSELF
// all left the viewport. Only the Selections panel survived. SwiftUI logged one
// line — "Bound preference BottomBarHeightKey tried to update multiple times per
// frame" — which names the symptom and not the cause.
//
// ★ IT SHIPPED BECAUSE NOTHING TESTED IT. `BottomBarHeightKey` had no test at
// all: the clearance arithmetic was "obviously right", and the number fed into
// it was never questioned. The fix is the modifier ORDER; this file is the
// second line of defence, and it fails on the exact number the device produced.

import XCTest
import SwiftUI
@testable import TopOptFlows

final class BottomBarMeasurementTests: XCTestCase {

    /// The two heights measured on the device that found this.
    private let viewport: CGFloat = 1376      // iPad Pro 13-inch, points
    private let realBar: CGFloat = 90         // one-line Optimize
    private let tallBar: CGFloat = 112        // disabled Optimize, two lines

    // ─────────────────────────────────────────────────────────────────────
    // MARK: ★ the failing case, as the device produced it

    /// ★ THE DEFECT. A reading equal to the viewport is the expanded frame, and
    /// adopting it is what emptied the screen.
    func testAFullViewportReadingIsRefused() {
        XCTAssertNil(BottomBarMeasurement.accept(measured: viewport, viewport: viewport),
                     "1376 pt is not a bar — it is the frame the bar was expanded "
                     + "into, and clearing it pushes every dependent view off-screen")
    }

    /// And so is anything near it — the failure is not special to exactly 100%.
    func testAnythingNearTheViewportIsRefused() {
        for share in [0.99, 0.8, 0.6, 0.4, 0.36] {
            XCTAssertNil(BottomBarMeasurement.accept(measured: viewport * share,
                                                     viewport: viewport),
                         "\(Int(share * 100))% of the viewport is not a bar")
        }
    }

    // ─────────────────────────────────────────────────────────────────────
    // MARK: the real bar is accepted — this is not a guard that refuses everything

    /// ★ THE POSITIVE CONTROL. A guard that refused the real number too would
    /// freeze the clearance at its seed and re-open the overlap §12b item 3 fixed.
    func testTheRealBarIsAccepted() throws {
        XCTAssertEqual(try XCTUnwrap(BottomBarMeasurement.accept(measured: realBar,
                                                                 viewport: viewport)),
                       realBar, "a one-line Optimize measures ~90 pt and must pass")
        XCTAssertEqual(try XCTUnwrap(BottomBarMeasurement.accept(measured: tallBar,
                                                                 viewport: viewport)),
                       tallBar, "a DISABLED Optimize carries a second line — the whole "
                       + "reason the height is measured rather than hardcoded")
    }

    /// The 11-inch iPad, whose viewport is shorter, still accepts the same bar.
    func testTheSameBarPassesOnASmallerIPad() {
        XCTAssertNotNil(BottomBarMeasurement.accept(measured: tallBar, viewport: 1194))
        XCTAssertNotNil(BottomBarMeasurement.accept(measured: tallBar, viewport: 1024))
    }

    /// Degenerate readings do not become the clearance.
    func testDegenerateReadingsAreRefused() {
        XCTAssertNil(BottomBarMeasurement.accept(measured: 0, viewport: viewport))
        XCTAssertNil(BottomBarMeasurement.accept(measured: -5, viewport: viewport))
        XCTAssertNil(BottomBarMeasurement.accept(measured: .nan, viewport: viewport))
        XCTAssertNil(BottomBarMeasurement.accept(measured: .infinity, viewport: viewport))
    }

    /// Before the viewport is known, a reading is taken at face value rather than
    /// refused — the first frame must not be starved of a clearance.
    func testAnUnknownViewportDoesNotRefuseTheReading() {
        XCTAssertEqual(BottomBarMeasurement.accept(measured: realBar, viewport: 0), realBar)
    }

    // ─────────────────────────────────────────────────────────────────────
    // MARK: ★ the ORDER is the real fix, so the order is asserted

    /// ★ THE GUARD ABOVE WOULD MASK A RE-ORDER — it would refuse the bad number
    /// and the screen would look fine while the measurement was meaningless. So
    /// the modifier order is pinned directly: the preference must be published
    /// from INSIDE the expanded frame.
    ///
    /// Asserted on the source because the ordering is not observable from a value
    /// type, and rendering the real view in a host would need a GPU (the app's
    /// `swift test` GPU flake is a known trap).
    func testTheMeasurementIsPublishedInsideTheExpandedFrame() throws {
        let src = try String(contentsOf: Self.workspaceSource, encoding: .utf8)
        // The full signature: a bare "private var bottomBar" prefix would match
        // `bottomBarHeight`, declared 6,000 lines earlier.
        let bar = try XCTUnwrap(Self.body(of: "private var bottomBar: some View", in: src),
                                "bottomBar not found — update this test with it")

        // ★ MATCH THE EXPRESSION, NOT THE NAME. The bar's own comment names
        // `BottomBarHeightKey` while explaining this defect, and that mention sits
        // ABOVE the frame — so keying on the bare name made this test pass on the
        // broken code it exists to catch. Caught by running the negative control.
        let publish = try XCTUnwrap(bar.range(of: "preference(key: BottomBarHeightKey.self"),
                                    "the bar must still publish its height")
        // ★ THE LAST ONE. Children inside the bar carry their own
        // `maxHeight: .infinity`; the bar's OWN expansion is the outermost
        // modifier and therefore the last in the chain.
        let expand = try XCTUnwrap(bar.range(of: "maxHeight: .infinity",
                                             options: .backwards),
                                   "the bar must still expand to be bottom-anchored")
        XCTAssertLessThan(publish.lowerBound, expand.lowerBound,
                          "§12b/3: the GeometryReader must be mounted BEFORE "
                          + ".frame(maxHeight: .infinity) — after it, it measures the "
                          + "whole viewport (1376 pt, not 90) and every view that "
                          + "clears the bar leaves the screen")
    }

    /// One expression decides the clearance, so two call sites cannot clear
    /// different amounts — the shape of the bug §12b item 3 fixed.
    func testEveryClearanceGoesThroughTheOneExpression() throws {
        let src = try String(contentsOf: Self.workspaceSource, encoding: .utf8)
        let uses = src.components(separatedBy: "bottomBarHeight +").count - 1
        XCTAssertEqual(uses, 1,
                       "`bottomBarHeight` may be added to exactly ONCE — inside "
                       + "`bottomBarClearance`. Every view above the bar clears that "
                       + "one expression, so two call sites cannot clear different "
                       + "amounts; the measurement is the bar's CONTENT and omits "
                       + "the inset it floats on")
        XCTAssertTrue(src.contains("private var bottomBarClearance"),
                      "the one expression must still exist")
    }

    // MARK: - source helpers

    private static var workspaceSource: URL {
        URL(fileURLWithPath: #filePath)                       // …/Tests/TopOptFlowsTests/x.swift
            .deletingLastPathComponent()                      // …/Tests/TopOptFlowsTests
            .deletingLastPathComponent()                      // …/Tests
            .deletingLastPathComponent()                      // …/TopOptKit
            .appendingPathComponent("Sources/TopOptFlows/WorkspacePlaceholder.swift")
    }

    /// One declaration's body, by brace matching from its opening `{` — the
    /// modifier chain of a computed property, and nothing of its neighbours.
    private static func body(of decl: String, in src: String) -> String? {
        guard let start = src.range(of: decl),
              let open = src[start.upperBound...].firstIndex(of: "{") else { return nil }
        var depth = 0
        var i = open
        while i < src.endIndex {
            if src[i] == "{" { depth += 1 }
            if src[i] == "}" {
                depth -= 1
                if depth == 0 { return String(src[open...i]) }
            }
            i = src.index(after: i)
        }
        return nil
    }
}
