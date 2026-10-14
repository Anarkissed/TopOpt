// FlexibleRound7ViewsTests — round 7, batch R7-V (2026-10-14): the views on both Flexible pages. Written BEFORE the code
// (the stubs' red run: docs/handoffs/evidence/2026-09-29-flexible-screens/round7/batch_v/r7v_red_run.txt), each with its
// RED control run inside the test. On HIS projects, restored as he saved them (A1_0003 = his img1–4 pad; his 0004 for the
// sims, FlexibleSquishVerifyGTests' fixture). His words (2026-10-14, binding — r7/tasks.md):
//   V-2a "All view buttons should be icons - never full words. Remove the two full worded view icons." + his answer: no
//        Selections role colours on the main page's model; a group's prism / number only after a pick.
//   V-2b "add a Play button icon … When it is on the simulation plays - otherwise, remove the play-bar" + his answer: Play
//        OFF on open, the model AT REST until he taps Play.
//   V-2c "When the pause is selected … any action taken anywhere automatically re-starts the simulation. Only by pressing
//        Play should the sim actually restart."
//   V-2d "Please re-add the x-ray view icon." (step 1: X-ray off by default is the opaque model)
//   V-4c "make the heatmap view actually show/hide the actual heatmap on the model" + his answer: tap = the current
//        group, hold 3 s = every group, tap again = hide (Settings only)
//   V-4i "a 'bend' icon view … the entire group's bend at the full depth - all together" + his answer: every face of the
//        group bent at once, at full depth, frozen.
#if canImport(MetalKit)
import XCTest
import Combine
import simd
@testable import TopOptFlows
@testable import TopOptKit

@MainActor
final class FlexibleRound7ViewsTests: XCTestCase {

    final class Box<T>: @unchecked Sendable {
        private let lock = NSLock()
        private var v: T
        init(_ v: T) { self.v = v }
        var value: T {
            get { lock.lock(); defer { lock.unlock() }; return v }
            set { lock.lock(); v = newValue; lock.unlock() }
        }
    }

