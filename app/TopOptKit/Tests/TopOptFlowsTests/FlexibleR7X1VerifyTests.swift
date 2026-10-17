// FlexibleR7X1VerifyTests — round 7 batch X1's VERIFY fixes, written BEFORE the code (the stubs' red run:
// docs/handoffs/evidence/2026-09-29-flexible-screens/round7/batch_x1/r7x1v_red_run.txt). Each test runs its RED control
// inside. His words (2026-10-14, his answer on the R7-V handoff's Q9, binding): "X-ray mode should show the inside of the
// SOLID showing the extent of the face prism/bend amount/heat map etc. … If lattice is on without x-ray view, we see the
// lattice plus the solid. If the user adds x-ray, we see through the solid." His answer 12 (the Squish page): "Turning heat
// map on shows colour … Turning x-ray on shows a prism view of the actual bend INTO the model." His img3: "The view of the
// heatmap doesn't actually change anything." His rules: numbers are boxes, one legend card per page, blockers say why at once.
//   V1  THE HEAT ON THE WALLS (the verify's blocker + majors): Heat on and the walls drawn (X-ray or the printed view) ⇒ the
//       walls carry the squish of their column (FlexibleWallHeat, the legend's scale); in X-ray the lid is a faint skin (the
//       ghost — never the opaque square that hid the lattice from above), in the printed view the solid part wears no heat
//       (no 0 mm lid); the legend's Squish row only with heat drawn, the density row gone while the walls carry the squish.
//       No walls drawn (the Lattice view off, Covered out of X-ray) ⇒ the lid carries the heat as before. RED
//       `controlHeatOnLid` (X1's first build: the opaque lid in X-ray, M6's ghost walls under it, the 0 mm lid).
//   V2  A wall's reading is its column's squish (mm · density). RED `controlHeatOnLid` (the density reading).
//   V3  The printed view's layer, body alpha and tints follow ONE rule — a page going up never leaves a see-through body with
//       no pass drawing its closed surface. RED `controlPrintedRulesApart` (X1: the body alpha read `frozen`, a turn late).
//   V4  Covered, X-ray off: the Lattice icon turning on says why nothing changes, with the one-tap fix (X-ray). RED
//       `controlNoCoveredNote`.
//   V5  The Squish page's bend prism reads over the heat (a neutral glass, not the violet that vanished on the heat's blue),
//       carries its number in a box, and the ONE legend card has its row ("less than drawn" when the sim's bend is well short
//       of his curve). RED `FlexibleBendPrism.controlFirstBuild`.
//   V6  X-ray on an edges group's tab says why there is no prism (as Heat and Bend do).
#if canImport(MetalKit)
import XCTest
import simd
@testable import TopOptFlows
@testable import TopOptKit

@MainActor
final class FlexibleR7X1VerifyTests: XCTestCase {
    typealias F = FlexibleR7M1Fixtures

    /// His pad with his LIVE lattice (Group C's two 25 mm face-prisms — the strips of his img5), the main page shown, the
    /// lattice built and the sims landed.
    func hisStrips() async throws -> (FlexibleHisProject.Restored, FlexibleMainStage, FlexibleStageModel) {
        let (r, s, m) = try await F.hisPad(self, live: true)
        s.didExitSettings()
        s.apply(r.project, owned: true, pageUp: false)
        try await FlexibleHisProject.waitFor(240, "the lattice") { m.lattice != nil && !m.latticeBuilding && !m.latticeIsStale }
        try await FlexibleHisProject.waitFor(300, "the sims") { !m.squish.isEmpty && !m.squish.values.contains(.pending) }
        s.refresh()
        return (r, s, m)
    }

    /// The overlay's map vertices (the pressed faces' quads, after the part's own).
    func mapRange(_ s: FlexibleMainStage) throws -> Range<Int> {
        let o = try XCTUnwrap(s.overlay)
        return o.partFlatVertices..<o.mesh.flat.vertexCount
    }

    // MARK: - V1: the heat on the walls

