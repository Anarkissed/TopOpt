// OrientationGizmoView.swift — the ViewCube-style orientation widget (the
// 3d-gizmo-orbit-camera task, STEP 3/4).
//
// A small translucent cube that mirrors the shared `OrbitCameraModel`'s live
// orientation and drives it: tap a face/edge/corner to ease to that canonical view,
// grab-and-spin to orbit, and press Home to return to the viewer's default angle. It
// shares the exact camera the Metal viewer uses, so the cube and the model can never
// drift apart.
//
// The geometry/hit-testing is the pure, unit-tested `OrientationGizmo`; this file is
// the SwiftUI drawing + gestures (device QA — the M7 /app/ standard). The look reuses
// the design's dark-glass tokens (Surface.bar fill over a backdrop blur, the
// strokePanel hairline, control radius) so it reads as part of the app, not an engine
// widget.

import SwiftUI
import TopOptDesign
import simd

public struct OrientationGizmoView: View {
    @ObservedObject private var camera: OrbitCameraModel
    private let size: CGFloat

    /// Hovered region (pointer devices) — lights its faces.
    @State private var hovered: GizmoRegion?
    /// Drag tracking so a zero-distance drag reads as a tap→snap and a real drag orbits.
    @State private var dragLast: CGPoint?
    @State private var dragMoved: CGFloat = 0

    public init(camera: OrbitCameraModel, size: CGFloat = 74) {
        self.camera = camera
        self.size = size
    }

    public var body: some View {
        VStack(spacing: DS.Space.s) {
            cube
            homeButton
        }
        .accessibilityElement(children: .contain)
    }

    // MARK: - Cube

    private var cube: some View {
        Canvas { ctx, sz in draw(&ctx, size: sz) }
            .frame(width: size, height: size)
            .background(glassBacking(radius: DS.Radius.control))
            .contentShape(Rectangle())
            .gesture(orbitOrTap)
            .modifier(HoverRegions(size: size, rotation: camera.viewRotation, hovered: $hovered))
            .accessibilityLabel("Orientation cube")
            .accessibilityHint("Drag to orbit the model, or tap a face to snap to that view")
    }

