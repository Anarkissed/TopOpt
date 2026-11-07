import XCTest
import TopOptKit

/// ★ POSITIVE AND NEGATIVE CONTROLS, or the probe proves nothing: a probe that said
/// "accepted" for everything would pass a one-sided test.
final class LatticeSchemaProbeTests: XCTestCase {
    func testTheLatticeProbeHasBothControls() {
        // What core actually says, so a broken skeleton cannot hide behind a boolean.
        print("schema(emit_welded_stl)      = \(TopOptKit.latticeSchemaError(key: "emit_welded_stl") ?? "nil")")
        print("schema(nonsense)             = \(TopOptKit.latticeSchemaError(key: "definitely_not_a_lattice_key") ?? "nil")")
        print("schema(emit_organic_spans)   = \(TopOptKit.latticeSchemaError(key: "emit_organic_spans") ?? "nil")")
        XCTAssertTrue(TopOptKit.latticeSchemaAccepts(key: "emit_welded_stl"),
                      "★ a key this core is known to carry must probe TRUE")
        XCTAssertFalse(TopOptKit.latticeSchemaAccepts(key: "definitely_not_a_lattice_key"),
                       "★ an unknown key must probe FALSE — reject_unknown_keys would kill the job")
        // The one this exists for. Documented, not asserted: true on this core, false on
        // any core older than the span export.
        print("latticeSchemaAccepts(emit_organic_spans) = "
              + "\(TopOptKit.latticeSchemaAccepts(key: "emit_organic_spans"))")
    }
}
