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
public struct FlexibleRestsAsk: Equatable, Sendable {
    public let region: Int
    public let anchorName: String
    public let faceName: String
    public let kg: Double?
    public let into: Int?
    public var line: String { FlexibleRowCopy.restsAsk(face: faceName, anchor: anchorName) }
}

/// The links' red controls (tests only).
enum FlexibleGroupLinks {
    /// RED CONTROL: a new main-page Load group joins squeeze group 1 (round 3's adopt).
    nonisolated(unsafe) static var controlOneSqueezeTag = false
    /// RED CONTROL: `designInputs` keeps `weightFrom` (a link alone re-keys the lattice).
    nonisolated(unsafe) static var controlKeepWeightFrom = false
    /// RED CONTROL: the trash leaves the face in its main-page group (round 5 S6's rule).
    nonisolated(unsafe) static var controlKeepMainGroup = false

    /// A name THIS code gives a hand ("Group 2", "Group 2 · Face 4") — renamed when its group's number or hands change.
    static func madeHere(_ name: String) -> Bool {
        name.range(of: #"^Group [0-9]+( · .+)?$"#, options: .regularExpression) != nil
    }
}

extension FlexibleRowCopy {
    /// "Face 0 rests (main page: Bottom)".
    public static func restsAsk(face: String, anchor: String) -> String { "\(face) rests (main page: \(fit(anchor, 16)))" }
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

    init(selection: SelectionModel, force: ForceModel, flexible: FlexibleStageSettings, x: FlexibleMainPageLoads.Expander,
         latticeRoles: Set<UUID>, load: @escaping (Int) -> SIMD3<Double>? = { _ in nil }) {
        self.selection = selection; self.force = force; self.flexible = flexible; self.x = x
        self.latticeRoles = latticeRoles; self.load = load
    }

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
    /// stays, pending, its affixes kept.
    mutating func commit(_ groups: [SelectionGroup]) {
        let wasEmpty = Dictionary(uniqueKeysWithValues: selection.groups.map { ($0.id, Self.isEmpty($0)) })
        var keep: [SelectionGroup] = []
        for g in groups {
            if Self.isEmpty(g), wasEmpty[g.id] == false {
                if hasAffix(g.id) { makePending(g.id) } else { force.clearKind(g.id); continue }
            }
            keep.append(g)
        }
        selection.restore(groups: keep, active: selection.activeGroupID)
    }

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

    /// `r` into group `id` — out of every other group first (a face belongs to one group).
    mutating func attach(_ r: Int, to id: UUID) {
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
    }

    /// A new main-page group (#354's addGroup: its colour cursor), named; the ACTIVE group stays his.
    mutating func newGroup(_ name: String) -> UUID {
        let active = selection.activeGroupID
        let id = selection.addGroup()
        selection.rename(id, to: name)
        selection.restore(groups: selection.groups, active: active)
        return id
    }

    mutating func setWeightFrom(_ r: Int, _ id: UUID?) {
        guard var f = flexible.face(r), f.weightFrom != id else { return }
        f.weightFrom = id
        flexible.setFace(f)
    }

    // MARK: linking

    /// Link pressed Flexible face `r` (squeeze group `gid`, stored) to its hand — found, taken or made (the order is in
    /// the file comment). nil: a main-page Load group holds it without pressing it (a pull, a shear — his to settle there).
    @discardableResult
    mutating func linkPressed(_ r: Int, squeeze gid: Int, kg: Double) -> UUID? {
        let l = loads()
        if let e = l.entry(r) {
            if e.role == .pressed { setWeightFrom(r, e.groupID); return e.groupID }
            if force.kind(for: e.groupID).isLoad { return nil }
        }
        for g in holders(r) where force.kind(for: g.id).isPending {
            let ms = members(g)
            guard ms.allSatisfy({ $0 == r || (pressed($0, in: gid) && sameFacing($0, r)) }) else { continue }
            force.makeLoad(g.id); force.setDirection(g.id, .push); force.setWeight(g.id, kg: kg)
            for m in ms { setWeightFrom(m, g.id) }
            return g.id
        }
        if let h = hands(ofSqueeze: gid).first(where: { sameSide(r, $0) }) {
            attach(r, to: h); setWeightFrom(r, h)
            return h
        }
        let id = newGroup(FlexibleRowCopy.groupName(gid))
        force.makeLoad(id); force.setDirection(id, .push); force.setWeight(id, kg: kg)
        attach(r, to: id); setWeightFrom(r, id)
        return id
    }

