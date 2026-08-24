import Foundation
import simd

/// ★★★ HOW FAR EACH LATTICED VOXEL IS FROM THE EDGE OF ITS OWN REGION.
///
/// His rule for grade-to-fit-shape (2026-08-22): *"Distance to the boundary, getting
/// smaller as it gets closer to the boundary to be able to create the shape of the
/// lattice that perfectly fits the face/prism."*
///
/// ★ THE BOUNDARY IS THE **CANDIDATE SET'S**, NOT THE PART'S. What he is shaping is the
/// declared region — a face prism — so the distance has to be measured to the edge of
/// the material that is actually being latticed. Measuring to the part's outer surface
/// instead would leave the cells coarse right up to the cut where a prism ends, which is
/// the edge he can see.
///
/// ★ IT IS AN EXACT EUCLIDEAN TRANSFORM, not a chamfer. Felzenszwalb & Huttenlocher's
/// separable lower-envelope method, run once per axis on the SQUARED distance, so the
/// answer does not depend on which way the sweep happened to run. A chamfer's error is a
/// few percent and anisotropic — it is largest on the diagonals, which on a face prism is
/// exactly where the chamfered edges are, so the one place the grading has to be right is
/// the one place a chamfer is worst.
///
/// Anisotropic spacing is carried through the per-axis pass, so a preview grid whose
/// voxels are not cubes still measures millimetres.
public enum LatticeBoundaryDistance {

    /// Distance in MILLIMETRES from each candidate voxel to the nearest non-candidate
    /// voxel (the region boundary). Non-candidate voxels return 0.
    ///
    /// The grid is treated as OPEN at its faces: a voxel against the edge of the grid is
    /// not thereby "at a boundary", because the grid's extent is a preview setting and
    /// not a property of his part. Anything else would shrink cells along an arbitrary
    /// box.
    /// ★★★ `skipAxis` MAKES IT THE **IN-PLANE** DISTANCE — distance to the face's own
    /// OUTLINE, with the thickness direction left out (his ruling, 2026-08-23: *"in-plane
    /// distance to the face outline. I mean the shape of the face not the thickness as
    /// that is already covered by the floor"*).
    ///
    /// ★ AND WITHOUT IT THE GRADING CANNOT EXIST ON A THIN WALL, which is measured, not
    /// argued. On his 11 mm wall the full 3-D distance runs p25 1.72 / p50 3.44 / max
    /// 5.16 mm — i.e. for nearly every voxel the nearest boundary is the wall's own FACE,
    /// half a thickness away, and it barely varies across the face at all. Graded by it,
    /// the real bake moved 28 cells out of 964 (2.9%) and read as no gradient whatsoever.
    /// Dropping the normal axis leaves the two directions that actually span the face —
    /// ~200 mm against 11 mm of thickness — so the gradient follows the prism's shape.
    ///
    /// Pass the index of the face-normal axis (0=x, 1=y, 2=z); nil measures in 3-D.
    public static func millimetres(candidate: [Bool],
                                   nx: Int, ny: Int, nz: Int,
                                   spacing: SIMD3<Float>,
                                   skipAxis: Int? = nil) -> [Double] {
        let n = nx * ny * nz
        guard candidate.count == n, n > 0 else { return [] }
        let sx = Double(spacing.x), sy = Double(spacing.y), sz = Double(spacing.z)
        guard sx > 0, sy > 0, sz > 0 else { return [] }

        // Seed: 0 inside the "empty" set, +inf inside the candidate set. The transform
        // then measures every candidate voxel's distance to the nearest empty one.
        let INF = Double.greatestFiniteMagnitude / 4
        var d2 = [Double](repeating: 0, count: n)
        var anyCandidate = false, anyEmpty = false
        for i in 0..<n {
            if candidate[i] { d2[i] = INF; anyCandidate = true } else { anyEmpty = true }
        }
        // All-solid or all-empty: no boundary exists, so there is nothing to grade to.
        // Returning zeros would read as "every voxel is ON the boundary" and collapse
        // every cell to the finest rung — the opposite of what no boundary means.
        guard anyCandidate, anyEmpty else { return [] }

        var f = [Double](); var dOut = [Double]()
        var v = [Int](); var z = [Double]()

        /// 1-D squared-distance transform of `f` (length m) with sample spacing `s`.
        func edt1d(_ m: Int, _ s: Double) {
            if v.count < m { v = [Int](repeating: 0, count: m) }
            if z.count < m + 1 { z = [Double](repeating: 0, count: m + 1) }
            if dOut.count < m { dOut = [Double](repeating: 0, count: m) }
            var k = 0
            v[0] = 0
            z[0] = -INF
            z[1] = INF
            var q = 1
            while q < m {
                // Intersection of the parabolas rooted at q and v[k], in INDEX units
                // scaled by s so the result is a true millimetre distance.
                var sIsect = 0.0
                while true {
                    let p = v[k]
                    let num = (f[q] + s * s * Double(q * q)) - (f[p] + s * s * Double(p * p))
                    // The parabolas are f[q] + (x - s·q)², so the intersection is in
                    // x (millimetres): denominator 2(s·q − s·p), NOT 2s²(q − p).
                    let den = 2 * s * Double(q - p)
                    sIsect = num / den
                    if sIsect <= z[k] {
                        if k == 0 { break }
                        k -= 1
                    } else { break }
                }
                k += 1
                v[k] = q
                z[k] = sIsect
                z[k + 1] = INF
                q += 1
            }
            k = 0
            for qq in 0..<m {
                let x = s * Double(qq)
                while z[k + 1] < x { k += 1 }
                let p = v[k]
                let dx = x - s * Double(p)
                dOut[qq] = dx * dx + f[p]
            }
        }

        func axis(_ m: Int, _ step: Int, _ s: Double, _ base: (Int) -> Int, _ lanes: Int) {
            if f.count < m { f = [Double](repeating: 0, count: m) }
            for lane in 0..<lanes {
                let b = base(lane)
                for t in 0..<m { f[t] = d2[b + t * step] }
                edt1d(m, s)
                for t in 0..<m { d2[b + t * step] = dOut[t] }
            }
        }

        // X — skipped when it is the face normal, which leaves the transform measuring
        // only the two in-plane directions.
        if skipAxis != 0 {
            axis(nx, 1, sx, { lane in
                let j = lane % ny, k = lane / ny
                return (k * ny + j) * nx
            }, ny * nz)
        }
        // Y
        if skipAxis != 1 {
            axis(ny, nx, sy, { lane in
                let i = lane % nx, k = lane / nx
                return (k * ny) * nx + i
            }, nx * nz)
        }
        // Z
        if skipAxis != 2 {
            axis(nz, nx * ny, sz, { lane in
                let i = lane % nx, j = lane / nx
                return j * nx + i
            }, nx * ny)
        }

        var out = [Double](repeating: 0, count: n)
        for i in 0..<n where candidate[i] {
            let v2 = d2[i]
            out[i] = v2 >= INF ? 0 : (v2 > 0 ? v2.squareRoot() : 0)
        }
        return out
    }

