// FlexibleStageModel+PressSend — the edge/corner press SENT to core (task 2026-09-29-flexible-screens, round 7 batch R7-E2). The
// reviewer's ruling (angled presses, 2026-10-07 item 6): "Under an angled press, the preview lattice is graded by that press's own
// design along the arrow, and blended into the neighbouring faces' lattices by core's conflict rule … the preview shows what will
// be built." His 2026-10-18 answers: do not ask #361 yet — ship the twist with its honest line.
//
// ★ THE PRESS IS A DESIGN TARGET through its synthetic key (FlexibleSquishTarget): `target(r)` — r ≥ 0 a face's settings, r ≤ −1000
// the press's (faceRegionID = r); `setTarget` routes a press through setPress (its regions[0] restored); `key(r)` takes both. The
// design pipeline designs every registered press on CORE's press stack (scheduleDesigns), with the map FlexiblePressShape builds
// from core's frame.
// ★ WHAT IS SENT (`pressSupport`, `sentPresses`): FlexiblePressSupport's gate per press. In the job (`pressJobEntries`) after the
// face entries; in the lattice (generateLattice) as core's field over the press key; on the card its one line (`pressWarning`).

import Foundation
import simd
import TopOptKit

extension FlexibleStageModel {

    /// Core's synthetic press ids start here and go down (the bridge's kSyntheticPressMax).
    nonisolated static let syntheticPressMax = -1000

    /// ★ RED CONTROL only (FlexibleR7E2Tests): E1's rule — presses stripped from the lattice's key and never built into it.
    @MainActor static var controlStripPresses: Bool {
        get { FlexibleStageSettings.controlStripPresses }
        set { FlexibleStageSettings.controlStripPresses = newValue }
    }
    /// ★ RED CONTROL only: the hold before E2 — a sent press's group not counted (Ready with both groups, one dropped).
    @MainActor static var controlHoldIgnoresPresses = false

    // MARK: - FlexibleSquishTarget

    /// The press registered on the open scene under synthetic key `r`.
    public func pressID(forKey r: Int) -> UUID? {
        guard r <= Self.syntheticPressMax else { return nil }
        return pressRegistrations.first { $0.value.key == r }?.key
    }

    /// ★ THE TARGET a key names: r ≥ 0 a face's settings; r ≤ −1000 the press's settings with faceRegionID = r.
    public func target(_ r: Int) -> FlexibleFaceSettings? {
        guard r <= Self.syntheticPressMax else { return settings.face(r) }
        guard let id = pressID(forKey: r), var f = settings.press(id)?.settings else { return nil }
        f.faceRegionID = r
        return f
    }

    /// Store a target's settings: a face's as before; a press's through setPress, its regions[0] restored.
    public func setTarget(_ f: FlexibleFaceSettings) {
        guard f.faceRegionID <= Self.syntheticPressMax else { edit { $0.setFace(f) }; return }
        guard let id = pressID(forKey: f.faceRegionID), var p = settings.press(id) else { return }
        var g = f
        g.faceRegionID = p.regions.first ?? p.settings.faceRegionID
        p.settings = g
        edit { $0.setPress(p) }
    }

    /// The press's design key (its synthetic key, rotation 0) on the open scene.
    public func pressDesignKey(_ id: UUID) -> FlexFaceKey? {
        pressRegistrations[id].map { FlexFaceKey(region: $0.key, rotation: 0) }
    }

    /// Core's design of the press (on its press stack).
    public func pressDesign(_ id: UUID) -> FlexFaceDesignInfo? { pressDesignKey(id).flatMap { designs[$0] } }

    /// What FlexiblePressShape needs of the press beyond core's stack.
    public func pressShape(_ id: UUID) -> FlexiblePressShape.Press? {
        guard let p = settings.press(id), let st = p.strip, let r = pressRegistrations[id] else { return nil }
        return FlexiblePressShape.Press(corner: st.kind == .corner, endsUVT: r.endsUVT)
    }

    /// ★ The map core is sent for the press (the design's and the job's — one function).
    public func pressMap(_ id: UUID) -> FlexMap? {
        guard let p = settings.press(id), let r = pressRegistrations[id], let h = FlexibleFlatPrism.depth(of: p),
              let sh = pressShape(id) else { return nil }
        return FlexiblePressShape.map(r.stack, apexT: r.apexT, depthMM: h, press: sh)
    }

