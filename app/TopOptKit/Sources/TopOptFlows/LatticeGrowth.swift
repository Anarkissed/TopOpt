// LatticeGrowth — ★ his 11-22 ("Can we implement this like an animation? Could the user literally *watch* the lattice grow
// from nothing? … Time isn't wasted if there's an interesting animation running of the actual lattice being grown - this
// allows for patience from the user."), the app half. The engine hands every piece of vine an Organic lay lays to the
// session's GrowthTap (core); while the lay runs, the preview reads it about every 0.15 s (`LatticeGrowthWatch`: a Task on the
// main actor, the read synchronous and never through the session's worker, which the lay occupies), appends the new pieces
// here, and the 3D view draws them (`LatticeGrowthPass`, an append-only GPU buffer): the vines rising from their seeds in the
// lattice's own purple, the newest pieces (the growing tips) brighter. When the lay lands, the finished lattice replaces the
// growth; a new lay starts the growth again; a remembered preview shows none.
// The Lattice button's line names the phase the engine is in (LatticePreviewMode.phaseWords).
//
// ★ his notes 2026-11-23 (img 49): "It needs to be in 3D. There needs to be depth. I would prefer having the walls removed and
// seeing the actual 3d models of the lattices grow - but only the ones that are visible to me". The pieces are drawn as real
// tubes at their strut width (`radiusByRegion`: what each region's group asked — the engine's tap carries no width), lit and
// depth-tested as the landed lattice is (LatticeGrowthPass); the part is opened by the map this lay opens it with, else drawn
// in X-ray while the vines grow (`landedHold` keeps it so until the landed lattice's own map opens it).
//
// ★ his words after release 16 (a), "start an animation by removing the walls … THEN starting the growing animation … the
// recording of the vine growth … at about 10-12 frames per second, slowing the animation down": the 3D view shows the lay
// through its `LatticeGrowthReplay` — the walls first (`opening`: dissolved by this lay's map, or a fade to X-ray), then the
// recording played back in steps, behind the engine; the moment the lattice lands what is left is shown within a second and
// the landed lattice takes over (the tubes sink into it). Item 3 of 11-23: once the replay has shown everything recorded and
// the engine is still past its growing (phase 2 on), a band of light rises through the grown vines until it lands.
import Foundation
import Combine
import QuartzCore
import simd
import TopOptKit

/// The vines an Organic lay has laid so far, append-only, as the 3D view draws them. Main thread only (the preview writes it,
/// the renderer reads it while it draws).
public final class LatticeGrowth {
    /// Two per piece: (a xyz, birth) and (b xyz, radius). `birth` is the poll the piece came in, plus its place in that poll's
    /// batch (the batch's newest at the poll's own number). ★ notes24: `radius` (mm) is the tube's (`radiusByRegion`).
    public private(set) var pieces: [SIMD4<Float>] = []
    public var count: Int { pieces.count / 2 }
    /// A new start (cleared, or a new lay): the renderer begins its buffer again.
    public private(set) var epoch = 0
    /// The newest poll's number (the recording's end, in birth units).
    public private(set) var clock: Float = 0
    /// The finished lattice landed: the growth sinks into it for `fadeS` from here (after the replay caught up). nil: not.
    public private(set) var fadeStarted: CFTimeInterval?
    /// ★ notes29 (his "the end always feels too rushed"): the sink, 1.0 s eased (release 20: 0.35 s, straight) — his to tune.
    nonisolated(unsafe) public static var fadeS: CFTimeInterval = 1.0
    nonisolated(unsafe) static var fadeEases = true
    static let release20FadeS: CFTimeInterval = 0.35
    /// From the landing to the growth gone, at most: the catch-up (or, nothing left, the rest), then the sink.
    public static var landingS: CFTimeInterval {
        Swift.max(Swift.max(LatticeGrowthReplay.catchUpEndS, LatticeGrowthReplay.restS) + fadeS,
                  LatticeGrowthReplay.minTotalS)   // ★ his pick: a quick lay's end fills the 7 s
    }
    /// Fires on every visible change: the 3D view redraws itself (no page pass, never the workspace's body).
    public let changed = PassthroughSubject<Void, Never>()
    /// Pieces appended since this object was made (tests: growth was shown).
    public private(set) var appendedTotal = 0
    /// The lay it grew for has landed (or stopped): nothing more is appended to it until a new lay `restart`s it.
    public private(set) var sealed = false

