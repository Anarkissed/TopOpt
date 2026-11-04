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

@MainActor
final class ParityTopologyShots: XCTestCase {
    static let sizes: [(String, CGSize)] = [("13L", AppBuildHost.landscape13), ("11P", CGSize(width: 820, height: 1180))]

    func page(_ size: CGSize) throws -> (AppBuildHost, ProjectModel) {
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
        let s2 = p.force.addScenario(); p.force.renameScenario(s2, to: "Held by left plate")
        let s3 = p.force.addScenario(); p.force.renameScenario(s3, to: "Held by right plate")
        let s1 = p.force.scenarioList[0].id
        p.force.renameScenario(s1, to: "Normal use")
        _ = s3
        p.force.openScenario(s1)
        p.force.sync(groups: p.selection.groups)
        let h = AppBuildHost(WorkspacePlaceholder(model: r.app, project: p), size: size, test: self)
        h.pump(3)
        return (h, p)
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
            let (h, _) = try page(size)
            try shot(h, "topo-setup", name)
            if h.frames.all["setupChip"] != nil {
                try h.tap("setupChip", "Settings")
                h.pump(0.5)
                try shot(h, "corner-settings", name)
            }
        }
    }
}
#endif
