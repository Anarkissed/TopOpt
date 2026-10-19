// FlexibleStageModel+EdgePick — the stage model's side of round 6 item 2: [+ New] → [Edges/corners] (task 2026-10-08;
// the maintainer OKed the design directly, the reviewer: "build it as posted"; r6 spec §3).
//
// ★ HIS FLOW. [+ New] asks [Faces] [Edges/corners] on one line. Edges/corners opens PICK MODE (`startEdgePick`): a new
// group with its number and its free colour; every edge and corner of the part, from core's adjacency and the 15° rule
// (FlexibleEdgeCandidates), drawn on the model in colours that never repeat on touching ones, numbered as in the list
// beside it. A tap on a row or on the model (`edgePickTap`: the nearest corner, then edge; a repeat tap cycles) picks
// it. What cannot be picked is listed grey with one line why: AP2's reasons, "In Group N" (in another edges group's
// press already), core's verdict on its press, or the area's own (a fillet, a curved face). [Done · 2 picked]
// (`finishEdgePick`) is ONE undoable edit: each pick's FLAT PRISM (★ R7-E1, his 2026-10-18 words: "There shouldn't be a strip
// width. It should be a Flat prism …") is cut on every member face through the Surface tool's own cut (FlexibleEdgeStrips,
// FlexibleFlatPrism), the face's own squeeze group KEEPS THE REST (its settings moved onto the rest, re-expressed through core's
// frames), and each pick becomes an AP1 FlexiblePress over its pieces, aimed at core's halfway over its WHOLE member faces
// (stored on its area at pick time — never re-aimed from the pieces), 3 mm deep, in the new group, at the group's one force he
// typed. SAVED, NOT WRITTEN TO ANY JOB (`sentPresses` stays empty until AP9; `designInputs` strips presses), so no face
// press's job changes except the faces that gave a piece (their entry is their rest now).
// ★ CORE BEFORE THE CUT. The strips' halfway and core's verdict on them are asked of a scene opened on the regions AFTER
// the cut, before anything is committed (`changeStrips`), so the cut and its presses are one edit and one undo step;
// that scene then becomes the page's (`FlexibleWorker.install`), so the part does not open twice.
// ★ R7-E1 — NO WIDTH. The flat prism's depth and angles (FlexibleStageModel+FlatPrism's setFlatCut) re-cut that pick and every
// pick on the same faces, in the one order — one undo step. Removing a press (or its whole group) gives its piece back.
// ★ THE MAIN PAGE'S SELECTIONS ARE NOT TOUCHED: the Settings squeeze groups and the main page's Selections are two
// separate lists (his 2026-10-10 reversal); the cut joins no Selections group.

import CoreGraphics
import Foundation
import simd
import TopOptKit

/// Core's frames over TWO scenes: the open one for the frame the inputs were drawn in (a face, or its rest before a
/// re-cut), and the one opened on the regions after the cut for the rest they move to. A region's frame is its own
/// triangles and cuts — the same in both scenes, which share the part, the grid and the mask.
struct FlexibleSplitFrames: FlexibleFrameSource {
    let from: FlexibleSceneFrames
    let to: FlexibleSceneFrames
    let toRef: FlexibleFrameRef
    private func pick(_ ref: FlexibleFrameRef) -> FlexibleSceneFrames { ref == toRef ? to : from }
    func stack(_ ref: FlexibleFrameRef) throws -> FlexStackInfo { try pick(ref).stack(ref) }
    func fromUV(_ ref: FlexibleFrameRef, _ uv: [SIMD2<Double>]) throws -> [SIMD3<Double>] { try pick(ref).fromUV(ref, uv) }
    func toUVT(_ ref: FlexibleFrameRef, _ xyz: [SIMD3<Double>]) throws -> [SIMD3<Double>] { try pick(ref).toUVT(ref, xyz) }
}

extension FlexibleStageModel {

    // MARK: - pick mode

    /// ★ [+ New] → [Edges/corners]: pick mode, a NEW group (its number after every group, the first colour no group
    /// wears). Every edge and corner is read from core and listed; nothing is stored until [Done].
    public func startEdgePick() {
        guard edgePick == nil else { return }
        let s = settings
        edgePick = FlexibleEdgePick(groupID: FlexibleSqueezeGroups.nextID(s),
                                    colour: FlexibleSqueezeGroups.freeColour(in: s, forNumber: squeezeGroups.count + 1))
        track(Task { @MainActor [weak self] in await self?.loadEdgePick() })
    }

    /// [Faces] or [Cancel]: pick mode ends; nothing was stored.
    public func cancelEdgePick() { edgePick = nil }

