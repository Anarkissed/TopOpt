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
import TopOptKit

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
    /// ★★ AUTO MEANS GRADED (maintainer, 2026-08-20: "Auto should also mean
    /// *GRADED*"), and the transition control is where he says so.
    ///
    /// ★ WHAT CHANGED AND WHY IT MATTERS TO HIM. Auto used to resolve to FIT the
    /// moment any region was declared — which is always, on his parts. Fit gives each
    /// region ONE cell, and core refuses Fit alongside sub-floor retention, so
    /// choosing Auto silently switched retention OFF before the job was built. His
    /// quiet upright could not keep its lattice and the switch could not help him,
    /// for a reason nothing on screen stated.
    ///
    /// ★ SO AUTO IS NOW SWEPT — the dyadic ladder, graded by the solve, which is what
    /// "graded" means and which coexists with retention. Fit remains available by
    /// CHOOSING it: "Manual, fixed and swept remain available and must not be
    /// removed" cuts both ways, and Fit is the right answer when regions differ in
    /// thickness and each wants its own cell.
    public static func resolve(includeRegionCount: Int,
                               retainSubfloor: Bool,
                               transition: LatticeCellTransition = .defaultGrade) -> Posture {
        // Only a WIRED transition can steer the posture; the other two are refused in
        // the UI and must not quietly select a different mode here either.
        _ = transition
        return Posture(cellMode: .swept, densityMode: .sim,
                       droppedSubfloorRetention: false)
    }

    /// ★ THE WINDOW AUTO SWEEPS, DERIVED FROM CORE — never typed, because Auto is
    /// exactly the mode where the user does not type it.
    ///
    ///   fine end   the finest cell that can print AT ALL: `bead / phi(rho_max)`,
    ///              where phi is core's measured strut diameter per unit cell
    ///   coarse end the coarsest cell any declared region can hold, `W / N*`, which
    ///              is Fit's own answer for that region — so the ladder's top is the
    ///              cell Fit would have chosen and the grading fills in below it
    ///
    /// Returns nil when core cannot answer (no bead stated, no region widths), and
    /// the caller then leaves the window alone rather than inventing one.
    /// ★★★ `cellsPerMemberFloor` — 0 keeps core's ACCURACY floor (5), which is what
    /// this always used. THE WINDOW IS A CEILING ON EVERY CELL THE PLANNER MAY CHOOSE,
    /// so leaving it unstated capped Auto at `W / 5` no matter what the stage mode had
    /// relaxed to (maintainer, 2026-08-22: "The legend is still saying it's 2.2mm
    /// cells"). On his 11 mm wall that ceiling is 2.20 mm — the number on his card,
    /// reached from a SECOND place after the per-region derivation was fixed.
    public static func autoWindowMM(regionWidthsMM: [Double],
                                    lineWidthMM: Double,
                                    topology: String,
                                    cellsPerMemberFloor: Double = 0)
        -> (min: Double, max: Double)? {
        guard lineWidthMM > 0 else { return nil }
        // ★★ THE FINEST PRINTABLE CELL IS NOT A USABLE FLOOR (maintainer,
        // 2026-08-20: "Is it too thick and unable to actually draw the 2.2 mm cell?").
        //
        // ★ HE WAS RIGHT, AND HERE IS THE ARITHMETIC. `bead / phi(rho_max)` is the
        // cell at which a strut prints ONLY at the very top of the band — so the one
        // legal lattice there is the densest one, the struts fill a fifth of the cell
        // edge, and at ~190 cells across his part it renders as a SOLID WALL. A cell
        // that can only be printed solid is not a cell size worth sweeping to.
        //
        // ★ SO THE LADDER GOES DOWN IN WHOLE DOUBLINGS FROM FIT'S OWN CELL, and stops
        // at the last rung that still prints. That is the dyadic ladder core actually
        // uses, walked from the top rather than guessed at from the bottom:
        //
        //     ceiling  W / N* for the widest declared region  (Fit's answer)
        //     floor    ceiling / 2^L, the deepest L whose cell still prints
        //
        // On his 13 mm regions: ceiling 2.6 mm, one doubling to 1.3 mm (which prints
        // at rho ~= 0.44, a dense lattice but a lattice), and 0.65 mm refused. Two
        // rungs, which is a sweep. The old floor gave 1.095 mm and a filled wall.
        //
        // ★ AND IF THERE IS NO ROOM, THERE IS NO ROOM. A part whose regions are all
        // one thickness gets a single rung and grades nothing — an honest fact about
        // the part, which `sweptWindowWarning` already states. Widening the ceiling
        // to manufacture a sweep would hand a region a cell it cannot hold.
        let limits = TopOptKit.latticeLimits(topology: topology)
        let phiMax = TopOptKit.latticeStrutDiameterMM(topology: topology,
                                                      relativeDensity: limits.rhoMax,
                                                      cellMM: 1.0)
        guard phiMax > 0 else { return nil }
        let finestThatPrints = lineWidthMM / phiMax
        guard finestThatPrints > 0, finestThatPrints.isFinite else { return nil }

        // ★★ THE CEILING IS THE WIDEST REGION'S CELL; THE FLOOR MUST REACH THE
        // THINNEST'S. Taking both ends from the widest was wrong, and the §4a guard
        // caught it: with regions of 7, 13 and 20 mm the ladder came out 2.0 – 4.0 mm,
        // and a 7 mm member holds 7 / N* = 1.4 mm. Every cell Auto could sweep to was
        // one that region cannot hold, so it would have been culled entirely — the
        // empty wall, reached from a third direction.
        var hi = 0.0
        var loFit = Double.greatestFiniteMagnitude
        for w in regionWidthsMM where w > 0 {
            let d = TopOptKit.latticeRegionDerivation(topology: topology,
                                                      memberWidthMM: w,
                                                      minExtrudableWidthMM: lineWidthMM,
                                                      cellsPerMemberFloor: cellsPerMemberFloor)
            guard d.valid, d.cellMM > 0 else { continue }
            hi = Swift.max(hi, d.cellMM)
            loFit = Swift.min(loFit, d.cellMM)
        }
        // Nothing to fit into (whole-part Auto): one rung at the finest printable
        // cell, stated as such rather than dressed up as a sweep.
        if hi <= 0 { hi = finestThatPrints; loFit = finestThatPrints }
        // Reach the thinnest region's own cell, never finer than what prints and
        // never coarser than the widest region's. A thinnest cell BELOW the printable
        // floor means that region cannot be latticed at all — a fact about the
        // region, not something a window can repair.
        let lo = Swift.min(Swift.max(Swift.min(loFit, hi), finestThatPrints), hi)
        return (lo, hi)
    }

    /// Apply the posture to a settings value. Only the AUTO-owned fields move;
    /// a user who has chosen Fixed or Swept or Uniform keeps that choice — Auto
    /// is the default, never a lock (§4b: "Manual, fixed and swept remain
    /// available and must not be removed").
    public static func applied(to s: LatticeSettings,
                               includeRegionCount: Int,
                               regionWidthsMM: [Double] = [],
                               lineWidthMM: Double = 0) -> LatticeSettings {
        guard s.cellSizeMode == .auto || s.densityMode == .sim else { return s }
        let posture = resolve(includeRegionCount: includeRegionCount,
                              retainSubfloor: s.retainSubfloorInUnloadedRegions,
                              transition: s.cellTransition)
        var out = s
        if s.cellSizeMode == .auto {
            out.cellSizeMode = posture.cellMode
            // ★ AND THE WINDOW COMES WITH IT. Auto is swept-without-typing, so the
            // ends must be filled in or the job carries a sweep with no range.
            if posture.cellMode == .swept,
               let w = autoWindowMM(regionWidthsMM: regionWidthsMM,
                                    lineWidthMM: lineWidthMM,
                                    topology: s.topologyID,
                                    // ★ The mode's floor, or Auto's ceiling is W / 5
                                    // however far the mode relaxed — see the note on
                                    // `autoWindowMM`.
                                    cellsPerMemberFloor: (s.stageMode ?? .structural)
                                        .cellsPerMemberFloor(
                                            topology: s.topologyID, utilisation: .nan,
                                            boundaryFinishWritten: s.boundary != .none)) {
                out.cellMinMM = w.min
                out.cellMaxMM = w.max
            }
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
