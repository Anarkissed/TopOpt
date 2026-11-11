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
    public enum Target: Equatable, Sendable { case none, topology, changeType, editFaces, about, deleteStage }

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
    /// ★ B3 (his answer 11-03, via #362 20:22Z: "a way to delete the Lattice stage entirely straight from the page").
    public static let deleteStageTitle = "Delete lattice stage"
    public static let deleteStageDetail = "asks first \u{00B7} one Undo"

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
            out.append(Row(id: "lattice-menu-delete-stage", title: deleteStageTitle, detail: deleteStageDetail, enabled: true,
                           checked: false, target: .deleteStage))
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
        case .deleteStage: return .deleteStage
        }
    }
}

// MARK: - the capsule's pages

/// The lattice stage's two pages. Regions: the one list (groups and regions), depth / expand / grade. Cells: the lattice's
/// cell settings (today's settings page, re-homed).
public enum LatticeStagePage: String, Equatable, Sendable, CaseIterable {
    case regions, cells

    public var title: String { self == .regions ? "Setup" : "Lattice" }   // ★ B2 (U4, approved design 2026-11-02): "Setup │ Lattice", never Regions / Cells

    /// The lit page: Cells while today's settings page is up, else Regions.
    public static func current(cellsUp: Bool) -> LatticeStagePage { cellsUp ? .cells : .regions }
}

public enum LatticeStageCopy {
    /// What the lattice builds on, beside the capsule: "on −35 %" on a variant (its saving, the Results tab's own headline
    /// rule; "+N %" on a growth variant). ★ B2 (note 20, the reviewer's Q3 (c) 2026-11-03): nothing on the stage's own part
    /// (it said "on the part"); B6's corner ⌃ menu takes both cases.
    public static func builtOn(achievedVolumeFraction vf: Double?) -> String? {
        guard let vf, vf.isFinite, vf > 0 else { return nil }
        let pct = Int(((1 - vf) * 100).rounded())
        if pct < 0 { return "on +\(-pct) %" }
        return "on \u{2212}\(pct) %"
    }
}

/// ★ B6 s1 (his go 11-05; ledger note 21, app-map §3.6, mockup #lat-setup / #lat-corner): the Lattice Setup corner's and hint's
/// words — the corner is Topology's, [Settings ⌄] [Lattice] [⌃].
public enum LatticeSetupCopy {
    /// design-system §5's short form, while taps make lattice groups (mockup #lat-setup).
    public static let hint = "Tap a face to lattice it \u{00B7} drag to turn"
    /// Lattice, grey: nothing saved on the Lattice page yet (§4.6, ≤ 5 words).
    public static let saveFirst = "Save a lattice first"
    /// The fix line just above the corner (§4.18, N4) and its one tap.
    public static let noSettings = "No lattice settings yet"
    public static let openLattice = "Open Lattice"
    /// ⌃'s five (note 21), in its order; Optimize, then lattice is `TopologyRunCopy.optimizeThenLattice`.
    public static let original = "Lattice the original part"
    public static let optimizedResult = "Lattice an optimized result"
    public static let previewOnly = "Preview only"
    public static let export = "Export\u{2026}"
    /// Under "Lattice an optimized result" with no results yet.
    public static let noResults = "Optimize first"
    /// Lattice while its run goes (Topology's "Optimizing" rule).
    public static let running = "Latticing"
    /// The ready line: "Octet · 2 groups", "Octet · 1 group · 1 zone" (the mockup's).
    public static func ready(type: String, groups: Int, zones: Int = 0) -> String {
        "\(type) \u{00B7} \(groups) group\(groups == 1 ? "" : "s")"
            + (zones > 0 ? " \u{00B7} \(zones) zone\(zones == 1 ? "" : "s")" : "")
    }

    // ★ B6 s3a — the Lattice zones section (notes 25, 25a, N3)
    public static let zones = "Lattice zones"
    public static let addZone = "+ Add zone"
    public static let zoneEmpty = "A zone lattices a space with no face, like inside a drum."
    public static let box = "Box"
    public static let cylinder = "Cylinder"

