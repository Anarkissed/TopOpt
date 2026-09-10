import Foundation
import simd

/// ★★★ GRADE TO SOLID, AS CORE BUILDS IT (his instruction, 2026-09-07: "There is still
/// a gap between the rim and the lattice … And the solid is never created").
///
/// ★ WHAT CORE ACTUALLY DOES, AND WHAT IT DOES NOT. `grade_lattice` is where an octet
/// voxel goes solid — a member too thin to hold `cells_per_member_floor` cells stays
/// solid. That law is explicitly SKIPPED for organic (grading.cpp: "ORGANIC: the
/// cells-per-member and percolation floors are OCTET invariants; organic keeps its own
/// … and audits them in run_organic_step"), and organic's own spacing floors RAISE the
/// separation rather than turning anything solid. So for a traced lattice there is
/// exactly one grade-to-solid in the whole run, and it is `apply_organic_solid_rim`:
/// a band, `rim` millimetres wide, of candidate voxels that touch solid material
/// SIDEWAYS, turned back into solid.
///
/// This is that function, mirrored on the preview's own grid — the BFS, the step count
/// and the normal test, arithmetic for arithmetic. Inventing a smoother rule here would
/// draw a part the run does not build, which is the whole failure this file exists to
/// avoid.
///
/// ★ AND THE TAPER HE ASKED FOR IS NOT THIS. "More of a grade between them" is the
/// SEPARATION shrinking as the wall's edge approaches, which is shape fit's boundary
/// term (`OrganicShapeFit`), not the rim. The rim is the last step: lattice, graded
/// finer and finer, then solid.
public enum OrganicSolidRim {

    /// ★★★ THE SAMPLE CUBE HAS NO DECLARED FACE, SO IT HAS NO OUTLINE — and his rule
    /// for it is different (2026-09-07): "In the sample cube, cover the edges of the
    /// cube. On the preview cover the OUTLINE of the face-prism SHAPE. NEVER OBSTRUCT
    /// THE VIEW OF THE LATTICE!"
    ///
    /// A face region's outline is a curve, and a band around it is a frame. A block's
    /// equivalent is its EDGES — where two of its faces meet — not its faces, which
    /// would wall the lattice in. So a voxel seeds the band only when it is open on two
    /// DIFFERENT axes; a voxel in the middle of a face is open on one and is left alone.
    /// Twelve solid bars, and every face still sees through.
    public static func edgeVoxels(candidate: [Bool], nx: Int, ny: Int, nz: Int,
                                  voxelMM: Double, rimMM: Double) -> [Int] {
        let n = nx * ny * nz
        guard rimMM > 0, voxelMM > 0, candidate.count == n else { return [] }
        let di = [1, -1, 0, 0, 0, 0], dj = [0, 0, 1, -1, 0, 0], dk = [0, 0, 0, 0, 1, -1]
        var dist = [Int](repeating: -1, count: n)
        var q: [Int] = []
        @inline(__always) func at(_ i: Int, _ j: Int, _ k: Int) -> Int { (k * ny + j) * nx + i }
        for k in 0..<nz { for j in 0..<ny { for i in 0..<nx {
            let e = at(i, j, k)
            guard candidate[e] else { continue }
            var openAxes = 0
            for axis in 0..<3 {
                var open = false
                for d in (2 * axis)..<(2 * axis + 2) {
                    let i2 = i + di[d], j2 = j + dj[d], k2 = k + dk[d]
                    if i2 < 0 || j2 < 0 || k2 < 0 || i2 >= nx || j2 >= ny || k2 >= nz { open = true; continue }
                    if !candidate[at(i2, j2, k2)] { open = true }
                }
                if open { openAxes += 1 }
            }
            if openAxes >= 2 { dist[e] = 0; q.append(e) }
        } } }
        let maxSteps = Int((rimMM / voxelMM + 1e-9).rounded(.down))
        var head = 0
        while head < q.count {
            let e = q[head]; head += 1
            if dist[e] >= maxSteps { continue }
            let i = e % nx, j = (e / nx) % ny, k = e / (nx * ny)
            for d in 0..<6 {
                let i2 = i + di[d], j2 = j + dj[d], k2 = k + dk[d]
                guard i2 >= 0, j2 >= 0, k2 >= 0, i2 < nx, j2 < ny, k2 < nz else { continue }
                let e2 = at(i2, j2, k2)
                guard candidate[e2], dist[e2] < 0 else { continue }
                dist[e2] = dist[e] + 1; q.append(e2)
            }
        }
        return q
    }

