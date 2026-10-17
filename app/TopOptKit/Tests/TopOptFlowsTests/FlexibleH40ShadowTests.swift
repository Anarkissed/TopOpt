// FlexibleH40ShadowTests — round 7, the H39 hotfix (2026-10-17): the contact-shadow hook H40 (the reviewer's ruling 4 of
// 2026-10-17 20:25, approved by the maintainer: "the contact-shadow hook MetalMeshView.swift:4085 (+1 −1,
// `&& !flexibleBodyPrinted`) APPROVED — pin test with red control; other stages' renders pixel-identical"). Written BEFORE
// the code (the red run: round7/batch_h39/h39_red_run.txt). The pin is FlexibleH39HotfixHookTests; this is the frame.
//
// X1's finding: "No contact shadow under the printed view on the device … #354's `latticeOnly = bodyAlpha <= 0.5` reads the
// see-through printed body as lattice-only and, with no octet layer on the Flexible stage, draws no shadow … the solid part
// floats with no shadow in None / Rim / Skin."
//   S1  HIS pad with his live lattice, the main page's default view (X-ray off, finish None: the printed view), drawn by the
//       shipping renderer WITH its stage (the floor and the contact shadow): the part now casts its footprint — the frame
//       differs from today's, and only by DARKER floor pixels. RED CONTROL `controlNoPrintedShadow`: today's frame.
//   S2  the gate is false everywhere else: no Flexible pass (Topology, the Structural / Aesthetic lattice stage, Surface),
//       the pass hidden, the pass in X-ray (not printed) — there the hook is #354's expression, byte for byte. The renders
//       of those stages before / after are the opt-in FlexibleH40OtherStagesDigestProbe (round7/batch_h39/shadow/).
#if canImport(Metal) && canImport(MetalKit)
import XCTest
import Metal
import MetalKit
import simd
import TopOptDesign
@testable import TopOptFlows
@testable import TopOptKit

@MainActor
final class FlexibleH40ShadowTests: XCTestCase {
    typealias F = FlexibleR7M1Fixtures

    static func luminance(_ px: [UInt8], _ i: Int) -> Double {   // BGRA
        0.0722 * Double(px[i]) + 0.7152 * Double(px[i + 1]) + 0.2126 * Double(px[i + 2])
    }

