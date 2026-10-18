// FlexibleR7D2ReviewTests — round 7, the review of R7-D2 (Selections, his pick 2): what the two-angle review found on his
// pad, pinned BEFORE the fixes (the red run: round7/batch_d2_review/d2r_red_run.txt). Each test carries a RED CONTROL that
// shows the old behaviour fails the same assertion. The hosted half (the page on his pad at 13" and 11", both orientations)
// is FlexibleR7D2ReviewHostedTests.
//
//   R1  the (i) from the CHIP never covers the chip (the mockup: below it)
//   R2  the message (a Load's "Set its weight…", a delete's [Undo]) never sits on the player
//   R3  the (i)'s numbers are the Flexible lattice DRAWN at that face — the legend's numbers, never #354's slab card's
//   R4  the join offers only a group that already has a lattice face; a Load or Anchor group says what else it gives
//   R5  the weights read in the Flexible unit (his lb); a Load the chip just made reads "weight: Squish page"
//   R6  the delete question and its message fit one line of ≤ 44 characters, whatever the name
//   R7  the held [Lattice] says the two-tap route in plain words (no "review")
//   R8  the number boxes take a tap across 44 pt
//   R9  the chip's automatic spot keeps off the face it edits
//   R10 [Prisms]' number falls back to another spot of its face-prism before it is dropped
import XCTest
import SwiftUI
import simd
import TopOptDesign
@testable import TopOptFlows
@testable import TopOptKit

@MainActor
final class FlexibleR7D2ReviewTests: XCTestCase {

    static let viewports: [(String, CGSize)] = [("13p", CGSize(width: 1032, height: 1376)), ("13l", CGSize(width: 1376, height: 1032)),
                                               ("11p", CGSize(width: 834, height: 1194)), ("11l", CGSize(width: 1194, height: 834))]

    func hisPad() throws -> (FlexibleHisProject.Restored, ProjectModel, UUID) {
        let r = try FlexiblePressFixtures.a1Project(3, self, facePrism: false)
        let c = try FlexibleR7M1Fixtures.hisLiveLattice(r.project)
        r.project.seedUndoBaseline()
        return (r, r.project, c)
    }

    // MARK: R1 — the chip's (i) card sits below the chip, never on it

    func testTheChipsInfoCardSitsBelowTheChipNeverOnIt() {
        let size = CGSize(width: FlexibleFaceStatsCard.width, height: FlexibleFaceStatsPlacement.estimatedHeight(rows: true))
        for (tag, v) in Self.viewports {
            // the chip where his pad put it (13p: 612,903 404×132) and two other spots, its (i) inside its second line
            for chip in [CGRect(x: 612, y: 903, width: 404, height: 132).offsetBy(dx: v.width > 1100 ? 0 : -200, dy: v.height > 1100 ? 0 : -300),
                         CGRect(x: 420, y: 120, width: 404, height: 132), CGRect(x: 16, y: v.height - 16 - 132, width: 404, height: 132)] {
                let info = CGRect(x: chip.minX + 70, y: chip.minY + 76, width: 44, height: 44)
                let card = FlexibleFaceStatsPlacement.frame(anchor: info, chip: chip, size: size, viewport: v, keepOut: [])
                XCTAssertFalse(card.intersects(chip), "★ \(tag): the (i)'s card never covers its chip (\(card) vs \(chip))")
                XCTAssertTrue(card.minX >= 7.5 && card.maxX <= v.width - 7.5 && card.minY >= 7.5 && card.maxY <= v.height - 7.5,
                              "\(tag): on screen \(card)")
                if chip.maxY + 8 + size.height <= v.height - 8 {
                    XCTAssertEqual(card.minY, chip.maxY + 8, accuracy: 0.5, "★ \(tag): below the chip (the mockup's spot)")
                    XCTAssertEqual(card.minX, max(8, min(info.minX - 12, v.width - 8 - size.width)), accuracy: 0.5,
                                   "\(tag): lined up with the (i)")
                }
                // ★ RED CONTROL: the old spot — to the right of the (i), which is inside the chip — lands on the chip
                let old = CGRect(x: min(max(8, info.maxX + 8), v.width - 8 - size.width), y: min(max(8, info.midY - size.height / 2), v.height - 8 - size.height),
                                 width: size.width, height: size.height)
                XCTAssertTrue(old.intersects(chip), "★ RED CONTROL \(tag): beside the (i) it covers the chip")
            }
        }
        // the list's (i): still beside the list (the mockup), no chip given
        let list = CGRect(x: 24, y: 600, width: 348, height: 300)
        let info = CGRect(x: 320, y: 700, width: 44, height: 44)
        let card = FlexibleFaceStatsPlacement.frame(anchor: info, chip: nil, size: size, viewport: Self.viewports[0].1, keepOut: [list])
        XCTAssertGreaterThanOrEqual(card.minX, info.maxX + 8 - 0.5, "the list's (i): to its right")
        XCTAssertFalse(card.intersects(list), "and off the list")
    }

