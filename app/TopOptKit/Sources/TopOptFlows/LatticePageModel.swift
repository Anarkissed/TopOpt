// LatticePageModel.swift — the lattice page's state machine and surface
// derivation (handoff 2026-07-30-lattice-page). The Swift twin of the approved
// prototype's `renderVals`: PURE value types compute every user-visible surface
// (gate items, banner, gating reasons, picker rows, sizing lanes) from plain
// inputs, so every bar (B0–B9) is testable headlessly; a small ObservableObject
// holds only navigation state.
//
// THE TOPOLOGY RULE (bar B0): the picker is computed from CORE's two independent
// sets — the certifiable set (TopOptKit.latticeCertifiableTopologies) and the
// generatable set (TopOptKit.latticeGeneratableTopologies) — and contains their
// UNION, nothing else. Nothing here authors a topology name; an entry core does
// not know cannot appear, and the B0 test fails if one ever does.

import Foundation
import TopOptKit

// MARK: - topology picker (bar B0 / B0b)

/// One picker row: a topology core knows, with its TWO independent properties.
public struct LatticeTopologyRow: Equatable, Sendable, Identifiable {
    public let id: String            // core's own name ("octet", "sc", …)
    public let displayName: String
    /// Core carries a homogenized tensor (band displays, a run may certify it).
    public let certifiable: Bool
    /// Core's geometry generator can emit it (a run can BUILD it).
    public let generatable: Bool

    /// The row badge: both properties, never conflated. Only a topology that is
    /// BOTH can run end-to-end today.
    public var badge: String {
        if certifiable && generatable { return "CERTIFIABLE" }
        if certifiable { return "CERTIFIES · NO GEOMETRY YET" }
        return "PREVIEW ONLY"
    }
}

public enum LatticeTopologyPicker {
    /// The picker rows: certifiable ∪ generatable, in core's certifiable order
    /// (generatable-only entries, should core ever grow one, append after). No
    /// entry outside the union can exist — the sets come straight from core.
    public static func rows(certifiable: [String], generatable: [String]) -> [LatticeTopologyRow] {
        var out: [LatticeTopologyRow] = certifiable.map {
            LatticeTopologyRow(id: $0, displayName: LatticeType.displayName(forID: $0),
                               certifiable: true, generatable: generatable.contains($0))
        }
        for g in generatable where !certifiable.contains(g) {
            out.append(LatticeTopologyRow(id: g, displayName: LatticeType.displayName(forID: g),
                                          certifiable: false, generatable: true))
        }
        return out
    }

    /// The rows read live from core (the production path).
    public static func rowsFromCore() -> [LatticeTopologyRow] {
        rows(certifiable: TopOptKit.latticeCertifiableTopologies,
             generatable: TopOptKit.latticeGeneratableTopologies)
    }

    /// The default topology: the first entry that is BOTH certifiable and
    /// generatable (octet today). Nil only if core ships disjoint sets — the
    /// caller then refuses to default rather than promising a run that can't exist.
    public static func defaultTopology(in rows: [LatticeTopologyRow]) -> String? {
        rows.first { $0.certifiable && $0.generatable }?.id
    }
}

// MARK: - entry gate (bar B1)

/// The full-screen entry gate: the page is unreachable past it without ≥ 1 anchor
/// AND ≥ 1 load, and it STATES what is missing (never a mute disabled button).
public struct LatticePageGate: Equatable, Sendable {
    public struct Item: Equatable, Sendable {
        public let name: String
        public let detail: String
        public let satisfied: Bool
        /// The fix affordance ("Add load") on an unsatisfied row.
        public let fixLabel: String?
    }
    public let satisfied: Bool
    public let title: String
    public let items: [Item]
    /// The big CTA ("Back to Setup — add a load").
    public let ctaLabel: String

