// LatticeStrutStream — ★ notes30 (his decision 2026-11-26, option D of the scoping pass, "start the full version"): "The strut
// engine hands over its struts while it works, the way Organic's engine does, so the floors rise in step with the real work."
// The app half (scope.md §3.2, A1-A3). The engine lays its base cells in order of height and keeps a FINISHED LINE (a
// watermark): every strut below it that a sound certificate proves is in the finished lay EXACTLY (same ends, same width, same
// flags) is handed to the session's StrutTap the moment it is proven; the solid view's map is made behind the same line. While
// the lay runs, the page reads the tap about every 0.15 s (`LatticeStrutWatch`: a Task on the main actor, the read synchronous
// and never through the session's worker, which the lay occupies — Organic's LatticeGrowthWatch, the same cursor), appends the
// new struts here, and the build timelapse (LatticeBuildTimelapse) raises its floors behind the line; the bars pass draws them
// from an append-only GPU buffer (LatticeLayoutBarsPass.syncStream). What the line cannot promise mid-lay (the pieces cut at the
// surface, the skin) lands with the lay: the cladding.
// HIS RULES kept: nothing drawn is ever taken away (every strut here is in the print file as it is); never loose struts over a
// bare part (a floor shows only once the line has passed it); the drawing follows the print file.
// Pure model + poll: the tests feed it a fake engine (LatticeStrutTap).
import Foundation
import QuartzCore
import simd

/// ★ notes30: one read of the engine's strut tap (core's StrutTap, scope §3.2 (5)): the lay, its plan, the finished line, the
/// struts handed over from `from` on, and the map's rows made behind the line from `mapFrom` on.
public struct LatticeStrutRead: Sendable, Equatable {
    /// Which lay (the tap counts them; a new lay starts again at 0). 0: none yet.
    public var lay: UInt64
    /// 0 none yet, 1 laying the cells, 2 the struts, 3 the pieces, 4 the map, 5 done.
    public var phase: Int
    /// The index to read the struts from next time.
    public var next: Int
    /// The plan (model coordinates): the up the cells are laid along (the line rises along it) and the box they are laid in.
    /// nil: not planned yet.
    public var up: SIMD3<Float>?
    public var lo: SIMD3<Float>
    public var hi: SIMD3<Float>
    /// The base cells laid, of all planned (the line's progress).
    public var slotsDone: Int
    public var slotsTotal: Int
    /// THE FINISHED LINE (model mm along `up`): every strut the engine will hand over mid-lay whose highest point is at or
    /// below it has been handed over. +∞: every one.
    public var line: Float
    /// How far any strut rises above its lower end (along up): a floor's struts are all out once the line is past its top by
    /// this much.
    public var reach: Float
    /// 7 per strut: a xyz, b xyz, width mm (the part's own coordinates); one flags byte each (core's bar_flags).
    public var bars: [Float]
    public var flags: [UInt8]
    /// THE MAP behind the line (asked with the lay): every voxel whose centre lies at or below `mapLine` (along up) is final;
    /// +∞ all of it. The rows handed over from `mapFrom` on: [z0, z1) of the map grid, 2 bytes a voxel (open, inside).
    public var mapLine: Float
    public var mapNext: Int
    public var mapRows: [MapRows]
    public struct MapRows: Sendable, Equatable {
        public var z0: Int32, z1: Int32
        public var rg: [Int8]
        public init(z0: Int32, z1: Int32, rg: [Int8]) { self.z0 = z0; self.z1 = z1; self.rg = rg }
    }
    public var count: Int { bars.count / 7 }

    public init(lay: UInt64, phase: Int = 0, next: Int = 0, up: SIMD3<Float>? = nil, lo: SIMD3<Float> = .zero,
                hi: SIMD3<Float> = .zero, slotsDone: Int = 0, slotsTotal: Int = 0, line: Float = -.infinity, reach: Float = 0,
                bars: [Float] = [], flags: [UInt8] = [], mapLine: Float = -.infinity, mapNext: Int = 0, mapRows: [MapRows] = []) {
        self.lay = lay; self.phase = phase; self.next = next; self.up = up; self.lo = lo; self.hi = hi
        self.slotsDone = slotsDone; self.slotsTotal = slotsTotal; self.line = line; self.reach = reach
        self.bars = bars; self.flags = flags; self.mapLine = mapLine; self.mapNext = mapNext; self.mapRows = mapRows
    }
}

