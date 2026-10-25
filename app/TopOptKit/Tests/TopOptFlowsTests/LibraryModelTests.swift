// LibraryModelTests.swift — the Library screens' model (approved mockup 2026-10-25, batch 2).
//
// What the screens rely on: the Library asks before grouping (first launch: Group / Not now); an
// unreadable index shows today's flat Library and is never written; his marks (half stars, Print this,
// Rejected — no Favourite) persist; a new part joins the project he chose; result numbers and pictures
// come from each version's own results file; Storage trims an older version to the result he picked.

import XCTest
import simd
import TopOptKit
@testable import TopOptFlows

@MainActor
final class LibraryModelTests: XCTestCase {

    private var root: URL!
    private var store: ProjectStore!
    private let fm = FileManager.default

    override func setUpWithError() throws {
        root = fm.temporaryDirectory.appendingPathComponent("topopt-library-model-\(UUID().uuidString)", isDirectory: true)
        store = ProjectStore(rootDir: root)
    }
    override func tearDownWithError() throws {
        if let root { try? fm.removeItem(at: root) }
    }

    // MARK: fixtures

    /// One triangle per variant, so a results file has real meshes without being big.
    private func outcome(_ rungs: [(grams: Double, margin: Double, fraction: Double, accepted: Bool)]) -> OptimizeOutcome {
        let variants = rungs.enumerated().map { i, r in
            OptimizeVariant(requestedVolumeFraction: r.fraction, achievedVolumeFraction: r.fraction,
                            massGrams: r.grams, supportVolumeVoxels: 0, meshTriangleCount: 1,
                            worstCaseMargin: r.margin, accepted: r.accepted, v3Passes: r.accepted,
                            meshVertices: [0, 0, 0, 1 + Float(i), 0, 0, 0, 1, 0], meshIndices: [0, 1, 2])
        }
        return OptimizeOutcome(variants: variants, stoppedOnMargin: false, cancelled: false,
                               acceptedCount: rungs.filter(\.accepted).count, voxelVolumeMM3: 1,
                               gridNx: 2, gridNy: 2, gridNz: 2, gridOrigin: .zero, spacing: 1)
    }

    /// His three Carriage Arms copies: v1 and v2 optimized (3 results each), v3 never run.
    @discardableResult
    private func hisCopies() throws -> [ProjectSnapshot] {
        let bytes = Data("solid carriage arms".utf8)
        var out: [ProjectSnapshot] = []
        for (i, name) in ["Carriage Arms", "Carriage Arms copy", "Carriage Arms copy 2"].enumerated() {
            let src = root.appendingPathComponent("import-\(i)", isDirectory: true)
            try fm.createDirectory(at: src, withIntermediateDirectories: true)
            let model = src.appendingPathComponent("part.step")
            try bytes.write(to: model)
            let snap = ProjectSnapshot(id: UUID(), name: name, material: "PA12-CF", process: .fdm,
                                       modelFileName: "model.step", originalFileName: "Carriage Arms.step",
                                       savedAt: Date(timeIntervalSince1970: Double(i)), selection: SelectionModel(),
                                       force: ForceModel(), quality: .fast, optimized: i < 2 ? true : nil)
            try store.save(snap, modelSource: model)
            try fm.removeItem(at: src)
            if i < 2 {
                let o = outcome([(127.6, 6.95, 1.10, true), (120.0, 6.52, 1.03, true), (89.0, 4.58, 0.77, false)])
                try store.saveResults(try OutcomeCodec.encode(OutcomeCodec.dto(from: o)), id: snap.id)
                try store.saveRelatticeArtifacts(jobJSON: Data("{}".utf8), designBin: Data([1, 2, 3]), id: snap.id)
            }
            out.append(snap)
        }
        return out
    }

    private func grouped() throws -> (LibraryModel, LibraryPart) {
        try hisCopies()
        let lib = LibraryModel(store: store)
        lib.refresh()
        try lib.group(projectName: "Squish Mechanism", partIDs: nil)
        let part = try XCTUnwrap(lib.index.parts.first)
        return (lib, part)
    }

