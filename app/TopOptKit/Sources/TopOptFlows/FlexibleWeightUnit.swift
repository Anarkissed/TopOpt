// FlexibleWeightUnit — the unit the Flexible Settings page shows its weights in (task
// 2026-09-29-flexible-screens, round 5 batch S4; his img 2: "Allow for a change of weight input:
// kg/lb/newtons/etc.").
//
// ★ STORAGE NEVER CHANGES. Every weight is stored in kgf, as ForceModel stores the main page's
// (its D5) and FlexibleFaceSettings.weightKg always has. The unit is a way of READING and TYPING
// that number: a box shows kgf converted, a value typed in the box is converted back to kgf before
// it is written (to the face, or back to the main page's Load group — one source of truth). The
// conversions are exact inverses in Double (kg ↔ lb by the international pound 0.45359237 kg;
// kg ↔ N by standard gravity 9.80665 m/s², FlexibleUnits), so kg → N → lb → kg round-trips.
// ★ ITS OWN ENUM, not a case on ForceModel.WeightUnit (main's kg / lbs display enum): the main
// page's unit is untouched; this one is per project, in FlexibleStageSettings.weightUnit.

import Foundation

public enum FlexibleWeightUnit: String, CaseIterable, Codable, Sendable, Identifiable {
    case kg, lb, N, kN

    public var id: String { rawValue }

    /// The international avoirdupois pound (kg).
    public static let kgPerPound = 0.45359237

    /// The unit as the box shows it.
    public var label: String {
        switch self {
        case .kg: return "kg"
        case .lb: return "lb"
        case .N: return "N"
        case .kN: return "kN"
        }
    }

    /// kgf → this unit.
    public func fromKg(_ kg: Double) -> Double {
        switch self {
        case .kg: return kg
        case .lb: return kg / Self.kgPerPound
        case .N: return kg * FlexibleUnits.standardGravity
        case .kN: return kg * FlexibleUnits.standardGravity / 1000
        }
    }

    /// This unit → kgf (the stored number).
    public func toKg(_ v: Double) -> Double {
        switch self {
        case .kg: return v
        case .lb: return v * Self.kgPerPound
        case .N: return v / FlexibleUnits.standardGravity
        case .kN: return v * 1000 / FlexibleUnits.standardGravity
        }
    }

    /// One scrub step in this unit (the box's up / down drag): about 0.1–0.5 kgf each.
    public var step: Double {
        switch self {
        case .kg: return 0.5
        case .lb: return 1
        case .N: return 5
        case .kN: return 0.005
        }
    }

    /// Decimals the box shows (a typed value keeps more; the box rounds only what it SHOWS).
    public var decimals: Int {
        switch self {
        case .kg, .lb: return 1
        case .N: return 0
        case .kN: return 3
        }
    }

    /// "10 kg" · "22 lb" · "98 N" · "0.098 kN" — trailing zeros dropped (the rows' text).
    public func text(kg: Double) -> String {
        "\(Self.number(fromKg(kg), decimals: decimals)) \(label)"
    }

    /// A number rounded to `decimals`, trailing zeros dropped ("10", "10.5", "0.098").
    public static func number(_ v: Double, decimals: Int) -> String {
        guard v.isFinite else { return "—" }
        let p = pow(10, Double(max(0, decimals)))
        let r = (v * p).rounded() / p
        if decimals <= 0 || abs(r - r.rounded()) < 0.5 / p { return String(Int(r.rounded())) }
        var s = String(format: "%.\(decimals)f", r)
        while s.hasSuffix("0") { s.removeLast() }
        if s.hasSuffix(".") { s.removeLast() }
        return s
    }

    /// The stored value's unit (nil / unknown ⇒ kg).
    public init(stored: String?) {
        self = stored.flatMap(FlexibleWeightUnit.init(rawValue:)) ?? .kg
    }
}

extension FlexibleStageModel {

    /// ★ S4: the unit the page's weight boxes show (per project; kg until he picks another).
    public var weightUnit: FlexibleWeightUnit { FlexibleWeightUnit(stored: settings.weightUnit) }

    /// ★ S4: switch every weight box's unit. Display only — nothing is re-designed, the lattice
    /// stays current (`designInputs` leaves it out), the stored kgf are untouched.
    public func setWeightUnit(_ u: FlexibleWeightUnit) {
        edit({ s in s.weightUnit = u == .kg ? nil : u.rawValue }, recompute: false)
    }

    /// A weight as the page says it now ("10 kg", "22 lb").
    public func weightText(_ kg: Double) -> String { weightUnit.text(kg: kg) }
}
