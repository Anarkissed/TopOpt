#pragma once

#include <atomic>
#include <functional>
#include <stdexcept>
#include <vector>

#include "topopt/fea.hpp"
#include "topopt/voxel.hpp"

namespace topopt {

// SIMP density interpolation, compliance and sensitivities (ROADMAP M3.2).
//
// SIMP (Solid Isotropic Material with Penalization) drives each design voxel's
// density rho in [rho_min, 1] and penalizes intermediate densities so the
// optimizer converges toward black/white (solid/void) layouts. ARCHITECTURE §4
// locks the classic Sigmund 99-line interpolation with penalty p = 3:
//
//   E(rho) = clamp(rho, rho_min, 1)^p * E0
//
// The density floor rho_min keeps a "void" design voxel at a small *positive*
// stiffness. This is deliberately > 0 so such voxels are NOT dropped by the M3.1
// void-DOF safety gate (which targets genuinely Empty, out-of-design voxels that
// contribute no element at all). The isotropic Poisson ratio is density-
// independent (standard SIMP).
//
// The density filter (radius >= 1.5 voxels) and the Optimality-Criteria update
// are M3.3; the full volume-fraction-targeted loop is M3.4. This header provides
// only the objective (compliance) and its gradient (sensitivities) that those
// stages consume.

struct SimpParams {
  double youngs_modulus = 0.0;  // E0, base solid Young's modulus (> 0)
  double poisson = 0.0;         // nu, in (-1, 0.5)
  double penalty = 3.0;         // p, penalization exponent (ARCHITECTURE §4: 3)
  double density_min = 1e-3;    // rho floor, in (0, 1]
};

// SIMP Young's modulus for a design density: E(rho) = clamp(rho, rho_min, 1)^p
// * E0. Throws std::invalid_argument if the params are non-physical
// (youngs_modulus <= 0, penalty <= 0, or density_min not in (0, 1]).
double simp_youngs(const SimpParams& params, double density);

// A uniform initial design field: every solid voxel gets density `value`, every
// Empty voxel gets 0. Size = grid.voxel_count(), indexed like the grid. This is
// the "density field" a SIMP run starts from (typically value = the target
// volume fraction).
std::vector<double> simp_uniform_density(const VoxelGrid& grid, double value);

// Result of a SIMP compliance analysis.
struct SimpCompliance {
  FeaSolution solution;             // penalized displacement field
  double compliance = 0.0;          // c = f^T u  (= sum_e E(rho_e) u_e^T K_unit u_e)
  std::vector<double> dcompliance;  // dc/drho_e per voxel, 0 on Empty voxels
  CgInfo cg;                        // solver diagnostics from the penalized solve
};

// Solve the SIMP-penalized linear-elastic system for the design field `density`
// (size grid.voxel_count(); Empty-voxel entries are ignored, solid entries are
// clamped to [rho_min, 1]) and return:
//   * the displacement solution,
//   * the compliance c = f^T u = sum_e E(rho_e) * (u_e^T K_unit u_e), and
//   * the per-voxel compliance sensitivity
//        dc/drho_e = -p * rho_e^(p-1) * E0 * (u_e^T K_unit u_e)   (<= 0),
//     which is 0 on Empty voxels.
// K_unit is the unit-modulus Hex8 element stiffness hex8_stiffness(1, nu,
// spacing). The solve routes through the void-gated Jacobi-CG path
// (fea_solve_cg), so under-constrained / void-only systems are rejected per
// M3.1. `tolerance` / `max_iterations` are forwarded to the CG solver.
//
// Throws std::invalid_argument if `density` has the wrong size or the params are
// non-physical; propagates fea_solve_cg's throws (bad BC/load index, or a CG
// non-convergence std::runtime_error).
SimpCompliance simp_compliance(const VoxelGrid& grid, const SimpParams& params,
                               const std::vector<double>& density,
                               const std::vector<DirichletBC>& bcs,
                               const std::vector<NodalLoad>& loads,
                               double tolerance = 1e-8, int max_iterations = 0);

// ---------------------------------------------------------------------------
// Density filter + Optimality-Criteria update (ROADMAP M3.3).
//
// ARCHITECTURE §4 locks a "density filter (radius >= 1.5 voxels)" as the SIMP
// mesh-independence regularizer and an "Optimality Criteria updater" as the
// design updater. Both are provided here as reusable operators; the full
// volume-fraction-targeted loop with convergence criteria is M3.4.

// Precomputed linear density filter over a voxel grid's design (solid) voxels.
// The physical density of design voxel e is the weighted average of the design
// densities of the solid voxels i whose centre lies within `radius` voxels of e:
//     xPhys_e = ( sum_i H_ei x_i ) / ( sum_i H_ei ),
//     H_ei    = max(0, radius - dist(e,i))      (dist in voxel units)
// `radius` is in voxel units (ARCHITECTURE §4: ">= 1.5 voxels"), independent of
// the grid spacing. Empty voxels are not design variables: they are excluded
// from every neighbourhood and map to 0. The map x -> xPhys is linear (xPhys =
// M x with M_ei = H_ei / sum_k H_ek); H is symmetric, so filtering an
// objective/constraint sensitivity from physical space back to design space is
// the transpose M^T (the chain rule d/dx = M^T d/dxPhys).
//
// Weights are stored in compressed sparse row form keyed by grid voxel index.
struct DensityFilter {
  std::size_t voxel_count = 0;         // == grid.voxel_count()
  std::vector<std::size_t> row_start;  // CSR row offsets, size voxel_count + 1
  std::vector<std::size_t> neighbor;   // neighbour voxel indices (solid only)
  std::vector<double> weight;          // H_ei for each neighbour entry
  std::vector<double> weight_sum;      // Hs_e = sum_i H_ei (0 for Empty voxels)

