// ManualPrimitive.swift — a user-placed clearance primitive (handoff group-editing).
//
// The hole finder OVER-finds and MISSES. The user needs an escape hatch in BOTH
// directions: hand-place a keep-out the finder missed (this file), and hand-delete
// a phantom one the finder invented (ForceModel.suppressedClearanceFaces). A
// hand-placed primitive has NO B-rep face, so — unlike an auto clearance, whose
// axis/radius/normal are re-read from the STEP core-side — it carries its own
// geometry, which travels through the bridge + job schema as a `ClearanceSpec`
// with inline `ManualGeometry` (see TopOptKit.ClearanceSpec.manualBolt/manualFace).
//
// Everything here is a pure value type on simd scalars (no SwiftUI, no GPU, no
// bridge). The placement, the move + magnetic-detent math, and the spec/volume
// derivation are all headlessly unit-tested (the /app/ verification standard); the
// SwiftUI gesture that drags a primitive and the Metal draw are the device-QA'd
// layers.

import Foundation
import simd
import TopOptKit

/// One hand-placed clearance primitive, in MODEL space (mm) — the same frame as
/// the mesh, the load faces and the auto clearances. A bolt is a swept cylinder
/// (centre + axis + radius + half-length); a face is a bounded slab (centre origin
/// + outward normal + in-plane half-extents). `override` holds the per-primitive
/// margin / axial / depth edits, reusing the SAME `ClearanceOverride` an auto
/// primitive uses, so a manual primitive's chips behave identically.
public struct ManualPrimitive: Equatable, Sendable, Codable, Identifiable {
    public enum Kind: Int, Equatable, Sendable, Codable {
        case bolt = 0   // swept cylinder (a fastener keep-out)
        case face = 1   // bounded slab (a mounting-face keep-out)
    }

    public let id: UUID
    public var kind: Kind
    /// Bolt: a point on the axis (its centre). Face: a point on the plane (origin).
    public var center: SIMD3<Double>
    /// Bolt: the axis direction (unit). Face: the outward plane normal (unit).
    public var axis: SIMD3<Double>
    /// Bolt: the bore radius (mm).
    public var radiusMM: Double
    /// Bolt: half the cylinder's own axial extent (mm) about `center`.
    public var halfLengthMM: Double
    /// Face: in-plane half-extents (mm) of the slab footprint.
    public var halfUMM: Double
    public var halfWMM: Double
    /// Per-primitive distance overrides (nil field → the Auto suggestion).
    public var override: ClearanceOverride

    public init(id: UUID = UUID(), kind: Kind, center: SIMD3<Double>,
                axis: SIMD3<Double>, radiusMM: Double = 0, halfLengthMM: Double = 0,
                halfUMM: Double = 0, halfWMM: Double = 0,
                override: ClearanceOverride = ClearanceOverride()) {
        self.id = id
        self.kind = kind
        self.center = center
        self.axis = ManualPrimitive.unit(axis)
        self.radiusMM = radiusMM
        self.halfLengthMM = halfLengthMM
        self.halfUMM = halfUMM
        self.halfWMM = halfWMM
        self.override = override
    }

    static func unit(_ v: SIMD3<Double>) -> SIMD3<Double> {
        let l = simd_length(v)
        return l > 1e-9 ? v / l : SIMD3<Double>(0, 0, 1)
    }

    /// A default bolt centred at `center`, axis +Z, sized off the model so it is
    /// visible without editing: radius `r`, half-length `halfLen`.
    public static func defaultBolt(at center: SIMD3<Double>, radiusMM r: Double,
                                   halfLengthMM halfLen: Double) -> ManualPrimitive {
        ManualPrimitive(kind: .bolt, center: center, axis: SIMD3<Double>(0, 0, 1),
                        radiusMM: r, halfLengthMM: halfLen)
    }

    /// A default face slab centred at `center`, outward normal +Z, footprint `half`.
    public static func defaultFace(at center: SIMD3<Double>, halfMM half: Double,
                                   normal: SIMD3<Double> = SIMD3<Double>(0, 0, 1)) -> ManualPrimitive {
        ManualPrimitive(kind: .face, center: center, axis: normal, halfUMM: half, halfWMM: half)
    }

