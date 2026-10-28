// FlexibleRound7D1ReviewTests — round 7, the REVIEW of batch R7-D1 (2026-10-17), the pure half. What the two-angle review
// of his pick 1 on the Flexible stage found, each a test written FIRST (red at 999c6025, the D1 handoff), with its RED
// control inside:
//   P1  (the blocker) in portrait, with the Setup card or the Lattice card open and Play on, the squish player climbed under
//       the orientation cube (13" (526,174) on the cube (808,14 210x210); 11" half the scrubber hidden). It reserved the
//       panels' whole possible column, and nothing kept it off the cube or the capsule. His rule: nothing covering a button.
//   L1  in landscape the open card sat on the one legend card (11" landscape: the whole key hidden). The mockup he picked
//       puts the legend under the views row (top 292) and every panel below it.
//   PL  "Plate up › Change" showed #354's BuildOrientationView: paragraphs, 40 × 28 pt axis chips, "Down in service +Z" over
//       a chip that says gravity is −Z. The mockup's page: ONE question line over a 2 × 3 grid of big buttons, +Z lit.
//   ST  the card's secondary sends and the callout's second fix were drawn with no edge — they read as text (his B1(c) words:
//       "looks like it is just noting … when in fact it's a button").
//   PV  ① named "2 face-prisms"; the mockup names them ("Face 3 + Face 5"). The Squish page's panel said "● Flexible" right
//       under the capsule that says Flexible (the mockup: "Flexible · Squish").
#if canImport(AppKit)
import XCTest
import SwiftUI
import AppKit
import simd
import TopOptDesign
@testable import TopOptFlows
@testable import TopOptKit

@MainActor
final class FlexibleRound7D1ReviewTests: XCTestCase {

    static let sizes: [(String, CGSize)] = [("13p", CGSize(width: 1032, height: 1376)), ("13l", CGSize(width: 1376, height: 1032)),
                                            ("11p", CGSize(width: 834, height: 1194)), ("11l", CGSize(width: 1194, height: 834))]
    /// The panels as his pad draws them (D1's frames, measured on his pad: the Setup tray 276, the Preview card 412, the
    /// blocker callout 151).
    static let panels: [(FlexibleChromeState.Card, CGFloat)] = [(.setup, 276), (.latticeCard, 412), (.callout, 151)]

    // MARK: - P1: the player never goes under the cube, the views, the capsule or an open panel

    func testThePlayerNeverGoesUnderTheCubeTheViewsTheCapsuleOrAnOpenPanel() throws {
        var lines: [String] = []
        for (tag, v) in Self.sizes {
            for (card, h) in Self.panels {
                let s = FlexibleMainStage()
                s.chromeGeometry.note(v)
                s.chromeGeometry.notePanel(h)
                s.chrome.show(card)
                let p = try XCTUnwrap(FlexibleMainPlayerSlot.place(main: s, viewport: v, bottomClearance: FlexibleChromeLayout.barClearance,
                                                                   chipColumnWidth: 0, size: FlexibleLegendPlacement.playerSize),
                                      "\(tag) \(card): the player has a place")
                let panel = FlexibleChromeLayout.panelFrame(viewport: v, contentHeight: h, legend: nil)
                let avoid: [(String, CGRect)] = [("the cube", FlexibleLegendPlacement.gizmoFrame(viewport: v)),
                                                 ("the views row", FlexibleMainViewToggles.frame(viewport: v)),
                                                 ("the name row and the capsule", FlexibleChromeLayout.topLeftChrome(v)),
                                                 ("the open panel", panel)]
                for (what, k) in avoid {
                    XCTAssertFalse(p.intersects(k), "★ \(tag), \(card) open, Play on: the player \(p.integral) is clear of \(what) \(k.integral)")
                }
                // where the mockup puts it: beside the panel on the bottom row when there is room, else right above it
                if v.width > v.height {
                    XCTAssertEqual(p.maxY, v.height - FlexibleChromeLayout.barClearance - PageChrome.gap, accuracy: 0.5,
                                   "\(tag) \(card): landscape keeps the player on its bottom row, left of the panel")
                } else {
                    XCTAssertLessThanOrEqual(p.maxY, panel.minY - PageChrome.gap + 0.5,
                                             "\(tag) \(card): portrait has no room beside it (the Selections column) — right above the panel")
                    XCTAssertGreaterThan(p.minY, panel.minY - 200, "\(tag) \(card): …close above it, never climbing to the top")
                }
                lines.append("\(tag) \(card) (\(Int(h)) tall): player \(p.integral) · panel \(panel.integral)")
            }
        }
        print("FLEX-R7D1R-P1\n" + lines.joined(separator: "\n"))
        // RED CONTROL: D1's keep-out — the panels' WHOLE possible column, no cube — climbs under the cube at 13" portrait
        let v = Self.sizes[0].1
        let column = CGRect(x: v.width - 24 - 420, y: FlexibleChromeLayout.panelTopLimit(v), width: 420, height: FlexibleChromeLayout.panelMaxHeight(v))
        let keep = [FlexibleMainViewToggles.frame(viewport: v), FlexibleMainLegendLayout.leftStrip(viewport: v), column]
        let red = try XCTUnwrap(FlexibleLegendPlacement.player(viewport: v, bottomClearance: FlexibleChromeLayout.barClearance, keepOut: keep))
        XCTAssertTrue(red.intersects(FlexibleLegendPlacement.gizmoFrame(viewport: v)), "★ RED CONTROL: D1's keep-out puts the player on the cube (\(red.integral))")
    }

