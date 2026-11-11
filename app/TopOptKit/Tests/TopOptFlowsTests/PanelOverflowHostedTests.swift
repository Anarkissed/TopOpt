// PanelOverflowHostedTests — B2, U10 (approved design 2026-11-02, design-system §1 U10 and §4.3).
//
// "Nothing hidden below a fold. Any list taller than its panel shows a '3 more ⌄' cue at its bottom edge. Pinned footers
// (+ Add a load scenario, Safety margin) never scroll away. A control that can't be seen without hunting doesn't count as
// there." Checked on Topology Setup's Selections panel with real clicks, at three window sizes.
#if canImport(AppKit) && canImport(MetalKit)
import XCTest
import SwiftUI
@testable import TopOptFlows
@testable import TopOptKit

@MainActor
final class PanelOverflowHostedTests: XCTestCase {

    func host(_ size: CGSize, extraGroups: Int) throws -> (AppBuildHost, ProjectModel) {
        let r = try FlexiblePressFixtures.a1Project(3, self, facePrism: false)
        let p = r.project
        p.lattice.flexible = nil
        p.lattice.chooseLatticeType(.structural)
        for _ in 0..<extraGroups { _ = p.selection.addGroup() }
        let h = AppBuildHost(WorkspacePlaceholder(model: r.app, project: p), size: size, test: self)
        h.pump(3)
        return (h, p)
    }

    /// The cue's frame and the count it shows ("selectionsMore-<n>").
    func cue(_ h: AppBuildHost) -> (CGRect, Int)? {
        guard let (k, f) = h.frames.all.first(where: { $0.key.hasPrefix("selectionsMore-") }),
              let n = Int(k.dropFirst("selectionsMore-".count)) else { return nil }
        return (f, n)
    }

    /// The group lines lying (more than half) below the list's visible foot.
    func hiddenBelow(_ h: AppBuildHost, _ p: ProjectModel, foot: CGFloat) -> Int {
        p.selection.groups.filter { g in
            guard let f = h.frames.all["selGroup-\(g.id.uuidString)"] else { return false }
            return f.midY > foot
        }.count
    }

    func testATallListShowsHowManyMoreAndTheCueScrolls() throws {
        for size in [AppBuildHost.landscape13, AppBuildHost.landscape11] {
            let (h, p) = try host(size, extraGroups: 16)
            let (f, n) = try XCTUnwrap(cue(h), "\(size): ★ the list is taller than its panel, so it shows the 'n more' cue")
            _ = try h.probe(h.frames.all.first { $0.key.hasPrefix("selectionsMore-") }!.key, "\(size): the cue")
            let list = try XCTUnwrap(h.frames.all["selectionsList"])
            XCTAssertTrue(list.contains(CGPoint(x: f.midX, y: f.midY)), "\(size): the cue sits in its panel")
            XCTAssertEqual(n, hiddenBelow(h, p, foot: f.maxY), "\(size): ★ the cue counts the lines below the fold")
            h.click(CGPoint(x: f.midX, y: f.midY), settle: 1.0)
            let after = cue(h)?.1 ?? 0
            XCTAssertLessThan(after, n, "\(size): ★ tapping the cue scrolls the hidden lines into view")
        }
    }

    func testAShortListHasNoCue() throws {
        let (h, _) = try host(AppBuildHost.landscape13, extraGroups: 0)
        _ = try h.onScreen("selectionsList", "the Selections panel")
        XCTAssertNil(cue(h), "everything fits: no cue")
    }

    /// ★ The reviewer (2026-11-03 06:06): "Add a hosted test that the Safety margin row is reachable at every viewport" — the
    /// three ScreenProbe sizes, his iPad's More Space, and 11" portrait.
    /// ★ B10: the sweep's six windows (it was these five, without More Space portrait).
    static let everyViewport = AppBuildHost.sweep

    func testThePinnedFooterIsNeverOutOfSight() throws {
        for size in Self.everyViewport {
            for extra in [0, 16] {
                let (h, _) = try host(size, extraGroups: extra)
                let list = try h.onScreen("selectionsList", "\(size) +\(extra): ★ the whole Selections panel")
                let top = try XCTUnwrap(h.frames.all["capsule"]).maxY
                XCTAssertGreaterThanOrEqual(list.minY, top + 12 - 0.5, "\(size): the panel starts 12 pt under the stage row")
                _ = try h.probe("safetyMargin", "\(size) +\(extra): ★ Safety margin, pinned", minHit: 24)
                _ = try h.onScreen("addLoadScenario", "\(size) +\(extra): ★ + Add a load scenario, pinned")
                let m = try h.onScreen("safetyMargin", "Safety margin")
                XCTAssertTrue(list.contains(CGPoint(x: m.midX, y: m.midY)), "\(size) +\(extra): ★ Safety margin inside its panel")
                XCTAssertLessThanOrEqual(list.maxY, size.height - PageChrome.panelBottom + 0.5, "\(size) +\(extra): the panel ends above the hint band")
            }
        }
    }
}
#endif
