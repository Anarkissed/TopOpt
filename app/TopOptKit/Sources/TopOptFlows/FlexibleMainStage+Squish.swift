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
// sim is left out of Play all but stays pickable.

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
    /// The FE field moves the picture.
    var active: Bool { !sequence.isEmpty }

    static func == (a: Self, b: Self) -> Bool {
        a.token == b.token && a.sequence == b.sequence && a.pending == b.pending && a.failure == b.failure
    }
}

extension FlexibleMainStage {

    /// The FE view of `drawn` (the lattice as the player shows it), starting its sims when they
    /// have not started (the shown sim first). Cheap: the mesh displacements are cached per
    /// (overlay, field).
    func feView(_ m: FlexibleStageModel, drawn: FlexibleGeneratedLattice?) -> FlexibleFEView {
        guard let g = drawn, !m.latticeIsStale, !controlColumnSquish else { return FlexibleFEView() }
        let groups = m.squishSims
        let groupIDs = groups.map(\.sim.id)
        // the sequence: the pick, or every group ("Play all", or one group with nothing to pick)
        let seqIDs: [String] = g.shownSimID.flatMap { id in groupIDs.contains(id) ? [id] : nil } ?? groupIDs
        if visible, !frozen { m.startSquishSims(first: seqIDs.first) }
        guard m.squishGeneration == g.generation, groups.contains(where: { $0.state != nil }) else { return FlexibleFEView() }
        var v = FlexibleFEView()
        v.fields = groups.compactMap { $0.state?.field }.filter { $0.generation == g.generation }
        v.mesh = v.fields.map { feMesh(for: $0) }
        v.sequence = seqIDs.compactMap { id in v.fields.firstIndex { $0.simID == id } }
        v.pending = seqIDs.contains { m.squish[$0] == .pending }
        if v.sequence.isEmpty, !v.pending { v.failure = seqIDs.compactMap { m.squish[$0]?.failure }.first }
        var h = Hasher()
        h.combine(g.generation)
        for f in v.fields { h.combine(f.serial); h.combine(f.scale) }
        h.combine(overlaySerial)
        v.token = h.finalize()
        v.safeScale = v.sequence.map { v.fields[$0].maxSafeScale }.min() ?? .infinity
        v.coreRatio = v.sequence.map { v.fields[$0] }.first { $0.clamped }?.coreRatio
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
    /// "Simple squish · the sim failed" when it fell back.
    var feNote: String? {
        if fe.pending { return FlexibleFE.pending }
        if fe.failure != nil { return FlexibleFE.failed }
        return nil
    }
}