    /// The candidates, their colours, what cannot be picked and why, and each one's area — then core's verdict on each
    /// pickable one's press (over its whole members, along core's halfway), greying what core refuses.
    func loadEdgePick() async {
        guard let token = edgePick?.token else { return }
        do {
            let facts = try await meetFacts()
            guard let meet = await meetOffMain(), edgePick?.token == token else { return }
            // AP2's list, its one-line reasons in the PANEL's names ("Face 5", "Top A")
            let list = FlexibleEdgeCandidates.make(meet: meet, facts: facts, removed: Set(settings.removedRegions ?? []),
                                                   name: { [weak self] r in self?.displayName(r) ?? "Face \(r)" })
            if let why = list.unread {
                edgePick?.loading = false
                edgePick?.line = FlexibleRowCopy.fit(why)
                return
            }
            let s = settings
            let existing = (s.presses ?? []).compactMap(\.strip)
            let order = (existing.map(\.order).max() ?? 0) + 1
            let held = s.pressRegions
            var greyed: [Int: String] = [:], strips: [Int: FlexibleStrip] = [:], loads: [Int: [SIMD3<Double>]] = [:]
            for c in list.candidates {
                loads[c.number] = c.members.compactMap { facts.frames[$0]?.load }
                if let why = c.why { greyed[c.number] = FlexibleRowCopy.fit(why); continue }
                if let r = c.members.first(where: { held.contains($0) }),
                   let p = s.pressHolding(r), let g = FlexibleSqueezeGroups.group(ofPress: p.id, in: s) {
                    greyed[c.number] = FlexibleRowCopy.inGroup(name: groupName(g))   // ★ ROUND 7 (S, 4d): his name
                    continue
                }
                // ★ ROUND 7 (M2, D6): with a face-prism set, a member with no lattice under it cannot take a strip
                if facePrismsSet, !FlexibleLatticeSections.controlWholeFace, let set = regions.flexible,
                   c.members.contains(where: { r in !FlexibleRegions.isFlexible(r) && !set.wholeRoots.contains(r) && set.notYet[r] == nil }) {
                    greyed[c.number] = FlexibleRowCopy.noLatticeAt(FlexibleRowCopy.candidateLabel(c))
                    continue
                }
                switch FlexibleEdgeStrips.strip(for: c, label: FlexibleRowCopy.candidateLabel(c), order: order, meet: meet,
                                                facts: facts, faceRegions: restoredFaceRegions, existing: existing,
                                                name: { [weak self] r in self?.displayName(r) ?? "Face \(r)" }) {
                case .success(let st): strips[c.number] = st
                case .failure(let r): greyed[c.number] = r.line
                }
            }
            guard edgePick?.token == token, var p = edgePick else { return }
            p.candidates = list.candidates
            p.colours = FlexibleEdgePickRules.colours(list.candidates, excluding: p.colour)
            p.greyed = greyed
            p.strips = strips
            p.loads = loads
            p.loading = false
            p.checking = true
            edgePick = p
            // ★ CORE'S VERDICT on each pickable candidate's press (its whole members, along core's halfway). ★ R7-E1: that
            // halfway — over the WHOLE member faces — is stored on its area (where the flat prism's arrow starts and snaps back
            // to; the engine never re-aims from the pieces), and an inside edge or corner along it is greyed
            for c in list.candidates where strips[c.number] != nil {
                let aim = try await pressAim(c.members)
                guard edgePick?.token == token else { return }
                guard aim.defaultRelease != nil, let hw = aim.offered.first(where: { $0.kind == .halfway })?.direction else {
                    let why = aim.why ?? aim.asked.first { !$0.accepted }?.line ?? FlexibleRowCopy.coreRefuses
                    edgePick?.greyed[c.number] = FlexibleRowCopy.fit(why)
                    edgePick?.picks.removeAll { $0 == c.number }
                    continue
                }
                if let st = edgePick?.strips[c.number], let line = FlexibleFlatPrism.convexityLine(st, d0: hw) {
                    edgePick?.greyed[c.number] = line
                    edgePick?.picks.removeAll { $0 == c.number }
                    continue
                }
                edgePick?.strips[c.number]?.halfway = hw
            }
            edgePick?.checking = false
        } catch {
            guard edgePick?.token == token else { return }
            edgePick?.loading = false
            edgePick?.checking = false
            edgePick?.line = FlexibleRowCopy.fit(text("\(error)"))
        }
    }

    /// Core's lattice depth under region `r` (its stack's latticeMMMax), or nil (no stack: core refused one).
    func latticeDepth(_ r: Int) async -> Double? {
        if let st = stack(r) { return st.latticeMMMax }
        return try? await frameWorker.withScene { try $0.stack(face: r, rotation: 0).latticeMMMax }
    }

    /// A row's or the model's tap: toggle candidate `n` (not one that is greyed, nor while the list loads or cuts).
    public func toggleEdgePick(_ n: Int) {
        guard var p = edgePick, !p.loading, !p.working, p.pickable(n) else { return }
        if let i = p.picks.firstIndex(of: n) { p.picks.remove(at: i) } else { p.picks.append(n) }
        p.line = nil
        edgePick = p
    }

    /// ★ A TAP ON THE MODEL in pick mode, at `point` (the page's points) through the page's projection: the nearest
    /// corner within 22 pt, then the nearest edge; a repeat tap cycles. Returns the one line the page shows (a miss, or
    /// why the candidate hit cannot be picked); nil when it toggled one.
    @discardableResult
    public func edgePickTap(at point: CGPoint, projection: CameraProjection) -> String? {
        guard var p = edgePick, !p.loading, !p.working else { return nil }
        let shown = FlexibleEdgePickRules.project(p.candidates, loads: p.loads, projection: projection)
        let hit = FlexibleEdgePickRules.hit(shown, at: point, last: p.cycle)
        p.cycle = hit.cycle
        edgePick = p
        guard let n = hit.toggle else { return FlexibleRowCopy.edgePickMiss }
        if let u = hit.untoggle, p.pickable(u) { toggleEdgePick(u) }
        guard p.pickable(n) else {
            return FlexibleRowCopy.fit((p.candidate(n).map(FlexibleRowCopy.candidateLabel) ?? "") + " · " + (p.greyed[n] ?? ""))
        }
        toggleEdgePick(n)
        return nil
    }

    /// The group's one squeeze force, typed on the pick card.
    public func setEdgePickWeight(_ kg: Double) {
        guard kg > 0, kg.isFinite else { return }
        edgePick?.weightKg = kg
        if edgePick?.line == FlexibleRowCopy.edgePickWeightAsk { edgePick?.line = nil }
    }

    /// ★ "Top keeps the rest · strip taken for Edge 3": one line per picked candidate's member that a face group holds
    /// (pressed or resting) — what [Done] will leave it.
    public func edgePickKeepsTheRest() -> [String] {
        guard let p = edgePick else { return [] }
        var out: [String] = []
        for n in p.picks {
            guard let c = p.candidate(n) else { continue }
            for m in c.members where settings.face(m) != nil {
                out.append(FlexibleRowCopy.keepsTheRest(name: displayName(m), label: FlexibleRowCopy.candidateLabel(c),
                                                        corner: c.kind == .corner))
            }
        }
        return out
    }

