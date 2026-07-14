// Headless tests for the M7.viz.5 load→anchor flow mode (handoff NNN, built on the
// mode-agnostic 071 foundation + the 072 core stress tensor). Four things are pinned:
//   1. StressTensorField reads the core's Voigt convention — von Mises reconstructed
//      from tensor(at:) matches the trusted vonMisesField (a mislabeled order fails).
//   2. The stress-flux streamline of F = σ·d̂ reaches the anchor voxel set on a field
//      built so σ·d̂ points load→anchor (a wrong contraction leaves the material).
//   3. Each of the THREE stop conditions (anchor / left-material / max-length) fires.
//   4. ResultsModel builds one curve per load→anchor path in .anchor mode, empty with
//      no anchors, and the mode switch swaps the curves while every downstream consumer
//      (isolation, comet frames) behaves identically — the 071 separation held.
//
// The Metal draw + device feel are QA (the M7 /app/ standard); this pins the numerics.

import XCTest
import simd
@testable import TopOptFlows
@testable import TopOptKit

final class LoadAnchorFlowTests: XCTestCase {

    // MARK: - STEP 1: tensor convention (von Mises reconstruction)

    /// The core's von Mises formula on a Voigt-[xx,yy,zz,xy,yz,zx] tensor with TRUE
    /// shear: `sqrt(0.5·Σ(σii-σjj)² + 3·Σ τ²)`. Independent reference for the guard.
    private func referenceVonMises(_ xx: Float, _ yy: Float, _ zz: Float,
                                   _ xy: Float, _ yz: Float, _ zx: Float) -> Float {
        let dev = 0.5 * (pow(xx - yy, 2) + pow(yy - zz, 2) + pow(zz - xx, 2))
        let shear = 3 * (xy * xy + yz * yz + zx * zx)
        return (dev + shear).squareRoot()
    }

    func testStressTensorFieldReconstructsVonMisesMatchingScalar() {
        // Three voxels with DISTINCT normals and shears so a mislabeled order (a
        // normal↔shear swap) would change the reconstructed von Mises. The scalar field
        // is filled from the SAME tensor via the reference formula — the app reading the
        // wrong convention would not reproduce it.
        let n = 3, spacing: Float = 2
        let count = n * n * n
        var tensor = [Float](repeating: 0, count: 6 * count)
        var vm = [Float](repeating: 0, count: count)
        // Give voxel idx the components (idx+1, idx+2, idx+3, idx*0.5, idx*0.3, idx*0.7).
        for idx in 0..<count {
            let xx = Float(idx) + 1, yy = Float(idx) + 2, zz = Float(idx) + 3
            let xy = Float(idx) * 0.5, yz = Float(idx) * 0.3, zx = Float(idx) * 0.7
            tensor[6 * idx + 0] = xx; tensor[6 * idx + 1] = yy; tensor[6 * idx + 2] = zz
            tensor[6 * idx + 3] = xy; tensor[6 * idx + 4] = yz; tensor[6 * idx + 5] = zx
            vm[idx] = referenceVonMises(xx, yy, zz, xy, yz, zx)
        }
        let origin = SIMD3<Float>(0, 0, 0)
        let tf = StressTensorField(nx: n, ny: n, nz: n, origin: origin, spacing: spacing, values: tensor)
        let sf = StressField(nx: n, ny: n, nz: n, origin: origin, spacing: spacing, values: vm)
        XCTAssertFalse(tf.isEmpty)
        // Sample several voxel centres; von Mises from the tensor must match the scalar.
        for k in 0..<n { for j in 0..<n { for i in 0..<n {
            let p = origin + SIMD3<Float>(Float(i) + 0.5, Float(j) + 0.5, Float(k) + 0.5) * spacing
            let idx = (k * n + j) * n + i
            XCTAssertEqual(tf.vonMises(at: p), sf.value(at: p), accuracy: 1e-3 * (1 + abs(vm[idx])),
                           "von Mises from tensor must match the scalar at voxel \(i),\(j),\(k)")
        }}}
    }

    func testStressTensorMatrixIsSymmetricWithTrueShear() {
        // The assembled 3×3 has the normals on the diagonal and the TRUE shears
        // off-diagonal (row/col (0,1)=xy, (1,2)=yz, (2,0)=zx), and is symmetric.
        let vals: [Float] = [11, 22, 33, 4, 5, 6]   // one voxel
        let tf = StressTensorField(nx: 1, ny: 1, nz: 1, origin: .zero, spacing: 1, values: vals)
        let m = tf.tensor(at: SIMD3<Float>(0.5, 0.5, 0.5))
        XCTAssertEqual(m[0][0], 11); XCTAssertEqual(m[1][1], 22); XCTAssertEqual(m[2][2], 33)
        XCTAssertEqual(m[0][1], 4);  XCTAssertEqual(m[1][0], 4)   // xy, symmetric
        XCTAssertEqual(m[1][2], 5);  XCTAssertEqual(m[2][1], 5)   // yz
        XCTAssertEqual(m[2][0], 6);  XCTAssertEqual(m[0][2], 6)   // zx
    }

