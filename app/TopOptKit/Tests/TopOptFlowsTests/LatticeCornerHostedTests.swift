// LatticeCornerHostedTests — B6 s1 (his go 11-05; ledger note 21, app-map §3.6, design-system §4.18 / §4.19; mockup #lat-setup,
// #lat-corner, #lat-settings-above). His words: "Should have the same bottom right corner as Topology: Settings | Lattice | ^
// (arrow that gives options to changes like 'optimize with lattice'". The Lattice stage's corner is [Settings ⌄] [Lattice] [⌃]:
// the chips stacked above it (Fast · 64³, Protect, Minimize plastic, Plate up, Gravity) and the iPad / Print Parameters buttons
// move into the Settings panel; ⌃ holds Lattice the original part · Optimize, then lattice · Lattice an optimized result ›
// · Preview only · Export…; with no lattice settings yet, Lattice is grey ("Save a lattice first") and the fix line above the
// corner reads "No lattice settings yet · Open Lattice". The hint comes back: "Tap a face to lattice it · drag to turn".
//
// RED before (saved: scratchpad b2red/LatticeCorner_build.txt): the corner was iPad · Print Parameters · Lattice · ⌃ under the
// chip column, ⌃ held Preview / Core / Export, and Lattice greyed with "lattice mode is off" and no fix line.
#if canImport(AppKit) && canImport(MetalKit)
import XCTest
import SwiftUI
import AppKit
@testable import TopOptFlows
@testable import TopOptKit
import TopOptDesign

@MainActor
final class LatticeCornerHostedTests: XCTestCase {

    /// His A1 pad on Structural (`prism`: his Top's face prism latticed and the lattice on, as FlexiblePressFixtures sets it).
    func stage(_ size: CGSize, prism: Bool) throws -> (AppBuildHost, ProjectModel, AppModel) {
        let r = try FlexiblePressFixtures.a1Project(3, self, facePrism: prism)
        let p = r.project
        p.lattice.flexible = nil
        p.lattice.chooseLatticeType(.structural)
        if let c = p.selection.groups.first(where: { $0.name == "Group C" }) { p.force.makeAnchor(c.id) }   // no group pending
        let h = AppBuildHost(WorkspacePlaceholder(model: r.app, project: p), size: size, test: self)
        h.pump(3)
        try h.pickFromMenu("capsuleMenu", "Structural", what: "\(size): the stage menu")
        h.pump(1)
        return (h, p, r.app)
    }

    /// ★ [Settings ⌄] [Lattice] [⌃], 12 pt apart, 24 pt from the right edge, one bottom line — Topology's corner.
    func testTheCornerIsSettingsLatticeAndTheArrow() throws {
        for size in [AppBuildHost.landscape13, CGSize(width: 820, height: 1180)] {
            let (h, _, _) = try stage(size, prism: true)
            let s = try h.onScreen("setupChip", "\(size): ★ Settings ⌄")
            let l = try h.onScreen("latticeButton", "\(size): ★ the Lattice run button")
            let m = try h.probe("latticeSplitMore", "\(size): ★ ⌃")
            XCTAssertEqual(l.minX - s.maxX, DSParts.cornerGap, accuracy: 1, "\(size): ★ Settings, 12 pt, Lattice")
            XCTAssertEqual(m.minX - l.maxX, DSParts.cornerGap, accuracy: 1, "\(size): ★ Lattice, 12 pt, ⌃")
            XCTAssertEqual(h.size.width - m.maxX, PageChrome.edge, accuracy: 1, "\(size): ★ 24 pt from the right edge")
            XCTAssertEqual(s.maxY, l.maxY, accuracy: 1, "\(size): one bottom line")
            XCTAssertEqual(m.maxY, l.maxY, accuracy: 1, "\(size): one bottom line")
            XCTAssertEqual(l.height, 64, accuracy: 1, "\(size): §4.6 — the 64 pt run button")
            XCTAssertNil(h.frames.all["latticeFixLine"], "\(size): a lattice set: no fix line")
            _ = try h.onScreen("stageHint", "\(size): ★ the hint is back")
        }
        // the hint's words (design-system §5's short form, mockup #lat-setup)
        XCTAssertEqual(LatticeSetupCopy.hint, "Tap a face to lattice it \u{00B7} drag to turn")
    }

    /// ★ No lattice settings yet: Lattice is grey ("Save a lattice first") and the fix line above the corner opens the Lattice page.
    func testNoLatticeYetGreysLatticeAndTheFixLineOpensTheLatticePage() throws {
        let (h, p, _) = try stage(AppBuildHost.landscape13, prism: false)
        XCTAssertFalse(p.lattice.enabled, "premise: nothing saved on the Lattice page yet")
        let l = try h.onScreen("latticeButton", "the Lattice run button")
        let fix = try h.onScreen("latticeFixLine", "★ the fix line")
        XCTAssertLessThanOrEqual(fix.maxY, l.minY + 0.5, "★ just above the corner")
        XCTAssertEqual(LatticeSetupCopy.saveFirst, "Save a lattice first")
        XCTAssertEqual(LatticeSetupCopy.noSettings, "No lattice settings yet")
        XCTAssertEqual(LatticeSetupCopy.openLattice, "Open Lattice")
        try h.tap("latticeFixChip", "★ Open Lattice", settle: 1.5)
        _ = try h.onScreen("latticeSettingsPanel", "★ Open Lattice opens the Lattice page")
    }

