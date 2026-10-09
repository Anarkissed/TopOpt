// FlexibleGroupMigration — the Settings groups LINKED to the main page's at PROJECT RESTORE (task
// 2026-09-29-flexible-screens, round 6 item 4; hook H18, one line in ProjectModel.init(restoring:) after
// refreshFaceRegionDrift() and before seedUndoBaseline()).
//
// ★ WHY AT RESTORE: Topology and Optimize see the hands without a Flexible visit; the link is part of the undo baseline
// (never an undo step, and Undo never re-runs it); it is already in Settings' opened snapshot, so its first Exit reads
// "Exit". ★ PURE AND IDEMPOTENT: it reads the selection, the roles, the regions, the mesh and `lattice.flexible`, and
// writes the same three values through FlexibleGroupWorld (#354's public APIs only) — a second run finds every face
// linked and changes nothing. A project with no Flexible stage is never touched.
// ★ WHAT IT DOES (FlexibleGroupWorld's order, spec §4): each squeeze group's pressed faces, in order, are linked to their
// hand — the Load group that presses them; a role-less group holding exactly faces Settings presses on that side
// (Group C on his pad); the squeeze group's hand on the face's side; else a new hand at the face's OWN weight — and
// each resting face to an Anchor (the one that holds it; a role-less group holding only faces Settings rests — "sides"
// on his 0004; the first Anchor; a new "Rests"). The faces are then re-read from the groups (the adopt every open runs).
// ★ IT NEVER INVENTS A WEIGHT: a new hand presses with the face's own; a weight moves only where his force answer moves
// it — two faces on ONE side of one squeeze group become one hand and SHARE its weight by area (his 0004: "10 kg on
// Top A + Top B = 5 + 5"). Each face's line in `report` says what it was linked to and what moved.
// ★ A ONE-TIME LINE ("Groups 2 and 3 are on the main page now") is kept per project and shown by the main page on
// the project's first Flexible open (FlexibleMainStage.apply), then forgotten.

import Foundation

@MainActor
public enum FlexibleGroupMigration {
    /// RED CONTROL (tests only): restore WITHOUT the migration — his img4 as he saw it.
    public static var controlSkip = false

    /// H18: link the project's Settings groups to its main-page groups (pure on its values, idempotent).
    public static func migrate(_ project: ProjectModel) {
        guard !controlSkip, let stored = project.lattice.flexible, let mesh = project.viewerMesh else { return }
        let regions = FlexibleRegions(model: project.faceRegions, mesh: mesh)
        let x = FlexibleMainPageLoads.Expander(faceRegions: project.faceRegions, mesh: mesh, regions: regions)
        let out = linked(selection: project.selection, force: project.force, flexible: stored, x: x,
                         latticeRoles: Set(project.lattice.groupRoles.keys))
        if out.selection != project.selection { project.selection = out.selection }
        if out.force != project.force { project.force = out.force }
        if out.flexible != stored { project.lattice.flexible = out.flexible }
        if !out.lines.isEmpty { reports[project.id] = out.lines }   // (a second run changes nothing and keeps the first's)
        if let n = out.note { notes[project.id] = n }
    }

    /// The linked values and what changed — the pure core of `migrate`.
    static func linked(selection: SelectionModel, force: ForceModel, flexible: FlexibleStageSettings,
                       x: FlexibleMainPageLoads.Expander, latticeRoles: Set<UUID>)
        -> (selection: SelectionModel, force: ForceModel, flexible: FlexibleStageSettings, lines: [String], note: String?) {
        var w = FlexibleGroupWorld(selection: selection, force: force, flexible: flexible, x: x, latticeRoles: latticeRoles)
        let gone = Set(flexible.removedRegions ?? []).union(flexible.pressRegions.subtracting(flexible.faces.map(\.faceRegionID)))
        for g in FlexibleSqueezeGroups.groups(flexible) {
            for r in g.regions where !gone.contains(r) {
                guard let f = w.flexible.face(r), f.isLoaded else { continue }
                w.linkPressed(r, squeeze: g.id, kg: f.weightKg)
            }
        }
        for f in flexible.faces where !f.isLoaded && !gone.contains(f.faceRegionID) { w.linkResting(f.faceRegionID) }
        w.readopt()
        w.renameHands()
        let (lines, note) = report(before: (selection, force, flexible), after: w)
        return (w.selection, w.force, w.flexible, lines, note)
    }

    // MARK: what changed, per face and per main-page group

    static func roleText(_ k: GroupKind, _ f: ForceModel) -> String {
        switch k {
        case .anchor: return "Anchor"
        case let .load(d, kg): return "\(d.rawValue) \(FlexibleRowCopy.weightText(kg, .kg))"
        case .pending: return "Pending"
        case .clearance: return "Keep clear"
        }
    }

