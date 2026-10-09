import XCTest

/// ★★ REVIEWER, 2026-10-08 (approved by the maintainer): "Frozen lattice: don't wire it now. Add the
/// guard test (the bridge never arms frozen_lattice without both fields set from the job), so that
/// arming it later forces the two fields and the E1 test."
///
/// Today no production path builds the frozen-lattice options: the bridge's MinimizePlasticOptions
/// builders never set `frozen_lattice`, and only core's own harness and validation test arm it. Core
/// added `frozen_lattice_max_relative_density` beside `frozen_lattice_min_extrudable_width_mm`; only
/// the caller fills that block, so a bridge that armed `frozen_lattice` without both would run the
/// frozen floors uncapped (or be refused for the missing width). This test is the tripwire: the day
/// `bridge.cpp` arms it, both fields must be set there and a test must pin the frozen floor to E1's
/// (`lattice_min_printable_cell_mm`) at the job's cap.
final class FrozenLatticeNeverArmedBareTests: XCTestCase {

    private static var root: URL {
        var u = URL(fileURLWithPath: #filePath)
        for _ in 0..<3 { u.deleteLastPathComponent() }
        return u
    }

    /// The rule, as a pure check over the bridge's source and the test sources: nil = satisfied.
    static func violation(bridgeSource: String, testSources: String) -> String? {
        let armed = bridgeSource.range(of: #"\.frozen_lattice\s*=\s*(true|[^=])"#, options: .regularExpression) != nil
        guard armed else { return nil }
        var missing: [String] = []
        for field in ["frozen_lattice_min_extrudable_width_mm", "frozen_lattice_max_relative_density"]
            where bridgeSource.range(of: #"\.\#(field)\s*="#, options: .regularExpression) == nil {
            missing.append(field)
        }
        if !testSources.contains("testTheFrozenFloorIsE1sAtTheJobsCap") {
            missing.append("a test `testTheFrozenFloorIsE1sAtTheJobsCap` (frozen floor == lattice_min_printable_cell_mm at the job's cap)")
        }
        return missing.isEmpty ? nil : "bridge.cpp arms frozen_lattice without: " + missing.joined(separator: "; ")
    }

    private func allTestSources() throws -> String {
        let fm = FileManager.default
        var out = ""
        for dir in ["Tests/TopOptKitTests", "Tests/TopOptFlowsTests"] {
            let d = Self.root.appendingPathComponent(dir)
            for f in try fm.contentsOfDirectory(atPath: d.path) where f.hasSuffix(".swift") && f != "FrozenLatticeNeverArmedBareTests.swift" {
                out += try String(contentsOf: d.appendingPathComponent(f), encoding: .utf8)
            }
        }
        return out
    }

    /// ★ The shipped bridge satisfies the rule (today: it never arms the frozen lattice at all).
    func testTheBridgeNeverArmsTheFrozenLatticeBare() throws {
        let bridge = try String(contentsOf: Self.root.appendingPathComponent("Sources/TopOptBridge/bridge.cpp"), encoding: .utf8)
        XCTAssertNil(Self.violation(bridgeSource: bridge, testSources: try allTestSources()))
    }

    /// RED control: arming it bare trips the rule, naming every missing piece; arming it with both
    /// fields and the E1 test satisfies it.
    func testArmingItBareTripsTheRule() {
        let bare = "  topopt::MinimizePlasticOptions opts;\n  opts.frozen_lattice = true;\n"
        let v = Self.violation(bridgeSource: bare, testSources: "")
        XCTAssertNotNil(v)
        XCTAssertTrue(v?.contains("frozen_lattice_min_extrudable_width_mm") ?? false)
        XCTAssertTrue(v?.contains("frozen_lattice_max_relative_density") ?? false)
        XCTAssertTrue(v?.contains("testTheFrozenFloorIsE1sAtTheJobsCap") ?? false)
        let complete = bare
            + "  opts.frozen_lattice_min_extrudable_width_mm = job.grading.min_extrudable_width_mm;\n"
            + "  opts.frozen_lattice_max_relative_density = job.grading.max_relative_density;\n"
        XCTAssertNil(Self.violation(bridgeSource: complete, testSources: "func testTheFrozenFloorIsE1sAtTheJobsCap()"))
        // reading the flag is not arming it
        XCTAssertNil(Self.violation(bridgeSource: "if (opts.frozen_lattice == true) {}", testSources: ""))
    }
}
