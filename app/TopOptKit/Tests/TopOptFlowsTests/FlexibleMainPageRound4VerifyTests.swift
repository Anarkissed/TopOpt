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
    private func hisBuilt(_ tweak: (FlexibleStageModel) -> Void = { _ in }) async throws
        -> (FlexibleHisProject.Restored, FlexibleMainStage, FlexibleStageModel) {
        let r = try FlexibleHisProject.restore()
        addTeardownBlock { r.cleanup() }
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
        // never more than three buttons
        let four = FlexibleCoreHold.sends(groups: (1...4).map { g($0, $0, [$0]) }, pinches: [], name: name)
        XCTAssertEqual(four.count, 3)
        // the order: a calibrate-first filament first (any send would be refused), then groups, then a pinch
        XCTAssertEqual(FlexibleCoreHold.kind(calibrateFirst: true, groups: 2, pinches: 1), .shapeOnly)
        XCTAssertEqual(FlexibleCoreHold.kind(calibrateFirst: false, groups: 2, pinches: 1), .squeezeGroups)
        XCTAssertEqual(FlexibleCoreHold.kind(calibrateFirst: false, groups: 1, pinches: 1), .pinch)
        XCTAssertNil(FlexibleCoreHold.kind(calibrateFirst: false, groups: 1, pinches: 0))
        // one line each on the pill (it is 300 pt at 10.5 pt)
        for k in [FlexibleCoreHold.Kind.pinch, .squeezeGroups] {
            XCTAssertLessThanOrEqual(FlexibleCoreHold.pill(k, shapeOnlyLabel: nil).count, 44)
        }
        // ★ the Preview pill is not the Ready pill's green
        XCTAssertNotEqual(FlexibleMainStatusPill.fill(.preview), FlexibleMainStatusPill.fill(.ready))
        XCTAssertEqual(FlexibleMainStatusPill.fill(.ready), FlexibleStageStyle.accentToken, "control: Ready is the green")
        XCTAssertEqual(FlexibleMainStatus(line: "x", tone: .preview, fix: nil).tap, .send, "its tap opens the Export step on it")
    }

    /// His project as saved: faces 3 and 5 pinch the pad. C2's pill read the green "Ready" and a
    /// tap ended on "Not sent" with nothing to do. Now the pill says what it is (a preview core
    /// can't take yet), and the Export step names the faces and offers each end.
    @MainActor
    func testHisPinchIsAPreviewAndTheStepSendsEitherEnd() async throws {
        let (_, stage, m) = try await hisBuilt()
        XCTAssertEqual(m.pinches.map { "\($0.a)|\($0.b)" }, ["3|5"], "premise: his faces 3 and 5 pinch the pad")
        let s = stage.status
        print("FLEX-C2V pinch: pill '\(s.line)' tone \(s.tone)")
        XCTAssertEqual(s.tone, .preview, "never the green Ready while core can't take it")
        XCTAssertEqual(s.line, FlexibleCoreHold.pill(.pinch, shapeOnlyLabel: nil))
        stage.pillTapped(s, open: { XCTFail("no Settings") }, goToLattice: { XCTFail("already there") })
        let run = stage.coreRun
        XCTAssertTrue(run.shown)
        XCTAssertEqual(run.runs, 0, "nothing core would refuse is sent")
        let a = m.displayName(3), b = m.displayName(5)
        XCTAssertEqual(run.line, "Not sent: core can\u{2019}t press \(a) and \(b) at once", "the faces, named")
        let fixes = try XCTUnwrap(run.hold?.fixes)
        print("FLEX-C2V pinch: step '\(run.line)' · (i) '\(run.info ?? "-")' · buttons \(fixes.map(\.title))")
        XCTAssertEqual(fixes.map(\.title), ["Send with \(b) resting", "Send with \(a) resting"])
        let all = m.settings.loadedFaces.map(\.faceRegionID).sorted()
        let settings = m.settings
        // [Send with Face 5 resting]
        run.onFix?(fixes[0])
        try await FlexibleHisProject.waitFor(180, "core's answer") { !run.isSending }
        XCTAssertEqual(run.runs, 1)
        guard case .ran(let rep1) = run.phase else { return XCTFail("core ran it: \(run.phase)") }
        XCTAssertEqual(try Self.pressed(try XCTUnwrap(run.sentJob)), all.filter { $0 != 5 }, "Face 5 rests in the job")
        XCTAssertTrue(run.line.contains("\(b) resting"), run.line)
        XCTAssertEqual(m.settings, settings, "his settings keep the pinch")
        XCTAssertFalse(m.pinches.isEmpty)
        print("FLEX-C2V pinch: [\(fixes[0].title)] → '\(run.line)' · (i) '\(run.info ?? "-")'")
        XCTAssertFalse((run.info ?? "").contains("/"), "no temp path he cannot open behind the (i)")
        // the pill again: that answer stands, both buttons stay
        stage.pillTapped(stage.status, open: {}, goToLattice: {})
        XCTAssertEqual(run.runs, 1, "the same answer is not asked twice")
        if case .ran = run.phase {} else { XCTFail("the answer stands: \(run.phase)") }
        XCTAssertEqual(run.hold?.fixes.count, 2)
        // the other end; the first run's temp folder is cleaned up
        run.onFix?(fixes[1])
        try await FlexibleHisProject.waitFor(180, "core's answer") { !run.isSending }
        XCTAssertEqual(run.runs, 2)
        XCTAssertEqual(try Self.pressed(try XCTUnwrap(run.sentJob)), all.filter { $0 != 3 })
        XCTAssertFalse(FileManager.default.fileExists(atPath: rep1.outDir), "the previous run's temp folder is deleted")
    }

    /// His img 4 (the sides in Group 2): each group alone — Group 2 with one end of its pinch resting.
    @MainActor
    func testTwoGroupsOfferEachGroupAlone() async throws {
        let (_, stage, m) = try await hisBuilt { m in
            _ = m.newGroup(with: 3)
            if let g2 = m.squeezeGroup(of: 3) { m.moveToGroup(5, g2.id) }
        }
        XCTAssertEqual(m.squeezeGroups.count, 2, "premise: two squeeze groups")
        let s = stage.status
        XCTAssertEqual(s.tone, .preview)
        XCTAssertEqual(s.line, FlexibleCoreHold.pill(.squeezeGroups, shapeOnlyLabel: nil))
        stage.pillTapped(s, open: { XCTFail("no Settings") }, goToLattice: {})
        let run = stage.coreRun
        XCTAssertEqual(run.runs, 0)
        XCTAssertEqual(run.line, FlexibleCoreRun.notSentLine(.squeezeGroups))
        let fixes = try XCTUnwrap(run.hold?.fixes)
        print("FLEX-C2V groups: \(m.squeezeGroups.map { m.groupLine($0) }) · pill '\(s.line)' · buttons \(fixes.map(\.title))")
        XCTAssertEqual(fixes.count, 2)
        XCTAssertTrue(fixes[0].title.hasPrefix("Send Group 1 only"))
        XCTAssertTrue(fixes[1].title.hasPrefix("Send Group 2 only"))
        let all = m.settings.loadedFaces.map(\.faceRegionID)
        for f in fixes {
            XCTAssertEqual(try Self.pressed(try m.runJobJSON(resting: Set(f.resting))), all.filter { !f.resting.contains($0) }.sorted(),
                           "\(f.title): core's own parser reads the faces it presses")
        }
        run.onFix?(fixes[1])
        try await FlexibleHisProject.waitFor(180, "core's answer") { !run.isSending }
        print("FLEX-C2V groups: [\(fixes[1].title)] → '\(run.line)'")
        XCTAssertEqual(run.runs, 1)
        if case .ran = run.phase {} else { XCTFail("core answered: \(run.phase)") }
        XCTAssertTrue(run.line.contains("Group 2 only"), run.line)
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
            XCTAssertEqual(note.midY, row.midY, accuracy: 0.5, "on the row's line at \(name)")
            XCTAssertLessThanOrEqual(note.maxX, row.minX - DS.Space.s + 0.5, "left of the three buttons at \(name)")
            XCTAssertGreaterThanOrEqual(note.width, 180, "room for 'Lattice ready · Show' at \(name)")
            XCTAssertFalse(note.intersects(FlexibleMainLegendLayout.leftStrip(viewport: v)), "clear of the left panel at \(name)")
            XCTAssertTrue(frame.contains(note))
            XCTAssertEqual(frame.maxY, row.maxY, accuracy: 0.5, "the keep-out ends where the row ends at \(name)")
            for chip: CGFloat in [0, 222] {
                let keep = FlexibleMainLegendLayout.keepOut(viewport: v, bottomClearance: 94, chipColumnWidth: chip)
                let placed = FlexibleMainLegendLayout.place(kinds, minimized: [], viewport: v, keepOut: keep)
                let rowOnly = FlexibleMainLegendLayout.place(kinds, minimized: [], viewport: v,
                                                              keepOut: keep.map { $0 == frame ? row : $0 })
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

    func testTheExportStepSaysTheWaitOnceAndUsesDSTokens() throws {
        let code = try FlexibleSource.code("FlexibleExportSheet.swift")
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
