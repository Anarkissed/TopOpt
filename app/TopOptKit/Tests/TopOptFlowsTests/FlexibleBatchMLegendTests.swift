// FlexibleBatchMLegendTests — his round-5 M4 (img 4): "The legends should combine into a singular
// modal. Please review the other lattice sections to understand" — task 2026-09-29-flexible-screens,
// round 5 batch M. The octet's key (LatticeLegendPanel) is ONE squircle holding every scale in play;
// the Flexible page now shows ONE card the same way:
//   * the active scales in one card (the dent OR Stress — never both — and the walls' density), one
//     frame, clear of every button at 13" and 11", both orientations, open or folded — RED: batch C's
//     per-kind placement gave two frames;
//   * tap it → "TAP THE PART TO READ"; a tap on the part reads what is under the finger — the solid
//     dent plane over a ghost wall — RED: batch C read the wall the probe found behind the plane.
#if canImport(MetalKit)
import XCTest
import simd
import SwiftUI
@testable import TopOptFlows
@testable import TopOptKit

@MainActor
final class FlexibleBatchMLegendTests: XCTestCase {

    static let viewports: [(String, CGSize)] = [("13 portrait", CGSize(width: 1032, height: 1376)),
                                                ("13 landscape", CGSize(width: 1376, height: 1032)),
                                                ("11 portrait", CGSize(width: 834, height: 1194)),
                                                ("11 landscape", CGSize(width: 1194, height: 834))]

    func testOneCardHoldsTheActiveScalesAndNeverCoversAButton() async throws {
        let (r, stage, _) = try await FlexibleBatchMXrayTests().round5Shared(self)
        _ = r
        XCTAssertEqual(stage.legendKinds, [.dent, .lattice], "the defaults: the dent and the walls")
        for (name, v) in Self.viewports {
            for chip: CGFloat in [0, 222] {
                for folded in [false, true] {
                    stage.legendMinimized = folded
                    let frames = stage.legendFrames(viewport: v, bottomClearance: 94, chipColumnWidth: chip)
                    let card = try XCTUnwrap(stage.legendCard(viewport: v, bottomClearance: 94, chipColumnWidth: chip), "\(name)")
                    XCTAssertEqual(Set(frames.values.map(\.frame.debugDescription)).count, 1, "\(name): ONE card for every scale")
                    XCTAssertEqual(card.expanded, !folded)
                    for k in FlexibleMainLegendLayout.keepOut(viewport: v, bottomClearance: 94, chipColumnWidth: chip) {
                        XCTAssertFalse(card.frame.intersects(k), "\(name) chip \(chip) folded \(folded): the card covers no button")
                    }
                    XCTAssertGreaterThanOrEqual(card.frame.minX, 0); XCTAssertLessThanOrEqual(card.frame.maxX, v.width)
                    // the player keeps clear of it
                    let keep = FlexibleMainPlayerSlot.keepOut(viewport: v, bottomClearance: 94, chipColumnWidth: chip,
                                                              legends: frames.values.map(\.frame))
                    XCTAssertTrue(keep.contains(card.frame))
                }
            }
        }
        stage.legendMinimized = false
        // ★ RED CONTROL: batch C's per-kind legends — two frames, two cards
        let v = Self.viewports[0].1
        let keep = FlexibleMainLegendLayout.keepOut(viewport: v, bottomClearance: 94, chipColumnWidth: 0)
        let old = FlexibleMainLegendLayout.place(stage.legendKinds, minimized: [], viewport: v, keepOut: keep)
        XCTAssertEqual(Set(old.values.map(\.frame.debugDescription)).count, 2, "control: batch C drew a legend per scale")
        // Stress takes the dent's row (never both)
        stage.toggleStress()
        XCTAssertEqual(stage.legendKinds, [.stress, .lattice])
        stage.toggleHeat()
        XCTAssertEqual(stage.legendKinds, [.dent, .lattice])
        // the source: the page draws the ONE card
        let src = try FlexibleSource.code("FlexibleMainLegends.swift")
        XCTAssertTrue(src.contains("card(kinds, p)"))
        XCTAssertTrue(src.contains(".accessibilityIdentifier(\"flexible-legend-card\")"))
        XCTAssertFalse(src.contains("legend(k, p)"), "no per-kind legend any more")
    }

