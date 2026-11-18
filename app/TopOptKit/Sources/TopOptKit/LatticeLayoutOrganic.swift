// LatticeLayoutOrganic — ★ ORGANIC, CUT 1 (his 11-18: "I'd like to get going to be able to VIEW things on the ipad ASAP";
// "Preview PLUS settings simultaneously. Export as its own install"): the weave's preview on the iPad through the session,
// from LatticeReview's engine (lattice_layout_organic.hpp, brief L2): the lay in two qualities (Exact = what will be made;
// Draft = for a dragged slider, NOT what will be made), its strut RUNS (polylines with a width per point, thinned), the
// stress tensor the weave follows, and the Auto Sweep limits per region.
import Foundation
import TopOptBridge

extension LatticeLayoutSession {

    /// Every field of core's OrganicAsk, under its own name and default (LatticeLayoutBridge.hpp says what each does). The
    /// app's controls map onto these (his 13; organic-cut1 mapping); the rest stay at core's defaults.
    public struct Organic: Sendable, Equatable {
        public enum Mode: Int32, Sendable { case traced = 0, grown = 1 }
        public enum Quality: Int32, Sendable { case exact = 0, draft = 1 }
        public var mode: Mode = .traced
        public var quality: Quality = .exact
        public var toleranceMM = 0.1
        public var spacingMM = 0.0, spacingMinMM = 3.0, spacingMaxMM = 8.0, spacingExponent = 1.0
        public var widthMM = 0.0, widthHeavyMM = 0.0
        public var referenceMPa = 0.0, percentile = 0.95
        public var shapeFit = true, memberCap = true
        public var shapeReach = 1.0
        public var buildDir = SIMD3<Double>(0, 0, 1)
        public var wallsOut = false, ties = true
        public var tieSwirl = 1.0, footGap = 2.5
        public var stressGoal = false
        public var voidRatio = 1.5
        public var reseedRounds: Int32 = 1
        public var wallConnect = false
        public var wallGap = 0.0, wallGapHeavy = 0.0
        public var wallCross: Int32 = 0
        public var crossGap = 2.5, crossGapHeavy = 0.0, crossClimbMaxDeg = 45.0
        public var topRun = 0.0, rootRun = 0.0
        public var runMax: Int32 = 1
        public var runGap = 0.5, runFollow = 1.0, runPull = 0.0, runSeek = 0.0, runMin = 0.5, rootGap = -1.0
        public var autoByStress = false, prune = false
        public var bedFloorMM = 0.0
        public var holdParts = false
        public var partReachMM = 8.0, partSupportMM = 0.0
        public var partToFloor = false
        public var linkWidth = 1.0, unbracedMax = 0.0
        public var tieLevel = false
        public var tieGap = 1.0, tieGapHeavy = 0.0
        public var followStress = true   // OP6 (his 11-18): false = shape only
        public var seed: UInt64 = 1
        public init() {}

        var raw: topoptbridge.LatticeLayoutOrganic {
            var o = topoptbridge.LatticeLayoutOrganic()
            o.mode = mode.rawValue; o.quality = quality.rawValue; o.tolerance_mm = toleranceMM
            o.spacing_mm = spacingMM; o.spacing_min_mm = spacingMinMM; o.spacing_max_mm = spacingMaxMM
            o.spacing_exponent = spacingExponent
            o.width_mm = widthMM; o.width_heavy_mm = widthHeavyMM
            o.reference_mpa = referenceMPa; o.percentile = percentile
            o.shape_fit = shapeFit; o.member_cap = memberCap; o.shape_reach = shapeReach
            o.build_x = buildDir.x; o.build_y = buildDir.y; o.build_z = buildDir.z
            o.walls_out = wallsOut; o.ties = ties; o.tie_swirl = tieSwirl; o.foot_gap = footGap
            o.stress_goal = stressGoal; o.void_ratio = voidRatio; o.reseed_rounds = reseedRounds
            o.wall_connect = wallConnect; o.wall_gap = wallGap; o.wall_gap_heavy = wallGapHeavy
            o.wall_cross = wallCross; o.cross_gap = crossGap; o.cross_gap_heavy = crossGapHeavy
            o.cross_climb_max_deg = crossClimbMaxDeg
            o.top_run = topRun; o.root_run = rootRun; o.run_max = runMax; o.run_gap = runGap
            o.run_follow = runFollow; o.run_pull = runPull; o.run_seek = runSeek; o.run_min = runMin; o.root_gap = rootGap
            o.auto_by_stress = autoByStress; o.prune = prune; o.bed_floor_mm = bedFloorMM
            o.hold_parts = holdParts; o.part_reach_mm = partReachMM; o.part_support_mm = partSupportMM
            o.part_to_floor = partToFloor
            o.link_width = linkWidth; o.unbraced_max = unbracedMax
            o.tie_level = tieLevel; o.tie_gap = tieGap; o.tie_gap_heavy = tieGapHeavy
            o.follow_stress = followStress
            o.seed = seed
            return o
        }
    }