    // MARK: R2 — the message never sits on the player

    func testTheMessageSitsAboveThePlayerWhenPlayIsOn() {
        for (tag, v) in Self.viewports {
            let msg = CGSize(width: 420, height: 44)
            let free = FlexibleSelectionsMessage.frame(size: msg, viewport: v, player: nil)
            XCTAssertEqual(free.midY, v.height - FlexibleChromeLayout.barClearance - PageChrome.gap - 22, accuracy: 0.5,
                           "\(tag): with Play off, its band above the bar (as before)")
            // the player where his pad puts it with Play on (13p: capsule 526,1230 340×46; its note row above)
            let player = CGRect(x: (PageChrome.edge + PageChrome.panelWidth + v.width) / 2 - 170, y: v.height - FlexibleChromeLayout.barClearance - 112,
                                width: 340, height: 46 + FlexibleSquishPlayer.topRowHeight + 6)
            let r = FlexibleSelectionsMessage.frame(size: msg, viewport: v, player: player)
            XCTAssertFalse(r.intersects(player), "★ \(tag): the message is not on the player (\(r) vs \(player))")
            XCTAssertLessThanOrEqual(r.maxY, player.minY - PageChrome.gap + 0.5, "★ \(tag): above it, a gap between")
            XCTAssertGreaterThan(r.minY, 0, "\(tag): on screen")
            // and above the chip when the chip sits in its band
            let chip = CGRect(x: r.minX - 40, y: r.minY - 20, width: 404, height: 132)
            let r2 = FlexibleSelectionsMessage.frame(size: msg, viewport: v, player: player, avoid: [chip])
            XCTAssertFalse(r2.intersects(chip), "★ \(tag): the message is not on the chip (\(r2) vs \(chip))")
            XCTAssertFalse(r2.intersects(player), "\(tag): nor on the player")
            // ★ RED CONTROL: the old fixed spot is the player's own band
            let old = CGRect(x: free.minX, y: v.height - FlexibleChromeLayout.barClearance - PageChrome.gap - 44, width: msg.width, height: 44)
            XCTAssertTrue(old.intersects(player), "★ RED CONTROL \(tag): the old fixed spot sits on the player")
        }
    }

    // MARK: R3 — the (i) reads the Flexible lattice drawn at that face

