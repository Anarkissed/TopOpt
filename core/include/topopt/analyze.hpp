#ifndef TOPOPT_ANALYZE_HPP
#define TOPOPT_ANALYZE_HPP

// analyze_fixed_design — ONE FEA analysis solve on a FIXED design, no
// optimization (handoff 2026-07-26-constrained-smooth).
//
// This is the "receipt" engine the constrained-smoothing feature needs: hand it
// a fixed density field (a converged optimizer rung, or the voxelization of an
// edited/smoothed mesh) and it recovers the physics and gates it exactly as the
// optimizer's per-rung certification does — a single penalized elastic solve, the
// per-voxel stress/displacement fields, printed mass, support proxy, worst-case
// stress margin, the §7 V3 suite, and the acceptance verdict. It NEVER runs an
// optimization iteration.
//
// SINGLE SOURCE OF TRUTH. minimize_plastic's per-rung recovery/certification block
// (minimize_plastic.cpp, "Final penalized solve on the converged density ...")
// calls THIS function, so the numbers a run reports and the numbers a standalone
// re-analysis reports are produced by the same code. Handed a variant's OWN
// converged density (plus the same grid/BCs/loads/params/solver), the outputs are
// bit-identical to that variant's report/fields — the correctness bar this entry
// point is measured against (test_analyze_fixed_design).

#include <cstddef>
#include <vector>

#include "topopt/build_orientation.hpp"  // BuildOrientationReport (post-pass)
#include "topopt/fea.hpp"        // DirichletBC, NodalLoad
#include "topopt/lattice.hpp"    // LatticeTopology (lattice certification)
#include "topopt/materials.hpp"  // Material
#include "topopt/mesh.hpp"       // Vec3
#include "topopt/report.hpp"     // StressMargin
#include "topopt/simp.hpp"       // SimpParams, SolverKind
#include "topopt/strut_strength.hpp"  // StrutStrengthReport (report-only)
#include "topopt/voxel.hpp"      // VoxelGrid, V3Report