    /// ★ notes24: each region's tube radius (mm), and the radius of a region no group names.
    public private(set) var radiusByRegion: [Int32: Float] = [:]
    public private(set) var radiusDefault: Float = 0.45
    /// ★ How this lay's part opens (`layBegins`).
    public enum Opening: Equatable {
        /// X-ray: there are no walls to open.
        case none
        /// The map on screen is this lay's: the part is open already.
        case open
        /// The map this lay opens its faces with, made before it (362's gridAhead): the walls dissolve away with it.
        case dissolve(LatticeLayoutSolidGrid)
        /// No map yet: the part fades to X-ray and the vines grow inside it.
        case xray
        public init(solid: Bool, mapFits: Bool, ahead: LatticeLayoutSolidGrid?) {
            self = !solid ? .none : mapFits ? .open : ahead.map { .dissolve($0) } ?? .xray
        }
    }
    public private(set) var opening: Opening = .none
    /// The map on screen opens this lay's faces (the Draft's for its exact lattice, the last Look's).
    public var mapOpensFaces: Bool { opening == .open }
    /// The map made before this lay that its walls dissolve with (nil: none).
    public var aheadMap: LatticeLayoutSolidGrid? { if case .dissolve(let m) = opening { return m }; return nil }
    /// The engine's phase (core's GrowthTap: 1 growing, 2 pruning, 3 re-seeding, 4 reaching the walls, 5 finishing; 0 none).
    public private(set) var phase = 0
    /// ★ item 3: since when the band of light runs (the replay caught up, the engine past its growing). nil: not running.
    public private(set) var workingSince: CFTimeInterval?
    /// ★ notes29 (his print orientation): the print's up, in the part's own coordinates, when the lattice is laid standing on
    /// the face he kept (the vines climb it; the band of light rises along it, a print layer by layer). nil: the view's own up,
    /// as before.
    public var printUp: SIMD3<Float>?
    /// ★ notes24: the lay landed after growing: the part stays in X-ray (if it was) until the landed lattice's own map opens it.
    public private(set) var landedHold = false
    /// ★ the replay of this lay (nil: none asked — every recorded piece shows at once, as before).
    private(set) var replay: LatticeGrowthReplay?
    /// RED CONTROLS (tests): no band; the replay never sped up at the landing (the finished lattice would wait for it).
    nonisolated(unsafe) public static var controlNoWorkingBand = false
    nonisolated(unsafe) public static var controlNoCatchUp = false
    /// The view's redraws a second while something moves (the walls, the band, the landing; the replay's steps as they come).
    static let tickFPS: Double = 30
    private var tickTask: Task<Void, Never>?
    private var lastShown = -1
    /// A new lay that began while the last one was still landing: its pieces wait until that landing ends.
    private var queued: (xyz: [Float], region: [Int32], lay: PendingLay?)?
    private var pendingLay: PendingLay?
    struct PendingLay { var opening: Opening; var radius: [Int32: Float]; var radiusDefault: Float; var expectedLeftS: Double? }

    public init() {}

    /// ★ notes24: an Organic lay of `groups` is about to run (the preview, just before it asks the engine): each region's tube
    /// radius, how its part opens, and how long the last lay like it took from now (the replay's pacing; nil: none).
    public func layBegins(_ groups: [LatticeLayoutSession.OrganicGroup], lineMM: Double, opening: Opening,
                          expectedLeftS: Double? = nil, now: CFTimeInterval = CACurrentMediaTime()) {
        var m: [Int32: Float] = [:]
        for g in groups {
            let r = Float(Self.strutWidthMM(g.ask, lineMM: lineMM) / 2)
            for id in g.regions { m[id] = r }
        }
        let lay = PendingLay(opening: opening, radius: m, radiusDefault: Float(Self.strutWidthMM(nil, lineMM: lineMM) / 2),
                             expectedLeftS: expectedLeftS)
        // ★ notes29: Skip all animations — no walls, no replay, no growth: the page's "Refreshing Lattice" card instead
        if AppSettings.skipAllAnimations { stop(); return }
        settle(now)
        if landing(now) { pendingLay = lay; return }   // the last lay's landing first
        begin(lay, now: now)
    }

    private func begin(_ lay: PendingLay, now: CFTimeInterval) {
        radiusByRegion = lay.radius
        radiusDefault = lay.radiusDefault
        opening = lay.opening
        let walls = lay.opening != .none && lay.opening != .open
        replay = LatticeGrowthReplay(start: now, walls: walls, expectedEnd: lay.expectedLeftS.map { now + $0 })
        workingSince = nil
        changed.send()
        tick()
    }

