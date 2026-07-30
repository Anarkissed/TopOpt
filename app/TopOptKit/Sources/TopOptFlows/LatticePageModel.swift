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

    public static func compute(baseCanOptimize: Bool, baseSummary: String,
                               latticeEnabled: Bool, densityMode: LatticeDensityMode,
                               topologyDisplayName: String, cellMM: Double,
                               bounds: LatticeBounds?, running: Bool) -> LatticeOptimizeSurface {
        if running {
            return LatticeOptimizeSurface(enabled: false, label: "Optimize", sub: "a job is already running")
        }
        guard latticeEnabled else {
            return LatticeOptimizeSurface(enabled: baseCanOptimize, label: "Optimize",
                                          sub: "topology only · \(baseSummary)")
        }
        // Auto density cannot ride an optimize job yet (core grades only on the
        // analyze path; the worker routes only `run`). Never silently uniform (B6).
        if densityMode == .auto {
            return LatticeOptimizeSurface(
                enabled: false, label: "Optimize",
                sub: "auto density can't ride an optimize job yet — switch to uniform")
        }
        if let b = bounds, !b.runnableAsCertified {
            let why = b.generatableReason ?? b.topologyReason ?? b.cellReason ?? "settings not certifiable"
            return LatticeOptimizeSurface(enabled: false, label: "Optimize", sub: why)
        }
        return LatticeOptimizeSurface(
            enabled: baseCanOptimize, label: "Optimize",
            sub: "topology + \(topologyDisplayName.lowercased()) lattice · \(String(format: "%.1f", cellMM)) mm")
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

/// The page's live state: which pane, which accordion role, which primitive,
/// which chip drawer. Pure navigation — every derived surface lives in the pure
/// types above so tests never need a view.
@MainActor
public final class LatticePageModel: ObservableObject {

    public enum Pane: Equatable, Sendable {
        case topology
        case cellDensity
        case regions
        case primitive(UUID)
        case paint
        case boundary
        case review
    }

    public enum Chip: String, Equatable, Sendable { case paint, regions, preview }

    /// Where the page was entered from — decides the demand-field source (B6's
    /// two paths) and where Back returns to.
    public enum Entry: Equatable, Sendable {
        case workspace
        case variant(runName: String, variantIndex: Int)
    }

    @Published public var pane: Pane?
    @Published public var openRole: LatticeRegionRole = .clearance
    @Published public var paintRole: LatticeRegionRole = .include
    @Published public var openChip: Chip?
    @Published public var panelMinimized = false
    public let entry: Entry

    public init(entry: Entry = .workspace) {
        self.entry = entry
    }

    public func go(_ p: Pane?) {
        pane = p
        openChip = nil
    }

    /// Back within the panel: a primitive pane returns to regions; any other
    /// sub-pane returns to the root ladder.
    public func back() {
        switch pane {
        case .primitive: pane = .regions
        default: pane = nil
        }
    }

    /// The context-sensitive bottom-left hint (the prototype's `hint` cascade).
    public func hint(gated: Bool, previewOn: Bool) -> String {
        if gated { return "Lattice is unavailable until Setup has at least one anchor and one load." }
        switch pane {
        case .primitive:
            return "Drag the primitive on the model · values are absolute mm"
        case .paint:
            return "Tap faces to paint · tap again to remove · depth applies to every painted face"
        default:
            if previewOn { return "Preview is indicative — the built lattice is generated at optimize time" }
            return "Scrub sliders left–right · tap a value to type it"
        }
    }
}
