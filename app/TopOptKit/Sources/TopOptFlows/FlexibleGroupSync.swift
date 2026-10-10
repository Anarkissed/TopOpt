// FlexibleGroupSync — ONE SET OF GROUPS (task 2026-09-29-flexible-screens, round 6 item 4; his img4: "All set groups
// should be visible on the main Flexibles screen. Also, any groups already created should already be set in the
// flexible settings when the user starts up. These two boxes should be synced; with the settings allowing more granular
// settings specific to flexibles/squish dynamics"; his answer: "Yes, one set of groups").
//
// ★ THE MODEL (the approved design, spec §4, with his answers of 2026-10-08/09):
//   * the main page's Selections groups ARE the groups — Topology and Optimize read them as they always did;
//   * a Settings SQUEEZE GROUP is its main-page Load groups ("hands"): one force, one colour. One hand = one Load group.
//     A PINCH is one Load group PER SIDE (two rows, one colour, each pushing into its own wall — #354's loadCase sums the
//     member normals, so one Push group on opposite walls pushes both straight down); faces on ONE side are one hand
//     and share its weight by area ("10 kg on Top A + Top B = 5 + 5"); each side pushes with the group's force;
//   * Anchor = Rests (one Rests tab; a row names its group); a main-page group with no role is PENDING and Settings
//     lists it with [Squeeze it] [It rests];
//   * Settings adds the squish detail (curves, stamp, shape, deepest, the pinch, the presses), keyed by region.
// ★ THE WRITES (Settings → main page) go through #354's PUBLIC selection / force APIs only — addGroup, rename,
// restore(groups:active:) (each membership edit as ONE replay of the groups, so nothing #354 sweeps is lost on the way),
// makeLoad / makeAnchor / setDirection / setWeight / clearKind and the affix setters. Every action writes the Flexible
// settings AND the Selections in one go, sealed as ONE undo step (`syncGroups`). No #354 file is edited for it.
// ★ FINDING A PRESSED FACE'S HAND, in order (spec §4): (1) the main-page Load group that already presses it; (2) a
// role-less group that holds exactly faces this squeeze group presses, on its side — it takes the role; (3) a hand of
// its squeeze group on its side (core's 15°) — the face joins it and shares its weight; (4) else a NEW hand: Push, the
// group's force, named "Group N" (one hand) or "Group N · Face X" (several). Names made here follow the group's number
// and its hands (`renameHands`); a name he made or gave ("Top", "Group C") is never touched.
// ★ THE TRASH takes the face off its main-page group too (his answer); a group it empties is removed unless it carries
// keep-clear, protect, a lattice role or hand-placed primitives — then it stays, pending, with its affixes.

import Foundation
import simd
import TopOptDesign
import TopOptKit

/// A main-page group with no role yet ("Pending…" on the main page), listed on Settings' Pending tab.
public struct FlexiblePendingGroup: Equatable, Identifiable, Sendable {
    public let id: UUID
    public let name: String
    /// The Flexible regions it holds.
    public let regions: [Int]
    public init(id: UUID, name: String, regions: [Int]) { self.id = id; self.name = name; self.regions = regions }
}

/// [Press it] on a face a main-page Anchor holds: asked once — "Face 0 rests (main page: Bottom)".
/// ★ (item 4 verification) the same ask settles a face the two pages DISAGREE on, as an older project was saved (round 3
/// let Settings press a face an Anchor holds, or rest one a Load presses): `conflict`, and `pressedOnMain` for the second
/// ("Face 1 is pressed (main page: Top)" [Squeeze it] [It rests]). Never settled at restore — nobody is there to ask.
public struct FlexibleRestsAsk: Equatable, Sendable {
    public let region: Int
    public let anchorName: String
    public let faceName: String
    public let kg: Double?
    public let into: Int?
    /// The two pages disagree as saved (listed on the Pending tab until he settles it).
    public var conflict = false
    /// The main page PRESSES it (a Load group) while Settings rests it.
    public var pressedOnMain = false
    public var line: String {
        pressedOnMain ? FlexibleRowCopy.pressedAsk(face: faceName, group: anchorName) : FlexibleRowCopy.restsAsk(face: faceName, anchor: anchorName)
    }
}

/// The links' red controls (tests only).
enum FlexibleGroupLinks {
    /// RED CONTROL: a new main-page Load group joins squeeze group 1 (round 3's adopt).
    nonisolated(unsafe) static var controlOneSqueezeTag = false
    /// RED CONTROL: `designInputs` keeps `weightFrom` (a link alone re-keys the lattice).
    nonisolated(unsafe) static var controlKeepWeightFrom = false
    /// RED CONTROL: the trash leaves the face in its main-page group (round 5 S6's rule).
    nonisolated(unsafe) static var controlKeepMainGroup = false
    /// RED CONTROL: a fresh adopt ignores the hands' names (every new Load group its own squeeze group).
    nonisolated(unsafe) static var controlNoFamilies = false
    /// RED CONTROL (item 4 verification): round 3's adopt — a face whose main-page group no longer presses or anchors it
    /// stays pressed in Settings as his own (the pages disagree; the next restore linked it again).
    nonisolated(unsafe) static var controlKeepOrphans = false
    /// RED CONTROL (item 4 verification): the restore links as round 6 first shipped — taking faces out of groups that hold
    /// them with the other role, joining hands that carry a lattice role, removing emptied groups, on EVERY restore.
    nonisolated(unsafe) static var controlEagerRestore = false
    /// RED CONTROL (item 4 verification): a main-page weight on ONE hand of a squeeze group stays on that hand alone.
    nonisolated(unsafe) static var controlNoEqualise = false
    /// RED CONTROL (item 4 verification): a hand made from a face leaving a Protect / keep-clear group carries nothing.
    nonisolated(unsafe) static var controlDropAffixes = false
    /// RED CONTROL (item 4 verification): hands renamed by the look of their name (any "Group N …").
    nonisolated(unsafe) static var controlRenameByName = false
    /// RED CONTROL (item 4 verification): a face a region that can't split holds is linked anyway (two groups hold it).
    nonisolated(unsafe) static var controlTwoGroups = false
    /// RED CONTROL (item 4 verification): a new hand takes #354's next colour and goes to the end of the list.
    nonisolated(unsafe) static var controlPlainHands = false

