// Headless tests for the M7.8 ResultsModel (savings tabs, orientation copy, layer
// shear, stress color ramp + shared scale, scrub state). Pure logic — no bridge,
// no rendering. The ResultsScreen chrome + the Metal stress/threshold rendering
// are device QA (the M7 /app/ standard).
import XCTest
import simd
@testable import TopOptFlows
@testable import TopOptKit
import TopOptDesign

@MainActor
final class ResultsModelTests: XCTestCase {

    // A stub accepted variant with just the fields the results screen reads.
    private func variant(vf: Double, mass: Double = 100, support: Int = 0,
                         orientation: SIMD3<Double> = SIMD3(0, 0, 1),
                         maxStress: Double = 10, interlayerMargin: Double = 3,
                         accepted: Bool = true, minFeat: Int = 0) -> OptimizeVariant {
        OptimizeVariant(
            requestedVolumeFraction: vf, achievedVolumeFraction: vf, massGrams: mass,
            supportVolumeVoxels: support, meshTriangleCount: 100, worstCaseMargin: min(2, interlayerMargin),
            accepted: accepted, v3Passes: true, minFeatureViolations: minFeat, minFeatureWarning: minFeat > 0 ? "thin" : "",
            orientation: orientation, maxStressMPa: maxStress, maxInterlayerTensionMPa: 5,
            inPlaneMargin: 2, interlayerMargin: interlayerMargin)
    }

    private func outcome(_ variants: [OptimizeVariant], voxelVolumeMM3: Double = 1) -> OptimizeOutcome {
        OptimizeOutcome(variants: variants, stoppedOnMargin: false, cancelled: false,
                        acceptedCount: variants.filter(\.accepted).count, voxelVolumeMM3: voxelVolumeMM3)
    }

    // MARK: tabs / savings / mass

    func testSavingsAndMassLabels() {
        let m = ResultsModel(projectName: "P", outcome: outcome([
            variant(vf: 0.7, mass: 199), variant(vf: 0.5, mass: 142), variant(vf: 0.3, mass: 85),
        ]))
        XCTAssertEqual(m.tabs.count, 3)
        XCTAssertEqual(m.tabs[0].savingsPercent, 30)
        XCTAssertEqual(m.tabs[0].savingsLabel, "\u{2212}30%")   // U+2212 minus, per design
        XCTAssertEqual(m.tabs[1].savingsLabel, "\u{2212}50%")
        XCTAssertEqual(m.tabs[2].savingsLabel, "\u{2212}70%")
        XCTAssertEqual(m.tabs[0].massLabel, "199 g")
        XCTAssertEqual(m.tabs[0].subLabel(active: true), "199 g · selected")
        XCTAssertEqual(m.tabs[0].subLabel(active: false), "199 g · plastic")
    }

    func testMassLabelFormatting() {
        XCTAssertEqual(ResultsModel.massLabel(199), "199 g")
        XCTAssertEqual(ResultsModel.massLabel(9.4), "9.4 g")
        XCTAssertEqual(ResultsModel.massLabel(1240), "1.24 kg")
    }

    func testOnlyAcceptedVariantsBecomeTabs() {
        let m = ResultsModel(projectName: "P", outcome: outcome([
            variant(vf: 0.7), variant(vf: 0.5), variant(vf: 0.3, accepted: false),  // rejected terminal
        ]))
        XCTAssertEqual(m.tabs.count, 2)
    }

    // MARK: selection

    func testDefaultSelectedIsRecommendedLightest() {
        let m = ResultsModel(projectName: "P", outcome: outcome([variant(vf: 0.7), variant(vf: 0.5), variant(vf: 0.3)]))
        // Recommendation = lightest safe = the last (max-savings) tab; default-selected.
        XCTAssertEqual(m.selectedIndex, 2)
        XCTAssertTrue(m.tabs[2].isRecommended)
        XCTAssertFalse(m.tabs[0].isRecommended)
        XCTAssertFalse(m.tabs[1].isRecommended)
        XCTAssertEqual(m.tabs.filter(\.isRecommended).count, 1, "exactly one recommendation")
    }

    func testUpdateAppendsStreamedVariantsAndFollowsRecommendation() {
        // Progressive results: variants stream in one at a time; the model appends
        // them and (until the user picks) keeps the recommendation/selection on the
        // newest lightest-safe variant.
        let m = ResultsModel(projectName: "P", outcome: outcome([variant(vf: 0.7)]))
        XCTAssertEqual(m.tabs.count, 1)
        XCTAssertTrue(m.tabs[0].isRecommended)
        XCTAssertEqual(m.selectedIndex, 0)

        m.update(from: outcome([variant(vf: 0.7), variant(vf: 0.5)]))
        XCTAssertEqual(m.tabs.count, 2)
        XCTAssertTrue(m.tabs[1].isRecommended)                  // recommendation moved to the lighter
        XCTAssertEqual(m.selectedIndex, 1, "selection follows the recommendation")

        // Once the user manually picks, streaming no longer moves the selection.
        m.select(0)
        m.update(from: outcome([variant(vf: 0.7), variant(vf: 0.5), variant(vf: 0.3)]))
        XCTAssertEqual(m.tabs.count, 3)
        XCTAssertTrue(m.tabs[2].isRecommended)
        XCTAssertEqual(m.selectedIndex, 0, "the user's pick is preserved across streaming")
    }

    func testDefaultSelectedIsZeroWhenSingle() {
        let m = ResultsModel(projectName: "P", outcome: outcome([variant(vf: 0.6)]))
        XCTAssertEqual(m.selectedIndex, 0)
        XCTAssertEqual(m.selected?.index, 0)
    }

    func testSelectResetsScrubAndClampsRange() {
        let m = ResultsModel(projectName: "P", outcome: outcome([variant(vf: 0.7), variant(vf: 0.5)]))
        m.scrub(to: 0.3)
        m.select(0)
        XCTAssertEqual(m.selectedIndex, 0)
        XCTAssertEqual(m.playT, 1, accuracy: 1e-9)     // pick → fully formed
        XCTAssertFalse(m.playing)
        m.select(9)                                    // out of range → ignored
        XCTAssertEqual(m.selectedIndex, 0)
    }

    // MARK: scrub / play state

    func testScrubClamps() {
        let m = ResultsModel(projectName: "P", outcome: outcome([variant(vf: 0.5)]))
        m.scrub(to: -1); XCTAssertEqual(m.playT, 0, accuracy: 1e-9)
        m.scrub(to: 2);  XCTAssertEqual(m.playT, 1, accuracy: 1e-9)
    }

    func testTogglePlayRestartsFromEnd() {
        let m = ResultsModel(projectName: "P", outcome: outcome([variant(vf: 0.5)]))
        XCTAssertEqual(m.playT, 1, accuracy: 1e-9)     // opens fully formed
        m.togglePlay()                                 // at end → restart
        XCTAssertTrue(m.playing)
        XCTAssertEqual(m.playT, 0, accuracy: 1e-9)
        m.advance(0.5); XCTAssertEqual(m.playT, 0.5, accuracy: 1e-9)
        m.advance(1);   XCTAssertEqual(m.playT, 1, accuracy: 1e-9)
        XCTAssertFalse(m.playing)                      // stops at 1
    }

    func testToggleStress() {
        let m = ResultsModel(projectName: "P", outcome: outcome([variant(vf: 0.5)]))
        XCTAssertFalse(m.stressOn)
        m.toggleStress(); XCTAssertTrue(m.stressOn)
        m.toggleStress(); XCTAssertFalse(m.stressOn)
    }

    // MARK: support estimate