    /// The voxels the run turns back into solid. Indices into a `nx·ny·nz` grid.
    /// - Parameters:
    ///   - candidate: the lattice mask (core's `mask`).
    ///   - solid: is there printed material at this voxel? (core's `density > iso`).
    ///   - regionID: 1-based include-region id per voxel, 0 = none.
    ///   - normals: one outward normal per include region, in declaration order.
    ///   - rimMM: `organic_solid_rim_mm`, or the job's `cell_min_mm` when it is −1.
    public static func voxels(candidate: [Bool], solid: [Bool], regionID: [Int32],
                              normals: [SIMD3<Double>], nx: Int, ny: Int, nz: Int,
                              voxelMM: Double, rimMM: Double) -> [Int] {
        let n = nx * ny * nz
        guard rimMM > 0, voxelMM > 0, candidate.count == n, solid.count == n,
              regionID.count == n, !normals.isEmpty else { return [] }
        let di = [1, -1, 0, 0, 0, 0], dj = [0, 0, 1, -1, 0, 0], dk = [0, 0, 0, 0, 1, -1]
        var dist = [Int](repeating: -1, count: n)
        var q: [Int] = []
        @inline(__always) func at(_ i: Int, _ j: Int, _ k: Int) -> Int { (k * ny + j) * nx + i }
        for k in 0..<nz { for j in 0..<ny { for i in 0..<nx {
            let e = at(i, j, k)
            guard candidate[e] else { continue }
            let rid = Int(regionID[e])
            guard rid > 0, rid <= normals.count else { continue }
            let nrm = normals[rid - 1]
            let nl = simd_length(nrm)
            for d in 0..<6 {
                let i2 = i + di[d], j2 = j + dj[d], k2 = k + dk[d]
                guard i2 >= 0, j2 >= 0, k2 >= 0, i2 < nx, j2 < ny, k2 < nz else { continue }
                let e2 = at(i2, j2, k2)
                // ★★★ THE OUTLINE IS THE OUTLINE, SOLID BEHIND IT OR NOT (his
                // correction, 2026-09-08: "Image 2 is the *bottom* of the lattice - and
                // thus is an OUTLINE and abso-fucking-lutely should get a rim! It's the
                // front and back faces that do not touch anything that shouldn't get a
                // rim").
                //
                // ★ THIS REFUSED A SEED WHOSE NEIGHBOUR WAS AIR, mirroring core's
                // `apply_organic_solid_rim`, which only turns a cell solid where there
                // is already solid beside it. On a face prism cut into a wall that is
                // right for the sides — and WRONG for the bottom, where the region runs
                // out at the part's own surface and the neighbour is air. That edge is
                // as much the outline as the sides are, the lattice ends there, and it
                // is exactly where he expects a wall. The only direction that is still
                // exempt is the NORMAL: the prism's front and back faces are open by
                // design and walling them would hide the lattice.
                if candidate[e2] { continue }
                // ★ ALONG THE NORMAL IS THE FLOOR OR THE OPEN FACE, NEVER A SIDE.
                let dot = nl > 0
                    ? (Double(di[d]) * nrm.x + Double(dj[d]) * nrm.y + Double(dk[d]) * nrm.z) / nl
                    : 0
                if abs(dot) >= 0.5 { continue }
                dist[e] = 0; q.append(e); break
            }
        } } }
        let maxSteps = Int((rimMM / voxelMM + 1e-9).rounded(.down))
        var head = 0
        while head < q.count {
            let e = q[head]; head += 1
            if dist[e] >= maxSteps { continue }
            let i = e % nx, j = (e / nx) % ny, k = e / (nx * ny)
            for d in 0..<6 {
                let i2 = i + di[d], j2 = j + dj[d], k2 = k + dk[d]
                guard i2 >= 0, j2 >= 0, k2 >= 0, i2 < nx, j2 < ny, k2 < nz else { continue }
                let e2 = at(i2, j2, k2)
                guard candidate[e2], dist[e2] < 0 else { continue }
                dist[e2] = dist[e] + 1; q.append(e2)
            }
        }
        return q
    }
}
