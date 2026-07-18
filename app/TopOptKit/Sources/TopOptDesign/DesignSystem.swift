// DesignSystem.swift — TopOpt design tokens (ROADMAP M7.2).
//
// Every value here is extracted verbatim from the committed visual source of
// truth, docs/design/TopOpt.dc.html (the "dark glass" iPad mockup). The HTML is
// authoritative: when a token and the HTML disagree, the HTML wins and this file
// is wrong. Each token's doc comment cites the literal it traces to so a reviewer
// can diff them side by side.
//
// Colors are stored as `RGBA` value types with the exact 0–255 component numbers
// from the design's `rgba()` / hex literals, so the tokens can be verified
// headlessly (TopOptDesignTests) without rendering. `.color` yields the SwiftUI
// sRGB `Color` the views consume.

import SwiftUI

/// A color stored by its exact sRGB components (0–255) and alpha (0–1), matching
/// how the design HTML writes `rgba(r,g,b,a)` / `#rrggbb`. Kept as raw numbers so
/// token values are testable without a rendering context.
public struct RGBA: Equatable, Sendable {
    /// Red 0–1.
    public let r: Double
    /// Green 0–1.
    public let g: Double
    /// Blue 0–1.
    public let b: Double
    /// Alpha 0–1.
    public let a: Double

    /// Construct from 0–255 channels (+ optional 0–1 alpha), as written in CSS.
    public init(_ r255: Double, _ g255: Double, _ b255: Double, _ a: Double = 1) {
        self.r = r255 / 255
        self.g = g255 / 255
        self.b = b255 / 255
        self.a = a
    }

    /// Construct from a `0xRRGGBB` hex literal (+ optional alpha), as written for
    /// the design's `#rrggbb` colors.
    public init(hex: UInt32, alpha: Double = 1) {
        self.init(Double((hex >> 16) & 0xFF), Double((hex >> 8) & 0xFF), Double(hex & 0xFF), alpha)
    }

    /// The SwiftUI sRGB color for this token.
    public var color: Color { Color(.sRGB, red: r, green: g, blue: b, opacity: a) }

    /// The same color at a different alpha (the design reuses `#f2f2f5` at many
    /// opacities for its text ramp).
    public func opacity(_ a: Double) -> RGBA { RGBA(r * 255, g * 255, b * 255, a) }
}

/// TopOpt design tokens. Namespaced (`DS.Color`, `DS.Radius`, …) so call sites
/// read as `DS.Color.accent.color`, `DS.Radius.sheet`, etc.
public enum DS {

    // MARK: - Color

    public enum Color {
        // Base surfaces & ink
        /// Page background `#060608`.
        public static let background = RGBA(hex: 0x060608)
        /// Primary text `#f2f2f5`.
        public static let textPrimary = RGBA(hex: 0xF2F2F5)
        /// Success / "Optimized ✓" green `#30D158`.
        public static let okGreen = RGBA(hex: 0x30D158)
        /// Destructive / remove red `#FF453A` (also group color A).
        public static let danger = RGBA(hex: 0xFF453A)
        /// Caution / non-blocking warning amber `#FF9F0A` (e.g. the sub-voxel
        /// load-face "may not register" badge, handoff 099).
        public static let warning = RGBA(hex: 0xFF9F0A)

        // Text ramp — `#f2f2f5` at the opacities the design reuses.
        /// `rgba(242,242,245,0.55)` — secondary text.
        public static let textSecondary = textPrimary.opacity(0.55)
        /// `rgba(242,242,245,0.45)` — tertiary / captions.
        public static let textTertiary = textPrimary.opacity(0.45)
        /// `rgba(242,242,245,0.40)` — quaternary / muted labels.
        public static let textQuaternary = textPrimary.opacity(0.40)
        /// `rgba(242,242,245,0.35)` — disabled text.
        public static let textDisabled = textPrimary.opacity(0.35)

        // Accent — themeable; default `#0A84FF`, options from the design's
        // Appearance section (`accentColor.options`).
        /// Default accent `#0A84FF`.
        public static let accent = RGBA(hex: 0x0A84FF)
        /// Accent option: cyan `#64D2FF`.
        public static let accentCyan = RGBA(hex: 0x64D2FF)
        /// Accent option: purple `#BF5AF2`.
        public static let accentPurple = RGBA(hex: 0xBF5AF2)
        /// Accent option: green `#30D158`.
        public static let accentGreen = RGBA(hex: 0x30D158)
        /// The four selectable accents, in design order.
        public static let accentOptions: [RGBA] = [accent, accentCyan, accentPurple, accentGreen]

        // Selection-group palette (`this.COLORS`), assigned round-robin as the
        // user adds face groups.
        /// Face-group colors, in assignment order: red, blue, green, orange, purple.
        public static let groupPalette: [RGBA] = [
            RGBA(hex: 0xFF453A), // A
            RGBA(hex: 0x0A84FF), // B
            RGBA(hex: 0x30D158), // C
            RGBA(hex: 0xFF9F0A), // D
            RGBA(hex: 0xBF5AF2), // E
        ]

