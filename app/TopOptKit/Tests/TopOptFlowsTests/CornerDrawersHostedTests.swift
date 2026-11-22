// CornerDrawersHostedTests — his iPad notes 2026-11-22 (afternoon, img 45), the corner's Settings drawer and the ⌃.
//
// His words: "When the 'Settings' drawer is open, a tap to the background or opening up the ^ menu should automatically hide
// the Settings drawer. The same rule for the ^ menu. The menu colours are different - they should be the same colour as the ^
// menu colour. The ^ menu should start *above* the buttons like the Settings menu so it is not covering any buttons."
//
// Measured as drawn on his two iPad sizes (13″ landscape, 11″ portrait), on the Lattice stage (img 45's), Topology and Results.
#if canImport(AppKit) && canImport(MetalKit)
import XCTest
import SwiftUI
import AppKit
@testable import TopOptFlows
@testable import TopOptKit
import TopOptDesign

@MainActor
final class CornerDrawersHostedTests: XCTestCase {
    static let sizes = [AppBuildHost.landscape13, CGSize(width: 820, height: 1180)]

    /// His A1 pad on the Lattice stage (Structural, his Top's prism latticed: the lattice is set), as LatticeCornerHostedTests.
    func latticeStage(_ size: CGSize) throws -> (AppBuildHost, ProjectModel, AppModel) {
        let r = try FlexiblePressFixtures.a1Project(3, self, facePrism: true)
        let p = r.project
        p.lattice.flexible = nil
        p.lattice.chooseLatticeType(.structural)
        if let c = p.selection.groups.first(where: { $0.name == "Group C" }) { p.force.makeAnchor(c.id) }
        let h = AppBuildHost(WorkspacePlaceholder(model: r.app, project: p), size: size, test: self)
        h.pump(3)
        try h.pickFromMenu("capsuleMenu", "Structural", what: "\(size): the stage menu")
        h.pump(1)
        return (h, p, r.app)
    }

    func colour(_ h: AppBuildHost, at p: CGPoint) throws -> (r: Double, g: Double, b: Double) {
        h.view.layoutSubtreeIfNeeded()
        let rep = try XCTUnwrap(h.view.bitmapImageRepForCachingDisplay(in: h.view.bounds))
        h.view.cacheDisplay(in: h.view.bounds, to: rep)
        let s = CGFloat(rep.pixelsWide) / h.view.bounds.width
        let c = try XCTUnwrap(rep.colorAt(x: Int(p.x * s), y: Int(p.y * s))?.usingColorSpace(.sRGB))
        return (Double(c.redComponent) * 255, Double(c.greenComponent) * 255, Double(c.blueComponent) * 255)
    }

    /// ★ The ⌃ opens a drawer ABOVE the buttons, right-aligned with the pair as Settings is; no button under it; every row 44 pt;
    /// the menu's items in the order he saw them (the first nearest the buttons).
    func testTheArrowsDrawerStartsAboveTheButtons() throws {
        for size in Self.sizes {
            let (h, _, _) = try latticeStage(size)
            try h.tap("latticeSplitMore", "\(size): ★ the ⌃", settle: 1.2)
            let drawer = try h.onScreen("latticeSplitMoreDrawer", "\(size): ★ the ⌃'s drawer")
            let more = try h.onScreen("latticeSplitMore", "\(size): the ⌃"), run = try h.onScreen("latticeButton", "\(size): Lattice")
            let chip = try h.onScreen("setupChip", "\(size): Settings")
            let top = [more.minY, run.minY, chip.minY, h.frames.all["latticeFixLine"]?.minY ?? .infinity].min()!
            XCTAssertLessThanOrEqual(drawer.maxY, top - CornerPairStyle.fixLineGap + 0.5,
                                     "\(size): ★ it starts above the buttons (\(drawer) over the row at \(top))")
            XCTAssertEqual(drawer.maxX, more.maxX, accuracy: 1, "\(size): right-aligned with the pair, as Settings is")
            for k in ["latticeSplitMore", "latticeButton", "setupChip"] {
                try h.probe(k, "\(size): ★ \(k) uncovered", covers: ["latticeSplitMoreDrawer"])
            }
            let rows = try XCTUnwrap(CornerMoreDrawer.probe["latticeSplitMore"], "\(size): the drawer's rows")
            let drawn = rows.filter { !$0.title.isEmpty }
            XCTAssertTrue(drawn.map(\.title).contains(LatticePreviewMode.printAccurate), "\(size): the switch: \(drawn.map(\.title))")
            for r in drawn {
                let f = try XCTUnwrap(h.frames.all[r.id], "\(size): row \(r.title)")
                XCTAssertGreaterThanOrEqual(f.height, 43.5, "\(size): ★ \(r.title): a 44 pt row (\(f))")
                XCTAssertTrue(drawer.insetBy(dx: -0.5, dy: -0.5).contains(f), "\(size): \(r.title) inside its drawer")
            }
            let first = try XCTUnwrap(h.frames.all[drawn[0].id]), last = try XCTUnwrap(h.frames.all[drawn[drawn.count - 1].id])
            XCTAssertGreaterThan(first.minY, last.minY, "\(size): ★ the first item nearest the buttons, as the system drew the menu")
            try h.picture("corner_more_drawer_\(Int(size.width)).png")
        }
    }

