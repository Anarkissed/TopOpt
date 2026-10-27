// TopologyStage — the redesign's TOPOLOGY stage (batch B3, his picks 2026-10-24: T2, S3 amended, A1 corner pair, B1 list).
//
// A RE-LAYOUT of existing function, never new behaviour: the job a Topology run sends is pinned byte-identical to B2's
// (TopologyStageTests.testTheTopologyJobIsByteIdenticalToB2). What moved, and where it moved to:
//   * the stage buttons (Lattice ›, Surface) → the "● Topology ⌄ | Setup | Results | Smooth | ✂" capsule (StageCapsule) and its
//     ● menu (TopologyStageMenu): Topology ✓, the project's ONE lattice type (or "Lattice…"), "Edit faces…";
//   * Results NEVER opens by itself after a run: a dot on its segment and a message with "Open Results"
//     (TopologyResultsNotice); Smooth is its own page;
//   * the chip column and the bottom bar's iPad / Print Parameters / Lattice / Optimize → the corner pair (CornerPair): a Setup
//     chip whose panel holds today's chips as rows (TopologySetupRow), and an Optimize split button;
//   * the Selections card → SelectionsList, one line per group with an EYE (view-only) and a TRASH that asks in place and comes
//     back with one Undo (ProjectModel.trashGroup / undoTrash);
//   * the re-run alert → the re-run card's three choices (RerunCard, TopologyRerunChoice).
//
// Pure values here (no view), so each rule is asserted headlessly.

import Foundation
import TopOptKit

// MARK: - the pages (T2)

/// Topology's three pages. Setup is always open to him; Results and Smooth are hidden until the project has results (B8).
public enum TopologyPage: String, Equatable, Sendable, CaseIterable {
    case setup, results, smooth

    public var title: String {
        switch self {
        case .setup: return "Setup"
        case .results: return "Results"
        case .smooth: return "Smooth"
        }
    }

    /// Which page is up: the smoothing page wins (it is mounted over everything), then Results while it is open.
    public static func current(resultsOpen: Bool, smoothing: Bool, hasResults: Bool) -> TopologyPage {
        if smoothing { return .smooth }
        return resultsOpen && hasResults ? .results : .setup
    }

    /// Results and Smooth need a run's results; Setup never greys.
    public static func enabled(_ p: TopologyPage, hasResults: Bool) -> Bool { p == .setup || hasResults }

    /// ★ B8 (his answer 2026-10-24): Results and Smooth are HIDDEN while the project has no results — not greyed. They
    /// appear when a run lands, or on reopening a project that has results.
    public static func shown(hasResults: Bool) -> [TopologyPage] { hasResults ? allCases : [.setup] }

    /// The capsule's segments to hide (Results = secondary, Smooth = tertiary). The greyed ✂ is not a page: it stays.
    public static func hiddenSegments(hasResults: Bool) -> Set<StageCapsule.Page> {
        hasResults ? [] : [.secondary, .tertiary]
    }

    /// The variant Smooth opens on: the recommendation — "the last accepted rung" (ResultsModel.isRecommended's one rule).
    public static func smoothVariant(_ outcome: OptimizeOutcome?) -> Int? {
        outcome?.variants.lastIndex(where: { $0.accepted })
    }
}

/// ★ RESULTS NEVER OPENS BY ITSELF (T2, 2026-10-24). A run that lands puts a dot on the Results segment and a message with
/// "Open Results"; the page stays where he is. Opening Results clears both.
public struct TopologyResultsNotice: Equatable, Sendable {
    public private(set) var dot = false
    public private(set) var message: String?
    /// The accepted-variant count he has already been told about (or has seen on Results).
    private var told = 0

    public init() {}

    public static let openLabel = "Open Results"

    /// The run's accepted-variant count moved. More variants than he was told about, while Results is shut: the dot and the
    /// message. NEVER a page change — this type cannot open anything.
    /// ★ B8 (his answer 2026-10-24): the dot means "new results since you last looked" — only a run that LANDS sets it.
    /// A reopened project's results arrive after the page appears (persist-c restores them off the main thread), so the
    /// count moves with no run: `landedByRun: false` takes them as already seen (no dot, no message).
    public mutating func note(accepted: Int, streaming: Bool, resultsOpen: Bool, landedByRun: Bool = true) {
        if accepted < told { told = accepted }            // a new run retired the old variants
        guard landedByRun else { told = accepted; return }
        guard accepted > told else { return }
        told = accepted
        guard !resultsOpen else { return }
        dot = true
        message = Self.message(accepted: accepted, streaming: streaming)
    }

