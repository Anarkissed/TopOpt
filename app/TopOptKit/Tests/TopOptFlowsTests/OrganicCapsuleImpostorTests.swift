import XCTest
import simd
import TopOptKit
@testable import TopOptFlows
#if canImport(MetalKit)
import Metal
import MetalKit
#endif

/// ★★★ ORGANIC AS CAPSULE IMPOSTORS (maintainer, 2026-09-06: "leave the SDF for the
/// regular lattice section. Once Organic is selected, switch the previews to GPU
/// capsule impostors"). The spans are drawn analytically into the unified G-buffer;
/// the field march leaves organic alone.
final class OrganicCapsuleImpostorTests: XCTestCase {

    private static let edgeMM = 20.0

    /// A cube with pre-baked (empty) organic fields and the given capsules — the
    /// variant-cache path, without a trace.
    private static func scene(capsules: [OrganicCapsule], mesh: ViewerMesh) -> LatticeSDFScene {
        let mn = mesh.bounds.min, mx = mesh.bounds.max
        let n = 4
        let sp = (mx - mn) / Float(n - 1)
        let far = [Float](repeating: 3.0, count: n * n * n)
        let grid = LatticeVoxelGrid(nx: n, ny: n, nz: n, origin: mn, spacing: sp, values: far)
        let baked = OrganicBakedFields(distance: grid, surface: grid, reachMM: 3.0,
                                       summary: "\(capsules.count) struts (test)",
                                       spanCount: capsules.count, lengthMM: 0, capsules: capsules)
        return LatticeSDFScene(mesh: mesh, field: nil, latticeID: "octet",
                               stageMode: .aesthetic, algorithm: "organic",
                               organicBaked: baked)
    }

    func testEveryOrganicSourceHandsTheSceneItsCapsules() {
        let mesh = LatticeWizardSample.cube(edgeMM: Self.edgeMM, at: .zero)
        let c = 0.5 * (mesh.bounds.min + mesh.bounds.max)
        let caps = [OrganicCapsule(a: c - SIMD3(6, 0, 0), b: c + SIMD3(6, 0, 0), r: 1.0),
                    OrganicCapsule(a: c, b: c + SIMD3(0, 5, 0), r: 0.4)]
        let s = Self.scene(capsules: caps, mesh: mesh)
        XCTAssertEqual(s.organicCapsules, caps, "the pre-baked path carries its spans")
        XCTAssertNotNil(s.organicField, "the field is still baked for the probes")
        // the 3MF document path reduces to the same value type
        let doc = OrganicBeamLattice3MF.Document(
            spans: caps.map { (a: SIMD3<Double>($0.a), b: SIMD3<Double>($0.b), r: Double($0.r)) },
            metadata: [:])
        XCTAssertEqual(doc.spans.map { OrganicCapsule($0) }, caps)
        // and a non-organic scene carries none
        let octet = LatticeSDFScene(mesh: mesh, field: nil, latticeID: "octet")
        XCTAssertTrue(octet.organicCapsules.isEmpty)
    }

    #if canImport(MetalKit)
    @MainActor
    private func covered(capsules: [OrganicCapsule], bodyAlpha: Float, radiusMM: Float = 0,
                         size: Int = 384) throws -> Int {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal device") }
        let mesh = LatticeWizardSample.cube(edgeMM: Self.edgeMM, at: .zero)
        guard let renderer = MeshRenderer(device: device, sampleCount: 1) else {
            throw XCTSkip("MeshRenderer init: \(MeshRenderer.lastInitError ?? "?")")
        }
        try XCTSkipUnless(renderer.latticePipelinesDidBuild, "lattice MSL must compile")
        XCTAssertTrue(renderer.organicCapsulePipelineDidBuild,
                      "★ the capsule MSL must build on a real GPU — the compile guard covers "
                      + "the source, this covers the pipeline (formats, attachments)")
        try XCTSkipUnless(renderer.organicCapsulePipelineDidBuild)
        renderer.setMesh(mesh)
        renderer.camera.setOrientation(azimuth: 0.7, elevation: 0.4)
        renderer.setBodyAlpha(bodyAlpha)
        renderer.latticeOrganicRadiusMM = radiusMM
        renderer.setLatticeScene(Self.scene(capsules: capsules, mesh: mesh), token: 1)
        let d = try XCTUnwrap(renderer.latticeMaskDump(size: size), "the lattice must be in the G-buffer")
        return d.covered
    }

