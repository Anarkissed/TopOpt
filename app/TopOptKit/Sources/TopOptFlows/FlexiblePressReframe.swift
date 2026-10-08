// FlexiblePressReframe — a press's (or a face press's) inputs carried from one of core's frames to another
// (task 2026-10-07, angled presses, batch AP1; final spec §4 "Inputs belong to a frame").
//
// ★ WHY. Stamp centres are (u, v) mm in a frame (FlexibleStampPlacement.centreU / centreV) and the
// curves run along the frame's X and Y over normalised extents. When the frame a press is drawn in
// changes — a face press moved to a complement sector (spec §8's [Press the rest of Top]), and from AP9 a
// tilt, a straighten and every direction change — the drawing must stay where he drew it:
//   * the STAMP keeps its point ON THE SURFACE: core's from_uv in the old frame, plus core's column
//     entry along the old load, then core's to_uvt in the new frame. Its width axis is carried the same
//     way (a second point 1 mm along it), so an elongated stamp keeps its heading on the part;
//   * each CURVE stays along the world axis it was drawn along: X and Y swap when the new X lies nearer
//     the old Y, and a curve's normalised x runs backwards when its axis flipped.
// "Curves follow the face" is said whenever a curve swapped or reversed (`Result.toast`).
//
// ★ ONE SOURCE: CORE. Every frame number used here — the load, the X and Y axes, the column entries, the
// (u, v) ↔ point maps — is core's, read through `FlexibleFrameSource`. The only Swift is the comparison
// of core's axes (which old axis a new one runs along, and its sign) and the stamp's heading measured
// between two of core's mapped points. No frame, column or design is computed here.
//
// ★ A FRAME IS NAMED BY VALUE (AP1 review). A press's own frame is `FlexibleFrameRef.press` of a
// `FlexiblePressFrame` — its footprint and its direction, equal only bit for bit (FlexiblePress.swift) —
// never the press's id: a re-aim or a footprint change is then two frames (from, to) that core is asked
// for in turn, and the frame the inputs were drawn in can be SAVED (`FlexiblePress.drawnIn`).
//
// ★ WHAT WAITS ON CORE (AP9). A press's OWN frame is core's build_press_stack, which this branch's core
// does not have (it arrives with #361's addendum, S1) and which the bridge does not call before the
// seam (AP9: flexible_scene_register_press and stack_of's dispatch of synthetic ids). Until then
// `FlexibleSceneFrames` throws `Waiting.pressFrame` for it, so re-expressing a tilt, a straighten or a
// direction change through a press's frame waits: a tilt keeps its inputs in the face's frame
// (`drawnIn` = `.face(region)`), and a re-aim or a member change records the frame they were drawn in
// (`FlexiblePress.aim` / `setMembers`) for AP9 to reframe from. Face frames — a declared region's stack,
// from_uv and to_uvt — are core's today, through the open scene.

import Foundation
import simd
import TopOptKit

/// Core's answers about a frame. Every value is core's; nothing implementing this may compute a frame.
public protocol FlexibleFrameSource {
    /// Core's stack in that frame (its load, axes and columns).
    func stack(_ ref: FlexibleFrameRef) throws -> FlexStackInfo
    /// Core's from_uv: (u, v) mm → points on the frame's plane.
    func fromUV(_ ref: FlexibleFrameRef, _ uv: [SIMD2<Double>]) throws -> [SIMD3<Double>]
    /// Core's to_uv plus t along the load: points → (u, v, t).
    func toUVT(_ ref: FlexibleFrameRef, _ xyz: [SIMD3<Double>]) throws -> [SIMD3<Double>]
}

/// The open scene's frames. A face frame is core's today; a press frame waits on AP9.
public struct FlexibleSceneFrames: FlexibleFrameSource {
    public let scene: FlexibleScene
    public init(_ scene: FlexibleScene) { self.scene = scene }

    private func region(_ ref: FlexibleFrameRef) throws -> Int {
        switch ref {
        case .face(let r): return r
        case .press: throw FlexiblePressReframe.Waiting.pressFrame
        }
    }

