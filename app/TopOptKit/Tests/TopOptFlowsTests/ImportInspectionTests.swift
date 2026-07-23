// ImportInspectionTests.swift — the unit prompt + refusal copy (handoff 134).
//
// These are pure value types over plain inputs, so they test headlessly: no
// GPU, no device, no file picker. That is the point of keeping the decisions
// out of the Views.

import XCTest
import TopOptKit
@testable import TopOptFlows

final class ImportInspectionTests: XCTestCase {

    // MARK: units

    func testMillimetresIsTheDefaultAndTheScaleIsCorrect() {
        XCTAssertEqual(ImportUnitPrompt.defaultUnit, .millimetres)
        XCTAssertEqual(PartUnit.millimetres.scaleToMM, 1.0)
        XCTAssertEqual(PartUnit.inches.scaleToMM, 25.4)
    }

    func testSizeHintReportsBothReadings() {
        let p = ImportUnitPrompt(fileName: "bracket.stl", largestDimension: 120)
        XCTAssertEqual(p.sizeMM(as: .millimetres), 120)
        XCTAssertEqual(p.sizeMM(as: .inches), 3048)
        // The hint names both numbers — that is what makes the choice obvious.
        XCTAssertTrue(p.sizeHint.contains("120"))
        XCTAssertTrue(p.sizeHint.contains("3048"))
    }

    func testAPartSizedFileInMillimetresRecommendsMillimetres() {
        let p = ImportUnitPrompt(fileName: "bracket.stl", largestDimension: 120)
        XCTAssertTrue(p.isPlausible(.millimetres))
        XCTAssertFalse(p.isPlausible(.inches))     // 3048 mm is not a printed part
        XCTAssertEqual(p.suggestedUnit, .millimetres)
        XCTAssertNotNil(p.recommendation)
    }

    // A file whose numbers are too small to be millimetres: 0.5 mm is not a
    // printable part, 12.7 mm is. Here the prompt does lean.
    func testATinyFileRecommendsInches() {
        let p = ImportUnitPrompt(fileName: "bracket.stl", largestDimension: 0.5)
        XCTAssertFalse(p.isPlausible(.millimetres))  // 0.5 mm — below the window
        XCTAssertTrue(p.isPlausible(.inches))        // 12.7 mm — part-sized
        XCTAssertEqual(p.suggestedUnit, .inches)
        XCTAssertTrue(p.recommendation?.contains("Inches") == true)
    }

    // THE HONEST LIMIT, pinned as a test. A 4.72-unit file is the classic inch
    // export (4.72 in = 120 mm) — but 4.72 mm is also a perfectly real small
    // part, so BOTH readings are plausible and the hint must not pretend to
    // know. It still shows both numbers; it just doesn't recommend.
    func testAClassicInchExportIsLeftAmbiguousRatherThanGuessed() {
        let p = ImportUnitPrompt(fileName: "bracket.stl", largestDimension: 4.72)
        XCTAssertTrue(p.isPlausible(.millimetres))
        XCTAssertTrue(p.isPlausible(.inches))
        XCTAssertNil(p.recommendation)
        XCTAssertEqual(p.suggestedUnit, .millimetres)   // the stated default
        XCTAssertTrue(p.sizeHint.contains("4.72"))      // both numbers still shown
        XCTAssertTrue(p.sizeHint.contains("120"))
    }

    // When BOTH readings are plausible the prompt must not argue — it defaults
    // to millimetres and offers no recommendation.
    func testAnAmbiguousSizeMakesNoRecommendation() {
        let p = ImportUnitPrompt(fileName: "part.stl", largestDimension: 20)
        XCTAssertTrue(p.isPlausible(.millimetres))   // 20 mm
        XCTAssertTrue(p.isPlausible(.inches))        // 508 mm
        XCTAssertNil(p.recommendation)
        XCTAssertEqual(p.suggestedUnit, .millimetres)
    }

    // MARK: refusal copy