    /// ★ One drawer at a time: Settings shuts the ⌃'s; the ⌃ shuts Settings; a choice shuts it; the switch keeps it up.
    func testOneDrawerAtATime() throws {
        addTeardownBlock { @MainActor in AppSettings.shared.latticePrintAccurate = true; AppSettings.shared.latticeLivePreview = true }
        let (h, _, app) = try latticeStage(AppBuildHost.landscape13)
        try h.tap("setupChip", "Settings", settle: 1.2)
        _ = try h.onScreen("settingsPanel", "premise: the Settings drawer")
        try h.tap("latticeSplitMore", "★ the ⌃", settle: 1.2)
        XCTAssertNil(h.frames.all["settingsPanel"], "★ opening the ⌃ hides Settings")
        _ = try h.onScreen("latticeSplitMoreDrawer", "the ⌃'s drawer")
        try h.tap("setupChip", "★ Settings again", settle: 1.2)
        XCTAssertNil(h.frames.all["latticeSplitMoreDrawer"], "★ opening Settings hides the ⌃'s drawer")
        _ = try h.onScreen("settingsPanel", "the Settings drawer")
        try h.tap("setupChip", "Settings, shut", settle: 1.2)
        XCTAssertNil(app.cornerDrawers.open, "nothing up")
        // the switch: flips, the drawer stays
        try h.tap("latticeSplitMore", "the ⌃", settle: 1.2)
        let before = AppSettings.shared.latticePrintAccurate
        try h.tap("lattice-split-print-accurate", "★ Print-accurate preview", settle: 1.2)
        XCTAssertEqual(AppSettings.shared.latticePrintAccurate, !before, "★ the switch flips it")
        _ = try h.onScreen("latticeSplitMoreDrawer", "★ a switch keeps the drawer up")
        // a choice: made, the drawer goes
        XCTAssertTrue(AppSettings.shared.latticeLivePreview, "premise: the host's Live preview")
        try h.tap("lattice-split-preview-mode-refresh", "★ Click to refresh preview", settle: 1.2)
        XCTAssertFalse(AppSettings.shared.latticeLivePreview, "★ the choice is made")
        XCTAssertNil(h.frames.all["latticeSplitMoreDrawer"], "★ choosing an item shuts the drawer")
        // the ⌃ again shuts it
        try h.tap("latticeSplitMore", "the ⌃", settle: 1.2)
        try h.tap("latticeSplitMore", "the ⌃ again", settle: 1.2)
        XCTAssertNil(h.frames.all["latticeSplitMoreDrawer"], "the ⌃ shuts its own drawer")
    }

    /// ★ "Lattice an optimized result ›" opens its results in place, each row 44 pt; a result opens the Lattice page on it.
    func testTheResultsSubList() throws {
        let (h, p, _) = try latticeStage(AppBuildHost.landscape13)
        p.run.restoreOutcome(AppBuildFixtures.outcome())
        h.pump(1)
        try h.tap("latticeSplitMore", "the ⌃", settle: 1.2)
        XCTAssertNil(h.frames.all["lattice-split-result-0"], "shut: no result rows")
        try h.tap("lattice-split-result", "★ Lattice an optimized result ›", settle: 1.2)
        let drawer = try h.onScreen("latticeSplitMoreDrawer", "the drawer stays up")
        let r0 = try XCTUnwrap(h.frames.all["lattice-split-result-0"], "★ its results, in place")
        XCTAssertGreaterThanOrEqual(r0.height, 43.5, "a 44 pt row")
        XCTAssertTrue(drawer.contains(r0))
        XCTAssertLessThanOrEqual(drawer.maxY, try h.onScreen("latticeButton", "Lattice").minY, "still above the buttons")
    }

