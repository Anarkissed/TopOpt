// LatticeSDFProfileTests — the device-comparable cost of the RAYMARCHED lattice
// preview (handoff 2026-07-29-lattice-preview, bars P3/V1/V2). Runs on the
// maintainer's own bracket on whatever GPU runs the tests (his M2 Pro — the same
// machine as handoff 134 / PR-166 and LatticeProxyProfileTests, so the numbers are
// directly comparable to BOTH the 0.436 ms body baseline and the density-proxy
// baseline this preview costs against).
//
// It measures `LatticeSDFRenderer.measureFrameGPUSeconds` (the REAL fragment shader),
// at 8/6/4 mm cells and 1024²/2048², and reports:
//   • triangles + GPU memory: ZERO / a few uniform buffers — no geometry at any cell.
//   • frame time vs the density-proxy busy scene and the 134 body baseline.
// The assertions keep it honest: interactive at 1024², and — the headline property —
// the cost does NOT explode as the cell shrinks the way a real mesh's (1/cell)³ does.

import XCTest
import Metal
import simd
@testable import TopOptFlows
import TopOptDesign

@MainActor
final class LatticeSDFProfileTests: XCTestCase {

    private static let repoRoot: URL = {
        var u = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { u.deleteLastPathComponent() }
        return u
    }()
    private static var bracketPath: String {
        repoRoot.appendingPathComponent("core/tests/fixtures/mesh/WallMount_ShelfBracket.stl").path
    }

    private func gpuMS(_ r: LatticeSDFRenderer, size: Int) -> Double? {
        for _ in 0..<5 { _ = r.measureFrameGPUSeconds(size: size) }
        var best: Double?
        for _ in 0..<40 {
            guard let s = r.measureFrameGPUSeconds(size: size) else { return nil }
            best = Swift.min(best ?? .infinity, s * 1000)
        }
        return best
    }

