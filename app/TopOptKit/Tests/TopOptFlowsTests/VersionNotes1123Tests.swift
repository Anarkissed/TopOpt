// VersionNotes1123Tests — ★ his iPad notes 2026-11-23 on versions (RESULTS_REPORT §5, §7):
//   "A new version should be made withOUT the export as soon as ANY changes are made onto the version the result is on."
//   "Tapping on "v7 draft" should open up two options: Save, and Save and Start a New Version"
//   "When I open up an old Lattice job ... all the settings should already be saved."
// Model tests on his optimized cube in a grouped Library (LibraryVersioningTests' set-up); hosted tests of the version chip's
// drawer and of the watch at his two iPad sizes.
import XCTest
import SwiftUI
import TopOptKit
@testable import TopOptFlows

@MainActor
class VersionNotes1123Base: XCTestCase {
    static let repoRoot: URL = {
        var u = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { u.deleteLastPathComponent() }
        return u
    }()
    static var materialsPath: String { repoRoot.appendingPathComponent("core/src/materials/materials.json").path }
    static var cubeSTL: URL { repoRoot.appendingPathComponent("core/tests/fixtures/stl/cube_10mm.stl") }

    var root: URL!
    var store: ProjectStore!
    let fm = FileManager.default

    override func setUpWithError() throws {
        root = fm.temporaryDirectory.appendingPathComponent("topopt-versions-1123-\(UUID().uuidString)", isDirectory: true)
        store = ProjectStore(rootDir: root)
        AppModel.controlEditsInPlace = false
    }
    override func tearDownWithError() throws {
        AppModel.controlEditsInPlace = false
        if let root { try? fm.removeItem(at: root) }
    }

    /// His optimized cube: one version with three results, grouped (the Library numbers it v1).
    func optimizedCube() throws -> (AppModel, ProjectSnapshot) {
        let src = root.appendingPathComponent("import", isDirectory: true)
        try fm.createDirectory(at: src, withIntermediateDirectories: true)
        let model = src.appendingPathComponent("cube.stl")
        try fm.copyItem(at: Self.cubeSTL, to: model)
        // a version that ran has its gravity set (no "Which way is down?" banner over the top row)
        var force = ForceModel()
        force.setGravity(direction: SIMD3(0, 0, -1))
        let snap = ProjectSnapshot(id: UUID(), name: "Cube", material: "PLA", process: .fdm,
                                   modelFileName: "model.stl", originalFileName: "cube.stl",
                                   savedAt: Date(timeIntervalSince1970: 100), selection: SelectionModel(),
                                   force: force, quality: .fast, optimized: true)
        try store.save(snap, modelSource: model)
        try fm.removeItem(at: src)
        try store.saveResults(try OutcomeCodec.encode(OutcomeCodec.dto(from: AppBuildFixturesLite.outcome())), id: snap.id)
        let app = AppModel(materialsPath: Self.materialsPath, store: store)
        app.loadMaterials()
        app.library.refresh()
        try app.library.group(projectName: nil, partIDs: nil)
        return (app, snap)
    }

    func open(_ app: AppModel, _ id: UUID) throws {
        app.open(try XCTUnwrap(app.recentProjects.first { $0.id == id }))
        XCTAssertNotNil(app.project?.importedFile, "really re-imported")
    }

    /// Waits (pumping the run loop) for the restored results to land in the reopened project.
    func waitForResults(_ p: ProjectModel, _ s: Double = 3) {
        let end = Date().addingTimeInterval(s)
        while !p.hasResults, Date() < end { _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.02)) }
    }

    func projectJSON(_ id: UUID) throws -> Data {
        try Data(contentsOf: root.appendingPathComponent(id.uuidString).appendingPathComponent("project.json"))
    }
}

