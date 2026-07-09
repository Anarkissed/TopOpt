// GlassSheet.swift — the design's centered modal card (ROADMAP M7.2).
//
// The import / weight / export dialogs in docs/design/TopOpt.dc.html: a heavier
// glass than a panel (`rgba(30,30,36,0.78)`–`rgba(32,32,38,0.82)` over
// `blur(40px)`), `28px` radius, `rgba(255,255,255,0.13)` hairline and the deep
// sheet shadow `0 24px 80px rgba(0,0,0,0.6)`. This view is just the styled card
// (with the `sheetIn` entrance); presenting it over a scrim is the caller's job
// (M7.3+), but `.glassSheet(isPresented:)` is provided for the common case.

import SwiftUI

/// A centered modal card in the design's sheet style. Supply the body content;
/// the card sizes to it (callers set an explicit width per the design, e.g. 540).
public struct GlassSheet<Content: View>: View {
    private let radius: CGFloat
    private let content: Content

    public init(radius: CGFloat = DS.Radius.sheet, @ViewBuilder content: () -> Content) {
        self.radius = radius
        self.content = content()
    }

    public var body: some View {
        content
            .glassSurface(
                fill: DS.Surface.sheet,
                stroke: DS.Color.strokeSheet,
                radius: radius,
                shadow: .sheet
            )
    }
}

/// Presents a `GlassSheet` over a dimmed, blurred scrim — the design's modal
/// backdrop (`rgba(0,0,0,0.45)` + `blur(6px)`), tap-scrim-to-dismiss.
public struct GlassSheetModifier<SheetContent: View>: ViewModifier {
    @Binding var isPresented: Bool
    let sheetContent: () -> SheetContent

    public func body(content: Content) -> some View {
        content.overlay {
            if isPresented {
                ZStack {
                    Rectangle()                             // blurred, dimmed backdrop
                        .fill(.ultraThinMaterial)
                        .overlay(DS.Color.scrim.color)
                        .ignoresSafeArea()
                        .onTapGesture { isPresented = false }
                    GlassSheet { sheetContent() }
                        .transition(.scale(scale: 0.97).combined(with: .opacity))
                }
                .animation(DS.Motion.sheetIn, value: isPresented)
            }
        }
    }
}

public extension View {
    /// Present a design-styled modal sheet over a scrim.
    func glassSheet<SheetContent: View>(
        isPresented: Binding<Bool>,
        @ViewBuilder content: @escaping () -> SheetContent
    ) -> some View {
        modifier(GlassSheetModifier(isPresented: isPresented, sheetContent: content))
    }
}

#Preview("GlassSheet") {
    ZStack {
        DS.Color.background.color.ignoresSafeArea()
        DS.Color.scrim.color.ignoresSafeArea()
        GlassSheet {
            VStack(alignment: .leading, spacing: DS.Space.m) {
                Text("New TopOpt").dsStyle(DS.TypeScale.title)
                Text("Import a model and choose your print material.")
                    .dsStyle(DS.TypeScale.subhead)
                    .foregroundStyle(DS.Color.textTertiary.color)
                HStack(spacing: DS.Space.m) {
                    PillButton("Cancel", style: .secondary) {}
                    PillButton("Continue", style: .primary) {}
                }
                .padding(.top, DS.Space.s)
            }
            .padding(DS.Space.xl6)
            .frame(width: 460, alignment: .leading)
        }
        .foregroundStyle(DS.Color.textPrimary.color)
    }
}