    func testSupportEstimateCm3() {
        // 2000 voxels × 1 mm³ each = 2000 mm³ = 2.0 cm³.
        let m = ResultsModel(projectName: "P", outcome: outcome([variant(vf: 0.5, support: 2000)], voxelVolumeMM3: 1))
        XCTAssertEqual(m.tabs[0].supportCm3, 2.0, accuracy: 1e-9)
        XCTAssertEqual(m.tabs[0].supportLabel, "2.0 cm³")
    }

    func testZeroSupportReadsMinimal() {
        let m = ResultsModel(projectName: "P", outcome: outcome([variant(vf: 0.5, support: 0)]))
        XCTAssertEqual(m.tabs[0].supportLabel, "minimal")
    }

    // MARK: orientation tilt + copy

    func testUprightOrientation() {
        XCTAssertEqual(ResultsModel.tiltFromVertical(SIMD3(0, 0, 1)), 0)
        XCTAssertEqual(ResultsModel.tiltFromVertical(SIMD3(0, 0, -1)), 0)   // same layer planes
        let s = ResultsModel.orientationSummary(tiltDegrees: 0, supportCm3: 0, supportLabel: "minimal")
        XCTAssertTrue(s.hasPrefix("Print upright"))
        XCTAssertTrue(s.contains("Minimal supports"))
    }

    func testTiltedOrientation() {
        // 45° between +Z and (1,0,1)/√2.
        XCTAssertEqual(ResultsModel.tiltFromVertical(SIMD3(1, 0, 1)), 45)
        let s = ResultsModel.orientationSummary(tiltDegrees: 45, supportCm3: 3.8, supportLabel: "3.8 cm³")
        XCTAssertTrue(s.contains("Tilt 45° from vertical"))
        XCTAssertTrue(s.contains("Est. 3.8 cm³ support"))
    }

    func testOrientationSummaryOmitsPrintTime() {
        // DECISIONS 2026-07-11: (b) omit print time. Never surface a time/duration.
        let s = ResultsModel.orientationSummary(tiltDegrees: 30, supportCm3: 1, supportLabel: "1.0 cm³")
        XCTAssertFalse(s.lowercased().contains("print time"))
        // No hour/minute duration tokens like "3h", "10 min", "2 hr".
        let duration = #"\d+\s*(h|hr|hrs|hour|hours|min|mins|minute|minutes)\b"#
        XCTAssertNil(s.range(of: duration, options: .regularExpression),
                     "orientation copy must not surface a print-time duration")
    }

    // MARK: layer shear

    func testLayerShearClassification() {
        XCTAssertEqual(LayerShear.classify(interlayerMargin: 2.0), .low)
        XCTAssertEqual(LayerShear.classify(interlayerMargin: 1.99), .moderate)
        XCTAssertEqual(LayerShear.classify(interlayerMargin: 1.25), .moderate)
        XCTAssertEqual(LayerShear.classify(interlayerMargin: 1.24), .high)
        XCTAssertEqual(LayerShear.classify(interlayerMargin: .infinity), .low)  // no layer tension
        XCTAssertTrue(LayerShear.low.isLow)
        XCTAssertFalse(LayerShear.moderate.isLow)
        XCTAssertEqual(LayerShear.high.label, "High")
    }

    // MARK: stress color ramp + shared scale

    func testStressColorRampEndpointsAndMidpoint() {
        let lo = ResultsModel.stressColor(fraction: 0)
        XCTAssertEqual(lo, RGBA(28, 60, 170))       // #1c3caa
        let hi = ResultsModel.stressColor(fraction: 1)
        XCTAssertEqual(hi, RGBA(255, 70, 50))       // #ff4632
        let mid = ResultsModel.stressColor(fraction: 0.5)
        XCTAssertEqual(mid, RGBA(60, 190, 110))     // #3cbe6e (green, center stop)
    }

    func testStressColorClamps() {
        XCTAssertEqual(ResultsModel.stressColor(fraction: -5), RGBA(28, 60, 170))
        XCTAssertEqual(ResultsModel.stressColor(fraction: 5), RGBA(255, 70, 50))
    }

    func testStressSharedScaleAcrossVariants() {
        let m = ResultsModel(projectName: "P", outcome: outcome([
            variant(vf: 0.7, maxStress: 8), variant(vf: 0.5, maxStress: 20), variant(vf: 0.3, maxStress: 12),
        ]))
        XCTAssertEqual(m.stressScaleMaxMPa, 20, accuracy: 1e-9)   // global max
        XCTAssertEqual(m.stressFraction(mpa: 20), 1, accuracy: 1e-9)
        XCTAssertEqual(m.stressFraction(mpa: 10), 0.5, accuracy: 1e-9)
        XCTAssertEqual(m.stressFraction(mpa: 40), 1, accuracy: 1e-9) // clamped
    }

    // MARK: stress scale keyed to material yield (M7.viz.1 — the honest heatmap)

    /// A model whose stress scale is keyed to the material `yield` (MPa), as the app
    /// constructs it from the run's material record (materials.json).
    private func yieldModel(_ variants: [OptimizeVariant], yield: Double,
                            material: String = "PLA") -> ResultsModel {
        ResultsModel(projectName: "P", outcome: outcome(variants),
                     materialName: material, yieldStrengthMPa: yield)
    }

    func testStressScaleKeyedToMaterialYieldNotDataRange() {
        // Variants peak at 8 / 20 / 12 MPa, but the scale is the material YIELD (55),
        // NOT the data max — so a color means the same physical safety everywhere.
        let m = yieldModel([variant(vf: 0.7, maxStress: 8), variant(vf: 0.5, maxStress: 20),
                            variant(vf: 0.3, maxStress: 12)], yield: 55)
        XCTAssertEqual(m.stressScaleMaxMPa, 55, accuracy: 1e-9)
        XCTAssertEqual(m.stressFraction(mpa: 0), 0, accuracy: 1e-9)
        XCTAssertEqual(m.stressFraction(mpa: 27.5), 0.5, accuracy: 1e-9)   // half yield
        XCTAssertEqual(m.stressFraction(mpa: 55), 1, accuracy: 1e-9)       // yield boundary
        XCTAssertEqual(m.stressFraction(mpa: 110), 1, accuracy: 1e-9)      // above yield → clamped
    }

    func testStressYieldBoundaryMapsToRedAndZeroToBlue() {
        // yield boundary correct: stress == yield → the ramp's red endpoint; above
        // yield stays red (clamped); zero stress → the blue (safe) endpoint.
        let m = yieldModel([variant(vf: 0.5, maxStress: 5)], yield: 55)
        XCTAssertEqual(ResultsModel.stressColor(fraction: m.stressFraction(mpa: 55)), RGBA(255, 70, 50))
        XCTAssertEqual(ResultsModel.stressColor(fraction: m.stressFraction(mpa: 80)), RGBA(255, 70, 50))
        XCTAssertEqual(ResultsModel.stressColor(fraction: m.stressFraction(mpa: 0)), RGBA(28, 60, 170))
    }

    func testStressFractionMonotonicAndClampedAgainstYield() {
        let m = yieldModel([variant(vf: 0.5, maxStress: 5)], yield: 50)
        var prev = -1.0
        for mpa in stride(from: 0.0, through: 100.0, by: 2.5) {
            let f = m.stressFraction(mpa: mpa)
            XCTAssertGreaterThanOrEqual(f, prev)      // monotone non-decreasing in stress
            XCTAssertGreaterThanOrEqual(f, 0)
            XCTAssertLessThanOrEqual(f, 1)            // clamped into [0, 1]
            prev = f
        }
        XCTAssertEqual(m.stressFraction(mpa: 25), 0.5, accuracy: 1e-9)   // half of yield 50
    }

