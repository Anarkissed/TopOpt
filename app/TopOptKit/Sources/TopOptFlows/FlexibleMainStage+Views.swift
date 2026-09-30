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

    /// The Stress button: on — and X-ray off, so the colours read on a solid part (a ghost
    /// shows them only at its silhouette); the solve starts if there is no field. Off: off.
    public func toggleStress() {
        if stress { stress = false; return }
        if xray { xray = false }
        stress = true
        requestStressIfNeeded()
    }

    /// Ask the workspace's solver (H5') — it runs only when there is no field or its inputs
    /// moved (FlexibleStressTrigger over the fingerprint) and none is running. Called by the
    /// Stress button, by Settings' Save & Exit, and — while Stress shows — by a main-page edit.
    func requestStressIfNeeded() {
        guard !stressRunning else { return }
        stressSolver?()
    }

    /// H5': what the workspace knows about its solve, handed over on each render (no publish).
    func noteStress(ready: Bool, running: Bool, solve: (() -> Void)?) {
        stressReady = ready
        stressRunning = running
        if let solve { stressSolver = solve }
    }

    // MARK: the ONE tint array (H4')

    /// H4': the part with its map quads, coloured — Heat on the map, Stress on the part (when
    /// on), the Flexible face tints, the main page's group colours where Flexible has none,
    /// X-ray's ghost on everything not opaque. Composed only when an input changed.
    public func tints(_ project: ProjectModel, on stage: WorkspaceStage, roles: [FaceID: SIMD4<Float>],
                      stress field: LatticeDemandField?) -> [Float]? {
        noteStressField(field)
        guard current(project, stage) != nil, let c = channels else { return nil }
        var h = Hasher()
        for k in roles.keys.sorted() { h.combine(k); h.combine(roles[k]!) }
        let showStress = stress && stressField != nil && stressPeak > 0
        let key = "\(generation)|\(h.finalize())|\(showStress ? stressKey : 0)|\(xray)|\(heat)|\(overlay != nil)"
        if key == composedKey { return composed }
        composedKey = key
        composed = FlexibleMainTints.compose(base: c.tints, overlay: overlay, part: project.viewerMesh, heat: heat,
                                             roles: roles, stress: showStress ? (stressField!, stressPeak) : nil,
                                             ghost: xray ? FlexibleColours.ghost : nil)
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
                                                    chipColumnWidth: chipColumnWidth, simulating: stress && stressRunning)
        return FlexibleMainLegendLayout.place(legendKinds, minimized: minimized, viewport: viewport, keepOut: keep,
                                              priority: legendPriority)
    }

    /// The dent legend's "×k" (the map is drawn k times deeper).
    public var dentExaggeration: Int { Int(channels?.exaggeration ?? 1) }
    /// The dent legend's (i): what the map is ("What you drew", "What the lattice was built
    /// from") and why it looks deeper than it is.
    public var dentInfo: String {
        let line = channels?.legendLine ?? ""
        return (line.isEmpty ? "" : line + ": ") + "drawn \(dentExaggeration)× deeper so it reads. Tap here, then the part: the true mm at that spot."
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
            return FlexibleProbe.dentReading(model: m, overlay: overlay, dents: channels?.dents, scale: currentScale,
                                             drawnLattice: drawn, point: p, dir: dir, onlyIfOnMap: !xray)
        case .stress:
            guard stress, let f = stressField, stressPeak > 0, let v = FlexibleProbe.stress(f, at: p) else { return nil }
            return FlexibleReading(kind: .stress, value: String(format: "%.2f", v), unit: "MPa", fraction: v / stressPeak, anchor: p)
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
        guard kind == .lattice, let g = model?.lattice else { return true }
        guard let r = FlexibleProbe.lattice(g.inputs, faces: g.faces, squish: currentScale, at: p) else {
            reading = FlexibleReading(kind: .lattice, value: "—", unit: FlexibleReadKind.lattice.nothingHere, fraction: nil, anchor: p)
            return true
        }
        let span = FlexibleProbe.latticeSpan(g.inputs)
        let w = span.upperBound - span.lowerBound
        reading = FlexibleReading(kind: .lattice, value: "\(Int((r.rho * 100).rounded()))%",
                                  unit: String(format: "density · %.1f mm cell", r.cellMM),
                                  fraction: w > 1e-6 ? min(1, max(0, (r.rho - span.lowerBound) / w)) : 0, anchor: p)
        return true
    }

    public func clearReading() { if reading != nil { reading = nil } }
}
