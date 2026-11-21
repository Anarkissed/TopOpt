// WidePanelFitsTests — B2, U14 (approved design 2026-11-02, design-system §4.19 and §6 U14; his round 2 note N5b: "Please
// enlarge the Lattice Settings modal to fit the 'Cell Size' options").
//
// The Lattice stage's Settings (the Lattice page) at four sizes: its panel is the wide panel, 440 pt, wholly inside the window
// and starting under the stage row; the Selections / Topology panels stay 348 (U2). RED before B2: 348.
#if canImport(AppKit) && canImport(MetalKit)
import XCTest
import SwiftUI
import AppKit
@testable import TopOptFlows
@testable import TopOptKit

@MainActor
final class WidePanelFitsTests: XCTestCase {
    func testTheLatticeSettingsPanelIsTheWidePanel() throws {
        XCTAssertEqual(PageChrome.widePanelWidth, 440)
        XCTAssertEqual(PageChrome.panelWidth, 348, "the Selections / Topology panels stay 348")
        for size in [AppBuildHost.landscape13, AppBuildHost.portrait13, AppBuildHost.landscape11, CGSize(width: 820, height: 1180)] {
            let r = try FlexiblePressFixtures.a1Project(3, self, facePrism: false)
            let p = r.project
            p.lattice.flexible = nil
            p.lattice.chooseLatticeType(.structural)
            let h = AppBuildHost(WorkspacePlaceholder(model: r.app, project: p), size: size, test: self)
            h.pump(3)
            try h.pickFromMenu("capsuleMenu", "Structural", what: "\(size): the stage menu")
            try h.tap("capsuleLattice", "\(size): the Lattice page", settle: 1.5)
            let panel = try h.onScreen("latticeSettingsPanel", "\(size): ★ the Lattice settings panel")
            XCTAssertEqual(panel.width, 440, accuracy: 0.5, "\(size): ★ U14 — the wide panel")
            XCTAssertGreaterThanOrEqual(panel.minX, PageChrome.edge - 0.5, "\(size): on the left edge")
        }
    }
}
#endif
