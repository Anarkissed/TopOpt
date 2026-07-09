// Headless macOS tests for the M7.5 face-pick + face-loop logic (FacePicker,
// FaceTopology). All GPU-free simd/array math (the M7 /app/ verification
// standard); the Metal id-buffer pass mirrors FacePicker and is maintainer device
// QA. The face-loop walk is checked on a synthetic multi-face hole AND on the real
// l-bracket fixture's two Ø5 holes (STEP import, skipped if OCCT is unavailable).

import XCTest
import simd
import TopOptKit
@testable import TopOptFlows
#if canImport(MetalKit)
import Metal
#endif

final class FaceSelectionTests: XCTestCase {

    // Repo root from this file: .../app/TopOptKit/Tests/TopOptFlowsTests/<this> → up 5.
    private static let repoRoot: URL = {
        var u = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { u.deleteLastPathComponent() }
        return u
    }()
    private static var lbracketStep: String {
        repoRoot.appendingPathComponent("core/tests/fixtures/demo/l-bracket.step").path
    }

    // MARK: - FacePicker (id-buffer readback reference)

    /// A flat quad in the z=0 plane split into a left face (id 10, x<0) and a right
    /// face (id 20, x>0), each two triangles. A camera looking straight down −Z sees
    /// the left face on the screen's left, the right face on its right.
    private func splitQuad(faceIDs ids: [Int32] = [10, 10, 20, 20]) -> ViewerMesh {
        let verts: [Float] = [
            -1, -1, 0,   // 0
             0, -1, 0,   // 1
             0,  1, 0,   // 2
            -1,  1, 0,   // 3
             1, -1, 0,   // 4
             1,  1, 0,   // 5
        ]
        let indices: [Int32] = [
            0, 1, 2,  0, 2, 3,   // left  → id 10
            1, 4, 5,  1, 5, 2,   // right → id 20
        ]
        return ViewerMesh(vertices: verts, indices: indices, faceIDs: ids)
    }

    /// A camera on the +Z axis looking at the origin down −Z (azimuth 0, elevation 0
    /// → direction (0,0,1)), framed to fit the mesh.
    private func topDownCamera(_ mesh: ViewerMesh) -> OrbitCamera {
        var cam = OrbitCamera(target: .zero, distance: 4, azimuth: 0, elevation: 0)
        cam.frame(mesh.bounds)
        return cam
    }

    func testPickMapsPixelToFaceID() {
        let mesh = splitQuad()
        let cam = topDownCamera(mesh)
        // Screen right (+x world) → the right face; screen left → the left face.
        XCTAssertEqual(FacePicker.pick(mesh: mesh, camera: cam, aspect: 1,
                                       point: CGPoint(x: 0.75, y: 0.5)), 20)
        XCTAssertEqual(FacePicker.pick(mesh: mesh, camera: cam, aspect: 1,
                                       point: CGPoint(x: 0.25, y: 0.5)), 10)
    }

    func testPickMissesOffMesh() {
        let mesh = splitQuad()
        let cam = topDownCamera(mesh)
        // Far corner projects outside the framed plane → ray misses.
        XCTAssertNil(FacePicker.pick(mesh: mesh, camera: cam, aspect: 1,
                                     point: CGPoint(x: 0.995, y: 0.005)))
    }

    #if canImport(MetalKit)
    /// The real Metal id-buffer pass (render face ids to an offscreen R32Uint
    /// target, read back the pixel) must resolve the same face id as the CPU
    /// reference. Skipped where no Metal device is available (e.g. CI).
    func testIDBufferReadbackMatchesCPUPick() throws {
        guard let device = MTLCreateSystemDefaultDevice(),
              let renderer = MeshRenderer(device: device) else {
            throw XCTSkip("No Metal device / renderer in this environment")
        }
        let mesh = splitQuad()
        renderer.setMesh(mesh)
        renderer.camera = topDownCamera(mesh)   // setMesh reframes; force top-down

        let right = renderer.pickFaceID(atNormalizedPoint: CGPoint(x: 0.75, y: 0.5),
                                        width: 128, height: 128)
        let left = renderer.pickFaceID(atNormalizedPoint: CGPoint(x: 0.25, y: 0.5),
                                       width: 128, height: 128)
        if right == nil && left == nil {
            throw XCTSkip("id pass unavailable (no id pipeline on this device)")
        }
        XCTAssertEqual(right, 20)
        XCTAssertEqual(left, 10)
    }
    #endif

