// FlexibleBridgeExitTests — the intermittent "exited with signal 11 / 6" after every test had passed (task
// 2026-09-29-flexible-screens, round 7 T1 item 4; his ask of 2026-10-23 ~03:45).
//
// The crash reports (~/Library/Logs/DiagnosticReports/xctest-2026-10-18-074658.ips, SIGSEGV, and
// xctest-2026-10-18-034828.ips, SIGABRT "pointer being freed was not allocated") show the same two threads:
//   * the main thread in exit() → __cxa_finalize_ranges, destroying namespace-scope statics;
//   * a cooperative-pool thread still in FlexibleStageModel.scheduleDesigns → FlexibleCore.strainUnder →
//     topoptbridge::flexible_strain_under → set_for → data_at (flexible_bridge.cpp:54-64), reading `g_data`, the
//     bridge's material cache — a std::map that exit had just destroyed.
// The bridge's process-wide caches (the data, the scenes, the squish sessions, their mutexes) are now never
// destroyed, so a call still running when the process exits reads live memory.
//
// The proof runs a CHILD xctest: four threads loop on the bridge's cached call, the test returns, the child exits
// with them still inside it. Every child must exit 0 — a signal is the old race.
import XCTest
import Foundation
@testable import TopOptKit

final class FlexibleBridgeExitTests: XCTestCase {

    private static let repoRoot: URL = {
        var u = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { u.deleteLastPathComponent() }
        return u
    }()
    static var materialsPath: String {
        repoRoot.appendingPathComponent("core/src/materials/flexible_materials.json").path
    }
    static let childKey = "FLEX_EXIT_CHILD"

    /// The child: four detached threads call the bridge's cached data in a loop for ever; the test returns at once,
    /// so xctest exits while they are inside the bridge. Runs only in the child (the parent test sets the key).
    func testChildExitsWhileBridgeCallsAreInFlight() throws {
        guard ProcessInfo.processInfo.environment[Self.childKey] == "1" else {
            throw XCTSkip("the child of testTheProcessExitsCleanlyWhileBridgeCallsAreInFlight only")
        }
        let path = Self.materialsPath
        // the cache is warm before the threads start (the same call the scheduled designs make)
        _ = try FlexibleCore.strainUnder(path: path, materialID: "varioshore_tpu", tempC: 220, topology: "gyroid",
                                         pressureMPa: 0.1, density: 0.2)
        let started = DispatchSemaphore(value: 0)
        for i in 0..<4 {
            let t = Thread {
                started.signal()
                var k = 0
                while true {
                    _ = try? FlexibleCore.strainUnder(path: path, materialID: "varioshore_tpu", tempC: 220,
                                                      topology: "gyroid", pressureMPa: 0.05 + Double(k % 7) * 0.01,
                                                      density: 0.2)
                    k += 1
                }
            }
            t.name = "flex-exit-\(i)"
            t.start()
        }
        for _ in 0..<4 { started.wait() }
        Thread.sleep(forTimeInterval: 0.05)
    }

    /// ★ The process exits cleanly with bridge calls in flight: 16 children, every one exit status 0.
    /// RED (before the fix, the caches destroyed by exit): 2 of 8 children ended on signal 11 (t1/repro_exit.log).
    func testTheProcessExitsCleanlyWhileBridgeCallsAreInFlight() throws {
        if ProcessInfo.processInfo.environment[Self.childKey] == "1" { throw XCTSkip("(inside the child)") }
        let bundle = Bundle(for: Self.self).bundleURL
        let runs = 16
        var outcomes: [String] = []
        var signalled = 0
        for _ in 0..<runs {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
            p.arguments = ["xctest", "-XCTest", "TopOptKitTests.FlexibleBridgeExitTests/testChildExitsWhileBridgeCallsAreInFlight",
                           bundle.path]
            var env = ProcessInfo.processInfo.environment
            env[Self.childKey] = "1"
            p.environment = env
            let out = Pipe()
            p.standardOutput = out
            p.standardError = out
            try p.run()
            _ = out.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            let sig = p.terminationReason == .uncaughtSignal
            if sig { signalled += 1 }
            outcomes.append(sig ? "signal \(p.terminationStatus)" : "exit \(p.terminationStatus)")
        }
        print("FLEX-EXIT \(runs) children with 4 bridge threads in flight at exit: \(outcomes)")
        XCTAssertEqual(signalled, 0, "★ no child ends on a signal: \(outcomes)")
        XCTAssertEqual(outcomes.filter { $0 == "exit 0" }.count, runs, "★ every child passes and exits 0: \(outcomes)")
    }
}
