// FlexibleIndent — round 7, step X20b (task 2026-09-29-flexible-screens). His answer of 2026-10-20 ~19:10 (binding): "On-part
// curves: REMOVE them from the part, but show the indent when selected like the stamp" — the selected press (a face's or an edge's)
// shows its INDENT on the part as a stamp shows its outline; nothing on the part is editable; the curves are edited only in the
// 2D / 3D window (FlexiblePressCurveModal).
//
// ★ WHAT IS DRAWN: the drawn squish's contour lines on the part — the indent's outline (10 % of the deepest: where the dent
// starts), its half (50 %) and its deepest zone (90 %) — from the shape the app already holds, never a new one:
//   * a face: core's own squish fraction per column of the face's map (FlexibleStageModel.liveS — the dent and the heat read it),
//     on the column grid, at the face (the stamp's plane: the frame's corner + X·u + Y·v, ½ mm out);
//   * an edge or a corner: the press's drawn push on its flat prism's footprint (FlexiblePressPush.samples — what Play pushes).
// Beyond the grid counts as no squish, so a press flat to its rim (ones) is outlined along its footprint's border.

import SwiftUI
import simd
import TopOptKit

public enum FlexibleIndent {
    /// ★ RED CONTROL only: the curves drawn and dragged ON THE PART (before X20b: FlexibleCurveEditor on the face and on the edge).
    nonisolated(unsafe) public static var controlCurvesOnPart = false

    /// The contour levels (share of the deepest squish): the outline, the half, the deepest zone.
    public static let levels: [Double] = [0.1, 0.5, 0.9]

    public struct Line: Equatable {
        public let level: Double
        public let a: SIMD3<Double>
        public let b: SIMD3<Double>
    }

    /// A triangulated grid with values and its border (the edges beyond which nothing squishes).
    struct Mesh {
        var pos: [SIMD3<Double>] = []
        var val: [Double] = []
        var tris: [SIMD3<Int>] = []
        var border: [SIMD2<Int>] = []
    }

    /// The contour of `m` at each level: marching triangles inside, and the border wherever it is past the level.
    static func lines(_ m: Mesh) -> [Line] {
        var out: [Line] = []
        func cross(_ i: Int, _ j: Int, _ l: Double) -> SIMD3<Double> {
            let a = m.val[i], b = m.val[j]
            let t = Swift.abs(b - a) > 1e-12 ? (l - a) / (b - a) : 0.5
            return m.pos[i] + (m.pos[j] - m.pos[i]) * Swift.min(1, Swift.max(0, t))
        }
        for l in levels {
            for t in m.tris {
                let ids = [t.x, t.y, t.z]
                var pts: [SIMD3<Double>] = []
                for e in 0..<3 {
                    let i = ids[e], j = ids[(e + 1) % 3]
                    if (m.val[i] >= l) != (m.val[j] >= l) { pts.append(cross(i, j, l)) }
                }
                if pts.count == 2 { out.append(Line(level: l, a: pts[0], b: pts[1])) }
            }
            for e in m.border {
                let i = e.x, j = e.y
                let ai = m.val[i] >= l, aj = m.val[j] >= l
                if ai && aj { out.append(Line(level: l, a: m.pos[i], b: m.pos[j])) }
                else if ai { out.append(Line(level: l, a: m.pos[i], b: cross(i, j, l))) }
                else if aj { out.append(Line(level: l, a: cross(i, j, l), b: m.pos[j])) }
            }
        }
        return out
    }

    /// A rows × cols grid (row-major), two triangles a cell, its four sides the border.
    static func grid(rows: Int, cols: Int, pos: (Int, Int) -> SIMD3<Double>, val: (Int, Int) -> Double) -> Mesh {
        var m = Mesh()
        guard rows > 1, cols > 1 else { return m }
        for r in 0..<rows { for c in 0..<cols { m.pos.append(pos(r, c)); m.val.append(val(r, c)) } }
        func id(_ r: Int, _ c: Int) -> Int { r * cols + c }
        for r in 0..<(rows - 1) { for c in 0..<(cols - 1) {
            m.tris.append(SIMD3(id(r, c), id(r + 1, c), id(r, c + 1)))
            m.tris.append(SIMD3(id(r + 1, c), id(r + 1, c + 1), id(r, c + 1)))
        } }
        for c in 0..<(cols - 1) { m.border.append(SIMD2(id(0, c), id(0, c + 1))); m.border.append(SIMD2(id(rows - 1, c), id(rows - 1, c + 1))) }
        for r in 0..<(rows - 1) { m.border.append(SIMD2(id(r, 0), id(r + 1, 0))); m.border.append(SIMD2(id(r, cols - 1), id(r + 1, cols - 1))) }
        return m
    }