    func testPickTriangleWorksWithoutFaceIDs() {
        // An STL has no face ids: pick() → nil, but a triangle still resolves.
        let mesh = splitQuad(faceIDs: [])
        let cam = topDownCamera(mesh)
        XCTAssertNil(FacePicker.pick(mesh: mesh, camera: cam, aspect: 1,
                                     point: CGPoint(x: 0.75, y: 0.5)))
        XCTAssertNotNil(FacePicker.pickTriangle(mesh: mesh, camera: cam, aspect: 1,
                                                point: CGPoint(x: 0.75, y: 0.5)))
    }

    // MARK: - FaceTopology (curvature + loop walk)

    /// An octagonal-prism wall (faces 1 and 2 each spanning four side segments,
    /// edge-adjacent along two seams) capped by a planar octagon fan (face 3). The
    /// wall faces are curved; the cap is planar.
    private func octagonWithCap() -> ViewerMesh {
        let n = 8
        var verts: [Float] = []
        // 0..7 bottom ring, 8..15 top ring, 16 = top centre.
        for k in 0..<n {
            let a = Float(k) * (2 * .pi / Float(n))
            verts += [cos(a), sin(a), 0]
        }
        for k in 0..<n {
            let a = Float(k) * (2 * .pi / Float(n))
            verts += [cos(a), sin(a), 1]
        }
        verts += [0, 0, 1]                          // 16: top centre
        let topCentre: Int32 = 16

        var indices: [Int32] = []
        var faceIDs: [Int32] = []
        func B(_ k: Int) -> Int32 { Int32(k % n) }
        func T(_ k: Int) -> Int32 { Int32(n + (k % n)) }
        for k in 0..<n {
            // side quad Bk, B(k+1), T(k+1), Tk → two triangles, outward wound.
            indices += [B(k), B(k + 1), T(k + 1),  B(k), T(k + 1), T(k)]
            let id: Int32 = k < 4 ? 1 : 2           // first four segments → face 1
            faceIDs += [id, id]
        }
        for k in 0..<n {
            // planar top cap fan.
            indices += [topCentre, T(k), T(k + 1)]
            faceIDs += [3]
        }
        return ViewerMesh(vertices: verts, indices: indices, faceIDs: faceIDs)
    }

    func testCurvatureClassification() {
        let mesh = octagonWithCap()
        XCTAssertTrue(FaceTopology.isCurved(1, in: mesh))
        XCTAssertTrue(FaceTopology.isCurved(2, in: mesh))
        XCTAssertFalse(FaceTopology.isCurved(3, in: mesh))   // planar cap
        XCTAssertEqual(FaceTopology.curvedFaceIDs(in: mesh), [1, 2])
    }

    func testLoopWalksAdjacentCurvedFaces() {
        let mesh = octagonWithCap()
        // Faces 1 and 2 are curved and edge-adjacent → the loop grabs both, but stops
        // at the planar cap (face 3).
        XCTAssertEqual(FaceTopology.loop(fromFace: 1, in: mesh), [1, 2])
        XCTAssertEqual(FaceTopology.loop(fromFace: 2, in: mesh), [1, 2])
        // Tapping the planar cap selects only that face.
        XCTAssertEqual(FaceTopology.loop(fromFace: 3, in: mesh), [3])
    }

    func testAdjacencyIsSymmetric() {
        let mesh = octagonWithCap()
        let adj = FaceTopology.adjacency(in: mesh)
        XCTAssertTrue(adj[1]?.contains(2) ?? false)
        XCTAssertTrue(adj[2]?.contains(1) ?? false)
        XCTAssertTrue(adj[1]?.contains(3) ?? false)   // wall meets cap along the rim
    }

    // MARK: - l-bracket holes (real STEP fixture; skipped if OCCT unavailable)

    func testLBracketHolesAreSingleFaceLoops() throws {
        let imported: ImportedMesh
        do {
            imported = try TopOptKit.importMesh(path: Self.lbracketStep)
        } catch {
            throw XCTSkip("STEP import unavailable in this environment: \(error)")
        }
        XCTAssertFalse(imported.faceIDs.isEmpty, "STEP import must carry per-triangle face ids")
        let mesh = ViewerMesh(vertices: imported.vertices, indices: imported.indices,
                              faceIDs: imported.faceIDs)

        // expected_values.json: 10 B-rep faces, 8 planar + 2 cylindrical (the holes).
        XCTAssertEqual(FaceTopology.faceIDs(in: mesh).count, 10)
        let holes = FaceTopology.curvedFaceIDs(in: mesh)
        XCTAssertEqual(holes.count, 2, "the two Ø5 through-holes are the curved faces")

        // Each hole is a single cylindrical face separated from the other by planar
        // plate material, so tapping inside it selects exactly that hole's face loop.
        for h in holes {
            XCTAssertEqual(FaceTopology.loop(fromFace: h, in: mesh), [h])
        }
    }
}
