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
// ★ notes30, his word on the strut stream's clips (11-26): stand-solid-7s "looks GREAT! That's exactly what I wanted!" — and
// "It would be best if on fast parts, it runs as it is now - and on slow parts it runs with the scaffolding": "open up the walls
// first, then start with the vertical struts and horizontal struts - like having scaffolding put in place ... we can remove the
// scaffolding afterwards"; "I don't think scaffolds ever differ in heights"; "little stair/diagonal sections to really hammer in
// the 'Scaffold' effect"; the rough cut-open edge "can shift slightly ... I think that's ok"; "I would much rather two different
// animations" (Organic keeps its own growth).
//
// What the 3D view shows of a regular (strut) lay, from the moment it is asked for (the Lattice page's refresh, the Settings
// sample's build) to the finished lattice. THE SITE first, either way: the last lattice gone at once (never a lattice half one,
// half the other: img 97), the part closed, whole. Then one of two:
//
// THE FAST PATH (a quick lay; the Settings sample always) — stand-solid-7s, his "exactly what I wanted":
//   * once the lay has landed with its own map, FLOOR BY FLOOR from the lowest, each floor in hard snaps: ITS WALLS come off (the
//     solid view: the part opened up to that floor's top by the map, held shut above it, its inside shaded), then ITS COLUMNS,
//     then ITS BAYS left to right, then a beat of stillness before the next floor. No fading, no growth.
//   * TOPPED OUT: the whole lattice held still for a beat; at least `totalS` (7 s) from the ask.
//
// THE SCAFFOLD (a slow lay: one expected to take longer than `scaffoldAfterS` from the ask, or one still working that long after
// it — the switch):
//   * THE WALLS FIRST: the moment the rough cut-open of the lattice's area is made (before the lay: the domain's "where", every
//     lattice region open, its cells not yet known — LatticeLayoutSession.gridRough), the walls over it come off floor by floor
//     in hard snaps (the solid view), its inside shaded.
//   * THE SCAFFOLD RISES: ONE EVEN GRID of thin, pale uprights and ledgers through the whole opened area, every lift one
//     height (a lift is a floor), its floors closed, with diagonal braces and a zig-zag stair tower (LatticeBuildScaffold) —
//     lift by lift from the lowest: ★ his order (11-26 22:40) "floors and walls, then stairs for the entire level" — its FLOOR,
//     then its WALLS, then its STAIRS (the top lift's roof last) — ★ (23:50) "It should be a piece at a time": one piece a hard
//     snap (a few neighbouring ones only when a lift's time cannot hold them one by one), never stretched (the rest of a lift's
//     time is stillness before the next level) — paced to top out `marginS` before the lay is expected to land.
//   * THE LANDING: the exact map replaces the rough one (its edge may shift slightly), then the real struts replace the scaffold
//     FLOOR BY FLOOR: each floor's columns, its bays, then that floor's lift of scaffold is struck — the scaffold comes down as
//     the real floors go in, nothing of it left once the last floor stands. ★ (23:50) "Can we slow it down a little bit and give
//     it that time-lapse feel too?" — the real build has its own `replaceS` (5 s) after the landing: a floor's columns in
//     sweeping snaps left to right, then its bays the same, then its lift struck piece by piece.
//   * TOPPED OUT, as above; at least `totalS` from the ask.
// The frame (up, across, floors, a floor's height) is FIXED once — the rough area's box (the scaffold), or the landed lattice's
// (the fast path) — and never moved: every strut shown stays shown, the scaffold's lifts and the real floors are the same floors.
// In X-ray (and the Settings sample, drawn see-through) there are no walls to take off: the same clock in the see-through part.
// ★ "Skip all animations" (Settings): none of this — the lattice area stays blank while the lay runs (the page shows its
// "Refreshing Lattice" card), and the finished lattice shows at once when it lands. ★ Live preview: no timelapse at all
// (LatticeLayoutPreview.quietLay). ★ Organic: its own growth (LatticeGrowthReplay), never this.
//
// THE TIMINGS ARE HIS TO TUNE (after he watches the clips): every number is a named constant below (the scaffold's look:
// LatticeBuildScaffold). Pure: wall seconds in, what shows out. The bars are put on floors and bays in the bars' own shader
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
    /// The closed site: the first floor (or the scaffold's first wall) comes no sooner than this after the ask.
    static let siteLeastS: Double = 0.5
    /// The fast path: the floors rise at least this long after the landing.
    static let buildLeastS: Double = 3.0
    /// Topped out: the whole lattice held still before the timelapse ends.
    static let toppedOutS: Double = 0.7
    /// A floor's least time, its snaps one by one (each its own frame at 30 fps).
    static let floorLeastS: Double = 0.45
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

    // MARK: ★ notes30 — the scaffold's timings (his to tune)

    /// ★ his "fast parts ... as it is now ... slow parts with the scaffolding": a lay expected to take longer than this from the
    /// ask to its landing gets the scaffold; a lay still working this long after the ask switches to it.
    static let scaffoldAfterS: Double = 1.0
    /// ★ his "open up the walls first": the rough cut-open's walls come off floor by floor in this long, before the scaffold.
    static let scaffoldWallsS: Double = 0.9
    /// A lift's least time (its uprights, then its 3 bays of ledgers and braces).
    static let liftLeastS: Double = 0.45
    /// A lift's time when the landing cannot be foreseen (a first lay that switched, or a lay running past its expected time).
    static let liftUnknownS: Double = 1.2
    /// The scaffold tops out this long before the lay is expected to land (Organic's `LatticeGrowthReplay.marginS`).
    static let marginS: Double = 1.0
    /// ★ his notes on v2 (11-26 23:50): "the actual building of the lattice is nearly instant. Can we slow it down a little bit
    /// and give it that time-lapse feel too?" — after the landing the real floors replace the scaffold in this long, their own
    /// time (each floor at least `floorLeastS`). v1: 2.4 s.
    static let replaceS: Double = 5.0
    static let replaceV1S: Double = 2.4
    /// A beat between the landing (or the scaffold topped out, whichever is later) and the first real floor.
    static let replaceBeatS: Double = 0.3
    /// ★ (23:50) "It should be a piece at a time": a real floor on the scaffold's path comes in sweeping snaps — its columns in
    /// `sweeps` slices left to right, then its bays in `sweeps` — then its lift of scaffold is struck piece by piece.
    static let sweeps = 6
    /// ★ (23:50) the scaffold a piece at a time: each snap one piece — a few neighbouring ones, `piecesMostPerSnap` at most, only
    /// when a lift's time cannot hold them one by one — at most `pieceS` apart, never closer than a frame (`pieceLeastS`); a
    /// lift's pieces within `activeShare` of its time, the rest stillness before the next level. Struck the same way, at most
    /// `strikeSnapsWanted` snaps a lift.
    static let pieceS: Double = 0.06
    static let pieceLeastS: Double = 1.0 / 30
    static let piecesMostPerSnap = 8
    static let activeShare: Double = 0.85
    static let strikeSnapsWanted = 12
    /// A lift the landing hurried: its last pieces a beat apart, then this much stillness.
    static let liftBeatS: Double = 0.15
    /// RED CONTROLS (tests): a lift's pieces all in one snap (v2's floor that "just comes into existence"); the real build in
    /// v1's `replaceV1S`.
    nonisolated(unsafe) static var controlWholeLift = false
    nonisolated(unsafe) static var controlQuickReal = false

    /// The struts' snaps a floor makes: its columns, then each bay (the bars' shader counts these).
    static var perFloor: Int { 1 + bays }
    /// ★ (23:50) a real floor's snaps on the scaffold's path: its columns in `sweeps`, its bays in `sweeps`.
    static var perFloorReal: Int { 2 * sweeps }

    /// The floors over a lattice `heightMM` tall.
    static func floors(heightMM h: Float) -> Int {
        Swift.min(floorsMost, Swift.max(floorsLeast, Int((h / floorMM).rounded())))
    }

    // MARK: ★ notes30 — fast or slow, decided at the ask

    /// Whether a lay gets the scaffold, and when it is expected to land (s after the ask; nil: not known).
    struct Plan: Equatable {
        var scaffold: Bool
        var expectedS: Double?
    }
    /// ★ his "on fast parts, it runs as it is now - and on slow parts it runs with the scaffolding": from the part's last lay
    /// time (`lastLayS`, the page's layWallS for this part and type), or for a first lay the estimate from its size and cells
    /// (`estimateS`), plus the map the solid view waits for (`mapS`).
    static func plan(lastLayS: Double?, mapS: Double?, estimateS: Double?) -> Plan {
        guard let lay = lastLayS ?? estimateS, lay.isFinite else { return Plan(scaffold: false, expectedS: nil) }
        let e = lay + Swift.max(0, mapS ?? 0)
        return Plan(scaffold: e > scaffoldAfterS, expectedS: e)
    }
    /// A first lay's time, foreseen from the part's size and its cells: `estimateBaseS` and `estimatePerCellS` for each cell of
    /// the part's box (the cell between the smallest and the largest the lay may use). Rough by design — a lay still working
    /// `scaffoldAfterS` after the ask switches to the scaffold whatever this said.
    static let estimateBaseS: Double = 0.3
    static let estimatePerCellS: Double = 0.0005
    static func estimateS(box: (lo: SIMD3<Float>, hi: SIMD3<Float>)?, cellLoMM: Double, cellHiMM: Double) -> Double? {
        guard let b = box else { return nil }
        let lo = cellLoMM > 0 ? cellLoMM : cellHiMM, hi = Swift.max(cellHiMM, lo)
        guard lo > 0, lo.isFinite, hi.isFinite else { return nil }
        let cell = (lo * hi).squareRoot()
        let e = simd_max(b.hi - b.lo, SIMD3(repeating: 0))
        let volume = Double(e.x) * Double(e.y) * Double(e.z)
        return estimateBaseS + volume / (cell * cell * cell) * estimatePerCellS
    }

    // MARK: one timelapse

    /// When the lay was asked for (wall s).
    let start: Double
    /// The walls come off floor by floor (the solid view); false — X-ray, the sample: none.
    let walls: Bool
    /// ★ notes30: the switch is armed — a lay still working `scaffoldAfterS` after the ask gets the scaffold (the Lattice page's
    /// strut lays; never the Settings sample, Organic, Live preview or Skip all animations).
    let mayScaffold: Bool
    /// ★ notes30: when the scaffold's path began (the ask, or the switch); nil — the fast path.
    private(set) var scaffoldFrom: Double?
    /// ★ notes30: when the rough cut-open (and the scaffold on it) arrived; nil — not yet, or none could be made.
    private(set) var roughAt: Double?
    /// When the engine is expected to land (wall s); nil — not known.
    private(set) var expectedLanding: Double?
    /// When it landed (wall s); nil while the engine works.
    private(set) var landedAt: Double?
    /// The frame — fixed once (the rough area's box, or the landed bars'), never moved. nil: not yet.
    private(set) var frame: Frame?
    /// The floors when no frame is fixed yet (tests that never draw).
    var floorsUnframed = LatticeBuildTimelapse.floorsLeast
    /// ★ notes30: the scaffold's lifts begun, bottom up: each one's snaps (a piece — or a few — each), how many pieces a snap
    /// brings, its pieces, and its end.
    struct Lift: Equatable { var snaps: [Double]; var perSnap: Int; var pieces: Int; var end: Double }
    private(set) var lifts: [Lift] = []
    /// ★ (23:50) the scaffold's pieces a lift (LatticeBuildScaffold.Layout.liftPieces: its floor, walls, stairs; the top lift's
    /// roof), in the order they come; none given (tests that never draw): `perFloor` a lift.
    private(set) var liftPieces: [Int] = []
    func pieces(_ k: Int) -> Int { k < liftPieces.count ? liftPieces[k] : Self.perFloor }
    func piecesBefore(_ k: Int) -> Int { (0..<Swift.max(0, k)).reduce(0) { $0 + pieces($1) } }
    /// Every piece of the scaffold.
    var piecesAll: Int { piecesBefore(floors) }
    /// The real floors' snaps a floor (the fast path's `perFloor`; the scaffold's path `perFloorReal`).
    var realPerFloor: Int { scaffolding ? Self.perFloorReal : Self.perFloor }

    init(start: Double, walls: Bool = false, scaffold: Bool = false, mayScaffold: Bool = false, expectedLanding: Double? = nil) {
        self.start = start
        self.walls = walls
        self.mayScaffold = mayScaffold || scaffold
        scaffoldFrom = scaffold ? start : nil
        self.expectedLanding = expectedLanding
    }

    /// The floors this timelapse rises in.
    var floors: Int { frame?.floors ?? floorsUnframed }
    /// ★ notes30: the scaffold's path (else the fast one).
    var scaffolding: Bool { scaffoldFrom != nil }
    /// The fast path's snaps a floor makes on screen: its walls (the solid view), its columns, its bays.
    var snapsPerFloor: Int { (walls ? 1 : 0) + Self.perFloor }

    // MARK: what happened

    /// The frame, once: the rough area's box, or the landed bars'. Never moved after.
    mutating func fix(_ f: Frame) { if frame == nil { frame = f } }
    /// No frame fixed (tests that never draw): rise in `n` floors (before any lift).
    mutating func unframed(floors n: Int) { if lifts.isEmpty { floorsUnframed = Swift.max(1, n) } }
    /// ★ notes30: the rough cut-open arrived at `t` (before the landing; one a lay), with the frame on its area (`f`: fixed when
    /// the scaffold's path is taken — now, or at the switch; the fast path keeps the landed lattice's own).
    mutating func roughArrived(at t: Double, frame f: Frame? = nil, pieces: [Int] = []) {
        guard roughAt == nil, landedAt == nil else { return }
        roughAt = Swift.max(t, start)
        roughFrame = f
        liftPieces = pieces
        if scaffolding, let f { fix(f) }
    }
    /// ★ notes30: the frame on the rough cut-open's area (the scaffold's), until the scaffold's path fixes it.
    private(set) var roughFrame: Frame?
    /// The engine is now expected to land at `t` (nil: not known).
    mutating func expect(landingAt t: Double?) { expectedLanding = t }

    /// The lay landed at `t` (its finished lattice, its map). The scaffold's path: the lift under way finishes at the least
    /// pace, the lifts still to come follow at it, then the real floors replace it. Nothing of the scaffold shown yet (a quick
    /// lay after all, or no rough cut-open): the fast path.
    mutating func land(at t: Double) {
        guard landedAt == nil else { return }
        let l = Swift.max(t, start)
        advance(to: l)
        landedAt = l
        if scaffolding, (wallsFrom.map { $0 > l } ?? true) { scaffoldFrom = nil; lifts = [] }
        guard scaffolding else { return }
        if var last = lifts.last, last.end > l {   // the lift under way: its pieces still to come a beat apart
            var i = 0
            for k in last.snaps.indices where last.snaps[k] > l { i += 1; last.snaps[k] = l + Double(i) * Self.pieceS }
            last.end = Swift.max(l, last.snaps.last ?? l) + Self.liftBeatS
            lifts[lifts.count - 1] = last
        }
        commitLifts(through: .greatestFiniteMagnitude)
    }

    // MARK: the clock

    /// Takes the timelapse to `t`: ★ the switch (a lay still working `scaffoldAfterS` after the ask), and every lift due by then
    /// (its pace decided by what was known when it began). Call before asking what shows.
    mutating func advance(to t: Double) {
        if scaffoldFrom == nil, mayScaffold, landedAt == nil, !Self.controlNoSwitch, t >= start + Self.scaffoldAfterS {
            scaffoldFrom = start + Self.scaffoldAfterS
            if let f = roughFrame { fix(f) }
        }
        if scaffolding { commitLifts(through: t) }
    }
    /// RED CONTROL (tests): no switch — a lay foreseen quick stays on the fast path however long it runs (the site closed).
    nonisolated(unsafe) static var controlNoSwitch = false

    /// ★ notes30: the scaffold's walls — its first snap (the solid view; in X-ray its first lift): once both the path and the
    /// rough cut-open are there, no sooner than the site's least.
    var wallsFrom: Double? {
        guard let s = scaffoldFrom, let r = roughAt else { return nil }
        return Swift.max(s, r, start + Self.siteLeastS)
    }
    /// The scaffold's first lift: after its walls.
    var liftsFrom: Double? { wallsFrom.map { walls ? $0 + Self.scaffoldWallsS : $0 } }

    private mutating func commitLifts(through t: Double) {
        var guardSteps = 0
        while lifts.count < floors, let at = lifts.last?.end ?? liftsFrom, at <= t, guardSteps < 64 {
            lifts.append(planLift(at: at))
            guardSteps += 1
        }
    }

    /// Lift `lifts.count`, beginning at `at`: paced to top out `marginS` before the expected landing; after the landing at the
    /// least pace; the landing past or unknown, a steady one. ★ (23:50) a piece at a time: its pieces one a snap, at most
    /// `pieceS` apart (never stretched: the rest of its time is stillness before the next level), a few a snap
    /// (`piecesMostPerSnap` at most) only when its time cannot hold them one by one — its time grows before that cap does.
    private func planLift(at: Double) -> Lift {
        let k = lifts.count, n = pieces(k)
        let left = Double(Swift.max(1, floors - k))
        var dur: Double
        if let l = landedAt, l <= at { dur = Self.liftLeastS }
        else if let e = expectedLanding, e > at { dur = Swift.max(Self.liftLeastS, (e - Self.marginS - at) / left) }
        else { dur = Self.liftUnknownS }
        let most = Self.controlWholeLift ? Swift.max(1, n) : Self.piecesMostPerSnap
        dur = Swift.max(dur, Double((n + most - 1) / most) * Self.pieceLeastS / Self.activeShare)
        let room = Swift.max(1, Int(Self.activeShare * dur / Self.pieceLeastS))
        let per = Self.controlWholeLift ? Swift.max(1, n) : Swift.min(most, Swift.max(1, (n + room - 1) / room))
        let count = Swift.max(1, (n + per - 1) / per)
        let gap = Swift.min(Self.pieceS, Self.activeShare * dur / Double(count))
        return Lift(snaps: (0..<count).map { at + Double($0) * gap }, perSnap: per, pieces: n, end: at + dur)
    }

    /// ★ (23:50) a lift struck piece by piece: the pieces a strike snap takes, and its snaps.
    func strikePer(_ k: Int) -> Int {
        let n = pieces(k)
        return Self.controlWholeLift ? Swift.max(1, n)
            : Swift.min(Self.piecesMostPerSnap, Swift.max(1, (n + Self.strikeSnapsWanted - 1) / Self.strikeSnapsWanted))
    }
    func strikeSnaps(_ k: Int) -> Int { Swift.max(1, (pieces(k) + strikePer(k) - 1) / strikePer(k)) }

    /// The fast path's floors, once landed: the first's start and each one's time.
    var fastPlan: (from: Double, floorS: Double)? {
        guard !scaffolding, let l = landedAt else { return nil }
        let from = Swift.max(l, start + Self.siteLeastS)
        let target = Swift.max(start + Self.totalS - Self.toppedOutS, from + Self.buildLeastS)
        return (from, (target - from) / Double(Swift.max(1, floors)))
    }
    /// ★ notes30: the real floors replacing the scaffold, once landed and every lift begun: the first's start and each one's
    /// time — ★ (23:50) their own `replaceS` after the landing; a floor's snaps: its columns in `sweeps` slices, its bays in
    /// `sweeps`, then its lift struck piece by piece (`replaceSnaps`), `pieceS` apart at most.
    var replacePlan: (from: Double, floorS: Double)? {
        guard scaffolding, let l = landedAt, lifts.count >= floors, let top = lifts.last?.snaps.last else { return nil }
        let from = Swift.max(l, top) + Self.replaceBeatS
        let n = Double(Swift.max(1, floors))
        let need = (0..<floors).map { Double(replaceSnaps($0)) * Self.pieceLeastS / Self.activeShare }.max() ?? 0
        let real = Self.controlQuickReal ? Self.replaceV1S : Self.replaceS
        return (from, Swift.max(Self.floorLeastS, real / n, need, (start + Self.totalS - Self.toppedOutS - from) / n))
    }
    func replaceSnaps(_ f: Int) -> Int { Self.perFloorReal + strikeSnaps(f) }
    /// Floor `f`'s snaps, `floorS` long from `at`, this far apart.
    func replaceGap(_ f: Int, floorS: Double) -> Double {
        Swift.min(Self.pieceS, Self.activeShare * floorS / Double(replaceSnaps(f)))
    }

    /// What shows at `t` (after `advance(to: t)`).
    struct Shown: Equatable {
        /// The floors whose walls are off (the solid view).
        var opened = 0
        /// The real struts' snaps (the bars' shader's count: floor × perFloor + its kinds shown; on the scaffold's path floor ×
        /// perFloorReal + its slices shown).
        var snaps = 0
        /// ★ notes30: the scaffold's pieces risen, in the order they come (the first `lifts` of them) …
        var lifts = 0
        /// … and those struck, from the first (the first `struck` of them).
        var struck = 0
    }
    /// nil: nothing yet — the site.
    func shown(at t: Double) -> Shown? {
        var s = Shown()
        let n = floors
        if let p = fastPlan {
            guard t >= p.from - 1e-9 else { return nil }
            for f in 0..<n {
                let at = p.from + Double(f) * p.floorS
                guard at <= t + 1e-9 else { break }
                let k = Swift.min(snapsPerFloor, Int(((t - at) / (Self.snapShare * p.floorS) + 1e-9).rounded(.down)) + 1)
                if walls { s.opened = f + 1 }
                s.snaps = f * Self.perFloor + Swift.max(0, k - (walls ? 1 : 0))
            }
            return s
        }
        guard scaffolding else { return nil }
        var any = false
        if walls, let w = wallsFrom, t >= w - 1e-9 {
            let gap = Self.scaffoldWallsS / Double(Swift.max(1, n))
            s.opened = Swift.min(n, Int(((t - w) / gap + 1e-9).rounded(.down)) + 1)
            any = true
        }
        var before = 0
        for lift in lifts {
            let here = lift.snaps.filter { $0 <= t + 1e-9 }.count
            if here == 0 { break }
            s.lifts = before + Swift.min(lift.pieces, here * lift.perSnap)
            before += lift.pieces
            any = true
        }
        if let p = replacePlan, t >= p.from - 1e-9 {
            for f in 0..<n {
                let at = p.from + Double(f) * p.floorS
                guard at <= t + 1e-9 else { break }
                let c = Swift.min(replaceSnaps(f), Int(((t - at) / replaceGap(f, floorS: p.floorS) + 1e-9).rounded(.down)) + 1)
                s.snaps = f * Self.perFloorReal + Swift.min(c, Self.perFloorReal)
                let strikes = Swift.max(0, c - Self.perFloorReal)
                s.struck = Self.controlNeverStrike ? 0 : piecesBefore(f) + Swift.min(pieces(f), strikes * strikePer(f))
            }
            any = true
        }
        return any ? s : nil
    }

    /// ★ (23:50) the real floors whose lift of scaffold is struck whole at `t` (RED CONTROL `controlStrikeRealToo`'s reach).
    func floorsStruck(at t: Double) -> Int {
        guard let s = shown(at: t) else { return 0 }
        var f = 0
        while f < floors, piecesBefore(f + 1) <= s.struck, s.struck > 0 { f += 1 }
        return f
    }
    /// RED CONTROL (tests): the scaffold is never struck (it stands over the finished lattice until the timelapse ends).
    nonisolated(unsafe) static var controlNeverStrike = false

    /// Every snap's time, in order (tests: never two in one frame, hard stops). Once landed: all of them.
    var snapTimes: [Double] {
        var out: [Double] = []
        let n = floors
        if let p = fastPlan {
            for f in 0..<n { for k in 0..<snapsPerFloor { out.append(p.from + Double(f) * p.floorS + Double(k) * Self.snapShare * p.floorS) } }
            return out
        }
        if walls, let w = wallsFrom { for f in 0..<n { out.append(w + Double(f) * Self.scaffoldWallsS / Double(Swift.max(1, n))) } }
        for l in lifts { out += l.snaps }
        if let p = replacePlan {
            for f in 0..<n {
                let gap = replaceGap(f, floorS: p.floorS)
                for k in 0..<replaceSnaps(f) { out.append(p.from + Double(f) * p.floorS + Double(k) * gap) }
            }
        }
        return out.sorted()
    }

    /// The timelapse's end (the topped-out beat's last), once the lay has landed. nil: not landed yet.
    var end: Double? {
        guard let p = fastPlan ?? replacePlan else { return nil }
        return Swift.max(start + Self.totalS, p.from + Double(Swift.max(1, floors)) * p.floorS + Self.toppedOutS)
    }

    /// The timelapse is over at `t` (landed, its frame risen and topped out).
    func done(at t: Double) -> Bool { end.map { t >= $0 } ?? false }

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
    struct Frame: Equatable, Sendable {
        var up: SIMD3<Float>
        var across: SIMD3<Float>
        var low: Float
        var floorH: Float
        var acrossLow: Float
        var acrossW: Float
        var floors: Int

        /// Over the model-space box `lo`…`hi` (the rough area's, or the landed bars'), `up` and `across` in model coordinates.
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

        /// The third axis (square to up and across): the scaffold's depth.
        var depth: SIMD3<Float> { simd_normalize(simd_cross(up, across)) }
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
    /// ★ notes30: whether strut a–b is hidden with `snaps` shown and `struck` struck (the shader's rule, mirrored).
    static func hidden(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ f: Frame, snaps: Int, struck: Int = 0) -> Bool {
        let s = step(a, b, f)
        return s >= snaps || s < struck
    }
    /// ★ (23:50) the snap strut a–b comes in on the scaffold's path (`bar_build_hidden`'s sweeps, mirrored): its floor (by its
    /// lower end), then its slice across (by its middle) — a column among the floor's first `sweeps` snaps, a bay's strut among
    /// its next `sweeps`.
    static func sweepStep(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ f: Frame) -> Int {
        let ha = simd_dot(f.up, a), hb = simd_dot(f.up, b)
        let fl = Swift.min(Float(f.floors - 1), Swift.max(0, ((Swift.min(ha, hb) - f.low) / f.floorH + 1e-3).rounded(.down)))
        let d = b - a, len = simd_length(d)
        let column = len < 1e-6 || abs(simd_dot(d, f.up)) / len >= columnCos
        let mid = simd_dot(f.across, (a + b) / 2)
        let slice = Swift.min(Float(sweeps - 1), Swift.max(0, ((mid - f.acrossLow) / f.acrossW * Float(sweeps)).rounded(.down)))
        return Int(fl) * perFloorReal + (column ? 0 : sweeps) + Int(slice)
    }

    /// ★ notes30 M1 (the sheets on release 21's timelapse): a sheet has no struts, so it rises as its walls: the snap a place
    /// `p` of a sheet comes in is its floor (by its own height along up), then its bay across — a floor of a sheet goes up bay
    /// by bay, left to right, each all at once, after its floor's first beat (a sheet has no columns to stand first). The
    /// sheet pass's shader (`sheet_build_hidden`) is this, mirrored.
    static func sheetStep(_ p: SIMD3<Float>, _ f: Frame) -> Int {
        let fl = Swift.min(Float(f.floors - 1), Swift.max(0, ((simd_dot(f.up, p) - f.low) / f.floorH + 1e-3).rounded(.down)))
        let x = simd_dot(f.across, p)
        let bay = Swift.min(Float(bays - 1), Swift.max(0, ((x - f.acrossLow) / f.acrossW * Float(bays)).rounded(.down)))
        return Int(fl) * perFloor + 1 + Int(bay)
    }
}

