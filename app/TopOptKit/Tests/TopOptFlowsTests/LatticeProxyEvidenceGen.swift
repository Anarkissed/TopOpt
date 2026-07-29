// LatticeProxyEvidenceGen — renders the device-real proxy IMAGES for the handoff
// (V5), through the SAME Metal pipeline the app draws with (MeshRenderer +
// renderOffscreen), on the maintainer's own bracket. Opt-in: set
// TOPOPT_LATTICE_EVIDENCE_DIR to a directory and it writes PNGs there; without it the
// test SKIPS, so a normal run stays fast. Nothing here is a frame-time claim (that is
// LatticeProxyProfileTests) — this just proves the proxy produces a real, legible
// picture: the part shaded by density + the true-geometry sample patch.

import XCTest
import Metal
import simd
import ImageIO
import CoreGraphics
import TopOptDesign
@testable import TopOptFlows

@MainActor
final class LatticeProxyEvidenceGen: XCTestCase {

    private var outDir: String? { ProcessInfo.processInfo.environment["TOPOPT_LATTICE_EVIDENCE_DIR"] }

    private static let repoRoot: URL = {
        var u = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { u.deleteLastPathComponent() }
        return u
    }()
    private static var bracketPath: String {
        repoRoot.appendingPathComponent("core/tests/fixtures/mesh/WallMount_ShelfBracket.stl").path
    }

    func testRenderProxyImages() throws {
        let dir = try XCTSkipIfNil(outDir, "set TOPOPT_LATTICE_EVIDENCE_DIR to render evidence")
        let data = try XCTUnwrap(try? Data(contentsOf: URL(fileURLWithPath: Self.bracketPath)))
        let (verts, idx) = MeshExport.parseBinarySTL(data)
        let mesh = ViewerMesh(vertices: verts, indices: idx, faceIDs: [])
        guard let device = MTLCreateSystemDefaultDevice(), let renderer = MeshRenderer(device: device)
        else { throw XCTSkip("no Metal device") }

        let model = LatticeProxyModel(params: LatticeProxyParams(latticeID: "octet", cellMM: 8,
                                        minRelativeDensity: 0.08, maxRelativeDensity: 0.55))
        let bg = DS.Color.background
        let clear = MTLClearColor(red: bg.r, green: bg.g, blue: bg.b, alpha: 1)
        let size = 1024

        // 1) UNIFORM density preview (the workspace pre-run state, V4 no-field case).
        renderer.setMesh(mesh)
        renderer.setStressTints(model.densityTints(for: mesh, field: nil))
        try write(renderer, size: size, clear: clear, dir: dir, name: "proxy_uniform_bracket.png")

        // 2) GRADED density preview from an ILLUSTRATIVE cantilever-style demand field
        //    (von Mises rising toward one end of the long axis). NOT a solve — it shows
        //    the proxy's graded shading; grading CORRECTNESS is pinned in
        //    LatticeProxyTests against a controlled field.
        let field = illustrativeDemandField(bounds: mesh.bounds)
        renderer.setStressTints(model.densityTints(for: mesh, field: field))
        try write(renderer, size: size, clear: clear, dir: dir, name: "proxy_graded_bracket.png")

        // 3) The true-geometry SAMPLE PATCH (what the cells actually look like).
        let patch = model.samplePatchMesh()
        renderer.setMesh(patch)
        renderer.setStressTints([])
        try write(renderer, size: 512, clear: clear, dir: dir, name: "proxy_sample_patch.png")

        print("wrote proxy evidence PNGs to \(dir)")
    }

    /// A smooth demand field over the mesh bounds: von Mises rising with distance along
    /// the LONGEST axis (a cantilever-like gradient), peak 1. Illustrative only.
    private func illustrativeDemandField(bounds: MeshBounds) -> StressField {
        let ext = bounds.max - bounds.min
        // longest axis
        let axis = ext.x >= ext.y && ext.x >= ext.z ? 0 : (ext.y >= ext.z ? 1 : 2)
        let n = 32
        let sp = simd_length(ext) / Float(n)
        var vals = [Float](repeating: 0, count: n * n * n)
        for k in 0..<n { for j in 0..<n { for i in 0..<n {
            let f: Float = axis == 0 ? Float(i) : axis == 1 ? Float(j) : Float(k)
            vals[(k * n + j) * n + i] = f / Float(n - 1)          // 0…1 along the long axis
        } } }
        return StressField(nx: n, ny: n, nz: n, origin: bounds.min, spacing: sp, values: vals)
    }

    private func write(_ renderer: MeshRenderer, size: Int, clear: MTLClearColor,
                       dir: String, name: String) throws {
        guard let bgra = renderer.renderOffscreen(size: size, clear: clear, stage: true),
              let img = MeshThumbnail.image(from: bgra, size: size) else {
            throw XCTSkip("render failed for \(name)")
        }
        let url = URL(fileURLWithPath: dir).appendingPathComponent(name)
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else {
            XCTFail("cannot create PNG destination"); return
        }
        CGImageDestinationAddImage(dest, img, nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest), "PNG write \(name)")
    }
}

private func XCTSkipIfNil<T>(_ value: T?, _ message: String) throws -> T {
    guard let v = value else { throw XCTSkip(message) }
    return v
}
