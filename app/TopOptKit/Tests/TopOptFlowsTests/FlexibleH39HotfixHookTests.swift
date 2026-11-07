// FlexibleH39HotfixHookTests — round 7, the H39 hotfix (2026-10-17), the reviewer's rulings of 2026-10-17 20:25 + 20:36
// (approved by the maintainer). The two #354 lines it lays, pinned by text — "each hook once at its anchor with its gate;
// removing a gate goes red" (condition e) — and the source facts the behaviour rests on. Written BEFORE the code (the red
// run: docs/handoffs/evidence/2026-09-29-flexible-screens/round7/batch_h39/h39_red_run.txt).
//
//   H39  WorkspacePlaceholder: the Selections-card header's Regions toggle is drawn only when
//        !flexibleMain.owns(project, stage) (ruling 1). One added line, a modifier right after #354's own
//        `.accessibilityLabel("Regions")`; #354's lines around it stay byte-identical.
//   LEAK nothing on the Flexible stage can set `regionsOpen` (ruling 1: "today's carry-over pops the Regions panel on
//        Topology — a leak"): the toggle is its ONLY writer that opens it, and it is H39-gated; the panel's Done only closes
//        it; no binding hands it to anything else. RED CONTROL: today's text (the toggle ungated).
//   H40  MetalMeshView: the contact shadow keeps the printed body (ruling 4: "MetalMeshView.swift:4085 (+1 −1,
//        `&& !flexibleBodyPrinted`) APPROVED — pin test with red control"). Its gate is ours (MeshRenderer+FlexibleLattice).
//   DOOR every core scene the Flexible stage opens goes through FlexibleCoreDoor (ruling 6): the one `FlexibleScene(jobJSON:`
//        in the app's Flexible code is the door's. RED CONTROL: today's three openings.
import XCTest
@testable import TopOptFlows

final class FlexibleH39HotfixHookTests: XCTestCase {

    static let sources = FlexibleHisProject.repoRoot.appendingPathComponent("app/TopOptKit/Sources/TopOptFlows")
    static func text(_ name: String) throws -> String {
        try String(contentsOf: sources.appendingPathComponent(name), encoding: .utf8)
    }

    // MARK: - H39

    static let h39Anchor = "                    .accessibilityLabel(\"Regions\")\n"
    static let h39Pin = "                    .flexibleDrawn(when: !flexibleMain.owns(project, stage))   // Flexible (PR #362) H39: "
    static let h39Gate = "!flexibleMain.owns(project, stage)"
    /// #354's toggle, byte for byte, then H39, then #354's next line.
    static let h39Block = "                    Button { regionsOpen.toggle() } label: {\n"
        + "                        Image(systemName: \"square.on.square.dashed\")\n"
        + "                            .font(.system(size: 12, weight: .semibold))\n"
        + "                            .foregroundStyle((regionsOpen ? DS.Color.accent\n"
        + "                                              : DS.Color.textTertiary).color)\n"
        + "                    }\n"
        + "                    .buttonStyle(.plain)\n"
        + h39Anchor

    static func h39Failures(_ ws: String) -> [String] {
        var out: [String] = []
        let n = ws.components(separatedBy: h39Pin).count - 1
        if n != 1 { out.append("H39: the hook appears \(n) times (must be exactly once)") }
        if !h39Pin.contains(h39Gate) { out.append("H39: its gate is not in it") }
        if !ws.contains(h39Block + h39Pin) { out.append("H39: not right after #354's own Regions toggle (its anchor moved, or the toggle changed)") }
        // #354's next line follows, unindented, unchanged
        if let r = ws.range(of: h39Pin), let nl = ws[r.upperBound...].firstIndex(of: "\n") {
            if !ws[ws.index(after: nl)...].hasPrefix("                    keepClearQuickAction\n                    unitToggle\n") {
                out.append("H39: #354's keepClearQuickAction / unitToggle no longer follow it")
            }
        }
        return out
    }

