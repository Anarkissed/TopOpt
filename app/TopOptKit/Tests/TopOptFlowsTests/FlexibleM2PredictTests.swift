// FlexibleM2PredictTests — round 7 · MANUAL, part M2: predictions, and Auto removed in Manual.
//   His orders of 2026-10-22 ~02:30: "implement the manual add-on. Remove any of the auto processes and make it as simple to
//   understand as possible. The views become what the app assumes based on your values, so cards should say that when a view is
//   selected." His picks: in Manual the depths and the curves become the app's PREDICTION (read only, on the views, the cards and
//   in the curve window); Auto's lattice-type pick and the "can't meet your curve" checks disappear.
// On HIS live pad of 2026-10-21. Each RED control is asserted red inside its test. Written before the code (red first).
import XCTest
import simd
@testable import TopOptFlows
@testable import TopOptKit

@MainActor
final class FlexibleM2PredictTests: XCTestCase {

    override func tearDown() {
        FlexibleStageModel.controlDesignsInManual = false
        FlexibleStageModel.controlManualDepthEditable = false
        FlexibleStageModel.controlManualCurvesEditable = false
        FlexibleStageModel.controlStampOffFaceInManual = false
        super.tearDown()
    }

    func opened(_ dir: URL, _ what: String) async throws -> (FlexibleHisProject.Restored, FlexibleStageModel) {
        let r = try FlexibleHisProject.restore(dir, asSaved: true)
        addTeardownBlock { r.cleanup() }
        let m = try await FlexibleHisProject.openedModel(r.project, test: self)
        try await FlexibleSquishFixture.settle(m, what)
        return (r, m)
    }

    func jobBytes(_ m: FlexibleStageModel) -> String {
        let run: String
        do { run = try m.runJobJSON() } catch { run = "refused: \(error)" }
        return run + "\n" + ((try? m.sceneJob()?.json) ?? "none")
    }

    /// His pad's faces group and a face in it (a Stamp face first), and a Curves face.
    func picks(_ m: FlexibleStageModel) throws -> (group: FlexibleSqueezeGroup, face: Int, curves: Int) {
        let g = try XCTUnwrap(m.squeezeGroups.first { $0.kind == .faces }, "premise: a faces group")
        let stamp = g.regions.first { m.settings.face($0)?.isStampShape == true }
        let r = try XCTUnwrap(stamp ?? g.regions.first)
        let c = try XCTUnwrap(m.settings.loadedFaces.first { !$0.isStampShape }?.faceRegionID, "premise: a Curves face")
        return (g, r, c)
    }

    // MARK: 1 — no design request while Manual is on (RED: a request sent); Auto asks as before

    func testNoDesignRequestWhileManual() async throws {
        let (_, m) = try await opened(FlexibleU21DeleteUndoTests.padDir, "his pad")
        let (g, r, _) = try picks(m)
        XCTAssertGreaterThan(m.coreDesignRequests, 0, "premise: Auto asked core for its designs")
        XCTAssertFalse(m.designs.isEmpty, "premise: Auto's designs landed")
        XCTAssertNotNil(m.settings.loadedFaces.first { m.design($0.faceRegionID) != nil }, "premise")
        let job = jobBytes(m)

        m.setManual(true)
        await m.waitForIdle()
        let d0 = m.coreDesignRequests, a0 = m.coreAutoRequests
        // his inputs in Manual: the weight, the density, the stamp's face
        if let kg = m.groupForce(g)?.upperBound { m.setGroupForce(g.id, kg: kg + 1) }
        m.setManualDensity(0.25, group: nil)
        m.recomputeAll()
        await m.waitForIdle()
        XCTAssertEqual(m.coreDesignRequests, d0, "★ Manual: no design run handed to core")
        XCTAssertEqual(m.coreAutoRequests, a0, "★ Manual: no Auto pick asked")
        XCTAssertFalse(m.designsInFlight, "★ Manual: no design in flight")
        XCTAssertNil(m.reached(region: r), "★ no 'Reaches 0.6 of 7.0 mm'")
        XCTAssertFalse(m.readiness.designing, "★ nothing waits for a design")
        XCTAssertTrue(m.readiness.isReady, "★ Manual is ready to build: \(m.readiness.oneLine)")

        // RED CONTROL: the designs requested in Manual
        FlexibleStageModel.controlDesignsInManual = true
        m.recomputeAll()
        XCTAssertGreaterThan(m.coreDesignRequests, d0, "RED control (designs in Manual) must send a request")
        FlexibleStageModel.controlDesignsInManual = false
        await m.waitForIdle()

        // back to Auto: Auto asks again, and its job is its own
        let d1 = m.coreDesignRequests
        m.setManual(false)
        XCTAssertGreaterThan(m.coreDesignRequests, d1, "★ Auto asks core again")
        if let kg = m.groupForce(g)?.upperBound { m.setGroupForce(g.id, kg: kg - 1) }
        try await FlexibleSquishFixture.settle(m, "his pad · Auto again")
        XCTAssertEqual(jobBytes(m), job, "★ Auto's job bytes unchanged")
        XCTAssertTrue(m.depthIsInput, "★ Auto: the depth is his input")
        XCTAssertNil(m.estimateLine(region: r), "★ Auto: no estimate line")
    }

