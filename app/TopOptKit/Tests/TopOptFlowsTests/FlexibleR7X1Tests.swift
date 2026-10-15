// FlexibleR7X1Tests — round 7 batch X1, THE X-RAY RULE (reviewer order item 3, before the redesign), written BEFORE the code
// (the stubs' red run: docs/handoffs/evidence/2026-09-29-flexible-screens/round7/batch_x1/r7x1_red_run.txt). Each test runs
// its RED control inside. His words, 2026-10-14 (his answer on the R7-V handoff's Q9, binding):
//   "No. X-ray mode should show the inside of the SOLID showing the extent of the face prism/bend amount/heat map etc. The
//    lattice should be visible without x-ray on as long as finish is set to something that isn't 'covered'. These two
//    things are not mutually exclusive. If lattice is on without x-ray view, we see the lattice plus the solid. If the user
//    adds x-ray, we see through the solid."
// and on the Squish page (his answer 12): "Turning x-ray on shows a prism view of the actual bend INTO the model."
//   X1-1  X-ray is OFF by default on BOTH pages, whatever the finish — R7-V's stopgap (`xrayDefault`: on for None / Rim /
//         Skin) is retired. RED `controlXrayByFinish` (the stopgap), `FlexibleStagePage.controlAlwaysXray` (the Squish page
//         always in X-ray, rounds 3–7).
//   X1-2  The Lattice view and [Prisms] NEVER turn X-ray on (reverses R7-V's "a view that needs another turns it on itself"
//         for these two, and the Exit / note / pill paths that went through it). The Lattice icon is a plain show / hide.
//         RED `controlViewsForceXray` (R7-V's rule).
//   X1-3  THE PRINTED VIEW: X-ray off, the lattice on, a finish that is not Covered ⇒ the walls are drawn with the printed
//         solid (FlexibleLatticeLayerInputs.printed), the body is see-through with its CLOSED surface flagged solid (its
//         tints), so the solid part shows and the lattice shows where the finish leaves it open; Covered ⇒ the plain model;
//         X-ray ⇒ R7-V's X-ray, unchanged. RED `controlNoPrintedView` (R7-V's rule: the walls only in X-ray).
//   X1-4  THE SQUISH PAGE: an X-ray icon (icons only), off by default (the part opaque); on: the ghost and the current
//         group's bend drawn as a prism INTO the model (FlexibleBendPrism: the rest faces, the full-depth bend, the skirt
//         between). RED `FlexibleStagePage.controlAlwaysXray` (always X-ray, no prism).
#if canImport(MetalKit)
import XCTest
import simd
@testable import TopOptFlows
@testable import TopOptKit

@MainActor
final class FlexibleR7X1Tests: XCTestCase {
    typealias F = FlexibleR7M1Fixtures

    /// His pad with his LIVE lattice (Group C's two 25 mm face-prisms — the two strips of his img5), the main page shown,
    /// the lattice built and the sims landed.
    func hisStrips() async throws -> (FlexibleHisProject.Restored, FlexibleMainStage, FlexibleStageModel) {
        let (r, s, m) = try await F.hisPad(self, live: true)
        let p = r.project
        s.didExitSettings()
        s.apply(p, owned: true, pageUp: false)
        try await FlexibleHisProject.waitFor(240, "the lattice") { m.lattice != nil && !m.latticeBuilding && !m.latticeIsStale }
        try await FlexibleHisProject.waitFor(300, "the sims") { !m.squish.isEmpty && !m.squish.values.contains(.pending) }
        s.refresh()
        return (r, s, m)
    }

    // MARK: - X1-1: X-ray off by default on both pages

