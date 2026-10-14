// FlexibleRound7ViewsReviewTests — round 7 batch R7-V's REVIEW (2026-10-14): the verify's confirmed findings on the views,
// each a test written BEFORE its fix (the stubs' red run: round7/batch_v/r7v_review_red_run.txt), with its RED control run
// inside. Part of FlexibleRound7ViewsTests (its fixtures: HIS pad, A1_0003 as he saved it — Finish None).
//   RV1 (major) his None pad opened as an opaque block with NO lattice (X-ray off for every finish): X-ray's DEFAULT follows
//       the finish — on for None / Rim / Skin, off for Covered — and his choice wins once made. RED `controlXrayOffOnOpen`.
//       ★ RE-PINNED by round 7 batch X1 (his Q9 answer): X-ray off for every finish, the lattice seen out of X-ray (the
//       printed view); RED `controlXrayByFinish`.
//   RV3 (major) a pick of the Top drew "12.0 mm" — his img2: "this 12mm is completely worthless … please remove whatever it
//       is", and his answer: "The squish number: only on the Squish page". RED `controlSquishTagsOnMain`.
//   RV5 (minor) his paused pose still JUMPED after an edit (held 0.38 → 1.00 → 0.00): it looked like the sim restarting
//       ("Only by pressing Play should the sim actually restart"). His pause freezes the pose. RED `controlPauseMovesPose`.
//   RV6 (minor) with Play off the sims' status was a faint grey speck and a failure said nothing: both Play icons say
//       working / failed (the hosted half measures the drawn ring and dot).
//   RV8 (minor) the Settings player's note was cut at 11" portrait: every line has shorter forms (the hosted half draws it
//       whole).
#if canImport(MetalKit)
import XCTest
import Combine
import simd
@testable import TopOptFlows
@testable import TopOptKit

extension FlexibleRound7ViewsTests {

    // MARK: - RV1 (★ RE-PINNED by X1): X-ray off by default whatever the finish; the lattice seen out of X-ray; his choice wins

    /// ★ RE-PINNED, round 7 batch X1 — his answer on the R7-V handoff's Q9 (2026-10-14): "No. X-ray mode should show the inside
    /// of the SOLID … The lattice should be visible without x-ray on as long as finish is set to something that isn't
    /// 'covered'." R7-V's review made X-ray's DEFAULT follow the finish (on for None / Rim / Skin — the stopgap); X1 retires
    /// it: off for every finish, and the walls are drawn out of X-ray (the printed view) unless the finish is Covered.
    /// RED CONTROL `controlXrayByFinish` (the stopgap: X-ray on for his None pad).
    func testXrayOpensOnForAFinishThatShowsTheLatticeAndOffForCovered() async throws {
        let (r, s, m) = try await hisPad()
        let p = r.project
        XCTAssertEqual(m.settings.finishMode, .none, "premise: his pad is saved with Finish None (pure lattice)")
        s.didExitSettings()
        try await FlexibleHisProject.waitFor(240, "the lattice") { m.lattice != nil && !m.latticeBuilding && !m.latticeIsStale }
        s.refresh()
        XCTAssertFalse(s.xrayOn, "★ X1: Finish None — X-ray OFF as the page opens")
        XCTAssertEqual(s.bodyAlpha(p, on: .lattice), 0, "★ the printed view: only the closed surface of the body draws")
        XCTAssertEqual(s.layer(p, stage: .lattice, pageUp: false)?.hidden, false, "★ the walls are drawn out of X-ray")
        XCTAssertTrue(s.wallsShown, "★ …and seen")
        XCTAssertTrue(s.latticeIconLit, "★ the Lattice icon is lit (his view)")
        // ★ RED CONTROL: R7-V's stopgap — X-ray on for his None pad
        s.controlXrayByFinish = true
        let control = s.xrayOn
        s.controlXrayByFinish = false
        XCTAssertTrue(control, "★ RED CONTROL: R7-V's stopgap opened his None pad in X-ray")
        // his tap wins
        s.toggleXray()
        XCTAssertTrue(s.xrayOn, "his X-ray tap: on")
        XCTAssertEqual(s.bodyAlpha(p, on: .lattice), FlexibleStagePage.xrayBodyAlpha, "the ghost")
        s.toggleXray()
        // Covered: the plain model — X-ray off, no wall drawn
        s.xrayChoice = [:]
        m.edit({ $0.finish = FlexibleFinish.covered.rawValue }, recompute: false)
        XCTAssertFalse(s.xrayOn, "★ Finish Covered: X-ray off")
        XCTAssertEqual(s.bodyAlpha(p, on: .lattice), 1, "★ …the opaque model (the print)")
        // Rim and Skin: X-ray off too (their lattice shows through the finish in the printed view)
        for f in [FlexibleFinish.rim, .skin] {
            m.edit({ $0.finish = f.rawValue }, recompute: false)
            XCTAssertFalse(s.xrayOn, "★ Finish \(f.rawValue): X-ray off by default")
        }
        // his choice outlives a finish change
        s.toggleXray()
        XCTAssertTrue(s.xrayOn)
        m.edit({ $0.finish = FlexibleFinish.none.rawValue }, recompute: false)
        XCTAssertTrue(s.xrayOn, "★ his X-ray choice, kept for the session")
        print("FLEX-R7V-RV1 (re-pinned by X1) X-ray on open: false for every finish · None: walls drawn out of X-ray · control (stopgap) \(control) · his choice kept")
    }