    /// A name THIS code gives a hand ("Group 2", "Group 2 · Face 4") — renamed when its group's number or hands change.
    static func madeHere(_ name: String) -> Bool {
        name.range(of: #"^Group [0-9]+( · .+)?$"#, options: .regularExpression) != nil
    }

    /// The squeeze group number a hand named here was made for ("Group 2 · Face 4" → 2); nil for any other name.
    static func family(_ name: String?) -> Int? {
        guard !controlNoFamilies, let name, madeHere(name) else { return nil }
        return Int(name.dropFirst("Group ".count).prefix { $0.isNumber })
    }
}

extension FlexibleRowCopy {
    /// "Face 0 rests (main page: Bottom)".
    public static func restsAsk(face: String, anchor: String) -> String { "\(face) rests (main page: \(fit(anchor, 16)))" }
    /// "Face 1 is pressed (main page: Top)" — Settings rests a face a main-page Load presses (an older project).
    public static func pressedAsk(face: String, group: String) -> String { "\(face) is pressed (main page: \(fit(group, 16)))" }
    /// A pressed face on no main-page group (the restore left it as saved — his call), or one a group holds through a
    /// region that cannot be split (a filter region): never in two groups.
    public static let notOnMainPage = "Not on the main page yet"
    public static func heldBy(_ group: String) -> String { fit("\(fit(group, 16)) holds it (a region that can't split)") }
    /// H17 off the Flexible stage: a row the restore's link made or changed (until its one-time line was shown).
    public static let linkedFromSettings = "Linked from Flexible Settings"
    /// The Pending tab's detail: "1 group", "1 face", "1 group · 1 face".
    public static func pendingCount(groups: Int, faces: Int) -> String {
        [groups > 0 ? groupCount(groups) : nil, faces > 0 ? faceCount(faces) : nil].compactMap { $0 }.joined(separator: " · ")
    }
    /// A hand's name among several: "Group 2 · Face 4", "Group 1 · Top A + Top B".
    public static func handName(number: Int, faces: [String]) -> String { fit("\(groupName(number)) · " + faces.joined(separator: " + "), 30) }
    /// H17's caption: "Squeezed with Group 2 · Face 2".
    public static func squeezedWith(_ names: [String]) -> String { fit("Squeezed with " + names.joined(separator: " + "), 44) }
    /// The Pending tab.
    public static let railPending = "Pending"
    public static func groupCount(_ n: Int) -> String { n == 1 ? "1 group" : "\(n) groups" }
    /// The Pending tab's line under each group (the main page's own words — LatticeFaceRoleGate).
    public static let pendingLine = LatticeFaceRoleGate.Block.undeclared.reason
    public static let squeezeIt = "Squeeze it"
    public static let itRests = "It rests"
    public static let keepResting = "Keep it resting"
    /// "Face 0 · Bottom" — a resting face's row names the main-page group it rests with.
    public static func restRow(name: String, group: String) -> String { fit("\(name) · \(fit(group, 16))") }
}

// MARK: - the links: pure, on values (the migration's and every action's)

/// The two pages' state as values — the Selections, the roles, the Flexible settings — and the edits that keep them
/// one set of groups. Pure: it reads the mesh and the regions, writes only these three values.
struct FlexibleGroupWorld {
    var selection: SelectionModel
    var force: ForceModel
    var flexible: FlexibleStageSettings
    let x: FlexibleMainPageLoads.Expander
    let latticeRoles: Set<UUID>
    /// Core's into-the-face direction when a stack exists (the model's), nil at restore.
    let load: (Int) -> SIMD3<Double>?
    /// ★ (item 4 verification) AT RESTORE — the migration, with nobody there to ask: nothing he set is taken apart. No
    /// face leaves a group that holds it with the other role, a keep-clear role, a lattice role, hand-placed primitives
    /// or a region that cannot be split; no face joins a group carrying an affix or a lattice role; no group is
    /// removed. Such a face stays exactly as it was saved, unlinked, and is listed in `held` (a disagreement is settled
    /// in Settings' Pending tab — `FlexibleStageModel.disagreements`).
    var atRestore = false
    /// What the restore left as saved: region → why (the report's lines, the handoff's table).
    var held: [Int: String] = [:]

    init(selection: SelectionModel, force: ForceModel, flexible: FlexibleStageSettings, x: FlexibleMainPageLoads.Expander,
         latticeRoles: Set<UUID>, load: @escaping (Int) -> SIMD3<Double>? = { _ in nil }) {
        self.selection = selection; self.force = force; self.flexible = flexible; self.x = x
        self.latticeRoles = latticeRoles; self.load = load
    }

    /// The restore's rules are on (its red control restores the eager link).
    var guarded: Bool { atRestore && !FlexibleGroupLinks.controlEagerRestore }

    mutating func hold(_ r: Int, _ why: String) { held[r] = why }

    // MARK: reading

    func members(_ g: SelectionGroup) -> [Int] { x.members(g) }
    func group(_ id: UUID) -> SelectionGroup? { selection.groups.first { $0.id == id } }
    /// The groups holding Flexible region `r`, in list order.
    func holders(_ r: Int) -> [SelectionGroup] { selection.groups.filter { members($0).contains(r) } }
    func loads() -> FlexibleMainPageLoads { FlexibleMainPageLoads.derive(groups: selection.groups, force: force, x: x, load: load) }
    static func isEmpty(_ g: SelectionGroup) -> Bool { g.faces.isEmpty && g.regionIDs.isEmpty }
    /// Keep-clear, protect, a lattice role or hand-placed primitives: an emptied group carrying one stays.
    func hasAffix(_ id: UUID) -> Bool {
        force.keepClearAffix(for: id) == .on || force.isProtected(id) || latticeRoles.contains(id) || !force.manualPrimitives(for: id).isEmpty
    }
    /// The main page's "Pending…": no role and no complete declaration (keep-clear, protect, a lattice role).
    func isMainPending(_ id: UUID) -> Bool {
        force.kind(for: id).isPending && force.keepClearAffix(for: id) != .on && !force.isProtected(id) && !latticeRoles.contains(id)
    }
    func name(_ r: Int) -> String { FlexibleGroupWorld.displayName(r, regions: x.regions, mesh: x.mesh) }
    static func displayName(_ r: Int, regions: FlexibleRegions, mesh: ViewerMesh?) -> String {
        let sector = regions.sector(r)
        return FlexibleRowCopy.faceName(sector: sector?.name, face: sector == nil ? r : regions.faces(of: r, mesh: mesh).first ?? r)
    }
    func inward(_ r: Int) -> SIMD3<Double>? { x.inward(r, load: load) }
    func direction(_ id: UUID) -> SIMD3<Double>? { group(id).flatMap { x.direction($0, force: force) } }
    /// Does Load group `hand` press `r` straight in (core's same-axis 15°)?
    func sameSide(_ r: Int, _ hand: UUID) -> Bool {
        guard let d = direction(hand), simd_length(d) > 1e-9, let n = inward(r) else { return false }
        return simd_dot(simd_normalize(d), n) >= FlexibleMainPageLoads.straightCos
    }
    /// Two faces facing the same way (their inward normals within 15°).
    func sameFacing(_ a: Int, _ b: Int) -> Bool {
        guard let na = inward(a), let nb = inward(b) else { return false }
        return simd_dot(na, nb) >= FlexibleMainPageLoads.straightCos
    }
    /// The faces of `regions` grouped by the way they face, in order.
    func sides(_ regions: [Int]) -> [[Int]] {
        var out: [[Int]] = []
        for r in regions {
            if let i = out.firstIndex(where: { sameFacing($0[0], r) }) { out[i].append(r) } else { out.append([r]) }
        }
        return out
    }
    /// The hands of squeeze group `gid` (stored id): the Load groups its pressed faces are linked to, in order.
    func hands(ofSqueeze gid: Int) -> [UUID] {
        var out: [UUID] = []
        for f in flexible.loadedFaces where FlexibleSqueezeGroups.id(f) == gid {
            guard let h = f.weightFrom, !out.contains(h), force.kind(for: h).isLoad, group(h) != nil else { continue }
            out.append(h)
        }
        return out
    }
    func pressed(_ r: Int, in gid: Int) -> Bool {
        flexible.face(r).map { $0.isLoaded && FlexibleSqueezeGroups.id($0) == gid } ?? false
    }