    func testXrayIsOffByDefaultOnBothPagesWhateverTheFinish() async throws {
        addTeardownBlock { @MainActor in FlexibleStagePage.controlAlwaysXray = false }
        let (r, s, m) = try await hisStrips()
        let p = r.project
        XCTAssertEqual(m.settings.finishMode, .none, "premise: his pad is saved with Finish None")
        XCTAssertTrue(m.facePrismsSet, "premise: his live lattice (Group C's face-prisms)")
        XCTAssertFalse(s.xrayOn, "★ Finish None: X-ray OFF as the page opens (his Q9 answer)")
        XCTAssertNotEqual(s.bodyAlpha(p, on: .lattice), FlexibleStagePage.xrayBodyAlpha, "★ not the ghost")
        for f in FlexibleFinish.allCases {
            m.edit({ $0.finish = f.rawValue }, recompute: false)
            XCTAssertFalse(s.xrayOn, "★ Finish \(f.rawValue): X-ray off by default")
        }
        m.edit({ $0.finish = FlexibleFinish.none.rawValue }, recompute: false)
        // his tap wins, both ways
        s.toggleXray()
        XCTAssertTrue(s.xrayOn, "his X-ray tap: on")
        XCTAssertEqual(s.bodyAlpha(p, on: .lattice), FlexibleStagePage.xrayBodyAlpha, "…the ghost")
        s.toggleXray()
        XCTAssertFalse(s.xrayOn)
        // ★ THE SQUISH PAGE: X-ray off by default — the part opaque (Bend alone was already opaque; now every view is)
        XCTAssertFalse(m.views.contains(.xray), "★ the Squish page opens with X-ray off")
        XCTAssertEqual(FlexibleStagePage.bodyAlpha(views: m.views, edgePick: false, hasDent: true), 1, "★ the Squish page's part is opaque")
        XCTAssertEqual(FlexibleStagePage.bodyAlpha(views: [.xray], edgePick: false, hasDent: true), FlexibleStagePage.xrayBodyAlpha,
                       "★ his X-ray icon there: the ghost")
        XCTAssertTrue(FlexibleStageViews.buttons.contains { $0.view == .xray && $0.icon == FlexibleMainViewToggles.xrayIcon },
                      "★ the Squish page's X-ray icon (the main page's glyph — icons only)")
        // ★ RED CONTROLS: R7-V's stopgap (X-ray on for None / Rim / Skin), and the Squish page always in X-ray
        s.xrayChoice = [:]
        s.controlXrayByFinish = true
        let controlNone = s.xrayOn
        s.controlXrayByFinish = false
        FlexibleStagePage.controlAlwaysXray = true
        let controlSquish = FlexibleStagePage.bodyAlpha(views: [], edgePick: false, hasDent: true)
        FlexibleStagePage.controlAlwaysXray = false
        XCTAssertTrue(controlNone, "★ RED CONTROL: R7-V's stopgap opened his None pad in X-ray")
        XCTAssertEqual(controlSquish, FlexibleStagePage.xrayBodyAlpha, "★ RED CONTROL: the Squish page always in X-ray")
        print("FLEX-R7X1-1 X-ray on open: \(s.xrayOn) for every finish · Squish page opaque · controls: stopgap \(controlNone), Squish ghost \(controlSquish)")
    }

    // MARK: - X1-2: the Lattice view and [Prisms] never turn X-ray on

    func testTheLatticeViewAndPrismsNeverTurnXrayOn() async throws {
        let (r, s, m) = try await hisStrips()
        let p = r.project
        XCTAssertFalse(s.xrayOn, "premise: X-ray off")
        s.latticeOn = false
        XCTAssertFalse(s.latticeIconLit, "the Lattice icon unlit with the view off")
        s.toggleLatticeView()
        XCTAssertTrue(s.latticeOn, "the Lattice icon: on")
        XCTAssertFalse(s.xrayOn, "★ …and X-ray stays off")
        XCTAssertTrue(s.latticeIconLit, "★ the icon is lit by the view itself (a plain show / hide)")
        s.toggleLatticeView()
        XCTAssertFalse(s.latticeOn, "the Lattice icon: off")
        XCTAssertFalse(s.xrayOn)
        s.showFromNote()
        XCTAssertTrue(s.latticeOn, "the note's [Show]: the view on")
        XCTAssertFalse(s.xrayOn, "★ …X-ray stays off")
        s.latticeOn = false
        s.showLatticeView()
        XCTAssertFalse(s.xrayOn, "★ the pill's \"View off · tap to build\" path: X-ray stays off")
        s.togglePrisms()
        XCTAssertTrue(s.prismsOn, "[Prisms] on")
        XCTAssertFalse(s.xrayOn, "★ [Prisms] does not turn X-ray on")
        s.togglePrisms()
        // Exit after the Lattice icon opened Settings (nothing to show then): the view on, not X-ray
        s.latticeOn = false
        s.showLatticeOnExit = true
        s.didExitSettings()
        XCTAssertTrue(s.latticeOn, "Exit shows the view")
        XCTAssertFalse(s.xrayOn, "★ …and leaves X-ray as he set it")
        _ = p
        // ★ RED CONTROL: R7-V's rule — [Prisms] and the Lattice icon turned X-ray on themselves
        s.controlViewsForceXray = true
        s.xrayOn = false
        s.togglePrisms()
        let byPrisms = s.xrayOn
        s.togglePrisms()
        s.xrayOn = false
        s.latticeOn = false
        s.toggleLatticeView()
        let byLattice = s.xrayOn
        s.controlViewsForceXray = false
        s.xrayOn = false
        XCTAssertTrue(byPrisms, "★ RED CONTROL: R7-V's [Prisms] turned X-ray on")
        XCTAssertTrue(byLattice, "★ RED CONTROL: R7-V's Lattice icon turned X-ray on")
        _ = m
        print("FLEX-R7X1-2 Lattice / note / pill / [Prisms] / Exit: X-ray stays off · controls: [Prisms] \(byPrisms), Lattice \(byLattice)")
    }

