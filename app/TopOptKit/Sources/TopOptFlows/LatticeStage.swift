// LatticeStage — the redesign's LATTICE stages (batch B4, his picks 2026-10-24: L1 amended, S3 amended, A1 corner pair).
//
// A RE-LAYOUT of existing function, never new engine behaviour: the stage's lattice job and a variant's re-lattice job are
// pinned byte-identical to B3 (LatticeStageTests). What moved, and where it moved to:
//   * ONE lattice type per project. The first entry asks (today's LatticeStageModeModal — the selector); after a pick the
//     ● menu names that type alone ("● Structural ⌄"). Flexible is #362's stage: its card joins the selector there
//     (`LatticeTypeChoice.offered(flexibleStageBuilt:)`; #362's `onChooseFlexible`, H38), never here.
//   * "Change lattice type…" asks in place, three ways (ChangeLatticeTypeChoice): a duplicate that carries everything and
//     opens the selector in the copy (AppModel.duplicateAndChooseLatticeType), lose all work (ProjectModel.clearLatticeWork,
//     today's mode-sheet delete), Cancel.
//   * The stage buttons → "● <Type> ⌄ | Regions | Cells | ✂" (StageCapsule) plus what it builds on ("on the part" / "on −35 %").
//   * Regions = the Selections list (SelectionsList: groups and lattice regions in one list, eye, trash "from every stage" +
//     one Undo); Cells = today's lattice settings rows (LatticeSetupWizard in its `.cellsPage` presentation), plus the rows
//     the design adds (Grade from/to, Along, Strength / Ties / Overhangs) mapped onto today's settings.
//   * The lattice run's re-run card (APP LIST 6): its own action — it starts the LATTICE request, never Topology's run.
//
// Pure values here (and two small views), so each rule is asserted headlessly.

import SwiftUI
import TopOptKit
import TopOptDesign

// MARK: - one lattice type per project (L1 amended)

/// The selector's choices. Structural and Aesthetic are core's two grading intents (LatticeStageMode); Flexible is #362's
/// stage, offered only where that stage is built.
public enum LatticeTypeChoice: String, Equatable, Sendable, CaseIterable {
    case structural, aesthetic, flexible

    public var title: String {
        switch self {
        case .structural: return "Structural"
        case .aesthetic: return "Aesthetic"
        case .flexible: return "Flexible"
        }
    }

    /// The intent a pick records (`LatticeSettings.stageMode`). Flexible records none here: its stage owns its own setup.
    public var mode: LatticeStageMode? {
        switch self {
        case .structural: return .structural
        case .aesthetic: return .aesthetic
        case .flexible: return nil
        }
    }

    /// The selector's cards, in order. This tree has no Flexible stage (#362), so it offers two; #362's modal adds its card
    /// beside them (H38, `onChooseFlexible`).
    public static func offered(flexibleStageBuilt: Bool) -> [LatticeTypeChoice] {
        flexibleStageBuilt ? [.structural, .aesthetic, .flexible] : [.structural, .aesthetic]
    }
}

public enum LatticeTypeSelector {
    /// The first entry (and the first after "Continue and lose all work", or in a duplicate made to choose a type): the
    /// stage is up and the project has no type. `nil` is "not yet asked" — never a default.
    public static func isShown(onLatticeStage: Bool, typeInUse: LatticeStageMode?) -> Bool {
        onLatticeStage && typeInUse == nil
    }

    /// The selector's second line (was "This is set once … cannot be changed afterwards": it now can, by asking).
    public static let oneTypeLine = "One lattice type per project. To change it later: \u{25CF} menu \u{2192} Change lattice type\u{2026}"
}

// MARK: - the ● menu

public enum LatticeStageMenu {
    public enum Target: Equatable, Sendable { case none, topology, changeType, editFaces, about }

    public struct Row: Equatable, Sendable {
        public let id: String
        public let title: String
        public let detail: String?
        public let enabled: Bool
        public let checked: Bool
        public let target: Target
    }

    public static let changeTypeTitle = "Change lattice type\u{2026}"
    public static let changeTypeDetail = "asks first: the lattice work goes"

    /// The ● title: the project's ONE type (B3's seam, `TopologyStageMenu.latticeTitle`).
    public static func title(typeInUse: LatticeStageMode?) -> String {
        TopologyStageMenu.latticeTitle(typeInUse: typeInUse)
    }

