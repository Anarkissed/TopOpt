// Notes29DensityDialTests — ★ his iPad notes on release 20, 2026-11-25: "Every single lattice type was quilted ... limit both
// when 'Allow quilt' is turned off. The 'Density' grade percentage should then be limited within that, with a notification
// popping up if they try to go further (like 100%) saying that it can't until 'Allow Quilt' is turned back on." And his
// sample's footer read "density 107 → 10 %".
//   · 100 % is each type's OWN quilt (core's touch through the engine), never "half the cell" (the octet-style rule every
//     type was read by); the percent is never over 100.
//   · ★ notes29b: with Allow quilt off a percent past the type's LIMIT (one printed line short of its quilt, just under
//     100 %) is refused, and the centred pop-up says Allow quilt must be on, with an (i) for why (FlexibleSaid's recording:
//     AppPopups.recorded); past the open look and up to the limit is taken. RED control: with Allow quilt on, 100 % is taken.
//   · The page's percent reaches core as the dial that lays that strut (with Allow quilt off, the open look is core's 1 and
//     the limit is past 1).
//   · The sample's footer says the Density percent, never over 100.
import XCTest
import TopOptKit
@testable import TopOptFlows

@MainActor
final class Notes29DensityDialTests: XCTestCase {
    override func setUp() { super.setUp(); FlexibleSaid.recording = true; AppPopups.recorded = []; AppPopups.shared.current = nil }
    override func tearDown() { FlexibleSaid.recording = false; AppPopups.shared.current = nil; super.tearDown() }

    static let types = ["octet", "sc", "bcc", "fcc", "diamond", "kelvin", "rhombic", "bccz", "fccz", "reentrant"]
    static let line = 0.45

    /// ★ 100 % is the type's own quilt: the band's top is core's touch x the cell, for every strut type the engine lays.
    /// RED CONTROL: the old rule (half the cell) is not it for sc, bcc, fcc, bccz, fccz (their quilts are not half the cell).
    func testOneHundredPercentIsTheTypesOwnQuilt() throws {
        var differs = 0
        for id in Self.types {
            let f = LatticeLayoutSession.typeFacts(id)
            XCTAssertTrue(f.lays, "\(id): the engine lays it")
            let q = try XCTUnwrap(LatticeDensityDial.limits(topology: id), id)
            XCTAssertEqual(q.quilt, f.touch, "\(id): the quilt is core's touch")
            XCTAssertLessThan(q.openLook, q.quilt, "\(id): the open look is under the quilt")
            for cell in [4.0, 8.0, 12.0] {
                let b = try XCTUnwrap(ProjectModel.latticeDensityBandDiametersMM(topology: id, lineWidthMM: Self.line, cellMM: cell))
                XCTAssertEqual(b.hi, f.touch * cell, accuracy: 1e-9, "★ \(id) at \(cell) mm: 100 % is its own quilt")
                // never over 100, whatever the strut
                XCTAssertEqual(LatticeDensityDial.percent(strutMM: 10 * cell, cellMM: cell, topology: id, lineWidthMM: Self.line), 100)
                XCTAssertEqual(LatticeDensityDial.percent(strutMM: f.touch * cell, cellMM: cell, topology: id, lineWidthMM: Self.line)!,
                               100, accuracy: 1e-9)
            }
            if abs(f.touch - 0.5) > 0.01 { differs += 1 }
        }
        XCTAssertGreaterThanOrEqual(differs, 9, "RED CONTROL: half the cell is no type's quilt but fccz's")
    }

