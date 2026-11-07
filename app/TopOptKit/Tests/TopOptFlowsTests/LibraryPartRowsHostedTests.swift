// LibraryPartRowsHostedTests — the Part folder. ★ His iPad notes 11-05 (ledger L1, his answers): "Make each version 1/3 that
// width, making it look like the rest of the Library with 3 versions per row … Each of the version's thumbnails should show
// smaller thumbnails of each version available - it is just meant to show you how many there are", his answer "On the card"
// (one line per result under the picture: "v2b · +10 % · 117 g · 8.7× ★★★ ⋯"), and "Make the cards as tall as required to
// ensure the card doesn't look too crowded". This replaces B5's one full-width row per version (mockup #lib-part).
//
// Each version is one card, newest first, 3 across (2 in portrait, as the project page): a draft first marked "Draft" with its
// Open, a branch right after the version it came from with "from v1" (no indent). A version with results shows them small,
// side by side, and one line each: name, weight · strength, stars, its ⋯, its flags. A small result's tap is Quick look of THAT
// result; a line's ⋯ holds Pick this · Print this · Reject · Export…; the version's ⋯ is app-map's list.
#if canImport(AppKit) && canImport(MetalKit)
import XCTest
import SwiftUI
import TopOptDesign
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

    func host(_ size: CGSize) throws -> (AppBuildHost, AppModel, [String: UUID]) {
        let (app, f) = try Self.arms(root: root.appendingPathComponent("\(Int(size.width))", isDirectory: true))
        let part = try XCTUnwrap(app.library.index.part(containing: try XCTUnwrap(f["2"])))
        XCTAssertEqual(part.versions.map(\.number.description).sorted(), ["1", "1.1", "2", "3"], "the fixture's four versions")
        app.library.route = .part(part.id)
        let h = AppBuildHost(AppBuildRoot(model: app), size: size, test: self)
        h.pump(3)
        return (h, app, f)
    }

    /// Reading order in the grid: an earlier row, or the same row further left.
    static func before(_ a: CGRect, _ b: CGRect) -> Bool {
        a.minY < b.minY - 0.5 || (abs(a.minY - b.minY) < 0.5 && a.minX < b.minX)
    }

    func testEachVersionIsACardAThirdWideNewestFirst() throws {
        for (name, size) in ParityTopologyShots.sizes {
            let (h, _, _) = try host(size)
            let portrait = size.height > size.width
            let v3 = try h.onScreen("library-version-v3", "\(name): v3, the draft, as a card")
            let v2 = try h.onScreen("library-version-v2", "\(name): v2 as a card")
            let v1 = try h.onScreen("library-version-v1", "\(name): v1 as a card")
            let b = try h.onScreen("library-version-v1.1", "\(name): ★ v1.1, the branch, as a card")
            let page = size.width - 2 * DS.Space.page
            for c in [v3, v2, v1, b] {
                XCTAssertEqual(c.width, v3.width, accuracy: 0.5, "\(name): one card width")
                XCTAssertLessThan(c.width, page / (portrait ? 1.9 : 2.9), "\(name): ★ a third of the width (half in portrait), not a full row")
            }
            if portrait {
                XCTAssertEqual(v3.minY, v2.minY, accuracy: 0.5, "\(name): ★ two across in portrait, as the project page")
                XCTAssertEqual(v1.minY, b.minY, accuracy: 0.5, "\(name): the next row")
                XCTAssertGreaterThan(v1.minY, v3.maxY, "\(name): the next row under the first")
                XCTAssertEqual(v1.minX, v3.minX, accuracy: 0.5, "\(name): the rows share one left edge")
            } else {
                for c in [v2, v1] { XCTAssertEqual(c.minY, v3.minY, accuracy: 0.5, "\(name): ★ three across, like the project page") }
                XCTAssertGreaterThan(b.minY, v3.maxY, "\(name): the fourth on the next row")
                XCTAssertEqual(b.minX, v3.minX, accuracy: 0.5, "\(name): ★ the branch has no indent: it follows its parent")
            }
            XCTAssertTrue(Self.before(v3, v2), "\(name): ★ a draft comes first")
            XCTAssertTrue(Self.before(v2, v1), "\(name): ★ newest first")
            XCTAssertTrue(Self.before(v1, b), "\(name): ★ a branch right after the version it came from")
            _ = try h.onScreen("library-version-v3-draft", "\(name): ★ the draft is marked Draft")
            _ = try h.onScreen("library-version-v3-open", "\(name): ★ a draft's card opens it")
            XCTAssertNotNil(h.frames.all["library-version-v1.1-from"], "\(name): ★ the branch says where it came from")
            XCTAssertNil(h.frames.all["library-result-v3a"], "\(name): a draft has no results to show")
        }
    }

    /// The results small (just how many), and one line each under them; as tall as it needs, nothing squeezed.
    func testAVersionShowsItsResultsSmallAndOneLineEachNeverCrowded() throws {
        for (name, size) in ParityTopologyShots.sizes {
            let (h, _, _) = try host(size)
            let v2 = try h.onScreen("library-version-v2", "\(name): v2")
            let minis = try ["a", "b", "c"].map { try h.onScreen("library-mini-v2\($0)", "\(name): ★ v2\($0) small in v2's picture") }
            let lines = try ["a", "b", "c"].map { try h.onScreen("library-result-v2\($0)", "\(name): ★ v2\($0)'s line") }
            for m in minis {
                XCTAssertTrue(v2.insetBy(dx: -0.5, dy: -0.5).contains(m), "\(name): in v2's card")
                XCTAssertEqual(m.minY, minis[0].minY, accuracy: 0.5, "\(name): ★ side by side")
                XCTAssertEqual(m.width, minis[0].width, accuracy: 1, "\(name): equal")
                XCTAssertLessThan(m.width, v2.width / 2.5, "\(name): ★ small: three fit across the card")
                XCTAssertGreaterThanOrEqual(m.height, 64, "\(name): big enough to see the shape")
            }
            XCTAssertLessThan(minis[0].maxX, minis[1].minX, "\(name): a, then b")
            XCTAssertLessThan(minis[1].maxX, minis[2].minX, "\(name): b, then c")
            for (i, l) in lines.enumerated() {
                XCTAssertTrue(v2.insetBy(dx: -0.5, dy: -0.5).contains(l), "\(name): v2's lines are in v2's card: \(l) in \(v2)")
                XCTAssertGreaterThan(l.minY, minis[0].maxY, "\(name): ★ under the picture")
                XCTAssertGreaterThanOrEqual(l.height, DSParts.target - 0.5, "\(name): ★ not crowded: each line a 44 pt row")
                if i > 0 { XCTAssertGreaterThanOrEqual(l.minY, lines[i - 1].maxY - 0.5, "\(name): ★ one under the other, never overlapping") }
            }
            XCTAssertGreaterThanOrEqual(v2.maxY - lines[2].maxY, 8, "\(name): ★ the card is as tall as it needs: room under its last line")
            let v1 = try h.onScreen("library-version-v1", "\(name): v1")
            if abs(v1.minY - v2.minY) < 0.5 { XCTAssertEqual(v1.height, v2.height, accuracy: 0.5, "\(name): cards in a row share one height") }
            _ = try h.onScreen("library-result-v2b-picked", "\(name): ★ the picked result wears Picked")
            XCTAssertNil(h.frames.all["library-result-v2a-picked"], "\(name): only the picked one")
            _ = try h.onScreen("library-result-v2b-stars", "\(name): each result has its stars")
            try h.probe("library-version-v2-menu", "\(name): v2's ⋯")
            try h.probe("library-result-v2b-menu", "\(name): v2b's ⋯")
            // the picture is drawn at its own shape: a small result is never a long thin strip
            XCTAssertLessThan(minis[0].width / minis[0].height, 1.8, "\(name): ★ not stretched into a band")
        }
    }

    func testASmallResultsTapIsQuickLookOfThatResult() throws {
        let (h, _, _) = try host(AppBuildHost.landscape13)
        let c = try h.onScreen("library-mini-v2c", "v2c, small")
        h.click(CGPoint(x: c.midX, y: c.midY), settle: 1.5)
        _ = try h.onScreen("libraryQuickLook-v2c", "★ a tap on v2c is Quick look of v2c — not the version's shown result (b)")
    }

    func testTheLineMenuPicksAndTheVersionMenuIsAppMapsList() throws {
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

    /// A draft's card opens it (today's ⋯ Open, as a button he can see).
    func testADraftsCardOpensIt() throws {
        let (h, app, f) = try host(AppBuildHost.landscape13)
        let open = try h.probe("library-version-v3-open", "v3's Open")
        h.click(CGPoint(x: open.midX, y: open.midY), settle: 2)
        XCTAssertEqual(app.project?.id, f["3"], "★ the draft opens")
    }
}
#endif
