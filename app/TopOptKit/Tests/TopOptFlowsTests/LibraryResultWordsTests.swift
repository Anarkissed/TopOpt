// LibraryResultWordsTests — B5 (his Q1, plan.md §B5 / app-map §3.1): each Library result tile names its result the way Results
// does, "v2b · +10 %". His answer (11-04, "a: save the words"): the run's report is saved WITH its results, so a reopened
// strengthen run reads "Just safe · +10 % · +20 %" (Results and the tiles); a Minimize run keeps its savings ("−30%"); a
// strengthen run saved before today has no report, so its tiles show just "v2b".
//
// The reports here are lookalikes written for the test (never his job inputs).
#if canImport(AppKit) && canImport(MetalKit)
import XCTest
@testable import TopOptFlows
@testable import TopOptKit

@MainActor
final class LibraryResultWordsTests: XCTestCase {
    private var root: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("topopt-result-words-\(UUID().uuidString)", isDirectory: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    /// A strengthen report (the new ladder: `safety_margin`), one version per (fraction, status).
    static func report(_ versions: [(Double, String)]) throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "safety_margin": 1.5,
            "strengthen": ["as_drawn_margin": 0.8, "margin_required": 1.5, "ceiling_margin": 9.0,
                           "original_mass_grams": 100.0, "coarse_resolution": 64,
                           "versions": versions.enumerated().map { i, v in
                               ["version": i + 1, "status": v.1, "volume_fraction": v.1 == "unreachable" ? 0 : v.0,
                                "verified_margin": v.1 == "unreachable" ? 0 : 1.5 + 0.15 * Double(i),
                                "mass_grams": 60.0 + 5 * Double(i), "mass_fraction_of_original": 0.6 + 0.05 * Double(i),
                                "stress_cut": 0.0, "note": ""] as [String: Any] }] as [String: Any]
        ])
    }

    /// An outcome of one solid result per requested fraction (achieved = requested), with `report` riding on it.
    static func outcome(_ fractions: [Double], report: Data?, growthLadder: Bool = false) -> OptimizeOutcome {
        OptimizeOutcome(variants: fractions.enumerated().map { i, f in
            OptimizeVariant(requestedVolumeFraction: f, achievedVolumeFraction: f, massGrams: 60 + Double(i),
                            supportVolumeVoxels: 0, meshTriangleCount: 1, worstCaseMargin: 1.6, accepted: true, v3Passes: true,
                            meshVertices: [0, 0, 0, 1, 0, 0, 0, 1, 0], meshIndices: [0, 1, 2])
        }, stoppedOnMargin: false, cancelled: false, acceptedCount: fractions.count, voxelVolumeMM3: 1,
           gridNx: 2, gridNy: 2, gridNz: 2, gridOrigin: .zero, spacing: 1, growthLadder: growthLadder, reportJSON: report)
    }

    // MARK: the report is saved with the results

    func testTheRunsReportIsSavedWithItsResults() throws {
        let report = try Self.report([(0.40, "verified"), (0.48, "verified"), (0.56, "verified")])
        let back = try OutcomeCodec.decode(try OutcomeCodec.encode(OutcomeCodec.dto(from: Self.outcome([0.40, 0.48, 0.56],
                                                                                                        report: report))))
        XCTAssertEqual(back.reportJSON, report, "★ his answer (a): the report survives the save, so a reopen keeps its words")
        XCTAssertNotNil(back.reportJSON.flatMap(RunReportBlocks.decode(reportJSON:))?.strengthen, "Results reads it on reopen")
        // a run with no report (on the device) stores nothing new: its file is today's
        let plain = try OutcomeCodec.encode(OutcomeCodec.dto(from: Self.outcome([0.5], report: nil)))
        let dict = try XCTUnwrap(try PropertyListSerialization.propertyList(from: plain, options: PropertyListSerialization.ReadOptions(), format: nil) as? [String: Any])
        XCTAssertFalse(dict.keys.contains { $0.lowercased().contains("report") && $0 != "latticeReport" },
                       "no report: no new key, the bytes stay today's")
        XCTAssertNil(try OutcomeCodec.decode(plain).reportJSON)
    }

    // MARK: the words

    func testAStrengthenRunsWordsAreJustSafeThenTenPercentSteps() throws {
        let o = Self.outcome([0.40, 0.48, 0.56], report: try Self.report([(0.40, "verified"), (0.48, "verified"), (0.56, "verified")]))
        XCTAssertEqual(ResultsVersions.words(o), ["Just safe", "+10 %", "+20 %"], "★ Q1: a · Just safe, b · +10 %, c · +20 %")
    }

    func testAVersionCoreCouldNotMakeLeavesNoResultAndNoWord() throws {
        let o = Self.outcome([0.40, 0.56], report: try Self.report([(0.40, "verified"), (0, "unreachable"), (0.56, "verified")]))
        XCTAssertEqual(ResultsVersions.words(o), ["Just safe", "+20 %"], "each result keeps its own version's words")
    }

    func testTheWordsAreResultsOwnLines() throws {
        let o = Self.outcome([0.40, 0.48, 0.56], report: try Self.report([(0.40, "verified"), (0.48, "verified"), (0.56, "verified")]))
        let blocks = try XCTUnwrap(o.reportJSON.flatMap(RunReportBlocks.decode(reportJSON:)))
        XCTAssertEqual(StrengthenText.cards(blocks).map(\.title), ["a · Just safe", "b · +10 %", "c · +20 %"],
                       "Results' own titles: the tiles read the same words")
    }

    func testAMinimizeRunsWordsAreItsSavings() {
        let o = Self.outcome([0.7, 0.6], report: nil)
        XCTAssertEqual(ResultsVersions.words(o), ["\u{2212}30%", "\u{2212}40%"], "★ what Results says on that line")
    }

    func testAStrengthenRunSavedBeforeTodayHasNoWord() {
        let o = Self.outcome([0.40, 0.48], report: nil, growthLadder: true)
        XCTAssertEqual(ResultsVersions.words(o), [nil, nil], "★ his answer (a): no report, no word — never a misleading −60%")
    }

    // MARK: the Library keeps them; the tile shows them

    func testTheTileReadsTheVersionTheLetterAndTheWord() {
        XCTAssertEqual(LibraryStyle.resultTitle(number: "2", result: 1, word: "+10 %"), "v2b · +10 %", "★ Q1 on the tile")
        XCTAssertEqual(LibraryStyle.resultTitle(number: "4.1", result: 0, word: "Just safe"), "v4.1a · Just safe")
        XCTAssertEqual(LibraryStyle.resultTitle(number: "2", result: 2, word: nil), "v2c", "no word: the name alone")
    }

    func testTheLibraryKeepsEachResultsWordAndTrimKeepsThePickedOnesWord() throws {
        let store = ProjectStore(rootDir: root.appendingPathComponent("store", isDirectory: true))
        let src = root.appendingPathComponent("import", isDirectory: true)
        try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
        let model = src.appendingPathComponent("Arm.stl")
        try ParityLibraryShots.boxSTL(SIMD3(40, 20, 10)).write(to: model, atomically: true, encoding: .utf8)
        let snap = ProjectSnapshot(id: UUID(), name: "Arm", material: "PA12", process: .fdm, modelFileName: "model.stl",
                                   originalFileName: "Arm.stl", savedAt: Date(timeIntervalSince1970: 100),
                                   selection: SelectionModel(), force: ForceModel(), quality: .fast, optimized: true)
        try store.save(snap, modelSource: model)
        let o = Self.outcome([0.40, 0.48, 0.56], report: try Self.report([(0.40, "verified"), (0.48, "verified"), (0.56, "verified")]))
        try store.saveResults(try OutcomeCodec.encode(OutcomeCodec.dto(from: o)), id: snap.id)
        let library = LibraryModel(store: store)
        library.refresh()
        _ = library.proposal()
        try library.group(projectName: "Rig", partIDs: nil)
        let done = expectation(description: "summaries")
        library.loadSummaries { done.fulfill() }
        wait(for: [done], timeout: 20)
        XCTAssertEqual(library.version(snap.id)?.summary?.map(\.word), ["Just safe", "+10 %", "+20 %"],
                       "★ each result's word, read once with its numbers")
        library.pick(folder: snap.id, result: 1)
        try library.trim(folder: snap.id)
        XCTAssertEqual(library.version(snap.id)?.summary?.map(\.word), ["+10 %"], "★ Trim keeps the picked one's word")
        XCTAssertEqual(ResultsVersions.words(try OutcomeCodec.decode(try XCTUnwrap(store.loadResultsData(id: snap.id)))),
                       ["+10 %"], "the trimmed file keeps its report, so a reopen still says +10 %")
    }
}
#endif
