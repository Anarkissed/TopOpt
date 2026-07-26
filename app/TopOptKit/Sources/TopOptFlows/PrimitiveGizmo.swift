// PrimitiveGizmo.swift — the transform gizmo's PURE math (DEFECT 2).
//
// PR 190 shipped hand-placed clearance primitives but nothing to grab them by: the
// magnetic detents were unreachable because there were no handles. This is the math
// behind those handles — a Shapr3D-style transform gizmo AFFORDANCE SET expressed in
// TopOpt's own terms:
//   • translate along ONE axis          (`Handle.axis`)
//   • translate in a PLANE (two axes)    (`Handle.plane`)
//   • translate FREELY (all three)       (`Handle.free`, camera-facing plane)
//   • ROTATE about an axis               (`Handle.rotate`)
//   • COPY                               (a model op — `ProjectModel.copyManualPrimitive`)
//
// BLOCKED-STOP check (rotation vs the PR-190 clearance schema): a bolt carries
// axis_point/axis_dir/radius/half_length; a face carries origin/normal/half_u/half_w.
// Rotation is expressed ENTIRELY by rotating the DIRECTION VECTOR (`ManualPrimitive.axis`
// = a bolt's axis_dir / a face's normal) about the pivot — no schema field is missing:
//   • a bolt is rotationally symmetric about its own axis, so its full orientation IS
//     its axis_dir → rotating that vector covers every bolt rotation;
//   • a face's plane is fully defined by its normal + origin; the in-plane (u,v) basis is
//     DERIVED from the normal (`planeBasis`), so rotating the normal covers every face
//     rotation EXCEPT a spin about the normal itself — and that spin is a NO-OP for the
//     square manual slab (halfU == halfW by construction), so it changes no geometry and
//     needs no stored orientation. Hence NO field was added to the schema.
//
// Everything here is a pure value type on simd Doubles (model-space; the same frame the
// primitive, the mesh and the run share) — no SwiftUI, no GPU, no camera. The gesture
// that turns a touch into a model-space ray, and the Metal/SwiftUI knobs, are the
// device-QA'd layers (the /app/ rule; G8 device-real evidence is the maintainer's step).

import Foundation
import simd

public enum PrimitiveGizmo {

    // ─────────────────────────────────────────────────────────────────────────
    // MARK: - The grabbed affordance

    /// Which gizmo handle the user grabbed. Directions are UNIT model-space vectors.
    public enum Handle: Equatable, Sendable {
        /// Translate along a single axis line (the arrow shafts). Constrains motion to
        /// this one direction.
        case axis(SIMD3<Double>)
        /// Translate in the plane whose normal is this (the corner quads) — two axes at once.
        case plane(SIMD3<Double>)
        /// Translate freely in the camera-facing plane (the centre knob) — all three axes.
        case free
        /// Rotate the primitive's orientation about this axis, through the pivot (the rings).
        case rotate(SIMD3<Double>)
    }

    /// A drag ray in the SAME frame as the primitive (model space): a point + unit dir.
    public struct Ray: Equatable, Sendable {
        public var origin: SIMD3<Double>
        public var dir: SIMD3<Double>
        public init(origin: SIMD3<Double>, dir: SIMD3<Double>) {
            self.origin = origin
            self.dir = PrimitiveGizmo.unit(dir)
        }
    }

    static func unit(_ v: SIMD3<Double>) -> SIMD3<Double> {
        let l = simd_length(v)
        return l > 1e-12 ? v / l : SIMD3<Double>(0, 0, 1)
    }

    // ─────────────────────────────────────────────────────────────────────────
    // MARK: - Ray primitives (pure)

    /// The intersection of `ray` with the plane through `planePoint` with unit `planeNormal`.
    /// Nil when the ray is parallel to the plane (grazing / behind).
    public static func rayPlaneHit(_ ray: Ray, planePoint: SIMD3<Double>,
                                   planeNormal: SIMD3<Double>) -> SIMD3<Double>? {
        let n = unit(planeNormal)
        let denom = simd_dot(ray.dir, n)
        guard abs(denom) > 1e-9 else { return nil }
        let t = simd_dot(planePoint - ray.origin, n) / denom
        return ray.origin + ray.dir * t
    }

