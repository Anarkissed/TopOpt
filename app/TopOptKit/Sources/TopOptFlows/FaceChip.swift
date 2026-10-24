// FaceChip — the pieces of the chip AT THE FACE: its [▦ Lattice | ■ Solid | ⬚ Off] segment, the filled join button and the
// new-face buttons.
//
// Lifted from #362 (claude/flexible-screens) at b472880b, app/TopOptKit/Sources/TopOptFlows/FlexibleFaceChip.swift, as a
// neutral shared component (reviewer ruling 2026-10-24 07:30). #362 swaps its Flexible* copy for this one on its next sync of
// #354.
//
// Copied, not redesigned. What changed from the source, and only that:
//   * FlexibleFaceChip's statics → `enum FaceChip` (protectTint, segmentWidth); its private segment → FaceStateSegment;
//     FlexibleJoinButton → JoinButton, FlexibleJoinButtonStyle → JoinButtonStyle, FlexibleNewFaceButton → NewFaceButton,
//     FlexibleNewFaceKind → NewFaceKind (the same five cases and raw values), FlexibleKeepOutKey → ChromeKeepOutKey;
//   * the words are SelectionsCopy's (the source's FlexibleSelectionsCopy: joinLabel, kindWord); the lattice tint is
//     StateGlyph.latticeTint (the source's FlexibleStageStyle.facePrismToken, the same RGBA);
//   * the accessibility ids take `idPrefix` (the source's "flexible" gives its ids back);
//   * not lifted (Flexible-only): the chip view itself (its kinds N / M / G / B / L are driven by FlexibleMainStage,
//     FlexibleFaceScope, FlexibleFaceCommits and the Attach step), `kind(_:project:lastGroup:main:attachCompact:)`,
//     `loadWeight` (FlexibleWeightUnit, lattice.flexible), `roleReading` (FlexibleFaceCommits.readsLattice), and the title,
//     role, face, all, action, ask and close lines (FlexibleMainStage.missTap).
//
// His change (c), 2026-10-14: "Please make it more obvious that an 'Add to group C as lattice' is an obvious button and not just
// a title." — a FILLED button (the DS accent, white semibold label, the group's swatch, 48 tall).

import SwiftUI
import TopOptDesign

public enum FaceChip {
    static let protectTint = RGBA(hex: 0x2EE0C7)
    static let segmentWidth: CGFloat = 80
}

/// The new-face buttons' kinds (copied from FlexibleNewFaceKind).
public enum NewFaceKind: String, CaseIterable, Sendable { case lattice, anchor, load, protect, keepClear }

/// [▦ Lattice | ■ Solid | ⬚ Off]: 3 × 80, 36 tall, in a 44 pt target.
struct FaceStateSegment: View {
    let current: LatticeSelectableRole?
    let mixed: Bool
    var idPrefix: String = "stage"
    let set: (LatticeSelectableRole) -> Void

    var body: some View {
        HStack(spacing: 2) {
            ForEach([LatticeSelectableRole.include, .exclude, .off], id: \.self) { r in
                let on = !mixed && current == r
                Button { set(r) } label: {
                    HStack(spacing: 4) {
                        StateGlyph(role: r.regionRole)
                        Text(r == .include ? "Lattice" : r == .exclude ? "Solid" : "Off")
                            .font(.system(size: 12.5, weight: .semibold))
                            .foregroundStyle((on ? DS.Color.textPrimary : DS.Color.textSecondary).color)
                    }
                    .frame(width: FaceChip.segmentWidth, height: 36)
                    .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(on ? DS.Color.fillSelected.color : Color.clear))
                    .frame(height: 44).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel((r == .include ? "Lattice" : r == .exclude ? "Solid" : "Off") + (on ? ", selected" : ""))
                .accessibilityIdentifier("\(idPrefix)-chip-seg-\(r.rawValue)")
                .background(CornerPairStyle.publish("chipSeg-\(r.rawValue)"))
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(DS.Color.fillSubtle.color))
    }
}

/// His change (c): "Add to Group C as lattice" — a FILLED button (the DS accent, white semibold label, the group's swatch
/// with a white ring, 48 tall, radius 14, the accent glow, 85 % when pressed, the button trait), the depth it takes under it.
struct JoinButton: View {
    let group: SelectionGroup
    let note: String
    var idPrefix: String = "stage"
    let action: () -> Void
    static let height: CGFloat = 48
    static let fill = DS.Color.accent

