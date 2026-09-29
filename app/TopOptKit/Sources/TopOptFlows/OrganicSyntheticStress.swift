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

    /// The run's dead fraction (run_job passes 0.02). Core calls a WALL dead when its
    /// p99 von Mises is at or under `max(0.02 × the peak, kOrganicSyntheticDeadFloorMPa)`
    /// and then gives the whole wall the focal field — one verdict per wall, no
    /// per-voxel blend (core #358). The preview makes the run's own call through the
    /// bridge; this copy is for the wording and the tests, never for a verdict.
    public static let deadFraction = 0.02
    /// ★★★ AN ABSOLUTE FLOOR UNDER THE DEAD TEST (his ruling, 2026-09-07: "I want you to
    /// change the dead test to 2% OR 0.005MPa - whichever comes first").
    ///
    /// Core's test USED TO BE `thr = dead_fraction × peak`, purely relative. His stand
    /// peaks at 0.03 MPa against a 31 MPa allowable, so 2 % of the peak is 0.0006 MPa and
    /// a wall holding 0.004 MPa read alive — foci accepted, nothing replaced. Whichever
    /// fires first now: the threshold is `max(0.02 × peak, 0.005)`.
    ///
    /// ★ CORE OWNS THE FLOOR: `kOrganicSyntheticDeadFloorMPa` (organic_lattice.hpp), which
    /// the run passes as `dead_floor`, and the preview bridge makes that same call
    /// (`synthesize_as_the_run`, ruling C 2026-09-29). This copy only drives the wording;
    /// OrganicDeadWallParityTests pins it equal to core's.
    public static let deadMPaFloor = 0.005
    public static let fociRange = 1...5

    public static func clampFoci(_ n: Int) -> Int {
        Swift.min(Swift.max(n, fociRange.lowerBound), fociRange.upperBound)
    }

    /// ★★ WHAT THE JOB FLAGS (ruling 2, 2026-09-29): every include wall, each with its
    /// stated foci count or the lattice default. The same precedence the preview's plan
    /// uses (`statedFoci[key] ?? defaultFoci`), so the preview and the run offer core the
    /// same walls with the same counts; core decides which are dead.
    public struct SyntheticFlags: Equatable, Sendable {
        public var defaultFoci: Int
        public var stated: [String: Int]
        public init(defaultFoci: Int, stated: [String: Int]) {
            self.defaultFoci = defaultFoci; self.stated = stated
        }
        /// nil key ⇒ a wall with no selectable (a legacy include primitive): the default.
        public func foci(for key: String?) -> Int {
            clampFoci(key.flatMap { stated[$0] } ?? defaultFoci)
        }
    }

    /// ★★★ WHICH WALLS ARE "LOADED" IS CORE'S ANSWER (maintainer, 2026-09-29, ruling 1:
    /// "The Selections row's word and the foci offer follow core's verdict … not the
    /// app's 15 % rule"). The app used to judge it itself — a wall's p99 under 15 % of
    /// the part's peak, or the whole part idle against the allowable — and on his stand
    /// that called the 0.0203 MPa back wall "unloaded" and offered it foci, while core
    /// (p99 0.0203 > its threshold 0.005) leaves it alone. Now the word and the offer
    /// read core's verdict from the same call the preview grades by
    /// (`LatticeSDFScene.coreDeadWallVerdict`): a wall core synthesised is barely loaded
    /// and may take foci; a wall core left alone carries load and may not.
    ///
    /// One wall's verdict, from core's report — every region of the wall summed.
    public struct WallReport: Equatable, Sendable {
        public let key: String?
        public let faceID: Int?
        public var voxels: Int
        public var fullySynthetic: Int
        public var blended: Int
        public let foci: Int
        /// ★★ DEAD = CORE SYNTHESISED IT (ruling 1): any of the wall's regions took the
        /// focal field (`fully_synthetic > 0`). No Swift threshold decides this.
        public var dead: Bool { voxels > 0 && fullySynthetic > 0 }
        /// ★ PLAIN WORDS (ruling 1). This retires the 2026-09-07 "two facts" row (verdict +
        /// the wall's MPa): that number was the app's own p99, not the one core judged.
        public var statusText: String {
            voxels == 0 ? "no material" : OrganicSyntheticStress.wallWord(loaded: !dead)
        }
    }

    /// The Selections row's word for a wall core measured (his words, 2026-09-29).
    public static func wallWord(loaded: Bool) -> String {
        loaded ? "Carries load" : "Barely loaded — a made-up load can be added"
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

    /// Von Mises from a Voigt tensor [xx, yy, zz, xy, yz, zx] with TRUE shear.
    static func vonMises(_ t: [Double], at i: Int) -> Double {
        let o = 6 * i
        let a = (t[o] - t[o + 1]) * (t[o] - t[o + 1])
            + (t[o + 1] - t[o + 2]) * (t[o + 1] - t[o + 2])
            + (t[o + 2] - t[o]) * (t[o + 2] - t[o])
        let b = 3 * (t[o + 3] * t[o + 3] + t[o + 4] * t[o + 4] + t[o + 5] * t[o + 5])
        return (0.5 * a + b).squareRoot()
    }

    /// Core's report, keyed back to the rows. ★ A WALL IS ONE ROW however many regions it
    /// emits (a curved face's facets, a region's member faces): their voxels and counts
    /// are summed, so a wall core synthesised in ANY of its regions reads barely loaded.
    /// (The last region in plan order used to decide it.)
    public static func wallReports(from report: TopOptKit.OrganicSyntheticReport?,
                                   plan: Plan) -> [String: WallReport] {
        guard let report else { return [:] }
        var out: [String: WallReport] = [:]
        for r in report.regions {
            guard let key = plan.keyByID[r.regionID], !key.isEmpty else { continue }
            if var w = out[key] {
                w.voxels += r.voxels; w.fullySynthetic += r.fullySynthetic; w.blended += r.blended
                out[key] = w
            } else {
                out[key] = WallReport(key: key, faceID: r.faceID >= 0 ? r.faceID : nil,
                                      voxels: r.voxels, fullySynthetic: r.fullySynthetic,
                                      blended: r.blended, foci: r.foci)
            }
        }
        return out
    }
}
