// FlexibleX20bTests — round 7, step X20b: his answers of 2026-10-20 (~16:05 and ~19:10, binding):
//   1 "Edge Play shows CORE'S FULL DESIGN DEPTH (e.g. Edge 12 5.6 mm, Edge 9 3.3 mm), not held back" — an edges group's sim is
//     solved per press and each press scaled to core's design depth; no band, no ½ cut; only a true fold cuts it, said
//                                                                                            — testEdgePlayIsCoresFullDesignDepth
//   2 "On-part curves: REMOVE them from the part, but show the indent when selected like the stamp"
//                                                                                            — testTheCurvesLeftThePartAndTheIndentShows
//   3 "FACE presses use the SAME 2D/3D curve window"                                         — testAFaceUsesTheSameCurveWindow
//     (hosted, the Shape row's [2D] / [3D] and the window: FlexibleU2Tests.testX20bAFacesShapeRowOpensTheWindow)
//   4 "a face pressed by ANOTHER group lying over the squished lattice BENDS ALONG too"      — testAnotherGroupsFaceBendsAlong
// On HIS pad of 10-20 (round7/batch_u1/his_live_1020) for 1–3; his 0004 split (Face 3 its own group) for 4, round 5's own case.
// Each RED control is asserted red inside its test.
import XCTest
import simd
@testable import TopOptFlows
@testable import TopOptKit

@MainActor
final class FlexibleX20bTests: XCTestCase {
    typealias Axis = FlexiblePressCurveBaselines.Axis

    override func tearDown() {
        FlexibleBackend.sendsPresses = true
        FlexibleFERequest.controlOneScalar = false
        FlexibleStageModel.controlAsBuiltTargets = false
        FlexibleIndent.controlCurvesOnPart = false
        FlexiblePressCurveModal.controlLiveEdits = false
        FlexibleSettingsSquish.controlOtherGroupStill = false
        super.tearDown()
    }

    func hisPad() async throws -> (FlexibleHisProject.Restored, FlexibleStageModel) {
        let r = try FlexibleHisProject.restore(FlexibleU1Tests.liveDir, asSaved: true)
        addTeardownBlock { r.cleanup() }
        let s = FlexibleMainStage()
        s.reduceMotion = { true }
        let m = s.model(for: r.project, materialsPath: FlexibleHisProject.materialsPath, stampsPath: FlexibleHisProject.stampsPath, persist: {})
        m.keepCombinedField = true
        addTeardownBlock { @MainActor in await m.waitForIdle() }
        m.openScene()
        try await FlexibleSquishFixture.settle(m, "his pad of 10-20")
        return (r, m)
    }

    // MARK: 1 — edge Play at core's full design depth

    struct Played { let m: FlexibleStageModel; let simID: String; let field: FlexibleFEField; let deepest: [String: Double]; let design: [String: Double] }

    func play() async throws -> Played {
        let (_, m) = try await hisPad()
        let strips = m.presses.filter { $0.strip != nil }
        XCTAssertEqual(strips.compactMap { $0.strip?.label }.sorted(), ["Edge 12", "Edge 9"], "premise: his Group 2")
        try await FlexibleHisProject.waitFor(240, "his presses registered") { strips.allSatisfy { m.pressKey($0.id) != nil } }
        try await FlexibleHisProject.waitFor(300, "core's verdict on his presses") {
            strips.allSatisfy { m.pressSupport[$0.id].map { $0.inJob || $0.reason != .designing } ?? false }
        }
        try await FlexibleSquishFixture.settle(m, "his pad again")
        let g = try XCTUnwrap(m.squeezeGroups.first { $0.kind == .edges }, "his edges group")
        let id = FlexibleSim.groupID(g.number)
        _ = try await FlexibleSquishFixture.build(m, "his pad")
        try await FlexibleSquishFixture.solve(m, first: id, "his pad")
        m.startSquishSims(first: id)
        try await FlexibleHisProject.waitFor(400, "Group 2's sim") { m.squish[id] != nil && m.squish[id] != .pending }
        await m.squishSolver.waitForIdle()
        let field = try XCTUnwrap(m.squish[id]?.field, "landed: \(m.squish[id]?.failure ?? "-")")
        var deepest: [String: Double] = [:], design: [String: Double] = [:]
        for p in strips {
            let st = try XCTUnwrap(m.pressRegistrations[p.id]?.stack, "core's press stack")
            // as Play shows it: the field × the Squish page's k for an edges group
            let k = FlexiblePressHeat.shownScale(field)
            deepest[p.strip!.label] = (st.columns.indices.map { field.columnCompression(stack: st, col: $0, pinched: false) }.max() ?? 0) * k
            let d = try XCTUnwrap(m.pressDesign(p.id), "core's design")
            design[p.strip!.label] = FlexiblePinch.core(d, stack: st).buildableDepthMM.compactMap { $0 }.max() ?? 0
        }
        return Played(m: m, simID: id, field: field, deepest: deepest, design: design)
    }

