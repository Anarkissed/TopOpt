// GlassPanel.swift — the design's floating "glass" container (ROADMAP M7.2).
//
// Maps the design's panel recipe (docs/design/TopOpt.dc.html, e.g. the workspace
// Selections panel): a dark tinted fill `rgba(24,24,30,0.62)` over a backdrop
// blur, a `rgba(255,255,255,0.11)` hairline, `22px` radius and a soft drop
// shadow. SwiftUI's `Material` supplies the backdrop blur (the design's numeric
// `blur(36px)` maps to `.ultraThinMaterial` — the closest system material on a
// dark stage; exact radius is maintainer QA, the fill/stroke/radius/shadow tokens
// are exact).

import SwiftUI

/// The glass-surface fill+blur+stroke recipe shared by `GlassPanel` and
/// `GlassSheet`. Applied as a background/overlay so content lays out normally.
struct GlassSurface: ViewModifier {
    let fill: RGBA
    let stroke: RGBA
    let radius: CGFloat
    let shadow: DS.Shadow

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        return content
            .background {
                shape
                    .fill(.ultraThinMaterial)          // backdrop blur
                    .overlay(shape.fill(fill.color))   // dark glass tint
            }
            .overlay {
                shape.strokeBorder(stroke.color, lineWidth: 1) // hairline
            }
            .clipShape(shape)
            .compositingGroup()
            .dsShadow(shadow)
    }
}

extension View {
    /// Apply an arbitrary glass surface (used by the design-system containers).
    func glassSurface(fill: RGBA, stroke: RGBA, radius: CGFloat, shadow: DS.Shadow) -> some View {
        modifier(GlassSurface(fill: fill, stroke: stroke, radius: radius, shadow: shadow))
    }
}

/// A floating translucent panel — the container for the workspace side panels,
/// popovers and toolbars in the design. Wrap any content; padding is the caller's.
public struct GlassPanel<Content: View>: View {
    private let radius: CGFloat
    private let content: Content

    /// - Parameters:
    ///   - radius: corner radius (defaults to the design's panel `22`).
    ///   - content: panel contents.
    public init(radius: CGFloat = DS.Radius.panel, @ViewBuilder content: () -> Content) {
        self.radius = radius
        self.content = content()
    }

    public var body: some View {
        content
            .glassSurface(
                fill: DS.Surface.panel,
                stroke: DS.Color.strokePanel,
                radius: radius,
                shadow: .panel
            )
    }
}

#Preview("GlassPanel") {
    ZStack {
        DS.Color.background.color.ignoresSafeArea()
        GlassPanel {
            VStack(alignment: .leading, spacing: DS.Space.s) {
                Text("Selections").dsStyle(DS.TypeScale.bodyStrong)
                Text("Choose faces below, then tap the model to select anchor or load faces.")
                    .dsStyle(DS.TypeScale.caption)
                    .foregroundStyle(DS.Color.textTertiary.color)
            }
            .padding(DS.Space.l)
            .frame(width: 280, alignment: .leading)
        }
        .foregroundStyle(DS.Color.textPrimary.color)
    }
}