    /// The RESOLVED clearance distances (the user override, or the geometry-derived
    /// Auto suggestion — the same suggestions an auto primitive prefills). Used for
    /// both the run spec and the rendered volume so the picture matches the run.
    public var resolvedMarginMM: Double {
        override.concentricMarginMM ?? ClearanceSuggestion.boltMarginMM(boreRadiusMM: radiusMM)
    }
    public var resolvedAxialMM: Double {
        override.axialClearanceMM ?? ClearanceSuggestion.boltAxialMM(boreRadiusMM: radiusMM)
    }
    public var resolvedDepthMM: Double {
        override.slabDepthMM ?? ClearanceSuggestion.faceSlabDepthMM
    }

    /// The bridge/job spec for this primitive (inline manual geometry). The
    /// distances are sent ONLY when the user overrode them (non-nil), matching the
    /// auto path's 0-sentinel "use the suggestion" protocol — so a manual bolt the
    /// user never touched sends margin/axial 0 and the core derives them from
    /// `radius_mm`, exactly as an auto bolt derives from the bore.
    public func spec() -> TopOptKit.ClearanceSpec {
        switch kind {
        case .bolt:
            return .manualBolt(axisPoint: center, axisDir: axis, radiusMM: radiusMM,
                               halfLengthMM: halfLengthMM,
                               concentricMarginMM: override.concentricMarginMM ?? 0,
                               axialClearanceMM: override.axialClearanceMM ?? 0)
        case .face:
            return .manualFace(origin: center, normal: axis, halfUMM: halfUMM,
                               halfWMM: halfWMM, slabDepthMM: override.slabDepthMM ?? 0)
        }
    }

    /// A synthetic `StepFaceGeometry` so the manual primitive renders through the
    /// SAME `ClearanceVolume` path an auto primitive does (the picture is built from
    /// the identical numbers the run freezes).
    public var syntheticGeometry: StepFaceGeometry {
        switch kind {
        case .bolt:
            return StepFaceGeometry(kind: .cylinder, cylinderRadiusMM: radiusMM,
                                    axisPoint: center, axisDir: axis)
        case .face:
            return StepFaceGeometry(kind: .plane, planeNormal: axis, planeOrigin: center)
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Magnetic detents (pure; the gesture that feeds it is device QA)

/// A snap target the user can drag a manual primitive onto, with a human label so
/// the UI can state WHAT it snapped to and WHY (the handoff requires this).
public struct PrimitiveSnapTarget: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        /// A world principal axis (X/Y/Z) — the primitive's axis aligns to it.
        case worldAxis
        /// Another primitive's axis line — makes the two CO-AXIAL / parallel.
        case primitiveAxis
        /// A point to drop the centre on: a face centroid, a bore axis point, or
        /// another primitive's centre.
        case point
    }
    public let kind: Kind
    /// A reference point on the target (a point on the axis line, or the snap point).
    public let point: SIMD3<Double>
    /// A reference direction for axis targets (unit); `.zero` for a pure point.
    public let direction: SIMD3<Double>
    /// A short label, e.g. "world Z axis", "bore axis", "primitive 2".
    public let label: String
    public init(kind: Kind, point: SIMD3<Double>, direction: SIMD3<Double> = .zero,
                label: String) {
        self.kind = kind
        self.point = point
        self.direction = direction
        self.label = label
    }
}

/// The outcome of applying detents to a dragged position: the (possibly snapped)
/// centre + axis, and a list of the snaps that fired (empty = free move). The UI
/// shows `labels` ("Snapped to: bore axis, world Z") and pulses a haptic.
public struct PrimitiveDetentResult: Equatable, Sendable {
    public var center: SIMD3<Double>
    public var axis: SIMD3<Double>
    public var snapped: [PrimitiveSnapTarget]
    public var labels: [String] { snapped.map(\.label) }
    public var didSnap: Bool { !snapped.isEmpty }
}

/// Magnetic-detent math for moving a manual primitive. Given a free-drag centre +
/// the primitive's axis and the available targets, it snaps:
///   • the AXIS to the nearest world principal axis or nearby primitive axis, when
///     within `angleTolDeg` — so a hand-placed bolt lands parallel to the part's
///     holes instead of askew;
///   • the CENTRE onto the nearest snap point (face centroid / bore axis point /
///     another primitive's centre) or onto a snapped axis LINE, when within
///     `distanceTolMM` — so it sits ON a face or CO-AXIAL with a real hole.
/// Both are reported so the UI can say exactly what it snapped to and why. Pure +
/// headlessly tested; the drag gesture that supplies `freeCenter` is device QA.
public enum ManualPrimitiveDetent {
    /// Angular tolerance (deg) within which the axis snaps to a target direction.
    public static let angleTolDeg: Double = 8.0
    /// Distance tolerance (mm) within which the centre snaps to a target point/line.
    public static let distanceTolMM: Double = 3.0