    /// ‹ Topology, the ONE type ✓ (here), Change lattice type…, Edit faces…, About <type>…. Never a second type.
    public static func rows(typeInUse: LatticeStageMode?, anchors: Int, loads: Int) -> [Row] {
        func count(_ n: Int, _ w: String) -> String { n == 0 ? "no \(w)" : "\(n) \(w)\(n == 1 ? "" : "s")" }
        let name = title(typeInUse: typeInUse)
        var out = [
            Row(id: "lattice-menu-topology", title: "\u{2039} Topology",
                detail: "\(count(anchors, "anchor")) \u{00B7} \(count(loads, "load"))", enabled: true, checked: false,
                target: .topology),
            Row(id: "lattice-menu-type", title: name, detail: "You are here", enabled: false, checked: true, target: .none),
        ]
        if typeInUse != nil {
            out.append(Row(id: "lattice-menu-change-type", title: changeTypeTitle, detail: changeTypeDetail, enabled: true,
                           checked: false, target: .changeType))
        }
        out.append(Row(id: "lattice-menu-edit-faces", title: TopologyStageMenu.editFacesTitle,
                       detail: TopologyStageMenu.editFacesDetail, enabled: true, checked: false, target: .editFaces))
        if typeInUse != nil {
            // the id ends "-menu-about" so StageCapsule draws its divider above it
            out.append(Row(id: "lattice-menu-about", title: "About \(name)\u{2026}", detail: "limits \u{00B7} delete the lattice",
                           enabled: true, checked: false, target: .about))
        }
        return out
    }

    /// A row as the capsule takes it.
    public static func capsuleAction(_ t: Target) -> StageCapsule.Action {
        switch t {
        case .none: return .none
        case .topology: return .topology
        case .changeType: return .changeType
        case .editFaces: return .editFaces
        case .about: return .about
        }
    }
}

// MARK: - the capsule's pages

/// The lattice stage's two pages. Regions: the one list (groups and regions), depth / expand / grade. Cells: the lattice's
/// cell settings (today's settings page, re-homed).
public enum LatticeStagePage: String, Equatable, Sendable, CaseIterable {
    case regions, cells

    public var title: String { self == .regions ? "Regions" : "Cells" }

    /// The lit page: Cells while today's settings page is up, else Regions.
    public static func current(cellsUp: Bool) -> LatticeStagePage { cellsUp ? .cells : .regions }
}

public enum LatticeStageCopy {
    /// What the lattice builds on, beside the capsule: "on the part" on the stage (it lattices the solid part), "on −35 %"
    /// on a variant (its saving, the Results tab's own headline rule; "+N %" on a growth variant).
    public static func builtOn(achievedVolumeFraction vf: Double?) -> String {
        guard let vf, vf.isFinite, vf > 0 else { return "on the part" }
        let pct = Int(((1 - vf) * 100).rounded())
        if pct < 0 { return "on +\(-pct) %" }
        return "on \u{2212}\(pct) %"
    }
}

// MARK: - "Change lattice type…" (three ways)

public enum ChangeLatticeTypeChoice: String, Equatable, Sendable, CaseIterable {
    case duplicate, loseAll, cancel

    public static let title = "Change the lattice type?"

    public var label: String {
        switch self {
        case .duplicate: return "Create a duplicate and choose a type"
        case .loseAll: return "Continue and lose all work"
        case .cancel: return "Cancel"
        }
    }

    public func detail(was type: String) -> String? {
        switch self {
        case .duplicate: return "Recommended \u{00B7} the copy keeps everything; this project keeps its \(type) lattice"
        case .loseAll: return "Clears the \(type) lattice here; Undo brings it back"
        case .cancel: return nil
        }
    }

    public static func message(type: String, regions: Int) -> String {
        "This project\u{2019}s lattice is \(type): \(regions) region\(regions == 1 ? "" : "s"), their cells and grades. "
            + "A duplicate carries all of it over (regions, groups, settings) and opens the type selector in the copy. "
            + "Continuing here clears the lattice; Topology\u{2019}s groups and results stay."
    }
}

/// A project the workspace should open ON THE LATTICE STAGE (the copy "Create a duplicate and choose a type" makes, so its
/// selector shows at once; the copy the lattice re-run card's "Save as new project" makes). Once, for that project.
public enum LatticeStageOpen {
    @MainActor private static var pending: (id: UUID, toast: String?)?

    @MainActor public static func request(_ project: UUID, toast: String? = nil) { pending = (project, toast) }

    /// The request for `project`, exactly once (its toast, or "" for none); nil when there is none.
    @MainActor public static func take(for project: UUID) -> String? {
        guard let p = pending, p.id == project else { return nil }
        pending = nil
        return p.toast ?? ""
    }
}

