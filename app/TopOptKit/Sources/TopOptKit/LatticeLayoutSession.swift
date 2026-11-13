// LatticeLayoutSession — the lattice rebuild's stage E entry, Swift side (362; LatticeLayoutBridge.hpp). One session per part
// while its Lattice page is open: `open` reads and measures the model once (STEP, STL or 3MF — the faces the app sees),
// `lay` lays the lattice for a set of settings (core keeps what a change does not touch, rule P2), `whereAt` says what is at a
// batch of points for the LAST layout (the drawer's lattice / rim / solid, the blue glow's reasons).
//
// ★ Every call runs on the session's OWN worker thread, a 16 MB stack, never main (his 10-28 iPad crash: the iPad's main-thread
// stack is small, and macOS tests cannot see it). ★ Latest wins: a `lay` asked while an older one waits or runs makes the
// older come back as CancellationError (the waiting one never starts; the running one is told through core's bridge, and its
// result dropped) — a slider moved ten times lays the tenth. A cancelled Task cancels its own layout the same way.
import Foundation
import simd
import TopOptBridge

public final class LatticeLayoutSession: @unchecked Sendable {

    /// Why a place is solid, or that it is lattice (core's lattice_layout::Why, and D14's no cell fits).
    public enum Why: UInt8, Sendable, CaseIterable {
        case lattice = 0, outside, notAsked, noLattice, protectSkin, wallTooThin, rim, cover, noCellFits
        public var isSolid: Bool { self != .lattice && self != .outside }
    }

    /// How a bar's end finishes (core's Bar::End).
    public enum End: UInt8, Sendable { case node = 0, solid, surface, loose, joined }

    public struct Region: Sendable, Equatable {
        public var id: Int32            // > 0
        public var noLattice: Bool
        public var faces: [Int32]       // the model's own face numbers (the app's FaceIDs)
        public var depthMM: Double
        public var expandMM: Double
        public init(id: Int32, noLattice: Bool = false, faces: [Int32], depthMM: Double, expandMM: Double = 0) {
            self.id = id; self.noLattice = noLattice; self.faces = faces; self.depthMM = depthMM; self.expandMM = expandMM
        }
    }

    public struct Protect: Sendable, Equatable {
        public var id: Int32
        public var faces: [Int32]
        public var depthMM: Double      // 0 = two line widths
        public init(id: Int32, faces: [Int32], depthMM: Double = 0) { self.id = id; self.faces = faces; self.depthMM = depthMM }
    }

    /// Core's settings, one for one (LatticeLayoutBridge.hpp says what each does).
    public struct Settings: Sendable, Equatable {
        public var allLattice = false
        public var beadMM = 0.45
        public var minStrutLines = 2.0   // ★ two lines (the reviewer's ruling 11-12: one line does not print on his 0.4 mm nozzle)
        public var minWallMM = 0.0
        public var rimMM = 0.0
        public var coverMM = 0.0
        public var regions: [Region] = []
        public var protect: [Protect] = []
        public var topology = "octet"
        public var algorithm = "default_grade"
        public var cellMM = 0.0
        public var cellMaxMM = 8.0
        public var cellMinMM = 0.0
        public var minCellsAcross: Int32 = 1
        public var gradeToShape = false
        public var bandMM = 0.0
        public var bandCellMM = 0.0
        public var perRegion = false
        public var dial = 0.45
        public var regionDials: [(region: Int32, dial: Double)] = []
        public var strutWidthMM = 0.0
        public var allowQuilt = false
        public var strength = 0.0
        public var bars = true
        public var joinLoose = true
        public var skin = false
        public var skinWidthMM = 0.0
        public var skinReachCells = 1.2
        public var dropLoose = true
        public var smallCellsInThinWalls = false   // his per-part choice (11-13)
        public init() {}
        public static func == (a: Settings, b: Settings) -> Bool {
            a.allLattice == b.allLattice && a.beadMM == b.beadMM && a.minStrutLines == b.minStrutLines && a.minWallMM == b.minWallMM
                && a.rimMM == b.rimMM && a.coverMM == b.coverMM && a.regions == b.regions && a.protect == b.protect
                && a.topology == b.topology && a.algorithm == b.algorithm && a.cellMM == b.cellMM && a.cellMaxMM == b.cellMaxMM
                && a.cellMinMM == b.cellMinMM && a.minCellsAcross == b.minCellsAcross && a.gradeToShape == b.gradeToShape
                && a.bandMM == b.bandMM && a.bandCellMM == b.bandCellMM && a.perRegion == b.perRegion && a.dial == b.dial
                && a.regionDials.map(\.region) == b.regionDials.map(\.region) && a.regionDials.map(\.dial) == b.regionDials.map(\.dial)
                && a.strutWidthMM == b.strutWidthMM && a.allowQuilt == b.allowQuilt && a.strength == b.strength && a.bars == b.bars
                && a.joinLoose == b.joinLoose && a.skin == b.skin && a.skinWidthMM == b.skinWidthMM
                && a.skinReachCells == b.skinReachCells && a.dropLoose == b.dropLoose
                && a.smallCellsInThinWalls == b.smallCellsInThinWalls
        }
    }

