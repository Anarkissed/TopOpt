// RotationRing.swift — the M7.6-ring constrained single-DOF rotation gizmo model
// (MOD-F1 D4 v2: "a single-DOF rotation ring at the arrow base for custom
// directions, 15° detents, haptic ticks, second ring appears only after the
// first commits. Never a freehand drag.").
//
// Why a model, not just a gesture: aiming a 3D direction by freehand-dragging on
// a 2D screen is the exact failure MOD-F1 P1 rejects. Instead the user rotates a
// direction about ONE fixed axis (a single degree of freedom); a full sphere is
// reached by two such rotations in sequence (ring 1, then an orthogonal ring 2),
// never by a 2-DOF drag. This value type owns that math — the rotation about the
// fixed axis, the 15° detent snap, the detent-crossing edges that drive the
// haptic ticks, and the two-ring sequencing — so it is unit-tested headlessly
// (the M7 /app/ verification standard). The drawn ring, the drag gesture, and the
// CoreHaptics ticks are the SwiftUI/GPU surface over it and are maintainer QA.

import Foundation
import simd

/// A single constrained rotation ring: it rotates a `base` unit direction about a
/// fixed `axis` (⟂ base) by one scalar `angle` — the single degree of freedom.
public struct RotationRing: Equatable, Sendable {

    /// Detent spacing in degrees (D4: 15° detents).
    public static let detentDegrees: Float = 15
    /// Detent spacing in radians.
    public static var detentRadians: Float { detentDegrees * .pi / 180 }
    /// Detents in a full turn (360 / 15).
    public static let detentCount = 24

    /// The direction the ring rotates (unit, model/world space per the caller).
    public let base: SIMD3<Float>
    /// The fixed rotation axis — the single DOF. Always unit and ⟂ `base`.
    public let axis: SIMD3<Float>
    /// The current, unsnapped angle in radians (tracks the live drag).
    public private(set) var angle: Float

    /// Build a ring rotating `base` about `axis`. `axis` is projected onto the plane
    /// ⟂ base (and normalized) so the rotation is a genuine single DOF; a degenerate
    /// (parallel) axis falls back to an arbitrary perpendicular rather than NaNing.
    public init(base: SIMD3<Float>, axis: SIMD3<Float>, angle: Float = 0) {
        let b = Self.safeNormalize(base) ?? SIMD3<Float>(0, -1, 0)
        self.base = b
        self.axis = Self.orthonormalAxis(to: b, preferred: axis)
        self.angle = angle.isFinite ? angle : 0
    }

    /// Track the live drag angle (radians). Ignores a non-finite value.
    public mutating func rotate(toRadians a: Float) { if a.isFinite { angle = a } }

    /// The unit direction produced by rotating `base` about `axis` by `a`.
    public func direction(atRadians a: Float) -> SIMD3<Float> {
        simd_normalize(simd_quatf(angle: a, axis: axis).act(base))
    }

    /// The live (unsnapped) direction — the drag preview.
    public var liveDirection: SIMD3<Float> { direction(atRadians: angle) }
    /// The current angle snapped to the nearest 15° detent.
    public var snappedAngle: Float { Self.nearestDetentAngle(to: angle) }
    /// The committed direction — rotated to the nearest detent.
    public var snappedDirection: SIMD3<Float> { direction(atRadians: snappedAngle) }

    // MARK: - detents (static: also used by the gesture layer before a ring exists)

    /// The nearest 15° detent angle (radians) to `a`.
    public static func nearestDetentAngle(to a: Float) -> Float {
        guard a.isFinite else { return 0 }
        return (a / detentRadians).rounded() * detentRadians
    }

    /// The (possibly negative) detent index an angle rounds to — its identity for
    /// tick detection.
    public static func detentIndex(forRadians a: Float) -> Int {
        guard a.isFinite else { return 0 }
        return Int((a / detentRadians).rounded())
    }

    /// True when a drag from `a` to `b` moves into a different detent — the edge on
    /// which the gizmo fires one haptic tick.
    public static func didCrossDetent(fromRadians a: Float, toRadians b: Float) -> Bool {
        detentIndex(forRadians: a) != detentIndex(forRadians: b)
    }

    /// The angle (radians) of a screen `location` about the ring's screen `center` —
    /// the single scalar a constrained drag maps to (the drag is never a freehand
    /// 3D vector, only a position around the ring).
    public static func angleForDrag(center: CGPoint, location: CGPoint) -> Float {
        Float(atan2(location.y - center.y, location.x - center.x))
    }

    // MARK: - helpers

    static func safeNormalize(_ v: SIMD3<Float>) -> SIMD3<Float>? {
        let len = simd_length(v)
        guard len > 1e-6, v.x.isFinite, v.y.isFinite, v.z.isFinite else { return nil }
        return v / len
    }

    /// A unit axis in the plane ⟂ `base`: the component of `preferred` orthogonal to
    /// `base`, or (if `preferred` is parallel/degenerate) an arbitrary perpendicular.
    static func orthonormalAxis(to base: SIMD3<Float>, preferred: SIMD3<Float>) -> SIMD3<Float> {
        if let p = safeNormalize(preferred - simd_dot(preferred, base) * base) { return p }
        let trial: SIMD3<Float> = abs(base.x) < 0.9 ? SIMD3<Float>(1, 0, 0) : SIMD3<Float>(0, 1, 0)
        return simd_normalize(trial - simd_dot(trial, base) * base)
    }
}

/// The two-stage constrained aiming (D4 v2): ring 1 rotates the base direction in
/// one plane; once it commits, ring 2 — rotating about an axis orthogonal to both
/// ring 1's axis and its committed direction — appears, letting the user tilt out
/// of that plane. Two single-DOF rotations reach any direction on the sphere; the
/// user never freehand-drags a vector. Only two rings ever exist.
public struct RingAiming: Equatable, Sendable {

    /// The first (always-present) ring.
    public private(set) var first: RotationRing
    /// The second ring — nil until `commitFirst()`.
    public private(set) var second: RotationRing?

    public init(base: SIMD3<Float>, primaryAxis: SIMD3<Float>) {
        first = RotationRing(base: base, axis: primaryAxis)
    }

    /// Whether the second ring is active (i.e. the first has committed).
    public var isOnSecondRing: Bool { second != nil }
    /// The ring the drag currently drives.
    public var activeRing: RotationRing { second ?? first }

    /// Drive the active ring's live angle.
    public mutating func rotateActive(toRadians a: Float) {
        if second != nil { second!.rotate(toRadians: a) } else { first.rotate(toRadians: a) }
    }

    /// Commit ring 1's snapped angle and reveal the orthogonal ring 2. No-op once
    /// ring 2 exists (there are only ever two rings).
    public mutating func commitFirst() {
        guard second == nil else { return }
        let committed = first.snappedDirection
        let axis2 = simd_cross(first.axis, committed)     // ⟂ both → a new degree of freedom
        second = RotationRing(base: committed, axis: axis2)
    }

    /// The live (unsnapped) aimed direction of the active ring — the drag preview.
    public var previewDirection: SIMD3<Float> { activeRing.liveDirection }
    /// The committed (snapped) aimed direction of the active ring.
    public var committedDirection: SIMD3<Float> { activeRing.snappedDirection }
}
