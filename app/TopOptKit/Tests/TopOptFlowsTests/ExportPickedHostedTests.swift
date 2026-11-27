// ExportPickedHostedTests — B5 (ledger note 11, Q10, plan.md §B5, mockup #lib-project-export): Export chosen versions.
//
// His words: "We should then be able to export from the Project page only the chosen versions of any part selected and/or all
// parts in the project." Q10: "Allow for one stl per part or a 3mf for all parts - make a note that the original version will
// be exported for any part without a chosen version." His answers 11-04: "Choose parts…" ticks parts in the sheet's own list;
// a part whose chosen result has a lattice sends its chosen SOLID result, its line saying so.
//
// Plan §B5: 3 parts, one picked; the list says "the original goes out" for the other two; STL writes 3 files, and 3MF writes
// 1 file with 3 objects (parsed back). Every click is a real one through the window.
#if canImport(AppKit) && canImport(MetalKit)
import XCTest
import SwiftUI
@testable import TopOptFlows
@testable import TopOptKit

@MainActor
final class ExportPickedHostedTests: XCTestCase {
    private var root: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("topopt-export-picked-\(UUID().uuidString)", isDirectory: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    /// Lookalike results: result i is a mesh of i + 1 triangles, so each result's file says which one went out.
    private static func outcome() -> OptimizeOutcome {
        let tris: [Int32] = [0, 1, 2, 0, 1, 3, 0, 2, 3]
        return OptimizeOutcome(variants: (0..<3).map { i in
            OptimizeVariant(requestedVolumeFraction: 0.5, achievedVolumeFraction: 0.5, massGrams: 10 + Double(i),
                            supportVolumeVoxels: 0, meshTriangleCount: i + 1, worstCaseMargin: 2, accepted: true, v3Passes: true,
                            meshVertices: [0, 0, 0, 10, 0, 0, 0, 10, 0, 0, 0, 10], meshIndices: Array(tris.prefix(3 * (i + 1))))
        }, stoppedOnMargin: false, cancelled: false, acceptedCount: 3, voxelVolumeMM3: 1,
           gridNx: 2, gridNy: 2, gridNz: 2, gridOrigin: .zero, spacing: 1)
    }

    /// "Squish Mechanism": Carriage Arms optimized (its b chosen unless `pick` is false), Top motor mount and Electronics box
    /// never optimized. Lookalike boxes, never his models.
    private func host(_ size: CGSize = AppBuildHost.landscape13, pick: Bool = true, latticed: Bool = false)
        throws -> (AppBuildHost, AppModel, LibraryProject) {
        let dir = root.appendingPathComponent("\(Int(size.width))", isDirectory: true)
        let store = ProjectStore(rootDir: dir.appendingPathComponent("store", isDirectory: true))
        func part(_ name: String, _ s: SIMD3<Float>, results: Bool) throws {
            let src = dir.appendingPathComponent("import-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
            let model = src.appendingPathComponent("\(name).stl")
            try ParityLibraryShots.boxSTL(s).write(to: model, atomically: true, encoding: .utf8)
            var snap = ProjectSnapshot(id: UUID(), name: name, material: "PA12", process: .fdm, modelFileName: "model.stl",
                                       originalFileName: "\(name).stl", savedAt: Date(timeIntervalSince1970: 100),
                                       selection: SelectionModel(), force: ForceModel(), quality: .fast, optimized: results)
            if results && latticed { var l = LatticeSettings(); l.enabled = true; snap.lattice = l }
            try store.save(snap, modelSource: model)
            if results { try store.saveResults(try OutcomeCodec.encode(OutcomeCodec.dto(from: Self.outcome())), id: snap.id) }
        }
        try part("Carriage Arms", SIMD3(60, 30, 20), results: true)
        try part("Top motor mount", SIMD3(40, 40, 10), results: false)
        try part("Electronics box", SIMD3(50, 30, 25), results: false)
        let core = FlexibleHisProject.repoRoot.appendingPathComponent("core")
        let app = AppModel(materialsPath: core.appendingPathComponent("src/materials/materials.json").path, store: store)
        app.loadMaterials()
        app.library.refresh()
        _ = app.library.proposal()
        try app.library.group(projectName: "Squish Mechanism", partIDs: nil)
        let squish = try XCTUnwrap(app.library.index.projects.first)
        if pick, let arms = app.library.index.parts.first(where: { $0.name == "Carriage Arms" }) {
            app.library.pick(folder: arms.versions[0].folderID, result: 1)
        }
        app.library.route = .project(squish.id)
        let h = AppBuildHost(AppBuildRoot(model: app), size: size, test: self)
        h.pump(3)
        return (h, app, squish)
    }

    private func parts(_ app: AppModel, _ p: LibraryProject) -> [LibraryPart] {
        p.partIDs.compactMap { id in app.library.index.parts.first { $0.id == id } }
    }

    /// What each part sends, by name: its object's name, its line and its triangles (b = 2; a box = 12). The page's order is
    /// the grouping's (new folders' ids), so each test reads it from the project.
    private static let sends: [String: (object: String, what: String, triangles: Int)] = [
        "Carriage Arms": ("Carriage Arms · v1b", "v1b · picked", 2),
        "Top motor mount": ("Top motor mount · original", "no version picked · the original goes out", 12),
        "Electronics box": ("Electronics box · original", "no version picked · the original goes out", 12)]

    /// Wait (pumping) for the export's files.
    private func files(_ h: AppBuildHost, _ app: AppModel, _ what: String) throws -> [URL] {
        for _ in 0..<150 where app.library.exportedFiles.isEmpty { h.pump(0.1) }
        XCTAssertFalse(app.library.exporting, "\(what): the export finished")
        return try XCTUnwrap(app.library.exportedFiles.isEmpty ? nil : app.library.exportedFiles, "★ \(what): no files came out")
    }

    /// A binary STL's triangle count (its header is 80 bytes, then the count).
    private func triangles(_ url: URL) throws -> Int {
        let d = try Data(contentsOf: url)
        XCTAssertGreaterThanOrEqual(d.count, 84)
        return Int(d.subdata(in: 80..<84).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self).littleEndian })
    }

