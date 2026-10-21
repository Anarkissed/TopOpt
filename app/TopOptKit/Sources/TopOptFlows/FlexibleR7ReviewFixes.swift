// FlexibleR7ReviewFixes — round 7, "the review of M2 and F" (task 2026-09-29-flexible-screens; the owed two-angle review of
// batches M2 and F, merged with X1 at a870cad4, and his three answers of 2026-10-15). Tests: FlexibleR7RTests and
// FlexibleR7RHostedTests (each with its RED control). App only; no #354, main or core file.
//   (1) His answer 7, clarified: "the weight is an EQUAL SHARE PER LATTICE PART (two parts = 5 lb each of 10 lb, whatever
//       their size), only on the latticed parts." M2 split only the Top (linked to the main page). A face with its OWN
//       weight was COPIED onto each of its lattice parts, so each face pressed twice as hard (Group 2: 10 lb per face
//       became 20). Now a face's own weight is shared equally between its parts, and the parts of one face are ONE hand of
//       its squeeze group (the group's force row says the face's weight, not a part's).
//   (2) F's Bend pose: its cache key sampled every 522nd dent on his pad — always a vertex's x, zero for a press along y
//       or z — so every group's bend had the SAME key, and the page kept the first pose of the session.
//   (3) His answer of 2026-10-15 (1): "With Bend on, the depth chip and depth labels MOVE with the bend (everything goes to
//       the full-bend pose)." A prism's floor, its depth chip and the Prisms view's floor tags follow the bend of their face.
//   (4) His answer of 2026-10-15 (3): after Reset all the MAIN page's line says "Nothing to squish yet" too (neutral, no
//       Fix); with nothing to heat the heat icon is not lit, on either page.
//   (5) The review's smaller findings: a stale "Delete Group N?" never outlives its group; a tap on a face's solid middle
//       picks its lattice parts' group; the violet legend row only while something is violet; the rail counts faces; the
//       pinch line names the face; the face card's named chips fit (under the words when not beside them); F's new
//       controls are 44 pt targets.

import Foundation
import simd
import SwiftUI
import TopOptKit

// MARK: - (1) an equal share per lattice part

/// ★ (1) A face's own weight over its lattice parts: an equal share each; the parts of one face are one hand.
enum FlexibleSectionShares {
    /// ★ RED CONTROL: M2's carry — a face's own weight COPIED onto each of its lattice parts, each part its own hand.
    nonisolated(unsafe) static var controlCopyWeight = false

    /// Is `f` pressed by the main-page Load group it is linked to (its weight is that group's share, not his own)?
    static func isLinked(_ f: FlexibleFaceSettings, _ loads: FlexibleMainPageLoads) -> Bool {
        guard let from = f.weightFrom, let e = loads.entry(f.faceRegionID) else { return false }
        return e.groupID == from && e.role == .pressed
    }

    /// The hand of a face of his own: every pressed lattice part of `region`'s root in its squeeze group, `region` among
    /// them (a whole face, no `root`, or the red control: `region` alone).
    static func parts(of region: Int, settings s: FlexibleStageSettings, loads: FlexibleMainPageLoads,
                      root: ((Int) -> Int)?) -> [Int] {
        guard !controlCopyWeight, let root, let f = s.face(region), f.isLoaded else { return [region] }
        let rt = root(region)
        guard rt != region else { return [region] }
        let gid = FlexibleSqueezeGroups.id(f)
        let out = s.loadedFaces.filter { g in
            root(g.faceRegionID) == rt && FlexibleSqueezeGroups.id(g) == gid && !isLinked(g, loads)
        }.map(\.faceRegionID)
        return out.contains(region) ? out : [region]
    }

    /// `regions` grouped by their root, in order (the parts of one face together; a whole face alone).
    static func byRoot(_ regions: [Int], root: ((Int) -> Int)?) -> [[Int]] {
        guard !controlCopyWeight, let root else { return regions.map { [$0] } }
        var order: [Int] = [], groups: [Int: [Int]] = [:]
        for r in regions {
            let k = root(r)
            if groups[k] == nil { order.append(k) }
            groups[k, default: []].append(r)
        }
        return order.compactMap { groups[$0] }
    }

    /// ★ `kg` — a face's own weight — shared EQUALLY by its lattice parts `parts` (his answer 7: "5 lb each of 10 lb,
    /// whatever their size"); each keeps it as his own (unlinked). The red control: each part takes the whole `kg`.
    static func spread(_ kg: Double, over parts: [Int], in s: inout FlexibleStageSettings) {
        let n = controlCopyWeight ? 1 : Swift.max(1, parts.count)
        for r in parts {
            guard var f = s.face(r) else { continue }
            f.weightKg = kg / Double(n)
            f.weightFrom = nil
            s.setFace(f)
        }
    }

