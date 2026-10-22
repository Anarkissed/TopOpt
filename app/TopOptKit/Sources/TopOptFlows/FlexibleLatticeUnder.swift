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

    static func issue(_ region: Int, share: Double, name: String, canFix: Bool, key: String? = nil) -> FlexibleIssue {
        // ★ ROUND 7 (S, 4f f): keyed by the face's root (a strip's re-cut rest is the same issue)
        FlexibleIssue(id: "noLatticeUnder|\(key ?? "\(region)")", kind: .noLatticeUnder, region: region,
                      oneLine: line(name, share: share), blocking: false,
                      fixes: (canFix ? [.latticeUnder(region)] : []) + [.rest(region)],
                      pill: pill(name, share: share))
    }

    /// ★ U21 BATCH E (NOLAT + LBR-COVER, his notes of 2026-10-21 — Img12/11: "if we are going to say 'you need to lattice
    /// this first' then it should do so for every face"; Img14: "I tapped a side wall and it shows that there IS lattice
    /// behind it? That's definitely a bug."): the ONE notice for a face, or part of a face, with no lattice of its own — a tap
    /// on it (FlexibleStageModel.noLatticeTap, in the fix pop-up's place), a pressed face's pop-up, pill and top line. Fixes
    /// [Go to Lattice] and, where the whole face can rest, [<face> rests] (rests need no lattice). Never blocking. It replaces
    /// [Lattice under it] on such a face: on his Face 1 that made a 50 mm protected lattice sideways into the part.
    static func noPrismIssue(_ region: Int, name: String, canRest: Bool, key: String? = nil) -> FlexibleIssue {
        FlexibleIssue(id: "noLatticeUnder|\(key ?? "\(region)")", kind: .noLatticeUnder, region: region,
                      oneLine: FlexibleRowCopy.noLatticeUnder(name), blocking: false,
                      fixes: [.goToLattice] + (canRest ? [.rest(region)] : []),
                      pill: pill(name, share: 0))
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
        // ★ ROUND 7, RULING 6: no face-prism — no lattice under any face, by his rule; nothing was asked of core
        if heldWithoutFacePrism, settings.face(region)?.isLoaded == true { return 0 }
        // ★ U21 BATCH E: no lattice of its OWN — 0, never core's count of another face-prism's lattice on its columns (his
        // l-bracket: Face 5 11.8 %, Face 1 36.5 %, Face 7 93.8 %); a curved face-prism's root (notYet) keeps core's share
        if !hasOwnLattice(region) { return 0 }
        guard let st = stacks[FlexFaceKey(region: region, rotation: settings.face(region)?.rotationDeg ?? 0)],
              !st.columns.isEmpty else { return nil }
        return Double(st.latticedColumns) / Double(st.columns.count)
    }

    // MARK: ★ U21 BATCH E — the one lattice rule

    /// ★ RED CONTROL only (U21 batch E): core's column count speaks for every face (today's): "Only 12 % of Face 5", its
    /// Deepest box capped at core's 118.8 mm, its chip, prism and dent drawn.
    nonisolated(unsafe) static var controlCoreShare = false

    /// ★ U21 BATCH E: does `region` have lattice of its OWN — the app's face-prism geometry (FlexibleSectorSet.latticed: a
    /// section, a root wholly inside a face-prism, a curved face-prism's root)? True under the old whole-part / whole-face
    /// controls (their lattice is the whole part) and with no part loaded (nothing to say).
    public func hasOwnLattice(_ region: Int) -> Bool {
        if Self.controlCoreShare || Self.controlDesignsWithoutPrism || controlWholePartWithoutPrism
            || FlexibleLatticeSections.controlWholeFace || FlexibleRegions.controlPressAnyRoot { return true }
        guard project.viewerMesh != nil else { return true }
        return sectorSet.latticed(region)
    }

    /// ★ U21 BATCH E: the deepest `region` may be squished — its deepest column's lattice (half where pinched); 0 with no
    /// lattice of its own (the card says "No lattice under it", the chip, the prism and the dent read 0); nil before its stack.
    public func latticeMaxMM(_ region: Int) -> Double? {
        if !hasOwnLattice(region) { return 0 }
        return stack(region).map { FlexibleDepthPrism.latticeMax($0, pinched: pinchedColumns(region)) }
    }

    /// ★ U21 BATCH E: the notice a tap on `root` (or on the solid part of it) shows — nothing is pressed or selected. [<face>
    /// rests] only when the whole face can rest: never the solid part of a face partly inside a face-prism (its sections
    /// press), never a face already resting.
    func noLatticeNotice(root: Int) -> FlexibleIssue {
        let partial = regions.flexible?.partialRoots[root] != nil
        let rests = settings.face(root).map { !$0.isLoaded } ?? false
        return FlexibleLatticeUnder.noPrismIssue(root, name: displayName(root), canRest: !partial && !rests, key: "tap|\(root)")
    }

    /// ★ U21 BATCH E: [Go to Lattice] — one request the page answers with its leave for the Lattice page (saved, never the
    /// bake: FlexibleStagePage.leaveForLattice), the toast's own route (FlexibleToastFix.goToLattice).
    public func askLeaveForLattice() {
        noLatticeTap = nil
        leaveForLatticeAsks += 1
    }

    func latticeUnderPlan(_ region: Int) -> FlexibleLatticeUnder.Plan? {
        // ★ ROUND 7 (M2): a Flexible sector is a lattice section (or its strip / rest) — latticed by construction; no one-tap
        if FlexibleRegions.isFlexible(region) { return nil }
        // ★ U21 BATCH E: a face with no lattice of its own gets [Go to Lattice], never the one-tap (on his side Face 1 it would
        // lattice sideways 50 mm deep into the part, against his 10-18 default-depth rule)
        if !hasOwnLattice(region) { return nil }
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
