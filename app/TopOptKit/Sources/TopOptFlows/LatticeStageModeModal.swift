// LatticeStageModeModal — ★★★ THE CHOICE, ASKED ONCE, BEFORE THE STAGE OPENS
// (maintainer, 2026-08-21: "implement it with a Modal at the start, right when you
// switch over that covers the screen and blurs everything out. This cannot be changed
// again afterwards. Explain the two differences clearly.").
//
// ★ WHY IT BLOCKS RATHER THAN DEFAULTS. The two modes produce different RECEIPTS about
// the same object: a structural lattice is covered by the strength certificate, an
// aesthetic one is not and is stamped out of regime for the material below the accuracy
// floor. A default would mean a part graded under one claim and read under the other,
// with nothing on screen saying which — the exact class of silent divergence this branch
// has spent a week paying down. So there is no default and no dismissal: the sheet is
// not interactively dismissable and carries no cancel.
//
// ★ AND IT IS NOT REOPENABLE. Once answered it is a property of the stage. See
// `LatticeStageMode` for what actually differs — it is core's `GradingIntent`, not a
// presentation flag.

import SwiftUI
import TopOptDesign

/// The full-screen, blurring, un-dismissable chooser.
public struct LatticeStageModeModal: View {
    /// Called with the chosen mode. The caller records it and never asks again.
    public let onChoose: (LatticeStageMode) -> Void
    @State private var focused: LatticeStageMode?

    public init(onChoose: @escaping (LatticeStageMode) -> Void) {
        self.onChoose = onChoose
    }

    public var body: some View {
        ZStack {
            // ★ THE BLUR IS THE POINT — "covers the screen and blurs everything out".
            // A material rather than a flat scrim so the part stays legible behind it:
            // the choice is ABOUT that part, and hiding it entirely would make this feel
            // like a modal error rather than a question about the thing on screen.
            Rectangle()
                .fill(.ultraThinMaterial)
                .overlay(Color.black.opacity(0.45))
                .ignoresSafeArea()

            // ★★ ONE CONTAINING SQUIRCLE, NOT TWO CARDS FLOATING ON A SCRIM. The
            // question and its two answers are one object; drawing them as three
            // separate things on a blur made the header read as page furniture rather
            // than as the thing the cards answer.
            VStack(spacing: DS.Space.xl2) {
                VStack(spacing: DS.Space.xs) {
                    Text("How should this lattice be graded?")
                        .font(.system(size: 27, weight: .semibold))
                        .foregroundStyle(DS.Color.textPrimary.color)
                    Text("This is set once for the Lattice stage and cannot be changed "
                         + "afterwards.")
                        .font(.system(size: 15))
                        .foregroundStyle(DS.Color.textTertiary.color)
                        .multilineTextAlignment(.center)
                }

                // ★ EQUAL-HEIGHT CARDS, MEASURED — NOT A HARD-CODED HEIGHT. Two
                // earlier attempts pinned the card to a literal (232, then 246); both
                // were guesses at how many lines the longest paragraph wraps to, and
                // both were wrong at the second string — the aesthetic button hung out
                // through the bottom of its own card and through the dialog. Here the
                // HStack is sized by its TALLEST child (`fixedSize` vertically proposes
                // nil, so each card reports its ideal height), and `maxHeight: .infinity`
                // then stretches the SHORTER card to match. The buttons share a row
                // because the spacer inside each card pushes to the same bottom edge,
                // and the copy can change length without anyone editing a number.
                HStack(alignment: .top, spacing: DS.Space.m) {
                    card(.structural)
                    card(.aesthetic)
                }
                .fixedSize(horizontal: false, vertical: true)
            }
            .padding(DS.Space.xl4)
            .frame(maxWidth: 800)
            .fixedSize(horizontal: false, vertical: true)
            .background(
                RoundedRectangle(cornerRadius: DS.Radius.sheet, style: .continuous)
                    .fill(DS.Surface.sheet.color))
            .overlay(
                RoundedRectangle(cornerRadius: DS.Radius.sheet, style: .continuous)
                    .stroke(Color.white.opacity(0.10), lineWidth: 1))
            .shadow(color: .black.opacity(0.45), radius: 40, y: 18)
        }
        .accessibilityIdentifier("lattice-mode-modal")
    }

