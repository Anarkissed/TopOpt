// OrientationGizmoView.swift — the ViewCube-style orientation widget, RE-SKINNED as a
// liquid-glass lens (the gizmo-liquid-glass-reskin task).
//
// A large translucent GLASS cube that mirrors the shared `OrbitCameraModel`'s live
// orientation and drives it: tap a face/edge/corner to ease to that canonical view,
// grab-and-spin to orbit, and press Home to return to the viewer's default angle. It
// shares the exact camera the Metal viewer uses, so the cube and the model can never
// drift apart.
//
// THE FEEL IS UNTOUCHED. The geometry, the projection scale, and the hit-testing are the
// pure, unit-tested `OrientationGizmo`; the drag/tap/snap routing and easing live in
// `OrbitCameraModel`. This file only RE-DRAWS that same cube — nothing here changes what
// a tap snaps to. The 26 anchors and their canonical mapping are exactly as before; the
// bubbles are decorative affordances drawn AT each anchor's projected position, and taps
// still resolve through the same band-based `OrientationGizmo.hitTest`.
//
// STEP 0 — rendering approach (Canvas + layered gradients, option (c)). The deployment
// target is iOS 16.0 (verified: IPHONEOS_DEPLOYMENT_TARGET / Package platforms .iOS(.v16)),
// NOT 26.5 — so iOS-26 Liquid-Glass APIs (`.glassEffect`) are only reachable behind an
// `#available` gate with a fallback. More decisively, the look REQUIRES per-face
// projective drawing that no system effect provides: labels pinned onto the rotating face
// planes (upside-down when the face is), and 26 domed bubbles at projected anchor points.
// A `Canvas` is the one surface that keeps the exact projection math AND renders those,
// so the whole widget is drawn there for one coherent look on every supported OS. The
// system `.glassEffect` is layered onto the frosted holder as a progressive enhancement
// (iOS/macOS 26+); everything below it falls back to `Material` on iOS 16–25. It redraws
// only when the camera publishes (as it already did), and all of it is cheap vector work
// — no per-pixel shader, no framebuffer sampling — so live tracking stays smooth.

import SwiftUI
import TopOptDesign
import simd

public struct OrientationGizmoView: View {
    @ObservedObject private var camera: OrbitCameraModel
    /// The holder squircle's side. Default 300 — ~4× the old 74pt cube, sized to read on
    /// iPad and leave room for the pinned face labels and the bubble targets.
    private let size: CGFloat

    /// Hovered region (pointer devices) — lights its bubble + faces.
    @State private var hovered: GizmoRegion?
    /// Briefly-lit region after a tap (touch has no hover) so a snap flashes its target.
    @State private var pressed: GizmoRegion?
    /// Drag tracking so a zero-distance drag reads as a tap→snap and a real drag orbits.
    @State private var dragLast: CGPoint?
    @State private var dragMoved: CGFloat = 0

    public init(camera: OrbitCameraModel, size: CGFloat = 300) {
        self.camera = camera
        self.size = size
    }

    // MARK: - Layout

    private var holderRadius: CGFloat { min(size * 0.19, 58) }
    private var homeInset: CGFloat { max(size * 0.045, 12) }
    private var homeSide: CGFloat { max(size * 0.15, 40) }

    public var body: some View {
        ZStack(alignment: .topLeading) {
            holder
            cube
            homeButton
                .padding(homeInset)
        }
        .frame(width: size, height: size)
        .accessibilityElement(children: .contain)
    }

    // MARK: - Cube (the clear lens: faces, caustics, pinned labels, bubbles)

    private var cube: some View {
        Canvas { ctx, sz in draw(&ctx, size: sz) }
            .frame(width: size, height: size)
            .contentShape(RoundedRectangle(cornerRadius: holderRadius, style: .continuous))
            .gesture(orbitOrTap)
            .modifier(HoverRegions(size: size, rotation: camera.viewRotation, hovered: $hovered))
            .accessibilityLabel("Orientation cube")
            .accessibilityHint("Drag to orbit the model, or tap a face to snap to that view")
    }