  // Forward filter: design densities x (grid-indexed) -> physical densities
  // xPhys (grid-indexed; 0 on Empty voxels). Throws std::invalid_argument if
  // x.size() != voxel_count.
  std::vector<double> filter_density(const std::vector<double>& x) const;

  // Adjoint (transpose) filter for the chain rule: given a sensitivity in
  // physical space `dfdxphys` (grid-indexed; d f / d xPhys), return the
  // sensitivity in design space d f / d x (grid-indexed; 0 on Empty voxels).
  // Used to filter both the compliance and volume sensitivities before the OC
  // update. Throws std::invalid_argument if dfdxphys.size() != voxel_count.
  std::vector<double> filter_sensitivity(
      const std::vector<double>& dfdxphys) const;
};

// Build the density filter for `grid` with neighbourhood `radius` in voxel units
// (ARCHITECTURE §4: >= 1.5). Throws std::invalid_argument if radius <= 0.
DensityFilter make_density_filter(const VoxelGrid& grid, double radius);

// Mask-aware density filter (ROADMAP M3.7). Identical weights to the overload
// above, but only Active solid voxels (mask[e] == MaskValue::Active) are
// design/filter voxels: FrozenSolid, FrozenVoid and Empty voxels are excluded
// from every Active voxel's neighbourhood, so the filter does not average
// (bleed) physical density across a mask boundary. Frozen/Empty voxels get an
// empty filter row (weight_sum 0) and map to 0 under filter_density — the
// mask-aware SIMP loop pins their physical density separately (FrozenSolid -> 1,
// FrozenVoid -> 0). With an all-Active mask this reproduces the plain overload
// bit-for-bit (which delegates here). Throws std::invalid_argument if radius <= 0
// or mask.size() != grid.voxel_count().
DensityFilter make_density_filter(const VoxelGrid& grid, double radius,
                                  const DesignMask& mask);

// One Optimality-Criteria design update (ROADMAP M3.3) for the volume-constrained
// minimum-compliance problem. Inputs (all grid-indexed; Empty voxels ignored):
//   density       current design x_e in [density_min, 1],
//   dcompliance   the physical-space compliance sensitivity dc/dxPhys_e (<= 0),
//                 as returned by simp_compliance evaluated on the filtered field.
// The update filters dc/dxPhys and the (unit) volume sensitivity through `filter`
// (chain rule), then advances the design by the classic OC step
//     x_new_e = clamp( x_e * sqrt( -dc_e / (lambda * dv_e) ),
//                       [x_e - move, x_e + move] intersect [density_min, 1] ),
// where the Lagrange multiplier lambda is found by bisection so the *physical*
// volume sum_e xPhys(x_new)_e equals volume_fraction * (number of design voxels)
// (the constraint is enforced on the filtered density, matching the density-
// filter OC updater). Returns the grid-indexed updated design (Empty voxels 0).
//
// Throws std::invalid_argument on a size mismatch, a non-physical parameter
// (volume_fraction not in (0,1], move <= 0, density_min not in (0,1]), or a
// filter whose voxel_count does not match the grid.
std::vector<double> oc_update(const VoxelGrid& grid, const DensityFilter& filter,
                              const std::vector<double>& density,
                              const std::vector<double>& dcompliance,
                              double volume_fraction, double move = 0.2,
                              double density_min = 1e-3);

// ---------------------------------------------------------------------------
// Single-field Heaviside projection + beta continuation (ROADMAP M6.3).
//
// Minimum-length-scale control via the smoothed Heaviside threshold of Wang/
// Lazarov/Sigmund (2011), single-field ("cheap") variant — no robust eroded/
// nominal/dilated three-solve formulation. The analysis chain becomes
//     x (design) --density filter--> rho_tilde --projection--> rho_bar
//       --clamp[rho_min,1]--> E = rho_bar^p * E0,
// with (eta = 0.5 threshold, beta = sharpness):
//     rho_bar = (tanh(beta*eta) + tanh(beta*(rho_tilde - eta)))
//             / (tanh(beta*eta) + tanh(beta*(1 - eta))).
// The formulation (schedule, move limits, OC ratio guard, volume constraint on
// the PROJECTED density, derivative chained BEFORE the filter transpose) is
// locked by tests/fixtures/benchmarks.json "formulation_locked" and gated by
// test_gate_v2 (Gate V2, projected).

// The projection value rho_bar(rho_tilde) above. Monotone increasing, fixes
// 0 -> 0 and 1 -> 1, and rho_bar(eta) = eta at eta = 0.5. Throws
// std::invalid_argument if beta <= 0 (or not finite) or eta outside (0, 1).
double heaviside_project(double rho_tilde, double beta, double eta = 0.5);

// Its derivative d rho_bar / d rho_tilde
//     = beta * sech^2(beta*(rho_tilde - eta))
//     / (tanh(beta*eta) + tanh(beta*(1 - eta)))    (> 0, underflows toward 0
// far from the threshold at high beta — see the OC guard note on
// SimpOptions::projection). Same validation as heaviside_project.
double heaviside_project_derivative(double rho_tilde, double beta,
                                    double eta = 0.5);

// One stage of the beta-continuation schedule: run `iterations` OC updates at
// sharpness `beta` with OC move limit `move`, then continue with the next
// stage (re-converging at each step).
struct ProjectionStage {
  double beta = 1.0;    // projection sharpness for this stage (> 0)
  double move = 0.2;    // OC move limit for this stage (> 0)
  int iterations = 50;  // OC iterations in this stage (>= 1)
};

// The locked continuation schedule of benchmarks.json "formulation_locked":
// beta in {1, 2, 4, 8, 16, 32} (doubling), exactly 50 OC iterations per stage
// (300 total), move 0.2 for beta <= 8, damped to 0.1 at beta = 16 and 0.05 at
// beta = 32 (undamped high-beta moves produce structure-splitting oscillation;
// beta = 64 is excluded — measured, continuation destroys the structure).
std::vector<ProjectionStage> heaviside_continuation_schedule();

// ---------------------------------------------------------------------------
// Full volume-fraction-targeted SIMP optimization loop (ROADMAP M3.4).
//
// Ties the M3.2 penalized compliance/sensitivities together with the M3.3
// density filter and Optimality-Criteria update into the classic minimum-
// compliance SIMP loop (ARCHITECTURE §4). Starting from a uniform design at the
// target volume fraction, each iteration:
//   1. xPhys = filter.filter_density(x)         (physical/analysis density)
//   2. (c, dc/dxPhys) = simp_compliance(xPhys)  (penalized solve + gradient)
//   3. x = oc_update(x, dc/dxPhys, volfrac)     (constraint on physical volume)
// and stops when the design change max_e |x_new - x| falls below `change_tol`
// (converged) or after `max_iterations` (the iteration cap). The volume
// constraint is enforced on the physical (filtered) density by oc_update every
// step, so the achieved physical volume fraction tracks the target throughout.

struct SimpOptions {
  double volume_fraction = 0.5;  // target physical volume fraction, in (0, 1]
  double filter_radius = 1.5;    // density-filter radius, voxel units (§4: >= 1.5)
  double move = 0.2;             // OC move limit
  int max_iterations = 60;       // hard iteration cap (a convergence criterion)
  double change_tol = 0.01;      // stop when max_e |x_new - x| < change_tol
  double cg_tolerance = 1e-8;    // penalized-FEA CG tolerance (tight: §V2 gate)
  int cg_max_iterations = 0;     // 0 -> Eigen CG default (2 * n_dof)

