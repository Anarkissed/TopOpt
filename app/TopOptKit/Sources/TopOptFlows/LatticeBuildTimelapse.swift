// LatticeBuildTimelapse — ★ his notes on release 20 (2026-11-25, img 97: a regular lattice half-drawn while it refreshed — loose
// vertical struts over the bare part): "We need to think of an animation to implement so we never have to deal with images like
// this. Make it like the organic lattice, but make it feel like it is being *built*. Give it a 'timelapse of a building being
// made' feel. Make it have hard stops and starts, not organic growth. Remember to include the shade inside the part and make it
// feel like we're literally looking inside. Even though the lattice is built in usually a second, let the animation run for at
// least 5 seconds. The user will wait."
//
// ★ his review of the first clips (the same evening, img 98): "None of the parts' walls open up, I can't see through the part
// to the other side and no shading exists. Try again. I think the perfect amount is about 6-8 seconds for the build, total."
// HIS PICK: "Let's go with 7 seconds for ALL animations. It looks great!"
//
// ★ notes30 (his decision 2026-11-26, option D of the scoping pass, "start the full version"): "The strut engine hands over its
// struts while it works, the way Organic's engine does, so the floors rise in step with the real work." The engine lays its
// cells from the bottom up and keeps a FINISHED LINE: every strut below it is handed over the moment it is certain to be in the
// print file, exactly as it prints (LatticeStrutStream). What the 3D view shows of a regular (strut) lay, from the ask:
//   * THE SITE — the last lattice gone at once (never a lattice half one, half the other: img 97), the part closed, whole.
//   * FLOOR BY FLOOR, as the line rises: each floor in hard snaps — ITS WALLS come off (the solid view: the part opened up to
//     that floor's top by the map made behind the same line, its inside shaded), then ITS COLUMNS, then ITS BAYS left to
//     right — and a beat of stillness before the next floor. A floor never comes before the line has passed it (every strut
//     of it handed over, its map made): nothing drawn ever goes away again, and nothing loose stands over a bare part.
//   * THE PACE — the floors are spread so the last one ends `marginS` before the engine is expected to land (the line's own
//     progress, learned on this part; Organic's LatticeGrowthReplay paces its replay the same way), never ahead of the line,
//     never in less than his total (`totalS`, 7 s) from the ask.
//   * THE LANDING — the cladding (the struts the line cannot promise mid-lay: the pieces cut at the part's surface, the skin,
//     and the key's colours) goes on the floors already standing in one snap; the floors still to come follow at the pace
//     (in full, or — the floors behind a late landing — each whole in one snap: the catch-up).
//   * TOPPED OUT — the whole lattice held still for a beat; at least `totalS` from the ask.
// The frame (up, across, floors, a floor's height) is FIXED at the stream's start — from the box the engine plans its cells in
// and the up at the ask — and never moved: every strut shown before the landing shows after it.
// A lay the engine does not stream (no tap, or the solid view's map not made behind the line) lands whole and rises the same
// way from its landing: the floors at least `buildLeastS`, the walls still off floor by floor.
// In X-ray (and the Settings sample, drawn see-through) there are no walls: the same clock, the frame rising in the see-through
// part.
// ★ "Skip all animations" (Settings): none of this — the lattice area stays blank while the lay runs (the page shows its
// "Refreshing Lattice" card), and the finished lattice shows at once when it lands.
//
// THE TIMINGS ARE HIS TO TUNE (after he watches the clips): every number is a named constant below.
// Pure: wall seconds and the line in, what shows out. The bars are put on floors and bays in the bars' own shader
// (`bar_build_hidden`), mirrored here (`step`) for the tests; the walls by the map, held shut above the floors opened
// (LatticeLayoutBarsPass.openWalls).
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
    /// The closed site: the first floor comes no sooner than this after the ask (a lay that lands at once still shows it).
    static let siteLeastS: Double = 0.5
    /// A lay nothing of which stood before it landed (no stream): its floors rise at least this long after the landing.
    static let buildLeastS: Double = 3.0
    /// Topped out: the whole lattice held still before the timelapse ends.
    static let toppedOutS: Double = 0.7
    /// ★ notes30: the floors are paced to end this long before the expected landing (Organic's `LatticeGrowthReplay.marginS`).
    static let marginS: Double = 1.0
    /// ★ notes30: a floor's least time, its snaps one by one (5 snaps `snapShare` apart: each its own frame at 30 fps).
    static let floorLeastS: Double = 0.45
    /// ★ notes30: the catch-up — the floors left when a streamed lay lands late, each WHOLE in one snap, this far apart.
    static let catchUpFloorS: Double = 0.2
    /// A floor is about this tall (model mm) — between `floorsLeast` and `floorsMost` floors over the lattice's height.
    static let floorMM: Float = 10
    static let floorsLeast = 4
    static let floorsMost = 6
    /// The bays across a floor (left to right), after its columns.
    static let bays = 3
    /// A floor's snaps (its walls, its columns, then each bay) come this share of the floor's time apart; the rest of it is
    /// still.
    static let snapShare: Double = 0.18
    /// A strut this close to upright (|cos| of its angle to up) is a column.
    static let columnCos: Float = 0.85

    /// The struts' snaps a floor makes: its columns, then each bay (the bars' shader counts these).
    static var perFloor: Int { 1 + bays }

    /// The floors over a lattice `heightMM` tall.
    static func floors(heightMM h: Float) -> Int {
        Swift.min(floorsMost, Swift.max(floorsLeast, Int((h / floorMM).rounded())))
    }

    // MARK: one timelapse

    /// When the lay was asked for (wall s).
    let start: Double
    /// ★ notes30: the walls come off floor by floor (the solid view: one snap of each floor); false — X-ray, the sample: none.
    let walls: Bool
    /// ★ notes30: the frame — fixed once (the stream's plan, or the landed bars' box), never moved. nil: not yet.
    private(set) var frame: Frame?
    /// The floors when no frame is fixed yet (tests that never draw).
    var floorsUnframed = LatticeBuildTimelapse.floorsLeast
    /// ★ notes30: when each floor was ready — its struts handed over and (with walls) its map made — bottom up.
    private(set) var readyAt: [Double] = []
    /// ★ notes30: when the engine is expected to land (wall s); nil — none known (the first lay here: the 7 s pace).
    private(set) var expectedLanding: Double?
    /// When it landed (wall s); nil while the engine works.
    private(set) var landedAt: Double?
    /// The floors begun: when, how long each was given, and whether it came whole in one snap (the catch-up).
    struct FloorShown: Equatable { var at: Double; var dur: Double; var whole: Bool }
    private(set) var shownFloors: [FloorShown] = []
    /// How far the clock has been taken (`advance`).
    private(set) var clock: Double

    init(start: Double, walls: Bool = false) {
        self.start = start
        self.walls = walls
        clock = start
    }

    /// The floors this timelapse rises in.
    var floors: Int { frame?.floors ?? floorsUnframed }
    /// The snaps a floor makes on screen: its walls (the solid view), its columns, its bays.
    var snapsPerFloor: Int { (walls ? 1 : 0) + Self.perFloor }

    // MARK: what happened

    /// The frame, once: the stream's plan, or (no stream) the landed bars' box. Never moved after.
    mutating func fix(_ f: Frame) { if frame == nil { frame = f } }
    /// No frame fixed (tests that never draw): rise in `n` floors.
    mutating func unframed(floors n: Int) {
        floorsUnframed = Swift.max(1, n)
        if let l = landedAt { while readyAt.count < floors { readyAt.append(l) } }
    }
    /// RED CONTROL only (`LatticeBuildShow.controlFrameFromLanded`): the frame made again.
    mutating func refix(_ f: Frame) { frame = f; while readyAt.count < floors, let l = landedAt { readyAt.append(l) } }

    /// ★ notes30: floors 0..<n are ready at `t` (the line has passed them; with walls, their map is made). Never fewer.
    mutating func ready(floors n: Int, at t: Double) {
        advance(to: t)
        while readyAt.count < Swift.min(n, floors) { readyAt.append(Swift.max(t, start)) }
    }

    /// ★ notes30: the engine is now expected to land at `t` (nil: not known).
    mutating func expect(landingAt t: Double?) { expectedLanding = t }

    /// The lay landed at `t` (its finished lattice, its map): every floor ready.
    mutating func land(at t: Double) {
        guard landedAt == nil else { return }
        let at = Swift.max(t, start)
        advance(to: at)
        landedAt = at
        while readyAt.count < floors { readyAt.append(at) }
    }

    // MARK: the clock

    /// When the next floor begins (its first snap), from what is known; nil — it waits (not ready, or every floor shown).
    private func nextFloorStart() -> Double? {
        let f = shownFloors.count
        guard f < floors, f < readyAt.count else { return nil }
        var at = Swift.max(readyAt[f], start + Self.siteLeastS)
        if let p = shownFloors.last { at = Swift.max(at, p.at + p.dur) }
        return at
    }

    /// How long floor `shownFloors.count`, beginning at `t`, is given.
    private func plan(at t: Double) -> FloorShown {
        let left = Double(Swift.max(1, floors - shownFloors.count))
        let least = start + Self.totalS - Self.toppedOutS   // the frame topped out by his total
        if let l = landedAt, l <= t {
            let stoodBefore = shownFloors.contains { $0.at < l }
            if !stoodBefore {   // nothing stood when it landed (no stream): the whole build, at least `buildLeastS` from its first floor
                let target = Swift.max(least, Swift.max(l, start + Self.siteLeastS) + Self.buildLeastS)
                return FloorShown(at: t, dur: Swift.max(Self.catchUpFloorS, (target - t) / left), whole: false)
            }
            let room = least - t
            if room >= left * Self.floorLeastS { return FloorShown(at: t, dur: room / left, whole: false) }
            return FloorShown(at: t, dur: Self.catchUpFloorS, whole: true)   // the catch-up: each floor whole in one snap
        }
        var target = least
        if let e = expectedLanding { target = Swift.max(target, e - Self.marginS) }
        return FloorShown(at: t, dur: Swift.max(Self.floorLeastS, (target - t) / left), whole: false)
    }

    /// Takes every floor due by `t` (its start decided by what was known up to then). Call before asking what shows.
    mutating func advance(to t: Double) {
        var guardSteps = 0
        while let at = nextFloorStart(), at <= t, guardSteps < 64 {
            shownFloors.append(plan(at: at))
            guardSteps += 1
        }
        clock = Swift.max(clock, t)
    }

    /// What shows at `t` (after `advance(to: t)`): the floors whose walls are off, and the struts' snaps (the bars' shader's
    /// count: floor × perFloor + its kinds shown). nil: nothing yet — the site.
    func shown(at t: Double) -> (opened: Int, snaps: Int)? {
        var opened = 0, snaps = 0, any = false
        for (f, s) in shownFloors.enumerated() where s.at <= t + 1e-9 {
            any = true
            if s.whole { opened = f + 1; snaps = (f + 1) * Self.perFloor; continue }
            let k = Swift.min(snapsPerFloor, Int(((t - s.at) / (Self.snapShare * s.dur) + 1e-9).rounded(.down)) + 1)
            if walls { opened = f + 1 }
            snaps = f * Self.perFloor + Swift.max(0, k - (walls ? 1 : 0))
        }
        return any ? (opened, snaps) : nil
    }

    /// Every snap's time, in order (tests: never two in one frame, hard stops).
    var snapTimes: [Double] {
        var out: [Double] = []
        for s in shownFloors {
            if s.whole { out.append(s.at); continue }
            for k in 0..<snapsPerFloor { out.append(s.at + Double(k) * Self.snapShare * s.dur) }
        }
        return out
    }

    /// The timelapse's end (the topped-out beat's last), once the lay has landed (every floor ready then: the floors still to
    /// come are taken ahead on a copy). nil: not landed yet.
    var end: Double? {
        guard let l = landedAt else { return nil }
        var all = self
        if all.shownFloors.count < all.floors { all.advance(to: .greatestFiniteMagnitude) }
        guard all.shownFloors.count >= all.floors, let last = all.shownFloors.last else { return nil }
        return Swift.max(start + Self.totalS, Swift.max(last.at + last.dur, l) + Self.toppedOutS)
    }

    /// The timelapse is over at `t` (landed, its frame risen and topped out).
    func done(at t: Double) -> Bool { end.map { t >= $0 } ?? false }

    /// The floors shown before the landing (the stream's), at the landing.
    var floorsBeforeLanding: Int { landedAt.map { l in shownFloors.filter { $0.at < l }.count } ?? shownFloors.count }

    // MARK: the axes

    /// ★ notes29 H3: the floors' up and the bays' across, in the part's own coordinates: the world's up and right (the model
    /// matrix's rows), or — the lattice laid standing on the face he kept (`printUp`) — the print's up, the bays across it
    /// from the world's right (its part square to that up). RED CONTROL (tests) `controlWorldUp`: the world's up always.
    static func axes(model: simd_float4x4, printUp: SIMD3<Float>?) -> (up: SIMD3<Float>, across: SIMD3<Float>) {
        let worldUp = SIMD3(model.columns.0.y, model.columns.1.y, model.columns.2.y)
        let right = SIMD3(model.columns.0.x, model.columns.1.x, model.columns.2.x)
        guard !controlWorldUp, let p = printUp, simd_length(p) > 1e-6, simd_length(p).isFinite else { return (worldUp, right) }
        let up = simd_normalize(p)
        return (up, across(right: right, depth: SIMD3(model.columns.0.z, model.columns.1.z, model.columns.2.z), up: up))
    }
    nonisolated(unsafe) static var controlWorldUp = false

    /// The world's right made square to `up` (its depth when the right runs along up).
    static func across(right: SIMD3<Float>, depth: SIMD3<Float>, up: SIMD3<Float>) -> SIMD3<Float> {
        var a = right - simd_dot(right, up) * up
        if simd_length(a) < 1e-4 { a = depth - simd_dot(depth, up) * up }
        return simd_length(a) > 1e-6 ? simd_normalize(a) : right
    }

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

        /// Over the model-space box `lo`…`hi` (the engine's plan, or the landed bars'), `up` and `across` in model coordinates.
        init(lo: SIMD3<Float>, hi: SIMD3<Float>, up u: SIMD3<Float>, across a: SIMD3<Float>) {
            up = simd_length(u) > 1e-6 ? simd_normalize(u) : SIMD3(0, 1, 0)
            var ac = simd_length(a) > 1e-6 ? simd_normalize(a) : SIMD3(1, 0, 0)
            ac -= simd_dot(ac, up) * up   // (square to up: the bays run across the floors)
            across = simd_length(ac) > 1e-4 ? simd_normalize(ac) : LatticeBuildTimelapse.anySquare(to: up)
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

        /// The floor a height along up lies on (the shader's clamp: below the lowest is the first, above the top the last).
        func floor(ofHeight h: Float) -> Int {
            Int(Swift.min(Float(floors - 1), Swift.max(0, ((h - low) / floorH + 1e-3).rounded(.down))))
        }
        /// Floor `f`'s top, along up.
        func top(_ f: Int) -> Float { low + Float(f + 1) * floorH }
    }

    /// Any unit direction square to `u`.
    static func anySquare(to u: SIMD3<Float>) -> SIMD3<Float> {
        let h: SIMD3<Float> = abs(u.x) < 0.9 ? SIMD3(1, 0, 0) : SIMD3(0, 1, 0)
        return simd_normalize(h - simd_dot(h, u) * u)
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

/// The timelapse of the lay on screen, as the 3D view draws it: the page (or the sample) says when a lay is asked for, what the
/// engine hands over while it lays (`stream`) and when it lands; the renderer asks it, each frame, whether the bars it holds
/// show, how much of them, and how many floors' walls are off. Main thread only.
public final class LatticeBuildShow {
    /// Fires on every visible change (a snap, the site cleared, the end): the 3D view redraws itself.
    public let changed = PassthroughSubject<Void, Never>()
    /// The timelapse under way (nil: none — the bars on screen show whole).
    private(set) var timelapse: LatticeBuildTimelapse?
    /// The landed lay's bars (their token): only they show while a timelapse runs; any other bars (the last lay's) never.
    private(set) var token: Int?
    /// ★ notes30: the struts the engine hands over while this lay lays (empty: none — the lay lands whole).
    public let stream = LatticeStrutStream()
    /// ★ notes30: the view's up and right in the part's own coordinates (the renderer's last frame; +Z and +X before one): the
    /// floors rise along the up the engine is asked to stream along, the bays run along the right.
    var viewAxes: (up: SIMD3<Float>, across: SIMD3<Float>) = (SIMD3(0, 0, 1), SIMD3(1, 0, 0))
    /// Lays asked for (tests).
    private(set) var asks = 0
    /// RED CONTROL (tests): no timelapse — the last lattice stays while the engine works and the new one shows whole the moment
    /// it lands (as before release 21: img 97's frame possible again with a late map).
    nonisolated(unsafe) public static var controlOff = false
    /// RED CONTROL (tests, S1): the floors come at the pace alone, whether or not the line has passed them.
    nonisolated(unsafe) static var controlIgnoreLine = false
    /// RED CONTROL (tests, S2): the frame made again from the landed bars' box at the landing (release 21's frame).
    nonisolated(unsafe) static var controlFrameFromLanded = false
    /// The clock (tests set it; else now).
    nonisolated(unsafe) static var clockForTesting: CFTimeInterval?
    public static var now: CFTimeInterval { clockForTesting ?? CACurrentMediaTime() }
    static let tickFPS: Double = 30
    private var tickTask: Task<Void, Never>?
    private var lastSent: [Int]?

    public init() {
        stream.holdBack = { [weak self] a, b in self?.standsAlready(a, b) ?? false }
    }

    /// ★ notes30: strut a–b belongs to a snap already shown (it would pop in on a floor at rest: held for the cladding).
    private func standsAlready(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> Bool {
        guard let tl = timelapse, let f = tl.frame, let s = tl.shown(at: Self.now) else { return false }
        return LatticeBuildTimelapse.step(a, b, f) < s.snaps
    }

    /// Animations are off (Settings › Skip all animations): no timelapse, but the lattice area blank while the lay runs.
    static var skipping: Bool { AppSettings.skipAllAnimations }

    /// A lay was asked for: the last lattice goes at once and the site stands cleared until this lay's first floor.
    /// `walls`: the solid view (each floor's walls come off; its map is needed). The stream starts empty.
    public func layBegins(walls: Bool = false, now: CFTimeInterval = LatticeBuildShow.now) {
        guard !Self.controlOff else { return }
        asks += 1
        // a lay asked while the last is still being built starts again from a cleared site
        timelapse = LatticeBuildTimelapse(start: now, walls: walls && !Self.skipping)
        token = nil
        stream.reset()
        changed.send()
        tick()
    }

    /// ★ notes30: what the engine handed over moved (its plan, the line, the map): the frame is fixed from the plan the first
    /// time, and the floors the line has passed are ready. The stream's struts are drawn by the renderer as they come.
    func streamMoved(now: CFTimeInterval = LatticeBuildShow.now) {
        guard var tl = timelapse, token == nil, !Self.skipping else { return }
        if tl.frame == nil, let p = stream.plan {
            tl.fix(.init(lo: p.lo, hi: p.hi, up: p.up, across: viewAxes.across))
        }
        if let f = tl.frame { tl.ready(floors: Self.readyFloors(stream, frame: f, walls: tl.walls), at: now) }
        timelapse = tl
        tick()
    }

    /// ★ notes30: the floors of `f` the stream has passed — every strut of each handed over (the line past its top by a strut's
    /// reach) and, with walls, its map made behind the line (by the map's margin) — counted from the bottom.
    static func readyFloors(_ s: LatticeStrutStream, frame f: LatticeBuildTimelapse.Frame, walls: Bool) -> Int {
        if controlIgnoreLine { return f.floors }   // RED CONTROL: the pace alone
        var n = 0
        while n < f.floors {
            let top = f.top(n)
            let struts = s.allHanded || s.line >= top + s.reach
            let map = !walls || s.mapAllMade || (s.hasMap && s.mapReadyLine >= top + s.mapMargin)
            guard struts, map else { break }
            n += 1
        }
        return n
    }

    /// ★ notes30: the engine is expected to land at `t` (the line's own progress; nil: not known).
    func expect(landingAt t: CFTimeInterval?) {
        guard var tl = timelapse, token == nil else { return }
        tl.expect(landingAt: t)
        timelapse = tl
    }

    /// The lay landed: its bars (`token`) with their map, in the box `box` (the frame, when the stream fixed none; its floors
    /// along `printUp`, the face he kept, else the view's up). The cladding goes on and the floors still to come follow (none:
    /// shown whole — animations off).
    public func landed(token t: Int, box: (lo: SIMD3<Float>, hi: SIMD3<Float>)? = nil, printUp: SIMD3<Float>? = nil,
                       now: CFTimeInterval = LatticeBuildShow.now) {
        guard var tl = timelapse, token == nil else { return }
        token = t
        stream.seal()
        if Self.skipping { stop(); return }
        let up = printUp.flatMap { simd_length($0) > 1e-6 ? simd_normalize($0) : nil } ?? viewAxes.up
        if let b = box, tl.frame == nil || Self.controlFrameFromLanded {
            tl.refix(.init(lo: b.lo, hi: b.hi, up: up, across: viewAxes.across))
        }
        tl.land(at: now)
        timelapse = tl
        changed.send()
        tick()
    }

    /// The renderer's landed bars (`token`) with no frame fixed yet: the frame from their box, now (never moved after).
    func fixFrame(lo: SIMD3<Float>, hi: SIMD3<Float>, up: SIMD3<Float>, across: SIMD3<Float>, token t: Int) {
        guard var tl = timelapse, tl.frame == nil, token == t else { return }
        tl.fix(.init(lo: lo, hi: hi, up: up, across: across))
        if let l = tl.landedAt { tl.ready(floors: tl.floors, at: l) }
        timelapse = tl
    }

    /// No timelapse (a lattice shown from memory, an error, the page closed): what is on screen shows as it is.
    public func stop() {
        let had = timelapse != nil
        timelapse = nil
        token = nil
        stream.seal()
        tickTask?.cancel(); tickTask = nil
        lastSent = nil
        if had { changed.send() }
    }

    /// A lay is under way on screen: asked for and not yet landed (the page's "Refreshing Lattice" card, with animations off).
    public var waiting: Bool { timelapse != nil && token == nil }

    /// ★ notes30: the frame the floors rise in (nil: not fixed yet).
    var frame: LatticeBuildTimelapse.Frame? { timelapse?.frame }

    /// The timelapse taken to `t` (every floor due by then begun).
    private func advanced(_ t: CFTimeInterval) -> LatticeBuildTimelapse? {
        guard var tl = timelapse else { return nil }
        tl.advance(to: t)
        timelapse = tl
        return tl
    }

    /// What of the bars `barsToken` shows at `t`: `.all` (no timelapse), `.none` (the site cleared: not this lay's bars, or not
    /// yet), or the first `n` struts' snaps of the frame. `floors`: the floors to rise in when no frame was fixed (tests).
    enum Reveal: Equatable { case all, none, snaps(Int) }
    func reveal(barsToken: Int, floors: Int, at t: CFTimeInterval) -> Reveal {
        guard timelapse != nil else { return .all }
        guard let tok = token, tok == barsToken else { return .none }
        if timelapse?.frame == nil, timelapse?.floorsUnframed != floors { timelapse?.unframed(floors: floors) }
        guard let tl = advanced(t) else { return .all }
        return Self.reveal(tl, at: t)
    }
    /// ★ notes30: what of the stream's struts shows at `t` (before the landed bars are on screen).
    func revealStream(at t: CFTimeInterval) -> Reveal {
        guard timelapse != nil else { return .none }
        guard let tl = advanced(t) else { return .none }
        return Self.reveal(tl, at: t)
    }
    private static func reveal(_ tl: LatticeBuildTimelapse, at t: CFTimeInterval) -> Reveal {
        if tl.done(at: t) { return .all }
        guard let s = tl.shown(at: t) else { return .none }
        return s.snaps >= tl.floors * LatticeBuildTimelapse.perFloor && tl.landedAt != nil ? .all : .snaps(s.snaps)
    }

    /// ★ notes30: the floors whose walls are off at `t` for the bars `barsToken` (nil = the stream): nil — no timelapse (the
    /// map opens the part, as always); 0 — none yet (the part closed).
    func wallsOpen(barsToken: Int?, at t: CFTimeInterval) -> Int? {
        guard let tl0 = timelapse, tl0.walls else { return nil }
        if let b = barsToken, b != token { return nil }   // (another lay's bars: `standing` keeps the part closed over them)
        guard let tl = advanced(t) else { return nil }
        if tl.done(at: t) { return nil }
        return tl.shown(at: t)?.opened ?? 0
    }

    /// ★ his review (img 98, "None of the parts' walls open up"): the part closed over bars that are not this lay's while a
    /// timelapse runs (1: the last lay's map never opens it); nil — the map opens it (this lay's: floor by floor, `wallsOpen`).
    func standing(barsToken: Int?, at t: CFTimeInterval) -> Float? {
        guard timelapse != nil else { return nil }
        if let b = barsToken, b != token { return 1 }
        return nil
    }

    /// ★ notes30: the stream is what the renderer draws now — a timelapse that has struts handed over, before its landed bars
    /// (`landedToken`, the renderer's) are on screen.
    func drawsStream(landedToken: Int?) -> Bool {
        guard timelapse != nil, stream.plan != nil, !Self.skipping else { return false }
        guard let t = token else { return true }
        return landedToken != t
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
        if settle(t) { lastSent = nil; changed.send(); return false }
        guard let tl = advanced(t) else { return false }
        let s = tl.shown(at: t)
        let key = [token ?? -1, s?.opened ?? -1, s?.snaps ?? -1, tl.landedAt.map { t >= $0 ? 1 : 0 } ?? 0]
        if lastSent == key { return true }
        lastSent = key
        changed.send()
        return true
    }
}

#if canImport(MetalKit)
import MetalKit

/// What the bars' shader is told of the timelapse (BarFrame's four rows after the map): x of `build` < 0 — no timelapse, every bar.
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
        streamBars = nil   // (another show's stream is not this one's)
        return true
    }

    /// ★ notes30: the bars pass this frame draws — the stream's (the struts the engine handed over) while the lay streams and
    /// its landed bars are not on screen yet, else the landed lay's.
    var drawnLayoutBars: LatticeLayoutBarsPass? {
        if let show = buildShow, show.drawsStream(landedToken: layoutBars?.token) { return streamBars }
        return layoutBars
    }

    /// ★ notes30: once a frame, before anything reads the bars — the stream's struts and map onto the GPU (appended: never the
    /// whole set again), and each pass's walls held shut above the floors opened so far.
    func prepareBuild(_ device: MTLDevice, model: simd_float4x4) {
        guard let show = buildShow else { return }
        let now = LatticeBuildShow.now
        // the view's up and right in the part's own coordinates (the print's up when laid standing on the face he kept): where
        // the next lay's line rises and its floors stand
        let drawnUp = drawnLayoutBars.map { $0 === streamBars ? show.stream.printUp : $0.printUp } ?? show.stream.printUp
        show.viewAxes = LatticeBuildTimelapse.axes(model: model, printUp: drawnUp)
        // the landed bars with no frame fixed yet (no stream, no box given): the frame from their box now, before any mask
        if let p = layoutBars, let box = p.box {
            let (up, across) = LatticeBuildTimelapse.axes(model: model, printUp: p.printUp)
            show.fixFrame(lo: box.lo, hi: box.hi, up: up, across: across, token: p.token)
        }
        if show.drawsStream(landedToken: layoutBars?.token) {
            if streamBars == nil, LatticeLayoutBarsPass.lastInitError == nil {
                do { streamBars = try LatticeLayoutBarsPass(device: device) } catch {
                    LatticeLayoutBarsPass.lastInitError = "\(error)"
                    NSLog("DIAG stream bars: %@", "\(error)")
                }
            }
            if let p = streamBars {
                p.syncStream(show.stream)
                p.openWalls(show.wallsOpen(barsToken: nil, at: now), frame: show.frame)
            }
        }
        if let p = layoutBars {
            p.openWalls(show.wallsOpen(barsToken: p.token, at: now), frame: show.frame)
        }
    }

    /// ★ his review (img 98): the part closed over the last lay's bars while a timelapse runs (nil: the map opens it — this
    /// lay's floor by floor).
    var buildStanding: Float? {
        guard let show = buildShow, let pass = drawnLayoutBars else { return nil }
        return show.standing(barsToken: pass === streamBars ? nil : pass.token, at: LatticeBuildShow.now)
    }

    /// The bars this frame: drawn or not, and how much of them (nil: all). The world's up and right in the part's own
    /// coordinates (the model matrix's rows: the part's placement turns it, the camera never does) — ★ notes29 H3: or, for a
    /// lattice laid standing on the face he kept, the print's up (the floors rise as the file prints, layer by layer).
    /// ★ notes30: the frame is the timelapse's own, fixed once (the stream's plan, or the landed bars' box) — never moved.
    func buildReveal(model: simd_float4x4) -> (draw: Bool, reveal: LatticeBuildRevealUniform?) {
        guard let show = buildShow, let pass = drawnLayoutBars else { return (true, nil) }
        let streaming = pass === streamBars
        let (up, across) = LatticeBuildTimelapse.axes(model: model, printUp: streaming ? show.stream.printUp : pass.printUp)
        show.viewAxes = (up, across)
        if !streaming, let box = pass.box { show.fixFrame(lo: box.lo, hi: box.hi, up: up, across: across, token: pass.token) }
        let f = show.frame
        lastBuildFrame = f
        lastBuildStanding = show.standing(barsToken: streaming ? nil : pass.token, at: LatticeBuildShow.now)
        let r = streaming ? show.revealStream(at: LatticeBuildShow.now)
                          : show.reveal(barsToken: pass.token, floors: f?.floors ?? LatticeBuildTimelapse.floorsLeast,
                                        at: LatticeBuildShow.now)
        switch r {
        case .all: return (true, nil)
        case .none: return (false, nil)
        case .snaps(let n):
            guard let f = show.frame else { return (false, nil) }
            return (n > 0, LatticeBuildRevealUniform(snaps: n, frame: f))
        }
    }
}
#endif
