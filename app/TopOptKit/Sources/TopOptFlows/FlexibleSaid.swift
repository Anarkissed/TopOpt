// FlexibleSaid — the words a view draws, for the hosted tests (task 2026-09-29-flexible-screens, round 7, batch R7-D1).
//
// A test process builds no accessibility tree for SwiftUI on macOS (checked: an NSHostingView's AX children are empty
// without an assistive client), so a hosted test cannot read what a card SAYS. The message rows the full-screen Export
// step and the corner card share (FlexibleExportRows) and the card's own lines publish their words here instead — only
// while a test records (`FlexibleSaid.recording`); in the app the modifier passes its content through untouched.

import SwiftUI

/// Every message drawn under the view that collects it, in drawing order.
struct FlexibleSaidKey: PreferenceKey {
    static var defaultValue: [String] = []
    static func reduce(value: inout [String], nextValue: () -> [String]) { value += nextValue() }
}

enum FlexibleSaid {
    /// Tests only: the rows publish their words.
    nonisolated(unsafe) static var recording = false
}

struct FlexibleSaidModifier: ViewModifier {
    let text: String
    func body(content: Content) -> some View {
        if FlexibleSaid.recording {
            content.background(Color.clear.preference(key: FlexibleSaidKey.self, value: [text]))
        } else {
            content
        }
    }
}

extension View {
    /// This view draws `text` (published only while a test records).
    func said(_ text: String) -> some View { modifier(FlexibleSaidModifier(text: text)) }
}
