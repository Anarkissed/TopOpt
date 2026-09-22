import Foundation
import simd

// ★★★ THE OUTLINE IS GEOMETRY, NOT A FIELD. His rule (2026-09-16, 00:19):
//
//   "I'd prefer the outline be a singular beam bent around the entirety of the
//    face-prism outline; something *inherently* smooth — not something with
//    definitive pixel sizes!"
//
// A closed beam of rectangular section — `widthMM` in-plane, the wall deep — swept
// around each include face's outline (the polygon offset in by `inPlaneOffsetMM`),
// built as triangles with position + normal interleaved (the depth-prepass vertex
// layout) and drawn as a mesh in the rim colour by `MetalMeshView`. The lattice's
// struts end inside it (the march clips them half a width in), so it reads as one
// separate frame holding the lattice and joining it to the body. Only when the shape
// grade is on: the bake hands out `solidBandMM` only then.
public enum LatticeOutlineRibbon {
    public struct Mesh: Equatable {
        /// 6 floats per vertex: position xyz, normal xyz — `FlatMesh.interleaved()`'s layout.
        public var interleaved: [Float] = []
        public var vertexCount: Int { interleaved.count / 6 }
        public var triangleCount: Int { vertexCount / 3 }
        public init(interleaved: [Float] = []) { self.interleaved = interleaved }
    }

    /// The loop's INWARD edge normals (unit), orientation-independent.
    static func edgeInwardNormals(_ loop: [SIMD2<Double>]) -> [SIMD2<Double>] {
        let m = loop.count
        var area = 0.0
        for i in 0..<m { let a = loop[i], b = loop[(i + 1) % m]; area += a.x * b.y - b.x * a.y }
        let ccw = area > 0
        return (0..<m).map { i in
            let e = loop[(i + 1) % m] - loop[i]
            let l = simd_length(e)
            guard l > 1e-9 else { return .zero }
            let left = SIMD2(-e.y, e.x) / l
            return ccw ? left : -left
        }
    }

    /// The loop offset INWARD by `d`, as a true parallel offset: each corner is the
    /// intersection of its two offset edges, and an edge the offset has eaten (its
    /// offset copy runs backwards) collapses to the corner its neighbours make — so
    /// the ring never crosses itself, whatever the corner angle or the segment
    /// lengths (his 25 mm beam overlapped itself at two acute corners, 2026-09-16).
    static func offsetRing(_ loop: [SIMD2<Double>], by d: Double, seams: [Bool] = []) -> [SIMD2<Double>] {
        let m = loop.count
        guard m >= 3 else { return loop }
        if abs(d) < 1e-9 { return loop }
        let n = edgeInwardNormals(loop)
        // Offset lines: point + direction per edge.
        var lineP: [SIMD2<Double>] = [], lineD: [SIMD2<Double>] = []
        for i in 0..<m {
            // ★ a seam edge is not offset: it is where the neighbouring prism continues
            lineP.append(loop[i] + n[i] * (i < seams.count && seams[i] ? 0 : d))
            lineD.append(loop[(i + 1) % m] - loop[i])
        }
        func meet(_ a: Int, _ b: Int) -> SIMD2<Double> {
            // intersection of offset lines a and b; the edge-normal offset when parallel
            let p1 = lineP[a], d1 = lineD[a], p2 = lineP[b], d2 = lineD[b]
            let cross = d1.x * d2.y - d1.y * d2.x
            if abs(cross) < 1e-9 * max(simd_length(d1) * simd_length(d2), 1e-9) { return p2 }
            let t = ((p2.x - p1.x) * d2.y - (p2.y - p1.y) * d2.x) / cross
            return p1 + d1 * t
        }
        // Which edges still stand: an edge whose offset copy runs backwards is eaten
        // — decided on the RAW intersections, so a swallowed tip segment is seen
        // for what it is even when the true corner lies far away.
        var alive = [Bool](repeating: true, count: m)
        var ring = [SIMD2<Double>](repeating: .zero, count: m)
        for _ in 0..<m {
            func prevLive(_ i: Int) -> Int? { for k in 1...m { let j = (i - k + m) % m; if alive[j] { return j } }; return nil }
            func nextLive(_ i: Int) -> Int? { for k in 0..<m { let j = (i + k) % m; if alive[j] { return j } }; return nil }
            var any = false
            for i in 0..<m {
                guard let a = prevLive(i), let b = nextLive(i) else { return loop }
                ring[i] = a == b ? lineP[b] : meet(a, b)
            }
            for i in 0..<m where alive[i] {
                let e = ring[(i + 1) % m] - ring[i]
                if simd_dot(e, lineD[i]) <= 1e-9 { alive[i] = false; any = true }
            }
            if !any { break }
        }
        // The true corner of the eroded polygon — however far from the vertex (a
        // 20° tip puts it 30 mm in). Where the polygon is thinner than twice the
        // offset that corner lies outside; the ring then takes the deepest point on
        // the way to it, so the beam fills the thin part and never leaves the outline.
        func inside(_ q: SIMD2<Double>) -> Double { -LatticeFaceOutline.signedDistance(q, loops: [loop]) }
        for i in 0..<m where inside(ring[i]) < abs(d) - 1e-6 {
            let v = loop[i], x = ring[i]
            var best = v, bestIn = inside(v)
            for k in 1...32 {
                let q = v + (x - v) * (Double(k) / 32)
                let ins = inside(q)
                if ins > bestIn { bestIn = ins; best = q }
            }
            ring[i] = best
        }
        return ring
    }

