// VersionNotes28HostedTests — ★ his iPad notes on release 18 (2026-11-24), on the real pages at his two iPad sizes (13″
// landscape and 820 × 1180 portrait), clicked with real mouse events: his words on a version card, its ⋯ and its Details; the
// version chip's Edit description; a version opening as he left it; Results' top row where every stage's sits (under a 24 pt
// top safe area, as the iPad's status bar gives); Export a 3MF, with Export as STL and its (i) in the ⌃. Hosted tests have no
// SwiftUI accessibility tree: they read frames (ChromeKeepOutKey) and the shared models' state.
#if canImport(AppKit) && canImport(MetalKit)
import XCTest
import SwiftUI
import AppKit
import TopOptKit
@testable import TopOptFlows

@MainActor
final class VersionNotes28HostedTests: VersionNotes1123Base {
    static let sizes = [AppBuildHost.landscape13, CGSize(width: 820, height: 1180)]

    override func tearDownWithError() throws {
        AppPopups.shared.current = nil
        VersionDescriptionEditor.shared.close()
        VersionViewOpen.controlOpensAsBefore = false
        ChromeGeometry.controlNoSafeTop = false
        ResultsScreen.exportWriteFailsForTests = false
        ResultsScreen.exportAttemptProbe = nil
        try super.tearDownWithError()
    }

    private func frame(_ h: AppBuildHost, _ key: String, _ what: String) throws -> CGRect {
        try XCTUnwrap(h.frames.all[key], "★ \(what): no frame '\(key)'")
    }

    private func waitFor(_ h: AppBuildHost, _ key: String, seconds: Double = 8) -> CGRect? {
        var waited = 0.0
        while h.frames.all[key] == nil, waited < seconds { h.pump(0.25); waited += 0.25 }
        return h.frames.all[key]
    }

