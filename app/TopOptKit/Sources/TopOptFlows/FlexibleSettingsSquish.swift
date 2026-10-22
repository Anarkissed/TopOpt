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
        /// ★ U21 (LBR-EDGES): what poses the overlays at the full bend — the 3D field shown, or the column preview's pressed
        /// faces (each point ON one takes that face's own bend).
        var field: FlexibleFEField? = nil
        var poseFaces: [FlexibleBendPose.FaceBend] = []
    }

    /// The sim id of `g` when the current lattice has a landed field for it.
    /// ★ BATCH N: its REFINED field once that landed (the squish solved in steps), else its quick one.
    static func field(model m: FlexibleStageModel, group g: FlexibleSqueezeGroup) -> FlexibleFEField? {
        let id = FlexibleSim.groupID(g.number)
        guard let l = m.lattice, m.squishGeneration == l.generation,
              let f = m.shownSquishField(id), f.generation == l.generation else { return nil }
        // ★ U21 (BEND-EDGES): out of date since Save & Exit — an edges group's sim on the LAST BUILT lattice still shows, once it
        // answers his presses as they are now (a face group keeps the current-lattice rule: its column preview)
        if m.latticeIsStale { return staleEdges(model: m, group: g) && m.pressSimIsCurrent(id) ? f : nil }
        return f
    }

    /// An edges group playing on the last built lattice (out of date, built on the scene open now).
    static func staleEdges(model m: FlexibleStageModel, group g: FlexibleSqueezeGroup?) -> Bool {
        g?.kind == .edges && m.edgesSimOnStaleLattice
    }

    /// The sims of a current lattice start when the Settings page asks for its group (the main page
    /// usually started them already; one call is cheap and never re-solves).
    static func startSims(model m: FlexibleStageModel, group g: FlexibleSqueezeGroup?) {
        guard let g, m.lattice != nil, !m.latticeIsStale || staleEdges(model: m, group: g) else { return }
        m.startSquishSims(first: FlexibleSim.groupID(g.number))   // (out of date: only the edges groups' sims — startPressSims)
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
            return Shown(dents: d, exaggeration: k, fe: true, groupNumber: g.number, field: f)
        }
        // ★ U21 (BEND-EDGES): an edges group with no sim to show (no lattice yet, its sim solving or failed) is never still — the
        // EDGE PREVIEW: each press's drawn push moves the part inside its flat prism along the arrow (the note says so)
        if edges, !controlEdgePreviewOff {
            return Shown(dents: edgePreview(model: m, overlay: o, group: g), exaggeration: 1, fe: false, groupNumber: g.number)
        }
        return Shown(dents: columnDents(model: m, overlay: o, regions: Set(g.regions)), exaggeration: edges ? 1 : c.exaggeration,
                     fe: false, groupNumber: g.number,   // (an edges group: still, until its sim lands — the note says why)
                     poseFaces: poseFaces(model: m, overlay: o, regions: Set(g.regions)))
    }

    /// ★ RED CONTROL only (BEND-EDGES): an edges group with no sim stands still (before U21).
    public static var controlEdgePreviewOff = false

    /// ★ U21 (BEND-EDGES): the edge preview of `g` on `o` — every drawn part vertex inside a press's flat prism (between its apex and
    /// its floor along the arrow, over its footprint) moves along the arrow by the press's depth × the drawn push there (the
    /// samples Play pushes and the indent outlines: FlexiblePressPush), full at the surface, easing to 0 in the last millimetre
    /// above the prism's floor so it meets the still face. Nothing outside the prisms moves. Display only.
    static func edgePreview(model m: FlexibleStageModel, overlay o: FlexibleOverlayMesh, group g: FlexibleSqueezeGroup) -> [Float] {
        let pos = o.mesh.flat.positions
        var out = [Float](repeating: 0, count: pos.count)
        for id in g.presses {
            guard let p = m.press(id), p.strip != nil, let c = m.flatCut(id) else { continue }
            let s = FlexiblePressPush.samples(p, c)
            guard s.count > 1, c.depthMM > 0 else { continue }
            let depth = Swift.min(FlexibleFlatPrism.depth(of: p) ?? c.depthMM, c.depthMM)
            let pts = (0..<s.count).map { SIMD3(s.xyz[3 * $0], s.xyz[3 * $0 + 1], s.xyz[3 * $0 + 2]) }
            // the samples' own spacing: how far a point may lie from the footprint's nearest sample and still be on it
            var spacing = 0.0
            for i in stride(from: 0, to: pts.count, by: Swift.max(1, pts.count / 64)) {
                var best = Double.infinity
                for j in pts.indices where j != i { let dd = simd_distance(pts[i], pts[j]); if dd > 1e-6 { best = Swift.min(best, dd) } }
                if best.isFinite { spacing = Swift.max(spacing, best) }
            }
            let reach = Swift.max(0.5, 1.5 * spacing)
            let cell = reach
            func key(_ q: SIMD3<Double>) -> SIMD3<Int32> { SIMD3<Int32>(Int32((q.x / cell).rounded(.down)), Int32((q.y / cell).rounded(.down)), Int32((q.z / cell).rounded(.down))) }
            var buckets: [SIMD3<Int32>: [Int]] = [:]
            for (i, q) in pts.enumerated() { buckets[key(q), default: []].append(i) }
            for v in 0..<o.partFlatVertices {
                let q = SIMD3<Double>(Double(pos[3 * v]), Double(pos[3 * v + 1]), Double(pos[3 * v + 2]))
                let h = c.height(q)
                guard h > -0.25, h < c.depthMM - 1e-6 else { continue }
                // the drawn push at q: inverse-distance over the samples within reach (its nearest decides whether q is on it)
                let k0 = key(q)
                var wsum = 0.0, vsum = 0.0, nearest = Double.infinity
                for dz in -1...1 { for dy in -1...1 { for dx in -1...1 {
                    for i in buckets[k0 &+ SIMD3(Int32(dx), Int32(dy), Int32(dz))] ?? [] {
                        let dd = simd_distance(pts[i], q)
                        guard dd <= reach else { continue }
                        nearest = Swift.min(nearest, dd)
                        let w = 1 / Swift.max(dd, 1e-3)
                        wsum += w; vsum += w * s.weight[i]
                    }
                } } }
                guard wsum > 0, nearest <= reach else { continue }
                let ease = Swift.min(1, Swift.max(0, (c.depthMM - h) / 1.0))
                let mm = depth * (vsum / wsum) * ease
                guard mm > 0 else { continue }
                out[3 * v] += Float(c.direction.x * mm); out[3 * v + 1] += Float(c.direction.y * mm); out[3 * v + 2] += Float(c.direction.z * mm)
            }
        }
        return out
    }

    /// Each face's shown depths per column (the page's own rule), for `regions` only.
    static func columnDepths(model m: FlexibleStageModel, regions: Set<Int>) -> [FlexFaceKey: [Double?]] {
        let shown = FlexibleShownValues(model: m, drawnLattice: nil)
        var depths: [FlexFaceKey: [Double?]] = [:]
        for (k, vals) in shown.values where regions.contains(k.region) {
            depths[k] = vals.map { if case .depth(let d) = $0 { return d } else { return nil } }
        }
        return depths
    }

    /// ★ U21 (LBR-EDGES): the column preview's pressed faces as the bend pose reads them — each face's squares' corners (the
    /// numbers `columnDents` moves them by) in its frame.
    static func poseFaces(model m: FlexibleStageModel, overlay o: FlexibleOverlayMesh, regions: Set<Int>) -> [FlexibleBendPose.FaceBend] {
        let depths = columnDepths(model: m, regions: regions)
        return o.cornerGrids(depths: depths, stacks: m.stacks).sorted { $0.key.region < $1.key.region }.compactMap { k, grid in
            guard let g = m.geometry[k] else { return nil }
            return FlexibleBendPose.FaceBend(grid: grid, origin: g.corner - grid.stack.load * grid.stack.entryT(nearU: 0, v: 0))
        }
    }

    /// The column preview of `regions` ONLY (each face's shown values, the page's own rule).
    static func columnDents(model m: FlexibleStageModel, overlay o: FlexibleOverlayMesh, regions: Set<Int>) -> [Float] {
        let depths = columnDepths(model: m, regions: regions)
        var out = o.displacements(depths: depths, stacks: m.stacks, partUVT: m.geometry.mapValues(\.partUVT),
                                  still: FlexiblePageChannels.stillRule(regions: m.regions, mesh: m.project.viewerMesh, overlay: o,
                                                                        keys: Array(depths.keys)),   // ★ ROUND 7 (M2)
                                  perVertex: true)   // ★ U21 (BEND-TOP): every part vertex from the squares' own corners
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
        // ★ U21 (BEND-EDGES): an edges group's sim on the LAST BUILT lattice, his presses as they are now
        if fe, let g = m.playingGroup, m.latticeIsStale, staleEdges(model: m, group: g) { return FlexibleRowCopy.settingsEdgesLastSaved }
        // ★ R7-E3: an edges group's squish is the interim sim — the chip says so while it plays
        if fe, let g = m.playingGroup, let line = m.notTunedLine(simID: FlexibleSim.groupID(g.number)) { return line }
        if fe { return FlexibleRowCopy.settingsSimNote }
        guard m.frozenExaggeration == nil, let g = m.playingGroup else { return nil }
        // ★ U21 (BEND-EDGES): the edge preview stands in — and why
        if g.kind == .edges, !controlEdgePreviewOff, !FlexibleStageModel.controlNoPressSims {
            let id = FlexibleSim.groupID(g.number)
            guard m.lattice != nil else { return FlexibleRowCopy.edgePreviewNoLattice }
            if m.latticeIsStale && !staleEdges(model: m, group: g) { return FlexibleRowCopy.edgePreviewEdited }
            if case .failed? = m.squish[id] { return FlexibleRowCopy.edgePreviewFailed }
            return FlexibleRowCopy.edgePreviewRunning
        }
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
