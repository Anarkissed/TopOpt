// Headless tests for handoff 097 fix (3): a LAN-computed outcome renders the
// fields the worker does NOT serialise (mass, stress overlay, flex, playback,
// support) as explicitly unavailable — never as a plausible 0 g / blank overlay —
// while the fields it DOES deliver (savings, orientation, safety margin, geometry)
// still read as real values.

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