  // Heaviside projection + beta continuation (M6.3). EMPTY (the default)
  // disables projection entirely: the loop is the unchanged M3.4 formulation
  // above and `move` / `max_iterations` govern it. Non-empty: the loop runs
  // the stages in order — each stage runs its own `iterations` OC updates at
  // its own `beta` and `move` (stopping a stage early when the design change
  // drops below change_tol, then continuing with the next stage), and `move` /
  // `max_iterations` above are NOT consulted. The analysis density becomes
  // rho_bar = heaviside_project(filter(x), stage beta, projection_eta); the
  // volume constraint is enforced on the PROJECTED density; the compliance and
  // volume sensitivities chain the projection derivative BEFORE the filter
  // transpose; and the OC ratio -dc/(lambda*dv) is computed with UNCLAMPED dv,
  // holding the design variable (ratio treated as 1) where it is non-finite
  // (0/0 at high beta: a voxel whose whole filter neighbourhood has zero
  // projection derivative). All locked by benchmarks.json "formulation_locked"
  // — in particular, dv must never be clamped at an absolute floor (measured:
  // that drags exactly the should-not-move voxels to the bound and destroys
  // the design at beta >= 32).
  std::vector<ProjectionStage> projection;
  double projection_eta = 0.5;  // projection threshold, in (0, 1)