/// ★ notes30: the session's strut tap, as the page reads it: the real one is the layout session's (core's StrutTap through the
/// bridge, lattice_layout_strut_read: synchronous, ANY thread, never through the session's worker); the tests' a fake engine.
public protocol LatticeStrutTap: AnyObject {
    /// The session's NEXT lay hands its struts over, its line rising along `up` (model coordinates), and makes the solid view's
    /// map on `map` behind the line (nil: no map). Changes nothing the lay makes.
    func streamNextLay(up: SIMD3<Float>, map: (origin: SIMD3<Float>, voxel: Float, dims: SIMD3<Int32>)?)
    /// The struts from `from` on (at most `most`; 0 all) and the map's rows from `mapFrom` on, with the lay's number, plan and
    /// line.
    func strutRead(from: Int, most: Int, mapFrom: Int) throws -> LatticeStrutRead
}

/// ★ notes30: where a poll of an engine's tap stands — shared by Organic's growth (LatticeGrowthPoller) and the strut stream
/// (LatticeStrutWatch): lay numbers (a new lay starts again; one seen part-way is read again from its start), a floor (the lay
/// this watch began after, and each lay that landed), the phase. Pure.
struct LatticeTapCursor: Equatable {
    /// Lays up to this one are not watched: the tap's lay when the watch began, then each lay that landed.
    private(set) var floor: UInt64
    private(set) var lay: UInt64?
    /// Where the next read starts.
    var next = 0
    private(set) var phase = 0

    struct Step: Equatable {
        /// A new lay: what was taken of the last goes.
        var restart = false
        /// Take this read's pieces.
        var take = false
        /// The phase moved (or a new lay's first).
        var phase: Int?
        /// A new lay seen part-way through a read: read it again from its start, now.
        var readAgain = false
    }

    init(baseline: UInt64) { floor = baseline }

    /// The lay `lay` (the tap's newest) landed: it and every earlier one are done.
    mutating func landed(_ lay: UInt64) { floor = Swift.max(floor, lay) }

    /// A read of lay `lay` at `phase`, made from `from` (this cursor's `next` when it was asked), whose next index is `next`.
    mutating func take(lay r: UInt64, phase p: Int, next n: Int, from: Int) -> Step {
        var s = Step()
        guard r > floor else { return s }   // no lay yet, the one before this watch began, or one already landed
        if r != lay {
            lay = r; next = 0; phase = 0
            s.restart = true
            if from != 0 { s.readAgain = true; return s }
        }
        s.take = true
        next = n
        if p != phase { phase = p; s.phase = p }
        return s
    }
}

/// ★ notes30: the struts the engine has handed over so far for the lay on screen, append-only, as the 3D view draws them, with
/// the lay's plan, the finished line and the map behind it. Main thread only (the watch writes it, the renderer reads it).
public final class LatticeStrutStream {
    /// A new start (reset, or a new lay): the renderer begins its buffer again.
    public private(set) var epoch = 0
    /// Two per strut, LatticeLayoutBarsPass.pack's layout: (a xyz, radius) (b xyz, flags).
    public private(set) var packed: [SIMD4<Float>] = []
    public var count: Int { packed.count / 2 }
    /// The struts as handed over (7 floats each: a, b, width) — the in-app check against the landed lattice.
    public private(set) var bars: [Float] = []
    /// The plan: the up the line rises along and the box the cells are laid in (model coordinates). nil: not planned yet.
    public private(set) var plan: (up: SIMD3<Float>, lo: SIMD3<Float>, hi: SIMD3<Float>)?
    /// The finished line and a strut's reach (along up); see LatticeStrutRead.
    public private(set) var line: Float = -.infinity
    public private(set) var reach: Float = 0
    /// Every strut the engine will hand over mid-lay is out (the line past the top, or the lay landed).
    public var allHanded: Bool { sealed || line >= .greatestFiniteMagnitude }
    /// The base cells laid, of all (0 → 1).
    public private(set) var progress: Double = 0
    public private(set) var phase = 0
    /// ★ notes29 H3: the up the lattice is laid standing along (the face he kept): its bridges drawn level on it. nil: +Z.
    public var printUp: SIMD3<Float>?
    /// The lay landed (or stopped): nothing more is taken until a new lay resets it.
    public private(set) var sealed = false
    /// Struts taken since this object was made (tests).
    public private(set) var takenTotal = 0
    /// ★ notes30: a strut handed over for a floor that already stands is held back — never one popping in on a floor at rest
    /// (core: "a strut below the line … comes later, its piece found held"); it comes with the cladding at the landing. The
    /// timelapse says which (LatticeBuildShow). Held back this lay (tests).
    var holdBack: ((SIMD3<Float>, SIMD3<Float>) -> Bool)?
    public private(set) var heldBack = 0

