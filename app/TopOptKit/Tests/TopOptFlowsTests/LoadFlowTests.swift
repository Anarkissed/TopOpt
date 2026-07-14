// Headless tests for the redesigned "alive" load-path flow (handoff 070 → Metal):
// the mode-agnostic curve source, the load→stress-point streamline, the comet-arrow
// frame math (travel, undulation, clean head, reduced-motion static), the tube
// extrusion layout, and the moving-epicenter heat blend. The Metal tube draw + the
// "alive" feel are device QA (the M7 /app/ standard); this pins the numerics.

import XCTest
import simd
@testable import TopOptFlows
@testable import TopOptKit
#if canImport(MetalKit)
import MetalKit
#endif

final class LoadFlowTests: XCTestCase {

    // MARK: helpers

    /// A uniform principal-stress field: every glyph carries `dir`, spread over a grid
    /// so `nearestDirection` always resolves to it.
    private func uniformGlyphs(dir: SIMD3<Float>, extent: Float = 20, step: Float = 2) -> LoadPath {
        var gs: [LoadPathGlyph] = []
        var x: Float = 0
        while x <= extent {
            var y: Float = -extent
            while y <= extent {
                gs.append(LoadPathGlyph(position: SIMD3<Float>(x, y, 0),
                                        direction: simd_normalize(dir),
                                        stressMPa: 5, principalStrain: 1e-3))
                y += step
            }
            x += step
        }
        return LoadPath(glyphs: gs, segmentLength: step)
    }

    // MARK: FlowCurve

    func testResampleStraightLineIsEquallySpaced() {
        let raw = [SIMD3<Float>(0, 0, 0), SIMD3<Float>(10, 0, 0)]
        let c = FlowCurve.resample(raw, resolution: 11)
        XCTAssertEqual(c.points.count, 11)
        XCTAssertEqual(c.total, 10, accuracy: 1e-4)
        // Equal arc spacing → x steps of 1.0.
        for k in 0..<11 {
            XCTAssertEqual(c.points[k].x, Float(k), accuracy: 1e-3)
        }
        // Tangents are unit and point +x.
        for t in c.tangents { XCTAssertEqual(simd_length(t), 1, accuracy: 1e-4) }
        XCTAssertEqual(c.tangents[5].x, 1, accuracy: 1e-3)
    }

    func testSampleAtInterpolatesAndClamps() {
        let c = FlowCurve.resample([SIMD3<Float>(0, 0, 0), SIMD3<Float>(8, 0, 0)], resolution: 9)
        XCTAssertEqual(c.sample(at: 4).pos.x, 4, accuracy: 1e-3)
        XCTAssertEqual(c.sample(at: -5).pos.x, 0, accuracy: 1e-3)   // clamp low
        XCTAssertEqual(c.sample(at: 99).pos.x, 8, accuracy: 1e-3)   // clamp high
    }

    func testResampleDegenerateIsEmpty() {
        let c = FlowCurve.resample([SIMD3<Float>(1, 1, 1)], resolution: 20)
        XCTAssertTrue(c.isEmpty)
    }

    // MARK: streamline (load → stress-point)

    func testStreamlineTerminatesAtHotSpot() {
        let glyphs = uniformGlyphs(dir: SIMD3<Float>(1, 0, 0))
        let seed = SIMD3<Float>(0, 0, 0)
        let target = SIMD3<Float>(18, 0, 0)
        let pts = LoadFlowField.streamline(from: seed, to: target, glyphs: glyphs,
                                           stepLength: 1, maxSteps: 400)
        XCTAssertEqual(pts.first!, seed)
        assertClose(pts.last!, target, accuracy: 1e-3)     // pinned terminus
        // Following the +x field toward a +x target keeps the path on the axis.
        for p in pts { XCTAssertLessThan(abs(p.y), 0.5) }
    }

    func testStreamlineBendsWithFieldButStillConverges() {
        // A field angled up-and-forward bends the mid-path off the straight line, yet
        // the target pull still lands it exactly on the hot-spot (not a rigid line).
        let glyphs = uniformGlyphs(dir: SIMD3<Float>(1, 1, 0), extent: 30)
        let target = SIMD3<Float>(16, 0, 0)
        let pts = LoadFlowField.streamline(from: .zero, to: target, glyphs: glyphs,
                                           stepLength: 1, maxSteps: 600)
        assertClose(pts.last!, target, accuracy: 1e-3)
        let midY = pts[pts.count / 2].y
        XCTAssertGreaterThan(midY, 0.5)   // the field genuinely shaped the route
    }