    // MARK: - RV3: no squish number on the main page

    func testNoSquishNumberOnTheMainPageAfterAPickOrUnderPrisms() async throws {
        let (r, s, m) = try await hisPad(selectTop: true)
        let p = r.project
        let size = CGSize(width: 1032, height: 1376)
        // a plain projection of the model's mm onto his 13" portrait (the tags' placement needs only a point per prism)
        func tags() -> [String] {
            s.prismTags(p, on: .lattice, drilledIn: false, viewport: size, keepOut: [],
                        projector: { CGPoint(x: 316 + CGFloat($0.x) * 4, y: 888 - CGFloat($0.y) * 4) }).map(\.text)
        }
        let top = try XCTUnwrap(p.selection.groups.first { $0.name == "Top" })
        p.selection.setActive(top.id)
        XCTAssertTrue(s.sessionPicked, "premise: his pick of the Top")
        XCTAssertEqual(s.volumes(p, on: .lattice, drilledIn: false).map(\.volume.faceID), [1], "the picked Top's face-prism (after his pick; ★ M1: the lattice face-prism)")
        let afterPick = tags()
        XCTAssertEqual(afterPick, [], "★ no squish number on the main page after his pick (img2's 12.0 mm)")
        m.views.insert(.prisms)
        // ★ RE-PINNED (round 7, M1 — H15'): [Prisms] is every face-prism of the picked group (the fixture's Top face-prism,
        // Face 1), never every pressed face's squish prism
        XCTAssertEqual(Set(s.volumes(p, on: .lattice, drilledIn: false).map(\.volume.faceID)), [1], "[Prisms]: every face-prism of the picked Top")
        let underPrisms = tags()
        XCTAssertEqual(underPrisms, [], "★ …nor under [Prisms]")
        // ★ RED CONTROL: S1b's tags — the Top's squish number on the main page
        s.controlSquishTagsOnMain = true
        let control = tags()
        s.controlSquishTagsOnMain = false
        m.views.remove(.prisms)
        XCTAssertTrue(control.contains("12.0 mm"), "★ RED CONTROL: S1b's tags carry the Top's 12.0 mm (his img2): \(control)")
        print("FLEX-R7V-RV3 squish tags on the main page: after the pick \(afterPick) · under [Prisms] \(underPrisms) · control \(control)")
    }

    // MARK: - RV5: his pause freezes the pose

