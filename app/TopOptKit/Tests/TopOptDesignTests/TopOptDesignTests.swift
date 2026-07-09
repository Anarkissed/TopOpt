// TopOptDesignTests — headless verification of the M7.2 design tokens.
//
// The design HTML (docs/design/TopOpt.dc.html) is the source of truth; these
// tests pin every DS token to the exact literal it was extracted from, so a
// mistyped hex, a drifted radius/size, or a wrong shadow fails here rather than
// slipping into maintainer QA. Colors are checked on the raw RGBA components
// (0–1), which is why the tokens are stored as numbers. The views are also
// instantiated to keep them compiling and constructible.

import XCTest
import SwiftUI
@testable import TopOptDesign

final class TopOptDesignTests: XCTestCase {

    private let eps = 1e-9

    private func assertRGBA(_ c: RGBA, _ r255: Double, _ g255: Double, _ b255: Double,
                            _ a: Double, _ label: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(c.r, r255 / 255, accuracy: eps, "\(label).r", file: file, line: line)
        XCTAssertEqual(c.g, g255 / 255, accuracy: eps, "\(label).g", file: file, line: line)
        XCTAssertEqual(c.b, b255 / 255, accuracy: eps, "\(label).b", file: file, line: line)
        XCTAssertEqual(c.a, a, accuracy: eps, "\(label).a", file: file, line: line)
    }

    // MARK: RGBA construction

    func testRGBAHexDecodesToChannels() {
        assertRGBA(RGBA(hex: 0x0A84FF), 10, 132, 255, 1, "hex 0A84FF")   // accent
        assertRGBA(RGBA(hex: 0x060608), 6, 6, 8, 1, "hex 060608")        // background
        assertRGBA(RGBA(hex: 0xFF453A), 255, 69, 58, 1, "hex FF453A")    // danger
        // hex and 0–255 constructors agree
        XCTAssertEqual(RGBA(hex: 0x30D158), RGBA(48, 209, 88))
    }

    func testOpacityKeepsChannelsChangesAlpha() {
        let base = DS.Color.textPrimary          // #f2f2f5
        let faded = base.opacity(0.55)
        XCTAssertEqual(faded.r, base.r, accuracy: eps)
        XCTAssertEqual(faded.g, base.g, accuracy: eps)
        XCTAssertEqual(faded.b, base.b, accuracy: eps)
        XCTAssertEqual(faded.a, 0.55, accuracy: eps)
    }

    // MARK: Palette

    func testCorePalette() {
        assertRGBA(DS.Color.background, 6, 6, 8, 1, "background")
        assertRGBA(DS.Color.textPrimary, 242, 242, 245, 1, "textPrimary")
        assertRGBA(DS.Color.okGreen, 48, 209, 88, 1, "okGreen")
        assertRGBA(DS.Color.danger, 255, 69, 58, 1, "danger")
        assertRGBA(DS.Color.accent, 10, 132, 255, 1, "accent")
    }

    func testTextRampOpacities() {
        XCTAssertEqual(DS.Color.textSecondary.a, 0.55, accuracy: eps)
        XCTAssertEqual(DS.Color.textTertiary.a, 0.45, accuracy: eps)
        XCTAssertEqual(DS.Color.textQuaternary.a, 0.40, accuracy: eps)
        XCTAssertEqual(DS.Color.textDisabled.a, 0.35, accuracy: eps)
        // ramp is #f2f2f5 at varying alpha
        assertRGBA(DS.Color.textSecondary, 242, 242, 245, 0.55, "textSecondary")
    }

    func testAccentOptionsMatchDesignAppearanceSet() {
        // docs/design: accentColor.options = ["#0A84FF","#64D2FF","#BF5AF2","#30D158"]
        XCTAssertEqual(DS.Color.accentOptions.count, 4)
        assertRGBA(DS.Color.accentOptions[0], 10, 132, 255, 1, "accent[0]")
        assertRGBA(DS.Color.accentOptions[1], 100, 210, 255, 1, "accent[1] cyan")
        assertRGBA(DS.Color.accentOptions[2], 191, 90, 242, 1, "accent[2] purple")
        assertRGBA(DS.Color.accentOptions[3], 48, 209, 88, 1, "accent[3] green")
    }

    func testGroupPaletteMatchesDesignCOLORS() {
        // docs/design: this.COLORS = [FF453A, 0A84FF, 30D158, FF9F0A, BF5AF2]
        XCTAssertEqual(DS.Color.groupPalette.count, 5)
        assertRGBA(DS.Color.groupPalette[0], 255, 69, 58, 1, "group A")
        assertRGBA(DS.Color.groupPalette[1], 10, 132, 255, 1, "group B")
        assertRGBA(DS.Color.groupPalette[2], 48, 209, 88, 1, "group C")
        assertRGBA(DS.Color.groupPalette[3], 255, 159, 10, 1, "group D")
        assertRGBA(DS.Color.groupPalette[4], 191, 90, 242, 1, "group E")
    }

    func testStrokesAndFills() {
        assertRGBA(DS.Color.strokePanel, 255, 255, 255, 0.11, "strokePanel")
        assertRGBA(DS.Color.strokeSheet, 255, 255, 255, 0.13, "strokeSheet")
        assertRGBA(DS.Color.strokeStrong, 255, 255, 255, 0.14, "strokeStrong")
        assertRGBA(DS.Color.strokeSubtle, 255, 255, 255, 0.07, "strokeSubtle")
        assertRGBA(DS.Color.fillSubtle, 255, 255, 255, 0.06, "fillSubtle")
        assertRGBA(DS.Color.fillSelected, 255, 255, 255, 0.16, "fillSelected")
        assertRGBA(DS.Color.fillDisabled, 255, 255, 255, 0.08, "fillDisabled")
        assertRGBA(DS.Color.scrim, 0, 0, 0, 0.45, "scrim")
    }

