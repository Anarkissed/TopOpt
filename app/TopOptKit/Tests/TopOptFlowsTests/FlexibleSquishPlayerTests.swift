// FlexibleSquishPlayerTests — the squish player (task 2026-09-29-flexible-screens, round 3
// batch B; maintainer, verbatim: "Please add a play button and/or timeline to drag that moves
// the squish in and out").
//   * play loops rest → full → rest on the 2.4 s cosine ease and RESUMES FROM WHERE IT IS;
//     a drag pauses and sets the amount; pause holds; reduced motion does not auto-play.
//     RED CONTROL: restarting from phase 0 jumps the squish;
//   * ONE NUMBER: the renderer's loop sets THE flexScale (k × amount) that the dent's vertices
//     and the lattice's walls both read; it runs continuous frames only while playing and
//     returns the view to on-demand drawing on pause. RED CONTROL: no loop ⇒ nil;
//   * a new dent on the SAME mesh reaches the GPU (MetalMeshView's flex upload keyed on the
//     array). RED CONTROL: the frame did not change before the fix (mutation run);
//   * the hooks in draw(in:) and the flex upload are pinned.
import XCTest
import simd
#if canImport(MetalKit)
import MetalKit
#endif
@testable import TopOptFlows

final class FlexibleSquishPlayerTests: XCTestCase {

    private func loop(at t0: CFTimeInterval = 50) -> (FlexibleSquishLoop, (CFTimeInterval) -> Void) {
        let l = FlexibleSquishLoop()
        var t = t0
        l.clock = { t }
        return (l, { t = $0 })
    }

    func testPlayLoopsRestFullRestAndResumesWhereItIs() {
        let (l, set) = loop()
        l.exaggeration = 5
        l.scrub(to: 0.3)
        XCTAssertFalse(l.playing)
        XCTAssertEqual(l.amount, 0.3, accuracy: 1e-12, "a drag sets the amount directly")
        l.play()
        XCTAssertEqual(l.amount(at: 50), 0.3, accuracy: 1e-9, "play resumes from where it is")
        XCTAssertGreaterThan(l.amount(at: 50.1), 0.3, "…on the rising half")
        // one period: rest → full → rest
        let p0 = FlexibleSquishLoop.risingPhase(0.3)
        let tFull = 50 + (0.5 - p0) * FlexibleSquishLoop.periodS, tRest = tFull + 0.5 * FlexibleSquishLoop.periodS
        XCTAssertEqual(l.amount(at: tFull), 1, accuracy: 1e-9)
        XCTAssertEqual(l.amount(at: tRest), 0, accuracy: 1e-9)
        XCTAssertEqual(l.scale(at: tFull), 5, accuracy: 1e-5, "the renderer's scale is k × amount")
        // pause holds what is shown; a drag while playing pauses
        set(tFull); l.pause()
        XCTAssertFalse(l.playing)
        XCTAssertEqual(l.held, 1, accuracy: 1e-9)
        l.play(); l.scrub(to: 0.6)
        XCTAssertFalse(l.playing, "dragging the timeline pauses")
        XCTAssertEqual(l.amount(at: 999), 0.6, accuracy: 1e-12, "…and holds the dragged amount")
        // ★ RED CONTROL: restarting at phase 0 (not resuming) would jump 0.6 → 0
        XCTAssertEqual(FlexibleSquishLoop.ease(0), 0)
        XCTAssertNotEqual(FlexibleSquishLoop.ease(0), 0.6, "control: a restart jumps the squish")
    }

    func testReducedMotionDoesNotAutoPlay() {
        let (l, _) = loop()
        l.autoPlay(reduceMotion: true)
        XCTAssertFalse(l.playing, "reduced motion: no auto-play")
        XCTAssertEqual(l.amount, 1, "…the full squish, held")
        l.autoPlay(reduceMotion: false)
        XCTAssertTrue(l.playing, "control: without reduced motion a fresh lattice plays")
    }

