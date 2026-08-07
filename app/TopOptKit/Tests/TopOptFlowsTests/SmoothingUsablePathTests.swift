// SmoothingUsablePathTests — THE WHOLE PATH, ON HIS OWN VARIANT
// (task 2026-08-08-smoothing-that-works-and-is-usable, bar R3).
//
// R3: "Report the path end to end on his own variant: stroke -> tint appears ->
// preview updates -> CAMERA UNCHANGED -> repeated strokes darken -> Smoothed view
// reachable without certifying. A test against a path he cannot reach is not
// evidence; four consecutive PRs here shipped app-side defects behind green
// checks."
//
// So this file takes that sentence literally and walks it, in order, on rung 068
// of his own ladder — 141,894 vertices of real geometry — through the objects the
// app itself uses:
//
//   * the real `SmoothBrushModel` built from that mesh, painted through the same
//     `paint(.add, triangles:)` seam `handleBrush` calls after hit-testing;
//   * the real `SmoothingPageModel` with `SmoothingPageWiring.livePreviewer` —
//     the value `WorkspacePlaceholder` passes;
//   * the real `MetalMeshView.Coordinator` over a real `MeshRenderer` and the
//     shared `OrbitCameraModel` the app binds;
//   * the real `hasSmoothedToShow`, which is now the property the Smoothed tab's
//     enable condition reads.
//
// Nothing here is a stand-in and nothing is retyped. Skipped LOUDLY if his mesh
// is absent — a machine without it must not report a green path it never walked.

import XCTest
import Metal
import MetalKit
import simd
@testable import TopOptFlows
import TopOptKit

@MainActor
final class SmoothingUsablePathTests: XCTestCase {

    private static var variantSTL: URL {
        var u = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { u.deleteLastPathComponent() }
        return u.appendingPathComponent(
            "evidence/2026-08-06-cad-face-projection/variant_068.stl")
    }

    private func settle() async {
        for _ in 0..<10 {
            await Task.yield()
            RunLoop.current.run(until: Date().addingTimeInterval(0.005))
        }
    }

    func testTheWholePathOnHisOwnVariant() async throws {
        let stl = Self.variantSTL
        try XCTSkipUnless(FileManager.default.fileExists(atPath: stl.path),
                          "SKIPPED: \(stl.path) absent — THE R3 PATH WAS NOT WALKED")

        var log = ""
        func step(_ s: String) { log += s + "\n"; print(s) }

        // ── the page, as the host opens it ───────────────────────────────────
        let mesh = try TopOptKit.importMesh(path: stl.path)
        let nverts = mesh.vertices.count / 3
        let ntris = mesh.indices.count / 3
        step("HIS VARIANT: rung 068 — \(nverts) vertices / \(ntris) triangles")

        let page = SmoothingPageModel(
            context: SmoothVariantContext(
                runName: "M2_verticalStand", variantIndex: 3,
                requestedVolumeFraction: 0.68, massGrams: 628.94,
                reportedMargin: 4595.80, accepted: true,
                pageMesh: SmoothPageMesh(path: stl.path, vertices: mesh.vertices,
                                         indices: mesh.indices),
                loadCase: nil, unavailable: nil, modelPath: stl.path),
            variantMeshPath: stl.path, smoothedMeshPath: stl.path + ".smoothed",
            runner: { _ in
                XCTFail("R3: nothing on this path may need the certification engine")
                throw TopOptError(message: "unreachable")
            },
            previewer: SmoothingPageWiring.livePreviewer)

        var brush = SmoothBrushModel(
            indices: mesh.indices, vertexCount: nverts,
            freeze: SmoothFreezeMask(frozen: [Bool](repeating: false, count: nverts),
                                     toleranceMM: 0.85, meshPath: stl.path),
            meshPath: stl.path)

        // ── the viewer, as the host wires it ─────────────────────────────────
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice(), "no Metal device")
        let renderer = try XCTUnwrap(MeshRenderer(device: device),
                                     MeshRenderer.lastInitError ?? "renderer init failed")
        let coordinator = MetalMeshView.Coordinator()
        coordinator.renderer = renderer
        let view = MTKView(frame: CGRect(x: 0, y: 0, width: 900, height: 700),
                           device: device)
        let camera = OrbitCameraModel()

        func show(_ v: [Float], _ i: [Int32], tints: [SIMD4<Float>]) async {
            let vm = ViewerMesh(vertices: v, indices: i, faceIDs: [], faceGeometry: [],
                                pseudoFaces: false, smoothShaded: true)
            coordinator.apply(MetalMeshView(mesh: vm, camera: camera,
                                            stressTints: tints).inputs, to: view)
            await settle()
        }

        await show(mesh.vertices, mesh.indices, tints: brush.viewerTints())

        // ── HE FRAMES THE PART THE WAY HE WANTS IT ───────────────────────────
        camera.zoom(0.4)
        camera.pan(dx: 55, dy: -30, viewportHeight: 700)
        let framed = camera.camera
        step(String(format: "HE SETS HIS VIEW: distance %.4f, target (%.3f, %.3f, %.3f)",
                    framed.distance, framed.target.x, framed.target.y, framed.target.z))

        // ── the patch he brushes: a connected run of real triangles ──────────
        let patch = (0..<min(40_000, ntris)).map { Int32($0) }