    /// ★ [Done · N picked]: ONE edit — the strips and patches cut, each face's group keeps its rest, one press per pick
    /// in the new group at core's halfway on its strips. nil when done (the new group's tab opens); else the one line why
    /// nothing was stored (the card keeps the picks).
    @discardableResult
    public func finishEdgePick() async -> String? {
        guard var pick = edgePick, !pick.working else { return nil }
        guard !pick.picks.isEmpty else { return FlexibleRowCopy.edgePickNone }
        guard let kg = pick.weightKg, kg > 0 else {
            pick.line = FlexibleRowCopy.edgePickWeightAsk
            edgePick = pick
            return pick.line
        }
        let lines = edgePickKeepsTheRest()
        let base = ((settings.presses ?? []).compactMap(\.strip).map(\.order).max() ?? 0) + 1
        var adds: [(id: UUID, strip: FlexibleStrip)] = []
        var cuts: [UUID: FlatCutChange] = [:]
        let mesh = project.viewerMesh
        var placed = settings.presses ?? []   // ★ R7-E1 REVIEW: his rule over every press on a face — the kept ones and the picks before
        for (i, n) in pick.picks.enumerated() {
            guard var st = pick.strips[n] else { continue }
            st.order = base + i
            let id = UUID()
            adds.append((id, st))
            // ★ R7-E1: a new pick sits on its whole faces' halfway, 3 mm deep (a face's default) — held so each face keeps
            // some of itself (his answer: the half-face rule dropped)
            if let d0 = st.halfway, let mesh {
                let others = Self.controlPerPressRest ? [:] : Self.otherCuts(placed, except: id)
                let range = FlexibleFlatPrismAngles.depthRange(st, d: d0, limits: .init(loads: [], keepsRest: Self.keepsRest(st, mesh: mesh, others: others)))
                let c = FlatCutChange(depthMM: Swift.min(FlexibleFlatPrism.defaultDepthMM, range.max), direction: d0,
                                      snap: FlexiblePress.Snap.halfway.raw)
                cuts[id] = c
                var f = FlexibleFaceSettings(faceRegionID: -1)
                f.deepestMM = c.depthMM
                placed.append(FlexiblePress(id: id, regions: [], direction: d0, snap: c.snap, settings: f, strip: st))
            }
        }
        pick.working = true
        pick.line = nil
        edgePick = pick
        lastFlatStop = nil
        var why = await changeStrips(StripChange(add: adds, cut: cuts), kg: kg, colour: pick.colour)
        // ★ R7-E1 REVIEW (the verifier: "whenever the cap is below 3 mm, [Done] fails outright with no fix"): a pick the lattice
        // stops shallower than its start STARTS at the stop (core's N, never under 0.5 mm) — said in one line
        var startedAt: [UUID: Double] = [:]
        for _ in 0..<(adds.count + 2) {
            guard why != nil, !Self.controlNoStartHold, let stop = lastFlatStop, let n = stop.setMM, var c = cuts[stop.press],
                  n >= FlexibleFlatPrism.minDepthMM, n < c.depthMM - 1e-9 else { break }
            c.depthMM = n
            cuts[stop.press] = c
            startedAt[stop.press] = n
            why = await changeStrips(StripChange(add: adds, cut: cuts), kg: kg, colour: pick.colour)
        }
        if let why {
            edgePick?.working = false
            edgePick?.line = why
            return why
        }
        edgePick = nil
        for (id, n) in startedAt {
            if let d = cuts[id]?.direction { flatExactStops[id] = (FlexiblePressAim.bits(d), n, sceneKey(regionsKey: "")) }
        }
        if let first = adds.first?.id, let g = FlexibleSqueezeGroups.group(ofPress: first, in: settings) {
            rail = .group(g.id)
            selectedPress = first
            flatCameraRequest = first   // ★ R7-E1: the page turns the camera to the new press (D-AP-13 as ruled)
            if let (id, n) = startedAt.first {
                lastFlatStop = FlexibleFlatStop(press: id, line: FlexibleRowCopy.flatLatticeEnds(n), setMM: nil, direction: cuts[id]?.direction,
                                                snap: cuts[id]?.snap)
                toast = FlexibleRowCopy.flatStartsAt(n)
            } else {
                lastFlatStop = nil
                toast = lines.first ?? FlexibleRowCopy.edgesGroupMade(g.number, edges: pick.edgesPicked, corners: pick.cornersPicked)
            }
        }
        return nil
    }

    // MARK: - the strips after [Done]

    /// The presses' strips back to their faces, the presses gone — one undo step.
    @discardableResult
    public func removeStripPresses(_ ids: [UUID]) async -> String? {
        let strips = Set(ids.filter { settings.press($0)?.strip != nil })
        let plain = ids.filter { !strips.contains($0) }
        for id in plain { removePress(id) }
        guard !strips.isEmpty else { return nil }
        let why = await changeStrips(StripChange(remove: strips))
        if let id = selectedPress, settings.press(id) == nil { selectedPress = nil }
        return why
    }

    /// ★ A strip press's one line: "Edge 9 · Face 1 + Face 2" — its pick and the FACES it presses (its strips' own
    /// sector names read "Edge 9 · Face 1"; the face is what he knows).
    public func stripTitle(_ id: UUID) -> String {
        guard let p = settings.press(id) else { return "" }
        guard let st = p.strip else { return p.name { [weak self] r in self?.displayName(r) ?? "Face \(r)" } }
        let names = st.members.map { m -> String in
            if let r = project.faceRegions.region(m.root), r.isCut { return FlexibleRowCopy.faceName(sector: r.name, face: m.face) }
            return "Face \(m.face)"
        }
        let full = st.label + " \u{00B7} " + names.joined(separator: " + ")
        if full.count <= 34 { return full }
        // ★ R7-E1 (looking at the corner's picture: "Corner 2 · Face 3 + Face 1 + Face…"): three whole faces read "Faces 3 + 1 + 2"
        let numbers = names.compactMap { n -> String? in n.hasPrefix("Face ") && Int(n.dropFirst(5)) != nil ? String(n.dropFirst(5)) : nil }
        if numbers.count == names.count {
            let short = st.label + " \u{00B7} Faces " + numbers.joined(separator: " + ")
            if short.count <= 34 { return short }
        }
        return FlexibleRowCopy.fit(full, 34)
    }

