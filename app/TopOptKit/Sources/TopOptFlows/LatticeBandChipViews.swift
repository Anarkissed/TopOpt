// LatticeBandChipViews.swift — the chip and its card (his 2026-09-27: "little chips
// tracked to the faces that, when clicked, asks whether it should grade to solid or not").
// Placement is `LatticeBandChipLayout` (pure, tested); this file only draws.

import SwiftUI
import TopOptDesign

/// ★ THE STAGE UI A CHIP MUST STAY OUT OF — each chrome element reports its frame in
/// `.global` (`latticeBandChipKeepOut()`), and the workspace hands the union to the layout.
struct LatticeBandChipKeepOutKey: PreferenceKey {
    static var defaultValue: [CGRect] = []
    static func reduce(value: inout [CGRect], nextValue: () -> [CGRect]) {
        value.append(contentsOf: nextValue())
    }
}

extension View {
    /// Report this view's frame as somewhere the band chips may not sit. Attach it BEFORE
    /// any full-screen `.frame(maxWidth: .infinity, …)` placement, or it measures the
    /// whole screen. The reader never takes a touch.
    func latticeBandChipKeepOut() -> some View {
        background(GeometryReader { g in
            Color.clear.preference(key: LatticeBandChipKeepOutKey.self,
                                   value: [g.frame(in: .global)])
        }
        .allowsHitTesting(false))
    }
}

/// One chip: a 24 pt disc, blue when the band goes SOLID there (the legend's rim & skin
/// hue), lilac when the lattice runs through (the interior hue), a dot when the user has
/// overridden the rule. Tapping opens its card.
struct LatticeBandChipView: View {
    let placement: LatticeBandChipPlacement
    @Binding var isOpen: Bool
    /// A segment was tapped (the solid-ness chosen).
    let onChoose: (Bool) -> Void
    /// "Use default".
    let onDefault: () -> Void

    private var tint: Color {
        let c = placement.solid ? LatticeStructureColour.rim : LatticeStructureColour.interior
        return Color(.sRGB, red: c.r, green: c.g, blue: c.b, opacity: 1)
    }

    private var glyph: String {
        switch (placement.decision.kind, placement.solid) {
        case (.face, true):  return "square.fill"
        case (.face, false): return "square.grid.3x3"
        case (.cap, true):   return "square.bottomhalf.filled"
        case (.cap, false):  return "square.dashed"
        }
    }

    var body: some View {
        Button { isOpen.toggle() } label: {
            ZStack {
                Circle()
                    .fill(tint.opacity(placement.pending ? 0.55 : 0.92))
                    .overlay(Circle().strokeBorder(DS.Color.textPrimary.opacity(0.85).color,
                                                   lineWidth: isOpen ? 2.5 : 1.5))
                    .frame(width: LatticeBandChipLayout.chipDiameter,
                           height: LatticeBandChipLayout.chipDiameter)
                    // a small lift off the struts — the panel token's 22 pt blur would
                    // swamp a 24 pt disc
                    .shadow(color: DS.Color.background.opacity(0.6).color, radius: 3, x: 0, y: 1)
                Image(systemName: glyph)
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(DS.Color.textPrimary.color)
                if placement.overridden {
                    Circle()
                        .fill(DS.Color.textPrimary.color)
                        .overlay(Circle().strokeBorder(tint, lineWidth: 1.5))
                        .frame(width: 8, height: 8)
                        .offset(x: 9, y: -9)
                }
            }
            // ★ the HIG touch target around a small disc (`KeepOutSolver.minTouch`)
            .frame(width: LatticeBandChipLayout.touchSize, height: LatticeBandChipLayout.touchSize)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(LatticeBandChipText.accessibility(placement))
        .accessibilityIdentifier("band-chip-\(placement.decision.key)")
        .popover(isPresented: $isOpen) {
            LatticeBandChipCard(placement: placement, onChoose: onChoose, onDefault: onDefault)
        }
    }
}

/// The card a chip opens: what it is, the two answers, what the chosen one means, and the
/// way back to the rule when it has been overridden.
struct LatticeBandChipCard: View {
    let placement: LatticeBandChipPlacement
    let onChoose: (Bool) -> Void
    let onDefault: () -> Void

    var body: some View {
        let d = placement.decision
        let seg = LatticeBandChipText.segments(d.kind)
        VStack(alignment: .leading, spacing: DS.Space.sm) {
            VStack(alignment: .leading, spacing: 2) {
                Text(d.label)
                    .dsStyle(DS.TypeScale.bodyStrong).fontWeight(.semibold)
                    .foregroundStyle(DS.Color.textPrimary.color)
                Text(d.kind == .face ? "Face the lattice reaches" : "Where the lattice's depth ends")
                    .dsStyle(DS.TypeScale.caption2)
                    .foregroundStyle(DS.Color.textTertiary.color)
            }
            SegmentedGlass([.init(true, seg.solid), .init(false, seg.open)],
                           selection: Binding(get: { placement.solid },
                                              set: { onChoose($0) }))
            Text(LatticeBandChipText.explanation(d.kind, solid: placement.solid))
                .dsStyle(DS.TypeScale.caption)
                .foregroundStyle(DS.Color.textSecondary.color)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: DS.Space.s) {
                Text("Default: \(d.defaultSolid ? seg.solid : seg.open)")
                    .dsStyle(DS.TypeScale.footnote)
                    .foregroundStyle(DS.Color.textTertiary.color)
                Spacer(minLength: 0)
                if placement.overridden {
                    Button(action: onDefault) {
                        Text("Use default")
                            .dsStyle(DS.TypeScale.footnote).fontWeight(.semibold)
                            .foregroundStyle(DS.Color.accent.color)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("band-chip-use-default")
                }
            }
        }
        .padding(DS.Space.l)
        .frame(width: 292)
        .accessibilityIdentifier("band-chip-card")
    }
}