    /// ★ Both drawers wear the ⌃ menu's colour (img 45: DS.Surface.menu) — the Settings drawer no longer lighter.
    func testBothDrawersAreTheMenusColour() throws {
        for size in Self.sizes {
            let (h, _, _) = try latticeStage(size)
            try h.tap("setupChip", "\(size): Settings", settle: 1.2)
            let header = try h.onScreen("settingsPanelHeader", "\(size): Settings' header")
            let a = try colour(h, at: CGPoint(x: header.maxX - 40, y: header.midY))   // right of "Settings": nothing drawn there
            try h.tap("latticeSplitMore", "\(size): the ⌃", settle: 1.2)
            let row = try XCTUnwrap(h.frames.all["lattice-split-preview"], "\(size): Preview only")
            let b = try colour(h, at: CGPoint(x: row.maxX - 40, y: row.midY))   // right of "Preview only"
            print("DRAWER COLOURS \(size): Settings \(a) ⌃ \(b)")
            for (x, y) in [(a.r, b.r), (a.g, b.g), (a.b, b.b)] {
                XCTAssertEqual(x, y, accuracy: 4, "\(size): ★ one colour (\(a) vs \(b))")
            }
            let m = DS.Surface.menu
            XCTAssertEqual(b.r, Double(m.r) * 255, accuracy: 8, "\(size): ★ the ⌃ menu's colour (\(b))")
            XCTAssertEqual(b.b, Double(m.b) * 255, accuracy: 8, "\(size): ★ the ⌃ menu's colour (\(b))")
        }
    }

    /// ★ Topology's corner: the same drawer above Optimize and ⌃.
    func testTopologysArrowDrawer() throws {
        for size in Self.sizes {
            let (h, _, _) = try ParityTopologyShots.pad(size, test: self)
            h.pump(1)
            try h.tap("topologySplitMore", "\(size): ★ Topology's ⌃", settle: 1.2)
            let drawer = try h.onScreen("topologySplitMoreDrawer", "\(size): ★ its drawer")
            let split = try h.onScreen("optimizeSplit", "\(size): Optimize + ⌃"), chip = try h.onScreen("setupChip", "\(size): Settings")
            XCTAssertLessThanOrEqual(drawer.maxY, Swift.min(split.minY, chip.minY, h.frames.all["topologyFixLine"]?.minY ?? .infinity) + 0.5,
                                     "\(size): ★ above the buttons")
            for k in ["optimizeSplit", "setupChip"] { try h.probe(k, "\(size): \(k) uncovered", covers: ["topologySplitMoreDrawer"]) }
            let offered = try XCTUnwrap(CornerMoreDrawer.probe["topologySplitMore"]).map(\.title)
            XCTAssertEqual(offered, [TopologyRunCopy.optimizeThenLattice, "Lattice the part (no optimization)"], "the menu's two")
            try h.tap("setupChip", "\(size): Settings", settle: 1.2)
            XCTAssertNil(h.frames.all["topologySplitMoreDrawer"], "\(size): ★ Settings hides it")
        }
    }

    /// ★ Results' ⌃: its drawer above the corner; Open in Library runs.
    func testResultsArrowDrawer() throws {
        let o = try ResultsRedesignTests.strengthenOutcome()
        var closed = 0
        let h = AppBuildHost(ResultsScreen(projectName: "CarriageArms", outcome: o, onClose: { closed += 1 }, undo: {}, redo: {},
                                           resultsModel: ResultsModel(projectName: "CarriageArms", outcome: o)),
                             size: AppBuildHost.landscape13, test: self)
        h.pump(2)
        try h.tap("resultsSplitMore", "★ Results' ⌃", settle: 1.2)
        let drawer = try h.onScreen("resultsSplitMoreDrawer", "★ its drawer")
        for k in ["resultsSplitMore", "resultsExport"] {
            let f = try h.probe(k, "\(k) uncovered", covers: ["resultsSplitMoreDrawer"])
            XCTAssertLessThanOrEqual(drawer.maxY, f.minY + 0.5, "★ above \(k)")
        }
        try h.tap("results-split-library", "★ Open in Library", settle: 1.2)
        XCTAssertEqual(closed, 1, "★ it runs")
        XCTAssertNil(h.frames.all["resultsSplitMoreDrawer"], "★ and the drawer shuts")
    }