    // MARK: the map behind the line

    /// The map as known so far (voxels not made yet: (−127, −127), air), smoothed when asked; nil — none asked.
    public private(set) var map: LatticeLayoutSolidGrid?
    /// Every voxel at or below this (along up) is final in `map` (smoothed too, when asked).
    public private(set) var mapReadyLine: Float = -.infinity
    /// The map has been asked for (the solid view) and is being made behind the line.
    public var hasMap: Bool { map != nil }
    /// Every voxel of the map is final.
    public var mapAllMade: Bool { map != nil && mapReadyLine >= .greatestFiniteMagnitude }
    /// A floor's walls come off once the map is ready this far past its top: the cut's softening reaches 4 voxels.
    public var mapMargin: Float { (map?.voxel ?? 0) * 5 }
    /// The map's rows changed, in order (the renderer re-sends those since the version it holds).
    public private(set) var mapVersion = 0
    private(set) var mapChanges: [(version: Int, rows: Range<Int>)] = []
    /// The rows as the engine made them (the softened map is made from these).
    private var rawRG: [Int8] = []
    private var rawLine: Float = -.infinity
    /// ★ notes28: the regular lattice's cut drawn smooth (Print-accurate preview off): the map softened before it is shown.
    private var smoothCut = false
    private var smoothing = false
    private var smoothAgain = false
    /// RED CONTROL / tests: soften on the caller's thread (no background task).
    nonisolated(unsafe) static var smoothInline = false

    public init() {}

    /// A new lay on screen: nothing taken yet. `map`: the solid view's map geometry the engine makes behind the line (nil:
    /// X-ray), softened when `smoothCut`.
    public func reset(map: (origin: SIMD3<Float>, voxel: Float, dims: SIMD3<Int32>)? = nil, smoothCut: Bool = false,
                      printUp: SIMD3<Float>? = nil) {
        epoch &+= 1
        packed = []; bars = []; heldBack = 0
        plan = nil; line = -.infinity; reach = 0; progress = 0; phase = 0
        sealed = false
        self.printUp = printUp
        self.smoothCut = smoothCut
        mapChanges = []; mapVersion &+= 1
        rawLine = -.infinity; mapReadyLine = -.infinity
        smoothAgain = false
        if let g = map, g.dims.x > 0, g.dims.y > 0, g.dims.z > 0 {
            let n = Int(g.dims.x) * Int(g.dims.y) * Int(g.dims.z)
            rawRG = [Int8](repeating: -127, count: 2 * n)
            self.map = LatticeLayoutSolidGrid(token: Self.mapToken(epoch), origin: g.origin, voxel: g.voxel, dims: g.dims,
                                              rg: rawRG, smooth: smoothCut)
            mapChanges = [(mapVersion, 0..<Int(g.dims.z))]
        } else {
            rawRG = []
            self.map = nil
        }
    }
    /// The stream map's token (never a landed lay's: those count up from 1).
    static func mapToken(_ epoch: Int) -> Int { -1_000_000 - epoch }

    /// The lay landed (or stopped): nothing more is taken.
    public func seal() { sealed = true }

    /// One read's worth: the plan, the line, the new struts, the new map rows.
    func take(_ r: LatticeStrutRead) {
        guard !sealed else { return }
        phase = r.phase
        if let u = r.up, simd_length(u) > 1e-6, plan == nil {
            plan = (simd_normalize(u), simd_min(r.lo, r.hi), simd_max(r.lo, r.hi))
        }
        if r.slotsTotal > 0 { progress = Swift.min(1, Double(r.slotsDone) / Double(r.slotsTotal)) }
        reach = Swift.max(reach, r.reach)
        line = Swift.max(line, r.line)
        let n = Swift.min(r.bars.count / 7, r.flags.isEmpty ? r.bars.count / 7 : r.flags.count)
        if n > 0 {   // (LatticeLayoutBarsPass.pack's layout: radius = width / 2, the second's w = the flags)
            packed.reserveCapacity(packed.count + 2 * n)
            let b = r.bars
            for i in 0..<n {
                let k = 7 * i
                if let h = holdBack, h(SIMD3(b[k], b[k + 1], b[k + 2]), SIMD3(b[k + 3], b[k + 4], b[k + 5])) { heldBack += 1; continue }
                packed.append(SIMD4(b[k], b[k + 1], b[k + 2], 0.5 * b[k + 6]))
                packed.append(SIMD4(b[k + 3], b[k + 4], b[k + 5], i < r.flags.count ? Float(r.flags[i]) : 0))
            }
            bars += b[0..<(7 * n)]
            takenTotal += n
        }
        takeMap(r)
    }

