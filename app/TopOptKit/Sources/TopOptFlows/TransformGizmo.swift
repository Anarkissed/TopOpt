// TransformGizmo.swift — the pure geometry + hit-testing behind the 3D liquid-glass
// TRANSFORM gizmo (redesign 2026-07-26, take 2).
//
// PR 195 shipped a scatter of floating chips; take 1 replaced them with a flat 2D SwiftUI
// path — which the maintainer rejected too: it read as "2D rectangles squashed together",
// grew lines/holes at the seams, and LOST HALF OF ITSELF at some angles because a flat
// projection has no depth. The verdict: it must be a genuine 3D object with depth and
// see-through, from the SAME set as the existing Position (orientation) gizmo — which is a
// raymarched liquid-glass SDF.
//
// So this gizmo is now built the SAME way as `OrientationGizmo`: ONE set of geometry
// constants drives BOTH the raymarched Metal render (`TransformGizmoMetal`) and this CPU
// hit-test, so the drawn glass and the grabbable geometry can't diverge. The shape is the
// classic transform manipulator, TRANSLATE-ONLY (no rotation rings/arcs):
//   • a centre HUB sphere (free move — the camera-facing plane);
//   • three thick AXIS ARMS (shaft + solid conical arrowhead) along model +X/+Y/+Z
//     (single-axis translate);
//   • three quarter-circle ARCS welded between adjacent arms (the two-axis plane handles —
//     the "arcs connecting the arrows" the reference shows).
//
// The render (`TransformGizmoMetal`) raymarches the same shape in its own small virtual
// camera and floats it at the primitive's projected centre, rotated by the live view — so
// it has real front/back depth, translucency and a lit rim exactly like the orientation
// cube, and never collapses at an angle.
//
// This math is pure (no SwiftUI/Metal) and headlessly testable; the drag itself still runs
// through the untouched `PrimitiveGizmo` + `ProjectModel.moveManualPrimitive` (only which
// handle you grabbed now comes from `pick` here). The gesture/Metal are the device-QA layers.

import Foundation
import simd
#if canImport(CoreGraphics)
import CoreGraphics
#endif

public enum TransformGizmo {

    // MARK: - The ONE geometry (object space; both render + pick read this)

    /// Object-space geometry of the manipulator (a unit-ish gizmo — everything fits within a
    /// radius ≈ 1.1 of the origin). The Metal SDF and this picker read the SAME numbers.
    public struct Constants: Equatable, Sendable {
        // Proportions trace the reference SVG (docs/design/Transform Gizmo.html): thin
        // straight arms (stroke ≈ 0.057 of the arm length), sharp flat arrowheads (base ≈
        // 0.16 wide, ≈ 0.34 long), a small centre hub — clean and professional, NOT bubbly.

        /// Centre hub sphere radius (the free-move handle).
        public var hubR: Float = 0.135
        /// Axis shaft (arm) radius — SLENDER (thin, precise, professional).
        public var armR: Float = 0.036
        /// Where the shaft ends and the arrowhead begins (along the axis).
        public var shaftEnd: Float = 0.70
        /// The arrowhead tip (along the axis).
        public var tip: Float = 1.0
        /// Arrowhead base radius (its widest point, at `shaftEnd`) — a slim crisp cone.
        public var headR: Float = 0.105
        /// Radius of the quarter-arc that connects two adjacent arms.
        public var arcR: Float = 0.52
        /// In-plane half-width of the connecting arcs. The arcs are FLATTENED ribbons/plates
        /// (thin out-of-plane, see the shader's squash) so they read as plane handles, clearly
        /// distinct from the round axis shafts.
        public var arcTube: Float = 0.05
        /// Weld softness between the unioned parts — TINY, so the arms/arrowheads read as
        /// crisp straight geometry, not melted blobs.
        public var weld: Float = 0.01

        /// Virtual camera the render + pick share (matches the shader's projection).
        public var fov: Float = 36          // vertical FOV (degrees)
        public var camZ: Float = 4.05       // camera distance on +Z