    /// RED CONTROL: drawn in code order, the first item sits at the top — far from the buttons, not as he saw the menu.
    func testRedControlTopDownOrder() throws {
        CornerMoreDrawer.controlTopDown = true
        addTeardownBlock { @MainActor in CornerMoreDrawer.controlTopDown = false }
        let (h, _, _) = try latticeStage(AppBuildHost.landscape13)
        try h.tap("latticeSplitMore", "the ⌃", settle: 1.2)
        let rows = try XCTUnwrap(CornerMoreDrawer.probe["latticeSplitMore"]).filter { !$0.title.isEmpty }
        let first = try XCTUnwrap(h.frames.all[rows[0].id]), last = try XCTUnwrap(h.frames.all[rows[rows.count - 1].id])
        XCTAssertLessThan(first.minY, last.minY, "RED: the first item at the top")
    }
}

/// ★ A tap on the 3D view (on the part, or on nothing) shuts the open drawer; only the tap callbacks it had are wrapped.
@MainActor
final class CornerDrawersTapTests: XCTestCase {
    func testATapOnTheViewShutsTheOpenDrawer() throws {
        let d = CornerDrawers()
        var empty = 0, ray = 0
        let v = MetalMeshView(mesh: nil).onEmptyTap { empty += 1 }.onTapRay { _, _, _ in ray += 1; return false }
            .closesCornerDrawers(d)
        d.set(CornerDrawers.settings, true)
        v.inputs.onEmptyTap?()
        XCTAssertNil(d.open, "★ a tap on empty space shuts Settings")
        XCTAssertEqual(empty, 1, "and still does what it did")
        d.toggle("latticeSplitMore")
        XCTAssertTrue(d.isOpen("latticeSplitMore"))
        _ = v.inputs.onTapRay?(.zero, SIMD3<Float>(0, 0, 1), 3)
        XCTAssertNil(d.open, "★ a tap on the part shuts the ⌃'s drawer")
        XCTAssertEqual(ray, 1)
        XCTAssertNil(v.inputs.onMiss, "a callback the view did not have is not added")
        XCTAssertNil(v.inputs.onPickPoint, "(nor a pick: no recognizer changes)")
        // one at a time
        d.toggle("latticeSplitMore"); d.set(CornerDrawers.settings, true)
        XCTAssertEqual(d.open, CornerDrawers.settings, "★ Settings shuts the ⌃'s")
        d.toggle("latticeSplitMore")
        XCTAssertEqual(d.open, "latticeSplitMore", "★ the ⌃ shuts Settings")
        d.set(CornerDrawers.settings, false)
        XCTAssertEqual(d.open, "latticeSplitMore", "shutting Settings leaves the ⌃'s alone")
    }

    /// The pages' 3D views carry it; no new alert or confirmation dialog anywhere.
    func testThePagesWireIt() throws {
        let ws = try FlexibleSource.code("WorkspacePlaceholder.swift"), rs = try FlexibleSource.code("ResultsScreen.swift")
        XCTAssertTrue(ws.contains(".closesCornerDrawers(model.cornerDrawers)"), "★ the workspace's 3D view")
        XCTAssertTrue(rs.contains(".closesCornerDrawers(model.cornerDrawers)"), "★ Results' 3D view")
        XCTAssertFalse(ws.contains("@State private var setupPanelOpen"), "★ the drawers' state is the model's, not a @State")
        for (name, src) in [("WorkspacePlaceholder", ws), ("ResultsScreen", rs)] {
            XCTAssertFalse(src.contains("DSSplitButton(key: \"latticeSplitMore\") {") || src.contains("DSSplitButton(key: \"topologySplitMore\") {")
                           || src.contains("DSSplitButton(key: \"resultsSplitMore\") {"), "\(name): ★ no system menu on the corner's ⌃")
        }
        XCTAssertTrue(ws.contains(".cornerTapCloses(model.cornerDrawers)") && rs.contains(".cornerTapCloses(model.cornerDrawers)"),
                      "★ his 11-22: a tap anywhere outside the open drawer closes it, on both pages")
    }
}

