// LatticeBuildTimelapse — ★ his notes on release 20 (2026-11-25, img 97: a regular lattice half-drawn while it refreshed — loose
// vertical struts over the bare part): "We need to think of an animation to implement so we never have to deal with images like
// this. Make it like the organic lattice, but make it feel like it is being *built*. Give it a 'timelapse of a building being
// made' feel. Make it have hard stops and starts, not organic growth. Remember to include the shade inside the part and make it
// feel like we're literally looking inside. Even though the lattice is built in usually a second, let the animation run for at
// least 5 seconds. The user will wait."
//
// ★ his review of the first clips (the same evening, img 98): "None of the parts' walls open up, I can't see through the part
// to the other side and no shading exists. Try again. I think the perfect amount is about 6-8 seconds for the build, total."
//
// What the 3D view shows of a regular (strut) lay, from the moment it is asked for (the Lattice page's refresh, the Settings
// sample's build) to the finished lattice:
//   * THE SITE — the moment the lay is asked for, the last lattice is gone at once (never a lattice half one, half the other:
//     img 97 was the new struts over the LAST lay's map) and the part stands CLOSED, whole, while the engine works.
//   * THE WALLS COME OFF — once the lay has landed WITH ITS OWN MAP (the preview hands the two together now), the walls over
//     the lattice are taken off in `wallSteps` hard snaps (chunks at a time, the map's own dissolve held at each step): the part
//     stands open where its lattice goes, its inside shaded as the inside of a part (LatticeInsideShade), the far side seen
//     through it where the lattice runs through.
//   * THE FRAME RISES — floor by floor from the lowest: each floor in hard snaps — its columns (the struts standing near
//     upright), then its bays left to right — and then a beat of stillness before the next floor. No fading, no growth: each
//     snap is all at once, as a timelapse frame.
//   * TOPPED OUT — the whole lattice held still for a beat; the timelapse is over.
// `totalS` from the ask to the end when the lay is quick (his "6-8 seconds … total": the clips at 6, 7 and 8 s; HIS PICK: "Let's
// go with 7 seconds for ALL animations. It looks great!");
// a lay that takes longer is covered by the closed site, and its walls and frame still come in full (at least `buildLeastS`)
// after it lands. In X-ray (and the Settings sample, drawn see-through) there are no walls to take off: the same clock, the
// frame rising inside the see-through part.
// ★ "Skip all animations" (Settings): none of this — the lattice area stays blank while the lay runs (the page shows its
// "Refreshing Lattice" card), and the finished lattice shows at once when it lands.
//
// THE TIMINGS ARE HIS TO TUNE (after he watches the clips): every number is a named constant below.
// Pure: wall seconds in, what shows out. The bars are put on floors and bays in the bars' own shader (`bar_build_hidden`),
// mirrored here (`step`) for the tests.
import Foundation
import Combine
import QuartzCore
import simd

struct LatticeBuildTimelapse: Equatable {
    // MARK: the timings (his to tune)

    /// From the ask to the finished lattice, at least: his "about 6-8 seconds for the build, total" (the clips at 6, 7 and 8),
    /// HIS PICK "7 seconds for ALL animations" (the Lattice page and the Settings sample; Organic's `LatticeGrowthReplay.minTotalS`
    /// too). Release 21's first cut: 5 (his "at least 5 seconds").
    nonisolated(unsafe) static var totalS: Double = hisTotalS
    static let hisTotalS: Double = 7.0
    static let totalChoicesS: [Double] = [6, 7, 8]
    /// The closed site: the walls start coming off no sooner than this after the ask (a lay that lands at once still shows it).
    static let siteLeastS: Double = 0.5
    /// The walls coming off: this long, in `wallSteps` hard snaps (the last one leaves them open).
    static let wallsS: Double = 0.9
    static let wallSteps = 3
    /// The frame rising, at least (a lay that lands late still gets its whole build).
    static let buildLeastS: Double = 3.0
    /// Topped out: the whole lattice held still before the timelapse ends.
    static let toppedOutS: Double = 0.7
    /// A floor is about this tall (model mm) — between `floorsLeast` and `floorsMost` floors over the lattice's height.
    static let floorMM: Float = 10
    static let floorsLeast = 4
    static let floorsMost = 6
    /// The bays across a floor (left to right), after its columns.
    static let bays = 3
    /// A floor's snaps (its columns, then each bay) come this share of the floor's time apart; the rest of it is still.
    static let snapShare: Double = 0.18
    /// A strut this close to upright (|cos| of its angle to up) is a column.
    static let columnCos: Float = 0.85

    /// The snaps a floor makes: its columns, then each bay.
    static var perFloor: Int { 1 + bays }

    /// The floors over a lattice `heightMM` tall.
    static func floors(heightMM h: Float) -> Int {
        Swift.min(floorsMost, Swift.max(floorsLeast, Int((h / floorMM).rounded())))
    }

