// FlexibleLegendPlacementTests — "the legend never covers a button" and the squish player
// never covers a button or a legend (task 2026-09-29-flexible-screens, round 3 batch B, item
// 7; maintainer: "legends never cover buttons"). Measured at iPad 13" and 11", both
// orientations, on BOTH pages, against each page's real chrome:
//   * Settings: the panel (bottom-left, ≤ 62 % high), the legend (trailing, centred), the top
//     row (Exit, undo, redo), the readiness line, the gizmo;
//   * main: the bottom bar with the status pill, the Settings button, the view toggles.
// RED CONTROL: the old bottom-trailing legend covers the old Generate pill (img 7).
import XCTest
import CoreGraphics
import TopOptDesign
@testable import TopOptFlows

final class FlexibleLegendPlacementTests: XCTestCase {

    /// iPad Pro 13" and iPad Pro 11" (points), portrait and landscape.
    static let viewports: [(String, CGSize)] = [
        ("13\" portrait", CGSize(width: 1032, height: 1376)), ("13\" landscape", CGSize(width: 1376, height: 1032)),
        ("11\" portrait", CGSize(width: 834, height: 1194)), ("11\" landscape", CGSize(width: 1194, height: 834)),
    ]
    static let legendSize = CGSize(width: 236 + 2 * 14, height: 118)
    let e = PageChrome.edge

    /// The Settings page's chrome at `v`.
    func settingsChrome(_ v: CGSize) -> [String: CGRect] {
        let panelH = v.height * 0.62
        var k: [String: CGRect] = [
            "panel": CGRect(x: e, y: v.height - e - panelH, width: 400, height: panelH),
            "exitRow": CGRect(x: e, y: e, width: 240, height: 44),
            "notice": CGRect(x: 180, y: e + 6, width: v.width - 360, height: 34),
            "gizmo": CGRect(x: v.width - PageChrome.gizmoInset - PageChrome.gizmoSize, y: PageChrome.gizmoInset,
                            width: PageChrome.gizmoSize, height: PageChrome.gizmoSize),
        ]
        k["legend"] = FlexibleLegendPlacement.legend(size: Self.legendSize, viewport: v, keepOut: Array(k.values))
        return k
    }

    /// The main page's chrome at `v` (the bottom bar measured at its one-line height).
    func mainChrome(_ v: CGSize) -> (keepOut: [String: CGRect], bottomClearance: CGFloat) {
        let bar: CGFloat = 50, clearance = bar + DS.Space.xl4
        return ([
            "bottomBar": CGRect(x: 0, y: v.height - clearance, width: v.width, height: clearance),
            "statusPill": CGRect(x: v.width - e - 460, y: v.height - DS.Space.xl4 - bar, width: 220, height: bar),
            "settingsButton": CGRect(x: v.width - PageChrome.gizmoClearance - 150, y: DS.Space.xl3, width: 140, height: 44),
            "viewToggles": FlexibleMainViewToggles.frame(viewport: v),
            "gizmo": CGRect(x: v.width - PageChrome.gizmoInset - PageChrome.gizmoSize, y: PageChrome.gizmoInset,
                            width: PageChrome.gizmoSize, height: PageChrome.gizmoSize),
        ], clearance)
    }

    private func clearOf(_ r: CGRect, _ k: [String: CGRect], _ what: String, _ at: String) {
        for (name, b) in k where b.intersects(r) {
            XCTFail("\(what) at \(at) covers \(name): \(r) ∩ \(b)")
        }
    }

    func testTheSettingsPagesPlayerAndLegendCoverNothing() throws {
        for (name, v) in Self.viewports {
            let k = settingsChrome(v)
            let legend = try XCTUnwrap(k["legend"], "a legend place at \(name)")
            XCTAssertEqual(legend.maxX, v.width - e, accuracy: 0.5, "trailing")
            clearOf(legend, k.filter { $0.key != "legend" }, "the legend", name)
            // the player computed the page's way (FlexibleStagePage.playerKeepOut's frames)
            let p = try XCTUnwrap(FlexibleLegendPlacement.player(viewport: v, bottomClearance: e,
                                                                keepOut: ["panel", "legend", "exitRow", "notice"].compactMap { k[$0] }),
                                  "a player place at \(name)")
            print("FLEX-PLACE settings \(name): legend \(legend.integral) · player \(p.integral)")
            XCTAssertGreaterThanOrEqual(p.width, FlexibleLegendPlacement.playerMinWidth)
            XCTAssertTrue(CGRect(origin: .zero, size: v).contains(p), "on screen")
            clearOf(p, k, "the player", name)
        }
    }

