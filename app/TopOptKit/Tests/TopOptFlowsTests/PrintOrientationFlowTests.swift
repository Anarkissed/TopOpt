// PrintOrientationFlowTests — ★ notes27 P6 + P7 (builder H; his print orientation 11-23, SPEC 2d), the flow's states and the
// jobs "Check strength" sends, without a screen.
//
// His flow: "Print orientation" → "Best orientation" (OK) or "A new orientation may be stronger" (OK / Not now) → OK animates to
// it, Cancel (top left) animates back → Check strength / Manual orientation → the processing pop-up → the benefits modal
// (As placed | New) → Keep orientation (the face set: the next version, holding the new result) / Cancel (nothing changed).
import XCTest
import simd
@testable import TopOptFlows
@testable import TopOptKit

@MainActor
final class PrintOrientationFlowTests: XCTestCase {

    // MARK: fixtures (shaped like his stand's v8 print file: core P4's block)

    final class Calls: @unchecked Sendable {
        var kept: [(SIMD3<Double>, OptimizeOutcome)] = []
        var checks: [SIMD3<Double>] = []
        var cancelledSeen = false
        var fail: Error?
        var mac = true
        var wait = false
    }

    func host(_ c: Calls, kind: PrintCheckKind = .organic) -> PrintOrientationHost {
        PrintOrientationHost(kind: kind, macReady: { c.mac }, check: { up, _, cancelled, said in
            c.checks.append(up)
            said("Strengthening, round 2")
            while c.wait {
                if cancelled() { c.cancelledSeen = true; throw LatticeFileRun.Failure("Cancelled") }
                try await Task.sleep(nanoseconds: 5_000_000)
            }
            if let f = c.fail { throw f }
            return PrintCheckResult(up: up, outcome: try PrintOrientationJobsTests.outcome(["ok": true]),
                                    before: PrintMeasured(strength: 1.34, layerStrength: 7.53, supportMM3: 2139.8, paintedPlaces: 1,
                                                          heightMM: 70, layers: 350, bedMM2: 3119.8, tookS: 560),
                                    after: PrintMeasured(strength: 1.62, layerStrength: 4.35, supportMM3: 18668.8, paintedPlaces: 3,
                                                         heightMM: 110.4, layers: 553, bedMM2: 0, tookS: 590),
                                    required: 1.5)
        }, keep: { up, o in c.kept.append((up, o)) })
    }

    func settle(_ f: PrintOrientationFlow, until: () -> Bool) async {
        for _ in 0..<400 where !until() { try? await Task.sleep(nanoseconds: 5_000_000) }
    }

    // MARK: the pop-ups

    func testANewOrientationMayBeStrongerOKAnimatesToItAndCancelComesBack() throws {
        let f = PrintOrientationFlow()
        let r = try XCTUnwrap(PrintOrientationRanking.decode(PrintOrientationJobsTests.ranking(change: true)))
        f.start(kind: .organic, ranking: r, mesh: nil)
        XCTAssertEqual(f.phase, .asked)
        XCTAssertEqual(f.ask?.title, "A new orientation may be stronger", "★ his words")
        XCTAssertEqual(f.ask?.caption, "Stronger across the layers", "core's reason, ≤ 5 words")
        XCTAssertTrue(f.ask?.change ?? false, "OK / Not now")
        XCTAssertEqual(f.ask?.info.first, "Strength (estimate): 1.40× · needs 1.50×", "★ the estimate's numbers in its (i), said so")
        XCTAssertNil(f.shownUp(), "a question is not a decision: nothing turns yet")
        f.okay()
        XCTAssertEqual(f.phase, .proposed)
        XCTAssertTrue(f.animating, "★ OK animates the part to it")
        let up = try XCTUnwrap(f.shownUp())
        XCTAssertEqual(simd_distance(up, SIMD3<Float>(0.70710678, 0, 0.70710678)), 0, accuracy: 1e-6)
        XCTAssertTrue(f.shown?.onEdge ?? false, "an edge, held by supports")
        XCTAssertTrue(f.ownsCorner, "★ Check strength + Manual orientation in Export's place")
        f.cancel()
        XCTAssertEqual(f.phase, .placed)
        XCTAssertNil(f.shownUp(), "★ Cancel: back to how it prints")
        XCTAssertTrue(f.animating, "… animated back")
        XCTAssertFalse(f.ownsCorner, "Export is back")
    }

