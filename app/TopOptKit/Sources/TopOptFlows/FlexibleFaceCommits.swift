// FlexibleFaceCommits — STUB (tests first; the commits are empty). What the main Flexible page's Selections WRITE (task 2026-09-29-flexible-screens, round 7, batch
// R7-D2: his mockup pick 2, B1 with his three changes; his answers of 2026-10-14). Each commit is ONE sealed undo step
// (`project.sealUndoStep()` before and after) through #354's PUBLIC setters only — the same calls #354's Selections card
// makes (SelectionModel, ForceModel, LatticeSelectableRoles.declare, writeLatticeDepthMM / writeGroupDepthMM /
// writeLatticeExpandMM). The pick stays put afterwards: it never jumps to another group (his img4 lesson on the Squish page:
// "please make it stay on the same group and never shift").
//
// ★ HIS ANSWERS IT FOLLOWS (r7/tasks.md):
//   * "Lattice picked for a new face in the pop-up = a LATTICE-ONLY role on the Flexible stage (no Protect set behind it)".
//     ★ HELD: the reviewer's condition (d) — "a lattice-only group … is OK ONLY IF it changes nothing about a Topology run
//     … if it does change a Topology run, STOP and tell the reviewer". Measured before any D2 code (round7/batch_d2/
//     conditionD/): without H35 such a group is Pending and BLOCKS Topology's Optimize; with H35 it rides Topology's
//     lattice block (Face 4's include slab, 3 479 → 4 374 job bytes). So H35 is NOT landed and the [▦ Lattice] button
//     of chip N is held (greyed, one line) until the reviewer rules — `latticeOnlyRoleLanded`. Nothing writes
//     `latticeOnlyGroups` meanwhile.
//   * After Load: "NO weight pill (the weight is set later on the Settings page); reword the Load toast accordingly."
//   * "Main-page groups get a TRASH icon too (B1), deleting the group for Topology as well; one Undo brings it back" +
//     "Group trash should confirm deletion" (the reviewer's (f): "with a confirm before deleting and Undo: yes").
//   * The (c) join: "Add to Group C as lattice" writes exactly what it says — the group's common depth and expand.
//   * Existing purple groups are left as they are; a new group skips #BF5AF2 (the face-prism's own violet).

import Foundation
import TopOptKit

/// Chip N's five buttons.
public enum FlexibleNewFaceKind: String, CaseIterable, Sendable { case lattice, anchor, load, protect, keepClear }

/// Chip M's role line (the capsule opens these).
public enum FlexibleGroupRoleButton: String, CaseIterable, Sendable { case anchor, load, protect, keepClear }

/// A role tap's answer: done, or "Keep clear removes this lattice" must be asked first.
public enum FlexibleRoleAnswer: Equatable, Sendable { case done, asksFirst, refused }

/// Every word the Selections half says (his rule: one visible line per setting, ≤ 44 characters).
public enum FlexibleSelectionsCopy {
    public static func joinLabel(_ group: String) -> String { "Add to \(group) as lattice" }
    /// Under the join button: "25.0 mm deep, the same as Face 3 + Face 5".
    public static func joinNote(depthMM: Double, like: [String]) -> String {
        let d = String(format: "%.1f mm deep", depthMM)
        guard !like.isEmpty else { return d }
        let names = like.count > 2 ? "\(like.count) faces" : like.joined(separator: " + ")
        return d + ", the same as " + names
    }
    public static let orNew = "Or start a new group:"
    public static func loadToast(_ face: String) -> String { "\(face) is a Load. Set its weight on the Squish page." }
    /// ★ HELD (condition d): under chip N's five buttons while the lattice-only role waits for the reviewer.
    public static let latticeHeld = "Lattice on a new face waits for a review"
    public static func deleteAsk(_ name: String) -> String { "Delete \(name) here and in Topology?" }
    public static func deleted(_ name: String) -> String { "\(name) deleted here and in Topology" }
    public static let delete = "Delete"
    public static let cancel = "Cancel"
    public static let undo = "Undo"
    public static let statsCaption = "The current preview's numbers at this depth."
    public static let noNumbers = "No numbers yet for this face"
    public static let empty = "Tap a face on the model to start."
    public static let keepClearAsk = "Keep clear removes this lattice"
    public static let keepClear = "Keep clear"
    public static let keepClearBlocks = "Keep clear blocks lattice"
    public static let latticeInstead = "Lattice instead"
    public static let locked = "Locked on Topology"
    public static let unlock = "Unlock"
    public static let mixed = "mixed"
    public static let weightOnSquish = "set on the Squish page"
    public static let depthCaption = "Depth mm"
    public static let expandCaption = "Expand mm"
    public static let latticeOnly = "Lattice only"
    public static let setRole = "Set role"
    public static func allFaces(_ n: Int) -> String { "All \(n)" }
    public static func kindWord(_ k: FlexibleNewFaceKind) -> String {
        switch k {
        case .lattice: return "Lattice"
        case .anchor: return "Anchor"
        case .load: return "Load"
        case .protect: return "Protect"
        case .keepClear: return "Keep clear"
        }
    }
}

enum FlexibleFaceCommits {
    static let latticeOnlyRoleLanded = false
    static func group(_ id: UUID, _ p: ProjectModel) -> SelectionGroup? { nil }
    static func isLocked(_ id: UUID, _ p: ProjectModel) -> Bool { false }
    static func mayCarryLattice(_ id: UUID, _ p: ProjectModel) -> Bool { false }
    static func blockedByKeepClear(_ id: UUID, _ p: ProjectModel) -> Bool { false }
    static func canJoin(_ id: UUID?, _ p: ProjectModel) -> Bool { false }
    static func joinValues(_ id: UUID, _ p: ProjectModel, session s: FlexibleFacePickSession) -> (depth: Double, expand: Double, like: [String]) { (0, 0, []) }
    static func refs(_ faces: [FlexibleFreeFace], in gid: UUID) -> [LatticeSelectableRef] { [] }
    @discardableResult
    static func newGroup(_ kind: FlexibleNewFaceKind, faces: [FlexibleFreeFace], project p: ProjectModel,
                         session s: inout FlexibleFacePickSession) -> UUID? { nil }
    @discardableResult
    static func join(_ gid: UUID, faces: [FlexibleFreeFace], project p: ProjectModel, session s: inout FlexibleFacePickSession) -> Bool { false }
    static func setState(_ role: LatticeSelectableRole, ref: LatticeSelectableRef, group gid: UUID, project p: ProjectModel) {}
    static func setAll(_ role: LatticeSelectableRole, group gid: UUID, project p: ProjectModel) {}
    static func writeDepth(_ mm: Double, ref: LatticeSelectableRef?, group gid: UUID, project p: ProjectModel,
                           session s: inout FlexibleFacePickSession) {}
    static func setDepth(_ mm: Double, ref: LatticeSelectableRef?, group gid: UUID, project p: ProjectModel,
                         session s: inout FlexibleFacePickSession) {}
    static func setExpand(_ mm: Double, ref: LatticeSelectableRef?, group gid: UUID, project p: ProjectModel) {}
    @discardableResult
    static func setRole(_ b: FlexibleGroupRoleButton, group gid: UUID, project p: ProjectModel) -> FlexibleRoleAnswer { .refused }
    static func confirmKeepClear(group gid: UUID, project p: ProjectModel) {}
    static func latticeInstead(group gid: UUID, project p: ProjectModel) {}
    static func rename(_ gid: UUID, to name: String, project p: ProjectModel) {}
    @discardableResult
    static func delete(_ gid: UUID, project p: ProjectModel) -> String? { nil }
}