    // MARK: membership (one replay of the groups per edit — #354's restore, nothing swept on the way)

    func covers(_ regionID: RegionID, _ r: Int) -> Bool { x.expand(region: regionID).contains { $0.id == r } }

    /// A union holding `r`, as its other parts (recursively); nil when a region that is not a union holds it.
    func split(_ reg: FaceRegion, _ r: Int, sector: RegionID?) -> [RegionID]? {
        guard reg.isUnionOfParts else { return nil }
        var out: [RegionID] = []
        for p in reg.parts {
            if p == sector { continue }
            if covers(p, r) {
                guard let sub = x.faceRegions.region(p), let s = split(sub, r, sector: sector) else { return nil }
                out += s
            } else { out.append(p) }
        }
        return out
    }

    /// `g` with Flexible region `r` taken out of its own lists (a face, a sector, a union holding it — replaced by its
    /// other parts); nil when a region that cannot be split holds it (a filter region, a whole-face region).
    func taking(_ r: Int, outOf g: SelectionGroup) -> SelectionGroup? {
        let sector: RegionID? = FlexibleRegions.isSector(r) ? r - FlexibleRegions.sectorBase : nil
        let faces = sector == nil ? g.faces.filter { Int($0) != r } : g.faces
        var regs: [RegionID] = []
        for id in g.regionIDs {
            if let s = sector, id == s { continue }
            guard covers(id, r) else { regs.append(id); continue }
            guard let reg = x.faceRegions.region(id), let parts = split(reg, r, sector: sector) else { return nil }
            for p in parts where !regs.contains(p) { regs.append(p) }
        }
        let out = SelectionGroup(id: g.id, name: g.name, colorIndex: g.colorIndex, faces: faces, regionIDs: regs)
        return members(out).contains(r) ? nil : out
    }

    /// Write `groups` back as ONE replay. A group THIS edit emptied is removed — unless it carries an affix, when it
    /// stays, pending, its affixes kept. ★ (item 4 verification) at restore no group is ever removed.
    mutating func commit(_ groups: [SelectionGroup]) {
        let wasEmpty = Dictionary(uniqueKeysWithValues: selection.groups.map { ($0.id, Self.isEmpty($0)) })
        var keep: [SelectionGroup] = []
        for g in groups {
            if Self.isEmpty(g), wasEmpty[g.id] == false, !guarded {
                if hasAffix(g.id) { makePending(g.id) } else { force.clearKind(g.id); continue }
            }
            keep.append(g)
        }
        selection.restore(groups: keep, active: selection.activeGroupID)
    }

    /// Can every group holding `r` (but `keep`) let it go? (A filter region, a whole-face region: no.)
    func canDetach(_ r: Int, keep: UUID? = nil) -> Bool {
        guard !FlexibleGroupLinks.controlTwoGroups else { return true }
        return selection.groups.allSatisfy { g in g.id == keep || !members(g).contains(r) || taking(r, outOf: g) != nil }
    }

    /// ★ (item 4 verification) at restore: why a group holding `r` (but `keep`) must keep it — a keep-clear role, a
    /// lattice role, hand-placed primitives, a Load or an Anchor, a region that cannot be split; nil: only a group with
    /// no role (its Protect / keep-clear affix goes with the face — `carried`).
    func restoreBlock(_ r: Int, keep: UUID? = nil) -> String? {
        for g in holders(r) where g.id != keep {
            let k = force.kind(for: g.id)
            if case .clearance = k { return "\u{201C}\(g.name)\u{201D} keeps it clear on the main page" }
            if latticeRoles.contains(g.id) { return "\u{201C}\(g.name)\u{201D} puts a lattice under it on the main page" }
            if !force.manualPrimitives(for: g.id).isEmpty { return "\u{201C}\(g.name)\u{201D} carries placed shapes" }
            if k.isLoad || k.isAnchor { return "\u{201C}\(g.name)\u{201D} holds it as a \(k.isLoad ? "Load" : "Anchor")" }
            if taking(r, outOf: g) == nil { return "\u{201C}\(g.name)\u{201D} holds it in a region that can't split" }
        }
        return nil
    }

    /// The affixes of the groups `r` would leave (Protect, keep-clear) — a hand made from it carries them, so the main
    /// page protects exactly what it protected (the M2 stand's face 2 kept Group C's Protect).
    struct Carried: Equatable {
        var protect = false
        var keepClear: KeepClearAffix?
        var isEmpty: Bool { !protect && keepClear == nil }
    }
    func carried(_ r: Int, keep: UUID? = nil) -> Carried {
        var c = Carried()
        guard !FlexibleGroupLinks.controlDropAffixes else { return c }
        for g in holders(r) where g.id != keep {
            if force.isProtected(g.id) { c.protect = true }
            if let k = force.keepClearAffix(for: g.id), k == .on { c.keepClear = k }
        }
        return c
    }
    mutating func give(_ c: Carried, to id: UUID) {
        if c.protect { force.setProtected(id, true) }
        if let k = c.keepClear { force.setKeepClearAffix(id, k) }
    }

