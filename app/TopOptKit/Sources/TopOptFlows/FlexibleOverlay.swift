// FlexibleOverlay — the squish map drawn ON THE PART (task 2026-09-29-flexible-screens S2,
// M11: "3D view with an overlay on the actual part").
//
// ★ WHAT IS DRAWN, AND FROM WHERE. One small quad per stack COLUMN, centred where core's
// column ray enters the face (from_uv(u, v) + load × entry_t), in the frame's own X / Y
// directions, one column pitch wide — so the map sits on the face exactly where core's
// columns are. Its colour is a per-column number core returned (drawn squish, buildable
// squish, a stamp's dent). Nothing here computes a squish.
//
// ★ THE DENT (02 §6): "u(z) = depth · (z − z_bottom) / h" through the lattice height —
// the face moves the full depth, the far end not at all. Applied (exaggerated, labelled)
// to the column quads AND to the part's own vertices inside the stack, using core's
// column entry/exit along the load; the renderer scales it (`flexScale`).
//
// The part and the quads are ONE mesh so taps on the map pick the face under it.

import Foundation
import simd
import TopOptDesign
import TopOptKit

public struct FlexibleOverlayFace {
    public let key: FlexFaceKey
    /// The part faces the region covers, and its cuts (a split sector); the map replaces
    /// exactly the part of those faces on the sector's side of every cut (FlexibleFacePieces).
    public let faces: Set<Int>
    public let cuts: [RegionCut]
    public let stack: FlexStackInfo
    /// Core's from_uv at every column centre (u_mm, v_mm), in column order.
    public let centres: [SIMD3<Double>]
}

public struct FlexibleOverlayMesh {
    public let mesh: ViewerMesh
    public let partFlatVertices: Int
    /// Per kept part triangle: its SOURCE triangle in the part (a triangle a sector cut
    /// crosses is kept as its pieces outside the pressed sectors, so a source can repeat).
    /// A loaded region's own part is replaced by its column quads, so the dent is not
    /// hidden under the undented face.
    public let keptTriangles: [Int]
    /// Per face: the first FLAT vertex of its quads (6 flat vertices per column).
    public let flatStart: [FlexFaceKey: Int]
    /// Per kept part triangle: its face id and centroid (per-sector tinting — exact, since
    /// every piece lies on one side of every sector cut).
    public let keptFace: [Int]
    public let keptCentroid: [SIMD3<Double>]
    /// Per kept FLAT vertex: its barycentric weights in its source triangle
    /// (`keptTriangles[v / 3]`). The dent's uvt is interpolated from them; core's to_uv + t
    /// is affine, so the interpolation is exact (FlexibleOverlayClipTests).
    public let keptWeights: [SIMD3<Double>]

