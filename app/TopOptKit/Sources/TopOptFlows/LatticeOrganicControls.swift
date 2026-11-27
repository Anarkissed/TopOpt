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
    /// ★ Cut 2, OG1: the gap the engine keeps between struts (its measured value, else 1.5 printed lines).
    private var gapMM: Double { limits?.gapMM ?? LatticeOrganicLook.Check.gapLines * lineMM }

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
                    say(LatticeCaptions.organicShapeOnlyBrief, info: ("Shape only",   // ★ notes29: five words + (i)
                        "Shape only: no heavy ends; small cells only where the shape tightens."))
                }
            }
            swept("Cell size", "mm", \.cell, auto: limits.map { ($0.cellAutoMM, $0.cellLowerMM, $0.cellUpperMM) },
                  lightIsSmall: false, step: 0.5, offered: LatticeOrganicLook.cellModes,
                  pair: { a, b in LatticeOrganicLook.Check.cell(small: a, large: b, thinStrutMM: thinStrutMM, gapMM: gapMM) },
                  one: { v in LatticeOrganicLook.Check.cell(small: v, large: v, thinStrutMM: thinStrutMM, gapMM: gapMM) })
            swept("Strut thickness", "mm", \.strut, auto: limits.map { ($0.strutAutoMM, $0.strutLowerMM, $0.strutUpperMM) },
                  lightIsSmall: true, step: lineMM,
                  pair: { a, b in LatticeOrganicLook.Check.strut(thin: a, thick: b, thinnestMM: thinnestMM) },
                  one: { v in LatticeOrganicLook.Check.strut(thin: v, thick: nil, thinnestMM: thinnestMM) })
            if limits?.measured == false || limits == nil && look.four(look.cell, offered: LatticeOrganicLook.cellModes).isAuto {
                // ★ notes29 (his 11-25): five words; the rest in the (i)
                say(limits == nil ? LatticeCaptions.organicMeasuringBrief : LatticeCaptions.organicUnmeasuredBrief,
                    warning: limits != nil,
                    info: limits == nil ? nil : ("Auto's numbers", "This part could not be measured, so Auto has no numbers "
                                                 + "for it: type the range yourself."))
            }
            if grown {
                if on(.seeds) { number("Seeds (feet apart) (0 = off)", "spacings", \.seeds, auto: 2.5, check: { LatticeOrganicLook.Check.seeds($0) }) }
                if on(.wallSeedsOff) {
                    toggle("Wall seeds", \.wallSeeds) { on in if !on, look.crossingVines ?? true { look.crossingVines = false } }
                }
                if look.wallSeeds ?? true {
                    gap("Wall seed gap (0 = off)", \.wallGap, LatticeOrganicLook.wallGapAuto, zeroOff: true)
                    if on(.crossingVinesOff) { toggle("Crossing vines", \.crossingVines) }
                    if look.crossingVines ?? true { gap("Crossing gap", \.crossGap, LatticeOrganicLook.crossGapAuto) }
                } else if on(.crossingVinesOff) {
                    say(LatticeCaptions.organicCrossingNeedsSeedsBrief, info: ("Crossing vines",   // ★ rule g; notes29
                        "Crossing vines are off: they grow from wall seeds, so they need Wall seeds on."))
                }
                if on(.roots) {
                    number("Roots (0 = off)", "spacings", \.roots, auto: 0) { LatticeOrganicLook.Check.run("Roots", $0) }
                }
                if on(.topBranches) {
                    number("Top branches (0 = off)", "spacings", \.topBranches, auto: 0) {
                        LatticeOrganicLook.Check.run("Top branches", $0)
                    }
                }
                if on(.stressFollowOff) { toggle("Stress follow", \.stressFollow) }
            }
            if on(.flatTiesOff) { toggle("Flat ties", \.flatTies) }
            if look.flatTies ?? true { gap("Flat tie gap", \.tieGap, LatticeOrganicLook.tieGapAuto) }
            if on(.shapeReach) {   // always on (his ruling)
                number("Grade to shape reach (0 = off)", "×", \.shapeReach, auto: 1) { LatticeOrganicLook.Check.reach($0) }
            }
            if on(.detectFloatingOff) { toggle("Detect floating parts", \.detectFloating) }
            if aesthetic {   // ★ his 11-18: Organic and Aesthetic only
                row("Simulate stresses on unstressed walls") {
                    Toggle("", isOn: Binding(get: { look.syntheticStresses ?? false }, set: { look.syntheticStresses = $0 }))
                        .labelsHidden().toggleStyle(.switch)
                }
                .accessibilityIdentifier("organic-Simulate stresses on unstressed walls")
                if look.syntheticStresses ?? false {   // ★ notes29: five words + (i)
                    say(LatticeCaptions.organicFociBrief, info: ("Number of foci",
                        "Each wall's number of foci (the made-up load points) is set on its row in Selections."))
                }
            }
            if LatticeOrganicLook.cut2Wired {   // ★ cut 2 (his 11-19): depth variation and extra spacing, each one switch
                row("Depth variation") {
                    Toggle("", isOn: Binding(get: { look.depthVariationValue }, set: { look.depthVariation = $0 }))
                        .labelsHidden().toggleStyle(.switch)
                }
                .accessibilityIdentifier("organic-Depth variation")
                // ★ notes26 (his yes, 11-23): "Up to 1 mm out." showed twice with it on — its grey caption (OrganicSettingsHelp)
                // and this line ("… at open faces"). ONE line now, as Extra spacing's: the caption, five words (his rule); the
                // open faces are in its (i).
                row("Extra spacing between vines") {
                    Toggle("", isOn: Binding(get: { look.extraSpacingValue(aesthetic: aesthetic) }, set: { look.extraSpacing = $0 }))
                        .labelsHidden().toggleStyle(.switch)
                }
                .accessibilityIdentifier("organic-Extra spacing between vines")
                // ★ his iPad notes 11-23 (img 9): "Will likely lose strength" showed twice with it on — its grey caption
                // (OrganicSettingsHelp) and this line. The caption says it; this line is gone.
            }
            if on(.linkWidth) { number("Link thickness", "× strut", \.linkWidth, auto: 1) { LatticeOrganicLook.Check.link($0) } }
            if on(.unbracedOther) {
                number("Longest strut without a joint (0 = off)", "widths", \.unbracedMax, auto: 10) { LatticeOrganicLook.Check.unbraced($0) }
            } else {
                row("Longest strut without a joint (0 = off)") {
                    Toggle("", isOn: Binding(get: { (look.unbracedMax ?? 10) > 0 }, set: { look.unbracedMax = $0 ? nil : 0 }))
                        .labelsHidden().toggleStyle(.switch)
                }
                .accessibilityIdentifier("organic-Longest strut without a joint (0 = off)")
            }
        }
        .accessibilityIdentifier("organic-controls")
    }

    // MARK: rows

    /// A setting's name without its " (0 = off)" (★ 11-22: the number pad's header).
    static func bare(_ label: String) -> String {
        label.hasSuffix(" (0 = off)") ? String(label.dropLast(" (0 = off)".count)) : label
    }

    private func name(_ label: String) -> some View {
        let off = " (0 = off)"
        let base = label.hasSuffix(off) ? String(label.dropLast(off.count)) : label
        return HStack(spacing: 0) {
            Text(base).dsStyle(DS.TypeScale.caption).fontWeight(.semibold).lineLimit(1).minimumScaleFactor(0.85)
            // ★ his 11-20: "Add the 0=off beside the name but in italics and the same grey as the details"
            if base != label {
                Text(off).font(.system(size: 11.5)).italic().foregroundStyle(DS.Color.textTertiary.color).lineLimit(1)
                    .fixedSize()
            }
            OrganicInfoButton(label: label)   // ★ his 11-20: an (i) beside every setting
        }
        .layoutPriority(1)
    }

    /// ★ notes29 (his 11-25): a line under a setting — at most five words (LatticeCaptionsNotes29Tests), the rest in its (i).
    private func say(_ text: String, warning: Bool = false, info: (title: String, text: String)? = nil) -> some View {
        LatticeCaptions.record(text)
        return HStack(spacing: DS.Space.xs) {
            Text(text).font(.system(size: 12, weight: warning ? .semibold : .regular))
                .foregroundStyle(warning ? DS.Color.warning.color : DS.Color.textTertiary.color)
                .lineLimit(1).minimumScaleFactor(0.75)
            if let info { AppInfoButton(title: info.title, text: info.text) }
        }
    }

    /// The refusal under this setting, when the last typed number was refused (the centred pop-up says it too).
    /// ★ notes29 (his 11-25): five words; the reason in the (i).
    @ViewBuilder private func refused(_ label: String) -> some View {
        if let r = refusal, r.label == label {
            say(LatticeCaptions.numberNotApplied, warning: true, info: (Self.bare(label), r.text))
                .accessibilityIdentifier("organic-refusal")
        }
    }

    /// One row: the name, then its control at the right. 44 pt; ★ his 11-20: its grey line under it (`grey` false: the
    /// setting puts it under its fields instead).
    private func row<C: View>(_ label: String, grey: Bool = true, @ViewBuilder _ control: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: DS.Space.s) {
                name(label)
                Spacer(minLength: DS.Space.s)
                control()
            }
            .frame(height: 44)
            if grey { OrganicGreyLine(label: label) }
        }
    }

    /// Two rows: the name, then its control across the row under it, then its grey line.
    private func stacked<C: View>(_ label: String, @ViewBuilder _ control: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            name(label).frame(height: 44, alignment: .bottom)
            control().frame(maxWidth: .infinity, minHeight: 44, maxHeight: 44, alignment: .leading)
            OrganicGreyLine(label: label)
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
                OrganicNumberField(value: look[keyPath: kp], auto: auto, unit: unit, title: Self.bare(label), key: label) { v in
                    if let v, let why = check(v) { refusal = (label, why); AppPopups.shared.wrongNumber(label, why); return }
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
                     _ a: LatticeOrganicLook.GapAuto, zeroOff: Bool = false) -> some View {
        let name = label.replacingOccurrences(of: " (0 = off)", with: "")
        return swept(label, "spacings", kp, auto: (a.single, a.heavy, a.light), lightIsSmall: false, step: 0.1,
              pair: { c, w in LatticeOrganicLook.Check.gap(name, close: c, wide: w, zeroOff: zeroOff) },
              one: { v in LatticeOrganicLook.Check.gap(name, close: nil, wide: v, zeroOff: zeroOff) })
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
            if let x = a2 ?? auto?.1, let y = b2 ?? auto?.2, let why = pair(x, y) { refusal = (label, why); AppPopups.shared.wrongNumber(label, why); return }
            refusal = nil
            var v = s
            if lightIsSmall { v.light = a2; v.heavy = b2 } else { v.heavy = a2; v.light = b2 }
            look[keyPath: kp] = v
        }
        return VStack(alignment: .trailing, spacing: 0) {
            row(label, grey: false) {
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
                    OrganicNumberField(value: mode.isAuto ? nil : small, auto: auto?.1, unit: "", locked: mode.isAuto,
                                       title: Self.bare(label), key: label + "-small") { v in
                        setPair(small: v, large: large)
                    }
                    Text("to").font(.system(size: 12)).foregroundStyle(DS.Color.textTertiary.color)
                    OrganicNumberField(value: mode.isAuto ? nil : large, auto: auto?.2, unit: unit, locked: mode.isAuto,
                                       title: Self.bare(label), key: label + "-large") { v in
                        setPair(small: small, large: v)
                    }
                } else {
                    OrganicNumberField(value: mode.isAuto ? nil : s.single, auto: auto?.0, unit: unit, locked: mode.isAuto,
                                       title: Self.bare(label), key: label) { v in
                        let v2 = v.map(snap)
                        if let x = v2, let why = one(x) { refusal = (label, why); AppPopups.shared.wrongNumber(label, why); return }
                        refusal = nil
                        var n = s; n.single = v2; look[keyPath: kp] = n
                    }
                }
            }
            .frame(height: 44)
            OrganicGreyLine(label: label)
            refused(label)
        }
        .accessibilityIdentifier("organic-" + label)
        .settingToChange(label, also: label == "Cell size" ? [LatticeWizardSetting.cellSize.rawValue] : [])   // ★ notes25 B6: Solve and "Change settings" light it and bring it to the middle (SettingToChange)
    }
}

