// SettingRowHostedTests — B2, round 1 (R2.2; design-system §4.21 "Safety margin  Light use · 150 % ⌄", §4.14 the (i), U8).
//
// On Topology Setup, at three sizes, with real clicks: Safety margin is a setting row — a 44 pt row, its value in the
// design's words with ⌄, its menu offering Light use · Everyday part · Repeated loads, or hard to replace · Custom…, and an
// (i) with a 44 pt target whose tap opens its popover (1–3 sentences). RED: before B2 the value read "Light use: 150% of your
// load", the (i) was a bare info glyph with no target of its own, and its words opened as a line in the panel.
#if canImport(AppKit) && canImport(MetalKit)
import XCTest
import SwiftUI
import AppKit
@testable import TopOptFlows
@testable import TopOptKit

@MainActor
final class SettingRowHostedTests: XCTestCase {

    func testSafetyMarginIsASettingRowWithItsInfo() throws {
        for size in [AppBuildHost.landscape13, AppBuildHost.portrait13, AppBuildHost.landscape11] {
            let r = try FlexiblePressFixtures.a1Project(3, self, facePrism: false)
            let p = r.project
            p.lattice.flexible = nil
            let h = AppBuildHost(WorkspacePlaceholder(model: r.app, project: p), size: size, test: self)
            h.pump(3)
            let info = try h.probe("info-safetyMargin", "\(size): ★ Safety margin's (i), a 44 pt target", minHit: 44)
            let value = try h.onScreen("safetyMargin", "\(size): its value")
            XCTAssertEqual(info.midY, value.midY, accuracy: 2, "\(size): the (i) on the row's line")
            let offered = try h.pickFromMenu("safetyMargin", "Everyday", what: "\(size): Safety margin")
            XCTAssertEqual(offered, ["Light use · 150 %", "Everyday part · 200 %", "Repeated loads, or hard to replace · 300 %", "Custom…"],
                           "\(size): ★ the design's words")
            XCTAssertEqual(p.force.safetyMarginValue, 2.0, accuracy: 1e-9, "\(size): the pick lands")
            try h.tap("info-safetyMargin", "\(size): the (i)")
            let pop = NSApp.windows.first { $0 !== h.window && $0.isVisible && $0.className.contains("Popover") }
            XCTAssertNotNil(pop, "\(size): ★ the (i) opens its popover")
            pop?.orderOut(nil)
        }
    }
}
#endif
