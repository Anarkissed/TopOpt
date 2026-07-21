// OrbitCamera.swift — the M7.4 viewer's orbit + pinch-zoom camera.
//
// A turntable camera: it looks at a fixed `target` (the model centre) from a point
// on a sphere of radius `distance`, parameterized by `azimuth` (yaw) and
// `elevation` (pitch). Dragging orbits (design hint "Drag to orbit"); pinch /
// scroll scales `distance` (hint "pinch or scroll to zoom"). The matrices are
// right-handed with a Metal [0,1] clip-z depth range.
//
// This is pure simd value-type math with no MTKView/GPU dependency, so the camera
// behaviour (framing, orbit clamping, zoom clamping, the view/projection matrices)
// is unit-tested headlessly; MetalMeshView drives an instance from gestures.

import Foundation
import CoreGraphics
import simd

/// A snapshot of the viewer camera's world→clip transform plus the on-screen
/// viewport, so SwiftUI overlays can position themselves at 3D points (M7.6 D3–D6:
/// the Anchor|Load chip, snap row, weight pill and force arrows float beside the
/// selection). `MetalMeshView` publishes one of these each time the camera orbits
/// or zooms; overlays call `project` to turn a world point into a view-space point.
///
/// Pure value-type math (no MetalKit), so `project` is unit-tested headlessly (the
/// M7 /app/ standard). `viewportSize` is in SwiftUI points (the MTKView's bounds),
/// and the returned point is in the same top-left-origin, y-down space SwiftUI
/// lays out in.
public struct CameraProjection: Equatable, Sendable {
    /// projection · view (world → Metal clip space).
    public let viewProjection: simd_float4x4
    /// The on-screen size of the stage, in points.
    public let viewportSize: CGSize

    public init(viewProjection: simd_float4x4, viewportSize: CGSize) {
        self.viewProjection = viewProjection
        self.viewportSize = viewportSize
    }

    /// Build from an `OrbitCamera` and the viewport (points), matching exactly what
    /// the renderer uses to draw (aspect from the viewport).
    public init(camera: OrbitCamera, viewportSize: CGSize) {
        let aspect = viewportSize.height > 0 ? Float(viewportSize.width / viewportSize.height) : 1
        self.viewProjection = camera.projectionMatrix(aspect: aspect) * camera.viewMatrix()
        self.viewportSize = viewportSize
    }

    /// Whether the viewport has a drawable area.
    public var isUsable: Bool { viewportSize.width > 0 && viewportSize.height > 0 }

    /// Project a world point to a view-space point (points, top-left origin, y down).
    /// Returns nil when the point is behind the camera (`w <= 0`) or the viewport is
    /// degenerate.
    public func project(_ world: SIMD3<Float>) -> CGPoint? {
        guard isUsable else { return nil }
        let clip = viewProjection * SIMD4<Float>(world, 1)
        guard clip.w > 1e-6 else { return nil }
        let ndcX = clip.x / clip.w                       // [-1, 1]
        let ndcY = clip.y / clip.w                       // [-1, 1], +y up
        let x = (ndcX * 0.5 + 0.5) * Float(viewportSize.width)
        let y = (1 - (ndcY * 0.5 + 0.5)) * Float(viewportSize.height)   // flip to y-down
        guard x.isFinite, y.isFinite else { return nil }
        return CGPoint(x: CGFloat(x), y: CGFloat(y))
    }

    /// The world-space ray (origin, unit direction) through a view-space point (points,
    /// top-left origin, y down) — the INVERSE of `project`. Unprojects the near and far
    /// clip points of the pixel and connects them, so the keep-clear drag handles
    /// (Phase B) turn a touch into the exact camera ray the volumes were drawn with.
    /// Nil for a degenerate viewport or a non-invertible transform. Pure (no MetalKit),
    /// so the round-trip with `project` is unit-tested headlessly.
    public func ray(throughViewPoint p: CGPoint) -> (origin: SIMD3<Float>, dir: SIMD3<Float>)? {
        guard isUsable else { return nil }
        let ndcX = Float(p.x / viewportSize.width) * 2 - 1
        let ndcY = 1 - Float(p.y / viewportSize.height) * 2      // tap y is down, NDC y up
        let inv = viewProjection.inverse
        func unproject(_ z: Float) -> SIMD3<Float>? {            // Metal clip z ∈ [0, 1]
            let clip = inv * SIMD4<Float>(ndcX, ndcY, z, 1)
            guard abs(clip.w) > 1e-9 else { return nil }
            return SIMD3<Float>(clip.x, clip.y, clip.z) / clip.w
        }
        guard let near = unproject(0), let far = unproject(1) else { return nil }
        let d = far - near
        let len = simd_length(d)
        guard len > 1e-9, d.x.isFinite, d.y.isFinite, d.z.isFinite else { return nil }
        return (near, d / len)
    }
}