    @ViewBuilder
    private func card(_ mode: LatticeStageMode) -> some View {
        let isFocused = focused == mode
        VStack(alignment: .leading, spacing: DS.Space.s) {
            HStack(spacing: DS.Space.xs) {
                Circle()
                    .fill(LatticeStageModeStyle.accent(mode))
                    .frame(width: 10, height: 10)
                Text(mode.title)
                    .font(.system(size: 21, weight: .semibold))
                    .foregroundStyle(DS.Color.textPrimary.color)
            }
            Text(mode.tagline)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(LatticeStageModeStyle.accent(mode))

            Text(mode.explanation)
                .font(.system(size: 15))
                .padding(.top, 2)
                .foregroundStyle(DS.Color.textSecondary.color)
                .fixedSize(horizontal: false, vertical: true)

            // ★ THE CLAIM, WHERE THERE IS ONE. Core authors this sentence; the app only
            // shows it, so what the receipt promises and what the modal promises cannot
            // drift apart.
            if let caveat = mode.receiptCaveat {
                Text(caveat)
                    .font(.system(size: 13))
                    .foregroundStyle(DS.Color.textTertiary.color)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 2)
            }

            // ★ THE BUTTONS SHARE A ROW. Both cards take the same minimum height and
            // the spacer pushes each button to its own bottom edge, so the two land on
            // one line however unequal the paragraphs above them are. Without it the
            // longer card's button sat a paragraph lower than the shorter one's.
            Spacer(minLength: DS.Space.l)

            Button {
                focused = mode
                onChoose(mode)
            } label: {
                Text("Use \(mode.title)")
                    .font(.system(size: 16, weight: .semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, DS.Space.s)
            }
            .buttonStyle(.borderedProminent)
            .tint(LatticeStageModeStyle.accent(mode))
            .accessibilityIdentifier("lattice-mode-choose-\(mode.rawValue)")
        }
        .padding(DS.Space.l)
        // ★ FILL THE ROW'S HEIGHT, WHATEVER THE TALLER CARD SET IT TO. Bare
        // `maxHeight: .infinity` under a screen-sized parent would stretch each card the
        // full length of the iPad; it is safe here only because the HStack above carries
        // `fixedSize(vertical:)`, which caps the row at the taller card's ideal height.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous)
                .fill(DS.Surface.dialog.color))
        .overlay(
            RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous)
                .stroke(LatticeStageModeStyle.accent(mode).opacity(isFocused ? 0.9 : 0.35),
                        lineWidth: isFocused ? 2 : 1))
    }
}

/// ★★ THE VISUAL DIFFERENCE, IN ONE PLACE ("ensure there is some sort of visual
/// difference and a title somewhere that says Structural or Aesthetic").
///
/// One accent per mode, used by the modal, by the persistent stage title, and by the
/// lattice's own chrome — so the mode is legible at a glance from anywhere on the stage
/// rather than only in a settings row nobody is looking at.
public enum LatticeStageModeStyle {
    /// Structural reads as the app's own blue — the certified path, continuous with
    /// every other structural affordance. Aesthetic reads violet, the colour the lattice
    /// legend already uses for interior fill, because that is the thing it is about.
    public static func accent(_ mode: LatticeStageMode) -> Color {
        switch mode {
        case .structural: return Color(red: 0.20, green: 0.55, blue: 1.00)
        case .aesthetic:  return Color(red: 0.62, green: 0.44, blue: 0.96)
        }
    }
}

/// ★★ THE MODE, AS A TITLE — not a badge tucked into a corner.
///
/// It sits in the stage's TOP row, immediately right of the way back, and it is set at
/// title weight because it is the single most consequential thing about the stage: it
/// decides what the receipt claims. A small chip under the back button read as
/// decoration and, at the size it was, collided with it.
public struct LatticeStageModeChip: View {
    public let mode: LatticeStageMode
    public init(mode: LatticeStageMode) { self.mode = mode }

    public var body: some View {
        HStack(spacing: DS.Space.s) {
            Circle()
                .fill(LatticeStageModeStyle.accent(mode))
                .frame(width: 10, height: 10)
            Text(mode.title)
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(LatticeStageModeStyle.accent(mode))
        }
        .padding(.horizontal, DS.Space.l)
        .padding(.vertical, DS.Space.s)
        .background(
            Capsule().fill(LatticeStageModeStyle.accent(mode).opacity(0.14)))
        .overlay(
            Capsule().stroke(LatticeStageModeStyle.accent(mode).opacity(0.45), lineWidth: 1))
        .accessibilityIdentifier("lattice-mode-chip")
    }
}