    // MARK: one timelapse

    /// When the lay was asked for (wall s).
    let start: Double
    /// When it landed with its map (wall s); nil while the engine works.
    private(set) var landedAt: Double?

    init(start: Double) { self.start = start }

    mutating func land(at t: Double) { if landedAt == nil { landedAt = Swift.max(t, start) } }

    /// The walls start coming off (nil: not landed).
    var wallsStart: Double? { landedAt.map { Swift.max($0, start + Self.siteLeastS) } }
    /// The frame's first snap (nil: not landed).
    var buildStart: Double? { wallsStart.map { $0 + Self.wallsS } }
    /// How long the frame rises: at least `buildLeastS`, and long enough that the whole lasts `totalS`.
    var buildS: Double? {
        buildStart.map { Swift.max(Self.buildLeastS, start + Self.totalS - Self.toppedOutS - $0) }
    }

    /// How much of the walls over the lattice still stands at `t` (1: the part closed; 0: open), in hard snaps.
    func standing(at t: Double) -> Float {
        guard let w = wallsStart, t >= w else { return 1 }
        let k = Int(((t - w) / (Self.wallsS / Double(Self.wallSteps)) + 1e-9).rounded(.down)) + 1   // the first snap at once
        return Float(Swift.max(0, Self.wallSteps - k)) / Float(Self.wallSteps)
    }
    /// The timelapse's end (the last of the topped-out beat).
    var end: Double? { buildStart.flatMap { b in buildS.map { b + $0 + Self.toppedOutS } } }

    /// When snap `k` (0-based: floor k / perFloor, its columns then its bays) shows, over `floors` floors.
    func snapAt(_ k: Int, floors: Int) -> Double? {
        guard let b = buildStart, let s = buildS, floors > 0 else { return nil }
        let floorS = s / Double(floors)
        let f = k / Self.perFloor, kind = k % Self.perFloor
        return b + Double(f) * floorS + Double(kind) * Self.snapShare * floorS
    }

    /// How many snaps show at `t` over `floors` floors: nil — nothing of the lay shows (the site is cleared, the engine still
    /// works or the frame has not started); else 0...floors × perFloor (all of them: the frame stands).
    func shown(at t: Double, floors: Int) -> Int? {
        guard let b = buildStart, let s = buildS, floors > 0 else { return nil }
        guard t >= b else { return nil }
        let all = floors * Self.perFloor
        if t >= b + s { return all }
        let floorS = s / Double(floors)
        let f = Swift.min(floors - 1, Int(((t - b) / floorS + 1e-9).rounded(.down)))
        let within = t - b - Double(f) * floorS
        let kind = Swift.min(Self.perFloor - 1, Int((within / (Self.snapShare * floorS) + 1e-9).rounded(.down)))
        return Swift.min(all, f * Self.perFloor + kind + 1)
    }

    /// The timelapse is over at `t` (landed, its frame risen and topped out).
    func done(at t: Double) -> Bool { end.map { t >= $0 } ?? false }

    // MARK: which snap a strut comes in (the bars' shader's `bar_build_hidden`, mirrored)

    /// Where the floors and bays lie, in the part's own (model) coordinates: `up` and `across` unit directions, the lattice's
    /// lowest height along `up` and a floor's height, its lowest along `across` and its width.
    struct Frame: Equatable {
        var up: SIMD3<Float>
        var across: SIMD3<Float>
        var low: Float
        var floorH: Float
        var acrossLow: Float
        var acrossW: Float
        var floors: Int

        /// Over the model-space box `lo`…`hi` of the bars, `up` and `across` the world's up and right in model coordinates.
        init(lo: SIMD3<Float>, hi: SIMD3<Float>, up u: SIMD3<Float>, across a: SIMD3<Float>) {
            up = simd_length(u) > 1e-6 ? simd_normalize(u) : SIMD3(0, 1, 0)
            across = simd_length(a) > 1e-6 ? simd_normalize(a) : SIMD3(1, 0, 0)
            var hLo = Float.greatestFiniteMagnitude, hHi = -hLo, aLo = hLo, aHi = -hLo
            for i in 0..<8 {
                let p = SIMD3<Float>(i & 1 == 0 ? lo.x : hi.x, i & 2 == 0 ? lo.y : hi.y, i & 4 == 0 ? lo.z : hi.z)
                let h = simd_dot(up, p), x = simd_dot(across, p)
                hLo = Swift.min(hLo, h); hHi = Swift.max(hHi, h); aLo = Swift.min(aLo, x); aHi = Swift.max(aHi, x)
            }
            let height = Swift.max(hHi - hLo, 1e-3)
            floors = LatticeBuildTimelapse.floors(heightMM: height)
            low = hLo
            floorH = height / Float(floors)
            acrossLow = aLo
            acrossW = Swift.max(aHi - aLo, 1e-3)
        }
    }