        // Hairline strokes — white at low alpha, as the design's `border` rules.
        /// `rgba(255,255,255,0.11)` — default glass-panel hairline.
        public static let strokePanel = RGBA(255, 255, 255, 0.11)
        /// `rgba(255,255,255,0.13)` — glass-sheet hairline.
        public static let strokeSheet = RGBA(255, 255, 255, 0.13)
        /// `rgba(255,255,255,0.14)` — raised / emphasized hairline (toast, chips).
        public static let strokeStrong = RGBA(255, 255, 255, 0.14)
        /// `rgba(255,255,255,0.07)` — inset-track hairline (segmented control).
        public static let strokeSubtle = RGBA(255, 255, 255, 0.07)

        // Fills — white at low alpha, for non-glass control surfaces.
        /// `rgba(255,255,255,0.06)` — resting subtle fill (inputs, ghost buttons).
        public static let fillSubtle = RGBA(255, 255, 255, 0.06)
        /// `rgba(255,255,255,0.16)` — selected segment fill.
        public static let fillSelected = RGBA(255, 255, 255, 0.16)
        /// `rgba(255,255,255,0.08)` — disabled control fill.
        public static let fillDisabled = RGBA(255, 255, 255, 0.08)

        // Scrim behind modal sheets — `rgba(0,0,0,0.45)`.
        public static let scrim = RGBA(0, 0, 0, 0.45)
    }

    // MARK: - Surface (tinted glass fills)

    /// The dark, semi-transparent fills layered over a blur to make the design's
    /// "glass". Alpha and tint vary by surface role.
    public enum Surface {
        /// Floating panel `rgba(24,24,30,0.62)`.
        public static let panel = RGBA(24, 24, 30, 0.62)
        /// Modal sheet `rgba(30,30,36,0.80)` (30/78 … 32/82 in the design; 0.80 mid).
        public static let sheet = RGBA(30, 30, 36, 0.80)
        /// Small dialog `rgba(32,32,38,0.82)`.
        public static let dialog = RGBA(32, 32, 38, 0.82)
        /// Pill / chip bar `rgba(28,28,34,0.60)`.
        public static let bar = RGBA(28, 28, 34, 0.60)
        /// Toast `rgba(40,40,48,0.85)`.
        public static let toast = RGBA(40, 40, 48, 0.85)
    }

    // MARK: - Radius (corner radii, px == pt)

    public enum Radius {
        /// Fully rounded pill (`999px`).
        public static let pill: CGFloat = 999
        /// Card / large sheet `24`.
        public static let card: CGFloat = 24
        /// Sheet `28`.
        public static let sheet: CGFloat = 28
        /// Dialog `24`.
        public static let dialog: CGFloat = 24
        /// Floating panel `22`.
        public static let panel: CGFloat = 22
        /// Small panel / popover `20`.
        public static let panelSmall: CGFloat = 20
        /// Control / input `14`.
        public static let control: CGFloat = 14
        /// Field / select `12`.
        public static let field: CGFloat = 12
        /// Inner segment `9`.
        public static let segment: CGFloat = 9
    }

    // MARK: - Spacing (px == pt), the design's layout rhythm

    public enum Space {
        public static let xxs: CGFloat = 4
        public static let xs: CGFloat = 6
        public static let s: CGFloat = 8
        public static let sm: CGFloat = 10
        public static let m: CGFloat = 12
        public static let ml: CGFloat = 14
        public static let l: CGFloat = 16
        public static let xl: CGFloat = 18
        public static let xl2: CGFloat = 20
        public static let xl3: CGFloat = 22
        public static let xl4: CGFloat = 24
        public static let xl5: CGFloat = 26
        public static let xl6: CGFloat = 30
        /// Page gutter (`padding … 52px`).
        public static let page: CGFloat = 52
    }

    // MARK: - Blur (backdrop material radii, px)

    /// Backdrop-filter blur radii from the design (`backdrop-filter: blur(Npx)`).
    /// SwiftUI's `Material` doesn't take a numeric radius, so views map these to
    /// the nearest system material; the numbers are retained as the design's
    /// intent and for QA.
    public enum Blur {
        /// Sheet `blur(40px) saturate(170%)`.
        public static let sheet: CGFloat = 40
        /// Panel `blur(36px) saturate(170%)`.
        public static let panel: CGFloat = 36
        /// Button / chip `blur(30px) saturate(160%)`.
        public static let control: CGFloat = 30
        /// Small `blur(20px)`.
        public static let subtle: CGFloat = 20
        /// Backdrop saturation used with the sheet/panel blurs (`saturate(170%)`).
        public static let saturation: Double = 1.70
    }

    // MARK: - Shadow

