// plsm.hpp — THE PARAMETRIC LEVEL-SET OPTIMISER, on the production path.
//
// Task 2026-08-10-plsm-production. PR 324 measured that a parametric level set
// started from a plain array of holes, with SIMP nowhere in the pipeline, beats
// his shipped SIMP rung 0.68 on all three of the numbers that gate a run:
//
//     margin 3391.74 against 3254.34 (+4.2%), peak vM -4%, mass 463.0 g
//     against 543.7 g (-15%), ACCEPTED
//
// This header is that optimiser, as something `minimize_plastic` can call in
// place of `simp_optimize`. Everything downstream of it — the ladder, the
// certification, `achieved_vf`, the frozen/protect masks, the clearances, the
// design box, the lattice pass — reads a DENSITY PER VOXEL and gets exactly
// that; see the audit in the task handoff's S1(e).
//
// ★ DEFAULT OFF, AND SIMP'S DEFAULT PATH IS BYTE-IDENTICAL. `PlsmOptions::mode`
// is Off unless a job says otherwise, `minimize_plastic` branches on it and on
// nothing else, and R1 is verified by a stash-rebuild checksum rather than by
// construction (evidence/2026-08-10-plsm-production/r1_byte_identity).
//
// ── WHAT IS DIFFERENT FROM `simp_optimize`, IN ONE PARAGRAPH ────────────────
//
// The design variable is not a density per voxel. It is a vector of RBF
// coefficients alpha, and the voxel field is a VALUE of the analytic function
// phi(x) = sum_i alpha_i psi_i(x) (plsm_basis.hpp) through the ersatz
// rho = rho_min + (1 - rho_min) H_eta(-phi). There is no density filter, no
// Heaviside projection and no penalty continuation: the smoothness is a property
// of the BASIS BANDWIDTH — the knot spacing — rather than a rule policed
// afterwards. There is also no Hamilton-Jacobi advection and no reinitialisation
// (PR 324 §6): the coefficient step IS the motion.

#ifndef TOPOPT_PLSM_HPP_
#define TOPOPT_PLSM_HPP_

#include <cstddef>
#include <functional>
#include <string>
#include <vector>

#include "topopt/fea.hpp"
#include "topopt/plsm_basis.hpp"
#include "topopt/plsm_topology.hpp"
#include "topopt/simp.hpp"
#include "topopt/voxel.hpp"