    /// ★ How far core's profile is off the flat prism (percent of h), from the design's S (core's squish_fraction) and δ_k.
    public func pressOffPercent(_ id: UUID) -> Double? {
        guard let d = pressDesign(id), d.refusal == nil, let p = settings.press(id), let r = pressRegistrations[id],
              let h = FlexibleFlatPrism.depth(of: p), d.columns.count == r.stack.columns.count else { return nil }
        return FlexiblePressShape.offPercent(s: d.columns.map(\.s), delta: FlexiblePressShape.delta(r.stack, apexT: r.apexT, depthMM: h),
                                             depthMM: h)
    }

    /// ★ What the design pipeline designs for each registered strip press: its key, its map, its weight (the pipeline's snapshot).
    var pressDesignTargets: [(id: UUID, key: FlexFaceKey, map: FlexMap, weightN: Double)] {
        (settings.presses ?? []).compactMap { p in
            guard p.strip != nil, let k = pressDesignKey(p.id), let map = pressMap(p.id), p.settings.weightKg > 0 else { return nil }
            return (p.id, k, map, p.settings.weightN)
        }
    }

    // MARK: - names

    /// ★ A region id as core names it, in his words: a press's piece → the press ("Edge 16"), a face → its name ("Face 3").
    public func coreRegionName(_ id: Int) -> String {
        if let p = (settings.presses ?? []).first(where: { $0.regions.contains(id) }), let label = p.strip?.label { return label }
        return displayName(id)
    }

    // MARK: - the gate

    /// ★ Every strip press's verdict (FlexiblePressSupport), memoised by what it is read from.
    public var pressSupport: [UUID: FlexiblePressSupport.Verdict] {
        let s = settings
        let strips = (s.presses ?? []).filter { $0.strip != nil }
        guard !strips.isEmpty else { return [:] }
        let core = (FlexiblePressSupport.schemaTakesPresses(), FlexiblePressSupport.bridgeBuildsPress, FlexiblePressSupport.apiVersion())
        var key = "\(s.faces.hashValue)|\(s.presses.hashValue)|\(regions.key)|\(core)|\(FlexiblePressShape.controlSilent)"
        for p in strips {
            let k = pressDesignKey(p.id)
            key += "|\(p.id.uuidString):\(k?.region ?? 0):\(pressRefusals[p.id] ?? "")"
            if let k {
                let d = designs[k]
                key += ":\(d == nil ? "-" : (d?.refusal?.code ?? "ok")):\(designErrors[k] ?? "")"
            }
        }
        key += "|\(pressConflicts.map { "\($0.faceA),\($0.faceB)" })"
        if let m = pressSupportMemo, m.key == key { return m.value }
        var out: [UUID: FlexiblePressSupport.Verdict] = [:]
        let two = Set(FlexibleEdgeStrips.regionsInTwoEntries(s))
        let shared = sharedFootprints(s)
        let pinches = pressPinchLines(s)
        for p in strips {
            let k = pressDesignKey(p.id)
            var stacked: String? = nil
            if let why = pressRefusals[p.id] { stacked = why } else if k == nil { stacked = "" }
            let twice = p.regions.first(where: two.contains).map { FlexibleRowCopy.pressTwoEntries(displayName($0)) }
            var refusal: String? = nil, designed = false
            if let k {
                if let d = designs[k] {
                    if let r = d.refusal {
                        refusal = FlexibleRowCopy.pressNotDesigned(FlexibleCoreRunReport.refusalLine(r).replacingOccurrences(of: "Core refused it: ", with: ""))
                    } else {
                        designed = true
                    }
                } else if let e = designErrors[k] {
                    refusal = FlexibleRowCopy.pressNotDesigned(FlexiblePressAim.plainLine(text(e)) { [weak self] r in self?.coreRegionName(r) ?? "Face \(r)" })
                }
            }
            let facts = FlexiblePressSupport.Facts(schema: core.0, bridge: core.1, api: core.2, stacked: stacked, twoEntries: twice,
                                                   shared: shared[p.id], designed: designed, designRefusal: refusal, conflict: pinches[p.id])
            out[p.id] = FlexiblePressSupport.verdict(facts)
        }
        pressSupportMemo = (key, out)
        return out
    }

