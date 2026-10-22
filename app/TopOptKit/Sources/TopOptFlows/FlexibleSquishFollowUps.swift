// FlexibleSquishFollowUps — round 7 batch F, the Squish page's follow-ups from his 2026-10-14 answers (task
// 2026-09-29-flexible-screens; tasks.md "His answers on the R7-S/R7-V handoff questions" and "on the remaining handoff
// questions", with his clarifications). Tests: FlexibleR7FTests (each with its RED control).
//   (1) Q7a "Group trash should confirm deletion." — one line in the panel's header: "Delete Group 2? · [Delete] [Keep]".
//       Q11: the face row's trash looks different — a smaller TAKE-OUT glyph (it only takes that face out of the setup).
//   (2) Q5a "Yes. Allow an *empty* setup after reset all." — with nothing set to squish, "nothing pressed" no longer holds
//       Exit (Exit / Save & Exit); Q9 "Do not." — the top line suggests no face ("Nothing to squish yet", no [Fix], no
//       pop-up). His Q7 (the Top after Reset all at an EQUAL SHARE PER LATTICE PART) was already M2's: the test pins it.
//   (3) Q10 the face card's group chips show the squeeze groups' NAMES (Squish-only names: the main page never sees them).
//   (4) Q12-answer "If bend is on, all views move to the furthest bend. Always. Bend view and Play cannot be viewed
//       simultaneously." — one toggle rule for both pages (Bend on turns Play off and back); with Bend on, everything drawn
//       ON the part sits where the bent part puts it (FlexibleBendPose): the curves, the stamp's handle, the group discs and
//       outlines, the prisms' faces and the glass. What stands INSIDE the part (a prism's floor and its depth chip, the
//       Prisms view's floor tags) stays: the bent face comes down to meet it. ★ ROUND 7 REVIEW (R, his answer of
//       2026-10-15): REVERSED — the floors, the depth chip and the floor tags move with the bend too (FlexibleR7ReviewFixes).
//   (5) Q12 "The curve should be viewed as nothing but the curve without any view turned on. Turning heat map on shows
//       colour." — the page opens with Heat off (FlexibleStageModel.openingViews).
//   (6) Q13 "Heat follows whatever group is selected, first group as default. Hold for 3 seconds to view all. No picker
//       needed." + his clarification: on the main page, the squeeze group of the face he last tapped; the 3 s hold there
//       too. The main page's shown squeeze follows it (first group by default, every group under the hold); the play bar
//       carries no group picker.

import Foundation
import simd
import TopOptKit

// MARK: - (1) the trash

/// The two trash glyphs: the GROUP's trash deletes a group; the FACE row's take-out only takes that face out of the setup.
enum FlexibleTrashGlyphs {
    static let group = "trash"
    static let groupSize: CGFloat = 14
    static let face = "minus.circle"
    static let faceSize: CGFloat = 12
}

extension FlexibleRowCopy {
    /// The group trash's one line.
    static func deleteGroupAsk(_ name: String) -> String { "Delete \(name)?" }
    static let deleteGroupConfirm = "Delete"
    static let deleteGroupKeep = "Keep"
    /// The face row's take-out (spoken).
    static func takeFaceOut(_ name: String) -> String { "Take \(name) out of the squish" }
}

extension FlexibleStageModel {
    /// ★ RED CONTROL: today's trash (R7-S) — the group goes at once.
    @MainActor static var controlTrashDeletesAtOnce = false

    /// The group trash: it ASKS ("Delete Group 2?" — ★ U21: in place, on the group's trash; FlexibleConfirmInPlace); nothing
    /// changes until [Delete].
    public func askDeleteGroup(_ groupID: Int) {
        guard squeezeGroups.contains(where: { $0.id == groupID }) else { groupDeleteAsk = nil; return }
        if Self.controlTrashDeletesAtOnce { groupDeleteAsk = nil; removeGroup(groupID); return }
        dropInPlaceAsks()   // ★ U21: one ask at a time
        groupDeleteAsk = groupID
    }
    /// [Delete]: the group asked about is deleted (R7-S's delete: one undo step).
    public func confirmDeleteGroup() {
        guard let id = groupDeleteAsk else { return }
        groupDeleteAsk = nil
        removeGroup(id)
    }
    /// [Keep]: nothing changes.
    public func keepGroup() { groupDeleteAsk = nil }

