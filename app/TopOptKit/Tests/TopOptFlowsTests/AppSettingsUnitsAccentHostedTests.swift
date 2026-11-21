// AppSettingsUnitsAccentHostedTests — B5 (Q12; the reviewer's answers 11-04 02:44Z to my 01:55Z question, his confirmed
// Library list item 5): App settings' Units and Accent rows (mockup #app-settings).
//
//   Units (a): "Add N to Topology's unit, display only, with storage kept in kgf (N = kgf × 9.80665). The setting is each new
//              part's starting unit on both stages."
//   Accent (a): "Applied live when Settings closes. Settings is Library-only, so no open work is affected."
//
// RED before (saved: scratchpad b2red/AppSettingsUnitsAccent.txt): Topology's unit was kg │ lb only, the sheet had no Units or
// Accent row, and the accent was a fixed token (four copies of it were frozen at first use).
#if canImport(AppKit) && canImport(MetalKit)
import XCTest
import SwiftUI
import AppKit
@testable import TopOptFlows
@testable import TopOptKit
import TopOptDesign

@MainActor
final class AppSettingsUnitsAccentHostedTests: XCTestCase {
    let ui = LoadScenarioHostedTests()
    var suite: UserDefaults!
    var suiteName = ""

    override func setUp() {
        super.setUp()
        suiteName = "AppSettingsUnitsAccentHostedTests-\(UUID().uuidString)"
        suite = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        suite.removePersistentDomain(forName: suiteName)
        // the app's own choices go back to blue / unset, so no other test sees them
        AppSettings.shared.accent = .blue
        AppSettings.shared.applyAccent()
        UserDefaults.standard.removeObject(forKey: AppSettings.accentKey)
        UserDefaults.standard.removeObject(forKey: AppSettings.unitsKey)
        super.tearDown()
    }

    // MARK: - Units

    /// Topology reads N; what is stored stays kgf, so the job never changes with the unit.
    func testTopologyReadsNewtonsAndStoresKgf() throws {
        XCTAssertEqual(WeightUnit.allCases.map(\.label), ["kg", "lb", "N"], "★ [kg │ lb │ N]")
        var fm = ForceModel()
        fm.unit = .N
        XCTAssertEqual(fm.formattedWeight(kg: 2.5), "25 N", "★ 2.5 kgf = 24.5 N, read as the workspace reads a weight")
        XCTAssertEqual(fm.formattedWeight(kg: 0.5), "4.9 N")
        XCTAssertEqual(WeightUnit.N.fromKg(1), ForceModel.gravityAccel, "N = kgf × 9.80665")
        XCTAssertEqual(WeightUnit.N.toKg(WeightUnit.N.fromKg(7.3)), 7.3, accuracy: 1e-12, "typed back to the same kgf")
        XCTAssertEqual(WeightUnit.lbs.fromKg(10), 10 * ForceModel.kgToLb, "lb as before, byte for byte")
        XCTAssertEqual(WeightUnit.lbs.toKg(22), 22 / ForceModel.kgToLb)
        XCTAssertEqual(fm.scrub(kg: 2.5, byPoints: 10), 2.5 + 10 * 0.5 / ForceModel.gravityAccel, accuracy: 1e-12,
                       "a drag steps 0.5 N a point (about the kg step)")
        XCTAssertEqual(ResultsModel.loadLabel(kg: 7.5, unit: .N), "74 N", "the Results failure load in his unit")
        XCTAssertEqual(WeightUnit.N.boxStep, 5)
        XCTAssertEqual(WeightUnit.N.boxDecimals, 0)
        XCTAssertEqual(WeightUnit.kg.boxStep, 0.5, "kg │ lb boxes as before")
        XCTAssertEqual(WeightUnit.lbs.boxDecimals, 1)
        let back = try JSONDecoder().decode(ForceModel.self, from: try JSONEncoder().encode(fm))
        XCTAssertEqual(back.unit, .N, "a part saved in N reopens in N")

        // the job: the same part in kg and in N sends the same bytes
        let r = try FlexiblePressFixtures.a1Project(3, self, facePrism: false)
        let p = r.project
        p.lattice.flexible = nil
        p.lattice.chooseLatticeType(.structural)
        if let c = p.selection.groups.first(where: { $0.name == "Group C" }) { p.force.makeAnchor(c.id) }
        p.force.unit = .kg
        let kgJob = try RemoteRun.buildJobJSON(try XCTUnwrap(r.app.makeRunRequest(lattice: false)))
        let kgAgain = try RemoteRun.buildJobJSON(try XCTUnwrap(r.app.makeRunRequest(lattice: false)))
        p.force.unit = .N
        let nJob = try RemoteRun.buildJobJSON(try XCTUnwrap(r.app.makeRunRequest(lattice: false)))
        XCTAssertEqual(try Self.differing(kgJob, kgAgain), [], "control: the same setup twice")
        XCTAssertEqual(try Self.differing(kgJob, nJob), [], "★ display only: the unit never reaches the job")
    }

