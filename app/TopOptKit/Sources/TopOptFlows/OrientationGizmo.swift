// OrientationGizmo.swift — the pure geometry behind the liquid-glass orientation widget
// (the orientation-gizmo-redesign task; ports docs/design/gizmo_redesign.html).
//
// The gizmo is a raymarched SDF "liquid glass" cube that mirrors the shared camera's
// orientation and, when a region is tapped, snaps the camera to that canonical view. The
// design mock builds the picture (a WebGL fragment shader) AND the hit-testing (a JS SDF
// mirror) from ONE set of geometry constants — the picture and the picking are the same
// geometry, never two hand-tuned copies. This port keeps that property:
//
//   * `GizmoConstants` is that ONE source of numbers. `OrientationGizmoMetal` interpolates
//     it into the Metal shader source (exactly as the mock interpolates `CFG` into its
//     GLSL); the picker below evaluates the SAME constants on the CPU. Change a number once
//     and both the render and the hit-test move together.
//   * `pick` ray-marches a tap through the same rotation the widget renders with and reads
//     back which SDF cell (centre / 6 faces / 12 edges / 8 corners) the ray entered — the
//     shader's `globalId` classification, mirrored on the CPU.
//   * the 26 clickable REGIONS and the canonical (azimuth, elevation) each maps to are
//     unchanged from the previous gizmo, so a snap is still an exact round-trip with
//     `OrbitCamera`, and the shared-camera behaviour is preserved.
//
// This math is headlessly tested (the M7 /app/ standard) and is verified independently by a
// C++ oracle (Testing/gizmo_pick_oracle.cpp) that mirrors the mock's JS byte-for-byte. The
// SwiftUI/Metal drawing + gestures (OrientationGizmoView / OrientationGizmoMetal) are device
// QA, so they live apart.

import Foundation
import simd

// MARK: - Shared geometry constants (the ONE source; shader + picker both read these)

/// The liquid-glass gizmo's SDF geometry constants — a verbatim port of the mock's `CFG`
/// object. This is the SINGLE source of the numbers: `OrientationGizmoMetal.shaderSource`
/// interpolates them into the Metal fragment shader, and the CPU picker below evaluates the
/// same values, so the drawn glass and the tappable geometry can never diverge.
///
/// Fields keep the mock's names (a `_C` centre, `_R`/`_N`/`_T`/`_L` radii, `KCELL`/`KLOBE`
/// weld softness, `GROOVE` seam carve, plus the virtual camera `FOV`/`CAMZ`). See the mock
/// for the meaning of each blob; they are tuned together and are not meant to be edited in
/// isolation.
public struct GizmoConstants: Equatable, Sendable {
    public var kCell: Float = 0.09      // crisper welds between the eight cells
    public var kLobe: Float = 0.095     // softness within a cell's lobes
    public var centerR: Float = 0.72    // the frosted core sphere

    public var faceC: Float = 0.80, faceN: Float = 0.38, faceT: Float = 0.92
    public var fshC: Float = 0.80, fshD: Float = 0.68, fshR1: Float = 0.20, fshR2: Float = 0.34
    public var emC: Float = 0.92, emR: Float = 0.18, emL: Float = 0.74
    public var efIn: Float = 0.86, efR: Float = 0.18, efL: Float = 0.62
    public var cnC: Float = 0.885, cnR: Float = 0.22
    public var clIn: Float = 0.70
    public var clR: SIMD3<Float> = SIMD3<Float>(0.13, 0.14, 0.16)

    public var groove: Float = 0.045    // seam depth
    public var grooveW: Float = 0.085   // seam width (narrow → tight compression lines)

    public var fov: Float = 38          // virtual camera vertical FOV (degrees)
    public var camZ: Float = 9.25       // virtual camera distance on +Z

    public init() {}

    /// The canonical constants used everywhere (render + pick). Both sides read THIS.
    public static let standard = GizmoConstants()
}

// MARK: - Regions (the 26 canonical views — unchanged mapping)

/// One clickable region of the orientation cube: a face, edge, or corner. `anchor` has each
/// component in {-1, 0, +1} — the count of non-zero components is the kind (1 = face,
/// 2 = edge, 3 = corner) and their signs place it on the cube. `direction` (the normalized
/// anchor) is the unit eye-direction of the canonical view: the camera looks at the model
/// FROM there.
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

