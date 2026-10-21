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
// each face's drawn map dents its own column, at once, and ★ S VERIFICATION one line above the
// player says why (`note`).

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
    /// ★ BATCH N: its REFINED field once that landed (the squish solved in steps), else its quick one.
    static func field(model m: FlexibleStageModel, group g: FlexibleSqueezeGroup) -> FlexibleFEField? {
        guard let l = m.lattice, !m.latticeIsStale, m.squishGeneration == l.generation,
              let f = m.shownSquishField(FlexibleSim.groupID(g.number)), f.generation == l.generation else { return nil }
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
        // ★ R7-E3: an edges group has no face map (no column dent) — it plays its interim sim along the arrow
        let edges = m.playingGroup?.kind == .edges && !FlexibleStageModel.controlNoPressSims
        guard let o = overlay, c.dents != nil || edges, let g = m.playingGroup else {
            return Shown(dents: c.dents, exaggeration: c.exaggeration, fe: false, groupNumber: m.playingGroup?.number)
        }
        if let f = field(model: m, group: g), m.frozenExaggeration == nil {
            let shown = FlexibleShownValues(model: m, drawnLattice: nil)
            // ★ R7-E3: the interim sim at × 1 — its own size (no core prediction to scale it to), never folded
            // ★ X20b: core's full design depth at × 1 (only a true fold cut it, inside the field)
            let k = edges ? FlexiblePressHeat.shownScale(f) : FlexibleShownValues.cappedExaggeration(rule: shown.uncappedExaggeration, maxSafeScale: f.maxSafeScale)
            let key = "\(o.mesh.flat.vertexCount)|\(o.partFlatVertices)|\(f.simID)|\(f.serial)|\(f.scale)"   // (the page drops it on a rebuild)
            let d: [Float]
            if let cached = feCache, cached.key == key { d = cached.dents } else {
                d = f.meshDisplacements(positions: o.mesh.flat.positions)
                feCache = (key, d)
            }
            return Shown(dents: d, exaggeration: k, fe: true, groupNumber: g.number)
        }
        return Shown(dents: columnDents(model: m, overlay: o, regions: Set(g.regions)), exaggeration: edges ? 1 : c.exaggeration,
                     fe: false, groupNumber: g.number)   // (an edges group: still, until its sim lands — the note says why)
    }

    /// The column preview of `regions` ONLY (each face's shown values, the page's own rule).
    static func columnDents(model m: FlexibleStageModel, overlay o: FlexibleOverlayMesh, regions: Set<Int>) -> [Float] {
        let shown = FlexibleShownValues(model: m, drawnLattice: nil)
        var depths: [FlexFaceKey: [Double?]] = [:]
        for (k, vals) in shown.values where regions.contains(k.region) {
            depths[k] = vals.map { if case .depth(let d) = $0 { return d } else { return nil } }
        }
        var out = o.displacements(depths: depths, stacks: m.stacks, partUVT: m.geometry.mapValues(\.partUVT),
                                  still: FlexiblePageChannels.stillRule(regions: m.regions, mesh: m.project.viewerMesh, overlay: o,
                                                                        keys: Array(depths.keys)))   // ★ ROUND 7 (M2)
        // ★ X20b (his answer of 2026-10-20 ~16:05): another group's face lying over the squished lattice bends along with it
        // (supersedes round 5's "another group's face stands still" for this case); RED CONTROL `controlOtherGroupStill`
        guard !controlOtherGroupStill else { return out }
        var origins: [FlexFaceKey: SIMD3<Double>] = [:]
        for k in depths.keys {
            guard let g = m.geometry[k], let st = m.stacks[k] else { continue }
            origins[k] = g.corner - st.load * st.entryT(nearU: 0, v: 0)
        }
        let riders = m.loadedKeys.filter { depths[$0] == nil }
        o.addRiders(&out, depths: depths, stacks: m.stacks, origins: origins, riders: riders)
        return out
    }
    /// ★ X20b, RED CONTROL only: round 5's rule — another group's map stands still even over the squished lattice.
    public static var controlOtherGroupStill = false

    /// ★ U1 (his notes of 2026-10-20, img_1020_7: the Top stayed flat while Face 3's side bent): the Squish page's overlay is
    /// cut fine for the COLUMN preview too — at the loaded stacks' pitch (≥ 2 mm), at most `columnMaxTriangles` — so a big flat
    /// triangle of the part over a pocket (his Top is two) follows the ramp instead of standing on its far corners. The 3D sim
    /// keeps its own grid (`overlayEdge`). nil before a stack lands. ★ X20b: another GROUP's pressed map over the squished lattice
    /// bends along too (`columnDents`, his answer of 2026-10-20 ~16:05). RED CONTROL `controlColumnFlatNeighbours`:
    /// uncut (before U1).
    public static func pageEdge(model m: FlexibleStageModel) -> Double? {
        if let e = overlayEdge(model: m) { return e }
        if controlColumnFlatNeighbours { return nil }
        let pitches = m.loadedKeys.compactMap { m.stacks[$0]?.pitchMM }.filter { $0 > 0 }
        return pitches.min().map { Swift.max($0, 2) }
    }
    /// (the page recomputes the dent and the tints on every change: kept small — his pad's 28 000 mm² at ~3 mm)
    static let columnMaxTriangles = 12_000
    public static var controlColumnFlatNeighbours = false

    // MARK: the player

    /// ★ RED CONTROL only: the Squish page's group picker (before his 2026-10-19 notes).
    public static var controlSquishPagePicker = false

    /// The player's picker on the Settings page: each group (no "Play all" — one group plays at a
    /// time here); none with one group.
    public static func playerSims(model m: FlexibleStageModel) -> [FlexibleSim] {
        // ★ R7-E3 (his notes of 2026-10-19 ~14:40: "Since all squish groups are selectable on the squish page, all views should only
        // show what group is currently selected"): NO picker on the Squish page — it plays the open group; the selector is the
        // Lattice page's (FlexibleMainGroupSelector). RED CONTROL `controlSquishPagePicker` (the old picker).
        guard controlSquishPagePicker else { return [] }
        let groups = m.sims.filter { if case .group = $0.kind { return true }; return false }
        // ★ ROUND 7 (S, 4d): each group by HIS name (the Settings page's picker; the main page keeps "Group N")
        let named = groups.map { sim -> FlexibleSim in
            guard case .group(let n) = sim.kind else { return sim }
            let name = m.groupName(number: n)
            guard name != sim.short else { return sim }
            let faces = m.squeezeGroups.first { $0.number == n }?.regions.map { m.displayName($0) } ?? []
            return FlexibleSim(id: sim.id, kind: sim.kind, title: FlexibleRowCopy.simTitle(name: name, names: faces),
                               short: name, keys: sim.keys)
        }
        return named.count > 1 ? named : []
    }

    /// The player's end label: the PLAYING group's one squeeze force in the page's unit ("10 kg",
    /// "22 lb" — the number in its Squeeze box). ★ S VERIFICATION: it read "Full load" for his
    /// Group 1 (Top A 5 kg + Top B 5 kg of Top's 10 kg, Face 5 10 kg: one 10 kg squeeze). A
    /// calibrate-first filament or a shape-only lattice: "As drawn", never a weight.
    public static func fullLabel(model m: FlexibleStageModel) -> String {
        if m.material?.noPrediction != nil || m.lattice?.shapeOnly == true { return FlexibleSquishLoop.asDrawn }
        if let g = m.playingGroup, let f = m.groupForce(g) { return FlexibleRowCopy.squeezeValue(f, unit: m.weightUnit) }
        return FlexibleSquishLoop.fullLabel(weightsKg: m.settings.loadedFaces.map(\.weightKg), unit: m.weightUnit)
    }

    /// A pick in the player: select that group's first face (the page plays the selected face's group).
    public static func pick(_ simID: String, model m: FlexibleStageModel) {
        guard let g = m.squeezeGroups.first(where: { FlexibleSim.groupID($0.number) == simID }) else { return }
        m.rail = .group(g.id)
        if let r = g.regions.first, m.squeezeGroup(of: m.selectedRegion ?? -1)?.id != g.id { m.select(r) }
    }

    /// One line above the player: the 3D sim while it moves the part. ★ S VERIFICATION: and while
    /// the COLUMN preview stands in for it, why — and what brings the fold back (the page dropped
    /// to the column dent after his first edit with no word, and the loop changed character):
    /// edited since the last Save & Exit / no lattice built yet / the sim still running / it
    /// failed. Nothing while he drags (the legend says "What you drew"), nor for a lattice that
    /// has no sim (shape only).
    public static func note(model m: FlexibleStageModel, fe: Bool) -> String? {
        // ★ R7-E3: an edges group's squish is the interim sim — the chip says so while it plays
        if fe, let g = m.playingGroup, let line = m.notTunedLine(simID: FlexibleSim.groupID(g.number)) { return line }
        if fe { return FlexibleRowCopy.settingsSimNote }
        guard m.frozenExaggeration == nil, let g = m.playingGroup else { return nil }
        guard let l = m.lattice else { return FlexibleRowCopy.settingsColumnNoLattice }
        if m.latticeIsStale { return FlexibleRowCopy.settingsColumnEdited }
        switch m.squish[FlexibleSim.groupID(g.number)] {
        case .failed?: return FlexibleRowCopy.settingsColumnFailed
        case .pending?: return FlexibleRowCopy.settingsColumnRunning
        case .ready?: return nil
        case nil:
            let coming = m.feRequest?.generation == l.generation || m.squishScheduled == l.generation
            return coming ? FlexibleRowCopy.settingsColumnRunning : nil
        }
    }
}
