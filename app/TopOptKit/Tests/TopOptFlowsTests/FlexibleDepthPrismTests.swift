// FlexibleDepthPrismTests — "Deepest squish = a prism you drag out" (task
// 2026-09-29-flexible-screens, round 3, item 1.1). On the split pad (only top A pressed):
//   * the footprint is the sector's own columns (area = columns × pitch²) and stays on its side
//     of the cut. RED CONTROL: the whole face's bounding rectangle crosses the cut;
//   * the floor moves along +load (into the part). RED CONTROL: −load leaves the part;
//   * the handle reads the true depth back through the page's MODEL projection. RED CONTROL:
//     the same screen point through an un-settled WORLD projection reads another depth;
//   * clamp and detents: 0.2 → 0.5, past the lattice → the lattice depth, 2.9 → 3.0;
//   * the page passes the prism to MetalMeshView and mounts the chip (call-site pins).
import XCTest
import simd
@testable import TopOptFlows
@testable import TopOptKit

final class FlexibleDepthPrismTests: XCTestCase {

    static func area(_ s: FaceOffsetShell) -> Double {
        var a = 0.0
        for t in stride(from: 0, to: s.indices.count, by: 3) {
            let p = (0..<3).map { SIMD3<Double>(s.base[Int(s.indices[t + $0])]) }
            a += simd_length(simd_cross(p[1] - p[0], p[2] - p[0])) / 2
        }
        return a
    }

    func testTheFootprintIsTheSectorsOwnColumns() throws {
        let a = try FlexibleOverlayClipTests.padAOnly()
        let t0 = Date()
        let s = try XCTUnwrap(FlexibleDepthPrism.shell(stack: a.stack, centres: a.geometry.centres, depthMM: 3, k: 4))
        let ms = Date().timeIntervalSince(t0) * 1000
        let want = Double(a.stack.columns.count) * a.stack.pitchMM * a.stack.pitchMM
        print(String(format: "FLEX-PRISM top A: %d columns, footprint %.1f mm² (columns × pitch² %.1f), %d corners, %d triangles, built in %.1f ms",
                     a.stack.columns.count, Self.area(s), want, s.base.count, s.indices.count / 3, ms))
        XCTAssertEqual(Self.area(s), want, accuracy: want * 1e-6)
        XCTAssertTrue(s.base.allSatisfy { $0.x >= 50 - 1e-4 }, "the prism stays on top A's side of the cut")
        XCTAssertLessThan(s.base.count, a.stack.columns.count * 2, "corners are shared, not four per column")
        // ★ RED CONTROL: the whole top face's bounding rectangle crosses the cut
        let rect: [SIMD2<Double>] = [SIMD2(0, 0), SIMD2(100, 0), SIMD2(100, 100), SIMD2(0, 100)]
        XCTAssertTrue(rect.contains { $0.x < 50 }, "control: the face's bounding box reaches into top B")
    }

    func testTheFloorMovesIntoThePart() throws {
        let a = try FlexibleOverlayClipTests.padAOnly()
        let s = try XCTUnwrap(FlexibleDepthPrism.shell(stack: a.stack, centres: a.geometry.centres, depthMM: 3, k: 4))
        for i in s.base.indices {
            let d = SIMD3<Double>(s.offset[i] - s.base[i])
            XCTAssertEqual(simd_dot(d, a.stack.load), 12, accuracy: 1e-3, "k · depth along +load")
        }
        XCTAssertEqual(s.reachedDepthMM, 12)
        XCTAssertEqual(a.stack.load.z, -1, accuracy: 1e-9, "premise: the top's load points down, into the part")
        // ★ RED CONTROL: along −load the floor would leave the part (above z = 20)
        let wrong = s.base.map { $0 - SIMD3<Float>(a.stack.load) * 12 }
        XCTAssertTrue(wrong.allSatisfy { $0.z > 20 }, "control: −load goes out of the part")
        XCTAssertTrue(s.offset.allSatisfy { $0.z < 20 }, "the floor is inside")
        // the handle: normal == load, anchor on the floor
        let v = try XCTUnwrap(FlexibleDepthPrism.volume(region: a.region, stack: a.stack, centres: a.geometry.centres, depthMM: 3, k: 4))
        let h = try XCTUnwrap(FlexibleDepthPrism.handle(v))
        XCTAssertEqual(simd_dot(SIMD3<Double>(h.planeNormal), a.stack.load), 1, accuracy: 1e-5)
        XCTAssertEqual(Double(h.anchor.z), 20 - FlexibleDepthPrism.insetMM - 12, accuracy: 1e-3)
    }

