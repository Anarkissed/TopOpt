// LatticeLayoutPreview — the NEW ENGINE's preview on Lattice Setup (the lattice rebuild, stage E; his blitz of 2026-11-12, the
// reviewer's go 20:21Z). Behind App settings' "New engine (test)", DEFAULT OFF: off, nothing here runs and the page is today's.
// On, the page draws core's lattice_layout bars (LatticeLayoutBarsPass) in place of the old engine's march:
//   * one LatticeLayoutSession per part (opened once; core keeps what a change does not touch, rule P2);
//   * the page's own settings, read where its rows read them (`settings(_:)`): each face row of each lattice group is ONE
//     region (Lattice or No lattice, its depth and its Expand), a group set as a Protect skin is a skin over its faces, Finish
//     Rim / Skin / Covered, Grade to shape, the type, the cell and the strut width; two-line struts always (the reviewer's
//     ruling 11-12);
//   * latest wins: a setting moved while a layout runs stops that layout (core's stop flag) and lays the new one.
// What it says, in one plain line each: why there is nothing to draw, and that bars are drawn round where the print file
// squares flat-bridge undersides and adds posts (PREVIEW IS THE SPEC — until the drawer shows them).
import Foundation
import SwiftUI
import simd
import TopOptKit
import TopOptDesign

@MainActor
public final class LatticeLayoutPreview: ObservableObject {

    /// What the 3D view draws (nil: nothing yet).
    @Published public private(set) var bars: LatticeLayoutBarsInputs?
    /// ★ Install 3: what the layout on screen laid (bars and cells), for the colour key, the tap-to-read card and the drawer.
    @Published public private(set) var laid: LatticeLayoutColours.Laid?
    /// One plain line under the preview: what is wrong, or nil.
    @Published public private(set) var problem: String?
    /// Core's numbers for the debug overlay (stage E's iPad timing): open, read, cells, bars, ms.
    @Published public private(set) var timing: Timing?
    @Published public private(set) var laying = false
    /// One plain line: what these settings ask that the new engine does not do yet (nil: nothing).
    @Published public private(set) var notes: [String] = []
    /// ★ his rule 11-14: "recommend changing to a 0.2mm nozzle" when lattice cannot go where asked — one line, or nil.
    @Published public private(set) var nozzleLine: String?
    /// ★ his ruling 11-14: where asked-for lattice came out solid, why (one line) and one to three fixes he can take.
    @Published public private(set) var solidReason: SolidReason?
    /// ★ his pick 11-16 (5): the 0.2 mm nozzle check is a second full layout, so it runs only when asked — on Refresh, or his
    /// tap on "Check a 0.2 mm nozzle". `.notAsked` for the layout on screen, `.checking`, or `.done` (its line, or none).
    public enum NozzleState: Equatable { case notAsked, checking, done }
    @Published public private(set) var nozzleState: NozzleState = .notAsked
    /// How many nozzle checks ran (a test's count: none may run after a layout nobody asked to check).
    public static private(set) var nozzleChecksRun = 0

    public struct Timing: Equatable, Sendable {
        public var openMS: Double
        public var readMS: Double
        public var cellsMS: Double
        public var barsMS: Double
        public var bars: Int
        public var mapMS: Double = 0   // the solid view's map (0: X-ray, or not yet)
        public var line: String {
            String(format: "New engine · open %.0f · read %.0f · cells %.0f · bars %.0f ms · %d bars", openMS, readMS, cellsMS, barsMS, bars)
                + (mapMS > 0 ? String(format: " · solid %.0f ms", mapMS) : "")
        }
    }

    /// The line the preview carries while the drawer draws every bar round (the reviewer's PREVIEW IS THE SPEC).
    public static let roundBarsLine = "Preview: flat bridges drawn square, as printed · the print adds a few posts"
    public static let noPartLine = "New engine: this part has no model file to read"
    public static let organicLine = "New engine: Organic is not drawn yet · this is the old preview"
    public static let byStressLine = "New engine: no stress result yet · run the stress check to grade by stress"
    public static let perAreaLine = "New engine: one cell range, grade style and band for the whole part, not per area yet"

    /// The new engine draws the strut types' Uniform, Default Grade and Stepped; Organic keeps the old preview (LatticeReview 11-13).
    public static func draws(_ l: LatticeSettings) -> Bool { l.resolvedAlgorithm != "organic" }
    /// One plain line each for what the new engine leaves out for these settings.
    public static func notes(_ l: LatticeSettings, hasStress: Bool = false) -> [String] {
        var out: [String] = []
        if needsStress(l), !hasStress { out.append(byStressLine) }
        return out
    }
    public static func note(_ l: LatticeSettings) -> String? { notes(l).first }

    /// ★ Install 2: the stress result the page grades by (the stage's quick solve, or a run's variant), its identity (the
    /// page's latticeStressFieldKey: one hash, never a scan per frame) and the Structural reference. Equal when the key and
    /// the reference are.
    public struct Stress: Equatable {
        public var key: Int
        public var field: LatticeDemandField?
        public var referenceMPa: Double
        public init(key: Int = 0, field: LatticeDemandField? = nil, referenceMPa: Double = 0) {
            self.key = key; self.field = field; self.referenceMPa = referenceMPa
        }
        public static func == (a: Stress, b: Stress) -> Bool { a.key == b.key && a.referenceMPa == b.referenceMPa }
    }

