// LatticeAreaGradingHostedTests — release (2), the reviewer's ruling of 2026-11-06 09:41Z, item 1: "B7 sends E3's per-region
// keys from its tabs and drops its 'until E3' line", and ruling (2): "#362's B7 shows one plain line under the shape grade:
// 'The run's shape grade is a solid outline; the band and Strength are preview only.'"
//
// An area's tab on the Lattice page sets its own grade — on or off, what varies, the shape band (`LatticeSettings.areaGrading`,
// keyed by the lattice group). Each include region the area emits sends what differs from the part as core's per-region
// `grading` / `shape_grade_band_mm` (LatticeTypes' E3, 4ace41f5), each falling back to the job's `grading.*`. The preview draws
// one grade, so Save keeps the part's grade where every area agrees and no region sends a key — the picture is the run.
#if canImport(AppKit) && canImport(MetalKit)
import XCTest
import SwiftUI
import AppKit
@testable import TopOptFlows
@testable import TopOptKit
import TopOptDesign

@MainActor
final class LatticeAreaGradingHostedTests: XCTestCase {

    /// His Lattice stage with Group 1 (a face, Lattice) and Zone 1 (a 30 × 20 × 12 mm box, Lattice): two areas.
    private func twoAreas() throws -> (ProjectModel, face: UUID, zone: UUID) {
        let (h, p, _) = try ParityTopologyShots.pad(AppBuildHost.landscape13, test: self)
        p.lattice.clearLatticeType()
        p.lattice.chooseLatticeType(.structural)
        try h.pickFromMenu("capsuleMenu", "Structural", what: "the stage menu")
        h.pump(1)
        let f = try XCTUnwrap(p.selection.groups.first?.faces.first)
        _ = p.latticeStageTap(face: f, loop: [f])
        let g = try XCTUnwrap(p.latticeList.activeGroupID)
        p.lattice.groupRoles[g] = .include
        p.latticeList.clearActive()
        let z = try XCTUnwrap(p.addLatticeZone())
        p.setLatticeZoneSize(z, width: 30, depth: 20, height: 12)
        p.lattice.enabled = true
        p.lattice.simulateStresses = true
        p.lattice.densityMode = .sim   // graded: the job carries the `grading` block the region keys fall back to
        h.pump(1)
        XCTAssertEqual(p.latticeAreaGroups.map(\.id), [g, z], "premise: two areas, the group's tab then the zone's")
        return (p, g, z)
    }

    private func zoneRegion(_ p: ProjectModel) throws -> [String: Any] {
        try XCTUnwrap(p.latticeJobRegions().regions.first { $0.kind == .face && abs($0.halfUMM - 15) < 1e-6 }, "the zone's slab")
            .wireDictionary
    }

    private func faceRegions(_ p: ProjectModel) -> [[String: Any]] {
        p.latticeJobRegions().regions.filter { !($0.kind == .face && abs($0.halfUMM - 15) < 1e-6) }.map(\.wireDictionary)
    }

    /// ★ An area's own grade reaches ITS include regions, and only theirs; nothing where it grades as the part.
    func testAnAreasOwnGradeReachesItsRegionsOnly() throws {
        XCTAssertTrue(TopOptKit.regionGradingWired, "premise: the linked core takes E3's per-region keys")
        let (p, _, z) = try twoAreas()
        XCTAssertNil(try zoneRegion(p)["grading"], "no key where the area grades as the part")

        p.lattice.areaGrading[z] = LatticeAreaGrading(gradingMode: LatticeGradingMode.none)
        XCTAssertEqual(try zoneRegion(p)["grading"] as? String, "off", "★ the zone's Grade off is core's \"off\"")
        XCTAssertNil(try zoneRegion(p)["shape_grade_band_mm"], "no band on a grade that does not fit the shape")
        XCTAssertTrue(faceRegions(p).allSatisfy { $0["grading"] == nil && $0["shape_grade_band_mm"] == nil },
                      "★ the other area's regions carry nothing")

        p.lattice.areaGrading[z] = LatticeAreaGrading(gradingMode: .stressOnly)
        XCTAssertEqual(try zoneRegion(p)["grading"] as? String, "stress")
        p.lattice.areaGrading[z] = LatticeAreaGrading(shapeFitBandMM: p.lattice.shapeFitBandMM + 10)
        XCTAssertNil(try zoneRegion(p)["grading"], "the part's mode (Stress + shape) is not restated")
        XCTAssertEqual(try zoneRegion(p)["shape_grade_band_mm"] as? Double, p.lattice.shapeFitBandMM + 10, "★ its own band")

        // an exclude carries no grade (core refuses one there), and a uniform job has no grading for the keys to fall back to
        p.lattice.groupRoles[z] = .exclude
        XCTAssertNil(try zoneRegion(p)["shape_grade_band_mm"])
        p.lattice.groupRoles[z] = .include
        p.lattice.densityMode = .uniform
        XCTAssertNil(try zoneRegion(p)["shape_grade_band_mm"], "★ uniform: no grading block, so no area grade")
        XCTAssertTrue(p.lattice.resolvedAreaGrading.isEmpty)
    }

