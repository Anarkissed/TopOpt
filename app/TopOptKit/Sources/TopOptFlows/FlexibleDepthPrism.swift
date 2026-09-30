// FlexibleDepthPrism — "Deepest squish = a prism you drag out" (task
// 2026-09-29-flexible-screens, round 3, item 1.1).
//
// ★ WHAT IT IS. The selected pressed face's footprint — its stack's own column grid, so it
// is exactly the heat map's footprint and a split sector's prism stops at the cut — pushed
// INTO the part along the load (core's R13 frame) by the deepest squish × k, the page's one
// exaggeration. The dent bottoms out on the prism's floor. Drawn by MetalMeshView's
// clearance-volume pass (`clearanceVolumes:`), in the Flexible accent (never violet).
//
// ★ SHARED CORNERS, NOT A QUAD PER COLUMN. Each grid corner is the mean of the columns that
// touch it, so the shell's skirt forms on the footprint's outline only (a quad per column
// would put a skirt round every column and multiply the cost by ~4 on a 2k-column face).
// ★ AND ON A FLAT FACE, ONLY THE OUTLINE'S CORNERS (verification of round 3): the clearance
// pass draws a skirt edge at EVERY boundary vertex, so a vertex every column pitch (2 mm)
// turned the prism's walls into a barcode of ~150 lines that buried the bent map. A flat
// footprint is cut into the fewest grid rectangles (greedy), each fanned from its centre
// through every rectangle corner on its sides (so neighbours share every sub-edge, no
// T-junction), and the skirt stands only where the outline turns. A curved face keeps the
// per-corner grid (its base must follow the surface).
// ★ DRAWN ONLY WHILE THE CHIP IS DRAGGED (verification of round 3): at rest a prism × k
// filled ~90 % of his pad under the face and hid the dent it measures.
//
// ★ THE DRAG. The handle is the shell's own `.slabDepth` ClearanceHandle (normal == load);
// its value under a MODEL-space ray (the page's projection already includes the settle) is
// the SHOWN depth, so the true mm is value / k, with k frozen at drag start. Snaps: 0.5 mm
// steps and the lattice depth (LatticeDepthDetent, never `.certifies` — Flexible has no
// certificate); clamped to 0.5 mm … the lattice depth. Any footprint polygon works, so a
// stamp's outline can reuse it (batch D).
//
// Pure value math — FlexibleDepthPrismTests.

import Foundation
import simd
import TopOptKit

enum FlexibleDepthPrism {

    /// The base sits this far inside the face, so the heat map (lifted 0.05 mm out) stays readable.
    static let insetMM = 0.05
    /// The shallowest squish a drag can set (core refuses ≤ 0).
    static let minMM = 0.5
    /// The drag's round detents.
    static let stepMM = 0.5

    /// A footprint whose corners lie within this of one plane across the load is flat.
    static let flatToleranceMM = 0.02

