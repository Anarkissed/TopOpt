// FlexiblePressPushHeat — round 7 batch R7-E5 (task 2026-09-29-flexible-screens): an edges group's interim sim (R7-E3) PRESSES
// WHERE HE DREW, and its squish wears HEAT on the flat prism's footprint. His answers of 2026-10-19 ~17:50 (binding): "one more small
// lean front-end batch for edge groups now: Heat colours, X-ray showing the bend as a prism, Play following the drawn curve (not an
// even push)". FRONT-END FIRST (his ruling of 2026-10-19 ~14:50): nothing here reaches core's job — the interim sim's conditions hold
// (it never writes a job; the chip "Lattice not tuned for this press yet" while it plays).
//
// ★ THE PUSH (FlexiblePressPush): the press's drawn shape as samples on its footprint, each with a weight — Curves: the across
// multiplier × the along multiplier at that fold coordinate (a corner: its one curve, rim 0 → vertex 1); Stamp: 1 under the stamp's
// outline (laid ⟂ the arrow through its centre, as drawn), 0 off it. The bridge gives each loaded cell face its nearest sample's
// weight and renormalises to the group's force (FlexSquishPress.push_xyz / push_weight): the force is unchanged, only WHERE it
// presses follows the drawing. All ones (never edited) is exactly R7-E3's even push.
// ★ THE HEAT (FlexiblePressHeat): per COLUMN of core's press stack (the stack the flat prism's limits already read), how much the
// interim sim compresses it along the arrow (FlexibleFEField.columnCompression, the face groups' own quantity), at the size Play
// shows it (× min(1, the field's safe scale) — the Squish page's k for an edges group); painted on the footprint's drawn triangles,
// every vertex by its own column, on the legend's one scale. It follows the group the views show (the open group on the Squish
// page, the selector's on the Lattice page; the 3-second hold: every group).

import Foundation
import simd
import TopOptKit

public enum FlexiblePressPush {
    /// ★ RED CONTROL only (FlexibleR7E5Tests): R7-E3's even push — the drawing ignored (every weight 1).
    nonisolated(unsafe) static var controlEvenPush = false
    /// Samples per side of the footprint grid.
    static let n = 32

    public struct Samples: Equatable, Sendable {
        public var xyz: [Double] = []
        public var weight: [Double] = []
        public var count: Int { weight.count }
        mutating func add(_ p: SIMD3<Double>, _ w: Double) { xyz += [p.x, p.y, p.z]; weight.append(Swift.max(0, Swift.min(1, w))) }
    }

    /// The pen curve's values at `t` (the editor's own curve), or ones.
    static func values(_ c: FlexCurve, _ t: [Double]) -> [Double] {
        (try? FlexibleCore.penCurveValues(x: c.x, y: c.y, t: t)) ?? [Double](repeating: 1, count: t.count)
    }

    /// Is `p` under the stamp — its outline laid ⟂ the arrow through its centre (FlexiblePressStamp.outline's ellipse)?
    static func underStamp(_ p: SIMD3<Double>, _ st: FlexibleStrip, _ s: FlexibleStampPlacement, direction d: SIMD3<Double>) -> Bool {
        guard let c = FlexiblePressStamp.centre(st, s), let f = FlexiblePressStamp.frame(st, direction: d),
              s.widthMM > 0, s.lengthMM > 0 else { return false }
        let th = s.rotationDeg * .pi / 180
        let ax = f.x * cos(th) + f.y * sin(th), ay = f.y * cos(th) - f.x * sin(th)
        let q = p - d * simd_dot(p - c, d)
        let x = simd_dot(q - c, ax) / (s.widthMM / 2), y = simd_dot(q - c, ay) / (s.lengthMM / 2)
        return x * x + y * y <= 1
    }

