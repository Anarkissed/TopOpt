// FlexibleFinish — the WHOLE model's finish: None / Rim / Skin / Covered (task
// 2026-09-29-flexible-screens, round 4 batch D1; his img 5: "there should be a way to define
// the *entire* model to have a different finish like in the other lattice area: Rim, skin,
// or covered", and his answer 4). It replaces the per-face "Solid skin" row.
//
//   none ...... the lattice runs to the surface everywhere;
//   rim ....... a SOLID band along every face edge (`rimMM` round each edge); the faces open;
//   skin ...... a thin PERFORATED skin over the lattice: `skinMM` of solid under every
//               surface, with round holes 3 mm ACROSS (`holeRadiusMM` = 1.5 is a RADIUS), on a
//               hex grid `holePitchMM` = 5 mm apart — about a third of the skin open — through
//               which the lattice reaches the surface;
//   covered ... a solid skin everywhere (the default, and what every project had before).
//
// ★ HOW THE PREVIEW DRAWS IT — ONE CHANNEL, NO SHADER CHANGE. The lattice field is
// F = max(wall, dRegion, dPart, dSkin) with dSkin = skinMM − skinDist(p) (FlexibleLatticeField):
// wherever dSkin > 0 there is no lattice, and the part there is solid. So each finish is a
// skin-distance grid and a thickness, on the SDF's own grid:
//   covered: skinDist = the distance to every surface, thickness `defaultSkinMM`;
//   none:    skinDist = `farMM` everywhere (dSkin < 0: no skin anywhere);
//   rim:     skinDist = the distance to the part's face EDGES (the segments where two faces
//            meet), thickness `rimMM`;
//   skin:    skinDist = max(|surface distance|, skinMM − e), e the hole pattern's signed
//            distance at the nearest surface point — so dSkin = min(skinMM − |d|, e): the skin
//            band, minus the holes, continuous across a hole's rim (trilinear-friendly).
//
// ★ WHAT CORE CANNOT SAY (core brief): core's Flexible block has one `skin_on` per face
// (job_block.cpp:180) and nothing else. The job writes skin_on = true only for Covered; Rim's
// band and Skin's perforation exist in the app's preview only, and the constants below are the
// app's choice until core owns a `flexible.finish`.

import Foundation
import simd
import TopOptKit

public enum FlexibleFinish: String, CaseIterable, Codable, Sendable {
    case none, rim, skin, covered

    /// The run job's per-face `skin_on`: only Covered is a solid skin core can be told about.
    public var jobSkinOn: Bool { self == .covered }

    /// Rim: the solid band's radius round each face edge (mm). The app's choice (core brief).
    public static let rimMM: Float = 2.0
    /// Skin: the perforation — round holes on a hex grid, in each surface's own plane. ★ A
    /// RADIUS (verification of D1: the handoff said "1.5 mm holes"): the holes are 3 mm across,
    /// ~33 % of the skin open (π·1.5² / (5² · √3/2)).
    public static let holeRadiusMM: Float = 1.5
    public static var holeDiameterMM: Float { 2 * holeRadiusMM }
    public static let holePitchMM: Float = 5.0
    /// The share of a skin plane the holes open (the hex cell's area is pitch² · √3/2).
    public static var openFraction: Float { .pi * holeRadiusMM * holeRadiusMM / (holePitchMM * holePitchMM * 0.8660254) }
    /// "No skin anywhere near" (None): far beyond any skin thickness; fits a half float.
    public static let farMM: Float = 1000

    // MARK: the perforation pattern

    /// The nearest hole centre to a 2-D point: a hex grid, rows `pitch·√3/2` apart, every
    /// other row shifted by half a pitch.
    public static func holeCentreNear(_ q: SIMD2<Float>) -> SIMD2<Float> {
        let pitch = holePitchMM, row = pitch * 0.8660254
        let j0 = Int((q.y / row).rounded())
        var best = SIMD2<Float>(0, 0), bestD = Float.infinity
        for j in (j0 - 1)...(j0 + 1) {
            let off: Float = j & 1 == 0 ? 0 : pitch / 2
            let i = ((q.x - off) / pitch).rounded()
            let c = SIMD2<Float>(i * pitch + off, Float(j) * row)
            let d = simd_length_squared(q - c)
            if d < bestD { bestD = d; best = c }
        }
        return best
    }