    /// The main-page group holding `r` (the first), its name.
    func holderName(_ r: Int) -> String? { holders(r).first?.name }

    /// No role, its affixes kept (ForceModel's public setters: clearKind clears everything, so they are put back).
    mutating func makePending(_ id: UUID) {
        guard !force.kind(for: id).isPending else { return }
        let keepClear = force.keepClearAffix(for: id), protect = force.isProtected(id)
        let prims = force.manualPrimitives(for: id), o = force.clearanceOverride(for: id)
        force.clearKind(id)
        if let k = keepClear { force.setKeepClearAffix(id, k) }
        if protect { force.setProtected(id, true) }
        if !prims.isEmpty { force.loadManualPrimitives(prims, for: id) }
        if let v = o.concentricMarginMM { force.setClearanceMargin(id, mm: v) }
        if let v = o.axialClearanceMM { force.setClearanceAxial(id, mm: v) }
        if let v = o.slabDepthMM { force.setClearanceSlab(id, mm: v) }
    }

    /// Take `r` off every group that holds it (but `keep`); false when one of them cannot let it go.
    @discardableResult
    mutating func detach(_ r: Int, keep: UUID? = nil) -> Bool {
        var groups = selection.groups, ok = true
        for i in groups.indices where groups[i].id != keep && members(groups[i]).contains(r) {
            if let t = taking(r, outOf: groups[i]) { groups[i] = t } else { ok = false }
        }
        commit(groups)
        return ok
    }

    /// `r` into group `id` — out of every other group first (a face belongs to one group). ★ (item 4 verification) false,
    /// and nothing moved, when a group holding it cannot let it go (a filter region): never in two groups.
    @discardableResult
    mutating func attach(_ r: Int, to id: UUID) -> Bool {
        guard canDetach(r, keep: id) else { return false }
        var groups = selection.groups
        for i in groups.indices where groups[i].id != id && members(groups[i]).contains(r) {
            if let t = taking(r, outOf: groups[i]) { groups[i] = t }
        }
        if let i = groups.firstIndex(where: { $0.id == id }), !members(groups[i]).contains(r) {
            let g = groups[i]
            groups[i] = FlexibleRegions.isSector(r)
                ? SelectionGroup(id: g.id, name: g.name, colorIndex: g.colorIndex, faces: g.faces, regionIDs: g.regionIDs + [r - FlexibleRegions.sectorBase])
                : SelectionGroup(id: g.id, name: g.name, colorIndex: g.colorIndex, faces: g.faces + [FaceID(r)], regionIDs: g.regionIDs)
        }
        commit(groups)
        return true
    }

    /// A new main-page group (#354's addGroup: its colour cursor), named; the ACTIVE group stays his.
    mutating func newGroup(_ name: String) -> UUID {
        let active = selection.activeGroupID
        let id = selection.addGroup()
        selection.rename(id, to: name)
        selection.restore(groups: selection.groups, active: active)
        return id
    }

    /// ★ (item 4 verification) a new HAND of squeeze group `gid`: recorded as made here (`madeHands` — the only names
    /// renamed), in its squeeze group's colour on every page (a sibling hand's #354 colour, else the palette's nearest
    /// to the squeeze colour — a pinch's two rows one colour on Topology too), and listed right after its group's other
    /// hands (one group's rows together).
    mutating func newHand(_ name: String, squeeze gid: Int) -> UUID {
        let siblings = FlexibleGroupLinks.controlPlainHands ? [] : hands(ofSqueeze: gid).compactMap { group($0) }
        let id = newGroup(name)
        flexible.madeHands = (flexible.madeHands ?? []) + [id]
        if FlexibleGroupLinks.controlPlainHands { return id }
        var groups = selection.groups
        if let i = groups.firstIndex(where: { $0.id == id }) {
            let g = groups.remove(at: i)
            let number = FlexibleSqueezeGroups.groups(flexible).first { $0.id == gid }?.number ?? (FlexibleSqueezeGroups.groups(flexible).count + 1)
            let colour = siblings.last?.colorIndex ?? Self.nearestPaletteIndex(FlexibleSqueezeGroups.colour(number: number, in: flexible))
            let at = siblings.last.flatMap { s in groups.firstIndex { $0.id == s.id } }.map { $0 + 1 } ?? groups.count
            groups.insert(SelectionGroup(id: g.id, name: g.name, colorIndex: colour, faces: g.faces, regionIDs: g.regionIDs), at: at)
            selection.restore(groups: groups, active: selection.activeGroupID)
        }
        return id
    }

    /// The #354 palette entry nearest a colour.
    static func nearestPaletteIndex(_ c: RGBA) -> Int {
        let p = DS.Color.groupPalette
        func d(_ a: RGBA) -> Double { let dr = a.r - c.r, dg = a.g - c.g, db = a.b - c.b; return dr * dr + dg * dg + db * db }
        return p.indices.min { d(p[$0]) < d(p[$1]) } ?? 0
    }

    /// Was hand `id` made here (renamed with its group)? Its id is on the list and its name is still one this code gives.
    func madeHere(_ id: UUID) -> Bool {
        guard let n = group(id)?.name, FlexibleGroupLinks.madeHere(n) else { return false }
        return FlexibleGroupLinks.controlRenameByName || (flexible.madeHands ?? []).contains(id)
    }

    /// ★ (item 4 verification) a parked face pressed or rested again from Settings comes back with its squish detail.
    mutating func unparkFace(_ r: Int) {
        guard flexible.face(r) == nil, var parked = flexible.parkedFaces, let i = parked.firstIndex(where: { $0.faceRegionID == r }) else { return }
        flexible.setFace(parked.remove(at: i))
        flexible.parkedFaces = parked.isEmpty ? nil : parked
    }

    mutating func setWeightFrom(_ r: Int, _ id: UUID?) {
        guard var f = flexible.face(r), f.weightFrom != id else { return }
        f.weightFrom = id
        flexible.setFace(f)
    }

    // MARK: linking