    /// The run finished (no longer streaming) with variants he has not opened: the message says so.
    public mutating func noteFinished(accepted: Int, resultsOpen: Bool) {
        guard accepted > 0, !resultsOpen, dot else { return }
        message = Self.message(accepted: accepted, streaming: false)
    }

    /// A project opened with results already on it: nothing new has landed, so no dot (the Results segment is simply live).
    public mutating func seed(accepted: Int) { told = accepted }

    /// Whether the outcome moved because a run is landing (streaming, or resolved with results of its own). Never a restore
    /// from disk (only while idle, `RunModel.restoreOutcome`), nor a failed or cancelled run putting the PREVIOUS run's
    /// variants back (`restorePreservedOutcome`): neither is new.
    public static func landedByRun(_ phase: RunPhase) -> Bool { phase == .running || phase == .succeeded }

    /// He opened Results.
    public mutating func opened() { dot = false; message = nil }

    /// He dismissed the message (the dot stays until Results is opened).
    public mutating func dismiss() { message = nil }

    static func message(accepted: Int, streaming: Bool) -> String {
        let n = accepted == 1 ? "1 variant" : "\(accepted) variants"
        return streaming ? "\(n) ready \u{2014} more on the way." : "Optimization finished \u{2014} \(n)."
    }
}

// MARK: - the ● menu (S3 amended)

/// The ● Topology menu: the stages, never a second set of stage buttons. "Edit faces…" opens today's Surface stage (B5 builds
/// the real Edit faces screen); the greyed ✂ after Smooth opens the same thing.
public enum TopologyStageMenu {
    public enum Target: Equatable, Sendable { case none, lattice, editFaces }

    public struct Row: Equatable, Sendable {
        public let id: String
        public let title: String
        public let detail: String?
        public let enabled: Bool
        public let checked: Bool
        public let target: Target
    }

    public static let editFacesTitle = "Edit faces\u{2026}"
    public static let editFacesDetail = "cut \u{00B7} union \u{00B7} pattern"
    public static let scissorsLabel = "Edit faces"

    /// ★ B4's SEAM: the lattice row names the project's ONE lattice type, or "Lattice…" before one is chosen. B4 owns what
    /// choosing / changing the type does; this only names it.
    public static func latticeTitle(typeInUse: LatticeStageMode?) -> String {
        typeInUse?.title ?? "Lattice\u{2026}"
    }

    /// The rows, in order: Topology ✓ (here), the lattice row (gated as the old Lattice button was: gravity, an anchor, a
    /// load), Edit faces….
    public static func rows(typeInUse: LatticeStageMode?, latticeGate: LatticeEntryButtonGate) -> [Row] {
        [
            Row(id: "topology-menu-topology", title: "Topology", detail: "You are here", enabled: false, checked: true,
                target: .none),
            Row(id: "topology-menu-lattice", title: latticeTitle(typeInUse: typeInUse),
                detail: latticeGate.enabled ? nil : latticeGate.subtitle, enabled: latticeGate.enabled, checked: false,
                target: .lattice),
            Row(id: "topology-menu-edit-faces", title: editFacesTitle, detail: editFacesDetail, enabled: true, checked: false,
                target: .editFaces),
        ]
    }

    /// Where a target goes, as a stage. B5: Edit faces is a mode, not a stage (nil — the row opens the mode).
    public static func stage(for t: Target) -> WorkspaceStage? {
        switch t {
        case .none: return nil
        case .lattice: return .lattice
        case .editFaces: return nil
        }
    }
}

extension WorkspaceStage {
    /// Whether the stage draws its forward column of stage BUTTONS. Topology does not: its capsule's ● menu and ✂ carry
    /// `forward` instead (S3 amended — "no Surface button"). B4: nor does the lattice stage (its capsule's ● menu and ✂
    /// reach Topology and Edit faces). B5: the Surface stage that kept them is gone — no stage draws them.
    public var drawsForwardButtons: Bool { false }
}

// MARK: - the Setup chip's rows (A1)

