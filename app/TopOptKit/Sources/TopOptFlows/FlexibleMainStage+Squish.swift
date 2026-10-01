// FlexibleMainStage+Squish — the main page's squish, one continuous 3D field per squeeze group
// (task 2026-09-29-flexible-screens, round 5 batch G, §5–§7).
//
// ★ WHAT HE SEES. Save & Exit: the lattice at once, held at rest, "Simulating the squish…" in the
// player's note slot for a few seconds; then the part plays — the pressed faces sink, the free
// sides BULGE, and the ghost, the bent heat plane and the walls move as ONE body (the same field,
// the same flexScale). With two or more groups the picker lists each group and "Play all", which
// plays the groups ONE AFTER ANOTHER (the renderer swaps field and mesh together at rest). The
// numbers (colours, legend ends, tap-to-read) stay core's: the field gives the SHAPE, scaled so its
// deepest zone moves exactly core's deepest squish.
// ★ FALLBACK. A sim that fails (or runs past its deadline) plays today's column squish, with one
// line ("Simple squish · the sim failed") and core's words behind the Squish legend's (i); a failed
// sim is left out of Play all but stays pickable, and Play all says so ("Group 2 skipped · its sim
// failed"). When EVERY sim of Play all failed, the first group's column squish plays (never every
// group's faces at once — his round-5 (a): "not as a combo").
// ★ BATCH G VERIFICATION. The sims are started BEFORE they are read, so the very first refresh after
// Save & Exit already sees them pending (it used to read an empty cache, fall to the column branch
// and play the old column squish for ~1–2 s, then snap to rest); a lattice whose FE request is in
// hand but not yet scheduled is pending too.

import Foundation
import simd

/// What the main page draws of the squish sims for the lattice on screen (one value per refresh).
struct FlexibleFEView: Equatable {
    /// The landed fields, in group order (the renderer holds them all; the sequence indexes them).
    var fields: [FlexibleFEField] = []
    /// Per field: its mesh displacements on the page's overlay (the ghost and the heat plane).
    var mesh: [[Float]] = []
    /// What the loop plays (indices into `fields`): a pick is [g], "Play all" every landed group.
    var sequence: [Int] = []
    /// The sims the page ASKED for (the pick, or every group under "Play all") — landed or not.
    var requested: [String] = []
    /// Sims of the request that failed while others play ("Play all" skips them — said).
    var skipped: [String] = []
    /// The generation and the landed fields (the pass re-uploads by it).
    var token = 0
    /// A sim of the sequence still runs.
    var pending = false
    /// Nothing of the sequence has a field and a sim failed: core's words.
    var failure: String?
    /// The largest scale every field of the sequence stays injective at (s · gmax ≤ ½).
    var safeScale = Double.infinity
    /// The sequence's first clamped field: how much stiffer (> 1) or softer the sim found the part
    /// than core's columns (the (i) says it).
    var coreRatio: Double?
    /// The smallest share a field of the sequence was cut to so it never folds at ×1 (the (i)).
    var foldShare: Double?
    /// The largest scale every field's PART stays injective at (the (i)'s large-strain case).
    var partSafeScale = Double.infinity
    /// A field of the sequence was solved with every rest held fast (its sliding solve did not
    /// settle — the one retry): the (i) says so.
    var restsBonded = false
    /// The FE field moves the picture.
    var active: Bool { !sequence.isEmpty }

    static func == (a: Self, b: Self) -> Bool {
        a.token == b.token && a.sequence == b.sequence && a.pending == b.pending && a.failure == b.failure
            && a.requested == b.requested && a.skipped == b.skipped
    }
}

extension FlexibleMainStage {