    /// The point on the axis LINE (through `linePoint`, unit `axisDir`) closest to `ray`,
    /// returned as the signed parameter (mm) along `axisDir`. Robust to the parallel case
    /// (falls back to the foot of the ray origin). This is the Double sibling of
    /// `ClearanceDragMath.closestAxisParam`, in the gizmo's own frame.
    public static func axisParam(_ ray: Ray, linePoint: SIMD3<Double>,
                                 axisDir: SIMD3<Double>) -> Double? {
        let v = unit(axisDir)
        let u = ray.dir
        let w0 = ray.origin - linePoint
        let b = simd_dot(u, v)
        let d = simd_dot(u, w0)
        let e = simd_dot(v, w0)
        let denom = 1 - b * b                 // u, v both unit
        if denom < 1e-9 { return e }          // parallel: foot of the ray origin on the line
        return (e - b * d) / denom
    }

    /// Rotate `v` about the unit `axis` by `radians` (right-handed). A no-op when the axis
    /// is degenerate. Used to turn a primitive's direction vector — the ENTIRETY of a bolt's
    /// orientation and a face's plane normal (see the file header's schema note).
    public static func rotate(_ v: SIMD3<Double>, about axis: SIMD3<Double>,
                              radians: Double) -> SIMD3<Double> {
        let k = unit(axis)
        let q = simd_quatd(angle: radians, axis: k)
        return q.act(v)
    }

    /// The signed angle (radians, right-handed about `axis`) that turns direction
    /// `pivot → from` into `pivot → to`, measured in the plane ⟂ `axis` through `pivot`.
    /// Nil when either arm collapses onto the axis (no well-defined angle).
    public static func ringAngle(from: SIMD3<Double>, to: SIMD3<Double>,
                                 about axis: SIMD3<Double>, pivot: SIMD3<Double>) -> Double? {
        let k = unit(axis)
        // Project both arms into the plane ⟂ k.
        let a = (from - pivot) - k * simd_dot(from - pivot, k)
        let b = (to - pivot) - k * simd_dot(to - pivot, k)
        let la = simd_length(a), lb = simd_length(b)
        guard la > 1e-9, lb > 1e-9 else { return nil }
        let an = a / la, bn = b / lb
        let cosT = simd_clamp(simd_dot(an, bn), -1, 1)
        let sinT = simd_dot(k, simd_cross(an, bn))     // signed by the right-hand rule
        return atan2(sinT, cosT)
    }

    // ─────────────────────────────────────────────────────────────────────────
    // MARK: - The drag (grab context → transformed primitive)

    /// Everything captured at the instant a handle is grabbed, so each subsequent drag
    /// frame resolves to a stable transform (no jump: the grab offset is preserved). All
    /// in MODEL space. `viewDir` (unit, pointing INTO the scene) is only read by `.free`.
    public struct Drag: Equatable, Sendable {
        public let handle: Handle
        public let startCenter: SIMD3<Double>
        public let startAxis: SIMD3<Double>
        public let grab: Ray
        public let viewDir: SIMD3<Double>

        public init(handle: Handle, startCenter: SIMD3<Double>, startAxis: SIMD3<Double>,
                    grab: Ray, viewDir: SIMD3<Double> = SIMD3<Double>(0, 0, -1)) {
            self.handle = handle
            self.startCenter = startCenter
            self.startAxis = PrimitiveGizmo.unit(startAxis)
            self.grab = grab
            self.viewDir = PrimitiveGizmo.unit(viewDir)
        }