    func testHeatGoesOnTheWallsWhereverTheWallsAreDrawn() async throws {
        let (r, s, m) = try await hisStrips()
        let p = r.project
        XCTAssertTrue(s.heat, "premise: Heat on (the default)")
        XCTAssertFalse(s.xrayOn, "premise: X-ray off")
        XCTAssertTrue(s.printedView, "premise: Finish None — the printed view")
        XCTAssertGreaterThan(s.dentMaxMM, 0.5, "premise: a squish to colour")
        let map = try mapRange(s)
        XCTAssertGreaterThan(map.count, 100, "premise: the pressed faces' quads")

        // ★ the PRINTED view: the walls carry the heat, the solid part wears none
        XCTAssertTrue(s.heatOnWalls, "★ the printed view: the walls carry the heat")
        let layer = try XCTUnwrap(s.layer(p, stage: .lattice, pageUp: false))
        let hw = try XCTUnwrap(layer.heatWalls, "★ …handed to the pass with the lattice")
        XCTAssertEqual(hw.cells.count, layer.faces.count, "one table per squish face (the pass's slots)")
        XCTAssertEqual(Double(hw.topMM), s.dentMaxMM, accuracy: 1e-4, "★ on the legend's scale (one top for the lid and the walls)")
        let cellMax = hw.cells.flatMap { $0 }.max() ?? 0
        XCTAssertGreaterThanOrEqual(Double(cellMax), 0.95 * s.dentMaxMM, "★ the hottest column reaches the legend's top")
        XCTAssertFalse(layer.ghostWalls, "★ the walls are solid")
        let t = try XCTUnwrap(s.tints(p, on: .lattice, roles: [:], stress: nil))
        let open = try XCTUnwrap(s.printedOpen(), "premise: the printed view's open surface")
        var closedMap = 0, closedHeated = 0
        for v in map where !open[v] { closedMap += 1; if t[v * 8 + 3] > 0.01 { closedHeated += 1 } }
        // ★ RE-PINNED (merge of X1 after M2 — the reviewer's ruling 3 and his img3 / answer 7): M2 presses only the LATTICE
        // SECTIONS of the Top, so its solid middle is no pressed quad at all — no closed map vertex to carry a lid (was
        // XCTAssertGreaterThan(closedMap, 20) — X1 ran on M1, where the whole Top was pressed). The rule holds either way.
        XCTAssertEqual(closedMap, 0, "★ M2: the Top's solid middle is not pressed (only its lattice sections are)")
        XCTAssertEqual(closedHeated, 0, "★ the solid part wears no heat — it does not squish (no flat 0 mm lid)")   // (measured on a pressed solid middle by V1b)
        XCTAssertTrue(s.legendKinds.contains(.dent), "★ the Squish row: the heat IS drawn (on the walls)")
        XCTAssertFalse(s.legendKinds.contains(.lattice), "★ no density row: the walls are coloured by the squish")

        // ★ X-RAY: the walls carry the heat; the lid is a faint heat skin (the ghost), never the opaque square
        s.xrayOn = true
        XCTAssertTrue(s.heatOnWalls, "★ X-ray: the walls carry the heat")
        let xl = try XCTUnwrap(s.layer(p, stage: .lattice, pageUp: false))
        XCTAssertNotNil(xl.heatWalls, "★ X-ray: the heat handed to the pass")
        XCTAssertFalse(xl.printed, "X-ray: no printed solid")
        XCTAssertFalse(xl.ghostWalls, "★ X-ray: the walls solid (M6's ghost walls under an opaque lid — reversed)")
        let xt = try XCTUnwrap(s.tints(p, on: .lattice, roles: [:], stress: nil))
        var solidMap = 0, ghostHeated = 0
        for v in map {
            if xt[v * 8 + 5] > 0.5 { solidMap += 1 }
            if xt[v * 8 + 6] > 0.5, xt[v * 8 + 3] > 0.01 { ghostHeated += 1 }
        }
        XCTAssertEqual(solidMap, 0, "★ X-ray: no pressed face is an opaque lid (he sees through the solid)")
        XCTAssertGreaterThan(ghostHeated, map.count / 4, "★ X-ray: the lid is a faint skin in its heat colours")
        XCTAssertTrue(s.legendKinds.contains(.dent))
        XCTAssertFalse(s.legendKinds.contains(.lattice))

        // Heat off: the walls by density (their legend row back)
        s.heat = false
        XCTAssertFalse(s.heatOnWalls, "Heat off: no heat on the walls")
        XCTAssertNil(s.layer(p, stage: .lattice, pageUp: false)?.heatWalls)
        XCTAssertTrue(s.legendKinds.contains(.lattice), "Heat off: the density row")
        s.heat = true

        // no walls drawn (the Lattice view off, in X-ray): the LID carries the heat, opaque, as before
        s.latticeOn = false
        XCTAssertFalse(s.heatOnWalls, "the Lattice view off: no walls to carry it")
        let lt = try XCTUnwrap(s.tints(p, on: .lattice, roles: [:], stress: nil))
        let lidSolid = map.filter { lt[$0 * 8 + 5] > 0.5 && lt[$0 * 8 + 3] > 0.01 }.count
        XCTAssertGreaterThan(lidSolid, map.count / 4, "★ no walls: the heat on the lid, opaque")
        XCTAssertTrue(s.legendKinds.contains(.dent))
        s.latticeOn = true
        s.xrayOn = false

        // Stress takes the map from Heat: no heat on the walls
        s.toggleStress()
        XCTAssertFalse(s.heatOnWalls, "Stress on (Heat off): no heat on the walls")
        s.toggleHeat()
        XCTAssertTrue(s.heatOnWalls)

        // Covered, X-ray off: no walls drawn — the plain model, its lid carries the heat
        m.edit({ $0.finish = FlexibleFinish.covered.rawValue }, recompute: false)
        s.refresh()
        XCTAssertFalse(s.printedView)
        XCTAssertFalse(s.heatOnWalls, "Covered out of X-ray: no walls to carry it")
        // ★ RE-PINNED (merge of X1 after the M1 verify — his answer "the squish number: only on the Squish page"): the finish
        // edit (no rebuild here) leaves the lattice STALE, and the main page wears heat only from a lattice drawn — the plain
        // model until the rebuild (was: the lid's heat at once — X1 ran before the M1 verify). X1's rule — no walls drawn, the
        // lid carries the heat — is checked with the M1 verify's gate opened (its red control `controlDrawnCurveOnMain`)
        XCTAssertTrue(m.latticeIsStale, "premise: the finish edit leaves the lattice stale (no rebuild in this test)")
        let ctStale = try XCTUnwrap(s.tints(p, on: .lattice, roles: [:], stress: nil))
        XCTAssertEqual(map.filter { ctStale[$0 * 8 + 3] > 0.01 }.count, 0, "★ M1 verify: no lattice drawn — no heat on the main page")
        FlexibleMainStage.controlDrawnCurveOnMain = true
        s.refresh()
        let ct = try XCTUnwrap(s.tints(p, on: .lattice, roles: [:], stress: nil))
        FlexibleMainStage.controlDrawnCurveOnMain = false
        XCTAssertGreaterThan(map.filter { ct[$0 * 8 + 5] > 0.5 && ct[$0 * 8 + 3] > 0.01 }.count, map.count / 4, "Covered: the lid's heat")
        m.edit({ $0.finish = FlexibleFinish.none.rawValue }, recompute: false)
        s.refresh()

        // ★ RED CONTROL: X1's first build — the heat only on the lid (opaque in X-ray, M6's ghost walls under it; the 0 mm
        // lid in the printed view); the legend's rows regardless
        s.controlHeatOnLid = true
        s.refresh()
        let cPrinted = (walls: s.heatOnWalls, layer: s.layer(p, stage: .lattice, pageUp: false)?.heatWalls != nil, kinds: s.legendKinds)
        let cpt = try XCTUnwrap(s.tints(p, on: .lattice, roles: [:], stress: nil))
        let cOpen = try XCTUnwrap(s.printedOpen())
        let cClosedHeated = map.filter { !cOpen[$0] && cpt[$0 * 8 + 3] > 0.01 }.count
        s.xrayOn = true
        let cxt = try XCTUnwrap(s.tints(p, on: .lattice, roles: [:], stress: nil))
        let cSolid = map.filter { cxt[$0 * 8 + 5] > 0.5 }.count
        let cGhostWalls = s.layer(p, stage: .lattice, pageUp: false)?.ghostWalls ?? false
        s.xrayOn = false
        s.controlHeatOnLid = false
        s.refresh()
        XCTAssertFalse(cPrinted.walls, "★ RED CONTROL: no heat on the walls")
        XCTAssertFalse(cPrinted.layer)
        // ★ RE-PINNED (merge, M2): no flat 0 mm lid on the solid middle even in X1's first build — M2 never presses it (was
        // XCTAssertGreaterThan(cClosedHeated, 20)); the control stays red by its other lines (no walls' heat, the density row,
        // X-ray's opaque lid, M6's ghost walls)
        XCTAssertEqual(cClosedHeated, 0, "★ RED CONTROL (M2): nothing pressed on the solid middle to wear a lid")   // (V1b: the lid's control on a pressed solid middle)
        XCTAssertTrue(cPrinted.kinds.contains(.lattice), "★ RED CONTROL: the density row beside the Squish row")
        XCTAssertGreaterThan(cSolid, map.count / 4, "★ RED CONTROL: X-ray's opaque heat lid (the square that hid the lattice)")
        XCTAssertTrue(cGhostWalls, "★ RED CONTROL: M6's ghost walls under it")
        print("FLEX-R7X1V-1 heat on the walls: top \(String(format: "%.2f", s.dentMaxMM)) mm, hottest column \(cellMax) · printed closed \(closedMap) heated \(closedHeated) · X-ray solid lid \(solidMap), ghost skin \(ghostHeated)/\(map.count) · control: closed heated \(cClosedHeated), X-ray solid \(cSolid), ghost walls \(cGhostWalls)")
    }

