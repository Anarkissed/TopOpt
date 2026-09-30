// FlexibleBatchBReviewUXTests — the batch B review's page findings, on values (task
// 2026-09-29-flexible-screens, round 3 batch B verification). His rules: blockers surface AT
// ONCE as a pop-up that selects the face, with 1–3 fix buttons; legends and lines never cover
// buttons. Each comparison carries its RED control inline (the old rule, shown to fail).
//   * every blocking issue has 1–3 fixes — "no pressed face" with nothing selected offers the
//     face that faces up; "no filament" with no data offers any filament;
//   * the pop-up shows the issue as it is NOW (it kept the value it opened with);
//   * a blocker already standing when Settings opens pops once, when the scene settles;
//   * the top line and the pop-up clear the Exit row and the gizmo at every iPad width;
//   * a shared stack is seen obliquely (both faces), not face-on to one of them;
//   * the shape-only timeline ends "As drawn"; the pill reads whole and never says "Lattice"
//     twice; a toast clears itself with no page up; the Lattice view turns X-ray on; the
//     main page's player clears the bottom-right chip column.
import XCTest
import simd
@testable import TopOptFlows
@testable import TopOptKit
import TopOptDesign

final class FlexibleBatchBReviewUXTests: XCTestCase {

    private func face(_ r: Int, kg: Double = 10, design: FlexibleReadiness.DesignState = .ok,
                      stacked: Bool = true, stackError: String? = nil) -> FlexibleReadiness.Face {
        FlexibleReadiness.Face(region: r, weightKg: kg, stacked: stacked, stackError: stackError, design: design,
                               drawn: true, areaMM2: 100)
    }

    private func inputs(_ faces: [FlexibleReadiness.Face], material: String? = "varioshore_tpu",
                        withData: (id: String, name: String)? = (id: "varioshore_tpu", name: "colorFabb varioShore TPU"),
                        anyFilament: (id: String, name: String)? = (id: "tpu95a_generic", name: "TPU 95A"),
                        selected: Int? = nil, suggested: Int? = nil) -> FlexibleReadiness.Inputs {
        FlexibleReadiness.Inputs(materialID: material, materialName: "colorFabb varioShore TPU (foaming)",
                                 calibrateFirst: false, withData: withData, pressed: faces,
                                 nozzleIsAuto: true, topologyIsGyroid: true, selected: selected,
                                 anyFilament: anyFilament, suggested: suggested)
    }

    // MARK: every blocker has a button

    func testEveryBlockingIssueHasOneToThreeFixes() {
        let cases: [(String, FlexibleReadiness.Inputs)] = [
            ("no filament", inputs([face(1)], material: nil)),
            ("no filament, none with data", inputs([face(1)], material: nil, withData: nil)),
            ("no pressed face, nothing selected", inputs([], suggested: 7)),
            ("no pressed face, one selected", inputs([], selected: 4, suggested: 7)),
            // ★ RE-PINNED (round 4 D2): "shared stack" is no blocker any more (a pinch builds) — gone from this list
            ("no stack", inputs([face(2, stacked: false, stackError: "no lattice under it")])),
            ("no weight", inputs([face(2, kg: 0)])),
            ("refused", inputs([face(2, design: .refused(code: "no_pressure", reason: "x"))])),
            ("design failed", inputs([face(2, design: .failed("threw"))])),
        ]
        for (what, i) in cases {
            let r = FlexibleReadiness.evaluate(i)
            XCTAssertFalse(r.blocking.isEmpty, "premise: \(what) blocks")
            for issue in r.blocking {
                XCTAssertTrue((1...3).contains(issue.fixes.count), "\(what): \(issue.oneLine) has \(issue.fixes.count) fixes")
                XCTAssertLessThanOrEqual(issue.pill.count, 44, "\(what): the pill reads whole — \(issue.pill)")
            }
        }
        let none = FlexibleReadiness.evaluate(inputs([], suggested: 7)).blocking[0]
        XCTAssertEqual(none.fixes, [.press(7)], "nothing selected: [Press] the face that faces up")
        XCTAssertEqual(none.region, 7, "…and the pop-up selects it")
        XCTAssertEqual(FlexibleReadiness.evaluate(inputs([], selected: 4, suggested: 7)).blocking[0].fixes, [.press(4)],
                       "his selection wins over the suggestion")
        XCTAssertEqual(FlexibleReadiness.evaluate(inputs([face(1)], material: nil, withData: nil)).blocking[0].fixes,
                       [.pickFilament(id: "tpu95a_generic", name: "TPU 95A")], "no filament with data: any filament (shape only)")
        // with no catalogue at all there is nothing to pick: Exit is not held on it
        XCTAssertTrue(FlexibleReadiness.evaluate(inputs([face(1)], material: nil, withData: nil, anyFilament: nil)).isReady)
        // ★ RED CONTROL: the old rule — nothing selected, no suggestion — had NO button
        XCTAssertEqual(FlexibleReadiness.evaluate(inputs([])).blocking[0].fixes.count, 0,
                       "control: without a suggestion the pop-up had no button")
    }

