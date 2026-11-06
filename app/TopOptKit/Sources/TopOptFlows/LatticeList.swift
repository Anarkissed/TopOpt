// LatticeList.swift — B6 slice 1 (approved design 2026-11-02, ledger notes 22, 23; plan.md §B6).
//
// His words: "Does not allow for a face to be part of multiple groups. This needs to be fixed." and "the 'Selections'
// should separate the groups made from Topology with the ones going to be made here". The Lattice stage gets its OWN
// groups (`LatticeSettings.latticeList`): a face can be in its Topology groups (its role in the run) and in lattice groups
// at once. Everything that reads where the lattice goes reads `latticeGroups`; Topology's job never sees the list.
//
// · Structural / Aesthetic: the list. An older project is migrated on open — each group whose lattice role today's run
//   uses becomes a lattice group with the SAME id, name, colour and members, in the same order, so every per-group map
//   (roles, depths, densities, primitives) still resolves and the lattice job is byte-identical. A role the run drops
//   today (its group has no Topology role) stays dropped.
// · Flexible (#362, until B9): Topology's groups, exactly as today and in today's order.
// · A lattice group needs no Topology role: its own role (Lattice · No lattice, and Protect skin in B6's role picker) is
//   the declaration (notes 24, 27, Q5). Keep clear still blocks it.

import Foundation

extension ProjectModel {
    /// Structural / Aesthetic use the lattice list; Flexible stays on Topology's groups (#362 moves it in B9).
    public var usesLatticeList: Bool { lattice.flexible == nil }

    /// The groups the Lattice stage edits — its own list, or (Flexible) Topology's. Until the list is made (a project
    /// never opened since B6, or built in memory) it reads as today's lattice groups — the migration's own copies — so
    /// nothing moves; the first edit through here makes it.
    public var latticeList: SelectionModel {
        get {
            guard usesLatticeList else { return selection }
            if let l = lattice.latticeList { return l }
            let used = topologyGatedLatticeRoles()
            return .latticeList(adopting: selection.groups.filter { used[$0.id] != nil })
        }
        set { if usesLatticeList { lattice.latticeList = newValue } else { selection = newValue } }
    }

    /// Where the lattice goes, in order: the list's groups (Flexible: every Topology group, as today).
    public var latticeGroups: [SelectionGroup] { latticeList.groups }

    /// ★ B7 (E3): the lattice AREAS, in order — the groups that lattice something (an include in them). One list for the
    /// Lattice page's tabs (`WorkspacePlaceholder.latticeRegionTabNames`) and each tab's own grade (`areaGrading`).
    public var latticeAreaGroups: [SelectionGroup] {
        latticeGroups.filter { g in latticeSelectableRefs(g).contains { latticeSelectableRole($0, in: g.id) == .include } }
    }

    /// Every group whose per-group state `force` must keep — Topology's and the lattice list's (a migrated lattice group
    /// shares its id with its Topology twin, so the union keeps one entry).
    public var forceKeptGroups: [SelectionGroup] {
        usesLatticeList ? selection.groups + (lattice.latticeList?.groups ?? []) : selection.groups
    }

    /// `force.sync` over both lists: a lattice group's primitives and depth handles survive an edit on Topology's list.
    public func syncForceGroups() { force.sync(groups: forceKeptGroups) }

    /// ★ A TAP ON THE LATTICE STAGE (note 23c, the Topology panel closed): it grows or starts a LATTICE group — a face that
    /// is in Topology's groups stays there (note 22). Today's router (LatticeLibraryTap: a face a lattice group holds selects
    /// that group, a free face grows the active one or starts "Group N"), over the lattice list. Returns that group.
    @discardableResult
    public func latticeStageTap(face: FaceID, loop: [FaceID]) -> UUID? {
        var l = latticeList
        // ★ B6 s3a: a face never joins a zone (a zone is a shape, no faces) — with a zone picked, the tap starts its own group
        if let a = l.activeGroupID, lattice.zoneGroups.contains(a) { l.clearActive() }
        let gid = LatticeLibraryTap.route(faceID: face, loop: loop, selection: &l)
        latticeList = l
        syncForceGroups()
        return gid
    }

    /// ★ THE MIGRATION (plan.md §B6, risk 1). An older Structural / Aesthetic project keeps its lattice where it was: each
    /// group whose role today's run uses (`LatticeFaceRoleGate` over Topology's roles) becomes a lattice group — same id,
    /// name, colour, faces and regions, Topology's order. The Topology group stays as it is. Runs once: the list is then
    /// saved, empty or not, and a Flexible project is never migrated here.
    public func adoptLatticeListIfNeeded() {
        guard usesLatticeList, lattice.latticeList == nil else { return }
        let used = topologyGatedLatticeRoles()
        guard !used.isEmpty else { return }
        lattice.latticeList = .latticeList(adopting: selection.groups.filter { used[$0.id] != nil })
    }

    /// Today's gate (task 2026-08-12 §1a/§1d): a lattice role counts only on a group with a Topology role and no Keep clear.
    /// The migration's filter and Flexible's emission gate.
    func topologyGatedLatticeRoles() -> [UUID: LatticeGroupRole] {
        var byID: [UUID: SelectionGroup] = [:]
        for g in selection.groups { byID[g.id] = g }
        return LatticeFaceRoleGate.pruned(roles: lattice.groupRoles) { id in
            guard byID[id] != nil else { return false }
            return LatticeFaceRoleGate.allowed(
                kind: force.kind(for: id), protected: force.isProtected(id),
                // EXPLICIT only — see LatticeFaceRoleGate.block.
                keepClearOn: force.keepClearAffix(for: id) == .on)
        }
    }

    /// The lattice list's gate: a lattice group's own role is its declaration; Keep clear (on a migrated group's Topology
    /// twin) still blocks it.
    func latticeListRoles() -> [UUID: LatticeGroupRole] {
        let ids = Set(latticeGroups.map(\.id))
        return LatticeFaceRoleGate.pruned(roles: lattice.groupRoles) { id in
            ids.contains(id) && force.keepClearAffix(for: id) != .on
        }
    }
}
