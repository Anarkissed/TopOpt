// ProgressBar.swift — the design's thin determinate progress track (ROADMAP M7.2).
//
// The bar under the running percentage in docs/design/TopOpt.dc.html: a `5px`
// track (`rgba(255,255,255,0.1)`, `3px` radius) with an accent fill whose width
// tracks progress and tweens `0.15s linear`. Used by the M7.7 run screen driven
// by the M7.0a progress callback.

import SwiftUI

public struct ProgressBar: View {
    private let value: Double        // clamped 0…1
    private let accent: Color

    /// - Parameters:
    ///   - value: fraction complete, clamped to 0…1.
    ///   - accent: fill color (default `DS.Color.accent`).
    public init(value: Double, accent: Color = DS.Color.accent.color) {
        self.value = min(1, max(0, value))
        self.accent = accent
    }

    public var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(DS.Color.textPrimary.opacity(0.10).color) // track
                Capsule().fill(accent)                                    // fill
                    .frame(width: geo.size.width * value)
            }
        }
        .frame(height: 5)
        .animation(DS.Motion.progress, value: value)
    }
}

#Preview("ProgressBar") {
    struct Demo: View {
        @State private var v = 0.42
        var body: some View {
            ZStack {
                DS.Color.background.color.ignoresSafeArea()
                VStack(spacing: DS.Space.xl2) {
                    ProgressBar(value: v).frame(width: 360)
                    ProgressBar(value: 1.0, accent: DS.Color.accentPurple.color).frame(width: 360)
                    Slider(value: $v, in: 0...1).frame(width: 360)
                }
                .padding(DS.Space.page)
            }
        }
    }
    return Demo()
}
