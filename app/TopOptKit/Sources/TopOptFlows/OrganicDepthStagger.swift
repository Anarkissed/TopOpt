import Foundation
import simd

/// ★★★ DEPTH VARIATION, AS A TEST FOR A CORE CHANGE (his instruction, 2026-09-08: "the
/// cells are nearly uniform going through the depth of the lattice. In reality there is
/// a lot of variation. Where you see through a window on the first layer, you see a
/// strut right in the middle of the next … I would like you to implement it into the
/// preview as a *test* for the core algorithm update").
///
/// ★ WHAT THIS IS NOT. It is not a fix, and it is not what the run builds. The preview
/// calls core's own `trace_organic_lattice`, so its curves ARE the run's curves; the
/// registration he is describing is the tracer's, measured at 73–98 % of struts sitting
/// within a quarter-cell of a strut in the layer behind, and getting WORSE on a finer
/// grid (`OrganicRegionFillProbe.testHowMuchTheLatticeVariesThroughTheWallsDepth`). So
/// this file DEFORMS core's output afterwards, to show what an interleaved weave would
/// look like before anyone changes the tracer. Everything that draws it says so, and it
/// is off unless asked for.
///
/// ★ THE DEFORMATION. Each span is binned by its depth along its region's normal, one
/// bin per cell, and each bin is shifted bodily in that region's plane. The shift is a
/// pair of incommensurate sines of the bin index — deterministic, no RNG, never
/// repeating — so consecutive layers land off each other rather than in a rigid brick
/// pattern. A strut's own direction is untouched: only where the layer sits moves.
public enum OrganicDepthStagger {

    /// The in-plane shift for depth layer `k`, in millimetres, at a given cell size.
    /// Amplitude is half a cell: enough that a window in one layer is covered by the
    /// next, never enough to walk a strut into its neighbour's track.
    public static func offset(layer: Int, cellMM: Double) -> SIMD2<Double> {
        // ★ A GOLDEN-ANGLE CIRCLE, NOT A LISSAJOUS (2026-09-08). The first cut took two
        // sines of the layer index, and two sines can land near each other: consecutive
        // layers sometimes barely moved, and the measured registration only fell from
        // 73 % to 67 %. On a circle at the golden angle every consecutive pair is
        // 137.5° apart, so the displacement between them is a fixed 0.93 of a cell —
        // always far more than the quarter-cell that counts as "the same track" — and
        // the sequence still never repeats.
        // ★★★ HALF A PITCH BETWEEN CONSECUTIVE LAYERS, NOT A WHOLE ONE (measured
        // 2026-09-08). At radius 0.5·cell the golden angle puts consecutive layers
        // 0.93 of a cell apart — and in a weave whose pitch IS about a cell, shifting
        // by nearly a whole pitch lands each strut where the NEXT strut used to be.
        // Registration barely moved (76 % → 69 %) because the layers re-registered on
        // their neighbours. The offset that puts a strut behind a window is HALF a
        // pitch: consecutive displacement on a golden-angle circle of radius `a` is
        // 2·a·sin(68.75°) = 1.86·a, so a = 0.27·cell gives 0.5·cell.
        let a = 0.27 * cellMM
        let t = 2.39996 * Double(layer)
        return SIMD2(a * cos(t), a * sin(t))
    }

    /// An orthonormal in-plane basis for a normal.
    static func basis(_ n: SIMD3<Double>) -> (SIMD3<Double>, SIMD3<Double>) {
        let u = simd_length(n) > 1e-9 ? n / simd_length(n) : SIMD3(0, 0, 1)
        let helper = abs(u.x) < 0.9 ? SIMD3<Double>(1, 0, 0) : SIMD3<Double>(0, 1, 0)
        let a = simd_normalize(simd_cross(u, helper))
        return (a, simd_cross(u, a))
    }

    /// Stagger a span list. `regions` supplies each span's plane and origin; a span
    /// whose midpoint is in no include region is returned untouched.
    /// - Parameter fallbackAxis: the "depth" direction to use when there is no declared
    ///   face to take one from — the sample cube is a bare block, and without this it
    ///   returned every span untouched, which is why the toggle did nothing on the cube
    ///   (his walk, 2026-09-08: "almost no difference in the sample cube").
    public static func apply(spans: [(a: SIMD3<Double>, b: SIMD3<Double>, r: Double)],
                             regions: [LatticeRegionSpec],
                             cellMM: Double,
                             fallbackAxis: SIMD3<Double>? = nil)
        -> [(a: SIMD3<Double>, b: SIMD3<Double>, r: Double)] {
        let includes = regions.filter { $0.role == .include && $0.isValid && $0.kind == .face }
        guard cellMM > 0 else { return spans }
        // ★★★ NO DECLARED FACE ⇒ ONE AXIS FOR THE WHOLE BLOCK. A bare block has no
        // outline to take a normal from, so the caller names the axis: the build
        // direction, which is the direction a printer stacks and the one a viewer reads
        // as "layers". Without this the guard below returned early and the sample cube
        // never changed, however the toggle was set.
        if includes.isEmpty {
            guard let ax = fallbackAxis, simd_length(ax) > 1e-9 else { return spans }
            let n = ax / simd_length(ax)
            let (u, v) = basis(n)
            var origin = SIMD3<Double>(repeating: 0)
            if let first = spans.first { origin = 0.5 * (first.a + first.b) }
            return spans.map { s in
                let mid = 0.5 * (s.a + s.b)
                let layer = Int((simd_dot(mid - origin, n) / cellMM).rounded(.down))
                let d = offset(layer: layer, cellMM: cellMM)
                let shift = u * d.x + v * d.y
                return (a: s.a + shift, b: s.b + shift, r: s.r)
            }
        }
        // One basis per region, computed once.
        let frames = includes.map { r -> (n: SIMD3<Double>, u: SIMD3<Double>, v: SIMD3<Double>,
                                          o: SIMD3<Double>) in
            let (u, v) = basis(r.normal)
            let n = simd_length(r.normal) > 1e-9 ? r.normal / simd_length(r.normal) : SIMD3(0, 0, 1)
            return (n, u, v, r.origin)
        }
        return spans.map { s in
            let mid = 0.5 * (s.a + s.b)
            guard let k = includes.firstIndex(where: { LatticeRegionMask.contains(mid, region: $0) })
            else { return s }
            let f = frames[k]
            let depth = simd_dot(mid - f.o, f.n)
            let layer = Int((depth / cellMM).rounded(.down))
            let d = offset(layer: layer, cellMM: cellMM)
            let shift = f.u * d.x + f.v * d.y
            return (a: s.a + shift, b: s.b + shift, r: s.r)
        }
    }
}