    // MARK: - V1b: the printed view's solid part wears no lid — measured on a pressed, partly solid face

    /// ★ ROUND 7 REVIEW (R — the review of M2 and F, finding "the X1-merge re-pin leaves V1's no-lid check and its red-control
    /// line vacuous"): M2 presses only the Top's LATTICE PARTS, so on the live fixture no pressed quad lies on the solid middle
    /// and V1's `closedHeated == 0` (and its control's) measured nothing. Here the Top is pressed WHOLE though only partly
    /// latticed — M2's own red control `FlexibleLatticeSections.controlWholeFace`, for this fixture only (a pressed, partly
    /// solid face, as X1 measured it on M1) — so the rule and its red control measure something again.
    func testThePrintedViewsSolidPartWearsNoLidOnAWholePressedFace() async throws {
        FlexibleLatticeSections.controlWholeFace = true
        defer { FlexibleLatticeSections.controlWholeFace = false }
        let (r, s, m) = try await hisStrips()
        let p = r.project
        XCTAssertTrue(m.settings.face(1)?.isLoaded ?? false, "premise: the Top pressed whole (no lattice parts)")
        XCTAssertTrue(s.printedView, "premise: Finish None — the printed view")
        XCTAssertTrue(s.heatOnWalls, "premise: the walls carry the heat")
        let map = try mapRange(s)
        let t = try XCTUnwrap(s.tints(p, on: .lattice, roles: [:], stress: nil))
        let open = try XCTUnwrap(s.printedOpen())
        var closed = 0, heated = 0
        for v in map where !open[v] { closed += 1; if t[v * 8 + 3] > 0.01 { heated += 1 } }
        XCTAssertGreaterThan(closed, 20, "premise: the Top's solid middle is pressed quads (\(closed))")
        XCTAssertEqual(heated, 0, "★ the solid part wears no heat — no flat 0 mm lid (\(heated) of \(closed))")
        // ★ RED CONTROL: X1's first build — the heat on the lid, the solid middle a flat 0 mm lid
        s.controlHeatOnLid = true
        s.refresh()
        let ct = try XCTUnwrap(s.tints(p, on: .lattice, roles: [:], stress: nil))
        let cOpen = try XCTUnwrap(s.printedOpen())
        let cHeated = map.filter { !cOpen[$0] && ct[$0 * 8 + 3] > 0.01 }.count
        s.controlHeatOnLid = false
        s.refresh()
        print("FLEX-R7X1V-1b whole Top: printed closed \(closed) heated \(heated) · control heated \(cHeated)")
        XCTAssertGreaterThan(cHeated, 20, "★ RED CONTROL: the flat 0 mm lid on the solid middle (\(cHeated))")
    }