    func testTheCardReadsWhatIsUnderTheFinger() async throws {
        let (r, stage, m) = try await FlexibleBatchMXrayTests().round5Shared(self)
        let pm = r.project
        stage.pick("group-1"); stage.refresh()
        // tap the card: it reads (its first scale's mode), a second tap comes back out
        let mode = stage.cardTapped(mode: .groups)
        XCTAssertEqual(mode, FlexibleReadKind.dent.mode)
        XCTAssertEqual(stage.cardTapped(mode: mode), .groups)
        XCTAssertTrue(stage.wantsWallProbe(mode), "the walls are in the card: a wall may be tapped")
        // a wall found BEHIND the dent plane (the probe reads the G-buffer; the walls are a ghost under the
        // solid plane): the reading is the plane's — what he sees
        let key = try XCTUnwrap(m.key(FlexibleHisProject.topA)), st = try XCTUnwrap(m.stacks[key])
        let o = try XCTUnwrap(stage.overlay)
        let start = try XCTUnwrap(o.flatStart[key])
        let pos = o.mesh.flat.positions
        let c = st.columns.count / 2
        let q = start + 6 * c
        let onMap = (SIMD3<Float>(pos[3 * q], pos[3 * q + 1], pos[3 * q + 2]) + SIMD3(pos[3 * q + 3], pos[3 * q + 4], pos[3 * q + 5])
            + SIMD3(pos[3 * q + 6], pos[3 * q + 7], pos[3 * q + 8])) / 3
        let wall = onMap + SIMD3<Float>(st.load) * 4   // 4 mm inside the part, under the plane
        // the view straight down the load
        let cam = SIMD3<Float>(st.load)
        stage.noteViewForTests(direction: cam)
        XCTAssertTrue(stage.readLattice(pm, mode: mode, model: wall))
        let got = try XCTUnwrap(stage.reading)
        print("FLEX-M CARD tap on a wall under the plane: \(got.kind) '\(got.text)'")
        XCTAssertEqual(got.kind, .dent, "the solid plane he sees is read, not the ghost wall behind it")
        // ★ RED CONTROL: there IS a wall at that point — the probe's own reading of it is a density (what
        // a wall-first card would have shown over the solid plane)
        let g = try XCTUnwrap(stage.shownLattice)
        let wallRead = FlexibleProbe.lattice(g.inputs, faces: g.squishFaces, squish: 0, at: wall, fe: stage.feShownField)
        XCTAssertNotNil(wallRead, "control: a wall is there to be read")
    }
}

extension FlexibleBatchMXrayTests {
    /// His round-5 project through Save & Exit for another test case (its teardowns).
    func round5Shared(_ test: XCTestCase) async throws -> (FlexibleHisProject.Restored, FlexibleMainStage, FlexibleStageModel) {
        let r = try FlexibleHisProject.restore(FlexibleHisProject.round5Dir)
        test.addTeardownBlock { r.cleanup() }
        let stage = FlexibleMainStage()
        stage.reduceMotion = { true }
        let m = stage.model(for: r.project, materialsPath: FlexibleHisProject.materialsPath,
                            stampsPath: FlexibleHisProject.stampsPath, persist: {})
        test.addTeardownBlock { @MainActor in await m.waitForIdle() }
        m.openScene()
        try await FlexibleSquishFixture.settle(m, "his round 5")
        stage.didExitSettings()
        stage.apply(r.project, owned: true, pageUp: false)
        try await FlexibleHisProject.waitFor(300, "his round 5: the sims") {
            stage.refresh()
            return m.lattice != nil && !m.squish.isEmpty && !m.squish.values.contains(.pending)
        }
        await m.squishSolver.waitForIdle()
        stage.refresh()
        return (r, stage, m)
    }
}
#endif