namespace topopt {

// A latticed region for a certification analysis (lattice certification Phase 1,
// handoff 2026-07-27-lattice-certification). Declares WHICH voxels of the fixed
// design are filled with a lattice instead of solid material, and at what relative
// density, so analyze_fixed_design can solve of the REAL composite object — the
// latticed elements carry the homogenized effective cubic tensor (lattice.hpp), the
// solid elements are unchanged — rather than of solid material with a scalar infill
// knockdown bolted on at display. A null LatticePosture* (the default) is the exact
// pre-lattice path, byte-for-byte.
//
// HOW A REGION IS DECLARED is out of scope for this task (the UI / grading-law
// front-end that fills `mask` and `relative_density` is a separate task). This struct
// is the in-memory contract the certification engine consumes; no production job path
// populates it yet, so every current run passes nullptr and is byte-identical.
struct LatticePosture {
  LatticeTopology topology = LatticeTopology::Octet;
  double cell_size_mm = 0.0;  // recorded in the analysis/run_info; not used in the math
  // grid-indexed (grid.voxel_count()); mask[e] != 0 marks voxel e as latticed.
  std::vector<char> mask;
  // grid-indexed; the lattice's LOCAL relative density at voxel e (in the library's
  // valid range; clamped otherwise). Meaningful only where mask[e] != 0. A uniform
  // region fills this with one value; the grading law (separate task) fills it graded.
  std::vector<double> relative_density;
  // OPTIONAL per-voxel cell size (mm), grid-indexed, for a SWEPT posture (handoff
  // 2026-08-01-lattice-cell-size-sweep). EMPTY (the default) => every latticed voxel
  // uses the scalar cell_size_mm above, which is the pre-sweep path byte-for-byte.
  //
  // It does NOT enter the certification math and cannot: the homogenized tensor is a
  // function of relative density alone, and relative density is a ratio, so the tensor
  // is cell-size invariant (measured at 0.000e+00 relative deviation on C11/C12/C44
  // across a 4x cell range — evidence/2026-08-01-lattice-cell-size-sweep). What it
  // changes is the CELLS-PER-MEMBER regime guard, which becomes a per-voxel test at
  // each voxel's OWN cell instead of one number for the whole part — the honest
  // question for a part whose cell size varies.
  std::vector<double> cell_size_field;
};

// How the acceptance gate knocks the worst-case stress margin down for a sparse
// print (handoff 2026-07-26-width-aware-knockdown). Bundles the two postures so a
// single analyze_fixed_design signature serves both, and so a caller cannot forget
// the width fields when it arms the width-aware path.
//
//   infill_knockdown  — the scalar f^1.5 (infill_margin_knockdown of the job's
//                       infill). This is the WHOLE gate in the default posture
//                       (`margin.worst_case * infill_knockdown`), and it also stays
//                       the interlayer-term knockdown in the width-aware posture
//                       (walls are credited only in-plane — 191/192 measured axial
//                       and bending, never z-bonding — so the interlayer failure
//                       mode is never made less conservative than today).
//   width_aware       — arm the SHELL+CORE composite. false (the default) → the gate
//                       is exactly the scalar path above (byte-identical).
//   infill_percent    — the job infill (percent) for the per-voxel core term.
//   wall_thickness_mm — t = outer + (wall_loops - 1)·inner, the solid perimeter ring
//                       width the slicer wraps around each member (one OUTER line width
//                       + the remaining inner loops at the INNER line width — what
//                       Bambu/Orca actually deposit). A mirror-inner outer collapses
//                       this to loops·inner. 0 → f_wall = 0 → the composite reduces to
//                       f^1.5 even when armed. Built once in knockdown_spec_for.
struct KnockdownSpec {
  double infill_knockdown = 1.0;
  bool width_aware = false;
  double infill_percent = 100.0;
  double wall_thickness_mm = 0.0;
};

// The certification outputs of one fixed-design analysis. Field-for-field the
// subset of MinimizePlasticVariant that the recovery block fills (von_mises_field,
// stress_tensor_field, displacement_field, mass_grams, support_volume_voxels,
// margin, v3, accepted) plus the intermediate scalars the report line consumes.
struct FixedDesignAnalysis {
  // Per-voxel von Mises stress over the PRINTED material (density > iso),
  // grid-indexed (grid.voxel_count()), MPa; zero off the printed set.
  std::vector<double> von_mises_field;
  // Per-voxel Cauchy stress tensor, flattened grid-indexed (6*voxel_count),
  // Voigt [xx,yy,zz,xy,yz,zx], TRUE shear, MPa; zero off the printed set.
  std::vector<double> stress_tensor_field;
  // Per-node displacement of the same solve, DOF-ordered (3*fea_node_count(grid)),
  // mm; zero on nodes attached only to non-printed voxels.
  std::vector<double> displacement_field;
  double mass_grams = 0.0;
  int support_volume_voxels = 0;
  std::size_t printed_voxels = 0;
  double printed_fraction = 0.0;  // printed_voxels / part_solid (0 if part_solid==0)
  double max_von_mises = 0.0;
  double max_interlayer_tension = 0.0;
  StressMargin margin;  // SOLID margin (the reported/displayed value)
  V3Report v3;          // §7 V3 suite on the fixed density (min-feature count, mesh, ...)
  // The acceptance gate, on the INFILL-ADJUSTED margin (the optimizer's ladder
  // gate uses the same two facts): margin_effective = margin.worst_case *
  // infill_knockdown; accepted = load_path_ok && (margin_effective >= margin_stop).
  double margin_effective = 0.0;
  bool accepted = false;
  // Handoff 2026-07-27-nonconvergence-rejection — true iff the CERTIFICATION solve
  // (simp_compliance at the tight cg_tolerance) did NOT converge. When set, every
  // field above is default/empty (the analysis never ran) and `accepted` is FALSE:
  // a design whose certification solve the CG cannot resolve is NEVER certified. The
  // caller (minimize_plastic) rejects that rung with kRungNonConvergentReason rather
  // than letting the solve's throw destroy the whole run. `non_convergent_iteration`
  // / `non_convergent_residual` are the failing solve's last CG readings (0 when it
  // converged). The certification solve is NOT softened or retried — the tolerance
  // is unchanged; this flag only records that it missed.
  bool non_convergent = false;
  int non_convergent_iteration = 0;
  double non_convergent_residual = 0.0;

