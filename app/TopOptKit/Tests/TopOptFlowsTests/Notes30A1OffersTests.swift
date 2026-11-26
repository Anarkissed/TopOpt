// Notes30A1OffersTests — ★ notes30 X2, the maintainer's 11-26 answers (builder R1's finding on his 20 mm A1 pad).
//   1. "This lattice can't be laid" on Structural with Allow quilt off: Structural lays 5 cells across the 20 mm pad, 4 mm cells,
//      under the 4.74 mm smallest cell Allow quilt off lays (notes29 N2/N2b). "Use smaller cells" cannot help there. His answer:
//      offer all three — turn Allow quilt on, switch to Aesthetic, leave it solid — each a 44 pt button that does it, in the
//      centred pop-up, positive words, the detail in an (i). "Smaller cells" stays where it helps.
//      HIS QUESTION: "would 'Allow quilt' go straight to a full quilt, or would it just get to the 4 mm cell and that's it?"
//      — answered by laying his pad both ways here (testHisPadLaidWithAllowQuiltOffAndOn prints the numbers).
//   2. His yes: the Lattice page's warning triangle opens the one centred card, its setting fixes as the card's buttons.
// Model and measured parts here; the pages: Notes30A1OffersHostedTests.
#if canImport(AppKit) && canImport(MetalKit)
import XCTest
import simd
@testable import TopOptFlows
@testable import TopOptKit

@MainActor
final class Notes30A1OffersTests: XCTestCase {

    override func tearDown() {
        SolidReason.controlSmallerCellsAlways = false
        AppPopups.shared.current = nil
        super.tearDown()
    }

    // MARK: 1 · the rule

    /// His pad's numbers: 20 mm deep, Structural's 5 across, 4.74 mm the smallest cell Allow quilt off lays, 2.55 mm with it on.
    static let hisPad = SolidReason.Depth(depthMM: 20, cellsAcross: 5, floorCellMM: 4.7404, quiltFloorCellMM: 2.5456,
                                          aestheticCellsAcross: 2, allowQuiltOn: false)

