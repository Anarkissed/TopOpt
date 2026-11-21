import XCTest
import TopOptKit
@testable import TopOptFlows

/// ★★ REVIEWER, 2026-10-08, ruling C (approved by the maintainer): "THE ORGANIC BAND. Keep it in the
/// preview, with the line 'the run doesn't build this band yet'. #358 adds it to core." The preview
/// grades the organic spacing toward the outline across the shape band (27,448 voxels on 102117B9
/// at one size 4 mm); no organic job carries a band, so the run grades none.
final class OrganicBandNotBuiltLineTests: XCTestCase {

    private func banner(graded: Int, algorithm: String = "organic") throws -> LatticePreviewBanner {
        var s = LatticePreviewSummaryValues(interiorVoxelCount: 1, previewLabel: "organic · 4.00 mm",
                                            algorithmName: algorithm)
        s.organicBandGradedVoxels = graded
        return try XCTUnwrap(LatticePreviewBanner.make(previewOn: true, hasModel: true, scene: s))
    }

    /// The line shows whenever the band graded anything, in the ruling's own words.
    func testTheBandSaysTheRunDoesNotBuildItYet() throws {
        let b = try banner(graded: 27_448)
        XCTAssertTrue(b.text.contains("the run doesn't build this band yet"), b.text)
        XCTAssertEqual(b.caption, "Band: preview only")
        XCTAssertLessThanOrEqual(b.caption.count, 34, "one line in the Selections column")
        XCTAssertTrue(b.text.hasPrefix("organic · 4.00 mm"), "the preview's own label stays first")
        // controls: no band graded ⇒ no line; a mismatch still wins over it
        let none = try banner(graded: 0)
        XCTAssertFalse(none.text.contains("the run doesn't build this band yet"))
        XCTAssertNotEqual(none.caption, "Band: preview only")
        var mismatch = LatticePreviewSummaryValues(interiorVoxelCount: 1,
                                                   previewLabel: "★ PREVIEW DOES NOT MATCH THE RUN — x",
                                                   algorithmName: "organic")
        mismatch.organicBandGradedVoxels = 10
        XCTAssertEqual(try XCTUnwrap(LatticePreviewBanner.make(previewOn: true, hasModel: true, scene: mismatch)).caption,
                       "★ Preview differs from run")
    }

    /// The scene counts the graded voxels where it grades them, and publishes the count.
    func testTheSceneCountsWhatTheBandGraded() throws {
        var u = URL(fileURLWithPath: #filePath); for _ in 0..<3 { u.deleteLastPathComponent() }
        let metal = try String(contentsOf: u.appendingPathComponent("Sources/TopOptFlows/LatticeSDFMetal.swift"), encoding: .utf8)
        XCTAssertTrue(metal.contains("bandGraded = graded"), "★ the band's own count")
        XCTAssertTrue(metal.contains("self.organicBandGradedVoxels = bandGraded"))
    }
}
