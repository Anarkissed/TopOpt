// FlexibleStageModel+Aim — the stage model's side of the arrow (task 2026-10-07, angled presses, batch AP3; final spec
// §6, amended by A4/A8). It ASKS core and hands the answers to FlexiblePressAim's pure maths:
//   * `pressAim(_:)` — core's inward normal of every member (face_frame_cut per region, or per member face of a
//     one-region press over 2+ faces, clipped by its cuts), core's frame axes, core's build direction, the targets
//     FlexiblePressAim.candidates names (A4: never a member's own normal for 2+ regions; A8: build Z both ways), and
//     CORE'S VERDICT on each (build_press_stack through flexible_scene_press_verdict): only what core builds is
//     offered. Straighten is asked BOTH ways (AP3 REVIEW): as the plain face press it turns back into (no direction)
//     and as the direction it stores when it stays a press (stated); it is offered only when core builds both;
//   * AP3 REVIEW: core's inward normal of every footprint triangle (`footprintNormals`, the knob's and the box's 1°
//     limit, as core checks a stated direction) and core's refusals as one plain line (`plainLine`);
//   * `pressSide(_:direction:)` — core's side verdict for a stated direction: FaceFrame.side of face_frame_cut with
//     press_direction (no Swift threshold);
//   * `aimPress(_:_:)` — ONE undoable edit storing what a chip, the knob or the degrees box released: the direction
//     bit for bit and its snap kind (FlexiblePress.snap). [Straighten] — EXACTLY on it: the chip, a knob snap, the
//     box at 0 (AP3 REVIEW: the box measures from it, so every box commit carried its kind) — on a tilted press puts
//     the face back (`straighten`, AP1: the struct moves back intact, so the job is as it was before the tilt).
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
    /// of edge-on to. Each member's average let curved members through to directions core refuses (the M2's
    /// corners #11 and #12). The members' loads when core's part is not the page's mesh triangle for triangle.
    public let footprintNormals: [SIMD3<Double>]
    /// ★ AP3 REVIEW: the sentence behind `why` (core's, renamed), for the (i); `why` is the plain line.
    public let whyDetail: String?

    /// ★ The targets OFFERED: exactly those core builds.
    public var offered: [FlexiblePressAim.Target] { asked.filter(\.accepted).map(\.target) }

    /// ★ AP3 REVIEW (D-AP3-1): the offered target the arrow IS on, bit for bit — what the screen shows as snapped
    /// (a chip lit, the badge above the knob). The stored snap kind is only the target the box measures FROM.
    public func on(_ direction: SIMD3<Double>) -> FlexiblePressAim.Target? {
        offered.first { FlexiblePressAim.on(direction, $0) }
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
    /// (FlexiblePressAim.selected), on core's fallback axes, held 1° short of edge-on to core's normal of every
    /// footprint triangle (AP3 REVIEW; or the target's own margin when core built it inside that band).
    public func box(current: SIMD3<Double>, snap: FlexiblePress.Snap?) -> FlexiblePressAim.Box? {
        guard let t = FlexiblePressAim.selected(snap, offered: offered) else { return nil }
        return FlexiblePressAim.box(target: t, current: current, fallbacks: fallbacks, loads: footprintNormals)
    }
}

/// ★ ROUND 6 ITEM 2: where an aim's numbers come from — the page's OPEN scene (`FlexibleStageModel.pressAim`), or a scene
/// opened on regions that are not cut yet (item 2's [Done]: the strips' own halfway, asked of core before the cut is
/// committed, so the cut and its presses are ONE edit). The same engine (`FlexibleStageModel.aimSet`) reads either: one
/// route for the rule, never two.
struct FlexibleAimSource {
    /// Core's frame of a declared region (or of its member face), no direction.
    let frame: (Int, Int?) async throws -> FlexRegionFrame
    /// Core's verdict on a press over a footprint along a direction (nil: none stated).
    let verdict: ([Int], SIMD3<Double>?) async throws -> FlexPressVerdict
    /// Core's inward normal of each asked triangle.
    let triangleLoads: ([Int]) async throws -> FlexTriangleLoads
    /// The faces a region covers.
    let faces: (Int) -> [Int]
    let mesh: ViewerMesh?
    /// Core's build direction (the scene's); nil while the part opens.
    let buildDir: SIMD3<Double>?
    /// Core's id → the app's name ("face 1000103" → "face 1 · A"), and the panel's name ("Top A").
    let name: (Int) -> String
    let displayName: (Int) -> String
    /// Core's sentence with the app's names.
    let text: (String) -> String
}

