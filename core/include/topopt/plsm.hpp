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
#include <string>
#include <vector>

#include "topopt/fea.hpp"
#include "topopt/plsm_basis.hpp"
#include "topopt/simp.hpp"
#include "topopt/voxel.hpp"

namespace topopt {

// Off is the DEFAULT and is the entire existing world: `minimize_plastic` calls
// `simp_optimize` and not one line of this file executes.
enum class PlsmMode { Off, Parametric };

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

  // The ersatz band half-width, VOXELS. rho = H_eta(-phi) with GridapTopOpt's
  // H_eta (the same one levelset_kernel.hpp carries).
  double eta_voxels = 2.0;

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

  int max_iterations = 60;

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
  double eta_voxels = 2.0;
  double spacing_mm = 0.0;

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