/// Results that look like his (never his job inputs): three accepted variants on a one-triangle mesh.
enum AppBuildFixturesLite {
    static func outcome(_ n: Int = 3) -> OptimizeOutcome {
        OptimizeOutcome(variants: (0..<n).map { i in
            OptimizeVariant(requestedVolumeFraction: 0.5, achievedVolumeFraction: 0.5, massGrams: 10 + Double(i),
                            supportVolumeVoxels: 0, meshTriangleCount: 1, worstCaseMargin: 2, accepted: true, v3Passes: true,
                            meshVertices: [0, 0, 0, 1, 0, 0, 0, 1, 0], meshIndices: [0, 1, 2])
        }, stoppedOnMargin: false, cancelled: false, acceptedCount: n, voxelVolumeMM3: 1,
           gridNx: 2, gridNy: 2, gridNz: 2, gridOrigin: .zero, spacing: 1)
    }
}

@MainActor
final class VersionNotes1123Tests: VersionNotes1123Base {

    /// ★ The first change on a version with a result makes the next version at once and the workspace moves there (the same
    /// live project): the result stays on its version, untouched, and the new version holds none. RED CONTROL: edits in place.
    func testTheFirstChangeOnAVersionWithAResultMakesTheNextVersion() throws {
        let (app, v1) = try optimizedCube()
        let before = try projectJSON(v1.id)
        try open(app, v1.id)
        let p = try XCTUnwrap(app.project)
        waitForResults(p)
        XCTAssertTrue(p.hasResults, "v1's result is on screen")
        // RED CONTROL: edits stay on v1 (nothing moves until Back writes a draft)
        AppModel.controlEditsInPlace = true
        p.quality = .fine
        XCTAssertFalse(app.moveToNextVersionIfEdited(p), "RED CONTROL: no move")
        XCTAssertEqual(p.id, v1.id)
        AppModel.controlEditsInPlace = false
        XCTAssertTrue(app.moveToNextVersionIfEdited(p), "★ the first change makes the next version")
        XCTAssertTrue(app.project === p, "★ the workspace moved in place (the same live project)")
        XCTAssertNotEqual(p.id, v1.id)
        XCTAssertEqual(app.library.version(p.id)?.number, 2, "★ v2, the next number")
        XCTAssertEqual(app.library.version(p.id)?.parentNumber, 1)
        XCTAssertEqual(TopLeftBlock.versionLabel(app.library, folder: p.id), "v2 draft", "★ the top bar shows the new number")
        XCTAssertEqual(try projectJSON(v1.id), before, "★ v1's settings are the ones its result was made with")
        XCTAssertTrue(store.hasPersistedResults(id: v1.id), "★ the result stays on its own version")
        XCTAssertFalse(store.hasPersistedResults(id: p.id), "the new version has no result")
        XCTAssertFalse(p.hasResults, "★ the workspace shows no result of v1's as v2's")
        XCTAssertNil(ResultsReplacementPrompt.forNewRun(existing: p.run.outcome), "★ a run now asks nothing: no re-run card")
        XCTAssertEqual(store.snapshot(id: p.id)?.quality, .fine, "★ the edit is v2's")
        XCTAssertTrue(p.importedFile?.path.hasPrefix(root.appendingPathComponent(p.id.uuidString).path) == true,
                      "★ its model is read from its own folder (sidecars never written into v1's)")
        XCTAssertFalse(app.moveToNextVersionIfEdited(p), "a version with no result takes its edits")
        p.minimizePlastic = false
        app.persistCurrentProject()
        XCTAssertEqual(store.snapshot(id: p.id)?.minimizePlastic, false, "★ saved in place on v2")
        XCTAssertEqual(app.library.index.part(containing: v1.id)?.versions.count, 2, "never a pile")
        // reopening v1 shows it as it ran; reopening v2 shows its edits
        try open(app, v1.id)
        XCTAssertEqual(app.project?.quality, .fast)
        try open(app, p.id)
        XCTAssertEqual(app.project?.quality, .fine)
        XCTAssertEqual(app.project?.minimizePlastic, false)
    }

