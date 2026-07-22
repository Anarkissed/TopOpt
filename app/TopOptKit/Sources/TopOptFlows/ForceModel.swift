// ForceModel.swift — the M7.6 force & gravity data model (MOD-F1 D1–D6).
//
// A faithful port of the force/gravity prototype's state (docs/design/
// TopOpt_force_proto.html: `S`, `setGravity`, `mkAnchor`/`mkLoad`, `loadDir`,
// `fmtW`, the weight scrub, and the `opt`/`hint` sync block) and of the locked
// design decisions in docs/design/MOD_force_gravity_rework.md:
//
//   * D2 — gravity is the outward normal of a tapped "floor" face, stored as a
//     unit vector in MODEL space (survives re-orientation); the model animates
//     so gravity aligns with world −Y (the `settleRotation`).
//   * D3 — a selection group is explicitly an Anchor or a Load (no implicit
//     "arrow-less = anchor" rule). A fresh group is `.pending` until declared.
//   * D4 — a Load spawns along gravity; its direction changes only via the snap
//     row Gravity / Push / Pull.
//   * D5 — weight is stored internally in kgf; the display unit (kg / lbs) is a
//     global toggle. Scrub steps in the display unit.
//   * D6 — arrow convention: if the force points into the face, the tip is at the
//     application point; otherwise the tail is.
//   * D7 — a load's magnitude is a real force (kgf → Newtons) the solver applies
//     as a traction; this model exposes the force vector M7.7 hands the core.
//
// This composes with the M7.5 `SelectionModel` (which owns group identity,
// faces, colour and the pick/steal machine) by keying per-group role/direction/
// weight on the group's `UUID`. It is a pure value type (no SwiftUI, no GPU, no
// bridge), so the whole force/gravity logic is unit-tested headlessly (the M7
// /app/ verification standard); the SwiftUI workspace renders over it.

import Foundation
import simd
import TopOptDesign
import TopOptKit

/// The global weight display unit (design's kg / lbs segment). Storage is always
/// kgf; this only changes presentation and the scrub step.
public enum WeightUnit: String, CaseIterable, Sendable, Codable {
    case kg
    case lbs
    /// The segment button label ("kg" / "lbs").
    public var label: String { rawValue }
}

/// A load's direction affordance (design snap row, D4). The world-space vector is
/// derived from this + the group's face normal via `ForceModel.directionVector`.
public enum LoadDirection: String, CaseIterable, Sendable, Codable {
    case gravity
    case push
    case pull
    /// The snap-row button label ("Gravity" / "Push" / "Pull").
    public var title: String {
        switch self {
        case .gravity: return "Gravity"
        case .push: return "Push"
        case .pull: return "Pull"
        }
    }
}

/// A selection group's role in the load case (design `g.kind`). A group is
/// `.pending` from creation until the user taps Anchor or Load (D3).
public enum GroupKind: Equatable, Sendable, Codable {
    /// Faces selected, role not yet declared (design `kind:'pending'`).
    case pending
    /// A clamped/fixed mounting region (design `kind:'anchor'`).
    case anchor
    /// A loaded region with a direction + weight in kgf (design `kind:'load'`).
    case load(direction: LoadDirection, weightKg: Double)
    /// LEGACY (handoff 100): "Keep clear" used to be a competing role. Keep-clear v2
    /// demotes it to an ATTRIBUTE (`KeepClearAffix`) that rides alongside a group's
    /// real role, so this case is no longer produced — `makeClearance` is gone. It
    /// stays in the enum ONLY so pre-v2 snapshots still DECODE; `ForceModel`'s
    /// decoder migrates any `.clearance` group to a keep-clear-only affix
    /// (role → pending, affix → on). Never set it directly.
    case clearance

    public var isPending: Bool { self == .pending }
    public var isAnchor: Bool { self == .anchor }
    public var isLoad: Bool { if case .load = self { return true }; return false }
    /// LEGACY — true only for a not-yet-migrated pre-v2 snapshot value; new code
    /// asks `ForceModel.keepClearIsOn(_:autoDefault:)` for the attribute instead.
    public var isClearance: Bool { self == .clearance }

    /// The load direction, or nil for pending/anchor.
    public var loadDirection: LoadDirection? {
        if case let .load(direction, _) = self { return direction }
        return nil
    }
    /// The load weight in kgf, or nil for pending/anchor.
    public var weightKg: Double? {
        if case let .load(_, kg) = self { return kg }
        return nil
    }
}