    // MARK: - V2: a wall reads its column's squish

    func testAWallReadsTheSquishOfItsColumn() async throws {
        let (r, s, m) = try await hisStrips()
        let p = r.project
        s.xrayOn = true
        s.refresh()
        let layer = try XCTUnwrap(s.layer(p, stage: .lattice, pageUp: false))
        let hw = try XCTUnwrap(layer.heatWalls, "premise: the walls carry the heat")
        let g = try XCTUnwrap(s.shownLattice)
        let faces = g.squishFaces
        // a point in the lattice region under a hot column (the loop at rest: the drawn point is its rest point)
        XCTAssertEqual(s.currentScale, 0, accuracy: 1e-6, "premise: at rest (Play off)")
        let mask = g.inputs.mask
        var pick: (p: SIMD3<Float>, mm: Float)?
        for n in stride(from: 0, to: mask.values.count, by: 7) where mask.values[n] > 0.99 {
            let q = mask.c0 + SIMD3<Float>(Float(n % mask.nx), Float((n / mask.nx) % mask.ny), Float(n / (mask.nx * mask.ny))) * mask.spacing
            if let h = FlexibleWallHeat.value(at: q, faces: faces, cells: hw.cells), h > 0.4 * hw.topMM { pick = (q, h); break }
        }
        let w = try XCTUnwrap(pick, "premise: a wall point under a squishing column")
        let mode = FlexibleReadKind.dent.mode
        XCTAssertTrue(s.wantsWallProbe(mode), "★ the wall probe is armed: the walls carry the reading")
        s.clearReading()
        XCTAssertTrue(s.readLattice(p, mode: mode, model: w.p))
        let rd = try XCTUnwrap(s.reading)
        XCTAssertEqual(rd.kind, .dent, "★ a wall reads the squish (its colour)")
        XCTAssertEqual(rd.value, String(format: "%.1f", w.mm), "★ …its column's mm")
        XCTAssertTrue(rd.unit.contains("density"), "…with its density: \(rd.unit)")
        XCTAssertEqual(rd.fraction ?? -1, Double(min(1, w.mm / hw.topMM)), accuracy: 1e-4, "the arrow on the ramp where its colour is")
        // ★ RED CONTROL: X1's first build — the wall read its density
        s.controlHeatOnLid = true
        s.refresh()
        s.clearReading()
        _ = s.readLattice(p, mode: FlexibleReadKind.lattice.mode, model: w.p)
        let control = s.reading?.kind
        s.controlHeatOnLid = false
        s.refresh()
        XCTAssertEqual(control, .lattice, "★ RED CONTROL: the density reading")
        _ = m
        print("FLEX-R7X1V-2 wall reading: \(rd.value) \(rd.unit) (column \(w.mm) mm of \(hw.topMM)) · control \(String(describing: control))")
    }

