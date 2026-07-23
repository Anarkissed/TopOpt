// ViewerProfileTests — handoff 134, item 3: MEASURE the results viewer's cost on
// the real bracket variants. No fix here; this exists to produce the numbers the
// fix task will be written against, and to keep producing them (so the next change
// to the mesh pipeline shows up as a number, not a feeling).
//
// It reports, per variant: triangles, the RAW vertex count the viewer actually
// uploads (the render buffer is an unshared triangle soup — 3 vertices per
// triangle, see `MeshGeometry.flatShadedSmooth`), the WELDED vertex count the same
// geometry would need if it were indexed, and the GPU bytes each per-vertex buffer
// costs. It also times the offscreen render of the real body draw on whatever GPU
// runs the tests.
//
// HONEST SCOPE: this is a MAC-GPU measurement. It is NOT the iPad's frame time —
// the handoff records device numbers separately, captured with Instruments on the
// device, because nothing here can stand in for that.
//
// Meshes: the three accepted rungs of the demo l-bracket ladder (0.70 / 0.50 /
// 0.30). The harness (see the handoff) writes them to a directory passed in via
// TOPOPT_VIEWER_PROFILE_DIR; without it the test SKIPS, so a normal test run
// (which has no such directory) stays green and fast.

import XCTest
import Metal
import simd
@testable import TopOptFlows

final class ViewerProfileTests: XCTestCase {

    private var profileDir: String? {
        ProcessInfo.processInfo.environment["TOPOPT_VIEWER_PROFILE_DIR"]
    }

    /// One renderer for every timing in this test (see `gpuMilliseconds`).
    private lazy var sharedRenderer: MeshRenderer? = {
        MTLCreateSystemDefaultDevice().flatMap { MeshRenderer(device: $0) }
    }()

    /// Weld a triangle-soup mesh by exact position identity — the count an indexed
    /// buffer would carry. Exact (bit-pattern) equality is the right test here: the
    /// core's marching-cubes mesh already emits shared corner positions bit-for-bit,
    /// so this measures real sharing, not a tolerance-based re-merge.
    private func weldedVertexCount(_ vertices: [Float]) -> Int {
        var seen = Set<SIMD3<Float>>()
        var i = 0
        while i + 2 < vertices.count {
            seen.insert(SIMD3(vertices[i], vertices[i + 1], vertices[i + 2]))
            i += 3
        }
        return seen.count
    }

    func testProfileRealBracketVariants() throws {
        let dir = try XCTSkipIfNil(profileDir,
            "set TOPOPT_VIEWER_PROFILE_DIR to a topopt-cli --out directory to profile")
        let names = ["variant_070.stl", "variant_050.stl", "variant_030.stl"]
        print("== VIEWER PROFILE (handoff 134 item 3) — GPU: "
            + (MTLCreateSystemDefaultDevice()?.name ?? "none") + " ==")
        print("variant | tris | raw verts (soup) | welded verts | weld ratio | "
            + "pos+nrm KB | tint KB | flex KB | total KB | GPU ms @1024² | GPU ms @2048²")

        for name in names {
            let url = URL(fileURLWithPath: dir).appendingPathComponent(name)
            guard let data = try? Data(contentsOf: url) else {
                XCTFail("missing \(name) in \(dir)"); continue
            }
            let (verts, idx) = MeshExport.parseBinarySTL(data)
            let mesh = ViewerMesh(vertices: verts, indices: idx, faceIDs: [])
            let tris = idx.count / 3
            let raw = idx.count                       // the soup the viewer uploads
            let welded = weldedVertexCount(verts)

            // Per-vertex GPU buffers the viewer keeps for the body, all sized to the
            // SOUP count (MetalMeshView: interleaved pos+normal, stress tint, flex).
            let posNrmKB = Double(raw * 6 * 4) / 1024
            let tintKB = Double(raw * 4 * 4) / 1024   // float4 tint per vertex
            let flexKB = Double(raw * 3 * 4) / 1024   // float3 displacement per vertex
            let totalKB = posNrmKB + tintKB + flexKB

            // Two raster sizes: the iPad's results viewer is roughly 1024–2048 px on
            // its long edge at 2× scale, and a soup this size is vertex-bound, so the
            // pair shows how much of the cost is geometry vs. fill.
            let ms1k = gpuMilliseconds(mesh: mesh, size: 1024)
            let ms2k = gpuMilliseconds(mesh: mesh, size: 2048)
            func fmt(_ v: Double?) -> String { v.map { String(format: "%.3f", $0) } ?? "n/a" }
            print(String(format: "%@ | %d | %d | %d | %.2f× | %.0f | %.0f | %.0f | %.0f | %@ | %@",
                         name, tris, raw, welded,
                         welded > 0 ? Double(raw) / Double(welded) : 0,
                         posNrmKB, tintKB, flexKB, totalKB, fmt(ms1k), fmt(ms2k)))

            XCTAssertEqual(raw, tris * 3, "the viewer buffer is an unshared triangle soup")
            XCTAssertGreaterThan(tris, 0)
        }
    }