    // MARK: (2) the empty setup

    /// Nothing set to squish — no face and no press (what Reset all leaves).
    public var isEmptySetup: Bool { settings.faces.isEmpty && presses.isEmpty }

    // MARK: (5) the opening look

    /// ★ RED CONTROL: R7-V's opening look — the current group's heat.
    @MainActor static var controlHeatOnByDefault = false
    /// The views the page opens with: no view on — the curve only, no colour (Heat's bit means hidden).
    @MainActor static var openingViews: FlexibleStageViews { controlHeatOnByDefault ? [] : [.heatOff] }
}

extension FlexibleSettingsExit {
    /// ★ RED CONTROL: today's rule — "nothing pressed" holds Exit and the line names a face to press.
    @MainActor static var controlEmptyBlocks = false
    /// The top line over an empty setup (it suggests no face).
    public static let emptyLine = "Nothing to squish yet"

    /// Does the empty setup leave freely? Only "nothing pressed" stands (a missing filament still holds it).
    @MainActor static func emptyLeaves(_ r: FlexibleReadiness, empty: Bool) -> Bool {
        empty && !controlEmptyBlocks && r.blocking.allSatisfy { $0.kind == .noPressedFace }
    }
    @MainActor public static func title(_ r: FlexibleReadiness, modified: Bool, empty: Bool) -> String {
        guard emptyLeaves(r, empty: empty) else { return title(r, modified: modified) }
        return modified ? saveAndExit : exit
    }
    @MainActor public static func decide(_ r: FlexibleReadiness, modified: Bool, empty: Bool) -> FlexibleExitDecision {
        emptyLeaves(r, empty: empty) ? .exit : decide(r, modified: modified)
    }
    @MainActor public static func topLine(_ r: FlexibleReadiness, modified: Bool, empty: Bool) -> String {
        emptyLeaves(r, empty: empty) ? emptyLine : readyLine(r.oneLine, modified: modified)
    }
}

// MARK: - (3) the chips

extension FlexibleFaceGroupRow {
    /// ★ RED CONTROL: today's chips — the groups' numbers.
    @MainActor static var controlChipsByNumber = false
}

// MARK: - (4) Bend and Play; the full-bend pose

extension FlexibleStageViews {
    /// ★ RED CONTROL: R7-V's rule — Bend and Play together (the full pose a ghost beside the animation).
    nonisolated(unsafe) static var controlBendWithPlay = false
    /// A view button's toggle — ★ Bend and Play are never on together: turning one on turns the other off.
    public mutating func toggle(_ v: FlexibleStageViews) {
        if contains(v) { remove(v); return }
        insert(v)
        guard !Self.controlBendWithPlay else { return }
        if v == .bend { remove(.play) }
        if v == .play { remove(.bend) }
    }
}

extension FlexibleStagePage {
    /// ★ RED CONTROL: R7-V's rule — Bend alone hides what is drawn on the part; with Heat or Prisms it stays at rest.
    @MainActor static var controlBendRestPose = false
    /// Bend on (and so Play off): what is drawn on the part sits at the full bend.
    @MainActor static func posesOverlays(views: FlexibleStageViews) -> Bool {
        !controlBendRestPose && views.contains(.bend) && !views.contains(.play)
    }
    /// The full-bend pose of the page's overlay mesh bent by `dents` × `k` (the renderer's own), or nil.
    /// ★ U21 (LBR-EDGES): `faces` — the column preview's pressed faces (a point ON one takes that face's own bend: the squares'
    /// corners around it); `field` — the 3D sim shown (a point takes the field's own sample there). Both nil: the nearest vertex.
    /// ★ U21 FIX 1: `edges` — the edge preview's pushes (a point takes their sum there: the outline on the same smooth dent).
    @MainActor static func bendPose(views: FlexibleStageViews, overlay: FlexibleOverlayMesh?, dents: [Float]?, k: Double,
                                    faces: [FlexibleBendPose.FaceBend] = [], field: FlexibleFEField? = nil,
                                    edges: [FlexibleSettingsSquish.EdgePush] = []) -> FlexibleBendPose? {
        guard posesOverlays(views: views), let o = overlay, let d = dents, k > 0 else { return nil }
        return FlexibleBendPose.cached(positions: o.mesh.flat.positions, dents: d, k: k, signature: o.mesh.signature.contentHash,
                                       faces: faces, field: field, edges: edges)
    }
}

