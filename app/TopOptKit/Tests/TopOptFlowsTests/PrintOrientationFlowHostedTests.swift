// PrintOrientationFlowHostedTests — ★ notes27 P6 (builder H; his print orientation 11-23, SPEC 2d), the real Results screen at his
// two iPad sizes: "Print orientation" in the ⌃ drawer → the centred pop-up → OK → Cancel at the top left UNDER the Structural
// capsule, Check strength + Manual orientation bottom-right in Export's place → the processing pop-up → the benefits modal,
// centred → Keep orientation. His rules: nothing at the bottom-centre, 44 pt targets, pop-ups centred, never over a panel.
#if canImport(AppKit) && canImport(MetalKit)
import XCTest
import SwiftUI
import AppKit
@testable import TopOptFlows
@testable import TopOptKit

@MainActor
final class PrintOrientationFlowHostedTests: XCTestCase {
    let ui = LoadScenarioHostedTests()
    static let sizes = [AppBuildHost.landscape13, CGSize(width: 820, height: 1180)]

    /// A one-variant print file's result (the stand's box) whose report carries core's ranking: a new orientation may be stronger.
    static func latticeOutcome() throws -> OptimizeOutcome {
        let b = PrintOrientationHullTests.box(120, 60, 70)
        var report = IPadNotes1121Tests.report()
        report["print_orientation"] = PrintOrientationJobsTests.ranking(change: true)
        report["slicer_supports"] = "painted"
        let v = OptimizeVariant(requestedVolumeFraction: 0.6, achievedVolumeFraction: 0.6, massGrams: 120, supportVolumeVoxels: 0,
                                meshTriangleCount: b.indices.count / 3, worstCaseMargin: 1.6, accepted: true, v3Passes: true,
                                orientation: SIMD3(0, 0, 1), maxStressMPa: 10, maxInterlayerTensionMPa: 3, inPlaneMargin: 3,
                                interlayerMargin: 4.5, meshVertices: b.vertices, meshIndices: b.indices, vonMisesField: [],
                                displacementField: [], stressTensorField: [], diagnosis: nil)
        return OptimizeOutcome(variants: [v], stoppedOnMargin: false, cancelled: false, acceptedCount: 1, computedRemotely: true,
                               reportJSON: try JSONSerialization.data(withJSONObject: report))
    }

    func host(_ size: CGSize, _ calls: PrintOrientationFlowTests.Calls) throws -> LoadScenarioHostedTests.Host {
        let o = try Self.latticeOutcome()
        let rm = ResultsModel(projectName: "Stand", outcome: o)
        let flow = PrintOrientationFlowTests()
        let h = ui.host(ResultsScreen(projectName: "Stand", outcome: o, undo: {}, redo: {}, resultsModel: rm, version: "v8",
                                      printUp: SIMD3(0, 0, 1), orientation: flow.host(calls))
                            .frame(width: size.width, height: size.height), size: size)
        ui.pump(2)
        return h
    }

    func tap(_ h: LoadScenarioHostedTests.Host, _ key: String, _ what: String) throws {
        let f = try XCTUnwrap(h.frames.all[key], "\(what): \(key) is there")
        ui.click(h, CGPoint(x: f.midX, y: f.midY))
        ui.pump(1.2)
    }

