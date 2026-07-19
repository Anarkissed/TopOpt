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

// MARK: - Gizmo layout (the ONE source for every control's placement — headless-tested)

/// The squircle-relative geometry that positions the three controls (both roll arrows +
/// the Home cube) and the housing. Design-overhaul round 2 (items 2–4): all three controls
/// share ONE inset from their nearest edges (equal margins, comfortably inside), and the
/// glass cube sits at the EXACT centre of the squircle (`housingOffset == .zero` — the
/// housing-offset bug that pushed the cube high has recurred once, so it is asserted here
/// and in `OrientationLayoutTests`). Pure fractions of the widget `size`, so a test can
/// prove the equal-margin + centred invariants without touching SwiftUI.
public enum GizmoLayout {
    /// The single inset (fraction of `size`) every control sits at from its NEAREST edges.
    /// One constant → the two arrows and the Home cube share an identical corner margin.
    public static let controlInsetFraction: CGFloat = 0.20
    /// The roll-arrow button footprint (fraction of `size`).
    public static let arrowButtonFraction: CGFloat = 0.22
    /// The Home-cube button footprint (fraction of `size`).
    public static let homeButtonFraction: CGFloat = 0.17
    /// The frosted housing squircle side (fraction of `size`), CENTRED in the frame.
    public static let housingFraction: CGFloat = 0.90
    /// The housing's offset from the frame centre — ZERO, so the raymarched cube (which
    /// renders at the frame centre) sits dead-centre of the squircle. Do not reintroduce a
    /// vertical nudge here: that is exactly the recurring "cube sits high / off-centre" bug.
    public static let housingOffset: CGSize = .zero

    /// The inset (points) for a given widget size.
    public static func controlInset(_ size: CGFloat) -> CGFloat { size * controlInsetFraction }
    /// Centre of the left (counter-clockwise) roll arrow — top-left corner.
    public static func rotateLeftCenter(_ size: CGFloat) -> CGPoint {
        CGPoint(x: controlInset(size), y: controlInset(size))
    }
    /// Centre of the right (clockwise) roll arrow — top-right corner, mirror of the left.
    public static func rotateRightCenter(_ size: CGFloat) -> CGPoint {
        CGPoint(x: size - controlInset(size), y: controlInset(size))
    }
    /// Centre of the Home cube — bottom-right corner, the SAME inset as the arrows.
    public static func homeCenter(_ size: CGFloat) -> CGPoint {
        CGPoint(x: size - controlInset(size), y: size - controlInset(size))
    }
}

public struct OrientationGizmoView: View {
    @ObservedObject private var camera: OrbitCameraModel
    /// The widget's square footprint. Defaults to `standardSize` — ONE size on every screen
    /// (design-overhaul round 2, item 4: the workspace-210 / results-300 divergence is dead).
    private let size: CGFloat

    /// The single gizmo size used on EVERY screen (workspace + results). Big enough to read
    /// the etched face labels and hold the corner control-ring, small enough to sit in the
    /// absolute top-right corner without reaching the other panels.
    public static let standardSize: CGFloat = 210

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

    public init(camera: OrbitCameraModel, size: CGFloat = OrientationGizmoView.standardSize) {
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
            .overlay(shape.strokeBorder(DS.Color.accent.opacity(0.16).color, lineWidth: 1.5)
                        .blur(radius: 1.5))                            // faint blue edge glow
            // CENTERED (design-overhaul 109, re-asserted round 2 item 3): the cube renders at
            // the frame centre, so the housing is centred on the frame too — `GizmoLayout
            // .housingOffset` is ZERO. The old `size*0.07` downward nudge left the cube high /
            // off-centre; that bug has recurred once, so the offset is a named constant proven
            // zero in `OrientationLayoutTests`.
            .frame(width: size * GizmoLayout.housingFraction, height: size * GizmoLayout.housingFraction)
            .offset(x: GizmoLayout.housingOffset.width, y: GizmoLayout.housingOffset.height)
            .dsShadow(.panel)
    }

