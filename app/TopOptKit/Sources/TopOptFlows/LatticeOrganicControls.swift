// LatticeOrganicControls — ★ ORGANIC (his 11-18: "Preview PLUS settings simultaneously"; his iPad notes 11-18: "only those
// settings are visible when Organic is turned on ... All settings have a range that must be accepted and all new rules must be
// followed"): the new engine's Organic settings on the Lattice page (Manual), the WHOLE PART's (one ask per lay: LatticeReview's
// ruling 1). One line of text per setting (his rule 09-29); a setting whose controls do not fit beside its name puts them on
// the row under it (the panel is ~320 pt wide on the iPad); every row 44 pt. A range is typed smallest to largest, whichever
// end is the light one. A number outside what the engine takes (LatticeOrganicLook.Check, LatticeReview's ruling 4) is not
// applied and the reason is said in one line under the setting. Auto's numbers (measured by the engine, moved by Look) are
// shown greyed in the fields; "–" until measured.
import SwiftUI
import TopOptDesign

struct LatticeOrganicControls: View {
    @Binding var look: LatticeOrganicLook
    /// The Auto numbers in force (the engine's whole-part limits, as Look leaves them); nil: not measured yet.
    var limits: LatticeOrganicLook.Limits?
    /// The print line (the thinnest strut is two of them).
    var lineMM: Double = 0.45
    /// Aesthetic: the "Simulate stresses on unstressed walls" switch shows (his 11-18: ONLY in Organic and Aesthetic).
    var aesthetic = false
    /// The last refusal, under the setting it is about.
    @State private var refusal: (label: String, text: String)?

    private var grown: Bool { look.modeValue == .grown }
    private func on(_ o: LatticeOrganicLook.Option) -> Bool { LatticeOrganicLook.offered(o) }
    private var thinnestMM: Double { 2 * lineMM }