    /// The paths where two jobs' values differ, read as JSON (so key order is not a difference).
    static func differing(_ a: Data, _ b: Data) throws -> [String] {
        func walk(_ x: Any?, _ y: Any?, _ path: String, _ out: inout [String]) {
            if let dx = x as? [String: Any], let dy = y as? [String: Any] {
                for k in Set(dx.keys).union(dy.keys).sorted() { walk(dx[k], dy[k], path + "." + k, &out) }
            } else if let ax = x as? [Any], let ay = y as? [Any], ax.count == ay.count {
                for i in ax.indices { walk(ax[i], ay[i], path + "[\(i)]", &out) }
            } else if let x, let y, NSDictionary(dictionary: ["v": x]).isEqual(to: ["v": y]) {
                return
            } else {
                out.append("\(path): \(x.map { "\($0)" } ?? "nil") → \(y.map { "\($0)" } ?? "nil")")
            }
        }
        var out: [String] = []
        walk(try JSONSerialization.jsonObject(with: a), try JSONSerialization.jsonObject(with: b), "job", &out)
        return out
    }

    // MARK: - the sheet

    func testTheSheetHasUnitsAndAccentInTheDesignsOrder() throws {
        let settings = AppSettings(defaults: suite), projection = ViewProjection(defaults: suite)
        let compute = ComputeLocationModel(defaults: suite)
        let size = CGSize(width: 600, height: 760)
        let h = ui.host(AppSettingsView(settings: settings, projection: projection, compute: compute,
                                        storage: {}, done: {})
                            .frame(width: size.width, height: size.height), size: size)
        ui.pump(1)
        var last = -CGFloat.infinity
        for label in ["Units", "Safety margin", "Runs on", "Camera", "Accent", "Storage"] {
            let r = try XCTUnwrap(h.frames.all["appSettingsRow-\(label)"], "★ the \(label) row: \(h.frames.all.keys.filter { $0.hasPrefix("appSettings") }.sorted())")
            XCTAssertGreaterThanOrEqual(r.height, 43.5, "\(label): one 44 pt line")
            XCTAssertGreaterThan(r.minY, last, "★ \(label): in the mockup's order")
            last = r.minY
        }
        // Units: [kg │ lb │ N], the right third is N
        let units = try XCTUnwrap(h.frames.all["appSettingsUnits"], "★ Units' segments")
        ui.click(h, CGPoint(x: units.maxX - units.width / 6, y: units.midY))
        XCTAssertEqual(settings.units, .N, "★ N")
        XCTAssertEqual(suite.string(forKey: AppSettings.unitsKey), "N", "remembered on this device")
        ui.click(h, CGPoint(x: units.midX, y: units.midY))
        XCTAssertEqual(settings.units, .lbs, "the middle is lb")
        ui.click(h, CGPoint(x: units.minX + units.width / 6, y: units.midY))
        XCTAssertEqual(settings.units, .kg, "the left is kg")
        // Accent: the mockup's four dots, each a 44 pt target, his pick ringed
        XCTAssertEqual(AccentChoice.allCases.map(\.rgba), [RGBA(hex: 0x0A84FF), RGBA(hex: 0x64D2FF), RGBA(hex: 0xBF5AF2),
                                                           RGBA(hex: 0x30D158)], "★ mockup #app-settings")
        var right = -CGFloat.infinity
        for a in AccentChoice.allCases {
            let dot = try XCTUnwrap(h.frames.all["appSettingsAccent-\(a.rawValue)"], "★ the \(a.name) dot")
            XCTAssertGreaterThanOrEqual(dot.width, 43.5, "\(a.name): a 44 pt target")
            XCTAssertGreaterThanOrEqual(dot.height, 43.5)
            XCTAssertGreaterThan(dot.minX, right - 0.5, "\(a.name): in the mockup's order")
            right = dot.maxX
        }
        XCTAssertNotNil(h.frames.all["appSettingsAccentRing-blue"], "the one in use is ringed")
        let purple = try XCTUnwrap(h.frames.all["appSettingsAccent-purple"])
        let before = DS.Color.accent
        ui.click(h, CGPoint(x: purple.midX, y: purple.midY))
        XCTAssertEqual(settings.accent, .purple, "★ his pick")
        XCTAssertEqual(suite.string(forKey: AppSettings.accentKey), "purple", "remembered on this device")
        XCTAssertNotNil(h.frames.all["appSettingsAccentRing-purple"], "★ the ring moves to his pick")
        XCTAssertNil(h.frames.all["appSettingsAccentRing-blue"])
        XCTAssertEqual(DS.Color.accent, before, "★ not yet: the app takes it when Settings closes")
        XCTAssertEqual(AppSettings(defaults: suite).accent, .purple, "a relaunch keeps it")
        XCTAssertEqual(AppSettings(defaults: suite).appliedAccent, .purple, "and wears it from the first draw")
    }