/// Per-group editable overrides of the SUGGESTED clearance distances (mm, handoff
/// 100). The GEOMETRY is derived core-side; these are the judgement-call numbers.
/// A nil field means "use the suggestion" (for a bolt that is the bore radius /
/// diameter, which only the core knows — so an un-overridden bolt margin shows as
/// a suggestion, not a fabricated number). Applied to a group's auto-bolt (anchor
/// groups) or explicit face slab (clearance groups).
public struct ClearanceOverride: Equatable, Sendable, Codable {
    public var concentricMarginMM: Double?
    public var axialClearanceMM: Double?
    public var slabDepthMM: Double?
    public init(concentricMarginMM: Double? = nil, axialClearanceMM: Double? = nil,
                slabDepthMM: Double? = nil) {
        self.concentricMarginMM = concentricMarginMM
        self.axialClearanceMM = axialClearanceMM
        self.slabDepthMM = slabDepthMM
    }
    public var isEmpty: Bool {
        concentricMarginMM == nil && axialClearanceMM == nil && slabDepthMM == nil
    }
}

/// A group's STORED "Keep clear" attribute choice, keyed by group id (keep-clear
/// v2). Absence means "follow the default": an anchored bore auto-gets a bolt
/// clearance (design 095), everything else is clear-free. Only a DEVIATION from
/// that default is stored, so the wire path and empty-clearance parity are
/// untouched — a group with no entry and no auto contributes nothing.
public enum KeepClearAffix: String, Equatable, Sendable, Codable {
    /// The user affixed "Keep clear" to this group (explicit ON) — a plane slab, a
    /// standalone keep-clear-only selection, or an explicit add-on to an anchor/load.
    case on
    /// The user turned OFF an auto (anchored-bore) clearance — an explicit override
    /// that SUPPRESSES that bore's automatic bolt clearance for the run.
    case suppressed
}

/// Face-protection (handoff 124) constants shared by the model + UI.
public enum FaceProtection {
    /// The default global preserve-depth (mm): ~2× the 2.5 mm min-feature size,
    /// mirroring the core's `kFaceProtectionDepthDefaultMm`. Editable per project.
    public static let defaultDepthMM = 5.0
    /// Editable range for the global depth chip (mm) — at least one min-feature,
    /// capped so a stray edit cannot freeze an unreasonable fraction of a part.
    public static let minDepthMM = 1.0
    public static let maxDepthMM = 50.0
}

/// Where an effectively-ON keep-clear came from, for the row's origin label.
public enum KeepClearOrigin: Equatable, Sendable {
    /// Derived from the anchored-bore rule (shown "Auto"); user can toggle it off.
    case auto
    /// The user affixed it explicitly.
    case explicit
}

/// Which step the workspace is in. Setup shows the "which way is down?" prompt and
/// disables Optimize; edit is the normal selection/force state (design `S.phase`).
public enum GravityPhase: Equatable, Sendable, Codable {
    case setup
    case edit
}

/// The force & gravity state layered over the M7.5 `SelectionModel`.
public struct ForceModel: Equatable, Sendable, Codable {

    // MARK: design constants (traced to the prototype)

    /// A new load's default weight (proto group is created with `kg:2.5`).
    public static let defaultWeightKg = 2.5
    /// Weight clamp (proto scrub: `Math.min(500, Math.max(0.1, …))`).
    public static let minWeightKg = 0.1
    public static let maxWeightKg = 500.0
    /// kgf → lb (proto `KG2LB`).
    public static let kgToLb = 2.20462
    /// Standard gravity, kgf → Newtons for the solver traction (D7).
    public static let gravityAccel = 9.80665
    /// Scrub step per point of horizontal drag, in the display unit (proto
    /// `stepKg = unit==='kg' ? 0.05 : 0.05/KG2LB`).
    public static let scrubStepKg = 0.05
    /// The anchor tint (proto `ANCHOR_C = '#30D158'`), for the viewer highlight.
    public static let anchorColor = RGBA(hex: 0x30D158)

    // MARK: state

    /// Gravity as an outward face normal in MODEL space, or nil until set (D2).
    public private(set) var gravity: SIMD3<Float>?
    /// The B-rep face the user tapped as "down" (proto `S.gravityFace`).
    public private(set) var gravityFace: FaceID?
    /// Setup (prompt) vs edit (proto `S.phase`).
    public private(set) var phase: GravityPhase = .setup
    /// The global display unit (proto `S.unit`).
    public var unit: WeightUnit = .kg

    /// Per selection-group role/direction/weight, keyed by `SelectionGroup.id`.
    /// A group with no entry here is `.pending`.
    private var kinds: [UUID: GroupKind] = [:]

    /// Per-group clearance distance overrides (handoff 100). OPTIONAL so snapshots
    /// written before this field still decode (nil → no overrides, all suggestions).
    private var clearanceOverrides: [UUID: ClearanceOverride]? = nil

    /// Per-group "Keep clear" attribute deviations from the default (keep-clear v2).
    /// OPTIONAL + only-deviations-stored: a group absent here follows the auto rule
    /// (anchored bore → on, else off). `.on` = affixed, `.suppressed` = auto turned
    /// off. Snapshots written before v2 decode with this nil; the pre-v2 `.clearance`
    /// ROLE is migrated into this map by the decoder.
    private var keepClear: [UUID: KeepClearAffix]? = nil