/// The timelapse of the lay on screen, as the 3D view draws it: the page (or the sample) says when a lay is asked for, when its
/// rough cut-open and scaffold are made (the scaffold's path) and when it lands; the renderer asks it, each frame, whether the
/// bars it holds show and how much of them, how many floors' walls are off, and which of the scaffold's lifts stand. Main
/// thread only.
public final class LatticeBuildShow {
    /// Fires on every visible change (a snap, the site cleared, the end): the 3D view redraws itself.
    public let changed = PassthroughSubject<Void, Never>()
    /// The timelapse under way (nil: none — the bars on screen show whole).
    private(set) var timelapse: LatticeBuildTimelapse?
    /// The landed lay's bars (their token): only they show while a timelapse runs; any other bars (the last lay's) never.
    private(set) var token: Int?
    /// ★ notes30: the scaffold standing for this lay (its members and the rough cut-open), drawn by the renderer's scaffold pass;
    /// nil — none (the fast path, or not made yet).
    private(set) var scaffold: LatticeBuildScaffold.Drawing?
    /// ★ notes30: the view's up, right and depth in the part's own coordinates (the renderer's last frame; the part stood Z-up
    /// before one): the floors rise along the up (or the print's), the bays run along the right.
    var viewAxes: (up: SIMD3<Float>, across: SIMD3<Float>, depth: SIMD3<Float>) = (SIMD3(0, 0, 1), SIMD3(1, 0, 0), SIMD3(0, -1, 0))
    /// Lays asked for (tests).
    private(set) var asks = 0
    /// RED CONTROL (tests): no timelapse — the last lattice stays while the engine works and the new one shows whole the moment
    /// it lands (as before release 21: img 97's frame possible again with a late map).
    nonisolated(unsafe) public static var controlOff = false
    /// RED CONTROL (tests): no scaffold — a slow lay rises as a quick one (the site closed until it lands), no switch.
    nonisolated(unsafe) static var controlNoScaffold = false
    /// RED CONTROL (tests): every lay the page asks gets the scaffold, a quick one too.
    nonisolated(unsafe) static var controlScaffoldAlways = false
    /// RED CONTROL (tests): the struck lifts applied to the real lattice too (its struts taken away as the scaffold comes down).
    nonisolated(unsafe) static var controlStrikeRealToo = false
    /// The clock (tests set it; else now).
    nonisolated(unsafe) static var clockForTesting: CFTimeInterval?
    public static var now: CFTimeInterval { clockForTesting ?? CACurrentMediaTime() }
    static let tickFPS: Double = 30
    private var tickTask: Task<Void, Never>?
    private var lastSent: [Int]?