    /// Link pressed Flexible face `r` (squeeze group `gid`, stored) to its hand — found, taken or made (the order is in
    /// the file comment). nil: a main-page Load group holds it without pressing it (a pull, a shear — his to settle
    /// there); ★ (item 4 verification) or it stays as saved — at restore (`held`), or held by a region that can't split.
    @discardableResult
    mutating func linkPressed(_ r: Int, squeeze gid: Int, kg: Double) -> UUID? {
        let l = loads()
        if let e = l.entry(r) {
            if e.role == .pressed { setWeightFrom(r, e.groupID); return e.groupID }
            if force.kind(for: e.groupID).isLoad { return nil }
            // at restore a face an Anchor holds stays as saved — the pages disagree; he settles it in Settings
            if guarded, e.role == .rests {
                hold(r, "Settings presses it, \u{201C}\(e.groupName)\u{201D} rests it on the main page (Settings' Pending tab)")
                return nil
            }
        }
        for g in holders(r) where force.kind(for: g.id).isPending {
            let ms = members(g)
            guard ms.allSatisfy({ $0 == r || (pressed($0, in: gid) && sameFacing($0, r)) }) else { continue }
            force.makeLoad(g.id); force.setDirection(g.id, .push); force.setWeight(g.id, kg: kg)
            for m in ms { setWeightFrom(m, g.id) }
            return g.id
        }
        if guarded, let why = restoreBlock(r) { hold(r, why); return nil }
        guard canDetach(r) else {
            hold(r, "\u{201C}\(holderName(r) ?? "a group")\u{201D} holds it in a region that can't split")
            return nil
        }
        let c = carried(r)
        // a hand of its squeeze group on its side: joined (their weight shared by area) — never with an affix to carry
        // (it would spread to the hand's other faces), and at restore never a hand that carries one or a lattice role
        if c.isEmpty, let h = hands(ofSqueeze: gid).first(where: { sameSide(r, $0) }) {
            if guarded, hasAffix(h) {
                hold(r, "joining \u{201C}\(group(h)?.name ?? "its hand")\u{201D} would put "
                     + (latticeRoles.contains(h) ? "its lattice under it" : "its Protect / keep-clear on it") + " (his call)")
                return nil
            }
            if attach(r, to: h) { setWeightFrom(r, h); return h }
            return nil
        }
        let id = newHand(FlexibleRowCopy.groupName(gid), squeeze: gid)
        force.makeLoad(id); force.setDirection(id, .push); force.setWeight(id, kg: kg)
        give(c, to: id)
        attach(r, to: id); setWeightFrom(r, id)
        return id
    }

    /// Link resting Flexible face `r` to an Anchor: the one that holds it; a role-less group holding only faces that rest
    /// (it becomes the Anchor); else the first Anchor group; else a new "Rests". ★ (item 4 verification) nil: it stays as
    /// saved (at restore, or held by a region that can't split); a group's Protect / keep-clear goes with it.
    @discardableResult
    mutating func linkResting(_ r: Int) -> UUID? {
        if let e = loads().entry(r) {
            if e.role == .rests { setWeightFrom(r, e.groupID); return e.groupID }
            if guarded {
                hold(r, e.role == .pressed
                     ? "Settings rests it, \u{201C}\(e.groupName)\u{201D} presses it on the main page (Settings' Pending tab)"
                     : "\u{201C}\(e.groupName)\u{201D} holds it as a Load")
                return nil
            }
        }
        for g in holders(r) where force.kind(for: g.id).isPending {
            let ms = members(g)
            guard ms.allSatisfy({ flexible.face($0).map { !$0.isLoaded } ?? false }) else { continue }
            force.makeAnchor(g.id)
            for m in ms { setWeightFrom(m, g.id) }
            return g.id
        }
        if guarded, let why = restoreBlock(r) { hold(r, why); return nil }
        guard canDetach(r) else {
            hold(r, "\u{201C}\(holderName(r) ?? "a group")\u{201D} holds it in a region that can't split")
            return nil
        }
        let c = carried(r)
        let anchor: UUID
        if c.isEmpty, let a = selection.groups.first(where: { force.kind(for: $0.id).isAnchor && !(guarded && hasAffix($0.id)) })?.id {
            anchor = a
        } else {
            anchor = newGroup("Rests"); force.makeAnchor(anchor); give(c, to: anchor)
        }
        attach(r, to: anchor); setWeightFrom(r, anchor)
        return anchor
    }

    /// Two hands of one squeeze group pressing the same way are ONE side: the later's faces join the earlier (their
    /// weight then shared by area — his force answer).
    mutating func mergeSameSide(squeeze gid: Int) {
        var hs = hands(ofSqueeze: gid)
        var i = 0
        while i < hs.count {
            var j = i + 1
            while j < hs.count {
                if let a = direction(hs[i]), let b = direction(hs[j]), simd_length(a) > 1e-9, simd_length(b) > 1e-9,
                   simd_dot(simd_normalize(a), simd_normalize(b)) >= FlexibleMainPageLoads.straightCos {
                    for f in flexible.loadedFaces where f.weightFrom == hs[j] && FlexibleSqueezeGroups.id(f) == gid {
                        if attach(f.faceRegionID, to: hs[i]) { setWeightFrom(f.faceRegionID, hs[i]) }
                    }
                    hs.remove(at: j)
                } else { j += 1 }
            }
            i += 1
        }
    }

    // MARK: following the main page (item 4 verification)

    /// ★ HIS FORCE ANSWER, ON THE MAIN PAGE: a squeeze group's force is ONE number — a weight set on one of its hands (a
    /// pinch side's row, the scrub or the pad) is every hand's, in the same undo step. `changed`: the hands whose weight
    /// moved since the last look; when those of one squeeze group agree on a weight, its other hands take it. true:
    /// something was written.
    @discardableResult
    mutating func equaliseHands(changed: Set<UUID>) -> Bool {
        guard !FlexibleGroupLinks.controlNoEqualise, !changed.isEmpty else { return false }
        var wrote = false
        for g in FlexibleSqueezeGroups.groups(flexible) {
            let hs = hands(ofSqueeze: g.id)
            guard hs.count > 1 else { continue }
            let moved = hs.filter { changed.contains($0) }
            let kgs = moved.compactMap { force.kind(for: $0).weightKg }
            guard let kg = kgs.first, kgs.allSatisfy({ abs($0 - kg) < 1e-9 }) else { continue }
            for h in hs where !moved.contains(h) {
                if let w = force.kind(for: h).weightKg, abs(w - kg) > 1e-9 { force.setWeight(h, kg: kg); wrote = true }
            }
        }
        return wrote
    }

    /// The hands whose weight is not the one Settings' faces record (a weight set on the main page since the last
    /// adopt): each linked face's weight is its share of its hand's.
    func handsMovedSinceRecorded() -> Set<UUID> {
        let l = loads()
        var out = Set<UUID>()
        for f in flexible.loadedFaces {
            guard let h = f.weightFrom, let now = force.kind(for: h).weightKg, l.entry(f.faceRegionID)?.groupID == h,
                  let was = l.groupKg(forRegion: f.faceRegionID, kg: f.weightKg) else { continue }
            if abs(was - now) > 1e-6 * max(1, now) { out.insert(h) }
        }
        return out
    }