/// ★ His answer 11-22 ("If you mean tapping on the Selections panel or opening up a new menu, then it ABSOLUTELY should"): a
/// real click ANYWHERE outside the open drawer closes it and still does its own job; inside it, or on the corner's own chip and
/// ⌃, it does not (they switch). Both sizes, the Lattice and Topology stages and Results, with a RED CONTROL.
@MainActor
final class CornerDrawersOutsideTapHostedTests: XCTestCase {
    static let sizes = [AppBuildHost.landscape13, CGSize(width: 820, height: 1180)]

    func latticeStage(_ size: CGSize) throws -> (AppBuildHost, ProjectModel, AppModel) {
        let r = try FlexiblePressFixtures.a1Project(3, self, facePrism: true)
        let p = r.project
        p.lattice.flexible = nil
        p.lattice.chooseLatticeType(.structural)
        if let c = p.selection.groups.first(where: { $0.name == "Group C" }) { p.force.makeAnchor(c.id) }
        let h = AppBuildHost(WorkspacePlaceholder(model: r.app, project: p), size: size, test: self)
        h.pump(3)
        try h.pickFromMenu("capsuleMenu", "Structural", what: "\(size): the stage menu")
        h.pump(1)
        return (h, p, r.app)
    }

    func click(_ h: AppBuildHost, _ f: CGRect, settle: Double = 1.2) { h.click(CGPoint(x: f.midX, y: f.midY), settle: settle) }

    func testOnTheLatticeStageATapOutsideClosesAndStillDoesItsJob() throws {
        for size in Self.sizes {
            let (h, p, app) = try latticeStage(size)
            // a Selections row: the drawer goes AND the row is picked
            let g = try XCTUnwrap(p.latticeFaceGroups.first, "\(size): premise: a lattice group (his Top's prism)")
            let rowKey = "selGroup-\(g.id.uuidString)"
            h.scrollIntoList(rowKey)
            XCTAssertNil(p.latticeList.activeGroupID, "\(size): premise: nothing picked")
            try h.tap("latticeSplitMore", "\(size): the ⌃", settle: 1.2)
            _ = try h.onScreen("latticeSplitMoreDrawer", "\(size): premise: the ⌃'s drawer")
            click(h, try h.onScreen(rowKey, "\(size): a Selections row"))
            XCTAssertNil(h.frames.all["latticeSplitMoreDrawer"], "\(size): ★ a tap on a Selections row closes the drawer")
            XCTAssertEqual(p.latticeList.activeGroupID, g.id, "\(size): ★ … and still picks the row")
            // the stage menu (top bar): the drawer goes and the menu opens
            try h.tap("setupChip", "\(size): Settings", settle: 1.2)
            _ = try h.onScreen("settingsPanel", "\(size): premise: the Settings drawer")
            let offered = try h.pickFromMenu("capsuleMenu", "(none: read the menu only)", what: "\(size): ★ the stage menu")
            XCTAssertFalse(offered.isEmpty, "\(size): ★ the menu still opens: \(offered)")
            XCTAssertNil(h.frames.all["settingsPanel"], "\(size): ★ opening a menu closes the Settings drawer")
            XCTAssertNil(app.cornerDrawers.open)
            // the view cube's corner: its view buttons (Orthographic │ Perspective) — the drawer goes, the view switches. (The
            // cube itself is a Metal view whose own gesture a synthesised Mac click never reaches; on the iPad the window's
            // watcher sees every touch, and the cube closes it besides — `closesCornerDrawersOnTouch`.)
            try h.tap("latticeSplitMore", "\(size): the ⌃", settle: 1.2)
            let ortho = ViewProjection.shared.orthographic
            defer { ViewProjection.shared.orthographic = ortho }
            let viewKey = ortho ? "viewPairPerspective" : "viewPairOrthographic"
            click(h, try h.onScreen(viewKey, "\(size): the view corner's other button"))
            XCTAssertNil(h.frames.all["latticeSplitMoreDrawer"], "\(size): ★ a tap on the view corner closes it")
            XCTAssertEqual(ViewProjection.shared.orthographic, !ortho, "\(size): ★ … and still switches the view")
            try h.tap("latticeSplitMore", "\(size): the ⌃ again", settle: 1.2)
            // inside the drawer: it stays
            let drawer = try h.onScreen("latticeSplitMoreDrawer", "\(size): the ⌃'s drawer")
            h.click(CGPoint(x: drawer.midX, y: drawer.minY + 3), settle: 1.2)
            _ = try h.onScreen("latticeSplitMoreDrawer", "\(size): ★ a tap inside the drawer leaves it up")
            // Settings while the ⌃'s is up: they switch (no close-then-reopen)
            try h.tap("setupChip", "\(size): ★ Settings", settle: 1.2)
            XCTAssertEqual(app.cornerDrawers.open, CornerDrawers.settings, "\(size): ★ Settings switches in")
            _ = try h.onScreen("settingsPanel", "\(size): the Settings drawer")
            // inside the Settings drawer (a row's left margin, beside its name — not the header, which folds it): it stays
            let row = try XCTUnwrap(h.frames.all["settingsRow-units"] ?? h.frames.all.first { $0.key.hasPrefix("settingsRow-") }?.value,
                                    "\(size): a Settings row")
            h.click(CGPoint(x: row.minX + 5, y: row.midY), settle: 1.2)
            _ = try h.onScreen("settingsPanel", "\(size): ★ a tap inside Settings leaves it up")
            // the ⌃ while Settings is up: they switch
            try h.tap("latticeSplitMore", "\(size): ★ the ⌃", settle: 1.2)
            XCTAssertNil(h.frames.all["settingsPanel"], "\(size): ★ Settings closed")
            _ = try h.onScreen("latticeSplitMoreDrawer", "\(size): ★ the ⌃'s drawer open")
        }
    }

