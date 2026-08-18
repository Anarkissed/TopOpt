// LatticeSeparationEvidenceGen.swift — ★ R6: THE SAMPLE IS VISIBLE ON ENTRY,
// SHOWN RATHER THAN CLAIMED (task 2026-08-14-lattice-separation §7).
//
// This renders the wizard's OWN Stage-A mesh through the app's OWN Metal pipeline
// — `MeshRenderer` + the same `viewer_fragment` shader whose `discard_fragment()`
// is what blanked the page — twice:
//
//   BEFORE  `setReveal(0)`, which is what `LatticeSetupWizard` passed on entry
//           because it read the wipe's progress whenever the density mode was
//           Auto, and §4b had just made Auto the default.
//   AFTER   `setReveal(1)`, which is what `LatticeWizardReveal.value` returns
//           unless a wipe is actually running.
//
// It is not a mock of the defect: the discard rule, the mesh, the camera framing
// and the clear colour are all the shipping ones. The LIT-PIXEL COUNT is asserted,
// so this file is a test as well as a capture — a "screenshot" nobody looks at is
// not evidence.

import XCTest
import CoreGraphics
import ImageIO
import Metal
import UniformTypeIdentifiers
import simd
@testable import TopOptFlows
@testable import TopOptDesign

@MainActor
final class LatticeSeparationEvidenceGen: XCTestCase {

    private var evidenceDir: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // TopOptFlowsTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // TopOptKit
            .deletingLastPathComponent()   // app
            .deletingLastPathComponent()   // repo root
            .appendingPathComponent("evidence/2026-08-14-lattice-separation",
                                    isDirectory: true)
    }

    /// Lit pixels = anything that is not the stage background. With every fragment
    /// discarded the frame is background and nothing else, which is exactly what
    /// the maintainer saw beside "1 ms · 544 tris".
    private func litPixels(_ bgra: [UInt8], size: Int) -> Int {
        let bg = DS.Color.background
        let b = UInt8(max(0, min(255, bg.b * 255))), g = UInt8(max(0, min(255, bg.g * 255)))
        let r = UInt8(max(0, min(255, bg.r * 255)))
        var lit = 0
        for i in stride(from: 0, to: size * size * 4, by: 4) {
            let db = Int(bgra[i]) - Int(b), dg = Int(bgra[i + 1]) - Int(g)
            let dr = Int(bgra[i + 2]) - Int(r)
            if abs(db) + abs(dg) + abs(dr) > 12 { lit += 1 }
        }
        return lit
    }

    private func write(_ bgra: [UInt8], size: Int, to name: String) throws {
        guard let image = MeshThumbnail.image(from: bgra, size: size) else { return }
        try FileManager.default.createDirectory(at: evidenceDir,
                                                withIntermediateDirectories: true)
        let url = evidenceDir.appendingPathComponent(name)
        guard let dest = CGImageDestinationCreateWithURL(
            url as CFURL, UTType.png.identifier as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(dest, image, nil)
        CGImageDestinationFinalize(dest)
        print("SEPARATION-EVIDENCE wrote \(url.path)")
    }

    /// ★ §7 / R6 — the before and the after, through the real shader.
    func testTheSampleIsVisibleOnEntryAndTheOldRevealBlankedIt() throws {
        // ★ 1× SAMPLED ON PURPOSE (task 2026-08-15-render-quality added 4× MSAA as the
        // renderer's default). The claim this file makes is about the DISCARD RULE —
        // `reveal = 0` threw away every fragment of a mesh that had been built and
        // uploaded — and it is asserted as EXACTLY ZERO lit pixels, which is the right
        // strength for it. Under 4× MSAA that assertion started reporting 5 lit pixels
        // out of 230,400, and the cause is not the reveal: the shader discards on
        // `t > reveal.x`, so at reveal 0 the zero-height sliver of vertices at exactly
        // t == 0 survives, and multisampling is simply the first thing whose sample
        // points ever landed on it. Weakening `== 0` to `< 10` would have hidden a
        // property of the reveal behind a property of the anti-aliasing; pinning the
        // sampling this test was written under keeps the assertion at full strength and
        // keeps it measuring the thing it names.
        guard let device = MTLCreateSystemDefaultDevice(),
              let renderer = MeshRenderer(device: device, sampleCount: 1) else {
            throw XCTSkip("no Metal device")
        }
        // The wizard's own entry state: Stage A, one cell, the project defaults.
        let model = LatticeWizardModel(settings: LatticeSettings())
        XCTAssertEqual(model.stage, .cell)
        XCTAssertEqual(model.densityMode, .sim,
                       "§4b: Auto is the default — the condition that armed the bug")
        let mesh = model.stageMesh()
        XCTAssertFalse(mesh.isEmpty)

        renderer.setMesh(mesh)      // frames the camera to the object (§7b)
        let bg = DS.Color.background
        let clear = MTLClearColor(red: bg.r, green: bg.g, blue: bg.b, alpha: 1)
        let size = 480

        // BEFORE — what shipped: `reveal = wipe = 0` on entry.
        renderer.setReveal(0)
        let before = try XCTUnwrap(renderer.renderOffscreen(size: size, clear: clear))
        let beforeLit = litPixels(before, size: size)
        try write(before, size: size, to: "r6_sample_before_reveal0.png")

        // AFTER — `LatticeWizardReveal().value`, which is 1 unless a wipe runs.
        renderer.setReveal(Float(LatticeWizardReveal().value))
        let after = try XCTUnwrap(renderer.renderOffscreen(size: size, clear: clear))
        let afterLit = litPixels(after, size: size)
        try write(after, size: size, to: "r6_sample_after.png")

        print("""
        R6 — THE SAMPLE ON ENTRY, rendered through the shipping shader
          mesh              \(mesh.indices.count / 3) triangles — the figure the \
        page's own readout prints beside the empty frame
          (his screenshot read 544, at his topology and cell; the mechanism does \
        not depend on the count)
          BEFORE reveal=0   \(beforeLit) lit pixels of \(size * size)
          AFTER  reveal=1   \(afterLit) lit pixels of \(size * size)
        """)

        XCTAssertEqual(beforeLit, 0,
                       "§7: the shipped reveal discarded EVERY fragment — an empty "
                       + "viewport over a mesh that was built and uploaded")
        XCTAssertGreaterThan(afterLit, size * size / 100,
                             "§7/R6: and the sample is on screen on entry")
    }
}
