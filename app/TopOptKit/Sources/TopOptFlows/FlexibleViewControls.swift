// FlexibleViewControls — the position gizmo and the X-ray "view" button under it
// (task 2026-09-29-flexible-screens; maintainer, 2026-09-29: "Imagine an 'X-ray vision'
// with a plane with a heat map for the dent. Make it a 'view' button below the position
// gizmo (which should be on every screen that had a 3d object)" and "I'd like the x-ray to
// look more ghostly for this version with the bent plane showing the dent").
//
// ★ THE SAME FAMILY AS THE WORKSPACE'S VIEWS. The gizmo is `OrientationGizmoView` at its
// one shared size in the absolute top-right corner (`PageChrome.gizmoInset`), and the
// button copies the workspace's `viewModeButton` metrics and tokens (40 pt square,
// `DS.Radius.pill`, `DS.Surface.bar` off / `DS.Color.accentDeep` 55 % on, the X-ray icon),
// so it reads as the same control on another page. That helper is private to
// WorkspacePlaceholder, so it is mirrored here rather than hooked out of #354's file.

import SwiftUI
import TopOptDesign

/// The top-right column: the gizmo. ★ ROUND 3 (item 1.4): the X-ray button that sat under it
/// is gone — the Settings page is always in X-ray (FlexibleStagePage.xray).
struct FlexibleViewColumn: View {
    @ObservedObject var camera: OrbitCameraModel

    var body: some View {
        VStack {
            HStack {
                Spacer()
                VStack(alignment: .trailing, spacing: DS.Space.s) {
                    OrientationGizmoView(camera: camera, size: OrientationGizmoView.standardSize)
                }
            }
            Spacer()
        }
        .padding(.top, PageChrome.gizmoInset)
        .padding(.trailing, PageChrome.gizmoInset)
    }
}

/// The workspace's view-mode button, same metrics and tokens.
struct FlexibleViewButton: View {
    let icon: String
    let label: String
    let on: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle((on ? DS.Color.textPrimary : DS.Color.textTertiary).color)
                .frame(width: 40, height: 40)
                .background(
                    RoundedRectangle(cornerRadius: DS.Radius.pill, style: .continuous)
                        .fill(on ? DS.Color.accentDeep.opacity(0.55).color : DS.Surface.bar.color)
                        .overlay(RoundedRectangle(cornerRadius: DS.Radius.pill, style: .continuous)
                            .strokeBorder(DS.Color.strokePanel.color, lineWidth: 1))
                )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityValue(on ? "On" : "Off")
    }
}
