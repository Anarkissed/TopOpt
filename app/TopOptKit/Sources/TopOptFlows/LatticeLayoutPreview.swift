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
#if os(iOS)
import os
#endif

@MainActor
public final class LatticeLayoutPreview: ObservableObject {

    /// What the 3D view draws (nil: nothing yet).
    @Published public private(set) var bars: LatticeLayoutBarsInputs?
    /// ★ Install 3: what the layout on screen laid (bars and cells), for the colour key, the tap-to-read card and the drawer.
    @Published public private(set) var laid: LatticeLayoutColours.Laid?
    /// One plain line under the preview: what is wrong, or nil. ★ his 11-20: a new one is also raised as a centred pop-up.
    @Published public private(set) var problem: String? {
        didSet { if let p = problem, p != oldValue, Self.popsUp(p) { AppPopups.shared.show(Self.problemTitle, p) } }
    }
    static let problemTitle = "The lattice preview couldn’t be made"
    /// A problem that is the page's state rather than an error (no part yet) stays a line.
    static func popsUp(_ p: String) -> Bool { p != noPartLine && p != organicNeedsStressLine }
    /// ★ his 11-20: the engine's own words never reach the page; this plain sentence does, the words go to the log.
    static let failedPlainLine = "These settings didn’t make a lattice. Try changing one of them; if it keeps happening, tell us."

