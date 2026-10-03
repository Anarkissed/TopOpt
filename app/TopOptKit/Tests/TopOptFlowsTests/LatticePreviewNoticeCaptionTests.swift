import XCTest
import TopOptKit
@testable import TopOptFlows

/// ★ THE PREVIEW NOTICE IS A CAPTION (maintainer, 2026-09-06: "a massive squircle of
/// text that is over a bunch of other assets … shorten this text so it is only above
/// the minimized Selections window and doesn't reach beyond the start of the iPad
/// chip"). The sentence still exists, unchanged, behind the (i).
final class LatticePreviewNoticeCaptionTests: XCTestCase {

    private func banner(label: String) throws -> LatticePreviewBanner {
        try XCTUnwrap(LatticePreviewBanner.make(
            previewOn: true, hasModel: true,
            scene: LatticePreviewSummaryValues(interiorVoxelCount: 1, previewLabel: label)))
    }

    func testTheCaptionIsFourWordsAndTheSentenceIsUntouched() throws {
        let b = try banner(label: LatticeSDFPreview(latticeID: "octet").previewLabel)
        XCTAssertEqual(b.caption, "Lattice preview · not the export")
        XCTAssertEqual(b.text, "LATTICE PREVIEW — live strut geometry, not the exported mesh",
                       "the full sentence is what the (i) shows; it did not move")
        XCTAssertLessThanOrEqual(b.caption.count, 34)
        XCTAssertFalse(b.caption.contains("—"))
    }

    func testTheStandInAndMismatchCasesKeepTheirWarningInTheCaption() throws {
        let ladder = LatticePreviewBanner.drawing(
            "LATTICE PREVIEW — live strut geometry, not the exported mesh · shown as the doubled ladder; "
            + "the run builds the organic lattice — no stress tensor reached the tracer")
        XCTAssertEqual(ladder.caption, "Lattice preview · stand-in")
        let bad = LatticePreviewBanner.drawing("★ PREVIEW DOES NOT MATCH THE RUN — 3 struts short  LATTICE PREVIEW …")
        XCTAssertEqual(bad.caption, "★ Preview differs from run")
        let empty = LatticePreviewBanner.empty("No lattice to show — there is no model open yet.")
        XCTAssertEqual(empty.caption, empty.text, "a reason is already one short sentence")
    }

    /// The call site: the caption is what is drawn, the sentence is behind (i), and
    /// the notice is capped to the Selections column.
    func testTheNoticeDrawsTheCaptionCappedToTheSelectionsColumn() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/TopOptFlows/WorkspacePlaceholder.swift")
        let ws = try String(contentsOf: url, encoding: .utf8)
        guard let r = ws.range(of: "private var latticePreviewNotice: some View {") else {
            return XCTFail("the notice moved")
        }
        let body = String(ws[r.lowerBound...].prefix(3000))
        XCTAssertTrue(body.contains("Text(banner.caption)"), "the caption is what is drawn")
        XCTAssertTrue(body.contains("Text(banner.text)"), "the sentence is behind the (i)")
        XCTAssertTrue(body.contains(".popover(isPresented: $latticeNoticeInfoShown)"))
        XCTAssertTrue(body.contains(".frame(maxWidth: CGFloat(LatticePreviewBanner.noticeMaxWidthPT), alignment: .leading)"))
        XCTAssertLessThanOrEqual(LatticePreviewBanner.noticeMaxWidthPT, 300,
                                 "the iPad chip starts ~310 pt in on the 13-inch iPad")
    }
}
