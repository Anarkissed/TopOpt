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
    /// After the lattice lands: what is left, in `catchSteps` steps.
    static let catchUpS: Double = 0.8
    static var catchSteps: Int { Swift.max(1, Int((catchUpS * stepsPerS).rounded(.down))) }
    /// How long the catch-up lasts (its last step).
    static var catchUpEndS: Double { Double(catchSteps) / stepsPerS }

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
    struct Landed: Equatable { var at: Double, from: Double, to: Double, wallsFrom: Double }

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
        let k = Swift.min(Swift.max((t - l.at) / Self.catchUpEndS, 0), 1)
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
            let k = Swift.min(Self.catchSteps, Swift.max(0, Int(((t - l.at) * Self.stepsPerS + 1e-9).rounded(.down))))
            shown = Swift.max(shown, l.from + (l.to - l.from) * Double(k) / Double(Self.catchSteps))
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
        landed = Landed(at: t, from: shown, to: recorded, wallsFrom: wallsProgress(t))
    }

    /// When everything of the landed lay is shown (the landed lattice takes over then); nil: not landed.
    var caughtUpAt: Double? {
        guard let l = landed else { return nil }
        let rest = l.to - l.from > 1e-9 || (walls && l.wallsFrom < 1)
        return rest ? l.at + Self.catchUpEndS : l.at
    }

    /// Everything recorded so far is shown (the band of light may run).
    func caughtUp(recorded: Double) -> Bool { shown >= recorded - 1e-9 }

    private static func ease(_ x: Double) -> Double { x * x * (3 - 2 * x) }
}
