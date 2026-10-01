// FlexibleLatticeUnder — ★ A PRESSED FACE WITH NO LATTICE UNDER IT IS SAID AT ONCE, AND FIXED IN
// ONE TAP (task 2026-09-29-flexible-screens, round 3 batch E — the Flexible half of his item 4).
//
// ★ WHY NOW. Batch E made a split piece latticeable (LatticeSectorOutline). The Flexible lattice
// goes where the main page's Lattice roles put it (FlexibleJob.regions = latticeJobRegions — the
// round 3 decision), and while 'top A' was dropped that list was EMPTY, which latticed the WHOLE
// part by accident. Now it is what he set: on his pad (img 4 state) the lattice is top A's prism,
// and 'top B' — still pressed — has none under it, so it cannot squish. That is never silent: one
// line, the face selected, [Lattice under it] [Top B rests]. Core's own count decides
// (FlexStackInfo.latticedColumns — the columns with any lattice on their path).
//
// ★ [LATTICE UNDER IT] IS THE MAIN PAGE'S OWN EDIT, never a second rule:
//   * the face is in a main-page group that may carry a lattice role → exactly the Selections
//     row's "Lattice" chip for it (LatticeSelectableRoles.declare; the group's role and depth if it
//     had none), so nothing else in the group moves;
//   * the face is in no group → a group of its own, PROTECTED + LATTICE (his words: "that is how we
//     make a lattice and protected from TO"), as deep as the part is under it (its stack, within the
//     main page's depth limits). No main-page load moves;
//   * otherwise (a group that may not carry a role, a piece held through its parent) there is no
//     one-tap answer: only [<face> rests].
// ★ NEVER A BLOCKER: the lattice still builds — the face just would not squish.

import Foundation

public enum FlexibleLatticeUnder {

    /// Below this share of a pressed face's columns with lattice under them, it is said.
    public static let minShare = 0.5

    /// The pop-up's one sentence.
    public static func line(_ name: String, share: Double) -> String {
        share <= 0 ? "\(name) has no lattice under it, so it can't squish"
                   : "Only \(Int((share * 100).rounded())) % of \(name) has lattice under it"
    }

    /// The short form (the bottom pill, the readiness line).
    public static func pill(_ name: String, share: Double) -> String {
        share <= 0 ? "No lattice under \(name)" : "Little lattice under \(name)"
    }

    static func issue(_ region: Int, share: Double, name: String, canFix: Bool) -> FlexibleIssue {
        FlexibleIssue(id: "noLatticeUnder|\(region)", kind: .noLatticeUnder, region: region,
                      oneLine: line(name, share: share), blocking: false,
                      fixes: (canFix ? [.latticeUnder(region)] : []) + [.rest(region)],
                      pill: pill(name, share: share))
    }

    /// What [Lattice under it] does for a Flexible region (the button exists only when there is one).
    public enum Plan: Equatable, Sendable {
        /// The Selections row's "Lattice" chip in the main-page group that holds it.
        case declare(group: UUID, ref: LatticeSelectableRef)
        /// A new main-page group of its own: protected + Lattice, `depthMM` deep.
        case newGroup(face: FaceID?, region: RegionID?, name: String, depthMM: Double)
    }

    /// The first face the readiness says this about (the main page's pill and its tap).
    public static func first(_ r: FlexibleReadiness) -> FlexibleIssue? {
        r.issues.first { $0.kind == .noLatticeUnder }
    }

    // MARK: ★ BATCH E REVIEW — said everywhere, blocking nothing

    /// ★ THE MAIN PAGE'S PILL with a face left without lattice. Never the `fix` tone: that tone's tap
    /// opens Settings, so on his saved pad EVERY tap of the big Lattice button re-opened the pop-up
    /// and core was out of reach (his round 4 rule: "the large bottom buttons are for exports and
    /// starting the actual core process"). A PREVIEW tone — the tap sends (the Export step says what
    /// core can take) — and the fix lives on Settings' line and the pop-up that opens with the page.
    /// A calibrate-first filament keeps HIS label ('<filament>: shape only — no squish predicted');
    /// otherwise the face is said before core's other holds. nil ⇒ nothing to say.
    public static func mainStatus(_ r: FlexibleReadiness, hold: String?) -> FlexibleMainStatus? {
        guard let n = first(r) else { return nil }
        if r.shapeOnly, let hold { return FlexibleMainStatus(line: hold, tone: .preview, fix: n) }
        return FlexibleMainStatus(line: n.pill, tone: .preview, fix: n)
    }

    /// The Settings page's top line: ★ a calibrate-first filament keeps "shape only" on it.
    public static func readyLine(_ n: FlexibleIssue, shapeOnly: Bool) -> String {
        shapeOnly ? "Ready · shape only · \(n.pill)" : "Ready · \(n.pill)"
    }

