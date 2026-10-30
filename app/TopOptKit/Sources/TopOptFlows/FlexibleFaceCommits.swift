// FlexibleFaceCommits — what the main Flexible page's Selections WRITE (task 2026-09-29-flexible-screens, round 7, batch
// R7-D2: his mockup pick 2, B1 with his three changes; his answers of 2026-10-14). Each commit is ONE sealed undo step
// (`project.sealUndoStep()` before and after) through #354's PUBLIC setters only — the same calls #354's Selections card
// makes (SelectionModel, ForceModel, LatticeSelectableRoles.declare, writeLatticeDepthMM / writeGroupDepthMM /
// writeLatticeExpandMM). The pick stays put afterwards: it never jumps to another group (his img4 lesson on the Squish page:
// "please make it stay on the same group and never shift").
//
// ★ HIS ANSWERS IT FOLLOWS (r7/tasks.md):
//   * ★ HIS RULING of 2026-10-18 (it SUPERSEDES his 2026-10-14 "Lattice picked for a new face in the pop-up = a LATTICE-ONLY
//     role … (no Protect set behind it)"): "We do not want any lattices to be affected by topology optimization. This is why
//     I set it within 'protect' in the first place. These two things should behave the same way." So chip N's [▦ Lattice]
//     makes the group Lattice WITH Protect underneath — exactly [Protect] and then [▦ Lattice] on the face's chip, in ONE
//     undo step — and a protected group with a Lattice face reads "Lattice" (the shield beside it), whichever way it was
//     made. The lattice-only role (H35, its lattice-only set) is withdrawn: R7-D2 held it on the reviewer's condition (d)
//     (round7/batch_d2/conditionD/: without Protect the group is Pending and BLOCKS Topology's Optimize), now moot.
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

/// ★ REVIEW OF R7-D2: what else a join gives the face (a Load group's share of its load, an Anchor group's anchor).
public enum FlexibleJoinAlso: Equatable, Sendable { case none, load, anchor }

/// A role tap's answer: done, or "Keep clear removes this lattice" must be asked first.
public enum FlexibleRoleAnswer: Equatable, Sendable { case done, asksFirst, refused, locked }

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
    /// ★ REVIEW OF R7-D2: the join's note — for a Load or an Anchor group, what else the face takes, in plain words (the
    /// review: "Add to Top as lattice" joined the Load and took part of its 10 kg while the label said only "as lattice").
    public static func joinNote(depthMM: Double, like: [String], also: FlexibleJoinAlso) -> String {
        let d = String(format: "%.1f mm deep", depthMM)
        switch also {
        case .none: return joinNote(depthMM: depthMM, like: like)
        case .load: return d + " · it also shares the Load"
        case .anchor: return d + " · it is also anchored"
        }
    }
    /// ★ REVIEW OF R7-D2: a Load the chip made, its weight not set yet (the mockup's words).
    public static let weightUnset = "weight: Squish page"
    public static let orNew = "Or start a new group:"
    public static func loadToast(_ face: String) -> String { "\(face) is a Load. Set its weight on the Squish page." }
    /// ★ the review of R7-D2: ONE line of ≤ 44 characters whatever name he typed ("Delete Left side squeeze pad here and in
    /// Topology?" was 50 and widened the 348 pt list) — the name stays on the group's line right above the question.
    /// ★ THE REDESIGN, P3 (point 3; the reviewer's ruling R11 of 2026-10-24: "Delete 'X' from every stage?"): the group goes
    /// from every stage, named in curly quotes — 44 characters hold a name of up to 17; a longer one falls back.
    public static func deleteAsk(_ name: String) -> String {
        let s = "Delete \u{2018}\(name)\u{2019} from every stage?"
        return s.count <= 44 ? s : "Delete this group from every stage?"
    }
    public static func deleted(_ name: String) -> String {
        let s = "\(name) deleted here and in Topology"
        return s.count <= 44 ? s : "Group deleted here and in Topology"
    }
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
    public static let setRole = "Set role"
    /// ★ R7-E1 (his answer 2026-10-18 ~15:50): a tap on [Protect] of a Lattice group says why it stays on.
    public static let protectLocked = "Protect stays on while a face is Lattice"
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