/// The Setup chip's panel: today's chip column and bar controls, one row each, in his order (Quality, Plate, Gravity,
/// iPad | Mac, Units, Minimize plastic, Protect skin, Design box, Print parameters). CAD surfaces (an EXPORT setting, STEP only)
/// is a row too — it decides the run's output, so it is not a view icon.
public enum TopologySetupRow: String, Equatable, Sendable, CaseIterable {
    case quality, plate, gravity, compute, units, minimizePlastic, protectSkin, cadFaces, designBox, printParameters

    public var title: String {
        switch self {
        case .quality: return "Quality"
        case .plate: return "Plate"
        case .gravity: return "Gravity"
        case .compute: return "Runs on"
        case .units: return "Units"
        case .minimizePlastic: return "Plastic"
        case .protectSkin: return "Protect skin"
        case .cadFaces: return "CAD surfaces"
        case .designBox: return "Design primitives"   // B6: the list of up to 6
        case .printParameters: return "Print parameters"
        }
    }

    /// The rows shown. The chip column's own rules carry over: Protect skin only once a face is protected (handoff 124), CAD
    /// surfaces only on a STEP part, the Design box only where the stage draws it.
    public static func visible(protectCount: Int, isStep: Bool, designBoxDrawn: Bool) -> [TopologySetupRow] {
        allCases.filter {
            switch $0 {
            case .protectSkin: return protectCount > 0
            // ★ HIDDEN (his ruling 2026-10-26 23:44): Protect exports holes and flat faces exact now; the run always
            // sends project_cad_faces = true (AppModel), so there is nothing left to switch.
            case .cadFaces: return false
            case .designBox: return designBoxDrawn
            default: return true
            }
        }
    }
}

// MARK: - the group line's eye and trash (B1)

public enum TopologySelectionsCopy {
    /// ★ THE EYE IS VIEW-ONLY (GroupViewState): hiding a group changes nothing about the run.
    public static let hiddenToast = "Hidden from view \u{2014} it still counts in the run."
    /// A group deleted on Topology goes from every stage (decided 2026-10-24: "Delete everywhere").
    public static func deleteAsk(_ name: String) -> String {
        let s = "Delete \(name) from every stage?"
        return s.count <= 44 ? s : "Delete this group from every stage?"
    }
    public static func deletedToast(_ name: String) -> String { "Deleted \(name)." }
    public static let undo = "Undo"
    /// The face chip's filled button: the tapped face joins the group with its role.
    public static func joinLabel(_ group: String, role: String) -> String { "Add to \(group) as \(role)" }
    public static let joinNote = "or pick a role below for a new group"
}

/// What a design-primitive trash took away, for its one-step Undo (B6).
public struct TrashedPrimitive: Equatable, Sendable {
    public let id: Int
    public let name: String
    let after: EditSnapshot
}

/// What a trash took away, for its one-step Undo: the edit slice after the delete (the Undo is live only while nothing else
/// has changed since) and the group's view state (hide / lock are not in the undo slice).
public struct TrashedGroup: Equatable, Sendable {
    public let id: UUID
    public let name: String
    public let wasHidden: Bool
    public let wasLocked: Bool
    let after: EditSnapshot
}

extension ProjectModel {
    /// ★ THE TRASH, AS ONE UNDO STEP (APP LIST 1). The history folds a burst of edits into one step on a 400 ms settle, so a
    /// delete made right after another edit merged with it, and the delete's Undo took the earlier edit back too (or a later
    /// one rode along). Sealed BEFORE the delete and AFTER it, the delete is its own step: one Undo restores exactly the group.
    /// The removal itself is today's `removeGroup` (selection, its kind, the force sync, its view state).
    @discardableResult
    public func trashGroup(_ id: UUID) -> TrashedGroup? {
        guard let g = selection.groups.first(where: { $0.id == id }), groupView.canEdit(id) else { return nil }
        let hidden = groupView.isHidden(id), locked = groupView.isLocked(id)
        sealUndoStep()
        selection.remove(id)
        force.clearKind(id)
        force.sync(groups: selection.groups)
        groupView.forget(id)
        sealUndoStep()
        return TrashedGroup(id: id, name: g.name, wasHidden: hidden, wasLocked: locked, after: editSnapshot)
    }

    /// Whether the trash's Undo still means "put that group back": nothing has changed since the delete.
    public func canUndoTrash(_ t: TrashedGroup) -> Bool { editSnapshot == t.after }