    public static func compute(anchors: Int, loads: Int) -> LatticePageGate {
        let missing = [anchors < 1 ? "an anchor" : nil, loads < 1 ? "a load" : nil]
            .compactMap { $0 }
        let anchorItem = Item(
            name: "Anchor",
            detail: anchors >= 1
                ? "\(anchors) face\(anchors == 1 ? "" : "s") fixed"
                : "None yet — the part must be held somewhere",
            satisfied: anchors >= 1,
            fixLabel: anchors >= 1 ? nil : "Add anchor")
        let loadItem = Item(
            name: "Load",
            detail: loads >= 1
                ? "\(loads) load\(loads == 1 ? "" : "s") declared"
                : "None yet — a lattice cannot be graded without one",
            satisfied: loads >= 1,
            fixLabel: loads >= 1 ? nil : "Add load")
        return LatticePageGate(
            satisfied: missing.isEmpty,
            title: missing.count == 2 ? "Lattice needs an anchor and a load"
                : missing.first == "an anchor" ? "Lattice needs an anchor"
                : "Lattice needs a load",
            items: [anchorItem, loadItem],
            ctaLabel: missing.isEmpty ? "" : "Back to Setup — add \(missing.joined(separator: " and "))")
    }
}

// MARK: - status banner (bar B9)

/// The centre-top status banner, one per page state. Derivation is pure: the
/// page's real signals in, the surfaced copy out.
public struct LatticePageBanner: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case simRunning, simComplete, simStale, optimizing, failed
        /// A SMOOTHING that belongs to a different rung than the one on screen
        /// (task 2026-08-03-variant-postprocessing-concurrency, requirement 3).
        /// Deliberately a case on THIS enum rather than a second banner type: the
        /// brief's rule is one staleness concept, and "the thing you are looking at
        /// was computed from inputs that have since changed" is the same state
        /// `simStale` already names.
        case smoothingStale
    }
    public let kind: Kind
    public let title: String
    public let body: String
    public let actionLabel: String?
    public let showsProgress: Bool

    public static func derive(simPhase: LatticeSimModel.Phase, simStale: Bool,
                              optimizing: Bool, runFailure: String?) -> LatticePageBanner? {
        // Optimizing outranks sim states (the page dims and gates on it).
        if optimizing {
            return LatticePageBanner(kind: .optimizing, title: "Optimizing",
                                     body: "Topology first · lattice generation follows on the result",
                                     actionLabel: "Cancel", showsProgress: true)
        }
        if let f = runFailure {
            return LatticePageBanner(kind: .failed, title: "Job failed", body: f,
                                     actionLabel: "Fix", showsProgress: false)
        }
        switch simPhase {
        case .running:
            return LatticePageBanner(kind: .simRunning, title: "Running lattice simulation",
                                     body: "One linear FEA of the solid part · on this device",
                                     actionLabel: "Cancel", showsProgress: true)
        case .complete(let s):
            if simStale {
                return LatticePageBanner(kind: .simStale, title: "Sim is out of date",
                                         body: "The part, material, resolution or load case changed since the last run — the field shown is from the old settings.",
                                         actionLabel: "Re-run", showsProgress: false)
            }
            return LatticePageBanner(
                kind: .simComplete, title: "Sim complete",
                body: String(format: "Max displacement %.2f mm · peak von Mises %.0f MPa · safety %.1f",
                             s.maxDisplacementMM, s.maxStressMPa, s.safety),
                actionLabel: nil, showsProgress: false)
        case .failed(let msg):
            return LatticePageBanner(kind: .failed, title: "Sim failed", body: msg,
                                     actionLabel: nil, showsProgress: false)
        case .idle:
            return nil
        }
    }
}

// MARK: - RUN SIM gating (bar B5)

public struct LatticeSimGate: Equatable, Sendable {
    public let blocked: Bool
    /// The one-line reason under the button when blocked.
    public let reason: String?