/// ★ (4) THE FULL-BEND POSE: a point on the part moves by the bend at the nearest vertex of the page's overlay mesh — its
/// displacement × k, exactly what the renderer moves that vertex by (flexDisplacements × flexScale). A point farther than
/// `reach` from the part's surface (a prism's floor, its depth chip, the floor tags) stays: the bent face meets it.
struct FlexibleBendPose {
    let key: String
    let cell: Float
    let reach: Float
    private let lo: SIMD3<Float>
    private let buckets: [SIMD3<Int32>: [Int32]]
    private let positions: [SIMD3<Float>]
    private let moves: [SIMD3<Float>]
    /// ★ U21 (LBR-EDGES, his Img15: "is it calculating how much the TPU can actually stretch at the edges without ripping? Is that
    /// what those sharp edges mean?" — no: a drawing fault). The nearest vertex flipped between two layers that lie together over a
    /// pressed face's rim — the squares (moved up to 7.8 mm) and the part's still solid rim (0) — so the 10 % indent outline on his
    /// Face 6 zig-zagged (369 of 534 segments jumped > 2 mm). A point ON a pressed face (over its grid, half a pitch out, within a
    /// pitch of its plane — the indent's padded ring, the curves, the glass, a prism's face) now takes that face's OWN bend: the
    /// squares' corners around it (`FlexibleOverlayMesh.CornerGrid`, the numbers the renderer moves the squares by); in the 3D sim
    /// the field's own sample there. Other points keep the nearest vertex.
    let faces: [FaceBend]
    let field: FlexibleFEField?
    let k: Float
    /// ★ U21 FIX 1: the edge preview's pushes — every point takes their sum (zero outside the flat prisms, as the renderer's vertices).
    let edges: [FlexibleSettingsSquish.EdgePush]
    /// ★ RED CONTROL only (U21 fix 1): the edge preview posed by the nearest vertex (fix 1's first try: a jagged outline).
    nonisolated(unsafe) static var controlNearestVertexEdges = false

    /// One pressed face's bend for the pose: its squares' corner grid and its frame (core's from_uv(0, 0) back along the load).
    struct FaceBend {
        let grid: FlexibleOverlayMesh.CornerGrid
        let origin: SIMD3<Double>
        /// The squares' corner extent (cached: the grid's).
        let extent: (u: ClosedRange<Double>, w: ClosedRange<Double>)?
        init(grid: FlexibleOverlayMesh.CornerGrid, origin: SIMD3<Double>) {
            self.grid = grid; self.origin = origin; self.extent = grid.extent
        }
        /// The face's own bend at `p` (mm along its load, before × k) when `p` lies ON the face; nil off it. `gap`: how far
        /// `p` sits off the face's plane.
        func bend(at p: SIMD3<Double>) -> (mm: Double, gap: Double)? {
            let st = grid.stack
            let q = p - origin
            let p2 = st.pitchMM / 2
            let u0 = simd_dot(q, st.xAxis), w0 = simd_dot(q, st.yAxis), t = simd_dot(q, st.load)
            // ★ a stamp partly off the face (his Img1: "3.0 N of the stamp lands off the face") is drawn on in the face's plane past
            // its edge: that part keeps the edge's bend (within `offFaceMM`), so the outline never steps from the bent edge to rest
            guard let e = extent else { return nil }
            let u = Swift.min(Swift.max(u0, e.u.lowerBound - p2), e.u.upperBound + p2)
            let w = Swift.min(Swift.max(w0, e.w.lowerBound - p2), e.w.upperBound + p2)
            guard abs(u - u0) <= FaceBend.offFaceMM, abs(w - w0) <= FaceBend.offFaceMM, let c = grid.column(u: u, w: w) else { return nil }
            let gap = abs(t - c.entryT)
            guard gap <= Swift.max(st.pitchMM, 1), let b = grid.bend(u: u, w: w) else { return nil }
            return (b, gap)
        }
        /// How far past a face's grid (in its plane) a point still takes the face's edge bend.
        static let offFaceMM = 40.0
    }