    func testTheEndsSayRestAndTheFullLoad() {
        XCTAssertEqual(FlexibleSquishLoop.fullLabel(weightsKg: [10]), "10 kg")
        XCTAssertEqual(FlexibleSquishLoop.fullLabel(weightsKg: [10, 10]), "10 kg each")
        XCTAssertEqual(FlexibleSquishLoop.fullLabel(weightsKg: [10, 7.5]), "Full load")
        XCTAssertEqual(FlexibleSquishLoop.fullLabel(weightsKg: []), "Full load")
    }

    #if canImport(MetalKit)
    /// The renderer's side: the loop's scale IS the frame's flexScale (dent + walls), and the
    /// view runs continuous frames only while it plays.
    @MainActor
    func testTheRendererStepsTheLoop() throws {
        let device = try FlexibleLatticeFixtures.device()
        let r = try FlexibleLatticeFixtures.renderer(device: device)
        let view = MTKView(frame: CGRect(x: 0, y: 0, width: 64, height: 64), device: device)
        view.isPaused = true; view.enableSetNeedsDisplay = true
        let (l, _) = loop(at: 10)
        l.exaggeration = 4
        var layer = FlexibleLatticeFixtures.layer(FlexibleLatticeFixtures.boxInputs(.gyroid), token: 1)
        // ★ RED CONTROL: without a loop the renderer keeps the view's own flexScale
        r.applyFlexibleLattice(layer, device: device)
        XCTAssertNil(r.flexibleLoopScale(now: 10), "control: no loop, #354's flexScale stands")
        XCTAssertFalse(r.stepFlexibleLoop(in: view, now: 10))
        layer.loop = l
        XCTAssertTrue(r.applyFlexibleLattice(layer, device: device), "handing the loop over redraws")
        l.scrub(to: 0.25)
        XCTAssertEqual(r.flexibleLoopScale(now: 10) ?? -1, 1, accuracy: 1e-6, "k × amount = 4 × 0.25")
        XCTAssertFalse(r.stepFlexibleLoop(in: view, now: 10), "paused: no continuous frames")
        XCTAssertTrue(view.isPaused)
        l.play()
        XCTAssertTrue(r.stepFlexibleLoop(in: view, now: 10.3))
        XCTAssertFalse(view.isPaused, "playing: continuous frames")
        XCTAssertFalse(view.enableSetNeedsDisplay)
        XCTAssertEqual(r.flexibleLoopScale(now: 10.3) ?? -1, l.scale(at: 10.3), accuracy: 1e-6)
        l.pause()
        XCTAssertFalse(r.stepFlexibleLoop(in: view, now: 10.4))
        XCTAssertTrue(view.isPaused, "a pause returns the view to on-demand drawing (battery)")
        XCTAssertTrue(view.enableSetNeedsDisplay)
        // ★ ITS COST PER FRAME (the frame budget): the step is a clock read and a multiply
        l.play()
        let n = 20_000
        let t0 = CACurrentMediaTime()
        var sink: Float = 0
        for i in 0..<n { _ = r.stepFlexibleLoop(in: view, now: 11 + Double(i) / 60); sink += r.flexibleLoopScale(now: 11) ?? 0 }
        let us = (CACurrentMediaTime() - t0) / Double(n) * 1e6
        print(String(format: "FLEX-LOOP cost per frame: %.2f µs (step + read, this build) — sink %.0f", us, sink))
        XCTAssertLessThan(us, 200, "the renderer's loop step is negligible against a 16.7 ms frame")
        l.pause(); _ = r.stepFlexibleLoop(in: view, now: 20)
        // hidden walls still loop the dent; no upload ⇒ no loop
        layer.hidden = true
        r.applyFlexibleLattice(layer, device: device)
        XCTAssertNotNil(r.flexibleLoopScale(now: 11), "the Lattice view off keeps the squish on the map")
    }