    /// ★ A face's indent: core's squish fraction per column (liveS) on the column grid, padded by one column of no squish.
    @MainActor
    public static func face(model m: FlexibleStageModel, region r: Int) -> [Line] {
        // ★ MANUAL (M2, "the on-model indent rings follow the prediction"): in Manual each column's estimate ÷ the deepest (no
        // estimate yet: no rings) — his drawing is no input there
        guard let k = m.key(r), let st = m.stacks[k], let g = m.geometry[k], let s = m.isManual ? m.estimateFractions(region: r) : m.liveS[k],
              st.nu > 0, st.nv > 0, st.pitchMM > 0 else { return [] }
        let p = st.pitchMM
        func world(_ iu: Int, _ iv: Int) -> SIMD3<Double> {
            g.corner + st.xAxis * ((Double(iu) + 0.5) * p) + st.yAxis * ((Double(iv) + 0.5) * p) - st.load * 0.5
        }
        func value(_ iu: Int, _ iv: Int) -> Double {
            guard iu >= 0, iv >= 0, iu < st.nu, iv < st.nv else { return 0 }
            let c = st.cell[iv * st.nu + iu]
            return c >= 0 && c < s.count ? Swift.max(0, Swift.min(1, s[c])) : 0
        }
        // padded: row = iv + 1, col = iu + 1 (the outer ring is no squish, at the next column's place)
        let mesh = grid(rows: st.nv + 2, cols: st.nu + 2, pos: { world($1 - 1, $0 - 1) }, val: { value($1 - 1, $0 - 1) })
        return lines(mesh)
    }

    /// ★ An edge's or a corner's indent: the press's drawn push on its footprint (what Play pushes), the grid's border no squish.
    @MainActor
    public static func press(model m: FlexibleStageModel, id: UUID) -> [Line] {
        guard let p = m.press(id), let st = p.strip, let c = m.flatCut(id) else { return [] }
        // ★ MANUAL (M2): the field's push along the arrow at each sample, ÷ the deepest (no estimate yet: no rings)
        let est = m.isManual ? m.estimatePushes(press: id) : nil
        if m.isManual && est == nil { return [] }
        var s = est?.samples ?? FlexiblePressPush.samples(p, c)
        if let e = est { s.weight = e.values }
        let n = FlexiblePressPush.n + 1
        func at(_ i: Int) -> SIMD3<Double> { SIMD3(s.xyz[3 * i], s.xyz[3 * i + 1], s.xyz[3 * i + 2]) - c.direction * 0.5 }
        if st.kind != .corner {
            guard s.count == n * n else { return [] }
            return lines(grid(rows: n, cols: n, pos: { at($0 * n + $1) }, val: { s.weight[$0 * n + $1] }))
        }
        // a corner: each member's triangle of samples (a, b ≥ 0, a + b ≤ n − 1), in the samples' order; its sides are its border
        var mesh = Mesh()
        var base = 0
        let per = n * (n + 1) / 2
        while base + per <= s.count {
            var idx: [SIMD2<Int>: Int] = [:]
            var q = base
            for a in 0..<n { for b in 0..<(n - a) { idx[SIMD2(a, b)] = mesh.pos.count; mesh.pos.append(at(q)); mesh.val.append(s.weight[q]); q += 1 } }
            for a in 0..<(n - 1) { for b in 0..<(n - 1 - a) {
                guard let i = idx[SIMD2(a, b)], let j = idx[SIMD2(a + 1, b)], let k = idx[SIMD2(a, b + 1)] else { continue }
                mesh.tris.append(SIMD3(i, j, k))
                if let l = idx[SIMD2(a + 1, b + 1)] { mesh.tris.append(SIMD3(j, l, k)) }
            } }
            for t in 0..<(n - 1) {
                if let i = idx[SIMD2(t, 0)], let j = idx[SIMD2(t + 1, 0)] { mesh.border.append(SIMD2(i, j)) }
                if let i = idx[SIMD2(0, t)], let j = idx[SIMD2(0, t + 1)] { mesh.border.append(SIMD2(i, j)) }
                if let i = idx[SIMD2(t, n - 1 - t)], let j = idx[SIMD2(t + 1, n - 2 - t)] { mesh.border.append(SIMD2(i, j)) }
            }
            base += per
        }
        return lines(mesh)
    }
}

/// ★ X20b: the indent's lines on the part — display only (no touch), never under the chrome; the pose while Bend shows.
struct FlexibleIndentLayer: View {
    let lines: [FlexibleIndent.Line]
    let projection: CameraProjection?
    var clip: [CGRect] = []
    var pose: FlexibleBendPose? = nil

    var body: some View {
        Canvas { ctx, size in
            FlexibleChromeClip.apply(&ctx, size: size, holes: clip)
            for (level, width, alpha) in [(0.1, 2.0, 1.0), (0.5, 1.5, 0.8), (0.9, 1.0, 0.65)] {
                var path = Path()
                for l in lines where l.level == level {
                    guard let a = screen(l.a), let b = screen(l.b) else { continue }
                    path.move(to: a); path.addLine(to: b)
                }
                ctx.stroke(path, with: .color(FlexibleStageStyle.onPart.opacity(alpha)),
                           style: StrokeStyle(lineWidth: width, lineCap: .round, dash: level == 0.9 ? [4, 3] : []))
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func screen(_ w: SIMD3<Double>) -> CGPoint? {
        let q = SIMD3<Float>(w)
        return projection?.project(pose?.apply(q) ?? q)
    }
}
