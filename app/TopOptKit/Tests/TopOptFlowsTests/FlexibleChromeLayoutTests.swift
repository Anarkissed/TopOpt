// FlexibleChromeLayoutTests — round 7, batch R7-D1 (his pick 1: A2's capsule + A1's corner pair). The screen's frames,
// pure, on the iPads he uses: 13" 1032×1376 / 1376×1032, 11" 834×1194 / 1194×834 and the mini 744×1133 / 1133×744.
//
// His rules (2026-09-29, and img5, 2026-10-14: "When 'Selections' is minimized it touches the 'iPad' chip. Please ensure
// that the all chips are separated by equal padding between them."): even spacing, 44 pt targets, icons only for views,
// one card at a time above the pair. The mockup he picked ("Your pick", config pk) is the reference: the capsule at
// (24, 76), the views 44 pt and 8 apart under the gizmo, the pair on 24/24, panels 420 wide (336 on the mini) 12 above it.
import XCTest
import SwiftUI
import TopOptDesign
@testable import TopOptFlows

final class FlexibleChromeLayoutTests: XCTestCase {

    static let pads: [(String, CGSize)] = [
        ("13p", CGSize(width: 1032, height: 1376)), ("13l", CGSize(width: 1376, height: 1032)),
        ("11p", CGSize(width: 834, height: 1194)), ("11l", CGSize(width: 1194, height: 834)),
        ("minip", CGSize(width: 744, height: 1133)), ("minil", CGSize(width: 1133, height: 744)),
    ]
    /// The minimised Selections pill's width, as img5 shows it on his 13" ("> Selections 3", ~138 pt).
    static let pillWidth: CGFloat = 138

    func testTheCapsuleSitsUnderTheNameClearOfTheGizmo() {
        XCTAssertEqual(FlexibleChromeLayout.capsuleTop, 76)
        XCTAssertEqual(FlexibleChromeLayout.capsuleLeft, 24)
        XCTAssertEqual(FlexibleChromeLayout.capsuleHeight, 44)
        XCTAssertEqual(FlexibleChromeLayout.segmentHeight, 36)
        XCTAssertLessThanOrEqual(FlexibleChromeLayout.capsuleMaxWidth, 300)
        let cap = FlexibleChromeLayout.capsuleFrame(width: 1000)
        XCTAssertEqual(cap, CGRect(x: 24, y: 76, width: FlexibleChromeLayout.capsuleMaxWidth, height: 44), "capped at its widest")
        for (name, v) in Self.pads {
            let gizmo = FlexibleLegendPlacement.gizmoFrame(viewport: v)
            XCTAssertGreaterThanOrEqual(gizmo.minX - cap.maxX, 12, "\(name): the capsule keeps 12 pt from the gizmo")
        }
    }

    /// The source pin: the capsule's top IS #354's StageNavPlacement for the lattice stage (H27 applies that modifier), so
    /// the two numbers cannot drift.
    func testTheCapsuleTopIsStageNavPlacementsFormula() throws {
        let ws = try FlexibleSource.code("WorkspacePlaceholder.swift")
        XCTAssertTrue(ws.contains("static let identityRowHeight: CGFloat = 42"))
        XCTAssertTrue(ws.contains(".padding(.top, DS.Space.xl3 + Self.identityRowHeight\n                             + PageChrome.gap)"))
        XCTAssertEqual(FlexibleChromeLayout.capsuleTop, DS.Space.xl3 + 42 + PageChrome.gap)
        XCTAssertEqual(FlexibleChromeLayout.capsuleLeft, DS.Space.xl4)
    }

    func testTheViewsRowIsSixFortyFourPointIconsEightApart() {
        XCTAssertEqual(FlexibleChromeLayout.viewButton, 44)
        XCTAssertEqual(FlexibleChromeLayout.viewsGap, 8)
        for (name, v) in Self.pads {
            let row = FlexibleChromeLayout.viewsRow(viewport: v)
            XCTAssertEqual(row, FlexibleMainViewToggles.rowFrame(viewport: v), "\(name): the toggles draw the layout's row")
            XCTAssertEqual(row.maxX, v.width - 24, "\(name): on the right edge's 24")
            XCTAssertEqual(row.minY, PageChrome.belowGizmo, "\(name): under the gizmo")
            if name == "minip" {
                XCTAssertEqual(row.size, CGSize(width: 3 * 44 + 2 * 8, height: 2 * 44 + 8), "the mini in portrait: three over three")
            } else {
                XCTAssertEqual(row.size, CGSize(width: 304, height: 44), "\(name): one line, 6 × 44 + 5 × 8")
            }
        }
    }