public struct OrbitCamera: Equatable {
    /// The point the camera looks at (set to the model centre by `frame`; slid off it by
    /// `pan`, restored by `resetPan`).
    public var target: SIMD3<Float>
    /// The un-panned orbit centre — the framed model centre `frame` computed. `pan` moves
    /// `target` away from it; `resetPan` (the Home button, round-4 item 2) returns to it, so
    /// Home clears any pan. Captured by `init`/`frame` so it always tracks the current framing.
    public private(set) var homeTarget: SIMD3<Float>
    /// Distance from `target` to the eye. Clamped to `[minDistance, maxDistance]`.
    public var distance: Float
    /// Yaw about the world +Y axis, in radians. Unbounded (wraps naturally).
    public var azimuth: Float
    /// Pitch, in radians. Clamped to ±`maxElevation` to avoid flipping over the pole.
    public private(set) var elevation: Float
    /// ROLL about the view axis (the line of sight), in radians — the "visual axis"
    /// rotation the gizmo's swoosh arrows drive (design-overhaul, handoff 109). Unbounded
    /// (wraps naturally). This is the DOF handoff 107 Blocked-stopped on: the 074 "roll=0"
    /// decision is overridden by the maintainer FOR THIS TASK (he records it in DECISIONS.md;
    /// this code does not). Rolls the horizon by tilting the camera up-vector about the
    /// direction of view; it never moves the eye, so it composes freely with azimuth/
    /// elevation and does not affect the canonical-view `direction`. `roll == 0` is the
    /// level view Home and every snap return to.
    public private(set) var roll: Float = 0
    /// Vertical field of view, in radians.
    public var fovY: Float
    public var minDistance: Float
    public var maxDistance: Float

    /// Elevation is kept just shy of ±90° so the up vector never aligns with the
    /// view direction (which would make the look-at basis degenerate).
    public static let maxElevation: Float = .pi / 2 - 0.05
    /// Radians of orbit per point of drag.
    public static let orbitSensitivity: Float = 0.01

    public init(target: SIMD3<Float> = .zero,
                distance: Float = 3,
                azimuth: Float = .pi / 4,
                elevation: Float = .pi / 6,
                roll: Float = 0,
                fovY: Float = .pi / 4,
                minDistance: Float = 0.01,
                maxDistance: Float = 1_000) {
        self.target = target
        self.homeTarget = target
        self.distance = distance
        self.azimuth = azimuth
        self.roll = roll
        self.fovY = fovY
        self.minDistance = minDistance
        self.maxDistance = maxDistance
        self.elevation = Self.clampElevation(elevation)
    }

    static func clampElevation(_ e: Float) -> Float {
        Swift.min(Swift.max(e, -maxElevation), maxElevation)
    }

    /// Set azimuth + elevation together (elevation clamped near the poles). Used by
    /// the shared camera model when snapping to a canonical view or animating.
    public mutating func setOrientation(azimuth: Float, elevation: Float) {
        self.azimuth = azimuth
        self.elevation = Self.clampElevation(elevation)
    }

    /// Invert `direction` back to an (azimuth, elevation) pair — the canonical camera
    /// that looks at the target FROM `d` (a unit eye-direction). This is the exact
    /// inverse of `direction`'s formula `(cosE·sinA, sinE, cosE·cosA)`, so snapping to
    /// a named-view direction and reading `direction` back is a round-trip. Elevation
    /// is clamped to the pole limit (so a straight-down "Top" lands at the reachable
    /// `maxElevation`, never the degenerate pole). At a pole the azimuth is undefined,
    /// so the caller's `currentAzimuth` is preserved (keeps the spin you had).
    public static func azimuthElevation(forDirection d: SIMD3<Float>,
                                        currentAzimuth: Float = 0) -> (azimuth: Float, elevation: Float) {
        let n = simd_length(d) > 1e-6 ? simd_normalize(d) : SIMD3<Float>(0, 0, 1)
        let elevation = clampElevation(asin(Swift.min(Swift.max(n.y, -1), 1)))
        // Near a pole the horizontal component vanishes and azimuth is undefined.
        let horiz = n.x * n.x + n.z * n.z
        let azimuth = horiz > 1e-6 ? atan2(n.x, n.z) : currentAzimuth
        return (azimuth, elevation)
    }