    /// ★ THE SAMPLES of press `p` with cut `c`: its footprint on the part (an edge: across 0 → ½ the edge → 1 on the faces' traces,
    /// along start → stop; a corner: each member's triangle from the vertex to its legs), each weighted by the drawing.
    public static func samples(_ p: FlexiblePress, _ c: FlexibleFlatPrism.Cut) -> Samples {
        guard let st = p.strip else { return Samples() }
        let stamp = p.settings.isStampShape ? p.settings.designStamp : nil
        var out = Samples()
        let ts = (0...n).map { Double($0) / Double(n) }
        func weight(_ q: SIMD3<Double>, curve: Double) -> Double {
            if controlEvenPush { return 1 }
            if let stamp { return underStamp(q, st, stamp, direction: c.direction) ? 1 : 0 }
            return curve
        }
        if let l = FlexibleFlatPrism.line(st), st.members.count == 2,
           let aa = st.members[0].away.first, let ab = st.members[1].away.first {
            let across = values(FlexiblePressCurveBaselines.multipliers(p, .across), ts)
            let along = values(FlexiblePressCurveBaselines.multipliers(p, .along), ts)
            for (i, si) in ts.enumerated() {
                let s = l.s0 + (l.s1 - l.s0) * si
                let e = l.origin + l.dir * s
                guard let wa = FlexibleFlatPrism.reach(st, member: 0, c, along: s), let wb = FlexibleFlatPrism.reach(st, member: 1, c, along: s),
                      wa.isFinite, wb.isFinite else { continue }
                for (j, t) in ts.enumerated() {
                    let q = t <= 0.5 ? e + aa * (Swift.max(0, wa) * (1 - 2 * t)) : e + ab * (Swift.max(0, wb) * (2 * t - 1))
                    out.add(q, weight(q, curve: across[j] * along[i]))
                }
            }
        } else if st.kind == .corner {
            let curve = values(FlexiblePressCurveBaselines.multipliers(p, .corner), ts)
            for m in st.members {
                let legs = FlexibleFlatPrism.edges(m).compactMap { e -> SIMD3<Double>? in
                    let de = simd_dot(e, c.direction)
                    return de > 1e-9 ? c.apex + e * (c.depthMM / de) : nil
                }
                guard legs.count == 2 else { continue }
                for a in 0...n { for b in 0...(n - a) {
                    let u = Double(a) / Double(n), v = Double(b) / Double(n)
                    let q = c.apex + (legs[0] - c.apex) * u + (legs[1] - c.apex) * v
                    out.add(q, weight(q, curve: curve[n - a - b]))   // rim (u + v = 1) → 0, the vertex → 1
                } }
            }
        }
        return out
    }
}

@MainActor
public enum FlexiblePressHeat {
    /// ★ RED CONTROL only: R7-E3's state — an edges group wears no heat.
    static var controlNoPressHeat = false

    /// One press's heat: its footprint's regions, core's press stack and the value of each of its columns (mm, as Play shows it).
    public struct Entry: Equatable {
        public let press: UUID
        public let regions: [Int]
        public let stack: FlexStackInfo
        public let valuesMM: [Double]
    }

    /// The size Play shows an edges group's interim sim at (the Squish page's k: its own size, never folded).
    static func shownScale(_ f: FlexibleFEField) -> Double { Swift.min(1, f.maxSafeScale) }

    /// ★ The heat of the edges groups numbered `groups` (nil: every edges group — his hold) whose interim sim is current.
    public static func entries(model m: FlexibleStageModel, groups: Set<Int>?) -> [Entry] {
        guard !controlNoPressHeat else { return [] }
        var out: [Entry] = []
        for g in m.squeezeGroups where g.kind == .edges && (groups?.contains(g.number) ?? true) {
            guard let f = FlexibleSettingsSquish.field(model: m, group: g) else { continue }
            let k = shownScale(f)
            for id in g.presses {
                guard let p = m.press(id), !p.regions.isEmpty, let st = m.pressStack(id), !st.columns.isEmpty else { continue }
                let v = st.columns.indices.map { Swift.max(0, f.columnCompression(stack: st, col: $0, pinched: false) * k) }
                out.append(Entry(press: id, regions: p.regions, stack: st, valuesMM: v))
            }
        }
        return out
    }

