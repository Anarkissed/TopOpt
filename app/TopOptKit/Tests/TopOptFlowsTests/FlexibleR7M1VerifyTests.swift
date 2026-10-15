// FlexibleR7M1VerifyTests — round 7 batch M1's VERIFY (2026-10-14): the findings the verify confirmed on his pad, written
// BEFORE the fixes (the red run: docs/handoffs/evidence/2026-09-29-flexible-screens/round7/batch_m1_verify/r7m1v_red_run.txt).
// Each test runs its RED CONTROL inside (the M1 build's behaviour it reverses). His pad is A1_0003 as saved (no face-prism)
// and with his live lattice (Group C = Face 3 + Face 5, Lattice at 25 mm) — FlexibleR7M1Fixtures.
//   V1  no face-prism: core's designs were still asked for and drove the Squish page's dent scale ("What you drew · 0 mm …
//       28.7 mm" over faces that show no dent); its top line said "Ready · No lattice under Face 1" with [Fix] → [Lattice under
//       all 4]. Now: no design, no dent scale, the one line, no [Fix], no pop-up at once.
//   V2  the main page's legend read "What you drew · 0 mm … 24.5 mm" (Face 3's SQUISH depth) while no lattice was drawn —
//       his img1 "they should *always* be equal", his answer "the squish number: only on the Squish page".
//   V3  [Prisms] drew nothing a pick did not — now every group's lattice face-prisms (the picked group's brighter); its legend
//       row and X-ray only when one is drawn.
//   V4  no face-prism: the pill said "Set a face to Lattice in Selections first" and its tap opened the Squish page's fix —
//       now disabled on the main page with its reason (ruling 4), and on another stage its tap goes to the Lattice stage.
//   V5  no face-prism: the lattice views (Heat, Stress, Lattice, [Prisms], Play) drawn unavailable, never lit.
//   V6  the Export line names the squeeze group by its NUMBER, never his Squish-page name (his answer: squish names are
//       just squish groups); 2+ face groups beside an edges group: "Each export makes one group only." said first.
import XCTest
import simd
@testable import TopOptFlows
@testable import TopOptKit

@MainActor
final class FlexibleR7M1VerifyTests: XCTestCase {
    typealias F = FlexibleR7M1Fixtures

    override func tearDown() async throws {
        FlexibleStageModel.controlDesignsWithoutPrism = false
        FlexibleMainStage.controlDrawnCurveOnMain = false
        FlexibleMainStage.controlPrismsPickedOnly = false
        FlexibleMainStage.controlNoPrismOpensSquishFix = false
        FlexibleMainStage.controlViewsAlwaysAvailable = false
        FlexibleCoreHold.controlSquishNameInExport = false
        FlexibleCoreHold.controlEdgesSilentlyDropped = false
        try await super.tearDown()
    }

    // MARK: - V1: no face-prism — nothing designed, no dent scale, the Squish page says the one line

