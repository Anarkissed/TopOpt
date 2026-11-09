// LatticeFinishWireTests — B7 slice 2b (the reviewer 11-08 21:32Z, rulings 3 and 4; ruling 11-06 (1), core E2.4 5fe8e992).
//
// The app sent `lattice.outer_finish` only for Covered, and an absent key is core's "shell": None ran as a covered part
// (the preview draws it open) and Skin ran as the shell with the anchored diagrid's balls under it, not the woven skin.
// Each finish now states core's word; Rim is greyed until the engine builds it on a real part; Results says the receipt's
// finish facts in words.
import XCTest
@testable import TopOptFlows
@testable import TopOptKit

final class LatticeFinishWireTests: XCTestCase {

    override func tearDown() {
        LatticeBoundaryTreatment.controlShellDefault = false
        super.tearDown()
    }

    /// ★ Each finish states core's word, red first: the control restores the old mapping, where None and Skin carried
    /// nothing (core's default shell).
    func testEachFinishStatesCoresWord() {
        XCTAssertTrue(TopOptKit.latticeOpenFinishWired, "premise: the linked core has E2.4's open finish")
        let want: [(LatticeBoundaryTreatment, String?)] = [(.none, "none"), (.rim, nil), (.fullSkin, "skin"), (.covered, "shell")]
        for (t, w) in want { XCTAssertEqual(t.jobOuterFinish, w, "\(t)") }
        LatticeBoundaryTreatment.controlShellDefault = true
        XCTAssertNil(LatticeBoundaryTreatment.none.jobOuterFinish, "★ CONTROL: before 2b None ran under core's shell")
        XCTAssertNil(LatticeBoundaryTreatment.fullSkin.jobOuterFinish, "★ CONTROL: before 2b Skin ran under core's shell")
        XCTAssertEqual(LatticeBoundaryTreatment.covered.jobOuterFinish, "shell")
    }

    /// ★ The run spec carries the pair core reads (skin, outer_finish), and each pair parses in the linked core; core
    /// refuses "skin" without the diagrid (the control).
    func testTheRunSpecCarriesThePairCoreParses() throws {
        func job(skin: String, finish: String?) -> Data {
            let of = finish.map { #", "outer_finish": "\#($0)""# } ?? ""
            return Data(TopOptKit.latticeProbeBaseJob.replacingOccurrences(
                of: #""output":"#,
                with: #""grading": {"topology": "octet", "min_extrudable_width_mm": 0.4, "cell_mm": 3.0}, "lattice": {"topology": "octet", "skin": "\#(skin)""#
                    + of + #", "regions": [{"role": "include", "kind": "face", "geometry": {"origin": [0, 0, 0], "normal": [0, 0, 1], "half_u_mm": 10, "half_w_mm": 10, "depth_mm": 5}}]}, "output":"#).utf8)
        }
        let want: [(LatticeBoundaryTreatment, String, String?)] = [(.none, "none", "none"), (.rim, "rim", nil),
                                                                   (.fullSkin, "diagrid", "skin"), (.covered, "none", "shell")]
        for (t, skin, finish) in want {
            var s = LatticeSettings(enabled: true)
            s.boundary = t
            s.minRelativeDensity = 0.2; s.maxRelativeDensity = 0.4
            let spec = try XCTUnwrap(s.runSpec(lineWidthMM: 0.42))
            XCTAssertEqual(spec.skin, skin, "\(t)")
            XCTAssertEqual(spec.outerFinish, finish, "\(t)")
            XCTAssertNil(TopOptKit.jobSchemaError(job(skin: skin, finish: finish)), "★ core parses \(t)'s pair")
        }
        XCTAssertNotNil(TopOptKit.jobSchemaError(job(skin: "none", finish: "skin")),
                        "★ CONTROL: core refuses the skin finish without the diagrid")
    }

    /// ★ Ruling 3 (a): Results says the receipt's finish facts in plain words.
    func testTheReceiptsFinishFactsInWords() throws {
        func receipt(_ json: String) -> Data { Data(json.utf8) }
        XCTAssertEqual(LatticeReport.finishLines(receipt: nil), [])
        XCTAssertEqual(LatticeReport.finishLines(receipt: receipt(#"{"lattice_accepted": true}"#)), [],
                       "a covered part with nothing to say says nothing")
        let zone = receipt(#"""
            {"grading": {"shape_band": {"band_voxels": 900, "solid_where_unprintable": 37,
               "solid_box_mm": [2.04, 3, 0.5, 10, 8.25, 4]}},
             "open_finish": {"cut_cell_voxels": 128, "latticed_voxels": 4000, "cut_cell_credit": "none",
               "load_path_after": true, "regions": ["Zone 1 open: a wall closes it from the covered part"],
               "wall_mm": 0.9, "wall_voxels": 210}}
            """#)
        XCTAssertEqual(LatticeReport.finishLines(receipt: zone), [
            "Solid where no cell prints: 37 voxels, between x 2–10, y 3–8.3, z 0.5–4 mm.",
            "Zone 1 is open: a 0.9 mm wall closes it from the covered part.",
        ])
        let open = receipt(#"{"open_finish": {"cut_cell_voxels": 128, "latticed_voxels": 4000, "load_path_after": true}}"#)
        XCTAssertEqual(LatticeReport.finishLines(receipt: open),
                       ["Open finish: 128 voxels of cells at the surface get no strength credit (the safe floor)."])
        let skin = receipt(#"{"lattice_accepted": false, "finish_certified": false}"#)
        XCTAssertEqual(LatticeReport.finishLines(receipt: skin),
                       ["Skin: with no solid shell the engine doesn't certify this lattice yet, so it isn't accepted."])
    }

    /// ★ Ruling 4: Rim greyed with one line until the engine builds it; Skin says, before the run, that it isn't certified.
    func testRimIsGreyedAndSkinSaysItIsNotCertified() throws {
        XCTAssertTrue(LatticeSetupWizard.rimNeedsEngineWork, "un-grey Rim when LatticeTypes' rim on a real part lands")
        let src = try FlexibleSource.code("LatticeSetupWizard.swift")
        XCTAssertTrue(src.contains("selected: boundaryIndex, greyed: Self.rimNeedsEngineWork ? [1] : []"),
                      "★ the finish row greys Rim (index 1)")
        XCTAssertTrue(src.contains(".disabled(greyed)"), "★ a greyed choice is not picked by a tap")
        XCTAssertTrue(src.contains("model.boundary == .rim ? Self.rimStoredLine : Self.rimGreyedLine"))
        XCTAssertEqual(LatticeSetupWizard.rimGreyedLine, "Rim needs engine work: the engine builds no rim on a real part yet.")
        XCTAssertTrue(src.contains("captionLine(Self.skinNotCertifiedLine"))
        XCTAssertTrue(src.contains("segmentButton(title, on: shown == value, greyed: partWord == nil)"),
                      "★ a zone's finish is greyed under the part's Skin or Rim")
    }
}
