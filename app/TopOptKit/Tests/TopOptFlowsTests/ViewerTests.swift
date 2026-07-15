// Headless macOS tests for the M7.4 Metal viewer's pure logic: mesh geometry
// (bounds + smooth normals), the render-ready ViewerMesh, and the OrbitCamera
// (framing, orbit/zoom clamping, and the view/projection matrices). The Metal
// draw itself (MetalMeshView) needs a GPU + display and is maintainer device QA;
// everything asserted here is GPU-free simd math, the M7 /app/ verification
// standard being `xcodebuild test` on this package.
//
// Also checks that AppModel retains the imported geometry so the workspace viewer
// has something to render (M7.4 data seam).

import XCTest
import simd
import TopOptKit
@testable import TopOptFlows
#if canImport(MetalKit)
import Metal
#endif

final class ViewerTests: XCTestCase {

    // A unit cube [0,1]³ with outward-wound triangles (so smooth normals point out).
    private static let cubeCorners: [SIMD3<Float>] = [
        SIMD3(0, 0, 0), SIMD3(1, 0, 0), SIMD3(1, 1, 0), SIMD3(0, 1, 0),  // z = 0
        SIMD3(0, 0, 1), SIMD3(1, 0, 1), SIMD3(1, 1, 1), SIMD3(0, 1, 1),  // z = 1
    ]
    private static let cubeTris: [Int32] = [
        1, 2, 6, 1, 6, 5,   // +x
        0, 4, 7, 0, 7, 3,   // -x
        3, 7, 6, 3, 6, 2,   // +y
        0, 1, 5, 0, 5, 4,   // -y
        4, 5, 6, 4, 6, 7,   // +z
        0, 3, 2, 0, 2, 1,   // -z
    ]
    private static var cubeVerts: [Float] {
        cubeCorners.flatMap { [$0.x, $0.y, $0.z] }
    }

    // MARK: bounds

    func testBoundsOfUnitCube() {
        let b = MeshGeometry.bounds(vertices: Self.cubeVerts)
        XCTAssertFalse(b.isEmpty)
        XCTAssertEqual(b.min, SIMD3<Float>(0, 0, 0))
        XCTAssertEqual(b.max, SIMD3<Float>(1, 1, 1))
        XCTAssertEqual(b.center, SIMD3<Float>(0.5, 0.5, 0.5))
        XCTAssertEqual(b.radius, sqrt(0.75), accuracy: 1e-5)  // half the space diagonal
    }

    func testBoundsOfEmptyIsEmpty() {
        let b = MeshGeometry.bounds(vertices: [])
        XCTAssertTrue(b.isEmpty)
        XCTAssertEqual(b.radius, 0, accuracy: 1e-6)
    }

    // MARK: normals

    func testSingleTriangleNormal() {
        // Triangle in the z=0 plane wound CCW → normal +z.
        let verts: [Float] = [0, 0, 0, 1, 0, 0, 0, 1, 0]
        let n = MeshGeometry.vertexNormals(vertices: verts, indices: [0, 1, 2])
        XCTAssertEqual(n.count, 9)
        for v in 0..<3 {
            XCTAssertEqual(n[v * 3], 0, accuracy: 1e-6)
            XCTAssertEqual(n[v * 3 + 1], 0, accuracy: 1e-6)
            XCTAssertEqual(n[v * 3 + 2], 1, accuracy: 1e-6)
        }
    }

    func testCubeNormalsPointOutwardAndAreUnit() {
        let verts = Self.cubeVerts
        let normals = MeshGeometry.vertexNormals(vertices: verts, indices: Self.cubeTris)
        XCTAssertEqual(normals.count, verts.count)
        let center = SIMD3<Float>(0.5, 0.5, 0.5)
        for v in 0..<8 {
            let n = SIMD3<Float>(normals[v * 3], normals[v * 3 + 1], normals[v * 3 + 2])
            XCTAssertEqual(simd_length(n), 1, accuracy: 1e-5, "normal \(v) not unit")
            let outward = Self.cubeCorners[v] - center
            XCTAssertGreaterThan(simd_dot(n, outward), 0, "normal \(v) faces inward")
        }
    }