    /// Whether these settings grade by stress at all (By stress struts, or cell size by stress).
    public static func needsStress(_ l: LatticeSettings) -> Bool {
        let s = settings(l)
        return s.byStress || s.cellsByStress
    }
    /// The stress half of the settings, read off the lattice settings alone.
    static func settings(_ l: LatticeSettings) -> (byStress: Bool, cellsByStress: Bool) {
        let follows = l.simulateStresses && l.gradingMode != .none && l.gradingMode.followsStress
        return (follows && l.densityMode == .sim, follows && l.cellSizeMode != .fixed)
    }
    /// The body while the new engine draws: see-through, so the bars inside it show (the Flexible pass's ghost rules apply).
    public static let ghostAlpha: Float = 0.2

    private var session: LatticeLayoutSession?
    private var sessionPath: String?
    private var openMS = 0.0
    private var lastSettings: LatticeLayoutSession.Settings?
    private var token = 0
    private var task: Task<Void, Never>?
    /// ★ THE SOLID VIEW (his ask 11-13): X-ray off draws the part solid, cut open where the lattice is (the engine's map).
    private var solidWanted = false
    private var box: (lo: SIMD3<Float>, hi: SIMD3<Float>)?
    private var mapTask: Task<Void, Never>?
    private var nozzleSession: LatticeLayoutSession?
    private var latticeAtLay = LatticeSettings()
    private var nozzlePath: String?
    private var stress = Stress()
    private var sessionStressKey: Int?   // the field the session holds (setDemand), by its key
    private var nozzleStressKey: Int?

    public init() {}

    /// ★ his pick 11-16 (2): whether the layout on screen is the one these inputs ask for (Click to refresh marks the preview
    /// out of date when not). True with nothing laid yet only when there is nothing to lay.
    public func isCurrent(project p: ProjectModel, stress: Stress = Stress()) -> Bool {
        guard let path = p.importedFile?.path else { return bars == nil }
        return path == sessionPath && Self.settings(p, referenceMPa: stress.referenceMPa) == lastSettings && stress.key == self.stress.key
    }

    /// The page's one call, on every change of the part or its lattice settings (cheap when nothing changed).
    /// ★ his picks 11-16: `delay` — Live preview lays half a second after the last change (a newer change cancels the wait);
    /// `checkNozzle` — Refresh also runs the 0.2 mm nozzle check after the layout.
    public func update(project p: ProjectModel, on: Bool, solid: Bool = false, stress: Stress = Stress(),
                       delay: Duration = .zero, checkNozzle: Bool = false) {
        guard on else { clear(); return }
        guard let path = p.importedFile?.path else { problem = Self.noPartLine; bars = nil; return }
        if path != sessionPath || box == nil { box = Self.box(p.importedMesh?.vertices ?? []) }
        let solidChanged = solid != solidWanted
        solidWanted = solid
        notes = Self.notes(p.lattice, hasStress: stress.field != nil)
        let s = Self.settings(p, referenceMPa: stress.referenceMPa)
        let stressMoved = stress.key != self.stress.key
        self.stress = stress
        if path == sessionPath, s == lastSettings, !stressMoved, task != nil || bars != nil {
            if solidChanged, task == nil || bars != nil { solidToggled() }
            if checkNozzle, nozzleState == .notAsked, bars != nil { self.checkNozzle() }   // Refresh with nothing changed
            return
        }
        lastSettings = s
        latticeAtLay = p.lattice
        task?.cancel()
        laying = true
        nozzleWanted = checkNozzle
        task = Task { [weak self] in
            if delay > .zero {   // ★ Live preview: wait for him to stop changing it
                try? await Task.sleep(for: delay)
                if Task.isCancelled { return }
            }
            await self?.lay(path: path, s)
        }
    }

    /// ★ his pick 11-16 (5): the 0.2 mm nozzle check for the layout on screen, on his tap (or Refresh).
    public func checkNozzle() {
        guard let path = sessionPath, let s = lastSettings, bars != nil, !laying else { nozzleWanted = true; return }   // after the lay
        nozzleTask?.cancel()
        let lattice = latticeAtLay
        nozzleTask = Task { [weak self] in await self?.nozzleCheck(path: path, s, lattice: lattice) }
    }
    private var nozzleWanted = false
    private var nozzleTask: Task<Void, Never>?

    /// Off: the session closed, nothing drawn.
    public func clear() {
        task?.cancel(); task = nil
        mapTask?.cancel(); mapTask = nil
        nozzleTask?.cancel(); nozzleTask = nil; nozzleWanted = false; nozzleState = .notAsked
        nozzleSession?.close(); nozzleSession = nil; nozzlePath = nil; nozzleLine = nil; solidReason = nil
        session?.close(); session = nil; sessionPath = nil; lastSettings = nil; sessionStressKey = nil; nozzleStressKey = nil
        bars = nil; laid = nil; problem = nil; timing = nil; laying = false
    }

    // MARK: ★ Install 3 — the old preview's colour key on the new engine's bars

