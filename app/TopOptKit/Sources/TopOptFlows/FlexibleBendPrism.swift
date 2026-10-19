// FlexibleBendPrism — the Squish page's X-ray view (task 2026-09-29-flexible-screens, round 7 batch X1). His answer 12
// (2026-10-14, binding): "The curve should be viewed as nothing but the curve without any view turned on. Turning heat map
// on shows colour. Turning bend on, shows bend. Turning play on, plays the sim. Turning x-ray on shows a prism view of the
// actual bend INTO the model."
// ★ THE BEND AS A PRISM: the current group's (the open tab's — FlexibleStageModel.playingGroup) pressed faces AT REST, the
// same faces BENT at full depth (k × the dent at full load, the page's one k), and the skirt between them along the group's
// outline — one shell (FaceOffsetShell: base = rest, offset = bent), drawn by MetalMeshView's clearance pass in the
// face-prism's purple, faint, through the X-ray ghost (★ X1 VERIFY: a NEUTRAL glass — the violet vanished on the heat's
// blue, his Group 1's prism unseen under the Top's heat; and its number, in a box, at its deepest point, with the ONE card's
// row). A pinch's two faces are two prisms in the one shell.
// ★ R7-E5 (his answer of 2026-10-19 ~17:50: "X-ray showing the bend as a prism" for edge groups): an edges/corners group's prism is
// its presses' FOOTPRINTS (the drawn part triangles of each flat prism's pieces) at rest and moved by its interim sim at the size Play
// shows — the wedge of the bend along each arrow, into the model (R7-E3's guard `g.kind != .edges` dropped).
// ★ WELDED: the overlay's map quads are flat (each triangle its own corners), so its corners are welded by rest position
// (to 1 µm) — the skirt then rides only the group's outline (the edges used by one triangle), and a corner's bend is the
// mean of its quads' (the column route's steps are smoothed; the 3D sim's field is continuous already).

import Foundation
import simd
import TopOptDesign

@MainActor
enum FlexibleBendPrism {
    static let faceAlpha: Float = 0.22
    static let edgeAlpha: Float = 0.85
    /// The shell's corners are welded on this grid (mm).
    static let weldMM: Float = 0.001
    private static var cache: (key: String, item: ClearanceRenderItem?)?

    /// ★ X1 VERIFY (the verify: "nothing says how deep it is … He has no way to tell what the purple slab measures"; his
    /// rule: numbers are boxes): the prism's number, read-only, at its deepest point (the floor — where the bend ends).
    struct Tag: Equatable {
        let text: String
        let anchor: SIMD3<Float>
        let depthMM: Double
    }
    static func tag(_ item: ClearanceRenderItem?) -> Tag? {
        guard !controlFirstBuild, let item, case .shell(let sh) = item.volume.shape, !sh.base.isEmpty, sh.base.count == sh.offset.count
        else { return nil }
        var best = 0, far: Float = -1
        for i in sh.base.indices { let d = simd_length(sh.offset[i] - sh.base[i]); if d > far { far = d; best = i } }
        return Tag(text: String(format: "%.1f mm", sh.reachedDepthMM), anchor: sh.offset[best], depthMM: sh.reachedDepthMM)
    }
    /// ★ X1 VERIFY (the verify: his Group 1's prism 3.8 mm beside its 12 mm Deepest squish, nothing said): the bend at full
    /// load (the 3D sim's, when it is current) is well short of the curve he DREW on the open group's faces — the deepest
    /// number the page's heat shows for them — by more than 10 % and 0.5 mm.
    static func shortOfDrawn(model m: FlexibleStageModel, depthMM: Double) -> Bool {
        guard let g = m.playingGroup else { return false }
        let regions = Set(g.regions)
        let shown = FlexibleShownValues(model: m, drawnLattice: nil)
        var drawn = 0.0
        for (k, vals) in shown.values where regions.contains(k.region) {
            for v in vals { if case .depth(let d) = v { drawn = Swift.max(drawn, d) } }
        }
        return depthMM < 0.9 * drawn && drawn - depthMM > 0.5
    }
    /// ★ X1 VERIFY: the glass — a neutral white, far from every colour of the heat's rainbow (the violet sat on its blue).
    static var tint: SIMD3<Float> {
        controlFirstBuild ? FlexibleStageStyle.facePrismTint
            : SIMD3(Float(DS.Color.textPrimary.r), Float(DS.Color.textPrimary.g), Float(DS.Color.textPrimary.b))
    }
    /// Test control only (X1 verify): X1's first build — the violet prism, no number, no legend row.
    static var controlFirstBuild = false
    /// Test control only (R7-E5): R7-E3's guard — no prism for an edges group.
    static var controlNoEdges = false