@MainActor
enum FlexibleFaceCommits {

    /// ★ RED CONTROL only (FlexibleLatticeIsProtectedTests): R7-D2's hold put back — `newGroup(.lattice, …)` refuses.
    static var controlLatticeHeld = false
    /// ★ RED CONTROL only (FlexibleR7E1FollowUpTests): Protect toggles off on a Lattice group (the rule before his 2026-10-18
    /// answer — the group then went Pending and its lattice dropped out).
    static var controlProtectUnlocked = false

    /// ★ R7-E1 — HIS ANSWER of 2026-10-18 ~15:50: "On a Lattice group, Protect is LOCKED ON while any face of the group is
    /// Lattice (a lattice can never be exposed to Topology)." A group that reads Lattice (protected, no Anchor, Load or Keep
    /// clear, a Lattice face) cannot have Protect tapped off; once no face is Lattice it toggles again.
    static func protectLocked(_ id: UUID, _ p: ProjectModel) -> Bool {
        !controlProtectUnlocked && readsLattice(id, p)
    }

    /// ★ HIS RULING 2026-10-18 ("These two things should behave the same way"): a group reads "Lattice" — in the chip's role
    /// capsule and on the list's line, the shield beside it — when it is Protected (no Anchor, no Load, no Keep clear) and
    /// holds a Lattice face. [▦ Lattice] on a new face and [Protect] then [▦ Lattice] both give exactly that.
    static func readsLattice(_ id: UUID, _ p: ProjectModel) -> Bool {
        let k = p.force.kind(for: id)
        guard !k.isLoad, !k.isAnchor, p.force.keepClearAffix(for: id) != .on, p.force.isProtected(id) else { return false }
        return hasLattice(id, p)
    }

    // MARK: reads

    static func group(_ id: UUID, _ p: ProjectModel) -> SelectionGroup? { p.selection.groups.first { $0.id == id } }

    /// Locked on Topology (#354's padlock): nothing here writes it.
    static func isLocked(_ id: UUID, _ p: ProjectModel) -> Bool { !p.groupView.canEdit(id) }

    /// The group may carry a lattice role (#354's gate: an anchor, a load or Protect, and no Keep clear).
    static func mayCarryLattice(_ id: UUID, _ p: ProjectModel) -> Bool {
        LatticeFaceRoleGate.allowed(kind: p.force.kind(for: id), protected: p.force.isProtected(id),
                                    keepClearOn: p.force.keepClearAffix(for: id) == .on)
    }

    /// Keep clear is on and something of the group is set to Lattice (state B: "Keep clear blocks lattice").
    static func blockedByKeepClear(_ id: UUID, _ p: ProjectModel) -> Bool {
        guard p.force.keepClearAffix(for: id) == .on, let g = group(id, p) else { return false }
        if p.lattice.groupRoles[id] == .include { return true }
        return p.latticeSelectableRefs(g).contains { p.lattice.selectableRoles[$0.key] == .include }
    }

    /// The live (not Off) refs of a group and their depths / expands.
    static func liveRefs(_ g: SelectionGroup, _ p: ProjectModel) -> [LatticeSelectableRef] {
        p.latticeSelectableRefs(g).filter { p.latticeSelectableRole($0, in: g.id) != nil }
    }

    /// The most common value (ties: the smaller), to 0.1 mm.
    static func mostCommon(_ v: [Double]) -> Double? {
        guard !v.isEmpty else { return nil }
        var counts: [Double: Int] = [:]
        for x in v { counts[(x * 10).rounded() / 10, default: 0] += 1 }
        return counts.max { a, b in a.value == b.value ? a.key > b.key : a.value < b.value }?.key
    }

