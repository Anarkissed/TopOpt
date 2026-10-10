// FlexibleGroupMigration — the Settings groups LINKED to the main page's at PROJECT RESTORE (task
// 2026-09-29-flexible-screens, round 6 item 4; hook H18, one line in ProjectModel.init(restoring:) after
// refreshFaceRegionDrift() and before seedUndoBaseline()).
//
// ★ WHY AT RESTORE: Topology and Optimize see the hands without a Flexible visit; the link is part of the undo baseline
// (never an undo step, and Undo never re-runs it); it is already in Settings' opened snapshot, so its first Exit reads
// "Exit". ★ PURE: it reads the selection, the roles, the regions, the mesh and `lattice.flexible`, and writes the same
// three values through FlexibleGroupWorld (#354's public APIs only). A project with no Flexible stage is never touched.
// ★ ONCE PER PROJECT (the item 4 verification's blocker): it records itself in `FlexibleStageSettings.groupLink`, and a
// later restore never links again — so a main-page edit (a hand deleted, a role cleared, a face moved) is never undone
// by the next open; from then on the two pages follow each other live (FlexibleGroupSync, FlexibleGroupWatch).
// ★ WHAT IT DOES (FlexibleGroupWorld's order, spec §4): each squeeze group's pressed faces, in order, are linked to their
// hand — the Load group that presses them; a role-less group holding exactly faces Settings presses on that side
// (Group C on his pad); the squeeze group's hand on the face's side; else a new hand at the face's OWN weight — and
// each resting face to an Anchor (the one that holds it; a role-less group holding only faces Settings rests — "sides"
// on his 0004; the first Anchor; a new "Rests"). The faces are then re-read from the groups (the adopt every open runs).
// ★ NOTHING HE SET IS TAKEN APART (the verification's second blocker; `FlexibleGroupWorld.atRestore`): no face leaves a
// group that holds it with the other role (round 3 let Settings press a face an Anchor holds, or rest one a Load
// presses — the restore had deleted his only Anchor or his gravity Load), a keep-clear role, a lattice role or a region
// that cannot split; no face joins a hand carrying an affix or a lattice role (his 0004's Top B is NOT put under Top's
// 4 mm lattice — his call); no group is removed. Such a face stays as saved and is reported; a disagreement is asked in
// Settings (its Pending tab and the face's card). A face leaving a role-less group carrying Protect / keep-clear takes
// it to a hand of its own (the M2 stand's face 2 keeps Group C's Protect).
// ★ IT NEVER INVENTS A WEIGHT: a new hand presses with the face's own; nothing joins at restore, so no weight moves.
// ★ ONE UNIT: where Settings shows kg or lb and the main page the other, Settings takes the main page's (the force is one
// number on both pages); from then on either toggle switches both (FlexibleGroupWatch).
// ★ THE ONE-TIME LINE ("Groups 2 and 3 are on the main page now") is SAVED with the record and shown on the project's
// first Flexible open, wherever the project opened; until then each main-page row it made or changed says so on every
// stage (H17: "Linked from Flexible Settings"). That it was shown is kept per record outside the project (showing it is
// never an undo step).

import Foundation

/// ★ (item 4 verification) the restore's link, recorded once per project (FlexibleStageSettings.groupLink).
public struct FlexibleGroupLinkRecord: Codable, Equatable, Hashable, Sendable {
    /// 1 — round 6 item 4's link.
    public var version: Int
    /// The record's own id: the "shown" flag of its line is kept per id, outside the project.
    public var id: UUID
    /// The one-time line; nil: nothing to say.
    public var note: String?
    /// The main-page groups it made or changed (H17's caption off the Flexible stage, until the line was shown).
    public var groups: [UUID]?
    public init(version: Int = 1, id: UUID = UUID(), note: String?, groups: [UUID]?) {
        self.version = version; self.id = id; self.note = note; self.groups = groups
    }
}

@MainActor
public enum FlexibleGroupMigration {
    /// RED CONTROL (tests only): restore WITHOUT the migration — his img4 as he saw it.
    public static var controlSkip = false

    /// H18: link the project's Settings groups to its main-page groups — once (see the file comment).
    public static func migrate(_ project: ProjectModel) {
        guard !controlSkip, let stored = project.lattice.flexible, let mesh = project.viewerMesh else { return }
        let eager = FlexibleGroupLinks.controlEagerRestore
        guard stored.groupLink == nil || eager else { reports[project.id] = nil; return }   // ★ once per project
        let regions = FlexibleRegions(model: project.faceRegions, mesh: mesh)
        let x = FlexibleMainPageLoads.Expander(faceRegions: project.faceRegions, mesh: mesh, regions: regions)
        var out = linked(selection: project.selection, force: project.force, flexible: stored, x: x,
                         latticeRoles: Set(project.lattice.groupRoles.keys))
        // one unit on both pages (kg / lb): the main page's
        let main: FlexibleWeightUnit = project.force.unit == .kg ? .kg : .lb
        let mine = FlexibleWeightUnit(stored: out.flexible.weightUnit)
        if !eager, mine != main, mine == .kg || mine == .lb {
            out.flexible.weightUnit = main == .kg ? nil : main.rawValue
            out.lines.append("Settings' weights in \(main.label) now (the main page's unit; either toggle switches both)")
        }
        out.flexible.groupLink = FlexibleGroupLinkRecord(note: out.note, groups: out.groups.isEmpty ? nil : out.groups)
        if out.selection != project.selection { project.selection = out.selection }
        if out.force != project.force { project.force = out.force }
        if out.flexible != stored { project.lattice.flexible = out.flexible }
        reports[project.id] = out.lines
    }

