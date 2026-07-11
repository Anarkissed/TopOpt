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
}
