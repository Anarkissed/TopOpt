// FlexiblePress — an ANGLED press, saved with the project (task 2026-10-07, angled presses, batch AP1;
// final spec §4 "The saved press").
//
// ★ WHAT IT IS. A press he aims at an angle: a tilted face press (one region), an EDGE (two connected
// regions) or a CORNER (three or more). It is an INPUT, like a face's settings: nothing here is a frame,
// a column or a design — core computes every one of those (one source of truth: core). Until the bridge
// builds a press's stack (batch AP9) a press is saved and drawn, never sent: core's job carries no
// press_direction before then, and `designInputs` strips the list so a press that cannot be built can
// never change (or stale) the lattice.
//
// ★ WHERE IT LIVES. `FlexibleStageSettings.presses`, an OPTIONAL list that is nil — never [] — when it is
// empty (`setPresses`): synthesized Codable omits a nil, so every project saved before presses decodes
// with none and re-encodes byte-identical (the AP0 subtree goldens), and removing the last press writes
// the file back the way it was. The face list is untouched: no new region, no FlexFaceKey change, and a
// press member is never re-pressed or re-rested as a face by the main page's re-sync
// (FlexibleStageModel.adopt).
//
// ★ ITS FORCE IS ITS SQUEEZE GROUP'S (D2: "ONE CONTROL FOR THE FORCE — the group's header pill"). A press
// is in a squeeze group (`settings.squeezeGroup`, nil ⇒ 1) and never invents a weight. A new press takes
// the first of: (1) the members' main-page Load group, LINKED — the force that group puts through those
// faces, Σ share × the group's weight, BEFORE the main page's at-an-angle cos (the press points along its
// own arrow now); (2) its squeeze group's one force; (3) the pad's answer ("How much weight presses
// here?"). There is no default 10 kg.
//
// ★ TILT AND STRAIGHTEN MOVE ONE STRUCT, INTACT. A tilt moves the pressed face's FlexibleFaceSettings
// into a press (its weight and its link kept; `drawnIn` = the face, the frame its curves and stamp were
// drawn in); straighten moves it back into `faces`. Re-expressing inputs between two of core's frames is
// FlexiblePressReframe.

import Foundation
import simd
import TopOptKit

public struct FlexiblePress: Codable, Equatable, Hashable, Sendable, Identifiable {
    public var id: UUID
    /// 1 region (a tilted face press) or 2+ connected regions (an edge or a corner): whole faces or
    /// declared sectors, in his pick order. Core names the press by regions[0].
    public var regions: [Int]
    /// Model frame, unit, INTO the part: core's press_direction. ALWAYS stated (core's no-direction
    /// default is the AREA-weighted union normal, not the halfway). Stored exactly as given — never
    /// re-normalised here, so a snap that landed bit-exactly on its target stays there.
    public var direction: SIMD3<Double>
    /// The snap it was released on: "halfway" | "face:<region>" | "build" | nil (free). See `Snap`.
    public var snap: String?
    /// Everything else, as a face press saves it (curves, deepest, shape, stamp, squeeze group, weight
    /// and its link): faceRegionID == regions[0], role "loaded", rotationDeg 0.
    public var settings: FlexibleFaceSettings
    /// The straight frame (a face's region) its curves and stamp were drawn in, until core frames the
    /// press (AP9 clears it). nil = drawn in the press's own frame. OPTIONAL, omitted when nil.
    public var drawnIn: Int?

    public init(id: UUID = UUID(), regions: [Int], direction: SIMD3<Double>, snap: String? = nil,
                settings: FlexibleFaceSettings, drawnIn: Int? = nil) {
        self.id = id
        self.regions = regions
        // ★ AP1 TESTS FIRST — RED STUB (the spec's red variant; the next commit replaces it): the direction stored through Float
        self.direction = SIMD3<Double>(SIMD3<Float>(direction))
        self.snap = snap
        var f = settings
        if let r = regions.first { f.faceRegionID = r }
        f.role = "loaded"
        f.rotationDeg = 0
        self.settings = f
        self.drawnIn = drawnIn
    }