    func testNormalsIgnoreOutOfRangeIndices() {
        // A stray index past the vertex count must not trap; the good triangle wins.
        let verts: [Float] = [0, 0, 0, 1, 0, 0, 0, 1, 0]
        let n = MeshGeometry.vertexNormals(vertices: verts, indices: [0, 1, 2, 0, 1, 99])
        XCTAssertEqual(n.count, 9)
        XCTAssertEqual(n[2], 1, accuracy: 1e-6)
    }

    // MARK: flat (per-face) normals — the viewer default

    func testFaceNormalOfSingleTriangleIsGeometric() {
        // Triangle in z=0 wound CCW → geometric face normal +z, one per triangle.
        let verts: [Float] = [0, 0, 0, 1, 0, 0, 0, 1, 0]
        let fn = MeshGeometry.faceNormals(vertices: verts, indices: [0, 1, 2])
        XCTAssertEqual(fn.count, 1)
        XCTAssertEqual(fn[0].x, 0, accuracy: 1e-6)
        XCTAssertEqual(fn[0].y, 0, accuracy: 1e-6)
        XCTAssertEqual(fn[0].z, 1, accuracy: 1e-6)
    }

    func testFlatBufferHasThreeVerticesPerTriangle() {
        let flat = MeshGeometry.flatShaded(vertices: Self.cubeVerts, indices: Self.cubeTris)
        XCTAssertEqual(flat.vertexCount, 3 * 12)          // 3 unshared verts / triangle
        XCTAssertEqual(flat.positions.count, 3 * 12 * 3)
        XCTAssertEqual(flat.normals.count, 3 * 12 * 3)
        XCTAssertEqual(flat.interleaved().count, 3 * 12 * 6)
        // And the ViewerMesh's default render buffer is the flat one.
        let mesh = ViewerMesh(vertices: Self.cubeVerts, indices: Self.cubeTris, faceIDs: [])
        XCTAssertEqual(mesh.flat.vertexCount, 3 * 12)
    }

    func testFlatNormalsAreConstantPerTriangleAndEqualFaceNormal() {
        let verts = Self.cubeVerts
        let faces = MeshGeometry.faceNormals(vertices: verts, indices: Self.cubeTris)
        let flat = MeshGeometry.flatShaded(vertices: verts, indices: Self.cubeTris)
        XCTAssertEqual(faces.count, 12)
        for tri in 0..<12 {
            let expected = faces[tri]
            for corner in 0..<3 {
                let v = tri * 3 + corner
                let n = SIMD3<Float>(flat.normals[v * 3], flat.normals[v * 3 + 1], flat.normals[v * 3 + 2])
                XCTAssertEqual(n.x, expected.x, accuracy: 1e-6, "tri \(tri) corner \(corner)")
                XCTAssertEqual(n.y, expected.y, accuracy: 1e-6)
                XCTAssertEqual(n.z, expected.z, accuracy: 1e-6)
                XCTAssertEqual(simd_length(n), 1, accuracy: 1e-5)  // crisp unit face normal
            }
        }
    }

    // MARK: smooth-shaded flat buffer (083) — display-only anti-terracing

    func testSmoothFlatBufferMatchesFlatPositionsButUsesSmoothNormals() {
        let verts = Self.cubeVerts, tris = Self.cubeTris
        let flat = MeshGeometry.flatShaded(vertices: verts, indices: tris)
        let smooth = MeshGeometry.flatShadedSmooth(vertices: verts, indices: tris)
        // Same unshared-vertex layout: identical count and byte-identical positions
        // in the same order (so per-flat-vertex tint/flex/id buffers stay aligned).
        XCTAssertEqual(smooth.vertexCount, flat.vertexCount)
        XCTAssertEqual(smooth.positions, flat.positions)
        // Normals are the shared-vertex SMOOTH normals expanded by original index,
        // NOT the constant face normal — so they differ from the flat buffer.
        let vtxNormals = MeshGeometry.vertexNormals(vertices: verts, indices: tris)
        var t = 0, corner = 0
        for v in 0..<smooth.vertexCount {
            let idx = Int(tris[t + corner])
            for k in 0..<3 {
                XCTAssertEqual(smooth.normals[v * 3 + k], vtxNormals[idx * 3 + k], accuracy: 1e-6)
            }
            let n = SIMD3<Float>(smooth.normals[v * 3], smooth.normals[v * 3 + 1], smooth.normals[v * 3 + 2])
            XCTAssertEqual(simd_length(n), 1, accuracy: 1e-5)  // unit smooth normal
            corner += 1
            if corner == 3 { corner = 0; t += 3 }
        }
        // On the cube the smooth normals genuinely differ from the flat ones
        // (a corner vertex averages three faces), proving it is not a no-op.
        XCTAssertNotEqual(smooth.normals, flat.normals)
    }

