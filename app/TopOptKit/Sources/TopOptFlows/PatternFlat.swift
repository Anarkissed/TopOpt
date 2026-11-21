// PatternFlat.swift — B8 (row 37; "On a flat face, the grid sits square to the face's own edges"; the reviewer's 11-09 18:31Z
// ruling (b): "starting square to the longest edge", Rotate in 15° steps): THE PATTERN ON A FLAT FACE.
//
// ★ WHY. Every face went through the grid's spine walk (`SurfacePatternAxis.grid`), which follows the triangle graph's longest
// path and never reads the frame: on a flat plate that path runs corner to corner, so the grid lay on a diagonal — square to
// no edge — and the turn disc moved nothing unless the walk declined. A flat face needs no walk: its lines are straight.
//
//   • n ALONG: lines square to the frame's u (the face's longest straight edge, turned by Rotate), spaced along it.
//   • n ACROSS: lines square to its v.
//   • Each line sits where the piece's OWN AREA divides evenly (on a rectangle, even spacing; on any other outline, no end
//     piece is left a sliver — §7's equal-area rule, `SurfacePatternAxis.areaCells`).
//   • Inside a piece already cut (`within`), the lines divide that piece.
// Each cell is the frame's half-spaces only (`FaceRegionGeometry.GridCell`); `drawn` names each divider once (by the cell past it).
// Pure geometry over value types: no view, no camera.

import Foundation
import simd

public enum PatternFlat {

    /// ★ THE STRAIGHT GRID: `columns` × `rows` pieces of the flat face's piece, in `frame` (already turned).
    public static func cells(face: FaceID, frame: FaceRegionGeometry.Frame, columns: Int, rows: Int,
                             in mesh: ViewerMesh, within: [RegionCut] = [])
        -> Result<[FaceRegionGeometry.GridCell], SurfacePatternArc.Refusal> {
        guard frame.valid, columns >= 1, rows >= 1 else { return .failure(.init("This face cannot be divided.")) }
        let polys = SurfacePatternAxis.piecePolygons(face: face, in: mesh, within: within)
        guard !polys.isEmpty else { return .failure(.init("Nothing of this face is left to divide.")) }
        guard let us = evenAreaLines(polys, origin: frame.origin, axis: frame.u, count: columns),
              let vs = evenAreaLines(polys, origin: frame.origin, axis: frame.v, count: rows)
        else { return .failure(.init("This face is too small to divide.")) }
        var out: [FaceRegionGeometry.GridCell] = []
        for i in 0..<columns {
            for j in 0..<rows {
                var cuts: [RegionCut] = [], drawn: [RegionCut] = []
                // the outer sides are left open (a cell reaches the piece's own edge), as `gridSplitCells` does
                if i > 0 {
                    let c = RegionCut(point: frame.origin + frame.u * us[i - 1], normal: frame.u)
                    cuts.append(c); drawn.append(c)
                }
                if i < columns - 1 {
                    cuts.append(RegionCut(point: frame.origin + frame.u * us[i], normal: -frame.u, strict: true))
                }
                if j > 0 {
                    let c = RegionCut(point: frame.origin + frame.v * vs[j - 1], normal: frame.v)
                    cuts.append(c); drawn.append(c)
                }
                if j < rows - 1 {
                    cuts.append(RegionCut(point: frame.origin + frame.v * vs[j], normal: -frame.v, strict: true))
                }
                out.append(FaceRegionGeometry.GridCell(i: i, j: j, cuts: cuts, drawn: drawn))
            }
        }
        return .success(out)
    }

    /// The `count − 1` places along `axis` (from `origin`) where the polygons' area divides into `count` even parts. Nil when
    /// they hold no area. Bisection on the clipped area, 32 halvings (under a micron on a 1 m part).
    static func evenAreaLines(_ polys: [[SIMD3<Double>]], origin: SIMD3<Double>, axis: SIMD3<Double>, count: Int) -> [Double]? {
        guard count >= 1 else { return nil }
        let a = simd_normalize(axis)
        var lo = Double.greatestFiniteMagnitude, hi = -Double.greatestFiniteMagnitude
        for p in polys { for q in p { let t = simd_dot(q - origin, a); lo = Swift.min(lo, t); hi = Swift.max(hi, t) } }
        let total = polys.reduce(0) { $0 + SurfacePatternAxis.polygonArea($1) }
        guard hi > lo, total > 1e-12 else { return nil }
        guard count > 1 else { return [] }
        /// The area on the near side of the line at `t` (u ≤ t).
        func below(_ t: Double) -> Double {
            let keep = [RegionCut(point: origin + a * t, normal: -a)]
            return polys.reduce(0) { $0 + SurfacePatternAxis.polygonArea(SurfacePatternAxis.clipPolygon($1, to: keep)) }
        }
        return (1..<count).map { k in
            let want = total * Double(k) / Double(count)
            var l = lo, h = hi
            for _ in 0..<32 {
                let m = (l + h) / 2
                if below(m) < want { l = m } else { h = m }
            }
            return (l + h) / 2
        }
    }
}
