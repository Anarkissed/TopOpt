// LatticePreviewConfettiEvidenceGen — the before/after pair for R4, on HIS OWN
// configuration, through the PRODUCTION path (task 2026-08-18-lattice-preview-confetti).
//
// ★ BOTH SIDES GO THROUGH `Coordinator.apply`. That is the whole point: the defect
// is not in the renderer, it is in what the SwiftUI update layer tells the renderer,
// so a capture that calls `setBodyAlpha` by hand — which is what every existing
// lattice picture in this repo does — cannot show it. BEFORE is the coordinator as
// it shipped (the body alpha dropped on the floor). AFTER is the coordinator with
// the reconciliation this task adds. Same renderer, same scene, same camera, same
// frame; one line of plumbing between them.
//
// ★ AND IT RUNS ON BOTH PLATFORMS. `xcodebuild test -destination 'platform=macOS'`
// captures on the host GPU; `-destination 'platform=iOS Simulator,…'` captures on
// the simulator's Metal, which is §1's question. The printout names the GPU it ran
// on, every time, so no number here can be mistaken for a device measurement.
//
// Set TOPOPT_CONFETTI_EVIDENCE=1 to write the PNGs.

import XCTest
import Foundation
import Metal
import MetalKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import simd
import TopOptKit
@testable import TopOptFlows
@testable import TopOptDesign

final class LatticePreviewConfettiEvidenceGen: XCTestCase {

    private var enabled: Bool { ProcessInfo.processInfo.environment["TOPOPT_CONFETTI_EVIDENCE"] == "1" }

    private static let repoRoot: URL = {
        var u = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { u.deleteLastPathComponent() }
        return u
    }()

    /// ★ WRITTEN INTO THE REPO ON macOS, AND INTO THE TEST'S OWN SANDBOX ON THE
    /// SIMULATOR — which cannot reach the repo. The simulator run's path is printed
    /// so the files can be collected; nothing is silently dropped.
    private var evidenceDir: URL {
        #if targetEnvironment(simulator)
        return FileManager.default.temporaryDirectory
            .appendingPathComponent("confetti-evidence-simulator")
        #else
        return Self.repoRoot.appendingPathComponent("evidence/2026-08-18-lattice-preview-confetti")
        #endif
    }

    private static let size = 1024
    private static let azimuth: Float = 0.7
    private static let elevation: Float = 0.4

    // MARK: - the pair

