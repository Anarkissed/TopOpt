// GravityDirectionGizmo.swift — the PURE math for "point which way is down" (gravity
// direction widget, 2026-07-26).
//
// The device-found problem: setting gravity required TAPPING A FACE, and on STL meshes
// the pseudo-face segmentation frequently over-selects, so a tap can't reliably indicate
// a direction. The fix is to stop depending on a clean face: the user POINTS a direction
// in 3D instead. This is that widget's math — a single draggable arrow whose tip the user
// pushes around a camera-facing plane, re-normalized to a unit pointing direction, then
// SNAPPED to the part's principal axes.
//
// It deliberately speaks TopOpt's existing gizmo language: it reuses `PrimitiveGizmo.Ray`
// and `PrimitiveGizmo.rayPlaneHit` (the same ray/plane math the transform gizmo drags on),
// so the pointing arrow feels like the position gizmo's free-move knob, not a foreign
// control. Everything here is a pure value type on simd `Double`s in MODEL space (the frame
// `ForceModel.gravity`, the mesh and the run share) — no SwiftUI, no GPU, no camera. The
// gesture that turns a touch into a model-space ray and the Metal/SwiftUI arrow are the
// device-QA'd layers (the /app/ rule); this snap/point math is unit-tested headlessly.

import Foundation
import simd

public enum GravityDirectionGizmo {

    /// How close (degrees, measured as the angle between the pointed direction and a snap
    /// target) the arrow must be before it SNAPS. Chosen so "straight down" is easy to hit
    /// exactly by hand yet an intentional off-axis direction (e.g. a 20° tilt) is still
    /// reachable. Stated in the handoff.
    public static let snapToleranceDegrees: Double = 12

    /// One direction the arrow snaps to, with a human label for the "Snapped to …" badge.
    public struct SnapTarget: Equatable, Sendable {
        /// A UNIT model-space direction.
        public let direction: SIMD3<Double>
        public let label: String
        public init(direction: SIMD3<Double>, label: String) {
            self.direction = direction
            self.label = label
        }
    }

    /// Build snap targets from the part's own flat FACE normals (round 2, 2026-07-27). These
    /// are the real requirement: gravity snaps perpendicular to whatever floor/wall the part
    /// sits on, however the part is oriented in model space — unlike the principal axes, which
    /// only coincide with the faces when the part is modelled axis-aligned (the "Gravity set ·
    /// custom" failure on the maintainer's imported bracket). The stored direction is the EXACT
    /// candidate normal, so a snapped gravity is bit-for-bit that face's normal (BAR V2).
    public static func faceSnapTargets(_ normals: [SIMD3<Double>]) -> [SnapTarget] {
        normals.map { SnapTarget(direction: unit($0), label: "face") }
    }

    /// The snap set: the six SIGNED principal axes — kept as cheap ADDITIONAL detents on top
    /// of the face normals (item 1). They coincide with the bounding-box faces of an
    /// axis-aligned part; the part's actual face normals (`faceSnapTargets`) are what make the
    /// snap engage on a real, arbitrarily-oriented import. The label names the axis; `−Y` is
    /// the conventional "down".
    public static let snapTargets: [SnapTarget] = [
        SnapTarget(direction: SIMD3<Double>( 1,  0,  0), label: "+X"),
        SnapTarget(direction: SIMD3<Double>(-1,  0,  0), label: "−X"),
        SnapTarget(direction: SIMD3<Double>( 0,  1,  0), label: "+Y"),
        SnapTarget(direction: SIMD3<Double>( 0, -1,  0), label: "−Y"),
        SnapTarget(direction: SIMD3<Double>( 0,  0,  1), label: "+Z"),
        SnapTarget(direction: SIMD3<Double>( 0,  0, -1), label: "−Z"),
    ]

    /// Normalize, falling back to model-space down (−Y) for a degenerate vector.
    public static func unit(_ v: SIMD3<Double>) -> SIMD3<Double> {
        let l = simd_length(v)
        return l > 1e-12 ? v / l : SIMD3<Double>(0, -1, 0)
    }

