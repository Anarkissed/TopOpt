// FlexibleGroupWalls — a squeeze group's GLASS on the Settings page (task 2026-09-29-flexible-screens,
// round 6, item 1; his img1: "I am seeing these edges all along the object - even when the heat map is
// turned off", and his answer: "Settings page only, BUT only when the group is selected or the all groups
// has been set. Also, make it a slightly visible wall with a TINT of the group colour").
//
// ★ WHAT REPLACES ROUND 5's FRAMES. The frames (FlexibleGroupFrames — a band of a face's outermost columns
// in the group colour) are painted nowhere now (only their red control paints them). On the Settings page
// the OPEN group — its rail tab `.group(id)`, or on [Model] the group of the selected pressed face — wears
// a faint tinted GLASS on each member region; [Rests] shows the resting faces' glass in Rests cyan; the
// Groups view (FlexibleStageViews.groups) shows every group's and Rests', the open one brighter. Nothing
// on [Model] with no face selected, nor on [+ New]. The main page wears no group colour at all.
// ★ THE GLASS: ONE layer on the member region's OWN outline (its sector cuts included —
// SurfacePatternAxis.clipPolygon, FlexibleMainPageLoads' clip), `epsMM` proud of the face along the
// welded, area-weighted normal; no offset layer, no skirt (so no doubled alpha, no vertical barcode).
// The renderer draws it FRONT FACES ONLY (MetalMeshView's GLASS buffer, cull .back) through the plain
// pass (no contact line, no occlusion darkening — a face-hugging layer would wash white): a member that
// faces away never tints the face in front of it through the X-ray; every member's OUTLINE draws, front
// and back. Every triangle is wound so the renderer's front face is seen from OUTSIDE the part
// (`frontIsCounterClockwiseFromOutside`, pinned on the GPU by FlexibleRound6Tests). DISPLAY geometry only:
// never an input to core.
// ★ R6 REVIEW (the verifier's findings, confirmed on his pad): (1) one alpha for every colour tinted nothing — his teal
// over the green heat moved ΔE76 3.0 at 0.08 — so each member's glass takes the alpha that moves the colour HE SEES there
// by about ΔE 20 toward its group's colour (`alphas`, over its own heat — `heatSamples`, the page's composed tints);
// (2) a member that faces AWAY (his [Rests] bottom from any camera above it) has its fill culled, and its 1 px outline
// ran along the part's own edges — the page draws it as a bold DASHED line in its colour (`outlines` →
// FlexibleStageViewTags.hidden), the hidden-line convention, so colours still never mix through the X-ray.
// ★ PAST EIGHT GROUPS (C5): the digits painted on the heat went with the frames; in the Groups view a
// group whose colour another group also wears (FlexibleGroupNumbers.shared) shows its number disc on
// each member's glass (`discs`; FlexibleStageViewTags places them on screen). One group shown: its tab
// names it, no disc.

import Foundation
import simd
import TopOptDesign
import TopOptKit

enum FlexibleGroupWalls {

    /// How far the glass stands proud of its face (mm).
    static let epsMM = 0.3
    /// ★ R6 REVIEW — THE GLASS'S ALPHA IS ITS COLOUR'S OVER ITS OWN HEAT (the verifier, confirmed on his pad: at ONE
    /// alpha for every colour, 0.08, his teal Group 3 over the green heat moved its face ΔE76 3.0 and his green Group 1
    /// over the blue top 8.5 — no tint; the Groups view looked unchanged; and no single alpha serves both: teal reads
    /// ΔE 10 only at 0.28, where green on the blue top is ΔE 40). Each member's glass takes the alpha that moves the
    /// colour he sees there by about `targetDE` toward its group's colour — "slightly visible … with a TINT" for every
    /// colour over every heat: alpha = targetDE / the median ΔE between its colour and its face's own heat (the page's
    /// composed tints, `heatSamples`), within [`minAlpha`, `maxAlpha`]; the OPEN group in the Groups view
    /// `openTargetDE` (brighter), up to `maxOpenAlpha`. TRUE opacities (MetalMeshView's GLASS pass pushes them
    /// straight). The renderer's lighting dims a face below its vertex colour, so the screen moves less than the
    /// estimate (on his pad 0.58–0.86 of it: least for his dark teal over the green heat): 21 is the target that brings
    /// that worst case to ΔE 12 at the cap. Measured on his pad by FlexibleRound6Tests (R6R-1: ΔE ≥ 10 toward its own
    /// colour, ≤ 32; the spec's 15 left his teal at 8.8).
    static let targetDE = 21.0
    static let openTargetDE = 28.0
    static let minAlpha: Float = 0.06
    /// The most a glass may hide of the heat under it (a tab's; the open group's in the Groups view).
    static let maxAlpha: Float = 0.35
    static let maxOpenAlpha: Float = 0.45
    /// The outline's alphas (every member's, front and back).
    static let edgeAlpha: Float = 0.40
    static let openEdgeAlpha: Float = 0.60
    /// What a member with no heat of its own is seen over (a resting face: the X-ray's ghost on the page's ground).
    static let backdrop = SIMD3<Float>(Float(DS.Color.background.r), Float(DS.Color.background.g), Float(DS.Color.background.b))
    /// How many of a region's heat colours `heatSamples` keeps (evenly spaced).
    static let heatSampleCount = 256
    /// The welding key (mm).
    static let weldMM = 1e-4
    /// The renderer's front face, seen from OUTSIDE the part (Metal's default winding, read in its y-up clip
    /// space): pinned on the GPU by FlexibleRound6Tests (R6-1d's reversed-winding control).
    static let frontIsCounterClockwiseFromOutside = false