    func testEdgePlayIsCoresFullDesignDepth() async throws {
        let a = try await play()
        print("FLEX-X20B-1 core's design \(a.design) · Play shows \(a.deepest) · design depth \(a.field.designDepth) · true-fold cut \(a.field.trueFoldCut ?? 1)"
              + " · gmax \(a.field.gmax) (×1: ½ bound \(a.field.gmax <= FlexibleFE.safeGradient)) · min det \(a.field.minDeterminant(k: 1)) · chip '\(a.m.notTunedLine(simID: a.simID) ?? "-")'")
        XCTAssertTrue(a.field.designDepth, "★ the sim is scaled to core's design depth, per press")
        XCTAssertFalse(a.field.clamped, "★ no band")
        XCTAssertNil(a.field.foldShare, "★ no ½ cut")
        XCTAssertEqual(FlexiblePressHeat.shownScale(a.field), 1, "★ shown at × 1 (the Squish page's and the heat's k)")
        XCTAssertGreaterThanOrEqual(a.field.minDeterminant(k: 1), FlexibleFE.trueFoldDet - 1e-6, "★ no cell of the part turned inside out")
        let keep = a.field.trueFoldCut ?? 1
        for (label, want) in a.design {
            XCTAssertGreaterThan(want, 1, "premise: core designs \(label) a real squish")
            XCTAssertEqual(a.deepest[label] ?? 0, want * keep, accuracy: 0.05 * want, "★ \(label): Play's deepest squish is core's design depth")
        }
        if let cut = a.field.trueFoldCut {
            XCTAssertEqual(a.m.notTunedLine(simID: a.simID), FlexibleRowCopy.pressFoldCut(percent: Int((cut * 100).rounded(.down))), "★ a true-fold cut is said")
        } else {
            XCTAssertNil(a.m.notTunedLine(simID: a.simID), "★ nothing held back, nothing said")
        }
        XCTAssertLessThanOrEqual(FlexibleRowCopy.pressFoldCut(percent: 88).count, 44)

        // RED CONTROL (C1): one scalar for the group, as-built targets, the band and the ½ cut — Edge 12 2.68 mm, Edge 9 2.98 mm
        FlexibleFERequest.controlOneScalar = true
        FlexibleStageModel.controlAsBuiltTargets = true
        let b = try await play()
        print("FLEX-X20B-1 RED (C1's hold): Play shows \(b.deepest) · scale \(b.field.scale) asked \(b.field.coreRatio) clamped \(b.field.clamped) fold share \(b.field.foldShare ?? 1)")
        XCTAssertFalse(b.field.designDepth, "RED CONTROL: C1's calibration")
        XCTAssertLessThan(b.deepest["Edge 12"] ?? .infinity, 0.6 * (b.design["Edge 12"] ?? 0), "RED CONTROL: Edge 12 held back (C1's 2.68 of 5.6 mm)")
    }

    // MARK: 2 — the curves left the part; the selected press shows its indent

