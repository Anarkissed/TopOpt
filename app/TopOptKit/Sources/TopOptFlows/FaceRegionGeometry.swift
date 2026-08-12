// FaceRegionGeometry.swift — the geometry a region needs, over the viewer mesh
// (task 2026-08-14-face-regions §2, §4).
//
// ★ THE SAME TESSELLATION THE RUN USES. `ViewerMesh` comes from the same import
// the run re-reads (`import_part_file_resolved`), so a face's area, its
// neighbours, and a region's principal axis computed here are the numbers core
// computes in src/io/face_region.cpp. The parity is asserted, not asserted-by-
// hope: `FaceRegionParityTests` runs both sides over the same fixture.
//
// Everything here is pure simd over value types — no SwiftUI, no GPU, no bridge
// — so it is unit-tested headlessly (the M7 /app/ verification standard).

import Foundation
import simd
import TopOptKit

public enum FaceRegionGeometry {

    // MARK: - measures

    /// Per-face area (mm²), keyed by face id. A face with no triangles is absent.
    public static func faceAreas(in mesh: ViewerMesh) -> [FaceID: Double] {
        var out: [FaceID: Double] = [:]
        let idx = mesh.indices
        var t = 0
        var i = 0
        while i + 2 < idx.count {
            guard t < mesh.faceIDs.count else { break }
            let p0 = position(idx[i], mesh), p1 = position(idx[i + 1], mesh)
            let p2 = position(idx[i + 2], mesh)
            let a = Double(simd_length(simd_cross(p1 - p0, p2 - p0))) * 0.5
            out[mesh.faceIDs[t], default: 0] += a
            i += 3
            t += 1
        }
        return out
    }

    /// Face-level edge adjacency, reusing `FaceTopology.adjacency` — the same
    /// walk the hole face-loop has used since M7.5. One definition of "touching",
    /// not two.
    public static func adjacency(in mesh: ViewerMesh) -> [FaceID: Set<FaceID>] {
        FaceTopology.adjacency(in: mesh)
    }

    // MARK: - §2(d) EXPAND TO NEIGHBOURS — the cheapest win in the whole task

    /// Default angle (degrees) within which two faces count as CONTINUOUS: their
    /// representative normals agree. 1° is tight enough that a chamfer is not
    /// swallowed into the wall it bevels, and loose enough to survive
    /// tessellation noise on a nominally flat face.
    public static let coplanarToleranceDeg: Float = 1

    /// ★ TAP ONE FACE, GRAB ALL CONNECTED COPLANAR NEIGHBOURS. This is what turns
    /// his 23-tap load group into one tap, and it ships even if nothing else does
    /// (§2d).
    ///
    /// The walk is breadth-first over edge adjacency, admitting a neighbour only
    /// when its representative normal is within `toleranceDeg` of the SEED's — of
    /// the seed's, not of the neighbour it came from, so a gently curving run of
    /// faces cannot creep all the way around the part one degree at a time. That
    /// creep is the over-selection failure of handoff 2026-07-25-tap-overselect,
    /// and it is designed out here rather than tuned around.
    public static func expandCoplanar(from seed: FaceID, in mesh: ViewerMesh,
                                      toleranceDeg: Float = coplanarToleranceDeg)
        -> [FaceID] {
        guard let seedNormal = representativeNormal(seed, in: mesh) else { return [seed] }
        let cosTol = cos(toleranceDeg * .pi / 180)
        let adj = adjacency(in: mesh)
        var visited: Set<FaceID> = [seed]
        var stack: [FaceID] = [seed]
        while let f = stack.popLast() {
            for n in adj[f] ?? [] where !visited.contains(n) {
                guard let nn = representativeNormal(n, in: mesh) else { continue }
                if simd_dot(nn, seedNormal) >= cosTol {
                    visited.insert(n)
                    stack.append(n)
                }
            }
        }
        return visited.sorted()
    }