    /// One layout, as flat arrays the drawer reads straight into its buffers (a list that grows with the part goes in a GPU
    /// BUFFER, never inline — his 11-11 crash; the rebuild's rule).
    public struct Result: Sendable {
        public var bars: [Float] = []          // 7 per bar: a xyz, b xyz, width mm
        public var barEnds: [UInt8] = []       // 2 per bar: End
        public var barFlags: [UInt8] = []      // 1 per bar: 1 a piece of a cut strut, 2 a skin bar
        public var barRegion: [Int32] = []
        public var frames: [Float] = []        // 12 per frame: origin, then three unit axes
        public var solidCubes: [Float] = []    // 4 per solid piece: low corner (frame mm) and size
        public var solidFrame: [Int32] = []
        public var solidRegion: [Int32] = []
        public var solidWhy: [UInt8] = []      // a Why per solid piece
        public var steppedEdges: [Float] = []  // 4 per edge: at xyz, ends
        public var steppedRegion: [Int32] = []
        public var emptyRegions: [Int32] = []
        public var cells = 0, solidPieces = 0, atOneLine = 0, atWidest = 0, stubs = 0, joined = 0, dropped = 0, pieces = 0, adrift = 0
        public var floorCellMM = 0.0, minStrutMM = 0.0, openLook = 0.0, touch = 0.0
        /// The rebuild's rules (a), (b) of 11-12, nil until core measures them.
        public var bedContactMM2: Double?
        public var midairStarts: Int?
        public var readAgain = false
        public var msRead = 0.0, msCells = 0.0, msBars = 0.0, msBridge = 0.0
        public var barCount: Int { bars.count / 7 }
    }

    public struct OpenInfo: Sendable {
        public let faces: Int
        public let openEdges: Int
        public let msOpen: Double
    }

    public let id: Int64
    public let info: OpenInfo
    private let worker: LatticeLayoutWorker
    private let lock = NSLock()
    private var generation: UInt64 = 0
    private var closed = false

    /// The worker's stack: 16 MB (the iPad's main thread has 1 MB; core recurses in its measure).
    public static let workerStackSize = 16 << 20

    private init(id: Int64, info: OpenInfo, worker: LatticeLayoutWorker) {
        self.id = id; self.info = info; self.worker = worker
    }

    deinit { close() }

    /// Opens the imported model at `path` (STEP, STL or 3MF) on a new worker thread.
    public static func open(path: String, linearDeflection: Double = 0) async throws -> LatticeLayoutSession {
        let worker = LatticeLayoutWorker(stackSize: workerStackSize)
        let raw: topoptbridge.LatticeLayoutOpenInfo = try await worker.run {
            var err = topoptbridge.BridgeError()
            let r = topoptbridge.lattice_layout_open(std.string(path), linearDeflection, &err)
            if !err.ok { throw TopOptError(message: String(err.message)) }
            return r
        }
        return LatticeLayoutSession(id: raw.session,
                                    info: OpenInfo(faces: Int(raw.faces), openEdges: Int(raw.open_edges), msOpen: raw.ms_open),
                                    worker: worker)
    }

