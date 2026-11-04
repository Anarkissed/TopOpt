// FlexibleRevealFramesProbe — round 7 · T3's two renders (P1's harness, FlexibleManualP1FramesProbe): his project 0004
//   (FlexibleSettingsPageHostedTests' own), the Settings page AS OPENED at 11" landscape and 13" portrait, the selected face's
//   card (face 5, as the hosted test opens it) against the panel's scroll. Frames only with FLEX_P1_DIR=<dir>.
#if canImport(AppKit) && canImport(MetalKit)
import XCTest
import SwiftUI
@testable import TopOptFlows
@testable import TopOptKit

extension FlexibleManualP1FramesProbe {
    func testRevealFramesAsOpened() throws {
        guard Self.dir != nil else { throw XCTSkip("frames only with FLEX_P1_DIR") }
        let his = try FlexibleHisProject.restore()
        addTeardownBlock { @MainActor in his.cleanup() }
        let stage = FlexibleMainStage()
        stage.reduceMotion = { true }
        let m = stage.model(for: his.project, materialsPath: FlexibleHisProject.materialsPath,
                            stampsPath: FlexibleHisProject.stampsPath, persist: {})
        addTeardownBlock { @MainActor in await m.waitForIdle() }
        m.openScene()
        XCTAssertTrue(pumpUntil(120) {
            m.sceneState == .ready && m.loadedKeys.allSatisfy { m.stacks[$0] != nil && m.geometry[$0] != nil }
                && !m.readiness.designing && !m.designsInFlight
        }, "the scene, stacks and designs")
        pump(0.3)
        m.select(5)   // the hosted test's "as opened": face 5 (last pressed), the card last in the tab
        for (name, size) in [("T3_01_11l_as_opened.png", CGSize(width: 1194, height: 834)),
                             ("T3_02_13p_as_opened.png", Self.p13)] {
            let h = host(FlexibleStagePage(project: his.project, model: m, onExit: {}), size: size)
            pump(2.5)
            func local(_ k: String) -> CGRect {
                guard let f = h.frames.all[k] else { return .null }
                guard let p = h.frames.all["page"] else { return f }
                return f.offsetBy(dx: -p.minX, dy: -p.minY)
            }
            let v = local("panelScroll"), c = local("faceCard")
            let on = c.minY >= v.minY - 1 && c.maxY <= v.maxY + 1
            log.append(String(format: "%@: selected %@ · card %.0f–%.0f in the panel's scroll %.0f–%.0f (%.0f pt) %@", name,
                              m.selectedRegion.map { m.faceName($0) } ?? "none", c.minY, c.maxY, v.minY, v.maxY, v.height, on ? "✓" : "✗ OFF"))
            try shot(name, h, settle: 1)
            h.window.orderOut(nil); h.window.contentView = nil
        }
        flush("T3_lines.txt")
    }
}
#endif