/// What a tap resolved to: a region, the Home target (the frosted core sphere / Home button),
/// or nothing (the tap fell in the margin around the floating gizmo).
public enum GizmoPick: Equatable, Sendable {
    case region(GizmoRegion)
    case home
    case miss
}

public enum OrientationGizmo {
    /// Model-axis face names. +Z faces the viewer at the default front view (the camera eye
    /// sits on +Z and looks down −Z), so +Z is "Front"; +Y up is "Top"; +X is "Right" —
    /// matching how `OrbitCamera`'s canonical views are defined.
    private static func faceName(axis: Int, positive: Bool) -> String {
        switch (axis, positive) {
        case (0, true): return "Right"; case (0, false): return "Left"
        case (1, true): return "Top";   case (1, false): return "Bottom"
        default:        return positive ? "Front" : "Back"   // axis 2 (Z)
        }
    }

    /// All 26 regions: the 6 faces first (labeled), then the 12 edges, then the 8 corners.
    /// Built once from every {-1,0,1}³ anchor except the origin.
    public static let regions: [GizmoRegion] = buildRegions()

    /// The 6 face regions, in axis order (Right, Left, Top, Bottom, Front, Back).
    public static var faces: [GizmoRegion] { regions.filter { $0.kind == .face } }

    /// Look up a region by its id (e.g. "Front", "Top-Right", "Front-Top-Right").
    public static func region(_ id: String) -> GizmoRegion? { regions.first { $0.id == id } }

    /// Look up a region by its {-1,0,1}³ anchor.
    public static func region(anchor: SIMD3<Float>) -> GizmoRegion? {
        regions.first { $0.anchor == anchor }
    }

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

    /// The shader's `globalId` for a region anchor — the numeric 0…26 cell id the Metal pass
    /// uses to light a hovered cell. The view passes this as the renderer's `hoverId` so the
    /// glow lands on the same cell the CPU picked. Mirrors `globalId` in the MSL.
    public static let homeNumericId: Float = 0
    public static func numericId(anchor a: SIMD3<Float>) -> Float {
        func b(_ v: Float) -> Float { v > 0 ? 0 : 1 }
        let nz = (a.x != 0 ? 1 : 0) + (a.y != 0 ? 1 : 0) + (a.z != 0 ? 1 : 0)
        switch nz {
        case 1:
            if a.x != 0 { return 1 + b(a.x) }
            if a.y != 0 { return 3 + b(a.y) }
            return 5 + b(a.z)
        case 2:
            if a.z == 0 { return 7  + b(a.x) * 2 + b(a.y) }   // XY edge
            if a.x == 0 { return 11 + b(a.y) * 2 + b(a.z) }   // YZ edge
            return 15 + b(a.z) * 2 + b(a.x)                    // ZX edge
        default:
            return 19 + b(a.x) * 4 + b(a.y) * 2 + b(a.z)      // corner
        }
    }

    // MARK: - Hit-testing (raymarch the tap through the SDF, read back its cell)

    /// Resolve a tap to a region, or nil when the tap misses the cube OR lands on the Home
    /// core. `point` is in the gizmo view's coordinates (top-left origin, y down); `size` is
    /// that view's size; `rotation` is the camera's `viewRotation()` (the SAME transform the
    /// widget draws with, so the tap lands where the user sees the glass).
    ///
    /// Home-vs-nil is intentionally collapsed here so the existing behaviour (this returns a
    /// snap target or nothing) is preserved and the headless region tests are unchanged; the
    /// view calls `pick` directly when it wants to route a core tap to Home.
    public static func hitTest(point: CGPoint, in size: CGSize,
                               rotation: simd_float3x3) -> GizmoRegion? {
        if case let .region(r) = pick(point: point, in: size, rotation: rotation) { return r }
        return nil
    }