    /// ★★★ ONE IN-PLANE FIELD PER REGION, because each face has its OWN normal and
    /// therefore its own plane. Entry `r` is nil for a region that is not an axis-aligned
    /// include face — there is no plane to drop, so it gets no shape grading rather than
    /// a wrong one.
    public static func inPlanePerRegion(regions: [LatticeRegionSpec],
                                        candidate: [Bool],
                                        nx: Int, ny: Int, nz: Int,
                                        spacing: SIMD3<Float>) -> [[Double]?] {
        var out = [[Double]?](repeating: nil, count: regions.count)
        // At most three distinct answers, so the transform runs once per AXIS rather
        // than once per region — two faces sharing a normal share the field.
        var byAxis = [Int: [Double]]()
        for (i, r) in regions.enumerated() where r.role == .include {
            let n = simd_normalize(r.normal)
            guard simd_length(n) > 0.5 else { continue }
            let a = abs(n)
            let axis = a.x >= a.y && a.x >= a.z ? 0 : (a.y >= a.z ? 1 : 2)
            guard a[axis] > 0.99 else { continue }
            if let cached = byAxis[axis] { out[i] = cached; continue }
            let f = millimetres(candidate: candidate, nx: nx, ny: ny, nz: nz,
                                spacing: spacing, skipAxis: axis)
            byAxis[axis] = f
            out[i] = f
        }
        return out
    }