    /// ★ The face-keeps-the-rest lines of press `id`: one per member face whose rest a face group holds.
    public func keepsTheRest(press id: UUID) -> [String] {
        guard let p = settings.press(id), let st = p.strip else { return [] }
        let held = settings.pressRegions
        var out: [String] = []
        // ★ ROUND 7 (M2): the Flexible form — each strip piece's REST is its chain's rest pieces (FlexibleSectors)
        if let set = regions.flexible, st.members.allSatisfy({ $0.root < 0 }) {
            for r in p.regions {
                guard let pc = set.piece(r) else { continue }
                let rests = set.pieces.filter { $0.kind == .rest && $0.chain == pc.chain }.map(\.wireID).filter { !held.contains($0) }
                if let rest = rests.first(where: { settings.face($0) != nil }) {
                    out.append(FlexibleRowCopy.keepsTheRest(name: displayName(rest), label: st.label, corner: st.kind == .corner))
                }
            }
            return out
        }
        for m in st.members where m.root >= 0 {
            let rests = FlexibleEdgeStrips.leaves(of: m.root, in: project.faceRegions)
                .compactMap { project.faceRegions.region($0) }.map(FlexibleRegions.wireID).filter { !held.contains($0) }
            if let r = rests.first(where: { settings.face($0) != nil }) {
                out.append(FlexibleRowCopy.keepsTheRest(name: displayName(r), label: st.label, corner: st.kind == .corner))
            }
        }
        return out
    }

    // MARK: - the one engine

    /// What a change does to the strips. ★ R7-E1: `cut` — a press's flat prism (its depth, direction and snap kind; for a new
    /// pick, where it starts) — in place of the width.
    struct StripChange {
        var add: [(id: UUID, strip: FlexibleStrip)] = []
        var cut: [UUID: FlatCutChange] = [:]
        var remove: Set<UUID> = []
    }

    /// ★ APPLY A STRIP CHANGE AS ONE EDIT: re-cut every chain it touches (FlexibleEdgeStrips.plan), open a scene on the
    /// regions after the cut, ask core there for each new or re-cut press's halfway (its default aim) and re-express
    /// each face's settings onto its rest through core's frames; then commit the regions, the faces and the presses
    /// together between two undo seals, and hand that scene to the page. nil when done; else one line why nothing was
    /// stored. `kg` and `colour`: the new presses' group force and the new group's colour.
    func changeStrips(_ ch: StripChange, kg: Double? = nil, colour: FlexibleGroupColour? = nil) async -> String? {
        if FlexibleSectors.controlSurfaceRoute { return await changeStripsI2(ch, kg: kg, colour: colour) }
        return await changeFlexibleStrips(ch, kg: kg, colour: colour)
    }