    private var lookupCache: (token: Int, lookup: LatticeLayoutColours.CellLookup)?
    private var drawnCache: (key: [Int], bars: LatticeLayoutBarsInputs)?

    /// Which laid cell holds a point (the tap-to-read card, the drawer), for the layout on screen.
    public func cellLookup() -> LatticeLayoutColours.CellLookup? {
        guard let laid else { return nil }
        if let c = lookupCache, c.token == laid.token { return c.lookup }
        let l = LatticeLayoutColours.CellLookup(laid)
        lookupCache = (laid.token, l)
        return l
    }

    /// The bars to draw, wearing the old preview's key (LatticeLayoutColours): by what each bar is and how much material it
    /// holds, or by the stress (`stress`, the stress view with the lattice; `stressKey` names it). Worked out once per layout
    /// and colouring.
    public func drawn(stressField field: LatticeDemandField?, stressKey: Int) -> LatticeLayoutBarsInputs? {
        guard var b = bars else { return nil }
        guard let laid, laid.token == b.token else { return b }
        let grade = latticeAtLay.gradingMode.fitsShape
        let key = [b.token, field == nil ? 0 : stressKey, grade ? 1 : 0, latticeAtLay.topologyID.hashValue,
                   LatticeLayoutColours.controlOneColour ? 1 : 0, b.solid?.token ?? -1, b.hidden ? 1 : 0]
        if let c = drawnCache, c.key == key { return c.bars }
        b.colours = LatticeLayoutColours.colours(laid, type: latticeAtLay.lattice, grade: grade,
                                                 stress: field.map(LatticeLayoutColours.Stress.init(field:)),
                                                 lookup: grade ? cellLookup() : nil)
        var h = Hasher()
        key.forEach { h.combine($0) }
        b.colourKey = h.finalize()
        drawnCache = (key, b)
        return b
    }

    /// Layouts started, app-wide (a hosted test's count: Click to refresh lays none on a change; Live one per pause).
    public static private(set) var laysStarted = 0

    private func lay(path: String, _ s: LatticeLayoutSession.Settings) async {
        Self.laysStarted += 1
        do {
            if session == nil || sessionPath != path {
                session?.close()
                let opened = try await LatticeLayoutSession.open(path: path)
                guard !Task.isCancelled else { return }
                session = opened; sessionPath = path; openMS = opened.info.msOpen; sessionStressKey = nil
            }
            guard let session else { return }
            sessionStressKey = try await Self.give(stress, to: session, holding: sessionStressKey)
            let r = try await session.lay(s)
            guard !Task.isCancelled else { return }
            token &+= 1
            // the last map stays until this layout's own lands (no flash of a closed part on every change)
            bars = LatticeLayoutBarsInputs(token: token, bars: r.bars, solid: solidWanted ? bars?.solid : nil, flags: r.barFlags)
            laid = LatticeLayoutColours.Laid(r, token: token)   // ★ Install 3
            timing = Timing(openMS: openMS, readMS: r.msRead, cellsMS: r.msCells, barsMS: r.msBars, bars: r.barCount)
            problem = r.barCount == 0 ? "New engine: no lattice fits these settings" : nil
            laying = false
            if solidWanted { await addMap() }
            nozzleTask?.cancel(); nozzleLine = nil; nozzleState = .notAsked
            await solidReasonCheck(lattice: latticeAtLay)   // ★ his ruling 11-14: why it is solid (one coarse map, cheap)
            // ★ his pick 11-16 (5): the nozzle check is a second full layout — only when asked (Refresh, or his tap)
            if LatticePreviewMode.nozzleAfterLay(asked: nozzleWanted), !Task.isCancelled {
                nozzleWanted = false
                await nozzleCheck(path: path, s, lattice: latticeAtLay)
            }
        } catch is CancellationError {
            // a newer setting is laying
        } catch {
            problem = FlexibleRowCopy.fit("New engine: \(error)", 60)
            bars = nil
            laying = false
        }
    }

    /// The stress result into a session once per field (core keeps the part's own reference by its pointer).
    static func give(_ stress: Stress, to session: LatticeLayoutSession, holding key: Int?) async throws -> Int? {
        guard key != stress.key else { return key }
        if let f = stress.field {
            try await session.setDemand(mpa: f.vonMises, nx: f.nx, ny: f.ny, nz: f.nz, origin: f.origin, spacingMM: f.spacingMM)
        } else {
            try await session.setDemand(mpa: nil, nx: 0, ny: 0, nz: 0, origin: .zero, spacingMM: 0)
        }
        return stress.key
    }

    // MARK: his 0.2 mm nozzle line (11-14)

    /// A 0.2 mm nozzle's line width; only the line width changes (Min and Max cell stay his; two lines still).
    public static let fineBeadMM = 0.22
    /// Below this share of asked-for lattice left solid, nothing is said; below this cure, nothing either (LatticeReview).
    static let worthLooking = 0.05, worthSaying = 0.2

    /// Asked-for lattice no cell holds, as a share of all asked-for lattice, from the engine's own map (a coarse one).
    static func unheldShare(_ s: LatticeLayoutSession, _ box: (lo: SIMD3<Float>, hi: SIMD3<Float>)) async throws -> Double? {
        try await unheldReport(s, box)?.share
    }