    func testEmptyTensorFieldIsEmptyAndZero() {
        let tf = StressTensorField(nx: 2, ny: 2, nz: 2, origin: .zero, spacing: 1, values: [])
        XCTAssertTrue(tf.isEmpty)
        XCTAssertEqual(tf.vonMises(at: .zero), 0)
        // A ragged field (wrong size) is also empty (defensive).
        let ragged = StressTensorField(nx: 2, ny: 2, nz: 2, origin: .zero, spacing: 1, values: [1, 2, 3])
        XCTAssertTrue(ragged.isEmpty)
    }

    // MARK: - helpers for the flux field

    /// A tensor field whose ONLY nonzero component is σxx = `sxx` on every voxel, so
    /// `σ·(1,0,0)` = (sxx, 0, 0): a uniform +x (for sxx>0) flux that carries a streamline
    /// straight down +x. `nx/ny/nz` voxels, unit spacing, origin 0.
    private func uniaxialTensor(nx: Int, ny: Int, nz: Int, sxx: Float) -> StressTensorField {
        var v = [Float](repeating: 0, count: 6 * nx * ny * nz)
        for idx in 0..<(nx * ny * nz) { v[6 * idx + 0] = sxx }
        return StressTensorField(nx: nx, ny: ny, nz: nz, origin: .zero, spacing: 1, values: v)
    }

    /// A uniform-positive von Mises gate (all printed) for a grid.
    private func allPrinted(nx: Int, ny: Int, nz: Int) -> StressField {
        StressField(nx: nx, ny: ny, nz: nz, origin: .zero, spacing: 1,
                    values: [Float](repeating: 1, count: nx * ny * nz))
    }

    // MARK: - STEP 2: flux streamline reaches the anchor

    func testFluxStreamlineReachesAnchorWhenSigmaDHatPointsToIt() {
        let n = 12
        let tensor = uniaxialTensor(nx: n, ny: n, nz: n, sxx: 1)      // σ·d̂ = +x
        let gate = allPrinted(nx: n, ny: n, nz: n)
        // Anchor at the far +x end.
        let anchors = AnchorVoxelSet.build(points: [SIMD3<Float>(11.5, 5.5, 5.5)],
                                           nx: n, ny: n, nz: n, origin: .zero, spacing: 1)
        XCTAssertFalse(anchors.isEmpty)
        let traced = LoadFlowField.fluxStreamline(from: SIMD3<Float>(0.5, 5.5, 5.5),
                                                  direction: SIMD3<Float>(1, 0, 0),
                                                  tensor: tensor, printedGate: gate,
                                                  anchors: anchors, stepLength: 0.5, maxSteps: 400)
        XCTAssertEqual(traced.stop, .reachedAnchor)
        XCTAssertTrue(anchors.contains(traced.points.last!))
        // The route stayed on the +x axis (the flux was purely +x).
        for p in traced.points { XCTAssertLessThan(abs(p.y - 5.5), 0.5); XCTAssertLessThan(abs(p.z - 5.5), 0.5) }
    }

    func testWrongContractionDoesNotReachAnchor() {
        // σyy-only tensor: σ·(1,0,0) = column 0 = (0,0,0) → no flux along d̂ = +x. The
        // (correct-order) contraction yields nothing, so the streamline cannot advance
        // and never reaches the anchor — the negative control the reach test relies on.
        let n = 12
        var v = [Float](repeating: 0, count: 6 * n * n * n)
        for idx in 0..<(n * n * n) { v[6 * idx + 1] = 1 }            // σyy only
        let tensor = StressTensorField(nx: n, ny: n, nz: n, origin: .zero, spacing: 1, values: v)
        let anchors = AnchorVoxelSet.build(points: [SIMD3<Float>(11.5, 5.5, 5.5)],
                                           nx: n, ny: n, nz: n, origin: .zero, spacing: 1)
        let traced = LoadFlowField.fluxStreamline(from: SIMD3<Float>(0.5, 5.5, 5.5),
                                                  direction: SIMD3<Float>(1, 0, 0),
                                                  tensor: tensor, printedGate: allPrinted(nx: n, ny: n, nz: n),
                                                  anchors: anchors, stepLength: 0.5, maxSteps: 400)
        XCTAssertNotEqual(traced.stop, .reachedAnchor)
    }

