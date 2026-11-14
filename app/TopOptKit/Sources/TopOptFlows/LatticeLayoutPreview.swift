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
    /// One plain line under the preview: what is wrong, or nil.
    @Published public private(set) var problem: String?
    /// Core's numbers for the debug overlay (stage E's iPad timing): open, read, cells, bars, ms.
    @Published public private(set) var timing: Timing?
    @Published public private(set) var laying = false
    /// One plain line: what these settings ask that the new engine does not do yet (nil: nothing).
    @Published public private(set) var notes: [String] = []

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
    public static let byStressLine = "New engine: no stress yet · cell size and density follow the shape only"
    public static let perAreaLine = "New engine: one cell range, grade style and band for the whole part, not per area yet"

    /// The new engine draws the strut types' Uniform, Default Grade and Stepped; Organic keeps the old preview (LatticeReview 11-13).
    public static func draws(_ l: LatticeSettings) -> Bool { l.resolvedAlgorithm != "organic" }
    /// One plain line each for what the new engine leaves out for these settings.
    public static func notes(_ l: LatticeSettings) -> [String] {
        var out: [String] = []
        if l.densityMode == .sim || l.simulateStresses { out.append(byStressLine) }
        if l.areaGrading.values.contains(where: { !$0.isEmpty }) { out.append(perAreaLine) }
        return out
    }
    public static func note(_ l: LatticeSettings) -> String? { notes(l).first }
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

    public init() {}

    /// The page's one call, on every change of the part or its lattice settings (cheap when nothing changed).
    public func update(project p: ProjectModel, on: Bool, solid: Bool = false) {
        guard on else { clear(); return }
        guard let path = p.importedFile?.path else { problem = Self.noPartLine; bars = nil; return }
        if path != sessionPath || box == nil { box = Self.box(p.importedMesh?.vertices ?? []) }
        let solidChanged = solid != solidWanted
        solidWanted = solid
        notes = Self.notes(p.lattice)
        let s = Self.settings(p)
        if path == sessionPath, s == lastSettings, task != nil || bars != nil {
            if solidChanged, task == nil || bars != nil { solidToggled() }
            return
        }
        lastSettings = s
        task?.cancel()
        laying = true
        task = Task { [weak self] in await self?.lay(path: path, s) }
    }

    /// Off: the session closed, nothing drawn.
    public func clear() {
        task?.cancel(); task = nil
        mapTask?.cancel(); mapTask = nil
        session?.close(); session = nil; sessionPath = nil; lastSettings = nil
        bars = nil; problem = nil; timing = nil; laying = false
    }

    private func lay(path: String, _ s: LatticeLayoutSession.Settings) async {
        do {
            if session == nil || sessionPath != path {
                session?.close()
                let opened = try await LatticeLayoutSession.open(path: path)
                guard !Task.isCancelled else { return }
                session = opened; sessionPath = path; openMS = opened.info.msOpen
            }
            guard let session else { return }
            let r = try await session.lay(s)
            guard !Task.isCancelled else { return }
            token &+= 1
            // the last map stays until this layout's own lands (no flash of a closed part on every change)
            bars = LatticeLayoutBarsInputs(token: token, bars: r.bars, solid: solidWanted ? bars?.solid : nil, flags: r.barFlags)
            timing = Timing(openMS: openMS, readMS: r.msRead, cellsMS: r.msCells, barsMS: r.msBars, bars: r.barCount)
            problem = r.barCount == 0 ? "New engine: no lattice fits these settings" : nil
            laying = false
            if solidWanted { await addMap() }
        } catch is CancellationError {
            // a newer setting is laying
        } catch {
            problem = FlexibleRowCopy.fit("New engine: \(error)", 60)
            bars = nil
            laying = false
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
                for f in g.faces where !m.faces.contains(f) { m.faces.append(f) }
                byDepth[g.depthMM] = m
            } else {
                byDepth[g.depthMM] = g
                order.append(g.depthMM)
            }
        }
        return order.compactMap { byDepth[$0] }
    }

    /// Lattice Setup's settings for core's lattice_layout (read where its rows read them).
    public static func settings(_ p: ProjectModel) -> LatticeLayoutSession.Settings {
        var s = LatticeLayoutSession.Settings()
        let l = p.lattice
        let bead = p.printParams.strutLineWidthMM
        s.beadMM = bead > 0 ? bead : 0.45
        s.minStrutLines = 2   // ★ the reviewer's ruling 11-12: one line does not print on his 0.4 mm nozzle
        s.topology = l.topologyID.isEmpty ? "octet" : l.topologyID
        s.algorithm = l.resolvedAlgorithm == "stepped" ? "stepped" : "default_grade"
        // ★ 11-13: the cell window the page RESOLVES, as the old engine's job reads it (Auto: the floor to the type's ceiling;
        // Swept: the typed window, never under the floor) — never the stored numbers a mode does not show
        let bounds = LatticeBounds.compute(settings: l, limits: TopOptKit.latticeLimits(topology: l.topologyID),
                                           lineWidthMM: s.beadMM)
        let plan = l.resolvedCellPlan(bounds: bounds, minimizePlastic: false)
        s.cellMM = l.cellSizeMode == .fixed ? l.cellMM : 0
        s.cellMinMM = Swift.max(0, plan.loMM)
        s.cellMaxMM = plan.hiMM > 0 ? plan.hiMM : (l.cellMaxMM > 0 ? l.cellMaxMM : 8)
        switch l.boundary {
        case .rim: s.rimMM = -1           // Finish Rim: two line widths
        case .fullSkin: s.skin = true     // Finish Skin (S3): bars across the face joining the cut strut ends (his pick 11-12:
                                          // this went as Covered)
        case .covered: s.coverMM = -1     // Finish Covered (S9): a solid shell over the lattice, two line widths
        default: break
        }
        // Grade to shape: the grading mode's shape fit, its band and its Strength, as the old engine's job sends them (Stepped and
        // Doubled only)
        if l.gradingMode.fitsShape, ["stepped", "doubled"].contains(l.resolvedAlgorithm) {
            s.gradeToShape = true
            s.bandMM = Swift.max(0, l.shapeFitBandMM)
            s.strength = l.shapeFitGradeStrength
        }
        if let t = l.manualStrutThicknessMM, t > 0 { s.strutWidthMM = t }
        s.allowQuilt = l.allowQuilt
        s.smallCellsInThinWalls = l.smallCellsInThinWalls   // ★ his per-part choice (11-13)
        // ★ cells across a wall (C3-C5): Structural five; Aesthetic one with "Allow single-cell members", else two
        let aesthetic = (l.stageMode ?? .structural) == .aesthetic
        s.minCellsAcross = aesthetic ? (l.singleCellMembers ? 1 : 2) : 5
        // ★ density (R10): core's dial is the percent he sees / 100 (0.01 thinnest ... 1 widest); a typed strut width wins
        let rowDensity = l.densityMode != .sim && (l.densityMode == .perRegion || aesthetic)
        s.perRegion = rowDensity
        var id: Int32 = 1
        var uniformSet = false
        for g in p.latticeGroups {
            // ★ a Protect skin group is a solid face at its rows' depth (D5), never a No lattice region (11-13: it went as both)
            let skinGroup = l.skinGroups.contains(g.id)
            for ref in p.latticeSelectableRefs(g) {
                let role = p.latticeSelectableRole(ref, in: g.id)
                guard skinGroup || role != nil else { continue }
                let faces: [Int32]
                switch ref {
                case let .face(_, f):
                    faces = [Int32(f)]
                case let .region(_, rid):
                    faces = p.surfaceResolvedFaces(rid).map { Int32($0) }
                case .primitive:
                    continue   // a zone is a shape, not a face: the new engine takes faces only (first cut)
                }
                guard !faces.isEmpty else { continue }
                let depth = p.latticeSlabDepthMM(ref, in: g.id)   // the face row's own number (FlexibleSelectionsList's)
                if skinGroup {
                    s.protect.append(.init(id: id, faces: faces, depthMM: depth))
                } else {
                    s.regions.append(.init(id: id, noLattice: role == .exclude, faces: faces, depthMM: depth,
                                           expandMM: p.latticeExpandMM(ref)))
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
            .padding(.bottom, 96)
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
        .padding(.bottom, 96)   // above the bottom bar and the stage row's own lines
        .allowsHitTesting(false)
        .accessibilityIdentifier("new-engine-lines")
    }
}