    static func report(before b: (selection: SelectionModel, force: ForceModel, flexible: FlexibleStageSettings),
                       after w: FlexibleGroupWorld) -> (lines: [String], note: String?) {
        var lines: [String] = []
        func gname(_ id: UUID?, _ s: SelectionModel) -> String? { id.flatMap { i in s.groups.first { $0.id == i }?.name } }
        let groupsAfter = FlexibleSqueezeGroups.groups(w.flexible)
        func number(_ f: FlexibleFaceSettings, _ s: FlexibleStageSettings) -> Int? {
            f.isLoaded ? FlexibleSqueezeGroups.groups(s).first { $0.regions.contains(f.faceRegionID) }?.number : nil
        }
        var linkedGroups = Set<Int>(), restsLinked = false
        for f in w.flexible.faces {
            let r = f.faceRegionID, n = w.name(r)
            let was = b.flexible.face(r)
            var parts: [String] = []
            let role = f.isLoaded ? "pressed \(FlexibleRowCopy.weightText(f.weightKg, .kg))" : "rests"
            if let was {
                if was.weightFrom != f.weightFrom {
                    let to = gname(f.weightFrom, w.selection) ?? "nothing"
                    let made = f.weightFrom.map { id in !b.selection.groups.contains { $0.id == id } } ?? false
                    parts.append("linked to \u{201C}\(to)\u{201D}\(made ? " (new on the main page)" : "")")
                    if f.isLoaded, let k = number(f, w.flexible) { linkedGroups.insert(k) } else if !f.isLoaded { restsLinked = true }
                }
                if abs(was.weightKg - f.weightKg) > 1e-9, f.isLoaded {
                    let mates = w.flexible.loadedFaces.filter { $0.weightFrom == f.weightFrom && $0.faceRegionID != r }.map { w.name($0.faceRegionID) }
                    parts.append("\(FlexibleRowCopy.weightText(was.weightKg, .kg)) → \(FlexibleRowCopy.weightText(f.weightKg, .kg))"
                                 + (mates.isEmpty ? "" : " (one side: shares \(gname(f.weightFrom, w.selection) ?? "its hand")'s weight with \(mates.joined(separator: " + ")) by area)"))
                }
                let sb = number(was, b.flexible), sa = number(f, w.flexible)
                if sb != sa, f.isLoaded { parts.append("squeeze group \(sb.map(String.init) ?? "-") → \(sa.map(String.init) ?? "-")") }
            } else {
                parts.append("new in Settings: \(f.isLoaded ? "pressed" : "rests") by \u{201C}\(gname(f.weightFrom, w.selection) ?? "?")\u{201D}"
                             + (f.isLoaded ? ", squeeze group \(number(f, w.flexible).map(String.init) ?? "-")" : ""))
            }
            lines.append("\(n) (\(role)): " + (parts.isEmpty ? "unchanged" : parts.joined(separator: "; ")))
        }
        for f in b.flexible.faces where w.flexible.face(f.faceRegionID) == nil {
            lines.append("\(w.name(f.faceRegionID)): no longer in Settings")
        }
        // the main page
        for g in w.selection.groups {
            let k = w.force.kind(for: g.id), kind = roleText(k, w.force)
            guard let was = b.selection.groups.first(where: { $0.id == g.id }) else {
                lines.append("main page + \u{201C}\(g.name)\u{201D} \(kind) on \(w.members(g).map(w.name).joined(separator: " + "))")
                continue
            }
            var parts: [String] = []
            let kb = roleText(b.force.kind(for: g.id), b.force)
            if kb != kind { parts.append("\(kb) → \(kind)") }
            if was.name != g.name { parts.append("named \u{201C}\(g.name)\u{201D}") }
            let mb = Set(w.x.members(was)), ma = Set(w.members(g))
            let gained = ma.subtracting(mb).sorted(), lost = mb.subtracting(ma).sorted()
            if !gained.isEmpty { parts.append("+ \(gained.map(w.name).joined(separator: " + "))") }
            if !lost.isEmpty { parts.append("− \(lost.map(w.name).joined(separator: " + "))") }
            if !parts.isEmpty { lines.append("main page \u{201C}\(was.name)\u{201D}: " + parts.joined(separator: "; ")) }
        }
        for g in b.selection.groups where !w.selection.groups.contains(where: { $0.id == g.id }) {
            lines.append("main page − \u{201C}\(g.name)\u{201D} (emptied)")
        }
        _ = groupsAfter
        let changed = lines.contains { !$0.hasSuffix(": unchanged") }
        guard changed else { return ([], nil) }
        let ns = linkedGroups.sorted()
        let note: String?
        switch ns.count {
        case 0: note = restsLinked ? "Rests are linked to the main page now" : nil
        case 1: note = "Group \(ns[0]) is on the main page now"
        default: note = "Groups " + ns.dropLast().map(String.init).joined(separator: ", ") + " and \(ns.last!) are on the main page now"
        }
        return (lines, note)
    }

    /// What the migration did to a project, per face (one line each) — kept for the handoff's table.
    public static func report(for id: UUID) -> [String] { reports[id] ?? [] }
    static var reports: [UUID: [String]] = [:]

    /// The ONE line the main page shows on the project's first Flexible open (then forgotten).
    public static func takeNote(for id: UUID) -> String? { notes.removeValue(forKey: id) }
    static var notes: [UUID: String] = [:]
}
