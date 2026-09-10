import Foundation
import simd
import TopOptKit

/// ★ SYNTHETIC STRESSES FOR UNLOADED WALLS (maintainer, 2026-09-05; Aesthetic only).
///
/// A wall the load never reaches has NO field to trace: its principal directions
/// are rounding noise and the tracer faithfully follows garbage. Core gives such a
/// wall a synthetic focal load — `synthesize_focal_stress`, the same function the
/// run calls, with the same per-region config the job carries. Since 2026-09-06
/// the PREVIEW calls that function too (through the bridge): the app no longer
/// injects a field of its own, so preview and run cannot disagree on a dead wall.
///
/// This file PLANS the call (per-voxel region ids, per-region config) and READS
/// core's report back into per-wall verdicts for the Selections drawer.
public enum OrganicSyntheticStress {

    /// The run's dead fraction (run_job passes 0.02): below this share of the
    /// field's peak a voxel's real stress is noise and the synthetic field takes
    /// over, blended by a smoothstep.
    public static let deadFraction = 0.02
    /// A wall whose REAL share (1 − its synthetic share) is at least this is
    /// LOADED — foci are never allowed there (his rule, 2026-09-05).
    /// ★★★ WHAT MAKES A WALL "LOADED" (his walk, 2026-09-07: "One literally has ZERO
    /// stress on it … Why are they saying the same stress MPa?"). It was core's
    /// SYNTHESIS share — the fraction of the wall core replaced — and core's dead test
    /// is 2 % of the PART's peak, so on a lightly loaded part (0.024 MPa) a wall
    /// carrying a thousandth of the allowable still came back "88 % real". Worse, the
    /// row printed the PART's peak on every wall, so two walls read identically.
    ///
    /// The wall's own stress is the measure, and the app has the tensor: a wall whose
    /// p99 von Mises is under this fraction of the part's peak carries spill, not load,
    /// and may take foci. Core still decides how much it SYNTHESISES in the run — that
    /// gate is its own (see the handoff's core report) — but which walls are OFFERED is
    /// this app's question and it is now answered from the stress, not from core's
    /// answer to a different question.
    public static let loadedStressShare = 0.15

    /// ★★★ AND THE PART ITSELF HAS TO BE CARRYING SOMETHING (his walk, 2026-09-07:
    /// "One literally has ZERO stress on it — or something close to it, so I should be
    /// able to add the synthetic stresses!").
    ///
    /// A share of the part's PEAK only ranks the walls against each other. His stand
    /// peaks at 0.024 MPa against an allowable of 31 — the whole part is idle, and the
    /// back wall at 0.004 MPa is about one hundredth of one percent of allowable. It
    /// came back "loaded" for being 17 % of a very small number, which is not a
    /// statement about load at all. So the peak must ALSO clear this fraction of the
    /// material's allowable before any wall on the part can be called loaded.
    public static let partLoadedAllowableShare = 0.02

    /// ★★★ AN ABSOLUTE FLOOR UNDER THE DEAD TEST (his ruling, 2026-09-07: "I want you to
    /// change the dead test to 2% OR 0.005MPa - whichever comes first").
    ///
    /// Core's test is `thr = dead_fraction × peak`, purely relative. His stand peaks at
    /// 0.03 MPa against a 31 MPa allowable, so 2 % of the peak is 0.0006 MPa and a wall
    /// holding 0.004 MPa reads alive — foci accepted, nothing replaced. Whichever fires
    /// first now: the threshold is `max(0.02 × peak, this)`. The bridge converts it into
    /// core's own units (`max(fraction, mpa / peak)`) so `synthesize_focal_stress` runs
    /// exactly as written.
    ///
    /// ★ THE RUN STILL PASSES 0.02 AND HAS NO KEY FOR THIS (run_job.cpp:4118). Until
    /// core takes one, the preview synthesises on walls the run will not — named in the
    /// handoff rather than hidden here.
    public static let deadMPaFloor = 0.005

    /// A wall is offered foci when it is under the loaded share OR under this absolute
    /// stress — the same "whichever comes first" rule, so the row and core agree about
    /// which walls are dead.
    public static let unloadedMPaFloor = deadMPaFloor

    public static let loadedRealShare = 0.5
    public static let fociRange = 1...5

    public static func clampFoci(_ n: Int) -> Int {
        Swift.min(Swift.max(n, fociRange.lowerBound), fociRange.upperBound)
    }