    /// The Flexible faces re-read from the groups (the adopt every open runs — its own squeeze tag for a new Load group).
    @discardableResult
    mutating func readopt() -> [Int: Double] { FlexibleStageModel.adopt(loads(), into: &flexible) }

    /// Each hand named here follows its group: "Group N" alone, "Group N · Face X" among several.
    mutating func renameHands() {
        // (a hand deleted since is no longer one made here)
        if let made = flexible.madeHands {
            let alive = made.filter { group($0) != nil }
            if alive != made { flexible.madeHands = alive.isEmpty ? nil : alive }
        }
        for g in FlexibleSqueezeGroups.groups(flexible) {
            let hs = hands(ofSqueeze: g.id)
            for h in hs {
                // ★ (item 4 verification) a hand THIS code made, by id — a "Group 7" he typed is his name
                guard let sg = group(h), madeHere(h) else { continue }
                let faces = flexible.loadedFaces.filter { $0.weightFrom == h }.map { name($0.faceRegionID) }
                let want = hs.count == 1 ? FlexibleRowCopy.groupName(g.number) : FlexibleRowCopy.handName(number: g.number, faces: faces)
                if sg.name != want { selection.rename(h, to: want) }
            }
        }
    }
}

// MARK: - main → Settings: a face its main-page group let go of (item 4 verification)

extension FlexibleStageModel {
    /// ★ HIS DELETE ANSWER, MIRRORED (main page → Settings): a face LINKED to a main-page group that no longer presses or
    /// rests it — the group deleted, its role cleared, the face moved into a group with no role, a pull — is un-pressed:
    /// it leaves Settings (the job, the rail), parked with its squish detail, and the main page's Pending group (if any)
    /// shows on the Pending tab. Round 3 kept it pressed as his own: the pages disagreed until the next restore linked it
    /// back (the verifier's P1, P2, P9). A face of his own (no link) is never parked.
    nonisolated static func parkOrphans(_ s: inout FlexibleStageSettings, loads: FlexibleMainPageLoads, skip: Set<Int>) {
        guard !FlexibleGroupLinks.controlKeepOrphans else { return }
        var parked = s.parkedFaces ?? []
        for f in s.faces where f.weightFrom != nil && !skip.contains(f.faceRegionID) {
            if let e = loads.entry(f.faceRegionID), e.role != .ask { continue }
            var p = f
            p.weightFrom = nil
            parked.removeAll { $0.faceRegionID == f.faceRegionID }
            parked.append(p)
            s.removeFace(f.faceRegionID)
        }
        s.parkedFaces = parked.isEmpty ? nil : parked
    }

    /// A parked face a main-page group presses or rests again comes back WITH its squish detail (curves, stamp, shape,
    /// deepest) — its role, weight and link from the group (the adopt that follows).
    nonisolated static func unpark(_ s: inout FlexibleStageSettings, loads: FlexibleMainPageLoads, skip: Set<Int>) {
        guard var parked = s.parkedFaces, !parked.isEmpty else { return }
        for p in parked where s.face(p.faceRegionID) == nil && !skip.contains(p.faceRegionID) {
            guard let e = loads.entry(p.faceRegionID), e.role != .ask else { continue }
            var f = p
            f.role = e.role == .pressed ? "loaded" : "resting"
            f.weightFrom = e.groupID
            if e.role == .pressed { f.weightKg = e.weightKg }
            s.setFace(f)
            parked.removeAll { $0.faceRegionID == p.faceRegionID }
        }
        s.parkedFaces = parked.isEmpty ? nil : parked
    }
}

// MARK: - the model: every Settings action on both pages

extension FlexibleStageModel {

    /// The expansion (areas, normals, sectors) for the part as it is — cached per regions and mesh.
    var groupExpander: FlexibleMainPageLoads.Expander? {
        guard let mesh = project.viewerMesh else { return nil }
        let regions = self.regions
        let key = "\(regions.key)|\(project.faceRegions.regions.count)|\(mesh.triangleCount)|\(mesh.positions.count)"
        if let c = groupExpanderCache, c.key == key { return c.x }
        let x = FlexibleMainPageLoads.Expander(faceRegions: project.faceRegions, mesh: mesh, regions: regions)
        groupExpanderCache = (key, x)
        return x
    }

    func groupWorld() -> FlexibleGroupWorld? {
        guard let x = groupExpander else { return nil }
        return FlexibleGroupWorld(selection: project.selection, force: project.force, flexible: settings, x: x,
                                  latticeRoles: Set(project.lattice.groupRoles.keys),
                                  load: { [stacks] r in stacks[FlexFaceKey(region: r, rotation: 0)]?.load })
    }

    /// ★ ONE ACTION ON BOTH PAGES: the Selections, the roles and the Flexible settings written in one go — the faces
    /// re-read from the groups, the hands named — and sealed as ONE undo step (what came before is its own).
    func syncGroups(_ body: (inout FlexibleGroupWorld) -> Void) {
        guard var w = groupWorld() else { return }   // (no part: nothing to link)
        project.sealUndoStep()
        body(&w)
        let relinked = w.readopt()
        w.renameHands()
        if w.selection != project.selection { project.selection = w.selection }
        if w.force != project.force { project.force = w.force }
        edit { $0 = w.flexible }
        if let l = deriveMainPageLoads() { mainPageLoads = l }
        relinkedWeights.merge(relinked) { old, _ in old }
        project.sealUndoStep()
    }

    // MARK: press, rest, the trash

