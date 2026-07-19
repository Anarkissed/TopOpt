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

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Drag-handle anchors (Phase B — pure; the touch layer is device QA)

/// One projected drag handle on a clearance volume: WHERE the grab knob sits (a
/// point in the volume's frame) plus the fixed bore/plane geometry the value math
/// needs. The workspace projects `anchor` to the screen for a ~44pt hit target,
/// then routes a pan through `value(rayOrigin:rayDir:)` with the per-frame camera
/// ray. A cylinder gets a WALL handle (radial → margin) and one handle per END CAP
/// (axial → clearance length); a slab gets one FACE handle (normal → depth).
///
/// Pure value type on simd scalars: the anchor placement, the settled-space
/// transform, and the value dispatch are all headlessly unit-tested. The SwiftUI
/// gesture that grabs a handle and feeds it a ray is the device-QA'd layer.
public struct ClearanceHandle: Equatable, Sendable {
    public enum Role: Equatable, Sendable {
        /// Cylinder wall — radial drag sets the concentric MARGIN.
        case margin
        /// −axis end cap — axial drag sets the axial CLEARANCE on the low side.
        case axialLo
        /// +axis end cap — axial drag sets the axial CLEARANCE on the high side.
        case axialHi
        /// Slab outer face — normal drag sets the slab DEPTH.
        case slabDepth
    }

    /// The kind of value this handle writes.
    public let role: Role
    /// Where the grab knob sits, in the volume's frame (model space when built from
    /// a `ClearanceVolume`; settled-world after `settled(center:rotation:)`).
    public let anchor: SIMD3<Float>
    // The fixed geometry the value math reads (same frame as `anchor`). Only the
    // fields the role needs are populated; the rest stay zero.
    public let axisPoint: SIMD3<Float>
    public let axisDir: SIMD3<Float>
    public let boreRadiusMM: Float
    public let boreEndT: Float
    public let outward: Float
    public let planeOrigin: SIMD3<Float>
    public let planeNormal: SIMD3<Float>

    public init(role: Role, anchor: SIMD3<Float>,
                axisPoint: SIMD3<Float> = .zero, axisDir: SIMD3<Float> = .zero,
                boreRadiusMM: Float = 0, boreEndT: Float = 0, outward: Float = 0,
                planeOrigin: SIMD3<Float> = .zero, planeNormal: SIMD3<Float> = .zero) {
        self.role = role
        self.anchor = anchor
        self.axisPoint = axisPoint
        self.axisDir = axisDir
        self.boreRadiusMM = boreRadiusMM
        self.boreEndT = boreEndT
        self.outward = outward
        self.planeOrigin = planeOrigin
        self.planeNormal = planeNormal
    }

    /// This handle rigidly re-posed into settled-WORLD space (rotation about the mesh
    /// `center`, the same settle transform the render applies), so the value math can
    /// run against a WORLD-space drag ray. A rigid transform preserves distances and
    /// axis parameters, so the returned mm equals the model-space mm — `boreRadiusMM`,
    /// `boreEndT` and `outward` are unchanged; only points/directions rotate.
    public func settled(center: SIMD3<Float>, rotation: simd_quatf) -> ClearanceHandle {
        func p(_ x: SIMD3<Float>) -> SIMD3<Float> { center + rotation.act(x - center) }
        func d(_ x: SIMD3<Float>) -> SIMD3<Float> { rotation.act(x) }
        return ClearanceHandle(role: role, anchor: p(anchor),
                               axisPoint: p(axisPoint), axisDir: d(axisDir),
                               boreRadiusMM: boreRadiusMM, boreEndT: boreEndT, outward: outward,
                               planeOrigin: p(planeOrigin), planeNormal: d(planeNormal))
    }

    /// The new clearance mm this handle should write for a drag ray, in the SAME frame
    /// as the handle's geometry (dispatches to `ClearanceDragMath` by role). Nil for a
    /// zero ray direction. This is the pure value-write path the drag tests exercise.
    public func value(rayOrigin: SIMD3<Float>, rayDir: SIMD3<Float>) -> Float? {
        switch role {
        case .margin:
            return ClearanceDragMath.radialMargin(rayOrigin: rayOrigin, rayDir: rayDir,
                axisPoint: axisPoint, axisDir: axisDir, boreRadiusMM: boreRadiusMM)
        case .axialLo, .axialHi:
            return ClearanceDragMath.axialClearance(rayOrigin: rayOrigin, rayDir: rayDir,
                axisPoint: axisPoint, axisDir: axisDir, boreEndT: boreEndT, outward: outward)
        case .slabDepth:
            return ClearanceDragMath.slabDepth(rayOrigin: rayOrigin, rayDir: rayDir,
                planeOrigin: planeOrigin, planeNormal: planeNormal)
        }
    }
}

