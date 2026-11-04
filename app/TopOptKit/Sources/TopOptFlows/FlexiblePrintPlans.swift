// FlexiblePrintPlans — B9 (#362), the Print plan's saved settings and its rules (app-map §3.7 "Print plan page", flow §4.8;
// ledger round 2 J-1…J-8, J-A, J-S; plan.md B9: "Plans: a list of named plans in FlexibleStageSettings. Each holds its cuts, a
// joint per seam, places, add-ons and built state. Nothing is made beyond the app's cut.").
//
// ★ nil IN FlexibleStageSettings = TODAY'S BYTES: an old project reads as no plan, and the page starts from the app's cut as a
// fresh Plan A (plan.md B9 › Risks). A plan is about the WHOLE model: how it is cut into pieces and how each seam is held.
// ★ FRONT END FIRST (his 11-03 answer: "Get the entirety of the look through ASAP even if pieces need the new engine work"): the
// pieces, seams, joints and add-ons are chosen and kept here; cutting the body, the joint geometry, the per-plan rebuild and the
// N-body export are engine work (E5: 53, 54, 55, 58, 62, 63). Until it lands the job sent to core stays as today, nothing here
// claims a result, and the page says so in one plain line where a result would show.

import Foundation

/// One seam's two materials (the joints it can take follow from them).
public enum FlexibleSeamKind: String, Codable, Equatable, Sendable {
    case tpuRigid, rigidRigid, tpuTpu
}

/// A way a seam is held ("Held by ⌄"), with what it is in a few words and the family that decides its card's rows.
public struct FlexibleJoint: Equatable, Sendable {
    public enum Family: Equatable, Sendable { case together, slide, flange, pause, fixed, one }
    public let name: String
    public let what: String
    public let family: Family
}

public struct FlexiblePrintPlan: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    /// "Plan A", "Plan B" … (Rename changes it).
    public var name: String
    /// Seam key → the joint's name (Held by). A seam with none needs one before Build.
    public var joints: [String: String] = [:]
    /// Seam key → its TPU plate (mm); 2.0 until set (J-S).
    public var plateMM: [String: Double] = [:]
    /// Add-on keys switched off (each is on by default once its joint calls for it).
    public var addOnsOff: [String] = []
    /// Seam key → the back place's thin wall answered with "Use a flange".
    public var flangeBack: [String] = []
    /// Built with its joints (the engine's per-plan rebuild sets it; nothing in the app does yet).
    public var built = false
    /// ★ B9 slice 3: the cuts he placed (+ Cut ⌄). Their pieces and seams come from the engine's cut (E5 item 62): until it
    /// lands a cut is kept and listed, and it adds no piece. OPTIONAL (decoded when missing): a plan saved before this field
    /// still reads — a field added later to a saved type must always be optional (a project that fails to decode is dropped).
    public var cuts: [FlexiblePlanCut]?

    public init(id: UUID = UUID(), name: String) { self.id = id; self.name = name }
}

public struct FlexiblePrintPlans: Codable, Hashable, Sendable {
    public var plans: [FlexiblePrintPlan]
    public var current: UUID
    /// The rigid plastic of the solid areas (J-2: "PLA · from New part"); nil = one material, the solid areas print in TPU.
    public var rigidMaterial: String?
    /// Skin and rim: printed in the rigid plastic (true) or TPU (false). Two materials only.
    public var skinRigid = false

    /// A fresh Plan A from the app's cut (J-5: no plan is made for you beyond the app's own cut).
    public static func fresh(rigidMaterial: String? = nil) -> FlexiblePrintPlans {
        let a = FlexiblePrintPlan(name: FlexiblePrintPlanRules.planName(0))
        return FlexiblePrintPlans(plans: [a], current: a.id, rigidMaterial: rigidMaterial)
    }

    public var plan: FlexiblePrintPlan {
        get { plans.first { $0.id == current } ?? plans[0] }
        set { if let i = plans.firstIndex(where: { $0.id == current }) { plans[i] = newValue } else { plans[0] = newValue } }
    }
}

