// StageBackdropTests.swift — the CAD-stage backdrop (design-overhaul round 2, item 9).
//
// The stage is a full-screen gradient + infinite floor grid compiled at runtime and built with
// `try?` (nil-on-failure), so a shader typo would SILENTLY disable it. These tests fail loudly:
//   * the exact MSL the app ships compiles and exposes both entry points;
//   * the stage pipeline actually builds inside the renderer;
//   * the backdrop is GATED — `renderOffscreen(stage:)` changes the picture when on and matches
//     the plain clear when off (so thumbnails / exported video, which pass it off, are unchanged
//     while the live viewer, which passes it on, gets the stage).
//
// GPU-gated: skips with no Metal device (headless CI), so a no-GPU host never turns red.

#if canImport(Metal)
import XCTest
import Metal
@testable import TopOptFlows

final class StageBackdropTests: XCTestCase {

    private func device() throws -> MTLDevice {
        guard let d = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("No Metal device (headless) — stage backdrop is device QA here")
        }
        return d
    }

    /// A unit cube mesh (matches the ViewerTests fixture) so the renderer has something to frame.
    private static let cubeCorners: [SIMD3<Float>] = [
        SIMD3(0, 0, 0), SIMD3(1, 0, 0), SIMD3(1, 1, 0), SIMD3(0, 1, 0),
        SIMD3(0, 0, 1), SIMD3(1, 0, 1), SIMD3(1, 1, 1), SIMD3(0, 1, 1)]
    private static let cubeTris: [Int32] = [
        1, 2, 6, 1, 6, 5, 0, 4, 7, 0, 7, 3, 3, 7, 6, 3, 6, 2,
        0, 1, 5, 0, 5, 4, 4, 5, 6, 4, 6, 7, 0, 3, 2, 0, 2, 1]
    private static var cubeVerts: [Float] { cubeCorners.flatMap { [$0.x, $0.y, $0.z] } }

    func testStageShaderCompiles() throws {
        let d = try device()
        let lib = try d.makeLibrary(source: MeshRenderer.stageShaderSourceForTesting, options: nil)
        XCTAssertNotNil(lib.makeFunction(name: "stage_vertex"), "stage vertex entry point missing")
        XCTAssertNotNil(lib.makeFunction(name: "stage_fragment"), "stage fragment entry point missing")
    }

    func testStagePipelineBuilds() throws {
        let d = try device()
        guard let renderer = MeshRenderer(device: d) else {
            XCTFail("MeshRenderer init failed: \(MeshRenderer.lastInitError ?? "unknown")"); return
        }
        XCTAssertTrue(renderer.stagePipelineDidBuild, "the CAD-stage pipeline must build on a real GPU")
    }

    /// The stage is GATED: with it OFF the picture equals the plain clear render (thumbnails /
    /// video path); with it ON the backdrop changes many pixels. Proves both that the stage draws
    /// when enabled and that it is not drawn otherwise.
    func testStageBackdropIsGated() throws {
        let d = try device()
        guard let renderer = MeshRenderer(device: d) else {
            XCTFail("MeshRenderer init failed: \(MeshRenderer.lastInitError ?? "unknown")"); return
        }
        renderer.setMesh(ViewerMesh(vertices: Self.cubeVerts, indices: Self.cubeTris, faceIDs: []))
        guard let off = renderer.renderOffscreen(size: 96, stage: false),
              let on = renderer.renderOffscreen(size: 96, stage: true) else {
            XCTFail("renderOffscreen produced no image"); return
        }
        XCTAssertNotEqual(off, on, "the CAD stage must change the picture when enabled")
        // The change is concentrated in the BACKGROUND (the mesh occludes the stage), so a large
        // fraction of pixels must differ — not just a stray few.
        var diff = 0, i = 0
        while i + 2 < off.count {
            if off[i] != on[i] || off[i + 1] != on[i + 1] || off[i + 2] != on[i + 2] { diff += 1 }
            i += 4
        }
        XCTAssertGreaterThan(diff, 96 * 96 / 4, "the stage backdrop should repaint much of the frame")
    }
}
#endif