extension FlexibleStageModel {

    /// ★ Core's answers for aiming a press over `regions` (pick order), and the targets core builds (A4/A8).
    public func pressAim(_ regions: [Int]) async throws -> FlexiblePressAimSet {
        try await Self.aimSet(regions, source: openSceneAimSource)
    }

    /// The open scene, as an aim's source (FlexibleStageModel+Meet's caches).
    var openSceneAimSource: FlexibleAimSource {
        FlexibleAimSource(
            frame: { [weak self] r, f in
                guard let self else { throw TopOptError(message: "The page closed.") }
                return try await self.regionFrame(r, face: f)
            },
            verdict: { [weak self] fp, d in
                guard let self else { throw TopOptError(message: "The page closed.") }
                return try await self.pressVerdict(fp, direction: d)
            },
            triangleLoads: { [frameWorker] tris in try await frameWorker.withScene { try $0.triangleLoads(tris) } },
            faces: { [weak self] r in self.map { $0.regions.faces(of: r, mesh: $0.project.viewerMesh) } ?? [r] },
            mesh: project.viewerMesh, buildDir: sceneInfo?.buildDir,
            name: { [weak self] r in self?.name(r) ?? "face \(r)" },
            displayName: { [weak self] r in self?.displayName(r) ?? "Face \(r)" },
            text: { [weak self] s in self?.text(s) ?? s })
    }

    /// ★ THE ENGINE: core's inward normal of every member (face_frame_cut per region, or per member face of a one-region
    /// press over 2+ faces, clipped by its cuts), core's frame axes, core's build direction, the targets
    /// FlexiblePressAim.candidates names (A4/A8) and CORE'S VERDICT on each — from `source`.
    static func aimSet(_ regions: [Int], source: FlexibleAimSource) async throws -> FlexiblePressAimSet {
        guard let first = regions.first else { throw TopOptError(message: "A press needs a face.") }
        let single = regions.count == 1
        var memberLoads: [SIMD3<Double>] = []
        var ownLoad: SIMD3<Double>? = nil
        var why: String? = nil, whyDetail: String? = nil
        var axes: (x: SIMD3<Double>, y: SIMD3<Double>)? = nil
        if single {
            let own = try await source.frame(first, nil)
            if own.valid {
                ownLoad = own.load
                axes = (own.xAxis, own.yAxis)
                let faces = source.faces(first)
                if faces.count >= 2 {
                    for f in faces {
                        let ff = try await source.frame(first, f)
                        if ff.valid { memberLoads.append(ff.load) }
                    }
                } else {
                    memberLoads = [own.load]
                }
            } else {
                why = FlexiblePressAim.plainFrameLine(own.reason, name: source.displayName(first))
                whyDetail = source.name(first) + ": " + source.text(own.reason)
            }
        } else {
            for r in regions {
                let f = try await source.frame(r, nil)
                guard f.valid else {
                    if why == nil {
                        why = FlexiblePressAim.plainFrameLine(f.reason, name: source.displayName(r))
                        whyDetail = source.name(r) + ": " + source.text(f.reason)
                    }
                    continue
                }
                if axes == nil { axes = (f.xAxis, f.yAxis) }
                memberLoads.append(f.load)
            }
            if why != nil { memberLoads = [] }
        }
        guard let build = source.buildDir else { throw TopOptError(message: "The part is still opening.") }
        let candidates = FlexiblePressAim.candidates(memberLoads: why == nil ? memberLoads : [],
                                                     ownLoad: ownLoad, buildDir: build)
        let halfway = memberLoads.count >= 2 ? FlexiblePressAim.halfway(memberLoads) : nil
        if why == nil, !single, halfway == nil {
            why = "These faces face apart \u{00B7} no one direction"
            whyDetail = "Their inward normals cancel out, or their sum does not push into every one of them: "
                + "no one direction presses them all."
        }
        func line(_ reason: String) -> String {
            var names: [Int: String] = [:]
            for id in FlexiblePressAim.regionIDs(reason) { names[id] = source.displayName(id) }
            return FlexiblePressAim.plainLine(reason) { names[$0] ?? "Face \($0)" }
        }
        var asked: [FlexiblePressAimSet.Asked] = []
        for t in candidates {
            // ★ AP3 REVIEW: straighten is asked as the plain face press it turns back into (no direction) AND as
            // the direction it stores when it stays a press (stated): offered only when core builds both. Every
            // other target is asked as the press it would be, along its direction.
            let v: FlexPressVerdict
            if t.kind == .straighten {
                let asFace = try await source.verdict([first], nil)
                v = asFace.accepted ? try await source.verdict([first], t.direction) : asFace
            } else {
                v = try await source.verdict(regions, t.direction)
            }
            asked.append(.init(target: t, accepted: v.accepted, reason: v.accepted ? "" : source.text(v.reason),
                               line: v.accepted ? "" : line(v.reason)))
        }
        let fallbacks = FlexiblePressAim.fallbacks(memberLoads: memberLoads, single: single, coreX: axes?.x, coreY: axes?.y)
        let normals = try await footprintNormals(regions, source: source) ?? memberLoads
        return FlexiblePressAimSet(regions: regions, memberLoads: memberLoads, ownLoad: ownLoad, halfway: halfway,
                                   buildDir: build, asked: asked, fallbacks: fallbacks, why: why,
                                   footprintNormals: normals, whyDetail: whyDetail)
    }