    public init() {}

    /// Animations are off (Settings › Skip all animations): no timelapse, but the lattice area blank while the lay runs.
    static var skipping: Bool { AppSettings.skipAllAnimations }

    /// A lay was asked for: the last lattice goes at once and the site stands cleared until this one shows. `walls`: the solid
    /// view (each floor's walls come off). ★ notes30: `scaffold` — a slow lay (`LatticeBuildTimelapse.plan`): the walls first
    /// and the scaffold; `mayScaffold` — the switch armed (the Lattice page's strut lays); `expectedS` — when it is expected to
    /// land, s from now (the scaffold's pace).
    public func layBegins(walls: Bool = false, scaffold: Bool = false, mayScaffold: Bool = false, expectedS: Double? = nil,
                          now: CFTimeInterval = LatticeBuildShow.now) {
        guard !Self.controlOff else { return }
        asks += 1
        let arm = mayScaffold && !Self.skipping && !Self.controlNoScaffold
        // a lay asked while the last is still being built starts again from a cleared site
        timelapse = LatticeBuildTimelapse(start: now, walls: walls && !Self.skipping, scaffold: arm && (scaffold || Self.controlScaffoldAlways),
                                          mayScaffold: arm, expectedLanding: expectedS.map { now + $0 })
        token = nil
        self.scaffold = nil
        changed.send()
        tick()
    }