    /// The same, with the unheld voxels by core's reason (NoCell: Other, WallNarrow, TooFewAcross, Sliver, RegionShallow).
    static func unheldReport(_ s: LatticeLayoutSession, _ box: (lo: SIMD3<Float>, hi: SIMD3<Float>)) async throws
        -> (share: Double, nocell: [Int])? {
        let ext = simd_max(box.hi - box.lo, SIMD3(repeating: 0.1))
        let voxel = Swift.max(0.6, Float(cbrt(Double(ext.x * ext.y * ext.z) / 250_000)))
        let dims = SIMD3<Int32>(Int32((ext.x / voxel).rounded(.up)) + 3, Int32((ext.y / voxel).rounded(.up)) + 3,
                                Int32((ext.z / voxel).rounded(.up)) + 3)
        let r = try await s.grid(origin: box.lo - SIMD3(repeating: voxel), voxel: voxel, dims: dims)
        return r.asked > 0 ? (Double(r.unheld) / Double(r.asked), r.nocell) : nil
    }

    /// How much of what is solid now a 0.2 mm nozzle would lattice (0 … 1), laying `settings` again in `fine` with only the line
    /// width changed; nil when there is too little left solid to ask.
    static func cure(main: LatticeLayoutSession, fine: LatticeLayoutSession, settings: LatticeLayoutSession.Settings,
                     box: (lo: SIMD3<Float>, hi: SIMD3<Float>)) async throws -> Double? {
        guard settings.beadMM > fineBeadMM + 0.05, let now = try await unheldShare(main, box), now >= worthLooking else { return nil }
        var s = settings
        s.beadMM = fineBeadMM
        _ = try await fine.lay(s)
        let then = try await unheldShare(fine, box) ?? now
        return Swift.max(0, (now - then) / now)
    }

    /// ★ his ruling 11-14: why asked-for lattice is solid, and the fixes (after every layout: one coarse map).
    private func solidReasonCheck(lattice: LatticeSettings) async {
        guard let session, let box, !Task.isCancelled else { return }
        if let rep = try? await Self.unheldReport(session, box), !Task.isCancelled {
            solidReason = SolidReason.of(share: rep.share, nocell: rep.nocell, lattice: lattice)
        } else {
            solidReason = nil
        }
    }

    /// His 0.2 mm nozzle line: the same settings laid again with only the line width changed (a second full layout) —
    /// ★ 11-16: only when asked.
    private func nozzleCheck(path: String, _ s: LatticeLayoutSession.Settings, lattice: LatticeSettings) async {
        nozzleLine = nil
        guard let session, let box, !Task.isCancelled else { return }
        nozzleState = .checking
        Self.nozzleChecksRun += 1
        defer { if !Task.isCancelled { nozzleState = .done } }
        do {
            if nozzleSession == nil || nozzlePath != path {
                nozzleSession?.close()
                nozzleSession = try await LatticeLayoutSession.open(path: path)
                nozzlePath = path
            }
            guard let fine = nozzleSession, !Task.isCancelled else { return }
            guard let c = try await Self.cure(main: session, fine: fine, settings: s, box: box), !Task.isCancelled else { return }
            if c >= Self.worthSaying {
                nozzleLine = String(format: "A 0.2 mm nozzle would lattice %.0f%% of what is solid now", 100 * c)
            }
        } catch {
            // no line: the preview stands as it is
        }
    }

    // MARK: the solid view's map

    /// X-ray was switched: off asks for the map (once per layout), on drops it.
    private func solidToggled() {
        guard var b = bars else { return }
        if !solidWanted { b.solid = nil; bars = b; timing?.mapMS = 0; return }
        mapTask?.cancel()   // never the layout's own task: a layout in flight maps itself when it lands
        mapTask = Task { [weak self] in await self?.addMap() }
    }

    private func addMap() async {
        guard let session, let box, let b = bars, b.solid?.token != b.token else { return }
        do {
            let m = try await Self.map(session, box, token: b.token)
            guard !Task.isCancelled, solidWanted, var now = bars, now.token == b.token else { return }
            now.solid = m.grid
            bars = now
            timing?.mapMS = m.ms
        } catch {
            // the bars stay; the body stays whole where the map could not be read
        }
    }

    /// The part's box, from the imported mesh (x y z per vertex).
    static func box(_ v: [Float]) -> (lo: SIMD3<Float>, hi: SIMD3<Float>)? {
        guard v.count >= 3 else { return nil }
        var lo = SIMD3<Float>(repeating: .greatestFiniteMagnitude), hi = -lo
        for i in stride(from: 0, to: v.count - 2, by: 3) {
            let p = SIMD3(v[i], v[i + 1], v[i + 2])
            lo = simd_min(lo, p); hi = simd_max(hi, p)
        }
        return (lo, hi)
    }