    /// The prism under a pressed face's columns: base = surface + load·ε, offset = base +
    /// load·k·depth. nil when the stack has no column. `flatOutline` false keeps the per-corner
    /// grid on a flat face too (the tests' control).
    static func shell(stack st: FlexStackInfo, centres: [SIMD3<Double>], depthMM: Double, k: Double,
                      flatOutline: Bool = true) -> FaceOffsetShell? {
        guard !st.columns.isEmpty, centres.count == st.columns.count, st.pitchMM > 0 else { return nil }
        struct Key: Hashable { let u: Int; let v: Int }
        var sum: [Key: SIMD3<Double>] = [:], count: [Key: Int] = [:]
        let h = st.pitchMM / 2
        for (c, col) in st.columns.enumerated() {
            let p = centres[c] + st.load * col.entryT
            for (du, dv) in [(0, 0), (1, 0), (1, 1), (0, 1)] {
                let q = p + st.xAxis * (Double(2 * du - 1) * h) + st.yAxis * (Double(2 * dv - 1) * h)
                let key = Key(u: col.iu + du, v: col.iv + dv)
                sum[key, default: .zero] += q
                count[key, default: 0] += 1
            }
        }
        var corner: [Key: SIMD3<Double>] = [:]
        for (key, p) in sum { corner[key] = p / Double(count[key]!) + st.load * insetMM }
        let travel = st.load * (k * depthMM)
        var base: [SIMD3<Float>] = [], offset: [SIMD3<Float>] = []
        func vertex(_ q: SIMD3<Double>) -> UInt32 {
            base.append(SIMD3<Float>(q)); offset.append(SIMD3<Float>(q + travel))
            return UInt32(base.count - 1)
        }
        var idx: [UInt32] = []
        let along = corner.values.map { simd_dot($0, st.load) }
        if flatOutline, (along.max() ?? 0) - (along.min() ?? 0) <= flatToleranceMM {
            // ── FLAT: the fewest rectangles, fanned from their centres ──
            let cells = Set(st.columns.map { Key(u: $0.iu, v: $0.iv) })
            let rects = Self.rectangles(cells.map { ($0.u, $0.v) })
            var cornerKeys = Set<Key>()
            for r in rects { for (u, v) in [(r.u0, r.v0), (r.u1, r.v0), (r.u1, r.v1), (r.u0, r.v1)] { cornerKeys.insert(Key(u: u, v: v)) } }
            var index: [Key: UInt32] = [:]
            for key in cornerKeys.sorted(by: { ($0.v, $0.u) < ($1.v, $1.u) }) {
                guard let q = corner[key] else { continue }
                index[key] = vertex(q)
            }
            let byV = Dictionary(grouping: cornerKeys, by: \.v), byU = Dictionary(grouping: cornerKeys, by: \.u)
            for r in rects {
                // every rectangle corner on this rectangle's sides, counter-clockwise in (u, v)
                let bottom = (byV[r.v0] ?? []).filter { $0.u >= r.u0 && $0.u < r.u1 }.sorted { $0.u < $1.u }
                let right = (byU[r.u1] ?? []).filter { $0.v >= r.v0 && $0.v < r.v1 }.sorted { $0.v < $1.v }
                let top = (byV[r.v1] ?? []).filter { $0.u > r.u0 && $0.u <= r.u1 }.sorted { $0.u > $1.u }
                let left = (byU[r.u0] ?? []).filter { $0.v > r.v0 && $0.v <= r.v1 }.sorted { $0.v > $1.v }
                let loop = (bottom + right + top + left).compactMap { index[$0] }
                guard loop.count >= 3,
                      let a = corner[Key(u: r.u0, v: r.v0)], let b = corner[Key(u: r.u1, v: r.v0)],
                      let c = corner[Key(u: r.u1, v: r.v1)], let d = corner[Key(u: r.u0, v: r.v1)] else { continue }
                let centre = vertex((a + b + c + d) / 4)
                // the overlay quad's winding: faces out of the part (along −load)
                for i in loop.indices { idx += [centre, loop[(i + 1) % loop.count], loop[i]] }
            }
        } else {
            // ── CURVED: every grid corner, so the base follows the surface ──
            var index: [Key: UInt32] = [:]
            for key in corner.keys.sorted(by: { ($0.v, $0.u) < ($1.v, $1.u) }) { index[key] = vertex(corner[key]!) }
            idx.reserveCapacity(st.columns.count * 6)
            for col in st.columns {
                guard let a = index[Key(u: col.iu, v: col.iv)], let b = index[Key(u: col.iu + 1, v: col.iv)],
                      let c = index[Key(u: col.iu + 1, v: col.iv + 1)], let d = index[Key(u: col.iu, v: col.iv + 1)] else { continue }
                idx += [a, c, b, a, d, c]
            }
        }
        return FaceOffsetShell(base: base, offset: offset, indices: idx, reachedDepthMM: k * depthMM)
    }

    /// One grid rectangle [u0, u1) × [v0, v1) of columns (corner keys at its ends).
    struct Rect: Equatable { let u0: Int; let v0: Int; let u1: Int; let v1: Int }

    /// The column cells as the fewest greedy rectangles: widest run along u, then as many rows
    /// of that same run as are free. Exactly covers `cells`; no two overlap.
    static func rectangles(_ cells: [(Int, Int)]) -> [Rect] {
        struct C: Hashable { let u: Int; let v: Int }
        var free = Set(cells.map { C(u: $0.0, v: $0.1) })
        var out: [Rect] = []
        for c in free.sorted(by: { ($0.v, $0.u) < ($1.v, $1.u) }) where free.contains(c) {
            var u1 = c.u + 1
            while free.contains(C(u: u1, v: c.v)) { u1 += 1 }
            var v1 = c.v + 1
            while (c.u..<u1).allSatisfy({ free.contains(C(u: $0, v: v1)) }) { v1 += 1 }
            for v in c.v..<v1 { for u in c.u..<u1 { free.remove(C(u: u, v: v)) } }
            out.append(Rect(u0: c.u, v0: c.v, u1: u1, v1: v1))
        }
        return out
    }