    func testNoFacePrismShowsNothingOfCoresDesignsAndTheSquishPageSaysTheOneLine() async throws {
        let (_, _, m) = try await F.hisPad(self, live: false)
        XCTAssertFalse(m.facePrismsSet, "premise: his pad as saved sets no face-prism")
        XCTAssertFalse(m.settings.loadedFaces.isEmpty, "premise: his pressed faces")
        // (the red run's first expectation was "no design is asked of core"; changed after it: core's designs on a pad with no
        // face-prism are pinned by the goldens' C1 pad, so they are still ASKED — and shown NOWHERE: the reviewer's ruling on
        // the scene job decides whether the asks stop)
        XCTAssertFalse(m.designs.isEmpty, "premise: core's whole-part designs are asked (scene analysis, not a send)")
        XCTAssertNil(FlexibleFaceRows.warning(model: m, region: 1), "★ no 'Can't reach your curve on 4096 columns' from them")
        let shown = FlexibleShownValues(model: m)
        XCTAssertEqual(shown.maxDepth, 0, "★ no dent scale on the Squish page")
        XCTAssertFalse(shown.showsDent, "★ no dent drawn")
        let r = m.readiness
        XCTAssertEqual(r.oneLine, FlexibleRowCopy.noFacePrism, "★ the Squish page's top line: the one line, never 'Ready'")
        XCTAssertFalse(FlexibleSettingsExit.readyLine(r.oneLine, modified: true).contains("Ready"))
        XCTAssertNil(FlexibleStagePage.noticeFix(r, model: m), "★ no [Fix] to [Lattice under all N] on that line")
        let under = try XCTUnwrap(FlexibleLatticeUnder.first(r), "the per-face issue stays (each face's card)")
        XCTAssertFalse(FlexibleStagePage.popsAtOnce(under, model: m), "★ no pop-up at once with [Lattice under all N]")
        XCTAssertTrue(r.isReady, "nothing BLOCKS: Exit still leaves (his answer: an empty setup may exit)")
        // ★ RED CONTROL: the M1 build — core's whole-part designs, the drawn curve's scale, "Ready · …", the [Fix] and pop-up
        FlexibleStageModel.controlDesignsWithoutPrism = true
        m.recomputeAll()
        try await FlexibleHisProject.waitFor(120, "the control's designs") { !m.designs.isEmpty && !m.designsInFlight }
        await m.waitForIdle()
        let control = FlexibleShownValues(model: m)
        let controlLine = m.readiness.oneLine
        let controlFix = FlexibleStagePage.noticeFix(m.readiness, model: m)
        let controlPops = FlexibleLatticeUnder.first(m.readiness).map { FlexibleStagePage.popsAtOnce($0, model: m) } ?? false
        let controlWarning = FlexibleFaceRows.warning(model: m, region: 1)
        FlexibleStageModel.controlDesignsWithoutPrism = false
        XCTAssertGreaterThan(control.maxDepth, 20, "★ RED CONTROL: the whole-part designs' scale (the verify: 28.7 mm)")
        XCTAssertTrue(controlLine.hasPrefix("Ready"), "★ RED CONTROL: 'Ready · No lattice under …'")
        XCTAssertNotNil(controlFix, "★ RED CONTROL: [Fix]")
        XCTAssertTrue(controlPops, "★ RED CONTROL: the pop-up at once")
        XCTAssertEqual(controlWarning, "Can't reach your curve on 4096 columns", "★ RED CONTROL: the verify's orange line")
        print("FLEX-R7M1V-V1 no face-prism: designs \(m.designs.count) · shown max \(shown.maxDepth) dent \(shown.showsDent) · line '\(r.oneLine)' · control max \(control.maxDepth) line '\(controlLine)'")
    }

    // MARK: - V2: the main page never shows the drawn curve's number while no lattice is drawn

