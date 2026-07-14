// OrientationGizmo.swift — the pure geometry behind the ViewCube-style orientation
// widget (the 3d-gizmo-orbit-camera task).
//
// The gizmo is a small cube that mirrors the shared camera's orientation and, when a
// region is tapped, snaps the camera to that canonical view. ALL of that reduces to
// three pure operations pinned here (headlessly tested — the M7 /app/ standard):
//
//   * the 26 clickable REGIONS (6 faces, 12 edges, 8 corners) and the canonical
//     (azimuth, elevation) each maps to — shared with `OrbitCamera` so a snap is an
//     exact round-trip;
//   * HIT-TESTING a tap point to a region, by ray-casting the tap through the same
//     rotation the widget renders with and classifying where it enters the unit cube;
//   * the cube's world→view rotation, taken verbatim from the camera so the widget
//     can never drift out of lockstep with the live view.
//
// The SwiftUI drawing + gestures (OrientationGizmoView) are device QA; this math is
// not, so it lives apart and is unit-tested.

import Foundation
import simd

/// One clickable region of the orientation cube: a face, edge, or corner. `anchor`
/// has each component in {-1, 0, +1} — the count of non-zero components is the kind
/// (1 = face, 2 = edge, 3 = corner) and their signs place it on the cube. `direction`
/// (the normalized anchor) is the unit eye-direction of the canonical view: the camera
/// looks at the model FROM there.
public struct GizmoRegion: Equatable, Sendable, Identifiable {
    public enum Kind: Sendable { case face, edge, corner }
    public let id: String
    public let anchor: SIMD3<Float>
    public let kind: Kind
    /// The face label drawn on the cube (Front/Top/Right/…); nil for edges/corners.
    public let label: String?

    /// Unit eye-direction of this region's canonical view.
    public var direction: SIMD3<Float> { simd_normalize(anchor) }

    /// The canonical (azimuth, elevation) a snap to this region targets. `currentAzimuth`
    /// is preserved for the poles (Top/Bottom), where azimuth is undefined.
    public func orientation(currentAzimuth: Float) -> (azimuth: Float, elevation: Float) {
        OrbitCamera.azimuthElevation(forDirection: direction, currentAzimuth: currentAzimuth)
    }
}

public enum OrientationGizmo {
    /// Model-axis face names. +Z faces the viewer at the default front view (the camera
    /// eye sits on +Z and looks down −Z), so +Z is "Front"; +Y up is "Top"; +X is
    /// "Right" — matching how `OrbitCamera`'s canonical views are defined.
    private static func faceName(axis: Int, positive: Bool) -> String {
        switch (axis, positive) {
        case (0, true): return "Right"; case (0, false): return "Left"
        case (1, true): return "Top";   case (1, false): return "Bottom"
        default:        return positive ? "Front" : "Back"   // axis 2 (Z)
        }
    }

    /// All 26 regions: the 6 faces first (labeled), then the 12 edges, then the 8
    /// corners. Built once from every {-1,0,1}³ anchor except the origin.
    public static let regions: [GizmoRegion] = buildRegions()

    /// The 6 face regions, in axis order (Right, Left, Top, Bottom, Front, Back).
    public static var faces: [GizmoRegion] { regions.filter { $0.kind == .face } }

    /// Look up a region by its id (e.g. "Front", "Top-Right", "Front-Top-Right").
    public static func region(_ id: String) -> GizmoRegion? { regions.first { $0.id == id } }

    private static func buildRegions() -> [GizmoRegion] {
        var faces: [GizmoRegion] = []
        var edges: [GizmoRegion] = []
        var corners: [GizmoRegion] = []
        for x in -1...1 { for y in -1...1 { for z in -1...1 {
            let a = SIMD3<Float>(Float(x), Float(y), Float(z))
            let nz = [x, y, z].filter { $0 != 0 }.count
            if nz == 0 { continue }
            // Name each active axis by its face name, ordered Top/Bottom, Front/Back,
            // Right/Left (Y, Z, X) so ids read naturally ("Top-Front-Right").
            var parts: [String] = []
            for axis in [1, 2, 0] {
                let c = axis == 0 ? x : (axis == 1 ? y : z)
                if c != 0 { parts.append(faceName(axis: axis, positive: c > 0)) }
            }
            let id = parts.joined(separator: "-")
            switch nz {
            case 1:
                // The single active axis carries the label.
                let axis = x != 0 ? 0 : (y != 0 ? 1 : 2)
                let pos = (axis == 0 ? x : (axis == 1 ? y : z)) > 0
                faces.append(GizmoRegion(id: id, anchor: a, kind: .face,
                                         label: faceName(axis: axis, positive: pos)))
            case 2:
                edges.append(GizmoRegion(id: id, anchor: a, kind: .edge, label: nil))
            default:
                corners.append(GizmoRegion(id: id, anchor: a, kind: .corner, label: nil))
            }
        }}}
        return faces + edges + corners
    }

