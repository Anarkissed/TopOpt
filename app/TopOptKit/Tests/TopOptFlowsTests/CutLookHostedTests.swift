// CutLookHostedTests — B8, the look first (his ask via #362 11-07; the reviewer's routing 11-07 19:55Z item 3; rows 34, 35, R0;
// mockup #cut): Edit faces on design-system §4's parts at 13″ landscape and 11″ portrait.
//   • the corner is empty (row 35): no run, no Settings, no iPad │ Mac;
//   • the rail is one capsule of round tools (mockup .rail), and Outlines · X-ray are the view corner's (R0), above it;
//   • the rail's one line sits beside it, clear of the view corner;
//   • the left side is Topology's Selections, VIEW ONLY (row 34); a group row's tap lights its faces and joins nothing;
//   • the foot hint says so ("A tap selects a face for the tool. It joins no group.");
//   • from Lattice, both panels (Topology, Selections), view only.
#if canImport(AppKit)
import XCTest
import SwiftUI
import AppKit
@testable import TopOptFlows
@testable import TopOptKit

@MainActor
final class CutLookHostedTests: XCTestCase {

    static let sizes: [(String, CGSize)] = [("13L", AppBuildHost.landscape13), ("11P", CGSize(width: 820, height: 1180))]

    /// A control that publishes `<key>` off and `<key>-on` on.
    func either(_ h: AppBuildHost, _ key: String) -> String { h.frames.all[key + "-on"] != nil ? key + "-on" : key }

    func testEditFacesIsOnTheMockupsParts() throws {
        for (name, size) in Self.sizes {
            let (h, p, _) = try ParityTopologyShots.pad(size, test: self)
            try h.tap("capsuleScissors", "\(name): Topology's ✂")
            h.pump(1)

            // ★ row 35: the corner is empty
            for k in ["cornerFour", "optimizeSplit", "setupChip"] {
                XCTAssertNil(h.frames.all[k], "\(name): ★ Edit faces' corner is empty (row 35), but '\(k)' is drawn")
            }

            // ★ the rail: every tool, round, 40 pt, in one capsule
            let rail = try h.onScreen("cutRail", "\(name): the rail")
            for t in SurfaceTool.allCases {
                let f = try h.onScreen(either(h, "cutTool-\(t.title)"), "\(name): the rail's \(t.title)")
                XCTAssertEqual(f.width, 40, accuracy: 0.5, "\(name): \(t.title) is a 40 pt round tool")
                XCTAssertTrue(rail.insetBy(dx: -0.5, dy: -0.5).contains(f), "\(name): \(t.title) is inside the rail")
            }
            try h.tap(either(h, "cutTool-Cut"), "\(name): the rail's Cut")
            XCTAssertNotNil(h.frames.all["cutTool-Cut-on"], "\(name): ★ the armed tool wears the accent")

            // ★ R0: Outlines · X-ray are the view corner's — above the rail, never in it
            for v in ["Outlines", "X-ray"] {
                let f = try h.onScreen(either(h, "view-\(v)"), "\(name): the view corner's \(v)")
                XCTAssertFalse(rail.intersects(f), "\(name): ★ \(v) is not in the rail (R0)")
                XCTAssertLessThanOrEqual(f.maxY, rail.minY, "\(name): ★ \(v) sits above the rail")
            }

            // ★ the rail's line: beside it, clear of the view corner
            let line = try h.onScreen("cutRailHint", "\(name): the rail's line")
            XCTAssertLessThanOrEqual(line.maxX, rail.minX - 8, "\(name): the line is beside the rail")
            for v in ["Outlines", "X-ray"] {
                if let f = h.frames.all[either(h, "view-\(v)")] { XCTAssertFalse(line.intersects(f), "\(name): the line clears \(v)") }
            }

            // ★ row 34: Topology's Selections, view only
            let panel = try h.onScreen("cutSelections", "\(name): the view-only Selections")
            XCTAssertNil(h.frames.all["selectionsList"], "\(name): ★ not the editable list")
            XCTAssertFalse(panel.intersects(rail), "\(name): the panel clears the rail")
            let c = try XCTUnwrap(p.selection.groups.first { $0.name == "Group C" }, "the pad's Group C")
            _ = try h.onScreen("cutGroup-\(c.id.uuidString)", "\(name): Group C's row (its scenario open)")
            let before = p.selection.groups.map { "\($0.id)\($0.faces)" }
            let roles = p.selection.groups.map { "\(p.force.kind(for: $0.id))" }
            try h.tap("cutGroup-\(c.id.uuidString)", "\(name): Group C's row")
            XCTAssertEqual(p.selection.groups.map { "\($0.id)\($0.faces)" }, before, "\(name): ★ a row's tap joins nothing")
            XCTAssertEqual(p.selection.groups.map { "\(p.force.kind(for: $0.id))" }, roles, "\(name): ★ … and changes no role")

            // ★ the foot hint
            let hint = try h.onScreen("stageHint", "\(name): the foot hint")
            XCTAssertFalse(hint.intersects(panel), "\(name): the foot hint clears the panel")
            XCTAssertGreaterThan(hint.minY, size.height / 2, "\(name): the foot hint is at the foot")
        }
    }

    func testFromLatticeBothPanelsAreViewOnly() throws {
        for (name, size) in Self.sizes {
            let (h, p, _) = try ParityTopologyShots.pad(size, test: self)
            p.lattice.clearLatticeType()
            p.lattice.chooseLatticeType(.structural)
            try h.pickFromMenu("capsuleMenu", "Structural", what: "\(name): Topology's ● menu")
            h.pump(1)
            try h.tap("capsuleScissors", "\(name): Lattice's ✂")
            h.pump(1)
            _ = try h.onScreen("cutTopology", "\(name): Topology, view only")
            _ = try h.onScreen("cutSelections", "\(name): Selections (the lattice groups), view only")
            XCTAssertNil(h.frames.all["latticeTopologyPanel"], "\(name): not Lattice Setup's own panel")
            XCTAssertNil(h.frames.all["selectionsList"], "\(name): not the editable list")
        }
    }
}
#endif