    // MARK: derived

    /// tilted (1 region) · edge (2) · corner (3+).
    public enum Kind: String, Equatable, Sendable { case tilted, edge, corner }
    public var kind: Kind { regions.count <= 1 ? .tilted : regions.count == 2 ? .edge : .corner }

    /// The snap, typed (the stored string is the file's form).
    public enum Snap: Equatable, Hashable, Sendable {
        case halfway
        case face(Int)
        case build
        public init?(_ raw: String?) {
            guard let raw else { return nil }
            switch raw {
            case "halfway": self = .halfway
            case "build": self = .build
            default:
                guard raw.hasPrefix("face:"), let r = Int(raw.dropFirst("face:".count)) else { return nil }
                self = .face(r)
            }
        }
        public var raw: String {
            switch self {
            case .halfway: return "halfway"
            case .build: return "build"
            case .face(let r): return "face:\(r)"
            }
        }
    }
    public var snapTarget: Snap? { Snap(snap) }

    /// The squeeze group it is in (stored number; nil ⇒ 1, as a face).
    public var squeezeGroup: Int { settings.squeezeGroup ?? FlexibleSqueezeGroups.first }

    /// "Corner · Top A + Face 3 + Face 2", fitted to one line (`regionName` names a region).
    public func name(_ regionName: (Int) -> String) -> String {
        let head: String
        switch kind {
        case .tilted: head = "Tilted"
        case .edge: head = "Edge"
        case .corner: head = "Corner"
        }
        return FlexibleRowCopy.fit(head + " \u{00B7} " + regions.map(regionName).joined(separator: " + "))
    }

    // MARK: the weight rule (spec §4, D-AP-2) — never an invented weight

    /// Where a new press's force comes from.
    public enum Weight: Equatable, Sendable {
        /// (1) the members' main-page Load group, linked: Σ share × its weight (before the cos).
        case linked(group: UUID, kg: Double)
        /// (2) its squeeze group's one force.
        case force(Double)
        /// (3) nothing to press with: the pad asks "How much weight presses here?".
        case ask
    }

    /// The ONE main-page Load group the members' entries name (a member in no group, or resting in an
    /// Anchor group, names none). nil when they name none — or two different groups (no one force).
    public static func loadGroup(of regions: [Int], loads: FlexibleMainPageLoads) -> UUID? {
        let named = Set(regions.compactMap { r in loads.entry(r).flatMap { $0.role == .rests ? nil : $0.groupID } })
        return named.count == 1 ? named.first : nil
    }

    /// The force main-page group `group` puts through `regions`: Σ share × the group's weight over the
    /// members it holds — BEFORE the at-an-angle cos (FlexibleMainPageLoads' `pressFraction`), because the
    /// press points along its own arrow. nil when the group holds none of them (any more).
    public static func linkedKg(regions: [Int], group: UUID, loads: FlexibleMainPageLoads) -> Double? {
        var kg = 0.0, held = false
        for r in Set(regions) {
            guard let e = loads.entry(r), e.groupID == group, e.role != .rests else { continue }
            kg += e.share * e.groupKg
            held = true
        }
        return held ? kg : nil
    }

    /// The rule, in its order: the link, then the squeeze group's ONE force, then the pad.
    public static func weight(regions: [Int], loads: FlexibleMainPageLoads,
                              groupForce: ClosedRange<Double>?) -> Weight {
        if let g = loadGroup(of: regions, loads: loads), let kg = linkedKg(regions: regions, group: g, loads: loads) {
            return .linked(group: g, kg: kg)
        }
        if let f = groupForce, f.upperBound - f.lowerBound < 0.05, f.upperBound > 0 { return .force(f.upperBound) }
        return .ask
    }

