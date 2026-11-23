// LatticeGrowth — ★ his 11-22 ("Can we implement this like an animation? Could the user literally *watch* the lattice grow
// from nothing? … Time isn't wasted if there's an interesting animation running of the actual lattice being grown - this
// allows for patience from the user."), the app half. The engine hands every piece of vine an Organic lay lays to the
// session's GrowthTap (core); while the lay runs, the preview reads it about every 0.15 s (`LatticeGrowthWatch`: a Task on the
// main actor, the read synchronous and never through the session's worker, which the lay occupies), appends the new pieces
// here, and the 3D view draws them (`LatticeGrowthPass`, an append-only GPU buffer): the vines rising from their seeds in the
// lattice's own purple, the newest pieces (the growing tips) brighter. When the lay lands, the finished lattice replaces the
// growth (a short fade over it, never a flash of nothing); a new lay starts the growth again; a remembered preview shows none.
// The Lattice button's line names the phase the engine is in (LatticePreviewMode.phaseWords).
//
// ★ his notes 2026-11-23 (img 49): "It needs to be in 3D. There needs to be depth. I would prefer having the walls removed and
// seeing the actual 3d models of the lattices grow - but only the ones that are visible to me". The pieces are drawn as real
// tubes at their strut width (`radiusByRegion`: what each region's group asked — the engine's tap carries no width), lit and
// depth-tested as the landed lattice is (LatticeGrowthPass); the part is opened by the map on screen when it is this lay's
// (`mapOpensFaces`), else drawn in X-ray while the vines grow (`landedHold` keeps it so until the landed lattice's own map
// opens it). Item 3 ("the "Finishing" stayed on for the majority of the time … some sort of animation like the growing of the
// lattice would be VERY beneficial"): from the engine's phase 2 on (the vines grown, the lay pruning, filling, reaching the
// walls, finishing) the grown lattice keeps moving (`workingSince`: a band of light rises through it, looping, until it lands).
import Foundation
import Combine
import QuartzCore
import simd
import TopOptKit

/// The vines an Organic lay has laid so far, append-only, as the 3D view draws them. Main thread only (the preview writes it,
/// the renderer reads it while it draws).
public final class LatticeGrowth {
    /// Two per piece: (a xyz, birth) and (b xyz, radius). `birth` is the poll the piece came in, plus its place in that poll's
    /// batch (the batch's newest at the poll's own number): `clock` less it is the piece's age in polls, and the young glow.
    /// ★ notes24: `radius` (mm) is the tube's, from its region's group (`radiusByRegion`).
    public private(set) var pieces: [SIMD4<Float>] = []
    public var count: Int { pieces.count / 2 }
    /// A new start (cleared, or a new lay): the renderer begins its buffer again.
    public private(set) var epoch = 0
    /// The newest poll's number (the tips' clock).
    public private(set) var clock: Float = 0
    /// The finished lattice landed: the growth fades out over it for `fadeS`, then is cleared. nil: not fading.
    public private(set) var fadeStarted: CFTimeInterval?
    public static let fadeS: CFTimeInterval = 0.35
    /// Fires on every change: the 3D view redraws itself (no page pass, never the workspace's body).
    public let changed = PassthroughSubject<Void, Never>()
    /// Pieces appended since this object was made (tests: growth was shown).
    public private(set) var appendedTotal = 0
    /// The lay it grew for has landed (or stopped): nothing more is appended until a new lay `restart`s it (a read still
    /// behind the lay never brings its growth back over the finished lattice).
    public private(set) var sealed = false
    private var fadeTask: Task<Void, Never>?