    /// The share each of `n` lattice parts carries of an own weight `total` (the carry at open).
    static func share(_ total: Double, parts n: Int) -> Double {
        controlCopyWeight ? total : total / Double(Swift.max(1, n))
    }
}

extension FlexibleStageModel {
    /// The root a lattice part grows from (a face, or his own Surface sector); any other region is its own root.
    public func rootRegion(of r: Int) -> Int {
        guard FlexibleSectors.isFlexible(r), let p = regions.flexible?.piece(r), p.kind != .strip else { return r }
        return p.rootRegion
    }
    /// Every lattice part's root as it is now, for the static rules (a closure over the sectors' map).
    var rootOf: (Int) -> Int {
        var map: [Int: Int] = [:]
        for p in regions.flexible?.pieces ?? [] where p.kind != .strip { map[p.wireID] = p.rootRegion }
        return { map[$0] ?? $0 }
    }
    /// The hands of squeeze group `g` (a main-page Load group's faces; a face of his own — all its lattice parts).
    public func groupHands(_ g: FlexibleSqueezeGroup) -> [FlexibleSqueezeGroups.Hand] {
        FlexibleSqueezeGroups.hands(g, settings: settings, loads: mainPageLoads, liveKg: liveMainKg, root: rootOf)
    }
    /// ★ R: a lattice part leaving its face's hand (taken out, or set to rest) — the face's force (the hand's sum) and the
    /// parts that carry it on, equally; nil when `region` is no part of an own hand of two or more.
    func partsLeft(without region: Int) -> (kg: Double, parts: [Int])? {
        guard settings.face(region)?.weightFrom == nil, let h = ownPartsHand(region) else { return nil }
        return (h.kg, h.regions.filter { $0 != region })
    }
    /// The own hand `region` presses in (its face's parts), when it has more than one part; nil otherwise.
    func ownPartsHand(_ region: Int) -> FlexibleSqueezeGroups.Hand? {
        guard let g = squeezeGroup(of: region), let h = groupHands(g).first(where: { $0.regions.contains(region) }),
              h.mainGroup == nil, h.regions.count > 1 else { return nil }
        return h
    }
}

// MARK: - (2) the Bend pose's key

extension FlexibleBendPose {
    /// ★ RED CONTROL: F's key — a strided sample of the dents (every count/256-th value).
    @MainActor static var controlSampledKey = false
    /// ★ RED CONTROL: F's rule (before his 2026-10-15 answer) — a prism's floor, its depth chip and the floor tags stay at rest.
    nonisolated(unsafe) static var controlInsideStays = false
}

// MARK: - (4) the empty setup on the main page

extension FlexibleMainStage {
    /// ★ RED CONTROL: today's main page after Reset all — the readiness's "press the face that carries weight" Fix.
    @MainActor static var controlEmptyMainFix = false
    /// Something to heat: a face-prism and a squeeze group (after Reset all there is none — the icon is not lit).
    public var heatAvailable: Bool {
        guard viewsAvailable else { return false }
        if Self.controlEmptyMainFix { return true }
        guard let m = model, m.sceneState == .ready else { return true }
        return !m.squeezeGroups.isEmpty
    }
    /// The heat icon lit: his Heat on and something to heat.
    public var heatIconLit: Bool { heat && heatAvailable }
    /// The "every group" mark on the heat icon (his 3 s hold), only while there is something to heat.
    public var heatAllBadgeShown: Bool { heat && heatAll && heatAvailable }
}

extension FlexibleMainStatus {
    /// ★ (4) The main page's line over an EMPTY setup (Reset all, then Exit): "Nothing to squish yet" — neutral (no warning
    /// outline), no Fix; a tap opens the Squish page (his tap — it never opens by itself). nil: not empty, no face-prism
    /// (M1's line says what to do first), or another blocker than "nothing pressed" (a filament) still stands.
    @MainActor static func emptySetup(_ m: FlexibleStageModel) -> FlexibleMainStatus? {
        guard !FlexibleMainStage.controlEmptyMainFix, m.sceneState == .ready, m.facePrismsSet, m.isEmptySetup,
              FlexibleSettingsExit.emptyLeaves(m.readiness, empty: true) else { return nil }
        return .init(line: FlexibleSettingsExit.emptyLine, tone: .idle, fix: nil)
    }
}

// MARK: - (5) the smaller findings

