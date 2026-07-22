// WorkspaceChipLayout.swift — the bottom-right settings-chip ordering (design-overhaul
// round 2, item 12).
//
// The four bottom-right settings chips (Gravity · Minimize plastic · quality · Design Box)
// stack above the Optimize button. The maintainer wants them ordered SMALLEST width at the top
// → LARGEST at the bottom (Optimize beneath), by their MEASURED width, stably. The view reads
// each chip's real rendered width with a preference key and feeds `BottomChipOrder.sorted`;
// this comparator is pure so the "ascending width, stable tie-break" rule is unit-tested.

import CoreGraphics
import SwiftUI

/// Collects each bottom-right settings chip's measured width (item 12). Merges the per-chip
/// single-entry dictionaries the width readers emit into one `[SettingsChipID: CGFloat]`.
struct SettingsChipWidthKey: PreferenceKey {
    static let defaultValue: [SettingsChipID: CGFloat] = [:]
    static func reduce(value: inout [SettingsChipID: CGFloat], nextValue: () -> [SettingsChipID: CGFloat]) {
        value.merge(nextValue()) { _, new in new }
    }
}

/// A stable identity for each bottom-right settings chip. The `allCases` order is the DEFAULT
/// (and tie-break) order — used before any width is measured and whenever two chips measure
/// equal, so the layout is deterministic frame-to-frame.
public enum SettingsChipID: Int, CaseIterable, Hashable, Sendable {
    case gravity, minimizePlastic, quality, designBox
    /// The ONE global Face-protection depth (handoff 124). Only shown when ≥ 1 face
    /// is protected — the workspace filters it out of the cluster otherwise.
    case faceProtectDepth
}

public enum BottomChipOrder {
    /// Order `ids` by ascending measured width (smallest first → sits at the top of the
    /// bottom-anchored stack), breaking ties — and unmeasured chips — by the ids' original
    /// order. Comparing on the `(width, originalIndex)` pair is a TOTAL order, so the result is
    /// deterministic and stable even though `sorted(by:)` itself is not guaranteed stable.
    /// An unmeasured chip sorts as if maximally wide, so it parks at the bottom until its real
    /// width arrives (one transient frame), rather than jumping around.
    public static func sorted<ID: Hashable>(_ ids: [ID], widths: [ID: CGFloat]) -> [ID] {
        ids.enumerated().sorted { a, b in
            let wa = widths[a.element] ?? .greatestFiniteMagnitude
            let wb = widths[b.element] ?? .greatestFiniteMagnitude
            if wa != wb { return wa < wb }
            return a.offset < b.offset
        }.map(\.element)
    }
}