    // ★ B6 s3b — Start from (notes 26, R2.2; mockup #lat-latmode-ask)
    public static let startFrom = "Start from"
    public static let startFromPlus = "Solid \u{00B7} + Lattice faces"
    public static let startFromMinus = "All lattice \u{00B7} \u{2212} Lattice faces"
    public static let startFromPlusLine = "faces add lattice"
    public static let startFromMinusLine = "faces remove it"
    public static let startFromInfo = "+ Lattice faces: the part stays solid, and the faces you pick add lattice (Protect keeps a solid skin). \u{2212} Lattice faces: the whole part is lattice, and the faces you pick remove it (no skin)."
    /// §4.13's in-place ask: your faces change meaning. `group`: the one face group's name, or nil for several.
    public static func modeAsk(toMinus: Bool, group: String?) -> String {
        let who = group ?? "your groups"
        return toMinus ? "Switch to \(startFromMinus)? The whole part becomes lattice, and \(who) remove\(group == nil ? "" : "s") it."
            : "Switch to \(startFromPlus)? The part becomes solid, and \(who) add\(group == nil ? "" : "s") lattice."
    }
    public static let switchMode = "Switch"
    /// While − is set: the job stays as today until the engine takes `lattice.whole_part` (his 11-03 rule).
    public static let wholePartWaits = "\u{2212} Lattice faces waits on the engine update"

    // ★ B6 s1b — the Selections rows (§4.3 / §4.4, mockup #lat-setup)
    public static let faces = "Faces"
    public static let newGroup = "+ New group"
    public static let newGroupToast = "Tap a face to start a new lattice group"
    public static let role = "Role"
    public static let thisFace = "This face"
    public static let lattice = "Lattice"
    public static let noLattice = "No lattice"
    /// A face declared out of the lattice (its row's value).
    public static let off = "Off"
    /// A group line's value: how deep its faces lattice, "12–31 mm deep" ("31 mm deep" when they agree to 0.1 mm).
    public static func deep(lo: Double, hi: Double) -> String {
        let a = SelectionsSummary.format((lo * 10).rounded() / 10, decimals: 1)
        let b = SelectionsSummary.format((hi * 10).rounded() / 10, decimals: 1)
        return a == b ? "\(a) mm deep" : "\(a)\u{2013}\(b) mm deep"
    }
    /// Note 22's tag on a face row.
    public static func alsoIn(_ group: String) -> String { "also in \(group)" }
    // ★ B6 s2a — the Topology panel (notes 23a, 23b)
    public static let topology = "Topology"
    public static let includeLine = "Switched-off groups are left out of this lattice."
    /// While a scenario's switch is off and the linked core can't take `lattice.scenarios` yet (his 11-03 rule). Group
    /// switches act in the app (release (2)), so they never show it.
    public static let includeWaits = "The run still uses every scenario until the engine update"
    /// ★ Release (2): while a group's switch is off — the one run that can't leave it out (pick (a), asked 11-06 09:49Z).
    public static let resultKeepsGroups =
        "Lattice an optimized result keeps every group: it is checked under the loads it was optimized with."
    /// While a switched-off group carries Protect or Keep clear: the job still applies them (the reviewer asked 09:49Z).
    public static let protectStillApplies = "Protect and Keep clear still apply to switched-off groups."

    // ★ B6 s2b — the role picker (notes 24, 27) and the open Topology panel's hint (23c)
    public static let protectSkin = "Protect skin"
    /// A lattice group with no role yet (§4.4's pending state).
    public static let pending = "Pending\u{2026}"
    /// Protect skin, until the engine has a per-region skin (E2.4): the run keeps the face solid.
    public static let skinWaits = "Runs as No lattice until the engine update"
    public static let topologyHint = "Taps go to Topology groups"
    /// ★ B6 N2: a picked face row's line, under its depth (mockup #lat-face-prism, "or drag its handle").
    public static let dragItsHandle = "Or drag its handle on the part"
    /// ★ his iPad 11-09 (2.1, the reviewer's ruling (a) 19:21Z): what a face row says. A face of a Protect skin group says
    /// so ("Protect skin · 4 mm") — it runs as No lattice until the engine has a per-region skin, and said "No lattice ·
    /// 4 mm" beside a depth with no handle (his rule: Protect skin = colour, no prism). A face with no role says "—"
    /// (its group has none yet) or "Off" (declared out); a latticed face its depth.
    public static func faceValue(role: LatticeGroupRole?, groupHasRole: Bool, skin: Bool, mm: String) -> String {
        guard let role else { return groupHasRole ? off : "\u{2014}" }
        return role == .exclude ? "\(notLatticed(skin: skin)) \u{00B7} \(mm)" : mm
    }

