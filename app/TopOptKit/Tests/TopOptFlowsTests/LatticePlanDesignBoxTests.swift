import XCTest
import simd
@testable import TopOptKit
@testable import TopOptFlows

/// ★ RELEASE (2): THE APP'S PLAN WITH A DESIGN BOX (#362 11-04, reviewer 21:40Z: "your stepped_cells design-box test").
/// TO-core's 4e7648d8 lifted the graded + design-box refusal (the law plans around the added material, and every level and
/// pass lays only cells covering a certified voxel) and said the app's plan path (`lattice.stepped_cells`) had no test with
/// a box. What the app owns of that path, pinned here:
///   1. production sends NO plan, box or not (ruling 4, 2026-10-02: Default Grade plans stay off until every project's plan
///      is accepted and the run's histogram equals the preview's) — so no design-box run carries one today;
///   2. a graded Default Grade or Stepped run with a box is not refused by the app (only the organic lattice is, as core);
///   3. with the plan switch on (the proof's seam), a plan job WITH a design box is a document the linked core parses: the
///      plan's bases and grids stamped on its regions, `stepped_cells`, `grading` and `design_box` together.
/// Not here: a run that lays the plan over a box's added material — core's own G-tests carry that for its passes
/// (test_designbox_graded_lattice); a plan G-test belongs with the day plans ship.
final class LatticePlanDesignBoxTests: XCTestCase {

    /// A 40 mm block at 1 mm voxels; its −y face and its −x face, include (LatticePlanBaseTests' block).
    private func block() -> (occ: LatticeVoxelGrid, demand: LatticeVoxelGrid, regions: [LatticeRegionSpec]) {
        let n = 44, origin = SIMD3<Float>(-2, -2, -2)
        var vals = [Float](repeating: 0, count: n * n * n)
        for k in 0..<n { for j in 0..<n { for i in 0..<n {
            let p = SIMD3<Float>(Float(i), Float(j), Float(k)) + origin + 0.5
            if p.x > 0, p.x < 40, p.y > 0, p.y < 40, p.z > 0, p.z < 40 { vals[(k * n + j) * n + i] = 1 }
        }}}
        func face(origin o: SIMD3<Double>, normal: SIMD3<Double>) -> LatticeRegionSpec {
            var r = LatticeRegionSpec(role: .include, kind: .face)
            r.origin = o; r.normal = normal
            r.halfUMM = 19; r.halfWMM = 19; r.depthMM = 12
            let h = 18.0
            r.outlineLoops = [[SIMD2(-h, -h), SIMD2(h, -h), SIMD2(h, h), SIMD2(-h, h)]]
            return r
        }
        let spacing = SIMD3<Float>(repeating: 1)
        return (LatticeVoxelGrid(nx: n, ny: n, nz: n, origin: origin, spacing: spacing, values: vals),
                LatticeVoxelGrid(nx: n, ny: n, nz: n, origin: origin, spacing: spacing,
                                 values: [Float](repeating: 0.3, count: vals.count)),
                [face(origin: SIMD3(20, 0, 20), normal: SIMD3(0, 1, 0)),
                 face(origin: SIMD3(0, 20, 20), normal: SIMD3(1, 0, 0))])
    }

    /// 1 + 2: no plan in production, and no grading refusal for a Default Grade or Stepped run with a box.
    func testProductionSendsNoPlanAndABoxDoesNotRefuseTheGrade() {
        for algorithm in ["doubled", "stepped"] {
            XCTAssertFalse(LatticeSteppedCellWire.sendsPlan(algorithm: algorithm, wired: true),
                           "★ \(algorithm): production sends no plan (ruling 4), box or not")
            XCTAssertNil(LatticeCoreCapability.liveConflict(latticeEnabled: true, designBoxActive: true,
                                                            graded: true, organic: false),
                         "★ \(algorithm): a graded lattice runs with a design box since 4e7648d8")
        }
        XCTAssertNotNil(LatticeCoreCapability.liveConflict(latticeEnabled: true, designBoxActive: true,
                                                           graded: true, organic: true), "control: the organic one is refused")
    }

    /// 3: the plan job with a design box, as the linked core's parser reads it.
    func testAPlanJobWithADesignBoxIsOneTheLinkedCoreParses() throws {
        let s = block()
        var st = LatticePreviewOccupancy.OctreeBakeStats()
        let f = try XCTUnwrap(LatticePreviewOccupancy.octreeCellField(
            occupancy: s.occ, demand: s.demand, regions: s.regions, cellMM: [12, 10], lineWidthMM: 0.45,
            realFloorMM: 1.5, shapeFitBandMM: 0, shapeFit: false, densityLo: 0.1, densityHi: 0.3,
            densityGamma: 1, latticeID: "octet", dyadicSteps: true, stats: &st), "no bake")
        let wire = LatticeSteppedCellWire.wire(f.steppedCells, regions: s.regions)
        XCTAssertFalse(wire.isEmpty, "premise: the preview planned cells")
        var spec = LatticeSpec(topologyID: "octet", cellMM: 12, strutRadiusMM: 0,
                               generateRelativeDensity: 0, minRelativeDensity: 0.1, maxRelativeDensity: 0.3,
                               regionScoped: true, minExtrudableWidthMM: 0.45, graded: true, regions: s.regions)
        spec.algorithm = "doubled"
        spec.steppedCells = wire
        var lattice: [String: Any] = ["topology": "octet", "regions": s.regions.map { $0.wireDictionary }]
        XCTAssertNil(LatticeSteppedCellWire.writePlan(into: &lattice, for: spec, wired: true, enabled: true),
                     "★ the plan is written (the proof's seam) on a design-box job too")
        XCTAssertNotNil(lattice["stepped_cells"])
        let grading = try XCTUnwrap(spec.gradingDictionary(), "a graded spec writes its grading block")
        func job(designBox: Bool) throws -> Data {
            var root = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(TopOptKit.latticeProbeBaseJob.utf8)) as? [String: Any])
            root["grading"] = grading
            root["lattice"] = lattice
            if designBox { root["design_box"] = ["min": [-2.0, -2.0, -2.0], "max": [42.0, 42.0, 54.0]] }
            return try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
        }
        XCTAssertNil(TopOptKit.jobSchemaError(try job(designBox: false)), "control: the plan job without a box parses")
        XCTAssertNil(TopOptKit.jobSchemaError(try job(designBox: true)),
                     "★ the same plan job with a design box parses: grading, stepped_cells and design_box together")
    }
}
