// FlexibleSettingsOpenGroup — the Settings page's OPEN GROUP is the master (task 2026-09-29-flexible-screens, round 7
// batch S; his img4 words of 2026-10-14: "After creating the first group, and in particular adding a corner
// modification, automatically brings me back to Group 1. It does this after every change I make, please make it stay on
// the same group and never shift." and "What is this 3mm? I don't see anything listed in the group with that number? I
// should only be able to view numbers associated to what I'm working on.").
//
// ★ WHY IT SHIFTED (read at 61cfce05): the open tab was COMPUTED from the selected face after every edit (syncRail →
// railTab(for: selectedRegion)). An edges group has no face to select, so the selection stayed on Group 1's Face 1; a
// strip cut re-ids Face 1's rest and moved the selection to it; the rest's new id made "Little lattice under Face 1" look
// like a NEW issue, whose pop-up selected Face 1 and opened Group 1; a renumber sent a stale tab to the first group; and
// every fallback (removeFace, the re-open's adopt, both panels' onAppear) picked the first loaded face — Group 1's.
// ★ NOW (4f):
//   (a) the open tab's MEMBERS are remembered (`FlexibleRailKeep`: its faces and presses, the regions model they were
//       read through); after every change the tab is the group — or Rests — that holds them now (a member the change
//       re-id'd, a strip's rest, is found on its own face among the NEW regions); its members all gone, the group at the
//       same rank, else the one before; no group left: [+ New]. Never Group 1 by default.
//   (b) the tab follows a face only on an EXPLICIT pick — a face tapped on the part, a row, [+ New]'s start, the player's
//       group picker, the pop-up's own fix (`followSelection`); a selection the code makes moves no tab.
//   (c) an edges tab selects no face (it has none) and its first press;
//   (d)/(e) whatever re-points the selection (a removed face, a re-cut rest, the re-open, the panels' onAppear) stays
//       inside the open tab (`appearSelection`, `keepSelectionInOpenTab`);
//   (f) the readiness keys a face's issues by the face's ROOT (`issueKey`): a re-cut rest is the same issue, never a new
//       pop-up; and the pop-up selects its face only when it is in the open tab (`presentSelection`) — otherwise it names
//       and pulses it.
// ★ 4g: the page draws a face's numbers (its depth chip, its curves, its stamp handle, the Prisms view's tags) only for
// the face he works on in the open tab (`FlexibleStageOverlays.workingRegion`).

import Foundation
import TopOptKit

/// ★ 4f (a): the open tab's members, remembered so the tab stays on them through any change.
struct FlexibleRailKeep: Equatable {
    var tab: FlexibleRailTab
    /// Its number as shown when remembered (the rank fallback).
    var rank: Int?
    /// Its faces (regions) and its presses.
    var regions: [Int]
    var presses: Set<UUID>
    /// Every face the settings held then (a member that vanished maps to a NEW region on its own face; a face that WAS set
    /// and is not now was removed or moved).
    var known: Set<Int>
    /// The regions model they were read through (a vanished member's faces).
    var faceRegions: FaceRegionModel
}

extension FlexibleStageModel {
    /// ★ RED CONTROL (FlexibleR7SettingsTests): today's rule — the tab follows the SELECTED FACE after every edit.
    @MainActor static var controlRailFollowsSelection = false
    /// ★ RED CONTROL: today's Reset all — the main page's loads read in again, the strips left cut.
    @MainActor static var controlResetAdopts = false

    // MARK: (a) the members

    /// The open tab's members now.
    func captureRail() -> FlexibleRailKeep {
        let s = settings
        var k = FlexibleRailKeep(tab: rail, rank: nil, regions: [], presses: [], known: Set(s.faces.map(\.faceRegionID)),
                                 faceRegions: project.faceRegions)
        switch rail {
        case .group(let id):
            if let g = railGroup(id) { k.rank = g.number; k.regions = g.regions; k.presses = Set(g.presses) }
        case .rests:
            k.regions = s.faces.filter { !$0.isLoaded }.map(\.faceRegionID)
        case .model, .newGroup:
            break
        }
        return k
    }

