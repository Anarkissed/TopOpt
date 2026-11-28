// Notes30CellAdviceTests — ★ notes30 X2, cell advice (362's follow-up to X2's finding, 11-26): advice never names a cell under
// the smallest cell the current settings lay — 4.74 mm with Allow quilt off (two 0.45 mm lines over the open look), the type's
// own quilt cell with it on (octet 2.55 mm). Where no smaller cell can lay, it gives the "This needs … cells" pop-up's fixes
// instead (Allow quilt where it lays, Aesthetic where it lays, Leave it solid). Swept: the triangle's card
// (LatticeFaceDiagnosis), the solid pop-up's wall reasons (core's own "what is there" now rides the map: SolidWhy::have_mm), the
// Lattice page's thin-wall pop-up hint (LatticeThinWallPrompt.cellLine). RED CONTROL everywhere: `controlSmallerCellsAlways`,
// release 21's words. The three offers themselves are unchanged (Notes30A1OffersTests).
#if canImport(AppKit) && canImport(MetalKit)
import XCTest
import simd
@testable import TopOptFlows
@testable import TopOptKit

@MainActor
final class Notes30CellAdviceTests: XCTestCase {
    override func tearDown() { SolidReason.controlSmallerCellsAlways = false; super.tearDown() }

    /// The smallest cells of his pad's settings: 4.74 mm laid, 2.55 mm with Allow quilt (octet), Aesthetic's 2 across.
    static let floors = SolidReason.Depth(depthMM: 0, cellsAcross: 5, floorCellMM: 4.7418, quiltFloorCellMM: 2.5456,
                                          aestheticCellsAcross: 2, allowQuiltOn: false)

    /// A face card: its wall `thick` mm through, `cell` mm cells.
    static func card(thick: Double, cell: Double, strut: Double = 0.9) -> LatticeFaceCard {
        LatticeFaceCard(faceID: 1, depthMM: thick, heldVoxels: 100, heldVolumeMM3: 100, heldMassG: 1, cellMM: cell,
                        relativeDensity: 0.2, strutDiameterMM: strut, cellsPerMember: thick / cell, verdict: .outOfRegime)
    }

    /// ★ The triangle's card on his pad 8 mm deep (3.6 cells of 2.22 mm across, 5 asked): no smaller cell is named (1.6 mm is
    /// under 4.74 mm); the depth is the one whose cells lay (23.8 mm, not 11.1); Leave it solid is its fix (Allow quilt's
    /// 2.55 mm and Aesthetic's 2 cells of 4 mm do not fit 8 mm). At 20 mm deep with 4.4 mm cells: Allow quilt and Aesthetic
    /// lay it, so both, then Leave it solid — the pop-up's own three. A bigger cell for a too-thin strut is never under the
    /// smallest either. Where a smaller cell lays (a 30 mm wall: 6 mm), it is named as before. RED CONTROL: release 21's words.
    func testTheTrianglesCardNeverNamesACellUnderTheSmallest() throws {
        let eight = LatticeFaceDiagnosis.of(card: Self.card(thick: 8, cell: 8 / 3.6), cellsPerMemberFloor: 5, nozzleWidthMM: 0.45,
                                            cells: Self.floors)
        let p8 = try XCTUnwrap(eight.problems.first)
        print("NOTES30-X2 ADVICE 8 mm: \(p8.fixes)")
        XCTAssertFalse(p8.fixes.contains { $0.contains("smaller cell") }, "★ never 1.6 mm cells")
        XCTAssertEqual(p8.fixes.first, "Make it deeper: 23.8 mm.", "★ the depth whose cells lay")
        XCTAssertEqual(p8.fixes.last, "Or leave it solid.")
        XCTAssertEqual(eight.changes.map(\.title), ["Leave it solid"], "★ the pop-up's fix that does something here")
        XCTAssertEqual(eight.changes.first?.offer, .leaveSolid)

        let twenty = LatticeFaceDiagnosis.of(card: Self.card(thick: 20, cell: 4.4), cellsPerMemberFloor: 5, nozzleWidthMM: 0.45,
                                             cells: Self.floors)
        print("NOTES30-X2 ADVICE 20 mm: \(twenty.problems.first?.fixes ?? [])")
        XCTAssertEqual(twenty.changes.map(\.title), ["Turn Allow quilt on", "Switch to Aesthetic", "Leave it solid"],
                       "★ the pop-up's own three where both lay")
        XCTAssertTrue(twenty.popoverText.contains("Or turn Allow quilt on: cells may then be as small as 2.55 mm."))
        XCTAssertTrue(twenty.popoverText.contains("Or switch to Aesthetic: it needs 2 cells across."))

        let thirty = LatticeFaceDiagnosis.of(card: Self.card(thick: 30, cell: 8), cellsPerMemberFloor: 5, nozzleWidthMM: 0.45,
                                             cells: Self.floors)
        XCTAssertTrue(thirty.popoverText.contains("Or use a smaller cell: 6.0 mm."), "★ named where it lays")
        XCTAssertEqual(thirty.changes.first?.tryText, "Try 6.0 mm cells")

        let thin = LatticeFaceDiagnosis.of(card: Self.card(thick: 60, cell: 2, strut: 0.3), cellsPerMemberFloor: 5,
                                           nozzleWidthMM: 0.45, cells: Self.floors)
        XCTAssertTrue(thin.popoverText.contains("Or use a bigger cell: 4.8 mm."), "★ a bigger cell, never under the smallest (3.0)")

        // RED CONTROL: release 21's words
        SolidReason.controlSmallerCellsAlways = true
        let old = LatticeFaceDiagnosis.of(card: Self.card(thick: 8, cell: 8 / 3.6), cellsPerMemberFloor: 5, nozzleWidthMM: 0.45,
                                          cells: Self.floors)
        XCTAssertTrue(old.popoverText.contains("Or use a smaller cell: 1.6 mm."), "RED CONTROL: release 21's cell under 4.74 mm")
        XCTAssertTrue(old.popoverText.contains("Make it deeper: 11.2 mm."), "RED CONTROL: a depth of cells that never lay")
        XCTAssertEqual(old.changes.first?.tryText, "Try 1.6 mm cells")
    }