  // Progress + cancellation (M7.0a). Both are optional and absent by default;
  // when absent the loop's behavior and per-iteration work are unchanged (the
  // only added cost is one null check per OC iteration).
  //
  // `progress` is invoked once per COMPLETED OC iteration with the 1-based
  // global iteration number (monotone across projection stages), the
  // compliance of the analysis density at the START of that iteration, and
  // the design change it produced — the same values recorded in
  // SimpOptimizeResult::history. The callback must not throw; it runs on the
  // optimizing thread.
  //
  // `cancel` is a caller-owned flag polled once per OC iteration, at its
  // start (so a cancel request is honoured before the next FEA solve). When
  // observed true the loop stops: no further iterations run, the result's
  // `cancelled` is true, `converged` is false, and the returned fields are
  // still mutually consistent (SimpOptimizeResult contract) — a cancelled
  // run pays one final consistency solve on the partially-optimized field.
  // The pointee must outlive the simp_optimize call.
  std::function<void(int iteration, double compliance, double change)> progress;
  const std::atomic<bool>* cancel = nullptr;
};

// One recorded step of the SIMP trajectory.
struct SimpIteration {
  double compliance = 0.0;       // compliance of xPhys at the START of the step
  double change = 0.0;           // max_e |x_new - x| produced by this step's OC
  double volume_fraction = 0.0;  // achieved physical volume fraction after the step
};

// Result of simp_optimize. `design`, `physical_density` and `compliance` are
// mutually consistent: compliance == compliance(physical_density) (a final solve
// on the converged field), and physical_density == filter(design) — or, when a
// projection schedule is set (M6.3), physical_density ==
// heaviside_project(filter(design), last stage's beta, projection_eta) and
// `volume_fraction` is the achieved PROJECTED volume fraction.
struct SimpOptimizeResult {
  std::vector<double> design;            // final design variable x (grid-indexed)
  std::vector<double> physical_density;  // final xPhys = filter(x) (grid-indexed)
  double compliance = 0.0;               // compliance of physical_density
  double initial_compliance = 0.0;       // compliance of the uniform start design
  double volume_fraction = 0.0;          // achieved physical volume fraction
  int iterations = 0;                    // OC updates performed
  bool converged = false;                // stopped on change_tol (not the cap)
  // True iff the run stopped because options.cancel was observed true (M7.0a).
  // A cancelled result is still valid and self-consistent (fields above hold
  // for the state at the cancelled iteration; history has `iterations`
  // entries), but it is a partial optimization: converged is false and
  // initial_compliance is 0 when cancelled before the first iteration.
  bool cancelled = false;
  std::vector<SimpIteration> history;    // per-iteration trajectory (size iterations)
};

// Run the full SIMP loop above and return the optimized design. The initial
// design is uniform at options.volume_fraction on every solid voxel (Empty
// voxels stay 0 and are not design variables). Solves route through the M3.1
// void-gated Jacobi-CG path (fea_solve_cg via simp_compliance).
//
// Throws std::invalid_argument if the params are non-physical (simp_compliance
// rules), volume_fraction not in (0, 1], move <= 0, max_iterations < 1,
// change_tol < 0, or filter_radius <= 0 (make_density_filter). Throws
// std::runtime_error if a penalized CG solve fails to converge (so the caller
// never optimizes on a garbage field).
SimpOptimizeResult simp_optimize(const VoxelGrid& grid, const SimpParams& params,
                                 const std::vector<DirichletBC>& bcs,
                                 const std::vector<NodalLoad>& loads,
                                 const SimpOptions& options);

// ---------------------------------------------------------------------------
// Passive regions: mask-aware SIMP optimization (ROADMAP M3.7).
//
// The same minimum-compliance loop as simp_optimize above, with per-voxel
// passive regions applied through `mask` (grid-indexed, size voxel_count()):
//   * FrozenSolid voxels: physical density pinned to 1 and excluded from the OC
//     update (kept full material);
//   * FrozenVoid voxels: physical density pinned to 0, excluded from the design
//     AND from the FEA stiffness (they contribute no element — realised by
//     solving on an analysis grid where FrozenVoid voxels are treated as Empty,
//     so the M3.1 void-DOF gate handles any nodes left attached only to void);
//   * Active voxels: free design variables, updated by the OC step subject to
//     the volume constraint volume_fraction * (number of Active voxels).
// Load and Fixture voxels (M1.6) are treated as implicitly FrozenSolid whatever
// their mask entry, so they are retained at density 1 — the §7 V3 Load/Fixture
// retention gate becomes structural rather than emergent. Empty voxels are
// never design variables: their mask entry is ignored (voxel.hpp) and they are
// excluded from the Active-voxel budget, so a part that does not fill its
// bounding grid still targets volume_fraction of the PART, not of the grid.
// The density filter does not bleed across mask boundaries
// (make_density_filter mask overload).
//
// The returned `design` and `physical_density` carry the pins (FrozenSolid 1,
// FrozenVoid 0), so unlike the unconstrained overload physical_density is NOT
// filter(design) at frozen voxels; `volume_fraction` is the achieved fraction
// over the Active voxels. With an all-Active mask and no Load/Fixture voxels the
// result matches the unconstrained overload.
//
// Throws std::invalid_argument for the same argument errors as simp_optimize,
// plus mask.size() != grid.voxel_count(); std::runtime_error if a penalized CG
// solve fails to converge or the FrozenVoid pattern leaves the structure
// under-constrained (M3.1 void gate).
SimpOptimizeResult simp_optimize(const VoxelGrid& grid, const SimpParams& params,
                                 const std::vector<DirichletBC>& bcs,
                                 const std::vector<NodalLoad>& loads,
                                 const SimpOptions& options,
                                 const DesignMask& mask);

// ---------------------------------------------------------------------------
// Multi-variant runner (ROADMAP M3.6).
//
// One job (grid + material + BCs + loads + shared loop options) is optimized at
// several requested volume fractions (e.g. [0.7, 0.5, 0.3]), producing one
// design + printable mesh per fraction plus each variant's compliance. This is
// the §5 pipeline's "SIMP loop (target volume fraction; repeat per requested
// variant) -> marching cubes -> mesh cleanup" stage restricted to the isotropic
// optimizer: it runs simp_optimize once per fraction and extracts the cleaned
// isosurface of each result, so a caller gets the three meshes and the
// per-variant compliance report from a single call. (Orientation, settings and
// export are later milestones; this task is the variant fan-out only.)

// One optimized variant: the full SIMP result at a requested volume fraction and
// the cleaned marching-cubes surface extracted from its physical density.
struct SimpVariant {
  double requested_volume_fraction = 0.0;  // the SimpOptions.volume_fraction used
  SimpOptimizeResult optimization;         // full SIMP result (compliance, ...)
  TriangleMesh mesh;                       // cleaned isosurface (largest component)
};

// Result of a multi-variant run: one SimpVariant per requested volume fraction,
// in the same order as the input `volume_fractions`.
struct MultiVariantResult {
  std::vector<SimpVariant> variants;

  // The per-variant compliance report: the final compliance of each variant, in
  // the requested order (variants[i].optimization.compliance).
  std::vector<double> compliances() const;
};

// Run simp_optimize once per entry of `volume_fractions` (each overriding
// options.volume_fraction; every other options field is shared across variants),
// extract and clean a marching-cubes mesh at `iso` (0.5 for M3.5/M3.6) from each
// result's physical density, and return one SimpVariant per fraction in input
// order. The input `options.volume_fraction` is ignored — each variant uses its
// own fraction.
//
// Throws std::invalid_argument if `volume_fractions` is empty or any entry is
// not in (0, 1] (plus everything simp_optimize / make_density_filter validate);
// propagates simp_optimize's std::runtime_error if any variant's penalized CG
// solve fails to converge.
MultiVariantResult simp_optimize_variants(
    const VoxelGrid& grid, const SimpParams& params,
    const std::vector<DirichletBC>& bcs, const std::vector<NodalLoad>& loads,
    const SimpOptions& options, const std::vector<double>& volume_fractions,
    double iso = 0.5);

}  // namespace topopt