    /// ★ RED CONTROL only (LBR-EDGES): every point by the nearest overlay vertex (the zig-zag).
    nonisolated(unsafe) static var controlNearestVertexPose = false

    init?(positions p: [Float], dents d: [Float], k: Double, key: String = "", faces: [FaceBend] = [], field: FlexibleFEField? = nil,
          edges: [FlexibleSettingsSquish.EdgePush] = []) {
        let n = Swift.min(p.count, d.count) / 3
        guard n > 0, k > 0, k.isFinite else { return nil }
        var pos = [SIMD3<Float>](), mv = [SIMD3<Float>]()
        pos.reserveCapacity(n); mv.reserveCapacity(n)
        var lo = SIMD3<Float>(repeating: .greatestFiniteMagnitude), hi = -lo
        for v in 0..<n {
            let q = SIMD3<Float>(p[3 * v], p[3 * v + 1], p[3 * v + 2])
            pos.append(q)
            mv.append(SIMD3<Float>(d[3 * v], d[3 * v + 1], d[3 * v + 2]) * Float(k))
            lo = simd_min(lo, q); hi = simd_max(hi, q)
        }
        let cell = Swift.max(1, simd_length(hi - lo) / 48)
        var b: [SIMD3<Int32>: [Int32]] = [:]
        for (i, q) in pos.enumerated() { b[Self.bucket(q, lo: lo, cell: cell), default: []].append(Int32(i)) }
        self.key = key; self.cell = cell; self.reach = cell; self.lo = lo
        self.buckets = b; self.positions = pos; self.moves = mv
        self.faces = faces; self.field = field; self.k = Float(k); self.edges = edges
    }

    private static func bucket(_ q: SIMD3<Float>, lo: SIMD3<Float>, cell: Float) -> SIMD3<Int32> {
        let c = (q - lo) / cell
        return SIMD3<Int32>(Int32(c.x.rounded(.down)), Int32(c.y.rounded(.down)), Int32(c.z.rounded(.down)))
    }

    /// The bend at `p`: the nearest overlay vertex's displacement × k, within `reach` of the part's surface; else none.
    func displacement(at p: SIMD3<Float>) -> SIMD3<Float> {
        if !edges.isEmpty, !Self.controlNearestVertexPose, !Self.controlNearestVertexEdges {
            let pd = SIMD3<Double>(p)
            var mv = SIMD3<Double>.zero
            for e in edges { mv += e.move(pd) }
            return SIMD3<Float>(mv) * k
        }
        if !Self.controlNearestVertexPose, field == nil, !faces.isEmpty {
            let pd = SIMD3<Double>(p)
            var best: (mm: Double, gap: Double, load: SIMD3<Double>)?
            for f in faces {
                guard let b = f.bend(at: pd), best == nil || b.gap < best!.gap else { continue }
                best = (b.mm, b.gap, f.grid.stack.load)
            }
            if let b = best { return SIMD3<Float>(b.load * b.mm) * k }
        }
        let n = nearest(p)
        guard n >= 0 else { return .zero }
        if !Self.controlNearestVertexPose, let f = field { return f.sample(p) * k }
        return moves[Int(n)]
    }

    /// The nearest overlay vertex within `reach` of `p`, or −1.
    private func nearest(_ p: SIMD3<Float>) -> Int32 {
        let c = Self.bucket(p, lo: lo, cell: cell)
        var best: Int32 = -1
        var bestD = reach * reach
        for dz in -1...1 { for dy in -1...1 { for dx in -1...1 {
            guard let list = buckets[c &+ SIMD3<Int32>(Int32(dx), Int32(dy), Int32(dz))] else { continue }
            for i in list {
                let e = simd_length_squared(positions[Int(i)] - p)
                if e <= bestD { bestD = e; best = i }
            }
        } } }
        return best
    }
    /// `p` at the full bend.
    func apply(_ p: SIMD3<Float>) -> SIMD3<Float> { p + displacement(at: p) }
    func apply(_ p: SIMD3<Double>) -> SIMD3<Double> { SIMD3<Double>(apply(SIMD3<Float>(p))) }

