// Headless tests for the remote-results honesty contract.
//
// Handoff 097 (the fetch-FAILED / pre-122-worker case): a LAN outcome with NO
// per-voxel fields renders mass/stress/flex/playback/support as explicitly
// unavailable — never a plausible 0 g / blank overlay — while savings, orientation,
// margin and geometry read as real. Those tests still hold: a fields-less remote
// outcome is exactly the partial/failed fetch, and it must stay gated.
//
// Handoff 122 (the fetch-SUCCEEDED case): when the worker serves fields.bin, the
// remote outcome carries the von Mises + displacement fields + the voxel mass &
// grid dims, so the Stress / Flex / Load-path overlays light up and the mass reads
// real — identical to a local run — and the "computed on Mac" note SHRINKS to only
// what's still Mac-only (playback; and on a partial fetch, the missing fields). The
// gates are now PRESENCE-based, not provenance-based.

import XCTest
import simd
@testable import TopOptFlows
@testable import TopOptKit

@MainActor
final class ResultsRemoteFieldsTests: XCTestCase {

    private func remoteVariant(vf: Double) -> OptimizeVariant {
        // Mirrors what RemoteRunner builds: real mesh + margins + orientation, but
        // massGrams 0, no support voxels, and empty per-voxel / keyframe arrays.
        OptimizeVariant(
            requestedVolumeFraction: vf, achievedVolumeFraction: vf, massGrams: 0,
            supportVolumeVoxels: 0, meshTriangleCount: 12, worstCaseMargin: 1.9,
            accepted: true, v3Passes: true,
            orientation: SIMD3(0, 0, 1), maxStressMPa: 40, maxInterlayerTensionMPa: 15,
            inPlaneMargin: 1.9, interlayerMargin: 2.4,
            meshVertices: [0, 0, 0, 1, 0, 0, 0, 1, 0], meshIndices: [0, 1, 2])
    }

    private func remoteOutcome() -> OptimizeOutcome {
        OptimizeOutcome(variants: [remoteVariant(vf: 0.68), remoteVariant(vf: 0.49)],
                        stoppedOnMargin: false, cancelled: false, acceptedCount: 2,
                        computedRemotely: true)
    }

    func testRemoteMarksUnavailableFields() {
        let m = ResultsModel(projectName: "P", outcome: remoteOutcome())
        XCTAssertTrue(m.computedRemotely)

        // Mass + support: n/a, NOT "0 g" / "minimal".
        for tab in m.tabs {
            XCTAssertEqual(tab.massLabel, ResultsModel.remoteNA, "mass must be n/a, not 0 g")
            XCTAssertEqual(tab.supportLabel, ResultsModel.remoteNA, "support must be n/a")
            XCTAssertFalse(tab.subLabel(active: true).contains("0 g"))
        }

        // Stress overlay, flex, tensor flow, playback: unavailable → controls hide.
        XCTAssertNil(m.selectedStressField, "no stress overlay for a remote run")
        XCTAssertNil(m.selectedDisplacementField, "no flex field for a remote run")
        XCTAssertNil(m.selectedTensorField, "no load-path tensor for a remote run")
        // The screen shows the Stress / Flex / playback controls ONLY when these gates
        // are true (`if model.hasStress`, `if model.hasFlex`, `if model.hasHistory`).
        // A remote run has none of the data, so all three must be false — the assertion
        // that ties this test to what the SCREEN actually renders, not just the labels.
        XCTAssertFalse(m.hasStress, "no stress control for a remote run")
        XCTAssertFalse(m.hasFlex)
        XCTAssertFalse(m.hasHistory, "no optimization playback for a remote run")

        // The explicit, honest note is present.
        let note = m.remoteComputeNote
        XCTAssertNotNil(note)
        XCTAssertTrue(note!.contains("Mac"))

        // The fields the CLI DOES deliver still read as real values.
        let rec = m.tabs.last!
        XCTAssertEqual(rec.savingsPercent, 51, "savings from achieved vf is real")
        XCTAssertEqual(rec.orientation, SIMD3(0, 0, 1))
        XCTAssertGreaterThan(rec.worstCaseMargin, 0, "safety margin is real")
        XCTAssertNotNil(m.selectedMesh, "the geometry renders")
    }