    func testThePrintedViewCastsThePartsContactShadow() async throws {
        let (r, s, m) = try await F.hisPad(self, live: true)
        let p = r.project
        s.didExitSettings()
        s.apply(p, owned: true, pageUp: false)
        try await FlexibleHisProject.waitFor(240, "the lattice") { m.lattice != nil && !m.latticeBuilding && !m.latticeIsStale }
        for _ in 0..<30 { try await Task.sleep(nanoseconds: 10_000_000) }
        s.refresh()
        let layer = try XCTUnwrap(s.layer(p, stage: .lattice, pageUp: false), "the main page's lattice layer")
        XCTAssertTrue(layer.printed, "premise: the printed view (X-ray off, finish None)")
        let alpha = s.bodyAlpha(p, on: .lattice) ?? 1
        XCTAssertLessThanOrEqual(alpha, 0.5, "premise: the see-through printed body (#354 reads ≤ 0.5 as lattice-only)")
        let settle = p.force.settleRotation ?? simd_quatf(from: SIMD3<Float>(0, 0, -1), to: SIMD3<Float>(0, -1, 0))
        let mesh = try XCTUnwrap(s.mesh(p, on: .lattice) ?? p.viewerMesh)
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let mr = try FlexibleRound6EvidenceProbe().renderer(mesh: mesh, tints: s.tints(p, on: .lattice, roles: [:], stress: nil),
                                                             dents: s.dents(p, on: .lattice), scale: s.dentScale(p, on: .lattice),
                                                             bodyAlpha: alpha, settle: settle, cam: FlexibleR7X1EvidenceProbe.img1,
                                                             device: device, items: [], layer: layer)
        mr.quality = .all
        let fx = try XCTUnwrap(mr.flexibleLattice, "the Flexible pass")
        XCTAssertTrue(mr.flexibleLatticeInFrame, "premise: the pass draws this frame")
        XCTAssertTrue(mr.flexibleBodyPrinted, "★ the gate: the printed view")
        let bg = DS.Color.background
        let clear = MTLClearColor(red: bg.r, green: bg.g, blue: bg.b, alpha: 1)
        let n = 512
        let now = try XCTUnwrap(mr.renderOffscreen(size: n, clear: clear, stage: true))
        // ★ RED CONTROL: today's frame — no shadow under the printed part
        fx.controlNoPrintedShadow = true
        XCTAssertFalse(mr.flexibleBodyPrinted)
        let today = try XCTUnwrap(mr.renderOffscreen(size: n, clear: clear, stage: true))
        fx.controlNoPrintedShadow = false
        var differ = 0, darker = 0
        for i in stride(from: 0, to: now.count, by: 4) where now[i] != today[i] || now[i + 1] != today[i + 1] || now[i + 2] != today[i + 2] {
            differ += 1
            if Self.luminance(now, i) < Self.luminance(today, i) { darker += 1 }
        }
        XCTAssertGreaterThan(differ, 300, "★ the printed part casts a contact shadow now (\(differ) px moved; the control is today's frame)")
        XCTAssertGreaterThan(Double(darker), 0.95 * Double(differ), "★ …and only by darker floor pixels — a shadow (\(darker) of \(differ))")
        // the rest of the frame is the same frame (the shadow pass draws nothing else)
        XCTAssertLessThan(differ, n * n / 3, "the shadow is a footprint, not a new picture")
        try write(now, n, "H40_printed_shadow_after_img1.png")
        try write(today, n, "H40_printed_shadow_before_img1.png")
        print("FLEX-H40-S1 printed view: \(differ) px differ from today's frame, \(darker) darker · body alpha \(alpha)")
    }

    func testTheGateIsFalseOffThePrintedView() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let mr = try XCTUnwrap(MeshRenderer(device: device, sampleCount: 4))
        mr.setMesh(try LatticePreviewConfettiTests.hisMesh())
        XCTAssertNil(mr.flexibleLattice, "Topology / Structural / Surface: no Flexible pass")
        XCTAssertFalse(mr.flexibleBodyPrinted, "★ no pass: #354's expression")
        mr.setBodyAlpha(0)
        XCTAssertFalse(mr.flexibleBodyPrinted, "★ a lattice-only body with no pass (the Structural stage): #354's expression")
    }

    func write(_ px: [UInt8], _ n: Int, _ name: String) throws {
        guard let dir = ProcessInfo.processInfo.environment["FLEX_H40_DIR"].map({ URL(fileURLWithPath: $0, isDirectory: true) }) else { return }
        try FlexibleH40OtherStagesDigestProbe.png(px, n, dir.appendingPathComponent(name))
    }
}