    /// The strut width (mm) a group asked: its one width, or the middle of its light-to-heavy range; none asked (the engine's
    /// own): two print lines, the thinnest strut the print makes.
    static func strutWidthMM(_ ask: LatticeLayoutSession.Organic?, lineMM: Double) -> Double {
        let line = lineMM > 0 ? lineMM : 0.45
        guard let a = ask, a.widthMM > 0 else { return 2 * line }
        return a.widthHeavyMM > a.widthMM ? (a.widthMM + a.widthHeavyMM) / 2 : a.widthMM
    }

    /// A poll's new pieces (6 floats each: a, b), in the order the engine laid them. Ignored once sealed.
    func append(xyz: [Float], region: [Int32]) {
        if AppSettings.skipAllAnimations { return }   // ★ notes29: Skip all animations — nothing grows on screen
        if queued != nil { queued!.xyz += xyz; queued!.region += region; return }
        let n = Swift.min(xyz.count / 6, region.count)
        guard n > 0, !sealed else { return }
        clock += 1
        pieces.reserveCapacity(pieces.count + 2 * n)
        for i in 0..<n {
            let k = 6 * i
            let birth = clock - 1 + Float(i + 1) / Float(n)
            pieces.append(SIMD4(xyz[k], xyz[k + 1], xyz[k + 2], birth))
            pieces.append(SIMD4(xyz[k + 3], xyz[k + 4], xyz[k + 5], radiusByRegion[region[i]] ?? radiusDefault))
        }
        appendedTotal += n
        lastShown = shownCount(at: CACurrentMediaTime())   // (this change is drawn now)
        changed.send()
        tick()
    }

    /// The engine's phase moved.
    func phaseMoved(_ p: Int, now: CFTimeInterval = CACurrentMediaTime()) {
        phase = p
        advance(to: now)
        tick()   // (the band may start now: never a frozen picture)
    }

    // MARK: the replay

    /// Moves the replay to `t`: its playhead, and the band (on once it has shown everything recorded and the engine is past
    /// its growing, until the lattice lands).
    func advance(to t: CFTimeInterval) {
        settle(t)
        replay?.advance(to: t, recorded: Double(clock))
        let caught = replay.map { t >= $0.replayStart && $0.caughtUp(recorded: Double(clock)) } ?? true
        let band = phase >= 2 && !sealed && count > 0 && caught && !Self.controlNoWorkingBand
        if band, workingSince == nil { workingSince = t }
        if !band { workingSince = nil }
    }

    /// The playhead (birth units) at `t`: every piece born up to it shows. No replay: all of them.
    func playhead(at t: CFTimeInterval) -> Float {
        advance(to: t)
        guard let r = replay else { return clock }
        return Float(r.shown)
    }

    /// How many pieces show at `t` (the first ones: the recording is in birth order).
    public func shownCount(at t: CFTimeInterval) -> Int {
        let head = playhead(at: t)
        guard head < clock else { return count }
        var lo = 0, hi = count   // the first piece born after the playhead
        while lo < hi {
            let mid = (lo + hi) / 2
            if pieces[2 * mid].w <= head + 1e-6 { lo = mid + 1 } else { hi = mid }
        }
        return lo
    }

    /// How far the walls have gone at `t` (0 → 1; 1 when this lay opens none).
    public func wallsProgress(at t: CFTimeInterval) -> Float {
        Float(replay?.wallsProgress(t) ?? 1)
    }

    /// This lay is under way on screen (its walls, its replay, its landing): from `layBegins` until its growth is gone.
    public var layOnScreen: Bool { replay != nil }

    /// The landed lattice waits at `t` for the replay to show what was left (at most `LatticeGrowthReplay.catchUpEndS`).
    public func holdsLanded(at t: CFTimeInterval) -> Bool {
        guard sealed, replay != nil, let f = fadeStarted else { return false }
        return t < f   // (the sink starts once the replay has shown it all)
    }

    /// The band runs (tests).
    var working: Bool { workingSince != nil }

    /// Tests that predate the replay: every recorded piece shows as it comes (no walls, no replay).
    func replayOffForTesting() { replay = nil }

    // MARK: lays begin and end

