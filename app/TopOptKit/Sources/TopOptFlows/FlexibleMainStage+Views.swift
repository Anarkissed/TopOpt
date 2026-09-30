// FlexibleMainStage+Views — the main Flexible page's views, legends and tap-to-read (task
// 2026-09-29-flexible-screens, round 3 batch C: items 1.4, T, 7; maintainer: "each data view
// with its own legend … tapping a legend switches it to 'Tap the part to read'; any tap on the
// part then pins a callout at that spot with the exact value and unit; a double tap exits").
//
// ★ THE VIEWS (all four combine): X-ray (the ghost — no legend, his answer), Dent heat (its
// own DS ramp), Stress (the solid part's FEA, Stress's rainbow), Lattice (the walls' density
// ramp). ONE tint array (FlexibleMainTints): Heat owns the map quads, Stress the rest of the
// part, X-ray ghosts what is not opaque.
//
// ★ ITS HOOKS (one line each in #354's WorkspacePlaceholder; the exact list is in the
// handoff): `tints(_:on:roles:stress:)` (H4'), the toggles' Stress + solve (H5'),
// FlexibleMainLegends (H6), `read` (H7), `wantsWallProbe` + `readLattice` (H8).

import Foundation
import QuartzCore
import simd
import TopOptKit

extension FlexibleMainStage {

    // MARK: Stress (item T)

    /// The Stress button. ★ BATCH C VERIFICATION: Stress and Heat are the two colourings of the
    /// pressed map, so turning Stress on takes the map from Heat (and Heat on takes it back) —
    /// with both on, Heat kept the map and Stress was left the part's 24 corner vertices, one
    /// flat blue (his project). X-ray and the lattice are NOT touched (it used to turn X-ray off,
    /// and with it the walls and their legend). The solve starts if there is no field.
    public func toggleStress() {
        if stress { stress = false; return }
        if heat { heat = false }
        stress = true
        requestStressIfNeeded()
    }
    /// The Dent heat button — the other colouring of the map (see toggleStress).
    public func toggleHeat() {
        if heat { heat = false; return }
        if stress { stress = false }
        heat = true
    }

    /// Ask the workspace's solver — it runs only when there is no field for these inputs (or the
    /// last one failed) and none is running. Called by the Stress button, by Settings' Save &
    /// Exit while Stress shows, by a main-page edit while Stress shows, and by Retry.
    func requestStressIfNeeded() {
        guard !stressRunning else { return }
        stressSolver?()
    }
    /// The Stress legend's Retry.
    public func retryStress() { requestStressIfNeeded() }