    private func diagnostics(_ defects: [PartDiagnostics.Defect],
                             boundaryEdges: Int = 0,
                             nonManifoldEdges: Int = 0,
                             welded: Int = 0, flipped: Int = 0,
                             degenerate: Int = 0) -> PartDiagnostics {
        PartDiagnostics(checked: true, acceptable: defects.isEmpty, defects: defects,
                        defectText: defects.map { _ in "core text" },
                        boundaryEdges: boundaryEdges, nonManifoldEdges: nonManifoldEdges,
                        degenerateTriangles: degenerate, weldedVertices: welded,
                        flippedTriangles: flipped, volume: 1,
                        bboxMin: .zero, bboxMax: SIMD3<Double>(10, 20, 5))
    }

    func testEveryDefectProducesPlainLanguageAndASuggestion() {
        for defect in PartDiagnostics.Defect.allCases {
            let r = ImportRefusal(fileName: "x.stl",
                                  diagnostics: diagnostics([defect]), rawMessage: "")
            XCTAssertEqual(r.reasons.count, 1, "\(defect) should explain itself")
            XCTAssertFalse(r.reasons[0].headline.isEmpty)
            XCTAssertFalse(r.reasons[0].detail.isEmpty)
            // No jargon leaks into the headline the user reads first.
            let headline = r.reasons[0].headline.lowercased()
            XCTAssertFalse(headline.contains("manifold"), "\(defect) headline uses jargon")
            XCTAssertFalse(headline.contains("orientable"), "\(defect) headline uses jargon")
            // There is always something to try, and the scope limit is stated.
            XCTAssertFalse(r.suggestions.isEmpty, "\(defect) should suggest something")
            XCTAssertFalse(r.scopeNote.isEmpty)
        }
    }

    func testOpenBoundaryReasonQuotesTheMeasuredCount() {
        let r = ImportRefusal(fileName: "x.stl",
                              diagnostics: diagnostics([.openBoundary], boundaryEdges: 4),
                              rawMessage: "")
        XCTAssertTrue(r.reasons[0].detail.contains("4 edges"))
    }

    func testASingleEdgeIsNotPluralised() {
        let r = ImportRefusal(fileName: "x.stl",
                              diagnostics: diagnostics([.openBoundary], boundaryEdges: 1),
                              rawMessage: "")
        XCTAssertTrue(r.reasons[0].detail.contains("1 edge "))
    }

    func testAMeshRepairIsSuggestedOnlyForTopologyDefects() {
        let topology = ImportRefusal(fileName: "x.stl",
                                     diagnostics: diagnostics([.openBoundary]),
                                     rawMessage: "")
        XCTAssertTrue(topology.suggestions.contains { $0.contains("repair") })

        let thickness = ImportRefusal(fileName: "x.stl",
                                      diagnostics: diagnostics([.zeroThickness]),
                                      rawMessage: "")
        XCTAssertTrue(thickness.suggestions.contains { $0.contains("thickness") })
    }

    // An unreadable file has no structured verdict; the sheet must still say
    // something useful rather than render empty.
    func testAnUnreadableFileFallsBackToTheCoreMessage() {
        let r = ImportRefusal(fileName: "x.stl", diagnostics: nil,
                              rawMessage: "file not found")
        XCTAssertEqual(r.reasons.count, 1)
        XCTAssertEqual(r.reasons[0].detail, "file not found")
        XCTAssertFalse(r.suggestions.isEmpty)
    }

    // MARK: repair note

    func testRepairNoteNamesWhatChangedAndIsAbsentWhenNothingDid() {
        XCTAssertNil(ImportRepairNote.text(for: diagnostics([])))

        let note = ImportRepairNote.text(for: diagnostics([], welded: 12, flipped: 3,
                                                          degenerate: 1))
        XCTAssertNotNil(note)
        XCTAssertTrue(note?.contains("12 duplicate points") == true)
        XCTAssertTrue(note?.contains("3 triangles") == true)
        XCTAssertTrue(note?.contains("1 empty triangle") == true)
    }

    func testSTEPPartsAreNeverAnnotatedWithARepairNote() {
        // A STEP import is not mesh-inspected at all (checked == false), so it
        // must never claim a repair happened.
        let step = PartDiagnostics(checked: false, acceptable: true, defects: [],
                                   defectText: [], boundaryEdges: 0,
                                   nonManifoldEdges: 0, degenerateTriangles: 0,
                                   weldedVertices: 9, flippedTriangles: 9,
                                   volume: 0, bboxMin: .zero, bboxMax: .zero)
        XCTAssertNil(ImportRepairNote.text(for: step))
    }
}