    /// The upper-left 3×3 of the view matrix (world→view rotation) — the orientation
    /// the model appears in from this camera. The orientation gizmo renders the cube
    /// through exactly this, so the widget can never diverge from the live view.
    public func viewRotation() -> simd_float3x3 { normalMatrix() }

    /// Frame `bounds`: look at its centre from a distance that fits the whole
    /// bounding sphere in the vertical field of view (with a small margin), and set
    /// the zoom limits relative to the part size. A degenerate (empty/point) mesh
    /// falls back to a unit radius so the camera is still usable.
    public mutating func frame(_ bounds: MeshBounds, margin: Float = 1.15) {
        let radius = Swift.max(bounds.radius, 1e-4)
        target = bounds.isEmpty ? .zero : bounds.center
        homeTarget = target           // reframing re-anchors Home to the new model centre
        minDistance = radius * 0.2
        maxDistance = radius * 12
        let fit = radius / sin(fovY * 0.5) * margin
        distance = Swift.min(Swift.max(fit, minDistance), maxDistance)
    }

    /// Orbit by a drag delta in points (dx = screen-right, dy = screen-DOWN — both gesture
    /// paths normalize to this): horizontal drag turns azimuth, vertical drag changes
    /// elevation (clamped near the poles).
    ///
    /// ROLL-AWARE (device round 3, item 2): azimuth/elevation are WORLD-frame rotations, but a
    /// drag is a SCREEN vector — and once the view is rolled the screen no longer aligns with
    /// that world frame, so feeding the raw delta made a screen-DOWN drag slide the view
    /// sideways (the 074 roll-pin's exact concern). Fix: decompose the drag in the CAMERA frame
    /// by undoing the roll (rotate the delta by −roll) BEFORE mapping, so screen-down always
    /// moves the view down regardless of roll. The image rotates by +roll in this y-down screen
    /// space (see `up`); the inverse rotation R(−roll) is the transpose below. At roll == 0 the
    /// rotation is the identity, so the mapping is bit-identical to the pre-roll camera.
    public mutating func orbit(dx: Float, dy: Float) {
        let c = cos(roll), s = sin(roll)
        let rx =  c * dx + s * dy        // R(−roll) · (dx, dy): drag delta in the un-rolled frame
        let ry = -s * dx + c * dy
        azimuth -= rx * Self.orbitSensitivity
        elevation = Self.clampElevation(elevation + ry * Self.orbitSensitivity)
    }

    /// Zoom by a multiplicative factor (`< 1` moves closer, `> 1` farther),
    /// clamped to the framed distance limits.
    public mutating func zoom(_ factor: Float) {
        guard factor > 0, factor.isFinite else { return }
        distance = Swift.min(Swift.max(distance * factor, minDistance), maxDistance)
    }

    /// Two-finger CAD pan (round-4 item 2): slide the look-at `target` in the VIEW PLANE by a
    /// screen drag (`dx` = screen-right, `dy` = screen-DOWN, both in points — the same convention
    /// `orbit` takes). The world distance per screen point is derived from the view frustum at the
    /// target (`2·distance·tan(fovY/2) / viewportHeight`), so the grabbed point tracks the finger
    /// 1:1 at any zoom. The eye follows `target` (see `eye`), so pan translates the whole camera
    /// sideways without changing orientation; a subsequent `orbit` therefore turns about the NEW
    /// target. Roll-aware for the same reason `orbit` is: the drag is decomposed in the rolled
    /// camera frame so screen-right always slides the view right. `homeTarget` is untouched, so
    /// `resetPan`/Home can always return.
    public mutating func pan(dx: Float, dy: Float, viewportHeight: Float) {
        guard viewportHeight > 0, dx.isFinite, dy.isFinite else { return }
        let worldPerPixel = 2 * distance * tan(fovY * 0.5) / viewportHeight
        // Undo roll so a screen-down drag pans down regardless of the horizon tilt (see `orbit`).
        let c = cos(roll), s = sin(roll)
        let rx =  c * dx + s * dy
        let ry = -s * dx + c * dy
        let dir = direction
        var right = simd_cross(up, dir)
        var camUp = simd_cross(dir, right)
        guard simd_length(right) > 1e-6, simd_length(camUp) > 1e-6 else { return }
        right = simd_normalize(right); camUp = simd_normalize(camUp)
        // Grab-pan: the camera moves OPPOSITE the finger so the world point under it follows the
        // finger. Screen-right → target left (−right); screen-down → target up (+camUp).
        target += (-right * rx + camUp * ry) * worldPerPixel
    }

