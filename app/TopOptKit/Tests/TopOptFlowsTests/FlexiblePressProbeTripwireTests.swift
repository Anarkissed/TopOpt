// FlexiblePressProbeTripwireTests — angled presses, batch S1 (the #361 sync), TESTS FIRST (spec §10, §20; the
// S1 batch's tests_first). At the synced head, core's own job parser (TopOptKit.jobSchemaError → parse_job)
// takes the two angled forms the probe will ask about, built exactly as the probe builds them
// (FlexibleAngledGoldens.probeDocuments: FlexibleJob.document, 2 declared faces, varioshore_tpu, ONE loaded
// entry):
//   * the control — the entry exactly as faceEntry writes a pressed face today — parses;
//   * the TILT — the same entry + press_direction [0,0,-1] — parses (POSITIVE);
//   * the EDGE — face_region_ids [0,1] in place of face_region_id, + press_direction — parses (POSITIVE).
// ★ RED CONTROL: the same entry with an unknown key, press_directionX, is REFUSED, by name — the parser is
//   strict, so "parses" above is core accepting the key, not core ignoring it.
// ★ PRE-SYNC EVIDENCE: the base core (523dd2f90b04, AP0 at 01ec5e3c) refused both forms; its texts are
//   AP0's probe_refusals_base.json (never overwritten — AP6's injected-probe test reads them). This test reads
//   them and pins that each angled form flipped from ITS base refusal to accepted.
// It is a TRIPWIRE: if #361 renames press_direction or face_region_ids (3121151e is titled WIP), this goes
// red at the next sync instead of the probe silently answering "not supported".
import XCTest
@testable import TopOptFlows
@testable import TopOptKit

@MainActor
final class FlexiblePressProbeTripwireTests: XCTestCase {
    typealias G = FlexibleAngledGoldens

    func testTheAddendumIsWhatTheProbeExpects() throws {
        let d = try G.probeDocuments()
        // premise: the documents carry what they claim (one loaded entry, the keys under test)
        XCTAssertTrue(d.tilt.contains("\"press_direction\""), "premise: the tilt states press_direction")
        XCTAssertTrue(d.edge.contains("\"face_region_ids\"") && d.edge.contains("\"press_direction\""),
                      "premise: the edge states face_region_ids + press_direction")
        XCTAssertFalse(d.edge.contains("\"face_region_id\""), "premise: the edge names its regions only by the list")

        let control = TopOptKit.jobSchemaError(Data(d.control.utf8))
        let tilt = TopOptKit.jobSchemaError(Data(d.tilt.utf8))
        let edge = TopOptKit.jobSchemaError(Data(d.edge.utf8))
        print("FLEX-AP S1 tripwire · core \(CoreFingerprint.value): control \(control ?? "accepted") · tilt \(tilt ?? "accepted") · edge \(edge ?? "accepted")")
        XCTAssertNil(control, "the control (the entry as faceEntry writes it) parses")
        XCTAssertNil(tilt, "★ POSITIVE: a loaded entry with press_direction parses")
        XCTAssertNil(edge, "★ POSITIVE: a loaded entry with face_region_ids + press_direction parses")

        // ★ RED CONTROL: an unknown key beside the same entry is refused, by its name
        var unknown = try G.controlEntry()
        unknown["press_directionX"] = [0.0, 0.0, -1.0]
        let refused = TopOptKit.jobSchemaError(Data(try G.probeDocument(unknown).utf8))
        print("FLEX-AP S1 tripwire control: press_directionX → \(refused ?? "accepted")")
        XCTAssertNotNil(refused, "control: core's parser refuses a key it does not know")
        XCTAssertTrue(refused?.contains("press_directionX") == true, "control: …by its name: \(refused ?? "nil")")

        // ★ PRE-SYNC EVIDENCE: AP0's recorded base refusals — each form refused for ITS OWN reason then
        let base = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(try G.read("probe_refusals_base.json").utf8)) as? [String: Any])
        let baseTilt = try XCTUnwrap(base["tilt"] as? String, "the base refused the tilt")
        let baseEdge = try XCTUnwrap(base["edge"] as? String, "the base refused the edge")
        XCTAssertTrue(base["control"] is NSNull, "the control parsed at the base too")
        XCTAssertTrue(baseTilt.contains("unknown key \"press_direction\""), baseTilt)
        XCTAssertTrue(baseEdge.contains("missing required key \"face_region_id\""), baseEdge)
    }
}