    /// The hole pattern's signed distance (mm, negative inside a hole) at a surface point `p`
    /// whose outward normal is `n`: triplanar — the pattern lies in the two axes `n` is least
    /// along, so an axis-aligned face gets round holes.
    public static func holeDistance(_ p: SIMD3<Float>, normal n: SIMD3<Float>, radius: Float = holeRadiusMM) -> Float {
        let a = simd_abs(n)
        let q: SIMD2<Float> = a.z >= a.x && a.z >= a.y ? SIMD2(p.x, p.y)
            : (a.x >= a.y ? SIMD2(p.y, p.z) : SIMD2(p.x, p.z))
        return simd_length(q - holeCentreNear(q)) - radius
    }

    // MARK: the skin-distance grid

    /// The (skinDist grid, thickness) a finish draws with, on the SDF's grid — nil for
    /// Covered, whose grid the builder already makes (the distance to every skinned surface).
    static func skin(_ finish: FlexibleFinish, part: ViewerMesh, sdf: LatticeVoxelGrid,
                     bandVoxels: Int) -> (grid: FlexGrid, skinMM: Float)? {
        let sp = sdf.spacing.x
        func grid(_ v: [Float]) -> FlexGrid {
            FlexGrid(nx: sdf.nx, ny: sdf.ny, nz: sdf.nz, c0: sdf.origin, spacing: sp, values: v)
        }
        switch finish {
        case .covered:
            return nil
        case .none:
            return (grid([Float](repeating: farMM, count: sdf.count)), FlexibleLatticeField.defaultSkinMM)
        case .rim:
            let far = rimMM + 3 * sp
            let d = edgeDistance(segments: faceEdges(part), like: sdf, farMM: far)
            return (grid(d), rimMM)
        case .skin:
            let skinMM = FlexibleLatticeField.defaultSkinMM
            let near = nearestTriangle(part: part, like: sdf, bandVoxels: bandVoxels)
            var out = [Float](repeating: 0, count: sdf.count)
            let far = Float(bandVoxels) * sp
            for i in 0..<sdf.count {
                let t = near.tri[i]
                guard t >= 0 else { out[i] = Swift.max(abs(sdf.values[i]), far); continue }
                let (a, b, c) = triangle(part, Int(t))
                let p = sdf.origin + SIMD3<Float>(Float(i % sdf.nx), Float((i / sdf.nx) % sdf.ny), Float(i / (sdf.nx * sdf.ny))) * sdf.spacing
                let q = MeshGeometry.closestPointOnTriangle(p, a, b, c)
                let n = simd_cross(b - a, c - a)
                let e = holeDistance(q, normal: simd_length_squared(n) > 0 ? simd_normalize(n) : SIMD3(0, 0, 1))
                out[i] = Swift.max(abs(sdf.values[i]), skinMM - e)
            }
            return (grid(out), skinMM)
        }
    }

    // MARK: pieces (pure; FlexibleSettingsRound4Tests)

    static func triangle(_ m: ViewerMesh, _ t: Int) -> (SIMD3<Float>, SIMD3<Float>, SIMD3<Float>) {
        func v(_ k: Int) -> SIMD3<Float> {
            let b = Int(m.indices[3 * t + k]) * 3
            return SIMD3(m.positions[b], m.positions[b + 1], m.positions[b + 2])
        }
        return (v(0), v(1), v(2))
    }

    /// The part's face EDGES: every triangle edge shared by triangles of two different faces
    /// (matched by position, to 1 µm, so an unwelded mesh is read the same).
    static func faceEdges(_ m: ViewerMesh) -> [(SIMD3<Float>, SIMD3<Float>)] {
        struct K: Hashable { let x: Int32, y: Int32, z: Int32 }
        func k(_ p: SIMD3<Float>) -> K { K(x: Int32((p.x * 1000).rounded()), y: Int32((p.y * 1000).rounded()), z: Int32((p.z * 1000).rounded())) }
        struct E: Hashable { let a: K, b: K }
        var faces: [E: Set<Int32>] = [:]
        var ends: [E: (SIMD3<Float>, SIMD3<Float>)] = [:]
        let ids = m.faceIDs
        for t in 0..<(m.indices.count / 3) {
            let (a, b, c) = triangle(m, t)
            let fid: Int32 = t < ids.count ? ids[t] : -1
            for (p, q) in [(a, b), (b, c), (c, a)] {
                let kp = k(p), kq = k(q)
                let e = (kp.x, kp.y, kp.z) < (kq.x, kq.y, kq.z) ? E(a: kp, b: kq) : E(a: kq, b: kp)
                faces[e, default: []].insert(fid)
                if ends[e] == nil { ends[e] = (p, q) }
            }
        }
        return faces.compactMap { $0.value.count >= 2 ? ends[$0.key] : nil }
    }