    /// ★ EXPAND TO THE CONNECTED RUN OF THE SAME SURFACE KIND — the second form
    /// of one-tap expansion, for a bore whose wall OCCT split into several
    /// cylinders, or a fillet chain. Admits a neighbour when it is the same
    /// `StepFaceGeometry.Kind` AND (for cylinders) shares the seed's axis.
    public static func expandSameKind(from seed: FaceID, in mesh: ViewerMesh)
        -> [FaceID] {
        guard let seedGeo = mesh.faceGeometry(seed) else { return [seed] }
        let adj = adjacency(in: mesh)
        var visited: Set<FaceID> = [seed]
        var stack: [FaceID] = [seed]
        while let f = stack.popLast() {
            for n in adj[f] ?? [] where !visited.contains(n) {
                guard let g = mesh.faceGeometry(n), g.kind == seedGeo.kind else { continue }
                if seedGeo.kind == .cylinder {
                    let a = simd_normalize(SIMD3<Float>(seedGeo.axisDir))
                    let b = simd_normalize(SIMD3<Float>(g.axisDir))
                    guard simd_length(a) > 0.5, simd_length(b) > 0.5,
                          abs(simd_dot(a, b)) >= cos(2 * .pi / 180) else { continue }
                }
                visited.insert(n)
                stack.append(n)
            }
        }
        return visited.sorted()
    }

    // MARK: - §2(a,b) the filter

    /// The faces `filter` matches, ascending. An all-unset filter matches
    /// NOTHING — it is not "match everything".
    public static func match(_ filter: RegionFilter, in mesh: ViewerMesh) -> [FaceID] {
        guard filter.any else { return [] }
        let areas = faceAreas(in: mesh)
        let adj = filter.minLargerNeighbours > 0 ? adjacency(in: mesh) : [:]
        var out: [FaceID] = []
        for (f, area) in areas {
            if filter.maxAreaMM2 > 0 && area > filter.maxAreaMM2 { continue }
            if filter.minAreaMM2 > 0 && area < filter.minAreaMM2 { continue }
            if !filter.kind.isEmpty {
                let k = mesh.faceGeometry(f)?.kind ?? .other
                let want: StepFaceGeometry.Kind? =
                    filter.kind == "plane" ? .plane
                    : filter.kind == "cylinder" ? .cylinder
                    : filter.kind == "other" ? .other : nil
                if let want, k != want { continue }
            }
            if filter.cylinderRadiusMM > 0 {
                guard let g = mesh.faceGeometry(f), g.kind == .cylinder,
                      abs(g.cylinderRadiusMM - filter.cylinderRadiusMM)
                        <= filter.cylinderRadiusTolMM else { continue }
            }
            if filter.minLargerNeighbours > 0 {
                guard area > 0 else { continue }
                let larger = (adj[f] ?? []).filter {
                    (areas[$0] ?? 0) >= filter.largerRatio * area
                }.count
                if larger < filter.minLargerNeighbours { continue }
            }
            out.append(f)
        }
        return out.sorted()
    }

    /// The member faces of a region on THIS mesh: filter matches, plus `add`,
    /// minus `remove`. The same arithmetic core does at resolve time.
    public static func members(of region: FaceRegion, in mesh: ViewerMesh) -> [FaceID] {
        var s = Set(match(region.filter, in: mesh))
        for f in region.add { s.insert(f) }
        for f in region.remove { s.remove(f) }
        return s.sorted()
    }

    // MARK: - §4(b) the region's own coordinates

    /// The frame a split is placed in — CYLINDRICAL when every member is a
    /// cylinder sharing one axis (a union of fillets around a bore), else the
    /// PCA of the members' vertices.
    ///
    /// ★ `cylindrical == false` on a mixed or irregular union is a fact the UI
    /// must SAY: "equal" is then equal in the PCA parameter, which is not equal
    /// in any intrinsic sense on a curved surface.
    public struct Frame: Equatable, Sendable {
        public var valid = false
        public var cylindrical = false
        public var axisPoint = SIMD3<Double>.zero
        public var axisDir = SIMD3<Double>(0, 0, 1)
        public var origin = SIMD3<Double>.zero
        public var u = SIMD3<Double>(1, 0, 0)
        public var v = SIMD3<Double>(0, 1, 0)
        public var axialLo = 0.0, axialHi = 0.0
        public var uLo = 0.0, uHi = 0.0, vLo = 0.0, vHi = 0.0
    }