    /// A synthetic lattice: a 40 × 40 × 20 mm block, ρ 0.15 in its x < 20 half and 0.21 in the other, the mask on everywhere;
    /// a face region over the x < 20 half, 10 mm deep. The (i) reads THAT half: 15 %, the drawn cell at 0.15, the wall,
    /// and depth ÷ cell.
    func testTheInfoReadsTheFlexibleLatticeDrawnInsideThatFace() throws {
        let n = (x: 40, y: 40, z: 20)
        var rho = [Float](repeating: 0, count: n.x * n.y * n.z)
        for k in 0..<n.z { for j in 0..<n.y { for i in 0..<n.x { rho[(k * n.y + j) * n.x + i] = i < 20 ? 0.15 : 0.21 } } }
        let grid = FlexGrid(nx: n.x, ny: n.y, nz: n.z, c0: SIMD3(0.5, 0.5, 0.5), spacing: 1, values: rho)
        let mask = FlexGrid(nx: n.x, ny: n.y, nz: n.z, c0: SIMD3(0.5, 0.5, 0.5), spacing: 1, values: [Float](repeating: 1, count: rho.count))
        let f = FlexibleLatticeInputs(topology: .gyroid, wallMM: 0.42, lMinMM: 1.4, lMaxMM: 25, honeycombCellMM: 4,
                                      buildDir: SIMD3(0, 0, 1), skinMM: 0.8, rho: grid, mask: mask, partSDF: grid, skinDist: grid,
                                      boundsMin: .zero, boundsMax: SIMD3(40, 40, 20))
        var face = LatticeRegionSpec(role: .include, kind: .face)
        face.origin = SIMD3(10, 20, 20); face.normal = SIMD3(0, 0, -1)   // the top of the x < 20 half, into the part
        face.halfUMM = 9.9; face.halfWMM = 9.9; face.depthMM = 10   // x 0.1…19.9, y 10.1…29.9 whichever in-plane axis is u
        let rows = try XCTUnwrap(FlexibleFaceStats.rows(lattice: f, regions: [face], depthMM: 10), "★ numbers for the face")
        XCTAssertEqual(rows.rows.map(\.label), FlexibleFaceStats.labels, "★ his four, in order")
        let cell = FlexibleProbe.drawnCell(rho: 0.15, f)
        XCTAssertEqual(rows.rows[0].value, String(format: "%@%.1f mm · Gyroid", cell.blended ? "≈" : "", cell.mm), "★ Cell: the drawn cell at the face's ρ")
        XCTAssertEqual(rows.rows[1].value, "15%", "★ Density: the face's own ρ (not the other half's 21 %)")
        XCTAssertEqual(rows.rows[2].value, "0.42 mm", "★ Strut: the wall it is drawn with")
        XCTAssertEqual(rows.rows[3].value, String(format: "%.1f", 10 / cell.mm), "★ Cells across: depth ÷ cell")
        XCTAssertNil(rows.note, "no estimate note: these are the drawn numbers")
        // inside the legend's span (the same pass's ρ over the mask)
        let span = FlexibleProbe.latticeSpan(f)
        let faceRho = try XCTUnwrap(rows.rho)
        XCTAssertEqual(faceRho, 0.15, accuracy: 1e-6, "the face's own ρ")
        XCTAssertTrue(span.contains(faceRho), "the face's ρ lies inside the legend's span \(span)")
        // no region, no numbers
        XCTAssertNil(FlexibleFaceStats.rows(lattice: f, regions: [], depthMM: 10), "no face-prism → 'No numbers yet for this face'")
        // ★ RED CONTROL: #354's slab card for the same face (the barrier preview's octet numbers) is not the lattice he sees
        let card = try XCTUnwrap(FlexibleFaceChipTests.sampleCard())
        let old = try XCTUnwrap(FlexibleFaceStats.rows(card: card, depthMM: 10, held: true))
        XCTAssertNotEqual(old.rows[1].value, rows.rows[1].value, "★ RED CONTROL: the slab card's density is another lattice's")
    }

    // MARK: R4 — the join offers only a lattice group, and says what else a Load / Anchor group gives

    func testTheJoinOffersOnlyAGroupThatHasALatticeFace() throws {
        let (_, p, c) = try hisPad()
        let top = try XCTUnwrap(p.selection.groups.first { $0.name == "Top" })
        XCTAssertTrue(p.force.kind(for: top.id).isLoad, "premise: the Top is his Load")
        XCTAssertFalse(FlexibleFaceCommits.hasLattice(top.id, p), "premise: no lattice face on the Top")
        XCTAssertFalse(FlexibleFaceCommits.canJoin(top.id, p), "★ no 'Add to Top as lattice' (it would join the Load)")
        XCTAssertTrue(FlexibleFaceCommits.canJoin(c, p), "Group C (Protect, two lattice faces) is offered")
        let v = FlexibleFaceCommits.joinValues(c, p, session: FlexibleFacePickSession())
        XCTAssertEqual(v.depth, 25, accuracy: 1e-9, "★ at its own 25 mm (never the paint default)")
        XCTAssertEqual(FlexibleFaceCommits.joinAlso(c, p), .none, "a Protect group gives nothing else")
        XCTAssertEqual(FlexibleSelectionsCopy.joinNote(depthMM: 25, like: ["Face 3", "Face 5"], also: .none), "25.0 mm deep, the same as Face 3 + Face 5")
        // a Load group WITH a lattice face: offered, and its note says the face also takes part of the load
        FlexibleFaceCommits.setState(.include, ref: .face(group: top.id, face: 1), group: top.id, project: p)
        XCTAssertTrue(FlexibleFaceCommits.canJoin(top.id, p), "a Load group with a lattice face is offered")
        XCTAssertEqual(FlexibleFaceCommits.joinAlso(top.id, p), .load)
        let note = FlexibleSelectionsCopy.joinNote(depthMM: 21, like: ["Face 1"], also: .load)
        XCTAssertEqual(note, "21.0 mm deep · it also shares the Load", "★ said plainly")
        XCTAssertEqual(FlexibleSelectionsCopy.joinNote(depthMM: 21, like: [], also: .anchor), "21.0 mm deep · it is also anchored")
        for s in [note, FlexibleSelectionsCopy.joinNote(depthMM: 21, like: [], also: .anchor)] { XCTAssertLessThanOrEqual(s.count, 44, s) }
        // ★ RED CONTROL: the old rule (any group that may carry a lattice role) offered the Top with no lattice face
        FlexibleFaceCommits.setState(.off, ref: .face(group: top.id, face: 1), group: top.id, project: p)
        XCTAssertTrue(FlexibleFaceCommits.mayCarryLattice(top.id, p), "★ RED CONTROL: the old canJoin said yes to the Top")
    }