  // --- Lattice certification (handoff 2026-07-27-lattice-certification) --------
  // All false/zero unless a LatticePosture was applied to this analysis (a nullptr
  // posture leaves every field here at its default and the whole solve byte-identical).
  //
  // WHAT THE MARGIN DESCRIBES WITH A LATTICE REGION. The certification solve now
  // carries the latticed elements' homogenized effective cubic tensor, so the
  // displacement field, the compliance/STIFFNESS, and the SOLID region's stresses
  // describe the REAL composite object (a softer lattice load path), not a solid
  // object with a scalar knockdown. `margin`/`accepted` are the SOLID region's
  // worst-case STRENGTH margin over that real composite field (the lattice voxels are
  // excluded from max_von_mises — see below). The lattice region is certified for
  // STIFFNESS but NOT for strut-level STRENGTH: the recovered lattice stress is the
  // EFFECTIVE (macro, smeared) stress, which is lower than the peak strut stress by a
  // stress-concentration factor. Certifying strut strength needs the de-homogenization
  // step named in handoff 2026-07-26-lattice-homog-phase0 (Phase 2). Hence
  // `lattice_strength_uncertified` is set whenever a lattice region is present.
  bool lattice_certified = false;    // a LatticePosture was applied to this solve
  LatticeTopology lattice_topology = LatticeTopology::Octet;  // recorded posture
  double lattice_cell_size_mm = 0.0;       // recorded posture cell size
  std::size_t lattice_voxels = 0;    // # latticed voxels in the printed set
  double lattice_rho_min = 0.0;      // min relative density used over the region
  double lattice_rho_max = 0.0;      // max relative density used over the region
  double lattice_max_effective_vm = 0.0;   // worst EFFECTIVE (macro) von Mises there
  bool lattice_strength_uncertified = false;  // strut strength not gated (Phase 2)

  // --- Strut-strength REPORT (task 2026-07-31-lattice-strut-strength-report) ----
  // REPORT ONLY. Filled AFTER the gate above from the SAME solve's stress tensor
  // field; nothing here feeds `accepted`/`margin_effective` (bar L1) and
  // `lattice_strength_uncertified` stays true — these are the measured NUMBERS the
  // maintainer asked to see, not a gate. Present iff a lattice posture with >= 1
  // latticed voxel was applied AND the topology carries a measured strut law
  // (octet only — strut_strength.hpp; other topologies report nothing rather than
  // borrow octet's law).
  bool lattice_strut_report = false;
  StrutStrengthReport lattice_strut;
  // Cells-per-member regime guard (bar L4): the thinnest LATTICED member's span in
  // cells (local_member_thickness_mm / cell) against the floor homogenization
  // needs (lattice_cells_per_member_min). Below the floor the homogenized macro
  // stress the strut law amplifies is itself outside the tensor's validated
  // regime, so the strut numbers above must be labelled out-of-regime — reported,
  // never trusted silently (and never gated on).
  double lattice_min_cells_per_member = 0.0;  // +inf if every latticed member
                                              // exceeds the thickness-EDT cap
  bool lattice_strut_out_of_regime = false;   // min_cells_per_member < floor

  // --- BUILD-ORIENTATION RANKING (handoff 2026-08-01-build-direction-separation)
  // A RECOMMENDATION, filled strictly AFTER `accepted` / `margin_effective` were
  // sealed above and unable to touch them. Default-constructed (evaluated ==
  // false) unless the caller passed score_build_orientation = true, so every
  // existing caller's output is byte-identical. See build_orientation.hpp.
  BuildOrientationReport build_orientation;