    // MARK: - V3: the printed view's rules agree under a page

    func testThePrintedViewsLayerBodyAndTintsFollowOneRule() async throws {
        let (r, s, m) = try await hisStrips()
        let p = r.project
        s.heat = false
        s.refresh()
        XCTAssertTrue(s.printedView)
        XCTAssertEqual(s.bodyAlpha(p, on: .lattice), 0, "premise: the printed body (only its closed surface draws)")
        XCTAssertNotNil(s.printedOpen(), "premise: its open surface known")
        // under a page the walls hide at once
        let up = s.layer(p, stage: .lattice, pageUp: true)
        XCTAssertEqual(up?.hidden, true, "under a page: no wall")
        XCTAssertEqual(up?.printed, false)
        _ = s.layer(p, stage: .lattice, pageUp: false)
        try await Task.sleep(nanoseconds: 200_000_000)
        s.refresh()
        // ★ no open surface known (no overlay — nothing could be flagged solid): the body is NOT see-through, the layer is not
        // printed, the tints keep no open surface — one rule for the three
        s.dropOverlayForTests()
        XCTAssertNil(s.printedOpen(), "no overlay: no open surface")
        XCTAssertEqual(s.bodyAlpha(p, on: .lattice), 1, "★ …so the body is opaque (see-through with nothing flagged solid, the part vanished)")
        XCTAssertEqual(s.layer(p, stage: .lattice, pageUp: false)?.printed, false, "★ …and the layer is not printed")
        // ★ RED CONTROL: X1's rules — the body alpha and the layer by `printedDrawn` alone
        s.controlPrintedRulesApart = true
        let control = s.bodyAlpha(p, on: .lattice)
        let controlPrinted = s.layer(p, stage: .lattice, pageUp: false)?.printed
        s.controlPrintedRulesApart = false
        XCTAssertEqual(control, 0, "★ RED CONTROL: see-through with no open surface flagged (the part vanished)")
        XCTAssertEqual(controlPrinted, true, "★ RED CONTROL: …and the layer printed")
        s.forceOverlayRebuildForTests()
        s.refresh()
        XCTAssertEqual(s.bodyAlpha(p, on: .lattice), 0, "the overlay back: the printed body again")
        _ = m
        print("FLEX-R7X1V-3 no overlay: body alpha 1, layer not printed, no open surface · control alpha \(control ?? -1), printed \(String(describing: controlPrinted))")
    }