    // MARK: - STEP 2: the three stop conditions

    func testStopConditionReachedAnchor() {
        let n = 8
        let anchors = AnchorVoxelSet.build(points: [SIMD3<Float>(7.5, 3.5, 3.5)],
                                           nx: n, ny: n, nz: n, origin: .zero, spacing: 1)
        let traced = LoadFlowField.fluxStreamline(from: SIMD3<Float>(0.5, 3.5, 3.5),
                                                  direction: SIMD3<Float>(1, 0, 0),
                                                  tensor: uniaxialTensor(nx: n, ny: n, nz: n, sxx: 1),
                                                  printedGate: allPrinted(nx: n, ny: n, nz: n),
                                                  anchors: anchors, stepLength: 0.5, maxSteps: 400)
        XCTAssertEqual(traced.stop, .reachedAnchor)
    }

    func testStopConditionLeftMaterial() {
        // Flux flows +x, but the printed gate goes void at i≥4 (a hole) BEFORE the anchor
        // at the far end — the streamline leaves the material and is dropped.
        let n = 12
        var gateVals = [Float](repeating: 1, count: n * n * n)
        for k in 0..<n { for j in 0..<n { for i in 4..<n { gateVals[(k * n + j) * n + i] = 0 } } }
        let gate = StressField(nx: n, ny: n, nz: n, origin: .zero, spacing: 1, values: gateVals)
        let anchors = AnchorVoxelSet.build(points: [SIMD3<Float>(11.5, 5.5, 5.5)],
                                           nx: n, ny: n, nz: n, origin: .zero, spacing: 1)
        let traced = LoadFlowField.fluxStreamline(from: SIMD3<Float>(0.5, 5.5, 5.5),
                                                  direction: SIMD3<Float>(1, 0, 0),
                                                  tensor: uniaxialTensor(nx: n, ny: n, nz: n, sxx: 1),
                                                  printedGate: gate,
                                                  anchors: anchors, stepLength: 0.5, maxSteps: 400)
        XCTAssertEqual(traced.stop, .leftMaterial)
    }

    func testStopConditionExceededLength() {
        // Flux flows +x through all-printed material, but the anchor is off the path (far
        // +y) and maxSteps is too small to traverse the domain — the trace runs out.
        let n = 20
        let anchors = AnchorVoxelSet.build(points: [SIMD3<Float>(0.5, 19.5, 0.5)],
                                           nx: n, ny: n, nz: n, origin: .zero, spacing: 1)
        let traced = LoadFlowField.fluxStreamline(from: SIMD3<Float>(0.5, 5.5, 5.5),
                                                  direction: SIMD3<Float>(1, 0, 0),
                                                  tensor: uniaxialTensor(nx: n, ny: n, nz: n, sxx: 1),
                                                  printedGate: allPrinted(nx: n, ny: n, nz: n),
                                                  anchors: anchors, stepLength: 0.5, maxSteps: 6)
        XCTAssertEqual(traced.stop, .exceededLength)
    }

    // MARK: - STEP 2: curves() anchor branch

    func testAnchorCurvesOnePerLoadAndEmptyWithoutAnchors() {
        let n = 12
        let tensor = uniaxialTensor(nx: n, ny: n, nz: n, sxx: 1)
        let gate = allPrinted(nx: n, ny: n, nz: n)
        let anchors = AnchorVoxelSet.build(points: [SIMD3<Float>(11.5, 3.5, 3.5),
                                                    SIMD3<Float>(11.5, 8.5, 8.5)],
                                           nx: n, ny: n, nz: n, origin: .zero, spacing: 1)
        let seeds = [SIMD3<Float>(0.5, 3.5, 3.5), SIMD3<Float>(0.5, 8.5, 8.5)]
        let dirs = [SIMD3<Float>(1, 0, 0), SIMD3<Float>(1, 0, 0)]
        let curves = LoadFlowField.curves(mode: .anchor, loadSeeds: seeds, loadDirections: dirs,
                                          tensor: tensor, printedGate: gate, anchors: anchors,
                                          stepLength: 0.5)
        XCTAssertEqual(curves.count, 2)                             // one per load→anchor path
        for c in curves { XCTAssertFalse(c.isEmpty) }
        XCTAssertNotEqual(curves[0].phaseOffset, curves[1].phaseOffset)   // per-path desync
        // No anchors tagged → no curves.
        let none = AnchorVoxelSet.build(points: [], nx: n, ny: n, nz: n, origin: .zero, spacing: 1)
        XCTAssertTrue(LoadFlowField.curves(mode: .anchor, loadSeeds: seeds, loadDirections: dirs,
                                           tensor: tensor, printedGate: gate, anchors: none,
                                           stepLength: 0.5).isEmpty)
        // A load whose flux never reaches an anchor is dropped (σyy-only → no +x flux).
        var vy = [Float](repeating: 0, count: 6 * n * n * n)
        for idx in 0..<(n * n * n) { vy[6 * idx + 1] = 1 }
        let noFlux = StressTensorField(nx: n, ny: n, nz: n, origin: .zero, spacing: 1, values: vy)
        XCTAssertTrue(LoadFlowField.curves(mode: .anchor, loadSeeds: seeds, loadDirections: dirs,
                                           tensor: noFlux, printedGate: gate, anchors: anchors,
                                           stepLength: 0.5).isEmpty)
    }