    /// A drop shadow token (`0 Ypx Blurpx color`), matching the design's
    /// `box-shadow` rules. `x` is 0 for every design shadow.
    public struct Shadow: Sendable {
        public let color: RGBA
        public let radius: CGFloat
        public let x: CGFloat
        public let y: CGFloat
        public init(color: RGBA, radius: CGFloat, y: CGFloat, x: CGFloat = 0) {
            self.color = color
            self.radius = radius
            self.x = x
            self.y = y
        }
        // NOTE: CSS blur radius ≈ 2× a SwiftUI shadow radius, but the tokens store
        // the design's CSS number; views halve it when calling `.shadow`.
        /// Sheet `0 24px 80px rgba(0,0,0,0.6)`.
        public static let sheet = Shadow(color: RGBA(0, 0, 0, 0.60), radius: 80, y: 24)
        /// Panel `0 12px 44px rgba(0,0,0,0.4)`.
        public static let panel = Shadow(color: RGBA(0, 0, 0, 0.40), radius: 44, y: 12)
        /// Toast `0 12px 40px rgba(0,0,0,0.5)`.
        public static let toast = Shadow(color: RGBA(0, 0, 0, 0.50), radius: 40, y: 12)
        /// Accent glow under primary buttons `0 6px 24px rgba(10,132,255,0.4)`.
        public static let accentGlow = Shadow(color: RGBA(10, 132, 255, 0.40), radius: 24, y: 6)
    }

    // MARK: - Typography

    /// A text style: point size + weight + letter spacing, from the design's
    /// inline `font-size` / `font-weight` / `letter-spacing`. SwiftUI has no 650/
    /// 750 weights, so those map to the nearest named weight (documented per case);
    /// the exact px sizes are preserved and tested.
    public struct TextStyle: Sendable {
        public let size: CGFloat
        public let weight: Font.Weight
        public let tracking: CGFloat
        public init(_ size: CGFloat, _ weight: Font.Weight, tracking: CGFloat = 0) {
            self.size = size
            self.weight = weight
            self.tracking = tracking
        }
        /// The SwiftUI system font for this style (tracking applied via `.tracking`).
        public var font: Font { .system(size: size, weight: weight) }
    }

    public enum TypeScale {
        /// `44px/800`, `-1` — the running progress percentage.
        public static let display = TextStyle(44, .heavy, tracking: -1)
        /// `22px/700`, `-0.4` — home title / large numerals.
        public static let titleXL = TextStyle(22, .bold, tracking: -0.4)
        /// `20px/700`, `-0.3` — sheet titles.
        public static let title = TextStyle(20, .bold, tracking: -0.3)
        /// `17px/700` — dialog titles (design uses 750 → mapped to bold).
        public static let headline = TextStyle(17, .bold, tracking: -0.2)
        /// `14.5px/650` — button / row labels (650 → semibold).
        public static let bodyStrong = TextStyle(14.5, .semibold)
        /// `14px/400` — body.
        public static let body = TextStyle(14, .regular)
        /// `13.5px/400` — callouts / control labels.
        public static let callout = TextStyle(13.5, .regular)
        /// `13px/400` — subheads.
        public static let subhead = TextStyle(13, .regular)
        /// `12.5px/400` — captions / hints.
        public static let caption = TextStyle(12.5, .regular)
        /// `12px/400` — small captions.
        public static let caption2 = TextStyle(12, .regular)
        /// `11.5px/400` — footnotes / meta.
        public static let footnote = TextStyle(11.5, .regular)
        /// `12px/600`, tracking `0.8`, UPPERCASE — section overlines.
        public static let overline = TextStyle(12, .semibold, tracking: 0.8)
        /// `10.5px/700`, tracking `0.8`, UPPERCASE — column headers.
        public static let overlineSmall = TextStyle(10.5, .bold, tracking: 0.8)
    }

    // MARK: - Motion

    /// Animation curves & durations from the design's `@keyframes` / `animation`.
    public enum Motion {
        /// The design's spring-ish ease `cubic-bezier(0.2,0.9,0.3,1)` (sheets, toast).
        public static let emphasized = Animation.timingCurve(0.2, 0.9, 0.3, 1, duration: 0.26)
        /// Sheet entrance (~`0.26s` emphasized).
        public static let sheetIn = Animation.timingCurve(0.2, 0.9, 0.3, 1, duration: 0.26)
        /// Toast entrance (`0.25s` emphasized).
        public static let toastIn = Animation.timingCurve(0.2, 0.9, 0.3, 1, duration: 0.25)
        /// Screen fade-in (`0.25s ease`).
        public static let fadeIn = Animation.easeInOut(duration: 0.25)
        /// Progress-bar width tween (`0.15s linear`).
        public static let progress = Animation.linear(duration: 0.15)
        /// Toast on-screen dwell before auto-dismiss (design uses `2400ms`).
        public static let toastDwell: TimeInterval = 2.4
    }
}

// MARK: - Convenience

public extension View {
    /// Apply a `DS.Shadow` token. The stored radius is the design's CSS blur
    /// number; SwiftUI shadow radius ≈ half of that, so it is halved here.
    func dsShadow(_ shadow: DS.Shadow) -> some View {
        self.shadow(color: shadow.color.color, radius: shadow.radius / 2, x: shadow.x, y: shadow.y)
    }
}

public extension Text {
    /// Apply a `DS.TextStyle` (font + letter spacing).
    func dsStyle(_ style: DS.TextStyle) -> Text {
        self.font(style.font).tracking(style.tracking)
    }
}
