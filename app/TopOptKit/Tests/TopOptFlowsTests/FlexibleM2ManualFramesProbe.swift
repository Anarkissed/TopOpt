// FlexibleM2ManualFramesProbe — round 7 · MANUAL, part M2: the read-only depths on the hosted page, and the four renders at 13"
// portrait on HIS pad of 10-21: (1) a face card in Manual, (2) an edge card in Manual, (3) the read-only curve window, (4) a view
// with its estimate line. The hosted checks always run (RED controls asserted red inside); frames only with FLEX_M1_DIR=<dir>.
// The harness is FlexibleM1ManualFramesProbe's (this is an extension of it).
#if canImport(AppKit) && canImport(MetalKit)
import XCTest
import SwiftUI
import AppKit
import MetalKit
import simd
import TopOptDesign
@testable import TopOptFlows
@testable import TopOptKit

extension FlexibleM1ManualFramesProbe {

    func testM2ReadOnlyDepthsAndFramesOnHisPad() throws {
        let r = try FlexibleHisProject.restore(FlexibleU21DeleteUndoTests.padDir, asSaved: true)
        addTeardownBlock { r.cleanup() }
        addTeardownBlock { @MainActor in FlexibleStageModel.controlManualDepthEditable = false }
        let s = FlexibleMainStage()
        s.reduceMotion = { true }
        let m = s.model(for: r.project, materialsPath: FlexibleHisProject.materialsPath, stampsPath: FlexibleHisProject.stampsPath, persist: {})
        addTeardownBlock { @MainActor in await m.waitForIdle() }
        m.squishSolver.controlNoRefine = true
        m.openScene()
        XCTAssertTrue(pumpUntil(180) { m.sceneState == .ready && m.loadedKeys.allSatisfy { m.stacks[$0] != nil } }, "scene")
        let strips = m.presses.filter { $0.strip != nil }
        pumpUntil(240) { strips.allSatisfy { m.pressKey($0.id) != nil } }
        pumpUntil(60) { !m.readiness.designing }

        // Manual on, his lattice built (no design asked), every group's sim solved
        m.setManual(true)
        let asked = m.coreDesignRequests
        m.discardLattice()
        m.generateLattice()
        XCTAssertTrue(pumpUntil(400) { m.lattice != nil && !m.latticeBuilding && !m.latticeIsStale }, "lattice (Manual): \(m.latticeError ?? "")")
        let fg = try XCTUnwrap(m.squeezeGroups.first { g in g.kind == .faces && g.regions.contains { m.settings.face($0)?.isStampShape == true } }
                               ?? m.squeezeGroups.first { $0.kind == .faces })
        let face = try XCTUnwrap(fg.regions.first { m.settings.face($0)?.isStampShape == true } ?? fg.regions.first)
        let eg = m.squeezeGroups.first { $0.kind == .edges }
        let ids = [fg] .map { FlexibleSim.groupID($0.number) } + (eg.map { [FlexibleSim.groupID($0.number)] } ?? [])
        m.startSquishSims(first: ids[0])
        XCTAssertTrue(pumpUntil(600) { ids.allSatisfy { m.squish[$0] != nil && m.squish[$0] != .pending } }, "the sims (Manual)")
        XCTAssertEqual(m.coreDesignRequests, asked, "★ Manual: no design asked to build or solve")

        let loop = FlexibleSquishLoop()
        m.views = [.heatOff]
        let h = host(FlexibleStagePage(project: r.project, model: m, loop: loop, onExit: {}), size: Self.p13)
        pump(3)

        // (1) a face card in Manual: one read-only line, no box
        m.rail = .group(fg.id)
        m.select(face)
        pump(2)
        XCTAssertNil(h.frames.all["numberBox-deepest-\(face)"], "★ Manual: no Deepest squish box on the face card")
        XCTAssertNotNil(h.frames.all["manualEstimate-\(face)"], "★ Manual: the estimate line on the face card")
        log.append("(1) Face \(face) (\(m.groupName(fg))): '\(m.estimateLine(region: face) ?? "-")' · chip '\(m.depthLabel(region: face, deepestMM: m.settings.face(face)?.deepestMM ?? 0))' · rings \(FlexibleIndent.face(model: m, region: face).count) segments")
        try shot("M2_01_13p_pad_face_card_MANUAL.png", h, settle: 1.5)
        // RED CONTROL: the depth editable in Manual — the box is back
        FlexibleStageModel.controlManualDepthEditable = true
        m.objectWillChange.send()
        pump(1.5)
        XCTAssertNotNil(h.frames.all["numberBox-deepest-\(face)"], "RED control (editable) must draw the Deepest squish box")
        FlexibleStageModel.controlManualDepthEditable = false
        m.objectWillChange.send()
        pump(1.5)
        XCTAssertNil(h.frames.all["numberBox-deepest-\(face)"], "back to read only")

        // (2) an edge card in Manual: the depth predicted, Tilt / Twist kept
        if let eg, let id = eg.presses.first, let label = m.press(id)?.strip?.label {
            m.rail = .group(eg.id)
            m.selectedPress = id
            pump(2)
            XCTAssertNil(h.frames.all["numberBox-flat-depth-card-\(id.uuidString)"], "★ Manual: no depth box on the edge card")
            XCTAssertNotNil(h.frames.all["manualEstimate-\(label)"], "★ Manual: the edge's estimate line")
            let designLines = h.frames.all.keys.filter { $0.hasPrefix("pressLine:\(label):") && ($0.contains("designing") || $0.contains("reach") || $0.contains("% off")) }
            XCTAssertTrue(designLines.isEmpty, "★ Manual: no core-design line (designing / can't reach / % off) (\(designLines))")
            XCTAssertTrue(h.frames.all.keys.contains { $0.hasPrefix("numberBox-flat-twist-") || $0.hasPrefix("numberBox-flat-tilt-") || $0.contains("twist") },
                          "★ Tilt / Twist stay his (\(h.frames.all.keys.filter { $0.contains("flat") }.sorted()))")
            log.append("(2) \(label) (\(m.groupName(eg))): '\(m.estimateLine(press: id) ?? "-")' · chip '\(FlexibleManualCopy.chipText(m.estimate(press: id)))'")
            try shot("M2_02_13p_pad_edge_card_MANUAL.png", h, settle: 1.5)
        } else {
            XCTFail("premise: his pad has an edges group with a press")
        }

        // (3) the curve window, read only: the predicted profile, no points, no Mirror / Copy, one line, [Done]
        let curves = try XCTUnwrap(m.settings.loadedFaces.first { !$0.isStampShape }?.faceRegionID)
        if let g3 = m.squeezeGroup(of: curves) { m.rail = .group(g3.id) }
        m.select(curves)
        pump(1)
        m.openFaceCurveModal(curves, .flat2D)
        pump(2)
        XCTAssertNotNil(h.frames.all["curveDone"], "★ the read-only window's [Done]")
        XCTAssertNil(h.frames.all["curveOK"], "★ no [OK]")
        XCTAssertNil(h.frames.all["curveLegend"], "★ no Mirror / Copy")
        if let d = m.curveDraft, let p = m.predictedProfiles(d) {
            log.append("(3) Face \(curves) window: profiles \(p.keys.map(\.rawValue).sorted()) · '\(FlexibleManualCopy.curveNote(m.predictedDeepest(d)))'")
        } else { log.append("(3) Face \(curves) window: no profiles") }
        try shot("M2_03_13p_pad_curve_window_READ_ONLY.png", h, settle: 1.5)
        m.closeCurveModal(keep: false)
        pump(1)

        // (4) a view with its estimate line: Bend on, the stamp face selected
        m.rail = .group(fg.id)
        m.select(face)
        m.views = [.bend, .heatOff]
        pump(2.5)
        log.append("(4) view line: '\(m.manualViewLine ?? "-")' · card: '\(m.estimateLine(region: face) ?? "-")'")
        XCTAssertTrue(m.manualViewLine?.contains("estimate \u{2248}") == true, "★ the view's line says the estimate (\(m.manualViewLine ?? "-"))")
        try shot("M2_04_13p_pad_bend_estimate_line_MANUAL.png", h, settle: 2.5)
        flush("M2_lines.txt")
    }
}
#endif