    /// The engine's map over the part's box with a voxel of air all round: about a million voxels at most, never finer than
    /// 0.35 mm.
    static func map(_ s: LatticeLayoutSession, _ box: (lo: SIMD3<Float>, hi: SIMD3<Float>), token: Int) async throws
        -> (grid: LatticeLayoutSolidGrid, ms: Double) {
        let ext = simd_max(box.hi - box.lo, SIMD3(repeating: 0.1))
        let voxel = Swift.max(0.35, Float(cbrt(Double(ext.x * ext.y * ext.z) / 1_000_000)))
        let dims = SIMD3<Int32>(Int32((ext.x / voxel).rounded(.up)) + 3, Int32((ext.y / voxel).rounded(.up)) + 3,
                                Int32((ext.z / voxel).rounded(.up)) + 3)
        let origin = box.lo - SIMD3(repeating: voxel)
        let r = try await s.grid(origin: origin, voxel: voxel, dims: dims)
        return (LatticeLayoutSolidGrid(token: token, origin: origin, voxel: voxel, dims: dims, rg: r.rg), r.ms)
    }

    // MARK: the page's settings, as core reads them

    /// Protect skins of one depth as one skin, in the order their depths first appear; each face once.
    static func mergedByDepth(_ skins: [LatticeLayoutSession.Protect]) -> [LatticeLayoutSession.Protect] {
        var order: [Double] = []
        var byDepth: [Double: LatticeLayoutSession.Protect] = [:]
        for g in skins {
            if var m = byDepth[g.depthMM] {
                if m.pieces.isEmpty && g.pieces.isEmpty {
                    for f in g.faces where !m.faces.contains(f) { m.faces.append(f) }
                } else {
                    // ★ D22: one skin holding cut pieces takes the others as pieces too (a whole face = a piece with no cuts)
                    m.pieces = Self.asPieces(m) + Self.asPieces(g)
                    for f in g.faces where !m.faces.contains(f) { m.faces.append(f) }
                }
                byDepth[g.depthMM] = m
            } else {
                byDepth[g.depthMM] = g
                order.append(g.depthMM)
            }
        }
        return order.compactMap { byDepth[$0] }
    }

    /// ★ Install 2 (C23, R19, S13): an area's own tab (LatticeSettings.areaGrading) as the region's own settings — its grade,
    /// band, Strength and Finish; what it leaves unset is the part's. A Lattice region only (core reads no own for No lattice).
    static func areaOwn(_ l: LatticeSettings, group: UUID, into r: inout LatticeLayoutSession.Region, coverMM: Double = -1) {
        guard let a = l.areaGrading[group], !a.isEmpty else { return }
        var o = LatticeLayoutSession.AreaOwn()
        if let m = a.gradingMode {
            if m == .none {
                // his 08-25 "No grade — one cell, one density", for this area
                o.algorithm = "uniform"; o.gradeToShape = false; o.byStress = false; o.cellsByStress = false
            } else {
                o.gradeToShape = m.fitsShape && ["stepped", "doubled"].contains(l.resolvedAlgorithm)
                let follows = l.simulateStresses && m.followsStress
                o.byStress = follows && l.densityMode == .sim
                o.cellsByStress = follows && l.cellSizeMode != .fixed
            }
        }
        if let b = a.shapeFitBandMM { o.bandMM = Swift.max(0, b) }
        if let st = a.shapeGradeStrength { o.strength = Swift.min(1, Swift.max(-1, st)) }
        // ★ Install 2: this area's Manual controls 1, 2, 4, 5
        if let lo = a.strutFromMM, let hi = a.strutToMM, lo > 0, hi >= lo { o.widthLightMM = lo; o.widthHeavyMM = hi }
        if let n = a.cellsAcrossMin, n >= 1 { o.minCellsAcross = Int32(n) }
        if let k = a.neverSkipCellSize { o.maxStep = k ? 2 : 0 }
        if let g = a.response { o.response = Swift.min(4, Swift.max(0.25, g)) }
        if let t = a.stressTargetMPa, t > 0 { o.referenceMPa = t }
        r.own = o
        // a zone's Finish (release (4)'s four), as the region's own: what the page shows is what goes
        var f = LatticeLayoutSession.RegionFinish()
        var own: LatticeAreaGrading.ZoneFinish?
        let partOuter = l.boundary.zoneFinishWord
        if a.outerFinish != nil || a.skin != nil, partOuter != nil || l.boundary == .fullSkin {
            let z = a.zoneFinish(partOuter: partOuter, partSkin: l.boundary.jobSkinValue)
            own = z
            switch z {
            case .none: f.rimMM = 0; f.coverMM = 0; f.skin = false
            case .rim: f.rimMM = -1; f.coverMM = 0; f.skin = false
            case .skin: f.rimMM = 0; f.coverMM = 0; f.skin = true
            case .covered: f.rimMM = 0; f.coverMM = coverMM; f.skin = false   // at the printer's wall, as the part's
            }
        }
        // ★ Install 2, controls 7 and 8: the rim's width and the skin's bars where this area runs Rim or Skin (its own Finish,
        // else the part's); on its own Finish the part's numbers go with it
        let runs = own ?? LatticeManualControl.partFinish(l)
        if runs == .rim, let w = a.rimWidthMM ?? (own == .rim ? l.rimWidthMM : nil), w > 0 { f.rimMM = Swift.max(0.1, w) }
        if runs == .skin {
            if let w = a.skinBarWidthMM ?? (own == .skin ? l.skinBarWidthMM : nil), w > 0 { f.skinWidthMM = w }
            if let k = a.skinReachCells ?? (own == .skin ? l.skinReachCells : nil), k > 0 { f.skinReachCells = k }
        }
        if f.any { r.finish = f }
    }

