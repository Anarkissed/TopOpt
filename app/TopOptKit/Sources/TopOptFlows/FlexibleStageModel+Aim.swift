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
        /// Core's words when refused (its region ids renamed), for the (i); "" when accepted.
        public let reason: String
        /// ★ AP3 REVIEW: the same refusal as ONE plain line of at most 44 characters, in the app's names; "" when
        /// accepted.
        public let line: String
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

    /// ★ AP3 REVIEW: core's inward normal of EVERY triangle core checks a stated direction against (each member
    /// region's member faces), deduplicated — the set the knob's clamp and the degrees box's limit hold 1° short
    /// of edge-on to.
    public var footprintNormals: [SIMD3<Double>] { memberLoads }   // AP3 REVIEW RED STUB: each member's average
    /// ★ AP3 REVIEW: core's own sentence behind `why` (renamed), for the (i).
    public var whyDetail: String? { why }   // AP3 REVIEW RED STUB: no plain line

    /// ★ The targets OFFERED: exactly those core builds.
    public var offered: [FlexiblePressAim.Target] { asked.filter(\.accepted).map(\.target) }

    /// ★ AP3 REVIEW (D-AP3-1): the offered target the arrow IS on, bit for bit — what the screen shows as snapped
    /// (a chip lit, the badge above the knob). The stored snap kind is only the target the box measures FROM.
    public func on(_ direction: SIMD3<Double>) -> FlexiblePressAim.Target? {
        offered.first   // AP3 REVIEW RED STUB: the selected target, wherever the arrow is
    }

    /// The knob's drag for this press: the offered targets, held 1° short of edge-on to the footprint's normals.
    public func drag(direction: SIMD3<Double>, anchor: SIMD3<Double>, length: Double, grab: PrimitiveGizmo.Ray,
                     viewDir: SIMD3<Double>) -> FlexiblePressAim.Drag {
        FlexiblePressAim.Drag(direction: direction, anchor: anchor, length: length, grab: grab, viewDir: viewDir,
                              targets: offered, loads: footprintNormals)
    }

    /// The trackball for this press (looking along the arrow), with the same targets and limit as the knob.
    public func trackball(direction: SIMD3<Double>, right: SIMD3<Double>, up: SIMD3<Double>) -> FlexiblePressAim.Trackball {
        FlexiblePressAim.Trackball(direction: direction, right: right, up: up, targets: offered, loads: footprintNormals)
    }

    /// ★ A NEW press's aim (round 6 item 2's picks, spec §6): the first offered target — the halfway of an edge or a
    /// corner, a tilt's straighten — exactly, with its kind. nil when core builds none of them (`why` and the asked
    /// targets' reasons say why, in core's words).
    public var defaultRelease: FlexiblePressAim.Release? { offered.first.map(FlexiblePressAim.chip) }

    /// The degrees box for a press aimed along `current` whose snap kind is `snap`: measured from the selected target
    /// (FlexiblePressAim.selected), on core's fallback axes, held 1° short of edge-on to every member.
    public func box(current: SIMD3<Double>, snap: FlexiblePress.Snap?) -> FlexiblePressAim.Box? {
        guard let t = FlexiblePressAim.selected(snap, offered: offered) else { return nil }
        return FlexiblePressAim.box(target: t, current: current, fallbacks: fallbacks, loads: memberLoads)
    }
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
                memberLoads.append(f.load)
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
            let v = try await pressVerdict(t.kind == .straighten ? [first] : regions,
                                           direction: t.kind == .straighten ? nil : t.direction)
            asked.append(.init(target: t, accepted: v.accepted, reason: v.accepted ? "" : text(v.reason),
                               line: v.accepted ? "" : text(v.reason)))   // AP3 REVIEW RED STUB: core's sentence as the line
        }
        let fallbacks = FlexiblePressAim.fallbacks(memberLoads: memberLoads, single: single, coreX: axes?.x, coreY: axes?.y)
        return FlexiblePressAimSet(regions: regions, memberLoads: memberLoads, ownLoad: ownLoad, halfway: halfway,
                                   buildDir: build, asked: asked, fallbacks: fallbacks, why: why)
    }

    /// ★ AP3 REVIEW: core's refusal `reason` (a press verdict's words) as ONE plain line of at most 44 characters,
    /// in the app's names ("Top A", "Face 3"); `text(reason)` is core's own sentence for the (i).
    public func plainLine(_ reason: String) -> String {
        text(reason)   // AP3 REVIEW RED STUB: core's sentence as it is
    }

    /// ★ CORE'S SIDE VERDICT for pressing `regions` along `direction`: face_frame_cut with press_direction — its
    /// build_angle_deg and side (core's "> kSideStackDeg") for the stated load — from the first member core frames.
    /// nil when core frames none of them. No angle is compared with a threshold in Swift.
    public func pressSide(_ regions: [Int], direction: SIMD3<Double>) async throws -> FlexRegionFrame? {
        for r in regions {
            let f = try await regionFrame(r, direction: direction)
            if f.valid { return f }
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
        if r.snap == .straighten, p.kind == .tilted, straighten(id) { return true }   // AP3 REVIEW RED STUB: `exact` unread
        let raw = r.snap?.raw
        guard FlexiblePressAim.bits(p.direction) != FlexiblePressAim.bits(r.direction) || p.snap != raw else { return false }
        guard p.aim(r.direction, snap: raw) else { return false }
        project.sealUndoStep()   // its own undo step, as every press action (AP1 review)
        actionSerial += 1
        edit { $0.setPress(p) }
        return true
    }
}
