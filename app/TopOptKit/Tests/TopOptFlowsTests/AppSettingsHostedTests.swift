// AppSettingsHostedTests — B5 (approved design 2026-11-02, Q12 "Yes", app-map §3.10, plan.md §B5, mockup #app-settings).
//
// Library ⋯ › Settings, "For every new part": Safety margin, Runs on, Camera, Storage ›, then Done. The margin is the one a
// new part starts with (150 % stores nothing, so the job is today's); Camera is the app's one projection choice. Units and
// Accent wait on the reviewer's answer. RED before B5 (saved: scratchpad b2red/AppSettings.txt): the Library's ⋯ had no
// Settings and a new part ignored the default.
#if canImport(AppKit) && canImport(MetalKit)
import XCTest
import SwiftUI
import AppKit
@testable import TopOptFlows
@testable import TopOptKit

@MainActor
final class AppSettingsHostedTests: XCTestCase {
    let ui = LoadScenarioHostedTests()
    var suite: UserDefaults!
    var suiteName = ""

    override func setUp() {
        super.setUp()
        suiteName = "AppSettingsHostedTests-\(UUID().uuidString)"
        suite = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        suite.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    func testTheRowsTheCameraAndStorage() throws {
        let settings = AppSettings(defaults: suite), projection = ViewProjection(defaults: suite)
        let compute = ComputeLocationModel(defaults: suite)
        var storage = 0, done = 0
        let size = CGSize(width: 600, height: 700)
        let h = ui.host(AppSettingsView(settings: settings, projection: projection, compute: compute,
                                        storage: { storage += 1 }, done: { done += 1 })
                            .frame(width: size.width, height: size.height), size: size)
        ui.pump(1)
        var last = -CGFloat.infinity
        for label in ["Safety margin", "Runs on", "Camera", "Storage"] {
            let r = try XCTUnwrap(h.frames.all["appSettingsRow-\(label)"], "★ the \(label) row: \(h.frames.all.keys.filter { $0.hasPrefix("appSettings") }.sorted())")
            XCTAssertGreaterThanOrEqual(r.height, 43.5, "\(label): one 44 pt line")
            XCTAssertGreaterThan(r.minY, last, "\(label): in the design's order")
            last = r.minY
        }
        XCTAssertNotNil(h.frames.all["appSettingsMargin"], "★ the margin's value, a menu")
        // Camera: Orthographic is the right segment
        XCTAssertFalse(projection.orthographic)
        let cam = try XCTUnwrap(h.frames.all["appSettingsRow-Camera"])
        ui.click(h, CGPoint(x: cam.maxX - 70, y: cam.midY))
        XCTAssertTrue(projection.orthographic, "★ the app's one projection choice")
        XCTAssertTrue(suite.bool(forKey: ViewProjection.defaultsKey), "remembered on this device")
        let s = try XCTUnwrap(h.frames.all["appSettingsStorage"])
        ui.click(h, CGPoint(x: s.midX, y: s.midY))
        XCTAssertEqual(storage, 1, "★ Storage › opens the Storage page")
        let d = try XCTUnwrap(h.frames.all["appSettingsDone"])
        ui.click(h, CGPoint(x: d.midX, y: d.midY))
        XCTAssertEqual(done, 1)
    }

    func testANewPartStartsFromTheDefaultMargin() throws {
        let settings = AppSettings(defaults: suite)
        XCTAssertEqual(settings.safetyMargin, 1.5, "150 % until he picks another")
        var f = ForceModel()
        settings.apply(to: &f)
        XCTAssertNil(f.safetyMargin, "★ the default stores nothing: the job bytes are today's")
        settings.safetyMargin = 2.0
        XCTAssertEqual(AppSettings(defaults: suite).safetyMargin, 2.0, "remembered on this device")
        settings.apply(to: &f)
        XCTAssertEqual(f.safetyMarginValue, 2.0, "★ a new part starts at his default")
        suite.set(1.0, forKey: AppSettings.marginKey)
        XCTAssertEqual(AppSettings(defaults: suite).safetyMargin, 1.5, "never below the minimum")
        XCTAssertEqual(AppSettingsCopy.marginLabel(2.0), "Everyday part \u{00B7} 200 %")
        // the wiring: a new part takes it, and Library ⋯ opens the sheet
        let app = try FlexibleSource.code("AppModel.swift")
        let cont = try XCTUnwrap(app.range(of: "public func continueToWorkspace()"))
        XCTAssertTrue(String(app[cont.lowerBound...].prefix(1_400)).contains("AppSettings.shared.apply(to: &pm.force)"))
        let lib = try FlexibleSource.code("LibraryViews.swift")
        XCTAssertTrue(lib.contains("Button { settingsOpen = true } label: { Label(\"Settings\", systemImage: \"gearshape\") }"),
                      "★ Library ⋯ › Settings")
        XCTAssertTrue(lib.contains("AppSettingsView(settings: AppSettings.shared, projection: ViewProjection.shared"))
    }
}
#endif