    /// The join offers this group: picked earlier this session, still there, editable, able to carry a lattice role, and
    /// ★ (the review of R7-D2) already holding a lattice face — "Add to Top as lattice" was offered for his Load with no
    /// lattice face: it joined the Load (part of its 10 kg on the new face) at the paint default (4.0 mm), not a lattice depth.
    static func canJoin(_ id: UUID?, _ p: ProjectModel) -> Bool {
        guard let id, group(id, p) != nil, !isLocked(id, p) else { return false }
        return mayCarryLattice(id, p) && hasLattice(id, p)
    }

    /// ★ REVIEW OF R7-D2: what else joining `id` gives the face — a Load group's share of its load, an Anchor group's anchor.
    static func joinAlso(_ id: UUID, _ p: ProjectModel) -> FlexibleJoinAlso {
        let k = p.force.kind(for: id)
        return k.isLoad ? .load : k.isAnchor ? .anchor : .none
    }

    /// What the join writes: the group's most common live depth and expand (lastDepth, else the default, when it has
    /// none), and the faces that already sit at that depth.
    static func joinValues(_ id: UUID, _ p: ProjectModel, session s: FlexibleFacePickSession) -> (depth: Double, expand: Double, like: [String]) {
        guard let g = group(id, p) else { return (LatticeSlabDepth.clamp(p.lattice.paintDepthMM), 0, []) }
        let live = liveRefs(g, p)
        let depth = mostCommon(live.map { p.latticeSlabDepthMM($0, in: id) })
            ?? s.lastDepth ?? LatticeSlabDepth.clamp(p.lattice.paintDepthMM)
        let expand = mostCommon(live.map { p.latticeExpandMM($0) }) ?? 0
        let like = live.filter { abs(p.latticeSlabDepthMM($0, in: id) - depth) < 0.05 }.map { p.latticeSelectableName($0) }
        return (LatticeSlabDepth.clamp(depth), expand, like)
    }

    // MARK: writes (each ONE sealed undo step)

    /// The faces' refs inside group `gid`.
    static func refs(_ faces: [FlexibleFreeFace], in gid: UUID) -> [LatticeSelectableRef] {
        faces.map { f in
            switch f {
            case let .face(x): return .face(group: gid, face: x)
            case let .region(r): return .region(group: gid, region: r)
            }
        }
    }

    static func add(_ faces: [FlexibleFreeFace], to gid: UUID, _ p: ProjectModel) {
        let fs = faces.compactMap { if case let .face(f) = $0 { return f } else { return nil } }
        let rs = faces.compactMap { if case let .region(r) = $0 { return r } else { return nil } }
        if !fs.isEmpty { p.selection.addFaces(fs, to: gid) }
        if !rs.isEmpty { p.selection.addRegions(rs, to: gid) }
    }

