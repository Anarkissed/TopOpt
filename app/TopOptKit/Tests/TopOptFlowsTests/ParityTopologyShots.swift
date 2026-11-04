// ParityTopologyShots — the reviewer's rule A (11-04 02:56Z): each screen's states, offscreen, next to mockup v5's same state
// (scratchpad/parity/mockshot.py renders those headless). Opt-in: PARITY_SHOT_DIR=<dir>; skipped otherwise. His A1 pad laid out
// like the mockup's Carriage Arms: three scenarios ("Normal use", "Held by left plate", "Held by right plate"), two anchors, a
// 51 kg push, a Protect group and a Keep clear group. The 3D view draws nothing offscreen (Metal) — the chrome is what's judged.
#if canImport(AppKit) && canImport(MetalKit)
import XCTest
import SwiftUI
import AppKit
@testable import TopOptFlows
@testable import TopOptKit

/// The workspace as RootView mounts it, with its notification lane (the "v8 is ready" message, the toasts).
private struct ParityRoot: View {
    @ObservedObject var model: AppModel
    var body: some View { AppBuildWorkspace(model: model).laneToast($model.toast) }
}

@MainActor
final class ParityTopologyShots: XCTestCase {
    static let sizes: [(String, CGSize)] = [("13L", AppBuildHost.landscape13), ("11P", CGSize(width: 820, height: 1180))]

    /// `scenarios`: the mockup's three folders, each with its own load.
    func page(_ size: CGSize, scenarios: Bool = true) throws -> (AppBuildHost, ProjectModel, AppModel) {
        let r = try FlexiblePressFixtures.a1Project(3, self, facePrism: false)
        let p = r.project
        p.lattice.flexible = nil
        // the mockup's groups, on his pad's faces
        let gs = p.selection.groups
        if let c = gs.first(where: { $0.name == "Group C" }) {
            p.force.makeLoad(c.id); p.force.setWeight(c.id, kg: 51)
        }
        let anchors = gs.filter { $0.name != "Group C" }.prefix(2).map(\.id)
        for a in anchors { p.force.makeAnchor(a) }
        // the pad has three groups: the second anchor carries the Protect (the mockup's Group D), so Settings shows Protect skin
        if let a = anchors.last { p.force.setProtected(a, true) }
        if scenarios {
            let s2 = p.force.addScenario(); p.force.renameScenario(s2, to: "Held by left plate")
            let s3 = p.force.addScenario(); p.force.renameScenario(s3, to: "Held by right plate")
            let s1 = p.force.scenarioList[0].id
            p.force.renameScenario(s1, to: "Normal use")
            // each folder its own load (T5: a scenario with none is a block), on a face of his pad no group holds
            let used = Set(p.selection.groups.flatMap(\.faces))
            var free = (0..<64).map { FaceID($0) }.filter { !used.contains($0) }.makeIterator()
            for s in [s2, s3] {
                p.force.openScenario(s)
                let g = p.selection.addGroup()
                if let f = free.next() { p.selection.addFaces([f], to: g) }
                p.force.makeLoad(g); p.force.setWeight(g, kg: 25)
            }
            p.force.openScenario(s1)
        }
        p.force.sync(groups: p.selection.groups)
        let h = AppBuildHost(ParityRoot(model: r.app), size: size, test: self)
        h.pump(3)
        return (h, p, r.app)
    }

    func shot(_ h: AppBuildHost, _ state: String, _ size: String) throws {
        guard let dir = ProcessInfo.processInfo.environment["PARITY_SHOT_DIR"] else { return }
        h.view.layoutSubtreeIfNeeded()
        let rep = try XCTUnwrap(h.view.bitmapImageRepForCachingDisplay(in: h.view.bounds))
        h.view.cacheDisplay(in: h.view.bounds, to: rep)
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try XCTUnwrap(rep.representation(using: .png, properties: [:]))
            .write(to: URL(fileURLWithPath: dir).appendingPathComponent("app_\(state)_\(size).png"))
    }

