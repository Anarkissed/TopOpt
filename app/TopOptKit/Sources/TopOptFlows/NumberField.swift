// NumberField.swift — B2 (U9, U11; design-system §4.10, §4.28; his round 2 notes N1 / N2 and round 3 note P1): the ONE
// number in the app. The value and its unit in a box that looks editable:
//   • a TAP opens the app's number pad beside it (NumberPad, §4.33; none with a keyboard connected: it takes typing);
//   • a vertical DRAG steps it (up = more; slow = fine, fast = coarse), and a drag never opens the pad;
//   • the value is committed ONCE: as the pad closes (Done or a tap elsewhere), or as the drag ends — one undo step;
//   • in a bar it wears − and + beside it (`steps`): every + has a −.
// Its rules (step, range, decimals, wrap) are `FlexNumberSpec`'s and its drag is `FlexNumberScrub`'s, the pure parts the
// Flexible page's box (FlexNumberBox) already proves; this is that box as the app-wide part.

import SwiftUI
import TopOptDesign

struct NumberField: View {
    enum Size {
        /// A setting row's number (74 pt at least).
        case setting
        /// Inside a bar (46 pt at least).
        case bare
        /// A depth that is also dragged on the part (it shows ↕).
        case withHandle

        var minWidth: CGFloat { self == .bare ? 46 : 74 }
    }

    /// The accessibility id and the published frame ("numberField-<key>").
    let key: String
    /// The setting's name (the pad's header).
    let title: String
    let spec: FlexNumberSpec
    var size: Size = .setting
    /// The pad's range when it is not the drag's (an open top: "150 % and up"). nil = `spec.range`.
    var padRange: NumberRange? = nil
    var allowsNegative = false
    /// − and + beside it (a bar's number).
    var steps = false
    /// The unit in the box (a row of sizes says "mm" once, after them; the pad still names it).
    var unitShown = true
    /// The pad's open state when the page drives it (Custom… opens it at once). nil = its own.
    var open: Binding<Bool>? = nil
    /// ★ B9 Setup: it wears the accent while its twin's pad is open (Flexible's handle box on the part ⇄ the list's number).
    var alsoLit = false
    /// ★ B9 Setup: the word it shows in place of the number until a drag or a typed value ("mixed": the faces differ).
    var word: String? = nil
    /// Commit, in the unit it shows: once per pad close, once per drag release, once per − / +.
    let onCommit: (Double) -> Void

    @Environment(\.numberPadNote) private var note
    @State private var ownOpen = false
    @State private var pending: Double?? = nil
    @State private var scrub: (raw: Double, shown: Double)?
    @State private var lastY: CGFloat = 0
    @State private var sideways = false

    static let height: CGFloat = 32
    static let target: CGFloat = 44
    static let tapSlop: CGFloat = 8

    private var isOpen: Bool { open?.wrappedValue ?? ownOpen }
    private func setOpen(_ v: Bool) { if let open { open.wrappedValue = v } else { ownOpen = v } }

    /// The pad's binding: closing it commits what was typed, BEFORE the page hears it closed (a page that hides the field
    /// on close would otherwise drop the value with the field).
    private var padBinding: Binding<Bool> {
        Binding(get: { isOpen }, set: { v in
            if !v, isOpen { commitTyped() }
            if v != isOpen { setOpen(v) }
        })
    }

