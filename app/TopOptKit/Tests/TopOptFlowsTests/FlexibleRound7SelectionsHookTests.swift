// FlexibleRound7SelectionsHookTests — round 7, batch R7-D2 (Selections, his mockup pick 2), written BEFORE the code (the red
// run: docs/handoffs/evidence/2026-09-29-flexible-screens/round7/batch_d2/d2_red_run.txt). The reviewer's approved merged list
// (2026-10-14 19:45) gives D2 the hooks H20, H22, H23, H25, H32 and H35; condition (e): "pin tests (each hook once with its
// gate; removing a gate goes red)".
//
//   H20  WorkspacePlaceholder: #354's numberless depth / expand knobs not drawn on the Flexible stage (our numbered handles).
//   H22  onPickPoint: on the Flexible stage, edit phase, no page up — the tap goes to the face chip's router and is consumed
//        (#354's LatticeLibraryTap.route and handleTopologyPiecePick never run there).
//   H23  onMiss: on the Flexible stage, no page up — the chip closes; nothing is created.
//   H25  the selections panel: on the Flexible stage, no page up, the B1 list replaces #354's card (the slot, the placement
//        and the minimise rule stay #354's; the panel's declaration string still counts 1).
//   H32  the on-model layer (the chip, its leader, the numbered handles) mounted on the Flexible stage only.
//   H35  ★ WITHDRAWN — his ruling of 2026-10-18 ("We do not want any lattices to be affected by topology optimization. This is
//        why I set it within 'protect' in the first place. These two things should behave the same way."): a lattice face is
//        always protected, so the lattice-only role is never built. ProjectModel.swift carries NO H35 line (it was HELD on
//        the reviewer's condition (d) — round7/batch_d2/conditionD/ — which is moot now).
//   H39  kept (the ruling: "keep H39 if the card can still draw on Flexible in any state") — #354's card still draws on the
//        variant lattice page's library mount (showLatticePage, a full-screen page that H25's `!fullScreenPageUp` leaves alone).
import XCTest
@testable import TopOptFlows

final class FlexibleRound7SelectionsHookTests: XCTestCase {

    static let sources = FlexibleHisProject.repoRoot.appendingPathComponent("app/TopOptKit/Sources/TopOptFlows")
    static func text(_ name: String) throws -> String {
        try String(contentsOf: sources.appendingPathComponent(name), encoding: .utf8)
    }

    struct Hook {
        let id: String
        let before: String   // the line(s) right before it (its anchor)
        let line: String     // the hook's own line, up to and including its comment tag
        let gate: String     // the gate (removed from a copy, the pin goes red)
        let after: String    // #354's next line, unchanged
    }

    static let owns = "flexibleMain.owns(project, stage)"

    static let hooks: [Hook] = [
        Hook(id: "H20",
             before: "                // ★ §3d — THE 3D DEPTH-PLANE HANDLES, the lattice stage's own tool.\n",
             line: "                if visible.latticeDepthPlanes, !legendDrilledIn, !flexibleMain.owns(project, stage) {   // Flexible (PR #362) H20: ",
             gate: ", !flexibleMain.owns(project, stage)",
             after: "                    latticeDepthHandlesOverlay.ignoresSafeArea()\n"),
        Hook(id: "H22",
             before: "                              if legendDrilledIn { return true }\n                              guard let m = viewerMesh else { return false }\n",
             // ★ RE-PINNED (the redesign P5; H60 / H61 approved in the overnight release ruling of 2026-10-26): the positive owns() gates carry `!editFaces.isEditing` (Flexible is off under Edit faces), and H27 / H36 hand Edit faces its closure.
             line: "                              if flexibleMain.owns(project, stage), !editFaces.isEditing, force.phase == .edit, !fullScreenPageUp { flexibleMain.tapFace(project, face: fid, point: pt, mesh: m); return true }   // Flexible (PR #362) H22: ",
             gate: "flexibleMain.owns(project, stage), !editFaces.isEditing, force.phase == .edit, !fullScreenPageUp",
             after: "                              if visible.surfaceEditing {\n"),
        Hook(id: "H23",
             before: "                          onMiss: {\n",
             line: "                              if flexibleMain.owns(project, stage), !editFaces.isEditing, !fullScreenPageUp { flexibleMain.missTap(); return }   // Flexible (PR #362) H23: ",
             gate: "flexibleMain.owns(project, stage), !editFaces.isEditing, !fullScreenPageUp",
             after: "                              guard visible.surfaceEditing else { return }\n"),
        // ★ RE-PINNED (sync of #354 at 89af86dd): #354's bare `selectionsLibraryCard` is now a chain (B5 3f293974's Edit faces card
        // first, then B3 7e37c45f's Topology list, B4 564db991's lattice list, the card last). Our owns-swap goes right after
        // B5's mode branch, as #354's hook table places it; its gate and its FlexibleSelectionsList call are unchanged, and
        // its else is #354's chain. Was: `if <gate> { FlexibleSelectionsList(…) } else { selectionsLibraryCard }`.
        Hook(id: "H25",
             before: "            if editFaces.isEditing { selectionsLibraryCard }\n",
             line: "            else if flexibleMain.owns(project, stage), !editFaces.isEditing, !fullScreenPageUp { FlexibleSelectionsList(project: project, main: flexibleMain, collapsed: $selectionsCollapsed, cards: latticeSelectableCards, groupCards: latticeFaceCards, cardsChanged: { refreshLatticeFaceCards() }) }   // Flexible (PR #362) H25: ",
             gate: "flexibleMain.owns(project, stage), !editFaces.isEditing, !fullScreenPageUp",
             after: "            // ★ B3 (B1): Topology's list is SelectionsList — one line per group, eye, trash in place + Undo.\n"),
        Hook(id: "H32",
             before: "                latticeOnlyBadge\n                latticeEdgeLight\n",
             line: "                if flexibleMain.owns(project, stage), !editFaces.isEditing { FlexibleOnModelLayer(main: flexibleMain, project: project, projection: projection, settle: settleQuat, bottomClearance: bottomBarClearance, cards: latticeSelectableCards, groupCards: latticeFaceCards, cardsChanged: { refreshLatticeFaceCards() }) }   // Flexible (PR #362) H32: ",
             gate: "flexibleMain.owns(project, stage)",
             after: "                // ★ THE VON MISES SCALE, ON THE RIGHT EDGE (maintainer,\n"),
    ]

