// Toast.swift — the design's transient pill toast (ROADMAP M7.2).
//
// The bottom-center notification in docs/design/TopOpt.dc.html: a blurred pill
// (`rgba(40,40,48,0.85)`, `rgba(255,255,255,0.14)` hairline, `999px`, `blur(30px)`)
// with `13.5px/600` text and shadow `0 12px 40px rgba(0,0,0,0.5)`, animating up
// (`toastUp`) and auto-dismissing after ~2.4s. The bare `Toast` view is reusable
// on its own; `.toast(_:isPresented:)` presents it with the entrance + auto-hide.

import SwiftUI

/// The pill itself. Presentation/animation is the caller's (or use `.toast(...)`).
public struct Toast: View {
    private let message: String
    public init(_ message: String) { self.message = message }

    public var body: some View {
        Text(message)
            .dsStyle(DS.TypeScale.callout)
            .fontWeight(.semibold)
            .foregroundStyle(DS.Color.textPrimary.color)
            .padding(.vertical, DS.Space.m)
            .padding(.horizontal, DS.Space.xl3)
            .background {
                Capsule().fill(.ultraThinMaterial)
                    .overlay(Capsule().fill(DS.Surface.toast.color))
            }
            .overlay(Capsule().strokeBorder(DS.Color.strokeStrong.color, lineWidth: 1))
            .clipShape(Capsule())
            .compositingGroup()
            .dsShadow(.toast)
    }
}

/// Presents a `Toast` above the bottom edge, sliding up on show and
/// auto-dismissing after `DS.Motion.toastDwell`.
public struct ToastModifier: ViewModifier {
    @Binding var message: String?

    public func body(content: Content) -> some View {
        content.overlay(alignment: .bottom) {
            if let message {
                Toast(message)
                    .padding(.bottom, 96) // design places the toast 96px off the bottom
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .task(id: message) {
                        try? await Task.sleep(nanoseconds: UInt64(DS.Motion.toastDwell * 1_000_000_000))
                        self.message = nil
                    }
            }
        }
        .animation(DS.Motion.toastIn, value: message)
    }
}

public extension View {
    /// Show a transient toast whenever `message` is non-nil; it clears the binding
    /// after the design's dwell. Set `message` to a string to show one.
    func toast(_ message: Binding<String?>) -> some View {
        modifier(ToastModifier(message: message))
    }
}

#Preview("Toast") {
    ZStack {
        DS.Color.background.color.ignoresSafeArea()
        VStack(spacing: DS.Space.xl2) {
            Toast("Exported to Files · ready to print")
            Toast("Add at least one force arrow first")
        }
        .padding(DS.Space.page)
    }
}
