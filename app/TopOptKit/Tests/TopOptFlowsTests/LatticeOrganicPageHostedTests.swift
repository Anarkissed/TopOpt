// LatticeOrganicPageHostedTests — his 11-18 iPad notes on the Lattice page with Organic on (img 2): "only those settings are
// visible when Organic is turned on. If on Auto, all but Look is invisible"; no "Manual · this area" with nothing below it; no
// Strength; Auto Sweep / Manual Sweep, not the old Auto / Manual cell size and its "cannot form a lattice" refusal. On the real
// page (LatticeSetupWizard's cells page, an area's tab open) at the six windows, Auto then Manual; pictures with
// APP_BUILD_SHOT_DIR. RED CONTROL: the regular lattice still shows its own rows.
#if canImport(AppKit) && canImport(MetalKit)
import XCTest
import SwiftUI
import AppKit
@testable import TopOptFlows
@testable import TopOptKit

@MainActor
final class LatticeOrganicPageHostedTests: XCTestCase {

    override nonisolated func setUp() { super.setUp(); FlexibleSaid.recording = true }   // the page publishes its ids
    override nonisolated func tearDown() { FlexibleSaid.recording = false; super.tearDown() }

    final class Probe { var all: [String: CGRect] = [:] }

    func project(organic: Bool, manual: Bool) throws -> ProjectModel {
        let p = try FlexiblePressFixtures.a1Project(3, self, facePrism: false).project
        p.lattice.flexible = nil
        p.lattice.chooseLatticeType(.aesthetic)
        if organic { p.lattice.algorithm = "organic" }
        p.latticePageManual = manual
        XCTAssertNotNil(p.importedFile, "premise: the part has its model file (the new engine)")
        // a real lattice group (a face, Lattice), so the page has its tab (LatticeAreaGradingHostedTests' way)
        let f = try XCTUnwrap(p.selection.groups.first?.faces.first, "premise: a face")
        _ = p.latticeStageTap(face: f, loop: [f])
        let g = try XCTUnwrap(p.latticeList.activeGroupID)
        p.lattice.groupRoles[g] = .include
        p.latticeList.clearActive()
        XCTAssertEqual(p.latticeAreaGroups.map(\.id), [g], "premise: one group, its own tab")
        return p
    }

    func visit(_ p: ProjectModel, size: CGSize, area: Bool = false) -> (AppBuildHost, Probe) {
        let pr = Probe()
        let v = LatticeSetupWizard(project: p, onExit: {}).cellsPage(regions: p.latticeAreaGroups.map(\.name), closeToken: 0)
            .onPreferenceChange(LatticeProbeKey.self) { pr.all = $0 }
        let h = AppBuildHost(v, size: size, test: self)
        h.pump(1.2)
        for id in ["wizard-stage-\(LatticeWizardStage.allCases.last!.rawValue)"] + (area ? ["lattice-page-tab-area-0"] : []) {
            if let f = pr.all[id] ?? h.frames.all[id], f.width > 1 { h.click(CGPoint(x: f.midX, y: f.midY), settle: 0.6) }
        }
        h.pump(0.6)
        return (h, pr)
    }

