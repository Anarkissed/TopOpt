import XCTest
import TopOptKit
@testable import TopOptFlows

/// ★★ REVIEWER, 2026-10-05, Q2 (approved by the maintainer): "A type core doesn't call live gets
/// no band. Show core's readiness words where the band was, not a blank."
///
/// Since the bridge guard (c4cf899e) `lattice_limits` gives a non-live type NO numbers. Every place
/// that drew a band, or a readout that hangs on one, now shows the picker's one sentence for the
/// condition — "Kelvin: Strength-checked, but not buildable yet" — and the octet, the control, keeps
/// its band.
@MainActor
final class LatticeTypeNoBandTests: XCTestCase {

    private static var sources: URL {
        var u = URL(fileURLWithPath: #filePath)
        for _ in 0..<3 { u.deleteLastPathComponent() }
        return u.appendingPathComponent("Sources/TopOptFlows")
    }
    private func src(_ f: String) throws -> String {
        try String(contentsOf: Self.sources.appendingPathComponent(f), encoding: .utf8)
    }

    /// A type core certifies but cannot build, and one it does neither — core's words, once, with
    /// the type's name; never the id quoted again, never the app's own "certifies, but…" first.
    func testTheReasonIsCoresSentenceWithTheNameOnce() throws {
        let certifiable = TopOptKit.latticeCertifiableTopologies
        let generatable = Set(TopOptKit.latticeGeneratableTopologies)
        let certOnly = try XCTUnwrap(certifiable.first { !generatable.contains($0) }, "no certify-only type on this core")
        for (id, words) in [(certOnly, TopOptKit.latticeTypeReadinessPlain(.notGeneratable)),
                            ("bccz", TopOptKit.latticeTypeReadinessPlain(.notEither))] {
            let s = LatticeSettings(enabled: true, topologyID: id)
            let limits = TopOptKit.latticeLimits(topology: id)
            XCTAssertFalse(limits.certifiable, "no band for \(id)")
            let b = LatticeBounds.compute(settings: s, limits: limits,
                                          generatable: generatable.contains(id))
            let name = LatticeType.displayName(forID: id)
            XCTAssertEqual(b.topologyReason, "\(name): \(words)", "★ the picker's sentence for \(id)")
            XCTAssertEqual(b.topologyReason, LatticeTypeCatalog.selectionRefusal(id),
                           "★ one sentence for the condition, wherever it shows (\(id))")
            XCTAssertFalse(b.topologyReason!.contains("\"\(id)\""), "the id is not quoted a second time")
        }
        // control: the octet has a band and no reason
        let o = LatticeBounds.compute(settings: LatticeSettings(enabled: true, topologyID: "octet"),
                                      limits: TopOptKit.latticeLimits(topology: "octet"))
        XCTAssertNil(o.topologyReason)
        XCTAssertTrue(o.certifiable)
    }

    /// The variant page's Optimize line leads with core's words, not the app's generator line
    /// (wrong for BCCZ, which core neither builds nor certifies).
    func testOptimizeSaysCoresWordsFirst() throws {
        let page = try src("LatticePageModel.swift")
        XCTAssertTrue(page.contains("let why = b.topologyReason ?? b.generatableReason ?? b.cellReason"))
        XCTAssertFalse(page.contains("let why = b.generatableReason ?? b.topologyReason"))
    }

    /// The stage drawer: core's sentence leads, and no row shows a cell, density, strut or count
    /// that only the band could give. A live type's drawer is unchanged (the control).
    func testTheDrawerLeadsWithCoresWordsAndDrawsNoBandRows() {
        let card = LatticeFaceCard(faceID: 1, depthMM: 12, heldVoxels: 900,
                                   heldVolumeMM3: 4_000, heldMassG: 5, cellMM: 2.4,
                                   relativeDensity: 0.2, strutDiameterMM: 0.5,
                                   cellsPerMember: 5, verdict: .certified)
        let line = "Kelvin: Strength-checked, but not buildable yet"
        let d = LatticeRegionDrawer.make(card: card, depthMM: 12, held: false, typeRefusal: line)
        XCTAssertEqual(d.headline?.text, line, "★ core's words where the band was")
        let labels = d.rows.map(\.label)
        for gone in ["Cell", "Density", "Strut", "Cells across", "As lattice", "Saved"] {
            XCTAssertFalse(labels.contains(gone), "no \(gone) without a band")
        }
        XCTAssertTrue(labels.contains("Depth"), "the depth stays his control")
        // control: no refusal ⇒ the drawer as before
        let live = LatticeRegionDrawer.make(card: card, depthMM: 12, held: false)
        XCTAssertNotEqual(live.headline?.text, line)
        XCTAssertTrue(live.rows.map(\.label).contains("Cell"))
        // and a face the run does not lattice says so, whatever the type — batch E's two words (#362
        // review, ported 2026-10-08: never "Frozen"; the group's shield already says Protected)
        let frozen = LatticeRegionDrawer.make(card: card, depthMM: 12, held: false,
                                              latticeReachesTheRun: false, typeRefusal: line)
        XCTAssertEqual(frozen.headline?.text, "Not latticed")
    }

    /// Where each band was drawn, the sentence now is — read from the views' own source.
    func testEveryBandSiteShowsTheSentence() throws {
        let page = try src("LatticePage.swift")
        XCTAssertTrue(page.contains("if limits.certifiable { miniBand } else if let t = typeLine {"),
                      "★ the Cell & density row: core's words where the mini band was")
        XCTAssertFalse(page.contains("No certifiable band — core carries no tensor"),
                       "★ the old line was false for Kelvin (core certifies it)")
        XCTAssertTrue(page.contains("Text(typeLine ?? \"\")"), "the density card")
        XCTAssertTrue(page.contains("if let t = typeLine {"), "sector density: the sentence, not per-region refusals")
        XCTAssertTrue(page.contains("summaryRow(\"Topology\", typeLine ??"), "the Review row")
        let ws = try src("WorkspacePlaceholder.swift")
        XCTAssertTrue(ws.contains("typeRefusal: latticeTypeRefusal)"), "the stage drawer")
        let wiz = try src("LatticeSetupWizard.swift")
        XCTAssertTrue(wiz.contains("} else if let why = LatticeTypeCatalog.selectionRefusal(model.topologyID) {"),
                      "the wizard's thickness range hangs on the band")
    }
}