    /// ★ From an older version the next one branches (v1 → v1.1 once v2 is there); Back after an edit never leaves it on v1.
    func testAChangeOnAnOlderVersionBranches() throws {
        let (app, v1) = try optimizedCube()
        try open(app, v1.id)
        app.project?.quality = .fine
        app.backHome()   // the edit is saved as it leaves: it moved to v2
        let part = try XCTUnwrap(app.library.index.part(containing: v1.id))
        XCTAssertEqual(part.versions.count, 2)
        let v2 = try XCTUnwrap(part.versions.first { $0.folderID != v1.id })
        XCTAssertEqual(v2.number, 2)
        // v2 runs (its own result), then v1 is changed again
        try store.saveResults(try XCTUnwrap(store.loadResultsData(id: v1.id)), id: v2.folderID)
        app.library.refresh()
        try open(app, v1.id)
        let p = try XCTUnwrap(app.project)
        p.minimizePlastic = false
        XCTAssertTrue(app.moveToNextVersionIfEdited(p))
        XCTAssertEqual(app.library.version(p.id)?.number, VersionNumber("1.1"), "★ from an older version: a branch")
    }

    /// ★ A pick is not a change: the active group of either list, a folded region, the shown load scenario. RED CONTROL: the
    /// Library's own comparison counts the active group.
    func testAPickIsNotAChange() throws {
        var sel = SelectionModel()
        sel.pickFace(1)
        let a = ProjectSnapshot(id: UUID(), name: "Cube", material: "PLA", process: .fdm, modelFileName: "model.stl",
                                originalFileName: "cube.stl", savedAt: Date(), selection: sel, force: ForceModel())
        var b = a
        b.selection.clearActive()
        XCTAssertNotNil(a.selection.activeGroupID)
        XCTAssertFalse(LibrarySettings.same(a, b), "RED CONTROL: the Library's comparison counts the pick")
        XCTAssertTrue(VersionSettings.same(a, b), "★ a pick makes no version")
        var c = b
        c.selection.pickFace(2)
        XCTAssertFalse(VersionSettings.same(a, c), "a face added is a change")
        // and on the open version: picking makes nothing
        let (app, v1) = try optimizedCube()
        try open(app, v1.id)
        let p = try XCTUnwrap(app.project)
        XCTAssertFalse(app.moveToNextVersionIfEdited(p), "nothing changed")
        XCTAssertEqual(p.id, v1.id)
    }

    /// ★ The version chip's Save and "Save and start a new version": saved to this version, then the next one made from it
    /// (the same settings, no result) and the workspace on it; from an older version, a branch.
    func testSaveAndStartANewVersion() throws {
        let (app, v1) = try optimizedCube()
        try open(app, v1.id)
        let p = try XCTUnwrap(app.project)
        waitForResults(p)
        app.saveVersion()
        XCTAssertEqual(app.toast, VersionChipCopy.saved("v1"), "★ Save says so")
        XCTAssertEqual(p.id, v1.id, "Save keeps the version")
        let made = try XCTUnwrap(app.saveAndStartNewVersion())
        XCTAssertTrue(app.project === p)
        XCTAssertEqual(p.id, made.id, "★ the workspace is on the new version")
        XCTAssertEqual(app.library.version(p.id)?.number, 2)
        XCTAssertTrue(VersionSettings.same(try XCTUnwrap(store.snapshot(id: v1.id)), try XCTUnwrap(store.snapshot(id: p.id))),
                      "★ it starts from what was saved")
        XCTAssertFalse(store.hasPersistedResults(id: p.id))
        XCTAssertTrue(store.hasPersistedResults(id: v1.id), "v1 keeps its result")
        XCTAssertFalse(p.hasResults)
        // from v2 (the newest): v3; then from v1 (older): v1.1
        XCTAssertEqual(app.library.version(try XCTUnwrap(app.saveAndStartNewVersion()).id)?.number, 3)
        try open(app, v1.id)
        XCTAssertEqual(app.library.version(try XCTUnwrap(app.saveAndStartNewVersion()).id)?.number, VersionNumber("1.1"))
        XCTAssertLessThanOrEqual(VersionChipCopy.saveLine("v12.1").split(separator: " ").count, 5)
        XCTAssertLessThanOrEqual(VersionChipCopy.newLine("v12.1", next: "v12.2").split(separator: " ").count, 5)
    }