    // MARK: - V4: Covered says why the Lattice icon changes nothing

    func testCoveredSaysWhyTheLatticeIconShowsNothingWithItsFix() async throws {
        let (_, s, m) = try await hisStrips()
        m.edit({ $0.finish = FlexibleFinish.covered.rawValue }, recompute: false)
        s.refresh()
        XCTAssertFalse(s.xrayOn)
        s.note.clear()
        s.latticeOn = false
        s.toggleLatticeView()
        XCTAssertTrue(s.latticeOn, "the Lattice icon: on")
        XCTAssertEqual(s.note.kind, .coveredHidesLattice, "★ Covered, X-ray off: the note says why nothing changes")
        let line = FlexibleMainNote.line(.coveredHidesLattice) + " · " + FlexibleRowCopy.coveredHidesLatticeAction
        XCTAssertLessThanOrEqual(line.count, FlexibleRowCopy.maxChars, "one line, ≤ 44: \(line)")
        XCTAssertFalse(s.xrayOn, "★ never X-ray by itself")
        s.coveredNoteTapped()
        XCTAssertTrue(s.xrayOn, "★ the note's one tap: X-ray (the lattice inside the skin)")
        XCTAssertNil(s.note.kind, "…and the note goes")
        // in X-ray, or with another finish, the walls are seen: no note
        s.latticeOn = false
        s.toggleLatticeView()
        XCTAssertNotEqual(s.note.kind, .coveredHidesLattice, "X-ray on: the walls are seen — no note")
        s.xrayOn = false
        m.edit({ $0.finish = FlexibleFinish.none.rawValue }, recompute: false)
        s.refresh()
        s.note.clear()
        s.latticeOn = false
        s.toggleLatticeView()
        XCTAssertNotEqual(s.note.kind, .coveredHidesLattice, "None: the printed view shows the lattice — no note")
        // ★ RED CONTROL: X1 — the icon lit with no word
        m.edit({ $0.finish = FlexibleFinish.covered.rawValue }, recompute: false)
        s.refresh()
        s.note.clear()
        s.controlNoCoveredNote = true
        s.latticeOn = false
        s.toggleLatticeView()
        let control = s.note.kind
        s.controlNoCoveredNote = false
        XCTAssertNil(control, "★ RED CONTROL: no word")
        print("FLEX-R7X1V-4 Covered note: \"\(line)\" (\(line.count) chars) · tap → X-ray · control \(String(describing: control))")
    }

    // MARK: - V5: the Squish page's bend prism reads over the heat, with its number and its legend row