    /// A single combined gesture: a real drag grabs-and-spins the cube (orbits the
    /// shared camera); a tap (near-zero movement) snaps to the tapped region.
    private var orbitOrTap: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { g in
                let last = dragLast ?? g.startLocation
                let dx = Float(g.location.x - last.x)
                let dy = Float(g.location.y - last.y)
                // Same mapping as the viewer's drag (y-down), so grabbing the cube feels
                // like grabbing the model.
                if dx != 0 || dy != 0 { camera.orbit(dx: dx, dy: dy) }
                dragMoved += hypot(g.location.x - last.x, g.location.y - last.y)
                dragLast = g.location
            }
            .onEnded { g in
                let moved = dragMoved
                dragLast = nil
                dragMoved = 0
                guard moved < 6 else { return }   // a spin, already applied
                if let region = OrientationGizmo.hitTest(
                    point: g.startLocation, in: CGSize(width: size, height: size),
                    rotation: camera.viewRotation) {
                    camera.snap(to: region, animated: true)
                }
            }
    }

    /// Paint the cube: project the 8 corners through the live view rotation, then fill
    /// the front-facing faces (painter-sorted), highlight the hovered region's faces, and
    /// label the principal faces.
    private func draw(_ ctx: inout GraphicsContext, size sz: CGSize) {
        let r = camera.viewRotation
        let center = CGPoint(x: sz.width / 2, y: sz.height / 2)
        let k = Float(min(sz.width, sz.height) / 2) * OrientationGizmo.cubeScreenScale

        func project(_ p: SIMD3<Float>) -> (pt: CGPoint, depth: Float) {
            let v = r * p
            return (CGPoint(x: center.x + CGFloat(v.x * k),
                            y: center.y - CGFloat(v.y * k)), v.z)
        }

        // Front-facing faces, farthest first (so nearer faces paint on top).
        let visible = Self.cubeFaces
            .map { face -> (face: CubeFace, normalZ: Float, depth: Float) in
                let nz = (r * face.normal).z
                let depth = face.corners.reduce(Float(0)) { $0 + (r * $1).z } / 4
                return (face, nz, depth)
            }
            .filter { $0.normalZ > 0.02 }
            .sorted { $0.depth < $1.depth }

        for item in visible {
            let face = item.face
            var path = Path()
            for (i, c) in face.corners.enumerated() {
                let p = project(c).pt
                if i == 0 { path.move(to: p) } else { path.addLine(to: p) }
            }
            path.closeSubpath()

            let lit = isLit(face)
            let fill = lit ? DS.Color.accent.opacity(0.30).color
                           : Color.white.opacity(0.06 + 0.05 * Double(item.normalZ))
            ctx.fill(path, with: .color(fill))
            ctx.stroke(path, with: .color(lit ? DS.Color.accent.opacity(0.85).color
                                              : Color.white.opacity(0.16)),
                       lineWidth: 1)

            // Label a face once it faces the viewer enough to read. The threshold sits
            // below 0.5 so the default 3/4 view (Top's normal·view == 0.5) still shows
            // Front, Top AND Right — the labels the task asks to be visible.
            if let label = face.label, item.normalZ > 0.4 {
                let c = project(face.center).pt
                let text = Text(label.uppercased())
                    .font(.system(size: 8.5, weight: .semibold))
                    .foregroundColor(lit ? DS.Color.textPrimary.color
                                         : DS.Color.textPrimary.opacity(0.7).color)
                ctx.draw(text, at: c)
            }
        }
    }

    /// Whether `face` should highlight: its own face is hovered, or the hovered edge/
    /// corner touches it (its anchor is +/- on the face's axis).
    private func isLit(_ face: CubeFace) -> Bool {
        guard let h = hovered else { return false }
        return h.anchor[face.axis] == (face.positive ? 1 : -1)
    }

    // MARK: - Home

    private var homeButton: some View {
        Button { camera.home(animated: true) } label: {
            Image(systemName: "house.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(DS.Color.textPrimary.color)
                .frame(width: 30, height: 30)
                .background(glassBacking(radius: DS.Radius.control))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Home view")
        .accessibilityHint("Return the camera to the default angle")
    }

    // MARK: - Glass chrome (matches the app's chips/drawers)

    private func glassBacking(radius: CGFloat) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        return shape.fill(.ultraThinMaterial)
            .overlay(shape.fill(DS.Surface.bar.color))
            .overlay(shape.strokeBorder(DS.Color.strokePanel.color, lineWidth: 1))
    }

    // MARK: - Cube geometry (drawing only; the clickable regions live in OrientationGizmo)

    fileprivate struct CubeFace {
        let corners: [SIMD3<Float>]   // 4, wound consistently
        let normal: SIMD3<Float>
        let center: SIMD3<Float>
        let label: String?
        let axis: Int                 // 0=X, 1=Y, 2=Z
        let positive: Bool
    }

    private static let cubeFaces: [CubeFace] = {
        func face(_ axis: Int, _ positive: Bool, _ label: String) -> CubeFace {
            let s: Float = positive ? 1 : -1
            var normal = SIMD3<Float>(0, 0, 0); normal[axis] = s
            // The two in-plane axes.
            let a = (axis + 1) % 3, b = (axis + 2) % 3
            func corner(_ ia: Float, _ ib: Float) -> SIMD3<Float> {
                var p = SIMD3<Float>(0, 0, 0); p[axis] = s; p[a] = ia; p[b] = ib; return p
            }
            let corners = [corner(-1, -1), corner(1, -1), corner(1, 1), corner(-1, 1)]
            return CubeFace(corners: corners, normal: normal, center: normal,
                            label: label, axis: axis, positive: positive)
        }
        return [
            face(2, true,  "Front"), face(2, false, "Back"),
            face(0, true,  "Right"), face(0, false, "Left"),
            face(1, true,  "Top"),   face(1, false, "Bottom"),
        ]
    }()
}

/// Pointer-hover tracking factored out so the cube body stays readable. Resolves the
/// hovered region through the same hit-test taps use, so the highlight previews exactly
/// what a click would select.
private struct HoverRegions: ViewModifier {
    let size: CGFloat
    let rotation: simd_float3x3
    @Binding var hovered: GizmoRegion?

    func body(content: Content) -> some View {
        content.onContinuousHover { phase in
            switch phase {
            case .active(let p):
                hovered = OrientationGizmo.hitTest(
                    point: p, in: CGSize(width: size, height: size), rotation: rotation)
            case .ended:
                hovered = nil
            }
        }
    }
}