    /// Draw calls + submitted vertices per FRAME, measured through the renderer's own
    /// counter, for the viewer states the results screen actually runs in. Orbiting
    /// changes nothing about the frame's CONTENT — the same encode runs — so this is
    /// also the orbit number; what orbiting changes is how OFTEN it runs (the view is
    /// on-demand: paused at rest, one frame per camera change while dragging).
    func testFrameDrawCallCensus() throws {
        let dir = try XCTSkipIfNil(profileDir, "set TOPOPT_VIEWER_PROFILE_DIR to profile")
        let data = try Data(contentsOf: URL(fileURLWithPath: dir)
            .appendingPathComponent("variant_050.stl"))
        let (verts, idx) = MeshExport.parseBinarySTL(data)
        let mesh = ViewerMesh(vertices: verts, indices: idx, faceIDs: [])
        guard let device = MTLCreateSystemDefaultDevice(),
              let renderer = MeshRenderer(device: device) else { throw XCTSkip("no Metal device") }
        renderer.setMesh(mesh)

        // Results screen, plain: the CAD-stage backdrop + the body. No ground plane
        // (that is the workspace's gravity affordance), no design box, no clearances.
        _ = renderer.renderOffscreen(size: 512, stage: true)
        print(String(format: "results at rest/orbit: %d draw calls, %d vertices/frame",
                     renderer.lastFrameDrawCalls, renderer.lastFrameVertices))
        XCTAssertEqual(renderer.lastFrameDrawCalls, 2, "stage + body")
        XCTAssertEqual(renderer.lastFrameVertices, idx.count + 3,
                       "the body soup plus the stage's fullscreen triangle")

        // Thumbnail / video export path (no stage): the body alone.
        _ = renderer.renderOffscreen(size: 512, stage: false)
        print(String(format: "offscreen export: %d draw calls, %d vertices/frame",
                     renderer.lastFrameDrawCalls, renderer.lastFrameVertices))
        XCTAssertEqual(renderer.lastFrameDrawCalls, 1)
    }

    /// GPU time (ms) of the full results frame — stage backdrop + body — measured by
    /// Metal itself (no CPU readback in the timed region), reported as the MINIMUM of
    /// 40 frames. Minimum, not median, on purpose: these frames are sub-millisecond,
    /// so anything else sharing the GPU (a solve, another test, the window server)
    /// adds noise that only ever inflates a sample. The minimum is the uncontended
    /// cost, which is the number the fix task needs. nil where no Metal device exists.
    private func gpuMilliseconds(mesh: ViewerMesh, size: Int) -> Double? {
        // ONE renderer for the whole profile: a fresh one compiles its pipelines on
        // first use, and that cost lands entirely on whichever variant happens to be
        // measured first (it made the res-48 0.70 row read 3× the others). Reusing it
        // measures the mesh, not the pipeline cache.
        guard let renderer = sharedRenderer else { return nil }
        renderer.setMesh(mesh)
        for _ in 0..<5 { _ = renderer.measureFrameGPUSeconds(size: size, stage: true) }  // warm-up
        var best: Double?
        for _ in 0..<40 {
            guard let s = renderer.measureFrameGPUSeconds(size: size, stage: true) else { return nil }
            best = Swift.min(best ?? .infinity, s * 1000)
        }
        return best
    }
}

/// XCTSkipIfNil — unwrap or SKIP (rather than fail), so the profile is opt-in.
private func XCTSkipIfNil<T>(_ value: T?, _ message: String) throws -> T {
    guard let v = value else { throw XCTSkip(message) }
    return v
}