    // MARK: - X1-3: the printed view

    func testThePrintedViewDrawsTheLatticeWithXrayOffUnlessCovered() async throws {
        let (r, s, m) = try await hisStrips()
        let p = r.project
        s.heat = false
        s.refresh()
        let g = try XCTUnwrap(m.lattice, "premise: his lattice")
        // ★ None, X-ray off, the lattice on: the walls drawn, the printed solid with them, the body see-through
        XCTAssertFalse(s.xrayOn)
        XCTAssertTrue(s.printedView, "★ the printed view")
        let layer = try XCTUnwrap(s.layer(p, stage: .lattice, pageUp: false))
        XCTAssertFalse(layer.hidden, "★ None, X-ray off: the walls are drawn")
        XCTAssertTrue(layer.printed, "★ …with the printed solid (the finish's skin, the pocket's wall and floor)")
        XCTAssertFalse(layer.ghostWalls, "never the ghost out of X-ray")
        XCTAssertEqual(s.bodyAlpha(p, on: .lattice), 0, "★ the body see-through: only its closed surface draws")
        XCTAssertTrue(s.wallsShown, "the walls are seen")
        XCTAssertTrue(s.legendKinds.contains(.lattice), "…so the lattice legend shows (one card)")
        // the body's CLOSED surface is flagged solid, the surface over the lattice region is not; no ghost anywhere
        let mesh = try XCTUnwrap(s.mesh(p, on: .lattice))
        let t = try XCTUnwrap(s.tints(p, on: .lattice, roles: [:], stress: nil))
        let n = mesh.flat.vertexCount
        XCTAssertEqual(t.count, n * 8)
        let mask = g.inputs.mask
        var deepOpen = 0, deepOpenFlagged = 0, farClosed = 0, farClosedUnflagged = 0, ghost = 0
        for v in 0..<n {
            let q = SIMD3<Float>(mesh.flat.positions[3 * v], mesh.flat.positions[3 * v + 1], mesh.flat.positions[3 * v + 2])
            let nn = SIMD3<Float>(mesh.flat.normals[3 * v], mesh.flat.normals[3 * v + 1], mesh.flat.normals[3 * v + 2])
            let a = mask.sample(q - nn * 1.5 * mask.spacing), b = mask.sample(q + nn * 1.5 * mask.spacing)
            let inR = max(a, b), solid = t[v * 8 + 5] > 0.5
            if t[v * 8 + 6] > 0.5 { ghost += 1 }
            if inR > 0.99 { deepOpen += 1; if solid { deepOpenFlagged += 1 } }
            if inR < 0.01 { farClosed += 1; if !solid { farClosedUnflagged += 1 } }
        }
        XCTAssertGreaterThan(deepOpen, 100, "premise: surface over his strips")
        XCTAssertGreaterThan(farClosed, 100, "premise: surface away from them")
        XCTAssertEqual(deepOpenFlagged, 0, "★ over the lattice region the body is open (not solid)")
        XCTAssertEqual(farClosedUnflagged, 0, "★ away from it the body is closed (solid)")
        XCTAssertEqual(ghost, 0, "★ no ghost out of X-ray")
        // X-ray on: R7-V's X-ray, unchanged (the ghost, the walls, no printed solid)
        s.xrayOn = true
        let xl = try XCTUnwrap(s.layer(p, stage: .lattice, pageUp: false))
        XCTAssertFalse(xl.hidden, "X-ray: the walls")
        XCTAssertFalse(xl.printed, "★ X-ray: no printed solid — he sees through the solid")
        XCTAssertEqual(s.bodyAlpha(p, on: .lattice), FlexibleStagePage.xrayBodyAlpha, "the ghost")
        let xt = try XCTUnwrap(s.tints(p, on: .lattice, roles: [:], stress: nil))
        XCTAssertGreaterThan(stride(from: 6, to: xt.count, by: 8).filter { xt[$0] > 0.5 }.count, n / 2, "X-ray: the ghost flags")
        s.xrayOn = false
        // the Lattice view off: the plain model
        s.latticeOn = false
        XCTAssertEqual(s.layer(p, stage: .lattice, pageUp: false)?.hidden, true, "the lattice off: no wall")
        XCTAssertEqual(s.bodyAlpha(p, on: .lattice), 1, "…the opaque model")
        s.latticeOn = true
        // under a full-screen page: nothing drawn
        XCTAssertEqual(s.layer(p, stage: .lattice, pageUp: true)?.hidden, true, "under a page: hidden")
        // ★ RED CONTROL: R7-V's rule — the walls only in X-ray (out of it an opaque body hid them on his None pad)
        s.controlNoPrintedView = true
        s.refresh()
        let control = (hidden: s.layer(p, stage: .lattice, pageUp: false)?.hidden, alpha: s.bodyAlpha(p, on: .lattice), printed: s.printedView)
        s.controlNoPrintedView = false
        s.refresh()
        XCTAssertEqual(control.hidden, true, "★ RED CONTROL: R7-V hid the walls out of X-ray")
        XCTAssertEqual(control.alpha, 1, "★ RED CONTROL: …under the opaque body")
        // Covered: the plain model (the skin hides the lattice — the print)
        m.edit({ $0.finish = FlexibleFinish.covered.rawValue }, recompute: false)
        s.refresh()
        XCTAssertFalse(s.printedView, "★ Covered: no printed view")
        XCTAssertEqual(s.layer(p, stage: .lattice, pageUp: false)?.hidden, true, "★ Covered: no wall drawn out of X-ray")
        XCTAssertEqual(s.bodyAlpha(p, on: .lattice), 1, "★ Covered: the plain, opaque model")
        XCTAssertFalse(s.wallsShown, "Covered, X-ray off: the walls are not seen")
        XCTAssertTrue(s.latticeIconLit, "…but the view is his: the icon stays lit (the lattice shows in X-ray)")
        print("FLEX-R7X1-3 None X-ray off: walls drawn, printed, body alpha 0 · open surface \(deepOpen) (flagged \(deepOpenFlagged)) · closed \(farClosed) (unflagged \(farClosedUnflagged)) · control hidden \(control.hidden ?? false) alpha \(control.alpha) · Covered plain")
    }

