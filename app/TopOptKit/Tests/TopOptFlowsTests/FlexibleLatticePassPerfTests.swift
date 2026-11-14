// FlexibleLatticePassPerfTests — T16, the frame budget of the Flexible lattice drawn in
// MeshRenderer's passes (task 2026-09-29-flexible-screens, in-pass round).
//
// ★ RELEASE ONLY. A Debug build's timing is not the app's; the test skips on DEBUG and says
// which configuration and GPU it declined to measure. Run:
//     swift test -c release -Xswiftc -enable-testing --filter FlexibleLatticePassPerfTests
// ★ THE WHOLE FRAME, not the march alone: `measureFrameGPUSeconds(size: 1152, stage: true)`
// is the shipping frame (backdrop, MSAA, prepass, AO, shade, the re-issued ghost) at the
// G-buffer cap, beside the octet cube's frame from the same process. 1 warm-up + 9 frames,
// median/min/max printed. Bar: gyroid squished (s = 1) median ≤ 16 ms; hang guard 250 ms.
// ★ RED CONTROL: the same frame with the pass hidden must be > 20 % cheaper — the timer
// sees the march, or the bar measures nothing. A pass with NOTHING latticed must cost
// about what the hidden one does (the empty region box exits the march at once).
#if canImport(Metal) && canImport(MetalKit)
import XCTest
import Metal
import simd
import TopOptDesign
@testable import TopOptFlows

@MainActor
final class FlexibleLatticePassPerfTests: XCTestCase {

    typealias Fx = FlexibleLatticeFixtures

    struct Stats: CustomStringConvertible {
        let ms: [Double]
        var median: Double { ms[ms.count / 2] }
        var description: String {
            String(format: "median %.2f ms (min %.2f, max %.2f; n %d)", median, ms.first ?? 0, ms.last ?? 0, ms.count)
        }
    }

    func measure(_ r: MeshRenderer, frames: Int = 9) throws -> Stats {
        _ = r.measureFrameGPUSeconds(size: 1152, stage: true)   // warm-up
        var ms: [Double] = []
        for _ in 0..<frames {
            if let t = r.measureFrameGPUSeconds(size: 1152, stage: true) { ms.append(t * 1000) }
        }
        guard !ms.isEmpty else { throw XCTSkip("GPU timestamps unavailable on \(r.deviceName)") }
        return Stats(ms: ms.sorted())
    }

    func testFrameBudgetAt1152() throws {
        let device = try Fx.device()
        #if DEBUG
        throw XCTSkip("T16 is a RELEASE measurement; this is a DEBUG build on \(device.name) — run swift test -c release -Xswiftc -enable-testing --filter FlexibleLatticePassPerfTests")
        #else
        let box = Fx.boxMesh()
        // the shipping sample count (MSAA 4×), as the screen draws
        let r = try Fx.renderer(device: device, sampleCount: 4, box: box)
        r.setVertexTints(Fx.xrayTints(box, ghost: FlexibleColours.ghost, dent: FlexibleColours.token(DS.Color.warning, 1)))
        r.setBodyAlpha(FlexibleStagePage.xrayBodyAlpha)
        var report: [String] = []
        var gyroidSquished: Stats?
        var token = 0
        for topo in [FlexibleLatticeInputs.Topology.gyroid, .honeycomb] {
            token += 1
            r.applyFlexibleLattice(Fx.layer(Fx.boxInputs(topo), faces: [Fx.topFace(depth: 3)], token: token), device: device)
            for s: Float in [0, 1] {
                r.setFlexScale(s)
                let st = try measure(r)
                report.append("\(topo) s=\(Int(s)) \(st)")
                XCTAssertLessThan(st.median, 250, "\(topo) s=\(s): the frame is pathologically slow (hang guard)")
                if topo == .gyroid && s == 1 { gyroidSquished = st }
            }
        }
        // ★ RED CONTROL: the same gyroid squished frame with the pass hidden
        token += 1
        r.applyFlexibleLattice(Fx.layer(Fx.boxInputs(.gyroid), faces: [Fx.topFace(depth: 3)], token: token), device: device)
        r.setFlexScale(1)
        r.flexibleLattice?.hidden = true
        let hidden = try measure(r)
        report.append("gyroid s=1 HIDDEN \(hidden)")
        // ★ A DRAWABLE PASS WITH NOTHING LATTICED (T8's frame E; the evidence probe's
        // reference): the march must exit on the empty region box at once, not read the
        // inverted box as all of space and march every pixel (proved red by removing it)
        var empty = Fx.boxInputs(.gyroid)
        empty.mask.values = [Float](repeating: 0, count: empty.mask.values.count)
        token += 1
        r.applyFlexibleLattice(Fx.layer(empty, faces: [Fx.topFace(depth: 3)], token: token), device: device)
        XCTAssertTrue(r.flexibleLatticeInFrame)
        let nothing = try measure(r)
        report.append("gyroid s=1 NOTHING LATTICED \(nothing)")
        // the octet cube's frame, same process, same size
        let scene = LatticeBandTestCase.octetScene()
        guard let o = MeshRenderer(device: device) else { throw XCTSkip("octet renderer") }
        o.setMesh(scene.mesh)
        o.setLatticeScene(scene, token: 1)
        o.latticeParams = LatticePreviewConfettiTests.hisParamsAtACellHisPartCanHold(cellMM: 4)
        o.camera.setOrientation(azimuth: 0.65, elevation: 0.6)
        for a: Float in [1, 0] {
            o.setBodyAlpha(a)
            report.append("octet cube bodyAlpha \(Int(a)) \(try measure(o))")
        }
        print("FLEX-PERF 1152 whole frame, Release, \(r.deviceName): " + report.joined(separator: "; "))
        let g = try XCTUnwrap(gyroidSquished)
        XCTAssertLessThanOrEqual(g.median, 16, "the gyroid squished frame must fit 16 ms at the 1152 cap")
        XCTAssertLessThan(hidden.median, 0.8 * g.median, "control: the timer must see the march")
        XCTAssertLessThan(nothing.median, hidden.median + 0.25 * (g.median - hidden.median),
                          "an empty lattice region must cost about what a hidden pass costs")
        #endif
    }
}
#endif
