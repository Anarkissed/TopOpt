import XCTest
import TopOptKit
@testable import TopOptFlows

/// ★★ MAINTAINER, 2026-10-03, item 5 ("one number, one source"): "the drawer's 'Cell 2.40 mm' and
/// the bake use the same member width (the measured one)". On 3418E167 the drawer said 2.40 mm
/// (12 mm declared / 5) about a face the bake laid at 12.00 mm on its measured 75 mm wall.
///
/// The bake's region cells and the drawer's now come out of ONE function
/// (`LatticeRegionCells.regionCells`); the card asks core for the density, strut and cells-across
/// AT the bake's cell and the measured wall (`lattice_region_derivation`'s stated cell).
@MainActor
final class LatticeDrawerCellIsTheBakesTests: XCTestCase {

    private static var sources: URL {
        var u = URL(fileURLWithPath: #filePath)
        for _ in 0..<3 { u.deleteLastPathComponent() }
        return u.appendingPathComponent("Sources/TopOptFlows")
    }
    private func src(_ f: String) throws -> String {
        try String(contentsOf: Self.sources.appendingPathComponent(f), encoding: .utf8)
    }

    /// Core's derivation at a STATED cell: the cell is the caller's, the density is the lightest
    /// that prints a bead at that cell, cells-across is the measured wall over it. 0 = derive,
    /// exactly as before (the control).
    func testCoreDerivesAtTheBakesCell() {
        let derived = TopOptKit.latticeRegionDerivation(topology: "octet", memberWidthMM: 12,
                                                        minExtrudableWidthMM: 0.45, cellsPerMemberFloor: 5)
        XCTAssertEqual(derived.cellMM, 2.4, accuracy: 1e-9, "control: 12 / 5 when no cell is stated")
        let atBake = TopOptKit.latticeRegionDerivation(topology: "octet", memberWidthMM: 75.38,
                                                       minExtrudableWidthMM: 0.45, cellsPerMemberFloor: 5,
                                                       cellMM: 12)
        XCTAssertTrue(atBake.valid && atBake.feasible)
        XCTAssertEqual(atBake.cellMM, 12, "★ the bake's cell, not a re-derivation")
        XCTAssertEqual(atBake.cellsPerMember, 75.38 / 12, accuracy: 1e-9, "★ across the MEASURED wall")
        XCTAssertGreaterThanOrEqual(atBake.strutMM + 1e-12, 0.45, "the density in force prints a bead")
        XCTAssertFalse(atBake.outOfRegime)
    }

    /// The card carries the bake's cell and, across a drawer's several regions, their span.
    func testTheCardSaysTheBakesCellAndSpan() {
        var c = LatticeFaceCardDerivation.card(faceID: 3, depthMM: 12, heldVoxels: 1000, spacingMM: 1,
                                               densityGCM3: 1.24, topologyID: "octet",
                                               minExtrudableWidthMM: 0.45, cellsPerMemberFloor: 5,
                                               memberWidthMM: 75.38, cellMM: 12)
        XCTAssertEqual(c.cellMM, 12)
        XCTAssertEqual(c.cellText, "12.00 mm")
        XCTAssertEqual(c.depthMM, 12, "the depth row keeps the declared depth")
        c.cellRangeMM = 4.667...12
        XCTAssertEqual(c.cellText, "4.67–12.00 mm", "a drawer over regions whose cells differ says so")
        // control: no bake ⇒ the declared depth and core's own derivation, as before
        let before = LatticeFaceCardDerivation.card(faceID: 3, depthMM: 12, heldVoxels: 1000, spacingMM: 1,
                                                    densityGCM3: 1.24, topologyID: "octet",
                                                    minExtrudableWidthMM: 0.45, cellsPerMemberFloor: 5)
        XCTAssertEqual(before.cellMM, 2.4, accuracy: 1e-9)
    }

    /// His two walls on 3418E167 (Structural, the stage floor 5), at the bake's own measured walls
    /// and cells (the renderer's DIAG regionCell lines, fresh copy of snapshot S1): what the drawer
    /// said before (declared depth / 5) and says now.
    func testHisTwoWallsOn3418E167() {
        let walls: [(face: Int, depth: Double, measured: Double, baked: Double)] = [
            (15, 14, 20.22270953655243, 14.0 / 3), (3, 12, 75.37555372714996, 12)]
        for w in walls {
            let before = LatticeFaceCardDerivation.card(faceID: w.face, depthMM: w.depth, heldVoxels: 1000, spacingMM: 1,
                                                        densityGCM3: 1.24, topologyID: "octet",
                                                        minExtrudableWidthMM: 0.45, cellsPerMemberFloor: 5)
            let after = LatticeFaceCardDerivation.card(faceID: w.face, depthMM: w.depth, heldVoxels: 1000, spacingMM: 1,
                                                       densityGCM3: 1.24, topologyID: "octet",
                                                       minExtrudableWidthMM: 0.45, cellsPerMemberFloor: 5,
                                                       memberWidthMM: w.measured, cellMM: w.baked)
            print("DRAWER face \(w.face): before cell \(before.cellText) density \(before.densityText) strut \(before.strutText) "
                  + "across \(before.cellsText) \(before.verdict) | after cell \(after.cellText) density \(after.densityText) "
                  + "strut \(after.strutText) across \(after.cellsText) \(after.verdict)")
            XCTAssertEqual(before.cellMM, w.depth / 5, accuracy: 1e-9, "before: the declared depth over 5")
            XCTAssertEqual(after.cellMM, w.baked, "★ after: the bake's cell")
            XCTAssertEqual(after.cellsPerMember, w.measured / w.baked, accuracy: 1e-9)
        }
    }

    /// The wiring, from the source: one function feeds the bake and the drawer, the card is built
    /// at the bake's width and cell, and the cards follow the final picture.
    func testOneFunctionFeedsTheBakeAndTheDrawer() throws {
        let cells = try src("LatticeRegionCells.swift")
        XCTAssertTrue(cells.contains("widthPercentile: widthPercentile, quiltStep: quiltStep).map(\\.cellMM)"),
                      "★ cellsMM (the bake's) IS regionCells' cells")
        XCTAssertTrue(cells.contains("let derived = regionCells(project: project, scene: scene, regions: regions,\n                                  widthPercentile: 0.5, quiltStep: true)"),
                      "the drawer reads the stepped bake's own inputs (p50, the quilt step)")
        let ws = try src("WorkspacePlaceholder.swift")
        XCTAssertTrue(ws.contains("let baked = LatticeRegionCells.selectableCells(project: project, scene: strutScene)"))
        XCTAssertTrue(ws.contains("memberWidthMM: bakedCopy[i]?.measuredWidthMM,\n                    cellMM: bakedCopy[i]?.cellMM)"))
        XCTAssertTrue(ws.contains("if isLastStage, Self.perRegionCellAlgorithms.contains(project.lattice.algorithm) {\n                    refreshLatticeFaceCards()"),
                      "★ the cards are re-derived when the bake lands")
    }
}