    /// The face that most likely carries weight: the most area facing up (the box's top), the
    /// bottom when gravity points up, a side when it points sideways.
    func testTheSuggestedFaceIsTheOneFacingUp() throws {
        // the fixture box is wound INWARD (the wizard sample's windings); an imported part is
        // wound outward (ViewerMesh.faceNormal's rule, and his pad below) — so wind it outward
        let raw = FlexibleLatticeFixtures.boxMesh().mesh
        var idx: [Int32] = []
        for t in 0..<raw.triangleCount { idx += [Int32(raw.indices[3 * t]), Int32(raw.indices[3 * t + 2]), Int32(raw.indices[3 * t + 1])] }
        let box = ViewerMesh(vertices: raw.positions, indices: idx, faceIDs: raw.faceIDs)
        XCTAssertEqual(FlexibleReadiness.suggestedFace(mesh: box, up: SIMD3(0, 0, 1))?.face, 1, "the top")
        XCTAssertEqual(FlexibleReadiness.suggestedFace(mesh: box, up: SIMD3(0, 0, -1))?.face, 0, "the bottom")
        XCTAssertEqual(FlexibleReadiness.suggestedFace(mesh: box, up: SIMD3(1, 0, 0))?.face, 3, "x = hi")
        let c = try XCTUnwrap(FlexibleReadiness.suggestedFace(mesh: box, up: SIMD3(0, 0, 1))?.centroid)
        XCTAssertEqual(c.z, 20.25, accuracy: 1e-4, "the centroid lies on the face (a split face resolves by it)")
        // ★ CONTROL: the rule reads the winding — the inward box answers the opposite face
        XCTAssertEqual(FlexibleReadiness.suggestedFace(mesh: raw, up: SIMD3(0, 0, 1))?.face, 0)
    }

    /// On a real part with no main-page load and nothing selected: [Press] the pad's top.
    @MainActor
    func testNoPressedFaceOffersThePadsTop() throws {
        let pm = try FlexibleHisProject.padProject(FlexibleStageSettings(materialID: "varioshore_tpu"))
        let m = FlexibleStageModel(project: pm, materialsPath: FlexibleHisProject.materialsPath, stampsPath: nil, persist: {})
        let mesh = try XCTUnwrap(pm.viewerMesh)
        let top = FlexibleHisProject.topFace(mesh)
        let issue = try XCTUnwrap(m.readiness.blocking.first)
        print("FLEX-REVIEW no load: '\(issue.oneLine)' fixes \(issue.fixes) (top face \(top))")
        XCTAssertEqual(issue.kind, .noPressedFace)
        XCTAssertEqual(issue.fixes, [.press(top)])
        XCTAssertEqual(issue.oneLine, "Press Face \(top) or tap the face that carries weight")
    }

    // MARK: the pop-up

    func testThePopUpShowsTheIssueAsItIsNow() throws {
        // opened with nothing selected and (the old rule) no suggestion: no button
        let opened = try XCTUnwrap(FlexibleReadiness.evaluate(inputs([])).blocking.first)
        XCTAssertTrue(opened.fixes.isEmpty, "premise: the value the pop-up was opened with")
        // he taps face 3, as it said
        let now = FlexibleReadiness.evaluate(inputs([], selected: 3))
        let live = try XCTUnwrap(FlexibleFixPrompt.live(opened, in: now))
        XCTAssertEqual(live.fixes, [.press(3)], "the pop-up shows [Press Face 3] now")
        XCTAssertEqual(live.oneLine, "Press Face 3 or tap the face that carries weight")
        // gone ⇒ nil (the pop-up closes)
        XCTAssertNil(FlexibleFixPrompt.live(opened, in: FlexibleReadiness.evaluate(inputs([face(3)]))))
        // ★ RED CONTROL: the stored value (what the page rendered) still has no button
        XCTAssertNotEqual(opened.fixes, live.fixes)
    }