    /// ★ notes30: this lay wants its rough cut-open made before it lays (the scaffold may come: a slow lay, or the switch).
    public var wantsRough: Bool { waiting && scaffold == nil && timelapse?.mayScaffold == true }
    /// ★ notes30: the scaffold the renderer draws — once the scaffold's path is taken (a quick lay's stays unsent).
    var scaffoldInUse: LatticeBuildScaffold.Drawing? { timelapse?.scaffolding == true ? scaffold : nil }
    /// ★ notes30: the token this lay's scaffold wears (its own pass; never a landed lay's: those count up from 1).
    var scaffoldToken: Int { -(1000 + asks) }

    /// ★ notes30: the up and across a frame stands on: the print's up (the face he kept) with the view's right square to it, or
    /// the view's own.
    func axes(printUp: SIMD3<Float>?) -> (up: SIMD3<Float>, across: SIMD3<Float>) {
        guard !LatticeBuildTimelapse.controlWorldUp, let p = printUp, simd_length(p) > 1e-6, simd_length(p).isFinite else {
            return (viewAxes.up, viewAxes.across)
        }
        let up = simd_normalize(p)
        return (up, LatticeBuildTimelapse.across(right: viewAxes.across, depth: viewAxes.depth, up: up))
    }

    /// ★ notes30: the rough cut-open and the scaffold on it arrived (before the lay lands): the frame is fixed from its area, its
    /// walls come off (the scaffold's path, now or at the switch) and the scaffold rises.
    func scaffoldArrived(_ d: LatticeBuildScaffold.Drawing, now: CFTimeInterval = LatticeBuildShow.now) {
        guard var tl = timelapse, token == nil, tl.mayScaffold, scaffold == nil else { return }
        tl.roughArrived(at: now, frame: d.frame, pieces: d.liftPieces)
        timelapse = tl
        scaffold = d
        changed.send()
        tick()
    }