    public static func compute(latticeOn: Bool, optimizing: Bool, simRunning: Bool) -> LatticeSimGate {
        if optimizing {
            return LatticeSimGate(blocked: true, reason: "A job is already running.")
        }
        if simRunning {
            return LatticeSimGate(blocked: true, reason: "The sim is already running.")
        }
        if latticeOn {
            return LatticeSimGate(blocked: true,
                                  reason: "This job also runs topology optimization — sim runs on its result.")
        }
        return LatticeSimGate(blocked: false, reason: nil)
    }
}

// MARK: - Auto density availability (bar B6)

public struct LatticeAutoDensityGate: Equatable, Sendable {
    /// Whether the Auto option is OFFERED at all — only with a real field.
    public let offered: Bool
    /// Why not, when it isn't ("No stress field yet — run a sim …").
    public let unavailableReason: String?
    /// The provenance + age line shown when offered.
    public let provenanceLabel: String?
    /// The field is stale against the current inputs (amber, "Re-run").
    public let stale: Bool

    public static func compute(field: LatticeDemandField?, stale: Bool,
                               now: Date = Date()) -> LatticeAutoDensityGate {
        guard let f = field else {
            return LatticeAutoDensityGate(
                offered: false,
                unavailableReason: "No stress field yet — Auto needs one. Run a sim, or open Lattice from a finished run's variant.",
                provenanceLabel: nil, stale: false)
        }
        return LatticeAutoDensityGate(offered: true, unavailableReason: nil,
                                      provenanceLabel: f.provenance.label(now: now),
                                      stale: stale)
    }
}

// MARK: - Optimize gating + sub-label (bars B2 / B6)

public struct LatticeOptimizeSurface: Equatable, Sendable {
    public let enabled: Bool
    public let label: String
    public let sub: String

