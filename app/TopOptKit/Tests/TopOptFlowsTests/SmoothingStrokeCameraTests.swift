// SmoothingStrokeCameraTests — ONE BRUSH STROKE MUST NOT MOVE HIS VIEW
// (task 2026-08-08-smoothing-that-works-and-is-usable, S1a / bar R2).
//
// HIS WORDS: "it currently takes a single brush stroke, then resets the entire
// page (including moving the zoom/position back to the origin point) every single
// time you let go of the brush."
//
// WHAT THESE TESTS DRIVE, AND WHY IT IS NOT A VALUE TYPE. The decision lives in
// `MetalMeshView.Coordinator.apply(_:to:)` — the exact method `updateUIView`
// calls on every SwiftUI pass — over a real `MeshRenderer` on a real GPU. Four
// consecutive PRs on this page shipped app-side defects behind green checks
// because their tests called a helper production did not call; so these build the
// inputs through `MetalMeshView`'s own initializer, hand them to the real
// coordinator, and read the camera out of the shared `OrbitCameraModel` the app
// binds to the viewer. Nothing here mirrors the production logic.
//
// THE SHAPE OF EACH TEST IS A PAIR, and the first half is not decoration:
//
//   * `testANewPartStillReframesTheCamera` is the POSITIVE CONTROL. If the
//     framing stopped working, every "the camera did not move" assertion below
//     would pass vacuously forever. It asserts a genuinely different mesh DOES
//     reframe.
//   * `testAStrokeDoesNotMoveTheCamera` is the bar. It also asserts the renderer
//     actually took the new positions — a swap that quietly did nothing would
//     otherwise satisfy "the camera did not move" perfectly.

import XCTest
import Metal
import MetalKit
import simd
@testable import TopOptFlows

@MainActor
final class SmoothingStrokeCameraTests: XCTestCase {

    // MARK: - fixtures

    /// A unit box. Eight welded vertices, twelve triangles.
    private static let boxCorners: [SIMD3<Float>] = [
        SIMD3(0, 0, 0), SIMD3(1, 0, 0), SIMD3(1, 1, 0), SIMD3(0, 1, 0),
        SIMD3(0, 0, 1), SIMD3(1, 0, 1), SIMD3(1, 1, 1), SIMD3(0, 1, 1)]
    private static let boxTris: [Int32] = [
        1, 2, 6, 1, 6, 5, 0, 4, 7, 0, 7, 3, 3, 7, 6, 3, 6, 2,
        0, 1, 5, 0, 5, 4, 4, 5, 6, 4, 6, 7, 0, 3, 2, 0, 2, 1]
    private static var boxVerts: [Float] { boxCorners.flatMap { [$0.x, $0.y, $0.z] } }

    /// THE VARIANT AS THE RUN MADE IT.
    private func original() -> ViewerMesh {
        ViewerMesh(vertices: Self.boxVerts, indices: Self.boxTris, faceIDs: [],
                   pseudoFaces: false, smoothShaded: true)
    }

    /// THE SAME SURFACE AFTER A STROKE: identical vertex count, identical
    /// triangle list, some positions moved. This is exactly what
    /// `smooth_brush_preview` returns — the smoother keeps the welded topology
    /// vertex-for-vertex — and it is why the swap cannot be told from a new part
    /// by counts or by bounds alone.
    private func afterAStroke() -> ViewerMesh {
        var v = Self.boxVerts
        v[0] += 0.02; v[1] -= 0.015; v[5] += 0.03
        return ViewerMesh(vertices: v, indices: Self.boxTris, faceIDs: [],
                          pseudoFaces: false, smoothShaded: true)
    }

    /// A GENUINELY DIFFERENT OBJECT: different counts, different connectivity.
    private func aDifferentPart() -> ViewerMesh {
        let v: [Float] = [0, 0, 0, 40, 0, 0, 40, 30, 0, 0, 30, 0, 20, 15, 25]
        let t: [Int32] = [0, 1, 4, 1, 2, 4, 2, 3, 4, 3, 0, 4, 0, 2, 1, 0, 3, 2]
        return ViewerMesh(vertices: v, indices: t, faceIDs: [])
    }

    // MARK: - harness

    private func device() throws -> MTLDevice {
        try XCTUnwrap(MTLCreateSystemDefaultDevice(), "no Metal device on this machine")
    }

