// ResultOpeningCover.swift — ★ his iPad notes 2026-11-23: "Tapping the notification should bring you RIGHT to the result
// screen. Nothing else." While the tapped run's version and its result are read (a few seconds for a big print file), the
// screen is plain — never the Library or a stage on the way. It goes as the version opens on its Results.
import SwiftUI
import TopOptDesign

struct ResultOpeningCover: View {
    static let line = "Opening the result"

    var body: some View {
        ZStack {
            DS.Color.background.color.ignoresSafeArea()
            VStack(spacing: DS.Space.m) {
                ProgressView().controlSize(.large)
                Text(Self.line).dsStyle(DS.TypeScale.subhead).foregroundStyle(DS.Color.textSecondary.color)
            }
        }
        .contentShape(Rectangle())   // nothing under it takes a tap while it is up
        .background(DSParts.publish("resultOpeningCover"))
        .accessibilityElement(children: .combine)
    }
}
