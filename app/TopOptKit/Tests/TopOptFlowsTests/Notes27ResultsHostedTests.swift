// Notes27ResultsHostedTests — ★ his iPad notes 2026-11-23 ~23:45 on release 17, builder F ("results27"), on HIS two iPad sizes,
// hosted offscreen (never the app):
//   F3 "The "v8.1 results" list's corner radius cuts into the selected row's highlight radius": the list's corners are concentric
//      with the highlight's — the selected line's outline sits inside the list's inner rounded rect, its corners on the list's.
//   F2 Details › Strength: each row plain, its detail behind an (i) — a finger's size, inside the drawer, opening the centred card.
#if canImport(AppKit) && canImport(MetalKit)
import XCTest
import SwiftUI
import AppKit
@testable import TopOptFlows
@testable import TopOptKit

@MainActor
final class Notes27ResultsHostedTests: XCTestCase {
    let ui = LoadScenarioHostedTests()
    static let sizes = [AppBuildHost.landscape13, CGSize(width: 820, height: 1180)]

    override func tearDown() {
        MainActor.assumeIsolated { AppPopups.shared.current = nil }
        super.tearDown()
    }

    func frame(_ h: LoadScenarioHostedTests.Host, _ k: String) throws -> CGRect {
        let f = try XCTUnwrap(h.frames.all[k], "★ '\(k)' is not on the screen; frames: \(h.frames.all.keys.sorted())")
        XCTAssertTrue(CGRect(origin: .zero, size: h.size).insetBy(dx: -1, dy: -1).contains(f), "★ '\(k)' leaves the window: \(f)")
        return f
    }

    /// Whether `q` lies inside `r` with corners of radius `rho` (within `tol`).
    static func inside(_ q: CGPoint, _ r: CGRect, _ rho: CGFloat, tol: CGFloat = 0.5) -> Bool {
        guard r.insetBy(dx: -tol, dy: -tol).contains(q) else { return false }
        let cx = Swift.min(Swift.max(q.x, r.minX + rho), r.maxX - rho), cy = Swift.min(Swift.max(q.y, r.minY + rho), r.maxY - rho)
        return hypot(q.x - cx, q.y - cy) <= rho + tol
    }

    /// Points along a rounded rect's outline (its four corner arcs and its sides).
    static func outline(_ r: CGRect, _ rho: CGFloat) -> [CGPoint] {
        var out: [CGPoint] = []
        let corners = [(CGPoint(x: r.minX + rho, y: r.minY + rho), CGFloat.pi), (CGPoint(x: r.maxX - rho, y: r.minY + rho), 1.5 * .pi),
                       (CGPoint(x: r.maxX - rho, y: r.maxY - rho), 0), (CGPoint(x: r.minX + rho, y: r.maxY - rho), 0.5 * .pi)]
        for (c, a0) in corners {
            for k in 0...12 {
                let a = a0 + CGFloat(k) / 12 * (.pi / 2)
                out.append(CGPoint(x: c.x + rho * cos(a), y: c.y + rho * sin(a)))
            }
        }
        // the straight sides, between the corner arcs
        for k in 0...20 {
            let t = CGFloat(k) / 20
            let x = r.minX + rho + t * (r.width - 2 * rho), y = r.minY + rho + t * (r.height - 2 * rho)
            out += [CGPoint(x: x, y: r.minY), CGPoint(x: x, y: r.maxY), CGPoint(x: r.minX, y: y), CGPoint(x: r.maxX, y: y)]
        }
        return out
    }