    func pump(_ seconds: Double) {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end { _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.02)) }
    }

    /// A main stage over HIS pad (A1_0003 as he saved it), the scene, stacks and designs settled, the page shown.
    func hisPad(selectTop: Bool = false, show: Bool = true) async throws -> (FlexibleHisProject.Restored, FlexibleMainStage, FlexibleStageModel) {
        let r = try FlexiblePressFixtures.a1Project(3, self)
        if selectTop, let top = r.project.selection.groups.first(where: { $0.name == "Top" }) { r.project.selection.setActive(top.id) }
        let s = FlexibleMainStage()
        s.reduceMotion = { true }
        let m = s.model(for: r.project, materialsPath: FlexibleHisProject.materialsPath, stampsPath: FlexibleHisProject.stampsPath, persist: {})
        addTeardownBlock { @MainActor in await m.waitForIdle() }
        m.openScene()
        try await FlexibleSquishFixture.settle(m, "his pad")
        if show { s.apply(r.project, owned: true, pageUp: false) }   // (the main page shown: it builds and runs the sims itself)
        return (r, s, m)
    }

    /// His project through Save & Exit on a main stage until every sim has landed (FlexibleSquishVerifyGTests.stage, with
    /// the Play view given: `play` inserts it as the model is made — the fixtures' "insert .play").
    func simsLanded(split: Bool = false, play: Bool, failing: Set<String> = [], failDelayS: Double = 0,
                    configure: (FlexibleMainStage) -> Void = { _ in },
                    sample: ((FlexibleMainStage, FlexibleStageModel) -> Void)? = nil) async throws
        -> (FlexibleHisProject.Restored, FlexibleMainStage, FlexibleStageModel) {
        let r = try FlexibleHisProject.restore(nil)
        addTeardownBlock { r.cleanup() }
        let stage = FlexibleMainStage()
        stage.reduceMotion = { false }
        configure(stage)
        let m = stage.model(for: r.project, materialsPath: FlexibleHisProject.materialsPath,
                            stampsPath: FlexibleHisProject.stampsPath, persist: {})
        addTeardownBlock { @MainActor in await m.waitForIdle() }
        if play { m.views.insert(.play) }
        m.keepFERequest = true
        m.squishSolver.controlFailSimIDs = failing
        m.squishSolver.controlFailDelayS = failDelayS
        m.openScene()
        try await FlexibleSquishFixture.settle(m, "his")
        if split {
            m.edit { s in
                _ = FlexibleSqueezeGroups.newGroup(with: 3, in: &s)
                FlexibleSqueezeGroups.move(5, to: FlexibleSqueezeGroups.group(of: 3, in: s)!.id, in: &s)
            }
            try await FlexibleSquishFixture.settle(m, "his split")
        }
        stage.didExitSettings()
        stage.apply(r.project, owned: true, pageUp: false)
        try await landed(stage, m, sample: sample)
        return (r, stage, m)
    }

    /// Wait (driven only by the page's own debounced refresh) until a fresh lattice is drawn and every sim landed.
    func landed(_ s: FlexibleMainStage, _ m: FlexibleStageModel, after generation: Int? = nil,
                sample: ((FlexibleMainStage, FlexibleStageModel) -> Void)? = nil) async throws {
        let start = Date()
        while Date().timeIntervalSince(start) < 400 {
            sample?(s, m)
            if let l = m.lattice, !m.latticeIsStale, !m.latticeBuilding, generation.map({ l.generation > $0 }) ?? true,
               !m.squish.isEmpty, !m.squish.values.contains(.pending), m.squishSolver.isIdle { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        for _ in 0..<40 { sample?(s, m); try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertFalse(m.squish.isEmpty, "the sims ran")
    }

    /// #354's Selections role colours as the workspace composes them (WorkspacePlaceholder.roleTints): each group's tint on
    /// every face it holds.
    static func roleTints(_ p: ProjectModel) -> [FaceID: SIMD4<Float>] {
        var out: [FaceID: SIMD4<Float>] = [:]
        for g in p.selection.groups where !p.groupView.isHidden(g.id) {
            let c = p.force.tint(for: g)
            for f in Set(g.faces).union(p.latticeRegionCoveredFaces(g)) { out[f] = SIMD4<Float>(Float(c.r), Float(c.g), Float(c.b), 1) }
        }
        return out
    }
    static func rgba(_ t: [Float], _ v: Int) -> SIMD4<Float> { SIMD4(t[v * 8], t[v * 8 + 1], t[v * 8 + 2], t[v * 8 + 3]) }
    static func inked(_ t: [Float], _ ink: Set<SIMD4<Float>>) -> Int { (0..<(t.count / 8)).filter { ink.contains(rgba(t, $0)) }.count }

    // MARK: - V-2a: no role colour on the main page's model, whatever roles #354 hands over

    func testTheMainPageModelWearsNoRoleColourWhateverRolesAreHandedOver() async throws {
        let (r, s, m) = try await hisPad()
        let p = r.project
        m.selectedRegion = nil
        s.stress = false
        let roles = Self.roleTints(p)
        XCTAssertFalse(roles.isEmpty, "premise: #354 has role colours for his groups (H4's roleTints)")
        let roleInk = Set(roles.values)
        let marks: Set<SIMD4<Float>> = [FlexibleColours.restingFace, FlexibleColours.loadedFace, FlexibleColours.selectedFace, FlexibleColours.linkedEnd]
        var lines: [String] = []
        // a face Flexible does not tint (his resting bottom taken out of Settings, the Bottom still anchoring it)
        m.edit({ st in st.removeFace(0) }, recompute: false)
        for (name, lattice, heat, xray) in [("model", false, false, false), ("model, heat", false, true, false),
                                             ("X-ray, lattice", true, false, true), ("X-ray, lattice, heat", true, true, true)] {
            s.latticeOn = lattice; s.heat = heat; s.xrayOn = xray
            s.refresh()
            var evaluated = 0
            let t = try XCTUnwrap(s.tints(p, on: .lattice, roles: { evaluated += 1; return roles }(), stress: nil))
            let roleN = Self.inked(t, roleInk), markN = Self.inked(try XCTUnwrap(s.channels?.tints), marks)
            XCTAssertEqual(roleN, 0, "★ \(name): no Selections role colour on the main page's model")
            XCTAssertEqual(markN, 0, "★ \(name): no pressed green, resting cyan, selected face or linked end")
            XCTAssertEqual(evaluated, 0, "★ \(name): #354's roles are never even evaluated on the Flexible stage")
            // ★ RED CONTROL: the roles and Flexible's marks passed through (batch V's toggles unticked) — the probe sees them
            s.controlRolesOnMain = true
            s.refresh()
            let tc = try XCTUnwrap(s.tints(p, on: .lattice, roles: roles, stress: nil))
            let roleC = Self.inked(tc, roleInk), markC = Self.inked(try XCTUnwrap(s.channels?.tints), marks)
            s.controlRolesOnMain = false
            s.refresh()
            XCTAssertGreaterThan(roleC + markC, 0, "★ RED CONTROL (\(name)): roles and marks passed through are found")
            lines.append("\(name): role-coloured vertices \(roleN), marks \(markN) · control \(roleC) / \(markC)")
        }
        // a Play-all turn's tints too (the renderer swaps them in with each group's field)
        for (id, t) in s.playAllBaseTints(m, scaleMM: 1) { XCTAssertEqual(Self.inked(t, marks), 0, "\(id)'s turn: no mark") }
        print("FLEX-R7V-2a roles\n  " + lines.joined(separator: "\n  "))
    }

    // MARK: - V-2a: a group's prism and number only after a pick

    func testAGroupsPrismShowsOnlyAfterHisPickNeverOnOpenNorForAPendingGroup() async throws {
        let (r, s, _) = try await hisPad(selectTop: true)
        let p = r.project
        func prisms() -> [Int] { s.volumes(p, on: .lattice, drilledIn: false).map(\.volume.faceID) }
        XCTAssertEqual(p.selection.activeGroup?.name, "Top", "premise: the Top active as the project opens")
        XCTAssertFalse(s.sessionPicked)
        XCTAssertEqual(prisms(), [], "★ on open: no prism (the Top is active, he has not picked it)")
        // ★ RED CONTROL: the prism on open (S1b's rule — batch V's "Prism after a pick" unticked)
        s.controlPrismOnOpen = true
        s.volumesCache = nil
        let control = prisms()
        s.controlPrismOnOpen = false
        s.volumesCache = nil
        XCTAssertEqual(control, [1], "★ RED CONTROL: S1b drew the active Top's prism on open")
        // his pick (a Selections write — re-tapping the active row is #354's equal write)
        let top = try XCTUnwrap(p.selection.groups.first { $0.name == "Top" })
        p.selection.setActive(top.id)
        XCTAssertTrue(s.sessionPicked)
        XCTAssertEqual(prisms(), [1], "★ after his pick: the Top's prism")
        let groupC = try XCTUnwrap(p.selection.groups.first { $0.name == "Group C" })
        XCTAssertTrue(p.force.kind(for: groupC.id).isPending, "premise: Group C is Pending")
        p.selection.setActive(groupC.id)
        XCTAssertEqual(prisms(), [], "★ a Pending group: none")
        print("FLEX-R7V-2a prisms: on open [] (control \(control)) · after the pick [1] · Pending []")
    }

    // MARK: - V-2b: Play — off on open, the bar only with Play, Play beside every view

    func testPlayIsOffOnOpenAndOnlyPlayShowsTheBarAndPlays() async throws {
        let (r, s, m) = try await simsLanded(play: false)
        XCTAssertFalse(m.views.contains(.play), "★ Play OFF on open")
        XCTAssertTrue(s.visible && m.lattice != nil && !m.latticeIsStale, "premise: a fresh lattice on the shown page")
        XCTAssertFalse(s.playerShown, "★ Play off: no bar")
        XCTAssertFalse(s.loop.playing, "★ Play off: the loop never plays after the field lands")
        XCTAssertEqual(s.loop.held, 0, accuracy: 1e-12, "★ …it sits AT REST (his answer)")
        XCTAssertEqual(s.dentScale(r.project, on: .lattice), 0, accuracy: 1e-9, "…the dent's scale at rest")
        // ★ RED CONTROL: the bar's old gate (no view in it) shows it with Play off
        s.controlPlayerIgnoresPlayView = true
        let controlShown = s.playerShown
        s.controlPlayerIgnoresPlayView = false
        XCTAssertTrue(controlShown, "★ RED CONTROL: without the Play view in its gate the bar is back")
        // his tap on Play
        s.togglePlay()
        XCTAssertTrue(m.views.contains(.play))
        XCTAssertTrue(s.playerShown, "★ Play on: the bar")
        XCTAssertTrue(s.loop.playing, "★ Play on: it plays")
        // Play combines with every view: none of them moves it, it moves none of them
        let before = (s.heat, s.stress, s.latticeOn, m.views.contains(.prisms), s.xrayOn)
        s.toggleHeat(); s.toggleHeat()
        s.toggleStress(); s.toggleStress()
        s.toggleLattice(); s.toggleLattice()
        s.togglePrisms(); s.togglePrisms()
        s.toggleXray(); s.toggleXray()
        XCTAssertTrue(m.views.contains(.play), "★ no other view turns Play off")
        let views = (s.heat, s.stress, s.latticeOn, m.views.contains(.prisms))
        s.togglePlay()
        XCTAssertFalse(m.views.contains(.play))
        XCTAssertFalse(s.playerShown, "Play off again: no bar")
        XCTAssertFalse(s.loop.playing)
        XCTAssertEqual(s.loop.held, 0, accuracy: 1e-12, "…at rest")
        XCTAssertEqual(views.0, s.heat); XCTAssertEqual(views.1, s.stress); XCTAssertEqual(views.2, s.latticeOn)
        XCTAssertEqual(views.3, m.views.contains(.prisms), "★ Play moves no other view")
        print("FLEX-R7V-2b Play: off on open — shown \(false) playing false held 0 (control: shown \(controlShown)) · on: shown true playing true · "
              + "views before \(before) after \(views)")
    }

    // MARK: - V-2c: his pause holds across an edit, a Stress retry and Save & Exit — until he presses Play

    func testHisPauseHoldsAcrossAnEditUntilHePressesPlay() async throws {
        func run(control: Bool) async throws -> (played: [String], playsAfterHisPlay: Bool) {
            let played = Box<[String]>([])
            var watch: AnyCancellable?
            defer { watch?.cancel() }
            let (_, s, m) = try await simsLanded(split: true, play: true)
            XCTAssertTrue(s.loop.playing, "premise: Play on, the sims landed — it plays")
            s.loop.controlIgnoreHisPause = control
            s.loop.toggle()   // ★ HIS pause (the player's ❚❚)
            XCTAssertFalse(s.loop.playing)
            if !control { XCTAssertTrue(s.loop.pausedByHim, "his pause is latched") }
            watch = s.loop.$playing.sink { now in if now { played.value.append("played") } }
            // (1) an edit: Group 1's weight → stale → rebuild → the sims pending → landing (the page's own refresh)
            let g1 = try XCTUnwrap(m.squeezeGroups.first)
            let gen = m.lattice?.generation ?? -1
            let kg = m.groupForce(g1)?.upperBound ?? 10
            m.setGroupForce(g1.id, kg: kg + 3)
            try await landed(s, m, after: gen)
            // (2) Save & Exit after a change
            let gen2 = m.lattice?.generation ?? -1
            m.setGroupForce(g1.id, kg: kg + 1)
            s.didExitSettings()
            try await landed(s, m, after: gen2)
            // (3) a legend's reading starting and ending
            s.noteDrill(true); s.noteDrill(false)
            pump(0.3)
            let out = played.value
            // only HIS Play restarts it
            s.loop.controlIgnoreHisPause = false
            s.loop.toggle()
            return (out, s.loop.playing)
        }
        let fixed = try await run(control: false)
        XCTAssertTrue(fixed.played.isEmpty, "★ his pause held across the edit, the landing, Save & Exit and a reading: \(fixed.played)")
        XCTAssertTrue(fixed.playsAfterHisPlay, "★ …until he pressed Play")
        // ★ RED CONTROL: the automatic paths ignoring his pause (rounds 3–6) — it plays again once the sims land
        let red = try await run(control: true)
        XCTAssertFalse(red.played.isEmpty, "★ RED CONTROL: the landing restarted the sim over his pause")
        print("FLEX-R7V-2c pause: plays while paused \(fixed.played.count) (control \(red.played.count)) · his Play plays \(fixed.playsAfterHisPlay)")
    }

    /// The Stress retry while paused: a failed sim re-run lands — it must not restart the loop.
    func testAStressRetryLandingNeverUndoesHisPause() async throws {
        let (_, s, m) = try await simsLanded(play: true, failing: ["group-1"], failDelayS: 1)
        XCTAssertNotNil(m.squish["group-1"]?.failure, "premise: the only sim failed (the column squish plays)")
        XCTAssertTrue(s.loop.playing, "premise: the fallback plays")
        s.loop.toggle()
        let played = Box(0)
        let watch = s.loop.$playing.sink { if $0 { played.value += 1 } }
        defer { watch.cancel() }
        m.squishSolver.controlFailSimIDs = []
        s.stress = true
        s.retryStress()
        try await landed(s, m)
        try await FlexibleHisProject.waitFor(120, "the retried sim") { m.squish["group-1"]?.field != nil }
        for _ in 0..<40 { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertEqual(played.value, 0, "★ the retried sim landed and his pause held")
        XCTAssertFalse(s.loop.playing)
        print("FLEX-R7V-2c Stress retry: landed \(m.squish["group-1"]?.field != nil) · plays while paused \(played.value)")
    }

    // MARK: - V-2d step 1: the X-ray icon back, X-ray off by default (the opaque model)

    func testXrayIsItsOwnIconOffByDefaultAndTheDefaultIsTheOpaqueModel() async throws {
        XCTAssertEqual(FlexibleMainViewToggles.buttons, 6, "★ Heat · Stress · Lattice · Prisms · X-ray · Play")
        let (r, s, m) = try await hisPad()
        let p = r.project
        // ★ RE-PINNED (R7-V review — the verify on his pad, saved Finish None: X-ray off for every finish opened it as an opaque
        // block with no lattice): X-ray's default follows the finish — OFF for Covered (pinned here), on for None / Rim / Skin
        // (FlexibleRound7ViewsTests.testXrayOpensOnForAFinishThatShowsTheLatticeAndOffForCovered)
        m.edit { $0.finish = FlexibleFinish.covered.rawValue }
        try await FlexibleSquishFixture.settle(m, "his pad, Covered")
        s.didExitSettings()
        try await FlexibleHisProject.waitFor(240, "the lattice") { m.lattice != nil && !m.latticeBuilding && !m.latticeIsStale }
        s.refresh()
        XCTAssertFalse(s.xrayOn, "★ X-ray OFF by default")
        XCTAssertTrue(s.heat && s.latticeShown, "premise: Heat and the Lattice view on (the defaults)")
        XCTAssertFalse(s.xray, "★ Heat and the lattice no longer force X-ray (C2 and M6 reversed)")
        XCTAssertEqual(s.bodyAlpha(p, on: .lattice), 1, "★ the opaque model")
        XCTAssertEqual(s.layer(p, stage: .lattice, pageUp: false)?.hidden, true, "★ no wall drawn through an opaque body")
        // ★ RED CONTROL: C2 + M6's rule (the Lattice view IS the X-ray; the dent view forces it) — the 0.04 ghost
        s.controlXrayIsLatticeView = true
        let controlAlpha = s.bodyAlpha(p, on: .lattice)
        s.controlXrayIsLatticeView = false
        XCTAssertEqual(controlAlpha, FlexibleStagePage.xrayBodyAlpha, "★ RED CONTROL: C2 / M6 ghosted the body with Heat and the Lattice on")
        // his X-ray icon
        s.toggleXray()
        XCTAssertTrue(s.xrayOn && s.xray)
        XCTAssertEqual(s.bodyAlpha(p, on: .lattice), FlexibleStagePage.xrayBodyAlpha, "X-ray on: the ghost")
        XCTAssertEqual(s.layer(p, stage: .lattice, pageUp: false)?.hidden, false, "X-ray on: the walls drawn inside it")
        // Heat never moves X-ray
        s.toggleHeat(); XCTAssertTrue(s.xrayOn); s.toggleHeat(); XCTAssertTrue(s.xrayOn)
        s.toggleXray()
        s.toggleHeat(); XCTAssertFalse(s.xrayOn, "★ Heat never turns X-ray on"); s.toggleHeat()
        XCTAssertEqual(s.bodyAlpha(p, on: .lattice), 1)
        // a view that needs X-ray turns it on itself: [Prisms] (a prism sits inside the part)
        s.togglePrisms()
        XCTAssertTrue(s.xrayOn, "★ [Prisms] turns X-ray on itself")
        s.togglePrisms(); s.toggleXray()
        XCTAssertFalse(m.views.contains(.play), "nothing here touched Play")
        print("FLEX-R7V-2d xray: default body alpha 1 walls hidden (control \(controlAlpha ?? -1)) · X-ray on alpha \(FlexibleStagePage.xrayBodyAlpha)")
    }

    // MARK: - V-4c: the Settings page's Heat view — the current group's, every group's, or none

    func testTheSettingsHeatShowsTheCurrentGroupEveryGroupOrNone() async throws {
        addTeardownBlock { @MainActor in FlexibleStagePage.controlHeatAlwaysOn = false }
        let (_, _, m) = try await hisPad(show: false)
        XCTAssertEqual(m.squeezeGroups.map(\.regions), [[1], [4, 2], [3, 5]], "premise: his three groups")
        let overlay = try XCTUnwrap(FlexiblePageChannels.overlay(model: m))
        let g2 = m.squeezeGroups[1]
        m.rail = .group(g2.id)
        m.select(4)
        XCTAssertEqual(m.playingGroup?.id, g2.id, "premise: Group 2 open")
        /// The pressed regions whose map carries a heat colour (opaque, flags.y) in the page's composed tints.
        func heated(_ views: FlexibleStageViews) throws -> [Int] {
            let t = try XCTUnwrap(FlexibleStagePage.composeTints(model: m, overlay: overlay, views: views).tints)
            return m.settings.loadedFaces.map(\.faceRegionID).filter { r in
                guard let key = m.key(r), let start = overlay.flatStart[key], let n = m.stacks[key]?.columns.count else { return false }
                return (start..<(start + 6 * n)).contains { v in v * 8 + 5 < t.count && t[v * 8 + 5] > 0.5 && t[v * 8 + 3] > 0 }
            }.sorted()
        }
        XCTAssertEqual(FlexibleStageViews().heatScope, .group, "the page opens with the current group's heat (today's look)")
        let off = try heated([.heatOff]), group = try heated([]), all = try heated([.heatAll])
        XCTAssertEqual(off, [], "★ off: no heat colour on any map")
        XCTAssertEqual(group, [2, 4], "★ the current group (Group 2: faces 4 and 2) only")
        XCTAssertEqual(all, [1, 2, 3, 4, 5], "★ his hold: every group's")
        // the tap / hold rule
        var v = FlexibleStageViews()
        v.heatTapped(); XCTAssertEqual(v.heatScope, .off, "a tap on the shown heat hides it")
        v.heatTapped(); XCTAssertEqual(v.heatScope, .group, "a tap on hidden heat: the current group's")
        v.heatHeld(); XCTAssertEqual(v.heatScope, .all, "a 3 s hold: every group's")
        v.heatTapped(); XCTAssertEqual(v.heatScope, .off, "a tap on every group's heat hides it")
        // ★ RED CONTROL: today's composeTints (heat always on, every face) — Face 1's map coloured under .group and .off
        FlexibleStagePage.controlHeatAlwaysOn = true
        let cOff = try heated([.heatOff]), cGroup = try heated([])
        FlexibleStagePage.controlHeatAlwaysOn = false
        XCTAssertTrue(cOff.contains(1) && cGroup.contains(1), "★ RED CONTROL: heat always on colours Face 1 under off and the group")
        // the added layer removed: no group glass over a heated face (glass only where heat is hidden)
        m.views = [.groups]
        let heatedAll = FlexibleStageHeat.shown(model: m, views: m.views)
        let glass = FlexibleStageVolumes.items(model: m, k: 1, part: m.project.viewerMesh, heated: heatedAll)
            .filter(\.surfaceOnly).map(\.volume.faceID)
        XCTAssertTrue(Set(glass).isDisjoint(with: heatedAll), "★ no glass over a heated face: glass \(glass) heated \(heatedAll.sorted())")
        m.views = [.groups, .heatOff]
        let glassOff = FlexibleStageVolumes.items(model: m, k: 1, part: m.project.viewerMesh,
                                                  heated: FlexibleStageHeat.shown(model: m, views: m.views)).filter(\.surfaceOnly).map(\.volume.faceID)
        XCTAssertFalse(glassOff.isEmpty, "with the heat hidden, the groups' glass shows")
        m.views = []
        print("FLEX-R7V-4c heat (Group 2 open): off \(off) · group \(group) · all \(all) · control off \(cOff) group \(cGroup) · "
              + "glass with every heat \(glass.sorted()) · heat hidden \(glassOff.sorted())")
    }

    // MARK: - V-4i: Bend — the current group at full depth, every face at once, frozen

    func testTheBendViewHoldsTheWholeGroupAtFullDepth() async throws {
        let (_, _, m) = try await hisPad(show: false)   // (the Settings page's own pipeline: no main page building beside it)
        _ = try await FlexibleSquishFixture.build(m, "his pad")
        let g2 = try XCTUnwrap(m.squeezeGroups.first { $0.regions == [4, 2] }, "his two-face Group 2")
        m.rail = .group(g2.id)
        m.select(4)
        try await FlexibleSquishFixture.solve(m, first: FlexibleSim.groupID(g2.number), "his pad")
        let edge = try XCTUnwrap(FlexibleSettingsSquish.overlayEdge(model: m), "premise: Group 2's field is current (the 3D sim)")
        let overlay = try XCTUnwrap(FlexiblePageChannels.overlay(model: m, maxEdgeMM: edge))
        var cache: (key: String, dents: [Float])?
        let c = FlexibleStagePage.composeTints(model: m, overlay: overlay, views: [.bend])
        let sq = FlexibleSettingsSquish.shown(model: m, overlay: overlay, channels: c, feCache: &cache)
        XCTAssertTrue(sq.fe, "premise: the whole part moves by the group's field")
        let d = try XCTUnwrap(sq.dents)
        let k = sq.exaggeration
        // ★ BEND: the loop is not playing (Play off) and the scale is k × 1 — whatever the loop's amount
        let loop = FlexibleSquishLoop()
        loop.playView = false
        loop.autoPlay(reduceMotion: false)
        XCTAssertFalse(loop.playing, "★ Bend (Play off): the loop does not play")
        let mid = 0.37
        XCTAssertEqual(FlexibleStagePage.dentScale(views: [.bend], exaggeration: k, amount: mid), Float(k), "★ Bend: k × 1, frozen")
        XCTAssertEqual(FlexibleStagePage.dentScale(views: [.bend, .heatOff], exaggeration: k, amount: 0), Float(k))
        // every face of the group moves — both faces of the pinch (their maps) — and the rest of the part with them (the FE
        // field moves the whole model: here the part's own vertices on the Top, which Group 2 does not press)
        let mesh = overlay.mesh
        func movedMap(_ r: Int) -> Float {
            guard let key = m.key(r), let start = overlay.flatStart[key], let n = m.stacks[key]?.columns.count else { return 0 }
            return (start..<min(start + 6 * n, d.count / 3)).map { v in simd_length(SIMD3(d[3 * v], d[3 * v + 1], d[3 * v + 2])) }.max() ?? 0
        }
        let topZ = (0..<overlay.partFlatVertices).map { mesh.flat.positions[3 * $0 + 2] }.max() ?? 0
        let side = (0..<overlay.partFlatVertices).filter { abs(mesh.flat.positions[3 * $0 + 2] - topZ) < 1e-3 }
            .map { v in simd_length(SIMD3(d[3 * v], d[3 * v + 1], d[3 * v + 2])) }.max() ?? 0
        let f4 = movedMap(4), f2 = movedMap(2)
        XCTAssertGreaterThan(f4, 1e-4, "★ face 4 of the pinch bends")
        XCTAssertGreaterThan(f2, 1e-4, "★ …and face 2, its opposing side")
        XCTAssertGreaterThan(side, 1e-5, "★ the rest of the part moves with them (the 3D field: the whole model)")
        // ★ RED CONTROL: without Bend the scale follows the loop (below k mid-cycle)
        XCTAssertLessThan(FlexibleStagePage.dentScale(views: [], exaggeration: k, amount: mid), Float(k), "★ RED CONTROL: no Bend, k × amount")
        // a stale lattice: the column dent of every face of the group, at k
        let f = try XCTUnwrap(m.settings.face(4))
        m.edit { s in var g = f; g.deepestMM = f.deepestMM + 1; s.setFace(g) }
        try await FlexibleSquishFixture.settle(m, "edited")
        XCTAssertTrue(m.latticeIsStale, "premise: the edit made the lattice stale")
        let o2 = try XCTUnwrap(FlexiblePageChannels.overlay(model: m))
        var cache2: (key: String, dents: [Float])?
        let c2 = FlexibleStagePage.composeTints(model: m, overlay: o2, views: [.bend])
        let sq2 = FlexibleSettingsSquish.shown(model: m, overlay: o2, channels: c2, feCache: &cache2)
        XCTAssertFalse(sq2.fe, "stale: the column preview")
        let d2 = try XCTUnwrap(sq2.dents)
        func movedCol(_ r: Int) -> Float {
            guard let key = m.key(r), let start = o2.flatStart[key], let n = m.stacks[key]?.columns.count else { return 0 }
            return (start..<(start + 6 * n)).map { v in simd_length(SIMD3(d2[3 * v], d2[3 * v + 1], d2[3 * v + 2])) }.max() ?? 0
        }
        XCTAssertGreaterThan(movedCol(4), 1e-4, "★ stale: face 4's column dent")
        XCTAssertGreaterThan(movedCol(2), 1e-4, "★ …and face 2's (every face of the group)")
        XCTAssertEqual(movedCol(1), 0, "another group's face stands still")
        XCTAssertEqual(FlexibleStagePage.dentScale(views: [.bend], exaggeration: sq2.exaggeration, amount: 0), Float(sq2.exaggeration), "…at k")
        print(String(format: "FLEX-R7V-4i bend: k %.2f · face 4 %.4f face 2 %.4f the Top's part vertices %.5f mm/k · control (no Bend, amount %.2f) scale %.2f · stale columns face 4 %.3f face 2 %.3f",
                     k, f4, f2, side, mid, FlexibleStagePage.dentScale(views: [], exaggeration: k, amount: mid), movedCol(4), movedCol(2)))
    }
}
#endif