    /// The thin strut in force (the cell's smallest printable size follows it).
    private var thinStrutMM: Double {
        let s = look.strut
        switch look.four(s) {
        case .autoSweep, .auto: return limits?.strutLowerMM ?? thinnestMM
        case .manualSweep: return s?.light ?? limits?.strutLowerMM ?? thinnestMM
        case .manual: return s?.single ?? limits?.strutAutoMM ?? thinnestMM
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.xs) {
            stacked("Organic") {
                SegmentedGlass(LatticeOrganicLook.Mode.allCases.map { .init($0, $0.title) },
                               selection: Binding(get: { look.modeValue }, set: { look.mode = $0 }), small: true)
            }
            if on(.shapeOnly) {   // ★ his 11-18: stress and shape, or shape alone
                stacked("Gradient") {
                    SegmentedGlass([.init(true, "Stress and shape"), .init(false, "Shape only")],
                                   selection: Binding(get: { look.followStressValue }, set: { look.followStress = $0 }), small: true)
                }
                .accessibilityIdentifier("organic-Gradient")
                if !look.followStressValue {   // OP6 (sheet H8): no heavy end acts; the small cells only where the shape tightens
                    say("Shape only: no heavy ends; small cells only where the shape tightens")
                }
            }
            swept("Cell size", "mm", \.cell, auto: limits.map { ($0.cellAutoMM, $0.cellLowerMM, $0.cellUpperMM) },
                  lightIsSmall: false, step: 0.5, offered: LatticeOrganicLook.cellModes,
                  pair: { a, b in LatticeOrganicLook.Check.cell(small: a, large: b, thinStrutMM: thinStrutMM) },
                  one: { v in LatticeOrganicLook.Check.cell(small: v, large: v, thinStrutMM: thinStrutMM) })
            swept("Strut thickness", "mm", \.strut, auto: limits.map { ($0.strutAutoMM, $0.strutLowerMM, $0.strutUpperMM) },
                  lightIsSmall: true, step: lineMM,
                  pair: { a, b in LatticeOrganicLook.Check.strut(thin: a, thick: b, thinnestMM: thinnestMM) },
                  one: { v in LatticeOrganicLook.Check.strut(thin: v, thick: nil, thinnestMM: thinnestMM) })
            if limits?.measured == false || limits == nil && look.four(look.cell, offered: LatticeOrganicLook.cellModes).isAuto {
                say(limits == nil ? "Measuring this part's areas for Auto" : "This part could not be measured: type the range",
                    warning: limits != nil)
            }
            if grown {
                if on(.seeds) { number("Seeds (feet apart)", "spacings", \.seeds, auto: 2.5, check: { _ in nil }) }
                if on(.wallSeedsOff) {
                    toggle("Wall seeds", \.wallSeeds) { on in if !on, look.crossingVines ?? true { look.crossingVines = false } }
                }
                if look.wallSeeds ?? true {
                    gap("Wall seed gap", \.wallGap, LatticeOrganicLook.wallGapAuto)
                    if on(.crossingVinesOff) { toggle("Crossing vines", \.crossingVines) }
                    if look.crossingVines ?? true { gap("Crossing gap", \.crossGap, LatticeOrganicLook.crossGapAuto) }
                } else if on(.crossingVinesOff) {
                    say("Crossing vines are off: they grow from wall seeds")   // ★ rule g
                }
                if on(.roots) {
                    number("Roots (0 = off)", "spacings", \.roots, auto: 0) { LatticeOrganicLook.Check.atLeastZero("Roots", $0) }
                }
                if on(.topBranches) {
                    number("Top branches (0 = off)", "spacings", \.topBranches, auto: 0) {
                        LatticeOrganicLook.Check.atLeastZero("Top branches", $0)
                    }
                }
                if on(.stressFollowOff) { toggle("Stress follow", \.stressFollow) }
            }
            if on(.flatTiesOff) { toggle("Flat ties", \.flatTies) }
            if look.flatTies ?? true { gap("Flat tie gap", \.tieGap, LatticeOrganicLook.tieGapAuto) }
            if on(.shapeReach) {   // always on (his ruling)
                number("Grade to shape reach", "×", \.shapeReach, auto: 1) { LatticeOrganicLook.Check.atLeastZero("Grade to shape reach", $0) }
            }
            if on(.detectFloatingOff) { toggle("Detect floating parts", \.detectFloating) }
            if aesthetic {   // ★ his 11-18: Organic and Aesthetic only
                row("Simulate stresses on unstressed walls") {
                    Toggle("", isOn: Binding(get: { look.syntheticStresses ?? false }, set: { look.syntheticStresses = $0 }))
                        .labelsHidden().toggleStyle(.switch)
                }
                .accessibilityIdentifier("organic-Simulate stresses on unstressed walls")
                if look.syntheticStresses ?? false { say("Number of foci: per wall, in Selections") }
            }
            if on(.linkWidth) { number("Link thickness", "× strut", \.linkWidth, auto: 1) { LatticeOrganicLook.Check.link($0) } }
            if on(.unbracedOther) {
                number("Longest strut without a joint", "widths", \.unbracedMax, auto: 10) { LatticeOrganicLook.Check.unbraced($0) }
            } else {
                row("Longest strut without a joint") {
                    Toggle("", isOn: Binding(get: { (look.unbracedMax ?? 10) > 0 }, set: { look.unbracedMax = $0 ? nil : 0 }))
                        .labelsHidden().toggleStyle(.switch)
                }
                .accessibilityIdentifier("organic-Longest strut without a joint")
            }
        }
        .accessibilityIdentifier("organic-controls")
    }

    // MARK: rows

    private func name(_ label: String) -> some View {
        Text(label).dsStyle(DS.TypeScale.caption).fontWeight(.semibold).lineLimit(1).minimumScaleFactor(0.85)
            .layoutPriority(1)
    }

