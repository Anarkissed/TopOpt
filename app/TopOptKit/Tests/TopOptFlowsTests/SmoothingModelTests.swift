// Headless tests for SmoothingModel — the HONESTY RULE and the S7 boundary
// (handoff 2026-07-28-constrained-smooth-ui). Pure logic: the runner is injected,
// so no bridge / no rendering. The SmoothingPanel chrome is device QA (the /app/
// standard), but the rule "pre-smoothing numbers never appear beside smoothed
// geometry" is a logic invariant and is tested HERE.
import XCTest
@testable import TopOptFlows
@testable import TopOptKit

// A canned re-cert receipt with tunable margin / verdict / convergence. File-scope
// (not actor-isolated) so it can be called from inside the @Sendable runner closures.
private func cannedResult(
    margin: Double, required: Double = 1.5, accepted: Bool,
    nonConvergent: Bool = false, strength: Double = 0.4,
    drift: Double = 0.03, bound: Double = 0.005, minFeatureLimited: Bool = false
) -> TopOptKit.SmoothRecertifyResult {
    TopOptKit.SmoothRecertifyResult(
        smoothedMeshPath: "/tmp/part_smoothed.stl",
        accepted: accepted, nonConvergent: nonConvergent,
        marginWorstCase: margin, marginEffective: margin, marginRequired: required,
        maxStressMPa: 55.0 / max(margin, 0.001), maxInterlayerTensionMPa: 0,
        voxelMassGrams: 14.7, meshMassGrams: 14.9, minFeatureViolations: 3,
        spacingMM: 1.0, strength: strength, pairsRequested: 8, pairsApplied: 8,
        frozenVertices: 42, totalVertices: 502, volumeBeforeMM3: 1000,
        volumeAfterMM3: 970, volumeDriftFraction: drift, volumeDriftBound: bound,
        minFeatureLimited: minFeatureLimited)
}

@MainActor
final class SmoothingModelTests: XCTestCase {

    private func model(_ run: @escaping @Sendable (Double) async throws
                       -> TopOptKit.SmoothRecertifyResult) -> SmoothingModel {
        SmoothingModel(strength: 0.4, runner: run)
    }

    // ── THE HONESTY RULE ─────────────────────────────────────────────────────────

    func testIdleExposesNoNumbers() {
        let m = model { _ in cannedResult(margin: 2.0, accepted: true) }
        XCTAssertNil(m.receipt, "idle: no receipt, no numbers")
        XCTAssertNil(m.exportMeshPath, "idle: nothing to export")
        XCTAssertNil(m.verdictText)
    }

    func testCertifiedExposesOnlySmoothedNumbers() async {
        // The runner returns a WEAKENED, still-accepted margin (1.6). The model must
        // surface exactly that — there is no channel for a pre-smoothing number.
        let m = model { _ in cannedResult(margin: 1.6, accepted: true) }
        await m.apply()
        let r = try? XCTUnwrap(m.receipt)
        XCTAssertEqual(r?.marginWorstCase, 1.6)
        XCTAssertEqual(r?.strength, 0.4)
        XCTAssertEqual(m.exportMeshPath, "/tmp/part_smoothed.stl")
        XCTAssertEqual(m.verdictText,
            "Holds — re-certified margin is above the required minimum.")
    }

    func testWeakenedBelowGateReportsRejectedNotAccepted() async {
        // S3 in the UI: the smoothed part fell below the 1.5 gate. The receipt shows
        // the LOWER margin and the verdict says weakened — never a carried-over pass.
        let m = model { _ in cannedResult(margin: 1.12, accepted: false) }
        await m.apply()
        XCTAssertEqual(m.receipt?.marginWorstCase, 1.12)
        XCTAssertEqual(m.receipt?.accepted, false)
        XCTAssertEqual(m.verdictText,
            "Weakened below the required margin — reduce strength or keep the original.")
    }

    // ── S7: non-convergence is surfaced, NOT shown as a fabricated receipt ────────

    func testNonConvergentBecomesCouldNotCertifyWithNoNumbers() async {
        let m = model { _ in cannedResult(margin: 0, accepted: false, nonConvergent: true) }
        await m.apply()
        XCTAssertNil(m.receipt, "S7: a non-convergent re-cert exposes NO numbers")
        XCTAssertNil(m.exportMeshPath, "S7: nothing to export from a failed re-cert")
        guard case .couldNotCertify(let s) = m.phase else {
            return XCTFail("expected .couldNotCertify, got \(m.phase)")
        }
        XCTAssertEqual(s, 0.4)
        XCTAssertEqual(m.verdictText,
            "Couldn't re-certify at strength 0.40 — try a lower strength.")
    }

    func testHardFailureSurfacesMessageAndNoNumbers() async {
        struct Boom: Error {}
        let m = model { _ in throw TopOptError(message: "material not found: PLA") }
        await m.apply()
        XCTAssertNil(m.receipt)
        guard case .failed(let msg) = m.phase else { return XCTFail("expected .failed") }
        XCTAssertTrue(msg.contains("material not found"))
    }

    // ── receipt detail: quantization disclosure + drift honesty ──────────────────

    func testQuantizationInfoDisclosesTheVoxelGap() async {
        let m = model { _ in cannedResult(margin: 1.6, accepted: true) }
        await m.apply()
        let info = m.quantizationInfo
        XCTAssertTrue(info.contains("half a voxel"))
        XCTAssertTrue(info.contains("1 mm"), "the actual grid spacing is disclosed")
    }

    func testDriftLineFlagsExceedingTheBound() async {
        let m = model { _ in cannedResult(margin: 1.2, accepted: false, drift: 0.05, bound: 0.005) }
        await m.apply()
        let r = try! XCTUnwrap(m.receipt)
        XCTAssertTrue(m.driftLine(r).contains("beyond the denoising bound"),
                      "aggressive smoothing that removed real material is disclosed")
    }

    func testDriftLineUnderBoundIsPlain() async {
        let m = model { _ in cannedResult(margin: 1.6, accepted: true, drift: 0.002, bound: 0.005) }
        await m.apply()
        let r = try! XCTUnwrap(m.receipt)
        XCTAssertFalse(m.driftLine(r).contains("beyond"))
    }

    // ── control gating + reset ───────────────────────────────────────────────────

    func testStrengthZeroDisablesApply() {
        let m = model { _ in cannedResult(margin: 2, accepted: true) }
        m.strength = 0
        XCTAssertFalse(m.canApply)
        m.strength = 0.2
        XCTAssertTrue(m.canApply)
    }

    func testResetClearsTheReceipt() async {
        let m = model { _ in cannedResult(margin: 1.6, accepted: true) }
        await m.apply()
        XCTAssertNotNil(m.receipt)
        m.reset()
        XCTAssertNil(m.receipt, "reset returns to the pre-smoothing view")
        XCTAssertEqual(m.phase, .idle)
    }

    func testPillTextIsStable() {
        XCTAssertEqual(SmoothingModel.pillText, "Smoothed · re-analyzed")
    }
}
