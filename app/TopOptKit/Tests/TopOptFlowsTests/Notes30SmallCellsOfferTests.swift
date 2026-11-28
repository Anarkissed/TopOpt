// Notes30SmallCellsOfferTests — ★ notes30 X2, his answer (11-26): YES — the "This needs … cells" pop-up offers "Small cells in
// thin walls" FIRST, ahead of Allow quilt on, Switch to Aesthetic and Leave it solid (X2's finding: with Allow quilt off it lays
// his pad exactly — 4 mm cells, 0.90 mm struts, never touching — and only where a wall needs it). Five words, 44 pt, shown only
// where it lays (core's thin_floor_cell_mm: the thinnest strut and one printed line of air over the type's touch, octet
// 3.82 mm), turning its own switch on (Manual's, as Allow quilt: Auto lays neither), its (i) first in plain words. RED CONTROL
// `controlThreeOffers`: release 22's three. The page: Notes30A1OffersHostedTests.
#if canImport(AppKit) && canImport(MetalKit)
import XCTest
import simd
@testable import TopOptFlows
@testable import TopOptKit

@MainActor
final class Notes30SmallCellsOfferTests: XCTestCase {
    override func tearDown() {
        SolidReason.controlThreeOffers = false
        AppPopups.shared.current = nil
        super.tearDown()
    }

    /// His pad's numbers, with Small cells in thin walls' smallest cell (octet, two 0.45 mm lines and one of air: 3.82 mm).
    static let hisPad = SolidReason.Depth(depthMM: 20, cellsAcross: 5, floorCellMM: 4.7418, quiltFloorCellMM: 2.5456,
                                          aestheticCellsAcross: 2, allowQuiltOn: false, thinFloorCellMM: 3.8184, smallCellsOn: false)

    /// ★ Small cells in thin walls first where it lays (his pad: 4 mm ≥ 3.82 mm), then Allow quilt, Aesthetic and Leave it solid;
    /// never where it does not (17.5 mm: 3.5 mm cells), nor when it is on already or Allow quilt is on (core lays it only with
    /// Allow quilt off). Its (i) says it first, in plain words. RED CONTROL: release 22's three.
    func testSmallCellsFirstWhereItLays() throws {
        var st = LatticeSettings(); st.stageMode = .structural
        let nocell = [0, 0, 0, 0, 40]
        let r = try XCTUnwrap(SolidReason.of(share: 1, nocell: nocell, lattice: st, depth: Self.hisPad))
        XCTAssertEqual(r.fixes, [.smallCells, .allowQuilt, .switchToAesthetic, .leaveSolid], "★ Small cells first, Leave it solid last")
        XCTAssertEqual(r.fixes.first?.title, "Small cells in thin walls")
        for f in r.fixes { XCTAssertLessThanOrEqual(LatticeCaptions.words(f.title), 5, "★ five words: \(f.title)") }
        let why = try XCTUnwrap(SolidPopUp.offersWhy(r))
        print("NOTES30-X2 SMALL (i): \(why.replacingOccurrences(of: "\n", with: " "))")
        XCTAssertTrue(why.hasPrefix("Small cells in thin walls:"), "★ its (i) first")
        XCTAssertTrue(why.contains("4 mm cells it needs") && why.contains("3.82 mm") && why.contains("never touch"))
        XCTAssertTrue(why.contains("Allow quilt stays off"), "★ its own switch")

        var shallow = Self.hisPad; shallow.depthMM = 17.5   // 3.5 mm cells: under 3.82 mm
        let s = try XCTUnwrap(SolidReason.of(share: 1, nocell: nocell, lattice: st, depth: shallow))
        XCTAssertFalse(s.fixes.contains(.smallCells), "★ never where it does not lay")
        XCTAssertEqual(s.fixes.first, .allowQuilt)
        var on = Self.hisPad; on.smallCellsOn = true
        XCTAssertFalse(try XCTUnwrap(SolidReason.of(share: 1, nocell: nocell, lattice: st, depth: on)).fixes.contains(.smallCells),
                       "on already: not offered again")

        SolidReason.controlThreeOffers = true
        XCTAssertEqual(try XCTUnwrap(SolidReason.of(share: 1, nocell: nocell, lattice: st, depth: Self.hisPad)).fixes,
                       [.allowQuilt, .switchToAesthetic, .leaveSolid], "RED CONTROL: release 22's three")
    }

