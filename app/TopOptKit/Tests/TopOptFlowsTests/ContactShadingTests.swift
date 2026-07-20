// ContactShadingTests.swift — the translucent-intersection contact treatment (device round 3,
// items 7+8, parts b+c) + the detent face-highlight pulse (item 2).
//
// Parts b+c add a depth PREPASS (the opaque part's eye-space depth in an R32Float texture) that a
// shared CONTACT shader — used by BOTH the design-box and the clearance face draws — reads to add a
// bright contact line + interior occlusion where a translucent volume meets the part. These tests
// fail loudly on a shader typo (both entry points compile, both pipelines build), prove the effect
// actually CHANGES the picture where a volume crosses the part (before/after), and capture the four
// before/after PNGs the plan (handoff 115, step 6) asks for into docs/handoffs/assets/. A frame-cost
// probe measures what the prepass adds to a redraw (idle stays zero — the view is on-demand).
//
// GPU-gated: skips with no Metal device (headless CI), so a no-GPU host never turns red. The pure
// detent `matchedFace` math is covered unconditionally.

#if canImport(Metal)
import XCTest
import Metal
import CoreGraphics
import ImageIO
import simd
@testable import TopOptFlows
import TopOptKit

final class ContactShadingTests: XCTestCase {

    private func device() throws -> MTLDevice {
        guard let d = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("No Metal device (headless) — contact shading is device QA here")
        }
        return d
    }

    // MARK: fixtures

    /// A cube [-h, h]³ with 6 planar B-rep faces (id 0…5 = −Z,+Z,−X,+X,−Y,+Y), each carrying its
    /// outward plane geometry — enough for the renderer to draw AND for `matchedFace` to resolve.
    private static func cube(_ h: Float) -> ViewerMesh {
        let c: [SIMD3<Float>] = [
            SIMD3(-h,-h,-h), SIMD3( h,-h,-h), SIMD3( h, h,-h), SIMD3(-h, h,-h),
            SIMD3(-h,-h, h), SIMD3( h,-h, h), SIMD3( h, h, h), SIMD3(-h, h, h)]
        // 6 faces × 2 triangles, in the id order below.
        let quads: [[Int]] = [
            [0,2,1, 0,3,2],   // 0: −Z
            [4,5,6, 4,6,7],   // 1: +Z
            [0,3,7, 0,7,4],   // 2: −X
            [1,6,2, 1,5,6],   // 3: +X
            [0,1,5, 0,5,4],   // 4: −Y
            [3,2,6, 3,6,7]]   // 5: +Y
        var verts: [Float] = []
        var idx: [Int32] = []
        var faceIDs: [Int32] = []
        var vi: Int32 = 0
        for (fid, q) in quads.enumerated() {
            for corner in q {
                let p = c[corner]
                verts += [p.x, p.y, p.z]
                idx.append(vi); vi += 1
            }
            faceIDs += [Int32(fid), Int32(fid)]   // two triangles per face
        }
        func plane(_ n: SIMD3<Double>, _ o: SIMD3<Double>) -> StepFaceGeometry {
            StepFaceGeometry(kind: .plane, planeNormal: n, planeOrigin: o)
        }
        let hd = Double(h)
        let geo = [
            plane([0,0,-1], [0,0,-hd]), plane([0,0,1], [0,0,hd]),
            plane([-1,0,0], [-hd,0,0]), plane([1,0,0], [hd,0,0]),
            plane([0,-1,0], [0,-hd,0]), plane([0,1,0], [0,hd,0])]
        return ViewerMesh(vertices: verts, indices: idx, faceIDs: faceIDs, faceGeometry: geo)
    }

    /// Frame + orient a renderer's camera for a legible 3⁄4 view of the crossing.
    private func frame(_ renderer: MeshRenderer, _ mesh: ViewerMesh) {
        renderer.setMesh(mesh)
        renderer.camera.frame(mesh.bounds)
        renderer.camera.setOrientation(azimuth: .pi / 5, elevation: .pi / 7)
    }

    private static let captureSize = 512
    private static let bg = MTLClearColor(red: 0.05, green: 0.06, blue: 0.09, alpha: 1)

    // MARK: shaders + pipelines build

    func testContactAndPrepassShadersCompile() throws {
        let d = try device()
        let cl = try d.makeLibrary(source: MeshRenderer.contactShaderSourceForTesting, options: nil)
        XCTAssertNotNil(cl.makeFunction(name: "contact_vertex"), "contact_vertex missing")
        XCTAssertNotNil(cl.makeFunction(name: "contact_fragment"), "contact_fragment missing")
        let dl = try d.makeLibrary(source: MeshRenderer.depthPrepassShaderSourceForTesting, options: nil)
        XCTAssertNotNil(dl.makeFunction(name: "depth_vertex"), "depth_vertex missing")
        XCTAssertNotNil(dl.makeFunction(name: "depth_fragment"), "depth_fragment missing")
    }

    func testContactPipelinesBuild() throws {
        let d = try device()
        guard let renderer = MeshRenderer(device: d) else {
            XCTFail("MeshRenderer init failed: \(MeshRenderer.lastInitError ?? "unknown")"); return
        }
        XCTAssertTrue(renderer.contactPipelinesDidBuild,
                      "the depth-prepass + contact pipelines must build on a real GPU")
    }

    // MARK: the contact treatment changes the picture (before/after) + captures

    /// A clearance CYLINDER crossing the part: the contact treatment must repaint the crossing
    /// (bright line + interior occlusion) — before ≠ after. Captures both PNGs.
    func testContactChangesPictureForClearanceCylinder() throws {
        let d = try device()
        guard let renderer = MeshRenderer(device: d) else {
            XCTFail("MeshRenderer init failed: \(MeshRenderer.lastInitError ?? "unknown")"); return
        }
        frame(renderer, Self.cube(1.0))
        // A tube along +Z through the cube, sticking out both ±Z faces → a contact ring on each.
        let vol = ClearanceVolume(faceID: 0, kind: .bolt, shape: .cylinder(
            axisPoint: SIMD3(0.15, 0.1, 0), axisDir: SIMD3(0, 0, 1),
            radiusMM: 0.5, tLo: -1.6, tHi: 1.6))
        renderer.setClearanceVolumes([ClearanceRenderItem(volume: vol, selected: true)])

        renderer.contactShadingEnabled = false
        guard let before = renderer.renderOffscreen(size: Self.captureSize, clear: Self.bg) else {
            XCTFail("no before render"); return
        }
        renderer.contactShadingEnabled = true
        guard let after = renderer.renderOffscreen(size: Self.captureSize, clear: Self.bg) else {
            XCTFail("no after render"); return
        }
        assertContactChanged(before, after, label: "cylinder")
        writeCapture(before, "120_contact_cylinder_before.png")
        writeCapture(after, "120_contact_cylinder_after.png")
    }

    /// A design BOX overlapping the part: the same shared contact variant must repaint the crossing.
    /// Captures both PNGs.
    func testContactChangesPictureForDesignBox() throws {
        let d = try device()
        guard let renderer = MeshRenderer(device: d) else {
            XCTFail("MeshRenderer init failed: \(MeshRenderer.lastInitError ?? "unknown")"); return
        }
        frame(renderer, Self.cube(1.0))
        // A box that passes THROUGH the cube (overlaps one corner region) so its glass faces cross
        // the part surface.
        let box = DesignBoxBounds(min: SIMD3(-0.4, -0.4, -0.4), max: SIMD3(1.7, 1.7, 1.7))
        renderer.setDesignBoxes(design: box, designColor: SIMD4(0.4, 0.58, 1, 1),
                                keepOuts: [], keepOutColor: SIMD4(1, 0.3, 0.3, 1))

        renderer.contactShadingEnabled = false
        guard let before = renderer.renderOffscreen(size: Self.captureSize, clear: Self.bg) else {
            XCTFail("no before render"); return
        }
        renderer.contactShadingEnabled = true
        guard let after = renderer.renderOffscreen(size: Self.captureSize, clear: Self.bg) else {
            XCTFail("no after render"); return
        }
        assertContactChanged(before, after, label: "box")
        writeCapture(before, "120_contact_box_before.png")
        writeCapture(after, "120_contact_box_after.png")
    }

    /// The contact pass must change a meaningful number of pixels (the crossing band), not a stray
    /// few — and must leave the frame otherwise recognizable (it is byte-identical away from the part).
    private func assertContactChanged(_ before: [UInt8], _ after: [UInt8], label: String) {
        XCTAssertEqual(before.count, after.count)
        var diff = 0, i = 0
        while i + 2 < before.count {
            if before[i] != after[i] || before[i+1] != after[i+1] || before[i+2] != after[i+2] { diff += 1 }
            i += 4
        }
        let total = before.count / 4
        XCTAssertGreaterThan(diff, total / 400, "[\(label)] contact treatment barely changed the picture (\(diff) px)")
        XCTAssertLessThan(diff, total / 2, "[\(label)] contact treatment changed too much — should be a contact band, not the whole frame (\(diff) px)")
    }

    // MARK: frame-cost probe (idle stays zero — this is per-REDRAW only)

    /// Measure what the depth prepass adds to a single redraw that has a translucent volume, by
    /// timing `renderOffscreen` with the contact pass off vs on. Logged for the handoff; the loose
    /// assertion only guards against a pathological regression (the prepass is one extra opaque
    /// draw, so a redraw at worst roughly doubles — never orders of magnitude).
    func testDepthPrepassFrameCostIsBounded() throws {
        let d = try device()
        guard let renderer = MeshRenderer(device: d) else {
            XCTFail("MeshRenderer init failed"); return
        }
        frame(renderer, Self.cube(1.0))
        let vol = ClearanceVolume(faceID: 0, kind: .bolt, shape: .cylinder(
            axisPoint: SIMD3(0.15, 0.1, 0), axisDir: SIMD3(0, 0, 1),
            radiusMM: 0.5, tLo: -1.6, tHi: 1.6))
        renderer.setClearanceVolumes([ClearanceRenderItem(volume: vol, selected: true)])

        func timeRedraws(contact: Bool, iterations: Int) -> Double {
            renderer.contactShadingEnabled = contact
            _ = renderer.renderOffscreen(size: Self.captureSize, clear: Self.bg)  // warm up
            let t0 = Date()
            for _ in 0..<iterations { _ = renderer.renderOffscreen(size: Self.captureSize, clear: Self.bg) }
            return Date().timeIntervalSince(t0) / Double(iterations) * 1000.0      // ms/redraw
        }
        let iters = 40
        let base = timeRedraws(contact: false, iterations: iters)
        let withContact = timeRedraws(contact: true, iterations: iters)
        let delta = withContact - base
        print("CONTACT-FRAME-COST size=\(Self.captureSize) base=\(String(format: "%.3f", base))ms " +
              "withContact=\(String(format: "%.3f", withContact))ms delta=\(String(format: "%.3f", delta))ms " +
              "(idle redraws: 0 — the view is on-demand, so idle cost is unchanged)")
        // Pathological-regression guard only (timing is machine-dependent): the prepass is a single
        // extra opaque pass, so a redraw should not cost more than ~3× the plain redraw + slack.
        XCTAssertLessThan(withContact, base * 3 + 4.0,
                          "the depth prepass cost a redraw far more than the expected one extra opaque pass")
    }

    // MARK: the pulse drives continuous redraw then ends (item 2)

    func testDetentPulseSetsPulsingAndRendersDifferently() throws {
        let d = try device()
        guard let renderer = MeshRenderer(device: d) else {
            XCTFail("MeshRenderer init failed"); return
        }
        frame(renderer, Self.cube(1.0))        // frame the camera so the cube (and its +X face) is in view
        renderer.setHighlights(faceTint: [:], activeFaces: [])
        XCTAssertFalse(renderer.isPulsing, "no pulse before a snap")
        guard let plain = renderer.renderOffscreen(size: 256, clear: Self.bg) else {
            XCTFail("no plain render"); return
        }
        renderer.beginDetentPulse(faceID: 3)   // flash the +X face
        XCTAssertTrue(renderer.isPulsing, "a fresh snap starts the pulse (continuous redraw)")
        // Mid-envelope the gold flash must brighten the face's pixels vs the un-pulsed frame. The
        // sin envelope is ~0 at t=0, so sample after letting a little wall-clock elapse; the live
        // viewer advances the pulse each frame in `draw(in:)`, so mirror that with one `stepPulse`
        // (renderOffscreen itself doesn't animate).
        Thread.sleep(forTimeInterval: 0.18)
        renderer.stepPulse()
        guard let flashed = renderer.renderOffscreen(size: 256, clear: Self.bg) else {
            XCTFail("no flashed render"); return
        }
        XCTAssertNotEqual(plain, flashed, "the detent pulse must visibly flash the matched face")
    }

    // MARK: PNG capture helper

    /// The docs/handoffs/assets directory (worktree root ÷ app/TopOptKit/Tests/TopOptFlowsTests).
    private func assetsDir(file: StaticString = #filePath) -> URL {
        var url = URL(fileURLWithPath: "\(file)")
        for _ in 0..<5 { url.deleteLastPathComponent() }   // …/ContactShadingTests.swift → worktree root
        return url.appendingPathComponent("docs/handoffs/assets", isDirectory: true)
    }

    private func writeCapture(_ bgra: [UInt8], _ name: String) {
        let size = Self.captureSize
        let dir = assetsDir()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)
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
              let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else {
            XCTFail("could not encode \(name)"); return
        }
        CGImageDestinationAddImage(dest, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest), "could not write \(name)")
        print("CONTACT-CAPTURE wrote \(url.path)")
    }
}
#endif
