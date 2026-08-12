// LatticeAutoPosture.swift — ★ WHAT "AUTO" ACTUALLY ASKS CORE FOR, and the
// promise that it NEVER REFUSES (task 2026-08-12-lattice-page-redesign §4).
//
// THE MAINTAINER'S REQUIREMENT: "a user should be able to simply press Auto on
// everything after setting the faces section and it should work — no questions
// asked."
//
// AUTO IS NOT ONE JOB FIELD. Core carries four cell modes and two density modes,
// and the combination that answers "coarse and light where the stress is low,
// fine and dense where it is high" depends on whether the user declared REGIONS:
//
//   regions declared  → cell_mode "fit"   — core derives the cell PER REGION from
//                       that region's own thickness, and reports each region's
//                       verdict. This is the per-region answer §4a asks for, and
//                       it is the mode the device could not select until PR 302's
//                       schema was surfaced.
//   no regions        → cell_mode "swept" — core grades the cell across a
//                       min…max window over the whole part, coarse where the
//                       stress is low. Both ends still bounded by core's own
//                       printability floor; this file authors NO bound.
//
// Density is `auto` in both: the run carries a `grading` block and core grades
// each accepted variant from THAT VARIANT'S OWN final stress field.
//
// ★ §4d — WHICH STRESS FIELD, ON A REAL JOB. There is no deadlock on the RUN
// path: the field Auto grades from is computed INSIDE the run, per accepted
// variant, and its provenance is in the receipt. "Run Sim" is disabled on a
// TO+lattice job because a sim of the ORIGINAL solid part is not the field that
// governs — it would describe geometry the run is about to replace. What Run Sim
// feeds is the PREVIEW overlay, which is why the preview says whose field it is
// drawing (`LatticeDemandField.provenance`) and says so when it has none.
//
// ★ §4c — AUTO MUST NEVER PRODUCE A REFUSAL. Two combinations core REFUSES
// outright are unreachable from here rather than being offered and then failing:
// "fit" with no include region, and "fit" alongside sub-floor retention. When a
// region cannot be certified at any cell, the run still emits it — core reports
// it out of regime (`grading.regions[].verdict`) and the face card states it.
//
// Pure derivation over value types.

import Foundation

public enum LatticeAutoPosture {

    /// What Auto asks core for, given the project's declarations.
    public struct Posture: Equatable, Sendable {
        public let cellMode: LatticeCellSizeMode
        public let densityMode: LatticeDensityMode
        /// True when sub-floor retention had to be dropped to keep "fit" legal —
        /// surfaced, never silent.
        public let droppedSubfloorRetention: Bool
        /// ★ Four words. Named on the control, not explained in a paragraph (R3).
        public var label: String {
            cellMode == .fit ? "Auto · per region" : "Auto · swept"
        }
    }

    /// Resolve Auto. `includeRegionCount` is the number of `role: include`
    /// regions the job will actually carry — read from the EMISSION, not from the
    /// role map, because a role whose face has no usable B-rep geometry emits
    /// nothing and "fit" would then be refused for having no region to fit into.
    public static func resolve(includeRegionCount: Int,
                               retainSubfloor: Bool) -> Posture {
        guard includeRegionCount > 0 else {
            return Posture(cellMode: .swept, densityMode: .auto,
                           droppedSubfloorRetention: false)
        }
        return Posture(cellMode: .fit, densityMode: .auto,
                       droppedSubfloorRetention: retainSubfloor)
    }

    /// Apply the posture to a settings value. Only the AUTO-owned fields move;
    /// a user who has chosen Fixed or Swept or Uniform keeps that choice — Auto
    /// is the default, never a lock (§4b: "Manual, fixed and swept remain
    /// available and must not be removed").
    public static func applied(to s: LatticeSettings,
                               includeRegionCount: Int) -> LatticeSettings {
        guard s.cellSizeMode == .auto || s.densityMode == .auto else { return s }
        let posture = resolve(includeRegionCount: includeRegionCount,
                              retainSubfloor: s.retainSubfloorInUnloadedRegions)
        var out = s
        if s.cellSizeMode == .auto {
            out.cellSizeMode = posture.cellMode
            // Core refuses "fit" alongside sub-floor retention — two mechanisms
            // for the same voxel with two receipts. Auto drops the one it did
            // not choose rather than emitting a job core will reject (§4c).
            if posture.cellMode == .fit { out.retainSubfloorInUnloadedRegions = false }
            // "fit" reports a verdict per region, which is the whole of §5.
            out.reportRegionCells = true
        }
        return out
    }
}