namespace topopt {

// Off is the DEFAULT and is the entire existing world: `minimize_plastic` calls
// `simp_optimize` and not one line of this file executes.
enum class PlsmMode { Off, Parametric };

// ── ★ THE ERSATZ DENSITY: WHAT `rho_e` IS A FUNCTION OF ─────────────────────
//
// `VolumeFraction` is the production default and PR 327 is why: the shipped
// `--plsm` gradient — `DH_eta(phi)*|grad phi|` projected by `Psi^T` against a
// centre-sampled `H_eta` density — was measured WRONG BY UP TO 23%, flat across
// two decades of step size, in every level-set arm since PR 322 and in this
// optimiser. See plsm_frac.hpp for the derivation and the finite differences.
//
// `Heaviside` is PR 324/325/326's density, kept reachable so the change is an
// A/B on this path rather than a rewrite with nothing to compare against. It is
// no longer the default and no shipped job selects it.
enum class PlsmErsatz { Heaviside, VolumeFraction };

// ── ★★ THE COMPLIANCE SENSITIVITY'S WEIGHT ──────────────────────────────────
//
// The MEASURE says where the boundary moves; the WEIGHT says what that costs.
// They are separate choices and until 2026-08-13 only the measure had ever been
// verified.
//
// `Continuum` is the classical shape derivative's: the strain-energy density
// `q E0`, correct when material appears across the interface as a 0 -> 1 jump —
// which is the continuum picture and also the DISCRETE one when the stiffness
// law is LINEAR. GridapTopOpt's is (E = rho E0, p = 1). It is what PR 324/325/
// 326/327 and the shipped `--plsm` mode all ran.
//
// ★★ `Discrete` is the derivative of the stiffness law PRODUCTION ACTUALLY RUNS,
// which is SIMP at p = 3. R2 finite-differenced both against the same solves on
// the same design: the continuum weight reads +56.0% and +45.0% on two random
// directions, FLAT to five digits across a factor of ten in step size; the
// discrete weight reads −0.31% and +0.97%. Flatness is what makes it a gradient
// error and not noise. `Discrete` is therefore the default.
//
// ★ SINGLE COEFFICIENTS DO NOT SEPARATE THEM (6-7% against 1.5-1.8%), which is
// the same trap the sub-cell-psi ablation fell into: only a general direction,
// where many knots combine across the band, shows it.
enum class PlsmSensWeight { Continuum, Discrete };

// What a margin probe found on a candidate design. Returned by the driver's
// certification callback (`PlsmOptions::margin_probe`) so the optimiser can
// track the CERTIFIED margin without learning what a material, a build
// direction or a knockdown posture is.
struct PlsmMarginProbe {
  double margin = 0.0;        // the worst-case margin, as certified
  bool load_path_ok = false;  // ★ a severed design measures ~zero stress and
                              //   therefore an enormous, meaningless margin
  bool non_convergent = false;  // the certification solve did not converge
  double wall_s = 0.0;          // what this probe cost, measured by the driver
};

// ── THE KNOT LATTICE, PER AXIS, DERIVED FROM THE GRID ───────────────────────
//
// ★ R4 — NEVER FROM A MINIMUM. His grid is 128 x 31 x 118, a 4:1 slab. PR 323
// lost a day because GridapTopOpt's alpha rule read `minimum(el_size)` and sized
// a regularity length for a 31³ mesh; PR 324 reproduced the same trap
// deliberately (`--knots-min`) and measured that it is an ACCIDENT of this part
// that the thin axis happened to give a usable spacing — on a 128 x 8 x 118 slab
// it gives 1 and blows the coefficient count past the voxel count.
//
// So the rule below takes NO minimum and NO maximum over the axes: the spacing
// is the SAME NUMBER OF VOXELS on every axis, because the voxels are cubic and
// the thing being controlled is a LENGTH — the smallest structure the basis can
// express. `PlsmKnots` is three numbers throughout so a future anisotropic rule
// has somewhere to land without re-plumbing anything.
struct PlsmKnots {
  double dx = 0.0, dy = 0.0, dz = 0.0;  // VOXELS, per axis
};

// The production default: the knot spacing that ships, as a function of the
// grid. See the frontier in the task handoff's S2 for what it was chosen from
// and what the three columns cost at each point.
PlsmKnots plsm_knots_for_grid(const VoxelGrid& grid);

struct PlsmOptions {
  PlsmMode mode = PlsmMode::Off;

  // The basis. "gaussian" is PR 324's Arm 2 configuration and the default;
  // "wendland" is the compactly-supported C² alternative.
  std::string basis = "gaussian";

  // Knot spacing, VOXELS, PER AXIS. All three zero (the default) means "derive
  // it from the grid with plsm_knots_for_grid" — the production rule. Setting
  // them is how the S2 frontier was measured and how a job overrides the rule.
  PlsmKnots knots;

  // Support radius as a multiple of the spacing, per axis: R_a = support * D_a.
  // PR 324 measured that below 2x the supports leave gaps and the CAD-face
  // population degrades past SIMP's; 2 is the floor and the default.
  double support = 2.0;

  // ── ★ THE ERSATZ, AND WHAT eta STILL MEANS AFTER IT ──────────────────────
  PlsmErsatz ersatz = PlsmErsatz::VolumeFraction;

  // Sub-cell samples PER AXIS for the volume fraction: `f_v` is counted over a
  // k x k x k lattice inside each ACTIVE cell. PR 327 §S1(a) swept k and
  // established 4 as sufficient — the fraction changes by less than the run-to-
  // run floor beyond it, and the cost is O(k^3). Ignored under `Heaviside`.
  int frac_samples = 4;

  // The quadrature bandwidth multiplier: eps_q = frac_eps_mult * |grad phi| *
  // h/k. 1.0 is the DERIVED value, not a tuned one — at exactly that width the
  // tent is a partition of unity along the normal (plsm_frac.hpp), so the
  // estimator is smooth in alpha by construction.
  double frac_eps_mult = 1.0;