    /// `designBoxActive` is the project's CURRENT design box. A lattice job with one
    /// is refused by core before any solve (`run_job.cpp`), so the button that would
    /// submit it is disabled with that reason instead of letting the user configure
    /// a whole page and discover it at the end (task
    /// 2026-08-03-variant-entry-gating-and-retention, failure B).
    public static func compute(baseCanOptimize: Bool, baseSummary: String,
                               latticeEnabled: Bool, densityMode: LatticeDensityMode,
                               topologyDisplayName: String, cellMM: Double,
                               bounds: LatticeBounds?, running: Bool,
                               lineWidthMM: Double = 0,
                               cellSummary: String? = nil,
                               designBoxActive: Bool = false,
                               // ★ Regions whose dialled density core will refuse
                               // (task 2026-08-16-per-sector-density-override).
                               // Empty by default, so every existing call site and
                               // every project that dials nothing is unchanged.
                               densityRefusals: [(name: String, why: String)] = []) -> LatticeOptimizeSurface {
        // The cell phrase the button claims. In AUTO / SWEPT cell mode there is no
        // single target cell to name — the page passes the mode's own summary
        // ("Auto 4.6 mm", "Swept 4.6–8.0 mm") so the button never states a target the
        // job does not carry (core REFUSES cell_mm in those modes). Absent ⇒ the
        // fixed-cell phrasing, exactly as before.
        let cellText = cellSummary ?? String(format: "%.1f mm", cellMM)
        if running {
            return LatticeOptimizeSurface(enabled: false, label: "Optimize", sub: "a job is already running")
        }
        guard latticeEnabled else {
            return LatticeOptimizeSurface(enabled: baseCanOptimize, label: "Optimize",
                                          sub: "topology only · \(baseSummary)")
        }
        // The core refusal, surfaced BEFORE the configuration rather than after it.
        if let why = LatticeCoreCapability.liveConflict(
            latticeEnabled: true, designBoxActive: designBoxActive,
            // Core refuses GRADING with a design box, not the box itself; auto
            // density is what ships a `grading` block (LatticeSettings.runSpec).
            graded: densityMode == .sim) {
            return LatticeOptimizeSurface(enabled: false, label: "Optimize", sub: why)
        }
        // AUTO density rides the optimize job now (task lattice-page-core-hookup
        // stage 4: core's run_job grades each accepted variant from that
        // variant's OWN final field). The one remaining requirement is the
        // stated line width — core's grading schema requires it (the
        // printability floor's input) — so ONLY that is gated, with the reason.
        //
        // THE REASON NAMES THE STRUT WIDTH, not the outer wall bead (task
        // strut-line-width-field). It used to say "outer line width", which told the
        // user to go and edit a WALL setting to change a LATTICE floor — the exact
        // conflation this task separated, and the one that also corrupts the wall
        // ring the width-aware gate sizes. The strut width resolves from the two
        // wall beads by rule, so "set them in print settings" is still the action.
        // ★ A DIALLED DENSITY CORE WILL REFUSE (task 2026-08-16-per-sector-
        // density-override). Same argument as the design-box refusal above, and
        // the same shape: core refuses this job, so the button that would submit
        // it says so with the REGION'S NAME rather than letting the user start a
        // run and meet the refusal at the other end. Core's own refusal is fast
        // (it lands before the solve) but "fast" is not "here".
        if let first = densityRefusals.first {
            let more = densityRefusals.count > 1
                ? " (and \(densityRefusals.count - 1) more)" : ""
            return LatticeOptimizeSurface(
                enabled: false, label: "Optimize",
                sub: "\(first.name): \(first.why)\(more)")
        }
        if densityMode == .sim && lineWidthMM <= 0 {
            return LatticeOptimizeSurface(
                enabled: false, label: "Optimize",
                sub: "auto density needs a strut line width (the grading printability floor) — set your wall line widths in print settings")
        }
        if let b = bounds, !b.runnableAsCertified {
            let why = b.generatableReason ?? b.topologyReason ?? b.cellReason ?? "settings not certifiable"
            return LatticeOptimizeSurface(enabled: false, label: "Optimize", sub: why)
        }
        // THE FORECAST IS NOT SHOWN HERE — see LatticePageActions. It describes the
        // `lattice_variant` job (this stored design, these settings), and THIS
        // button re-runs the whole ladder from the ORIGINAL part, which will not use
        // that design at all. Putting the forecast on this button would state a
        // prediction about a job it does not start.
        if densityMode == .sim {
            return LatticeOptimizeSurface(
                enabled: baseCanOptimize, label: "Optimize",
                sub: "topology + graded \(topologyDisplayName.lowercased()) lattice (from this run's own field) · target \(cellText)")
        }
        return LatticeOptimizeSurface(
            enabled: baseCanOptimize, label: "Optimize",
            sub: "topology + \(topologyDisplayName.lowercased()) lattice · \(cellText)")
    }
}

// MARK: - primitive sizing lanes (bar B4)

/// "Who honours this size" — the two pipeline lanes for an absolute size, against
/// the LIVE one-voxel minimum (longest bbox extent / resolution — exactly
/// topopt::voxelize's spacing, via VoxelFit.spacing). Not a constant: it moves
/// with part size and resolution, and the B4 test proves it.
public struct LatticeSizingLanes: Equatable, Sendable {
    public struct Lane: Equatable, Sendable {
        public let name: String
        public let verdict: String
        public let honoured: Bool
    }
    public let sizeMM: Double
    public let voxelMM: Double
    public let honoured: Bool     // every lane exact
    public let lanes: [Lane]
    /// "1 voxel at 128³ on a 200 mm part = 1.56 mm" (all live numbers).
    public let voxelLine: String