    func testTheMainPageNeverShowsTheDrawnCurvesNumberWhileNoLatticeIsDrawn() async throws {
        let (r, s, m) = try await F.hisPad(self, live: true)
        let p = r.project
        XCTAssertTrue(m.facePrismsSet, "premise: his live lattice")
        XCTAssertNil(m.lattice, "premise: no lattice drawn yet (it builds once the page shows)")
        XCTAssertEqual(m.settings.face(3)?.deepestMM, 24.5, "premise: Face 3's squish depth (the Squish page's number)")
        XCTAssertTrue(s.heat, "premise: Heat on (the default)")
        s.refresh()
        XCTAssertFalse(s.legendKinds.contains(.dent), "★ no dent row while no lattice is drawn")
        XCTAssertEqual(s.dentMaxMM, 0, "★ no squish number on the main page")
        XCTAssertNil(s.channels?.dents, "★ the drawn curve does not dent the main page's model")
        // ★ RED CONTROL: the M1 build — the drawn curve's scale in the legend ("What you drew · 0 mm … 24.5 mm")
        FlexibleMainStage.controlDrawnCurveOnMain = true
        s.refresh()
        let controlMax = s.dentMaxMM, controlKinds = s.legendKinds, controlTitle = s.legendTitle(.dent)
        FlexibleMainStage.controlDrawnCurveOnMain = false
        s.refresh()
        XCTAssertTrue(controlKinds.contains(.dent), "★ RED CONTROL: the dent row")
        // (the red run's first expectation, 24.5 — Face 3's own depth — was the verify's mid-rebuild picture; before the first
        // build the drawn curve's scale also takes core's design targets: 28.6 mm. Either is the Squish page's number.)
        XCTAssertGreaterThanOrEqual(controlMax, 24.5, "★ RED CONTROL: the drawn curve's scale on the main page (≥ Face 3's 24.5)")
        XCTAssertEqual(controlMax, FlexibleShownValues(model: m).maxDepth, accuracy: 1e-9, "★ RED CONTROL: the Squish page's scale")
        XCTAssertEqual(controlTitle, "What you drew · mm")
        // and once the lattice is drawn, the heat is the lattice's (the dent row returns)
        _ = try await FlexibleSquishFixture.build(m, "his live lattice")
        s.refresh()
        XCTAssertNotNil(m.lattice)
        XCTAssertTrue(s.legendKinds.contains(.dent), "the lattice's heat, once it is drawn")
        XCTAssertNotEqual(s.legendTitle(.dent), "What you drew · mm", "core's squish, not the drawing")
        _ = p
        print("FLEX-R7M1V-V2 before the lattice: kinds \(s.legendKinds) · control max \(controlMax) '\(controlTitle)'")
    }

    // MARK: - V3: [Prisms] = every group's lattice face-prisms; its row and X-ray only when one is drawn

    func testPrismsShowsEveryGroupsFacePrismsAndItsRowOnlyWhenOneIsDrawn() async throws {
        let (r, s, m) = try await F.hisPad(self, live: true)
        let p = r.project
        let c = try XCTUnwrap(p.selection.groups.first { $0.name == "Group C" })
        let top = try XCTUnwrap(p.selection.groups.first { $0.name == "Top" })
        XCTAssertTrue(s.volumes(p, on: .lattice, drilledIn: false).isEmpty, "nothing before a pick (his fixed rule)")
        // (the red run's premise "X-ray off" was wrong then: his None pad's X-ray started ON with a face-prism — R7-V's stopgap,
        // retired by X1: X-ray now starts off for every finish)
        s.togglePrisms()
        let all = s.volumes(p, on: .lattice, drilledIn: false)
        XCTAssertEqual(Set(all.map(\.volume.faceID)), [3, 5], "★ [Prisms] with nothing picked: every group's face-prisms (Group C's)")
        XCTAssertTrue(all.allSatisfy(\.selected), "nothing picked: every face-prism in #354's active look (faint ones hid under the heat)")
        XCTAssertTrue(s.legendPrismsRow, "its row: a face-prism is drawn")
        // ★ RE-PINNED (merge of X1 after M2 and F — his Q9 answer, 2026-10-14: "If the user adds x-ray, we see through the solid";
        // X-ray is HIS view, off on open for every finish): [Prisms] no longer turns X-ray on, even with a face-prism drawn (was
        // XCTAssertTrue — the M1 verify's "X-ray with it"; X1's `togglePrisms` taken in the merge, as X1's merge notes asked)
        XCTAssertFalse(s.xrayOn, "★ X1: [Prisms] leaves X-ray off (his view)")
        // the Top picked (Off in Selections): a pick alone draws nothing; [Prisms] still shows Group C's
        p.selection.setActive(top.id)
        let withTop = s.volumes(p, on: .lattice, drilledIn: false)
        XCTAssertEqual(Set(withTop.map(\.volume.faceID)), [3, 5], "★ [Prisms] shows what a pick does not")
        XCTAssertTrue(withTop.allSatisfy { !$0.selected }, "another group picked: Group C's fainter (#354's look for the rest)")
        m.views.remove(.prisms)
        XCTAssertTrue(s.volumes(p, on: .lattice, drilledIn: false).isEmpty, "the Top's pick alone: no face-prism")
        m.views.insert(.prisms)
        // Group C picked: its own brighter
        p.selection.setActive(c.id)
        let picked = s.volumes(p, on: .lattice, drilledIn: false)
        XCTAssertEqual(Set(picked.map(\.volume.faceID)), [3, 5])
        XCTAssertTrue(picked.allSatisfy(\.selected), "the picked group's face-prisms brighter (#354's active look)")
        // ★ RED CONTROL: the M1 build — [Prisms] = only the picked group's (nothing before a pick), its row anyway
        m.views.remove(.prisms)
        s.sessionPicked = false
        FlexibleMainStage.controlPrismsPickedOnly = true
        s.togglePrisms()
        let control = s.volumes(p, on: .lattice, drilledIn: false), controlRow = s.legendPrismsRow
        FlexibleMainStage.controlPrismsPickedOnly = false
        XCTAssertTrue(control.isEmpty, "★ RED CONTROL: nothing drawn before a pick")
        XCTAssertTrue(controlRow, "★ RED CONTROL: its legend row anyway")
        print("FLEX-R7M1V-V3 [Prisms] nothing picked \(all.map(\.volume.faceID)) · Group C picked selected \(picked.map(\.selected)) · control \(control.count) row \(controlRow)")
    }

