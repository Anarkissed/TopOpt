// FlexibleMainPageRound4VerifyTests — the verification of round 4 batch C2 (task
// 2026-09-29-flexible-screens): each finding the verifier confirmed, pinned, and written RED FIRST
// against C2's commit (38963bbe). His rules they hold the page to:
//   answer 2: "when Lattice Ready shows, tapping it should send to Core and the export path"
//   "blockers surface at once as a pop-up that SELECTS the face and says exactly what to choose,
//    with 1-3 fix buttons"; "the group is the one source of truth" (a weight he typed reaches
//    the job); "legends never cover buttons"; "only what is necessary".
//
// Each comparison carries a positive control that goes RED on the rule it replaces.
import XCTest
import simd
@testable import TopOptFlows
@testable import TopOptKit
import TopOptDesign

final class FlexibleMainPageRound4VerifyTests: XCTestCase {

    // MARK: helpers

    @MainActor
    private func padStage(_ material: String = "varioshore_tpu") async throws -> (ProjectModel, FlexibleMainStage, FlexibleStageModel, Int) {
        let pm = try FlexibleHisProject.padProject(FlexibleStageSettings(materialID: material))
        let stage = FlexibleMainStage()
        stage.reduceMotion = { true }
        let m = stage.model(for: pm, materialsPath: FlexibleHisProject.materialsPath, stampsPath: nil, persist: {})
        addTeardownBlock { @MainActor in await m.waitForIdle() }
        stage.apply(pm, owned: true, pageUp: false)
        try await FlexibleHisProject.waitFor(60, "the pad's scene") { m.sceneState == .ready }
        await m.waitForIdle()
        stage.refresh()
        let top = FlexibleHisProject.topFace(try XCTUnwrap(pm.viewerMesh))
        return (pm, stage, m, top)
    }

    /// His project restored, on the Lattice stage, `tweak` applied in Settings, Save & Exit, the
    /// lattice built.
    @MainActor
    private func hisBuilt(before: (ProjectModel) throws -> Void = { _ in }, _ tweak: (FlexibleStageModel) -> Void = { _ in }) async throws
        -> (FlexibleHisProject.Restored, FlexibleMainStage, FlexibleStageModel) {
        let r = try FlexibleHisProject.restore()
        addTeardownBlock { r.cleanup() }
        try before(r.project)   // (a main-page edit, before the stage opens)
        let stage = FlexibleMainStage()
        stage.reduceMotion = { true }
        let m = stage.model(for: r.project, materialsPath: FlexibleHisProject.materialsPath,
                            stampsPath: FlexibleHisProject.stampsPath, persist: {})
        addTeardownBlock { @MainActor in await m.waitForIdle() }
        stage.apply(r.project, owned: true, pageUp: false)
        try await FlexibleHisProject.waitFor(90, "his scene and stacks") {
            m.sceneState == .ready && m.loadedKeys.allSatisfy { m.stacks[$0] != nil }
        }
        await m.waitForIdle()
        tweak(m)
        await m.waitForIdle()
        stage.didExitSettings()
        try await FlexibleHisProject.waitFor(240, "his lattice") {
            (m.lattice != nil && !m.latticeIsStale && !m.latticeBuilding) || m.latticeError != nil
        }
        await m.waitForIdle()
        stage.refresh()
        XCTAssertNil(m.latticeError)
        return (r, stage, m)
    }

    /// The pressed faces of a run job, as core parses it.
    static func pressed(_ job: String) throws -> [Int] {
        try FlexibleCore.parseJobBlock(job).faces.filter { $0.role == "loaded" }.map(\.faceRegionID).sorted()
    }

    // MARK: V4 — Ready on another stage sends HIS edit, never the weight from before it