    /// The snap strut a–b comes in: its floor (by its lower end), then 0 for a column, 1 + its bay (by its middle) else.
    static func step(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ f: Frame) -> Int {
        let ha = simd_dot(f.up, a), hb = simd_dot(f.up, b)
        let fl = Swift.min(Float(f.floors - 1), Swift.max(0, ((Swift.min(ha, hb) - f.low) / f.floorH + 1e-3).rounded(.down)))
        let d = b - a, len = simd_length(d)
        if len < 1e-6 || abs(simd_dot(d, f.up)) / len >= columnCos { return Int(fl) * perFloor }
        let mid = simd_dot(f.across, (a + b) / 2)
        let bay = Swift.min(Float(bays - 1), Swift.max(0, ((mid - f.acrossLow) / f.acrossW * Float(bays)).rounded(.down)))
        return Int(fl) * perFloor + 1 + Int(bay)
    }
}

/// The timelapse of the lay on screen, as the 3D view draws it: the page (or the sample) says when a lay is asked for and when
/// it lands; the renderer asks it, each frame, whether the bars it holds show and how much of them. Main thread only.
public final class LatticeBuildShow {
    /// Fires on every visible change (a snap, the site cleared, the end): the 3D view redraws itself.
    public let changed = PassthroughSubject<Void, Never>()
    /// The timelapse under way (nil: none — the bars on screen show whole).
    private(set) var timelapse: LatticeBuildTimelapse?
    /// The landed lay's bars (their token): only they show while a timelapse runs; any other bars (the last lay's) never.
    private(set) var token: Int?
    /// The floors the renderer put the landed bars on (its last frame), for the ticks' redraws.
    var floorsSeen = LatticeBuildTimelapse.floorsLeast
    /// Lays asked for (tests).
    private(set) var asks = 0
    /// RED CONTROL (tests): no timelapse — the last lattice stays while the engine works and the new one shows whole the moment
    /// it lands (as before release 21: img 97's frame possible again with a late map).
    nonisolated(unsafe) public static var controlOff = false
    /// The clock (tests set it; else now).
    nonisolated(unsafe) static var clockForTesting: CFTimeInterval?
    public static var now: CFTimeInterval { clockForTesting ?? CACurrentMediaTime() }
    static let tickFPS: Double = 30
    private var tickTask: Task<Void, Never>?
    private var lastSent: Int?? = .none

    public init() {}

    /// Animations are off (Settings › Skip all animations): no timelapse, but the lattice area blank while the lay runs.
    static var skipping: Bool { AppSettings.skipAllAnimations }

    /// A lay was asked for: the last lattice goes at once and the site stands cleared until this lay lands.
    public func layBegins(now: CFTimeInterval = LatticeBuildShow.now) {
        guard !Self.controlOff else { return }
        asks += 1
        // a lay asked while the last is still being built starts again from a cleared site
        timelapse = LatticeBuildTimelapse(start: now)
        token = nil
        changed.send()
        tick()
    }

    /// The lay landed: its bars (`token`) with their map. The frame rises (none: shown whole — animations off).
    public func landed(token t: Int, now: CFTimeInterval = LatticeBuildShow.now) {
        guard var tl = timelapse, token == nil else { return }
        token = t
        if Self.skipping { stop(); return }
        tl.land(at: now)
        timelapse = tl
        changed.send()
        tick()
    }

    /// No timelapse (a lattice shown from memory, an error, the page closed): what is on screen shows as it is.
    public func stop() {
        let had = timelapse != nil
        timelapse = nil
        token = nil
        tickTask?.cancel(); tickTask = nil
        lastSent = .none
        if had { changed.send() }
    }

    /// A lay is under way on screen: asked for and not yet landed (the page's "Refreshing Lattice" card, with animations off).
    public var waiting: Bool { timelapse != nil && token == nil }

    /// What of the bars `barsToken` shows at `t`: `.all` (no timelapse), `.none` (the site cleared: not this lay's bars, or not
    /// yet), or the first `n` snaps of the frame over `floors` floors.
    enum Reveal: Equatable { case all, none, snaps(Int) }
    func reveal(barsToken: Int, floors: Int, at t: CFTimeInterval) -> Reveal {
        guard let tl = timelapse else { return .all }
        guard let tok = token, tok == barsToken else { return .none }
        if tl.done(at: t) { return .all }
        guard let n = tl.shown(at: t, floors: floors) else { return .none }
        return n >= floors * LatticeBuildTimelapse.perFloor ? .all : .snaps(n)
    }