    /// The part's own mesh (minus the pressed regions) plus one quad per column of every face.
    ///
    /// ★ ROUND 3, ITEM 2 — THE HOLE. A triangle of a face with sectors is CUT along the
    /// sectors' planes (`splitPlanes`, plus every pressed region's own cuts) before anything
    /// is dropped; only the pieces inside a pressed region go. So the part's own surface runs
    /// right up to the map along the cut, and never under it.
    public static func build(part: ViewerMesh, faces: [FlexibleOverlayFace],
                             splitPlanes: [Int: [RegionCut]] = [:]) -> FlexibleOverlayMesh {
        var pos = part.positions
        var idx: [Int32] = []
        var fid: [Int32] = []
        var kept: [Int] = []
        var keptFace: [Int] = [], keptCentroid: [SIMD3<Double>] = [], weights: [SIMD3<Double>] = []
        var planes = splitPlanes
        for f in faces where !f.cuts.isEmpty {
            for face in f.faces { for c in f.cuts { FlexibleFacePieces.add(c, to: &planes[face, default: []]) } }
        }
        let pfid = part.faceIDs
        func vtx(_ i: UInt32) -> SIMD3<Double> {
            let b = Int(i) * 3
            return SIMD3(Double(part.positions[b]), Double(part.positions[b + 1]), Double(part.positions[b + 2]))
        }
        let identity = [SIMD3<Double>(1, 0, 0), SIMD3(0, 1, 0), SIMD3(0, 0, 1)]
        for t in 0..<part.triangleCount {
            let f = t < pfid.count ? Int(pfid[t]) : -1
            let pressed = faces.filter { $0.faces.contains(f) }
            // a whole face pressed: its map replaces all of it
            if pressed.contains(where: { $0.cuts.isEmpty }) { continue }
            let i0 = part.indices[3 * t], i1 = part.indices[3 * t + 1], i2 = part.indices[3 * t + 2]
            let a = vtx(i0), b = vtx(i1), c = vtx(i2)
            let facePlanes = planes[f] ?? []
            guard !facePlanes.isEmpty else {
                // no sector on this face: the triangle as it is
                kept.append(t); keptFace.append(f); keptCentroid.append((a + b + c) / 3)
                weights += identity
                idx += [Int32(i0), Int32(i1), Int32(i2)]
                fid.append(Int32(f))
                continue
            }
            for piece in FlexibleFacePieces.pieces(a, b, c, planes: facePlanes) {
                // replaced by a pressed sector's map: this piece is on its side of every cut
                if pressed.contains(where: { FaceRegionGeometry.inside(piece.centroid, $0.cuts) }) { continue }
                if piece.whole {
                    kept.append(t); keptFace.append(f); keptCentroid.append(piece.centroid)
                    weights += identity
                    idx += [Int32(i0), Int32(i1), Int32(i2)]
                    fid.append(Int32(f))
                    continue
                }
                let base = Int32(pos.count / 3)
                for p in piece.points { pos += [Float(p.x), Float(p.y), Float(p.z)] }
                for (x, y, z) in FlexibleFacePieces.fan(piece.points.count) {
                    kept.append(t); keptFace.append(f)
                    keptCentroid.append((piece.points[x] + piece.points[y] + piece.points[z]) / 3)
                    weights += [piece.weights[x], piece.weights[y], piece.weights[z]]
                    idx += [base + Int32(x), base + Int32(y), base + Int32(z)]
                    fid.append(Int32(f))
                }
            }
        }
        var flatStart: [FlexFaceKey: Int] = [:]
        var tri = kept.count
        for f in faces {
            flatStart[f.key] = tri * 3
            let st = f.stack
            let x = st.xAxis * (st.pitchMM / 2), y = st.yAxis * (st.pitchMM / 2)
            let lift = -st.load * 0.05
            for (k, c) in st.columns.enumerated() {
                let p = f.centres[k] + st.load * c.entryT + lift
                let base = Int32(pos.count / 3)
                for q in [p - x - y, p + x - y, p + x + y, p - x + y] {
                    pos += [Float(q.x), Float(q.y), Float(q.z)]
                }
                // wound so the quad faces out of the part (along −load)
                idx += [base, base + 2, base + 1, base, base + 3, base + 2]
                let face = Int32(f.faces.min() ?? -1)
                fid += [face, face]
                tri += 2
            }
        }
        let mesh = ViewerMesh(vertices: pos, indices: idx, faceIDs: fid,
                              faceGeometry: part.faceGeometry, pseudoFaces: part.pseudoFaces)
        return FlexibleOverlayMesh(mesh: mesh, partFlatVertices: kept.count * 3, keptTriangles: kept,
                                   flatStart: flatStart, keptFace: keptFace, keptCentroid: keptCentroid,
                                   keptWeights: weights)
    }

    // MARK: colour