    /// Test controls only: every group walled whatever is open; every group numbered once there are
    /// more groups than colours (the count rule, not the shared-colour rule).
    @MainActor static var controlEveryGroup = false
    @MainActor static var controlNumberByCount = false

    /// One walled group: its key ("group-N" / "rests"), its colour, its regions, and whether it is the open one.
    struct Shown: Equatable {
        let key: String
        let colour: RGBA
        let regions: [Int]
        let open: Bool
    }

    /// A number disc on a member's glass (the Groups view, a group whose colour another also wears).
    struct Disc: Equatable {
        let number: Int
        let colour: RGBA
        let region: Int
        let anchor: SIMD3<Float>
        let normal: SIMD3<Float>
    }

    // MARK: - the geometry (pure)

    /// The glass over `region`: its part triangles clipped to its cuts and fanned, welded on `weldMM`,
    /// each point `epsMM` out along the area-weighted normal (outward: the part's own orientation, read from
    /// its signed volume), every triangle wound front-out. nil when the region has no surface.
    /// `ignoringCuts` / `welded: false` are the red controls (the whole face; every edge an outline).
    static func shell(region: Int, regions: FlexibleRegions, mesh: ViewerMesh, epsMM: Double = epsMM,
                      ignoringCuts: Bool = false, welded: Bool = true) -> FaceOffsetShell? {
        let faces = Set(regions.faces(of: region, mesh: mesh).map { Int32($0) })
        guard !faces.isEmpty, !mesh.indices.isEmpty else { return nil }
        let cuts = ignoringCuts ? [] : regions.cuts(of: region)
        func point(_ i: UInt32) -> SIMD3<Double> {
            let b = Int(i) * 3
            return SIMD3(Double(mesh.positions[b]), Double(mesh.positions[b + 1]), Double(mesh.positions[b + 2]))
        }
        var pts: [SIMD3<Double>] = []
        var index: [SIMD3<Int64>: Int] = [:]
        func vertex(_ p: SIMD3<Double>) -> Int {
            guard welded else { pts.append(p); return pts.count - 1 }
            let key = SIMD3<Int64>(Int64((p.x / weldMM).rounded()), Int64((p.y / weldMM).rounded()), Int64((p.z / weldMM).rounded()))
            if let i = index[key] { return i }
            pts.append(p)
            index[key] = pts.count - 1
            return pts.count - 1
        }
        var tris: [(Int, Int, Int)] = []
        var volume = 0.0   // the part's signed volume ×6: positive when its triangles wind outward
        for t in 0..<mesh.triangleCount {
            let tri = [point(mesh.indices[3 * t]), point(mesh.indices[3 * t + 1]), point(mesh.indices[3 * t + 2])]
            volume += simd_dot(tri[0], simd_cross(tri[1], tri[2]))
            guard t < mesh.faceIDs.count, faces.contains(mesh.faceIDs[t]) else { continue }
            let poly = cuts.isEmpty ? tri : SurfacePatternAxis.clipPolygon(tri, to: cuts)
            guard poly.count >= 3 else { continue }
            let ids = poly.map(vertex)
            for i in 1..<(ids.count - 1) where ids[0] != ids[i] && ids[i] != ids[i + 1] && ids[0] != ids[i + 1] {
                tris.append((ids[0], ids[i], ids[i + 1]))
            }
        }
        guard !tris.isEmpty else { return nil }
        let outward: Double = volume < 0 ? -1 : 1
        var normal = [SIMD3<Double>](repeating: .zero, count: pts.count)
        for (a, b, c) in tris {
            let n = simd_cross(pts[b] - pts[a], pts[c] - pts[a]) * outward   // |n| = twice the area: area-weighted
            normal[a] += n; normal[b] += n; normal[c] += n
        }
        let base = pts.indices.map { i -> SIMD3<Float> in
            let n = simd_length(normal[i]) > 1e-12 ? simd_normalize(normal[i]) : .zero
            return SIMD3<Float>(pts[i] + n * epsMM)
        }
        var idx: [UInt32] = []
        idx.reserveCapacity(tris.count * 3)
        for (a, b, c) in tris {
            // counter-clockwise from outside ⇔ the triangle's own normal points out
            let ccw = simd_dot(simd_cross(pts[b] - pts[a], pts[c] - pts[a]), normal[a] + normal[b] + normal[c]) > 0
            idx += ccw == frontIsCounterClockwiseFromOutside ? [UInt32(a), UInt32(b), UInt32(c)] : [UInt32(a), UInt32(c), UInt32(b)]
        }
        return FaceOffsetShell(base: base, offset: base, indices: idx, reachedDepthMM: 0)
    }

