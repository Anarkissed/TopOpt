// SmoothingPreviewGateTests — S3 of task 2026-08-05-smoothing-must-actually-smooth.
//
// THE REPORT. "Today he cannot even SEE the Smoothed view without pressing
// Re-certify and waiting minutes. That inverts the workflow: certification is
// being used as the rendering path."
//
// These are the REPRODUCTIONS, written before any fix. Each one names the shipped
// condition it is reproducing, by file and line, and reproduces it VERBATIM rather
// than describing it — so a test cannot pass because the reproduction drifted away
// from the code it is about.
//
// Three gates were found. G1 is the one the maintainer hit; G2 and G3 are the
// "are there others?" the task asked for, and both are real.
//
// ── WHY THE LAST ASSERTION IN EACH TEST IS SKIPPED ──────────────────────────
//
// It is NOT skipped because it is inconvenient. All three FAILED when first run,
// and that run is recorded verbatim in
// `evidence/2026-08-05-smoothing-must-actually-smooth/s3_reproduction_failing.txt`.
// They are skipped because S1 of the same task returned a NO-GO: the smoothing
// operator removes about 6% of the stair-stepping it exists to remove (10.6% at
// the most aggressive setting that does not melt the part), so what these gates
// are blocking the user from seeing is a preview of a change that is not worth
// showing. Rewiring the page to surface it is scaffolding on an operator the task
// said to stop building on.
//
// WHAT STILL THROWS, in every one of the three: the preconditions. That the
// previewer runs, that it produces a displaced mesh, that `currentGeometry` is
// willing to hand it to the stage, that a certification really happened. Those
// are live assertions and they will fail if the preview machinery regresses.
// Only the final "and therefore the user can see it" is deferred, and each names
// the file and line that has to change for it to pass.

import XCTest
import TopOptDesign
import simd
@testable import TopOptFlows
@testable import TopOptKit

@MainActor
final class SmoothingPreviewGateTests: XCTestCase {

    // MARK: - fixtures

    private let verts: [Float] = [0, 0, 0, 1, 0, 0, 0, 1, 0, 1, 1, 0]
    private let tris: [Int32] = [0, 1, 2, 1, 3, 2]

    private func brush() -> SmoothBrushModel {
        SmoothBrushModel(indices: tris, vertexCount: 4,
                         freeze: SmoothFreezeMask(frozen: [false, false, false, false],
                                                  toleranceMM: 1.2,
                                                  meshPath: "/tmp/variant_1.stl"),
                         meshPath: "/tmp/variant_1.stl")
    }

    private func brushed() -> SmoothBrushModel {
        var b = brush()
        b.beginStroke(); b.brush(.paint, triangles: [0, 1]); b.endStroke()
        return b
    }

    /// A page model with a REAL previewer: it returns a genuinely displaced mesh,
    /// the way `smooth_brush_preview` does (unconstrained, no certification).
    private func pageModel() -> SmoothingPageModel {
        let job = try! JSONSerialization.data(withJSONObject: [
            "model": "b.stl", "material": "PLA", "mode": "minimize_plastic",
            "resolution": 64,
            "loads": [
                "anchor_face_ids": [3],
                "groups": [["face_ids": [7], "force": [0.0, 0.0, -500.0]]],
                "build_dir": [0.0, 0.0, -1.0],
                "infill_percent": 35,
            ] as [String: Any],
        ] as [String: Any])
        let ctx = SmoothPageEntry.context(
            runName: "Bracket", variantIndex: 1, requestedVolumeFraction: 0.6,
            massGrams: 41.2, reportedMargin: 9.99, accepted: true,
            pageMesh: SmoothPageMesh(path: "/tmp/variant_1.stl",
                                     vertices: verts, indices: tris),
            latticed: false, retainedJob: job, modelPath: "/tmp/bracket.stl")
        return SmoothingPageModel(
            context: ctx, variantMeshPath: "/tmp/variant_1.stl",
            smoothedMeshPath: "/tmp/variant_1_smoothed.stl",
            runner: { r in
                let before = r.subject == .originalVariant
                let cert = SmoothCertification(
                    subject: r.subject,
                    TopOptKit.MeshCertification(
                        accepted: true, nonConvergent: false,
                        marginWorstCase: before ? 14.03 : 12.57,
                        marginInPlane: before ? 14.03 : 12.57,
                        marginInterlayer: before ? 22.74 : 20.61,
                        marginEffective: before ? 2.91 : 2.60,
                        marginRequired: 1.5, maxStressMPa: before ? 3.92 : 4.38,
                        minFeatureViolations: before ? 3271 : 2347,
                        voxelMassGrams: before ? 207.712 : 197.348,
                        meshMassGrams: before ? 182.640 : 182.601,
                        spacingMM: 1.25, meshVolumeFraction: 0.31,
                        voxelVolumeFraction: 0.33,
                        meshPath: before ? r.inputMeshPath : r.outputMeshPath))
                return SmoothingPageModel.CertifyOutcome(
                    certification: cert,
                    smoothing: before ? nil : SmoothingApplied(
                        maxStrength: r.strength, pairsRequested: 20,
                        pairsApplied: 20, totalVertices: 4, frozenVertices: 0,
                        brushedVertices: 3, unbrushedVertices: 1,
                        volumeDriftFraction: 0.0006, volumeDriftBound: 0.0056,
                        minFeatureLimited: false, regionLines: []),
                    meshVertices: before ? [] : [0, 0, 0, 1, 0, 0, 0, 1, 0, 0.9, 0.9, 0],
                    meshIndices: before ? [] : self.tris)
            },
            previewer: { _, _, _ in
                // What core's `smooth_brush_preview` returns: a moved mesh, no
                // certification, in milliseconds.
                SmoothingPageModel.BrushPreviewResult(
                    meshVertices: [0, 0, 0, 1, 0, 0, 0, 1, 0, 0.95, 0.95, 0],
                    meshIndices: self.tris, movedVertices: 1,
                    maxDisplacementMM: 0.49, seconds: 0.004)
            })
    }