    func testStressScaleUnchangedBySelectionAndStreaming() {
        // Keyed to the material limit, the scale is a constant — picking a tab or a
        // heavier variant streaming in never rescales the colors.
        let m = yieldModel([variant(vf: 0.7, maxStress: 8), variant(vf: 0.5, maxStress: 40)], yield: 55)
        XCTAssertEqual(m.stressScaleMaxMPa, 55, accuracy: 1e-9)
        m.select(0); XCTAssertEqual(m.stressScaleMaxMPa, 55, accuracy: 1e-9)
        m.select(1); XCTAssertEqual(m.stressScaleMaxMPa, 55, accuracy: 1e-9)
        m.update(from: outcome([variant(vf: 0.7, maxStress: 8), variant(vf: 0.5, maxStress: 40),
                                variant(vf: 0.3, maxStress: 99)]))
        XCTAssertEqual(m.stressScaleMaxMPa, 55, accuracy: 1e-9)   // 99 > 55 does not move the scale
    }

    func testStressLegendStatesMaterialAndYield() {
        let m = yieldModel([variant(vf: 0.5, maxStress: 10)], yield: 55, material: "PLA")
        let legend = m.stressLegend
        XCTAssertTrue(legend.scaledToYield)
        XCTAssertEqual(legend.yieldStrengthMPa, 55, accuracy: 1e-9)
        XCTAssertTrue(legend.caption.contains("PLA"))    // names the material
        XCTAssertTrue(legend.caption.contains("55"))     // states the yield value
        XCTAssertTrue(legend.caption.contains("MPa"))
        XCTAssertTrue(legend.maxLabel.contains("55"))
        XCTAssertEqual(legend.minLabel, "0")
    }

    func testStressLegendFallsBackWhenNoMaterialYield() {
        // No material limit → the scale degrades to the data range and the legend is
        // honest that it is a relative scale (not keyed to yield).
        let m = ResultsModel(projectName: "P", outcome: outcome([
            variant(vf: 0.7, maxStress: 8), variant(vf: 0.5, maxStress: 20),
        ]))
        XCTAssertEqual(m.stressScaleMaxMPa, 20, accuracy: 1e-9)   // data-range fallback
        XCTAssertFalse(m.stressLegend.scaledToYield)
    }

    // MARK: optimization-history playback (keyframes)

    func testKeyframeIndexMapping() {
        XCTAssertEqual(ResultsModel.keyframeIndex(playT: 0, count: 10), 0)     // start
        XCTAssertEqual(ResultsModel.keyframeIndex(playT: 1, count: 10), 9)     // optimized end
        XCTAssertEqual(ResultsModel.keyframeIndex(playT: 0.5, count: 11), 5)   // middle
        XCTAssertEqual(ResultsModel.keyframeIndex(playT: -1, count: 10), 0)    // clamp low
        XCTAssertEqual(ResultsModel.keyframeIndex(playT: 2, count: 10), 9)     // clamp high
        XCTAssertEqual(ResultsModel.keyframeIndex(playT: 0.5, count: 1), 0)    // single frame
        XCTAssertEqual(ResultsModel.keyframeIndex(playT: 0.5, count: 0), 0)    // no frames
    }

    func testHistoryPlaybackSelectsKeyframes() {
        let v = OptimizeVariant(
            requestedVolumeFraction: 0.5, achievedVolumeFraction: 0.5, massGrams: 100,
            supportVolumeVoxels: 0, meshTriangleCount: 1, worstCaseMargin: 2,
            accepted: true, v3Passes: true, maxStressMPa: 10,
            keyframeMeshes: [
                KeyframeMesh(vertices: [0, 0, 0, 1, 0, 0, 0, 1, 0], indices: [0, 1, 2]),
                KeyframeMesh(vertices: [0, 0, 1, 1, 0, 1, 0, 1, 1], indices: [0, 1, 2]),
            ])
        let m = ResultsModel(projectName: "P", outcome: outcome([v]))
        XCTAssertTrue(m.hasHistory)
        XCTAssertEqual(m.keyframes().count, 2)
        m.scrub(to: 0); XCTAssertNotNil(m.playbackMesh)          // ~solid start
        m.scrub(to: 1); XCTAssertNotNil(m.playbackMesh)          // optimized end

        // A variant with no keyframes has no history.
        let plain = ResultsModel(projectName: "P", outcome: outcome([variant(vf: 0.5)]))
        XCTAssertFalse(plain.hasHistory)
        XCTAssertNil(plain.playbackMesh)
    }

    // MARK: stress field sampling (grid index (k*ny+j)*nx+i, matches core)

    func testStressFieldSamplingMatchesGridIndex() {
        // NON-cubic 2×3×4 grid (distinct dims so index order matters — a cubic grid
        // can't tell (k*ny+j)*nx+i from a transposed formula), unit voxels at origin;
        // value == the field index.
        let vals = (0..<(2 * 3 * 4)).map { Float($0) }
        let f = StressField(nx: 2, ny: 3, nz: 4, origin: .zero, spacing: 1, values: vals)
        // idx = (k*ny + j)*nx + i.
        XCTAssertEqual(f.value(at: SIMD3(0.5, 0.5, 0.5)), 0)    // (0,0,0) -> 0
        XCTAssertEqual(f.value(at: SIMD3(1.5, 0.5, 0.5)), 1)    // (1,0,0) -> 1
        XCTAssertEqual(f.value(at: SIMD3(0.5, 1.5, 0.5)), 2)    // (0,1,0) -> 2
        XCTAssertEqual(f.value(at: SIMD3(0.5, 0.5, 1.5)), 6)    // (0,0,1) -> (1*3+0)*2+0 = 6
        XCTAssertEqual(f.value(at: SIMD3(1.5, 2.5, 0.5)), 5)    // (1,2,0) -> (0*3+2)*2+1 = 5
        XCTAssertEqual(f.value(at: SIMD3(1.5, 2.5, 3.5)), 23)   // (1,2,3) -> (3*3+2)*2+1 = 23
        XCTAssertEqual(f.value(at: SIMD3(99, 99, 99)), 23)      // clamps to (1,2,3) -> 23
    }

    func testStressFieldEmptyIsZero() {
        XCTAssertTrue(StressField(nx: 0, ny: 0, nz: 0, origin: .zero, spacing: 0, values: []).isEmpty)
        XCTAssertEqual(StressField(nx: 2, ny: 2, nz: 2, origin: .zero, spacing: 1, values: []).value(at: .zero), 0)
    }

    func testStressTintsPerFlatVertexColored() {
        // Shared scale 10 (from the variant), a triangle with a vertex in each of
        // three voxels holding 0 / 10 / 5 → blue / red / green.
        let m = ResultsModel(projectName: "P", outcome: outcome([variant(vf: 0.5, maxStress: 10)]))
        let mesh = ViewerMesh(vertices: [0.5, 0.5, 0.5,  1.5, 0.5, 0.5,  0.5, 1.5, 0.5],
                              indices: [0, 1, 2], faceIDs: [])
        let field = StressField(nx: 2, ny: 2, nz: 2, origin: .zero, spacing: 1,
                                values: [0, 10, 5, 0, 0, 0, 0, 0])
        let tints = m.stressTints(for: mesh, field: field)
        XCTAssertEqual(tints.count, mesh.flat.vertexCount)   // one per flat vertex
        XCTAssertEqual(tints[0], SIMD4<Float>(Float(RGBA(28, 60, 170).r), Float(RGBA(28, 60, 170).g), Float(RGBA(28, 60, 170).b), 1))   // frac 0
        XCTAssertGreaterThan(tints[1].x, 0.9)               // frac 1 → red (high R)
        XCTAssertLessThan(tints[1].z, 0.3)                  //         low B
        XCTAssertEqual(tints.allSatisfy { $0.w == 1 }, true) // opaque
    }

