// FlexibleLatticeRendererCoverageTests — the two gaps the renderer's verifier found
// (task 2026-09-29-flexible-screens, overnight round), each with a control that goes red:
//   * the REGION and SKIN terms must decide the GPU field somewhere — the builder's box
//     had the mask at 1 and the skin 100 mm away, so deleting either term from the shader
//     (or binding its texture to the wrong slot) passed every test;
//   * the lattice must LAND WHERE THE PART IS on screen — every other render test compared
//     one render with another under the same camera, so a flipped image or a ray built
//     from the wrong planes passed too.
#if canImport(Metal) && canImport(MetalKit)
import XCTest
import Metal
import simd
@testable import TopOptFlows

final class FlexibleLatticeRendererCoverageTests: XCTestCase {

    func device() throws -> MTLDevice {
        guard let d = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal device") }
        return d
    }

    /// The renderer tests' 40 × 40 × 20 box, with the lattice region cut at x = 30 and a
    /// real skin: skinDist = distance to the box surface on the density grid.
    static func regionAndSkinBox(_ topo: FlexibleLatticeInputs.Topology) -> FlexibleLatticeInputs {
        var f = FlexibleLatticeRendererTests.boxInputs(topo)
        let g = f.mask
        var mask = g.values, skin = g.values
        let lo = SIMD3<Float>(0, 0, 0), hi = SIMD3<Float>(40, 40, 20)
        let centre = (lo + hi) * 0.5, half = (hi - lo) * 0.5
        for k in 0..<g.nz { for j in 0..<g.ny { for i in 0..<g.nx {
            let p = g.c0 + SIMD3<Float>(Float(i), Float(j), Float(k)) * g.spacing
            let q = abs(p - centre) - half
            let d = simd_length(simd_max(q, .zero)) + Swift.min(Swift.max(q.x, Swift.max(q.y, q.z)), 0)
            let n = (k * g.ny + j) * g.nx + i
            mask[n] = p.x > 30 ? 0 : 1
            skin[n] = abs(d)
        } } }
        f.mask.values = mask
        f.skinDist.values = skin
        f.skinMM = 2   // wide enough that the 2 mm grid resolves it
        return f
    }

    func testRegionAndSkinTermsDecideTheGPUField() throws {
        let r = try FlexibleLatticeRenderer(device: try device())
        // points concentrated where the two terms matter: near the faces and around x = 30
        var s: UInt64 = 0xC0FFEE
        func u() -> Float { s = s &* 6364136223846793005 &+ 1442695040888963407; return Float(s >> 40) / Float(1 << 24) }
        let pts = (0..<3000).map { _ in SIMD3<Float>(-1 + 42 * u(), -1 + 42 * u(), -1 + 22 * u()) }
        for topo in [FlexibleLatticeInputs.Topology.gyroid, .honeycomb] {
            let f = Self.regionAndSkinBox(topo)
            r.setInputs(f)
            let gpu = try XCTUnwrap(r.probe(pts))
            var worst: Float = 0, byRegion = 0, bySkin = 0
            for (i, p) in pts.enumerated() {
                let ref = FlexibleLatticeField.lattice(at: p, f)
                worst = max(worst, abs(gpu[i] - ref))
                let w = FlexibleLatticeField.wall(p, f), dr = FlexibleLatticeField.dRegion(p, f)
                let dp = f.partSDF.sample(p), ds = FlexibleLatticeField.dSkin(p, f)
                if dr > max(w, dp, ds) + 1e-3 { byRegion += 1 }
                if ds > max(w, dp, dr) + 1e-3 { bySkin += 1 }
            }
            // ★ CONTROLS: the same GPU probe on inputs WITHOUT each term must disagree with the
            // reference — the probe can see a dropped region term and a dropped skin term.
            var noRegion = f; noRegion.mask.values = [Float](repeating: 1, count: f.mask.values.count)
            var noSkin = f; noSkin.skinDist.values = [Float](repeating: 100, count: f.skinDist.values.count)
            r.setInputs(noRegion)
            let gpuNoRegion = try XCTUnwrap(r.probe(pts))
            r.setInputs(noSkin)
            let gpuNoSkin = try XCTUnwrap(r.probe(pts))
            let missRegion = pts.indices.map { abs(gpuNoRegion[$0] - FlexibleLatticeField.lattice(at: pts[$0], f)) }.max() ?? 0
            let missSkin = pts.indices.map { abs(gpuNoSkin[$0] - FlexibleLatticeField.lattice(at: pts[$0], f)) }.max() ?? 0
            print("FLEX-TERMS \(topo): max |gpu − swift| \(worst) mm over \(pts.count) points; region decides at "
                  + "\(byRegion), skin at \(bySkin); controls: region dropped \(missRegion) mm, skin dropped \(missSkin) mm")
            XCTAssertLessThanOrEqual(worst, 2e-3, "\(topo): GPU ≠ Swift with the region and skin terms live")
            XCTAssertGreaterThanOrEqual(byRegion, 5, "\(topo): the fixture must make the region term decide")
            XCTAssertGreaterThanOrEqual(bySkin, 5, "\(topo): the fixture must make the skin term decide")
            XCTAssertGreaterThan(missRegion, 0.1, "control: a dropped region term must show")
            XCTAssertGreaterThan(missSkin, 0.1, "control: a dropped skin term must show")
        }
    }