    /// THE regression guard for handoffs 097/105 (a)+(d): the results screen persists,
    /// so the honesty of a remote run must survive persist → reopen. The prior tests
    /// built the model from an IN-MEMORY outcome and stayed green while a REOPENED remote
    /// result lied — the persistence DTO dropped `computedRemotely`, so the restored
    /// outcome defaulted to local: "0.0 g" on the chips, no "computed on Mac" note, the
    /// dead stress/playback controls back. This drives the model through the SAME
    /// encode→decode `OutcomeStore` uses, then asserts the restored model is still honest.
    func testRemoteHonestySurvivesPersistRoundTrip() throws {
        let restored = try OutcomeCodec.decode(
            try OutcomeCodec.encode(OutcomeCodec.dto(from: remoteOutcome())))
        XCTAssertTrue(restored.computedRemotely, "the flag must survive persistence")

        let m = ResultsModel(projectName: "P", outcome: restored)
        XCTAssertTrue(m.computedRemotely, "a reopened remote run is still remote")
        for tab in m.tabs {
            XCTAssertEqual(tab.massLabel, ResultsModel.remoteNA, "reopened mass must be n/a, not 0 g")
            XCTAssertFalse(tab.subLabel(active: false).contains("0 g"))
        }
        XCTAssertNotNil(m.remoteComputeNote, "the 'computed on Mac' note must reappear on reopen")
        XCTAssertFalse(m.hasStress, "the Stress control stays hidden on reopen")
        XCTAssertFalse(m.hasHistory, "no playbar on reopen")
        XCTAssertNotNil(m.selectedMesh, "the geometry still renders on reopen")
    }

    // ── Handoff 122: a remote run that FETCHED fields.bin ──────────────────────

    /// A remote variant enriched with the fields fields.bin now carries: a real voxel
    /// mass + support and the von Mises / displacement arrays (sized to a 2×2×2 grid).
    /// The 6-component tensor is NOT sent in v1, so it stays empty.
    private func remoteVariantWithFields(vf: Double, displacement: Bool = true) -> OptimizeVariant {
        let voxels = 8                       // 2·2·2
        let nodes = 27                       // 3·3·3
        return OptimizeVariant(
            requestedVolumeFraction: vf, achievedVolumeFraction: vf, massGrams: 118,
            supportVolumeVoxels: 3, meshTriangleCount: 1, worstCaseMargin: 1.9,
            accepted: true, v3Passes: true, orientation: SIMD3(0, 0, 1),
            maxStressMPa: 40, maxInterlayerTensionMPa: 15, inPlaneMargin: 1.9,
            interlayerMargin: 2.4,
            meshVertices: [0, 0, 0, 1, 0, 0, 0, 1, 0], meshIndices: [0, 1, 2],
            vonMisesField: [Float](repeating: 20, count: voxels),
            displacementField: displacement ? [Float](repeating: 0.1, count: 3 * nodes) : [],
            stressTensorField: [])
    }

    private func remoteOutcomeWithFields(displacement: Bool = true) -> OptimizeOutcome {
        // The grid metadata fields.bin carries; without it the overlays read isEmpty.
        OptimizeOutcome(
            variants: [remoteVariantWithFields(vf: 0.68, displacement: displacement),
                       remoteVariantWithFields(vf: 0.49, displacement: displacement)],
            stoppedOnMargin: false, cancelled: false, acceptedCount: 2,
            voxelVolumeMM3: 8, gridNx: 2, gridNy: 2, gridNz: 2,
            gridOrigin: .zero, spacing: 2, computedRemotely: true)
    }

