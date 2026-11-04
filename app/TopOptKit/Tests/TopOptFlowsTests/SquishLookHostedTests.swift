// SquishLookHostedTests — B9 (#362), the Squish page in the one-app look (app-map §3.7, ledger R6, design-system U1 / U2 /
// U14 / §4.3; the mockup's #flex-squish). Written before the code; the red runs are saved with the batch.
//   * U1: the one top-left block where the Exit row was, at the place it has on every stage, and the stage row 8 pt under it
//     (RED: today's Exit row at 24, 24 and no back button);
//   * U14 / U2: the panel is the shared wide panel (440 pt) and hangs from under the stage row (RED: 480 pt, bottom-aligned);
//   * U2: its header is a fold: a real click folds the panel to the header line, a second opens it;
//   * R6's foot: Save and Cancel are drawn, 44 pt, not covered; Save with nothing changed leaves as Exit did (no rebuild);
//     Cancel after a change puts back what changed — the Squeeze written back to the Topology load included — and leaves
//     with nothing to rebuild (RED: `controlCancelKeeps`);
//   * Reset all, moved to the top of the open tab, still asks in place.
// Every size the plan proves (13" landscape and portrait, 11" landscape, "More Space"); real clicks through the window.
#if canImport(AppKit)
import XCTest
import SwiftUI
import AppKit
@testable import TopOptFlows
@testable import TopOptKit

@MainActor
final class SquishLookHostedTests: XCTestCase {
    static let sizes: [CGSize] = [CGSize(width: 1376, height: 1032), CGSize(width: 1032, height: 1376),
                                  CGSize(width: 1180, height: 820), CGSize(width: 1590, height: 1192)]

