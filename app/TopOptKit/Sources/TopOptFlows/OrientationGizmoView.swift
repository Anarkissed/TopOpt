// OrientationGizmoView.swift — the liquid-glass orientation widget (orientation-gizmo-redesign
// task; ports docs/design/gizmo_redesign.html "Liquid Glass View Gizmo v21").
//
// A raymarched SDF "liquid glass" cube that mirrors the shared `OrbitCameraModel`'s live
// orientation and drives it: drag to orbit, tap a face/edge/corner to ease to that canonical
// view, the swoosh buttons step the turntable, and Home returns to the default angle. It
// shares the exact camera the Metal viewer uses, so the glass and the model can never drift
// apart.
//
// COMPOSITION (this file):
//   * the frosted squircle HOUSING (SwiftUI Material + gradients), with the glass floating IN
//     FRONT of it — a soft drop-shadow cast straight back onto the panel sells the depth;
//   * the GLASS itself is a transparent `GizmoMetalView` (the Metal SDF render, in
//     OrientationGizmoMetal.swift) laid over the housing;
//   * LABELS pinned to each face, projected with the SAME virtual camera (FOV/CAMZ) the shader
//     uses, fading as a face turns away;
//   * the CONTROL RING — two swoosh rotate buttons + a Home cube — corner-anchored ~48px in,
//     per the mock's layout;
//   * the snap TOAST.
//
// THE FEEL: picking is the pure, headless-tested `OrientationGizmo.pick` (the shared-constants
// SDF raymarch); drag/snap/home route through `OrbitCameraModel` exactly as before. The idle
// float is a render-only flourish (it freezes while you interact), so taps resolve against the
// settled pose the picker sees. See handoff 105 for the kept/changed behaviour inventory.

import SwiftUI
import TopOptDesign
import simd

public struct OrientationGizmoView: View {
    @ObservedObject private var camera: OrbitCameraModel
    /// The widget's square footprint. Default 300 — sized to read on iPad and hold the
    /// floating glass, the pinned labels, and the corner control ring.
    private let size: CGFloat

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The SDF cell (the shared `globalId`) currently glowing from a pointer hover, or -1.
    @State private var hoverId: Float = -1
    /// A cell briefly lit after a tap (touch has no hover) so a snap flashes its target.
    @State private var flashId: Float = -1
    /// Drag tracking so a near-zero drag reads as a tap→snap and a real drag orbits.
    @State private var dragLast: CGPoint?
    @State private var dragMoved: CGFloat = 0
    /// True while a drag/tap is in flight — freezes the glass's idle float so the pick is exact.
    @State private var interacting = false
    /// The snap toast.
    @State private var toastText = ""
    @State private var toastShown = false

    public init(camera: OrbitCameraModel, size: CGFloat = 300) {
        self.camera = camera
        self.size = size
    }

    private var glowId: Float { flashId >= 0 ? flashId : hoverId }

    public var body: some View {
        ZStack {
            housing
            dropShadow
            glass
            labels.allowsHitTesting(false)
            controls
            toast.allowsHitTesting(false)
        }
        .frame(width: size, height: size)
        .accessibilityElement(children: .contain)
    }

    // MARK: - Glass (the transparent Metal SDF render + the gesture)

    @ViewBuilder
    private var glass: some View {
        #if canImport(MetalKit)
        GizmoMetalView(camera: camera, hoverId: glowId,
                       interacting: interacting, reduceMotion: reduceMotion)
            .frame(width: size, height: size)
            .contentShape(Rectangle())
            .gesture(orbitOrTap)
            .modifier(HoverPick(size: size, rotation: camera.viewRotation, hoverId: $hoverId))
            .accessibilityLabel("Orientation cube")
            .accessibilityHint("Drag to orbit the model, or tap a face to snap to that view")
        #else
        Color.clear.frame(width: size, height: size)
        #endif
    }