    func testSmoothShadedViewerMeshLeavesGeometryUnchanged() {
        let verts = Self.cubeVerts, tris = Self.cubeTris
        let flatMesh = ViewerMesh(vertices: verts, indices: tris, faceIDs: [])
        let smoothMesh = ViewerMesh(vertices: verts, indices: tris, faceIDs: [], smoothShaded: true)
        // Display-only: positions, indices and bounds (the exported/printed geometry
        // proxy) are identical; only the render buffer's normals change.
        XCTAssertEqual(smoothMesh.positions, flatMesh.positions)
        XCTAssertEqual(smoothMesh.indices, flatMesh.indices)
        XCTAssertEqual(smoothMesh.flat.positions, flatMesh.flat.positions)
        XCTAssertNotEqual(smoothMesh.flat.normals, flatMesh.flat.normals)
    }

    func testCubeYieldsSixDistinctFaceNormals() {
        let faces = MeshGeometry.faceNormals(vertices: Self.cubeVerts, indices: Self.cubeTris)
        XCTAssertEqual(faces.count, 12)
        // Round to collapse the two coplanar triangles per box face into one key.
        func key(_ n: SIMD3<Float>) -> String {
            func r(_ f: Float) -> Int { Int((f * 100).rounded()) }
            return "\(r(n.x)),\(r(n.y)),\(r(n.z))"
        }
        XCTAssertEqual(Set(faces.map(key)).count, 6)
    }

    // MARK: ViewerMesh

    func testViewerMeshShape() {
        let mesh = ViewerMesh(vertices: Self.cubeVerts, indices: Self.cubeTris, faceIDs: [])
        XCTAssertEqual(mesh.vertexCount, 8)
        XCTAssertEqual(mesh.triangleCount, 12)
        XCTAssertEqual(mesh.indices.count, 36)
        XCTAssertFalse(mesh.isEmpty)
        XCTAssertEqual(mesh.interleaved().count, 8 * 6)
        XCTAssertEqual(mesh.bounds.max, SIMD3<Float>(1, 1, 1))
        // Interleave preserves position then normal for vertex 0.
        let inter = mesh.interleaved()
        XCTAssertEqual(inter[0], mesh.positions[0])
        XCTAssertEqual(inter[3], mesh.normals[0])
    }

    func testViewerMeshEmpty() {
        let mesh = ViewerMesh(vertices: [], indices: [], faceIDs: [])
        XCTAssertTrue(mesh.isEmpty)
        XCTAssertEqual(mesh.vertexCount, 0)
        XCTAssertTrue(mesh.bounds.isEmpty)
    }

    // MARK: OrbitCamera framing

    func testFrameCentersAndFits() {
        var cam = OrbitCamera()
        let b = MeshGeometry.bounds(vertices: Self.cubeVerts)
        cam.frame(b)
        XCTAssertEqual(cam.target.x, 0.5, accuracy: 1e-5)
        XCTAssertEqual(cam.target.y, 0.5, accuracy: 1e-5)
        XCTAssertEqual(cam.target.z, 0.5, accuracy: 1e-5)
        let expected = b.radius / sin(cam.fovY * 0.5) * 1.15
        XCTAssertEqual(cam.distance, expected, accuracy: 1e-4)
        // Distance sits within the zoom limits framing established.
        XCTAssertGreaterThanOrEqual(cam.distance, cam.minDistance)
        XCTAssertLessThanOrEqual(cam.distance, cam.maxDistance)
    }

    func testFrameEmptyMeshStaysUsable() {
        var cam = OrbitCamera()
        cam.frame(MeshBounds(min: .zero, max: .zero, isEmpty: true))
        XCTAssertEqual(cam.target, .zero)
        XCTAssertTrue(cam.distance.isFinite)
        XCTAssertGreaterThan(cam.distance, 0)
    }

    // MARK: OrbitCamera orbit / zoom

    func testOrbitTurnsAzimuthBySensitivity() {
        var cam = OrbitCamera(azimuth: 0, elevation: 0)
        cam.orbit(dx: 100, dy: 0)
        XCTAssertEqual(cam.azimuth, -100 * OrbitCamera.orbitSensitivity, accuracy: 1e-6)
        XCTAssertEqual(cam.elevation, 0, accuracy: 1e-6)
    }

