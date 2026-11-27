// NoSmoothPageTests — B4 (approved design 2026-11-02, plan.md §B4 "The Smooth page is deleted", ledger note 15 / Q2).
//
// Core finishes every result (E1), so the app's Smooth page goes: Topology has two pages, Setup and Results, and the
// Library card's Export opens Results on the chosen result — its Export button is the finished shape. The pick is taken
// once, so a later open (the capsule's Results) keeps his own selection. RED before B4 (saved: scratchpad
// b2red/NoSmoothPage.txt): the page's file and opener were there, and Export did not open Results on the chosen result.
// (Topology's page list is a compile-time fact: putting `.smooth` back breaks every switch over it.)
#if canImport(AppKit) && canImport(MetalKit)
import XCTest
import SwiftUI
import AppKit
@testable import TopOptFlows
@testable import TopOptKit

@MainActor
final class NoSmoothPageTests: XCTestCase {
    let ui = LoadScenarioHostedTests()

    func testTopologyHasSetupAndResultsOnly() {
        XCTAssertEqual(TopologyPage.allCases, [.setup, .results])
        XCTAssertEqual(TopologyPage.allCases.map(\.title), ["Setup", "Results"])
        XCTAssertEqual(TopologyPage.current(resultsOpen: true, hasResults: true), .results)
        XCTAssertEqual(TopologyPage.current(resultsOpen: false, hasResults: true), .setup)
        XCTAssertEqual(TopologyPage.current(resultsOpen: true, hasResults: false), .setup)
    }

    func testTheSmoothPagesFilesAndWiringAreGone() throws {
        for f in ["SmoothingPage.swift", "SmoothingPageModel.swift", "SmoothBrush.swift", "SmoothingPageWiring.swift",
                  "SmoothPageMesh.swift", "SmoothingVariantSession.swift"] {
            XCTAssertFalse(FileManager.default.fileExists(atPath: FlexibleSource.url(f).path), "★ \(f) is deleted")
        }
        let ws = try FlexibleSource.code("WorkspacePlaceholder.swift")
        for gone in ["showSmoothingPage", "openSmoothingPage", "SmoothingPage(", "smoothTools", "smoothEntry"] {
            XCTAssertFalse(ws.contains(gone), "★ the workspace no longer reaches the Smooth page: \(gone)")
        }
        let capsule = try XCTUnwrap(ws.range(of: "@ViewBuilder var topologyCapsuleOverlay"))
        XCTAssertFalse(String(ws[capsule.lowerBound...].prefix(2_000)).contains("tertiary"), "★ the capsule: Setup | Results")
        let rs = try FlexibleSource.code("ResultsScreen.swift")
        XCTAssertFalse(rs.contains("onSmooth"), "★ Results has no Smooth button")
        // the brush survives for the Topology page's paint: its gesture, off the deleted page's tools
        XCTAssertTrue(BrushGesture.workspacePaint(active: true).armed)
    }

    func testTheLibraryExportOpensResultsOnTheChosenResultOnce() throws {
        let o = try ResultsRedesignTests.strengthenOutcome()
        let size = AppBuildHost.landscape13
        // the screen's own pick, without the Library
        let plain = ResultsModel(projectName: "CarriageArms", outcome: o)
        _ = ui.host(ResultsScreen(projectName: "CarriageArms", outcome: o, undo: {}, redo: {}, resultsModel: plain)
                        .frame(width: size.width, height: size.height), size: size)
        ui.pump(2)
        let chosen = try XCTUnwrap(plain.tabs.filter { !$0.isLatticed }.last?.variantIndex)
        XCTAssertNotEqual(plain.selectedVariantIndex, chosen, "the control: the chosen result is not the screen's own pick")
        // from the Library card's Export
        var takes = 0
        let rm = ResultsModel(projectName: "CarriageArms", outcome: o)
        _ = ui.host(ResultsScreen(projectName: "CarriageArms", outcome: o, undo: {}, redo: {}, resultsModel: rm,
                                  takeOpenOn: { takes += 1; return chosen })
                        .frame(width: size.width, height: size.height), size: size)
        ui.pump(2)
        XCTAssertEqual(rm.selectedVariantIndex, chosen, "★ Results opens on the chosen result")
        XCTAssertEqual(takes, 1, "★ taken once")
        // the workspace: Export sets it, the screen takes it and clears it
        let ws = try FlexibleSource.code("WorkspacePlaceholder.swift")
        let open = try XCTUnwrap(ws.range(of: "private func openLibraryExportIfReady()"))
        XCTAssertTrue(String(ws[open.lowerBound...].prefix(500)).contains("resultsOpenOn = run.outcome.flatMap { ResultsPick.accepted(r, in: $0) }"),
                      "★ the card's result, as Results numbers it")
        XCTAssertTrue(ws.contains("takeOpenOn: { defer { resultsOpenOn = nil }; return resultsOpenOn }"))
    }
}
#endif
