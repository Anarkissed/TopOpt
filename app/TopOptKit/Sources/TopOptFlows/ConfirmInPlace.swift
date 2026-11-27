// ConfirmInPlace — every delete asks first, IN PLACE.
//
// Lifted from #362 (claude/flexible-screens) at b472880b, app/TopOptKit/Sources/TopOptFlows/FlexibleConfirmInPlace.swift, as a
// neutral shared component (reviewer ruling 2026-10-24 07:30). #362 swaps its Flexible* copy for this one on its next sync of
// #354.
//
// Copied, not redesigned. What changed from the source, and only that:
//   * FlexibleConfirmInPlace → ConfirmInPlace, FlexibleCancelInPlace → CancelInPlace, FlexibleConfirmCopy → ConfirmCopy,
//     FlexibleConfirmLayout → ConfirmLayout, FlexibleConfirmControlWidthKey → ConfirmControlWidthKey, the alignment
//     `.flexKeepCentre` → `.keepCentre`, FlexibleKeepOutKey → ChromeKeepOutKey;
//   * the accessibility ids take `idPrefix` (the source's "flexible" gives its ids back);
//   * the 44 pt targets are ConfirmLayout.target (the source read FlexibleTargets, whose `controlSmall` red control is
//     Flexible's round-7 F check);
//   * the take-out question's red control `controlTakeOutFullName` lives on ConfirmCopy (the source: FlexibleStageModel);
//   * not lifted (Flexible-only): every FlexibleStageModel extension (dropInPlaceAsks, the face / press / Reset-all / fix asks,
//     tapPressFix, applyPressFixNow, sealAfterReopen, reopenLanded and their red controls) and FlexibleFixAsk (keyed on
//     FlexibleStageModel.fixRemoveAsk).
//
// THE RULE (one for every delete; his Img13, 2026-10-21): the tapped control's place turns into [Keep] (or [Cancel]) — its CENTRE
// exactly where the tapped control's centre was and at least as wide as the control, so a second tap anywhere on the same spot
// only cancels; the question and the red button sit to its LEFT, the red button's trailing edge at least `gap` (24 pt) left of
// Keep's leading edge — so confirming needs a move. The first button of a left-aligned row puts its red button on the RIGHT.

import SwiftUI
import TopOptDesign

/// Keep's centre on the tapped control's centre: the overlay aligns this guide of its content with the control's.
extension HorizontalAlignment {
    private enum KeepCentre: AlignmentID {
        static func defaultValue(in d: ViewDimensions) -> CGFloat { d[HorizontalAlignment.center] }
    }
    static let keepCentre = HorizontalAlignment(KeepCentre.self)
}

enum ConfirmCopy {
    static let keep = "Keep"
    static let cancel = "Cancel"
    /// ★ RED CONTROL: the take-out question with the whole section name ("Take Face 6 · lattice out?").
    nonisolated(unsafe) static var controlTakeOutFullName = false
    /// The face's own name only — a section suffix (" · lattice A") is dropped from the question.
    static func takeOutAsk(_ name: String) -> String {
        if controlTakeOutFullName { return "Take \(name) out?" }
        let short = name.components(separatedBy: " \u{00B7} ").first ?? name
        return "Take \(short) out?"
    }
    static let takeOut = "Take out"
    static func removeAsk(_ name: String) -> String { "Remove \(name)?" }
    static let remove = "Remove"
}

enum ConfirmLayout {
    /// The clear space between the red button's trailing edge and Keep's leading edge.
    static let gap: CGFloat = 24
    /// Keep's width (its height is a finger's 44 pt) — wide enough for "Cancel".
    static let keepWidth: CGFloat = 64
    /// A finger's target.
    static let target: CGFloat = 44
}

/// The ask on a delete control: while `asking`, the control is hidden and [Keep] sits centred on it, the question and the red
/// button to its left. Frames: "<keepKey>" and "<confirmKey>" (ChromeKeepOutKey).
struct ConfirmInPlace: ViewModifier {
    let asking: Bool
    let question: String?
    let destructive: String
    var keep: String = ConfirmCopy.keep
    let confirmKey: String
    let keepKey: String
    var questionID: String? = nil
    /// The FIRST button of a left-aligned row has nothing to its left, so its red button goes to the RIGHT of [Keep] (the same
    /// ≥ 24 pt move).
    var redOnTrailing: Bool = false
    var idPrefix: String = "stage"
    let confirm: () -> Void
    let cancel: () -> Void

    /// ★ RED CONTROL (hosted): the old placement — the question, [Delete] then [Keep] at the row's trailing end, Keep NOT on the
    /// tapped spot.
    @MainActor static var controlOldPlacement = false
    /// ★ RED CONTROL (hosted): the red button always on the left — a first fix's [Remove] leaves its row.
    @MainActor static var controlRedAlwaysLeading = false
    /// ★ RED CONTROL (hosted): [Keep] always 64 pt wide — on a wide button the red one then sits over the button he tapped.
    @MainActor static var controlGapFromKeepOnly = false