    /// An app model for the one top-left block (a scratch library; nothing of his).
    func appModel() throws -> AppModel {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("squish-look-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return AppModel(materialsPath: "/no/such/materials.json", store: ProjectStore(rootDir: dir))
    }

    final class Exits { var count = 0 }

    func page(_ r: FlexibleHisProject.Restored, _ m: FlexibleStageModel, app: AppModel, exits: Exits, size: CGSize) -> SquishHost {
        let h = SquishHost(FlexibleStagePage(project: r.project, model: m, appModel: app, onBack: {}, onExit: { exits.count += 1 }),
                           size: size, test: self)
        SquishHost.pump(2.5)
        return h
    }

    func testTheTopLeftBlockAndTheWidePanelHangingUnderTheStageRow() throws {
        let (r, m) = try SquishHost.pad(self, edges: false)
        let app = try appModel()
        var report: [String] = []
        for size in Self.sizes {
            let h = page(r, m, app: app, exits: Exits(), size: size)
            let tag = "\(Int(size.width))×\(Int(size.height))"
            // U1: the block's back button at the block's own place (TopLeftBlock.top / .leading), the stage row under it
            let back = try XCTUnwrap(h.frame("backButton"), "\(tag): ★ the top-left block's ‹ is drawn")
            XCTAssertEqual(back.minX, TopLeftBlock.leading, accuracy: 0.5, "\(tag): ‹ at the block's leading inset")
            XCTAssertEqual(back.minY, TopLeftBlock.top, accuracy: 1, "\(tag): ‹ at the block's top inset (±1 pt, U1; centred in its 44 pt row)")
            XCTAssertNotNil(h.frame("topLeftUndo"), "\(tag): undo in the block")
            XCTAssertNotNil(h.frame("topLeftRedo"), "\(tag): redo in the block")
            let capsule = try XCTUnwrap(h.frame("capsule"), "\(tag): the stage row")
            XCTAssertEqual(capsule.minY, FlexibleChromeLayout.capsuleTop, accuracy: 0.5, "\(tag): the stage row under the block")
            XCTAssertGreaterThanOrEqual(capsule.minY, back.maxY + 7.5, "\(tag): the stage row 8 pt under the block")
            // U14 / U2: the wide panel, hanging from under the stage row
            let panel = try XCTUnwrap(h.frame("panel"), "\(tag): the Squish panel")
            XCTAssertEqual(panel.width, PageChrome.widePanelWidth, accuracy: 0.5, "\(tag): ★ the panel is the 440 pt wide panel")
            XCTAssertEqual(panel.minX, PageChrome.edge, accuracy: 0.5, "\(tag): panels on the left")
            XCTAssertGreaterThanOrEqual(panel.minY, PageChrome.panelTop - 0.5, "\(tag): ★ the panel starts under the stage row")
            XCTAssertLessThanOrEqual(panel.minY, PageChrome.panelTop + 80, "\(tag): ★ the panel hangs from the top, never the bottom")
            XCTAssertLessThanOrEqual(panel.maxY, size.height - PageChrome.edge + 0.5, "\(tag): the panel ends above the bottom edge")
            XCTAssertFalse(panel.intersects(capsule.insetBy(dx: 0.5, dy: 0.5)), "\(tag): the panel clears the stage row")
            // the top line beside the panel's column, never across it: the panel keeps its place under the stage row
            if let notice = h.frame("notice") {
                XCTAssertFalse(notice.intersects(panel.insetBy(dx: 0.5, dy: 0.5)), "\(tag): the top line clears the panel")
            }
            XCTAssertEqual(panel.minY, PageChrome.panelTop, accuracy: 0.5, "\(tag): ★ the panel starts right under the stage row")
            // the foot and Reset all: drawn, 44 pt, inside the window, under nothing
            let covers = ["capsule", "exitRow", "viewButtons", "legend", "popup"]
            let save = try h.probe("squishSave", "\(tag) Save", covers: covers)
            let cancel = try h.probe("squishCancel", "\(tag) Cancel", covers: covers)
            // Auto │ Manual and Reset all top the open tab's scroll (the mockup's): on the Model tab, nothing selected
            m.selectedRegion = nil; m.rail = .model; SquishHost.pump(0.8)
            try h.probe("resetAll", "\(tag) Reset all", covers: covers)
            try h.probe("panelHeader", "\(tag) the panel's header", covers: covers)
            XCTAssertTrue(panel.insetBy(dx: -0.5, dy: -0.5).contains(save) && panel.insetBy(dx: -0.5, dy: -0.5).contains(cancel),
                          "\(tag): Save and Cancel sit in the panel's foot")
            XCTAssertLessThan(cancel.maxX, save.minX, "\(tag): Cancel │ Save, Save last")
            report.append(String(format: "%@ panel %.0f×%.0f at (%.0f, %.0f) · ‹ (%.0f, %.0f) · stage row y %.0f · Save %.0f×%.0f",
                                 tag, panel.width, panel.height, panel.minX, panel.minY, back.minX, back.minY, capsule.minY,
                                 save.width, save.height))
        }
        print("SQUISH-LOOK layout:\n  " + report.joined(separator: "\n  "))
    }

    /// ★ RED CONTROL: the top line's own row across the panel's column (`controlNoticeAcrossPanel`) pushes the panel down at 11"
    /// landscape.
    func testTheTopLineAcrossThePanelPushesItDown() throws {
        let (r, m) = try SquishHost.pad(self, edges: false)
        FlexibleStagePage.controlNoticeAcrossPanel = true
        defer { FlexibleStagePage.controlNoticeAcrossPanel = false }
        let h = page(r, m, app: try appModel(), exits: Exits(), size: Self.sizes[2])
        let panel = try XCTUnwrap(h.frame("panel"))
        XCTAssertGreaterThan(panel.minY, PageChrome.panelTop + 20, "control: the panel starts under the top line's row (\(panel.minY))")
    }

    func testTheHeaderFoldsThePanel() throws {
        let (r, m) = try SquishHost.pad(self, edges: false)
        let h = page(r, m, app: try appModel(), exits: Exits(), size: Self.sizes[2])
        let open = try XCTUnwrap(h.frame("panel"))
        try h.tap("panelHeader", "the panel's header")
        let folded = try XCTUnwrap(h.frame("panel"))
        XCTAssertLessThan(folded.height, 80, "★ a click on the header folds the panel to its header line (\(open.height) → \(folded.height))")
        XCTAssertNil(h.frame("squishSave"), "folded: no foot")
        try h.tap("panelHeader", "the folded header")
        let again = try XCTUnwrap(h.frame("panel"))
        XCTAssertEqual(again.height, open.height, accuracy: 1, "a second click opens it as it was")
    }

    func testSaveWithNothingChangedLeavesAsExitDid() throws {
        let (r, m) = try SquishHost.pad(self, edges: false)
        let exits = Exits()
        let h = page(r, m, app: try appModel(), exits: exits, size: Self.sizes[0])
        try h.tap("squishSave", "Save")
        XCTAssertEqual(exits.count, 1, "★ Save leaves the page")
        XCTAssertTrue(m.takeExitUnchanged(), "nothing changed: the main page is left as it was (no rebuild)")
    }

    /// One face's Squeeze changed on the page — it is written back to the Topology load it came from.
    func changedSqueeze(_ m: FlexibleStageModel) throws -> (face: Int, before: Double) {
        let face = try XCTUnwrap(m.squeezeGroups.first?.regions.first, "a pressed face")
        let before = try XCTUnwrap(m.settings.face(face)?.weightKg, "its weight")
        m.setWeight(face, kg: before + 3)
        SquishHost.pump(1.2)   // the project's undo debounce settles the step
        XCTAssertNotEqual(m.settings.face(face)?.weightKg, before, "the edit took")
        return (face, before)
    }

    func testCancelPutsBackWhatChangedAndLeaves() throws {
        let (r, m) = try SquishHost.pad(self, edges: false)
        let exits = Exits()
        let h = page(r, m, app: try appModel(), exits: exits, size: Self.sizes[0])
        let force = r.project.force
        let (face, before) = try changedSqueeze(m)
        XCTAssertNotEqual(r.project.force, force, "the Squeeze reached the Topology load")
        try h.tap("squishCancel", "Cancel")
        XCTAssertEqual(exits.count, 1, "★ Cancel leaves the page")
        XCTAssertEqual(try XCTUnwrap(m.settings.face(face)?.weightKg), before, accuracy: 1e-9, "★ the Squeeze is back as it opened")
        XCTAssertEqual(r.project.force, force, "★ …and the Topology load it was written back to")
        XCTAssertTrue(m.takeExitUnchanged(), "★ nothing to rebuild")
        XCTAssertTrue(r.project.canRedoNow, "Redo brings the change back")
    }

    /// ★ RED CONTROL: Cancel that keeps the change (`controlCancelKeeps`) — the Squeeze stays changed.
    func testCancelRedControlKeepsTheChange() throws {
        let (r, m) = try SquishHost.pad(self, edges: false)
        FlexibleStagePage.controlCancelKeeps = true
        defer { FlexibleStagePage.controlCancelKeeps = false }
        let h = page(r, m, app: try appModel(), exits: Exits(), size: Self.sizes[0])
        let (face, before) = try changedSqueeze(m)
        try h.tap("squishCancel", "Cancel")
        XCTAssertNotEqual(m.settings.face(face)?.weightKg, before, "control: the change stays")
    }

    func testResetAllStillAsksInPlace() throws {
        let (r, m) = try SquishHost.pad(self, edges: false)
        let h = page(r, m, app: try appModel(), exits: Exits(), size: Self.sizes[2])
        m.selectedRegion = nil; m.rail = .model; SquishHost.pump(0.8)   // the top of the open tab's scroll
        try h.probe("resetAll", "Reset all", covers: ["capsule", "exitRow"])
        try h.tap("resetAll", "Reset all")
        XCTAssertTrue(m.resetAsk, "★ Reset all asks in place")
        let keep = try h.probe("resetCancel", "Reset all's Cancel", covers: ["capsule", "exitRow"])
        let panel = try XCTUnwrap(h.frame("panel"))
        XCTAssertTrue(panel.insetBy(dx: -0.5, dy: -0.5).contains(keep), "U7: the ask stays inside its panel")
        try h.tap("resetCancel", "Reset all's Cancel")
        XCTAssertFalse(m.resetAsk, "Cancel keeps everything")
    }
}
#endif
