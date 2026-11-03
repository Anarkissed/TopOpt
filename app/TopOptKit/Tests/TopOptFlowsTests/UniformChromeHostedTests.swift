// UniformChromeHostedTests — B2, U1 (approved design 2026-11-02, design-system §4.1; ledger notes 8, 16, 17, 18).
//
// ONE top-left block on every page: ‹ where Back goes · name and version · material · undo · redo, then the stage row 8 pt
// under it. Its frames are identical on Topology Setup, Results, the Lattice stage, the Cells page, Edit faces and the
// Flexible stage, at three window sizes. (Squish, the Flexible full-screen page, is #362's: B9.)
#if canImport(AppKit) && canImport(MetalKit)
import XCTest
import SwiftUI
@testable import TopOptFlows
@testable import TopOptKit

@MainActor
final class UniformChromeHostedTests: XCTestCase {

    struct Block: Equatable, CustomStringConvertible {
        let back: CGRect, name: CGRect, undo: CGRect, redo: CGRect, stageRowTop: CGFloat
        var description: String { "back \(back) name \(name) undo \(undo) redo \(redo) stageRow.y \(stageRowTop)" }
    }

    func block(_ h: AppBuildHost, _ page: String) throws -> Block {
        Block(back: try h.onScreen("backButton", "\(page): Back"),
              name: try h.onScreen("topLeftName", "\(page): the name pill"),
              undo: try h.onScreen("topLeftUndo", "\(page): Undo"),
              redo: try h.onScreen("topLeftRedo", "\(page): Redo"),
              stageRowTop: try h.onScreen("capsule", "\(page): the stage row").minY)
    }

    /// The rules every page's block keeps.
    func checkShape(_ b: Block, _ page: String, _ size: CGSize) {
        XCTAssertGreaterThanOrEqual(b.back.height, 42, "\(page) \(size): Back is a full-size target")
        for (f, n) in [(b.undo, "Undo"), (b.redo, "Redo")] {
            XCTAssertGreaterThanOrEqual(f.width, 44, "\(page) \(size): \(n) ≥ 44 pt"); XCTAssertGreaterThanOrEqual(f.height, 44, "\(page) \(size): \(n) ≥ 44 pt")
        }
        XCTAssertLessThan(b.back.maxX, b.name.minX, "\(page): Back, then the name"); XCTAssertLessThan(b.name.maxX, b.undo.minX + 1, "\(page): then Undo")
        XCTAssertEqual(b.stageRowTop - max(b.back.maxY, b.name.maxY, b.undo.maxY), 8, accuracy: 3, "\(page) \(size): the stage row 8 pt under it")
    }

    func testTheTopLeftBlockIsTheSameOnEveryPage() throws {
        for size in [AppBuildHost.landscape13, AppBuildHost.portrait13, AppBuildHost.landscape11] {
            // a Structural lookalike with results: Topology Setup, Results, the Lattice stage, the Cells page, Edit faces
            let r = try FlexiblePressFixtures.a1Project(3, self, facePrism: false)
            let p = r.project
            p.lattice.flexible = nil
            p.lattice.chooseLatticeType(.structural)
            p.run.restoreOutcome(AppBuildFixtures.outcome())
            let h = AppBuildHost(WorkspacePlaceholder(model: r.app, project: p), size: size, test: self)
            h.pump(3)
            var seen: [(String, Block)] = []
            seen.append(("Topology Setup", try block(h, "Topology Setup")))
            try h.tap("capsuleResults", "Results")
            seen.append(("Results", try block(h, "Results")))
            try h.pickFromMenu("capsuleMenu", "Structural", what: "the stage menu")
            h.pump(1)
            seen.append(("Lattice stage", try block(h, "Lattice stage")))
            try h.tap("capsuleLattice", "the Lattice page", settle: 1.5)
            seen.append(("Lattice page", try block(h, "Lattice page")))
            try h.tap("capsuleSetup", "back to Setup", settle: 1.5)
            try h.tap("capsuleScissors", "Edit faces", settle: 1.5)
            seen.append(("Edit faces", try block(h, "Edit faces")))

            // the Flexible stage (the lookalike as saved)
            let f = try FlexiblePressFixtures.a1Project(3, self, facePrism: false)
            let hf = AppBuildHost(WorkspacePlaceholder(model: f.app, project: f.project), size: size, test: self)
            hf.pump(3)
            seen.append(("Flexible stage", try block(hf, "Flexible stage")))

            let first = seen[0].1
            for (page, b) in seen {
                checkShape(b, page, size)
                XCTAssertEqual(b.back, first.back, "\(size): ★ Back on \(page) sits where it sits on Topology Setup")
                XCTAssertEqual(b.name.origin, first.name.origin, "\(size): ★ the name pill on \(page)")
                XCTAssertEqual(b.name.height, first.name.height, "\(size): the name pill's height on \(page)")
                XCTAssertEqual(b.stageRowTop, first.stageRowTop, accuracy: 0.5, "\(size): ★ the stage row on \(page)")
            }
        }
    }
}
#endif