    func testPrismsWithNoFacePrismDrawsNothingAndAddsNoRowNorXray() async throws {
        let (r, s, _) = try await F.hisPad(self, live: false)
        let p = r.project
        s.apply(p, owned: true, pageUp: false)
        await Task.yield()
        s.refresh()
        XCTAssertFalse(s.xrayOn, "premise: the plain model")
        s.togglePrisms()
        XCTAssertTrue(s.volumes(p, on: .lattice, drilledIn: false).isEmpty, "no face-prism anywhere: nothing")
        XCTAssertFalse(s.legendPrismsRow, "★ no legend row for violet that is not on screen")
        XCTAssertFalse(s.xrayOn, "★ no X-ray forced on the plain model")
        // ★ RED CONTROL: the M1 build — the row and X-ray anyway
        s.model?.views.remove(.prisms)
        FlexibleMainStage.controlPrismsPickedOnly = true
        s.controlViewsForceXray = true   // ★ RE-PINNED (X1 merge): the M1 build turned X-ray on with [Prisms] (R7-V's rule, X1's control)
        s.togglePrisms()
        let row = s.legendPrismsRow, xray = s.xrayOn
        FlexibleMainStage.controlPrismsPickedOnly = false
        s.controlViewsForceXray = false
        XCTAssertTrue(row && xray, "★ RED CONTROL: the row and X-ray with nothing drawn")
    }

    // MARK: - V4: no face-prism — the pill is disabled with its reason; it never opens the Squish page's fix