    // MARK: - X1-4: the Squish page's X-ray — the bend's prism into the model

    func testTheSquishPagesXrayIsTheBendsPrismIntoTheModel() async throws {
        addTeardownBlock { @MainActor in FlexibleStagePage.controlAlwaysXray = false }
        let r = try FlexiblePressFixtures.a1Project(3, self)
        let p = r.project
        let stage = FlexibleMainStage()
        stage.reduceMotion = { true }
        let m = stage.model(for: p, materialsPath: FlexibleHisProject.materialsPath, stampsPath: FlexibleHisProject.stampsPath, persist: {})
        addTeardownBlock { @MainActor in await m.waitForIdle() }
        m.openScene()
        try await FlexibleSquishFixture.settle(m, "his pad")
        _ = try await FlexibleSquishFixture.build(m, "his pad")
        let g2 = try XCTUnwrap(m.squeezeGroups.first { $0.regions == [4, 2] }, "his two-face Group 2 (the pinch)")
        m.rail = .group(g2.id)
        m.select(4)
        try await FlexibleSquishFixture.solve(m, first: FlexibleSim.groupID(g2.number), "his pad")
        let edge = try XCTUnwrap(FlexibleSettingsSquish.overlayEdge(model: m), "premise: Group 2's field is current")
        let overlay = try XCTUnwrap(FlexiblePageChannels.overlay(model: m, maxEdgeMM: edge))
        var cache: (key: String, dents: [Float])?
        let c = FlexibleStagePage.composeTints(model: m, overlay: overlay, views: [])
        let sq = FlexibleSettingsSquish.shown(model: m, overlay: overlay, channels: c, feCache: &cache)
        let dents = try XCTUnwrap(sq.dents, "premise: the group's dent")
        // X-ray off (the default): no prism, the part opaque, no ghost flag on the body
        XCTAssertTrue(FlexibleStagePage.xrayItems(model: m, overlay: overlay, dents: dents, k: sq.exaggeration, views: []).isEmpty,
                      "★ X-ray off: no bend prism")
        let ct = c.tints ?? []
        let ghostOff = stride(from: 6, to: ct.count, by: 8).filter { ct[$0] > 0.5 }.count
        XCTAssertEqual(ghostOff, 0, "★ X-ray off: the Squish page's body wears no ghost")
        // X-ray on: the ghost, and Group 2's bend as a prism INTO the model, at the full depth
        let items = FlexibleStagePage.xrayItems(model: m, overlay: overlay, dents: dents, k: sq.exaggeration, views: [.xray])
        let prism = try XCTUnwrap(items.first, "★ X-ray on: the bend's prism")
        guard case .shell(let shell) = prism.volume.shape else { return XCTFail("a shell volume") }
        XCTAssertFalse(prism.surfaceOnly, "★ a PRISM — the rest faces, the bent floor and the skirt between (not a surface)")
        let travel = zip(shell.base, shell.offset).map { simd_length($1 - $0) }
        let deepest = travel.max() ?? 0
        // Group 2's own map quads (its faces' columns, 6 flat vertices each), at the bend's full depth
        var groupVerts: [Int] = []
        for r in g2.regions {
            guard let key = m.key(r), let start = overlay.flatStart[key], let st = m.stacks[key] else { continue }
            groupVerts += Array(start..<min(start + 6 * st.columns.count, dents.count / 3))
        }
        XCTAssertFalse(groupVerts.isEmpty, "premise: Group 2's map quads")
        let expect = groupVerts.map { v in simd_length(SIMD3(dents[3 * v], dents[3 * v + 1], dents[3 * v + 2])) }
            .max().map { $0 * Float(sq.exaggeration) } ?? 0
        XCTAssertGreaterThan(deepest, 0.5, "★ the prism reaches INTO the model")
        XCTAssertEqual(deepest, expect, accuracy: max(0.05, expect * 0.02), "★ …to the bend's full depth (k × the dent at full load)")
        let tx = FlexibleStagePage.composeTints(model: m, overlay: overlay, views: [.xray]).tints ?? []
        XCTAssertGreaterThan(stride(from: 6, to: tx.count, by: 8).filter { tx[$0] > 0.5 }.count, 0, "X-ray on: the ghost flags")
        // ★ RED CONTROL: rounds 3–7 — the page always in X-ray, and no prism of the bend
        FlexibleStagePage.controlAlwaysXray = true
        let controlAlpha = FlexibleStagePage.bodyAlpha(views: [], edgePick: false, hasDent: true)
        let controlItems = FlexibleStagePage.xrayItems(model: m, overlay: overlay, dents: dents, k: sq.exaggeration, views: [.xray])
        FlexibleStagePage.controlAlwaysXray = false
        XCTAssertEqual(controlAlpha, FlexibleStagePage.xrayBodyAlpha, "★ RED CONTROL: always the ghost")
        XCTAssertTrue(controlItems.isEmpty, "★ RED CONTROL: no prism of the bend")
        print("FLEX-R7X1-4 Squish X-ray: off → no prism, no ghost flag · on → prism \(shell.base.count) corners, deepest \(deepest) mm (expect \(expect)) · control ghost \(controlAlpha), items \(controlItems.count)")
    }
}
#endif
