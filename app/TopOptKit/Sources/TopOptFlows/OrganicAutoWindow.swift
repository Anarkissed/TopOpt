import Foundation
import simd
import TopOptKit

/// ★★ THE ORGANIC WINDOW UNDER AUTO, FROM CORE'S OWN BAND (maintainer, 2026-09-06:
/// "auto cell grade looked incredibly sparse — is it using the octet preview
/// settings?" It was). With nothing picked the job carries no numbers and core decides
/// in the run from `organic_recommend_band`; the preview asks that same function,
/// through the bridge, with the rows the run builds: per include region its depth, its
/// shortest in-plane extent, and the p50/p99 of the solve's von Mises over its voxels.
/// The choice among the band's candidates follows the run's rule: Aesthetic takes the
/// look pair, Structural the band. Nothing is derived here; the numbers are core's.
public enum OrganicAutoWindow {

    /// The rows the run builds (run_job.cpp `[recommend]`), from the app's regions and
    /// the solve's tensor.
    /// ★ THE PLAN IS PASSED IN, NEVER REBUILT (his walk, 2026-09-07: a bake stage that
    /// reports 0.3 s of bridge work took 124 s). `OrganicSyntheticStress.plan` tags every
    /// voxel by point-in-polygon against each face's outline — on his part that is
    /// millions of voxels against 63-vertex loops — and it was being built TWICE per
    /// bake: once here for the band's stress percentiles, once for the synthesis.
    public static func rows(regions: [LatticeRegionSpec], input: LatticeOrganicInput,
                            plan: OrganicSyntheticStress.Plan)
        -> [TopOptKit.OrganicRecommendRegionRow] {
        let includes = regions.filter { $0.role == .include && $0.isValid }
        guard !includes.isEmpty else { return [] }
        let n = input.dims.0 * input.dims.1 * input.dims.2
        var vmByRegion = [[Double]](repeating: [], count: includes.count)
        if plan.regionIDs.count == n, input.tensor.count == 6 * n {
            for i in 0..<n {
                let id = Int(plan.regionIDs[i])
                guard id >= 1, id <= includes.count else { continue }
                let vm = OrganicSyntheticStress.vonMises(input.tensor, at: i)
                if vm > 0 { vmByRegion[id - 1].append(vm) }
            }
        }
        var out: [TopOptKit.OrganicRecommendRegionRow] = []
        for (k, r) in includes.enumerated() {
            var vm = vmByRegion[k]; vm.sort()
            let p50 = vm.isEmpty ? 0 : vm[vm.count / 2]
            let p99 = vm.isEmpty ? 0 : vm[Int(0.99 * Double(vm.count - 1))]
            out.append(.init(faceID: r.faceID ?? -1, depthMM: r.depthMM,
                             extentShortMM: shortestExtentMM(r), stressP50: p50, stressP99: p99))
        }
        return out
    }

    /// The shortest in-plane extent of a face: its outline's bounding box, else the
    /// primitive's own rectangle; a bolt's diameter.
    public static func shortestExtentMM(_ r: LatticeRegionSpec) -> Double {
        switch r.kind {
        case .face:
            if let first = r.outlineLoops.first, !first.isEmpty {
                var mn = SIMD2<Double>(repeating: .greatestFiniteMagnitude)
                var mx = SIMD2<Double>(repeating: -.greatestFiniteMagnitude)
                for p in first { mn = simd_min(mn, p); mx = simd_max(mx, p) }
                return Swift.min(mx.x - mn.x, mx.y - mn.y)
            }
            return 2 * Swift.min(r.halfUMM, r.halfWMM)
        case .bolt:
            return 2 * r.radiusMM
        }
    }

    /// ★ THE ROWS WITHOUT THE STRESS PERCENTILES — depth and extent come from the
    /// region itself, and only `grade_ratio` needs the field. Cheap enough to run on
    /// the main actor while a control moves, which is what the Look slider needs.
    public static func rowsWithoutStress(_ regions: [LatticeRegionSpec])
        -> [TopOptKit.OrganicRecommendRegionRow] {
        regions.filter { $0.role == .include && $0.isValid }.map {
            .init(faceID: $0.faceID ?? -1, depthMM: $0.depthMM,
                  extentShortMM: shortestExtentMM($0), stressP50: 0, stressP99: 0)
        }
    }

