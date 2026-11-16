// LatticeTurningTests — ★ his second ask of 11-16: "I'm still seeing some lag while tapping on something or dragging around the
// model to view it in different angles when the lattice is turned on (even when it isn't rendering live). What other
// "cheats" are there?" His picks A-E (F, hiding the lattice while turning, ruled out):
//   B. a tap reads one pixel (the face pick: a 1×1 target, the same face as the whole-screen pass; the lattice probe: the frame
//      already on screen) and no longer bakes the lattice's unused tint volume;
//   C. while turning, the lattice's layer is drawn at 576 px on its long side (both engines);
//   D. while turning, no soft shading in the gaps and no edge lines;
//   E. while turning, at most 60 frames a second.
// (A, on the real page, is LatticeTurningHostedTests in LatticePreviewModeTests.swift.) Each with a RED CONTROL.
#if canImport(AppKit) && canImport(MetalKit)
import XCTest
import MetalKit
import simd
@testable import TopOptFlows
@testable import TopOptKit

final class LatticeTurningTests: XCTestCase {

    func testTheTurningRules() {
        XCTAssertEqual(LatticePreviewMode.gbufferCap(turning: false, marched: true, bars: false, restCap: 1152), 1152)
        XCTAssertNil(LatticePreviewMode.gbufferCap(turning: false, marched: false, bars: true, restCap: 1152), "the bars: uncapped at rest")
        XCTAssertEqual(LatticePreviewMode.gbufferCap(turning: true, marched: true, bars: false, restCap: 1152), 576, "★ C: the march")
        XCTAssertEqual(LatticePreviewMode.gbufferCap(turning: true, marched: false, bars: true, restCap: 1152), 576, "★ C: the bars")
        XCTAssertNil(LatticePreviewMode.gbufferCap(turning: true, marched: false, bars: false, restCap: 1152), "no lattice: untouched")
        XCTAssertFalse(LatticePreviewMode.aoDrawn(turning: true, latticeShown: true), "★ D")
        XCTAssertTrue(LatticePreviewMode.aoDrawn(turning: false, latticeShown: true))
        XCTAssertTrue(LatticePreviewMode.aoDrawn(turning: true, latticeShown: false))
        XCTAssertEqual(LatticePreviewMode.turnFrameWait(now: 1.0, lastDraw: 1.0), 1.0 / 60, accuracy: 1e-9, "★ E: 60 a second")
        XCTAssertEqual(LatticePreviewMode.turnFrameWait(now: 1.02, lastDraw: 1.0), 0)
        LatticePreviewMode.controlFullDetailWhileTurning = true
        defer { LatticePreviewMode.controlFullDetailWhileTurning = false }
        XCTAssertEqual(LatticePreviewMode.gbufferCap(turning: true, marched: true, bars: false, restCap: 1152), 1152, "RED CONTROL")
        XCTAssertTrue(LatticePreviewMode.aoDrawn(turning: true, latticeShown: true), "RED CONTROL")
        XCTAssertEqual(LatticePreviewMode.turnFrameWait(now: 1.0, lastDraw: 1.0), 0, "RED CONTROL")
    }