    /// The lay landed: its bars (`token`) with their map, in the box `box` (the frame, when none is fixed yet; its floors along
    /// `printUp`, the face he kept, else the view's up). The fast path's floors rise; the scaffold's path: the real floors
    /// replace the scaffold (none: shown whole — animations off).
    public func landed(token t: Int, box: (lo: SIMD3<Float>, hi: SIMD3<Float>)? = nil, printUp: SIMD3<Float>? = nil,
                       now: CFTimeInterval = LatticeBuildShow.now) {
        guard var tl = timelapse, token == nil else { return }
        token = t
        if Self.skipping { stop(); return }
        if tl.frame == nil, let b = box {
            let (up, across) = axes(printUp: printUp)
            tl.fix(.init(lo: b.lo, hi: b.hi, up: up, across: across))
        }
        tl.land(at: now)
        if !tl.scaffolding { scaffold = nil }   // (a quick lay after all: nothing of the scaffold was shown)
        timelapse = tl
        changed.send()
        tick()
    }

    /// The renderer's landed bars (`token`) with no frame fixed yet: the frame from their box, now (never moved after).
    func fixFrame(lo: SIMD3<Float>, hi: SIMD3<Float>, up: SIMD3<Float>, across: SIMD3<Float>, token t: Int) {
        guard var tl = timelapse, tl.frame == nil, token == t else { return }
        tl.fix(.init(lo: lo, hi: hi, up: up, across: across))
        timelapse = tl
    }

