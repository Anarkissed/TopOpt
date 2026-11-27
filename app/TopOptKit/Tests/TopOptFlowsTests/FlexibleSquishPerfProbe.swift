// FlexibleSquishPerfProbe — what one squish sim costs (task 2026-09-29-flexible-screens, round 5
// batch G, §10). Opt-in, and only meaningful on a RELEASE build (memory: measure cost only on
// Release):
//     FLEX_G_PERF=1 swift test -c release --filter FlexibleSquishPerfProbe
// Prints, per sim: elements, iterations, multigrid levels, whether multigrid carried, setup and
// solve ms, the rest mode, k and gmax — and the distribution over repeats (never a difference of
// wall-clocks across runs). Gates: his pad ≤ 4 s per sim, C1's pad ≤ 3 s. The M2 stand is measured
// and printed.
import XCTest
import simd
@testable import TopOptFlows
@testable import TopOptKit

@MainActor
final class FlexibleSquishPerfProbe: XCTestCase {

    static var on: Bool { ProcessInfo.processInfo.environment["FLEX_G_PERF"] == "1" }

    func measure(_ m: FlexibleStageModel, _ what: String, repeats: Int = 3) async throws -> [Double] {
        guard let r = m.lastFERequest else { XCTFail("\(what): no request"); return [] }
        let ref = await m.squishWorker.sceneRef()
        let scene = try XCTUnwrap(ref)
        var worst: [Double] = []
        for sim in r.sims {
            var wall: [Double] = []
            var last: FlexSquishSolutionInfo?
            for _ in 0..<repeats {
                let t0 = Date()
                let s = try scene.squishSolve(r.request(sim))
                wall.append(Date().timeIntervalSince(t0) * 1000)
                last = s
            }
            let s = try XCTUnwrap(last)
            XCTAssertTrue(s.ok, "\(what) \(sim.id): \(s.failure)")
            let f = FlexibleFEField(solution: s, simID: sim.id, generation: r.generation).calibrated(to: sim.targets)
            print(String(format: "FLEX-G PERF %@ %@: elements %d · iterations %d · levels %d · multigrid %@ · setup %.0f ms · solve %.0f ms · bc %@ (%d free modes) · k %.3f (asked %.3f) · gmax %.4f · wall ms %@",
                         what, sim.id, s.elements, s.iterations, s.mgLevels, "\(s.usedMultigrid)", s.setupMS, s.solveMS, s.bcMode,
                         s.freeModes, f.scale, f.coreRatio, f.gmax, wall.map { String(format: "%.0f", $0) }.joined(separator: " / ")))
            worst.append(wall.max() ?? 0)
        }
        return worst
    }

    func testHisPadAtFastAndFineAndC1sPad() async throws {
        guard Self.on else { throw XCTSkip("FLEX_G_PERF=1 (Release)") }
        for quality in [RunQuality.fast, .fine] {
            let (r, m) = try await FlexibleSquishFixture.his(self, "his \(quality)", solve: false) { m in
                m.project.quality = quality
                m.openScene()
            }
            _ = r
            try await FlexibleHisProject.waitFor(120, "the scene at \(quality)") { m.sceneState == .ready }
            let info = try XCTUnwrap(m.sceneInfo)
            print("FLEX-G PERF his \(quality): scene \(info.nx)×\(info.ny)×\(info.nz) · coarsen ×\(FlexibleFE.coarsen(nx: info.nx, ny: info.ny, nz: info.nz))")
            let w = try await measure(m, "his \(quality)")
            for x in w { XCTAssertLessThanOrEqual(x, 4000, "his pad: ≤ 4 s per sim") }
        }
        let pad = try await FlexibleSquishFixture.pad(self, finish: "covered", solve: false)
        let w = try await measure(pad, "C1 pad")
        for x in w { XCTAssertLessThanOrEqual(x, 3000, "C1's pad: ≤ 3 s per sim") }
    }

    func testTheM2Stand() async throws {
        guard Self.on else { throw XCTSkip("FLEX_G_PERF=1 (Release)") }
        let pm = try FlexibleSquishFixture.stlProject("app/TopOptKit/Tests/TopOptFlowsTests/Fixtures/M2_verticalStand.step")
        let mesh = try XCTUnwrap(pm.viewerMesh)
        // the face with the most area whose normal is +Z: press it; the lowest: rest
        let top = FlexibleReadiness.suggestedFace(mesh: mesh, up: SIMD3(0, 0, 1))?.face ?? 0
        let bottom = FlexibleReadiness.suggestedFace(mesh: mesh, up: SIMD3(0, 0, -1))?.face ?? 0
        let m = try await FlexibleSquishFixture.model(self, pm, "the M2 stand") { m in
            _ = m.press(top, kg: 5)
            m.rest(bottom)
        }
        let info = try XCTUnwrap(m.sceneInfo)
        print("FLEX-G PERF M2 stand: scene \(info.nx)×\(info.ny)×\(info.nz) · coarsen ×\(FlexibleFE.coarsen(nx: info.nx, ny: info.ny, nz: info.nz)) · faces top \(top) bottom \(bottom)")
        _ = try await measure(m, "M2 stand", repeats: 2)
    }
}