    /// The headline: a capsule inside the part reaches pixels; one outside is clipped by
    /// the part field; the opaque shell hides one inside; the live radius fattens it.
    @MainActor
    func testCapsulesReachPixelsAreClippedByThePartAndHiddenByTheShell() throws {
        let mesh = LatticeWizardSample.cube(edgeMM: Self.edgeMM, at: .zero)
        let c = 0.5 * (mesh.bounds.min + mesh.bounds.max)
        let inside = OrganicCapsule(a: c - SIMD3(6, 0, 0), b: c + SIMD3(6, 0, 0), r: 1.0)
        let outside = OrganicCapsule(a: c + SIMD3(60, 0, 0), b: c + SIMD3(72, 0, 0), r: 1.0)
        let seen = try covered(capsules: [inside], bodyAlpha: 0)
        let clipped = try covered(capsules: [outside], bodyAlpha: 0)
        let hidden = try covered(capsules: [inside], bodyAlpha: 1)
        let fat = try covered(capsules: [inside], bodyAlpha: 0, radiusMM: 2.5)
        let none = try covered(capsules: [], bodyAlpha: 0)
        print("""

        ── organic capsule impostors, 384² G-buffer ──────────────────────────
        one 12 mm strut, r 1.0, inside the cube, body hidden   \(seen) px
        the same strut at a live radius of 2.5 mm               \(fat) px
        a strut 60 mm outside the part                          \(clipped) px
        the inside strut behind an OPAQUE shell                 \(hidden) px
        no capsules at all (the march is off)                   \(none) px
        """)
        XCTAssertGreaterThan(seen, 200, "★ the capsule must reach pixels")
        XCTAssertEqual(clipped, 0, "★ a strut outside the part is cut by the part field")
        XCTAssertEqual(hidden, 0, "★ the shell's depth buffer hides a strut inside it")
        XCTAssertGreaterThan(fat, seen, "★ the Thicker radius is a uniform on the capsules")
        XCTAssertEqual(none, 0, "★ with organic drawn as capsules the march draws nothing")
    }
    #endif

    /// The call sites, pinned by text: the march is switched off by the same flag that
    /// draws the capsules, and the draw is instanced over the span count.
    func testTheRendererDrawsCapsulesInThePrepassAndSilencesTheMarch() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/TopOptFlows")
        let mm = try String(contentsOf: root.appendingPathComponent("MetalMeshView.swift"), encoding: .utf8)
        XCTAssertTrue(mm.contains("if lattice.capsulesReplaceField, let cpipe = organicCapsulePipeline {"))
        XCTAssertTrue(mm.contains("instanceCount: lattice.capsuleCount)"))
        XCTAssertTrue(mm.contains("fresh.drawOrganicCapsules = organicCapsulePipeline != nil"))
        let ls = try String(contentsOf: root.appendingPathComponent("LatticeSDFMetal.swift"), encoding: .utf8)
        XCTAssertTrue(ls.contains("Float(capsulesReplaceField ? 0 : debugMaxSteps)"), "★ zero steps under capsules")
        XCTAssertTrue(ls.contains("organicTex != nil, !capsulesReplaceField else { return .zero }"),
                      "★ the organic field is off under capsules")
        let src = MeshRenderer.organicCapsuleShaderSourceForTesting
        XCTAssertEqual(src.components(separatedBy: "[[depth(any)]]").count - 1, 1,
                       "one permissive depth write, on purpose (culling is off)")
        XCTAssertTrue(src.contains("lsdf_part_clip(U, sdfTex, regionTex, samp, RC, decls, p, dPart)"),
                      "★ the same clip the march applies")
        XCTAssertTrue(src.contains("shell_is_latticed(p, n, RC, shellDecls, regionTex)"),
                      "★ the same shell depth bias")
    }
}