    /// The tapped control's own width (measured while it shows).
    @State private var controlWidth: CGFloat = 0

    /// [Keep] covers the WHOLE tapped control — never narrower than it — so the red button's ≥ 24 pt gap is measured from the
    /// control's own edge.
    @MainActor var keepFrameWidth: CGFloat {
        Self.controlGapFromKeepOnly ? ConfirmLayout.keepWidth : max(ConfirmLayout.keepWidth, controlWidth.rounded(.up))
    }

    func body(content: Content) -> some View {
        content
            .background(GeometryReader { g in Color.clear.preference(key: ConfirmControlWidthKey.self, value: g.size.width) })
            .onPreferenceChange(ConfirmControlWidthKey.self) { controlWidth = $0 }
            .transformPreference(ConfirmControlWidthKey.self) { $0 = 0 }   // (never an enclosing ask's)
            .opacity(asking ? 0 : 1)
            .allowsHitTesting(!asking)
            .overlay(alignment: Alignment(horizontal: .keepCentre, vertical: .center)) {
                if asking { line.fixedSize() }
            }
    }

    @ViewBuilder private var line: some View {
        let red = Button(action: confirm) {
            Text(destructive).font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                .lineLimit(1).fixedSize()
                .padding(.horizontal, 12).frame(height: 32)
                .background(Capsule().fill(DS.Color.danger.color))
                .frame(minWidth: ConfirmLayout.target, minHeight: ConfirmLayout.target)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(Self.publish(confirmKey))
        .accessibilityIdentifier("\(idPrefix)-confirm-\(confirmKey)")
        let keepButton = Button(action: cancel) {
            Text(keep).font(.system(size: 13, weight: .semibold)).foregroundStyle(DS.Color.textPrimary.color)
                .lineLimit(1).fixedSize()
                .frame(width: keepFrameWidth - 8, height: 32)
                .background(Capsule().fill(DS.Color.chipSolid.color))
                .frame(width: keepFrameWidth, height: ConfirmLayout.target)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(Self.publish(keepKey))
        .accessibilityIdentifier("\(idPrefix)-keep-\(keepKey)")
        HStack(spacing: 0) {
            if let q = question {
                Text(q).font(.system(size: 13, weight: .semibold)).foregroundStyle(DS.Color.textPrimary.color)
                    .lineLimit(1).fixedSize()
                    .padding(.trailing, DS.Space.s)
                    .background(Self.publish(confirmKey + "Question"))
                    .accessibilityIdentifier(questionID ?? "\(idPrefix)-confirm-question")
            }
            if redOnTrailing, !Self.controlRedAlwaysLeading, !Self.controlOldPlacement {
                keepButton.alignmentGuide(.keepCentre) { $0[HorizontalAlignment.center] }
                Color.clear.frame(width: ConfirmLayout.gap, height: 1)
                red
            } else if Self.controlOldPlacement {
                // (the red control: Keep last, past the red button, its centre off the tapped spot)
                red
                Color.clear.frame(width: DS.Space.s, height: 1)
                keepButton
                Color.clear.frame(width: ConfirmLayout.keepWidth, height: 1)
                    .alignmentGuide(.keepCentre) { $0[HorizontalAlignment.center] }
            } else {
                red
                Color.clear.frame(width: ConfirmLayout.gap, height: 1)
                keepButton.alignmentGuide(.keepCentre) { $0[HorizontalAlignment.center] }
            }
        }
        // (no backdrop: the caller hides what the line would cover — the row's name, its chips — while it asks)
        .accessibilityElement(children: .contain)
    }

    static func publish(_ key: String) -> some View {
        GeometryReader { g in Color.clear.preference(key: ChromeKeepOutKey.self, value: [key: g.frame(in: .global)]) }
            .allowsHitTesting(false)
    }
}

private struct ConfirmControlWidthKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

/// The list's variant: [Cancel] takes the tapped control's place (centred on it); the question and [Delete] are drawn by the
/// caller on the lines under it (`DeleteConfirm`).
struct CancelInPlace: ViewModifier {
    let asking: Bool
    let keepKey: String
    var idPrefix: String = "stage"
    let cancel: () -> Void

    func body(content: Content) -> some View {
        let asking = self.asking && !ConfirmInPlace.controlOldPlacement   // (the red control: the trash stays, no Cancel on it)
        content
            .opacity(asking ? 0 : 1)
            .allowsHitTesting(!asking)
            .overlay {
                if asking {
                    Button(action: cancel) {
                        Text(ConfirmCopy.cancel).font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(DS.Color.textPrimary.color)
                            .lineLimit(1).fixedSize()
                            .frame(width: ConfirmLayout.keepWidth - 8, height: 32)
                            .background(Capsule().fill(DS.Color.chipSolid.color))
                            .frame(width: ConfirmLayout.keepWidth, height: ConfirmLayout.target)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .fixedSize()
                    .background(ConfirmInPlace.publish(keepKey))
                    .accessibilityIdentifier("\(idPrefix)-delete-cancel")
                }
            }
    }
}
