// FlexibleB10CensusProbe — B10 Flexible part 2 (#362; the reviewer's 03:50Z ruling: "#362 fixes the Flexible pages"). An OPT-IN
// probe (B10_CENSUS_DIR=<dir>, outside the repo), the Flexible twin of UI-Notes' B10CensusProbe: HIS pad lookalike (A1_0003 + his
// live lattice, Group C) on the whole page at the sweep's six windows, and, per page and window, every frame the page publishes
// (FlexibleKeepOutKey and ChromeKeepOutKey) as JSON and the page as a PNG (the 3D view draws nothing offscreen). It asserts
// nothing; the Flexible sweep's U-tests are written from what it records.
// Pages: the Flexible main page (nothing picked; Group C picked), the Squish page (Model tab; Group C's tab), the Print plan.
#if canImport(AppKit) && canImport(MetalKit)
import XCTest
import SwiftUI
import AppKit
import TopOptDesign
@testable import TopOptFlows
@testable import TopOptKit

@MainActor
final class FlexibleB10CensusProbe: XCTestCase {
    var dir: URL!
    private var index: [String] = []

    override func setUpWithError() throws {
        guard let d = ProcessInfo.processInfo.environment["B10_CENSUS_DIR"] else { throw XCTSkip("opt-in: B10_CENSUS_DIR") }
        dir = URL(fileURLWithPath: d)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    /// One page at one window: both keys' frames (JSON) and its picture (PNG).
    func record(_ h: SquishHost, _ page: String, _ win: String) {
        SquishHost.pump(0.6)
        let name = "\(page)__\(win)"
        func json(_ d: [String: CGRect]) -> [String: [Double]] {
            d.filter { $0.value.width > 0 || $0.value.height > 0 }
                .mapValues { [$0.minX, $0.minY, $0.width, $0.height].map { (Double($0) * 10).rounded() / 10 } }
        }
        let out: [String: Any] = ["page": page, "window": win, "size": [h.size.width, h.size.height],
                                  "flexible": json(h.keys.flexible), "chrome": json(h.keys.chrome)]
        if let d = try? JSONSerialization.data(withJSONObject: out, options: [.sortedKeys, .prettyPrinted]) {
            try? d.write(to: dir.appendingPathComponent("\(name).json"))
        }
        h.view.layoutSubtreeIfNeeded()
        if let rep = h.view.bitmapImageRepForCachingDisplay(in: h.view.bounds) {
            h.view.cacheDisplay(in: h.view.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent("\(name).png"))
        }
        index.append("\(name)\t\(h.keys.flexible.count) flexible + \(h.keys.chrome.count) chrome frames")
    }
    func miss(_ page: String, _ win: String, _ why: String) { index.append("\(page)__\(win)\tMISSED: \(why)") }

    func testFlexiblePages() throws {
        Bundle.r7m1vSwap
        for (win, size) in B10CensusProbe.windows {
            do {
                let r = try FlexiblePressFixtures.a1Project(3, self, facePrism: false)
                let p = r.project
                let c = try FlexibleR7M1Fixtures.hisLiveLattice(p)
                let h = SquishHost(WorkspacePlaceholder(model: r.app, project: p), size: size, test: self)
                SquishHost.pump(4)
                try FlexiblePressFixtures.enterLatticeStage(p, click: { h.click($0) })
                SquishHost.pump(3)
                let s = try XCTUnwrap(FlexibleMainStage.lastMade, "the page's stage")
                if let m = s.model { addTeardownBlock { @MainActor in await m.waitForIdle() } }
                s.faceUI.toastSeconds = 120
                record(h, "flex-main", win)
                s.pickGroup(c, project: p)
                SquishHost.pump(1.2)
                record(h, "flex-group", win)
                if h.frame("capsuleSquish") != nil {
                    try h.tap("capsuleSquish", "Squish", settle: 3)
                    if let m = s.model {
                        SquishHost.pumpUntil(60) { m.sceneState == .ready }
                        m.selectedRegion = nil; m.rail = .model
                    }
                    SquishHost.pump(1.5)
                    record(h, "squish-model", win)
                    if let m = s.model, let g = m.squeezeGroups.first {
                        m.rail = .group(g.id)
                        SquishHost.pump(1.2)
                        record(h, "squish-group", win)
                    }
                    if h.frame("squishCancel") != nil { try h.tap("squishCancel", "Cancel", settle: 2) }
                } else { miss("squish", win, "no capsuleSquish") }
                if h.frame("capsulePlan") != nil {
                    try h.tap("capsulePlan", "Print plan", settle: 2)
                    record(h, "print-plan", win)
                } else { miss("print-plan", win, "no capsulePlan") }
            } catch { miss("flexible", win, "\(error)") }
        }
        try? index.joined(separator: "\n").write(to: dir.appendingPathComponent("index-flexible.txt"), atomically: true, encoding: .utf8)
    }
}
#endif