    /// ★ Where smaller cells cannot help (the cell the depth needs is under the smallest laid), the pop-up offers exactly his
    /// three — Allow quilt on, Aesthetic, Leave it solid — says what the depth needs in positive words, and never "smaller
    /// cells"; where they help, "smaller cells" stays; where nothing but depth helps, it says the depth. RED CONTROL
    /// (`controlSmallerCellsAlways`): release 21's advice, "use smaller cells" with no offer.
    func testHisThreeOffersWhereSmallerCellsCannotHelp() throws {
        var st = LatticeSettings(); st.stageMode = .structural
        let nocell = [0, 0, 0, 0, 40]   // core's reason: the region is too shallow (C15)
        let r = try XCTUnwrap(SolidReason.of(share: 1, nocell: nocell, lattice: st, depth: Self.hisPad))
        XCTAssertEqual(r.fixes, [.allowQuilt, .switchToAesthetic, .leaveSolid], "★ exactly his three, in his order")
        XCTAssertEqual(r.fixes.map(\.title), ["Turn Allow quilt on", "Switch to Aesthetic", "Leave it solid"])
        let title = SolidPopUp.title(r), text = SolidPopUp.text(r, lattice: st)
        XCTAssertEqual(title, "This needs 4 mm cells")
        print("NOTES30-X2 POP-UP: \(title) — \(text.replacingOccurrences(of: "\n", with: " ")) [\(r.fixes.map(\.title))]")
        XCTAssertFalse(text.contains("smaller cells"), "★ never the advice that cannot help")
        XCTAssertTrue(text.contains("5 cells across 20 mm") && text.contains("4 mm") && text.contains("4.74 mm"), "★ the numbers")
        for words in [title, text] + r.fixes.map(\.title) {
            for neg in ["can't", "can’t", "cannot", "don't", "don’t", "won't"] {
                XCTAssertFalse(words.lowercased().contains(neg), "★ positive words: \(words)")
            }
        }
        for w in [title] + r.fixes.map(\.title) { XCTAssertLessThanOrEqual(LatticeCaptions.words(w), 5, "★ five words: \(w)") }
        let why = try XCTUnwrap(SolidPopUp.offersWhy(r), "★ the detail is in its (i)")
        XCTAssertTrue(why.contains("Turn Allow quilt on:") && why.contains("Switch to Aesthetic:") && why.contains("Leave it solid:"))
        XCTAssertTrue(why.contains("2.55 mm") && why.contains("10 mm"), "★ each offer's own number")
        XCTAssertLessThanOrEqual(LatticeCaptions.words(SolidPopUp.offersWhyTitle), 5)

        // where smaller cells help (a 30 mm region: 6 mm cells, over the 4.74 mm smallest), the words are as before
        var deep = Self.hisPad; deep.depthMM = 30
        let d = try XCTUnwrap(SolidReason.of(share: 1, nocell: nocell, lattice: st, depth: deep))
        XCTAssertFalse(d.offersThree)
        XCTAssertTrue(SolidPopUp.text(d, lattice: st).contains("smaller cells"), "★ smaller cells stay where they help")
        // where neither helps (a 1 mm region), the depth is the fix — no offer that would lay nothing, no "smaller cells"
        var thin = Self.hisPad; thin.depthMM = 1
        let t = try XCTUnwrap(SolidReason.of(share: 1, nocell: nocell, lattice: st, depth: thin))
        XCTAssertTrue(t.fixes.isEmpty, "nothing offered that lays nothing")
        XCTAssertEqual(SolidPopUp.text(t, lattice: st), t.line + ".\n\nIts depth is less than one cell. Make it at least 23.8 mm deep.",
                       "★ his words where the depth is under one cell, and the depth that lays")
        // between one cell and five (an 8 mm region: neither offer lays, 1.6 mm cells)
        var mid = Self.hisPad; mid.depthMM = 8
        let m = try XCTUnwrap(SolidReason.of(share: 1, nocell: nocell, lattice: st, depth: mid))
        XCTAssertTrue(m.fixes.isEmpty)
        XCTAssertEqual(SolidPopUp.text(m, lattice: st), m.line + ".\n\nIts depth holds fewer than 5 cells. Make it at least 23.8 mm deep.")
        // Allow quilt already on: it is not offered again
        var on = Self.hisPad; on.allowQuiltOn = true; on.floorCellMM = 2.5456
        XCTAssertFalse(try XCTUnwrap(SolidReason.of(share: 1, nocell: nocell, lattice: st, depth: on)).offersThree,
                       "Allow quilt on: 4 mm cells lay, smaller cells are not the question")
        // Aesthetic already: Allow quilt alone, then Leave it solid
        var ae = LatticeSettings(); ae.stageMode = .aesthetic
        var aeDepth = Self.hisPad; aeDepth.depthMM = 8; aeDepth.cellsAcross = 2   // 4 mm cells again
        XCTAssertEqual(try XCTUnwrap(SolidReason.of(share: 1, nocell: nocell, lattice: ae, depth: aeDepth)).fixes, [.allowQuilt, .leaveSolid])

        // RED CONTROL: release 21's advice
        SolidReason.controlSmallerCellsAlways = true
        let old = try XCTUnwrap(SolidReason.of(share: 1, nocell: nocell, lattice: st, depth: Self.hisPad))
        XCTAssertTrue(old.fixes.isEmpty, "RED CONTROL: no offer")
        XCTAssertTrue(SolidPopUp.text(old, lattice: st).contains("use smaller cells"), "RED CONTROL: the advice that cannot help")
        XCTAssertEqual(SolidPopUp.title(old), "This lattice can't be laid")
    }

    /// ★ Each offer does what it says, on the part: Allow quilt on opens the Lattice page's Manual with it on (Auto never
    /// quilts, his 11-25); Aesthetic switches the mode and nothing else; Leave it solid changes nothing.
    func testEachOfferDoesWhatItSays() throws {
        let r = try FlexiblePressFixtures.a1Project(3, self, facePrism: true)
        let p = r.project
        p.lattice.flexible = nil
        p.lattice.chooseLatticeType(.structural)
        p.latticePageManual = false
        let before = p.lattice
        SolidReason.take(.leaveSolid, on: p)
        XCTAssertEqual(p.lattice, before, "★ Leave it solid: nothing changes")
        XCTAssertFalse(p.latticePageManual)
        XCTAssertFalse(LatticeLayoutPreview.settings(p).allowQuilt, "premise: Auto lays no quilt")
        SolidReason.take(.allowQuilt, on: p)
        XCTAssertTrue(p.latticePageManual && p.lattice.allowQuilt, "★ Manual, Allow quilt on")
        XCTAssertTrue(LatticeLayoutPreview.settings(p).allowQuilt, "★ the lay reads it")
        p.latticePageManual = false; p.lattice.allowQuilt = false
        let cell = p.lattice.cellSizeMode, depthKeys = p.lattice.selectableDepthMM
        SolidReason.take(.switchToAesthetic, on: p)
        XCTAssertEqual(p.lattice.stageMode, .aesthetic, "★ Aesthetic")
        XCTAssertEqual(p.lattice.cellSizeMode, cell); XCTAssertEqual(p.lattice.selectableDepthMM, depthKeys, "nothing else moves")
    }