  // ★ THE MOLLIFIED VALUE (the production default). The hard sample indicator is
  // replaced by the exact ANTIDERIVATIVE of the mollifier the SENSITIVITY uses,
  // so the value and the gradient are two facts about ONE function. PR 327
  // §4(c)(ii): sub-1% on the volume finite difference where the hard count read
  // +182%, and 1.3-5.2% on the COMPLIANCE where the hard count was
  // noise-dominated at every affordable step. The two agree on the volume they
  // measure to 0.037%, so it buys differentiability without moving the geometry.
  bool frac_mollified = true;

  // ★ ABLATIONS, both defaulting to the MEASURED choice rather than to the
  // theoretically tidy one. `frac_sens_exact = false` factors psi_i out at the
  // cell centre and projects with `Psi^T` (worth ~15 percentage points of
  // gradient accuracy on a general direction, and NOTHING on a single
  // coefficient). `frac_eps_l1` scales the bandwidth by |grad phi|_1, which
  // Engquist-Tornberg-Tsai prove is the convergent choice in 3D and which PR 327
  // §5 M5 measured as mixed-to-negative HERE (-2.32/+7.61% against -1.33/+3.18%
  // without it). They exist so both are PRICED rather than assumed.
  bool frac_sens_exact = true;
  bool frac_eps_l1 = false;

  // ★★ THE COMPLIANCE WEIGHT. `Discrete` is the default and R2 is why (see
  // PlsmSensWeight). `Continuum` reproduces PR 324-327's gradient exactly and
  // exists so the control arm can be the control.
  PlsmSensWeight sens_weight = PlsmSensWeight::Discrete;

  // The ersatz band half-width, VOXELS, for `PlsmErsatz::Heaviside`.
  //
  // ★ 2.0 -> 1.0 (task 2026-08-13-plsm-production-settings, item 1). Measured as
  // a MATCHED PAIR at the shipped volume convention, which is the pairing that
  // was asked for because eta sits inside the perimeter functional: n_cut 28,934
  // -> 27,887 (-3.6%), carved 11.6466 -> 9.1155 (-21.7%), CAD 0.4461 -> 0.4373,
  // and margins IDENTICAL TO THREE DIGITS (3252.3 against 3251.0).
  //
  // ★ THE MAGNITUDE SUPERSEDES AN EARLIER CLAIM. -11.7% on internal surface was
  // measured at rung 0.68 on the probe path; at the shipped volume it is -3.6%.
  // Direction confirmed, magnitude a third of the earlier number.
  //
  // ★ AND UNDER `VolumeFraction` eta IS OUT OF THE DENSITY ENTIRELY. What still
  // reads it is listed at `PlsmRunResult::eta_voxels`.
  double eta_voxels = 1.0;

  // The seed fit / re-fit: Tikhonov ridge, the clamp on the target distance
  // (only the zero set carries geometry), and the CG budget.
  double ridge = 1e-6;
  double clamp_voxels = 6.0;
  int fit_cg_iterations = 2000;

  // The MMA step. `move` multiplies the DERIVED move limit (PR 324: the limit is
  // a LENGTH, gamma * hj_steps * h of interface motion, divided by how far a unit
  // coefficient move carries phi) — so 1.0 means "one voxel-arm step's worth".
  // `bound` sizes the coefficient box at +-bound x the largest seed coefficient.
  double move = 1.0;
  double bound = 4.0;
  double gamma = 0.1;
  int step_substeps = 24;

  // Approximate re-initialisation: re-distance phi ON THE GRID and RE-PROJECT it
  // onto the basis every N iterations, so the design variable stays the
  // coefficients. 0 = never. PR 324's Arm 2 ran at 5 and its ablation measured
  // that this is what keeps |grad phi| near 1 and therefore keeps the volume
  // measure honest.
  int refit_every = 5;
  int reinit_sweeps = 2;

