// FlexibleStageChrome — the Flexible stage's entry card, stage title chip and its
// "delete and choose again" sheet (task 2026-09-29-flexible-screens S1; M10: Flexible
// "looks exactly like" Structural and Aesthetic).
//
// ★ THE SAME SHAPES, FONTS AND SPACING AS LatticeStageModeModal / LatticeStageModeSheet —
// copied from them rather than generalised, so #354's files keep their shape (the
// territory rule: only small additive hooks in their files). Accent: DS.Color.accentGreen,
// an existing token (no new colours). Purple only where he asked for it (round 4 D1, img 2):
// the depth prism and chip wear the lattice stage's face-prism purple (`facePrismToken`).

import SwiftUI
import simd
import TopOptDesign

public enum FlexibleStageStyle {
    public static let title = "Flexible"
    public static let tagline = "Graded to squish"
    /// Plain words (task S1): for squishy filaments; the part gives under weight; no
    /// strength certificate; every number shows where it comes from.
    public static let explanation =
        "For squishy filaments — TPU, TPE, PEBA and the foaming \u{201C}Air\u{201D} ones. "
        + "You draw how far each face should give under weight, and the app picks the "
        + "lattice that does it."
    public static let caveat =
        "No strength certificate. Every squish number shows where it comes from and how "
        + "far off it might be."

    public static var accent: Color { DS.Color.accentGreen.color }
    public static var accentToken: RGBA { DS.Color.accentGreen }
    /// ★ WHAT IS DRAWN ON THE PART BESIDE THE DENT MAP — the curves and their points, the
    /// depth chip and prism, the selected face — in DS textPrimary, never the map's green
    /// (verification of round 3: the ramp, the tints, the prism, the curves and the chip were
    /// all accentGreen, and the heat map read as shading in a green box). The green stays the
    /// page's accent (its dot, Generate) and the map's own ramp.
    public static var onPart: Color { DS.Color.textPrimary.color }
    public static var onPartToken: RGBA { DS.Color.textPrimary }
    /// ★ ROUND 4 (D1, HIS EXPLICIT REQUEST — img 2: "please use the same purple used in the rest
    /// of the lattice area's face-prisms"): the depth prism is the lattice stage's own face
    /// prism — `WorkspacePlaceholder.latticeRegionTint(.include)`, the density ramp's mid violet
    /// (FlexibleSettingsRound4Tests reads that line, so the two cannot drift) — and the depth
    /// chip wears the lattice stage's depth-knob glass. It overrides "never purple" for THIS
    /// element only; everything else on the part stays `onPart`.
    public static let facePrismToken = RGBA(124, 111, 214)
    public static var facePrismTint: SIMD3<Float> {
        SIMD3<Float>(Float(facePrismToken.r), Float(facePrismToken.g), Float(facePrismToken.b))
    }
    public static var facePrismKnob: RGBA { LatticeDensityProxy.densityColor(fraction: 0.6) }
    /// The modal's luminance rule (LatticeStageModeStyle.onAccent), on the green token.
    public static var onAccent: Color {
        let (r, g, b) = (48.0 / 255, 209.0 / 255, 88.0 / 255)   // #30D158
        return (0.299 * r + 0.587 * g + 0.114 * b) > 0.6
            ? Color(red: 0.07, green: 0.08, blue: 0.10) : .white
    }
}

/// The third card on the Lattice modal. Same layout as the modal's own `card(_:)`.
public struct FlexibleStageCard: View {
    public let focused: Bool
    public let onChoose: () -> Void
    public init(focused: Bool = false, onChoose: @escaping () -> Void) {
        self.focused = focused
        self.onChoose = onChoose
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            HStack(spacing: DS.Space.xs) {
                Circle().fill(FlexibleStageStyle.accent).frame(width: 10, height: 10)
                Text(FlexibleStageStyle.title)
                    .font(.system(size: 21, weight: .semibold))
                    .foregroundStyle(DS.Color.textPrimary.color)
            }
            Text(FlexibleStageStyle.tagline)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(FlexibleStageStyle.accent)
            Text(FlexibleStageStyle.explanation)
                .font(.system(size: 15))
                .foregroundStyle(DS.Color.textSecondary.color)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 2)
            Text(FlexibleStageStyle.caveat)
                .font(.system(size: 13))
                .foregroundStyle(DS.Color.textTertiary.color)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: DS.Space.l)
            Button { onChoose() } label: {
                Text("Use \(FlexibleStageStyle.title)")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(FlexibleStageStyle.onAccent)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, DS.Space.s)
            }
            .buttonStyle(.borderedProminent)
            .tint(FlexibleStageStyle.accent)
            .accessibilityIdentifier("lattice-mode-choose-flexible")
        }
        .padding(DS.Space.l)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous)
            .fill(DS.Surface.dialog.color))
        .overlay(RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous)
            .stroke(FlexibleStageStyle.accent.opacity(focused ? 0.9 : 0.35),
                    lineWidth: focused ? 2 : 1))
    }
}

