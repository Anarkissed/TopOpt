// LibraryVersioningTests.swift — Optimize makes the next version (approved Library mockup 2026-10-25, batch 3).
//
// - A version's settings never change after it ran: editing a version that has results saves into a
//   DRAFT (the next number, "from vN"), and the version's own folder is left as it ran.
// - Optimize on such a version asks "Optimize as vN" with the automatic name; he may change it; the
//   draft runs (his decision 3).
// - Before he groups (today's Home), edits save exactly as today.
// - The ⌄ next to Open lists the drafts, newest first (his decision 6). A run he stops with no result
//   leaves the draft a draft.
// - Export from a card opens that version on Smooth with that result, once.

import XCTest
import TopOptKit
@testable import TopOptFlows

@MainActor
final class LibraryVersioningTests: XCTestCase {

    private static let repoRoot: URL = {
        var u = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { u.deleteLastPathComponent() }
        return u
    }()
    private static var materialsPath: String { repoRoot.appendingPathComponent("core/src/materials/materials.json").path }
    private static var cubeSTL: URL { repoRoot.appendingPathComponent("core/tests/fixtures/stl/cube_10mm.stl") }

    private var root: URL!
    private var store: ProjectStore!
    private let fm = FileManager.default

    override func setUpWithError() throws {
        root = fm.temporaryDirectory.appendingPathComponent("topopt-library-versions-\(UUID().uuidString)", isDirectory: true)
        store = ProjectStore(rootDir: root)
    }
    override func tearDownWithError() throws {
        if let root { try? fm.removeItem(at: root) }
    }

    /// His optimized cube (one version with three results), optionally grouped.
    private func optimizedCube(grouped: Bool = true) throws -> (AppModel, ProjectSnapshot) {
        let src = root.appendingPathComponent("import", isDirectory: true)
        try fm.createDirectory(at: src, withIntermediateDirectories: true)
        let model = src.appendingPathComponent("cube.stl")
        try fm.copyItem(at: Self.cubeSTL, to: model)
        let snap = ProjectSnapshot(id: UUID(), name: "Cube", material: "PLA", process: .fdm,
                                   modelFileName: "model.stl", originalFileName: "cube.stl",
                                   savedAt: Date(timeIntervalSince1970: 100), selection: SelectionModel(),
                                   force: ForceModel(), quality: .fast, optimized: true)
        try store.save(snap, modelSource: model)
        try fm.removeItem(at: src)
        let o = OptimizeOutcome(variants: (0..<3).map { i in
            OptimizeVariant(requestedVolumeFraction: 0.5, achievedVolumeFraction: 0.5, massGrams: 10 + Double(i),
                            supportVolumeVoxels: 0, meshTriangleCount: 1, worstCaseMargin: 2, accepted: true, v3Passes: true,
                            meshVertices: [0, 0, 0, 1, 0, 0, 0, 1, 0], meshIndices: [0, 1, 2])
        }, stoppedOnMargin: false, cancelled: false, acceptedCount: 3, voxelVolumeMM3: 1,
           gridNx: 2, gridNy: 2, gridNz: 2, gridOrigin: .zero, spacing: 1)
        try store.saveResults(try OutcomeCodec.encode(OutcomeCodec.dto(from: o)), id: snap.id)
        let app = AppModel(materialsPath: Self.materialsPath, store: store)
        app.loadMaterials()
        app.library.refresh()
        if grouped { try app.library.group(projectName: nil, partIDs: nil) }
        return (app, snap)
    }

    private func open(_ app: AppModel, _ id: UUID) throws {
        app.open(try XCTUnwrap(app.recentProjects.first { $0.id == id }))
        XCTAssertNotNil(app.project?.importedFile, "really re-imported")
    }

    private func projectJSON(_ id: UUID) throws -> Data {
        try Data(contentsOf: root.appendingPathComponent(id.uuidString).appendingPathComponent("project.json"))
    }

    // MARK: a version never changes after it ran

    func testEditingAVersionWithResultsLeavesItAsItRanAndStartsADraft() throws {
        let (app, v1) = try optimizedCube()
        let before = try projectJSON(v1.id)
        try open(app, v1.id)
        app.project?.quality = .fine
        app.backHome()
        XCTAssertEqual(try projectJSON(v1.id), before, "v1's settings are the ones its results were made with")
        let part = try XCTUnwrap(app.library.index.part(containing: v1.id))
        XCTAssertEqual(part.versions.count, 2)
        let draft = try XCTUnwrap(part.versions.first { $0.folderID != v1.id })
        XCTAssertEqual(draft.number, 2)
        XCTAssertEqual(draft.parentNumber, 1)
        XCTAssertTrue(app.library.isDraft(draft))
        XCTAssertEqual(draft.changes.map(\.text), ["Resolution 64 → 128"])
        XCTAssertEqual(store.snapshot(id: draft.folderID)?.quality, .fine)
        XCTAssertTrue(store.hasPersistedResults(id: v1.id))
        XCTAssertFalse(store.hasPersistedResults(id: draft.folderID))
        // reopening v1 shows it as it ran, not the edit
        try open(app, v1.id)
        XCTAssertEqual(app.project?.quality, .fast)
    }

    func testSavingAgainUpdatesTheSameDraft() throws {
        let (app, v1) = try optimizedCube()
        try open(app, v1.id)
        app.project?.quality = .fine
        app.persistCurrentProject()
        app.project?.minimizePlastic = false
        app.backHome()
        let part = try XCTUnwrap(app.library.index.part(containing: v1.id))
        XCTAssertEqual(part.versions.count, 2, "one draft, never a pile")
        XCTAssertEqual(store.snapshot(id: part.versions[1].folderID)?.minimizePlastic, false)
    }