    func testNoFacePrismThePillIsDisabledWithItsReasonAndNeverOpensTheSquishFix() async throws {
        let (r, s, m) = try await F.hisPad(self, live: false)
        let p = r.project
        s.apply(p, owned: true, pageUp: false)
        try await FlexibleHisProject.waitFor(30, "the main page") { s.visible }
        s.refresh()
        let st = s.status
        XCTAssertEqual(st.line, FlexibleRowCopy.noFacePrism, "the stated reason")
        XCTAssertNotEqual(st.tap, .send, "never core")
        XCTAssertTrue(FlexibleMainStatusPill.disabled(st, visible: true), "★ disabled on the main page (ruling 4), its line the reason")
        var opened = false, went = false
        s.pillTapped(st, open: { opened = true }, goToLattice: { went = true })
        XCTAssertFalse(opened, "★ the Squish page does not open")
        XCTAssertNil(m.pendingFix, "★ no [Lattice under all N] pop-up queued")
        XCTAssertFalse(went, "already on the Lattice stage")
        // from another stage: the tap goes to the Lattice stage, where Selections is
        s.apply(p, owned: false, pageUp: false)
        try await FlexibleHisProject.waitFor(30, "off the main page") { !s.visible }
        XCTAssertFalse(FlexibleMainStatusPill.disabled(s.status, visible: false), "another stage: a tap target")
        s.pillTapped(s.status, open: { opened = true }, goToLattice: { went = true })
        XCTAssertTrue(went, "★ to the Lattice stage (Selections)")
        XCTAssertFalse(opened, "★ never the Squish page")
        XCTAssertNil(m.pendingFix)
        // ★ RED CONTROL: the M1 build — enabled, its tap opened the Squish page on [Lattice under all N]
        s.apply(p, owned: true, pageUp: false)
        try await FlexibleHisProject.waitFor(30, "the main page again") { s.visible }
        FlexibleMainStage.controlNoPrismOpensSquishFix = true
        let controlDisabled = FlexibleMainStatusPill.disabled(s.status, visible: true)
        var controlOpened = false
        s.pillTapped(s.status, open: { controlOpened = true })
        let controlFix = m.pendingFix
        FlexibleMainStage.controlNoPrismOpensSquishFix = false
        m.pendingFix = nil
        XCTAssertFalse(controlDisabled, "★ RED CONTROL: enabled")
        XCTAssertTrue(controlOpened, "★ RED CONTROL: the Squish page opened")
        XCTAssertEqual(controlFix?.kind, .noLatticeUnder, "★ RED CONTROL: on [Lattice under all N]")
    }

    // MARK: - V5: no face-prism — the lattice views are unavailable, never lit

    func testNoFacePrismTheLatticeViewsAreUnavailable() async throws {
        let (r, s, _) = try await F.hisPad(self, live: false)
        s.apply(r.project, owned: true, pageUp: false)
        await Task.yield()
        XCTAssertTrue(s.heat, "premise: the Heat flag is on (the default)")
        XCTAssertFalse(s.viewsAvailable, "★ Heat, Stress, Lattice, [Prisms] and Play: nothing to show")
        FlexibleMainStage.controlViewsAlwaysAvailable = true
        let control = s.viewsAvailable
        FlexibleMainStage.controlViewsAlwaysAvailable = false
        XCTAssertTrue(control, "★ RED CONTROL: the M1 build — lit and live on the plain model")
        // with his live lattice: available
        let (_, s2, _) = try await F.hisPad(self, live: true)
        XCTAssertTrue(s2.viewsAvailable, "a face-prism: the views are live")
    }

    // MARK: - V6: the Export names the squeeze group by its number; 2+ face groups beside an edges group