    /// The world principal axes as snap targets (always available).
    public static func worldAxisTargets() -> [PrimitiveSnapTarget] {
        [("world X axis", SIMD3<Double>(1, 0, 0)),
         ("world Y axis", SIMD3<Double>(0, 1, 0)),
         ("world Z axis", SIMD3<Double>(0, 0, 1))]
            .map { PrimitiveSnapTarget(kind: .worldAxis, point: .zero, direction: $0.1, label: $0.0) }
    }

    /// Snap `freeCenter` + `axis` against `targets`. Axis snaps first (so a centre
    /// can then snap onto the snapped axis line); centre snaps to the closest point
    /// target OR the projection onto a snapped primitive/world axis line through its
    /// reference point, whichever is nearer within tolerance.
    public static func apply(freeCenter: SIMD3<Double>, axis: SIMD3<Double>,
                             targets: [PrimitiveSnapTarget],
                             angleTolDeg: Double = angleTolDeg,
                             distanceTolMM: Double = distanceTolMM) -> PrimitiveDetentResult {
        var snapped: [PrimitiveSnapTarget] = []
        let a = ManualPrimitive.unit(axis)

        // ── Axis snap: nearest axis target within the angular tolerance. ──
        var bestAxis: (t: PrimitiveSnapTarget, ang: Double)? = nil
        for t in targets where t.kind == .worldAxis || t.kind == .primitiveAxis {
            let d = ManualPrimitive.unit(t.direction)
            // Direction-agnostic angle (a bolt axis has no polarity): fold to [0,90].
            let c = min(1.0, abs(simd_dot(a, d)))
            let ang = acos(c) * 180.0 / .pi
            if ang <= angleTolDeg, bestAxis == nil || ang < bestAxis!.ang {
                bestAxis = (t, ang)
            }
        }
        var outAxis = a
        if let b = bestAxis {
            let d = ManualPrimitive.unit(b.t.direction)
            // Keep the axis pointing roughly the same way the user placed it.
            outAxis = simd_dot(a, d) < 0 ? -d : d
            snapped.append(b.t)
        }

        // ── Centre snap: the nearest of (a) a point target, or (b) the projection onto
        //    any primitive-axis LINE that is parallel to the FINAL axis — a co-axial
        //    snap — within the distance tolerance. Co-axial works regardless of which
        //    axis target won the angular snap (a world axis and a bore can be parallel).
        var best: (pos: SIMD3<Double>, label: String, dist: Double)? = nil
        func consider(_ pos: SIMD3<Double>, _ label: String) {
            let dist = simd_length(pos - freeCenter)
            guard dist <= distanceTolMM else { return }
            if best == nil || dist < best!.dist { best = (pos, label, dist) }
        }
        for t in targets where t.kind == .point { consider(t.point, t.label) }
        for t in targets where t.kind == .primitiveAxis {
            let d = ManualPrimitive.unit(t.direction)
            guard min(1.0, abs(simd_dot(outAxis, d))) >= cos(angleTolDeg * .pi / 180.0) else { continue }
            let proj = t.point + d * simd_dot(freeCenter - t.point, d)
            consider(proj, t.label)  // co-axial with this primitive/bore
        }

        var outCenter = freeCenter
        if let p = best {
            outCenter = p.pos
            // Report the snap (avoid a duplicate label already added by the axis snap).
            if !snapped.contains(where: { $0.label == p.label }) {
                snapped.append(PrimitiveSnapTarget(kind: .point, point: p.pos, label: p.label))
            }
        }

        return PrimitiveDetentResult(center: outCenter, axis: outAxis, snapped: snapped)
    }
}
