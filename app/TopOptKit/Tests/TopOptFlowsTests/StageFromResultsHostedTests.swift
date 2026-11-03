// StageFromResultsHostedTests — B1, ledger note 16 (approved design 2026-11-02).
//
// His words: "Tried to go from results to 'Structural' and it didn't work. That entire menu line disappeared. I had to exit
// using the <." The cause: the ● menu's stage change (`goToStage`) never closed Results, which draws over every stage while it
// is open, and the capsule riding over Results is drawn on Topology only — so the stage changed underneath and the menu line
// went. The design: changing stage closes Results first; the top-left block never vanishes.
#if canImport(AppKit) && canImport(MetalKit)
import XCTest
import SwiftUI
@testable import TopOptFlows
@testable import TopOptKit

@MainActor
final class StageFromResultsHostedTests: XCTestCase {

    func testResultsThenTheStageMenuOpensTheLatticeStageWithItsTopLeftBlock() throws {
        for size in [AppBuildHost.landscape13, AppBuildHost.portrait13] {
            let r = try FlexiblePressFixtures.a1Project(3, self, facePrism: false)
            let p = r.project
            // his case: a Structural part (the lookalike is a Flexible one; make it Structural, in memory only)
            p.lattice.flexible = nil
            p.lattice.chooseLatticeType(.structural)
            p.run.restoreOutcome(AppBuildFixtures.outcome())
            let h = AppBuildHost(WorkspacePlaceholder(model: r.app, project: p), size: size, test: self)
            h.pump(3)

            // Results open, the way he opens it: the capsule's Results segment
            let before = Set(h.frames.all.keys)
            try h.tap("capsuleResults", "\(size): the capsule's Results")
            XCTAssertTrue(Set(h.frames.all.keys).subtracting(before).contains("resultsVersions"), "\(size): Results is open (its versions)")
            XCTAssertNotNil(h.frames.all["capsuleMenu"], "\(size): the ● menu rides over Results")

            // ● → Structural (the lattice stage, named by its type)
            let offered = try h.pickFromMenu("capsuleMenu", "Structural", what: "\(size): the ● menu over Results")
            XCTAssertFalse(offered.isEmpty, "\(size): the ● menu opened (offered: \(offered))")
            h.pump(1.5)

            // ★ the lattice stage is up, with its top-left block: the capsule and its Regions / Cells pages
            _ = try h.onScreen("capsule", "\(size): the top-left block (the capsule) after the stage change")
            _ = try h.onScreen("capsuleMenu", "\(size): the ● menu after the stage change")
            XCTAssertNotNil(h.frames.all["capsuleRegions"] ?? h.frames.all["capsuleCells"],
                            "\(size): ★ the LATTICE stage's capsule (Regions / Cells); frames: \(h.frames.all.keys.sorted())")
            XCTAssertNil(h.frames.all["capsuleResults"], "\(size): Topology's capsule is gone")
            // ★ RESULTS CLOSED FIRST: none of its controls is left drawn over the lattice stage (on 5cf6773b-era code they all
            // were — Results is mounted above the stage row, so it covered the capsule: "that entire menu line disappeared")
            let left = h.frames.all.keys.filter { $0.hasPrefix("results") }.sorted()
            XCTAssertTrue(left.isEmpty, "\(size): ★ Results is still up over the lattice stage: \(left)")
        }
    }
}
#endif
