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

/// ★ THE BOTTOM BAR'S MEASURED HEIGHT. The settings cluster sits above the bar
/// and has to clear it — and the bar is NOT a fixed height: a DISABLED Optimize
/// carries a second line saying what is missing. A hardcoded clearance let the
/// two overlap, which is what the maintainer's screenshot shows.
struct BottomBarHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// ★ THE GUARD THIS MEASUREMENT SHIPPED WITHOUT — and the defect it now refuses.
///
/// The measuring `GeometryReader` was mounted AFTER the bar's
/// `.frame(maxHeight: .infinity)`, so it measured the EXPANDED frame — the whole
/// viewport — rather than the bar. On a 13-inch iPad that is 1376 pt instead of
/// ~90. Every view that clears the bar then padded itself off the bottom of the
/// screen and the ZStack grew to twice the display, taking the top chrome, the
/// orientation gizmo, the stage buttons and the bar itself out of view. SwiftUI
/// logged only "Bound preference BottomBarHeightKey tried to update multiple
/// times per frame", which names the symptom and not the cause.
///
/// ★ THE MODIFIER ORDER IS THE REAL FIX (the measurement now sits inside the
/// frame). This is the second line of defence: a bar is a BAR, and no bar is
/// nearly as tall as the viewport it sits in. A measurement that large is the
/// expanded frame, and using it is worse than keeping the previous value.
enum BottomBarMeasurement {

    /// The largest share of the viewport a bottom bar may plausibly occupy. The
    /// real bar is ~90 pt of 1376 (6.5%) with a one-line Optimize and ~112 pt
    /// (8.1%) with the disabled two-line one; the broken reading was 100%.
    static let maxViewportShare: CGFloat = 0.35

    /// The height to adopt, or nil to keep what is already held.
    static func accept(measured: CGFloat, viewport: CGFloat) -> CGFloat? {
        guard measured.isFinite, measured > 0 else { return nil }
        guard viewport > 0 else { return measured }
        guard measured <= viewport * maxViewportShare else { return nil }
        return measured
    }
}

/// A stable identity for each bottom-right settings chip. The `allCases` order is the DEFAULT
/// (and tie-break) order — used before any width is measured and whenever two chips measure
/// equal, so the layout is deterministic frame-to-frame.
public enum SettingsChipID: Int, CaseIterable, Hashable, Sendable {
    case gravity, minimizePlastic, quality, designBox
    /// THE SECOND QUESTION (handoff 2026-08-01-build-direction-separation): which
    /// way is UP ON THE PLATE. Sits beside `gravity` deliberately — the two are
    /// adjacent because they are DIFFERENT questions the app used to conflate, and
    /// putting them side by side is how the user sees that they are different.
    case buildOrientation
    /// The ONE global Face-protection depth (handoff 124). Only shown when ≥ 1 face
    /// is protected — the workspace filters it out of the cluster otherwise.
    case faceProtectDepth
    /// Paint mode toggle (handoff 2026-07-25): brush faces into the active group when
    /// tap-selection over-selects. Always present in the edit phase.
    case paint
    /// ★ CAD-FACE PROJECTION on export (task
    /// 2026-08-06-arm-projection-and-void-check, S1c). ON by default, matching
    /// core. Shown only for a STEP part — the whole operation is "put the
    /// surface back where the B-rep says it is", and an STL/3MF import has no
    /// B-rep to put it back to, so the chip would be a control over nothing.
    case cadFaces
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