    func testOpeningAndLeavingWithoutAChangeMakesNoDraft() throws {
        let (app, v1) = try optimizedCube()
        try open(app, v1.id)
        app.backHome()
        XCTAssertEqual(app.library.index.part(containing: v1.id)?.versions.count, 1)
    }

    func testBeforeGroupingEditsSaveAsToday() throws {
        let (app, v1) = try optimizedCube(grouped: false)
        try open(app, v1.id)
        app.project?.quality = .fine
        app.backHome()
        XCTAssertEqual(store.snapshot(id: v1.id)?.quality, .fine, "today's behaviour until he taps Group")
        XCTAssertEqual(store.loadAll().readable.count, 1)
        XCTAssertFalse(app.library.makesNextVersion(of: v1.id))
    }

    // MARK: Optimize as vN

    func testOptimizeOnAVersionWithResultsAsksForTheNextVersion() throws {
        let (app, v1) = try optimizedCube()
        XCTAssertTrue(app.library.makesNextVersion(of: v1.id))
        try open(app, v1.id)
        app.project?.quality = .fine
        let preview = try XCTUnwrap(app.nextVersionPreview())
        XCTAssertEqual(preview.number, 2)
        XCTAssertEqual(preview.name, "Cube · v2 · res 128")
        XCTAssertEqual(preview.changes.map(\.text), ["Resolution 64 → 128"])
        XCTAssertEqual(preview.from, 1)
    }

    func testOptimizeAsNextVersionMakesTheDraftWithHisNameAndLeavesTheVersion() throws {
        let (app, v1) = try optimizedCube()
        let before = try projectJSON(v1.id)
        try open(app, v1.id)
        app.project?.quality = .fine
        let next = try XCTUnwrap(app.optimizeAsNextVersion(id: v1.id, name: "Cube · v2 · Fine pass"))
        XCTAssertNotEqual(next.id, v1.id)
        XCTAssertEqual(try projectJSON(v1.id), before)
        let v = try XCTUnwrap(app.library.version(next.id))
        XCTAssertEqual(v.number, 2)
        XCTAssertEqual(v.name, "Fine pass", "his own name, without the part and number")
        XCTAssertEqual(store.snapshot(id: next.id)?.quality, .fine)
        XCTAssertTrue(app.recentProjects.contains { $0.id == next.id })
    }

    func testKeepingTheAutomaticNameStoresNoName() throws {
        let (app, v1) = try optimizedCube()
        try open(app, v1.id)
        app.project?.quality = .fine
        let auto = try XCTUnwrap(app.nextVersionPreview()).name
        let next = try XCTUnwrap(app.optimizeAsNextVersion(id: v1.id, name: auto))
        XCTAssertNil(app.library.version(next.id)?.name)
    }

    func testTheSameSettingsStillMakeTheNextVersion() throws {
        let (app, v1) = try optimizedCube()
        try open(app, v1.id)
        let preview = try XCTUnwrap(app.nextVersionPreview())
        XCTAssertEqual(preview.name, "Cube · v2 · same settings")
        let next = try XCTUnwrap(app.optimizeAsNextVersion(id: v1.id, name: nil))
        XCTAssertEqual(app.library.version(next.id)?.number, 2)
    }

    // MARK: drafts and export

    func testTheOpenMenuListsDraftsNewestFirst() throws {
        let (app, v1) = try optimizedCube()
        try open(app, v1.id)
        app.project?.quality = .fine
        app.backHome()
        let d1 = try XCTUnwrap(app.duplicateProject(id: v1.id))
        app.library.refresh()
        let part = try XCTUnwrap(app.library.index.part(containing: v1.id))
        let drafts = app.library.drafts(of: part)
        XCTAssertEqual(drafts.count, 2)
        XCTAssertEqual(drafts.first?.folderID, d1.id)
        XCTAssertEqual(drafts.map(\.number), drafts.map(\.number).sorted(by: >))
    }

    /// His decision 11: optimizing an older version branches it (v1 → v1.1), the newest continues (v2 → v3).
    func testADraftOfAnOlderVersionBranchesAndOfTheNewestContinues() throws {
        let (app, v1) = try optimizedCube()
        // v2: a second optimized version on the main line
        let v2 = try XCTUnwrap(app.duplicateProject(id: v1.id))
        try store.saveResults(try XCTUnwrap(store.loadResultsData(id: v1.id)), id: v2.id)
        var s2 = try XCTUnwrap(store.snapshot(id: v2.id)); s2.optimized = true; try store.save(s2)
        app.library.refresh()
        XCTAssertEqual(app.library.version(v2.id)?.number, 2, "a grouped copy stays on the main line")

        try open(app, v1.id)
        app.project?.quality = .fine
        XCTAssertEqual(app.nextVersionPreview()?.number, VersionNumber("1.1"))
        XCTAssertEqual(app.nextVersionPreview()?.name, "Cube · v1.1 · res 128")
        app.backHome()
        let branch = try XCTUnwrap(app.library.index.part(containing: v1.id)?.versions.first { $0.number == VersionNumber("1.1") })
        XCTAssertEqual(branch.parentNumber, 1)

        try open(app, v2.id)
        app.project?.quality = .fine
        XCTAssertEqual(app.nextVersionPreview()?.number, 3, "the newest continues the main line")
    }

    func testExportFromACardIsAskedForOnce() {
        let id = UUID()
        XCTAssertNil(LibraryOpen.takeExport(for: id))
        LibraryOpen.exportOnOpen(id, result: 2)
        XCTAssertNil(LibraryOpen.takeExport(for: UUID()), "only for the version asked for")
        XCTAssertEqual(LibraryOpen.takeExport(for: id), 2)
        XCTAssertNil(LibraryOpen.takeExport(for: id), "once")
    }
}