  // ── ★★ THE STOPPING RULE ──────────────────────────────────────────────────
  //
  // ★ `max_iterations = 60` WAS WRONG IN BOTH DIRECTIONS, AND BOTH WERE
  // MEASURED. At the shipped rung 60 is too FEW — production's own run of record
  // reports last-10 compliance spreads of 4.43 / 10.24 / 20.40% under a
  // 40-iteration cap. At the light rung MORE IS WORSE: both Stage A arms PEAK
  // and then FALL (control 2609 at it80 -> 2183 at it120, -16.3%; the penalty
  // arm 2385 at it60 -> 1931, -19.0%), and PR 327 measured the same shape at the
  // shipped rung — a margin peaking at iteration 80 and falling 19.4% by 120
  // while compliance was FLAT.
  //
  // ★★ SO A RAISED CAP IS NOT THE FIX. Stopping AT THE PEAK recovers 16-19%.
  //
  // ★ AND COMPLIANCE CANNOT FIND THAT PEAK. PR 326 measured one arm's margin
  // DOUBLE between iterations 40 and 60 while its compliance moved 2%. A
  // compliance-plateau stop is not an acceptable substitute here, so the rule
  // below watches the CERTIFIED MARGIN and the compliance plateau is demoted to
  // a floor that can only fire when no margin probe is attached.
  //
  // `margin_probe` is supplied by the DRIVER, not built here: certifying needs a
  // material, a build direction, a knockdown posture and an acceptance
  // threshold, none of which an optimiser should learn about. Null (the default
  // when nothing attaches one) leaves the historical compliance-plateau rule in
  // place, so this whole block is inert unless a caller opts in.
  std::function<PlsmMarginProbe(const std::vector<double>& density)> margin_probe;

  // ★ THE CADENCE, AND ITS COST. A probe is ONE tight cold certification solve.
  // On his part that is about the cost of an iteration, so probing every
  // iteration would DOUBLE the run. Every margin curve in this line of work was
  // sampled every 10 iterations and that sampling resolved the peak: the
  // control's neighbours at 70 and 90 read 3233 and 3273 against the peak's
  // 3276, so a 10-iteration grid locates it to within 1.3% of its own value.
  // 10 therefore costs about one solve per ten iterations — ~10% of a run — and
  // buys a peak located to a tenth of the span the endpoint was missing by.
  // 0 disables the rule.
  int margin_probe_every = 10;

  // How many CONSECUTIVE probes may fail to improve on the best margin before
  // the run stops. 3 probes at cadence 10 is a 30-iteration window — wide enough
  // that the control's 3233 / 3276 / 3273 / 3198 tail does not stop it early at
  // 70, and narrow enough to stop before the 19.4% fall completes.
  int margin_plateau_probes = 3;

  // The relative improvement that COUNTS as an improvement. Twenty consecutive
  // certified iterates of one converged tail spread 0.15% (sd 0.04%), so 0.5% is
  // comfortably above the reproduction floor and well below any real move.
  double margin_plateau_tol = 0.005;

  // ★ THE HARD CEILING, KEPT AS A BACKSTOP. 120, not 60: the peak is at
  // iteration 60-80 on every curve measured, and the plateau window needs 30
  // iterations past it to fire. A run that reaches this number stopped on the
  // ceiling and says so (`PlsmRunResult::stop_reason`).
  int max_iterations = 120;

  // The seed topology. "holes" is PR 324's Arm 2 — a regular array of holes, no
  // SIMP anywhere. "inherit" seeds from SimpOptions::initial_design when the
  // driver has one (rung k+1 from rung k) and falls back to "holes" when it does
  // not, which is what makes the ladder's warm start work on this path.
  std::string seed = "inherit";
  double hole_period_voxels = 8.0;

  // ── S3: THE SOLVER WIN, ARMED ON THIS PATH BY DEFAULT ────────────────────
  // PR 324 measured 76% fewer solver steps and 59% less wall clock, on the same
  // design to seven significant figures, from LOOSENING the trajectory solve and
  // WARM STARTING it — and the two are MULTIPLICATIVE (4% and 44% alone). The
  // certification is a separate call at the production tolerance and is NOT
  // touched by either.
  double cg_tolerance_loose = 1e-4;  // 0 disables; else used for the trajectory
  bool warm_start = true;            // reuse the previous iterate's displacement