    /// The covered pixels' bounding box is the box's projected silhouette (its 8 corners
    /// through the same `CameraProjection` the page publishes): inside it, within 8 px
    /// (measured 5.1 px — a corner in a pore), where either mirror image misses by 20+.
    func testTheLatticeLandsWhereThePartProjects() throws {
        let r = try FlexibleLatticeRenderer(device: try device())
        let size = 512
        let proj = FlexibleLatticeRendererTests.obliqueProjection(size: size)
        r.setInputs(FlexibleLatticeRendererTests.boxInputs(.honeycomb))
        let px = try XCTUnwrap(r.renderOffscreen(width: size, height: size, projection: proj))
        var minX = size, minY = size, maxX = -1, maxY = -1
        for y in 0..<size { for x in 0..<size where px[(y * size + x) * 4 + 3] > 0 {
            minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
        } }
        var cx: [CGFloat] = [], cy: [CGFloat] = []
        for c in 0..<8 {
            let p = SIMD3<Float>(c & 1 == 0 ? 0 : 40, c & 2 == 0 ? 0 : 40, c & 4 == 0 ? 0 : 20)
            let q = try XCTUnwrap(proj.project(p))
            cx.append(q.x); cy.append(q.y)
        }
        let want = (minX: Double(cx.min()!), maxX: Double(cx.max()!), minY: Double(cy.min()!), maxY: Double(cy.max()!))
        let got = (minX: Double(minX), maxX: Double(maxX + 1), minY: Double(minY), maxY: Double(maxY + 1))
        // ★ CONTROLS: the silhouette mirrored top-to-bottom and left-to-right is NOT where
        // the lattice is — so this comparison can see a flipped image.
        let flipY = (minY: Double(size) - want.maxY, maxY: Double(size) - want.minY)
        let flipX = (minX: Double(size) - want.maxX, maxX: Double(size) - want.minX)
        let errFlipY = max(abs(got.minY - flipY.minY), abs(got.maxY - flipY.maxY))
        let errFlipX = max(abs(got.minX - flipX.minX), abs(got.maxX - flipX.maxX))
        let err = max(abs(got.minX - want.minX), abs(got.maxX - want.maxX), abs(got.minY - want.minY), abs(got.maxY - want.maxY))
        print(String(format: "FLEX-ALIGN covered bbox x %.0f–%.0f y %.0f–%.0f; projected x %.1f–%.1f y %.1f–%.1f; "
                     + "max edge error %.1f px; controls: y-flipped %.1f px, x-flipped %.1f px",
                     got.minX, got.maxX, got.minY, got.maxY, want.minX, want.maxX, want.minY, want.maxY, err, errFlipY, errFlipX))
        // Walls need not reach the box's exact corners (a corner can fall in a pore), so the
        // covered box sits INSIDE the projected one, by less than about a millimetre.
        XCTAssertGreaterThanOrEqual(got.minX, want.minX - 1.5); XCTAssertLessThanOrEqual(got.maxX, want.maxX + 1.5)
        XCTAssertGreaterThanOrEqual(got.minY, want.minY - 1.5); XCTAssertLessThanOrEqual(got.maxY, want.maxY + 1.5)
        XCTAssertLessThanOrEqual(err, 8, "the lattice must land on the part's projected silhouette")
        XCTAssertGreaterThan(errFlipY, 15, "control: a vertically flipped picture must fail")
        XCTAssertGreaterThan(errFlipX, 15, "control: a horizontally flipped picture must fail")
    }
}
#endif
