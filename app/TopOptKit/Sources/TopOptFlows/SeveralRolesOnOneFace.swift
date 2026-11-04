// SeveralRolesOnOneFace — ONE FACE, SEVERAL GROUPS, on the Topology page (the owner's request of 2026-10-25, relayed by the
// reviewer at 03:16; PR #362, app side only). The hooks H55a–H55j in #354's files call into this file; the table is in
// SeveralRolesOnOneFaceTests (each pinned once, with a red control).
//
// BEFORE: a face belonged to ONE group, so it had ONE role — Keep clear OR Protect OR Load OR Anchor — and a tap on a face a
// group held re-selected that group, even a HIDDEN one, so a second selection on it was refused.
// NOW:
//   * a face may sit in several groups. Each group sends it in its OWN job list, exactly as core reads it
//     (anchor_face_ids, groups[].face_ids, face_protections, clearances) — nothing new reaches the job. Core's facts (TO-core,
//     checked): the same face_id may be in face_protections AND clearances (the protection's solid wins); a Keep clear never
//     voids the part's own material.
//   * LOAD + ANCHOR on one face stays REFUSED, with one plain line: core does not refuse it, but it is WRONG — the load
//     re-tags the voxels and the anchor is silently dropped.
//   * a HIDDEN group never blocks: a tap on a face only hidden groups hold is a tap on a free face (it starts or grows the
//     selection; the hidden group keeps the face). The eye stays view-only: a hidden group still runs, so it still counts
//     for the Load + Anchor refusal.
//   * every role a face has is shown: a badge on the part, at each set of faces two or more groups hold, listing each role
//     (not just the tint of the group picked last).
// THE TAP (WorkspaceTap.route, H55c): a face in the ACTIVE group → deselect (as before). A face another group holds while a
// group is ACTIVE → it JOINS the active group too. Nothing active → the face's first VISIBLE group is re-selected (as before);
// only hidden groups hold it → a new selection starts with it.

import Foundation
import SwiftUI
import TopOptDesign

public enum SeveralRoles {

    /// The one plain line for Load + Anchor on the same face.
    public static let anchorAndLoadLine = "A face can\u{2019}t be both held and loaded \u{2014} pick one."

    /// A role a group gives its faces on the Topology page.
    public enum Role: String, CaseIterable, Sendable {
        case anchor, load, keepClear, protect
        public var title: String {
            switch self {
            case .anchor: return "Anchor"
            case .load: return "Load"
            case .keepClear: return "Keep clear"
            case .protect: return "Protect"
            }
        }
        /// Today's glyph for the role (the face chip's).
        public var symbol: String {
            switch self {
            case .anchor: return "lock.fill"
            case .load: return "arrow.down"
            case .keepClear: return "nosign"
            case .protect: return "shield.lefthalf.filled"
            }
        }
    }

    // MARK: the tap

    /// The group a tap on `face` belongs to: the ACTIVE group when it holds the face, else the first VISIBLE group that does
    /// (a hidden group never claims a tap). nil = a free face.
    public static func owner(of face: FaceID, in s: SelectionModel, hidden: Set<UUID>) -> SelectionGroup? {
        if let a = s.activeGroup, a.faces.contains(face) { return a }
        return s.groups(forFace: face).first { !hidden.contains($0.id) }
    }

    /// A face another group holds, tapped while `active` is being built: it JOINS the active group too — with the members of
    /// its loop the same groups hold (a bore's whole loop) — unless that puts a face in an anchor AND a load (the line).
    @discardableResult
    public static func join(_ face: FaceID, loop: [FaceID], into active: UUID, selection s: inout SelectionModel,
                            force: ForceModel) -> String? {
        let holders = Set(s.groups(forFace: face).map(\.id))
        let mine = Set(s.groups.first { $0.id == active }?.faces ?? [])
        var members = loop.filter { !mine.contains($0) && Set(s.groups(forFace: $0).map(\.id)) == holders }
        if !members.contains(face) { members.insert(face, at: 0) }
        if let r = role(of: force.kind(for: active)), clashes(faces: members, as: r, in: active, selection: s, force: force) {
            return anchorAndLoadLine
        }
        s.joinFaces(members, to: active)
        return nil
    }

    /// Free faces some HIDDEN group holds: they start (or grow) the selection and stay in the hidden group.
    @discardableResult
    public static func joinFree(_ faces: [FaceID], selection s: inout SelectionModel, force: ForceModel) -> String? {
        if s.activeGroup == nil { s.addGroup() }
        guard let active = s.activeGroupID else { return nil }
        if let r = role(of: force.kind(for: active)), clashes(faces: faces, as: r, in: active, selection: s, force: force) {
            return anchorAndLoadLine
        }
        s.joinFaces(faces, to: active)
        return nil
    }

    // MARK: Load + Anchor, refused

    /// The role a group KIND gives (anchor / load); nil for pending (no role yet — nothing to refuse).
    static func role(of kind: GroupKind) -> Role? { kind.isAnchor ? .anchor : kind.isLoad ? .load : nil }

