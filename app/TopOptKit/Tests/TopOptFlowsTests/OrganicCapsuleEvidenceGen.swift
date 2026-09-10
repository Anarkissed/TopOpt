import XCTest
import simd
import ImageIO
import TopOptKit
@testable import TopOptFlows
#if canImport(MetalKit)
import Metal
import MetalKit
#endif

/// ★ EVIDENCE, NOT A GATE (2026-09-06): the shipped sample-cube variant drawn as
/// capsule impostors, offscreen on the Mac, so the look can be seen before the
/// simulator is launched. The simulator screenshot is still the verdict.
final class OrganicCapsuleEvidenceGen: XCTestCase {

    #if canImport(MetalKit)
    @MainActor
    func testRenderTheShippedVariantAsCapsules() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal device") }
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let variants = root.appendingPathComponent("Sources/TopOptFlows/OrganicSample/variants")
        let evidence = root.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("evidence/2026-09-02-organic-on-device/sample_shape_fit_2026-09-03")
        let mesh = LatticeWizardSample.cube(edgeMM: 20, at: .zero)
        for (name, file) in [("traced_fit", "9eefe6f45b88780552ddec25.3mf"),
                             ("grown_auto", "b4fa2779cd2ebf538a95b971.3mf")] {
            let data = try Data(contentsOf: variants.appendingPathComponent(file))
            let doc = try XCTUnwrap(OrganicBeamLattice3MF.read(data), "\(file) reads")
            let caps = doc.spans.map { OrganicCapsule($0) }
            let mn = mesh.bounds.min, mx = mesh.bounds.max
            let n = 4, sp = (mx - mn) / Float(n - 1)
            let grid = LatticeVoxelGrid(nx: n, ny: n, nz: n, origin: mn, spacing: sp,
                                        values: [Float](repeating: 3, count: n * n * n))
            let baked = OrganicBakedFields(distance: grid, surface: grid, reachMM: 3,
                                           summary: "evidence", spanCount: caps.count,
                                           lengthMM: doc.totalLengthMM, capsules: caps)
            let scene = LatticeSDFScene(mesh: mesh, field: nil, latticeID: "octet",
                                        stageMode: .aesthetic, algorithm: "organic",
                                        organicBaked: baked)
            guard let renderer = MeshRenderer(device: device, sampleCount: 4) else {
                throw XCTSkip("MeshRenderer init: \(MeshRenderer.lastInitError ?? "?")")
            }
            try XCTSkipUnless(renderer.organicCapsulePipelineDidBuild, "capsule MSL must build")
            renderer.setMesh(mesh)
            renderer.camera.setOrientation(azimuth: 0.7, elevation: 0.4)
            renderer.setBodyAlpha(0)
            renderer.setLatticeScene(scene, token: 1)
            let size = 900
            let px = try XCTUnwrap(renderer.renderOffscreen(size: size), "a frame")
            let path = evidence.appendingPathComponent("v16_mac_capsules_\(name).png").path
            LatticeQuiltFrameProbe.writePNG(px, size: size, to: path)
            let mask = try XCTUnwrap(renderer.latticeMaskDump(size: 512))
            print("── capsules · \(name): \(caps.count) spans · \(mask.covered) of \(mask.total) px lattice · \(path)")
            XCTAssertGreaterThan(mask.covered, 0)
        }
    }
    #endif
}