    func testBestOrientationSaysSoAndNotNowChangesNothing() throws {
        let f = PrintOrientationFlow()
        f.start(kind: .cells, ranking: try XCTUnwrap(PrintOrientationRanking.decode(PrintOrientationJobsTests.ranking(change: false))), mesh: nil)
        XCTAssertEqual(f.ask?.title, "Best orientation")
        XCTAssertEqual(f.ask?.caption, "Prints best as placed")
        XCTAssertFalse(f.ask?.change ?? true, "OK only")
        f.okay()
        XCTAssertEqual(f.phase, .placed)
        XCTAssertNil(f.shownUp())
        f.start(kind: .organic, ranking: try XCTUnwrap(PrintOrientationRanking.decode(PrintOrientationJobsTests.ranking(change: true))), mesh: nil)
        f.notNow()
        XCTAssertEqual(f.phase, .placed)
        XCTAssertNil(f.shownUp(), "★ Not now: nothing changes")
        for w in [PrintOrientationWords.bestCaption, PrintOrientationWords.manualCaption, PrintOrientationWords.check,
                  PrintOrientationWords.manual, PrintOrientationWords.keep, PrintOrientationWords.yourChoice] {
            XCTAssertLessThanOrEqual(w.split(separator: " ").count, 5, "his rule: ≤ 5 words: \(w)")
        }
    }

    // MARK: Manual orientation

    func testManualTapsAFaceOrAnEdgeAndAFaceThatWouldTipSaysSo() async throws {
        let f = PrintOrientationFlow()
        let s = PrintOrientationDrawnTests.standMesh()
        f.start(kind: .topology, ranking: nil, mesh: s)
        XCTAssertEqual(f.phase, .manual, "★ no ranking (a topology result): straight to Manual orientation")
        await settle(f) { f.hull != nil }
        let h = try XCTUnwrap(f.hull, "its faces found")
        let shown = AppPopups.shared
        let top = try XCTUnwrap(h.faces.first { $0.normal.z > 0.999 })
        f.pick(face: top)
        XCTAssertEqual(f.phase, .manual, "★ it would tip: it stays")
        XCTAssertEqual(shown.current?.title, "It would tip over", "★ a centred pop-up says so")
        shown.current = nil
        let back = try XCTUnwrap(h.faces.first { $0.normal.y < -0.999 })
        f.pick(face: back)
        // ★ RE-PINNED (notes28, his img 81 — Bambu Studio's Lay on face): the part turns to it and Manual stays open, its patches
        // back in the new pose once it has turned (the picked one outlined); Check strength from there
        XCTAssertEqual(f.phase, .manual)
        XCTAssertTrue(f.turning, "the patches wait while it turns")
        XCTAssertTrue(f.ownsCorner, "Check strength is there")
        XCTAssertEqual(f.shown?.up, SIMD3(0, 1, 0), "the back face down: printed with its back on the bed")
        XCTAssertEqual(f.shown?.recommended, false, "his own choice")
        f.manual()
        let e = try XCTUnwrap(h.edges.first)
        f.pick(edge: e)
        XCTAssertEqual(f.phase, .manual)
        XCTAssertTrue(f.shown?.onEdge ?? false)
    }

    // MARK: Check strength → the benefits → Keep / Cancel

