// FlexibleAutoFloorFramesProbe — round 7 · AUTO FLOOR + SHAPE's three renders at 13" portrait (P1's harness,
//   FlexibleManualP1FramesProbe): (1) his l-bracket in Auto at 10 lb / 7 mm, its face on Stamp · Elbow 60 × 75 mm turned 90°, the
//   face card with the truth line and the stamp-shaped lattice (X-ray); (2) the same in Manual, a grade 10 → 30 % along Shape, the
//   Model card; (3) his pad's Model card in Manual (one Temperature row; More's Nozzle row is Auto's). Frames only with
//   FLEX_P1_DIR=<dir>.
#if canImport(AppKit) && canImport(MetalKit)
import XCTest
import SwiftUI
import simd
@testable import TopOptFlows
@testable import TopOptKit

extension FlexibleManualP1FramesProbe {
    func testAutoFloorFrames() throws {
        guard Self.dir != nil else { throw XCTSkip("frames only with FLEX_P1_DIR") }
        let face = FlexibleAutoFloorShapeTests.face
        let r = try FlexibleHisProject.restore(FlexibleU21DeleteUndoTests.lbracketDir, asSaved: true)
        addTeardownBlock { r.cleanup() }
        let s = FlexibleMainStage()
        s.reduceMotion = { true }
        let m = s.model(for: r.project, materialsPath: FlexibleHisProject.materialsPath, stampsPath: FlexibleHisProject.stampsPath, persist: {})
        addTeardownBlock { @MainActor in await m.waitForIdle() }
        m.squishSolver.controlNoRefine = true
        m.openScene()
        XCTAssertTrue(pumpUntil(180) { m.sceneState == .ready && m.loadedKeys.allSatisfy { m.stacks[$0] != nil } }, "scene")
        m.edit { st in guard var f = st.face(face) else { return }; f.deepestMM = 7; st.setFace(f) }
        m.setWeight(face, kg: 4.535929094356398)
        m.setShape(face, "stamp")
        m.setStamp(face, source: .library("elbow"), shape: m.library?.shape("elbow"))
        m.updateStamp(face) { $0.widthMM = 60; $0.lengthMM = 75; $0.rotationDeg = 90 }
        pumpUntil(120) { !m.readiness.designing && m.design(face) != nil }
        pump(1)
        let loop = FlexibleSquishLoop()
        m.views = [.xray, .heatOff]
        let h = host(FlexibleStagePage(project: r.project, model: m, loop: loop, onExit: {}), size: Self.p13)
        pump(2)
        func rebuild(_ what: String) {
            m.discardLattice()
            m.generateLattice()
            XCTAssertTrue(pumpUntil(400) { m.lattice != nil && !m.latticeBuilding }, what)
            pump(1)
        }
        // (1) Auto at the floor: the face card's lines and the stamp-shaped lattice
        m.select(face)
        rebuild("Auto")
        let span = m.lattice.map { FlexibleProbe.latticeSpan($0.inputs) }
        log.append("(1) \(m.displayName(face)) Auto · card \(FlexibleFaceRows.floorLines(model: m, region: face)) · Auto row \(m.autoFloorLines()) · drawn ρ \(String(describing: span))")
        try shot("AF_01_13p_lbracket_AUTO_floor_stamp_shaped.png", h, settle: 2)

        // (2) Manual, a grade 10 → 30 % along Shape (the stamp): the Model card, the lattice
        m.setManual(true)
        m.setManualType("gyroid", group: nil); m.setManualBeads(1, group: nil); m.setManualDensity(0.10, group: nil)
        m.setManualGrade(on: true, group: nil); m.setManualGradeValue(end: true, 0.30, group: nil)
        m.setManualGradeAlong("shape", group: nil)
        m.rail = .model
        rebuild("Manual along Shape")
        let ends = m.lattice.flatMap { FlexibleManualCopy.legendEnds($0.inputs) }
        log.append("(2) Manual · part \(String(describing: m.manualLattice(group: nil))) · facts \(m.manualFacts(group: nil).map(\.text)) · legend \(String(describing: ends))")
        try shot("AF_02_13p_lbracket_MANUAL_grade_along_SHAPE.png", h, settle: 2)
        flush("AF_lines_bracket.txt")
    }

    func testAutoFloorPadModelCardFrame() throws {
        guard Self.dir != nil else { throw XCTSkip("frames only with FLEX_P1_DIR") }
        let r = try FlexibleHisProject.restore(FlexibleU21DeleteUndoTests.padDir, asSaved: true)
        addTeardownBlock { r.cleanup() }
        let s = FlexibleMainStage()
        s.reduceMotion = { true }
        let m = s.model(for: r.project, materialsPath: FlexibleHisProject.materialsPath, stampsPath: FlexibleHisProject.stampsPath, persist: {})
        addTeardownBlock { @MainActor in await m.waitForIdle() }
        m.squishSolver.controlNoRefine = true
        m.openScene()
        XCTAssertTrue(pumpUntil(180) { m.sceneState == .ready && m.loadedKeys.allSatisfy { m.stacks[$0] != nil } }, "scene")
        pumpUntil(60) { !m.readiness.designing }
        let loop = FlexibleSquishLoop()
        m.views = [.heatOff]
        let h = host(FlexibleStagePage(project: r.project, model: m, loop: loop, onExit: {}), size: Self.p13)
        pump(2)
        m.setManual(true)
        m.setManualDensity(0.20, group: nil)
        m.rail = .model
        pump(1.5)
        log.append("(3) pad Manual Model card · temp \(m.manualTempC ?? -1) · facts \(m.manualFacts(group: nil).map(\.text))")
        try shot("AF_03_13p_pad_MANUAL_model_card_one_temperature.png", h, settle: 1.5)
        flush("AF_lines_pad.txt")
    }
}
#endif