    /// ★ RESULTS_REPORT §7: the link from a version to its draft survives relaunch (it lived for the session, so each session
    /// made another draft), and a linked draft that ran is never written over. RED CONTROL: the link gone, another draft.
    func testTheDraftLinkSurvivesRelaunch() throws {
        AppModel.controlEditsInPlace = true   // the edit goes to a draft on Back (the path the link serves)
        let (app, v1) = try optimizedCube()
        try open(app, v1.id)
        app.project?.quality = .fine
        app.backHome()
        XCTAssertEqual(app.library.index.part(containing: v1.id)?.versions.count, 2)
        XCTAssertTrue(fm.fileExists(atPath: VersionDraftLinks.url(store).path), "★ the link is kept on disk")
        // relaunch
        let again = AppModel(materialsPath: Self.materialsPath, store: store)
        again.loadMaterials()
        again.library.refresh()
        try open(again, v1.id)
        again.project?.minimizePlastic = false
        again.backHome()
        XCTAssertEqual(again.library.index.part(containing: v1.id)?.versions.count, 2, "★ the same draft, not another")
        // RED CONTROL: without the link, a second draft
        try fm.removeItem(at: VersionDraftLinks.url(store))
        let third = AppModel(materialsPath: Self.materialsPath, store: store)
        third.loadMaterials()
        third.library.refresh()
        try open(third, v1.id)
        third.project?.quality = .balanced
        third.backHome()
        XCTAssertEqual(third.library.index.part(containing: v1.id)?.versions.count, 3, "RED CONTROL: no link, another draft")
        // a linked draft that has a result of its own is never written over
        let linked = try XCTUnwrap(VersionDraftLinks.read(store)[v1.id])
        try store.saveResults(try XCTUnwrap(store.loadResultsData(id: v1.id)), id: linked)
        XCTAssertNil(VersionDraftLinks.usable(linked, store), "★ a draft that ran takes no more edits")
    }
}

#if canImport(AppKit) && canImport(MetalKit)
/// The version chip's drawer and the watch, in the real page at his two sizes.
@MainActor
final class VersionNotes1123HostedTests: VersionNotes1123Base {
    static let sizes = [AppBuildHost.landscape13, CGSize(width: 820, height: 1180)]