    /// A Library of its own (the cube would be filed as the last size's part).
    private func fresh() {
        let own = fm.temporaryDirectory.appendingPathComponent("topopt-notes28-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: own) }
        root = own
        store = ProjectStore(rootDir: own)
    }

    // MARK: 2 · his words on the card, its ⋯ and its Details

    /// ★ (a) The card shows his words with the automatic differences on one line under them; ⋯ → Edit description opens the
    /// centred editor, prefilled; Save keeps his words.
    func testTheCardShowsHisWordsAndItsMenuEditsThem() throws {
        for size in Self.sizes {
            let dir = fm.temporaryDirectory.appendingPathComponent("topopt-notes28-card-\(UUID().uuidString)", isDirectory: true)
            addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
            let (app, f) = try LibraryPartRowsHostedTests.arms(root: dir)
            let v2 = try XCTUnwrap(f["2"])
            app.library.setDescription("Thicker rim on the rail", folder: v2)
            app.library.route = .part(try XCTUnwrap(app.library.index.part(containing: v2)).id)
            let h = AppBuildHost(AppBuildRoot(model: app).overlay { VersionDescriptionLayer() }, size: size, test: self)
            h.pump(3)
            let words = try frame(h, "library-version-v2-description", "\(size): ★ his words on v2's card")
            let diff = try frame(h, "library-version-v2-differences", "\(size): ★ the differences under them")
            XCTAssertLessThanOrEqual(words.maxY, diff.minY + 0.5, "\(size): ★ the differences on the line under his words")
            XCTAssertLessThan(diff.height, 22, "\(size): ★ one line")
            XCTAssertNil(h.frames.all["library-version-v1-description"], "\(size): RED CONTROL: v1 has none, so none is drawn")
            XCTAssertNotNil(h.frames.all["library-version-v1-differences"], "\(size): v1 still says its differences")
            let offered = try h.pickFromMenu("library-version-v2-menu", VersionDescriptionCopy.edit, what: "\(size): v2's ⋯")
            XCTAssertTrue(offered.contains(VersionDescriptionCopy.edit), "\(size): ★ ⋯ offers Edit description: \(offered)")
            h.pump(1)
            XCTAssertEqual(VersionDescriptionEditor.shared.editing?.folder, v2, "\(size): ★ the editor is v2's")
            XCTAssertEqual(VersionDescriptionEditor.shared.text, "Thicker rim on the rail", "\(size): ★ his words to start from")
            let editor = try h.onScreen("versionDescriptionEditor", "\(size): ★ the centred editor")
            XCTAssertEqual(editor.midX, size.width / 2, accuracy: 2, "\(size): ★ centred")
            try h.probe("versionDescriptionSave", "\(size): ★ Save, a 44 pt target")
            try h.probe("versionDescriptionCancel", "\(size): Cancel")
            VersionDescriptionEditor.shared.text = "Thicker rim, Organic off"
            try h.tap("versionDescriptionSave", "\(size): Save", settle: 1)
            XCTAssertNil(VersionDescriptionEditor.shared.editing, "\(size): the editor shut")
            XCTAssertEqual(app.library.description(of: v2), "Thicker rim, Organic off", "\(size): ★ kept")
        }
    }

    /// ★ (b) Details: a pencil beside Description edits the words in place (Save / Cancel there).
    func testDetailsPencilEditsTheDescriptionInPlace() throws {
        for size in Self.sizes {
            let dir = fm.temporaryDirectory.appendingPathComponent("topopt-notes28-details-\(UUID().uuidString)", isDirectory: true)
            addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
            let (app, f) = try LibraryPartRowsHostedTests.arms(root: dir)
            let v2 = try XCTUnwrap(f["2"])
            app.library.setDescription("First words", folder: v2)
            app.library.route = .details(v2)
            let h = AppBuildHost(AppBuildRoot(model: app), size: size, test: self)
            h.pump(3)
            _ = try frame(h, "library-details-v2-description", "\(size): ★ Description on v2's Details")
            _ = try frame(h, "library-details-v2-description-text", "\(size): his words")
            XCTAssertNil(h.frames.all["library-details-v2-description-field"], "\(size): RED CONTROL: no field until the pencil")
            try h.probe("library-details-v2-description-edit", "\(size): ★ the pencil, a 44 pt target")
            try h.tap("library-details-v2-description-edit", "\(size): the pencil", settle: 1)
            _ = try frame(h, "library-details-v2-description-field", "\(size): ★ the field, in place")
            try h.probe("library-details-v2-description-save", "\(size): ★ Save")
            try h.tap("library-details-v2-description-cancel", "\(size): Cancel", settle: 1)
            XCTAssertNil(h.frames.all["library-details-v2-description-field"], "\(size): Cancel shuts it")
            XCTAssertEqual(app.library.description(of: v2), "First words", "\(size): Cancel keeps his words")
            try h.tap("library-details-v2-description-edit", "\(size): the pencil again", settle: 1)
            try h.tap("library-details-v2-description-save", "\(size): Save", settle: 1)
            XCTAssertEqual(app.library.description(of: v2), "First words", "\(size): Save keeps what the field holds")
        }
    }

    // MARK: 2 (e) · the version chip

    /// ★ (e) A tap on "v1" in the top bar offers Edit description, beside Save and Save and start a new version.
    func testTheVersionChipOffersEditDescription() throws {
        for size in Self.sizes {
            fresh()
            let (app, v1) = try optimizedCube()
            try open(app, v1.id)
            let h = AppBuildHost(AppBuildWorkspace(model: app), size: size, test: self)
            h.pump(2)
            try h.tap("topLeftVersion", "\(size): the version chip")
            let drawer = try h.onScreen("versionMenuDrawer", "\(size): its drawer")
            let row = try h.probe("versionMenuDescribe", "\(size): ★ Edit description, a 44 pt target")
            XCTAssertTrue(drawer.insetBy(dx: -0.5, dy: -0.5).contains(row), "\(size): in the drawer")
            XCTAssertLessThan(try frame(h, "versionMenuNew", "new").maxY, row.minY + 0.5, "\(size): after the two saves")
            h.click(CGPoint(x: row.midX, y: row.midY), settle: 1)
            XCTAssertEqual(VersionDescriptionEditor.shared.editing?.folder, v1.id, "\(size): ★ the editor is v1's")
            XCTAssertNil(h.frames.all["versionMenuDrawer"], "\(size): the drawer shut")
            VersionDescriptionEditor.shared.close()
        }
    }

    // MARK: 3 · a version opens as he left it

    /// ★ A draft opens on the stage he left it on (the lattice stage), with its view kept; RED CONTROL: release 18 opened every
    /// version on Topology. Leaving it keeps the page with it.
    func testADraftOpensOnTheStageHeLeftIt() throws {
        for size in Self.sizes {
            for control in [true, false] {
                fresh()
                VersionViewOpen.controlOpensAsBefore = control
                let (app, v1) = try optimizedCube()
                var draft = try XCTUnwrap(store.snapshot(id: v1.id))
                draft.id = UUID(); draft.optimized = nil; draft.savedAt = Date(timeIntervalSince1970: 200)
                var lat = LatticeSettings(enabled: true); lat.stageMode = .aesthetic
                draft.lattice = lat
                try store.save(draft, modelSource: URL(fileURLWithPath: store.modelPath(id: v1.id, fileName: draft.modelFileName)))
                app.library.noteParent(v1.id, of: draft.id)
                app.library.refresh()
                app.recentProjects.insert(ProjectDuplication.recent(for: draft), at: 0)
                store.saveViewState(VersionViewState(stage: "lattice", page: VersionViewState.pageSetup, selectionsCollapsed: false,
                                                     outlines: true), id: draft.id)
                try open(app, draft.id)
                let h = AppBuildHost(AppBuildRoot(model: app), size: size, test: self)   // (Back unmounts the page, as RootView)
                h.pump(2)
                if control {
                    XCTAssertNil(h.frames.all["capsuleLattice"], "\(size): RED CONTROL: on Topology, as release 18 opened it")
                } else {
                    XCTAssertNotNil(waitFor(h, "capsuleLattice"), "\(size): ★ on the lattice stage he left it on")
                    XCTAssertEqual(VersionViewOpen.settled[draft.id], "lattice")
                    app.backHome()
                    h.pump(1)
                    XCTAssertEqual(store.loadViewState(id: draft.id)?.stage, "lattice", "\(size): ★ leaving keeps the page")
                    XCTAssertEqual(store.loadViewState(id: draft.id)?.outlines, true, "\(size): ★ its view buttons with it")
                    XCTAssertNotNil(store.loadViewState(id: draft.id)?.camera, "\(size): ★ and its camera")
                }
            }
        }
    }

    /// ★ A version with a result opened with Open (not its card's tap) opens on the stage its result belongs to — not on the
    /// result, even when Results was the last thing he looked at.
    func testOpenOnAVersionWithAResultOpensTheVersionNotTheResult() throws {
        for size in Self.sizes {
            fresh()
            let (app, v1) = try optimizedCube()
            store.saveViewState(VersionViewState(stage: "lattice", page: VersionViewState.pageResults), id: v1.id)
            try open(app, v1.id)
            let h = AppBuildHost(AppBuildWorkspace(model: app), size: size, test: self)
            h.pump(3)
            waitForResults(try XCTUnwrap(app.project))
            h.pump(1)
            XCTAssertNil(h.frames.all["resultsExport"], "\(size): ★ not the result")
            XCTAssertNotNil(waitFor(h, "capsuleResults"), "\(size): ★ on the stage its (Topology) result belongs to")
            XCTAssertNil(h.frames.all["capsuleLattice"], "\(size): ★ not the stage last looked at")
            XCTAssertEqual(VersionViewOpen.settled[v1.id], "topology")
        }
    }

    // MARK: 4a / 4c · Results: the top row, Export

    /// Results with a 24 pt top safe area (the iPad's status bar).
    private func resultsPage(_ size: CGSize) throws -> (AppBuildHost, AppModel) {
        fresh()
        let (app, v1) = try optimizedCube()
        try open(app, v1.id)
        waitForResults(try XCTUnwrap(app.project))
        let page = AppBuildWorkspace(model: app).safeAreaInset(edge: .top, spacing: 0) { Color.clear.frame(height: 24) }
        let h = AppBuildHost(page, size: size, test: self)
        h.pump(2)
        return (h, app)
    }

    /// ★ (4a) The top row ("‹ Squish Mechanism | Part" and the version pill) sits on Results exactly where it sits on Setup.
    /// RED CONTROL: release 18 drew Results edge to edge and its row 24 pt higher.
    func testResultsTopRowSitsWhereEveryStagesDoes() throws {
        for size in Self.sizes {
            for control in [true, false] {
                ChromeGeometry.controlNoSafeTop = control
                let (h, _) = try resultsPage(size)
                let setup = try frame(h, "backButton", "\(size): Setup's back")
                XCTAssertGreaterThanOrEqual(setup.minY, 24 - 0.5, "premise: Setup's row is under the safe area")
                try h.tap("capsuleResults", "\(size): Results", settle: 2)
                XCTAssertNotNil(waitFor(h, "resultsExport"), "\(size): Results is up")
                h.pump(1)
                let results = try frame(h, "backButton", "\(size): Results' back")
                if control {
                    XCTAssertLessThan(results.minY, setup.minY - 20, "\(size): RED CONTROL: release 18's row, higher on Results")
                } else {
                    XCTAssertEqual(results.minY, setup.minY, accuracy: 1, "\(size): ★ the same place as Setup's")
                    XCTAssertEqual(results.minX, setup.minX, accuracy: 1, "\(size): ★ and the same left edge")
                }
            }
        }
    }

    /// ★ (4c) Export writes the 3MF; the ⌃ offers Export as STL with its line and its (i).
    func testExportIsThe3MFAndTheCaretOffersSTL() throws {
        var attempts: [String] = []
        ResultsScreen.exportWriteFailsForTests = true
        ResultsScreen.exportAttemptProbe = { attempts.append($0) }
        for size in Self.sizes {
            attempts = []
            let (h, _) = try resultsPage(size)
            try h.tap("capsuleResults", "\(size): Results", settle: 2)
            XCTAssertNotNil(waitFor(h, "resultsExport"))
            try h.tap("resultsExport", "\(size): Export", settle: 1)
            XCTAssertEqual(attempts, ["3mf"], "\(size): ★ Export is the 3MF (RED CONTROL: release 18's was \"stl\")")
            try h.tap("resultsSplitMore", "\(size): ⌃", settle: 1)
            _ = try h.onScreen("resultsSplitMoreDrawer", "\(size): the ⌃'s drawer")
            let rows = CornerMoreDrawer.probe["resultsSplitMore"] ?? []
            let stl = try XCTUnwrap(rows.first { $0.id == "results-split-export-stl" }, "\(size): ★ Export as STL in the ⌃: \(rows)")
            XCTAssertEqual(stl.title, ResultsExportCopy.stlItem)
            XCTAssertEqual(stl.line, ResultsExportCopy.stlLine)
            try h.probe("results-split-export-stl-info", "\(size): ★ its (i), a 44 pt target")
            try h.tap("results-split-export-stl-info", "\(size): its (i)", settle: 1)
            XCTAssertEqual(AppPopups.shared.current?.text, ResultsExportCopy.stlInfo, "\(size): ★ the (i) in the centred card")
            XCTAssertEqual(AppPopups.shared.current?.info, true)
            AppPopups.shared.current = nil
            if h.frames.all["resultsSplitMoreDrawer"] == nil { try h.tap("resultsSplitMore", "\(size): ⌃ again", settle: 1) }
            try h.tap("results-split-export-stl", "\(size): Export as STL", settle: 1)
            XCTAssertEqual(attempts, ["3mf", "stl"], "\(size): ★ the STL, from the ⌃")
        }
    }
}
#endif
