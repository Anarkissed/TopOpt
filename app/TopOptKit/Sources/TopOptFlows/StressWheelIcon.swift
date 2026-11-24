// StressWheelIcon — ★ notes25 icons (his pick 11-23): the Stress view's ONE icon on every page — the drawn colour wheel (the
// stress ramp around a circle) Results has drawn since 10-27. The Workspace's views row and the Flexible main page drew
// `waveform.path.ecg` for the same view.
import SwiftUI
import TopOptDesign

struct StressWheelIcon: View {
    var size: CGFloat = 16
    /// Greyed (the view not offered, or waiting): the wheel faded, as a greyed SF glyph would be.
    var dimmed = false

    static let colours: [RGBA] = [RGBA(28, 60, 170), RGBA(0, 170, 220), RGBA(60, 190, 110), RGBA(250, 220, 60), RGBA(255, 70, 50),
                                  RGBA(28, 60, 170)]

    var body: some View {
        Circle().fill(AngularGradient(colors: Self.colours.map(\.color), center: .center))
            .frame(width: size, height: size)
            .opacity(dimmed ? 0.45 : 1)
            .accessibilityHidden(true)
    }
}
