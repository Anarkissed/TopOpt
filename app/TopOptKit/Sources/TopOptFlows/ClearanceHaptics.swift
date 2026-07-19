// ClearanceHaptics.swift — light haptic ticks for the keep-clear drag handles (Phase B).
//
// A grab/release impact when a handle is picked up or let go, and a soft selection
// tick when the dragged value crosses its Auto suggestion. UIKit-only; a no-op on
// macOS / where UIKit is unavailable (the macOS test slice, the SwiftUI fallback).
// This is device-QA'd feel — nothing here is unit-tested (there is nothing pure to
// pin); the pure part is the value math that decides WHEN `crossedAuto` fires.

import Foundation

#if canImport(UIKit) && os(iOS)
import UIKit

enum ClearanceHaptics {
    /// A handle was grabbed — a light impact.
    static func grab() { impact(.light) }
    /// A handle was released — a soft rigid impact.
    static func release() { impact(.soft) }
    /// The dragged value crossed the Auto suggestion — a selection tick.
    static func crossedAuto() {
        let g = UISelectionFeedbackGenerator()
        g.prepare()
        g.selectionChanged()
    }
    /// A design-box face snapped into a magnetic detent (device round 3, item 10) — a crisp
    /// rigid tick so the snap is felt as well as seen.
    static func detent() { impact(.rigid) }

    private static func impact(_ style: UIImpactFeedbackGenerator.FeedbackStyle) {
        let g = UIImpactFeedbackGenerator(style: style)
        g.prepare()
        g.impactOccurred()
    }
}
#else
enum ClearanceHaptics {
    static func grab() {}
    static func release() {}
    static func crossedAuto() {}
    static func detent() {}
}
#endif
