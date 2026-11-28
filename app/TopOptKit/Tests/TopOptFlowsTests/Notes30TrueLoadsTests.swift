// Notes30TrueLoadsTests — the app's side of the TO rebuild's stages 1 and 2 ("For #362",
// docs/design/to-rebuild/stages/stage-1-true-loads.md): the report keys core writes only while its switches are on, read by
// TrueLoadsReport and said in his words. Pinned against small report.json fixtures written from the keys report.cpp writes
// (core/src/settings/report.cpp: "as_drawn", "pads", "too_small", "strength_reading", "drawn_part", and a refused version's
// "the load has no path to a mount"). Each ★ RED CONTROL is today's report, without the keys: the app behaves as before.
// The key layout is TOReview's real flipped runs' (2026-11-28: report_pads / report_too_small / report_as_drawn.json); those
// files are read in place by testTOReviewsRealSamples when TOREVIEW_FOR362_DIR names their folder, and never committed.
import XCTest
import TopOptKit
@testable import TopOptFlows

@MainActor
final class Notes30TrueLoadsTests: XCTestCase {

    // MARK: fixtures (the keys as report.cpp writes them, in the layout of TOReview's real samples)

    /// A reduction run that kept no version, every stage 1-2 key on.
    static let allKeys = """
    {
      "material": "PLA",
      "variants": [],
      "rejected_variants": [
        {"volume_fraction": 0.6800000045, "accepted": false, "margin_required": 1.5, "rejection_reason": "margin below required"},
        {"volume_fraction": 0.5, "accepted": false, "rejection_reason": "the load has no path to a mount"}
      ],
      "as_drawn": {"margin": 0.4498, "required": 1.5, "passes": false},
      "pads": [{"face_id": 8, "thickness_mm": 12, "pad_mm": 1.2, "automatic": true},
               {"region_id": 104, "thickness_mm": 70, "pad_mm": 4.5, "automatic": true}],
      "too_small": {"thickest_mm": 0.9, "needed_mm": 1.35, "line_width_mm": 0.45, "nozzle_that_fits_mm": 0.2},
      "strength_reading": {"size_mm": 1.2, "voxel_mm": 0.3125, "needs_voxel_mm": 0.6857142857, "over_size": true},
      "drawn_part": {"printed_grams": 144.4, "solid_grams": 226}
    }
    """
    /// report_too_small.json's own block: the run still made its 4 versions, so it is a notice, never a refusal.
    static let tooSmallSample = #""too_small": {"thickest_mm": 7.5, "needed_mm": 9, "line_width_mm": 3, "nozzle_that_fits_mm": 0.6}"#
    /// The same run's report from today's build (every switch off).
    static let today = """
    {"variants": [], "rejected_variants": [{"volume_fraction": 0.68, "accepted": false, "rejection_reason": "margin below required"}]}
    """
    static func data(_ s: String) -> Data { Data(s.utf8) }
    static func report(_ s: String) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: data(s))) as? [String: Any] ?? [:]
    }
    /// A report with only `keys` (JSON members, comma-separated) besides today's arrays.
    static func with(_ keys: String, rejected: String = "") -> String {
        "{\"variants\": [], \"rejected_variants\": [\(rejected)]" + (keys.isEmpty ? "" : ", " + keys) + "}"
    }

    private func variant(vf: Double, margin: Double, accepted: Bool, grams: Double = 60) -> OptimizeVariant {
        OptimizeVariant(requestedVolumeFraction: vf, achievedVolumeFraction: vf, massGrams: grams, supportVolumeVoxels: 0,
                        meshTriangleCount: 12, worstCaseMargin: margin, accepted: accepted, v3Passes: accepted,
                        meshVertices: [0, 0, 0], meshIndices: [0])
    }
    private func request() -> RunRequest {
        RunRequest(modelPath: "/x/part.step", material: "PLA", materialsPath: "", rulesPath: "", resolution: 24, projectName: "P")
    }
    /// A run that ends with `variants` and `report`, through the stub runner.
    private func run(_ variants: [OptimizeVariant], report: String) -> RunModel {
        let model = RunModel(scheduler: SynchronousRunScheduler())
        let accepted = variants.filter(\.accepted).count
        model.runner = { _, _, _ in
            OptimizeOutcome(variants: variants, stoppedOnMargin: accepted == 0, cancelled: false, acceptedCount: accepted,
                            reportJSON: Self.data(report))
        }
        model.start(request())
        return model
    }

    override func setUp() { super.setUp(); AppPopups.shared.current = nil }
    override func tearDown() { AppPopups.shared.current = nil; super.tearDown() }

    // MARK: decoding

    func testEveryKeyDecodes() {
        let t = TrueLoadsReport.decode(report: Self.report(Self.allKeys))
        XCTAssertEqual(t.asDrawn, .init(margin: 0.4498, required: 1.5, passes: false))
        XCTAssertEqual(t.pads, [.init(faceID: 8, regionID: nil, thicknessMM: 12, padMM: 1.2, automatic: true),
                                .init(faceID: nil, regionID: 104, thicknessMM: 70, padMM: 4.5, automatic: true)])
        XCTAssertEqual(t.tooSmall, .init(thickestMM: 0.9, neededMM: 1.35, lineWidthMM: 0.45, nozzleThatFitsMM: 0.2))
        XCTAssertEqual(t.strengthReading, .init(sizeMM: 1.2, voxelMM: 0.3125, needsVoxelMM: 0.6857142857, overSize: true))
        XCTAssertEqual(t.drawnPart, .init(printedGrams: 144.4, solidGrams: 226))
        XCTAssertEqual(t.noPathVolumeFractions, [0.5])
        XCTAssertTrue(t.printedGrams)
    }

    func testTodaysReportReadsEmpty() {
        // ★ RED CONTROL: every key absent (core's switches off) — nothing here, nothing said
        let t = TrueLoadsReport.decode(reportJSON: Self.data(Self.today))
        XCTAssertTrue(t.isEmpty)
        XCTAssertFalse(t.printedGrams)
        XCTAssertNil(TrueLoadsFailure.of(t, terminalVF: 0.68))
        XCTAssertTrue(TrueLoadsReport.decode(reportJSON: nil).isEmpty, "an on-device run has no report")
    }

    // MARK: as drawn (A-05): the pop-up offering Strengthen

    func testTooWeakAsDrawnIsThePopUpOfferingStrengthen() {
        let m = run([variant(vf: 0.68, margin: 0.4, accepted: false)],
                    report: Self.with(#""as_drawn": {"margin": 0.4498, "required": 1.5, "passes": false}"#))
        XCTAssertEqual(m.phase, .failed)
        XCTAssertEqual(m.failure, .trueLoads(.asDrawn(margin: 0.4498, required: 1.5)))
        XCTAssertEqual(m.failure?.title, "Your part needs strengthening")
        XCTAssertEqual(m.failure?.message, "As drawn, your part holds 0.45× its load, and your safety margin asks for 1.50×. "
                       + "Strengthen redesigns it to reach that, adding as little plastic as it can.")
        XCTAssertEqual(TrueLoadsFailure.asDrawn(margin: 0.45, required: 1.5).offersStrengthen, true)
        XCTAssertEqual(TrueLoadsWords.strengthenButton, "Strengthen")
    }

    func testWithoutAsDrawnTheSheetIsTodays() {
        // ★ RED CONTROL: today's report — today's margin sheet, word for word
        let m = run([variant(vf: 0.68, margin: 0.4, accepted: false)], report: Self.today)
        XCTAssertEqual(m.failure, .allRejectedOnMargin(worstMargin: 0.4, effectiveMargin: 0.4, minFeatureViolations: 0, diagnosis: nil))
        // ★ RED CONTROL: a part that passes as drawn is no Strengthen case
        let p = run([variant(vf: 0.68, margin: 0.4, accepted: false)],
                    report: Self.with(#""as_drawn": {"margin": 2.1, "required": 1.5, "passes": true}"#))
        XCTAssertEqual(p.failure, .allRejectedOnMargin(worstMargin: 0.4, effectiveMargin: 0.4, minFeatureViolations: 0, diagnosis: nil))
    }

    // MARK: too small for the nozzle: one pop-up, 0.6 / 0.4 / 0.2 mm or resin

    func testTooSmallRecommendsOnlyHisThreeNozzlesOrResin() {
        func s(_ n: Double) -> TrueLoadsReport.TooSmall { .init(thickestMM: 0.9, neededMM: 1.35, lineWidthMM: 0.45, nozzleThatFitsMM: n) }
        XCTAssertEqual(TrueLoadsWords.tooSmallTitle(s(0.6)), "Try a 0.6 mm nozzle")
        XCTAssertEqual(TrueLoadsWords.tooSmallTitle(s(0.4)), "Try a 0.4 mm nozzle")
        XCTAssertEqual(TrueLoadsWords.tooSmallTitle(s(0.2)), "Try a 0.2 mm nozzle")
        XCTAssertEqual(TrueLoadsWords.tooSmallTitle(s(0.25)), "Try a 0.2 mm nozzle", "only his three sizes, never core's other number")
        XCTAssertEqual(TrueLoadsWords.tooSmallTitle(s(0)), "Try resin printing")
        XCTAssertEqual(TrueLoadsWords.tooSmallText(s(0.2)), "Your part’s thickest section is 0.90 mm. A 0.45 mm line needs 1.35 mm "
                       + "to leave room for a cut. A 0.2 mm nozzle fits it.")
        XCTAssertTrue(TrueLoadsWords.tooSmallText(s(0)).hasSuffix("Resin printing makes parts this fine."))
    }

    func testTooSmallIsOneCentredPopUpBesideTheVersions() {
        let key = Self.tooSmallSample
        // report_too_small.json's run: its 4 versions stand, and the centred pop-up says it once (a notice, never a refusal)
        let four = [0.68, 0.52, 0.38, 0.26].map { variant(vf: $0, margin: 3, accepted: true) }
        let ok = run(four, report: Self.with(key))
        XCTAssertEqual(ok.phase, .succeeded)
        XCTAssertNil(ok.failure)
        XCTAssertEqual(ok.outcome?.variants.filter(\.accepted).count, 4, "the versions stay")
        XCTAssertEqual(AppPopups.shared.current?.title, "Try a 0.6 mm nozzle")
        XCTAssertEqual(AppPopups.shared.current?.text, "Your part’s thickest section is 7.50 mm. A 3.00 mm line needs 9.00 mm "
                       + "to leave room for a cut. A 0.6 mm nozzle fits it.")
        AppPopups.shared.current = nil
        // a run that kept nothing: its failure pop-up says it, and no second pop-up
        let none = run([variant(vf: 0.68, margin: 0.4, accepted: false)], report: Self.with(key))
        XCTAssertEqual(none.failure?.title, "Try a 0.6 mm nozzle")
        XCTAssertNil(AppPopups.shared.current, "only ever one pop-up")
        // ★ RED CONTROL: today's report raises nothing
        _ = run([variant(vf: 0.68, margin: 3, accepted: true)], report: Self.today)
        XCTAssertNil(AppPopups.shared.current)
    }

    // MARK: the load lost its path: plain words, never a solver failure

    func testNoPathIsPlainWordsOnThatVersion() {
        let row = #"{"volume_fraction": 0.5, "accepted": false, "rejection_reason": "the load has no path to a mount"}"#
        let m = run([variant(vf: 0.5, margin: 0, accepted: false)], report: Self.with("", rejected: row))
        XCTAssertEqual(m.failure, .trueLoads(.noPath), "never .solver: the solver ran fine")
        XCTAssertEqual(m.failure?.title, "The load lost its path")
        XCTAssertFalse(m.failureShowsOnButton, "a design result is a pop-up, never engine text on the button")
        let b = RunReportBlocks.decode(report: Self.report(Self.with("", rejected: row)))
        XCTAssertEqual(StrengthenText.rejectionLines(b), ["A version cut the load’s path to its anchors, so it was set aside"])
        // ★ RED CONTROL: a margin refusal has no such line
        XCTAssertEqual(StrengthenText.rejectionLines(RunReportBlocks.decode(report: Self.report(Self.today))), [])
    }

    // MARK: the pads, and printed grams, on Results

    private func results(_ report: String) -> ResultsModel {
        let o = OptimizeOutcome(variants: [variant(vf: 0.6, margin: 3, accepted: true, grams: 85.4)], stoppedOnMargin: false,
                                cancelled: false, acceptedCount: 1, computedRemotely: true, reportJSON: Self.data(report))
        return ResultsModel(projectName: "P", outcome: o)
    }

    func testThePadsAreOneLineWithEachFaceByNameBehindItsInfo() throws {
        let m = results(Self.allKeys)
        let pad = try XCTUnwrap(m.detailRows(.run, version: nil).first { $0.label == "Pad depth" })
        XCTAssertEqual(pad.value, "Auto · 1.2–4.5 mm")
        let info = try XCTUnwrap(pad.info)
        XCTAssertTrue(info.hasSuffix("\n\nA face: 1.2 mm, 12.0 mm of plastic behind it\nA cut piece: 4.5 mm, 70.0 mm of plastic behind it"), info)
        XCTAssertNil(info.range(of: #"\b[Ff]ace \d|\b[Rr]egion \d|\b8\b|104"#, options: .regularExpression), "never a face number: \(info)")
        // the workspace's namer gives each its plain name
        m.placeName = { $0.faceID == 8 ? "Top face" : "Left bracket" }
        let named = try XCTUnwrap(m.detailRows(.run, version: nil).first { $0.label == "Pad depth" }?.info)
        XCTAssertTrue(named.hasSuffix("Top face: 1.2 mm, 12.0 mm of plastic behind it\nLeft bracket: 4.5 mm, 70.0 mm of plastic behind it"), named)
        // a typed pad (Manual) says so
        XCTAssertEqual(TrueLoadsWords.padValue([.init(faceID: 1, regionID: nil, thicknessMM: 0, padMM: 3, automatic: false)]), "3.0 mm")
        // ★ RED CONTROL: no "pads" key, no line
        XCTAssertFalse(results(Self.today).detailRows(.run, version: nil).contains { $0.label == "Pad depth" })
    }

    func testGramsArePrintedGramsWhenStageTwoIsOn() throws {
        let m = results(Self.allKeys)
        XCTAssertEqual(m.tabs.first?.massLabel, "85 g printed")
        let drawn = try XCTUnwrap(m.detailRows(.strength, version: nil).first { $0.label == "Part as drawn" })
        XCTAssertEqual(drawn.value, "144 g printed")
        XCTAssertEqual(drawn.info, "What your part as drawn weighs, printed with your walls and infill. Printed solid, it weighs 226 g.")
        // ★ RED CONTROL: today's report — today's label, no drawn-part line
        let t = results(Self.today)
        XCTAssertEqual(t.tabs.first?.massLabel, "85 g")
        XCTAssertFalse(t.detailRows(.strength, version: nil).contains { $0.label == "Part as drawn" })
    }

    // MARK: TOReview's real flipped runs (read in place, never committed)

    /// The folder TOReview dropped its samples in (TOREVIEW_FOR362_DIR); the test skips without it.
    private func sample(_ name: String) throws -> Data {
        guard let dir = ProcessInfo.processInfo.environment["TOREVIEW_FOR362_DIR"], !dir.isEmpty else {
            throw XCTSkip("TOREVIEW_FOR362_DIR is unset: TOReview's samples are read only where they are")
        }
        return try Data(contentsOf: URL(fileURLWithPath: dir).appendingPathComponent(name))
    }

    func testTOReviewsRealSamples() throws {
        // report_pads.json: 4 versions, every grams label printed, one Pad depth line, no pop-up
        let pads = try sample("report_pads.json")
        let p = TrueLoadsReport.decode(reportJSON: pads)
        XCTAssertEqual(p.pads.count, 3)
        XCTAssertTrue(p.pads.allSatisfy { $0.faceID != nil && $0.automatic })
        XCTAssertTrue(p.printedGrams)
        XCTAssertNil(p.asDrawn)
        XCTAssertNil(p.tooSmall)
        let four = [0.6800000045, 0.5200000245, 0.380000002, 0.2600000041].map { variant(vf: $0, margin: 7, accepted: true) }
        let m = ResultsModel(projectName: "Bracket", outcome: OptimizeOutcome(
            variants: four, stoppedOnMargin: false, cancelled: false, acceptedCount: 4, computedRemotely: true, reportJSON: pads))
        XCTAssertTrue(m.tabs.allSatisfy { $0.massLabel.hasSuffix(" printed") }, "\(m.tabs.map(\.massLabel))")
        let row = try XCTUnwrap(m.detailRows(.run, version: nil).first { $0.label == "Pad depth" })
        XCTAssertTrue(row.value.hasPrefix("Auto · "), row.value)
        XCTAssertNil(row.info?.range(of: #"\b[Ff]ace \d"#, options: .regularExpression), "never a face number")
        XCTAssertNotNil(m.detailRows(.strength, version: nil).first { $0.label == "Part as drawn" })
        let made = run(four, report: String(decoding: pads, as: UTF8.self))
        XCTAssertEqual(made.phase, .succeeded)
        XCTAssertNil(AppPopups.shared.current)
        // report_too_small.json: the 4 versions AND the one pop-up
        let small = run(four, report: String(decoding: try sample("report_too_small.json"), as: UTF8.self))
        XCTAssertEqual(small.phase, .succeeded)
        XCTAssertEqual(AppPopups.shared.current?.title, "Try a 0.6 mm nozzle")
        AppPopups.shared.current = nil
        // report_as_drawn.json: 0 versions, the pop-up offering Strengthen
        let drawn = run([variant(vf: 0.6800000045, margin: 7.5, accepted: false)],
                        report: String(decoding: try sample("report_as_drawn.json"), as: UTF8.self))
        XCTAssertEqual(drawn.failure, .trueLoads(.asDrawn(margin: 8.190100418, required: 40)))
        XCTAssertEqual(drawn.failure?.title, "Your part needs strengthening")
    }

    // MARK: his on-screen rules

    func testEveryNewStringKeepsHisRules() {
        let s = TrueLoadsReport.TooSmall(thickestMM: 0.9, neededMM: 1.35, lineWidthMM: 0.45, nozzleThatFitsMM: 0.2)
        let r = TrueLoadsReport.TooSmall(thickestMM: 0.1, neededMM: 1.35, lineWidthMM: 0.45, nozzleThatFitsMM: 0)
        let captions = [TrueLoadsWords.asDrawnTitle, TrueLoadsWords.tooSmallTitle(s), TrueLoadsWords.tooSmallTitle(r),
                        TrueLoadsWords.noPathTitle, TrueLoadsWords.padLabel, TrueLoadsWords.drawnPartLabel,
                        TrueLoadsWords.strengthenButton]
        for c in captions { XCTAssertLessThanOrEqual(c.split(separator: " ").count, 5, "≤ 5 words: \(c)") }
        let all = captions + [TrueLoadsWords.asDrawnText(margin: 0.45, required: 1.5), TrueLoadsWords.tooSmallText(s),
                              TrueLoadsWords.tooSmallText(r), TrueLoadsWords.noPathText, TrueLoadsWords.noPathLine,
                              TrueLoadsWords.padInfoLead, TrueLoadsWords.printed("85 g")]
        for w in all {
            XCTAssertNil(w.range(of: #"\b(not|don[’']t|can[’']t|cannot)\b"#, options: [.regularExpression, .caseInsensitive]),
                         "positive words: \(w)")
        }
        // ★ RED CONTROL: the check catches a negative word
        XCTAssertNotNil("It can’t print".range(of: #"\b(not|don[’']t|can[’']t|cannot)\b"#, options: [.regularExpression, .caseInsensitive]))
    }
}
