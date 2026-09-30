// FlexibleFE — the squish sim's constants and copy, in ONE place (task
// 2026-09-29-flexible-screens, round 5 batch G; maintainer: "is there a way to ensure that the
// squish sim also squeezes out the sides of the object? I'd like it to actually bend and move
// and squish like it would in real life. Also, I'd like a way to play the different sims if
// there are multiple ways to squeeze/squish a model").
//
// ★ WHAT BATCH G IS. Each squeeze group is ONE 3D linear-elastic solve of the whole part (core's
// fea_solve_mgcg_matfree through the app's bridge: FlexibleKit+Squish, flexible_squish_fe.cpp):
// its force on its pressed faces, the resting faces held, the sides free so they BULGE. One
// displacement field moves the ghost body, the bent heat plane and the lattice walls together
// (FlexibleFEField). It is scaled so its deepest zone moves exactly core's deepest squish —
// the numbers on screen stay core's; the field gives the SHAPE.

import Foundation
import TopOptKit

public enum FlexibleFE {
    /// One Poisson's ratio for every voxel (an ASSUMPTION — the curve tables carry no lateral
    /// data; 0.3 is representative of TPMS lattices and clear of the Hex8's volumetric locking).
    public static let poisson = 0.3
    /// The display solve's relative residual (≤ 0.5 % of max|u| from a 1e-8 solve on C1's pad).
    public static let tolerance = 1e-4
    /// Past this, the sim falls back to the column squish.
    public static let deadlineMS = 20_000.0
    /// The coarsening rule's box limits (voxels): ×1 up to boxLimit1, ×2 up to boxLimit2, else ×4.
    public static let boxLimit1 = 120_000
    public static let boxLimit2 = 960_000
    /// s · gmax ≤ this: x = p + s·u(p) is injective (the planes never cross), det ≥ 0.125, and the
    /// fixed-point inverse converges geometrically.
    public static let safeGradient = 0.5
    /// The inverse map's fixed-point iterations (GPU and Swift twin alike) and its early exit.
    public static let pullbackIterations = 8
    public static let pullbackTolMM: Float = 1e-3
    /// The calibration's deepest zone: columns within 90 % of the deepest core squish.
    public static let deepZone = 0.9
    /// ★ The calibration factor k is kept inside this band (the design's own physics check on
    /// C1's pad): beyond it the 3D sim and core's columns disagree — typically a Covered skin's
    /// plates and walls carrying the load in parallel, which the columns ignore — and one scalar
    /// stretched to core's depth there would move everything else by that factor (his project with
    /// [Face 5 rests]: k 13.6 sank a soft spot 20 mm through his 20 mm pad). Not for a shape-only
    /// lattice (its law is in relative units: k is a unit conversion there).
    public static let calibrationBand: ClosedRange<Double> = 0.5...2
    /// |Σf| ≤ this · Σ|f|: a balanced squeeze (the bridge's rule, said here for the tests).
    public static let balanced = 0.02
    /// The bridge's control bit that bonds every rest (the design's rule): the app's one retry when a
    /// solve whose rests slide does not converge.
    public static let bondedRests = 2048

    /// The FE grid's coarsening factor — the Swift twin of `flexible_squish_coarsen`
    /// (FlexibleSquishCoarsenTests holds the two together).
    public static func coarsen(nx: Int, ny: Int, nz: Int) -> Int {
        let box = max(nx, 0) * max(ny, 0) * max(nz, 0)
        if box <= boxLimit1 { return 1 }
        if box <= boxLimit2 { return 2 }
        return 4
    }

    /// The FE grid's spacing for a scene grid (mm) — the main page cuts its overlay this fine, so
    /// a big flat triangle bends with the lattice skin inside it.
    public static func spacing(sceneNX nx: Int, ny: Int, nz: Int, spacing: Double) -> Double {
        spacing * Double(coarsen(nx: nx, ny: ny, nz: nz))
    }

    // MARK: copy (one line each, DS tokens only)

    /// The player's note while the shown group's sim runs.
    public static let pending = "Simulating the squish…"
    /// The player's note when the shown group's sim failed (core's words behind the (i)).
    public static let failed = "Simple squish · the sim failed"
    /// The Squish legend's (i), in FE mode — one sentence. `stiffer`: the sim found the part this
    /// many times stiffer than core's columns (k past its band) — said, since it then moves less
    /// than the map reads. `largeStrain`: even the page's ×k is past s · gmax ≤ ½. `bonded`: the
    /// sliding rests' solve did not settle and the one retry held every rest fast (a stiffer
    /// picture) — said.
    public static func info(exaggeration k: Int, stiffer: Double? = nil, largeStrain: Bool = false, bonded: Bool = false) -> String {
        let sim = bonded ? "a linear 3D sim with every rest held fast (sliding, it did not settle)" : "a linear 3D sim"
        if largeStrain {
            // even ×1 is past s · gmax ≤ ½: the linear sim has left small strain here
            return "The shape moves by \(sim) that leaves small strain here, so the picture can fold where real TPU would stiffen — tap here, then the part, for core's mm."
        }
        if let r = stiffer, r > 1 {
            return String(format: "The shape is drawn %d× deeper and moves by %@ that finds this part %.0f× stiffer than core's columns (its skin and walls carry load), so it moves less than the map reads — tap here, then the part, for core's mm.", k, sim, r)
        }
        if let r = stiffer, r > 0, r < 1 {
            return String(format: "The shape is drawn %d× deeper and moves by %@ that finds this part %.0f× softer than core's columns, so it moves more than the map reads — tap here, then the part, for core's mm.", k, sim, 1 / r)
        }
        return "The shape is drawn \(k)× deeper and moves by \(sim) scaled to core's squish; real TPU stiffens and thin walls can fold — tap here, then the part, for the true mm."
    }
    /// The Squish legend's (i) after a failed sim — one sentence, core's words kept.
    public static func failedInfo(_ why: String, exaggeration k: Int) -> String {
        let w = why.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: ". ", with: "; ")
        let words = w.hasSuffix(".") ? String(w.dropLast()) : w
        return "The map is drawn \(k)× deeper and moves by the simple column squish because the 3D sim failed (\(words)) — tap here, then the part, for the true mm."
    }
}