    func testTheCurvesLeftThePartAndTheIndentShows() async throws {
        let (_, m) = try await hisPad()
        // a face on Curves (his Face 5 carries a stamp: put it on Curves, then bend its X curve)
        let face = try XCTUnwrap(m.loadedKeys.map(\.region).first { m.settings.face($0) != nil }, "a pressed face")
        m.setShape(face, "curves")
        try await FlexibleSquishFixture.settle(m, "Curves")
        try await FlexibleHisProject.waitFor(60, "its drawn map") { m.key(face).map { m.liveS[$0] != nil } ?? false }
        let f = try XCTUnwrap(m.settings.face(face))
        XCTAssertEqual(FlexibleStageOverlays.curveEditorsOnPart(f), [], "★ no curve editor on the face")
        let flat = FlexibleIndent.face(model: m, region: face)
        XCTAssertFalse(flat.isEmpty, "★ the face's indent is drawn")
        m.edit { s in guard var g = s.face(face) else { return }; g.curveX = FlexCurve(x: [0, 0.5, 1], y: [0, 1, 0]); s.setFace(g) }
        m.curveChanged(region: face)
        try await FlexibleHisProject.waitFor(60, "the new drawn map") { FlexibleIndent.face(model: m, region: face) != flat }
        let bent = FlexibleIndent.face(model: m, region: face)
        XCTAssertNotEqual(bent, flat, "★ the indent follows his drawing")
        XCTAssertTrue(FlexibleIndent.levels.allSatisfy { l in bent.contains { $0.level == l } }, "★ outline, half and deepest zone")

        // an edge on Curves: no editor on the part, its indent
        let e = try XCTUnwrap(m.presses.first { $0.strip?.label == "Edge 12" })
        m.setPressShape(e.id, "curves")
        try await FlexibleHisProject.waitFor(120, "Edge 12's cut") { m.flatCut(e.id) != nil }
        XCTAssertEqual(FlexiblePressCurveLayer.editorsOnPart(model: m, press: e.id, projection: nil).count, 0, "★ no curve editor on the edge")
        let edge = FlexibleIndent.press(model: m, id: e.id)
        XCTAssertFalse(edge.isEmpty, "★ the edge's indent is drawn")
        m.setPressCurve(e.id, .across, FlexCurve(x: [0, 0.5, 1], y: [0, 1, 0]))
        let edgeBent = FlexibleIndent.press(model: m, id: e.id)
        XCTAssertNotEqual(edgeBent, edge, "★ it follows his drawing")
        let sv = m.key(face).flatMap { m.liveS[$0] } ?? []
        print("FLEX-X20B-2 face \(m.displayName(face)): \(flat.count) → \(bent.count) segments (per level \(FlexibleIndent.levels.map { l in bent.filter { $0.level == l }.count })) · S \(sv.min() ?? -1)…\(sv.max() ?? -1) of \(sv.count) · Edge 12: \(edge.count) → \(edgeBent.count) (per level \(FlexibleIndent.levels.map { l in edgeBent.filter { $0.level == l }.count }))")
        // the views: no FlexibleCurveEditor mounted on the part outside the red control
        let src = try String(contentsOf: FlexibleHisProject.repoRoot.appendingPathComponent("app/TopOptKit/Sources/TopOptFlows/FlexibleStagePage.swift"), encoding: .utf8)
        XCTAssertTrue(src.contains("ForEach(Self.curveEditorsOnPart(f)"), "★ the face's editors are mounted only through curveEditorsOnPart")

        // RED CONTROL: the curves on the part (before X20b)
        FlexibleIndent.controlCurvesOnPart = true
        XCTAssertEqual(FlexibleStageOverlays.curveEditorsOnPart(f), ["x", "y"], "RED CONTROL: both curves on the face")
        XCTAssertEqual(FlexiblePressCurveLayer.editorsOnPart(model: m, press: e.id, projection: nil).count, 2, "RED CONTROL: both on the edge")
    }

    // MARK: 3 — a face's curves in the same window

