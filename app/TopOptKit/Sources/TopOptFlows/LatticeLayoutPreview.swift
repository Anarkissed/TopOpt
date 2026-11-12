// LatticeLayoutPreview — the NEW ENGINE's preview on Lattice Setup (the lattice rebuild, stage E; his blitz of 2026-11-12, the
// reviewer's go 20:21Z). Behind App settings' "New engine (test)", DEFAULT OFF: off, nothing here runs and the page is today's.
// On, the page draws core's lattice_layout bars (LatticeLayoutBarsPass) in place of the old engine's march:
//   * one LatticeLayoutSession per part (opened once; core keeps what a change does not touch, rule P2);
//   * the page's own settings, read where its rows read them (`settings(_:)`): each face row of each lattice group is ONE
//     region (Lattice or No lattice, its depth and its Expand), a group set as a Protect skin is a skin over its faces, Finish
//     Rim / Covered, the type, the cell and the strut width; two-line struts always (the reviewer's ruling 11-12);
//   * latest wins: a setting moved while a layout runs stops that layout (core's stop flag) and lays the new one.
// What it says, in one plain line each: why there is nothing to draw, and that bars are drawn round where the print file
// squares flat-bridge undersides and adds posts (PREVIEW IS THE SPEC — until the drawer shows them).
import Foundation
import SwiftUI
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

    public struct Timing: Equatable, Sendable {
        public var openMS: Double
        public var readMS: Double
        public var cellsMS: Double
        public var barsMS: Double
        public var bars: Int
        public var line: String {
            String(format: "New engine · open %.0f · read %.0f · cells %.0f · bars %.0f ms · %d bars", openMS, readMS, cellsMS, barsMS, bars)
        }
    }

    /// The line the preview carries while the drawer draws every bar round (the reviewer's PREVIEW IS THE SPEC).
    public static let roundBarsLine = "Preview: bars drawn round · the print squares flat bridges and adds posts"
    public static let noPartLine = "New engine: this part has no model file to read"
    /// The body while the new engine draws: see-through, so the bars inside it show (the Flexible pass's ghost rules apply).
    public static let ghostAlpha: Float = 0.2

    private var session: LatticeLayoutSession?
    private var sessionPath: String?
    private var openMS = 0.0
    private var lastSettings: LatticeLayoutSession.Settings?
    private var token = 0
    private var task: Task<Void, Never>?

    public init() {}

    /// The page's one call, on every change of the part or its lattice settings (cheap when nothing changed).
    public func update(project p: ProjectModel, on: Bool) {
        guard on else { clear(); return }
        guard let path = p.importedFile?.path else { problem = Self.noPartLine; bars = nil; return }
        let s = Self.settings(p)
        if path == sessionPath, s == lastSettings, task != nil || bars != nil { return }
        lastSettings = s
        task?.cancel()
        laying = true
        task = Task { [weak self] in await self?.lay(path: path, s) }
    }

    /// Off: the session closed, nothing drawn.
    public func clear() {
        task?.cancel(); task = nil
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
            bars = LatticeLayoutBarsInputs(token: token, bars: r.bars)
            timing = Timing(openMS: openMS, readMS: r.msRead, cellsMS: r.msCells, barsMS: r.msBars, bars: r.barCount)
            problem = r.barCount == 0 ? "New engine: no lattice fits these settings" : nil
            laying = false
        } catch is CancellationError {
            // a newer setting is laying
        } catch {
            problem = FlexibleRowCopy.fit("New engine: \(error)", 60)
            bars = nil
            laying = false
        }
    }

    // MARK: the page's settings, as core reads them

    /// Lattice Setup's settings for core's lattice_layout (read where its rows read them).
    public static func settings(_ p: ProjectModel) -> LatticeLayoutSession.Settings {
        var s = LatticeLayoutSession.Settings()
        let l = p.lattice
        let bead = p.printParams.strutLineWidthMM
        s.beadMM = bead > 0 ? bead : 0.45
        s.minStrutLines = 2   // ★ the reviewer's ruling 11-12: one line does not print on his 0.4 mm nozzle
        s.topology = l.topologyID.isEmpty ? "octet" : l.topologyID
        s.algorithm = l.resolvedAlgorithm == "stepped" ? "stepped" : "default_grade"
        s.cellMM = l.cellSizeMode == .fixed ? l.cellMM : 0
        s.cellMaxMM = l.cellMaxMM > 0 ? l.cellMaxMM : 8
        s.cellMinMM = Swift.max(0, l.cellMinMM)
        switch l.boundary {
        case .rim: s.rimMM = -1        // two line widths
        case .fullSkin: s.coverMM = -1
        default: break
        }
        if let t = l.manualStrutThicknessMM, t > 0 { s.strutWidthMM = t }
        s.allowQuilt = l.allowQuilt
        var id: Int32 = 1
        for g in p.latticeGroups {
            for ref in p.latticeSelectableRefs(g) {
                guard let role = p.latticeSelectableRole(ref, in: g.id) else { continue }
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
                s.regions.append(.init(id: id, noLattice: role == .exclude, faces: faces, depthMM: depth,
                                       expandMM: p.latticeExpandMM(ref)))
                id += 1
            }
            if l.skinGroups.contains(g.id), !g.faces.isEmpty {
                s.protect.append(.init(id: id, faces: g.faces.map { Int32($0) }, depthMM: 0))   // 0 = two line widths
                id += 1
            }
        }
        // no face asked for lattice: the whole part, as the old engine's "In a part" with no face picked
        s.allLattice = !s.regions.contains { !$0.noLattice }
        return s
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
