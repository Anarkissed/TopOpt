// LatticeGrowthReplay — ★ his words 2026-11-23, after release 16 (a): "One idea I had was to start an animation by removing the
// walls, allowing that animation to run for 2-3 seconds and THEN starting the growing animation - even if it's ahead of what's
// actually being built. This way, theres an extra 2-3 seconds of space that can be added to the experience. All it would take
// is the recording of the vine growth. And then you could even do it at about 10-12frames per second, slowing the animation
// down to provide an even longer buffer. It's a cheat, but one that might help".
//
// The clock of what the 3D view shows of an Organic lay (LatticeGrowth holds one per lay):
//   * WALLS FIRST: for `wallsS` the part opens — its walls over the lattice dissolve away (the map this lay opens them with),
//     or, with no map yet, the part fades to X-ray — and no vine shows;
//   * THEN THE REPLAY of the recording (the engine's growth tap, append-only in LatticeGrowth) in steps of `stepsPerS` a second
//     (stop-motion), slowed: `slowDefault` recorded seconds a second, or paced so it ends about `marginS` before the time the
//     last lay like it landed; never ahead of what the engine has laid (the playhead never passes the recording);
//   * NEVER MAKING THE FINISHED LATTICE WAIT: the moment the lay lands, whatever of the replay (and of the walls) is left is
//     shown in `catchSteps` steps — within `catchUpS` — and then the landed lattice takes over (LatticeGrowth's sink).
//   * ★ notes29 (his notes on release 20, 2026-11-25: "add a couple more seconds to the organic animations — the end always
//     feels too rushed. Slow it down a little bit, allow it to be an experience. The user won't mind an extra 2 or 3 seconds
//     wait"): the end is about 2.3 s longer — the catch-up over `catchUpS` 2.4 s (was 0.8), its steps easing out (the big ones
//     first, the last few small: it slows into the finished lattice); a lay whose replay had already caught up holds the grown
//     vines `restS` before they sink (was none); the sink itself `LatticeGrowth.fadeS` 1.0 s, eased (was 0.35, straight).
//   * ★ his review of the clips (the same evening): "As for organic, it's currently at about 6 seconds, let's do 8 seconds for
//     the entire animation" — then, the clips seen, HIS PICK: "Let's go with 7 seconds for ALL animations. It looks great!":
//     from the lay's start (the walls) to the growth gone, at least `minTotalS` 7 s — a quick lay's
//     landing stretches its catch-up (or its rest) to fill it; a slow lay takes as long as it lays, its end never shorter
//     than the catch-up and the sink above.
// Pure: wall seconds in, the playhead out (in birth units: one poll of the recording, LatticeGrowth.append's clock).
import Foundation

struct LatticeGrowthReplay: Equatable {
    /// The walls' part (the dissolve, or the fade to X-ray) before any vine shows.
    static let wallsS: Double = 2.5
    /// The replay's steps a second (his "10-12 frames per second").
    static let stepsPerS: Double = 11
    /// One birth unit of the recording: one poll (LatticeLayoutPreview.growthPollS).
    static let pollS: Double = 0.15
    /// How fast the recording plays (recorded seconds a second) with no time to aim at; the slowest and the fastest paced.
    static let slowDefault: Double = 0.4
    static let slowLeast: Double = 0.15
    static let slowMost: Double = 1.0
    /// The pacing aims to end this long before the expected landing (what is left of the wait, the band of light fills).
    static let marginS: Double = 1.0
    /// After the lattice lands: what is left, in `catchSteps` steps (★ notes29: 2.4 s, was 0.8 — his to tune).
    nonisolated(unsafe) static var catchUpS: Double = 2.4
    /// ★ notes29: the catch-up's steps ease out (the most first, the last small); false: even steps (release 20).
    nonisolated(unsafe) static var catchUpEases = true
    /// ★ notes29: a lay whose replay had shown everything when it landed: the grown vines held this long before they sink
    /// (release 20: none).
    nonisolated(unsafe) static var restS: Double = 1.4
    static var catchSteps: Int { Swift.max(1, Int((catchUpS * stepsPerS).rounded(.down))) }
    /// How long the catch-up lasts (its last step).
    static var catchUpEndS: Double { Double(catchSteps) / stepsPerS }
    /// ★ his review (notes29): the entire animation, from the lay's start to the growth gone, at least this long (s).
    /// ★ his pick after the clips: "7 seconds for ALL animations" (the clips showed 8).
    nonisolated(unsafe) static var minTotalS: Double = hisTotalS
    static let hisTotalS: Double = 7.0
    /// ★ notes29: the end as release 20 had it (the clips' "before"; tests' red control).
    static let release20CatchUpS: Double = 0.8
    static let release20RestS: Double = 0
    /// ★ notes29: puts the end back as release 20 had it (true) or as now (false) — the clips' before and after.
    static func endAsRelease20(_ on: Bool) {
        catchUpS = on ? release20CatchUpS : 2.4
        restS = on ? release20RestS : 1.4
        minTotalS = on ? 0 : hisTotalS
        catchUpEases = !on
        LatticeGrowth.fadeS = on ? LatticeGrowth.release20FadeS : 1.0
        LatticeGrowth.fadeEases = !on
    }