    /// A face kept out of the lattice: "Protect skin" in a Protect skin group, else "No lattice" (its row's word and its
    /// "This face" choice).
    public static func notLatticed(skin: Bool) -> String { skin ? protectSkin : noLattice }

    /// ★ his iPad 11-09 (3.1): a picked face row's Expand line (the number its ± handle on the part drags).
    public static let expand = "Expand"
    /// The ± handle's number on the part: "+2.0 mm", "−1.5 mm", "0 mm".
    public static func expandValue(_ mm: Double) -> String {
        let r = (mm * 10).rounded() / 10
        if r == 0 { return "0 mm" }
        return (r > 0 ? "+" : "\u{2212}") + SelectionsSummary.format(abs(r), decimals: 1) + " mm"
    }
    /// ★ B6 N3: a picked zone's line, under its size (mockup #lat-zone-sel).
    public static let zoneHandlesLine = "Drag its handles on the part to size it."
    /// The join's second line (the face takes the group it joins).
    public static let joinNote = "with its role and depth"

    /// The toast after a face row's trash (Undo, top left, brings it back).
    public static func removed(_ name: String) -> String { "\(name) removed \u{00B7} Undo brings it back" }
}

// MARK: - "Change lattice type…" (three ways)

/// ★ B3: "Delete lattice stage" asks with the clear-all confirm (design-system §4.29: it clears the whole lattice), its yes apart
/// from its no; yes is "Continue and lose all work" (ProjectModel.clearLatticeWork, ONE undo step) and lands on Topology.
public enum DeleteLatticeStageCopy {
    public static func question(type: String) -> String { "Delete the \(type) lattice stage?" }
    public static let detail = "Its regions, cells and settings go. Topology\u{2019}s groups and results stay. Undo brings it back."
    public static let keep = "Keep it"
    public static let delete = "Delete"
}

public enum ChangeLatticeTypeChoice: String, Equatable, Sendable, CaseIterable {
    /// ★ B3 (his answer 11-03, via #362 20:22Z: "I think this should be a third choice"): `keepRegions` keeps where the lattice
    /// goes and resets only the cells (the reviewer's ruling (a), 23:05Z).
    case duplicate, keepRegions, loseAll, cancel

    public static let title = "Change the lattice type?"

    public var label: String {
        switch self {
        case .duplicate: return "Create a duplicate and choose a type"
        case .keepRegions: return "Keep my regions and groups, choose a new type"
        case .loseAll: return "Continue and lose all work"
        case .cancel: return "Cancel"
        }
    }

    public func detail(was type: String) -> String? {
        switch self {
        case .duplicate: return "Recommended \u{00B7} the copy keeps everything; this project keeps its \(type) lattice"
        case .keepRegions: return "Only the \(type) cell settings reset; Undo brings them back"
        case .loseAll: return "Clears the \(type) lattice here; Undo brings it back"
        case .cancel: return nil
        }
    }