    /// ★ The solid pop-up's wall reasons (Aesthetic; Structural's go to the thin-wall pop-up): with core's own "what is there"
    /// (a 3 mm wall; a 6 mm member asked for 2 cells: 3 mm each), under the smallest cell, the words say what the wall holds
    /// and where cells start — never "use smaller cells" — and the fixes end with Leave it solid. A wall a smaller cell fits
    /// keeps the words as before. RED CONTROL: release 21's "Use smaller cells".
    func testTheSolidPopUpsWallsNeverSaySmallerCellsWhereNoneLays() throws {
        var ae = LatticeSettings()
        ae.stageMode = .aesthetic
        var t = Self.floors; t.cellsAcross = 2
        let narrow = try XCTUnwrap(SolidReason.of(share: 1, nocell: [0, 40, 0, 0, 0], lattice: ae, depth: t,
                                                  haveMM: [0, 3, 0, 0, 0]))
        let text = SolidPopUp.text(narrow, lattice: ae)
        print("NOTES30-X2 ADVICE wall: \(SolidPopUp.title(narrow)) — \(text.replacingOccurrences(of: "\n", with: " ")) \(narrow.fixes)")
        XCTAssertFalse(text.contains("smaller cells"), "★ never the advice that cannot help")
        XCTAssertTrue(text.contains("A wall there is 3 mm thick.") && text.contains("cells start at 4.74 mm"), "★ the numbers")
        XCTAssertEqual(narrow.fixes.last, .leaveSolid, "★ the pop-up's Leave it solid")
        XCTAssertEqual(narrow.fixes.first, .letWallsCutCells, "the wall's own fix first, as before")
        XCTAssertEqual(SolidPopUp.title(narrow), "This needs 1.5 mm cells", "a 3 mm wall in the 2 cells its lattice asks")   // ★ RE-PINNED (X2, Small cells first): core divides a wall into its cells across
        XCTAssertNotNil(SolidPopUp.offersWhy(narrow), "its (i)")

        let few = try XCTUnwrap(SolidReason.of(share: 1, nocell: [0, 0, 40, 0, 0], lattice: ae, depth: t, haveMM: [0, 0, 6, 0, 0]))
        XCTAssertTrue(SolidPopUp.text(few, lattice: ae).contains("It is 6 mm across, room for 2 cells of 3 mm."))
        XCTAssertFalse(SolidPopUp.text(few, lattice: ae).contains("smaller cells"))

        let wide = try XCTUnwrap(SolidReason.of(share: 1, nocell: [0, 0, 40, 0, 0], lattice: ae, depth: t, haveMM: [0, 0, 12, 0, 0]))
        XCTAssertTrue(SolidPopUp.text(wide, lattice: ae).contains("Use smaller cells"), "★ 6 mm cells lay: said as before")

        SolidReason.controlSmallerCellsAlways = true
        let old = try XCTUnwrap(SolidReason.of(share: 1, nocell: [0, 40, 0, 0, 0], lattice: ae, depth: t, haveMM: [0, 3, 0, 0, 0]))
        XCTAssertTrue(SolidPopUp.text(old, lattice: ae).contains("Use smaller cells"), "RED CONTROL: release 21's words")
    }

