// ClearanceSyncCheckbox.swift — the PER-ROW clearance "Sync" checkbox (device round 3, items 5+6).
//
// The 109 global "Same clearance for all" toggle and its round-2 on-model checkbox
// (`ClearanceSyncCheckbox` + the `SyncCheckboxState` hidden/disabled-single-site/active machine)
// are BOTH withdrawn by the maintainer. Sync membership is now PER ROW: every keep-clear row
// carries this small liquid-glass checkbox, ALWAYS ENABLED (no ≥2-sites gate, no disabled state),
// DEFAULT CHECKED. Checked rows share ONE clearance (editing any checked row writes every checked
// row); an unchecked row is independent and keeps its own value; re-checking adopts the shared
// value. All of that membership + fan-out + adopt-on-check logic lives in `ForceModel` and is
// headless-tested; this is just the row-level glass control that reads/drives it (device QA).

import SwiftUI
import TopOptDesign

/// A small, always-enabled "Sync" checkbox for one keep-clear row. `isOn` reflects the row's
/// membership in the shared clearance group; tapping writes back through `onToggle`.
struct ClearanceSyncRowCheckbox: View {
    let isOn: Bool
    var compact: Bool = true
    let onToggle: (Bool) -> Void

    var body: some View {
        Button { onToggle(!isOn) } label: {
            HStack(spacing: 3) {
                Image(systemName: isOn ? "checkmark.square.fill" : "square")
                    .font(.system(size: compact ? 10.5 : 12, weight: .semibold))
                Text("Sync")
                    .font(.system(size: compact ? 10 : 11.5, weight: .semibold))
            }
            .foregroundStyle(isOn ? DS.Color.accent.color : DS.Color.textTertiary.color)
            .padding(.vertical, compact ? 3 : 4)
            .padding(.horizontal, compact ? DS.Space.s : DS.Space.sm)
            .liquidGlassCapsule(isOn ? .blue : .neutral)
        }
        .buttonStyle(.plain)
        .help(isOn
              ? "Synced — this site shares one clearance with the other checked sites. Uncheck to give it its own."
              : "Independent — this site keeps its own clearance. Check to adopt the shared value.")
        .accessibilityLabel("Sync clearance for this site")
        .accessibilityValue(isOn ? "On" : "Off")
        .accessibilityHint("Checked sites share one clearance; unchecked sites are independent.")
    }
}