    /// ★ The pop-up as raised: three offers as its 44 pt buttons and Leave it solid its last word (it closes, changing nothing);
    /// the triangle's card and the thin-wall pop-up say Small cells first too. RED CONTROL: release 22's.
    func testThePopUpTheCardAndTheThinWallLine() {
        let card = LatticeFaceCard(faceID: 1, depthMM: 20, heldVoxels: 100, heldVolumeMM3: 100, heldMassG: 1, cellMM: 4.4,
                                   relativeDensity: 0.2, strutDiameterMM: 0.9, cellsPerMember: 20 / 4.4, verdict: .outOfRegime)
        var floors = Self.hisPad; floors.depthMM = 0
        let d = LatticeFaceDiagnosis.of(card: card, cellsPerMemberFloor: 5, nozzleWidthMM: 0.45, cells: floors)
        XCTAssertEqual(d.changes.map(\.title), ["Small cells in thin walls", "Turn Allow quilt on", "Switch to Aesthetic"],
                       "★ the card's buttons, Small cells first")
        XCTAssertTrue(d.popoverText.contains("Or turn Small cells in thin walls on: cells may then be as small as 3.82 mm."))
        XCTAssertTrue(d.popoverText.contains("Or leave it solid."), "Leave it solid is said (a tap anywhere does it)")
        var fixed = LatticeSettings(); fixed.cellSizeMode = .fixed; fixed.cellMM = 8
        var walls = floors; walls.depthMM = 20
        XCTAssertEqual(LatticeThinWallPrompt.cellLine(fixed, cells: walls), LatticeThinWallPrompt.smallCellsHint(walls),
                       "★ the thin-wall pop-up's line: Small cells first")
        SolidReason.controlThreeOffers = true
        let old = LatticeFaceDiagnosis.of(card: card, cellsPerMemberFloor: 5, nozzleWidthMM: 0.45, cells: floors)
        XCTAssertEqual(old.changes.map(\.title), ["Turn Allow quilt on", "Switch to Aesthetic", "Leave it solid"], "RED CONTROL")
        XCTAssertEqual(LatticeThinWallPrompt.cellLine(fixed, cells: walls), LatticeThinWallPrompt.quiltHint(walls), "RED CONTROL")
    }

    /// ★ MEASURED on his pad (core laying it as the preview does): his settings read 3.82 mm as Small cells' smallest; the
    /// offer's tap turns its own switch on (Manual; Allow quilt stays off) and the pad lays — every cell 4 mm, struts 0.90 mm,
    /// none touching, none solid. At 17.5 mm deep (3.5 mm cells) Small cells lays nothing: it is not offered there.
    func testItsTapLaysHisPadAndOnlyWhereItLays() async throws {
        let r = try FlexiblePressFixtures.a1Project(3, self, facePrism: true)
        let p = r.project
        p.lattice.flexible = nil
        p.lattice.chooseLatticeType(.structural)
        p.latticePageManual = false
        let f = try XCTUnwrap(LatticeLayoutPreview.cellFloor(p))
        XCTAssertEqual(f.thinFloorCellMM, 3.818, accuracy: 0.001, "★ Small cells' smallest, core's thin floor")
        let session = try await LatticeLayoutSession.open(path: try XCTUnwrap(p.importedFile?.path))
        addTeardownBlock { session.close() }
        let box = try XCTUnwrap(LatticeLayoutPreview.box(p.importedMesh?.vertices ?? []))
        let auto = LatticeLayoutPreview.settings(p)
        let none = try await session.lay(auto)
        let ask = try XCTUnwrap(LatticeLayoutPreview.depthAsk(auto, lattice: p.lattice, floorCellMM: none.floorCellMM))
        let reason = try XCTUnwrap(SolidReason.of(share: 1, nocell: [0, 0, 0, 0, 9], lattice: p.lattice, depth: ask))
        XCTAssertEqual(reason.fixes.first, .smallCells, "★ offered first on his pad")

        SolidReason.take(.smallCells, on: p)
        XCTAssertTrue(p.latticePageManual && p.lattice.smallCellsInThinWalls && !p.lattice.allowQuilt, "★ its own switch, Manual")
        let s = LatticeLayoutPreview.settings(p)
        XCTAssertTrue(s.smallCellsInThinWalls && !s.allowQuilt, "★ the lay reads it")
        let laid = try await session.lay(s)
        let solidNow = try await LatticeLayoutPreview.unheldReport(session, box)
        let seen = Notes30A1OffersTests.seen(laid, line: s.beadMM, solid: solidNow?.share ?? 0)
        print("NOTES30-X2 SMALL his pad: \(seen)")
        XCTAssertGreaterThan(seen.cells, 0, "★ it lays his pad")
        XCTAssertEqual(seen.smallest, 4, accuracy: 0.01, "★ the 4 mm cells it needs, no smaller")
        XCTAssertEqual(seen.wMax, 0.9, accuracy: 0.01, "★ struts as thin as before")
        XCTAssertEqual(seen.atQuilt, 0, "★ none touching")
        XCTAssertEqual(seen.solidShare, 0, accuracy: 0.05, "★ none solid")

        let top = try XCTUnwrap(p.selection.groups.first { $0.name == "Top" })
        p.writeLatticeDepthMM(.face(group: top.id, face: 1), mm: 17.5)
        let shallow = LatticeLayoutPreview.settings(p)
        let thin = try await session.lay(shallow)
        let thinSolid = try await LatticeLayoutPreview.unheldReport(session, box)
        let thinSeen = Notes30A1OffersTests.seen(thin, line: shallow.beadMM, solid: thinSolid?.share ?? 0)
        print("NOTES30-X2 SMALL at 17.5 mm: \(thinSeen)")
        XCTAssertEqual(thinSeen.cells, 0, "★ 3.5 mm cells: Small cells lays nothing here, so it is never offered here")
    }
}
#endif