    /// "[Lattice under both]" / "[Lattice under all 3]".
    public static func allTitle(_ n: Int) -> String {
        n == 2 ? "Lattice under both" : "Lattice under all \(n)"
    }

    /// ★ SEVERAL FACES, ONE TAP (his round-5 pad: Face 3 and Face 5 at 23 %). Every face that has a
    /// one-tap edit gets [Lattice under both / all N] in place of its own [Lattice under it]; its
    /// [<face> rests] stays. One face: unchanged.
    static func offerAll(_ issues: inout [FlexibleIssue]) {
        let fixable = issues.filter { $0.kind == .noLatticeUnder }
            .compactMap { i in i.fixes.contains { if case .latticeUnder = $0 { return true }; return false } ? i.region : nil }
        guard fixable.count >= 2 else { return }
        issues = issues.map { i in
            guard i.kind == .noLatticeUnder, let r = i.region, fixable.contains(r) else { return i }
            let rest = i.fixes.filter { if case .latticeUnder = $0 { return false }; return true }
            return FlexibleIssue(id: i.id, kind: i.kind, region: r, oneLine: i.oneLine, blocking: i.blocking,
                                 fixes: [.latticeUnderAll(fixable)] + rest, pill: i.pill)
        }
    }

    /// ★ NO LATTICE AT ALL UNDER A PRESSED FACE: its deepest squish has nothing to sink into. The
    /// Settings row and the 3D chip said "3.0 mm" and quietly clamped every edit to 0.5 mm ("Kept
    /// within 0.1–0.5 mm"); now the row says why and offers the fix, and the stored value is kept.
    /// nil (no stack yet) ⇒ not said.
    public static func nothingToSquish(latticeMaxMM: Double?) -> Bool {
        guard let m = latticeMaxMM else { return false }
        return m < FlexibleDepthPrism.minMM
    }

    /// The deepest-squish row's one line when there is nothing to squish into.
    public static let deepestNoLattice = "No lattice under it"

    /// ★ The face's stack line (behind the (i)): the share of its columns with lattice under them is
    /// said — "lattice 100.0–100.0 mm deep" read as all of Face 3 while 77 % of it had none (core's
    /// min/max skip the empty columns).
    public static func stackInfo(uMM: Double, vMM: Double, columns: Int, pitchMM: Double,
                                 latticed: Int, minMM: Double, maxMM: Double) -> String {
        let base = String(format: "%.0f × %.0f mm · %d columns, %.1f mm apart", uMM, vMM, columns, pitchMM)
        guard columns > 0, latticed < columns else {
            return base + String(format: " · lattice %.1f–%.1f mm deep", minMM, maxMM)
        }
        if latticed <= 0 { return base + " · no lattice under it" }
        let pct = Int((100 * Double(latticed) / Double(columns)).rounded())
        return base + String(format: " · lattice under %d %% · %.1f–%.1f mm deep", pct, minMM, maxMM)
    }
}

// MARK: - the model: what the tap does

extension FlexibleStageModel {

    /// The share of `region`'s columns with lattice under them (core's count); nil before its stack.
    func latticedShare(_ region: Int) -> Double? {
        guard let st = stacks[FlexFaceKey(region: region, rotation: settings.face(region)?.rotationDeg ?? 0)],
              !st.columns.isEmpty else { return nil }
        return Double(st.latticedColumns) / Double(st.columns.count)
    }

    func latticeUnderPlan(_ region: Int) -> FlexibleLatticeUnder.Plan? {
        let p = project
        let rid: RegionID? = FlexibleRegions.isSector(region) ? region - FlexibleRegions.sectorBase : nil
        let face: FaceID? = rid == nil ? FaceID(region) : nil
        if let rid, p.faceRegions.region(rid) == nil { return nil }
        // the group that holds it DIRECTLY
        let direct = p.selection.groups.first { g in
            if let rid { return g.regionIDs.contains(rid) }
            return face.map { g.faces.contains($0) } ?? false
        }
        if let g = direct {
            let ok = LatticeFaceRoleGate.allowed(kind: p.force.kind(for: g.id), protected: p.force.isProtected(g.id),
                                                 keepClearOn: p.force.keepClearAffix(for: g.id) == .on)
            guard ok else { return nil }
            let ref: LatticeSelectableRef = rid.map { .region(group: g.id, region: $0) } ?? .face(group: g.id, face: face!)
            guard p.latticeSelectableRole(ref, in: g.id) != .include else { return nil }   // already Lattice: nothing to tap
            return .declare(group: g.id, ref: ref)
        }
        // held through a parent / a union, or the whole face through a region: no one-tap answer
        for g in p.selection.groups {
            if let rid {
                var up = p.faceRegions.region(rid)?.parentID ?? -1
                var seen: Set<RegionID> = [rid]
                while let a = p.faceRegions.region(up), !seen.contains(a.id) {
                    if g.regionIDs.contains(a.id) { return nil }
                    seen.insert(a.id); up = a.parentID
                }
            } else if let face, p.latticeRegionCoveredFaces(g).contains(face) {
                return nil
            }
        }
        let st = stacks[FlexFaceKey(region: region, rotation: settings.face(region)?.rotationDeg ?? 0)]
        let depth = LatticeSlabDepth.clamp(st?.stackMMMax ?? p.lattice.paintDepthMM)
        return .newGroup(face: face, region: rid, name: displayName(region), depthMM: depth)
    }

