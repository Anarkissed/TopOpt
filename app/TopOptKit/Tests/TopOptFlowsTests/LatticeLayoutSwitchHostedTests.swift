// LatticeLayoutSwitchHostedTests — the new engine on the REAL Lattice Setup page, at the sweep's six windows (the reviewer's
// go of 2026-11-12 20:21Z, item 4: "checked at 6 windows"). ★ Install 3 (his 11-17 "Implement it as soon as possible"): the
// "New engine (test)" switch is retired, so with nothing set the new engine is the preview. One Structural part, the lattice
// preview armed the way he arms it (the cube's tap; the page's Save when the settings open first), then:
//   * by default: the lines come, wholly inside the window, and core's numbers come back (the timing line: the layout was laid
//     and its bars handed to the 3D view);
//   * RED CONTROL, the tests-only hook (`newEngineTest = false`, never stored, no row): the old preview, no new-engine lines.
#if canImport(AppKit) && canImport(MetalKit)
import XCTest
import SwiftUI
@testable import TopOptFlows
@testable import TopOptKit

final class LatticeLayoutSwitchHostedTests: XCTestCase {

    @MainActor
    func testTheNewEngineIsThePreviewOnLatticeSetupAtTheSixWindows() throws {
        let settings = AppSettings.shared
        let was = settings.newEngineTest
        addTeardownBlock { @MainActor in AppSettings.shared.newEngineTest = was }
        let names = ["13L", "13P", "11L", "11P", "MSL", "MSP"]
        for (name, size) in zip(names, AppBuildHost.sweep) {
            settings.newEngineTest = true
            let r = try FlexiblePressFixtures.a1Project(3, self, facePrism: false)
            let p = r.project
            p.lattice.flexible = nil
            p.lattice.clearLatticeType()
            p.lattice.chooseLatticeType(.structural)
            p.lattice.enabled = true
            XCTAssertNotNil(p.importedFile, "premise: the part has a model file for core to read")
            let h = AppBuildHost(WorkspacePlaceholder(model: r.app, project: p), size: size, test: self)
            h.pump(3)
            try h.pickFromMenu("capsuleMenu", "Structural", what: "\(name): the stage menu")
            h.pump(1.5)
            if h.frames.all["view-Lattice preview-on"] == nil { try h.tap("view-Lattice preview", "\(name): the lattice preview", settle: 1.5) }
            if h.frames.all["latticeSettingsPanel"] != nil { try h.tap("capsuleSetup", "\(name): the page's Save", settle: 1.5) }
            XCTAssertNil(h.frames.all["latticeSettingsPanel"], "\(name): premise: on Lattice Setup")
            _ = try h.onScreen("view-Lattice preview-on", "\(name): premise: the lattice preview is on")

            let end = Date().addingTimeInterval(120)
            while h.frames.all["new-engine-timing"] == nil, Date() < end { h.pump(0.5) }
            // the thin-wall pop-up opens by itself on this part a moment after the lay (Install 3, his 11-09 rule on the new
            // engine): Continue first
            h.pump(1.5)
            if h.frames.all["lattice-thin-walls-continue"] != nil {
                try h.tap("lattice-thin-walls-continue", "\(name): Continue with Structural", settle: 1)
            }
            let lines = try h.onScreen("new-engine-lines", "★ \(name): by default — the new engine's lines")
            _ = try h.onScreen("new-engine-timing", "★ \(name): core's numbers came back (laid, bars handed over)")
            print("NEW-ENGINE \(name) \(Int(size.width))×\(Int(size.height)): lines at \(lines)")

            settings.newEngineTest = false   // RED CONTROL: the tests-only hook, the old preview
            h.pump(1)
            XCTAssertNil(h.frames.all["new-engine-lines"], "RED CONTROL \(name): the old preview has no new-engine lines")
            XCTAssertNil(h.frames.all["new-engine-timing"], "RED CONTROL \(name)")
        }
    }
}

/// ★ Install 3 (R2b): on Lattice Setup the new engine is the only lattice — the old engine's bake never starts there, and the
/// colour key is up with the new engine's bars (its scale from them). RED CONTROL `controlOldBakeUnderNewEngine`: the old
/// bake runs underneath, as before Install 3.
final class LatticeOldBakeRetiredHostedTests: XCTestCase {

    @MainActor
    func testNoOldBakeUnderTheNewEngineAndTheKeyIsUp() throws {
        for control in [false, true] {
            LatticeLayoutPreview.controlOldBakeUnderNewEngine = control
            defer { LatticeLayoutPreview.controlOldBakeUnderNewEngine = false }
            let r = try FlexiblePressFixtures.a1Project(3, self, facePrism: false)
            let p = r.project
            p.lattice.flexible = nil
            p.lattice.clearLatticeType()
            p.lattice.chooseLatticeType(.structural)
            p.lattice.enabled = true
            let h = AppBuildHost(WorkspacePlaceholder(model: r.app, project: p), size: AppBuildHost.sweep[0], test: self)
            h.pump(3)
            let before = LatticeLayoutPreview.oldEngineBakes
            try h.pickFromMenu("capsuleMenu", "Structural", what: "the stage menu")
            h.pump(1.5)
            if h.frames.all["view-Lattice preview-on"] == nil { try h.tap("view-Lattice preview", "the lattice preview", settle: 1.5) }
            if h.frames.all["latticeSettingsPanel"] != nil { try h.tap("capsuleSetup", "the page's Save", settle: 1.5) }
            let end = Date().addingTimeInterval(120)
            while h.frames.all["new-engine-timing"] == nil, Date() < end { h.pump(0.5) }
            h.pump(2)
            _ = try h.onScreen("new-engine-lines", "premise: the new engine laid the lattice")
            let bakes = LatticeLayoutPreview.oldEngineBakes - before
            print("OLD-BAKE control \(control): \(bakes) old bakes; key \(h.frames.all["latticeDensityLegend"].map { "\($0)" } ?? "none")")
            if control {
                XCTAssertGreaterThan(bakes, 0, "RED CONTROL: before Install 3 the old engine baked underneath")
            } else {
                XCTAssertEqual(bakes, 0, "★ no old bake where the new engine draws")
                _ = try h.onScreen("latticeDensityLegend", "★ the colour key is up, on the new engine's bars")
            }
        }
    }
}
#endif