/// A number field: nil shows Auto's value greyed ("–" until measured); what he types applies as the pad closes (nil when
/// cleared); `locked` (an Auto mode) shows Auto's value and takes no typing.
/// ★ His iPad notes 11-22 (img 5): "Why is the full alpha-numeric keyboard being used? It should just be the numeric." The box
/// opens the app's number pad beside it (PadNumberBox), never the system keyboard; Done or a tap elsewhere applies what he
/// typed through the same rule its Return used (`parse`).
struct OrganicNumberField: View {
    let value: Double?
    let auto: Double?
    let unit: String
    var locked = false
    /// What the empty field shows in place of `auto`'s number (e.g. "Auto" where the engine works the number out).
    var placeholder: String? = nil
    /// ★ 11-22: the setting's name (the pad's header) and the box's id ("organic-field-<key>").
    var title: String = ""
    var key: String = ""
    let apply: (Double?) -> Void

    var body: some View {
        HStack(spacing: 4) {
            PadNumberBox(key: "organic-field-" + (key.isEmpty ? title : key), title: title,
                         shown: value.map(StrengthCheckDocs.number),
                         placeholder: placeholder ?? auto.map(StrengthCheckDocs.number) ?? "–",
                         unit: unit.isEmpty ? nil : unit, width: 64, locked: locked) { text in
                guard let v = Self.parse(text) else { return }
                apply(v)
            }
            if !unit.isEmpty { Text(unit).font(.system(size: 12)).foregroundStyle(DS.Color.textTertiary.color).lineLimit(1).fixedSize() }
        }
        .frame(minHeight: 44)
    }

    /// What a typed text applies (its Return's rule before 11-22, unchanged): cleared = .some(nil), back to Auto; a number;
    /// anything else (nil) applies nothing.
    static func parse(_ text: String) -> Double?? {
        let t = text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
        if t.isEmpty { return .some(nil) }
        guard let d = Double(t), d.isFinite else { return nil }
        return .some(d)
    }
}
