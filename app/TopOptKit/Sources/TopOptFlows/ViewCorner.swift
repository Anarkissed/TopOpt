// ViewCorner.swift — ★ B2, the view corner's shared parts (approved design 2026-11-02, design-system §4.2; ledger notes 1,
// 2, 7).
//
// · ViewProjection: ONE [Orthographic │ Perspective] choice for the whole app (every 3D screen's camera follows it, so it
//   never resets between stages or on Results). Remembered on this device.
// · ViewProjectionPair: the two icons in one glass pill, directly LEFT of the gizmo. One is always lit; tapping the other
//   switches. The camera keeps its framing (OrbitCamera.orthographic).
// · XrayLook: ONE X-ray look everywhere — the Results X-ray (the body see-through, its inner faces faint, the colours and
//   the lattice still drawn inside). X-ray and Outlines are two switches; each works alone, both can be on.

import SwiftUI
import Combine
import TopOptDesign

@MainActor
public final class ViewProjection: ObservableObject {
    public static let shared = ViewProjection()
    static let defaultsKey = "topopt.view.orthographic.v1"
    private let defaults: UserDefaults

    @Published public var orthographic: Bool {
        didSet { defaults.set(orthographic, forKey: Self.defaultsKey) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.orthographic = defaults.bool(forKey: Self.defaultsKey)
    }
}

/// The X-ray look, one for every 3D screen (it was 0.3 on Results, 0.04 on Flexible, and on Topology and Lattice only the
/// Outlines drawn through the solid, so X-ray did nothing with Outlines off: note 7).
public enum XrayLook {
    /// How opaque the part's body is drawn under X-ray (the Results look).
    public static let bodyAlpha: Float = 0.3
}

/// [Orthographic │ Perspective], left of the gizmo.
public struct ViewProjectionPair: View {
    @ObservedObject var projection: ViewProjection
    public init(projection: ViewProjection = .shared) { self.projection = projection }

    public var body: some View {
        HStack(spacing: 2) {
            button(icon: "square.grid.3x3", label: "Orthographic", on: projection.orthographic, key: "viewPairOrthographic") {
                projection.orthographic = true
            }
            button(icon: "cube", label: "Perspective", on: !projection.orthographic, key: "viewPairPerspective") {
                projection.orthographic = false
            }
        }
        .padding(3)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(DS.Surface.bar.color)
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(DS.Color.textPrimary.opacity(0.12).color, lineWidth: 1)))
        .background(CornerPairStyle.publish("viewPair"))
    }

    private func button(icon: String, label: String, on: Bool, key: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle((on ? DS.Color.textPrimary : DS.Color.textTertiary).color)
                .frame(width: 44, height: 44)
                .background(RoundedRectangle(cornerRadius: 13, style: .continuous).fill(on ? DS.Color.fillSelected.color : Color.clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityAddTraits(on ? .isSelected : [])
        .background(CornerPairStyle.publish(on ? key + "-on" : key))
    }
}