    /// ★ Install 2 (D21): a Lattice zone's shape for core — a Box about its middle, its axes the depth planes' own (as its
    /// handles draw it), its half sizes width, depth and height over two; a Cylinder about its centre along its axis.
    static func zone(_ p: ProjectModel, group: UUID, primitive pid: UUID) -> LatticeLayoutSession.Zone? {
        guard let prim = p.latticeZonePrimitive(group), prim.id == pid, let size = p.latticeZoneSize(group) else { return nil }
        let up = simd_normalize(ManualPrimitive.unit(prim.axis))
        let (uf, _) = corePlaneBasis(normal: SIMD3<Float>(up))
        var u = SIMD3<Double>(uf)
        u = simd_normalize(u - up * simd_dot(u, up))
        let v = simd_normalize(simd_cross(up, u))
        if prim.kind == .bolt {
            return .init(kind: .cylinder, centre: prim.center, axes: [u, v, up],
                         half: SIMD3(size.width / 2, size.width / 2, size.height / 2))
        }
        return .init(kind: .box, centre: p.latticeZoneMiddle(prim), axes: [u, v, up],
                     half: SIMD3(size.width / 2, size.depth / 2, size.height / 2))
    }

    /// A skin's surface as pieces: its own pieces, or its faces as one piece with no cut.
    static func asPieces(_ s: LatticeLayoutSession.Protect) -> [LatticeLayoutSession.Piece] {
        s.pieces.isEmpty ? (s.faces.isEmpty ? [] : [.init(faces: s.faces, cuts: [])]) : s.pieces
    }

    /// ★ HIS ASK 11-14: "ALL modifications done in cut faces is respected without question." An Edit faces piece goes to the
    /// new engine as itself (core's FacePiece, rule D22): each leaf of the region (a union resolves to its leaves) with its
    /// faces and the WHOLE chain of cuts that made it. A region no cut made (a face, or a union of whole faces) gives none,
    /// so it goes as its faces, as before.
    static func pieces(_ p: ProjectModel, region rid: RegionID) -> [LatticeLayoutSession.Piece] {
        guard let mesh = p.viewerMesh else { return [] }
        let leaves = p.faceRegions.resolvedLeaves(rid).compactMap { p.faceRegions.region($0) }
        guard leaves.contains(where: { !$0.cuts.isEmpty }) else { return [] }
        return leaves.compactMap { r in
            let faces = FaceRegionGeometry.members(of: r, in: mesh).sorted().map { Int32($0) }
            guard !faces.isEmpty else { return nil }
            return .init(faces: faces, cuts: r.cuts.map { .init(point: $0.point, normal: $0.normal, strict: $0.strict) })
        }
    }