    // MARK: hot-spot callout (M7.viz.2 — the single worst-stress point)

    /// An outcome whose single accepted variant carries `field` on a `dims` grid at
    /// unit spacing from the origin (so voxel (i,j,k)'s center is (i+0.5, j+0.5, k+0.5)).
    private func fieldedOutcome(_ field: [Float], dims: (Int, Int, Int),
                                maxStress: Double) -> OptimizeOutcome {
        let v = OptimizeVariant(
            requestedVolumeFraction: 0.5, achievedVolumeFraction: 0.5, massGrams: 100,
            supportVolumeVoxels: 0, meshTriangleCount: 1, worstCaseMargin: 2, accepted: true,
            v3Passes: true, maxStressMPa: maxStress,
            meshVertices: [0, 0, 0, 1, 0, 0, 0, 1, 0], meshIndices: [0, 1, 2], vonMisesField: field)
        return OptimizeOutcome(variants: [v], stoppedOnMargin: false, cancelled: false,
                               acceptedCount: 1, voxelVolumeMM3: 1,
                               gridNx: dims.0, gridNy: dims.1, gridNz: dims.2,
                               gridOrigin: .zero, spacing: 1)
    }

    func testStressFieldPeakArgmaxAndPosition() {
        // 2×3×4 grid, values == index → the max is the last voxel (idx 23 == (1,2,3)).
        let vals = (0..<(2 * 3 * 4)).map { Float($0) }
        let f = StressField(nx: 2, ny: 3, nz: 4, origin: .zero, spacing: 1, values: vals)
        let peak = f.peak()
        XCTAssertEqual(peak?.index, 23)                          // matches the field's max index
        XCTAssertEqual(peak?.valueMPa, 23)
        XCTAssertEqual(peak?.position, SIMD3<Float>(1.5, 2.5, 3.5))   // voxel (1,2,3) center
    }

    func testStressFieldPeakLocatesInteriorMaxWithOriginAndSpacing() {
        // Max at a NON-terminal index on a non-cubic grid (proves argmax, not "last"),
        // with a non-zero origin + spacing so the world-center math is exercised.
        var vals = [Float](repeating: 1, count: 2 * 3 * 4)
        vals[5] = 99                                             // idx 5 -> (i,j,k)=(1,2,0)
        let f = StressField(nx: 2, ny: 3, nz: 4, origin: SIMD3(10, 20, 30), spacing: 2, values: vals)
        let peak = f.peak()
        XCTAssertEqual(peak?.index, 5)
        XCTAssertEqual(peak?.valueMPa, 99)
        // center = origin + (i+0.5, j+0.5, k+0.5) * spacing.
        XCTAssertEqual(peak?.position, SIMD3<Float>(10 + 1.5 * 2, 20 + 2.5 * 2, 30 + 0.5 * 2))
    }

    func testStressFieldPeakNilWhenEmptyOrAllZero() {
        XCTAssertNil(StressField(nx: 0, ny: 0, nz: 0, origin: .zero, spacing: 0, values: []).peak())
        XCTAssertNil(StressField(nx: 2, ny: 2, nz: 2, origin: .zero, spacing: 1,
                                 values: [Float](repeating: 0, count: 8)).peak())   // no stress → no hot spot
    }

    func testHotSpotValueAndMarginAgainstYield() {
        // Field peaks at 24 MPa; yield 55 → margin = value ÷ yield = 24/55 (~44%).
        var field = [Float](repeating: 2, count: 8)
        field[6] = 24
        let m = ResultsModel(projectName: "P",
                             outcome: fieldedOutcome(field, dims: (2, 2, 2), maxStress: 24),
                             materialName: "PLA", yieldStrengthMPa: 55)
        let hs = m.hotSpot
        XCTAssertNotNil(hs)
        XCTAssertEqual(hs?.fieldIndex, 6)                        // located max == field argmax
        XCTAssertEqual(hs?.valueMPa ?? 0, 24, accuracy: 1e-6)
        XCTAssertEqual(hs?.margin ?? 0, 24.0 / 55.0, accuracy: 1e-9)   // value ÷ yield
        XCTAssertTrue(hs?.valueLabel.contains("24") ?? false)
        XCTAssertTrue(hs?.marginLabel.contains("44") ?? false)  // 24/55 rounds to 44% of yield
    }

    func testHotSpotMarginAtOrAboveYield() {
        // A peak over yield → margin > 1 and the label reads at/above the limit.
        var field = [Float](repeating: 1, count: 8)
        field[0] = 60                                            // above yield 55
        let m = ResultsModel(projectName: "P",
                             outcome: fieldedOutcome(field, dims: (2, 2, 2), maxStress: 60),
                             materialName: "PLA", yieldStrengthMPa: 55)
        XCTAssertGreaterThan(m.hotSpot?.margin ?? 0, 1)
        XCTAssertTrue(m.hotSpot?.marginLabel.lowercased().contains("yield") ?? false)
    }

    func testHotSpotWithoutMaterialYield() {
        // No material limit: the point is still located, but there is no margin to
        // state (honest fallback — not a % of yield).
        var field = [Float](repeating: 1, count: 8)
        field[3] = 12
        let m = ResultsModel(projectName: "P",
                             outcome: fieldedOutcome(field, dims: (2, 2, 2), maxStress: 12))
        let hs = m.hotSpot
        XCTAssertNotNil(hs)
        XCTAssertEqual(hs?.valueMPa ?? 0, 12, accuracy: 1e-6)
        XCTAssertEqual(hs?.margin ?? -1, 0, accuracy: 1e-9)      // no yield → no margin
        XCTAssertFalse(hs?.marginLabel.contains("%") ?? true)
    }

    func testHotSpotNilWithoutStressField() {
        // The plain variant() helper carries no vonMisesField / grid → nothing to call out.
        let m = yieldModel([variant(vf: 0.5, maxStress: 10)], yield: 55)
        XCTAssertNil(m.hotSpot)
    }

    func testHotSpotTracksSelectedVariant() {
        // Two accepted variants with different peak locations; the hot spot follows
        // whichever variant is displayed.
        var fA = [Float](repeating: 0, count: 8); fA[1] = 30
        var fB = [Float](repeating: 0, count: 8); fB[7] = 45
        let a = OptimizeVariant(
            requestedVolumeFraction: 0.7, achievedVolumeFraction: 0.7, massGrams: 100,
            supportVolumeVoxels: 0, meshTriangleCount: 1, worstCaseMargin: 2, accepted: true,
            v3Passes: true, maxStressMPa: 30,
            meshVertices: [0, 0, 0, 1, 0, 0, 0, 1, 0], meshIndices: [0, 1, 2], vonMisesField: fA)
        let b = OptimizeVariant(
            requestedVolumeFraction: 0.5, achievedVolumeFraction: 0.5, massGrams: 80,
            supportVolumeVoxels: 0, meshTriangleCount: 1, worstCaseMargin: 2, accepted: true,
            v3Passes: true, maxStressMPa: 45,
            meshVertices: [0, 0, 0, 1, 0, 0, 0, 1, 0], meshIndices: [0, 1, 2], vonMisesField: fB)
        let out = OptimizeOutcome(variants: [a, b], stoppedOnMargin: false, cancelled: false,
                                  acceptedCount: 2, voxelVolumeMM3: 1, gridNx: 2, gridNy: 2, gridNz: 2,
                                  gridOrigin: .zero, spacing: 1)
        let m = ResultsModel(projectName: "P", outcome: out, materialName: "PLA", yieldStrengthMPa: 55)
        // Default selection is the recommended lightest variant (index 1 → variant b).
        XCTAssertEqual(m.hotSpot?.fieldIndex, 7)
        XCTAssertEqual(m.hotSpot?.valueMPa ?? 0, 45, accuracy: 1e-6)
        m.select(0)
        XCTAssertEqual(m.hotSpot?.fieldIndex, 1)
        XCTAssertEqual(m.hotSpot?.valueMPa ?? 0, 30, accuracy: 1e-6)
    }

