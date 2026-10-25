// FlexibleR7U21HookTests — round 7 · U21, batch A: the hooks New TopOpt's Flexible tab lays in main's files, pinned by text.
// The reviewer's ruling of 2026-10-22 06:38 (1): "BATCH A HOOKS APPROVED as posted (H41–H44 ImportSheet.swift, H45
// WorkspacePlaceholder, H38' one-line edit …). Conditions: (a) with Flexible NOT chosen the sheet behaves exactly as today —
// H42's else-branch byte-identical … (b) each hook pinned once at its anchor with its gate, a gate-removed copy goes red." and
// the Home card's hook H46 ("show the Flexible filament when lattice.flexible.materialID is set, today's label otherwise").
//
//   H41  ImportSheet: the draft (@StateObject, inert)
//   H42  ImportSheet: `flexDraft.available` ⇒ the three-segment picker; else today's five SegmentedGlass lines, byte-identical
//   H43  ImportSheet: `flexDraft.on` ⇒ the flexible filament dropdown; else today's `materialDropdown`
//   H44  ImportSheet: `flexDraft.on` ⇒ continueFlexible; else today's `model.continueToWorkspace()`
//   H45  WorkspacePlaceholder: the one-shot landing on the Lattice stage (this project's id only)
//   H38' WorkspacePlaceholder: the mode modal's Flexible writes a new setup (`.newSetup()`, his Img7)
//   H46  HomeView: a Flexible project's card names its filament; else today's `project.meta`
import XCTest
@testable import TopOptFlows

final class FlexibleR7U21HookTests: XCTestCase {

    struct Hook { let id: String; let file: String; let pin: String; let gate: String; let anchor: String; let elseText: String? }

    static let todaysSegments = """
                SegmentedGlass(
                    [.init(ProcessKind.fdm, ProcessKind.fdm.segmentTitle),
                     .init(ProcessKind.resin, ProcessKind.resin.segmentTitle)],
                    selection: $model.process
                )

    """

    static let hooks: [Hook] = [
        Hook(id: "H41", file: "ImportSheet.swift",
             pin: "    @StateObject private var flexDraft = FlexibleImportDraft(materialsPath: FlexibleResources.materialsPath)   // Flexible (PR #362) H41: ",
             gate: "FlexibleImportDraft(materialsPath: FlexibleResources.materialsPath)",
             anchor: "    @State private var browsing = false\n", elseText: nil),
        Hook(id: "H42", file: "ImportSheet.swift",
             pin: "            Group { if flexDraft.available { FlexibleImportProcessPicker(model: model, draft: flexDraft) } else {   // Flexible (PR #362) H42: ",
             gate: "if flexDraft.available",
             anchor: "                .padding(.top, DS.Space.xl2)\n", elseText: nil),
        Hook(id: "H43", file: "ImportSheet.swift",
             pin: "            Group { if flexDraft.on { FlexibleImportFilamentMenu(draft: flexDraft) } else { materialDropdown } }.padding(.top, DS.Space.l)   // Flexible (PR #362) H43: ",
             gate: "if flexDraft.on",
             anchor: "            .padding(.top, DS.Space.sm)\n\n", elseText: "else { materialDropdown }"),
        Hook(id: "H44", file: "ImportSheet.swift",
             pin: "                           isEnabled: model.canContinue && flexDraft.canContinue) { if flexDraft.on { flexDraft.continueFlexible(model) } else { model.continueToWorkspace() } }   // Flexible (PR #362) H44: ",
             gate: "if flexDraft.on",
             anchor: "                PillButton(\"Continue\", style: .primary, systemImage: \"sparkles\",\n",
             elseText: "else { model.continueToWorkspace() }"),
        Hook(id: "H45", file: "WorkspacePlaceholder.swift",
             pin: "                .onAppear { if FlexibleNewProject.takeLatticeStage(for: project.id) { goToStage(.lattice) } }   // Flexible (PR #362) H45: ",
             gate: "if FlexibleNewProject.takeLatticeStage(for: project.id)",
             anchor: "                    if open, project.lattice.flexible != nil { showLatticeWizard = false; showFlexiblePage = true }\n                }\n",
             elseText: nil),
        Hook(id: "H38'", file: "WorkspacePlaceholder.swift",
             pin: "                    project.lattice.flexible = .newSetup()   // Flexible (PR #362) H38': ",
             gate: ".newSetup()",
             // ★ RE-PINNED (sync of #354 at 89af86dd: B4 564db991 made the mount `LatticeStageModeModal { mode in` (a trailing closure;
             // LatticeStageTests pins that text), so our closure follows as the second trailing closure. Anchor only.)
             anchor: "                } onChooseFlexible: {\n", elseText: nil),
        Hook(id: "H46", file: "HomeView.swift",
             pin: "                        Text(FlexibleHomeCard.meta(project) ?? project.meta)   // Flexible (PR #362) H46: ",
             gate: "FlexibleHomeCard.meta(project) ?? ",
             anchor: "                            .lineLimit(1)\n", elseText: "?? project.meta)"),
    ]

    static func source(_ file: String) throws -> String {
        try String(contentsOf: FlexibleHisProject.repoRoot.appendingPathComponent("app/TopOptKit/Sources/TopOptFlows/\(file)"), encoding: .utf8)
    }