    /// Lattice Setup's settings for core's lattice_layout (read where its rows read them).
    public static func settings(_ p: ProjectModel, referenceMPa: Double = 0) -> LatticeLayoutSession.Settings {
        var s = LatticeLayoutSession.Settings()
        let l = p.lattice
        let bead = p.printParams.strutLineWidthMM
        s.beadMM = bead > 0 ? bead : 0.45
        s.minStrutLines = 2   // ★ the reviewer's ruling 11-12: one line does not print on his 0.4 mm nozzle
        s.topology = l.topologyID.isEmpty ? "octet" : l.topologyID
        // ★ "Grade the lattice" off (his 08-25: "No grade — one cell, one density"): core's uniform
        let graded = l.gradingMode != .none
        // ★ Install 2 (the reviewer 10-08): Stepped is Aesthetic only — the page blocks it in Structural, and a stored one goes
        // as Default Grade there
        let stepped = l.resolvedAlgorithm == "stepped" && (l.stageMode ?? .structural) == .aesthetic
        s.algorithm = !graded ? "uniform" : stepped ? "stepped" : "default_grade"
        // ★ 11-13: the cell window the page RESOLVES, as the old engine's job reads it (Auto: the floor to the type's ceiling;
        // Swept: the typed window, never under the floor) — never the stored numbers a mode does not show
        let bounds = LatticeBounds.compute(settings: l, limits: TopOptKit.latticeLimits(topology: l.topologyID),
                                           lineWidthMM: s.beadMM)
        let plan = l.resolvedCellPlan(bounds: bounds, minimizePlastic: false)
        s.cellMM = l.cellSizeMode == .fixed ? l.cellMM : 0
        s.cellMinMM = Swift.max(0, plan.loMM)
        s.cellMaxMM = plan.hiMM > 0 ? plan.hiMM : (l.cellMaxMM > 0 ? l.cellMaxMM : 8)
        switch l.boundary {
        case .rim: s.rimMM = l.rimWidthMM.map { Swift.max(0.1, $0) } ?? -1   // Finish Rim: two line widths, or his (control 8)
        case .fullSkin: s.skin = true     // Finish Skin (S3): bars across the face joining the cut strut ends (his pick 11-12:
                                          // this went as Covered)
            if let w = l.skinBarWidthMM, w > 0 { s.skinWidthMM = w }        // ★ control 7: the skin's bars
            if let k = l.skinReachCells, k > 0 { s.skinReachCells = k }
        case .covered:                    // Finish Covered (S9): a solid shell over the lattice — ★ Install 2: at the printer's
                                          // own wall (his 08-19 caption, faceSkinMM); two line widths with none set
            let ring = p.printParams.wallRingMM
            s.coverMM = ring > 0 ? ring : -1
        default: break
        }
        // ★ Install 2 (his 09-18: single-cell members lock the Finish to Skin; jobSkinResolved): a one-cell member's struts are
        // tied by the skin, whatever None or Rim the page holds
        if l.singleCellMembers, l.boundary == .none || l.boundary == .rim { s.skin = true }
        // Grade to shape: the grading mode's shape fit, its band and its Strength, as the old engine's job sends them (Stepped and
        // Doubled only)
        if graded, l.gradingMode.fitsShape, ["stepped", "doubled"].contains(l.resolvedAlgorithm) {
            s.gradeToShape = true
            s.bandMM = Swift.max(0, l.shapeFitBandMM)
            s.strength = l.shapeFitGradeStrength
        }
        // ★ Install 2: by stress (his 08-17 permission, the 08-25 grades; LatticeReview's Install 2 engine)
        let stressHalf = Self.settings(l)
        s.byStress = stressHalf.byStress
        s.cellsByStress = stressHalf.cellsByStress
        if s.byStress || s.cellsByStress {
            s.response = Swift.min(4, Swift.max(0.25, l.demandExponent))
            s.percentile = 0.95
            // Structural: the printed yield over his Safety margin (his 11-14 carry-over); Aesthetic: the part's own
            s.referenceMPa = (l.stageMode ?? .structural) == .structural ? Swift.max(0, referenceMPa) : 0
            if let t = l.stressTargetMPa, t > 0 { s.referenceMPa = t }   // ★ control 5: his target stress
        }
        if s.byStress {
            // Grade to (light) and Grade from (heavy), on the dial the page's densities use (R10, the largest cell)
            func dial(_ rho: Double, _ fallback: Double) -> Double {
                guard rho > 0 else { return fallback }
                let pct = p.latticeDensityPercent(rho: rho, cellMM: s.cellMaxMM) ?? rho * 100
                return Swift.min(1, Swift.max(0.01, pct / 100))
            }
            s.dialLight = dial(l.minRelativeDensity, 0.01)
            s.dialHeavy = dial(l.maxRelativeDensity, 1)
            // ★ control 1: the two ends typed in mm
            if let a = l.strutFromMM, let b = l.strutToMM, a > 0, b >= a { s.widthLightMM = a; s.widthHeavyMM = b }
        }
        // ★ a typed Thickness only with the simulation off (his 08-19), and never under By stress
        if !l.simulateStresses, !s.byStress, let t = l.manualStrutThicknessMM, t > 0 { s.strutWidthMM = t }
        s.allowQuilt = l.allowQuilt
        s.smallCellsInThinWalls = l.smallCellsInThinWalls   // ★ his per-part choice (11-13)
        // ★ cells across a wall (C3-C5): Structural five; Aesthetic one with "Allow single-cell members", else two
        let aesthetic = (l.stageMode ?? .structural) == .aesthetic
        s.minCellsAcross = aesthetic ? (l.singleCellMembers ? 1 : 2) : 5
        if let n = l.cellsAcrossMin, n >= 1 { s.minCellsAcross = Int32(n) }   // ★ control 2: his minimum
        if l.neverSkipCellSize, s.algorithm == "default_grade" { s.maxStep = 2 }   // ★ control 4 (Default Grade only)
        s.oneGrid = aesthetic && l.letWallsCutCells   // ★ his 11-14: Aesthetic only; Structural always sends false
        // ★ density (R10): core's dial is the percent he sees / 100 (0.01 thinnest ... 1 widest); a typed strut width wins
        // ★ Install 2: the rows' densities only in Per region (the proposal: "Shown only in this mode, sent only in this mode")
        let rowDensity = l.densityMode == .perRegion && !s.byStress
        s.perRegion = rowDensity
        var id: Int32 = 1
        var uniformSet = false
        let ring = p.printParams.wallRingMM, cover = ring > 0 ? ring : -1   // Covered's shell: the printer's own wall
        for g in p.latticeGroups {
            // ★ a Protect skin group is a solid face at its rows' depth (D5), never a No lattice region (11-13: it went as both)
            let skinGroup = l.skinGroups.contains(g.id)
            for ref in p.latticeSelectableRefs(g) {
                let role = p.latticeSelectableRole(ref, in: g.id)
                guard skinGroup || role != nil else { continue }
                let faces: [Int32]
                var pieces: [LatticeLayoutSession.Piece] = []
                switch ref {
                case let .face(_, f):
                    faces = [Int32(f)]
                case let .region(_, rid):
                    faces = p.surfaceResolvedFaces(rid).map { Int32($0) }
                    pieces = Self.pieces(p, region: rid)   // ★ his 11-14: a cut piece is itself, never its whole face (D22)
                case let .primitive(pid):
                    // ★ Install 2 (D21): a Lattice zone is a shape — a Box or a Cylinder of its own, no face
                    guard !skinGroup, l.zoneGroups.contains(g.id), let z = Self.zone(p, group: g.id, primitive: pid) else { continue }
                    var r = LatticeLayoutSession.Region(id: id, noLattice: role == .exclude, faces: [], depthMM: 0,
                                                        expandMM: p.latticeExpandMM(ref))
                    r.zone = z
                    if role != .exclude { Self.areaOwn(l, group: g.id, into: &r, coverMM: cover) }
                    s.regions.append(r)
                    id += 1
                    continue
                }
                guard !faces.isEmpty else { continue }
                let depth = p.latticeSlabDepthMM(ref, in: g.id)   // the face row's own number (FlexibleSelectionsList's)
                if skinGroup {
                    s.protect.append(.init(id: id, faces: faces, depthMM: depth, pieces: pieces))
                } else {
                    var r = LatticeLayoutSession.Region(id: id, noLattice: role == .exclude, faces: faces, depthMM: depth,
                                                        expandMM: p.latticeExpandMM(ref), pieces: pieces)
                    if role != .exclude { Self.areaOwn(l, group: g.id, into: &r, coverMM: cover) }   // ★ Install 2: the area's own tab
                    s.regions.append(r)
                    if role != .exclude, l.densityMode != .sim, let rho = p.latticeSelectableDensity(ref, in: g.id),
                       let pct = [l.cellSizeMode == .fixed && l.cellMM > 0 ? l.cellMM : (p.latticeSelectableCellMM(ref) ?? s.cellMaxMM),
                                  s.cellMaxMM, 8].lazy.compactMap({ p.latticeDensityPercent(rho: rho, cellMM: $0) }).first {
                        // (the row's cell, else the largest cell: the page's percent is read on a cell its band exists for)
                        let dial = Swift.min(1, Swift.max(0.01, pct / 100))
                        if rowDensity { s.regionDials.append((region: id, dial: dial)) } else if !uniformSet { s.dial = dial; uniformSet = true }
                    }
                }
                id += 1
            }
        }
        // ★ 11-13: Protect skins of one depth go as ONE skin (the same solid, rule D5). The engine's reading asks every skin in
        // turn: his v4 stand's 26 skins of 4 mm took 289 s to lay on the Mac, one group of them 0.7 s, the lattice identical.
        s.protect = Self.mergedByDepth(s.protect)
        // Whole part ("In a part"), or no face asked for lattice: the whole part is lattice, less No lattice and Protect skins
        s.allLattice = l.wholePart || !s.regions.contains { !$0.noLattice }
        return s
    }
}