    /// One wall's verdict, from core's report.
    public struct WallReport: Equatable, Sendable {
        public let key: String?
        public let faceID: Int?
        public let voxels: Int
        public let fullySynthetic: Int
        public let blended: Int
        public let foci: Int
        /// ★ The part's peak von Mises core measured against (MPa) — the denominator,
        /// core's own number so the app and core speak of one peak.
        public var partPeakMPa: Double = 0
        /// The material's allowable (MPa), so "loaded" can be an absolute statement and
        /// not only a ranking. 0 ⇒ unknown, and then the ranking is all there is.
        public var allowableMPa: Double = 0
        /// ★ THIS WALL's own stress (MPa): the p99 and the max of the von Mises over
        /// the wall's voxels, measured from the same tensor the tracer is handed.
        public var wallP99MPa: Double = 0
        public var wallMaxMPa: Double = 0
        /// The share of the part's peak this wall carries. Under `loadedStressShare`
        /// it is unloaded and may take foci.
        public var stressShare: Double {
            partPeakMPa > 0 ? wallP99MPa / partPeakMPa : 0
        }
        /// Is the PART carrying anything worth calling load?
        public var partIsLoaded: Bool {
            allowableMPa <= 0 || partPeakMPa >= partLoadedAllowableShare * allowableMPa
        }
        /// ★ WHICHEVER COMES FIRST (his ruling, 2026-09-07). A wall under the
        /// absolute floor is unloaded however it ranks against the part's peak — the
        /// same rule the dead test now uses, so the row and core's synthesis agree.
        public var carriesLoad: Bool {
            if wallP99MPa > 0, wallP99MPa < unloadedMPaFloor { return false }
            return partIsLoaded && stressShare >= loadedStressShare
        }
        /// The share of the wall that went synthetic (fully + half of blended).
        public var syntheticFraction: Double {
            voxels > 0 ? (Double(fullySynthetic) + 0.5 * Double(blended)) / Double(voxels) : 0
        }
        public var realShare: Double { 1 - syntheticFraction }
        /// ★ Unloaded by the WALL's own stress (2026-09-07), not by core's synthesis
        /// share. `realShare` stays on the report because the run's synthesis is still
        /// judged by core's own dead test, and the two numbers disagreeing is the
        /// finding, not a bug to be hidden.
        public var dead: Bool { voxels > 0 && !carriesLoad }
        public var injected: Int { fullySynthetic }
        public var statusText: String {
            if voxels == 0 { return "no material" }
            guard partPeakMPa > 0 else {
                return dead ? String(format: "unloaded · %.0f%% synthetic", 100 * syntheticFraction)
                            : String(format: "loaded · %.0f%% real", 100 * realShare)
            }
            // ★ TWO FACTS, NOTHING ELSE (his walk, 2026-09-07: "there is way too much
            // text in that area. Cut it down to its bare necessities"). The verdict and
            // the wall's own stress. The percentages, the part's peak and the allowable
            // were three more numbers on a row that answers one question.
            //
            // ★ A THIRD FACT WAS TRIED HERE AND WITHDRAWN (2026-09-07). When the app
            // called a wall unloaded and core replaced nothing, the row said "not
            // synthesised" — honest, but it broke his own rule for this row and it
            // described a threshold rather than fixing it. The threshold is fixed
            // instead: `deadMPaFloor` below, whichever fires first.
            return String(format: "%@ · %.3g MPa", dead ? "unloaded" : "loaded", wallP99MPa)
        }
    }

    /// What the bridge needs: a region id per voxel and the config per region.
    public struct Plan: Equatable, Sendable {
        public let regionIDs: [Int32]
        public let regions: [TopOptKit.OrganicSyntheticRegionSpec]
        /// region id → selectable key, for the report's way back to the row.
        public let keyByID: [Int: String]
        public var isEmpty: Bool { regions.isEmpty }
        public init(regionIDs: [Int32], regions: [TopOptKit.OrganicSyntheticRegionSpec], keyByID: [Int: String]) {
            self.regionIDs = regionIDs; self.regions = regions; self.keyByID = keyByID
        }
    }

