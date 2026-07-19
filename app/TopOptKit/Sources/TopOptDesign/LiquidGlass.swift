// LiquidGlass.swift — the ONE shared "Apple liquid glass" surface (design-overhaul,
// handoff 109).
//
// The gizmo redesign (107) replicated the mock's *palette*; the maintainer wanted its
// *intent* — Apple's Liquid Glass material — applied as ONE component everywhere, not a
// per-view bespoke recipe. This is that component. Every reskinned surface in the overhaul
// (the gizmo housing, the margin/axial value chips, the sync toggle, the clearance drag
// handles, the design-box handles) consumes THIS and nothing else, so the whole app reads
// as one material.
//
// THE MATERIAL: frosted translucency + a configurable frost TINT at a configurable
// INTENSITY + a soft specular top-edge. It is ALWAYS slightly see-through (the stage behind
// it reads through), matching the mock's glass.
//
//   * On iOS/macOS 26 it renders the real system `.glassEffect(_:in:)` (Liquid Glass),
//     tinted via `Glass.regular.tint(...)`, with our specular edge on top.
//   * On iOS 16 (the app's deployment floor — see the app-deployment-target memory) it
//     falls back to `.ultraThinMaterial` + a dark glass base + the frost tint + the same
//     specular edge. The two paths are intentionally close, not identical (disclosed).
//
// PERF (budget, per the task): this is a STATIC material — a background blur + fills + a
// stroke. It adds NO timer, display-link, or per-frame work, so an idle surface costs
// nothing continuous (it does not undo Prompt A's "idle = zero continuous cost"). Material
// blur is a real per-composite GPU cost, so callers keep glass to chrome-sized rects, never
// full-screen. Tokens/verification: the tint numbers are `RGBA` (headlessly testable in
// TopOptDesignTests); the rendered pixels are maintainer device QA (the /app/ rule).

import SwiftUI

/// The shared liquid-glass surface. Use `View.liquidGlass(_:in:)` to clad any view, or the
/// `LiquidGlass` container to wrap content that supplies its own padding.
public enum LiquidGlass {

    /// A frost TINT + INTENSITY: the colour the glass is cast with and how strongly. The
    /// glass is always translucent; intensity only scales the *colour* (0 = a clear/neutral
    /// frost, 1 = a full colour cast) and the matching specular glow.
    public struct Tint: Equatable, Sendable {
        /// The frost colour (its own alpha is ignored — `intensity` governs strength).
        public var color: RGBA
        /// 0 … 1 — how strongly the frost colour is applied.
        public var intensity: Double

        public init(color: RGBA, intensity: Double = 0.5) {
            self.color = color
            self.intensity = Swift.min(1, Swift.max(0, intensity))
        }

        /// Clear frost — no colour cast (a plain glass surface).
        public static let neutral = Tint(color: RGBA(255, 255, 255, 1), intensity: 0)
        /// The overhaul's signature BLUE frost — the gizmo, value chips and sync control.
        /// Explicitly NOT the 107 mock's green pools (the maintainer rejects palette
        /// replication); this is the design accent `#0A84FF`.
        public static let blue = Tint(color: DS.Color.accent, intensity: 0.55)
        /// RED frost — the clearance / keep-out handles keep the "forbidden space" colour
        /// language (`DS.Color.clearance`).
        public static let red = Tint(color: DS.Color.clearance, intensity: 0.55)

        /// A custom frost from any token colour.
        public static func frost(_ color: RGBA, intensity: Double = 0.55) -> Tint {
            Tint(color: color, intensity: intensity)
        }

        /// The frost colour at a chosen alpha as a SwiftUI `Color` (call-site convenience,
        /// e.g. to colour a value chip's number to match its glass).
        public func accent(_ alpha: Double = 1) -> Color { color.opacity(alpha).color }
    }

    /// The dark glass base for the fallback path — a touch of body so the frost reads on the
    /// near-black stage while staying translucent (alpha < 1).
    static let darkBase = RGBA(22, 24, 30, 0.52)

    /// The glass recipe as a `ViewModifier`, generic over the clip `Shape`. Applied as a
    /// background + specular overlay so the clad content lays out normally (padding is the
    /// caller's, exactly like `GlassSurface`). `InsettableShape` so the specular hairline can
    /// `strokeBorder` (inset), and both `RoundedRectangle` and `Capsule` conform.
    struct Surface<S: InsettableShape>: ViewModifier {
        let tint: Tint
        let shape: S
        /// Scales the specular top-edge (1 = default; 0 = none).
        let specular: Double

