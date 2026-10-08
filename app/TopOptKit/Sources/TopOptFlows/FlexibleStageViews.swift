// FlexibleStageViews — round 6, item 3's two views (task 2026-09-29-flexible-screens, round 6). TESTS-FIRST
// STUB: the option set and its toggle; no button, no frame yet.

import SwiftUI
import TopOptDesign

/// The Settings page's views (session display state — never a setting).
public struct FlexibleStageViews: OptionSet, Hashable, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    /// Every pressed face's prism, faint, with its mm.
    public static let prisms = FlexibleStageViews(rawValue: 1 << 0)
    /// Every group's glass, the open group brighter.
    public static let groups = FlexibleStageViews(rawValue: 1 << 1)

    /// Where the buttons sit (the keep-outs read it).
    static func frame(viewport: CGSize) -> CGRect { .zero }
}

extension FlexibleStageModel {
    /// A view button: on ⇄ off.
    public func toggleView(_ v: FlexibleStageViews) {
        if views.contains(v) { views.remove(v) } else { views.insert(v) }
        // RED CONTROL: the views written into the settings (an action, a modified page)
        if controlViewsInSettings {
            edit({ s in var c = s.groupColours ?? [:]; c["views"] = String(views.rawValue); s.groupColours = c }, recompute: false)
            actionSerial += 1
        }
    }
}