    /// The faces (regions) of `members` as they are now: a kept id as it is, a vanished one as the NEW faces on its own
    /// mesh face (a strip cut, a re-cut and their undo re-id a face's rest; nothing else is new).
    func membersNow(_ members: [Int], _ k: FlexibleRailKeep) -> Set<Int> {
        let present = Set(settings.faces.map(\.faceRegionID))
        var now = Set<Int>()
        var vanished: [Int] = []
        for r in members { if present.contains(r) { now.insert(r) } else { vanished.append(r) } }
        guard !vanished.isEmpty, let mesh = project.viewerMesh else { return now }
        let fresh = present.subtracting(k.known)
        guard !fresh.isEmpty else { return now }
        let before = FlexibleRegions(model: k.faceRegions, mesh: mesh), after = regions
        for r in vanished {
            let faces = Set(before.faces(of: r, mesh: mesh))
            for n in fresh where !faces.isDisjoint(with: after.faces(of: n, mesh: mesh)) { now.insert(n) }
        }
        return now
    }

    /// ★ 4f (a): where the open tab is after a change — the group (or Rests) that holds most of its members now (a tie
    /// keeps it a group when it was one, then the nearest number); its members all gone, the group at the same rank, else
    /// the one before; no group left: [+ New]. [Model] and [+ New] stay put.
    func resolveRail(_ k: FlexibleRailKeep) -> FlexibleRailTab {
        if k.tab == .model || k.tab == .newGroup { return k.tab }
        let now = membersNow(k.regions, k)
        let gs = squeezeGroups
        let wasGroup: Bool = { if case .group = k.tab { return true }; return false }()
        let rank = k.rank ?? (gs.count + 1)
        var best: (key: (Int, Int, Int), tab: FlexibleRailTab)?
        func offer(_ tab: FlexibleRailTab, score: Int, isGroup: Bool, number: Int) {
            guard score > 0 else { return }
            let key = (score, isGroup == wasGroup ? 1 : 0, -abs(number - rank))
            if best == nil || best!.key < key { best = (key, tab) }
        }
        for g in gs {
            offer(.group(g.id), score: g.regions.filter(now.contains).count + g.presses.filter(k.presses.contains).count,
                  isGroup: true, number: g.number)
        }
        let rests = settings.faces.filter { !$0.isLoaded }.map(\.faceRegionID)
        offer(.rests, score: rests.filter(now.contains).count, isGroup: false, number: gs.count + 1)
        if let b = best { return b.tab }
        if wasGroup, let g = gs.first(where: { $0.number == rank }) ?? gs.last(where: { $0.number < rank }) { return .group(g.id) }
        if !wasGroup, let g = gs.last { return .group(g.id) }   // Rests emptied: the tab before it
        return .newGroup
    }

    /// ★ After every edit (FlexibleStageModel.edit) and every restore (the page's undo / redo): the open tab is the group
    /// that holds its members (a), and the selection stays inside it (c)–(e).
    func syncRail() {
        if Self.controlRailFollowsSelection {   // ★ RED CONTROL: today's rule
            if rail == .model || rail == .newGroup { return }
            let t = railTab(for: selectedRegion)
            if t != rail { rail = t }
            return
        }
        let t = railKeep.map(resolveRail) ?? validRail
        if t != rail {
            rail = t   // railChanged keeps the selection inside it and remembers its members
        } else {
            keepSelectionInOpenTab(railKeep)
            railKeep = captureRail()
        }
    }

    // MARK: (b) the explicit picks

    /// ★ 4f (b): HIS pick of the selected face (a tap on the part, a row, the pop-up's fix) opens its tab — a face not set
    /// yet keeps the tab open (its card offers [Press it] there).
    func followSelection() {
        guard let r = selectedRegion else { return }
        let t = railTab(for: r)
        if t != rail { rail = t }
    }

    // MARK: (c)–(e) the selection inside the open tab

