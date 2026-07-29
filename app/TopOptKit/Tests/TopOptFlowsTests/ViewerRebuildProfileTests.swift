// ViewerRebuildProfileTests — the 2026-07-29 viewer-lag fix, measuring the ONE cost
// 166's ViewerProfileTests did not: the per-SwiftUI-body-evaluation CPU cost of the
// results viewer, on the SAME committed bracket meshes.
//
// 166 measured the GPU frame (sub-millisecond, fill-bound) and proved the body draw
// is cheap. It did NOT measure what happens on the CPU each time the results screen's
// `body` re-evaluates — which is once per orbit frame (the shared camera republishes)
// and 30×/s while any Play/Flex/Load-path animation runs. On every one of those,
// `ResultsScreen.viewerMesh` reads `ResultsModel.selectedMesh`, which — unlike every
// sibling derived quantity (flexCache/keyframeCache/loadPathCache/peakToRedCache) —
// was NOT cached, so it rebuilt the entire `ViewerMesh` (smooth normals + the 6×
// unshared flat-shaded soup) from scratch. That rebuild scales with triangle count,
// which is exactly why the viewer went sluggish on real (higher-resolution) variants.
//
// This test times `model.selectedMesh` accessed repeatedly, the way the body does.
// BEFORE the cache each access pays the full rebuild; AFTER, the first access builds
// and the rest are O(1) cache hits. Same meshes, same gating (TOPOPT_VIEWER_PROFILE_DIR)
// as ViewerProfileTests, so a normal test run SKIPS and stays fast.

import XCTest
import simd
@testable import TopOptFlows
@testable import TopOptKit

@MainActor
final class ViewerRebuildProfileTests: XCTestCase {

    private var profileDir: String? {
        ProcessInfo.processInfo.environment["TOPOPT_VIEWER_PROFILE_DIR"]
    }

    /// Build a one-variant results model whose selected variant carries `verts`/`idx`
    /// as its optimized mesh (the arrays `selectedMesh` builds a ViewerMesh from).
    private func model(verts: [Float], idx: [Int32]) -> ResultsModel {
        let v = OptimizeVariant(
            requestedVolumeFraction: 0.5, achievedVolumeFraction: 0.5, massGrams: 100,
            supportVolumeVoxels: 0, meshTriangleCount: idx.count / 3, worstCaseMargin: 2,
            accepted: true, v3Passes: true, maxStressMPa: 10,
            meshVertices: verts, meshIndices: idx)
        let oc = OptimizeOutcome(variants: [v], stoppedOnMargin: false, cancelled: false,
                                 acceptedCount: 1, voxelVolumeMM3: 1)
        return ResultsModel(projectName: "P", outcome: oc)
    }

    func testSelectedMeshPerBodyEvalCost() throws {
        let dir = try XCTSkipIfNil(profileDir,
            "set TOPOPT_VIEWER_PROFILE_DIR to a topopt-cli --out directory to profile")
        let names = ["variant_070.stl", "variant_050.stl", "variant_030.stl"]
        print("== VIEWER REBUILD PROFILE (2026-07-29 viewer-lag) — per-body-eval CPU cost ==")
        print("variant | tris | selectedMesh ms (min of 60) | 30 fps budget used")

        for name in names {
            let url = URL(fileURLWithPath: dir).appendingPathComponent(name)
            guard let data = try? Data(contentsOf: url) else {
                XCTFail("missing \(name) in \(dir)"); continue
            }
            let (verts, idx) = MeshExport.parseBinarySTL(data)
            let tris = idx.count / 3
            let m = model(verts: verts, idx: idx)

            // Warm up (first access builds; JIT/allocator settles).
            for _ in 0..<5 { _ = m.selectedMesh }
            // Min-of-N single accesses — the cost the body pays each re-evaluation. Min,
            // not mean, for the same reason 166 uses it: it strips scheduler/allocator
            // noise and reports the uncontended cost the fix has to move.
            var best = Double.infinity
            for _ in 0..<60 {
                let t0 = DispatchTime.now().uptimeNanoseconds
                _ = m.selectedMesh
                let dt = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1_000_000
                best = Swift.min(best, dt)
            }
            let budget = best / (1000.0 / 30.0) * 100   // % of a 33.3 ms frame at 30 fps
            print(String(format: "%@ | %d | %.3f | %.1f%%", name, tris, best, budget))
            XCTAssertGreaterThan(tris, 0)
        }
    }

    /// The fix must not change the geometry displayed (viewer-lag bar V2). Whatever the
    /// cache does, repeated `selectedMesh` reads must be byte-identical to a fresh build.
    func testCachedMeshIsGeometricallyIdentical() throws {
        let dir = try XCTSkipIfNil(profileDir, "set TOPOPT_VIEWER_PROFILE_DIR to profile")
        let data = try Data(contentsOf: URL(fileURLWithPath: dir)
            .appendingPathComponent("variant_050.stl"))
        let (verts, idx) = MeshExport.parseBinarySTL(data)
        let m = model(verts: verts, idx: idx)
        let a = try XCTUnwrap(m.selectedMesh)
        let b = try XCTUnwrap(m.selectedMesh)               // second read (cache hit once cached)
        let fresh = ViewerMesh(vertices: verts, indices: idx, faceIDs: [], smoothShaded: true)
        XCTAssertEqual(a.flat.positions, fresh.flat.positions, "positions must be identical")
        XCTAssertEqual(a.flat.normals, fresh.flat.normals, "normals must be identical")
        XCTAssertEqual(a.indices, fresh.indices, "indices must be identical")
        XCTAssertEqual(a.flat.positions, b.flat.positions, "repeated reads identical")
    }
}

private func XCTSkipIfNil<T>(_ value: T?, _ message: String) throws -> T {
    guard let v = value else { throw XCTSkip(message) }
    return v
}