    // MARK: first launch

    func testWithProjectsAndNoIndexTheLibraryAsksBeforeGrouping() throws {
        try hisCopies()
        let lib = LibraryModel(store: store)
        lib.refresh()
        XCTAssertEqual(lib.mode, .flat, "today's Library until he taps Group")
        XCTAssertFalse(fm.fileExists(atPath: store.libraryURL.path), "nothing written before he says so")
        let proposal = lib.proposal()
        XCTAssertEqual(proposal.parts.count, 1)
        XCTAssertEqual(proposal.parts[0].versions.count, 3)

        try lib.group(projectName: "Squish Mechanism", partIDs: [proposal.parts[0].id])
        XCTAssertEqual(lib.mode, .library)
        XCTAssertEqual(lib.index.projects.map(\.name), ["Squish Mechanism"])
        XCTAssertEqual(lib.index.projects[0].partIDs, [lib.index.parts[0].id])
        XCTAssertEqual(store.loadLibrary(), lib.index)
    }

    func testNotNowKeepsTheFlatLibraryAndWritesNothing() throws {
        try hisCopies()
        let lib = LibraryModel(store: store)
        lib.refresh()
        lib.notNow()
        lib.refresh()
        XCTAssertEqual(lib.mode, .flat)
        XCTAssertFalse(fm.fileExists(atPath: store.libraryURL.path))
    }

    func testAnEmptyLibraryStartsGroupedWithoutAsking() {
        let lib = LibraryModel(store: store)
        lib.refresh()
        XCTAssertEqual(lib.mode, .library, "nothing to review: a new install goes straight to the Library")
    }

    func testAnUnreadableIndexShowsTheFlatLibraryAndIsNeverWritten() throws {
        try hisCopies()
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let junk = Data("{ not json".utf8)
        try junk.write(to: store.libraryURL)
        let lib = LibraryModel(store: store)
        lib.refresh()
        guard case .unreadable = lib.mode else { return XCTFail("\(lib.mode)") }
        XCTAssertThrowsError(try lib.group(projectName: nil, partIDs: nil))
        XCTAssertEqual(try Data(contentsOf: store.libraryURL), junk)
    }

    func testUngroupGoesBackToTheFlatLibraryAndRemovesOnlyTheLibrarysFiles() throws {
        let (lib, part) = try grouped()
        _ = part
        lib.ungroup()
        XCTAssertEqual(lib.mode, .flat)
        XCTAssertFalse(fm.fileExists(atPath: store.libraryURL.path))
        XCTAssertFalse(fm.fileExists(atPath: lib.cacheDir.path), "the pictures cache goes too")
        XCTAssertEqual(store.loadAll().readable.count, 3)
    }

    // MARK: marks

    func testStarsPrintAndRejectPersistPerResult() throws {
        let (lib, part) = try grouped()
        let v1 = part.versions[0].folderID
        lib.setStars(4.5, folder: v1, result: 1)
        lib.togglePrint(folder: v1, result: 1)
        lib.toggleReject(folder: v1, result: 2)
        let again = LibraryModel(store: store)
        again.refresh()
        let v = try XCTUnwrap(again.version(v1))
        XCTAssertEqual(v.mark(for: 1), ResultMark(result: 1, stars: 4.5, printThis: true))
        XCTAssertTrue(v.mark(for: 2).rejected)
        XCTAssertTrue(v.mark(for: 0).isEmpty)
    }

    func testRejectingAResultTakesItOffThePrintListAndBack() throws {
        let (lib, part) = try grouped()
        let v1 = part.versions[0].folderID
        lib.togglePrint(folder: v1, result: 0)
        lib.toggleReject(folder: v1, result: 0)
        XCTAssertEqual(lib.version(v1)?.mark(for: 0), ResultMark(result: 0, rejected: true), "a rejected result is not for print")
        lib.togglePrint(folder: v1, result: 0)
        XCTAssertEqual(lib.version(v1)?.mark(for: 0), ResultMark(result: 0, printThis: true))
    }