    // MARK: - L1: the legend under the views row; no panel ever covers it

    func testTheMainLegendSitsUnderTheViewsRowAndNoPanelCoversIt() throws {
        var lines: [String] = []
        for (tag, v) in Self.sizes + [("minip", CGSize(width: 744, height: 1133))] {
            let keep = FlexibleMainLegendLayout.keepOut(viewport: v, bottomClearance: FlexibleChromeLayout.barClearance, chipColumnWidth: 0)
            for rows in [1, 2] {
                for folded in [false, true] {
                    let legend = try XCTUnwrap(FlexibleMainLegendLayout.placeMainCard(rows: rows, minimized: folded, viewport: v, keepOut: keep),
                                               "\(tag): the legend has a place")
                    // under the views row (and the note band under it at 11" portrait), one gap below, on the right edge
                    XCTAssertEqual(legend.frame.minY, FlexibleMainViewToggles.frame(viewport: v).maxY + PageChrome.gap, accuracy: 4,
                                   "★ \(tag) rows \(rows) folded \(folded): the legend sits right under the views row (the mockup: top 292)")
                    XCTAssertEqual(legend.frame.maxX, v.width - (folded ? FlexibleMainLegendLayout.foldedEdge : PageChrome.edge), accuracy: 1,
                                   "\(tag): on the right edge")
                    for (card, h) in Self.panels {
                        let panel = FlexibleChromeLayout.panelFrame(viewport: v, contentHeight: h, legend: legend.frame)
                        XCTAssertGreaterThanOrEqual(panel.minY, legend.frame.maxY + PageChrome.gap - 0.5,
                                                    "★ \(tag) rows \(rows) folded \(folded): the open \(card) \(panel.integral) stays under the legend \(legend.frame.integral)")
                        XCTAssertEqual(panel.maxY, v.height - PageChrome.edge - PageChrome.actionButton - PageChrome.gap, accuracy: 0.5,
                                       "\(tag): the panel's foot stays 12 above the pair")
                    }
                    if rows == 1, !folded {
                        let card = FlexibleChromeLayout.panelFrame(viewport: v, contentHeight: 412, legend: legend.frame)
                        lines.append("\(tag): legend \(legend.frame.integral) · the card \(card.integral)\(card.height < 412 ? " (scrolls: \(Int(card.height)) of 412)" : "")")
                    }
                }
            }
        }
        print("FLEX-R7D1R-L1\n" + lines.joined(separator: "\n"))
        // RED CONTROL: D1's legend (batch M's, from the vertical centre) under D1's panel at 11" landscape — the card covers it
        let v = CGSize(width: 1194, height: 834)
        let keep = FlexibleMainLegendLayout.keepOut(viewport: v, bottomClearance: FlexibleChromeLayout.barClearance, chipColumnWidth: 0)
        let old = try XCTUnwrap(FlexibleMainLegendLayout.placeCard(rows: 1, minimized: false, viewport: v, keepOut: keep))
        let d1Panel = FlexibleChromeLayout.panel(viewport: v, setupWidth: 0, contentHeight: 412).frame
        XCTAssertTrue(d1Panel.intersects(old.frame), "★ RED CONTROL: D1's centred legend \(old.frame.integral) under the card \(d1Panel.integral)")
    }

    // MARK: - PL: Plate up is one question and six big buttons

    func project(plateUp: SIMD3<Float>? = nil) -> ProjectModel {
        let p = ProjectModel(id: UUID(), name: "Pad 100 x 100 x 20 (Flexible)", material: "ABS", process: .fdm, importedFile: nil, importedMesh: nil)
        p.lattice.flexible = FlexibleStageSettings()
        p.force.setGravity(direction: SIMD3<Float>(0, 0, -1))
        p.buildOrientation = BuildOrientation(plateUp: plateUp)
        return p
    }