        public init() {}
        public static let standard = Constants()
    }

    /// What a tap resolved to — a translate handle, or nil (missed the glass).
    public enum Hit: Equatable, Sendable {
        /// Single-axis translate along model axis `axis` (0 = X, 1 = Y, 2 = Z).
        case axis(Int)
        /// Two-axis translate in a principal plane (0 = XY→normal Z, 1 = YZ→normal X,
        /// 2 = ZX→normal Y) — the same (pair → normal) mapping as `PrimitiveGizmo`.
        case plane(Int)
        /// Free translate (the centre hub) — the camera-facing plane.
        case free
    }

    /// Unit model axes, indexed 0/1/2 = X/Y/Z.
    public static let axisVectors: [SIMD3<Double>] = [
        SIMD3(1, 0, 0), SIMD3(0, 1, 0), SIMD3(0, 0, 1),
    ]
    /// Plane-handle normals, indexed the same as `Hit.plane` (0 = Z, 1 = X, 2 = Y).
    public static let planeNormals: [SIMD3<Double>] = [
        SIMD3(0, 0, 1), SIMD3(1, 0, 0), SIMD3(0, 1, 0),
    ]

    #if canImport(CoreGraphics)
    // MARK: - Hit-testing (analytic ray vs the SAME parts the SDF draws)

    /// Resolve a tap inside the gizmo's square overlay to a translate handle, or nil on a
    /// miss. `point` is in the overlay's coordinates (top-left origin, y down); `size` is the
    /// overlay box; `rotation` is the object→view rotation the render uses (so the pick lands
    /// where the glass is drawn). Depth-correct: the nearest hit along the ray wins, so a
    /// front arm is picked over a back arm.
    public static func pick(point: CGPoint, in size: CGSize, rotation: simd_float3x3,
                            c: Constants = .standard) -> Hit? {
        guard size.width > 0, size.height > 0 else { return nil }
        let ux = Float((point.x / size.width) * 2 - 1)
        let uy = Float(1 - (point.y / size.height) * 2)      // flip to y-up
        let tf = tanf(c.fov * 0.5 * .pi / 180)
        // Ray in the virtual camera (view) space, then into object space via Rᵀ.
        let rt = rotation.transpose
        let ro = rt * SIMD3<Float>(0, 0, c.camZ)
        let rd = simd_normalize(rt * simd_normalize(SIMD3<Float>(ux * tf, uy * tf, -1)))

        // HUB PRIORITY: a tap whose ray passes through the centre is free-move. This also
        // absorbs the axis that happens to point straight at the camera (its arrowhead
        // projects onto the centre and is un-grabbable as an axis from that view) — so the
        // dead-centre is reliably free, never a stray axis/plane behind it.
        let tCentre = -simd_dot(ro, rd)
        if tCentre > 0, simd_length(ro + rd * tCentre) < c.hubR { return .free }

        var best = Float.greatestFiniteMagnitude
        var hit: Hit? = nil
        func consider(_ t: Float?, _ h: Hit) {
            guard let t, t > 0, t < best else { return }
            best = t; hit = h
        }

        // Arms (axis) — a capsule from the hub out to the arrowhead tip, radius widened toward
        // the head so the arrowhead is easy to grab.
        for i in 0..<3 {
            let e = SIMD3<Float>(Float(i == 0 ? 1 : 0), Float(i == 1 ? 1 : 0), Float(i == 2 ? 1 : 0))
            let t = raySegment(ro, rd, a: e * (c.hubR * 0.5), b: e * c.tip,
                               r: Swift.max(c.armR, c.headR * 0.72))
            consider(t, .axis(i))
        }

        // Arcs (plane) — sample only the MIDDLE of each quarter-arc (its diagonal bulge), NOT
        // the ends: the arc endpoints sit on the axes atop the arm shafts, so testing them
        // would steal shaft taps for the plane handle. You grab a plane by its diagonal.
        for pl in 0..<3 {
            var t: Float? = nil
            let steps = 6
            var prev = arcPoint(plane: pl, s: 0.20, c: c)
            for k in 1...steps {
                let s = 0.20 + 0.60 * Float(k) / Float(steps)
                let cur = arcPoint(plane: pl, s: s, c: c)
                if let seg = raySegment(ro, rd, a: prev, b: cur, r: c.arcTube + 0.045) {
                    if t == nil || seg < t! { t = seg }
                }
                prev = cur
            }
            consider(t, .plane(pl))
        }

        // Hub as a normal (lowest-priority) candidate too, so a tap on the hub surface that
        // isn't dead-centre still reads as free when it's the nearest thing.
        consider(raySphere(ro, rd, r: c.hubR + c.armR * 0.5), .free)
        return hit
    }

