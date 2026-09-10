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
        // ★ WHATEVER THIS BUILD SHIPS, NOT A FILENAME FROM A PAST ONE (2026-09-07).
        // The keys are a hash of the picks, core's fingerprint and the bake layout, so
        // every change to any of those renames all of them — and this generator then
        // failed on a file that no longer exists, which says nothing about capsules.
        // Two of whatever is there, largest first, so the picture is worth looking at.
        let shipped = ((try? FileManager.default.contentsOfDirectory(atPath: variants.path)) ?? [])
            .filter { $0.hasSuffix(".3mf") }
            .sorted {
                let a = (try? FileManager.default.attributesOfItem(
                    atPath: variants.appendingPathComponent($0).path)[.size]) as? Int ?? 0
                let b = (try? FileManager.default.attributesOfItem(
                    atPath: variants.appendingPathComponent($1).path)[.size]) as? Int ?? 0
                return a > b
            }
        try XCTSkipIf(shipped.isEmpty, "this build ships no organic sample variants")
        for (i, file) in shipped.prefix(2).enumerated() {
            let name = "shipped_\(i)"
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
