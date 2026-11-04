// ParitySquishShots — the reviewer's rule A (11-04 02:56Z) for the Squish page: the app's chrome offscreen next to mockup v5's
// #flex-squish (scratchpad parity/mockshot.py renders that headless). Opt-in: APP_BUILD_SHOT_DIR=<dir>; skipped otherwise. His A1
// pad lookalike, the first squeeze group's tab open on its first face — the mockup's state. The 3D view draws nothing offscreen.
#if canImport(AppKit)
import XCTest
import SwiftUI
import AppKit
@testable import TopOptFlows
@testable import TopOptKit

@MainActor
final class ParitySquishShots: XCTestCase {
    static let sizes: [(String, CGSize)] = [("13L", CGSize(width: 1376, height: 1032)), ("11P", CGSize(width: 820, height: 1180))]

    func testSquishStates() throws {
        guard ProcessInfo.processInfo.environment["APP_BUILD_SHOT_DIR"] != nil else { throw XCTSkip("APP_BUILD_SHOT_DIR not set") }
        let (r, m) = try SquishHost.pad(self, edges: false)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("squish-shots-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let app = AppModel(materialsPath: "/no/such/materials.json", store: ProjectStore(rootDir: dir))
        let g = try XCTUnwrap(m.squeezeGroups.first, "a squeeze group")
        for (name, size) in Self.sizes {
            m.rail = .group(g.id)
            m.selectedRegion = g.regions.first
            let h = SquishHost(FlexibleStagePage(project: r.project, model: m, appModel: app, onBack: {}, onExit: {}),
                               size: size, test: self)
            // each shot once core's design has landed: the face's "Reaches … short" line, the dent tag and the top line read it
            // (11-04: a fixed 2.5 s shot 13L mid-design on a loaded Mac, the panel a line shorter and scrolled)
            SquishHost.pump(2.5)
            XCTAssertTrue(SquishHost.pumpUntil(30) { !m.designsInFlight }, "\(name): core's design landed")
            SquishHost.pump(0.5)
            try h.picture("app_flex-squish_\(name).png")
            m.rail = .model
            SquishHost.pump(1)
            XCTAssertTrue(SquishHost.pumpUntil(30) { !m.designsInFlight }, "\(name) model: core's design landed")
            SquishHost.pump(0.5)
            try h.picture("app_flex-squish-model_\(name).png")
        }
    }

    /// The main Flexible page (the mockup's #flex-lattice): his pad, the whole app page, on the Flexible stage — Setup.
    func testMainPageStates() throws {
        guard ProcessInfo.processInfo.environment["APP_BUILD_SHOT_DIR"] != nil else { throw XCTSkip("APP_BUILD_SHOT_DIR not set") }
        for (name, size) in Self.sizes {
            let r = try FlexiblePressFixtures.a1Project(3, self)
            let h = SquishHost(WorkspacePlaceholder(model: r.app, project: r.project), size: size, test: self)
            SquishHost.pump(3)
            try FlexiblePressFixtures.enterLatticeStage(r.project, click: { h.click($0) })
            SquishHost.pump(3)
            if let s = FlexibleMainStage.lastMade { addTeardownBlock { @MainActor in await s.model?.waitForIdle() } }
            try h.picture("app_flex-lattice_\(name).png")
        }
    }
}
#endif
