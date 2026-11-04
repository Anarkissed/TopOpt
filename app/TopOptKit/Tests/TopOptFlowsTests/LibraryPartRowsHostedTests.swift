// LibraryPartRowsHostedTests — B5 (his "look per screen"): the Part folder is mockup v5's #lib-part. Each version is one §4.7
// version card (DSVersionCard), newest first: a draft on top marked "Draft", a branch 48 pt in under the version it came from
// with "from v1". A version with results shows its a · b · c inline — picture, "v2b · +10 %", weight · strength, stars, and the
// "Picked" ring on the one picked. A tile tap is Quick look of THAT result; the tile's ⋯ holds Pick this · Print this · Reject ·
// Export…; the version's ⋯ is app-map's list.
#if canImport(AppKit) && canImport(MetalKit)
import XCTest
import SwiftUI
@testable import TopOptFlows
@testable import TopOptKit

@MainActor
final class LibraryPartRowsHostedTests: XCTestCase {
    private var root: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("topopt-lib-rows-\(UUID().uuidString)", isDirectory: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    /// Carriage Arms in four versions, like #lib-part: v1 and v2 with three results each (v2 picked b), v3 a draft, v1.1 a branch
    /// from v1, in "Squish Mechanism". One lookalike box (never his model), so every save is a version of the same part.
    static func arms(root: URL) throws -> (app: AppModel, folders: [String: UUID]) {
        let store = ProjectStore(rootDir: root.appendingPathComponent("store", isDirectory: true))
        let src = root.appendingPathComponent("import", isDirectory: true)
        try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
        let model = src.appendingPathComponent("Carriage Arms.stl")
        try ParityLibraryShots.boxSTL(SIMD3(60, 30, 20)).write(to: model, atomically: true, encoding: .utf8)
        func save(_ t: Double, results: Bool) throws -> UUID {
            let snap = ProjectSnapshot(id: UUID(), name: "Carriage Arms", material: "PA12", process: .fdm, modelFileName: "model.stl",
                                       originalFileName: "Carriage Arms.stl", savedAt: Date(timeIntervalSince1970: t),
                                       selection: SelectionModel(), force: ForceModel(), quality: .fast, optimized: results)
            try store.save(snap, modelSource: model)
            if results { try store.saveResults(try OutcomeCodec.encode(OutcomeCodec.dto(from: AppBuildFixtures.outcome())), id: snap.id) }
            return snap.id
        }
        var f: [String: UUID] = [:]
        f["1"] = try save(100, results: true)
        f["2"] = try save(200, results: true)
        f["3"] = try save(300, results: false)
        let core = FlexibleHisProject.repoRoot.appendingPathComponent("core")
        let app = AppModel(materialsPath: core.appendingPathComponent("src/materials/materials.json").path, store: store)
        app.loadMaterials()
        app.library.refresh()
        _ = app.library.proposal()
        try app.library.group(projectName: "Squish Mechanism", partIDs: nil)
        let branch = try save(400, results: true)
        app.library.noteParent(try XCTUnwrap(f["1"]), of: branch)
        app.library.refresh()
        f["1.1"] = branch
        app.library.pick(folder: try XCTUnwrap(f["2"]), result: 1)
        return (app, f)
    }

    private func host(_ size: CGSize) throws -> (AppBuildHost, AppModel, [String: UUID]) {
        let (app, f) = try Self.arms(root: root.appendingPathComponent("\(Int(size.width))", isDirectory: true))
        let part = try XCTUnwrap(app.library.index.part(containing: try XCTUnwrap(f["2"])))
        XCTAssertEqual(part.versions.map(\.number.description).sorted(), ["1", "1.1", "2", "3"], "the fixture's four versions")
        app.library.route = .part(part.id)
        let h = AppBuildHost(AppBuildRoot(model: app), size: size, test: self)
        h.pump(3)
        return (h, app, f)
    }

    func testEachVersionIsOneRowNewestFirstWithItsResultsInline() throws {
        for (name, size) in ParityTopologyShots.sizes {
            let (h, _, _) = try host(size)
            let v3 = try h.onScreen("library-version-v3", "\(name): v3, the draft, as a row")
            let v2 = try h.onScreen("library-version-v2", "\(name): v2 as a row")
            let v1 = try h.onScreen("library-version-v1", "\(name): v1 as a row")
            let b = try XCTUnwrap(h.frames.all["library-version-v1.1"], "\(name): ★ v1.1, the branch, as a row")
            XCTAssertLessThan(v3.minY, v2.minY, "\(name): ★ a draft sits on top")
            XCTAssertLessThan(v2.minY, v1.minY, "\(name): ★ newest first")
            XCTAssertLessThan(v1.minY, b.minY, "\(name): ★ a branch sits right under the version it came from")
            for f in [v2, v1] {
                XCTAssertEqual(f.minX, v3.minX, accuracy: 0.5, "\(name): the rows share one left edge")
                XCTAssertEqual(f.maxX, v3.maxX, accuracy: 0.5, "\(name): one width — rows, not a grid of cards")
            }
            XCTAssertEqual(b.minX, v1.minX + DSCards.branchIndent, accuracy: 0.5, "\(name): ★ the branch sits 48 pt in")
            XCTAssertEqual(b.maxX, v1.maxX, accuracy: 0.5, "\(name): the branch keeps the right edge")
            _ = try h.onScreen("library-version-v3-draft", "\(name): ★ the draft is marked Draft")
            XCTAssertNotNil(h.frames.all["library-version-v1.1-from"], "\(name): ★ the branch says where it came from")
            XCTAssertNil(h.frames.all["library-result-v3a"], "\(name): a draft has no results to show")
            let tiles = try ["a", "b", "c"].map { try h.onScreen("library-result-v2\($0)", "\(name): ★ v2\($0) inline in v2's row") }
            for t in tiles {
                XCTAssertTrue(v2.insetBy(dx: -0.5, dy: -0.5).contains(t), "\(name): v2's results sit inside v2's row: \(t) in \(v2)")
                XCTAssertEqual(t.minY, tiles[0].minY, accuracy: 0.5, "\(name): ★ a · b · c side by side")
                XCTAssertEqual(t.width, tiles[0].width, accuracy: 1, "\(name): three equal tiles")
            }
            XCTAssertLessThan(tiles[0].maxX, tiles[1].minX, "\(name): a, then b")
            XCTAssertLessThan(tiles[1].maxX, tiles[2].minX, "\(name): b, then c")
            XCTAssertNotNil(h.frames.all["library-result-v1a"], "\(name): ★ every version with results shows them (app-map: each card has 3)")
            _ = try h.onScreen("library-result-v2b-picked", "\(name): ★ the picked result wears Picked")
            XCTAssertNil(h.frames.all["library-result-v2a-picked"], "\(name): only the picked one")
            _ = try h.onScreen("library-result-v2b-stars", "\(name): each result has its stars")
            try h.probe("library-version-v2-menu", "\(name): v2's ⋯")
            try h.probe("library-result-v2b-menu", "\(name): v2b's ⋯")
        }
    }

    func testATileTapIsQuickLookOfThatResult() throws {
        let (h, _, _) = try host(AppBuildHost.landscape13)
        let c = try h.onScreen("library-result-v2c", "v2c's tile")
        h.click(CGPoint(x: c.midX, y: c.minY + 30), settle: 1.5)
        _ = try h.onScreen("libraryQuickLook-v2c", "★ a tap on v2c is Quick look of v2c — not the version's shown result (b)")
    }

    func testTheTileMenuPicksAndTheVersionMenuIsAppMapsList() throws {
        let (h, app, f) = try host(AppBuildHost.landscape13)
        let tile = try h.pickFromMenu("library-result-v1c-menu", "Pick this", what: "v1c's ⋯")
        XCTAssertEqual(tile, ["Pick this", "Print this", "Reject", "Export…"], "★ a result's own ⋯")
        let part = try XCTUnwrap(app.library.index.part(containing: try XCTUnwrap(f["1"])))
        XCTAssertEqual(app.library.chosen(of: part), LibraryChosen(folder: try XCTUnwrap(f["1"]), result: 2),
                       "★ Pick this on v1c makes v1c the part's chosen result")
        h.pump(1)
        _ = try h.onScreen("library-result-v1c-picked", "v1c now wears Picked")
        XCTAssertNil(h.frames.all["library-result-v2b-picked"], "★ one chosen per part: v2b is no longer picked")
        let version = try h.pickFromMenu("library-version-v1-menu", "Quick look", what: "v1's ⋯")
        XCTAssertEqual(version, ["Quick look", "Compare its results", "Export…", "Open v1", "New draft from v1", "Rename…", "Delete v1…"],
                       "★ app-map's version ⋯")
        _ = try h.onScreen("libraryQuickLook-v1c", "Quick look from the version's ⋯ shows its chosen result")
    }
}
#endif
