// ManualPrimitiveJobTests — BAR B1 (field equivalence) at the job.json layer.
//
// A job containing a MANUALLY-placed primitive must serialize to the SAME SHAPE
// of job.json as one containing an AUTO-found primitive of the same kind. The only
// permitted difference is the geometry SOURCE — an auto clearance carries a
// "face_id" (the B-rep face the core re-reads geometry from), a manual clearance
// carries a "geometry" object (the axis/radius/normal/extent the user supplied,
// because a hand-placed primitive has no B-rep face). The kind + every editable
// distance field is identical. This is the same field-equivalence discipline that
// caught PR 178's dropped loads (JobJSONEquivalenceTests) — asserted by diffing the
// two clearance dicts.

import XCTest
import TopOptKit
@testable import TopOptFlows

@MainActor
final class ManualPrimitiveJobTests: XCTestCase {

    private func request(clearances: [TopOptKit.ClearanceSpec]) -> RunRequest {
        RunRequest(
            modelPath: "/tmp/part.stl", material: "PLA", materialsPath: "", rulesPath: "",
            resolution: 96, projectName: "manual-primitive",
            anchorFaceIDs: [3], loadGroups: [], minimizePlastic: true,
            buildDirection: SIMD3(0, 0, 1), infillPercent: 40,
            designBox: nil, keepOutBoxes: [], clearances: clearances,
            faceProtections: [], faceProtectionDepthMM: -1)
    }

    private func clearances(from clearances: [TopOptKit.ClearanceSpec]) throws -> [[String: Any]] {
        let cfg = RemoteRunnerConfig(host: "127.0.0.1", port: 8757, expectedFingerprint: "test")
        let run = RemoteRun(config: cfg, request: request(clearances: clearances),
                            progress: { _, _, _ in true }, onVariant: { _ in })
        let job = try XCTUnwrap(JSONSerialization.jsonObject(with: try run.buildJobJSON()) as? [String: Any])
        let loads = try XCTUnwrap(job["loads"] as? [String: Any])
        return try XCTUnwrap(loads["clearances"] as? [[String: Any]])
    }

    // MARK: - manual bolt geometry serialization

    func testManualBoltSerializesGeometryNotFaceID() throws {
        let spec = TopOptKit.ClearanceSpec.manualBolt(
            axisPoint: SIMD3(1, 2, 3), axisDir: SIMD3(0, 0, 1), radiusMM: 2.5,
            halfLengthMM: 5, concentricMarginMM: 1.5, axialClearanceMM: 4)
        let c = try XCTUnwrap(clearances(from: [spec]).first)

        XCTAssertNil(c["face_id"], "a manual clearance carries NO face_id")
        let geo = try XCTUnwrap(c["geometry"] as? [String: Any], "a manual clearance carries a geometry object")
        XCTAssertEqual(geo["axis_point"] as? [Double], [1, 2, 3])
        XCTAssertEqual(geo["axis_dir"] as? [Double], [0, 0, 1])
        XCTAssertEqual(geo["radius_mm"] as? Double, 2.5)
        XCTAssertEqual(geo["half_length_mm"] as? Double, 5)
        XCTAssertEqual(c["kind"] as? String, "bolt")
        XCTAssertEqual(c["concentric_margin_mm"] as? Double, 1.5)
        XCTAssertEqual(c["axial_clearance_mm"] as? Double, 4)
    }

    func testManualFaceSerializesGeometryNotFaceID() throws {
        let spec = TopOptKit.ClearanceSpec.manualFace(
            origin: SIMD3(4, 5, 6), normal: SIMD3(1, 0, 0), halfUMM: 3, halfWMM: 2, slabDepthMM: 3)
        let c = try XCTUnwrap(clearances(from: [spec]).first)

        XCTAssertNil(c["face_id"])
        let geo = try XCTUnwrap(c["geometry"] as? [String: Any])
        XCTAssertEqual(geo["origin"] as? [Double], [4, 5, 6])
        XCTAssertEqual(geo["normal"] as? [Double], [1, 0, 0])
        XCTAssertEqual(geo["half_u_mm"] as? Double, 3)
        XCTAssertEqual(geo["half_w_mm"] as? Double, 2)
        XCTAssertEqual(c["kind"] as? String, "face")
        XCTAssertEqual(c["slab_depth_mm"] as? Double, 3)
    }

    // MARK: - BAR B1: manual vs auto differ ONLY in the geometry source

    func testManualAndAutoBoltAreFieldEquivalentExceptSource() throws {
        let auto = TopOptKit.ClearanceSpec(faceID: 7, kind: .bolt,
                                           concentricMarginMM: 1.5, axialClearanceMM: 4)
        let manual = TopOptKit.ClearanceSpec.manualBolt(
            axisPoint: SIMD3(1, 2, 3), axisDir: SIMD3(0, 0, 1), radiusMM: 2.5,
            halfLengthMM: 5, concentricMarginMM: 1.5, axialClearanceMM: 4)
        var a = try XCTUnwrap(clearances(from: [auto]).first)
        var m = try XCTUnwrap(clearances(from: [manual]).first)

        // The source keys are the ONLY permitted difference.
        XCTAssertNotNil(a["face_id"])
        XCTAssertNotNil(m["geometry"])
        a["face_id"] = nil
        m["geometry"] = nil

        // Everything that remains — kind + every distance field — is byte-identical.
        XCTAssertEqual((a as NSDictionary), (m as NSDictionary),
                       "B1: a manual and an auto clearance of the same kind agree on every field but the source")
    }

    // MARK: - untouched auto job is byte-identical (BAR B4 at the wire)

    func testAutoOnlyJobHasNoGeometryOrManualKeys() throws {
        let auto = TopOptKit.ClearanceSpec(faceID: 7, kind: .bolt, concentricMarginMM: 1.5)
        let c = try XCTUnwrap(clearances(from: [auto]).first)
        XCTAssertEqual(c["face_id"] as? Int, 7)
        XCTAssertNil(c["geometry"], "an auto clearance never emits a geometry object (byte-identical to pre-handoff)")
    }
}