    func testElevationClampsAtPoles() {
        var cam = OrbitCamera(elevation: 0)
        cam.orbit(dx: 0, dy: 100_000)
        XCTAssertEqual(cam.elevation, OrbitCamera.maxElevation, accuracy: 1e-6)
        cam.orbit(dx: 0, dy: -1_000_000)
        XCTAssertEqual(cam.elevation, -OrbitCamera.maxElevation, accuracy: 1e-6)
    }

    func testInitClampsElevation() {
        XCTAssertEqual(OrbitCamera(elevation: 10).elevation, OrbitCamera.maxElevation, accuracy: 1e-6)
        XCTAssertEqual(OrbitCamera(elevation: -10).elevation, -OrbitCamera.maxElevation, accuracy: 1e-6)
    }

    func testZoomClampsToLimits() {
        var cam = OrbitCamera()
        cam.frame(MeshGeometry.bounds(vertices: Self.cubeVerts))
        cam.zoom(1e-9)
        XCTAssertEqual(cam.distance, cam.minDistance, accuracy: 1e-6)
        cam.zoom(1e9)
        XCTAssertEqual(cam.distance, cam.maxDistance, accuracy: 1e-4)
    }

    func testZoomIgnoresNonPositiveFactor() {
        var cam = OrbitCamera()
        cam.frame(MeshGeometry.bounds(vertices: Self.cubeVerts))
        let d = cam.distance
        cam.zoom(0)
        cam.zoom(-2)
        XCTAssertEqual(cam.distance, d, accuracy: 1e-6)
    }

    // MARK: OrbitCamera matrices

    func testEyeIsDistanceFromTarget() {
        var cam = OrbitCamera(azimuth: 0.7, elevation: 0.3)
        cam.frame(MeshGeometry.bounds(vertices: Self.cubeVerts))
        XCTAssertEqual(simd_length(cam.eye - cam.target), cam.distance, accuracy: 1e-4)
    }

    func testViewMatrixMapsEyeAndTarget() {
        var cam = OrbitCamera(azimuth: 0.9, elevation: -0.4)
        cam.frame(MeshGeometry.bounds(vertices: Self.cubeVerts))
        let v = cam.viewMatrix()
        let eyeV = v * SIMD4<Float>(cam.eye, 1)
        XCTAssertEqual(eyeV.x, 0, accuracy: 1e-3)
        XCTAssertEqual(eyeV.y, 0, accuracy: 1e-3)
        XCTAssertEqual(eyeV.z, 0, accuracy: 1e-3)
        let tgtV = v * SIMD4<Float>(cam.target, 1)
        XCTAssertEqual(tgtV.x, 0, accuracy: 1e-3)
        XCTAssertEqual(tgtV.y, 0, accuracy: 1e-3)
        XCTAssertEqual(tgtV.z, -cam.distance, accuracy: 1e-3)  // straight ahead down −Z
    }

    func testTargetProjectsToClipCenter() {
        var cam = OrbitCamera(azimuth: 0.2, elevation: 0.2)
        cam.frame(MeshGeometry.bounds(vertices: Self.cubeVerts))
        let mvp = cam.projectionMatrix(aspect: 1.6) * cam.viewMatrix()
        let clip = mvp * SIMD4<Float>(cam.target, 1)
        XCTAssertGreaterThan(clip.w, 0)  // in front of the camera
        XCTAssertEqual(clip.x / clip.w, 0, accuracy: 1e-4)
        XCTAssertEqual(clip.y / clip.w, 0, accuracy: 1e-4)
    }

    func testNormalMatrixColumnsAreOrthonormal() {
        var cam = OrbitCamera(azimuth: 1.1, elevation: -0.6)
        cam.frame(MeshGeometry.bounds(vertices: Self.cubeVerts))
        let n = cam.normalMatrix()
        XCTAssertEqual(simd_length(n.columns.0), 1, accuracy: 1e-5)
        XCTAssertEqual(simd_length(n.columns.1), 1, accuracy: 1e-5)
        XCTAssertEqual(simd_length(n.columns.2), 1, accuracy: 1e-5)
        XCTAssertEqual(simd_dot(n.columns.0, n.columns.1), 0, accuracy: 1e-5)
    }

