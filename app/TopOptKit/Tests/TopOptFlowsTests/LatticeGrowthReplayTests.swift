// LatticeGrowthReplayTests — ★ his words 2026-11-23, after release 16 (a): "start an animation by removing the walls, allowing that
// animation to run for 2-3 seconds and THEN starting the growing animation - even if it's ahead of what's actually being built
// ... All it would take is the recording of the vine growth. And then you could even do it at about 10-12frames per second,
// slowing the animation down to provide an even longer buffer." What 362 told him we build, checked here on the replay's clock
// (pure) and on LatticeGrowth:
//   * the walls first (2-3 s, nothing grows), THEN the replay of the recording, in 10-12 steps a second, BEHIND the engine;
//   * paced toward the time the last lay like it took, when there is one;
//   * it NEVER makes the finished lattice wait: what is left is shown within a second of the landing (the landed lattice held
//     no longer than that), then the tubes sink into it. RED CONTROL `controlNoCatchUp`: at its own pace the lattice would
//     wait many seconds;
//   * the band of light only once the replay has shown everything recorded, the engine still past its growing;
//   * a lay that begins while the last one is still landing waits for that landing (its pieces kept).
import XCTest
import Combine
import QuartzCore
@testable import TopOptFlows
@testable import TopOptKit

@MainActor
final class LatticeGrowthReplayTests: XCTestCase {

    override func tearDown() {
        LatticeGrowth.controlNoCatchUp = false
        LatticeGrowth.controlNoWorkingBand = false
        super.tearDown()
    }

    /// The engine as his stand's lay goes: it grows for `growS` (a poll's batch every 0.15 s), then finishes until `landS`.
    struct Engine {
        var growS = 4.0, landS = 30.0
        func recorded(at t: Double) -> Double { Swift.min(t, growS) / LatticeGrowthReplay.pollS }
    }

    // MARK: the replay's clock

    /// Walls first: for 2.5 s nothing grows and the walls open (eased 0 → 1); then the replay, 10-12 steps a second, behind
    /// the engine all the way; never past the recording.
    func testTheWallsFirstThenTheReplayBehindTheEngineInStepsOfTenToTwelveASecond() {
        let e = Engine()
        var r = LatticeGrowthReplay(start: 100, walls: true, expectedEnd: nil)
        XCTAssertEqual(LatticeGrowthReplay.wallsS, 2.5, "★ 2-3 seconds")
        XCTAssertTrue((10...12).contains(LatticeGrowthReplay.stepsPerS), "★ 10-12 steps a second")
        var changes: [Double] = [], last = 0.0, lastWalls = -1.0
        for k in 0...(30 * 120) {   // two minutes at 120 frames a second
            let t = 100 + Double(k) / 120
            r.advance(to: t, recorded: e.recorded(at: t - 100))
            let w = r.wallsProgress(t)
            XCTAssertGreaterThanOrEqual(w, lastWalls, "the walls only open"); lastWalls = w
            if t < 100 + LatticeGrowthReplay.wallsS { XCTAssertEqual(r.shown, 0, "★ the walls first: nothing grows yet") }
            XCTAssertLessThanOrEqual(r.shown, e.recorded(at: t - 100) + 1e-9, "★ never ahead of what the engine laid")
            if r.shown != last { changes.append(t); last = r.shown }
            if t - 100 > 1, t - 100 < e.growS { XCTAssertLessThan(r.shown, e.recorded(at: t - 100) * 0.6, "★ behind the engine") }
        }
        XCTAssertEqual(r.wallsProgress(100), 0)
        XCTAssertEqual(r.wallsProgress(100 + LatticeGrowthReplay.wallsS), 1)
        let first = changes.first ?? 0
        XCTAssertGreaterThanOrEqual(first, 100 + LatticeGrowthReplay.wallsS, "★ THEN the growing")
        // steps a second while it replays (before it caught up)
        let span = changes.filter { $0 < first + 5 }
        let perS = Double(span.count) / ((span.last ?? first) - first)
        print("REPLAY: first step at +\(first - 100) s, \(perS) steps a second, caught up at +\((changes.last ?? 0) - 100) s "
              + "(the engine grew for \(e.growS) s)")
        XCTAssertTrue((10...12.2).contains(perS), "★ about 11 steps a second: \(perS)")
        XCTAssertGreaterThan((changes.last ?? 0) - 100, LatticeGrowthReplay.wallsS + e.growS / LatticeGrowthReplay.slowDefault * 0.9,
                             "★ slowed down: \(e.growS) s of growing take about \(e.growS / LatticeGrowthReplay.slowDefault) s")
    }