    func testOnTopologyARowTapClosesAndPicks() throws {
        for size in Self.sizes {
            let (h, p, _) = try ParityTopologyShots.pad(size, scenarios: false, test: self)
            h.pump(1)
            let g = try XCTUnwrap(p.selection.groups.first)
            let rowKey = "selGroup-\(g.id.uuidString)"
            p.selection.clearActive()
            h.pump(0.5)
            h.scrollIntoList(rowKey)
            try h.tap("topologySplitMore", "\(size): Topology's ⌃", settle: 1.2)
            _ = try h.onScreen("topologySplitMoreDrawer", "\(size): premise: its drawer")
            click(h, try h.onScreen(rowKey, "\(size): a Selections row"))
            XCTAssertNil(h.frames.all["topologySplitMoreDrawer"], "\(size): ★ the drawer closes")
            XCTAssertEqual(p.selection.activeGroupID, g.id, "\(size): ★ and the row is picked")
        }
    }

    func testOnResultsATapOutsideClosesAndStillDoesItsJob() throws {
        let o = try ResultsRedesignTests.strengthenOutcome()
        let h = AppBuildHost(ResultsScreen(projectName: "CarriageArms", outcome: o, undo: {}, redo: {},
                                           resultsModel: ResultsModel(projectName: "CarriageArms", outcome: o)),
                             size: AppBuildHost.landscape13, test: self)
        h.pump(2)
        try h.tap("resultsSplitMore", "Results' ⌃", settle: 1.2)
        _ = try h.onScreen("resultsSplitMoreDrawer", "premise: its drawer")
        try h.tap("resultsDetailsButton", "★ Details", settle: 1.5)
        XCTAssertNil(h.frames.all["resultsSplitMoreDrawer"], "★ a tap on Details closes the drawer")
        XCTAssertNotNil(h.frames.all["resultsDetailsPanel"], "★ … and Details still opens")
    }

    /// RED CONTROL: without the rule a tap on a Selections row leaves the drawer up.
    func testRedControlNoOutsideTap() throws {
        CornerDrawers.controlNoOutsideTap = true
        addTeardownBlock { @MainActor in CornerDrawers.controlNoOutsideTap = false }
        let (h, p, _) = try latticeStage(AppBuildHost.landscape13)
        let g = try XCTUnwrap(p.latticeFaceGroups.first)
        try h.tap("latticeSplitMore", "the ⌃", settle: 1.2)
        click(h, try h.onScreen("selGroup-\(g.id.uuidString)", "a Selections row"))
        XCTAssertNotNil(h.frames.all["latticeSplitMoreDrawer"], "RED: the drawer stays up")
    }
}
#endif
