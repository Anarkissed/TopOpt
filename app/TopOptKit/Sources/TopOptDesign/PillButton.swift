// PillButton.swift — the design's pill-shaped action button (ROADMAP M7.2).
//
// The buttons throughout docs/design/TopOpt.dc.html: fully-rounded (`999px`),
// `14.5px/700` label, with three roles the design reuses —
//   • primary   — accent fill, white text, accent glow shadow (Continue, Optimize)
//   • secondary — transparent over a hairline, `rgba(242,242,245,0.75)` text (Cancel)
//   • danger    — red-tinted fill + border + `#FF453A` text (Remove)
// and a disabled state (`rgba(255,255,255,0.08)` fill, muted text, no glow) used
// by Optimize until a force exists. An optional leading SF Symbol matches the
// design's inline icons.

import SwiftUI

public struct PillButton: View {
    public enum Style: Sendable {
        case primary
        case secondary
        case danger
    }

    private let title: String
    private let style: Style
    private let systemImage: String?
    private let accent: Color
    private let isEnabled: Bool
    private let action: () -> Void

    /// - Parameters:
    ///   - title: label text.
    ///   - style: visual role (default `.primary`).
    ///   - systemImage: optional leading SF Symbol name.
    ///   - accent: accent color for the primary role (default `DS.Color.accent`).
    ///   - isEnabled: when false, renders the design's disabled treatment and
    ///     does not fire `action`.
    ///   - action: tap handler.
    public init(
        _ title: String,
        style: Style = .primary,
        systemImage: String? = nil,
        accent: Color = DS.Color.accent.color,
        isEnabled: Bool = true,
        action: @escaping () -> Void
    ) {
        self.title = title
        self.style = style
        self.systemImage = systemImage
        self.accent = accent
        self.isEnabled = isEnabled
        self.action = action
    }

    public var body: some View {
        Button(action: { if isEnabled { action() } }) {
            HStack(spacing: DS.Space.s) {
                if let systemImage { Image(systemName: systemImage) }
                Text(title).dsStyle(DS.TypeScale.bodyStrong)
            }
            .padding(.vertical, DS.Space.m)
            .padding(.horizontal, DS.Space.xl4)
            .foregroundStyle(foreground)
            .background(background)
            .overlay(border)
            .clipShape(Capsule())
            .dsShadowIf(glow)
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
    }

    // MARK: role → tokens

    private var foreground: Color {
        guard isEnabled else { return DS.Color.textDisabled.color }
        switch style {
        case .primary: return .white
        case .secondary: return DS.Color.textPrimary.opacity(0.75).color
        case .danger: return DS.Color.danger.color
        }
    }

    @ViewBuilder private var background: some View {
        if !isEnabled {
            Capsule().fill(DS.Color.fillDisabled.color)
        } else {
            switch style {
            case .primary: Capsule().fill(accent)
            case .secondary: Capsule().fill(.clear)
            case .danger: Capsule().fill(DS.Color.danger.opacity(0.10).color)
            }
        }
    }

    @ViewBuilder private var border: some View {
        if isEnabled, style == .secondary {
            Capsule().strokeBorder(DS.Color.strokeSheet.color, lineWidth: 1)
        } else if isEnabled, style == .danger {
            Capsule().strokeBorder(DS.Color.danger.opacity(0.35).color, lineWidth: 1)
        }
    }

    /// Primary buttons carry the accent glow; nothing else does.
    private var glow: DS.Shadow? {
        (isEnabled && style == .primary) ? .accentGlow : nil
    }
}

private extension View {
    @ViewBuilder func dsShadowIf(_ shadow: DS.Shadow?) -> some View {
        if let shadow { self.dsShadow(shadow) } else { self }
    }
}

#Preview("PillButton") {
    ZStack {
        DS.Color.background.color.ignoresSafeArea()
        VStack(spacing: DS.Space.l) {
            PillButton("Continue", style: .primary, systemImage: "sparkles") {}
            PillButton("Cancel", style: .secondary) {}
            PillButton("Remove", style: .danger) {}
            PillButton("Optimize", style: .primary, isEnabled: false) {}
        }
        .padding(DS.Space.page)
    }
}