    /// Mockup #lib-project: Export beside + Add part, the note under the grid; both where he sees them at every size.
    func testExportIsInTheHeaderAndTheNoteIsUnderTheGrid() throws {
        for size in AppBuildHost.probeSizes {
            let (h, _, _) = try host(size)
            let export = try h.probe("libraryExport", "\(size): ★ the header's Export")
            XCTAssertEqual(export.height, DSParts.glassHeight, accuracy: 0.5, "\(size): §4's glass button, 48 pt")
            let add = try h.onScreen("libraryAddPart", "\(size): + Add part")
            XCTAssertLessThan(export.maxX, add.minX, "\(size): Export sits before + Add part (mockup #lib-project)")
            let note = try h.onScreen("libraryProjectNote", "\(size): ★ the note under the grid")
            let tile = try h.onScreen("libraryAddTile", "\(size): the grid's last tile")
            XCTAssertGreaterThan(note.minY, tile.maxY, "\(size): the note sits under the grid")
        }
        XCTAssertEqual(ProjectFolderView.note,
                       "A part with nothing picked shows its original model. A picked result gets the blue ring.",
                       "★ mockup #lib-project, word for word")
    }

    /// The list (Q10): the chosen result's line, and "the original goes out" for each part with nothing picked.
    func testTheListSaysWhatGoesOut() throws {
        let (h, app, squish) = try host()
        let order = parts(app, squish).map(\.name)
        XCTAssertEqual(Set(order), Set(Self.sends.keys))
        let lines = app.library.exportLines(parts(app, squish))
        XCTAssertEqual(lines.map(\.name), order, "the page's order")
        XCTAssertEqual(lines.map(\.what), order.map { Self.sends[$0]!.what }, "★ Q10: said in each line")
        XCTAssertEqual(lines.map(\.objectName), order.map { Self.sends[$0]!.object })
        XCTAssertEqual(ChosenExport.fileLine(lines, format: .stlPerPart, title: squish.name),
                       "3 files: " + order.map { "“\(Self.sends[$0]!.object).stl”" }.joined(separator: ", "),
                       "★ mockup #lib-project-export")
        XCTAssertEqual(ChosenExport.fileLine(lines, format: .oneThreeMF, title: squish.name),
                       "One file: “Squish Mechanism.3mf” with 3 parts")
        XCTAssertEqual(ChosenExport.fileLine(Array(lines.prefix(1)), format: .oneThreeMF, title: squish.name),
                       "One file: “Squish Mechanism.3mf” with 1 part")
        XCTAssertEqual(ChosenExport.fileLine([], format: .stlPerPart, title: squish.name), ChosenExport.noneTicked)
        // the sheet, with a real click on Export
        XCTAssertNil(h.frames.all["libraryExportSheet"], "closed until Export is tapped")
        try h.tap("libraryExport", "Export")
        _ = try h.onScreen("libraryExportSheet", "★ the Export chosen versions sheet")
        for n in ["Carriage Arms", "Top motor mount", "Electronics box"] {
            try h.probe("libraryExportLine-\(n)", "★ \(n)'s line in the list", minHit: 0)
            XCTAssertNil(h.frames.all["libraryExportTick-\(n)"], "All parts: no ticks")
        }
        try h.tap("libraryExportCancel", "Cancel")
        XCTAssertNil(h.frames.all["libraryExportSheet"], "★ Cancel closes it")
        XCTAssertTrue(app.library.exportedFiles.isEmpty, "Cancel sends nothing")
    }

