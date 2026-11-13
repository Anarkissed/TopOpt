// LatticeLayoutSwitchHostedTests — "New engine (test)" on the REAL Lattice Setup page, at the sweep's six windows (the
// reviewer's go of 2026-11-12 20:21Z, item 4: "the switch, checked at 6 windows"). One Structural part, the lattice preview
// armed the way he arms it (the cube's tap; the page's Save when the settings open first), then:
//   * OFF (the default): the page is today's — no new-engine lines anywhere;
//   * ON: the lines come, wholly inside the window, and core's numbers come back (the timing line: the layout was laid and its
//     bars handed to the 3D view);
//   * OFF again: they go.
// The off arms are the red control for the on arm's frames (the same probe finds nothing when the switch is off).
#if canImport(AppKit) && canImport(MetalKit)
import XCTest
import SwiftUI
@testable import TopOptFlows
@testable import TopOptKit

final class LatticeLayoutSwitchHostedTests: XCTestCase {

    @MainActor
    func testTheSwitchOnLatticeSetupAtTheSixWindows() throws {
        let settings = AppSettings.shared
        let was = settings.newEngineTest
        addTeardownBlock { @MainActor in AppSettings.shared.newEngineTest = was }
        let names = ["13L", "13P", "11L", "11P", "MSL", "MSP"]
        for (name, size) in zip(names, AppBuildHost.sweep) {
            settings.newEngineTest = false
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

            XCTAssertNil(h.frames.all["new-engine-lines"], "★ \(name): OFF (the default) — today's page, no new-engine lines")

            settings.newEngineTest = true
            let end = Date().addingTimeInterval(120)
            while h.frames.all["new-engine-timing"] == nil, Date() < end { h.pump(0.5) }
            let lines = try h.onScreen("new-engine-lines", "★ \(name): ON — the new engine's lines")
            _ = try h.onScreen("new-engine-timing", "★ \(name): ON — core's numbers came back (laid, bars handed over)")
            print("NEW-ENGINE \(name) \(Int(size.width))×\(Int(size.height)): lines at \(lines)")

            settings.newEngineTest = false
            h.pump(1)
            XCTAssertNil(h.frames.all["new-engine-lines"], "★ \(name): OFF again — gone")
            XCTAssertNil(h.frames.all["new-engine-timing"], "★ \(name): OFF again — gone")
        }
    }
}
#endif