    /// One combined gesture — UNCHANGED behaviour from the prior gizmo: a real drag grabs and
    /// spins the cube (orbits the shared camera); a tap (near-zero movement) picks the tapped
    /// face/edge/corner (snap) or the Home core, via the shared SDF `pick`.
    private var orbitOrTap: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { g in
                interacting = true
                let last = dragLast ?? g.startLocation
                let dx = Float(g.location.x - last.x)
                let dy = Float(g.location.y - last.y)
                if dx != 0 || dy != 0 { camera.orbit(dx: dx, dy: dy) }   // same mapping as the viewer
                dragMoved += hypot(g.location.x - last.x, g.location.y - last.y)
                dragLast = g.location
            }
            .onEnded { g in
                let moved = dragMoved
                dragLast = nil
                dragMoved = 0
                interacting = false
                guard moved < 6 else { return }                         // a spin, already applied
                switch OrientationGizmo.pick(point: g.startLocation,
                                             in: CGSize(width: size, height: size),
                                             rotation: camera.viewRotation) {
                case .region(let r):
                    camera.snap(to: r, animated: true)
                    flash(OrientationGizmo.numericId(anchor: r.anchor))
                    showToast(r.label ?? r.id)
                case .home:
                    camera.home(animated: true)
                    flash(OrientationGizmo.homeNumericId)
                    showToast("Home")
                case .miss:
                    break
                }
            }
    }

    /// Flash a snapped cell for the length of the ease so touch (no hover) still gets a glow.
    private func flash(_ id: Float) {
        flashId = id
        DispatchQueue.main.asyncAfter(deadline: .now() + OrbitCameraModel.transitionDuration + 0.15) {
            if flashId == id { flashId = -1 }
        }
    }

    // MARK: - Housing (the frosted squircle the glass floats in front of)

    private var housing: some View {
        let shape = RoundedRectangle(cornerRadius: size * 0.23, style: .continuous)
        return shape
            .fill(.ultraThinMaterial)                                   // real backdrop blur
            .overlay(shape.fill(LinearGradient(                        // dark frosted tint
                colors: [DS.Surface.panel.opacity(0.62).color,
                         Color.black.opacity(0.30),
                         DS.Surface.bar.opacity(0.55).color],
                startPoint: .topLeading, endPoint: .bottomTrailing)))
            .overlay(shape.strokeBorder(                               // top-edge sheen line
                LinearGradient(colors: [Color.white.opacity(0.30), Color.white.opacity(0.04)],
                               startPoint: .top, endPoint: .bottom), lineWidth: 1))
            .overlay(shape.strokeBorder(DS.Color.accent.opacity(0.14).color, lineWidth: 1.5)
                        .blur(radius: 1.5))                            // faint blue edge glow
            .frame(width: size * 0.98, height: size * 0.82)
            .offset(y: size * 0.07)                                    // sit low so the glass floats above it
            .dsShadow(.panel)
    }

    /// The shadow the floating glass casts straight back onto the housing plane.
    private var dropShadow: some View {
        Circle()
            .fill(RadialGradient(
                colors: [Color.black.opacity(0.55), Color.black.opacity(0.22), .clear],
                center: .init(x: 0.46, y: 0.42), startRadius: 0, endRadius: size * 0.30))
            .frame(width: size * 0.62, height: size * 0.62)
            .blur(radius: size * 0.06)
            .offset(y: -size * 0.02)
            .opacity(0.85)
    }

    // MARK: - Face labels (projected with the shader's virtual camera)

    private var labels: some View {
        ZStack {
            ForEach(OrientationGizmo.faces) { face in
                if let l = projectLabel(face) {
                    Text((face.label ?? "").uppercased())
                        .font(.system(size: max(11, size * 0.052), weight: .heavy, design: .rounded))
                        .tracking(1)
                        .foregroundStyle(Color.white.opacity(0.55 + 0.44 * Double(l.opacity)))
                        .shadow(color: DS.Color.accentCyan.opacity(0.75 * Double(l.opacity)).color,
                                radius: 5)
                        .position(l.point)
                }
            }
        }
        .frame(width: size, height: size)
    }

    /// Project a face's label anchor with the SAME perspective (FOV/CAMZ + camera rotation) the
    /// Metal shader renders with, and fade it as the face turns away. Returns nil for a face
    /// pointing away from the viewer. (Divergence from the mock, which etches curved decals into
    /// the glass — here they are upright billboards; disclosed in the handoff.)
    private func projectLabel(_ face: GizmoRegion) -> (point: CGPoint, opacity: Float)? {
        let c = GizmoConstants.standard
        let R = camera.viewRotation
        let normal = face.anchor                                        // (±1,0,0) etc — already unit
        let facing = (R * normal).z
        guard facing > 0.28 else { return nil }
        let v = R * (normal * 1.05)                                     // a touch proud of the dome
        let tf = tanf(c.fov * 0.5 * .pi / 180)
        let dz = c.camZ - v.z
        guard dz > 0.05 else { return nil }
        let ndcX = v.x / (dz * tf), ndcY = v.y / (dz * tf)
        let x = CGFloat((ndcX * 0.5 + 0.5)) * size
        let y = CGFloat(1 - (ndcY * 0.5 + 0.5)) * size
        let opacity = smoothstep(0.28, 0.62, facing)
        return (CGPoint(x: x, y: y), opacity)
    }

    // MARK: - Controls (the corner ring: two swoosh buttons + Home, ~48px inset)

    private var controls: some View {
        let inset = size * 0.16                                         // ~48pt at the 300 default
        let btn = size * 0.22
        return ZStack {
            RotateButton(clockwise: false) { turn(by: .pi / 4, "Turned ⟲ 45°") }
                .frame(width: btn, height: btn)
                .position(x: inset, y: inset)
            RotateButton(clockwise: true) { turn(by: -.pi / 4, "Turned ⟳ 45°") }
                .frame(width: btn, height: btn)
                .position(x: size - inset, y: inset)
            HomeButton {
                camera.home(animated: true); flash(OrientationGizmo.homeNumericId); showToast("Home")
            }
            .frame(width: btn * 0.78, height: btn * 0.78)
            .position(x: size - inset, y: size - inset * 0.95)
        }
        .frame(width: size, height: size)
    }

    /// Step the turntable by `delta` radians of azimuth via the shared camera's existing orbit
    /// API (azimuth -= dx·sensitivity), so no new camera surface is needed.
    ///
    /// DIVERGENCE (disclosed): the mock's arrows ROLL about the screen-Z axis. The shared
    /// `OrbitCamera` is a turntable with up hard-pinned to world +Y — it has no roll DOF, and
    /// adding one would touch `OrbitCamera`/`MetalMeshView` (out of territory; see handoff 105
    /// "Blocked"). A ±45° azimuth step is the faithful in-territory analogue: it steps to the
    /// next quarter-diagonal view, which is what the buttons are useful for here.
    private func turn(by delta: Float, _ label: String) {
        camera.orbit(dx: -delta / OrbitCamera.orbitSensitivity, dy: 0)
        showToast(label)
    }

    // MARK: - Toast

    private var toast: some View {
        VStack {
            Spacer()
            Text(toastText)
                .font(.system(size: max(12, size * 0.043), weight: .semibold))
                .foregroundStyle(Color.white.opacity(0.9))
                .padding(.vertical, 7).padding(.horizontal, 18)
                .background(.ultraThinMaterial, in: Capsule())
                .overlay(Capsule().strokeBorder(Color.white.opacity(0.16), lineWidth: 1))
                .opacity(toastShown ? 1 : 0)
                .offset(y: toastShown ? 0 : 6)
                .padding(.bottom, size * 0.05)
        }
        .frame(width: size, height: size)
    }

    private func showToast(_ text: String) {
        toastText = text
        withAnimation(.easeOut(duration: 0.25)) { toastShown = true }
        let token = text
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) {
            if toastText == token {
                withAnimation(.easeOut(duration: 0.35)) { toastShown = false }
            }
        }
    }
}