    /// ★★★ THE GRADING DISTANCE PER VOXEL, REGION-AWARE — the doubled ladder's
    /// answer to the same defect the stepped path already fixed (2026-08-24).
    ///
    /// ★ THE 3-D DISTANCE REACHES 0 AT THE DEPTH CAPS as much as at the face's
    /// outline — a face region is an extrusion, so "distance to the edge of the
    /// latticed material" is ~half the wall thickness through the WHOLE wall. At the
    /// fine cells the ladder used to draw, that ceiling barely bound (measured: it
    /// moved 2.9% of cells); at the one-cell-per-wall sizes single-cell now produces
    /// (12–13 mm), S ≤ 2d binds mid-wall and cuts the very cells the mode exists to
    /// keep. The IN-PLANE field (thickness axis dropped) is the fit question the
    /// shape actually asks.
    ///
    /// Per voxel: the OWNING include region's in-plane distance, by the same
    /// first-match rule the emission uses; the 3-D distance where no axis-aligned
    /// face region owns the voxel (a bolt region, a whole-part lattice) — the
    /// behaviour those cases have always had.
    public static func perVoxelForGrading(regions: [LatticeRegionSpec],
                                          candidate: [Bool],
                                          nx: Int, ny: Int, nz: Int,
                                          spacing: SIMD3<Float>,
                                          origin: SIMD3<Float>) -> [Double] {
        let volume = millimetres(candidate: candidate, nx: nx, ny: ny, nz: nz,
                                 spacing: spacing)
        guard !volume.isEmpty, !regions.isEmpty else { return volume }
        let perRegion = inPlanePerRegion(regions: regions, candidate: candidate,
                                         nx: nx, ny: ny, nz: nz, spacing: spacing)
        guard perRegion.contains(where: { $0 != nil }) else { return volume }
        var out = volume
        var i = 0
        for k in 0..<nz {
            for j in 0..<ny {
                for x in 0..<nx {
                    defer { i += 1 }
                    guard i < candidate.count, candidate[i] else { continue }
                    let p = SIMD3<Double>(
                        Double(origin.x) + Double(x) * Double(spacing.x),
                        Double(origin.y) + Double(j) * Double(spacing.y),
                        Double(origin.z) + Double(k) * Double(spacing.z))
                    for (r, region) in regions.enumerated()
                    where region.role == .include
                        && LatticeRegionMask.contains(p, region: region) {
                        if let f = perRegion[r], i < f.count { out[i] = f[i] }
                        break
                    }
                }
            }
        }
        return out
    }

    /// ★★★ THE CELL A VOXEL THAT CLOSE TO THE EDGE MAY HOLD.
    ///
    /// A cube of side S centred `d` from the boundary stays inside the material when
    /// `S ≤ 2d`. That is the whole law: it is a statement about FIT, which is what he
    /// asked for ("perfectly fits the face/prism"), and it needs no tuning constant
    /// because the geometry supplies the 2.
    ///
    /// ★ IT IS A CEILING, NEVER A FLOOR. It can only make a cell FINER than the one the
    /// member already asked for; a voxel deep inside a thick wall is unaffected, so on a
    /// part with no thin edges this is inert. A rule that could also COARSEN would
    /// overrule `width / N*`, and the cells-per-member floor is not the boundary's to
    /// relax ([[cells-per-member-floor-is-region-and-cell]]).
    public static func cellCeilingMM(distanceMM d: Double) -> Double {
        d > 0 ? 2 * d : 0
    }

    /// Apply the ceiling to a per-voxel `desired_cell_mm` in place.
    ///
    /// `wants` that are already 0 stay 0 — that is core's "not fitted, leave it solid"
    /// marker and the boundary has no standing to overturn it. Where `wants` is EMPTY the
    /// caller is on a mode that never derived one (plain swept, fixed), and it is filled
    /// from the boundary alone and clamped to that mode's own window, so grade-to-fit
    /// reaches every grade option rather than only the two that already fit.
    public static func applyCeiling(to wants: inout [Double],
                                    distanceMM d: [Double],
                                    candidate: [Bool],
                                    fallbackWindow: ClosedRange<Double>? = nil) {
        guard !d.isEmpty else { return }
        if wants.isEmpty {
            guard let w = fallbackWindow, w.upperBound > 0 else { return }
            wants = [Double](repeating: 0, count: d.count)
            for i in 0..<d.count where i < candidate.count && candidate[i] {
                let ceil = cellCeilingMM(distanceMM: d[i])
                // Below the window's own floor there is no rung to give, so ask for
                // nothing and let the voxel stay solid.
                wants[i] = ceil >= w.lowerBound ? Swift.min(ceil, w.upperBound) : 0
            }
            return
        }
        guard wants.count == d.count else { return }
        for i in 0..<wants.count where wants[i] > 0 {
            let ceil = cellCeilingMM(distanceMM: d[i])
            if ceil > 0, ceil < wants[i] { wants[i] = ceil }
        }
    }
}
