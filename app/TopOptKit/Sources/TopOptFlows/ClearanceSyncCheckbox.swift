// ClearanceSyncCheckbox.swift — the "Same clearance for all" checkbox (design-overhaul
// round 2, item 7).
//
// The 109 sync control was a text toggle that ONLY appeared in the Selections header when
// ≥2 keep-clear sites existed — invisible in practice (the maintainer couldn't find it). This
// replaces it with a small liquid-glass CHECKBOX that rides the clearance chips themselves:
//   * visible whenever the clearance chips are (≥1 keep-clear site),
//   * DISABLED with a plain-English explanation at EXACTLY 1 site (nothing to link yet),
//   * actionable at ≥2 sites, DEFAULT CHECKED,
// and it appears in BOTH places the chips do — beside the on-model margin/axial pills and
// mirrored in the Selections panel — so it's always right next to what it governs.
//
// The visibility/enabled decision is the pure `SyncCheckboxState`, headless-tested; the glass
// chrome is maintainer device QA (the /app/ standard). The fan-out semantics are unchanged —
// the checkbox writes `ForceModel.setSyncClearances`, whose peer fan-out is proven by the 109
// tests (`ForceModelTests` "Same clearance for all" block).

import SwiftUI
import TopOptDesign

/// What the sync checkbox should do for a given number of editable keep-clear sites. Pure, so
/// the "visible whenever chips are; disabled-with-reason at exactly 1" rule is unit-tested.
public enum SyncCheckboxState: Equatable {
    /// No keep-clear sites — the checkbox is not shown at all (there are no chips either).
    case hidden
    /// Exactly ONE site — shown but not actionable, with an explanation (nothing to sync yet).
    case disabledSingleSite
    /// Two or more sites — actionable; carries the current on/off.
    case active(Bool)

    /// The state for `siteCount` editable keep-clear sites, given the current toggle value.
    public static func forSiteCount(_ siteCount: Int, isOn: Bool) -> SyncCheckboxState {
        if siteCount <= 0 { return .hidden }
        if siteCount == 1 { return .disabledSingleSite }
        return .active(isOn)
    }

    /// Shown at all? (≥1 site.)
    public var isVisible: Bool { self != .hidden }
    /// Tappable? (≥2 sites.)
    public var isEnabled: Bool { if case .active = self { return true }; return false }
    /// Rendered checked? Disabled-single-site still shows the DEFAULT-checked box so the user
    /// sees the intent ("these will match once you add another"); ≥2 sites reflects the value.
    public var isChecked: Bool {
        switch self {
        case .hidden: return false
        case .disabledSingleSite: return true
        case .active(let on): return on
        }
    }
    /// The explanation shown at exactly one site (nil otherwise).
    public var explanation: String? {
        self == .disabledSingleSite
            ? "Add another keep-clear site and they’ll share one clearance."
            : nil
    }
}

/// A small liquid-glass checkbox labelled "Same clearance for all". Sizes to the chips it rides
/// with (`compact` for the Selections row). `siteCount` drives visibility/enablement via
/// `SyncCheckboxState`; toggling writes back through `onToggle`.
struct ClearanceSyncCheckbox: View {
    let siteCount: Int
    let isOn: Bool
    var compact: Bool = false
    let onToggle: (Bool) -> Void

    private var state: SyncCheckboxState { .forSiteCount(siteCount, isOn: isOn) }

    var body: some View {
        if state.isVisible {
            Button { if state.isEnabled { onToggle(!isOn) } } label: {
                HStack(spacing: DS.Space.xs) {
                    Image(systemName: state.isChecked ? "checkmark.square.fill" : "square")
                        .font(.system(size: compact ? 11 : 12, weight: .semibold))
                    Text("Same clearance for all")
                        .font(.system(size: compact ? 10.5 : 11.5, weight: .semibold))
                }
                .foregroundStyle(foreground)
                .padding(.vertical, compact ? 4 : 5)
                .padding(.horizontal, compact ? DS.Space.s : DS.Space.sm)
                .liquidGlassCapsule(state.isChecked && state.isEnabled ? .blue : .neutral)
                .opacity(state.isEnabled ? 1 : 0.6)
            }
            .buttonStyle(.plain)
            .disabled(!state.isEnabled)
            .help(state.explanation ?? "Apply one clearance to every keep-clear site")
            .accessibilityLabel("Same clearance for all keep-clear sites")
            .accessibilityValue(state.isChecked ? "On" : "Off")
            .accessibilityHint(state.explanation ?? "")
        }
    }

    private var foreground: Color {
        if !state.isEnabled { return DS.Color.textTertiary.color }
        return state.isChecked ? DS.Color.accent.color : DS.Color.textSecondary.color
    }
}