    /// Chip N: a new group of the free faces with one role. Anchor / Load / Protect / Keep clear leave the faces Off (no
    /// lattice role). ★ Lattice (his ruling 2026-10-18): Protect underneath and every new face Lattice — [Protect] then the
    /// face chip's [▦ Lattice] (or the group's "All N" → Lattice), byte for byte, in ONE undo step: the group's role and depth
    /// seeded as #354's row chip seeds them (the lattice default depth), no face depth of its own.
    @discardableResult
    static func newGroup(_ kind: FlexibleNewFaceKind, faces: [FlexibleFreeFace], project p: ProjectModel,
                         session s: inout FlexibleFacePickSession) -> UUID? {
        guard !faces.isEmpty else { return nil }
        if kind == .lattice, controlLatticeHeld { return nil }
        p.sealUndoStep()
        let gid = p.selection.addGroup()
        // ★ a new group never takes the face-prism's own violet (#BF5AF2, the palette's 5th); existing ones are left alone
        if let g = group(gid, p), ((g.colorIndex % 5) + 5) % 5 == 4 { p.selection.setColorIndex(gid, g.colorIndex + 1) }
        add(faces, to: gid, p)
        p.force.sync(groups: p.selection.groups)
        switch kind {
        case .anchor: p.force.makeAnchor(gid)
        case .load: p.force.makeLoad(gid)
        case .protect: p.force.setProtected(gid, true)
        case .keepClear: p.force.setKeepClearAffix(gid, .on)
        case .lattice:
            // ★ his ruling 2026-10-18: Protect underneath (Topology never touches a lattice), then every new face Lattice —
            // setAll / seed are the face chip's and the "All N" line's own writes (setState / setAll below)
            p.force.setProtected(gid, true)
            if let g = group(gid, p) {
                LatticeSelectableRoles.setAll(.include, refs: p.latticeSelectableRefs(g), in: &p.lattice.selectableRoles)
            }
            seed(.include, gid, p)
        }
        p.sealUndoStep()
        s.lastGroup = gid
        return gid
    }

    /// The (c) join: the free faces into `gid` as Lattice, at the group's common depth and expand — exactly the label.
    @discardableResult
    static func join(_ gid: UUID, faces: [FlexibleFreeFace], project p: ProjectModel, session s: inout FlexibleFacePickSession) -> Bool {
        guard !faces.isEmpty, canJoin(gid, p) else { return false }
        let v = joinValues(gid, p, session: s)
        p.sealUndoStep()
        add(faces, to: gid, p)
        p.force.sync(groups: p.selection.groups)
        guard let g = group(gid, p) else { return false }
        let role = p.latticeEligibleRoles()[gid]
        for r in refs(faces, in: gid) {
            LatticeSelectableRoles.declare(.include, for: r, siblings: p.latticeSelectableRefs(g), groupRole: role,
                                           in: &p.lattice.selectableRoles)
            p.writeLatticeDepthMM(r, mm: v.depth)
            p.writeLatticeExpandMM(r, mm: v.expand)
        }
        if p.lattice.groupRoles[gid] == nil {
            p.lattice.groupRoles[gid] = .include
            if p.lattice.groupDepthMM[gid] == nil { p.lattice.groupDepthMM[gid] = v.depth }
        }
        p.lattice.enabled = true
        p.sealUndoStep()
        s.lastGroup = gid
        s.lastDepth = v.depth
        return true
    }

    /// One face's Lattice / Solid / Off — #354's row chip exactly (WorkspacePlaceholder's latticePrimitiveChip): declare with
    /// the siblings pinned; the first non-Off seeds the group's role and depth; Off keeps the stored depth.
    static func setState(_ role: LatticeSelectableRole, ref: LatticeSelectableRef, group gid: UUID, project p: ProjectModel) {
        guard let g = group(gid, p), !isLocked(gid, p) else { return }
        let now = p.latticeSelectableRole(ref, in: gid).map(LatticeSelectableRole.init) ?? .off
        guard now != role else { return }   // it already says this; a re-tap is a no-op (#354's chip)
        p.sealUndoStep()
        LatticeSelectableRoles.declare(role, for: ref, siblings: p.latticeSelectableRefs(g),
                                       groupRole: p.latticeEligibleRoles()[gid], in: &p.lattice.selectableRoles)
        seed(role, gid, p)
        p.sealUndoStep()
    }

    /// Every face of the group at once (the chip's / list's "All").
    static func setAll(_ role: LatticeSelectableRole, group gid: UUID, project p: ProjectModel) {
        guard let g = group(gid, p), !isLocked(gid, p) else { return }
        p.sealUndoStep()
        LatticeSelectableRoles.setAll(role, refs: p.latticeSelectableRefs(g), in: &p.lattice.selectableRoles)
        seed(role, gid, p)
        p.sealUndoStep()
    }