    func testABlockerStandingWhenThePageOpensPopsOnce() {
        // ★ RE-PINNED (round 4 batch D2): the blocker was 3/5's shared stack, which no longer
        // blocks (a pinch builds); the rule under test is the prompt's, on any blocker — a weight
        let block = FlexibleReadiness.evaluate(inputs([face(3), face(5, kg: 0)]))
        var p = FlexibleFixPrompt(actionSerial: 4, popExisting: true)
        XCTAssertNil(p.next(block, actionSerial: 4, settled: false), "not while the scene / designs are in flight")
        XCTAssertEqual(p.next(block, actionSerial: 4, settled: true)?.kind, .noWeight, "at once, when settled")
        XCTAssertNil(p.next(block, actionSerial: 4, settled: true), "once — recompute noise never re-pops it")
        // a clear page opens with nothing to pop, and then only his actions pop
        var q = FlexibleFixPrompt(actionSerial: 4, popExisting: true)
        XCTAssertNil(q.next(FlexibleReadiness.evaluate(inputs([face(3)])), actionSerial: 4, settled: true))
        XCTAssertEqual(q.next(block, actionSerial: 5, settled: false)?.kind, .noWeight)
        // ★ RED CONTROL: the old prompt (no pop on open) stays silent on the same readiness
        var old = FlexibleFixPrompt(actionSerial: 4)
        XCTAssertNil(old.next(block, actionSerial: 4, settled: true))
    }

    /// Both ends of a shared stack, seen at once: an oblique corner view from above, never the
    /// face-on view of one (which hid the other behind it and turned its curve edge-on).
    func testASharedStackIsSeenObliquely() throws {
        let settle = simd_quatf(from: SIMD3<Float>(0, 0, -1), to: SIMD3<Float>(0, -1, 0))   // gravity −Z → down
        // face 5 at x = 0 (load +X into the part), face 3 at x = 100 (load −X)
        let g = try XCTUnwrap(FlexibleFixPopup.cameraRegion(load: SIMD3(1, 0, 0), other: SIMD3(-1, 0, 0), settle: settle))
        print("FLEX-REVIEW shared stack camera: \(g.id)")
        XCTAssertEqual(g.kind, .corner)
        XCTAssertGreaterThan(g.direction.y, 0, "from above")
        XCTAssertGreaterThan(simd_dot(g.direction, SIMD3<Float>(-1, 0, 0)), 0, "looking at the named face")
        // two faces at a right angle: between them
        let e = try XCTUnwrap(FlexibleFixPopup.cameraRegion(load: SIMD3(1, 0, 0), other: SIMD3(0, 0, -1), settle: settle))
        XCTAssertGreaterThan(simd_dot(e.direction, simd_normalize(SIMD3<Float>(-1, 1, 0))), 0.9)
        // ★ RED CONTROL: the one-face rule turns face-on to Face 5 (LEFT)
        let old = try XCTUnwrap(FlexibleFixPopup.cameraRegion(load: SIMD3(1, 0, 0), settle: settle))
        XCTAssertEqual(old.kind, .face)
        // ★ RE-PINNED (round 4 batch D2): no issue names both ends of a stack any more — two
        // pressed faces on one stack are a pinch (or separate squeezes) and nothing blocks
        XCTAssertTrue(FlexibleReadiness.evaluate(inputs([face(3), face(5)])).blocking.isEmpty)
    }

    // MARK: placement — the top line and the pop-up never cover a button

    /// The Exit row as measured at 11" portrait with "Fix 1 thing" (Exit 24…146, undo 154…198,
    /// redo 206…250).
    private let exitRow = CGRect(x: 24, y: 24, width: 226, height: 44)

