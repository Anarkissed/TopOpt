import Foundation
import simd

// ★★★ THE TRACER'S GRID IS NOT THE SOLVE'S (his 2026-09-21 19:38, "100% density of the full
// depth … still not working"). The stage solve runs at the COARSE tier — 3.41 mm voxels on
// his stand — and the tracer was handed that grid verbatim. Core floors every spacing at
// one voxel ("the tracer integrates a field sampled at the voxel grid, so it cannot
// resolve a separation finer than the grid"), so on that grid no curve could ever be laid
// closer than 3.41 mm to another or to the rim, the 12 mm wall was 3.5 voxels deep, and the
// band grade "toward the floor" graded toward 3.41. Measured: every candidate voxel was
// occupied (100 %) and the picture was still sparse, because the voxels were the size of
// the gap. The run traces at its own resolution (the Fine chip's 128³, 1.71 mm here), so
// the preview was also not the run's picture.
//
// So the tensor is resampled onto the preview's own grid before the trace: trilinear in
// each of the six components, voxel centres at (i + ½)·h on both grids, edges clamped. It
// adds no information the solve did not have — it lets the tracer USE the information at
// the spacing the print will actually get.
public enum OrganicTraceGrid {

    public struct Resampled: Sendable {
        public let tensor: [Double]
        public let dims: (Int, Int, Int)
        public let originMM: SIMD3<Double>
        public let spacingMM: Double
        /// voxels per coarse voxel along each axis (2 ⇒ ×8 voxels)
        public let factor: Int
    }

    /// The tensor on a grid `factor` times finer, where `factor = round(spacing / target)`;
    /// nil when the field is already at or finer than the target (factor < 2), when the
    /// tensor does not match `dims`, or when the fine grid would exceed `maxVoxels` even
    /// at ×2 — the factor is lowered before giving up.
    public static func resample(tensor: [Double], dims: (Int, Int, Int), originMM: SIMD3<Double>,
                                spacingMM: Double, toVoxelMM target: Double,
                                maxVoxels: Int = 4_000_000) -> Resampled? {
        let (nx, ny, nz) = dims
        guard nx > 0, ny > 0, nz > 0, spacingMM > 0, target > 0,
              tensor.count == 6 * nx * ny * nz else { return nil }
        var factor = Int((spacingMM / target).rounded())
        while factor >= 2, nx * ny * nz * factor * factor * factor > maxVoxels { factor -= 1 }
        guard factor >= 2 else { return nil }
        let fx = nx * factor, fy = ny * factor, fz = nz * factor
        let h = spacingMM / Double(factor)
        var out = [Double](repeating: 0, count: 6 * fx * fy * fz)
        // per axis: the coarse index below and the blend, at the fine voxel's centre
        func axis(_ n: Int, _ fn: Int) -> ([Int], [Double]) {
            var lo = [Int](repeating: 0, count: fn), t = [Double](repeating: 0, count: fn)
            for i in 0..<fn {
                let g = (Double(i) + 0.5) / Double(factor) - 0.5     // coarse continuous index
                let c = Swift.min(Double(n - 1), Swift.max(0, g))
                let l = Swift.min(n - 1, Int(c.rounded(.down)))
                lo[i] = l; t[i] = l + 1 < n ? c - Double(l) : 0
            }
            return (lo, t)
        }
        let (ix, tx) = axis(nx, fx), (iy, ty) = axis(ny, fy), (iz, tz) = axis(nz, fz)
        tensor.withUnsafeBufferPointer { src in
            out.withUnsafeMutableBufferPointer { dst in
                for k in 0..<fz {
                    let k0 = iz[k], k1 = Swift.min(nz - 1, k0 + 1), wz = tz[k]
                    for j in 0..<fy {
                        let j0 = iy[j], j1 = Swift.min(ny - 1, j0 + 1), wy = ty[j]
                        for i in 0..<fx {
                            let i0 = ix[i], i1 = Swift.min(nx - 1, i0 + 1), wx = tx[i]
                            let c000 = 6 * ((k0 * ny + j0) * nx + i0), c100 = 6 * ((k0 * ny + j0) * nx + i1)
                            let c010 = 6 * ((k0 * ny + j1) * nx + i0), c110 = 6 * ((k0 * ny + j1) * nx + i1)
                            let c001 = 6 * ((k1 * ny + j0) * nx + i0), c101 = 6 * ((k1 * ny + j0) * nx + i1)
                            let c011 = 6 * ((k1 * ny + j1) * nx + i0), c111 = 6 * ((k1 * ny + j1) * nx + i1)
                            let o = 6 * ((k * fy + j) * fx + i)
                            for c in 0..<6 {
                                let x00 = src[c000 + c] + (src[c100 + c] - src[c000 + c]) * wx
                                let x10 = src[c010 + c] + (src[c110 + c] - src[c010 + c]) * wx
                                let x01 = src[c001 + c] + (src[c101 + c] - src[c001 + c]) * wx
                                let x11 = src[c011 + c] + (src[c111 + c] - src[c011 + c]) * wx
                                let y0 = x00 + (x10 - x00) * wy, y1 = x01 + (x11 - x01) * wy
                                dst[o + c] = y0 + (y1 - y0) * wz
                            }
                        }
                    }
                }
            }
        }
        return Resampled(tensor: out, dims: (fx, fy, fz), originMM: originMM, spacingMM: h, factor: factor)
    }
}