/// ★ B9 slice 3 (round 3: SIX ways; Draw on the part folded into Draw on a plane): how a cut is made (+ Cut ⌄).
public enum FlexibleCutWay: String, Codable, CaseIterable, Hashable, Sendable {
    case plane, curve, shape, offset, edges, keyed
    public var title: String {
        switch self {
        case .plane: return "A plane"
        case .curve: return "Draw on a plane"
        case .shape: return "A shape"
        case .offset: return "Offset from a face"
        case .edges: return "Along the part\u{2019}s edges"
        case .keyed: return "Keyed step cut"
        }
    }
    public var sub: String {
        switch self {
        case .plane: return "pick a plane; move, tilt, rotate"
        case .curve: return "Pencil or spline; cuts straight through"
        case .shape: return "box, cylinder or ball: inside is a piece"
        case .offset: return "follows a face at a set depth"
        case .edges: return "tap an edge loop"
        case .keyed: return "pick a plane; the pieces line up"
        }
    }
    /// P7 / P8: a cut that is placed or drawn starts from a plane.
    public var planeFirst: Bool { self == .plane || self == .curve || self == .keyed }
    /// Drawn ON its plane (the view turns straight at it); otherwise placed (the view turns edge-on).
    public var drawn: Bool { self == .curve }
}

/// The plane a cut starts from (P8: Top · Front · Side · A face you tap).
public enum FlexiblePlaneBase: String, Codable, CaseIterable, Hashable, Sendable {
    case top, front, side, face
    public var title: String {
        switch self { case .top: return "Top"; case .front: return "Front"; case .side: return "Side"; case .face: return "A face" }
    }
    public var sub: String {
        switch self {
        case .top: return "flat, like the build plate"
        case .front: return "upright, facing you"
        case .side: return "upright, end on"
        case .face: return "tap a flat face"
        }
    }
    public var chip: String { self == .face ? "On a face" : "\(title) plane" }
}

/// One cut as he placed it: its way, its plane (base, Move along its normal, Tilt = how far it leans, Rotate = which way),
/// and the key's size for a keyed cut.
public struct FlexiblePlanCut: Codable, Hashable, Sendable {
    public var way: FlexibleCutWay
    public var base: FlexiblePlaneBase
    public var offsetMM: Double
    public var tiltDeg: Double
    public var rotateDeg: Double
    public var keyMM: Double
    public init(way: FlexibleCutWay, base: FlexiblePlaneBase = .side, offsetMM: Double = 0, tiltDeg: Double = 0,
                rotateDeg: Double = 0, keyMM: Double = 4) {
        self.way = way; self.base = base; self.offsetMM = offsetMM; self.tiltDeg = tiltDeg; self.rotateDeg = rotateDeg
        self.keyMM = keyMM
    }
}

/// A piece of the plan (the app's cut: the lattice apart from the solid).
public struct FlexiblePlanPiece: Equatable, Sendable {
    public let key: String
    public let name: String
    public let tpu: Bool
    /// "varioShore TPU", "PLA".
    public let material: String
}

/// A seam: one place two pieces meet, with its own joint.
public struct FlexiblePlanSeam: Equatable, Sendable {
    public let key: String
    public let name: String
    public let kind: FlexibleSeamKind
}

/// An add-on: an extra piece printed in the rigid plastic, called for by a seam's joint (R8.4, J-3).
public struct FlexiblePlanAddOn: Equatable, Sendable {
    public let key: String
    public let name: String
    public let what: String
}

public enum FlexiblePrintPlanRules {
    /// "Plan A" … "Plan Z", then "Plan 27" …
    public static func planName(_ i: Int) -> String {
        i < 26 ? "Plan " + String(UnicodeScalar(UInt8(65 + i))) : "Plan \(i + 1)"
    }

    /// The next free plan name.
    public static func nextName(_ plans: [FlexiblePrintPlan]) -> String {
        let taken = Set(plans.map(\.name))
        var i = 0
        while taken.contains(planName(i)) { i += 1 }
        return planName(i)
    }

    /// The rigid plastics offered for the solid areas (Only PLA has tested joint data with TPU: the (i) says so).
    public static let rigidMaterials = ["PLA", "PETG", "ABS", "ASA", "PA-CF"]

    /// The pieces of the app's cut. One material: the whole part (its solid areas print in TPU too). Two: the lattice apart
    /// from the solid body.
    public static func pieces(_ p: FlexiblePrintPlans?, tpuName: String) -> [FlexiblePlanPiece] {
        guard let rigid = p?.rigidMaterial else { return [FlexiblePlanPiece(key: "whole", name: "Whole part", tpu: true, material: tpuName)] }
        return [FlexiblePlanPiece(key: "lattice", name: "Lattice", tpu: true, material: tpuName),
                FlexiblePlanPiece(key: "body", name: "Body", tpu: false, material: rigid)]
    }

