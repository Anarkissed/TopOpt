// FlexibleKit+Meet — which faces meet, as CORE answers it (task 2026-10-07, angled presses, batch AP2;
// final spec §5 "FlexibleMeet", §6 "Core's inward normals"). Swift wrappers over three thin bridge
// pass-throughs (FlexibleBridge.hpp), each run under bridge.cpp's one guard: a core throw arrives here as
// a thrown TopOptError carrying core's words, never as a crash.
//
// ★ ONE SOURCE: CORE. These carry core's numbers and nothing else:
//   * `faceAdjacency()` — core's face_adjacency (welded mesh edges), the whole-face authority;
//   * `regionFrame(_:face:direction:)` — core's face_frame_cut of a declared region (or one member face of
//     it), its inward normal or a stated press direction, with core's side verdict and normal spread;
//   * `triangleLoads(_:)` — core's inward normal of single triangles (face_frame of one triangle), for the
//     15° rule at a seam (FlexibleEdgeCandidates), with core's face of each so the caller can check that
//     its mesh's triangle t IS core's triangle t;
//   * `pressVerdict(_:direction:)` (AP2 review, binding amendment A4) — whether core's build_press_stack
//     BUILDS a press over these regions along this direction, and core's words when it refuses: the only
//     test of "a direction core accepts" (core checks EVERY footprint triangle; a per-member load check
//     is a coarser Swift copy that disagrees with core on curved members).
// No frame, normal, adjacency or verdict is computed in this file.
import Foundation
import simd
import TopOptBridge

/// Core's frame of a declared face region (or of one member face of it): face_frame_cut, rotation 0.
public struct FlexRegionFrame: Equatable, Sendable {
    public let valid: Bool
    /// Core's reason when not valid ("the face's normals cancel out …").
    public let reason: String
    /// INTO the part: the inward normal, or the stated press direction (unit, core's normaliser).
    public let load: SIMD3<Double>
    public let centroid: SIMD3<Double>
    public let areaMM2: Double
    /// Angle between the load line and build Z (0…90°), core's.
    public let buildAngleDeg: Double
    /// > core's kSideStackDeg from build Z: core's side verdict for this load.
    public let side: Bool
    public let normalSpreadDeg: Double
    /// > core's kNormalSpreadFlagDeg (30°): the face WRAPS (no one direction suits all of it).
    public let normalSpreadFlag: Bool
    /// The triangles handed to core.
    public let triangles: Int
    /// ★ AP3: core's frame axes — X, the principal axis of the region projected perpendicular to the load
    /// (core's stack X for the same inputs), and Y = load × X. Copied, never computed here.
    public let xAxis: SIMD3<Double>
    public let yAxis: SIMD3<Double>

    public init(valid: Bool, reason: String, load: SIMD3<Double>, centroid: SIMD3<Double>, areaMM2: Double,
                buildAngleDeg: Double, side: Bool, normalSpreadDeg: Double, normalSpreadFlag: Bool, triangles: Int,
                xAxis: SIMD3<Double> = SIMD3(1, 0, 0), yAxis: SIMD3<Double> = SIMD3(0, 1, 0)) {
        self.valid = valid; self.reason = reason; self.load = load; self.centroid = centroid; self.areaMM2 = areaMM2
        self.buildAngleDeg = buildAngleDeg; self.side = side; self.normalSpreadDeg = normalSpreadDeg
        self.normalSpreadFlag = normalSpreadFlag; self.triangles = triangles
        self.xAxis = xAxis; self.yAxis = yAxis
    }
}

/// Core's verdict on a press (build_press_stack over the open scene): built, or refused with core's words.
public struct FlexPressVerdict: Equatable, Sendable {
    public let accepted: Bool
    /// Core's words when refused ("press_direction does not point into the part over face region 3 …").
    public let reason: String
    /// When accepted: core's frame load — the stated direction normalised by core, or the inward normal.
    public let load: SIMD3<Double>
    /// When accepted: core's angle between the load line and build Z, and its side verdict.
    public let buildAngleDeg: Double
    public let side: Bool
    /// When accepted: core's column count.
    public let columns: Int

    public init(accepted: Bool, reason: String, load: SIMD3<Double>, buildAngleDeg: Double, side: Bool, columns: Int) {
        self.accepted = accepted; self.reason = reason; self.load = load; self.buildAngleDeg = buildAngleDeg
        self.side = side; self.columns = columns
    }
}

/// Core's inward normal of single triangles of the scene's model.
public struct FlexTriangleLoads: Equatable, Sendable {
    /// The scene model's triangle count.
    public let triangleCount: Int
    /// Core's face of each asked triangle (−1: out of range).
    public let faces: [Int]
    /// Core's load (inward normal) of each asked triangle; nil where core cannot frame it.
    public let loads: [SIMD3<Double>?]
}

extension FlexibleScene {

