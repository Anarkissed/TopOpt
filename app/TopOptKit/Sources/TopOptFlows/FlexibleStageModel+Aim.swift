// FlexibleStageModel+Aim — the stage model's side of the arrow (task 2026-10-07, angled presses, batch AP3; final spec
// §6, amended by A4/A8). It ASKS core and hands the answers to FlexiblePressAim's pure maths:
//   * `pressAim(_:)` — core's inward normal of every member (face_frame_cut per region, or per member face of a
//     one-region press over 2+ faces, clipped by its cuts), core's frame axes, core's build direction, the targets
//     FlexiblePressAim.candidates names (A4: never a member's own normal for 2+ regions; A8: build Z both ways), and
//     CORE'S VERDICT on each (build_press_stack through flexible_scene_press_verdict): only what core builds is
//     offered. Straighten is asked as the plain face press core builds today (no direction);
//   * `pressSide(_:direction:)` — core's side verdict for a stated direction: FaceFrame.side of face_frame_cut with
//     press_direction (no Swift threshold);
//   * `aimPress(_:_:)` — ONE undoable edit storing what a chip, the knob or the degrees box released: the direction
//     bit for bit and its snap kind (FlexiblePress.snap). [Straighten] on a tilted press puts the face back
//     (`straighten`, AP1: the struct moves back intact, so the job is as it was before the tilt).
// Every number read here is core's, through the open scene (FlexibleStageModel+Meet's caches); nothing is framed,
// columned or designed in Swift.
import Foundation
import simd
import TopOptKit

/// Core's answers for one press's aim, and the targets core builds.
public struct FlexiblePressAimSet: Equatable, Sendable {
    /// One target as asked of core, with core's verdict (renamed to the app's region names).
    public struct Asked: Equatable, Sendable {
        public let target: FlexiblePressAim.Target
        public let accepted: Bool
        /// Core's words when refused; "" when accepted.
        public let reason: String
    }

    public let regions: [Int]
    /// Core's inward normal of each member, in order (each region; each member face of a multi-face region).
    public let memberLoads: [SIMD3<Double>]
    /// A one-region press's own core normal (its straighten); nil for 2+ regions.
    public let ownLoad: SIMD3<Double>?
    /// The halfway (2+ members), or nil — with `why` saying so.
    public let halfway: SIMD3<Double>?
    /// Core's build direction (the scene's).
    public let buildDir: SIMD3<Double>
    /// Every target asked, in order, with core's verdict.
    public let asked: [Asked]
    /// The degrees box's fallback axes (core's normals and frame axes).
    public let fallbacks: [SIMD3<Double>]
    /// One line when a member has no core normal or the members face apart; nil otherwise.
    public let why: String?

    /// ★ The targets OFFERED: exactly those core builds.
    public var offered: [FlexiblePressAim.Target] { asked.filter(\.accepted).map(\.target) }
}

extension FlexibleStageModel {