    /// ★ RED CONTROL (round 7, M2 — FlexibleSectors.controlSurfaceRoute): I2's own route, kept as it was — the strips cut
    /// INTO the Surface stage's regions (`project.faceRegions`), the presses and rests keyed on those Surface sectors. The
    /// migration tests make I2's saved form with it.
    func changeStripsI2(_ ch: StripChange, kg: Double? = nil, colour: FlexibleGroupColour? = nil) async -> String? {
        guard sceneState == .ready, let opened = openedKey, opened == currentSceneKey, let mesh = project.viewerMesh else {
            return FlexibleRowCopy.edgePickOpening
        }
        let s0 = settings
        let regions0 = project.faceRegions
        var entries: [FlexibleEdgeStrips.Entry] = []
        var replay = Set<Int>()
        for p in s0.presses ?? [] {
            guard let st = p.strip else { continue }
            if ch.remove.contains(p.id) { replay.formUnion(st.members.map(\.root).filter { $0 >= 0 }); continue }
            entries.append(.init(id: p.id, strip: st, regions: p.regions))
        }
        for a in ch.add {
            // ★ R7-E1: I2's route keeps I2's own width (it makes I2's saved form for the migration tests — the red control)
            var st = a.strip
            if st.widthMM == nil {
                var lattice: [Double?] = []
                for mb in st.members { lattice.append(await latticeDepth(mb.face)) }
                st.widthMM = FlexibleEdgeStrips.legacyDefaultWidth(capMM: st.capMM, latticeMM: lattice)
            }
            entries.append(.init(id: a.id, strip: st, regions: nil))
            replay.formUnion(st.members.map(\.root).filter { $0 >= 0 })
        }
        let keep = Set(project.selection.groups.flatMap(\.regionIDs).map { Int($0) })
        var plan = FlexibleEdgeStrips.plan(entries, replay: replay, faceRegions: regions0, mesh: mesh, keep: keep)
        if FlexibleEdgeStrips.controlWholeFaces {
            // ★ RED CONTROL: the picks press their WHOLE member faces — nothing is cut, the face groups keep them too
            plan = FlexibleEdgeStrips.Plan(faceRegions: regions0)
            for e in entries {
                plan.strips[e.id] = e.strip
                plan.regions[e.id] = e.regions ?? e.strip.members.map(\.face)
            }
        }
        if let first = entries.first(where: { plan.refused[$0.id] != nil }), let why = plan.refused[first.id] { return why }
        let after = FlexibleRegions(model: plan.faceRegions, mesh: mesh)
        let key = sceneKey(regionsKey: after.key)
        // ── core, on the regions after the cut
        let scene: FlexibleScene
        do {
            guard let job = try sceneJob(sectors: after.wire) else { return FlexibleRowCopy.edgePickOpening }
            // ★ ROUND 7, RULING 6 (FlexibleCoreDoor): through the door — no face-prism, no scene asked of core
            let door = frameWorker.door, prisms = mayAskCore(facePrism: facePrismsNow)
            await holdLanded()
            scene = try await Task.detached(priority: .userInitiated) { try door.open(jobJSON: job.json, jobDir: job.dir, facePrism: prisms) }.value
        } catch {
            return FlexibleRowCopy.fit(text("\(error)"))
        }
        let build = (try? await Task.detached(priority: .userInitiated) { try scene.info() }.value)?.buildDir ?? sceneInfo?.buildDir
        let source = FlexibleAimSource(
            frame: { r, f in try await Task.detached(priority: .userInitiated) { try scene.regionFrame(r, face: f) }.value },
            verdict: { fp, d in try await Task.detached(priority: .userInitiated) { try scene.pressVerdict(fp, direction: d) }.value },
            triangleLoads: { t in try await Task.detached(priority: .userInitiated) { try scene.triangleLoads(t) }.value },
            faces: { after.faces(of: $0, mesh: mesh) }, mesh: mesh, buildDir: build,
            name: { after.name($0, mesh: mesh) },
            displayName: { r in
                let sec = after.sector(r)
                return FlexibleRowCopy.faceName(sector: sec?.name, face: sec == nil ? r : after.faces(of: r, mesh: mesh).first ?? r)
            },
            text: { after.renamed($0, mesh: mesh) })
        // ── each new or re-cut press's default aim: core's halfway on ITS strips
        var aims: [UUID: FlexiblePressAim.Release] = [:]
        for e in entries {
            let regs = plan.regions[e.id] ?? []
            guard e.regions == nil || regs != e.regions else { continue }
            do {
                let set = try await Self.aimSet(regs, source: source)
                guard let rel = set.defaultRelease else {
                    let why = set.why ?? set.asked.first { !$0.accepted }?.line ?? FlexibleRowCopy.coreRefuses
                    return FlexibleRowCopy.fit("\(e.strip.label) · \(why)")
                }
                aims[e.id] = rel
            } catch {
                return FlexibleRowCopy.fit("\(e.strip.label) · \(text("\(error)"))")
            }
        }
        // ── each face's settings onto its rest, re-expressed through core's frames (the open scene → the new one)
        var moved: [(old: [Int], new: [FlexibleFaceSettings], checks: [FlexibleCheckStamp])] = []
        for root in plan.rests.keys.sorted() {
            guard let rest = plan.rests[root], let before = plan.before[root], Set(before) != Set(rest),
                  let face = plan.faces[root] else { continue }
            let olds = before.compactMap { id in s0.face(id).map { (id: id, f: $0) } }
            guard !olds.isEmpty else { continue }
            let tris = FlexibleEdgeStrips.triangles(face: face, mesh: mesh)
            let regionsBefore = FlexibleRegions(model: regions0, mesh: mesh)
            var news: [FlexibleFaceSettings] = []
            var checks: [FlexibleCheckStamp] = []
            var carried = Set<Int>()   // each old piece's check stamps go once, with its first rest
            for to in rest {
                let src = olds.max { a, b in
                    FlexibleEdgeStrips.area(tris, regionsBefore.cuts(of: a.id) + after.cuts(of: to))
                        < FlexibleEdgeStrips.area(tris, regionsBefore.cuts(of: b.id) + after.cuts(of: to))
                }!
                if src.id == to { news.append(src.f); continue }
                do {
                    let r = try await frameWorker.withScene { cur in
                        try FlexiblePressReframe.reframe(src.f, from: .face(src.id), to: .face(to),
                                                         frames: FlexibleSplitFrames(from: FlexibleSceneFrames(cur),
                                                                                     to: FlexibleSceneFrames(scene),
                                                                                     toRef: .face(to)))
                    }
                    var f = r.settings
                    f.faceRegionID = to
                    news.append(f)
                    // his check stamps on that face go with it, re-expressed the same way (never dropped)
                    if carried.insert(src.id).inserted {
                        for c in s0.checkStamps where c.faceRegionID == src.id {
                            var holder = FlexibleFaceSettings(faceRegionID: src.id)
                            holder.designStamp = c.stamp
                            let rc = try await frameWorker.withScene { cur in
                                try FlexiblePressReframe.reframe(holder, from: .face(src.id), to: .face(to),
                                                                 frames: FlexibleSplitFrames(from: FlexibleSceneFrames(cur),
                                                                                             to: FlexibleSceneFrames(scene),
                                                                                             toRef: .face(to)))
                            }
                            if let st = rc.settings.designStamp { checks.append(FlexibleCheckStamp(faceRegionID: to, stamp: st)) }
                        }
                    }
                } catch {
                    return FlexibleRowCopy.fit("\(displayName(src.id)) · \(text("\(error)"))")
                }
            }
            moved.append((olds.map(\.id), news, checks))
        }
        // ── commit: the regions, the faces and the presses — ONE edit between two undo seals
        guard sceneState == .ready, openedKey == opened, currentSceneKey == opened, project.faceRegions == regions0 else {
            return FlexibleRowCopy.edgePickOpening   // the part changed while core was asked: nothing stored
        }
        // the main page's groups read over the regions after the cut — the same re-sync the reopen makes, made HERE so it
        // is part of this one edit (a Load group's share of a face is its rest's now; a strip is in a press, never a face)
        let loads = FlexibleMainPageLoads.derive(groups: project.selection.groups, force: project.force,
                                                 faceRegions: plan.faceRegions, mesh: mesh, regions: after)
        project.sealUndoStep()
        actionSerial += 1
        FlexibleSectorMigration.assignRegions(project, plan.faceRegions)   // (I2's write — the red control only)
        let newGroup = FlexibleSqueezeGroups.nextID(s0)
        edit({ s in
            for mv in moved {
                let at = s.faces.firstIndex { mv.old.contains($0.faceRegionID) } ?? s.faces.count
                s.faces.removeAll { mv.old.contains($0.faceRegionID) }
                s.checkStamps.removeAll { mv.old.contains($0.faceRegionID) }
                s.checkStamps += mv.checks
                s.faces.insert(contentsOf: mv.new, at: Swift.min(at, s.faces.count))
            }
            for id in ch.remove { s.removePress(id) }
            for e in entries {
                guard let regs = plan.regions[e.id] else { continue }
                if var p = s.press(e.id) {
                    p.strip = plan.strips[e.id]
                    if regs != p.regions {
                        let wasHalfway = p.snapTarget == .halfway
                        p.setMembers(regs)
                        if wasHalfway, let rel = aims[e.id] { p.aim(rel.direction, snap: rel.snap?.raw) }
                    }
                    s.setPress(p)
                } else if let rel = aims[e.id] {
                    var f = FlexibleFaceSettings(faceRegionID: regs[0])
                    f.weightKg = kg ?? 0
                    f.weightFrom = nil
                    f.squeezeGroup = newGroup
                    s.setPress(FlexiblePress(id: e.id, regions: regs, direction: rel.direction, snap: rel.snap?.raw,
                                             settings: f, strip: plan.strips[e.id]))
                }
            }
            FlexibleSqueezeGroups.normalise(&s)
            _ = Self.adopt(loads, into: &s)
            if let colour, let first = ch.add.first?.id, let g = FlexibleSqueezeGroups.group(ofPress: first, in: s) {
                var map = s.groupColours ?? [:]
                map[String(g.id)] = colour.rawValue
                s.groupColours = FlexibleSqueezeGroups.canonical(map, groups: FlexibleSqueezeGroups.groups(s))
            }
        }, recompute: false)
        project.sealUndoStep()
        refreshMainPageLoads()   // the cache follows (no edit)
        for mv in moved { for id in mv.old where settings.face(id) == nil { purgeFaceCaches(id) } }
        // ★ ROUND 7 (S, 4f d): the selected face's rest — only where the OPEN tab shows it (it opened Group 1 behind the
        // edges tab, his img4), else none
        if let r = selectedRegion, settings.face(r) == nil, let mv = moved.first(where: { $0.old.contains(r) }) {
            let n = mv.new.first?.faceRegionID
            selectedRegion = n.flatMap { Self.controlRailFollowsSelection || admitsSelection($0) ? $0 : nil }
        }
        // ── the page's scene: the one core was asked on, when the project's key is its key now
        if currentSceneKey == key { await frameWorker.install(scene, key: key) }
        openScene()
        return nil
    }

