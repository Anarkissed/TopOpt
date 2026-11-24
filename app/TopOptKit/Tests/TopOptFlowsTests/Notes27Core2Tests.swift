// ★ notes27 core2 (362's follow-up): the strengthening said per group in his words, the group's name sent with the Mac's
// job, and a tap on a print file read as a share of its limit.

import XCTest
@testable import TopOptFlows
@testable import TopOptKit

@MainActor
final class Notes27Core2Tests: XCTestCase {
    /// Core's per-group keys (name, thickest_setting_mm, past_thickest) become one plain line per group in the (i).
    func testEachGroupSaysItsThickestSettingAndHowManyArePastIt() throws {
        var r = Notes27Fixture.report()
        var g = r[LatticeFileButton.strengthenKey] as! [String: Any]
        g["thickened_distinct"] = 12; g["widest_mm"] = 2.6; g["past_thickest"] = 4
        g["groups"] = [["id": 0, "name": "Back wall", "regions": [1], "thickest_setting_mm": 2.25, "past_thickest": 4,
                        "thickened_distinct": 9, "widest_mm": 2.6],
                       ["id": 1, "regions": [2], "thickest_setting_mm": 1.5, "past_thickest": 0, "thickened_distinct": 3,
                        "widest_mm": 1.5]]
        r[LatticeFileButton.strengthenKey] = g
        let f = try XCTUnwrap(LatticeFileFacts.decode(r))
        let s = try XCTUnwrap(f.strengthening)
        XCTAssertEqual(s.groupLines, ["Back wall: thickest set 2.25 mm · 4 struts past it",
                                      "Group 2: thickest set 1.50 mm · none past it"])
        let row = try XCTUnwrap(f.rows(.strength).first { $0.label == "Strengthened" })
        let info = try XCTUnwrap(row.info)
        XCTAssertTrue(info.contains("Back wall: thickest set 2.25 mm · 4 struts past it."), info)
        XCTAssertTrue(info.contains("Group 2: thickest set 1.50 mm · none past it."), info)
        // RED CONTROL: one group (the whole part) says no group line
        g["groups"] = [["id": 0, "regions": [1], "thickest_setting_mm": 2.25, "past_thickest": 4]]
        r[LatticeFileButton.strengthenKey] = g
        let one = try XCTUnwrap(LatticeFileFacts.decode(r)?.rows(.strength).first { $0.label == "Strengthened" }?.info)
        XCTAssertFalse(one.contains("thickest set"), one)
    }

    /// His name for a group rides with it to the Mac's job (core says it back in strengthen.json); none for a nameless one.
    func testTheGroupsNameIsSentWithTheJob() throws {
        let s = LatticeLayoutSession.Settings()
        let ask = LatticeOrganicLook().ask(limits: nil)
        let groups = [LatticeLayoutSession.OrganicGroup(regions: [1], ask: ask, name: "Back wall"),
                      LatticeLayoutSession.OrganicGroup(regions: [2], ask: ask)]
        let job = try XCTUnwrap(JSONSerialization.jsonObject(with: try LatticeFileJob.build(s, modelName: "p.step",
                                                                                             organic: groups)) as? [String: Any])
        let og = try XCTUnwrap((job["layout"] as? [String: Any])?["organic_groups"] as? [[String: Any]])
        XCTAssertEqual(og.count, 2)
        XCTAssertEqual(og[0]["name"] as? String, "Back wall")
        XCTAssertNil(og[1]["name"], "RED CONTROL: a nameless group sends no name")
    }

    /// ★ K7, K8: Auto asks core to fit its cells to the faces the grid is square to (the size with the fewest slivers, a
    /// sliver left taken in by the row beside it); Manual never does. The print file's job carries the two keys only when
    /// asked, so every other job is the bytes it was.
    func testAutoFitsItsCellsToTheSquareFacesAndManualDoesNot() throws {
        let r = try FlexiblePressFixtures.a1Project(3, self, facePrism: false)
        let p = r.project
        p.lattice.stageMode = .aesthetic
        p.latticePageManual = false
        let auto = LatticeLayoutPreview.settings(p)
        XCTAssertTrue(auto.cellSearch, "★ Auto: the cells fitted")
        p.lattice.stageMode = .structural
        XCTAssertTrue(LatticeLayoutPreview.settings(p).cellSearch, "★ Structural Auto asks too (core says its walls keep their own)")
        p.lattice.cellSizeMode = .fixed
        p.lattice.cellMM = 60
        XCTAssertFalse(LatticeLayoutPreview.settings(p).cellSearch, "RED CONTROL: a typed cell size is his: never fitted")
        p.lattice.cellSizeMode = .auto
        p.lattice.stageMode = .aesthetic
        p.latticePageManual = true
        let manual = LatticeLayoutPreview.settings(p)
        XCTAssertFalse(manual.cellSearch, "RED CONTROL: Manual lays his own size")
        let on = try XCTUnwrap(JSONSerialization.jsonObject(with: try LatticeFileJob.build(auto, modelName: "p.step")) as? [String: Any])
        let onLayout = try XCTUnwrap(on["layout"] as? [String: Any])
        XCTAssertEqual(onLayout["cell_search"] as? Bool, true)
        XCTAssertEqual(onLayout["stretch_edges"] as? Bool, true)
        let off = try XCTUnwrap(JSONSerialization.jsonObject(with: try LatticeFileJob.build(manual, modelName: "p.step")) as? [String: Any])
        let offLayout = try XCTUnwrap(off["layout"] as? [String: Any])
        XCTAssertNil(offLayout["cell_search"], "RED CONTROL: not asked, not written")
        XCTAssertNil(offLayout["stretch_edges"])
        var asked = manual
        asked.cellSearch = true
        XCTAssertNotEqual(asked, manual, "★ the preview lays again when it changes")
    }

    /// A tap on a print file says its share of the limit there, never MPa; an optimised part keeps MPa.
    func testATapOnAPrintFileSaysItsShareOfTheLimit() {
        XCTAssertEqual(ResultsScreen.probeText(0.62, share: true), "62% of its limit")
        XCTAssertEqual(ResultsScreen.probeText(1.234, share: true), "123% of its limit")
        XCTAssertFalse(ResultsScreen.probeText(0.62, share: true).contains("MPa"), "RED CONTROL")
        XCTAssertEqual(ResultsScreen.probeText(12.345, share: false), "12.35 MPa")
    }
}