    /// No timelapse (a lattice shown from memory, an error, the page closed): what is on screen shows as it is.
    public func stop() {
        let had = timelapse != nil
        timelapse = nil
        token = nil
        scaffold = nil
        tickTask?.cancel(); tickTask = nil
        lastSent = nil
        if had { changed.send() }
    }

    /// A lay is under way on screen: asked for and not yet landed (the page's "Refreshing Lattice" card, with animations off).
    public var waiting: Bool { timelapse != nil && token == nil }

    /// The frame the floors rise in (nil: not fixed yet).
    var frame: LatticeBuildTimelapse.Frame? { timelapse?.frame }

    /// The timelapse taken to `t` (the switch, every lift due by then).
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
        if tl.done(at: t) { return .all }
        guard let s = tl.shown(at: t) else { return .none }
        return s.snaps >= tl.floors * tl.realPerFloor ? .all : .snaps(s.snaps)
    }

    /// ★ notes30: which of the scaffold's pieces stand at `t` — the first `lifts` risen, the first `struck` of them struck
    /// (lifts > struck: something stands); nil — no scaffold (the fast path, none made, or the timelapse over).
    func revealScaffold(at t: CFTimeInterval) -> (lifts: Int, struck: Int)? {
        guard scaffold != nil, let tl = advanced(t), tl.scaffolding, !tl.done(at: t) else { return nil }
        guard let s = tl.shown(at: t) else { return (0, 0) }
        return (s.lifts, s.struck)
    }

    /// The floors whose walls are off at `t` for the bars `barsToken`: nil — the map as it is (no timelapse, X-ray, another
    /// lay's bars — `standing` keeps the part closed over them — or, on the scaffold's path, the landed lattice's exact map,
    /// its walls already off); 0 — none yet (the part closed).
    func wallsOpen(barsToken: Int, at t: CFTimeInterval) -> Int? {
        guard let tl0 = timelapse, tl0.walls else { return nil }
        if let d = scaffold, barsToken == d.token {   // ★ notes30: the rough cut-open, floor by floor before the scaffold
            guard let tl = advanced(t) else { return nil }
            return tl.shown(at: t)?.opened ?? 0
        }
        guard barsToken == token, let tl = advanced(t), !tl.scaffolding, !tl.done(at: t) else { return nil }
        return tl.shown(at: t)?.opened ?? 0
    }

    /// ★ his review (img 98, "None of the parts' walls open up"): the part closed over bars that are not this lay's while a
    /// timelapse runs (1: the last lay's map never opens it); nil — the map opens it (this lay's, or the scaffold's rough
    /// cut-open: floor by floor, `wallsOpen`).
    func standing(barsToken: Int, at t: CFTimeInterval) -> Float? {
        guard timelapse != nil else { return nil }
        if barsToken == token || barsToken == scaffold?.token { return nil }
        return 1
    }

    /// ★ notes30: the scaffold's pass is THE pass drawn (its rough map cuts the part, its walls, its inside shade): while the
    /// scaffold stands and the landed lattice (`landedToken`, the renderer's) is not on screen yet.
    func drawsScaffold(landedToken: Int?) -> Bool {
        guard let tl = timelapse, tl.scaffolding, scaffold != nil, !Self.skipping else { return false }
        guard let t = token else { return true }
        return landedToken != t
    }

    /// The timelapse ended at `t` (it is let go: nothing more to draw for it, the scaffold gone).
    private func settle(_ t: CFTimeInterval) -> Bool {
        guard let tl = timelapse, tl.done(at: t) else { return false }
        timelapse = nil
        token = nil
        scaffold = nil
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
        let key = [token ?? -1, s?.opened ?? -1, s?.snaps ?? -1, s?.lifts ?? -1, s?.struck ?? -1, tl.scaffolding ? 1 : 0,
                   scaffold == nil ? 0 : 1, tl.landedAt.map { t >= $0 ? 1 : 0 } ?? 0]
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
    /// x: the snaps shown (−1: all); y: the floors; z: the bays (★ notes30, sweeping: the slices); w: 1 on, ★ 3 sweeping (the
    /// scaffold's path: a floor's columns in slices across, then its bays in slices).
    var build = SIMD4<Float>(-1, 1, 1, 0)
    /// xyz: up, in the part's own coordinates; w: the lattice's lowest height along it.
    var up = SIMD4<Float>(0, 1, 0, 0)
    /// xyz: across (left to right); w: the lattice's lowest along it.
    var across = SIMD4<Float>(1, 0, 0, 0)
    /// x: a floor's height; y: the lattice's width across; z: a column's |cos| to up; w: snaps hidden from the bottom (0: none —
    /// nothing of the real lattice is ever taken away; RED CONTROL `controlStrikeRealToo` only).
    var sizes = SIMD4<Float>(1, 1, 0.85, 0)

    init() {}
    init(snaps n: Int, struck: Int = 0, frame f: LatticeBuildTimelapse.Frame, sweeping: Bool = false) {
        build = SIMD4(Float(n), Float(f.floors), Float(sweeping ? LatticeBuildTimelapse.sweeps : LatticeBuildTimelapse.bays),
                      sweeping ? 3 : 1)
        up = SIMD4(f.up, f.low)
        across = SIMD4(f.across, f.acrossLow)
        sizes = SIMD4(f.floorH, f.acrossW, LatticeBuildTimelapse.columnCos, Float(Swift.max(0, struck)))
    }
}

