import XCTest
import simd
import TopOptKit
@testable import TopOptFlows

/// ★★ THE JOB'S DENSITY CAP, ONE SOURCE. Two rulings, approved by the maintainer:
/// - 2026-10-09 19:41, item 3: "LatticeAutoPosture's inline w/phi(rho_max), the wizard's sample
///   cell, the sector-density readout all take the job's cap through E1 or the capped derivation.
///   One source."
/// - 2026-10-09 20:51: "THE AESTHETIC CEILING (one source): Call core's ceiling through the guarded
///   bridge instead, and pin that a sent rho never exceeds the cap the job carries."
/// The ceiling itself was already core's (`lattice_aesthetic_density_ceiling`, through the guard).
/// What went over it was the bake's printability floor: the app's own 24-step bisection of the
/// diameter table, 24 ppb above the cap at a 2.25 mm cell.
final class LatticeCapOneSourceTests: XCTestCase {

    private var cap: Double { LatticeSettings.jobDensityCap(topologyID: "octet", allowQuilt: false) }

    /// ★ Core's lightest printable density at the floor cell is AT the cap, never over it; the
    /// app's old bisection was over it (the control: it can see the defect).
    func testCoresFloorAtTheCapNeverExceedsIt() throws {
        XCTAssertGreaterThan(cap, 0.2); XCTAssertLessThan(cap, 0.25)
        guard case .prints(let core)? = TopOptKit.latticeMinDensityForStrut(
            topology: "octet", cellMM: 2.25, minExtrudableWidthMM: 0.45, maxRelativeDensity: cap) else {
            return XCTFail("core answers at the floor cell")
        }
        XCTAssertLessThanOrEqual(core, cap, "★ core's floor is never over the job's cap")
        XCTAssertGreaterThan(core, cap - 1e-6, "2.25 mm IS the floor cell: its floor is the cap")
        let old = try XCTUnwrap(LatticeType.named("octet")).printabilityDensityFloor(lineWidthMM: 0.45, cellMM: 2.25)
        XCTAssertGreaterThan(old, cap, "★ control: the app's old bisection lands over the cap")
        // below the floor cell nothing the job allows prints; uncapped the band top still does
        XCTAssertEqual(TopOptKit.latticeMinDensityForStrut(topology: "octet", cellMM: 2.0, minExtrudableWidthMM: 0.45,
                                                           maxRelativeDensity: cap), .noneUnderTheCap)
        guard case .prints? = TopOptKit.latticeMinDensityForStrut(topology: "octet", cellMM: 2.0,
                                                                  minExtrudableWidthMM: 0.45, maxRelativeDensity: 0) else {
            return XCTFail("uncapped, a 2 mm cell prints (Allow quilt)")
        }
        print(String(format: "CAP-FLOOR cap=%.12f core@2.25=%.12f (cap−core %.3g) old@2.25=%.12f (old−cap %.3g)",
                     cap, core, cap - core, old, old - cap))
    }

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

    /// ★ The bake: cells at the 2.25 mm floor are raised to core's floor — at the cap — and no cell
    /// carries a density over the cap the job writes.
    func testNoBakedCellIsDenserThanTheJobsCap() throws {
        let s = block()
        var st = LatticePreviewOccupancy.OctreeBakeStats()
        // a 9 mm base under a structural intent (no prints-open bound): quarters at 2.25 mm
        let f = try XCTUnwrap(LatticePreviewOccupancy.octreeCellField(
            occupancy: s.occ, demand: s.demand, regions: s.regions, cellMM: [9, 9], lineWidthMM: 0.45,
            realFloorMM: 2.25, shapeFitBandMM: 0, shapeFit: false, densityLo: 0.1, densityHi: 0.3,
            densityGamma: 1, latticeID: "octet", dyadicSteps: false, finestPrintsOpen: false,
            densityCap: cap, stats: &st), "no bake")
        let floorCells = f.steppedCells.filter { abs($0.sizeMM - 2.25) < 1e-9 }
        XCTAssertFalse(floorCells.isEmpty, "positive control: the bake laid cells at the floor")
        let maxRho = f.steppedCells.map(\.rho).max() ?? 0
        XCTAssertLessThanOrEqual(maxRho, cap, "★ no cell over the job's cap")
        XCTAssertGreaterThan(floorCells.map(\.rho).min() ?? 0, cap - 1e-6, "the floor cells ARE raised to it")
        print(String(format: "CAP-BAKE cells=%d floorCells=%d maxRho=%.12f cap=%.12f",
                     f.steppedCells.count, floorCells.count, maxRho, cap))
    }