    /// He leaves the Lattice stage and changes a main-page Load group's weight on Topology. The
    /// stage re-reads the main page's loads only while it shows, so C2's Ready sent the job from
    /// BEFORE his edit. Now the tap catches the model up first; the lattice no longer matches, so
    /// nothing is sent — he is taken to the Lattice stage, it rebuilds, and Ready sends his weight.
    @MainActor
    func testReadyOnAnotherStageSendsHisEditNotTheOldWeight() async throws {
        let (r, stage, m) = try await hisBuilt { $0.rest(5) }
        let pm = r.project
        XCTAssertEqual(stage.status.tone, .ready, "premise: Lattice · Ready (\(stage.status.line))")
        guard let face = m.settings.loadedFaces.first(where: { $0.weightFrom != nil }), let gid = face.weightFrom,
              let before = pm.force.kind(for: gid).weightKg else {
            return XCTFail("premise: a pressed face linked to a main-page Load group")
        }
        let jobBefore = try m.runJobJSON()
        // he taps [‹ Topology] …
        stage.apply(pm, owned: false, pageUp: false)
        // … and there changes the Load group's weight
        let newKg = max(2 * before, before + 5)
        pm.force.setWeight(gid, kg: newKg)
        try await Task.sleep(nanoseconds: 700_000_000)   // every debounce has run (off-stage: nothing re-reads)
        await m.waitForIdle()
        let s = stage.status
        XCTAssertEqual(s.tone, .ready, "premise: the pill on Topology still reads Ready")
        var went = 0
        stage.pillTapped(s, open: { XCTFail("Ready never opens Settings") }, goToLattice: { went += 1 })
        print("FLEX-C2V V4 group \(gid): \(before) → \(newKg) kg on Topology · tap Ready → runs \(stage.coreRun.runs) · to the Lattice stage \(went)× · note \(String(describing: stage.note.kind)) · face \(face.faceRegionID) \(face.weightKg) → \(m.settings.face(face.faceRegionID)?.weightKg ?? -1) kg · stale \(m.latticeIsStale) · pill '\(stage.status.line)'")
        XCTAssertEqual(stage.coreRun.runs, 0, "the job from before his edit is never sent")
        XCTAssertEqual(went, 1, "…he is taken to the Lattice stage, where it rebuilds")
        XCTAssertEqual(stage.note.kind, .building)
        XCTAssertEqual(m.settings.face(face.faceRegionID)?.weightKg ?? -1, face.weightKg * newKg / before, accuracy: 1e-6,
                       "the model took his weight (one source of truth: the group)")
        XCTAssertTrue(m.latticeIsStale, "the lattice no longer matches his loads")
        XCTAssertEqual(stage.status.tone, .building)
        // on the Lattice stage (what goToLattice does): it rebuilds, Ready comes back, the tap sends HIS weight
        stage.apply(pm, owned: true, pageUp: false)
        try await FlexibleHisProject.waitFor(240, "the rebuild") {
            (m.lattice != nil && !m.latticeIsStale && !m.latticeBuilding) || m.latticeError != nil
        }
        await m.waitForIdle()
        stage.refresh()
        XCTAssertEqual(stage.status.tone, .ready)
        stage.pillTapped(stage.status, open: { XCTFail("Ready never opens Settings") }, goToLattice: { went += 1 })
        try await FlexibleHisProject.waitFor(180, "core's answer") { !stage.coreRun.isSending }
        XCTAssertEqual(stage.coreRun.runs, 1)
        XCTAssertEqual(went, 1, "on the Lattice stage the tap stays put")
        let sent = try XCTUnwrap(stage.coreRun.sentJob)
        XCTAssertEqual(sent, try m.runJobJSON(), "the job Settings describes NOW")
        // ★ POSITIVE CONTROL: the two documents differ where his edit is — the face's weight
        let wBefore = try XCTUnwrap(FlexibleCore.parseJobBlock(jobBefore).faces.first { $0.faceRegionID == face.faceRegionID }?.weightN)
        let wSent = try XCTUnwrap(FlexibleCore.parseJobBlock(sent).faces.first { $0.faceRegionID == face.faceRegionID }?.weightN)
        print("FLEX-C2V V4 sent: face \(face.faceRegionID) weight_n \(wBefore) → \(wSent) · core '\(stage.coreRun.line)'")
        XCTAssertEqual(wSent / wBefore, newKg / before, accuracy: 1e-6, "his weight reached core")
    }

    // MARK: V1 — "Building…" on another stage takes him to the Lattice stage

    /// Builds start only while the Lattice stage shows. C2's tap on "Lattice · Building…" posted a
    /// note that only the Lattice stage draws — on Topology a dead tap. Now it takes him there.
    @MainActor
    func testBuildingOnAnotherStageTakesHimToTheLatticeStage() async throws {
        let building = FlexibleMainStatus(line: FlexibleMainStatus.building, tone: .building, fix: nil)
        var went = 0, opened = 0
        let off = FlexibleMainStage()   // the Lattice stage is not showing
        off.pillTapped(building, open: { opened += 1 }, goToLattice: { went += 1 })
        XCTAssertEqual(went, 1, "off the Lattice stage: the tap goes there")
        XCTAssertEqual(opened, 0, "…and opens no Settings (his img 6)")
        XCTAssertEqual(off.note.kind, .building, "the note waits for him there")
        // ★ CONTROL: on the Lattice stage the same tap goes nowhere (the note beside the row says it)
        let (pm, on, m, top) = try await padStage()
        on.pillTapped(building, open: { opened += 1 }, goToLattice: { went += 1 })
        XCTAssertEqual(went, 1, "control: on the Lattice stage there is nowhere to go")
        XCTAssertEqual(opened, 0)
        // the real case: Save & Exit, then ‹ Topology while the designs are in flight
        XCTAssertTrue(m.press(top, kg: 10))
        on.didExitSettings()
        let designing = m.readiness.designing, buildingAtExit = m.latticeBuilding
        on.apply(pm, owned: false, pageUp: false)
        try await Task.sleep(nanoseconds: 2_000_000_000)
        await m.waitForIdle()
        let s = on.status
        print("FLEX-C2V V1 designing at Exit \(designing) building \(buildingAtExit) · off-stage 2 s: lattice \(m.lattice != nil) building \(m.latticeBuilding) · pill '\(s.line)' tap \(s.tap)")
        if s.tap == .wait {
            on.pillTapped(s, open: { opened += 1 }, goToLattice: { went += 1 })
            XCTAssertEqual(went, 2, "Building… on Topology: to the Lattice stage")
            XCTAssertEqual(opened, 0)
            on.apply(pm, owned: true, pageUp: false)
            try await FlexibleHisProject.waitFor(120, "the build there") { m.lattice != nil || m.latticeError != nil }
            await m.waitForIdle()
            XCTAssertNil(m.latticeError)
        }
    }

    // MARK: the pill never promises what core will refuse (his project as saved, two groups, TPU 95A)