    /// One run of the weave: a polyline with a width and a local spacing at each point (core's WeaveRun).
    public struct Run: Sendable, Equatable {
        public struct Marks: OptionSet, Sendable, Equatable {
            public let rawValue: UInt8
            public init(rawValue: UInt8) { self.rawValue = rawValue }
            public static let levelTie = Marks(rawValue: 1), brace = Marks(rawValue: 2), support = Marks(rawValue: 4)
            public static let net = Marks(rawValue: 8)
        }
        public var region: Int32
        public var marks: Marks
        public var endA: UInt8, endB: UInt8   // core's Bar::End
        public var points: [SIMD3<Float>]
        public var widthMM: [Float]
        public var spacingMM: [Float]
    }

    /// The weave's preview: what was laid, its runs, the lay's own result (counts, timings; its bars are the weave's —
    /// draw the runs) and the weave's numbers.
    public struct OrganicResult: Sendable {
        public var quality: Organic.Quality
        public var runs: [Run]
        public var layout: Result
        public var strands: Int, netStruts: Int
        public var spacingSmallestMM: Double, spacingLargestMM: Double, spacingMeanMM: Double
        public var msTrace: Double, ms: Double
        /// Segments drawn: one per pair of neighbouring points of every run.
        public var segments: Int { runs.reduce(0) { $0 + Swift.max(0, $1.points.count - 1) } }
    }

    /// core's pack_weave_runs, read back: per run 12 bytes (point count u32, region i32, marks u8, end_a u8, end_b u8, pad),
    /// then 20 bytes per point (x, y, z, width, spacing, float32), little-endian. nil when the bytes do not add up.
    public static func runs(packed b: [UInt8]) -> [Run]? {
        var out: [Run] = []
        var i = 0
        func u32() -> UInt32? {
            guard i + 4 <= b.count else { return nil }
            defer { i += 4 }
            return UInt32(b[i]) | UInt32(b[i + 1]) << 8 | UInt32(b[i + 2]) << 16 | UInt32(b[i + 3]) << 24
        }
        func f32() -> Float? { u32().map { Float(bitPattern: $0) } }
        while i < b.count {
            guard let n = u32(), let region = u32(), i + 4 <= b.count else { return nil }
            let marks = b[i], ea = b[i + 1], eb = b[i + 2]
            i += 4
            guard Int(n) <= (b.count - i) / 20 else { return nil }
            var pts: [SIMD3<Float>] = [], w: [Float] = [], sp: [Float] = []
            pts.reserveCapacity(Int(n)); w.reserveCapacity(Int(n)); sp.reserveCapacity(Int(n))
            for _ in 0..<Int(n) {
                guard let x = f32(), let y = f32(), let z = f32(), let wd = f32(), let s = f32() else { return nil }
                pts.append(SIMD3(x, y, z)); w.append(wd); sp.append(s)
            }
            out.append(Run(region: Int32(bitPattern: region), marks: Run.Marks(rawValue: marks), endA: ea, endB: eb,
                           points: pts, widthMM: w, spacingMM: sp))
        }
        return out
    }