    func testH39TheRegionsToggleIsDrawnOnlyOffTheFlexibleStage() throws {
        let ws = try Self.text("WorkspacePlaceholder.swift")
        XCTAssertEqual(Self.h39Failures(ws), [], "★ H39 at its anchor with its gate")
        // ★ RED CONTROL: the gate removed (the toggle drawn on every stage, as before) — the check goes red
        let ungated = ws.replacingOccurrences(of: Self.h39Pin, with: Self.h39Pin.replacingOccurrences(of: Self.h39Gate, with: "true"))
        XCTAssertFalse(Self.h39Failures(ungated).isEmpty, "★ RED CONTROL: H39 without its gate fails the pin")
        // the modifier draws its view only when `on` (ours)
        let mod = try Self.text("FlexibleDrawnWhen.swift")
        XCTAssertTrue(mod.contains("@ViewBuilder func flexibleDrawn(when on: Bool) -> some View {\n        if on { self }\n    }"),
                      "the modifier: the view when on, nothing otherwise")
    }

    // MARK: - the leak: nothing on the Flexible stage can set regionsOpen

    /// Every write of `regionsOpen` in #354's file, as (kind, line). Empty findings = nothing on the Flexible stage opens it.
    static func leakFailures(_ ws: String) -> [String] {
        var out: [String] = []
        if ws.contains("$regionsOpen") { out.append("a binding hands regionsOpen to another view") }
        if ws.contains("regionsOpen = true") { out.append("something sets regionsOpen = true") }
        let toggles = ws.components(separatedBy: "regionsOpen.toggle()").count - 1
        if toggles != 1 { out.append("regionsOpen.toggle() appears \(toggles) times") }
        // the one toggle is #354's Regions button, and that button is H39-gated
        if !ws.contains(h39Block + h39Pin) { out.append("the Regions toggle is drawn on the Flexible stage (not H39-gated)") }
        // (the red run's first count expected one: the declaration's own `= false` is the other — corrected before the code)
        // ★ RE-PINNED (sync of #354 at 89af86dd): B5 3f293974 added a third `= false`, a CLOSER (leaveEditFacesTools shuts the panel on
        // Edit faces' Done); nothing opens it. Was: exactly the declaration and the panel's Done (2).
        let falses = ws.components(separatedBy: "regionsOpen = false").count - 1
        if falses != 3 || !ws.contains("@State private var regionsOpen = false\n") || !ws.contains("onClose: { regionsOpen = false })")
            || !ws.contains("        paintActive = false\n        regionsOpen = false\n    }\n") {
            out.append("regionsOpen = false is not only its declaration and the panel's Done")
        }
        // and the panel itself is not drawn on the Flexible stage (H26, unchanged)
        let h26 = "                if viewerMesh != nil, regionsOpen, !flexibleMain.owns(project, stage) { regionsPanelOverlay }   // Flexible (PR #362) H26: "
        if ws.components(separatedBy: h26).count - 1 != 1 { out.append("H26 changed") }
        if ws.components(separatedBy: "{ regionsPanelOverlay }").count - 1 != 1 { out.append("the panel is mounted somewhere else too") }
        return out
    }

    func testNothingOnTheFlexibleStageCanSetRegionsOpen() throws {
        let ws = try Self.text("WorkspacePlaceholder.swift")
        XCTAssertEqual(Self.leakFailures(ws), [], "★ no writer of regionsOpen is reachable on the Flexible stage")
        // ★ RED CONTROL: today's carry-over — the toggle drawn on the Flexible stage too (H39's line not there)
        let today = ws.replacingOccurrences(of: Self.h39Pin, with: "                    // (no H39) ")
        XCTAssertTrue(Self.leakFailures(today).contains("the Regions toggle is drawn on the Flexible stage (not H39-gated)"),
                      "★ RED CONTROL: without H39 the Flexible stage can open the Regions panel for Topology")
    }

    // MARK: - H40