    /// Per-GROUP clearance SYNC flag (device round 4, item 3 — corrects round-3's CROSS-group
    /// membership to WITHIN-group scope). A group's several keep-clear bores share margin/axial
    /// when its Sync box is CHECKED; groups NEVER couple to each other. DEFAULT CHECKED, so only
    /// the exclusions (unchecked groups) are stored — a group id absent here is synced.
    ///
    /// Synced (checked): the group edits its ONE shared `clearanceOverrides[group]`, which every
    /// bore of the group reads — so they stay equal (this is the pre-round-4 behaviour and wire).
    /// Unsynced (unchecked): each bore edits its OWN `clearanceBoreOverrides[group:face]` and is
    /// independent. See `setClearance*(group:face:mm:)` for the write split and
    /// `setClearanceSynced(_:_:boreFaces:)` for the adopt-on-check / seed-on-uncheck.
    private var syncExcluded: Set<UUID>? = nil

    /// Per-BORE clearance overrides, used ONLY while a group is UNSYNCED (item 3). Keyed by
    /// `"group.uuidString:faceID"` so it JSON-encodes as a plain object; a bore absent here falls
    /// back to the group's shared override, then to Auto. Optional + only-deviations-stored, so a
    /// project with every group synced (the default) carries none and the on-disk format + wire
    /// are byte-identical to before round 4.
    private var clearanceBoreOverrides: [String: ClearanceOverride]? = nil

    /// Per-group "Protect" attribute (handoff 124 — Face protection / preserve-skin).
    /// A protected group's faces have their OWN part-solid skin frozen so the
    /// optimizer may not touch them (FrozenSolid — the opposite polarity of a
    /// keep-clear FrozenVoid). PURELY EXPLICIT (no auto rule like keep-clear's
    /// anchored-bore default): only groups the user marked Protect are stored, so a
    /// project with no protection carries none and the on-disk format + wire are
    /// byte-identical to before this handoff. `true` = protected; absence = not.
    private var faceProtect: [UUID: Bool]? = nil

    /// The ONE GLOBAL preserve-depth (mm) governing EVERY Face protection in the
    /// project — a single editable number shown once (design 124). The default is
    /// ~2× the min-feature size; the core reads it and floors the derived voxel
    /// depth at 1. Persisted so it round-trips; harmless when no face is protected.
    public var faceProtectDepthMM: Double = FaceProtection.defaultDepthMM

    public init() {}

    /// Whether a gravity direction has been chosen (stays true across re-entering
    /// setup via "Change").
    public var gravityIsSet: Bool { gravity != nil }

    // MARK: - gravity (D2)

    /// Set gravity from the tapped floor-facing face's outward normal. The normal
    /// is normalized and stored in model space; the workspace enters edit
    /// (proto `setGravity`: `S.quat` settles, `S.phase='edit'`).
    public mutating func setGravity(faceNormal normal: SIMD3<Float>, face: FaceID) {
        let n = simd_normalize(normal)
        guard n.x.isFinite, n.y.isFinite, n.z.isFinite else { return }
        gravity = n
        gravityFace = face
        phase = .edit
    }

    /// Re-enter the gravity prompt (design chip's "Change"). Keeps the current
    /// vector until a new face is tapped (proto `gchange`: only `S.phase='gravity'`).
    public mutating func enterGravitySetup() {
        phase = .setup
    }

    /// The rotation that settles the part so gravity points at world −Y (proto
    /// `Q.fromUnit(n,[0,-1,0])`). Nil until gravity is set.
    public var settleRotation: simd_quatf? {
        guard let g = gravity else { return nil }
        return simd_quatf(from: simd_normalize(g), to: SIMD3<Float>(0, -1, 0))
    }

    // MARK: - group role (D3)

    /// The role of a group (default `.pending` for an unknown/undeclared id).
    public func kind(for id: UUID) -> GroupKind { kinds[id] ?? .pending }

    /// Declare a group a fixed Anchor (proto `mkAnchor`).
    public mutating func makeAnchor(_ id: UUID) { kinds[id] = .anchor }

    /// Declare a group a Load: it spawns along gravity with the default weight, or
    /// keeps its existing weight if it was already a load. Re-tapping Load resets
    /// the direction to gravity (proto `mkLoad`: `a.dir='gravity'`).
    public mutating func makeLoad(_ id: UUID) {
        let kg = kinds[id]?.weightKg ?? Self.defaultWeightKg
        kinds[id] = .load(direction: .gravity, weightKg: kg)
    }

    // MARK: - keep-clear attribute (keep-clear v2)

    /// The group's STORED keep-clear deviation (nil = follow the auto default).
    public func keepClearAffix(for id: UUID) -> KeepClearAffix? { keepClear?[id] }

