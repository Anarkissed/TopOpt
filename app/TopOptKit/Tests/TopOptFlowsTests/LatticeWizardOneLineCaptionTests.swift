import XCTest
@testable import TopOptFlows

/// ★★ ONE LINE PER CAPTION, THE REST BEHIND THE (i) (his 2026-09-18), and ONLY THE
/// OCTET TRUSS OFFERED. Source pins: the wizard's lattice-stage captions go through
/// `captionLine`, which never wraps, and only the offered types (octet today) are on the page.
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
        // ★ re-pinned 11-10 (his iPad note img04/05): the band's line is shorter, under Band (IPadNotes1110Tests)
        // ★ RE-PINNED (notes29, his 11-25: "about 5 words below ANY setting, with an (i)"): the briefs are five words, named
        // in LatticeCaptions.swift (Notes29UITests holds every one to five)
        for brief in [LatticeSetupWizard.simOnLine, LatticeSetupWizard.gradeOnLine, LatticeSetupWizard.shapeBand.brief,
                      LatticeSetupWizard.autoCellLine, LatticeSetupWizard.densityByStressLine] {
            XCTAssertLessThanOrEqual(LatticeCaptions.words(brief), 5, "★ \(brief)")
        }
        XCTAssertTrue(s.contains("cell sizes available."), "★ the band's steps line")
        for named in ["Self.simOnLine", "Self.gradeOnLine", "Self.autoCellLine", "Self.densityByStressLine"] {
            XCTAssertTrue(s.contains(named), "★ the one-line brief is missing: \(named)")
        }
    }

    /// ★ Re-pinned for lattice types U1 (2026-10-01): the offered set is CORE's (build ∩ certify ∩
    /// the job parser) — the octet alone today, exactly as his 2026-09-18 ruling had it, now lifted
    /// type by type (M8). A type not offered still never selects: its tap only says why.
    /// ★ RE-PINNED (notes28, the maintainer's decision 2026-11-24: all the strut types): the octet is no longer the only one —
    /// every strut type the old run builds is offered (the Lattice stage reads the new engine's catalog, which adds the
    /// Structural rules — LatticeCellTypesNotes28Tests). Still pinned: a type the stage can't use is drawn only greyed with
    /// its sentence, never picked, and a saved one says why under the row.
    func testEveryStrutTypeTheRunBuildsIsOffered() {
        // ★ RE-PINNED (362, his 11-25 "Sure"): `offeredTypeIDs` is the OLD run's catalog (octet only until it moves to the new
        // engine); the Lattice stage on a STEP part reads the new engine's (LatticeCellTypesNotes28Tests)
        XCTAssertEqual(LatticeSetupWizard.offeredTypeIDs, ["octet"])
        let s = src
        // ★ RE-PINNED (B7 slice 2, plan.md §B7 Type, LS-1 / LS-19): a type not offered is not on the page at all, so it
        // can't be selected; a SAVED type core can't run still says why under the row.
        XCTAssertTrue(s.contains("let offered = entries.filter(\\.offered)") && s.contains("ForEach(shown)")
                      && s.contains("guard e.offered else { typeReason = LatticeTypeCatalog.line(e); return }"),
                      "★ only offered types can be picked; the rest are drawn greyed, if at all")
        XCTAssertTrue(s.contains("if let why = typeReason ?? stale {"), "★ a saved type core can't run says why")
        let bccz = LatticeTypeCatalog.entriesFromCore().first { $0.id == "bccz" }!
        XCTAssertEqual(LatticeTypeCatalog.reasonLine(bccz), "BCC + Z: Not buildable or strength-checked yet", "…in one sentence")
        LatticeTypeCatalog.appBatchesForTests = ["octet"]   // RED CONTROL: behind the old gate BCC waited for its batch
        defer { LatticeTypeCatalog.appBatchesForTests = nil }
        let bcc = LatticeTypeCatalog.entriesFromCore().first { $0.id == "bcc" }!
        XCTAssertEqual(LatticeTypeCatalog.reasonLine(bcc), "BCC: \(LatticeTypeCatalog.appBatchPending)")
        // Organic hides the cards — except the offered card that fixes a saved type core can't run
        // (review 2026-10-01, `LatticeStaleTypeTests`)
        XCTAssertTrue(s.contains("if !organicOn || stale != nil {"), "only Organic hides the cards, never the stale fix")
        XCTAssertTrue(LatticeTypeCatalog.order.count > 1, "the catalog keeps every type; the page shows the offered ones")
    }
}
