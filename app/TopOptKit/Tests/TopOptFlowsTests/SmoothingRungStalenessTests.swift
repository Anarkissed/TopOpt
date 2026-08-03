// SmoothingRungStalenessTests — task 2026-08-03-variant-postprocessing-concurrency,
// requirement 3 / BAR 5.
//
// THE FAILURE THIS PREVENTS. A ladder takes hours, and a variant is now workable
// the moment it streams. So a user can smooth rung 1, watch rung 3 arrive, and
// ship rung 3 — with a smoothed shape on screen that was computed from a DIFFERENT
// design and certified under a different margin. The smoothed geometry must never
// silently become the basis for a later rung's work, and the UI must name which
// rung a smoothing belongs to.
//
// The rule is PR 260's, deliberately: an Equatable fingerprint recorded when the
// result is computed, compared against the current one, surfaced through the SAME
// `LatticePageBanner` shape. There is one staleness concept, not two.

import XCTest
import simd
@testable import TopOptFlows
@testable import TopOptKit

@MainActor
final class SmoothingRungStalenessTests: XCTestCase {

    private func rung(_ index: Int, _ vf: Double,
                      fingerprint: UInt64? = nil) -> SmoothingRungFingerprint {
        SmoothingRungFingerprint(variantIndex: index, requestedVolumeFraction: vf,
                                 designFingerprint: fingerprint)
    }

    // MARK: - the rule

    func testASmoothingOfOneRungIsNotCurrentForAnother() throws {
        let one = rung(0, 0.68)
        let three = rung(2, 0.38)

        XCTAssertTrue(SmoothingStaleness.isCurrent(kept: one, current: one),
                      "a smoothing IS current for the rung it was made from — a "
                      + "gate that fires on everything is not a gate")
        XCTAssertFalse(SmoothingStaleness.isCurrent(kept: one, current: three),
                       "BAR 5: rung 1's smoothing must NOT be presented as current "
                       + "for rung 3")

        let banner = try XCTUnwrap(SmoothingStaleness.banner(kept: one, current: three))
        XCTAssertEqual(banner.kind, .smoothingStale)
        // It must NAME BOTH rungs — which one the smoothing is, and which one you
        // are looking at. "Out of date" without a subject is what let this happen.
        XCTAssertTrue(banner.title.contains("rung 1"), banner.title)
        XCTAssertTrue(banner.body.contains("rung 3"), banner.body)
        XCTAssertTrue(banner.body.contains("rung 1"), banner.body)
        XCTAssertTrue(banner.title.contains("68% volume"),
                      "…and by volume fraction, the key every artifact is indexed "
                      + "by: \(banner.title)")
        XCTAssertNotNil(banner.actionLabel, "a stale banner offers the way out")
    }

    /// The identity is a DESIGN, not a position. A later run whose rung 1 lands at
    /// the same volume fraction is a different design, and the smoothing goes stale.
    func testTheSameRungOfADIFFERENTRunIsStale() {
        let first = rung(0, 0.68, fingerprint: 0xDEAD_BEEF)
        let second = rung(0, 0.68, fingerprint: 0x1234_5678)
        XCTAssertFalse(SmoothingStaleness.isCurrent(kept: first, current: second),
                       "same index, same volume fraction, different DESIGN — the "
                       + "fingerprint is what makes this catchable")
        XCTAssertTrue(SmoothingStaleness.isCurrent(kept: first, current: first))
    }

    func testNothingKeptAndNothingSelectedSayNothing() {
        XCTAssertNil(SmoothingStaleness.banner(kept: nil, current: rung(0, 0.7)))
        XCTAssertNil(SmoothingStaleness.banner(kept: rung(0, 0.7), current: nil))
        XCTAssertNil(SmoothingStaleness.banner(kept: nil, current: nil))
    }

    // MARK: - BAR 5, through the page model that actually carries it