    /// `depthAt(regionIndex, point)` answers how deep the beam runs into the part at a
    /// point on the outline (the wall's thickness there); it is clamped to the
    /// region's depth.
    public static func build(regions: [LatticeRegionSpec], widthMM: Double,
                             depthAt: (Int, SIMD3<Double>) -> Double) -> Mesh {
        var mesh = Mesh()
        guard widthMM > 0 else { return mesh }
        var v: [Float] = []
        func emit(_ p: SIMD3<Double>, _ n: SIMD3<Double>) {
            v.append(Float(p.x)); v.append(Float(p.y)); v.append(Float(p.z))
            v.append(Float(n.x)); v.append(Float(n.y)); v.append(Float(n.z))
        }
        func quad(_ a: SIMD3<Double>, _ b: SIMD3<Double>, _ c: SIMD3<Double>, _ d: SIMD3<Double>,
                  _ na: SIMD3<Double>, _ nb: SIMD3<Double>, _ nc: SIMD3<Double>, _ nd: SIMD3<Double>) {
            emit(a, na); emit(b, nb); emit(c, nc)
            emit(a, na); emit(c, nc); emit(d, nd)
        }
        for (ri, region) in regions.enumerated()
        where region.role == .include && region.kind == .face && !region.outlineLoops.isEmpty {
            let n = LatticeRegionMask.unit(region.normal)
            guard simd_length(n) > 0.5, region.depthMM > 0 else { continue }
            let (bu, bv) = LatticeRegionMask.basis(n)
            func at(_ uv: SIMD2<Double>, _ s: Double) -> SIMD3<Double> {
                region.origin + bu * uv.x + bv * uv.y + n * s
            }
            func dir3(_ d: SIMD2<Double>) -> SIMD3<Double> {
                let w = bu * d.x + bv * d.y
                let l = simd_length(w)
                return l > 1e-9 ? w / l : bu
            }
            for (li, loop) in region.outlineLoops.enumerated() {
                let m = loop.count
                guard m >= 3 else { continue }
                let seams = li < region.outlineSeams.count ? region.outlineSeams[li] : []
                let outer = offsetRing(loop, by: region.inPlaneOffsetMM, seams: seams)
                let inner = offsetRing(loop, by: region.inPlaneOffsetMM + widthMM, seams: seams)
                // Per-vertex inward direction for the smooth wall normals: from the
                // outer ring to the inner one, or the edge normals' bisector where the
                // two rings meet.
                let en = edgeInwardNormals(loop)
                let miter: [SIMD2<Double>] = (0..<m).map { i in
                    let v = inner[i] - outer[i]
                    let l = simd_length(v)
                    if l > 1e-6 { return v / l }
                    let b = en[(i + m - 1) % m] + en[i]
                    let lb = simd_length(b)
                    return lb > 1e-6 ? b / lb : en[i]
                }
                let depth = (0..<m).map { i -> Double in
                    let mid = at((outer[i] + inner[i]) * 0.5, 1.0)
                    return Swift.max(0.5, Swift.min(region.depthMM, depthAt(ri, mid)))
                }
                let seamFaces = li < region.outlineSeamFaces.count ? region.outlineSeamFaces[li] : []
                for i in 0..<m {
                    // ★ no beam along a seam (his 2026-09-22: no rims between two prisms) —
                    // but where the seam is a CORNER between two latticed faces, a thin
                    // STABILITY PLATE at rim width runs from the shared edge inward along the
                    // bisector of the two walls, to the shallower wall's depth (his 2.2,
                    // "a 45 degree wall going into the middle of the shape … not there to
                    // break the flow"; "thin plate, rim width"). Emitted once, by the face
                    // with the smaller id.
                    if i < seams.count, seams[i] {
                        guard i < seamFaces.count, let other = seamFaces[i], let own = region.faceID,
                              other != own, own < other,
                              let nb = regions.first(where: { $0.role == .include && $0.kind == .face && $0.faceID == other })
                        else { continue }
                        let nB = LatticeRegionMask.unit(nb.normal)
                        let bis = n + nB
                        guard simd_length(bis) > 1e-6 else { continue }
                        let dir = simd_normalize(bis)
                        let j = (i + 1) % m
                        let p0 = at(loop[i], 0), p1 = at(loop[j], 0)
                        let along = p1 - p0
                        guard simd_length(along) > 1e-6 else { continue }
                        let side = simd_normalize(simd_cross(simd_normalize(along), dir))
                        let cosHalf = Swift.max(0.2, simd_dot(dir, n))
                        let length = Swift.min(region.depthMM, nb.depthMM) / cosHalf
                        let h = 0.5 * widthMM
                        let a0 = p0 - side * h, a1 = p1 - side * h, b0 = p0 + side * h, b1 = p1 + side * h
                        let a0d = a0 + dir * length, a1d = a1 + dir * length, b0d = b0 + dir * length, b1d = b1 + dir * length
                        quad(a0, a1, a1d, a0d, -side, -side, -side, -side)
                        quad(b0, b0d, b1d, b1, side, side, side, side)
                        quad(a0d, a1d, b1d, b0d, dir, dir, dir, dir)
                        quad(a0, b0, b1, a1, -dir, -dir, -dir, -dir)
                        let e = simd_normalize(along)
                        quad(a0, a0d, b0d, b0, -e, -e, -e, -e)
                        quad(a1, b1, b1d, a1d, e, e, e, e)
                        continue
                    }
                    let j = (i + 1) % m
                    let oi0 = at(outer[i], 0), oj0 = at(outer[j], 0)
                    let oi1 = at(outer[i], depth[i]), oj1 = at(outer[j], depth[j])
                    let ii0 = at(inner[i], 0), ij0 = at(inner[j], 0)
                    let ii1 = at(inner[i], depth[i]), ij1 = at(inner[j], depth[j])
                    // Smooth per-vertex normals along the sweep: the outer wall faces out
                    // of the prism, the inner wall faces the lattice.
                    let outI = -dir3(miter[i]), outJ = -dir3(miter[j])
                    quad(oi0, oj0, oj1, oi1, outI, outJ, outJ, outI)
                    quad(ii0, ii1, ij1, ij0, -outI, -outI, -outJ, -outJ)
                    // The face cap (the declared face looks along −n) and the far cap.
                    quad(oi0, ii0, ij0, oj0, -n, -n, -n, -n)
                    quad(oi1, oj1, ij1, ii1, n, n, n, n)
                }
            }
        }
        mesh.interleaved = v
        return mesh
    }
}