    /// ★ The writer: a plan with a cell over the cap the job writes is withheld in words, never
    /// trimmed; a cell AT the cap goes (the control).
    func testTheWriterWithholdsACellOverTheCap() throws {
        var face = LatticeRegionSpec(role: .include, kind: .face)
        face.normal = SIMD3(0, 0, 1); face.depthMM = 12; face.halfUMM = 20; face.halfWMM = 20
        var spec = LatticeSpec(topologyID: "octet", cellMM: 12, strutRadiusMM: 0.4,
                               generateRelativeDensity: 0.2, minRelativeDensity: 0.1, maxRelativeDensity: 0.9,
                               regions: [face])
        spec.algorithm = "doubled"
        spec.densityCapRho = cap
        XCTAssertEqual(spec.densityCapWritten, cap, "the job carries the cap on the linked core")
        func plan(_ rho: Double) -> LatticeSteppedCellWire.PlanWithheld? {
            var p = spec
            p.steppedCells = [LatticeSteppedCellWire(regionID: 1, originMM: .zero, sizeMM: 12, rho: 0.15, planBaseCellMM: 12),
                              LatticeSteppedCellWire(regionID: 1, originMM: SIMD3(12, 0, 0), sizeMM: 6, rho: rho,
                                                     planBaseCellMM: 12)]
            var blk: [String: Any] = ["regions": [face.wireDictionary]]
            let why = LatticeSteppedCellWire.writePlan(into: &blk, for: p, wired: true, enabled: true)
            XCTAssertEqual(blk["stepped_cells"] == nil, why != nil, "sent whole or not at all")
            return why
        }
        XCTAssertNil(plan(cap), "control: a cell at the cap goes")
        guard case .rhoOverCap(let id, let rho, let c)? = plan(cap + 2.4e-8) else { return XCTFail("★ withheld") }
        XCTAssertEqual(id, 1); XCTAssertEqual(rho, cap + 2.4e-8); XCTAssertEqual(c, cap)
        XCTAssertTrue(LatticeSteppedCellWire.PlanWithheld.rhoOverCap(regionID: 1, rho: 0.25, cap: cap).reason.contains("region 1"))
        // Allow quilt: the job writes no cap, and a dense cell goes
        var quilt = spec; quilt.densityCapRho = 0
        XCTAssertEqual(quilt.densityCapWritten, 0)
    }

    /// ★ Auto's window at the job's cap: its fine end is core's E1 floor (2.25 mm at a 0.45 mm bead),
    /// not the uncapped 1.173 — the control shows the uncapped end is under the run's floor.
    func testAutosWindowTakesTheJobsCap() throws {
        let capped = try XCTUnwrap(LatticeAutoPosture.autoWindowMM(regionWidthsMM: [], lineWidthMM: 0.45,
                                                                   topology: "octet", maxRelativeDensity: cap))
        XCTAssertEqual(capped.min, 2.25, accuracy: 1e-9, "★ the run's floor")
        let open = try XCTUnwrap(LatticeAutoPosture.autoWindowMM(regionWidthsMM: [], lineWidthMM: 0.45,
                                                                 topology: "octet", maxRelativeDensity: 0))
        XCTAssertEqual(open.min, 1.173173434, accuracy: 1e-9, "control: uncapped (Allow quilt)")
        // a 9 mm member: the capped derivation's cell is never under the floor
        let w = try XCTUnwrap(LatticeAutoPosture.autoWindowMM(regionWidthsMM: [9], lineWidthMM: 0.45,
                                                              topology: "octet", maxRelativeDensity: cap))
        XCTAssertGreaterThanOrEqual(w.min, 2.25 - 1e-9)
    }

    /// ★ The sector readout at the job's cap: a stated density over it is named before the run
    /// (core would print it AT the cap); uncapped the same number is fine (the control).
    func testTheSectorReadoutTakesTheJobsCap() {
        let g = SelectionGroup(id: UUID(), name: "Sector A", colorIndex: 0, faces: [])
        var r = LatticeRegionSpec(role: .include, kind: .face)
        r.depthMM = 12; r.halfUMM = 20; r.halfWMM = 20
        func row(_ stated: Double, cap: Double) -> LatticeSectorDensity.Row {
            LatticeSectorDensity.rows(groups: [g], roles: [g.id: .include], densities: [g.id: stated],
                                      regionsFor: { _ in [r] }, topology: "octet", minExtrudableWidthMM: 0.45,
                                      maxRelativeDensity: cap)[0]
        }
        let over = row(0.25, cap: cap)
        XCTAssertTrue(over.refusal?.contains("Allow quilt") ?? false, over.refusal ?? "nil")
        XCTAssertEqual(over.validRange?.upperBound ?? 0, cap, accuracy: 1e-12, "★ the range ends at the cap")
        XCTAssertNil(row(0.25, cap: 0).refusal, "control: uncapped, 25% is in the band")
        XCTAssertNil(row(0.20, cap: cap).refusal, "under the cap is fine")
    }

    /// The production callers pass the job's cap — the one source — and the bake's floor is core's.
    func testTheCallersPassTheJobsCap() throws {
        var u = URL(fileURLWithPath: #filePath); for _ in 0..<3 { u.deleteLastPathComponent() }
        func src(_ f: String) throws -> String {
            try String(contentsOf: u.appendingPathComponent("Sources/TopOptFlows/" + f), encoding: .utf8)
        }
        // (B8: the wizard's sample cell is deleted with the full-screen page and its sample cube)
        XCTAssertTrue(try src("ProjectModel.swift").contains(
            "maxRelativeDensity: LatticeSettings.jobDensityCap(topologyID: lattice.topologyID,"), "★ the sector readout")
        let posture = try src("LatticeAutoPosture.swift")
        XCTAssertFalse(posture.contains("lineWidthMM / phiMax"), "★ Auto's inline w/phi(rho_max) is gone")
        XCTAssertTrue(posture.contains("TopOptKit.latticeMinPrintableCellMM("))
        XCTAssertTrue(try src("WorkspacePlaceholder.swift").contains("""
                    topology: lat.topologyID,
                    maxRelativeDensity: LatticeSettings.jobDensityCap(
"""), "★ the Auto sweep's floor")
        XCTAssertTrue(try src("LatticeSDFMetal.swift").contains(
            "densityCap: LatticeSettings.jobDensityCap(topologyID: params.latticeID, allowQuilt: scene.allowQuilt)"),
                      "★ the bake gets the job's cap")
        let bake = try src("LatticeOctreeBake.swift")
        XCTAssertTrue(bake.contains("r = Swift.max(r, printFloor(size[i], lat))"), "★ the bake's floor is core's")
        XCTAssertTrue(bake.contains("if densityCap > 0 { r = Swift.min(r, densityCap) }"))
    }
}