        // Tints are one entry per FLAT vertex — 863,160 of them. Comparing the
        // arrays with XCTAssertNotEqual prints both on failure, which is
        // unreadable; the property that matters is how much of the surface is
        // painted and how deeply, so compare that.
        func tintDigest(_ t: [SIMD4<Float>]) -> (painted: Int, sum: Double) {
            var painted = 0
            var sum = 0.0
            for c in t where c.w > 0 { painted += 1; sum += Double(c.x + c.y + c.z + c.w) }
            return (painted, sum)
        }

        var lastPreviewMoved = 0
        var levels: [Int] = []
        for pass in 1...3 {
            // ── STROKE ───────────────────────────────────────────────────────
            // `brush(_:triangles:)`, NOT `paint(_:triangles:)` — this is the seam
            // `WorkspacePlaceholder.handleBrush` calls with the hit-tested
            // triangles, and it is the one that carries the rung ladder (+1 rung
            // per stroke, capped at four). Going through the lower-level region
            // API instead would paint weights but leave `level(of:)` at 0, which
            // is a different code path from the one he uses.
            let before = tintDigest(brush.viewerTints())
            brush.beginStroke()
            brush.brush(.paint, triangles: patch)
            brush.endStroke()

            // ── TINT APPEARS ─────────────────────────────────────────────────
            let after = tintDigest(brush.viewerTints())
            XCTAssertGreaterThan(after.painted, 0,
                                 "pass \(pass): the stroke must tint the surface")
            XCTAssertNotEqual(after.sum, before.sum, accuracy: 1e-9,
                              "pass \(pass): the stroke must change what is on screen")

            // ── REPEATED STROKES DARKEN ──────────────────────────────────────
            let level = brush.level(of: patch[0])
            levels.append(level)
            XCTAssertEqual(level, pass, "pass \(pass): each stroke must deepen one rung")

            // ── PREVIEW UPDATES ──────────────────────────────────────────────
            let t0 = Date()
            await page.refreshPreview(brush: brush)
            let wall = Date().timeIntervalSince(t0)
            let p = try XCTUnwrap(page.preview, "pass \(pass): the stroke must produce a preview")
            XCTAssertGreaterThan(p.movedVertices, 0, "pass \(pass): it must have moved geometry")
            XCTAssertEqual(p.secondsImport, 0, accuracy: 0,
                           "pass \(pass): no STL may be re-read for a stroke")
            XCTAssertGreaterThan(p.movedVertices, lastPreviewMoved - 1)
            lastPreviewMoved = p.movedVertices

            // the host binds the preview to the stage
            page.showingSmoothed = true
            let g = page.currentGeometry
            XCTAssertTrue(g.smoothed, "pass \(pass): the stage must be handed the preview")
            await show(g.vertices, g.indices, tints: brush.viewerTints())

            // ── CAMERA UNCHANGED ─────────────────────────────────────────────
            XCTAssertEqual(camera.camera, framed,
                           "pass \(pass): the stroke moved his view")

            // ── SMOOTHED VIEW REACHABLE WITHOUT CERTIFYING ───────────────────
            XCTAssertNil(page.receipt, "pass \(pass): nothing was certified")
            XCTAssertNil(page.kept)
            XCTAssertTrue(page.hasSmoothedToShow,
                          "pass \(pass): the Smoothed tab must be reachable with no solve")

            step(String(format:
                "  stroke %d -> rung %d, %d vertices moved, max %.4f mm, "
                + "preview %.0f ms (import %.0f ms), camera UNCHANGED, "
                + "Smoothed reachable with receipt=nil",
                pass, level, p.movedVertices, p.maxDisplacementMM,
                wall * 1000, p.secondsImport * 1000))
        }

        XCTAssertEqual(levels, [1, 2, 3], "the rungs must deepen one per stroke")

        // ── AND BACK: the Original/Smoothed toggle must not reframe either ───
        page.showingSmoothed = false
        let back = page.currentGeometry
        XCTAssertFalse(back.smoothed)
        await show(back.vertices, back.indices, tints: brush.viewerTints())
        XCTAssertEqual(camera.camera, framed,
                       "flipping back to Original moved his view")
        step("  toggled back to Original — camera UNCHANGED")

        // ── the positive control: the renderer really is drawing the strokes ──
        XCTAssertEqual(renderer.mesh?.signature,
                       ViewerMesh(vertices: back.vertices, indices: back.indices,
                                  faceIDs: [], faceGeometry: [], pseudoFaces: false,
                                  smoothShaded: true).signature,
                       "the viewer must be holding the geometry the page last handed it")
        XCTAssertEqual(renderer.settleBeginCount, 1,
                       "the part must have settled ONCE, at open — not once per stroke")
        step("  renderer holds the page's geometry; settle ran ONCE for the whole session")

        var out = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { out.deleteLastPathComponent() }
        out.appendPathComponent("evidence/2026-08-08-smoothing-that-works-and-is-usable")
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        try ("R3 — THE PATH, WALKED END TO END ON HIS OWN VARIANT\n\n" + log)
            .write(to: out.appendingPathComponent("r3_usable_path.txt"),
                   atomically: true, encoding: .utf8)
    }
}