    // MARK: 2 — the prediction follows the density (stiffer → smaller) and the weight

    func testThePredictionFollowsDensityAndWeight() async throws {
        let (_, m) = try await opened(FlexibleU21DeleteUndoTests.padDir, "his pad")
        m.squishSolver.controlNoRefine = true
        let (g, r, c) = try picks(m)
        m.setManual(true)
        let d0 = m.coreDesignRequests
        func predict(_ what: String) async throws -> Double {
            XCTAssertEqual(m.estimate(region: r), .later, "\(what): ★ edited since the build — no estimate yet")
            XCTAssertEqual(m.estimateLine(region: r), FlexibleManualCopy.estimateLater, what)
            m.discardLattice()
            _ = try await FlexibleSquishFixture.build(m, what)
            try await FlexibleSquishFixture.solve(m, first: FlexibleSim.groupID(g.number), what)
            guard case .mm(let mm) = m.estimate(region: r) else {
                XCTFail("\(what): no estimate (\(m.estimate(region: r)))"); return .nan
            }
            return mm
        }
        m.setManualDensity(0.15, group: nil)
        let soft = try await predict("his pad · 15 %")
        m.setManualDensity(0.30, group: nil)
        let firm = try await predict("his pad · 30 %")
        XCTAssertGreaterThan(soft, 0)
        XCTAssertLessThan(firm, soft * 0.9, "★ a stiffer lattice squishes less (\(firm) vs \(soft) mm)")
        let line = try XCTUnwrap(m.estimateLine(region: r))
        XCTAssertTrue(line.hasPrefix("Squishes \u{2248} "), line)
        XCTAssertTrue(line.contains(String(format: "%.1f mm", firm)), line)
        XCTAssertLessThanOrEqual(line.count, FlexibleRowCopy.maxChars)
        XCTAssertFalse(line.hasSuffix("\u{2026}"), line)
        XCTAssertEqual(m.depthLabel(region: r, deepestMM: m.settings.face(r)?.deepestMM ?? 0), FlexibleManualCopy.chip(firm),
                       "★ the depth chip and the tags say the estimate")
        XCTAssertFalse(FlexibleIndent.face(model: m, region: r).isEmpty, "★ the indent rings follow the prediction")
        // the curve window's profiles: what the lattice does, scaled to its deepest
        m.openFaceCurveModal(c, .flat2D)
        let d = try XCTUnwrap(m.curveDraft)
        let prof = try XCTUnwrap(m.predictedProfiles(d), "★ the predicted profiles once the sim landed")
        XCTAssertEqual(Set(prof.keys), [.along, .across])
        for (a, v) in prof {
            XCTAssertFalse(v.isEmpty, "\(a)")
            XCTAssertEqual(v.max() ?? 0, 1, accuracy: 1e-6, "\(a): scaled to its deepest")
            XCTAssertGreaterThanOrEqual(v.min() ?? -1, 0, "\(a)")
        }
        m.closeCurveModal(keep: false)

        let kg = try XCTUnwrap(m.groupForce(g)?.upperBound)
        m.setGroupForce(g.id, kg: kg * 2)
        let heavy = try await predict("his pad · 30 % · 2× weight")
        XCTAssertGreaterThan(heavy, firm * 1.5, "★ twice the weight squishes more (\(heavy) vs \(firm) mm)")
        XCTAssertEqual(m.coreDesignRequests, d0, "★ no design request through all of it")
        print(String(format: "FLEX-M2 his pad Face %d estimate: 15 %% %.3f mm · 30 %% %.3f mm · 30 %% at 2× %.3f mm · '%@'",
                     r, soft, firm, heavy, m.estimateLine(region: r) ?? "-"))
    }

    // MARK: 3 — the depth controls are read only in Manual (RED: editable)

