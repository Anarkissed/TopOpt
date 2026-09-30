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

    /// The prism under a pressed face's columns: base = surface + load·ε, offset = base +
    /// load·k·depth. nil when the stack has no column.
    static func shell(stack st: FlexStackInfo, centres: [SIMD3<Double>], depthMM: Double, k: Double) -> FaceOffsetShell? {
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
        var index: [Key: UInt32] = [:]
        var base: [SIMD3<Float>] = [], offset: [SIMD3<Float>] = []
        let travel = st.load * (k * depthMM)
        for key in sum.keys.sorted(by: { ($0.v, $0.u) < ($1.v, $1.u) }) {
            let q = sum[key]! / Double(count[key]!) + st.load * insetMM
            index[key] = UInt32(base.count)
            base.append(SIMD3<Float>(q))
            offset.append(SIMD3<Float>(q + travel))
        }
        var idx: [UInt32] = []
        idx.reserveCapacity(st.columns.count * 6)
        for col in st.columns {
            guard let a = index[Key(u: col.iu, v: col.iv)], let b = index[Key(u: col.iu + 1, v: col.iv)],
                  let c = index[Key(u: col.iu + 1, v: col.iv + 1)], let d = index[Key(u: col.iu, v: col.iv + 1)] else { continue }
            // the overlay quad's winding: faces out of the part (along −load)
            idx += [a, c, b, a, d, c]
        }
        return FaceOffsetShell(base: base, offset: offset, indices: idx, reachedDepthMM: k * depthMM)
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

    /// One drag sample: raw mm → snapped (with the held detent) → clamped.
    static func resolve(rawMM: Double, latticeMM: Double, held: LatticeDepthDetent.Candidate?)
        -> (mm: Double, held: LatticeDepthDetent.Candidate?, didSnap: Bool) {
        let r = LatticeDepthDetent.resolve(rawMM: rawMM, candidates: candidates(latticeMM: latticeMM), current: held)
        return (clamp(r.mm, latticeMM: latticeMM), r.snapped, r.didSnap)
    }

    /// The prism the Settings page draws: the SELECTED pressed face's, in the Flexible accent.
    @MainActor
    static func renderItems(model: FlexibleStageModel, k: Double) -> [ClearanceRenderItem] {
        guard let r = model.selectedRegion, let f = model.settings.face(r), f.isLoaded,
              let key = model.key(r), let st = model.stacks[key], let g = model.geometry[key], k > 0,
              let v = volume(region: r, stack: st, centres: g.centres, depthMM: f.deepestMM, k: k) else { return [] }
        let t = FlexibleStageStyle.accentToken
        return [ClearanceRenderItem(volume: v, selected: true, tint: SIMD3<Float>(Float(t.r), Float(t.g), Float(t.b)))]
    }
}