    /// Part triangles tinted per triangle (`partTint(face, centroid)`, nil = clay), and one
    /// RGBA per column of each loaded region's map.
    /// ★ X-RAY (maintainer, 2026-09-29: "more ghostly … with the bent plane showing the
    /// dent"): with `ghost` set, every vertex that is not the opaque map is flagged
    /// flags.z = 1 and drawn by MetalMeshView as a ghost — faint face-on, lit at the
    /// silhouette — in its own tint, or in `ghost` where it had none.
    public func tints(partTint: (Int, SIMD3<Double>) -> SIMD4<Float>?,
                      columnColours: [FlexFaceKey: [SIMD4<Float>]],
                      ghost: SIMD4<Float>? = nil) -> [Float] {
        let n = mesh.flat.vertexCount
        var out = [Float](repeating: 0, count: n * 8)
        for t in 0..<keptFace.count {
            guard let c = partTint(keptFace[t], keptCentroid[t]) else { continue }
            for j in 0..<3 {
                let v = t * 3 + j
                out[v * 8] = c.x; out[v * 8 + 1] = c.y; out[v * 8 + 2] = c.z; out[v * 8 + 3] = c.w
            }
        }
        for (k, start) in flatStart {
            guard let cols = columnColours[k] else { continue }
            for (c, col) in cols.enumerated() {
                for j in 0..<6 {
                    let v = start + c * 6 + j
                    guard v < n else { break }
                    out[v * 8] = col.x; out[v * 8 + 1] = col.y; out[v * 8 + 2] = col.z; out[v * 8 + 3] = col.w
                    // flags.y: the map stays fully opaque when the body is drawn see-through
                    if col.w > 0 { out[v * 8 + 5] = 1 }
                }
            }
        }
        if let g = ghost { Self.markGhost(&out, colour: g) }
        return out
    }

    /// flags.z = 1 on every vertex that is not flagged opaque (flags.y); clay takes `colour`.
    public static func markGhost(_ out: inout [Float], colour g: SIMD4<Float>) {
        for v in 0..<(out.count / 8) where out[v * 8 + 5] < 0.5 {
            out[v * 8 + 6] = 1
            if out[v * 8 + 3] <= 0 {
                out[v * 8] = g.x; out[v * 8 + 1] = g.y; out[v * 8 + 2] = g.z; out[v * 8 + 3] = g.w
            }
        }
    }

    // MARK: the dent (02 §6)

    /// Per-flat-vertex displacement (mm, before the renderer's exaggeration).
    /// `depth[k]` per column (nil / ≤ 0 ⇒ that column does not move); `partUVT` is
    /// core's to_uv + t for every part flat vertex, per face.
    /// `joinRegions` (default on; off only as a test's red control): a quad corner that two
    /// loaded regions share — the two sectors of a split face — takes the mean over BOTH
    /// regions' columns, so their maps meet along the cut instead of stepping apart.
    public func displacements(depths: [FlexFaceKey: [Double?]], stacks: [FlexFaceKey: FlexStackInfo],
                              partUVT: [FlexFaceKey: [Double]], joinRegions: Bool = true) -> [Float] {
        let n = mesh.flat.vertexCount
        var out = [Float](repeating: 0, count: n * 3)
        let shared = joinRegions ? SharedCorners(self, depths: depths, stacks: stacks) : nil
        for (k, d) in depths {
            guard let st = stacks[k] else { continue }
            let l = st.load
            // the column quads: the full depth, each CORNER the mean of the columns that
            // share it, so neighbouring quads stay joined and the dented surface is closed
            if let start = flatStart[k] {
                func depth(_ iu: Int, _ iv: Int) -> Double? {
                    let c = st.column(iu, iv)
                    guard c >= 0, c < d.count else { return nil }
                    return d[c]
                }
                // `flat`: one flat vertex AT this corner (its place, for the other regions)
                func corner(_ cu: Int, _ cv: Int, flat v: Int) -> Double {
                    var sum = 0.0, n = 0
                    for (du, dv) in [(-1, -1), (0, -1), (-1, 0), (0, 0)] {
                        if let x = depth(cu + du, cv + dv) { sum += x; n += 1 }
                    }
                    // ★ ACROSS THE CUT: the other loaded regions' columns at this very corner
                    // (same place, same load) — the sectors of a split face stay joined
                    if let shared {
                        for x in shared.depths(at: v, load: l, except: k) { sum += x; n += 1 }
                    }
                    return n > 0 ? sum / Double(n) : 0
                }
                // the quad's corners in build order, then its six flat vertices
                let order = [0, 2, 1, 0, 3, 2]
                for (c, col) in st.columns.enumerated() where c < d.count {
                    let q = start + c * 6
                    let cs = [corner(col.iu, col.iv, flat: q + Self.flatOfCorner[0]),
                              corner(col.iu + 1, col.iv, flat: q + Self.flatOfCorner[1]),
                              corner(col.iu + 1, col.iv + 1, flat: q + Self.flatOfCorner[2]),
                              corner(col.iu, col.iv + 1, flat: q + Self.flatOfCorner[3])]
                    for j in 0..<6 {
                        let v = start + c * 6 + j, dd = cs[order[j]]
                        guard v < n, dd > 0 else { continue }
                        out[v * 3] += Float(l.x * dd); out[v * 3 + 1] += Float(l.y * dd); out[v * 3 + 2] += Float(l.z * dd)
                    }
                }
            }
            // the part: the linear ramp from the face (full) to the far end (none)
            guard let uvt = partUVT[k], st.pitchMM > 0 else { continue }
            for v in 0..<partFlatVertices {
                // ★ its source triangle's corners in the ORIGINAL part's flat buffer (the uvt
                // order), weighted by where this vertex sits in it (a clipped piece's corner
                // lies inside its source; an uncut triangle's weights are the identity)
                let src = keptTriangles[v / 3] * 3
                guard 3 * (src + 2) + 2 < uvt.count, v < keptWeights.count else { continue }
                let wv = keptWeights[v]
                var u = 0.0, w = 0.0, t = 0.0
                for j in 0..<3 where wv[j] != 0 {
                    u += wv[j] * uvt[3 * (src + j)]; w += wv[j] * uvt[3 * (src + j) + 1]; t += wv[j] * uvt[3 * (src + j) + 2]
                }
                let iu = Int((u / st.pitchMM).rounded(.down)), iv = Int((w / st.pitchMM).rounded(.down))
                let iuC = min(max(iu, 0), st.nu - 1), ivC = min(max(iv, 0), st.nv - 1)
                // a vertex on the face's own edge sits half a pitch outside the last column
                guard abs(iu - iuC) <= 1, abs(iv - ivC) <= 1, st.nu > 0, st.nv > 0 else { continue }
                let col = st.cell[ivC * st.nu + iuC]
                guard col >= 0, col < d.count, let dd = d[col], dd > 0 else { continue }
                let c = st.columns[col]
                let span = c.exitT - c.entryT
                guard span > 1e-6, t >= c.entryT - 0.5 * st.pitchMM, t <= c.exitT + 0.5 * st.pitchMM else { continue }
                let r = max(0, min(1, (c.exitT - t) / span))
                out[v * 3] += Float(l.x * dd * r); out[v * 3 + 1] += Float(l.y * dd * r); out[v * 3 + 2] += Float(l.z * dd * r)
            }
        }
        return out
    }

