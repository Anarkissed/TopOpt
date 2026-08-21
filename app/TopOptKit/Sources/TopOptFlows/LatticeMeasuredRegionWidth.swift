// LatticeMeasuredRegionWidth — the member width Auto and Fit size their cell from,
// MEASURED by core rather than read off the user's declaration.
//
// ★★ THE DEFECT (maintainer, 2026-08-20: "I made sure the walls here are *exactly*
// 20mm wide. That's 4mm cells 5x wide. Yet I am seeing holes, and much smaller sized
// cells than what should be expected when I put 'auto' on everything").
//
// He is right, and the arithmetic is not subtle. Both Auto's swept window and Fit's
// per-region cell were handed `region.depthMM` — HOW FAR THE LATTICE REACHES IN FROM
// THE DECLARED FACE — and used it as if it were the thickness of the member:
//
//     LatticeAutoPosture.applied(… regionWidthsMM: includes.map { $0.depthMM } …)
//
// Those are different quantities. The cells-per-member ceiling is W / N*, where W is
// the MATERIAL's thickness — the same `local_member_thickness_mm` core's own floor
// reads. A declared depth is a statement about the lattice, not about the wall.
// Measured, at his bead of 0.42 mm with N* = 5:
//
//     declared depth   5 mm  ->  Auto's window  1.09 mm     (his "tiny cells")
//     declared depth  10 mm  ->                 2.00 mm
//     declared depth  11 mm  ->                 2.20 mm
//     declared depth  20 mm  ->                 4.00 mm     (what a 20 mm wall holds)
//
// So declaring a lattice HALF WAY into a 20 mm wall halved the cell, on a wall whose
// material never changed. The error only ever runs one way — a declared depth cannot
// exceed the material it is declared into — so the cell was always too FINE, which is
// more struts, more plastic and longer bakes, the exact opposite of what he asked
// "minimize plastic" for.
//
// ★ AND IT EXPLAINS THE HOLES TOO. A finer cell needs a denser strut to clear one
// bead: at 4.00 mm on a 20 mm slab core plans 864 cells with ZERO rejections down to
// rho = 0.08, but the same slab at rho = 0.05 has every one of those 864 cells
// rejected `unprintable`. Driving the cell below what the wall can hold pushes the
// thin end of a graded band under the nozzle, and those cells fall back to solid —
// holes, in the middle of material thick enough to lattice.
//
// ★ THE MEASUREMENT IS CORE'S, NOT A SECOND ONE. The scene already carries
// `memberThicknessMM` — `topopt::local_member_thickness_mm` per occupancy voxel, the
// SAME field the cells-per-member floor tests against. Reading the window off that
// field is what makes the ceiling agree with the floor: the cell Auto reaches for is,
// by construction, one the floor will accept.

import Foundation
import simd

public enum LatticeMeasuredRegionWidth {

    /// The coarsest cell the latticed material can hold, expressed as ONE width in mm.
    /// Empty when core measured nothing.
    ///
    /// ★★★ IT RETURNS ONE WIDTH, AND THAT IS THE WHOLE POINT — A REGRESSION I SHIPPED
    /// AND HE CAUGHT IN ONE LOOK ("It's worse now....").
    ///
    /// The first version of this returned the THINNEST and THICKEST measured widths, on
    /// the reasoning that `autoWindowMM` wants a ceiling and a floor. That widened Auto's
    /// window from one rung to several — and core's swept planner then walks DOWN that
    /// ladder, not up. `plan_cell_sizes` takes the level printability DEMANDS:
    ///
    ///     if (all_candidates && need_max == L && cap_min >= L)   // need = finest that prints
    ///
    /// so every extra rung below the ceiling is a rung it will descend to. Handing it a
    /// wider ladder produced FINER cells over most of the part, and finer cells push the
    /// thin end of a graded band under the nozzle — which culls them to solid. Sparse
    /// clumps of struts in a mostly empty wall: strictly worse than the too-fine-but-
    /// uniform picture it replaced.
    ///
    /// ★ SO THE CEILING IS THE ONLY NUMBER TO GIVE IT. One width in means `loFit == hi`
    /// inside `autoWindowMM`, which means one rung, which means the planner has nowhere
    /// to descend to: every cell it plans is the coarsest the material holds. That is
    /// what "minimize plastic" asks for, and it is also what the code did BEFORE this
    /// file existed — the defect was never the single rung, it was that the rung was
    /// derived from the declared depth instead of the measured wall.
    ///
    /// ★ WHAT THIS DELIBERATELY DOES NOT DO. On a part whose regions differ in
    /// thickness, one rung at the thickest means the thinner ones are culled by the
    /// cells-per-member floor rather than given their own finer cell. That is a real
    /// limit and it is NOT repaired here: the mode that sizes each region separately is
    /// FIT, which picks `W / N*` per region by construction and culls nothing. Widening
    /// the swept window to imitate it does not work, for the reason above.
    ///
    /// - Note: `occupancy` is ALREADY masked to the declared regions, so every voxel
    ///   considered is material the lattice will actually be built into. A `+infinity`
    ///   width is core's "thicker than the EDT cap measured" sentinel; it cannot bound a
    ///   ceiling, so it is excluded rather than treated as a length.
    public static func boundsMM(occupancy: LatticeVoxelGrid,
                                memberThicknessMM: [Double]) -> [Double] {
        guard memberThicknessMM.count == occupancy.values.count else { return [] }
        var hi = 0.0
        for i in 0..<occupancy.values.count where occupancy.values[i] > 0.5 {
            let w = memberThicknessMM[i]
            guard w.isFinite, w > 0 else { continue }
            if w > hi { hi = w }
        }
        return hi > 0 ? [hi] : []
    }

    /// The measured member width under ONE declared region, in mm — Fit's own question,
    /// asked of the material instead of the declaration.
    ///
    /// Fit sizes each region independently at `W / N*`, so it needs a single number per
    /// region rather than a ladder. The THICKEST material under the region is the right
    /// one: it is the coarsest cell that region can hold anywhere, and core's per-voxel
    /// floor still culls the cells that land on thinner material. Taking the thinnest
    /// instead would size every region for its worst voxel — the too-fine direction
    /// this whole file exists to stop.
    ///
    /// Returns 0 when core measured nothing under the region, and the caller must then
    /// fall back rather than invent a width.
    public static func widthMM(region: LatticeRegionSpec,
                               occupancy: LatticeVoxelGrid,
                               memberThicknessMM: [Double]) -> Double {
        guard memberThicknessMM.count == occupancy.values.count else { return 0 }
        var hi = 0.0
        for k in 0..<occupancy.nz {
            for j in 0..<occupancy.ny {
                for i in 0..<occupancy.nx {
                    let n = (k * occupancy.ny + j) * occupancy.nx + i
                    guard occupancy.values[n] > 0.5 else { continue }
                    let w = memberThicknessMM[n]
                    guard w.isFinite, w > 0, w > hi else { continue }
                    let p = SIMD3<Double>(
                        Double(occupancy.origin.x) + Double(i) * Double(occupancy.spacing.x),
                        Double(occupancy.origin.y) + Double(j) * Double(occupancy.spacing.y),
                        Double(occupancy.origin.z) + Double(k) * Double(occupancy.spacing.z))
                    if LatticeRegionMask.contains(p, region: region) { hi = w }
                }
            }
        }
        return hi
    }
}