    /// Can `region` be the selected face with the open tab as it is? (a group's own face; a resting face on [Rests];
    /// anything on [Model]; nothing on [+ New]).
    public func admitsSelection(_ region: Int) -> Bool {
        switch rail {
        case .group(let id): return railGroup(id)?.regions.contains(region) == true
        case .rests: return settings.face(region).map { !$0.isLoaded } ?? false
        case .model: return true
        case .newGroup: return false
        }
    }

    /// Select `region` when the open tab admits it (an action's face that moved out of the open tab is not selected).
    func selectIfAdmitted(_ region: Int) {
        if Self.controlRailFollowsSelection || admitsSelection(region) { selectedRegion = region }
    }

    /// Does `r` exist as a region of the part now (a whole face, or a declared sector)?
    func regionExists(_ r: Int) -> Bool { !FlexibleRegions.isSector(r) || regions.sector(r) != nil }

    /// ★ 4f (c)–(e): the selected face is one of the open tab's, or none. An edges tab selects no face and its first press;
    /// a face that moved out or went away is replaced by its own piece in the tab (a re-cut rest on the same face), else
    /// the tab's first face; a face tapped on the part that is not set yet stays (its card offers [Press it]).
    func keepSelectionInOpenTab(_ k: FlexibleRailKeep?) {
        func replacement(for r: Int?, among members: [Int]) -> Int? {
            if let r, let k, let mesh = project.viewerMesh {
                let faces = Set(FlexibleRegions(model: k.faceRegions, mesh: mesh).faces(of: r, mesh: mesh))
                if let same = members.first(where: { !faces.isDisjoint(with: regions.faces(of: $0, mesh: mesh)) }) { return same }
            }
            return members.first
        }
        func stays(_ r: Int) -> Bool {
            settings.face(r) == nil && !(k?.known.contains(r) ?? false) && regionExists(r)
        }
        switch rail {
        case .group(let id):
            guard let g = railGroup(id) else { return }
            if g.kind == .edges {
                if selectedRegion != nil { selectedRegion = nil }
                if selectedPress.map({ !g.presses.contains($0) }) ?? true { selectedPress = g.presses.first }
                return
            }
            // (none selected: its first face — its curves on the part)
            if let r = selectedRegion, g.regions.contains(r) || stays(r) { return }
            if let n = replacement(for: selectedRegion, among: g.regions) { select(n) } else if selectedRegion != nil { selectedRegion = nil }
        case .rests:
            let rests = settings.faces.filter { !$0.isLoaded }.map(\.faceRegionID)
            if let r = selectedRegion, rests.contains(r) || stays(r) { return }
            if let n = replacement(for: selectedRegion, among: rests) { select(n) } else if selectedRegion != nil { selectedRegion = nil }
        case .model, .newGroup:
            break
        }
    }

    /// ★ The panels' onAppear rule, and the re-open's (`adoptMainPageLoads`) and a removed face's: the face selected when
    /// nothing is — the OPEN group's first face, the first resting face on [Rests], none on an edges tab, [Model] or
    /// [+ New]. Never `loadedFaces.first` (Group 1's).
    @MainActor
    static func appearSelection(_ m: FlexibleStageModel) -> Int? {
        if controlRailFollowsSelection { return m.settings.loadedFaces.first?.faceRegionID }   // (the red control: today's)
        switch m.rail {
        case .group(let id):
            guard let g = m.railGroup(id), g.kind == .faces else { return nil }
            return g.regions.first
        case .rests:
            return m.settings.faces.first { !$0.isLoaded }?.faceRegionID
        case .model, .newGroup:
            return nil
        }
    }

    // MARK: (f) issues keyed by the face's root

    /// ★ 4f (f): the key a face's issues carry — the face's own id for a whole face and for a piece of a chain whose root
    /// is the face itself (a strip's REST: a re-cut gives it a new id, never a new issue); a Surface sector's own id
    /// (or the sector a strip cut it from). A face no strip touched keeps its id as before.
    public func issueKey(_ region: Int) -> String {
        guard FlexibleRegions.isSector(region), !FlexibleReadiness.controlIssueIdByRegion else { return "\(region)" }
        let m = project.faceRegions
        let strips = (settings.presses ?? []).compactMap(\.strip)
        let face = regions.faces(of: region, mesh: project.viewerMesh).first ?? region
        let root = FlexibleEdgeStrips.rootOf(region, face: face, faceRegions: m, existing: strips)
        guard root >= 0, let r = m.region(root) else { return "\(region)" }
        if r.isIdentity && !r.isCut { return "\(face)" }
        return "\(FlexibleRegions.wireID(r))"
    }

