// OrganicShapeFit.swift — the preview's mirror of core's organic SHAPE FIT
// (maintainer, 2026-09-03: "neither has Fit to shape turned on, otherwise they would
// look like a cube").
//
// ★ A MIRROR, NAMED AS ONE. Core applies shape fit to the organic separation field
// inline in the CLI (`core/src/cli/run_job.cpp` ~4160–4290, `if (jg.organic_shape_fit)`),
// not in a function the bridge could call, and this PR makes no core change. So the
// rule is reproduced here, pinned by `OrganicShapeFitTests` against hand-computed
// numbers, and flagged in the handoff: the honest end state is ONE core function
// shared by run_job and the preview bridge. Until then, any change to core's rule must
// be mirrored here or the sample will lie about what the run builds.
//
// The rule (run_job.cpp):
//   1. dist[e] = chamfer distance, in voxels, from every candidate voxel to the
//      boundary — a non-candidate neighbour, or a grid face ("the wall it sits in ends
//      here"): two passes (forward, backward) over the 6-neighbourhood.
//   2. SHAPE-FIT-ONLY (`organic_shape_fit_only`, with a window): the stress map is NOT
//      read; spacing = cell_min + (cell_max − cell_min) · dist / dmax — small at the
//      faces, large at the core.
//   3. Otherwise: cap = min(member_width / n★, 2 · dist · voxel); floor = cell_min;
//      spacing = min(spacing, max(cap, floor)). The member-width term needs the run's
//      per-voxel member width, which the preview does not have; here only the
//      boundary cap applies, and that is said.
import Foundation

public enum OrganicShapeFit {
    public struct Result: Equatable {
        public var spacing: [Double]
        public var shrunk: Int
        public var minRatio: Double
        public var depthVoxels: Int
    }

    /// Chamfer distance to the boundary, in voxels, over the candidate mask — exactly
    /// core's two passes. Non-candidates read 0; grid-face candidates read 1.
    public static func boundaryDistance(candidate: [Bool], nx: Int, ny: Int, nz: Int) -> [Int] {
        let big = Int(1) << 30
        var dist = [Int](repeating: big, count: nx * ny * nz)
        @inline(__always) func at(_ i: Int, _ j: Int, _ k: Int) -> Int { (k * ny + j) * nx + i }
        for k in 0..<nz { for j in 0..<ny { for i in 0..<nx {
            let e = at(i, j, k)
            if !candidate[e] { dist[e] = 0; continue }
            if i == 0 || j == 0 || k == 0 || i == nx - 1 || j == ny - 1 || k == nz - 1 { dist[e] = 1 }
        } } }
        for k in 0..<nz { for j in 0..<ny { for i in 0..<nx {
            let e = at(i, j, k)
            if i > 0 { dist[e] = min(dist[e], dist[at(i - 1, j, k)] + 1) }
            if j > 0 { dist[e] = min(dist[e], dist[at(i, j - 1, k)] + 1) }
            if k > 0 { dist[e] = min(dist[e], dist[at(i, j, k - 1)] + 1) }
        } } }
        for k in stride(from: nz - 1, through: 0, by: -1) {
            for j in stride(from: ny - 1, through: 0, by: -1) {
                for i in stride(from: nx - 1, through: 0, by: -1) {
                    let e = at(i, j, k)
                    if i + 1 < nx { dist[e] = min(dist[e], dist[at(i + 1, j, k)] + 1) }
                    if j + 1 < ny { dist[e] = min(dist[e], dist[at(i, j + 1, k)] + 1) }
                    if k + 1 < nz { dist[e] = min(dist[e], dist[at(i, j, k + 1)] + 1) }
                } } }
        return dist
    }

    /// Apply core's shape fit to a separation field. `spacing` is per voxel (mm),
    /// `candidate` the region mask, `voxelMM` the grid pitch, `window` the job's
    /// cell_min/cell_max (nil ⇒ no window: shape-fit-only cannot run, the cap floor is
    /// `kOrganicShapeFitMinCellRatio × spacing`).
    public static func apply(spacing: [Double], candidate: [Bool], nx: Int, ny: Int, nz: Int,
                             voxelMM: Double, window: (lo: Double, hi: Double)?,
                             only: Bool, minCellRatio: Double = 0.5) -> Result {
        var out = spacing
        let dist = boundaryDistance(candidate: candidate, nx: nx, ny: ny, nz: nz)
        let big = Int(1) << 30
        var shrunk = 0, worst = 1.0
        var dmax = 0
        for e in 0..<candidate.count where candidate[e] && dist[e] < big { dmax = max(dmax, dist[e]) }
        if only, let w = window, dmax > 0 {
            for e in 0..<candidate.count where candidate[e] {
                let t = min(1.0, Double(dist[e]) / Double(dmax))
                let before = out[e]
                out[e] = w.lo + (w.hi - w.lo) * t
                if out[e] < before { shrunk += 1; worst = min(worst, out[e] / before) }
            }
        } else {
            for e in 0..<candidate.count where candidate[e] {
                let capBoundary = 2.0 * Double(dist[e]) * voxelMM
                var cap = capBoundary
                let floorMM = window.map { $0.lo } ?? (minCellRatio * out[e])
                if cap < floorMM { cap = floorMM }
                guard cap > 0, cap < out[e] else { continue }
                let before = out[e]
                out[e] = cap
                shrunk += 1; worst = min(worst, cap / before)
            }
        }
        return Result(spacing: out, shrunk: shrunk, minRatio: shrunk > 0 ? worst : 1.0, depthVoxels: dmax)
    }
}
