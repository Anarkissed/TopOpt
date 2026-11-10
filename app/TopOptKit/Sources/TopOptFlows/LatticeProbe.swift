// LatticeProbe — B7, the Lattice page's controls for the hosted parity test (LatticePageParityHostedTests).
//
// A test process builds no accessibility tree for SwiftUI on macOS (FlexibleSaid), so the page's ids cannot be read there.
// Each control's `latticeID` is its accessibility identifier and, only while a test records (`FlexibleSaid.recording`),
// also publishes the id and where it sits in the window; in the app it is the identifier alone.

import SwiftUI

/// Every control id the Lattice page draws → its frame in the window (top-left origin).
struct LatticeProbeKey: PreferenceKey {
    static var defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue()) { a, _ in a }
    }
}

extension View {
    /// The control's id: its accessibility identifier, and (while a test records) the id and its frame.
    @ViewBuilder func latticeID(_ id: String) -> some View {
        if FlexibleSaid.recording {
            accessibilityIdentifier(id)
                .background(GeometryReader { g in Color.clear.preference(key: LatticeProbeKey.self, value: [id: g.frame(in: .global)]) })
        } else {
            accessibilityIdentifier(id)
        }
    }

    /// `latticeID` when an id is given, and the view untouched when not (a caption line measured only where it asks to be).
    @ViewBuilder func latticeID(ifGiven id: String?) -> some View {
        if let id { latticeID(id) } else { self }
    }
}