    static let h40Anchor = "        // it shows up on screen\"). The body is hidden; its footprint must not stay behind.\n"
    static let h40Pin = "        let latticeOnly = bodyAlpha <= 0.5 && !flexibleBodyPrinted   // Flexible (PR #362) H40: "
    static let h40Gate = " && !flexibleBodyPrinted"

    static func h40Failures(_ mm: String) -> [String] {
        var out: [String] = []
        let n = mm.components(separatedBy: h40Pin).count - 1
        if n != 1 { out.append("H40: the hook appears \(n) times (must be exactly once)") }
        if !h40Pin.contains(h40Gate) { out.append("H40: its gate is not in it") }
        if !mm.contains(h40Anchor + h40Pin) { out.append("H40: not at its anchor (the line before it moved)") }
        if mm.contains("        let latticeOnly = bodyAlpha <= 0.5\n") { out.append("H40: #354's old line is still there (+1 −1)") }
        // the next line is #354's, unchanged
        if let r = mm.range(of: h40Pin), let nl = mm[r.upperBound...].firstIndex(of: "\n") {
            if !mm[mm.index(after: nl)...].hasPrefix("        var vbuf: MTLBuffer, fbuf: MTLBuffer, drawCount: Int\n") {
                out.append("H40: #354's next line moved")
            }
        }
        return out
    }

    func testH40TheContactShadowKeepsThePrintedBody() throws {
        let mm = try Self.text("MetalMeshView.swift")
        XCTAssertEqual(Self.h40Failures(mm), [], "★ H40 at its anchor with its gate")
        let ungated = mm.replacingOccurrences(of: Self.h40Pin, with: Self.h40Pin.replacingOccurrences(of: Self.h40Gate, with: ""))
        XCTAssertFalse(Self.h40Failures(ungated).isEmpty, "★ RED CONTROL: H40 without its gate fails the pin")
        // the gate is ours: false unless the Flexible pass draws the printed view
        let ours = try Self.text("MeshRenderer+FlexibleLattice.swift")
        XCTAssertTrue(ours.contains("    var flexibleBodyPrinted: Bool {\n        guard flexibleLatticeInFrame, let fx = flexibleLattice, !fx.controlNoPrintedShadow else { return false }\n        return fx.printed\n    }"),
                      "the gate: the Flexible pass in frame AND its printed view")
        XCTAssertEqual(mm.components(separatedBy: "flexibleBodyPrinted").count - 1, 1, "#354's file reads the gate once (H40)")
    }

    // MARK: - ruling 6: one door to core's scene

    func testEveryCoreSceneTheFlexibleStageOpensGoesThroughTheDoor() throws {
        let names = try FileManager.default.contentsOfDirectory(atPath: Self.sources.path).filter { $0.hasSuffix(".swift") }
        var sites: [String: Int] = [:]
        for n in names {
            let t = try Self.text(n)
            let c = t.components(separatedBy: "FlexibleScene(jobJSON:").count - 1
            if c > 0 { sites[n] = c }
        }
        XCTAssertEqual(sites, ["FlexibleCoreDoor.swift": 1], "★ the door is the only place a core scene is opened")
        let door = try Self.text("FlexibleCoreDoor.swift")
        XCTAssertTrue(door.contains("guard facePrism else {"), "★ the door refuses with no face-prism")
        let edge = try Self.text("FlexibleStageModel+EdgePick.swift")
        XCTAssertEqual(edge.components(separatedBy: "door.open(jobJSON: job.json, jobDir: job.dir, facePrism: prisms)").count - 1, 2,
                       "★ the strips' two openings go through the door")
        // ★ RED CONTROL: today's openings (the worker's and the strips' two) — three outside any door
        let today = ["FlexibleStageModel.swift": 1, "FlexibleStageModel+EdgePick.swift": 2]
        XCTAssertNotEqual(sites, today, "★ RED CONTROL: today's three openings fail the check")
    }
}