    public static func compute(sizeMM: Double, voxelMM: Double, resolution: Int,
                               longestExtentMM: Double) -> LatticeSizingLanes {
        let ok = sizeMM >= voxelMM - 1e-9
        return LatticeSizingLanes(
            sizeMM: sizeMM, voxelMM: voxelMM, honoured: ok,
            lanes: [
                Lane(name: "Lattice generator", verdict: "exact", honoured: true),
                Lane(name: "Topology optimizer",
                     verdict: ok ? "exact" : String(format: "rounds up to %.2f mm", voxelMM),
                     honoured: ok),
            ],
            voxelLine: String(format: "1 voxel at %d³ on a %.0f mm part = %.2f mm",
                              resolution, longestExtentMM, voxelMM))
    }
}

// MARK: - region roles (bar B3)

/// The three region roles, as the prototype names them. Each maps to a DISTINCT
/// shipped concept — they never collapse into one control or one job field:
///   clearance        → keep-clear (loads.clearances; REMOVES material, FrozenVoid)
///   lattice-include  → the lattice region list (preview scope; no job carrier yet)
///   lattice-exclude  → protect (loads.face_protections; KEEPS material solid, FrozenSolid)
public enum LatticeRegionRole: String, CaseIterable, Equatable, Sendable {
    case clearance
    case include
    case exclude

    public var displayName: String {
        switch self {
        case .clearance: return "Clearance"
        case .include: return "Lattice-include"
        case .exclude: return "Lattice-exclude"
        }
    }
    public var shortName: String {
        switch self {
        case .clearance: return "Clear"
        case .include: return "Lattice"
        case .exclude: return "Solid"
        }
    }
    public var subtitle: String {
        switch self {
        case .clearance: return "No material at all"
        case .include: return "Material, latticed"
        case .exclude: return "Material, kept solid"
        }
    }
}

// MARK: - the page's navigation state

// MARK: - the TO page's Lattice entry button (round-2 item T1)

/// The workspace's big Lattice button (same stature as Optimize, top right, left
/// of the position gizmo). Greyed until gravity AND an anchor AND a load are all
/// set — and it SAYS what is missing rather than just disabling.
public struct LatticeEntryButtonGate: Equatable, Sendable {
    public let enabled: Bool
    /// What still needs doing, in setup order ("gravity", "an anchor", "a load").
    public let missing: [String]
    /// The sub-line under the button title: the missing list, or the ready hint.
    public let subtitle: String

    public static func compute(gravitySet: Bool, anchors: Int, loads: Int) -> LatticeEntryButtonGate {
        var missing: [String] = []
        if !gravitySet { missing.append("gravity") }
        if anchors < 1 { missing.append("an anchor") }
        if loads < 1 { missing.append("a load") }
        let subtitle = missing.isEmpty
            ? "topology + infill setup"
            : "needs \(missing.joined(separator: " and "))"
        return LatticeEntryButtonGate(enabled: missing.isEmpty, missing: missing,
                                      subtitle: subtitle)
    }
}

// MARK: - chrome spacing (round-2 item L1 / bar M4)

/// The ONE chrome spacing token. Every gap between adjacent chrome elements on
/// the lattice page — button-to-button in the bottom-right cluster, the title
/// row to the From-Setup bar, the RUN SIM column, the top-left row — uses
/// `gap`, and the M4 test asserts every entry in `allGaps` IS `gap` (two
/// adjacent chrome elements with different gaps cannot compile in silently).
/// Chosen a little larger than the old chip stack's 9 pt and smaller than the
/// old Preview→Optimize 16 pt, per the task.
///
/// SINCE 2026-08-02-smoothing-page these numbers live in `PageChrome`, the one
/// chrome geometry all three full-screen pages share, and this enum is a NAMED
/// VIEW onto them rather than a second copy — a third page cannot invent a third
/// look without editing a constant every page reads (bar AE7).
public enum LatticeChromeLayout {
    public static let gap: CGFloat = PageChrome.gap