    // MARK: - the Flexible route (round 7, M2)

    /// ★ ROUND 7 (M2 — the reviewer's ruling 3: "FLEXIBLE-ONLY sectors carried in the job, NOT Surface-stage sectors"):
    /// APPLY A STRIP CHANGE AS ONE EDIT, the strips Flexible-only: the strips' areas are stored on their presses and the
    /// pieces DERIVED (FlexibleSectors — nested inside the lattice sections, D6); a scene opened on the regions after the
    /// change answers each new or re-cut press's halfway and re-expresses each face's settings onto its rest through core's
    /// frames; then the faces and the presses are committed between two undo seals. `project.faceRegions` is never written.
    func changeFlexibleStrips(_ ch: StripChange, kg: Double? = nil, colour: FlexibleGroupColour? = nil) async -> String? {
        switch await prepareFlexibleStrips(ch, kg: kg, colour: colour) {
        case .refused(let why): return why
        case .ready(let plan): return await commitFlexibleStrips(plan)
        }
    }

    /// ★ R7-E1 REVIEW: a strip change PLANNED — every check core and his rules make, the scene opened on the regions after it, each
    /// face's settings re-expressed — and nothing stored (`commitFlexibleStrips` stores it as one edit). The lattice landing probes
    /// with it (FlexibleStageModel+FlatPrism): a refused plan stores nothing and opens nothing more.
    func prepareFlexibleStrips(_ ch: StripChange, kg: Double? = nil, colour: FlexibleGroupColour? = nil) async -> FlexibleStripPlan {
        guard sceneState == .ready, let opened = openedKey, opened == currentSceneKey, let mesh = project.viewerMesh else {
            return .refused(FlexibleRowCopy.edgePickOpening)
        }
        let s0 = settings
        let before = regions
        // ★ R7-E1: every strip press as it will be — a cut change's direction and depth on it (M2's width written now), a new
        // pick at its halfway — so the sectors are cut by each press's own flat prism (FlexibleFlatPrism.planCut)
        var strips: [(id: UUID, strip: FlexibleStrip)] = []
        var regionsOf: [UUID: [Int]] = [:]
        var will: [FlexiblePress] = []
        for p in s0.presses ?? [] where !ch.remove.contains(p.id) {
            var q = p
            if var st = p.strip, let c = ch.cut[p.id] {
                st.halfway = st.halfway ?? FlexibleFlatPrism.halfway(of: p)
                st.widthMM = nil
                q.strip = st
                q.direction = c.direction
                q.settings.deepestMM = c.depthMM
            }
            if let st = q.strip { strips.append((p.id, st)); regionsOf[p.id] = p.regions }
            will.append(q)
        }
        var adds = Set<UUID>()
        for a in ch.add {
            var st = a.strip
            for k in st.members.indices { st.members[k].root = -1 }   // derived (FlexibleSectors)
            guard let d = ch.cut[a.id]?.direction ?? st.halfway else {
                return .refused(FlexibleRowCopy.fit("\(st.label) \u{00B7} \(FlexibleRowCopy.coreRefuses)"))
            }
            strips.append((a.id, st))
            adds.insert(a.id)
            var f = FlexibleFaceSettings(faceRegionID: -1)
            f.deepestMM = ch.cut[a.id]?.depthMM ?? FlexibleFlatPrism.defaultDepthMM
            will.append(FlexiblePress(id: a.id, regions: [], direction: d, snap: FlexiblePress.Snap.halfway.raw, settings: f, strip: st))
        }
        let willByID = Dictionary(will.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let changed = adds.union(ch.cut.keys)
        // the Flexible sectors after the change (the session's numbers: the same the committed settings will read)
        var probe = s0
        probe.presses = will.isEmpty ? nil : will
        let state = sectorState(for: probe, newPicks: changed)
        var set = state.set
        var after = state.regions
        if FlexibleEdgeStrips.controlWholeFaces {
            // ★ RED CONTROL: the picks press their WHOLE member faces — nothing is cut, the face groups keep them too
            set = before.flexible ?? .empty
            for (id, st) in strips { set.stripRegions[id] = regionsOf[id] ?? st.members.map(\.face) }
            after = before
        }
        if let first = strips.first(where: { set.refused[$0.id] != nil }), let why = set.refused[first.id] { return .refused(why) }
        // ★ R7-E1 REVIEW (the verifier: two flat prisms on one face could take it all, its rest falling back to the WHOLE face over
        // both pieces — core's shared_footprint): HIS RULE "as long as each face keeps some of itself", over every press on the face
        // together — each new or re-cut press's faces keep 0.5 mm beyond every cut there, and every face a strip cuts keeps a piece
        // that is not a strip. The handles and a typed value are held to it first (flatLimits); this never stores what breaks it.
        if !FlexibleEdgeStrips.controlWholeFaces, !Self.controlPerPressRest {
            if let why = Self.keepsEveryRest(will: will, changed: changed, mesh: mesh, name: { [weak self] f in self?.displayName(f) ?? "Face \(f)" }) {
                return .refused(why)
            }
            // a face group's face (or its section) the strips would take whole: no piece left to hold its settings
            let stripRoots = Set(set.pieces.filter { $0.kind == .strip }.map(\.rootRegion))
            for root in stripRoots.sorted() where !set.pieces.contains(where: { $0.rootRegion == root && $0.kind != .strip }) {
                let had = (before.flexible?.pieces ?? []).filter { $0.rootRegion == root && $0.kind != .strip }.map(\.wireID)
                guard (had.isEmpty ? [root] : had).contains(where: { s0.face($0) != nil }) else { continue }
                return .refused(FlexibleFlatPrismAngles.line(.rest(0), strip: strips[0].strip, name: { [weak self] _ in self?.displayName(root) ?? "Face \(root)" }))
            }
        }
        let key = sceneKey(regionsKey: after.key)
        // ── core, on the regions after the change
        let scene: FlexibleScene
        do {
            guard let job = try sceneJob(sectors: after.wire) else { return .refused(FlexibleRowCopy.edgePickOpening) }
            // ★ ROUND 7, RULING 6 (FlexibleCoreDoor): through the door — no face-prism, no scene asked of core
            let door = frameWorker.door, prisms = mayAskCore(facePrism: facePrismsNow)
            await holdLanded()
            scene = try await Task.detached(priority: .userInitiated) { try door.open(jobJSON: job.json, jobDir: job.dir, facePrism: prisms) }.value
        } catch {
            return .refused(FlexibleRowCopy.fit(text("\(error)")))
        }
        // ── ★ R7-E1: each new or re-cut press, as core sees it on the regions after the change — core's verdict on its STATED
        // direction (never re-aimed: the halfway is its whole faces', stored at pick time), then core's press stack checked
        // against the lattice: every column's target δ_k = (t_A + h) − entry_t_k within its lattice_mm (FlexibleFlatPrism.latticeCap)
        func plain(_ reason: String) -> String {
            var names: [Int: String] = [:]
            for id in FlexiblePressAim.regionIDs(reason) {
                let sec = after.sector(id)
                names[id] = FlexibleRowCopy.faceName(sector: sec?.name, face: sec == nil ? id : after.faces(of: id, mesh: mesh).first ?? id)
            }
            return FlexiblePressAim.plainLine(reason) { names[$0] ?? "Face \($0)" }
        }
        // ★ R7-E1 REVIEW (the verifier: a neighbour re-cut by another's change was stored unasked): every strip press whose pieces
        // change is asked — the new and re-cut ones, and a neighbour the plan clipped or renumbered
        var asked = changed
        for (id, _) in strips where !changed.contains(id) && set.stripRegions[id] != regionsOf[id] && !(set.stripRegions[id]?.isEmpty ?? true) {
            asked.insert(id)
        }
        if !FlexibleEdgeStrips.controlWholeFaces {
            for id in asked.sorted(by: { $0.uuidString < $1.uuidString }) {
                guard let q = willByID[id], let regs = set.stripRegions[id], !regs.isEmpty, let cut = FlexibleFlatPrism.cut(of: q) else { continue }
                if let injected = Self.controlRefuseFlatCut, changed.contains(id) { return .refused(plain(injected)) }   // (RED CONTROL: core refuses)
                do {
                    let d = q.direction
                    let v = try await Task.detached(priority: .userInitiated) { try scene.pressVerdict(regs, direction: d) }.value
                    guard v.accepted else { return .refused(plain(v.reason)) }
                    let a = cut.apex
                    let got = try await Task.detached(priority: .userInitiated) { () -> (FlexStackInfo, Double) in
                        let k = try scene.registerPress(regs, direction: d)
                        let st = try scene.stack(face: k, rotation: 0)
                        let t = try scene.toUVT(face: k, rotation: 0, [a.x, a.y, a.z])
                        return (st, t.count >= 3 ? t[2] : 0)
                    }.value
                    // (no face-prism — only under the tests' ask-core control, ruling 6 — is no lattice at all, M1: no stop to read)
                    if facePrismsNow, let cap = FlexibleFlatPrism.latticeCap(got.0, apexT: got.1), cut.depthMM > cap + 1e-6 {
                        let line = FlexibleRowCopy.flatLatticeEnds(cap)
                        // ★ R7-E1 REVIEW: N is core's number along the RELEASED arrow — the stop keeps that arrow (its fix keeps it)
                        let control = Self.controlNoLatticeLanding
                        lastFlatStop = FlexibleFlatStop(press: id, line: line, setMM: cap, direction: control ? nil : d,
                                                        snap: control ? nil : ch.cut[id]?.snap)
                        return .refused(line)
                    }
                } catch {
                    return .refused(FlexibleRowCopy.fit("\(q.strip?.label ?? "") \u{00B7} \(text("\(error)"))"))
                }
            }
        }
        // ── each root's settings onto its pieces after the change, re-expressed through core's frames (open scene → new)
        func pieces(_ regs: FlexibleRegions, _ root: Int) -> [Int] {
            let all = (regs.flexible?.pieces ?? []).filter { $0.rootRegion == root }
            let pcs = all.filter { $0.kind != .strip }.map(\.wireID)
            // ★ R7-E1 REVIEW: never the WHOLE face for a face a strip cuts (it would overlap the strip — core's shared_footprint)
            if pcs.isEmpty, all.contains(where: { $0.kind == .strip }), !Self.controlPerPressRest { return [] }
            return pcs.isEmpty ? [root] : pcs
        }
        let rootsTouched = Set((before.flexible?.pieces ?? []).map(\.rootRegion) + set.pieces.map(\.rootRegion))
        var moved: [(old: [Int], new: [FlexibleFaceSettings])] = []
        for root in rootsTouched.sorted() {
            let was = pieces(before, root), now = pieces(after, root)
            guard Set(was) != Set(now) else { continue }
            let olds = was.compactMap { id in s0.face(id).map { (id: id, f: $0) } }
            guard !olds.isEmpty else { continue }
            var news: [FlexibleFaceSettings] = []
            for to in now {
                let face = after.faces(of: to, mesh: mesh).first ?? root
                let tris = FlexibleEdgeStrips.triangles(face: face, mesh: mesh)
                let src = olds.max { a, b in
                    FlexibleEdgeStrips.area(tris, before.cuts(of: a.id) + after.cuts(of: to))
                        < FlexibleEdgeStrips.area(tris, before.cuts(of: b.id) + after.cuts(of: to))
                }!
                // a piece no old setting overlaps (a section a strip left alone keeps its own) is not his to fill
                guard FlexibleEdgeStrips.area(tris, before.cuts(of: src.id) + after.cuts(of: to)) > 1e-6 else { continue }
                if src.id == to { news.append(src.f); continue }
                do {
                    let r = try await frameWorker.withScene { cur in
                        try FlexiblePressReframe.reframe(src.f, from: .face(src.id), to: .face(to),
                                                         frames: FlexibleSplitFrames(from: FlexibleSceneFrames(cur),
                                                                                     to: FlexibleSceneFrames(scene), toRef: .face(to)))
                    }
                    var f = r.settings
                    f.faceRegionID = to
                    news.append(f)
                } catch {
                    return .refused(FlexibleRowCopy.fit("\(displayName(src.id)) · \(text("\(error)"))"))
                }
            }
            moved.append((olds.map(\.id), news))
        }
        return .ready(FlexibleStripPlan.Ready(ch: ch, kg: kg, colour: colour, opened: opened, s0: s0, mesh: mesh, set: set, after: after,
                                              key: key, scene: scene, strips: strips, willByID: willByID, adds: adds, moved: moved))
    }

    /// ★ R7-E1 REVIEW: a planned strip change STORED — the faces and the presses, ONE edit between two undo seals (the Surface
    /// stage's regions untouched); nothing when the part changed while core was asked.
    func commitFlexibleStrips(_ plan: FlexibleStripPlan.Ready) async -> String? {
        let ch = plan.ch, kg = plan.kg, colour = plan.colour, opened = plan.opened, s0 = plan.s0, mesh = plan.mesh
        let set = plan.set, after = plan.after, key = plan.key, scene = plan.scene, strips = plan.strips
        let willByID = plan.willByID, adds = plan.adds, moved = plan.moved
        // ── commit: the faces and the presses — ONE edit between two undo seals (the Surface stage's regions untouched)
        guard sceneState == .ready, openedKey == opened, currentSceneKey == opened, settings == s0 else {
            return FlexibleRowCopy.edgePickOpening   // the part changed while core was asked: nothing stored
        }
        let loads = FlexibleMainPageLoads.derive(groups: project.selection.groups, force: project.force,
                                                 faceRegions: restoredFaceRegions, mesh: mesh, regions: after)
        project.sealUndoStep()
        actionSerial += 1
        let newGroup = FlexibleSqueezeGroups.nextID(s0)
        edit({ s in
            for mv in moved {
                let at = s.faces.firstIndex { mv.old.contains($0.faceRegionID) } ?? s.faces.count
                s.faces.removeAll { mv.old.contains($0.faceRegionID) }
                s.checkStamps.removeAll { mv.old.contains($0.faceRegionID) }
                s.faces.insert(contentsOf: mv.new, at: Swift.min(at, s.faces.count))
            }
            for id in ch.remove { s.removePress(id) }
            for (id, _) in strips {
                guard let regs = set.stripRegions[id], !regs.isEmpty, let q = willByID[id] else { continue }
                if var p = s.press(id) {
                    if let c = ch.cut[id] {
                        // ★ R7-E1: the flat prism — the one mutator (its pieces, direction, depth, snap; M2's width cleared)
                        p.strip = q.strip
                        p.setFlatCut(regions: regs, direction: c.direction, snap: c.snap, depthMM: c.depthMM)
                    } else if regs != p.regions {
                        // a neighbour's re-cut renumbered its pieces: its own plane, direction and snap kept
                        p.regions = regs
                        p.settings.faceRegionID = regs[0]
                    }
                    s.setPress(p)
                } else if adds.contains(id) {
                    var f = FlexibleFaceSettings(faceRegionID: regs[0])
                    f.weightKg = kg ?? 0
                    f.weightFrom = nil
                    f.squeezeGroup = newGroup
                    f.deepestMM = q.settings.deepestMM
                    // (the whole-face red control stores no strip area: its geometry would derive the strips again)
                    s.setPress(FlexiblePress(id: id, regions: regs, direction: q.direction, snap: FlexiblePress.Snap.halfway.raw,
                                             settings: f, strip: FlexibleEdgeStrips.controlWholeFaces ? nil : q.strip))
                }
            }
            FlexibleSqueezeGroups.normalise(&s)
            _ = Self.adopt(loads, into: &s)
            if let colour, let first = ch.add.first?.id, let g = FlexibleSqueezeGroups.group(ofPress: first, in: s) {
                var map = s.groupColours ?? [:]
                map[String(g.id)] = colour.rawValue
                s.groupColours = FlexibleSqueezeGroups.canonical(map, groups: FlexibleSqueezeGroups.groups(s))
            }
        }, recompute: false)
        project.sealUndoStep()
        refreshMainPageLoads()
        for mv in moved { for id in mv.old where settings.face(id) == nil { purgeFaceCaches(id) } }
        if let r = selectedRegion, settings.face(r) == nil, let mv = moved.first(where: { $0.old.contains(r) }) {
            let n = mv.new.first?.faceRegionID
            selectedRegion = n.flatMap { Self.controlRailFollowsSelection || admitsSelection($0) ? $0 : nil }
        }
        if currentSceneKey == key { await frameWorker.install(scene, key: key) }
        openScene()
        return nil
    }
}