    /// ★ CORE'S A3 RULE, asked of the app's own geometry first (FlexibleEdgeStrips' clipping): each strip press against every other
    /// LOADED entry — a loaded face, another strip press — whose surface it shares (more than 1e-3 mm² on a common face); the first
    /// such pair per press, with the shared area.
    func sharedFootprints(_ s: FlexibleStageSettings) -> [UUID: FlexibleSharedFootprint] {
        guard let mesh = project.viewerMesh else { return [:] }
        let regs = regions
        var entries: [(region: Int, press: UUID?)] = s.loadedFaces.map { ($0.faceRegionID, nil) }
        let strips = (s.presses ?? []).filter { $0.strip != nil }
        for p in strips { for r in p.regions { entries.append((r, p.id)) } }
        var trisOf: [Int: [[SIMD3<Double>]]] = [:]
        var out: [UUID: FlexibleSharedFootprint] = [:]
        for p in strips {
            for r in p.regions {
                if out[p.id] != nil { break }
                let fa = Set(regs.faces(of: r, mesh: mesh))
                for e in entries where e.press != p.id && e.region != r {
                    let common = fa.intersection(regs.faces(of: e.region, mesh: mesh)).sorted()
                    var mm2 = 0.0
                    for f in common {
                        let t = trisOf[f] ?? FlexibleEdgeStrips.triangles(face: f, mesh: mesh)
                        trisOf[f] = t
                        mm2 += FlexibleEdgeStrips.area(t, regs.cuts(of: r) + regs.cuts(of: e.region))
                    }
                    guard mm2 > 1e-3 else { continue }
                    let other = e.press.flatMap { id in s.press(id)?.strip?.label } ?? displayName(e.region)
                    out[p.id] = FlexibleSharedFootprint(press: p.id, pressName: p.strip?.label ?? "This press", otherRegion: e.region,
                                                        otherPress: e.press, otherName: other, mm2: mm2)
                    break
                }
            }
        }
        return out
    }

    /// ★ Core's one_profile_per_stack among presses of one squeeze group (FlexibleSqueezeGroups.pressPinches over core's stack
    /// conflicts): each press of such a pair, its one line.
    func pressPinchLines(_ s: FlexibleStageSettings) -> [UUID: String] {
        guard !pressConflicts.isEmpty else { return [:] }
        var pressOf: [Int: UUID] = [:]
        for p in s.presses ?? [] where p.strip != nil {
            if let first = p.regions.first { pressOf[first] = p.id }
            if let k = pressRegistrations[p.id]?.key { pressOf[k] = p.id }
        }
        var out: [UUID: String] = [:]
        for pair in FlexibleSqueezeGroups.pressPinches(pressConflicts, s, pressOf: pressOf) {
            let a = s.press(pair.a)?.strip?.label ?? "A press", b = s.press(pair.b)?.strip?.label ?? "a press"
            out[pair.a] = out[pair.a] ?? FlexibleRowCopy.pressConflict(a, b)
            out[pair.b] = out[pair.b] ?? FlexibleRowCopy.pressConflict(b, a)
        }
        return out
    }

    // MARK: - the card

    /// ★ THE CARD'S ONE WARNING LINE past core's refusal and a lattice stop: not in the job (its reason, and its 1–3 fixes) ›
    /// twisted (or a corner tipped) more than 2 % off › core's side label. nil: nothing to say.
    /// (The design ordered the side label before the twist line; on his pad every edge press is a side press, so the twist's honest
    /// line — his answer of 2026-10-18 — would never show: it comes first, the side label then, the ruling's sentence in its (i).)
    /// `warn`: said in the warning colour (not in the job; a twist core's map follows less closely than 2 %) — the side label is a
    /// plain caption.
    public func pressWarning(_ id: UUID) -> (line: String, fixes: [FlexiblePressFix], warn: Bool)? {
        guard let p = settings.press(id), let st = p.strip else { return nil }
        if let v = pressSupport[id], !v.inJob {
            if case .shared(let sh)? = v.reason { return (sh.line, sharedFixes(p, sh), true) }
            return (v.line ?? FlexibleRowCopy.pressNotSent, [], true)
        }
        if let off = pressOffPercent(id), let shape = pressShape(id) {
            let tipped = st.kind == .corner
                && FlexibleFlatPrism.halfway(of: p).map { FlexiblePressAim.bits($0) != FlexiblePressAim.bits(p.direction) } ?? false
            if FlexiblePressShape.twisted(shape) || tipped,
               let line = FlexiblePressShape.line(offPercent: off, corner: st.kind == .corner) { return (line, [], true) }
        }
        if pressStack(id)?.side == true { return (FlexibleRowCopy.sidePress, [], false) }
        return nil
    }

