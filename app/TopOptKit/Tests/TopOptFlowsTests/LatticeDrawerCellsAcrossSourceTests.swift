import XCTest
@testable import TopOptFlows

/// ★★ RULING A (reviewer, 2026-10-08, approved by the maintainer), until core's fast layout check
/// lands: "Fit shows core's exact count (lattice_region_derivation); Stepped and Default Grade show
/// the measured estimate, labelled 'estimate, core checks it'; organic shows '—'."
final class LatticeDrawerCellsAcrossSourceTests: XCTestCase {

    private func card(_ source: LatticeFaceCard.CellsAcrossSource, cells: Double = 5,
                      verdict: LatticeFaceCard.Verdict = .certified) -> LatticeFaceCard {
        var c = LatticeFaceCard(faceID: 1, depthMM: 12, heldVoxels: 900, heldVolumeMM3: 4_000, heldMassG: 5,
                                cellMM: 2.4, relativeDensity: 0.2, strutDiameterMM: 0.5,
                                cellsPerMember: cells, verdict: verdict)
        c.cellsAcrossSource = source
        return c
    }
    private func row(_ d: LatticeRegionDrawer) throws -> LatticeDrawerRow {
        try XCTUnwrap(d.rows.first { $0.label == "Cells across" })
    }

    func testCoreEstimateAndOrganicEachSayWhoseNumberItIs() throws {
        let core = try row(LatticeRegionDrawer.make(card: card(.core), depthMM: 12, held: false))
        XCTAssertEqual(core.value, "5.0"); XCTAssertNil(core.note, "★ core's count, plainly")
        let est = try row(LatticeRegionDrawer.make(card: card(.estimate), depthMM: 12, held: false))
        XCTAssertEqual(est.value, "5.0")
        XCTAssertEqual(est.note, "estimate, core checks it", "★ the ruling's words")
        let org = try row(LatticeRegionDrawer.make(card: card(.none), depthMM: 12, held: false))
        XCTAssertEqual(org.value, "—", "★ organic: no octet count")
        XCTAssertNil(org.note)
        // an estimate with nothing to estimate says nothing more
        XCTAssertNil(try row(LatticeRegionDrawer.make(card: card(.estimate, cells: 0), depthMM: 12, held: false)).note)
    }

    func testAnOutOfRegimeHeadlineSaysWhoseNumberItIs() {
        func head(_ s: LatticeFaceCard.CellsAcrossSource) -> String? {
            LatticeRegionDrawer.make(card: card(s, cells: 2.1, verdict: .outOfRegime), depthMM: 12, held: false).headline?.text
        }
        XCTAssertEqual(head(.core), "2.1 cells across")
        XCTAssertEqual(head(.estimate), "2.1 cells across (estimate)")
        XCTAssertNil(head(.none), "organic: no octet verdict on the headline")
    }

    /// The card is told its source where it is built: organic ⇒ none; a bake's wall and cell ⇒ an
    /// estimate; else core's own derivation.
    func testTheCardIsToldItsSourceWhereItIsBuilt() throws {
        var u = URL(fileURLWithPath: #filePath); for _ in 0..<3 { u.deleteLastPathComponent() }
        let ws = try String(contentsOf: u.appendingPathComponent("Sources/TopOptFlows/WorkspacePlaceholder.swift"), encoding: .utf8)
        XCTAssertTrue(ws.contains("let organicCards = project.lattice.algorithm == \"organic\""))
        XCTAssertTrue(ws.contains("card.cellsAcrossSource = organicCards ? .none : (bakedCopy[i] != nil ? .estimate : .core)"))
        XCTAssertTrue(ws.contains("if let note = row.note {"), "★ the note is drawn")
    }
}