    public static func frame(members: [FaceID], in mesh: ViewerMesh) -> Frame {
        var frame = Frame()
        let pts = memberVertices(members, in: mesh)
        guard pts.count >= 3 else { return frame }

        var allCyl = !members.isEmpty
        var axisDir = SIMD3<Double>.zero
        var axisPoint = SIMD3<Double>.zero
        let cosTol = cos(2 * Double.pi / 180)
        for f in members {
            guard let g = mesh.faceGeometry(f), g.kind == .cylinder,
                  simd_length(g.axisDir) > 0.5 else { allCyl = false; break }
            let d = simd_normalize(g.axisDir)
            if simd_length(axisDir) < 0.5 {
                axisDir = d
                axisPoint = g.axisPoint
            } else if abs(simd_dot(axisDir, d)) < cosTol {
                allCyl = false
                break
            }
        }

        let centroid = pts.reduce(SIMD3<Double>.zero, +) / Double(pts.count)
        if allCyl && simd_length(axisDir) > 0.5 {
            frame.valid = true
            frame.cylindrical = true
            frame.axisDir = axisDir
            frame.axisPoint = axisPoint + axisDir * simd_dot(centroid - axisPoint, axisDir)
            frame.origin = frame.axisPoint
            let (e1, e2) = perpBasis(axisDir)
            frame.u = e1
            frame.v = e2
            let s = pts.map { simd_dot($0 - frame.axisPoint, axisDir) }
            frame.axialLo = s.min() ?? 0
            frame.axialHi = s.max() ?? 0
            return frame
        }

        // PCA of the member vertices.
        var cov = simd_double3x3(0)
        for p in pts {
            let d = p - centroid
            cov += simd_double3x3(rows: [d * d.x, d * d.y, d * d.z])
        }
        let (axes, _) = symmetricEigen(cov)
        frame.valid = true
        frame.origin = centroid
        frame.u = axes.0
        frame.v = axes.1
        let su = pts.map { simd_dot($0 - centroid, frame.u) }
        let sv = pts.map { simd_dot($0 - centroid, frame.v) }
        frame.uLo = su.min() ?? 0
        frame.uHi = su.max() ?? 0
        frame.vLo = sv.min() ?? 0
        frame.vHi = sv.max() ?? 0
        return frame
    }

    /// §4(a) — the snap candidates the MANUAL split's ROTATE BUTTON cycles.
    /// Index 0 is the default: the plane whose normal is the long axis, i.e. the
    /// cut that goes ACROSS the region.
    ///
    /// ★ A BUTTON, NOT A DRAG. Rotating precisely with a finger on a small face
    /// while also having placed a point is fiddly, and he asked for a button.
    public static func snapNormals(_ frame: Frame) -> [SIMD3<Double>] {
        guard frame.valid else { return [] }
        let u = frame.cylindrical ? frame.axisDir : frame.u
        let v = frame.cylindrical ? frame.u : frame.v
        return [simd_normalize(u), simd_normalize(v),
                simd_normalize(u + v), simd_normalize(v - u)]
    }

    // MARK: - §4(b) Mode B — the grid

    public struct GridCell: Equatable, Sendable {
        public let i: Int
        public let j: Int
        public let cuts: [RegionCut]
    }

