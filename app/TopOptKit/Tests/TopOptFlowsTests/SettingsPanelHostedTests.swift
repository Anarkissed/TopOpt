// SettingsPanelHostedTests — B3 (approved design 2026-11-02, plan.md §B3, app-map §3.9, mockup #corner-settings).
//
// The Settings panel opens from the corner chip, one line per setting: Quality · Plate · Gravity · Runs on · Units · Plastic ·
// Protect skin · Allow growth here · Print parameters · Material. plan.md's test: every row is inside the panel, and the panel
// never covers the top-left block — at every iPad size. Material is new here (it was set only at import): its menu changes
// the project's material. RED before B3 (saved: scratchpad b2red/SettingsPanel.txt): no Material row.
#if canImport(AppKit) && canImport(MetalKit)
import XCTest
import SwiftUI
import AppKit
@testable import TopOptFlows
@testable import TopOptKit

@MainActor
final class SettingsPanelHostedTests: XCTestCase {

    func testEveryRowIsInsideThePanelAndThePanelNeverCoversTheTopLeftBlock() throws {
        for size in AppBuildHost.probeSizes {
            let r = try FlexiblePressFixtures.a1Project(3, self, facePrism: false)
            let p = r.project
            p.lattice.flexible = nil
            if let c = p.selection.groups.first(where: { $0.name == "Group C" }) { p.force.makeAnchor(c.id) }
            let h = AppBuildHost(WorkspacePlaceholder(model: r.app, project: p), size: size, test: self)
            h.pump(3)
            let what = "\(size)"
            try h.tap("setupChip", "\(what): the corner's Settings chip")
            let panel = try h.onScreen("cornerPanel", "\(what): the Settings panel")
            let rows = TopologySetupRow.visible(protectCount: p.force.explicitProtectCount(in: p.selection.groups),
                                                isStep: false, designBoxDrawn: true)
            XCTAssertEqual(rows.last, .material, "\(what): ★ Material is the last row (app-map §3.9)")
            var seen = 0
            for row in rows {
                guard let f = h.frames.all["settingsRow-\(row.rawValue)"] else { continue }
                seen += 1
                XCTAssertTrue(panel.insetBy(dx: -0.5, dy: -0.5).contains(f) || f.minY >= panel.maxY - 1,
                              "\(what): ★ \(row.title) sits inside the panel (or below its fold, scrolled to): \(f) in \(panel)")
                XCTAssertGreaterThanOrEqual(f.minX, panel.minX - 0.5, "\(what): \(row.title) is not cut at the side")
                XCTAssertLessThanOrEqual(f.maxX, panel.maxX + 0.5, "\(what): \(row.title) is not cut at the side")
            }
            XCTAssertGreaterThanOrEqual(seen, 6, "\(what): the panel draws its rows")
            for k in ["backButton", "topLeftName", "topLeftUndo", "topLeftRedo", "capsule"] {
                guard let b = h.frames.all[k] else { continue }
                XCTAssertFalse(panel.intersects(b.insetBy(dx: 0.5, dy: 0.5)), "\(what): ★ the panel never covers the top-left block (\(k))")
            }
            XCTAssertLessThanOrEqual(panel.maxY, size.height + 0.5, "\(what): the panel is wholly on the screen")
            XCTAssertGreaterThanOrEqual(panel.minY, -0.5)
        }
    }

    func testMaterialIsOneLineAndItsMenuChangesTheMaterial() throws {
        let r = try FlexiblePressFixtures.a1Project(3, self, facePrism: false)
        let p = r.project
        p.lattice.flexible = nil
        r.app.loadMaterials()
        let h = AppBuildHost(WorkspacePlaceholder(model: r.app, project: p), size: AppBuildHost.landscape13, test: self)
        h.pump(3)
        try h.tap("setupChip", "the corner's Settings chip")
        let options = (p.process == .resin ? r.app.resinMaterials : r.app.fdmMaterials).map(\.name)
        guard let other = options.first(where: { $0 != p.material }) else { throw XCTSkip("one material only in this catalogue") }
        let row = try h.onScreen("settingsRow-material", "the Material row")
        let menu = try h.probe("settingsMaterial", "★ Material's value, a 44 pt target", minHit: 44)
        XCTAssertLessThanOrEqual(row.height, 44.5, "★ one line")
        XCTAssertEqual(menu.midY, row.midY, accuracy: 2)
        let offered = try h.pickFromMenu("settingsMaterial", other, what: "Material")
        XCTAssertEqual(Set(offered.map { $0.replacingOccurrences(of: " [off]", with: "") }), Set(options), "★ its process's materials")
        XCTAssertEqual(p.material, other, "★ the pick is the project's material")
    }
}
#endif