    /// Every way a hook can be wrong: missing or doubled, gate gone, not at its anchor, #354's next line moved.
    static func failures(_ ws: String, _ h: Hook) -> [String] {
        var out: [String] = []
        let n = ws.components(separatedBy: h.line).count - 1
        if n != 1 { out.append("\(h.id): appears \(n) times (must be exactly once)") }
        if !h.line.contains(h.gate) { out.append("\(h.id): its gate is not in it") }
        if !ws.contains(h.before + h.line) { out.append("\(h.id): not right after its anchor") }
        if let r = ws.range(of: h.line), let nl = ws[r.upperBound...].firstIndex(of: "\n") {
            if !ws[ws.index(after: nl)...].hasPrefix(h.after) { out.append("\(h.id): #354's next line moved") }
        }
        return out
    }

    func testEachHookOnceAtItsAnchorWithItsGateAndRemovingAGateGoesRed() throws {
        let ws = try Self.text("WorkspacePlaceholder.swift")
        for h in Self.hooks {
            XCTAssertEqual(Self.failures(ws, h), [], "★ \(h.id) at its anchor with its gate")
            // ★ RED CONTROL: the gate removed from a copy (the hook then runs on every stage) — the pin goes red
            let ungated = ws.replacingOccurrences(of: h.line, with: h.line.replacingOccurrences(of: h.gate, with: h.id == "H20" ? "" : "true"))
            XCTAssertFalse(Self.failures(ungated, h).isEmpty, "★ RED CONTROL: \(h.id) without its gate fails the pin")
        }
    }

    /// H20's old line is gone (+0 −0: an edit), H22's and H23's are additions, H25's an edit, H32's an addition.
    func testTheOldLinesAreGoneAndNothingElseOfOursIsInThoseSpots() throws {
        let ws = try Self.text("WorkspacePlaceholder.swift")
        XCTAssertFalse(ws.contains("                if visible.latticeDepthPlanes, !legendDrilledIn {\n"), "H20 edits #354's line (+0 −0)")
        XCTAssertFalse(ws.contains("            selectionsLibraryCard\n            if !selectionsCollapsed { latticePreviewNotice }"),
                       "H25 edits #354's mount line (+0 −0)")
        // ★ the panel's declaration string, which three #354 guards count, still counts once (comments included)
        XCTAssertEqual(ws.components(separatedBy: "var selectionsPanel").count - 1, 1)
        XCTAssertEqual(ws.components(separatedBy: "private var selectionsPanel").count - 1, 1)
        XCTAssertFalse(ws.contains("!showLatticePage { FlexibleSelectionsList"), "H25 never names the variant page")
        // the variant lattice page's library still mounts #354's own panel (and so its card) — H39 stays (the ruling)
        XCTAssertTrue(ws.contains("            if showLatticePage, latticePageModel.libraryOpen,\n               force.phase == .edit, viewerMesh != nil {\n                selectionsPanel\n            }"),
                      "the variant lattice page's library mount is #354's, unchanged — the card can still draw there")
        XCTAssertEqual(ws.components(separatedBy: "Flexible (PR #362) H39:").count - 1, 1, "★ H39 kept (the card can still draw on the stage in that state)")
        // the hook calls are our only uses of the new types in #354's file
        XCTAssertEqual(ws.components(separatedBy: "FlexibleSelectionsList(").count - 1, 1)
        XCTAssertEqual(ws.components(separatedBy: "FlexibleOnModelLayer(").count - 1, 1)
        XCTAssertEqual(ws.components(separatedBy: "flexibleMain.tapFace(").count - 1, 1)
        XCTAssertEqual(ws.components(separatedBy: "flexibleMain.missTap(").count - 1, 1)
        // H15' is unchanged (its line pinned by FlexibleR7M1Tests); volumes( still asked only there
        XCTAssertEqual(ws.components(separatedBy: "flexibleMain.volumes(").count - 1, 2)
    }

