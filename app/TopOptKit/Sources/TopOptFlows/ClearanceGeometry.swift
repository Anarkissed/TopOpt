// ClearanceGeometry.swift — the pure, headless-testable geometry of a "Keep clear"
// clearance volume (keep-clear UX v2).
//
// THE POINT (design note): the app must render a clearance volume from the SAME
// numbers the core rasterizer freezes. The exact bore axis/radius and plane
// normal now cross the bridge as `StepFaceGeometry` (handoff: keep-clear v2 Part
// 1); this file turns them into the true swept-cylinder / bounded-slab region and
// derives the "Auto · N mm" labels — mirroring core/include/topopt/clearance.hpp
// exactly. An app-side tessellation fit that drew a slightly different cylinder
// would be a picture of a DIFFERENT object than the run keeps clear — reject-class.
//
// Everything here is a pure value type on simd scalars (no SwiftUI, no GPU, no
// bridge), so the region math, the Auto-label derivation, and the drag-handle
// math are all unit-tested headlessly (the /app/ verification standard). The
// MetalMeshView draw that consumes `ClearanceVolume` and the gesture layer that
// drives `ClearanceDragMath` are the device-QA'd parts and say so.

import Foundation
import simd
import TopOptKit

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Auto-label suggestions (mirror clearance.hpp)

/// The geometry-derived DEFAULT distances the UI prefills and labels "Auto · N mm".
///
/// DUPLICATED from `core/include/topopt/clearance.hpp` (`default_bolt_clearance`,
/// `default_face_clearance`, `kClearanceFaceSlabDepthDefaultMm`) — the same kind of
/// deliberate app/core duplication as the infill knockdown curve. KEEP IN SYNC: if
/// the core defaults change, change these too, or the label lies about the run.
///
/// The 0-sentinel wire protocol is unchanged: an un-overridden distance is still
/// sent as 0 and the core re-derives it. These values exist ONLY so the app can
/// DISPLAY the real number instead of the word "auto", now that the bore radius
/// crosses the bridge.
public enum ClearanceSuggestion {
    /// Bounded-slab default depth (mm) — `kClearanceFaceSlabDepthDefaultMm`.
    public static let faceSlabDepthMM: Double = 3.0

    /// Bolt concentric margin (mm): the bore radius → keep-out Ø ≈ 2× hole Ø.
    public static func boltMarginMM(boreRadiusMM: Double) -> Double { boreRadiusMM }

    /// Bolt axial clearance (mm): the bore diameter out each side.
    public static func boltAxialMM(boreRadiusMM: Double) -> Double { 2.0 * boreRadiusMM }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Basis + outline helpers

/// A right-handed orthonormal (u, v) basis spanning the plane whose normal is `n`.
/// Deterministic: picks the world axis least aligned with `n` as the seed so the
/// basis is stable for axis-aligned mounting faces. `n` is assumed ~unit.
public func planeBasis(normal n: SIMD3<Float>) -> (u: SIMD3<Float>, v: SIMD3<Float>) {
    let a = abs(n)
    // Seed with the world axis MOST orthogonal to n (smallest |component|).
    let seed: SIMD3<Float>
    if a.x <= a.y && a.x <= a.z { seed = SIMD3<Float>(1, 0, 0) }
    else if a.y <= a.z { seed = SIMD3<Float>(0, 1, 0) }
    else { seed = SIMD3<Float>(0, 0, 1) }
    var u = seed - n * simd_dot(seed, n)
    let lu = simd_length(u)
    u = lu > 1e-6 ? u / lu : SIMD3<Float>(1, 0, 0)
    let v = simd_normalize(simd_cross(n, u))
    return (u, v)
}

/// A planar face's in-plane bounding rectangle (the slab footprint) — the same
/// "tessellation's in-plane extent" the core's bounded slab extrudes (handoff 100
/// noted this is the bounding rectangle, not the exact polygon; matched here).
public struct PlaneOutline: Equatable, Sendable {
    public let center: SIMD3<Float>
    public let uAxis: SIMD3<Float>
    public let vAxis: SIMD3<Float>
    public let halfU: Float
    public let halfV: Float
    public init(center: SIMD3<Float>, uAxis: SIMD3<Float>, vAxis: SIMD3<Float>,
                halfU: Float, halfV: Float) {
        self.center = center
        self.uAxis = uAxis
        self.vAxis = vAxis
        self.halfU = halfU
        self.halfV = halfV
    }