    /// [Press it] — on both pages. A face a main-page Anchor holds asks first (`restsAsk`). A face a Load group presses
    /// is linked to it (its hand moves into `groupID`'s group with it); any other joins `groupID` (else the hand's group,
    /// else group 1) at that group's force — through its hand (`FlexibleGroupWorld.linkPressed`). false: no weight to
    /// press with (the pad asks).
    @discardableResult
    func pressLinked(_ region: Int, kg: Double?, into groupID: Int?) -> Bool {
        let entry = mainPageLoads.entry(region)
        if let e = entry, e.role == .rests, restsConfirmed != region {
            restsAsk = FlexibleRestsAsk(region: region, anchorName: e.groupName, faceName: displayName(region), kg: kg, into: groupID)
            selectedRegion = region
            let t = railTab(for: region)   // the card that asks is on screen (its Rests tab)
            if rail != t { rail = t }
            return true
        }
        let inherited = entry.flatMap { $0.role == .pressed ? $0 : nil }
        let handGroup: FlexibleSqueezeGroup? = inherited.flatMap { e in
            settings.loadedFaces.first { $0.weightFrom == e.groupID }.flatMap { squeezeGroup(of: $0.faceRegionID) }
        }
        let target: FlexibleSqueezeGroup? = groupID.flatMap { railGroup($0) } ?? handGroup ?? (inherited == nil ? squeezeGroups.first : nil)
        let gid = target?.id ?? ((squeezeGroups.map(\.id).max() ?? 0) + 1)
        let force = target.flatMap { groupForce($0) }.flatMap { f -> Double? in f.upperBound - f.lowerBound < 0.05 && f.upperBound > 0 ? f.upperBound : nil }
        let kgUse = kg ?? (inherited == nil ? force : nil)
        guard inherited != nil || (kgUse ?? 0) > 0 else { return false }
        actionSerial += 1
        let hand = hand(of: region)
        syncGroups { w in
            if w.flexible.isRemoved(region) {
                w.flexible.removedRegions?.removeAll { $0 == region }
                if w.flexible.removedRegions?.isEmpty == true { w.flexible.removedRegions = nil }
            }
            w.unparkFace(region)
            var f = w.flexible.face(region) ?? FlexibleFaceSettings(faceRegionID: region)
            f.role = "loaded"
            f.squeezeGroup = gid == FlexibleSqueezeGroups.first ? nil : gid
            if let e = inherited { f.weightKg = e.weightKg; f.weightFrom = e.groupID } else { f.weightKg = kgUse ?? f.weightKg; f.weightFrom = nil }
            w.flexible.setFace(f)
            if let e = inherited {
                FlexibleSqueezeGroups.move(region, to: gid, hand: hand, in: &w.flexible)
                // pressed on a group's tab, its hand takes that group's one force, and joins a hand on its side there
                if groupID != nil, let fk = force, w.force.kind(for: e.groupID).isLoad { w.force.setWeight(e.groupID, kg: fk) }
                if groupID != nil, let g = FlexibleSqueezeGroups.group(of: region, in: w.flexible) { w.mergeSameSide(squeeze: g.id) }
            } else {
                w.linkPressed(region, squeeze: gid, kg: kgUse ?? f.weightKg)
            }
            FlexibleSqueezeGroups.normalise(&w.flexible)
        }
        restsConfirmed = nil
        relinkedWeights[region] = nil
        selectedRegion = region
        ensureStack(region)
        return true
    }

    /// [It rests here] — on both pages: the face rests with an Anchor (it leaves a hand it was in).
    func restLinked(_ region: Int) {
        actionSerial += 1
        syncGroups { w in
            if w.flexible.isRemoved(region) {
                w.flexible.removedRegions?.removeAll { $0 == region }
                if w.flexible.removedRegions?.isEmpty == true { w.flexible.removedRegions = nil }
            }
            w.unparkFace(region)
            var f = w.flexible.face(region) ?? FlexibleFaceSettings(faceRegionID: region, role: "resting")
            f.role = "resting"
            f.weightFrom = nil
            w.flexible.setFace(f)
            FlexibleSqueezeGroups.normalise(&w.flexible)   // a resting face is in no squeeze group
            w.linkResting(region)
        }
        relinkedWeights[region] = nil
        selectedRegion = region
    }

    /// The trash — on both pages (his answer): the face leaves Settings AND its main-page group. Only a face a region
    /// that cannot be split holds is remembered as deleted instead (round 5 S6's rule), so the re-sync skips it.
    func removeLinked(_ region: Int) {
        actionSerial += 1
        syncGroups { w in
            w.flexible.removeFace(region)
            // (a face he deletes here never comes back from the parked list either — S7: reset values)
            w.flexible.parkedFaces?.removeAll { $0.faceRegionID == region }
            if w.flexible.parkedFaces?.isEmpty == true { w.flexible.parkedFaces = nil }
            let held = !w.holders(region).isEmpty
            let off = !FlexibleGroupLinks.controlKeepMainGroup && w.detach(region)
            if held, !off, !w.flexible.isRemoved(region) { w.flexible.removedRegions = (w.flexible.removedRegions ?? []) + [region] }
            FlexibleSqueezeGroups.normalise(&w.flexible)
        }
    }

    // MARK: the main page's Pending groups (Settings' Pending tab)

    /// The main page's Pending groups (no role, no keep-clear / protect / lattice role) that hold a face of the part.
    public var pendingGroups: [FlexiblePendingGroup] {
        guard let w = groupWorld() else { return [] }
        return project.selection.groups.compactMap { g in
            guard w.isMainPending(g.id) else { return nil }
            let rs = w.members(g)
            return rs.isEmpty ? nil : FlexiblePendingGroup(id: g.id, name: g.name, regions: rs)
        }
    }

    /// [Squeeze it]: the group becomes a Load (push, `kg`) in a NEW squeeze group, its faces pressed and linked — on two
    /// opposite walls, one hand per side. One undo step.
    public func squeezePending(_ id: UUID, kg: Double) {
        guard kg > 0, kg.isFinite, let p = pendingGroups.first(where: { $0.id == id }) else { return }
        actionSerial += 1
        syncGroups { w in
            let gid = (FlexibleSqueezeGroups.groups(w.flexible).map(\.id).max() ?? 0) + 1
            let sides = w.sides(p.regions)
            // the other walls leave it first: ONE Push group on opposite walls pushes both straight down (#354's loadCase)
            var groups = w.selection.groups
            if let i = groups.firstIndex(where: { $0.id == id }) {
                for r in sides.dropFirst().flatMap({ $0 }) { if let t = w.taking(r, outOf: groups[i]) { groups[i] = t } }
            }
            w.commit(groups)
            w.force.makeLoad(id); w.force.setDirection(id, .push); w.force.setWeight(id, kg: kg)
            for (i, side) in sides.enumerated() {
                for r in side {
                    if w.flexible.isRemoved(r) {
                        w.flexible.removedRegions?.removeAll { $0 == r }
                        if w.flexible.removedRegions?.isEmpty == true { w.flexible.removedRegions = nil }
                    }
                    w.unparkFace(r)
                    var f = w.flexible.face(r) ?? FlexibleFaceSettings(faceRegionID: r)
                    f.role = "loaded"; f.weightKg = kg; f.weightFrom = i == 0 ? id : nil
                    f.squeezeGroup = gid == FlexibleSqueezeGroups.first ? nil : gid
                    w.flexible.setFace(f)
                }
            }
            for side in sides.dropFirst() { for r in side { w.linkPressed(r, squeeze: gid, kg: kg) } }
            FlexibleSqueezeGroups.normalise(&w.flexible)
        }
        if let r = p.regions.first { selectedRegion = r; ensureStack(r) }
    }