    /// ★ F3: his one-line "v8.1 results" list — its line selected, its highlight meeting the list's bottom corners.
    func testTheSelectedLinesHighlightSitsInsideTheListsInnerRoundedRect() throws {
        let inset = DSParts.rowHighlightInset, hr = DSParts.rowHighlightRadius
        XCTAssertEqual(ResultsVersionsPanel.radius, hr + inset, "★ concentric: the list's radius = the highlight's + the space between")
        for size in Self.sizes {
            let rm = try Notes27Fixture.model()
            let o = try LatticeFileButton.outcome(try Notes27Fixture.made(), densityGCm3: 1.01, organic: true)
            let h = ui.host(ResultsScreen(projectName: "2040 Extrusion Stand copy", outcome: o, undo: {}, redo: {}, resultsModel: rm,
                                          version: "v8.1")
                                .frame(width: size.width, height: size.height), size: size)
            ui.pump(2)
            let list = try frame(h, "resultsVersions")
            let rows = ResultsVersions.rows(tabs: rm.tabs, blocks: rm.reportBlocks, requestedVF: { rm.requestedVolumeFraction(of: $0) })
            let sel = try XCTUnwrap(rows.first { $0.tabIndex == rm.selectedIndex }, "premise: a selected line")
            let row = try frame(h, "resultsVersion-\(sel.id)")
            XCTAssertEqual(row.maxY, list.maxY, accuracy: 1, "\(size): premise — the selected line is the list's last (its corners)")
            XCTAssertEqual(row.minX, list.minX, accuracy: 1, "\(size): premise — the line runs the list's width")
            let highlight = row.insetBy(dx: inset, dy: inset)
            let inner = list.insetBy(dx: inset, dy: inset)
            let pts = Self.outline(highlight, hr)
            let out = pts.filter { !Self.inside($0, inner, ResultsVersionsPanel.radius - inset) }
            XCTAssertTrue(out.isEmpty, "\(size): ★ the highlight sits inside the list's inner rounded rect (\(out.count) points out)")
            // its bottom corners ARE the list's, one inset in: the same centres
            XCTAssertEqual(highlight.maxY - hr, list.maxY - ResultsVersionsPanel.radius, accuracy: 1, "\(size): ★ concentric")
            // RED CONTROL: §4.3's 22 pt corners cut into it (release 17)
            let cut = pts.filter { !Self.inside($0, inner, DSParts.panelRadius - inset) }
            XCTAssertFalse(cut.isEmpty, "RED CONTROL: with the old 22 pt corners the list cuts the highlight's corners")
            XCTAssertEqual(ResultsVersionsPanel.title("v8.1"), "v8.1 results")
            try ui.picture(h, "notes27_list_\(Int(size.width))x\(Int(size.height)).png")
        }
    }

    /// ★ F3 on a list of several results: the last line selected (by a tap, as he would) sits inside the list too.
    func testTheLastOfSeveralResultsSitsInsideTheListWhenSelected() throws {
        for size in Self.sizes {
            let o = try ResultsRedesignTests.strengthenOutcome()
            let rm = ResultsModel(projectName: "CarriageArms", outcome: o)
            let h = ui.host(ResultsScreen(projectName: "CarriageArms", outcome: o, undo: {}, redo: {}, resultsModel: rm, version: "v7")
                                .frame(width: size.width, height: size.height), size: size)
            ui.pump(2)
            let rows = ResultsVersions.rows(tabs: rm.tabs, blocks: rm.reportBlocks, requestedVF: { rm.requestedVolumeFraction(of: $0) })
            let last = try XCTUnwrap(rows.last { $0.tabIndex != nil })
            let line = try frame(h, "resultsVersion-\(last.id)")
            ui.click(h, CGPoint(x: line.minX + 40, y: line.midY))
            XCTAssertEqual(rm.selectedIndex, last.tabIndex, "\(size): premise — the tap selects it")
            let list = try frame(h, "resultsVersions"), row = try frame(h, "resultsVersion-\(last.id)")
            let inset = DSParts.rowHighlightInset
            let out = Self.outline(row.insetBy(dx: inset, dy: inset), DSParts.rowHighlightRadius)
                .filter { !Self.inside($0, list.insetBy(dx: inset, dy: inset), ResultsVersionsPanel.radius - inset) }
            XCTAssertTrue(out.isEmpty, "\(size): ★ the highlight inside the list's inner rounded rect (\(out.count) points out)")
        }
    }