    /// ★ notes29b: Allow quilt off stops one printed line short of the quilt (core's lattice_quilt_off_strut_mm: touch x cell
    /// - one line), just under 100 %; the open look is no longer the stop (a percent past it is taken). Past the limit is
    /// refused, and the pop-up says so in plain words (title of five words at most), with an (i) for the reason.
    /// RED CONTROL: Allow quilt on takes 100 %, and nothing pops up.
    func testPastTheQuiltLimitIsRefusedWithAPopUp() throws {
        for id in Self.types {
            let f = LatticeLayoutSession.typeFacts(id)
            let open = try XCTUnwrap(LatticeDensityDial.openLookPercent(cellMM: 8, topology: id, lineWidthMM: Self.line), id)
            let limit = try XCTUnwrap(LatticeDensityDial.offMostPercent(cellMM: 8, topology: id, lineWidthMM: Self.line), id)
            XCTAssertEqual(try XCTUnwrap(LatticeDensityDial.offMostMM(cellMM: 8, topology: id, lineWidthMM: Self.line)),
                           f.touch * 8 - Self.line, accuracy: 1e-12, "★ \(id): one line short of the touch (core's rule)")
            XCTAssertLessThan(limit, 100, "\(id): the limit is under the quilt")
            XCTAssertGreaterThan(limit, open + 1, "★ \(id): the limit is past the open look")
            AppPopups.recorded = []
            XCTAssertTrue(LatticeDensityDial.accept((open + 1).rounded(.up), allowQuilt: false, cellMM: 8, topology: id,
                                                    lineWidthMM: Self.line), "★ \(id): past the open look is taken now")
            XCTAssertTrue(LatticeDensityDial.accept(limit.rounded(.down), allowQuilt: false, cellMM: 8, topology: id,
                                                    lineWidthMM: Self.line), "\(id): up to the limit is taken")
            XCTAssertTrue(AppPopups.recorded.isEmpty)
            XCTAssertFalse(LatticeDensityDial.accept(limit.rounded(.down) + 1, allowQuilt: false, cellMM: 8, topology: id,
                                                     lineWidthMM: Self.line), "★ \(id): one past the limit is refused")
            XCTAssertFalse(LatticeDensityDial.accept(100, allowQuilt: false, cellMM: 8, topology: id, lineWidthMM: Self.line),
                           "★ \(id): 100 % with Allow quilt off is refused")
            let p = try XCTUnwrap(AppPopups.recorded.last, id)
            XCTAssertEqual(p.title, LatticeDensityDial.refusedTitle)
            XCTAssertFalse(p.info, "a refusal, not an (i)")
            XCTAssertLessThanOrEqual(p.title.split(separator: " ").count, 5, "the title: five words at most")
            XCTAssertTrue(p.text.contains("Allow quilt"), "★ it says Allow quilt must be on: \(p.text)")
            XCTAssertTrue(p.text.contains("\(Int(limit.rounded(.down))) %"), "it says how far it may go: \(p.text)")
            for bad in ["std::", "open look", "open_look", "_"] { XCTAssertFalse(p.text.contains(bad), "plain words: \(p.text)") }
            // its (i): the reason, in the centred card
            XCTAssertEqual(AppPopups.shared.action?.title, LatticeDensityDial.refusedInfoButton)
            AppPopups.shared.action?.run()
            let info = try XCTUnwrap(AppPopups.recorded.last, id)
            XCTAssertTrue(info.info && info.text.contains("one printed line"), "★ the (i) says why: \(info.text)")
            AppPopups.recorded = []
            XCTAssertTrue(LatticeDensityDial.accept(100, allowQuilt: true, cellMM: 8, topology: id, lineWidthMM: Self.line),
                          "RED CONTROL: \(id) with Allow quilt on goes to 100 %")
            XCTAssertTrue(AppPopups.recorded.isEmpty)
        }
    }