    /// With the last lay's time known (30 s), the replay is paced to end about a second before it; never ahead of the engine.
    func testPacedTowardTheTimeTheLastLayTook() {
        let e = Engine(growS: 4, landS: 30)
        var r = LatticeGrowthReplay(start: 0, walls: true, expectedEnd: e.landS)
        var caught: Double?
        for k in 0...(40 * 60) {
            let t = Double(k) / 60
            r.advance(to: t, recorded: e.recorded(at: t))
            XCTAssertLessThanOrEqual(r.shown, e.recorded(at: t) + 1e-9)
            if caught == nil, t > e.growS, r.caughtUp(recorded: e.recorded(at: t)) { caught = t }
        }
        print("REPLAY paced: caught up at \(caught ?? -1) s, the lay expected at \(e.landS) s")
        let c = try? XCTUnwrap(caught)
        XCTAssertNotNil(c)
        XCTAssertGreaterThan(c ?? 0, e.landS - LatticeGrowthReplay.marginS - 3, "★ it fills the wait")
        XCTAssertLessThanOrEqual(c ?? .infinity, e.landS - LatticeGrowthReplay.marginS + 0.6, "★ and ends before the lattice")
    }

    /// The lay lands with most of the replay still to come: the rest shows within a second (stepped), then the landed lattice
    /// takes over; the walls too, when they had not finished. RED CONTROL: at its own pace it would take many seconds.
    func testTheLandingNeverWaitsMoreThanASecond() {
        for (landAt, walls) in [(6.0, true), (1.2, true), (9.0, false)] {
            let e = Engine(growS: 5, landS: landAt)
            var r = LatticeGrowthReplay(start: 0, walls: walls, expectedEnd: nil)
            for k in 0...Int(landAt * 60) { let t = Double(k) / 60; r.advance(to: t, recorded: e.recorded(at: t)) }
            let left = e.recorded(at: landAt) - r.shown
            XCTAssertGreaterThan(left, 1, "premise: much left at the landing (\(landAt) s)")
            // RED CONTROL: not sped up — at its own pace the rest would take this long
            let ownPace = left * LatticeGrowthReplay.pollS / LatticeGrowthReplay.slowDefault
            r.land(at: landAt, recorded: e.recorded(at: landAt))
            let done = try? XCTUnwrap(r.caughtUpAt)
            XCTAssertLessThanOrEqual((done ?? .infinity) - landAt, 1.0, "★ within a second of the landing")
            XCTAssertGreaterThan(ownPace, 2, "RED CONTROL: at its own pace the lattice would wait \(ownPace) s")
            var steps = Set<Double>()
            for k in 0...120 {
                let t = landAt + Double(k) / 120
                r.advance(to: t, recorded: e.recorded(at: landAt))
                steps.insert(r.shown)
                if t >= (done ?? 0) { XCTAssertEqual(r.shown, e.recorded(at: landAt), accuracy: 1e-9, "★ all of it shown") }
                if walls, t >= (done ?? 0) { XCTAssertEqual(r.wallsProgress(t), 1, accuracy: 1e-9, "the walls done too") }
            }
            XCTAssertGreaterThanOrEqual(steps.count, 4, "★ still a replay (in steps), only quicker")
            print("LANDING at \(landAt) s: \(left) polls left, shown by +\((done ?? 0) - landAt) s; at its own pace \(ownPace) s")
        }
    }

    // MARK: on LatticeGrowth

    private func pieces(_ n: Int, at x: Float = 0) -> (xyz: [Float], region: [Int32]) {
        var xyz: [Float] = []
        for k in 0..<n { xyz += [x, Float(k), 0, x, Float(k) + 1, 0] }
        return (xyz, [Int32](repeating: 1, count: n))
    }

    /// The growth through a lay: nothing during the walls, then the first pieces, behind; at the landing the landed lattice is
    /// held at most a second, then the tubes sink. RED CONTROL `controlNoCatchUp`: the landed lattice held for seconds.
    func testTheGrowthHoldsTheLandedLatticeAtMostASecond() {
        for red in [false, true] {
            LatticeGrowth.controlNoCatchUp = red
            let g = LatticeGrowth()
            let t0 = CACurrentMediaTime() + 1000   // a clock of its own, ahead of the ticker's
            g.layBegins([], lineMM: 0.45, opening: .xray, now: t0)
            XCTAssertTrue(g.layOnScreen)
            for poll in 0..<20 {   // 3 s of growing
                let p = pieces(500, at: Float(poll)); g.append(xyz: p.xyz, region: p.region)
            }
            XCTAssertEqual(g.shownCount(at: t0 + 1), 0, "★ the walls first")
            XCTAssertLessThan(g.wallsProgress(at: t0 + 1), 1)
            let mid = g.shownCount(at: t0 + LatticeGrowthReplay.wallsS + 1)
            XCTAssertGreaterThan(mid, 0, "★ then it grows")
            XCTAssertLessThan(mid, g.count / 2, "★ behind")
            let land = t0 + LatticeGrowthReplay.wallsS + 1.5
            g.seal(landed: true, now: land)
            XCTAssertTrue(g.holdsLanded(at: land + 0.1), "the landed lattice waits for the rest of the replay")
            if red {
                XCTAssertTrue(g.holdsLanded(at: land + 1.5), "RED CONTROL: at its own pace the finished lattice waits")
                XCTAssertGreaterThan((g.fadeStarted ?? 0) - land, 2)
                continue
            }
            XCTAssertFalse(g.holdsLanded(at: land + 1.0), "★ never more than a second")
            XCTAssertEqual(g.shownCount(at: land + 1.0), g.count, "★ every piece shown by then")
            XCTAssertLessThanOrEqual((g.fadeStarted ?? .infinity) - land, 1.0)
            XCTAssertEqual(g.alpha(at: (g.fadeStarted ?? 0) + LatticeGrowth.fadeS + 0.01), 0, "then it sinks into it")
            XCTAssertLessThanOrEqual(LatticeGrowth.landingS, 1.1 + 1e-9, "the landing in all")
        }
    }

