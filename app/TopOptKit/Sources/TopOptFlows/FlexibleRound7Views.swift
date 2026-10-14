// FlexibleRound7Views — the views on both Flexible pages, round 7 batch R7-V (task 2026-09-29-flexible-screens). His
// words, 2026-10-14 (his UI breakdown, binding):
//   img1: "All view buttons should be icons - never full words. Remove the two full worded view icons. I've decided
//          against them." … "Instead, add a Play button icon to allow for the simulation view. This should be able to be
//          on with any other view simultaneously. When it is on the simulation plays - otherwise, remove the play-bar from
//          the bottom of the screen entirely." … "When the pause is selected for the simulator, any action taken anywhere
//          automatically re-starts the simulation. Only by pressing Play should the sim actually restart."
//   img3: "The view of the heatmap doesn't actually change anything … Remove that. Then make the heatmap view actually
//          show/hide the actual heatmap on the model. Turning it on should show all the Groups' heatmap (not just the face
//          selected). Holding it down for 3 seconds allows for all heatmaps across all groups/faces." … "Add a play-button
//          view to show the animation play-bar or not."
//   img4: "There should also be a 'bend' icon view. This should show the entire group's bend at the full depth - all
//          together. It should be the two opposing sides of a squish that show. It can be turned on with other views, but
//          it should also be able to be turned on on its own, showing the entire 3d model at its full squish depth."
//   img5: "Please re-add the x-ray view icon."
// His answers, 2026-10-14: Play OFF on open — the model at REST until he taps Play (heat keeps its full-load values);
// Bend = EVERY face of the group bent at once at full depth, frozen; the heat tap / 3 s hold is on SETTINGS ONLY (the
// main page's Heat stays a plain on/off); Heat tap = the CURRENT group, hold 3 s = every group, tap again = hide.
// ★ SESSION DISPLAY STATE, SHARED BY BOTH PAGES: the new views are bits of `FlexibleStageModel.views` — never a
// setting, never the lattice's key, never an action (Exit stays "Exit") — so Play on one page is Play on the other.

import Foundation
import simd

/// The Settings page's Heat view: the CURRENT group's heat (his tap, and the look the page opens with), every group's
/// (his 3 s hold), or none.
public enum FlexibleHeatScope: Equatable, Sendable { case off, group, all }

extension FlexibleStageViews {
    /// ★ R7-V: Play — the sim plays and its bar shows (both pages; OFF on open).
    public static let play = FlexibleStageViews(rawValue: 1 << 2)
    /// ★ R7-V: the Settings page's Heat HIDDEN (his tap on a shown heat). An "off" bit so the page opens with the current
    /// group's heat (today's look) without a first-open flag.
    public static let heatOff = FlexibleStageViews(rawValue: 1 << 3)
    /// ★ R7-V: every group's heat (his 3 s hold).
    public static let heatAll = FlexibleStageViews(rawValue: 1 << 4)
    /// ★ R7-V: Bend — the current group bent at full depth, every face of it at once, frozen (Settings).
    public static let bend = FlexibleStageViews(rawValue: 1 << 5)

    /// The Heat view's scope.
    public var heatScope: FlexibleHeatScope {
        if contains(.heatOff) { return .off }
        return contains(.heatAll) ? .all : .group
    }
    /// His TAP on Heat: hidden → the current group's; shown (the group's or every group's) → hidden.
    public mutating func heatTapped() {
        if heatScope == .off { remove(.heatOff); remove(.heatAll) } else { insert(.heatOff); remove(.heatAll) }
    }
    /// His 3 s HOLD on Heat: every group's.
    public mutating func heatHeld() {
        remove(.heatOff); insert(.heatAll)
    }
}