    /// ★★★ THE LOOK SLIDER, IN CORE'S OWN BAND (his instruction, 2026-09-07: "It should
    /// be a percentage value on a slider. 1% is the largest cell across the width
    /// possible, 100% is the smallest cells possible (before printability is lost)").
    ///
    /// The band's ceiling is the largest cell that fits the wall; its floor is the
    /// smallest core will print at this bead and grid. 1 % takes the ceiling, 100 % the
    /// floor, linearly between. The window keeps a grading spread so the cell still
    /// follows the stress, clamped inside the band.
    public static func window(percent: Double, band: TopOptKit.OrganicRecommendBandResult)
        -> (lo: Double, hi: Double)? {
        guard !band.collapsed, band.loMM > 0, band.hiMM >= band.loMM else { return nil }
        let t = Swift.min(Swift.max((percent - 1) / 99, 0), 1)
        let cell = band.hiMM - t * (band.hiMM - band.loMM)
        let spread = Swift.max(1, band.gradeRatio)
        // ★★★ THE SLIDER'S NUMBER IS THE CEILING, NOT THE FLOOR (his walk, 2026-09-07:
        // "I have set it to be 50 %, that should give me 3.62 mm cells at 11 mm across —
        // that's about 3 cells — why aren't there 3 cells of depth?", and "I set the
        // depth to 100 % and it still doesn't go as far as it should").
        //
        // ★ THE WINDOW WAS OPENING UPWARDS. It returned `(cell, cell · spread)`, and the
        // preview maps demand onto it as `sep = hi − (hi − lo)·t` — so the COARSEST end
        // is what an idle voxel gets, and on a lightly loaded part that is nearly every
        // voxel. At a grading spread of 2 his 3.62 mm slider drew a 7.24 mm lattice:
        // one and a half cells through an 11 mm wall, and a half-cell empty margin at
        // every edge. The number the control promised was the one cell size that
        // appeared NOWHERE in the picture.
        //
        // ★ AND HIS OWN DEFINITION SETTLES WHICH END IT IS: "1 % is the largest cell
        // across the width possible, 100 % is the smallest cells possible". The slider
        // names the LARGEST cell the lattice may use; grading can only refine from
        // there, down to the band's floor. So the pair opens downwards, and the cell he
        // is shown is the coarsest thing on screen rather than the finest.
        return (Swift.max(band.loMM, cell / spread), cell)
    }

    /// The window the Look slider asks for, from the regions alone. nil when there is
    /// nothing declared or the band collapsed (no cell fits: the region goes solid).
    public static func lookWindow(percent: Double, regions: [LatticeRegionSpec],
                                  beadMM: Double, voxelMM: Double,
                                  lookCellsAcross: Double) -> (lo: Double, hi: Double)? {
        let rows = rowsWithoutStress(regions)
        guard !rows.isEmpty, beadMM > 0, voxelMM > 0,
              let b = TopOptKit.organicRecommendBand(
                  regions: rows, minExtrudableWidthMM: beadMM, voxelMM: voxelMM,
                  lookCellsAcross: lookCellsAcross,
                  steps: LatticeSettings.organicRecommendSteps) else { return nil }
        return window(percent: percent, band: b)
    }

    public static func band(regions: [LatticeRegionSpec], input: LatticeOrganicInput,
                            plan: OrganicSyntheticStress.Plan,
                            lookCellsAcross: Double,
                            steps: Int = LatticeSettings.organicRecommendSteps)
        -> TopOptKit.OrganicRecommendBandResult? {
        let r = rows(regions: regions, input: input, plan: plan)
        guard !r.isEmpty else { return nil }
        return TopOptKit.organicRecommendBand(regions: r, minExtrudableWidthMM: input.minExtrudableWidthMM,
                                              voxelMM: input.spacingMM, lookCellsAcross: lookCellsAcross,
                                              steps: steps)
    }

    /// The run's pick before any probe: Aesthetic ⇒ the look pair (else the look
    /// cell, else the band); Structural ⇒ the band. nil when the band collapsed.
    public static func window(from band: TopOptKit.OrganicRecommendBandResult, structural: Bool)
        -> (lo: Double, hi: Double)? {
        guard !band.collapsed, band.hiMM > 0, band.loMM > 0, band.hiMM >= band.loMM else { return nil }
        if !structural {
            if let p = band.candidates.first(where: { $0.source == "look_pair" }), p.loMM > 0, p.hiMM >= p.loMM {
                return (p.loMM, p.hiMM)
            }
            if let l = band.candidates.first(where: { $0.source == "look" }), l.loMM > 0 {
                return (l.loMM, Swift.max(l.loMM, l.hiMM))
            }
        }
        return (band.loMM, band.hiMM)
    }

}

/// ★ EVERYTHING AN ORGANIC BAKE READS, compared whole (see `buildStrutScene`). Its own
/// type rather than a tuple so it can be `Equatable` and so adding a term is one edit in
/// one place — the subset that forgets a term is the stale picture.
public struct OrganicBakeKey: Equatable, Sendable {
    public let region: Int
    /// The stage's solve. NOT a lattice setting, and the reason a rebake must not key on
    /// the settings alone: the first bake of a session runs before the solve lands.
    public let stress: Int
    /// How many tensor values reached the tracer. Organic needs the full Cauchy tensor,
    /// so "a field arrived" and "the tracer can run" are different questions.
    public let tensor: Int
    public let inputs: LatticeSettings
    public init(region: Int, stress: Int, tensor: Int, inputs: LatticeSettings) {
        self.region = region; self.stress = stress; self.tensor = tensor; self.inputs = inputs
    }
}