    /// The vertices the clearance pass stands a skirt edge on: every vertex of a boundary edge
    /// (an edge used by exactly one triangle) — MetalMeshView's own rule, counted.
    static func skirtVertices(_ s: FaceOffsetShell) -> Int {
        var use: [UInt64: Int] = [:]
        var k = 0
        while k + 2 < s.indices.count {
            for e in 0..<3 {
                let a = s.indices[k + e], b = s.indices[k + (e + 1) % 3]
                use[a < b ? (UInt64(a) << 32 | UInt64(b)) : (UInt64(b) << 32 | UInt64(a)), default: 0] += 1
            }
            k += 3
        }
        var verts = Set<UInt32>()
        for (key, n) in use where n == 1 { verts.insert(UInt32(key >> 32)); verts.insert(UInt32(key & 0xFFFF_FFFF)) }
        return verts.count
    }

    static func volume(region: Int, stack: FlexStackInfo, centres: [SIMD3<Double>], depthMM: Double, k: Double) -> ClearanceVolume? {
        shell(stack: stack, centres: centres, depthMM: depthMM, k: k).map { ClearanceVolume.shell(faceID: region, shell: $0) }
    }

    /// The drag handle: a `.slabDepth` whose normal is the load; its anchor is the prism floor.
    static func handle(_ v: ClearanceVolume) -> ClearanceHandle? {
        ClearanceHandles.handles(for: v, boreRadiusMM: 0, axialSpan: nil).first { $0.role == .slabDepth }
    }

    /// The TRUE depth (mm) under a MODEL-space ray, k frozen at drag start.
    static func depth(handle: ClearanceHandle, rayOrigin: SIMD3<Float>, rayDir: SIMD3<Float>, k: Double) -> Double? {
        guard k > 0, let v = handle.value(rayOrigin: rayOrigin, rayDir: rayDir) else { return nil }
        return Double(v) / k
    }

    /// What the drag snaps to: every 0.5 mm, and the lattice depth (as deep as it can go).
    static func candidates(latticeMM: Double) -> [LatticeDepthDetent.Candidate] {
        var out: [LatticeDepthDetent.Candidate] = []
        var v = stepMM
        while v < latticeMM - 1e-9 { out.append(.init(mm: v, kind: .round)); v += stepMM }
        if latticeMM >= minMM { out.append(.init(mm: latticeMM, kind: .extent)) }
        return out
    }

    /// 0.5 mm … the lattice depth.
    static func clamp(_ mm: Double, latticeMM: Double) -> Double {
        max(minMM, min(max(minMM, latticeMM), mm))
    }

    /// ★ HOW DEEP ONE DRAG MAY GO with k frozen (verification of round 3): the prism floor
    /// (k × depth) stays inside every column's lattice — else a drag toward the lattice depth
    /// at × 4 drew a prism four lattices deep, out through the part. The lattice depth itself
    /// when k is 1; after release k is re-chosen for the new depth and the next drag goes on.
    static func dragLimit(stack st: FlexStackInfo, k: Double) -> Double {
        let shallowest = st.columns.map(\.latticeMM).filter { $0 > 0 }.min() ?? st.latticeMMMax
        return max(minMM, min(st.latticeMMMax, shallowest / max(1, k)))
    }

    /// One drag sample: raw mm → snapped (with the held detent) → clamped to `limitMM` (the
    /// lattice depth unless `dragLimit` is shallower, which then snaps as the extent).
    static func resolve(rawMM: Double, latticeMM: Double, limitMM: Double? = nil, held: LatticeDepthDetent.Candidate?)
        -> (mm: Double, held: LatticeDepthDetent.Candidate?, didSnap: Bool) {
        let limit = min(latticeMM, limitMM ?? latticeMM)
        var cands = candidates(latticeMM: latticeMM).filter { $0.mm <= limit + 1e-9 }
        if limit < latticeMM - 1e-9, limit >= minMM { cands.append(.init(mm: limit, kind: .extent)) }
        let r = LatticeDepthDetent.resolve(rawMM: rawMM, candidates: cands, current: held)
        return (clamp(r.mm, latticeMM: limit), r.snapped, r.didSnap)
    }

    /// The prism the Settings page draws: the SELECTED pressed face's, in the Flexible accent,
    /// and ONLY while its chip is dragged (`frozenExaggeration` set) — at rest the dent reads alone.
    @MainActor
    static func renderItems(model: FlexibleStageModel, k: Double) -> [ClearanceRenderItem] {
        guard model.frozenExaggeration != nil,
              let r = model.selectedRegion, let f = model.settings.face(r), f.isLoaded,
              let key = model.key(r), let st = model.stacks[key], let g = model.geometry[key], k > 0,
              let v = volume(region: r, stack: st, centres: g.centres, depthMM: f.deepestMM, k: k) else { return [] }
        let t = FlexibleStageStyle.accentToken
        return [ClearanceRenderItem(volume: v, selected: true, tint: SIMD3<Float>(Float(t.r), Float(t.g), Float(t.b)))]
    }
}
