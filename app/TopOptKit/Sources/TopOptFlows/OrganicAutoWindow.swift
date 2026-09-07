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
    public static func rows(regions: [LatticeRegionSpec], input: LatticeOrganicInput)
        -> [TopOptKit.OrganicRecommendRegionRow] {
        let includes = regions.filter { $0.role == .include && $0.isValid }
        guard !includes.isEmpty else { return [] }
        let plan = OrganicSyntheticStress.plan(regions: regions, dims: input.dims,
                                               originMM: input.originMM, spacingMM: input.spacingMM,
                                               defaultFoci: 4, statedFoci: [:])
        let n = input.dims.0 * input.dims.1 * input.dims.2
        var vmByRegion = [[Double]](repeating: [], count: includes.count)
        if plan.regionIDs.count == n, input.tensor.count == 6 * n {
            for i in 0..<n {
                let id = Int(plan.regionIDs[i])
                guard id >= 1, id <= includes.count else { continue }
                let vm = vonMises(input.tensor, at: i)
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

    public static func band(regions: [LatticeRegionSpec], input: LatticeOrganicInput,
                            lookCellsAcross: Double,
                            steps: Int = LatticeSettings.organicRecommendSteps)
        -> TopOptKit.OrganicRecommendBandResult? {
        let r = rows(regions: regions, input: input)
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

    /// Von Mises from a Voigt tensor [xx, yy, zz, xy, yz, zx] with true shear.
    static func vonMises(_ t: [Double], at i: Int) -> Double {
        let o = 6 * i
        let sxx = t[o], syy = t[o + 1], szz = t[o + 2], sxy = t[o + 3], syz = t[o + 4], szx = t[o + 5]
        let a = (sxx - syy) * (sxx - syy) + (syy - szz) * (syy - szz) + (szz - sxx) * (szz - sxx)
        let b = 3 * (sxy * sxy + syz * syz + szx * szx)
        return (0.5 * a + b).squareRoot()
    }
}