    /// Place an N x M grid split in the region's own coordinates.
    ///
    ///   CYLINDRICAL — `n` sectors about the axis (bounded by planes CONTAINING
    ///     the axis) and `m` slabs perpendicular to it. His worked example: "a
    ///     face arcing around a donut, 10 equal faces and 5 equal cuts
    ///     perpendicular to it".
    ///   PCA — `n` slabs perpendicular to u, `m` perpendicular to v.
    ///
    /// "Equal" means EQUAL IN PARAMETER (angle, or distance) — what he drew. The
    /// per-cell VOXEL counts are what `cellVoxelCounts` reports, so a sliver is
    /// visible before confirming, not after.
    public static func gridSplitCells(_ frame: Frame, n: Int, m: Int) -> [GridCell] {
        guard frame.valid, n >= 1, m >= 1 else { return [] }
        var cells: [GridCell] = []
        if frame.cylindrical {
            let twoPi = 2 * Double.pi
            for i in 0..<n {
                var ang: [RegionCut] = []
                if n >= 2 {
                    let a0 = twoPi * Double(i) / Double(n)
                    let a1 = twoPi * Double(i + 1) / Double(n)
                    ang.append(RegionCut(point: frame.axisPoint,
                                         normal: frame.u * -sin(a0) + frame.v * cos(a0)))
                    ang.append(RegionCut(point: frame.axisPoint,
                                         normal: -(frame.u * -sin(a1) + frame.v * cos(a1)),
                                         strict: true))
                }
                let span = frame.axialHi - frame.axialLo
                for j in 0..<m {
                    var cuts = ang
                    let s0 = frame.axialLo + span * Double(j) / Double(m)
                    let s1 = frame.axialLo + span * Double(j + 1) / Double(m)
                    if j > 0 {
                        cuts.append(RegionCut(point: frame.axisPoint + frame.axisDir * s0,
                                              normal: frame.axisDir))
                    }
                    if j < m - 1 {
                        cuts.append(RegionCut(point: frame.axisPoint + frame.axisDir * s1,
                                              normal: -frame.axisDir, strict: true))
                    }
                    cells.append(GridCell(i: i, j: j, cuts: cuts))
                }
            }
            return cells
        }
        let du = frame.uHi - frame.uLo
        let dv = frame.vHi - frame.vLo
        for i in 0..<n {
            for j in 0..<m {
                var cuts: [RegionCut] = []
                // The OUTER boundaries are omitted rather than placed at the
                // measured extent, so a vertex-derived extent sitting a hair
                // inside a voxel centre cannot drop that voxel out of every cell.
                if i > 0 {
                    cuts.append(RegionCut(
                        point: frame.origin + frame.u * (frame.uLo + du * Double(i) / Double(n)),
                        normal: frame.u))
                }
                if i < n - 1 {
                    cuts.append(RegionCut(
                        point: frame.origin + frame.u * (frame.uLo + du * Double(i + 1) / Double(n)),
                        normal: -frame.u, strict: true))
                }
                if j > 0 {
                    cuts.append(RegionCut(
                        point: frame.origin + frame.v * (frame.vLo + dv * Double(j) / Double(m)),
                        normal: frame.v))
                }
                if j < m - 1 {
                    cuts.append(RegionCut(
                        point: frame.origin + frame.v * (frame.vLo + dv * Double(j + 1) / Double(m)),
                        normal: -frame.v, strict: true))
                }
                cells.append(GridCell(i: i, j: j, cuts: cuts))
            }
        }
        return cells
    }

    // MARK: - §4(c) per-cell counts, without a voxel grid