    // MARK: - a new part's starting unit, on both stages

    func testANewPartStartsInTheChosenUnitOnBothStages() throws {
        let settings = AppSettings(defaults: suite)
        // his answer (11-05, my chat): "kg" until he picks another — as the mockup draws it, and Flexible's start already
        XCTAssertEqual(settings.units, .kg, "★ kg until he picks another")
        XCTAssertNil(suite.string(forKey: AppSettings.unitsKey), "the default stores nothing")
        var k = ForceModel()
        XCTAssertEqual(k.unit, .lbs, "a part saved before units were a setting still reads lb (T4)")
        settings.apply(to: &k)
        XCTAssertEqual(k.unit, .kg, "★ a new Topology part starts in kg (it was lb)")
        XCTAssertNil(AppSettings.flexibleStartingUnit(suite), "★ and a new Flexible setup in kg, as today")
        settings.units = .N
        var f = ForceModel()
        settings.apply(to: &f)
        XCTAssertEqual(f.unit, .N, "★ Topology: a new part starts in his unit")
        XCTAssertEqual(AppSettings.flexibleStartingUnit(suite), "N", "★ Flexible: a new setup starts in it too")
        settings.units = .lbs
        XCTAssertEqual(AppSettings.flexibleStartingUnit(suite), "lb", "Flexible's own word for lb")
        settings.units = .kg
        XCTAssertNil(AppSettings.flexibleStartingUnit(suite), "kg stores nothing: Flexible's setup is today's")
        // the wiring: a new Flexible setup reads this device's choice (both of its doors: the Flexible import and H38')
        UserDefaults.standard.set("N", forKey: AppSettings.unitsKey)
        XCTAssertEqual(FlexibleStageSettings.newSetup().weightUnit, "N", "★ a new Flexible setup starts in N")
        UserDefaults.standard.set("kg", forKey: AppSettings.unitsKey)
        XCTAssertNil(FlexibleStageSettings.newSetup().weightUnit)
        // and an existing part keeps its own unit: only a new part's apply sets it
        let app = try FlexibleSource.code("AppModel.swift")
        let cont = try XCTUnwrap(app.range(of: "public func continueToWorkspace()"))
        XCTAssertTrue(String(app[cont.lowerBound...].prefix(1_400)).contains("AppSettings.shared.apply(to: &pm.force)"))
    }

    // MARK: - Accent, live when Settings closes