/// ★ R7-V (4c): which pressed regions the Settings page's heat colours — his Heat view's scope over the open group.
@MainActor
enum FlexibleStageHeat {
    /// The open group's regions (the one that plays — FlexibleStageModel.playingGroup): a faces group's faces, an
    /// edges/corners group's strips and patches (no stacks until AP9 — no heat yet).
    static func groupRegions(_ m: FlexibleStageModel) -> Set<Int> {
        guard let g = m.playingGroup else { return [] }
        return Set(g.kind == .edges ? g.presses.flatMap { m.press($0)?.regions ?? [] } : g.regions)
    }
    /// The heat's filter for FlexiblePageChannels: none (every region — his hold), the open group's, or nothing (hidden).
    static func filter(model m: FlexibleStageModel, views: FlexibleStageViews) -> Set<Int>? {
        switch views.heatScope {
        case .all: return nil
        case .group: return groupRegions(m)
        case .off: return []
        }
    }
    /// The pressed regions whose heat the page draws now (each with a stack — a map to colour).
    static func shown(model m: FlexibleStageModel, views: FlexibleStageViews) -> Set<Int> {
        let f = filter(model: m, views: views)
        return Set(m.settings.loadedFaces.map(\.faceRegionID).filter { r in
            (f?.contains(r) ?? true) && m.key(r).flatMap { m.stacks[$0] } != nil
        })
    }
}

/// ★ R7-V (4i): Bend with Play — the bar animates, and the full-depth pose shows as a faint glass ghost (his img4: "It can
/// be turned on with other views"): the page's overlay at its displacements × k, drawn through MetalMeshView's GLASS
/// pass (front faces only, no outline). Cached per (overlay, dents, k) — the page refreshes often.
@MainActor
enum FlexibleBendGhost {
    static let faceAlpha: Float = 0.14
    static let tint = SIMD3<Float>(0.86, 0.90, 0.98)
    private static var cache: (key: String, item: ClearanceRenderItem?)?

    /// The ghost of `overlay` bent by `dents` (mm per flat vertex) × `k`; nil with no dent.
    static func item(overlay o: FlexibleOverlayMesh?, dents: [Float]?, k: Double) -> ClearanceRenderItem? {
        guard let o, let d = dents, k > 0 else { return nil }
        let pos = o.mesh.flat.positions
        let n = min(pos.count, d.count) / 3
        guard n >= 3 else { return nil }
        var h = Hasher()
        h.combine(n); h.combine(k)
        let step = max(1, d.count / 64)
        var i = 0
        while i < d.count { h.combine(d[i]); i += step }
        let key = "\(o.mesh.signature.contentHash)|\(h.finalize())"
        if let c = cache, c.key == key { return c.item }
        var base = [SIMD3<Float>](repeating: .zero, count: n)
        var volume = 0.0
        for v in 0..<n {
            base[v] = SIMD3(pos[3 * v], pos[3 * v + 1], pos[3 * v + 2]) + SIMD3(d[3 * v], d[3 * v + 1], d[3 * v + 2]) * Float(k)
        }
        var t = 0
        while t + 2 < n {
            let a = SIMD3<Double>(base[t]), b = SIMD3<Double>(base[t + 1]), c = SIMD3<Double>(base[t + 2])
            volume += simd_dot(a, simd_cross(b, c))
            t += 3
        }
        // wound so the renderer's front face is seen from OUTSIDE the part (FlexibleGroupWalls' convention)
        let outwardCCW = volume >= 0
        var idx: [UInt32] = []
        idx.reserveCapacity(n - n % 3)
        t = 0
        while t + 2 < n {
            let keep = outwardCCW == FlexibleGroupWalls.frontIsCounterClockwiseFromOutside
            idx += keep ? [UInt32(t), UInt32(t + 1), UInt32(t + 2)] : [UInt32(t), UInt32(t + 2), UInt32(t + 1)]
            t += 3
        }
        let shell = FaceOffsetShell(base: base, offset: base, indices: idx, reachedDepthMM: 0)
        let item = ClearanceRenderItem(volume: .shell(faceID: -1, shell: shell), selected: false, tint: tint,
                                       faceAlpha: faceAlpha, edgeAlpha: 0, surfaceOnly: true)
        cache = (key, item)
        return item
    }
}