    func testThePairSitsOnTheCornerTwelveApart() {
        for (name, v) in Self.pads {
            let mini = name.hasPrefix("mini")
            XCTAssertEqual(FlexibleChromeLayout.isMini(v), mini, name)
            let size = FlexibleChromeLayout.latticeButtonSize(v)
            XCTAssertEqual(size, CGSize(width: mini ? 240 : 260, height: 64), "\(name): the Lattice split")
            let p = FlexibleChromeLayout.pair(viewport: v, setupWidth: 210)
            XCTAssertEqual(p.lattice.maxX, v.width - 24, name)
            XCTAssertEqual(p.lattice.maxY, v.height - 24, name)
            XCTAssertEqual(p.setup.maxY, v.height - 24, "\(name): bottoms aligned")
            XCTAssertEqual(p.lattice.minX - p.setup.maxX, 12, "\(name): 12 apart")
            XCTAssertEqual(p.setup.height, 48, name)
            XCTAssertEqual(FlexibleChromeLayout.pair(viewport: v, setupWidth: 400).setup.width, 240, "\(name): the Setup chip is at most 240")
        }
        XCTAssertEqual(FlexibleChromeLayout.latticeCaretWidth, 52)
    }

    func testPanelsAreRightAlignedAboveThePairAndNeverRiseAboveTheViewsRow() {
        for (name, v) in Self.pads {
            let mini = name.hasPrefix("mini")
            XCTAssertEqual(FlexibleChromeLayout.panelWidth(v), mini ? 336 : 420, name)
            let limit = FlexibleChromeLayout.panelTopLimit(v)
            XCTAssertEqual(limit, FlexibleChromeLayout.viewsRow(viewport: v).maxY + 12, "\(name): the views row's foot + 12")
            let pair = FlexibleChromeLayout.pair(viewport: v, setupWidth: 210)
            let small = FlexibleChromeLayout.panel(viewport: v, setupWidth: 210, contentHeight: 200)
            XCTAssertEqual(small.frame.maxX, v.width - 24, "\(name): right-aligned on 24")
            XCTAssertEqual(small.frame.maxY, pair.lattice.minY - 12, "\(name): 12 above the pair")
            XCTAssertEqual(small.frame.height, 200, "\(name): sized to its content")
            XCTAssertFalse(small.scrolls, name)
            let tall = FlexibleChromeLayout.panel(viewport: v, setupWidth: 210, contentHeight: 5000)
            XCTAssertEqual(tall.frame.minY, limit, "\(name): never above the views row's foot + 12 …")
            XCTAssertTrue(tall.scrolls, "\(name): … past that its body scrolls")
        }
        XCTAssertEqual(FlexibleChromeLayout.panelTopLimit(CGSize(width: 1032, height: 1376)), PageChrome.belowGizmo + 44 + 12, accuracy: 0.01)
    }

    /// His img5: the minimised Selections pill touched the iPad chip. Now the chip next to it is the Setup chip, at its
    /// widest, and it keeps at least 12 pt on every pad. RED CONTROL: today's bar ([iPad][Print Parameters][Lattice]
    /// [Optimize], img5's widths) lands on the pill.
    func testTheMinimisedSelectionsPillKeepsTwelveFromTheSetupChip() {
        for (name, v) in Self.pads {
            let pill = FlexibleChromeLayout.selectionsPill(viewport: v, width: Self.pillWidth)
            XCTAssertEqual(pill.minX, 24, name)
            XCTAssertEqual(pill.maxY, v.height - 24, name)
            let setup = FlexibleChromeLayout.pair(viewport: v, setupWidth: FlexibleChromeLayout.setupMaxWidth).setup
            XCTAssertGreaterThanOrEqual(setup.minX - pill.maxX, 12, "\(name): the pill and the Setup chip at least 12 apart")
        }
        // RED CONTROL: today's bar on his 13" (img5: iPad 86, Print Parameters 175, Lattice 341, Optimize 228; 8 apart)
        let v = CGSize(width: 1032, height: 1376)
        let bar = FlexibleChromeLayout.todaysBar(viewport: v, widths: [86, 175, 341, 228], spacing: 8)
        let pill = FlexibleChromeLayout.selectionsPill(viewport: v, width: Self.pillWidth)
        let gap = (bar.first?.minX ?? 0) - pill.maxX
        print("FLEX-R7D1-LAYOUT img5 control: the iPad chip starts \(gap) pt right of the pill (≥ 12 needed)")
        XCTAssertLessThan(gap, 12, "★ RED CONTROL: today's bar breaks the rule (img5: the pill touches the iPad chip)")
        XCTAssertEqual(bar.count, 4)
    }
}
