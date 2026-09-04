import XCTest
import TopOptKit
@testable import TopOptFlows

/// ★ THE SAMPLE FOLLOWS THE SETTINGS (maintainer, 2026-09-03: "every possible permutation
/// of settings selected by the user") — the picks the tracer is told, derived from the
/// sheet; and the two settings fields certification feeds (the fitting set, the pick).
final class OrganicSampleCubeTests: XCTestCase {

    private func organic() -> LatticeSettings {
        var s = LatticeSettings(); s.enabled = true; s.stageMode = .aesthetic
        s.algorithm = "organic"; s.densityMode = .sim; s.cellSizeMode = .auto
        s.minRelativeDensity = 0.05; s.maxRelativeDensity = 0.12
        return s
    }

    func testAutoTracesThePrintedWindowScaledByTheSpacingScale() {
        var s = organic(); s.organicScale = 1.5
        let p = OrganicSampleCube.Picks(settings: s, layerHeightMM: 0.2)
        XCTAssertEqual(p.separationMinMM, 4.5, accuracy: 1e-9)   // 3 × 1.5
        XCTAssertEqual(p.separationMaxMM, 9.0, accuracy: 1e-9)   // 6 × 1.5
        XCTAssertFalse(p.grow); XCTAssertEqual(p.strutDiameterMM, 0)
        XCTAssertEqual(p.rhoMin, 0.05); XCTAssertEqual(p.rhoMax, 0.12)
        XCTAssertFalse(p.structural)
    }

    func testFitTracesOneSeparationThePickOrTheMiddle() {
        var s = organic(); s.cellSizeMode = .fit
        let mid = OrganicSampleCube.Picks(settings: s, layerHeightMM: 0.2)
        XCTAssertEqual(mid.separationMinMM, 4.5, accuracy: 1e-9)
        XCTAssertEqual(mid.separationMaxMM, 4.5, accuracy: 1e-9)
        s.organicPickedSeparationMM = 3
        let picked = OrganicSampleCube.Picks(settings: s, layerHeightMM: 0.2)
        XCTAssertEqual(picked.separationMinMM, 3); XCTAssertEqual(picked.separationMaxMM, 3)
    }

    func testGrownNeedsALayerHeightAndDropsTheOverhang() {
        var s = organic(); s.organicGrowth = true; s.organicOverhangDeg = 40
        XCTAssertFalse(OrganicSampleCube.Picks(settings: s, layerHeightMM: 0).grow,
                       "no stated layer height ⇒ traced (the same precondition the job has)")
        let g = OrganicSampleCube.Picks(settings: s, layerHeightMM: 0.2)
        XCTAssertTrue(g.grow); XCTAssertEqual(g.layerHeightMM, 0.2)
        XCTAssertEqual(g.overhangDeg, 0, "overhang is trace-only; growth holds its own constant")
        s.organicGrowth = false
        XCTAssertEqual(OrganicSampleCube.Picks(settings: s, layerHeightMM: 0.2).overhangDeg, 40)
    }

    func testThickerStatesTheStrutAndTheBakeVoxelFollowsTheThinnestStrut() {
        var s = organic()
        let bead = OrganicSampleCube.Picks(settings: s, layerHeightMM: 0.2)
        XCTAssertEqual(bead.thinnestRadiusMM, 0.21, accuracy: 1e-9)      // 0.42 / 2
        XCTAssertEqual(bead.bakeVoxelMM, 0.105, accuracy: 1e-9)          // ≤ r_min / 2
        s.organicStrutWidthMM = 1.0
        let thick = OrganicSampleCube.Picks(settings: s, layerHeightMM: 0.2)
        XCTAssertEqual(thick.strutDiameterMM, 1.0)
        XCTAssertEqual(thick.bakeVoxelMM, 0.25, accuracy: 1e-9)
        // a 20 mm corner at the bead voxel stays under the 12 M cap
        let n = Int(OrganicSampleCube.edgeMM / bead.bakeVoxelMM) + 2
        XCTAssertLessThan(n * n * n, 12_000_000)
    }

