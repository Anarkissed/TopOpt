// Regression guards for the "3D models don't display in the viewer" hunt
// (handoff 075). The diagnosis proved the shared Metal viewer draws a real
// STEP-derived mesh on the iOS Simulator (all pipelines built, 708 flat verts
// uploaded, the draw executes every frame, bodyAlpha=1, reveal disabled) — the
// blank viewer was upstream (STEP import fails on the OCCT-free sim slice), NOT
// a #78–#83 render/merge regression.
//
// These tests lock in the two invariants a future merge could silently break so
// the body would draw empty or invisible:
//   1. A normal (B-rep, faceful) STEP import hands a NON-EMPTY mesh to the viewer.
//   2. With the DEFAULT viewer state (no bodyAlpha/reveal set), the body renders
//      OPAQUE and visible — i.e. the visibility defaults are not zeroed.
//   3. A fresh results view starts fully-formed and opaque (playT=1, loadPathOn
//      off → the ResultsScreen body-alpha path resolves to 1).

import XCTest
import simd
import TopOptKit
@testable import TopOptFlows
#if canImport(MetalKit)
import Metal
#endif

final class ViewerVisibilityRegressionTests: XCTestCase {

    private static let repoRoot: URL = {
        var u = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { u.deleteLastPathComponent() }
        return u
    }()
    private static func fixture(_ rel: String) -> String {
        repoRoot.appendingPathComponent("core/tests/fixtures/\(rel)").path
    }

    // 1. The representative import path (STEP, with selectable B-rep faces) yields a
    //    non-empty ViewerMesh — the geometry the workspace viewer hands to the
    //    renderer. STL is deliberately NOT used here: it carries no faces and is not
    //    the process path.
    func testStepImportHandsNonEmptyMeshToViewer() throws {
        for name in ["step/cube.step", "demo/l-bracket.step"] {
            let path = Self.fixture(name)
            try XCTSkipUnless(FileManager.default.fileExists(atPath: path), "missing \(name)")
            let mesh = try TopOptKit.importMesh(path: path)
            let vm = ViewerMesh(vertices: mesh.vertices, indices: mesh.indices, faceIDs: mesh.faceIDs)
            XCTAssertGreaterThan(vm.triangleCount, 0, "\(name): viewer mesh must have triangles")
            XCTAssertFalse(vm.bounds.isEmpty, "\(name): viewer mesh must have non-empty bounds")
            XCTAssertGreaterThan(Set(mesh.faceIDs).count, 0, "\(name): STEP mesh must carry B-rep faces")
        }
    }

    #if canImport(MetalKit)
    // 2. With ONLY setMesh called — no bodyAlpha/reveal overrides — the body must
    //    rasterize to real pixels. This is the guard the regression hunt was about:
    //    if a merge zeroed the body-alpha default (fully transparent) or left the
    //    reveal scrub enabled at 0 (whole body discarded), this drops to ~0 lit px.
    func testBodyRendersOpaqueByDefault() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal device") }
        guard let renderer = MeshRenderer(device: device) else {
            XCTFail("MeshRenderer init failed: \(MeshRenderer.lastInitError ?? "unknown")"); return
        }
        let path = Self.fixture("demo/l-bracket.step")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: path), "missing l-bracket.step")
        let mesh = try TopOptKit.importMesh(path: path)
        let vm = ViewerMesh(vertices: mesh.vertices, indices: mesh.indices, faceIDs: mesh.faceIDs)

        renderer.setMesh(vm)   // uploads + frames; NO setBodyAlpha / setReveal calls
        guard let px = renderer.renderOffscreen(size: 128) else {
            XCTFail("renderOffscreen produced no image"); return
        }
        var lit = 0, i = 0
        while i + 2 < px.count {
            if Int(px[i]) + Int(px[i+1]) + Int(px[i+2]) > 60 { lit += 1 }
            i += 4
        }
        XCTAssertGreaterThan(lit, 500,
            "the body must render opaque by default (only \(lit) lit px of \(128*128) — a zeroed bodyAlpha/reveal default draws it invisible)")
    }
    #endif

    // 3. A fresh results view is fully-formed and opaque: playT starts at 1 (the reveal
    //    scrub shows the whole mesh) and the load-path overlay starts off (so the
    //    ResultsScreen body-alpha resolves to 1, the opaque draw). A merge flipping
    //    either default would blank / dissolve the results model on open.
    @MainActor
    func testResultsViewStartsFullyFormedAndOpaque() {
        let v = OptimizeVariant(
            requestedVolumeFraction: 0.5, achievedVolumeFraction: 0.5, massGrams: 100,
            supportVolumeVoxels: 0, meshTriangleCount: 100, worstCaseMargin: 2,
            accepted: true, v3Passes: true, minFeatureViolations: 0, minFeatureWarning: "",
            orientation: SIMD3(0, 0, 1), maxStressMPa: 10, maxInterlayerTensionMPa: 5,
            inPlaneMargin: 2, interlayerMargin: 3)
        let outcome = OptimizeOutcome(variants: [v], stoppedOnMargin: false, cancelled: false,
                                      acceptedCount: 1, voxelVolumeMM3: 1)
        let m = ResultsModel(projectName: "P", outcome: outcome)
        XCTAssertEqual(m.playT, 1, "results morph starts fully formed (reveal shows the whole mesh)")
        XCTAssertFalse(m.loadPathOn, "load-path overlay starts off, so the body draws opaque (bodyAlpha 1)")
    }
}