    /// A shell's area centroid and its area-weighted outward normal (a disc's place).
    static func centroid(_ s: FaceOffsetShell) -> (point: SIMD3<Float>, normal: SIMD3<Float>)? {
        var acc = SIMD3<Double>.zero, area = 0.0, n = SIMD3<Double>.zero
        var k = 0
        while k + 2 < s.indices.count {
            let p = (0..<3).map { SIMD3<Double>(s.base[Int(s.indices[k + $0])]) }
            let c = simd_cross(p[1] - p[0], p[2] - p[0])
            let a = simd_length(c) / 2
            acc += (p[0] + p[1] + p[2]) / 3 * a
            area += a
            n += c
            k += 3
        }
        guard area > 1e-12, simd_length(n) > 1e-12 else { return nil }
        let out = simd_normalize(n) * (frontIsCounterClockwiseFromOutside ? 1 : -1)
        return (SIMD3<Float>(acc / area), SIMD3<Float>(out))
    }

    /// ★ R6 REVIEW: a shown member's outline (model space), its centroid and outward normal.
    struct Outline: Equatable {
        let key: String
        let colour: RGBA
        let region: Int
        let loops: [[SIMD3<Float>]]
        let point: SIMD3<Float>
        let normal: SIMD3<Float>
    }
    /// ★ R6 REVIEW: a shell's boundary (the edges one triangle uses) chained into closed loops, in its base's points —
    /// the dashed outline of a member that faces away (FlexibleStageViewTags.hidden).
    static func loops(_ s: FaceOffsetShell) -> [[SIMD3<Float>]] {
        var use: [UInt64: Int] = [:], dir: [UInt64: (UInt32, UInt32)] = [:]
        var k = 0
        while k + 2 < s.indices.count {
            for e in 0..<3 {
                let a = s.indices[k + e], b = s.indices[k + (e + 1) % 3]
                let key = a < b ? (UInt64(a) << 32 | UInt64(b)) : (UInt64(b) << 32 | UInt64(a))
                use[key, default: 0] += 1
                dir[key] = (a, b)
            }
            k += 3
        }
        var next: [UInt32: [UInt32]] = [:]
        for (key, n) in use where n == 1 { if let (a, b) = dir[key] { next[a, default: []].append(b) } }
        for a in next.keys { next[a]!.sort() }
        var out: [[SIMD3<Float>]] = []
        for start in next.keys.sorted() {
            while let first = next[start]?.first {
                next[start]!.removeFirst()
                var loop: [SIMD3<Float>] = [s.base[Int(start)]]
                var v = first
                var guardSteps = use.count + 1
                while v != start, guardSteps > 0, let n = next[v]?.first {
                    loop.append(s.base[Int(v)])
                    next[v]!.removeFirst()
                    v = n
                    guardSteps -= 1
                }
                if loop.count >= 3 { out.append(loop) }
            }
        }
        return out
    }

    // MARK: - what the page shows (the model's state)