    /// The shadow the floating glass casts straight back onto the housing plane — centred
    /// under the (now centred) cube.
    private var dropShadow: some View {
        Circle()
            .fill(RadialGradient(
                colors: [Color.black.opacity(0.55), Color.black.opacity(0.22), .clear],
                center: .init(x: 0.5, y: 0.5), startRadius: 0, endRadius: size * 0.30))
            .frame(width: size * 0.62, height: size * 0.62)
            .blur(radius: size * 0.06)
            .opacity(0.8)
    }

    // MARK: - Face labels (ATTACHED decals — etched on the glass, transform with the cube)

    /// The etched-decal colour: a bright cool-white so the label reads on the blue frost.
    private let labelColor = Color(red: 0.86, green: 0.93, blue: 1.0)

    /// Labels ETCHED onto the cube faces (design-overhaul 109): each label is drawn in a
    /// `Canvas` with a per-face affine that maps its local axes onto the face's projected
    /// tangent axes, so it rotates, shears and fades WITH the cube — not the rejected upright
    /// billboards of 107. The projection is the shader's own virtual camera (FOV/CAMZ + the
    /// live view rotation), so the decals sit exactly where the glass faces are drawn.
    private var labels: some View {
        Canvas { ctx, sz in
            let R = camera.viewRotation
            let font = Font.system(size: max(11, size * 0.05), weight: .heavy, design: .rounded)
            for face in OrientationGizmo.faces {
                guard let d = faceDecal(face, rotation: R, size: sz) else { continue }
                var c = ctx
                c.opacity = Double(d.opacity)
                c.transform = d.transform
                c.addFilter(.shadow(color: DS.Color.accentCyan.opacity(0.55).color, radius: 2.5))
                var text = c.resolve(Text((face.label ?? "").uppercased()).font(font))
                text.shading = .color(labelColor)
                c.draw(text, at: .zero, anchor: .center)
            }
        }
        .frame(width: size, height: size)
    }

    /// Project a model-space point through the gizmo's virtual camera (the SAME FOV/CAMZ the
    /// Metal shader uses), into view-space points (top-left origin, y down). Nil behind the cam.
    private func projectGizmo(_ p: SIMD3<Float>, rotation R: simd_float3x3, size: CGSize) -> CGPoint? {
        let c = GizmoConstants.standard
        let v = R * p
        let tf = tanf(c.fov * 0.5 * .pi / 180)
        let dz = c.camZ - v.z
        guard dz > 0.05 else { return nil }
        let ndcX = v.x / (dz * tf), ndcY = v.y / (dz * tf)
        return CGPoint(x: CGFloat(ndcX * 0.5 + 0.5) * size.width,
                       y: CGFloat(1 - (ndcY * 0.5 + 0.5)) * size.height)
    }