    func testTopologyStates() throws {
        guard ProcessInfo.processInfo.environment["PARITY_SHOT_DIR"] != nil else { throw XCTSkip("PARITY_SHOT_DIR not set") }
        for (name, size) in Self.sizes {
            let (h, _, _) = try page(size)
            try shot(h, "topo-setup", name)
            if h.frames.all["setupChip"] != nil {
                try h.tap("setupChip", "Settings")
                h.pump(0.5)
                try shot(h, "corner-settings", name)
            }
        }
    }

    /// The run button's states (mockup #topo-corner): finding his Mac, his Mac not answering, blocked, running, landed. His
    /// remembered Mac and Bonjour as RememberedMacHostedTests sets them; the core is RunModel.hostedTestRunner.
    func testTopologyRunStates() throws {
        guard ProcessInfo.processInfo.environment["PARITY_SHOT_DIR"] != nil else { throw XCTSkip("PARITY_SHOT_DIR not set") }
        let key = RememberedMacHostedTests.key, mac = RememberedMacHostedTests.mac
        let saved = UserDefaults.standard.data(forKey: key), find = ComputeLocationModel.findSeconds
        UserDefaults.standard.set(try JSONEncoder().encode(ComputeChoice.worker(name: mac)), forKey: key)
        addTeardownBlock { @MainActor in
            if let saved { UserDefaults.standard.set(saved, forKey: key) } else { UserDefaults.standard.removeObject(forKey: key) }
            ComputeLocationModel.hostedTestDiscovery = nil
            ComputeLocationModel.findSeconds = find
            RunModel.hostedTestRunner = nil
        }
        func optimize(_ h: AppBuildHost) throws {
            let f = try h.onScreen("optimizeSplit", "Optimize")
            h.click(CGPoint(x: f.minX + (f.width - 76) / 2, y: f.midY), settle: 0.4)   // the run button, not the ⌃
        }
        func waitUntil(_ h: AppBuildHost, _ s: Double, _ cond: () -> Bool) {
            let end = Date().addingTimeInterval(s)
            while !cond(), Date() < end { h.pump(0.1) }
        }
        for (name, size) in Self.sizes {
            // finding his Mac, then not answering
            ComputeLocationModel.findSeconds = 2
            ComputeLocationModel.hostedTestDiscovery = (mac, nil, 0)
            RunModel.hostedTestRunner = { _, _, _ in AppBuildFixtures.outcome() }
            var (h, p, _) = try page(size)
            try optimize(h)
            try shot(h, "topo-finding", name)
            h.pump(2.6)
            try shot(h, "topo-nomac", name)
            // blocked: a group with faces and no role
            (h, p, _) = try page(size)
            if let c = p.selection.groups.first(where: { $0.name == "Group C" }) { p.force.clearKind(c.id) }
            h.pump(0.6)
            try shot(h, "topo-blocked", name)
            // running, then landed: his Mac answers at once; the core takes 4 s
            ComputeLocationModel.hostedTestDiscovery = (mac, RemoteRunnerConfig(host: "10.0.0.9", port: 8757,
                                                                                expectedFingerprint: CoreFingerprint.value), 0)
            RunModel.hostedTestRunner = { _, progress, _ in
                for i in 0..<8 { _ = progress(1, 3, i * 10); Thread.sleep(forTimeInterval: 0.5) }
                return AppBuildFixtures.outcome()
            }
            (h, p, _) = try page(size)
            h.pump(0.6)
            try optimize(h)
            waitUntil(h, 4) { p.run.phase == .running }
            h.pump(1)
            try shot(h, "topo-run", name)
            waitUntil(h, 15) { p.run.phase == .succeeded }
            h.pump(1)
            try shot(h, "topo-landed", name)
        }
    }
}
#endif