    func testStreamlineSignsPrincipalAxisTowardTarget() {
        // A field pointing -x (away from a +x target) must be flipped, not walked back.
        let glyphs = uniformGlyphs(dir: SIMD3<Float>(-1, 0, 0))
        let target = SIMD3<Float>(15, 0, 0)
        let pts = LoadFlowField.streamline(from: .zero, to: target, glyphs: glyphs,
                                           stepLength: 1, maxSteps: 400)
        assertClose(pts.last!, target, accuracy: 1e-3)
        // Net progress is toward +x (never doubles back past the origin).
        for p in pts { XCTAssertGreaterThan(p.x, -0.5) }
    }

    func testCurvesStressPointOnePerSeedAndEmptyWithoutHotSpot() {
        let glyphs = uniformGlyphs(dir: SIMD3<Float>(1, 0, 0))
        let seeds = [SIMD3<Float>(0, 0, 0), SIMD3<Float>(0, 6, 0)]
        let hot = SIMD3<Float>(18, 0, 0)
        let curves = LoadFlowField.curves(mode: .stressPoint, loadSeeds: seeds,
                                          glyphs: glyphs, hotSpot: hot, stepLength: 1)
        XCTAssertEqual(curves.count, 2)
        for c in curves {
            assertClose(c.points.last!, hot, accuracy: 1e-2)
            XCTAssertFalse(c.isEmpty)
        }
        // No hot-spot → no curves (the mode has nothing to terminate at).
        XCTAssertTrue(LoadFlowField.curves(mode: .stressPoint, loadSeeds: seeds,
                                           glyphs: glyphs, hotSpot: nil, stepLength: 1).isEmpty)
        // Per-path desync differs so arrows don't beat in lockstep.
        XCTAssertNotEqual(curves[0].phaseOffset, curves[1].phaseOffset)
    }

    // MARK: comet arrow

    private func straightCurve(length: Float = 20) -> FlowCurve {
        FlowCurve.resample([SIMD3<Float>(0, 0, 0), SIMD3<Float>(length, 0, 0)], resolution: 96)
    }

    func testCometHeadAdvancesWithClock() {
        let c = straightCurve()
        let f0 = CometArrow.frame(curve: c, style: .sine, clock: 0.0, loopPeriod: 4,
                                  speed: 1, wiggle: 1, reduced: false, baseRadius: 0.4,
                                  color: SIMD3<Float>(1, 0.2, 0.15))
        let f1 = CometArrow.frame(curve: c, style: .sine, clock: 0.8, loopPeriod: 4,
                                  speed: 1, wiggle: 1, reduced: false, baseRadius: 0.4,
                                  color: SIMD3<Float>(1, 0.2, 0.15))
        XCTAssertGreaterThan(f1.headPosition.x, f0.headPosition.x)   // travelled forward
    }

    func testCometHeadStaysOnCurveAndWiggleZeroIsClean() {
        let c = straightCurve()
        // wiggle 0 → the whole centreline lies on the straight curve (y ≈ 0).
        let f = CometArrow.frame(curve: c, style: .serpentine, clock: 1.3, loopPeriod: 4,
                                 speed: 1, wiggle: 0, reduced: false, baseRadius: 0.4,
                                 color: SIMD3<Float>(1, 0, 0))
        for p in f.centers { XCTAssertLessThan(abs(p.y), 1e-3) }
        // The head is on the curve even WITH wiggle (amplitude tapers to 0 at the head).
        let fw = CometArrow.frame(curve: c, style: .serpentine, clock: 1.3, loopPeriod: 4,
                                  speed: 1, wiggle: 2, reduced: false, baseRadius: 0.4,
                                  color: SIMD3<Float>(1, 0, 0))
        XCTAssertLessThan(abs(fw.headPosition.y), 1e-3)
    }

    func testCometReducedMotionIsStatic() {
        let c = straightCurve()
        let a = CometArrow.frame(curve: c, style: .sine, clock: 0.0, loopPeriod: 4,
                                 speed: 1, wiggle: 1, reduced: true, baseRadius: 0.4,
                                 color: SIMD3<Float>(1, 0, 0))
        let b = CometArrow.frame(curve: c, style: .sine, clock: 5.0, loopPeriod: 4,
                                 speed: 1, wiggle: 1, reduced: true, baseRadius: 0.4,
                                 color: SIMD3<Float>(1, 0, 0))
        assertClose(a.headPosition, b.headPosition, accuracy: 1e-5)   // frozen
        XCTAssertEqual(a.centers.count, CometArrow.bodySegments)
    }

    // MARK: epicenter heat