    /// Whether "Keep clear" is EFFECTIVELY on for a group. `autoDefault` is whether
    /// the anchored-bore rule would auto-clear it (the caller supplies it because it
    /// needs the mesh geometry ForceModel does not hold). A stored `.on`/`.suppressed`
    /// overrides the default; absence follows it.
    public func keepClearIsOn(_ id: UUID, autoDefault: Bool) -> Bool {
        switch keepClear?[id] {
        case .on: return true
        case .suppressed: return false
        case nil: return autoDefault
        }
    }

    /// The origin of an effectively-ON keep-clear: `.auto` when it comes from the
    /// default rule (no stored deviation), `.explicit` when the user affixed it.
    public func keepClearOrigin(_ id: UUID) -> KeepClearOrigin {
        keepClear?[id] == nil ? .auto : .explicit
    }

    /// Store a keep-clear deviation for a group (`.on` affix, `.suppressed` override),
    /// or pass nil to REVERT to the auto default. Callers pick the value by comparing
    /// the desired effective state with `autoDefault` so only true deviations persist.
    public mutating func setKeepClearAffix(_ id: UUID, _ affix: KeepClearAffix?) {
        var map = keepClear ?? [:]
        if let a = affix { map[id] = a } else { map[id] = nil }
        keepClear = map.isEmpty ? nil : map
    }

    /// Toggle a group's EFFECTIVE keep-clear to `on`, given whether the auto rule
    /// applies. Stores the minimal deviation: a choice matching the default clears
    /// the override (so the row reverts to "Auto"), a choice against it stores `.on`
    /// or `.suppressed`. This is the single control the affix toggle drives.
    public mutating func setKeepClear(_ id: UUID, on: Bool, autoDefault: Bool) {
        if on == autoDefault { setKeepClearAffix(id, nil) }
        else { setKeepClearAffix(id, on ? .on : .suppressed) }
    }

    /// Groups the user has EXPLICITLY affixed keep-clear to (`.on`). Distinct from the
    /// effective count (which needs geometry for the auto bores — see ProjectModel).
    public func explicitKeepClearCount(in groups: [SelectionGroup]) -> Int {
        groups.filter { keepClear?[$0.id] == .on }.count
    }

    /// Whether a group is a keep-clear-ONLY selection: no anchor/load role, but the
    /// keep-clear attribute affixed. Such a group is a COMPLETE declaration (it does
    /// not block Optimize the way a bare pending group does).
    public func isKeepClearOnly(_ id: UUID) -> Bool {
        kind(for: id).isPending && keepClear?[id] == .on
    }

    // MARK: - Protect attribute (handoff 124 — Face protection / preserve-skin)

    /// Whether the user has affixed "Protect" to a group (its faces' own skin is
    /// preserved FrozenSolid). Purely explicit — absence means not protected.
    public func isProtected(_ id: UUID) -> Bool { faceProtect?[id] == true }

    /// Affix / remove "Protect" on a group. Only ON entries are stored, so removing
    /// it (or setting a group that was never protected) keeps the map minimal and a
    /// protection-free project byte-identical on disk + wire.
    public mutating func setProtected(_ id: UUID, _ on: Bool) {
        var map = faceProtect ?? [:]
        if on { map[id] = true } else { map[id] = nil }
        faceProtect = map.isEmpty ? nil : map
    }

    /// Groups the user has affixed "Protect" to.
    public func protectedGroups(in groups: [SelectionGroup]) -> [SelectionGroup] {
        groups.filter { faceProtect?[$0.id] == true }
    }

    /// How many groups carry a Protect affix (drives the "≥ 1 protection → show the
    /// global depth chip" gate).
    public func explicitProtectCount(in groups: [SelectionGroup]) -> Int {
        groups.filter { faceProtect?[$0.id] == true }.count
    }

    /// Whether a group is a protect-ONLY selection: no anchor/load role, but the
    /// Protect attribute affixed. Like a keep-clear-only group it is a COMPLETE
    /// declaration and does not block Optimize the way a bare pending group does.
    public func isProtectOnly(_ id: UUID) -> Bool {
        kind(for: id).isPending && faceProtect?[id] == true
    }

    // MARK: - clearance overrides (handoff 100)

    /// The editable-distance override for a group (nil-fields → use the suggestion).
    public func clearanceOverride(for id: UUID) -> ClearanceOverride {
        clearanceOverrides?[id] ?? ClearanceOverride()
    }
    private mutating func mutateOverride(_ id: UUID, _ body: (inout ClearanceOverride) -> Void) {
        var map = clearanceOverrides ?? [:]
        var ov = map[id] ?? ClearanceOverride()
        body(&ov)
        if ov.isEmpty { map[id] = nil } else { map[id] = ov }
        clearanceOverrides = map.isEmpty ? nil : map
    }
    /// Override a bolt clearance's concentric margin (mm); pass nil to revert to the
    /// suggestion. Negative values are ignored.
    public mutating func setClearanceMargin(_ id: UUID, mm: Double?) {
        if let v = mm, v < 0 { return }
        mutateOverride(id) { $0.concentricMarginMM = mm }
    }
    /// Override a bolt clearance's axial length (mm); nil reverts to the suggestion.
    public mutating func setClearanceAxial(_ id: UUID, mm: Double?) {
        if let v = mm, v < 0 { return }
        mutateOverride(id) { $0.axialClearanceMM = mm }
    }
    /// Override a face clearance's slab depth (mm); nil reverts to the suggestion.
    public mutating func setClearanceSlab(_ id: UUID, mm: Double?) {
        if let v = mm, v < 0 { return }
        mutateOverride(id) { $0.slabDepthMM = mm }
    }