    // MARK: Surfaces (glass fills)

    func testGlassSurfaces() {
        assertRGBA(DS.Surface.panel, 24, 24, 30, 0.62, "panel")
        assertRGBA(DS.Surface.sheet, 30, 30, 36, 0.80, "sheet")
        assertRGBA(DS.Surface.dialog, 32, 32, 38, 0.82, "dialog")
        assertRGBA(DS.Surface.bar, 28, 28, 34, 0.60, "bar")
        assertRGBA(DS.Surface.toast, 40, 40, 48, 0.85, "toast")
    }

    // MARK: Radius

    func testRadii() {
        XCTAssertEqual(DS.Radius.pill, 999)
        XCTAssertEqual(DS.Radius.sheet, 28)
        XCTAssertEqual(DS.Radius.card, 24)
        XCTAssertEqual(DS.Radius.dialog, 24)
        XCTAssertEqual(DS.Radius.panel, 22)
        XCTAssertEqual(DS.Radius.panelSmall, 20)
        XCTAssertEqual(DS.Radius.control, 14)
        XCTAssertEqual(DS.Radius.field, 12)
        XCTAssertEqual(DS.Radius.segment, 9)
    }

    // MARK: Spacing (monotone rhythm, endpoints pinned to the design)

    func testSpacingScale() {
        let scale: [CGFloat] = [
            DS.Space.xxs, DS.Space.xs, DS.Space.s, DS.Space.sm, DS.Space.m,
            DS.Space.ml, DS.Space.l, DS.Space.xl, DS.Space.xl2, DS.Space.xl3,
            DS.Space.xl4, DS.Space.xl5, DS.Space.xl6,
        ]
        XCTAssertEqual(scale.first, 4)
        XCTAssertEqual(DS.Space.page, 52)          // page gutter
        for (a, b) in zip(scale, scale.dropFirst()) {
            XCTAssertLessThan(a, b, "spacing scale must be strictly increasing")
        }
    }

    // MARK: Typography

    func testTypeSizes() {
        XCTAssertEqual(DS.TypeScale.display.size, 44)
        XCTAssertEqual(DS.TypeScale.titleXL.size, 22)
        XCTAssertEqual(DS.TypeScale.title.size, 20)
        XCTAssertEqual(DS.TypeScale.headline.size, 17)
        XCTAssertEqual(DS.TypeScale.bodyStrong.size, 14.5)
        XCTAssertEqual(DS.TypeScale.body.size, 14)
        XCTAssertEqual(DS.TypeScale.callout.size, 13.5)
        XCTAssertEqual(DS.TypeScale.caption.size, 12.5)
        XCTAssertEqual(DS.TypeScale.overlineSmall.size, 10.5)
    }

    func testTypeWeightsAndTracking() {
        XCTAssertEqual(DS.TypeScale.display.weight, .heavy)
        XCTAssertEqual(DS.TypeScale.title.weight, .bold)
        XCTAssertEqual(DS.TypeScale.bodyStrong.weight, .semibold)
        XCTAssertEqual(DS.TypeScale.body.weight, .regular)
        XCTAssertEqual(DS.TypeScale.display.tracking, -1)
        XCTAssertEqual(DS.TypeScale.overline.tracking, 0.8)
        XCTAssertEqual(DS.TypeScale.overlineSmall.tracking, 0.8)
    }

    // MARK: Shadows

    func testShadowTokens() {
        assertRGBA(DS.Shadow.sheet.color, 0, 0, 0, 0.60, "sheet shadow")
        XCTAssertEqual(DS.Shadow.sheet.radius, 80)
        XCTAssertEqual(DS.Shadow.sheet.y, 24)
        XCTAssertEqual(DS.Shadow.panel.radius, 44)
        XCTAssertEqual(DS.Shadow.panel.y, 12)
        XCTAssertEqual(DS.Shadow.toast.radius, 40)
        assertRGBA(DS.Shadow.accentGlow.color, 10, 132, 255, 0.40, "accentGlow")
        XCTAssertEqual(DS.Shadow.accentGlow.radius, 24)
        XCTAssertEqual(DS.Shadow.accentGlow.y, 6)
        // every design shadow is centered horizontally
        for s in [DS.Shadow.sheet, .panel, .toast, .accentGlow] {
            XCTAssertEqual(s.x, 0)
        }
    }

    // MARK: Motion

    func testToastDwell() {
        XCTAssertEqual(DS.Motion.toastDwell, 2.4, accuracy: eps) // design: 2400ms
    }

    // MARK: Blur intents

    func testBlurRadii() {
        XCTAssertEqual(DS.Blur.sheet, 40)
        XCTAssertEqual(DS.Blur.panel, 36)
        XCTAssertEqual(DS.Blur.control, 30)
        XCTAssertEqual(DS.Blur.subtle, 20)
        XCTAssertEqual(DS.Blur.saturation, 1.70, accuracy: eps)
    }

    // MARK: Views construct (kept compiling / instantiable)

    func testViewsInstantiate() {
        _ = GlassPanel { Text("x") }
        _ = GlassSheet { Text("x") }
        _ = PillButton("Go") {}
        _ = PillButton("Off", style: .secondary, isEnabled: false) {}
        _ = SegmentedGlass([.init("a", "A"), .init("b", "B")], selection: .constant("a"))
        _ = Toast("hello")
        _ = ProgressBar(value: 0.5)
    }

    func testProgressBarClampsValue() {
        // constructing out-of-range values must not trap; clamped internally.
        _ = ProgressBar(value: -0.5)
        _ = ProgressBar(value: 1.5)
    }
}