    // ═══════════════════════════════════════════════════════════════════════
    // G1 — THE SMOOTHED TAB IS DEAD UNTIL A CERTIFICATION
    //      SmoothingPage.swift:296
    //          private var hasSmoothed: Bool {
    //              page.receipt != nil || page.kept != nil }
    //      consumed at SmoothingPage.swift:270-271
    //          stageTab("Smoothed", on: showingSmoothed && hasSmoothed,
    //                   enabled: hasSmoothed)
    // ═══════════════════════════════════════════════════════════════════════

    /// The preview exists, `currentGeometry` would draw it — and the control that
    /// reaches it is disabled. Once the user taps Original there is no way back to
    /// Smoothed without a certification solve.
    func testTheSmoothedTabIsReachableAsSoonAsAPreviewExists() async throws {
        let page = pageModel()
        await page.refreshPreview(brush: brushed())

        XCTAssertNotNil(page.preview, "precondition: the previewer produced one")
        XCTAssertEqual(page.previewCallCount, 1, "precondition: it really ran")
        page.showingSmoothed = true
        XCTAssertTrue(page.currentGeometry.smoothed,
                      "precondition: the model would hand the stage the preview")
        XCTAssertNil(page.receipt, "precondition: nothing has been certified")

        throw XCTSkip("G1 CONFIRMED FAILING — see s3_reproduction_failing.txt. "
                      + "Deferred behind S1's NO-GO: fix is SmoothingPage.swift:296, "
                      + "`hasSmoothed` must include `page.preview != nil`.")

        // SmoothingPage.swift:296, verbatim. This is the whole of the view's
        // enable condition for the Smoothed tab.
        let hasSmoothedAsShipped = page.receipt != nil || page.kept != nil
        XCTAssertTrue(hasSmoothedAsShipped,
                      "the Smoothed tab must be enabled the moment a preview "
                      + "exists — certification is not a rendering step")
    }

    // ═══════════════════════════════════════════════════════════════════════
    // G2 — AFTER ONE CERTIFICATION, NO LATER STROKE EVER REACHES THE STAGE
    //      WorkspacePlaceholder.swift:1019, in the .ended brush handler:
    //          guard page.receipt == nil, page.kept == nil else { return }
    // ═══════════════════════════════════════════════════════════════════════

    /// Certify once, then brush again. The model produces a fresh preview; the
    /// host refuses to bind it, so the stage keeps drawing the OLD certified mesh
    /// while the brush says it has been painted.
    func testALaterStrokeStillReachesTheStageAfterACertification() async throws {
        let page = pageModel()
        await page.recertify(brush: brushed())
        XCTAssertNotNil(page.receipt, "precondition: it certified")

        await page.refreshPreview(brush: brushed())
        XCTAssertNotNil(page.preview, "precondition: a fresh preview was produced")

        throw XCTSkip("G2 CONFIRMED FAILING — see s3_reproduction_failing.txt. "
                      + "Deferred behind S1's NO-GO: fix is "
                      + "WorkspacePlaceholder.swift:1019, which must compare WHICH "
                      + "brush the certified mesh describes, not merely that one exists.")

        // WorkspacePlaceholder.swift:1019, verbatim — the host's own condition
        // for letting a preview reach `smoothedVariantMesh`.
        let hostWouldBind = page.receipt == nil && page.kept == nil
        XCTAssertTrue(hostWouldBind,
                      "a stroke after a certification must still be previewable "
                      + "— otherwise the page silently stops responding to the brush")
    }

    // ═══════════════════════════════════════════════════════════════════════
    // G3 — AND THE MODEL WOULD NOT HAND IT OVER EITHER
    //      SmoothingPageModel.swift:847-859: `currentGeometry` ranks a certified
    //      outcome above the preview UNCONDITIONALLY, with no comparison of which
    //      brush each describes.
    // ═══════════════════════════════════════════════════════════════════════

    /// Even with G2 fixed, the model returns the stale certified geometry for a
    /// brush the user has since changed.
    func testTheModelPrefersAFreshPreviewOverAStaleCertifiedMesh() async throws {
        let page = pageModel()
        await page.recertify(brush: brushed())
        XCTAssertNotNil(page.receipt, "precondition: it certified")

        var deeper = brushed()
        deeper.beginStroke(); deeper.brush(.paint, triangles: [0, 1]); deeper.endStroke()
        await page.refreshPreview(brush: deeper)
        XCTAssertNotNil(page.preview, "precondition: a fresh preview was produced")

        throw XCTSkip("G3 CONFIRMED FAILING — see s3_reproduction_failing.txt. "
                      + "Deferred behind S1's NO-GO: fix is "
                      + "SmoothingPageModel.swift:847, whose certified-outcome branch "
                      + "must yield to a preview of a LATER brush.")

        page.showingSmoothed = true
        let g = page.currentGeometry
        XCTAssertEqual(g.vertices, page.preview!.meshVertices,
                       "the stage must show the geometry the CURRENT brush "
                       + "describes, not the one a previous certification measured")
    }
}