        /// The (center, axis) this drag resolves to for `currentRay`. Translate handles
        /// move the CENTRE (axis fixed); the rotate handle turns the AXIS about the handle
        /// axis through `startCenter` (centre fixed). Any degenerate/parallel geometry
        /// leaves the primitive where it was (a safe no-op — the finger keeps control).
        public func resolve(currentRay: Ray) -> (center: SIMD3<Double>, axis: SIMD3<Double>) {
            switch handle {
            case let .axis(a):
                let dir = PrimitiveGizmo.unit(a)
                guard let s0 = PrimitiveGizmo.axisParam(grab, linePoint: startCenter, axisDir: dir),
                      let s = PrimitiveGizmo.axisParam(currentRay, linePoint: startCenter, axisDir: dir)
                else { return (startCenter, startAxis) }
                return (startCenter + dir * (s - s0), startAxis)

            case let .plane(n):
                return translateOnPlane(normal: n, currentRay: currentRay)

            case .free:
                // The camera-facing plane through the primitive — drag it anywhere on screen.
                return translateOnPlane(normal: viewDir, currentRay: currentRay)

            case let .rotate(k):
                let axis = PrimitiveGizmo.unit(k)
                guard let hit0 = PrimitiveGizmo.rayPlaneHit(grab, planePoint: startCenter, planeNormal: axis),
                      let hit = PrimitiveGizmo.rayPlaneHit(currentRay, planePoint: startCenter, planeNormal: axis),
                      let theta = PrimitiveGizmo.ringAngle(from: hit0, to: hit, about: axis, pivot: startCenter)
                else { return (startCenter, startAxis) }
                return (startCenter, PrimitiveGizmo.rotate(startAxis, about: axis, radians: theta))
            }
        }

        private func translateOnPlane(normal n: SIMD3<Double>,
                                      currentRay: Ray) -> (center: SIMD3<Double>, axis: SIMD3<Double>) {
            guard let hit0 = PrimitiveGizmo.rayPlaneHit(grab, planePoint: startCenter, planeNormal: n),
                  let hit = PrimitiveGizmo.rayPlaneHit(currentRay, planePoint: startCenter, planeNormal: n)
            else { return (startCenter, startAxis) }
            return (startCenter + (hit - hit0), startAxis)
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // MARK: - Handle layout (pure model-space anchors the overlay projects)

    /// The model-space anchor points for the gizmo's knobs about a primitive centred at
    /// `center`, scaled by `length` (model mm) so the gizmo tracks the primitive's size.
    /// Kept pure + tested so the overlay is a thin projection of these — the knob geometry
    /// can't silently drift from the drag math's world axes.
    public struct Anchors: Equatable, Sendable {
        public let center: SIMD3<Double>
        /// Translate-along-axis arrow tips (world +X, +Y, +Z), each with its unit axis.
        public let axisTips: [(axis: SIMD3<Double>, at: SIMD3<Double>)]
        /// Translate-in-plane quads (XY, YZ, ZX), each with the plane's unit normal.
        public let planeHandles: [(normal: SIMD3<Double>, at: SIMD3<Double>)]
        /// Rotate-about-axis rings (about +X, +Y, +Z), each with its unit axis.
        public let rotateHandles: [(axis: SIMD3<Double>, at: SIMD3<Double>)]

        public static func == (l: Anchors, r: Anchors) -> Bool {
            l.center == r.center
            && l.axisTips.map(\.at) == r.axisTips.map(\.at)
            && l.planeHandles.map(\.at) == r.planeHandles.map(\.at)
            && l.rotateHandles.map(\.at) == r.rotateHandles.map(\.at)
        }
    }

    public static func anchors(center: SIMD3<Double>, length: Double) -> Anchors {
        let L = Swift.max(length, 1)
        let X = SIMD3<Double>(1, 0, 0), Y = SIMD3<Double>(0, 1, 0), Z = SIMD3<Double>(0, 0, 1)
        let axisTips = [(X, center + X * L), (Y, center + Y * L), (Z, center + Z * L)]
        // Plane quads sit partway out along the two in-plane axes; normal is the third axis.
        let p = L * 0.45
        let planeHandles = [(Z, center + (X + Y) * p),   // XY plane
                            (X, center + (Y + Z) * p),   // YZ plane
                            (Y, center + (Z + X) * p)]   // ZX plane
        // Rotate rings sit on a slightly larger radius in the plane ⟂ their axis so they
        // read as arcs, not translate quads.
        let r = L * 0.8
        let rotateHandles = [(X, center + (Y + Z) * (r * 0.5)),
                             (Y, center + (Z + X) * (r * 0.5)),
                             (Z, center + (X + Y) * (r * 0.5))]
        return Anchors(center: center, axisTips: axisTips,
                       planeHandles: planeHandles, rotateHandles: rotateHandles)
    }
}
