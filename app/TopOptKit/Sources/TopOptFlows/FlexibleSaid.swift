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
    /// Tests only (with `recording`): the one-line words (`saidWhole`) also publish how wide they are drawn and how wide they
    /// need to be — FlexibleRound7FitHostedTests' check that nothing his rules keep on one line is cut ("Fa…", "Print paramet…").
    nonisolated(unsafe) static var measuring = false
}

/// ★ R7-D1 look-and-fix 3: one line of words as drawn (`actual`) against what it needs (`ideal`, its content at its own
/// size); `minScale` is the line's own minimumScaleFactor (a line drawn smaller but whole is whole).
struct FlexibleFit: Equatable {
    let text: String
    var actual: CGFloat?
    var ideal: CGFloat?
    let minScale: CGFloat
    /// Whole: drawn at least as wide as it needs at its smallest allowed size (half a point of rounding).
    var whole: Bool {
        guard let a = actual, let i = ideal else { return true }
        return a + 0.5 >= i * minScale
    }
}

/// Every one-line text's two widths, by the modifier's own id (the drawn and the needed widths come from two readers).
struct FlexibleFitKey: PreferenceKey {
    static var defaultValue: [UUID: FlexibleFit] = [:]
    static func reduce(value: inout [UUID: FlexibleFit], nextValue: () -> [UUID: FlexibleFit]) {
        for (k, v) in nextValue() {
            var f = value[k] ?? FlexibleFit(text: v.text, actual: nil, ideal: nil, minScale: v.minScale)
            if let a = v.actual { f.actual = a }
            if let i = v.ideal { f.ideal = i }
            value[k] = f
        }
    }
}

/// `said` for words his rules keep on ONE line; while a test measures, it also publishes the two widths.
struct FlexibleSaidWholeModifier: ViewModifier {
    let text: String
    let minScale: CGFloat
    @State private var id = UUID()
    func body(content: Content) -> some View {
        if FlexibleSaid.recording && FlexibleSaid.measuring {
            content
                .background(Color.clear.preference(key: FlexibleSaidKey.self, value: [text]))
                .background(GeometryReader { g in
                    Color.clear.preference(key: FlexibleFitKey.self,
                                           value: [id: FlexibleFit(text: text, actual: g.size.width, ideal: nil, minScale: minScale)])
                })
                .overlay(alignment: .topLeading) {
                    content.fixedSize().hidden().allowsHitTesting(false)
                        .background(GeometryReader { g in
                            Color.clear.preference(key: FlexibleFitKey.self,
                                                   value: [id: FlexibleFit(text: text, actual: nil, ideal: g.size.width, minScale: minScale)])
                        })
                        .preference(key: FlexibleSaidKey.self, value: [])
                }
        } else {
            content.modifier(FlexibleSaidModifier(text: text))
        }
    }
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
    /// This view draws `text` on ONE line (its smallest allowed size `minScale`): a measuring test checks it is not cut.
    func saidWhole(_ text: String, minScale: CGFloat = 1) -> some View { modifier(FlexibleSaidWholeModifier(text: text, minScale: minScale)) }
}
