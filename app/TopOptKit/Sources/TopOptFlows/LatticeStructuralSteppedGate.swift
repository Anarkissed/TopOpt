import Foundation
import TopOptKit

/// ★★ REVIEWER, 2026-10-08 (approved by the maintainer): "Structural Stepped: BLOCK the run (no
/// fallback), saying it waits on core's strength check for mixed cell sizes."
///
/// A Stepped run under Structural has no honest route today:
/// - WITHOUT the plan, core lays its own one-cell-per-region layout — not the cells he designed,
///   a silent substitute the standing rule forbids;
/// - WITH the plan, the cells come in several families that share no nodes, and core refuses it
///   unless the job names the beam-network certificate (`refuse_stepped_structural`,
///   run_job.cpp:5161-5183) — which its run routes only for organic (run_job.cpp:7581).
///
/// So every run path refuses it, in these words, until the beam-network set the app reads
/// (`TopOptKit.latticeBeamNetworkCertifiedAlgorithms`) holds "stepped" — then it lifts by itself.
/// Aesthetic Stepped, and Default Grade under either intent, are untouched. The fix is one tap:
/// Default Grade, whose halving cells share their nodes and which core certifies today. (The
/// intent itself is asked once and is never editable, so it is not offered.)
public enum LatticeStructuralSteppedGate {
    /// The line on every refused button and in Settings.
    public static let line = "Stepped waits on a strength check"
    /// The sentence behind the (i).
    public static let detail = "Under Structural, Stepped mixes cell sizes, and core can't yet "
        + "check the strength where different sizes meet. Default Grade's cells halve and share "
        + "their nodes, so core checks it today."
    /// The one-tap fix's label.
    public static let fixLabel = "Use Default Grade"

    /// The refusal, or nil when this lattice may run. An unstated intent reads as Structural —
    /// the codebase's `stageMode ?? .structural`, and core's own reading (anything but
    /// "aesthetic" is not Aesthetic, run_job.cpp:5166).
    public static func refusal(latticeEnabled: Bool, algorithm: String, stageMode: LatticeStageMode?,
                               beamNetworkAlgorithms: Set<String> = TopOptKit.latticeBeamNetworkCertifiedAlgorithms)
        -> String? {
        let stepped = LatticeCellTransition.stepped.coreAlgorithm
        guard latticeEnabled, algorithm == stepped, (stageMode ?? .structural) == .structural,
              !beamNetworkAlgorithms.contains(stepped) else { return nil }
        return line
    }

    /// The same question, of the project's saved lattice.
    public static func refusal(_ lattice: LatticeSettings,
                               beamNetworkAlgorithms: Set<String> = TopOptKit.latticeBeamNetworkCertifiedAlgorithms)
        -> String? {
        refusal(latticeEnabled: lattice.enabled, algorithm: lattice.algorithm, stageMode: lattice.stageMode,
                beamNetworkAlgorithms: beamNetworkAlgorithms)
    }
}