    /// Build the plan from the job's INCLUDE regions in declaration order (ids are
    /// 1-based, exactly how `lattice_role_regions_from_job` numbers them), each
    /// voxel taking the first region that contains its centre. Every include
    /// region is offered to core; core decides which are dead.
    public static func plan(regions: [LatticeRegionSpec], dims: (Int, Int, Int),
                            originMM: SIMD3<Double>, spacingMM: Double,
                            defaultFoci: Int, statedFoci: [String: Int]) -> Plan {
        let (nx, ny, nz) = dims
        let n = nx * ny * nz
        let includes = regions.filter { $0.role == .include && $0.isValid }
        guard n > 0, spacingMM > 0, !includes.isEmpty else {
            return Plan(regionIDs: [], regions: [], keyByID: [:])
        }
        var ids = [Int32](repeating: 0, count: n)
        for k in 0..<nz {
            for j in 0..<ny {
                for i in 0..<nx {
                    // ★ CORE'S OWN CONVENTION, and this is the authority:
                    // `VoxelGrid::voxel_center` is `origin + (i + 0.5) · spacing`
                    // (core/include/topopt/voxel.hpp:87). A 4 mm slab on a 1 mm grid
                    // then holds FOUR voxels, which is the right answer; sampling the
                    // corner instead makes it five and pushes the near face half a voxel
                    // out. The scene's candidate loop was the one out of step, and it
                    // has been corrected to match — see `LatticeSDFMetal`.
                    let p = originMM + (SIMD3<Double>(Double(i), Double(j), Double(k)) + 0.5) * spacingMM
                    for (r, region) in includes.enumerated()
                    where LatticeRegionMask.contains(p, region: region) {
                        ids[(k * ny + j) * nx + i] = Int32(r + 1)
                        break
                    }
                }
            }
        }
        var specs: [TopOptKit.OrganicSyntheticRegionSpec] = []
        var keys: [Int: String] = [:]
        for (r, region) in includes.enumerated() {
            let key = region.selectableKey ?? ""
            let foci = clampFoci(statedFoci[key] ?? region.syntheticFoci ?? defaultFoci)
            specs.append(TopOptKit.OrganicSyntheticRegionSpec(
                regionID: r + 1, faceID: region.faceID ?? -1, foci: foci, softMM: 0))
            keys[r + 1] = key
        }
        return Plan(regionIDs: ids, regions: specs, keyByID: keys)
    }

    /// Core's report, keyed back to the rows.
    /// ★ PER-WALL VON MISES from the tensor the tracer is handed (2026-09-07), keyed
    /// by the plan's 1-based region id: the p99 and the max over that wall's voxels.
    /// The same Voigt convention core uses (true shear).
    public static func wallStress(tensor: [Double], regionIDs: [Int32])
        -> [Int: (p99: Double, max: Double)] {
        let n = regionIDs.count
        guard n > 0, tensor.count == 6 * n else { return [:] }
        var byRegion: [Int: [Double]] = [:]
        for i in 0..<n {
            let id = Int(regionIDs[i])
            guard id >= 1 else { continue }
            byRegion[id, default: []].append(vonMises(tensor, at: i))
        }
        var out: [Int: (p99: Double, max: Double)] = [:]
        for (id, var vm) in byRegion where !vm.isEmpty {
            vm.sort()
            out[id] = (p99: vm[Int(0.99 * Double(vm.count - 1))], max: vm[vm.count - 1])
        }
        return out
    }

    /// Von Mises from a Voigt tensor [xx, yy, zz, xy, yz, zx] with TRUE shear.
    static func vonMises(_ t: [Double], at i: Int) -> Double {
        let o = 6 * i
        let a = (t[o] - t[o + 1]) * (t[o] - t[o + 1])
            + (t[o + 1] - t[o + 2]) * (t[o + 1] - t[o + 2])
            + (t[o + 2] - t[o]) * (t[o + 2] - t[o])
        let b = 3 * (t[o + 3] * t[o + 3] + t[o + 4] * t[o + 4] + t[o + 5] * t[o + 5])
        return (0.5 * a + b).squareRoot()
    }

    public static func wallReports(from report: TopOptKit.OrganicSyntheticReport?,
                                   plan: Plan,
                                   stressByRegion: [Int: (p99: Double, max: Double)] = [:],
                                   allowableMPa: Double = 0) -> [String: WallReport] {
        guard let report else { return [:] }
        var out: [String: WallReport] = [:]
        for r in report.regions {
            guard let key = plan.keyByID[r.regionID], !key.isEmpty else { continue }
            var w = WallReport(key: key, faceID: r.faceID >= 0 ? r.faceID : nil,
                               voxels: r.voxels, fullySynthetic: r.fullySynthetic,
                               blended: r.blended, foci: r.foci)
            w.partPeakMPa = report.peakVonMises
            w.allowableMPa = allowableMPa
            if let s = stressByRegion[r.regionID] { w.wallP99MPa = s.p99; w.wallMaxMPa = s.max }
            out[key] = w
        }
        return out
    }
}