    // MARK: 4h [+ New] with nothing pressed

    /// ★ 4h: [+ New] with nothing pressed — a tap on a face starts Group 1: at the main page's weight when a Load group
    /// presses it, else at `kg` (the keypad's answer); with neither, the keypad asks (`newGroupAsk`) and false is returned.
    /// ONE undo step; its tab opens.
    @discardableResult
    public func startFirstGroup(_ region: Int, kg: Double?) -> Bool {
        guard settings.loadedFaces.isEmpty, presses.isEmpty else { return false }
        guard !pressNeedsWeight(region) || (kg ?? 0) > 0 else { newGroupAsk = region; return false }
        project.sealUndoStep()
        guard press(region, kg: kg) else { newGroupAsk = region; return false }
        newGroupAsk = nil
        if let g = squeezeGroup(of: region) { rail = .group(g.id) }
        selectedRegion = region
        if tab == .more { tab = .face }
        save()
        return true
    }
}

extension FlexibleStageOverlays {
    /// ★ RED CONTROL: today's gate — the selected face's numbers whatever tab is open (his img4).
    @MainActor static var controlGateOnSelectionOnly = false

    /// ★ 4g: the face whose numbers the page draws (the depth chip, the curve editors, the stamp handle, the selected
    /// prism): the selected face only when the open tab admits it — a face of the open group (an edges group: none), a
    /// resting face on [Rests], the face selected on [Model]; nothing on [+ New].
    @MainActor
    static func workingRegion(model m: FlexibleStageModel) -> Int? {
        guard let r = m.selectedRegion else { return nil }
        if controlGateOnSelectionOnly { return r }
        return m.admitsSelection(r) ? r : nil
    }

    struct WorkingFace { let region: Int; let geometry: FlexFaceGeometry; let face: FlexibleFaceSettings }

    /// ★ The face the overlays draw on (its curves, its depth chip, its stamp handle): the working region, on the Face
    /// tab, out of pick mode, a pressed face with its map. nil: nothing is drawn on a face.
    @MainActor
    static func workingFace(model m: FlexibleStageModel) -> WorkingFace? {
        guard m.edgePick == nil, m.tab == .face, let r = workingRegion(model: m), let k = m.key(r),
              let g = m.geometry[k], let f = m.settings.face(r), f.isLoaded else { return nil }
        return WorkingFace(region: r, geometry: g, face: f)
    }

    /// The curve editors drawn (the face and its axes); nil: none (no working face, or a Stamp face).
    @MainActor
    static func curveEditors(model m: FlexibleStageModel) -> (region: Int, axes: [String])? {
        guard let w = workingFace(model: m) else { return nil }
        let axes = curveAxes(w.face)
        return axes.isEmpty ? nil : (w.region, axes)
    }
}

extension FlexibleStagePage {

    /// ★ 4f (f): the face the fix pop-up selects as it opens on `issue` — its face only when the open tab admits it;
    /// otherwise nil: the pop-up names and pulses the face, and the tab stays (its own fix is his pick and moves it).
    @MainActor
    static func presentSelection(_ issue: FlexibleIssue, model m: FlexibleStageModel) -> Int? {
        guard let r = issue.region else { return nil }
        if FlexibleStageModel.controlRailFollowsSelection { return r }
        return m.admitsSelection(r) ? r : nil
    }
}

extension FlexibleReadiness {
    /// ★ RED CONTROL (4f f): issue ids by REGION (today's) — a strip re-cut re-ids the rest and its issue looks new.
    nonisolated(unsafe) static var controlIssueIdByRegion = false
}
