// Notes29DensityDialTests — ★ his iPad notes on release 20, 2026-11-25: "Every single lattice type was quilted ... limit both
// when 'Allow quilt' is turned off. The 'Density' grade percentage should then be limited within that, with a notification
// popping up if they try to go further (like 100%) saying that it can't until 'Allow Quilt' is turned back on." And his
// sample's footer read "density 107 → 10 %".
//   · 100 % is each type's OWN quilt (core's touch through the engine), never "half the cell" (the octet-style rule every
//     type was read by); the percent is never over 100.
//   · With Allow quilt off a percent past the type's open look is refused, and the centred pop-up says Allow quilt must be
//     on (FlexibleSaid's recording: AppPopups.recorded). RED control: with Allow quilt on the same percent is taken.
//   · The page's percent reaches core as the dial that lays that strut (with Allow quilt off, the open look is core's 1).
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

    /// ★ Allow quilt off: past the open look is refused, and the pop-up says so in plain words (title of five words at most).
    /// RED CONTROL: Allow quilt on takes it, and nothing pops up.
    func testPastTheOpenLookIsRefusedWithAPopUp() throws {
        for id in Self.types {
            let open = try XCTUnwrap(LatticeDensityDial.openLookPercent(cellMM: 8, topology: id, lineWidthMM: Self.line), id)
            XCTAssertLessThan(open, 100, "\(id): the open look is under the quilt")
            AppPopups.recorded = []
            XCTAssertTrue(LatticeDensityDial.accept(open.rounded(.down), allowQuilt: false, cellMM: 8, topology: id, lineWidthMM: Self.line),
                          "\(id): up to the open look is taken")
            XCTAssertTrue(AppPopups.recorded.isEmpty)
            XCTAssertFalse(LatticeDensityDial.accept(100, allowQuilt: false, cellMM: 8, topology: id, lineWidthMM: Self.line),
                           "★ \(id): 100 % with Allow quilt off is refused")
            let p = try XCTUnwrap(AppPopups.recorded.last, id)
            XCTAssertEqual(p.title, LatticeDensityDial.refusedTitle)
            XCTAssertLessThanOrEqual(p.title.split(separator: " ").count, 5, "the title: five words at most")
            XCTAssertTrue(p.text.contains("Allow quilt"), "★ it says Allow quilt must be on: \(p.text)")
            XCTAssertTrue(p.text.contains("\(Int(open.rounded(.down))) %"), "it says how far it may go: \(p.text)")
            for bad in ["std::", "open look", "open_look", "_"] { XCTAssertFalse(p.text.contains(bad), "plain words: \(p.text)") }
            AppPopups.recorded = []
            XCTAssertTrue(LatticeDensityDial.accept(100, allowQuilt: true, cellMM: 8, topology: id, lineWidthMM: Self.line),
                          "RED CONTROL: \(id) with Allow quilt on goes to 100 %")
            XCTAssertTrue(AppPopups.recorded.isEmpty)
        }
    }

    /// ★ The page's boxes (Grade from, Grade to): a stored density shows the dial percent (never over 100 %); a typed percent
    /// past the open look stores nothing with Allow quilt off; within it, it stores the density that shows that percent back.
    func testTheGradeBoxesSpeakTheDial() throws {
        var l = LatticeSettings()
        l.topologyID = "bccz"
        l.stageMode = .aesthetic
        let off = LatticeDensityDial.Page(l, lineWidthMM: Self.line, allowQuilt: false)
        let on = LatticeDensityDial.Page(l, lineWidthMM: Self.line, allowQuilt: true)
        XCTAssertLessThanOrEqual(off.shown(1.0), 1.0, "★ a density of 1 shows at most 100 %")
        XCTAssertLessThan(off.most, 100)
        AppPopups.recorded = []
        XCTAssertNil(off.typed(100), "★ Allow quilt off: 100 % stores nothing")
        XCTAssertEqual(AppPopups.recorded.last?.title, LatticeDensityDial.refusedTitle)
        let rho = try XCTUnwrap(off.typed(off.most), "within the open look it stores")
        XCTAssertEqual(off.shown(rho) * 100, off.most, accuracy: 1.0, "and shows back what was typed")
        XCTAssertNotNil(on.typed(100), "RED CONTROL: Allow quilt on stores 100 %")
    }

    /// ★ The percent reaches core as the dial that lays that strut: with Allow quilt off the open look's percent is core's 1
    /// (its widest), the thinnest its 0.01; with it on, 100 % is core's 1 and the open look's percent is under it.
    func testThePercentIsCoresDial() throws {
        for id in Self.types {
            let open = try XCTUnwrap(LatticeDensityDial.openLookPercent(cellMM: 8, topology: id, lineWidthMM: Self.line))
            let offTop = LatticeDensityDial.coreDial(percent: open, cellMM: 8, topology: id, lineWidthMM: Self.line,
                                                     minStrutLines: 2, allowQuilt: false)
            XCTAssertEqual(offTop, 1, accuracy: 1e-6, "★ \(id): the open look is core's widest with Allow quilt off")
            XCTAssertEqual(LatticeDensityDial.coreDial(percent: 1, cellMM: 8, topology: id, lineWidthMM: Self.line,
                                                       minStrutLines: 2, allowQuilt: false), 0.01, accuracy: 1e-6)
            XCTAssertEqual(LatticeDensityDial.coreDial(percent: 100, cellMM: 8, topology: id, lineWidthMM: Self.line,
                                                       minStrutLines: 2, allowQuilt: true), 1, accuracy: 1e-6)
            XCTAssertLessThan(LatticeDensityDial.coreDial(percent: open, cellMM: 8, topology: id, lineWidthMM: Self.line,
                                                          minStrutLines: 2, allowQuilt: true), 1, "RED CONTROL: \(id), on")
        }
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
        l.smallCellsInThinWalls = true   // his per-part choice: no longer brings the quilt back
        let plan = LatticeSampleLay.page(l, lineWidthMM: Self.line, wallRingMM: 0.9)
        let made = try await LatticeSampleLay.lay(plan, cube: false)
        XCTAssertGreaterThan(made.pctHi, 0)
        XCTAssertLessThanOrEqual(made.pctHi, 100, "★ never over 100 %")
        let caption = LatticeSampleLay.caption(made, typeName: "BCC + Z", cube: false, finish: plan.finishWord, band: plan.band)
        let numbers = caption.components(separatedBy: "density ").dropFirst().first?
            .components(separatedBy: " %").first?.components(separatedBy: " → ").compactMap { Int($0) } ?? []
        XCTAssertFalse(numbers.isEmpty, caption)
        XCTAssertTrue(numbers.allSatisfy { $0 >= 1 && $0 <= 100 }, "★ \(caption)")
    }
}
