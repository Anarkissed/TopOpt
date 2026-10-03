// FlexibleFEPassPerfTests — what the squish sim's field costs the frame (task
// 2026-09-29-flexible-screens, round 5 batch G, §10). RELEASE ONLY, like T16
// (FlexibleLatticePassPerfTests), whose harness this reuses:
//     swift test -c release -Xswiftc -enable-testing --filter FlexibleFEPassPerfTests
// The whole shipping frame at the 1152 G-buffer cap, MSAA 4×: the gyroid squished by the COLUMN
// path (T16's case: the top face 3 mm deep, s = 1) beside the same lattice squished by an FE field
// that sinks the top 3 mm (FlexibleFEPassTests.boxField) at s = 1. 1 warm-up + 15 frames each,
// median / min / max printed (memory: print the distribution; never difference wall-clocks across
// runs). Bar: the FE frame's median ≤ the column frame's median + 3 ms.
// ★ RED CONTROL: the same frame with the pass hidden is > 20 % cheaper (the timer sees the march).
#if canImport(Metal) && canImport(MetalKit)
import XCTest
import Metal
import simd
import TopOptDesign
@testable import TopOptFlows

@MainActor
final class FlexibleFEPassPerfTests: XCTestCase {

    typealias Fx = FlexibleLatticeFixtures

    func testFrameCostOnRelease() throws {
        let device = try Fx.device()
        #if DEBUG
        throw XCTSkip("a RELEASE measurement; this is a DEBUG build on \(device.name) — run swift test -c release -Xswiftc -enable-testing --filter FlexibleFEPassPerfTests")
        #else
        let box = Fx.boxMesh()
        let r = try Fx.renderer(device: device, sampleCount: 4, box: box)
        r.setVertexTints(Fx.xrayTints(box, ghost: FlexibleColours.ghost, dent: FlexibleColours.token(DS.Color.warning, 1)))
        r.setBodyAlpha(FlexibleStagePage.xrayBodyAlpha)
        let perf = FlexibleLatticePassPerfTests()
        // the column path (T16)
        r.applyFlexibleLattice(Fx.layer(Fx.boxInputs(.gyroid), faces: [Fx.topFace(depth: 3)], token: 1), device: device)
        r.setFlexScale(1)
        let column = try perf.measure(r, frames: 15)
        // the FE field
        var l = Fx.layer(Fx.boxInputs(.gyroid), faces: [Fx.topFace(depth: 3)], token: 1)
        l.fe = [FlexibleFEPassTests.boxField()]; l.feMesh = [[]]; l.feSequence = [0]; l.feToken = 9
        r.applyFlexibleLattice(l, device: device)
        r.flexibleLattice?.bindFE(0)
        let fe = try perf.measure(r, frames: 15)
        r.flexibleLattice?.hidden = true
        let hidden = try perf.measure(r, frames: 15)
        print("FLEX-G FRAME \(device.name) 1152 px MSAA 4×: column \(column) · FE \(fe) · hidden \(hidden)")
        XCTAssertLessThanOrEqual(fe.median, column.median + 3, "the FE field costs at most 3 ms more than the column squish")
        XCTAssertLessThan(hidden.median, 0.8 * fe.median, "control: the timer sees the march")
        #endif
    }
}
#endif