    /// Link resting Flexible face `r` to an Anchor: the one that holds it; a role-less group holding only faces that rest
    /// (it becomes the Anchor); else the first Anchor group; else a new "Rests".
    @discardableResult
    mutating func linkResting(_ r: Int) -> UUID {
        if let e = loads().entry(r), e.role == .rests { setWeightFrom(r, e.groupID); return e.groupID }
        for g in holders(r) where force.kind(for: g.id).isPending {
            let ms = members(g)
            guard ms.allSatisfy({ flexible.face($0).map { !$0.isLoaded } ?? false }) else { continue }
            force.makeAnchor(g.id)
            for m in ms { setWeightFrom(m, g.id) }
            return g.id
        }
        let anchor: UUID
        if let a = selection.groups.first(where: { force.kind(for: $0.id).isAnchor })?.id { anchor = a }
        else { anchor = newGroup("Rests"); force.makeAnchor(anchor) }
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
                        attach(f.faceRegionID, to: hs[i]); setWeightFrom(f.faceRegionID, hs[i])
                    }
                    hs.remove(at: j)
                } else { j += 1 }
            }
            i += 1
        }
    }

    /// The Flexible faces re-read from the groups (the adopt every open runs — its own squeeze tag for a new Load group).
    @discardableResult
    mutating func readopt() -> [Int: Double] { FlexibleStageModel.adopt(loads(), into: &flexible) }

    /// Each hand named here follows its group: "Group N" alone, "Group N · Face X" among several.
    mutating func renameHands() {
        for g in FlexibleSqueezeGroups.groups(flexible) {
            let hs = hands(ofSqueeze: g.id)
            for h in hs {
                guard let sg = group(h), FlexibleGroupLinks.madeHere(sg.name) else { continue }
                let faces = flexible.loadedFaces.filter { $0.weightFrom == h }.map { name($0.faceRegionID) }
                let want = hs.count == 1 ? FlexibleRowCopy.groupName(g.number) : FlexibleRowCopy.handName(number: g.number, faces: faces)
                if sg.name != want { selection.rename(h, to: want) }
            }
        }
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
            var f = w.flexible.face(region) ?? FlexibleFaceSettings(faceRegionID: region)
            f.role = "loaded"
            f.squeezeGroup = gid == FlexibleSqueezeGroups.first ? nil : gid
            if let e = inherited { f.weightKg = e.weightKg; f.weightFrom = e.groupID } else { f.weightKg = kgUse ?? f.weightKg; f.weightFrom = nil }
            w.flexible.setFace(f)
            if inherited != nil {
                FlexibleSqueezeGroups.move(region, to: gid, hand: hand, in: &w.flexible)
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
                var f = w.flexible.face(r) ?? FlexibleFaceSettings(faceRegionID: r, role: "resting")
                f.role = "resting"; f.weightFrom = id
                w.flexible.setFace(f)
            }
            FlexibleSqueezeGroups.normalise(&w.flexible)
        }
        if let r = p.regions.first { selectedRegion = r }
    }

    // MARK: the anchored face's ask

    /// [Squeeze it] on the ask: the face leaves its Anchor and is pressed (one undo step). false: no force to press
    /// with — the pad asks, and its answer presses without asking again.
    @discardableResult
    public func squeezeAnchored() -> Bool {
        guard let a = restsAsk else { return false }
        restsAsk = nil
        restsConfirmed = a.region
        return pressLinked(a.region, kg: a.kg, into: a.into)
    }

    /// [Keep it resting].
    public func keepResting() { restsAsk = nil; restsConfirmed = nil }

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
        let hs = handIDs(g)
        if hs.count == 1, let n = project.selection.groups.first(where: { $0.id == hs[0] })?.name { return FlexibleRowCopy.fit(n, 14) }
        return FlexibleRowCopy.groupName(g.number)
    }

    /// The main-page Anchor a resting face rests with (its Rests row names it).
    public func restsGroupName(_ region: Int) -> String? {
        guard let f = settings.face(region), !f.isLoaded, let id = f.weightFrom, project.force.kind(for: id).isAnchor else { return nil }
        return project.selection.groups.first { $0.id == id }?.name
    }
}
