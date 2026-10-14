// FlexibleR7SettingsHostedTests — round 7 batch S, the Settings page HOSTED in a window (offscreen, never the app) on HIS
// pad (A1_0003 as he saved it, plus I2's Edge 9 edges group), at 11" and 13", portrait and landscape. Written BEFORE the
// code (his img3 words of 2026-10-14: "All groups should have a trash icon next to them and their names should be editable
// by tapping "group 1" or whatever the default name is."; img4: "I should only be able to view numbers associated to what
// I'm working on.").
//   * every group's header has a trash of at least 44 pt — including the ONLY group's (RED: today's × is 32 pt and shows
//     only with two or more groups);
//   * the name is one line, and a tap on it opens a one-line field;
//   * the edges group's tab mounts no face's depth chip ('flexible-depth-chip', his img4's "3.0 mm").
// FLEX_R7S_EVIDENCE_DIR=<dir> also writes the panel at each size.
#if canImport(AppKit)
import XCTest
import SwiftUI
import AppKit
import simd
import TopOptDesign
@testable import TopOptFlows
@testable import TopOptKit

private final class R7SHostWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

@MainActor
final class FlexibleR7SettingsHostedTests: XCTestCase {
    typealias G = FlexibleAngledGoldens

    final class Frames { var all: [String: CGRect] = [:]; var marks: [String: CGRect] = [:] }
    struct Host { let window: NSWindow; let view: NSView; let size: CGSize; let frames: Frames }

    static var dir: URL? { ProcessInfo.processInfo.environment["FLEX_R7S_EVIDENCE_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) } }

    func pump(_ seconds: Double) {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end { _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.02)) }
    }