    /// A single combined gesture — UNCHANGED behaviour: a real drag grabs-and-spins the
    /// cube (orbits the shared camera); a tap (near-zero movement) snaps to the tapped
    /// region via the same band-based hit-test as before.
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
                    flash(region)
                    camera.snap(to: region, animated: true)
                }
            }
    }

    /// Flash a tapped region blue for the length of the snap so touch (no hover) still
    /// gets a highlight. Cleared after the ~0.3s ease.
    private func flash(_ region: GizmoRegion) {
        pressed = region
        DispatchQueue.main.asyncAfter(deadline: .now() + OrbitCameraModel.transitionDuration + 0.05) {
            if pressed == region { pressed = nil }
        }
    }

    // MARK: - Canvas drawing

    /// Paint the glass cube. The body is a translucent glass you can SEE THROUGH, so the far
    /// side is drawn first as a ghost, then the near side over it. Each cube face is tiled
    /// with domed glass BUBBLES sized to the actual hit regions — the 3×3 partition that
    /// matches `edgeBand`: a big centre bubble = the face, four strips = the edges (each the
    /// width of the edge up to its corners), four small squares = the corners — with a gap
    /// between them. A specular + chromatic-dispersion caustic plays through the silhouette,
    /// and each face's label is pinned onto its plane. Hit-testing is unchanged, so a tap on
    /// a bubble still snaps to that bubble's region.
    private func draw(_ ctx: inout GraphicsContext, size sz: CGSize) {
        let r = camera.viewRotation
        let center = CGPoint(x: sz.width / 2, y: sz.height / 2)
        let k = Float(min(sz.width, sz.height) / 2) * OrientationGizmo.cubeScreenScale

        func project(_ p: SIMD3<Float>) -> CGPoint {
            let v = r * p
            return CGPoint(x: center.x + CGFloat(v.x * k), y: center.y - CGFloat(v.y * k))
        }
        let lit = hovered ?? pressed

        let faces = Self.cubeFaces.map { face -> (face: CubeFace, nz: Float, depth: Float) in
            let nz = (r * face.normal).z
            let depth = face.corners.reduce(Float(0)) { $0 + (r * $1).z } / 4
            return (face, nz, depth)
        }
        let back = faces.filter { $0.nz < -0.02 }.sorted { $0.depth < $1.depth }
        let front = faces.filter { $0.nz > 0.02 }.sorted { $0.depth < $1.depth }

        // FAR SIDE — ghosted bubbles, seen THROUGH the translucent glass.
        for item in back {
            let path = facePath(item.face, project)
            ctx.fill(path, with: .color(.white.opacity(0.02)))
            drawFaceTiles(&ctx, face: item.face, depth: -item.nz, project: project,
                          lit: lit, front: false)
            ctx.stroke(path, with: .color(.white.opacity(0.06)), lineWidth: 0.75)
        }

        // NEAR-SIDE grout fills + the caustics that play through the whole silhouette.
        var silhouette = Path()
        for item in front {
            let path = facePath(item.face, project)
            silhouette.addPath(path)
            ctx.fill(path, with: .color(.white.opacity(0.05 + 0.04 * Double(item.nz))))
        }
        if !front.isEmpty {
            let bounds = silhouette.boundingRect
            ctx.drawLayer { layer in
                layer.opacity = 0.7
                layer.clip(to: silhouette)
                drawCaustics(&layer, bounds: bounds)
            }
        }

        // NEAR SIDE — per face, far→near so nearer faces overdraw: domed bubbles, the pinned
        // label on top, then a crisp facet edge.
        for item in front {
            drawFaceTiles(&ctx, face: item.face, depth: item.nz, project: project,
                          lit: lit, front: true)
            if item.nz > 0.34 {
                drawFaceLabel(&ctx, face: item.face, project: project, lit: isLit(item.face, lit))
            }
            ctx.stroke(facePath(item.face, project),
                       with: .color(.white.opacity(0.20)), lineWidth: 1)
        }
    }

    /// The projected quad of a cube face.
    private func facePath(_ face: CubeFace, _ project: (SIMD3<Float>) -> CGPoint) -> Path {
        var path = Path()
        for (i, c) in face.corners.enumerated() {
            let p = project(c)
            if i == 0 { path.move(to: p) } else { path.addLine(to: p) }
        }
        path.closeSubpath()
        return path
    }

    /// Specular bloom + chromatic-dispersion caustic, drawn into the (already-clipped)
    /// silhouette. The blue splash (item 3) lives here as a cool cast under the highlight.
    private func drawCaustics(_ ctx: inout GraphicsContext, bounds: CGRect) {
        guard bounds.width > 1, bounds.height > 1 else { return }

        // Cool accent wash from the top so the whole lens carries a splash of app-blue.
        ctx.fill(Path(bounds), with: .linearGradient(
            Gradient(colors: [DS.Color.accent.opacity(0.20).color, .clear]),
            startPoint: CGPoint(x: bounds.midX, y: bounds.minY),
            endPoint: CGPoint(x: bounds.midX, y: bounds.midY)))

        // Chromatic-dispersion band across the upper-middle — a soft blurred rainbow, like
        // the caustic that skips across Apple's Liquid-Glass lens.
        let bandH = bounds.height * 0.20
        let bandY = bounds.minY + bounds.height * 0.30
        let band = CGRect(x: bounds.minX - 6, y: bandY - bandH / 2,
                          width: bounds.width + 12, height: bandH)
        let rainbow = Gradient(stops: [
            .init(color: .clear, location: 0.0),
            .init(color: Color(red: 1.0, green: 0.30, blue: 0.42).opacity(0.55), location: 0.16),
            .init(color: Color(red: 1.0, green: 0.72, blue: 0.30).opacity(0.55), location: 0.34),
            .init(color: Color(red: 0.55, green: 1.0, blue: 0.55).opacity(0.55), location: 0.52),
            .init(color: Color(red: 0.35, green: 0.80, blue: 1.0).opacity(0.55), location: 0.70),
            .init(color: Color(red: 0.72, green: 0.50, blue: 1.0).opacity(0.55), location: 0.85),
            .init(color: .clear, location: 1.0),
        ])
        ctx.drawLayer { layer in
            layer.opacity = 0.85
            layer.addFilter(.blur(radius: bandH * 0.28))
            layer.fill(Capsule().path(in: band),
                       with: .linearGradient(rainbow,
                                             startPoint: CGPoint(x: band.minX, y: band.midY),
                                             endPoint: CGPoint(x: band.maxX, y: band.midY)))
        }

        // Specular highlight — a bright soft blob near the upper-left, the glass catching
        // the light.
        let hlR = min(bounds.width, bounds.height) * 0.42
        let hlC = CGPoint(x: bounds.minX + bounds.width * 0.32,
                          y: bounds.minY + bounds.height * 0.24)
        ctx.fill(Path(ellipseIn: CGRect(x: hlC.x - hlR, y: hlC.y - hlR,
                                        width: hlR * 2, height: hlR * 2)),
                 with: .radialGradient(
                    Gradient(colors: [Color.white.opacity(0.5), .clear]),
                    center: hlC, startRadius: 0, endRadius: hlR))
    }

    /// Pin `face`'s label ONTO its plane. Builds the exact affine that maps the label's
    /// local box onto the face's projected parallelogram using the face's in-plane
    /// right/up axes, so the text shears + rotates with the face and flips upside-down when
    /// the face's up-vector points down on screen. Auto-fits the face so no label truncates.
    private func drawFaceLabel(_ ctx: inout GraphicsContext, face: CubeFace,
                               project: (SIMD3<Float>) -> CGPoint, lit: Bool) {
        guard let label = face.label else { return }
        let text = Text(label.uppercased())
            .font(.system(size: 26, weight: .heavy, design: .rounded))
        let resolved = ctx.resolve(text)
        let ts = resolved.measure(in: CGSize(width: 1000, height: 1000))
        let halfW = ts.width / 2, halfH = ts.height / 2
        guard halfW > 0.5, halfH > 0.5 else { return }

        // Fill ~66% of the half-face width; keep the text's own aspect (no stretch).
        let extentX: Float = 0.66
        let extentY = extentX * Float(halfH / halfW)
        let c = project(face.center)
        let rp = project(face.center + face.right3 * extentX)
        let up = project(face.center + face.up3 * extentY)
        let rx = rp.x - c.x, ry = rp.y - c.y     // screen vector for the label's +x half-width
        let ux = up.x - c.x, uy = up.y - c.y     // screen vector for the label's +y (up) half-height

        // Local text coords are y-DOWN; +x → face-right, +y(down) → face-down (−up).
        let a = CGAffineTransform(a: rx / halfW, b: ry / halfW,
                                  c: -ux / halfH, d: -uy / halfH,
                                  tx: c.x, ty: c.y)
        // Reject a collapsed (edge-on) transform.
        guard abs(a.a * a.d - a.b * a.c) > 0.02 else { return }

        ctx.drawLayer { layer in
            layer.transform = a
            let shade = Text(label.uppercased())
                .font(.system(size: 26, weight: .heavy, design: .rounded))
                .foregroundColor(.black.opacity(0.35))
            layer.draw(layer.resolve(shade), at: CGPoint(x: 0, y: 0.06), anchor: .center)
            let ink = Text(label.uppercased())
                .font(.system(size: 26, weight: .heavy, design: .rounded))
                .foregroundColor(lit ? .white : Color.white.opacity(0.86))
            layer.draw(layer.resolve(ink), at: .zero, anchor: .center)
        }
    }

    /// Tile ONE cube face with the 9 domed bubbles that match its hit regions: the central
    /// bubble is the face, the 4 edge strips are the edges (each the full width of the edge
    /// between its corners), the 4 small squares are the corners. Cells follow `edgeBand`
    /// exactly (the central 70% is the face, the outer 30% splits into edges/corners), with
    /// a gap between them, so each bubble's footprint IS its clickable region.
    private func drawFaceTiles(_ ctx: inout GraphicsContext, face: CubeFace, depth: Float,
                               project: (SIMD3<Float>) -> CGPoint, lit: GizmoRegion?, front: Bool) {
        let s: Float = face.positive ? 1 : -1
        let a = (face.axis + 1) % 3, b = (face.axis + 2) % 3
        let t: Float = 1 - OrientationGizmo.edgeBand     // 0.7 — face/edge boundary
        let gap: Float = 0.06                             // space between bubbles
        let pad: Float = 0.03                             // margin from the cube edge
        func seg(_ i: Int) -> (Float, Float) {
            switch i {
            case -1: return (-1 + pad, -t - gap)
            case 1:  return (t + gap, 1 - pad)
            default: return (-t + gap, t - gap)
            }
        }
        func corner(_ u: Float, _ v: Float) -> SIMD3<Float> {
            var p = SIMD3<Float>(0, 0, 0); p[face.axis] = s; p[a] = u; p[b] = v; return p
        }
        for iu in [-1, 0, 1] {
            for iv in [-1, 0, 1] {
                let (u0, u1) = seg(iu), (v0, v1) = seg(iv)
                let pts = [project(corner(u0, v0)), project(corner(u1, v0)),
                           project(corner(u1, v1)), project(corner(u0, v1))]
                var anchor = SIMD3<Float>(0, 0, 0)
                anchor[face.axis] = s; anchor[a] = Float(iu); anchor[b] = Float(iv)
                drawTile(&ctx, corners: pts, on: lit?.anchor == anchor, front: front, depth: depth)
            }
        }
    }

    /// One fat domed bubble filling a face cell: a curved body (radial gradient pulled to the
    /// upper-left so it reads as a raised dome), a wet specular pip, and a rim. Translucent so
    /// the far side reads through it; app-blue when its region is hovered/tapped.
    private func drawTile(_ ctx: inout GraphicsContext, corners: [CGPoint],
                          on: Bool, front: Bool, depth: Float) {
        guard corners.count == 4 else { return }
        let path = roundedQuad(corners, radiusFrac: 0.30)
        let bb = path.boundingRect
        guard bb.width > 1.5, bb.height > 1.5 else { return }
        let cen = CGPoint(x: (corners[0].x + corners[1].x + corners[2].x + corners[3].x) / 4,
                          y: (corners[0].y + corners[1].y + corners[2].y + corners[3].y) / 4)
        let dim = max(bb.width, bb.height)
        // Light gathers up-left → a fat dome; endRadius < the cell so the rim falls into shade.
        let hot = CGPoint(x: cen.x - bb.width * 0.20, y: cen.y - bb.height * 0.22)

        let body: Gradient
        if on {
            body = Gradient(colors: [.white.opacity(0.97),
                                     DS.Color.accent.opacity(0.92).color,
                                     DS.Color.accent.opacity(front ? 0.55 : 0.28).color])
        } else if front {
            let hi = 0.40 + 0.16 * Double(depth)         // fatter, brighter dome up top
            body = Gradient(colors: [.white.opacity(hi),
                                     .white.opacity(0.15),
                                     .white.opacity(0.05)])
        } else {
            body = Gradient(colors: [.white.opacity(0.11), .white.opacity(0.03), .clear])
        }
        ctx.fill(path, with: .radialGradient(body, center: hot,
                                             startRadius: 0, endRadius: dim * 0.70))

        if front || on {
            // A SOFT glint (radial fade), not a hard dot — reads as light on the dome.
            let pipR = dim * 0.20
            ctx.fill(Path(ellipseIn: CGRect(x: hot.x - pipR, y: hot.y - pipR,
                                            width: pipR * 2, height: pipR * 2)),
                     with: .radialGradient(
                        Gradient(colors: [.white.opacity(on ? 0.85 : 0.5), .clear]),
                        center: hot, startRadius: 0, endRadius: pipR))
        }
        let rim: Color = on ? .white.opacity(0.95)
            : (front ? DS.Color.accent.opacity(0.30 + 0.25 * Double(depth)).color
                     : .white.opacity(0.06))
        ctx.stroke(path, with: .color(rim), lineWidth: on ? 1.8 : (front ? 1.0 : 0.6))
    }

    /// A convex quad with rounded corners — each corner cut `radiusFrac` of the way along its
    /// two edges and bridged with a quad curve through the original vertex. Gives the domed
    /// bubbles their soft squircle silhouette on any projected (sheared) cell.
    private func roundedQuad(_ p: [CGPoint], radiusFrac: CGFloat) -> Path {
        var path = Path()
        let n = p.count
        let f = min(0.5, radiusFrac)
        func lerp(_ A: CGPoint, _ B: CGPoint, _ t: CGFloat) -> CGPoint {
            CGPoint(x: A.x + (B.x - A.x) * t, y: A.y + (B.y - A.y) * t)
        }
        for i in 0..<n {
            let cur = p[i], prev = p[(i + n - 1) % n], next = p[(i + 1) % n]
            let inPt = lerp(cur, prev, f)
            let outPt = lerp(cur, next, f)
            if i == 0 { path.move(to: inPt) } else { path.addLine(to: inPt) }
            path.addQuadCurve(to: outPt, control: cur)
        }
        path.closeSubpath()
        return path
    }

    /// Whether `face` should highlight: its own face is the lit region, or the lit edge/
    /// corner touches it (its anchor is +/- on the face's axis).
    private func isLit(_ face: CubeFace, _ lit: GizmoRegion?) -> Bool {
        guard let h = lit else { return false }
        return h.anchor[face.axis] == (face.positive ? 1 : -1)
    }

    // MARK: - Home (now INSIDE the holder, top-left corner)

    private var homeButton: some View {
        Button { camera.home(animated: true) } label: {
            Image(systemName: "house.fill")
                .font(.system(size: homeSide * 0.42, weight: .semibold))
                .foregroundStyle(DS.Color.textPrimary.color)
                .frame(width: homeSide, height: homeSide)
                .background(bubbleChrome(radius: DS.Radius.control))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Home view")
        .accessibilityHint("Return the camera to the default angle")
    }

    /// A small glass chrome for the home button — clear like the cube, blue-rimmed.
    private func bubbleChrome(radius: CGFloat) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        return shape.fill(.ultraThinMaterial)
            .overlay(shape.fill(Color.white.opacity(0.10)))
            .overlay(shape.strokeBorder(DS.Color.accent.opacity(0.45).color, lineWidth: 1))
    }

    // MARK: - Holder (the FROSTED case — more diffuse than the clear cube)

    private var holder: some View {
        let shape = RoundedRectangle(cornerRadius: holderRadius, style: .continuous)
        return shape.fill(.ultraThinMaterial)                     // real backdrop blur
            .overlay(shape.fill(DS.Surface.bar.opacity(0.52).color))  // frosted diffuse tint
            .overlay(Canvas { ctx, sz in drawHolderCaustics(&ctx, sz) })  // light in the case
            .overlay(                                             // top-edge sheen
                shape.strokeBorder(
                    LinearGradient(colors: [Color.white.opacity(0.28), Color.white.opacity(0.04)],
                                   startPoint: .top, endPoint: .bottom),
                    lineWidth: 1))
            .overlay(shape.strokeBorder(DS.Color.accent.opacity(0.18).color, lineWidth: 1.5)
                        .blur(radius: 1.5))                        // faint blue edge glow
            .clipShape(shape)
            .compositingGroup()
            .modifier(HolderGlass(radius: holderRadius))           // iOS/macOS 26 Liquid Glass
            .dsShadow(.panel)
    }

    /// Frosted-case caustics — broad diffuse light pools (softer + larger than the cube's
    /// crisp lens), with a cool accent corner, so the case has its own interesting light.
    private func drawHolderCaustics(_ ctx: inout GraphicsContext, _ sz: CGSize) {
        ctx.drawLayer { layer in
            layer.addFilter(.blur(radius: sz.width * 0.06))
            drawPool(&layer, sz, 0.24, 0.16, 0.42, .white.opacity(0.14))
            drawPool(&layer, sz, 0.82, 0.30, 0.40, DS.Color.accent.opacity(0.16).color)
            drawPool(&layer, sz, 0.68, 0.86, 0.50, .white.opacity(0.06))
        }
    }

    private func drawPool(_ ctx: inout GraphicsContext, _ sz: CGSize,
                          _ cx: CGFloat, _ cy: CGFloat, _ rf: CGFloat, _ color: Color) {
        let rad = min(sz.width, sz.height) * rf
        let c = CGPoint(x: sz.width * cx, y: sz.height * cy)
        ctx.fill(Path(ellipseIn: CGRect(x: c.x - rad, y: c.y - rad, width: rad * 2, height: rad * 2)),
                 with: .radialGradient(Gradient(colors: [color, .clear]),
                                       center: c, startRadius: 0, endRadius: rad))
    }

    // MARK: - Cube geometry (drawing only; the clickable regions live in OrientationGizmo)

    fileprivate struct CubeFace {
        let corners: [SIMD3<Float>]   // 4, wound consistently
        let normal: SIMD3<Float>
        let center: SIMD3<Float>
        let label: String?
        let axis: Int                 // 0=X, 1=Y, 2=Z
        let positive: Bool
        /// In-plane model axes the label is pinned to: +right and +up on the face.
        let right3: SIMD3<Float>
        let up3: SIMD3<Float>
    }

    private static let cubeFaces: [CubeFace] = {
        func v(_ x: Float, _ y: Float, _ z: Float) -> SIMD3<Float> { SIMD3<Float>(x, y, z) }
        // Conventional ViewCube label frames: sides read upright with +Y up; the poles read
        // along +X with their top toward the back (Top) / front (Bottom).
        func face(_ axis: Int, _ positive: Bool, _ label: String,
                  right: SIMD3<Float>, up: SIMD3<Float>) -> CubeFace {
            let s: Float = positive ? 1 : -1
            var normal = SIMD3<Float>(0, 0, 0); normal[axis] = s
            let a = (axis + 1) % 3, b = (axis + 2) % 3
            func corner(_ ia: Float, _ ib: Float) -> SIMD3<Float> {
                var p = SIMD3<Float>(0, 0, 0); p[axis] = s; p[a] = ia; p[b] = ib; return p
            }
            let corners = [corner(-1, -1), corner(1, -1), corner(1, 1), corner(-1, 1)]
            return CubeFace(corners: corners, normal: normal, center: normal,
                            label: label, axis: axis, positive: positive, right3: right, up3: up)
        }
        return [
            face(2, true,  "Front", right: v(1, 0, 0),  up: v(0, 1, 0)),
            face(2, false, "Back",  right: v(-1, 0, 0), up: v(0, 1, 0)),
            face(0, true,  "Right", right: v(0, 0, -1), up: v(0, 1, 0)),
            face(0, false, "Left",  right: v(0, 0, 1),  up: v(0, 1, 0)),
            face(1, true,  "Top",   right: v(1, 0, 0),  up: v(0, 0, -1)),
            face(1, false, "Bottom",right: v(1, 0, 0),  up: v(0, 0, 1)),
        ]
    }()
}

/// iOS/macOS 26 Liquid-Glass progressive enhancement for the frosted holder. On earlier OS
/// the holder falls back to its `Material` + Canvas frosting (below), so the look is
/// coherent everywhere; on 26+ the case gets the genuine system glass under that frosting.
private struct HolderGlass: ViewModifier {
    let radius: CGFloat
    func body(content: Content) -> some View {
        if #available(iOS 26.0, macOS 26.0, *) {
            content.glassEffect(.regular,
                                in: RoundedRectangle(cornerRadius: radius, style: .continuous))
        } else {
            content
        }
    }
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