    /// Snap a pointed direction to the nearest snap target within `toleranceDeg`.
    ///
    /// The candidate set is the six principal axes FOLLOWED BY the part's own flat-face
    /// normals (`extraTargets`, item 1). When a target is within tolerance the EXACT target
    /// vector is returned — a snapped "down" is bit-exactly `(0, -1, 0)`, and a snapped face
    /// is bit-for-bit that face's normal, never `(0.0001, -0.9999, …)` (BAR V2). Outside
    /// tolerance the normalized input passes through unchanged with no label. The strongest
    /// dot wins; the FIRST target wins an exact tie — axes are listed first, so a face normal
    /// that happens to coincide with an axis reports the clean axis label.
    public static func snap(_ dir: SIMD3<Double>, extraTargets: [SnapTarget] = [],
                            toleranceDeg: Double = snapToleranceDegrees)
        -> (dir: SIMD3<Double>, label: String?) {
        let n = unit(dir)
        let cosTol = Foundation.cos(toleranceDeg * .pi / 180)
        var best: SnapTarget?
        var bestDot = cosTol
        for t in snapTargets + extraTargets {
            let d = simd_dot(n, t.direction)
            if d > bestDot { bestDot = d; best = t }
        }
        if let b = best { return (b.direction, b.label) }   // EXACT canonical / face vector
        return (n, nil)
    }

    /// The model-space arrow TIP for a unit `direction` about `center`, at `length` mm —
    /// the point the overlay projects to place the draggable knob.
    public static func tip(center: SIMD3<Double>, direction: SIMD3<Double>, length: Double)
        -> SIMD3<Double> {
        center + unit(direction) * Swift.max(length, 1)
    }

    // ─────────────────────────────────────────────────────────────────────────
    // MARK: - The drag (grab context → pointed direction)

    /// Everything captured when the arrow tip is grabbed, so each drag frame resolves to a
    /// stable pointed direction (no jump: the grab offset on the drag plane is preserved).
    /// All in MODEL space. The tip is dragged on the CAMERA-FACING plane through the start
    /// tip (like the transform gizmo's free-move handle), then re-normalized center→tip.
    public struct Drag: Equatable, Sendable {
        public let center: SIMD3<Double>
        public let length: Double
        public let startTip: SIMD3<Double>
        public let grab: PrimitiveGizmo.Ray
        /// Unit view direction (into the scene) — the drag plane's normal.
        public let viewDir: SIMD3<Double>

        public init(startDirection: SIMD3<Double>, center: SIMD3<Double>, length: Double,
                    grab: PrimitiveGizmo.Ray, viewDir: SIMD3<Double>) {
            let L = Swift.max(length, 1)
            self.center = center
            self.length = L
            self.startTip = center + GravityDirectionGizmo.unit(startDirection) * L
            self.grab = grab
            self.viewDir = PrimitiveGizmo.unit(viewDir)
        }

        /// The pointed UNIT direction for `currentRay`: move the tip by the drag's in-plane
        /// delta, then normalize (center → new tip). Degenerate/parallel geometry leaves the
        /// direction where it was (a safe no-op — the finger keeps control).
        public func resolve(currentRay: PrimitiveGizmo.Ray) -> SIMD3<Double> {
            let fallback = GravityDirectionGizmo.unit(startTip - center)
            guard let hit0 = PrimitiveGizmo.rayPlaneHit(grab, planePoint: startTip, planeNormal: viewDir),
                  let hit = PrimitiveGizmo.rayPlaneHit(currentRay, planePoint: startTip, planeNormal: viewDir)
            else { return fallback }
            let newTip = startTip + (hit - hit0)
            let d = newTip - center
            return simd_length(d) > 1e-9 ? GravityDirectionGizmo.unit(d) : fallback
        }
    }
}
