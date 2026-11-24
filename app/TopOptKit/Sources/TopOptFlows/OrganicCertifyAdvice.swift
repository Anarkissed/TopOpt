// OrganicCertifyAdvice — ★ his notes 11-23 on the certify wizard's pop-ups (notes25 B4): "the fix pop-up only said to use
// thicker struts, but it didn't say what thickness to try. I'd prefer if there was specificity in the response. If it requires
// a thicker strut, check the current strut thickness and recommend a manual range or single thickness to use. This should be on
// ALL fix notifications."
//
// Every pop-up that asks for a change names the setting, its value now and a value (or a tight range) to try — from the
// result's own numbers and the settings as they stand; nothing invented. ONE RULE PER KIND (said in plain words on the card):
//   * Struts still short → Strut thickness. d_new = d_now × √(needed ÷ holds): area scaling, the conservative case (bending
//     would need less). A range scales both ends alike. Each value is rounded UP to the field's step (one printed line: the
//     field snaps what is typed to it) and goes up by at least 0.1 mm. Past the field's 50 mm: said plainly, and smaller cells
//     are the next step. Auto's numbers are the ones the field shows greyed; with none measured, the factor is said.
//   * A weak area of the solid (beside the lattice, beside a fixing, where the load presses, inside the solid) → its thickness:
//     × √(needed ÷ holds) (strength in bending grows with the square of the thickness), rounded up to the next 0.1×. Beside
//     the lattice that thickness is the solid kept between the lattice and the surface (a deeper Protect skin or a keep-clear).
//   * Infill → the lowest infill the check found that passes (core's number), against the infill now.
//   * The load on open lattice → the loaded face's Protect: off now, on to try (no number exists).
//   * Nothing carries the load → no setting holds the answer: no line (the card's text says why).
// The words live in `OrganicCertifyCopy`, one place (the strength numbers' wording may still change: a one-line change).
import Foundation

/// What one pop-up tells him to change: the setting (nil: a change to the part itself) and the one line that says it.
public struct OrganicCertifyAdvice: Equatable, Sendable {
    public var setting: String?
    public var line: String
    /// What to try, five words at most (the field's own note on the settings page: SettingToChange).
    public var tryText: String
    public init(setting: String?, line: String, tryText: String = "") { self.setting = setting; self.line = line; self.tryText = tryText }

    /// ★ notes25 B6: Solve's way to the field — the ONE way "Change settings" takes (`openSettingToChange`); nil: no field on a
    /// settings page holds this fix (the faces' selections, the model, or infill, which Solve sets itself).
    public func settingToChange(group: UUID?) -> SettingToChange.Ask? {
        guard let s = setting, SettingToChange.organicFields.contains(s) else { return nil }
        return SettingToChange.Ask(page: .lattice, field: s, tryText: tryText, group: group)
    }
}

/// ★ The wizard's words, in ONE place.
public enum OrganicCertifyCopy {
    /// A margin as the check reads it: two decimals ("1.34×") — the strength answer's own words (StrengthWords, builder C).
    public static func margin(_ m: Double) -> String { StrengthWords.x(m) }
    /// What it needs: "1.5×".
    public static func needs(_ s: Double) -> String { StrengthWords.need(s) }
    /// The field's note: "Try 1.8 to 3.15 mm" (five words at most).
    static func tryRange(_ lo: Double, _ hi: Double, single: Bool) -> String { "Try " + range(lo, hi, single: single) }
    /// A length as the setting's field shows it ("2.25", "2.7").
    public static func mm(_ v: Double) -> String { StrengthCheckDocs.number((v * 1000).rounded() / 1000) }
    static func range(_ lo: Double, _ hi: Double, single: Bool) -> String {
        single || abs(lo - hi) < 1e-9 ? "\(mm(hi)) mm" : "\(mm(lo)) to \(mm(hi)) mm"
    }

    /// ★ notes25 B7: the struts card's sentence — the rounds that ADDED material (core's `rounds_fixed`, the Checks panel's own
    /// number), never the checks.
    public static func strutsShort(holds: Double, rounds: Int?, needs s: Double) -> String {
        let after = rounds.map { " after \($0 == 1 ? "1 round" : "\($0) rounds") of strengthening" } ?? ""
        return "The weakest strut holds \(margin(holds)) your load\(after); it needs \(needs(s))."
    }

