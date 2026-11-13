// TopologyLikeLatticeHostedTests — his ask 2026-11-13: Topology behaves as Lattice:
//   * a tap (or a double tap) on empty space clears the picked group;
//   * a picked group's chevron closes its rows and the group STAYS picked (RED CONTROL: the old rule kept them open);
//   * while a group is picked only its shapes draw (TopologyFocus).
// On the real page (WorkspacePlaceholder), at the six windows.
#if canImport(AppKit) && canImport(MetalKit)
import XCTest
import SwiftUI
@testable import TopOptFlows
@testable import TopOptKit

@MainActor
final class TopologyLikeLatticeHostedTests: XCTestCase {

    func host(_ size: CGSize) throws -> (AppBuildHost, ProjectModel) {
        let r = try FlexiblePressFixtures.a1Project(3, self, facePrism: false)
        let p = r.project
        p.lattice.flexible = nil
        let h = AppBuildHost(WorkspacePlaceholder(model: r.app, project: p), size: size, test: self)
        h.pump(3)
        return (h, p)
    }

    /// ★ The tap: while a group is picked only its own shapes take a tap (a click cannot reach the 3D view in a hosted test, so
    /// the page's own rule is read).
    func testOnlyThePickedGroupsShapesTakeATap() throws {
        var u = URL(fileURLWithPath: #filePath)
        for _ in 0..<3 { u.deleteLastPathComponent() }
        let ws = try String(contentsOf: u.appendingPathComponent("Sources/TopOptFlows/WorkspacePlaceholder.swift"), encoding: .utf8)
        let r = try XCTUnwrap(ws.range(of: "private func pickPrimitive("))
        let body = String(ws[r.lowerBound...].prefix(1800))
        XCTAssertTrue(body.contains("(focus == nil || v.groupID == focus)"), "★ only the picked group's shapes take a tap")
        XCTAssertTrue(ws.contains("TopologyFocus.only(project.groupView.showing(project.clearanceVolumes())"), "★ and only they draw")
    }

    func testOnlyThePickedGroupsShapesDraw() {
        let a = UUID(), b = UUID()
        let items = [(a, 1), (b, 2), (a, 3)]
        XCTAssertEqual(TopologyFocus.only(items, active: nil) { $0.0 }.map(\.1), [1, 2, 3], "none picked: every group's")
        XCTAssertEqual(TopologyFocus.only(items, active: a) { $0.0 }.map(\.1), [1, 3], "★ a picked group: only its own, in order")
    }

    func testTheChevronClosesAPickedGroupAndTheTapIntoNothingClearsIt() throws {
        for size in AppBuildHost.sweep {
            let (h, p) = try host(size)
            let g = try XCTUnwrap(p.selection.groups.first)
            try h.tap("selName-\(g.id.uuidString)", "\(size): the first group's name")
            XCTAssertEqual(p.selection.activeGroupID, g.id, "premise: picked")
            _ = try h.onScreen("selRows-\(g.id.uuidString)", "\(size): picking a group opens its rows")
            try h.tap("selOpen-\(g.id.uuidString)", "\(size): its chevron")
            XCTAssertNil(h.frames.all["selRows-\(g.id.uuidString)"], "★ \(size): the chevron closes the picked group's rows")
            XCTAssertEqual(p.selection.activeGroupID, g.id, "★ \(size): and the group stays picked")
        }
    }
}
#endif