    // MARK: 1 · his question, measured on his pad

    /// One lay, read: the cells it laid (sizes), its struts' widths, and how many of them are at the quilt (a strut as wide as
    /// the type's touch on its cell: it meets its neighbours) or at Allow quilt off's limit (one printed line short of it).
    struct Seen: CustomStringConvertible {
        var cells = 0, sizes: [String: Int] = [:], floor = 0.0, touch = 0.0, openLook = 0.0
        var struts = 0, wMin = 0.0, wMedian = 0.0, wMax = 0.0, atQuilt = 0, atOffLimit = 0, atWidest = 0, solidShare = 0.0
        var smallest: Double { sizes.keys.compactMap(Double.init).min() ?? 0 }
        var description: String {
            let s = sizes.sorted { $0.key < $1.key }.map { "\($0.key) mm × \($0.value)" }.joined(separator: ", ")
            return "cells \(cells) [\(s)], floor \(String(format: "%.3f", floor)) mm, struts \(struts) "
                + String(format: "width %.3f / %.3f / %.3f mm (min / median / max)", wMin, wMedian, wMax)
                + ", at the quilt (touching) \(atQuilt), at the quilt-off limit \(atOffLimit), engine's at-widest \(atWidest)"
                + String(format: ", solid %.0f %% of what was asked", 100 * solidShare)
        }
    }

    static func seen(_ r: LatticeLayoutSession.Result, line: Double, solid: Double) -> Seen {
        var o = Seen()
        o.cells = r.cellInfo.count / 5
        for c in 0..<o.cells { o.sizes[String(format: "%.2f", r.cellInfo[5 * c]), default: 0] += 1 }
        o.floor = r.floorCellMM; o.touch = r.touch; o.openLook = r.openLook; o.atWidest = r.atWidest; o.solidShare = solid
        var w: [Double] = []
        for i in 0..<r.barCount where (i < r.barFlags.count ? r.barFlags[i] & 2 : 0) == 0 {   // skin bars are not struts
            let width = Double(r.bars[7 * i + 6]), cell = i < r.barCell.count ? Double(r.barCell[i]) : 0
            w.append(width)
            guard cell > 0 else { continue }
            if width >= r.touch * cell - 0.005 { o.atQuilt += 1 }
            else if width >= r.touch * cell - line - 0.005 { o.atOffLimit += 1 }
        }
        w.sort()
        o.struts = w.count
        if !w.isEmpty { o.wMin = w[0]; o.wMax = w[w.count - 1]; o.wMedian = w[w.count / 2] }
        return o
    }

    static func lay(_ session: LatticeLayoutSession, _ s: LatticeLayoutSession.Settings,
                    box: (lo: SIMD3<Float>, hi: SIMD3<Float>)) async throws -> Seen {
        let r = try await session.lay(s)
        let solid = try await LatticeLayoutPreview.unheldReport(session, box)?.share ?? 0
        return seen(r, line: s.beadMM, solid: solid)
    }