    /// The affine + opacity that paints a face's label onto the glass. Builds the face's local
    /// text axes (right `t`, down `b`) in model space, projects the face centre and a small
    /// step along each axis, and uses the resulting screen vectors as the decal's basis — so
    /// the label follows the face through any orbit/roll. Nil when the face turns away.
    private func faceDecal(_ face: GizmoRegion, rotation R: simd_float3x3,
                           size: CGSize) -> (transform: CGAffineTransform, opacity: Float)? {
        let n = face.anchor                                   // (±1,0,0)… already unit
        let facing = (R * n).z
        guard facing > 0.12 else { return nil }               // face is turned away
        // Face "up" in model space: side/front/back use world +Y; the poles use ∓Z so the
        // label has a defined heading. `t` = text-right, `b` = text-down.
        let faceUp: SIMD3<Float> = abs(n.y) > 0.5 ? SIMD3<Float>(0, 0, n.y > 0 ? -1 : 1)
                                                  : SIMD3<Float>(0, 1, 0)
        let t = simd_normalize(simd_cross(faceUp, n))
        let b = -faceUp
        let delta: Float = 0.34
        let cM = n * 1.0                                       // on the glass face
        guard let p0 = projectGizmo(cM, rotation: R, size: size),
              let pt = projectGizmo(cM + t * delta, rotation: R, size: size),
              let pb = projectGizmo(cM + b * delta, rotation: R, size: size) else { return nil }
        var ux = CGVector(dx: pt.x - p0.x, dy: pt.y - p0.y)
        var uy = CGVector(dx: pb.x - p0.x, dy: pb.y - p0.y)
        let lx = hypot(ux.dx, ux.dy), ly = hypot(uy.dx, uy.dy)
        guard lx > 0.5, ly > 0.5 else { return nil }
        // Unit orientation basis × a foreshortening scale (shrinks as the face turns away).
        let scl = CGFloat(0.72 + 0.28 * facing)
        ux = CGVector(dx: ux.dx / lx * scl, dy: ux.dy / lx * scl)
        uy = CGVector(dx: uy.dx / ly * scl, dy: uy.dy / ly * scl)
        let transform = CGAffineTransform(a: ux.dx, b: ux.dy, c: uy.dx, d: uy.dy, tx: p0.x, ty: p0.y)
        return (transform, smoothstep(0.12, 0.5, facing))
    }

    // MARK: - Controls (the corner ring: two swoosh buttons + Home, ~48px inset)

    private var controls: some View {
        let arrow = size * GizmoLayout.arrowButtonFraction
        let home = size * GizmoLayout.homeButtonFraction
        return ZStack {
            // Both arrows and the Home cube share ONE inset from their nearest edges
            // (`GizmoLayout`, item 2): equal margins, comfortably inside the squircle.
            RotateButton(clockwise: false) { roll(by: Self.rollStep, "Rolled ⟲") }
                .frame(width: arrow, height: arrow)
                .position(GizmoLayout.rotateLeftCenter(size))
            RotateButton(clockwise: true) { roll(by: -Self.rollStep, "Rolled ⟳") }
                .frame(width: arrow, height: arrow)
                .position(GizmoLayout.rotateRightCenter(size))
            HomeButton {
                camera.home(animated: true); flash(OrientationGizmo.homeNumericId); showToast("Home")
            }
            .frame(width: home, height: home)
            .position(GizmoLayout.homeCenter(size))
        }
        .frame(width: size, height: size)
    }

    /// Radians of view-roll per arrow tap (15°).
    private static let rollStep: Float = .pi / 12