    /// The rule as values: what core can run instead, 1–3 buttons.
    @MainActor
    func testTheHoldRuleOffersWhatCoreCanRun() {
        let name: (Int) -> String = { "Face \($0)" }
        func g(_ id: Int, _ n: Int, _ r: [Int]) -> FlexibleSqueezeGroup { FlexibleSqueezeGroup(id: id, number: n, regions: r) }
        // one group, one pinch: each end resting (his pinch is kept — the job only)
        let one = FlexibleCoreHold.sends(groups: [g(1, 1, [3, 5, 7])], pinches: [(a: 3, b: 5)], name: name)
        XCTAssertEqual(one.map(\.title), ["Send with Face 5 resting", "Send with Face 3 resting"])
        XCTAssertEqual(one.map(\.resting), [[5], [3]])
        // two pinches: one end of each
        let two = FlexibleCoreHold.sends(groups: [g(1, 1, [1, 2, 3, 4])], pinches: [(a: 1, b: 2), (a: 3, b: 4)], name: name)
        XCTAssertEqual(two.map(\.resting), [[2, 4], [1, 3]])
        // two groups, no pinch: each group alone
        let groups = FlexibleCoreHold.sends(groups: [g(1, 1, [1, 2]), g(2, 2, [3])], pinches: [], name: name)
        XCTAssertEqual(groups.map(\.title), ["Send Group 1 only", "Send Group 2 only"])
        XCTAssertEqual(groups.map(\.resting), [[3], [1, 2]])
        // a group with a pinch inside (his img 4: the sides in Group 2) rests one end of it too
        let his = FlexibleCoreHold.sends(groups: [g(1, 1, [1]), g(2, 2, [3, 5])], pinches: [(a: 3, b: 5)], name: name)
        XCTAssertEqual(his.map(\.title), ["Send Group 1 only", "Send Group 2 only, Face 5 resting"])
        XCTAssertEqual(his.map(\.resting), [[3, 5], [1, 5]])
        // never more than three buttons — ★ RE-PINNED (round 7 · U21 batch R, the reviewer's ruling E(1) of 2026-10-21, E2 Q2: "one
        // [More…] listing every group, one per row; no fourth fixed button"): every group has a send; the Export step shows two
        // buttons and [More…] (FlexibleCoreHold.slots), so still never more than three
        let four = FlexibleCoreHold.sends(groups: (1...4).map { g($0, $0, [$0]) }, pinches: [], name: name)
        XCTAssertEqual(four.count, 4)
        XCTAssertEqual(FlexibleCoreHold.slots(four).count, 3)
        // the order: a calibrate-first filament first (any send would be refused), then groups, then a pinch
        XCTAssertEqual(FlexibleCoreHold.kind(calibrateFirst: true, groups: 2, pinches: 1), .shapeOnly)
        // ★ RE-PINNED (C2 WIRING W2, the reviewer's ruling 5 (a)): core designs several groups and a pinch — neither is held; a
        // pressed face with no lattice under it is (core refuses it), before an edges group left out (said first)
        XCTAssertNil(FlexibleCoreHold.kind(calibrateFirst: false, groups: 2, pinches: 1), "★ W2: two groups and a pinch are core's")
        XCTAssertNil(FlexibleCoreHold.kind(calibrateFirst: false, groups: 1, pinches: 1))
        XCTAssertEqual(FlexibleCoreHold.kind(calibrateFirst: false, groups: 2, pinches: 1, edgesBeside: true, noLatticeUnder: true),
                       .noLatticeUnder)
        XCTAssertEqual(FlexibleCoreHold.kind(calibrateFirst: false, groups: 2, pinches: 1, edgesBeside: true), .edgesBeside)
        XCTAssertEqual(FlexibleCoreHold.kind(calibrateFirst: true, groups: 1, pinches: 0, noLatticeUnder: true), .shapeOnly)
        // ★ RED CONTROL (the app before C2): groups, then a pinch; no-lattice is never its hold
        FlexibleAngledGoldens.preC2 {
            XCTAssertEqual(FlexibleCoreHold.kind(calibrateFirst: false, groups: 2, pinches: 1), .squeezeGroups)
            XCTAssertEqual(FlexibleCoreHold.kind(calibrateFirst: false, groups: 1, pinches: 1), .pinch)
            XCTAssertNil(FlexibleCoreHold.kind(calibrateFirst: false, groups: 1, pinches: 0, noLatticeUnder: true))
        }
        XCTAssertNil(FlexibleCoreHold.kind(calibrateFirst: false, groups: 1, pinches: 0))
        // one line each on the pill (it is 300 pt at 10.5 pt)
        for k in [FlexibleCoreHold.Kind.pinch, .squeezeGroups, .edgesBeside, .noLatticeUnder] {
            XCTAssertLessThanOrEqual(FlexibleCoreHold.pill(k, shapeOnlyLabel: nil).count, 44)
        }
        // ★ the Preview pill is not the Ready pill's green
        XCTAssertNotEqual(FlexibleMainStatusPill.fill(.preview), FlexibleMainStatusPill.fill(.ready))
        XCTAssertEqual(FlexibleMainStatusPill.fill(.ready), FlexibleStageStyle.accentToken, "control: Ready is the green")
        XCTAssertEqual(FlexibleMainStatus(line: "x", tone: .preview, fix: nil).tap, .send, "its tap opens the Export step on it")
    }