    /// Corner i (build order: (iu, iv), (iu+1, iv), (iu+1, iv+1), (iu, iv+1)) of a column
    /// quad is its flat vertex `flatOfCorner[i]` (the quad's flat order is [0, 2, 1, 0, 3, 2]).
    static let flatOfCorner = [0, 2, 1, 4]

    /// Every loaded region's column-quad corners, by PLACE: what a corner of one region
    /// finds of the others at the same point. Places are hashed on a 0.01 mm grid (and its
    /// neighbours, so a point on a cell's boundary is not lost), matched within 0.005 mm;
    /// only regions pressing along the SAME load join (a corner shared by two faces of an
    /// edge moves along two directions, and averaging them would close nothing).
    struct SharedCorners {
        struct Entry { let key: FlexFaceKey; let load: SIMD3<Double>; let depth: Double; let p: SIMD3<Float> }
        private var byCell: [SIMD3<Int32>: [Entry]] = [:]
        private let positions: [Float]
        static let cellMM: Float = 0.01

        init(_ o: FlexibleOverlayMesh, depths: [FlexFaceKey: [Double?]], stacks: [FlexFaceKey: FlexStackInfo]) {
            positions = o.mesh.flat.positions
            guard depths.count > 1 else { return }   // one region: nothing to join
            for (k, d) in depths {
                guard let st = stacks[k], let start = o.flatStart[k] else { continue }
                for c in st.columns.indices where c < d.count {
                    guard let x = d[c] else { continue }
                    for j in FlexibleOverlayMesh.flatOfCorner {
                        let p = Self.place(positions, start + c * 6 + j)
                        byCell[Self.cell(p), default: []].append(Entry(key: k, load: st.load, depth: x, p: p))
                    }
                }
            }
        }