    func testEpicenterHeatsAtHeadAndCoolsWithDistance() {
        let head = SIMD3<Float>(5, 0, 0)
        let base = 0.1
        let atHead = LoadFlowEpicenter.heatedFraction(base: base, position: head,
                                                      heads: [head], radius: 4, strength: 0.6)
        XCTAssertEqual(atHead, min(1, base + 0.6), accuracy: 1e-5)
        // Far outside the radius → untouched base.
        let far = LoadFlowEpicenter.heatedFraction(base: base, position: SIMD3<Float>(50, 0, 0),
                                                   heads: [head], radius: 4, strength: 0.6)
        XCTAssertEqual(far, base, accuracy: 1e-6)
        // Monotone falloff: closer is hotter.
        let near = LoadFlowEpicenter.heatedFraction(base: base, position: SIMD3<Float>(6, 0, 0),
                                                    heads: [head], radius: 4, strength: 0.6)
        let mid = LoadFlowEpicenter.heatedFraction(base: base, position: SIMD3<Float>(7.5, 0, 0),
                                                   heads: [head], radius: 4, strength: 0.6)
        XCTAssertGreaterThan(near, mid)
        XCTAssertGreaterThan(mid, base)
        // Clamped to 1.
        let hot = LoadFlowEpicenter.heatedFraction(base: 0.9, position: head,
                                                   heads: [head], radius: 4, strength: 0.6)
        XCTAssertEqual(hot, 1, accuracy: 1e-6)
        // No heads → base.
        XCTAssertEqual(LoadFlowEpicenter.heatedFraction(base: base, position: head,
                                                        heads: [], radius: 4, strength: 0.6),
                       min(1, max(0, base)), accuracy: 1e-6)
    }

    // MARK: tube extrusion layout

    func testCometMeshLayoutAndEmptiness() {
        let c = straightCurve()
        let f = CometArrow.frame(curve: c, style: .pulse, clock: 1.0, loopPeriod: 4,
                                 speed: 1, wiggle: 1, reduced: false, baseRadius: 0.4,
                                 color: SIMD3<Float>(1, 0.2, 0.15))
        let verts = CometMesh.build(f, intensity: 1)
        XCTAssertFalse(verts.isEmpty)
        XCTAssertEqual(verts.count % 7, 0)                 // stride-7 pos+rgba
        XCTAssertEqual(verts.count % 21, 0)                // whole triangles
        // Degenerate frame → no geometry.
        let empty = CometFrame(centers: [], tangents: [], coreRadii: [], haloRadii: [],
                               headPosition: .zero, headDirection: SIMD3<Float>(0, 0, 1),
                               headLength: 0, headRadius: 0, color: .zero)
        XCTAssertTrue(CometMesh.build(empty).isEmpty)
    }

    // MARK: ResultsModel FLOW wiring — mode / isolation / epicenter coupling

    /// A results model over a 4×4×4 uniaxial-stretch variant with a single stress peak,
    /// two tagged load seeds — so the flow builds real curves terminating at the hot-spot.
    @MainActor private func flowModel(loadSeeds: [SIMD3<Float>] = [SIMD3<Float>(0.5, 0.5, 0.5),
                                                                   SIMD3<Float>(0.5, 3.5, 0.5)]) -> ResultsModel {
        let n = 4, spacing: Float = 1
        // Uniaxial +x displacement so the principal directions run along X.
        let na = n + 1
        var disp = [Float](repeating: 0, count: 3 * na * na * na)
        for c in 0..<na { for b in 0..<na { for a in 0..<na {
            let idx = (c * na + b) * na + a
            disp[3 * idx] = 0.01 * Float(a) * spacing            // ux grows along +x
        }}}
        // Stress: a clear single peak at the far-+x corner (the hot-spot terminus).
        var stress = [Float](repeating: 4, count: n * n * n)
        stress[(0 * n + 0) * n + (n - 1)] = 40                    // i=n-1, j=0, k=0
        let v = OptimizeVariant(
            requestedVolumeFraction: 0.5, achievedVolumeFraction: 0.5, massGrams: 10,
            supportVolumeVoxels: 0, meshTriangleCount: 1, worstCaseMargin: 2, accepted: true,
            v3Passes: true, orientation: SIMD3(0, 0, 1), maxStressMPa: 40,
            meshVertices: [0, 0, 0, 4, 0, 0, 4, 4, 4, 0, 4, 0], meshIndices: [0, 1, 2, 0, 2, 3],
            vonMisesField: stress, displacementField: disp)
        let out = OptimizeOutcome(variants: [v], stoppedOnMargin: false, cancelled: false,
                                  acceptedCount: 1, voxelVolumeMM3: 1,
                                  gridNx: n, gridNy: n, gridNz: n,
                                  gridOrigin: SIMD3<Double>(0, 0, 0), spacing: Double(spacing))
        return ResultsModel(projectName: "P", outcome: out, materialName: "PLA",
                            yieldStrengthMPa: 55, loadLocations: loadSeeds)
    }