    func testSelectedMeshAndFieldFromVariant() {
        var v = variant(vf: 0.5, maxStress: 10)
        v = OptimizeVariant(
            requestedVolumeFraction: 0.5, achievedVolumeFraction: 0.5, massGrams: 100,
            supportVolumeVoxels: 0, meshTriangleCount: 1, worstCaseMargin: 2, accepted: true,
            v3Passes: true, orientation: SIMD3(0, 0, 1), maxStressMPa: 10,
            meshVertices: [0, 0, 0, 1, 0, 0, 0, 1, 0], meshIndices: [0, 1, 2],
            vonMisesField: [1, 2, 3, 4, 5, 6, 7, 8])
        let out = OptimizeOutcome(variants: [v], stoppedOnMargin: false, cancelled: false,
                                  acceptedCount: 1, voxelVolumeMM3: 1,
                                  gridNx: 2, gridNy: 2, gridNz: 2, gridOrigin: .zero, spacing: 1)
        let m = ResultsModel(projectName: "P", outcome: out)
        XCTAssertEqual(m.selectedMesh?.triangleCount, 1)
        XCTAssertEqual(m.selectedStressField?.values.count, 8)
        XCTAssertEqual(m.selectedStressField?.nx, 2)
    }

    // MARK: - M7.viz.3 flex animation

    private func assertClose(_ a: SIMD3<Float>, _ b: SIMD3<Float>,
                             accuracy: Float = 1e-5, _ msg: String = "", file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(a.x, b.x, accuracy: accuracy, msg, file: file, line: line)
        XCTAssertEqual(a.y, b.y, accuracy: accuracy, msg, file: file, line: line)
        XCTAssertEqual(a.z, b.z, accuracy: accuracy, msg, file: file, line: line)
    }

    // MARK: DisplacementField (per-node sampling)

    func testDisplacementFieldSamplesNearestNode() {
        // 1-voxel grid: 2×2×2 = 8 nodes. Displace only node (1,1,1) (index 7) by +Y 0.1.
        var vals = [Float](repeating: 0, count: 24)
        vals[7 * 3 + 1] = 0.1
        let f = DisplacementField(nx: 1, ny: 1, nz: 1, origin: .zero, spacing: 1, values: vals)
        XCTAssertFalse(f.isEmpty)
        XCTAssertEqual(f.nodeCount, 8)
        assertClose(f.displacement(at: SIMD3(0, 0, 0)), .zero)
        assertClose(f.displacement(at: SIMD3(1, 1, 1)), SIMD3<Float>(0, 0.1, 0))
        // A point nearer node (1,1,1) rounds to it (nearest-node — mesh verts sit on corners).
        assertClose(f.displacement(at: SIMD3(0.9, 0.9, 0.9)), SIMD3<Float>(0, 0.1, 0))
        // Non-zero origin + spacing: node (1,1,1) is at origin+(spacing,spacing,spacing).
        let g = DisplacementField(nx: 1, ny: 1, nz: 1, origin: SIMD3(10, 20, 30), spacing: 2, values: vals)
        assertClose(g.displacement(at: SIMD3(12, 22, 32)), SIMD3<Float>(0, 0.1, 0))
        assertClose(g.displacement(at: SIMD3(10, 20, 30)), .zero)
    }

    func testDisplacementFieldEmptyRaggedAndOutOfRange() {
        XCTAssertTrue(DisplacementField(nx: 1, ny: 1, nz: 1, origin: .zero, spacing: 1, values: []).isEmpty)
        // A too-short field (< 3·nodeCount) is treated as empty (safety, no OOB read).
        XCTAssertTrue(DisplacementField(nx: 1, ny: 1, nz: 1, origin: .zero, spacing: 1, values: [0, 0, 0]).isEmpty)
        XCTAssertTrue(DisplacementField(nx: 0, ny: 0, nz: 0, origin: .zero, spacing: 1, values: [Float](repeating: 0, count: 3)).isEmpty)
        // An out-of-range point clamps into range and reads a valid (zero) node, no trap.
        let f = DisplacementField(nx: 1, ny: 1, nz: 1, origin: .zero, spacing: 1, values: [Float](repeating: 0, count: 24))
        assertClose(f.displacement(at: SIMD3(100, 100, 100)), .zero)
    }

    // MARK: FlexAnimation (pure math)

    func testFlexAmplitudeIsRestFullRest() {
        XCTAssertEqual(FlexAnimation.amplitude(phase: 0), 0, accuracy: 1e-9)    // rest
        XCTAssertEqual(FlexAnimation.amplitude(phase: 0.5), 1, accuracy: 1e-9)  // full deflection
        XCTAssertEqual(FlexAnimation.amplitude(phase: 1), 0, accuracy: 1e-9)    // back to rest
        // Non-decreasing from rest to full, and always in [0,1].
        var prev = -1.0
        for i in 0...50 {
            let a = FlexAnimation.amplitude(phase: Double(i) / 100)   // phase 0 → 0.5
            XCTAssertGreaterThanOrEqual(a, -1e-9)
            XCTAssertLessThanOrEqual(a, 1 + 1e-9)
            XCTAssertGreaterThanOrEqual(a, prev - 1e-9)
            prev = a
        }
    }

    func testFlexExaggerationClampAndDefaultInBand() {
        XCTAssertEqual(FlexAnimation.clampExaggeration(10), 50)   // below → min
        XCTAssertEqual(FlexAnimation.clampExaggeration(75), 75)   // inside → unchanged
        XCTAssertEqual(FlexAnimation.clampExaggeration(999), 100) // above → max
        XCTAssertGreaterThanOrEqual(FlexAnimation.defaultExaggeration, FlexAnimation.minExaggeration)
        XCTAssertLessThanOrEqual(FlexAnimation.defaultExaggeration, FlexAnimation.maxExaggeration)
    }

    func testFlexDisplacedPositionScalesLinearly() {
        let base = SIMD3<Float>(1, 2, 3), d = SIMD3<Float>(0, 0.1, 0)
        // Amplitude 0 → rest (exactly the base position, no move).
        assertClose(FlexAnimation.displacedPosition(base: base, displacement: d, exaggeration: 60, amplitude: 0), base)
        // Amplitude 1 → full deflection = base + exaggeration·d.
        assertClose(FlexAnimation.displacedPosition(base: base, displacement: d, exaggeration: 60, amplitude: 1),
                    base + 60 * d)
        // Linear in exaggeration: doubling the factor doubles the offset from base.
        let a = FlexAnimation.displacedPosition(base: .zero, displacement: d, exaggeration: 50, amplitude: 1)
        let b = FlexAnimation.displacedPosition(base: .zero, displacement: d, exaggeration: 100, amplitude: 1)
        assertClose(b, 2 * a)
        // Linear in amplitude: half amplitude = half the full-deflection offset.
        let half = FlexAnimation.displacedPosition(base: .zero, displacement: d, exaggeration: 80, amplitude: 0.5)
        assertClose(half, 40 * d)
    }

    // MARK: ResultsModel flex state

