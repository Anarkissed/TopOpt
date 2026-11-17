// PieceOutline.swift — ★ his 11-16 (Install 3), "Shouldn't the Outline view INCLUDE cuts and unions and patterns and such?",
// and his 11-17 "Start on the Outline view showing cuts and patterns": the Outlines view draws the faces the way the app
// sends them — every cut and every pattern line, and no line inside a union.
//
// ★ ONE RULE, THE TAP'S. A line is drawn exactly where the face a tap would pick changes (`EditedFaces.leaf`: the deepest cut
// piece holding the point, else the face's own region, resolved up to the union that took it; else the bare face) and
// nowhere else. The candidates are the part's own edges (`SurfaceWireframe`'s set) and every cut plane traced across the
// faces it cuts; each is split where another cut crosses it, and each piece of line is kept when its two sides pick
// different faces. So:
//   · a cut half a union took still has its line to the other half (the old set dropped every cut of a union's part);
//   · the part's own edge between a union's cut piece and its other face goes (the old set dropped only whole faces');
//   · a pattern line between two cells a union joined goes, and the rest of the grid stays;
//   · with no edits it is the part's own edges, unchanged.
//
// Pure geometry over value types — no Metal, no view.

import Foundation
import simd
import TopOptKit

public enum PieceOutline {

    /// RED CONTROL (tests): the old set — the part's edges less whole-face unions, plus `SurfaceCutLines.committed`.
    nonisolated(unsafe) public static var controlOld = false

    /// The Outlines view's line set (x, y, z per vertex, two vertices per segment, model space).
    public static func lines(regions: FaceRegionModel, in mesh: ViewerMesh) -> [Float] {
        if controlOld {
            return SurfaceWireframe.edges(of: mesh, welded: wholeFaceUnions(regions, mesh))
                + SurfaceCutLines.committed(regions: regions, in: mesh)
        }
        guard !mesh.indices.isEmpty, !mesh.faceIDs.isEmpty else { return [] }
        let look = Lookup(regions: regions, mesh: mesh)
        var out: [Float] = []
        edgeLines(mesh, look, into: &out)
        cutLines(mesh, look, into: &out)
        return out
    }

    /// The set for the mesh it was made on — the view draws it only over that mesh (a lattice variant or Flexible's dented
    /// part keeps the old set) — with one hash, so the view compares it without reading every number.
    public struct Drawing: Equatable {
        public let signature: ViewerMeshSignature
        public let lines: [Float]
        public let hash: Int
        init(signature: ViewerMeshSignature, lines: [Float]) {
            self.signature = signature
            self.lines = lines
            var h = Hasher()
            h.combine(lines.count)
            for f in lines { h.combine(f) }
            hash = h.finalize()
        }
        public static func == (a: Drawing, b: Drawing) -> Bool {
            a.signature == b.signature && a.hash == b.hash && a.lines == b.lines
        }
    }

    /// The set, worked out once per part and region state (the page asks on every body pass).
    @MainActor public static func drawing(regions: FaceRegionModel, in mesh: ViewerMesh) -> Drawing {
        if let c = cache, c.drawing.signature == mesh.signature, c.regions == regions, c.control == controlOld {
            return c.drawing
        }
        let d = Drawing(signature: mesh.signature, lines: lines(regions: regions, in: mesh))
        cache = (regions, controlOld, d)
        return d
    }
    @MainActor private static var cache: (regions: FaceRegionModel, control: Bool, drawing: Drawing)?

    // MARK: - what a tap picks

    /// `EditedFaces.leaf` with a point, worked out once per region state rather than once per question.
    struct Lookup {
        let regions: FaceRegionModel
        /// The regions holding each face, deepest first (`SurfaceTint.regionAt`'s order).
        private(set) var holders: [FaceID: [FaceRegion]] = [:]
        /// The distinct cut planes of the cut regions holding each face.
        private(set) var planes: [FaceID: [RegionCut]] = [:]
        private var top: [RegionID: RegionID] = [:]

        init(regions: FaceRegionModel, mesh: ViewerMesh) {
            self.regions = regions
            var depth: [RegionID: Int] = [:]
            for r in regions.regions {
                var d = 0, cur = r
                while let p = regions.region(cur.parentID) { d += 1; cur = p }
                depth[r.id] = d
            }
            var byFace: [FaceID: [FaceRegion]] = [:]
            for r in regions.regions {
                for f in FaceRegionGeometry.members(of: r, in: mesh) { byFace[f, default: []].append(r) }
            }
            for (f, hs) in byFace {
                holders[f] = hs.sorted { (depth[$0.id] ?? 0) > (depth[$1.id] ?? 0) }
                var seen: Set<String> = []
                var ps: [RegionCut] = []
                for r in hs where r.isCut {
                    for c in r.cuts where simd_length(c.normal) > 1e-12 {
                        if seen.insert(PieceOutline.key(c)).inserted { ps.append(c) }
                    }
                }
                if !ps.isEmpty { planes[f] = ps }
            }
            for r in regions.regions { top[r.id] = regions.outermostUnion(containing: r.id) }
        }