    // MARK: - per-group clearance sync (device round 4, item 3)

    /// The per-bore override map key ("group:face"), so a bore's independent value survives a
    /// Codable round-trip as a plain string-keyed entry.
    static func boreKey(_ group: UUID, _ face: FaceID) -> String { "\(group.uuidString):\(face)" }

    /// Whether a group's Sync box is CHECKED (its bores share one value). Default checked — a
    /// group with no stored exclusion is synced.
    public func isClearanceSynced(_ group: UUID) -> Bool { !(syncExcluded?.contains(group) ?? false) }

    private mutating func mutateBoreOverride(_ group: UUID, _ face: FaceID,
                                             _ body: (inout ClearanceOverride) -> Void) {
        var map = clearanceBoreOverrides ?? [:]
        let key = Self.boreKey(group, face)
        var ov = map[key] ?? ClearanceOverride()
        body(&ov)
        if ov.isEmpty { map[key] = nil } else { map[key] = ov }
        clearanceBoreOverrides = map.isEmpty ? nil : map
    }

    /// The EFFECTIVE clearance override for one bore of a group, honouring the group's Sync flag:
    /// a synced group reads its shared override (every bore the same); an unsynced group reads the
    /// bore's own override, falling back to the shared value then Auto. This is what the render /
    /// wire and the value chips resolve.
    public func clearanceOverride(forGroup group: UUID, face: FaceID) -> ClearanceOverride {
        if isClearanceSynced(group) { return clearanceOverride(for: group) }
        return clearanceBoreOverrides?[Self.boreKey(group, face)] ?? clearanceOverride(for: group)
    }

    /// Set a bore's concentric margin (mm; nil reverts to Auto). A SYNCED group writes its shared
    /// override so every bore follows; an UNSYNCED group writes only this bore. Negative ignored.
    public mutating func setClearanceMargin(group: UUID, face: FaceID, mm: Double?) {
        if let v = mm, v < 0 { return }
        if isClearanceSynced(group) { setClearanceMargin(group, mm: mm) }
        else { mutateBoreOverride(group, face) { $0.concentricMarginMM = mm } }
    }
    /// Set a bore's axial length (see `setClearanceMargin(group:face:mm:)`).
    public mutating func setClearanceAxial(group: UUID, face: FaceID, mm: Double?) {
        if let v = mm, v < 0 { return }
        if isClearanceSynced(group) { setClearanceAxial(group, mm: mm) }
        else { mutateBoreOverride(group, face) { $0.axialClearanceMM = mm } }
    }
    /// Set a face's slab depth (see `setClearanceMargin(group:face:mm:)`).
    public mutating func setClearanceSlab(group: UUID, face: FaceID, mm: Double?) {
        if let v = mm, v < 0 { return }
        if isClearanceSynced(group) { setClearanceSlab(group, mm: mm) }
        else { mutateBoreOverride(group, face) { $0.slabDepthMM = mm } }
    }

    /// Set a group's Sync flag. `boreFaces` are the group's OWN keep-clear faces (the caller
    /// classifies geometry). WITHIN-group scope only — no other group is ever touched, so two
    /// groups can never cross-talk. Semantics (adopt-on-check, scoped from round 3):
    ///   * UNCHECK → the group's bores become INDEPENDENT; each is SEEDED from the shared value so
    ///     it keeps its current number, then can diverge.
    ///   * RE-CHECK → the bores ADOPT the shared value: their per-bore overrides are dropped, so
    ///     every bore reads the group's shared override (or Auto when it has no edit yet).
    public mutating func setClearanceSynced(_ group: UUID, _ synced: Bool, boreFaces: [FaceID]) {
        var set = syncExcluded ?? []
        if synced {
            set.remove(group)
            syncExcluded = set.isEmpty ? nil : set
            // adopt shared: drop the group's per-bore divergence so bores snap back to the shared value.
            if var map = clearanceBoreOverrides {
                for f in boreFaces { map[Self.boreKey(group, f)] = nil }
                clearanceBoreOverrides = map.isEmpty ? nil : map
            }
        } else {
            let shared = clearanceOverride(for: group)          // capture BEFORE flipping the flag
            set.insert(group)
            syncExcluded = set
            for f in boreFaces { mutateBoreOverride(group, f) { $0 = shared } }
        }
    }