    /// Fit an outline to a set of in-plane points, given the plane normal + a point
    /// on the plane. Projects each point onto a `planeBasis(normal)`; the rectangle
    /// is centred at the projected-extent midpoint (lifted back onto the plane).
    /// Nil for no points.
    public static func fit(points: [SIMD3<Float>], normal: SIMD3<Float>,
                           origin: SIMD3<Float>) -> PlaneOutline? {
        guard !points.isEmpty else { return nil }
        let n = simd_length(normal) > 1e-6 ? simd_normalize(normal) : SIMD3<Float>(0, 0, 1)
        let (u, v) = planeBasis(normal: n)
        var loU = Float.greatestFiniteMagnitude, hiU = -Float.greatestFiniteMagnitude
        var loV = Float.greatestFiniteMagnitude, hiV = -Float.greatestFiniteMagnitude
        for p in points {
            let d = p - origin
            let su = simd_dot(d, u), sv = simd_dot(d, v)
            loU = Swift.min(loU, su); hiU = Swift.max(hiU, su)
            loV = Swift.min(loV, sv); hiV = Swift.max(hiV, sv)
        }
        let midU = (loU + hiU) * 0.5, midV = (loV + hiV) * 0.5
        // Centre the rectangle on the plane at the projected midpoint.
        let center = origin + u * midU + v * midV
        return PlaneOutline(center: center, uAxis: u, vAxis: v,
                            halfU: (hiU - loU) * 0.5, halfV: (hiV - loV) * 0.5)
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - The clearance volume

/// The TRUE 3D region one clearance occupies, in model space — built from the
/// exact B-rep geometry, so it is the volume the run actually keeps clear.
public struct ClearanceVolume: Equatable, Sendable {
    public enum Shape: Equatable, Sendable {
        /// Swept cylinder about the ray `axisPoint + t·axisDir` (axisDir unit), for
        /// `t ∈ [tLo, tHi]`, of radius `radiusMM` (= bore radius + concentric margin).
        case cylinder(axisPoint: SIMD3<Float>, axisDir: SIMD3<Float>,
                      radiusMM: Float, tLo: Float, tHi: Float)
        /// Bounded slab: the rectangle centred at `center` with in-plane half-extents
        /// `halfU·uAxis` and `halfV·vAxis`, extruded OUTWARD along `normal` by `depthMM`.
        case slab(center: SIMD3<Float>, normal: SIMD3<Float>,
                  uAxis: SIMD3<Float>, vAxis: SIMD3<Float>,
                  halfU: Float, halfV: Float, depthMM: Float)
        /// A no-op region: a Bolt on a non-cylinder face, or a region that resolved
        /// to nothing. Rendered hollow/dashed with "no effect" wording — the picture
        /// must not promise what the run won't do (degenerate honesty).
        case degenerate
    }

    /// The B-rep face the region is built from.
    public let faceID: Int
    /// Which keep-out this is (bolt swept cylinder / face bounded slab).
    public let kind: TopOptKit.ClearanceKind
    public let shape: Shape

    public init(faceID: Int, kind: TopOptKit.ClearanceKind, shape: Shape) {
        self.faceID = faceID
        self.kind = kind
        self.shape = shape
    }

    public var isDegenerate: Bool { if case .degenerate = shape { return true }; return false }

    /// A swept-cylinder bolt clearance from a bore's exact geometry. `axialSpan` is
    /// the bore's through-part extent along the axis (t=0 at `geometry.axisPoint`),
    /// from the SAME tessellation the core reads. `marginMM`/`axialMM` are the
    /// RESOLVED distances (the user override, or the Auto suggestion). Degenerate if
    /// the face is not a cylinder (a safe no-op the core also produces).
    public static func bolt(faceID: Int, geometry: StepFaceGeometry,
                            axialSpan: (lo: Float, hi: Float)?,
                            marginMM: Double, axialMM: Double) -> ClearanceVolume {
        guard geometry.isCylinder, let span = axialSpan,
              simd_length(SIMD3<Float>(geometry.axisDir)) > 1e-6 else {
            return ClearanceVolume(faceID: faceID, kind: .bolt, shape: .degenerate)
        }
        let radius = Float(geometry.cylinderRadiusMM + Swift.max(0, marginMM))
        let axial = Float(Swift.max(0, axialMM))
        return ClearanceVolume(faceID: faceID, kind: .bolt, shape: .cylinder(
            axisPoint: SIMD3<Float>(geometry.axisPoint),
            axisDir: simd_normalize(SIMD3<Float>(geometry.axisDir)),
            radiusMM: radius, tLo: span.lo - axial, tHi: span.hi + axial))
    }

    /// A bounded-slab face clearance from a plane's exact geometry + its outline.
    /// `depthMM` is the RESOLVED depth. Degenerate if the face is not a plane.
    public static func slab(faceID: Int, geometry: StepFaceGeometry,
                            outline: PlaneOutline?, depthMM: Double) -> ClearanceVolume {
        guard geometry.isPlane, let o = outline,
              simd_length(SIMD3<Float>(geometry.planeNormal)) > 1e-6 else {
            return ClearanceVolume(faceID: faceID, kind: .face, shape: .degenerate)
        }
        return ClearanceVolume(faceID: faceID, kind: .face, shape: .slab(
            center: o.center, normal: simd_normalize(SIMD3<Float>(geometry.planeNormal)),
            uAxis: o.uAxis, vAxis: o.vAxis, halfU: o.halfU, halfV: o.halfV,
            depthMM: Float(Swift.max(0, depthMM))))
    }
}

/// A clearance volume tagged for the viewport render (keep-clear v2 Part 3): the
/// true region + whether its group is selected (brightened). Equatable so the
/// MetalMeshView coordinator only re-tessellates when the set changes.
public struct ClearanceRenderItem: Equatable, Sendable {
    public let volume: ClearanceVolume
    public let selected: Bool
    public init(volume: ClearanceVolume, selected: Bool) {
        self.volume = volume
        self.selected = selected
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Drag-handle math (Phase B — pure; the gesture wiring is device QA)

/// Screen-ray → clearance-parameter math for the drag handles. A gesture converts
/// a touch into a world-space ray (camera → through the touch point); THESE turn
/// that ray into the mm value the handle should write. Pure and headless-tested;
/// the hit-testing + ray construction that feed them are the device-QA'd layer.
public enum ClearanceDragMath {

    /// The point on line `L(s) = point + s·dir` (dir unit) closest to the ray
    /// `R(t) = origin + t·rayDir` (rayDir unit), returned as the axis parameter `s`
    /// (mm along `dir`). Robust to the parallel case (falls back to the foot of
    /// `origin` on the axis). Nil only for a zero direction.
    public static func closestAxisParam(rayOrigin: SIMD3<Float>, rayDir: SIMD3<Float>,
                                        point: SIMD3<Float>, dir: SIMD3<Float>) -> Float? {
        let lr = simd_length(rayDir), la = simd_length(dir)
        guard lr > 1e-6, la > 1e-6 else { return nil }
        let u = rayDir / lr, v = dir / la
        let w0 = rayOrigin - point
        let b = simd_dot(u, v)
        let d = simd_dot(u, w0)
        let e = simd_dot(v, w0)
        let denom = 1 - b * b            // a = c = 1 (both unit)
        if denom < 1e-6 { return e }     // parallel: foot of rayOrigin on the axis
        return (e - b * d) / denom       // s: axis param of closest approach
    }

    /// The minimum distance between the drag ray and the axis line (mm) — the radius
    /// the cylinder wall would need to be tangent to the ray. Nil for a zero dir.
    public static func rayAxisDistance(rayOrigin: SIMD3<Float>, rayDir: SIMD3<Float>,
                                       point: SIMD3<Float>, dir: SIMD3<Float>) -> Float? {
        let lr = simd_length(rayDir), la = simd_length(dir)
        guard lr > 1e-6, la > 1e-6 else { return nil }
        let u = rayDir / lr, v = dir / la
        let w0 = rayOrigin - point
        let cross = simd_cross(u, v)
        let lc = simd_length(cross)
        if lc < 1e-6 {                       // parallel: perpendicular part of w0
            return simd_length(w0 - v * simd_dot(w0, v))
        }
        return abs(simd_dot(w0, cross / lc))
    }

    /// RADIAL drag on a cylinder wall → the new concentric MARGIN (mm): where the
    /// ray grazes, minus the bore radius, clamped ≥ 0. Nil for a zero dir.
    public static func radialMargin(rayOrigin: SIMD3<Float>, rayDir: SIMD3<Float>,
                                    axisPoint: SIMD3<Float>, axisDir: SIMD3<Float>,
                                    boreRadiusMM: Float) -> Float? {
        guard let dist = rayAxisDistance(rayOrigin: rayOrigin, rayDir: rayDir,
                                         point: axisPoint, dir: axisDir) else { return nil }
        return Swift.max(0, dist - boreRadiusMM)
    }

    /// AXIAL drag on an end cap → the new axial CLEARANCE (mm): the distance from the
    /// bore's tessellation end (`boreEndT`, t of that end) to where the drag lands
    /// along the axis, clamped ≥ 0. `outward > 0` for the +axis cap (t increasing),
    /// `< 0` for the −axis cap. Nil for a zero dir.
    public static func axialClearance(rayOrigin: SIMD3<Float>, rayDir: SIMD3<Float>,
                                      axisPoint: SIMD3<Float>, axisDir: SIMD3<Float>,
                                      boreEndT: Float, outward: Float) -> Float? {
        guard let s = closestAxisParam(rayOrigin: rayOrigin, rayDir: rayDir,
                                       point: axisPoint, dir: axisDir) else { return nil }
        let signed = (s - boreEndT) * (outward >= 0 ? 1 : -1)
        return Swift.max(0, signed)
    }

    /// NORMAL drag on a slab's outer face → the new slab DEPTH (mm): how far along the
    /// outward normal (from the plane origin) the drag lands, clamped ≥ 0. Nil for a
    /// zero dir.
    public static func slabDepth(rayOrigin: SIMD3<Float>, rayDir: SIMD3<Float>,
                                 planeOrigin: SIMD3<Float>, planeNormal: SIMD3<Float>) -> Float? {
        guard let s = closestAxisParam(rayOrigin: rayOrigin, rayDir: rayDir,
                                       point: planeOrigin, dir: planeNormal) else { return nil }
        return Swift.max(0, s)
    }
}
