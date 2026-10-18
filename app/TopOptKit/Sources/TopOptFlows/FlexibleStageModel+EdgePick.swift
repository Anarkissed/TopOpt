// FlexibleStageModel+EdgePick — the stage model's side of round 6 item 2: [+ New] → [Edges/corners] (task 2026-10-08;
// the maintainer OKed the design directly, the reviewer: "build it as posted"; r6 spec §3).
//
// ★ HIS FLOW. [+ New] asks [Faces] [Edges/corners] on one line. Edges/corners opens PICK MODE (`startEdgePick`): a new
// group with its number and its free colour; every edge and corner of the part, from core's adjacency and the 15° rule
// (FlexibleEdgeCandidates), drawn on the model in colours that never repeat on touching ones, numbered as in the list
// beside it. A tap on a row or on the model (`edgePickTap`: the nearest corner, then edge; a repeat tap cycles) picks
// it. What cannot be picked is listed grey with one line why: AP2's reasons, "In Group N" (in another edges group's
// press already), core's verdict on its press, or the area's own (a fillet, a curved face). [Done · 2 picked]
// (`finishEdgePick`) is ONE undoable edit: each pick's STRIP (an edge) or PATCH (a corner) is cut on every member face
// through the Surface tool's own cut (FlexibleEdgeStrips), the face's own squeeze group KEEPS THE REST (its settings
// moved onto the rest, re-expressed through core's frames), and each pick becomes an AP1 FlexiblePress over its strips,
// aimed at AP3's default — core's halfway on the strips (FlexiblePressAimSet.defaultRelease) — in the new group, at the
// group's one force he typed. SAVED, NOT WRITTEN TO ANY JOB (`sentPresses` stays empty until AP9; `designInputs` strips
// presses), so no face press's job changes except the faces that gave a strip (their entry is their rest now).
// ★ CORE BEFORE THE CUT. The strips' halfway and core's verdict on them are asked of a scene opened on the regions AFTER
// the cut, before anything is committed (`changeStrips`), so the cut and its presses are one edit and one undo step;
// that scene then becomes the page's (`FlexibleWorker.install`), so the part does not open twice.
// ★ THE WIDTH. "Strip width" on the edges group's tab: core's lattice depth under the members (the smaller member's
// latticeMMMax), capped at half the face's extent across the edge; a change re-cuts that pick and every pick on the same
// faces, in the one order (`setStripWidth`) — one undo step. Removing a press (or its whole group) gives its strip back.
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
            var depth: [Int: Double?] = [:]
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
                var lattice: [Double?] = []
                for m in c.members {
                    if depth[m] == nil { depth[m] = .some(await latticeDepth(m)) }
                    lattice.append(depth[m] ?? nil)
                }
                switch FlexibleEdgeStrips.strip(for: c, label: FlexibleRowCopy.candidateLabel(c), order: order, meet: meet,
                                                facts: facts, faceRegions: restoredFaceRegions, existing: existing,
                                                latticeMM: lattice, name: { [weak self] r in self?.displayName(r) ?? "Face \(r)" }) {
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
            // ★ CORE'S VERDICT on each pickable candidate's press (its whole members, along core's halfway)
            for c in list.candidates where strips[c.number] != nil {
                let aim = try await pressAim(c.members)
                guard edgePick?.token == token else { return }
                if aim.defaultRelease == nil {
                    let why = aim.why ?? aim.asked.first { !$0.accepted }?.line ?? FlexibleRowCopy.coreRefuses
                    edgePick?.greyed[c.number] = FlexibleRowCopy.fit(why)
                    edgePick?.picks.removeAll { $0 == c.number }
                }
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
        for (i, n) in pick.picks.enumerated() {
            guard var st = pick.strips[n] else { continue }
            st.order = base + i
            adds.append((UUID(), st))
        }
        pick.working = true
        pick.line = nil
        edgePick = pick
        if let why = await changeStrips(StripChange(add: adds), kg: kg, colour: pick.colour) {
            edgePick?.working = false
            edgePick?.line = why
            return why
        }
        edgePick = nil
        if let first = adds.first?.id, let g = FlexibleSqueezeGroups.group(ofPress: first, in: settings) {
            rail = .group(g.id)
            selectedPress = first
            toast = lines.first ?? FlexibleRowCopy.edgesGroupMade(g.number, edges: pick.edgesPicked, corners: pick.cornersPicked)
        }
        return nil
    }

    // MARK: - the strips after [Done]

    /// ★ "Strip width" changed on press `id`: that pick and every pick on the same faces re-cut, in the one order —
    /// one undo step. Clamped to 0.5 mm … the cap (half the narrowest member face across its edge).
    @discardableResult
    public func setStripWidth(_ id: UUID, mm: Double) async -> String? {
        guard let st = settings.press(id)?.strip, mm.isFinite else { return nil }
        let w = Swift.min(Swift.max(FlexibleEdgeStrips.minWidthMM, mm), st.capMM)
        guard w != st.widthMM else { return nil }
        return await changeStrips(StripChange(width: [id: w]))
    }

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
        return FlexibleRowCopy.fit(st.label + " \u{00B7} " + names.joined(separator: " + "), 34)
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

    /// What a change does to the strips.
    struct StripChange {
        var add: [(id: UUID, strip: FlexibleStrip)] = []
        var width: [UUID: Double] = [:]
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
            guard var st = p.strip else { continue }
            if ch.remove.contains(p.id) { replay.formUnion(st.members.map(\.root).filter { $0 >= 0 }); continue }
            if let w = ch.width[p.id] { st.widthMM = w; replay.formUnion(st.members.map(\.root).filter { $0 >= 0 }) }
            entries.append(.init(id: p.id, strip: st, regions: p.regions))
        }
        for a in ch.add {
            entries.append(.init(id: a.id, strip: a.strip, regions: nil))
            replay.formUnion(a.strip.members.map(\.root).filter { $0 >= 0 })
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
        guard sceneState == .ready, let opened = openedKey, opened == currentSceneKey, let mesh = project.viewerMesh else {
            return FlexibleRowCopy.edgePickOpening
        }
        let s0 = settings
        let before = regions
        var strips: [(id: UUID, strip: FlexibleStrip)] = []
        var regionsOf: [UUID: [Int]] = [:]
        for p in s0.presses ?? [] {
            guard var st = p.strip, !ch.remove.contains(p.id) else { continue }
            if let w = ch.width[p.id] { st.widthMM = w }
            strips.append((p.id, st))
            regionsOf[p.id] = p.regions
        }
        var adds = Set<UUID>()
        for a in ch.add {
            var st = a.strip
            for k in st.members.indices { st.members[k].root = -1 }   // derived (FlexibleSectors)
            strips.append((a.id, st))
            adds.insert(a.id)
        }
        // the Flexible sectors after the change (the session's numbers: the same the committed settings will read)
        var probe = s0
        probe.presses = (s0.presses ?? []).filter { !ch.remove.contains($0.id) }.map { p in
            var q = p
            if let w = ch.width[p.id] { q.strip?.widthMM = w }
            return q
        }
        for (id, st) in strips where adds.contains(id) {
            probe.presses?.append(FlexiblePress(id: id, regions: [], direction: SIMD3(0, 0, -1), settings: FlexibleFaceSettings(faceRegionID: -1), strip: st))
        }
        let state = sectorState(for: probe, newPicks: adds)
        var set = state.set
        var after = state.regions
        if FlexibleEdgeStrips.controlWholeFaces {
            // ★ RED CONTROL: the picks press their WHOLE member faces — nothing is cut, the face groups keep them too
            set = before.flexible ?? .empty
            for (id, st) in strips { set.stripRegions[id] = regionsOf[id] ?? st.members.map(\.face) }
            after = before
        }
        if let first = strips.first(where: { set.refused[$0.id] != nil }), let why = set.refused[first.id] { return why }
        let key = sceneKey(regionsKey: after.key)
        // ── core, on the regions after the change
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
        for (id, st) in strips {
            let regs = set.stripRegions[id] ?? []
            guard regionsOf[id] == nil || regs != regionsOf[id] else { continue }
            do {
                let aimSet = try await Self.aimSet(regs, source: source)
                guard let rel = aimSet.defaultRelease else {
                    let why = aimSet.why ?? aimSet.asked.first { !$0.accepted }?.line ?? FlexibleRowCopy.coreRefuses
                    return FlexibleRowCopy.fit("\(st.label) · \(why)")
                }
                aims[id] = rel
            } catch {
                return FlexibleRowCopy.fit("\(st.label) · \(text("\(error)"))")
            }
        }
        // ── each root's settings onto its pieces after the change, re-expressed through core's frames (open scene → new)
        func pieces(_ regs: FlexibleRegions, _ root: Int) -> [Int] {
            let pcs = (regs.flexible?.pieces ?? []).filter { $0.rootRegion == root && $0.kind != .strip }.map(\.wireID)
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
                    return FlexibleRowCopy.fit("\(displayName(src.id)) · \(text("\(error)"))")
                }
            }
            moved.append((olds.map(\.id), news))
        }
        // ── commit: the faces and the presses — ONE edit between two undo seals (the Surface stage's regions untouched)
        guard sceneState == .ready, openedKey == opened, currentSceneKey == opened, settings == s0 else {
            return FlexibleRowCopy.edgePickOpening   // the part changed while core was asked: nothing stored
        }
        let loads = FlexibleMainPageLoads.derive(groups: project.selection.groups, force: project.force,
                                                 faceRegions: restoredFaceRegions, mesh: mesh, regions: after)
        project.sealUndoStep()
        actionSerial += 1
        let newGroup = FlexibleSqueezeGroups.nextID(s0)
        let stripOf = Dictionary(strips.map { ($0.id, $0.strip) }, uniquingKeysWith: { a, _ in a })
        edit({ s in
            for mv in moved {
                let at = s.faces.firstIndex { mv.old.contains($0.faceRegionID) } ?? s.faces.count
                s.faces.removeAll { mv.old.contains($0.faceRegionID) }
                s.checkStamps.removeAll { mv.old.contains($0.faceRegionID) }
                s.faces.insert(contentsOf: mv.new, at: Swift.min(at, s.faces.count))
            }
            for id in ch.remove { s.removePress(id) }
            for (id, _) in strips {
                guard let regs = set.stripRegions[id], !regs.isEmpty else { continue }
                if var p = s.press(id) {
                    p.strip = stripOf[id]
                    if regs != p.regions {
                        let wasHalfway = p.snapTarget == .halfway
                        p.setMembers(regs)
                        if wasHalfway, let rel = aims[id] { p.aim(rel.direction, snap: rel.snap?.raw) }
                    }
                    s.setPress(p)
                } else if let rel = aims[id] {
                    var f = FlexibleFaceSettings(faceRegionID: regs[0])
                    f.weightKg = kg ?? 0
                    f.weightFrom = nil
                    f.squeezeGroup = newGroup
                    // (the whole-face red control stores no strip area: its geometry would derive the strips again)
                    s.setPress(FlexiblePress(id: id, regions: regs, direction: rel.direction, snap: rel.snap?.raw,
                                             settings: f, strip: FlexibleEdgeStrips.controlWholeFaces ? nil : stripOf[id]))
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
