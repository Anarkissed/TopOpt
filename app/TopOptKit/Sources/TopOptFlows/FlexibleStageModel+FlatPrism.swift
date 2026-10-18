// FlexibleStageModel+FlatPrism — the stage model's side of the edge/corner FLAT PRISM (task 2026-09-29-flexible-screens, round 7
// batch R7-E1). His words, 2026-10-18 (binding): "There shouldn't be a strip width. It should be a Flat prism that gets wider as it
// gets dragged further towards the centre of the model from the edge. We should be able to change the angle up/down and left/right
// of the prism." The reviewer's rulings: NOTHING app-side stands in as the bend limit — the depth is capped by the lattice/geometry
// from core's columns; no request to core without a face-prism; one source: core.
//
// ★ THE PREVIEW (`previewFlatCut`): what a handle shows while it moves — never in the settings, never in history, no scene opened.
// ★ THE COMMIT (`setFlatCut`): ONE edit and one undo step through the strips' one engine (changeFlexibleStrips, StripChange.cut):
// the press's pieces re-cut by its plane, a scene opened on them, core's verdict on the STATED direction, core's press stack's
// columns checked against the lattice (δ_k ≤ lattice_mm_k), the face's settings carried onto its rests — or nothing stored and one
// line why (a lattice stop also names its fix: [Set N mm], N from core's columns). A typed depth is held to what the faces allow
// (each keeps some of itself — his answer) and the hold is said.
// ★ THE SEAM (`registerPresses`): after every scene install, each strip press is registered on core's open scene as a synthetic key
// (≤ −1000, the bridge's flexible_scene_register_press) — core's press stack (FlexStackInfo), the apex's t in its frame (core's
// to_uvt) and core's per-triangle normals of its footprint (the knob's 1° limit). A press core refuses is not registered; its card
// line says why.
// ★ STRIPS SAVED WITH M2'S WIDTH read through (FlexibleFlatPrism.depth(of:)): shown at once as their depth, their pieces unchanged
// bit for bit, written with his next edit of that press (this engine clears the width); one toast on the first open.

import Foundation
import simd
import TopOptKit

/// What a drag shows before the release commits it (never in the settings, never in history).
public struct FlexibleFlatPreview: Equatable, Sendable {
    public let press: UUID
    public var depthMM: Double
    public var direction: SIMD3<Double>
}

/// A release the lattice stopped: its one line and the fix's number ([Set N mm], N from core's columns).
public struct FlexibleFlatStop: Equatable, Sendable {
    public let press: UUID
    public let line: String
    public let setMM: Double?
}

/// What one press is registered as on core's open scene.
struct FlexiblePressRegistration: Equatable {
    let scene: ObjectIdentifier
    let regions: [Int]
    let direction: [UInt64]
    let key: Int
    let stack: FlexStackInfo
    let apexT: Double
    let normals: [SIMD3<Double>]
}

extension FlexibleStageModel {
    /// ★ RED CONTROL only (FlexibleFlatPrismEngineTests): core's verdict refuses every flat-cut release with these words.
    @MainActor static var controlRefuseFlatCut: String?
    /// ★ RED CONTROL only: every drag sample is a stored edit (the live writes the preview replaced).
    @MainActor static var controlLiveFlatWrites = false

    // MARK: - what is shown

    /// The press's plane as shown: the drag's preview, else the stored press (FlexibleFlatPrism.cut(of:)).
    public func flatCut(_ id: UUID) -> FlexibleFlatPrism.Cut? {
        guard let p = settings.press(id), let st = p.strip else { return nil }
        if let v = flatPreview, v.press == id { return FlexibleFlatPrism.cut(st, direction: v.direction, depthMM: v.depthMM) }
        return FlexibleFlatPrism.cut(of: p)
    }

    /// ★ A handle moved: the preview only (`depthMM` / `direction` nil: kept).
    public func previewFlatCut(_ id: UUID, depthMM: Double?, direction: SIMD3<Double>?) {
        guard let cur = flatCut(id) else { return }
        let h = depthMM ?? cur.depthMM, d = direction ?? cur.direction
        if Self.controlLiveFlatWrites {   // (RED CONTROL: a stored edit and a scene open per sample)
            track(Task { @MainActor [weak self] in _ = await self?.setFlatCut(id, depthMM: h, direction: d, snap: nil) })
            return
        }
        flatPreview = FlexibleFlatPreview(press: id, depthMM: h, direction: d)
    }

