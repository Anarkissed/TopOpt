import XCTest
import simd
import TopOptKit
@testable import TopOptFlows

/// ★★ K1 — THE BASE ON THE WIRE (the reviewer, 2026-10-09 20:51, blocking): "Write the slot size
/// each region's ladder was built on, for both menus, on every planned region." Core (#358 664f222c)
/// requires `geometry.plan_base_cell_mm` on every region its plan places a cell in, and refuses a
/// plan without it by name (run_job.cpp:7053): the base cannot be inferred, because a region need
/// not hold a base-size cell. On 3418E167 region 1 the app's base is 14 and its cells 14/3 and 14/4;
/// read as "the largest cell sent" it was 4.6667, and core's menu was built on a ladder the app never
/// used.
final class LatticePlanBaseTests: XCTestCase {

    /// A 40 mm block at 1 mm voxels; A = its −y face (normal +y), B = its −x face (normal +x).
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

    /// Core's two menus on a base (stepped_plan.cpp): Default Grade's halves, base/2^a; any-step's
    /// k·base/n for n ≤ 6. A size is on the menu when it is one of them within 1e-6 of the base.
    private static func onMenu(_ size: Double, base: Double, halves: Bool) -> Bool {
        if halves {
            return (0...8).contains { abs(size - base / pow(2, Double($0))) <= 1e-6 * base }
        }
        if abs(size - base) <= 1e-6 * base { return true }
        return (2...6).contains { n in (1..<n).contains { k in abs(size - Double(k) * base / Double(n)) <= 1e-6 * base } }
    }

    private func bake(cellMM: [Double], halves: Bool) throws -> [LatticeSteppedCell] {
        let s = block()
        var st = LatticePreviewOccupancy.OctreeBakeStats()
        let f = try XCTUnwrap(LatticePreviewOccupancy.octreeCellField(
            occupancy: s.occ, demand: s.demand, regions: s.regions, cellMM: cellMM, lineWidthMM: 0.45,
            realFloorMM: 1.5, shapeFitBandMM: 0, shapeFit: false, densityLo: 0.1, densityHi: 0.3,
            densityGamma: 1, latticeID: "octet", dyadicSteps: halves, stats: &st), "no bake")
        XCTAssertFalse(f.steppedCells.isEmpty)
        return f.steppedCells
    }

    /// ★ Every baked cell states its ladder's base — the region's own cell, one per region — and
    /// every cell's size is on that base's menu, for BOTH menus. And the base is not what core used
    /// to infer (the largest cell sent) wherever the two differ.
    func testEveryBakedCellCarriesItsLaddersBaseForBothMenus() throws {
        for (halves, cellMM) in [(true, [12.0, 10.0]), (false, [12.0, 9.0])] {
            let cells = try bake(cellMM: cellMM, halves: halves)
            var bases: [Int: Set<Double>] = [:]
            var offMenu = 0, sizes: [Int: Set<Double>] = [:]
            for c in cells {
                let b = try XCTUnwrap(c.planBaseCellMM, "★ a baked cell states its base")
                bases[c.region, default: []].insert(b)
                sizes[c.region, default: []].insert(c.sizeMM)
                if !Self.onMenu(c.sizeMM, base: b, halves: halves) { offMenu += 1 }
            }
            XCTAssertEqual(Set(bases.keys), [0, 1], "both faces planned (\(halves ? "halves" : "any-step"))")
            for (r, b) in bases {
                XCTAssertEqual(b, [cellMM[r]], "★ region \(r): one base, the region's own cell")
            }
            XCTAssertEqual(offMenu, 0, "★ every cell on its base's menu (\(halves ? "halves" : "any-step"))")
            // ★ CONTROL: label each cell with its region's FINEST size instead, and the menu check
            // goes red — it can see a wrong base
            var wrong = 0
            for c in cells where !Self.onMenu(c.sizeMM, base: sizes[c.region]!.min()!, halves: halves) { wrong += 1 }
            XCTAssertGreaterThan(wrong, 0, "control: a wrong base is caught")
            print("PLAN-BASE \(halves ? "halves" : "any-step") cells=\(cells.count) bases=\(bases) "
                  + "sizes=\(sizes.mapValues { $0.sorted(by: >) }) wrongBaseControl=\(wrong)")
        }
    }

