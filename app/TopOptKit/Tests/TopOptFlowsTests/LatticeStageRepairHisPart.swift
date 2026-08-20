// LatticeStageRepairHisPart.swift — ★ THE READOUT, ON HIS PART, AFTER EACH FIX
// (task 2026-08-17-lattice-stage-repair, bar R1).
//
// R1 wants three numbers and a verdict after every fix: DENSITY, DEPTH, CELLS
// ACROSS. This file produces them from `M2_verticalStand.step` itself, through
// the SHIPPING derivation — `TopOptKit.faceSlabPreview` at the card's own preview
// resolution, then `LatticeFaceCardDerivation.card`, exactly as
// `WorkspacePlaceholder.refreshLatticeFaceCards` does it.
//
// ★ §0(c), CONFIRMED RATHER THAN ASSUMED: the card needs NO run. Its four numbers
// are a pure function of (depth, bounds, limits, width); the voxel count only
// feeds the mass rows, and it comes from a 48³ preview voxelization that is not
// the run's grid. So a Fast · 64³ job is not the cheapest reproduction of this
// failure — this is — and running one would not make the numbers more true. The
// run is still where R4's certification is demonstrated; it is not where the card
// comes from.

import XCTest
@testable import TopOptFlows
import TopOptKit

final class LatticeStageRepairHisPart: XCTestCase {

    static let strutLineWidthMM = 0.45
    static let densityGCM3 = 1.24            // PLA
    /// The card's own preview grid — `WorkspacePlaceholder.latticeCardPreviewResolution`.
    static let previewResolution = 48

    private var stepPath: String {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent(
                "evidence/2026-08-12-lattice-page-redesign/M2_verticalStand.step")
            .path
    }

    private func writeEvidence(_ name: String, _ text: String) {
        let dir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("evidence/2026-08-17-lattice-stage-repair")
        try? FileManager.default.createDirectory(at: dir,
                                                 withIntermediateDirectories: true)
        try? text.write(to: dir.appendingPathComponent(name), atomically: true,
                        encoding: .utf8)
    }

    /// One card on his part, at one face, at one depth — the shipping path.
    private func card(faceID: Int, depthMM: Double) throws -> LatticeFaceCard {
        let w = Self.strutLineWidthMM
        let preview = try TopOptKit.faceSlabPreview(
            stepPath: stepPath, faceIDs: [faceID], depthsMM: [depthMM],
            resolution: Self.previewResolution)
        return LatticeFaceCardDerivation.card(
            faceID: faceID, depthMM: depthMM,
            heldVoxels: preview.voxels.first ?? 0, spacingMM: preview.spacingMM,
            densityGCM3: Self.densityGCM3, topology: LatticeType.octet,
            minExtrudableWidthMM: w)
    }

    private func pad(_ s: String, _ n: Int) -> String {
        s.count >= n ? s : s + String(repeating: " ", count: n - s.count)
    }

    private func line(_ label: String, _ c: LatticeFaceCard) -> String {
        pad(label, 24)
            + "depth " + pad(String(format: "%.2f mm", c.depthMM), 10)
            + "| density " + pad(c.densityText, 6)
            + "| cells across " + pad(c.cellsText, 6)
            + "| cell " + pad(c.cellText, 10)
            + "| strut " + pad(c.strutText, 9)
            + "| " + c.verdict.label
    }