    /// Change a load's direction via the snap row (no-op unless it is a load).
    public mutating func setDirection(_ id: UUID, _ direction: LoadDirection) {
        guard case let .load(_, kg) = kinds[id] else { return }
        kinds[id] = .load(direction: direction, weightKg: kg)
    }

    /// Set a load's weight (kgf), clamped (no-op unless it is a load).
    public mutating func setWeight(_ id: UUID, kg: Double) {
        guard case let .load(dir, _) = kinds[id] else { return }
        kinds[id] = .load(direction: dir, weightKg: clampWeight(kg))
    }

    /// Forget a removed group's role (and any clearance override / keep-clear affix / sync
    /// membership).
    public mutating func clearKind(_ id: UUID) {
        kinds[id] = nil
        if var map = clearanceOverrides { map[id] = nil; clearanceOverrides = map.isEmpty ? nil : map }
        if var map = keepClear { map[id] = nil; keepClear = map.isEmpty ? nil : map }
        if var map = faceProtect { map[id] = nil; faceProtect = map.isEmpty ? nil : map }
        if var set = syncExcluded { set.remove(id); syncExcluded = set.isEmpty ? nil : set }
        pruneBoreOverrides { $0 != id }
    }

    /// Drop per-bore overrides whose owning group id fails `keepGroup` (a removed/absent group).
    private mutating func pruneBoreOverrides(_ keepGroup: (UUID) -> Bool) {
        guard let map = clearanceBoreOverrides else { return }
        let pruned = map.filter { entry in
            guard let g = UUID(uuidString: String(entry.key.prefix(36))) else { return false }
            return keepGroup(g)
        }
        clearanceBoreOverrides = pruned.isEmpty ? nil : pruned
    }

    /// Drop role entries for groups that no longer exist (call after the selection
    /// changes so removed groups don't linger as stale anchors/loads).
    public mutating func sync(groups: [SelectionGroup]) {
        let live = Set(groups.map { $0.id })
        kinds = kinds.filter { live.contains($0.key) }
        if let map = clearanceOverrides {
            let pruned = map.filter { live.contains($0.key) }
            clearanceOverrides = pruned.isEmpty ? nil : pruned
        }
        if let map = keepClear {
            let pruned = map.filter { live.contains($0.key) }
            keepClear = pruned.isEmpty ? nil : pruned
        }
        if let map = faceProtect {
            let pruned = map.filter { live.contains($0.key) }
            faceProtect = pruned.isEmpty ? nil : pruned
        }
        if let set = syncExcluded {
            let pruned = set.intersection(live)
            syncExcluded = pruned.isEmpty ? nil : pruned
        }
        pruneBoreOverrides { live.contains($0) }
    }

    private func clampWeight(_ kg: Double) -> Double {
        Swift.min(Self.maxWeightKg, Swift.max(Self.minWeightKg, kg))
    }

    // MARK: - weight formatting + scrub (D5)

    /// Format a kgf weight in the current display unit (proto `fmtW`: < 10 → one
    /// decimal, ≥ 10 → rounded integer).
    public func formattedWeight(kg: Double) -> String {
        let v = unit == .kg ? kg : kg * Self.kgToLb
        let num = v < 10 ? String(format: "%.1f", v) : String(Int(v.rounded()))
        return "\(num) \(unit.rawValue)"
    }

    /// The weight after scrubbing by `dx` points of horizontal drag, in the current
    /// display unit, clamped (proto scrub handler).
    public func scrub(kg: Double, byPoints dx: Double) -> Double {
        let stepKg = unit == .kg ? Self.scrubStepKg : Self.scrubStepKg / Self.kgToLb
        return clampWeight(kg + dx * stepKg)
    }

    // MARK: - load direction + force (D4, D7)

    /// The world-space unit direction of a load (proto `loadDir`): gravity → world
    /// −Y; push → into the face (−n); pull → away from the face (+n). `groupNormal`
    /// is the group's outward normal in world space (after the settle rotation).
    public static func directionVector(_ direction: LoadDirection,
                                       groupNormal n: SIMD3<Float>) -> SIMD3<Float> {
        switch direction {
        case .gravity: return SIMD3<Float>(0, -1, 0)
        case .push: return -n
        case .pull: return n
        }
    }

    /// A kgf weight as a force magnitude in Newtons (D7, kgf → N).
    public func forceNewtons(kg: Double) -> Double { kg * Self.gravityAccel }

    /// The load's force vector in Newtons (direction × magnitude), or nil if the
    /// group is not a load. This is what M7.7 hands the core traction path.
    public func loadForceVectorNewtons(_ id: UUID, groupNormal n: SIMD3<Float>) -> SIMD3<Float>? {
        guard case let .load(direction, kg) = kinds[id] else { return nil }
        let dir = Self.directionVector(direction, groupNormal: n)
        return dir * Float(forceNewtons(kg: kg))
    }