        static func place(_ pos: [Float], _ v: Int) -> SIMD3<Float> {
            guard 3 * v + 2 < pos.count else { return SIMD3(repeating: .nan) }
            return SIMD3(pos[3 * v], pos[3 * v + 1], pos[3 * v + 2])
        }
        static func cell(_ p: SIMD3<Float>) -> SIMD3<Int32> {
            guard p.x.isFinite, p.y.isFinite, p.z.isFinite else { return SIMD3(repeating: Int32.min) }
            return SIMD3<Int32>(p / cellMM, rounding: .toNearestOrEven)
        }

        /// The depths of the OTHER regions' columns whose quads have a corner at flat vertex
        /// `v`'s place, pressing along `load`.
        func depths(at v: Int, load: SIMD3<Double>, except k: FlexFaceKey) -> [Double] {
            guard !byCell.isEmpty else { return [] }
            let p = Self.place(positions, v)
            let c = Self.cell(p)
            guard c.x != Int32.min else { return [] }
            var out: [Double] = []
            for dz in -1...1 { for dy in -1...1 { for dx in -1...1 {
                for e in byCell[c &+ SIMD3(Int32(dx), Int32(dy), Int32(dz))] ?? []
                where e.key != k && simd_distance(e.p, p) <= 0.5 * Self.cellMM && simd_dot(e.load, load) > 0.999 {
                    out.append(e.depth)
                }
            } } }
            return out
        }
    }
}

/// Colours for the overlay: the depth ramp and the flags, all from DS tokens. Never purple.
@MainActor
public enum FlexibleColours {
    public static func depth(_ mm: Double, max: Double) -> SIMD4<Float> {
        let c = depthColour(fraction: max > 0 ? mm / max : 0)
        return SIMD4(Float(c.r), Float(c.g), Float(c.b), 0.95)
    }
    /// ★ ROUND 3 (his answers): THE DENT'S OWN RAMP, from DS tokens — "make it deep blue →
    /// cyan → white" (2026-09-30): accentDeep (no squish) → accentCyan → textPrimary (the
    /// deepest). One hue family, brighter = deeper, so it can never be read as the Stress
    /// rainbow the main page shows beside it (ResultsModel.stressColor keeps that one) — and
    /// never purple. FlexibleShownValuesTests pins both. The map AND its legend read it.
    public static let depthStops: [RGBA] = [
        DS.Color.accentDeep,
        DS.Color.accentCyan,
        DS.Color.textPrimary,
    ]
    public static func depthColour(fraction f: Double) -> RGBA {
        let x = min(1, max(0, f.isFinite ? f : 0)) * Double(depthStops.count - 1)
        let i = min(depthStops.count - 2, Int(x)), t = x - Double(i)
        return mix(depthStops[i], depthStops[i + 1], t)
    }
    /// a + (b − a)·t, per channel (two DS tokens blended).
    static func mix(_ a: RGBA, _ b: RGBA, _ t: Double) -> RGBA {
        RGBA((a.r + (b.r - a.r) * t) * 255, (a.g + (b.g - a.g) * t) * 255, (a.b + (b.b - a.b) * t) * 255)
    }
    public static func token(_ c: RGBA, _ a: Float) -> SIMD4<Float> {
        SIMD4(Float(c.r), Float(c.g), Float(c.b), a)
    }
    /// A column core could not give a number for (past the data / solid).
    public static let noNumber = token(DS.Color.textQuaternary, 0.9)
    public static let refused = token(DS.Color.danger, 0.9)
    public static let loadedFace = token(DS.Color.accentGreen, 0.35)
    /// ★ Not the map's green (verification of round 3): the on-part colour, like the curves.
    public static let selectedFace = token(DS.Color.textPrimary, 0.45)
    public static let linkedEnd = token(DS.Color.accentCyan, 0.45)
    public static let conflict = token(DS.Color.warning, 0.6)
    public static let restingFace = token(DS.Color.accentCyan, 0.25)
    /// The X-ray ghost's glow (the body's clay under X-ray).
    /// ★ Neutral white, not cyan: the dent ramp runs blue → cyan → white (2026-09-30), and a
    /// cyan ghost would read as part of the map.
    public static let ghost = token(DS.Color.textPrimary, 1)
}