    func testTappingTheSameStarAgainClearsIt() throws {
        let (lib, part) = try grouped()
        let v1 = part.versions[0].folderID
        lib.setStars(3, folder: v1, result: 0)
        lib.setStars(3, folder: v1, result: 0)
        XCTAssertEqual(lib.version(v1)?.mark(for: 0).stars, 0)
    }

    // MARK: results, numbers and the suggested result

    func testSummariesComeFromEachVersionsOwnResultsFile() throws {
        let (lib, part) = try grouped()
        let exp = expectation(description: "summaries")
        lib.loadSummaries { exp.fulfill() }
        wait(for: [exp], timeout: 10)
        let v1 = try XCTUnwrap(lib.version(part.versions[0].folderID))
        XCTAssertEqual(v1.summary?.map(\.massGrams), [127.6, 120.0, 89.0])
        XCTAssertEqual(v1.summary?.map(\.accepted), [true, true, false])
        XCTAssertNil(lib.version(part.versions[2].folderID)?.summary, "a draft has no results")
        XCTAssertEqual(lib.suggestedResult(v1), 1, "the last result that passes (the Results screen's own rule)")
        XCTAssertEqual(lib.shownResult(v1), 1)
        lib.pick(folder: v1.folderID, result: 0)
        XCTAssertEqual(lib.shownResult(lib.version(v1.folderID)!), 0)
        XCTAssertEqual(store.loadLibrary()?.parts[0].versions[0].summary?.count, 3, "kept, so a card never reads 20 MB again")
    }

    func testLoadingResultsGivesEveryVariantsMesh() throws {
        let (lib, part) = try grouped()
        let exp = expectation(description: "results")
        var got: [LibraryResult]?
        lib.results(for: part.versions[0].folderID) { got = $0; exp.fulfill() }
        wait(for: [exp], timeout: 10)
        XCTAssertEqual(got?.count, 3)
        XCTAssertEqual(got?.map(\.index), [0, 1, 2])
        XCTAssertEqual(got?[1].mesh.indices, [0, 1, 2])
        XCTAssertEqual(got?.map { Int(($0.fraction * 100).rounded()) }, [110, 103, 77])
    }

    // MARK: projects and parts

    func testANewPartJoinsTheProjectHeChose() throws {
        let (lib, _) = try grouped()
        let project = lib.index.projects[0].id
        let src = root.appendingPathComponent("lid", isDirectory: true)
        try fm.createDirectory(at: src, withIntermediateDirectories: true)
        try Data("solid lid".utf8).write(to: src.appendingPathComponent("lid.stl"))
        let lid = ProjectSnapshot(id: UUID(), name: "Carriage Lid", material: "PA12-CF", process: .fdm,
                                  modelFileName: "model.stl", originalFileName: "lid.stl", savedAt: Date(),
                                  selection: SelectionModel(), force: ForceModel())
        lib.importTargetProject = project
        try store.save(lid, modelSource: src.appendingPathComponent("lid.stl"))
        lib.refresh()
        let part = try XCTUnwrap(lib.index.part(containing: lid.id))
        XCTAssertEqual(part.name, "Carriage Lid")
        XCTAssertTrue(lib.index.projects[0].partIDs.contains(part.id))
        XCTAssertNil(lib.importTargetProject, "used once")
    }

    func testTheSameModelImportedAgainIsTheNextVersionNotANewPart() throws {
        let (lib, part) = try grouped()
        let again = try store.duplicate(id: part.versions[0].folderID, name: "Carriage Arms copy 3", now: Date())
        lib.refresh()
        XCTAssertEqual(lib.index.parts.count, 1)
        XCTAssertEqual(lib.index.part(containing: again.id)?.version(folderID: again.id)?.number, 4)
    }