    /// The AREA (mm²) of each cell of a split, and of the region as a whole.
    ///
    /// ★ WHY A SAMPLE AND NOT THE REAL GRID. The exact per-cell count needs the
    /// voxelised part, which the device only has mid-run; the preview has to be
    /// instant. So each member triangle is subdivided on a barycentric lattice
    /// FINE ENOUGH THAT ONE SAMPLE COVERS ABOUT ONE VOXEL of surface, and each
    /// sample's share of the triangle's area is credited to the one cell its
    /// centroid falls in.
    ///
    /// The sampling density is tied to `spacingMM` for a reason: a CAD wall is
    /// often TWO triangles, and a fixed handful of samples per triangle cannot
    /// represent a 2x2 split of it at all — it reports empty cells that are not
    /// empty and refuses a split that is fine. Tying the lattice to the voxel
    /// size makes the estimate converge to what the run will price.
    ///
    /// The run prices the real thing again and refuses on the same floor
    /// (loadcase.cpp), so this can be a voxel or two out at a cell boundary; it
    /// cannot let a bad split through.
    public static func cellAreas(members: [FaceID], in mesh: ViewerMesh,
                                 cells: [GridCell], spacingMM: Double)
        -> (perCell: [Double], total: Double, unassigned: Double) {
        var acc = Array(repeating: 0.0, count: cells.count)
        var total = 0.0
        var unassigned = 0.0
        let voxelArea = max(spacingMM * spacingMM, 1e-12)
        let member = Set(members)
        let idx = mesh.indices
        var t = 0
        var i = 0
        while i + 2 < idx.count {
            guard t < mesh.faceIDs.count else { break }
            if member.contains(mesh.faceIDs[t]) {
                let p0 = SIMD3<Double>(position(idx[i], mesh))
                let p1 = SIMD3<Double>(position(idx[i + 1], mesh))
                let p2 = SIMD3<Double>(position(idx[i + 2], mesh))
                let area = simd_length(simd_cross(p1 - p0, p2 - p0)) * 0.5
                total += area
                // k subdivisions per edge => k² sub-triangles, each ~one voxel.
                // Capped so a single enormous facet cannot cost unbounded time.
                let k = min(64, max(1, Int((area / voxelArea).squareRoot().rounded(.up))))
                let share = area / Double(k * k)
                for a in 0..<k {
                    for b in 0..<(k - a) {
                        // The upward sub-triangle's centroid…
                        emit(p0, p1, p2, (Double(a) + 1.0 / 3) / Double(k),
                             (Double(b) + 1.0 / 3) / Double(k), share, cells,
                             &acc, &unassigned)
                        // …and the downward one that shares its edge.
                        if a + b < k - 1 {
                            emit(p0, p1, p2, (Double(a) + 2.0 / 3) / Double(k),
                                 (Double(b) + 2.0 / 3) / Double(k), share, cells,
                                 &acc, &unassigned)
                        }
                    }
                }
            }
            i += 3
            t += 1
        }
        return (acc, total, unassigned)
    }

    private static func emit(_ p0: SIMD3<Double>, _ p1: SIMD3<Double>,
                             _ p2: SIMD3<Double>, _ u: Double, _ v: Double,
                             _ share: Double, _ cells: [GridCell],
                             _ acc: inout [Double], _ unassigned: inout Double) {
        let p = p0 + (p1 - p0) * u + (p2 - p0) * v
        for (ci, c) in cells.enumerated() where inside(p, c.cuts) {
            acc[ci] += share
            return
        }
        unassigned += share
    }

    /// The per-cell VOXEL counts a preview shows. Rounded from `cellAreas`, so
    /// the individual figures can differ from their sum by the rounding; the
    /// area figures are the exact ones.
    public static func cellVoxelCounts(members: [FaceID], in mesh: ViewerMesh,
                                       cells: [GridCell], spacingMM: Double) -> [Int] {
        guard spacingMM > 0 else { return Array(repeating: 0, count: cells.count) }
        let voxelArea = spacingMM * spacingMM
        return cellAreas(members: members, in: mesh, cells: cells,
                         spacingMM: spacingMM).perCell
            .map { Int(($0 / voxelArea).rounded()) }
    }

    /// The whole region's estimated voxel count at `spacingMM` (one-voxel depth).
    public static func memberVoxelEstimate(members: [FaceID], in mesh: ViewerMesh,
                                           spacingMM: Double) -> Int {
        guard spacingMM > 0 else { return 0 }
        let areas = faceAreas(in: mesh)
        let total = members.reduce(0.0) { $0 + (areas[$1] ?? 0) }
        return Int((total / (spacingMM * spacingMM)).rounded())
    }

    public static func inside(_ p: SIMD3<Double>, _ cuts: [RegionCut]) -> Bool {
        for c in cuts {
            let s = simd_dot(p - c.point, c.normal)
            if c.strict ? !(s > 0) : !(s >= 0) { return false }
        }
        return true
    }

    // MARK: - internals

    static func position(_ i: UInt32, _ mesh: ViewerMesh) -> SIMD3<Float> {
        let b = Int(i) * 3
        return SIMD3<Float>(mesh.positions[b], mesh.positions[b + 1], mesh.positions[b + 2])
    }