    func testTheMainPagesPlayerCoversNoButtonNorTheLegendSlot() throws {
        for (name, v) in Self.viewports {
            let (k, clearance) = mainChrome(v)
            let keep = FlexibleMainPlayerSlot.keepOut(viewport: v)
            let p = try XCTUnwrap(FlexibleLegendPlacement.player(viewport: v, bottomClearance: clearance, keepOut: keep),
                                  "a player place at \(name)")
            let legend = try XCTUnwrap(FlexibleLegendPlacement.legend(size: FlexibleMainPlayerSlot.legendSize, viewport: v))
            print("FLEX-PLACE main \(name): player \(p.integral) · legend slot \(legend.integral)")
            // ★ RE-PINNED (batch C verification): bottom-centre of the page — unless that would sit
            // in the Selections column (13" / 11" portrait), then centred in the free span right of it
            let strip = FlexibleMainLegendLayout.leftStrip(viewport: v)
            XCTAssertFalse(p.intersects(strip), "clear of the Selections column at \(name)")
            if (v.width - p.width) / 2 >= strip.maxX + FlexibleLegendPlacement.gap {
                XCTAssertEqual(p.midX, v.width / 2, accuracy: 0.5, "bottom-centre")
            } else {
                XCTAssertEqual(p.midX, (strip.maxX + FlexibleLegendPlacement.gap + v.width - e) / 2, accuracy: 0.5,
                               "centred right of the Selections column")
            }
            clearOf(p, k.merging(["legend": legend]) { a, _ in a }, "the player", name)
            clearOf(legend, k.merging(["player": p]) { a, _ in a }, "the legend slot", name)
        }
    }

    func testTheOldBottomCornerLegendCoveredGenerate() {
        // ★ RED CONTROL (img 7): bottom-trailing on the page edge, over the Generate pill
        let v = CGSize(width: 1194, height: 834)
        let old = CGRect(x: v.width - e - Self.legendSize.width, y: v.height - e - Self.legendSize.height,
                         width: Self.legendSize.width, height: Self.legendSize.height)
        let generate = CGRect(x: v.width - e - 210, y: v.height - e - 44, width: 210, height: 44)
        XCTAssertTrue(old.intersects(generate), "control: the old placement covered Generate")
        // …and the placement's own rule moves a legend off a keep-out it would cover
        let moved = FlexibleLegendPlacement.legend(size: Self.legendSize, viewport: v,
                                                   keepOut: [CGRect(x: v.width - 300, y: v.height / 2 - 20, width: 300, height: 40)])
        XCTAssertNotNil(moved)
        XCTAssertFalse(moved!.intersects(CGRect(x: v.width - 300, y: v.height / 2 - 20, width: 300, height: 40)))
    }

    func testThePagesUseThePlacement() throws {
        let page = try FlexibleSource.code("FlexibleStagePage.swift")
        XCTAssertTrue(page.contains("FlexibleLegendPlacement.player(viewport: size, bottomClearance: PageChrome.edge,"),
                      "the Settings page computes the player's frame")
        XCTAssertTrue(page.contains("return [\"panel\", \"legend\", \"exitRow\", \"notice\"].compactMap"),
                      "…against the panel, the legend, the top row and the readiness line")
        XCTAssertFalse(page.contains("latticeControls"), "no bottom-right buttons on the Settings page")
        let pill = try FlexibleSource.code("FlexibleMainStatusPill.swift")
        XCTAssertTrue(pill.contains("FlexibleLegendPlacement.player(viewport: g.size, bottomClearance: bottomClearance,"),
                      "the main page computes the player's frame")
    }
}