    /// ★ Per group (his 11-18: "whole part ONLY if the whole part is latticed. Otherwise, it is per Group"): a group's tab
    /// holds its own Organic settings — Look alone in Auto, the Organic settings and only those in Manual — at the six windows.
    func testOrganicShowsOnlyItsOwnSettingsAtTheSixWindows() throws {
        for size in AppBuildHost.sweep {
            let name = "\(Int(size.width))x\(Int(size.height))"
            // Auto: Look alone, on the group's tab
            do {
                let (h, pr) = visit(try project(organic: true, manual: false), size: size, area: true)
                let look = try XCTUnwrap(pr.all["lattice-organic-look"],
                                         "★ \(name) Auto: Look is on the group's tab; ids: \(pr.all.keys.sorted().joined(separator: " "))")
                XCTAssertTrue(CGRect(origin: .zero, size: size).contains(look), "★ \(name) Auto: Look inside the window")
                XCTAssertNil(pr.all["lattice-organic-controls"], "★ \(name) Auto: no Manual settings")
                for old in ["wizard-organic-look", "wizard-organic-shape-band"] {
                    XCTAssertNil(pr.all[old], "★ \(name) Auto: the old Organic row is gone (\(old))")
                }
                try h.picture("organic-page-auto-\(name).png")
            }
            // Manual: the Organic settings, and only those, on the group's tab
            do {
                let (h, pr) = visit(try project(organic: true, manual: true), size: size, area: true)
                let c = try XCTUnwrap(pr.all["lattice-organic-controls"], "★ \(name) Manual: the group's Organic settings")
                XCTAssertGreaterThan(c.height, 200, "★ \(name) Manual: its lines are drawn")
                XCTAssertNil(pr.all["lattice-organic-look"], "★ \(name) Manual: no Look")
                for old in ["wizard-organic-look", "wizard-organic-shape-band", "wizard-seg-uniform"] {
                    XCTAssertNil(pr.all[old], "★ \(name) Manual: no old or regular row (\(old))")
                }
                try h.picture("organic-page-manual-\(name).png")
            }
        }
        // the Part tab with groups: no Organic settings, one line saying where they are
        do {
            let (_, pr) = visit(try project(organic: true, manual: true), size: AppBuildHost.landscape13)
            XCTAssertNil(pr.all["lattice-organic-controls"], "★ groups: the Part tab holds no Organic settings")
            XCTAssertNotNil(pr.all["lattice-page-organic-part-note"], "★ it says each group sets its own")
        }
        // the whole part latticed: the Part tab holds them, a group's tab its finish only
        do {
            let p = try project(organic: true, manual: true)
            p.lattice.wholePart = true
            let (h, pr) = visit(p, size: AppBuildHost.landscape13)
            XCTAssertNotNil(pr.all["lattice-organic-controls"], "★ whole part latticed: the Part tab holds Organic's settings")
            try h.picture("organic-page-whole-part.png")
            let (_, pa) = visit(p, size: AppBuildHost.landscape13, area: true)
            XCTAssertNil(pa.all["lattice-organic-controls"], "★ whole part latticed: no Organic settings on a group's tab")
        }
        // each group's own: what one group sets is not another's (nor the whole part's)
        do {
            let p = try project(organic: true, manual: true)
            let g = try XCTUnwrap(p.latticeAreaGroups.first?.id, "premise: a group")
            var mine = p.lattice.organicLook(group: g)
            mine.mode = .traced
            mine.lookPercent = 80
            p.lattice.setOrganicLook(mine, group: g)
            XCTAssertEqual(p.lattice.organicLook(group: g).modeValue, .traced)
            XCTAssertEqual(p.lattice.organicLook(group: nil).modeValue, .grown, "RED CONTROL: the whole part's is its own")
            XCTAssertEqual(p.lattice.organicLook(group: UUID()).lookPercentValue, 15, "another group: Auto (his start, 15)")
            let back = try JSONDecoder().decode(LatticeSettings.self, from: JSONEncoder().encode(p.lattice))
            XCTAssertEqual(back.organicLook(group: g), mine, "★ saved with the project")
            // ★ his 11-18: "Simulate stresses on unstressed walls ... ONLY in organic and in aesthetic"; foci per wall
            XCTAssertFalse(p.organicSyntheticOn(group: g), "RED CONTROL: off until he turns it on")
            var synth = p.lattice.organicLook(group: g)
            synth.syntheticStresses = true
            p.lattice.setOrganicLook(synth, group: g)
            XCTAssertTrue(p.organicSyntheticOn(group: g), "★ Organic, Aesthetic, Manual, the switch on: the group's walls get foci")
            XCTAssertEqual(LatticeSettings().organicSyntheticFoci, 3, "★ his 11-18 default: 3 foci")
            p.lattice.stageMode = .structural
            XCTAssertFalse(p.organicSyntheticOn(group: g), "★ never in Structural")
        }
        // RED CONTROL: the regular lattice in Manual keeps its rows
        let (_, pr) = visit(try project(organic: false, manual: true), size: AppBuildHost.landscape13, area: true)
        XCTAssertNotNil(pr.all["wizard-seg-uniform"], "RED CONTROL: the regular lattice's Manual rows are there")
        XCTAssertNil(pr.all["lattice-organic-controls"], "RED CONTROL: no Organic settings on the regular lattice")
    }
}
#endif
