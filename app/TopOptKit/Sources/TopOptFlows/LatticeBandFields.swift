import Foundation
import simd

/// ★★★ THE BAND, REBUILT (2026-09-26, his images 10–14: an indent at the leg's foot, rungs on
/// the inner arcs, "tumours popping up on the right side, and it's an indent on the left. It
/// needs to be a singular line"; "a consistent blue line only where it is meant to be and a
/// skin above those blue lines … the lattice cells graded as tight as possible prior to the
/// solid blue layer").
///
/// Every earlier version built the skin/rim/grade from voxel fields whose SIGN came from the
/// voxelised part while their MAGNITUDE came from a subset of triangles, with 1e3 sentinels,
/// clamps and a per-voxel clip that jumped to a far value — so every thin feature aliased,
/// differently at every height. This module builds each field as a CONTINUOUS distance with a
/// GEOMETRIC sign, so a trilinear read reproduces a constant-thickness offset at any grid phase:
///
///   classes     per CAD face: SELECTED, OPEN (passed through), ALONGSIDE, or NONE (no face id)
///   B_r         min over alongside triangles of max(D_t − c, φ_t)   (c = skin + rim; φ_t = the
///               triangle's clip planes at edges it shares with an open face) — < 0 in skin ∪ rim
///   Δ           ±distance to the alongside set, signed by the closest feature's pseudo-normal
///               over the alongside set's OWN adjacency (beyond a convex border into a selected
///               mouth the value stays +, so the skin face does not dive short of the mouth)
///   K_s         Δ − s·τ   (τ tapers the skin to 0 at footprint clips, so the rim meets the
///               flush lattice of an open face without a notch)
///   G           the grade distance past the rim's inner face, signed and continuous, gated off
///               past a clip and where the rim at its foot lies outside the pocket
///   q           the pocket (whole-prism union) — exact through the caps
///   dMat        the part's material distance, pseudo-normal signed
///   carved      max(q, −B_r): negative only in the pocket outside every band
///
/// The rim is drawn from a FINE, PADDED copy (half the preview voxel, air on every side).
public enum LatticeBandFields {

    public enum FaceClass: UInt8, Sendable { case selected, open, alongside, none }

    public struct Result {
        public var qC: LatticeVoxelGrid
        public var carvedC: LatticeVoxelGrid
        public var gradeC: LatticeVoxelGrid
        public var skinC: LatticeVoxelGrid
        public var rimC: LatticeVoxelGrid
        public var materialC: LatticeVoxelGrid
        public var latticedC: LatticeVoxelGrid
        public var fine: LatticeBandFine
        public var classByFace: [Int: FaceClass]
        public var diag: String
        public var counts: [String: Int]
    }

    public struct Params {
        public var skinMM: Double          // s
        public var rimMM: Double           // r
        public var sideRimMM: Double       // r_o, the solid-backed prism side's rim (0 = none)
        public var gradeBandMM: Double     // g
        public var finishSkinMM: Double    // the covered finish's skin (0 unless `covered`)
        public var options: LatticeBandOptions
        public init(skinMM: Double, rimMM: Double, sideRimMM: Double, gradeBandMM: Double,
                    finishSkinMM: Double, options: LatticeBandOptions) {
            self.skinMM = skinMM; self.rimMM = rimMM; self.sideRimMM = sideRimMM
            self.gradeBandMM = gradeBandMM; self.finishSkinMM = finishSkinMM; self.options = options
        }
    }

    // MARK: - geometry primitives

    /// Closest point on triangle abc to p, with the feature it lies on: 0 face, 1 edge ab,
    /// 2 edge bc, 3 edge ca, 4 vertex a, 5 vertex b, 6 vertex c (Ericson §5.1.5).
    @inline(__always)
    static func closest(_ p: SIMD3<Double>, _ a: SIMD3<Double>, _ b: SIMD3<Double>, _ c: SIMD3<Double>)
        -> (SIMD3<Double>, Int) {
        let ab = b - a, ac = c - a, ap = p - a
        let d1 = simd_dot(ab, ap), d2 = simd_dot(ac, ap)
        if d1 <= 0 && d2 <= 0 { return (a, 4) }
        let bp = p - b
        let d3 = simd_dot(ab, bp), d4 = simd_dot(ac, bp)
        if d3 >= 0 && d4 <= d3 { return (b, 5) }
        let vc = d1 * d4 - d3 * d2
        if vc <= 0 && d1 >= 0 && d3 <= 0 { let v = d1 / (d1 - d3); return (a + ab * v, 1) }
        let cp = p - c
        let d5 = simd_dot(ab, cp), d6 = simd_dot(ac, cp)
        if d6 >= 0 && d5 <= d6 { return (c, 6) }
        let vb = d5 * d2 - d1 * d6
        if vb <= 0 && d2 >= 0 && d6 <= 0 { let w = d2 / (d2 - d6); return (a + ac * w, 3) }
        let va = d3 * d6 - d5 * d4
        if va <= 0 && (d4 - d3) >= 0 && (d5 - d6) >= 0 {
            let w = (d4 - d3) / ((d4 - d3) + (d5 - d6)); return (b + (c - b) * w, 2)
        }
        let denom = 1 / (va + vb + vc)
        let v = vb * denom, w = vc * denom
        return (a + ab * v + ac * w, 0)
    }

    struct VKey: Hashable { let x: Int32, y: Int32, z: Int32 }
    @inline(__always) static func vkey(_ p: SIMD3<Double>) -> VKey {
        VKey(x: Int32((p.x * 1000).rounded()), y: Int32((p.y * 1000).rounded()), z: Int32((p.z * 1000).rounded()))
    }
    struct EKey: Hashable { let a: VKey, b: VKey }
    @inline(__always) static func ekey(_ p: SIMD3<Double>, _ q: SIMD3<Double>) -> EKey {
        let a = vkey(p), b = vkey(q)
        return (a.x, a.y, a.z) < (b.x, b.y, b.z) ? EKey(a: a, b: b) : EKey(a: b, b: a)
    }

    /// A clip half-space: kept where dot(n, p) + d ≤ 0.
    struct Plane { var n: SIMD3<Double>; var d: Double
        @inline(__always) func term(_ p: SIMD3<Double>) -> Double { simd_dot(n, p) + d }
    }

    /// One band source: a triangle of the alongside set (or a side tile), its planes, its
    /// half-width (c for alongside, r_o for side tiles), and, for alongside triangles, the sign
    /// vectors of its 7 features.
    struct Piece {
        var a: SIMD3<Double>, b: SIMD3<Double>, c: SIMD3<Double>
        var planes: [Plane]
        var width: Double
        var isAlongside: Bool
        var signVec: [SIMD3<Double>]      // 7: face, edges ab/bc/ca, vertices a/b/c
        var lo: SIMD3<Double>, hi: SIMD3<Double>
    }

