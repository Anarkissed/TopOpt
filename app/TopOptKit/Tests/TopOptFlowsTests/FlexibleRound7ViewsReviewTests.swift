// FlexibleRound7ViewsReviewTests — round 7 batch R7-V's REVIEW (2026-10-14): the verify's confirmed findings on the views,
// each a test written BEFORE its fix (the stubs' red run: round7/batch_v/r7v_review_red_run.txt), with its RED control run
// inside. Part of FlexibleRound7ViewsTests (its fixtures: HIS pad, A1_0003 as he saved it — Finish None).
//   RV1 (major) his None pad opened as an opaque block with NO lattice (X-ray off for every finish): X-ray's DEFAULT follows
//       the finish — on for None / Rim / Skin, off for Covered — and his choice wins once made. RED `controlXrayOffOnOpen`.
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

    // MARK: - RV1: X-ray's default follows the finish; his choice wins

    func testXrayOpensOnForAFinishThatShowsTheLatticeAndOffForCovered() async throws {
        let (r, s, m) = try await hisPad()
        let p = r.project
        XCTAssertEqual(m.settings.finishMode, .none, "premise: his pad is saved with Finish None (pure lattice)")
        s.didExitSettings()
        try await FlexibleHisProject.waitFor(240, "the lattice") { m.lattice != nil && !m.latticeBuilding && !m.latticeIsStale }
        s.refresh()
        XCTAssertTrue(s.xrayOn, "★ Finish None: X-ray ON as the page opens — his lattice shows (until R7-X's printed view)")
        XCTAssertEqual(s.bodyAlpha(p, on: .lattice), FlexibleStagePage.xrayBodyAlpha, "★ the ghost")
        XCTAssertEqual(s.layer(p, stage: .lattice, pageUp: false)?.hidden, false, "★ the walls are drawn")
        XCTAssertTrue(s.wallsShown, "★ the Lattice icon is lit: the lattice is on and seen")
        // ★ RED CONTROL: R7-V's first build — X-ray off for every finish: the opaque block, no wall, the Lattice icon unlit
        s.controlXrayOffOnOpen = true
        s.refresh()
        let control = (xray: s.xrayOn, hidden: s.layer(p, stage: .lattice, pageUp: false)?.hidden, lit: s.wallsShown)
        s.controlXrayOffOnOpen = false
        s.refresh()
        XCTAssertFalse(control.xray, "★ RED CONTROL: X-ray off on his None pad")
        XCTAssertEqual(control.hidden, true, "★ RED CONTROL: …no wall drawn (the verify's opaque block)")
        XCTAssertFalse(control.lit, "★ RED CONTROL: …and the Lattice icon unlit")
        // his tap wins
        s.toggleXray()
        XCTAssertFalse(s.xrayOn, "his X-ray tap: off")
        XCTAssertEqual(s.bodyAlpha(p, on: .lattice), 1, "the opaque model")
        // Covered: the opaque model IS the print — X-ray off by default
        s.xrayChoice = [:]
        m.edit({ $0.finish = FlexibleFinish.covered.rawValue }, recompute: false)
        XCTAssertFalse(s.xrayOn, "★ Finish Covered: X-ray OFF by default (the skin hides the lattice)")
        XCTAssertEqual(s.bodyAlpha(p, on: .lattice), 1, "★ …the opaque model")
        // Rim and Skin show their lattice in the print: on
        for f in [FlexibleFinish.rim, .skin] {
            m.edit({ $0.finish = f.rawValue }, recompute: false)
            XCTAssertTrue(s.xrayOn, "★ Finish \(f.rawValue): X-ray on by default")
        }
        // his choice outlives a finish change
        s.toggleXray()
        XCTAssertFalse(s.xrayOn)
        m.edit({ $0.finish = FlexibleFinish.none.rawValue }, recompute: false)
        XCTAssertFalse(s.xrayOn, "★ his X-ray choice, not the finish's default")
        print("FLEX-R7V-RV1 xray on open: None \(true) walls drawn · control (first build) xray \(control.xray) hidden \(control.hidden ?? false) lit \(control.lit) · Covered off · Rim/Skin on · his choice kept")
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