    /// His answer 2 (11-04): a latticed chosen result sends its SOLID result, and its line says so.
    func testALatticedChoiceSendsItsSolidResultSaidInItsLine() throws {
        let (_, app, squish) = try host(latticed: true)
        let lines = app.library.exportLines(parts(app, squish))
        let arms = try XCTUnwrap(lines.first { $0.name == "Carriage Arms" })
        XCTAssertFalse(lines.contains { $0.name != "Carriage Arms" && $0.latticed }, "an original is never 'latticed'")
        XCTAssertTrue(arms.latticed, "the chosen version has a lattice")
        XCTAssertEqual(arms.what, "v1b · picked · the solid result; its lattice exports from its Lattice page", "★ said in its line")
        XCTAssertEqual(arms.objectName, "Carriage Arms · v1b")
    }

    /// Plan §B5: All parts, One STL per part → 3 files, the chosen result's and the two originals.
    func testAllPartsAsSTLWritesThreeFiles() throws {
        let (h, app, squish) = try host()
        let order = parts(app, squish).map(\.name)
        try h.tap("libraryExport", "Export")
        try h.tap("libraryExportGo", "the sheet's Export", settle: 0.3)
        let urls = try files(h, app, "STL per part")
        XCTAssertEqual(urls.map(\.lastPathComponent), order.map { Self.sends[$0]!.object + ".stl" }, "★ one STL per part")
        XCTAssertEqual(try urls.map(triangles), order.map { Self.sends[$0]!.triangles },
                       "★ the chosen b (2 triangles, never a nor c) and the original models (boxes)")
        XCTAssertNil(h.frames.all["libraryExportSheet"], "the sheet closes; the share sheet takes the files")
    }