  // --- THE ORIENTATION THIS ANALYSIS DESCRIBES (handoff
  // 2026-08-01-bake-build-orientation) -----------------------------------------
  // `applied_build_dir` is the MODEL-frame build direction every
  // direction-bearing field above was computed at, and the direction the
  // EXPORTED geometry is rotated onto +Z from. It equals the `build_dir`
  // argument unless `build_direction_auto_applied` is true, in which case it is
  // the orientation the scorer CHOSE.
  //
  // READ THIS, NOT THE `build_dir` ARGUMENT, when reporting or exporting. They
  // differ exactly when the caller armed auto-apply and the recommendation was
  // not the inferred direction — precisely the case where using the argument
  // would make the report describe a different object than the file.
  Vec3 applied_build_dir{0.0, 0.0, 1.0};
  // The orientation was CHOSEN by the scorer rather than supplied. Only ever
  // true when no build direction was declared. When it is true the caller MUST
  // surface the choice — see BuildOrientationReport::auto_applied.
  bool build_direction_auto_applied = false;

  // --- THE WIDTH-AWARE GATE'S OWN INPUT PAIRS (handoff
  // 2026-08-02-gate-diagnosis-recommendations) ---------------------------------
  // The (von Mises, local member width) pairs over the SOLID PRINTED voxels the
  // width-aware in-plane term maxed over — i.e. exactly the population
  // `max_von_mises_effective` is the max of. EMPTY unless the WIDTH-AWARE posture
  // was armed (`knockdown.width_aware`), so the default posture — every current
  // production run — is byte-for-byte unchanged and pays nothing.
  //
  // WHY THEY LEAVE THE FUNCTION. In the width-aware posture the in-plane term is
  // a per-voxel max, so a counterfactual "what would the gate say at 60% infill"
  // cannot be answered by scaling one scalar. With these pairs it is answered
  // EXACTLY, by re-running the same width_aware_knockdown per voxel — no
  // re-solve, because the stress field does not depend on infill or wall count
  // (infill never enters the solver, ARCHITECTURE §2). Without them a diagnosis
  // must report the infill/wall levers NOT EVALUABLE rather than price them with
  // the wrong (default-posture) law.
  std::vector<double> gate_printed_von_mises;
  std::vector<double> gate_printed_member_width_mm;
};

// Run one certification analysis of `density` on `grid`.
//
//   grid, params        — the solved grid and SIMP params (E, nu, penalty) the
//                         solve runs with.
//   density             — the FIXED design field, size grid.voxel_count(); a
//                         printed voxel is density > 0.5. A re-voxelized mesh
//                         passes a binary field (1.0 solid / 0.0 void).
//   bcs, loads          — the boundary conditions and nodal loads for the solve.
//   material            — yield/z_knockdown/density for margin + mass.
//   build_dir           — build-plate normal (unit) for interlayer tension + support.
//   cg_tolerance, cg_max_iterations, solver_kind
//                       — the certification solve config. To reproduce a run's
//                         numbers bit-for-bit, pass that run's cert tolerance,
//                         max-iterations and SolverKind.
//   margin_stop         — the acceptance threshold.
//   knockdown           — the margin knockdown posture (KnockdownSpec): the scalar
//                         f^1.5 in the default posture, or the width-aware SHELL+CORE
//                         composite when armed. The stored/displayed margin stays the
//                         SOLID margin; the knockdown scales ONLY what the gate tests.
//   load_path_ok        — the connectivity belt verdict on `density` (a severed
//                         design measures ~zero stress → an enormous, meaningless
//                         margin, so the gate rejects it however good it looks).
//   part_solid          — the printed_fraction denominator (grid.solid_count()).
//   score_build_orientation
//                       — arm the BUILD-ORIENTATION post-pass (handoff
//                         2026-08-01-build-direction-separation). false (the
//                         DEFAULT) leaves `build_orientation` default-constructed
//                         and the whole analysis byte-identical. true ranks
//                         build_orientation_candidates(build_dir) on six criteria
//                         against THIS solve's field — no re-solve — and names a
//                         recommendation. IT CANNOT MOVE `accepted` /
//                         `margin_effective`: those are sealed from `build_dir`
//                         BEFORE the post-pass runs. If the recommendation would
//                         gate differently the report says so and the caller
//                         surfaces both verdicts; the one that stands is always
//                         the one computed from `build_dir`.
//   build_direction_inferred
//                       — honesty flag forwarded onto the report:
//                         resolve_build_direction_is_inferred(options), i.e.
//                         "no build direction was declared, this one was assumed
//                         from gravity". Reported, never acted on.
//   auto_apply_build_orientation
//                       — *** THE ONE PLACE A RECOMMENDATION MAY BECOME A
//                         DECISION *** (handoff 2026-08-01-bake-build-
//                         orientation). false (the DEFAULT) is PR 271's
//                         behaviour to the byte. true makes the scorer's
//                         recommendation the orientation this analysis
//                         CERTIFIES: the direction-dependent outputs
//                         (`max_interlayer_tension`, `margin`,
//                         `margin_effective`, `accepted`, `support_volume_voxels`
//                         and the strut report) are re-sealed at that direction —
//                         from the SAME candidate row the scorer already priced
//                         with the SAME gate expression, so nothing is computed
//                         a second way — `applied_build_dir` records it, and
//                         `build_orientation.auto_applied` makes the choice
//                         impossible to miss on the receipt.
//                         REQUIRES `score_build_orientation` AND
//                         `build_direction_inferred`: a recommendation may never
//                         override a DECLARED direction, and
//                         apply_recommended_orientation throws if asked to. The
//                         caller then rotates the EXPORTED geometry onto
//                         `applied_build_dir`, so the verdict and the file
//                         describe the same object.
//                         NOTHING ELSE MOVES. The solve, the fields, the mass and
//                         the V3 suite do not depend on the build direction (PR
//                         266 measured that exactly), so re-sealing is a re-read
//                         of one solve, not a second one.
//
// Throws whatever simp_compliance throws for a MALFORMED problem (bad BC/load
// index, non-physical params) and ReportError from compute_stress_margin. A CG
// NON-CONVERGENCE (SolverNonConvergence) of the certification solve is NOT thrown:
// it is caught and reported via FixedDesignAnalysis::non_convergent with accepted
// forced false (handoff 2026-07-27-nonconvergence-rejection), so a run's
// certification of one hard-to-solve variant cannot abort the whole run.
FixedDesignAnalysis analyze_fixed_design(
    const VoxelGrid& grid, const SimpParams& params,
    const std::vector<double>& density, const std::vector<DirichletBC>& bcs,
    const std::vector<NodalLoad>& loads, const Material& material,
    const Vec3& build_dir, double cg_tolerance, int cg_max_iterations,
    SolverKind solver_kind, double margin_stop, const KnockdownSpec& knockdown,
    bool load_path_ok, double part_solid, const LatticePosture* lattice = nullptr,
    bool score_build_orientation = false,
    bool build_direction_inferred = false,
    bool auto_apply_build_orientation = false,
    // THE PRINTED-SET THRESHOLD (task multiscale-lattice-to). A voxel carries
    // material when density > this. 0.5 (the DEFAULT) is the M3.5 iso every
    // existing caller uses and is byte-for-byte the pre-multiscale path.
    //
    // WHY IT IS A PARAMETER NOW. Under classic SIMP, density is penalised toward
    // 0/1, so "is there material here" and "is this voxel more than half full"
    // are the same question and 0.5 answers both. Under the MULTISCALE lattice
    // material law they come apart: a voxel at density 0.30 is not a half-empty
    // solid voxel, it is a REAL, printable, measured 30%-dense lattice cell, and
    // thresholding it away would delete material the optimizer placed, the
    // certification solved with, and the lattice pass is meant to build — the
    // exact loop/export disagreement this task exists to end. A multiscale run
    // therefore passes a threshold below the certified band's floor, so "printed"
    // means "not void". Must be in (0, 1).
    double printed_iso = 0.5);

// ═══ THE MARGIN-REPRODUCTION BAND ═══════════════════════════════════════════
// (task 2026-08-08-lattice-variant-margin-tolerance, S1)
//
// WHAT THIS IS FOR. Two places re-certify a design the run already certified and
// compare the margin they get with the margin the run RECORDED: the lattice
// pipeline's null-posture proof (`certify_latticed_variant`) and the re-lattice
// entry point (`lattice_variant_job`), which REFUSES on a mismatch. Both used a
// bare `==` on a double. Both were wrong, and the second one refused every
// variant of the maintainer's own 128³ run.
//
// *** THE COMMENT ON THE SOLVE ABOVE — "the certification solve is stateless (no
// warm start, no cached solver) so a re-analysis of the same field is
// bit-identical" — IS FALSE, AND THIS IS WHY. *** `analyze_fixed_design` is not a
// pure function of its arguments. The Krylov recycling subspace
// (`core/src/fea/recycle.cpp:83`, `thread_local RcSpace g_space`) is
// production-ARMED (`core/src/simp/production.cpp:672`) and deliberately CARRIED
// across solves (`krylov_recycle_reset_per_rung` is false,
// `core/src/simp/production.cpp:674`). So:
//
//   * the ladder's per-rung certification solve
//     (`core/src/simp/minimize_plastic.cpp:1806`) — the solve whose margin is the
//     RECORDED one — runs with a subspace harvested from that rung's own hundreds
//     of trajectory solves;
//   * every RE-certification runs inside `ScopedLadderSolverIsolation`
//     (`core/src/cli/run_job.cpp:2517`), which disables recycling and GenEO for
//     the duration precisely so the lattice post-process cannot perturb the
//     ladder — and which covers `lattice_variant_job` too, by design.
//
// Two different Krylov paths on the same operator. Both stop at the same relative
// residual (`cg_tolerance`), so they land at two different points inside the same
// residual ball, and the margin — a smooth functional of the displacement field —
// differs by what that ball admits.
//
// MEASURED, on three parts (evidence/2026-08-08-lattice-variant-margin-tolerance):
// the recycler only engages when a solve falls back to Jacobi-CG, because
// production sets `fea_set_krylov_recycle_wrap_multigrid(false)`
// (`core/src/simp/production.cpp:673`). A fixture whose grid coarsens (plate_bore
// at res 48: multigrid carried 240/240 solves, recycle_dim 0) reproduces
// BIT-FOR-BIT. The maintainer's part never coarsens (his run: hierarchy built on
// 3 of 445 solves, recycle_dim 16 on 444) and reproduces to 9 significant figures
// and no further.
//
// THE BAND, AND WHY IT IS THIS NUMBER. It is anchored to the thing that causes
// the difference — the solver's own convergence tolerance — and not fitted to the
// spread that was observed. Both solves satisfy ||f - Ku|| / ||f|| <= cg_tolerance
// (1e-8 on every production run: minimize_plastic's kCertTol, asserted there), so
// the admissible disagreement scales with cg_tolerance. The factor buys headroom
// over that bound for the stress recovery on top of it:
//
//   band = kMarginReproductionResidualFactor * cg_tolerance = 1e-6 in production
//
// WHAT THAT STILL CATCHES. The check exists because a mismatch means the load
// case, the grid or the design is not the one that produced the variant, and that
// protection has to survive. Every row below is MEASURED — the noise across three
// parts and twelve rungs (evidence README §1), the corruptions in
// test_margin_reproduction section B3:
//
//   solver-path noise, the thing that must pass   8.4e-11 .. 6.8e-09   ACCEPTED
//   ── the band ────────────────────────────────────────── 1.0e-06 ──
//   the declared load off by one part in 10^4              1.0e-04     REFUSED
//   ONE voxel of the design flipped to solid               2.0e-03     REFUSED
//   the whole design 2 % denser                            6.1e-02     REFUSED
//
// The band sits 148x above the worst noise it must admit and 100x below the
// SMALLEST corruption it must catch — and that smallest corruption is one voxel,
// which is the finest change to the design that exists. Nothing that changes the
// OBJECT moves the margin by less than the band; nothing that changes only the
// SOLVE PATH moves it by more.
inline constexpr double kMarginReproductionResidualFactor = 100.0;

// |reproduced - recorded| / |recorded|. Exactly equal inputs (including two
// infinities, which a zero-stress lattice posture produces) are 0.0; anything
// non-finite or a zero denominator that is not an exact match is +inf, so it can
// never pass a band.
double margin_reproduction_relative_delta(double recorded, double reproduced);

// ONE definition of "this re-certification reproduces the recorded margin", so
// the receipt's proof and the re-lattice path's refusal cannot drift apart. A
// non-positive `cg_tolerance` (no declared convergence bound) falls back to exact
// equality rather than inventing a band.
bool margin_reproduces(double recorded, double reproduced, double cg_tolerance);

// THE ONE accept-gate margin expression (handoff
// 2026-08-01-build-direction-separation). Extracted verbatim from
// analyze_fixed_design so the ORIENTATION SCORER can price a candidate
// orientation's verdict with the identical arithmetic the real gate used, rather
// than a second copy that could drift. analyze_fixed_design itself calls this, so
// the two are the same code by construction, not by inspection.
//
//   * default posture  -> compute_stress_margin(...).worst_case * infill_knockdown
//   * width-aware      -> the SHELL+CORE composite: in-plane from
//                         `max_von_mises_effective` (the per-voxel wall rescue
//                         already folded in), interlayer from the UNMODIFIED
//                         f^1.5 (walls are never credited across layers).
//
// `max_von_mises_effective` must equal `max_von_mises` in the default posture
// (it is unused there). Nothing here reads a build direction: the direction
// enters through `max_interlayer` alone, which is exactly why one solved field
// prices every orientation.
//
// THIS COMPUTES A NUMBER. It does not decide anything: the caller still applies
// the load-path belt (`load_path_ok`) and the `margin_stop` comparison.
double gate_margin_effective(double yield_strength_mpa, double z_knockdown,
                             double max_von_mises,
                             double max_von_mises_effective,
                             double max_interlayer,
                             const KnockdownSpec& knockdown);

// The infill margin knockdown seed curve — effective/solid strength ~= f^1.5
// (Gibson-Ashby), f = infill_percent/100, pinned to EXACTLY 1.0 for f >= 1
// (solid/unset). Exposed here so the optimizer's ladder gate and a standalone
// re-analysis gate share ONE definition. (The maintainer tunes this curve; do NOT
// treat the exponent as final — see the definition.)
double infill_margin_knockdown(double infill_percent);

// The solid-wall AREA FRACTION of a square W×W member cross-section wrapped by a
// solid perimeter ring of thickness t: f_wall = 4·t·(W-t)/W² (191/192's φ_wall).
// Degenerate-safe (handoff 2026-07-26-width-aware-knockdown, bar K5):
//   * member_width_mm <= 0 or non-finite (an "unbounded"/thick sentinel) → 0 (a
//     region too thick to be a member gets NO wall rescue — the conservative choice);
//   * wall_thickness_mm <= 0 (no walls) → 0;
//   * a ring thicker than the half-width (t > W/2, i.e. a member thinner than the
//     wall stack) is clamped to t = W/2 → f_wall = 1 (the member is all wall = solid).
// Always in [0, 1]; never divides by zero.
double wall_area_fraction(double member_width_mm, double wall_thickness_mm);

// The WIDTH-AWARE infill knockdown — the SHELL+CORE Voigt composite 191/192
// measured and validated to ~1-3 % (handoff 2026-07-26-width-aware-knockdown):
//   E_eff/E_solid = f_wall + (1 - f_wall)·infill_margin_knockdown(infill_percent)
// with f_wall = wall_area_fraction(member_width_mm, wall_thickness_mm). The core
// term REUSES infill_margin_knockdown so the Gibson-Ashby f^1.5 curve has ONE
// definition. Reduces EXACTLY to infill_margin_knockdown when there is no wall ring
// (t = 0 or W unbounded), and to 1.0 for solid infill. Never exceeds 1.0 and never
// divides by zero. This is the ONE definition of the width-aware law: the per-voxel
// gate calls it per element on the local member width, and the reproduction test
// (bar K3) calls it directly against 191/192's member table.
double width_aware_knockdown(double infill_percent, double member_width_mm,
                             double wall_thickness_mm);

}  // namespace topopt

#endif  // TOPOPT_ANALYZE_HPP