    /// Lays the lattice. Latest wins: an older `lay` still waiting or running throws CancellationError.
    public func lay(_ settings: Settings) async throws -> Result {
        let mine: UInt64 = lock.withLock {
            generation &+= 1
            return generation
        }
        topoptbridge.lattice_layout_cancel(id)          // the one running now comes back cancelled
        let raw = convert(settings)
        let sid = id
        return try await withTaskCancellationHandler {
            try await worker.run { [weak self] () throws -> Result in
                guard let self, self.isCurrent(mine) else { throw CancellationError() }   // superseded before it started
                var err = topoptbridge.BridgeError()
                let r = topoptbridge.lattice_layout(sid, raw, &err)
                if !err.ok { throw TopOptError(message: String(err.message)) }
                if r.cancelled || !self.isCurrent(mine) { throw CancellationError() }
                return Self.convert(r)
            }
        } onCancel: { [weak self] in
            self?.cancel()
        }
    }

    /// What is at each point for the last layout (empty before the first).
    public func whereAt(_ points: [SIMD3<Float>]) async throws -> [(why: Why, region: Int32)] {
        let sid = id
        var pts = topoptbridge.LatticeLayoutPoints()
        for p in points { pts.xyz.push_back(p.x); pts.xyz.push_back(p.y); pts.xyz.push_back(p.z) }
        let input = pts
        return try await worker.run {
            var err = topoptbridge.BridgeError()
            let r = topoptbridge.lattice_layout_where(sid, input, &err)
            if !err.ok { throw TopOptError(message: String(err.message)) }
            return zip(Array(r.why), Array(r.id)).map { (Why(rawValue: $0.0) ?? .outside, $0.1) }
        }
    }

    /// Every layout running or waiting comes back cancelled.
    public func cancel() {
        lock.withLock { generation &+= 1 }
        topoptbridge.lattice_layout_cancel(id)
    }

    public func close() {
        let first: Bool = lock.withLock {
            defer { closed = true }
            return !closed
        }
        guard first else { return }
        topoptbridge.lattice_layout_close(id)
        worker.stop()
    }

    private func isCurrent(_ gen: UInt64) -> Bool { lock.withLock { gen == generation && !closed } }

    // MARK: conversion

    private func convert(_ s: Settings) -> topoptbridge.LatticeLayoutSettings {
        var o = topoptbridge.LatticeLayoutSettings()
        o.all_lattice = s.allLattice
        o.bead_mm = s.beadMM
        o.min_strut_lines = s.minStrutLines
        o.min_wall_mm = s.minWallMM
        o.rim_mm = s.rimMM
        o.cover_mm = s.coverMM
        for r in s.regions {
            o.region_ids.push_back(r.id)
            o.region_no_lattice.push_back(r.noLattice ? 1 : 0)
            o.region_depth_mm.push_back(r.depthMM)
            o.region_expand_mm.push_back(r.expandMM)
            o.region_face_counts.push_back(Int32(r.faces.count))
            for f in r.faces { o.region_faces.push_back(f) }
        }
        for p in s.protect {
            o.protect_ids.push_back(p.id)
            o.protect_depth_mm.push_back(p.depthMM)
            o.protect_face_counts.push_back(Int32(p.faces.count))
            for f in p.faces { o.protect_faces.push_back(f) }
        }
        o.topology = std.string(s.topology)
        o.algorithm = std.string(s.algorithm)
        o.cell_mm = s.cellMM
        o.cell_max_mm = s.cellMaxMM
        o.cell_min_mm = s.cellMinMM
        o.min_cells_across = s.minCellsAcross
        o.grade_to_shape = s.gradeToShape
        o.band_mm = s.bandMM
        o.band_cell_mm = s.bandCellMM
        o.per_region = s.perRegion
        o.dial = s.dial
        for d in s.regionDials { o.dial_region.push_back(d.region); o.dial_value.push_back(d.dial) }
        o.strut_width_mm = s.strutWidthMM
        o.allow_quilt = s.allowQuilt
        o.strength = s.strength
        o.bars = s.bars
        o.join_loose = s.joinLoose
        o.skin = s.skin
        o.skin_width_mm = s.skinWidthMM
        o.skin_reach_cells = s.skinReachCells
        o.drop_loose = s.dropLoose
        o.small_cells_in_thin_walls = s.smallCellsInThinWalls
        return o
    }