    /// Would `faces`, held by `group` as `role`, sit in an anchor group AND a load group? Every group counts, hidden ones too
    /// (the eye is view-only: a hidden group still runs).
    public static func clashes(faces: [FaceID], as role: Role, in group: UUID, selection s: SelectionModel,
                               force: ForceModel) -> Bool {
        guard role == .anchor || role == .load else { return false }
        let fs = Set(faces)
        return s.groups.contains { h in
            guard h.id != group, !fs.isDisjoint(with: h.faces) else { return false }
            let k = force.kind(for: h.id)
            return role == .anchor ? k.isLoad : k.isAnchor
        }
    }

    /// The face chip's Anchor / Load on `group`: the plain line when it would put one of its faces in an anchor AND a load.
    public static func refusal(committing group: UUID, as role: Role, selection s: SelectionModel, force: ForceModel) -> String? {
        guard let g = s.groups.first(where: { $0.id == group }) else { return nil }
        return clashes(faces: g.faces, as: role, in: group, selection: s, force: force) ? anchorAndLoadLine : nil
    }

    // MARK: every role a face has

    /// The centre of `faces` (the mean of their centroids, model space), or nil — where their badge sits.
    public static func centre(of faces: [FaceID], in mesh: ViewerMesh?) -> SIMD3<Float>? {
        let cs = faces.compactMap { mesh?.faceCentroid($0) }
        return cs.isEmpty ? nil : cs.reduce(.zero, +) / Float(cs.count)
    }

    /// Every role `g` gives its faces (in Role order). `keepClearOn` is the project's effective keep-clear (it needs the mesh).
    public static func roles(of g: SelectionGroup, force: ForceModel, keepClearOn: (SelectionGroup) -> Bool) -> [Role] {
        var r: [Role] = []
        let k = force.kind(for: g.id)
        if k.isAnchor { r.append(.anchor) }
        if k.isLoad { r.append(.load) }
        if keepClearOn(g) { r.append(.keepClear) }
        if force.isProtected(g.id) { r.append(.protect) }
        return r
    }

    /// One badge: the roles a set of faces carries, and those faces.
    public struct Badge: Equatable, Sendable {
        public let roles: [Role]
        public let faces: [FaceID]
    }

    /// ★ EVERY ROLE A FACE HAS: the faces two or more VISIBLE groups hold, carrying two or more roles between them, clustered
    /// by that role set — one badge per cluster, each role once, in Role order. A face one group holds draws no badge (its
    /// group's tint and affixes already say it), so a project with no shared face draws exactly what it drew.
    public static func badges(selection s: SelectionModel, force: ForceModel, hidden: Set<UUID>,
                              keepClearOn: (SelectionGroup) -> Bool) -> [Badge] {
        var roles: [FaceID: Set<Role>] = [:], holders: [FaceID: Int] = [:], order: [FaceID] = []
        for g in s.groups where !hidden.contains(g.id) {
            let rs = Self.roles(of: g, force: force, keepClearOn: keepClearOn)
            guard !rs.isEmpty else { continue }
            for f in g.faces {
                if holders[f] == nil { order.append(f) }
                holders[f, default: 0] += 1
                roles[f, default: []].formUnion(rs)
            }
        }
        var clusters: [[Role]: [FaceID]] = [:], keys: [[Role]] = []
        for f in order where (holders[f] ?? 0) >= 2 {
            let rs = Role.allCases.filter { roles[f]?.contains($0) == true }
            guard rs.count >= 2 else { continue }
            if clusters[rs] == nil { keys.append(rs) }
            clusters[rs, default: []].append(f)
        }
        return keys.map { Badge(roles: $0, faces: clusters[$0] ?? []) }
    }
}

/// The badge on the part: each role's glyph, in its colour, on one capsule (read by VoiceOver as the roles' names).
public struct SeveralRolesBadge: View {
    public let roles: [SeveralRoles.Role]
    public init(roles: [SeveralRoles.Role]) { self.roles = roles }

    static func tint(_ r: SeveralRoles.Role) -> Color {
        switch r {
        case .anchor: return DS.Color.accentGreen.color
        case .load: return DS.Color.textPrimary.color
        case .keepClear: return WorkspacePlaceholder.clearanceTint
        case .protect: return WorkspacePlaceholder.protectTint
        }
    }

    public var body: some View {
        HStack(spacing: 4) {
            ForEach(roles, id: \.self) { r in
                Image(systemName: r.symbol)
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Self.tint(r))
            }
        }
        .padding(.vertical, 4).padding(.horizontal, 7)
        .background(Capsule().fill(DS.Surface.panel.color)
            .overlay(Capsule().strokeBorder(DS.Color.strokePanel.color, lineWidth: 1)))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(roles.map(\.title).joined(separator: ", "))
        .accessibilityIdentifier("several-roles-badge")
    }
}