    /// A 3D item at the full bend: a shell's FACE (its base) follows the bend — ★ ROUND 7 REVIEW (R, his answer of
    /// 2026-10-15: "With Bend on, the depth chip and depth labels MOVE with the bend (everything goes to the full-bend
    /// pose)") and so does its floor: each floor point by the bend of its own face point (F kept the floor at rest:
    /// `controlInsideStays`). The depth chip and the floor tags sit on the floor, so they move with it.
    func pose(_ item: ClearanceRenderItem) -> ClearanceRenderItem {
        guard case .shell = item.volume.shape else { return item }
        return ClearanceRenderItem(volume: pose(item.volume), selected: item.selected, tint: item.tint, faceAlpha: item.faceAlpha,
                                   edgeAlpha: item.edgeAlpha, surfaceOnly: item.surfaceOnly)
    }
    /// A prism volume at the full bend (its face and, ★ R, its floor — the depth chip's handle is read from it).
    func pose(_ v: ClearanceVolume) -> ClearanceVolume {
        guard case .shell(let s) = v.shape else { return v }
        let floor = Self.controlInsideStays ? s.offset
            : zip(s.offset, s.base).map { o, b in o + displacement(at: b) }
        let shell = FaceOffsetShell(base: s.base.map { apply($0) }, offset: floor, indices: s.indices,
                                    reachedDepthMM: s.reachedDepthMM, clampedFromMM: s.clampedFromMM)
        return ClearanceVolume(faceID: v.faceID, kind: v.kind, shape: .shell(shell))
    }

    // the page asks on every body pass: one pose per (mesh, dents, k), one posed list per (pose, items)
    @MainActor private static var poseCache: (key: String, pose: FlexibleBendPose?)?
    @MainActor private static var itemsCache: (key: String, items: [ClearanceRenderItem], posed: [ClearanceRenderItem])?

    @MainActor static func cached(positions: [Float], dents: [Float], k: Double, signature: UInt64,
                                  faces: [FaceBend] = [], field: FlexibleFEField? = nil,
                                  edges: [FlexibleSettingsSquish.EdgePush] = []) -> FlexibleBendPose? {
        // ★ U21: which rule poses (the faces' own bend, the field, the edge pushes, the nearest vertex) is part of the key
        let source = field.map { "f\($0.simID)|\($0.serial)" } ?? "c\(faces.count)|e\(edges.count)"
        let key = Self.key(positions: positions, dents: dents, k: k, signature: signature) + "|\(source)|\(controlNearestVertexPose)|\(controlNearestVertexEdges)"
        if let c = poseCache, c.key == key { return c.pose }
        let pose = FlexibleBendPose(positions: positions, dents: dents, k: k, key: key, faces: faces, field: field, edges: edges)
        poseCache = (key, pose)
        return pose
    }
    /// ★ ROUND 7 REVIEW (R — the review of F: "the Bend pose cache key collides across groups and dents"): the pose's key
    /// is the WHOLE bend — every dent's bytes — with the overlay and k. F hashed every count/256-th dent: on his pad
    /// (133 650 values, a step of 522, a multiple of 3) every sample was a vertex's x, zero for a press along y or z, so
    /// every group's bend had ONE key and the page (and the next test in the process) kept the first pose it made.
    @MainActor static func key(positions: [Float], dents: [Float], k: Double, signature: UInt64) -> String {
        var h = Hasher()
        h.combine(dents.count); h.combine(k); h.combine(signature)
        if controlSampledKey {
            let step = Swift.max(1, dents.count / 256)
            var i = 0
            while i < dents.count { h.combine(dents[i]); i += step }
        } else {
            dents.withUnsafeBytes { h.combine(bytes: $0) }
        }
        return "\(positions.count)|\(h.finalize())"
    }
    /// `items` at the full bend (`pose` nil: as they are).
    @MainActor static func posed(_ items: [ClearanceRenderItem], by pose: FlexibleBendPose?) -> [ClearanceRenderItem] {
        guard let pose else { return items }
        if let c = itemsCache, c.key == pose.key, c.items == items { return c.posed }
        let out = items.map { pose.pose($0) }
        itemsCache = (pose.key, items, out)
        return out
    }
}