    /// The FE view of `drawn` (the lattice as the player shows it), starting its sims when they
    /// have not started (the shown sim first). Cheap: the mesh displacements are cached per
    /// (overlay, field).
    func feView(_ m: FlexibleStageModel, drawn: FlexibleGeneratedLattice?) -> FlexibleFEView {
        guard let g = drawn, !m.latticeIsStale, !controlColumnSquish else { return FlexibleFEView() }
        let groupIDs = m.squishSims.map(\.sim.id)
        // the sequence: the pick, or every group ("Play all", or one group with nothing to pick)
        let seqIDs: [String] = g.shownSimID.flatMap { id in groupIDs.contains(id) ? [id] : nil } ?? groupIDs
        // ★ started FIRST (it marks them pending in the same step), read AFTER — the red control
        // reads first, as batch G did
        let early = controlReadSimsBeforeStart ? m.squishSims : nil
        if visible, !frozen { m.startSquishSims(first: seqIDs.first) }
        let groups = early ?? m.squishSims
        // a lattice whose FE request is in hand but not scheduled yet: its sims are as good as pending
        let unscheduled = !controlReadSimsBeforeStart && m.feRequest?.generation == g.generation
            && m.squishScheduled != g.generation && !groupIDs.isEmpty
        var v = FlexibleFEView()
        v.requested = seqIDs
        guard m.squishGeneration == g.generation, groups.contains(where: { $0.state != nil }) else {
            v.pending = unscheduled
            return v
        }
        v.fields = groups.compactMap { $0.state?.field }.filter { $0.generation == g.generation }
        v.mesh = v.fields.map { feMesh(for: $0) }
        v.sequence = seqIDs.compactMap { id in v.fields.firstIndex { $0.simID == id } }
        v.pending = seqIDs.contains { m.squish[$0] == .pending } || unscheduled
        if v.sequence.isEmpty, !v.pending { v.failure = seqIDs.compactMap { m.squish[$0]?.failure }.first }
        if !v.sequence.isEmpty { v.skipped = seqIDs.filter { m.squish[$0]?.failure != nil } }
        var h = Hasher()
        h.combine(g.generation)
        for f in v.fields { h.combine(f.serial); h.combine(f.scale) }
        h.combine(overlaySerial)
        v.token = h.finalize()
        v.safeScale = v.sequence.map { v.fields[$0].maxSafeScale }.min() ?? .infinity
        v.coreRatio = v.sequence.map { v.fields[$0] }.first { $0.clamped }?.coreRatio
        v.restsBonded = v.sequence.contains { v.fields[$0].restsBonded }
        v.foldShare = v.sequence.compactMap { v.fields[$0].foldShare }.min()
        v.partSafeScale = v.sequence.map { v.fields[$0].partSafeScale }.min() ?? .infinity
        return v
    }

    /// A field's mesh displacements on the current overlay (cached per overlay and field).
    func feMesh(for f: FlexibleFEField) -> [Float] {
        guard let o = overlay else { return [] }
        let key = "\(overlaySerial)|\(f.serial)|\(f.scale)"
        if let c = feMeshCache[f.simID], c.key == key { return c.mesh }
        let mesh = f.meshDisplacements(positions: o.mesh.flat.positions)
        feMeshCache[f.simID] = (key, mesh)
        return mesh
    }

    /// ★ BATCH M (M5, M2b — his round-5 img 5: "The dent colours are not expanding out and graded";
    /// img 4: the stamps "seen as isolated areas … it should have foci but expand out, pulling lattice
    /// next to it in"). In FE mode the heat is the 3D sim's OWN squish: per column of the group's
    /// pressed faces, how much the sim COMPRESSES it along its load (entry − exit, to the middle where
    /// a pinch halves it — `FlexibleFEField.columnCompression`, core's own quantity and the one the
    /// calibration matches), then the corner mean at every map vertex (`mapCornerValues` — the colour
    /// grades across the map with no step). In mm at the CALIBRATED size: the sim scaled to core's
    /// deepest squish within the band [0.5, 2] (FlexibleFE.calibrationBand), the fold cut taken back
    /// out (`/ foldShare` — the cut only keeps the PICTURE from folding at ×1). Where the sim and core
    /// agree (his Group 2: k 2.09) the fingertips read core's 24.5 mm; where the sim finds the part
    /// far stiffer (his Group 1: k asked 7.4, held at 2 — the Squish (i) says so) the heat reads what
    /// the sim squishes, not core's number: × the asked k put 88 mm on his 100 mm-deep Face 5, which
    /// the band exists to refuse. A column the sim stretches reads 0. NaN off the group's faces.
    /// Cached per (overlay, field).
    func feMapValues(_ f: FlexibleFEField, _ m: FlexibleStageModel) -> [Float]? {
        guard let o = overlay else { return nil }
        let key = "\(overlaySerial)|\(f.serial)|\(f.scale)"
        if let c = feValueCache[f.simID], c.key == key { return c.values }
        let keys = Set(m.lattice?.sims.first { $0.id == f.simID }?.keys ?? [])
        let ratio = 1 / Swift.max(1e-6, f.foldShare ?? 1)
        var perColumn: [FlexFaceKey: [Double?]] = [:]
        for k in o.flatStart.keys where keys.contains(k) {
            guard let st = m.stacks[k] else { continue }
            let pinched = m.pinchedColumns(k.region) ?? []
            perColumn[k] = st.columns.indices.map { c in
                Swift.max(0, f.columnCompression(stack: st, col: c, pinched: c < pinched.count && pinched[c]) * ratio)
            }
        }
        let out = o.mapCornerValues(perColumn, stacks: m.stacks)
        feValueCache[f.simID] = (key, out)
        return out
    }