/// The stage's title pill under Flexible (LatticeStageModeChip's shape).
public struct FlexibleStageChip: View {
    public let onTap: () -> Void
    public init(onTap: @escaping () -> Void) { self.onTap = onTap }
    public var body: some View {
        Button(action: onTap) {
            Text(FlexibleStageStyle.title)
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(FlexibleStageStyle.accent)
                .frame(maxWidth: .infinity)
                .padding(.vertical, DS.Space.s)
                .background(Capsule().fill(FlexibleStageStyle.accent.opacity(0.14)))
                .overlay(Capsule().stroke(FlexibleStageStyle.accent.opacity(0.45), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("lattice-mode-chip")
    }
}

/// What Flexible does and will not do, and the only way to unmake the choice — the
/// same two-tap delete as LatticeStageModeSheet.
public struct FlexibleStageSheet: View {
    public let onDelete: () -> Void
    public let onClose: () -> Void
    @State private var confirming = false

    public init(onDelete: @escaping () -> Void, onClose: @escaping () -> Void) {
        self.onDelete = onDelete
        self.onClose = onClose
    }

    static let limitations: [(String, String)] = [
        ("No certificate, no margin",
         "This stage never says a part is certified or accepted. Every squish number carries "
         + "its data tier and a \u{00B1} band, and a squish outside the tested data is refused "
         + "with the reason instead of guessed."),
        ("Numbers come from measured squash curves",
         "Published compression tests of printed TPU lattices (Iacob 2024), looked up and "
         + "inverted in the app's core. Not a simulation."),
        ("Numbers are after break-in",
         "A brand-new part is firmer for its first few squeezes."),
        ("Dents have sharper edges than real life",
         "Load does not spread sideways yet, so a small press on a big pad sinks less than "
         + "shown around it and the edge of a dent is sharper."),
        ("Side faces are estimates",
         "A face pushed from the side uses gyroid only and is labelled estimated until "
         + "sideways test pucks are measured."),
        ("Soft-over-firm layering comes later",
         "One squish profile per stack of material in this version."),
    ]

    public var body: some View {
        ZStack {
            Rectangle()
                .fill(.ultraThinMaterial)
                .overlay(Color.black.opacity(0.45))
                .ignoresSafeArea()
                .onTapGesture { onClose() }

            VStack(alignment: .leading, spacing: DS.Space.l) {
                HStack(alignment: .firstTextBaseline) {
                    Text(FlexibleStageStyle.title)
                        .font(.system(size: 27, weight: .semibold))
                        .foregroundStyle(FlexibleStageStyle.accent)
                    Text(FlexibleStageStyle.tagline)
                        .font(.system(size: 15))
                        .foregroundStyle(DS.Color.textTertiary.color)
                    Spacer()
                    Button { onClose() } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(DS.Color.textSecondary.color)
                            .padding(DS.Space.s)
                            .background(Circle().fill(DS.Surface.dialog.color))
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("lattice-mode-sheet-close")
                }
                Text("What this stage does, and what it will not do")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(DS.Color.textSecondary.color)
                VStack(alignment: .leading, spacing: DS.Space.m) {
                    ForEach(Array(Self.limitations.enumerated()), id: \.offset) { _, row in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(row.0)
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(DS.Color.textPrimary.color)
                            Text(row.1)
                                .font(.system(size: 14))
                                .foregroundStyle(DS.Color.textSecondary.color)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                Divider().overlay(Color.white.opacity(0.10))
                if confirming {
                    VStack(alignment: .leading, spacing: DS.Space.s) {
                        Text("This removes the filament, every loaded face, curve and stamp set "
                             + "in Flexible, and asks which kind of lattice to use again. It "
                             + "cannot be undone from here.")
                            .font(.system(size: 14))
                            .foregroundStyle(DS.Color.warning.color)
                            .fixedSize(horizontal: false, vertical: true)
                        HStack(spacing: DS.Space.m) {
                            Button("Cancel") { confirming = false }
                                .buttonStyle(.plain)
                                .font(.system(size: 15, weight: .medium))
                                .foregroundStyle(DS.Color.textSecondary.color)
                            Button { onDelete() } label: {
                                Text("Delete Flexible lattice")
                                    .font(.system(size: 15, weight: .semibold))
                                    .padding(.vertical, DS.Space.s)
                                    .padding(.horizontal, DS.Space.l)
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(DS.Color.warning.color)
                            .accessibilityIdentifier("lattice-mode-delete-confirm")
                        }
                    }
                } else {
                    Button { confirming = true } label: {
                        HStack(spacing: DS.Space.s) {
                            Image(systemName: "trash")
                            Text("Delete Flexible lattice and choose again")
                        }
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(DS.Color.warning.color)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("lattice-mode-delete")
                }
            }
            .padding(DS.Space.xl4)
            .frame(maxWidth: 720)
            .fixedSize(horizontal: false, vertical: true)
            .background(RoundedRectangle(cornerRadius: DS.Radius.sheet, style: .continuous)
                .fill(DS.Surface.sheet.color))
            .overlay(RoundedRectangle(cornerRadius: DS.Radius.sheet, style: .continuous)
                .stroke(Color.white.opacity(0.10), lineWidth: 1))
            .shadow(color: .black.opacity(0.45), radius: 40, y: 18)
        }
        .accessibilityIdentifier("flexible-stage-sheet")
    }
}