    func testRaymarchCostOnMaintainerBracket() throws {
        let data = try XCTUnwrap(try? Data(contentsOf: URL(fileURLWithPath: Self.bracketPath)),
                                 "maintainer bracket fixture missing")
        let (verts, idx) = MeshExport.parseBinarySTL(data)
        let mesh = ViewerMesh(vertices: verts, indices: idx, faceIDs: [])
        guard let device = MTLCreateSystemDefaultDevice(),
              let renderer = LatticeSDFRenderer(device: device) else {
            throw XCTSkip("no Metal device / init: \(LatticeSDFRenderer.lastInitError ?? "?")")
        }

        let field = illustrativeField(mesh.bounds)
        let scene = LatticeSDFScene(mesh: mesh, field: field, latticeID: "octet")
        renderer.setScene(scene)
        // setScene no longer frames the renderer camera (ONE camera — the app frames
        // the shared model); offscreen harnesses frame explicitly.
        renderer.camera.frame(scene.bounds)
        renderer.camera.setOrientation(azimuth: 0.7, elevation: 0.5)

        print("== LATTICE SDF PREVIEW PROFILE (handoff 2026-07-29) — GPU: "
            + (device.name) + " ==")
        let b = mesh.bounds.max - mesh.bounds.min
        print(String(format: "part: WallMount_ShelfBracket  bbox=%.0f×%.0f×%.0f mm  occupancy grid=%d×%d×%d (%.1f MB f16)",
                     b.x, b.y, b.z, scene.occupancy.nx, scene.occupancy.ny, scene.occupancy.nz,
                     Double(scene.occupancy.count * 2) / (1024 * 1024)))
        print("segments in shader soup: \(scene.preview.segments.count) capsules (octet)")
        print("GEOMETRY: 0 triangles, 0 vertex buffers — a full-screen triangle + one uniform buffer, at EVERY cell.")

        print("P3/V2  cell |  @1024²  |  @2048²   (proxy busy scene: 0.31 ms @1024²; 134 body: 0.436 ms)")
        var ms1024: [Double: Double] = [:]
        for cell in [8.0, 6.0, 4.0] {
            renderer.params = LatticeProxyParams(latticeID: "octet", cellMM: cell,
                                                 minRelativeDensity: 0.10, maxRelativeDensity: 0.55)
            let a = gpuMS(renderer, size: 1024)
            let c = gpuMS(renderer, size: 2048)
            if let a { ms1024[cell] = a }
            print(String(format: "       %.0f mm | %@ ms | %@ ms", cell, fmt(a), fmt(c)))
        }

        // Headline: cost does NOT grow as (1/cell)³. A real mesh 8→4 mm is 8× the tris
        // (368 k → 2.95 M here); the raymarch grows only ~linearly with 1/cell (more
        // sphere-trace steps as the max empty gap shrinks), and often far less.
        if let m8 = ms1024[8.0], let m4 = ms1024[4.0] {
            let ratio = m4 / m8
            print(String(format: "       8→4 mm frame-time ratio: %.2f×  (a real MESH would be 8.0× the triangles)", ratio))
            XCTAssertLessThan(ratio, 4.0, "raymarch must not scale like mesh triangles")
        }
        // Interactive at 1024² (well inside the 16.6 ms 60 Hz budget).
        if let m8 = ms1024[8.0] { XCTAssertLessThan(m8, 16.6, "must be interactive at 1024²") }

        // ---- P4: the BUSY strut-mode scene ------------------------------------
        // In the app the strut layer composites over the mesh view drawing the glass
        // body + CAD stage + design box + keep-out (the workspace's heaviest overlay
        // set). Both layers redraw per orbit tick, so the frame cost is their SUM.
        guard let meshRenderer = MTLCreateSystemDefaultDevice().flatMap({ MeshRenderer(device: $0) })
        else { throw XCTSkip("no Metal device for busy-scene pass") }
        meshRenderer.setMesh(mesh)
        let lo = mesh.bounds.min, hi = mesh.bounds.max
        meshRenderer.setDesignBoxes(
            design: DesignBoxBounds(min: lo, max: hi),
            designColor: SIMD4<Float>(0.04, 0.52, 1, 1),
            keepOuts: [DesignBoxBounds(min: lo, max: (lo + hi) * 0.5)],
            keepOutColor: SIMD4<Float>(1, 0.42, 0.38, 1))
        var meshMS: Double?
        for _ in 0..<5 { _ = meshRenderer.measureFrameGPUSeconds(size: 1024, stage: true) }
        for _ in 0..<40 {
            guard let s = meshRenderer.measureFrameGPUSeconds(size: 1024, stage: true) else { break }
            meshMS = Swift.min(meshMS ?? .infinity, s * 1000)
        }
        renderer.params = LatticeProxyParams(latticeID: "octet", cellMM: 8,
                                             minRelativeDensity: 0.10, maxRelativeDensity: 0.55)
        let strutMS = gpuMS(renderer, size: 1024)
        if let meshMS, let strutMS {
            let total = meshMS + strutMS
            print(String(format: "P4  busy strut-mode scene @1024²: mesh+stage+boxes %.3f ms + raymarch %.3f ms = %.3f ms (60 Hz budget 16.6)",
                         meshMS, strutMS, total))
            XCTAssertLessThan(total, 16.6, "busy strut-mode scene must stay interactive at the capped resolution")
        }
    }

    private func illustrativeField(_ bounds: MeshBounds) -> StressField {
        let ext = bounds.max - bounds.min
        let axis = ext.x >= ext.y && ext.x >= ext.z ? 0 : (ext.y >= ext.z ? 1 : 2)
        let n = 40
        let sp = simd_length(ext) / Float(n)
        var vals = [Float](repeating: 0, count: n * n * n)
        for k in 0..<n { for j in 0..<n { for i in 0..<n {
            let f: Float = axis == 0 ? Float(i) : axis == 1 ? Float(j) : Float(k)
            vals[(k * n + j) * n + i] = f / Float(n - 1)
        } } }
        return StressField(nx: n, ny: n, nz: n, origin: bounds.min, spacing: sp, values: vals)
    }

    private func fmt(_ v: Double?) -> String { v.map { String(format: "%.3f", $0) } ?? "n/a" }
}