    func testAFaceUsesTheSameCurveWindow() async throws {
        let (r, m) = try await hisPad()
        let face = try XCTUnwrap(m.loadedKeys.map(\.region).first { m.settings.face($0) != nil }, "a pressed face")
        m.setShape(face, "curves")
        m.save()
        let before = try XCTUnwrap(m.settings.face(face))
        let bx = FlexCurve(x: [0, 0.4, 1], y: [0.2, 1, 0.2]), by = FlexCurve(x: [0, 0.6, 1], y: [0.5, 0.9, 0.1])
        m.openFaceCurveModal(face, .flat2D)
        XCTAssertEqual(m.curveDraft?.face, face, "★ the window opens on the face")
        XCTAssertEqual(m.curveDraft?.curves, [.along: before.curveX, .across: before.curveY], "★ on its X and Y curves")
        XCTAssertEqual(FlexiblePressCurveModal.faceTables2D().map(\.axes), [[.along], [.across]], "★ 2D: two tables, X above Y")
        let c3 = FlexiblePressCurveModal.faceCurves3D()
        XCTAssertEqual(Set(c3.map(\.axis)), [.along, .across], "★ 3D: both on one table")
        XCTAssertLessThan(simd_distance(c3[0].baseline.at(0.5), c3[1].baseline.at(0.5)), 1e-9, "crossing at their middles")
        m.setDraftCurve(.along, bx); m.setDraftCurve(.across, by)
        XCTAssertEqual(m.settings.face(face)?.curveX, before.curveX, "★ nothing written while the window is open")
        m.closeCurveModal(keep: false)
        XCTAssertEqual(m.settings.face(face)?.curveX, before.curveX, "★ Cancel: as before")
        XCTAssertEqual(m.settings.face(face)?.curveY, before.curveY)
        m.openFaceCurveModal(face, .table3D)
        m.setDraftCurve(.along, bx); m.setDraftCurve(.across, by)
        m.closeCurveModal(keep: true)
        XCTAssertEqual(m.settings.face(face)?.curveX, bx, "★ OK keeps X")
        XCTAssertEqual(m.settings.face(face)?.curveY, by, "★ OK keeps Y")
        r.project.performUndo()
        XCTAssertEqual(m.settings.face(face)?.curveX, before.curveX, "★ one undo returns both")
        XCTAssertEqual(m.settings.face(face)?.curveY, before.curveY)
        // RED CONTROL: every drag written at once — Cancel keeps it
        FlexiblePressCurveModal.controlLiveEdits = true
        m.openFaceCurveModal(face, .flat2D)
        m.setDraftCurve(.along, bx)
        m.closeCurveModal(keep: false)
        XCTAssertEqual(m.settings.face(face)?.curveX, bx, "RED CONTROL: Cancel kept the drag")
    }

    // MARK: 4 — another group's face over the squished lattice bends along

    func testAnotherGroupsFaceBendsAlong() async throws {
        let r = try FlexibleHisProject.restore()
        addTeardownBlock { r.cleanup() }
        let m = try await FlexibleHisProject.openedModel(r.project, test: self)
        m.newGroup(with: 3)   // his img 4's split: Face 3 its own squeeze
        try await FlexibleSquishFixture.settle(m, "his 0004 split")
        try await FlexibleHisProject.waitFor(30, "the drawn maps") { m.loadedKeys.allSatisfy { m.liveS[$0] != nil } }
        let o = try XCTUnwrap(FlexiblePageChannels.overlay(model: m))
        m.select(3)
        let mine = Set([3])
        func moved() throws -> [Int: Float] {
            let c = FlexiblePageChannels.channels(model: m, overlay: o, xray: true, drawnLattice: nil)
            var cache: (key: String, dents: [Float])?
            let sq = FlexibleSettingsSquish.shown(model: m, overlay: o, channels: c, feCache: &cache)
            XCTAssertFalse(sq.fe, "premise: no lattice — the column preview")
            return FlexibleRound5SquishExitTests.quadMotion(try XCTUnwrap(sq.dents), overlay: o, model: m)
        }
        let now = try moved()
        let others = now.filter { !mine.contains($0.key) }
        print("FLEX-X20B-4 Face 3 plays: " + now.sorted { $0.key < $1.key }.map { "\(m.faceName($0.key)) \(String(format: "%.2f", $0.value))" }.joined(separator: " · "))
        XCTAssertGreaterThan(now[3] ?? 0, 0.05, "premise: Face 3 dents")
        XCTAssertTrue(others.values.contains { $0 > 0.05 }, "★ another group's face over Face 3's lattice bends along")
        XCTAssertTrue(others.values.allSatisfy { $0 <= (now[3] ?? 0) + 1e-4 }, "★ never more than the press itself")
        // RED CONTROL: round 5's rule — another group's face stands still
        FlexibleSettingsSquish.controlOtherGroupStill = true
        let red = try moved()
        XCTAssertTrue(red.filter { !mine.contains($0.key) }.values.allSatisfy { $0 == 0 }, "RED CONTROL: it stood still")
    }
}