    /// ★ The release: the preview committed ONCE (setFlatCut); it ends whatever core says (a refusal springs the handle back).
    public func commitFlatPreview(_ id: UUID) async -> String? {
        guard let v = flatPreview, v.press == id, let p = settings.press(id) else { flatPreview = nil; return nil }
        let onHalfway = FlexibleFlatPrism.halfway(of: p).map { FlexiblePressAim.bits($0) == FlexiblePressAim.bits(v.direction) } ?? false
        let snap: String? = onHalfway ? FlexiblePress.Snap.halfway.raw
            : (FlexiblePressAim.bits(p.direction) == FlexiblePressAim.bits(v.direction) ? p.snap : nil)
        let why = await setFlatCut(id, depthMM: v.depthMM, direction: v.direction, snap: snap)
        flatPreview = nil
        return why
    }

    // MARK: - the seam's answers

    /// The press's synthetic key on core's open scene (nil: not registered — no scene, or core refused it).
    public func pressKey(_ id: UUID) -> Int? { pressRegistrations[id]?.key }

    /// Core's press stack of the press (its columns, its frame).
    public func pressStack(_ id: UUID) -> FlexStackInfo? { pressRegistrations[id]?.stack }

    /// ★ THE LATTICE CAP from core's columns (FlexibleFlatPrism.latticeCap): how deep the plane may go before a column's target
    /// leaves its lattice. nil: no stack.
    public func flatLatticeCap(_ id: UUID) -> Double? {
        guard let r = pressRegistrations[id] else { return nil }
        return FlexibleFlatPrism.latticeCap(r.stack, apexT: r.apexT)
    }

    /// The limits a press's handles hold to: core's footprint normals (L1), each face keeping some of itself (L3), and — for the
    /// depth — the lattice from core's columns (L5).
    func flatLimits(_ id: UUID, withLattice: Bool) -> FlexibleFlatPrismAngles.Limits {
        guard let p = settings.press(id), let st = p.strip, let mesh = project.viewerMesh else { return .init(loads: []) }
        return FlexibleFlatPrismAngles.Limits(loads: pressRegistrations[id]?.normals ?? [], keepsRest: Self.keepsRest(st, mesh: mesh),
                                              latticeCapMM: withLattice ? flatLatticeCap(id) : nil)
    }

    /// ★ HIS RULE (L3): the first member whose face would keep none of itself under (d, h) — nil when every face keeps some.
    static func keepsRest(_ st: FlexibleStrip, mesh: ViewerMesh) -> (SIMD3<Double>, Double) -> Int? {
        let tris = st.members.map { FlexibleEdgeStrips.triangles(face: $0.face, mesh: mesh) }
        return { d, h in
            let c = FlexibleFlatPrism.cut(st, direction: d, depthMM: h)
            return st.members.indices.first { !FlexibleFlatPrism.keepsRest(tris[$0], member: st.members[$0], c) }
        }
    }

    /// A member's face name for the lines ("Face 3").
    func flatMemberName(_ st: FlexibleStrip) -> (Int) -> String {
        { [weak self] k in self.map { FlexibleFlatPrismUI.memberName($0, st, k) } ?? "a face" }
    }

    // MARK: - the commit

    /// ★ ONE EDIT, ONE UNDO STEP: press `id` cut by the plane `depthMM` deep along `direction` (`snap`: the target's kind it sits on,
    /// "halfway" while d is the halfway's bits). The depth is held to what the faces allow (and the hold said). nil when stored (or
    /// nothing changed); else one line why nothing was stored.
    @discardableResult
    public func setFlatCut(_ id: UUID, depthMM: Double, direction: SIMD3<Double>, snap: String?) async -> String? {
        guard let p = settings.press(id), let st = p.strip, depthMM.isFinite, FlexiblePress.isAimable(direction) else { return nil }
        guard flatCommitting == nil else { return FlexibleRowCopy.edgePickOpening }
        let range = FlexibleFlatPrismAngles.depthRange(st, d: direction, limits: flatLimits(id, withLattice: false))
        let h = Swift.min(Swift.max(depthMM, range.min), range.max)
        if Swift.abs(h - depthMM) > 1e-9 {
            let stop = depthMM > range.max ? (range.maxStop ?? .shallow) : range.minStop
            toast = FlexibleFlatPrismAngles.heldLine(h, unit: " mm", stop: stop, strip: st, name: flatMemberName(st))
        }
        let unchanged = !FlexibleFlatPrism.isLegacy(p) && FlexiblePressAim.bits(p.direction) == FlexiblePressAim.bits(direction)
            && p.settings.deepestMM.bitPattern == h.bitPattern && p.snap == snap
        if unchanged { lastFlatStop = nil; return nil }
        flatCommitting = id
        defer { flatCommitting = nil }
        let why = await changeStrips(StripChange(cut: [id: FlatCutChange(depthMM: h, direction: direction, snap: snap)]))
        if why == nil { lastFlatStop = nil }
        return why
    }

