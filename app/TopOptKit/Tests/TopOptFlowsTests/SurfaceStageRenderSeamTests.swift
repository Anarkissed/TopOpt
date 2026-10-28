#if canImport(Metal)
import XCTest
import Metal
import CoreGraphics
import ImageIO
import TopOptKit
@testable import TopOptFlows

/// ★★ THE TEST-ONLY OFFSCREEN RENDER SEAM FOR THE SURFACE STAGE (the Regions task, approved
/// 2026-10-08). The Surface stage's look is built from pure inputs — `SurfaceTint.buffer` (with
/// `SurfaceTint.unionLighting` for a selected union of pieces), the shader's half-space chains, and
/// `SurfaceCutLines.committed` — that the view hands `MeshRenderer` (`MetalMeshView.apply`). This
/// renders the SAME inputs through the SAME renderer, offscreen, with no view, so what the stage
/// draws is measured in pixels and kept as evidence. No production code exists for it.
@MainActor
final class SurfaceStageRenderSeamTests: XCTestCase {

    private static let size = 480
    private static let bg = MTLClearColor(red: 0.05, green: 0.06, blue: 0.09, alpha: 1)

    /// The render, from the stage's own inputs. `chains` are the shader's pick groups.
    static func render(_ p: ProjectModel, tints: [Float], chains: [[SIMD4<Float>]],
                       device: MTLDevice) -> [UInt8]? {
        guard let mesh = p.viewerMesh, let r = MeshRenderer(device: device, sampleCount: 4) else { return nil }
        r.setMesh(mesh)
        r.camera.frame(mesh.bounds)
        r.camera.setOrientation(azimuth: .pi / 4.5, elevation: .pi / 2.4)
        r.setVertexTints(tints)
        r.setCutPlane(.zero, selected: SurfaceTint.selected, sibling: SurfaceTint.sibling,
                      enabled: false, pickGroups: chains)
        r.setWireframe(SurfaceCutLines.committed(regions: p.faceRegions, in: mesh),
                       rgba: SIMD4<Float>(0.14, 0.15, 0.17, 1.0))
        return r.renderOffscreen(size: size, clear: bg)
    }

    /// The selected-blue pixels: their count and their mean x (BGRA). The selected tint is a DEEP
    /// blue (red under 40); the selectable wash is a pale blue (red 60–100, measured on these
    /// renders) and is not counted.
    static func selectedPixels(_ px: [UInt8]) -> (count: Int, meanX: Double) {
        var n = 0, sx = 0.0
        for y in 0..<size { for x in 0..<size {
            let i = (y * size + x) * 4
            let b = Int(px[i]), g = Int(px[i + 1]), r = Int(px[i + 2])
            if r < 40, b > 90, b > g + 40 { n += 1; sx += Double(x) }
        }}
        return (n, n > 0 ? sx / Double(n) : -1)
    }

