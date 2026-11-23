// PrintAccurateDefaultTests — ★ his iPad notes 2026-11-23: "The "Print-accurate preview" was automatically on when I started, it
// should be defaulted off." His earlier ON was kept in the app's preferences across installs (RESULTS_REPORT §6); the switch's
// key is v2 now, so that old value is never read.
import XCTest
@testable import TopOptFlows

@MainActor
final class PrintAccurateDefaultTests: XCTestCase {

    /// ★ An install that kept ON under the old key starts OFF; his new choice is kept. RED CONTROL: the old key holds true.
    func testAnOldOnIsNotReadAndTheSwitchStartsOff() throws {
        let d = try XCTUnwrap(UserDefaults(suiteName: "PrintAccurateDefaultTests-\(UUID().uuidString)"))
        d.set(true, forKey: AppSettings.printAccurateKeyV1)   // what release 15 and earlier kept
        XCTAssertTrue(d.bool(forKey: AppSettings.printAccurateKeyV1), "RED CONTROL: his old ON is in the preferences")
        XCTAssertNotEqual(AppSettings.printAccurateKey, AppSettings.printAccurateKeyV1)
        XCTAssertEqual(AppSettings.printAccurateKey, "topopt.settings.latticePrintAccurate.v2")
        XCTAssertFalse(AppSettings(defaults: d).latticePrintAccurate, "★ off when he starts")
        let a = AppSettings(defaults: d)
        a.latticePrintAccurate = true
        XCTAssertTrue(AppSettings(defaults: d).latticePrintAccurate, "★ his own choice from now on is kept")
        a.latticePrintAccurate = false
        XCTAssertFalse(AppSettings(defaults: d).latticePrintAccurate)
    }
}
