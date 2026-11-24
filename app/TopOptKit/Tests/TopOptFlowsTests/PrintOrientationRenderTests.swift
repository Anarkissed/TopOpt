// PrintOrientationRenderTests — ★ notes27 P1 (builder H): the turned Results, rendered offscreen with the renderer Results
// draws with — a stand-like part as placed, on a chosen face, and on an edge — each standing on the bed (the ground under its
// lowest point). The PNGs go to the evidence folder (EvidenceOut "orient27"); the assertions hold the part's lowest point on
// the bed and the up pointing up.
#if canImport(MetalKit) && canImport(AppKit)
import XCTest
import MetalKit
import simd
import ImageIO
import UniformTypeIdentifiers
@testable import TopOptFlows

final class PrintOrientationRenderTests: XCTestCase {
    static let size = (w: 640, h: 480)
    static let bg = MTLClearColor(red: 0.93, green: 0.94, blue: 0.96, alpha: 1)

    func testTheStandDrawnAsPlacedOnAFaceAndOnAnEdge() throws {
        guard let d = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal device") }
        guard let renderer = MeshRenderer(device: d) else { XCTFail("MeshRenderer init: \(MeshRenderer.lastInitError ?? "")"); return }
        let stand = PrintOrientationDrawnTests.standMesh()
        let mesh = ViewerMesh(vertices: stand.vertices, indices: stand.indices, faceIDs: [], smoothShaded: true)
        let cases: [(String, SIMD3<Float>)] = [
            ("as_placed", SIMD3(0, 0, 1)),                     // his gravity −Z: the base on the bed
            ("chosen_face_back", SIMD3(0, 1, 0)),             // the back wall (its outward normal −Y) on the bed
            ("edge_base_front", simd_normalize(SIMD3<Float>(0, -1, 1))),   // the edge between the base and the short front face
        ]
        var shots: [String: [UInt8]] = [:]
        for (name, up) in cases {
            renderer.setMesh(mesh)
            renderer.camera.frame(mesh.bounds)
            renderer.camera.setOrientation(azimuth: .pi / 5, elevation: .pi / 9)
            let q = PrintDraw.settle(up: up)
            renderer.beginSettle(to: q, duration: 0)
            renderer.showGround = true
            // the part stands the way it prints: its up is the screen's up, and its lowest point is the bed's height
            let c = mesh.bounds.center
            var lowest = Float.infinity, lowestAlongUp = Float.infinity
            for i in stride(from: 0, to: stand.vertices.count, by: 3) {
                let p = SIMD3(stand.vertices[i], stand.vertices[i + 1], stand.vertices[i + 2])
                lowest = min(lowest, (c + q.act(p - c)).y)
                lowestAlongUp = min(lowestAlongUp, simd_dot(p - c, simd_normalize(up)))
            }
            XCTAssertEqual(lowest, c.y + lowestAlongUp, accuracy: 1e-3, "\(name): ★ the face (or edge) along −up is the lowest, on the bed")
            guard let px = renderer.renderOffscreen(width: Self.size.w, height: Self.size.h, clear: Self.bg, stage: true) else {
                XCTFail("\(name): no render"); continue
            }
            shots[name] = px
            write(px, "orient27_results_\(name).png")
        }
        XCTAssertEqual(shots.count, 3)
        if let a = shots["as_placed"], let b = shots["chosen_face_back"], let e = shots["edge_base_front"] {
            XCTAssertNotEqual(a, b, "★ a chosen face draws the part turned")
            XCTAssertNotEqual(a, e, "★ an edge draws it tilted")
        }
    }

    private func write(_ bgra: [UInt8], _ name: String) {
        let dir = EvidenceOut.dir("orient27")
        let url = dir.appendingPathComponent(name)
        var pixels = bgra
        let info = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        let image: CGImage? = pixels.withUnsafeMutableBytes { raw in
            CGContext(data: raw.baseAddress, width: Self.size.w, height: Self.size.h, bitsPerComponent: 8, bytesPerRow: Self.size.w * 4,
                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: info)?.makeImage()
        }
        guard let image, let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(dest, image, nil)
        CGImageDestinationFinalize(dest)
        print("ORIENT27-RENDER wrote \(url.path)")
    }
}
#endif
