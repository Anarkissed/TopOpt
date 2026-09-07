import XCTest
import simd
import TopOptKit
@testable import TopOptFlows

/// ★ HIS WALK, 2026-09-06 evening: the Auto window was the octet window; fit to shape
/// showed no solid outline; every preview waited on core's emission.
final class OrganicPreviewSpeedAndRimTests: XCTestCase {

    // MARK: core's band, through the bridge

    func testCoresBandComesThroughTheBridge() throws {
        guard TopOptKit.latticeAlgorithmIsKnown("organic") else { throw XCTSkip("no organic on this core") }
        let rows = [TopOptKit.OrganicRecommendRegionRow(faceID: 2, depthMM: 12, extentShortMM: 60,
                                                        stressP50: 1.0, stressP99: 3.0)]
        let band = try XCTUnwrap(TopOptKit.organicRecommendBand(
            regions: rows, minExtrudableWidthMM: 0.45, voxelMM: 1.7, lookCellsAcross: 8, steps: 5))
        print("── core's band: \(band.summary) · floors \(band.printabilityFloorMM)/\(band.resolutionFloorMM) · ceilings \(band.memberCeilingMM)/\(band.extentCeilingMM) · \(band.candidates.count) candidates")
        XCTAssertFalse(band.collapsed)
        XCTAssertGreaterThanOrEqual(band.loMM, 1.7 - 1e-9, "the resolution floor binds on a 1.7 mm voxel")
        XCTAssertLessThanOrEqual(band.hiMM, 12.0 + 1e-9, "never wider than the wall")
        XCTAssertGreaterThan(band.candidates.count, 0)
        XCTAssertEqual(band.printabilityFloorMM, 0.5 * 0.45 * (3 * Double.pi).squareRoot(), accuracy: 1e-6)
        // a wall too thin for any cell collapses, and the window is nil
        let thin = try XCTUnwrap(TopOptKit.organicRecommendBand(
            regions: [.init(faceID: 3, depthMM: 1.0, extentShortMM: 60, stressP50: 1, stressP99: 3)],
            minExtrudableWidthMM: 0.45, voxelMM: 1.7, lookCellsAcross: 8, steps: 5))
        XCTAssertTrue(thin.collapsed)
        XCTAssertNil(OrganicAutoWindow.window(from: thin, structural: false))
    }

    func testTheRunsPickAmongTheCandidates() {
        let cands: [TopOptKit.OrganicRecommendBandResult.Candidate] = [
            .init(loMM: 2, hiMM: 2, source: "grid"), .init(loMM: 2, hiMM: 4, source: "pair"),
            .init(loMM: 3, hiMM: 3, source: "look"), .init(loMM: 2.5, hiMM: 3.5, source: "look_pair"),
        ]
        let band = TopOptKit.OrganicRecommendBandResult(
            loMM: 2, hiMM: 6, printabilityFloorMM: 0.7, resolutionFloorMM: 1.7, memberCeilingMM: 6,
            extentCeilingMM: 15, collapsed: false, lookCellMM: 3, gradeRatio: 1.4, candidates: cands)
        let a = OrganicAutoWindow.window(from: band, structural: false)
        XCTAssertEqual(a?.lo, 2.5); XCTAssertEqual(a?.hi, 3.5)
        let s = OrganicAutoWindow.window(from: band, structural: true)
        XCTAssertEqual(s?.lo, 2); XCTAssertEqual(s?.hi, 6)
    }

    // MARK: the rows the run builds

    private func wall(depth: Double, faceID: Int) -> LatticeRegionSpec {
        var s = LatticeRegionSpec(role: .include, kind: .face)
        s.origin = SIMD3<Double>(10, 0, 10)
        s.normal = SIMD3<Double>(0, 1, 0)
        s.halfUMM = 10; s.halfWMM = 10; s.depthMM = depth
        s.outlineLoops = [[SIMD2(-10, -10), SIMD2(10, -10), SIMD2(10, 10), SIMD2(-10, 10)]]
        s.faceID = faceID
        return s
    }

    private func input(n: Int, spacing: Double, sxx: Double, rim: Double = 0, repairs: Bool = false) -> LatticeOrganicInput {
        var tensor = [Double](repeating: 0, count: 6 * n * n * n)
        for i in 0..<(n * n * n) { tensor[6 * i] = sxx; tensor[6 * i + 1] = 0.3 * sxx; tensor[6 * i + 2] = 0.1 * sxx }
        var o = LatticeOrganicInput(tensor: tensor, dims: (n, n, n), originMM: SIMD3(1.25, 1.25, 1.25),
                                    spacingMM: spacing, minExtrudableWidthMM: 0.45,
                                    buildDirection: SIMD3(0, 0, 1),
                                    separationMinMM: 3, separationMaxMM: 3, rhoMin: 0.05, rhoMax: 0.9,
                                    showRepairs: repairs)
        o.solidRimMM = rim
        return o
    }