    private func say(_ text: String, warning: Bool = false) -> some View {
        Text(text).font(.system(size: 12, weight: warning ? .semibold : .regular))
            .foregroundStyle(warning ? DS.Color.warning.color : DS.Color.textTertiary.color)
            .lineLimit(1).minimumScaleFactor(0.75)
    }

    /// The refusal under this setting, when the last typed number was refused.
    @ViewBuilder private func refused(_ label: String) -> some View {
        if let r = refusal, r.label == label {
            say(r.text, warning: true).accessibilityIdentifier("organic-refusal")
        }
    }

    /// One row: the name, then its control at the right. 44 pt.
    private func row<C: View>(_ label: String, @ViewBuilder _ control: () -> C) -> some View {
        HStack(spacing: DS.Space.s) {
            name(label)
            Spacer(minLength: DS.Space.s)
            control()
        }
        .frame(height: 44)
    }

    /// Two rows: the name, then its control across the row under it.
    private func stacked<C: View>(_ label: String, @ViewBuilder _ control: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            name(label).frame(height: 24, alignment: .bottom)
            control().frame(maxWidth: .infinity, minHeight: 44, maxHeight: 44, alignment: .leading)
        }
    }

    private func toggle(_ label: String, _ kp: WritableKeyPath<LatticeOrganicLook, Bool?>,
                        changed: @escaping (Bool) -> Void = { _ in }) -> some View {
        row(label) {
            Toggle("", isOn: Binding(get: { look[keyPath: kp] ?? true }, set: { look[keyPath: kp] = $0; changed($0) }))
                .labelsHidden().toggleStyle(.switch)
        }
        .accessibilityIdentifier("organic-" + label)
    }

    /// One number, nil = Auto (shown greyed in the field); typing sets it (refused with its reason when `check` says so),
    /// clearing it goes back to Auto.
    private func number(_ label: String, _ unit: String, _ kp: WritableKeyPath<LatticeOrganicLook, Double?>, auto: Double,
                        check: @escaping (Double) -> String?) -> some View {
        VStack(alignment: .trailing, spacing: 0) {
            row(label) {
                OrganicNumberField(value: look[keyPath: kp], auto: auto, unit: unit) { v in
                    if let v, let why = check(v) { refusal = (label, why); return }
                    refusal = nil
                    look[keyPath: kp] = v
                }
            }
            refused(label)
        }
        .accessibilityIdentifier("organic-" + label)
    }

    /// A gap (in local spacings): Auto Sweep's close and wide ends, a typed pair, or one number; the close end is the
    /// heavy one (denser where the stress is), 0 = off.
    private func gap(_ label: String, _ kp: WritableKeyPath<LatticeOrganicLook, LatticeOrganicLook.Swept?>,
                     _ a: LatticeOrganicLook.GapAuto) -> some View {
        swept(label, "spacings", kp, auto: (a.single, a.heavy, a.light), lightIsSmall: false, step: 0.1,
              pair: { c, w in LatticeOrganicLook.Check.gap(label, close: c, wide: w) },
              one: { v in LatticeOrganicLook.Check.gap(label, close: nil, wide: v) })
    }

    /// His modes on one setting (the ones `offered`): the name and the mode menu on the first row; the fields its mode shows
    /// on the second — a Sweep's two ends SMALLEST FIRST (`lightIsSmall`: the light end is the small number, as for struts;
    /// else the large one, as for cells and gaps), or one number. Auto's numbers greyed in the fields. Typed numbers are
    /// rounded to `step`, then `pair` / `one` say whether the engine takes them.
    /// `auto`: (single, small end, large end); nil: not measured yet.
    private func swept(_ label: String, _ unit: String, _ kp: WritableKeyPath<LatticeOrganicLook, LatticeOrganicLook.Swept?>,
                       auto: (Double, Double, Double)?, lightIsSmall: Bool, step: Double,
                       offered: [LatticeOrganicLook.Four] = LatticeOrganicLook.otherModes,
                       pair: @escaping (Double, Double) -> String?, one: @escaping (Double) -> String?) -> some View {
        let s = look[keyPath: kp] ?? .init()
        let mode = look.four(look[keyPath: kp], offered: offered)
        let small = lightIsSmall ? s.light : s.heavy, large = lightIsSmall ? s.heavy : s.light
        func snap(_ v: Double) -> Double { step > 0 ? ((v / step).rounded() * step * 1000).rounded() / 1000 : v }
        func setPair(small a: Double?, large b: Double?) {
            let a2 = a.map(snap), b2 = b.map(snap)
            if let x = a2 ?? auto?.1, let y = b2 ?? auto?.2, let why = pair(x, y) { refusal = (label, why); return }
            refusal = nil
            var v = s
            if lightIsSmall { v.light = a2; v.heavy = b2 } else { v.heavy = a2; v.light = b2 }
            look[keyPath: kp] = v
        }
        return VStack(alignment: .trailing, spacing: 0) {
            row(label) {
                Menu {
                    ForEach(offered, id: \.self) { m in
                        Button(m.title) { var v = s; v.mode = m; look[keyPath: kp] = v; refusal = nil }
                            .disabled(m.isSweep && !look.sweepsAllowed)
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text(mode.title).font(.system(size: 13, weight: .semibold)).lineLimit(1).fixedSize()
                        Image(systemName: "chevron.down").font(.system(size: 10, weight: .semibold))
                    }
                    .foregroundStyle(DS.Color.accent.color)
                    .frame(minWidth: 44, minHeight: 44)
                }
                .menuIndicator(.hidden)   // (its own chevron is drawn above)
                .fixedSize()
            }
            HStack(spacing: DS.Space.xs) {
                Spacer(minLength: 0)
                if mode.isSweep {
                    OrganicNumberField(value: mode.isAuto ? nil : small, auto: auto?.1, unit: "", locked: mode.isAuto) { v in
                        setPair(small: v, large: large)
                    }
                    Text("to").font(.system(size: 12)).foregroundStyle(DS.Color.textTertiary.color)
                    OrganicNumberField(value: mode.isAuto ? nil : large, auto: auto?.2, unit: unit, locked: mode.isAuto) { v in
                        setPair(small: small, large: v)
                    }
                } else {
                    OrganicNumberField(value: mode.isAuto ? nil : s.single, auto: auto?.0, unit: unit, locked: mode.isAuto) { v in
                        let v2 = v.map(snap)
                        if let x = v2, let why = one(x) { refusal = (label, why); return }
                        refusal = nil
                        var n = s; n.single = v2; look[keyPath: kp] = n
                    }
                }
            }
            .frame(height: 44)
            refused(label)
        }
        .accessibilityIdentifier("organic-" + label)
    }
}

/// A number field: nil shows Auto's value greyed ("–" until measured); Return applies what he typed (nil when cleared);
/// `locked` (an Auto mode) shows Auto's value and takes no typing.
struct OrganicNumberField: View {
    let value: Double?
    let auto: Double?
    let unit: String
    var locked = false
    let apply: (Double?) -> Void
    @State private var text = ""
    @State private var editing = false

    var body: some View {
        HStack(spacing: 4) {
            TextField(auto.map(StrengthCheckDocs.number) ?? "–",
                      text: Binding(get: { editing ? text : value.map(StrengthCheckDocs.number) ?? "" },
                                    set: { text = $0; editing = true }))
                .textFieldStyle(.roundedBorder)
                .frame(width: 64)
                .disabled(locked)
                .opacity(locked ? 0.55 : 1)
                .onSubmit {
                    editing = false
                    let t = text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
                    if t.isEmpty { apply(nil); return }
                    guard let d = Double(t), d.isFinite else { return }
                    apply(d)
                }
            if !unit.isEmpty { Text(unit).font(.system(size: 12)).foregroundStyle(DS.Color.textTertiary.color).lineLimit(1).fixedSize() }
        }
        .frame(minHeight: 44)
    }
}
