// LatticeSolidNotHoleTests — ★★★ A CELL THE RUN LEAVES SOLID MUST DRAW AS SOLID
// (maintainer, 2026-08-21: "I want to be able to view the solid parts of the piece
// instead of holes").
//
// ★★ WHAT A "HOLE" ACTUALLY WAS, and it is the whole preview↔algorithm question in one
// place. The shell's clip discarded every fragment inside a DECLARED REGION. But the run
// does not lattice every voxel of a region: a member too thin to hold N* cells stays
// SOLID (grading.cpp's L4) and a strut that cannot clear one bead stays SOLID
// (`fallback_strut_unprintable`). The shell was cut there anyway and no strut replaced
// it, so the viewport showed a VOID where the algorithm puts solid plastic.
//
// The preview had two states — "lattice here" and "not in region" — and the run has
// three. The missing one is "solid, because the run refuses to lattice this", and every
// hole he has reported was that state rendered as nothing.
//
// ★ THE FIELD THAT KNOWS IS THE CELL FIELD. Its R channel carries the cell's demand, or
// NEGATIVE where the cell is inactive — which is exactly "the run leaves this solid".
// `shellClipCellTexture` had been exposed for this ("ONE SOURCE OF TRUTH, NOT TWO") and
// never connected; the shell was still asking the REGION field, which cannot answer the
// question because a region is a declaration and not a verdict.

import XCTest
import simd
import TopOptKit
@testable import TopOptFlows

final class LatticeSolidNotHoleTests: XCTestCase {

    /// ★★★ THE PREDICATE, AS THE SHADER COMPUTES IT. `shell_is_latticed` returns true —
    /// and the shell then discards — ONLY where the cell field is non-negative.
    /// Mirrored here because the MSL itself cannot be unit-tested, and the polarity is
    /// the entire fix: getting it backwards hides the part instead of the hole.
    private func shellStandsDown(cellValue: Float, enabled: Bool = true) -> Bool {
        guard enabled else { return false }
        return cellValue >= 0
    }

    func testTheShellKeepsItsFragmentWhereTheRunLeavesSolid() {
        XCTAssertFalse(shellStandsDown(cellValue: -1),
                       "★ HIS ASK: an INACTIVE cell is material the run builds solid, so "
                       + "the shell must stay and the part must read as solid — not as a "
                       + "hole he can see through")
        XCTAssertTrue(shellStandsDown(cellValue: 0),
                      "★ …and an active cell at zero demand is still latticed, so the "
                      + "shell stands down there. 0 is a DEMAND, not an absence.")
        XCTAssertTrue(shellStandsDown(cellValue: 0.42),
                      "a graded active cell is latticed")
    }

    /// ★ AND WITH NO LATTICE IN THE FRAME THE SHELL IS UNTOUCHED — the neutral binding
    /// reads −1 and the enable flag is 0, so a part with no lattice draws exactly as it
    /// did before any of this existed.
    func testAPartWithNoLatticeIsUnclipped() {
        XCTAssertFalse(shellStandsDown(cellValue: -1, enabled: false))
        XCTAssertFalse(shellStandsDown(cellValue: 0.9, enabled: false),
                       "★ disabled must clip NOTHING, whatever the texture happens to "
                       + "hold — the flag is the gate, not the value")
    }

    /// ★★ THE SAMPLE MUST BE NEAREST, NOT LINEAR, and this is the reason written down.
    /// The cell field is an ACTIVATION, not a distance: interpolating across the −1
    /// boundary blends "latticed" into "solid" and puts a half-transparent fringe one
    /// cell wide around every solid island. A filter that is right for a signed distance
    /// is wrong for a flag.
    func testTheSourceSamplesTheCellFieldWithoutInterpolating() throws {
        var url = URL(fileURLWithPath: #filePath)
        url.deleteLastPathComponent(); url.deleteLastPathComponent()
        url.deleteLastPathComponent()
        let src = try String(
            contentsOf: url.appendingPathComponent(
                "Sources/TopOptFlows/MetalMeshView.swift"), encoding: .utf8)
        let fn = try XCTUnwrap(src.range(of: "inline bool shell_is_latticed"))
        let body = String(src[fn.lowerBound...].prefix(900))
        XCTAssertTrue(body.contains("filter::nearest"),
                      "★ an activation test must not interpolate")
        XCTAssertTrue(body.contains("cellTex"),
                      "★ the shell must ask the CELL field — a region is a declaration, "
                      + "not a verdict about whether the run latticed it")
        XCTAssertFalse(body.contains("regionTex.sample"),
                       "★ …and must no longer ask the region field, which is what cut "
                       + "the shell where the run builds solid")
    }
}