extension MeshRenderer {
    /// The timelapse this view draws its bars by (the Lattice page's, the sample's), or none. True when it changed.
    @discardableResult
    func applyBuildShow(_ s: LatticeBuildShow?) -> Bool {
        guard buildShow !== s else { return false }
        buildShow = s
        scaffoldBars = nil   // (another show's scaffold is not this one's)
        return true
    }

    /// ★ notes30: the bars pass drawn as THE lattice this frame (its map cuts the part, its walls, its inside shade): the
    /// scaffold's while it stands and the landed lattice is not on screen yet, else the landed lay's.
    /// Organic's growth never: while an Organic lay is on screen its part opens by its own map, as before (his "two different
    /// animations").
    var drawnLayoutBars: LatticeLayoutBarsPass? {
        if growth?.layOnScreen == true { return layoutBars }
        if let show = buildShow, let sc = scaffoldBars, sc.isDrawable, show.drawsScaffold(landedToken: layoutBars?.token) {
            return sc
        }
        return layoutBars
    }

    /// ★ notes30: once a frame, before anything reads the bars — the view's axes, the landed bars' frame (the fast path), the
    /// scaffold onto the GPU (once a lay) and each pass's walls held shut above the floors opened so far.
    func prepareBuild(_ device: MTLDevice, model m: simd_float4x4) {
        guard let show = buildShow else {
            scaffoldBars = nil
            layoutBars?.openWalls(nil, frame: nil)
            return
        }
        let now = LatticeBuildShow.now
        show.viewAxes = (SIMD3(m.columns.0.y, m.columns.1.y, m.columns.2.y), SIMD3(m.columns.0.x, m.columns.1.x, m.columns.2.x),
                         SIMD3(m.columns.0.z, m.columns.1.z, m.columns.2.z))
        if let p = layoutBars, let box = p.box {   // the landed bars with no frame fixed yet: the frame from their box now
            let (up, across) = show.axes(printUp: p.printUp)
            show.fixFrame(lo: box.lo, hi: box.hi, up: up, across: across, token: p.token)
        }
        if let d = show.scaffoldInUse {
            if scaffoldBars == nil, LatticeLayoutBarsPass.lastInitError == nil {
                do { scaffoldBars = try LatticeLayoutBarsPass(device: device) } catch {
                    LatticeLayoutBarsPass.lastInitError = "\(error)"
                    NSLog("DIAG scaffold: %@", "\(error)")
                }
            }
            if let p = scaffoldBars, p.token != d.token {
                p.upload(d.inputs)
                p.uploadGrid(d.inputs.solid)
            }
            scaffoldBars?.openWalls(show.wallsOpen(barsToken: d.token, at: now), frame: show.frame)
        } else if scaffoldBars != nil {
            scaffoldBars = nil   // ★ nothing of the scaffold left once it is struck and the timelapse is over
        }
        if let p = layoutBars { p.openWalls(show.wallsOpen(barsToken: p.token, at: now), frame: show.frame) }
    }