    /// The 1–3 fixes of a shared surface, the gentlest first (the first is the filled button): [Shallower] (only when a shallower
    /// flat prism shares none), [Face 3 rests] (the other is a loaded face), [Remove Edge 16] (found by looking: Remove sat first, a
    /// filled green button for the one that deletes).
    func sharedFixes(_ p: FlexiblePress, _ sh: FlexibleSharedFootprint) -> [FlexiblePressFix] {
        var out: [FlexiblePressFix] = []
        if let d = shallowerClear(p, sh) { out.append(.shallower(p.id, depthMM: d)) }
        if sh.otherPress == nil, settings.face(sh.otherRegion)?.isLoaded == true { out.append(.rest(sh.otherRegion, name: sh.otherName)) }
        out.append(.remove(p.id, label: sh.pressName))
        return Array(out.prefix(3))
    }

    /// The deepest of ¾, ½, ¼ of the press's depth (≥ 0.5 mm) at which its plane's pieces share no surface with the other entry.
    func shallowerClear(_ p: FlexiblePress, _ sh: FlexibleSharedFootprint) -> Double? {
        guard let st = p.strip, let c = FlexibleFlatPrism.cut(of: p), let mesh = project.viewerMesh else { return nil }
        let regs = regions
        let other = regs.cuts(of: sh.otherRegion), otherFaces = Set(regs.faces(of: sh.otherRegion, mesh: mesh))
        for k in [0.75, 0.5, 0.25] {
            let h = c.depthMM * k
            guard h >= FlexibleFlatPrism.minDepthMM else { break }
            let cuts = FlexibleFlatPrism.memberCuts(st, FlexibleFlatPrism.cut(st, direction: p.direction, depthMM: h))
            var mm2 = 0.0
            for (i, m) in st.members.enumerated() where otherFaces.contains(m.face) {
                mm2 += FlexibleEdgeStrips.area(FlexibleEdgeStrips.triangles(face: m.face, mesh: mesh), cuts[i] + other)
            }
            if mm2 <= 1e-3 { return h }
        }
        return nil
    }

    /// A fix of a press kept out of the job — ONE undo step. nil when done; else one line why not.
    @discardableResult
    public func applyPressFix(_ fix: FlexiblePressFix) async -> String? {
        project.sealUndoStep()
        defer { project.sealUndoStep() }
        switch fix {
        case .shallower(let id, let h):
            guard let p = settings.press(id) else { return nil }
            return await setFlatCut(id, depthMM: h, direction: p.direction, snap: p.snap)
        case .remove(let id, _):
            return await removeStripPresses([id])
        case .rest(let r, _):
            rest(r)
            return nil
        }
    }

    // MARK: - the job

    /// ★ The job's press entries: every press in the job but those with a region in `excluding` (a send that leaves a group out),
    /// in the settings' order.
    func pressJobEntries(excluding: Set<Int>) -> [FlexibleJob.PressEntry] {
        let sent = sentPresses
        return (settings.presses ?? []).compactMap { p in
            guard sent.contains(p.id), !p.regions.contains(where: excluding.contains), let map = pressMap(p.id) else { return nil }
            return FlexibleJob.PressEntry(id: p.id, regions: p.regions, direction: p.direction, weightN: p.settings.weightN, map: map)
        }
    }

    /// A press in the job, by its first region (the marker a send that leaves its group out lists among the resting regions).
    func sentPressMarker(_ id: UUID) -> Int? {
        sentPresses.contains(id) ? settings.press(id)?.regions.first : nil
    }

    /// ★ The ruling's sentence (2026-10-07 item 5), popped ONCE per session — when a SIDE press first goes into the job.
    func sayAngledEstimateOnce() {
        guard !sideSentenceSaid else { sideSentencePending = false; return }
        let side = sentPresses.contains { pressStack($0)?.side == true }
        guard side else { return }
        // another line is up (a read-through's note, a hold said): it is not replaced — the sentence follows when it clears
        guard toast == nil else { sideSentencePending = true; return }
        sideSentenceSaid = true
        sideSentencePending = false
        toast = FlexibleRowCopy.angledEstimateShort
    }
}