    /// ★ The page's boxes (Grade from, Grade to): a stored density shows the dial percent (never over 100 %); a typed percent
    /// past the limit stores nothing with Allow quilt off; within it (past the open look too), it stores the density that
    /// shows that percent back.
    func testTheGradeBoxesSpeakTheDial() throws {
        var l = LatticeSettings()
        l.topologyID = "bccz"
        l.stageMode = .aesthetic
        let off = LatticeDensityDial.Page(l, lineWidthMM: Self.line, allowQuilt: false)
        let on = LatticeDensityDial.Page(l, lineWidthMM: Self.line, allowQuilt: true)
        XCTAssertLessThanOrEqual(off.shown(1.0), 1.0, "★ a density of 1 shows at most 100 %")
        XCTAssertLessThan(off.most, 100)
        let open = try XCTUnwrap(LatticeDensityDial.openLookPercent(cellMM: off.cellMM, topology: "bccz", lineWidthMM: Self.line))
        XCTAssertGreaterThan(off.most, open, "★ notes29b: the box stops at the limit, past the open look")
        AppPopups.recorded = []
        XCTAssertNil(off.typed(100), "★ Allow quilt off: 100 % stores nothing")
        XCTAssertEqual(AppPopups.recorded.last?.title, LatticeDensityDial.refusedTitle)
        let rho = try XCTUnwrap(off.typed(off.most), "within the limit it stores")
        XCTAssertEqual(off.shown(rho) * 100, off.most, accuracy: 1.0, "and shows back what was typed")
        XCTAssertNotNil(on.typed(100), "RED CONTROL: Allow quilt on stores 100 %")
    }