public enum ClearanceHandles {
    /// The drag-handle anchors for a resolved clearance volume. `boreRadiusMM` and
    /// `axialSpan` are the FIXED bore facts the cylinder handles need (the bore's own
    /// geometry — not the current resolved distances, which move as the user drags),
    /// so the value math measures against a stable reference. A `.degenerate` volume
    /// gets NO handles (there is nothing to drag — degenerate honesty).
    public static func handles(for volume: ClearanceVolume,
                               boreRadiusMM: Float,
                               axialSpan: (lo: Float, hi: Float)?) -> [ClearanceHandle] {
        switch volume.shape {
        case let .cylinder(axisPoint, axisDir, radiusMM, tLo, tHi):
            let dir = simd_length(axisDir) > 1e-6 ? simd_normalize(axisDir) : SIMD3<Float>(0, 0, 1)
            let (u, _) = planeBasis(normal: dir)
            let mid = axisPoint + dir * (tLo + tHi) * 0.5
            // Wall handle: on the cylinder wall at mid-length, out along a deterministic
            // in-plane axis. Radial drag → new margin (measured from the bore radius).
            var out: [ClearanceHandle] = [
                ClearanceHandle(role: .margin, anchor: mid + u * radiusMM,
                                axisPoint: axisPoint, axisDir: dir, boreRadiusMM: boreRadiusMM)
            ]
            // End-cap handle: ONE per cylinder (device round 3, item 9 — was one per cap). The
            // axial CLEARANCE is a single value applied to BOTH ends (`tLo = span.lo − axial`,
            // `tHi = span.hi + axial`), so a second cap icon was redundant. Keep the +axis (hi)
            // end, measuring from the FIXED bore tessellation end so the value is stable; the
            // drag math already resolves the same axial mm from either end.
            if let span = axialSpan {
                out.append(ClearanceHandle(role: .axialHi, anchor: axisPoint + dir * tHi,
                    axisPoint: axisPoint, axisDir: dir, boreEndT: span.hi, outward: 1))
            }
            return out
        case let .slab(center, normal, _, _, _, _, depthMM):
            let n = simd_length(normal) > 1e-6 ? simd_normalize(normal) : SIMD3<Float>(0, 0, 1)
            // Face handle: at the current outer face centre; normal drag → new depth,
            // measured from the plane (`center` lies on it, so it is the plane origin).
            return [ClearanceHandle(role: .slabDepth, anchor: center + n * depthMM,
                                    planeOrigin: center, planeNormal: n)]
        case .degenerate:
            return []
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Precision scrub (Shapr3D-style: slower finger → finer step)

/// Maps a horizontal scrub delta (points) to a clearance mm increment, with a
/// speed-dependent gain: a slow finger takes fine steps, a fast flick takes coarse
/// ones. Pure and headless-tested; the SwiftUI pill that accumulates the deltas is
/// device QA. Values are mm-per-point so the same curve serves the margin, axial
/// and slab pills.
public enum ClearanceScrub {
    /// mm per point when the finger is (near) still — the fine end.
    public static let fineStepMMPerPoint: Float = 0.01
    /// mm per point at full flick speed — the coarse end.
    public static let coarseStepMMPerPoint: Float = 0.25
    /// |delta| (points, per drag update) at which the gain is fully coarse.
    public static let coarseSpeedPoints: Float = 16

    /// The mm increment for one drag update of `deltaPoints` (this frame's dx). The
    /// gain lerps from fine (slow) to coarse (fast) by the update's speed; the sign
    /// follows the drag direction.
    public static func increment(deltaPoints: Float) -> Float {
        let speed = abs(deltaPoints)
        let t = Swift.min(1, speed / coarseSpeedPoints)         // 0 slow → 1 fast
        let step = fineStepMMPerPoint + (coarseStepMMPerPoint - fineStepMMPerPoint) * t
        return deltaPoints * step
    }

    /// Apply one scrub update to `value` (mm), clamped ≥ 0.
    public static func scrub(value: Float, deltaPoints: Float) -> Float {
        Swift.max(0, value + increment(deltaPoints: deltaPoints))
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Distance quantization (device round 3, item 12)

/// Snaps clearance distances to a fixed grid. Scrub AND handle-drag quantize LIVE (the emitted
/// value is snapped every update, so the number ticks in whole steps as you drag); a typed value
/// rounds to the nearest step on commit. Auto is never quantized — it carries no explicit value,
/// so the caller only ever snaps a real number, and `onSet(nil)` (revert to Auto) is untouched.
/// Pure + headless-tested; the pill/gesture that call it are device QA.
public enum ClearanceQuantize {
    /// The distance grid: margin / axial / depth land on 0.25 mm steps.
    public static let stepMM: Double = 0.25

    /// Round `mm` to the nearest `step` (default 0.25 mm), never below 0.
    public static func snap(_ mm: Double, step: Double = stepMM) -> Double {
        guard step > 0 else { return Swift.max(0, mm) }
        return Swift.max(0, (mm / step).rounded() * step)
    }
    /// Float overload for the scrub / handle-drag paths (same grid).
    public static func snap(_ mm: Float, step: Float = Float(stepMM)) -> Float {
        guard step > 0 else { return Swift.max(0, mm) }
        return Swift.max(0, (mm / step).rounded() * step)
    }
}