    // MARK: R5 — the weights in his unit; a Load the chip just made reads "weight: Squish page"

    func testTheWeightsReadInTheFlexibleUnitAndANewLoadPointsToTheSquishPage() throws {
        let (_, p, _) = try hisPad()
        let top = try XCTUnwrap(p.selection.groups.first { $0.name == "Top" })
        XCTAssertEqual(p.lattice.flexible?.weightUnit, "lb", "premise: his Flexible stage reads lb")
        let kg = try XCTUnwrap(p.force.kind(for: top.id).weightKg)
        XCTAssertEqual(FlexibleFaceChip.loadWeight(p, top.id, ui: nil), FlexibleWeightUnit.lb.text(kg: kg), "★ the Top in lb")
        XCTAssertEqual(FlexibleFaceChip.loadWeight(p, top.id, ui: nil), "22 lb", "★ his 10 kg reads 22 lb, as the player and the Squish page say")
        // [Load] on a new face: the chip's group reads "weight: Squish page" until the weight is set there
        let s = FlexibleMainStage()
        s.facePick = FlexibleFacePickSession(scope: .pending([.face(4)]))
        s.commitNew(.load, project: p) {}
        let g = try XCTUnwrap(s.facePick.scope.groupID, "the new Load group")
        XCTAssertEqual(FlexibleFaceChip.loadWeight(p, g, ui: s.faceUI), FlexibleSelectionsCopy.weightUnset, "★ the mockup's words for an unset weight")
        XCTAssertEqual(FlexibleSelectionsCopy.weightUnset, "weight: Squish page")
        p.force.setWeight(g, kg: 4.5359237)   // the Squish page writes the face's weight back to the Load group (one source of truth)
        XCTAssertEqual(FlexibleFaceChip.loadWeight(p, g, ui: s.faceUI), "10 lb", "★ once set, the weight in his unit")
        // ★ RED CONTROL: Topology's formatter reads kg — "10 kg" beside the player's "11 lb each"
        XCTAssertEqual(p.force.formattedWeight(kg: kg), "10 kg", "★ RED CONTROL: the old read was Topology's kg")
    }

    // MARK: R6 — the delete question fits one line

    func testTheDeleteQuestionAndItsMessageFitOneLineWhateverTheName() {
        XCTAssertEqual(FlexibleSelectionsCopy.deleteAsk("Group C"), "Delete Group C here and in Topology?", "a short name: as before")
        XCTAssertEqual(FlexibleSelectionsCopy.deleted("Group C"), "Group C deleted here and in Topology")
        for name in ["Left side squeeze pad", "A name he typed that is rather long", String(repeating: "W", count: 60)] {
            XCTAssertLessThanOrEqual(FlexibleSelectionsCopy.deleteAsk(name).count, 44, "★ ≤ 44: \(FlexibleSelectionsCopy.deleteAsk(name))")
            XCTAssertLessThanOrEqual(FlexibleSelectionsCopy.deleted(name).count, 44, "★ ≤ 44: \(FlexibleSelectionsCopy.deleted(name))")
            XCTAssertTrue(FlexibleSelectionsCopy.deleteAsk(name).hasSuffix("here and in Topology?"))
        }
        // ★ RED CONTROL: the old sentence with his renamed group — 50 characters, past his line
        XCTAssertGreaterThan("Delete Left side squeeze pad here and in Topology?".count, 44, "★ RED CONTROL: the old question overflowed")
    }

