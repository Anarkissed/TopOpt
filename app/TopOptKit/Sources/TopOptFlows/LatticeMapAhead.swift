// LatticeMapAhead — ★ his words 2026-11-23, after release 16 (a): "start an animation by removing the walls, allowing that animation
// to run for 2-3 seconds and THEN starting the growing animation". The walls over the lattice can only dissolve with the map
// that opens them, and the engine makes that map from a FINISHED lay (lattice_layout_grid reads the lay's outcome, under the
// session lock the lay holds). 362 is adding `LatticeLayoutSession.gridAhead(_:origin:voxel:dims:)` (engine + bridge, branch
// claude/speed-2): the same map, made BEFORE the lay for all-Organic settings. THIS FILE IS ITS HOOK: `mapAhead` asks it with
// the very box, voxel and dims the landed lattice's map uses (`mapGeometry`, shared with `LatticeLayoutPreview.map`), and
// returns nil until it exists (or when it cannot: a cube-lattice region needs the laid cells) — the part then stands in X-ray
// while the vines grow, as before. The lay that lands keeps that map (no second one).
import Foundation
import simd
import TopOptKit

extension LatticeLayoutPreview {
    /// The engine's map over the part's box with a voxel of air all round: about a million voxels at most, never finer than
    /// 0.35 mm (the landed lattice's `map` and the map made ahead alike).
    static func mapGeometry(_ box: (lo: SIMD3<Float>, hi: SIMD3<Float>)) -> (origin: SIMD3<Float>, voxel: Float, dims: SIMD3<Int32>) {
        let ext = simd_max(box.hi - box.lo, SIMD3(repeating: 0.1))
        let voxel = Swift.max(0.35, Float(cbrt(Double(ext.x * ext.y * ext.z) / 1_000_000)))
        let dims = SIMD3<Int32>(Int32((ext.x / voxel).rounded(.up)) + 3, Int32((ext.y / voxel).rounded(.up)) + 3,
                                Int32((ext.z / voxel).rounded(.up)) + 3)
        return (box.lo - SIMD3(repeating: voxel), voxel, dims)
    }

    /// Tests: a map handed out as if the engine had made it ahead (nil: none).
    nonisolated(unsafe) static var mapAheadForTesting: ((LatticeLayoutSession.Settings) -> LatticeLayoutSolidGrid?)?
    /// Tests' RED CONTROL: no map before the lay (the part stands in X-ray while it grows, as before the engine made one).
    nonisolated(unsafe) public static var controlNoMapAhead = false

    /// ★ THE HOOK: the map settings `s` will open the part with, made before the lay (on the session's worker, right before
    /// `layOrganic`). nil: not available — the part stands in X-ray while it grows.
    static func mapAhead(_ session: LatticeLayoutSession, _ s: LatticeLayoutSession.Settings,
                         _ box: (lo: SIMD3<Float>, hi: SIMD3<Float>)?, token: Int, smooth: Bool) async -> LatticeLayoutSolidGrid? {
        if controlNoMapAhead || controlDraftWaitsForExactMap { return nil }
        if let t = mapAheadForTesting, var m = t(s) { m.token = token; return m }
        guard let box else { return nil }
        let g = mapGeometry(box)
        // ★ 362 (claude/speed-2 05b12173): the engine's map made before the lay (nil: a cube-lattice region, or it failed)
        guard let r = try? await session.gridAhead(s, origin: g.origin, voxel: g.voxel, dims: g.dims) else { return nil }
        let rg = smooth ? LatticeLayoutSolidGrid.smoothed(r.rg, dims: g.dims) : r.rg
        return LatticeLayoutSolidGrid(token: token, origin: g.origin, voxel: g.voxel, dims: g.dims, rg: rg, smooth: smooth)
    }
}

extension LatticeGrowth {
    /// The map this lay's walls dissolved with, as the landed lattice's own (`token`): it lands opened, no second map.
    public func landedMap(token: Int) -> LatticeLayoutSolidGrid? {
        guard var m = aheadMap else { return nil }
        m.token = token
        return m
    }
}