    /// The linked values and what changed — the pure core of `migrate` (`atRestore`: nothing he set is taken apart).
    static func linked(selection: SelectionModel, force: ForceModel, flexible: FlexibleStageSettings,
                       x: FlexibleMainPageLoads.Expander, latticeRoles: Set<UUID>, atRestore: Bool = true)
        -> (selection: SelectionModel, force: ForceModel, flexible: FlexibleStageSettings, lines: [String], note: String?, groups: [UUID]) {
        var w = FlexibleGroupWorld(selection: selection, force: force, flexible: flexible, x: x, latticeRoles: latticeRoles)
        w.atRestore = atRestore
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
        let (lines, note, groups) = report(before: (selection, force, flexible), after: w)
        return (w.selection, w.force, w.flexible, lines, note, groups)
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
                       after w: FlexibleGroupWorld) -> (lines: [String], note: String?, groups: [UUID]) {
        var lines: [String] = []
        func gname(_ id: UUID?, _ s: SelectionModel) -> String? { id.flatMap { i in s.groups.first { $0.id == i }?.name } }
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
                if let why = w.held[r] { parts.append("KEPT AS SAVED: \(why)") }
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
        var touched: [UUID] = []
        for g in w.selection.groups {
            let k = w.force.kind(for: g.id), kind = roleText(k, w.force)
            guard let was = b.selection.groups.first(where: { $0.id == g.id }) else {
                lines.append("main page + \u{201C}\(g.name)\u{201D} \(kind)\(w.force.isProtected(g.id) ? " +Protect" : "") on \(w.members(g).map(w.name).joined(separator: " + "))")
                touched.append(g.id)
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
            if !parts.isEmpty {
                lines.append("main page \u{201C}\(was.name)\u{201D}: " + parts.joined(separator: "; "))
                touched.append(g.id)
            }
        }
        for g in b.selection.groups where !w.selection.groups.contains(where: { $0.id == g.id }) {
            lines.append("main page − \u{201C}\(g.name)\u{201D} (emptied)")
        }
        // the faces the two pages disagree on, as saved (settled in Settings, never here)
        let l = w.loads()
        let disagree = w.flexible.faces.filter { f in
            guard f.weightFrom == nil, let e = l.entry(f.faceRegionID), e.role != .ask else { return false }
            return (e.role == .pressed) != f.isLoaded
        }
        let changed = lines.contains { !$0.hasSuffix(": unchanged") }
        guard changed || !disagree.isEmpty else { return ([], nil, []) }
        let ns = linkedGroups.sorted()
        var note: String?
        switch ns.count {
        case 0: note = restsLinked ? "Rests are linked to the main page now" : nil
        case 1: note = "Group \(ns[0]) is on the main page now"
        default: note = "Groups " + ns.dropLast().map(String.init).joined(separator: ", ") + " and \(ns.last!) are on the main page now"
        }
        if !disagree.isEmpty {
            let settle = "Settings: \(disagree.count == 1 ? "1 face" : "\(disagree.count) faces") to settle"
            note = note.map { "\($0) · \(settle)" } ?? settle
        }
        return (lines, note, touched)
    }

    /// What the migration did to a project, per face (one line each) — kept for the handoff's table.
    public static func report(for id: UUID) -> [String] { reports[id] ?? [] }
    static var reports: [UUID: [String]] = [:]

    // MARK: the one-time line

    /// Where "shown" is kept — outside the project (showing a line is never an undo step); tests swap it.
    nonisolated(unsafe) static var shownStore: UserDefaults = .standard
    static func shownKey(_ r: FlexibleGroupLinkRecord) -> String { "flexible.groupLink.shown.\(r.id.uuidString)" }

    /// Has the project's one-time line been shown (or is there none)?
    public static func noteShown(_ project: ProjectModel) -> Bool {
        guard let r = project.lattice.flexible?.groupLink, r.note != nil else { return true }
        return shownStore.bool(forKey: shownKey(r))
    }

    /// The ONE line the main page shows on the project's first Flexible open — then marked shown, for good.
    public static func takeNote(_ project: ProjectModel) -> String? {
        guard let r = project.lattice.flexible?.groupLink, let n = r.note, !shownStore.bool(forKey: shownKey(r)) else { return nil }
        shownStore.set(true, forKey: shownKey(r))
        return n
    }

    /// H17 off the Flexible stage: a main-page row the link made or changed says so, until its line was shown.
    public static func caption(_ g: SelectionGroup, _ project: ProjectModel) -> String? {
        guard let r = project.lattice.flexible?.groupLink, r.groups?.contains(g.id) == true, !noteShown(project) else { return nil }
        return FlexibleRowCopy.linkedFromSettings
    }
}