    // MARK: - build

    public static func build(mesh: ViewerMesh, regions: [LatticeRegionSpec], selectedRaw: Set<Int>,
                             solid: LatticeVoxelGrid, params: Params) -> Result {
        let t0 = Date()
        let opt = params.options
        let s = params.skinMM, r = params.rimMM, c = s + r
        let rO = params.sideRimMM
        let g = params.gradeBandMM
        let h = Double(Swift.max(solid.spacing.x, Swift.max(solid.spacing.y, solid.spacing.z)))
        let K = Swift.max(4.0, g / (0.5 * h))
        let wT = c
        let reachC = c + Swift.max(g, 12) + 2 * h
        let qCap = 3 * h
        var counts: [String: Int] = [:]
        var timings: [String: Double] = [:]
        func lap(_ k: String, _ since: inout Date) { timings[k] = Date().timeIntervalSince(since) * 1000; since = Date() }
        var tl = Date()

        // ── triangles
        let P = mesh.positions, I = mesh.indices
        let triCount = I.count / 3
        func vtx(_ i: UInt32) -> SIMD3<Double> { let b = Int(i) * 3; return SIMD3(Double(P[b]), Double(P[b + 1]), Double(P[b + 2])) }
        var A = [SIMD3<Double>](repeating: .zero, count: triCount)
        var B = A, C = A, N = A
        var area = [Double](repeating: 0, count: triCount)
        var fid = [Int](repeating: -1, count: triCount)
        for t in 0..<triCount {
            let a = vtx(I[3 * t]), b = vtx(I[3 * t + 1]), cc = vtx(I[3 * t + 2])
            A[t] = a; B[t] = b; C[t] = cc
            let cr = simd_cross(b - a, cc - a)
            let l = simd_length(cr)
            area[t] = 0.5 * l
            N[t] = l > 1e-12 ? cr / l : .zero
            fid[t] = t < mesh.faceIDs.count ? Int(mesh.faceIDs[t]) : -1
        }

        // ── classes, per CAD face
        let includeFaces = regions.filter { $0.role == .include && $0.kind == .face && $0.isValid }
        let acrossCos = cos(30.0 * Double.pi / 180)
        func reached(_ t: Int, _ rg: LatticeRegionSpec) -> Bool {
            let p0 = A[t], p1 = B[t], p2 = C[t], nOut = N[t]
            let probes = [(p0 + p1 + p2) / 3, p0, p1, p2, 0.5 * (p0 + p1), 0.5 * (p1 + p2), 0.5 * (p2 + p0)].map { $0 - nOut * 1.5 }
            for pr in probes where LatticeRegionMask.containsWholePrism(pr, region: rg) { return true }
            let nr = LatticeRegionMask.unit(rg.normal)
            let (ru, rv) = LatticeRegionMask.basis(nr)
            var plan: [SIMD3<Double>] = [rg.origin]
            if rg.outlineLoops.isEmpty {
                for sx in [-1.0, 1.0] { for sy in [-1.0, 1.0] { plan.append(rg.origin + ru * (sx * rg.halfUMM) + rv * (sy * rg.halfWMM)) } }
            } else { for loop in rg.outlineLoops { for q in loop { plan.append(rg.origin + ru * q.x + rv * q.y) } } }
            for pt in plan {
                let q = pt - nOut * simd_dot(pt - p0, nOut)
                let v0 = p1 - p0, v1 = p2 - p0, v2 = q - p0
                let d00 = simd_dot(v0, v0), d01 = simd_dot(v0, v1), d11 = simd_dot(v1, v1)
                let d20 = simd_dot(v2, v0), d21 = simd_dot(v2, v1)
                let den = d00 * d11 - d01 * d01
                guard abs(den) > 1e-18 else { continue }
                let v = (d11 * d20 - d01 * d21) / den, w = (d00 * d21 - d01 * d20) / den
                guard v >= -1e-6, w >= -1e-6, v + w <= 1 + 1e-6 else { continue }
                if LatticeRegionMask.containsWholePrism(q - nOut * 1.5, region: rg) { return true }
            }
            return false
        }
        var faceArea: [Int: Double] = [:]
        var alignedArea: [Int: [Double]] = [:]      // per face, per include region
        var faceReached: [Int: [Bool]] = [:]
        var triAcross = [Bool](repeating: false, count: triCount)   // the old per-triangle rule
        for t in 0..<triCount where area[t] > 1e-12 {
            let f = fid[t]
            guard f >= 0, !selectedRaw.contains(f) || opt.includeSelected else { continue }
            faceArea[f, default: 0] += area[t]
            if alignedArea[f] == nil { alignedArea[f] = [Double](repeating: 0, count: includeFaces.count); faceReached[f] = [Bool](repeating: false, count: includeFaces.count) }
            for (ri, rg) in includeFaces.enumerated() where abs(simd_dot(N[t], LatticeRegionMask.unit(rg.normal))) > acrossCos {
                alignedArea[f]![ri] += area[t]
                if !faceReached[f]![ri] || opt.perTriangle {
                    if reached(t, rg) { faceReached[f]![ri] = true; triAcross[t] = true }
                }
            }
        }
        var classByFace: [Int: FaceClass] = [:]
        for (f, fa) in faceArea {
            var open = false
            for ri in 0..<includeFaces.count where alignedArea[f]![ri] >= 0.5 * fa && faceReached[f]![ri] { open = true }
            classByFace[f] = open ? .open : .alongside
        }
        var cls = [FaceClass](repeating: .none, count: triCount)
        for t in 0..<triCount {
            let f = fid[t]
            if f < 0 { cls[t] = .none; continue }
            if selectedRaw.contains(f) && !opt.includeSelected { cls[t] = .selected; continue }
            if opt.perTriangle { cls[t] = triAcross[t] ? .open : .alongside; continue }
            cls[t] = classByFace[f] ?? .alongside
        }
        lap("classify", &tl)

        // ── adjacency (µm position keys; the mesh is edge-matched across faces)
        var edgeTris: [EKey: [Int]] = [:]
        edgeTris.reserveCapacity(triCount * 2)
        for t in 0..<triCount where area[t] > 1e-12 {
            let vs = [A[t], B[t], C[t]]
            for k in 0..<3 { edgeTris[ekey(vs[k], vs[(k + 1) % 3]), default: []].append(t) }
        }
        func neighbour(_ t: Int, _ k: Int) -> Int? {
            let vs = [A[t], B[t], C[t]]
            return edgeTris[ekey(vs[k], vs[(k + 1) % 3])]?.first { $0 != t }
        }
        func centroid(_ t: Int) -> SIMD3<Double> { (A[t] + B[t] + C[t]) / 3 }
        func unitOr(_ v: SIMD3<Double>, _ fallback: SIMD3<Double>) -> SIMD3<Double> {
            let l = simd_length(v); return l > 1e-12 ? v / l : fallback
        }

        // full-mesh pseudo-normals (for dMat)
        var vNormalAll: [VKey: SIMD3<Double>] = [:]
        for t in 0..<triCount where area[t] > 1e-12 {
            let vs = [A[t], B[t], C[t]]
            for k in 0..<3 {
                let e1 = unitOr(vs[(k + 1) % 3] - vs[k], .zero), e2 = unitOr(vs[(k + 2) % 3] - vs[k], .zero)
                let ang = acos(Swift.max(-1, Swift.min(1, simd_dot(e1, e2))))
                vNormalAll[vkey(vs[k]), default: .zero] += N[t] * ang
            }
        }
        func pseudoAll(_ t: Int, _ feat: Int) -> SIMD3<Double> {
            switch feat {
            case 0: return N[t]
            case 1, 2, 3:
                if let o = neighbour(t, feat - 1) { return unitOr(N[t] + N[o], N[t]) }
                return N[t]
            default:
                let v = [A[t], B[t], C[t]][feat - 4]
                return unitOr(vNormalAll[vkey(v)] ?? N[t], N[t])
            }
        }

        // ── alongside pieces: planes, sign vectors, taper segments
        var pieces: [Piece] = []
        var tapers: [(SIMD3<Double>, SIMD3<Double>)] = []
        var vertexPlanes: [VKey: [Plane]] = [:]
        var borderSignAtVertex: [VKey: SIMD3<Double>] = [:]
        var interiorNormalAtVertex: [VKey: SIMD3<Double>] = [:]
        struct EdgeInfo { var sign: SIMD3<Double>; var plane: Plane?; var footprint: Bool; var border: Bool }
        var alongIdx: [Int] = []
        var edgeInfo: [[EdgeInfo]] = []
        var cFoot = 0, cNeigh = 0, cUnmatched = 0, cBorder = 0
        for t in 0..<triCount where area[t] > 1e-12 && cls[t] == .alongside {
            let vs = [A[t], B[t], C[t]]
            var infos: [EdgeInfo] = []
            for k in 0..<3 {
                let a = vs[k], b = vs[(k + 1) % 3]
                let e = unitOr(b - a, .zero)
                guard let o = neighbour(t, k) else {
                    cUnmatched += 1
                    infos.append(EdgeInfo(sign: N[t], plane: nil, footprint: false, border: true)); continue
                }
                if cls[o] == .alongside {
                    infos.append(EdgeInfo(sign: unitOr(N[t] + N[o], N[t]), plane: nil, footprint: false, border: false)); continue
                }
                cBorder += 1
                var w = unitOr(simd_cross(N[o], e), .zero)
                if simd_dot(w, centroid(o) - a) < 0 { w = -w }
                let kappa = simd_dot(N[t], w)
                let turn = acos(Swift.max(-1, Swift.min(1, simd_dot(N[t], N[o]))))
                let convex = kappa < -0.05
                var m = unitOr(simd_cross(N[t], e), .zero)
                if simd_dot(m, centroid(t) - a) < 0 { m = -m }
                let footprintPlane = Plane(n: -m, d: simd_dot(m, a))
                let neighbourPlane = Plane(n: N[o], d: -simd_dot(N[o], a))
                let sign = convex ? unitOr(N[t] - w, N[t]) : N[o]
                var plane: Plane? = nil
                var fp = false
                switch cls[o] {
                case .selected:
                    if !convex { plane = footprintPlane; fp = true }
                case .open, .none:
                    if convex && turn >= 20 * Double.pi / 180 { plane = neighbourPlane } else { plane = footprintPlane; fp = true }
                case .alongside: break
                }
                if opt.noFootprint { plane = nil; fp = false }
                if let pl = plane {
                    if fp { cFoot += 1; tapers.append((a, b)) } else { cNeigh += 1 }
                    vertexPlanes[vkey(a), default: []].append(pl)
                    vertexPlanes[vkey(b), default: []].append(pl)
                }
                borderSignAtVertex[vkey(a), default: .zero] += sign
                borderSignAtVertex[vkey(b), default: .zero] += sign
                infos.append(EdgeInfo(sign: sign, plane: plane, footprint: fp, border: true))
            }
            for k in 0..<3 {
                let e1 = unitOr(vs[(k + 1) % 3] - vs[k], .zero), e2 = unitOr(vs[(k + 2) % 3] - vs[k], .zero)
                let ang = acos(Swift.max(-1, Swift.min(1, simd_dot(e1, e2))))
                interiorNormalAtVertex[vkey(vs[k]), default: .zero] += N[t] * ang
            }
            alongIdx.append(t); edgeInfo.append(infos)
        }
        // neighbour planes of open/no-id triangles touching a vertex (fan tips against an open face)
        if !opt.noFootprint {
            var touched = Set<VKey>()
            for t in alongIdx { for v in [A[t], B[t], C[t]] { touched.insert(vkey(v)) } }
            for t in 0..<triCount where area[t] > 1e-12 && (cls[t] == .open || cls[t] == .none) {
                for v in [A[t], B[t], C[t]] where touched.contains(vkey(v)) {
                    vertexPlanes[vkey(v), default: []].append(Plane(n: N[t], d: -simd_dot(N[t], v)))
                }
            }
        }
        var cOverflow = 0
        for (li, t) in alongIdx.enumerated() {
            let vs = [A[t], B[t], C[t]]
            var planes = edgeInfo[li].compactMap { $0.plane }
            for v in vs {
                for pl in vertexPlanes[vkey(v)] ?? [] {
                    if planes.contains(where: { simd_distance($0.n, pl.n) < 1e-9 && abs($0.d - pl.d) < 1e-9 }) { continue }
                    // a plane joins only when it does not cut the triangle
                    if vs.allSatisfy({ pl.term($0) <= 1e-4 }) {
                        if planes.count < 8 { planes.append(pl) } else { cOverflow += 1 }
                    }
                }
            }
            var sv = [SIMD3<Double>](repeating: N[t], count: 7)
            for k in 0..<3 { sv[1 + k] = edgeInfo[li][k].sign }
            for k in 0..<3 {
                let key = vkey(vs[k])
                if let bs = borderSignAtVertex[key], simd_length(bs) > 1e-9 { sv[4 + k] = unitOr(bs, N[t]) }
                else { sv[4 + k] = unitOr(interiorNormalAtVertex[key] ?? N[t], N[t]) }
            }
            pieces.append(Piece(a: vs[0], b: vs[1], c: vs[2], planes: planes, width: c, isAlongside: true, signVec: sv,
                                lo: simd_min(vs[0], simd_min(vs[1], vs[2])), hi: simd_max(vs[0], simd_max(vs[1], vs[2]))))
        }
        counts["alongsideTris"] = alongIdx.count
        counts["footprintEdges"] = cFoot
        counts["neighbourPlanes"] = cNeigh
        counts["unmatchedEdges"] = cUnmatched
        counts["borderEdges"] = cBorder
        counts["planeOverflow"] = cOverflow
        counts["taperSegments"] = tapers.count
        lap("adjacency", &tl)

        // ── the coarse pocket q (exact through the caps), in parallel
        let nx = solid.nx, ny = solid.ny, nz = solid.nz
        let so = SIMD3<Double>(solid.origin), ss = SIMD3<Double>(solid.spacing)
        func nodeC(_ i: Int, _ j: Int, _ k: Int) -> SIMD3<Double> { so + SIMD3(Double(i), Double(j), Double(k)) * ss }
        // ★ each include region once, whole-prism and slab forms, with a bounding box so a
        // voxel farther than the cap from a region skips its polygon entirely
        struct RegionEval { var slab: LatticeRegionSpec; var whole: LatticeRegionSpec; var lo: SIMD3<Double>; var hi: SIMD3<Double> }
        let evals: [RegionEval] = regions.filter { $0.role == .include }.map { r in
            var w = r; w.thicknessMap = nil
            var lo = SIMD3<Double>(repeating: -1e9), hi = SIMD3<Double>(repeating: 1e9)
            if r.kind == .face {
                let n = LatticeRegionMask.unit(r.normal)
                let (u, v) = LatticeRegionMask.basis(n)
                var pts: [SIMD2<Double>] = r.outlineLoops.flatMap { $0 }
                if pts.isEmpty { pts = [SIMD2(-r.halfUMM, -r.halfWMM), SIMD2(r.halfUMM, r.halfWMM), SIMD2(-r.halfUMM, r.halfWMM), SIMD2(r.halfUMM, -r.halfWMM)] }
                let grow = Swift.max(0, r.inPlaneOffsetMM) + 2 * r.depthMM   // flares tilt out by at most the depth
                lo = SIMD3(repeating: 1e9); hi = SIMD3(repeating: -1e9)
                for q in pts { for dd in [0.0, r.depthMM] {
                    let pt = r.origin + u * q.x + v * q.y + n * dd
                    lo = simd_min(lo, pt); hi = simd_max(hi, pt)
                } }
                lo -= SIMD3(repeating: grow); hi += SIMD3(repeating: grow)
            }
            return RegionEval(slab: r, whole: w, lo: lo, hi: hi)
        }
        func pocketQ(_ p: SIMD3<Double>, slab: Bool) -> Double {
            var best = 1e9
            for ev in evals {
                let dOut = simd_length(simd_max(simd_max(ev.lo - p, p - ev.hi), .zero))
                if dOut > qCap + 1e-6 { best = Swift.min(best, dOut); continue }
                best = Swift.min(best, LatticeRegionMask.signedDistance(p, region: slab ? ev.slab : ev.whole, reachMM: qCap))
            }
            return Swift.max(-reachC, Swift.min(qCap, best))
        }
        // ★ voxels more than 2 away from any solid voxel are far air: every reader there is
        // dominated by the part's own distance, so the exact pocket is not evaluated
        var near = solid.values.map { $0 > 0.5 }
        for axis in 0..<3 { for _ in 0..<2 {
            var nxt = near
            for k in 0..<nz { for j in 0..<ny { for i in 0..<nx where !near[(k * ny + j) * nx + i] {
                let (a, b) = axis == 0 ? (i > 0 ? near[(k * ny + j) * nx + i - 1] : false, i < nx - 1 ? near[(k * ny + j) * nx + i + 1] : false)
                    : axis == 1 ? (j > 0 ? near[(k * ny + j - 1) * nx + i] : false, j < ny - 1 ? near[(k * ny + j + 1) * nx + i] : false)
                    : (k > 0 ? near[((k - 1) * ny + j) * nx + i] : false, k < nz - 1 ? near[((k + 1) * ny + j) * nx + i] : false)
                if a || b { nxt[(k * ny + j) * nx + i] = true }
            } } }
            near = nxt
        } }
        var qC = [Float](repeating: Float(qCap), count: nx * ny * nz)
        var qSlabC = qC
        qC.withUnsafeMutableBufferPointer { qb in
            qSlabC.withUnsafeMutableBufferPointer { sb in
                DispatchQueue.concurrentPerform(iterations: nz) { k in
                    for j in 0..<ny { for i in 0..<nx {
                        let e0 = (k * ny + j) * nx + i
                        if !near[e0] { continue }
                        let p = nodeC(i, j, k), e = e0
                        let w = pocketQ(p, slab: false)
                        qb[e] = Float(w)
                        // the slab form differs only inside the prism's footprint
                        sb[e] = w >= qCap - 1e-6 ? Float(w) : Float(pocketQ(p, slab: true))
                    } }
                }
            }
        }
        let qGrid = LatticeVoxelGrid(nx: nx, ny: ny, nz: nz, origin: solid.origin, spacing: solid.spacing, values: qC)
        lap("pocket", &tl)

        // ── the band scatter over a grid
        struct GridSpec { var origin: SIMD3<Double>; var h: Double; var nx: Int; var ny: Int; var nz: Int }
        struct BandOut { var br: [Float]; var delta: [Float]; var grade: [Float]; var taperE: [Float]; var nearTri: [Int32]; var nearFeat: [UInt8] }
        func scatter(_ G: GridSpec, reach: Double, wantGrade: Bool, pcs pieces: [Piece]) -> BandOut {
            let n = G.nx * G.ny * G.nz
            // ★ the band matters only in and next to the pocket (rim, skin, green, the shell's
            // rule all need q ≤ 0); elsewhere B_r takes the pocket distance, which is still a
            // valid lower bound on the distance to the rim (the rim lies inside the pocket)
            // nearest coarse voxel, by index arithmetic (a conservative mask: the margin is 2 voxels)
            var qAt = [Float](repeating: 0, count: n)
            let r0 = (G.origin - so) / ss, rs = G.h / ss.x
            qAt.withUnsafeMutableBufferPointer { qa in
                DispatchQueue.concurrentPerform(iterations: G.nz) { k in
                    let ck = Swift.max(0, Swift.min(nz - 1, Int((r0.z + Double(k) * rs).rounded())))
                    for j in 0..<G.ny {
                        let cj = Swift.max(0, Swift.min(ny - 1, Int((r0.y + Double(j) * rs).rounded())))
                        let rowC = (ck * ny + cj) * nx, rowF = (k * G.ny + j) * G.nx
                        for i in 0..<G.nx {
                            let ci = Swift.max(0, Swift.min(nx - 1, Int((r0.x + Double(i) * rs).rounded())))
                            qa[rowF + i] = qC[rowC + ci]
                        }
                    }
                }
            }
            let activeQ = Float(2 * h + (G.h < h ? h : 0))
            var br = [Float](repeating: Float(reach - c), count: n)
            var d2 = [Float](repeating: .greatestFiniteMagnitude, count: n)
            var grade = [Float](repeating: Float(g + 2 * h), count: n)
            var nearTri = [Int32](repeating: -1, count: n)
            var nearFeat = [UInt8](repeating: 0, count: n)
            var taperE = [Float](repeating: .greatestFiniteMagnitude, count: n)
            let pad = Int((reach / G.h).rounded(.up)) + 1
            let slabs = Swift.max(1, Swift.min(G.nz, ProcessInfo.processInfo.activeProcessorCount * 2))
            br.withUnsafeMutableBufferPointer { brb in d2.withUnsafeMutableBufferPointer { d2b in
            grade.withUnsafeMutableBufferPointer { gb in nearTri.withUnsafeMutableBufferPointer { ntb in
            nearFeat.withUnsafeMutableBufferPointer { nfb in taperE.withUnsafeMutableBufferPointer { teb in
                DispatchQueue.concurrentPerform(iterations: slabs) { slab in
                    let k0s = G.nz * slab / slabs, k1s = G.nz * (slab + 1) / slabs
                    guard k0s < k1s else { return }
                    for (pi, pc) in pieces.enumerated() {
                        if !evals.contains(where: { simd_reduce_max(simd_max(pc.lo - reach - $0.hi, $0.lo - pc.hi - reach)) <= 0 }) { continue }
                        let lo = (pc.lo - G.origin) / G.h, hi = (pc.hi - G.origin) / G.h
                        let k0 = Swift.max(k0s, Int(lo.z.rounded(.down)) - pad), k1 = Swift.min(k1s - 1, Int(hi.z.rounded(.up)) + pad)
                        guard k0 <= k1 else { continue }
                        let i0 = Swift.max(0, Int(lo.x.rounded(.down)) - pad), i1 = Swift.min(G.nx - 1, Int(hi.x.rounded(.up)) + pad)
                        let j0 = Swift.max(0, Int(lo.y.rounded(.down)) - pad), j1 = Swift.min(G.ny - 1, Int(hi.y.rounded(.up)) + pad)
                        guard i0 <= i1, j0 <= j1 else { continue }
                        for k in k0...k1 { for j in j0...j1 { for i in i0...i1 {
                            let e = (k * G.ny + j) * G.nx + i
                            if qAt[e] > activeQ { continue }
                            let p = G.origin + SIMD3(Double(i), Double(j), Double(k)) * G.h
                            let (cp, feat) = closest(p, pc.a, pc.b, pc.c)
                            let dd = simd_distance_squared(p, cp)
                            if dd > reach * reach { continue }
                            let D = dd.squareRoot()
                            var phi = -reach
                            for pl in pc.planes { phi = Swift.max(phi, pl.term(p)) }
                            let b = Swift.max(D - pc.width, phi)
                            if Float(b) < brb[e] { brb[e] = Float(b) }
                            if pc.isAlongside && Float(dd) < d2b[e] { d2b[e] = Float(dd); ntb[e] = Int32(pi); nfb[e] = UInt8(feat) }
                            if wantGrade {
                                var gv = Swift.max(D - pc.width, K * phi)
                                if !opt.noRimFoot && D > pc.width && D < pc.width + g + h {
                                    let foot = cp + (p - cp) * (pc.width / D)
                                    gv = Swift.max(gv, K * qGrid.sampleLinear(foot))
                                }
                                if Float(gv) < gb[e] { gb[e] = Float(gv) }
                            }
                        } } }
                    }
                    if opt.skinTaper {
                        let padT = Int((wT / G.h).rounded(.up)) + 1
                        for (ta, tb) in tapers {
                            let lo = (simd_min(ta, tb) - G.origin) / G.h, hi = (simd_max(ta, tb) - G.origin) / G.h
                            let k0 = Swift.max(k0s, Int(lo.z.rounded(.down)) - padT), k1 = Swift.min(k1s - 1, Int(hi.z.rounded(.up)) + padT)
                            guard k0 <= k1 else { continue }
                            let i0 = Swift.max(0, Int(lo.x.rounded(.down)) - padT), i1 = Swift.min(G.nx - 1, Int(hi.x.rounded(.up)) + padT)
                            let j0 = Swift.max(0, Int(lo.y.rounded(.down)) - padT), j1 = Swift.min(G.ny - 1, Int(hi.y.rounded(.up)) + padT)
                            guard i0 <= i1, j0 <= j1 else { continue }
                            let ab = tb - ta, l2 = Swift.max(simd_length_squared(ab), 1e-18)
                            for k in k0...k1 { for j in j0...j1 { for i in i0...i1 {
                                let p = G.origin + SIMD3(Double(i), Double(j), Double(k)) * G.h
                                let u = Swift.max(0, Swift.min(1, simd_dot(p - ta, ab) / l2))
                                let dE = Float(simd_distance(p, ta + ab * u))
                                let e = (k * G.ny + j) * G.nx + i
                                if dE < teb[e] { teb[e] = dE }
                            } } }
                        }
                    }
                }
            } } } } } }
            // Δ: ±distance to the alongside set, signed by the closest feature's sign vector
            var delta = [Float](repeating: Float(reach), count: n)
            for e in 0..<n where nearTri[e] >= 0 {
                let pc = pieces[Int(nearTri[e])]
                let k = e / (G.nx * G.ny), rem = e % (G.nx * G.ny), j = rem / G.nx, i = rem % G.nx
                let p = G.origin + SIMD3(Double(i), Double(j), Double(k)) * G.h
                let (cp, feat) = closest(p, pc.a, pc.b, pc.c)
                let D = Double(d2[e]).squareRoot()
                let inside = simd_dot(p - cp, pc.signVec[feat]) < 0
                delta[e] = Float(Swift.min(reach, D)) * (inside ? 1 : -1)
                _ = feat
            }
            for e in 0..<n {
                if qAt[e] > activeQ { br[e] = Swift.min(br[e], qAt[e]) }
                br[e] = Swift.max(Float(-c), Swift.min(Float(reach - c), br[e]))
            }
            if wantGrade { for e in 0..<n { grade[e] = Swift.max(Float(-c), Swift.min(Float(g + 2 * h), grade[e])) } }
            return BandOut(br: br, delta: delta, grade: grade, taperE: taperE, nearTri: nearTri, nearFeat: nearFeat)
        }

        // ── the material distance with a geometric sign, over a grid
        func material(_ G: GridSpec, reach: Double) -> [Float] {
            let n = G.nx * G.ny * G.nz
            var d2 = [Float](repeating: .greatestFiniteMagnitude, count: n)
            var near = [Int32](repeating: -1, count: n)
            let pad = Int((reach / G.h).rounded(.up)) + 1
            let slabs = Swift.max(1, Swift.min(G.nz, ProcessInfo.processInfo.activeProcessorCount * 2))
            d2.withUnsafeMutableBufferPointer { db in near.withUnsafeMutableBufferPointer { nb in
                DispatchQueue.concurrentPerform(iterations: slabs) { slab in
                    let k0s = G.nz * slab / slabs, k1s = G.nz * (slab + 1) / slabs
                    guard k0s < k1s else { return }
                    for t in 0..<triCount where area[t] > 1e-12 {
                        let lo = (simd_min(A[t], simd_min(B[t], C[t])) - G.origin) / G.h
                        let hi = (simd_max(A[t], simd_max(B[t], C[t])) - G.origin) / G.h
                        let k0 = Swift.max(k0s, Int(lo.z.rounded(.down)) - pad), k1 = Swift.min(k1s - 1, Int(hi.z.rounded(.up)) + pad)
                        guard k0 <= k1 else { continue }
                        let i0 = Swift.max(0, Int(lo.x.rounded(.down)) - pad), i1 = Swift.min(G.nx - 1, Int(hi.x.rounded(.up)) + pad)
                        let j0 = Swift.max(0, Int(lo.y.rounded(.down)) - pad), j1 = Swift.min(G.ny - 1, Int(hi.y.rounded(.up)) + pad)
                        guard i0 <= i1, j0 <= j1 else { continue }
                        for k in k0...k1 { for j in j0...j1 { for i in i0...i1 {
                            let p = G.origin + SIMD3(Double(i), Double(j), Double(k)) * G.h
                            let (cp, _) = closest(p, A[t], B[t], C[t])
                            let dd = Float(simd_distance_squared(p, cp))
                            let e = (k * G.ny + j) * G.nx + i
                            if dd < db[e] { db[e] = dd; nb[e] = Int32(t) }
                        } } }
                    }
                }
            } }
            var out = [Float](repeating: Float(reach), count: n)
            // beyond the reach: the sign of the nearest node that has one is not known, so
            // parity-fill the far field from the coarse occupancy (it is far from any surface)
            for e in 0..<n {
                let k = e / (G.nx * G.ny), rem = e % (G.nx * G.ny), j = rem / G.nx, i = rem % G.nx
                let p = G.origin + SIMD3(Double(i), Double(j), Double(k)) * G.h
                // ★ only within the reach is the nearest triangle known to be THE nearest (a node
                // inside one big triangle's padded box can be far from every triangle)
                if near[e] >= 0, Double(d2[e]) <= reach * reach {
                    let t = Int(near[e])
                    let (cp, feat) = closest(p, A[t], B[t], C[t])
                    let D = Swift.min(reach, Double(d2[e]).squareRoot())
                    let outside = simd_dot(p - cp, pseudoAll(t, feat)) >= 0
                    out[e] = Float(outside ? D : -D)
                } else {
                    out[e] = solidNearest(p) ? Float(-reach) : Float(reach)
                }
            }
            return out
        }
        func solidNearest(_ p: SIMD3<Double>) -> Bool {
            let gi = (p - so) / ss
            let a = Int(gi.x.rounded()), b = Int(gi.y.rounded()), cc = Int(gi.z.rounded())
            guard a >= 0, b >= 0, cc >= 0, a < nx, b < ny, cc < nz else { return false }
            return solid.values[(cc * ny + b) * nx + a] > 0.5
        }

        // ── coarse grid
        let GC = GridSpec(origin: so, h: h, nx: nx, ny: ny, nz: nz)
        let matC = material(GC, reach: 3 * h)
        lap("materialC", &tl)
        var bandC = scatter(GC, reach: reachC, wantGrade: true, pcs: pieces)
        lap("bandC", &tl)
        // ── ★ SOLID-BACKED PRISM SIDES (his G4: "the *bottom* of the lattice … is an OUTLINE and
        // absolutely should get a rim! It's the front and back faces that do not touch anything
        // that shouldn't get a rim"): a prism side wall inside the part's material, not already
        // under an alongside face's band, gets a rim of the organic rim width (no skin — there is
        // no surface there) and green. Tiles of ≤ 2 mm × ≤ 3 mm on the grown outline wall, each
        // kept when the material continues 1.5 voxels beyond it, outside every prism.
        // `LATTICE_BAND_CAP_RIM=1` tiles the depth caps the same way (a rim facing the solid).
        let deltaGridC = LatticeVoxelGrid(nx: nx, ny: ny, nz: nz, origin: solid.origin, spacing: solid.spacing, values: bandC.delta)
        let matGridC = LatticeVoxelGrid(nx: nx, ny: ny, nz: nz, origin: solid.origin, spacing: solid.spacing, values: matC)
        func backed(_ probe: SIMD3<Double>) -> Bool {
            matGridC.sampleLinear(probe) < -0.25 * h && qGrid.sampleLinear(probe) > 0.25 * h && abs(deltaGridC.sampleLinear(probe)) > c
        }
        var tiles: [Piece] = []
        var sideTiles = 0, capTiles = 0
        if rO > 0 {
            for rg in includeFaces where !rg.outlineLoops.isEmpty && rg.depthMM > 0 {
                let n = LatticeRegionMask.unit(rg.normal)
                let (u, v) = LatticeRegionMask.basis(n)
                func to3(_ q: SIMD2<Double>, _ d: Double) -> SIMD3<Double> { rg.origin + u * q.x + v * q.y + n * d }
                let nDepth = Swift.max(1, Int((rg.depthMM / 3).rounded(.up)))
                for (li, loop) in rg.outlineLoops.enumerated() {
                    let seams = li < rg.outlineSeams.count ? rg.outlineSeams[li] : []
                    let grown = LatticeOutlineRibbon.offsetRing(loop, by: -rg.inPlaneOffsetMM, seams: seams)
                    let inN = LatticeOutlineRibbon.edgeInwardNormals(grown)
                    let m = grown.count
                    guard m >= 3 else { continue }
                    for i in 0..<m where !(i < seams.count && seams[i]) {
                        let p0 = grown[i], p1 = grown[(i + 1) % m]
                        let L = simd_distance(p0, p1)
                        guard L > 1e-6 else { continue }
                        let nSpan = Swift.max(1, Int((L / 2).rounded(.up)))
                        let out = -inN[i]
                        for db in 0..<nDepth {
                            let d0 = rg.depthMM * Double(db) / Double(nDepth), d1 = rg.depthMM * Double(db + 1) / Double(nDepth)
                            var ok = [Bool](repeating: false, count: nSpan)
                            for sp in 0..<nSpan {
                                let mid = p0 + (p1 - p0) * ((Double(sp) + 0.5) / Double(nSpan))
                                ok[sp] = backed(to3(mid + out * (1.5 * h), 0.5 * (d0 + d1)))
                            }
                            let dir3 = simd_normalize(to3(p1, 0) - to3(p0, 0))
                            for sp in 0..<nSpan where ok[sp] {
                                let qa = p0 + (p1 - p0) * (Double(sp) / Double(nSpan)), qb = p0 + (p1 - p0) * (Double(sp + 1) / Double(nSpan))
                                let a0 = to3(qa, d0), b0 = to3(qb, d0), a1 = to3(qa, d1), b1 = to3(qb, d1)
                                var planes: [Plane] = []
                                if sp == 0 || !ok[sp - 1] { planes.append(Plane(n: -dir3, d: simd_dot(dir3, a0))) }
                                if sp == nSpan - 1 || !ok[sp + 1] { planes.append(Plane(n: dir3, d: -simd_dot(dir3, b0))) }
                                for (x, y, z) in [(a0, b0, b1), (a0, b1, a1)] {
                                    tiles.append(Piece(a: x, b: y, c: z, planes: planes, width: rO, isAlongside: false,
                                                       signVec: [], lo: simd_min(x, simd_min(y, z)), hi: simd_max(x, simd_max(y, z))))
                                }
                                sideTiles += 1
                            }
                        }
                    }
                }
                if opt.capRim {
                    // the depth cap: 2 mm tiles over the grown polygon at the prism's full depth
                    let pts = rg.outlineLoops.flatMap { $0 }
                    var lo2 = SIMD2<Double>(repeating: 1e9), hi2 = SIMD2<Double>(repeating: -1e9)
                    for q in pts { lo2 = simd_min(lo2, q); hi2 = simd_max(hi2, q) }
                    lo2 -= SIMD2(repeating: Swift.max(0, rg.inPlaneOffsetMM)); hi2 += SIMD2(repeating: Swift.max(0, rg.inPlaneOffsetMM))
                    let D = rg.depthMM
                    var y = lo2.y
                    while y < hi2.y { var x = lo2.x
                        while x < hi2.x {
                            let mid = SIMD2(x + 1, y + 1)
                            let sd = LatticeFaceOutline.signedDistance(mid, loops: rg.outlineLoops, seams: rg.outlineSeams)
                            if sd <= rg.inPlaneOffsetMM, backed(to3(mid, D + 1.5 * h)) {
                                let a0 = to3(SIMD2(x, y), D), b0 = to3(SIMD2(x + 2, y), D), b1 = to3(SIMD2(x + 2, y + 2), D), a1 = to3(SIMD2(x, y + 2), D)
                                for (p, q, w) in [(a0, b0, b1), (a0, b1, a1)] {
                                    tiles.append(Piece(a: p, b: q, c: w, planes: [], width: rO, isAlongside: false,
                                                       signVec: [], lo: simd_min(p, simd_min(q, w)), hi: simd_max(p, simd_max(q, w))))
                                }
                                capTiles += 1
                            }
                            x += 2 }
                        y += 2 }
                }
            }
        }
        counts["sideTiles"] = sideTiles; counts["capTiles"] = capTiles
        if !tiles.isEmpty {
            let t = scatter(GC, reach: reachC, wantGrade: true, pcs: tiles)
            for e in 0..<bandC.br.count { bandC.br[e] = Swift.min(bandC.br[e], t.br[e]); bandC.grade[e] = Swift.min(bandC.grade[e], t.grade[e]) }
        }
        lap("tiles", &tl)
        var carvedC = [Float](repeating: 0, count: nx * ny * nz)
        var skinC = carvedC, latticedC = carvedC
        var skinVox = 0, rimVox = 0, gradeVox = 0, signDisagree = 0
        for e in 0..<carvedC.count {
            var cv = Swift.max(qC[e], -bandC.br[e])
            if params.finishSkinMM > 0 { cv = Swift.max(cv, matC[e] + Float(params.finishSkinMM)) }
            carvedC[e] = cv
            let tau: Float = opt.skinTaper ? Swift.max(0, Swift.min(1, bandC.taperE[e] / Float(wT))) : 1
            var dl = bandC.delta[e]
            if opt.signFromSolid, bandC.nearTri[e] >= 0 { dl = (matC[e] < 0 ? 1 : -1) * abs(dl) }
            skinC[e] = dl - Float(s) * tau
            latticedC[e] = Swift.max(matC[e], qSlabC[e])
            if qC[e] < 0, bandC.br[e] <= 0, matC[e] < 0 { if skinC[e] < 0 { skinVox += 1 } else { rimVox += 1 } }
            if qC[e] < 0, bandC.br[e] > 0, bandC.grade[e] < Float(g) { gradeVox += 1 }
            if bandC.br[e] <= 0, matC[e] < Float(-h), dl < 0 { signDisagree += 1 }
        }
        counts["skinVoxels"] = skinVox; counts["rimVoxels"] = rimVox; counts["gradeVoxels"] = gradeVox
        counts["signDisagreeC"] = signDisagree
        lap("combineC", &tl)

        // ── fine, padded grid
        var hf = opt.fineAtCoarse ? h : 0.5 * h
        let ext = SIMD3<Double>(mesh.bounds.max - mesh.bounds.min)
        func fineDims(_ hf: Double) -> (Int, Int, Int) {
            let padN = opt.noPad ? 1 : 8
            return (Int((ext.x / hf).rounded(.up)) + padN, Int((ext.y / hf).rounded(.up)) + padN, Int((ext.z / hf).rounded(.up)) + padN)
        }
        var fd = fineDims(hf)
        let budget = 6_000_000.0
        if Double(fd.0 * fd.1 * fd.2) > budget {
            let vol = ext.x * ext.y * ext.z
            hf = Swift.max(hf, cbrt(vol / budget) * 1.02)
            fd = fineDims(hf)
        }
        let fOrigin = SIMD3<Double>(mesh.bounds.min) - (opt.noPad ? .zero : SIMD3<Double>(repeating: 3.5 * hf))
        let GF = GridSpec(origin: fOrigin, h: hf, nx: fd.0, ny: fd.1, nz: fd.2)
        let reachF = c + 3 * hf
        let matF = material(GF, reach: 3 * hf)
        lap("materialF", &tl)
        var bandF = scatter(GF, reach: reachF, wantGrade: false, pcs: pieces)
        if !tiles.isEmpty {
            let t = scatter(GF, reach: reachF, wantGrade: false, pcs: tiles)
            for e in 0..<bandF.br.count { bandF.br[e] = Swift.min(bandF.br[e], t.br[e]) }
        }
        lap("bandF", &tl)
        let nF = fd.0 * fd.1 * fd.2
        var tex = [Float16](repeating: 0, count: 4 * nF)
        var rimTexels = 0
        tex.withUnsafeMutableBufferPointer { tb in
            DispatchQueue.concurrentPerform(iterations: fd.2) { k in
                for j in 0..<fd.1 { for i in 0..<fd.0 {
                    let e = (k * fd.1 + j) * fd.0 + i
                    let p = fOrigin + SIMD3(Double(i), Double(j), Double(k)) * hf
                    let br = bandF.br[e]
                    let tau: Float = opt.skinTaper ? Swift.max(0, Swift.min(1, bandF.taperE[e] / Float(wT))) : 1
                    var dl = bandF.delta[e]
                    if opt.signFromSolid, bandF.nearTri[e] >= 0 { dl = (matF[e] < 0 ? 1 : -1) * abs(dl) }
                    let ks = dl - Float(s) * tau
                    // ★ exact only where a rim hit is possible (every other rim term within two
                    // texels of zero); elsewhere a guaranteed LOWER bound (nearest coarse value
                    // minus a voxel), so the march's step bound never overstates the distance
                    let gi = (p - so) / ss
                    let ci = Swift.max(0, Swift.min(nx - 1, Int(gi.x.rounded()))), cj = Swift.max(0, Swift.min(ny - 1, Int(gi.y.rounded())))
                    let ck = Swift.max(0, Swift.min(nz - 1, Int(gi.z.rounded())))
                    var q = Swift.min(Float(qCap), qC[(ck * ny + cj) * nx + ci] - Float(h))
                    let m2 = Float(2 * hf)
                    if br <= m2, matF[e] <= m2, ks >= -m2 {
                        q = Float(pocketQ(p, slab: false))
                    }
                    tb[4 * e] = Float16(br); tb[4 * e + 1] = Float16(Swift.max(-100, Swift.min(100, ks)))
                    tb[4 * e + 2] = Float16(matF[e]); tb[4 * e + 3] = Float16(q)
                } }
            }
        }
        for e in 0..<nF where tex[4 * e] <= 0 && tex[4 * e + 1] >= 0 && tex[4 * e + 2] <= 0 && tex[4 * e + 3] <= 0 { rimTexels += 1 }
        counts["rimTexelsFine"] = rimTexels
        lap("packF", &tl)

        func grid(_ v: [Float]) -> LatticeVoxelGrid { LatticeVoxelGrid(nx: nx, ny: ny, nz: nz, origin: solid.origin, spacing: solid.spacing, values: v) }
        let fine = LatticeBandFine(origin: SIMD3<Float>(fOrigin), spacing: Float(hf),
                                   dims: SIMD3<Int32>(Int32(fd.0), Int32(fd.1), Int32(fd.2)), texels: tex)
        var classCounts: [FaceClass: Int] = [:]
        for (_, v) in classByFace { classCounts[v, default: 0] += 1 }
        let faceList = classByFace.keys.sorted().map { f -> String in
            let v = classByFace[f]!
            return "f\(f)=\(v == .open ? "O" : v == .alongside ? "A" : v == .selected ? "S" : "N")"
        }.joined(separator: " ")
        let diag = String(format: "DIAG band v1: skin %.2f rim %.2f side-rim %.2f band %.1f mm · h %.3f fine %.3f (%d×%d×%d) · alongside tris %d, border edges %d (footprint %d, neighbour %d), unmatched %d, overflow %d, taper segs %d · side tiles %d, cap tiles %d · voxels skin %d rim %d grade %d · sign disagreements %d · fine rim texels %d · ms %@ · faces %@",
                          s, r, rO, g, h, hf, fd.0, fd.1, fd.2, alongIdx.count, cBorder, cFoot, cNeigh, cUnmatched, cOverflow, tapers.count, sideTiles, capTiles,
                          skinVox, rimVox, gradeVox, signDisagree, rimTexels,
                          timings.sorted { $0.key < $1.key }.map { "\($0.key)=\(Int($0.value))" }.joined(separator: ","), faceList)
        _ = t0
        return Result(qC: qGrid, carvedC: grid(carvedC), gradeC: grid(bandC.grade), skinC: grid(skinC), rimC: grid(bandC.br),
                      materialC: grid(matC), latticedC: grid(latticedC), fine: fine, classByFace: classByFace,
                      diag: diag, counts: counts)
    }
}