    /// ★ F2: Details › Strength — "Weakest spot · A strut" with its (i) (a finger's size, inside the drawer), which opens the centred
    /// card with the detail; "Lattice carries" and "Strengthened" with theirs.
    func testDetailsRowsCarryTheirIAndItOpensTheCard() throws {
        for size in Self.sizes {
            AppPopups.shared.current = nil
            let rm = try Notes27Fixture.model()
            let o = try LatticeFileButton.outcome(try Notes27Fixture.made(), densityGCm3: 1.01, organic: true)
            let h = ui.host(ResultsScreen(projectName: "Stand", outcome: o, undo: {}, redo: {}, resultsModel: rm)
                                .frame(width: size.width, height: size.height), size: size)
            ui.pump(2)
            let button = try frame(h, "resultsDetailsButton")
            ui.click(h, CGPoint(x: button.midX, y: button.midY))
            let drawer = try frame(h, "resultsDetailsPanel")
            for label in ["Weakest spot", "Lattice carries", "Strengthened"] {
                let i = try frame(h, "resultsDetailInfo-" + label)
                XCTAssertGreaterThanOrEqual(i.width, 43.5, "\(size): ★ '\(label)' (i) is a finger's size")
                XCTAssertGreaterThanOrEqual(i.height, 43.5)
                XCTAssertTrue(drawer.insetBy(dx: -0.5, dy: -0.5).contains(i), "\(size): ★ '\(label)' (i) inside the drawer")
            }
            let i = try frame(h, "resultsDetailInfo-Weakest spot")
            ui.click(h, CGPoint(x: i.midX, y: i.midY))
            let card = try XCTUnwrap(AppPopups.shared.current, "\(size): ★ the (i) opens the centred card")
            XCTAssertEqual(card.title, "Weakest spot")
            XCTAssertTrue(card.info, "an explanation, not an error")
            XCTAssertEqual(card.text, rm.latticeAnswer?.weakestSpotInfo)
            try ui.picture(h, "notes27_details_\(Int(size.width))x\(Int(size.height)).png")
            AppPopups.shared.current = nil
        }
    }

    /// ★ his 11-24: the Strengthened row opened in Checks — the stress map off — lights the struts it changed, and its open text
    /// says what the gold is, inside the Checks panel, at both sizes.
    func testTheStrengthenedRowOpensWithItsLegend() throws {
        for size in Self.sizes {
            let bars = Notes27ColourRulesTests.flaggedBars([PrintFileParts.thickenedBit, 0, PrintFileParts.braceBit, 0])
            let o = try Notes27ColourRulesTests.outcome(bars: bars)
            let rm = ResultsModel(projectName: "Stand", outcome: o, materialName: "PA12", yieldStrengthMPa: 38, appliedLoadKg: 41,
                                  infillPercent: 50, infillPattern: "gyroid", materialDensityGCm3: 1.01)
            let h = ui.host(ResultsScreen(projectName: "Stand", outcome: o, undo: {}, redo: {}, resultsModel: rm)
                                .frame(width: size.width, height: size.height), size: size)
            ui.pump(2)
            XCTAssertNil(h.frames.all["resultsStressKey"], "\(size): premise — the stress map is off")
            let title = "Strengthened · 6 rounds"
            let line = try frame(h, "resultsCheck-" + title)
            ui.click(h, CGPoint(x: line.midX, y: line.midY))
            let text = try frame(h, "resultsCheckMoreText-" + title)
            XCTAssertTrue(try frame(h, "resultsChecks").insetBy(dx: -0.5, dy: -0.5).contains(text), "\(size): inside Checks")
            let check = rm.withStrengthenedLegend(try XCTUnwrap(rm.reportBlocks?.printFile?.checks.first { $0.title == title }))
            XCTAssertTrue(check.more?.contains(ResultsModel.strengthenedLegend) == true, "\(size): ★ its legend: \(check.more ?? "")")
            XCTAssertNotNil(rm.strengthenedTints(for: try XCTUnwrap(rm.selectedMesh)), "\(size): ★ the struts it changed, lit")
            try ui.picture(h, "notes27_strengthened_\(Int(size.width))x\(Int(size.height)).png")
        }
    }
}
#endif
