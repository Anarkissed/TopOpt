// LatticeGrowth — ★ his 11-22 ("Can we implement this like an animation? Could the user literally *watch* the lattice grow
// from nothing? … Time isn't wasted if there's an interesting animation running of the actual lattice being grown - this
// allows for patience from the user."), the app half. The engine hands every piece of vine an Organic lay lays to the
// session's GrowthTap (core); while the lay runs, the preview reads it about every 0.15 s (`LatticeGrowthWatch`: a Task on the
// main actor, the read synchronous and never through the session's worker, which the lay occupies), appends the new pieces
// here, and the 3D view draws them (`LatticeGrowthPass`, an append-only GPU buffer): the vines rising from their seeds in the
// lattice's own purple, the newest pieces (the growing tips) brighter. When the lay lands, the finished lattice replaces the
// growth (a short fade over it, never a flash of nothing); a new lay starts the growth again; a remembered preview shows none.
// The Lattice button's line names the phase the engine is in (LatticePreviewMode.phaseWords).
import Foundation
import Combine
import QuartzCore
import simd
import TopOptKit

/// The vines an Organic lay has laid so far, append-only, as the 3D view draws them. Main thread only (the preview writes it,
/// the renderer reads it while it draws).
public final class LatticeGrowth {
    /// Two per piece: (a xyz, birth) and (b xyz, region). `birth` is the poll the piece came in, plus its place in that poll's
    /// batch (the batch's newest at the poll's own number): `clock` less it is the piece's age in polls, and the young glow.
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

    public init() {}

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
            pieces.append(SIMD4(xyz[k + 3], xyz[k + 4], xyz[k + 5], Float(region[i])))
        }
        appendedTotal += n
        changed.send()
    }

    /// A new lay (or none yet): nothing grown, and its pieces welcome.
    func restart() {
        wipe()
        sealed = false
    }

    /// The lay this grew for is done: the finished lattice `landed` (the growth fades out over it), or nothing is on screen
    /// (a refusal, an error: gone at once). Nothing more is appended until a new lay restarts it.
    func seal(landed: Bool, now: CFTimeInterval = CACurrentMediaTime()) {
        sealed = true
        guard landed, !pieces.isEmpty else { wipe(); return }
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
        let had = !pieces.isEmpty || fadeStarted != nil
        fadeStarted = nil
        pieces = []
        clock = 0
        epoch &+= 1
        if had { changed.send() }
    }

    /// How much of the growth shows at `t`: 1, and toward 0 over `fadeS` once the lattice landed.
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
            if let p = s.phase { onPhase(p) }
            if !s.readAgain { return }
        }
    }
}