    /// A single-triangle variant whose third vertex sits on node (1,1,1); a 1-voxel
    /// grid whose node (1,1,1) is displaced +Y 0.1. So the flex buffer is non-trivial.
    @MainActor private func flexModel() -> ResultsModel {
        var vals = [Float](repeating: 0, count: 24)
        vals[7 * 3 + 1] = 0.1   // node (1,1,1) = index 7, +Y 0.1 mm
        let v = OptimizeVariant(
            requestedVolumeFraction: 0.5, achievedVolumeFraction: 0.5, massGrams: 10,
            supportVolumeVoxels: 0, meshTriangleCount: 1, worstCaseMargin: 2, accepted: true,
            v3Passes: true, orientation: SIMD3(0, 0, 1), maxStressMPa: 10,
            meshVertices: [0, 0, 0, 1, 0, 0, 1, 1, 1], meshIndices: [0, 1, 2],
            vonMisesField: [1], displacementField: vals)
        let out = OptimizeOutcome(variants: [v], stoppedOnMargin: false, cancelled: false,
                                  acceptedCount: 1, voxelVolumeMM3: 1,
                                  gridNx: 1, gridNy: 1, gridNz: 1, gridOrigin: .zero, spacing: 1)
        return ResultsModel(projectName: "P", outcome: out)
    }

    @MainActor func testHasFlexReflectsDisplacementField() {
        XCTAssertTrue(flexModel().hasFlex)
        // A variant with no displacement field (default []) cannot flex.
        let m = ResultsModel(projectName: "P", outcome: outcome([variant(vf: 0.5)]))
        XCTAssertFalse(m.hasFlex)
        XCTAssertTrue(m.selectedDisplacementField?.isEmpty ?? true)
    }

    @MainActor func testFlexToggleResetsPhaseAndClampsExaggeration() {
        let m = flexModel()
        XCTAssertFalse(m.flexOn)
        m.toggleFlex(); XCTAssertTrue(m.flexOn)
        m.setFlexExaggeration(5);   XCTAssertEqual(m.flexExaggeration, 50)   // clamped up
        m.setFlexExaggeration(500); XCTAssertEqual(m.flexExaggeration, 100)  // clamped down
        m.setFlexExaggeration(72);  XCTAssertEqual(m.flexExaggeration, 72)
        m.advanceFlex(0.3)
        XCTAssertEqual(m.flexPhase, 0.3, accuracy: 1e-9)
        m.toggleFlex()                                   // off → loop resets to rest
        XCTAssertFalse(m.flexOn)
        XCTAssertEqual(m.flexPhase, 0, accuracy: 1e-9)
    }

    @MainActor func testFlexAmplitudeAndScaleWithReduceMotion() {
        let m = flexModel()
        m.setFlexExaggeration(60)
        // Off → amplitude/scale are 0 regardless of reduced-motion.
        XCTAssertEqual(m.flexAmplitude(reduceMotion: false), 0, accuracy: 1e-9)
        XCTAssertEqual(m.flexAmplitude(reduceMotion: true), 0, accuracy: 1e-9)
        XCTAssertEqual(m.flexScale(reduceMotion: false), 0, accuracy: 1e-6)

        m.toggleFlex()   // on, phase 0 = rest
        XCTAssertEqual(m.flexAmplitude(reduceMotion: false), 0, accuracy: 1e-9)  // animated: rest frame
        XCTAssertEqual(m.flexScale(reduceMotion: false), 0, accuracy: 1e-6)
        // Reduced-motion pins the STATIC full-deflection frame (amplitude 1) at any phase.
        XCTAssertEqual(m.flexAmplitude(reduceMotion: true), 1, accuracy: 1e-9)
        XCTAssertEqual(m.flexScale(reduceMotion: true), 60, accuracy: 1e-5)
        // Advancing to phase 0.5 reaches full deflection when animated.
        m.advanceFlex(0.5)
        XCTAssertEqual(m.flexAmplitude(reduceMotion: false), 1, accuracy: 1e-9)
        XCTAssertEqual(m.flexScale(reduceMotion: false), 60, accuracy: 1e-5)
    }

    @MainActor func testAdvanceFlexWrapsAndIsNoOpWhenOff() {
        let m = flexModel()
        m.advanceFlex(0.4)                                  // off → ignored
        XCTAssertEqual(m.flexPhase, 0, accuracy: 1e-9)
        m.toggleFlex()
        m.advanceFlex(0.7); m.advanceFlex(0.7)              // 1.4 wraps to 0.4
        XCTAssertEqual(m.flexPhase, 0.4, accuracy: 1e-9)
    }

    @MainActor func testFlexDisplacementsBufferRestAndFullFrames() {
        let m = flexModel()
        let mesh = try! XCTUnwrap(m.selectedMesh)
        let field = try! XCTUnwrap(m.selectedDisplacementField)
        let disp = m.flexDisplacements(for: mesh, field: field)
        // One xyz per flat vertex (3 for a single triangle).
        XCTAssertEqual(disp.count, mesh.flat.vertexCount * 3)
        // The only displaced node is (1,1,1) with +Y 0.1; the vertex sitting there carries it.
        let maxY = stride(from: 1, to: disp.count, by: 3).map { disp[$0] }.max() ?? 0
        XCTAssertEqual(maxY, 0.1, accuracy: 1e-6)
        // The rest frame (amplitude 0) moves nothing; the full-deflection frame
        // (exaggeration 60 · amplitude 1) moves that corner 6 mm.
        for i in stride(from: 0, to: disp.count, by: 3) {
            let d = SIMD3<Float>(disp[i], disp[i + 1], disp[i + 2])
            assertClose(FlexAnimation.displacedPosition(base: .zero, displacement: d, exaggeration: 60, amplitude: 0), .zero)
        }
        XCTAssertEqual(maxY * 60, 6, accuracy: 1e-4)
        // Cached: the same array instance content is returned on re-query for the selection.
        XCTAssertEqual(m.flexDisplacements(for: mesh, field: field), disp)
    }

    // MARK: failure-load prediction (M7.viz.6 — "push it till it breaks")

    /// A variant carrying a von Mises field peaking at `peak` (one voxel) plus, when
    /// `withFlex`, a displacement field, on a 1×1×1 grid — so `hotSpot`/`peak` and the
    /// applied load drive the failure prediction. Yield/applied-load/unit/infill are
    /// the M7.viz.6 inputs threaded into the model.
    @MainActor private func failureModel(appliedLoadKg: Double = 2.5, unit: WeightUnit = .kg,
                                         infillPercent: Int = 100, peak: Float = 20,
                                         yield: Double = 60, withFlex: Bool = true) -> ResultsModel {
        var disp = [Float](repeating: 0, count: 24)
        disp[7 * 3 + 1] = 0.1                                   // node (1,1,1) +Y 0.1 mm
        let v = OptimizeVariant(
            requestedVolumeFraction: 0.5, achievedVolumeFraction: 0.5, massGrams: 10,
            supportVolumeVoxels: 0, meshTriangleCount: 1, worstCaseMargin: 2, accepted: true,
            v3Passes: true, orientation: SIMD3(0, 0, 1), maxStressMPa: Double(peak),
            meshVertices: [0, 0, 0, 1, 0, 0, 1, 1, 1], meshIndices: [0, 1, 2],
            vonMisesField: [peak], displacementField: withFlex ? disp : [])
        let out = OptimizeOutcome(variants: [v], stoppedOnMargin: false, cancelled: false,
                                  acceptedCount: 1, voxelVolumeMM3: 1,
                                  gridNx: 1, gridNy: 1, gridNz: 1, gridOrigin: .zero, spacing: 1)
        return ResultsModel(projectName: "P", outcome: out, materialName: "PLA",
                            yieldStrengthMPa: yield, appliedLoadKg: appliedLoadKg,
                            loadUnit: unit, infillPercent: infillPercent)
    }