    /// Core's face_adjacency: element f lists face f's neighbours, ascending, no self.
    public func faceAdjacency() throws -> [[Int]] {
        var err = topoptbridge.BridgeError()
        let r = topoptbridge.flexible_scene_face_adjacency(handle, &err)
        try FlexConv.check(err)
        let off = Array(r.offsets), nb = Array(r.neighbours)
        guard off.count >= 1 else { return [] }
        return (0..<(off.count - 1)).map { f in (Int(off[f])..<Int(off[f + 1])).map { Int(nb[$0]) } }
    }

    /// Core's frame of declared region `region` (rotation 0): all its triangles, or only member face
    /// `face`'s (still clipped by the region's cuts); along `direction` when given (a press direction,
    /// any length > 0 — core normalises it and refuses a zero one).
    public func regionFrame(_ region: Int, face: Int? = nil, direction: SIMD3<Double>? = nil) throws -> FlexRegionFrame {
        var err = topoptbridge.BridgeError()
        let dir = direction.map { [$0.x, $0.y, $0.z] } ?? []
        let r = topoptbridge.flexible_scene_region_frame(handle, Int32(region), Int32(face ?? -1), direction != nil,
                                                         FlexConv.d(dir), &err)
        try FlexConv.check(err)
        return FlexRegionFrame(valid: r.valid, reason: String(r.reason), load: FlexConv.v3(r.load),
                               centroid: FlexConv.v3(r.centroid), areaMM2: r.area_mm2, buildAngleDeg: r.build_angle_deg,
                               side: r.side, normalSpreadDeg: r.normal_spread_deg, normalSpreadFlag: r.normal_spread_flag,
                               triangles: Int(r.triangles), xAxis: FlexConv.v3(r.x_axis), yAxis: FlexConv.v3(r.y_axis))
    }

    /// Core's inward normal of each of `triangles` (indices into core's model), with core's face of each.
    public func triangleLoads(_ triangles: [Int]) throws -> FlexTriangleLoads {
        var err = topoptbridge.BridgeError()
        let r = topoptbridge.flexible_scene_triangle_loads(handle, FlexConv.i(triangles), &err)
        try FlexConv.check(err)
        let f = Array(r.faces), l = Array(r.loads)
        var loads: [SIMD3<Double>?] = []
        loads.reserveCapacity(f.count)
        for k in 0..<f.count {
            let v = SIMD3(l[3 * k], l[3 * k + 1], l[3 * k + 2])
            loads.append(v.x.isFinite && v.y.isFinite && v.z.isFinite ? v : nil)
        }
        return FlexTriangleLoads(triangleCount: Int(r.triangle_count), faces: f.map { Int($0) }, loads: loads)
    }

    /// ★ Core's verdict on a press over declared regions `footprint` (in this order), along `direction` when
    /// given (else the union's inward normal): core's build_press_stack on the open scene. A refusal is an
    /// answer (`accepted == false`, core's words); a closed scene or an undeclared region throws.
    public func pressVerdict(_ footprint: [Int], direction: SIMD3<Double>?) throws -> FlexPressVerdict {
        var err = topoptbridge.BridgeError()
        let dir = direction.map { [$0.x, $0.y, $0.z] } ?? []
        let r = topoptbridge.flexible_scene_press_verdict(handle, FlexConv.i(footprint), direction != nil, FlexConv.d(dir), &err)
        try FlexConv.check(err)
        return FlexPressVerdict(accepted: r.accepted, reason: String(r.reason), load: FlexConv.v3(r.load),
                                buildAngleDeg: r.build_angle_deg, side: r.side, columns: Int(r.columns))
    }

    /// ★ R7-E1 — THE PRESS SEAM: register a press over declared regions `footprint` (in order) along `direction` on this open
    /// scene. Core builds its press stack at once (fx::build_press_stack); a refusal throws core's words, nothing registered.
    /// Accepted: a synthetic id ≤ −1000 that `stack`, `fromUV`, `toUVT`, … take in place of a face region (core's press stack
    /// then). New for every call, never reused; an id this scene never registered is "not declared".
    public func registerPress(_ footprint: [Int], direction: SIMD3<Double>) throws -> Int {
        var err = topoptbridge.BridgeError()
        let id = topoptbridge.flexible_scene_register_press(handle, FlexConv.i(footprint), FlexConv.d([direction.x, direction.y, direction.z]), &err)
        try FlexConv.check(err)
        return Int(id)
    }

    /// ★ R7-E1: core's press API version (fx::kPressApiVersion).
    public static var pressApiVersion: Int { Int(topoptbridge.flexible_press_api_version()) }

    /// ★ R7-E1 REVIEW — TESTS ONLY (a red control): the press columns' latticed run counted from the first sample (E1's rule —
    /// a surface voxel core leaves Empty makes it 0). Off (the app): the leading off-lattice stretch within two voxels is travel.
    nonisolated(unsafe) public static var controlRunFromFirstSample = false {
        didSet { topoptbridge.flexible_control_run_from_first_sample(controlRunFromFirstSample) }
    }
}
