// TapOverselectCaptureTests.swift — before/after evidence for the tap over-selection
// fix (handoff 2026-07-25-tap-overselect). Renders the committed WallMount_ShelfBracket
// STL through the real Metal viewer (MeshRenderer.renderOffscreen), tinting the faces a
// SINGLE tap on one back-column pseudo-face selects:
//
//   BEFORE — the un-fixed FaceTopology.loop curved-face walk (reproduced locally from
//            the public adjacency/isCurved API) unions the whole connected "curved"
//            pseudo-face run: the diagonal strut + load region, ~44% of the model.
//   AFTER  — the fix: a pseudo-face mesh tap selects exactly the tapped face.
//
// GPU + STL-import required; skipped where either is unavailable (matching the other
// device-QA capture tests). Written to docs/handoffs/assets/tap_overselect_*.png.

#if os(macOS)
import XCTest
import Metal
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import simd
@testable import TopOptFlows
import TopOptKit

final class TapOverselectCaptureTests: XCTestCase {

    private static let captureSize = 640
    private static let bg = MTLClearColor(red: 0.05, green: 0.06, blue: 0.09, alpha: 1)
    // A representative pseudo-face that sat inside the over-selecting run — one inner
    // wall of the strut's central void, clearly visible in a 3⁄4 view.
    private static let tappedFace: FaceID = 21

    private static var shelfBracketStl: URL {
        var u = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { u.deleteLastPathComponent() }   // → worktree root
        return u.appendingPathComponent("core/tests/fixtures/mesh/WallMount_ShelfBracket.stl")
    }

    func testCaptureShelfBracketTapBeforeAfter() throws {
        guard let d = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("No Metal device (headless) — this is a device-QA capture")
        }
        let imported: ImportedMesh
        do {
            imported = try TopOptKit.importMesh(path: Self.shelfBracketStl.path)
        } catch {
            throw XCTSkip("STL import unavailable: \(error)")
        }
        let mesh = ViewerMesh(vertices: imported.vertices, indices: imported.indices,
                              faceIDs: imported.faceIDs, pseudoFaces: imported.pseudoFaces)
        guard let renderer = MeshRenderer(device: d) else {
            XCTFail("MeshRenderer init failed: \(MeshRenderer.lastInitError ?? "unknown")"); return
        }
        renderer.setMesh(mesh)
        renderer.camera.frame(mesh.bounds)
        renderer.camera.setOrientation(azimuth: .pi / 4.5, elevation: .pi / 8)

        let amber = SIMD4<Float>(1.0, 0.55, 0.15, 0.85)

        // BEFORE — the old union the curved-face walk produced from the tapped face.
        let before = Self.oldLoopUnion(fromFace: Self.tappedFace, in: mesh)
        XCTAssertGreaterThan(before.count, 1, "the un-fixed walk must union many faces")
        renderer.setHighlights(faceTint: Dictionary(uniqueKeysWithValues: before.map { ($0, amber) }),
                               activeFaces: Set(before))
        guard let beforePx = renderer.renderOffscreen(size: Self.captureSize, clear: Self.bg) else {
            XCTFail("no before render"); return
        }
        writeCapture(beforePx, "tap_overselect_before.png")

        // AFTER — the fix: exactly the tapped face.
        let after = FaceTopology.loop(fromFace: Self.tappedFace, in: mesh)
        XCTAssertEqual(after, [Self.tappedFace], "the fix selects only the tapped pseudo-face")
        renderer.setHighlights(faceTint: [Self.tappedFace: amber], activeFaces: [Self.tappedFace])
        guard let afterPx = renderer.renderOffscreen(size: Self.captureSize, clear: Self.bg) else {
            XCTFail("no after render"); return
        }
        writeCapture(afterPx, "tap_overselect_after.png")
    }

    /// The pre-fix `FaceTopology.loop`: a connected-component walk over edge-adjacent
    /// CURVED faces starting from the tapped face. Reproduced here from the public
    /// adjacency/isCurved API so the BEFORE image is faithful to the shipped-bug
    /// behaviour without resurrecting it in the product code.
    private static func oldLoopUnion(fromFace face: FaceID, in mesh: ViewerMesh) -> [FaceID] {
        guard FaceTopology.isCurved(face, in: mesh) else { return [face] }
        let adj = FaceTopology.adjacency(in: mesh)
        var visited: Set<FaceID> = [face]
        var stack = [face]
        while let f = stack.popLast() {
            for n in adj[f] ?? [] where !visited.contains(n) && FaceTopology.isCurved(n, in: mesh) {
                visited.insert(n); stack.append(n)
            }
        }
        return visited.sorted()
    }

    private func writeCapture(_ bgra: [UInt8], _ name: String) {
        let size = Self.captureSize
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { url.deleteLastPathComponent() }
        let dir = url.appendingPathComponent("docs/handoffs/assets", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let out = dir.appendingPathComponent(name)
        var pixels = bgra
        let cs = CGColorSpaceCreateDeviceRGB()
        let info = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        let image: CGImage? = pixels.withUnsafeMutableBytes { raw in
            guard let ctx = CGContext(data: raw.baseAddress, width: size, height: size,
                                      bitsPerComponent: 8, bytesPerRow: size * 4,
                                      space: cs, bitmapInfo: info) else { return nil }
            return ctx.makeImage()
        }
        guard let image,
              let dest = CGImageDestinationCreateWithURL(out as CFURL, "public.png" as CFString, 1, nil) else {
            XCTFail("could not encode \(name)"); return
        }
        CGImageDestinationAddImage(dest, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest), "could not write \(name)")
        print("TAP-OVERSELECT-CAPTURE wrote \(out.path)")
    }
}
#endif