    /// The groups walled now: the OPEN group (its rail tab; on [Model] the selected pressed face's group;
    /// [Rests]: the resting faces), or every group and Rests while the Groups view is on.
    @MainActor
    static func shown(model m: FlexibleStageModel, views: FlexibleStageViews) -> [Shown] {
        let rests = m.settings.faces.filter { !$0.isLoaded }.map(\.faceRegionID)
        var open: String?
        switch m.rail {
        case .group(let id): open = m.railGroup(id).map { "group-\($0.id)" }
        case .rests: open = rests.isEmpty ? nil : "rests"
        case .model:
            if let r = m.selectedRegion, m.settings.face(r)?.isLoaded == true, let g = m.squeezeGroup(of: r) { open = "group-\(g.id)" }
        case .newGroup: open = nil
        }
        let every = views.contains(.groups) || controlEveryGroup
        var out: [Shown] = []
        for g in m.squeezeGroups where !g.regions.isEmpty {
            let key = "group-\(g.id)"
            guard every || key == open else { continue }
            out.append(Shown(key: key, colour: m.groupColour(g), regions: g.regions, open: key == open))
        }
        if !rests.isEmpty, every || open == "rests" {
            out.append(Shown(key: "rests", colour: DS.Color.accentCyan, regions: rests, open: open == "rests"))
        }
        return out
    }

    /// ★ R6 REVIEW: a member's glass alphas over its heat (`heat`: its colours on the page; empty: the `backdrop`).
    nonisolated static func alphas(tint: SIMD3<Float>, heat: [SIMD3<Float>], open: Bool) -> (face: Float, edge: Float) {
        let t = lab(tint)
        let de = (heat.isEmpty ? [backdrop] : heat).map { Double(simd_length(lab($0) - t)) }.sorted()
        let median = de[de.count / 2]
        let cap = open ? maxOpenAlpha : maxAlpha
        let face = median > 1e-6 ? min(cap, max(minAlpha, Float((open ? openTargetDE : targetDE) / median))) : cap
        return (face, open ? openEdgeAlpha : edgeAlpha)
    }