    func testTheSquishPagesBendPrismReadsOverTheHeatWithItsNumberAndRow() async throws {
        addTeardownBlock { @MainActor in FlexibleBendPrism.controlFirstBuild = false }
        let r = try FlexiblePressFixtures.a1Project(3, self)
        let p = r.project
        let stage = FlexibleMainStage()
        stage.reduceMotion = { true }
        let m = stage.model(for: p, materialsPath: FlexibleHisProject.materialsPath, stampsPath: FlexibleHisProject.stampsPath, persist: {})
        addTeardownBlock { @MainActor in await m.waitForIdle() }
        m.openScene()
        try await FlexibleSquishFixture.settle(m, "his pad")
        _ = try await FlexibleSquishFixture.build(m, "his pad")
        var lines: [String] = []
        for regions in [[1], [4, 2]] {
            let g = try XCTUnwrap(m.squeezeGroups.first { $0.regions == regions }, "his group \(regions)")
            m.rail = .group(g.id)
            m.select(regions[0])
            try await FlexibleSquishFixture.solve(m, first: FlexibleSim.groupID(g.number), "his pad")
            let edge = FlexibleSettingsSquish.overlayEdge(model: m)
            let overlay = try XCTUnwrap(edge.map { FlexiblePageChannels.overlay(model: m, maxEdgeMM: $0) } ?? FlexiblePageChannels.overlay(model: m))
            var cache: (key: String, dents: [Float])?
            let views: FlexibleStageViews = [.xray]   // Heat on (the page's default) and his X-ray
            let c = FlexibleStagePage.composeTints(model: m, overlay: overlay, views: views)
            let sq = FlexibleSettingsSquish.shown(model: m, overlay: overlay, channels: c, feCache: &cache)
            let prism = try XCTUnwrap(FlexibleStagePage.xrayItems(model: m, overlay: overlay, dents: sq.dents, k: sq.exaggeration, views: views).first,
                                      "premise: the bend prism (group \(regions))")
            guard case .shell(let shell) = prism.volume.shape else { return XCTFail("a shell") }
            // ★ it reads over the heat: its colour far from every colour of the heat's rainbow (the violet sat on its blue)
            let tint = try XCTUnwrap(prism.tint)
            let nearest = stride(from: 0.0, through: 1.0, by: 0.05).map { f -> Float in
                let c = FlexibleColours.depthColour(fraction: f)
                return Self.deltaE(tint, SIMD3(Float(c.r), Float(c.g), Float(c.b)))
            }.min() ?? 0
            XCTAssertGreaterThan(nearest, 25, "★ the prism's glass is far from every heat colour (ΔE \(nearest))")
            // ★ its number, in a box, at its deepest point
            let tag = try XCTUnwrap(FlexibleBendPrism.tag(prism), "★ the prism carries its number")
            XCTAssertEqual(tag.text, String(format: "%.1f mm", shell.reachedDepthMM), "★ the prism's deepest mm")
            let deepest = zip(shell.base, shell.offset).max { simd_length($0.1 - $0.0) < simd_length($1.1 - $1.0) }
            XCTAssertEqual(simd_distance(tag.anchor, deepest?.1 ?? .zero), 0, accuracy: 1e-3, "★ …at its deepest point (the floor)")
            // ★ the ONE card has its row (it comes for it even with Heat hidden); "less than drawn" when the sim is short
            let short = FlexibleBendPrism.shortOfDrawn(model: m, depthMM: tag.depthMM)
            let row = FlexibleRowCopy.legendBendRow(short: short)
            XCTAssertLessThanOrEqual(row.count, FlexibleRowCopy.maxChars)
            XCTAssertTrue(FlexibleLegend.shows(hasDent: false, views: [.xray, .heatOff], bendPrism: true), "★ the card comes for the prism's row")
            if regions == [1] { XCTAssertTrue(short, "★ his Group 1: the sim's \(tag.text) is well short of his 12 mm curve — said") }
            lines.append("group \(regions): prism \(tag.text) (ΔE to the heat ≥ \(String(format: "%.0f", nearest))) · row \"\(row)\"")
        }
        // ★ RED CONTROL: X1's first build — the violet prism, no number, no row
        FlexibleBendPrism.controlFirstBuild = true
        let edge = FlexibleSettingsSquish.overlayEdge(model: m)
        let overlay = try XCTUnwrap(edge.map { FlexiblePageChannels.overlay(model: m, maxEdgeMM: $0) } ?? FlexiblePageChannels.overlay(model: m))
        var cache: (key: String, dents: [Float])?
        let c = FlexibleStagePage.composeTints(model: m, overlay: overlay, views: [.xray])
        let sq = FlexibleSettingsSquish.shown(model: m, overlay: overlay, channels: c, feCache: &cache)
        let item = FlexibleStagePage.xrayItems(model: m, overlay: overlay, dents: sq.dents, k: sq.exaggeration, views: [.xray]).first
        let controlTag = FlexibleBendPrism.tag(item)
        let controlCard = FlexibleLegend.shows(hasDent: false, views: [.xray, .heatOff], bendPrism: true)
        FlexibleBendPrism.controlFirstBuild = false
        XCTAssertEqual(item?.tint, FlexibleStageStyle.facePrismTint, "★ RED CONTROL: the violet prism")
        XCTAssertNil(controlTag, "★ RED CONTROL: no number")
        XCTAssertFalse(controlCard, "★ RED CONTROL: no row")
        print("FLEX-R7X1V-5 Squish bend prism:\n  " + lines.joined(separator: "\n  "))
    }

