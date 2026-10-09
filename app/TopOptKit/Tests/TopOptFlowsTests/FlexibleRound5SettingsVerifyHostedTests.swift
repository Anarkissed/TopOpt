// FlexibleRound5SettingsVerifyHostedTests — the batch S verification pass, HOSTED (offscreen, never the
// app) on HIS project 0004 (task 2026-09-29-flexible-screens): the S9 snapshot on the PAGE itself —
// the page appears while the part is still OPENING; an edit then is a change ("Save & Exit"), the
// open's own re-read of the main page is not ("Exit"). The model-level rule is pinned by
// FlexibleRound5SettingsVerifyTests; this pins the page's wiring (its onAppear and its .ready).
#if canImport(AppKit)
import XCTest
import SwiftUI
@testable import TopOptFlows
@testable import TopOptKit

extension FlexibleRound5SettingsHostedTests {

    func testThePageCountsAnEditMadeWhileThePartOpens() throws {
        var lines: [String] = []
        for edits in [false, true] {
            let his = try FlexibleHisProject.restore()
            addTeardownBlock { @MainActor in his.cleanup() }
            // the main page's Top changed since the Flexible settings were saved: the open re-reads it
            let top = try XCTUnwrap(his.project.selection.groups.first { $0.name == "Top" })
            his.project.force.setWeight(top.id, kg: 12)
            let stage = FlexibleMainStage()
            stage.reduceMotion = { true }
            let m = stage.model(for: his.project, materialsPath: FlexibleHisProject.materialsPath,
                                stampsPath: FlexibleHisProject.stampsPath, persist: {})
            addTeardownBlock { @MainActor in await m.waitForIdle() }
            XCTAssertEqual(m.sceneState, .idle, "premise: the part is not open yet")
            let before = m.settings
            let h = host(FlexibleStagePage(project: his.project, model: m, onExit: {}), size: CGSize(width: 1194, height: 834))
            XCTAssertTrue(pumpUntil(10) { m.sceneState != .idle }, "the page's appear opens the part")
            XCTAssertEqual(m.sceneState, .opening, "premise: still opening")
            if edits { m.edit { $0.feel = $0.feel == "damped" ? "springy" : "damped" } }   // the [Model] tab is live
            XCTAssertTrue(pumpUntil(120) { m.sceneState == .ready && !m.readiness.designing && !m.designsInFlight }, "open")
            pump(0.6)
            let t = title(h)
            lines.append("edit while opening \(edits): the open changed the settings \(m.settings != before) · title '\(t ?? "-")'")
            XCTAssertEqual(t, edits ? FlexibleSettingsExit.saveAndExit : FlexibleSettingsExit.exit,
                           edits ? "his edit while it opened is a change" : "the open's own read is not his change")
            h.window.orderOut(nil); h.window.contentView = nil
        }
        print("FLEX-R5V-HOSTED opening:\n  " + lines.joined(separator: "\n  "))
    }
}
#endif
