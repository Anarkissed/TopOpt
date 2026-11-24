// Notes26BarsClipTests — ★ his iPad notes 2026-11-23 (notes26 img 66, and 64/65's "random lattice edges at the corner"): the
// regular lattice "looks like it's ON TOP of the face of the part, not *in* it". Core's bars end ON the part's surface, but the
// bar pass drew round caps half a strut past each end, so every cut strut bulged out of the face while the print file cuts it
// flush. With the solid view's map of the part on the GPU, the bars are clipped to the part: nothing of a bar draws outside it,
// a bar meeting the face ends flat and flush. On a 10 mm cube and its map, through MeshRenderer (never the app).
#if canImport(AppKit) && canImport(MetalKit)
import XCTest
import MetalKit
@testable import TopOptFlows

@MainActor
final class Notes26BarsClipTests: XCTestCase {
    private static let corners: [SIMD3<Float>] = [
        SIMD3(0, 0, 0), SIMD3(1, 0, 0), SIMD3(1, 1, 0), SIMD3(0, 1, 0),
        SIMD3(0, 0, 1), SIMD3(1, 0, 1), SIMD3(1, 1, 1), SIMD3(0, 1, 1)]
    private static let tris: [Int32] = [
        1, 2, 6, 1, 6, 5, 0, 4, 7, 0, 7, 3, 3, 7, 6, 3, 6, 2,
        0, 1, 5, 0, 5, 4, 4, 5, 6, 4, 6, 7, 0, 3, 2, 0, 2, 1]
    static var cube: ViewerMesh { ViewerMesh(vertices: corners.flatMap { [$0.x * 10, $0.y * 10, $0.z * 10] }, indices: tris, faceIDs: []) }

    /// The engine's map of the 10 mm cube (open lattice and inside, both, for every voxel whose centre is in the cube), on a box
    /// 2 mm wider each side, at 0.5 mm.
    static var map: LatticeLayoutSolidGrid {
        let n = 28, voxel: Float = 0.5, origin = SIMD3<Float>(repeating: -1.75)
        var rg = [Int8](repeating: -127, count: 2 * n * n * n)
        for k in 0..<n { for j in 0..<n { for i in 0..<n {
            let c = origin + SIMD3(Float(i), Float(j), Float(k)) * voxel
            if c.x > 0, c.y > 0, c.z > 0, c.x < 10, c.y < 10, c.z < 10 {
                let v = 2 * ((k * n + j) * n + i)
                rg[v] = 127; rg[v + 1] = 127
            }
        } } }
        return LatticeLayoutSolidGrid(token: 7, origin: origin, voxel: voxel, dims: SIMD3(Int32(n), Int32(n), Int32(n)), rg: rg)
    }

    func strut(_ bars: [Float], clip: Bool) throws -> Int {
        guard let device = MTLCreateSystemDefaultDevice(), let r = MeshRenderer(device: device, sampleCount: 1) else {
            throw XCTSkip("no renderer: \(MeshRenderer.lastInitError ?? "?")")
        }
        let walls = LatticeLayoutBarsPass.drawWalls
        defer { LatticeLayoutBarsPass.clipToPart = true; LatticeLayoutBarsPass.drawWalls = walls }
        LatticeLayoutBarsPass.clipToPart = clip
        LatticeLayoutBarsPass.drawWalls = false
        r.setMesh(Self.cube)
        r.camera.setOrientation(azimuth: 0.6, elevation: 0.5)
        r.setBodyAlpha(0)   // the body out of the way: every bit of every bar that draws is counted (the map still clips)
        XCTAssertTrue(r.applyLayoutBars(.init(token: 1, bars: bars, solid: Self.map), device: device))
        let px = try XCTUnwrap(r.renderOffscreen(width: 320, height: 240, clear: MTLClearColor(red: 0.1, green: 0.1, blue: 0.12, alpha: 1),
                                                 stage: false))
        return LatticeLayoutSolidViewTests.strutPixels(px)
    }

    /// ★ A bar draws nothing outside the part; a bar ending on a face ends there; a bar inside is drawn as before. RED CONTROL:
    /// the bars as before (no clip) — the cap bulges past the face, and a bar beyond the face draws.
    func testABarEndingOnAFaceDrawsNothingBeyondIt() throws {
        let beyond: [Float] = [5, 5, 12, 5, 5, 13, 3]         // wholly past the z = 10 face, its round cap too (R 1.5)
        let ending: [Float] = [5, 5, 4, 5, 5, 10, 3]          // ends ON the face, as core's bars do
        let inside: [Float] = [5, 5, 3, 5, 5, 6.5, 3]         // wholly inside
        let (b0, b1) = (try strut(beyond, clip: false), try strut(beyond, clip: true))
        let (e0, e1) = (try strut(ending, clip: false), try strut(ending, clip: true))
        let (i0, i1) = (try strut(inside, clip: false), try strut(inside, clip: true))
        print("BARS CLIP: beyond \(b0) → \(b1), ending \(e0) → \(e1), inside \(i0) → \(i1)")
        XCTAssertGreaterThan(b0, 100, "RED CONTROL: unclipped, a bar past the face draws")
        XCTAssertEqual(b1, 0, "★ nothing of a bar draws outside the part")
        XCTAssertLessThan(Double(e1), 0.95 * Double(e0), "★ a bar ending on the face no longer bulges past it")
        XCTAssertGreaterThan(e1, 100, "and it is still there, up to the face")
        XCTAssertEqual(Double(i1), Double(i0), accuracy: max(3, 0.02 * Double(i0)), "★ inside, as before")
    }

    /// The clip, pinned: the map bound on every path, the inside channel read linear (never past the map's box), a flat cap with
    /// the face's own normal, on only where the solid view's map is on the GPU.
    func testTheClipIsPinned() throws {
        let src = try FlexibleSource.code("LatticeLayoutBarsPass.swift")
        XCTAssertTrue(src.contains("if (any(uvw < 0.0) || any(uvw > 1.0)) { return -1.0; }"))
        XCTAssertTrue(src.contains("return map.sample(sl, uvw).g;"), "the inside channel")
        XCTAssertTrue(src.contains("if (F.mapDims.w > 0.5 && bar_map_inside(ro + rd * t, F, map) <= 0.0) {"))
        XCTAssertTrue(src.contains("n = length(g) > 1e-5 ? -normalize(g) : -rd;"), "★ the flat cap: the face's own normal")
        XCTAssertTrue(src.contains("enc.setFragmentTexture(gridTexture ?? neutralMap, index: 0)"), "bound on every path")
        XCTAssertTrue(src.contains("if Self.clipToPart, let g = grid, gridTexture != nil {"), "on only with the solid view's map")
    }
}
#endif