    /// His project (with the [Lattice under it] tap FlexibleHisProject replays — AS SAVED the pill
    /// names Top B first: FlexibleLatticeUnderReviewTests): faces 3 and 5 pinch the pad. ★ RE-PINNED (C2 WIRING W2, the
    /// reviewer's ruling 5 (a): "a pinch inside one Load group = core's pinch; hands are separate load cases"): core designs his
    /// pinch, so the pill is the green Ready and its tap sends the WHOLE job — both ends pressed — and core's own runner designs
    /// it. Was (round 4, C2 verification): a preview, the Export step offering each end resting. RED CONTROL (the app before C2):
    /// that preview, its line naming the faces and its two sends.
    @MainActor
    func testHisPinchIsAPreviewAndTheStepSendsEitherEnd() async throws {
        let (_, stage, m) = try await hisBuilt()
        XCTAssertEqual(m.pinches.map { "\($0.a)|\($0.b)" }, ["3|5"], "premise: his faces 3 and 5 pinch the pad")
        let a = m.displayName(3), b = m.displayName(5)
        // ★ RED CONTROL: the app before C2 — never the green Ready; the step names the faces and offers each end
        try FlexibleAngledGoldens.preC2 {
            XCTAssertEqual(stage.status.tone, .preview, "RED CONTROL: before C2, a preview")
            XCTAssertEqual(stage.status.line, FlexibleCoreHold.pill(.pinch, shapeOnlyLabel: nil))
            let h = try XCTUnwrap(m.coreHold)
            XCTAssertEqual(h.line, "Not sent: core can\u{2019}t press \(a) and \(b) at once", "the faces, named")
            XCTAssertEqual(h.fixes.map(\.title), ["Send with \(b) resting", "Send with \(a) resting"])
        }
        let s = stage.status
        print("FLEX-C2W2 his pinch: pill '\(s.line)' tone \(s.tone)")
        XCTAssertEqual(s.tone, .ready, "★ W2: core designs his pinch — the green Ready")
        XCTAssertEqual(s.line, FlexibleMainStatus.ready)
        XCTAssertNil(m.coreHold, "★ nothing held")
        let all = m.settings.loadedFaces.map(\.faceRegionID).sorted()
        let settings = m.settings
        stage.pillTapped(s, open: { XCTFail("no Settings") }, goToLattice: { XCTFail("already there") })
        let run = stage.coreRun
        XCTAssertTrue(run.shown)
        try await FlexibleHisProject.waitFor(240, "core's answer") { !run.isSending }
        print("FLEX-C2W2 his pinch: step '\(run.line)' · (i) '\(run.info ?? "-")'")
        XCTAssertEqual(run.runs, 1, "★ sent")
        guard case .ran(let rep) = run.phase, rep.refusal == nil else { return XCTFail("★ core designed his pinch: \(run.phase)") }
        let job = try XCTUnwrap(run.sentJob)
        XCTAssertEqual(try Self.pressed(job), all, "★ both ends pressed in the one job")
        XCTAssertTrue(all.contains(3) && all.contains(5))
        let groups = (try FlexibleC2WiringTests.block(job)["squeeze_groups"] as? [[String: Any]]) ?? []
        print("FLEX-C2W2 his pinch: squeeze_groups \(groups) · pinches \(m.pinches.map { [$0.a, $0.b] })")
        XCTAssertEqual(m.settings, settings, "his settings as they were")
        XCTAssertFalse((run.info ?? "").contains("/"), "no temp path he cannot open behind the (i)")
    }

    /// His img 4 (the sides in Group 2): each group alone — Group 2 with one end of its pinch resting.
    @MainActor
    func testTwoGroupsOfferEachGroupAlone() async throws {
        let (_, stage, m) = try await hisBuilt { m in
            _ = m.newGroup(with: 3)
            if let g2 = m.squeezeGroup(of: 3) { m.moveToGroup(5, g2.id) }
        }
        XCTAssertEqual(m.squeezeGroups.count, 2, "premise: two squeeze groups")
        // ★ RED CONTROL (the app before C2): a preview; the step offers each group alone, each send's job parsed by core
        try FlexibleAngledGoldens.preC2 {
            XCTAssertEqual(stage.status.tone, .preview)
            XCTAssertEqual(stage.status.line, FlexibleCoreHold.pill(.squeezeGroups, shapeOnlyLabel: nil))
            let h = try XCTUnwrap(m.coreHold)
            XCTAssertEqual(h.line, FlexibleCoreRun.notSentLine(.squeezeGroups))
            XCTAssertEqual(h.fixes.count, 2)
            XCTAssertTrue(h.fixes[0].title.hasPrefix("Send Group 1 only"))
            XCTAssertTrue(h.fixes[1].title.hasPrefix("Send Group 2 only"))
            let all = m.settings.loadedFaces.map(\.faceRegionID)
            for f in h.fixes {
                XCTAssertEqual(try Self.pressed(try m.runJobJSON(resting: Set(f.resting))), all.filter { !f.resting.contains($0) }.sorted(),
                               "\(f.title): core's own parser reads the faces it presses")
            }
        }
        // ★ RE-PINNED (C2 WIRING W2, ruling 5 (a): "hands are separate load cases"): core designs both groups in ONE job (its
        // combination) — the green Ready, and the tap sends every pressed face of both groups; core's own runner designs it
        let s = stage.status
        print("FLEX-C2W2 his two groups: \(m.squeezeGroups.map { m.groupLine($0) }) · pill '\(s.line)' \(s.tone)")
        XCTAssertEqual(s.tone, .ready, "★ W2: two groups are core's")
        XCTAssertEqual(s.line, FlexibleMainStatus.ready)
        XCTAssertNil(m.coreHold)
        let all = m.settings.loadedFaces.map(\.faceRegionID).sorted()
        stage.pillTapped(s, open: { XCTFail("no Settings") }, goToLattice: {})
        let run = stage.coreRun
        try await FlexibleHisProject.waitFor(240, "core's answer") { !run.isSending }
        print("FLEX-C2W2 his two groups: '\(run.line)' · (i) '\(run.info ?? "-")'")
        XCTAssertEqual(run.runs, 1)
        guard case .ran(let rep) = run.phase, rep.refusal == nil else { return XCTFail("★ core designed both groups: \(run.phase)") }
        let job = try XCTUnwrap(run.sentJob)
        XCTAssertEqual(try Self.pressed(job), all, "★ both groups' faces in the one job")
        let groups = (try FlexibleC2WiringTests.block(job)["squeeze_groups"] as? [[String: Any]]) ?? []
        print("FLEX-C2W2 his two groups: squeeze_groups \(groups)")
    }