    /// The load's force vector in the MODEL/grid frame (the frame the voxel grid
    /// and the solver work in), or nil if the group is not a load. Unlike
    /// `loadForceVectorNewtons` (whose gravity case is world −Y, for the settled
    /// arrow render), a `.gravity` load here points along the stored model-space
    /// gravity (the tapped floor normal), so the solver applies the force in the
    /// same coordinates as the part. Push/Pull are the model-space ∓/± face normal.
    /// `groupNormal` must be the group's MODEL-space outward normal.
    public func loadForceVectorModel(_ id: UUID, groupNormal n: SIMD3<Float>) -> SIMD3<Float>? {
        guard case let .load(direction, kg) = kinds[id] else { return nil }
        let raw: SIMD3<Float>
        switch direction {
        case .gravity: raw = gravity ?? SIMD3<Float>(0, 0, -1)
        case .push: raw = -n
        case .pull: raw = n
        }
        let len = simd_length(raw)
        guard len > 1e-6 else { return nil }
        return (raw / len) * Float(forceNewtons(kg: kg))
    }

    /// D6 arrow convention: true when the force points into the face
    /// (`dot(dir, n) < 0`), so the arrow tip is drawn at the application point;
    /// false (pulling/hanging) → tail at the application point (proto `into`).
    public static func arrowTipAtApplicationPoint(direction dir: SIMD3<Float>,
                                                  faceNormal n: SIMD3<Float>) -> Bool {
        simd_dot(dir, n) < -0.001
    }

    // MARK: - counts, optimize enablement + summary

    /// Groups declared as anchors.
    public func anchorCount(in groups: [SelectionGroup]) -> Int {
        groups.filter { kind(for: $0.id).isAnchor }.count
    }
    /// Groups declared as loads.
    public func loadCount(in groups: [SelectionGroup]) -> Int {
        groups.filter { kind(for: $0.id).isLoad }.count
    }
    /// Any group still awaiting a decision: a bare pending group with NO keep-clear
    /// affix AND no Protect affix (a keep-clear-only OR protect-only selection is a
    /// complete declaration and never blocks Optimize — keep-clear v2 / handoff 124).
    public func hasPending(in groups: [SelectionGroup]) -> Bool {
        groups.contains {
            kind(for: $0.id).isPending && !isKeepClearOnly($0.id) && !isProtectOnly($0.id)
        }
    }
    /// Total load weight across all load groups, in kgf.
    public func totalLoadKg(in groups: [SelectionGroup]) -> Double {
        groups.reduce(0) { $0 + (kind(for: $1.id).weightKg ?? 0) }
    }

    /// Whether Optimize is enabled: gravity set (edit phase), ≥1 anchor, ≥1 load,
    /// and no group left pending (proto `ok = L>0 && A>0 && !P && phase==='edit'`).
    public func canOptimize(in groups: [SelectionGroup]) -> Bool {
        phase == .edit
            && anchorCount(in: groups) > 0
            && loadCount(in: groups) > 0
            && !hasPending(in: groups)
    }

    /// Whether Optimize is enabled given the "minimize plastic" toggle: gravity set
    /// (edit phase), no group left pending, AND either minimize-plastic is on (a
    /// self-weight or force-driven REMOVAL run is always possible) or a full force
    /// load case is declared (≥1 anchor + ≥1 load — the off-with-forces case).
    public func canOptimize(in groups: [SelectionGroup], minimizePlastic: Bool) -> Bool {
        guard phase == .edit, !hasPending(in: groups) else { return false }
        if minimizePlastic { return true }
        return anchorCount(in: groups) > 0 && loadCount(in: groups) > 0
    }

    /// The Optimize button's sub-label (proto `opt.innerHTML` sub cascade).
    public func optimizeSummary(in groups: [SelectionGroup]) -> String {
        if phase == .setup { return "set gravity first" }
        if hasPending(in: groups) { return "finish the pending group" }
        let a = anchorCount(in: groups), l = loadCount(in: groups)
        if a == 0 && l == 0 { return "needs an anchor and a load" }
        if a == 0 { return "needs an anchor" }
        if l == 0 { return "needs a load" }
        return "\(a) anchor\(a > 1 ? "s" : "") · \(l) load\(l > 1 ? "s" : "")"
    }

    // MARK: - panel presentation

    /// The Selections-panel "kind" label for a group (proto row `kind`): "Anchor",
    /// "<weight> · <dir>" for a load, or "Pending…".
    public func panelKindLabel(for id: UUID) -> String {
        switch kind(for: id) {
        case .anchor: return "Anchor"
        case let .load(direction, kg): return "\(formattedWeight(kg: kg)) · \(direction.rawValue)"
        case .clearance: return "Keep clear"  // legacy value; migrated away on decode
        case .pending:
            // A keep-clear-only or protect-only selection reads as its attribute,
            // not "Pending…" (both are complete declarations). Keep clear (forbid)
            // takes label precedence when a group somehow carries both.
            if keepClear?[id] == .on { return "Keep clear" }
            if faceProtect?[id] == true { return "Protect" }
            return "Pending…"
        }
    }