    /// ★ The Lattice page's thin-wall pop-up: "a smaller cell may lattice some of them" only where one can (a Swept range whose
    /// smallest is above the smallest laid: core divides a wall down to that whatever cell is typed); with a typed cell and
    /// 3 mm walls, the pop-up's Allow quilt instead (2.55 mm fits 3 mm); with 2 mm walls, nothing. RED CONTROL: release 21
    /// said the hint for every cell set by hand.
    func testTheThinWallHintOnlyWhereASmallerCellLays() {
        var fixed = LatticeSettings(); fixed.cellSizeMode = .fixed; fixed.cellMM = 8
        var swept = LatticeSettings(); swept.cellSizeMode = .swept; swept.cellMinMM = 6
        var walls = Self.floors; walls.depthMM = 3; walls.cellsAcross = 1
        XCTAssertEqual(LatticeThinWallPrompt.cellLine(swept, cells: walls), LatticeThinWallPrompt.manualHint, "★ Swept from 6 mm: lower it")
        XCTAssertEqual(LatticeThinWallPrompt.cellLine(fixed, cells: walls), LatticeThinWallPrompt.quiltHint(walls),
                       "★ a typed cell: the pop-up's Allow quilt")
        XCTAssertTrue(LatticeThinWallPrompt.quiltHint(walls).contains("2.55 mm"))
        var two = walls; two.depthMM = 2
        XCTAssertNil(LatticeThinWallPrompt.cellLine(fixed, cells: two), "★ nothing lays 2 mm walls: no cell line")
        XCTAssertLessThanOrEqual(LatticeCaptions.words("Turn Allow quilt on"), 5)
        SolidReason.controlSmallerCellsAlways = true
        XCTAssertEqual(LatticeThinWallPrompt.cellLine(fixed, cells: two), LatticeThinWallPrompt.manualHint,
                       "RED CONTROL: release 21's hint for any cell set by hand")
    }

    /// ★ The smallest cell the part's settings lay, read as core reads it (his pad: 4.74 mm on Auto; Manual with Allow quilt
    /// on, 2.55 mm), and core's "what is there" riding the map (his pad's 20 mm region, the reason's own depth).
    func testTheFloorAndCoresWhatIsThere() async throws {
        let r = try FlexiblePressFixtures.a1Project(3, self, facePrism: true)
        let p = r.project
        p.lattice.flexible = nil
        p.lattice.chooseLatticeType(.structural)
        p.latticePageManual = false; p.lattice.allowQuilt = true
        let auto = try XCTUnwrap(LatticeLayoutPreview.cellFloor(p))
        XCTAssertEqual(auto.floorCellMM, 4.742, accuracy: 0.001, "★ Auto never quilts: 4.74 mm")
        XCTAssertEqual(auto.quiltFloorCellMM, 2.546, accuracy: 0.001)
        p.latticePageManual = true
        XCTAssertEqual(try XCTUnwrap(LatticeLayoutPreview.cellFloor(p)).floorCellMM, 2.546, accuracy: 0.001, "★ Manual, Allow quilt on")
        p.lattice.allowQuilt = false

        let session = try await LatticeLayoutSession.open(path: try XCTUnwrap(p.importedFile?.path))
        addTeardownBlock { session.close() }
        let s = LatticeLayoutPreview.settings(p)
        let laid = try await session.lay(s)
        XCTAssertEqual(laid.floorCellMM, auto.floorCellMM, accuracy: 1e-6, "★ the same smallest cell as core's lay")
        let box = try XCTUnwrap(LatticeLayoutPreview.box(p.importedMesh?.vertices ?? []))
        let report = try await LatticeLayoutPreview.unheldReport(session, box)
        let rep = try XCTUnwrap(report)
        print("NOTES30-X2 ADVICE map: by reason \(rep.nocell), what is there \(rep.haveMM)")
        XCTAssertEqual(rep.haveMM.count, 5)
        XCTAssertEqual(rep.haveMM[SolidReason.Cause.regionShallow.rawValue], 20, accuracy: 0.05, "★ core's own: the 20 mm region")
    }
}
#endif
