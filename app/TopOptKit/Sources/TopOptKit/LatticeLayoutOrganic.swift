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
        public var layerMM = 0.2         // the printer's layer (sheet H2)
        /// One spacing for every candidate: a single size, or a range whose two ends are equal (no heavy end acts).
        public var spacingMMValueIsOne: Bool { spacingMM > 0 || spacingMaxMM <= spacingMinMM }
        public var seed: UInt64 = 1
        /// ★ Cut 2 (organic-cut2-handover.md, a), core's defaults. The app sends faceReliefMM (his "Depth variation": on 1,
        /// off 0), reliefExcludeFaces (the loaded and fixed faces, always flush) and strandKeep (his "Extra spacing between
        /// vines": on 0.9, off 0.5).
        public var gapLines = 1.5
        public var faceReliefMM = 1.0
        public var reliefExcludeFaces: [Int32] = []
        public var strandKeep = 0.9
        public var wallBareMM = 1.5, wallReach = 4.0
        public var sweep = true
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
            o.layer_mm = layerMM
            o.seed = seed
            o.gap_lines = gapLines; o.face_relief_mm = faceReliefMM; o.strand_keep = strandKeep
            for f in reliefExcludeFaces { o.relief_exclude_faces.push_back(f) }
            o.wall_bare_mm = wallBareMM; o.wall_reach = wallReach; o.sweep = sweep
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
            /// Leg H: the run lies along an allowed open face (its bars may stand proud by `proudMM`).
            public static let along = Marks(rawValue: 16)
        }
        public var region: Int32
        public var marks: Marks
        public var endA: UInt8, endB: UInt8   // core's Bar::End
        public var points: [SIMD3<Float>]
        /// Version 1: each point's width (at an inner point the mean of its two bars). Version 2: the print file's RING width
        /// (the end bar's at the run's ends, the larger of the two bars at an inner point).
        public var widthMM: [Float]
        public var spacingMM: [Float]
        /// Packed version 2 (the cut 2 engine). The run's section as the print file sweeps it: 0 round, 1 a bridge with a
        /// round top (its flat underside level), 2 a square bridge. Runs break where it changes.
        public var section: UInt8 = 0
        /// Packed version 2, bit 2 of the section byte (OV1, his 11-20 "Definitely curved"): the points are the print file's
        /// SWEPT centre line, each with its ring width; drawn as they are (short mitred pieces), no curve of the app's own.
        public var swept = false
        /// How far each end stands proud of the open face (0 = flush), the model face the run lies along (-1 none), and how
        /// far its tube may stand out where it runs along that face (0 none).
        public var proudA: Float = 0, proudB: Float = 0
        public var alongFace: Int32 = -1
        public var proudMM: Float = 0
        /// The print file lets this run stand out of the part's surface (it is not cut flat there).
        public var standsProud: Bool { proudA > 0 || proudB > 0 || proudMM > 0 }
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
        /// ★ E1: not empty = nothing laid; each says what and why, whole.
        public var refused: [Refusal] = []
        /// ★ E2: plain sentences (equal cell ends).
        public var notes: [String] = []
        /// ★ E7: struts of different groups that touch (not joined).
        public var crossGroupTouches = 0
        /// ★ Cut 2 (OJ6): bulges the print check made flush so the part prints (said on screen when above 0).
        public var reliefFlushed = 0
        /// ★ OS1 B (LatticeReview's leg U): the bridges' rounded ends the print file's check held FLAT, at the runs' own points
        /// (Exact only; the Draft's is empty): the drawing draws them flat (`OrganicVineShape.tubes(runs:heldFlat:)`).
        public var flatEnds: [SIMD3<Float>] = []
        /// Segments drawn: one per pair of neighbouring points of every run.
        public var segments: Int { runs.reduce(0) { $0 + Swift.max(0, $1.points.count - 1) } }
    }

    /// ★ E1 (LatticeReview's C2): one refusal as core gives it — which group (-1: the list itself, or the stress), which
    /// setting (the engine's field name), a code, and a plain sentence to show whole; the allowed numbers where one applies.
    public struct Refusal: Sendable, Equatable {
        public var group: Int
        public var setting: String, code: String, text: String
        public var given: Double
        public var allowedMin: Double?, allowedMax: Double?
        init(_ r: topoptbridge.LatticeLayoutRefusal) {
            group = Int(r.group); setting = String(r.setting); code = String(r.code); text = String(r.text); given = r.given
            allowedMin = r.has_min ? r.allowed_min : nil; allowedMax = r.has_max ? r.allowed_max : nil
        }
    }

    /// ★ E7, Organic per group (his 11-18): each group's weave region ids and its own ask.
    public struct OrganicGroup: Sendable {
        public var regions: [Int32]
        public var ask: Organic
        public init(regions: [Int32], ask: Organic) { self.regions = regions; self.ask = ask }
    }

    static func raw(_ groups: [OrganicGroup]) -> topoptbridge.LatticeLayoutOrganicGroups {
        var g = topoptbridge.LatticeLayoutOrganicGroups()
        for one in groups {
            g.asks.push_back(one.ask.raw)
            g.group_region_counts.push_back(Int32(one.regions.count))
            for r in one.regions { g.group_regions.push_back(r) }
        }
        return g
    }

    /// Lays the weave's preview group by group (latest wins). Needs the stress tensor set first (`setTensor`, `synthetic`).
    /// x, y, z triples as points (the bridge's flat_ends).
    static func points(_ xyz: [Double]) -> [SIMD3<Float>] {
        stride(from: 0, to: xyz.count - xyz.count % 3, by: 3).map { SIMD3(Float(xyz[$0]), Float(xyz[$0 + 1]), Float(xyz[$0 + 2])) }
    }

    public func layOrganic(_ settings: Settings, groups: [OrganicGroup]) async throws -> OrganicResult {
        let mine = beginLay()
        let raw = convert(settings), gs = Self.raw(groups)
        let sid = id
        return try await withTaskCancellationHandler {
            try await worker.run { [weak self] () throws -> OrganicResult in
                guard let self, self.isCurrent(mine) else { throw CancellationError() }
                var err = topoptbridge.BridgeError()
                let r = topoptbridge.lattice_layout_organic_groups(sid, raw, gs, &err)
                if !err.ok { throw TopOptError(message: String(err.message)) }
                if r.cancelled || !self.isCurrent(mine) { throw CancellationError() }
                let refused = r.refused.map(Refusal.init)
                guard let runs = refused.isEmpty ? Self.runs(packed: Array(r.runs)) : [] else {
                    throw TopOptError(message: "the Organic preview's runs could not be read")
                }
                var o = OrganicResult(quality: Organic.Quality(rawValue: r.quality) ?? .exact, runs: runs,
                                      layout: Self.convert(r.layout), strands: Int(r.strands), netStruts: Int(r.net_struts),
                                      spacingSmallestMM: r.spacing_smallest_mm, spacingLargestMM: r.spacing_largest_mm,
                                      spacingMeanMM: r.spacing_mean_mm, msTrace: r.ms_trace, ms: r.ms)
                o.refused = refused
                o.notes = r.notes.map { String($0) }
                o.crossGroupTouches = Int(r.cross_group_touches)
                o.reliefFlushed = Int(r.relief_flushed)
                o.flatEnds = Self.points(Array(r.flat_ends))
                return o
            }
        } onCancel: { [weak self] in
            self?.cancel()
        }
    }

    /// ★ E1: every refusal of these groups' asks (and of the stress the session holds), before a lay; empty = valid.
    public func validateOrganic(_ settings: Settings, groups: [OrganicGroup]) async throws -> [Refusal] {
        let raw = convert(settings), gs = Self.raw(groups), sid = id
        return try await worker.run {
            var err = topoptbridge.BridgeError()
            let r = topoptbridge.lattice_layout_organic_validate(sid, raw, gs, &err)
            if !err.ok { throw TopOptError(message: String(err.message)) }
            return r.map(Refusal.init)
        }
    }

    /// ★ E4 per group: the union of these regions' Auto Sweep limits (nil: none measured).
    public func sweepLimits(_ settings: Settings, regions: [Int32], lineMM: Double) async throws -> SweepLimits? {
        let raw = convert(settings), sid = id
        var ids = topoptbridge.LatticeLayoutIds()
        for r in regions { ids.ids.push_back(r) }
        let idsCopy = ids
        return try await worker.run {
            var err = topoptbridge.BridgeError()
            let r = topoptbridge.lattice_layout_sweep_limits_for(sid, raw, idsCopy, lineMM, &err)
            if !err.ok { throw TopOptError(message: String(err.message)) }
            guard let m = Array(r.measured).first, m != 0 else { return nil }
            return SweepLimits(region: 0, measured: true, dMM: 0, strutLowerMM: Array(r.strut_lower_mm)[0],
                               strutUpperMM: Array(r.strut_upper_mm)[0], strutAutoMM: Array(r.strut_auto_mm)[0],
                               cellLowerMM: Array(r.cell_lower_mm)[0], cellUpperMM: Array(r.cell_upper_mm)[0],
                               cellAutoMM: Array(r.cell_auto_mm)[0], gapMM: Array(r.gap_mm).first ?? 0)
        }
    }

    /// ★ E5: what core found of each weave region's stress, and how it filled the walls.
    public struct Synthetic: Sendable {
        public var withoutStress: [Int32: Bool] = [:]
        public var foci: [Int32: Int] = [:]
        public var filled: [Int32: Int] = [:]
        public var refused: [Refusal] = []
    }
    /// ★ E5, "Simulate stresses on unstressed walls" (his 11-18) and the samples' one focus: core fills the stress the
    /// session holds for the walls (region, foci) — or, `fromEmpty`, makes one with no solve — and the next Organic lay
    /// follows it. No walls (and not fromEmpty): the real stress back.
    public func synthetic(_ settings: Settings, groups: [OrganicGroup], walls: [(region: Int32, foci: Int)],
                          fromEmpty: Bool = false) async throws -> Synthetic {
        let raw = convert(settings), gs = Self.raw(groups), sid = id
        var wl = topoptbridge.LatticeLayoutIds()
        for w in walls { wl.ids.push_back(w.region); wl.foci.push_back(Int32(w.foci)) }
        let wallsCopy = wl
        return try await worker.run {
            var err = topoptbridge.BridgeError()
            let r = topoptbridge.lattice_layout_synthetic(sid, raw, gs, wallsCopy, fromEmpty, &err)
            if !err.ok { throw TopOptError(message: String(err.message)) }
            var o = Synthetic()
            o.refused = r.refused.map(Refusal.init)
            let ids = Array(r.region), w = Array(r.without_stress), f = Array(r.foci), n = Array(r.filled)
            for i in ids.indices {
                o.withoutStress[ids[i]] = w[i] != 0; o.foci[ids[i]] = Int(f[i]); o.filled[ids[i]] = Int(n[i])
            }
            return o
        }
    }

    /// core's pack_weave_runs, read back, little-endian; nil when the bytes do not add up.
    /// Version 1: per run 12 bytes (point count u32, region i32, marks u8, end_a u8, end_b u8, pad), then 20 bytes per point
    /// (x, y, z, width, spacing, float32).
    /// Version 2 (the cut 2 engine, LatticeReview 11-20 03:54Z, "final for this leg"): "WRN2" and u32 2 first; per run 28 bytes
    /// (the same 12, the pad now the SECTION byte: bits 0-1 the section, bit 2 a swept centre line (OV1), bits 3-7 held; then
    /// proud_a f32, proud_b f32, along_face i32, proud_mm f32); per point the same 20 bytes, the width now the file's ring width.
    public static func runs(packed b: [UInt8]) -> [Run]? {
        var out: [Run] = []
        var i = 0
        func u32() -> UInt32? {
            guard i + 4 <= b.count else { return nil }
            defer { i += 4 }
            return UInt32(b[i]) | UInt32(b[i + 1]) << 8 | UInt32(b[i + 2]) << 16 | UInt32(b[i + 3]) << 24
        }
        func f32() -> Float? { u32().map { Float(bitPattern: $0) } }
        let v2 = b.count >= 8 && b[0] == 0x57 && b[1] == 0x52 && b[2] == 0x4E && b[3] == 0x32   // "WRN2"
        if v2 {
            i = 4
            guard u32() == 2 else { return nil }
        }
        while i < b.count {
            guard let n = u32(), let region = u32(), i + 4 <= b.count else { return nil }
            // the section is bits 0-1 of that byte; bit 2 a swept centre line (OV1); bits 3-7 held
            let marks = b[i], ea = b[i + 1], eb = b[i + 2], section = v2 ? b[i + 3] & 3 : 0, swept = v2 && b[i + 3] & 4 != 0
            i += 4
            var pa: Float = 0, pb: Float = 0, face: Int32 = -1, pm: Float = 0
            if v2 {
                guard let a = f32(), let bb = f32(), let f = u32(), let m = f32() else { return nil }
                pa = a; pb = bb; face = Int32(bitPattern: f); pm = m
            }
            guard Int(n) <= (b.count - i) / 20 else { return nil }
            var pts: [SIMD3<Float>] = [], w: [Float] = [], sp: [Float] = []
            pts.reserveCapacity(Int(n)); w.reserveCapacity(Int(n)); sp.reserveCapacity(Int(n))
            for _ in 0..<Int(n) {
                guard let x = f32(), let y = f32(), let z = f32(), let wd = f32(), let s = f32() else { return nil }
                pts.append(SIMD3(x, y, z)); w.append(wd); sp.append(s)
            }
            out.append(Run(region: Int32(bitPattern: region), marks: Run.Marks(rawValue: marks), endA: ea, endB: eb,
                           points: pts, widthMM: w, spacingMM: sp, section: section, swept: swept, proudA: pa, proudB: pb,
                           alongFace: face, proudMM: pm))
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
                var o = OrganicResult(quality: Organic.Quality(rawValue: r.quality) ?? .exact, runs: runs,
                                      layout: Self.convert(r.layout), strands: Int(r.strands), netStruts: Int(r.net_struts),
                                      spacingSmallestMM: r.spacing_smallest_mm, spacingLargestMM: r.spacing_largest_mm,
                                      spacingMeanMM: r.spacing_mean_mm, msTrace: r.ms_trace, ms: r.ms)
                o.flatEnds = Self.points(Array(r.flat_ends))
                return o
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

    /// ★ Organic cut 2 (the export): the stress the next lay follows — as set, or as the synthetic stress filled it — as core's
    /// TOTENSOR file, the lattice file job's `tensor`. Throws when the session holds none.
    public func tensorFile() async throws -> Data {
        let sid = id
        return try await worker.run {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("organic-tensor-\(UUID().uuidString).bin")
            defer { try? FileManager.default.removeItem(at: url) }
            var err = topoptbridge.BridgeError()
            _ = topoptbridge.lattice_layout_write_tensor(sid, std.string(url.path), &err)
            if !err.ok { throw TopOptError(message: String(err.message)) }
            return try Data(contentsOf: url)
        }
    }

    /// The Auto Sweep limits of one weave region (LatticeReview's organic_sweep_limits; its fractions core's constants).
    public struct SweepLimits: Sendable, Equatable {
        public var region: Int32
        public var measured: Bool
        public var dMM: Double
        public var strutLowerMM: Double, strutUpperMM: Double, strutAutoMM: Double
        public var cellLowerMM: Double, cellUpperMM: Double, cellAutoMM: Double
        /// ★ Cut 2, OG1: the gap the engine keeps between struts (0: off); a cell under the thin strut + it is refused.
        public var gapMM: Double = 0
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
            let cl = Array(r.cell_lower_mm), cu = Array(r.cell_upper_mm), ca = Array(r.cell_auto_mm), g = Array(r.gap_mm)
            return region.indices.map {
                SweepLimits(region: region[$0], measured: m[$0] != 0, dMM: d[$0], strutLowerMM: sl[$0], strutUpperMM: su[$0],
                            strutAutoMM: sa[$0], cellLowerMM: cl[$0], cellUpperMM: cu[$0], cellAutoMM: ca[$0],
                            gapMM: $0 < g.count ? g[$0] : 0)
            }
        }
    }
}