    /// ★ The percent reaches core as the dial that lays that strut: with Allow quilt off the open look's percent is core's 1,
    /// the thinnest its 0.01, and (★ notes29b) the limit's percent is past 1, the dial on which core's own rule (R10, the
    /// same steps of width past 1) lays the limit's strut, one line short of the touch; with it on, 100 % is core's 1.
    func testThePercentIsCoresDial() throws {
        for id in Self.types {
            let q = try XCTUnwrap(LatticeDensityDial.limits(topology: id))
            let open = try XCTUnwrap(LatticeDensityDial.openLookPercent(cellMM: 8, topology: id, lineWidthMM: Self.line))
            let offTop = LatticeDensityDial.coreDial(percent: open, cellMM: 8, topology: id, lineWidthMM: Self.line,
                                                     minStrutLines: 2, allowQuilt: false)
            XCTAssertEqual(offTop, 1, accuracy: 1e-6, "★ \(id): the open look is core's 1 with Allow quilt off")
            XCTAssertEqual(LatticeDensityDial.coreDial(percent: 1, cellMM: 8, topology: id, lineWidthMM: Self.line,
                                                       minStrutLines: 2, allowQuilt: false), 0.01, accuracy: 1e-6)
            let limit = try XCTUnwrap(LatticeDensityDial.offMostPercent(cellMM: 8, topology: id, lineWidthMM: Self.line))
            let past = LatticeDensityDial.coreDial(percent: limit, cellMM: 8, topology: id, lineWidthMM: Self.line,
                                                   minStrutLines: 2, allowQuilt: false)
            XCTAssertGreaterThan(past, 1, "★ \(id): past the open look is core's dial past 1")
            // core's R10 on the 8 mm cell: thinnest + (dial - 0.01) / 0.99 x (open look x cell - thinnest)
            let thinnest = 2 * Self.line
            let strut = thinnest + (past - 0.01) / 0.99 * (q.openLook * 8 - thinnest)
            XCTAssertEqual(strut, q.quilt * 8 - Self.line, accuracy: 1e-6, "★ \(id): core lays the limit's strut")
            XCTAssertEqual(LatticeDensityDial.coreDial(percent: 100, cellMM: 8, topology: id, lineWidthMM: Self.line,
                                                       minStrutLines: 2, allowQuilt: false), past, accuracy: 1e-9,
                           "★ \(id): never past the limit with Allow quilt off")
            XCTAssertEqual(LatticeDensityDial.coreDial(percent: 100, cellMM: 8, topology: id, lineWidthMM: Self.line,
                                                       minStrutLines: 2, allowQuilt: true), 1, accuracy: 1e-6)
            XCTAssertLessThan(LatticeDensityDial.coreDial(percent: limit, cellMM: 8, topology: id, lineWidthMM: Self.line,
                                                          minStrutLines: 2, allowQuilt: true), 1, "RED CONTROL: \(id), on")
        }
    }
    /// ★ notes29b (his question on release 20: "Are you saying that no matter what happens, all Small cells in thin walls are
    /// going to be quilted?" -- no): the switch is on offer again with Allow quilt off (not greyed; greyed only with Allow
    /// quilt on, where it is moot), its captions are five words at most, its (i) says it never fuses, and a thin wall's
    /// pop-up offers it again. RED CONTROL: with Allow quilt on it is not offered.
    func testSmallCellsInThinWallsIsOnOfferAgain() throws {
        var u = URL(fileURLWithPath: #filePath); for _ in 0..<3 { u.deleteLastPathComponent() }
        let wizard = try String(contentsOf: u.appendingPathComponent("Sources/TopOptFlows/LatticeSetupWizard.swift"), encoding: .utf8)
        let block = try XCTUnwrap(wizard.components(separatedBy: "private var smallCellsSwitch").dropFirst().first?
            .components(separatedBy: "private var singleCellSwitch").first)
        // (362's merge of N1: the page's own switch, model.allowQuilt, and N1's captions)
        XCTAssertTrue(block.contains(".disabled(model.allowQuilt)"), "★ greyed only with Allow quilt on")
        XCTAssertFalse(block.contains(".disabled(true)"), "★ never greyed for good")
        XCTAssertTrue(block.contains("Self.smallCellsInfo"), "★ its (i) is the engine's own rule")
        for caption in [LatticeSetupWizard.smallCellsQuiltLine, LatticeSetupWizard.smallCellsOnLine,
                        LatticeSetupWizard.smallCellsOffLine] {
            XCTAssertLessThanOrEqual(caption.split(separator: " ").count, 5, "★ five words at most: \(caption)")
            XCTAssertFalse(caption.contains("Needs Allow quilt"), "★ not tied to Allow quilt: \(caption)")
        }
        XCTAssertTrue(LatticeSetupWizard.smallCellsInfo.contains("never fuse"), LatticeSetupWizard.smallCellsInfo)
        XCTAssertTrue(LatticeSetupWizard.smallCellsInfo.contains("one printed line"), LatticeSetupWizard.smallCellsInfo)
        var l = LatticeSettings()
        l.stageMode = .aesthetic
        l.allowQuilt = false
        XCTAssertTrue(SolidReason.of(share: 0.2, nocell: [0, 10, 0, 0, 0], lattice: l)?.fixes.contains(.smallCells) == true,
                      "★ a thin wall's pop-up offers it")
        l.allowQuilt = true
        XCTAssertFalse(SolidReason.of(share: 0.2, nocell: [0, 10, 0, 0, 0], lattice: l)?.fixes.contains(.smallCells) == true,
                       "RED CONTROL: with Allow quilt on it is moot, not offered")
    }

    /// ★ The sample's footer says the Density percent, never over 100 ("density 107 → 10 %" on BCC + Z). The sample is laid
    /// by the engine as his page asks it: Manual, By stress, Stepped with Grade to shape, Rim, Allow quilt off.
    func testTheSampleFooterIsNeverOverOneHundred() async throws {
        var l = LatticeSettings()
        l.chooseLatticeType(.aesthetic)
        l.topologyID = "bccz"
        l.algorithm = "stepped"
        l.boundary = .rim
        l.allowQuilt = false
        l.smallCellsInThinWalls = true   // his per-part choice: thin walls only, never fused (★ notes29b)
        let plan = LatticeSampleLay.page(l, lineWidthMM: Self.line, wallRingMM: 0.9)
        let made = try await LatticeSampleLay.lay(plan, cube: false)
        XCTAssertGreaterThan(made.pctHi, 0)
        XCTAssertLessThanOrEqual(made.pctHi, 100, "★ never over 100 %")
        XCTAssertLessThan(made.pctHi, 100, "★ notes29b: Allow quilt off lays no strut at its quilt (100 %)")
        let caption = LatticeSampleLay.caption(made, typeName: "BCC + Z", cube: false, finish: plan.finishWord, band: plan.band)
        let numbers = caption.components(separatedBy: "density ").dropFirst().first?
            .components(separatedBy: " %").first?.components(separatedBy: " → ").compactMap { Int($0) } ?? []
        XCTAssertFalse(numbers.isEmpty, caption)
        XCTAssertTrue(numbers.allSatisfy { $0 >= 1 && $0 <= 100 }, "★ \(caption)")
    }
}