    func testTwoFaceGroupsBesideAnEdgesGroupEachExportMakesOneGroupSaidFirst() async throws {
        let (pm, stage, m, top) = try await padStage()
        let mesh = try XCTUnwrap(pm.viewerMesh)
        let px = FlexibleSquishFixture.face(mesh, axis: 0, value: 100), py = FlexibleSquishFixture.face(mesh, axis: 1, value: 100)
        let nx = FlexibleSquishFixture.face(mesh, axis: 0, value: 0)
        XCTAssertTrue(px >= 0 && py >= 0 && nx >= 0, "premise: the pad's sides")
        XCTAssertTrue(m.press(top, kg: 10))
        XCTAssertTrue(m.press(nx, kg: 5))
        XCTAssertNotNil(m.newGroup(with: nx), "the -X side: group 2 of its own")
        _ = try XCTUnwrap(m.addPress(regions: [px, py], direction: simd_normalize(SIMD3(1, 1, 0)), snap: nil, group: 3, kg: 5))
        try await FlexibleHisProject.waitFor(60, "the scene") { m.sceneState == .ready && m.openedKey == m.currentSceneKey }
        try await FlexibleSquishFixture.settle(m, "two face groups + an edge")
        XCTAssertEqual(m.squeezeGroups.map(\.kind), [.faces, .faces, .edges], "premise: two face groups beside an edges group")
        let run = stage.coreRun
        run.runner = { _, _, _, _ in FlexRunInfo(refusal: nil, receiptJSON: "{\"faces\":[{}],\"topology\":\"gyroid\"}", files: []) }
        XCTAssertEqual(m.coreHoldKind, .squeezeGroups)
        let hold = try XCTUnwrap(m.coreHold)
        XCTAssertEqual(hold.line, "Each export makes one group only.", "★ said before anything is sent")
        XCTAssertEqual(hold.note, FlexibleRowCopy.edgesExportSeparately)
        XCTAssertEqual(hold.fixes.map(\.title), ["Send Group 1 only", "Send Group 2 only"], "one button per face group")
        XCTAssertTrue(hold.why.contains("Group 3 (edges and corners) is not in this export"), "★ the edges group named behind the (i): \(hold.why)")
        stage.refresh()
        stage.pillTapped(stage.status, open: { XCTFail("a preview never opens Settings") })
        guard case .notSent(let line, _) = run.phase else { return XCTFail("said, not sent: \(run.phase)") }
        XCTAssertEqual(line, "Each export makes one group only.")
        XCTAssertEqual(run.runs, 0, "★ nothing is exported before his tap")
        // ★ RED CONTROL: the edges group not counted — the plain squeeze-groups line, no note
        FlexibleCoreHold.controlEdgesSilentlyDropped = true
        let control = m.coreHold
        FlexibleCoreHold.controlEdgesSilentlyDropped = false
        XCTAssertEqual(control?.line, FlexibleCoreRun.notSentLine(.squeezeGroups), "★ RED CONTROL: the edges group dropped unsaid")
        XCTAssertNil(control?.note, "★ RED CONTROL: no note")
        print("FLEX-R7M1V-V6 '\(hold.line)' / '\(hold.note ?? "-")' · \(hold.fixes.map(\.title)) · control '\(control?.line ?? "-")'")
    }

    func testTheExportNamesTheSqueezeGroupByItsNumberNeverItsSquishName() async throws {
        let (pm, _, m, top) = try await padStage()
        let mesh = try XCTUnwrap(pm.viewerMesh)
        let px = FlexibleSquishFixture.face(mesh, axis: 0, value: 100), py = FlexibleSquishFixture.face(mesh, axis: 1, value: 100)
        XCTAssertTrue(m.press(top, kg: 10))
        _ = try XCTUnwrap(m.addPress(regions: [px, py], direction: simd_normalize(SIMD3(-1, -1, 0)), snap: nil, group: 2, kg: 5))
        try await FlexibleHisProject.waitFor(60, "the scene") { m.sceneState == .ready && m.openedKey == m.currentSceneKey }
        try await FlexibleSquishFixture.settle(m, "the pad + an edge")
        let g1 = try XCTUnwrap(m.squeezeGroups.first)
        m.setGroupName(g1.id, "Thumbs")
        XCTAssertEqual(m.groupName(g1), "Thumbs", "premise: his Squish-page name")
        let hold = try XCTUnwrap(m.coreHold)
        XCTAssertEqual(hold.line, "This export makes Group 1 only.", "★ the squeeze group's number (his answer: squish names stay on the Squish page)")
        XCTAssertEqual(hold.fixes.first?.title, "Send Group 1 only", "the same as the other [Send Group N only] buttons")
        XCTAssertFalse(hold.why.contains("Thumbs"))
        // ★ RED CONTROL: the M1 build — his Squish-page name in the Export line
        FlexibleCoreHold.controlSquishNameInExport = true
        let control = m.coreHold?.line
        FlexibleCoreHold.controlSquishNameInExport = false
        XCTAssertEqual(control, "This export makes Thumbs only.", "★ RED CONTROL: the squish name on the main page's Export")
    }

    // MARK: - fixtures

    /// C1's pad with a face-prism under the top (ruling 4), on a main stage.
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
}