    /// ★ A TYPED angle (a box): the other angle kept, held to the limits (the hold said), committed once. A typed value is kept as
    /// typed — the 3° snap is for drags only.
    @discardableResult
    public func setFlatAngle(_ id: UUID, degrees: Double, tilt: Bool) async -> String? {
        guard let p = settings.press(id), let st = p.strip, let c = flatCut(id), let f = FlexibleFlatPrismUI.frame(self, id) else { return nil }
        let now = FlexibleFlatPrismAngles.decompose(f, c.direction)
        let want = tilt ? (degrees, now.phi) : (now.theta, degrees)
        let r = FlexibleFlatPrismAngles.clamp(st, frame: f, h: c.depthMM, from: now, to: want, limits: flatLimits(id, withLattice: false))
        if let s = r.stop {
            toast = FlexibleFlatPrismAngles.heldLine(tilt ? r.theta : r.phi, unit: "\u{00B0}", stop: s, strip: st, name: flatMemberName(st))
        }
        let d = FlexibleFlatPrismAngles.compose(f, theta: r.theta, phi: r.phi)
        let snap: String? = r.theta == 0 && r.phi == 0 ? FlexiblePress.Snap.halfway.raw : nil
        return await setFlatCut(id, depthMM: c.depthMM, direction: d, snap: snap ?? (FlexiblePressAim.bits(d) == FlexiblePressAim.bits(p.direction) ? p.snap : nil))
    }

    /// [Back to halfway]: the arrow on its halfway again, the depth kept.
    @discardableResult
    public func flatBackToHalfway(_ id: UUID) async -> String? {
        guard let p = settings.press(id), let d0 = FlexibleFlatPrism.halfway(of: p), let c = flatCut(id) else { return nil }
        return await setFlatCut(id, depthMM: c.depthMM, direction: d0, snap: FlexiblePress.Snap.halfway.raw)
    }

    // MARK: - the seam: core's press stack for every strip press on the open scene

    /// ★ Register every strip press on core's open scene (a synthetic key each — a new one for every distinct scene, pieces and
    /// direction bits; never reused), and read back core's press stack, the apex's t and the footprint's per-triangle normals.
    /// Called after every recompute; a press already registered on THIS scene for these pieces and bits is not asked again.
    func registerPresses() {
        let list = (settings.presses ?? []).filter { $0.strip != nil }
        guard sceneState == .ready, !heldWithoutFacePrism, !list.isEmpty else {
            if !pressRegistrations.isEmpty { pressRegistrations = [:] }
            return
        }
        let source = openSceneAimSource
        let worker = frameWorker
        let known = pressRegistrations
        track(Task { @MainActor [weak self] in
            guard let self else { return }
            guard let sid = try? await worker.withScene({ ObjectIdentifier($0) }) else { return }
            var out: [UUID: FlexiblePressRegistration] = [:]
            var refused: [UUID: String] = [:]
            for p in list {
                let bits = FlexiblePressAim.bits(p.direction)
                if let k = known[p.id], k.scene == sid, k.regions == p.regions, k.direction == bits { out[p.id] = k; continue }
                guard let cut = FlexibleFlatPrism.cut(of: p) else { continue }
                do {
                    let r = try await worker.withScene { s -> (Int, FlexStackInfo, Double) in
                        let key = try s.registerPress(p.regions, direction: p.direction)
                        let st = try s.stack(face: key, rotation: 0)
                        let t = try s.toUVT(face: key, rotation: 0, [cut.apex.x, cut.apex.y, cut.apex.z])
                        return (key, st, t.count >= 3 ? t[2] : 0)
                    }
                    let normals = (try? await Self.footprintNormals(p.regions, source: source)) ?? nil
                    out[p.id] = FlexiblePressRegistration(scene: sid, regions: p.regions, direction: bits, key: r.0, stack: r.1,
                                                          apexT: r.2, normals: normals ?? [])
                } catch {
                    refused[p.id] = self.plainLine("\(error)")
                }
            }
            // the scene may have moved on while core was asked: only a current answer is kept
            guard let now = try? await worker.withScene({ ObjectIdentifier($0) }), now == sid else { return }
            if out != self.pressRegistrations { self.pressRegistrations = out }
            if refused != self.pressRefusals { self.pressRefusals = refused }
        })
    }

    /// ★ M2's strips read through — said once per session (one toast).
    func announceLegacyStrips() {
        guard !legacyStripsSaid, (settings.presses ?? []).contains(where: FlexibleFlatPrism.isLegacy) else { return }
        legacyStripsSaid = true
        toast = FlexibleRowCopy.stripsAreFlatNow
    }
}

/// What a flat-cut change puts on a press (StripChange.cut).
struct FlatCutChange: Equatable {
    var depthMM: Double
    var direction: SIMD3<Double>
    var snap: String?
}