    func testNewProjectRenameAndMoveAPart() throws {
        let (lib, part) = try grouped()
        let rig = lib.newProject(name: "Squish test rig")
        lib.move(part: part.id, to: rig)
        XCTAssertEqual(lib.index.projects.first { $0.id == rig }?.partIDs, [part.id])
        XCTAssertFalse(lib.index.projects[0].partIDs.contains(part.id), "a part is in one project")
        lib.move(part: part.id, to: nil)
        XCTAssertEqual(lib.index.unfiledParts.map(\.id), [part.id])
        lib.rename(part: part.id, to: "Arms")
        lib.rename(project: rig, to: "Rig")
        lib.rename(version: part.versions[1].folderID, to: "Print candidate")
        let again = LibraryModel(store: store)
        again.refresh()
        XCTAssertEqual(again.index.parts[0].name, "Arms")
        XCTAssertEqual(again.index.projects.first { $0.id == rig }?.name, "Rig")
        XCTAssertEqual(again.version(part.versions[1].folderID)?.name, "Print candidate")
        lib.rename(version: part.versions[1].folderID, to: "  ")
        XCTAssertNil(lib.version(part.versions[1].folderID)?.name, "a blank name means the automatic one")
    }

    func testTheAutomaticTitleIsTheNamingRule() throws {
        let (lib, part) = try grouped()
        XCTAssertEqual(lib.title(of: part.versions[0], in: part), "Carriage Arms · v1 · first run · res 64")
        XCTAssertEqual(lib.title(of: part.versions[1], in: part), "Carriage Arms · v2 · same settings")
    }

    // MARK: Storage

    func testStorageKeepsRatedPrintAndTheNewestTwo() throws {
        let (lib, part) = try grouped()
        let v1 = part.versions[0].folderID
        XCTAssertTrue(lib.keepsAllResults(v1), "v1 and v2 are the newest 2 with results")
        // two newer optimized versions push v1 out of the newest 2
        for n in 0..<2 {
            let copy = try store.duplicate(id: part.versions[1].folderID, name: "Carriage Arms copy \(9 + n)", now: Date())
            try store.saveResults(try XCTUnwrap(store.loadResultsData(id: part.versions[1].folderID)), id: copy.id)
            var s = try XCTUnwrap(store.snapshot(id: copy.id)); s.optimized = true; try store.save(s)
        }
        lib.refresh()
        XCTAssertFalse(lib.keepsAllResults(v1), "v1 is neither rated nor among the newest 2 with results")
        lib.setStars(4, folder: v1, result: 0)
        XCTAssertTrue(lib.keepsAllResults(v1))
        lib.setStars(4, folder: v1, result: 0)
        lib.togglePrint(folder: v1, result: 2)
        XCTAssertTrue(lib.keepsAllResults(v1))
        let newest = try XCTUnwrap(lib.index.parts[0].versions.max { $0.number < $1.number }).folderID
        XCTAssertTrue(lib.keepsAllResults(newest), "the newest")
        XCTAssertGreaterThan(lib.resultsBytes(v1), 0)
    }

    func testTrimKeepsOnlyThePickedResultAndMovesHisMarksWithIt() throws {
        let (lib, part) = try grouped()
        let v1 = part.versions[0].folderID
        lib.pick(folder: v1, result: 1)
        lib.setStars(3.5, folder: v1, result: 1)
        lib.toggleReject(folder: v1, result: 2)
        try lib.trim(folder: v1)
        let o = try OutcomeCodec.decode(try XCTUnwrap(store.loadResultsData(id: v1)))
        XCTAssertEqual(o.variants.map(\.massGrams), [120.0])
        XCTAssertEqual(o.acceptedCount, 1)
        let v = try XCTUnwrap(lib.version(v1))
        XCTAssertEqual(v.pickedResult, 0)
        XCTAssertEqual(v.marks, [ResultMark(result: 0, stars: 3.5)], "the picked result's marks follow it")
        XCTAssertEqual(v.summary?.map(\.massGrams), [120.0])
        XCTAssertTrue(v.trimmed == true)
        let art = try XCTUnwrap(store.loadRelatticeArtifacts(id: v1), "the run's job stays: smoothing still works")
        XCTAssertTrue(art.designBin.isEmpty, "the design of 3 results no longer matches 1, so it goes")
        XCTAssertEqual(store.snapshot(id: v1)?.optimized, true)
    }
}