    /// ★ AP3 REVIEW: core's inward normal of every triangle core checks a press direction against — the member faces
    /// of each region in `regions`, whole (build_press_stack checks a region's member_triangles; its cuts are not
    /// applied there) — deduplicated bit for bit (flexible_scene_triangle_loads: core's face_frame of each). nil when
    /// core's part is not the page's mesh triangle for triangle (meetFacts' check): nothing is decided on it then.
    func footprintNormals(_ regions: [Int]) async throws -> [SIMD3<Double>]? {
        try await Self.footprintNormals(regions, source: openSceneAimSource)
    }

    static func footprintNormals(_ regions: [Int], source: FlexibleAimSource) async throws -> [SIMD3<Double>]? {
        guard let mesh = source.mesh else { return nil }
        var faces = Set<Int>()
        for r in regions { faces.formUnion(source.faces(r)) }
        let n = Swift.min(mesh.triangleCount, mesh.faceIDs.count)
        let tris = (0..<n).filter { faces.contains(Int(mesh.faceIDs[$0])) }
        guard !tris.isEmpty else { return nil }
        let got = try await source.triangleLoads(tris)
        guard got.triangleCount == mesh.triangleCount, got.faces.count == tris.count, got.loads.count == tris.count
        else { return nil }
        var seen = Set<[UInt64]>()
        var out: [SIMD3<Double>] = []
        for (k, t) in tris.enumerated() {
            guard got.faces[k] == Int(mesh.faceIDs[t]) else { return nil }
            guard let l = got.loads[k] else { continue }   // a zero-area triangle: core skips it too
            if seen.insert(FlexiblePressAim.bits(l)).inserted { out.append(l) }
        }
        return out.isEmpty ? nil : out
    }

    /// ★ AP3 REVIEW: core's refusal `reason` (a press verdict's words) as ONE plain line of at most 44 characters,
    /// in the app's names ("Top A", "Face 3"); `text(reason)` is core's own sentence for the (i).
    public func plainLine(_ reason: String) -> String {
        var names: [Int: String] = [:]
        for id in FlexiblePressAim.regionIDs(reason) { names[id] = displayName(id) }
        return FlexiblePressAim.plainLine(reason) { names[$0] ?? "Face \($0)" }
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
    /// for bit and its snap kind. [Straighten] EXACTLY (`r.exact`: the chip, a knob snap, the box at 0) on a tilted
    /// press puts the face back intact (AP1's `straighten`); a face that cannot go back (pressed on its own already)
    /// keeps the press, on its normal. ★ AP3 REVIEW: the box measures FROM [Straighten], so its commits carry that
    /// kind at any angle — a commit off it is a tilt and is stored as one (it straightened the press away). false:
    /// no such press, a direction that cannot be stored, or nothing changes.
    @discardableResult
    public func aimPress(_ id: UUID, _ r: FlexiblePressAim.Release) -> Bool {
        guard var p = settings.press(id), FlexiblePress.isAimable(r.direction) else { return false }
        if r.snap == .straighten, r.exact, p.kind == .tilted, straighten(id) { return true }
        let raw = r.snap?.raw
        guard FlexiblePressAim.bits(p.direction) != FlexiblePressAim.bits(r.direction) || p.snap != raw else { return false }
        guard p.aim(r.direction, snap: raw) else { return false }
        project.sealUndoStep()   // its own undo step, as every press action (AP1 review)
        actionSerial += 1
        edit { $0.setPress(p) }
        return true
    }
}
