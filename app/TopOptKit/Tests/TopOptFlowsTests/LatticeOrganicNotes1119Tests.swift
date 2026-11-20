// LatticeOrganicNotes1119Tests — his 11-19 iPad notes on release (10), the app's part:
//   * "Auto should also have a selection for Traced vs Grown. This should be in 'Part'" — the Part tab in Auto, setting the
//     whole part's mode and every group's;
//   * "The look shouldn't show the range of mm" — no Cells line under Look;
//   * "The colour legend doesn't really work for Organic ... It should be a singular colour" — one colour, no key;
//   * "Rim should be hidden" under Organic;
//   * "They have VERY hard edges and stair-step. It should be a single straight or curved line" — the Organic cut map
//     softened and read linear.
// RED CONTROLS: the regular lattice keeps its colours; a map that is not softened stays as the engine gave it.
#if canImport(AppKit) && canImport(MetalKit)
import XCTest
import SwiftUI
@testable import TopOptFlows
@testable import TopOptKit

@MainActor
final class LatticeOrganicNotes1119Tests: XCTestCase {

    override nonisolated func setUp() { super.setUp(); FlexibleSaid.recording = true }
    override nonisolated func tearDown() { FlexibleSaid.recording = false; super.tearDown() }

    func testThePartsModeSetsEveryGroupInAuto() {
        var s = LatticeSettings(enabled: true)
        let a = UUID(), b = UUID()
        var la = LatticeOrganicLook(); la.mode = .grown; la.lookPercent = 70
        s.setOrganicLook(la, group: a)
        XCTAssertEqual(s.organicModeForThePart(groups: [a, b]), .grown, "both Grown (b at its default)")
        s.setOrganicModeForThePart(.traced, groups: [a, b])
        XCTAssertEqual(s.organicLook(group: a).modeValue, .traced, "★ a group's mode follows the Part tab")
        XCTAssertEqual(s.organicLook(group: b).modeValue, .traced)
        XCTAssertEqual(s.organicLook(group: nil).modeValue, .traced, "★ and the whole part's")
        XCTAssertEqual(s.organicLook(group: a).lookPercentValue, 70, "★ nothing else of the group's is touched")
        XCTAssertEqual(s.organicModeForThePart(groups: [a, b]), .traced)
        var lb = s.organicLook(group: b); lb.mode = .grown; s.setOrganicLook(lb, group: b)
        XCTAssertEqual(s.organicModeForThePart(groups: [a, b]), .traced, "groups that disagree: the whole part's shows")
    }

