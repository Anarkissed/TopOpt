// Headless tests for the compute-location model (handoff 097): the selection,
// per-device persistence, manual-address resolution, and version-skew flag. The
// Bonjour discovery + NWConnection resolution are device/network behaviour (not
// asserted here); these cover the pure logic the run flow depends on.

import XCTest
import Network
@testable import TopOptFlows

@MainActor
final class ComputeLocationTests: XCTestCase {

    private func freshDefaults() -> UserDefaults {
        let d = UserDefaults(suiteName: "topopt.tests.\(UUID().uuidString)")!
        return d
    }

    func testLocalIsDefaultAndByteIdentical() {
        let m = ComputeLocationModel(defaults: freshDefaults())
        XCTAssertEqual(m.choice, .local)
        XCTAssertNil(m.activeRemote, "local must not build a remote config")
        XCTAssertEqual(m.label, "iPad")
    }

    func testManualSelectionBuildsRemoteConfig() throws {
        let m = ComputeLocationModel(defaults: freshDefaults())
        m.select(.manual(host: "192.168.1.42", port: 8757))
        let cfg = try XCTUnwrap(m.activeRemote)
        XCTAssertEqual(cfg.host, "192.168.1.42")
        XCTAssertEqual(cfg.port, 8757)
        XCTAssertEqual(cfg.expectedFingerprint, CoreFingerprint.value,
                       "the expected fingerprint is always THIS app's core")
        XCTAssertEqual(m.label, "192.168.1.42")
    }

    func testSwitchingBackToLocalClearsRemote() {
        let m = ComputeLocationModel(defaults: freshDefaults())
        m.select(.manual(host: "10.0.0.5", port: 9000))
        XCTAssertNotNil(m.activeRemote)
        m.select(.local)
        XCTAssertNil(m.activeRemote, "switching back to iPad restores the local runner")
    }

    func testSelectionPersistsPerDevice() {
        let defaults = freshDefaults()
        let a = ComputeLocationModel(defaults: defaults)
        a.select(.manual(host: "host.local", port: 8757))
        // A fresh model reading the same defaults restores the choice (and, for a
        // manual address, re-resolves it immediately).
        let b = ComputeLocationModel(defaults: defaults)
        XCTAssertEqual(b.choice, .manual(host: "host.local", port: 8757))
        XCTAssertEqual(b.activeRemote?.host, "host.local")
    }

    func testSkewFlagAndMessage() {
        let m = ComputeLocationModel(defaults: freshDefaults())
        let matching = DiscoveredWorker(id: "Mac mini", fingerprint: CoreFingerprint.value,
                                        endpoint: .hostPort(host: "127.0.0.1", port: 8757))
        let skewed = DiscoveredWorker(id: "Old Mac", fingerprint: "0000deadbeef",
                                      endpoint: .hostPort(host: "127.0.0.1", port: 8757))
        let unknown = DiscoveredWorker(id: "No TXT", fingerprint: nil,
                                       endpoint: .hostPort(host: "127.0.0.1", port: 8757))
        XCTAssertFalse(m.isSkewed(matching), "same fingerprint → no skew")
        XCTAssertTrue(m.isSkewed(skewed), "different fingerprint → skew")
        XCTAssertFalse(m.isSkewed(unknown), "no advertised fingerprint → don't cry wolf")
        XCTAssertTrue(m.skewMessage(skewed).contains("Update core"),
                      "skew message points at the Mac app's Update core")
    }
}
