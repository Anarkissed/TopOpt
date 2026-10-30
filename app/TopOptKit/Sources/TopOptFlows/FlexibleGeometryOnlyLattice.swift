// FlexibleGeometryOnlyLattice — the SHAPE-ONLY lattice for a calibrate-first filament (task
// 2026-09-29-flexible-screens, round 3 batch B, item 9; maintainer's answer: "Save & Exit
// builds a SHAPE-ONLY lattice that follows the curves, labelled '<filament>: shape only —
// no squish predicted'. Exit always works.").
//
// ★ WHAT IT IS, AND WHAT IT IS NOT. 9 of the 10 filaments have no squish data, so core
// designs nothing for them (calibrate_first: "offered for geometry only",
// flexible_materials.json). This lattice is the APP'S DENSITY CHOICE, not a prediction (R7):
//   * WHERE: core's own lattice mask — `FlexibleScene.latticeMask` (core fills 0 on every
//     mask voxel, −1 elsewhere), so the walls sit exactly where a designed lattice would;
//   * HOW DENSE: from the DRAWN map S (core's squish_fraction of his curves), monotone —
//     softer where he drew softer (S = 1 → the softest end) — and inside the PRINTABLE band,
//     whose ends are cells from core's own planning relation (FlexibleCore.cellSizeMM):
//     no cell finer than `minCellWalls` walls, none coarser than half the lattice depth
//     (capped at `maxCellMM`);
//   * a voxel under two pressed faces takes the FIRMER (a column carries the load of the
//     face above it); a mask voxel under no face is flood-filled by FlexibleLatticeBuilder
//     from its nearest assigned neighbour — the same rule a designed field goes through.
// It never shows an mm prediction: the dent beside it is the drawing ("What you drew").
//
// ★ ONE ROUTE TO THE MASK (memory: "core computed one wall two ways"): the voxel → column
// mapping is the SHADER'S (FlexibleSquishField.pullback: d = p − centroid, t = d·load,
// u = d·x − uMin, v = d·y − vMin, the column at ⌊u/pitch⌋, ⌊v/pitch⌋, entry ≤ t ≤ exit),
// and the mask is core's; FlexibleGeometryOnlyLatticeTests holds its voxel count to
// `FlexibleScene.Info.latticeVoxels`.

import Foundation
import simd
import TopOptKit

public enum FlexibleGeometryOnlyLattice {

    /// The finest cell, in walls (t = beads × bead width): 8 t — a wall is an eighth of it.
    public static let minCellWalls = 8.0
    /// The coarsest cell (mm), whatever the depth.
    public static let maxCellMM = 12.0
    /// The coarsest cell as a share of the (shallowest pressed face's mean) lattice depth.
    public static let maxCellShareOfDepth = 0.5

    /// The printable density band for `topology` and walls of `beads × width`, given the
    /// lattice depth (mm) it has to fit in. Both ends come from core's density ↔ cell
    /// relation: ρ(L) = ρ₁ / L with ρ₁ = cellSizeMM(ρ = 1) (L ∝ 1/ρ in 03 §2).
    public static func band(topology: String, beadsPerWall: Int, beadWidthMM: Double,
                            latticeDepthMM: Double) throws -> ClosedRange<Double> {
        let unit = try FlexibleCore.cellSizeMM(topology: topology, density: 1,
                                               beadsPerWall: beadsPerWall, beadWidthMM: beadWidthMM)
        let t = Double(max(1, beadsPerWall)) * beadWidthMM
        let finest = minCellWalls * t
        let coarsest = max(finest, min(maxCellMM, maxCellShareOfDepth * max(latticeDepthMM, 0)))
        let hi = min(0.9, unit / finest)     // the firm end: the finest printable cell
        let lo = max(0.05, min(hi, unit / coarsest))
        return lo...hi
    }

    /// ρ for a column whose drawn squish fraction is `s` (1 = the deepest squish → the softest).
    public static func density(s: Double, band: ClosedRange<Double>) -> Double {
        let x = min(1, max(0, s.isFinite ? s : 0))
        return band.upperBound - x * (band.upperBound - band.lowerBound)
    }

    /// One pressed face: its stack (core's frame and columns) and its drawn S per column.
    public struct Face {
        public let stack: FlexStackInfo
        public let s: [Double]
        public init(stack: FlexStackInfo, s: [Double]) { self.stack = stack; self.s = s }
    }

    /// The column of `face` holding model point `p` (the shader's mapping), or nil.
    static func column(_ p: SIMD3<Double>, _ st: FlexStackInfo) -> Int? {
        guard st.pitchMM > 0, st.nu > 0, st.nv > 0 else { return nil }
        let d = p - st.centroid
        let u = simd_dot(d, st.xAxis) - st.uMin, v = simd_dot(d, st.yAxis) - st.vMin
        let iu = Int((u / st.pitchMM).rounded(.down)), iv = Int((v / st.pitchMM).rounded(.down))
        let c = st.column(iu, iv)
        guard c >= 0, c < st.columns.count else { return nil }
        let t = simd_dot(d, st.load)
        let col = st.columns[c]
        guard t >= col.entryT, t <= col.exitT else { return nil }
        return c
    }

    /// The shape-only field on core's grid: −1 off the mask (core's own sentinel), ρ where a
    /// pressed face's column reaches, 0 elsewhere in the mask (flood-filled by the builder).
    /// When NO voxel is reached, every mask voxel takes the band's middle — a uniform
    /// shape-only lattice rather than none.
    public static func field(mask: FlexDensityField, faces: [Face], band: ClosedRange<Double>) -> FlexDensityField {
        var rho = [Float](repeating: -1, count: mask.density.count)
        var assigned = 0
        let sp = mask.spacing
        for k in 0..<mask.nz { for j in 0..<mask.ny { for i in 0..<mask.nx {
            let n = mask.index(i, j, k)
            guard n < mask.density.count, mask.density[n] > -0.5 else { continue }
            rho[n] = 0
            // core's voxel centre: origin (the grid's CORNER) + (i + ½)·h
            let p = mask.origin + SIMD3<Double>(Double(i) + 0.5, Double(j) + 0.5, Double(k) + 0.5) * sp
            var best: Double = 0
            for f in faces {
                guard let c = column(p, f.stack), c < f.s.count else { continue }
                best = max(best, density(s: f.s[c], band: band))   // the firmer wins
            }
            if best > 0 { rho[n] = Float(best); assigned += 1 }
        } } }
        if assigned == 0 {
            let mid = Float(0.5 * (band.lowerBound + band.upperBound))
            for n in rho.indices where rho[n] > -0.5 { rho[n] = mid }
        }
        return FlexDensityField(nx: mask.nx, ny: mask.ny, nz: mask.nz, spacing: mask.spacing,
                                origin: mask.origin, density: rho, owner: mask.owner)
    }

    /// The mask voxels in `field` (core's count is `FlexibleScene.Info.latticeVoxels`).
    public static func maskVoxels(_ field: FlexDensityField) -> Int {
        field.density.reduce(0) { $0 + ($1 > -0.5 ? 1 : 0) }
    }
}