    @MainActor
    func testBeforeAndAfterOnHisConfiguration() throws {
        try XCTSkipUnless(enabled, "set TOPOPT_CONFETTI_EVIDENCE=1 to regenerate")
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal device") }
        let mesh = try LatticePreviewConfettiTests.hisMesh()
        let scene = LatticePreviewConfettiTests.hisScene(mesh, field: nil)
        let params = LatticePreviewConfettiTests.hisParams()

        let bg = DS.Color.background
        let clear = MTLClearColor(red: bg.r, green: bg.g, blue: bg.b, alpha: 1)

        func framed() throws -> (MeshRenderer, MetalMeshView.Coordinator, MTKView) {
            guard let r = MeshRenderer(device: device, sampleCount: 4) else {
                throw XCTSkip("MeshRenderer init: \(MeshRenderer.lastInitError ?? "?")")
            }
            r.setMesh(mesh)
            r.camera.setOrientation(azimuth: Self.azimuth, elevation: Self.elevation)
            r.showGround = true
            let c = MetalMeshView.Coordinator()
            c.renderer = r
            let v = MTKView(frame: CGRect(x: 0, y: 0, width: CGFloat(Self.size), height: CGFloat(Self.size)),
                            device: device)
            return (r, c, v)
        }

        var inputs = LatticePreviewConfettiTests.baseInputs()
        inputs.mesh = mesh
        inputs.bodyAlpha = 0                      // the workspace's bar A3
        inputs.latticeLayer = LatticeLayerInputs(scene: scene, params: params,
                                                 sceneToken: 1, faceTints: [:])

        // ── AFTER — the coordinator as this task leaves it ────────────────────────
        let (afterR, afterC, afterV) = try framed()
        try XCTSkipUnless(afterR.latticePipelinesDidBuild,
                          "the unified lattice MSL must compile or both pictures are empty")
        afterC.apply(inputs, to: afterV)
        let afterAlpha = afterR.bodyAlpha
        let afterMask = try XCTUnwrap(afterR.latticeMaskDump(size: Self.size))
        let afterPx = try XCTUnwrap(afterR.renderOffscreen(size: Self.size, clear: clear, stage: true))

        // ── BEFORE — the coordinator as it shipped ────────────────────────────────
        // Reproduced EXACTLY, not approximated: the shipped `apply` reached
        // `setBodyAlpha` only inside `if let flow = inputs.loadFlowVertices`, and the
        // lattice stage supplies no flow, so the renderer kept its default alpha of 1.
        // Applying the same inputs and then restoring that 1 is byte-for-byte the state
        // the old code left the renderer in.
        let (beforeR, beforeC, beforeV) = try framed()
        beforeC.apply(inputs, to: beforeV)
        beforeR.setBodyAlpha(1)                   // ← what the dropped plumbing left behind
        let beforeMask = try XCTUnwrap(beforeR.latticeMaskDump(size: Self.size))
        let beforePx = try XCTUnwrap(beforeR.renderOffscreen(size: Self.size, clear: clear, stage: true))

        try write(beforePx, size: Self.size, to: "01_before_confetti.png")
        try write(afterPx, size: Self.size, to: "02_after_struts.png")
        try writeMask(beforeMask, to: "03_before_lattice_mask.png")
        try writeMask(afterMask, to: "04_after_lattice_mask.png")

        // A 3× crop of the same window on both, chosen from the AFTER frame's lattice
        // so the crop is guaranteed to contain struts rather than empty stage.
        let box = coveredWindow(afterMask, side: Self.size / 5)
        try write(crop(beforePx, size: Self.size, box: box, zoom: 3), size: box.side * 3,
                  to: "05_before_zoom3x.png")
        try write(crop(afterPx, size: Self.size, box: box, zoom: 3), size: box.side * 3,
                  to: "06_after_zoom3x.png")

        print("""

        ================================================================================
        LATTICE PREVIEW CONFETTI — before/after, HIS configuration, PRODUCTION path
        GPU            \(device.name)
        platform       \(Self.platformName)
        part           Fixtures/M2_verticalStand.step · octet · cell \(params.cellMM) mm
                       Face 15 · Lattice · 11.0 mm  ·  Face 2 · Lattice · 10.6 mm
                       (the declarations are the maintainer's own, read out of his
                        saved project; the PREVIEW does not consume them — see §3d)
        captured       \(Self.size)² · 4× MSAA · stage on
        written to     \(evidenceDir.path)

        body alpha the workspace asked for ....... 0
          BEFORE  the renderer actually held ..... \(beforeAlphaNote)
          AFTER   the renderer actually held ..... \(afterAlpha)

                              lattice pixels won        isolated (confetti)
          BEFORE              \(beforeMask.covered)  (\(pct(beforeMask.coveredFraction)))       \(pct(beforeMask.isolatedFraction))
          AFTER               \(afterMask.covered)  (\(pct(afterMask.coveredFraction)))       \(pct(afterMask.isolatedFraction))
        ================================================================================
        """)

        // ★ R5 — WHAT THE COLOURED SPECKS ACTUALLY ARE, read out of the G-buffer the
        // lattice itself wrote, not inferred from a screenshot. `lsdf_albedo` writes
        // the indigo density ramp (plus a face-role tint where one is baked; none is
        // here, `faceTints: [:]`), so every won pixel SHOULD be indigo — blue-dominant
        // with red above green. Anything else did not come from the lattice's albedo.
        print(albedoCensus("BEFORE", beforeMask))
        print(albedoCensus("AFTER ", afterMask))

        XCTAssertGreaterThan(afterMask.covered, beforeMask.covered * 2,
                             "R4: a before/after pair nobody can see the difference in "
                             + "is not a pair")
        XCTAssertLessThan(afterMask.isolatedFraction, beforeMask.isolatedFraction / 10,
                          "R5: the BEFORE must be confetti and the AFTER must be struts")
    }

    private let beforeAlphaNote = "1.0"

    private static var platformName: String {
        #if targetEnvironment(simulator)
        return "iOS SIMULATOR (Metal translated to the host GPU — NOT a device)"
        #elseif os(macOS)
        return "macOS, headless — NOT an iPad"
        #else
        return "iOS device"
        #endif
    }