    /// The real viewer, wired the way `WorkspacePlaceholder` wires it: one shared
    /// `OrbitCameraModel`, one `MeshRenderer`, one coordinator.
    private struct Viewer {
        let coordinator: MetalMeshView.Coordinator
        let renderer: MeshRenderer
        let view: MTKView
        let camera: OrbitCameraModel
    }

    private func makeViewer() throws -> Viewer {
        let d = try device()
        let renderer = try XCTUnwrap(MeshRenderer(device: d),
                                     "MeshRenderer init failed: \(MeshRenderer.lastInitError ?? "unknown")")
        let c = MetalMeshView.Coordinator()
        c.renderer = renderer
        return Viewer(coordinator: c, renderer: renderer,
                      view: MTKView(frame: CGRect(x: 0, y: 0, width: 400, height: 300), device: d),
                      camera: OrbitCameraModel())
    }

    /// Put a mesh on screen through the production path — `MetalMeshView`'s own
    /// initializer builds the inputs, the coordinator applies them.
    private func show(_ mesh: ViewerMesh, in v: Viewer) async {
        v.coordinator.apply(MetalMeshView(mesh: mesh, camera: v.camera).inputs, to: v.view)
        // The coordinator hands a freshly-framed camera back to the shared model on
        // the NEXT runloop turn (it must not publish inside a view update). Let that
        // land, or a test would read the camera one hop before the reset it exists
        // to catch.
        await settle()
    }

    private func settle() async {
        for _ in 0..<10 {
            await Task.yield()
            RunLoop.current.run(until: Date().addingTimeInterval(0.005))
        }
    }

    /// The user grabs the part: zooms in and pans off centre. Every assertion
    /// below is about whether THIS survives.
    private func userMovesTheView(_ v: Viewer) {
        v.camera.zoom(0.35)
        v.camera.pan(dx: 40, dy: -25, viewportHeight: 300)
    }

    // MARK: - the positive control

    /// If framing stopped happening at all, every "the camera did not move" bar in
    /// this file would pass for the wrong reason. A DIFFERENT mesh must still
    /// reframe.
    func testANewPartStillReframesTheCamera() async throws {
        let v = try makeViewer()
        await show(original(), in: v)
        userMovesTheView(v)
        let moved = v.camera.camera

        await show(aDifferentPart(), in: v)

        XCTAssertNotEqual(v.camera.camera, moved,
                          "a different part must be framed — otherwise the bars below are vacuous")
        XCTAssertNotEqual(v.camera.camera.distance, moved.distance, accuracy: 0,
                          "framing sets the fit distance")
    }

    // MARK: - the bar

    /// ★ THE ONE HE HITS ON EVERY STROKE. The stroke's preview is the same
    /// surface with moved vertices; the camera must come out bit-identical.
    func testAStrokeDoesNotMoveTheCamera() async throws {
        let v = try makeViewer()
        await show(original(), in: v)
        userMovesTheView(v)
        let before = v.camera.camera

        await show(afterAStroke(), in: v)

        // NOT "close to". The stroke has no business touching the camera at all,
        // so the bar is equality on the whole value — target, home target,
        // distance, azimuth, elevation, roll, fov and both zoom limits.
        XCTAssertEqual(v.camera.camera, before,
                       "a brush stroke must leave the camera exactly as the user had it")
        XCTAssertEqual(v.renderer.camera, before,
                       "…and the renderer must be drawing from that same camera")

        // AND THE SWAP MUST ACTUALLY HAVE HAPPENED. Without this the test passes
        // for a viewer that ignored the stroke entirely — which is a worse defect
        // than the one it is guarding.
        XCTAssertEqual(v.renderer.mesh?.signature, afterAStroke().signature,
                       "the renderer must be holding the stroked geometry, not the pre-stroke one")
    }

    /// Repeated strokes, which is how the page is actually used: the camera must
    /// not creep either.
    func testFiveConsecutiveStrokesLeaveTheCameraWhereItWas() async throws {
        let v = try makeViewer()
        await show(original(), in: v)
        userMovesTheView(v)
        let before = v.camera.camera

        var verts = Self.boxVerts
        for pass in 1...5 {
            verts[3 * pass] += 0.01
            await show(ViewerMesh(vertices: verts, indices: Self.boxTris, faceIDs: [],
                                  pseudoFaces: false, smoothShaded: true), in: v)
            XCTAssertEqual(v.camera.camera, before, "stroke \(pass) moved the camera")
        }
    }