    /// ★ Cut 2's two switches, built ahead of the engine (his 11-19): their defaults, saved with the project, and not offered
    /// until the engine takes them.
    func testTheCut2SwitchesDefaultsAndGate() throws {
        var l = LatticeOrganicLook()
        XCTAssertTrue(l.depthVariationValue, "★ \"Default is not flush\"")
        XCTAssertTrue(l.extraSpacingValue(aesthetic: true), "★ \"On in Aesthetic only\"")
        XCTAssertFalse(l.extraSpacingValue(aesthetic: false), "★ off in Structural")
        l.depthVariation = false
        l.extraSpacing = true
        let back = try JSONDecoder().decode(LatticeOrganicLook.self, from: JSONEncoder().encode(l))
        XCTAssertEqual(back, l, "saved with the project")
        XCTAssertFalse(back.extraSpacingValue(aesthetic: false) == false, "his choice beats the mode's default")
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(LatticeOrganicLook()), as: UTF8.self).contains("depthVariation"),
                       "★ an untouched look writes no key (older bytes unchanged)")
        XCTAssertFalse(LatticeOrganicLook.cut2Wired, "★ not offered until the engine takes organic_face_relief_mm and organic_strand_keep")
        XCTAssertEqual(LatticeOrganicLook.faceReliefOnMM, 1.0)
        XCTAssertEqual(LatticeOrganicLook.strandKeepOn, 0.9)
        XCTAssertEqual(LatticeOrganicLook.strandKeepOff, 0.5)
    }

    /// ★ His 11-20 skin note: "skin thickness and density of skin tendrils should be added as manual variables". Auto by
    /// default (thickness Auto, density 3), the engine's ranges (OJ8: 0 to 3 mm; 1 to 6), saved with the project, an untouched
    /// look writes neither, and not offered until the engine takes a group's finish.
    func testTheSkinsTwoManualVariables() throws {
        var l = LatticeOrganicLook()
        XCTAssertNil(l.skinWidthMM, "★ thickness Auto")
        XCTAssertEqual(l.skinDensityValue, 3, "★ density 3, the usual")
        XCTAssertEqual(Array(LatticeOrganicLook.skinDensityRange), [1, 2, 3, 4, 5, 6])
        XCTAssertNil(LatticeOrganicLook.Check.skinWidth(0), "0 = Auto")
        XCTAssertNil(LatticeOrganicLook.Check.skinWidth(1.2))
        XCTAssertNil(LatticeOrganicLook.Check.skinWidth(3))
        XCTAssertNotNil(LatticeOrganicLook.Check.skinWidth(3.5), "★ past the engine's 3 mm: refused in a plain line")
        XCTAssertNotNil(LatticeOrganicLook.Check.skinWidth(-1))
        l.skinWidthMM = 1.2
        l.skinDensity = 5
        let back = try JSONDecoder().decode(LatticeOrganicLook.self, from: JSONEncoder().encode(l))
        XCTAssertEqual(back, l, "saved with the project")
        let fresh = String(decoding: try JSONEncoder().encode(LatticeOrganicLook()), as: UTF8.self)
        XCTAssertFalse(fresh.contains("skinWidth") || fresh.contains("skinDensity"), "★ an untouched look writes no key")
        let old = try JSONDecoder().decode(LatticeOrganicLook.self, from: Data(#"{"lookPercent": 40}"#.utf8))
        XCTAssertNil(old.skinDensity, "an older project reads")
        XCTAssertFalse(LatticeOrganicLook.finishWired, "★ not offered until the engine takes a group's finish")
    }

    func testOrganicIsOneColourAndTheRegularLatticeKeepsItsKey() {
        var l = LatticeLayoutColours.Laid()
        // two bars: one plain, one flagged skin (bit 1)
        l.bars = [0, 0, 0, 1, 0, 0, 0.8, 0, 0, 0, 0, 1, 0, 0.8]
        l.barFlags = [0, 2]
        l.barCell = [4, 4]
        l.barRegion = [1, 1]
        l.token = 1
        let one = LatticeLayoutColours.colours(l, type: nil, grade: false, oneColour: true)
        XCTAssertEqual(one.count, 2)
        XCTAssertEqual(one[0], one[1], "★ Organic: one colour")
        let keyed = LatticeLayoutColours.colours(l, type: nil, grade: false)
        XCTAssertNotEqual(keyed[0], keyed[1], "RED CONTROL: the regular lattice still colours a skin bar by the key")
    }

    func testTheSoftenedMapCutsAlongASmoothLine() {
        // a slanted cut through a 24 x 24 x 4 map: open where x + 0.6 y < 14 (the engine's yes/no voxels, stair-stepped)
        let d = SIMD3<Int32>(24, 24, 4)
        var rg = [Int8](repeating: 0, count: 2 * 24 * 24 * 4)
        for z in 0..<4 { for y in 0..<24 { for x in 0..<24 {
            let i = (z * 24 + y) * 24 + x
            rg[2 * i] = Double(x) + 0.6 * Double(y) < 14 ? 127 : -127
            rg[2 * i + 1] = 127
        } } }
        let soft = LatticeLayoutSolidGrid.smoothed(rg, dims: d)
        XCTAssertEqual(soft.count, rg.count)
        // along each row (z = 2), the zero crossing found by linear reading; its line against y is straight
        func crossing(_ m: [Int8], y: Int) -> Double? {
            for x in 0..<23 {
                let a = Double(m[2 * ((2 * 24 + y) * 24 + x)]), b = Double(m[2 * ((2 * 24 + y) * 24 + x + 1)])
                if a >= 0, b < 0 { return Double(x) + a / (a - b) }
            }
            return nil
        }
        func roughness(_ m: [Int8]) -> Double {
            let xs = (2..<20).compactMap { y in crossing(m, y: y).map { (Double(y), $0) } }
            // the largest jump of the second difference: 0 for a straight line, about 1 voxel for stair-steps
            var worst = 0.0
            for k in 1..<(xs.count - 1) { worst = Swift.max(worst, abs(xs[k + 1].1 - 2 * xs[k].1 + xs[k - 1].1)) }
            return worst
        }
        let hard = roughness(rg), smooth = roughness(soft)
        XCTAssertGreaterThan(hard, 0.5, "premise: the engine's map stair-steps")
        XCTAssertLessThan(smooth, 0.35, "★ softened, the cut is a smooth line (was \(hard))")
        XCTAssertEqual(LatticeLayoutSolidGrid.smoothed([Int8](repeating: 127, count: 2 * 8), dims: SIMD3(2, 2, 2)),
                       [Int8](repeating: 127, count: 16), "a map with no cut is unchanged")
    }

    /// The page: in Auto the Part tab carries Traced / Grown; Look shows no millimetres; Rim is not offered under Organic.
    func testThePageAtAuto() throws {
        let p = try FlexiblePressFixtures.a1Project(3, self, facePrism: false).project
        p.lattice.flexible = nil
        p.lattice.chooseLatticeType(.aesthetic)
        p.lattice.algorithm = "organic"
        p.latticePageManual = false
        let f = try XCTUnwrap(p.selection.groups.first?.faces.first, "premise: a face")
        _ = p.latticeStageTap(face: f, loop: [f])
        let g = try XCTUnwrap(p.latticeList.activeGroupID)
        p.lattice.groupRoles[g] = .include
        p.latticeList.clearActive()
        final class Probe { var all: [String: CGRect] = [:] }
        func visit(area: Bool) -> Probe {
            let pr = Probe()
            let v = LatticeSetupWizard(project: p, onExit: {}).cellsPage(regions: p.latticeAreaGroups.map(\.name), closeToken: 0)
                .onPreferenceChange(LatticeProbeKey.self) { pr.all = $0 }
            let h = AppBuildHost(v, size: AppBuildHost.landscape13, test: self)
            h.pump(1.2)
            for id in ["wizard-stage-\(LatticeWizardStage.allCases.last!.rawValue)"] + (area ? ["lattice-page-tab-area-0"] : []) {
                if let fr = pr.all[id] ?? h.frames.all[id], fr.width > 1 { h.click(CGPoint(x: fr.midX, y: fr.midY), settle: 0.6) }
            }
            h.pump(0.6)
            return pr
        }
        let part = visit(area: false)
        XCTAssertNotNil(part.all["lattice-organic-part-mode"], "★ Auto: Traced / Grown on the Part tab; ids: \(part.all.keys.sorted())")
        let tab = visit(area: true)
        XCTAssertNotNil(tab.all["lattice-organic-look"], "premise: Look on the group's tab")
        XCTAssertNil(tab.all["lattice-zone-finish-rim"], "★ no Rim under Organic")
        let src = try FlexibleSource.code("LatticeSetupWizard.swift")
        XCTAssertFalse(src.contains("\"Cells %@ to %@ mm\""), "★ no millimetres under Look")
        p.latticePageManual = true
        XCTAssertNil(visit(area: false).all["lattice-organic-part-mode"], "RED CONTROL: Manual sets the mode per group")
    }
}
#endif
