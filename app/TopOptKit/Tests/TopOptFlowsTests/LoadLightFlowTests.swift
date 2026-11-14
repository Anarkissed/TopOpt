import XCTest
import simd
@testable import TopOptFlows

/// ★ His iPad 2026-10-28: the load path as light travelling INSIDE the part — it starts on the load, never in the air, and
/// it follows the material, never jumping a gap.
final class LoadLightFlowTests: XCTestCase {
    /// An L of printed voxels on a 10×10×1 grid (1 mm): a bar along x at y = 0, then up along y at x = 9. The rest is air.
    static func lField() -> StressField {
        var v = [Float](repeating: 0, count: 100)
        for x in 0..<10 { v[x] = 5 }              // the bottom bar
        for y in 0..<10 { v[y * 10 + 9] = 5 }     // the upright
        return StressField(nx: 10, ny: 10, nz: 1, origin: .zero, spacing: 1, values: v)
    }

    func testTheLightStartsOnTheLoadAndFollowsTheMaterial() throws {
        let f = Self.lField()
        // surface "vertices": one at each printed voxel's centre, plus one in the air across the gap from the bar's start
        var pts: [SIMD3<Float>] = (0..<10).map { SIMD3(Float($0) + 0.5, 0.5, 0.5) } + (1..<10).map { SIMD3(9.5, Float($0) + 0.5, 0.5) }
        pts.append(SIMD3(0.5, 9.5, 0.5))          // far corner: air, nothing printed near it
        let lf = try XCTUnwrap(LoadLightFlow.build(positions: pts.flatMap { [$0.x, $0.y, $0.z] }, field: f,
                                                   seeds: [SIMD3(-3, 0.5, 0.5)]))   // a load point just OFF the bar's end, in the air
        XCTAssertEqual(lf.arrival[0], 0, accuracy: 1e-6, "★ the light starts at the printed voxel nearest the load")
        let along = Array(lf.arrival[0..<19])
        XCTAssertEqual(along, along.sorted(), "★ it travels along the bar, round the corner and up — in order")
        XCTAssertEqual(lf.arrival[18], 1, accuracy: 1e-6, "the far end is reached last")
        XCTAssertEqual(lf.arrival[19], -1, "★ a spot with no material path is never lit (no jumping the gap)")
    }

    func testOnlyThePassingBandIsLit() throws {
        let f = Self.lField()
        let pts: [SIMD3<Float>] = (0..<10).map { SIMD3(Float($0) + 0.5, 0.5, 0.5) }
        let lf = try XCTUnwrap(LoadLightFlow.build(positions: pts.flatMap { [$0.x, $0.y, $0.z] }, field: f, seeds: [SIMD3(0.5, 0.5, 0.5)]))
        let tints = lf.tints(phase: 0.5)
        let lit = tints.enumerated().filter { $0.element.x > LoadLightFlow.body.x + 0.05 }.map(\.offset)
        XCTAssertFalse(lit.isEmpty, "the band lights something")
        for i in lit { XCTAssertLessThan(lf.arrival[i], 0.5 + LoadLightFlow.headWidth, "nothing ahead of the head is lit") }
        XCTAssertTrue(lf.tints(phase: LoadLightFlow.sweepEnd).allSatisfy { $0.x <= LoadLightFlow.body.x + 0.05 },
                      "between sweeps the part rests dark")
    }
}