    /// A face's representative unit normal: its area-weighted average triangle
    /// normal. nil for a face with no usable triangle.
    static func representativeNormal(_ face: FaceID, in mesh: ViewerMesh) -> SIMD3<Float>? {
        let idx = mesh.indices
        var acc = SIMD3<Float>.zero
        for t in FaceTopology.triangles(ofFace: face, in: mesh) {
            let i = t * 3
            guard i + 2 < idx.count else { continue }
            let p0 = position(idx[i], mesh), p1 = position(idx[i + 1], mesh)
            let p2 = position(idx[i + 2], mesh)
            acc += simd_cross(p1 - p0, p2 - p0)   // magnitude IS twice the area
        }
        let l = simd_length(acc)
        return l > 1e-9 ? acc / l : nil
    }

    static func memberVertices(_ members: [FaceID], in mesh: ViewerMesh) -> [SIMD3<Double>] {
        let member = Set(members)
        let idx = mesh.indices
        var seen = Set<UInt32>()
        var out: [SIMD3<Double>] = []
        var t = 0
        var i = 0
        while i + 2 < idx.count {
            guard t < mesh.faceIDs.count else { break }
            if member.contains(mesh.faceIDs[t]) {
                for k in 0..<3 where seen.insert(idx[i + k]).inserted {
                    out.append(SIMD3<Double>(position(idx[i + k], mesh)))
                }
            }
            i += 3
            t += 1
        }
        return out
    }

    static func perpBasis(_ d: SIMD3<Double>) -> (SIMD3<Double>, SIMD3<Double>) {
        let seed = abs(d.x) < 0.9 ? SIMD3<Double>(1, 0, 0) : SIMD3<Double>(0, 1, 0)
        var e1 = seed - d * simd_dot(seed, d)
        e1 = simd_length(e1) > 1e-9 ? simd_normalize(e1) : SIMD3<Double>(1, 0, 0)
        return (e1, simd_normalize(simd_cross(d, e1)))
    }

    /// Cyclic-Jacobi eigen-decomposition of a symmetric 3x3, eigenvectors ordered
    /// by DESCENDING eigenvalue: `.0` is the principal (longest) axis.
    static func symmetricEigen(_ mIn: simd_double3x3)
        -> ((SIMD3<Double>, SIMD3<Double>, SIMD3<Double>), SIMD3<Double>) {
        var a = [[mIn[0][0], mIn[1][0], mIn[2][0]],
                 [mIn[0][1], mIn[1][1], mIn[2][1]],
                 [mIn[0][2], mIn[1][2], mIn[2][2]]]
        var v = [[1.0, 0, 0], [0, 1.0, 0], [0, 0, 1.0]]
        for _ in 0..<32 {
            var off = 0.0
            for i in 0..<3 { for j in (i + 1)..<3 { off += a[i][j] * a[i][j] } }
            if off < 1e-24 { break }
            for p in 0..<3 {
                for q in (p + 1)..<3 where abs(a[p][q]) > 1e-30 {
                    let theta = (a[q][q] - a[p][p]) / (2 * a[p][q])
                    let t = (theta >= 0 ? 1.0 : -1.0) / (abs(theta) + (theta * theta + 1).squareRoot())
                    let c = 1 / (t * t + 1).squareRoot()
                    let s = t * c
                    for k in 0..<3 {
                        let akp = a[k][p], akq = a[k][q]
                        a[k][p] = c * akp - s * akq
                        a[k][q] = s * akp + c * akq
                    }
                    for k in 0..<3 {
                        let apk = a[p][k], aqk = a[q][k]
                        a[p][k] = c * apk - s * aqk
                        a[q][k] = s * apk + c * aqk
                    }
                    for k in 0..<3 {
                        let vkp = v[k][p], vkq = v[k][q]
                        v[k][p] = c * vkp - s * vkq
                        v[k][q] = s * vkp + c * vkq
                    }
                }
            }
        }
        let vals = [a[0][0], a[1][1], a[2][2]]
        let order = [0, 1, 2].sorted { vals[$0] > vals[$1] }
        func col(_ k: Int) -> SIMD3<Double> {
            simd_normalize(SIMD3<Double>(v[0][k], v[1][k], v[2][k]))
        }
        return ((col(order[0]), col(order[1]), col(order[2])),
                SIMD3<Double>(vals[order[0]], vals[order[1]], vals[order[2]]))
    }
}