    /// [Lattice under it]: the main-page edit (`ProjectModel.flexibleLatticeUnder`), one undo
    /// step; the scene re-opens on the new lattice (its key moved), and a toast says what was done
    /// on the main page.
    public func latticeUnder(_ region: Int) {
        guard let plan = latticeUnderPlan(region) else { return }
        actionSerial += 1
        project.sealUndoStep()
        let group = project.flexibleLatticeUnder(plan)
        project.sealUndoStep()
        toast = FlexibleLatticeUnder.toast(plan, name: displayName(region), group: group)
        openScene()   // the lattice moved: the scene re-opens on it
    }

    /// ★ BATCH E REVIEW: [Lattice under both / all N] — each face's own edit (its plan read just
    /// before it is applied, so one face's edit can cover the next), ONE undo step, one re-open.
    public func latticeUnder(all regions: [Int]) {
        let todo = regions.filter { latticeUnderPlan($0) != nil }
        guard !todo.isEmpty else { return }
        actionSerial += 1
        project.sealUndoStep()
        var names: [String] = [], made = 0
        for r in todo {
            guard let plan = latticeUnderPlan(r) else { continue }
            project.flexibleLatticeUnder(plan)
            names.append(displayName(r))
            if case .newGroup = plan { made += 1 }
        }
        project.sealUndoStep()
        toast = FlexibleLatticeUnder.toastAll(names, newSelections: made)
        openScene()
    }
}

extension FlexibleLatticeUnder {
    /// ★ BATCH E REVIEW: the toast names what changed on the MAIN page — a new group there is a
    /// PROTECTED selection (it changes his Optimize runs), never just "a new group" (which collided
    /// with the Flexible page's own "Group 1 · Squeeze").
    static func toast(_ plan: Plan, name: String, group: String) -> String {
        switch plan {
        case .declare: return "\(name): set to Lattice in \(group)"
        case let .newGroup(_, _, n, depth):
            return "\(n): lattice under it, \(Int(depth.rounded())) mm deep · new protected selection \u{201C}\(n)\u{201D}"
        }
    }

    static func toastAll(_ names: [String], newSelections: Int) -> String {
        let who = names.count == 2 ? "\(names[0]) and \(names[1])" : names.joined(separator: ", ")
        guard newSelections > 0 else { return "\(who): set to Lattice on the main page" }
        return "\(who): lattice under them · \(newSelections) new protected selection\(newSelections == 1 ? "" : "s")"
    }
}

// MARK: - the main page's side: the edit itself

extension ProjectModel {

    /// ★ The main-page edit behind [Lattice under it] — the Selections row's own "Lattice" tap, or a
    /// protected + Lattice group of the face's own. Returns the group's name. (The Flexible page
    /// decides the plan; its fixtures replay it — `FlexibleHisProject`.)
    @discardableResult
    func flexibleLatticeUnder(_ plan: FlexibleLatticeUnder.Plan) -> String {
        switch plan {
        case let .declare(gid, ref):
            guard let g = selection.groups.first(where: { $0.id == gid }) else { return "" }
            LatticeSelectableRoles.declare(.include, for: ref, siblings: latticeSelectableRefs(g),
                                           groupRole: latticeEligibleRoles()[gid], in: &lattice.selectableRoles)
            if lattice.groupRoles[gid] == nil {
                lattice.groupRoles[gid] = .include
                if lattice.groupDepthMM[gid] == nil { lattice.groupDepthMM[gid] = LatticeSlabDepth.clamp(lattice.paintDepthMM) }
            }
            lattice.enabled = true
            return g.name
        case let .newGroup(face, rid, name, depth):
            let active = selection.activeGroupID
            let gid = selection.addGroup()
            selection.rename(gid, to: name)
            if let rid { selection.addRegions([rid], to: gid) } else if let face { selection.addFaces([face], to: gid) }
            if let active { selection.setActive(active) } else { selection.clearActive() }
            force.sync(groups: selection.groups)
            force.setProtected(gid, true)
            lattice.enabled = true
            lattice.groupRoles[gid] = .include
            lattice.groupDepthMM[gid] = depth
            let ref: LatticeSelectableRef = rid.map { .region(group: gid, region: $0) } ?? .face(group: gid, face: face ?? 0)
            writeLatticeDepthMM(ref, mm: depth)
            return name
        }
    }
}
