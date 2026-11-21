// PanelWidthHostedTests — B2, U2 (approved design 2026-11-02 §1 U2, §4.3; the reviewer's Q5, his answer 2026-11-03: "We'll
// try 1 for now, then change it up if required").
//
// Every left panel is 348 pt wide (one constant, PageChrome.panelWidth). His 10-27 note 2 ("the Group names are being cut
// off") still holds: a long name wraps to a second line inside its row, never cut off — checked at every viewport by
// measuring each name's drawn frame against the height its words need at that width.
#if canImport(AppKit) && canImport(MetalKit)
import XCTest
import SwiftUI
import AppKit
@testable import TopOptFlows
@testable import TopOptKit

@MainActor
final class PanelWidthHostedTests: XCTestCase {

    static let longName = "Left drum top under the bridge, front half (the one he presses)"

    /// The height `name` needs at `width` in the line's font (14 pt semibold).
    static func neededHeight(_ name: String, width: CGFloat) -> CGFloat {
        let font = NSFont.systemFont(ofSize: 14, weight: .semibold)
        return ceil((name as NSString).boundingRect(with: CGSize(width: width, height: .greatestFiniteMagnitude),
                                                    options: [.usesLineFragmentOrigin, .usesFontLeading],
                                                    attributes: [.font: font]).height)
    }

    func testThePanelIs348AndNoNameIsCutOff() throws {
        for size in PanelOverflowHostedTests.everyViewport {
            let r = try FlexiblePressFixtures.a1Project(3, self, facePrism: false)
            let p = r.project
            p.lattice.flexible = nil
            p.lattice.chooseLatticeType(.structural)
            let g = try XCTUnwrap(p.selection.groups.last)
            p.selection.rename(g.id, to: Self.longName)
            let h = AppBuildHost(WorkspacePlaceholder(model: r.app, project: p), size: size, test: self)
            h.pump(3)
            let list = try h.onScreen("selectionsList", "\(size): the Selections panel")
            XCTAssertEqual(list.width, PageChrome.panelWidth, accuracy: 0.5, "\(size): ★ U2 — the panel is 348 pt, a long name or not")
            XCTAssertEqual(PageChrome.panelWidth, 348)
            for grp in p.selection.groups {
                let f = try h.onScreen("selName-\(grp.id.uuidString)", "\(size): \(grp.name)'s name")
                XCTAssertGreaterThanOrEqual(f.height + 1, Self.neededHeight(grp.name, width: f.width),
                                            "\(size): ★ '\(grp.name)' is cut off (\(f))")
                XCTAssertLessThanOrEqual(f.maxX, list.maxX, "\(size): inside its panel")
            }
            let long = try h.onScreen("selName-\(g.id.uuidString)", "the long name")
            XCTAssertGreaterThan(long.height, 22, "\(size): ★ the long name wraps to a second line inside its row")
            let row = try h.onScreen("selGroup-\(g.id.uuidString)", "its row")
            XCTAssertTrue(row.insetBy(dx: -0.5, dy: -0.5).contains(long), "\(size): the name stays inside its row: \(long) in \(row)")
        }
    }
}
#endif
