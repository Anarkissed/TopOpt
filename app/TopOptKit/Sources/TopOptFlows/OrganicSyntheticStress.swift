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
        /// ★ The part's peak von Mises core measured against (MPa). Core's dead test
        /// is 2 % of THIS, so on a lightly loaded part (0.031 MPa on his stand) a wall
        /// carrying nothing useful still reads "loaded" — the number goes on the row so
        /// the reading can be judged (his walk, 2026-09-06; core report, handoff 39).
        public var peakMPa: Double = 0
        /// The share of the wall that went synthetic (fully + half of blended).
        public var syntheticFraction: Double {
            voxels > 0 ? (Double(fullySynthetic) + 0.5 * Double(blended)) / Double(voxels) : 0
        }
        public var realShare: Double { 1 - syntheticFraction }
        public var dead: Bool { voxels > 0 && realShare < loadedRealShare }
        public var injected: Int { fullySynthetic }
        public var statusText: String {
            if voxels == 0 { return "no material" }
            return dead
                ? String(format: "unloaded · %.0f%% synthetic", 100 * syntheticFraction)
                : String(format: "loaded · %.0f%% real", 100 * realShare)
                  + (peakMPa > 0 ? String(format: " · peak %.3g MPa", peakMPa) : "")
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
    public static func wallReports(from report: TopOptKit.OrganicSyntheticReport?,
                                   plan: Plan) -> [String: WallReport] {
        guard let report else { return [:] }
        var out: [String: WallReport] = [:]
        for r in report.regions {
            guard let key = plan.keyByID[r.regionID], !key.isEmpty else { continue }
            var w = WallReport(key: key, faceID: r.faceID >= 0 ? r.faceID : nil,
                               voxels: r.voxels, fullySynthetic: r.fullySynthetic,
                               blended: r.blended, foci: r.foci)
            w.peakMPa = report.peakVonMises
            out[key] = w
        }
        return out
    }
}