    private func takeMap(_ r: LatticeStrutRead) {
        guard var m = map else { return }
        let nx = Int(m.dims.x), ny = Int(m.dims.y), nz = Int(m.dims.z), slab = 2 * nx * ny
        var lo = Int.max, hi = Int.min
        for rows in r.mapRows {
            let z0 = Swift.max(0, Int(rows.z0)), z1 = Swift.min(nz, Int(rows.z1))
            guard z1 > z0, rows.rg.count == slab * (Int(rows.z1) - Int(rows.z0)) else { continue }
            let skip = (z0 - Int(rows.z0)) * slab
            rawRG.withUnsafeMutableBufferPointer { dst in
                rows.rg.withUnsafeBufferPointer { src in
                    _ = memcpy(dst.baseAddress! + z0 * slab, src.baseAddress! + skip, (z1 - z0) * slab)
                }
            }
            lo = Swift.min(lo, z0); hi = Swift.max(hi, z1)
        }
        let lineMoved = r.mapLine > rawLine
        rawLine = Swift.max(rawLine, r.mapLine)
        guard lo < hi || lineMoved else { return }
        if !smoothCut {
            if lo < hi {
                m.rg = rawRG
                map = m
                mapVersion &+= 1
                note(lo..<hi)
            }
            mapReadyLine = rawLine
            return
        }
        soften()
    }

    /// The map softened (the cut's line, LatticeLayoutSolidGrid.cutSmoothed) from the rows made so far, off the main thread,
    /// one at a time: what came meanwhile is softened next. The voxels a floor needs are final once the line is `mapMargin`
    /// past its top (the softening reads 4 voxels round).
    private func soften() {
        guard let m = map else { return }
        if smoothing { smoothAgain = true; return }
        smoothing = true
        let raw = rawRG, dims = m.dims, at = rawLine, e = epoch
        let done: ([Int8]) -> Void = { [weak self] rg in
            guard let self else { return }
            self.smoothing = false
            guard self.epoch == e, var now = self.map else { return }
            now.rg = rg
            self.map = now
            self.mapVersion &+= 1
            self.note(0..<Int(dims.z))
            self.mapReadyLine = Swift.max(self.mapReadyLine, at)
            self.softened?()
            if self.smoothAgain { self.smoothAgain = false; self.soften() }
        }
        if Self.smoothInline { done(LatticeLayoutSolidGrid.cutSmoothed(raw, dims: dims)); return }
        Task { @MainActor in
            let rg = await Task.detached(priority: .userInitiated) { LatticeLayoutSolidGrid.cutSmoothed(raw, dims: dims) }.value
            done(rg)
        }
    }
    /// Called when a softened map is ready (the page asks the timelapse which floors are ready again).
    public var softened: (() -> Void)?

    private func note(_ rows: Range<Int>) {
        mapChanges.append((mapVersion, rows))
        if mapChanges.count > 64, let first = mapChanges.first, let last = mapChanges.last {
            mapChanges = [(last.version, Swift.min(first.rows.lowerBound, last.rows.lowerBound)..<Int(map?.dims.z ?? 0))]
        }
    }

    /// The map's rows changed since version `v` (nil: none; all of them when `v` is older than what is kept).
    func mapRowsChanged(since v: Int) -> Range<Int>? {
        guard let m = map else { return nil }
        guard let first = mapChanges.first else { return nil }
        if v < first.version - 1 { return 0..<Int(m.dims.z) }
        var lo = Int.max, hi = Int.min
        for c in mapChanges where c.version > v { lo = Swift.min(lo, c.rows.lowerBound); hi = Swift.max(hi, c.rows.upperBound) }
        return lo < hi ? lo..<hi : nil
    }

    // MARK: ★ the in-app counter (scope §3.2): a handed-over strut absent from the landed lattice breaks the promise

