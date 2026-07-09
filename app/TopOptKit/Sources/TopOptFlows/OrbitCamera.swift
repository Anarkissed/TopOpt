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
import simd

public struct OrbitCamera: Equatable {
    /// The point the camera looks at (set to the model centre by `frame`).
    public var target: SIMD3<Float>
    /// Distance from `target` to the eye. Clamped to `[minDistance, maxDistance]`.
    public var distance: Float
    /// Yaw about the world +Y axis, in radians. Unbounded (wraps naturally).
    public var azimuth: Float
    /// Pitch, in radians. Clamped to ±`maxElevation` to avoid flipping over the pole.
    public private(set) var elevation: Float
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
                fovY: Float = .pi / 4,
                minDistance: Float = 0.01,
                maxDistance: Float = 1_000) {
        self.target = target
        self.distance = distance
        self.azimuth = azimuth
        self.fovY = fovY
        self.minDistance = minDistance
        self.maxDistance = maxDistance
        self.elevation = Self.clampElevation(elevation)
    }

    private static func clampElevation(_ e: Float) -> Float {
        Swift.min(Swift.max(e, -maxElevation), maxElevation)
    }

    /// Frame `bounds`: look at its centre from a distance that fits the whole
    /// bounding sphere in the vertical field of view (with a small margin), and set
    /// the zoom limits relative to the part size. A degenerate (empty/point) mesh
    /// falls back to a unit radius so the camera is still usable.
    public mutating func frame(_ bounds: MeshBounds, margin: Float = 1.15) {
        let radius = Swift.max(bounds.radius, 1e-4)
        target = bounds.isEmpty ? .zero : bounds.center
        minDistance = radius * 0.2
        maxDistance = radius * 12
        let fit = radius / sin(fovY * 0.5) * margin
        distance = Swift.min(Swift.max(fit, minDistance), maxDistance)
    }

    /// Orbit by a drag delta in points: horizontal drag turns azimuth, vertical
    /// drag changes elevation (clamped near the poles).
    public mutating func orbit(dx: Float, dy: Float) {
        azimuth -= dx * Self.orbitSensitivity
        elevation = Self.clampElevation(elevation + dy * Self.orbitSensitivity)
    }

    /// Zoom by a multiplicative factor (`< 1` moves closer, `> 1` farther),
    /// clamped to the framed distance limits.
    public mutating func zoom(_ factor: Float) {
        guard factor > 0, factor.isFinite else { return }
        distance = Swift.min(Swift.max(distance * factor, minDistance), maxDistance)
    }

    /// Unit direction from `target` toward the eye.
    public var direction: SIMD3<Float> {
        let ce = cos(elevation), se = sin(elevation)
        let ca = cos(azimuth), sa = sin(azimuth)
        return SIMD3<Float>(ce * sa, se, ce * ca)
    }

    /// The eye (camera) position in world space.
    public var eye: SIMD3<Float> { target + direction * distance }

    /// World → view (camera) space. `eye` maps to the origin and `target` to
    /// `(0, 0, -distance)` (straight ahead down −Z).
    public func viewMatrix() -> simd_float4x4 {
        Self.lookAt(eye: eye, center: target, up: SIMD3<Float>(0, 1, 0))
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