    /// A point on plane `pl`'s quarter-arc at parameter `s` ∈ [0, 1] (0 at the first axis,
    /// 1 at the second). Mirrors the shader's `sdTorusQ` placement.
    private static func arcPoint(plane pl: Int, s: Float, c: Constants) -> SIMD3<Float> {
        let a = s * (.pi / 2), ca = cosf(a) * c.arcR, sa = sinf(a) * c.arcR
        switch pl {
        case 0:  return SIMD3(ca, sa, 0)        // XY: +X → +Y
        case 1:  return SIMD3(0, ca, sa)        // YZ: +Y → +Z
        default: return SIMD3(sa, 0, ca)        // ZX: +Z → +X
        }
    }

    /// Ray/sphere-at-origin: nearest positive entry parameter, or nil.
    private static func raySphere(_ ro: SIMD3<Float>, _ rd: SIMD3<Float>, r: Float) -> Float? {
        let b = simd_dot(ro, rd)
        let cc = simd_dot(ro, ro) - r * r
        let disc = b * b - cc
        guard disc >= 0 else { return nil }
        let t = -b - sqrtf(disc)
        return t > 0 ? t : nil
    }

    /// Ray vs a capsule (segment `a`→`b`, radius `r`): if the ray passes within `r` of the
    /// segment, return the ray parameter at closest approach (an approximate entry t good
    /// enough for depth-ordered picking); else nil. Standard closest-point-between-two-lines
    /// with the segment clamped to [0, 1] and the ray to t ≥ 0.
    private static func raySegment(_ ro: SIMD3<Float>, _ rd: SIMD3<Float>,
                                   a: SIMD3<Float>, b: SIMD3<Float>, r: Float) -> Float? {
        let d2 = b - a
        let rr = ro - a
        let aa = simd_dot(rd, rd)          // 1 (rd unit)
        let bb = simd_dot(rd, d2)
        let cc = simd_dot(d2, d2)
        let dd = simd_dot(rd, rr)
        let ee = simd_dot(d2, rr)
        let denom = aa * cc - bb * bb
        if abs(denom) < 1e-7 {
            // Ray parallel/COLLINEAR with the segment: the general solution is degenerate.
            // Pick whichever endpoint is nearest the camera in front of it (a collinear ray
            // should hit the segment's near end, e.g. an arrow's tip — not its root).
            let ta = simd_dot(a - ro, rd), tb = simd_dot(b - ro, rd)
            var t = Float.greatestFiniteMagnitude
            var pt = a
            if ta > 0, ta < t { t = ta; pt = a }
            if tb > 0, tb < t { t = tb; pt = b }
            guard t < .greatestFiniteMagnitude else { return nil }
            return simd_length((ro + rd * t) - pt) <= r ? t : nil
        }
        let s = Swift.min(Swift.max((aa * ee - bb * dd) / denom, 0), 1)
        // Foot of the segment point (a + s·d2) on the ray.
        let t = simd_dot((a + d2 * s) - ro, rd) / aa
        guard t > 0 else { return nil }
        let closestOnRay = ro + rd * t
        let closestOnSeg = a + d2 * s
        return simd_length(closestOnRay - closestOnSeg) <= r ? t : nil
    }
    #endif
}