    /// ★ C2 WIRING W2 END TO END (ruling 5 (a): "a core squeeze group = one app HAND with 2+ entries"): his main page's Top
    /// Load group over BOTH tops (his edit: Top B added to Top) is ONE hand — the job's one squeeze group, its force_n Top's
    /// 10 kg, neither top stating a weight of its own. Core reads it as ONE hand ("group 1") and its receipt carries that force
    /// over the two — sent as it stands (refused by C2's combination beside Face 3: a FINDING, below) and alone, which core's
    /// own runner designs. RED CONTROL: his Top as saved (Top A only) — no hand of two, no squeeze group (the two-groups test
    /// above prints it: squeeze_groups []).
    @MainActor
    func testHisTopGroupOverBothTopsIsOneSqueezeGroupCoreDesigns() async throws {
        let a = FlexibleHisProject.topA, b = FlexibleHisProject.topB
        let (r, stage, m) = try await hisBuilt(before: { p in
            let top = try XCTUnwrap(p.selection.groups.first { $0.name == "Top" })
            XCTAssertEqual(top.regionIDs, [103], "premise: his Top presses Top A as saved")
            p.selection.addRegions([104], to: top.id)
        })
        let topID = try XCTUnwrap(r.project.selection.groups.first { $0.name == "Top" }?.id)
        XCTAssertEqual(m.settings.face(a)?.weightFrom, topID, "premise: Top presses Top A")
        XCTAssertEqual(m.settings.face(b)?.weightFrom, topID, "premise: …and Top B (his edit)")
        let kgA = try XCTUnwrap(m.settings.face(a)?.weightKg), kgB = try XCTUnwrap(m.settings.face(b)?.weightKg)
        XCTAssertEqual(kgA + kgB, 10, accuracy: 1e-9, "premise: Top's 10 kg, split by area")
        let s = stage.status
        print("FLEX-C2W2 his Top over both: Top A \(kgA) kg · Top B \(kgB) kg · \(m.squeezeGroups.map { m.groupLine($0) }) · pill '\(s.line)' \(s.tone)")
        XCTAssertEqual(s.tone, .ready, "★ core's: nothing held")
        XCTAssertNil(m.coreHold)
        let job = try m.runJobJSON()
        let block = try FlexibleC2WiringTests.block(job)
        let groups = try XCTUnwrap(block["squeeze_groups"] as? [[String: Any]], "★ a squeeze group is sent")
        print("FLEX-C2W2 his Top over both: squeeze_groups \(groups)")
        XCTAssertEqual(groups.count, 1, "★ ONE hand of two")
        XCTAssertEqual(Set((groups.first?["faces"] as? [Int]) ?? []), [a, b], "★ the two tops")
        XCTAssertEqual((groups.first?["force_n"] as? Double) ?? 0, FlexibleUnits.newtons(kg: 10), accuracy: 1e-9, "★ Top's 10 kg")
        for e in (block["faces"] as? [[String: Any]]) ?? [] where [a, b].contains(e["face_region_id"] as? Int ?? -1) {
            XCTAssertNil(e["weight_n"], "★ \(e["face_region_id"] ?? "?"): its share is the group's, by area, core's")
        }
        // core's receipt (written on a refusal too): ONE squeeze group, Top's 10 kg, split over the two tops
        func receiptGroups(_ rep: FlexibleCoreRunReport, _ label: String) throws {
            let info = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: rep.outDir).appendingPathComponent("run_info.json")))
            let receipt = try XCTUnwrap((info as? [String: Any])?["flexible"] as? [String: Any], "\(label): core's receipt")
            let got = try XCTUnwrap(receipt["squeeze_groups"] as? [[String: Any]], "★ \(label): core's receipt has the squeeze group")
            print("FLEX-C2W2 his Top over both (\(label)): core's receipt squeeze_groups \(got)")
            XCTAssertEqual(got.count, 1, label)
            XCTAssertEqual((got.first?["force_n"] as? Double) ?? 0, FlexibleUnits.newtons(kg: 10), accuracy: 1e-6, "★ \(label): core read Top's force")
            let split = (got.first?["split"] as? [String: Any] ?? [:]).values.compactMap { $0 as? Double }
            XCTAssertEqual(split.count, 2, "★ \(label): split over the two tops")
            XCTAssertEqual(split.reduce(0, +), FlexibleUnits.newtons(kg: 10), accuracy: 1e-6, "★ \(label): the split sums to the group's force")
        }
        // core's own runner, the job as it stands. ★ FINDING (w2c, 11-09; reported to the reviewer): Faces 3 and 5 are hands of
        // their own beside Top's, so separate load cases (Q-C1), and C2's first-order combination (B2b, "not proven impossible")
        // refuses Face 3 beside Top's hand — core names that hand "group 1": the two tops are ONE hand to core. Pinned so a
        // change in core shows.
        stage.pillTapped(s, open: { XCTFail("no Settings") }, goToLattice: {})
        let run = stage.coreRun
        try await FlexibleHisProject.waitFor(240, "core's answer") { !run.isSending }
        print("FLEX-C2W2 his Top over both: '\(run.line)' · (i) '\(run.info ?? "-")'")
        XCTAssertEqual(run.runs, 1)
        XCTAssertEqual(run.sentJob, job, "★ the job above is what went")
        guard case .ran(let whole) = run.phase else { return XCTFail("★ core answers: \(run.phase)") }
        XCTAssertEqual(whole.refusal?.code, "combination_not_reachable", "★ FINDING: core's combination (\(run.line))")
        let reason = whole.refusal?.reason ?? ""
        XCTAssertTrue(reason.contains("group 1"), "★ core names Top's hand as one group: \(reason)")
        XCTAssertFalse(reason.contains("face \(a)") || reason.contains("face \(b)"), "★ never a top on its own: \(reason)")
        try receiptGroups(whole, "as it stands")
        // ★ Top's hand ALONE (the other faces resting, in the job only): one load case — core designs the hand of two
        let others = m.settings.loadedFaces.map(\.faceRegionID).filter { ![a, b].contains($0) }.sorted()
        XCTAssertFalse(others.isEmpty, "premise: Top's hand presses beside other faces")
        run.send(m, fix: .send(resting: others, title: "Send Top alone", scope: "Top alone"))
        try await FlexibleHisProject.waitFor(240, "core's answer (Top alone)") { !run.isSending }
        print("FLEX-C2W2 his Top over both, Top alone: '\(run.line)' · (i) '\(run.info ?? "-")'")
        XCTAssertEqual(run.runs, 2)
        let alone = try XCTUnwrap(run.sentJob)
        XCTAssertEqual(try Self.pressed(alone), [a, b].sorted(), "★ only the two tops press")
        XCTAssertEqual((try FlexibleC2WiringTests.block(alone)["squeeze_groups"] as? [[String: Any]])?.count, 1, "★ still one squeeze group")
        guard case .ran(let rep) = run.phase, rep.refusal == nil else { return XCTFail("★ core designs the hand of two: \(run.phase)") }
        try receiptGroups(rep, "Top alone")
    }

    /// img 1 (TPU 95A): the shape-only lattice's pill was the green Ready, and a tap sent a job core
    /// refuses for certain. Now it is a preview; the step says why in one line (core's catalogue
    /// sentence behind the (i) — the one core answers with) and offers the filament with data.
    @MainActor
    func testAShapeOnlyLatticeIsNotReadyAndOffersAFilamentWithData() async throws {
        let (pm, stage, m, top) = try await padStage("tpu95a_generic")
        XCTAssertTrue(m.press(top, kg: 10))
        stage.didExitSettings()
        try await FlexibleHisProject.waitFor(120, "the shape-only lattice") {
            (m.lattice != nil && !m.latticeBuilding) || m.latticeError != nil
        }
        await m.waitForIdle()
        stage.refresh()
        let s = stage.status
        let name = FlexibleRowCopy.shortName(try XCTUnwrap(m.material?.displayName))
        XCTAssertEqual(s.line, FlexibleReadiness.shapeOnlyLabel(try XCTUnwrap(m.material?.displayName)), "his label, kept")
        XCTAssertEqual(s.tone, .preview, "not the green Ready")
        stage.pillTapped(s, open: { XCTFail("no Settings") }, goToLattice: { XCTFail("already there") })
        let run = stage.coreRun
        XCTAssertEqual(run.runs, 0, "a job core refuses for certain is not sent")
        XCTAssertEqual(run.line, "Not sent: \(name) has no squish data yet")
        let refusal = try XCTUnwrap(m.material?.noPrediction)
        XCTAssertEqual(run.info, "\(refusal.reason) (\(refusal.code))", "core's own sentence behind the (i)")
        // ★ POSITIVE CONTROL: core's own runner gives exactly that answer to this job
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("flex-c2v-\(UUID().uuidString)").path
        defer { try? FileManager.default.removeItem(atPath: out) }
        let core = try FlexibleCore.runJob(jobJSON: try m.runJobJSON(), jobDir: (try XCTUnwrap(pm.importedFile).path as NSString).deletingLastPathComponent,
                                           outDir: out, materialsPath: FlexibleHisProject.materialsPath, fingerprint: CoreFingerprint.value)
        XCTAssertEqual(core.refusal, refusal, "the app's verdict is core's")
        // the fix: the filament with squish data
        let fix = try XCTUnwrap(run.hold?.fixes.first)
        guard case .useFilament(let id, let fname) = fix else { return XCTFail("a filament fix: \(fix)") }
        XCTAssertEqual(run.hold?.fixes.count, 1)
        XCTAssertNil(m.catalogue.first { $0.id == id }?.noPrediction, "\(fname) has squish data")
        print("FLEX-C2V TPU 95A: pill '\(s.line)' tone \(s.tone) · step '\(run.line)' · button [\(fix.title)] · core's own runner: \(core.refusal?.code ?? "-")")
        run.onFix?(fix)
        XCTAssertFalse(run.shown, "the step closes: the lattice rebuilds on the main page")
        XCTAssertEqual(m.settings.materialID, id)
        XCTAssertEqual(stage.note.kind, .building)
        try await FlexibleHisProject.waitFor(180, "the rebuild on \(fname)") {
            (m.lattice != nil && !m.latticeIsStale && !m.latticeBuilding && m.lattice?.shapeOnly == false) || m.latticeError != nil
        }
        await m.waitForIdle()
        stage.refresh()
        XCTAssertEqual(stage.status.tone, .ready, "Ready on a filament core can design")
        stage.pillTapped(stage.status, open: { XCTFail("no Settings") }, goToLattice: {})
        try await FlexibleHisProject.waitFor(180, "core's answer") { !run.isSending }
        guard case .ran(let rep) = run.phase else { return XCTFail("core ran it: \(run.phase)") }
        XCTAssertNil(rep.refusal)
        XCTAssertEqual(run.runs, 1)
    }

    // MARK: a part with no file

    @MainActor
    func testAPartWithNoFileSaysSoNotPressAFace() throws {
        let pm = ProjectModel(id: UUID(), name: "no file", material: "ABS", process: .fdm, importedFile: nil, importedMesh: nil)
        pm.lattice.flexible = FlexibleStageSettings(materialID: "varioshore_tpu",
                                                    faces: [FlexibleFaceSettings(faceRegionID: 1, weightKg: 5)])
        let stage = FlexibleMainStage()
        let m = stage.model(for: pm, materialsPath: FlexibleHisProject.materialsPath, stampsPath: nil, persist: {})
        XCTAssertFalse(m.settings.loadedFaces.isEmpty, "premise: a face is pressed")
        XCTAssertThrowsError(try m.runJobJSON()) { XCTAssertEqual($0 as? FlexibleJob.EncodeError, .noPart) }
        stage.coreRun.send(m)
        XCTAssertEqual(stage.coreRun.line, "Not sent: the part\u{2019}s file is missing")
        // ★ CONTROL: "press a face first" is a different line (C2 said it here)
        XCTAssertNotEqual(FlexibleCoreRun.notSentLine(.noPart), FlexibleCoreRun.notSentLine(.noLoadedFace))
        XCTAssertLessThanOrEqual(FlexibleCoreRun.notSentLine(.noPart).count, 56)
    }

    // MARK: the note beside the row — it costs the legends nothing

    /// C2 reserved a band UNDER the view row for a note that shows 4 s; at 13" landscape with his
    /// Gravity chip column two of the three legends moved into a second column, over the part.
    /// Now the note sits on the row's own line, left of the three buttons, clear of the left panel,
    /// and never pushes a legend out of the trailing column.
    func testTheNoteSitsBesideTheRowAndCostsTheLegendsNothing() {
        let sizes: [(String, CGSize)] = [("13l", CGSize(width: 1376, height: 1032)), ("13p", CGSize(width: 1032, height: 1376)),
                                         ("11l", CGSize(width: 1194, height: 834)), ("11p", CGSize(width: 834, height: 1194)),
                                         ("11p820", CGSize(width: 820, height: 1180)), ("mini", CGSize(width: 744, height: 1133))]
        let kinds: [FlexibleReadKind] = [.dent, .stress, .lattice]
        for (name, v) in sizes {
            let row = FlexibleMainViewToggles.rowFrame(viewport: v), note = FlexibleMainViewToggles.noteFrame(viewport: v)
            let frame = FlexibleMainViewToggles.frame(viewport: v)
            // ★ RE-PINNED (round 7, R7-D1 — his pick 1, A2's views row of six 44 pt icons on one line): where the row leaves
            // less than the note's 180 pt beside it (11" portrait, and the 820 pt pad), the note sat UNDER the row's right end.
            // ★ RE-PINNED (round 7, R7-D3 — the reviewer's ruling 3 of 2026-10-17: "'Lattice ready' dropping under the icons at
            // 11" portrait" fixed before D3 is done): beside the row on its line at EVERY size again — where the left panel's
            // column leaves too little, over that column's empty top (the open panel never rises above 2 × noteTop); it still
            // costs the legends nothing (below). Was (R7-D1): under the row at 11p and 11p820.
            // ★ RE-PINNED (B2, U1 — #362's OK 2026-11-03 05:34): the open left panel now starts at PageChrome.panelTop, 12 pt under the stage row, so the column's top is no longer empty on the row's line; where the row leaves too little beside it (11" portrait, the 820 pt pad) the note goes UNDER the row's right end, whole (R7-D1's place). Was (R7-D3): beside, over the column's empty top.
            let under = ["11p", "11p820"].contains(name)
            if under {
                XCTAssertGreaterThanOrEqual(note.minY, row.maxY, "under the row at \(name)")
                XCTAssertEqual(note.maxX, row.maxX, accuracy: 0.5, "at the row's right end at \(name)")
            } else {
                XCTAssertEqual(note.midY, row.midY, accuracy: 0.5, "on the row's line at \(name)")
                XCTAssertLessThanOrEqual(note.maxX, row.minX - DS.Space.s + 0.5, "left of the three buttons at \(name)")
            }
            XCTAssertGreaterThanOrEqual(note.width, 180, "room for 'Lattice ready · Show' at \(name)")
            XCTAssertTrue(!note.intersects(FlexibleMainLegendLayout.leftStrip(viewport: v)) || note.maxY < FlexibleMainViewToggles.leftPanelHighestTop,
                          "clear of the left panel (or above its highest reach) at \(name)")
            XCTAssertTrue(frame.contains(note))
            // ★ RE-PINNED (R7-V, his 2026-10-14 words: "Remove the two full worded view icons"): batch V's settings' line is
            // gone — the NOTE costs the legends nothing again: the keep-out ends where the row ends, and the legends are
            // compared with the row alone held out.
            let held = row
            if !under { XCTAssertEqual(frame.maxY, held.maxY, accuracy: 0.5, "the keep-out ends where the row ends at \(name)") }
            for chip: CGFloat in [0, 222] {
                let keep = FlexibleMainLegendLayout.keepOut(viewport: v, bottomClearance: 94, chipColumnWidth: chip)
                let placed = FlexibleMainLegendLayout.place(kinds, minimized: [], viewport: v, keepOut: keep)
                let rowOnly = FlexibleMainLegendLayout.place(kinds, minimized: [], viewport: v,
                                                              keepOut: keep.map { $0 == frame ? held : $0 })
                // the note never pushes a legend out of the trailing column; where batch C's row-only
                // keep-out held them all there, nothing moves at all (at 11" landscape with the chip
                // column batch C already needed a second column — its top legend sits lower, as in C2)
                let edge = v.width - PageChrome.edge
                func trailing(_ p: [FlexibleReadKind: FlexibleMainLegendLayout.Placed]) -> Int { p.values.filter { abs($0.frame.maxX - edge) < 0.5 }.count }
                XCTAssertEqual(trailing(placed), trailing(rowOnly), "no legend leaves the trailing column at \(name), chips \(chip)")
                if trailing(rowOnly) == kinds.count {
                    XCTAssertEqual(placed.mapValues(\.frame), rowOnly.mapValues(\.frame), "the note costs the legends nothing at \(name), chips \(chip)")
                }
                for (k, p) in placed { XCTAssertFalse(p.frame.intersects(note), "the \(k) legend clears the note at \(name)") }
                if chip > 0 { print("FLEX-C2V note \(name) chips \(chip): note \(note.integral) · legends \(placed.map { "\($0.key.rawValue) \($0.value.frame.integral)" }.sorted())") }
            }
        }
        // ★ RED CONTROL: C2's band UNDER the row — at 13" landscape with his Gravity chip column
        // (≈ 222 pt), legends left the trailing column
        let v = CGSize(width: 1376, height: 1032)
        let row = FlexibleMainViewToggles.rowFrame(viewport: v)
        let band = CGRect(x: v.width - PageChrome.edge - 300, y: row.maxY + DS.Space.s, width: 300, height: 34)
        let now = FlexibleMainViewToggles.frame(viewport: v)
        let keep = FlexibleMainLegendLayout.keepOut(viewport: v, bottomClearance: 94, chipColumnWidth: 222)
        let c2 = FlexibleMainLegendLayout.place(kinds, minimized: [], viewport: v, keepOut: keep.map { $0 == now ? row.union(band) : $0 })
        let moved = c2.values.filter { $0.frame.maxX < v.width - PageChrome.edge - 1 }.count
        print("FLEX-C2V note control 13l chips 222 with C2's under-row band: \(c2.map { "\($0.key.rawValue) \($0.value.frame.integral)" }.sorted())")
        XCTAssertGreaterThanOrEqual(moved, 1, "control: C2's band pushed a legend out of the trailing column")
    }

    // MARK: the Export step

    /// ★ RE-PINNED (round 7, R7-D1 — H31 and the reviewer's condition (a)): the step's rows moved, unchanged, to
    /// FlexibleExportRows (the sheet and the Flexible stage's corner card draw the same rows). Was: inside the sheet.
    func testTheExportStepSaysTheWaitOnceAndUsesDSTokens() throws {
        let sheet = try FlexibleSource.code("FlexibleExportSheet.swift")
        let code = sheet + (try FlexibleSource.code("FlexibleExportRows.swift"))
        XCTAssertEqual(code.components(separatedBy: "FlexibleCoreRun.exportsWait").count - 1, 1, "one line")
        let card = try XCTUnwrap(code.range(of: "private func card("))
        XCTAssertFalse(code[card.lowerBound...].contains("exportsWait"), "not once per card")
        for raw in ["Color.black", "Color.white", ".black.opacity", ".white.opacity"] {
            XCTAssertFalse(code.contains(raw), "DS tokens only: \(raw)")
        }
        XCTAssertTrue(code.contains("DS.Color.scrim"))
        XCTAssertTrue(code.contains("run.onFix?("), "the step's fix buttons")
        // ★ the run lands on the main actor through a method (Swift 6: no captured `self` var read
        // inside MainActor.run)
        let run = try FlexibleSource.code("FlexibleCoreRun.swift")
        XCTAssertFalse(run.contains("await MainActor.run {\n                guard let self"))
    }
}