    /// ★ his review (img 98, "None of the parts' walls open up"): how much of the walls over the lattice stand at `t` while a
    /// timelapse runs — 1, the part closed, until this lay's walls come off (the last lay's map never opens it); nil: no
    /// timelapse (the map opens the part, as always).
    func standing(barsToken: Int, at t: CFTimeInterval) -> Float? {
        guard let tl = timelapse else { return nil }
        guard let tok = token, tok == barsToken else { return 1 }
        if tl.done(at: t) { return nil }
        return tl.standing(at: t)
    }

    /// The timelapse ended at `t` (it is let go: nothing more to draw for it).
    private func settle(_ t: CFTimeInterval) -> Bool {
        guard let tl = timelapse, tl.done(at: t) else { return false }
        timelapse = nil
        token = nil
        return true
    }

    /// The view is redrawn at each snap and when the timelapse ends; nothing ticks once it is over.
    private func tick() {
        guard tickTask == nil else { return }
        let gap = UInt64(1_000_000_000 / Self.tickFPS)
        tickTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                if !self.step(Self.now) { self.tickTask = nil; return }
                try? await Task.sleep(nanoseconds: gap)
            }
        }
    }

    /// One tick at `t`: true while there is more to come.
    @discardableResult
    func step(_ t: CFTimeInterval) -> Bool {
        if settle(t) { lastSent = .none; changed.send(); return false }
        guard let tl = timelapse else { return false }
        let now: Int? = token == nil ? nil : tl.shown(at: t, floors: floorsSeen)
        let walls = token == nil ? 1 : tl.standing(at: t)   // (each of the walls' snaps redraws too)
        let key: Int? = now.map { $0 * 16 + Int(walls * 8) } ?? (token == nil ? nil : -1 - Int(walls * 8))
        if case .some(let last) = lastSent, last == key { return true }
        lastSent = .some(key)
        changed.send()
        return true
    }
}

#if canImport(MetalKit)
import MetalKit

/// What the bars' shader is told of the timelapse (BarFrame's last four rows): x of `build` < 0 — no timelapse, every bar.
struct LatticeBuildRevealUniform: Equatable {
    /// x: the snaps shown (−1: all); y: the floors; z: the bays; w: 1 on.
    var build = SIMD4<Float>(-1, 1, 1, 0)
    /// xyz: up, in the part's own coordinates; w: the lattice's lowest height along it.
    var up = SIMD4<Float>(0, 1, 0, 0)
    /// xyz: across (left to right); w: the lattice's lowest along it.
    var across = SIMD4<Float>(1, 0, 0, 0)
    /// x: a floor's height; y: the lattice's width across; z: a column's |cos| to up.
    var sizes = SIMD4<Float>(1, 1, 0.85, 0)

    init() {}
    init(snaps n: Int, frame f: LatticeBuildTimelapse.Frame) {
        build = SIMD4(Float(n), Float(f.floors), Float(LatticeBuildTimelapse.bays), 1)
        up = SIMD4(f.up, f.low)
        across = SIMD4(f.across, f.acrossLow)
        sizes = SIMD4(f.floorH, f.acrossW, LatticeBuildTimelapse.columnCos, 0)
    }
}

extension MeshRenderer {
    /// The timelapse this view draws its bars by (the Lattice page's, the sample's), or none. True when it changed.
    @discardableResult
    func applyBuildShow(_ s: LatticeBuildShow?) -> Bool {
        guard buildShow !== s else { return false }
        buildShow = s
        return true
    }

    /// ★ his review (img 98): how much of the walls over the lattice stand this frame (nil: none — the map opens the part).
    var buildStanding: Float? {
        guard let show = buildShow, let pass = layoutBars else { return nil }
        return show.standing(barsToken: pass.token, at: LatticeBuildShow.now)
    }

    /// The bars this frame: drawn or not, and how much of them (nil: all). The world's up and right in the part's own
    /// coordinates (the model matrix's rows: the part's placement turns it, the camera never does).
    func buildReveal(model: simd_float4x4) -> (draw: Bool, reveal: LatticeBuildRevealUniform?) {
        guard let show = buildShow, let pass = layoutBars, let box = pass.box else { return (true, nil) }
        let up = SIMD3(model.columns.0.y, model.columns.1.y, model.columns.2.y)
        let across = SIMD3(model.columns.0.x, model.columns.1.x, model.columns.2.x)
        let f = LatticeBuildTimelapse.Frame(lo: box.lo, hi: box.hi, up: up, across: across)
        show.floorsSeen = f.floors
        lastBuildFrame = f
        lastBuildStanding = show.standing(barsToken: pass.token, at: LatticeBuildShow.now)
        switch show.reveal(barsToken: pass.token, floors: f.floors, at: LatticeBuildShow.now) {
        case .all: return (true, nil)
        case .none: return (false, nil)
        case .snaps(let n): return (n > 0, LatticeBuildRevealUniform(snaps: n, frame: f))
        }
    }
}
#endif