    /// Named gaps, one per adjacent-element seam the chrome has. The view reads
    /// THESE (not `gap` directly), so a one-off deviation would have to edit a
    /// named constant the test pins.
    public static let topLeftRowSpacing: CGFloat = gap
    public static let titleToFromSetup: CGFloat = gap
    public static let runSimColumnSpacing: CGFloat = gap
    public static let bottomClusterSpacing: CGFloat = gap
    public static let reviewDrawerToCluster: CGFloat = gap
    public static let noteToBanner: CGFloat = gap

    public static var allGaps: [CGFloat] {
        [topLeftRowSpacing, titleToFromSetup, runSimColumnSpacing,
         bottomClusterSpacing, reviewDrawerToCluster, noteToBanner]
    }

    /// Screen-edge margin (DS.Space.xl4's value) and the cluster button height —
    /// so the portrait panel's clearance above the bottom cluster DERIVES from
    /// the same token instead of a magic 104.
    public static let edge: CGFloat = PageChrome.edge
    public static let clusterHeight: CGFloat = PageChrome.actionButton
    public static var panelBottomClearance: CGFloat { PageChrome.panelBottomClearance }
}

/// A transient NOTE (round-2 item L13): shown top-centre, dismissed by a tap, by
/// a DIFFERENT note replacing it, or after `lifetime` seconds — never a caption
/// that persists until something else overwrites it. Pure value + a tiny clock
/// seam so the timeout rule is headlessly testable.
/// The lattice page's name for the ONE transient-note type every full-screen page
/// now shares — `PageTransientNote` in `PageChrome.swift`. Kept as an alias so
/// this page and its tests are untouched by the move (task 2026-08-04, bar U5:
/// the maintainer's third ask for this rule, answered once instead of per page).
public typealias LatticeTransientNote = PageTransientNote

/// The page's live state: which pane, whether the shared Selections library /
/// review drawer are up, the transient note. Pure navigation — every derived
/// surface lives in the pure types above so tests never need a view.
@MainActor
public final class LatticePageModel: ObservableObject {

    /// The panel's sub-panes. Round-2 pruned the ladder: regions/paint became the
    /// ONE shared Selections library (L18 — not a pane, an overlay of the same
    /// panel the TO page mounts), boundary was promoted inline (L15), and
    /// review became the bottom-right drawer (L16).
    public enum Pane: Equatable, Sendable {
        case topology
        case cellDensity
    }

    /// Where the page was entered from — decides the demand-field source (B6's
    /// two paths) and where Back returns to.
    public enum Entry: Equatable, Sendable {
        case workspace
        case variant(runName: String, variantIndex: Int)
    }

    @Published public var pane: Pane?
    @Published public var panelMinimized = false
    /// The ONE Selections library (the TO page's own panel) shown over the page
    /// (L18). While up, model taps route through the non-destructive lattice
    /// router (`LatticeLibraryTap`) — nothing here can remove TO-page work (L23).
    @Published public var libraryOpen = false
    /// The bottom-right Review drawer (L16).
    @Published public var reviewOpen = false
    /// The transient top-centre note (L13). Post via `post(note:)`; the view
    /// dismisses on tap; `tick(now:)` expires it after its lifetime.
    @Published public private(set) var note: LatticeTransientNote?
    public let entry: Entry

    public init(entry: Entry = .workspace) {
        self.entry = entry
    }

    public func go(_ p: Pane?) {
        pane = p
    }

    /// Back within the panel: every sub-pane returns to the root ladder.
    public func back() {
        pane = nil
    }

    // MARK: transient notes (L13)

    /// Post a note. A different note REPLACES the current one (rule 2); posting
    /// the same text refreshes its clock.
    public func post(note text: String, now: Date = Date()) {
        note = LatticeTransientNote(text: text, postedAt: now)
    }

    /// Tap-to-dismiss (rule 1).
    public func dismissNote() {
        note = nil
    }

    /// Expire the note after its lifetime (rule 3). The view calls this on a
    /// timer; tests call it with an explicit clock.
    public func tick(now: Date = Date()) {
        if let n = note, n.expired(now: now) { note = nil }
    }
}