    /// Written only with SURFACE_SEAM_WRITE=1, so an ordinary run never rewrites committed evidence.
    static func writePNG(_ bgra: [UInt8], _ name: String) {
        guard ProcessInfo.processInfo.environment["SURFACE_SEAM_WRITE"] == "1" else { return }
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { url.deleteLastPathComponent() }
        let dir = url.appendingPathComponent("docs/handoffs/evidence/2026-10-08-regions-task", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var pixels = bgra
        let info = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        let image: CGImage? = pixels.withUnsafeMutableBytes { raw in
            CGContext(data: raw.baseAddress, width: size, height: size, bitsPerComponent: 8, bytesPerRow: size * 4,
                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: info)?.makeImage()
        }
        guard let image, let dest = CGImageDestinationCreateWithURL(
            dir.appendingPathComponent(name) as CFURL, "public.png" as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(dest, image, nil)
        _ = CGImageDestinationFinalize(dest)
    }

    private func project() -> ProjectModel {
        var v: [Float] = []
        func V(_ x: Float, _ y: Float, _ z: Float) { v += [x, y, z] }
        V(0, 0, 0); V(10, 0, 0); V(10, 10, 0); V(0, 10, 0)
        V(0, 0, 5); V(10, 0, 5); V(10, 10, 5); V(0, 10, 5)
        V(0, 0, 9); V(10, 0, 9); V(10, 10, 9); V(0, 10, 9)
        let mesh = ViewerMesh(vertices: v,
                              indices: [0, 1, 2, 0, 2, 3, 4, 5, 6, 4, 6, 7, 8, 9, 10, 8, 10, 11],
                              faceIDs: [0, 0, 1, 1, 2, 2],
                              faceGeometry: (0..<3).map { _ in StepFaceGeometry(kind: .plane, planeNormal: SIMD3(0, 0, 1)) })
        let p = ProjectModel(id: UUID(), name: "S", material: "PLA", process: .fdm, importedFile: nil, importedMesh: nil)
        p.viewerMesh = mesh
        p.selection.addGroup()
        p.selection.pickFaces([0, 1, 2])
        return p
    }

    /// ★ A pattern cell of a union lights ITS SHARE — one side of the top face — and the other cell
    /// the other side; lit the old way (a union whole) both read as the whole face (the RED arm).
    func testAUnionCellLightsItsShareNotTheWholeUnion() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal") }
        let p = project()
        let mesh = try XCTUnwrap(p.viewerMesh)
        let a = try XCTUnwrap(p.surfaceEnsureRegion(for: 1)), b = try XCTUnwrap(p.surfaceEnsureRegion(for: 2))
        var su = SurfaceUnion(); su.toggle(a); su.toggle(b)
        let u = try XCTUnwrap(p.commitSurfaceUnion(su))
        let cells = p.commitSurfacePattern(face: 2, columns: 2, rows: 1, piece: u)
        XCTAssertEqual(cells.count, 2)
        func stage(_ selected: RegionID, perPiece: Bool) throws -> [UInt8] {
            let groups = Set(0..<Int32(mesh.faceGeometry.count))
            if perPiece, let ul = SurfaceTint.unionLighting(selected, regions: p.faceRegions, mesh: mesh) {
                let t = SurfaceTint.buffer(mesh: mesh, groupedFaces: groups, regions: p.faceRegions, selected: nil,
                                           picked: ul.picked, fragmentTested: ul.fragmentTested)
                return try XCTUnwrap(Self.render(p, tints: t, chains: ul.chains, device: device))
            }
            let t = SurfaceTint.buffer(mesh: mesh, groupedFaces: groups, regions: p.faceRegions, selected: selected)
            return try XCTUnwrap(Self.render(p, tints: t, chains: [], device: device))
        }
        let c0 = try stage(cells[0], perPiece: true), c1 = try stage(cells[1], perPiece: true)
        let old0 = try stage(cells[0], perPiece: false)
        Self.writePNG(c0, "union_cell_0_lit.png"); Self.writePNG(c1, "union_cell_1_lit.png")
        Self.writePNG(old0, "union_cell_0_lit_WHOLE_before.png")
        let s0 = Self.selectedPixels(c0), s1 = Self.selectedPixels(c1), w = Self.selectedPixels(old0)
        print("SEAM union cell 0: \(s0) | cell 1: \(s1) | lit whole (before): \(w)")
        XCTAssertGreaterThan(w.count, 1000, "positive control: the whole-face lighting lights the face")
        XCTAssertGreaterThan(s0.count, w.count / 4, "★ cell 0 lights")
        XCTAssertLessThan(s0.count, w.count * 3 / 4, "★ …only its share, not the whole union")
        XCTAssertLessThan(s1.count, w.count * 3 / 4)
        XCTAssertGreaterThan(abs(s0.meanX - s1.meanX), Double(Self.size) / 12, "★ the two cells light different sides")
    }
}
#endif
