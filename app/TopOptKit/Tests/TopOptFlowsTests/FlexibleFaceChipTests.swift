// FlexibleFaceChipTests — round 7, batch R7-D2, THE CHIP and his three changes to B1, written BEFORE the code (red run:
// round7/batch_d2/d2_red_run.txt). His words (2026-10-14):
//   (a) "I want to be able to move the modals around for each face by dragging" — the chip is draggable, its leader follows;
//   (b) "I want an (i) next to each face …" + his correction: "The per-face (i) shows ONLY: Cell, Density, Strut, Cells across";
//   (c) "Please make it more obvious that an 'Add to group C as lattice' is an obvious button and not just a title."
import XCTest
import SwiftUI
import TopOptDesign
@testable import TopOptFlows
@testable import TopOptKit

@MainActor
final class FlexibleFaceChipTests: XCTestCase {

    static let pad13p = CGSize(width: 1032, height: 1376)
    static let pad11p = CGSize(width: 834, height: 1194)

    // MARK: (c) the join button

    /// The label is EXACTLY "Add to Group C as lattice" (the group's own name), a filled DS-accent button, white semibold,
    /// ≥ 44 tall, the button trait. RED CONTROL: the mockup's rejected `.rowA` (fill-subtle + a tint stroke) is not this style.
    func testTheJoinIsAFilledButtonWithItsExactLabel() throws {
        XCTAssertEqual(FlexibleSelectionsCopy.joinLabel("Group C"), "Add to Group C as lattice")
        XCTAssertEqual(FlexibleJoinButton.fill, DS.Color.accent, "★ the DS accent fill (#0A84FF)")
        XCTAssertGreaterThanOrEqual(FlexibleJoinButton.height, 44, "★ ≥ 44 pt")
        let src = try String(contentsOf: FlexibleRound7SelectionsHookTests.sources.appendingPathComponent("FlexibleFaceChip.swift"), encoding: .utf8)
        XCTAssertTrue(src.contains(".accessibilityAddTraits(.isButton)"), "★ the button trait")
        XCTAssertTrue(src.contains(".font(.system(size: 15, weight: .semibold)).foregroundStyle(.white)"), "★ a white semibold label")
        XCTAssertTrue(src.contains(".fill(FlexibleJoinButton.fill.color)"), "★ filled")
        // ★ RED CONTROL: the rejected row (his image 2) — fill-subtle with a 1.5 pt tint stroke, an outlined title row
        let rejected = (fill: DS.Color.fillSubtle, stroke: 1.5)
        XCTAssertNotEqual(FlexibleJoinButton.fill, rejected.fill, "★ RED CONTROL: not the outlined `.rowA` he rejected")
    }

    // MARK: (a) the drag and the leader

    func testADraggedChipKeepsItsSpotForThatFaceAndTheLeaderReAims() {
        let st = FlexibleFaceChipState()
        let key3 = FlexibleFaceScope.face(group: UUID(), ref: .face(group: UUID(), face: 3)).chipKey!
        st.spots[key3] = CGPoint(x: 600, y: 900)
        let size = FlexibleFaceChipLayout.size(.member)
        let r = FlexibleFaceChipLayout.clamped(CGRect(origin: st.spots[key3]!, size: size), viewport: Self.pad13p)
        XCTAssertEqual(r.origin, CGPoint(x: 600, y: 900), "★ the spot is kept for that face")
        // an orbit moves the face's projected centre: the chip stays, the leader re-aims
        for target in [CGPoint(x: 300, y: 600), CGPoint(x: 500, y: 1200), CGPoint(x: 900, y: 920)] {
            let s = FlexibleFaceChipLayout.leaderStart(chip: r, target: target)
            XCTAssertTrue(r.insetBy(dx: -0.5, dy: -0.5).contains(s), "the leader starts on the chip's edge")
            XCTAssertTrue(abs(s.x - r.minX) < 0.5 || abs(s.x - r.maxX) < 0.5 || abs(s.y - r.minY) < 0.5 || abs(s.y - r.maxY) < 0.5,
                          "★ on its nearest edge, toward \(target)")
        }
        // another face: its own spot (none yet)
        XCTAssertNil(st.spots[FlexibleFaceScope.face(group: UUID(), ref: .face(group: UUID(), face: 5)).chipKey!], "dropped for a different face")
        // clamped 16 pt inside; let go over a keep-out, it slides to the nearest clear spot
        let off = FlexibleFaceChipLayout.clamped(CGRect(x: -200, y: 5000, width: size.width, height: size.height), viewport: Self.pad13p)
        XCTAssertEqual(off.minX, 16); XCTAssertEqual(off.maxY, Self.pad13p.height - 16)
        let keep = [CGRect(x: 400, y: 400, width: 300, height: 300)]
        let let_go = FlexibleFaceChipLayout.released(CGRect(x: 420, y: 420, width: size.width, height: size.height), viewport: Self.pad13p, keepOut: keep)
        XCTAssertFalse(keep[0].insetBy(dx: -8, dy: -8).intersects(let_go), "★ nudged off the keep-out")
        XCTAssertLessThan(hypot(let_go.minX - 420, let_go.minY - 420), 400, "to the nearest clear spot")
        // ★ RED CONTROL: the automatic placement ignores the drag (every frame it puts the chip back)
        let autoSpot = FlexibleFaceChipLayout.auto(size: size, anchor: CGPoint(x: 600, y: 700), viewport: Self.pad13p, keepOut: [])
        XCTAssertNotEqual(autoSpot.origin, r.origin, "★ RED CONTROL: auto alone would move his chip back")
    }