    @MainActor func testFailureMultiplierAndLoadFromPeakYieldAndAppliedLoad() {
        // peak 20, yield 60 → multiplier 3; applied 2.5 kg → failure load 7.5 kg. The
        // failure LOCATION is the hot spot (the peak voxel's center on a 1³ grid).
        let m = failureModel(appliedLoadKg: 2.5, peak: 20, yield: 60)
        let fp = try! XCTUnwrap(m.failurePrediction)
        XCTAssertEqual(fp.multiplier, 3, accuracy: 1e-9)
        XCTAssertEqual(fp.appliedLoadKg, 2.5, accuracy: 1e-9)
        XCTAssertEqual(fp.failureLoadKg, 7.5, accuracy: 1e-9)
        XCTAssertEqual(fp.position, SIMD3<Float>(0.5, 0.5, 0.5))    // == the viz.2 hot spot
        XCTAssertEqual(fp.fieldIndex, m.hotSpot?.fieldIndex)
        XCTAssertEqual(fp.solidValueLabel, "7.5 kg")
        XCTAssertEqual(fp.headline, "Holds ~7.5 kg")
        XCTAssertTrue(fp.subtitle.lowercased().contains("solid-print"))
    }

    @MainActor func testFailureLoadInEachUnit() {
        // 7.5 kg in kg → "7.5 kg"; in lbs → 16.5 lb → "17 lbs" (≥10 rounds to integer).
        XCTAssertEqual(failureModel(unit: .kg).failurePrediction?.solidValueLabel, "7.5 kg")
        XCTAssertEqual(failureModel(unit: .lbs).failurePrediction?.solidValueLabel, "17 lbs")
        // A design-scale case: 10 kg applied, peak 4 / yield 60 → ×15 → 150 kg → 331 lb.
        let big = failureModel(appliedLoadKg: 10, unit: .lbs, peak: 4, yield: 60)
        XCTAssertEqual(big.failurePrediction?.failureLoadKg ?? 0, 150, accuracy: 1e-6)
        XCTAssertEqual(big.failurePrediction?.solidValueLabel, "331 lbs")
    }

    @MainActor func testFailureLoadLabelFormatting() {
        XCTAssertEqual(ResultsModel.loadLabel(kg: 7.5, unit: .kg), "7.5 kg")
        XCTAssertEqual(ResultsModel.loadLabel(kg: 154.2, unit: .kg), "154 kg")
        XCTAssertEqual(ResultsModel.loadLabel(kg: 7.5, unit: .lbs), "17 lbs")   // 16.5 → 17
        XCTAssertEqual(ResultsModel.loadLabel(kg: 0.67, unit: .kg), "0.7 kg")
    }

    @MainActor func testFailureInfillAdjustedUsesGibsonAshbyKnockdown() {
        // infill 20% → knockdown 0.2^1.5 ≈ 0.0894; 7.5 kg × 0.0894 ≈ 0.67 kg.
        let m = failureModel(infillPercent: 20)
        let fp = try! XCTUnwrap(m.failurePrediction)
        XCTAssertEqual(fp.infillPercent, 20)
        XCTAssertEqual(fp.infillKnockdown, pow(0.2, 1.5), accuracy: 1e-12)
        XCTAssertEqual(try XCTUnwrap(fp.infillFailureLoadKg), 7.5 * pow(0.2, 1.5), accuracy: 1e-9)
        XCTAssertEqual(fp.infillValueLabel, "0.7 kg")
        XCTAssertEqual(fp.infillNote, "≈ 0.7 kg at 20% infill")
        XCTAssertLessThan(try XCTUnwrap(fp.infillFailureLoadKg), fp.failureLoadKg)   // weaker than solid
    }

    @MainActor func testFailureNoInfillEstimateWhenSolid() {
        // 100% (solid, the default) and any out-of-range value → no separate estimate.
        for pct in [100, 0, 150] {
            let fp = try! XCTUnwrap(failureModel(infillPercent: pct).failurePrediction)
            XCTAssertNil(fp.infillPercent)
            XCTAssertNil(fp.infillFailureLoadKg)
            XCTAssertNil(fp.infillNote)
            XCTAssertEqual(fp.infillKnockdown, 1, accuracy: 1e-12)
        }
    }

    @MainActor func testFailurePredictionNilOnMissingInputs() {
        // Degrade gracefully: no applied load, no yield, or no stress → no prediction.
        XCTAssertNil(failureModel(appliedLoadKg: 0).failurePrediction)          // no user load
        XCTAssertNil(failureModel(yield: 0).failurePrediction)                  // no material limit
        XCTAssertNil(failureModel(peak: 0).failurePrediction)                   // no stress to peak
        // No stress field at all (plain variant) → nil, toggle stays hidden.
        let plain = ResultsModel(projectName: "P", outcome: outcome([variant(vf: 0.5)]),
                                 materialName: "PLA", yieldStrengthMPa: 60, appliedLoadKg: 2.5)
        XCTAssertNil(plain.failurePrediction)
        XCTAssertFalse(plain.hasFailurePrediction)
    }

    func testInfillKnockdownMatchesCoreCurve() {
        // MUST match core minimize_plastic.cpp infill_margin_knockdown (Gibson-Ashby
        // f^1.5, exact 1.0 at ≥100, floored at 1e-3) so the two features agree.
        XCTAssertEqual(FailureLoad.infillKnockdown(percent: 100), 1)
        XCTAssertEqual(FailureLoad.infillKnockdown(percent: 130), 1)
        XCTAssertEqual(FailureLoad.infillKnockdown(percent: 0), 1e-3)
        XCTAssertEqual(FailureLoad.infillKnockdown(percent: -5), 1e-3)
        XCTAssertEqual(FailureLoad.infillKnockdown(percent: 20), pow(0.2, 1.5), accuracy: 1e-12)
        XCTAssertEqual(FailureLoad.infillKnockdown(percent: 50), pow(0.5, 1.5), accuracy: 1e-12)
        XCTAssertLessThan(FailureLoad.infillKnockdown(percent: 40),
                          FailureLoad.infillKnockdown(percent: 60))   // monotonic in infill
    }

    func testFailureMultiplierGuards() {
        XCTAssertEqual(FailureLoad.multiplier(peakMPa: 20, yieldMPa: 60), 3)
        XCTAssertNil(FailureLoad.multiplier(peakMPa: 0, yieldMPa: 60))
        XCTAssertNil(FailureLoad.multiplier(peakMPa: 20, yieldMPa: 0))
        XCTAssertNil(FailureLoad.multiplier(peakMPa: -1, yieldMPa: 60))
    }

    func testPushExaggerationProportionalAndBounded() {
        // Proportional to load, reaching the legible max at failure, bounded above it.
        XCTAssertEqual(FailureLoad.pushExaggeration(pushFactor: 3, multiplier: 3),
                       FlexAnimation.maxExaggeration)                 // at failure → max
        XCTAssertEqual(FailureLoad.pushExaggeration(pushFactor: 1, multiplier: 3),
                       FlexAnimation.maxExaggeration / 3, accuracy: 1e-3)   // 1× is proportional
        XCTAssertEqual(FailureLoad.pushExaggeration(pushFactor: 9, multiplier: 3),
                       FlexAnimation.maxExaggeration)                 // clamped above failure
        XCTAssertGreaterThan(FailureLoad.pushExaggeration(pushFactor: 2, multiplier: 3),
                             FailureLoad.pushExaggeration(pushFactor: 1, multiplier: 3))
        XCTAssertEqual(FailureLoad.pushExaggeration(pushFactor: 1, multiplier: 0), 0)   // degenerate
    }

