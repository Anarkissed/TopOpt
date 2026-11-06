// LatticeStartFromHostedTests — B6 s3b (his go 11-05; ledger notes 26, R2.2; design-system §4.21 / §4.13; mockup #lat-latmode-ask,
// #lat-setup-whole). His words (R2.2): "The '+ Lattice faces' and '- lattice faces' should look more like a setting than a switch
// … Make it look more like the 'Safety margin: Light use' setting". The foot of Lattice Setup's Selections: "Start from  Solid ·
// + Lattice faces ⌄ (i)"; its menu offers All lattice · − Lattice faces; switching asks in place first, because your faces
// change meaning ("The whole part becomes lattice, and Group 1 removes it."). Stored with the lattice; until the engine takes
// `lattice.whole_part` (E2, not released) the job stays as today and one plain line says so.
//
// RED before (saved: scratchpad b2red/LatticeStartFrom_build.txt): no Start from row.
#if canImport(AppKit) && canImport(MetalKit)
import XCTest
import SwiftUI
import AppKit
@testable import TopOptFlows
@testable import TopOptKit
import TopOptDesign

@MainActor
final class LatticeStartFromHostedTests: XCTestCase {

    func stage(_ size: CGSize = AppBuildHost.landscape13) throws -> (AppBuildHost, ProjectModel, UUID) {
        let (h, p, _) = try ParityTopologyShots.pad(size, test: self)
        p.lattice.clearLatticeType()
        p.lattice.chooseLatticeType(.structural)
        try h.pickFromMenu("capsuleMenu", "Structural", what: "\(size): the stage menu")
        h.pump(1)
        let f = try XCTUnwrap(p.selection.groups.first?.faces.first)
        _ = p.latticeStageTap(face: f, loop: [f])
        let g = try XCTUnwrap(p.latticeList.activeGroupID)
        p.lattice.groupRoles[g] = .include
        p.latticeList.clearActive()
        h.pump(1)
        return (h, p, g)
    }

    /// ★ R2.2: the foot's setting row, "Start from  Solid · + Lattice faces ⌄ (i)", pinned under the list.
    func testTheFootIsTheStartFromSetting() throws {
        for size in [AppBuildHost.landscape13, CGSize(width: 820, height: 1180)] {
            let (h, p, _) = try stage(size)
            let row = try h.onScreen("settingRow-latticeStartFrom", "\(size): ★ the Start from row")
            let panel = try h.onScreen("selectionsList", "\(size): Selections")
            XCTAssertEqual(row.height, 44, accuracy: 0.5, "\(size): U3 — a setting row is 44 pt")
            XCTAssertLessThanOrEqual(row.maxY, panel.maxY + 0.5, "\(size): inside the panel")
            XCTAssertGreaterThan(row.minY, try h.onScreen("latticeZonesSection", "\(size): zones").minY, "\(size): ★ its foot")
            _ = try h.probe("latticeStartFrom", "\(size): its value, a 44 pt target")
            _ = try h.onScreen("info-latticeStartFrom", "\(size): its (i)")
            XCTAssertFalse(p.lattice.wholePart, "\(size): + by default (note 26)")
        }
        XCTAssertEqual(LatticeSetupCopy.startFromPlus, "Solid \u{00B7} + Lattice faces")
        XCTAssertEqual(LatticeSetupCopy.startFromMinus, "All lattice \u{00B7} \u{2212} Lattice faces")
    }

    /// ★ Switching asks in place first; Cancel changes nothing; Switch makes the part all lattice and the groups remove it.
    func testSwitchingAsksFirstAndFlipsWhatTheGroupsDo() throws {
        let (h, p, g) = try stage()
        let offered = try h.pickFromMenu("latticeStartFrom", "All lattice", what: "Start from")
        XCTAssertTrue(offered.contains { $0.hasPrefix("Solid") } && offered.contains { $0.hasPrefix("All lattice") }, "\(offered)")
        h.pump(0.5)
        _ = try h.onScreen("latticeModeAsk", "★ it asks in place first")
        XCTAssertFalse(p.lattice.wholePart, "★ nothing changes before the answer")
        try h.tap("latticeModeCancel", "Cancel", settle: 0.8)
        XCTAssertNil(h.frames.all["latticeModeAsk"], "Cancel: the ask goes")
        XCTAssertFalse(p.lattice.wholePart)
        XCTAssertEqual(p.lattice.groupRoles[g], .include, "Cancel: Group 1 still adds lattice")

        try h.pickFromMenu("latticeStartFrom", "All lattice", what: "Start from again")
        h.pump(0.5)
        try h.tap("latticeModeSwitch", "★ Switch", settle: 1)
        XCTAssertTrue(p.lattice.wholePart, "★ All lattice")
        XCTAssertEqual(p.lattice.groupRoles[g], .exclude, "★ Group 1 now removes lattice")
        XCTAssertEqual(h.frames.all["latticeWholePartWaits"] != nil, !TopOptKit.latticeWholePartWired,
                       "★ the plain line exactly until the engine takes it (release (2): LatticeE2WiringHostedTests)")
        // and back: every group as it was
        try h.pickFromMenu("latticeStartFrom", "Solid", what: "Start from, back")
        h.pump(0.5)
        try h.tap("latticeModeSwitch", "Switch back", settle: 1)
        XCTAssertFalse(p.lattice.wholePart)
        XCTAssertEqual(p.lattice.groupRoles[g], .include, "★ switching back restores Group 1")
        XCTAssertEqual(LatticeSetupCopy.modeAsk(toMinus: true, group: "Group 1"),
                       "Switch to All lattice \u{00B7} \u{2212} Lattice faces? The whole part becomes lattice, and Group 1 removes it.")
        XCTAssertEqual(LatticeSetupCopy.modeAsk(toMinus: false, group: nil),
                       "Switch to Solid \u{00B7} + Lattice faces? The part becomes solid, and your groups add lattice.")
    }

    /// Stored with the lattice; a project saved before reads + (and writes the same bytes).
    func testItSavesAndAnOlderProjectReadsPlus() throws {
        var s = LatticeSettings()
        let old = try JSONEncoder().encode(s)
        XCTAssertFalse(String(decoding: old, as: UTF8.self).contains("wholePart"), "★ + : the key is not written")
        XCTAssertFalse(try JSONDecoder().decode(LatticeSettings.self, from: old).wholePart)
        s.wholePart = true
        XCTAssertTrue(try JSONDecoder().decode(LatticeSettings.self, from: try JSONEncoder().encode(s)).wholePart)
    }
}
#endif