    /// "Strut thickness is 1.35 to 2.7 mm. Try 1.8 to 3.15 mm." (`group`: the group's name when the part has several.)
    static func strutTry(now: OrganicCertifyAdvice.StrutNow, lo: Double, hi: Double, group: String?) -> String {
        let name = group.map { "\($0): strut thickness" } ?? "Strut thickness"
        let shown = range(now.light, now.heavy, single: now.single)
        let want = range(lo, hi, single: now.single)
        if now.auto {
            return "\(name) is Auto, \(shown). Set \(now.single ? "Manual" : "Manual Sweep"): \(want)."
        }
        return "\(name) is \(shown). Try \(want)."
    }
    static func strutPastMax(needMM: Double, maxMM: Double) -> String {
        "Struts would need " + String(format: "%.2f", needMM) + " mm, past the \(mm(maxMM)) mm the field takes. Use smaller cells instead."
    }
    static func strutUnmeasured(percent: Int) -> String {
        "Strut thickness is Auto, not measured yet. Set Manual Sweep about \(percent)% thicker at both ends."
    }
    static func solidThicker(holds: Double, needs s: Double, factor: Double, where w: String) -> String {
        "This area holds \(margin(holds)) of the \(needs(s)) it needs. Make the solid \(w) about "
            + String(format: "%.1f\u{00D7}", factor) + " as thick."
    }
    static func infill(now: Int, passes: Int) -> String { "Infill is \(now)% now. \(passes)% passes." }
    static let protect = "The loaded face is open lattice now. Set it to Protect."
}

extension OrganicCertifyAdvice {
    /// The strut thickness in force, as its field shows it: one number, or a range's thin and thick ends (light ≤ heavy).
    public struct StrutNow: Equatable, Sendable {
        public var light: Double
        public var heavy: Double
        public var single: Bool
        /// Auto's numbers (the field greyed): the advice says which mode to type them in.
        public var auto: Bool
        public init(light: Double, heavy: Double, single: Bool, auto: Bool) {
            self.light = light; self.heavy = heavy; self.single = single; self.auto = auto
        }
    }

    /// What the advice reads besides the result: the settings as they stand.
    public struct Context: Equatable, Sendable {
        /// The strut thickness of the group the advice is about (nil: Auto, not measured yet).
        public var strut: StrutNow?
        /// That group's name when the part has several lattice groups (the line says whose); nil: one, or the whole part.
        public var group: String?
        /// The group the strut field belongs to (nil: the whole part's), for Solve.
        public var groupID: UUID?
        /// The strut field's step (one printed line).
        public var stepMM: Double
        public var infillNow: Int
        public init(strut: StrutNow?, group: String? = nil, groupID: UUID? = nil, stepMM: Double, infillNow: Int) {
            self.strut = strut; self.group = group; self.groupID = groupID; self.stepMM = stepMM; self.infillNow = infillNow
        }
    }

    // MARK: the rules

    /// ★ B4: struts — the area-scaling factor, √(needed ÷ holds).
    public static func strutFactor(holds: Double, needs: Double) -> Double {
        guard holds > 0, needs > holds else { return 1 }
        return (needs / holds).squareRoot()
    }
    /// One strut value thicker by `factor`: rounded UP to the field's step (at least 0.1 mm) and at least 0.1 mm more than now.
    public static func thicker(_ d: Double, factor: Double, stepMM: Double) -> Double {
        let s = Swift.max(stepMM, 0.1)
        func up(_ v: Double) -> Double { ((v / s) - 1e-9).rounded(.up) * s }
        var v = up(d * factor)
        if v < d + 0.1 - 1e-9 { v = up(d + 0.1) }
        return (v * 1000).rounded() / 1000
    }
    /// ★ B4: a weak area of the solid — its thickness factor, √(needed ÷ holds), rounded up to the next 0.1×.
    public static func solidFactor(holds: Double, needs: Double) -> Double {
        guard holds > 0, needs > holds else { return 1.1 }
        return Swift.max(1.1, (((needs / holds).squareRoot() * 10) - 1e-9).rounded(.up) / 10)
    }

