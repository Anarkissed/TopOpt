// IPadNotes1120Tests — ★ his iPad notes on release (11), 2026-11-20 (relayed by LatticeReview; img1 to img7):
// "All errors should be nice looking Pop-ups at the centre of the screen in clear basic english. It should never be in small
// text and in technical language." · "If I input a number that's wrong, the error should be FRONT AND CENTRE" · the Lattice
// button said "Octet truss" on Organic · "Let the Organic preview finish first" with the preview finished.
import XCTest
import TopOptKit
@testable import TopOptFlows

@MainActor
final class IPadNotes1120Tests: XCTestCase {
    override func setUp() { super.setUp(); FlexibleSaid.recording = true; AppPopups.recorded = []; AppPopups.shared.current = nil }
    override func tearDown() { FlexibleSaid.recording = false; AppPopups.shared.current = nil; super.tearDown() }

    func testAWrongNumberIsSaidFrontAndCentreInPlainWords() {
        AppPopups.shared.wrongNumber("Cell size", "Cell size must be between 0.5 and 40 mm.")
        let p = try? XCTUnwrap(AppPopups.shared.current)
        XCTAssertEqual(p?.title, "Cell size: that number won’t work", "★ the setting named, in plain words")
        XCTAssertEqual(p?.text, "Cell size must be between 0.5 and 40 mm.")
        AppPopups.shared.show("The sample couldn’t be built", "Plain.", log: "lattice_layout_organic_groups: not a std::exception")
        XCTAssertFalse(AppPopups.shared.current!.text.contains("std::"), "★ the engine's words go to the log, never the card")
        XCTAssertEqual(AppPopups.recorded.count, 2)
    }

    func testNoPopUpTextIsTechnical() {
        for t in [LatticeSampleView.organicFailedText, LatticeSampleView.organicFailedCaption, LatticeLayoutPreview.failedPlainLine,
                  LatticeFileExport.organicPlain(LatticeLayoutPreview.OrganicFileWait.laying),
                  LatticeFileExport.organicPlain(LatticeLayoutPreview.OrganicFileWait.outOfDate),
                  LatticeFileExport.organicPlain(TopOptError(message: "bridge: lattice_layout_write_tensor"))] {
            for bad in ["std::", "lattice_layout", "exception", "core", "engine:", "_"] {
                XCTAssertFalse(t.contains(bad), "★ plain English: \"\(t)\" holds \"\(bad)\"")
            }
        }
    }

    func testTheOrganicKeyIsTheSameForEqualSettings() throws {
        // two equal per-group settings built in opposite orders: the key must agree, or the export reads them as moved
        let a = try FlexiblePressFixtures.a1Project(3, self, facePrism: false).project
        let b = try FlexiblePressFixtures.a1Project(3, self, facePrism: false).project
        for p in [a, b] { p.lattice.flexible = nil; p.lattice.chooseLatticeType(.structural); p.lattice.algorithm = "organic" }
        let ids = (0..<8).map { _ in UUID() }
        var look = LatticeOrganicLook()
        for (i, g) in ids.enumerated() { look.lookPercent = Double(10 + i); a.lattice.setOrganicLook(look, group: g) }
        for (i, g) in ids.enumerated().reversed() { look.lookPercent = Double(10 + i); b.lattice.setOrganicLook(look, group: g) }
        XCTAssertEqual(a.lattice.organicLooks, b.lattice.organicLooks, "premise: equal settings")
        XCTAssertEqual(LatticeLayoutPreview.organicKey(a), LatticeLayoutPreview.organicKey(b),
                       "★ equal settings, one key (the export never refuses a finished preview over the order)")
    }

    func testTheExportSaysWhyItWaitsNeverASilentNil() async throws {
        let p = try FlexiblePressFixtures.a1Project(3, self, facePrism: false).project
        let preview = LatticeLayoutPreview()
        do {
            _ = try await preview.organicFileInputs(project: p)
            XCTFail("nothing laid: no inputs")
        } catch let w as LatticeLayoutPreview.OrganicFileWait {
            XCTAssertEqual(w, .notLaid, "★ the reason is said, so the button lays the preview first instead of refusing")
        }
    }