    func testCheckStrengthThenKeepMakesTheNextVersionsResult() async throws {
        let f = PrintOrientationFlow()
        let c = Calls()
        f.start(kind: .organic, ranking: try XCTUnwrap(PrintOrientationRanking.decode(PrintOrientationJobsTests.ranking(change: true))), mesh: nil)
        f.okay()
        f.check(host: host(c), variant: PrintCheckVariant(index: 0, stl: nil))
        XCTAssertEqual(f.phase, .checking, "★ the processing pop-up")
        await settle(f) { f.phase == .compare }
        XCTAssertEqual(f.phase, .compare, "★ the benefits modal")
        XCTAssertEqual(c.checks.count, 1)
        let rows = try XCTUnwrap(f.result?.rows)
        XCTAssertEqual(rows.map(\.label), ["Strength", "Layer strength", "Supports", "Print height", "Bed contact", "Check took"])
        XCTAssertEqual(rows[0].old, "1.34×"); XCTAssertEqual(rows[0].new, "1.62×")
        XCTAssertEqual(rows[0].tone, .better, "★ better: the accent")
        XCTAssertEqual(rows[1].tone, .plain, "lower but still past the gate: not coloured")
        XCTAssertEqual(rows[2].new, "18.7 cm³ · 3 places")
        XCTAssertEqual(rows[3].new, "110 mm · 553 layers")
        XCTAssertEqual(rows[5].tone, .plain)
        f.keep(host: host(c))
        XCTAssertEqual(c.kept.count, 1, "★ Keep: the face set, the new result kept")
        XCTAssertEqual(c.kept.first?.0, SIMD3(0.7071067812, 0, 0.7071067812))
        XCTAssertEqual(f.phase, .placed)
    }

    func testAWeakerNewOrientationIsDangerAndCancelDiscards() async throws {
        let rows = PrintBenefitRow.rows(before: PrintMeasured(strength: 1.6, layerStrength: 3), after: PrintMeasured(strength: 1.2, layerStrength: 1.4),
                                        required: 1.5)
        XCTAssertEqual(rows[0].tone, .worse, "★ worse past the gate: danger")
        XCTAssertEqual(rows[1].tone, .worse)
        XCTAssertEqual(rows[2].old, "\u{2014}", "nothing measured: a dash, never a made-up number")
        let f = PrintOrientationFlow()
        let c = Calls()
        f.start(kind: .organic, ranking: try XCTUnwrap(PrintOrientationRanking.decode(PrintOrientationJobsTests.ranking(change: true))), mesh: nil)
        f.okay()
        f.check(host: host(c), variant: PrintCheckVariant(index: 0, stl: nil))
        await settle(f) { f.phase == .compare }
        f.discard()
        XCTAssertEqual(f.phase, .placed)
        XCTAssertNil(f.shownUp(), "★ Cancel: back as it was")
        XCTAssertTrue(c.kept.isEmpty, "nothing kept")
    }

    func testCancelWhileCheckingStopsTheMacsJobsAndNoMacOrAFailureSaySo() async throws {
        let f = PrintOrientationFlow()
        let c = Calls()
        c.wait = true
        f.start(kind: .cells, ranking: try XCTUnwrap(PrintOrientationRanking.decode(PrintOrientationJobsTests.ranking(change: true))), mesh: nil)
        f.okay()
        f.check(host: host(c), variant: PrintCheckVariant(index: 0, stl: nil))
        await settle(f) { f.stage == "Strengthening, round 2" }
        XCTAssertEqual(f.stage, "Strengthening, round 2", "the Mac's step, in plain words")
        f.stopCheck()
        XCTAssertEqual(f.phase, .proposed, "back to the way proposed")
        await settle(f) { c.cancelledSeen }
        XCTAssertTrue(c.cancelledSeen, "★ the run sees the cancel (its wait deletes the Mac's job)")
        // no Mac: a centred pop-up with Try again
        let d = Calls(); d.mac = false
        f.check(host: host(d), variant: PrintCheckVariant(index: 0, stl: nil))
        XCTAssertEqual(f.phase, .proposed)
        XCTAssertEqual(AppPopups.shared.current?.title, "Your Mac isn’t answering")
        AppPopups.shared.current = nil
        // a failure: a centred pop-up, back to proposed
        let e = Calls(); e.fail = LatticeFileRun.Failure("The Mac's worker did not answer")
        f.check(host: host(e), variant: PrintCheckVariant(index: 0, stl: nil))
        await settle(f) { f.phase == .proposed }
        XCTAssertEqual(f.phase, .proposed)
        XCTAssertEqual(AppPopups.shared.current?.title, "The strength couldn’t be checked")
        AppPopups.shared.current = nil
    }

}
