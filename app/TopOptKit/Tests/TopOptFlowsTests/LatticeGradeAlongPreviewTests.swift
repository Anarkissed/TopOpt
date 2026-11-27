import XCTest
@testable import TopOptFlows

/// ★ THE CELLS PAGE'S ALONG, DRAWN (ruling 2026-10-24 17:46: "Where the preview can draw that grade, draw it").
/// "Through the depth": the drawn density runs from the band's top at the face plane to its floor at the prism's far end.
/// "Across the face": from the top at the outline to the floor at the face's middle, in-plane. Neither moves the plan's
/// per-cell ρ (what `stepped_cells` sends) — the job does not change because of Along (LatticeStageTests pins it).
final class LatticeGradeAlongPreviewTests: XCTestCase {
    // the grade-strength fixture: a 30 mm slab under a +y face, 12 mm deep, a flat 0.1 demand
    private let origin = SIMD3<Float>(0.37, 0.63, 0.11)
    private let nx = 34, ny = 20, nz = 34
    private var faceY: Double { Double(origin.y) + 1.8 }

    private func bake(_ along: LatticeGradeAlong?) throws -> LatticeCellField {
        var vals = [Float](repeating: 0, count: nx * ny * nz)
        for k in 2..<(nz - 2) { for j in 0..<ny {
            let y = Double(origin.y) + Double(j)
            guard y >= faceY - 0.5, y <= faceY + 12.5 else { continue }
            for i in 2..<(nx - 2) { vals[(k * ny + j) * nx + i] = 1 }
        }}
        let occ = LatticeVoxelGrid(nx: nx, ny: ny, nz: nz, origin: origin, spacing: SIMD3(repeating: 1), values: vals)
        let demand = LatticeVoxelGrid(nx: nx, ny: ny, nz: nz, origin: origin, spacing: SIMD3(repeating: 1),
                                      values: [Float](repeating: 0.1, count: vals.count))
        var spec = LatticeRegionSpec(role: .include, kind: .face)
        spec.origin = SIMD3<Double>(Double(origin.x) + 17, faceY, Double(origin.z) + 17)
        spec.normal = SIMD3(0, 1, 0); spec.halfUMM = 40; spec.halfWMM = 40; spec.depthMM = 12
        let h = 14.5
        spec.outlineLoops = [[SIMD2(-h, -h), SIMD2(h, -h), SIMD2(h, h), SIMD2(-h, h)]]
        var st = LatticePreviewOccupancy.OctreeBakeStats()
        return try XCTUnwrap(LatticePreviewOccupancy.octreeCellField(
            occupancy: occ, demand: demand, regions: [spec], cellMM: [3], lineWidthMM: 0,
            realFloorMM: 1.0, shapeFitBandMM: 0, shapeFit: false,
            densityLo: 0.1, densityHi: 0.5, densityGamma: 1, latticeID: "octet",
            gradeAlong: along, stats: &st))
    }

    /// Mean drawn activation of the painted texels whose middle satisfies `pick`.
    private func mean(_ f: LatticeCellField, _ pick: (SIMD3<Double>) -> Bool) -> Double {
        let g = f.field
        var sum = 0.0, n = 0
        for k in 0..<g.nz { for j in 0..<g.ny { for i in 0..<g.nx {
            let v = g.values[(k * g.ny + j) * g.nx + i]
            guard v >= 0 else { continue }
            let p = SIMD3<Double>(g.origin) + (SIMD3<Double>(Double(i), Double(j), Double(k)) + 0.5) * SIMD3<Double>(g.spacing)
            guard pick(p) else { continue }
            sum += Double(v); n += 1
        }}}
        XCTAssertGreaterThan(n, 0, "the pick holds painted texels")
        return sum / Double(Swift.max(n, 1))
    }

    func testThroughTheDepthIsDenseAtTheFaceAndLightAtTheFarEnd() throws {
        let flat = try bake(nil), depth = try bake(.depth)
        let nearFace: (SIMD3<Double>) -> Bool = { $0.y - self.faceY < 4 }
        let farEnd: (SIMD3<Double>) -> Bool = { $0.y - self.faceY > 8 }
        let flatStep = mean(flat, nearFace) - mean(flat, farEnd), depthStep = mean(depth, nearFace) - mean(depth, farEnd)
        print("ALONG depth: face−far drawn activation, none \(flatStep) · Through the depth \(depthStep)")
        XCTAssertGreaterThan(depthStep, flatStep + 0.2, "Through the depth: denser at the face, lighter at the far end")
        XCTAssertEqual(flat.steppedCells.map(\.rho), depth.steppedCells.map(\.rho), "the plan's ρ (the job) does not move")
    }

    func testAcrossTheFaceIsDenseAtTheOutlineAndLightAtTheMiddle() throws {
        let flat = try bake(nil), face = try bake(.face)
        let cx = Double(origin.x) + 17, cz = Double(origin.z) + 17
        func inPlane(_ p: SIMD3<Double>) -> Double { Swift.max(abs(p.x - cx), abs(p.z - cz)) }
        let atOutline: (SIMD3<Double>) -> Bool = { inPlane($0) > 11 }
        let atMiddle: (SIMD3<Double>) -> Bool = { inPlane($0) < 4 }
        let flatStep = mean(flat, atOutline) - mean(flat, atMiddle), faceStep = mean(face, atOutline) - mean(face, atMiddle)
        print("ALONG face: outline−middle drawn activation, none \(flatStep) · Across the face \(faceStep)")
        XCTAssertGreaterThan(faceStep, flatStep + 0.2, "Across the face: denser at the outline, lighter at the middle")
        XCTAssertEqual(flat.steppedCells.map(\.rho), face.steppedCells.map(\.rho), "the plan's ρ (the job) does not move")
        // and "By stress" is today's bake exactly
        XCTAssertEqual(try bake(.load).field.values, flat.field.values)
    }
}