extension LatticeVoxelGrid {
    /// Node-centred trilinear read with clamp-to-edge — the CPU twin of the shader's
    /// `((p − origin)/spacing + 0.5)/n` linear sample.
    public func sampleLinear(_ p: SIMD3<Double>) -> Double {
        let g = (SIMD3<Float>(p) - origin) / spacing
        func cl(_ v: Int, _ n: Int) -> Int { Swift.max(0, Swift.min(n - 1, v)) }
        let fx = g.x.rounded(.down), fy = g.y.rounded(.down), fz = g.z.rounded(.down)
        let tx = g.x - fx, ty = g.y - fy, tz = g.z - fz
        let x0 = cl(Int(fx), nx), x1 = cl(Int(fx) + 1, nx), y0 = cl(Int(fy), ny), y1 = cl(Int(fy) + 1, ny)
        let z0 = cl(Int(fz), nz), z1 = cl(Int(fz) + 1, nz)
        func v(_ x: Int, _ y: Int, _ z: Int) -> Float { values[(z * ny + y) * nx + x] }
        let c00 = v(x0, y0, z0) * (1 - tx) + v(x1, y0, z0) * tx, c10 = v(x0, y1, z0) * (1 - tx) + v(x1, y1, z0) * tx
        let c01 = v(x0, y0, z1) * (1 - tx) + v(x1, y0, z1) * tx, c11 = v(x0, y1, z1) * (1 - tx) + v(x1, y1, z1) * tx
        return Double((c00 * (1 - ty) + c10 * ty) * (1 - tz) + (c01 * (1 - ty) + c11 * ty) * tz)
    }
}
