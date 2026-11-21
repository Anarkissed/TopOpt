// B10CensusProbe — B10 (the uniformity sweep; the reviewer's scope ruling 11-11 03:50Z, (A) corrected): an OPT-IN probe
// (B10_CENSUS_DIR=<dir>, outside the repo) that hosts every page at the sweep's six windows — 13″, 11″ and More Space, each in
// landscape and portrait — and writes, per page and window, every published frame (ChromeKeepOutKey) as JSON and the page as
// a PNG (the 3D view draws nothing offscreen). It asserts nothing; the sweep's U-tests are written from what it records.
// Kept pages (fixed in B10): the Library (home, part), Import / New part, Topology Setup and its Settings, Run, Results
// (topology), Cut, App settings. Read-only (listed, never fixed): the Lattice stage, the Lattice page.
#if canImport(AppKit) && canImport(MetalKit)
import XCTest
import SwiftUI
import AppKit
import TopOptDesign
@testable import TopOptFlows
@testable import TopOptKit

@MainActor
final class B10CensusProbe: XCTestCase {
    /// The sweep's six windows: three sizes, both orientations.
    static let windows: [(String, CGSize)] = [
        ("13L", AppBuildHost.landscape13), ("13P", AppBuildHost.portrait13),
        ("11L", AppBuildHost.landscape11), ("11P", CGSize(width: 820, height: 1180)),
        ("MSL", AppBuildHost.moreSpace), ("MSP", CGSize(width: 1192, height: 1590)),
    ]

    var dir: URL!
    private var root: URL!
    private var index: [String] = []