    /// How many struts handed over are NOT in `landed` (7 floats each), bit for bit (a, b, width). Expected 0, always.
    func missing(from landed: [Float]) -> Int {
        guard !bars.isEmpty else { return 0 }
        var have = Set<StrutKey>()
        have.reserveCapacity(landed.count / 7)
        var i = 0
        while i + 6 < landed.count { have.insert(StrutKey(landed, i)); i += 7 }
        var gone = 0
        i = 0
        while i + 6 < bars.count { if !have.contains(StrutKey(bars, i)) { gone += 1 }; i += 7 }
        return gone
    }
    struct StrutKey: Hashable {
        var a: UInt64, b: UInt64, c: UInt64, d: UInt32
        init(_ v: [Float], _ i: Int) {
            func p(_ x: Float, _ y: Float) -> UInt64 { UInt64(x.bitPattern) << 32 | UInt64(y.bitPattern) }
            a = p(v[i], v[i + 1]); b = p(v[i + 2], v[i + 3]); c = p(v[i + 4], v[i + 5]); d = v[i + 6].bitPattern
        }
    }
}

/// ★ notes30: the page's poll of the strut tap while a regular lay runs — a Task on the main actor, every `every` seconds, that
/// ends when the lay ends (`stop`), is cancelled, or the session can no longer be read. Organic's LatticeGrowthWatch's shape.
@MainActor
final class LatticeStrutWatch {
    typealias Reader = (_ from: Int, _ most: Int, _ mapFrom: Int) throws -> LatticeStrutRead
    let stream: LatticeStrutStream
    private(set) var cursor: LatticeTapCursor
    private var mapNext = 0
    /// Reads made (tests: none once the lay ended).
    private(set) var reads = 0
    private let read: Reader
    private let most: Int
    private let moved: () -> Void
    private var task: Task<Void, Never>?
    var running: Bool { task != nil }

    /// The baseline (the tap's lay now) is read at once, so the lay this watch is for is the next one.
    init(stream: LatticeStrutStream, every: Double, most: Int, read: @escaping Reader, moved: @escaping () -> Void) {
        self.stream = stream; self.read = read; self.most = most; self.moved = moved
        cursor = LatticeTapCursor(baseline: (try? read(Int.max, 1, Int.max).lay) ?? 0)
        let gap = UInt64(Swift.max(0.01, every) * 1_000_000_000)
        task = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                if let w = self { w.tick() } else { return }
                try? await Task.sleep(nanoseconds: gap)
            }
        }
    }

    /// The lay ended (or a newer one began): no more reads.
    func stop() {
        task?.cancel()
        task = nil
    }

    /// The finished lattice is on screen: the tap's newest lay is done, whatever of it a read has not reached yet.
    func landed() {
        cursor.landed((try? read(Int.max, 1, Int.max).lay) ?? cursor.lay ?? 0)
    }

    /// One poll: what came since the last, onto the stream. (Also called once more as the lay lands: its last struts.)
    func tick(force: Bool = false) {
        guard task != nil || force else { return }
        for _ in 0..<2 {   // a new lay seen part-way is read again from its start, in the same poll
            let from = cursor.next
            guard let r = try? read(from, most, mapNext) else { stop(); return }   // the session is closed
            reads += 1
            let s = cursor.take(lay: r.lay, phase: r.phase, next: r.next, from: from)
            if s.restart { mapNext = 0 }
            if s.readAgain { continue }
            if s.take {
                stream.take(r)
                mapNext = r.mapNext
                moved()
            }
            return
        }
    }
}

/// ★ notes30: when the engine is expected to land, from the line's own progress (the base cells laid of all) and what the rest
/// of the lay took the last time on this part (`afterShare`: the share of the lay after its cells). Pure.
enum LatticeStrutPace {
    /// Progress below this says too little to go by.
    static let leastProgress = 0.05
    /// `start` the ask, `cellsFrom` when the engine planned (its cells began), `cellsEnd` when they were all laid (nil: not
    /// yet), `now`, `progress` 0 → 1. nil: nothing to go by.
    static func expectedLanding(start: Double, cellsFrom: Double?, cellsEnd: Double? = nil, now: Double, progress: Double,
                                afterShare: Double?, lastLayS: Double?) -> Double? {
        let share = Swift.min(Swift.max(afterShare ?? 0, 0), 0.9)
        if let e = cellsEnd { return start + (e - start) / (1 - share) }
        if let c = cellsFrom, progress >= leastProgress, now > c {
            let end = c + (now - c) / Swift.min(1, progress)
            return start + (end - start) / (1 - share)
        }
        return lastLayS.map { start + $0 }
    }
    /// What the lay after its cells took, of the whole (learned at the landing): nil when the cells' end was never seen.
    static func afterShare(start: Double, cellsEnd: Double?, landed: Double) -> Double? {
        guard let c = cellsEnd, landed > start, c >= start, c <= landed else { return nil }
        return (landed - c) / (landed - start)
    }
}
