// AddScenarioVisibleHostedTests — B3 (plan.md §B3: "'+ Add a load scenario' is visible and hittable in all 3 sizes with 3
// folders open (the bug that started your rule)"; design-system U10: pinned footers never scroll away).
//
// Three scenarios, every folder open: the list scrolls, and the pinned footer — + Add a load scenario, then Safety margin —
// stays on the screen, a 44 pt target, inside the Selections panel, and its tap adds a scenario. RED before B3 (saved:
// scratchpad b2red/AddScenarioVisible.txt): its hit area was the caption's height.
#if canImport(AppKit) && canImport(MetalKit)
import XCTest
import SwiftUI
import AppKit
@testable import TopOptFlows
@testable import TopOptKit

@MainActor
final class AddScenarioVisibleHostedTests: XCTestCase {
    func testAddALoadScenarioIsOnScreenAndHittableWithThreeFoldersOpen() throws {
        for size in AppBuildHost.sweep {   // ★ B10: the six windows
            let x = try ScenarioSelectHostedTests.threeScenarios(self)
            let p = x.r.project
            let h = AppBuildHost(WorkspacePlaceholder(model: x.r.app, project: p), size: size, test: self)
            h.pump(3)
            let what = "\(size)"
            for i in [1, 2] where h.frames.all["scenarioFolderOpen-\(i)"] != nil {
                h.scrollIntoList("scenarioFolderOpen-\(i)")
                try h.tap("scenarioFolderOpen-\(i)", "\(what): folder \(i)'s ▶")
            }
            XCTAssertNotNil(h.frames.all["selLine-\(x.s[2].uuidString)-\(x.loads[1].uuidString)"], "\(what): premise: all three are open")
            let add = try h.probe("addLoadScenario", "\(what): ★ + Add a load scenario", minHit: 44)
            let list = try h.onScreen("selectionsList", "\(what): the Selections panel")
            XCTAssertTrue(list.insetBy(dx: -0.5, dy: -0.5).contains(add), "\(what): ★ inside the panel, pinned")
            if let cue = h.frames.all.first(where: { $0.key.hasPrefix("selectionsMore") })?.value {
                XCTAssertFalse(cue.intersects(add), "\(what): the 'n more' cue never covers it")
            }
            let n = p.force.scenarioList.count
            h.click(CGPoint(x: add.midX, y: add.midY))
            XCTAssertEqual(p.force.scenarioList.count, n + 1, "\(what): ★ its tap adds a scenario")
        }
    }
}
#endif