    /// The tint a group's faces should render with in the viewer: anchor green for
    /// anchors (proto `a.color=ANCHOR_C`), otherwise the group's own palette colour.
    public func tint(for group: SelectionGroup) -> RGBA {
        kind(for: group.id).isAnchor ? Self.anchorColor : group.color
    }
}

// MARK: - Codable (with pre-v2 keep-clear-role migration)

extension ForceModel {
    private enum CodingKeys: String, CodingKey {
        // Keys match the pre-v2 synthesized coder's property names, so on-disk
        // snapshots keep decoding; `keepClear` is the only new (optional) key.
        case gravity, gravityFace, phase, unit, kinds, clearanceOverrides, keepClear
        case syncClearances         // LEGACY (109 global toggle) — decoded-and-dropped for back-compat
        case syncExcluded           // per-GROUP sync flag exclusions (round 3 → round 4 scope)
        case clearanceBoreOverrides // per-bore overrides for unsynced groups (round 4, item 3)
        case faceProtect            // per-group Protect affix (handoff 124, optional)
        case faceProtectDepthMM     // ONE global preserve-depth in mm (handoff 124, optional)
    }

    public init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        gravity = try c.decodeIfPresent(SIMD3<Float>.self, forKey: .gravity)
        gravityFace = try c.decodeIfPresent(FaceID.self, forKey: .gravityFace)
        phase = try c.decodeIfPresent(GravityPhase.self, forKey: .phase) ?? .setup
        unit = try c.decodeIfPresent(WeightUnit.self, forKey: .unit) ?? .kg
        var decodedKinds = try c.decodeIfPresent([UUID: GroupKind].self, forKey: .kinds) ?? [:]
        clearanceOverrides = try c.decodeIfPresent([UUID: ClearanceOverride].self, forKey: .clearanceOverrides)
        syncExcluded = try c.decodeIfPresent(Set<UUID>.self, forKey: .syncExcluded)
        clearanceBoreOverrides = try c.decodeIfPresent([String: ClearanceOverride].self, forKey: .clearanceBoreOverrides)
        // LEGACY: the 109 global `syncClearances` toggle is gone (per-row membership replaces it).
        // Decode-and-drop the key so pre-round-3 snapshots still load; the intent of a legacy
        // `false` (every site independent) can't be reconstructed without the geometry, so rows
        // open at the default checked and the user sets membership per-row from here.
        _ = try c.decodeIfPresent(Bool.self, forKey: .syncClearances)
        var affixes = try c.decodeIfPresent([UUID: KeepClearAffix].self, forKey: .keepClear) ?? [:]

        // MIGRATION: a pre-v2 `.clearance` ROLE becomes a keep-clear-only affix — the
        // group loses its (competing) role and gains the attribute (role → pending,
        // affix → on). New snapshots never carry `.clearance`, so this is a no-op
        // for them and keep-clear-v2 behaviour is preserved end-to-end.
        for (id, kind) in decodedKinds where kind.isClearance {
            decodedKinds[id] = nil
            if affixes[id] == nil { affixes[id] = .on }
        }
        kinds = decodedKinds
        keepClear = affixes.isEmpty ? nil : affixes
        // Handoff 124 — Face protections (optional keys). Absent in pre-124 snapshots
        // → no protection + the default global depth, so old projects round-trip.
        faceProtect = try c.decodeIfPresent([UUID: Bool].self, forKey: .faceProtect)
        faceProtectDepthMM = try c.decodeIfPresent(Double.self, forKey: .faceProtectDepthMM)
            ?? FaceProtection.defaultDepthMM
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(gravity, forKey: .gravity)
        try c.encodeIfPresent(gravityFace, forKey: .gravityFace)
        try c.encode(phase, forKey: .phase)
        try c.encode(unit, forKey: .unit)
        try c.encode(kinds, forKey: .kinds)
        try c.encodeIfPresent(clearanceOverrides, forKey: .clearanceOverrides)
        try c.encodeIfPresent(syncExcluded, forKey: .syncExcluded)
        try c.encodeIfPresent(clearanceBoreOverrides, forKey: .clearanceBoreOverrides)
        try c.encodeIfPresent(keepClear, forKey: .keepClear)
        // Handoff 124 — only emit protection state when it deviates from the default,
        // so a protection-free project's snapshot is byte-identical to a pre-124 one.
        try c.encodeIfPresent(faceProtect, forKey: .faceProtect)
        if faceProtectDepthMM != FaceProtection.defaultDepthMM {
            try c.encode(faceProtectDepthMM, forKey: .faceProtectDepthMM)
        }
    }
}