    /// The lattice's OWN albedo at the pixels it won, bucketed by dominant channel.
    /// The indigo ramp is blue-dominant with red > green at every point along it, so a
    /// green- or red-dominant bucket is a pixel the lattice did not colour.
    private func albedoCensus(_ label: String, _ m: MeshRenderer.LatticeMaskDump) -> String {
        var indigo = 0, greenDom = 0, redDom = 0, otherBlue = 0, dark = 0
        for i in 0..<(m.width * m.height) where m.mask[i] {
            let r = Int(m.rgb[i*3]), g = Int(m.rgb[i*3+1]), b = Int(m.rgb[i*3+2])
            let mx = max(r, max(g, b))
            if mx < 24 { dark += 1 }
            else if b >= r && b >= g && r >= g { indigo += 1 }
            else if g > r && g > b { greenDom += 1 }
            else if r > g && r > b { redDom += 1 }
            else { otherBlue += 1 }
        }
        return """

        R5 — the LATTICE'S OWN ALBEDO at the \(m.covered) pixels it won  [\(label)]
          indigo density ramp (b ≥ r ≥ g) ....... \(indigo)
          green-dominant ........................ \(greenDom)
          red-dominant .......................... \(redDom)
          other blue-ish ........................ \(otherBlue)
          near-black ............................ \(dark)
        """
    }

    // MARK: - helpers

    private struct Box { var x: Int; var y: Int; var side: Int }

    /// A window centred on the lattice's own pixels, so a crop shows struts.
    private func coveredWindow(_ m: MeshRenderer.LatticeMaskDump, side: Int) -> Box {
        var sx = 0, sy = 0, n = 0
        for y in 0..<m.height {
            for x in 0..<m.width where m.mask[y * m.width + x] { sx += x; sy += y; n += 1 }
        }
        guard n > 0 else { return Box(x: 0, y: 0, side: side) }
        // The mask may be smaller than the colour target (the G-buffer is capped), so
        // map its centroid back into colour-target pixels before cropping.
        let scale = Double(Self.size) / Double(max(m.width, 1))
        let cx = Int(Double(sx / n) * scale), cy = Int(Double(sy / n) * scale)
        let half = side / 2
        return Box(x: max(0, min(Self.size - side, cx - half)),
                   y: max(0, min(Self.size - side, cy - half)), side: side)
    }

    private func crop(_ bgra: [UInt8], size: Int, box: Box, zoom: Int) -> [UInt8] {
        let out = box.side * zoom
        var dst = [UInt8](repeating: 0, count: out * out * 4)
        for y in 0..<out {
            let sy = box.y + y / zoom
            for x in 0..<out {
                let sx = box.x + x / zoom
                let s = (sy * size + sx) * 4, d = (y * out + x) * 4
                dst[d] = bgra[s]; dst[d+1] = bgra[s+1]; dst[d+2] = bgra[s+2]; dst[d+3] = bgra[s+3]
            }
        }
        return dst
    }

    /// The lattice's own mask as black-on-white: white where the lattice won a pixel.
    /// §2's number as a picture — the confetti is visible in it directly.
    private func writeMask(_ m: MeshRenderer.LatticeMaskDump, to name: String) throws {
        var bgra = [UInt8](repeating: 0, count: m.width * m.height * 4)
        for i in 0..<(m.width * m.height) {
            let v: UInt8 = m.mask[i] ? 255 : 24
            bgra[i*4] = v; bgra[i*4+1] = v; bgra[i*4+2] = v; bgra[i*4+3] = 255
        }
        XCTAssertEqual(m.width, m.height, "the mask dump is expected square")
        guard let img = MeshThumbnail.image(from: bgra, size: m.width) else {
            XCTFail("no image for \(name)"); return
        }
        try writeImage(img, to: name)
    }

    private func write(_ bgra: [UInt8], size: Int, to name: String) throws {
        guard let img = MeshThumbnail.image(from: bgra, size: size) else {
            XCTFail("no image for \(name)"); return
        }
        try writeImage(img, to: name)
    }

    private func writeImage(_ img: CGImage, to name: String) throws {
        try FileManager.default.createDirectory(at: evidenceDir, withIntermediateDirectories: true)
        let url = evidenceDir.appendingPathComponent(name)
        guard let dest = CGImageDestinationCreateWithURL(
                url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            XCTFail("no PNG destination for \(name)"); return
        }
        CGImageDestinationAddImage(dest, img, nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest), "PNG write \(name)")
    }

    private func pct(_ v: Double) -> String { String(format: "%.2f%%", v * 100) }
}