/// Opt-in (FLEX_H40_DIGEST_DIR=<dir>): the shipping renderer's frames of the OTHER stages, through the workspace's own
/// `MetalMeshView.Coordinator.apply`, WITH the stage (floor + contact shadow), at the production quality — PNGs and their
/// SHA-256 in `<dir>/digests.txt`. Run once on the commit BEFORE H40 and once AFTER: the two digests files must be identical
/// (the reviewer's "other stages' renders pixel-identical").
@MainActor
final class FlexibleH40OtherStagesDigestProbe: XCTestCase {
    static var dir: URL? { ProcessInfo.processInfo.environment["FLEX_H40_DIGEST_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) } }

    static func png(_ px: [UInt8], _ n: Int, _ url: URL) throws {
        var rgba = px
        for i in stride(from: 0, to: rgba.count, by: 4) { rgba.swapAt(i, i + 2); rgba[i + 3] = 255 }
        let ctx = try XCTUnwrap(CGContext(data: &rgba, width: n, height: n, bitsPerComponent: 8, bytesPerRow: n * 4,
                                          space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        let img = try XCTUnwrap(ctx.makeImage())
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let dest = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(dest, img, nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
    }

    func frame(_ inputs: MeshViewInputs, cam: (Float, Float), device: MTLDevice) throws -> [UInt8] {
        let mr = try XCTUnwrap(MeshRenderer(device: device, sampleCount: 4))
        let coord = MetalMeshView.Coordinator()
        coord.renderer = mr
        let view = MTKView(frame: CGRect(x: 0, y: 0, width: 512, height: 512), device: device)
        mr.setMesh(try XCTUnwrap(inputs.mesh))
        mr.camera.setOrientation(azimuth: cam.0, elevation: cam.1)
        coord.apply(inputs, to: view)
        mr.quality = .all
        let bg = DS.Color.background
        return try XCTUnwrap(mr.renderOffscreen(size: 512, clear: MTLClearColor(red: bg.r, green: bg.g, blue: bg.b, alpha: 1), stage: true))
    }

    func testOtherStagesFramesWithTheirContactShadow() throws {
        guard let dir = Self.dir else { throw XCTSkip("opt-in: FLEX_H40_DIGEST_DIR") }
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let bracket = try LatticePreviewConfettiTests.hisMesh()
        let pad = try XCTUnwrap(try FlexiblePressFixtures.a1Project(3, self).project.viewerMesh)
        var cases: [(String, MeshViewInputs)] = []
        // Topology: the opaque part (his Flexible pad, and the lattice tests' part)
        var topo = LatticePreviewConfettiTests.baseInputs(); topo.mesh = pad; topo.bodyAlpha = 1
        cases.append(("topology_pad", topo))
        var topoB = LatticePreviewConfettiTests.baseInputs(); topoB.mesh = bracket; topoB.bodyAlpha = 1
        cases.append(("topology_part", topoB))
        // the Structural lattice stage: the octet layer, the body hidden (#354's lattice-only shadow: the walls' own)
        var st = LatticePreviewConfettiTests.baseInputs(); st.mesh = bracket; st.bodyAlpha = 0
        st.latticeLayer = LatticeLayerInputs(scene: LatticePreviewConfettiTests.hisScene(bracket, field: nil),
                                             params: LatticePreviewConfettiTests.hisParams(), sceneToken: 1, faceTints: [:])
        cases.append(("structural_lattice_only", st))
        // the lattice stage with the body shown over the layer
        var st2 = st; st2.bodyAlpha = 1
        cases.append(("structural_body_shown", st2))
        // Surface: the part tinted per vertex (the Surface stage's tints)
        var sf = LatticePreviewConfettiTests.baseInputs(); sf.mesh = pad; sf.bodyAlpha = 1
        sf.faceTints = [FaceID(1): SIMD4<Float>(0.2, 0.5, 0.9, 1), FaceID(3): SIMD4<Float>(0.9, 0.5, 0.2, 1)]
        cases.append(("surface_tinted", sf))
        // a see-through body with no layer (no shadow by #354's rule)
        var tr = LatticePreviewConfettiTests.baseInputs(); tr.mesh = pad; tr.bodyAlpha = 0.3
        cases.append(("translucent_no_layer", tr))
        var lines: [String] = []
        for (name, inputs) in cases {
            for (cname, cam) in [("a", (Float(0.72), Float(0.38))), ("b", (Float(-1.9), Float(0.62)))] {
                let px = try frame(inputs, cam: cam, device: device)
                let digest = SHA256Hex.of(px)
                try Self.png(px, 512, dir.appendingPathComponent("\(name)_\(cname).png"))
                lines.append("\(name)_\(cname) \(digest)")
            }
        }
        try (lines.joined(separator: "\n") + "\n").write(to: dir.appendingPathComponent("digests.txt"), atomically: true, encoding: .utf8)
        print("FLEX-H40-DIGESTS\n" + lines.joined(separator: "\n"))
    }
}

import CryptoKit
enum SHA256Hex {
    static func of(_ px: [UInt8]) -> String { SHA256.hash(data: Data(px)).map { String(format: "%02x", $0) }.joined() }
}
#endif