// MARK: - Smoothstep

private func smoothstep(_ a: Float, _ b: Float, _ x: Float) -> Float {
    let t = min(max((x - a) / (b - a), 0), 1)
    return t * t * (3 - 2 * t)
}

// MARK: - Pointer-hover picking (previews exactly what a click would select)

private struct HoverPick: ViewModifier {
    let size: CGFloat
    let rotation: simd_float3x3
    @Binding var hoverId: Float

    func body(content: Content) -> some View {
        content.onContinuousHover { phase in
            switch phase {
            case .active(let p):
                switch OrientationGizmo.pick(point: p, in: CGSize(width: size, height: size),
                                             rotation: rotation) {
                case .region(let r): hoverId = OrientationGizmo.numericId(anchor: r.anchor)
                case .home:          hoverId = OrientationGizmo.homeNumericId
                case .miss:          hoverId = -1
                }
            case .ended:
                hoverId = -1
            }
        }
    }
}

// MARK: - Control glyphs

/// A glass swoosh rotate button. A near-half-circle arc with an arrowhead, filled with the
/// mock's top-lit glass gradient and topped by a thin bright sheen line. `clockwise` mirrors
/// it; the whole glyph is spun 45° into its corner like the mock's `rotate(±45deg)`.
private struct RotateButton: View {
    let clockwise: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Canvas { ctx, sz in draw(&ctx, sz) }
                .scaleEffect(x: clockwise ? -1 : 1, y: 1)           // mirror for CW
                .rotationEffect(.degrees(clockwise ? 45 : -45))     // spin into the corner
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(clockwise ? "Rotate view right" : "Rotate view left")
    }

    private func draw(_ ctx: inout GraphicsContext, _ sz: CGSize) {
        let c = CGPoint(x: sz.width / 2, y: sz.height * 0.52)
        let r = min(sz.width, sz.height) * 0.30
        let lw = r * 0.55
        // Arc over the top: from the right (-10°) counter-clockwise to the left (200°).
        let a0 = Angle.degrees(-10), a1 = Angle.degrees(200)
        var arc = Path()
        arc.addArc(center: c, radius: r, startAngle: a0, endAngle: a1, clockwise: false)
        let glass = Gradient(colors: [
            Color.white.opacity(0.95), Color(white: 0.86).opacity(0.66),
            Color(red: 0.58, green: 0.66, blue: 0.82).opacity(0.42)])
        ctx.stroke(arc, with: .linearGradient(glass,
                                              startPoint: CGPoint(x: c.x, y: c.y - r),
                                              endPoint: CGPoint(x: c.x, y: c.y + r)),
                   style: StrokeStyle(lineWidth: lw, lineCap: .round))

        // Arrowhead at the left (200°) end, pointing along the tangent (downward-ish).
        let end = CGPoint(x: c.x + r * CGFloat(cos(a1.radians)),
                          y: c.y + r * CGFloat(sin(a1.radians)))
        let tang = CGVector(dx: CGFloat(sin(a1.radians)), dy: CGFloat(-cos(a1.radians)))  // CCW tangent
        let head = lw * 1.35
        var tri = Path()
        let tip = CGPoint(x: end.x + tang.dx * head, y: end.y + tang.dy * head)
        let normal = CGVector(dx: -tang.dy, dy: tang.dx)
        let bL = CGPoint(x: end.x + normal.dx * head * 0.9, y: end.y + normal.dy * head * 0.9)
        let bR = CGPoint(x: end.x - normal.dx * head * 0.9, y: end.y - normal.dy * head * 0.9)
        tri.move(to: tip); tri.addLine(to: bL); tri.addLine(to: bR); tri.closeSubpath()
        ctx.fill(tri, with: .color(Color.white.opacity(0.9)))

        // Sheen: a thin bright line riding the top of the glass tube.
        var sheen = Path()
        sheen.addArc(center: CGPoint(x: c.x, y: c.y - lw * 0.28), radius: r,
                     startAngle: .degrees(8), endAngle: .degrees(172), clockwise: false)
        ctx.stroke(sheen, with: .color(Color.white.opacity(0.8)),
                   style: StrokeStyle(lineWidth: lw * 0.14, lineCap: .round))
    }
}