    /// The Library wears his accent once Settings closes: its "New TopOpt" circle turns purple (real pixels), and the four
    /// copies that were frozen at first use follow. Until then nothing changes.
    func testTheAccentIsLiveWhenSettingsCloses() throws {
        let r = try FlexiblePressFixtures.a1Project(3, self, facePrism: false)
        let app = r.app
        app.library.refresh()
        try app.library.group(projectName: "Squish Mechanism", partIDs: nil)
        app.backHome()
        let h = AppBuildHost(AppBuildRoot(model: app), size: AppBuildHost.landscape13, test: self)
        h.pump(2)
        let blue = RGBA(hex: 0x0A84FF), purple = RGBA(hex: 0xBF5AF2)
        try h.picture("accent-start.png")
        let start = try count(h, [blue, purple])
        XCTAssertEqual(start.count, 2)
        XCTAssertGreaterThan(start[0], 40, "the Library's accent is blue: \(start)")
        XCTAssertLessThan(start[1], 5, "no purple yet")
        AppSettings.shared.accent = .purple   // the dot, with Settings still open
        h.pump(0.5)
        XCTAssertLessThan(try count(h, [purple])[0], 5, "★ not live while Settings is open")
        AppSettings.shared.applyAccent()       // Settings closes (its sheet's onDismiss)
        h.pump(1)
        try h.picture("accent-after.png")
        let after = try count(h, [blue, purple])
        XCTAssertGreaterThan(after[1], 40, "★ the Library redraws in purple: \(after)")
        XCTAssertLessThan(after[0], start[0] - 30, "★ and its blue is gone: \(start) → \(after)")
        XCTAssertEqual(DS.Color.accent, purple)
        // the four copies that were frozen at first use
        XCTAssertEqual(JoinButton.fill, purple, "★ Topology's join button")
        XCTAssertEqual(FlexibleJoinButton.fill, purple, "★ Flexible's join button")
        XCTAssertEqual(LiquidGlass.Tint.blue.color, purple, "★ the glass's accent frost")
        XCTAssertEqual(DSParts.moreFill, purple.opacity(0.06), "★ the panel's n more ⌄ fill")
        XCTAssertEqual(ProjectFolderView.note,
                       "A part with nothing picked shows its original model. A picked result gets the purple ring.",
                       "★ the project page's note names the ring's colour")
        // the wiring: Settings' sheet applies it as it closes; the app wears his pick from launch
        let lib = try FlexibleSource.code("LibraryViews.swift")
        XCTAssertTrue(lib.contains(".sheet(isPresented: $settingsOpen, onDismiss: { AppSettings.shared.applyAccent() })"),
                      "★ applied when Settings closes (Done, Storage › or a swipe)")
        XCTAssertTrue(lib.contains(".id(appSettings.appliedAccent)"), "★ the Library redraws whole on the new accent")
        let model = try FlexibleSource.code("AppModel.swift")
        XCTAssertTrue(model.contains("_ = AppSettings.shared"), "★ the app wears his accent from the first draw")
    }

    /// How many sampled pixels of the page wear each colour: coloured, bright pixels within 10° of its HUE. (The capture is
    /// colour-managed, so a token's exact RGB never comes back; its hue does: measured 11-05, the + circle's blue reads
    /// s 0.71 h 213°, its purple s 0.48 h 276°; the dark glow round it has brightness ≤ 0.25 and stays out.)
    private func count(_ h: AppBuildHost, _ colours: [RGBA]) throws -> [Int] {
        h.view.layoutSubtreeIfNeeded()
        let rep = try XCTUnwrap(h.view.bitmapImageRepForCachingDisplay(in: h.view.bounds))
        h.view.cacheDisplay(in: h.view.bounds, to: rep)
        let hues = colours.map { NSColor(srgbRed: $0.r, green: $0.g, blue: $0.b, alpha: 1).hueComponent * 360 }
        var n = [Int](repeating: 0, count: colours.count)
        for y in stride(from: 0, to: rep.pixelsHigh, by: 3) {
            for x in stride(from: 0, to: rep.pixelsWide, by: 3) {
                guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB),
                      c.saturationComponent > 0.35, c.brightnessComponent > 0.6 else { continue }
                let hue = c.hueComponent * 360
                for (i, k) in hues.enumerated() where abs(hue - k) < 10 { n[i] += 1 }
            }
        }
        return n
    }
}
#endif
