// Round-trip tests for persist-c: an OptimizeOutcome (variants + stress fields +
// playback keyframes) must survive encode → binary plist → decode byte-for-byte,
// so results reopen intact after an app relaunch.

import XCTest
import simd
import TopOptKit
@testable import TopOptFlows

final class OutcomeStoreTests: XCTestCase {
    private func sampleOutcome() -> OptimizeOutcome {
        let v0 = OptimizeVariant(
            requestedVolumeFraction: 0.52, achievedVolumeFraction: 0.49,
            massGrams: 27.5, supportVolumeVoxels: 1234, meshTriangleCount: 3,
            worstCaseMargin: 1.8, accepted: true, v3Passes: true,
            minFeatureViolations: 2, minFeatureWarning: "1 thin web",
            orientation: SIMD3<Double>(0, 0, 1), maxStressMPa: 41.2,
            maxInterlayerTensionMPa: 12.0, inPlaneMargin: 2.1, interlayerMargin: 1.8,
            meshVertices: [0, 0, 0, 1, 0, 0, 0, 1, 0], meshIndices: [0, 1, 2],
            vonMisesField: [1.5, 2.5, 3.5, 4.5],
            displacementField: [0.1, -0.2, 0.3, 0.4, 0.5, -0.6],
            keyframeMeshes: [
                KeyframeMesh(vertices: [0, 0, 0, 2, 0, 0, 0, 2, 0], indices: [0, 1, 2]),
                KeyframeMesh(vertices: [0, 0, 0, 1, 1, 1], indices: [0, 1]),
            ])
        // A rejected rung with empty meshes (cancelled-style) must round-trip too.
        let v1 = OptimizeVariant(
            requestedVolumeFraction: 0.26, achievedVolumeFraction: 0.25,
            massGrams: 15.0, supportVolumeVoxels: 0, meshTriangleCount: 0,
            worstCaseMargin: 0.7, accepted: false, v3Passes: false)
        return OptimizeOutcome(variants: [v0, v1], stoppedOnMargin: true,
                               cancelled: false, acceptedCount: 1, voxelVolumeMM3: 0.125,
                               gridNx: 8, gridNy: 6, gridNz: 4,
                               gridOrigin: SIMD3<Double>(-1, -2, -3), spacing: 0.5)
    }

    func testOutcomeRoundTripsThroughEncodeDecode() throws {
        let o = sampleOutcome()
        let decoded = try OutcomeCodec.decode(try OutcomeCodec.encode(OutcomeCodec.dto(from: o)))

        XCTAssertEqual(decoded.variants.count, 2)
        XCTAssertEqual(decoded.acceptedCount, 1)
        XCTAssertTrue(decoded.stoppedOnMargin)
        XCTAssertFalse(decoded.cancelled)
        XCTAssertEqual(decoded.voxelVolumeMM3, 0.125)
        XCTAssertEqual(decoded.gridNx, 8); XCTAssertEqual(decoded.gridNy, 6); XCTAssertEqual(decoded.gridNz, 4)
        XCTAssertEqual(decoded.gridOrigin, SIMD3<Double>(-1, -2, -3))
        XCTAssertEqual(decoded.spacing, 0.5)

        let a = decoded.variants[0]
        XCTAssertEqual(a.massGrams, 27.5)
        XCTAssertEqual(a.worstCaseMargin, 1.8)
        XCTAssertTrue(a.accepted)
        XCTAssertEqual(a.minFeatureViolations, 2)
        XCTAssertEqual(a.minFeatureWarning, "1 thin web")
        XCTAssertEqual(a.orientation, SIMD3<Double>(0, 0, 1))
        XCTAssertEqual(a.maxStressMPa, 41.2)
        XCTAssertEqual(a.interlayerMargin, 1.8)
        // The heavy arrays survive exactly (this is the whole point).
        XCTAssertEqual(a.meshVertices, [0, 0, 0, 1, 0, 0, 0, 1, 0])
        XCTAssertEqual(a.meshIndices, [0, 1, 2])
        XCTAssertEqual(a.vonMisesField, [1.5, 2.5, 3.5, 4.5])
        // M7.viz.3: the per-node displacement field survives so a reopened project
        // flexes without re-optimizing (the whole point of persisting it).
        XCTAssertEqual(a.displacementField, [0.1, -0.2, 0.3, 0.4, 0.5, -0.6])
        XCTAssertEqual(a.keyframeMeshes.count, 2)
        XCTAssertEqual(a.keyframeMeshes[0].vertices, [0, 0, 0, 2, 0, 0, 0, 2, 0])
        XCTAssertEqual(a.keyframeMeshes[0].indices, [0, 1, 2])
        XCTAssertEqual(a.keyframeMeshes[1].vertices, [0, 0, 0, 1, 1, 1])

        let b = decoded.variants[1]
        XCTAssertFalse(b.accepted)
        XCTAssertTrue(b.meshVertices.isEmpty)
        XCTAssertTrue(b.keyframeMeshes.isEmpty)
        XCTAssertTrue(b.displacementField.isEmpty)   // rejected rung carries no flex data
    }

    /// A persist-c blob written BEFORE M7.viz.3 has no `displacementField` key. It
    /// must still decode (→ empty flex), not fail the whole outcome — that is why the
    /// DTO field is optional. Simulate the legacy blob by stripping the key.
    func testDecodesLegacyBlobWithoutDisplacementField() throws {
        let data = try OutcomeCodec.encode(OutcomeCodec.dto(from: sampleOutcome()))
        let obj = try PropertyListSerialization.propertyList(
            from: data, options: PropertyListSerialization.ReadOptions(), format: nil)
        var plist = try XCTUnwrap(obj as? [String: Any])
        var variants = try XCTUnwrap(plist["variants"] as? [[String: Any]])
        for i in variants.indices { variants[i].removeValue(forKey: "displacementField") }
        plist["variants"] = variants
        let stripped = try PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0)

        let decoded = try OutcomeCodec.decode(stripped)
        XCTAssertEqual(decoded.variants.count, 2)
        // The rest of the outcome is intact; only flex degrades to empty.
        XCTAssertEqual(decoded.variants[0].vonMisesField, [1.5, 2.5, 3.5, 4.5])
        XCTAssertTrue(decoded.variants[0].displacementField.isEmpty)
        XCTAssertTrue(decoded.variants[1].displacementField.isEmpty)
    }

    func testStoreSavesAndLoadsResultsBlob() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("topopt-results-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = ProjectStore(rootDir: dir)
        let id = UUID()
        // Saving into a project folder that only exists once a snapshot was written.
        let data = try OutcomeCodec.encode(OutcomeCodec.dto(from: sampleOutcome()))
        try store.saveResults(data, id: id)
        let reloaded = try XCTUnwrap(store.loadResultsData(id: id))
        XCTAssertEqual(reloaded, data)
        let outcome = try OutcomeCodec.decode(reloaded)
        XCTAssertEqual(outcome.variants.count, 2)
    }

    @MainActor
    func testRestoreOutcomeSetsOutcomeOnIdleRunOnce() {
        let run = RunModel(scheduler: SynchronousRunScheduler())
        XCTAssertNil(run.outcome)
        run.restoreOutcome(sampleOutcome())
        XCTAssertEqual(run.outcome?.variants.count, 2)
        XCTAssertEqual(run.phase, .idle, "restore has no side effects on phase")
        // Second restore is a no-op (already loaded).
        run.restoreOutcome(OptimizeOutcome(variants: [], stoppedOnMargin: false,
                                           cancelled: false, acceptedCount: 0))
        XCTAssertEqual(run.outcome?.variants.count, 2)
    }
}