    /// ★ B: the face under one pixel, drawn into a 1×1 target, is the face the whole-screen pass reads there — everywhere on a
    /// grid across the part and the background. RED CONTROL: the same pixel pick aimed 40 px off disagrees.
    @MainActor
    func testOnePixelPickIsTheWholeScreensFace() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal") }
        let mesh = LatticeBandChipsTests.boxMesh()
        guard let mr = MeshRenderer(device: device, sampleCount: 4) else { throw XCTSkip("renderer") }
        mr.setMesh(mesh)
        mr.showGround = false
        var cam = OrbitCamera()
        cam.frame(mesh.bounds)
        mr.camera = cam
        let W = 400, H = 300
        let ids = try XCTUnwrap(mr.renderFaceIDOffscreen(width: W, height: H))
        var same = 0, faces = Set<UInt32>(), off = 0
        for py in stride(from: 3, to: H, by: 15) {
            for px in stride(from: 3, to: W, by: 20) {
                let whole = ids[py * W + px]
                let one = try XCTUnwrap(mr.renderFaceIDPixel(px: px, py: py, width: W, height: H))
                XCTAssertEqual(one, whole, "★ pixel (\(px), \(py)): the 1×1 pick reads the whole screen's face")
                if one == whole { same += 1 }
                faces.insert(whole)
                let shifted = try XCTUnwrap(mr.renderFaceIDPixel(px: min(W - 1, px + 40), py: py, width: W, height: H))
                if shifted != whole { off += 1 }
            }
        }
        print("TURNING one-pixel pick: \(same) points agree; faces seen \(faces.sorted())")
        XCTAssertGreaterThanOrEqual(faces.count, 3, "premise: the grid crosses several faces and the background")
        XCTAssertGreaterThan(off, 10, "RED CONTROL: a pick 40 px off reads other faces")
    }

    /// ★ C + D on a real lattice (his stand): turning draws the lattice's layer at 576 px and leaves out the gap shading; at rest,
    /// 1152 and the shading. ★ B: a probe reads the frame on screen (no second frame), and it reads what a drawn frame reads;
    /// the lattice's tint volume is no longer baked. RED CONTROLS: turning as at rest; a probe that draws; the bake.
    @MainActor
    func testTheRendererDrawsLighterWhileTurningAndTapsReadTheScreen() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal") }
        let mesh = try LatticePreviewConfettiTests.hisMesh()
        let scene = LatticeSDFScene(mesh: mesh, field: nil, latticeID: "octet", regions: [], whenEmpty: .latticeEverything)
        guard let r = MeshRenderer(device: device, sampleCount: 1) else { throw XCTSkip("renderer") }
        try XCTSkipUnless(r.latticePipelinesDidBuild)
        r.setMesh(mesh)
        r.setLatticeScene(scene, token: 1)
        r.latticeParams = LatticePreviewConfettiTests.hisParamsAtACellHisPartCanHold(cellMM: 4.0)
        r.setBodyAlpha(0)   // the lattice alone, as the lattice view shows it (a solid body hides the struts)
        var cam = OrbitCamera()
        cam.frame(mesh.bounds)
        r.camera = cam
        let clear = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        func frame(_ turning: Bool, _ w: Int = 2048, _ h: Int = 1536) {
            r.turning = turning
            _ = r.renderOffscreen(width: w, height: h, clear: clear)
        }
        frame(false)
        XCTAssertTrue(r.lastFrameHadLatticeGBuffer, "premise: the lattice is drawn")
        XCTAssertEqual(r.lastGBufferLongSide, 1152, "at rest: the lattice's layer at 1152")
        XCTAssertTrue(r.lastFrameHadAO, "at rest: the gap shading")
        frame(true)
        XCTAssertEqual(r.lastGBufferLongSide, 576, "★ C: turning, 576")
        XCTAssertFalse(r.lastFrameHadAO, "★ D: turning, no gap shading or edge lines")
        LatticePreviewMode.controlFullDetailWhileTurning = true
        frame(true)
        XCTAssertEqual(r.lastGBufferLongSide, 1152, "RED CONTROL: turning as at rest")
        XCTAssertTrue(r.lastFrameHadAO, "RED CONTROL")
        LatticePreviewMode.controlFullDetailWhileTurning = false

        // ★ B: the probe. A square frame (the renderer's own aspect, 1) at rest, then taps across it.
        frame(false, 900, 900)
        let points = [CGPoint(x: 0.5, y: 0.5), CGPoint(x: 0.45, y: 0.55), CGPoint(x: 0.55, y: 0.4), CGPoint(x: 0.5, y: 0.65)]
        let screen = points.map { r.latticeProbe(atNormalizedPoint: $0, width: 900, height: 900) }
        XCTAssertEqual(r.probesFromScreen, points.count, "★ every tap read the frame on screen")
        XCTAssertEqual(r.probesDrawn, 0, "★ no second frame was drawn")
        XCTAssertTrue(screen.contains { $0 != nil }, "premise: some taps land on struts")
        LatticePreviewMode.controlTapDrawsWholeFrames = true
        defer { LatticePreviewMode.controlTapDrawsWholeFrames = false }
        frame(false, 900, 900)
        let drawn = points.map { r.latticeProbe(atNormalizedPoint: $0, width: 900, height: 900) }
        XCTAssertEqual(r.probesDrawn, points.count, "RED CONTROL: each tap drew a frame")
        for (a, b) in zip(screen, drawn) {
            XCTAssertEqual(a == nil, b == nil, "the same taps land on struts")
            if let a, let b {
                XCTAssertLessThan(simd_distance(a.model, b.model), 1.0, "★ the screen's answer is the drawn frame's (\(a.model) vs \(b.model))")
            }
        }
        // ★ B: the tint volume
        r.setLatticeFaceTints([0: SIMD4<Float>(1, 0, 0, 1)])
        XCTAssertEqual(r.faceTintBakes, 1, "RED CONTROL: baked as before")
        LatticePreviewMode.controlTapDrawsWholeFrames = false
        r.setLatticeFaceTints([1: SIMD4<Float>(0, 1, 0, 1)])
        XCTAssertEqual(r.faceTintBakes, 1, "★ a selection change bakes nothing")
    }
}
#endif
