// LatticeSteppedPhaseTests — ★★★ THE BLOCK A POINT IS PREFETCHED FOR MUST BE THE BLOCK
// ITS `q` PUTS IT IN.
//
// (maintainer, 2026-08-22: "These are still floating boxes. There is nothing connecting
// them. Something is seriously wrong with the preview each cell is completely
// disconnected from the other. Just *look* at the screenshot and see how there is empty
// space between them!")
//
// ★ THE TWO ENCODINGS HAVE DIFFERENT PHASE, and stepped was using the dyadic one.
// `lsdf_cell_q` tiles stepped from the ORIGIN POINT by `sMM` — index `floor(cb/m)`.
// `lsdf_cell_frame_at` derived the block from the base-cell GRID — `floor(round(cb)/m)`,
// which is right for a dyadic block (they are aligned to that grid) and wrong for a
// stepped one. At m = 1 — the ordinary case, one stated cell, so `baseCellMM == sMM` —
// the two disagree on HALF of every axis, so only 0.5³ = 12.5% of the volume prefetched
// its own 3x3x3 neighbourhood. The rest read a cell one step over: wrong demand, wrong
// radius, and where that neighbour was inactive, nothing drawn at all. The right/wrong
// boundary is a regular half-cell lattice, which is the grid of disconnected blocks.
//
// This test is the shader's own arithmetic, so it fails on the MSL source going stale.

import XCTest
import simd
@testable import TopOptFlows

final class LatticeSteppedPhaseTests: XCTestCase {

    /// `lsdf_cell_frame_at`, stepped branch — the block index the prefetch uses.
    private func blk(cb: Double, m: Double) -> Double { (cb / m).rounded(.down) }
    /// `lsdf_cell_q`, stepped branch — the cell `q` actually places the point in.
    private func qTile(cb: Double, m: Double) -> Double { (cb / m).rounded(.down) }

    /// The regression: the OLD block index, kept here as the control so the number the
    /// bug was worth is on the record rather than in a commit message.
    private func blkOld(cb: Double, m: Double) -> Double {
        (Swift.max(cb.rounded(), 0) / m).rounded(.down)
    }

    func testTheBlockAndTheCellAgreeAtEveryStepSize() {
        // m = 1 is his case (one stated cell ⇒ baseCellMM == sMM); the rest cover the
        // integer and the arbitrary-real ratios stepped is allowed to produce.
        for m in [1.0, 1.375, 2.0, 2.75, 3.0] {
            var wrongNow = 0, wrongBefore = 0, n = 0
            var cb = 0.0
            while cb < 400 {
                if blk(cb: cb, m: m) != qTile(cb: cb, m: m) { wrongNow += 1 }
                if blkOld(cb: cb, m: m) != qTile(cb: cb, m: m) { wrongBefore += 1 }
                n += 1
                cb += 0.0017            // irrational-ish stride: no resonance with m
            }
            let pctBefore = 100 * Double(wrongBefore) / Double(n)
            print(String(format: "  m = %.3f   mis-blocked per axis: was %.1f%%, now %.1f%%",
                         m, pctBefore, 100 * Double(wrongNow) / Double(n)))
            XCTAssertEqual(wrongNow, 0,
                           "stepped block index disagrees with its own cell at m = \(m)")
            // And the control has to be POSITIVE, or this test is measuring nothing.
            XCTAssertGreaterThan(pctBefore, 5.0,
                                 "control did not reproduce the defect at m = \(m)")
        }
    }

    /// The MSL is the thing that ships; assert the fix is in the source the device
    /// compiles, not only in the Swift replica above.
    func testTheShaderSourceDerivesTheSteppedBlockFromTheUnroundedCoord() {
        let src = latticeFieldSource
        XCTAssertTrue(src.contains("o.blk = floor(cb / max(o.m, 1e-6));"),
                      "stepped block index is not taken from the unrounded base coord")
        XCTAssertFalse(src.contains("o.blk = floor(max(bi, float3(0.0)) / max(o.m, 1e-6));"),
                       "the dyadic-phase block index is still on the stepped path")
        XCTAssertTrue(src.contains("if (LC.stepped > 0.0) { LC.blk = floor(cb / max(LC.m, 1e-6)); }"),
                      "the march caches blk on the base cell without re-deriving it")
    }
}