    /// ★ The linked core's parser takes the regions as the app writes them — and refuses a grade on an exclude (the control).
    func testCoreTakesTheAreasKeys() throws {
        let (p, _, z) = try twoAreas()
        p.lattice.areaGrading[z] = LatticeAreaGrading(gradingMode: .fitShape, shapeFitBandMM: 24)
        func job(_ regions: [[String: Any]]) throws -> Data {
            let text = String(decoding: try JSONSerialization.data(withJSONObject: regions, options: [.sortedKeys]), as: UTF8.self)
            return Data(TopOptKit.latticeProbeBaseJob.replacingOccurrences(
                of: #""output":"#,
                with: #""grading": {"topology": "octet", "min_extrudable_width_mm": 0.4, "cell_mm": 4.0}, "lattice": {"topology": "octet", "regions": "#
                    + text + #"}, "output":"#).utf8)
        }
        let regions = p.latticeJobRegions().regions.map(\.wireDictionary)
        XCTAssertTrue(regions.contains { $0["grading"] as? String == "shape" }, "premise: the zone sends its own grade")
        XCTAssertNil(TopOptKit.jobSchemaError(try job(regions)), "★ core parses the app's regions")
        var bad = regions
        let i = try XCTUnwrap(bad.firstIndex { $0["grading"] != nil })
        bad[i]["role"] = "exclude"
        XCTAssertNotNil(TopOptKit.jobSchemaError(try job(bad)), "★ CONTROL: core refuses a grade on an exclude region")
    }

    /// ★ Save keeps ONE grade where the areas agree (the preview draws one), else the first area's is the part's.
    func testSaveKeepsOneGradeWhereTheAreasAgree() {
        let a = UUID(), b = UUID()
        var s = LatticeSettings(enabled: true)
        s.gradingMode = .full
        let band = s.shapeFitBandMM
        s.saveAreaGrading([a: .init(gradingMode: .stressOnly), b: .init(gradingMode: .stressOnly)], areas: [a, b])
        XCTAssertEqual(s.gradingMode, .stressOnly, "★ both areas Stress: the part's grade is Stress")
        XCTAssertTrue(s.areaGrading.isEmpty, "★ and no area sends its own")

        s.gradingMode = .full
        s.saveAreaGrading([b: .init(gradingMode: LatticeGradingMode.none, shapeFitBandMM: band + 6)], areas: [a, b])
        XCTAssertEqual(s.gradingMode, .full, "the first area grades as the part")
        XCTAssertEqual(s.areaGrading, [b: .init(gradingMode: LatticeGradingMode.none, shapeFitBandMM: band + 6)])

        s.saveAreaGrading([a: .init(gradingMode: .fitShape), UUID(): .init(gradingMode: .stressOnly)], areas: [a, b])
        XCTAssertEqual(s.gradingMode, .fitShape, "the first area's grade leads")
        XCTAssertEqual(s.areaGrading, [b: .init(gradingMode: .full)], "★ the other keeps the part's old grade; a gone area drops")

        s.wholePart = true
        s.gradingMode = .full
        s.saveAreaGrading([a: .init(gradingMode: .stressOnly)], areas: [a, b])
        XCTAssertEqual(s.gradingMode, .full, "★ Start from −: the part's grade is the rest of the part's, not moved")
        XCTAssertEqual(s.areaGrading, [a: .init(gradingMode: .stressOnly)])

        // a saved project round-trips; an untouched one writes no key
        let data = try? JSONEncoder().encode(s)
        XCTAssertEqual(try? JSONDecoder().decode(LatticeSettings.self, from: data ?? Data()).areaGrading, s.areaGrading)
        let plain = try? JSONEncoder().encode(LatticeSettings(enabled: true))
        XCTAssertFalse(String(decoding: plain ?? Data(), as: UTF8.self).contains("areaGrading"), "★ older bytes unchanged")
    }

    /// ★ The page: "These settings apply to every region today" is gone from the area tab; the tab says which rows are its
    /// own, and the shape grade carries the reviewer's line until core's band is real.
    func testTheLinesOnThePage() throws {
        let src = try FlexibleSource.code("LatticeSetupWizard.swift")
        let r = try XCTUnwrap(src.range(of: "private func latticeTabBody(_ c: CellsPageContext) -> AnyView {"))
        let body = String(src[r.upperBound...].prefix(2400))
        XCTAssertFalse(body.contains("LatticeCellsRow.tabsNote"), "★ the until-E3 line is gone from the area tab")
        XCTAssertTrue(body.contains("shortNote(Self.latticeAreaOwnLine)"))
        XCTAssertTrue(src.contains("pick: { id in withAnimation(.easeInOut(duration: 0.15)) { openLatticeTab(id, c) } }"),
                      "★ a tab opens through the swap that keeps each area's grade")
        XCTAssertEqual(LatticeSetupWizard.shapeGradeRunLine,
                       "The run's shape grade is a solid outline; the band and Strength are preview only.")
        XCTAssertTrue(src.contains("if !TopOptKit.gradingSchemaAccepts(key: \"shape_grade_strength\") {\n"
                                   + "                shortNote(Self.shapeGradeRunLine)"),
                      "★ under the shape grade, until the linked core takes the band's strength")
        // ★ RE-PINNED (release (3), core e26b8038, ruling 2): the linked core builds the band and takes its strength, so
        // the line goes by itself (it showed on release (2)'s 565cc17c).
        XCTAssertTrue(TopOptKit.gradingSchemaAccepts(key: "shape_grade_strength"), "★ release (3)'s core: the line is gone")
    }

    /// ★ B7 slice 2 (release (3), the reviewer 11-07 19:55Z): the band's Strength and a zone's own Finish reach the job —
    /// the part's strength in `grading`, the zone's in its regions, its finish as `regions[].outer_finish` — and the linked
    /// core parses them; a finish core doesn't know is refused (the control).
    func testStrengthAndAZonesFinishReachTheJob() throws {
        XCTAssertTrue(TopOptKit.gradingSchemaAccepts(key: "shape_grade_strength"), "premise: release (3)'s core")
        XCTAssertTrue(TopOptKit.regionOuterFinishWired, "premise: release (3)'s core takes a region's own finish")
        let (p, _, z) = try twoAreas()
        XCTAssertNil(try zoneRegion(p)["outer_finish"], "nothing where the zone's finish is the part's")
        XCTAssertNil(try zoneRegion(p)["shape_grade_strength"])
        p.lattice.areaGrading[z] = LatticeAreaGrading(shapeGradeStrength: 0.5, outerFinish: "none")
        XCTAssertEqual(try zoneRegion(p)["outer_finish"] as? String, "none", "★ the zone is open")
        XCTAssertEqual(try zoneRegion(p)["shape_grade_strength"] as? Double, 0.5, "★ its own strength")
        XCTAssertTrue(faceRegions(p).allSatisfy { $0["outer_finish"] == nil && $0["shape_grade_strength"] == nil },
                      "★ the other area's regions carry nothing")
        func job(_ regions: [[String: Any]]) throws -> Data {
            let text = String(decoding: try JSONSerialization.data(withJSONObject: regions, options: [.sortedKeys]), as: UTF8.self)
            return Data(TopOptKit.latticeProbeBaseJob.replacingOccurrences(
                of: #""output":"#,
                with: #""grading": {"topology": "octet", "min_extrudable_width_mm": 0.4, "cell_mm": 4.0, "shape_grade": true, "shape_grade_strength": 0.5}, "lattice": {"topology": "octet", "regions": "#
                    + text + #"}, "output":"#).utf8)
        }
        let regions = p.latticeJobRegions().regions.map(\.wireDictionary)
        XCTAssertNil(TopOptKit.jobSchemaError(try job(regions)), "★ core parses the app's strength and finish")
        var bad = regions
        let i = try XCTUnwrap(bad.firstIndex { $0["outer_finish"] != nil })
        bad[i]["outer_finish"] = "open"
        XCTAssertNotNil(TopOptKit.jobSchemaError(try job(bad)), "★ CONTROL: core refuses a finish it doesn't know")
        // the part's strength in `grading`, with the shape grade (0, today's amount, is not restated)
        var s = LatticeSettings(enabled: true)
        s.densityMode = .sim
        s.algorithm = "doubled"
        s.gradingMode = .full
        s.shapeFitGradeStrength = -0.5
        let g = try XCTUnwrap(XCTUnwrap(s.runSpec(lineWidthMM: 0.45)).gradingDictionary())
        XCTAssertEqual(g["shape_grade_strength"] as? Double, -0.5, "★ the part's strength rides the shape grade")
        s.shapeFitGradeStrength = 0
        XCTAssertNil(try XCTUnwrap(XCTUnwrap(s.runSpec(lineWidthMM: 0.45)).gradingDictionary())["shape_grade_strength"],
                     "0 is core's default and is not restated")
    }
}
#endif