    /// The unsigned distance to the nearest segment, on `like`'s grid — each segment writes its
    /// exact distance into its AABB padded by `farMM`, min-combined; untouched voxels read `farMM`.
    static func edgeDistance(segments: [(SIMD3<Float>, SIMD3<Float>)], like g: LatticeVoxelGrid, farMM: Float) -> [Float] {
        var d2 = [Float](repeating: farMM * farMM, count: g.count)
        let pad = SIMD3<Float>(repeating: farMM) / g.spacing
        for (a, b) in segments {
            let lo = (simd_min(a, b) - g.origin) / g.spacing - pad, hi = (simd_max(a, b) - g.origin) / g.spacing + pad
            let i0 = Swift.max(0, Int(lo.x.rounded(.down))), i1 = Swift.min(g.nx - 1, Int(hi.x.rounded(.up)))
            let j0 = Swift.max(0, Int(lo.y.rounded(.down))), j1 = Swift.min(g.ny - 1, Int(hi.y.rounded(.up)))
            let k0 = Swift.max(0, Int(lo.z.rounded(.down))), k1 = Swift.min(g.nz - 1, Int(hi.z.rounded(.up)))
            guard i0 <= i1, j0 <= j1, k0 <= k1 else { continue }
            let ab = b - a, len2 = simd_length_squared(ab)
            for k in k0...k1 { for j in j0...j1 { for i in i0...i1 {
                let p = g.origin + SIMD3<Float>(Float(i), Float(j), Float(k)) * g.spacing
                let t = len2 > 0 ? Swift.min(1, Swift.max(0, simd_dot(p - a, ab) / len2)) : 0
                let q = simd_length_squared(p - (a + ab * t))
                let n = (k * g.ny + j) * g.nx + i
                if q < d2[n] { d2[n] = q }
            } } }
        }
        return d2.map { Swift.min($0.squareRoot(), farMM) }
    }

    /// The nearest triangle of every voxel within `bandVoxels` of the surface (−1 beyond): the
    /// same scatter as LatticePreviewOccupancy.signedDistance, keeping the triangle's index.
    static func nearestTriangle(part m: ViewerMesh, like g: LatticeVoxelGrid, bandVoxels: Int) -> (d2: [Float], tri: [Int32]) {
        var d2 = [Float](repeating: .greatestFiniteMagnitude, count: g.count)
        var tri = [Int32](repeating: -1, count: g.count)
        let minSp = Swift.min(g.spacing.x, Swift.min(g.spacing.y, g.spacing.z))
        let pad = SIMD3<Float>(repeating: Float(bandVoxels) * minSp) / g.spacing
        let slabs = Swift.max(1, Swift.min(g.nz, ProcessInfo.processInfo.activeProcessorCount))
        let triCount = m.indices.count / 3
        d2.withUnsafeMutableBufferPointer { dbuf in
            tri.withUnsafeMutableBufferPointer { tbuf in
                DispatchQueue.concurrentPerform(iterations: slabs) { slab in
                    let kStart = g.nz * slab / slabs, kEnd = g.nz * (slab + 1) / slabs
                    guard kStart < kEnd else { return }
                    for t in 0..<triCount {
                        let (a, b, c) = triangle(m, t)
                        let lo = (simd_min(a, simd_min(b, c)) - g.origin) / g.spacing - pad
                        let hi = (simd_max(a, simd_max(b, c)) - g.origin) / g.spacing + pad
                        let k0 = Swift.max(kStart, Int(lo.z.rounded(.down))), k1 = Swift.min(kEnd - 1, Int(hi.z.rounded(.up)))
                        let i0 = Swift.max(0, Int(lo.x.rounded(.down))), i1 = Swift.min(g.nx - 1, Int(hi.x.rounded(.up)))
                        let j0 = Swift.max(0, Int(lo.y.rounded(.down))), j1 = Swift.min(g.ny - 1, Int(hi.y.rounded(.up)))
                        guard k0 <= k1, i0 <= i1, j0 <= j1 else { continue }
                        for k in k0...k1 { for j in j0...j1 { for i in i0...i1 {
                            let p = g.origin + SIMD3<Float>(Float(i), Float(j), Float(k)) * g.spacing
                            let q = LatticePreviewOccupancy.pointTriangleDistSq(p, a, b, c)
                            let n = (k * g.ny + j) * g.nx + i
                            if q < dbuf[n] { dbuf[n] = q; tbuf[n] = Int32(t) }
                        } } }
                    }
                }
            }
        }
        return (d2, tri)
    }
}