    /// ★ notes24 (img 49, "the actual 3d models of the lattices"): each region's tube radius (mm) — half the strut width its
    /// group asked (a range: its middle) — and the radius of a region no group names (two print lines wide).
    public private(set) var radiusByRegion: [Int32: Float] = [:]
    public private(set) var radiusDefault: Float = 0.45
    /// ★ notes24: the solid view's map on screen when this lay began opens its faces (the Draft's for its exact lattice, the
    /// last Look's for a new Look: `LatticeLayoutPreview.mapFor`), so the vines grow inside the part opened as it will be.
    public private(set) var mapOpensFaces = false
    /// The engine's phase (core's GrowthTap: 1 growing, 2 pruning, 3 re-seeding, 4 reaching the walls, 5 finishing; 0 none).
    public private(set) var phase = 0
    /// ★ notes24 item 3: when the lay went on working on its grown vines (its phase 2 on): the clock of the band of light that
    /// rises through them until the lattice lands. nil: not yet (or none).
    public private(set) var workingSince: CFTimeInterval?
    /// ★ notes24: the lay landed after growing: the part stays in X-ray (if it was) until the landed lattice's own map opens
    /// it — never a closed part between the growth and the opened one.
    public private(set) var landedHold = false
    /// RED CONTROL (tests): no band — the grown lattice stands still while the lay finishes (as before 11-23).
    nonisolated(unsafe) public static var controlNoWorkingBand = false
    /// The band's redraws a second while it runs (the 3D view is drawn on demand).
    static let workingFPS: Double = 30
    private var workTask: Task<Void, Never>?

    public init() {}

    /// ★ notes24: an Organic lay of `groups` is about to run (the preview, just before it asks the engine): each region's tube
    /// radius, and whether the map on screen opens this lay's faces.
    public func layBegins(_ groups: [LatticeLayoutSession.OrganicGroup], lineMM: Double, mapOpens: Bool) {
        var m: [Int32: Float] = [:]
        for g in groups {
            let r = Float(Self.strutWidthMM(g.ask, lineMM: lineMM) / 2)
            for id in g.regions { m[id] = r }
        }
        radiusByRegion = m
        radiusDefault = Float(Self.strutWidthMM(nil, lineMM: lineMM) / 2)
        mapOpensFaces = mapOpens
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
        changed.send()
    }

    /// The engine's phase moved. ★ notes24 item 3: from phase 2 on (the vines grown) the lay keeps working: the band of light
    /// starts and the view is redrawn `workingFPS` times a second until the lattice lands (never a frozen picture).
    func phaseMoved(_ p: Int, now: CFTimeInterval = CACurrentMediaTime()) {
        phase = p
        guard p >= 2, !sealed, workingSince == nil, !Self.controlNoWorkingBand else { return }
        workingSince = now
        changed.send()
        let gap = UInt64(1_000_000_000 / Self.workingFPS)
        workTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: gap)
                guard let self, !Task.isCancelled, !self.sealed else { return }
                self.changed.send()
            }
        }
    }

    /// The band is running (tests).
    var working: Bool { workingSince != nil && !sealed && workTask != nil }

    /// A new lay (or none yet): nothing grown, and its pieces welcome.
    func restart() {
        wipe()
        sealed = false
        landedHold = false
        phase = 0
    }

    /// The lay this grew for is done: the finished lattice `landed` (the growth fades out over it), or nothing is on screen
    /// (a refusal, an error: gone at once). Nothing more is appended until a new lay restarts it.
    func seal(landed: Bool, now: CFTimeInterval = CACurrentMediaTime()) {
        sealed = true
        workTask?.cancel(); workTask = nil   // the band ends with the landing (it sinks with the growth)
        guard landed, !pieces.isEmpty else { wipe(); return }
        landedHold = true
        guard fadeStarted == nil else { return }
        fadeStarted = now
        changed.send()
        fadeTask = Task { @MainActor [weak self] in
            let end = Date().addingTimeInterval(Self.fadeS)
            while Date() < end {
                try? await Task.sleep(nanoseconds: 33_000_000)   // about 30 frames a second while it fades
                guard let self, !Task.isCancelled else { return }
                self.changed.send()
            }
            guard let self, !Task.isCancelled else { return }
            self.wipe()
        }
    }

    private func wipe() {
        fadeTask?.cancel(); fadeTask = nil
        workTask?.cancel(); workTask = nil
        workingSince = nil
        let had = !pieces.isEmpty || fadeStarted != nil
        fadeStarted = nil
        pieces = []
        clock = 0
        epoch &+= 1
        if had { changed.send() }
    }

    /// How much of the growth shows at `t`: 1, and toward 0 over `fadeS` once the lattice landed (★ notes24: the tubes' size,
    /// sinking into the finished lattice).
    public func alpha(at t: CFTimeInterval) -> Float {
        guard let f = fadeStarted else { return 1 }
        return Float(Swift.max(0, Swift.min(1, 1 - (t - f) / Self.fadeS)))
    }
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