    /// Return the look-at to the framed centre, clearing any `pan` (the Home button, item 2).
    public mutating func resetPan() { target = homeTarget }

    /// Roll the view by `delta` radians about the line of sight (the swoosh arrows). Positive
    /// spins the horizon one way, negative the other; unbounded (wraps). Does not move the eye.
    public mutating func rollBy(_ delta: Float) {
        guard delta.isFinite else { return }
        roll += delta
    }

    /// Set the roll angle directly (radians). Used by the shared model when animating a
    /// snap/home back to a level horizon (`roll = 0`).
    public mutating func setRoll(_ r: Float) {
        guard r.isFinite else { return }
        roll = r
    }

    /// Unit direction from `target` toward the eye.
    public var direction: SIMD3<Float> {
        let ce = cos(elevation), se = sin(elevation)
        let ca = cos(azimuth), sa = sin(azimuth)
        return SIMD3<Float>(ce * sa, se, ce * ca)
    }

    /// The eye (camera) position in world space.
    public var eye: SIMD3<Float> { target + direction * distance }

    /// The camera up-vector: world +Y rolled about the line of sight by `roll` (Rodrigues
    /// rotation about `direction`). At `roll == 0` this is exactly `(0,1,0)`, so the levelled
    /// view is byte-identical to the pre-roll camera. The rotation preserves the component of
    /// up along the view axis, so `cross(up, z)` in `lookAt` stays well-conditioned wherever
    /// it already was (elevation is clamped shy of the pole regardless).
    public var up: SIMD3<Float> {
        let base = SIMD3<Float>(0, 1, 0)
        guard roll != 0 else { return base }
        let k = direction                        // unit rotation axis (line of sight, toward eye)
        let c = cos(roll), s = sin(roll)
        return base * c + simd_cross(k, base) * s + k * (simd_dot(k, base) * (1 - c))
    }

    /// World → view (camera) space. `eye` maps to the origin and `target` to
    /// `(0, 0, -distance)` (straight ahead down −Z); `roll` tilts the horizon via `up`.
    public func viewMatrix() -> simd_float4x4 {
        Self.lookAt(eye: eye, center: target, up: up)
    }

    /// View → clip space (right-handed, Metal [0,1] depth).
    public func projectionMatrix(aspect: Float, near: Float = 0.01, far: Float = 10_000) -> simd_float4x4 {
        let a = aspect > 0 ? aspect : 1
        let ys = 1 / tan(fovY * 0.5)
        let xs = ys / a
        let zs = far / (near - far)
        return simd_float4x4(columns: (
            SIMD4<Float>(xs, 0, 0, 0),
            SIMD4<Float>(0, ys, 0, 0),
            SIMD4<Float>(0, 0, zs, -1),
            SIMD4<Float>(0, 0, zs * near, 0)
        ))
    }

    /// The normal matrix: the view rotation (upper-left 3×3 of the view matrix).
    /// The model matrix is identity (world vertices are rendered directly with the
    /// orbit target at the model centre), so normals transform by the view rotation
    /// alone.
    public func normalMatrix() -> simd_float3x3 {
        let v = viewMatrix()
        return simd_float3x3(columns: (
            SIMD3<Float>(v.columns.0.x, v.columns.0.y, v.columns.0.z),
            SIMD3<Float>(v.columns.1.x, v.columns.1.y, v.columns.1.z),
            SIMD3<Float>(v.columns.2.x, v.columns.2.y, v.columns.2.z)
        ))
    }

    /// Right-handed look-at (gluLookAt convention), column-major for simd.
    static func lookAt(eye: SIMD3<Float>, center: SIMD3<Float>, up: SIMD3<Float>) -> simd_float4x4 {
        let z = simd_normalize(eye - center)          // camera looks toward −z
        let x = simd_normalize(simd_cross(up, z))
        let y = simd_cross(z, x)
        return simd_float4x4(columns: (
            SIMD4<Float>(x.x, y.x, z.x, 0),
            SIMD4<Float>(x.y, y.y, z.y, 0),
            SIMD4<Float>(x.z, y.z, z.z, 0),
            SIMD4<Float>(-simd_dot(x, eye), -simd_dot(y, eye), -simd_dot(z, eye), 1)
        ))
    }
}
