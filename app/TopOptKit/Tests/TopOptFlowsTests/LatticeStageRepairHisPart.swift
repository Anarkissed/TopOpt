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
            bounds: TopOptKit.latticeCellBounds(topology: "octet",
                                                minExtrudableWidthMM: w),
            limits: TopOptKit.latticeLimits(topology: "octet"),
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
        // ★ THE FAILURE, ON HIS PART: the default depth reproduces his card.
        XCTAssertEqual(base.densityText, "5%")
        XCTAssertEqual(base.cellText, "4.93 mm")
        XCTAssertEqual(base.cellsText, "0.8")
        XCTAssertEqual(base.verdict, .outOfRegime)

        // ★ AFTER FIX 1 THE DEPTH IS REACHABLE, SO CELLS ACROSS MOVES. It moves
        // the way the card's own arithmetic says it must — depth / cell — and the
        // cell here is still the card's own (that is §1's defect, not §2's).
        let deep = try XCTUnwrap(cards[24.65])
        XCTAssertGreaterThan(deep.cellsPerMember, base.cellsPerMember,
                             "★ §2: dragging the handle moves CELLS ACROSS")
        XCTAssertEqual(deep.cellsPerMember, 5.0, accuracy: 0.02,
                       "24.65 mm is exactly 5 cells at the card's 4.93 mm cell")

        // ★ AND DENSITY DOES NOT MOVE — R1(d), stated rather than glossed.
        XCTAssertEqual(deep.densityText, "5%",
                       "★ §1 is NOT fixed by this: the density is still the band "
                       + "floor at every depth")

        let report = """
        R1 — THE READOUT ON HIS PART, AFTER FIX 1 (§2: depth is one value)
        part      M2_verticalStand.step
        face      \(faceID)   (\(base.heldVoxels) held voxels at 4 mm, \
        \(base.heldText))
        profile   strut line width \(Self.strutLineWidthMM) mm, PLA
        preview   \(Self.previewResolution)³ (the card's own grid, not the run's)

        \(rows.joined(separator: "\n"))

        VERDICT
          DEPTH        now the SELECTABLE's own number — a handle drag reaches the
                       derivation (it did not before; the card was built per GROUP)
          CELLS ACROSS moves with it: \(String(format: "%.2f", base.cellsPerMember)) \
        at 4 mm -> \(String(format: "%.2f", deep.cellsPerMember)) at 24.65 mm
          DENSITY      UNCHANGED at 5% — the band floor, at every depth. §1 next.
          in regime?   NO at his 4 mm. The card says 24.65 mm is what it takes;
                       core says 5.87 mm. That gap is §1's defect, not §2's.
        """
        writeEvidence("r1_fix1_depth_on_his_part.txt", report)
        print(report)
    }
}