    func testAutoPlacementOrderAndTheKeepOuts() {
        let size = FlexibleFaceChipLayout.size(.new(join: true, held: true))
        let v = Self.pad13p
        let a = CGPoint(x: 700, y: 800)
        let above = FlexibleFaceChipLayout.auto(size: size, anchor: a, viewport: v, keepOut: [])
        XCTAssertEqual(above.maxY, a.y - 56, accuracy: 0.5, "★ above the face's centre, 56 pt gap")
        // above blocked → below
        let below = FlexibleFaceChipLayout.auto(size: size, anchor: a, viewport: v, keepOut: [CGRect(x: 0, y: a.y - 400, width: v.width, height: 300)])
        XCTAssertEqual(below.minY, a.y + 56, accuracy: 0.5, "★ else below")
        // the main page's keep-outs: the list, the capsule, the gizmo + views row, the corner pair
        let sel = CGRect(x: 24, y: 400, width: 348, height: 360)
        let keep = FlexibleFaceChipLayout.keepOuts(viewport: v, selections: sel, legend: CGRect(x: 760, y: 292, width: 248, height: 124),
                                                   panel: nil, player: nil)
        XCTAssertTrue(keep.contains(sel))
        XCTAssertTrue(keep.contains(FlexibleLegendPlacement.gizmoFrame(viewport: v)))
        XCTAssertTrue(keep.contains(FlexibleChromeLayout.viewsRow(viewport: v)))
        let pair = FlexibleChromeLayout.pair(viewport: v, setupWidth: FlexibleChromeLayout.setupMaxWidth)
        XCTAssertTrue(keep.contains(pair.lattice))
        for anchor in [CGPoint(x: 200, y: 600), CGPoint(x: 900, y: 300), CGPoint(x: 516, y: 1300), CGPoint(x: 516, y: 688)] {
            for vp in [Self.pad13p, Self.pad11p] {
                let k = FlexibleFaceChipLayout.keepOuts(viewport: vp, selections: CGRect(x: 24, y: 300, width: 348, height: 420), legend: nil, panel: nil, player: nil)
                let r = FlexibleFaceChipLayout.auto(size: size, anchor: anchor, viewport: vp, keepOut: k)
                XCTAssertFalse(k.contains { $0.intersects(r) }, "★ the chip never sits on a keep-out (\(anchor) on \(vp))")
                XCTAssertTrue(r.minX >= 15.5 && r.maxX <= vp.width - 15.5, "inside the screen")
            }
        }
    }

    // MARK: (b) the (i)

    func testTheInfoShowsOnlyHisFourRowsFromTheDrawersOwnNumbers() throws {
        let card = try XCTUnwrap(FlexibleFaceChipTests.sampleCard(), "a card")
        let rows = try XCTUnwrap(FlexibleFaceStats.rows(card: card, depthMM: 25, held: true))
        XCTAssertEqual(rows.rows.map(\.label), ["Cell", "Density", "Strut", "Cells across"], "★ ONLY his four (his correction)")
        let drawer = LatticeRegionDrawer.make(card: card, depthMM: 25, held: true, latticeReachesTheRun: true)
        for r in rows.rows {
            XCTAssertEqual(r.value, drawer.rows.first { $0.label == r.label }?.value, "★ \(r.label): the old drawer's own number")
        }
        XCTAssertFalse(rows.rows.contains { ["Hands over", "As lattice", "Saved", "Depth", "Expand"].contains($0.label) })
        XCTAssertNil(FlexibleFaceStats.rows(card: nil, depthMM: 25, held: true), "no card yet → 'No numbers yet for this face'")
        XCTAssertEqual(FlexibleSelectionsCopy.statsCaption, "The current preview's numbers at this depth.")
        // ★ RED CONTROL: the B1 mockup without an (i) — the drawer's full list has the rows he struck
        XCTAssertTrue(drawer.rows.contains { $0.label == "Hands over" }, "★ RED CONTROL: the full drawer carries Hands over / As lattice / Saved")
    }

    /// A card as the barrier preview makes one (a 25 mm slab, octet).
    static func sampleCard() -> LatticeFaceCard? {
        var c = LatticeFaceCard(faceID: 3, depthMM: 25, heldVoxels: 900, heldVolumeMM3: 25_000, heldMassG: 26,
                                cellMM: 10.1, relativeDensity: 0.14, strutDiameterMM: 1.2,
                                cellsPerMember: 2.5, verdict: .certified)
        c.cellsAcrossSource = .estimate
        return c
    }
}