    private func page(_ size: CGSize) throws -> (AppBuildHost, AppModel, UUID) {
        // a Library of its own for each size (the cube would be filed as the same part as the last size's)
        let own = fm.temporaryDirectory.appendingPathComponent("topopt-versions-1123-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: own) }
        root = own
        store = ProjectStore(rootDir: own)
        let (app, v1) = try optimizedCube()
        try open(app, v1.id)
        waitForResults(try XCTUnwrap(app.project))
        let h = AppBuildHost(AppBuildWorkspace(model: app), size: size, test: self)
        h.pump(2)
        return (h, app, v1.id)
    }

    /// ★ A tap on "v1" opens the app's own drawer under it (two rows, each a 44 pt target, nothing covering them);
    /// "Save and start a new version" moves the page to v2 in place; Save says it saved.
    func testTheVersionChipOpensSaveAndSaveAndStartANewVersion() throws {
        for size in Self.sizes.reversed() {
            let (h, app, v1) = try page(size)
            let p = try XCTUnwrap(app.project)
            XCTAssertNil(h.frames.all["versionMenuDrawer"], "\(size): RED CONTROL: shut until tapped")
            let chip = try h.probe("topLeftVersion", "\(size): ★ the version chip, a 44 pt target")
            h.click(CGPoint(x: chip.midX, y: chip.midY))
            XCTAssertTrue(app.cornerDrawers.isOpen(VersionChipMenu.key), "\(size): ★ the tap on \(chip) opened it")
            let drawer = try h.onScreen("versionMenuDrawer", "\(size): ★ the version's drawer")
            XCTAssertGreaterThanOrEqual(drawer.minY, chip.maxY - 0.5, "\(size): ★ under the chip")
            let save = try h.probe("versionMenuSave", "\(size): ★ Save")
            let new = try h.probe("versionMenuNew", "\(size): ★ Save and start a new version")
            XCTAssertLessThan(save.maxY, new.minY + 0.5, "\(size): Save first")
            for k in ["versionMenuSave", "versionMenuNew"] {
                XCTAssertTrue(drawer.insetBy(dx: -0.5, dy: -0.5).contains(try XCTUnwrap(h.frames.all[k])), "\(size): \(k) in it")
            }
            XCTAssertTrue(app.cornerDrawers.isOpen(VersionChipMenu.key), "\(size): one of the corner drawers (one at a time)")
            h.click(CGPoint(x: new.midX, y: new.midY), settle: 1)
            XCTAssertTrue(app.project === p, "\(size): ★ the same page, moved in place")
            XCTAssertNotEqual(p.id, v1, "\(size): ★ on the new version")
            XCTAssertEqual(app.library.version(p.id)?.number, 2, "\(size): ★ v2")
            XCTAssertNil(h.frames.all["versionMenuDrawer"], "\(size): the drawer shut")
            XCTAssertTrue(store.hasPersistedResults(id: v1), "\(size): v1 keeps its result")
            // Save
            let chip2 = try h.probe("topLeftVersion", "\(size): the chip, now v2")
            h.click(CGPoint(x: chip2.midX, y: chip2.midY))
            let save2 = try h.probe("versionMenuSave", "\(size): Save")
            h.click(CGPoint(x: save2.midX, y: save2.midY))
            XCTAssertEqual(app.toast, VersionChipCopy.saved("v2"), "\(size): ★ saved, said")
            app.toast = nil
        }
        let code = try FlexibleSource.code("VersionChipMenu.swift")
        XCTAssertFalse(code.contains(".alert(") || code.contains(".confirmationDialog(") || code.contains("Menu {"),
                       "★ the app's own drawer, never a system alert or menu")
    }

    /// ★ The watch: opening a version with a result (and going to the Lattice stage) changes nothing; the first change of a
    /// setting moves the page to the next version within a moment, and the top bar says so.
    func testTheFirstChangeMovesThePageAndOpeningDoesNot() throws {
        for size in Self.sizes {
            let (h, app, v1) = try page(size)
            let p = try XCTUnwrap(app.project)
            h.pump(1.5)   // past the page's settling
            if h.frames.all["capsuleSetup"] != nil { try h.tap("capsuleSetup", "\(size): Setup, the settings", settle: 1.5) }
            if h.frames.all["capsuleLattice"] != nil { try h.tap("capsuleLattice", "\(size): back to the Lattice view", settle: 1) }
            XCTAssertEqual(p.id, v1, "\(size): ★ opening and looking makes no version")
            XCTAssertEqual(app.library.index.part(containing: v1)?.versions.count, 1)
            p.quality = .fine
            h.pump(1)
            XCTAssertNotEqual(p.id, v1, "\(size): ★ the first change moved the page to the next version")
            XCTAssertTrue(app.project === p)
            XCTAssertEqual(app.library.version(p.id)?.number, 2)
            XCTAssertEqual(store.snapshot(id: p.id)?.quality, .fine, "\(size): saved there")
        }
    }
}
#endif