    /// ★ his review (img 98): the part closed over the last lay's bars while a timelapse runs (nil: the map opens it — this
    /// lay's, or the scaffold's rough cut-open, floor by floor).
    var buildStanding: Float? {
        guard let show = buildShow, let pass = drawnLayoutBars else { return nil }
        return show.standing(barsToken: pass.token, at: LatticeBuildShow.now)
    }

    /// The bars this frame: drawn or not, and how much of them (nil: all). The world's up and right in the part's own
    /// coordinates (the model matrix's rows: the part's placement turns it, the camera never does) — ★ notes29 H3: or, for a
    /// lattice laid standing on the face he kept, the print's up (the floors rise as the file prints, layer by layer).
    /// ★ notes30: the frame is the timelapse's own, fixed once — never moved; while the scaffold is THE pass drawn, the real bars'
    /// reveal is none (`scaffoldRange` says which of its pieces draw).
    func buildReveal(model: simd_float4x4) -> (draw: Bool, reveal: LatticeBuildRevealUniform?) {
        guard let show = buildShow, let pass = drawnLayoutBars else { return (true, nil) }
        let now = LatticeBuildShow.now
        lastBuildStanding = show.standing(barsToken: pass.token, at: now)
        if pass === scaffoldBars {
            lastBuildFrame = show.frame
            return (scaffoldRange(show, at: now) != nil, nil)
        }
        if let box = pass.box {
            let (up, across) = show.axes(printUp: pass.printUp)
            show.fixFrame(lo: box.lo, hi: box.hi, up: up, across: across, token: pass.token)
        }
        let f = show.frame
        lastBuildFrame = f
        let r = show.reveal(barsToken: pass.token, floors: f?.floors ?? LatticeBuildTimelapse.floorsLeast, at: now)
        let sweeping = show.timelapse?.scaffolding == true
        let perFloor = sweeping ? LatticeBuildTimelapse.perFloorReal : LatticeBuildTimelapse.perFloor
        // (RED CONTROL `controlStrikeRealToo`: the real floors whose scaffold is struck taken away too; else never)
        let struck = LatticeBuildShow.controlStrikeRealToo ? (show.timelapse?.floorsStruck(at: now) ?? 0) * perFloor : 0
        switch r {
        case .all:
            guard struck > 0, let f else { return (true, nil) }
            return (true, LatticeBuildRevealUniform(snaps: f.floors * perFloor, struck: struck, frame: f, sweeping: sweeping))
        case .none: return (false, nil)
        case .snaps(let n):
            guard let f else { return (false, nil) }
            return (n > 0, LatticeBuildRevealUniform(snaps: n, struck: struck, frame: f, sweeping: sweeping))
        }
    }

    /// ★ (23:50) the scaffold's pieces drawn this frame — its pieces lie in its pass in the order they come, so those standing
    /// are one run of them: risen and not yet struck. nil — none.
    func scaffoldRange(_ show: LatticeBuildShow, at now: CFTimeInterval) -> Range<Int>? {
        guard let r = show.revealScaffold(at: now), r.lifts > r.struck else { return nil }
        return r.struck..<r.lifts
    }

    /// ★ notes30: the scaffold over the landed lattice (after the landing, until its last piece is struck): its pass and the
    /// pieces standing; nil — none this frame.
    func scaffoldOverLanded() -> (pass: LatticeLayoutBarsPass, range: Range<Int>)? {
        guard let show = buildShow, let sc = scaffoldBars, sc.isDrawable, drawnLayoutBars !== sc,
              let r = scaffoldRange(show, at: LatticeBuildShow.now) else { return nil }
        return (sc, r)
    }
}
#endif