    // MARK: renderer actually rasterizes the mesh (GPU offscreen)

    #if canImport(MetalKit)
    func testRendererRasterizesMeshToPixels() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("no Metal device on this host")
        }
        guard let renderer = MeshRenderer(device: device) else {
            XCTFail("MeshRenderer init failed: \(MeshRenderer.lastInitError ?? "unknown")")
            return
        }
        let mesh = ViewerMesh(vertices: Self.cubeVerts, indices: Self.cubeTris, faceIDs: [])
        renderer.setMesh(mesh)  // uploads buffer + frames the camera
        guard let px = renderer.renderOffscreen(size: 128) else {
            XCTFail("renderOffscreen produced no image")
            return
        }
        // Count pixels brighter than the near-black clear: the clay mesh should
        // cover a large chunk of the framed viewport.
        var lit = 0
        var i = 0
        while i + 2 < px.count {
            if Int(px[i]) + Int(px[i + 1]) + Int(px[i + 2]) > 60 { lit += 1 }
            i += 4
        }
        XCTAssertGreaterThan(lit, 500, "mesh did not rasterize (only \(lit) lit px of \(128 * 128))")
    }

    // M7.viz.3: the flex vertex displacement actually moves geometry on the GPU, and
    // scale 0 is byte-identical to rest (the buffer contributes nothing).
    func testRendererFlexDisplacesGeometry() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("no Metal device on this host")
        }
        guard let renderer = MeshRenderer(device: device) else {
            XCTFail("MeshRenderer init failed: \(MeshRenderer.lastInitError ?? "unknown")")
            return
        }
        let mesh = ViewerMesh(vertices: Self.cubeVerts, indices: Self.cubeTris, faceIDs: [])
        renderer.setMesh(mesh)
        let rest = renderer.renderOffscreen(size: 96)
        XCTAssertNotNil(rest)

        // Shove every flat vertex +X; a non-zero scale must change the rasterization.
        let flatV = mesh.flat.vertexCount
        var disp = [Float](repeating: 0, count: flatV * 3)
        for v in 0..<flatV { disp[v * 3] = 1 }
        renderer.setFlexDisplacements(disp)
        renderer.setFlexScale(3)
        XCTAssertNotEqual(renderer.renderOffscreen(size: 96), rest, "flex scale did not move geometry")

        // Scale 0 returns to rest exactly (deterministic same-state redraw).
        renderer.setFlexScale(0)
        XCTAssertEqual(renderer.renderOffscreen(size: 96), rest, "scale 0 should equal the rest frame")
    }
    #endif

    // MARK: AppModel geometry seam (workspace viewer gets a mesh)

    private static let repoRoot: URL = {
        var u = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { u.deleteLastPathComponent() }
        return u
    }()
    private static func core(_ rel: String) -> String {
        repoRoot.appendingPathComponent("core/\(rel)").path
    }

    @MainActor
    func testAppModelRetainsImportedGeometry() {
        let m = AppModel(materialsPath: Self.core("src/materials/materials.json"))
        XCTAssertNil(m.importedMesh)
        let ok = m.importFile(atPath: Self.core("tests/fixtures/stl/cube_10mm.stl"))
        XCTAssertTrue(ok)
        XCTAssertNotNil(m.importedMesh)
        XCTAssertEqual(m.importedMesh?.triangleCount, 12)
        // The retained geometry builds a non-empty ViewerMesh for the stage.
        let vm = ViewerMesh(vertices: m.importedMesh!.vertices,
                            indices: m.importedMesh!.indices,
                            faceIDs: m.importedMesh!.faceIDs)
        XCTAssertEqual(vm.triangleCount, 12)
        XCTAssertFalse(vm.bounds.isEmpty)
    }

    @MainActor
    func testAppModelClearsGeometryOnReject() {
        let m = AppModel(materialsPath: Self.core("src/materials/materials.json"))
        XCTAssertTrue(m.importFile(atPath: Self.core("tests/fixtures/stl/cube_10mm.stl")))
        XCTAssertNotNil(m.importedMesh)
        // A non-watertight import is rejected and must clear the prior geometry.
        XCTAssertFalse(m.importFile(atPath: Self.core("tests/fixtures/stl/broken_open_cube.stl")))
        XCTAssertNil(m.importedMesh)
    }
}