    public func stack(_ ref: FlexibleFrameRef) throws -> FlexStackInfo {
        try scene.stack(face: try region(ref), rotation: 0)
    }
    public func fromUV(_ ref: FlexibleFrameRef, _ uv: [SIMD2<Double>]) throws -> [SIMD3<Double>] {
        try scene.fromUV(face: try region(ref), rotation: 0, uv)
    }
    public func toUVT(_ ref: FlexibleFrameRef, _ xyz: [SIMD3<Double>]) throws -> [SIMD3<Double>] {
        let flat = try scene.toUVT(face: try region(ref), rotation: 0, xyz.flatMap { [$0.x, $0.y, $0.z] })
        return stride(from: 0, to: flat.count - 2, by: 3).map { SIMD3(flat[$0], flat[$0 + 1], flat[$0 + 2]) }
    }
}

public enum FlexiblePressReframe {

    /// What waits on core.
    public enum Waiting: Error, Equatable, CustomStringConvertible {
        /// A press's own frame is core's build_press_stack: the bridge does not call it until AP9.
        case pressFrame
        public var description: String {
            switch self {
            case .pressFrame:
                return "A press's own frame is core's build_press_stack, which the bridge does not call yet (batch AP9)."
            }
        }
    }

    /// The one line said when a curve swapped or reversed.
    public static let toast = "Curves follow the face"

    public struct Result: Equatable, Sendable {
        /// The settings with the curves and the stamp re-expressed (everything else as it was).
        public let settings: FlexibleFaceSettings
        /// The new X carries the old Y curve (and the new Y the old X).
        public let swapped: Bool
        /// The new X / Y curve runs backwards (its axis flipped).
        public let reversedX: Bool
        public let reversedY: Bool
        /// "Curves follow the face" when anything about the curves changed; nil otherwise.
        public var toast: String? { swapped || reversedX || reversedY ? FlexiblePressReframe.toast : nil }
    }

    /// `f`'s curves and stamp, from core's frame `from` to core's frame `to` (see the file comment).
    /// The same frame (a press frame: the same footprint and the same direction, bit for bit) returns
    /// `f` unchanged, bit for bit, without asking core.
    public static func reframe(_ f: FlexibleFaceSettings, from: FlexibleFrameRef, to: FlexibleFrameRef,
                               frames: FlexibleFrameSource) throws -> Result {
        guard from != to else { return Result(settings: f, swapped: false, reversedX: false, reversedY: false) }
        let a = try frames.stack(from), b = try frames.stack(to)
        var out = f

        // the curves: which old axis each new axis runs along (core's axes), and its sign
        let swapped = abs(simd_dot(b.xAxis, a.yAxis)) > abs(simd_dot(b.xAxis, a.xAxis))
        let alongX = swapped ? simd_dot(b.xAxis, a.yAxis) : simd_dot(b.xAxis, a.xAxis)
        let alongY = swapped ? simd_dot(b.yAxis, a.xAxis) : simd_dot(b.yAxis, a.yAxis)
        let newX = swapped ? f.curveY : f.curveX
        let newY = swapped ? f.curveX : f.curveY
        let reversedX = alongX < 0, reversedY = alongY < 0
        out.curveX = reversedX ? reversed(newX) : newX
        out.curveY = reversedY ? reversed(newY) : newY

        // the stamp: its point on the surface, and its heading, through core's maps
        if var st = f.designStamp {
            let th = st.rotationDeg * .pi / 180
            let uv = [SIMD2(st.centreU, st.centreV), SIMD2(st.centreU + cos(th), st.centreV + sin(th))]
            let entry = a.entryT(nearU: st.centreU, v: st.centreV)
            let onPart = try frames.fromUV(from, uv).map { $0 + a.load * entry }
            let mapped = try frames.toUVT(to, onPart)
            guard mapped.count == 2 else { throw TopOptError(message: "core's frame mapped \(mapped.count) of 2 stamp points") }
            st.centreU = mapped[0].x
            st.centreV = mapped[0].y
            let d = SIMD2(mapped[1].x - mapped[0].x, mapped[1].y - mapped[0].y)
            st.rotationDeg = atan2(d.y, d.x) * 180 / .pi
            out.designStamp = st
        }
        return Result(settings: out, swapped: swapped, reversedX: reversedX, reversedY: reversedY)
    }

    /// The same curve read from the other end: x → 1 − x, the points in reverse order (x stays increasing).
    public static func reversed(_ c: FlexCurve) -> FlexCurve {
        FlexCurve(x: c.x.reversed().map { 1 - $0 }, y: c.y.reversed())
    }
}
