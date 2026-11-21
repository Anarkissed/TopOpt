// CutRulingsHostedTests — B8, the reviewer's rulings of 11-08 21:32Z on the Cut look (item 1; asked 11-07 20:04Z), on the page
// (his pad, a mesh, for Paint's brush; his l bracket, a STEP, for Paint's why):
//   • Paint is the rail's 7th tool (mockup #cut .rail, "Paint (STL only)"), before Pencil only's divider; one tool at a time.
//   • Paint's controls (Erase, the brush's size) dock in a bar at the top of the free model area — where every print-plan bar docks
//     (design-system "One place for the bar") — clear of the panel, the view corner and the rail.
//   • On a STEP, Paint stays in the rail; a tap says why in the rail's line (mockup: "Not for STEP: its CAD faces are already
//     exact") and brushes nothing (no bar).
//   • None of the old card's buttons in Cut: Keep clear stays on Topology, kg│lb is in Settings. The Regions sheet stays reachable
//     until its filter has a rail twin (CutRegionsTwinTests: it has none for "Small faces").
#if canImport(AppKit) && canImport(MetalKit)
import XCTest
import SwiftUI
import AppKit
import simd
@testable import TopOptFlows
@testable import TopOptKit

@MainActor
final class CutPaintRailHostedTests: XCTestCase {

    /// A control that publishes `<key>` off and `<key>-on` on.
    private func either(_ h: AppBuildHost, _ key: String) -> String { h.frames.all[key + "-on"] != nil ? key + "-on" : key }

    /// His 'l bracket 3' (S0's 92A8016E, frozen: a STEP), through the app's own import, on the page at Topology, in Edit faces.
    private func stepCut(_ size: CGSize) throws -> (AppBuildHost, ProjectModel) {
        let dir = FlexiblePressFixtures.frozenDir.appendingPathComponent("his7/92A8016E-FCCD-421D-B19E-4A1EC81C98A5", isDirectory: true)
        try FlexiblePressFixtures.assertFrozen(dir)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cut-paint-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let core = FlexibleHisProject.repoRoot.appendingPathComponent("core")
        let app = AppModel(materialsPath: core.appendingPathComponent("src/materials/materials.json").path,
                           rulesPath: core.appendingPathComponent("src/settings/rules.json").path, store: ProjectStore(rootDir: root))
        app.loadMaterials()
        app.newTopOpt()
        guard app.importFile(atPath: dir.appendingPathComponent("model.step").path, displayName: "l bracket 3.step") else {
            throw XCTSkip("the STEP importer refused the l bracket: \(app.toast ?? "")")
        }
        app.continueToWorkspace()
        let p = try XCTUnwrap(app.project, "the bracket opens")
        p.force.setGravity(direction: SIMD3(0, 0, -1))
        let h = AppBuildHost(ParityRoot(model: app), size: size, test: self)
        h.pump(3)
        try h.tap("capsuleScissors", "\(size): Topology's ✂")
        h.pump(1)
        return (h, p)
    }