    /// A new lay's first pieces (the watch saw it start): nothing grown, its pieces welcome. While the last lay is still
    /// landing, its pieces wait for that landing to end (never cutting the last one's replay short).
    func restart(now: CFTimeInterval = CACurrentMediaTime()) {
        settle(now)
        if landing(now) {
            if queued == nil { queued = ([], [], nil) }
            return
        }
        clearPieces()
        sealed = false
        landedHold = false
        phase = 0
        if var r = replay { r = LatticeGrowthReplay(start: r.start, walls: r.walls, expectedEnd: r.expectedEnd); replay = r }
    }

    /// No lay any more (the preview's stop: a new lay coming, a remembered lattice, the preview closed): everything goes.
    func stop() {
        queued = nil; pendingLay = nil
        clearPieces()
        replay = nil
        opening = .none
        sealed = false
        landedHold = false
        phase = 0
        tickTask?.cancel(); tickTask = nil
    }

    /// The lay this grew for is done: the finished lattice `landed` (the replay catches up within a second, then the growth
    /// sinks into it), or nothing is on screen (a refusal, an error: gone at once).
    func seal(landed: Bool, now: CFTimeInterval = CACurrentMediaTime()) {
        settle(now)
        if sealed, fadeStarted != nil {   // the last lay is still landing and this one landed too: its growth is moot
            guard landed else { stop(); return }
            pendingLay = nil; queued = nil
            return
        }
        sealed = true
        workingSince = nil
        guard landed, !pieces.isEmpty || replay != nil else { stop(); return }
        landedHold = true
        if Self.controlNoCatchUp {   // RED CONTROL: the replay goes on at its own pace; the lattice waits for it
            replay?.advance(to: now, recorded: Double(clock))
            let left = replay.map { Double(clock) - $0.shown } ?? 0
            let rate = replay.map { $0.pace(at: now, recorded: Double(clock)) } ?? 1
            fadeStarted = now + left * LatticeGrowthReplay.pollS / Swift.max(rate, 1e-3)
        } else {
            replay?.land(at: now, recorded: Double(clock))
            fadeStarted = replay?.caughtUpAt ?? now
        }
        changed.send()
        tick()
    }

    /// The last landing's end, if `t` is past it and the ticker has not seen it yet (never wait on the ticker).
    private func settle(_ t: CFTimeInterval) {
        if sealed, let f = fadeStarted, t >= f + Self.fadeS { landed(now: t) }
    }

    /// The last lay is landing at `t`: sealed, its growth not yet gone.
    func landing(_ t: CFTimeInterval) -> Bool {
        guard sealed, let f = fadeStarted else { return false }
        return t < f + Self.fadeS
    }

    /// The landing ended: the growth goes (still sealed: a read behind the lay never brings it back); a lay that began
    /// meanwhile takes its place, its pieces (and its phase) as they came.
    private func landed(now: CFTimeInterval) {
        let q = queued, p = pendingLay
        queued = nil; pendingLay = nil
        clearPieces()
        replay = nil
        opening = .none
        if q == nil { phase = 0 }
        if let p { begin(p, now: now); landedHold = false }
        if let q {
            sealed = false; landedHold = false
            if !q.xyz.isEmpty { append(xyz: q.xyz, region: q.region) }
        }
    }

    private func clearPieces() {
        let had = !pieces.isEmpty || fadeStarted != nil
        fadeStarted = nil
        workingSince = nil
        pieces = []
        clock = 0
        lastShown = -1
        epoch &+= 1
        if had { changed.send() }
    }

    /// How much of the growth shows at `t`: 1, and toward 0 over `fadeS` once the replay of the landed lay caught up (the
    /// tubes' size, sinking into the finished lattice).
    public func alpha(at t: CFTimeInterval) -> Float {
        guard let f = fadeStarted else { return 1 }
        let x = Swift.max(0, Swift.min(1, (t - f) / Self.fadeS))
        return Float(1 - (Self.fadeEases ? x * x * (3 - 2 * x) : x))   // ★ notes29: eased in and out
    }

    // MARK: the redraws

    /// The view is redrawn while something moves: the walls opening, each replay step that shows more, the band, the
    /// landing; the landing's end clears the growth. Stops when nothing is left to move.
    private func tick() {
        guard tickTask == nil else { return }
        let gap = UInt64(1_000_000_000 / Self.tickFPS)
        tickTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                if !self.step(CACurrentMediaTime()) { self.tickTask = nil; return }
                try? await Task.sleep(nanoseconds: gap)
            }
        }
    }

    /// One tick at `t`: true while there is more to come.
    @discardableResult
    func step(_ t: CFTimeInterval) -> Bool {
        if sealed, let f = fadeStarted, t >= f + Self.fadeS {
            landed(now: t)
            changed.send()
            return replay != nil || queued != nil
        }
        let shown = shownCount(at: t)
        var moved = shown != lastShown
        lastShown = shown
        if let r = replay, r.walls, wallsProgress(at: t) < 1 { moved = true }
        if workingSince != nil || fadeStarted != nil { moved = true }
        if moved { changed.send() }
        return replay != nil || fadeStarted != nil || workingSince != nil
    }
}