    /// ★ HIS QUESTION, MEASURED: his A1 pad (his Top face as Lattice the whole 20 mm), Structural, laid by core as the preview
    /// lays it: Auto (Allow quilt off), Manual with Allow quilt off, Manual with it on — and, for a normal part, a 60 × 60 ×
    /// 40 mm block laid with the same settings both ways. With Allow quilt on core lays the 4 mm cells the depth needs (core's
    /// divide: depth / 5) and no smaller, struts as thin as before, none touching. On the block the switch is not neutral: the
    /// cells along the face halve and some struts thicken until they touch. Small cells in thin walls (Allow quilt off) is
    /// laid too, for the record: it also lays his pad's 4 mm cells.
    func testHisPadLaidWithAllowQuiltOffAndOn() async throws {
        let r = try FlexiblePressFixtures.a1Project(3, self, facePrism: true)
        let p = r.project
        p.lattice.flexible = nil
        p.lattice.chooseLatticeType(.structural)
        let path = try XCTUnwrap(p.importedFile?.path)
        let box = try XCTUnwrap(LatticeLayoutPreview.box(p.importedMesh?.vertices ?? []))
        let session = try await LatticeLayoutSession.open(path: path)
        addTeardownBlock { session.close() }

        p.latticePageManual = false; p.lattice.allowQuilt = false
        let auto = LatticeLayoutPreview.settings(p)
        print("NOTES30-X2 SETTINGS (Auto): topology \(auto.topology), bead \(auto.beadMM) mm × \(auto.minStrutLines) lines, cells "
              + "\(auto.cellMinMM)-\(auto.cellMaxMM) mm (typed \(auto.cellMM)), across \(auto.minCellsAcross), by stress \(auto.byStress) "
              + "dial \(auto.dial) light \(auto.dialLight) heavy \(auto.dialHeavy) width \(auto.strutWidthMM), algorithm \(auto.algorithm), "
              + "regions \(auto.regions.map { "\($0.faces) \($0.depthMM) mm" })")
        let a = try await Self.lay(session, auto, box: box)
        print("NOTES30-X2 PAD Auto, Allow quilt off: \(a)")
        p.latticePageManual = true
        let offS = LatticeLayoutPreview.settings(p)
        let off = try await Self.lay(session, offS, box: box)
        print("NOTES30-X2 PAD Manual, Allow quilt off: \(off)")
        SolidReason.take(.allowQuilt, on: p)
        let onS = LatticeLayoutPreview.settings(p)
        XCTAssertTrue(onS.allowQuilt, "premise")
        let on = try await Self.lay(session, onS, box: box)
        print("NOTES30-X2 PAD Manual, Allow quilt ON: \(on)")
        print("NOTES30-X2 SETTINGS (Manual, on): dial \(onS.dial) light \(onS.dialLight) heavy \(onS.dialHeavy), by stress \(onS.byStress), "
              + "cells \(onS.cellMinMM)-\(onS.cellMaxMM) mm")
        var small = offS; small.smallCellsInThinWalls = true
        let sm = try await Self.lay(session, small, box: box)
        print("NOTES30-X2 PAD Manual, Allow quilt off + Small cells in thin walls: \(sm)")

        // the depth the pop-up reads, from the lay that laid nothing
        _ = try await session.lay(auto)
        let laidAuto = try await session.lay(auto)
        let ask = try XCTUnwrap(LatticeLayoutPreview.depthAsk(auto, lattice: p.lattice, floorCellMM: laidAuto.floorCellMM))
        print("NOTES30-X2 DEPTH ASK: \(ask) needed \(ask.neededCellMM) quilt helps \(ask.quiltHelps) aesthetic helps \(ask.aestheticHelps)")

        XCTAssertEqual(a.cells, 0, "premise (R1): with Allow quilt off Structural lays nothing on his pad")
        XCTAssertEqual(a.solidShare, 1, accuracy: 0.005, "premise: all of it solid")
        XCTAssertEqual(a.floor, 4.74, accuracy: 0.01, "premise: 4.74 mm the smallest cell with Allow quilt off")
        XCTAssertFalse(ask.smallerCellsHelp, "★ smaller cells cannot help")
        XCTAssertTrue(ask.quiltHelps && ask.aestheticHelps, "★ both offers lay")
        XCTAssertGreaterThan(on.cells, 0, "★ Allow quilt on lays his pad")
        XCTAssertEqual(on.floor, 0.9 / (1 / (2 * 2.0.squareRoot())), accuracy: 0.01, "with it on the smallest cell is the quilt's, 2.55 mm")
        XCTAssertGreaterThanOrEqual(on.smallest, 4.0 - 0.01, "★ never a cell under the 4 mm the depth needs")
        XCTAssertEqual(on.solidShare, 0, accuracy: 0.05, "★ the pad is latticed")

        // a normal part: a 60 × 60 × 40 mm block, its top as Lattice 40 mm deep, the same settings
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("notes30-x2-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let blockPath = dir.appendingPathComponent("block.stl").path
        let xy = stride(from: Float(0), through: 60, by: 10).map { $0 }
        try LatticePlaceChipsTests.gridSTL(xy, xy, [0, 20, 40]) { _, _, _ in true }.write(to: URL(fileURLWithPath: blockPath))
        let m = try TopOptKit.importMesh(path: blockPath)
        let top = try XCTUnwrap(LatticePlaceChipsTests.face(m, axis: 2, sign: 1, at: 40), "the block's top")
        let block = try await LatticeLayoutSession.open(path: blockPath)
        addTeardownBlock { block.close() }
        let bbox = try XCTUnwrap(LatticeLayoutPreview.box(m.vertices))
        var bOff = offS, bOn = onS
        bOff.regions = [.init(id: 1, faces: [top], depthMM: 40)]; bOff.protect = []
        bOn.regions = bOff.regions; bOn.protect = []
        let nOff = try await Self.lay(block, bOff, box: bbox)
        print("NOTES30-X2 BLOCK 40 mm, Allow quilt off: \(nOff)")
        let nOn = try await Self.lay(block, bOn, box: bbox)
        print("NOTES30-X2 BLOCK 40 mm, Allow quilt ON: \(nOn)")
        // MEASURED (the answer's second half, said in the offer's (i)): on a deeper face the switch is not neutral — Default
        // Grade halves the cells along the face (its ladder may go under 4.74 mm now) and the band thickens their struts until
        // they touch (the band's ceiling is the quilt with Allow quilt on: set_struts' `ceiling`)
        XCTAssertEqual(nOff.atQuilt, 0, "Allow quilt off: nothing touches")
        XCTAssertGreaterThan(nOn.smallest, 0)
        XCTAssertLessThan(nOn.smallest, nOff.smallest - 0.01, "★ measured: Allow quilt on halves the cells along a deeper face")
        XCTAssertGreaterThan(nOn.atQuilt, 0, "★ measured: …and some of their struts thicken until they touch")
        XCTAssertEqual(on.atQuilt, 0, "★ his pad: no strut touches (its 4 mm cells are its finest: no band under them)")

        // the second offer, measured: Aesthetic (the mode alone, Auto) lays his pad
        p.latticePageManual = false; p.lattice.allowQuilt = false
        SolidReason.take(.switchToAesthetic, on: p)
        let ae = try await Self.lay(session, LatticeLayoutPreview.settings(p), box: box)
        print("NOTES30-X2 PAD Aesthetic (Auto): \(ae)")
        XCTAssertGreaterThan(ae.cells, 0, "★ Switch to Aesthetic lays his pad")
        XCTAssertEqual(ae.solidShare, 0, accuracy: 0.05)
    }

    // MARK: 2 · the triangle's card

    /// ★ The warning glyph's card: the centred (i) card ("Tap anywhere to continue"), every failure with its fix first, and its
    /// setting fixes as its buttons (the cell size, the density — one per setting), each going to the setting with what to
    /// try. RED CONTROL: a card with no setting fix offers no button.
    func testTheTrianglesCardOffersItsSettingFixes() {
        let card = LatticeFaceCard(faceID: 1, depthMM: 14.7, heldVoxels: 100, heldVolumeMM3: 100, heldMassG: 1, cellMM: 4.93,
                                   relativeDensity: 0.27, strutDiameterMM: 0.32, cellsPerMember: 14.7 / 4.93, verdict: .outOfRegime)
        let d = LatticeFaceDiagnosis.merged([LatticeFaceDiagnosis.of(card: card, cellsPerMemberFloor: 5, nozzleWidthMM: 0.45)])
        XCTAssertEqual(d.problems.count, 2, "premise: two failures")
        XCTAssertEqual(d.changes.map(\.field), [.cellSize, .density], "★ one button per setting, in the order the fixes name them")
        XCTAssertEqual(d.changes.map(\.title), ["Change the cell size", "Change the density"])
        XCTAssertEqual(d.changes.first?.tryText, "Try 2.9 mm cells", "★ what to try, the fix's own number")
        var went: [String] = []
        LatticeDiagnosisCard.open(d) { went.append($0.tryText) }
        let pop = AppPopups.shared
        XCTAssertEqual(pop.current?.info, true, "★ the (i)'s centred card")
        XCTAssertEqual(pop.current?.title, LatticeDiagnosisCard.title)
        XCTAssertEqual(pop.current?.text, d.popoverText, "★ every failure, the fix first")
        XCTAssertFalse(pop.dismissShown, "★ no OK: Tap anywhere to continue")
        XCTAssertEqual(pop.infoActions.map(\.title), ["Change the cell size", "Change the density"], "★ its fixes are its buttons")
        pop.infoActions.last?.run()
        XCTAssertEqual(went, ["Try above 27%"], "★ the button goes to its setting with what to try")
        for w in d.changes.map(\.title) + d.changes.map(\.tryText) { XCTAssertLessThanOrEqual(LatticeCaptions.words(w), 5, w) }
        // RED CONTROL: a failure with no setting fix (nothing to lighten) — no button
        let empty = LatticeFaceCard(faceID: 2, depthMM: 5, heldVoxels: 0, heldVolumeMM3: 0, heldMassG: 0, cellMM: 4,
                                    relativeDensity: 0.2, strutDiameterMM: 0.9, cellsPerMember: 1.2, verdict: .noMaterial)
        let e = LatticeFaceDiagnosis.of(card: empty, cellsPerMemberFloor: 5, nozzleWidthMM: 0.45)
        LatticeDiagnosisCard.open(e) { _ in }
        XCTAssertTrue(pop.infoActions.isEmpty, "RED CONTROL: no setting fix, no button")
        pop.current = nil
    }

    /// ★ An (i) over a pop-up: its card opens over it, and a tap anywhere gives the pop-up back as it was (its buttons, its
    /// (i)); a new pop-up replaces both. RED CONTROL: closing by setting nothing up (as every tap did) loses the pop-up.
    func testAnInfoOverAPopUpGivesThePopUpBack() {
        let pop = AppPopups.shared
        var taken = 0
        pop.choose("This needs 4 mm cells", "Pick a way below.", first: ("Turn Allow quilt on", { taken += 1 }),
                   second: ("Switch to Aesthetic", {}), third: ("Leave it solid", {}), dismiss: nil,
                   why: (SolidPopUp.offersWhyTitle, "What each does."))
        let id = pop.current?.id
        pop.openWhy()
        XCTAssertEqual(pop.current?.info, true, "★ the (i)'s card is up")
        XCTAssertEqual(pop.current?.title, SolidPopUp.offersWhyTitle)
        XCTAssertTrue(pop.holds(id), "★ the pop-up waits under it")
        pop.close()
        XCTAssertEqual(pop.current?.id, id, "★ a tap anywhere: the pop-up back")
        XCTAssertEqual([pop.action?.title, pop.second?.title, pop.third?.title], ["Turn Allow quilt on", "Switch to Aesthetic", "Leave it solid"])
        XCTAssertFalse(pop.dismissShown, "no fourth button")
        XCTAssertEqual(pop.why?.title, SolidPopUp.offersWhyTitle, "★ its (i) again")
        pop.action?.run()
        XCTAssertEqual(taken, 1)
        pop.openWhy()
        pop.show("Another", "A new pop-up.")
        XCTAssertFalse(pop.holds(id), "a new pop-up replaces both")
        pop.close()
        XCTAssertNil(pop.current, "and closes as before")
        // the pop-up's (i) is the one (i) (AppInfoButton: `help`): its card opens over the pop-up the same way
        pop.choose("T", "x", first: ("A", {}), second: nil, dismiss: nil, why: ("W", "w"))
        let tid = pop.current?.id
        pop.help("W", "w")
        XCTAssertTrue(pop.holds(tid), "★ the one (i)'s card over a pop-up keeps it")
        pop.close()
        XCTAssertEqual(pop.current?.id, tid, "★ and gives it back")
        pop.current = nil
        // RED CONTROL: the (i)'s card closed the old way — nothing comes back
        pop.choose("T", "x", first: ("A", {}), second: nil, dismiss: nil, why: ("W", "w"))
        pop.openWhy()
        pop.current = nil
        XCTAssertNil(pop.current, "RED CONTROL: the pop-up is lost")
    }
}
#endif