    /// ROLL the view about the visual (line-of-sight) axis by `delta` radians — what the
    /// arrows visually promise (design-overhaul 109). This drives the roll DOF added to
    /// `OrbitCamera` for this task (the 074 roll=0 decision is overridden by the maintainer;
    /// handoff 107 Blocked-stopped here). The gizmo cube and the Metal viewer share this exact
    /// camera, so both roll together; Home levels it back.
    private func roll(by delta: Float, _ label: String) {
        camera.rollBy(delta)
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

/// A matched glossy-WHITE 3D swoosh ROLL arrow — a faithful port of the maintainer's HTML mock
/// (design-overhaul round 2, item 1; `docs/design/gizmo_redesign.html` `#rotL`/`#rotR`). The
/// 109 "blue-glass rotate pair" is REJECTED. Each arrow is a ~200° tube stroked with the mock's
/// white→cool-white glass gradient (top white → mid cool-white → foot faint blue), a thin bright
/// sheen riding the top, and a filled arrowhead in the same gradient; a soft black drop-shadow +
/// faint blue glow give it dimension. Like the mock, each arrow is spun 45° INTO its corner so
/// the arc runs parallel to the squircle's fillet, and the right button is the exact MIRROR of
/// the left, so the two read as one matched pair. Taps roll the view ±15° about the view axis.
private struct RotateButton: View {
    let clockwise: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Canvas { ctx, sz in draw(&ctx, sz) }
                // Mirror the pair, then spin each into its corner (mock: rotL −45°, rotR +45°).
                .scaleEffect(x: clockwise ? -1 : 1, y: 1)
                .rotationEffect(.degrees(clockwise ? 45 : -45))
                .contentShape(Rectangle())
                // Soft drop-shadow + faint blue glow (mock's `filter: drop-shadow(…)`), giving
                // the white gloss its 3D lift off the housing.
                .shadow(color: .black.opacity(0.55), radius: 5, x: 0, y: 4)
                .shadow(color: Color(red: 0.55, green: 0.75, blue: 1.0).opacity(0.22), radius: 6)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(clockwise ? "Roll view right" : "Roll view left")
        .accessibilityHint("Rotate the view about the viewing axis")
    }

    /// The mock's glass gradient stops: white(0.95) → cool-white(0.66) → faint blue(0.40).
    private static let glass = Gradient(stops: [
        .init(color: Color(red: 1.0, green: 1.0, blue: 1.0).opacity(0.96), location: 0),
        .init(color: Color(red: 0.80, green: 0.87, blue: 0.98).opacity(0.66), location: 0.5),
        .init(color: Color(red: 0.58, green: 0.66, blue: 0.82).opacity(0.42), location: 1)])

    private func draw(_ ctx: inout GraphicsContext, _ sz: CGSize) {
        let c = CGPoint(x: sz.width / 2, y: sz.height / 2)
        let r = min(sz.width, sz.height) * 0.31
        let lw = r * 0.46
        // A ~200° tube arcing OVER THE TOP, open at the bottom-left where the arrowhead flies
        // off (counter-clockwise, like the mock's `rotL`).
        let a0 = Angle.degrees(200), a1 = Angle.degrees(-20)
        var arc = Path()
        arc.addArc(center: c, radius: r, startAngle: a0, endAngle: a1, clockwise: true)
        ctx.stroke(arc, with: .linearGradient(Self.glass,
                                              startPoint: CGPoint(x: c.x, y: c.y - r),
                                              endPoint: CGPoint(x: c.x, y: c.y + r)),
                   style: StrokeStyle(lineWidth: lw, lineCap: .round))

        // Arrowhead at the a0 (200°) end, pointing along the CCW tangent (down-and-left).
        let end = CGPoint(x: c.x + r * CGFloat(cos(a0.radians)),
                          y: c.y + r * CGFloat(sin(a0.radians)))
        let tang = CGVector(dx: CGFloat(sin(a0.radians)), dy: CGFloat(-cos(a0.radians)))   // CCW tangent
        let head = lw * 1.55
        let normal = CGVector(dx: -tang.dy, dy: tang.dx)
        let tip = CGPoint(x: end.x + tang.dx * head, y: end.y + tang.dy * head)
        let bL = CGPoint(x: end.x + normal.dx * head * 0.85, y: end.y + normal.dy * head * 0.85)
        let bR = CGPoint(x: end.x - normal.dx * head * 0.85, y: end.y - normal.dy * head * 0.85)
        var tri = Path()
        tri.move(to: tip); tri.addLine(to: bL); tri.addLine(to: bR); tri.closeSubpath()
        ctx.fill(tri, with: .linearGradient(Self.glass,
                                            startPoint: CGPoint(x: end.x, y: end.y - head),
                                            endPoint: CGPoint(x: end.x, y: end.y + head)))

        // Sheen: a thin bright white highlight riding the top of the glass tube.
        var sheen = Path()
        sheen.addArc(center: CGPoint(x: c.x, y: c.y - lw * 0.26), radius: r,
                     startAngle: .degrees(210), endAngle: .degrees(330), clockwise: false)
        ctx.stroke(sheen, with: .color(Color.white.opacity(0.85)),
                   style: StrokeStyle(lineWidth: lw * 0.18, lineCap: .round))
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