    func testAnchorVoxelSetContainsAndBuild() {
        let set = AnchorVoxelSet.build(points: [SIMD3<Float>(5.5, 5.5, 5.5)],
                                       nx: 10, ny: 10, nz: 10, origin: .zero, spacing: 1)
        XCTAssertFalse(set.isEmpty)
        XCTAssertTrue(set.contains(SIMD3<Float>(5.5, 5.5, 5.5)))     // the point's own voxel
        XCTAssertFalse(set.contains(SIMD3<Float>(0.5, 0.5, 0.5)))    // far corner not flagged
        // Empty points → empty set.
        XCTAssertTrue(AnchorVoxelSet.build(points: [], nx: 10, ny: 10, nz: 10,
                                           origin: .zero, spacing: 1).isEmpty)
    }

    // MARK: - STEP 3/4: ResultsModel mode wiring

    /// A results model over an 8³ variant carrying a σxx-only tensor field (so σ·(+x)
    /// flows +x), tagged loads at −x with +x direction, and an anchor at +x — so BOTH
    /// modes can build curves. The von Mises scalar has a single peak at the +x corner
    /// (the stress-point terminus).
    @MainActor private func anchorFlowModel(anchorPoints: [SIMD3<Float>] =
                                                [SIMD3<Float>(7.5, 3.5, 3.5)]) -> ResultsModel {
        let n = 8, spacing: Float = 1
        let na = n + 1
        // Uniaxial +x displacement so the principal directions (stress-point mode) run +x.
        var disp = [Float](repeating: 0, count: 3 * na * na * na)
        for c in 0..<na { for b in 0..<na { for a in 0..<na {
            disp[3 * ((c * na + b) * na + a)] = 0.01 * Float(a) * spacing
        }}}
        // σxx = 1 everywhere → the flux mode flows +x to the anchor.
        var tensor = [Float](repeating: 0, count: 6 * n * n * n)
        for idx in 0..<(n * n * n) { tensor[6 * idx + 0] = 1 }
        // Von Mises: a peak at the far +x corner (stress-point terminus) over a printed base.
        var vm = [Float](repeating: 4, count: n * n * n)
        vm[(3 * n + 3) * n + (n - 1)] = 40
        let v = OptimizeVariant(
            requestedVolumeFraction: 0.5, achievedVolumeFraction: 0.5, massGrams: 10,
            supportVolumeVoxels: 0, meshTriangleCount: 1, worstCaseMargin: 2, accepted: true,
            v3Passes: true, orientation: SIMD3(0, 0, 1), maxStressMPa: 40,
            meshVertices: [0, 0, 0, 8, 0, 0, 8, 8, 8, 0, 8, 0], meshIndices: [0, 1, 2, 0, 2, 3],
            vonMisesField: vm, displacementField: disp, stressTensorField: tensor)
        let out = OptimizeOutcome(variants: [v], stoppedOnMargin: false, cancelled: false,
                                  acceptedCount: 1, voxelVolumeMM3: 1, gridNx: n, gridNy: n, gridNz: n,
                                  gridOrigin: SIMD3<Double>(0, 0, 0), spacing: Double(spacing))
        return ResultsModel(projectName: "P", outcome: out, materialName: "PLA",
                            yieldStrengthMPa: 55,
                            loadLocations: [SIMD3<Float>(0.5, 3.5, 3.5)],
                            loadDirections: [SIMD3<Float>(1, 0, 0)],
                            anchorPoints: anchorPoints)
    }