    func testTheLatticeButtonSaysOrganicOnOrganic() throws {
        let p = try FlexiblePressFixtures.a1Project(3, self, facePrism: false).project
        p.lattice.flexible = nil
        p.lattice.chooseLatticeType(.structural)
        p.lattice.algorithm = "organic"
        var traced = LatticeOrganicLook(); traced.mode = .traced
        p.lattice.organicLook = traced
        p.lattice.wholePart = true
        XCTAssertEqual(LatticeLayoutPreview.organicButtonType(p), "Organic Traced", "★ never \"Octet truss\" on Organic")
        var grown = traced; grown.mode = .grown
        p.lattice.organicLook = grown
        XCTAssertEqual(LatticeLayoutPreview.organicButtonType(p), "Organic Grown")
    }

    /// ★ his img7: "a couple words under each setting ... an (i) next to settings": every label the panel shows has a grey
    /// line of at most twelve words and an (i) of a few plain sentences (LatticeReview's sheet, written for him).
    func testEverySettingHasAGreyLineAndAnInfo() {
        let labels = ["Auto / Manual", "Organic", "Look", "Finish", "Skin thickness", "Skin density", "Gradient", "Cell size",
                      "Strut thickness", "Seeds (feet apart) (0 = off)", "Wall seeds", "Wall seed gap (0 = off)", "Crossing vines", "Crossing gap",
                      "Roots (0 = off)", "Top branches (0 = off)", "Stress follow", "Flat ties", "Flat tie gap",
                      "Grade to shape reach (0 = off)", "Detect floating parts", "Simulate stresses on unstressed walls", "Depth variation",
                      "Extra spacing between vines", "Link thickness", "Longest strut without a joint (0 = off)"]
        for l in labels {
            guard let e = OrganicSettingsHelp.entry(l) else { XCTFail("★ \(l) has no help"); continue }
            // ★ his 11-20 correction: "This should be at most 5 words! Twelve is way too much!"
            let words = e.grey.split(separator: " ").count
            XCTAssertLessThanOrEqual(words, 5, "★ \(l): the grey line is five words at most (\(words))")
            let sentences = e.info.split(whereSeparator: { ".!?".contains($0) })
                .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            XCTAssertTrue((3...7).contains(sentences.count), "\(l): the (i) is a few plain sentences (\(sentences.count))")
            for bad in ["organic_", "_mm", "std::"] { XCTAssertFalse(e.info.contains(bad) || e.grey.contains(bad), "\(l): no keys") }
        }
        XCTAssertEqual(OrganicSettingsHelp.entry("Look")!.grey, "1 open. 100 nearly solid.", "★ his 1-100 rule, said")
        XCTAssertLessThanOrEqual(OrganicSettingsHelp.glossaryLink.split(separator: " ").count, 5, "★ the glossary's link, five words at most")
        XCTAssertNil(LatticeOrganicLook.Check.gap("Wall seed gap", close: nil, wide: 0, zeroOff: true), "★ Wall seed gap: 0 = off")
        XCTAssertNotNil(LatticeOrganicLook.Check.gap("Flat tie gap", close: nil, wide: 0), "RED CONTROL: Flat tie gap must be above 0")
        AppPopups.shared.wrongNumber("Roots (0 = off)", "x")
        XCTAssertEqual(AppPopups.shared.current?.title, "Roots: that number won’t work", "the card names the setting plainly")
    }

    /// ★ the engine's new upper limits (bc34b79c), refused at the field with the whole range (his "Can I put 789293?").
    func testTheUpperLimitsAreSaidWithTheRange() {
        typealias C = LatticeOrganicLook.Check
        XCTAssertEqual(C.cell(small: 2, large: 789_293, thinStrutMM: 0.9), "Cell size: the large end must be at most 200 mm.")
        XCTAssertEqual(C.strut(thin: 0.9, thick: 60, thinnestMM: 0.9), "Strut thickness: the thick end must be at most 50 mm.")
        XCTAssertEqual(C.run("Roots", 789_293), "Roots: it must be from 0 (off) to 20 spacings.")
        XCTAssertEqual(C.seeds(21), "Seeds (feet apart): it must be at most 20 spacings (0 is off).")
        XCTAssertEqual(C.reach(11), "Grade to shape reach: it must be from 0 (off) to 10 times.")
        XCTAssertEqual(C.gap("Flat tie gap", close: nil, wide: 25), "Flat tie gap: it must be at most 20 spacings.")
        XCTAssertNil(C.run("Roots", 2)); XCTAssertNil(C.reach(1)); XCTAssertNil(C.seeds(2.5))
        XCTAssertNil(C.cell(small: 2, large: 8, thinStrutMM: 0.9), "RED CONTROL: his 2 to 8 is taken")
    }
}