    /// [It rests]: the group becomes an Anchor, its faces resting and linked. One undo step.
    public func restPending(_ id: UUID) {
        guard let p = pendingGroups.first(where: { $0.id == id }) else { return }
        actionSerial += 1
        syncGroups { w in
            w.force.makeAnchor(id)
            for r in p.regions {
                if w.flexible.isRemoved(r) {
                    w.flexible.removedRegions?.removeAll { $0 == r }
                    if w.flexible.removedRegions?.isEmpty == true { w.flexible.removedRegions = nil }
                }
                w.unparkFace(r)
                var f = w.flexible.face(r) ?? FlexibleFaceSettings(faceRegionID: r, role: "resting")
                f.role = "resting"; f.weightFrom = id
                w.flexible.setFace(f)
            }
            FlexibleSqueezeGroups.normalise(&w.flexible)
        }
        if let r = p.regions.first { selectedRegion = r }
    }

    // MARK: the anchored face's ask — and a face the two pages disagree on (item 4 verification)

    /// [Squeeze it] on the ask: the face leaves its Anchor and is pressed (one undo step). false: no force to press
    /// with — the pad asks, and its answer presses without asking again. ★ On a disagreement (`a.conflict`): a face the
    /// main page RESTS but Settings presses is pressed through its hand at its own weight; one the main page PRESSES but
    /// Settings rests takes the main page's group.
    @discardableResult
    public func squeezeAnchored(_ ask: FlexibleRestsAsk? = nil) -> Bool {
        guard let a = ask ?? restsAsk else { return false }
        if restsAsk?.region == a.region { restsAsk = nil }
        if a.pressedOnMain { return pressLinked(a.region, kg: nil, into: nil) }
        restsConfirmed = a.region
        return pressLinked(a.region, kg: a.kg, into: a.into)
    }

    /// [Keep it resting] — ★ on a disagreement it rests in Settings too, with the main page's Anchor; [It rests] on a
    /// face the main page presses takes it off that group to an Anchor (his choice, one undo step).
    public func keepResting(_ ask: FlexibleRestsAsk? = nil) {
        let a = ask ?? restsAsk
        restsAsk = nil; restsConfirmed = nil
        if let a, a.conflict || a.pressedOnMain { restLinked(a.region) }
    }

    /// ★ (item 4 verification) the faces the two pages disagree on, as an older project was saved — never settled at
    /// restore (nobody is there to ask): Settings presses a face a main-page Anchor rests, or rests one a Load group
    /// presses. Each is listed on the Pending tab and asked in its face's card until he settles it.
    public var disagreements: [FlexibleRestsAsk] {
        let s = settings
        return s.faces.compactMap { f in
            guard f.weightFrom == nil, let e = mainPageLoads.entry(f.faceRegionID), e.role != .ask,
                  (e.role == .pressed) != f.isLoaded else { return nil }
            return FlexibleRestsAsk(region: f.faceRegionID, anchorName: e.groupName, faceName: displayName(f.faceRegionID),
                                    kg: f.isLoaded ? f.weightKg : nil,
                                    into: f.isLoaded ? squeezeGroup(of: f.faceRegionID)?.id : nil,
                                    conflict: true, pressedOnMain: e.role == .pressed)
        }
    }

    /// The ask a face's card shows: the one he raised by pressing, else the disagreement it is in.
    public func ask(for region: Int) -> FlexibleRestsAsk? {
        if let a = restsAsk, a.region == region { return a }
        return disagreements.first { $0.region == region }
    }

    /// The line under a pressed face on no main-page group: the restore left it as saved, or a region that can't split
    /// holds it in a group (it is never in two). nil: it is on the main page.
    public func notOnMainPageLine(_ region: Int) -> String? {
        guard let f = settings.face(region), f.isLoaded, f.weightFrom == nil, mainPageLoads.entry(region) == nil,
              let w = groupWorld() else { return nil }
        if !w.canDetach(region), let n = w.holderName(region) { return FlexibleRowCopy.heldBy(n) }
        return FlexibleRowCopy.notOnMainPage
    }

    // MARK: what the pages show

    /// The main-page Load groups a squeeze group's faces (and presses) are linked to — its hands, in order.
    public func handIDs(_ g: FlexibleSqueezeGroup) -> [UUID] { handIDs(g, in: settings) }

    /// (the settings read once — the main page asks per Selections row, per body pass)
    func handIDs(_ g: FlexibleSqueezeGroup, in s: FlexibleStageSettings) -> [UUID] {
        let force = project.force, groups = Set(project.selection.groups.map(\.id))
        var out: [UUID] = []
        for r in g.regions {
            guard let h = s.face(r)?.weightFrom, !out.contains(h), force.kind(for: h).isLoad, groups.contains(h) else { continue }
            out.append(h)
        }
        for pid in g.presses {
            guard let h = s.press(pid)?.settings.weightFrom, !out.contains(h), force.kind(for: h).isLoad, groups.contains(h) else { continue }
            out.append(h)
        }
        return out
    }

    /// The squeeze group a main-page Load group is a hand of.
    public func squeezeGroup(ofHand id: UUID) -> FlexibleSqueezeGroup? {
        let s = settings
        return FlexibleSqueezeGroups.groups(s).first { handIDs($0, in: s).contains(id) }
    }

    /// A squeeze group's tab title: its one hand's name; with several, "Group N".
    public func railTitle(_ g: FlexibleSqueezeGroup) -> String {
        let s = settings
        let hs = handIDs(g, in: s)
        // its one hand's name only while that hand IS the group (a face of it out of every main-page Load group — moved
        // into a Pending group on the main page, say — makes it "Group N" again)
        if hs.count == 1, g.regions.allSatisfy({ s.face($0)?.weightFrom == hs[0] }), g.presses.isEmpty,
           let n = project.selection.groups.first(where: { $0.id == hs[0] })?.name { return FlexibleRowCopy.fit(n, 14) }
        return FlexibleRowCopy.groupName(g.number)
    }

    /// The main-page Anchor a resting face rests with (its Rests row names it).
    public func restsGroupName(_ region: Int) -> String? {
        guard let f = settings.face(region), !f.isLoaded, let id = f.weightFrom, project.force.kind(for: id).isAnchor else { return nil }
        return project.selection.groups.first { $0.id == id }?.name
    }
}