    /// ★ THE RUN AFTER FIX 1 (§2 — depth and the handle are one value). The depth
    /// the card is derived at is now the depth of the SELECTABLE the drawer is
    /// about, so dragging a handle moves DEPTH and CELLS ACROSS. It does not move
    /// DENSITY, and this test says so rather than implying otherwise — §1 is the
    /// next fix, not this one.
    func testTheThreeNumbersOnHisPartAcrossTheDepthsAHandleCanReach() throws {
        // A face that holds material at 4 mm. Face 0 is the first B-rep face; the
        // preview says how much it holds, and a face holding none is skipped so
        // the readout is never about an empty slab.
        var faceID = -1
        for f in 0..<40 {
            if let c = try? card(faceID: f, depthMM: 4.0), c.heldVoxels > 200 {
                faceID = f
                break
            }
        }
        try XCTSkipIf(faceID < 0, "no face on his part holds material at 4 mm")

        var rows: [String] = []
        var cards: [Double: LatticeFaceCard] = [:]
        for d in [4.0, 6.0, 8.0, 12.0, 24.65] {
            let c = try card(faceID: faceID, depthMM: d)
            cards[d] = c
            rows.append(line(d == 4.0 ? "4.0 mm (the default)"
                                      : String(format: "%.2f mm (dragged)", d), c))
        }

        let base = try XCTUnwrap(cards[4.0])
        // ★ HIS 4 mm DEPTH, RE-DERIVED FROM CORE. Every number has moved off the
        // figures on his screenshot, and each moved toward core's own answer.
        XCTAssertEqual(base.cellText, "1.17 mm", "was 4.93 mm — the LIGHT-end floor")
        XCTAssertEqual(base.densityText, "60%", "was 5% — the band floor")
        XCTAssertEqual(base.cellsText, "3.4", "was 0.8")
        XCTAssertEqual(base.strutDiameterMM, Self.strutLineWidthMM, accuracy: 1e-3,
                       "was 0.32 mm on the app's own law; core's is one bead")
        XCTAssertEqual(base.verdict, .outOfRegime,
                       "★ 3.4 < 5: STILL out of regime at 4 mm, and honestly so — "
                       + "but for ONE reason now, not two. The strut prints.")

        // ★★ AND THE DEPTH THAT CERTIFIES IS REACHABLE. Core's requirement is
        // N* x the DENSE-end floor = 5.87 mm, not the 24.65 mm the old card's
        // arithmetic implied.
        let atSix = try XCTUnwrap(cards[6.0])
        XCTAssertGreaterThanOrEqual(atSix.cellsPerMember, 5.0 - 1e-9,
                                    "★ 6 mm clears the 5-cells floor")
        XCTAssertEqual(atSix.verdict, .certified,
                       "★★ R4: a region on HIS PART certifies at 6 mm depth")

        // ★ AND DENSITY NOW MOVES WITH THE REGION — R1(d), the thing fix 1 could
        // not do. Deeper region -> coarser cell -> LIGHTER lattice.
        let deep = try XCTUnwrap(cards[24.65])
        XCTAssertLessThan(deep.relativeDensity, base.relativeDensity,
                          "★ §1: the density is DERIVED now, and a deeper region "
                          + "gets a lighter lattice")
        XCTAssertEqual(deep.verdict, .certified)

        let report = """
        R1 — THE READOUT ON HIS PART, AFTER FIX 1 AND FIX 2
        part      M2_verticalStand.step
        face      \(faceID)   (\(base.heldVoxels) held voxels at 4 mm, \
        \(base.heldText))
        profile   strut line width \(Self.strutLineWidthMM) mm, PLA
        preview   \(Self.previewResolution)³ (the card's own grid, not the run's)

        \(rows.joined(separator: "\n"))

        HIS SCREENSHOT, FOR COMPARISON (all four wrong, all four app-side)
          depth 4.0 mm | density 5% | cells across 0.8 | cell 4.93 mm | strut 0.32 mm

        VERDICT
          DEPTH        the SELECTABLE's own number — a handle drag reaches the
                       derivation (fix 1; the card was built per GROUP before)
          DENSITY      DERIVED by core: \(base.densityText) at 4 mm, \
        \(deep.densityText) at 24.65 mm. Deeper region -> coarser cell ->
                       LIGHTER lattice. It was 5% at every depth before (fix 2).
          CELLS ACROSS \(String(format: "%.2f", base.cellsPerMember)) at 4 mm -> \
        \(String(format: "%.2f", atSix.cellsPerMember)) at 6 mm -> \
        \(String(format: "%.2f", deep.cellsPerMember)) at 24.65 mm
          STRUT        \(base.strutText) — one bead exactly, from CORE's law. The
                       badge's 2nd problem ("0.32 mm, under your nozzle") is GONE:
                       it was the app's own octet law, 1.4x off.
          in regime?   NO at 4 mm (3.4 < 5) — honestly, and for ONE reason now.
                       ★ YES at 6.00 mm: \(atSix.verdict.label), \
        \(String(format: "%.2f", atSix.cellsPerMember)) cells across, \
        \(atSix.densityText), \(atSix.strutText) strut.
                       The old card implied 24.65 mm was needed. It is 5.87 mm.
        """
        writeEvidence("r1_fix2_card_rederived_on_his_part.txt", report)
        print(report)
    }
}
