// ViewCornerParityHostedTests — B2, round 1 R0 (approved design 2026-11-02, design-system §4.2's table).
//
// Each stage keeps every view it has today; only the X-ray pair (Outlines + X-ray) and Ortho │ Persp are added, the pair
// first. Read on the real pages by the views' labels, in their order on the screen. RED control: drop one of today's views
// and the test fails. (Results' Outlines comes with B4's Results rebuild — a result's mesh has no edges for it to draw yet;
// Cut's pair stays in its tool tray under the gizmo until B8's Cut rebuild; Flexible and Squish are B9's, #362's.)
#if canImport(AppKit) && canImport(MetalKit)
import XCTest
import SwiftUI
@testable import TopOptFlows
@testable import TopOptKit

@MainActor
final class ViewCornerParityHostedTests: XCTestCase {

    /// The view buttons a page draws, by label, in their order on the screen (a row left to right; a column top to bottom).
    static func views(_ h: AppBuildHost, results: Bool = false) -> [String] {
        let picked: [(String, CGRect)] = h.frames.all.compactMap { k, f in
            if results {
                if k == "resultsFullScreen" { return ("Full screen", f) }
                guard k.hasPrefix("resultsView-") else { return nil }
                return (String(k.dropFirst("resultsView-".count)), f)
            }
            guard k.hasPrefix("view-") else { return nil }
            var label = String(k.dropFirst("view-".count))
            if label.hasSuffix("-on") { label.removeLast(3) }
            return (label, f)
        }
        return picked.sorted { a, b in
            let ay = (a.1.minY / 20).rounded(), by = (b.1.minY / 20).rounded()
            return ay != by ? ay < by : a.1.minX < b.1.minX
        }.map(\.0)
    }

    /// The pages, in one walk: Topology Setup, Results, the Lattice stage, the Lattice page, Cut.
    func walk(_ size: CGSize) throws -> [(String, [String])] {
        let r = try FlexiblePressFixtures.a1Project(3, self, facePrism: false)
        let p = r.project
        p.lattice.flexible = nil
        p.lattice.chooseLatticeType(.structural)
        p.run.restoreOutcome(AppBuildFixtures.outcome())
        let h = AppBuildHost(WorkspacePlaceholder(model: r.app, project: p), size: size, test: self)
        h.pump(3)
        var out: [(String, [String])] = [("Topology Setup", Self.views(h))]
        try h.tap("capsuleResults", "Results")
        out.append(("Results", Self.views(h, results: true)))
        try h.pickFromMenu("capsuleMenu", "Structural", what: "the stage menu")
        h.pump(1)
        out.append(("Lattice Setup", Self.views(h)))
        try h.tap("capsuleLattice", "the Lattice page", settle: 1.5)
        out.append(("Lattice page", Self.views(h)))
        try h.tap("capsuleSetup", "back to Setup", settle: 1.5)
        try h.tap("capsuleScissors", "Cut", settle: 1.5)
        out.append(("Cut", Self.views(h)))
        return out
    }

    /// §4.2's table for this lookalike: no growth box (Topology's "Allow growth here" shows only while there is one), a run
    /// without stress or motion (Results shows what the run can show), no lattice stress yet (Lattice Setup's Stress shows
    /// once its sim lands).
    static let expected: [(String, [String])] = [
        ("Topology Setup", ["Outlines", "X-ray", "Forces"]),
        ("Results", ["X-ray", "Solid", "Full screen"]),        // Solid goes in B4 (note 13); Outlines comes in B4
        ("Lattice Setup", ["Outlines", "X-ray", "Lattice preview"]),
        ("Lattice page", []),                                   // no part is drawn (R3.2)
        ("Cut", ["Outlines", "X-ray"]),
    ]

    /// §4.2's views a later batch brings (the reviewer's Q4 (b), 2026-11-03): absent now, so that batch flips them in.
    static let later: [(page: String, view: String, batch: String)] = [("Results", "Outlines", "B4")]

    func testEveryStageKeepsTodaysViewsWithTheXrayPairFirst() throws {
        for size in [AppBuildHost.landscape13, AppBuildHost.portrait13] {
            let seen = try walk(size)
            for ((page, want), (seenPage, got)) in zip(Self.expected, seen) {
                XCTAssertEqual(page, seenPage)
                XCTAssertEqual(got, want, "\(size): ★ \(page)'s views")
                for l in Self.later where l.page == page {
                    XCTAssertFalse(got.contains(l.view), "\(page)'s \(l.view) comes in \(l.batch): move it into `expected` there")
                }
            }
        }
    }

    func testTheRedControlDropsAView() throws {
        addTeardownBlock { @MainActor in ViewCornerParity.controlDropped = nil }
        ViewCornerParity.controlDropped = "Forces"
        let seen = try walk(AppBuildHost.landscape13)
        XCTAssertNotEqual(seen[0].1, Self.expected[0].1, "★ the control: Topology without Forces is caught")
    }
}
#endif