    /// The seams of the app's cut: none with one material; the lattice ↔ body with two.
    public static func seams(_ p: FlexiblePrintPlans?) -> [FlexiblePlanSeam] {
        guard p?.rigidMaterial != nil else { return [] }
        return [FlexiblePlanSeam(key: "lattice-body", name: "Lattice \u{2194} Body", kind: .tpuRigid)]
    }

    /// Held by ⌄, per seam kind (app-map §3.7; T-slot is the suggested TPU ↔ rigid joint).
    public static func joints(_ kind: FlexibleSeamKind) -> [FlexibleJoint] {
        switch kind {
        case .tpuRigid:
            return [FlexibleJoint(name: "Printed together", what: "two-head printer", family: .together),
                    FlexibleJoint(name: "T-slot", what: "suggested \u{00B7} slides in", family: .slide),
                    FlexibleJoint(name: "Dovetail", what: "slides in", family: .slide),
                    FlexibleJoint(name: "Flange", what: "rigid lip + screwed ring", family: .flange),
                    FlexibleJoint(name: "Insert", what: "the TPU print pauses", family: .pause),
                    FlexibleJoint(name: "Capture", what: "the rigid print pauses", family: .pause)]
        case .rigidRigid:
            return [FlexibleJoint(name: "Keyed", what: "the cut lines them up", family: .fixed),
                    FlexibleJoint(name: "Pins", what: "printed pins", family: .fixed),
                    FlexibleJoint(name: "Screws", what: "printed bosses", family: .fixed),
                    FlexibleJoint(name: "Glue", what: "flat faces", family: .fixed)]
        case .tpuTpu:
            return [FlexibleJoint(name: "Printed as one", what: "no seam in the print", family: .one),
                    FlexibleJoint(name: "Glue", what: "TPU cement", family: .fixed)]
        }
    }

    public static func joint(_ name: String?, kind: FlexibleSeamKind) -> FlexibleJoint? {
        name.flatMap { n in joints(kind).first { $0.name == n } }
    }

    /// The seams still waiting for a joint (Build stays grey with one fix chip for the first).
    public static func needing(_ p: FlexiblePrintPlans?) -> [FlexiblePlanSeam] {
        guard let p else { return seams(nil) }
        return seams(p).filter { p.plan.joints[$0.key] == nil }
    }

    /// The add-ons the plan's joints call for (on unless switched off).
    public static func addOns(_ p: FlexiblePrintPlans?) -> [FlexiblePlanAddOn] {
        guard let p else { return [] }
        var out: [FlexiblePlanAddOn] = []
        for s in seams(p) {
            switch p.plan.joints[s.key] {
            case "T-slot", "Dovetail":
                out += [FlexiblePlanAddOn(key: "\(s.key)/lock-1", name: "Lock key 1", what: "behind the lower slot"),
                        FlexiblePlanAddOn(key: "\(s.key)/lock-2", name: "Lock key 2", what: "behind the upper slot")]
                if p.plan.flangeBack.contains(s.key) {
                    out.append(FlexiblePlanAddOn(key: "\(s.key)/flange-ring", name: "Flange ring", what: "holds the back"))
                }
            case "Flange": out.append(FlexiblePlanAddOn(key: "\(s.key)/screwed-ring", name: "Screwed ring", what: "holds the flange down"))
            case "Insert": out.append(FlexiblePlanAddOn(key: "\(s.key)/insert-plate", name: "Insert plate", what: "the TPU prints through it"))
            case "Capture": out.append(FlexiblePlanAddOn(key: "\(s.key)/retainer", name: "Slide-in retainer", what: "instead of a printed lip"))
            case "Pins": out += [FlexiblePlanAddOn(key: "\(s.key)/pin-1", name: "Pin 1", what: "across the cut"),
                                 FlexiblePlanAddOn(key: "\(s.key)/pin-2", name: "Pin 2", what: "across the cut")]
            default: break
            }
        }
        return out
    }

    /// The TPU plate a seam's joint grips (J-S): 2.0 mm until set.
    public static let defaultPlateMM = 2.0
    public static let plateRange: ClosedRange<Double> = 1.0...6.0

    /// Every plan the Export sheet offers, with whether it is built ("Plan A built │ Plan B not built", round 3 P4).
    public static func exportChoices(_ p: FlexiblePrintPlans) -> [(id: UUID, name: String, built: Bool)] {
        p.plans.map { ($0.id, $0.name, $0.built) }
    }
}