extension LatticeSettings {
    /// ★ THE TYPE, CLEARED: no type in use, so the selector asks (a copy made to choose a type). ONE place for "no type":
    /// #362's merge adds `flexible = nil` HERE (reviewer ruling 08:45) — this tree has no `flexible` field — so neither a
    /// Structural / Aesthetic pick nor a pending copy can leave Flexible's `owns()` claiming the project.
    public mutating func clearLatticeType() {
        stageMode = nil
        flexible = nil   // Flexible (PR #362) H54: a Structural/Aesthetic pick or a pending copy clears Flexible's claim (reviewer ruling 2026-10-24 08:45, R4)
    }

    /// The selector's Structural / Aesthetic pick: any other type cleared first, then this one.
    public mutating func chooseLatticeType(_ mode: LatticeStageMode) {
        clearLatticeType()
        stageMode = mode
    }
}

/// What "Continue and lose all work" took, for its one-step Undo (as a trash's): live only while nothing has changed since.
public struct ClearedLattice: Equatable, Sendable {
    public let type: String
    let after: EditSnapshot
    public var undoLabel: String { "Undo \u{2014} put the \(type) lattice back" }
}

extension ProjectModel {
    /// ★ "CONTINUE AND LOSE ALL WORK" — today's mode-sheet delete, as a model call: every lattice setting goes (the type
    /// with them, so the selector asks again); Topology's groups, face regions and results stay. Sealed BEFORE and AFTER,
    /// so it is ONE undo step (APP LIST 1, as `trashGroup`): one Undo restores exactly the lattice work.
    @discardableResult
    public func clearLatticeWork() -> ClearedLattice {
        let type = lattice.stageMode?.title ?? "lattice"
        sealUndoStep()
        lattice = LatticeSettings()
        sealUndoStep()
        return ClearedLattice(type: type, after: editSnapshot)
    }

    public func canUndoClearLattice(_ c: ClearedLattice) -> Bool { editSnapshot == c.after }

    /// The one-step Undo: the history's own undo (the lattice is in the undo slice).
    public func undoClearLattice(_ c: ClearedLattice) {
        guard canUndoClearLattice(c) else { return }
        performUndo()
    }
}

extension AppModel {
    /// ★ "CREATE A DUPLICATE AND CHOOSE A TYPE": today's duplicate (ProjectDuplication — the whole setup: groups, face
    /// regions, every lattice setting; never results), opened, with its lattice TYPE cleared so its selector asks. Returns
    /// the copy, or nil (the original is untouched).
    @discardableResult
    public func duplicateAndChooseLatticeType(id: UUID) -> RecentProject? {
        guard let copy = duplicateProject(id: id) else { return nil }
        open(copy)
        project?.lattice.clearLatticeType()
        persistCurrentProject()
        LatticeStageOpen.request(copy.id)   // the copy opens on Lattice; its type is nil, so the selector shows there
        return copy
    }

    /// ★ THE LATTICE RE-RUN CARD'S "SAVE AS NEW PROJECT" (approved mockup over #362's H50d): today's duplicate — the SETUP
    /// only, never results (his rule) — opened on the Lattice stage with "press Lattice to run it". It runs NOTHING: no
    /// `RerunCard.runOnOpen`, so the copy's open starts no Optimize and no lattice run.
    @discardableResult
    public func saveAsNewProjectForLattice(id: UUID) -> RecentProject? {
        guard let copy = duplicateProject(id: id) else { return nil }
        LatticeStageOpen.request(copy.id, toast: LatticeRerunChoice.copyOpenToast)
        open(copy)
        return copy
    }
}

// MARK: - the lattice run's re-run card (APP LIST 6)

/// "Re-running clears this lattice's results": [Re-run the lattice here] [Save as new project] [Cancel]. The first starts
/// the LATTICE request (`makeLatticeRunRequest`), never `startRun()` (Topology's Optimize).
public enum LatticeRerunChoice: String, Equatable, Sendable, CaseIterable {
    case rerunHere, saveAsNew, cancel

    public static let title = "Re-running clears this lattice\u{2019}s results"
    public static let copyOpenToast = "The copy is open \u{2014} press Lattice to run it."

    public var label: String {
        switch self {
        case .rerunHere: return "Re-run the lattice here"
        case .saveAsNew: return RerunCard.saveAsNewLabel
        case .cancel: return RerunCard.cancelLabel
        }
    }
}

// MARK: - the Cells page's Along (decided 2026-10-24: keep all three)

/// Which way the grade runs. "By stress" / "Along the load" is core's stress-graded density (`densityMode == .sim`).
/// "Through the depth" and "Across the face" are SAVED (`gradeAlong`) and DRAWN by the preview's octree bake
/// (`LatticePreviewOccupancy.alongFraction`); the job does not read them (core's side is on the CORE LIST). No notice:
/// his standing rule (10-21) — the preview shows what's set, core is told through the CORE LIST.
public enum LatticeGradeAlong: String, Codable, Equatable, Sendable, CaseIterable {
    case depth, face, load

