// FlexibleMainPageRound4Tests — batch C2 of round 4: the MAIN Flexible page after his notes on
// batches A + B (task 2026-09-29-flexible-screens). His words:
//   img 5: "there's a bit of a confusion regarding the xray and lattice view - they both seem to
//          require one another … Please remove the xray view selector if the lattice view is
//          going to use the rendering anyways."
//   img 6: "When I clicked Lattice after already having a lattice preview, it brought me to the
//          settings page … I don't understand why?"
//   answer 2: "the large bottom buttons are for exports and starting the actual core process. So
//          when Lattice Ready shows, tapping it should send to Core and the export path. The
//          lattice VIEW button should show/hide the lattice and a notification should show up
//          when it is ready - however, tapping it without setting up the settings should take you
//          to the settings screen where exiting should automatically show the view."
//
// Each comparison carries a positive control that goes RED on the rule it replaces (inline, or a
// mutation run recorded in the handoff).
import XCTest
import simd
@testable import TopOptFlows
@testable import TopOptKit

final class FlexibleMainPageRound4Tests: XCTestCase {

    // MARK: helpers

    /// The plain pad as a Flexible part (varioShore, nothing pressed), with a main stage over it
    /// that the main page shows (`apply` — what the page's `layer` hook does off the update).
    @MainActor
    private func padStage() async throws -> (ProjectModel, FlexibleMainStage, FlexibleStageModel, Int) {
        let pm = try FlexibleHisProject.padProject(FlexibleStageSettings(materialID: "varioshore_tpu"))
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

    @MainActor
    private func hisStage() throws -> (FlexibleHisProject.Restored, FlexibleMainStage, FlexibleStageModel) {
        let r = try FlexibleHisProject.restore()
        addTeardownBlock { r.cleanup() }
        let stage = FlexibleMainStage()
        stage.reduceMotion = { true }
        let m = stage.model(for: r.project, materialsPath: FlexibleHisProject.materialsPath,
                            stampsPath: FlexibleHisProject.stampsPath, persist: {})
        addTeardownBlock { @MainActor in await m.waitForIdle() }
        return (r, stage, m)
    }

    // MARK: img 5 — no X-ray selector; the Lattice view IS the X-ray

    func testTheViewRowHasNoXRayButton() throws {
        XCTAssertEqual(FlexibleMainViewToggles.buttons, 3, "Dent heat · Stress · Lattice")
        let code = try FlexibleSource.code("FlexibleMainStatusPill.swift")
        XCTAssertFalse(code.contains("flexible-main-view-xray"), "no X-ray button on the main page")
        XCTAssertFalse(code.contains("label: \"X-ray\""))
        XCTAssertFalse(code.contains("main.xray.toggle()"))
        for id in ["flexible-main-view-heat", "flexible-main-view-stress", "flexible-main-view-lattice"] {
            XCTAssertTrue(code.contains(id), "\(id) stays")
        }
        // the Lattice button asks the stage (it may open Settings), never a bare toggle
        XCTAssertTrue(code.contains("main.latticeButtonTapped(openSettings: openSettings)"))
        XCTAssertFalse(code.contains("{ main.toggleLattice() }"))
    }

    /// The main page's X-ray rendering follows the Lattice view — on together, off together.
    @MainActor
    func testTheLatticeViewIsTheXRayRendering() throws {
        let pm = try FlexibleHisProject.padProject(FlexibleStageSettings(materialID: "varioshore_tpu"))
        let stage = FlexibleMainStage()
        XCTAssertTrue(stage.latticeOn, "premise: the view is on by default")
        for on in [true, false, true] {
            if stage.latticeShown != on { stage.toggleLattice() }
            XCTAssertEqual(stage.latticeShown, on)
            XCTAssertEqual(stage.xray, stage.latticeShown, "X-ray is the Lattice view's rendering")
            XCTAssertEqual(stage.bodyAlpha(pm, on: .lattice), on ? FlexibleStagePage.xrayBodyAlpha : 1,
                           on ? "the lattice shows through the ghosted part" : "the lattice hidden: the solid part")
        }
    }

    // MARK: answer 2 — the Lattice VIEW button

    /// Nothing to show (no pressed face): the Lattice button opens Settings; Save & Exit turns
    /// the view on, and the lattice shows. With a lattice, the button shows / hides it and never
    /// opens Settings.
    @MainActor
    func testTheLatticeButtonOpensSettingsWhenNothingCanShowAndExitShowsIt() async throws {
        let (pm, stage, m, top) = try await padStage()
        XCTAssertEqual(m.readiness.blocking.first?.kind, .noPressedFace, "premise: nothing pressed")
        XCTAssertFalse(stage.latticeAvailable, "no lattice can come without Settings")
        XCTAssertFalse(stage.latticeShown, "the button is not lit: there is nothing to show")
        XCTAssertFalse(stage.xray)
        XCTAssertEqual(stage.bodyAlpha(pm, on: .lattice), 1, "the solid part, not an empty ghost")
        // ★ RED CONTROL: batch C's button was a bare toggle — nothing he can see changes, and
        // Settings never opens (the view flips on a lattice that does not exist)
        stage.toggleLattice(); stage.toggleLattice()
        XCTAssertFalse(stage.latticeShown, "control: a bare toggle shows nothing")
        // he had turned the view off; now he taps it with nothing set up
        stage.latticeOn = false
        var opened = 0
        stage.latticeButtonTapped(openSettings: { opened += 1 })
        XCTAssertEqual(opened, 1, "nothing set up: the tap opens Settings")
        XCTAssertFalse(stage.latticeOn, "the tap changes no view by itself")
        // in Settings he presses the top; Save & Exit
        XCTAssertTrue(m.press(top, kg: 10))
        stage.didExitSettings()
        XCTAssertTrue(stage.latticeOn, "Exit turned the view on")
        XCTAssertTrue(stage.latticeShown, "…and it shows: the lattice is on its way")
        try await FlexibleHisProject.waitFor(120, "the pad's lattice") { m.lattice != nil || m.latticeError != nil }
        await m.waitForIdle()
        XCTAssertNil(m.latticeError)
        stage.refresh()
        XCTAssertTrue(stage.latticeShown && stage.xray)
        XCTAssertEqual(stage.bodyAlpha(pm, on: .lattice), FlexibleStagePage.xrayBodyAlpha)
        XCTAssertEqual(stage.layer(pm, stage: .lattice, pageUp: false)?.hidden, false, "the walls are drawn")
        // with a lattice: show / hide, never Settings
        stage.latticeButtonTapped(openSettings: { opened += 1 })
        XCTAssertFalse(stage.latticeShown, "hidden")
        XCTAssertEqual(stage.bodyAlpha(pm, on: .lattice), 1)
        XCTAssertEqual(stage.layer(pm, stage: .lattice, pageUp: false)?.hidden, true, "the walls are not drawn")
        stage.latticeButtonTapped(openSettings: { opened += 1 })
        XCTAssertTrue(stage.latticeShown, "shown again")
        XCTAssertEqual(opened, 1, "a lattice to show never opens Settings (his img 6)")
        // an Exit that did NOT come from the view button keeps his choice
        stage.latticeOn = false
        stage.didExitSettings()
        XCTAssertFalse(stage.latticeOn, "only the view button's trip to Settings turns the view on")
    }

    // MARK: answer 2 — the notification when it is ready

    @MainActor
    func testALatticeReadyNoteShowsOnceWhenABuildLands() async throws {
        let (_, stage, m, top) = try await padStage()
        XCTAssertTrue(m.press(top, kg: 10))
        stage.note.seconds = 30
        stage.didExitSettings()
        XCTAssertNil(stage.note.kind, "nothing is ready yet")
        try await FlexibleHisProject.waitFor(120, "the lattice") { m.lattice != nil || m.latticeError != nil }
        try await FlexibleHisProject.waitFor(5, "the note") { stage.note.kind != nil }
        XCTAssertEqual(stage.note.kind, .ready)
        XCTAssertEqual(FlexibleMainNote.line(.ready), "Lattice ready")
        XCTAssertEqual(stage.note.posts, 1)
        stage.refresh(); stage.refresh()
        XCTAssertEqual(stage.note.posts, 1, "once per build, not per refresh")
        // ★ RED CONTROL: a stage that did not see the build (the same lattice, shown afresh) posts
        // nothing — the note is keyed on a build landing, not on a lattice being there
        let other = FlexibleMainStage()
        _ = other.model(for: m.project, materialsPath: FlexibleHisProject.materialsPath, stampsPath: nil, persist: {})
        other.refresh()
        XCTAssertEqual(other.note.posts, 0, "control: no build seen, no note")
        // hidden when the next build lands: the note offers [Show]
        stage.note.clear()
        stage.latticeOn = false
        m.setWeight(top, kg: 12)
        try await FlexibleHisProject.waitFor(120, "the rebuild") {
            stage.note.posts == 2 || m.latticeError != nil
        }
        XCTAssertEqual(stage.note.kind, .ready)
        XCTAssertFalse(stage.latticeShown, "premise: he had hidden it")
        stage.showFromNote()
        XCTAssertTrue(stage.latticeShown, "[Show] shows it")
        XCTAssertNil(stage.note.kind, "…and the note goes")
    }

    // MARK: img 6 / answer 2 — the big bottom Lattice button

    @MainActor
    func testThePillSendsWhenReadyAndOpensSettingsOnlyToFix() throws {
        let ready = FlexibleMainStatus(line: FlexibleMainStatus.ready, tone: .ready, fix: nil)
        XCTAssertEqual(ready.tap, .send, "Lattice Ready: send to core and the export path")
        XCTAssertEqual(FlexibleMainStatus(line: FlexibleMainStatus.building, tone: .building, fix: nil).tap, .wait,
                       "building: nothing opens (his img 6)")
        XCTAssertEqual(FlexibleMainStatus(line: "Fix: press the face that carries weight", tone: .fix, fix: nil).tap, .openSettings)
        XCTAssertEqual(FlexibleMainStatus.of(model: nil).tap, .openSettings, "never opened: the stage and Settings")
        // while core runs, the pill says so and a tap shows the run
        let sending = ready.whileSending(true)
        XCTAssertEqual(sending.line, FlexibleMainStatus.sending)
        XCTAssertEqual(sending.tap, .send)
        XCTAssertEqual(ready.whileSending(false), ready)
        let pill = try FlexibleSource.code("FlexibleMainStatusPill.swift")
        XCTAssertTrue(pill.contains("main.pillTapped(s, open: open)"), "the pill asks the stage what its tap does")
        // ★ RED CONTROL: batch B's pill — every tap opened Settings, a ready lattice included
        XCTAssertFalse(pill.contains("if s.fix != nil { main.openFix() }\n            open()"),
                       "control: the old body opened Settings on every tap")
    }

    /// Ready on a part core can run: the SAME job document goes to core's own Flexible runner
    /// (`run_flexible_job`), beside the part, off the main thread; the Export step opens on its
    /// answer. The other sections' path refuses this job.
    @MainActor
    func testReadySendsTheJobToCoresFlexibleRunner() async throws {
        let (pm, stage, m, top) = try await padStage()
        XCTAssertTrue(m.press(top, kg: 10))
        stage.didExitSettings()
        try await FlexibleHisProject.waitFor(120, "the lattice") { m.lattice != nil || m.latticeError != nil }
        await m.waitForIdle()
        stage.refresh()
        XCTAssertEqual(stage.status.tone, .ready, "premise: Lattice · Ready")
        let run = stage.coreRun
        let t0 = Date()
        stage.pillTapped(stage.status, open: { XCTFail("a ready lattice never opens Settings") })
        XCTAssertTrue(run.shown, "the export step opens at once")
        XCTAssertEqual(run.phase, .sending)
        XCTAssertEqual(run.line, FlexibleCoreRun.sendingLine)
        XCTAssertEqual(stage.status.whileSending(run.isSending).line, FlexibleMainStatus.sending)
        try await FlexibleHisProject.waitFor(180, "core's answer") { !run.isSending }
        let secs = Date().timeIntervalSince(t0)
        guard case .ran(let rep) = run.phase else { return XCTFail("core ran it: \(run.phase)") }
        print("FLEX-CORE pad: '\(run.line)' in \(String(format: "%.2f", secs)) s · files \(rep.files.count): \(rep.files.prefix(8)) · out \(rep.outDir)")
        XCTAssertNil(rep.refusal, "varioShore on the pad's top: core designs it")
        XCTAssertEqual(rep.faces, 1)
        XCTAssertNotNil(rep.topology)
        XCTAssertTrue(rep.files.contains("run_info.json"), "core's own record")
        XCTAssertTrue(rep.files.contains("face\(top)_density.svg"), "core's heat maps for the pressed face")
        XCTAssertTrue(FileManager.default.fileExists(atPath: (rep.outDir as NSString).appendingPathComponent("run_info.json")))
        XCTAssertTrue(run.line.hasPrefix("Core designed it"), run.line)
        XCTAssertEqual(FlexibleCoreRun.exportsWait, "Waits on core\u{2019}s Flexible exporter")
        XCTAssertEqual(run.runs, 1)
        // the same job again: its answer stands (no second run)
        run.close()
        XCTAssertFalse(run.shown)
        stage.pillTapped(stage.status, open: {})
        XCTAssertTrue(run.shown)
        XCTAssertEqual(run.runs, 1, "the same job is not sent twice")
        // ★ RED CONTROL: the OTHER sections' Lattice path (RunModel.latticeBridgeRunner →
        // TopOptKit.runLatticeJob → core's lattice_variant_job) refuses this job
        let job = try m.runJobJSON()
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("flex-c2-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let jobURL = dir.appendingPathComponent("job.json")
        try job.write(to: jobURL, atomically: true, encoding: .utf8)
        let core = FlexibleHisProject.repoRoot.appendingPathComponent("core")
        XCTAssertThrowsError(try TopOptKit.runLatticeJob(
            jobPath: jobURL.path, jobDir: (try XCTUnwrap(pm.importedFile).path as NSString).deletingLastPathComponent,
            outDir: dir.appendingPathComponent("out").path,
            materialsPath: core.appendingPathComponent("src/materials/materials.json").path,
            rulesPath: core.appendingPathComponent("src/settings/rules.json").path)) { e in
            print("FLEX-CORE control: the other sections' runner says '\(e)'")
        }
    }

    /// What core cannot run yet (a pinch, several squeeze groups) is said in one line and never
    /// sent; with the pinch undone the same tap sends it, and core's answer comes back.
    @MainActor
    func testWhatCoreCannotRunIsSaidNotSent() async throws {
        let (_, stage, m) = try hisStage()
        m.openScene()
        try await FlexibleHisProject.waitFor(60, "his scene and stacks") {
            m.sceneState == .ready && m.loadedKeys.allSatisfy { m.stacks[$0] != nil }
        }
        await m.waitForIdle()
        XCTAssertFalse(m.pinches.isEmpty, "premise: his faces 3 and 5 pinch the pad")
        let run = stage.coreRun
        run.send(m)
        XCTAssertTrue(run.shown)
        guard case .notSent(let line, let why) = run.phase else { return XCTFail("not sent: \(run.phase)") }
        print("FLEX-CORE his project as saved: '\(line)' · (i) '\(why)'")
        XCTAssertEqual(line, FlexibleCoreRun.notSentLine(.pinch))
        XCTAssertEqual(run.runs, 0, "nothing reached core")
        // ★ POSITIVE CONTROL: face 5 rests — the same tap sends it (the counter can move)
        m.rest(5)
        await m.waitForIdle()
        run.send(m)
        try await FlexibleHisProject.waitFor(180, "core's answer") { !run.isSending }
        XCTAssertEqual(run.runs, 1, "control: sent once the pinch is gone")
        print("FLEX-CORE his project, face 5 resting: '\(run.line)' · (i) '\(run.info ?? "-")'")
        switch run.phase {
        case .ran: break
        default: XCTFail("core answered: \(run.phase)")
        }
    }

    /// A calibrate-first filament: the page's lattice is shape-only (D-R3-12) and its pill reads
    /// Ready; sent, core's own runner refuses it — said in one line, core's sentence behind (i).
    @MainActor
    func testACalibrateFirstFilamentIsCoresRefusalInOneLine() async throws {
        let pm = try FlexibleHisProject.padProject(FlexibleStageSettings(materialID: "tpu95a_generic"))
        let stage = FlexibleMainStage()
        stage.reduceMotion = { true }
        let m = stage.model(for: pm, materialsPath: FlexibleHisProject.materialsPath, stampsPath: nil, persist: {})
        addTeardownBlock { @MainActor in await m.waitForIdle() }
        stage.apply(pm, owned: true, pageUp: false)
        try await FlexibleHisProject.waitFor(60, "the pad's scene") { m.sceneState == .ready }
        XCTAssertTrue(m.press(FlexibleHisProject.topFace(try XCTUnwrap(pm.viewerMesh)), kg: 10))
        stage.didExitSettings()
        try await FlexibleHisProject.waitFor(120, "the shape-only lattice") { m.lattice != nil || m.latticeError != nil }
        await m.waitForIdle()
        XCTAssertEqual(stage.status.tone, .ready, "premise: the pill reads Ready (\(stage.status.line))")
        stage.pillTapped(stage.status, open: { XCTFail("Ready never opens Settings") })
        try await FlexibleHisProject.waitFor(120, "core's answer") { !stage.coreRun.isSending }
        guard case .ran(let rep) = stage.coreRun.phase, let refusal = rep.refusal else {
            return XCTFail("core refuses a calibrate-first filament: \(stage.coreRun.phase)")
        }
        print("FLEX-CORE TPU 95A: '\(stage.coreRun.line)' · code \(refusal.code) · (i) '\(stage.coreRun.info ?? "-")'")
        XCTAssertEqual(stage.coreRun.line, "Core refused it: no squish data for this filament yet", "one short line")
        // ★ CONTROL: core's own sentence is far too long for one line (it names five brands)
        XCTAssertGreaterThan(refusal.reason.count, 80)
        XCTAssertEqual(stage.coreRun.info, "\(refusal.reason) (\(refusal.code))", "core's whole sentence behind the (i)")
        XCTAssertNil(rep.topology, "nothing chosen on a refusal")
    }

    func testNotSentLinesAreOneShortLineEach() {
        for e: FlexibleJob.EncodeError in [.noFilament, .noLoadedFace, .squeezeGroups, .pinch, .missingStampGrid(UUID())] {
            let l = FlexibleCoreRun.notSentLine(e)
            XCTAssertTrue(l.hasPrefix("Not sent: "), l)
            XCTAssertLessThanOrEqual(l.count, 56, "one line: '\(l)'")
        }
    }

    // MARK: the export step

    func testTheExportStepSaysTheExportsWaitOnCoreInOneLine() throws {
        let code = try FlexibleSource.code("FlexibleExportSheet.swift")
        XCTAssertTrue(code.contains("Text(FlexibleCoreRun.exportsWait)"), "each card's one line")
        XCTAssertTrue(code.contains("Text(run.line)"), "core's answer in one line")
        XCTAssertFalse(code.contains("The part with its lattice, one closed solid"), "no second line on a card")
        XCTAssertTrue(code.contains("public struct FlexibleExportMount: View"))
    }

    // MARK: the note's place

    /// The note sits under the view row, inside the frame every legend and the player keep out of
    /// (reserved, so a note coming and going never moves a legend).
    func testTheNoteBandIsReservedUnderTheViewRow() {
        let viewports: [(String, CGSize)] = [("13l", CGSize(width: 1376, height: 1032)), ("13p", CGSize(width: 1032, height: 1376)),
                                             ("11l", CGSize(width: 1194, height: 834)), ("11p", CGSize(width: 834, height: 1194))]
        for (name, v) in viewports {
            let f = FlexibleMainViewToggles.frame(viewport: v), n = FlexibleMainViewToggles.noteFrame(viewport: v)
            XCTAssertTrue(f.contains(n), "the note band is inside the reserved frame at \(name)")
            XCTAssertEqual(n.maxX, v.width - PageChrome.edge, accuracy: 0.5, "trailing, under the row")
            let keep = FlexibleMainLegendLayout.keepOut(viewport: v, bottomClearance: 94, chipColumnWidth: 0)
            let placed = FlexibleMainLegendLayout.place([.dent, .stress, .lattice], minimized: [], viewport: v, keepOut: keep)
            for (k, p) in placed { XCTAssertFalse(p.frame.intersects(n), "the \(k) legend clears the note at \(name)") }
            print("FLEX-NOTE \(name): row+note \(f.integral) · note \(n.integral) · legends \(placed.map { "\($0.key.rawValue) \($0.value.frame.integral) \($0.value.expanded ? "open" : "pill")" }.sorted())")
            // ★ RED CONTROL: batch C's frame (the row alone) does not hold the note
            let rowOnly = CGRect(x: f.minX, y: f.minY, width: f.width, height: 40)
            XCTAssertFalse(rowOnly.contains(n), "control: the row-only frame leaves the note unreserved")
        }
    }

    // MARK: the #354 hooks

    func testTheHooksAreInPlace() throws {
        let ws = try FlexibleSource.text("WorkspacePlaceholder.swift")
        let pins = [
            "if flexibleMain.owns(project, stage) { FlexibleMainViewToggles(main: flexibleMain, solver: FlexibleStressSolver(app: model, sim: latticeSim), openSettings: { showFlexiblePage = true }) }",
            "if project.lattice.flexible != nil { FlexibleExportMount(run: flexibleMain.coreRun).zIndex(48) }",
        ]
        for p in pins { XCTAssertEqual(ws.components(separatedBy: p).count - 1, 1, "exactly once: \(p)") }
        // H10 is untouched: the pill's own body decides (send / Settings / wait)
        XCTAssertTrue(ws.contains("FlexibleMainStatusPill(main: flexibleMain, open: { if stage != .lattice { goToStage(.lattice) }; showFlexiblePage = true })"))
        // #354's octet Lattice run is untouched
        XCTAssertTrue(ws.contains("private func requestLatticeRun() {\n        guard canLatticeThis else { return }"))
    }
}
