// CardShowsOriginalHostedTests — B1, ledger note 10 (approved design 2026-11-02).
//
// His words: "If a part has not been optimized yet, the preview doesn't show anything … unless an optimized version has been
// absolutely chosen, the original model should be the preview." The rule: the card shows the result he PICKED; with none
// picked, the original model; a running version never blanks it.
//
// Lookalike parts only (the repo's 10 mm cube and 10 mm sphere), in a temporary store; the Library is drawn for real and the card's picture
// is found by its frame (it publishes one only while a picture is drawn).
#if canImport(AppKit) && canImport(MetalKit)
import XCTest
import SwiftUI
@testable import TopOptFlows
@testable import TopOptKit

@MainActor
final class CardShowsOriginalHostedTests: XCTestCase {
    private var root: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("topopt-b1-cards-\(UUID().uuidString)", isDirectory: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    /// A part named `name` from `fixture` (a repo STL), PLA, never optimized (or with three results, none picked).
    private func part(_ store: ProjectStore, _ name: String, _ fixture: String, results: Bool = false) throws -> UUID {
        let src = root.appendingPathComponent("import-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
        let model = src.appendingPathComponent("\(name).stl")
        try FileManager.default.copyItem(at: FlexibleHisProject.repoRoot.appendingPathComponent("core/tests/fixtures/stl/\(fixture)"), to: model)
        let snap = ProjectSnapshot(id: UUID(), name: name, material: "PLA", process: .fdm, modelFileName: "model.stl",
                                   originalFileName: "\(name).stl", savedAt: Date(timeIntervalSince1970: 100),
                                   selection: SelectionModel(), force: ForceModel(), quality: .fast, optimized: results)
        try store.save(snap, modelSource: model)
        if results { try store.saveResults(try OutcomeCodec.encode(OutcomeCodec.dto(from: AppBuildFixtures.outcome())), id: snap.id) }
        return snap.id
    }

    func testAPartNeverOptimizedShowsItsOriginalModelAndAResultNeedsAPick() throws {
        let store = ProjectStore(rootDir: root)
        _ = try part(store, "Top motor mount", "cube_10mm.stl")
        let ran = try part(store, "2040 Extrusion Stand", "sphere_r10mm.stl", results: true)   // a different model: a part of its own
        let core = FlexibleHisProject.repoRoot.appendingPathComponent("core")
        let app = AppModel(materialsPath: core.appendingPathComponent("src/materials/materials.json").path, store: store)
        app.loadMaterials()
        app.library.refresh()
        try app.library.group(projectName: "Bracket tests", partIDs: nil)
        let project = try XCTUnwrap(app.library.index.projects.first)
        app.library.route = .project(project.id)   // the folder he opens (navigation is not what is tested)

        let h = AppBuildHost(AppBuildRoot(model: app), size: AppBuildHost.landscape13, test: self)
        let end = Date().addingTimeInterval(15)
        while Date() < end, h.frames.all["libraryPartPicture-Top motor mount"] == nil || h.frames.all["libraryPartPicture-2040 Extrusion Stand"] == nil { h.pump(0.2) }

        // ★ never optimized: its card shows the original model
        _ = try h.onScreen("libraryPartPicture-Top motor mount", "★ the never-optimized part's picture (its original model)")
        // ★ optimized, nothing picked: the original too, not a result he never chose
        _ = try h.onScreen("libraryPartPicture-2040 Extrusion Stand", "the optimized part's picture")
        let stand = try XCTUnwrap(app.library.index.part(containing: ran))
        XCTAssertNotNil(app.library.originalPicture(stand))
        XCTAssertTrue(app.library.partPicture(stand) === app.library.originalPicture(stand), "★ with no pick, the original model")
    }
}
#endif