    /// The Original/Smoothed toggle is the same swap in the other direction, and
    /// it was resetting the view too.
    func testTogglingBackToTheOriginalDoesNotMoveTheCamera() async throws {
        let v = try makeViewer()
        await show(original(), in: v)
        userMovesTheView(v)
        let before = v.camera.camera

        await show(afterAStroke(), in: v)
        await show(original(), in: v)

        XCTAssertEqual(v.camera.camera, before,
                       "flipping between Original and Smoothed must not reframe")
    }

    // MARK: - the rest of "resets the entire page"

    /// `setMesh` resets the settle rotation to identity, and the coordinator then
    /// cleared `lastSettleVector` so the settle was re-applied — with its 0.8 s
    /// animation. That is the part of the reset that is NOT the camera: the part
    /// visibly re-dropped onto the ground on every stroke.
    ///
    /// The bar is the RESTART COUNT, not `isSettling`: the animation is advanced
    /// by `draw`, so a headless test that never draws would see `isSettling`
    /// stuck true and prove nothing either way.
    func testAStrokeDoesNotRestartTheSettleAnimation() async throws {
        let v = try makeViewer()
        let tilted = simd_quatf(angle: .pi / 5, axis: SIMD3<Float>(0, 0, 1))
        func showSettled(_ m: ViewerMesh) async {
            v.coordinator.apply(MetalMeshView(mesh: m, camera: v.camera,
                                              settleRotation: tilted, settleAnimated: true).inputs,
                                to: v.view)
            await settle()
        }
        await showSettled(original())
        XCTAssertEqual(v.renderer.settleBeginCount, 1, "precondition: the part settled once")

        await showSettled(afterAStroke())

        XCTAssertEqual(v.renderer.settleBeginCount, 1,
                       "a stroke must not re-run the settle animation — the part must not re-drop")
    }

    /// The positive control for the bar above: a genuinely new part MUST settle
    /// again, or the assertion would pass on a viewer that had stopped settling.
    func testANewPartDoesSettleAgain() async throws {
        let v = try makeViewer()
        let tilted = simd_quatf(angle: .pi / 5, axis: SIMD3<Float>(0, 0, 1))
        func showSettled(_ m: ViewerMesh) async {
            v.coordinator.apply(MetalMeshView(mesh: m, camera: v.camera,
                                              settleRotation: tilted, settleAnimated: true).inputs,
                                to: v.view)
            await settle()
        }
        await showSettled(original())
        await showSettled(aDifferentPart())
        XCTAssertEqual(v.renderer.settleBeginCount, 2,
                       "a different part must be settled onto the ground in its own right")
    }

    // MARK: - the signature that carries the decision

    func testTheSignatureSeparatesAMovedSurfaceFromADifferentOne() {
        let a = original().signature
        let b = afterAStroke().signature
        let c = aDifferentPart().signature

        XCTAssertNotEqual(a.contentHash, b.contentHash,
                          "the positions moved, so this IS a different mesh to upload")
        XCTAssertTrue(a.isSameSurface(as: b),
                      "…but it is the SAME SURFACE, so it must not be reframed")
        XCTAssertFalse(a.isSameSurface(as: c),
                       "a different object must not be mistaken for a moved one")
    }

    /// The topology hash must not read the positions — otherwise it would answer
    /// the same question `contentHash` already answers and decide nothing.
    func testTheTopologyHashIgnoresThePositions() {
        let a = ViewerMeshSignature(vertices: Self.boxVerts, indices: Self.boxTris)
        var far = Self.boxVerts
        for i in far.indices { far[i] *= 7.5 }
        let b = ViewerMeshSignature(vertices: far, indices: Self.boxTris)
        XCTAssertEqual(a.topologyHash, b.topologyHash)
        XCTAssertNotEqual(a.contentHash, b.contentHash)

        // …and it must read the indices, or it would call every mesh with the same
        // counts the same surface. (Positions 1 and 2 carry 2 and 6 — different
        // values, so the swap is a real change of connectivity.)
        var swapped = Self.boxTris
        XCTAssertNotEqual(swapped[1], swapped[2], "precondition: the swap changes something")
        swapped.swapAt(1, 2)
        let c = ViewerMeshSignature(vertices: Self.boxVerts, indices: swapped)
        XCTAssertNotEqual(a.topologyHash, c.topologyHash)
    }
}