    /// The question's Text never widens the panel (no fixedSize on it).
    func testTheDeleteQuestionNeverWidensItsPanel() throws {
        let src = try String(contentsOf: FlexibleRound7SelectionsHookTests.sources.appendingPathComponent("FlexibleSelectionsList.swift"), encoding: .utf8)
        let q = try XCTUnwrap(src.range(of: "Text(FlexibleSelectionsCopy.deleteAsk(name))"))
        let line = String(src[q.lowerBound...].prefix(260))
        XCTAssertFalse(line.contains(".fixedSize()"), "★ the question is not fixed-size (it widened the 348 pt panel)")
        XCTAssertTrue(line.contains(".lineLimit(1)"), "one line")
    }

    // MARK: R7 — the held [Lattice] says the route

    func testTheHeldLatticeLineSaysTheTwoTapRoute() {
        let s = FlexibleSelectionsCopy.latticeHeld
        XCTAssertLessThanOrEqual(s.count, 44, s)
        XCTAssertTrue(s.contains("Protect") && s.contains("Lattice"), "★ the route: Protect, then Lattice on the face's chip")
        XCTAssertFalse(s.lowercased().contains("review"), "★ no reviewer-process words on his screen")
        // ★ RED CONTROL: the old line
        XCTAssertTrue("Lattice on a new face waits for a review".contains("review"), "★ RED CONTROL: the old line was process talk")
    }

    // MARK: R8 — the number boxes take a tap across 44 pt

    func testTheMainPagesNumberBoxesHaveA44PointTarget() throws {
        XCTAssertEqual(FlexNumberBox.height, 32, "the box itself is still 32 pt (the look is unchanged)")
        let list = try String(contentsOf: FlexibleRound7SelectionsHookTests.sources.appendingPathComponent("FlexibleSelectionsList.swift"), encoding: .utf8)
        let layer = try String(contentsOf: FlexibleRound7SelectionsHookTests.sources.appendingPathComponent("FlexibleOnModelLayer.swift"), encoding: .utf8)
        XCTAssertEqual(list.components(separatedBy: "hitHeight: FlexNumberBox.target").count - 1, 1, "★ the list's boxes: a 44 pt target")
        XCTAssertEqual(layer.components(separatedBy: "hitHeight: FlexNumberBox.target").count - 1, 2, "★ the handles' two boxes: a 44 pt target")
        XCTAssertEqual(FlexNumberBox.target, 44)
        // scope: the Squish page's boxes keep their 32 pt (nothing else changes; the RED run is the hosted click,
        // FlexibleR7D2ReviewHostedTests.testANumberBoxTakesATapAcross44Points)
        let squish = try String(contentsOf: FlexibleRound7SelectionsHookTests.sources.appendingPathComponent("FlexibleSettingsRail.swift"), encoding: .utf8)
        XCTAssertFalse(squish.contains("hitHeight:"), "the Squish page's boxes are untouched")
    }

    // MARK: R9 — the chip's automatic spot keeps off the face it edits

    func testTheAutoSpotKeepsOffTheFacesOwnOutline() {
        let v = CGSize(width: 1032, height: 1376)
        let size = FlexibleFaceChipLayout.size(.member)
        // Face 3 at 13" portrait: its outline across the lower right of the part, its centre near its middle
        let face = CGRect(x: 520, y: 720, width: 470, height: 420)
        let anchor = CGPoint(x: face.midX, y: face.midY + 60)
        let keep = FlexibleFaceChipLayout.keepOuts(viewport: v, selections: FlexibleFaceChipLayout.selectionsColumn(viewport: v),
                                                   legend: nil, panel: nil, player: nil)
        let with = FlexibleFaceChipLayout.auto(size: size, anchor: anchor, viewport: v,
                                               keepOut: keep + [FlexibleFaceChipLayout.faceKeepOut(face, viewport: v)].compactMap { $0 })
        XCTAssertFalse(with.intersects(face), "★ the chip keeps off the face it edits (\(with) vs \(face))")
        // a face that fills most of the screen is no keep-out (nothing would be clear)
        XCTAssertNil(FlexibleFaceChipLayout.faceKeepOut(CGRect(x: 0, y: 0, width: 1000, height: 1300), viewport: v))
        // ★ RED CONTROL: without the face's outline the automatic spot lands on it
        let without = FlexibleFaceChipLayout.auto(size: size, anchor: anchor, viewport: v, keepOut: keep)
        XCTAssertTrue(without.intersects(face), "★ RED CONTROL: the old automatic spot sat on the face (\(without))")
    }