    /// Plan §B5: All parts, One 3MF → 1 file with 3 named objects (parsed back), laid out apart.
    func testAllPartsAsOne3MFHoldsThreeObjects() throws {
        let (h, app, squish) = try host()
        let order = parts(app, squish).map(\.name)
        try h.tap("libraryExport", "Export")
        let fmt = try h.onScreen("libraryExportFormat", "Files: One STL per part │ One 3MF")
        h.click(CGPoint(x: fmt.maxX - 24, y: fmt.midY))
        try h.tap("libraryExportGo", "the sheet's Export", settle: 0.3)
        let urls = try files(h, app, "One 3MF")
        XCTAssertEqual(urls.map(\.lastPathComponent), ["Squish Mechanism.3mf"], "★ one file, named for the project")
        let objects = try XCTUnwrap(PartsThreeMF.read(try Data(contentsOf: urls[0])), "★ it reads back")
        XCTAssertEqual(objects.map(\.name), order.map { Self.sends[$0]!.object }, "★ one named object per part, the page's order")
        XCTAssertEqual(objects.map(\.triangleCount), order.map { Self.sends[$0]!.triangles }, "★ the chosen b and the two originals")
        for (a, b) in zip(objects, objects.dropFirst()) { XCTAssertLessThan(a.placedMax.x, b.placedMin.x, "no two overlap") }
    }

    /// His answer 1 (11-04): Choose parts… ticks parts in the sheet's own list. Nothing ticked sends nothing.
    func testChoosePartsTicksInTheSheetsList() throws {
        let (h, app, squish) = try host()
        let order = parts(app, squish).map(\.name)
        try h.tap("libraryExport", "Export")
        let sel = try h.onScreen("libraryExportParts", "Parts: All parts │ Choose parts…")
        h.click(CGPoint(x: sel.maxX - 24, y: sel.midY))
        for n in ["Carriage Arms", "Top motor mount", "Electronics box"] {
            _ = try h.onScreen("libraryExportTick-\(n)", "★ \(n)'s tick")
            XCTAssertNil(h.frames.all["libraryExportTick-\(n)-on"], "★ Choose starts with nothing ticked")
        }
        try h.tap("libraryExportGo", "Export with nothing ticked", settle: 0.5)
        XCTAssertTrue(app.library.exportedFiles.isEmpty, "★ nothing ticked: Export sends nothing")
        _ = try h.onScreen("libraryExportSheet", "the sheet stays up")
        for n in ["Carriage Arms", "Electronics box"] {
            try h.probe("libraryExportLine-\(n)", "★ \(n)'s line: a 44 pt tap that ticks it")
            try h.tap("libraryExportLine-\(n)", "tick \(n)")
            _ = try h.onScreen("libraryExportTick-\(n)-on", "★ \(n) ticked")
        }
        XCTAssertNil(h.frames.all["libraryExportTick-Top motor mount-on"], "the third stays unticked")
        let fmt = try h.onScreen("libraryExportFormat", "Files")
        h.click(CGPoint(x: fmt.maxX - 24, y: fmt.midY))
        try h.tap("libraryExportGo", "the sheet's Export", settle: 0.3)
        let urls = try files(h, app, "Choose parts → One 3MF")
        let objects = try XCTUnwrap(PartsThreeMF.read(try Data(contentsOf: urls[0])))
        XCTAssertEqual(objects.map(\.name), order.filter { $0 != "Top motor mount" }.map { Self.sends[$0]!.object },
                       "★ only the ticked parts, the page's order")
    }

    /// File names stay files: a slash or colon in a part's name becomes a dash; two parts of one name never overwrite.
    func testFileNamesAreSafeAndNeverCollide() {
        let a = UUID(), b = UUID(), f = UUID()
        let lines = [ChosenExportLine(partID: a, name: "Arm / left", tag: "v2a", folder: f, result: 0, latticed: false),
                     ChosenExportLine(partID: b, name: "Arm / left", tag: "v2a", folder: f, result: 0, latticed: false)]
        XCTAssertEqual(ChosenExport.fileNames(lines, format: .stlPerPart, title: "P"), ["Arm - left · v2a.stl", "Arm - left · v2a (2).stl"])
        XCTAssertEqual(ChosenExport.fileNames(lines, format: .oneThreeMF, title: "A: B"), ["A- B.3mf"])
    }
}
#endif
