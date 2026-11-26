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
import Combine
import simd
import TopOptKit
import TopOptDesign
#if os(iOS)
import os
#endif

@MainActor
public final class LatticeLayoutPreview: ObservableObject {

    /// What the 3D view draws (nil: nothing yet).
    @Published public private(set) var bars: LatticeLayoutBarsInputs? {
        didSet { growthMeets(bars, after: oldValue) }   // ★ his 11-22: the finished lattice replaces the growth
    }
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
    /// ★ His picks 11-21 (the preview-speed research: "Let's do this one. Absolutely."): the Organic lay under way, for the
    /// Lattice button's ring and count-down. The Draft first (the last lattice dimmed meanwhile), then the exact lattice with
    /// the Draft on screen, marked. nil: no Organic lay going.
    @Published public private(set) var layProgress: LayProgress? {
        didSet { layTimingMoved(from: oldValue) }   // ★ his 11-22: each lay's time and what went in, logged
    }
    public struct LayProgress: Equatable, Sendable {
        public var quality: LatticeLayoutSession.Organic.Quality
        public var started: Date
        /// How long the last lay like it took on this part (s); nil: none yet.
        public var expectedS: Double?
        /// This lay's Draft is on screen (marked) while the exact lattice is made.
        public var draftShown: Bool
        /// ★ his 11-22 (watch it grow): the engine's phase of this lay (LatticePreviewMode.phaseWords); 0 not said yet.
        public var phase: Int
        public init(quality: LatticeLayoutSession.Organic.Quality, started: Date, expectedS: Double?, draftShown: Bool,
                    phase: Int = 0) {
            self.quality = quality; self.started = started; self.expectedS = expectedS; self.draftShown = draftShown
            self.phase = phase
        }
    }
    /// ★ his 11-22 ("Could the user literally *watch* the lattice grow from nothing?"): the vines an Organic lay has laid so
    /// far, drawn by the 3D view while it lays (LatticeGrowth). Not published: each poll redraws the 3D view alone.
    public let growth = LatticeGrowth()
    private var growthWatch: LatticeGrowthWatch?
    /// How often the lay's growth is read (s), and at most how many pieces a read takes: about 80,000 a second, so a lay that
    /// grows faster than that (his a1 part's Draft: 76,000 pieces in about a second) is still seen rising, not in two jumps.
    static let growthPollS = 0.15
    static let growthReadMost = 12_000
    /// RED CONTROL (tests): no growth is watched (as before 11-22).
    nonisolated(unsafe) public static var controlNoGrowth = false
    /// ★ his ask 11-21: Print-accurate preview (the ⌃ menu): on, every Organic lay ends with the exact print-file lattice;
    /// off, the Draft alone stands in (the exact lattice is made with the print file).
    var printAccurate: Bool { AppSettings.shared.latticePrintAccurate }
    /// The lay going (or last made) ends with the exact lattice.
    private var accurateAtLay = true
    /// An exact lattice is being made (the print file waits for it rather than asking again).
    public var layingExact: Bool { laying && accurateAtLay }
    /// ★ notes28: the part's session still opening behind a lattice read back from the version's folder (its inputs wait).
    public var opening: Bool { openingAfterRestore != nil }
    /// RED CONTROL (tests): an Organic lay goes straight to the exact lattice, no Draft first (as before 11-21).
    nonisolated(unsafe) public static var controlNoDraftFirst = false
    /// RED CONTROL (tests): nothing is remembered (every change of settings lays again, as before 11-21).
    nonisolated(unsafe) public static var controlForget = false
    /// Finished Organic previews shown from memory instead of laid (a test's count).
    public static private(set) var remembersShown = 0
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
            // ★ his 11-22: client-facing, the lay's time and size (kept for now: "that is temporary")
            let n = NumberFormatter.localizedString(from: NSNumber(value: bars), number: .decimal)
            return String(format: "Laid in %.1f s \u{00B7} %@ struts", (openMS + readMS + cellsMS + barsMS + mapMS) / 1000, n)
        }
    }

    /// The line the preview carries while the drawer draws every bar round (the reviewer's PREVIEW IS THE SPEC).
    public static let roundBarsLine = "Preview: flat bridges drawn square, as printed · the print adds a few posts"
    public static let noPartLine = "This part has no model file to read: upload its model again"
    public static let byStressLine = "No stress result yet: run the stress check to grade by stress"
    static let noFitLine = "No lattice fits these settings: try larger cells or thinner struts"

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
    /// ★ his 11-22 (the print-accurate lattice made on the Mac): the groups the last DRAFT laid, for the Mac's file job.
    private var organicDraftGroups: [LatticeLayoutSession.OrganicGroup]?
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
    /// ★ his 11-22 (img 45, 47: "The draft lattice doesn't cut the faces of the solid - so it is barely visible as it barely
    /// pokes through"): what the lattice on screen was laid in — its part, settings and stress — by its token (`mapFor`).
    private var shownWhere: (token: Int, at: MapWhere)?
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
    /// ★ his 11-22 ("The settings range should always be consistent. The sample model should always be consistent."): the
    /// Lattice page's Auto numbers are being measured for this part (the sample waits for them, never builds without).
    @Published public private(set) var measuringLimits = false
    private var limitsTask: Task<Void, Never>?
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
        return sameInputs(project: p, stress: stress)
            && (!printAccurate || !Self.organic(p.lattice) || layingExact || (!laying && organicQuality != .draft))   // ★ 11-21
    }
    /// The lattice on screen (a Draft too) was laid from these inputs.
    func sameInputs(project p: ProjectModel, stress: Stress) -> Bool {
        guard let path = p.importedFile?.path else { return bars == nil }
        return path == sessionPath && Self.settings(p, referenceMPa: stress.referenceMPa) == lastSettings && stress.key == self.stress.key
            && Self.organicKey(p) == lastOrganicKey
    }

    /// ★ his 11-22 ("Can you make the Mac send the lattice over to the iPad after it's done?"; his pick: only on his press):
    /// the file's inputs from the lattice on screen, a Draft too — its groups asked exact (the file job lays the exact lattice
    /// whatever it is asked; every other part of the ask is the exact's own), and the stress that lay followed. No iPad exact.
    public func organicMacInputs(project p: ProjectModel, stress: Stress = Stress())
        async throws -> (groups: [LatticeLayoutSession.OrganicGroup], tensor: Data) {
        if laying { throw OrganicFileWait.laying }
        let draft = organicDraftGroups?.map { g -> LatticeLayoutSession.OrganicGroup in var g = g; g.ask.quality = .exact; return g }
        guard let groups = organicLaidGroups ?? draft, let session else { throw OrganicFileWait.notLaid }
        guard sameInputs(project: p, stress: stress) else { throw OrganicFileWait.outOfDate }
        try await matchSessionTensor(session, groups: groups)
        let tensor = try await session.tensorFile()
        return (groups, tensor)
    }

    /// ★ his 11-22: the print file's own lattice, from the Mac, drawn in place of the lattice on screen (same body, opened the
    /// same way). False when the lattice on screen is no longer the one the file was made from.
    @discardableResult
    public func showFile(_ m: LatticeFileMesh, project p: ProjectModel, stress: Stress = Stress()) -> Bool {
        guard !laying, var b = bars, sameInputs(project: p, stress: stress) else { return false }
        token &+= 1
        b.token = token
        b.fileMesh = m
        b.dimmed = false
        if let w = shownWhere { shownWhere = (token, w.1) }
        bars = b
        return true
    }
    /// Whether the print file's lattice is what is drawn now.
    public var showsFile: Bool { bars?.fileMesh != nil }

    /// ★ Organic cut 2 (the export, handover f): what the print file is made from — the SAME groups the exact preview laid for
    /// these inputs, and the stress that lay followed (as set, or as the synthetic stress filled it) as core's file. nil: no
    /// exact lay of these inputs yet (the page lays it first), or still laying.
    public func organicFileInputs(project p: ProjectModel, stress: Stress = Stress())
        async throws -> (groups: [LatticeLayoutSession.OrganicGroup], tensor: Data) {
        if laying { throw OrganicFileWait.laying }
        guard let groups = organicLaidGroups, let session else { throw OrganicFileWait.notLaid }
        guard isCurrent(project: p, stress: stress) else { throw OrganicFileWait.outOfDate }
        try await matchSessionTensor(session, groups: groups)   // ★ his pick 11-21: a remembered lattice's own stress
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
                       delay: Duration = .zero, checkNozzle: Bool = false, exact: Bool = false) {
        guard on else { clear(); return }
        fixProject = p   // ★ notes28: the solid pop-up's fixes are taken on this part
        guard let path = p.importedFile?.path else { problem = Self.noPartLine; bars = nil; return }
        retargetIfSamePart(path)   // ★ his iPad notes 11-23: the version moved to its next number, the same part
        if path != sessionPath || box == nil { box = Self.box(p.importedMesh?.vertices ?? []) }
        if path != cutSurface?.path { cutMesh = p.importedMesh }
        let solidChanged = solid != solidWanted
        solidWanted = solid
        notes = Self.notes(p.lattice, hasStress: stress.field != nil)
        let s = Self.settings(p, referenceMPa: stress.referenceMPa)
        let stressMoved = stress.key != self.stress.key
        self.stress = stress
        let ok = Self.organicKey(p)
        // ★ his pick 11-21: the solid view asked of a remembered lattice: its map comes from a lay
        let mapNeedsLay = solidChanged && solid && shownRestored && bars?.solid == nil
        // ★ his ask 11-21: the exact lattice asked (Print-accurate preview, or the print file: `exact`) where a Draft stands in
        let accurate = printAccurate || exact, isOrganic = Self.organic(p.lattice)
        let wantsExact = accurate && isOrganic && ((laying && !accurateAtLay) || (!laying && bars != nil && organicQuality == .draft))
        if path == sessionPath, s == lastSettings, ok == lastOrganicKey, !stressMoved, task != nil || bars != nil, !mapNeedsLay,
           !wantsExact {
            if solidChanged, task == nil || bars != nil { solidToggled() }
            else if solid, !laying, let g = bars?.solid, !isOrganic, g.smooth != Self.cutSmoothWanted(lattice: latticeAtLay, printAccurate: printAccurate) {
                mapTask?.cancel()   // ★ notes28: Print-accurate preview switched — the cut drawn the other way (its map again)
                mapTask = Task { [weak self] in await self?.addMap(again: true) }
            }
            if checkNozzle, nozzleState == .notAsked, bars != nil { self.checkNozzle() }   // Refresh with nothing changed
            return
        }
        // ★ his pick 11-21 ("absolutely"): a lattice already made for exactly these inputs is shown at once, no lay
        adoptSaved(p, path: path, s)   // ★ his iPad notes 11-23: ... and the one this version's folder keeps
        if restoreRemembered(p, path: path, s, ok, accurate: accurate) { return }
        openingAfterRestore?.cancel(); openingAfterRestore = nil   // ★ 11-23: the lay opens the session itself
        let before = inputsAtLay, wasLaying = laying
        take(p, s, ok)
        shownRestored = false
        // the Draft of exactly these inputs is on screen: the exact lattice alone follows it
        let draftOnScreen = isOrganic && accurate && !wasLaying && organicQuality == .draft && before != nil && before == inputsAtLay
        accurateAtLay = accurate
        task?.cancel()
        stopGrowth()   // ★ his 11-22: a new lay grows from nothing again
        laying = true
        nozzleWanted = checkNozzle
        // ★ his pick 11-21 ("Let's do this one. Absolutely."): every Organic lay shows its Draft first (marked, the last
        // lattice dimmed until it lands), then the exact lattice replaces it (before: only Live preview's dragged slider)
        // ★ his ask 11-21: Print-accurate preview off, the Draft is all (the exact lattice is made with the print file)
        let draftFirst = isOrganic && !Self.controlNoDraftFirst && !draftOnScreen
        let q: LatticeLayoutSession.Organic.Quality = draftFirst ? .draft : .exact
        // ★ his 11-22: the ring on the Lattice button is the processing graphic, for every type
        layProgress = LayProgress(quality: q, started: Date(), expectedS: layWallS[timeKey(path, q)], draftShown: draftOnScreen)
        task = Task { [weak self] in
            if delay > .zero {   // ★ Live preview: wait for him to stop changing it
                try? await Task.sleep(for: delay)
                if Task.isCancelled { return }
            }
            await self?.lay(path: path, s, draft: draftFirst)
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
        stopGrowth()   // ★ his 11-22
        mapTask?.cancel(); mapTask = nil
        nozzleTask?.cancel(); nozzleTask = nil; nozzleWanted = false; nozzleState = .notAsked
        nozzleSession?.close(); nozzleSession = nil; nozzlePath = nil; nozzleLine = nil; solidReason = nil
        solidPopUpKey = nil; nozzleAskedByPopUp = false; popUpWatch = nil; solidPopUpUp = false   // ★ notes28
        session?.close(); session = nil; sessionPath = nil; lastSettings = nil; sessionStressKey = nil; nozzleStressKey = nil
        sessionTensorKey = nil; organicLimits = nil; organicQuality = nil; organicNumbers = nil   // ★ Organic cut 1
        organicLaidGroups = nil; organicDraftGroups = nil   // ★ cut 2; ★ his 11-22
        bars = nil; laid = nil; problem = nil; timing = nil; laying = false; places = []
        layTimingEnds(.cancelled, "the preview was closed")   // ★ his 11-22 (GenerationTimingLog)
        layProgress = nil; shownRestored = false   // ★ his pick 11-21 (what was remembered stays, for this part)
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

    // MARK: ★ his pick 11-21 ("absolutely"): finished previews remembered

    /// Everything an Organic lay reads: the part, the page's settings as laid and the stress. Equal inputs, the same lattice
    /// (the engine's lay is pinned). It holds the WHOLE lattice settings, not only the ones known to matter: a setting it
    /// missed would show an old lattice, one too many only lays again.
    struct LayInputs: Equatable {
        var path: String
        var settings: LatticeLayoutSession.Settings
        var lattice: LatticeSettings
        var pageManual: Bool
        var flush: [Int32]
        var layer: Double
        var keys: [Int32: String]
        var groups: [Int32: UUID]
        var groupOrder: [UUID]
        var stress: Stress
    }
    static func layInputs(_ p: ProjectModel, path: String, _ s: LatticeLayoutSession.Settings, stress: Stress) -> LayInputs {
        LayInputs(path: path, settings: s, lattice: p.lattice, pageManual: p.latticePageManual, flush: flushFaces(p),
                  layer: p.printParams.layerHeightMM > 0 ? p.printParams.layerHeightMM : 0.2, keys: regionKeys(p),
                  groups: regionGroups(p), groupOrder: p.latticeAreaGroups.map(\.id), stress: stress)
    }
    /// One finished exact Organic preview: what the page showed, and what the print file is made from.
    struct Remembered {
        var inputs: LayInputs
        var bars: LatticeLayoutBarsInputs
        var laid: LatticeLayoutColours.Laid?
        var timing: Timing?
        var numbers: OrganicNumbers?
        var problem: String?
        var notes: [String]
        var groups: [LatticeLayoutSession.OrganicGroup]
        var walls: [(region: Int32, foci: Int)]
        var wallVerdicts: [String: Bool]
        var autoLimits: LatticeOrganicLook.Limits?
        var groupLimits: [UUID: LatticeOrganicLook.Limits]
        var struts: Int
        /// A Draft (the quick stand-in) or the exact lattice; a Draft never stands for Print-accurate preview.
        var quality: LatticeLayoutSession.Organic.Quality
    }
    /// Most recent first; at most `rememberedMost`, and no more struts in all than `rememberedStrutsMost` (the iPad's memory).
    private var remembered: [Remembered] = []
    /// ★ his iPad notes 11-23 (LatticePreviewStore): the remembered lattice read back from the version's folder (its token), the
    /// inputs the folder was last asked for and had nothing for, and the part's session opening behind a lattice shown so.
    private var adoptedToken: Int?
    private var diskMiss: LayInputs?
    private var openingAfterRestore: Task<Void, Never>?
    public static let rememberedMost = 4
    public static let rememberedStrutsMost = 600_000
    private var inputsAtLay: LayInputs?
    /// The lattice on screen came from memory (the session's last lay is another one).
    private var shownRestored = false
    /// The synthetic stress walls of the lattice on screen (the print file's stress is made the same way).
    private var shownWalls: [(region: Int32, foci: Int)] = []
    /// ★ his pick 11-21: how long each kind of Organic lay took on this part (s), keyed "path|type|quality".
    private var layWallS: [String: Double] = [:]
    private var typeAtLay = ""

    private func timeKey(_ path: String, _ q: LatticeLayoutSession.Organic.Quality) -> String {
        "\(path)|\(typeAtLay)|\(q == .draft ? "draft" : "exact")"
    }

    private func remember(_ r: Remembered) {
        guard !Self.controlForget else { return }
        if r.quality == .draft, remembered.contains(where: { $0.inputs == r.inputs && $0.quality == .exact }) { return }
        var kept = [r]
        var struts = r.struts
        for e in remembered where e.inputs != r.inputs && kept.count < Self.rememberedMost
            && struts + e.struts <= Self.rememberedStrutsMost {
            kept.append(e); struts += e.struts
        }
        remembered = kept
        LatticePreviewStore.save(r)   // ★ his iPad notes 11-23: kept in the version's folder too
    }

    /// ★ his pick 11-21: a lattice already made for exactly these inputs, shown at once (no lay, nothing dimmed). False: none
    /// remembered, or it would need the solid view's map, which only a lay makes.
    private func restoreRemembered(_ p: ProjectModel, path: String, _ s: LatticeLayoutSession.Settings, _ ok: String?,
                                   accurate: Bool) -> Bool {
        guard Self.organic(p.lattice), !Self.controlForget else { return false }
        let key = Self.layInputs(p, path: path, s, stress: stress)
        guard let i = remembered.firstIndex(where: { $0.inputs == key && $0.quality == .exact })
                ?? (accurate ? nil : remembered.firstIndex(where: { $0.inputs == key })) else { return false }
        // ★ his iPad notes 11-23: read back from the version's folder, it is shown before the part's session is open (it opens
        // behind it, and the solid view's map follows) — no lay
        let fromDisk = adoptedToken != nil && remembered[i].bars.token == adoptedToken
        guard fromDisk || (session != nil && sessionPath == path) else { return false }
        if fromDisk, bars?.token == remembered[i].bars.token, openingAfterRestore != nil { return true }   // on screen already
        if solidWanted, remembered[i].bars.solid == nil, !fromDisk { return false }
        let r = remembered.remove(at: i)
        remembered.insert(r, at: 0)
        task?.cancel(); task = nil
        stopGrowth()   // ★ his 11-22: a remembered lattice shows no growth
        mapTask?.cancel(); mapTask = nil
        take(p, s, ok)
        accurateAtLay = r.quality == .exact
        var b = r.bars
        b.dimmed = false
        if !solidWanted { b.solid = nil }
        bars = b; laid = r.laid; timing = Self.inStrands(r.timing, r.numbers)   // ★ notes25
        shownWhere = (b.token, MapWhere(path: r.inputs.path, settings: r.inputs.settings, stressKey: r.inputs.stress.key))   // ★ 11-22
        organicQuality = r.quality; organicNumbers = r.numbers; problem = r.problem; notes = r.notes
        organicLaidGroups = r.quality == .exact ? r.groups : nil; organicRefusals = []
        organicDraftGroups = r.quality == .draft ? r.groups : nil   // ★ his 11-22
        organicWallVerdicts = r.wallVerdicts
        organicAutoLimits = r.autoLimits; organicGroupLimits = r.groupLimits
        shownWalls = r.walls; shownRestored = true
        layTimingEnds(.cancelled, "a remembered lattice was shown")   // ★ his 11-22 (GenerationTimingLog)
        laying = false; layProgress = nil
        Self.remembersShown += 1
        layTimingRestored(r)
        if fromDisk { openBehindRestored(path: path) }   // ★ his iPad notes 11-23
        return true
    }

    /// ★ his pick 11-21, for Click to refresh: a changed setting whose lattice was made before shows it at once (true); false:
    /// the preview is out of date (Refresh Lattice).
    public func showRemembered(project p: ProjectModel, solid: Bool, stress: Stress) -> Bool {
        guard let path = p.importedFile?.path, Self.organic(p.lattice) else { return false }
        let wasSolid = solidWanted, wasStress = self.stress
        solidWanted = solid; self.stress = stress
        if restoreRemembered(p, path: path, Self.settings(p, referenceMPa: stress.referenceMPa), Self.organicKey(p),
                             accurate: printAccurate) { return true }
        solidWanted = wasSolid; self.stress = wasStress
        return false
    }

    /// What the next lay reads off the page (the update's own, and a remembered lattice's).
    private func take(_ p: ProjectModel, _ s: LatticeLayoutSession.Settings, _ ok: String?) {
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
        typeAtLay = Self.organic(p.lattice) ? Self.organicButtonType(p) : ""
        inputsAtLay = p.importedFile.map { Self.layInputs(p, path: $0.path, s, stress: stress) }
        timingInputsAtLay = GenerationTimingLog.Inputs.of(p)   // ★ his 11-22: what went in (values only; encoded off the main thread)
    }

    /// The print file's stress for a remembered lattice: the session's tensor made as that lay made it.
    private func matchSessionTensor(_ session: LatticeLayoutSession, groups: [LatticeLayoutSession.OrganicGroup]) async throws {
        guard shownRestored, let s = lastSettings else { return }
        if sessionTensorKey != stress.key, let f = stress.field, !f.stressTensor.isEmpty {
            try await session.setTensor(voigt: f.stressTensor, nx: f.nx, ny: f.ny, nz: f.nz, origin: f.origin, spacingMM: f.spacingMM)
            sessionTensorKey = stress.key
        }
        if !shownWalls.isEmpty || syntheticOn {
            _ = try await session.synthetic(s, groups: groups, walls: shownWalls)
            syntheticOn = !shownWalls.isEmpty
        }
        shownRestored = false   // the session now holds what is on screen
    }

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
    /// ★ his pick 11-21: the lattice on screen is dimmed while an Organic lay goes, until this lay's own Draft lands.
    public static func dims(_ p: LayProgress?) -> Bool { p.map { !$0.draftShown } ?? false }

    public func drawn(stressField field: LatticeDemandField?, stressKey: Int) -> LatticeLayoutBarsInputs? {
        guard var b = bars else { return nil }
        b.dimmed = Self.dims(layProgress)   // ★ his pick 11-21: the last lattice, dimmed while the new one lays
        guard let laid, laid.token == b.token else { return b }
        let grade = latticeAtLay.gradingMode.fitsShape
        let organic = latticeAtLay.isOrganic
        let key = [b.token, field == nil ? 0 : stressKey, grade ? 1 : 0, latticeAtLay.topologyID.hashValue, organic ? 1 : 0,
                   LatticeLayoutColours.controlOneColour ? 1 : 0, b.solid?.token ?? -1, b.hidden ? 1 : 0, b.dimmed ? 1 : 0,
                   b.solid?.smooth == true ? 1 : 0]   // ★ notes28
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

    /// The part's session, opened once per part: the lay's, and the Lattice page's Auto numbers (his 11-22).
    private func openSession(path: String) async throws -> LatticeLayoutSession? {
        if session == nil || sessionPath != path {
            session?.close()
            let opened = try await LatticeLayoutSession.open(path: path)
            guard !Task.isCancelled else { opened.close(); return nil }
            session = opened; sessionPath = path; openMS = opened.info.msOpen; sessionStressKey = nil; sessionTensorKey = nil; organicLimits = nil
            syntheticOn = false   // a new session holds the stress as given
            remembered.removeAll { $0.inputs.path != path }   // ★ his pick 11-21: another part's lattices are of no use
        }
        return session
    }

    /// ★ his 11-22 (the 2 mm / 3.5 mm / 2 mm "dance"): the Lattice page measures this part's Auto numbers when it opens, so its
    /// fields and its sample never depend on whether a lattice was laid yet. Cheap when they are measured already.
    public func measureLimits(project p: ProjectModel) {
        guard Self.organic(p.lattice), let path = p.importedFile?.path, !laying, limitsTask == nil else { return }
        let s = Self.settings(p, referenceMPa: stress.referenceMPa)
        let line = s.beadMM > 0 ? s.beadMM : 0.45
        if let o = organicLimits, path == sessionPath, Self.sameWhere(o.key, s), o.line == line {
            organicAutoLimits = o.limits; organicGroupLimits = o.groups; return
        }
        let groups = Self.regionGroups(p)
        measuringLimits = true
        limitsTask = Task { [weak self] in
            defer { self?.measuringLimits = false; self?.limitsTask = nil }
            do {
                guard let self, let session = try await self.openSession(path: path) else { return }
                _ = try await self.measure(session, s, groups: groups)
            } catch {
                NSLog("TopOpt Auto numbers failed: %@", (error as? TopOptError)?.message ?? "\(error)")   // the log only
            }
        }
    }

    /// Auto's numbers for these settings' woven regions, whole and per group, once per "where" and line. false: cancelled.
    private func measure(_ session: LatticeLayoutSession, _ s: LatticeLayoutSession.Settings, groups regionGroup: [Int32: UUID])
        async throws -> Bool {
        let line = s.beadMM > 0 ? s.beadMM : 0.45   // the print line (the settings' bead)
        let weave = s.regions.filter { $0.weave && !$0.noLattice }.map(\.id)
        var byGroup: [UUID: [Int32]] = [:]
        for id in weave { if let g = regionGroup[id] { byGroup[g, default: []].append(id) } }
        if organicLimits == nil || !Self.sameWhere(organicLimits!.key, s) || organicLimits!.line != line {
            func limits(_ ids: [Int32]) async throws -> LatticeOrganicLook.Limits {
                try await session.sweepLimits(s, regions: ids, lineMM: line).map(LatticeOrganicLook.Limits.init)
                    ?? .init(strutLowerMM: 0, strutUpperMM: 0, strutAutoMM: 0, cellLowerMM: 0, cellUpperMM: 0, cellAutoMM: 0,
                             measured: false)
            }
            let whole = weave.isEmpty ? nil : try await limits(weave)
            var groups: [UUID: LatticeOrganicLook.Limits] = [:]
            for (g, ids) in byGroup { groups[g] = try await limits(ids) }
            guard !Task.isCancelled else { return false }
            organicLimits = (s, line, whole, groups)
        }
        organicAutoLimits = organicLimits?.limits   // (before Look: the page applies each look's own)
        organicGroupLimits = organicLimits?.groups ?? [:]
        return true
    }

    private func lay(path: String, _ s: LatticeLayoutSession.Settings, draft: Bool = false) async {
        Self.laysStarted += 1
        layTimingBegins(Self.organic(latticeAtLay) && draft ? .draft : .exact)   // ★ his 11-22: the lay really begins
        do {
            var t0 = Date()
            if let t = limitsTask { await t.value }   // ★ his 11-22: the page's Auto numbers first (one session, never two)
            layStages["limitsWaitMS"] = Self.ms(since: t0)
            guard !Task.isCancelled, let session = try await openSession(path: path) else { return }
            t0 = Date()
            sessionStressKey = try await Self.give(stress, to: session, holding: sessionStressKey)
            layStages["stressGiveMS"] = Self.ms(since: t0)
            layStages["openMS"] = openMS
            if Self.organic(latticeAtLay) {   // ★ Organic cut 1: the weave's own lay
                let watch = watchGrowth(session)   // ★ his 11-22: its vines drawn as they are laid, until it ends
                defer { watch?.stop() }
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
            if r.barCount > 0 { problem = nil }   // ★ notes28: nothing laid is said after the reason is read (below)
            layStages["readMS"] = r.msRead; layStages["cellsMS"] = r.msCells; layStages["barsMS"] = r.msBars   // ★ his 11-22
            laying = false; layProgress = nil
            layWallS[timeKey(path, .exact)] = (openMS + r.msRead + r.msCells + r.msBars) / 1000
            if solidWanted { await addMap() }
            nozzleTask?.cancel(); nozzleLine = nil; nozzleState = .notAsked
            await solidReasonCheck(lattice: latticeAtLay)   // ★ his ruling 11-14: why it is solid (one coarse map, cheap)
            // ★ notes28 (img 76): nothing laid — the solid pop-up names the real reason (raised by the check above); the general
            // line only when the engine gives none
            if r.barCount == 0, !Task.isCancelled { problem = solidReason == nil || Self.controlNoSolidPopUp ? Self.noFitLine : nil }
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
            layProgress = nil
        }
    }

    /// ★ Organic cut 1: the weave's lay. The tensor in (once per stress), Auto's numbers (core's, measured before the lay,
    /// once per regions and line), the lay (Draft while a slider moves, then Exact), its runs as
    /// the bars pass's segments. No stress yet: one line (the page runs the stress check first).
    private func layOrganic(_ session: LatticeLayoutSession, path: String, _ s: LatticeLayoutSession.Settings, draft: Bool,
                            afterDraft: Bool = false) async throws {
        if afterDraft {   // ★ his pick 11-21: the Draft is on screen, marked; the exact lattice is made
            layProgress = LayProgress(quality: .exact, started: Date(), expectedS: layWallS[timeKey(path, .exact)], draftShown: true)
            layTimingBegins(.exact)   // ★ his 11-22: the Draft's line is written; the exact lattice's begins
        }
        // ★ his 11-22 (img 45, 47: "The draft lattice doesn't cut the faces of the solid"): the Draft on screen is cut open
        // while its exact lattice is made — its own map first (the session's last lay is that Draft), the very map the exact
        // lattice opens its faces with (`mapFor` keeps it for it). Never the exact lay.
        let here = MapWhere(path: path, settings: s, stressKey: stress.key)
        if !draft, layProgress?.draftShown == true, solidWanted, !Self.controlDraftWaitsForExactMap, let b = bars,
           b.solid?.token != b.token, shownWhere?.token == b.token, shownWhere?.at == here {
            await addMap()
            guard !Task.isCancelled else { return }
        }
        // ★ Auto's numbers first, measured by the engine before any lay or stress (his iPad notes 11-18: the fields showed
        // 0): the whole part's and each group's (E4: the union of its areas), once per "where" and line
        let weave = s.regions.filter { $0.weave && !$0.noLattice }.map(\.id)
        var byGroup: [UUID: [Int32]] = [:]
        for id in weave { if let g = groupsAtLay[id] { byGroup[g, default: []].append(id) } }
        var t0 = Date()
        guard try await measure(session, s, groups: groupsAtLay) else { return }
        layStages["measureMS"] = Self.ms(since: t0)   // ★ his 11-22: each step's time, as it comes
        guard let f = stress.field, !f.stressTensor.isEmpty else {
            problem = Self.organicNeedsStressLine; bars = nil; laying = false; layProgress = nil; return
        }
        guard f.stressTensor.allSatisfy(\.isFinite) else {
            problem = "The stress result holds a value that is not a number: run the stress check again"
            bars = nil; laying = false; layProgress = nil; return
        }
        if sessionTensorKey != stress.key {
            t0 = Date()
            try await session.setTensor(voigt: f.stressTensor, nx: f.nx, ny: f.ny, nz: f.nz, origin: f.origin, spacingMM: f.spacingMM)
            sessionTensorKey = stress.key
            layStages["setTensorMS"] = Self.ms(since: t0)
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
                groups.append(.init(regions: byGroup[g]!, ask: ask(look, organicLimits?.groups[g]), name: groupNamesAtLay[g]))
                looks.append(look); groupIDs.append(g)
            }
        }
        let grown = looks.contains { $0.modeValue == .grown }
        if let short = Self.organicMemoryShort(mode: grown ? .grown : .traced, availableMB: Self.availableMB()) {
            problem = short; bars = nil; laid = nil; laying = false; layProgress = nil; return   // ★ refused, never a crash
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
            t0 = Date()
            let rep = try await session.synthetic(s, groups: groups, walls: walls)
            layStages["syntheticMS"] = Self.ms(since: t0)
            guard !Task.isCancelled else { return }
            syntheticOn = !walls.isEmpty
            if !rep.refused.isEmpty { return refuse(rep.refused, groupIDs) }
            var verdicts: [String: Bool] = [:]
            for (id, dead) in rep.withoutStress { if let k = keysAtLay[id] { verdicts[k] = dead } }
            organicWallVerdicts = verdicts
        }
        // ★ notes24 (viewer): the growing tubes' widths and how the part opens — by the map on screen when it is this lay's, else
        // by the map made before the lay (his walls-first; `mapAhead`, 362's gridAhead), else in X-ray (LatticeGrowth)
        let fits = Self.mapFor(token: token, at: here, shown: bars, shownWhere: shownWhere) != nil
        let ahead = solidWanted && !fits ? await Self.mapAhead(session, s, box, token: token &+ 1, smooth: true) : nil
        growth.layBegins(groups, lineMM: s.beadMM, opening: .init(solid: solidWanted, mapFits: fits, ahead: ahead),
                         expectedLeftS: layProgress?.expectedLeftS)
        t0 = Date()
        let r = try await session.layOrganic(s, groups: groups)
        layStages["layWallMS"] = Self.ms(since: t0)   // ★ his 11-22: the engine's own times, as they come
        layStages["layMS"] = r.ms; layStages["traceMS"] = r.msTrace
        layStages["readMS"] = r.layout.msRead; layStages["barsMS"] = r.layout.msBars; layStages["strands"] = Double(r.strands)
        guard !Task.isCancelled else { return }
        if !r.refused.isEmpty { organicLaidGroups = nil; organicDraftGroups = nil; return refuse(r.refused, groupIDs) }
        organicRefusals = []
        // ★ cut 2: the groups the EXACT lay laid (the file is that lattice); a draft is not what will be made
        organicLaidGroups = r.quality == .exact ? groups : nil
        organicDraftGroups = r.quality == .draft ? groups : nil   // ★ his 11-22: the Mac makes the print file from these
        token &+= 1
        t0 = Date()
        let seg = Self.segments(r.runs)
        layStages["segmentsMS"] = Self.ms(since: t0)
        // ★ his 11-19 rule ("The drawing follows the print file. Always."): every vine, Grown and the net skin too, as the
        // print file's tubes make them (built off the main thread), cut flat where they reach the part's surface (his 11-20
        // skin note: the file trims every tube to the part)
        let runs = r.runs, held = r.flatEnds   // ★ OS1 B: the rounded ends the print check held flat (Exact)
        let known = cutSurface?.path == path ? cutSurface?.surface : nil
        let mesh = known == nil ? cutMesh.map { ($0.vertices, $0.indices, $0.faceIDs) } : nil
        t0 = Date()
        let (vines, surface) = await Task.detached(priority: .userInitiated) { () -> (OrganicVineShape, OrganicVineShape.CutSurface?) in
            var v = OrganicVineShape.tubes(runs: runs, heldFlat: held)
            let surface = known ?? mesh.map { OrganicVineShape.CutSurface(vertices: $0.0, indices: $0.1, faceIDs: $0.2) }
            if let surface { v.cut(runs: runs, surface: surface) }
            return (v, surface)
        }.value
        layStages["vinesMS"] = Self.ms(since: t0)   // ★ his 11-22: the app's own step (tubes + cut), timed apart
        guard !Task.isCancelled else { return }
        if known == nil, let surface { cutSurface = (path, surface); cutMesh = nil }
        var drawn = LatticeLayoutBarsInputs(token: token, bars: seg.bars, solid: nil, flags: seg.flags)
        drawn.lightFrom = Self.organicLightFrom(grown: grown, netFrom: seg.lightFrom, count: seg.count)
        drawn.vines = vines
        // ★ his 11-22: cut open at once where the map on screen is this lattice's map too (the Draft's, for its exact lattice)
        if solidWanted { drawn.solid = Self.mapFor(token: token, at: here, shown: bars, shownWhere: shownWhere) ?? growth.landedMap(token: token) }   // ★ notes24: or the one made before it
        bars = drawn
        shownWhere = (token, here)
        var l = LatticeLayoutColours.Laid()   // no cells: the key and card read each strut's width and its cell size
        l.bars = seg.bars; l.barFlags = seg.skin; l.barCell = seg.cell; l.barRegion = seg.region; l.token = token
        laid = l
        timing = Timing(openMS: openMS, readMS: r.layout.msRead, cellsMS: r.msTrace, barsMS: r.layout.msBars, bars: seg.count)
        timing?.organicLine = Self.organicTimeLine(mode: grown ? .grown : .traced, draft: r.quality == .draft, ms: r.ms,
                                                   strands: r.strands)   // ★ notes25: strands (the print file's count too)
        organicQuality = r.quality
        organicNumbers = OrganicNumbers(strands: r.strands, segments: seg.count, ms: r.ms, draft: r.quality == .draft,
                                        limitsMeasured: organicLimits?.limits?.measured == true)
        let missing = r.layout.emptyRegions.count
        problem = seg.count == 0 ? Self.noFitLine
            : missing == 1 ? "An area points at faces this part does not have: pick its faces again"
            : missing > 1 ? "\(missing) areas point at faces this part does not have: pick their faces again" : nil
        notes = Self.notes(latticeAtLay, hasStress: true) + (r.quality == .draft ? [Self.draftLine] : []) + r.notes
            + (r.reliefFlushed > 0 ? [Self.reliefFlushedLine(r.reliefFlushed)] : [])   // ★ cut 2 (OJ6)
        // ★ his pick 11-21: a Draft is followed by the exact lattice, so the preview is still laying (the print file waits
        // for the exact one); how long this kind took is kept for the next count-down
        // ★ his ask 11-21: Print-accurate preview on, the exact lattice follows its Draft; off, the Draft is the preview
        let more = r.quality == .draft && accurateAtLay
        laying = more
        if let started = layProgress?.started { layWallS[timeKey(path, r.quality)] = Date().timeIntervalSince(started) }
        if !more {
            layProgress = nil
            if let inputs = inputsAtLay, seg.count > 0 {   // ★ his pick 11-21 ("absolutely"): remembered
                remember(Remembered(inputs: inputs, bars: drawn, laid: l, timing: timing, numbers: organicNumbers, problem: problem,
                                    notes: notes, groups: groups, walls: walls, wallVerdicts: organicWallVerdicts,
                                    autoLimits: organicAutoLimits, groupLimits: organicGroupLimits, struts: seg.count,
                                    quality: r.quality))
            }
        }
        // a draft is followed by the exact lattice when nothing newer came (Print-accurate preview)
        // ★ his 11-18 iPad (the body hid the weave): the solid view's map, cut open around Organic as around the regular lattice
        if !more, solidWanted, !Task.isCancelled { await addMap() }   // (an exact lattice after its Draft keeps the Draft's: no-op)
        if more, !Task.isCancelled { try await layOrganic(session, path: path, s, draft: false, afterDraft: true) }
    }

    /// The Organic lay's line: "Organic Grown · Exact · laid in 3.8 s · 12,605 strands".
    /// ★ notes25 (362's numbers investigation): it counted the drawn tube pieces as "struts" — a third meaning of the word (the
    /// print file counts the engine's bars, the strength check its frame struts). It counts STRANDS now: the same number on the
    /// iPad and in the print file (the Printing tab's "Strands").
    static func organicTimeLine(mode: LatticeOrganicLook.Mode, draft: Bool, ms: Double, strands: Int) -> String {
        let n = NumberFormatter.localizedString(from: NSNumber(value: strands), number: .decimal)
        return String(format: "Organic %@ \u{00B7} %@ \u{00B7} laid in %.1f s \u{00B7} %@ strands", mode.title,
                      draft ? "Draft" : "Exact", ms / 1000, n)
    }

    /// ★ notes25: a lattice kept from before says strands too (its line was saved saying "struts").
    static func inStrands(_ t: Timing?, _ n: OrganicNumbers?) -> Timing? {
        guard var t, let line = t.organicLine, line.hasSuffix(" struts"), let n,
              let cut = line.range(of: " \u{00B7} ", options: .backwards) else { return t }
        t.organicLine = String(line[..<cut.upperBound])
            + NumberFormatter.localizedString(from: NSNumber(value: n.strands), number: .decimal) + " strands"
        return t
    }

    // MARK: ★ his ask 11-22: "prints the time it took and what changes occurred for each generation" (GenerationTimingLog)

    /// The lay under way's line (tied to the ring it shows), its steps' times, and what it was laid from.
    private var layRecord: (pending: GenerationTimingLog.Pending, progress: Date)?
    private var layStages: [String: Double] = [:]
    private var timingInputsAtLay = GenerationTimingLog.Inputs()

    static func ms(since t: Date) -> Double { Date().timeIntervalSince(t) * 1000 }

    /// A lay really begins (after Live preview's wait): its line opens, tied to the ring the button shows.
    private func layTimingBegins(_ q: LatticeLayoutSession.Organic.Quality) {
        guard let p = layProgress else { return }
        layTimingEnds(.cancelled, "a newer lay began")
        var i = timingInputsAtLay
        i.values["quality"] = .text(q == .draft ? "draft" : "exact")
        let waited = Date().timeIntervalSince(p.started)
        if waited > 0.05 { i.values["waitedBeforeS"] = .number(waited) }   // Live preview's half second, the Draft before it
        if let e = p.expectedS { i.values["expectedS"] = .number(e) }
        layStages = [:]
        layRecord = (GenerationTimingLog.shared.begin(q == .draft ? .draft : .exact, inputs: i), p.started)
    }

    /// The ring moved on: the lay it belonged to ended — the exact lattice following its Draft (done), a newer change
    /// (cancelled), or nothing laying any more (done, or failed with the page's own line).
    private func layTimingMoved(from old: LayProgress?) {
        guard let r = layRecord, let old, old.started == r.progress, layProgress?.started != old.started else { return }
        layRecord = nil
        let outcome: GenerationTimingLog.Outcome, reason: String?
        if let new = layProgress {
            (outcome, reason) = old.quality == .draft && new.quality == .exact && new.draftShown ? (.done, nil) : (.cancelled, "a newer change")
        } else if bars == nil, let p = problem {
            (outcome, reason) = (.failed, p)
        } else {
            (outcome, reason) = (.done, problem)
        }
        GenerationTimingLog.shared.end(r.pending, outcome, reason: reason, struts: outcome == .done ? timing?.bars : nil,
                                       stages: layStages)
    }

    /// The lay under way stopped for a reason the ring cannot tell (closed, a remembered lattice shown instead).
    private func layTimingEnds(_ outcome: GenerationTimingLog.Outcome, _ why: String) {
        guard let r = layRecord else { return }
        layRecord = nil
        GenerationTimingLog.shared.end(r.pending, outcome, reason: why, stages: layStages)
    }

    /// A lattice made before, shown again with no lay: a "restored" line, no lay time.
    private func layTimingRestored(_ r: Remembered) {
        var i = timingInputsAtLay
        i.values["quality"] = .text(r.quality == .draft ? "draft" : "exact")
        let p = GenerationTimingLog.shared.begin(.restored, inputs: i)
        GenerationTimingLog.shared.end(p, .done, struts: r.struts, stages: ["layMS": 0])
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
            return LatticeRefusalWords.line(r, text: t)   // ★ his 11-22: what is wrong and how to fix it
        }
        problem = texts.first.map { texts.count > 1 ? $0 + " (and \(texts.count - 1) more)" : $0 }
        organicRefusals = refused
        bars = nil; laid = nil; laying = false; layProgress = nil
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

    /// ★ notes25 (D10, his 11-23 img 4: "Structural can't lattice the glowing walls" — and no wall glowed): on the new engine the
    /// thin-wall pop-up had its finding but no glow (the glow's mask was the old bake's). The glow from THIS lay: core's own
    /// answer for each place of a coarse grid over the part (`whereAt`, the last layout's Why) — the places he asked to lattice
    /// that it left solid because no cell fits or the wall is too thin for one (`wallTooThin`, `noCellFits`) — made into the
    /// part's per-vertex tints by the old glow's own look (LatticeThinWallGlow: those walls electric blue, the rest dimmed).
    /// [] when there is no lay, it is laying, or no such place.
    public func thinWallGlow(mesh: ViewerMesh) async -> [Float] {
        guard let session, let box, !laying else { return [] }
        return await Self.solidGlow(session, box, mesh: mesh)
    }
    /// The glow of the session's last lay (★ notes28: its own function, so a test can light a part laid on its own session).
    static func solidGlow(_ session: LatticeLayoutSession, _ box: (lo: SIMD3<Float>, hi: SIMD3<Float>),
                          mesh: ViewerMesh) async -> [Float] {
        let ext = simd_max(box.hi - box.lo, SIMD3(repeating: 0.1))
        let voxel = Swift.max(0.5, Float(cbrt(Double(ext.x * ext.y * ext.z) / Self.glowPoints)))
        let nx = Int((ext.x / voxel).rounded(.up)) + 3, ny = Int((ext.y / voxel).rounded(.up)) + 3
        let nz = Int((ext.z / voxel).rounded(.up)) + 3
        let origin = box.lo - SIMD3(repeating: voxel)   // voxel (0,0,0)'s centre: a voxel of air all round
        var points: [SIMD3<Float>] = []
        points.reserveCapacity(nx * ny * nz)
        for z in 0..<nz { for y in 0..<ny { for x in 0..<nx {
            points.append(origin + SIMD3(Float(x), Float(y), Float(z)) * voxel)
        } } }
        guard let at = try? await session.whereAt(points), at.count == points.count, !Task.isCancelled else { return [] }
        let grid = LatticeVoxelGrid(nx: nx, ny: ny, nz: nz, origin: origin, spacing: SIMD3(repeating: voxel), values: [])
        // ★ notes28 ("Glow them too"): and the engine's answer just under each triangle's middle, either side (the mesh's
        // winding is mixed): a region thinner than the grid's voxel (a shallow face prism) and a big face's middle glow too
        let tris = mesh.indices.count / 3
        var mids: [SIMD3<Float>] = []
        mids.reserveCapacity(2 * tris)
        for t in 0..<tris {
            func p(_ k: Int) -> SIMD3<Float> {
                let i = Int(mesh.indices[3 * t + k]) * 3
                return SIMD3(mesh.positions[i], mesh.positions[i + 1], mesh.positions[i + 2])
            }
            let a = p(0), b = p(1), c = p(2)
            let cr = simd_cross(b - a, c - a)
            let n = simd_length(cr) > 1e-12 ? simd_normalize(cr) : SIMD3<Float>(0, 0, 1)
            let m = (a + b + c) / 3
            mids.append(m - n * Self.glowProbeMM); mids.append(m + n * Self.glowProbeMM)
        }
        let under = Self.controlGlowGridOnly ? [] : ((try? await session.whereAt(mids)) ?? [])
        guard !Task.isCancelled else { return [] }
        let tints = await Task.detached(priority: .userInitiated) { () -> [Float] in
            let thin = at.map { $0.why == .wallTooThin || $0.why == .noCellFits }
            let lit: [Bool]? = under.count == 2 * tris ? (0..<tris).map { t in
                [under[2 * t].why, under[2 * t + 1].why].contains { $0 == .wallTooThin || $0 == .noCellFits }
            } : nil
            guard thin.contains(true) || lit?.contains(true) == true else { return [] }
            let inside = at.map { $0.why != .outside }
            return LatticeThinWallGlow.vertexTints(mesh: mesh, grid: grid,
                                                   field: LatticeThinWallGlow.field(thin: thin, inside: inside, grid: grid),
                                                   triangleLit: lit)
        }.value
        var lit = 0, k = 7
        while k < tints.count { if tints[k] > 0.03 { lit += 1 }; k += 8 }
        Self.lastGlowLit = lit
        return tints
    }
    /// About how many places the glow asks core about (a coarse grid; the glow is soft).
    static let glowPoints = 120_000.0
    /// ★ notes28: how far under a triangle's middle the glow asks (mm).
    static let glowProbeMM: Float = 0.25
    /// RED CONTROL (tests): the glow from the coarse grid alone (before notes28: a 1 mm face prism on his pad never glowed).
    nonisolated(unsafe) public static var controlGlowGridOnly = false
    /// Test hook: how many of the part's vertices the last glow lit.
    nonisolated(unsafe) static var lastGlowLit = 0

    /// ★ his ruling 11-14: why asked-for lattice is solid, and the fixes (after every layout: one coarse map).
    private func solidReasonCheck(lattice: LatticeSettings) async {
        guard let session, let box, !Task.isCancelled else { return }
        if let rep = try? await Self.unheldReport(session, box), !Task.isCancelled {
            solidReason = SolidReason.of(share: rep.share, nocell: rep.nocell, lattice: lattice)
        } else {
            solidReason = nil
        }
        if !Task.isCancelled { raiseSolidPopUpIfNew() }   // ★ notes28
    }

    // MARK: ★ notes28 — the solid places said in a centred pop-up, never at the bottom (his 11-21 rule; his 11-24 "Glow them too")

    /// ★ notes28 (his 11-24: the lattice view "should default to 'on' in the Lattice stage"): the stage wants its lattice view
    /// on (set on entering the stage; his tap that turns it off clears it). Kept here, the stage's own model, so the workspace
    /// holds no more state of its own (the iPad's main-thread stack).
    public var latticeViewWanted = false

    /// The part the pop-up's fixes are taken on (the page's own, as `update` was last called with it).
    private weak var fixProject: ProjectModel?
    /// The solid pop-up is up: the places he asked to lattice that stayed solid glow while it is (the workspace reads it).
    @Published public private(set) var solidPopUpUp = false
    private var solidPopUpID: UUID?
    /// The reason last raised (part, cause, all of it or some): a lay that keeps it raises nothing more; one without a reason
    /// clears it, so the same reason coming back is said again.
    private var solidPopUpKey: String?
    private var popUpWatch: AnyCancellable?
    /// The nozzle check was asked from the pop-up: its answer comes back in one.
    private var nozzleAskedByPopUp = false
    /// RED CONTROL (tests): no solid pop-up (before notes28: its words were the bottom-centre box, the general line popped up).
    nonisolated(unsafe) public static var controlNoSolidPopUp = false

    /// ★ notes28 (his 11-24, "Glow them too"): whether this lay's solid places are made into the glow — for the Structural
    /// thin-wall pop-up (as before) and for the solid pop-up, whatever its reason (a too shallow region among them; the glow
    /// lights every place he asked to lattice that stayed solid: `thinWallGlow`'s "no cell fits" is core's D14 solid, all its
    /// reasons). RED CONTROL `controlGlowThinWallsOnly`: thin walls only (before: a shallow region never glowed).
    static func glowWanted(thinWalls: Bool, solidPopUp: Bool) -> Bool {
        thinWalls || (solidPopUp && !controlGlowThinWallsOnly)
    }
    nonisolated(unsafe) public static var controlGlowThinWallsOnly = false
    /// Tests: how many solid pop-ups were raised.
    public static private(set) var solidPopUpsRaised = 0

    /// After a lay's reason is read: its pop-up, when the reason is new for this part — unless the Structural thin-wall pop-up
    /// owns this case (walls too thin for Structural's cells: LatticeThinWallPrompt, the workspace's own card).
    private func raiseSolidPopUpIfNew() {
        guard let r = solidReason else { solidPopUpKey = nil; return }
        guard !Self.controlNoSolidPopUp, let p = fixProject else { return }
        if WorkspacePlaceholder.thinWalls(r, project: p, floorCellMM: laid?.floorCellMM ?? 0) != nil {
            if solidPopUpUp { AppPopups.shared.current = nil }   // an earlier reason's pop-up: the thin-wall one says this
            solidPopUpKey = nil
            return
        }
        let key = "\(sessionPath ?? "")|\(r.cause.rawValue)|\(SolidReason.percent(r.share) >= 100)"
        guard key != solidPopUpKey else { return }
        solidPopUpKey = key
        raiseSolidPopUp(r, nozzleAnswer: nil)
    }

    /// The pop-up: what is solid and why, the fix that fits it, its fix taps, the 0.2 mm nozzle check (his pick 11-16 (5)),
    /// and OK. `nozzleAnswer`: the check's answer, said under the reason (its button gone).
    private func raiseSolidPopUp(_ r: SolidReason, nozzleAnswer: String?) {
        var text = SolidPopUp.text(r, lattice: latticeAtLay)
        if let a = nozzleAnswer { text += "\n\n" + a }
        var acts: [(title: String, run: () -> Void)] = r.fixes.map { f in
            (f.title, { [weak self] in self?.takeFix(f) })
        }
        if nozzleAnswer == nil, nozzleOffered { acts.append((LatticePreviewMode.nozzleCheck, { [weak self] in self?.checkNozzleFromPopUp() })) }
        acts = Array(acts.prefix(3))
        let popups = AppPopups.shared
        let title = SolidPopUp.title(r)
        if acts.count >= 2 {
            popups.choose(title, text, first: acts[0], second: acts[1], third: acts.count > 2 ? acts[2] : nil, dismiss: "OK")
        } else {
            popups.show(title, text, action: acts.first)
        }
        Self.solidPopUpsRaised += 1
        watchSolidPopUp(popups.current?.id)
    }

    /// Whether the pop-up offers the 0.2 mm nozzle check: not asked yet for the lattice on screen, and the line is wider than a
    /// 0.2 mm nozzle's (a finer one has nothing to say).
    private var nozzleOffered: Bool {
        nozzleState == .notAsked && (lastSettings?.beadMM ?? 0) > Self.fineBeadMM + 0.05
    }

    /// The glow lasts as long as this pop-up: closed (OK, a tap outside, a fix) or replaced, it stops.
    private func watchSolidPopUp(_ id: UUID?) {
        solidPopUpID = id
        solidPopUpUp = id != nil
        popUpWatch = AppPopups.shared.$current.sink { [weak self] now in
            MainActor.assumeIsolated {
                guard let self, now?.id != self.solidPopUpID else { return }
                self.solidPopUpUp = false
                self.solidPopUpID = nil
                self.popUpWatch = nil
            }
        }
    }

    /// A fix tap: taken on the part's lattice settings (the preview lays again on the change).
    private func takeFix(_ f: SolidReason.Fix) {
        guard let p = fixProject else { return }
        SolidReason.apply(f, to: &p.lattice)
    }

    /// The pop-up's "Check a 0.2 mm nozzle": the check runs; its answer comes back in the pop-up.
    func checkNozzleFromPopUp() {
        nozzleAskedByPopUp = true
        checkNozzle()
    }

    /// The nozzle check ended: its answer, in the solid pop-up when its reason still stands (the pop-up comes back with it), or
    /// on its own — when he asked for it, or when it found a finer nozzle worth it (a Refresh's check).
    private func nozzleAnswered(cure: Double?) {
        let asked = nozzleAskedByPopUp
        nozzleAskedByPopUp = false
        guard !Self.controlNoSolidPopUp, asked || nozzleLine != nil else { return }
        let answer = SolidPopUp.nozzleAnswer(cure: cure)
        if let r = solidReason, let p = fixProject, WorkspacePlaceholder.thinWalls(r, project: p, floorCellMM: laid?.floorCellMM ?? 0) == nil {
            raiseSolidPopUp(r, nozzleAnswer: answer)
        } else {
            AppPopups.shared.show(SolidPopUp.nozzleTitle, answer)
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
            let cure = try await Self.cure(main: session, fine: fine, settings: s, box: box)
            guard !Task.isCancelled else { return }
            if let c = cure, c >= Self.worthSaying {
                nozzleLine = String(format: "A 0.2 mm nozzle would lattice %.0f%% of what is solid now", 100 * c)
            }
            nozzleState = .done
            nozzleAnswered(cure: cure)   // ★ notes28: said in the centred pop-up (never a line at the bottom)
        } catch {
            // no line: the preview stands as it is
        }
    }

    // MARK: the solid view's map

    /// What an Organic lattice's map depends on: the part, the settings it was laid with and the stress. The engine's map is
    /// open wherever a weave region is (core's SolidAt: "a weave's lattice is open"), whatever its vines, so it is the same
    /// for the Draft and the exact lattice of these, and for every Look of them.
    struct MapWhere: Equatable {
        var path: String
        var settings: LatticeLayoutSession.Settings
        var stressKey: Int
    }
    /// RED CONTROL (tests): the Draft on screen waits for the exact lattice's own map (before 11-22: its faces stayed whole).
    nonisolated(unsafe) public static var controlDraftWaitsForExactMap = false

    /// ★ his 11-22 (img 45, 47 against 48): the map an Organic lattice laid at `at` opens its faces with, at once — the one on
    /// screen when it was made for the same part, settings and stress (the Draft's for its exact lattice, the last Look's for
    /// a new Look), as this lattice's own (no second map). nil: none fits; the lattice's own map is made (`addMap`).
    static func mapFor(token: Int, at: MapWhere, shown: LatticeLayoutBarsInputs?,
                       shownWhere: (token: Int, at: MapWhere)?) -> LatticeLayoutSolidGrid? {
        guard !controlDraftWaitsForExactMap, let b = shown, var m = b.solid, m.token == b.token, let w = shownWhere,
              w.token == b.token, w.at == at else { return nil }
        m.token = token
        return m
    }

    /// X-ray was switched: off asks for the map (once per layout), on drops it.
    private func solidToggled() {
        guard var b = bars else { return }
        if !solidWanted { b.solid = nil; bars = b; timing?.mapMS = 0; return }
        mapTask?.cancel()   // never the layout's own task: a layout in flight maps itself when it lands
        mapTask = Task { [weak self] in await self?.addMap() }
    }

    private func addMap(again: Bool = false) async {
        guard let session, let box, let b = bars, again || b.solid?.token != b.token else { return }
        do {
            let m = try await Self.map(session, box, token: b.token, smooth: latticeAtLay.isOrganic,
                                       cutSmooth: Self.cutSmoothWanted(lattice: latticeAtLay, printAccurate: printAccurate))   // ★ notes28
            guard !Task.isCancelled, solidWanted, var now = bars, now.token == b.token else { return }
            now.solid = m.grid
            bars = now
            timing?.mapMS = m.ms
            if let i = remembered.firstIndex(where: { $0.bars.token == now.token }) {
                remembered[i].bars.solid = m.grid   // ★ 11-21
                if i == 0 { LatticePreviewStore.save(remembered[0]) }   // ★ his iPad notes 11-23: kept with its map
            }
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
                    smooth: Bool = false, cutSmooth: Bool = false) async throws -> (grid: LatticeLayoutSolidGrid, ms: Double) {
        let (origin, voxel, dims) = mapGeometry(box)   // ★ notes24: shared with `mapAhead`
        let r = try await s.grid(origin: origin, voxel: voxel, dims: dims)
        // ★ his 11-19 note: Organic's cut edges are smooth lines, not the voxels' stair-steps
        var rg = smooth ? LatticeLayoutSolidGrid.smoothed(r.rg, dims: dims) : r.rg
        // ★ notes28 (img 77, "stair stepping on the cut lines of the original part's wall"): the regular lattice's cut, smoothed
        // off the main thread (Print-accurate preview OFF; `cutSmoothWanted`), read linear like Organic's
        if cutSmooth, !smooth {
            let raw = r.rg
            rg = await Task.detached(priority: .userInitiated) { LatticeLayoutSolidGrid.cutSmoothed(raw, dims: dims) }.value
        }
        return (LatticeLayoutSolidGrid(token: token, origin: origin, voxel: voxel, dims: dims, rg: rg, smooth: smooth || cutSmooth),
                r.ms)
    }

    /// ★ notes28 (his iPad notes on release 18, img 77: "Is there no way to vectorize the mechanism to cut the wall? If not, is
    /// there a way to implement anti-aliasing to make the stair-stepping less pronounced? It's on every wall."). Whether the
    /// regular lattice's cut is drawn smooth (`LatticeLayoutSolidGrid.cutSmoothed`, read linear, its edge anti-aliased in the
    /// viewer) or as the map's own voxels. HIS RULE: "The drawing follows the print file. Always." — amended 11-21: with
    /// Print-accurate preview ON. The print file's own cut along a slope steps (0.25 mm columns, measured: Notes28LatticeView-
    /// Tests), so ON the drawing keeps the map's steps; OFF (the default) the quick stand-in draws the straight line. Organic
    /// keeps its own smoothing (`smoothed`).
    static func cutSmoothWanted(lattice l: LatticeSettings, printAccurate: Bool) -> Bool {
        !controlSteppedCut && !l.isOrganic && !printAccurate
    }
    /// RED CONTROL (tests): the regular lattice's cut drawn as the map's voxels always (before notes28).
    nonisolated(unsafe) public static var controlSteppedCut = false

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

    /// ★ cells across a wall (C3-C5) the engine is asked for: Structural five; Aesthetic one with "Allow single-cell members",
    /// else two; his own minimum (control 2) over either. ★ notes25 (D8): the one place this rule lives — the thin-wall
    /// pop-up says these numbers (LatticeThinWallReasons).
    nonisolated public static func minCellsAcross(_ l: LatticeSettings) -> Int32 {
        if let n = l.cellsAcrossMin, n >= 1 { return Int32(n) }   // ★ control 2: his minimum
        return (l.stageMode ?? .structural) == .aesthetic ? (l.singleCellMembers ? 1 : 2) : structuralCellsAcross(l.topologyID)
    }

    /// ★ notes28 (all the strut types): Structural's cells across a wall is the TYPE's own certification floor — core's
    /// measured cells per member (`lattice_cells_per_member_min`: octet 5, sc 4, fcc 5, kelvin 8, bcc / diamond / rhombic
    /// 10) — never the octet's five under another type's name. Five where core gives none (a type it does not certify).
    nonisolated public static func structuralCellsAcross(_ topology: String) -> Int32 {
        let n = TopOptKit.latticeLimits(topology: topology.isEmpty ? "octet" : topology).minCellsPerMember
        return n.isFinite && n >= 1 ? Int32(n.rounded(.up)) : 5
    }

    /// Lattice Setup's settings for core's lattice_layout (read where its rows read them).
    public static func settings(_ p: ProjectModel, referenceMPa: Double = 0) -> LatticeLayoutSession.Settings {
        // ★ notes26: the part-wide half is its own function, so the Lattice page's sample lays by the same rules
        var s = partWide(p.lattice, beadMM: p.printParams.strutLineWidthMM, wallRingMM: p.printParams.wallRingMM,
                         referenceMPa: referenceMPa, percent: { p.latticeDensityPercent(rho: $0, cellMM: $1) })
        let l = p.lattice
        // ★ K3 (his 11-23 notes on release 17: "When I set auto regular lattices, it automatically set quilting=on. That should
        // ALWAYS be off by default unless it is literally impossible to lattice without it. If users want it on, they need to go
        // into manual." "Auto should try to give as thin struts as possible, regardless of the cell size."): the page on Auto
        // asks for no quilt and no Small cells in thin walls (★ notes29: the engine no longer falls back to the quilt where no
        // other cell can be laid; with Allow quilt off such a place stays solid and the pop-up says why), and for the thinnest strut the printer lays (its lines x its
        // line width) in every cell, the cells still grading. Manual sends his own choices, as before. (362 at the merge with
        // notes26: applied here, after partWide, where the page's Manual is known.)
        if !p.latticePageManual, !l.isOrganic {
            s.allowQuilt = false
            s.smallCellsInThinWalls = false
            // ★ notes29: Structural Auto's By stress ends, read again as core's dials without the quilt
            if s.byStress { Self.gradeDials(l, &s, percent: { p.latticeDensityPercent(rho: $0, cellMM: $1) }) }
            // ★ his 11-24 answer: the thinnest struts on Auto are for AESTHETIC only. Structural Auto keeps its strength-led
            // struts (his aim, to come: work back from his margin, 150/175/200 %, to the least plastic that meets it).
            if (l.stageMode ?? .structural) == .aesthetic {
                s.byStress = false
                s.strutWidthMM = s.minStrutLines * s.beadMM
            }
            // ★ K7, K8 (his 11-24: "why can't we just extend cells and cut them off where the bed is?"): Auto's cells fitted to
            // the faces the grid is square to — the size with the fewest slivers there, a sliver left taken in by the row
            // beside it (core: a region laid on one grid; Structural's walls keep their own cells and are only said). Manual
            // lays his own size, as before — and so does a typed cell size (core2, 362: only when the cell size is Auto).
            s.cellSearch = l.cellSizeMode != .fixed
        }
        let rowDensity = s.perRegion
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
                       let (cell, pct) = [l.cellSizeMode == .fixed && l.cellMM > 0 ? l.cellMM : (p.latticeSelectableCellMM(ref) ?? s.cellMaxMM),
                                          s.cellMaxMM, 8].lazy.compactMap({ c in p.latticeDensityPercent(rho: rho, cellMM: c).map { (c, $0) } }).first {
                        // (the row's cell, else the largest cell: the page's percent is read on a cell its band exists for)
                        // ★ notes29: the page's percent (100 % = the type's own quilt) as core's dial (1 = the widest the
                        // switch allows: the open look with Allow quilt off), so the strut laid is the strut the percent names
                        let dial = LatticeDensityDial.coreDial(percent: pct, cellMM: cell, topology: s.topology, lineWidthMM: s.beadMM,
                                                               minStrutLines: s.minStrutLines, allowQuilt: s.allowQuilt)
                        if rowDensity { s.regionDials.append((region: id, dial: dial)) } else if !uniformSet { s.dial = dial; uniformSet = true }
                    }
                }
                id += 1
            }
        }
        return Self.partRest(s, p, nextID: id)
    }

    /// Grade to (light) and Grade from (heavy) as core's dials (R10, read on the largest cell). ★ notes29: the page's percent
    /// (100 % = the type's own quilt) through `LatticeDensityDial.coreDial`, with the settings' own Allow quilt, so the struts
    /// laid are the ones the percents name; a density the type has no band for is read as its percent.
    static func gradeDials(_ l: LatticeSettings, _ s: inout LatticeLayoutSession.Settings,
                           percent: (_ rho: Double, _ cellMM: Double) -> Double?) {
        let cell = s.cellMaxMM, cur = s
        func dial(_ rho: Double, _ fallback: Double) -> Double {
            guard rho > 0 else { return fallback }
            let pct = percent(rho, cell) ?? rho * 100
            return LatticeDensityDial.coreDial(percent: pct, cellMM: cell, topology: cur.topology, lineWidthMM: cur.beadMM,
                                               minStrutLines: cur.minStrutLines, allowQuilt: cur.allowQuilt)
        }
        s.dialLight = dial(l.minRelativeDensity, 0.01)
        s.dialHeavy = dial(l.maxRelativeDensity, 1)
    }

    /// ★ notes26 (his 11-23, "Yes to the live sample"): the part-wide half of `settings(_:)` — everything read off the lattice
    /// settings and the printer alone, no face row: the type, the cells, the grade, the band, the finish, the struts. The Lattice
    /// page's sample lays the open group's settings through it, so it follows his part's own rules. `percent`: a density → the
    /// percent the page shows on that cell (nil: the type has no strut law).
    static func partWide(_ l: LatticeSettings, beadMM bead: Double, wallRingMM ring: Double, referenceMPa: Double,
                         percent: (_ rho: Double, _ cellMM: Double) -> Double?) -> LatticeLayoutSession.Settings {
        var s = LatticeLayoutSession.Settings()
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
            s.coverMM = ring > 0 ? ring : -1
        default: break
        }
        // ★ Install 2 (his 09-18: single-cell members lock the Finish to Skin; jobSkinResolved): a one-cell member's struts are
        // tied by the skin, whatever None or Rim the page holds
        if l.singleCellMembersInEffect, l.boundary == .none || l.boundary == .rim { s.skin = true }   // ★ notes29: Aesthetic only
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
        s.allowQuilt = l.allowQuilt
        if s.byStress {
            // Grade to (light) and Grade from (heavy), on the dial the page's densities use (R10, the largest cell)
            Self.gradeDials(l, &s, percent: percent)
            // ★ control 1: the two ends typed in mm
            if let a = l.strutFromMM, let b = l.strutToMM, a > 0, b >= a { s.widthLightMM = a; s.widthHeavyMM = b }
        }
        // ★ a typed Thickness only with the simulation off (his 08-19), and never under By stress
        if !l.simulateStresses, !s.byStress, let t = l.manualStrutThicknessMM, t > 0 { s.strutWidthMM = t }
        s.smallCellsInThinWalls = l.smallCellsInThinWalls   // ★ his per-part choice (11-13)
        // ★ cells across a wall (C3-C5): Structural five; Aesthetic one with "Allow single-cell members", else two
        let aesthetic = (l.stageMode ?? .structural) == .aesthetic
        s.minCellsAcross = Self.minCellsAcross(l)   // ★ notes25 (D8): the one rule, read by the thin-wall pop-up too
        if l.neverSkipCellSize, s.algorithm == "default_grade" { s.maxStep = 2 }   // ★ control 4 (Default Grade only)
        s.oneGrid = aesthetic && l.letWallsCutCells   // ★ his 11-14: Aesthetic only; Structural always sends false
        // ★ density (R10): core's dial is the percent he sees / 100 (0.01 thinnest ... 1 widest); a typed strut width wins
        // ★ Install 2: the rows' densities only in Per region (the proposal: "Shown only in this mode, sent only in this mode")
        let rowDensity = l.densityMode == .perRegion && !s.byStress
        s.perRegion = rowDensity
        return s
    }

    /// The rest of `settings(_:)` after its face rows (`id`: the next region id): Protect skins merged, Organic's weave, the
    /// chips' Solid faces, and whether the whole part is lattice.
    private static func partRest(_ settings: LatticeLayoutSession.Settings, _ p: ProjectModel, nextID id: Int32)
        -> LatticeLayoutSession.Settings {
        var s = settings
        let l = p.lattice
        let ring = p.printParams.wallRingMM, cover = ring > 0 ? ring : -1   // Covered's shell: the printer's own wall
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

// MARK: ★ his 11-22 — watch it grow ("Could the user literally *watch* the lattice grow from nothing? … Time isn't wasted if
// there's an interesting animation running of the actual lattice being grown - this allows for patience from the user.")

extension LatticeLayoutPreview {
    /// An Organic lay is about to run on `session`: its vines are read as it lays them (about every 0.15 s, on the main actor,
    /// never through the session's worker) onto `growth`, and its phase onto the Lattice button. nil under the red control.
    func watchGrowth(_ session: LatticeLayoutSession) -> LatticeGrowthWatch? {
        growthWatch?.stop()
        growthWatch = nil
        guard !Self.controlNoGrowth else { return nil }
        let w = LatticeGrowthWatch(growth: growth, every: Self.growthPollS, most: Self.growthReadMost,
                                   read: { [weak session] from, most in
                                       guard let session else { throw CancellationError() }
                                       return try session.growthRead(from: from, most: most)
                                   },
                                   onPhase: { [weak self] p in self?.growthPhase(p) })
        growthWatch = w
        return w
    }

    /// No more growth: the watch stopped and what was grown gone (a new lay, the preview closed, a remembered lattice).
    func stopGrowth() {
        growthWatch?.stop()
        growthWatch = nil
        growth.stop()   // ★ notes24: its walls and replay too
    }

    /// The bars on screen changed: a finished lattice (a new one) replaces the growth with a short fade over it; nothing on
    /// screen (a refusal, an error) takes the growth away at once. The same lattice (its map came) leaves it as it is.
    func growthMeets(_ now: LatticeLayoutBarsInputs?, after old: LatticeLayoutBarsInputs?) {
        guard now == nil || now?.token != old?.token else { return }
        growthWatch?.landed()
        growth.seal(landed: now != nil)
    }

    /// The engine's phase of the lay under way, onto the Lattice button's line.
    func growthPhase(_ p: Int) {
        guard var lp = layProgress, lp.phase != p else { return }
        lp.phase = p
        layProgress = lp
    }

    /// Tests: whether a watch is reading now.
    var growthWatching: Bool { growthWatch?.running ?? false }
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

// MARK: - ★ his iPad notes 11-23: the version's last lattice, kept in its folder (LatticePreviewStore)

extension LatticeLayoutPreview {
    /// The lattice this version's folder keeps for exactly these inputs joins the remembered ones (a fresh token), so the
    /// restore shows it at once: no stress check, no lay, no session needed to draw it. Read once per inputs.
    fileprivate func adoptSaved(_ p: ProjectModel, path: String, _ s: LatticeLayoutSession.Settings) {
        guard Self.organic(p.lattice), !Self.controlForget else { return }
        let inputs = Self.layInputs(p, path: path, s, stress: stress)
        guard inputs != diskMiss, !remembered.contains(where: { $0.inputs == inputs }) else { return }
        guard let r = LatticePreviewStore.load(inputs, token: token &+ 1) else { diskMiss = inputs; return }
        token &+= 1
        adoptedToken = token
        remembered.insert(r, at: 0)
        LatticePreviewStore.restoredFromDisk += 1
    }

    /// The part's session, opened behind a lattice read back from the folder (the print file, the nozzle check and Auto's
    /// numbers use it; `matchSessionTensor` gives it the stress the lattice was laid with), then the solid view's map.
    fileprivate func openBehindRestored(path: String) {
        guard session == nil || sessionPath != path else { return }
        openingAfterRestore?.cancel()
        openingAfterRestore = Task { [weak self] in
            defer { self?.openingAfterRestore = nil }
            guard let self, (try? await self.openSession(path: path)) != nil, !Task.isCancelled else { return }
            if self.solidWanted, self.bars?.solid == nil { await self.addMap() }
        }
    }

    /// ★ The live version moved to its next number (VersionMoves.swift): the same part, its copy in the new folder. The session,
    /// the remembered lattices and the drawn one are this part's still — re-pointed, never laid again.
    fileprivate func retargetIfSamePart(_ path: String) {
        guard let old = sessionPath, old != path, session != nil,
              FileManager.default.contentsEqual(atPath: old, andPath: path) else { return }
        sessionPath = path
        for i in remembered.indices where remembered[i].inputs.path == old { remembered[i].inputs.path = path }
        if inputsAtLay?.path == old { inputsAtLay?.path = path }
        if let c = cutSurface, c.path == old { cutSurface = (path, c.surface) }
        if let w = shownWhere, w.at.path == old { var at = w.at; at.path = path; shownWhere = (w.token, at) }
        if nozzlePath == old { nozzlePath = path }
        diskMiss = nil
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
            // ★ his 11-22: no "laying the lattice" line; the Lattice button's ring says it
            // ★ notes28: nor the 0.2 mm nozzle's answer — it is said in the centred pop-up (LatticeLayoutPreview.nozzleAnswered)
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