    @MainActor func testFlowCurvesTerminateAtHotSpotFromEachLoad() {
        let m = flowModel()
        let curves = m.selectedFlowCurves
        XCTAssertEqual(curves.count, 2)                          // one per load seed
        let hot = try! XCTUnwrap(m.hotSpot).position
        for c in curves { assertClose(c.points.last!, hot, accuracy: 0.5) }
    }

    @MainActor func testFlowFallsBackToMaxDeflectionWhenNoLoadsTagged() {
        let m = flowModel(loadSeeds: [])                         // STL / self-weight run
        XCTAssertEqual(m.flowLoadSeeds.count, 1)                 // one derived seed
        XCTAssertFalse(m.selectedFlowCurves.isEmpty)
    }

    @MainActor func testFlowIsolationRestrictsVisibleCurves() {
        let m = flowModel()
        XCTAssertNil(m.flowIsolate)                              // default: none isolated…
        XCTAssertGreaterThan(m.flowCurveCount, 1)               // …of a genuinely multi-load part
        XCTAssertEqual(m.visibleFlowCurveIndices.count, m.flowCurveCount)   // all by default
        XCTAssertEqual(m.visibleFlowCurveIndices, Array(0..<m.flowCurveCount))
        XCTAssertEqual(m.flowCometFrames(reduceMotion: false).count, m.flowCurveCount)
        m.flowIsolate = 1
        XCTAssertEqual(m.visibleFlowCurveIndices, [1])           // just the isolated one
        XCTAssertEqual(m.flowCometFrames(reduceMotion: false).count, 1)
        // Back to all.
        m.flowIsolate = nil
        XCTAssertEqual(m.visibleFlowCurveIndices.count, m.flowCurveCount)
        // An out-of-range isolate falls back to all (defensive).
        m.flowIsolate = 99
        XCTAssertEqual(m.visibleFlowCurveIndices.count, m.flowCurveCount)
    }

    @MainActor func testAdvancingFlowClockMovesHeadsUnlessReduced() {
        let m = flowModel()
        m.toggleLoadPath()
        // Reduced-motion OFF: advancing the flow clock moves the arrow heads.
        let before = m.flowHeadPositions(reduceMotion: false)
        m.advanceFlowClock(0.5)
        let after = m.flowHeadPositions(reduceMotion: false)
        XCTAssertEqual(before.count, after.count)
        XCTAssertFalse(before.isEmpty)
        let moved = zip(before, after).contains { simd_distance($0, $1) > 1e-4 }
        XCTAssertTrue(moved, "advancing the clock did not move any head (frozen with motion ON)")
        // Reduced-motion ON: the same clock advance leaves the heads pinned (static).
        let rBefore = m.flowHeadPositions(reduceMotion: true)
        m.advanceFlowClock(1.0)
        let rAfter = m.flowHeadPositions(reduceMotion: true)
        for (a, b) in zip(rBefore, rAfter) { assertClose(a, b, accuracy: 1e-5) }
    }

    @MainActor func testStaticStressReadoutUnchangedByFlowClock() {
        // HONESTY: the moving bloom is a flow overlay; the literal static Stress readout
        // (`stressTints`) must NOT depend on the arrow heads or the flow clock.
        let m = flowModel()
        m.toggleLoadPath()
        let mesh = try! XCTUnwrap(m.selectedMesh)
        let field = try! XCTUnwrap(m.selectedStressField)
        let staticBefore = m.stressTints(for: mesh, field: field, multiplier: 1)
        m.advanceFlowClock(0.9)                                  // heads move…
        let staticAfter = m.stressTints(for: mesh, field: field, multiplier: 1)
        XCTAssertEqual(staticBefore, staticAfter, "the static Stress readout drifted with the flow")
        // …while the flow's moving-epicenter tints DO change with the clock (the bloom
        // travels), proving the two paths are independent.
        let heads0 = m.flowHeadPositions(reduceMotion: false)
        m.advanceFlowClock(0.9)
        let heads1 = m.flowHeadPositions(reduceMotion: false)
        let bloom0 = m.flowStressTints(for: mesh, field: field, heads: heads0)
        let bloom1 = m.flowStressTints(for: mesh, field: field, heads: heads1)
        XCTAssertNotEqual(bloom0, bloom1, "the moving bloom did not travel with the clock")
    }