  int threads = 0;  // 0 = hardware concurrency
};

// The frozen-set signed distances the SMOOTH BOOLEAN is built from, plus the
// three population counts the load-path assertion checks.
//
// ★ THE FROZEN SET AS A SMOOTH BOOLEAN IS MANDATORY, NOT OPTIONAL, AND PR 324 §5
// IS WHY. An analytic phi cannot be discontinuous at the frozen-material
// boundary, so a fit leaks a handful of frozen voxels below the iso — 40 of
// 40,216 was enough — and `load_path_connected` then finds no route from the
// anchor to the load. EVERY fit was rejected, on the LOAD PATH and not on the
// margin. Stamping the mask back to hard 0/1 fixes the walk and costs most of
// the surface win (midpoint share 5.54% -> 51.31%). A level set does not need
// stamping: with solid = {phi < 0}, union is `min` and intersection is `max`, so
//
//     phi_eff = max( min(phi, phi_frozen_solid), -phi_frozen_void )
//
// is "what the optimiser chose, PLUS the frozen material, MINUS the frozen void"
// — exactly, smoothly, with no tags surviving into the result. It is also
// SELF-SECURING: a FrozenSolid voxel centre is at least half a voxel inside the
// frozen region, so phi_eff <= -0.5 voxels there BY CONSTRUCTION and the ersatz
// is H_eta(0.5 h) > 0.5 for any eta <= 2 voxels. `plsm_frozen_floor_occupancy`
// returns that floor so the guarantee is a MEASUREMENT, not a claim.
struct PlsmFrozenBoolean {
  std::vector<double> phi_solid;  // signed distance to the FrozenSolid set, VOXELS
  std::vector<double> phi_void;   // signed distance to the FrozenVoid  set, VOXELS
  std::size_t n_solid = 0;
  std::size_t n_void = 0;
  std::size_t n_active = 0;
  double spacing_mm = 0.0;   // the unit phi_solid / phi_void are measured in
};

// Build the two signed distances from an EFFECTIVE mask (the one
// `effective_design_mask` returns — Load/Fixture forced FrozenSolid, Empty
// normalised to FrozenVoid), so the boolean is built from the same set the run
// holds frozen and not from a second opinion about it.
PlsmFrozenBoolean plsm_build_frozen_boolean(const VoxelGrid& grid,
                                            const DesignMask& effective,
                                            int sweeps);

// The SMALLEST ersatz occupancy any FrozenSolid voxel can take under the smooth
// boolean, at this band width. > 0.5 is the load-path guarantee; the optimiser
// asserts it before its first solve and names the offending voxel count if it
// ever fails.
double plsm_frozen_floor_occupancy(const PlsmFrozenBoolean& fb, double eta_voxels);

// ── the run ────────────────────────────────────────────────────────────────

struct PlsmRunResult {
  // Shaped exactly like `simp_optimize`'s result so the ladder driver needs no
  // second code path: `physical_density` is the ersatz on the grid (the field
  // every downstream instrument reads), `volume_fraction` is the achieved
  // continuous fraction over the ACTIVE set — simp's own basis — and `design` is
  // a copy of `physical_density` (an RBF coefficient has no voxel, so there is no
  // honest per-voxel "design variable" to report; the coefficients are below).
  SimpOptimizeResult optimization;