    private static func convert(_ r: topoptbridge.LatticeLayoutResult) -> Result {
        var o = Result()
        o.bars = Array(r.bars)
        o.barEnds = Array(r.bar_ends)
        o.barFlags = Array(r.bar_flags)
        o.barRegion = Array(r.bar_region)
        o.frames = Array(r.frames)
        o.solidCubes = Array(r.solid_cubes)
        o.solidFrame = Array(r.solid_frame)
        o.solidRegion = Array(r.solid_region)
        o.solidWhy = Array(r.solid_why)
        o.steppedEdges = Array(r.stepped_edges)
        o.steppedRegion = Array(r.stepped_region)
        o.emptyRegions = Array(r.empty_regions)
        o.cells = Int(r.cells); o.solidPieces = Int(r.solid_pieces); o.atOneLine = Int(r.at_one_line); o.atWidest = Int(r.at_widest)
        o.stubs = Int(r.stubs); o.joined = Int(r.joined); o.dropped = Int(r.dropped); o.pieces = Int(r.pieces); o.adrift = Int(r.adrift)
        o.floorCellMM = r.floor_cell_mm; o.minStrutMM = r.min_strut_mm; o.openLook = r.open_look; o.touch = r.touch
        o.bedContactMM2 = r.bed_contact_mm2 >= 0 ? r.bed_contact_mm2 : nil
        o.midairStarts = r.midair_starts >= 0 ? Int(r.midair_starts) : nil
        o.readAgain = r.read_again
        o.msRead = r.ms_read; o.msCells = r.ms_cells; o.msBars = r.ms_bars; o.msBridge = r.ms_bridge
        return o
    }

    /// Tests only: the worker thread (its stack size and that it is not main).
    var workerThreadForTests: Thread? { worker.thread }
    /// Tests only: holds the worker until the returned semaphore is signalled (latest-wins, made deterministic).
    func holdWorkerForTests() async -> DispatchSemaphore {
        let gate = DispatchSemaphore(value: 0)
        let worker = self.worker
        await withCheckedContinuation { (started: CheckedContinuation<Void, Never>) in
            Task { try? await worker.run { started.resume(); gate.wait() } }
        }
        return gate
    }
}

/// One thread with its own stack, running jobs in order. Never main.
final class LatticeLayoutWorker: @unchecked Sendable {
    private let cond = NSCondition()
    private var jobs: [() -> Void] = []
    private var stopping = false
    private(set) var thread: Thread?

    init(stackSize: Int) {
        let t = Thread { [self] in self.loop() }   // the thread keeps its worker until stop() lets the loop end
        t.stackSize = stackSize
        t.name = "TopOpt lattice layout"
        t.qualityOfService = .userInitiated
        thread = t
        t.start()
    }

    private func loop() {
        while true {
            cond.lock()
            while jobs.isEmpty && !stopping { cond.wait() }
            if jobs.isEmpty && stopping { cond.unlock(); return }
            let job = jobs.removeFirst()
            cond.unlock()
            job()
        }
    }

    func run<T>(_ body: @escaping () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<T, Error>) in
            cond.lock()
            if stopping {
                cond.unlock()
                c.resume(throwing: CancellationError())
                return
            }
            jobs.append { c.resume(with: Result { try body() }) }
            cond.signal()
            cond.unlock()
        }
    }

    /// Lets the jobs already asked finish, then ends the thread.
    func stop() {
        cond.lock()
        stopping = true
        cond.signal()
        cond.unlock()
    }
}