    /// ★ ⌃ holds the five run choices, in the design's order; each greys with nothing to run on.
    func testTheArrowHoldsTheFiveRunChoices() throws {
        let (h, _, _) = try stage(AppBuildHost.landscape13, prism: true)
        // (the divider before Preview only reads as an untitled item: dropped)
        let offered = try h.pickFromMenu("latticeSplitMore", "no such item", what: "⌃")
            .filter { !$0.replacingOccurrences(of: " [off]", with: "").isEmpty }
        let five = ["Lattice the original part", "Optimize, then lattice", "Lattice an optimized result", "Preview only", "Export\u{2026}"]
        XCTAssertEqual(offered.count, five.count, "★ note 21's five: \(offered)")
        for (o, t) in zip(offered, five) { XCTAssertTrue(o.hasPrefix(t), "★ in the design's order: \(t) — \(offered)") }
        func item(_ t: String) -> String? { offered.first { $0.hasPrefix(t) } }
        XCTAssertFalse(item("Lattice the original part")?.hasSuffix("[off]") ?? true, "★ a lattice set: it runs (\(offered))")
        XCTAssertTrue(item("Lattice an optimized result")?.hasSuffix("[off]") ?? false, "★ no results yet: nothing to pick (\(offered))")
        XCTAssertTrue(item("Export")?.hasSuffix("[off]") ?? false, "no results: nothing to export (\(offered))")

        // with results: "Lattice an optimized result ›" opens them, and Export is live
        let (h2, p2, _) = try stage(AppBuildHost.landscape13, prism: true)
        p2.run.restoreOutcome(AppBuildFixtures.outcome())
        h2.pump(1)
        let more = try h2.pickFromMenu("latticeSplitMore", "no such item", what: "⌃ with results")
        XCTAssertFalse(more.first { $0.hasPrefix("Lattice an optimized result") }?.hasSuffix("[off]") ?? true, "★ results: live (\(more))")
        XCTAssertFalse(more.first { $0.hasPrefix("Export") }?.hasSuffix("[off]") ?? true, "results: Export is live (\(more))")
    }

    /// ★ Settings opens the Settings panel just above the corner (its fix line when there is one), holding the rows the chips
    /// and buttons were: Quality · Plate · Gravity · Runs on · Units · Plastic · Print parameters · Material — no Allow growth.
    func testSettingsHoldsWhatSatAboveTheCorner() throws {
        for prism in [true, false] {
            let (h, _, _) = try stage(AppBuildHost.landscape13, prism: prism)
            try h.tap("setupChip", "Settings ⌄", settle: 1)
            let panel = try h.onScreen("settingsPanel", "prism \(prism): ★ the Settings panel")
            XCTAssertEqual(panel.width, DSParts.panelWidth, accuracy: 0.5, "★ §4.19: 348 pt")
            for row in ["quality", "plate", "gravity", "compute", "units", "minimizePlastic", "printParameters", "material"] {
                XCTAssertNotNil(h.frames.all["settingsRow-\(row)"], "prism \(prism): ★ the \(row) row")
            }
            XCTAssertNil(h.frames.all["settingsRow-designBox"], "★ Allow growth here is Topology's (the Lattice stage has zones)")
            let top = try XCTUnwrap(h.frames.all["latticeFixLine"] ?? h.frames.all["latticeButton"])
            XCTAssertLessThanOrEqual(panel.maxY, top.minY, "prism \(prism): ★ N4: above the corner's top line, never behind it")
        }
    }

    /// ★ Nothing else in the Lattice corner: the chip column and the iPad / Print Parameters buttons are Settings rows now
    /// (the band chips' Show / Hide stays: the lattice-only view's own, not one of the chips his note lists).
    func testTheChipsAndButtonsLeftTheCorner() throws {
        let ws = try FlexibleSource.code("WorkspacePlaceholder.swift")
        let bar = try XCTUnwrap(ws.range(of: "} else if !editFaces.isEditing, stage == .lattice {"))
        let branch = String(ws[bar.upperBound...].prefix(400))
        let end = try XCTUnwrap(branch.range(of: "} else {"))
        let body = String(branch[..<end.lowerBound])
        XCTAssertTrue(body.contains("latticeCornerPair"), "★ the lattice branch of the bar is the corner pair")
        XCTAssertFalse(body.contains("ComputeLocationControl") || body.contains("printParamsButton"),
                       "★ iPad and Print Parameters are Settings rows: \(body)")
        let chips = try XCTUnwrap(ws.range(of: "private var visibleSettingsChips: [SettingsChipID] {"))
        XCTAssertTrue(String(ws[chips.upperBound...].prefix(900)).contains("if stage == .lattice { return id == .bandChips && bandChipsAvailable }"),
                      "★ no chip column on the Lattice stage (its chips are Settings rows)")
    }
}
#endif