    public func title(_ mode: LatticeStageMode?) -> String {
        switch self {
        case .depth: return "Through the depth"
        case .face: return "Across the face"
        case .load: return (mode ?? .structural) == .structural ? "By stress" : "Along the load"
        }
    }

    /// The lit choice: core's stress grade when it is on and nothing else was picked; a drawn pick as picked; "By stress"
    /// only while the density really is the simulated one.
    public static func lit(stored: LatticeGradeAlong?, densityMode: LatticeDensityMode) -> LatticeGradeAlong? {
        if stored == .load || stored == nil { return densityMode == .sim ? .load : nil }
        return stored
    }
}

extension LatticeWizardModel {
    /// Along's tap. "By stress" is today's Sim density (the wizard's own setter, refused without the simulation permission:
    /// returns false). The other two are saved and drawn by the preview's bake — the job does not move.
    @discardableResult
    public mutating func chooseAlong(_ a: LatticeGradeAlong) -> Bool {
        if a == .load {
            guard simulateStresses else { return false }
            setDensityMode(.sim)
        }
        gradeAlong = a
        return true
    }
}

/// The Cells page's rows the design adds where today has no control or no backing — each says which.
public enum LatticeCellsRow: String, Equatable, Sendable, CaseIterable {
    case grade, along, strength, ties, overhangs

    public var title: String {
        switch self {
        case .grade: return "Grade"
        case .along: return "Along"
        case .strength: return "Strength"
        case .ties: return "Ties"
        case .overhangs: return "Overhangs"
        }
    }

    /// Structural adds Strength; Aesthetic adds Ties and Overhangs.
    public static func rows(_ mode: LatticeStageMode?) -> [LatticeCellsRow] {
        (mode ?? .structural) == .structural ? [.grade, .along, .strength] : [.grade, .along, .ties, .overhangs]
    }

    /// The line a row with no live control of its own shows.
    public static let strengthLine = "Checked by core when the lattice runs (the Core step); no estimate before it."
    public static let tiesNotOrganic = "Ties are an organic setting: pick Organic under Grade style."
    public static let tiesOrganic = "Transfer ties, in Organic \u{203A} Fine-tune."
    public static let overhangsLine = "Printed as traced: core removed the flare stage (#358)."
    /// The tabs share one set of settings today.
    public static let tabsNote = "These settings apply to every region today."
    /// ★ B8: the Density row's choices. No "Sim": Along's "By stress" sets it (the same `densityMode = .sim`).
    public static let densityChoices: [LatticeDensityMode] = [.uniform, .perRegion]
}

extension NumberPad.Config {
    /// The keypad's "+" beside the Expand title (APP LIST 2: the box and the handle already show "+").
    static let expandSymbol = "plus"
}

// MARK: - the in-place "Change lattice type…" card

struct ChangeLatticeTypeCard: View {
    let type: String
    let regions: Int
    let choose: (ChangeLatticeTypeChoice) -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.35).ignoresSafeArea().onTapGesture { choose(.cancel) }
            VStack(alignment: .leading, spacing: DS.Space.m) {
                Text(ChangeLatticeTypeChoice.title).dsStyle(DS.TypeScale.headline)
                    .foregroundStyle(DS.Color.textPrimary.color)
                Text(ChangeLatticeTypeChoice.message(type: type, regions: regions)).dsStyle(DS.TypeScale.footnote)
                    .foregroundStyle(DS.Color.textSecondary.color).fixedSize(horizontal: false, vertical: true)
                ForEach(ChangeLatticeTypeChoice.allCases, id: \.rawValue) { c in
                    Button { choose(c) } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(c.label).font(.system(size: 15, weight: .semibold))
                            if let d = c.detail(was: type) { Text(d).font(.system(size: 12, weight: .medium)).opacity(0.85) }
                        }
                        .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
                        .padding(.horizontal, DS.Space.l)
                        .foregroundStyle(c == .loseAll ? DS.Color.danger.color : c == .duplicate ? Color.white
                                         : DS.Color.textPrimary.color)
                        .background(RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous)
                            .fill(c == .duplicate ? DS.Color.accent.color : DS.Surface.panel.color))
                        .overlay(RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous)
                            .strokeBorder(c == .loseAll ? DS.Color.danger.color : .clear, lineWidth: 1.5))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("lattice-change-type-\(c.rawValue)")
                }
            }
            .padding(DS.Space.xl)
            .frame(maxWidth: 440)
            .background(RoundedRectangle(cornerRadius: DS.Radius.sheet, style: .continuous).fill(DS.Surface.dialog.color))
            .dsShadow(DS.Shadow.panel)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("lattice-change-type-card")
        }
    }
}