    /// The edges groups the Squish page's Heat shows: the open group (tap), every group (hold), none (off).
    public static func squishPageGroups(model m: FlexibleStageModel, views: FlexibleStageViews) -> Set<Int>? {
        switch views.heatScope {
        case .all: return nil
        case .group: return m.playingGroup.map { [$0.number] } ?? []
        case .off: return []
        }
    }

    /// The column of stack `st` under model point `p` (core's frame; a surface point need not sit inside the column's run).
    static func column(_ p: SIMD3<Double>, _ st: FlexStackInfo) -> Int? {
        guard st.pitchMM > 0, st.nu > 0, st.nv > 0 else { return nil }
        let d = p - st.centroid
        let u = simd_dot(d, st.xAxis) - st.uMin, v = simd_dot(d, st.yAxis) - st.vMin
        let c = st.column(Int((u / st.pitchMM).rounded(.down)), Int((v / st.pitchMM).rounded(.down)))
        return c >= 0 && c < st.columns.count ? c : nil
    }

    private static var triCache: [String: [Int]] = [:]
    /// ★ The overlay's drawn part triangles on `regions` (a press's footprint), cached per (overlay, regions).
    static func footprintTriangles(model m: FlexibleStageModel, overlay o: FlexibleOverlayMesh, regions: [Int]) -> [Int] {
        let key = "\(o.mesh.signature.contentHash)|\(o.keptFace.count)|\(regions)"
        if let c = triCache[key] { return c }
        let mesh = m.project.viewerMesh
        let faces = Set(regions.flatMap { m.regions.faces(of: $0, mesh: mesh) })
        var out: [Int] = []
        for t in 0..<o.keptFace.count where o.bandColumn[t] == nil && faces.contains(o.keptFace[t]) {
            if regions.contains(where: { m.regions.contains($0, face: o.keptFace[t], centroid: o.keptCentroid[t], mesh: mesh) }) { out.append(t) }
        }
        if triCache.count > 32 { triCache = [:] }
        triCache[key] = out
        return out
    }

    /// The heat's top end over `entries` (mm).
    static func top(_ entries: [Entry]) -> Double { entries.flatMap(\.valuesMM).max() ?? 0 }

    /// ★ Paint `entries` on the overlay's tints: every vertex of the footprint's drawn triangles by its own column, on `scale`
    /// (opaque through the X-ray, like a face's map). Returns the vertices painted.
    @discardableResult
    static func paint(_ tints: inout [Float], overlay o: FlexibleOverlayMesh, model m: FlexibleStageModel,
                      entries: [Entry], scale: Double) -> Int {
        let pos = o.mesh.flat.positions
        var painted = 0
        for e in entries {
            for t in footprintTriangles(model: m, overlay: o, regions: e.regions) {
                for j in 0..<3 {
                    let v = 3 * t + j
                    guard 3 * v + 2 < pos.count, 8 * v + 7 < tints.count else { continue }
                    let p = SIMD3<Double>(Double(pos[3 * v]), Double(pos[3 * v + 1]), Double(pos[3 * v + 2]))
                    guard let c = column(p, e.stack), c < e.valuesMM.count else { continue }
                    let col = FlexibleColours.depth(e.valuesMM[c], max: scale)
                    tints[8 * v] = col.x; tints[8 * v + 1] = col.y; tints[8 * v + 2] = col.z; tints[8 * v + 3] = col.w
                    tints[8 * v + 5] = 1; tints[8 * v + 6] = 0
                    painted += 1
                }
            }
        }
        return painted
    }
}

extension FlexibleMainStage {
    /// ★ R7-E5: the edges groups whose heat the Lattice page shows — the selector's group; "All" or the 3-second hold: every one.
    var mainPressHeatGroups: Set<Int>? {
        if heatAll || selectedSim == FlexibleSim.allID { return nil }
        guard let id = selectedSim, case .group(let n)? = sims.first(where: { $0.id == id })?.kind else { return [] }
        return [n]
    }
}
