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
        let back: CGRect, name: CGRect, rename: CGRect, material: CGRect, undo: CGRect, redo: CGRect, stageRowTop: CGFloat
        var description: String { "back \(back) name \(name) rename \(rename) material \(material) undo \(undo) redo \(redo) stageRow.y \(stageRowTop)" }
    }

    func block(_ h: AppBuildHost, _ page: String) throws -> Block {
        Block(back: try h.onScreen("backButton", "\(page): Back"),
              name: try h.onScreen("topLeftName", "\(page): the name pill"),
              rename: try h.onScreen("topLeftRename", "\(page): the name (tap to rename)"),
              material: try h.onScreen("topLeftMaterial", "\(page): the material (tap to switch)"),
              undo: try h.onScreen("topLeftUndo", "\(page): Undo"),
              redo: try h.onScreen("topLeftRedo", "\(page): Redo"),
              stageRowTop: try h.onScreen("capsule", "\(page): the stage row").minY)
    }

    /// The rules every page's block keeps.
    func checkShape(_ b: Block, _ page: String, _ size: CGSize) {
        // ★ 11-12 (#362's B10 census: "the top-left block's ‹ and name pill are 42 pt tall on every page"; design-system §1:
        // every tap target ≥ 44 × 44): Back, the name and the material are 44 pt tall targets. Their pills are still drawn 42.
        XCTAssertGreaterThanOrEqual(b.back.height, 44, "\(page) \(size): Back is a 44 pt target")
        XCTAssertGreaterThanOrEqual(b.back.width, 44, "\(page) \(size): Back is a 44 pt target")
        XCTAssertGreaterThanOrEqual(b.rename.height, 44, "\(page) \(size): the name is a 44 pt target")
        XCTAssertGreaterThanOrEqual(b.rename.width, 44, "\(page) \(size): the name is a 44 pt target")
        XCTAssertGreaterThanOrEqual(b.material.height, 44, "\(page) \(size): the material is a 44 pt target")
        XCTAssertGreaterThanOrEqual(b.material.width, 44, "\(page) \(size): the material is a 44 pt target")
        XCTAssertEqual(b.name.height, TopLeftBlock.height, accuracy: 0.5, "\(page) \(size): the name pill is still drawn 42 (the look kept)")
        // the targets reach the row's 44: 1 pt over and under the drawn pill (as every pill button's, B10), never past its ends
        let pill = b.name.insetBy(dx: -0.5, dy: -1.5)
        XCTAssertTrue(pill.contains(b.rename) && pill.contains(b.material), "\(page) \(size): the name and the material sit in the name pill")
        XCTAssertLessThanOrEqual(b.rename.maxX, b.material.minX + 0.5, "\(page) \(size): the name's target, then the material's")
        for (f, n) in [(b.undo, "Undo"), (b.redo, "Redo")] {
            XCTAssertGreaterThanOrEqual(f.width, 44, "\(page) \(size): \(n) ≥ 44 pt"); XCTAssertGreaterThanOrEqual(f.height, 44, "\(page) \(size): \(n) ≥ 44 pt")
        }
        XCTAssertLessThan(b.back.maxX, b.name.minX, "\(page): Back, then the name"); XCTAssertLessThan(b.name.maxX, b.undo.minX + 1, "\(page): then Undo")
        XCTAssertEqual(b.stageRowTop - max(b.back.maxY, b.name.maxY, b.undo.maxY), 8, accuracy: 3, "\(page) \(size): the stage row 8 pt under it")
    }

    /// ★ Note 20 ("Has the words 'on the part' next to the scissors icon"), the reviewer's Q3 (c) of 2026-11-03: the words
    /// go now; a result's saving ("on −35 %") stays beside the stage row until B6's ⌃ menu takes it.
    func testTheStageRowSaysNoOnThePart() {
        let part: String? = LatticeStageCopy.builtOn(achievedVolumeFraction: nil)
        XCTAssertNil(part, "★ the stage's own part: no words beside the stage row")
        XCTAssertEqual(LatticeStageCopy.builtOn(achievedVolumeFraction: 0.65), "on \u{2212}35 %", "a result keeps its saving")
        XCTAssertEqual(LatticeStageCopy.builtOn(achievedVolumeFraction: 1.2), "on +20 %", "a growth result keeps its own")
    }

    /// ★ 11-12: the 44 pt targets really take a tap at their edges — 1 pt inside each target's top, where neither the drawn
    /// 42 pt pill nor the words are. (A frame that only measures 44 would pass the shape check and still miss his finger.)
    func testTheTopBarTakesATapAtItsTargetsEdges() throws {
        let r = try FlexiblePressFixtures.a1Project(3, self, facePrism: false)
        r.project.lattice.flexible = nil   // Topology Setup: the name renames there
        let h = AppBuildHost(AppBuildRoot(model: r.app), size: AppBuildHost.landscape13, test: self)
        h.pump(3)

        let rename = try h.onScreen("topLeftRename", "the name")
        XCTAssertGreaterThanOrEqual(rename.height, 44, "the name's target")   // so its top is ~10 pt above the words
        h.click(CGPoint(x: rename.midX, y: rename.minY + 1), settle: 1)
        _ = try h.onScreen("nameSheet", "★ a tap at the name's top edge opens Rename")
        try h.tap("nameSheetCancel", "Cancel", settle: 0.8)
        XCTAssertNil(h.frames.all["nameSheet"], "the sheet shut")

        let material = try h.onScreen("topLeftMaterial", "the material")
        var opened = false
        let obs = NotificationCenter.default.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: nil) { n in
            guard let m = n.object as? NSMenu else { return }
            RunLoop.main.perform(inModes: [.eventTracking, .default, .modalPanel]) { opened = true; m.cancelTracking() }
        }
        h.click(CGPoint(x: material.midX, y: material.minY + 1), settle: 1.5)
        XCTAssertTrue(opened, "★ a tap at the material's top edge opens its menu")
        opened = false
        h.click(CGPoint(x: material.minX + 1, y: material.midY), settle: 1.5)   // 9 pt left of the word
        NotificationCenter.default.removeObserver(obs)
        XCTAssertTrue(opened, "★ a tap at the material's left edge, beside the word, opens its menu")

        let back = try h.onScreen("backButton", "Back")
        h.click(CGPoint(x: back.midX, y: back.minY + 0.5), settle: 2)
        XCTAssertEqual(r.app.screen, .home, "★ a tap at Back's top edge, above the drawn pill, goes back")
    }

    func testTheTopLeftBlockIsTheSameOnEveryPage() throws {
        for size in AppBuildHost.sweep {   // ★ B10: the six windows
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