    private static func seed(_ role: LatticeSelectableRole, _ gid: UUID, _ p: ProjectModel) {
        if role != .off, p.lattice.groupRoles[gid] == nil {
            p.lattice.groupRoles[gid] = role.regionRole
            if p.lattice.groupDepthMM[gid] == nil { p.lattice.groupDepthMM[gid] = LatticeSlabDepth.clamp(p.lattice.paintDepthMM) }
        }
        if role == .include { p.lattice.enabled = true }
    }

    /// A depth: one face (`ref`) or the whole group (nil — it clears the faces' own numbers, #354's writeGroupDepthMM).
    /// Clamped 1–50 by #354's setters. Not sealed here: a typed value seals around it; a drag seals at its ends.
    static func writeDepth(_ mm: Double, ref: LatticeSelectableRef?, group gid: UUID, project p: ProjectModel,
                           session s: inout FlexibleFacePickSession) {
        guard !isLocked(gid, p) else { return }
        if let ref { p.writeLatticeDepthMM(ref, mm: mm) } else { p.writeGroupDepthMM(gid, mm: mm) }
        s.lastDepth = LatticeSlabDepth.clamp(mm)
    }

    /// A typed depth: one undo step.
    static func setDepth(_ mm: Double, ref: LatticeSelectableRef?, group gid: UUID, project p: ProjectModel,
                         session s: inout FlexibleFacePickSession) {
        guard !isLocked(gid, p) else { return }
        p.sealUndoStep()
        writeDepth(mm, ref: ref, group: gid, project: p, session: &s)
        p.sealUndoStep()
    }

    /// An expand (−50…+50, snapping to 0 — #354's own setter). A typed value is one undo step; in GROUP scope every face.
    static func setExpand(_ mm: Double, ref: LatticeSelectableRef?, group gid: UUID, project p: ProjectModel) {
        guard !isLocked(gid, p), let g = group(gid, p) else { return }
        p.sealUndoStep()
        if let ref { p.writeLatticeExpandMM(ref, mm: mm) } else { for r in liveRefs(g, p) { p.writeLatticeExpandMM(r, mm: mm) } }
        p.sealUndoStep()
    }

    /// Chip M's role line: Anchor and Load exclusive (the lit one re-tapped changes nothing), Protect and Keep clear toggle.
    /// Keep clear on a group with Lattice faces asks first ("Keep clear removes this lattice"). ★ R7-E1 (his answer
    /// 2026-10-18 ~15:50): [Protect] on a Lattice group is LOCKED on — the tap writes nothing (no undo step) and answers
    /// `.locked`, so the chip says "Protect stays on while a face is Lattice".
    @discardableResult
    static func setRole(_ b: FlexibleGroupRoleButton, group gid: UUID, project p: ProjectModel) -> FlexibleRoleAnswer {
        guard group(gid, p) != nil, !isLocked(gid, p) else { return .refused }
        if b == .protect, protectLocked(gid, p) { return .locked }
        let kind = p.force.kind(for: gid)
        if b == .keepClear, p.force.keepClearAffix(for: gid) != .on, hasLattice(gid, p) { return .asksFirst }
        if b == .anchor, kind.isAnchor { return .done }
        if b == .load, kind.isLoad { return .done }
        p.sealUndoStep()
        switch b {
        case .anchor: p.force.makeAnchor(gid)
        case .load: p.force.makeLoad(gid)
        case .protect: p.force.setProtected(gid, !p.force.isProtected(gid))
        case .keepClear: p.force.setKeepClearAffix(gid, p.force.keepClearAffix(for: gid) == .on ? nil : .on)
        }
        p.sealUndoStep()
        return .done
    }

    /// "Keep clear removes this lattice" → [Keep clear].
    static func confirmKeepClear(group gid: UUID, project p: ProjectModel) {
        guard !isLocked(gid, p) else { return }
        p.sealUndoStep()
        p.force.setKeepClearAffix(gid, .on)
        p.sealUndoStep()
    }