/// One plain line where the new engine's lines go, when it does not draw (Organic).
struct LatticeLayoutPreviewOneLine: View {
    let text: String
    var body: some View {
        Text(text).font(.system(size: 12)).foregroundStyle(DS.Color.textSecondary.color).lineLimit(1).minimumScaleFactor(0.8)
            .padding(.horizontal, DS.Space.m).padding(.vertical, DS.Space.xs)
            .background(Capsule().fill(DS.Surface.bar.color))
            .background(CornerPairStyle.publish("new-engine-lines"))
            .allowsHitTesting(false)
    }
}

/// The new engine's lines under the 3D view: what is wrong (or that it is laying), the round-bars line, and core's ms (the
/// debug overlay: stage E's iPad timing).
struct LatticeLayoutPreviewLines: View {
    @ObservedObject var preview: LatticeLayoutPreview

    var body: some View {
        VStack(spacing: 2) {
            if let p = preview.problem {
                Text(p).font(.system(size: 12, weight: .semibold)).foregroundStyle(DS.Color.warning.color)
            } else if preview.laying, preview.bars == nil {
                Text("New engine: laying the lattice…").font(.system(size: 12)).foregroundStyle(DS.Color.textSecondary.color)
            }
            ForEach(preview.notes, id: \.self) { n in
                Text(n).font(.system(size: 12)).foregroundStyle(DS.Color.warning.color)
            }
            if let z = preview.nozzleLine {
                Text(z).font(.system(size: 12, weight: .semibold)).foregroundStyle(DS.Color.textPrimary.color)
                    .background(CornerPairStyle.publish("new-engine-nozzle"))
            }
            Text(LatticeLayoutPreview.roundBarsLine).font(.system(size: 12)).foregroundStyle(DS.Color.textSecondary.color)
            if let t = preview.timing {
                Text(t.line).font(.system(size: 11, design: .monospaced)).foregroundStyle(DS.Color.textTertiary.color)
                    .accessibilityIdentifier("new-engine-timing")
                    .background(CornerPairStyle.publish("new-engine-timing"))   // the hosted tests' frame: core's numbers came back
            }
        }
        .lineLimit(1).minimumScaleFactor(0.8)
        .padding(.horizontal, DS.Space.m).padding(.vertical, DS.Space.xs)
        .background(Capsule().fill(DS.Surface.bar.color))
        .background(CornerPairStyle.publish("new-engine-lines"))   // the hosted tests' frame (LatticeLayoutSwitchHostedTests)
        .allowsHitTesting(false)
        .accessibilityIdentifier("new-engine-lines")
    }
}