    func host<V: View>(_ v: V, size: CGSize) -> Host {
        let frames = Frames()
        let root = AnyView(v.onPreferenceChange(FlexibleKeepOutKey.self) { frames.all = $0 }
            .onPreferenceChange(FlexibleViewMarksKey.self) { frames.marks = $0 }
            .environment(\.colorScheme, .dark))
        let hv = NSHostingView(rootView: root)
        hv.frame = CGRect(origin: .zero, size: size)
        _ = NSApplication.shared
        let w = R7SHostWindow(contentRect: CGRect(x: -20000, y: -20000, width: size.width, height: size.height),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        w.appearance = NSAppearance(named: .darkAqua)
        w.contentView = hv
        w.setFrameOrigin(NSPoint(x: -20000, y: -20000))
        w.orderFrontRegardless()
        w.makeKey()
        hv.layoutSubtreeIfNeeded()
        addTeardownBlock { @MainActor in w.orderOut(nil); w.contentView = nil }
        return Host(window: w, view: hv, size: size, frames: frames)
    }

    func local(_ h: Host, _ name: String) -> CGRect? {
        guard let f = h.frames.all[name] else { return nil }
        guard let page = h.frames.all["page"] else { return f }
        return f.offsetBy(dx: -page.minX, dy: -page.minY)
    }

    func click(_ h: Host, _ p: CGPoint) {
        let loc = NSPoint(x: p.x, y: h.size.height - p.y)
        for t in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let e = NSEvent.mouseEvent(with: t, location: loc, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                       windowNumber: h.window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
            h.window.sendEvent(e)
            pump(0.06)
        }
    }

    func snapshot(_ h: Host, _ name: String) {
        guard let dir = Self.dir else { return }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        h.view.layoutSubtreeIfNeeded()
        guard let rep = h.view.bitmapImageRepForCachingDisplay(in: h.view.bounds) else { return }
        h.view.cacheDisplay(in: h.view.bounds, to: rep)
        if let data = rep.representation(using: .png, properties: [:]) { try? data.write(to: dir.appendingPathComponent(name)) }
    }

    static let sizes: [(String, CGSize)] = [("11l", CGSize(width: 1194, height: 834)), ("11p", CGSize(width: 834, height: 1194)),
                                             ("13p", CGSize(width: 1032, height: 1376)), ("13l", CGSize(width: 1376, height: 1032))]

    func hisPadWithEdges() async throws -> (FlexibleHisProject.Restored, FlexibleStageModel, UUID) {
        let r = try FlexiblePressFixtures.a1Project(3, self)
        let m = try await G.openModel(self, r.project, "A1_0003")
        try await FlexibleSquishFixture.settle(m, "A1_0003")
        m.rail = .newGroup
        m.startEdgePick()
        try await FlexibleHisProject.waitFor(240, "the edges and corners listed") { m.edgePick.map { !$0.loading && !$0.checking } ?? false }
        await m.waitForIdle()
        let c = try XCTUnwrap(m.edgePick?.candidates.first { $0.kind == .edge && Set($0.members) == [1, 2] })
        m.toggleEdgePick(c.number)
        m.setEdgePickWeight(5)
        let why = await m.finishEdgePick()
        XCTAssertNil(why)
        try await FlexibleHisProject.waitFor(240, "the part open again") { m.sceneState == .ready && m.openedKey == m.currentSceneKey }
        await m.waitForIdle()
        try await FlexibleSquishFixture.settle(m, "the strips")
        return (r, m, try XCTUnwrap(m.presses.first { $0.strip != nil }).id)
    }

    func testEveryGroupHeaderHasAFingerSizedTrashAndAOneLineName() async throws {
        let (r, m, pid) = try await hisPadWithEdges()
        var report: [String] = []
        for (tag, size) in Self.sizes {
            let h = host(FlexibleStagePage(project: r.project, model: m, onExit: {}), size: size)
            pump(2.5)
            for g in m.squeezeGroups {
                m.rail = .group(g.id)
                pump(0.8)
                let n = g.number
                let trash = try XCTUnwrap(local(h, "groupRemove-\(n)"), "\(tag): Group \(n)'s trash")
                XCTAssertGreaterThanOrEqual(trash.width, 44, "\(tag): Group \(n)'s trash is a finger's target")
                XCTAssertGreaterThanOrEqual(trash.height, 44, "\(tag): Group \(n)'s trash is a finger's target")
                let name = try XCTUnwrap(local(h, "groupLine-\(n)"), "\(tag): Group \(n)'s name")
                XCTAssertLessThanOrEqual(name.height, 30, "\(tag): Group \(n)'s name is one line")
                let chips = h.frames.marks.keys.filter { $0.hasPrefix("depthChip-") }.sorted()
                if g.kind == .edges {
                    XCTAssertTrue(chips.isEmpty, "\(tag): the edges tab mounts no face's depth chip: \(chips)")
                    snapshot(h, "R7S_\(tag)_edges_tab.png")
                }
                report.append(String(format: "%@ Group %d (%@): trash %.0f×%.0f · name %.0f pt · chips %@", tag, n, g.kind.rawValue,
                                     trash.width, trash.height, name.height, chips.joined(separator: ",")))
            }
            // a tap on the name opens a one-line field
            let g1 = try XCTUnwrap(m.squeezeGroups.first)
            m.rail = .group(g1.id)
            pump(0.6)
            let name = try XCTUnwrap(local(h, "groupLine-\(g1.number)"))
            click(h, CGPoint(x: name.midX, y: name.midY))
            pump(0.5)
            let field = try XCTUnwrap(local(h, "groupNameField-\(g1.number)"), "\(tag): a tap on the name opens its field")
            XCTAssertLessThanOrEqual(field.height, 36, "\(tag): the field is one line")
            snapshot(h, "R7S_\(tag)_rename_field.png")
            h.window.orderOut(nil); h.window.contentView = nil
            report.append(String(format: "%@ rename field %.0f×%.0f", tag, field.width, field.height))
        }
        // the ONLY group has its trash: Reset all, the top starts Group 1
        m.resetAll()
        try await FlexibleHisProject.waitFor(240, "the part open again") { m.sceneState == .ready && m.openedKey == m.currentSceneKey }
        await m.waitForIdle()
        m.rail = .newGroup
        m.tapFace(1)
        XCTAssertEqual(m.squeezeGroups.count, 1, "one group")
        let h = host(FlexibleStagePage(project: r.project, model: m, onExit: {}), size: CGSize(width: 1194, height: 834))
        pump(2.5)
        let only = try XCTUnwrap(local(h, "groupRemove-1"), "the only group has its trash")
        XCTAssertGreaterThanOrEqual(min(only.width, only.height), 44)
        snapshot(h, "R7S_11l_only_group_trash.png")
        _ = pid
        print("FLEX-R7-HOSTED\n  " + report.joined(separator: "\n  "))
    }
}
#endif
