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
    public let face: Int            // B-rep / pseudo face id (region − regionBase)
    public let stack: FlexStackInfo
    /// Core's from_uv at every column centre (u_mm, v_mm), in column order.
    public let centres: [SIMD3<Double>]
}

public struct FlexibleOverlayMesh {
    public let mesh: ViewerMesh
    public let partFlatVertices: Int
    /// The part triangles kept, in order (a loaded face's own triangles are replaced by
    /// its column quads, so the dent is not hidden under the undented face).
    public let keptTriangles: [Int]
    /// Per face: the first FLAT vertex of its quads (6 flat vertices per column).
    public let flatStart: [FlexFaceKey: Int]

    /// The part's own mesh (minus the loaded faces) plus one quad per column of every face.
    public static func build(part: ViewerMesh, faces: [FlexibleOverlayFace]) -> FlexibleOverlayMesh {
        let replaced = Set(faces.map { Int32($0.face) })
        var pos = part.positions
        var idx: [Int32] = []
        var fid: [Int32] = []
        var kept: [Int] = []
        let pfid = part.faceIDs
        for t in 0..<part.triangleCount {
            let f = t < pfid.count ? pfid[t] : -1
            if replaced.contains(f) { continue }
            kept.append(t)
            idx += [Int32(part.indices[3 * t]), Int32(part.indices[3 * t + 1]), Int32(part.indices[3 * t + 2])]
            fid.append(f)
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
                fid += [Int32(f.face), Int32(f.face)]
                tri += 2
            }
        }
        let mesh = ViewerMesh(vertices: pos, indices: idx, faceIDs: fid,
                              faceGeometry: part.faceGeometry, pseudoFaces: part.pseudoFaces)
        return FlexibleOverlayMesh(mesh: mesh, partFlatVertices: kept.count * 3, keptTriangles: kept,
                                   flatStart: flatStart)
    }

    // MARK: colour

    /// One RGBA per column (nil ⇒ leave the quad uncoloured, i.e. hidden in clay).
    public func tints(partFaceTints: [Int: SIMD4<Float>],
                      columnColours: [FlexFaceKey: [SIMD4<Float>]]) -> [Float] {
        let n = mesh.flat.vertexCount
        var out = [Float](repeating: 0, count: n * 8)
        let ids = mesh.faceIDs
        for v in 0..<partFlatVertices {
            let t = v / 3
            guard t < ids.count, let c = partFaceTints[Int(ids[t])] else { continue }
            out[v * 8] = c.x; out[v * 8 + 1] = c.y; out[v * 8 + 2] = c.z; out[v * 8 + 3] = c.w
        }
        for (k, start) in flatStart {
            guard let cols = columnColours[k] else { continue }
            for (c, col) in cols.enumerated() {
                for j in 0..<6 {
                    let v = start + c * 6 + j
                    guard v < n else { break }
                    out[v * 8] = col.x; out[v * 8 + 1] = col.y; out[v * 8 + 2] = col.z; out[v * 8 + 3] = col.w
                }
            }
        }
        return out
    }

    // MARK: the dent (02 §6)

    /// Per-flat-vertex displacement (mm, before the renderer's exaggeration).
    /// `depth[k]` per column (nil / ≤ 0 ⇒ that column does not move); `partUVT` is
    /// core's to_uv + t for every part flat vertex, per face.
    public func displacements(depths: [FlexFaceKey: [Double?]], stacks: [FlexFaceKey: FlexStackInfo],
                              partUVT: [FlexFaceKey: [Double]]) -> [Float] {
        let n = mesh.flat.vertexCount
        var out = [Float](repeating: 0, count: n * 3)
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
                func corner(_ cu: Int, _ cv: Int) -> Double {
                    var sum = 0.0, n = 0
                    for (du, dv) in [(-1, -1), (0, -1), (-1, 0), (0, 0)] {
                        if let x = depth(cu + du, cv + dv) { sum += x; n += 1 }
                    }
                    return n > 0 ? sum / Double(n) : 0
                }
                // the quad's corners in build order, then its six flat vertices
                let order = [0, 2, 1, 0, 3, 2]
                for (c, col) in st.columns.enumerated() where c < d.count {
                    let cs = [corner(col.iu, col.iv), corner(col.iu + 1, col.iv),
                              corner(col.iu + 1, col.iv + 1), corner(col.iu, col.iv + 1)]
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
                // this flat vertex's place in the ORIGINAL part's flat buffer (the uvt order)
                let o = keptTriangles[v / 3] * 3 + v % 3
                guard 3 * o + 2 < uvt.count else { continue }
                let u = uvt[3 * o], w = uvt[3 * o + 1], t = uvt[3 * o + 2]
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
}

/// Colours for the overlay: the app's existing heat ramp (ResultsModel.stressColor) for
/// depth, DS tokens for the flags. No new colours.
@MainActor
public enum FlexibleColours {
    public static func depth(_ mm: Double, max: Double) -> SIMD4<Float> {
        let c = ResultsModel.stressColor(fraction: max > 0 ? mm / max : 0)
        return SIMD4(Float(c.r), Float(c.g), Float(c.b), 0.95)
    }
    public static func token(_ c: RGBA, _ a: Float) -> SIMD4<Float> {
        SIMD4(Float(c.r), Float(c.g), Float(c.b), a)
    }
    /// A column core could not give a number for (past the data / solid).
    public static let noNumber = token(DS.Color.textQuaternary, 0.9)
    public static let refused = token(DS.Color.danger, 0.9)
    public static let loadedFace = token(DS.Color.accentGreen, 0.35)
    public static let selectedFace = token(DS.Color.accentGreen, 0.6)
    public static let linkedEnd = token(DS.Color.accentCyan, 0.45)
    public static let conflict = token(DS.Color.warning, 0.6)
    public static let restingFace = token(DS.Color.accentCyan, 0.25)
}