        func body(content: Content) -> some View {
            content
                .background { base }
                .overlay { specularEdge }
                .clipShape(shape)
        }

        /// The frosted, tinted, translucent fill.
        @ViewBuilder private var base: some View {
            if #available(iOS 26.0, macOS 26.0, *) {
                // Real Liquid Glass. `.regular` is already translucent; tint casts the frost.
                let glass = tint.intensity > 0
                    ? Glass.regular.tint(tint.color.opacity(0.55 * tint.intensity).color)
                    : Glass.regular
                Color.clear.glassEffect(glass, in: shape)
            } else {
                // iOS 16 fallback: material blur + a dark glass base (keeps it see-through on
                // the dark stage) + the frost colour cast.
                shape.fill(.ultraThinMaterial)
                    .overlay(shape.fill(LiquidGlass.darkBase.color))
                    .overlay(shape.fill(tint.color.opacity(0.24 * tint.intensity).color))
            }
        }

        /// A soft specular edge: a top-lit white hairline (the glass's lit rim) plus a faint
        /// tint-coloured outer glow. Static — no animation.
        @ViewBuilder private var specularEdge: some View {
            let s = Swift.max(0, specular)
            ZStack {
                shape.strokeBorder(
                    LinearGradient(colors: [Color.white.opacity(0.34 * s),
                                            Color.white.opacity(0.05 * s)],
                                   startPoint: .top, endPoint: .bottom),
                    lineWidth: 1)
                if tint.intensity > 0 {
                    shape.strokeBorder(tint.color.opacity(0.30 * tint.intensity * s).color,
                                       lineWidth: 1.5)
                        .blur(radius: 1.5)
                }
            }
            .allowsHitTesting(false)
        }
    }
}

public extension View {
    /// Clad this view in the shared liquid glass, clipped to `shape`.
    func liquidGlass<S: InsettableShape>(_ tint: LiquidGlass.Tint = .neutral,
                               in shape: S,
                               specular: Double = 1) -> some View {
        modifier(LiquidGlass.Surface(tint: tint, shape: shape, specular: specular))
    }

    /// Clad this view in the shared liquid glass with a continuous rounded-rect clip.
    func liquidGlass(_ tint: LiquidGlass.Tint = .neutral,
                     cornerRadius: CGFloat = 16,
                     specular: Double = 1) -> some View {
        liquidGlass(tint,
                    in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous),
                    specular: specular)
    }

    /// Clad this view in a fully-rounded (capsule) liquid glass — chips & pills.
    func liquidGlassCapsule(_ tint: LiquidGlass.Tint = .neutral,
                            specular: Double = 1) -> some View {
        liquidGlass(tint, in: Capsule(style: .continuous), specular: specular)
    }
}

/// A floating liquid-glass container — wrap content that supplies its own padding (the glass
/// analogue of `GlassPanel`, but on the shared `LiquidGlass` material). Optional soft shadow.
public struct LiquidGlassContainer<Content: View>: View {
    private let tint: LiquidGlass.Tint
    private let radius: CGFloat
    private let shadow: DS.Shadow?
    private let content: Content

    public init(tint: LiquidGlass.Tint = .neutral,
                cornerRadius: CGFloat = DS.Radius.panel,
                shadow: DS.Shadow? = .panel,
                @ViewBuilder content: () -> Content) {
        self.tint = tint
        self.radius = cornerRadius
        self.shadow = shadow
        self.content = content()
    }

    public var body: some View {
        let clad = content.liquidGlass(tint, cornerRadius: radius).compositingGroup()
        if let shadow {
            clad.dsShadow(shadow)
        } else {
            clad
        }
    }
}

#Preview("LiquidGlass") {
    ZStack {
        DS.Color.background.color.ignoresSafeArea()
        VStack(spacing: 20) {
            Text("Blue frost")
                .foregroundStyle(DS.Color.textPrimary.color)
                .padding(.vertical, 8).padding(.horizontal, 16)
                .liquidGlassCapsule(.blue)
            Text("Red frost")
                .foregroundStyle(DS.Color.textPrimary.color)
                .padding(.vertical, 8).padding(.horizontal, 16)
                .liquidGlassCapsule(.red)
            LiquidGlassContainer(tint: .neutral) {
                Text("Neutral container")
                    .foregroundStyle(DS.Color.textPrimary.color)
                    .padding(16)
            }
        }
    }
}