        /// What a tap at `p` on `face` picks.
        func pick(_ p: SIMD3<Double>, face: FaceID) -> EditedFace.ID {
            guard let hs = holders[face], !hs.isEmpty else { return .face(face) }
            var hit: RegionID?
            for r in hs where r.isCut && FaceRegionGeometry.inside(p, r.cuts) { hit = r.id; break }
            if hit == nil {
                hit = SurfaceTint.controlCutPieceFallback
                    ? (hs.first(where: { !$0.isCut })?.id ?? hs.first?.id)
                    : hs.first(where: { !$0.isCut })?.id
            }
            guard let piece = hit else { return .face(face) }
            return .region(top[piece] ?? regions.outermostUnion(containing: piece))
        }
    }

    // MARK: - the part's own edges

    /// `SurfaceWireframe.edges`' set (an edge two faces share, or a rim one triangle uses), each split where a cut crosses
    /// it and kept where its faces pick differently. A rim is always kept.
    static func edgeLines(_ mesh: ViewerMesh, _ look: Lookup, into out: inout [Float]) {
        func vkey(_ i: UInt32) -> SIMD3<Int64> {
            let b = Int(i) * 3
            return SIMD3<Int64>(Int64((mesh.positions[b] * 10_000).rounded()),
                                Int64((mesh.positions[b + 1] * 10_000).rounded()),
                                Int64((mesh.positions[b + 2] * 10_000).rounded()))
        }
        struct EdgeKey: Hashable {
            let lo: SIMD3<Int64>, hi: SIMD3<Int64>
            init(_ a: SIMD3<Int64>, _ b: SIMD3<Int64>) {
                let aFirst = (a.x, a.y, a.z) <= (b.x, b.y, b.z)
                lo = aFirst ? a : b; hi = aFirst ? b : a
            }
        }
        struct Seen { var faces: Set<Int32> = []; var uses = 0; var a: UInt32 = 0; var b: UInt32 = 0 }
        var seen: [EdgeKey: Seen] = [:]
        var order: [EdgeKey] = []
        var t = 0
        while t + 2 < mesh.indices.count {
            let tri = t / 3
            let owner: Int32 = tri < mesh.faceIDs.count ? mesh.faceIDs[tri] : -1
            let v = (mesh.indices[t], mesh.indices[t + 1], mesh.indices[t + 2])
            for (x, y) in [(v.0, v.1), (v.1, v.2), (v.2, v.0)] {
                let k = EdgeKey(vkey(x), vkey(y))
                if seen[k] == nil { seen[k] = Seen(a: x, b: y); order.append(k) }
                seen[k]!.faces.insert(owner)
                seen[k]!.uses += 1
            }
            t += 3
        }
        for k in order {
            guard let e = seen[k], e.faces.count > 1 || e.uses == 1 else { continue }
            let a = point(e.a, mesh), b = point(e.b, mesh)
            guard e.faces.count > 1 else { push(a, b, &out); continue }
            let faces = e.faces.sorted()
            var cuts: [RegionCut] = []
            var keys: Set<String> = []
            for f in faces { for c in look.planes[f] ?? [] where keys.insert(PieceOutline.key(c)).inserted { cuts.append(c) } }
            for (s, u) in pieces(a, b, crossing: cuts) {
                let mid = (s + u) * 0.5
                let picks = Set(faces.map { look.pick(mid, face: $0) })
                if picks.count > 1 { push(s, u, &out) }
            }
        }
    }

    // MARK: - the cuts