extension LatticeLayoutPreview.LayProgress {
    /// ★ notes24: how long the last lay like this one took, less the time this one has run (the replay's pacing). nil: none.
    public var expectedLeftS: Double? { expectedS.map { $0 - Date().timeIntervalSince(started) } }
}

/// What one read of the engine's tap means for the growth on screen. Pure: the tests feed it a fake reader.
struct LatticeGrowthPoller {
    /// Lays up to this one are not grown: the tap's lay when the watch began (an earlier one), then each lay that landed
    /// (its finished lattice is on screen). The tap counts its lays up.
    private(set) var floor: UInt64
    private(set) var lay: UInt64?
    /// Where the next read starts.
    private(set) var next = 0
    private(set) var phase = 0

    struct Step: Equatable {
        /// A new lay: the growth starts again.
        var restart = false
        var xyz: [Float] = []
        var region: [Int32] = []
        /// The phase moved (or a new lay's first).
        var phase: Int?
        /// A new lay seen part-way through a read: read it again from its start, now.
        var readAgain = false
    }

    init(baseline: UInt64) { floor = baseline }

    /// The lay `lay` (the tap's newest) landed: it and every earlier one are done.
    mutating func landed(_ lay: UInt64) { floor = Swift.max(floor, lay) }

    /// `r` was read from `from` (this poller's `next` when it was asked).
    mutating func take(_ r: LatticeLayoutSession.Growth, from: Int) -> Step {
        var s = Step()
        guard r.lay > floor else { return s }   // no lay yet, the one before this watch began, or one already landed
        if r.lay != lay {
            lay = r.lay; next = 0; phase = 0
            s.restart = true
            if from != 0 { s.readAgain = true; return s }
        }
        s.xyz = r.xyz
        s.region = r.region
        next = r.next
        if r.phase != phase { phase = r.phase; s.phase = r.phase }
        return s
    }
}

/// The preview's poll of the tap while an Organic lay runs: a Task on the main actor, every `every` seconds, that ends when the
/// lay ends (`stop`) or is cancelled, or when the session can no longer be read.
@MainActor
final class LatticeGrowthWatch {
    typealias Reader = (_ from: Int, _ most: Int) throws -> LatticeLayoutSession.Growth
    let growth: LatticeGrowth
    private(set) var poller: LatticeGrowthPoller
    /// Reads made (tests: none once the lay ended).
    private(set) var reads = 0
    private let read: Reader
    private let most: Int
    private let onPhase: (Int) -> Void
    private var task: Task<Void, Never>?
    var running: Bool { task != nil }

    /// The baseline (the tap's lay now) is read at once, so the lay this watch is for is the next one.
    init(growth: LatticeGrowth, every: Double, most: Int, read: @escaping Reader, onPhase: @escaping (Int) -> Void) {
        self.growth = growth; self.read = read; self.most = most; self.onPhase = onPhase
        poller = LatticeGrowthPoller(baseline: (try? read(Int.max, 1).lay) ?? 0)
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

    /// The finished lattice is on screen (or nothing is, after a refusal): the tap's newest lay is done, whatever of it a read
    /// has not reached yet.
    func landed() {
        poller.landed((try? read(Int.max, 1).lay) ?? poller.lay ?? 0)
    }

    /// One poll: what came since the last, onto the growth.
    func tick() {
        guard task != nil else { return }
        for _ in 0..<2 {   // a new lay seen part-way is read again from its start, in the same poll
            let from = poller.next
            guard let r = try? read(from, most) else { stop(); return }   // the session is closed
            reads += 1
            let s = poller.take(r, from: from)
            if s.restart { growth.restart() }
            if !s.xyz.isEmpty { growth.append(xyz: s.xyz, region: s.region) }
            if let p = s.phase { onPhase(p); growth.phaseMoved(p) }   // ★ notes24 item 3: the band from phase 2 on
            if !s.readAgain { return }
        }
    }
}
