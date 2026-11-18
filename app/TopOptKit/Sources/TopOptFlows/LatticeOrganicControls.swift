// LatticeOrganicControls — ★ ORGANIC, CUT 1 (his 11-18: "Preview PLUS settings simultaneously"): his Organic controls on the
// lattice settings, one line each (his "one line per setting"), on a part with its model file (the new engine). His rule
// 11-18: "It shouldn't be an option if we can't do it or haven't tested" — what is not yet run and looked at on his stand is
// not shown (`LatticeOrganicLook.offered`, LatticeReview's list). Cell size: Auto Sweep and Manual Sweep; strut thickness and
// the gaps: Auto Sweep, Manual Sweep (and Manual once run). Auto's numbers shown in the fields, greyed.
import SwiftUI
import TopOptDesign

struct LatticeOrganicControls: View {
    @Binding var look: LatticeOrganicLook
    /// The Auto numbers in force (core's, or the part's own until core has measured); nil: not measured (a curved shell).
    var limits: LatticeOrganicLook.Limits?

    private var grown: Bool { look.modeValue == .grown }
    private func on(_ o: LatticeOrganicLook.Option) -> Bool { LatticeOrganicLook.offered(o) }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            line("Organic") {
                SegmentedGlass(LatticeOrganicLook.Mode.allCases.map { .init($0, $0.title) },
                               selection: Binding(get: { look.modeValue }, set: { look.mode = $0 }), small: true)
                    .frame(width: 220)
            }
            if on(.shapeOnly) {   // ★ his 11-18: stress and shape, or shape alone
                line("Gradient") {
                    SegmentedGlass([.init(true, "Stress and shape"), .init(false, "Shape only")],
                                   selection: Binding(get: { look.followStressValue }, set: { look.followStress = $0 }), small: true)
                        .frame(width: 260)
                }
                .accessibilityIdentifier("organic-Gradient")
                if !look.followStressValue {   // OP6: with shape only, core reads the light ends alone
                    Text("Shape only: the heavy ends of strut thickness and the gaps do nothing").font(.system(size: 12))
                        .foregroundStyle(DS.Color.textTertiary.color)
                }
            }
            swept("Cell size", "mm", \.cell, auto: limits.map { ($0.cellAutoMM, $0.cellLowerMM, $0.cellUpperMM) },
                  offered: LatticeOrganicLook.cellModes)
            swept("Strut thickness", "mm", \.strut, auto: limits.map { ($0.strutAutoMM, $0.strutLowerMM, $0.strutUpperMM) })
            if limits?.measured == false {
                Text("This area could not be measured: Auto Sweep is off, type the range").font(.system(size: 12))
                    .foregroundStyle(DS.Color.warning.color)
            }
            if grown {
                if on(.seeds) { number("Seeds (feet apart)", "spacings", \.seeds, auto: 2.5) }
                if on(.wallSeedsOff) { toggle("Wall seeds", \.wallSeeds) }
                if look.wallSeeds ?? true {
                    swept("Wall seed gap", "spacings", \.wallGap, auto: gapAuto(LatticeOrganicLook.wallGapAuto))
                    if on(.crossingVinesOff) { toggle("Crossing vines", \.crossingVines) }
                    if look.crossingVines ?? true {
                        swept("Crossing gap", "spacings", \.crossGap, auto: gapAuto(LatticeOrganicLook.crossGapAuto))
                    }
                }
                if on(.roots) { number("Roots (0 = off)", "spacings", \.roots, auto: 0) }
                if on(.topBranches) { number("Top branches (0 = off)", "spacings", \.topBranches, auto: 0) }
                if on(.stressFollowOff) { toggle("Stress follow", \.stressFollow) }
            }
            if on(.flatTiesOff) { toggle("Flat ties", \.flatTies) }
            if look.flatTies ?? true {
                swept("Flat tie gap", "spacings", \.tieGap, auto: gapAuto(LatticeOrganicLook.tieGapAuto))
            }
            if on(.shapeReach) { number("Grade to shape reach", "×", \.shapeReach, auto: 1) }   // always on (his ruling)
            if on(.detectFloatingOff) { toggle("Detect floating parts", \.detectFloating) }
            if on(.linkWidth) { number("Link thickness", "× strut", \.linkWidth, auto: 1, range: 0.5...2) }
            // run and looked at: 10 (Auto) and 0 (off); other numbers only once run
            line("Longest strut without a joint") {
                if on(.unbracedOther) {
                    OrganicNumberField(value: look.unbracedMax, auto: 10, unit: "strut widths", range: 0...40) { look.unbracedMax = $0 }
                } else {
                    Toggle("", isOn: Binding(get: { (look.unbracedMax ?? 10) > 0 }, set: { look.unbracedMax = $0 ? nil : 0 }))
                        .labelsHidden()
                }
            }
            .accessibilityIdentifier("organic-Longest strut without a joint")
        }
        .accessibilityIdentifier("organic-controls")
    }

    private func gapAuto(_ a: LatticeOrganicLook.GapAuto) -> (Double, Double, Double) { (a.single, a.heavy, a.light) }

    // MARK: rows

    private func line<C: View>(_ label: String, @ViewBuilder _ control: () -> C) -> some View {
        HStack(spacing: DS.Space.s) {
            Text(label).dsStyle(DS.TypeScale.caption).fontWeight(.semibold).lineLimit(1)
            Spacer(minLength: DS.Space.m)
            control()
        }
        .frame(minHeight: 44)
    }

    private func toggle(_ label: String, _ kp: WritableKeyPath<LatticeOrganicLook, Bool?>) -> some View {
        line(label) {
            Toggle("", isOn: Binding(get: { look[keyPath: kp] ?? true }, set: { look[keyPath: kp] = $0 }))
                .labelsHidden()
        }
        .accessibilityIdentifier("organic-" + label)
    }

    /// One number, nil = Auto (shown greyed in the field); typing sets it, clearing it goes back to Auto.
    private func number(_ label: String, _ unit: String, _ kp: WritableKeyPath<LatticeOrganicLook, Double?>, auto: Double,
                        range: ClosedRange<Double>? = nil) -> some View {
        line(label) {
            OrganicNumberField(value: look[keyPath: kp], auto: auto, unit: unit, range: range) { look[keyPath: kp] = $0 }
        }
        .accessibilityIdentifier("organic-" + label)
    }

    /// His modes on one setting (the ones `offered`): the mode menu, then the fields its mode shows (a Sweep's light and
    /// heavy ends, or one number); Auto's numbers greyed in the fields. `auto`: (single, low end, high end).
    private func swept(_ label: String, _ unit: String, _ kp: WritableKeyPath<LatticeOrganicLook, LatticeOrganicLook.Swept?>,
                       auto: (Double, Double, Double)?,
                       offered: [LatticeOrganicLook.Four] = LatticeOrganicLook.otherModes) -> some View {
        let s = look[keyPath: kp] ?? .init()
        let mode = look.four(look[keyPath: kp], offered: offered)
        func set(_ f: (inout LatticeOrganicLook.Swept) -> Void) { var v = s; f(&v); look[keyPath: kp] = v }
        return line(label) {
            Menu {
                ForEach(offered, id: \.self) { m in
                    Button(m.title) { set { $0.mode = m } }.disabled(m.isSweep && !look.sweepsAllowed)
                }
            } label: {
                Text(mode.title).font(.system(size: 13, weight: .semibold)).foregroundStyle(DS.Color.accent.color)
                    .frame(minWidth: 44, minHeight: 44)
            }
            if mode.isSweep {
                OrganicNumberField(value: mode.isAuto ? nil : s.light, auto: auto?.2 ?? 0, unit: "", range: nil,
                                   locked: mode.isAuto) { v in set { $0.light = v } }
                Text("to").font(.system(size: 12)).foregroundStyle(DS.Color.textTertiary.color)
                OrganicNumberField(value: mode.isAuto ? nil : s.heavy, auto: auto?.1 ?? 0, unit: unit, range: nil,
                                   locked: mode.isAuto) { v in set { $0.heavy = v } }
            } else {
                OrganicNumberField(value: mode.isAuto ? nil : s.single, auto: auto?.0 ?? 0, unit: unit, range: nil,
                                   locked: mode.isAuto) { v in set { $0.single = v } }
            }
        }
        .accessibilityIdentifier("organic-" + label)
    }
}

/// A number field: nil shows Auto's value greyed; Return applies what he typed (refused outside `range`); `locked` (an Auto
/// mode) shows Auto's value and takes no typing.
struct OrganicNumberField: View {
    let value: Double?
    let auto: Double
    let unit: String
    let range: ClosedRange<Double>?
    var locked = false
    let apply: (Double?) -> Void
    @State private var text = ""
    @State private var editing = false

    var body: some View {
        HStack(spacing: 4) {
            TextField(StrengthCheckDocs.number(auto), text: Binding(get: { editing ? text : value.map(StrengthCheckDocs.number) ?? "" },
                                                                     set: { text = $0; editing = true }))
                .textFieldStyle(.roundedBorder)
                .frame(width: 64)
                .disabled(locked)
                .opacity(locked ? 0.55 : 1)
                .onSubmit {
                    editing = false
                    let t = text.trimmingCharacters(in: .whitespaces)
                    if t.isEmpty { apply(nil); return }
                    guard let d = Double(t), range.map({ $0.contains(d) }) ?? true else { return }
                    apply(d)
                }
            if !unit.isEmpty { Text(unit).font(.system(size: 12)).foregroundStyle(DS.Color.textTertiary.color) }
        }
        .frame(minHeight: 44)
    }
}