    /// Fraction of the gizmo's HALF-size that one model unit (a cube half-face) maps to
    /// on screen. The view draws the cube at this scale and `hitTest` inverts by it, so
    /// the tappable regions line up exactly with the drawn cube (a tap outside the drawn
    /// silhouette misses). 0.5 leaves a comfortable margin around the cube.
    public static let cubeScreenScale: Float = 0.5

    /// The fraction of a face (measured from an edge) that resolves to that edge/corner
    /// rather than the face centre. 0.3 → the central 70% of a face is the face region;
    /// the outer band splits into the 12 edges and 8 corners, the standard ViewCube feel.
    public static let edgeBand: Float = 0.3

    /// Resolve a tap to a region, or nil when the tap misses the cube. `point` is in the
    /// gizmo view's coordinates (top-left origin, y down); `size` is that view's size;
    /// `rotation` is the camera's `viewRotation()` (the SAME transform the widget draws
    /// with, so the tap lands where the user sees the cube).
    ///
    /// Method: treat the widget as an orthographic camera looking down view −Z. The tap
    /// is a ray at (ndcX, ndcY) travelling −Z; transform it into model space (Rᵀ, since
    /// R is world→view and orthonormal), intersect the unit cube [-1,1]³, and classify
    /// the entry point — an axis within `edgeBand` of a face is "active", and the number
    /// of active axes (1/2/3) selects face/edge/corner.
    public static func hitTest(point: CGPoint, in size: CGSize,
                               rotation: simd_float3x3,
                               scale: Float = cubeScreenScale) -> GizmoRegion? {
        guard size.width > 0, size.height > 0, scale > 0 else { return nil }
        // Normalize the tap to the centred square, then divide by the render scale so the
        // ndc lands in the cube's own model units (a face edge sits at ±1, matching what
        // the view drew). A tap beyond the drawn silhouette exceeds ±1 and misses.
        let ndcX = Float((point.x / size.width) * 2 - 1) / scale
        let ndcY = Float(1 - (point.y / size.height) * 2) / scale   // flip to y-up

        // Ray in view space: start well in front (+Z) of the cube, travel toward −Z.
        let rt = rotation.transpose                          // view → model (R is orthonormal)
        let originView = SIMD3<Float>(ndcX, ndcY, 10)
        let dirView = SIMD3<Float>(0, 0, -1)
        let o = rt * originView
        let d = rt * dirView

        guard let hit = intersectUnitCube(origin: o, dir: d) else { return nil }
        // Classify the entry point: an axis is "active" when it is within `edgeBand` of
        // its ±1 face. Snap each active axis to its sign; inactive axes are 0.
        let thresh = 1 - edgeBand
        var anchor = SIMD3<Float>(0, 0, 0)
        for i in 0..<3 {
            let c = hit[i]
            if abs(c) >= thresh { anchor[i] = c >= 0 ? 1 : -1 }
        }
        // A degenerate all-zero classification (tap dead-centre of an oblique face that
        // is barely grazed) falls back to the dominant axis so we always return a face.
        if anchor == SIMD3<Float>(0, 0, 0) {
            let ax = dominantAxis(hit)
            anchor[ax] = hit[ax] >= 0 ? 1 : -1
        }
        return regions.first { $0.anchor == anchor }
    }

    private static func dominantAxis(_ v: SIMD3<Float>) -> Int {
        let a = abs(v)
        if a.x >= a.y && a.x >= a.z { return 0 }
        return a.y >= a.z ? 1 : 2
    }

    /// Nearest-entry intersection of a ray with the axis-aligned cube [-1,1]³ (slab
    /// method). Returns the entry point, or nil if the ray misses.
    private static func intersectUnitCube(origin: SIMD3<Float>, dir: SIMD3<Float>) -> SIMD3<Float>? {
        var tmin = -Float.greatestFiniteMagnitude
        var tmax = Float.greatestFiniteMagnitude
        for i in 0..<3 {
            if abs(dir[i]) < 1e-8 {
                if origin[i] < -1 || origin[i] > 1 { return nil }   // parallel & outside
            } else {
                let inv = 1 / dir[i]
                var t1 = (-1 - origin[i]) * inv
                var t2 = (1 - origin[i]) * inv
                if t1 > t2 { swap(&t1, &t2) }
                tmin = Swift.max(tmin, t1)
                tmax = Swift.min(tmax, t2)
                if tmin > tmax { return nil }
            }
        }
        let t = tmin >= 0 ? tmin : tmax
        guard t.isFinite else { return nil }
        return origin + dir * t
    }
}