    @MainActor func testToggleLoadPathResetsFlowAndIsExclusiveWithFlex() {
        let m = flowModel()
        m.flowIsolate = 1
        m.toggleLoadPath()                                       // on
        XCTAssertTrue(m.loadPathOn)
        XCTAssertNil(m.flowIsolate)                             // reset to all
        XCTAssertEqual(m.flowClock, 0)
        m.advanceFlowClock(0.5)
        XCTAssertEqual(m.flowClock, 0.5, accuracy: 1e-9)
        m.toggleFlex()                                           // flex steals the channel
        XCTAssertFalse(m.loadPathOn)
        // Advancing the clock while off is a no-op.
        let held = m.flowClock
        m.advanceFlowClock(1)
        XCTAssertEqual(m.flowClock, held, accuracy: 1e-9)
    }

    @MainActor func testFlowStressTintsBloomNearArrowHeads() {
        let m = flowModel()
        m.toggleLoadPath()
        let mesh = try! XCTUnwrap(m.selectedMesh)
        let field = try! XCTUnwrap(m.selectedStressField)
        let heads = m.flowHeadPositions(reduceMotion: true)     // static → deterministic heads
        XCTAssertFalse(heads.isEmpty)
        let tints = m.flowStressTints(for: mesh, field: field, heads: heads)
        XCTAssertEqual(tints.count, mesh.flat.vertexCount)
        // With NO heads the same vertices are the plain static field; the bloom must
        // make at least one vertex hotter (redder → higher R, or shifted).
        let plain = m.flowStressTints(for: mesh, field: field, heads: [])
        XCTAssertNotEqual(tints, plain, "moving epicenters did not heat the body")
    }

    // MARK: GPU smoke — the comet + translucent body actually change the raster

    #if canImport(MetalKit)
    /// A unit cube (flat tris) so the renderer has something to draw.
    private static let cubeVerts: [Float] = [
        0,0,0, 1,0,0, 1,1,0, 0,1,0, 0,0,1, 1,0,1, 1,1,1, 0,1,1,
    ]
    private static let cubeTris: [Int32] = [
        0,2,1, 0,3,2, 4,5,6, 4,6,7, 0,1,5, 0,5,4,
        2,3,7, 2,7,6, 1,2,6, 1,6,5, 0,4,7, 0,7,3,
    ]

    func testRendererDrawsCometFlowAndTranslucentBody() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal device") }
        guard let renderer = MeshRenderer(device: device) else {
            XCTFail("MeshRenderer init failed: \(MeshRenderer.lastInitError ?? "unknown")"); return
        }
        let mesh = ViewerMesh(vertices: Self.cubeVerts, indices: Self.cubeTris, faceIDs: [])
        renderer.setMesh(mesh)
        let opaque = renderer.renderOffscreen(size: 96)
        XCTAssertNotNil(opaque)

        // A translucent body must change the raster (see-through walls blend differently).
        renderer.setBodyAlpha(0.2)
        let xray = renderer.renderOffscreen(size: 96)
        XCTAssertNotEqual(xray, opaque, "translucent body did not change the render")

        // Feeding comet geometry through the body must add glowing pixels.
        let curve = FlowCurve.resample([SIMD3<Float>(0, 0, 0), SIMD3<Float>(1, 1, 1)], resolution: 64)
        let frame = CometArrow.frame(curve: curve, style: .sine, clock: 1, loopPeriod: 4,
                                     speed: 1, wiggle: 1, reduced: false, baseRadius: 0.08,
                                     color: SIMD3<Float>(1, 0.28, 0.22))
        renderer.setLoadFlow(CometMesh.build(frame))
        XCTAssertNotEqual(renderer.renderOffscreen(size: 96), xray, "comet flow did not draw")

        // Clearing the flow + restoring opacity returns to the opaque baseline exactly.
        renderer.clearLoadFlow()
        XCTAssertEqual(renderer.renderOffscreen(size: 96), opaque, "clearLoadFlow should restore rest")
    }
    #endif

    // MARK: helpers

    private func assertClose(_ a: SIMD3<Float>, _ b: SIMD3<Float>, accuracy: Float,
                             file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(a.x, b.x, accuracy: accuracy, file: file, line: line)
        XCTAssertEqual(a.y, b.y, accuracy: accuracy, file: file, line: line)
        XCTAssertEqual(a.z, b.z, accuracy: accuracy, file: file, line: line)
    }
}