    public static func message(type: String, regions: Int) -> String {
        "This project\u{2019}s lattice is \(type): \(regions) region\(regions == 1 ? "" : "s"), their cells and grades. "
            + "A duplicate carries all of it over (regions, groups, settings) and opens the type selector in the copy. "
            + "Keeping your regions and groups resets only the cell settings. "
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

    /// ★ B3: a fresh lattice that keeps only WHERE this one goes (the include / exclude roles, depths and expands of groups and
    /// faces, the zones, the painted faces) — no type, so the selector asks.
    public func keepingPlacement() -> LatticeSettings {
        var k = LatticeSettings()
        k.enabled = enabled
        k.includePrimitives = includePrimitives
        k.paintedIncludeFaces = paintedIncludeFaces
        k.paintDepthMM = paintDepthMM
        k.groupRoles = groupRoles
        k.latticeList = latticeList   // ★ B6: the lattice groups are where the lattice goes
        k.groupDepthMM = groupDepthMM
        k.selectableRoles = selectableRoles
        k.selectableDepthMM = selectableDepthMM
        k.selectableExpandMM = selectableExpandMM
        return k
    }

    /// The selector's Structural / Aesthetic pick: any other type cleared first, then this one.
    public mutating func chooseLatticeType(_ mode: LatticeStageMode) {
        clearLatticeType()
        stageMode = mode
        // ★ his 11-09: choosing Structural (again) is deliberate — the thin-wall glow and pop-up show once more
        if mode == .structural { thinWallsNoticeSeen = false }
    }
}

extension ProjectModel {
    /// ★ his 11-09, the thin-wall pop-up's "Switch to Aesthetic": the mode changes and nothing else does — every group, zone,
    /// depth and setting stays (unlike Change lattice type, which keeps only where the lattice goes). One Undo step.
    public func switchLatticeStageMode(to mode: LatticeStageMode) {
        guard lattice.stageMode != mode else { return }
        sealUndoStep()
        lattice.stageMode = mode
        if mode == .structural { lattice.thinWallsNoticeSeen = false }
        sealUndoStep()
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

    /// ★ B3 ("Keep my regions and groups, choose a new type"; the reviewer's ruling (a), 23:05Z): where the lattice goes stays —
    /// its roles, depths, expands, zones and painted faces — and everything about the cells goes, per-region densities with it
    /// (a density kept from one type can be out of band for the next). The type goes too, so the selector asks; on a Flexible
    /// project its Squish setup counts as cells. ONE undo step, as the full clear.
    @discardableResult
    public func clearLatticeCells() -> ClearedLattice {
        let type = lattice.stageMode?.title ?? (lattice.flexible != nil ? "Flexible" : "lattice")
        sealUndoStep()
        lattice = lattice.keepingPlacement()
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

    /// Structural adds Strength. ★ B7 slice 2: Along (round 2, N5c: "remove the 'Along' options … put it on the list for an
    /// update later") and the Ties and Overhangs notes (plan.md §B7 "Removed") are off the page; the cases stay so an old
    /// snapshot's `gradeAlong` still decodes. Along's one live choice, "By stress", is Density's now (`densityChoices`).
    public static func rows(_ mode: LatticeStageMode?) -> [LatticeCellsRow] {
        (mode ?? .structural) == .structural ? [.grade, .strength] : [.grade]
    }

    /// The line a row with no live control of its own shows.
    public static let strengthLine = "Checked by core when the lattice runs (the Core step); no estimate before it."
    public static let tiesNotOrganic = "Ties are an organic setting: pick Organic under Grade style."
    public static let tiesOrganic = "Transfer ties, in Organic \u{203A} Fine-tune."
    public static let overhangsLine = "Printed as traced: core removed the flare stage (#358)."
    /// The tabs share one set of settings today.
    public static let tabsNote = "These settings apply to every region today."
    /// The Density row's choices. ★ B7 slice 2: with Along gone, "By stress" (`densityMode = .sim`, which Along's "By stress"
    /// set since B8) is Density's third choice again — offered only while the stress simulation is on (the permission rule:
    /// `setSimulateStresses` moves the axis off it when the switch goes off).
    public static func densityChoices(simulate: Bool) -> [LatticeDensityMode] {
        simulate ? [.uniform, .perRegion, .sim] : [.uniform, .perRegion]
    }
    /// The Density row's words: Along's "By stress" for the simulated density.
    public static func densityTitle(_ m: LatticeDensityMode) -> String { m == .sim ? "By stress" : m.title }
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
                    .background(CornerPairStyle.publish("changeType-\(c.rawValue)"))
                    .accessibilityIdentifier("lattice-change-type-\(c.rawValue)")
                }
            }
            .padding(DS.Space.xl)
            .frame(maxWidth: 440)
            .background(RoundedRectangle(cornerRadius: DS.Radius.sheet, style: .continuous).fill(DS.Surface.dialog.color))
            .dsShadow(DS.Shadow.panel)
            .background(CornerPairStyle.publish("changeTypeCard"))
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("lattice-change-type-card")
        }
    }
}