    func testTheRowsCarryDepthExtentAndTheStressPercentiles() {
        let w = wall(depth: 8, faceID: 2)
        let rows = OrganicAutoWindow.rows(regions: [w], input: input(n: 8, spacing: 2.5, sxx: 10))
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].faceID, 2)
        XCTAssertEqual(rows[0].depthMM, 8)
        XCTAssertEqual(rows[0].extentShortMM, 20)
        // uniaxial 10 / 3 / 1 MPa ⇒ von Mises √(½((7)²+(2)²+(9)²)) = √67
        XCTAssertEqual(rows[0].stressP50, (67.0).squareRoot(), accuracy: 1e-9)
        XCTAssertEqual(rows[0].stressP99, (67.0).squareRoot(), accuracy: 1e-9)
        XCTAssertEqual(OrganicAutoWindow.shortestExtentMM(w), 20)
    }

    // MARK: the solid rim, in-plane

    func testTheRimErodesTheRegionInPlaneButNotInDepth() throws {
        guard TopOptKit.latticeAlgorithmIsKnown("organic") else { throw XCTSkip("no organic on this core") }
        let mesh = LatticeWizardSample.cube(edgeMM: 20, at: .zero)
        let w = wall(depth: 8, faceID: 2)
        let plain = LatticeSDFScene(mesh: mesh, field: nil, latticeID: "octet", stageMode: .aesthetic,
                                    algorithm: "organic", organic: input(n: 8, spacing: 2.5, sxx: 10),
                                    regions: [w], whenEmpty: .latticeNothing)
        let rimmed = LatticeSDFScene(mesh: mesh, field: nil, latticeID: "octet", stageMode: .aesthetic,
                                     algorithm: "organic", organic: input(n: 8, spacing: 2.5, sxx: 10, rim: 3),
                                     regions: [w], whenEmpty: .latticeNothing)
        func occupied(_ s: LatticeSDFScene) -> Int { s.occupancy.values.filter { $0 > 0.5 }.count }
        XCTAssertGreaterThan(occupied(plain), 0)
        XCTAssertLessThan(occupied(rimmed), occupied(plain), "★ the rim removes the outline band from the lattice")
        // the region field: 1 mm inside the outline's edge is OUT with the rim, IN without
        func region(_ s: LatticeSDFScene, at p: SIMD3<Float>) -> Float {
            let g = s.regionSDF!
            let q = (p - g.origin) / g.spacing
            let i = Int(q.x.rounded()), j = Int(q.y.rounded()), k = Int(q.z.rounded())
            return g.values[(k * g.ny + j) * g.nx + i]
        }
        let nearEdge = SIMD3<Float>(1.0, 4.0, 10.0)      // 1 mm from the x = 0 outline edge, 4 mm deep
        let centre = SIMD3<Float>(10.0, 4.0, 10.0)
        XCTAssertLessThan(region(plain, at: nearEdge), 0, "inside without a rim")
        XCTAssertGreaterThan(region(rimmed, at: nearEdge), 0, "★ the outline band is solid with the rim")
        XCTAssertLessThan(region(rimmed, at: centre), 0, "the middle is still lattice")
        // depth is untouched: a point 7 mm deep on the centre line is in either way
        let deep = SIMD3<Float>(10.0, 7.0, 10.0)
        XCTAssertLessThan(region(rimmed, at: deep), 0, "★ never along the normal")
        XCTAssertLessThan(region(plain, at: deep), 0)
    }

    // MARK: the call sites

    func testTheBakeIsTwoStagesAndAsksCoreForTheWindow() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources")
        let ws = try String(contentsOf: root.appendingPathComponent("TopOptFlows/WorkspacePlaceholder.swift"), encoding: .utf8)
        XCTAssertTrue(ws.contains("let stages: [Bool] = (organicIn?.showRepairs == true) ? [false, true]"),
                      "★ the traced picture first, the repaired one after")
        XCTAssertTrue(ws.contains("guard bakeGeneration == strutBakeGeneration else { return }"),
                      "★ a newer bake retires an older stage")
        XCTAssertTrue(ws.contains("OrganicAutoWindow.band(regions: regions, input: o,"), "★ core's band under Auto")
        XCTAssertTrue(ws.contains("o.solidRimMM = organicRimSetting < 0 ? Swift.min(o.separationMinMM, o.separationMaxMM) : organicRimSetting"),
                      "★ the job's rim number: −1 ⇒ the window's low end")
        let wz = try String(contentsOf: root.appendingPathComponent("TopOptFlows/LatticeSetupWizard.swift"), encoding: .utf8)
        XCTAssertTrue(wz.contains("quick.showRepairs = false"), "★ the sample cube traces first too")
        let br = try String(contentsOf: root.appendingPathComponent("TopOptBridge/bridge.cpp"), encoding: .utf8)
        XCTAssertTrue(br.contains("if (emit_repairs != 0) {"), "★ the bridge skips the emission when repairs are hidden")
    }
}
