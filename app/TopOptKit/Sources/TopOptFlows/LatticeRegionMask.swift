// LatticeRegionMask.swift — ★ THE PREVIEW SHOWS THE LATTICE WHERE IT WILL BE
// (maintainer, 2026-08-17: "Can you confirm that the preview will only show what
// is *actually* set to lattice (i.e. the primitives)").
//
// ★ THE ANSWER WAS NO, AND IT WAS A REAL GAP. `LatticeSDFScene` bakes its
// occupancy grid from `mesh.positions / indices / bounds` — the WHOLE PART — and
// there is no region or primitive input anywhere in the preview path. So the
// raymarched struts filled the entire part interior no matter which selectables
// were set to Lattice. Picture ≠ run, which on this project is a defect and not
// a cosmetic one: the whole page exists so the picture predicts the run.
//
// ★ THIS IS THE SAME PREDICATE CORE USES, IN THE SAME SHAPE. A lattice region is
// pure geometry (`LatticeRegionSpec`): a FACE slab is `origin + s·normal`,
// s ∈ [0, depth], clipped to 2·halfU × 2·halfW; a BOLT is a cylinder about
// `axisPoint + t·axisDir`, t ∈ [−halfLength, +halfLength]. Core evaluates them
// pointwise as `ClearanceGeometry` predicates; so does this. Nothing is
// approximated and nothing new is authored — if the two ever disagree it is
// because the SPEC changed, not because the picture drifted.
//
// ★ EMPTY MEANS "NO CLIPPING", DELIBERATELY. The lattice SETTINGS page previews a
// sample block with no regions declared at all ("A sample part. Your settings,
// not your result."), and clipping that to nothing would blank a preview whose
// job is to show the cell. So an empty region list leaves the occupancy exactly
// as it was — which is also what makes this change inert for every surface that
// does not declare regions.
//
// Pure Float math over the grid, headlessly testable, no GPU.

import Foundation
import simd

public enum LatticeRegionMask {

    /// Is `p` (world mm) inside this region's geometry?
    ///
    /// ★ THE FACE SLAB'S AXES. `normal` already points INTO the part (the
    /// emission flips it), so `s` runs 0…depth going inward. The two in-plane
    /// axes are any orthonormal pair perpendicular to it — the extents are
    /// symmetric in both, so which pair does not matter, only that they are
    /// perpendicular and unit.
    public static func contains(_ p: SIMD3<Double>, region: LatticeRegionSpec) -> Bool {
        switch region.kind {
        case .face:
            let n = unit(region.normal)
            guard simd_length(n) > 0.5, region.depthMM > 0 else { return false }
            let d = p - region.origin
            let s = simd_dot(d, n)
            guard s >= 0, s <= region.depthMM else { return false }
            let (u, v) = basis(n)
            let du = abs(simd_dot(d, u)), dv = abs(simd_dot(d, v))
            return du <= region.halfUMM && dv <= region.halfWMM
        case .bolt:
            let a = unit(region.axisDir)
            guard simd_length(a) > 0.5, region.radiusMM > 0 else { return false }
            let d = p - region.axisPoint
            let t = simd_dot(d, a)
            guard abs(t) <= region.halfLengthMM else { return false }
            return simd_length(d - a * t) <= region.radiusMM
        }
    }

    /// True when `p` is inside ANY of the regions that will actually be latticed.
    ///
    /// ★ ONLY `include` REGIONS COUNT. An `exclude` region is frozen SOLID — it
    /// carries no lattice at all — so showing struts there would be the same lie
    /// in the other direction.
    public static func contains(_ p: SIMD3<Double>, regions: [LatticeRegionSpec]) -> Bool {
        for r in regions where r.role == .include {
            if contains(p, region: r) { return true }
        }
        return false
    }

    /// ★ CLIP AN OCCUPANCY GRID TO THE DECLARED REGIONS.
    ///
    /// Returns the grid unchanged when no INCLUDE region is declared — see the
    /// file note: the settings page's sample block has none, and blanking it
    /// would break a preview whose job is to show the cell.
    /// ★★ WHAT AN EMPTY REGION LIST MEANS — AND IT IS NOT ONE ANSWER
    /// (maintainer, 2026-08-18: "Why does the lattice preview show the *entire*
    /// model as lattice? It should only show the regions that have been set as
    /// 'Lattice'. Everything else should stay solid").
    ///
    /// ★ THE DEFECT WAS AN IMPLICIT DEFAULT. `clipped` returned the grid
    /// UNCHANGED when no include region existed — correct for the settings
    /// page's sample block, where there are no regions by construction and the
    /// whole sample should lattice, and catastrophically wrong on the STAGE,
    /// where "no include region" means the user has declared nothing and the
    /// honest picture is a solid part. One function, two callers, opposite
    /// needs, and no way to tell them apart — so the caller says which.
    public enum EmptyRegionPolicy: Equatable, Sendable {
        /// No regions ⇒ the whole grid latticed. The settings-page SAMPLE, whose
        /// entire subject is the lattice itself.
        case latticeEverything
        /// No regions ⇒ nothing latticed. The STAGE: the user has declared no
        /// lattice, so none is drawn.
        case latticeNothing
    }

