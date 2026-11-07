// LibraryChosenResultTests — his answer (11-03, via the reviewer 11-04 02:44Z and 18:56Z): ONE chosen result per PART
// (version + result), set by Results' Pick this or a result tile's Pick this; the latest pick replaces the last. It drives
// the ring, the "v7b" tag, "PA12 · picked v7b", the card picture and the strip accent (note 11). Print this stays its own
// mark (several allowed). Old per-version picks are not migrated: no part has a chosen until he picks one, and with none
// the picture is the original model (note 10).

import XCTest
import CoreGraphics
import TopOptKit
@testable import TopOptFlows

@MainActor
final class LibraryChosenResultTests: XCTestCase {
    private var root: URL!
    private var store: ProjectStore!
    private let fm = FileManager.default

    override func setUpWithError() throws {
        root = fm.temporaryDirectory.appendingPathComponent("topopt-lib-chosen-\(UUID().uuidString)", isDirectory: true)
        store = ProjectStore(rootDir: root)
    }
    override func tearDownWithError() throws { if let root { try? fm.removeItem(at: root) } }

    // MARK: fixtures

    /// His Carriage Arms: v1 and v2 optimized (3 results each, one triangle per result), v3 a draft.
    private func carriageArms() throws -> (LibraryModel, LibraryPart) {
        for i in 0..<3 {
            let src = root.appendingPathComponent("import-\(i)", isDirectory: true)
            try fm.createDirectory(at: src, withIntermediateDirectories: true)
            let model = src.appendingPathComponent("part.step")
            try Data("solid carriage arms".utf8).write(to: model)
            let snap = ProjectSnapshot(id: UUID(), name: "Carriage Arms", material: "PA12", process: .fdm,
                                       modelFileName: "model.step", originalFileName: "Carriage Arms.step",
                                       savedAt: Date(timeIntervalSince1970: Double(i)), selection: SelectionModel(),
                                       force: ForceModel(), quality: .fast, optimized: i < 2 ? true : nil)
            try store.save(snap, modelSource: model)
            try fm.removeItem(at: src)
            if i < 2 {
                let variants = [1.10, 1.03, 0.77].enumerated().map { k, f in
                    OptimizeVariant(requestedVolumeFraction: f, achievedVolumeFraction: f, massGrams: 100 * f,
                                    supportVolumeVoxels: 0, meshTriangleCount: 1, worstCaseMargin: 5, accepted: true,
                                    v3Passes: true, meshVertices: [0, 0, 0, 1 + Float(k), 0, 0, 0, 1, 0], meshIndices: [0, 1, 2])
                }
                let o = OptimizeOutcome(variants: variants, stoppedOnMargin: false, cancelled: false, acceptedCount: 3,
                                        voxelVolumeMM3: 1, gridNx: 2, gridNy: 2, gridNz: 2, gridOrigin: .zero, spacing: 1)
                try store.saveResults(try OutcomeCodec.encode(OutcomeCodec.dto(from: o)), id: snap.id)
            }
        }
        let lib = LibraryModel(store: store)
        lib.refresh()
        try lib.group(projectName: "Squish Mechanism", partIDs: nil)
        return (lib, try XCTUnwrap(lib.index.parts.first))
    }

    private func part(_ lib: LibraryModel) throws -> LibraryPart { try XCTUnwrap(lib.index.parts.first) }

    private func loadPictures(_ lib: LibraryModel) {
        let exp = expectation(description: "pictures")
        lib.loadSummaries { exp.fulfill() }
        wait(for: [exp], timeout: 20)
    }

    /// A small stand-in for the original model's picture.
    private func original() throws -> CGImage {
        let ctx = try XCTUnwrap(CGContext(data: nil, width: 4, height: 4, bitsPerComponent: 8, bytesPerRow: 0,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        return try XCTUnwrap(ctx.makeImage())
    }

    // MARK: tests

    func testOneChosenPerPartAndTheLatestPickReplacesTheLast() throws {
        let (lib, p) = try carriageArms()
        let (v1, v2) = (p.versions[0].folderID, p.versions[1].folderID)
        XCTAssertNil(lib.chosen(of: p), "no part has a chosen until he picks one")
        lib.pick(folder: v1, result: 1)
        XCTAssertEqual(lib.chosen(of: try part(lib)), LibraryChosen(folder: v1, result: 1))
        XCTAssertEqual(lib.chosenTag(try part(lib)), "v1b", "★ the card's tag")
        lib.pick(folder: v2, result: 0)
        XCTAssertEqual(lib.chosen(of: try part(lib)), LibraryChosen(folder: v2, result: 0), "★ the latest pick replaces the last")
        XCTAssertNil(lib.chosenResult(folder: v1), "★ v1b is no longer picked: one per part")
        XCTAssertEqual(lib.chosenResult(folder: v2), 0, "Results' Picked ✓ reads it")
        let again = LibraryModel(store: store)
        again.refresh()
        XCTAssertEqual(again.chosen(of: try part(again)), LibraryChosen(folder: v2, result: 0), "kept in the Library's file")
    }

    func testAnOldPerVersionPickIsNotTheChosenOne() throws {
        let (lib, _) = try carriageArms()
        var idx = try XCTUnwrap(store.loadLibrary())
        idx.parts[0].versions[0].pickedResult = 2   // a pick from before (a switcher tap)
        try store.saveLibrary(idx)
        let again = LibraryModel(store: store)
        again.refresh()
        let p = try part(again)
        XCTAssertNil(again.chosen(of: p), "★ old picks are not migrated")
        XCTAssertNil(again.chosenResult(folder: p.versions[0].folderID))
        _ = lib
    }

    func testThePictureIsTheChosenResultNeverPrintThisElseTheOriginal() throws {
        let (lib, p) = try carriageArms()
        let (v1, v2, v3) = (p.versions[0].folderID, p.versions[1].folderID, p.versions[2].folderID)
        let orig = try original()
        lib.noteOriginal(folder: v3, image: orig)
        loadPictures(lib)
        lib.togglePrint(folder: v1, result: 2)
        XCTAssertTrue(lib.partPicture(try part(lib)) === orig, "★ Print this does not change the picture: the original until one is chosen")
        lib.pick(folder: v2, result: 1)
        let shot = try XCTUnwrap(lib.thumbnails[CompareItem(folder: v2, result: 1)])
        XCTAssertTrue(lib.partPicture(try part(lib)) === shot, "★ the chosen result's picture")
    }

    func testTrimKeepsTheChosenAndDeletingItsVersionLeavesNone() throws {
        let (lib, p) = try carriageArms()
        let (v1, v2) = (p.versions[0].folderID, p.versions[1].folderID)
        lib.pick(folder: v1, result: 2)
        try lib.trim(folder: v1)
        XCTAssertEqual(lib.chosen(of: try part(lib)), LibraryChosen(folder: v1, result: 0), "★ trim keeps the chosen one, now result 0")
        lib.pick(folder: v2, result: 1)
        try store.delete(id: v2)
        lib.refresh()
        XCTAssertNil(lib.chosen(of: try part(lib)), "★ its version is gone, so nothing is chosen")
    }
}
