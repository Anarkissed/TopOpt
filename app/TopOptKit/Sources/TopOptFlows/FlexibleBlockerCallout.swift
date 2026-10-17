// FlexibleBlockerCallout — a blocker pops AT ONCE above the corner pair, with 1–3 fixes (task 2026-09-29-flexible-screens,
// round 7, batch R7-D1: his pick 1, A1's callout).
//
// His rule (2026-09-29): "blockers surface at once as a pop-up … with 1–3 fix buttons". His pick: "Blockers pop at once
// above the pair." The mockup: "How much weight presses Face 1?" with [Set it in Squish ›] [Face 1 rests].
//
// ★ ONCE PER ISSUE (FlexibleCalloutRule): a NEW blocking issue (its stable id) pops; the same issue recomputed never pops
// again by itself, and a dismissed one stays dismissed — the Lattice button's main zone ("Fix: …") brings it back. An
// ADVISORY never pops (batch E's "no lattice under Face 3" stays on the button's line and in the card). While the card is
// open the issue is the card's Core row instead (one card at a time).
// ★ ITS FIXES are the issue's own, applied exactly as the Squish page's pop-up applies them (FlexibleFixPopup.apply —
// undoable, saved like every edit); a fix that lives on the Squish page (a weight to type) is ONE button, "Fix in
// Squish ›", which opens that page on the issue (openFix + the capsule's Squish).

import SwiftUI
import TopOptDesign

/// Which blocker pops: each new one once.
public struct FlexibleCalloutRule: Equatable, Sendable {
    /// The issue ids already popped (or dismissed) this session.
    public private(set) var seen: Set<String> = []
    /// Test control only: keyed on every recompute (a blocker pops again and again).
    var controlEveryRecompute = false

    public init() {}

    /// The issue to pop for this status, if any.
    public mutating func next(_ s: FlexibleMainStatus) -> FlexibleIssue? {
        guard s.tone == .fix, let f = s.fix else { return nil }
        if controlEveryRecompute { return f }
        guard !seen.contains(f.id) else { return nil }
        seen.insert(f.id)
        return f
    }
}

public enum FlexibleBlockerCallout {
    public enum Button: Equatable, Sendable { case apply(FlexibleFix), squish }

    public static let title = "Fix 1 thing"
    public static let squishTitle = "Fix in Squish \u{203A}"

    /// The issue's fixes as the callout's 1–3 buttons: a weight to type (or a press that needs one) is the Squish page's —
    /// ONE "Fix in Squish ›"; every other fix applies here.
    static func buttons(_ issue: FlexibleIssue, pressNeedsWeight: (Int) -> Bool) -> [Button] {
        var out: [Button] = []
        for f in issue.fixes {
            let b: Button
            switch f {
            case .weight: b = .squish
            case .press(let r) where pressNeedsWeight(r): b = .squish
            default: b = .apply(f)
            }
            if !out.contains(b) { out.append(b) }
            if out.count == 3 { break }
        }
        if out.isEmpty { out = [.squish] }
        return out
    }

    /// "Fix in Squish ›": the Squish page opens on the issue.
    static func goToSquish(openFix: () -> Void, openSquish: () -> Void) {
        openFix()
        openSquish()
    }
}

/// The callout.
struct FlexibleBlockerCalloutView: View {
    @ObservedObject var model: FlexibleStageModel
    let issue: FlexibleIssue
    let width: CGFloat
    let close: () -> Void
    let squish: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            HStack(spacing: DS.Space.s) {
                Image(systemName: "exclamationmark.circle.fill").font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(DS.Color.warning.color)
                Text(FlexibleBlockerCallout.title).font(.system(size: 14.5, weight: .semibold)).foregroundStyle(DS.Color.warning.color)
                Spacer(minLength: 0)
                FlexibleCornerPairStyle.x44("xmark", label: "Dismiss", id: "flexible-callout-close", action: close)
            }
            .frame(minHeight: 44)
            Text(issue.oneLine)
                .font(.system(size: 14)).foregroundStyle(DS.Color.textPrimary.color)
                .fixedSize(horizontal: false, vertical: true)
                .said(issue.oneLine)
                .accessibilityIdentifier("flexible-callout-line")
            FlexibleCalloutButtons(model: model, issue: issue, close: close, squish: squish)
                .padding(.bottom, DS.Space.xs)
        }
        .padding(.horizontal, DS.Space.ml).padding(.vertical, DS.Space.m)
        .frame(width: width, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: DS.Radius.panelSmall, style: .continuous).fill(DS.Surface.dialog.color)
            .overlay(RoundedRectangle(cornerRadius: DS.Radius.panelSmall, style: .continuous)
                .strokeBorder(DS.Color.warning.color.opacity(0.55), lineWidth: 1)))
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: DS.Radius.panelSmall, style: .continuous))
        .dsShadow(DS.Shadow.panel)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("flexible-blocker-callout")
    }
}

/// ★ ROUND 7, the review of R7-D1: the callout's 1–3 fix buttons, shared with the Lattice card's Core row (the review: "With
/// a fix pending, the card adds a tap … 'Show the fix' only opens the callout, so fixing takes two taps; his rule is 1–3
/// fixes shown at once") — the same buttons, applied the same way (FlexibleFixPopup.apply), "Fix in Squish ›" for a weight.
struct FlexibleCalloutButtons: View {
    @ObservedObject var model: FlexibleStageModel
    let issue: FlexibleIssue
    let close: () -> Void
    let squish: () -> Void

    var body: some View {
        let buttons = FlexibleBlockerCallout.buttons(issue, pressNeedsWeight: { model.pressNeedsWeight($0) })
        HStack(spacing: DS.Space.s) {
            ForEach(Array(buttons.enumerated()), id: \.offset) { i, b in
                switch b {
                case .squish:
                    FlexibleCornerPairStyle.big(FlexibleBlockerCallout.squishTitle, primary: i == 0, id: "flexible-callout-squish", action: squish)
                case .apply(let f):
                    FlexibleCornerPairStyle.big(f.title { model.displayName($0) }, primary: i == 0, id: "flexible-callout-\(FlexibleFixPopup.id(f))") {
                        FlexibleFixPopup.apply(f, to: model)
                        close()
                    }
                }
            }
        }
    }
}