    /// The FE heat of the sequence on screen: every face by its OWN group's sim (the pick's field; under
    /// "Play all" each group's faces by theirs — the renderer swaps in each turn's own, which match it on
    /// that group's faces) and the ONE scale over every field of it.
    func feHeat(_ m: FlexibleStageModel) -> (first: [Float], scaleMM: Double)? {
        guard fe.active, !controlColumnHeat else { return nil }
        let all = fe.sequence.compactMap { i in i < fe.fields.count ? feMapValues(fe.fields[i], m) : nil }
        guard var union = all.first else { return nil }
        for v in all.dropFirst() {
            for i in union.indices where i < v.count && !union[i].isFinite && v[i].isFinite { union[i] = v[i] }
        }
        let top = all.map { $0.reduce(Float(0)) { $1.isFinite ? Swift.max($0, $1) : $0 } }.max() ?? 0
        return top > 1e-6 ? (union, Double(top)) : nil
    }

    /// The heat a tap reads now: the field on screen's (FE), else the page's corner values.
    var shownHeatValues: [Float]? {
        if let f = feShownField, let m = model, let v = feMapValues(f, m) { return v }
        return heatValues
    }

    /// The mesh displacements the renderer shows NOW (the loop's shown field) — H4's `dents` in FE
    /// mode, so a mesh rebuild re-uploads the sim on screen, and tap-to-read casts against it.
    var feShownMesh: [Float]? {
        let v = fe
        guard v.active else { return nil }
        let i = v.sequence.contains(loop.shownIndex) ? loop.shownIndex : v.sequence[0]
        return i < v.mesh.count ? v.mesh[i] : nil
    }

    /// The field on screen now (the lattice reading's pull-back).
    var feShownField: FlexibleFEField? {
        let v = fe
        guard v.active else { return nil }
        let i = v.sequence.contains(loop.shownIndex) ? loop.shownIndex : v.sequence[0]
        return i < v.fields.count ? v.fields[i] : nil
    }

    /// The dent H4 hands the renderer and the taps read: the FE mesh on screen, else the column dent.
    var shownDents: [Float]? { feShownMesh ?? channels?.dents }

    /// The player's note from the sims: "Simulating the squish…" while one of the sequence runs,
    /// "Simple squish · the sim failed" when it fell back, "Group 2 skipped · its sim failed" when
    /// Play all plays the others.
    var feNote: String? {
        if fe.pending { return FlexibleFE.pending }
        if fe.failure != nil { return FlexibleFE.failed }
        if let id = fe.skipped.first, let sim = sims.first(where: { $0.id == id }) { return FlexibleFE.skipped(sim.short) }
        return nil
    }

    /// "Play all" is playing its groups' own sims in turn (the picker says which — FlexibleSquishPlayer).
    public var playAllLive: Bool { fe.active && fe.requested.count > 1 && !controlPlayAllCombo }

    /// ★ BATCH G VERIFICATION: "Play all" plays each group ALONE — the note beside the picker is the
    /// PLAYING group's own (its firmer-wins miss, or none), not the first group's for every turn.
    /// `playing`: the sim the renderer shows now (FlexibleSquishLoop.playingSimID).
    func simNote(playing id: String?) -> String? {
        if let n = feNote { return n }
        if let id, fe.active, fe.requested.count > 1, let g = shownLattice, g.shownSim?.kind == .playAll,
           fe.requested.contains(id) {
            return g.simNote(for: id)
        }
        return simNote
    }

    /// ★ BATCH G VERIFICATION (his round-5 (a): "based on the group's squish dynamics alone, not as
    /// a combo"): under "Play all" each group's OWN colours — only its faces' heat, on the page's
    /// one scale — computed per landed group of the sequence (refresh), composed with the rest of
    /// the page in `tints` and swapped in by the renderer WITH that group's field and mesh.
    func playAllBaseTints(_ m: FlexibleStageModel, scaleMM: Double) -> [String: [Float]] {
        guard fe.active, fe.sequence.count > 1, let lat = m.lattice, !controlPlayAllCombo else { return [:] }
        var out: [String: [Float]] = [:]
        for i in fe.sequence where i < fe.fields.count {
            let id = fe.fields[i].simID
            let d = FlexibleLatticePreview.drawn(lat.showing(id), xray: true, building: m.latticeBuilding,
                                                 checkStampShown: nil, stale: m.latticeIsStale)
            // ★ BATCH M: each turn's heat is its own sim's dent, on the page's one scale
            out[id] = FlexiblePageChannels.channels(model: m, overlay: overlay, xray: false, drawnLattice: d, heat: heat,
                                                    depthScaleMM: scaleMM, mapValues: feMapValues(fe.fields[i], m)).tints
        }
        return out
    }
}

/// ★ BATCH G VERIFICATION: each group's composed tints under "Play all", by sim id — handed to the
/// renderer by REFERENCE (FlexibleLatticeLayerInputs.feTints), which swaps them in with the field
/// and the mesh at the cycle's rest point (MeshRenderer+FlexibleLattice.stepFlexibleFE). Main thread.
public final class FlexibleFETints {
    private(set) var bySim: [String: [Float]] = [:]
    public init() {}
    func set(_ t: [String: [Float]]) { bySim = t }
    func tints(_ id: String) -> [Float]? { bySim[id] }
}