    /// Every cut plane traced across each face it cuts, split where another of that face's cuts crosses it, kept where the
    /// two sides of the line pick differently.
    static func cutLines(_ mesh: ViewerMesh, _ look: Lookup, into out: inout [Float]) {
        guard !look.planes.isEmpty else { return }
        var tris: [FaceID: [Int]] = [:]
        let n = min(mesh.indices.count / 3, mesh.faceIDs.count)
        for t in 0..<n where look.planes[mesh.faceIDs[t]] != nil { tris[mesh.faceIDs[t], default: []].append(t) }
        let b = mesh.bounds
        let diag = Double(simd_length(SIMD3<Float>(b.max.x - b.min.x, b.max.y - b.min.y, b.max.z - b.min.z)))
        let eps = max(diag * 1e-5, 1e-6)
        for (f, ps) in look.planes {
            for plane in ps {
                let nrm = simd_normalize(plane.normal)
                let k = key(plane)
                let others = ps.filter { key($0) != k }
                for t in tris[f] ?? [] {
                    guard let seg = crossing(plane: plane, triangle: t, mesh) else { continue }
                    for (s, u) in pieces(seg.0, seg.1, crossing: others) {
                        let mid = (s + u) * 0.5
                        if look.pick(mid + nrm * eps, face: f) != look.pick(mid - nrm * eps, face: f) { push(s, u, &out) }
                    }
                }
            }
        }
    }

    /// Where `plane` crosses triangle `t` (`SurfaceCutLines.trace`'s rule: two edge crossings, a touch at a corner is not a
    /// line).
    static func crossing(plane: RegionCut, triangle t: Int, _ mesh: ViewerMesh) -> (SIMD3<Double>, SIMD3<Double>)? {
        let nrm = simd_normalize(plane.normal)
        var p: [SIMD3<Double>] = [], d: [Double] = []
        for k in 0..<3 {
            let v = point(mesh.indices[t * 3 + k], mesh)
            p.append(v); d.append(simd_dot(v - plane.point, nrm))
        }
        var hits: [SIMD3<Double>] = []
        for e in 0..<3 {
            let a = e, c = (e + 1) % 3
            guard (d[a] < 0) != (d[c] < 0) else { continue }
            let denom = d[a] - d[c]
            guard abs(denom) > 1e-15 else { continue }
            hits.append(p[a] + (p[c] - p[a]) * (d[a] / denom))
        }
        guard hits.count >= 2, simd_length(hits[1] - hits[0]) > 1e-9 else { return nil }
        return (hits[0], hits[1])
    }

    /// The segment a→b cut where each plane crosses it.
    static func pieces(_ a: SIMD3<Double>, _ b: SIMD3<Double>, crossing cuts: [RegionCut])
        -> [(SIMD3<Double>, SIMD3<Double>)] {
        var ts: [Double] = []
        for c in cuts {
            let nrm = simd_normalize(c.normal)
            let da = simd_dot(a - c.point, nrm), db = simd_dot(b - c.point, nrm)
            guard (da < 0) != (db < 0), abs(da - db) > 1e-15 else { continue }
            let t = da / (da - db)
            if t > 1e-9, t < 1 - 1e-9 { ts.append(t) }
        }
        guard !ts.isEmpty else { return [(a, b)] }
        ts.sort()
        var out: [(SIMD3<Double>, SIMD3<Double>)] = []
        var lo = 0.0
        for t in ts + [1] where t - lo > 1e-9 {
            out.append((a + (b - a) * lo, a + (b - a) * t))
            lo = t
        }
        return out
    }

    // MARK: - small things

    /// One plane, whichever way it faces (a cut's two halves carry it with opposite normals).
    static func key(_ c: RegionCut) -> String {
        var n = simd_normalize(c.normal)
        if n.x + n.y + n.z < 0 || (n.x + n.y + n.z == 0 && (n.x < 0 || (n.x == 0 && n.y < 0))) { n = -n }
        return String(format: "%.5f,%.5f,%.5f,%.4f", n.x, n.y, n.z, simd_dot(c.point, n))
    }

    static func point(_ i: UInt32, _ mesh: ViewerMesh) -> SIMD3<Double> {
        SIMD3<Double>(FaceRegionGeometry.position(i, mesh))
    }

    static func push(_ a: SIMD3<Double>, _ b: SIMD3<Double>, _ out: inout [Float]) {
        out += [Float(a.x), Float(a.y), Float(a.z), Float(b.x), Float(b.y), Float(b.z)]
    }

    /// The old set's welded faces (`ProjectModel.surfaceWeldedFaces`): a region with two or more whole faces.
    static func wholeFaceUnions(_ regions: FaceRegionModel, _ mesh: ViewerMesh) -> [Set<FaceID>] {
        var out: [Set<FaceID>] = []
        for r in regions.regions {
            var faces: Set<FaceID> = []
            for leaf in regions.resolvedLeaves(r.id) {
                guard let part = regions.region(leaf), !part.isCut else { continue }
                faces.formUnion(FaceRegionGeometry.members(of: part, in: mesh))
            }
            if faces.count >= 2 { out.append(faces) }
        }
        return out
    }
}