    /// Lays the weave's preview (latest wins, as `lay`). Needs the stress tensor set first (`setTensor`).
    public func layOrganic(_ settings: Settings, _ organic: Organic) async throws -> OrganicResult {
        let mine = beginLay()
        let raw = convert(settings), org = organic.raw
        let sid = id
        return try await withTaskCancellationHandler {
            try await worker.run { [weak self] () throws -> OrganicResult in
                guard let self, self.isCurrent(mine) else { throw CancellationError() }
                var err = topoptbridge.BridgeError()
                let r = topoptbridge.lattice_layout_organic(sid, raw, org, &err)
                if !err.ok { throw TopOptError(message: String(err.message)) }
                if r.cancelled || !self.isCurrent(mine) { throw CancellationError() }
                guard let runs = Self.runs(packed: Array(r.runs)) else {
                    throw TopOptError(message: "the Organic preview's runs could not be read")
                }
                return OrganicResult(quality: Organic.Quality(rawValue: r.quality) ?? .exact, runs: runs,
                                     layout: Self.convert(r.layout), strands: Int(r.strands), netStruts: Int(r.net_struts),
                                     spacingSmallestMM: r.spacing_smallest_mm, spacingLargestMM: r.spacing_largest_mm,
                                     spacingMeanMM: r.spacing_mean_mm, msTrace: r.ms_trace, ms: r.ms)
            }
        } onCancel: { [weak self] in
            self?.cancel()
        }
    }

    /// The stress tensor a weave follows (Voigt, 6 per voxel, x fastest; the grid's low corner `origin`); nil clears it.
    public func setTensor(voigt: [Double]?, nx: Int, ny: Int, nz: Int, origin: SIMD3<Double>, spacingMM: Double) async throws {
        var t = topoptbridge.LatticeLayoutTensor()
        if let voigt {
            t.voigt.reserve(voigt.count)
            for v in voigt { t.voigt.push_back(Float(v)) }
            t.nx = Int32(nx); t.ny = Int32(ny); t.nz = Int32(nz)
            t.origin_x = origin.x; t.origin_y = origin.y; t.origin_z = origin.z; t.spacing = spacingMM
        }
        let input = t, sid = id
        try await worker.run {
            var err = topoptbridge.BridgeError()
            topoptbridge.lattice_layout_set_tensor(sid, input, &err)
            if !err.ok { throw TopOptError(message: String(err.message)) }
        }
    }

    /// The Auto Sweep limits of one weave region (LatticeReview's organic_sweep_limits; its fractions core's constants).
    public struct SweepLimits: Sendable, Equatable {
        public var region: Int32
        public var measured: Bool
        public var dMM: Double
        public var strutLowerMM: Double, strutUpperMM: Double, strutAutoMM: Double
        public var cellLowerMM: Double, cellUpperMM: Double, cellAutoMM: Double
    }

    /// The Auto Sweep limits of these settings' weave regions, before any lay (core's Session::sweep_limits, OP5).
    public func sweepLimits(_ settings: Settings, lineMM: Double) async throws -> [SweepLimits] {
        let sid = id, raw = convert(settings)
        return try await worker.run {
            var err = topoptbridge.BridgeError()
            let r = topoptbridge.lattice_layout_sweep_limits(sid, raw, lineMM, &err)
            if !err.ok { throw TopOptError(message: String(err.message)) }
            let region = Array(r.region), m = Array(r.measured), d = Array(r.d_mm)
            let sl = Array(r.strut_lower_mm), su = Array(r.strut_upper_mm), sa = Array(r.strut_auto_mm)
            let cl = Array(r.cell_lower_mm), cu = Array(r.cell_upper_mm), ca = Array(r.cell_auto_mm)
            return region.indices.map {
                SweepLimits(region: region[$0], measured: m[$0] != 0, dMM: d[$0], strutLowerMM: sl[$0], strutUpperMM: su[$0],
                            strutAutoMM: sa[$0], cellLowerMM: cl[$0], cellUpperMM: cu[$0], cellAutoMM: ca[$0])
            }
        }
    }
}
