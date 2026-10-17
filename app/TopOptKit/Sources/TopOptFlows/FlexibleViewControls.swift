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
/// is gone — the Settings page is always in X-ray (FlexibleStagePage.xray). ★ ROUND 6 (item 3): the
/// [Prisms] and [Groups] view buttons under it (FlexibleStageViewButtons).
struct FlexibleViewColumn: View {
    @ObservedObject var camera: OrbitCameraModel
    var model: FlexibleStageModel? = nil

    var body: some View {
      ZStack(alignment: .topTrailing) {
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
        if let model { FlexibleStageViewButtons(model: model) }
      }
    }
}

/// The workspace's view-mode button, same metrics and tokens.
/// ★ ROUND 7, R7-V (his answer, 2026-10-14 — Heat on the Settings page: "TAP = the heat on every face of the CURRENT group;
/// HOLD 3 s = the heat on ALL groups' faces"): an optional `onLongPress` — a 3 s hold, simultaneous with the tap, as the
/// workspace's own view-mode buttons do (WorkspacePlaceholder.viewModeButton, copied — #354's file is not edited): the
/// release that ends the hold is also delivered as a tap and is swallowed by the PRESS it ends (ViewModeHold.swallowsTap).
/// Icon only — the label is the accessibility text (his rule: view buttons are icons, never words).
struct FlexibleViewButton: View {
    /// ★ R7-D1 STUB: the icon's side.
    static let side: CGFloat = 40
    let icon: String
    let label: String
    let on: Bool
    let action: () -> Void
    /// ★ R6 REVIEW: a glyph of its own in place of the SF symbol (the Settings page's [Prisms] / [Groups]).
    var glyph: AnyView? = nil
    /// ★ R7-V: a 3 s hold's action (nil: no hold).
    var onLongPress: (() -> Void)? = nil
    /// Test control only (R7-V): the release tap NOT swallowed (it undoes the hold).
    @MainActor static var controlNoSwallow = false

    @State var holdFiredAt = Date.distantPast
    @State var pressBeganAt: Date?
    @GestureState var pressDown = false

    var body: some View {
        Button(action: {
            if onLongPress != nil, !Self.controlNoSwallow,
               ViewModeHold.swallowsTap(holdFiredAt: holdFiredAt, pressBeganAt: pressBeganAt, now: Date()) { return }
            action()
        }) {
            Group {
                if let glyph {
                    glyph
                } else {
                    Image(systemName: icon)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle((on ? DS.Color.textPrimary : DS.Color.textTertiary).color)
                }
            }
                .frame(width: 40, height: 40)
                .background(
                    RoundedRectangle(cornerRadius: DS.Radius.pill, style: .continuous)
                        .fill(on ? DS.Color.accentDeep.opacity(0.55).color : DS.Surface.bar.color)
                        .overlay(RoundedRectangle(cornerRadius: DS.Radius.pill, style: .continuous)
                            .strokeBorder(DS.Color.strokePanel.color, lineWidth: 1))
                )
        }
        .buttonStyle(.plain)
        .simultaneousGesture(
            LongPressGesture(minimumDuration: 3.0)
                .onEnded { _ in holdFiredAt = Date(); onLongPress?() },
            including: onLongPress == nil ? .none : .all)
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .updating($pressDown) { _, down, _ in down = true },
            including: onLongPress == nil ? .none : .all)
        .onChange(of: pressDown) { down in
            if down { pressBeganAt = Date() }
        }
        .accessibilityLabel(label)
        .accessibilityValue(on ? "On" : "Off")
    }
}