    var body: some View {
        Button(action: action) {
            HStack(spacing: DS.Space.s) {
                Image(systemName: "plus.circle.fill").font(.system(size: 20, weight: .semibold)).foregroundStyle(.white)
                // ★ the review of R7-D2: a blue group's swatch vanished on the blue fill — a dark ring inside the white one
                Circle().fill(group.color.color).frame(width: 14, height: 14)
                    .overlay(Circle().strokeBorder(Color.black.opacity(0.45), lineWidth: 3))
                    .overlay(Circle().strokeBorder(Color.white, lineWidth: 1.5))
                VStack(alignment: .leading, spacing: 1) {
                    Text(SelectionsCopy.joinLabel(group.name))
                        .font(.system(size: 15, weight: .semibold)).foregroundStyle(.white).lineLimit(1)
                        .accessibilityIdentifier("\(idPrefix)-chip-join-label")
                    Text(note).font(.system(size: 11.5, weight: .medium)).foregroundStyle(Color.white.opacity(0.82)).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, DS.Space.m)
            .frame(maxWidth: .infinity, minHeight: Self.height)
        }
        .buttonStyle(JoinButtonStyle())
        .background(GeometryReader { g in Color.clear.preference(key: ChromeKeepOutKey.self, value: ["chipJoin": g.frame(in: .global)]) }
            .allowsHitTesting(false))
        .accessibilityLabel(SelectionsCopy.joinLabel(group.name))
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier("\(idPrefix)-chip-join")
    }
}

struct JoinButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(JoinButton.fill.color))
            .dsShadow(DS.Shadow.accentGlow)
            .opacity(configuration.isPressed ? 0.85 : 1)
    }
}

/// One of chip N's five buttons (and the role line's four): an 18 pt glyph over an 11.5 pt bold word, 64 × 56.
struct NewFaceButton: View {
    let kind: NewFaceKind
    var lit: Bool = false
    /// Protect locked on (a Lattice group) — a small lock in its corner.
    var locked: Bool = false
    var idPrefix: String = "stage"
    let action: () -> Void
    static let size = CGSize(width: 64, height: 56)

    static func style(_ k: NewFaceKind) -> (symbol: String, tint: RGBA, fill: Double) {
        switch k {
        case .lattice: return ("square.grid.3x3.fill", StateGlyph.latticeTint, 0)
        case .anchor: return ("lock.fill", DS.Color.okGreen, 0.20)
        case .load: return ("arrow.down", DS.Color.accent, 0.18)
        case .protect: return ("shield.lefthalf.filled", FaceChip.protectTint, 0.16)
        case .keepClear: return ("nosign", DS.Color.clearance, 0.16)
        }
    }

    var body: some View {
        let s = Self.style(kind)
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: s.symbol).font(.system(size: 18, weight: .semibold)).foregroundStyle(s.tint.color)
                Text(SelectionsCopy.kindWord(kind)).font(.system(size: 11.5, weight: .bold))
                    .foregroundStyle(DS.Color.textPrimary.color).lineLimit(1).minimumScaleFactor(0.8)
            }
            .frame(width: Self.size.width, height: Self.size.height)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(s.fill > 0 ? s.tint.opacity(s.fill).color : DS.Color.fillSubtle.color)
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder((lit ? s.tint : RGBA(0, 0, 0, 0)).color, lineWidth: 2)))
            .overlay(alignment: .topTrailing) {
                if locked {
                    // ★ R7-E1: Protect locked on while a face of the group is Lattice
                    Image(systemName: "lock.fill").font(.system(size: 10, weight: .bold)).foregroundStyle(s.tint.color)
                        .padding(5)
                        .background(GeometryReader { g in
                            Color.clear.preference(key: ChromeKeepOutKey.self, value: ["chipRole-\(kind.rawValue)-lock": g.frame(in: .global)])
                        }.allowsHitTesting(false))
                        .accessibilityHidden(true)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(GeometryReader { g in Color.clear.preference(key: ChromeKeepOutKey.self, value: ["chipNew-\(kind.rawValue)": g.frame(in: .global)]) }
            .allowsHitTesting(false))
        .accessibilityLabel(SelectionsCopy.kindWord(kind))
        .accessibilityIdentifier("\(idPrefix)-chip-new-\(kind.rawValue)")
    }
}
