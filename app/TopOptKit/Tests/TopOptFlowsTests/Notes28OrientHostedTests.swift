// Notes28OrientHostedTests — ★ notes28 (his iPad notes on release 18), the real Results screen at his two iPad sizes:
//   2. "'Cancel' cuts below the 'Structural' menu row... Let's put it to the left of 'Manual orientation'": Cancel in the bottom
//      row, left of Manual orientation; in Manual, what to tap above that row; nothing left at the top left.
//   3. Manual orientation draws Bambu Studio's patches (his img 81): the faces turned toward him and the edge rests, each its
//      own patch to tap; a tap turns the part to it, Manual stays open and its patches come back in the new pose.
#if canImport(AppKit) && canImport(MetalKit)
import XCTest
import SwiftUI
import AppKit
@testable import TopOptFlows
@testable import TopOptKit

@MainActor
final class Notes28OrientHostedTests: XCTestCase {
    let ui = LoadScenarioHostedTests()

    func testManualOrientationDrawsBambusPatchesWithCancelInTheBottomRowAtBothSizes() throws {
        for size in PrintOrientationFlowHostedTests.sizes {
            let what = "\(size)"
            let flow = PrintOrientationFlow.shared
            flow.reset()
            let o = try PrintOrientationFlowHostedTests.latticeOutcome()
            let rm = ResultsModel(projectName: "Stand", outcome: o)
            let h = ui.host(ResultsScreen(projectName: "Stand", outcome: o, undo: {}, redo: {}, resultsModel: rm, version: "v8",
                                          printUp: SIMD3(0, 0, 1), orientation: PrintOrientationFlowTests().host(.init()))
                                .frame(width: size.width, height: size.height), size: size)
            ui.pump(2)
            let b = PrintOrientationHullTests.box(120, 60, 70)
            flow.start(kind: .cells, ranking: nil, mesh: (b.vertices, b.indices))   // no ranking: straight to Manual
            for _ in 0..<80 where flow.patches == nil { ui.pump(0.05) }
            ui.pump(0.8)
            XCTAssertEqual(flow.phase, .manual, what)
            let plates = h.frames.all.filter { $0.key.hasPrefix("orientPlate-") }
            let edges = h.frames.all.filter { $0.key.hasPrefix("orientEdge-") }
            XCTAssertGreaterThanOrEqual(plates.count, 2, "\(what): ★ each face turned toward him a patch")
            XCTAssertGreaterThanOrEqual(edges.count, 2, "\(what): ★ each edge rest its own small face, never a line")
            for (k, f) in edges { XCTAssertGreaterThan(f.width * f.height, 1, "\(what): \(k) is a face (an area), not a line") }
            // 2: Cancel in the bottom row, left of Manual orientation; what to tap above the row; nothing at the top left
            let cancel = try XCTUnwrap(h.frames.all["orientCancel"], "\(what): ★ Cancel")
            let manual = try XCTUnwrap(h.frames.all["orientManual"], "\(what): Manual orientation")
            let check = try XCTUnwrap(h.frames.all["orientCheck"], "\(what): Check strength")
            XCTAssertLessThanOrEqual(cancel.maxX, manual.minX + 0.5, "\(what): ★ Cancel left of Manual orientation")
            XCTAssertLessThanOrEqual(manual.maxX, check.minX + 0.5, "\(what): then Check strength")
            XCTAssertEqual(cancel.midY, manual.midY, accuracy: 2, "\(what): one row")
            XCTAssertGreaterThanOrEqual(cancel.height, 43.5, "\(what): a 44 pt target")
            let caption = try XCTUnwrap(h.frames.all["orientManualCaption"], "\(what): what to tap")
            XCTAssertLessThanOrEqual(caption.maxY, manual.minY + 0.5, "\(what): above the row")
            XCTAssertGreaterThan(caption.midY, size.height / 2, "\(what): at the bottom, never under the Structural menu")
            XCTAssertGreaterThan(caption.midX, size.width / 2, "\(what): at the right")
            // 3: a tap on the largest patch turns the part to it; Manual stays open; its patches come back
            let (key, f) = try XCTUnwrap(plates.max { $0.value.width * $0.value.height < $1.value.width * $1.value.height })
            ui.click(h, CGPoint(x: f.midX, y: f.midY))
            let shown = try XCTUnwrap(flow.shown, "\(what): ★ a tap on \(key) picks it")
            XCTAssertFalse(shown.onEdge, "\(what): a face")
            XCTAssertEqual(flow.phase, .manual, "\(what): ★ Manual stays open")
            ui.pump(1.2)
            XCTAssertFalse(flow.turning, what)
            XCTAssertFalse(h.frames.all.filter { $0.key.hasPrefix("orientPlate-") }.isEmpty, "\(what): ★ its patches back, turned")
            XCTAssertNotNil(h.frames.all[key], "\(what): ★ the picked one still drawn (its outline, on the bed)")
            flow.reset()
        }
    }
}
#endif
