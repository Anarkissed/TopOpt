// RowHeightsHostedTests — B2, U3 (approved design 2026-11-02, design-system §1 U3 and §6: "row heights are 44 or 48 pt"; §4.4:
// folder and setting rows 44, group and face rows 48).
//
// Topology Setup and the Lattice stage's Selections, at three sizes: every group row is 48 pt (taller only while a long name
// wraps, U2), the panel's header and the Safety margin setting row are 44. RED before B2b: group rows were 44.
// (Face rows are the stages' own and come with B3 / B6; #362's Flexible list swaps to this one in its sync.)
#if canImport(AppKit) && canImport(MetalKit)
import XCTest
import SwiftUI
import AppKit
@testable import TopOptFlows
@testable import TopOptKit

@MainActor
final class RowHeightsHostedTests: XCTestCase {
    func testGroupRowsAre48AndTheHeaderAndSettingRows44() throws {
        XCTAssertEqual(SelectionsList.groupLineHeight, 48)
        XCTAssertEqual(SelectionsList.lineHeight, 44)
        for size in AppBuildHost.sweep {   // ★ B10: the six windows
            for lattice in [false, true] {
                let r = try FlexiblePressFixtures.a1Project(3, self, facePrism: false)
                let p = r.project
                p.lattice.flexible = nil
                if lattice { p.lattice.chooseLatticeType(.structural) }
                let h = AppBuildHost(WorkspacePlaceholder(model: r.app, project: p), size: size, test: self)
                h.pump(3)
                if lattice { try h.pickFromMenu("capsuleMenu", "Structural", what: "\(size): the stage menu") }
                let what = "\(size) \(lattice ? "Lattice" : "Topology")"
                // ★ RE-PINNED (UI-Notes B6 slice 1, 7e4f0b53 — notes 22, 23): the Lattice stage lists its OWN groups, so a tap
                // there makes one (Topology's groups are its Topology panel's, B6)
                if lattice, let f = p.selection.groups.first?.faces.first {
                    _ = p.latticeStageTap(face: f, loop: [f])
                    h.pump(1)
                    XCTAssertFalse(p.latticeGroups.isEmpty, "\(what): premise — a lattice group")
                }
                for g in lattice ? p.latticeGroups : p.selection.groups {
                    let row = try h.onScreen("selGroup-\(g.id.uuidString)", "\(what): \(g.name)'s row")
                    XCTAssertEqual(row.height, 48, accuracy: 0.5, "\(what): ★ U3 — a group row is 48 pt")
                }
                let header = try h.onScreen("selHeader", "\(what): the panel's header")
                XCTAssertEqual(header.height, 44, accuracy: 0.5, "\(what): its header is 44 pt")
                if !lattice {
                    let margin = try h.onScreen("settingRow-safetyMargin", "\(what): Safety margin's row")
                    XCTAssertEqual(margin.height, 44, accuracy: 0.5, "\(what): ★ a setting row is 44 pt")
                    _ = try h.probe("safetyMargin", "\(what): its value, a 44 pt target", minHit: 44)
                }
            }
        }
    }
}
#endif