    /// State B's [▦ Lattice instead]: Keep clear off, so the group's Lattice faces count again.
    static func latticeInstead(group gid: UUID, project p: ProjectModel) {
        guard !isLocked(gid, p) else { return }
        p.sealUndoStep()
        p.force.setKeepClearAffix(gid, nil)
        p.sealUndoStep()
    }

    static func hasLattice(_ gid: UUID, _ p: ProjectModel) -> Bool {
        guard let g = group(gid, p) else { return false }
        return p.latticeSelectableRefs(g).contains { p.latticeSelectableRole($0, in: gid) == .include }
    }

    /// Rename (Return commits; an empty name keeps the old one).
    static func rename(_ gid: UUID, to name: String, project p: ProjectModel) {
        let t = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, let g = group(gid, p), g.name != t, !isLocked(gid, p) else { return }
        p.sealUndoStep()
        p.selection.rename(gid, to: t)
        p.sealUndoStep()
    }

    /// What a delete took away — enough to put the group back exactly (the message's [Undo]).
    struct Deleted: Equatable {
        let group: SelectionGroup
        let index: Int
        let wasActive: Bool
        let force: ForceModel
        let role: LatticeGroupRole?
        let depth: Double?
        let roles: [String: LatticeSelectableRole]
        let depths: [String: Double]
        let expands: [String: Double]
        let hidden: Bool
    }

    /// The trash, after its confirm: the group goes — here and for Topology — with its lattice entries; ONE undo step
    /// (`project.performUndo()` restores it all). Returns what it took (the message's name and its [Undo]).
    @discardableResult
    /// `sealAfter` false (★ U21, F12): the step stays open — the caller folds the Squish page's carry into it, then seals.
    static func delete(_ gid: UUID, project p: ProjectModel, sealAfter: Bool = true) -> Deleted? {
        guard let idx = p.selection.groups.firstIndex(where: { $0.id == gid }), !isLocked(gid, p) else { return nil }
        let g = p.selection.groups[idx]
        let refs = p.latticeSelectableRefs(g)
        let keys = Set(refs.map(\.key))
        let taken = Deleted(group: g, index: idx, wasActive: p.selection.activeGroupID == gid, force: p.force,
                            role: p.lattice.groupRoles[gid], depth: p.lattice.groupDepthMM[gid],
                            roles: p.lattice.selectableRoles.filter { keys.contains($0.key) },
                            depths: p.lattice.selectableDepthMM.filter { keys.contains($0.key) },
                            expands: p.lattice.selectableExpandMM.filter { keys.contains($0.key) },
                            hidden: p.groupView.isHidden(gid))
        p.sealUndoStep()
        // WorkspacePlaceholder's private removeGroup, step for step
        p.selection.remove(gid)
        p.force.clearKind(gid)
        p.force.sync(groups: p.selection.groups)
        p.groupView.forget(gid)
        // …and its lattice entries
        p.lattice.groupRoles[gid] = nil
        p.lattice.groupDepthMM[gid] = nil
        for r in refs {
            p.lattice.selectableRoles.removeValue(forKey: r.key)
            p.lattice.selectableDepthMM.removeValue(forKey: r.key)
            p.lattice.selectableExpandMM.removeValue(forKey: r.key)
        }
        // ★ U21 batch I (I2): its lattices' links are NOT touched (they go dormant; an Undo brings them back) — red control only
        if controlTrashPrunesLinks, var fs = p.lattice.flexible, let l = fs.links {
            let kept = l.filter { !keys.contains($0.lattice) }
            fs.links = kept.isEmpty ? nil : kept
            p.lattice.flexible = fs
        }
        if sealAfter { p.sealUndoStep() }
        return taken
    }

