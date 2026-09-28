import XCTest
@testable import TopOptFlows

/// ★★ ONE LINE PER CAPTION, THE REST BEHIND THE (i) (his 2026-09-18), and ONLY THE
/// OCTET TRUSS OFFERED. Source pins: the wizard's lattice-stage captions go through
/// `captionLine`, which never wraps, and the type chips grey everything but octet.
final class LatticeWizardOneLineCaptionTests: XCTestCase {
    private var src: String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/TopOptFlows/LatticeSetupWizard.swift")
        return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }

    func testTheLatticeStageCaptionsAreOneLineEach() {
        let s = src
        XCTAssertTrue(s.contains("private func captionLine("), "the one-line caption helper exists")
        XCTAssertTrue(s.contains(".lineLimit(1)\n                .minimumScaleFactor(0.85)\n            if let detail { infoButton(id, detail) }"),
                      "★ the brief never wraps, and the (i) follows it only when there is a detail")
        // Every long caption he photographed is gone from the page body.
        for gone in ["An FEA decides every setting left on Sim.",
                     "The lattice varies across the part — how, below.",
                     "The density follows the solve and the cells fit the outline.",
                     "cell sizes available at this cell and bead.",
                     "One cell across a member. The run adds a Skin finish",
                     "Every density stays under the point where octet struts fuse",
                     "A finite-element solve grades every region "] {
            XCTAssertFalse(s.contains("Text(\"" + gone) || s.contains("? \"" + gone) || s.contains(": \"" + gone),
                           "★ still a paragraph on the page: \(gone)")
        }
        for brief in ["An FEA decides the Sim settings.", "The lattice varies across the part.",
                      "How far in the cells grade down to the outline.", "cell sizes available.",
                      "The solve picks the cell everywhere.", "Each region graded from its own stress."] {
            XCTAssertTrue(s.contains(brief), "★ the one-line brief is missing: \(brief)")
        }
    }

    func testOnlyTheOctetTrussIsOffered() {
        XCTAssertEqual(LatticeSetupWizard.offeredTypeIDs, ["octet"])
        let s = src
        XCTAssertTrue(s.contains(".disabled(organicOn || !offered)"), "★ a type not offered is disabled")
        XCTAssertTrue(s.contains("guard !organicOn, offered else { return }"), "★ …and a tap on it does nothing")
        XCTAssertTrue(LatticeType.family.count > 1, "the others stay VISIBLE (greyed), not removed")
    }
}