    func testRemoteWithFieldsLightsUpOverlays() {
        let m = ResultsModel(projectName: "P", outcome: remoteOutcomeWithFields())
        XCTAssertTrue(m.computedRemotely, "still a remote run (ran on a worker)")

        // The overlays the fetched fields feed now light up — the arc this handoff closes.
        XCTAssertNotNil(m.selectedStressField, "stress overlay present from fetched von Mises")
        XCTAssertTrue(m.hasStress, "Stress chip shows")
        XCTAssertTrue(m.hasFlex, "Flex chip shows from fetched displacement")
        XCTAssertTrue(m.hasLoadPath, "Load-path shows (derived from displacement)")

        // The tensor is NOT serialised in v1 → the load→anchor flow sub-mode stays gated.
        XCTAssertTrue(m.selectedTensorField?.isEmpty ?? true, "no 6-component tensor over the wire")

        // Mass + support now read REAL, not n/a.
        for tab in m.tabs {
            XCTAssertNotEqual(tab.massLabel, ResultsModel.remoteNA, "mass is real now")
            XCTAssertTrue(tab.massLabel.contains("g"), "a real gram figure")
            XCTAssertNotEqual(tab.supportLabel, ResultsModel.remoteNA, "support is real now")
        }

        // The note SHRINKS: it no longer claims stress/flex/mass are Mac-only, only the
        // still-unavailable playback survives.
        let note = m.remoteComputeNote
        XCTAssertNotNil(note, "playback is still Mac-only, so a (smaller) note remains")
        XCTAssertTrue(note!.contains("playback"))
        XCTAssertFalse(note!.contains("stress overlay"), "the stress clause died — real data replaced it")
        XCTAssertFalse(note!.contains("mass"), "the mass clause died")
    }

    func testRemotePartialFetchKeepsNoteForMissingFields() {
        // Von Mises + mass arrived, but displacement did NOT (a partial fetch): Stress
        // lights up, Flex/Load-path stay gated, and the note names ONLY what's missing.
        let m = ResultsModel(projectName: "P",
                             outcome: remoteOutcomeWithFields(displacement: false))
        XCTAssertTrue(m.hasStress, "stress still lights up from its field")
        XCTAssertFalse(m.hasFlex, "flex stays gated — its field didn't arrive")
        XCTAssertFalse(m.hasLoadPath)
        let note = try! XCTUnwrap(m.remoteComputeNote).lowercased()
        XCTAssertTrue(note.contains("flex"), "the note keeps the missing-flex clause")
        XCTAssertFalse(note.contains("the stress overlay"), "but drops stress, which is present")
    }

    func testRemoteFieldsSurvivePersistRoundTrip() throws {
        // The fetched fields must survive persist→reopen (the 108/122 lesson): a reopened
        // remote run keeps its overlays, not just the flag.
        let restored = try OutcomeCodec.decode(
            try OutcomeCodec.encode(OutcomeCodec.dto(from: remoteOutcomeWithFields())))
        let m = ResultsModel(projectName: "P", outcome: restored)
        XCTAssertTrue(m.computedRemotely)
        XCTAssertTrue(m.hasStress, "stress overlay survives reopen")
        XCTAssertTrue(m.hasFlex, "flex survives reopen")
        XCTAssertNotEqual(m.tabs.first?.massLabel, ResultsModel.remoteNA, "mass survives reopen")
    }

    func testLocalOutcomeUnchanged() {
        // A local outcome (default computedRemotely=false) shows a real mass + note nil.
        let v = OptimizeVariant(
            requestedVolumeFraction: 0.6, achievedVolumeFraction: 0.6, massGrams: 120,
            supportVolumeVoxels: 0, meshTriangleCount: 10, worstCaseMargin: 2, accepted: true,
            v3Passes: true, orientation: SIMD3(0, 0, 1), maxStressMPa: 5,
            maxInterlayerTensionMPa: 2, inPlaneMargin: 2, interlayerMargin: 3)
        let m = ResultsModel(projectName: "P",
                             outcome: OptimizeOutcome(variants: [v], stoppedOnMargin: false,
                                                      cancelled: false, acceptedCount: 1))
        XCTAssertFalse(m.computedRemotely)
        XCTAssertNil(m.remoteComputeNote)
        XCTAssertNotEqual(m.tabs.first?.massLabel, ResultsModel.remoteNA)
        XCTAssertTrue(m.tabs.first!.massLabel.contains("g"), "local mass is a real gram figure")
    }
}