    var body: some View {
        HStack(spacing: DS.Space.xs) {
            if steps { stepButton(-1) }
            Button { pending = nil; setOpen(true) } label: {
                face
                    .frame(height: Self.target)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .highPriorityGesture(drag)
            .numberPad(padBinding,
                       config: .init(title: title, unit: spec.unit, allowsDecimal: spec.decimals > 0,
                                     allowsNegative: allowsNegative, range: range, clampsOnClose: false),
                       seed: spec.value) { pending = .some($0) }
            // ★ B9 Setup: a page that closes it from outside (another box took the page's one keypad slot) still commits
            // what was typed — once (the pad's own close already cleared `pending`)
            .onChange(of: isOpen) { o in if !o { commitTyped() } }
            .background(NumberPad.published("numberField-\(key)"))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(title)
            .accessibilityValue("\(shown) \(spec.unit)")
            .accessibilityAdjustableAction { dir in
                let v = spec.snapped(spec.value + (dir == .increment ? spec.step : -spec.step))
                if v != spec.value { onCommit(v) }
            }
            .accessibilityIdentifier("numberField-\(key)")
            if steps { stepButton(1) }
        }
        .fixedSize()
    }

    private var range: NumberRange { padRange ?? NumberRange(spec.range) }

    private var shown: String {
        scrub.map { FlexNumberSpec.format($0.shown, decimals: spec.decimals) } ?? word ?? spec.text
    }

    /// The box: the number, its unit, the ↕ hint; the accent edge while its pad is open or a drag is live.
    private var face: some View {
        let lit = isOpen || scrub != nil || alsoLit
        return HStack(spacing: 4) {
            Text(shown)
                .font(.system(size: 14, weight: .semibold)).monospacedDigit()
                .foregroundStyle(DS.Color.textPrimary.color)
                .lineLimit(1).fixedSize()
                .accessibilityIdentifier("numberField-\(key)-value")
            if unitShown, !spec.unit.isEmpty {
                Text(spec.unit).font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(DS.Color.textTertiary.color)
                    .lineLimit(1).fixedSize()
            }
            Image(systemName: "chevron.up.chevron.down")
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle((size == .withHandle ? DS.Color.accent : DS.Color.textTertiary).color)
        }
        .padding(.horizontal, 9)
        .frame(minWidth: size.minWidth, alignment: .trailing)
        .frame(height: Self.height)
        .background(RoundedRectangle(cornerRadius: DS.Radius.field, style: .continuous).fill(DS.Color.fillSubtle.color)
            .overlay(RoundedRectangle(cornerRadius: DS.Radius.field, style: .continuous)
                .strokeBorder((lit ? DS.Color.accent : DS.Color.strokeStrong).color, lineWidth: lit ? 1.5 : 1)))
        .background(NumberPad.published("numberFieldBox-\(key)"))
    }

    private func stepButton(_ dir: Double) -> some View {
        Button {
            let v = spec.snapped(spec.value + dir * spec.step)
            if abs(v - spec.value) > 1e-12 { onCommit(v) }
        } label: {
            Image(systemName: dir < 0 ? "minus" : "plus")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(DS.Color.textPrimary.color)
                .frame(width: Self.target, height: Self.target)
                .background(Circle().fill(DS.Color.fillSubtle.color).frame(width: 32, height: 32))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(NumberPad.published("numberField-\(key)-\(dir < 0 ? "minus" : "plus")"))
        .accessibilityLabel(dir < 0 ? "Less \(title)" : "More \(title)")
        .accessibilityIdentifier("numberField-\(key)-\(dir < 0 ? "minus" : "plus")")
    }

    /// What the pad typed; out of its range the nearest allowed value, and the page says so ("Kept 40 (1 to 40 mm)").
    private func commitTyped() {
        defer { pending = nil }
        guard case .some(.some(var v)) = pending, v.isFinite else { return }
        if spec.wraps {
            v = spec.clamped(v)
        } else if !range.contains(v), !NumberPadProbe.controlOldPad {
            v = range.clamp(v)
            note?(range.keptNote(v, unit: spec.unit))
        }
        if abs(v - spec.value) > 1e-12 { onCommit(v) }
    }

    /// Up / down steps it, once the finger has travelled `tapSlop` mostly vertically; committed once, on release.
    private var drag: some Gesture {
        DragGesture(minimumDistance: Self.tapSlop)
            .onChanged { g in
                if sideways { return }
                if scrub == nil {
                    guard FlexNumberScrub.startsScrub(dx: Double(g.translation.width), dy: Double(g.translation.height)) else {
                        sideways = true; return
                    }
                    scrub = (spec.value, spec.value); lastY = g.translation.height
                    return
                }
                let dy = Double(g.translation.height - lastY)
                lastY = g.translation.height
                guard dy != 0, let s = scrub else { return }
                scrub = FlexNumberScrub.scrub(raw: s.raw, deltaY: dy, spec: spec)
            }
            .onEnded { _ in
                let done = scrub
                scrub = nil
                lastY = 0
                sideways = false
                if let done, abs(done.shown - spec.value) > 1e-12 { onCommit(done.shown) }
            }
    }
}