    /// H5' / H2: the workspace's solver, and its sim's phase observed (delivered on the next
    /// run-loop turn — never a publish inside the view update that handed it over).
    public func attach(_ s: FlexibleStressSolver) {
        stressSolver = { [weak self] in self?.noteOutcome(s.start()) }
        squishBusy = s.busy   // ★ BATCH G: no squish sim starts beside the Stress solve or a run
        guard stressSim !== s.sim else { return }
        stressSim = s.sim
        stressPhaseObservation = s.sim.$phase
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.syncStress() }
    }

    /// The sim's phase AS IT IS NOW (a delivery arrives a turn late, and may be stale).
    func syncStress() {
        guard let p = stressSim?.phase else { return }
        phaseChanged(p)
    }

    func noteOutcome(_ o: FlexibleStressSolver.Outcome) {
        switch o {
        case .blocked(let line): setStress(.blocked(line))
        case .started, .running: setStress(.running)
        case .waiting:   // ★ BATCH G: a squish sim is inside core — it starts when the sims go idle
            stressWaiting = true
            setStress(.running)
        case .current: setStress(.ready)
        }
    }

    func phaseChanged(_ p: LatticeSimModel.Phase) {
        switch p {
        case .running: setStress(.running)
        case .complete: setStress(.ready)
        case .failed(let why): setStress(.failed(why))
        case .idle: if stressState == .running { setStress(.idle) }   // cancelled; a blocker stays said
        }
    }

    private func setStress(_ s: FlexibleStressState) { if stressState != s { stressState = s } }

    /// A field that may be drawn: in hand, not refused since (a failed or blocked solve is said,
    /// never painted over with the last field's colours).
    var stressDrawable: Bool {
        guard stressField != nil, stressPeak > 0 else { return false }
        switch stressState {
        case .failed, .blocked: return false
        default: return true
        }
    }

    // MARK: the ONE tint array (H4')

    /// H4': the part with its map quads, coloured — Heat or Stress on the map, Stress on the part
    /// (when on), the Flexible face tints, the main page's group colours where Flexible has none,
    /// X-ray's ghost on everything not opaque. Composed only when an input changed.
    /// ★ BATCH C VERIFICATION: INERT off the Flexible stage — nothing noted, hashed or composed,
    /// and `roles` (an autoclosure) not even evaluated, on every other page's body pass.
    public func tints(_ project: ProjectModel, on stage: WorkspaceStage, roles: @autoclosure () -> [FaceID: SIMD4<Float>],
                      stress field: LatticeDemandField?) -> [Float]? {
        guard current(project, stage) != nil, let c = channels else { return nil }
        noteStressField(field)
        let roles = roles()
        var h = Hasher()
        for k in roles.keys.sorted() { h.combine(k); h.combine(roles[k]!) }
        let showStress = stress && stressDrawable
        let key = "\(generation)|\(h.finalize())|\(showStress ? stressKey : 0)|\(xray)|\(heat)|\(overlay != nil)"
        if key == composedKey { return composed }
        composedKey = key
        composed = FlexibleMainTints.compose(base: c.tints, overlay: overlay, part: project.viewerMesh, heat: heat,
                                             roles: roles, stress: showStress ? (stressField!, stressPeak) : nil,
                                             ghost: xray ? FlexibleColours.ghost : nil)
        if let m = model { FlexibleGroupFrames.paint(&composed, overlay: overlay, model: m) }   // ★ S1: the group frames in every view (Stress too)
        return composed
    }

    /// The field's identity (its shape and 32 strided samples — never a full scan per body
    /// pass) and, once per field, its peak.
    func noteStressField(_ f: LatticeDemandField?) {
        guard let f else {
            if stressField != nil { stressField = nil; stressKey = 0; stressPeak = 0 }
            return
        }
        var h = Hasher()
        h.combine(f.nx); h.combine(f.ny); h.combine(f.nz); h.combine(f.vonMises.count); h.combine(f.spacingMM)
        let n = f.vonMises.count
        if n > 0 { let step = Swift.max(1, n / 32); var i = 0; while i < n { h.combine(f.vonMises[i]); i += step } }
        let key = h.finalize()
        guard key != stressKey || stressField == nil else { return }
        stressField = f
        stressKey = key
        stressPeak = LatticeStressTint.peakMPa(f)
    }

    // MARK: the legends (H6)

    /// The data views on screen, each with its legend: the dent while its map shows, Stress
    /// while it is on, the lattice while its walls are drawn. X-ray has no legend.
    public var legendKinds: [FlexibleReadKind] {
        guard let m = model else { return [] }
        var out: [FlexibleReadKind] = []
        if heat, overlay?.flatStart.isEmpty == false, dentMaxMM > 0 { out.append(.dent) }
        if stress { out.append(.stress) }
        if latticeShown, m.lattice != nil, !m.latticeIsStale, !m.latticeBuilding { out.append(.lattice) }
        return out
    }

    /// Where each legend goes (FlexibleMainLegendLayout — the player keeps clear of these).
    public func legendFrames(viewport: CGSize, bottomClearance: CGFloat, chipColumnWidth: CGFloat) -> [FlexibleReadKind: FlexibleMainLegendLayout.Placed] {
        let keep = FlexibleMainLegendLayout.keepOut(viewport: viewport, bottomClearance: bottomClearance,
                                                    chipColumnWidth: chipColumnWidth)
        return FlexibleMainLegendLayout.place(legendKinds, minimized: minimized, viewport: viewport, keepOut: keep,
                                              priority: legendPriority)
    }

    /// A tap on an open legend: into its reading, or back out. ★ BATCH C VERIFICATION: it never
    /// reorders the legends (it set the placement priority, and at 11" landscape the tapped
    /// legend jumped 260 pt from under his finger) — only a pill he opens is placed first.
    public func legendTapped(_ k: FlexibleReadKind, mode: LatticeLegendMode) -> LatticeLegendMode {
        if FlexibleReadKind(mode: mode) == k { return .groups }
        clearReading()
        return k.mode
    }

    /// A legend went into (or out of) its reading: the squish holds still meanwhile, so the
    /// pinned reading stays on the surface it was read from (FlexibleSquishLoop.holdWhileReading).
    public func noteDrill(_ on: Bool) { loop.holdWhileReading(on) }

    /// The legend's one line. ★ BATCH C VERIFICATION: the dent's is "What you drew · mm" while
    /// the map shows his drawing (no lattice drawn, or a shape-only one — "no squish
    /// predicted"), and "Squish · mm" only for a lattice core designed.
    public func legendTitle(_ k: FlexibleReadKind) -> String {
        guard k == .dent else { return k.title }
        // ★ VERIFICATION OF D1: a Stamp face's squish here is core's — the WHOLE face sinks
        // (core brief #10) — while Settings shows the stamp he drew; the legend says so
        if let g = drawn, !g.shapeOnly, let m = model,
           Self.showsStampFace(squished: Set(g.squishedKeys.map(\.region)), settings: m.settings) {
            return FlexibleRowCopy.stampMainLegend
        }
        return FlexibleReadKind.dentTitle(drawn: drawn)
    }

    /// A pressed Stamp face among the faces the main page squishes.
    nonisolated static func showsStampFace(squished: Set<Int>, settings: FlexibleStageSettings) -> Bool {
        settings.loadedFaces.contains { $0.isStampShape && squished.contains($0.faceRegionID) }
    }

    /// The dent legend's "×k" (the map is drawn k times deeper).
    public var dentExaggeration: Int { Int(channels?.exaggeration ?? 1) }
    /// The dent legend's (i), ONE sentence: what the map is and why it looks deeper than it is.
    public var dentInfo: String {
        // ★ BATCH G: the 3D sim, said in ONE sentence (linear physics, scaled to core's squish) —
        // or, after a failed sim, core's words
        if fe.active {
            return FlexibleFE.info(exaggeration: dentExaggeration, stiffer: fe.coreRatio,
                                   largeStrain: Double(dentExaggeration) > fe.safeScale, bonded: fe.restsBonded)
        }
        if let why = fe.failure { return FlexibleFE.failedInfo(why, exaggeration: dentExaggeration) }
        let what = (channels?.legendLine ?? "").components(separatedBy: " · ").first ?? ""
        return (what.isEmpty ? "The map" : what) + " is drawn \(dentExaggeration)× deeper so it reads — tap here, then the part, for the true mm."
    }
    /// The Stress legend's (i): core's own words after a refusal, else what the view is.
    public var stressInfo: String {
        if case .failed(let why) = stressState { return "Core could not solve the solid part: \(why)" }
        return FlexibleReadKind.stress.info
    }

    /// The Stress legend's ends: 0 … the peak, three significant digits (his pad peaks at
    /// 0.0462 MPa — "0.05" read as a round number it is not).
    public var stressEnds: (lo: String, hi: String) { ("0", FlexibleProbe.mpa(stressPeak) + " MPa") }

    /// The lattice legend's ends ("18% · 9.2 mm") and span, once per lattice generation.
    public func latticeEnds() -> (lo: String, hi: String, span: ClosedRange<Double>)? {
        guard let g = model?.lattice else { return nil }
        if let c = latticeEndsCache, c.generation == g.generation { return (c.lo, c.hi, c.span) }
        latticeSpanScans += 1
        let s = FlexibleProbe.latticeSpan(g.inputs)
        func end(_ rho: Double) -> String {
            let c = FlexibleProbe.drawnCell(rho: rho, g.inputs)
            return String(format: "%.0f%% · %@%.1f mm", rho * 100, c.blended ? "≈" : "", c.mm)
        }
        latticeEndsCache = (g.generation, s, end(s.lowerBound), end(s.upperBound))
        return (end(s.lowerBound), end(s.upperBound), s)
    }

    // MARK: tap-to-read (H7, H8)

    /// H6: the view the taps come through — the published camera composed with the settle, about
    /// the DRAWN mesh's centre (the overlay's: what the renderer rotates about).
    public func noteView(projection: CameraProjection?, settle: simd_quatf) {
        guard let projection, let c = (overlay?.mesh ?? model?.project.viewerMesh)?.bounds.center else { viewFrame = nil; return }
        viewFrame = LatticeBandChipFrame(projection: projection, modelCentre: c, modelRotation: settle)
    }

    /// A reading's screen point (the callout), or nil off screen.
    public func screenPoint(_ anchor: SIMD3<Float>) -> CGPoint? { viewFrame?.project(anchor) }

    /// The renderer's squish scale now (k × the loop's amount — the dent's and the walls').
    var currentScale: Float { loop.scale(at: loop.clock()) }

    /// H7: a surface tap while a Flexible legend is drilled in — CONSUMED (never selects a
    /// face) and read at the tap's rest point: the drilled kind first, else the first other view
    /// that has a value there (the key follows — "switching colours if needed").
    public func read(_ project: ProjectModel, mode: LatticeLegendMode, face: FaceID, point: SIMD3<Float>?) -> Bool {
        guard let kind = FlexibleReadKind(mode: mode) else { return false }
        guard let p = point else { return true }
        let order = [kind] + legendKinds.filter { $0 != kind }
        for k in order {
            if let r = surfaceReading(k, at: p) { reading = r; return true }
        }
        reading = FlexibleReading(kind: kind, value: "—", unit: kind.nothingHere, fraction: nil, anchor: p)
        return true
    }

    func surfaceReading(_ kind: FlexibleReadKind, at p: SIMD3<Float>) -> FlexibleReading? {
        switch kind {
        case .dent:
            guard let m = model, let dir = viewFrame?.viewDirection(at: p) else { return nil }
            return FlexibleProbe.dentReading(model: m, overlay: overlay, dents: shownDents, scale: currentScale,
                                             drawnLattice: drawn, point: p, dir: dir, onlyIfOnMap: !xray)
        case .stress:
            guard stress, stressDrawable, let f = stressField else { return nil }
            // ★ BATCH C VERIFICATION: with Stress on, the MAP is stress-coloured (its rest vertices
            // sampled) and drawn dented — so a tap on it is read where the drawn map meets the
            // view ray, at that point's REST place (the colour's own sample), not at the undented
            // surface under the ray
            var at = p, anchor = p
            if !heat, let m = model, let o = overlay, let dir = viewFrame?.viewDirection(at: p),
               let hit = FlexibleProbe.drawnMapHit(model: m, overlay: o, dents: shownDents, scale: currentScale,
                                                   point: p, dir: dir, onlyIfOnMap: !xray) {
                at = hit.rest; anchor = hit.point
            }
            guard let v = FlexibleProbe.stress(f, at: at) else { return nil }
            return FlexibleReading(kind: .stress, value: FlexibleProbe.mpa(v), unit: "MPa", fraction: v / stressPeak, anchor: anchor)
        case .lattice:
            return nil   // walls are read through the G-buffer probe (readLattice)
        }
    }

    /// H8: the wall probe is armed only when the lattice is being read — a tap for the dent or
    /// the stress must reach the surface (the probe claims any tap near a wall first).
    public func wantsWallProbe(_ mode: LatticeLegendMode) -> Bool {
        guard let k = FlexibleReadKind(mode: mode) else { return true }
        return k == .lattice
    }

    /// H8: a wall the probe found while a Flexible legend is drilled in — read at its rest point
    /// (never handed to the octet's setLatticeProbe).
    public func readLattice(_ project: ProjectModel, mode: LatticeLegendMode, model p: SIMD3<Float>) -> Bool {
        guard let kind = FlexibleReadKind(mode: mode) else { return false }
        guard kind == .lattice, let g = shownLattice else { return true }
        guard let r = FlexibleProbe.lattice(g.inputs, faces: g.squishFaces, squish: currentScale, at: p, fe: feShownField) else {
            reading = FlexibleReading(kind: .lattice, value: "—", unit: FlexibleReadKind.lattice.nothingHere, fraction: nil, anchor: p)
            return true
        }
        let span = latticeEnds()?.span ?? FlexibleProbe.latticeSpan(g.inputs)
        let w = span.upperBound - span.lowerBound
        reading = FlexibleReading(kind: .lattice, value: "\(Int((r.rho * 100).rounded()))%",
                                  unit: String(format: "density · %@%.1f mm cell", r.cellBlended ? "≈" : "", r.cellMM),
                                  fraction: w > 1e-6 ? min(1, max(0, (r.rho - span.lowerBound) / w)) : 0, anchor: p)
        return true
    }

    public func clearReading() { if reading != nil { reading = nil } }
}