    /// ★ The page's projection is MODEL space (it composes the settle); the handle is too.
    func testTheHandleReadsTheTrueDepthThroughTheModelProjection() throws {
        let a = try FlexibleOverlayClipTests.padAOnly()
        let k = 4.0
        let v = try XCTUnwrap(FlexibleDepthPrism.volume(region: a.region, stack: a.stack, centres: a.geometry.centres, depthMM: 2, k: k))
        let h = try XCTUnwrap(FlexibleDepthPrism.handle(v))
        // the page's camera and settle (gravity → down), as FlexibleStagePage builds them
        var cam = OrbitCamera()
        cam.frame(a.part.bounds)
        cam.orbit(dx: 120, dy: 60)
        let viewport = CGSize(width: 1366, height: 1024)
        let world = CameraProjection(camera: cam, viewportSize: viewport)
        let settle = simd_quatf(from: SIMD3<Float>(0, 0, -1), to: SIMD3<Float>(0, -1, 0))
        let m = ViewerModelFrame.matrix(centre: a.part.bounds.center, rotation: settle)
        let model = CameraProjection(viewProjection: world.viewProjection * m, viewportSize: viewport)
        var worst = 0.0, worstWorld = 0.0
        for d in [1.0, 3.0, 5.5] {
            let target = h.planeOrigin + h.planeNormal * Float(k * d)
            let p = try XCTUnwrap(model.project(target))
            let ray = try XCTUnwrap(model.ray(throughViewPoint: p))
            let got = try XCTUnwrap(FlexibleDepthPrism.depth(handle: h, rayOrigin: ray.origin, rayDir: ray.dir, k: k))
            worst = max(worst, abs(got - d))
            // ★ RED CONTROL: the same finger through the WORLD projection (no settle)
            let wr = try XCTUnwrap(world.ray(throughViewPoint: p))
            let wrong = FlexibleDepthPrism.depth(handle: h, rayOrigin: wr.origin, rayDir: wr.dir, k: k) ?? .infinity
            worstWorld = max(worstWorld, abs(wrong - d))
        }
        print(String(format: "FLEX-PRISM handle round trip: worst |read − set| %.5f mm (model projection), %.2f mm (world, control)", worst, worstWorld))
        XCTAssertLessThan(worst, 0.01)
        XCTAssertGreaterThan(worstWorld, 0.5, "control: an un-settled projection must read another depth")
    }

    func testClampAndDetents() {
        let lattice = 18.4
        XCTAssertEqual(FlexibleDepthPrism.resolve(rawMM: 0.2, latticeMM: lattice, held: nil).mm, 0.5)
        XCTAssertEqual(FlexibleDepthPrism.resolve(rawMM: -3, latticeMM: lattice, held: nil).mm, 0.5)
        XCTAssertEqual(FlexibleDepthPrism.resolve(rawMM: 40, latticeMM: lattice, held: nil).mm, lattice, "stops at the lattice depth")
        let snap = FlexibleDepthPrism.resolve(rawMM: 2.9, latticeMM: lattice, held: nil)
        XCTAssertEqual(snap.mm, 3.0)
        XCTAssertTrue(snap.didSnap)
        let atLattice = FlexibleDepthPrism.resolve(rawMM: 18.3, latticeMM: lattice, held: nil)
        XCTAssertEqual(atLattice.mm, lattice)
        XCTAssertEqual(atLattice.held?.kind, .extent)
        XCTAssertFalse(FlexibleDepthPrism.candidates(latticeMM: lattice).contains { $0.kind == .certifies },
                       "Flexible has no certificate")
    }

    /// The chip hides under the panel / legend (unreachable there) and off screen; looking
    /// along the load falls back to a screen scrub.
    func testTheChipKeepsOutAndFallsBackToAScrub() {
        let vp = CGSize(width: 1366, height: 1024)
        let panel = CGRect(x: 24, y: 400, width: 400, height: 600)
        XCTAssertTrue(FlexibleDepthChipLayout.visible(CGPoint(x: 700, y: 500), keepOut: [panel], viewport: vp))
        XCTAssertFalse(FlexibleDepthChipLayout.visible(CGPoint(x: 200, y: 700), keepOut: [panel], viewport: vp), "under the panel")
        XCTAssertFalse(FlexibleDepthChipLayout.visible(CGPoint(x: 440, y: 700), keepOut: [panel], viewport: vp), "half under it")
        XCTAssertFalse(FlexibleDepthChipLayout.visible(CGPoint(x: 5, y: 500), keepOut: [], viewport: vp), "off the edge")
        XCTAssertTrue(FlexibleDepthChipLayout.needsScrub(rayAlongLoad: 0.99, projectedPointsPer10MM: 40), "looking along the load")
        XCTAssertTrue(FlexibleDepthChipLayout.needsScrub(rayAlongLoad: 0.5, projectedPointsPer10MM: 4), "the load barely projects")
        XCTAssertFalse(FlexibleDepthChipLayout.needsScrub(rayAlongLoad: 0.5, projectedPointsPer10MM: 40))
    }

    /// ★ CALL SITES (memory: value-type tests miss call sites).
    func testThePageDrawsThePrismAndMountsTheChip() throws {
        let root = FlexibleHisProject.repoRoot.appendingPathComponent("app/TopOptKit/Sources/TopOptFlows")
        let page = try String(contentsOf: root.appendingPathComponent("FlexibleStagePage.swift"), encoding: .utf8)
        XCTAssertTrue(page.contains("clearanceVolumes: FlexibleDepthPrism.renderItems(model: model"))
        XCTAssertTrue(page.contains("FlexibleDepthChips("))
    }
}