    func testHisFlowAtBothSizes() throws {
        for size in Self.sizes {
            let what = "\(size)"
            PrintOrientationFlow.shared.reset()
            let calls = PrintOrientationFlowTests.Calls()
            let h = try host(size, calls)
            let screen = CGRect(origin: .zero, size: size)
            let bottomCentre = CGRect(x: size.width / 2 - 120, y: size.height - 140, width: 240, height: 140)
            // the ⌃ drawer's "Print orientation"
            try tap(h, "resultsSplitMore", "\(what): Results' ⌃")
            try tap(h, "results-split-orientation", "\(what): ★ \"Print orientation\" in the ⌃ drawer")
            // the centred pop-up
            let ask = try XCTUnwrap(h.frames.all["orientAsk"], "\(what): ★ the pop-up")
            XCTAssertEqual(ask.midX, size.width / 2, accuracy: 2, "\(what): ★ centred")
            XCTAssertEqual(ask.midY, size.height / 2, accuracy: 2, "\(what): ★ centred")
            for k in ["orientOK", "orientNotNow"] {
                let b = try XCTUnwrap(h.frames.all[k], "\(what): \(k)")
                XCTAssertGreaterThanOrEqual(b.height, 43.5, "\(what): \(k) a 44 pt target")
                XCTAssertTrue(ask.contains(b), "\(what): \(k) inside its card")
            }
            try tap(h, "orientOK", "\(what): OK")
            XCTAssertEqual(PrintOrientationFlow.shared.phase, .proposed, "\(what): ★ OK animates to it")
            // Cancel: the top left, under the Structural capsule
            let cancel = try XCTUnwrap(h.frames.all["orientCancel"], "\(what): ★ Cancel")
            XCTAssertLessThan(cancel.midX, size.width / 3, "\(what): at the left")
            XCTAssertGreaterThanOrEqual(cancel.minY, PageChrome.panelTop - 1, "\(what): ★ under the capsule")
            XCTAssertLessThan(cancel.maxY, size.height / 3, "\(what): at the top")
            XCTAssertGreaterThanOrEqual(cancel.height, 43.5, "\(what): a 44 pt target")
            // Check strength + Manual orientation, bottom right, in Export's place (Export hidden)
            XCTAssertNil(h.frames.all["resultsExport"], "\(what): ★ Export is hidden: nothing unchecked is exported")
            for k in ["orientCheck", "orientManual"] {
                let b = try XCTUnwrap(h.frames.all[k], "\(what): ★ \(k)")
                XCTAssertGreaterThan(b.midX, size.width / 2, "\(what): \(k) bottom right")
                XCTAssertGreaterThan(b.midY, size.height * 0.75, "\(what): \(k) bottom right")
                XCTAssertGreaterThanOrEqual(b.height, 43.5, "\(what): \(k) a 44 pt target")
                XCTAssertTrue(screen.contains(b), "\(what): \(k) on the screen")
            }
            for (k, f) in h.frames.all where k.hasPrefix("orient") {
                XCTAssertFalse(bottomCentre.contains(CGPoint(x: f.midX, y: f.midY)) && k != "orientCheck" && k != "orientManual",
                               "\(what): ★ nothing at the bottom-centre: \(k)")
            }
            // Check strength → the benefits modal, centred
            try tap(h, "orientCheck", "\(what): Check strength")
            for _ in 0..<40 where PrintOrientationFlow.shared.phase != .compare { ui.pump(0.1) }
            ui.pump(1)
            let modal = try XCTUnwrap(h.frames.all["orientBenefits"], "\(what): ★ the benefits modal")
            XCTAssertEqual(modal.midX, size.width / 2, accuracy: 2, "\(what): centred")
            XCTAssertTrue(screen.contains(modal), "\(what): on the screen")
            for label in ["Strength", "Layer strength", "Supports", "Print height", "Bed contact", "Check took"] {
                let r = try XCTUnwrap(h.frames.all["orientBenefit-" + label], "\(what): ★ the row \(label)")
                XCTAssertTrue(modal.contains(r), "\(what): \(label) inside the modal")
            }
            for k in ["orientKeep", "orientBenefitsCancel"] {
                XCTAssertGreaterThanOrEqual(try XCTUnwrap(h.frames.all[k]).height, 43.5, "\(what): \(k) a 44 pt target")
            }
            try tap(h, "orientKeep", "\(what): Keep orientation")
            XCTAssertEqual(calls.kept.count, 1, "\(what): ★ Keep: the face set, the new result kept")
            XCTAssertEqual(PrintOrientationFlow.shared.phase, .placed)
            XCTAssertNotNil(h.frames.all["resultsExport"], "\(what): Export is back")
        }
        PrintOrientationFlow.shared.reset()
    }

    func testTheChecksRowLinksToIt() throws {
        PrintOrientationFlow.shared.reset()
        let h = try host(AppBuildHost.landscape13, PrintOrientationFlowTests.Calls())
        let row = "Prints as you placed it"
        try tap(h, "resultsCheck-" + row, "the orientation row")
        XCTAssertNotNil(h.frames.all["info-resultsCheck-" + row], "★ its (i): how to slice the painted file")
        try tap(h, "resultsCheckLink-" + row, "★ its \"Print orientation\" link")
        XCTAssertEqual(PrintOrientationFlow.shared.phase, .asked, "the link opens the flow")
        PrintOrientationFlow.shared.reset()
    }
}
#endif
