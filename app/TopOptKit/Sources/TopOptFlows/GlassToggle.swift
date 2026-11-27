// GlassToggle — ★ ONE DARK LIQUID-GLASS ON/OFF SWITCH (maintainer, 2026-08-19:
// "please also change the Sim selector from a checkbox to an on/off select but
// can you make it dark-mode apple liquid glass? Can you also fix the 'CAD
// surfaces' selection button into the same dark-mode apple liquid glass?").
//
// ★ WHY A COMPONENT AND NOT TWO STYLED CALL SITES. He named two controls that
// should look the same and currently do not: the wizard's "Simulate Stresses"
// (a checkmark glyph) and "Restore CAD surfaces" (a stock blue `Toggle`). A
// third will follow. Styling each in place is how those two diverged in the
// first place, so the switch is a view and both call sites use it.
//
// ★ THE GLASS IS `.ultraThinMaterial`, which is what the rest of this app
// already uses for its panels (`HomeView`, `RootView`, `RunScreen`) — so this
// reads as the same surface rather than a new one. The ON state adds the accent
// fill and a soft glow; the OFF state is glass over the dark background with a
// hairline edge. The knob is plain white at both ends, as the platform's own
// switch is, so the affordance is unmistakable in either state.

import SwiftUI
import TopOptDesign

/// A dark liquid-glass on/off switch. Sized to the platform's own switch metrics
/// so it sits correctly beside body text.
public struct GlassToggle: View {
    private let isOn: Bool
    private let action: () -> Void

    /// Platform switch metrics — a 51×31 track with a 27 pt knob.
    private static let trackWidth: CGFloat = 51
    private static let trackHeight: CGFloat = 31
    private static let knob: CGFloat = 27

    public init(isOn: Bool, action: @escaping () -> Void) {
        self.isOn = isOn
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            ZStack(alignment: isOn ? .trailing : .leading) {
                Capsule()
                    // The glass itself, always present — the accent is layered
                    // OVER it when on, so the material never changes and the two
                    // states are the same surface at two tints.
                    .fill(.ultraThinMaterial)
                    .overlay(Capsule().fill(isOn
                                            ? DS.Color.accent.opacity(0.85).color
                                            : DS.Color.background.opacity(0.35).color))
                    .overlay(Capsule().strokeBorder(
                        (isOn ? DS.Color.accent.opacity(0.65)
                              : DS.Color.strokeSubtle).color, lineWidth: 1))
                    .frame(width: Self.trackWidth, height: Self.trackHeight)

                Circle()
                    .fill(Color.white)
                    .frame(width: Self.knob, height: Self.knob)
                    .shadow(color: .black.opacity(0.35), radius: 2, y: 1)
                    .padding(.horizontal, 2)
            }
            .frame(width: Self.trackWidth, height: Self.trackHeight)
            .animation(DS.Motion.emphasized, value: isOn)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isOn ? [.isButton, .isSelected] : .isButton)
    }
}