    func testTheTopLineAndThePopUpClearTheExitRowAndTheGizmo() {
        let sizes: [(String, CGSize)] = [
            ("mini portrait", CGSize(width: 744, height: 1133)), ("Air portrait", CGSize(width: 820, height: 1180)),
            ("11\" portrait", CGSize(width: 834, height: 1194)), ("13\" portrait", CGSize(width: 1032, height: 1376)),
            ("11\" landscape", CGSize(width: 1194, height: 834)), ("13\" landscape", CGSize(width: 1376, height: 1032)),
        ]
        for (name, size) in sizes {
            let gizmo = FlexibleLegendPlacement.gizmoFrame(viewport: size)
            let band = FlexibleLegendPlacement.noticeBand(viewport: size, exitRow: exitRow)
            let pop = FlexibleLegendPlacement.popUp(viewport: size, notice: band)
            let popFrame = CGRect(x: pop.minX, y: pop.minY, width: pop.width, height: 130)
            print("FLEX-PLACE top line \(name): band \(band.integral) · pop-up \(popFrame.integral) · gizmo \(gizmo.integral)")
            XCTAssertFalse(band.intersects(exitRow), "\(name): the line clears Exit / undo / redo")
            XCTAssertFalse(band.intersects(gizmo), "\(name): the line clears the gizmo")
            XCTAssertGreaterThanOrEqual(band.width, FlexibleLegendPlacement.noticeMinWidth, "\(name): room for the whole line")
            XCTAssertFalse(popFrame.intersects(gizmo), "\(name): the pop-up clears the gizmo")
            XCTAssertFalse(popFrame.intersects(exitRow), "\(name): the pop-up clears the Exit row")
            XCTAssertFalse(popFrame.intersects(band), "\(name): the pop-up sits under the line")
            XCTAssertGreaterThanOrEqual(band.minX, PageChrome.edge)
        }
        // ★ RED CONTROL: the old layout at 11" portrait (measured: the pill at 190,30 453×40 and
        // the pop-up at 187,88 460×115) covered Redo and ran under the gizmo
        let size = CGSize(width: 834, height: 1194)
        let gizmo = FlexibleLegendPlacement.gizmoFrame(viewport: size)
        let oldPill = CGRect(x: 190, y: 30, width: 453, height: 40), oldPop = CGRect(x: 187, y: 88, width: 460, height: 115)
        XCTAssertTrue(oldPill.intersects(exitRow) && oldPill.intersects(gizmo), "control: the old line covered Redo and the gizmo")
        XCTAssertTrue(oldPop.intersects(gizmo), "control: the old pop-up covered the gizmo")
    }

    // MARK: the pill, the player, the views, the toast

    func testTheShapeOnlyTimelineEndsAsDrawn() {
        XCTAssertEqual(FlexibleSquishLoop.fullLabel(weightsKg: [10, 10], shapeOnly: true), "As drawn")
        XCTAssertEqual(FlexibleSquishLoop.fullLabel(weightsKg: [10, 10]), "10 kg each", "control: a designed lattice ends at its load")
    }

    func testThePillReadsWholeAndSaysLatticeOnce() throws {
        // ★ RE-PINNED (round 4 batch D2): the shared stack no longer blocks — the pill's short
        // form, on the weight blocker instead
        let r = FlexibleReadiness.evaluate(inputs([face(3), face(5, kg: 0)]))
        let s = FlexibleMainStatus.of(readiness: r, sceneReady: true, isBuilding: false, lattice: nil, stale: false)
        XCTAssertEqual(s.line, "Fix: the weight on Face 5")
        XCTAssertEqual(s.tone, .fix)
        XCTAssertEqual(s.fix?.kind, .noWeight, "a tap opens that fix")
        XCTAssertLessThan(s.line.count, r.oneLine.count, "control: the Settings line is the longer sentence")
        for line in [FlexibleMainStatus.ready, FlexibleMainStatus.building, FlexibleMainStatus.notOpened] {
            XCTAssertFalse(line.localizedCaseInsensitiveContains("lattice"), "the pill's title already says Lattice: \(line)")
        }
        let failed = FlexibleMainStatus.of(readiness: FlexibleReadiness.evaluate(inputs([face(1)])), sceneReady: true,
                                           isBuilding: false, lattice: nil, stale: false, failure: "No lattice voxel. More.")
        XCTAssertEqual(failed.tone, .fix)
        XCTAssertEqual(failed.line, "Couldn't build the lattice: No lattice voxel")
    }

    @MainActor
    func testAToastClearsItselfWithNoPageUp() async throws {
        let pm = try FlexibleHisProject.padProject(FlexibleStageSettings(materialID: "varioshore_tpu"))
        let m = FlexibleStageModel(project: pm, materialsPath: FlexibleHisProject.materialsPath, stampsPath: nil, persist: {})
        m.toastSeconds = 0.2
        m.toast = "Nozzle temperature set to Auto — that one was never tested"
        XCTAssertNotNil(m.toast)
        try await FlexibleHisProject.waitFor(3, "the toast to clear itself") { m.toast == nil }
        XCTAssertNil(m.toast, "no page is up to clear it — the model does")
        // a newer toast is not cleared by the older one's timer
        m.toastSeconds = 0.3
        m.toast = "first"
        try await Task.sleep(nanoseconds: 200_000_000)
        m.toast = "second"
        try await Task.sleep(nanoseconds: 180_000_000)
        XCTAssertEqual(m.toast, "second", "the first one's clear does not take the second")
    }