    func testThePlatePageIsOneQuestionAndSixBigButtonsWithTheResolvedOneLit() throws {
        let p = project()
        XCTAssertEqual(FlexiblePlatePage.question, "Which side faces up, away from the plate?", "the mockup's one line")
        XCTAssertLessThanOrEqual(FlexiblePlatePage.question.count, 44, "one line (his rule)")
        let c = FlexiblePlatePage.choices(orientation: p.buildOrientation, gravity: p.force.gravity)
        XCTAssertEqual(c.map(\.label), ["+Z", "\u{2212}Z", "+X", "\u{2212}X", "+Y", "\u{2212}Y"], "the mockup's six, in its order (a 2 × 3 grid)")
        XCTAssertEqual(c.filter(\.lit).map(\.label), ["+Z"], "★ the resolved direction is lit (gravity −Z ⇒ +Z up, assumed)")
        XCTAssertEqual(FlexiblePlatePage.stateLine(orientation: p.buildOrientation, gravity: p.force.gravity), "+Z \u{00B7} assumed from gravity")
        // a pick: lit, said as his choice, and one tap back to assumed
        FlexiblePlatePage.pick(SIMD3<Float>(-1, 0, 0), project: p)
        XCTAssertEqual(p.buildOrientation.plateUp, SIMD3<Float>(-1, 0, 0))
        XCTAssertEqual(FlexiblePlatePage.choices(orientation: p.buildOrientation, gravity: p.force.gravity).filter(\.lit).map(\.label), ["\u{2212}X"])
        XCTAssertEqual(FlexiblePlatePage.stateLine(orientation: p.buildOrientation, gravity: p.force.gravity), "\u{2212}X \u{00B7} you chose this")
        FlexiblePlatePage.assume(project: p)
        XCTAssertTrue(p.buildOrientation.isInferredFromGravity, "★ 'Assume from gravity' takes the choice back")
        for line in [FlexiblePlatePage.stateLine(orientation: BuildOrientation(plateUp: SIMD3(0, -1, 0)), gravity: SIMD3(0, 0, -1)),
                     FlexiblePlatePage.assumeTitle] {
            XCTAssertLessThanOrEqual(line.count, 44, "'\(line)': one line")
        }
        // ★ the tray no longer embeds #354's BuildOrientationView (Topology keeps it, untouched)
        let tray = try FlexibleSource.code("FlexibleSetupTray.swift")
        XCTAssertFalse(tray.contains("BuildOrientationView("), "★ the Flexible plate page is its own (RED at D1: #354's view in the tray)")
        XCTAssertTrue(tray.contains("FlexiblePlatePageView("), "the tray draws the Flexible plate page")
        let orient = try FlexibleSource.code("BuildOrientationView.swift")
        XCTAssertTrue(orient.contains("Text(\"Down in service\")") || orient.contains("title: \"Down in service\""), "(#354's view is untouched)")
    }

    // MARK: - ST: a secondary button has an edge

    func testSecondaryButtonsInTheCardAndTheCalloutAreOutlined() throws {
        // the card's sends after the first (FlexibleExportRows.FixRow) and the callout's second fix (FlexibleCornerPairStyle.big)
        let rows = try FlexibleSource.code("FlexibleExportRows.swift")
        let pair = try FlexibleSource.code("FlexibleCornerPair.swift")
        XCTAssertTrue(rows.contains("FlexibleCornerPairStyle.secondaryEdge(i == 0)"), "★ the card's secondary sends wear the hairline (RED at D1: a fill alone)")
        XCTAssertTrue(pair.contains("FlexibleCornerPairStyle.secondaryEdge(primary)"), "★ the callout's secondary fix wears the hairline")
        XCTAssertTrue(pair.contains("DS.Color.strokeStrong"), "the hairline is the strong stroke (FlexibleCornerPairStyle.small's)")
        XCTAssertEqual(FlexibleCornerPairStyle.secondaryEdgeWidth, 1, "a 1 pt hairline")
    }

    // MARK: - PV: ① names the faces; the Squish panel says "Flexible · Squish"

    func testThePreviewStepNamesTheFacesAndTheSquishPanelSaysSquish() throws {
        let inc = { (face: Int, depth: Double) -> LatticeRegionSpec in
            var r = LatticeRegionSpec(role: .include, kind: .face)
            r.depthMM = depth
            r.faceID = face
            return r
        }
        XCTAssertEqual(FlexibleLatticeCard.previewLine(includes: [inc(3, 25), inc(5, 25)]), "built \u{00B7} Face 3 + Face 5 \u{00B7} 25.0 mm",
                       "★ ① names the faces, as the mockup does (RED at D1: '2 face-prisms')")
        XCTAssertEqual(FlexibleLatticeCard.previewLine(includes: [inc(1, 20)]), "built \u{00B7} Face 1 \u{00B7} 20.0 mm")
        let four = FlexibleLatticeCard.previewLine(includes: [inc(1, 20), inc(2, 20), inc(3, 25), inc(4, 25)])
        XCTAssertEqual(four, "built \u{00B7} 4 face-prisms \u{00B7} 20.0 / 25.0 mm", "more than two: the count (one line)")
        var piece = inc(7, 10); piece.sectorPiece = true; piece.faceID = nil
        XCTAssertEqual(FlexibleLatticeCard.previewLine(includes: [piece]), "built \u{00B7} 1 face-prism \u{00B7} 10.0 mm", "a split piece has no face name")
        for l in [four] { XCTAssertLessThanOrEqual(l.count, 44) }
        XCTAssertEqual(FlexibleSettingsPanel.title, "Flexible \u{00B7} Squish", "★ the Squish page's panel says the page (the mockup's words)")
        let panel = try FlexibleSource.code("FlexibleSettingsPanel.swift")
        XCTAssertTrue(panel.contains("Text(Self.title)"), "the header draws it")
    }
}
#endif