    /// ★ Paint, the rail's 7th tool; its bar at the top of the free model area; another tool puts it down. On his pad (an STL:
    /// Paint brushes on it).
    func testPaintIsTheRailsSeventhToolAndItsControlsDockAtTheTop() throws {
        for (name, size) in CutLookHostedTests.sizes {
            let (h, p) = try ParityCutShots.cut(size, test: self)
            XCTAssertFalse(EditFacesPaint.isStep(p.importedFile?.path), "premise: his pad is a mesh (model.stl)")
            let rail = try h.onScreen("cutRail", "\(name): the rail")
            let paint = try h.onScreen("cutTool-Paint", "\(name): ★ Paint, the rail's 7th tool")
            XCTAssertEqual(paint.width, 40, accuracy: 0.5, "\(name): a 40 pt round tool")
            XCTAssertTrue(rail.insetBy(dx: -0.5, dy: -0.5).contains(paint), "\(name): Paint is inside the rail")
            for t in SurfaceTool.allCases {
                let f = try h.onScreen(either(h, "cutTool-\(t.title)"), "\(name): the rail's \(t.title)")
                XCTAssertGreaterThan(paint.minY, f.minY, "\(name): ★ Paint comes after \(t.title)")
            }
            let pencil = try h.onScreen(either(h, "cutTool-PencilOnly"), "\(name): Pencil only")
            XCTAssertLessThan(paint.maxY, pencil.minY, "\(name): Pencil only stays under the divider, after Paint")
            XCTAssertNil(h.frames.all["cutPaintBar"], "\(name): no Paint bar before Paint is picked")

            try h.tap("cutTool-Paint", "\(name): the rail's Paint")
            _ = try h.onScreen("cutTool-Paint-on", "\(name): ★ the picked Paint wears the accent")
            for t in SurfaceTool.allCases {
                XCTAssertNil(h.frames.all["cutTool-\(t.title)-on"], "\(name): ★ one tool at a time: \(t.title) is off")
            }
            XCTAssertNil(h.frames.all["cutPaintWhy"], "\(name): an STL paints: no why")

            // ★ the bar: at the top of the free model area, clear of the panel, the view corner and the rail
            let bar = try h.onScreen("cutPaintBar", "\(name): ★ Paint's controls, in the docked bar")
            let panel = try h.onScreen("cutSelections", "\(name): the view-only Selections")
            XCTAssertGreaterThanOrEqual(bar.minX, panel.maxX, "\(name): ★ the bar is clear of the panel")
            XCTAssertEqual(bar.minY, PageChrome.panelTop, accuracy: 1, "\(name): ★ at the top of the free model area (the panels' top line)")
            XCTAssertLessThanOrEqual(bar.maxX, size.width - PageChrome.gizmoClearance + 0.5, "\(name): ★ clear of the view corner's column")
            XCTAssertFalse(bar.intersects(rail), "\(name): the bar is clear of the rail")
            if let line = h.frames.all["cutRailHint"] { XCTAssertFalse(bar.intersects(line), "\(name): … and of the rail's line") }
            for v in ["Outlines", "X-ray"] {
                if let f = h.frames.all[either(h, "view-\(v)")] { XCTAssertFalse(bar.intersects(f), "\(name): ★ clear of \(v)") }
            }
            let erase = try h.probe("cutPaintErase", "\(name): ★ Erase, in the bar")
            XCTAssertTrue(bar.insetBy(dx: -0.5, dy: -0.5).contains(erase), "\(name): Erase is in the bar")
            let brushField = try h.onScreen("numberField-cutPaintBrush", "\(name): ★ the brush's size, in the bar")
            XCTAssertTrue(bar.insetBy(dx: -0.5, dy: -0.5).contains(brushField), "\(name): the size is in the bar")
            for k in ["cutPaintBrushMinus", "cutPaintBrushPlus"] { _ = try h.probe(k, "\(name): \(k)") }
            try h.tap("cutPaintErase", "\(name): Erase")
            _ = try h.onScreen("cutPaintErase-on", "\(name): ★ Erase is on")

            // ★ another tool puts Paint down, and its bar goes with it
            try h.tap(either(h, "cutTool-Cut"), "\(name): the rail's Cut")
            XCTAssertNotNil(h.frames.all["cutTool-Cut-on"], "\(name): Cut is the tool")
            XCTAssertNil(h.frames.all["cutTool-Paint-on"], "\(name): ★ Paint is off")
            XCTAssertNil(h.frames.all["cutPaintBar"], "\(name): ★ … and its bar is gone")
        }
    }

