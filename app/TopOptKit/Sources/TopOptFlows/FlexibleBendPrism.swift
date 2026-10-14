// FlexibleBendPrism — the Squish page's X-ray view (task 2026-09-29-flexible-screens, round 7 batch X1). His answer 12
// (2026-10-14, binding): "The curve should be viewed as nothing but the curve without any view turned on. Turning heat map
// on shows colour. Turning bend on, shows bend. Turning play on, plays the sim. Turning x-ray on shows a prism view of the
// actual bend INTO the model."
// ★ THE BEND AS A PRISM: the current group's (the open tab's — FlexibleStageModel.playingGroup) pressed faces AT REST, the
// same faces BENT at full depth (k × the dent at full load, the page's one k), and the skirt between them along the group's
// outline — one shell (FaceOffsetShell: base = rest, offset = bent), drawn by MetalMeshView's clearance pass in the
// face-prism's purple, faint, through the X-ray ghost. A pinch's two faces are two prisms in the one shell. An
// edges/corners group has no press stacks yet (AP9): no prism.
// ★ WELDED: the overlay's map quads are flat (each triangle its own corners), so its corners are welded by rest position
// (to 1 µm) — the skirt then rides only the group's outline (the edges used by one triangle), and a corner's bend is the
// mean of its quads' (the column route's steps are smoothed; the 3D sim's field is continuous already).

import Foundation
import simd

@MainActor
enum FlexibleBendPrism {
    static let faceAlpha: Float = 0.22
    static let edgeAlpha: Float = 0.85
    /// The shell's corners are welded on this grid (mm).
    static let weldMM: Float = 0.001
    private static var cache: (key: String, item: ClearanceRenderItem?)?

    /// The current group's bend prism, or nil (no group, no stack, no dent).
    static func item(model m: FlexibleStageModel, overlay o: FlexibleOverlayMesh?, dents: [Float]?, k: Double) -> ClearanceRenderItem? {
        guard let o, let d = dents, k > 0, let g = m.playingGroup, g.kind != .edges else { return nil }
        let pos = o.mesh.flat.positions
        let n = min(pos.count, d.count) / 3
        var ranges: [Range<Int>] = []
        for r in g.regions {
            guard let key = m.key(r), let start = o.flatStart[key], let st = m.stacks[key], start < n else { continue }
            ranges.append(start..<min(start + 6 * st.columns.count, n))
        }
        guard !ranges.isEmpty else { return nil }
        var h = Hasher()
        h.combine(o.mesh.signature.contentHash); h.combine(k)
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
        let item = ClearanceRenderItem(volume: .shell(faceID: -1, shell: shell), selected: false, tint: FlexibleStageStyle.facePrismTint,
                                       faceAlpha: faceAlpha, edgeAlpha: edgeAlpha)
        cache = (key, item)
        return item
    }
}
