// FlexibleSettingsSquish — on the Settings page the SELECTED face's squeeze group squishes, ALONE
// (task 2026-09-29-flexible-screens, round 5 batch S2; his img 1: "Each different group should have
// different animations; depending on which face is selected, that's the group that gets animated.
// Allow for the model to squish and fold based on the group's squish dynamics alone, not as a
// combo." — and: "No this is for the setting page").
//
// ★ WHICH GROUP: the selected pressed face's (a row tapped, or the face tapped on the model); with a
// resting or unset face selected, the group whose folder tab is open (FlexibleStageModel.playingGroup).
// Only THAT group's faces dent — its load alone; the other groups' maps keep their colours and stand
// still. Never the firmer-wins combination: the dent is each face's own drawing.
// ★ HOW IT MOVES: batch G's 3D field for that group (FlexibleFEField — the squeeze group's own sim,
// solved for its load alone) when the lattice on the main page is CURRENT and its sim has landed:
// the whole part moves by it — the sides bulge — on an overlay cut to the sim's grid, ×k capped so
// it never folds over (the main page's rule). Otherwise — any edit since the last Save & Exit (a
// dragged curve, a new depth), no lattice yet, a sim still running or failed — the COLUMN preview:
// each face's drawn map dents its own column, at once.

import Foundation
import simd
import TopOptKit

@MainActor
public enum FlexibleSettingsSquish {

    /// What the page's renderer is handed for the playing group.
    public struct Shown {
        /// Displacements per flat vertex of the overlay (mm, before ×k); nil: nothing dents.
        public var dents: [Float]?
        /// The ×k the page scales them by.
        public var exaggeration: Double
        /// The 3D sim moves the part (else the column preview).
        public var fe: Bool
        /// The group that plays (its number, as shown).
        public var groupNumber: Int?
    }

    /// The sim id of `g` when the current lattice has a landed field for it.
    static func field(model m: FlexibleStageModel, group g: FlexibleSqueezeGroup) -> FlexibleFEField? {
        guard let l = m.lattice, !m.latticeIsStale, m.squishGeneration == l.generation,
              let f = m.squish[FlexibleSim.groupID(g.number)]?.field, f.generation == l.generation else { return nil }
        return f
    }

    /// The sims of a current lattice start when the Settings page asks for its group (the main page
    /// usually started them already; one call is cheap and never re-solves).
    static func startSims(model m: FlexibleStageModel, group g: FlexibleSqueezeGroup?) {
        guard let g, m.lattice != nil, !m.latticeIsStale else { return }
        m.startSquishSims(first: FlexibleSim.groupID(g.number))
    }

    /// The overlay's edge for the 3D field (the sim's grid pitch), nil for the column preview.
    public static func overlayEdge(model m: FlexibleStageModel) -> Double? {
        guard let g = m.playingGroup, field(model: m, group: g) != nil, let s = m.sceneInfo else { return nil }
        return FlexibleFE.spacing(sceneNX: s.nx, ny: s.ny, nz: s.nz, spacing: s.spacing)
    }

    /// The playing group's dent on `overlay` — its 3D field when current, else its faces' columns.
    /// `channels` is the page's (its ×k and whether a dent is shown at all).
    /// `feCache`: the field's mesh displacements, kept per (overlay, field) — sampling the field on
    /// every vertex is the costly part and the page refreshes often.
    public static func shown(model m: FlexibleStageModel, overlay: FlexibleOverlayMesh?,
                             channels c: FlexiblePageChannels.Channels,
                             feCache: inout (key: String, dents: [Float])?) -> Shown {
        guard let o = overlay, c.dents != nil, let g = m.playingGroup else {
            return Shown(dents: c.dents, exaggeration: c.exaggeration, fe: false, groupNumber: m.playingGroup?.number)
        }
        if let f = field(model: m, group: g), m.frozenExaggeration == nil {
            let shown = FlexibleShownValues(model: m, drawnLattice: nil)
            let k = FlexibleShownValues.cappedExaggeration(rule: shown.uncappedExaggeration, maxSafeScale: f.maxSafeScale)
            let key = "\(o.mesh.flat.vertexCount)|\(o.partFlatVertices)|\(f.simID)|\(f.serial)|\(f.scale)"   // (the page drops it on a rebuild)
            let d: [Float]
            if let cached = feCache, cached.key == key { d = cached.dents } else {
                d = f.meshDisplacements(positions: o.mesh.flat.positions)
                feCache = (key, d)
            }
            return Shown(dents: d, exaggeration: k, fe: true, groupNumber: g.number)
        }
        return Shown(dents: columnDents(model: m, overlay: o, regions: Set(g.regions)), exaggeration: c.exaggeration,
                     fe: false, groupNumber: g.number)
    }

    /// The column preview of `regions` ONLY (each face's shown values, the page's own rule).
    static func columnDents(model m: FlexibleStageModel, overlay o: FlexibleOverlayMesh, regions: Set<Int>) -> [Float] {
        let shown = FlexibleShownValues(model: m, drawnLattice: nil)
        var depths: [FlexFaceKey: [Double?]] = [:]
        for (k, vals) in shown.values where regions.contains(k.region) {
            depths[k] = vals.map { if case .depth(let d) = $0 { return d } else { return nil } }
        }
        return o.displacements(depths: depths, stacks: m.stacks, partUVT: m.geometry.mapValues(\.partUVT))
    }

    // MARK: the player

    /// The player's picker on the Settings page: each group (no "Play all" — one group plays at a
    /// time here); none with one group.
    public static func playerSims(model m: FlexibleStageModel) -> [FlexibleSim] {
        let groups = m.sims.filter { if case .group = $0.kind { return true }; return false }
        return groups.count > 1 ? groups : []
    }

    /// A pick in the player: select that group's first face (the page plays the selected face's group).
    public static func pick(_ simID: String, model m: FlexibleStageModel) {
        guard let g = m.squeezeGroups.first(where: { FlexibleSim.groupID($0.number) == simID }) else { return }
        m.rail = .group(g.id)
        if let r = g.regions.first, m.squeezeGroup(of: m.selectedRegion ?? -1)?.id != g.id { m.select(r) }
    }

    /// One line above the player: the 3D sim while it moves the part; nothing for the column preview
    /// of his drawing (the legend says "What you drew").
    public static func note(model m: FlexibleStageModel, fe: Bool) -> String? {
        fe ? FlexibleRowCopy.settingsSimNote : nil
    }
}