    /// Smooth rung 1, let rung 3 arrive, and assert the model itself — not a
    /// hand-built value — names the rung and refuses to call it current.
    func testTheModelRecordsWhichRungItSmoothedAndStalesAgainstALaterOne() async throws {
        let model = SmoothingPageModel(
            context: context(variantIndex: 0, vf: 0.68),
            variantMeshPath: "/tmp/variant_1.stl",
            smoothedMeshPath: "/tmp/variant_1_smoothed.stl",
            runner: { req in
                let before = req.subject == .originalVariant
                return SmoothingPageModel.CertifyOutcome(
                    certification: SmoothCertification(
                        subject: req.subject,
                        TopOptKit.MeshCertification(
                            accepted: true, nonConvergent: false,
                            marginWorstCase: before ? 2.78 : 2.31,
                            marginInPlane: before ? 3.78 : 3.31,
                            marginInterlayer: before ? 2.78 : 2.31,
                            marginEffective: before ? 0.58 : 0.48,
                            marginRequired: 1.5, maxStressMPa: before ? 14.4 : 33.2,
                            minFeatureViolations: 0,
                            voxelMassGrams: before ? 41.2 : 39.8,
                            meshMassGrams: before ? 41.9 : 40.4, spacingMM: 1.25,
                            meshVolumeFraction: 0.31, voxelVolumeFraction: 0.33,
                            meshPath: before ? req.inputMeshPath
                                             : req.outputMeshPath)),
                    smoothing: before ? nil : SmoothingApplied(
                        maxStrength: 0.6, pairsRequested: 20, pairsApplied: 20,
                        totalVertices: 4, frozenVertices: 0, brushedVertices: 3,
                        unbrushedVertices: 1, volumeDriftFraction: 0.004,
                        volumeDriftBound: 0.0056, minFeatureLimited: false,
                        regionLines: ["Region A 0.60 (2 tri)"]),
                    meshVertices: before ? [] : [9, 9, 9, 8, 8, 8, 7, 7, 7],
                    meshIndices: before ? [] : [0, 1, 2])
            })

        // The fingerprint the page reports for its OWN rung, before anything is kept.
        let mine = model.rungFingerprint(0xAAAA)
        XCTAssertEqual(mine.variantIndex, 0)
        XCTAssertEqual(mine.requestedVolumeFraction, 0.68)
        XCTAssertEqual(mine.designFingerprint, 0xAAAA)
        XCTAssertEqual(mine.rungLabel, "rung 1 (68% volume)")

        // …and with nothing kept there is nothing to be stale about, even when the
        // selection has already moved on.
        XCTAssertNil(model.stalenessBanner(currentRung: rung(2, 0.38)),
                     "an un-smoothed page must not show a staleness banner")

        // KEEP a smoothing for rung 1, through the PRODUCTION path: re-certify,
        // then keep. (The model refuses to keep without a live receipt, which is
        // its own rule — going through it is what makes this a real assertion.)
        var brush = SmoothBrushModel(
            indices: [0, 1, 2], vertexCount: 3,
            freeze: SmoothFreezeMask(frozen: [false, false, false],
                                     toleranceMM: 0.75))
        brush.addRegion(strength: 0.6)
        _ = brush.paint(.add, triangles: [0])
        await model.recertify(brush: brush)
        XCTAssertTrue(model.keep(regionLines: ["Region A 0.60 (2 tri)"],
                                 designFingerprint: 0xAAAA),
                      "the smoothing was kept through the production path")
        let kept = try XCTUnwrap(model.kept)
        let keptRung = try XCTUnwrap(kept.rung,
                                     "BAR 5: a kept smoothing must carry the rung "
                                     + "it was made from")
        XCTAssertEqual(keptRung, mine)

        // Rung 3 arrives and is selected.
        XCTAssertNil(model.stalenessBanner(currentRung: mine),
                     "still current for its own rung")
        let stale = try XCTUnwrap(
            model.stalenessBanner(currentRung: rung(2, 0.38, fingerprint: 0xBBBB)),
            "BAR 5: the model must report the smoothing as belonging to rung 1")
        XCTAssertTrue(stale.title.contains("rung 1"), stale.title)
        XCTAssertTrue(stale.body.contains("rung 3"), stale.body)
    }

    // MARK: - fixtures

    private func context(variantIndex: Int, vf: Double) -> SmoothVariantContext {
        SmoothVariantContext(
            runName: "Bracket", variantIndex: variantIndex,
            requestedVolumeFraction: vf, massGrams: 41.2, reportedMargin: 2.31,
            accepted: true,
            pageMesh: SmoothPageMesh(path: "/tmp/in.stl",
                                     vertices: [0, 0, 0, 1, 0, 0, 0, 1, 0],
                                     indices: [0, 1, 2]),
            loadCase: SmoothRecertLoadCase(
                material: "PLA", resolution: 64, anchorFaceIDs: [3],
                loadGroups: [TopOptKit.LoadGroupSpec(faceIDs: [7],
                                                     force: SIMD3(0, 0, -500))],
                buildDirection: SIMD3(0, 0, 1), infillPercent: 35, freeze: [],
                protectedFaceIDs: []),
            unavailable: nil, modelPath: "/tmp/part.stl")
    }
}