    @MainActor func testPushScrubClampAtFailureAndScale() {
        let m = failureModel(peak: 20, yield: 60)                     // multiplier 3
        m.toggleFailure()
        XCTAssertTrue(m.failureOn)
        XCTAssertTrue(m.pushActive)                                   // has a displacement field
        XCTAssertEqual(m.pushFactor, 1, accuracy: 1e-9)              // starts at the current load
        XCTAssertFalse(m.atFailure)
        m.setPush(factor: 2)
        XCTAssertEqual(m.pushFactor, 2, accuracy: 1e-9)
        XCTAssertEqual(m.pushFlexScale(), FlexAnimation.maxExaggeration * 2 / 3, accuracy: 1e-3)
        m.setPush(factor: 99)                                         // clamps to the multiplier
        XCTAssertEqual(m.pushFactor, 3, accuracy: 1e-9)
        XCTAssertTrue(m.atFailure)
        XCTAssertEqual(m.pushFlexScale(), FlexAnimation.maxExaggeration, accuracy: 1e-4)
        m.setPush(factor: 0)                                          // clamps to ≥ 1
        XCTAssertEqual(m.pushFactor, 1, accuracy: 1e-9)
    }

    @MainActor func testPushScrubSweepMonotonicDeflectionAndYieldTrigger() {
        // M7.viz.6b acceptance, tested headlessly: as the user scrubs the push from 1×
        // up to the failure multiplier, (a) the rendered deflection scale STRICTLY
        // INCREASES at every step (the part visibly flexes more), and (b) the failure
        // region lights up (`atFailure`) EXACTLY at/above the multiplier — not before.
        let m = failureModel(peak: 20, yield: 60)                    // multiplier = 3
        m.toggleFailure()
        guard let mult = m.failurePrediction?.multiplier else {
            return XCTFail("prediction must exist for the sweep")
        }
        XCTAssertEqual(mult, 3, accuracy: 1e-9)
        // Sweep the scrub across [1, multiplier] and just past it.
        let steps = stride(from: 1.0, through: mult + 0.5, by: 0.25)
        var lastScale: Float = -1
        for f in steps {
            m.setPush(factor: f)
            let scale = m.pushFlexScale()
            if m.pushFactor < mult - 1e-6 {
                // Below yield: strictly more deflection than the previous (lower) step…
                XCTAssertGreaterThan(scale, lastScale, "deflection must grow as the scrub rises (f=\(f))")
                XCTAssertFalse(m.atFailure, "must NOT report yield below the multiplier (f=\(f))")
                lastScale = scale
            } else {
                // At/above yield: pinned at the legible max, and the failure region lights up.
                XCTAssertEqual(scale, FlexAnimation.maxExaggeration, accuracy: 1e-4)
                XCTAssertGreaterThanOrEqual(scale, lastScale)
                XCTAssertTrue(m.atFailure, "must report yield at/above the multiplier (f=\(f))")
            }
        }
        // The rendered deflection at failure is exactly the proportional multiple of the
        // 1× deflection (linear FEA): scale(mult) / scale(1) == mult.
        m.setPush(factor: 1)
        let base = m.pushFlexScale()
        m.setPush(factor: mult)
        XCTAssertEqual(m.pushFlexScale() / base, Float(mult), accuracy: 1e-3,
                       "on-screen deflection scales linearly with the push (∝ load)")
    }

    @MainActor func testPushReadoutReadsNaturallyAndFlipsAtYield() {
        // M7.viz.6b: the drag readout shows the live load + multiple, flipping to YIELDS
        // at the multiplier. appliedLoad 2 kg, multiplier 3 → failure load 6 kg.
        let m = failureModel(appliedLoadKg: 2, unit: .kg, peak: 20, yield: 60)
        guard let fp = m.failurePrediction else { return XCTFail("prediction required") }
        m.toggleFailure()
        m.setPush(factor: 1)
        XCTAssertEqual(m.pushReadout(prediction: fp), "2.0 kg · 1.0× load")
        m.setPush(factor: 2)
        XCTAssertEqual(m.pushReadout(prediction: fp), "4.0 kg · 2.0× load")   // live load tracks the scrub
        m.setPush(factor: 3)                                                  // == multiplier → yields
        XCTAssertTrue(m.atFailure)
        XCTAssertEqual(m.pushReadout(prediction: fp), "6.0 kg · 3.0× · YIELDS")
    }

    @MainActor func testPushDegradesGracefullyWithoutDisplacementField() {
        // No displacement field → still a prediction (number + marker), but no scrub.
        let m = failureModel(withFlex: false)
        XCTAssertNotNil(m.failurePrediction)
        XCTAssertTrue(m.hasFailurePrediction)
        XCTAssertFalse(m.hasFlex)
        m.toggleFailure()
        XCTAssertFalse(m.pushActive)                                 // scrub unavailable
        XCTAssertEqual(m.pushFlexScale(), 0)
    }

    @MainActor func testFailureMutuallyExclusiveWithFlexAndLoadPath() {
        let m = failureModel()
        m.toggleFlex()
        XCTAssertTrue(m.flexOn)
        m.toggleFailure()                                            // turning failure on…
        XCTAssertTrue(m.failureOn)
        XCTAssertFalse(m.flexOn)                                     // …turns flex off
        m.setPush(factor: 2)
        m.toggleFlex()                                               // and flex back on…
        XCTAssertTrue(m.flexOn)
        XCTAssertFalse(m.failureOn)                                  // …turns failure off
        XCTAssertEqual(m.pushFactor, 1, accuracy: 1e-9)             // and resets the push scrub
    }

    @MainActor func testFailurePredictionCachedPerSelection() {
        // Two variants with different peaks → the prediction follows the selection.
        let strong = OptimizeVariant(
            requestedVolumeFraction: 0.7, achievedVolumeFraction: 0.7, massGrams: 20,
            supportVolumeVoxels: 0, meshTriangleCount: 1, worstCaseMargin: 2, accepted: true,
            v3Passes: true, maxStressMPa: 10, meshVertices: [0, 0, 0, 1, 0, 0, 0, 1, 0],
            meshIndices: [0, 1, 2], vonMisesField: [10])
        let weak = OptimizeVariant(
            requestedVolumeFraction: 0.4, achievedVolumeFraction: 0.4, massGrams: 12,
            supportVolumeVoxels: 0, meshTriangleCount: 1, worstCaseMargin: 2, accepted: true,
            v3Passes: true, maxStressMPa: 30, meshVertices: [0, 0, 0, 1, 0, 0, 0, 1, 0],
            meshIndices: [0, 1, 2], vonMisesField: [30])
        let out = OptimizeOutcome(variants: [strong, weak], stoppedOnMargin: false,
                                  cancelled: false, acceptedCount: 2, voxelVolumeMM3: 1,
                                  gridNx: 1, gridNy: 1, gridNz: 1, gridOrigin: .zero, spacing: 1)
        let m = ResultsModel(projectName: "P", outcome: out, materialName: "PLA",
                             yieldStrengthMPa: 60, appliedLoadKg: 2.0)
        m.select(1)                                                  // weak: peak 30 → ×2 → 4 kg
        XCTAssertEqual(m.failurePrediction?.multiplier ?? 0, 2, accuracy: 1e-9)
        XCTAssertEqual(m.failurePrediction?.failureLoadKg ?? 0, 4, accuracy: 1e-9)
        m.select(0)                                                  // strong: peak 10 → ×6 → 12 kg
        XCTAssertEqual(m.failurePrediction?.multiplier ?? 0, 6, accuracy: 1e-9)
        XCTAssertEqual(m.failurePrediction?.failureLoadKg ?? 0, 12, accuracy: 1e-9)
    }
}