extension Array where Element == ClearanceRenderItem {
    /// These items at the full bend (`pose` nil: as they are) — FlexibleBendPose.posed.
    @MainActor func posed(by pose: FlexibleBendPose?) -> [ClearanceRenderItem] { FlexibleBendPose.posed(self, by: pose) }
}

extension FlexibleCurveBaseline {
    /// The baseline at the full bend (the curve rises from the bent face).
    func posed(_ pose: FlexibleBendPose?) -> FlexibleCurveBaseline {
        guard let pose else { return self }
        var b = self
        b.points = points.map { pose.apply($0) }
        return b
    }
}

// MARK: - (6) the main page's heat follows the selected group

extension FlexibleMainStage {
    /// ★ RED CONTROL: today's main page — "Play all" by default (the lattice's default) and the group picker in the bar.
    @MainActor static var controlPlayAllDefault = false

    /// The squeeze the main page shows (its heat and its squish): every group under his 3 s hold ("Play all"), else the
    /// group of the face he last tapped, else the FIRST group. nil: one group (nothing to choose) — the lattice's default.
    @MainActor static func heatSim(sims: [FlexibleSim], tappedGroup: Int?, all: Bool) -> String? {
        guard sims.count > 1, !controlPlayAllDefault else { return nil }
        if all, let a = sims.first(where: { $0.kind == .playAll }) { return a.id }
        if let n = tappedGroup, let s = sims.first(where: { $0.kind == .group(n) }) { return s.id }
        return sims.first { if case .group = $0.kind { return true } else { return false } }?.id
    }

    /// The squeeze group of the face he last tapped on the main page (nil: none yet — the first group shows).
    var tappedGroupNumber: Int? { tappedRegion.flatMap { model?.squeezeGroup(of: $0)?.number } }

    /// The squeeze the main page shows: his pick (the heat's group) or the default rule.
    var selectedSim: String? { shownSim ?? Self.heatSim(sims: sims, tappedGroup: tappedGroupNumber, all: heatAll) }

    /// A tap on the main page's part (H7's surface tap, before #354 handles it): the face's squeeze group becomes the
    /// selected one (a face in no group keeps the last); the heat — and the squish — follow it.
    func noteMainTap(face: Int, point: SIMD3<Float>?) {
        guard let m = model else { return }
        let mesh = m.project.viewerMesh
        let pt = point.map { SIMD3<Double>($0) }
        var region: Int?
        if m.facePrismsSet, let p = pt { region = m.regions.pressable(at: p, face: face, mesh: mesh) }
        var r = region ?? m.regions.region(at: pt, face: face, mesh: mesh)
        // ★ ROUND 7 REVIEW (R): a tap on a face's SOLID middle (its root, in no group) picks its lattice parts' group when
        // they all press in one (F kept the last group, with no cue)
        if m.squeezeGroup(of: r) == nil, !Self.controlTapRootIgnored, let part = Self.onePartsGroup(of: r, model: m) { r = part }
        guard m.squeezeGroup(of: r) != nil else { return }
        tappedRegion = r
        followHeatGroup()
    }

    /// His 3 s hold on the heat icon: every group's heat.
    func heatHeld() {
        if stress { stress = false }
        heatAll = true
        if !heat { heat = true }
        followHeatGroup()
    }

    /// The shown squeeze follows the rule (a pick only when it changes).
    func followHeatGroup() {
        guard let want = Self.heatSim(sims: sims, tappedGroup: tappedGroupNumber, all: heatAll), want != selectedSimPicked else { return }
        pick(want)
    }
    private var selectedSimPicked: String? { shownSim }
}

extension FlexibleMainPlayerSlot {
    /// ★ (6) No group picker in the play bar (his "No picker needed"); the RED control keeps it.
    @MainActor static func pickerSims(_ sims: [FlexibleSim]) -> [FlexibleSim] {
        FlexibleMainStage.controlPlayAllDefault ? sims : []
    }
}