    /// ★ H35 WITHDRAWN (his ruling 2026-10-18: "We do not want any lattices to be affected by topology optimization. This is
    /// why I set it within 'protect' in the first place. These two things should behave the same way."): the lattice-only role
    /// is never built — ProjectModel carries no H35 line, and no TopOptFlows source names the lattice-only set, the hold, or
    /// chip N's greyed route line. RED CONTROLS: the approved H35 line put back into a copy is caught; its comment alone too.
    /// ★ RE-PINNED (our own test, his ruling of 2026-10-18): was `testH35IsHeldProjectModelHasNoLatticeOnlyLine` — the HOLD
    /// (no H35 line while the reviewer ruled on condition (d); chip N's [Lattice] greyed, `latticeOnlyRoleLanded == false`).
    func testH35IsWithdrawnNoLatticeOnlyRoleAnywhere() throws {
        let pm = try Self.text("ProjectModel.swift")
        let h35 = "lattice.flexible?.latticeOnlyGroups"
        func clean(_ text: String) -> Bool { !text.contains("latticeOnlyGroups") && !text.contains("Flexible (PR #362) H35") }
        XCTAssertTrue(clean(pm), "★ ProjectModel: no H35 line, no H35 comment")
        let files = try FileManager.default.contentsOfDirectory(atPath: Self.sources.path).filter { $0.hasSuffix(".swift") }
        XCTAssertGreaterThan(files.count, 100, "premise: every TopOptFlows source is read")
        for f in files {
            let t = try Self.text(f)
            XCTAssertFalse(t.contains("latticeOnlyGroups"), "★ \(f): the withdrawn lattice-only set")
            XCTAssertFalse(t.contains("latticeOnlyRoleLanded"), "★ \(f): the hold")
            XCTAssertFalse(t.contains("For lattice now"), "★ \(f): chip N's greyed route line")
        }
        let anchor = "                keepClearOn: force.keepClearAffix(for: id) == .on)\n"
        XCTAssertEqual(pm.components(separatedBy: anchor).count - 1, 1, "premise: the line H35 would have followed")
        let withH35 = pm.replacingOccurrences(of: anchor, with: anchor + "                || (\(h35)?.contains(id) == true && force.keepClearAffix(for: id) != .on)   // Flexible (PR #362) H35: x\n")
        XCTAssertNotEqual(withH35, pm, "premise: the copy carries the approved line")
        XCTAssertFalse(clean(withH35), "★ RED CONTROL: the approved H35 line put back is caught")
        XCTAssertFalse(clean(pm.replacingOccurrences(of: anchor, with: anchor + "                // Flexible (PR #362) H35: x\n")),
                       "★ RED CONTROL: the H35 comment alone is caught too")
    }

    /// The new code lives in new Flexible files; the hooks name only them.
    func testTheNewFlexibleFilesExist() throws {
        for f in ["FlexibleFacePick.swift", "FlexibleFaceCommits.swift", "FlexibleLatticeHandles.swift", "FlexibleOnModelLayer.swift",
                  "FlexibleFaceChip.swift", "FlexibleFaceChipLayout.swift", "FlexibleFaceStatsPopover.swift", "FlexibleSelectionsList.swift",
                  "FlexibleMainStage+Selections.swift"] {
            XCTAssertNoThrow(try Self.text(f), "\(f) exists")
        }
        // FlexibleNumberBox hands `allowsNegative` to the keypad (the expand box can be negative — today it was dropped)
        let box = try Self.text("FlexibleNumberBox.swift")
        XCTAssertTrue(box.contains("config: .init(title: title, unit: spec.unit, allowsDecimal: true, allowsNegative: allowsNegative)"),
                      "★ the keypad gets the sign key for the expand")
    }
}