    /// ★ THE RE-SYNC (D-R3-6): every LINKED press takes its group's force through its members again, so a
    /// group edit on the main page (or the squeeze group's pill, which writes the main group) reaches it.
    /// A press whose group no longer holds any member keeps its weight as his own, unlinked — the rule a
    /// face follows (FlexibleMainPageLoads.adopt). `loads` must be the FULL main-page read: the face
    /// re-sync's copy has the press members filtered out.
    public static func adoptWeights(_ loads: FlexibleMainPageLoads, into s: inout FlexibleStageSettings) {
        guard var ps = s.presses else { return }
        for i in ps.indices {
            guard let g = ps[i].settings.weightFrom else { continue }
            if let kg = linkedKg(regions: ps[i].regions, group: g, loads: loads) {
                ps[i].settings.weightKg = kg
            } else {
                ps[i].settings.weightFrom = nil
            }
        }
        if ps != s.presses { s.presses = ps }
    }
}

// MARK: - storage on the settings

extension FlexibleStageSettings {

    /// Write the list: nil, never [], when it is empty (an empty list would change the file of a project
    /// that has none — the nil rule the subtree goldens pin).
    public mutating func setPresses(_ list: [FlexiblePress]) {
        // ★ AP1 TESTS FIRST — RED STUB (the spec's red variant; the next commit replaces it): an empty list is written as []
        presses = list
    }

    public func press(_ id: UUID) -> FlexiblePress? { presses?.first { $0.id == id } }

    /// Replace or add a press (by id).
    public mutating func setPress(_ p: FlexiblePress) {
        var list = presses ?? []
        if let i = list.firstIndex(where: { $0.id == p.id }) { list[i] = p } else { list.append(p) }
        setPresses(list)
    }

    /// Remove a press; the last one leaves the list nil.
    public mutating func removePress(_ id: UUID) {
        guard let list = presses else { return }
        setPresses(list.filter { $0.id != id })
    }

    /// Every region some press holds.
    public var pressRegions: Set<Int> { Set((presses ?? []).flatMap(\.regions)) }

    /// The press holding `region` (the first, if two clash — a clash is never sent, spec §8).
    public func pressHolding(_ region: Int) -> FlexiblePress? { presses?.first { $0.regions.contains(region) } }

    /// ★ TILT: the pressed face `region` becomes a 1-region press, its settings moved INTACT (weight,
    /// link, curves, stamp, group), drawn in its own face's frame. nil (nothing changes): not a pressed
    /// face, or already in a press.
    @discardableResult
    public mutating func tiltFace(_ region: Int, direction: SIMD3<Double>, snap: String?, id: UUID = UUID()) -> UUID? {
        guard let f = face(region), f.isLoaded, pressHolding(region) == nil else { return nil }
        faces.removeAll { $0.faceRegionID == region }
        // ★ AP1 TESTS FIRST — RED STUB (the spec's red variant; the next commit replaces it): the tilt drops the link and the frame
        var g = f; g.weightFrom = nil
        setPress(FlexiblePress(id: id, regions: [region], direction: direction, snap: snap, settings: g))
        FlexibleSqueezeGroups.normalise(&self)
        return id
    }

    /// ★ STRAIGHTEN: a tilted press goes back into `faces`, its settings moved INTACT. false (nothing
    /// changes): not a 1-region press, or the face is in `faces` already (a clash — its own fix).
    /// Inputs drawn in the face's frame (`drawnIn` == the face) need no re-expressing; one drawn in the
    /// press's own frame (only once core frames presses, AP9) is re-expressed there first.
    @discardableResult
    public mutating func straightenPress(_ id: UUID) -> Bool {
        guard let p = press(id), p.kind == .tilted, let region = p.regions.first, face(region) == nil else { return false }
        removePress(id)
        setFace(p.settings)
        FlexibleSqueezeGroups.normalise(&self)
        return true
    }
}