    func testTheDepthControlsAreReadOnlyInManual() async throws {
        let (_, m) = try await opened(FlexibleU21DeleteUndoTests.padDir, "his pad")
        let (_, r, _) = try picks(m)
        XCTAssertTrue(m.depthIsInput, "Auto: his depth is an input")
        let autoLabel = m.depthLabel(region: r, deepestMM: 7)
        m.setManual(true)
        XCTAssertFalse(m.depthIsInput, "★ Manual: every depth is read only (the card, the chips, an edge's depth)")
        XCTAssertEqual(m.depthLabel(region: r, deepestMM: 7), FlexibleManualCopy.chipNone, "★ the chip says there is no estimate yet")
        XCTAssertEqual(m.estimateLine(region: r), FlexibleManualCopy.estimateLater)
        for s in [FlexibleManualCopy.estimateLater, FlexibleManualCopy.estimateWorking, FlexibleManualCopy.squishes(12.3, weight: "100.5 lb"),
                  FlexibleManualCopy.curveNote(12.3), FlexibleManualCopy.curveNote(nil)] {
            XCTAssertLessThanOrEqual(s.count, FlexibleRowCopy.maxChars, "one line: \(s)")
            XCTAssertFalse(s.hasSuffix("\u{2026}") && !s.hasSuffix("out\u{2026}"), "never cut: \(s)")
            XCTAssertFalse(s.isEmpty)
        }
        // an edge's depth too
        if let p = m.presses.first(where: { $0.strip != nil }) {
            XCTAssertEqual(m.estimateLine(press: p.id), FlexibleManualCopy.estimateLater, "★ an edge's depth is predicted too")
        }
        // RED CONTROL: editable in Manual
        FlexibleStageModel.controlManualDepthEditable = true
        XCTAssertTrue(m.depthIsInput, "RED control (editable) must make the depth an input")
        FlexibleStageModel.controlManualDepthEditable = false
        m.setManual(false)
        XCTAssertTrue(m.depthIsInput)
        XCTAssertEqual(m.depthLabel(region: r, deepestMM: 7), autoLabel, "★ Auto's label unchanged")
    }

    // MARK: 4 — the curve window is read only in Manual (RED: editable)

    func testTheCurveWindowIsReadOnlyInManual() async throws {
        let (_, m) = try await opened(FlexibleU21DeleteUndoTests.padDir, "his pad")
        let (_, _, c) = try picks(m)
        let stored = try XCTUnwrap(m.settings.face(c))
        m.setManual(true)
        XCTAssertFalse(m.curvesAreInput, "★ Manual: the curves are what the lattice does, not an input")
        m.openFaceCurveModal(c, .flat2D)
        let d = try XCTUnwrap(m.curveDraft, "★ the window still opens (what your lattice does)")
        XCTAssertNil(m.predictedProfiles(d), "no build yet: nothing predicted")
        var moved = try XCTUnwrap(d.curves[.along])
        moved.y = moved.y.map { _ in 0.3 }
        m.setDraftCurve(.along, moved)
        XCTAssertEqual(m.curveDraft?.curves, d.curves, "★ no point moves")
        m.mirrorDraftCurve(.along, .leftToRight)
        m.copyDraftCurve(from: .along, to: .across)
        XCTAssertEqual(m.curveDraft?.curves, d.curves, "★ no Mirror, no Copy")
        m.closeCurveModal(keep: true)
        XCTAssertEqual(m.settings.face(c)?.curveX, stored.curveX, "★ nothing written")
        XCTAssertEqual(m.settings.face(c)?.curveY, stored.curveY)

        // RED CONTROL: editable in Manual — the point moves
        FlexibleStageModel.controlManualCurvesEditable = true
        m.openFaceCurveModal(c, .flat2D)
        m.setDraftCurve(.along, moved)
        XCTAssertNotEqual(m.curveDraft?.curves, d.curves, "RED control (editable) must move the point")
        m.closeCurveModal(keep: false)
        FlexibleStageModel.controlManualCurvesEditable = false

        // Auto: the window edits as before
        m.setManual(false)
        XCTAssertTrue(m.curvesAreInput)
        m.openFaceCurveModal(c, .flat2D)
        m.setDraftCurve(.along, moved)
        XCTAssertNotEqual(m.curveDraft?.curves, d.curves, "★ Auto edits as before")
        m.closeCurveModal(keep: false)
        XCTAssertEqual(m.settings.face(c)?.curveX, stored.curveX)
    }

    // MARK: 5 (reviewer check) — core's "N of the stamp lands off the face" is not shown in Manual (RED: shown)

    func testTheStampOffFaceLineIsHiddenInManual() async throws {
        let (_, m) = try await opened(FlexibleU21DeleteUndoTests.padDir, "his pad")
        let r = try XCTUnwrap(m.settings.loadedFaces.first { f in
            m.design(f.faceRegionID)?.designStampOffFace == true }?.faceRegionID, "premise: his pad has a stamp partly off its face")
        let autoN = try XCTUnwrap(m.stampOffFaceN(region: r), "★ Auto: the line is there")
        m.setManual(true)
        XCTAssertNil(m.stampOffFaceN(region: r), "★ Manual: core's design word is not shown")
        // RED CONTROL: shown in Manual
        FlexibleStageModel.controlStampOffFaceInManual = true
        XCTAssertNotNil(m.stampOffFaceN(region: r), "RED control (shown in Manual) must show the line")
        FlexibleStageModel.controlStampOffFaceInManual = false
        m.setManual(false)
        XCTAssertEqual(m.stampOffFaceN(region: r), autoN, "★ Auto unchanged")
    }
}
