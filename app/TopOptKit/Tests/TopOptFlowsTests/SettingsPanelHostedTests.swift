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

    /// ★ LOOK PER SCREEN (11-04, Topology slice T3; mockup #corner-settings, U9): Runs on is a value box (the device's glyph and
    /// name), Units is [kg │ lb] and Protect skin is the ONE number box ("5 mm") — each on its own one-line row, its value at
    /// the row's right end. RED before T3 (scratchpad b2red/SettingsPanel-T3.txt): Runs on is a capsule, Units says "lbs", Protect
    /// skin is a chip that steps 3 → 5 → 8 → 12.
    func testRunsOnUnitsAndProtectSkinAreTheRowsValueBoxes() throws {
        let r = try FlexiblePressFixtures.a1Project(3, self, facePrism: false)
        let p = r.project
        p.lattice.flexible = nil
        if let c = p.selection.groups.first(where: { $0.name == "Group C" }) { p.force.setProtected(c.id, true) }
        p.force.unit = .kg
        let h = AppBuildHost(WorkspacePlaceholder(model: r.app, project: p), size: AppBuildHost.landscape13, test: self)
        h.pump(3)
        try h.tap("setupChip", "the corner's Settings chip")
        XCTAssertEqual(WeightUnit.lbs.label, "lb", "★ U9: kg │ lb")
        for (row, key) in [(TopologySetupRow.compute, "settingsRunsOn"), (.units, "settingsUnits"),
                           (.protectSkin, "numberField-settings-protectSkin")] {
            let line = try h.onScreen("settingsRow-\(row.rawValue)", "the \(row.title) row")
            let value = try h.probe(key, "★ \(row.title)'s value box", minHit: 32)
            XCTAssertLessThanOrEqual(line.height, 44.5, "★ \(row.title): one line")
            XCTAssertEqual(value.midY, line.midY, accuracy: 2, "\(row.title): its value sits on its line")
            XCTAssertEqual(value.maxX, line.maxX, accuracy: 6, "\(row.title): its value at the row's right end")
        }
        XCTAssertNil(h.frames.all["protectInfo"], "★ the old Protect chip and its own (i) are gone (the row's (i) says it)")
        XCTAssertNotNil(h.frames.all["info-settings-protectSkin"], "★ Protect skin's (i), on its row")
        // Units: [kg │ lb │ N] (★ B5, Q12 Units (a): N added, display only)
        let units = try h.onScreen("settingsUnits", "Units")
        h.click(CGPoint(x: units.midX, y: units.midY))
        XCTAssertEqual(p.force.unit, .lbs, "★ lb, the middle")
        h.click(CGPoint(x: units.maxX - units.width / 6, y: units.midY))
        XCTAssertEqual(p.force.unit, .N, "★ N, the right")
        h.click(CGPoint(x: units.minX + units.width / 6, y: units.midY))
        XCTAssertEqual(p.force.unit, .kg, "★ kg")
        // Protect skin: a drag up steps it (the number box's rule), one depth for every protected face
        let box = try h.onScreen("numberField-settings-protectSkin", "Protect skin's number")
        let before = p.force.faceProtectDepthMM
        NumberFieldHostedTests().drag(h, box, dy: -60)   // its real vertical drag
        XCTAssertGreaterThan(p.force.faceProtectDepthMM, before, "★ a drag up deepens Protect skin")
        XCTAssertLessThanOrEqual(p.force.faceProtectDepthMM, FaceProtection.maxDepthMM)
    }

    /// ★ LOOK PER SCREEN (T3; design-system §4.19 "A Panel (4.3)", U2, U10): the Settings panel is §4.3's panel — its header is
    /// the chevron and "Settings" (a tap closes it), and a row below its fold is announced by "N more ⌄", never cut off
    /// silently. RED before T3 (b2red/SettingsPanel-T3.txt): its own scroll box; Material cut off at 13″ landscape with no cue.
    func testItIsThePanelAndARowBelowTheFoldIsAnnounced() throws {
        for size in [AppBuildHost.landscape13, CGSize(width: 820, height: 1180)] {
            let r = try FlexiblePressFixtures.a1Project(3, self, facePrism: false)
            let p = r.project
            p.lattice.flexible = nil
            if let c = p.selection.groups.first(where: { $0.name == "Group C" }) { p.force.setProtected(c.id, true) }
            let h = AppBuildHost(WorkspacePlaceholder(model: r.app, project: p), size: size, test: self)
            h.pump(3)
            try h.tap("setupChip", "\(size): the corner's Settings chip")
            let panel = try h.onScreen("settingsPanel", "\(size): ★ the Settings panel is a DSPanel")
            XCTAssertEqual(panel.width, DSParts.panelWidth, accuracy: 0.5, "\(size): 348 pt (U2)")
            let header = try h.onScreen("settingsPanelHeader", "\(size): its header")
            XCTAssertEqual(header.height, DSParts.headerHeight, accuracy: 0.5)
            let material = try h.onScreen("settingsRow-material", "\(size): the Material row (laid out)")
            let more = h.frames.all.first { $0.key.hasPrefix("settingsPanelMore-") }?.value
            if material.maxY > panel.maxY - 1 || (more.map { material.maxY > $0.minY + 1 } ?? false) {
                XCTAssertNotNil(more, "\(size): ★ U10 — Material is below the fold and the panel says \"N more ⌄\"")
            }
            h.click(CGPoint(x: header.midX, y: header.midY))
            XCTAssertNil(h.frames.all["settingsPanel"], "\(size): ★ the header's tap closes Settings")
        }
    }
}
#endif