    func testHisPauseFreezesThePoseUntilHePressesPlay() {
        final class Clock { var t: CFTimeInterval = 100 }
        func paused(control: Bool) -> (FlexibleSquishLoop, Double) {
            let c = Clock()
            let l = FlexibleSquishLoop()
            l.clock = { c.t }
            l.controlPauseMovesPose = control
            l.play()
            c.t += 0.4
            l.toggle()   // his ❚❚
            return (l, l.held)
        }
        let (l, a) = paused(control: false)
        XCTAssertTrue(a > 0.05 && a < 0.95, "premise: paused mid-squeeze (\(a))")
        l.hold(1)
        XCTAssertEqual(l.held, a, accuracy: 1e-12, "★ a stale lattice (his drawing held at full): the pose stays where he paused")
        l.hold(0)
        XCTAssertEqual(l.held, a, accuracy: 1e-12, "★ the sims running (held at rest): the pose stays")
        l.restartFromRest(reduceMotion: false)
        XCTAssertEqual(l.held, a, accuracy: 1e-12, "★ the field landing: the pose stays (the new field binds at it)")
        l.autoPlay(reduceMotion: false)
        l.holdWhileReading(true); l.holdWhileReading(false)
        XCTAssertEqual(l.held, a, accuracy: 1e-12, "★ a new lattice, a reading: the pose stays")
        XCTAssertFalse(l.playing)
        // Play off (his icon): at rest — his answer ("the model sits still AT REST … until he taps Play")
        l.playView = false
        XCTAssertEqual(l.held, 0, accuracy: 1e-12, "Play off: at rest")
        l.playView = true
        l.toggle()
        XCTAssertTrue(l.playing, "★ his ▶ plays")
        // ★ RED CONTROL: R7-V's first build — the automatic holds move the paused pose
        let (c, ca) = paused(control: true)
        c.hold(1)
        XCTAssertEqual(c.held, 1, accuracy: 1e-12, "★ RED CONTROL: the stale lattice's hold moved his paused pose to full")
        XCTAssertFalse(c.playing)
        print(String(format: "FLEX-R7V-RV5 paused at %.2f: holds 1 / 0, a landing, a reading → %.2f · control: hold(1) → %.2f (from %.2f)", a, l.playing ? a : l.held, c.held, ca))
    }

    // MARK: - RV6: the Play icons' status (working / failed)

    func testThePlayIconsSayWhenTheSimsWorkOrFail() {
        let s = FlexibleMainStage()
        XCTAssertEqual(s.playStatus, .idle, "nothing running")
        s.fe.pending = true
        XCTAssertEqual(s.playStatus, .working, "★ the sims running")
        s.fe = FlexibleFEView()
        s.fe.refining = (id: "group-1", step: 3, total: 8)
        XCTAssertEqual(s.playStatus, .working, "★ a refine running")
        s.fe = FlexibleFEView()
        s.fe.failure = "core's words"
        XCTAssertEqual(s.playStatus, .failed, "★ 'Squish sim failed'")
        s.fe = FlexibleFEView()
        s.fe.skipped = ["group-2"]
        XCTAssertEqual(s.playStatus, .failed, "★ 'Group 2's sim failed' (Play all plays the others)")
        s.fe = FlexibleFEView()
        s.fe.refineKept = FlexibleFERefine.notSettled
        XCTAssertEqual(s.playStatus, .failed, "★ 'Refine didn't settle'")
        s.fe = FlexibleFEView()
        // the Settings page: from the line its hidden bar would carry
        XCTAssertEqual(FlexiblePlayStatus.settings(note: FlexibleRowCopy.settingsColumnRunning), .working, "★ Settings: the 3D sim running")
        XCTAssertEqual(FlexiblePlayStatus.settings(note: FlexibleRowCopy.settingsColumnFailed), .failed, "★ Settings: the 3D sim failed")
        for idle in [nil, FlexibleRowCopy.settingsSimNote, FlexibleRowCopy.settingsColumnEdited, FlexibleRowCopy.settingsColumnNoLattice] {
            XCTAssertEqual(FlexiblePlayStatus.settings(note: idle), .idle, "Settings: \(idle ?? "no line")")
        }
    }

    // MARK: - RV8: every Settings player line has a shorter form

    func testEverySettingsPlayerLineHasShorterForms() {
        for n in [FlexibleRowCopy.settingsSimNote, FlexibleRowCopy.settingsColumnEdited, FlexibleRowCopy.settingsColumnNoLattice,
                  FlexibleRowCopy.settingsColumnRunning, FlexibleRowCopy.settingsColumnFailed] {
            let f = FlexibleRowCopy.shortForms(n)
            XCTAssertFalse(f.isEmpty, "★ '\(n)' has a shorter form")
            var last = n.count
            for x in f {
                XCTAssertLessThan(x.count, last, "'\(x)' is shorter than the form before it")
                XCTAssertFalse(x.hasSuffix("…"), "a short form is whole words, never a cut")
                last = x.count
            }
            XCTAssertLessThanOrEqual(f.last?.count ?? 99, 14, "★ the shortest fits the narrowest note ('\(f.last ?? "")')")
        }
        print("FLEX-R7V-RV8 " + [FlexibleRowCopy.settingsColumnNoLattice, FlexibleRowCopy.settingsColumnEdited]
            .map { "\($0) → \(FlexibleRowCopy.shortForms($0))" }.joined(separator: " · "))
    }
}
#endif