    /// The band of light only once the replay has shown everything recorded and the engine is past its growing.
    func testTheBandOnlyOnceTheReplayCaughtUp() {
        let g = LatticeGrowth()
        let t0 = CACurrentMediaTime() + 1000
        g.layBegins([], lineMM: 0.45, opening: .open, now: t0)
        for poll in 0..<10 { let p = pieces(100, at: Float(poll)); g.append(xyz: p.xyz, region: p.region) }
        g.phaseMoved(5, now: t0 + 0.5)
        XCTAssertNil(g.workingSince, "★ finishing, but the replay is still behind: no band yet")
        var t = t0 + 0.5
        while g.shownCount(at: t) < g.count, t < t0 + 60 { t += 0.05 }
        _ = g.shownCount(at: t + 0.05)
        XCTAssertNotNil(g.workingSince, "★ the replay caught up: the band")
        print("BAND from +\((g.workingSince ?? 0) - t0) s (the replay caught up at +\(t - t0) s)")
        g.seal(landed: true, now: t + 0.2)
        XCTAssertNil(g.workingSince, "it ends with the landing")
    }

    /// A lay that lands while the last one is still landing (a quick exact lattice after its Draft): its growth is moot —
    /// dropped — and the finished lattice shows as the last landing ends, within a second; nothing replays over it.
    func testALayThatLandsWhileTheLastIsLandingIsShownAtOnce() {
        let g = LatticeGrowth()
        let t0 = CACurrentMediaTime() + 1000
        g.layBegins([], lineMM: 0.45, opening: .open, now: t0)
        for poll in 0..<10 { let p = pieces(100, at: Float(poll)); g.append(xyz: p.xyz, region: p.region) }
        let land = t0 + 1
        g.seal(landed: true, now: land)                                   // the Draft lands: its replay catches up
        g.layBegins([], lineMM: 0.45, opening: .open, now: land + 0.1)   // the exact lattice begins (waits)
        g.restart(now: land + 0.2)
        let b = pieces(50, at: 20); g.append(xyz: b.xyz, region: b.region)
        g.seal(landed: true, now: land + 0.4)                             // ...and lands while the Draft is still landing
        let end = (g.fadeStarted ?? 0) + LatticeGrowth.fadeS
        XCTAssertLessThanOrEqual(end - land, LatticeGrowth.landingS + 1e-9)
        XCTAssertFalse(g.holdsLanded(at: land + 1.0), "★ the finished lattice shows within a second")
        XCTAssertEqual(g.shownCount(at: end + 0.01), 0, "the growth gone")
        XCTAssertFalse(g.layOnScreen, "★ the quick lay's growth dropped: nothing replays over its finished lattice")
    }

    /// A lay that begins while the last is still landing: its pieces wait (kept) and grow once that landing ends; the last
    /// lay's replay is never cut short.
    func testANewLayWaitsForTheLastOnesLanding() async throws {
        let g = LatticeGrowth()
        let t0 = CACurrentMediaTime()
        g.layBegins([], lineMM: 0.45, opening: .open, now: t0 - 10)
        let a = pieces(300); g.append(xyz: a.xyz, region: a.region)
        g.seal(landed: true, now: t0)
        XCTAssertTrue(g.landing(t0 + 0.1))
        g.layBegins([], lineMM: 0.45, opening: .open, now: t0 + 0.1)   // the exact lattice after its Draft
        g.restart(now: t0 + 0.1)
        let b = pieces(40, at: 9); g.append(xyz: b.xyz, region: b.region)
        XCTAssertEqual(g.count, 300, "★ the last lay's growth stays while it lands")
        try await Task.sleep(nanoseconds: UInt64((LatticeGrowth.landingS + 0.3) * 1e9))
        XCTAssertFalse(g.sealed, "the new lay's")
        XCTAssertEqual(g.count, 40, "★ its pieces, kept while it waited")
        XCTAssertTrue(g.layOnScreen)
        g.stop()
        XCTAssertEqual(g.count, 0)
        XCTAssertFalse(g.layOnScreen, "stopped: nothing")
    }
}