    /// ★ A NEW DENT ON THE SAME MESH REACHES THE GPU (plan: the flex upload was keyed only on the
    /// mesh — the lattice landing with its own depths never replaced the drawn map's dent).
    @MainActor
    func testANewDentOnTheSameMeshIsUploaded() throws {
        let device = try FlexibleLatticeFixtures.device()
        guard let r = MeshRenderer(device: device, sampleCount: 1) else { throw XCTSkip("renderer") }
        let box = FlexibleLatticeFixtures.boxMesh()
        let coord = MetalMeshView.Coordinator()
        coord.renderer = r
        let view = MTKView(frame: CGRect(x: 0, y: 0, width: 128, height: 128), device: device)
        var inputs = LatticePreviewConfettiTests.baseInputs()
        inputs.mesh = box.mesh
        inputs.flexScale = 1
        let n = box.flatCount
        inputs.flexDisplacements = [Float](repeating: 0, count: n * 3)
        coord.apply(inputs, to: view)
        let a = try XCTUnwrap(r.renderOffscreen(size: 128))
        // the same mesh, a new dent: the top face slid 8 mm along X (a visible shear)
        var dent = [Float](repeating: 0, count: n * 3)
        for v in box.topStart..<n { dent[v * 3] = 8 }
        inputs.flexDisplacements = dent
        coord.apply(inputs, to: view)
        let b = try XCTUnwrap(r.renderOffscreen(size: 128))
        let d = FlexibleLatticeFixtures.differing(a, b)
        print("FLEX-UPLOAD same mesh, new dent: \(d.differ) of \(d.of) pixels changed")
        XCTAssertGreaterThan(d.differ, 50, "the second dent must reach the GPU")
        // ★ what the check costs per apply: the SAME array (the stage hands over its cached one)
        // is equal in O(1) — Array == compares storage first; a full hash was 83 ms per apply
        // over 1.2 M floats in Debug (the first version of this hook)
        let big = [Float](repeating: 0.5, count: 1_200_000)
        let held: [Float]? = big
        let h0 = CACurrentMediaTime()
        var same = 0
        for _ in 0..<1000 where big == held! { same += 1 }
        let perCheck = (CACurrentMediaTime() - h0) / 1000 * 1e6
        print(String(format: "FLEX-UPLOAD same-array check over 1.2 M floats: %.2f µs per apply (this build)", perCheck))
        XCTAssertEqual(same, 1000)
        XCTAssertLessThan(perCheck, 100, "an unchanged dent costs nothing per apply")
        // the same dent again uploads nothing new (the frame is unchanged)
        coord.apply(inputs, to: view)
        let c = try XCTUnwrap(r.renderOffscreen(size: 128))
        XCTAssertEqual(FlexibleLatticeFixtures.differing(b, c).differ, 0)
    }
    #endif

    // MARK: the hooks (#354's MetalMeshView)

    func testTheRendererHooksArePinned() throws {
        let mv = try FlexibleSource.code("MetalMeshView.swift")
        let draw = try XCTUnwrap(mv.range(of: "func draw(in view: MTKView) {"))
        let tail = String(mv[draw.upperBound...].prefix(2000))
        let step = try XCTUnwrap(tail.range(of: "let flexLooping = stepFlexibleLoop(in: view)"), "the loop is stepped in draw(in:)")
        let enc = try XCTUnwrap(tail.range(of: "encode(into: rpd"))
        XCTAssertLessThan(step.lowerBound, enc.lowerBound, "…BEFORE the frame is encoded (this frame's flexScale)")
        XCTAssertTrue(tail.contains("if wasAnimating && !isSettling && !isPulsing && !flexLooping {"),
                      "a settle ending must not pause the view under a playing loop")
        XCTAssertTrue(mv.contains("if dirty || !appliedFlex || flex != appliedFlexArray {"), "a new dent on the same mesh re-uploads")
        XCTAssertTrue(mv.contains("appliedFlexArray = flex"))
    }
}