    /// Every rule, on copies of the three files' text. Empty = all pinned.
    static func failures(_ files: [String: String]) -> [String] {
        var out: [String] = []
        for h in hooks {
            let src = files[h.file] ?? ""
            let n = src.components(separatedBy: h.pin).count - 1
            if n != 1 { out.append("\(h.id): the hook appears \(n) times (must be exactly once)"); continue }
            if !h.pin.contains(h.gate) { out.append("\(h.id): its gate '\(h.gate)' is not in it") }
            if !src.contains(h.anchor + h.pin) { out.append("\(h.id): not at its anchor") }
            if let e = h.elseText, !h.pin.contains(e) { out.append("\(h.id): its else branch is not today's '\(e)'") }
        }
        // H42: today's five lines byte-identical between the hook's two lines, the padding after
        let ims = files["ImportSheet.swift"] ?? ""
        if let h42 = hooks.first(where: { $0.id == "H42" }), let r = ims.range(of: h42.pin), let nl = ims[r.upperBound...].firstIndex(of: "\n") {
            let rest = ims[ims.index(after: nl)...]
            if !rest.hasPrefix(todaysSegments.dropLast() + "\n            } }   // Flexible (PR #362) H42 end\n            .padding(.top, DS.Space.sm)\n") {
                out.append("H42: the else branch is not today's five SegmentedGlass lines followed by its end and today's padding")
            }
        } else { out.append("H42: no line") }
        // H38: our own line stays right after H38' (FlexibleRound7ScreenHookTests re-pinned its anchor)
        let ws = files["WorkspacePlaceholder.swift"] ?? ""
        if !ws.contains("project.lattice.flexible = .newSetup()   // Flexible (PR #362) H38': a new setup reads nothing in from Topology (his Img7)\n                    showLatticeWizard = false   // Flexible (PR #362) H38: ") {
            out.append("H38': H38's line is not right after it")
        }
        if ws.contains("project.lattice.flexible = FlexibleStageSettings()") { out.append("H38': the old line is still there") }
        return out
    }

    func files() throws -> [String: String] {
        var f: [String: String] = [:]
        for name in ["ImportSheet.swift", "WorkspacePlaceholder.swift", "HomeView.swift"] { f[name] = try Self.source(name) }
        return f
    }

    func testEveryHookIsPinnedOnceAtItsAnchorWithItsGate() throws {
        let f = try files()
        let fails = Self.failures(f)
        XCTAssertEqual(fails, [], fails.joined(separator: "\n"))
        // RED CONTROL: each gate removed from a copy goes red
        for h in Self.hooks {
            var copy = f
            copy[h.file] = copy[h.file]!.replacingOccurrences(of: h.pin, with: h.pin.replacingOccurrences(of: h.gate, with: h.gate.hasPrefix("if ") ? "if true" : ""))
            XCTAssertFalse(Self.failures(copy).isEmpty, "RED CONTROL: \(h.id) with its gate removed must fail")
        }
        // RED CONTROL: H42's else branch touched
        var touched = f
        touched["ImportSheet.swift"] = touched["ImportSheet.swift"]!.replacingOccurrences(of: "                selection: $model.process\n", with: "                selection: $model.process   \n")
        XCTAssertFalse(Self.failures(touched).isEmpty, "RED CONTROL: H42's else branch must stay byte-identical")
    }

    /// The sheet's old body, back from the hooks, is today's (a639ed42's) body line for line: nothing else in it moved.
    func testTheSheetWithoutItsHooksIsTodays() throws {
        var s = try Self.source("ImportSheet.swift")
        func dropLine(containing t: String) { s = s.components(separatedBy: "\n").filter { !$0.contains(t) }.joined(separator: "\n") }
        dropLine(containing: "// Flexible (PR #362) H41: ")
        dropLine(containing: "// Flexible (PR #362) H42: ")
        dropLine(containing: "// Flexible (PR #362) H42 end")
        s = s.components(separatedBy: "\n").map { line in
            if line.contains("// Flexible (PR #362) H43: ") { return "            materialDropdown.padding(.top, DS.Space.l)" }
            if line.contains("// Flexible (PR #362) H44: ") { return "                           isEnabled: model.canContinue) { model.continueToWorkspace() }" }
            return line
        }.joined(separator: "\n")
        // re-pinned by Library (2026-10-25, reviewer ruling 22:36 (1)); was: no Library line to take back out.
        // The Library's one addition, its Project row (with the blank line before it), comes out like the hooks do.
        s = s.replacingOccurrences(of: "\n\n            LibraryImportProjectRow(model: model).padding(.top, DS.Space.l)   // Library: which project the new part joins", with: "")
        XCTAssertFalse(s.contains("flexDraft"), "★ no other line reads the draft")
        XCTAssertEqual(s.components(separatedBy: "\n").count, 251, "★ today's 250 lines (and the last newline)")
        XCTAssertTrue(s.contains("\n            fileRow.padding(.top, DS.Space.xl3)\n\n            Text(\"PRINT PROCESS\")\n"))
        XCTAssertTrue(s.contains("                .padding(.top, DS.Space.xl2)\n" + Self.todaysSegments.dropLast() + "\n            .padding(.top, DS.Space.sm)\n\n            materialDropdown.padding(.top, DS.Space.l)\n\n            minimizePlasticRow.padding(.top, DS.Space.l)\n"))
    }
}