    override func setUpWithError() throws {
        guard let d = ProcessInfo.processInfo.environment["B10_CENSUS_DIR"] else { throw XCTSkip("opt-in: B10_CENSUS_DIR") }
        dir = URL(fileURLWithPath: d)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        root = FileManager.default.temporaryDirectory.appendingPathComponent("b10-census-\(UUID().uuidString)", isDirectory: true)
    }
    override func tearDownWithError() throws {
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    /// One page at one window: its frames (JSON) and its picture (PNG).
    func record(_ h: AppBuildHost, _ page: String, _ win: String) {
        h.pump(0.6)
        let name = "\(page)__\(win)"
        let frames = h.frames.all.mapValues { [$0.minX, $0.minY, $0.width, $0.height].map { ($0 * 10).rounded() / 10 } }
        let json: [String: Any] = ["page": page, "window": win, "size": [h.size.width, h.size.height], "frames": frames]
        if let d = try? JSONSerialization.data(withJSONObject: json, options: [.sortedKeys, .prettyPrinted]) {
            try? d.write(to: dir.appendingPathComponent("\(name).json"))
        }
        h.view.layoutSubtreeIfNeeded()
        if let rep = h.view.bitmapImageRepForCachingDisplay(in: h.view.bounds) {
            h.view.cacheDisplay(in: h.view.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent("\(name).png"))
        }
        index.append("\(name)\t\(frames.count) frames")
    }
    func miss(_ page: String, _ win: String, _ why: String) { index.append("\(page)__\(win)\tMISSED: \(why)") }
    func writeIndex(_ tag: String) {
        try? index.joined(separator: "\n").write(to: dir.appendingPathComponent("index-\(tag).txt"), atomically: true, encoding: .utf8)
    }

    /// The workspace pages on a Structural lookalike with results (UniformChromeHostedTests' route).
    func testWorkspacePages() throws {
        for (win, size) in Self.windows {
            do {
                let r = try FlexiblePressFixtures.a1Project(3, self, facePrism: false)
                let p = r.project
                p.lattice.flexible = nil
                p.lattice.chooseLatticeType(.structural)
                p.run.restoreOutcome(AppBuildFixtures.outcome())
                let h = AppBuildHost(WorkspacePlaceholder(model: r.app, project: p), size: size, test: self)
                h.pump(3)
                record(h, "topo-setup", win)
                if h.frames.all["setupChip"] != nil {
                    try h.tap("setupChip", "Settings", settle: 1.2)
                    record(h, "topo-settings", win)
                    try h.tap("setupChip", "Settings, shut", settle: 1)
                } else { miss("topo-settings", win, "no setupChip") }
                try h.tap("capsuleResults", "Results", settle: 2)
                record(h, "topo-results", win)
                try h.tap("capsuleSetup", "back to Setup", settle: 1.5)
                _ = try h.pickFromMenu("capsuleMenu", "Structural", what: "the stage menu")
                h.pump(1.5)
                record(h, "RO-lattice-stage", win)
                try h.tap("capsuleLattice", "the Lattice page", settle: 2)
                record(h, "RO-lattice-page", win)
                // Cut last (UniformChromeHostedTests' route: from the Lattice page, Setup, then the scissors)
                try h.tap("capsuleSetup", "back to Setup", settle: 1.5)
                try h.tap("capsuleScissors", "Edit faces", settle: 2)
                record(h, "cut", win)
            } catch { miss("workspace", win, "\(error)") }
        }
        writeIndex("workspace")
    }

    /// Run: Optimize on a lookalike with no results, a slow stand-in runner; the running corner and the run card.
    /// (Not `testRun`: XCTest's own `testRun` property answers that selector, so the body never ran.)
    func testRunCard() throws {
        RunModel.hostedTestRunner = { _, progress, _ in
            for i in 0..<200 { if !progress(0, 3, i) { break }; Thread.sleep(forTimeInterval: 0.1) }
            return AppBuildFixtures.outcome()
        }
        defer { RunModel.hostedTestRunner = nil }
        for (win, size) in Self.windows {
            do {
                let r = try FlexiblePressFixtures.a1Project(3, self, facePrism: false)
                let p = r.project
                p.lattice.flexible = nil
                let h = AppBuildHost(WorkspacePlaceholder(model: r.app, project: p), size: size, test: self)
                h.pump(3)
                try h.tap("optimizeButton", "Optimize", settle: 1)
                let end = Date().addingTimeInterval(3)
                while p.run.phase != .running, Date() < end { h.pump(0.1) }
                record(h, "topo-run-card", win)
                if h.frames.all["runCardBackground"] != nil {
                    try h.tap("runCardBackground", "Run in background", settle: 0.8)
                    record(h, "topo-run-background", win)
                }
                p.run.cancel()
                let stop = Date().addingTimeInterval(5)
                while p.run.phase == .running, Date() < stop { h.pump(0.1) }
            } catch { miss("run", win, "\(error)") }
        }
        writeIndex("run")
    }

    /// The Library (home, the part page) on the Carriage Arms lookalike (LibraryPartRowsHostedTests.arms).
    func testLibrary() throws {
        for (win, size) in Self.windows {
            do {
                let (app, f) = try LibraryPartRowsHostedTests.arms(root: root.appendingPathComponent(win, isDirectory: true))
                app.library.route = .home
                let h = AppBuildHost(AppBuildRoot(model: app), size: size, test: self)
                h.pump(3)
                record(h, "lib-home", win)
                if let part = app.library.index.part(containing: try XCTUnwrap(f["2"])) {
                    app.library.route = .part(part.id)
                    h.pump(2)
                    record(h, "lib-part", win)
                }
                if let proj = app.library.index.projects.first {
                    app.library.route = .project(proj.id)
                    h.pump(2)
                    record(h, "lib-project", win)
                }
            } catch { miss("library", win, "\(error)") }
        }
        writeIndex("library")
    }

    /// The sheets as they draw over a page: New TopOpt (Import / New part) and App settings, each in the window.
    func testSheets() throws {
        let suite = "B10CensusProbe-\(UUID().uuidString)"
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        for (win, size) in Self.windows {
            do {
                let (app, _) = try LibraryPartRowsHostedTests.arms(root: root.appendingPathComponent("s" + win, isDirectory: true))
                app.newTopOpt()
                let hi = AppBuildHost(ZStack { DS.Color.background.color.ignoresSafeArea(); GlassSheet { ImportSheet(model: app) } },
                                      size: size, test: self)
                hi.pump(2)
                record(hi, "import", win)
                let d = try XCTUnwrap(UserDefaults(suiteName: suite))
                let hs = AppBuildHost(ZStack {
                    DS.Color.background.color.ignoresSafeArea()
                    AppSettingsView(settings: AppSettings(defaults: d), projection: ViewProjection(defaults: d),
                                    compute: ComputeLocationModel(defaults: d), storage: {}, done: {})
                        .frame(width: min(600, size.width - 64), height: min(700, size.height - 64))
                }, size: size, test: self)
                hs.pump(1.5)
                record(hs, "app-settings", win)
            } catch { miss("sheets", win, "\(error)") }
        }
        writeIndex("sheets")
    }
}
#endif