    /// ★ On a STEP (his l bracket): Paint stays in the rail; a tap says why in the rail's line and brushes nothing; a second tap
    /// puts it down.
    func testOnAStepPaintSaysWhyAndBrushesNothing() throws {
        let (h, p) = try stepCut(AppBuildHost.landscape13)
        XCTAssertTrue(EditFacesPaint.isStep(p.importedFile?.path), "premise: his l bracket is a STEP")
        let rail = try h.onScreen("cutRail", "the rail")
        let paint = try h.onScreen("cutTool-Paint", "★ Paint is in the rail on a STEP too")
        XCTAssertTrue(rail.insetBy(dx: -0.5, dy: -0.5).contains(paint), "inside the rail")
        try h.tap("cutTool-Paint", "the rail's Paint")
        _ = try h.onScreen("cutTool-Paint-on", "★ picked")
        let why = try h.onScreen("cutPaintWhy", "★ the rail's line says why")
        XCTAssertLessThanOrEqual(why.maxX, rail.minX - 8, "the why is the rail's line, beside it")
        XCTAssertNil(h.frames.all["cutPaintBar"], "★ no brush controls: Paint brushes nothing on a STEP")
        try h.tap("cutTool-Paint-on", "Paint again")
        XCTAssertNil(h.frames.all["cutTool-Paint-on"], "★ a second tap puts it down")
        XCTAssertNil(h.frames.all["cutPaintWhy"], "… and the why goes")
    }
}

@MainActor
final class CutFootHostedTests: XCTestCase {

    /// ★ The old card's buttons are not in Cut (Keep clear stays on Topology; kg│lb is in Settings); Regions stays reachable —
    /// its filter has no rail twin yet (CutRegionsTwinTests) — and opens its sheet.
    func testCutsFootKeepsOnlyTheRegionsSheet() throws {
        for (name, size) in CutLookHostedTests.sizes {
            let (h, p) = try ParityCutShots.cut(size, test: self)
            // a group active, as the old card's Keep clear needed one
            let c = try XCTUnwrap(p.selection.groups.first { $0.name == "Group C" }, "the pad's Group C")
            p.selection.setActive(c.id)
            h.pump(0.5)
            XCTAssertNil(h.frames.all["unitToggle"], "\(name): ★ kg│lb is not in Cut (units are in Settings)")
            XCTAssertNil(h.frames.all["keepClearQuick"], "\(name): ★ Keep clear is not in Cut (it stays on Topology)")
            let panel = try h.onScreen("cutSelections", "\(name): the view-only Selections")
            // ★ U10 on entry (11-09): the active scenario's folder opens with the panel, and the panel holds what it opened — a row
            // is above the foot or announced by "n more" (the folder used to open on appear, after the panel had measured its
            // closed rows: three rows hid with no cue, and the one under the foot took Regions' taps)
            let foot = try h.onScreen("cutSelectionsFooter", "\(name): the panel's foot")
            let cue = h.frames.all.keys.contains { $0.hasPrefix("cutSelectionsMore-") }
            let rows = h.frames.all.filter { $0.key.hasPrefix("cutGroup-") || $0.key.hasPrefix("cutFolder-") }
            XCTAssertGreaterThan(rows.count, 3, "\(name): premise: the active scenario's folder is open (its groups are rows)")
            for (k, f) in rows where f.maxY > foot.minY + 0.5 {
                XCTAssertTrue(cue, "\(name): ★ \(k.prefix(18)) hides under the foot (\(f.minY)–\(f.maxY), foot at \(foot.minY)) with no cue")
            }
            let regions = try h.probe("cutRegions", "\(name): ★ Regions stays reachable (its filter has no rail twin)")
            XCTAssertTrue(panel.insetBy(dx: -0.5, dy: -0.5).contains(regions), "\(name): in the panel's foot")
            try h.tap("cutRegions", "\(name): Regions")
            _ = try h.onScreen("cutRegions-on", "\(name): ★ Regions is on")
            _ = try h.onScreen("regionsSheet", "\(name): ★ the Regions sheet opens")
            try h.tap("cutRegions-on", "\(name): Regions again")
            XCTAssertNil(h.frames.all["regionsSheet"], "\(name): … and shuts")
        }
    }
}
#endif