    /// CIE L*a*b* (D65) of an sRGB colour (0…1) — a glass is judged as a colour change (ΔE76).
    nonisolated static func lab(_ c: SIMD3<Float>) -> SIMD3<Float> {
        func lin(_ v: Float) -> Float { v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
        let r = lin(c.x), g = lin(c.y), b = lin(c.z)
        let x = (0.4124 * r + 0.3576 * g + 0.1805 * b) / 0.95047
        let y = 0.2126 * r + 0.7152 * g + 0.0722 * b
        let z = (0.0193 * r + 0.1192 * g + 0.9505 * b) / 1.08883
        func f(_ v: Float) -> Float { v > 0.008856 ? cbrt(v) : 7.787 * v + 16 / 116 }
        return SIMD3(116 * f(y) - 16, 500 * (f(x) - f(y)), 200 * (f(y) - f(z)))
    }

    /// ★ R6 REVIEW: each pressed region's colours on the page — its map's column quads in the page's composed tints
    /// (`overlay.flatStart`, six flat vertices per column), at most `heatSampleCount`, evenly spaced. Taken where the
    /// page composes its tints (FlexibleStagePage.refreshChannels), never per frame.
    @MainActor
    static func heatSamples(tints: [Float]?, overlay: FlexibleOverlayMesh?, model m: FlexibleStageModel) -> [Int: [SIMD3<Float>]] {
        guard let t = tints, let o = overlay else { return [:] }
        var out: [Int: [SIMD3<Float>]] = [:]
        for f in m.settings.loadedFaces {
            let r = f.faceRegionID
            guard let key = m.key(r), let start = o.flatStart[key], let n = m.stacks[key]?.columns.count, n > 0 else { continue }
            let count = 6 * n, step = max(1, count / heatSampleCount)
            var cs: [SIMD3<Float>] = []
            var v = start
            while v < start + count, v * 8 + 2 < t.count {
                cs.append(SIMD3(t[v * 8], t[v * 8 + 1], t[v * 8 + 2]))
                v += step
            }
            if !cs.isEmpty { out[r] = cs }
        }
        return out
    }

    /// A short signature of `heatSamples` (a cache key: the page asks on every body pass).
    nonisolated static func signature(_ heat: [Int: [SIMD3<Float>]]) -> String {
        heat.keys.sorted().map { r -> String in
            let sum = heat[r]!.reduce(SIMD3<Float>.zero, +)
            return String(format: "%d:%d:%.4f,%.4f,%.4f", r, heat[r]!.count, sum.x, sum.y, sum.z)
        }.joined(separator: ";")
    }

    /// Each shown member's glass for MetalMeshView's clearance pass (GLASS: alphas set, surface only).
    /// Cached: the shells per (part, sectors, region); the list per (shown, views).
    @MainActor
    static func items(model m: FlexibleStageModel, views: FlexibleStageViews, mesh: ViewerMesh?,
                      heat: [Int: [SIMD3<Float>]] = [:]) -> [ClearanceRenderItem] {
        guard let mesh else { return [] }
        let shown = self.shown(model: m, views: views)
        guard !shown.isEmpty else { return [] }
        let regions = m.regions
        let scope = "\(mesh.signature.contentHash)|\(regions.key)"
        let key = scope + "|\(views.rawValue)|" + shown.map { "\($0.key):\($0.colour.r),\($0.colour.g),\($0.colour.b):\($0.regions):\($0.open)" }.joined(separator: ";")
            + "|" + signature(heat)
        if let c = Cache.items, c.key == key { return c.items }
        var out: [ClearanceRenderItem] = []
        for g in shown {
            let bright = g.open && views.contains(.groups)
            let tint = SIMD3<Float>(Float(g.colour.r), Float(g.colour.g), Float(g.colour.b))
            for r in g.regions {
                guard let s = cachedShell(r, scope: scope, regions: regions, mesh: mesh) else { continue }
                let a = alphas(tint: tint, heat: heat[r] ?? [], open: bright)
                out.append(ClearanceRenderItem(volume: .shell(faceID: r, shell: s), selected: false, tint: tint,
                                               faceAlpha: a.face, edgeAlpha: a.edge, surfaceOnly: true))
            }
        }
        Cache.items = (key, out)
        return out
    }

    /// The Groups view's number discs: a group whose colour another group also wears (past the eighth),
    /// one disc per member, at its glass's area centroid. None outside the Groups view.
    @MainActor
    static func discs(model m: FlexibleStageModel, views: FlexibleStageViews, mesh: ViewerMesh?) -> [Disc] {
        guard views.contains(.groups), let mesh else { return [] }
        let gs = m.squeezeGroups
        let numbered: Set<Int> = controlNumberByCount
            ? (gs.count > FlexibleGroupColour.allCases.count ? Set(gs.map(\.number)) : [])
            : FlexibleGroupNumbers.shared(in: m.settings)
        guard !numbered.isEmpty else { return [] }
        let regions = m.regions
        let scope = "\(mesh.signature.contentHash)|\(regions.key)"
        var out: [Disc] = []
        for g in gs where numbered.contains(g.number) {
            for r in g.regions {
                guard let s = cachedShell(r, scope: scope, regions: regions, mesh: mesh), let c = centroid(s) else { continue }
                out.append(Disc(number: g.number, colour: m.groupColour(g), region: r, anchor: c.point, normal: c.normal))
            }
        }
        return out
    }

    /// ★ R6 REVIEW: each shown member's outline loops, centroid and outward normal (cached like the glass).
    @MainActor
    static func outlines(model m: FlexibleStageModel, views: FlexibleStageViews, mesh: ViewerMesh?) -> [Outline] {
        guard let mesh else { return [] }
        let shown = self.shown(model: m, views: views)
        guard !shown.isEmpty else { return [] }
        let regions = m.regions
        let scope = "\(mesh.signature.contentHash)|\(regions.key)"
        let key = scope + "|" + shown.map { "\($0.key):\($0.colour.r),\($0.colour.g),\($0.colour.b):\($0.regions)" }.joined(separator: ";")
        if let c = Cache.outlines, c.key == key { return c.outlines }
        var out: [Outline] = []
        for g in shown {
            for r in g.regions {
                guard let s = cachedShell(r, scope: scope, regions: regions, mesh: mesh), let c = centroid(s) else { continue }
                out.append(Outline(key: g.key, colour: g.colour, region: r, loops: loops(s), point: c.point, normal: c.normal))
            }
        }
        Cache.outlines = (key, out)
        return out
    }

    // MARK: - the cache (main thread)

    @MainActor
    private enum Cache {
        static var scope: String?
        static var shells: [Int: FaceOffsetShell] = [:]
        static var items: (key: String, items: [ClearanceRenderItem])?
        static var outlines: (key: String, outlines: [Outline])?
    }

    @MainActor
    private static func cachedShell(_ r: Int, scope: String, regions: FlexibleRegions, mesh: ViewerMesh) -> FaceOffsetShell? {
        if Cache.scope != scope { Cache.scope = scope; Cache.shells = [:]; Cache.items = nil; Cache.outlines = nil }
        if let s = Cache.shells[r] { return s }
        guard let s = shell(region: r, regions: regions, mesh: mesh) else { return nil }
        Cache.shells[r] = s
        return s
    }
}