    /// Core's numbers for the debug overlay (stage E's iPad timing): open, read, cells, bars, ms.
    @Published public private(set) var timing: Timing?
    @Published public private(set) var laying = false
    /// ★ D23 (his 11-17): the chips' places of the last layout, and how long core took to find them.
    @Published public private(set) var places: [LatticeLayoutSession.Place] = []
    public private(set) var placesMS = 0.0
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
        public var organicLine: String?   // ★ Organic cut 1: its own line (mode, Draft or Exact, the lay time, struts)
        public var line: String {
            if let o = organicLine { return o }
            return String(format: "New engine · open %.0f · read %.0f · cells %.0f · bars %.0f ms · %d bars", openMS, readMS, cellsMS, barsMS, bars)
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
    /// ★ Organic cut 1 (his 11-18 "VIEW things on the ipad ASAP"): Organic is drawn by the new engine too, on a part with
    /// its model file (variants keep the old engine). `organic` says whether these settings are Organic.
    public static func draws(_ l: LatticeSettings) -> Bool { true }
    public static func organic(_ l: LatticeSettings) -> Bool { l.resolvedAlgorithm == "organic" }
    /// The strut type whose law turns a width into a density; Organic has none (width / cell size).
    static func lawType(_ l: LatticeSettings) -> LatticeType? { organic(l) ? nil : l.lattice }
    /// One plain line each for what the new engine leaves out for these settings.
    public static func notes(_ l: LatticeSettings, hasStress: Bool = false) -> [String] {
        var out: [String] = []
        if needsStress(l), !hasStress, !organic(l) { out.append(byStressLine) }   // ★ 11-20: Organic runs its check itself
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
        if organic(l) { return true }   // ★ Organic cut 1: the weave follows the stress (its tensor)
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
    /// ★ Organic cut 2: the groups the last EXACT Organic lay laid (nil: none, a draft, or refused).
    private var organicLaidGroups: [LatticeLayoutSession.OrganicGroup]?
    private var sessionPath: String?
    private var openMS = 0.0
    private var lastSettings: LatticeLayoutSession.Settings?
    private var lastOrganicKey: String?   // ★ his Organic settings at the last lay (organicKey)
    private var pageManualAtLay = false
    private var token = 0
    private var task: Task<Void, Never>?
    /// ★ THE SOLID VIEW (his ask 11-13): X-ray off draws the part solid, cut open where the lattice is (the engine's map).
    private var solidWanted = false
    private var box: (lo: SIMD3<Float>, hi: SIMD3<Float>)?
    /// ★ The flat cut (his 11-20 skin note): the part's surface the vines are cut at, and the mesh it is built from (once
    /// per part, off the main thread, at the first Organic lay).
    private var cutMesh: ImportedMesh?
    private var cutSurface: (path: String, surface: OrganicVineShape.CutSurface)?
    /// ★ Cut 2: the loaded and fixed faces at the lay (kept flush whatever depth variation says).
    private var flushAtLay: [Int32] = []
    private var mapTask: Task<Void, Never>?
    private var nozzleSession: LatticeLayoutSession?
    private var latticeAtLay = LatticeSettings()
    private var nozzlePath: String?
    private var stress = Stress()
    private var sessionStressKey: Int?   // the field the session holds (setDemand), by its key
    // ★ Organic cut 1: the tensor the session holds (by the stress key), the layer height at this lay, the Auto Sweep limits
    // core measured for these regions and line (before the lay), what the last Organic lay was, and its numbers
    private var sessionTensorKey: Int?
    private var layerAtLay = 0.2
    private var organicLimits: (key: LatticeLayoutSession.Settings, line: Double, limits: LatticeOrganicLook.Limits?,
                                groups: [UUID: LatticeOrganicLook.Limits])?
    private var groupsAtLay: [Int32: UUID] = [:]
    private var groupOrderAtLay: [UUID] = []          // the page's groups, in order
    private var groupNamesAtLay: [UUID: String] = [:]
    private var syntheticOn = false                   // the session's stress is filled (E5)
    @Published public private(set) var organicQuality: LatticeLayoutSession.Organic.Quality?
    @Published public private(set) var organicNumbers: OrganicNumbers?
    /// The Auto numbers the last Organic lay used (core's once measured), for the controls' fields.
    @Published public private(set) var organicAutoLimits: LatticeOrganicLook.Limits?
    /// ★ Each group's measured Auto Sweep limits (the union of its areas), before Look (per group, his 11-18).
    @Published public private(set) var organicGroupLimits: [UUID: LatticeOrganicLook.Limits] = [:]
    /// ★ E5: each wall's verdict from core (true = without stress, filled), by its selectable key (the Selections row).
    @Published public private(set) var organicWallVerdicts: [String: Bool] = [:]
    /// ★ E1: the engine's refusals of the last Organic lay (empty: none).
    @Published public private(set) var organicRefusals: [LatticeLayoutSession.Refusal] = []
    public struct OrganicNumbers: Equatable { public var strands: Int, segments: Int, ms: Double, draft: Bool
        public var limitsMeasured: Bool }
    /// Organic's draft line (a dragged slider's quick lay is NOT what will be made).
    public static let draftLine = "Draft while you change it \u{00B7} the exact lattice follows"
    /// ★ Cut 2 (OJ6, the hand-over sheet's own words): bulges the print check made flush.
    public static func reliefFlushedLine(_ n: Int) -> String {
        n == 1 ? "1 bulge made flush so the part prints" : "\(n) bulges made flush so the part prints"
    }
    /// Organic needs the stress check (its weave follows the stress's directions).
    public static let organicNeedsStressLine = "Checking the stresses first, then the lattice"
    private var nozzleStressKey: Int?

    public init() {}

    /// ★ his pick 11-16 (2): whether the layout on screen is the one these inputs ask for (Click to refresh marks the preview
    /// out of date when not). True with nothing laid yet only when there is nothing to lay.
    public func isCurrent(project p: ProjectModel, stress: Stress = Stress()) -> Bool {
        guard let path = p.importedFile?.path else { return bars == nil }
        return path == sessionPath && Self.settings(p, referenceMPa: stress.referenceMPa) == lastSettings && stress.key == self.stress.key
            && Self.organicKey(p) == lastOrganicKey
    }

    /// ★ Organic cut 2 (the export, handover f): what the print file is made from — the SAME groups the exact preview laid for
    /// these inputs, and the stress that lay followed (as set, or as the synthetic stress filled it) as core's file. nil: no
    /// exact lay of these inputs yet (the page lays it first), or still laying.
    public func organicFileInputs(project p: ProjectModel, stress: Stress = Stress())
        async throws -> (groups: [LatticeLayoutSession.OrganicGroup], tensor: Data) {
        if laying { throw OrganicFileWait.laying }
        guard let groups = organicLaidGroups, let session else { throw OrganicFileWait.notLaid }
        guard isCurrent(project: p, stress: stress) else { throw OrganicFileWait.outOfDate }
        let tensor = try await session.tensorFile()
        return (groups, tensor)
    }
    /// Why the file can't be made from the preview yet: it is laying, nothing exact is laid, or the settings moved since.
    public enum OrganicFileWait: Error, Equatable { case laying, notLaid, outOfDate }

    /// ★ his 11-20: the Lattice button's type on Organic — "Organic Traced", "Organic Grown", or "Organic" when groups differ.
    public static func organicButtonType(_ p: ProjectModel) -> String {
        let groups = p.lattice.wholePart || p.latticeAreaGroups.isEmpty ? [nil] : p.latticeAreaGroups.map { Optional($0.id) }
        let modes = Set(groups.map { p.lattice.organicLook(group: $0).modeValue })
        return modes.count == 1 ? "Organic " + modes.first!.title : "Organic"
    }

    /// The page's one call, on every change of the part or its lattice settings (cheap when nothing changed).
    /// ★ his picks 11-16: `delay` — Live preview lays half a second after the last change (a newer change cancels the wait);
    /// `checkNozzle` — Refresh also runs the 0.2 mm nozzle check after the layout.
    public func update(project p: ProjectModel, on: Bool, solid: Bool = false, stress: Stress = Stress(),
                       delay: Duration = .zero, checkNozzle: Bool = false) {
        guard on else { clear(); return }
        guard let path = p.importedFile?.path else { problem = Self.noPartLine; bars = nil; return }
        if path != sessionPath || box == nil { box = Self.box(p.importedMesh?.vertices ?? []) }
        if path != cutSurface?.path { cutMesh = p.importedMesh }
        let solidChanged = solid != solidWanted
        solidWanted = solid
        notes = Self.notes(p.lattice, hasStress: stress.field != nil)
        let s = Self.settings(p, referenceMPa: stress.referenceMPa)
        let stressMoved = stress.key != self.stress.key
        self.stress = stress
        let ok = Self.organicKey(p)
        if path == sessionPath, s == lastSettings, ok == lastOrganicKey, !stressMoved, task != nil || bars != nil {
            if solidChanged, task == nil || bars != nil { solidToggled() }
            if checkNozzle, nozzleState == .notAsked, bars != nil { self.checkNozzle() }   // Refresh with nothing changed
            return
        }
        lastSettings = s
        lastOrganicKey = ok
        pageManualAtLay = p.latticePageManual
        latticeAtLay = p.lattice
        flushAtLay = Self.flushFaces(p)   // ★ cut 2: the loaded and fixed faces, always flush
        layerAtLay = p.printParams.layerHeightMM > 0 ? p.printParams.layerHeightMM : 0.2
        keysAtLay = Self.regionKeys(p)   // ★ Install 3: the drawer's rows, as this layout's regions
        groupsAtLay = Self.regionGroups(p)   // ★ Organic per group: each region's group
        groupOrderAtLay = p.latticeAreaGroups.map(\.id)
        groupNamesAtLay = Dictionary(p.latticeAreaGroups.map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })
        task?.cancel()
        laying = true
        nozzleWanted = checkNozzle
        task = Task { [weak self] in
            if delay > .zero {   // ★ Live preview: wait for him to stop changing it
                try? await Task.sleep(for: delay)
                if Task.isCancelled { return }
            }
            await self?.lay(path: path, s, draft: delay > .zero && Self.organic(p.lattice))
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
        sessionTensorKey = nil; organicLimits = nil; organicQuality = nil; organicNumbers = nil   // ★ Organic cut 1
        organicLaidGroups = nil   // ★ cut 2
        bars = nil; laid = nil; problem = nil; timing = nil; laying = false; places = []
    }

    // MARK: ★ Install 3 — the old preview's colour key on the new engine's bars

    /// RED CONTROL (tests): the old engine's bake still runs under the new engine (before Install 3).
    nonisolated(unsafe) public static var controlOldBakeUnderNewEngine = false
    /// The old engine's bakes the page started (a test's count: none where the new engine draws).
    nonisolated(unsafe) public static var oldEngineBakes = 0

    private var keysAtLay: [Int32: String] = [:]
    /// ★ Install 3: the cells drawer's numbers per face row, from the layout on screen.
    public func selectableCells() -> [String: LatticeRegionCells.SelectableCell] {
        guard let laid else { return [:] }
        return Self.selectableCells(laid, keys: keysAtLay, algorithm: latticeAtLay.algorithm)
    }

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

    /// The span of relative density the bars are drawn over (the key's scale), and the median cell (its millimetres).
    public func keyScale() -> (lo: Double, hi: Double, cellMM: Double)? {
        guard let laid, laid.barCount > 0 else { return nil }
        if let c = scaleCache, c.token == laid.token { return c.scale }
        let rho = LatticeLayoutColours.densities(laid, type: Self.lawType(latticeAtLay))
        let cells = laid.barCell.sorted()
        let scale = (lo: rho.min() ?? 0, hi: rho.max() ?? 0, cellMM: Double(cells.isEmpty ? 0 : cells[cells.count / 2]))
        scaleCache = (laid.token, scale)
        return scale
    }
    private var scaleCache: (token: Int, scale: (lo: Double, hi: Double, cellMM: Double))?

    /// Whether any bar on screen is boundary work (the key's rim row).
    public var hasSkinBars: Bool { laid?.barFlags.contains { LatticeLayoutColours.isSkin($0) } ?? false }

    /// ★ The tap-to-read card's reading on the new engine: the bar nearest `p` (model mm) — its cell, width and density, what
    /// it is (boundary work, the grade band, or fill) — from what the layout laid, the same numbers its colour was made from.
    public struct Reading: Equatable {
        public var cellMM: Double
        public var widthMM: Double
        public var density: Double
        public var klass: LatticeStructureClass
    }
    public func read(at p: SIMD3<Float>) -> Reading? {
        guard let laid else { return nil }
        return Self.read(laid, at: p, lattice: latticeAtLay, lookup: latticeAtLay.gradingMode.fitsShape ? cellLookup() : nil)
    }
    /// The same, for a given layout and settings (tests read it directly).
    static func read(_ laid: LatticeLayoutColours.Laid, at p: SIMD3<Float>, lattice latticeAtLay: LatticeSettings,
                     lookup: LatticeLayoutColours.CellLookup?) -> Reading? {
        guard laid.barCount > 0 else { return nil }
        var best = -1
        var bestD = Float.infinity
        for i in 0..<laid.barCount {
            let k = 7 * i
            let a = SIMD3(laid.bars[k], laid.bars[k + 1], laid.bars[k + 2]), b = SIMD3(laid.bars[k + 3], laid.bars[k + 4], laid.bars[k + 5])
            let ab = b - a, l2 = simd_length_squared(ab)
            let t = l2 > 0 ? Swift.min(Swift.max(simd_dot(p - a, ab) / l2, 0), 1) : 0
            let d = simd_length(a + ab * t - p) - laid.bars[k + 6] / 2
            if d < bestD { bestD = d; best = i }
        }
        guard best >= 0 else { return nil }
        let width = Double(laid.bars[7 * best + 6])
        let cell = best < laid.barCell.count ? Double(laid.barCell[best]) : 0
        var one = LatticeLayoutColours.Laid()
        one.bars = Array(laid.bars[(7 * best)..<(7 * best + 7)]); one.barCell = [Float(cell)]
        let rho = LatticeLayoutColours.densities(one, type: Self.lawType(latticeAtLay)).first ?? 0
        var klass: LatticeStructureClass = .interior
        if best < laid.barFlags.count, LatticeLayoutColours.isSkin(laid.barFlags[best]) {
            klass = .rim
        } else if latticeAtLay.gradingMode.fitsShape, let look = lookup {
            let k = 7 * best
            let mid = (SIMD3(laid.bars[k], laid.bars[k + 1], laid.bars[k + 2]) + SIMD3(laid.bars[k + 3], laid.bars[k + 4], laid.bars[k + 5])) / 2
            if let c = look.cell(at: mid), laid.cellInfo[5 * c + 2] < 1 { klass = .grade }
        }
        return Reading(cellMM: cell, widthMM: width, density: rho, klass: klass)
    }

    /// The bars to draw, wearing the old preview's key (LatticeLayoutColours): by what each bar is and how much material it
    /// holds, or by the stress (`stress`, the stress view with the lattice; `stressKey` names it). Worked out once per layout
    /// and colouring.
    public func drawn(stressField field: LatticeDemandField?, stressKey: Int) -> LatticeLayoutBarsInputs? {
        guard var b = bars else { return nil }
        guard let laid, laid.token == b.token else { return b }
        let grade = latticeAtLay.gradingMode.fitsShape
        let organic = latticeAtLay.isOrganic
        let key = [b.token, field == nil ? 0 : stressKey, grade ? 1 : 0, latticeAtLay.topologyID.hashValue, organic ? 1 : 0,
                   LatticeLayoutColours.controlOneColour ? 1 : 0, b.solid?.token ?? -1, b.hidden ? 1 : 0]
        if let c = drawnCache, c.key == key { return c.bars }
        b.colours = LatticeLayoutColours.colours(laid, type: Self.lawType(latticeAtLay), grade: grade,
                                                 stress: field.map(LatticeLayoutColours.Stress.init(field:)),
                                                 lookup: grade ? cellLookup() : nil, oneColour: organic)
        var h = Hasher()
        key.forEach { h.combine($0) }
        b.colourKey = h.finalize()
        drawnCache = (key, b)
        return b
    }

    /// Layouts started, app-wide (a hosted test's count: Click to refresh lays none on a change; Live one per pause).
    public static private(set) var laysStarted = 0

    private func lay(path: String, _ s: LatticeLayoutSession.Settings, draft: Bool = false) async {
        Self.laysStarted += 1
        do {
            if session == nil || sessionPath != path {
                session?.close()
                let opened = try await LatticeLayoutSession.open(path: path)
                guard !Task.isCancelled else { return }
                session = opened; sessionPath = path; openMS = opened.info.msOpen; sessionStressKey = nil; sessionTensorKey = nil; organicLimits = nil
            }
            guard let session else { return }
            sessionStressKey = try await Self.give(stress, to: session, holding: sessionStressKey)
            if Self.organic(latticeAtLay) {   // ★ Organic cut 1: the weave's own lay
                try await layOrganic(session, path: path, s, draft: draft)
                return
            }
            organicQuality = nil; organicNumbers = nil
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
            // ★ his 11-17 "add a chip to ask what it should be": the faces this layout's regions run into that no rule decides
            // (D23), asked with the SAME settings it was laid with — a second call, so a dragged slider never waits on it
            if !Task.isCancelled, let found = try? await session.places(s), !Task.isCancelled {
                places = found.places
                placesMS = found.ms
            }
            // ★ his pick 11-16 (5): the nozzle check is a second full layout — only when asked (Refresh, or his tap)
            if LatticePreviewMode.nozzleAfterLay(asked: nozzleWanted), !Task.isCancelled {
                nozzleWanted = false
                await nozzleCheck(path: path, s, lattice: latticeAtLay)
            }
        } catch is CancellationError {
            // a newer setting is laying
        } catch {
            NSLog("TopOpt preview failed: %@", (error as? TopOptError)?.message ?? "\(error)")   // the words: the log only
            problem = Self.failedPlainLine
            bars = nil
            laying = false
        }
    }

    /// ★ Organic cut 1: the weave's lay. The tensor in (once per stress), Auto's numbers (core's, measured before the lay,
    /// once per regions and line), the lay (Draft while a slider moves, then Exact), its runs as
    /// the bars pass's segments. No stress yet: one line (the page runs the stress check first).
    private func layOrganic(_ session: LatticeLayoutSession, path: String, _ s: LatticeLayoutSession.Settings, draft: Bool) async throws {
        // ★ Auto's numbers first, measured by the engine before any lay or stress (his iPad notes 11-18: the fields showed
        // 0): the whole part's and each group's (E4: the union of its areas), once per "where" and line
        let line = s.beadMM > 0 ? s.beadMM : 0.45   // the print line (the settings' bead)
        let weave = s.regions.filter { $0.weave && !$0.noLattice }.map(\.id)
        var byGroup: [UUID: [Int32]] = [:]
        for id in weave { if let g = groupsAtLay[id] { byGroup[g, default: []].append(id) } }
        if organicLimits == nil || !Self.sameWhere(organicLimits!.key, s) || organicLimits!.line != line {
            func limits(_ ids: [Int32]) async throws -> LatticeOrganicLook.Limits {
                try await session.sweepLimits(s, regions: ids, lineMM: line).map(LatticeOrganicLook.Limits.init)
                    ?? .init(strutLowerMM: 0, strutUpperMM: 0, strutAutoMM: 0, cellLowerMM: 0, cellUpperMM: 0, cellAutoMM: 0,
                             measured: false)
            }
            let whole = weave.isEmpty ? nil : try await limits(weave)
            var groups: [UUID: LatticeOrganicLook.Limits] = [:]
            for (g, ids) in byGroup { groups[g] = try await limits(ids) }
            guard !Task.isCancelled else { return }
            organicLimits = (s, line, whole, groups)
        }
        organicAutoLimits = organicLimits?.limits   // (before Look: the page applies each look's own)
        organicGroupLimits = organicLimits?.groups ?? [:]
        guard let f = stress.field, !f.stressTensor.isEmpty else {
            problem = Self.organicNeedsStressLine; bars = nil; laying = false; return
        }
        guard f.stressTensor.allSatisfy(\.isFinite) else {
            problem = "The stress result holds a value that is not a number: run the stress check again"
            bars = nil; laying = false; return
        }
        if sessionTensorKey != stress.key {
            try await session.setTensor(voigt: f.stressTensor, nx: f.nx, ny: f.ny, nz: f.nz, origin: f.origin, spacingMM: f.spacingMM)
            sessionTensorKey = stress.key
        }
        // ★ E7, per group (his 11-18: "whole part ONLY if the whole part is latticed. Otherwise, it is per Group"): each
        // group's own settings (Auto: Look alone), its own limits moved by its own Look
        func ask(_ look: LatticeOrganicLook, _ lim: LatticeOrganicLook.Limits?) -> LatticeLayoutSession.Organic {
            let l = lim.map { $0.measured ? $0.looked(percent: look.lookPercentValue) : $0 }
            var a = look.ask(limits: l?.measured == true ? l : nil, layerMM: layerAtLay,
                             aesthetic: (latticeAtLay.stageMode ?? .structural) == .aesthetic, flushFaces: flushAtLay)
            a.quality = draft ? .draft : .exact
            return a
        }
        var groups: [LatticeLayoutSession.OrganicGroup] = []
        var looks: [LatticeOrganicLook] = []
        var groupIDs: [UUID?] = []
        let wholePart = latticeAtLay.wholePart || byGroup.isEmpty
        if wholePart {
            let look = latticeAtLay.organicLook(group: nil).effective(pageManual: pageManualAtLay)
            groups = [.init(regions: weave, ask: ask(look, organicLimits?.limits))]
            looks = [look]; groupIDs = [nil]
        } else {
            for g in groupOrderAtLay where byGroup[g] != nil {
                let look = latticeAtLay.organicLook(group: g).effective(pageManual: pageManualAtLay)
                groups.append(.init(regions: byGroup[g]!, ask: ask(look, organicLimits?.groups[g])))
                looks.append(look); groupIDs.append(g)
            }
        }
        let grown = looks.contains { $0.modeValue == .grown }
        if let short = Self.organicMemoryShort(mode: grown ? .grown : .traced, availableMB: Self.availableMB()) {
            problem = short; bars = nil; laid = nil; laying = false; return   // ★ refused, never a crash
        }
        // ★ E5, "Simulate stresses on unstressed walls" (his 11-18: Organic and Aesthetic only; each wall's foci, default 3)
        let aesthetic = (latticeAtLay.stageMode ?? .structural) == .aesthetic
        var walls: [(region: Int32, foci: Int)] = []
        if aesthetic {
            for (i, look) in looks.enumerated() where look.syntheticStresses == true {
                for id in groups[i].regions {
                    let stated = keysAtLay[id].flatMap { latticeAtLay.selectableSyntheticFoci[$0] }
                    walls.append((id, Swift.min(Swift.max(stated ?? latticeAtLay.organicSyntheticFoci, 1), 5)))
                }
            }
        }
        if !walls.isEmpty || syntheticOn {
            let rep = try await session.synthetic(s, groups: groups, walls: walls)
            guard !Task.isCancelled else { return }
            syntheticOn = !walls.isEmpty
            if !rep.refused.isEmpty { return refuse(rep.refused, groupIDs) }
            var verdicts: [String: Bool] = [:]
            for (id, dead) in rep.withoutStress { if let k = keysAtLay[id] { verdicts[k] = dead } }
            organicWallVerdicts = verdicts
        }
        let r = try await session.layOrganic(s, groups: groups)
        guard !Task.isCancelled else { return }
        if !r.refused.isEmpty { organicLaidGroups = nil; return refuse(r.refused, groupIDs) }
        organicRefusals = []
        // ★ cut 2: the groups the EXACT lay laid (the file is that lattice); a draft is not what will be made
        organicLaidGroups = r.quality == .exact ? groups : nil
        token &+= 1
        let seg = Self.segments(r.runs)
        // ★ his 11-19 rule ("The drawing follows the print file. Always."): every vine, Grown and the net skin too, as the
        // print file's tubes make them (built off the main thread), cut flat where they reach the part's surface (his 11-20
        // skin note: the file trims every tube to the part)
        let runs = r.runs
        let known = cutSurface?.path == path ? cutSurface?.surface : nil
        let mesh = known == nil ? cutMesh.map { ($0.vertices, $0.indices, $0.faceIDs) } : nil
        let (vines, surface) = await Task.detached(priority: .userInitiated) { () -> (OrganicVineShape, OrganicVineShape.CutSurface?) in
            var v = OrganicVineShape.tubes(runs: runs)
            let surface = known ?? mesh.map { OrganicVineShape.CutSurface(vertices: $0.0, indices: $0.1, faceIDs: $0.2) }
            if let surface { v.cut(runs: runs, surface: surface) }
            return (v, surface)
        }.value
        guard !Task.isCancelled else { return }
        if known == nil, let surface { cutSurface = (path, surface); cutMesh = nil }
        var drawn = LatticeLayoutBarsInputs(token: token, bars: seg.bars, solid: nil, flags: seg.flags)
        drawn.lightFrom = Self.organicLightFrom(grown: grown, netFrom: seg.lightFrom, count: seg.count)
        drawn.vines = vines
        bars = drawn
        var l = LatticeLayoutColours.Laid()   // no cells: the key and card read each strut's width and its cell size
        l.bars = seg.bars; l.barFlags = seg.skin; l.barCell = seg.cell; l.barRegion = seg.region; l.token = token
        laid = l
        timing = Timing(openMS: openMS, readMS: r.layout.msRead, cellsMS: r.msTrace, barsMS: r.layout.msBars, bars: seg.count)
        timing?.organicLine = Self.organicTimeLine(mode: grown ? .grown : .traced, draft: r.quality == .draft, ms: r.ms,
                                                   struts: seg.count)
        organicQuality = r.quality
        organicNumbers = OrganicNumbers(strands: r.strands, segments: seg.count, ms: r.ms, draft: r.quality == .draft,
                                        limitsMeasured: organicLimits?.limits?.measured == true)
        let missing = r.layout.emptyRegions.count
        problem = seg.count == 0 ? "New engine: no Organic lattice fits these settings"
            : missing == 1 ? "An area points at faces this part does not have: pick its faces again"
            : missing > 1 ? "\(missing) areas point at faces this part does not have: pick their faces again" : nil
        notes = Self.notes(latticeAtLay, hasStress: true) + (r.quality == .draft ? [Self.draftLine] : []) + r.notes
            + (r.reliefFlushed > 0 ? [Self.reliefFlushedLine(r.reliefFlushed)] : [])   // ★ cut 2 (OJ6)
        laying = false
        // a draft is followed by the exact lattice when nothing newer came
        // ★ his 11-18 iPad (the body hid the weave): the solid view's map, cut open around Organic as around the regular lattice
        if r.quality == .exact, solidWanted, !Task.isCancelled { await addMap() }
        if r.quality == .draft, !Task.isCancelled { try await layOrganic(session, path: path, s, draft: false) }
    }

    /// The Organic lay's line: "Organic Grown · Exact · laid in 3.8 s · 63,670 struts".
    static func organicTimeLine(mode: LatticeOrganicLook.Mode, draft: Bool, ms: Double, struts: Int) -> String {
        let n = NumberFormatter.localizedString(from: NSNumber(value: struts), number: .decimal)
        return String(format: "Organic %@ \u{00B7} %@ \u{00B7} laid in %.1f s \u{00B7} %@ struts", mode.title,
                      draft ? "Draft" : "Exact", ms / 1000, n)
    }

    /// ★ Organic cut 1, the memory gate: an Exact lay of his stand peaked at 498 MB (Grown) and 186 MB (Traced) (LatticeReview's
    /// item 2, after the fix); with a quarter more, a lay that would not fit in what this device has free is refused in one
    /// line. nil: room enough, or the device cannot say (a Mac).
    static func organicMemoryShort(mode: LatticeOrganicLook.Mode, availableMB: Double?) -> String? {
        let need = mode == .grown ? 625.0 : 235.0
        guard let a = availableMB, a < need else { return nil }
        return String(format: "Not enough free memory for %@ (%.0f of %.0f MB): close other apps", mode.title, a, need)
    }
    /// What this app may still use (iOS: os_proc_available_memory), MB; nil where the system does not say.
    static func availableMB() -> Double? {
        #if os(iOS)
        let b = os_proc_available_memory()
        return b > 0 ? Double(b) / 1_048_576 : nil
        #else
        return nil
        #endif
    }

    /// ★ His 11-18 ("There is no question, it will lag"): the light pass draws ALL of Grown (43,646 struts on his stand at
    /// Auto, past the ~37,000 the iPad lags at; at Auto Grown has no net skin), and only a net skin otherwise (Traced:
    /// 32,433 on his stand, drawn round).
    static func organicLightFrom(grown: Bool, netFrom: Int, count: Int) -> Int {
        grown ? 0 : (netFrom < count ? netFrom : .max)
    }

    /// ★ E1: the engine refused (nothing laid): its sentences whole, the group named, never an area's number (his rule).
    private func refuse(_ refused: [LatticeLayoutSession.Refusal], _ groupIDs: [UUID?]) {
        let texts = refused.map { r -> String in
            var t = r.text
            // "area 2" is a region id: the wall's own name instead
            while let m = t.range(of: #"area \d+"#, options: .regularExpression) {
                let id = Int32(t[m].dropFirst(5)) ?? 0
                t.replaceSubrange(m, with: groupsAtLay[id].flatMap { groupNamesAtLay[$0] } ?? "an area")
            }
            if groupIDs.count > 1, r.group >= 0, r.group < groupIDs.count, let g = groupIDs[r.group], let n = groupNamesAtLay[g] {
                t = n + ": " + t
            }
            return t
        }
        problem = texts.first.map { texts.count > 1 ? $0 + " (and \(texts.count - 1) more)" : $0 }
        organicRefusals = refused
        bars = nil; laid = nil; laying = false
    }

    /// ★ What of his Organic settings the lay reads beyond the session Settings: the controls (Manual), Look, and the page's
    /// Auto / Manual. nil: not Organic.
    static func organicKey(_ p: ProjectModel) -> String? {
        guard organic(p.lattice) else { return nil }
        let look = (p.lattice.organicLook ?? LatticeOrganicLook()).effective(pageManual: p.latticePageManual)
        // ★ 11-20: sorted keys — a dictionary's own order may differ between two equal settings (the export read that as
        // "the settings moved since the preview" and refused a finished preview)
        let enc = JSONEncoder(); enc.outputFormatting = [.sortedKeys]
        let data = (try? enc.encode(look)) ?? Data()
        let groups = (try? enc.encode(p.lattice.organicLooks ?? [:])) ?? Data()
        return "\(p.latticePageManual) \(p.lattice.wholePart) " + String(decoding: data, as: UTF8.self)
            + String(decoding: groups, as: UTF8.self)
    }

    /// The same regions and depths (the "where" Auto's numbers are measured on).
    static func sameWhere(_ a: LatticeLayoutSession.Settings, _ b: LatticeLayoutSession.Settings) -> Bool {
        a.regions == b.regions && a.protect == b.protect && a.allLattice == b.allLattice
    }

    /// The runs as the bars pass draws them: one capsule per pair of neighbouring points, its width the two points' mean.
    static func segments(_ runs: [LatticeLayoutSession.Run])
        -> (bars: [Float], flags: [UInt8], count: Int, cell: [Float], region: [Int32], skin: [UInt8], lightFrom: Int) {
        var b: [Float] = [], f: [UInt8] = [], cell: [Float] = [], region: [Int32] = [], skin: [UInt8] = []
        let n = runs.reduce(0) { $0 + Swift.max(0, $1.points.count - 1) }
        b.reserveCapacity(7 * n); f.reserveCapacity(n); cell.reserveCapacity(n); region.reserveCapacity(n); skin.reserveCapacity(n)
        var lightFrom = 0
        // ★ his 11-18 ("it will lag"): the net skin last, so the light pass draws it from `lightFrom` on
        for netPass in [false, true] {
          if netPass { lightFrom = cell.count }
          for r in runs where r.points.count >= 2 && r.marks.contains(.net) == netPass {
            let net: UInt8 = netPass ? 2 : 0
            for i in 1..<r.points.count {
                let a = r.points[i - 1], c = r.points[i]
                b.append(contentsOf: [a.x, a.y, a.z, c.x, c.y, c.z, 0.5 * (r.widthMM[i - 1] + r.widthMM[i])])
                f.append(0)
                cell.append(0.5 * (r.spacingMM[i - 1] + r.spacingMM[i]))
                region.append(r.region)
                skin.append(net)
            }
          }
        }
        return (b, f, n, cell, region, skin, lightFrom)
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
            let m = try await Self.map(session, box, token: b.token, smooth: latticeAtLay.isOrganic)
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
    static func map(_ s: LatticeLayoutSession, _ box: (lo: SIMD3<Float>, hi: SIMD3<Float>), token: Int,
                    smooth: Bool = false) async throws -> (grid: LatticeLayoutSolidGrid, ms: Double) {
        let ext = simd_max(box.hi - box.lo, SIMD3(repeating: 0.1))
        let voxel = Swift.max(0.35, Float(cbrt(Double(ext.x * ext.y * ext.z) / 1_000_000)))
        let dims = SIMD3<Int32>(Int32((ext.x / voxel).rounded(.up)) + 3, Int32((ext.y / voxel).rounded(.up)) + 3,
                                Int32((ext.z / voxel).rounded(.up)) + 3)
        let origin = box.lo - SIMD3(repeating: voxel)
        let r = try await s.grid(origin: origin, voxel: voxel, dims: dims)
        // ★ his 11-19 note: Organic's cut edges are smooth lines, not the voxels' stair-steps
        let rg = smooth ? LatticeLayoutSolidGrid.smoothed(r.rg, dims: dims) : r.rg
        return (LatticeLayoutSolidGrid(token: token, origin: origin, voxel: voxel, dims: dims, rg: rg, smooth: smooth), r.ms)
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
        // ★ Organic cut 1: every lattice region is woven, not filled with cells
        if Self.organic(l) {
            for i in s.regions.indices where !s.regions[i].noLattice { s.regions[i].weave = true }
            // ★ the whole part latticed (LatticeReview's C2 point 2: a weave is a Lattice REGION): one region from a box zone
            // round the part, 1 mm over, woven
            if (l.wholePart || !s.regions.contains { !$0.noLattice }), let b = Self.box(p.importedMesh?.vertices ?? []) {
                let c = SIMD3<Double>((b.lo + b.hi) / 2), h = SIMD3<Double>((b.hi - b.lo) / 2) + 1
                var r = LatticeLayoutSession.Region(id: (s.regions.map(\.id).max() ?? 0) + 1, faces: [], depthMM: 0)
                r.zone = .init(kind: .box, centre: c, axes: [SIMD3(1, 0, 0), SIMD3(0, 1, 0), SIMD3(0, 0, 1)], half: h)
                r.weave = true
                s.regions.append(r)
                s.allLattice = false
            }
            // ★ Cut 2 (OJ1/OJ2/OJ8; his 11-19 "None/Skin/Solid. Rim should be hidden"): every Organic area's finish, sent
            // always: its group's own, else the part's, as the Finish row shows it
            if LatticeOrganicLook.finishWired {
                let groupOf = Self.regionGroups(p)
                for i in s.regions.indices where s.regions[i].weave {
                    let g = l.wholePart ? nil : groupOf[s.regions[i].id]
                    let look = l.organicLook(group: g).effective(pageManual: p.latticePageManual)
                    s.regions[i].finish = Self.organicFinish(look, l, coverMM: cover)
                }
            }
            let layer = p.printParams.layerHeightMM > 0 ? p.printParams.layerHeightMM : 0.2
            s.bedFloorMM = 4 * layer   // ★ K1's flat floor under the weave (sheet H1; the ask's bed_floor_mm never reached it)
        }
        // ★ D23 (his 11-17 "add a chip to ask what it should be"): every face a chip was answered "Solid" on, as ONE chip skin at
        // depth 0 (core's D5 two line widths, LatticeReview 11-17: a thin skin with the lattice kept behind it), never merged
        // with his own skins, so its place stays listed and the chip can be answered again
        if let chip = Self.chipSkin(l, id: id) { s.protect.append(chip) }
        // Whole part ("In a part"), or no face asked for lattice: the whole part is lattice, less No lattice and Protect skins
        s.allLattice = l.wholePart || !s.regions.contains { !$0.noLattice }
        if Self.organic(l), s.regions.contains(where: \.weave) { s.allLattice = false }   // the weave's regions say where
        return s
    }

    /// ★ D23: the places as the chip overlay takes them — one chip per place, its faces its members ("face:<raw>", the old
    /// chips' keys), Lattice by default (what the engine makes there), Solid when a chip's answer makes it so now.
    public static func chipDecisions(_ places: [LatticeLayoutSession.Place]) -> [LatticeBandDecision] {
        places.map { p in
            let keys = p.faces.map { chipFaceKey + String($0) }
            return LatticeBandDecision(key: keys.first ?? "place:\(p.region)", kind: .place,
                                       label: LatticeBandChipText.placeTitle(faces: p.faces.count),
                                       anchor: p.point, normal: p.normal, areaMM2: Float(p.areaMM2),
                                       defaultSolid: false, solid: p.solidNow, memberKeys: keys)
        }
    }

    /// The faces answered "Solid" on a chip (`bandTreatments` "face:<raw>" = true, the old chips' keys, so his answers carry
    /// over), as one chip skin; nil when none.
    static func chipSkin(_ l: LatticeSettings, id: Int32) -> LatticeLayoutSession.Protect? {
        let faces = l.bandTreatments.compactMap { k, solid -> Int32? in
            guard solid, k.hasPrefix(chipFaceKey) else { return nil }
            return Int32(k.dropFirst(chipFaceKey.count))
        }.sorted()
        return faces.isEmpty ? nil : .init(id: id, faces: faces, depthMM: 0, chip: true)
    }
    static let chipFaceKey = "face:"
}

extension LatticeLayoutPreview {
    /// ★ Install 3 (the cells drawer on the new engine): which face row each region `settings(_:)` sends is — region id →
    /// the drawer's key (`LatticeSelectableRef.key`). Walks the rows exactly as `settings` does (the ids it gives); the test
    /// holds the two to the same ids.
    /// ★ Organic per group: each lattice region's group, in the same order `settings` gives the regions their ids.
    /// ★ Cut 2: an Organic area's finish for the engine (OJ1 None / Skin, OJ2 Solid, OJ8 the skin's numbers): `look`'s own,
    /// else the part's (Skin for a part skin, Solid for a part shell, else None). Rim is refused under Organic
    /// (rim_under_organic), so it goes as 0 whatever the part says; skin_sink is not offered (core's 0).
    static func organicFinish(_ look: LatticeOrganicLook, _ l: LatticeSettings, coverMM: Double) -> LatticeLayoutSession.RegionFinish {
        let shown = look.finish ?? (l.boundary == .fullSkin ? .skin : (l.boundary.zoneFinishWord == "shell" ? .solid : .none))
        var f = LatticeLayoutSession.RegionFinish()
        f.rimMM = 0
        switch shown {
        case .none:
            f.skin = false; f.coverMM = 0
        case .skin:
            f.skin = true; f.coverMM = 0
            f.skinWidthMM = look.skinWidthMM ?? 0   // 0 = Auto: as thick as the thinner vine
            f.skinDensity = look.skinDensityValue
        case .solid:
            f.skin = false; f.coverMM = coverMM
        }
        return f
    }

    /// ★ Cut 2 (his 11-19 depth variation): the loaded and fixed faces stay flush whatever the switch says (they mate with
    /// other parts): every face of a load or fixture group, in the lattice's own face numbers (a face as it is, a painted
    /// region as its faces).
    static func flushFaces(_ p: ProjectModel) -> [Int32] {
        var out = Set<Int32>()
        for g in p.selection.groups {
            let kind = p.force.kind(for: g.id)
            guard kind.isAnchor || kind.isLoad else { continue }
            for f in g.faces where f >= 0 { out.insert(Int32(f)) }
            for r in g.regionIDs { for f in p.surfaceResolvedFaces(r) where f >= 0 { out.insert(Int32(f)) } }
        }
        return out.sorted()
    }

    public static func regionGroups(_ p: ProjectModel) -> [Int32: UUID] {
        let l = p.lattice
        var out: [Int32: UUID] = [:]
        var id: Int32 = 1
        for g in p.latticeGroups {
            let skinGroup = l.skinGroups.contains(g.id)
            for ref in p.latticeSelectableRefs(g) {
                let role = p.latticeSelectableRole(ref, in: g.id)
                guard skinGroup || role != nil else { continue }
                let hasFaces: Bool
                switch ref {
                case .face: hasFaces = true
                case let .region(_, rid): hasFaces = !p.surfaceResolvedFaces(rid).isEmpty
                case let .primitive(pid):
                    guard !skinGroup, l.zoneGroups.contains(g.id), Self.zone(p, group: g.id, primitive: pid) != nil else { continue }
                    if role != .exclude { out[id] = g.id }
                    id += 1
                    continue
                }
                guard hasFaces else { continue }
                if !skinGroup, role != .exclude { out[id] = g.id }
                id += 1
            }
        }
        return out
    }

    public static func regionKeys(_ p: ProjectModel) -> [Int32: String] {
        let l = p.lattice
        var out: [Int32: String] = [:]
        var id: Int32 = 1
        for g in p.latticeGroups {
            let skinGroup = l.skinGroups.contains(g.id)
            for ref in p.latticeSelectableRefs(g) {
                let role = p.latticeSelectableRole(ref, in: g.id)
                guard skinGroup || role != nil else { continue }
                let hasFaces: Bool
                switch ref {
                case .face: hasFaces = true
                case let .region(_, rid): hasFaces = !p.surfaceResolvedFaces(rid).isEmpty
                case let .primitive(pid):
                    guard !skinGroup, l.zoneGroups.contains(g.id), Self.zone(p, group: g.id, primitive: pid) != nil else { continue }
                    if role != .exclude { out[id] = ref.key }
                    id += 1
                    continue
                }
                guard hasFaces else { continue }
                if !skinGroup, role != .exclude { out[id] = ref.key }
                id += 1
            }
        }
        return out
    }

    /// ★ Install 3: the drawer's measured wall and cell per face row, from what the new engine laid there — the wall that
    /// holds most of the row's cells (its width) and the cell it lays there (the wall's own), the row's cells' size range;
    /// rows sharing a key keep the finer cell, as the old bake's drawer did. Stepped and Doubled only, as before.
    static func selectableCells(_ laid: LatticeLayoutColours.Laid, keys: [Int32: String], algorithm: String)
        -> [String: LatticeRegionCells.SelectableCell] {
        guard ["stepped", "doubled"].contains(algorithm) else { return [:] }
        var byRegion: [Int32: [Int]] = [:]
        for c in 0..<Swift.min(laid.cellCount, laid.cellRegion.count) { byRegion[laid.cellRegion[c], default: []].append(c) }
        var out: [String: LatticeRegionCells.SelectableCell] = [:]
        for (rid, key) in keys.sorted(by: { $0.key < $1.key }) {
            guard let cells = byRegion[rid], !cells.isEmpty else { continue }
            var count: [SIMD2<Int32>: Int] = [:]
            for c in cells where c < laid.cellWall.count && laid.cellWall[c] >= 0 {
                count[SIMD2(laid.cellFrame[c], laid.cellWall[c]), default: 0] += 1
            }
            guard let wall = count.max(by: { $0.value < $1.value || ($0.value == $1.value && ($0.key.x, $0.key.y) > ($1.key.x, $1.key.y)) })?.key
            else { continue }
            let inWall = cells.filter { laid.cellFrame[$0] == wall.x && laid.cellWall[$0] == wall.y }
            let width = Double(laid.cellWallMM[inWall[0]])
            let owns = inWall.map { Double(laid.cellInfo[5 * $0 + 1]) }.sorted()
            let cell = owns[owns.count / 2]
            let sizes = cells.map { Double(laid.cellInfo[5 * $0]) }
            let mine = LatticeRegionCells.SelectableCell(measuredWidthMM: width, cellMM: cell,
                                                         cellRangeMM: (sizes.min() ?? cell)...(sizes.max() ?? cell))
            guard let had = out[key] else { out[key] = mine; continue }
            let span = Swift.min(had.cellRangeMM.lowerBound, mine.cellRangeMM.lowerBound)...Swift.max(had.cellRangeMM.upperBound, mine.cellRangeMM.upperBound)
            let gov = mine.cellMM < had.cellMM ? mine : had
            out[key] = LatticeRegionCells.SelectableCell(measuredWidthMM: gov.measuredWidthMM, cellMM: gov.cellMM, cellRangeMM: span)
        }
        return out
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

    // ★ his 11-21: "No, never show the bottom note! ... Remove it from the UI entirely!!" — the preview's problem and its notes
    // (the stress check's among them) are never drawn here: an error is a centred pop-up (AppPopups), nothing else.
    var body: some View {
        VStack(spacing: 2) {
            if preview.laying, preview.bars == nil {
                Text("New engine: laying the lattice…").font(.system(size: 12)).foregroundStyle(DS.Color.textSecondary.color)
            }
            if let z = preview.nozzleLine {
                Text(z).font(.system(size: 12, weight: .semibold)).foregroundStyle(DS.Color.textPrimary.color)
                    .background(CornerPairStyle.publish("new-engine-nozzle"))
            }
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