    /// When the lay began (wall s), whether it opens its walls first, and when the last lay like it landed (wall s; nil: none).
    let start: Double
    let walls: Bool
    let expectedEnd: Double?
    /// The playhead (birth units): the pieces born up to it show.
    private(set) var shown: Double = 0
    /// Steps taken since the replay began.
    private(set) var steps = 0
    /// The lay landed: when, and the playhead then and the recording's end.
    private(set) var landed: Landed?
    /// ★ notes29: the catch-up's steps (at least `catchSteps`; more, to fill `minTotalS`) and, nothing left, the rest's end.
    struct Landed: Equatable { var at: Double, from: Double, to: Double, wallsFrom: Double, steps: Int, restUntil: Double }

    init(start: Double, walls: Bool, expectedEnd: Double?) {
        self.start = start; self.walls = walls; self.expectedEnd = expectedEnd
    }

    /// When the replay's first step can come.
    var replayStart: Double { start + (walls ? Self.wallsS : 0) }

    /// How far the walls have gone (0 → 1, eased) at `t`; after a landing they finish within the catch-up.
    func wallsProgress(_ t: Double) -> Double {
        guard walls else { return 1 }
        let own = Self.ease(Swift.min(Swift.max((t - start) / Self.wallsS, 0), 1))
        guard let l = landed else { return own }
        let k = Swift.min(Swift.max((t - l.at) / (Double(l.steps) / Self.stepsPerS), 0), 1)
        return Swift.max(own, l.wallsFrom + (1 - l.wallsFrom) * k)
    }

    /// How fast the recording plays at `t` (recorded seconds a second): toward ending `marginS` before the expected landing,
    /// between the slowest and the recording's own pace; with no time to aim at, `slowDefault`.
    func pace(at t: Double, recorded: Double) -> Double {
        guard let end = expectedEnd else { return Self.slowDefault }
        let left = end - Self.marginS - t
        guard left > 0.5 else { return Self.slowMost }
        let backlog = Swift.max(recorded - shown, 0) * Self.pollS
        return Swift.min(Self.slowMost, Swift.max(Self.slowLeast, backlog / left))
    }

    /// Moves the playhead to `t` (whole steps only), `recorded` birth units laid so far. Never past the recording.
    mutating func advance(to t: Double, recorded: Double) {
        if let l = landed {
            let k = Swift.min(l.steps, Swift.max(0, Int(((t - l.at) * Self.stepsPerS + 1e-9).rounded(.down))))
            shown = Swift.max(shown, l.from + (l.to - l.from) * Self.catchShare(Double(k) / Double(l.steps)))
            return
        }
        guard t >= replayStart else { return }
        let due = Int(((t - replayStart) * Self.stepsPerS + 1e-9).rounded(.down))
        var guardSteps = 0
        while steps < due, guardSteps < 100_000 {
            let at = replayStart + Double(steps + 1) / Self.stepsPerS
            shown = Swift.min(recorded, shown + pace(at: at, recorded: recorded) / Self.stepsPerS / Self.pollS)
            steps += 1; guardSteps += 1
        }
    }

    /// The lay landed at `t` with `recorded` birth units: the rest is shown within the catch-up.
    mutating func land(at t: Double, recorded: Double) {
        guard landed == nil else { return }
        advance(to: t, recorded: recorded)
        // ★ his review: the whole lasts `minTotalS` at least — what is left of it (less the sink) goes to the catch-up or rest
        let fill = start + Self.minTotalS - LatticeGrowth.fadeS - t
        let catchS = Swift.max(Self.catchUpEndS, fill)
        let steps = Swift.max(Self.catchSteps, Int((catchS * Self.stepsPerS - 1e-9).rounded(.up)))   // (never short of the total)
        landed = Landed(at: t, from: shown, to: recorded, wallsFrom: wallsProgress(t), steps: steps,
                        restUntil: t + Swift.max(Self.restS, fill))
    }

    /// When everything of the landed lay is shown (the landed lattice takes over then); nil: not landed. ★ notes29: nothing
    /// left, the grown vines rest `restS` first.
    var caughtUpAt: Double? {
        guard let l = landed else { return nil }
        let rest = l.to - l.from > 1e-9 || (walls && l.wallsFrom < 1)
        return rest ? l.at + Double(l.steps) / Self.stepsPerS : l.restUntil
    }

    /// ★ notes29: the share of what was left shown after `x` of the catch-up's steps (0 → 1): eased out — the most first.
    static func catchShare(_ x: Double) -> Double {
        let c = Swift.min(Swift.max(x, 0), 1)
        return catchUpEases ? 1 - (1 - c) * (1 - c) : c
    }

    /// Everything recorded so far is shown (the band of light may run).
    func caughtUp(recorded: Double) -> Bool { shown >= recorded - 1e-9 }

    private static func ease(_ x: Double) -> Double { x * x * (3 - 2 * x) }
}
