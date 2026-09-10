import XCTest
import simd
#if canImport(MetalKit)
import MetalKit
#endif
import TopOptKit
@testable import TopOptFlows

/// ★★★ WHAT THE WETTED JOIN LOOKS LIKE (his instruction, 2026-09-08). A picture, not a
/// pass/fail: struts crossing from a declared region into the surrounding solid, drawn
/// through the SAME shader the iPad runs. He judges the picture in the simulator; this
/// exists so there is something to look at when the stage itself is unreachable.
final class OrganicWettedJoinEvidenceGen: XCTestCase {
    #if canImport(MetalKit)
    @MainActor
    func testRenderTheWettedJoin() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal device") }
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let out = root.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("evidence/2026-09-08-wetted-join")
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

        let edge = 20.0
        let mesh = LatticeWizardSample.cube(edgeMM: edge, at: .zero)
        let c = 0.5 * (mesh.bounds.min + mesh.bounds.max)
        // A pocket in the +x wall: 11 mm deep, 24 mm across. The solid is everything
        // outside it, which is what the struts have to wet.
        var wall = LatticeRegionSpec(role: .include, kind: .face)
        wall.origin = SIMD3<Double>(Double(c.x) + 5, Double(c.y), Double(c.z))
        wall.normal = SIMD3<Double>(-1, 0, 0)
        wall.halfUMM = 7; wall.halfWMM = 7; wall.depthMM = 6
        wall.outlineLoops = [[SIMD2(-7, -7), SIMD2(7, -7), SIMD2(7, 7), SIMD2(-7, 7)]]
        wall.faceID = 15
        wall.selectableKey = "f:x:15"

        // Struts inside the pocket, each aimed at the solid at a different angle — the
        // point of the join is that the bead does not care which.
        var caps: [OrganicCapsule] = []
        for k in stride(from: -5.0, through: 5.0, by: 2.5) {
            for (dy, dz) in [(0.0, 0.0), (0.5, 0.0), (0.0, 0.5), (-0.4, 0.4)] {
                let a = SIMD3<Float>(Float(Double(c.x) - 1), Float(Double(c.y) + k), Float(Double(c.z) + k * 0.25))
                let b = a + SIMD3<Float>(8, Float(dy * 8), Float(dz * 8))
                caps.append(OrganicCapsule(a: a, b: b, r: 0.55))
            }
        }
        let n = 4
        let sp = (mesh.bounds.max - mesh.bounds.min) / Float(n - 1)
        let far = LatticeVoxelGrid(nx: n, ny: n, nz: n, origin: mesh.bounds.min,
                                   spacing: sp, values: [Float](repeating: 3, count: n * n * n))
        let baked = OrganicBakedFields(distance: far, surface: far, reachMM: 3,
                                       summary: "wetted join", spanCount: caps.count,
                                       lengthMM: 0, capsules: caps)
        let scene = LatticeSDFScene(mesh: mesh, field: nil, latticeID: "octet",
                                    stageMode: .aesthetic, algorithm: "organic",
                                    organicBaked: baked, regions: [wall],
                                    whenEmpty: .latticeNothing)
        guard let renderer = MeshRenderer(device: device, sampleCount: 4) else {
            throw XCTSkip("MeshRenderer init: \(MeshRenderer.lastInitError ?? "?")")
        }
        try XCTSkipUnless(renderer.organicCapsulePipelineDidBuild, "capsule MSL must build")
        renderer.setMesh(mesh)
        renderer.setLatticeScene(scene, token: 1)
        let size = 1000
        for (name, alpha) in [("wetted_join_body_hidden", Float(0)),
                              ("wetted_join_body_ghosted", Float(0.25))] {
            renderer.camera.setOrientation(azimuth: 0.55, elevation: 0.35)
            renderer.setBodyAlpha(alpha)
            let px = try XCTUnwrap(renderer.renderOffscreen(size: size), "a frame")
            let path = out.appendingPathComponent("\(name).png").path
            LatticeQuiltFrameProbe.writePNG(px, size: size, to: path)
            print("── \(name): \(caps.count) struts into the wall · \(path)")
        }
        // ★ The positive control is taken with the body HIDDEN: at a ghosted alpha the
        // solid occludes the mask pass, so a 0 there says nothing about the struts.
        renderer.setBodyAlpha(0)
        let mask = try XCTUnwrap(renderer.latticeMaskDump(size: 512))
        XCTAssertGreaterThan(mask.covered, 0, "★ the struts must reach pixels")
    }
    #endif
}