    /// The advice for one pop-up (nil: no setting and no number exist for it — the card's text says why).
    public static func advice(_ issue: OrganicCertify.Issue, _ c: Context) -> OrganicCertifyAdvice? {
        let s = issue.needs
        switch issue.id {
        case "struts_short":
            let f = strutFactor(holds: issue.worst, needs: s)
            guard let now = c.strut else {
                let pct = Int(((f - 1) * 100).rounded(.up))
                return .init(setting: "Strut thickness", line: OrganicCertifyCopy.strutUnmeasured(percent: pct),
                             tryText: "About \(pct)% thicker, both ends")
            }
            let hi = thicker(now.heavy, factor: f, stepMM: c.stepMM)
            let lo = now.single ? hi : Swift.min(hi, thicker(now.light, factor: f, stepMM: c.stepMM))
            if hi > LatticeOrganicLook.Check.strutMaxMM {
                return .init(setting: "Cell size", line: OrganicCertifyCopy.strutPastMax(needMM: now.heavy * f,
                                                                                         maxMM: LatticeOrganicLook.Check.strutMaxMM),
                             tryText: "Try smaller cells")
            }
            return .init(setting: "Strut thickness", line: OrganicCertifyCopy.strutTry(now: now, lo: lo, hi: hi, group: c.group),
                         tryText: OrganicCertifyCopy.tryRange(lo, hi, single: now.single))
        case "infill":
            guard case .infill(let to)? = issue.solve else { return nil }
            return .init(setting: "Infill", line: OrganicCertifyCopy.infill(now: c.infillNow, passes: to))
        case "load_on_open_lattice":
            return .init(setting: "Protect", line: OrganicCertifyCopy.protect)
        case "beside_the_lattice", "beside_a_fixing", "beside_the_load", "inside_the_solid":
            let w: String
            switch issue.id {
            case "beside_the_lattice": w = "between the lattice and the surface"
            case "beside_a_fixing": w = "around the fixing"
            case "beside_the_load": w = "where the load presses"
            default: w = "here"
            }
            return .init(setting: issue.id == "beside_the_lattice" ? "Protect skin" : nil,
                         line: OrganicCertifyCopy.solidThicker(holds: issue.worst, needs: s,
                                                              factor: solidFactor(holds: issue.worst, needs: s), where: w))
        default:
            return nil
        }
    }

    // MARK: the settings as they stand (the workspace's numbers)

    /// The strut thickness in force for `look` (as its page shows it: Auto keeps Auto's numbers) with `limits` (Look applied).
    public static func strutNow(_ look: LatticeOrganicLook, limits: LatticeOrganicLook.Limits?) -> StrutNow? {
        let s = look.strut
        let m = limits?.measured == true ? limits : nil
        switch look.four(s) {
        case .manual:
            guard let v = s?.single ?? m?.strutAutoMM else { return nil }
            return StrutNow(light: v, heavy: v, single: true, auto: s?.single == nil)
        case .manualSweep:
            guard let a = s?.light ?? m?.strutLowerMM, let b = s?.heavy ?? m?.strutUpperMM else { return nil }
            return StrutNow(light: Swift.min(a, b), heavy: Swift.max(a, b), single: false, auto: s?.light == nil && s?.heavy == nil)
        case .auto:
            guard let v = m?.strutAutoMM else { return nil }
            return StrutNow(light: v, heavy: v, single: true, auto: true)
        case .autoSweep:
            guard let a = m?.strutLowerMM, let b = m?.strutUpperMM else { return nil }
            return StrutNow(light: Swift.min(a, b), heavy: Swift.max(a, b), single: false, auto: true)
        }
    }

    /// The context from the part: the lattice group the struts card is about — the whole part's settings when the whole part
    /// is latticed (or it has no group), the one group, or (several) the group whose thick end is nearest the weakest strut's
    /// width (the report names no group) — its strut thickness, and the infill now.
    @MainActor
    public static func context(_ p: ProjectModel, partLimits: LatticeOrganicLook.Limits?,
                               groupLimits: [UUID: LatticeOrganicLook.Limits], weakestWidthMM: Double?) -> Context {
        let groups = p.lattice.wholePart ? [] : p.latticeAreaGroups
        func limits(_ g: UUID?) -> LatticeOrganicLook.Limits? {
            let base = g.map { groupLimits[$0] } ?? partLimits
            let pct = p.lattice.organicLook(group: g).lookPercentValue
            return base.map { $0.measured ? $0.looked(percent: pct) : $0 }
        }
        func now(_ g: UUID?) -> StrutNow? {
            strutNow(p.lattice.organicLook(group: g).effective(pageManual: p.latticePageManual), limits: limits(g))
        }
        let step = p.printParams.strutLineWidthMM > 0 ? p.printParams.strutLineWidthMM : 0.45
        let infill = p.printParams.infillPercent
        guard !groups.isEmpty else { return Context(strut: now(nil), stepMM: step, infillNow: infill) }
        guard groups.count > 1 else { return Context(strut: now(groups[0].id), groupID: groups[0].id, stepMM: step, infillNow: infill) }
        let pick = groups.min { a, b in
            let w = weakestWidthMM ?? 0
            return abs((now(a.id)?.heavy ?? .infinity) - w) < abs((now(b.id)?.heavy ?? .infinity) - w)
        } ?? groups[0]
        return Context(strut: now(pick.id), group: pick.name, groupID: pick.id, stepMM: step, infillNow: infill)
    }
}