    /// ★ The wire carries the base; the one check hands every planned region its base and grid; and
    /// the job stamps it on exactly the planned include faces.
    func testTheJobStampsEachPlannedRegionWithItsBase() throws {
        let cells = try bake(cellMM: [12, 10], halves: true)
        let s = block()
        let wire = LatticeSteppedCellWire.wire(cells, regions: s.regions)
        XCTAssertTrue(wire.allSatisfy { $0.planBaseCellMM != nil }, "the wire keeps the base")
        guard case .success(let planned) = LatticeSteppedCellWire.plannedRegions(wire, regions: s.regions) else {
            return XCTFail("an axis-aligned plan with its bases is sent")
        }
        XCTAssertEqual(planned.mapValues(\.baseCellMM), [1: 12, 2: 10])
        XCTAssertTrue(planned.values.allSatisfy { $0.slotOriginMM != nil })

        var spec = LatticeSpec(topologyID: "octet", cellMM: 12, strutRadiusMM: 0.4,
                               generateRelativeDensity: 0.2, minRelativeDensity: 0.1, maxRelativeDensity: 0.9,
                               regions: s.regions)
        spec.algorithm = "doubled"
        spec.steppedCells = wire
        var blk: [String: Any] = ["regions": s.regions.map { $0.wireDictionary }]
        XCTAssertNil(LatticeSteppedCellWire.writePlan(into: &blk, for: spec, wired: true, enabled: true))
        let regs = try XCTUnwrap(blk["regions"] as? [[String: Any]])
        XCTAssertEqual(regs.map { ($0["geometry"] as? [String: Any])?["plan_base_cell_mm"] as? Double }, [12, 10])
        XCTAssertEqual((blk["stepped_cells"] as? [Any])?.count, wire.count)
    }

    /// ★ Each reason a plan cannot carry its base, named — never a guessed base.
    func testAPlanWithoutItsBaseIsWithheldInWords() {
        func cell(_ id: Int, _ b: Double?) -> LatticeSteppedCellWire {
            LatticeSteppedCellWire(regionID: id, originMM: .zero, sizeMM: 3, planBaseCellMM: b)
        }
        func verdict(_ cells: [LatticeSteppedCellWire], wired: Bool = true) -> LatticeSteppedCellWire.PlanWithheld? {
            if case .failure(let w) = LatticeSteppedCellWire.planBases(cells, baseWired: wired) { return w }
            return nil
        }
        XCTAssertNil(verdict([cell(1, 12), cell(1, 12), cell(2, 6)]), "control: stated, one per region")
        XCTAssertEqual(verdict([cell(1, 12), cell(2, nil)]), .baseNotStated(regionID: 2))
        XCTAssertEqual(verdict([cell(1, 12), cell(1, 6)]), .twoBases(regionID: 1))
        XCTAssertEqual(verdict([cell(1, 0)]), .baseNotStated(regionID: 1), "a zero base is not a base")
        XCTAssertEqual(verdict([cell(1, 12)], wired: false), .planBaseNotWired)
        for w in [LatticeSteppedCellWire.PlanWithheld.baseNotStated(regionID: 2), .twoBases(regionID: 1), .planBaseNotWired] {
            XCTAssertFalse(w.reason.isEmpty)
        }
        XCTAssertTrue(LatticeSteppedCellWire.PlanWithheld.twoBases(regionID: 4).reason.contains("region 4"))
    }

    /// ★ The probe, against core's own parser, with its control: the linked core (#358 664f222c+)
    /// takes the key, and refuses a base that is not a length — so the probe is not vacuous.
    func testTheLinkedCoreTakesTheKey() {
        XCTAssertTrue(TopOptKit.regionPlanBaseWired, "★ K1 is on the linked core")
        XCTAssertNil(TopOptKit.jobSchemaError(TopOptKit.regionSlotOriginProbeJob(#", "plan_base_cell_mm": 14.0"#)))
        let bad = TopOptKit.jobSchemaError(TopOptKit.regionSlotOriginProbeJob(#", "plan_base_cell_mm": -1.0"#))
        XCTAssertNotNil(bad, "control: core refuses a negative base")
        XCTAssertTrue(bad?.contains("plan_base_cell_mm") ?? false, bad ?? "")
    }
}