    @MainActor func testTensorFieldIsPlumbedThroughResultsModel() {
        // Proves the bridge → OptimizeVariant.stressTensorField → StressTensorField path
        // is wired: the model exposes the variant's tensor, and von Mises reconstructed
        // from it reads the σxx=1 the variant carries. (The rigorous convention→scalar
        // match on consistent data is `testStressTensorFieldReconstructsVonMisesMatchingScalar`.)
        let m = anchorFlowModel()
        let tf = try! XCTUnwrap(m.selectedTensorField)
        XCTAssertFalse(tf.isEmpty)
        let p = SIMD3<Float>(2.5, 2.5, 2.5)
        XCTAssertEqual(tf.vonMises(at: p), 1, accuracy: 1e-3)       // σxx=1 → von Mises 1
        let s = tf.components(at: p)
        XCTAssertEqual(s.xx, 1, accuracy: 1e-6)
        XCTAssertEqual(s.yy, 0, accuracy: 1e-6)
    }

    @MainActor func testAnchorModeBuildsCurveAndEmptyWithoutAnchors() {
        let m = anchorFlowModel()
        XCTAssertTrue(m.hasAnchorFlow)
        m.setFlowMode(.anchor)
        XCTAssertEqual(m.flowMode, .anchor)
        let curves = m.selectedFlowCurves
        XCTAssertEqual(curves.count, 1)                            // one load→anchor route
        XCTAssertTrue(m.selectedAnchorSet.contains(curves[0].points.last!))
        // No anchors tagged → anchor flow unavailable + no curves.
        let noAnchor = anchorFlowModel(anchorPoints: [])
        XCTAssertFalse(noAnchor.hasAnchorFlow)
        noAnchor.setFlowMode(.anchor)
        XCTAssertTrue(noAnchor.selectedFlowCurves.isEmpty)
    }

    @MainActor func testModeSwitchSwapsCurvesButDownstreamIsIdentical() {
        let m = anchorFlowModel()
        // Stress-point curves terminate at the hot-spot; anchor curves at the anchor.
        let stressCurves = m.selectedFlowCurves
        XCTAssertFalse(stressCurves.isEmpty)
        let hot = try! XCTUnwrap(m.hotSpot).position
        assertClose(stressCurves[0].points.last!, hot, accuracy: 0.6)

        m.setFlowMode(.anchor)
        let anchorCurves = m.selectedFlowCurves
        XCTAssertFalse(anchorCurves.isEmpty)
        XCTAssertTrue(m.selectedAnchorSet.contains(anchorCurves[0].points.last!))
        // The two families genuinely differ (different termini).
        XCTAssertNotEqual(stressCurves[0].points.last!, anchorCurves[0].points.last!)

        // Downstream is mode-blind: the SAME comet-frame / isolation path works for the
        // anchor curves exactly as for the stress-point curves (no mode branching there).
        XCTAssertEqual(m.flowCometFrames(reduceMotion: false).count, anchorCurves.count)
        XCTAssertEqual(m.visibleFlowCurveIndices.count, anchorCurves.count)
        m.flowIsolate = 0
        XCTAssertEqual(m.visibleFlowCurveIndices, [0])
        XCTAssertEqual(m.flowCometFrames(reduceMotion: false).count, 1)

        // Switching back restores the stress-point curves (cache is keyed on mode).
        m.setFlowMode(.stressPoint)
        XCTAssertEqual(m.flowMode, .stressPoint)
        assertClose(m.selectedFlowCurves[0].points.last!, hot, accuracy: 0.6)
    }

    @MainActor func testSetFlowModeResetsIsolationAndClock() {
        let m = anchorFlowModel()
        m.toggleLoadPath()
        m.flowIsolate = 0
        m.advanceFlowClock(0.7)
        XCTAssertEqual(m.flowClock, 0.7, accuracy: 1e-9)
        m.setFlowMode(.anchor)
        XCTAssertNil(m.flowIsolate)                                // reset to all paths
        XCTAssertEqual(m.flowClock, 0)                             // restarted cleanly
        // Re-selecting the same mode is a no-op (no needless reset).
        m.advanceFlowClock(0.3)
        m.setFlowMode(.anchor)
        XCTAssertEqual(m.flowClock, 0.3, accuracy: 1e-9)
    }

    // MARK: helpers

    private func assertClose(_ a: SIMD3<Float>, _ b: SIMD3<Float>, accuracy: Float,
                             file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(a.x, b.x, accuracy: accuracy, file: file, line: line)
        XCTAssertEqual(a.y, b.y, accuracy: accuracy, file: file, line: line)
        XCTAssertEqual(a.z, b.z, accuracy: accuracy, file: file, line: line)
    }
}