/// The Home glyph: a small isometric glass cube (the mock's three-face cube), tinted top-bright
/// / sides-dim.
private struct HomeButton: View {
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Canvas { ctx, sz in draw(&ctx, sz) }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Home view")
        .accessibilityHint("Return the camera to the default angle")
    }

    private func draw(_ ctx: inout GraphicsContext, _ sz: CGSize) {
        // Scale the mock's 24-unit cube glyph into the button.
        let s = min(sz.width, sz.height) / 24
        let ox = (sz.width - 24 * s) / 2, oy = (sz.height - 24 * s) / 2
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: ox + x * s, y: oy + y * s) }
        func poly(_ pts: [CGPoint]) -> Path {
            var path = Path(); path.move(to: pts[0]); pts.dropFirst().forEach { path.addLine(to: $0) }
            path.closeSubpath(); return path
        }
        let top = poly([p(12, 3.6), p(19.4, 7.4), p(12, 11.2), p(4.6, 7.4)])
        let left = poly([p(4.6, 7.4), p(12, 11.2), p(12, 20.4), p(4.6, 16.6)])
        let right = poly([p(12, 11.2), p(19.4, 7.4), p(19.4, 16.6), p(12, 20.4)])
        ctx.fill(top, with: .linearGradient(
            Gradient(colors: [Color.white.opacity(0.92), Color(red: 0.78, green: 0.86, blue: 1).opacity(0.55)]),
            startPoint: p(12, 3.6), endPoint: p(12, 11.2)))
        ctx.fill(left, with: .linearGradient(
            Gradient(colors: [Color(red: 0.55, green: 0.63, blue: 0.78).opacity(0.42),
                              Color(red: 0.33, green: 0.39, blue: 0.55).opacity(0.52)]),
            startPoint: p(8, 7.4), endPoint: p(8, 20.4)))
        ctx.fill(right, with: .linearGradient(
            Gradient(colors: [Color(red: 0.78, green: 0.84, blue: 0.97).opacity(0.66),
                              Color(red: 0.51, green: 0.6, blue: 0.78).opacity(0.42)]),
            startPoint: p(16, 7.4), endPoint: p(16, 20.4)))
    }
}