    /// CIE76 ΔE between two linear-ish 0…1 sRGB colours.
    static func deltaE(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> Float {
        func lab(_ c: SIMD3<Float>) -> SIMD3<Float> {
            func lin(_ v: Float) -> Float { v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
            let r = lin(c.x), g = lin(c.y), bl = lin(c.z)
            let x = (0.4124 * r + 0.3576 * g + 0.1805 * bl) / 0.95047, y = 0.2126 * r + 0.7152 * g + 0.0722 * bl
            let z = (0.0193 * r + 0.1192 * g + 0.9505 * bl) / 1.08883
            func f(_ t: Float) -> Float { t > 0.008856 ? pow(t, 1.0 / 3) : 7.787 * t + 16.0 / 116 }
            return SIMD3(116 * f(y) - 16, 500 * (f(x) - f(y)), 200 * (f(y) - f(z)))
        }
        return simd_length(lab(a) - lab(b))
    }

    // MARK: - V6: X-ray on an edges group says why there is no prism

    func pump(_ seconds: Double) {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end { _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.02)) }
    }
    func pumpUntil(_ seconds: Double, _ cond: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while !cond() {
            if Date() > end { return false }
            _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }
        return true
    }

    func testXrayOnAnEdgesGroupSaysWhyThereIsNoPrism() throws {
        let r = try FlexiblePressFixtures.a1Project(3, self)
        let stage = FlexibleMainStage()
        stage.reduceMotion = { true }
        let m = stage.model(for: r.project, materialsPath: FlexibleHisProject.materialsPath, stampsPath: FlexibleHisProject.stampsPath, persist: {})
        addTeardownBlock { @MainActor in await m.waitForIdle() }
        m.openScene()
        XCTAssertTrue(pumpUntil(120) { m.sceneState == .ready && m.loadedKeys.allSatisfy { m.stacks[$0] != nil && m.geometry[$0] != nil } })
        m.rail = .newGroup
        m.startEdgePick()
        XCTAssertTrue(pumpUntil(240) { m.edgePick.map { !$0.loading && !$0.checking } ?? false }, "the edges listed")
        let c = try XCTUnwrap(m.edgePick?.candidates.first { $0.kind == .edge && Set($0.members) == [1, 2] })
        m.toggleEdgePick(c.number)
        m.setEdgePickWeight(5)
        var done = false
        Task { @MainActor in _ = await m.finishEdgePick(); done = true }
        XCTAssertTrue(pumpUntil(240) { done && m.sceneState == .ready })
        let edges = try XCTUnwrap(m.squeezeGroups.first { $0.kind == .edges }, "premise: an edges group")
        m.rail = .group(edges.id)
        XCTAssertEqual(m.playingGroup?.kind, .edges, "premise: its tab open")
        XCTAssertEqual(FlexibleStageViewButtons.edgesPendingLine(.xray, views: [.xray], model: m), FlexibleRowCopy.noBendYet,
                       "★ X-ray on: says why there is no prism (as Bend and Heat do)")
        XCTAssertNil(FlexibleStageViewButtons.edgesPendingLine(.xray, views: [], model: m), "X-ray off: nothing to say")
        XCTAssertEqual(FlexibleStageViewButtons.edgesPendingLine(.bend, views: [.bend], model: m), FlexibleRowCopy.noBendYet, "Bend: as before")
        print("FLEX-R7X1V-6 edges tab, X-ray on: \"\(FlexibleRowCopy.noBendYet)\"")
    }
}
#endif