    /// ★ Core's answers for aiming a press over `regions` (pick order), and the targets core builds (A4/A8).
    public func pressAim(_ regions: [Int]) async throws -> FlexiblePressAimSet {
        guard let first = regions.first else { throw TopOptError(message: "A press needs a face.") }
        let mesh = project.viewerMesh
        let single = regions.count == 1
        var memberLoads: [SIMD3<Double>] = []
        var ownLoad: SIMD3<Double>? = nil
        var why: String? = nil
        var axes: (x: SIMD3<Double>, y: SIMD3<Double>)? = nil
        if single {
            let own = try await regionFrame(first)
            if own.valid {
                ownLoad = own.load
                axes = (own.xAxis, own.yAxis)
                let faces = self.regions.faces(of: first, mesh: mesh)
                if faces.count >= 2 {
                    for f in faces {
                        let ff = try await regionFrame(first, face: f)
                        if ff.valid { memberLoads.append(ff.load) }
                    }
                } else {
                    memberLoads = [own.load]
                }
            } else {
                why = name(first) + ": " + text(own.reason)
            }
        } else {
            for r in regions {
                let f = try await regionFrame(r)
                guard f.valid else {
                    why = why ?? (name(r) + ": " + text(f.reason))
                    continue
                }
                if axes == nil { axes = (f.xAxis, f.yAxis) }
                memberLoads.append(f.areaMM2 * f.load)   // AP3 RED STUB: area-weighted (core's no-direction default)
            }
            if why != nil { memberLoads = [] }
        }
        guard let build = sceneInfo?.buildDir else { throw TopOptError(message: "The part is still opening.") }
        let candidates = FlexiblePressAim.candidates(memberLoads: why == nil ? memberLoads : [],
                                                     ownLoad: ownLoad, buildDir: build)
        let halfway = memberLoads.count >= 2 ? FlexiblePressAim.halfway(memberLoads) : nil
        if why == nil, !single, halfway == nil { why = "These faces face apart \u{00B7} no one direction" }
        var asked: [FlexiblePressAimSet.Asked] = []
        for t in candidates {
            // straighten is the plain face press core builds today (no direction); every other target is
            // asked as the press it would be, along its direction
            asked.append(.init(target: t, accepted: true, reason: ""))   // AP3 RED STUB: offered without asking core
        }
        let fallbacks = FlexiblePressAim.fallbacks(memberLoads: memberLoads, single: single, coreX: axes?.x, coreY: axes?.y)
        return FlexiblePressAimSet(regions: regions, memberLoads: memberLoads, ownLoad: ownLoad, halfway: halfway,
                                   buildDir: build, asked: asked, fallbacks: fallbacks, why: why)
    }

    /// ★ CORE'S SIDE VERDICT for pressing `regions` along `direction`: face_frame_cut with press_direction — its
    /// build_angle_deg and side (core's "> kSideStackDeg") for the stated load — from the first member core frames.
    /// nil when core frames none of them. No angle is compared with a threshold in Swift.
    public func pressSide(_ regions: [Int], direction: SIMD3<Double>) async throws -> FlexRegionFrame? {
        // AP3 RED STUB: a Swift copy of the threshold — the angle to MODEL Z, >= 15
        for r in regions {
            let f = try await regionFrame(r, direction: direction)
            guard f.valid else { continue }
            let a = FlexiblePressAim.degrees(FlexiblePressAim.unit(direction) ?? f.load, SIMD3(0, 0, -1))
            let line = min(a, 180 - a)   // AP3 RED STUB
            return FlexRegionFrame(valid: f.valid, reason: f.reason, load: f.load, centroid: f.centroid, areaMM2: f.areaMM2,
                                   buildAngleDeg: line, side: line >= 15, normalSpreadDeg: f.normalSpreadDeg,   // AP3 RED STUB
                                   normalSpreadFlag: f.normalSpreadFlag, triangles: f.triangles, xAxis: f.xAxis, yAxis: f.yAxis)
        }
        return nil
    }

    /// ★ ONE undoable edit: put what a chip, the knob or the degrees box released on press `id` — the direction bit
    /// for bit and its snap kind. [Straighten] on a tilted press puts the face back intact (AP1's `straighten`); a
    /// face that cannot go back (pressed on its own already) keeps the press, on its normal. false: no such press,
    /// a direction that cannot be stored, or nothing changes.
    @discardableResult
    public func aimPress(_ id: UUID, _ r: FlexiblePressAim.Release) -> Bool {
        guard var p = settings.press(id), FlexiblePress.isAimable(r.direction) else { return false }
        let raw: String? = nil   // AP3 RED STUB: the snap kind dropped, no [Straighten]
        guard FlexiblePressAim.bits(p.direction) != FlexiblePressAim.bits(r.direction) || p.snap != raw else { return false }
        guard p.aim(SIMD3<Double>(SIMD3<Float>(r.direction)), snap: raw) else { return false }   // AP3 RED STUB: through Float
        project.sealUndoStep()   // its own undo step, as every press action (AP1 review)
        actionSerial += 1
        edit { $0.setPress(p) }
        return true
    }
}