    /// The full pick: ray-march the tap through the SDF and classify the entry cell into a
    /// region, the Home core, or a miss. This is the CPU mirror of the shader's raymarch +
    /// `globalId`, using the SAME `GizmoConstants`.
    ///
    /// Method (a verbatim port of the mock's `pickId`): the widget is a perspective camera on
    /// +Z (`CAMZ`) looking down −Z. The tap is a ray at (ndc·tan(FOV/2)); transform camera +
    /// ray into model space by Rᵀ (R is the orthonormal world→view rotation), sphere-trace the
    /// SDF, and at the hit read which of the 8 cells is nearest — its sign bits place the
    /// face/edge/corner.
    public static func pick(point: CGPoint, in size: CGSize,
                            rotation: simd_float3x3,
                            constants: GizmoConstants = .standard) -> GizmoPick {
        guard size.width > 0, size.height > 0 else { return .miss }
        let c = constants
        let ux = Float((point.x / size.width) * 2 - 1)
        let uy = Float(1 - (point.y / size.height) * 2)          // flip to y-up
        let tf = tanf(c.fov * 0.5 * .pi / 180)

        // Ray in the virtual camera's (view) space, then into model space via Rᵀ.
        let roW = SIMD3<Float>(0, 0, c.camZ)
        let rdW = simd_normalize(SIMD3<Float>(ux * tf, uy * tf, -1))
        let rt = rotation.transpose                              // view → model
        let ro = rt * roW
        let rd = simd_normalize(rt * rdW)

        var t = c.camZ - 3.0
        for _ in 0..<pickSteps {
            let p = ro + rd * t
            let d = map(p, c)
            if d < 0.003 {
                let cell = nearestCell(p, c)
                return classify(cell: cell, at: p)
            }
            t += d * 0.7                                         // matches the shader step
            if t > c.camZ + 3.0 { break }
        }
        return .miss
    }

    /// Raymarch step budget for picking. One-off (a single tap), so it can afford the mock's
    /// full 72 without any per-frame cost; the render pass caps its own steps separately.
    static let pickSteps = 72

    /// Map a winning cell index + hit point to a `GizmoPick`. Cell 0 is the Home core; cells
    /// 1–7 are the face/edge/corner groups whose sign bits (from the hit position) select the
    /// specific anchor — the CPU form of the shader's `globalId`.
    private static func classify(cell: Int, at p: SIMD3<Float>) -> GizmoPick {
        if cell == 0 { return .home }
        func s(_ v: Float) -> Float { v > 0 ? 1 : -1 }
        var a = SIMD3<Float>(0, 0, 0)
        switch cell {
        case 1: a.x = s(p.x)                                     // ±X face
        case 2: a.y = s(p.y)                                     // ±Y face
        case 3: a.z = s(p.z)                                     // ±Z face
        case 4: a.x = s(p.x); a.y = s(p.y)                       // XY edge
        case 5: a.y = s(p.y); a.z = s(p.z)                       // YZ edge
        case 6: a.x = s(p.x); a.z = s(p.z)                       // ZX edge
        default: a = SIMD3<Float>(s(p.x), s(p.y), s(p.z))        // corner
        }
        return region(anchor: a).map(GizmoPick.region) ?? .miss
    }

    // MARK: - The SDF (CPU mirror of the shader; both read `GizmoConstants`)