    /// ★ RE-PINNED (round 4, C2 — his img 5: "remove the xray view selector if the lattice view
    /// is going to use the rendering anyways"): there is no X-ray button any more — X-ray IS the
    /// Lattice view's rendering, so the button still shows what is DRAWN, and the two can never
    /// disagree (FlexibleMainPageRound4Tests pins the rest).
    @MainActor
    func testTheLatticeViewTurnsXRayOn() {
        let stage = FlexibleMainStage()
        XCTAssertTrue(stage.xray && stage.latticeShown, "the default: the lattice view, in X-ray")
        stage.toggleLattice()
        XCTAssertFalse(stage.latticeShown)
        XCTAssertFalse(stage.xray, "the lattice hidden: the solid part (X-ray goes with it)")
        stage.toggleLattice()
        XCTAssertTrue(stage.xray && stage.latticeShown, "turning the lattice on turns X-ray on")
        // ★ CONTROL: the button shows what is drawn — with nothing to show it is not lit, even on
        stage.latticeAvailable = false
        XCTAssertTrue(stage.latticeOn)
        XCTAssertNotEqual(stage.latticeOn, stage.latticeShown)
        XCTAssertEqual(FlexibleMainViewToggles.heatIcon, "thermometer.medium")
    }

    /// ★ The Settings page's squish is stepped by the RENDERER while a lattice is drawn (its
    /// 30 fps @State re-ran the whole page); the ticker writes the scale only for his live
    /// drawing, which has no lattice pass to step it.
    /// ★ RE-PINNED (round 4, batch D1 — his img 6: "the lattice should not be visible in the
    /// settings screen"): the Settings page draws NO lattice, so there is no lattice pass to
    /// step its squish — its own ticker steps his drawing (the renderer's loop is the main
    /// page's, the control below).
    func testTheSettingsPageLetsTheRendererStepTheSquish() throws {
        let page = try FlexibleSource.code("FlexibleStagePage.swift")
        XCTAssertTrue(page.contains("flexibleLattice: nil)"), "no lattice pass on the Settings page (round 4)")
        XCTAssertTrue(page.contains("guard loop.playing, dents != nil else { return }"),
                      "…so the page's ticker steps his drawing")
        XCTAssertFalse(page.contains("rendererLoops"), "no renderer loop to hand over")
        XCTAssertTrue(page.contains("loop.exaggeration = c.exaggeration"), "the renderer's scale is k × amount")
        // ★ CONTROL: the main page does the same (the mechanism FlexibleSquishPlayerTests measures)
        let main = try FlexibleSource.code("FlexibleMainStage.swift")
        XCTAssertTrue(main.contains("loop: fresh && !pageUp ? loop : nil)"))
    }

    func testTheMainPlayerClearsTheChipColumn() throws {
        for size in [CGSize(width: 834, height: 1194), CGSize(width: 1032, height: 1376), CGSize(width: 1194, height: 834)] {
            let clearance: CGFloat = 96
            for chip: CGFloat in [221, 280] {       // his Gravity chip; a wider one (another label)
                let keep = FlexibleMainPlayerSlot.keepOut(viewport: size, bottomClearance: clearance, chipColumnWidth: chip)
                let player = try XCTUnwrap(FlexibleLegendPlacement.player(viewport: size, bottomClearance: clearance, keepOut: keep))
                let column = CGRect(x: size.width - PageChrome.edge - chip, y: size.height - clearance - DS.Space.m - 48,
                                    width: chip, height: 48)
                print("FLEX-PLACE main player \(Int(size.width))×\(Int(size.height)) chip \(Int(chip)): \(player.integral) · chip \(column.integral)")
                XCTAssertFalse(player.insetBy(dx: -FlexibleLegendPlacement.gap + 0.5, dy: 0).intersects(column),
                               "the player keeps a gap from the chip in its row")
            }
        }
        // ★ RED CONTROL: without the column in the keep-outs a 280 pt chip lies under the player at 11" portrait
        let size = CGSize(width: 834, height: 1194)
        let old = try XCTUnwrap(FlexibleLegendPlacement.player(viewport: size, bottomClearance: 96,
                                                               keepOut: FlexibleMainPlayerSlot.keepOut(viewport: size)))
        let column = CGRect(x: size.width - PageChrome.edge - 280, y: size.height - 96 - DS.Space.m - 48, width: 280, height: 48)
        XCTAssertTrue(old.intersects(column), "control: the old keep-outs let the player run under the chip")
    }
}
