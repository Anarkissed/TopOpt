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

    public var isPending: Bool { self == .pending }
    public var isAnchor: Bool { self == .anchor }
    public var isLoad: Bool { if case .load = self { return true }; return false }

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

    /// Forget a removed group's role.
    public mutating func clearKind(_ id: UUID) { kinds[id] = nil }

    /// Drop role entries for groups that no longer exist (call after the selection
    /// changes so removed groups don't linger as stale anchors/loads).
    public mutating func sync(groups: [SelectionGroup]) {
        let live = Set(groups.map { $0.id })
        kinds = kinds.filter { live.contains($0.key) }
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
    /// Any group still awaiting an Anchor/Load decision (proto `kind==='pending'`).
    public func hasPending(in groups: [SelectionGroup]) -> Bool {
        groups.contains { kind(for: $0.id).isPending }
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
        case .pending: return "Pending…"
        }
    }

    /// The tint a group's faces should render with in the viewer: anchor green for
    /// anchors (proto `a.color=ANCHOR_C`), otherwise the group's own palette colour.
    public func tint(for group: SelectionGroup) -> RGBA {
        kind(for: group.id).isAnchor ? Self.anchorColor : group.color
    }
}