    /// The eight cell distances at `p`: [0] the core sphere, [1…3] the ±X/±Y/±Z face blobs,
    /// [4…6] the XY/YZ/ZX edge blobs, [7] the corner blobs. A verbatim port of the mock's
    /// `cellDistsJS`.
    static func cellDists(_ p: SIMD3<Float>, _ c: GizmoConstants) -> [Float] {
        let q = simd_abs(p)
        var dc = [Float](repeating: 0, count: 8)
        dc[0] = simd_length(p) - c.centerR

        var fx = sdEll(q, SIMD3(c.faceC, 0, 0), SIMD3(c.faceN, c.faceT, c.faceT))
        fx = smin(fx, sdEll(q, SIMD3(c.fshC, c.fshD, c.fshD), SIMD3(c.fshR1, c.fshR2, c.fshR2)), c.kLobe)
        var fy = sdEll(q, SIMD3(0, c.faceC, 0), SIMD3(c.faceT, c.faceN, c.faceT))
        fy = smin(fy, sdEll(q, SIMD3(c.fshD, c.fshC, c.fshD), SIMD3(c.fshR2, c.fshR1, c.fshR2)), c.kLobe)
        var fz = sdEll(q, SIMD3(0, 0, c.faceC), SIMD3(c.faceT, c.faceT, c.faceN))
        fz = smin(fz, sdEll(q, SIMD3(c.fshD, c.fshD, c.fshC), SIMD3(c.fshR2, c.fshR2, c.fshR1)), c.kLobe)
        dc[1] = fx; dc[2] = fy; dc[3] = fz

        var exy = sdEll(q, SIMD3(c.emC, c.emC, 0), SIMD3(c.emR, c.emR, c.emL))
        exy = smin(exy, sdEll(q, SIMD3(c.efIn, 1, 0), SIMD3(c.efR, c.efR, c.efL)), c.kLobe)
        exy = smin(exy, sdEll(q, SIMD3(1, c.efIn, 0), SIMD3(c.efR, c.efR, c.efL)), c.kLobe)
        var eyz = sdEll(q, SIMD3(0, c.emC, c.emC), SIMD3(c.emL, c.emR, c.emR))
        eyz = smin(eyz, sdEll(q, SIMD3(0, c.efIn, 1), SIMD3(c.efL, c.efR, c.efR)), c.kLobe)
        eyz = smin(eyz, sdEll(q, SIMD3(0, 1, c.efIn), SIMD3(c.efL, c.efR, c.efR)), c.kLobe)
        var ezx = sdEll(q, SIMD3(c.emC, 0, c.emC), SIMD3(c.emR, c.emL, c.emR))
        ezx = smin(ezx, sdEll(q, SIMD3(c.efIn, 0, 1), SIMD3(c.efR, c.efL, c.efR)), c.kLobe)
        ezx = smin(ezx, sdEll(q, SIMD3(1, 0, c.efIn), SIMD3(c.efR, c.efL, c.efR)), c.kLobe)
        dc[4] = exy; dc[5] = eyz; dc[6] = ezx

        var co = simd_length(q - SIMD3(c.cnC, c.cnC, c.cnC)) - c.cnR
        co = smin(co, sdEll(q, SIMD3(c.clIn, 1, 1), SIMD3(c.clR.x * 1.5, c.clR.x, c.clR.x)), c.kLobe)
        co = smin(co, sdEll(q, SIMD3(1, c.clIn, 1), SIMD3(c.clR.y, c.clR.y * 1.5, c.clR.y)), c.kLobe)
        co = smin(co, sdEll(q, SIMD3(1, 1, c.clIn), SIMD3(c.clR.z, c.clR.z, c.clR.z * 1.5)), c.kLobe)
        dc[7] = co
        return dc
    }

    /// The unioned surface distance at `p` (smin of the eight cells + the junction groove
    /// carve). A verbatim port of the mock's `mapJS`.
    static func map(_ p: SIMD3<Float>, _ c: GizmoConstants) -> Float {
        let dc = cellDists(p, c)
        var d = dc[0], m1 = dc[0], m2: Float = 1e9
        for i in 1..<8 {
            d = smin(d, dc[i], c.kCell)
            if dc[i] < m1 { m2 = m1; m1 = dc[i] }
            else if dc[i] < m2 { m2 = dc[i] }
        }
        let s = min(max((m2 - m1) / c.grooveW, 0), 1)
        return d + c.groove * (1 - s * s * (3 - 2 * s))          // same smoothstep as the shader
    }

    /// Index of the nearest cell at `p` (the shader's `i1`).
    private static func nearestCell(_ p: SIMD3<Float>, _ c: GizmoConstants) -> Int {
        let dc = cellDists(p, c)
        var d1 = Float.greatestFiniteMagnitude, i1 = 0
        for i in 0..<8 where dc[i] < d1 { d1 = dc[i]; i1 = i }
        return i1
    }

    /// Softmin (quadratic) — the mock's `smin`.
    private static func smin(_ a: Float, _ b: Float, _ k: Float) -> Float {
        let h = min(max(0.5 + 0.5 * (b - a) / k, 0), 1)
        return b * (1 - h) + a * h - k * h * (1 - h)
    }

    /// Approximate ellipsoid SDF — the mock's `sdEll`.
    private static func sdEll(_ p: SIMD3<Float>, _ c: SIMD3<Float>, _ r: SIMD3<Float>) -> Float {
        let q = (p - c) / r
        let k0 = simd_length(q)
        let k1 = simd_length(q / r)
        return k0 * (k0 - 1) / max(k1, 1e-4)
    }
}