    public static func clipped(_ grid: LatticeVoxelGrid,
                               to regions: [LatticeRegionSpec],
                               whenEmpty: EmptyRegionPolicy = .latticeEverything)
        -> LatticeVoxelGrid {
        guard regions.contains(where: { $0.role == .include }) else {
            switch whenEmpty {
            case .latticeEverything: return grid
            case .latticeNothing:
                var out = grid
                for i in 0..<out.values.count { out.values[i] = 0 }
                return out
            }
        }
        var out = grid
        var i = 0
        for k in 0..<grid.nz {
            for j in 0..<grid.ny {
                for x in 0..<grid.nx {
                    if out.values[i] != 0 {
                        let p = SIMD3<Double>(
                            Double(grid.origin.x) + Double(x) * Double(grid.spacing.x),
                            Double(grid.origin.y) + Double(j) * Double(grid.spacing.y),
                            Double(grid.origin.z) + Double(k) * Double(grid.spacing.z))
                        if !contains(p, regions: regions) { out.values[i] = 0 }
                    }
                    i += 1
                }
            }
        }
        return out
    }

    /// ★ A DEMAND FIELD THAT ENCODES EACH REGION'S OWN DENSITY (maintainer,
    /// 2026-08-17: "Density is controllable in each region - but it is not
    /// updating the lattice preview of it").
    ///
    /// ★ WHY A DEMAND FIELD AND NOT A SECOND UNIFORM. The raymarcher grades a
    /// strut's radius from ONE number per cell — `uniformRho` when there is no
    /// demand grid, and otherwise
    ///
    ///     rho = rhoMin + (rhoMax - rhoMin) * pow(demand, gamma)
    ///
    /// So a preview that shows two regions at two densities needs a PER-CELL
    /// input, which is exactly what the demand grid is. Inverting that mapping
    /// gives the demand value each region must carry to come out at its own rho:
    ///
    ///     demand = ((rho - rhoMin) / (rhoMax - rhoMin)) ^ (1 / gamma)
    ///
    /// — so nothing about the shader changes, and the number on the card is the
    /// number the struts are drawn at.
    ///
    /// Returns nil when NO region states a density: there is then nothing to
    /// grade by and the caller should keep whatever field it already had (the
    /// run's stress field, or none at all).
    public static func densityDemand(like grid: LatticeVoxelGrid,
                                     regions: [LatticeRegionSpec],
                                     rhoMin: Double, rhoMax: Double,
                                     gamma: Double) -> LatticeVoxelGrid? {
        let stated = regions.filter {
            $0.role == .include && ($0.relativeDensity ?? 0) > 0
        }
        guard !stated.isEmpty, rhoMax > rhoMin, gamma > 0 else { return nil }

        /// The demand value that comes back out of the shader as `rho`.
        func demand(for rho: Double) -> Float {
            let t = (rho - rhoMin) / (rhoMax - rhoMin)
            return Float(pow(Swift.min(Swift.max(t, 0), 1), 1.0 / gamma))
        }
        var out = grid
        var i = 0
        for k in 0..<grid.nz {
            for j in 0..<grid.ny {
                for x in 0..<grid.nx {
                    let p = SIMD3<Double>(
                        Double(grid.origin.x) + Double(x) * Double(grid.spacing.x),
                        Double(grid.origin.y) + Double(j) * Double(grid.spacing.y),
                        Double(grid.origin.z) + Double(k) * Double(grid.spacing.z))
                    // The FIRST stating region that contains this voxel wins —
                    // the same first-match rule the emission's own region order
                    // gives the run, so the picture and the job agree about an
                    // overlap instead of averaging it into a third answer.
                    var d: Float = 0
                    for r in stated where contains(p, region: r) {
                        d = demand(for: r.relativeDensity ?? 0)
                        break
                    }
                    out.values[i] = d
                    i += 1
                }
            }
        }
        return out
    }

    // MARK: helpers

    static func unit(_ v: SIMD3<Double>) -> SIMD3<Double> {
        let l = simd_length(v)
        return l > 1e-12 ? v / l : .zero
    }

    /// Any orthonormal pair perpendicular to `n`.
    static func basis(_ n: SIMD3<Double>) -> (SIMD3<Double>, SIMD3<Double>) {
        let a = abs(n.x) < 0.9 ? SIMD3<Double>(1, 0, 0) : SIMD3<Double>(0, 1, 0)
        let u = unit(simd_cross(n, a))
        return (u, unit(simd_cross(n, u)))
    }
}
