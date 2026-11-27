// ResultsPickHostedTests — B4 (approved design 2026-11-02, app-map §3.5, Q1, ledger 11): the Results panel is the version's —
// "v7 results" — its lines are the results (a · Just safe, b · +10 %, c · +20 %), and the selected line offers **Pick this**,
// the chosen result the Library's card rings and tags ("v7b"). Off the Library there is no ring to set, so no Pick this.
// RED before B4 (saved: scratchpad b2red/ResultsPick.txt): the panel said "Versions" and had no Pick this.
#if canImport(AppKit) && canImport(MetalKit)
import XCTest
import SwiftUI
import AppKit
@testable import TopOptFlows
@testable import TopOptKit

@MainActor
final class ResultsPickHostedTests: XCTestCase {
    final class Picks { var all: [Int] = [] }
    let ui = LoadScenarioHostedTests()

    func screen(_ size: CGSize, version: String?, picked: Int?, picks: Picks?) throws -> (LoadScenarioHostedTests.Host, ResultsModel) {
        let o = try ResultsRedesignTests.strengthenOutcome()
        let rm = ResultsModel(projectName: "CarriageArms", outcome: o)
        let h = ui.host(ResultsScreen(projectName: "CarriageArms", outcome: o, undo: {}, redo: {}, resultsModel: rm,
                                      version: version, pickedVariant: picked,
                                      onPick: picks.map { p in { p.all.append($0) } })
                            .frame(width: size.width, height: size.height), size: size)
        ui.pump(2)
        return (h, rm)
    }

    func testTheHeaderIsTheVersionsAndPickThisPicksTheSelectedResult() throws {
        for size in [AppBuildHost.landscape13, AppBuildHost.portrait13, AppBuildHost.landscape11] {
            let picks = Picks()
            let (h, rm) = try screen(size, version: "v7", picked: nil, picks: picks)
            let what = "\(size)"
            XCTAssertEqual(ResultsVersionsPanel.title("v7"), "v7 results")
            XCTAssertEqual(ResultsVersionsPanel.title(nil), "Results")
            let rows = ResultsVersions.rows(tabs: rm.tabs, blocks: rm.reportBlocks, requestedVF: { rm.requestedVolumeFraction(of: $0) })
            XCTAssertTrue(rows.first?.title.hasPrefix("a · ") == true, "\(what): the lines are results a, b, c: \(rows.map(\.title))")
            let pick = try XCTUnwrap(h.frames.all["resultsPickThis"], "\(what): ★ Pick this on the selected line")
            XCTAssertGreaterThanOrEqual(pick.height, 43.5); XCTAssertGreaterThanOrEqual(pick.width, 43.5)
            let panel = try XCTUnwrap(h.frames.all["resultsVersions"])
            XCTAssertTrue(panel.contains(pick), "\(what): inside the panel")
            ui.click(h, CGPoint(x: pick.midX, y: pick.midY))
            let sel = try XCTUnwrap(rm.tabs.first { $0.index == rm.selectedIndex })
            XCTAssertEqual(picks.all, [sel.variantIndex], "\(what): ★ Pick this picks the selected result")
        }
    }

    func testThePickedLineSaysSoAndOffTheLibraryThereIsNoPick() throws {
        let (h, rm) = try screen(AppBuildHost.landscape13, version: "v7", picked: 0, picks: Picks())
        let first = try XCTUnwrap(rm.tabs.first { $0.variantIndex == 0 && !$0.isLatticed })
        XCTAssertNotNil(h.frames.all["resultsPicked-t\(first.index)"], "★ the picked line reads Picked ✓")
        let (h2, _) = try screen(AppBuildHost.landscape13, version: nil, picked: nil, picks: nil)
        XCTAssertNil(h2.frames.all["resultsPickThis"], "★ off the Library: no ring to set, no Pick this")
    }

    /// ★ LOOK PER SCREEN (R-b, mockup #topo-results): the panel is §4.3's (348 pt), each result ONE 48 pt line — "a · Just safe
    /// ·· 87 g · 1.5× [Pick this]" — with Pick this on every line not picked (the reviewer's chosen answer, 11-04 02:44Z: Pick this
    /// sets the part's chosen result) and the selected line in the accent edge. RED before R-b (scratchpad
    /// b2red/ResultsPanelRows.txt): 340 pt, two-line rows, Pick this on the selected line only.
    func testTheResultsPanelIsThePanelWithOneLineRows() throws {
        for size in [AppBuildHost.landscape13, CGSize(width: 820, height: 1180)] {
            let picks = Picks()
            let (h, rm) = try screen(size, version: "v7", picked: nil, picks: picks)
            let panel = try XCTUnwrap(h.frames.all["resultsVersions"])
            XCTAssertEqual(panel.width, DSParts.panelWidth, accuracy: 0.5, "\(size): ★ 348 pt (U2)")
            XCTAssertEqual(try XCTUnwrap(h.frames.all["resultsVersionsHeader"], "\(size): §4.3's header").height,
                           DSParts.headerHeight, accuracy: 0.5)
            let solids = rm.tabs.filter { !$0.isLatticed }
            XCTAssertGreaterThanOrEqual(solids.count, 2, "premise")
            for t in solids {
                let row = try XCTUnwrap(h.frames.all["resultsVersion-t\(t.index)"], "\(size): the line of result \(t.index)")
                XCTAssertEqual(row.height, DSParts.rowHeight, accuracy: 0.5, "\(size): ★ one 48 pt line (\(row))")
                let key = t.index == rm.selectedIndex ? "resultsPickThis" : "resultsPickThis-t\(t.index)"
                let chip = try XCTUnwrap(h.frames.all[key], "\(size): ★ Pick this on line \(t.index)")
                XCTAssertTrue(row.insetBy(dx: -0.5, dy: -0.5).contains(CGPoint(x: chip.midX, y: chip.midY)), "\(size): on its line")
            }
            // Pick this on a line that is not selected picks THAT result
            let other = try XCTUnwrap(solids.first { $0.index != rm.selectedIndex })
            let chip = try XCTUnwrap(h.frames.all["resultsPickThis-t\(other.index)"])
            ui.click(h, CGPoint(x: chip.midX, y: chip.midY))
            XCTAssertEqual(picks.all, [other.variantIndex], "\(size): ★ its own result")
        }
    }

    /// The Library numbers results over all variants; Results over the accepted ones.
    func testTheIndexCrossing() {
        func v(_ ok: Bool) -> OptimizeVariant {
            OptimizeVariant(requestedVolumeFraction: 0.5, achievedVolumeFraction: 0.5, massGrams: 1, supportVolumeVoxels: 0,
                            meshTriangleCount: 1, worstCaseMargin: 2, accepted: ok, v3Passes: ok,
                            meshVertices: [0, 0, 0, 1, 0, 0, 0, 1, 0], meshIndices: [0, 1, 2])
        }
        let o = OptimizeOutcome(variants: [v(true), v(false), v(true)], stoppedOnMargin: false, cancelled: false, acceptedCount: 2,
                                voxelVolumeMM3: 1, gridNx: 2, gridNy: 2, gridNz: 2, gridOrigin: .zero, spacing: 1)
        XCTAssertEqual(ResultsPick.all(1, in: o), 2, "accepted #1 is the Library's result 2")
        XCTAssertEqual(ResultsPick.accepted(2, in: o), 1)
        XCTAssertNil(ResultsPick.accepted(1, in: o), "a rejected variant is never a pick")
        XCTAssertNil(ResultsPick.all(5, in: o))
    }
}
#endif