extension FlexibleStageModel {
    /// ★ RED CONTROL: F's question kept its group id after the group left (a new group reusing the id was asked about).
    @MainActor static var controlAskOutlivesGroup = false

    /// After every edit and every restore (`syncRail`): "Delete Group N?" goes with its group (ids are reused: a new group
    /// was asked about, and [Delete] would have deleted it); with no squeeze group left, the Heat view's "every group" (his
    /// 3 s hold) goes too — the page's opening look, no colour.
    func reviewAfterEdit() {
        if let id = groupDeleteAsk, !Self.controlAskOutlivesGroup, !squeezeGroups.contains(where: { $0.id == id }) { groupDeleteAsk = nil }
        // ★ U21 (DEL-CONFIRM): a take-out / press-trash ask goes with its face / press
        if let r = faceRemoveAsk, settings.face(r) == nil { faceRemoveAsk = nil }
        if let p = pressRemoveAsk, settings.press(p) == nil { pressRemoveAsk = nil }
        if squeezeGroups.isEmpty, views.heatScope == .all, !FlexibleMainStage.controlEmptyMainFix {
            var v = views
            v.insert(.heatOff); v.remove(.heatAll)
            views = v
        }
    }
    /// A tab change: the question asked on another group's tab goes.
    func dropDeleteAskOffItsTab() {
        dropInPlaceAsks()   // ★ U21: a tab change drops a take-out / press / Reset all / pop-up ask
        guard let id = groupDeleteAsk, !Self.controlAskOutlivesGroup, rail != .group(id) else { return }
        groupDeleteAsk = nil
    }
}

extension FlexibleMainStage {
    /// ★ RED CONTROL: F's main-page tap — a tap on a face's solid middle (its root, in no group) keeps the last group.
    @MainActor static var controlTapRootIgnored = false
    /// The first pressed lattice part of root `r` when every pressed part of it is in ONE squeeze group; else nil.
    @MainActor static func onePartsGroup(of r: Int, model m: FlexibleStageModel) -> Int? {
        let root = m.rootOf
        let parts = m.settings.loadedFaces.map(\.faceRegionID).filter { $0 != r && root($0) == r }
        let groups = Set(parts.compactMap { m.squeezeGroup(of: $0)?.id })
        return groups.count == 1 ? parts.first : nil
    }
}

extension FlexibleLegend {
    /// ★ RED CONTROL: M2's legend row — "Violet = lattice · tap to pick" whenever a face is cut into parts.
    @MainActor static var controlVioletRowAlways = false
}

extension FlexibleSettingsRailView {
    /// ★ RED CONTROL: M2's rail — every lattice part counted as a face.
    @MainActor static var controlRailCountsParts = false
    /// A faces group's faces — its lattice parts counted once per face (M2's "Group 1 · 2 faces" for the one Top).
    @MainActor static func faceCount(_ g: FlexibleSqueezeGroup, model m: FlexibleStageModel) -> Int {
        if controlRailCountsParts { return g.regions.count }
        let root = m.rootOf
        return Set(g.regions.map(root)).count
    }
}

extension FlexibleFacePanel {
    /// ★ RED CONTROL: the pinch line names the partner's lattice PART (cut to "Face 2 · lattic…").
    @MainActor static var controlPinchPartName = false
    /// The pinch line of a pressed face (nil: no pinch partner).
    @MainActor static func pinchLine(model: FlexibleStageModel, region r: Int) -> String? {
        guard let other = model.pinchPartners(r).first else { return nil }
        let oneProfile = model.key(r).map { model.segmentErrors[$0] != nil } ?? false
        let name = model.faceName(controlPinchPartName ? other : model.rootRegion(of: other))
        return oneProfile ? FlexibleRowCopy.pinchedOneProfile(with: name) : FlexibleRowCopy.pinched(with: name)
    }
}

extension FlexibleFaceGroupRow {
    /// ★ RED CONTROL: F's row — the chips only BESIDE the words, else one menu chip.
    @MainActor static var controlMenuFallback = false
}

/// ★ (5) His rule: 44 pt targets.
enum FlexibleTargets {
    /// ★ RED CONTROL: F's sizes (the take-out 32 × 32; Delete, Keep, Reset 32 tall; Reset all 30 tall).
    @MainActor static var controlSmall = false
    /// A finger's target.
    static let minimum: CGFloat = 44
    /// A control's side: 44 pt (the red control: F's `old`).
    @MainActor static func side(_ old: CGFloat) -> CGFloat { controlSmall ? old : Swift.max(old, minimum) }
    /// The least side a header control's target takes (the red control: none — the drawn capsule alone).
    @MainActor static var least: CGFloat? { controlSmall ? nil : minimum }
}