    /// The trash's one-step Undo: the history's own undo, and the group's eye / lock as they were.
    public func undoTrash(_ t: TrashedGroup) {
        guard canUndoTrash(t) else { return }
        performUndo()
        guard selection.groups.contains(where: { $0.id == t.id }) else { return }
        if t.wasHidden != groupView.isHidden(t.id) { groupView.toggleHidden(t.id) }
        if t.wasLocked != groupView.isLocked(t.id) { groupView.toggleLocked(t.id) }
    }

    // MARK: ★ B6 — a design primitive's trash, as ONE undo step

    /// The trash on a design-primitive row: sealed before and after (APP LIST 1), so one Undo restores exactly that row,
    /// where it was.
    @discardableResult
    public func trashPrimitive(_ id: Int) -> TrashedPrimitive? {
        guard let row = designBox.primitives.first(where: { $0.id == id }) else { return nil }
        sealUndoStep()
        designBox.remove(id)
        sealUndoStep()
        return TrashedPrimitive(id: id, name: row.name, after: editSnapshot)
    }

    /// Whether the trash's Undo still means "put that row back": nothing has changed since.
    public func canUndoTrashPrimitive(_ t: TrashedPrimitive) -> Bool { editSnapshot == t.after }

    /// The trash's one-step Undo: the history's own undo.
    public func undoTrashPrimitive(_ t: TrashedPrimitive) {
        guard canUndoTrashPrimitive(t) else { return }
        performUndo()
    }

    /// ★ THE FACE CHIP'S "Add to <group>": the face(s) he just tapped (a fresh, still-pending group) join an existing group
    /// instead of starting a new one. Today's SelectionModel.addFaces (a face belongs to one group) and today's removal of the
    /// emptied pending group; nothing new reaches the job.
    /// ★ // Flexible (PR #362) H55d: several roles on one face (owner 2026-10-25): the faces JOIN the group and stay in any other; Load + Anchor on one face is refused (the line).
    @discardableResult   // Flexible (PR #362) H55d: several roles on one face (owner 2026-10-25) — the Load + Anchor line, or nil
    public func joinPending(_ pending: UUID, into target: UUID) -> String? {   // Flexible (PR #362) H55d: several roles on one face (owner 2026-10-25)
        guard pending != target, force.kind(for: pending).isPending, groupView.canEdit(target),
              let faces = selection.groups.first(where: { $0.id == pending })?.faces,
              selection.groups.contains(where: { $0.id == target }) else { return nil }   // Flexible (PR #362) H55d: several roles on one face (owner 2026-10-25)
        if let r = SeveralRoles.role(of: force.kind(for: target)), SeveralRoles.clashes(faces: faces, as: r, in: target, selection: selection, force: force) { return SeveralRoles.anchorAndLoadLine }   // Flexible (PR #362) H55d: several roles on one face (owner 2026-10-25) — Load + Anchor on one face, refused
        sealUndoStep()
        selection.joinFaces(faces, to: target)   // Flexible (PR #362) H55d: several roles on one face (owner 2026-10-25) — the faces keep the other groups they are in (was addFaces, which took them out)
        selection.remove(pending)
        force.clearKind(pending)
        force.sync(groups: selection.groups)
        groupView.forget(pending)
        selection.setActive(target)
        return nil   // Flexible (PR #362) H55d: several roles on one face (owner 2026-10-25)
    }

    /// The group the face chip offers to join: the most recent group that already has a role (never the pending one).
    public func joinTarget(excluding pending: UUID) -> SelectionGroup? {
        selection.groups.last { $0.id != pending && !force.kind(for: $0.id).isPending && groupView.canEdit($0.id) }
    }
}

// MARK: - the re-run card's three choices

/// The re-run card (RerunCard's words): [Re-run here] [Save as new project] [Cancel]. Save as new project only on an Optimize
/// re-run (the Lattice run's card has no copy to run in — #362's H50d rule).
public enum TopologyRerunChoice: String, Equatable, Sendable, CaseIterable {
    case rerunHere, saveAsNew, cancel

    public var label: String {
        switch self {
        case .rerunHere: return RerunCard.rerunHereLabel
        case .saveAsNew: return RerunCard.saveAsNewLabel
        case .cancel: return RerunCard.cancelLabel
        }
    }

    public static func choices(offersCopy: Bool) -> [TopologyRerunChoice] {
        offersCopy ? [.rerunHere, .saveAsNew, .cancel] : [.rerunHere, .cancel]
    }
}
