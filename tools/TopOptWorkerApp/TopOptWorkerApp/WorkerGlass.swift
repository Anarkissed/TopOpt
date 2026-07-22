// WorkerGlass — the TopOpt Worker app's design language (handoff 124, items 5–8).
//
// This is the THIRD surface in the same family as the iPad app (the 109/112 Liquid
// Glass system) and MouseTool's macOS treatment: Liquid Glass dark, blue-frost accent,
// a near-black stage, restrained typography, depth from translucency rather than
// borders. The Worker app is a standalone Xcode target and does NOT link the iPad's
// TopOptDesign module, so the tokens are mirrored here (same values, one small file)
// instead of imported — deliberately, to keep the menu-bar app dependency-free.
//
// STATIC per the 108 rule (item 6): every surface here is a background blur + fills +
// a hairline. Nothing animates on idle; there is no timer, display-link, or per-frame
// work in the chrome. Live numbers change only when a poll delivers a new value.

import SwiftUI

// ─────────────────────────────────────────────────────────────────────────────
// Tokens. Mirror of the iPad DS palette used by the overhaul (accent #0A84FF, the
// red keep-out language, near-black stage), expressed as plain SwiftUI Colors.

// QA-only: when true, panes render without their ScrollView so ImageRenderer (which
// collapses ScrollView content to nothing) can rasterize the full view for the handoff
// screenshots. Default false — no effect on the shipping UI (handoff 124 evidence).
private struct QAFlattenKey: EnvironmentKey { static let defaultValue = false }
extension EnvironmentValues {
    var qaFlatten: Bool {
        get { self[QAFlattenKey.self] }
        set { self[QAFlattenKey.self] = newValue }
    }
}

/// Content in a ScrollView normally; a plain container under `qaFlatten` (for offscreen
/// rasterization). One place so every pane behaves the same.
struct FlexScroll<Content: View>: View {
    @Environment(\.qaFlatten) private var flat
    @ViewBuilder let content: Content
    var body: some View {
        if flat { content } else { ScrollView { content } }
    }
}

enum WD {
    enum Palette {
        static let accent   = Color(red: 0.039, green: 0.517, blue: 1.0)     // #0A84FF
        static let success  = Color(red: 0.188, green: 0.820, blue: 0.345)   // #30D158
        static let warning  = Color(red: 1.0,   green: 0.839, blue: 0.039)   // #FFD60A
        static let danger   = Color(red: 1.0,   green: 0.271, blue: 0.227)   // #FF453A

        static let stageTop = Color(red: 0.055, green: 0.065, blue: 0.085)   // #0E1016
        static let stageBot = Color(red: 0.027, green: 0.035, blue: 0.055)   // #07090E

        static let textPrimary   = Color(red: 0.949, green: 0.949, blue: 0.961)  // #F2F2F5
        static let textSecondary = Color(red: 0.949, green: 0.949, blue: 0.961).opacity(0.62)
        static let textTertiary  = Color(red: 0.949, green: 0.949, blue: 0.961).opacity(0.40)

        /// Dark glass body for the Material fallback — a touch of fill so frost reads
        /// on the near-black stage while staying translucent.
        static let glassBase = Color(red: 0.086, green: 0.094, blue: 0.118).opacity(0.55)
    }

    enum Metric {
        static let cardRadius: CGFloat = 16
        static let pillRadius: CGFloat = 999
        static let hairline: CGFloat = 1
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// The glass surface. One recipe, tinted per call. macOS 26 renders real Liquid Glass;
// earlier macOS falls back to `.ultraThinMaterial` + a dark base + the frost tint. Both
// carry the same soft specular top-edge so the family reads as one material.

struct WorkerGlassTint: Equatable {
    var color: Color
    var intensity: Double   // 0 = clear frost, 1 = full colour cast
    static let neutral = WorkerGlassTint(color: .white, intensity: 0)
    static let blue    = WorkerGlassTint(color: WD.Palette.accent, intensity: 0.55)
    static let red     = WorkerGlassTint(color: WD.Palette.danger, intensity: 0.5)
    static func frost(_ c: Color, _ i: Double = 0.5) -> WorkerGlassTint { .init(color: c, intensity: i) }
}

private struct WorkerGlassSurface<S: InsettableShape>: ViewModifier {
    let tint: WorkerGlassTint
    let shape: S
    let specular: Double

    func body(content: Content) -> some View {
        content
            .background { base }
            .overlay { edge }
            .clipShape(shape)
    }

