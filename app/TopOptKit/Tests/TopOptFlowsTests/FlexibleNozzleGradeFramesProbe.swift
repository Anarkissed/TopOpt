// FlexibleNozzleGradeFramesProbe — round 7 · ONE nozzle row + its grade: two renders at 13" portrait on HIS pad of 10-21 (P1's
//   harness, FlexibleManualP1FramesProbe): (1) Manual, the Model card scrolled to More — "Nozzle °C" (no Auto chip), Grade On
//   190 → 220 °C Stepped, the slicer line; (2) Auto, the same rows with the Auto chip, Grade On 190 → 240 °C Default and the
//   "Shown in the sim only" line. Frames only with FLEX_P1_DIR=<dir>.
#if canImport(AppKit) && canImport(MetalKit)
import XCTest
import SwiftUI
import AppKit
@testable import TopOptFlows
@testable import TopOptKit

extension FlexibleManualP1FramesProbe {
    /// Every scroll view of the page scrolled to its end (the Model card's More rows into view).
    func scrollToEnd(_ v: NSView) {
        if let s = v as? NSScrollView, let doc = s.documentView {
            let clip = s.contentView.bounds.height
            let y = doc.isFlipped ? Swift.max(0, doc.frame.height - clip) : 0
            s.contentView.scroll(to: NSPoint(x: 0, y: y))
            s.reflectScrolledClipView(s.contentView)
        }
        for c in v.subviews { scrollToEnd(c) }
    }

    func testNozzleGradeFrames() throws {
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
        // (1) Manual: one Nozzle °C row, Grade On 190 → 220 Stepped
        m.setManual(true)
        m.setManualTemp(190)
        m.setNozzleGrade(on: true)
        m.setNozzleGradeStepped(true)
        m.rail = .model
        pump(1.5)
        scrollToEnd(h.view)
        log.append("(1) pad MANUAL · nozzle \(m.nozzleRowTempC ?? -1) · rows \(FlexibleStageModel.nozzleRows(manual: true, hasData: true, gradeOn: true)) · grade \(String(describing: m.settings.nozzleGrade)) · lines \(m.nozzleGradeLines().map(\.text)) · span \(String(describing: m.buildSpanMM))")
        try shot("NG_01_13p_pad_MANUAL_one_nozzle_row_grade_stepped.png", h, settle: 1.5)
        // (2) Auto: the Auto chip, Grade On 190 → 240 Default
        m.setManual(false)
        m.setNozzleTemp(nil)
        m.setNozzleGradeEnd(top: true, 240)
        m.setNozzleGradeStepped(false)
        pump(1.5)
        scrollToEnd(h.view)
        log.append("(2) pad AUTO · nozzle \(String(describing: m.nozzleRowTempC)) · grade \(String(describing: m.settings.nozzleGrade)) · lines \(m.nozzleGradeLines().map(\.text))")
        try shot("NG_02_13p_pad_AUTO_nozzle_row_grade_default.png", h, settle: 1.5)
        flush("NG_lines_pad.txt")
    }
}
#endif