    func testPicksAreHashableSoTheWizardRetracesOnlyWhenTheyChange() {
        let a = OrganicSampleCube.Picks(settings: organic(), layerHeightMM: 0.2)
        let b = OrganicSampleCube.Picks(settings: organic(), layerHeightMM: 0.2)
        var c = organic(); c.organicScale = 1.01
        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a, OrganicSampleCube.Picks(settings: c, layerHeightMM: 0.2))
    }

    func testShapeFitAndTheBareSurfaceReachThePicks() {
        var s = organic(); s.organicShapeFit = true; s.organicShapeFitOnly = false
        let p = OrganicSampleCube.Picks(settings: s, layerHeightMM: 0.2)
        XCTAssertTrue(p.shapeFit); XCTAssertFalse(p.shapeFitOnly)
        XCTAssertFalse(p.covered, "no shell ⇒ ends that leave the region are NOT anchors (run_job's rule)")
        s.organicShapeFitOnly = true; s.boundary = .covered
        let q = OrganicSampleCube.Picks(settings: s, layerHeightMM: 0.2)
        XCTAssertTrue(q.shapeFitOnly); XCTAssertTrue(q.covered)
        s.organicShapeFit = false
        XCTAssertFalse(OrganicSampleCube.Picks(settings: s, layerHeightMM: 0.2).shapeFitOnly,
                       "only-mode needs shape fit")
        XCTAssertNotEqual(p, q, "a boundary change re-traces the sample")
    }

    // MARK: item 7 — no simulation ⇒ ungraded (the field is always the cube's own)

    func testSimulationOffLocksShapeFitOnlyAndDropsAuto() {
        var s = organic(); s.organicShapeFit = true
        s.setSimulateStresses(false)
        let p = OrganicSampleCube.Picks(settings: s, layerHeightMM: 0.2)
        XCTAssertTrue(p.shapeFitOnly, "no simulation ⇒ shape-only fit (item 3.2)")
        XCTAssertEqual(s.cellSizeMode, .fit, "no simulation ⇒ Auto is gone (item 3.1)")
        XCTAssertEqual(p.separationMinMM, p.separationMaxMM, "Fit ⇒ one separation")
    }

    func testTheLabelNamesNoPullRequest() {
        XCTAssertFalse(OrganicSampleCube.label.contains("PR"))
        XCTAssertTrue(OrganicSampleCube.label.hasPrefix("A 20 mm test cube"))
        XCTAssertNotNil(OrganicSampleCube.modelURL, "the 20 mm cube is bundled")
    }

    // MARK: the certification fields on the settings

    func testTheFittingSetAndThePickRoundTripAndStayOutOfAnUntouchedFile() throws {
        var s = organic()
        let untouched = try JSONEncoder().encode(s)
        XCTAssertFalse(String(decoding: untouched, as: UTF8.self).contains("organicFittingSeparationsMM"),
                       "bar U1: nothing written until certification found something")
        s.organicFittingSeparationsMM = [2, 3, 5]; s.organicPickedSeparationMM = 3
        s.organicApprovedGradesMM = [[3, 6], [2, 4]]; s.organicPickedGradeMM = [3, 6]
        let back = try JSONDecoder().decode(LatticeSettings.self, from: JSONEncoder().encode(s))
        XCTAssertEqual(back.organicFittingSeparationsMM, [2, 3, 5])
        XCTAssertEqual(back.organicPickedSeparationMM, 3)
        XCTAssertEqual(back.organicApprovedGradesMM, [[3, 6], [2, 4]])
        XCTAssertEqual(back.organicPickedGradeMM, [3, 6])
        XCTAssertEqual(LatticeSettings.organicManualSizeLadderMM.first, 2)
    }

    func testThePickIsNeverSentToACoreThatRefusesTheKey() throws {
        guard TopOptKit.gradingSchemaAccepts(key: "organic_shape_fit") else { throw XCTSkip("no organic in core") }
        var s = organic(); s.cellSizeMode = .fit; s.organicPickedSeparationMM = 3
        let lim = TopOptKit.LatticeLimits(rhoMin: 0.1, rhoMax: 0.6, certifiable: true, minCellsPerMember: 1)
        let region = LatticeRegionSpec(role: .include, kind: .face)
        let g = s.runSpec(limits: lim, generatable: true, memberMM: 12, lineWidthMM: 0.42,
                          regions: [region])?.gradingDictionary() ?? [:]
        let accepted = TopOptKit.gradingSchemaAccepts(key: "organic_separation_mm")
        XCTAssertEqual(g["organic_separation_mm"] != nil, accepted,
                       "written exactly when core's schema accepts the key (\(accepted) on this core)")
        XCTAssertEqual(g["cell_mode"] as? String, "fit")
    }
}