    /// The face is a SOFT keep-out: at 11" portrait no spot is clear of Face 3 AND the chrome — the chip then goes where it would
    /// without the face, never onto the chrome. RED CONTROL: the face as a hard keep-out docks the chip on the cube and views row.
    func testWhenNoSpotIsClearOfTheFaceTheChromeStillWins() {
        let v = CGSize(width: 834, height: 1194)
        let size = FlexibleFaceChipLayout.size(.member)
        let hard = FlexibleFaceChipLayout.keepOuts(viewport: v, selections: FlexibleFaceChipLayout.selectionsColumn(viewport: v),
                                                   legend: CGRect(x: 586, y: 292, width: 248, height: 124), panel: nil, player: nil)
        let face = CGRect(x: 417, y: 541, width: 487, height: 491)   // Face 3's outline on his pad, img1's camera, 11" portrait
        let anchor = CGPoint(x: 660, y: 790)
        let r = FlexibleFaceChipLayout.auto(size: size, anchor: anchor, viewport: v, keepOut: hard, soft: FlexibleFaceChipLayout.faceKeepOut(face, viewport: v))
        XCTAssertFalse(FlexibleFaceChipLayout.hits(r, hard), "★ the chrome wins: \(r)")
        XCTAssertEqual(r, FlexibleFaceChipLayout.auto(size: size, anchor: anchor, viewport: v, keepOut: hard), "placed as without the face")
        // ★ RED CONTROL: the face as a hard keep-out leaves no clear spot — the dock lands on the chrome
        let hardFace = FlexibleFaceChipLayout.auto(size: size, anchor: anchor, viewport: v, keepOut: hard + [face])
        XCTAssertTrue(FlexibleFaceChipLayout.hits(hardFace, hard), "★ RED CONTROL: docked on the chrome (\(hardFace))")
        // and where a spot off the face exists, it is taken (13" portrait)
        let v13 = CGSize(width: 1032, height: 1376)
        let hard13 = FlexibleFaceChipLayout.keepOuts(viewport: v13, selections: FlexibleFaceChipLayout.selectionsColumn(viewport: v13),
                                                     legend: nil, panel: nil, player: nil)
        let face13 = CGRect(x: 516, y: 623, width: 562, height: 566)
        let r13 = FlexibleFaceChipLayout.auto(size: size, anchor: CGPoint(x: 800, y: 900), viewport: v13, keepOut: hard13,
                                              soft: FlexibleFaceChipLayout.faceKeepOut(face13, viewport: v13))
        XCTAssertFalse(r13.intersects(face13), "★ 13p: off the face (\(r13))")
        XCTAssertFalse(FlexibleFaceChipLayout.hits(r13, hard13), "13p: off the chrome")
    }

    // MARK: R10 — [Prisms]' number tries another spot of its face-prism before it is dropped

    func testAPrismNumberUnderAPanelMovesToAnotherSpotOfItsPrism() throws {
        let (_, p, c) = try hisPad()
        let planes = p.latticeDepthPlanes().filter { $0.groupID == c && $0.role == .include }
        let plane = try XCTUnwrap(planes.first, "premise: Group C's face-prism")
        let v = CGSize(width: 1032, height: 1376)
        let panel = CGRect(x: 24, y: 300, width: 348, height: 700)
        let hidden = CGPoint(x: 200, y: 600), free = CGPoint(x: 600, y: 600)
        let placed = FlexiblePrismNumbers.place([(plane, [hidden, free])], viewport: v, keepOut: [panel])
        XCTAssertEqual(placed.count, 1, "★ the number is kept")
        XCTAssertEqual(placed.first?.1, free, "★ at the prism's next spot, off the panel")
        // ★ RED CONTROL: one spot only (the old placement) — under the panel it was dropped silently
        XCTAssertTrue(FlexiblePrismNumbers.place([(plane, [hidden])], viewport: v, keepOut: [panel]).isEmpty, "★ RED CONTROL: dropped")
    }
}