    /// The message's [Undo]: the deleted group EXACTLY back — its place in the list, its faces and regions, its role, load,
    /// Protect and Keep clear, its lattice entries — as ONE undoable step. (Not `performUndo()`: the stage's own background
    /// writes after a delete — a re-opened scene's section numbers — are steps too, and an Undo would take those instead.)
    static func restore(_ d: Deleted, project p: ProjectModel) {
        guard !p.selection.groups.contains(where: { $0.id == d.group.id }) else { return }
        p.sealUndoStep()
        var groups = p.selection.groups
        groups.insert(d.group, at: min(d.index, groups.count))
        p.selection.restore(groups: groups, active: d.wasActive ? d.group.id : p.selection.activeGroupID)
        p.force.restoreEntries(for: [d.group.id], from: d.force)
        p.lattice.groupRoles[d.group.id] = d.role
        p.lattice.groupDepthMM[d.group.id] = d.depth
        for (k, v) in d.roles { p.lattice.selectableRoles[k] = v }
        for (k, v) in d.depths { p.lattice.selectableDepthMM[k] = v }
        for (k, v) in d.expands { p.lattice.selectableExpandMM[k] = v }
        if d.hidden, !p.groupView.isHidden(d.group.id) { p.groupView.toggleHidden(d.group.id) }
        p.sealUndoStep()
    }
}

// MARK: - ★ U21 batch I (I2): the Attach tool's writes — each ONE sealed undo step, written inside the tap

extension FlexibleFaceCommits {
    /// ★ RED CONTROL (I2 test 9 / hosted d): no seal BEFORE the write — the link folds into the edit before it.
    static var controlUnsealedLinkWrite = false
    /// ★ RED CONTROL (I2 test 10): the suggestion links on open (nothing should be set until he taps).
    static var controlAutoApplySuggestion = false
    /// ★ RED CONTROL (I2 test 12): the last link removed stores [] (the re-encode carries "links":[]).
    static var controlLinksEmptyArray = false
    /// ★ RED CONTROL (I2 test 14): the group trash removes its links in the same write (the toast's [Undo] cannot bring them back).
    static var controlTrashPrunesLinks = false

    private static func writeLinks(_ p: ProjectModel, _ change: (inout [FlexibleLatticeLink]) -> Void) -> Bool {
        guard var s = p.lattice.flexible else { return false }
        var links = s.links ?? []
        let before = links
        change(&links)
        guard links != before else { return false }
        if !controlUnsealedLinkWrite { p.sealUndoStep() }
        s.links = links.isEmpty && !controlLinksEmptyArray ? nil : links   // ★ the last link removed stores nil, never []
        p.lattice.flexible = s
        p.sealUndoStep()
        return true
    }

    /// One link made by hand: one step. A link that exists already is not added twice.
    @discardableResult
    static func addLink(lattice: String, wall: String, target: String, project p: ProjectModel) -> Bool {
        writeLinks(p) { l in
            guard !l.contains(where: { $0.lattice == lattice && $0.wall == wall && $0.target == target }) else { return }
            l.append(FlexibleLatticeLink(lattice: lattice, wall: wall, target: target))
        }
    }

    /// The trash, after its in-place confirm: one step.
    @discardableResult
    static func removeLink(id: UUID, project p: ProjectModel) -> Bool {
        writeLinks(p) { l in l.removeAll { $0.id == id } }
    }

    /// ★ HIS ONE-TAP SUGGESTION: every missing side → wall link of `lattice` in ONE step (one tap = one Undo). Returns how many.
    @discardableResult
    static func addSuggested(lattice: String, sides: [String], project p: ProjectModel) -> Int {
        var added = 0
        _ = writeLinks(p) { l in
            for w in sides where !l.contains(where: { $0.lattice == lattice && $0.wall == w && $0.target == "wall" }) {
                l.append(FlexibleLatticeLink(lattice: lattice, wall: w, target: "wall"))
                added += 1
            }
        }
        return added
    }
}
