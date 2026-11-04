// LibraryProjectCardsHostedTests — B5 (his "look per screen"): the Project folder is mockup v5's #lib-project on §4's parts.
// Each part is a §4.7 part card (DSPartCard: a 200 pt picture, its name, "PA12 · not optimized yet", its version strip) with
// app-map's ⋯ (Rename · Move to · Delete part) where he can see it; the last tile is §4.7's dashed "+ Add part"; the header's
// "+ Add part" is §4's glass button in the accent. (The ring and "v7b" tag wait on the reviewer's ruling on "chosen".)
#if canImport(AppKit) && canImport(MetalKit)
import XCTest
import SwiftUI
@testable import TopOptFlows
@testable import TopOptKit

@MainActor
final class LibraryProjectCardsHostedTests: XCTestCase {
    private var root: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("topopt-lib-cards-\(UUID().uuidString)", isDirectory: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    /// "Squish Mechanism": Carriage Arms with results, Top motor mount and Electronics box never optimized. Lookalike boxes.
    private func host(_ size: CGSize) throws -> (AppBuildHost, AppModel, UUID) {
        let dir = root.appendingPathComponent("\(Int(size.width))", isDirectory: true)
        let store = ProjectStore(rootDir: dir.appendingPathComponent("store", isDirectory: true))
        func part(_ name: String, _ s: SIMD3<Float>, results: Bool) throws -> UUID {
            let src = dir.appendingPathComponent("import-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
            let model = src.appendingPathComponent("\(name).stl")
            try ParityLibraryShots.boxSTL(s).write(to: model, atomically: true, encoding: .utf8)
            let snap = ProjectSnapshot(id: UUID(), name: name, material: "PA12", process: .fdm, modelFileName: "model.stl",
                                       originalFileName: "\(name).stl", savedAt: Date(timeIntervalSince1970: 100),
                                       selection: SelectionModel(), force: ForceModel(), quality: .fast, optimized: results)
            try store.save(snap, modelSource: model)
            if results { try store.saveResults(try OutcomeCodec.encode(OutcomeCodec.dto(from: AppBuildFixtures.outcome())), id: snap.id) }
            return snap.id
        }
        _ = try part("Carriage Arms", SIMD3(60, 30, 20), results: true)
        _ = try part("Top motor mount", SIMD3(40, 40, 10), results: false)
        _ = try part("Electronics box", SIMD3(50, 30, 25), results: false)
        let core = FlexibleHisProject.repoRoot.appendingPathComponent("core")
        let app = AppModel(materialsPath: core.appendingPathComponent("src/materials/materials.json").path, store: store)
        app.loadMaterials()
        app.library.refresh()
        _ = app.library.proposal()
        try app.library.group(projectName: "Squish Mechanism", partIDs: nil)
        let squish = try XCTUnwrap(app.library.index.projects.first)
        app.library.route = .project(squish.id)
        let h = AppBuildHost(AppBuildRoot(model: app), size: size, test: self)
        h.pump(3)
        return (h, app, squish.id)
    }

    func testEachPartIsTheCardAndAddPartIsTheTileAndTheAccentButton() throws {
        for (name, size) in ParityTopologyShots.sizes {
            let (h, _, _) = try host(size)
            let cards = try ["Carriage Arms", "Top motor mount", "Electronics box"].map { n -> CGRect in
                let f = try XCTUnwrap(h.frames.all["libraryPart-\(n)"], "\(name): \(n)'s card")
                XCTAssertNotNil(h.frames.all["libraryPart-\(n)-versions"], "\(name): ★ \(n) is §4.7's part card (its version strip)")
                return f
            }
            for c in cards {
                XCTAssertEqual(c.width, cards[0].width, accuracy: 1, "\(name): one card width")
                XCTAssertEqual(c.height, cards[0].height, accuracy: 1, "\(name): one card height")
            }
            XCTAssertLessThan(cards[0].height, 330, "\(name): ★ the mockup's card (a 200 pt picture), not the old 230 pt one")
            // mockup .grid: 3 across in landscape, 2 in portrait (the parts' order is the grouping's, not asserted)
            let rows = Dictionary(grouping: cards) { Int($0.minY.rounded()) }.values.map(\.count).sorted(by: >)
            XCTAssertEqual(rows, size.width > size.height ? [3] : [2, 1], "\(name): ★ 3 across in landscape, 2 in portrait")
            let tile = try XCTUnwrap(h.frames.all["libraryAddTile"], "\(name): ★ the dashed + Add part tile")
            XCTAssertGreaterThanOrEqual(tile.height, DSCards.addMinHeight - 0.5, "\(name): the add tile's height")
            XCTAssertEqual(tile.width, cards[0].width, accuracy: 1, "\(name): the tile is one of the grid's cells")
            let add = try h.probe("libraryAddPart", "\(name): the header's + Add part")
            XCTAssertEqual(add.height, DSParts.glassHeight, accuracy: 0.5, "\(name): ★ §4's glass button (accent), 48 pt")
            try h.probe("libraryPart-Carriage Arms-menu", "\(name): ★ app-map's ⋯ on each card, where he sees it")
        }
    }

    func testTheCardMenuIsAppMapsListAndTheTileAddsAPartHere() throws {
        let (h, app, squish) = try host(AppBuildHost.landscape13)
        let offered = try h.pickFromMenu("libraryPart-Carriage Arms-menu", "(none)", what: "Carriage Arms' ⋯")
        XCTAssertEqual(offered, ["Rename…", "Move to", "Delete part…"], "★ app-map: Rename · Move to · Delete part")
        let tile = try h.onScreen("libraryAddTile", "the + Add part tile")
        h.click(CGPoint(x: tile.midX, y: tile.midY), settle: 1)
        XCTAssertEqual(app.library.importTargetProject, squish, "★ the tile adds a part to THIS project")
    }

    func testTheCardLine() {
        XCTAssertEqual(LibraryPartCard.line(material: "PA12", optimized: false), "PA12 · not optimized yet", "★ mockup #lib-project")
        XCTAssertEqual(LibraryPartCard.line(material: "PA12", optimized: true), "PA12")
    }
}
#endif