    @ViewBuilder private var base: some View {
        if #available(macOS 26.0, *) {
            let glass = tint.intensity > 0
                ? Glass.regular.tint(tint.color.opacity(0.55 * tint.intensity))
                : Glass.regular
            Color.clear.glassEffect(glass, in: shape)
        } else {
            shape.fill(.ultraThinMaterial)
                .overlay(shape.fill(WD.Palette.glassBase))
                .overlay(shape.fill(tint.color.opacity(0.22 * tint.intensity)))
        }
    }

    @ViewBuilder private var edge: some View {
        let s = max(0, specular)
        ZStack {
            shape.strokeBorder(
                LinearGradient(colors: [.white.opacity(0.30 * s), .white.opacity(0.04 * s)],
                               startPoint: .top, endPoint: .bottom),
                lineWidth: WD.Metric.hairline)
            if tint.intensity > 0 {
                shape.strokeBorder(tint.color.opacity(0.28 * tint.intensity * s), lineWidth: 1.5)
                    .blur(radius: 1.5)
            }
        }
        .allowsHitTesting(false)
    }
}

extension View {
    func workerGlass<S: InsettableShape>(_ tint: WorkerGlassTint = .neutral, in shape: S,
                                         specular: Double = 1) -> some View {
        modifier(WorkerGlassSurface(tint: tint, shape: shape, specular: specular))
    }
    func workerGlass(_ tint: WorkerGlassTint = .neutral, cornerRadius: CGFloat = WD.Metric.cardRadius,
                     specular: Double = 1) -> some View {
        workerGlass(tint, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous),
                    specular: specular)
    }
    func workerGlassCapsule(_ tint: WorkerGlassTint = .neutral, specular: Double = 1) -> some View {
        workerGlass(tint, in: Capsule(style: .continuous), specular: specular)
    }

    /// The app's stage backdrop — a near-black vertical gradient. Static.
    func workerStage() -> some View {
        background(
            LinearGradient(colors: [WD.Palette.stageTop, WD.Palette.stageBot],
                           startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea())
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Small shared pieces used by both faces.

/// A steady status dot (never blinks — static per item 6). The colour IS the state.
struct StatusDot: View {
    let color: Color
    var diameter: CGFloat = 8
    var body: some View {
        Circle().fill(color)
            .frame(width: diameter, height: diameter)
            .overlay(Circle().stroke(color.opacity(0.35), lineWidth: 3).blur(radius: 1.5))
    }
}

/// A glass value pill — the blue-frost chip the family uses for numbers/labels.
struct GlassPill: View {
    let text: String
    var systemImage: String?
    var tint: WorkerGlassTint = .neutral
    var body: some View {
        HStack(spacing: 5) {
            if let systemImage { Image(systemName: systemImage).font(.system(size: 10, weight: .semibold)) }
            Text(text).font(.system(size: 11, weight: .semibold, design: .rounded))
        }
        .foregroundStyle(tint.intensity > 0 ? tint.color : WD.Palette.textSecondary)
        .padding(.horizontal, 9).padding(.vertical, 4)
        .workerGlassCapsule(tint, specular: 0.8)
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// State → colour, shared by both faces so a "Solving" job is the same green
// everywhere and a failure the same red.

extension WorkerJob {
    /// The dot/accent colour for this job's state.
    var accentColor: Color {
        switch state {
        case "running":   return paused ? WD.Palette.warning : WD.Palette.success
        case "queued":    return WD.Palette.textTertiary
        case "done":      return WD.Palette.accent
        case "error":     return WD.Palette.danger
        case "cancelled": return WD.Palette.textTertiary
        default:          return WD.Palette.textTertiary
        }
    }
}

extension WorkerSupervisor.Liveness {
    var color: Color {
        switch self {
        case .solving:     return WD.Palette.success
        case .paused:      return WD.Palette.warning
        case .idle:        return WD.Palette.accent
        case .unreachable: return WD.Palette.danger
        case .stopped:     return WD.Palette.textTertiary
        case .starting:    return WD.Palette.warning
        }
    }
    var label: String {
        switch self {
        case .solving:     return "Solving"
        case .paused:      return "Paused"
        case .idle:        return "Idle · ready"
        case .unreachable: return "Unreachable"
        case .stopped:     return "Stopped"
        case .starting:    return "Starting…"
        }
    }
}

/// A thin, HONEST progress bar (item 8): a real fraction when the ladder gives one,
/// an empty track otherwise — no animated indeterminate shimmer (static, item 6).
struct HonestBar: View {
    let fraction: Double?   // nil → indeterminate, drawn as an empty track
    var tint: Color = WD.Palette.accent
    var height: CGFloat = 5
    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.10))
                if let f = fraction {
                    Capsule().fill(tint)
                        .frame(width: max(height, geo.size.width * CGFloat(min(1, max(0, f)))))
                }
            }
        }
        .frame(height: height)
    }
}