    /// The current group's bend prism, or nil (no group, no stack, no dent).
    static func item(model m: FlexibleStageModel, overlay o: FlexibleOverlayMesh?, dents: [Float]?, k: Double) -> ClearanceRenderItem? {
        guard let o, let d = dents, k > 0, let g = m.playingGroup, !(controlNoEdges && g.kind == .edges) else { return nil }
        let pos = o.mesh.flat.positions
        let n = min(pos.count, d.count) / 3
        var ranges: [Range<Int>] = []
        if g.kind == .edges {   // ★ R7-E5: each press's footprint (its drawn part triangles)
            for id in g.presses {
                guard let p = m.press(id), !p.regions.isEmpty else { continue }
                for t in FlexiblePressHeat.footprintTriangles(model: m, overlay: o, regions: p.regions) where 3 * t + 3 <= n {
                    ranges.append(3 * t..<3 * t + 3)
                }
            }
        }
        for r in g.regions where g.kind != .edges {
            guard let key = m.key(r), let start = o.flatStart[key], let st = m.stacks[key], start < n else { continue }
            ranges.append(start..<min(start + 6 * st.columns.count, n))
        }
        guard !ranges.isEmpty else { return nil }
        var h = Hasher()
        h.combine(o.mesh.signature.contentHash); h.combine(k); h.combine(controlFirstBuild)
        for r in ranges { h.combine(r.lowerBound); h.combine(r.upperBound); var i = r.lowerBound; while i < r.upperBound { h.combine(d[3 * i]); h.combine(d[3 * i + 2]); i += 7 } }
        let key = "\(h.finalize())"
        if let c = cache, c.key == key { return c.item }
        struct K: Hashable { let x: Int32, y: Int32, z: Int32 }
        var index: [K: UInt32] = [:]
        var base: [SIMD3<Float>] = [], sum: [SIMD3<Float>] = [], count: [Float] = []
        var idx: [UInt32] = []
        func corner(_ v: Int) -> UInt32 {
            let p = SIMD3<Float>(pos[3 * v], pos[3 * v + 1], pos[3 * v + 2])
            let q = (p / weldMM).rounded(.toNearestOrEven)
            let kk = K(x: Int32(clamping: Int(q.x)), y: Int32(clamping: Int(q.y)), z: Int32(clamping: Int(q.z)))
            let disp = SIMD3<Float>(d[3 * v], d[3 * v + 1], d[3 * v + 2])
            if let i = index[kk] { sum[Int(i)] += disp; count[Int(i)] += 1; return i }
            let i = UInt32(base.count)
            index[kk] = i; base.append(p); sum.append(disp); count.append(1)
            return i
        }
        for r in ranges {
            var t = r.lowerBound
            while t + 2 < r.upperBound {
                let a = corner(t), b = corner(t + 1), c = corner(t + 2)
                if a != b, b != c, a != c { idx += [a, b, c] }
                t += 3
            }
        }
        guard !idx.isEmpty else { cache = (key, nil); return nil }
        let kf = Float(k)
        let offset = base.indices.map { base[$0] + sum[$0] / max(count[$0], 1) * kf }
        let deepest = zip(base, offset).map { Double(simd_length($1 - $0)) }.max() ?? 0
        guard deepest > 1e-4 else { cache = (key, nil); return nil }
        let shell = FaceOffsetShell(base: base, offset: offset, indices: idx, reachedDepthMM: deepest)
        let item = ClearanceRenderItem(volume: .shell(faceID: -1, shell: shell), selected: false, tint: tint,   // ★ X1 VERIFY: neutral glass
                                       faceAlpha: faceAlpha, edgeAlpha: edgeAlpha)
        cache = (key, item)
        return item
    }
}