  // ★ THE ANALYTIC EXPORT. 685 KB against rho.f64's 3.75 MB on his part, and
  // re-evaluable at ANY resolution — the design itself rather than a sampling of
  // it. `plsm_evaluate(lattice, basis, alpha, ...)` reconstructs phi on any
  // lattice; `run_job` writes these as `<prefix>_<vf>_alpha.f64` / `.meta`.
  std::vector<double> alpha;
  PlsmKnotLattice lattice;
  PlsmBasisKind basis_kind = PlsmBasisKind::Gaussian;
  // ── ★ WHAT STILL READS eta, STATED RATHER THAN LEFT TO BE FOUND ───────────
  //
  // Under `PlsmErsatz::VolumeFraction` eta is OUT OF THE DENSITY PATH ENTIRELY.
  // These are the places it survives, each with what was done about it:
  //
  //   the PRINTED predicate `{occ > 0.5}` — eta-free ALREADY, as a set. `H` is
  //     monotone with `H(0) = 0.5` exactly, so `{H_eta(-phi) > 0.5} == {phi < 0}`
  //     for every eta; an eight-fold change in eta was measured to move the
  //     extracted triangle count by ZERO. Under the fraction it is `{f_v > 0.5}`,
  //     which is the same set to O(1/k^3). Unchanged, deliberately.
  //   the F>=1 ANALYTIC EXPORT's field VALUES — eta DOES move where marching
  //     cubes puts a vertex on a crossing edge. ★ This is the ONE place item 1's
  //     eta = 1 still acts once the density is a fraction, and it is where the
  //     surface numbers come from. Kept, and reported as its own axis.
  //   `plsm_frozen_floor_occupancy` — the load-path guarantee. ★ SUPERSEDED, not
  //     merely satisfied: under the fraction a FrozenSolid cell is STAMPED to
  //     1.0 by the mask, so the floor is exactly 1 and carries no eta. The
  //     eta-dependent form is still computed and still asserted, because it is
  //     what the `Heaviside` path rests on and R7 does not permit deleting it.
  //   the reinitialisation's reporting band — reporting only.
  //
  //   ★ AND NOT `eps_q`. The quadrature bandwidth is tied to the SAMPLE SPACING
  //     and shrinks like 1/k; eta is fixed in voxels and shrinks with nothing.
  //     plsm_frac.hpp answers that objection at length.
  double eta_voxels = 1.0;
  PlsmErsatz ersatz = PlsmErsatz::VolumeFraction;
  PlsmSensWeight sens_weight = PlsmSensWeight::Discrete;
  int frac_samples = 0;
  double spacing_mm = 0.0;

  // ── the fraction's own bookkeeping, COUNTED rather than bounded ───────────
  std::size_t frac_cut_cells = 0;    // ACTIVE cells with MIXED sample signs
  std::size_t frac_full_cells = 0;
  std::size_t frac_empty_cells = 0;
  double frac_sample_wall_s = 0.0;   // sub-cell sampling, whole run
  double frac_sens_wall_s = 0.0;     // the band + the scatter, whole run

  // ── ★ THE TOPOLOGY COUNTERS, ON EVERY RUN (plsm_topology.hpp) ────────────
  // The constraint that produced them does NOT ship; these do, because they cost
  // milliseconds and they made every other finding in this line of work legible.
  PlsmVoidTopology topology;

  // ── ★ THE STOPPING RULE'S OWN RECORD ─────────────────────────────────────
  // "compliance-plateau" | "margin-plateau" | "iteration-ceiling" |
  // "non-convergent" | "cancelled". A run that stopped on the ceiling must not
  // read like one that converged.
  std::string stop_reason = "iteration-ceiling";
  std::vector<int> margin_probe_iterations;
  std::vector<double> margin_probe_values;
  std::vector<char> margin_probe_load_path_ok;
  double margin_probe_wall_s = 0.0;  // what the cadence cost, measured
  int margin_peak_iteration = 0;     // 0 = no probe was ever accepted
  double margin_peak = 0.0;

  // The frozen-set guarantee, measured on this run.
  double frozen_floor_occupancy = 0.0;
  std::size_t frozen_solid_voxels = 0;
  std::size_t frozen_void_voxels = 0;
  std::size_t active_voxels = 0;

  // Per-iteration trajectory (compliance, achieved fraction, CG iterations,
  // wall) — the same observability the SIMP path emits, so a PLSM run is
  // readable with the instruments that already exist.
  std::vector<double> history_compliance;
  std::vector<double> history_volume_fraction;
  std::vector<int> history_cg_iterations;
  std::vector<double> history_wall_s;
  int best_iteration = 0;
  double total_solve_wall_s = 0.0;
  double total_wall_s = 0.0;
};

// Optimise `alpha` under the volume constraint of `options.volume_fraction` over
// the ACTIVE voxels — the identical constraint `simp_optimize`'s mask-aware
// overload imposes, so a ladder rung means the same thing on both paths.
//
// Throws std::invalid_argument on the same argument errors as `simp_optimize`
// (bad params, mask size), plus a non-positive knot spacing or an unknown basis.
PlsmRunResult plsm_optimize(const VoxelGrid& grid, const SimpParams& params,
                            const std::vector<DirichletBC>& bcs,
                            const std::vector<NodalLoad>& loads,
                            const SimpOptions& options, const DesignMask& mask,
                            const PlsmOptions& plsm);

}  // namespace topopt

#endif  // TOPOPT_PLSM_HPP_
