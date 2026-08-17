// ShellPixelDigestProbe — ★ R7's REAL PROOF, and the one the rest of this task's
// tests could NOT give (task 2026-08-18-unified-shading).
//
// `UnifiedShadingTests.testFrameWithoutLatticeIsUnchanged` compares this renderer
// against ANOTHER INSTANCE OF THIS RENDERER. That catches "installing a lattice layer
// and removing it leaves state behind"; it cannot catch "the material extraction moved
// the shell's pixels", because both sides would move together.
//
// So: this prints a SHA-256 of the shell's own offscreen frame, with no lattice, at the
// production quality set. Run it on the branch, revert to the merge base, run it again,
// compare the two strings. That is the only comparison that answers R7 for the SHELL.
//
// It is a probe, not an assertion, on purpose — the digest depends on the GPU, so a
// hard-coded constant would fail on any machine but the one that recorded it, and a
// test that fails everywhere is a test nobody reads. The two strings and the revision
// they came from are in the handoff.

import XCTest
import CryptoKit
import Foundation
import Metal
@testable import TopOptFlows
@testable import TopOptDesign

final class ShellPixelDigestProbe: XCTestCase {

    private static let repoRoot: URL = {
        var u = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { u.deleteLastPathComponent() }
        return u
    }()

    func testPrintShellFrameDigest() throws {
        guard ProcessInfo.processInfo.environment["TOPOPT_SHELL_DIGEST_PROBE"] == "1" else {
            throw XCTSkip("set TOPOPT_SHELL_DIGEST_PROBE=1 to print the digest")
        }
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal device") }
        let p = Self.repoRoot.appendingPathComponent(
            "core/tests/fixtures/mesh/WallMount_ShelfBracket.stl")
        let (verts, idx) = MeshExport.parseBinarySTL(try Data(contentsOf: p))
        let mesh = ViewerMesh(vertices: verts, indices: idx, faceIDs: [])
        guard let r = MeshRenderer(device: device, sampleCount: 4) else {
            throw XCTSkip("MeshRenderer init: \(MeshRenderer.lastInitError ?? "?")")
        }
        r.setMesh(mesh)
        r.camera.setOrientation(azimuth: 0.72, elevation: 0.38)
        r.camera.distance *= 0.80
        r.showGround = true
        let bg = DS.Color.background
        let clear = MTLClearColor(red: bg.r, green: bg.g, blue: bg.b, alpha: 1)
        for (label, quality) in [("all", MeshRenderer.Quality.all),
                                 ("none", MeshRenderer.Quality.none)] {
            r.quality = quality
            let px = try XCTUnwrap(r.renderOffscreen(size: 512, clear: clear, stage: true))
            var h = SHA256()
            h.update(data: Data(px))
            print("SHELL FRAME DIGEST  quality=\(label)  "
                  + h.finalize().map { String(format: "%02x", $0) }.joined())
        }
    }
}
