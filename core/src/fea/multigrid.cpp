// Geometric-multigrid-preconditioned Conjugate Gradient solver for the voxel
// FEA linear system Ku=f (handoff 072). The Jacobi-preconditioned CG in
// assembly.cpp averages ~550 iterations at 64^3; the profile (handoff 071)
// named geometric multigrid as the 10-100x lever. This file implements a
// standard V-cycle multigrid used as the CG preconditioner (MG-preconditioned
// CG), the robust choice for SIMP FEA.
//
// Design (justified in docs/handoffs/072-geometric-multigrid-solver.md):
//   * Hierarchy — vertex (node) coarsening by 2x per axis: a coarse node
//     coincides with every other fine node. Trilinear interpolation is the
//     prolongation P (coarse -> fine); restriction is its transpose R = P^T
//     (full weighting) — the variational pair.
//   * Coarse operator — GALERKIN A_c = P^T A P (rediscretisation is cheaper but
//     less robust under the SIMP soft-void modulus contrast rho_min^p; Galerkin
//     inherits the density-graded stiffness automatically, which is why it is
//     the standard robust choice and the one the task calls for).
//   * Smoother — damped Jacobi (omega=0.6, kPreSmooth pre + kPostSmooth post
//     sweeps; 1+1 today). Symmetric smoother + equal pre/post sweeps + R=P^T +
//     SPD coarse solve => the V-cycle is a symmetric positive-definite operator,
//     so it is a valid CG preconditioner. (This line read "2 pre + 2 post" until
//     the multigrid-component-sweep task; the constants below have been 1+1
//     since, and the comment had drifted. It now names them rather than
//     restating a number that can go stale again.)
//   * Dirichlet BCs and void DOFs — the hierarchy is built on the SAME BC-reduced,
//     void-gated operator the Jacobi-CG path solves (fea_detail::assemble_reduced
//     + void_dof_survivors). A coarse node-DOF is active iff its coincident fine
//     node-DOF is active, so fixed/void DOFs propagate up every level.
//   * Coarsest level — solved exactly with a cached SimplicialLDLT factorisation.
//
// CORRECTNESS: MG-CG solves the identical reduced system Kgg u = rg as
// fea_solve_cg, to the same relative-residual tolerance, so it converges to the
// same u. If the hierarchy cannot be built (grid not 2x-divisible, coarsest too
// large) or MG-CG fails to converge / produces a non-finite field, the solver
// FALLS BACK to the exact Jacobi-CG path rather than return a wrong or
// unconverged answer.

#include "topopt/fea.hpp"

#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstddef>
#include <cstring>
#include <memory>
#include <stdexcept>
#include <utility>
#include <vector>

#include "topopt/coarsen.hpp"

#include <Eigen/Dense>
#include <Eigen/IterativeLinearSolvers>
#include <Eigen/SparseCholesky>
#include <Eigen/SparseCore>

#include "algebraic_coarsen.hpp"
#include "fea_matfree.hpp"
#include "geneo.hpp"
#include "recycle.hpp"
#include "fea_reduced.hpp"

namespace topopt {

namespace {

using fea_detail::ReducedSystem;
using fea_detail::SpMat;
using fea_detail::Vec;
using Trip = Eigen::Triplet<double>;

// --- Multigrid tuning constants ------------------------------------------
constexpr double kJacobiOmega = 0.6;   // damped-Jacobi smoother weight
constexpr int kPreSmooth = 1;          // pre-smoothing sweeps (== post: SPD V-cycle)
constexpr int kPostSmooth = 1;         // 1+1 is the most wall-efficient on these grids
constexpr int kCoarseExtraSmooth = 0;  // extra sweeps below the finest level: none
constexpr int kCycleGamma = 1;         // 1 = V-cycle (the only cycle shipped)
// The coarsenability constants live in topopt/coarsen.hpp so the SEAM that pads
// the grid (expand_design_domain) and this SOLVER that enforces the rule cannot
// drift (handoff: multigrid-coarsenability-padding). Local aliases keep the hot
// loops below reading the short names.
constexpr int kMinCoarseElems = kMgMinCoarseElems;  // stop coarsening below this many elems/axis
constexpr int kCoarseDofCap = kMgCoarseDofCap;      // coarsest solved directly; cap its size
constexpr int kMinLevels = kMgMinLevels;            // < 2 usable levels -> not worth MG, fall back

// MG-CG iteration budget before giving up and falling back to Jacobi-CG. On
// well-conditioned / coherent SIMP fields MG-CG converges in ~10-30 iterations;
// under adversarial random high-contrast coefficients geometric MG degrades and
// can need thousands of iterations (much SLOWER than Jacobi). Rather than grind
// through that, bail after this budget and let the exact Jacobi-CG fallback
// finish.
//
// RAISED 100 -> 300 (handoff 128). The stagnation diagnosis (125) measured a
// BORDERLINE band of real design-box + clearance systems whose V-cycle DOES
// contract but slowly: they need ~120-300 cycles (their Jacobi fallback converged
// in <= ~20 k iters, i.e. the operator is well-posed, just weakly preconditioned
// by geometric MG). At the old 100-cycle budget those bailed to Jacobi every
// solve; at 300 they now CARRY MG at a fraction of the Jacobi cost. Healthy grids
// still converge in ~11-40 cycles (§1b of 125) — far under both budgets — so
// raising the ceiling is byte-identical for them (the budget is never reached).
// The genuinely pathological end (occ0.4+hole; §1d) does not converge even at
// 2000 cycles, so it still bails — but now it bails at most 3 times before the
// 127 stagnation LATCH stops even building the hierarchy. There is deliberately
// NO within-solve early residual/rate bail: 127 MEASURED that no early signature
// separates slow-but-converging (relative residual 2-8 at iter 15, converges by
// ~60-90) from truly stagnating, and the binding rule is never to abandon a solve
// MG would have solved. The only cutoffs are this full-cycle budget and the
// wall-clock guard below (a coarse safety net, not a convergence signal).
constexpr int kMgIterBudget = 300;

// Per-attempt wall-clock guard. DEFAULT 0 = DISABLED: the deterministic
// cycle budget (kMgIterBudget) is the sole bound. A fixed seconds value
// cannot sit "far above the converging envelope" at every scale — on a
// 128³ production grid one V-cycle costs ~1-2 s, so a legitimately
// converging borderline solve (200-300 cycles) takes 5-10 MINUTES; any
// wall cutoff below that kills exactly the solves budget-300 exists to
// rescue, and does so non-deterministically (thermal variation moves
// the trip point run to run). Worst case disabled: one stagnating
// attempt burns the full cycle budget, at most kMgLatchThreshold times
// per run before the latch stops building. Set > 0 explicitly only as
// an opt-in pathology net.
constexpr double kMgAttemptWallGuardSec = 0.0;

// --- Per-run multigrid stagnation LATCH (handoff 127, Amendment 2) -----------
// A high-contrast SIMP field (the ~1e-9 design-box + clearance-void case) can
// make the V-cycle stagnate: the hierarchy BUILDS but MG-CG never contracts, so it
// burns the full kMgIterBudget before falling back — and pays the expensive
// hierarchy build on EVERY solve of the run for nothing. The latch stops that:
// after kMgLatchThreshold consecutive STAGNATED solves (built a hierarchy but hit
// the budget without converging), stop attempting MG for the rest of the run —
// skip the build, go straight to the matrix-free Jacobi-CG. State is thread-local
// and RESET at run start by the driver (fea_matfree_reset_mg_stagnation_latch); a
// solve that DOES converge resets the consecutive counter, so a healthy run never
// latches and is bit-identical to before. Deterministic; cg_multigrid stays 0 in
// iterations.csv while latched. The build is ~60% of a stagnating solve, so
// skipping it is the dominant saving (measured ~2.5x faster once latched).
//
// NO EARLY (within-solve) FAST-FAIL. An earlier revision bailed a solve to Jacobi
// once its residual was still above a threshold after a probe iteration. Measured
// on real design-box solves that was UNSAFE: they routinely sit at relative
// residual 2-8 at iter 15 (a CG transient under a weak V-cycle) yet converge by
// iter ~60-90 — well within the budget. No early residual signature separates
// "slow-but-converging" from "stagnating" on these systems, and the binding rule
// is never to abandon a solve MG would have solved. So the only cutoff stays the
// existing full-budget one; the latch merely stops REPEATING a proven-doomed build.
constexpr int kMgLatchThreshold = 3;  // consecutive stagnations -> latch MG off

// Thread-local because the driver issues a run's solves sequentially on one
// thread (the matvec worker threads never touch this); reset per run.
thread_local int g_mg_consecutive_stagnations = 0;
thread_local bool g_mg_latched = false;

// --- MEASUREMENT-ONLY latch RE-ARM period (task solver-speed-arm-and-diagnose)
// The one thing handoff 2026-07-27-mg-stagnation-phase0 §7 named as missing to
// close its own B4: "a latch-disabled measurement build (opt-in flag; no
// production behavior change) so MG is attempted on every solve of every rung
// and the developed-rung verdict is OBSERVED rather than inferred". Phase 0
// could only bracket the maintainer's part with synthetic fixtures; the part
// itself is the fixture, and this is the flag that lets it be run.
//
// 0 = SHIPPED, and it is the default: the latch is permanent for the run, so
// production is byte-identical (the re-arm block below is unreachable at 0 and
// touches no state). n > 0 = after n consecutive LATCHED solves, clear the
// latch and let ONE solve attempt a hierarchy again. n = 1 is the
// "latch-disabled" build §7 asks for: every solve attempts MG.
//
// A re-armed attempt that stagnates re-latches IMMEDIATELY rather than paying
// kMgLatchThreshold stagnations again: g_mg_consecutive_stagnations is left at
// kMgLatchThreshold - 1, so the single stagnation the retry produces trips the
// latch on its own. That bounds the probe's tax at one wasted build + one
// wasted cycle budget per period instead of three, which is what makes a
// period-1 arm affordable on a real 128^3 job at all. A retry that CONVERGES
// clears the counter through the existing `solved` branch and multigrid simply
// carries from there — which is the outcome the measurement exists to detect.
thread_local int g_mg_rearm_period = 0;
thread_local int g_mg_latched_solves = 0;
// Cumulative-since-reset re-arm accounting, so the probe can price its own tax
// rather than have it inferred: how many retries were granted and how many of
// those retries CARRIED. Both are 0 in production by construction.
thread_local long long g_mg_rearm_attempts = 0;
thread_local long long g_mg_rearm_carries = 0;

// --- Parity padding of the MG index space (task: multigrid-odd-axis-cliff;
// scope widened by task multigrid-deep-block-pad) ---
// 0 = OFF (legacy: any grid the coarsening rule rejects — odd fine axis OR
// all-even deep-blocked — rejects the hierarchy), 1 = AUTO (default: pad the
// hierarchy's INDEX SPACE to mg_pad_target whenever the UNPADDED grid would be
// rejected; grids that already coarsen take the legacy path byte-identically),
// 2 = FORCE (tests only: pad even a fully-coarsenable grid by one extra 2^L
// block per axis, to prove the pad is bit-identical on a control grid).
// Thread-local like the latch: the driver issues a run's solves on one thread.
constexpr int kMgPadOff = 0, kMgPadAuto = 1, kMgPadForce = 2;
thread_local int g_mg_parity_pad_mode = kMgPadAuto;

// --- Component tuning (task: multigrid-component-sweep) ----------------------
// The V-cycle's recipe, overridable by a measurement harness and by NOTHING
// else. Thread-local for the same reason the latch and the pad mode are: the
// driver issues a run's solves on one thread. The static_asserts below BIND the
// header's defaults to the constants above, so a change to either that does not
// change the other fails the build rather than silently re-tuning production.
thread_local fea_detail::MgTuning g_mg_tuning;

static_assert(fea_detail::MgTuning{}.omega == kJacobiOmega,
              "MgTuning default omega must be the shipped kJacobiOmega");
static_assert(fea_detail::MgTuning{}.pre_smooth == kPreSmooth,
              "MgTuning default pre_smooth must be the shipped kPreSmooth");
static_assert(fea_detail::MgTuning{}.post_smooth == kPostSmooth,
              "MgTuning default post_smooth must be the shipped kPostSmooth");
static_assert(fea_detail::MgTuning{}.coarse_extra_smooth == kCoarseExtraSmooth,
              "MgTuning default coarse_extra_smooth must be the shipped 0");
static_assert(fea_detail::MgTuning{}.cycle_gamma == kCycleGamma,
              "MgTuning default cycle_gamma must be the shipped V-cycle");
static_assert(fea_detail::MgTuning{}.max_levels == 0,
              "MgTuning default max_levels must defer to the builder");
static_assert(!fea_detail::MgTuning{}.deepest,
              "MgTuning default must stop at the shipped DOF cap");
static_assert(fea_detail::MgTuning{}.coarse_dof_cap == kMgCoarseDofCap,
              "MgTuning default coarse_dof_cap must be the shipped kMgCoarseDofCap");
static_assert(fea_detail::MgTuning{}.smoother == fea_detail::MgSmoother::ScalarJacobi,
              "MgTuning default smoother must be the shipped scalar damped Jacobi");

// --- Coarse-space seam (task: hybrid-amg-coarsening-probe) -------------------
// The harness-only override for how levels 2.. are built (see the long note in
// fea_matfree.hpp). Thread-local and DEFAULT-EMPTY: production installs nothing,
// so `g_mg_coarse_hook` is false everywhere and build_mf_hierarchy takes the
// geometric branch it always has. The tripwire tests/unit/test_mg_coarse_hook.cpp
// asserts that default and the bit-identity of a solve after install+clear.
thread_local fea_detail::MgCoarseSpaceHook g_mg_coarse_hook;

// --- Algebraic level-1 coarsening (task: algebraic-level1-coarsening) --------
// THE ARMING FLAG, and the LIBRARY DEFAULT IS OFF (THE ONE RULE): every
// reference run — Gate-V2, the property suite, every core test — must stay
// byte-identical, so nothing but an explicit fea_set_mg_algebraic_level1(true)
// can put a solve on the algebraic path. Thread-local, like mg_set_tuning, the
// coarse-space hook and the stagnation latch: a run's solves are issued on one
// thread. The tripwire below asserts the default, and test_mg_algebraic_level1
// asserts a solve after arm+disarm is bit-identical to one that never armed.
thread_local bool g_mg_alg_level1 = false;
static_assert(!kMgAlgebraicLevel1LibraryDefaultOn,
              "the algebraic level-1 coarse space must ship DISARMED in the "
              "library: the reference world is byte-identical only while every "
              "solve that did not explicitly ask for it takes the geometric "
              "hierarchy");

// The LAST algebraic build's report, for observability only. No solver decision
// reads it; run_info.json echoes it so an armed run can be audited and a
// disarmed one shows the honest zeros.
thread_local fea_detail::AlgCoarsenStats g_mg_alg_stats;

// The LAST matrix-free hierarchy's per-level DOF counts, finest first, written
// by BOTH builders so a V-cycle can be priced in DOF-weighted applies whichever
// shape ran. Pure observation.
thread_local std::vector<int> g_mg_last_level_dims;  // defined-and-filled below

// The tuning RESOLVED once per solve, so the smoother's inner loop reads plain
// locals rather than a thread-local on every sweep. Snapshotting also means a
// single V-cycle can never see a half-changed recipe.
struct MgOpts {
  double omega = kJacobiOmega;
  int pre = kPreSmooth;
  int post = kPostSmooth;
  int coarse_extra = kCoarseExtraSmooth;
  int gamma = kCycleGamma;
  bool point_block = false;
};

MgOpts mg_opts_now() {
  const fea_detail::MgTuning& t = g_mg_tuning;
  MgOpts o;
  o.omega = t.omega;
  o.pre = t.pre_smooth;
  o.post = t.post_smooth;
  o.coarse_extra = t.coarse_extra_smooth;
  o.gamma = t.cycle_gamma;
  o.point_block = (t.smoother == fea_detail::MgSmoother::PointBlockJacobi);
  return o;
}

// Sweeps to run at GLOBAL level `level` (0 == finest). The extra sweeps land on
// the coarse levels only — the SMO paper's fix — and land on pre and post
// equally, which is what keeps the cycle symmetric.
inline int sweeps_at(int base, const MgOpts& o, int level) {
  return level == 0 ? base : base + o.coarse_extra;
}

// --- Point-block (3x3 nodal) Jacobi data -------------------------------------
// One entry per node that owns at least one active DOF: the (up to three) local
// DOF ids of that node, and the INVERSE of the 3x3 diagonal block of A over
// them. A component the level does not carry (fixed, void, or coarsened away)
// gets dof == -1 and a zero row/column in the inverse, so the sweep simply does
// not relax it — the same treatment inverse_diagonal gives a guarded diagonal.
//
// Empty unless the point-block smoother is selected, so the shipped scalar path
// builds none of this and pays nothing.
struct BlockDiag {
  std::vector<int> dof;     // 3 per block, -1 where the component is absent
  std::vector<double> inv;  // 9 per block, row-major
  bool empty() const { return dof.empty(); }
};

// Invert one node's 3x3 block. `present[c]` selects the components this node
// actually carries; absent rows/columns are identity-padded before the inverse
// and zeroed after, so the result is exactly the inverse of the PRESENT
// sub-block embedded in a 3x3. The block is a principal submatrix of an SPD
// operator, hence SPD, so LLT is the right factorisation; if it nonetheless
// fails (or produces a non-finite entry), fall back to the reciprocal diagonal
// — i.e. degrade to the scalar smoother for that node rather than poison it.
void invert_node_block(const double blk[9], const bool present[3], double out[9]) {
  Eigen::Matrix3d M = Eigen::Matrix3d::Identity();
  for (int i = 0; i < 3; ++i)
    for (int j = 0; j < 3; ++j)
      if (present[i] && present[j]) M(i, j) = blk[i * 3 + j];
  Eigen::LLT<Eigen::Matrix3d> llt(M);
  Eigen::Matrix3d Minv = Eigen::Matrix3d::Zero();
  bool ok = (llt.info() == Eigen::Success);
  if (ok) {
    Minv = llt.solve(Eigen::Matrix3d::Identity());
    ok = Minv.allFinite();
  }
  if (!ok) {  // scalar degrade for this node only
    for (int i = 0; i < 3; ++i)
      for (int j = 0; j < 3; ++j) out[i * 3 + j] = 0.0;
    for (int i = 0; i < 3; ++i) {
      const double d = present[i] ? blk[i * 3 + i] : 0.0;
      out[i * 3 + i] = (d > 0.0) ? 1.0 / d : 0.0;
    }
    return;
  }
  for (int i = 0; i < 3; ++i)
    for (int j = 0; j < 3; ++j)
      out[i * 3 + j] = (present[i] && present[j]) ? Minv(i, j) : 0.0;
}

// Point-block data for an ASSEMBLED level, read straight off A via its active
// map (node*3+comp -> local dof id).
BlockDiag build_block_diag(const SpMat& A, const std::vector<int>& active) {
  BlockDiag B;
  const std::size_t nnodes = active.size() / 3;
  for (std::size_t nd = 0; nd < nnodes; ++nd) {
    int d[3];
    bool present[3];
    bool any = false;
    for (int c = 0; c < 3; ++c) {
      d[c] = active[nd * 3 + static_cast<std::size_t>(c)];
      present[c] = d[c] >= 0;
      any = any || present[c];
    }
    if (!any) continue;
    double blk[9] = {0, 0, 0, 0, 0, 0, 0, 0, 0};
    for (int i = 0; i < 3; ++i)
      for (int j = 0; j < 3; ++j)
        if (present[i] && present[j]) blk[i * 3 + j] = A.coeff(d[i], d[j]);
    double inv[9];
    invert_node_block(blk, present, inv);
    for (int c = 0; c < 3; ++c) B.dof.push_back(d[c]);
    for (int k = 0; k < 9; ++k) B.inv.push_back(inv[k]);
  }
  return B;
}

// One point-block Jacobi sweep given a precomputed residual r:
//   x[node] <- x[node] + omega * Binv[node] * r[node].
inline void block_apply(const BlockDiag& B, double omega, const Vec& r, Vec& x) {
  const std::size_t nb = B.dof.size() / 3;
  for (std::size_t b = 0; b < nb; ++b) {
    const int* d = &B.dof[b * 3];
    const double* M = &B.inv[b * 9];
    double rv[3];
    for (int i = 0; i < 3; ++i) rv[i] = d[i] >= 0 ? r[d[i]] : 0.0;
    for (int i = 0; i < 3; ++i) {
      if (d[i] < 0) continue;
      x[d[i]] += omega * (M[i * 3 + 0] * rv[0] + M[i * 3 + 1] * rv[1] +
                          M[i * 3 + 2] * rv[2]);
    }
  }
}

// Actual active DOFs the UNPADDED halving walk would leave at its structural
// stop depth (mg_unpadded_stop_depth): the kept fine DOFs whose node
// coordinates are all multiples of 2^d — exactly the coincident-node injection
// rule every level applies (see build_hierarchy / build_mf_hierarchy), applied
// transitively. Active counts are monotone non-increasing in depth and the
// builder walks until they fit kMgCoarseDofCap or the structure blocks, so
// `this count <= kMgCoarseDofCap` predicts EXACTLY whether the unpadded build
// succeeds — except the vanishing corner (actives hitting 0 at some level
// makes the builder reject while the count reads 0 <= cap); there the
// prediction errs toward NOT padding, i.e. today's rejection is preserved.
// Returns -1 when the question does not arise (an odd fine axis, a grid the
// conservative bound already accepts, or no halving possible). O(ng), no
// allocation — run once per hierarchy build, only on the deep-block branch.
template <class GetGdof>
std::int64_t mg_unpadded_stop_active(int fex, int fey, int fez, int ng,
                                     GetGdof&& gdof_of) {
  if ((fex & 1) || (fey & 1) || (fez & 1)) return -1;
  if (mg_grid_coarsenable(fex, fey, fez)) return -1;
  const int d = mg_unpadded_stop_depth(fex, fey, fez);
  if (d < 1) return -1;
  const int nnx = fex + 1, nny = fey + 1;
  const int step = 1 << d;
  std::int64_t n = 0;
  for (int r = 0; r < ng; ++r) {
    const int node = gdof_of(r) / 3;
    const int a = node % nnx;
    const int b = (node / nnx) % nny;
    const int c = node / (nnx * nny);
    if (a % step == 0 && b % step == 0 && c % step == 0) ++n;
  }
  return n;
}

// The element extents the hierarchy is BUILT on: the real (fex,fey,fez), or the
// padded index-space extents when the parity pad engages. The padded extents
// only ever add virtual HIGH-side planes whose nodes stay inactive (-1), so the
// operator, RHS and kept-DOF numbering are untouched; only the hierarchy's
// geometric bookkeeping grows. Returns true when padding engaged.
// `unpadded_stop_active` is mg_unpadded_stop_active for this solve's kept-DOF
// map (or -1 when not applicable): the deep-block branch consults it so a
// bound-rejected grid whose ACTUAL active set still fits the cap at the walk
// stop — a build that succeeds today — is left byte-identically alone.
bool mg_effective_extents(int fex, int fey, int fez, int& pex, int& pey,
                          int& pez, std::int64_t unpadded_stop_active = -1) {
  pex = fex;
  pey = fey;
  pez = fez;
  const int mode = g_mg_parity_pad_mode;
  if (mode == kMgPadOff) return false;
  // Engage only when the UNPADDED grid would be rejected: an odd fine axis
  // (structural — no halving is ever possible), or an all-even deep block
  // whose actual actives at the walk stop exceed the cap. A grid that already
  // coarsens — by the conservative bound or by its actual active count —
  // keeps the legacy path byte-identically; the acceptance rule itself
  // (all-axes-even + DOF cap) is never relaxed: padded extents halve cleanly
  // at every level. Widening the scope to deep blocks re-tested PR #151's
  // harm finding first (task: multigrid-deep-block-pad — see that handoff);
  // the 127 stagnation latch and the 128 budget-300 raise stand unchanged
  // and bound any field where the padded hierarchy cannot contract.
  if (mode != kMgPadForce) {
    const bool fine_odd = (fex & 1) || (fey & 1) || (fez & 1);
    if (!fine_odd) {
      if (mg_grid_coarsenable(fex, fey, fez)) return false;
      if (unpadded_stop_active >= 0 && unpadded_stop_active <= kMgCoarseDofCap)
        return false;  // the unpadded build succeeds today: leave it alone
    }
  }
  int px, py, pz;
  const int L = mg_pad_target(fex, fey, fez, px, py, pz);
  if (L == 0) return false;  // too small to host any hierarchy: legacy rejection
  if (mode == kMgPadForce) {
    // Grow every axis by a full 2^L block so the pad is genuinely exercised
    // even when the real extents are already multiples of 2^L.
    const int step = 1 << L;
    px += step;
    py += step;
    pz += step;
  }
  pex = px;
  pey = py;
  pez = pz;
  return pex != fex || pey != fey || pez != fez;
}

// Wall-clock deadline for a single MG-CG attempt (handoff 128). steady_clock is
// monotone (unaffected by wall-clock adjustments). Returns time_point::max() when
// the guard is disabled (guard_sec <= 0) so the comparison in the loop is a cheap
// always-false and the attempt runs to the cycle budget.
std::chrono::steady_clock::time_point mg_attempt_deadline(double guard_sec) {
  if (!(guard_sec > 0.0)) return std::chrono::steady_clock::time_point::max();
  return std::chrono::steady_clock::now() +
         std::chrono::duration_cast<std::chrono::steady_clock::duration>(
             std::chrono::duration<double>(guard_sec));
}

// One grid level of the hierarchy. Active DOFs are the free, non-void DOFs at
// this level, numbered 0..n-1 (matching the rows/cols of A).
struct Level {
  int nx = 0, ny = 0, nz = 0;  // node dims (elements + 1)
  int n = 0;                   // number of active DOFs
  SpMat A;                     // operator (n x n), SPD
  Vec Dinv;                    // 1/diag(A) for the Jacobi smoother (0 where guarded)
  SpMat P;                     // prolongation coarse(level+1) -> this (n x n_coarse)
  std::vector<int> active;     // (node*3+comp) -> local dof id, or -1
  BlockDiag pbd;               // point-block smoother data; EMPTY on the shipped path
  bool coarsest = false;
  // coarsest-level exact solve; held by pointer so Level stays movable in a
  // std::vector (Eigen's factorisation objects are not moveable).
  std::shared_ptr<Eigen::SimplicialLDLT<SpMat>> chol;

  int node_index(int a, int b, int c) const { return (c * ny + b) * nx + a; }
};

// Trilinear (vertex-coarsening) interpolation weights along one axis: which
// coarse indices contribute to fine index f, and with what weight. A fine node
// at an even index coincides with a coarse node (weight 1); an odd fine node is
// the average of its two coarse neighbours (0.5 each).
inline int axis_weights(int f, int (&ci)[2], double (&cw)[2]) {
  if ((f & 1) == 0) {
    ci[0] = f / 2;
    cw[0] = 1.0;
    return 1;
  }
  ci[0] = (f - 1) / 2;
  cw[0] = 0.5;
  ci[1] = (f + 1) / 2;
  cw[1] = 0.5;
  return 2;
}

// Compute 1/diag(A), guarding non-positive diagonals (shouldn't occur on an SPD
// operator, but a zero would poison the Jacobi smoother — leave it at 0 so that
// DOF is simply not relaxed).
Vec inverse_diagonal(const SpMat& A) {
  const Vec d = A.diagonal();
  Vec dinv(d.size());
  for (int i = 0; i < d.size(); ++i)
    dinv[i] = (d[i] > 0.0) ? 1.0 / d[i] : 0.0;
  return dinv;
}

// Memory-frugal Galerkin coarse operator A_c = P^T A P, computed one COLUMN BLOCK
// of P at a time so the A*P intermediate is only a block wide instead of the full
// (peak-doubling) product. Each coarse column A_c[:,j] = P^T A P[:,j] is computed
// independently, so the result equals P.transpose()*(A*P) to summation roundoff.
// Used by the matrix-free path, where the level-1 operator A1 (~O(voxels) nnz) is
// large enough that the full A1*P intermediate is a couple hundred MB on the
// design box; blocking cuts that transient to tens of MB. (The assembled path
// keeps the plain product, byte-for-byte.)
SpMat galerkin_pt_a_p_frugal(const SpMat& A, const SpMat& P) {
  const int nc = static_cast<int>(P.cols());
  constexpr int kBlockCols = 4096;
  const SpMat Pt = P.transpose();
  std::vector<Trip> trips;
  for (int c0 = 0; c0 < nc; c0 += kBlockCols) {
    const int w = std::min(kBlockCols, nc - c0);
    const SpMat APblk = A * P.middleCols(c0, w);   // A.rows x w
    const SpMat Acblk = Pt * APblk;                 // nc x w (block of A_c columns)
    for (int j = 0; j < w; ++j)
      for (SpMat::InnerIterator it(Acblk, j); it; ++it)
        trips.emplace_back(static_cast<int>(it.row()), c0 + j, it.value());
  }
  SpMat Ac(nc, nc);
  Ac.setFromTriplets(trips.begin(), trips.end());
  return Ac;
}

// Build the multigrid hierarchy from the finest active operator A0 whose active
// DOFs sit on the node grid (nx0,ny0,nz0) with the given active map. Returns the
// levels finest-first, or an empty vector if a usable hierarchy (>= kMinLevels
// with a small enough coarsest level) cannot be built — the caller then falls
// back to Jacobi-CG. `frugal` selects the column-blocked coarse Galerkin product
// (matrix-free path, lower peak); default false keeps the plain product the
// assembled path has always used, byte-for-byte.
//
// `max_levels_here` caps the number of levels in THIS vector (0 = uncapped, the
// shipped behaviour); `global_level0` is the depth the first of them sits at in
// the whole hierarchy, which the point-block build and the caller's level
// accounting need. Both default to the production values, so the shipped call
// is unchanged.
std::vector<Level> build_hierarchy(const SpMat& A0, int nx0, int ny0, int nz0,
                                   std::vector<int> active0, bool frugal = false,
                                   int max_levels_here = 0,
                                   int global_level0 = 0) {
  const fea_detail::MgTuning& t = g_mg_tuning;
  const int dof_cap = t.coarse_dof_cap;
  const bool point_block = (t.smoother == fea_detail::MgSmoother::PointBlockJacobi);
  // A single-level request cannot seed a hierarchy at all; the caller's
  // coarsest-alone path is what expresses it.
  if (max_levels_here == 1) return {};
  (void)global_level0;
  std::vector<Level> levels;
  Level fine;
  fine.nx = nx0;
  fine.ny = ny0;
  fine.nz = nz0;
  fine.n = static_cast<int>(A0.cols());
  fine.A = A0;
  fine.Dinv = inverse_diagonal(A0);
  fine.active = std::move(active0);
  levels.push_back(std::move(fine));

  while (true) {
    // Depth cap (sweep A): stop before the level that would exceed it.
    if (max_levels_here > 0 &&
        static_cast<int>(levels.size()) >= max_levels_here)
      break;
    const Level& f = levels.back();
    const int fex = f.nx - 1, fey = f.ny - 1, fez = f.nz - 1;  // fine element dims
    // Coarsen only while every axis is even and stays >= kMinCoarseElems.
    if ((fex & 1) || (fey & 1) || (fez & 1)) break;
    const int cex = fex / 2, cey = fey / 2, cez = fez / 2;
    if (cex < kMinCoarseElems || cey < kMinCoarseElems || cez < kMinCoarseElems)
      break;
    const int cnx = cex + 1, cny = cey + 1, cnz = cez + 1;

    // Coarse active DOFs: a coarse node-DOF is active iff its coincident fine
    // node-DOF (2a,2b,2c) is active. Number them 0..nc-1.
    std::vector<int> cactive(static_cast<std::size_t>(cnx) * cny * cnz * 3, -1);
    int nc = 0;
    for (int c = 0; c < cnz; ++c)
      for (int b = 0; b < cny; ++b)
        for (int a = 0; a < cnx; ++a) {
          const int fnode = f.node_index(2 * a, 2 * b, 2 * c);
          const int cnode = (c * cny + b) * cnx + a;
          for (int comp = 0; comp < 3; ++comp)
            if (f.active[static_cast<std::size_t>(fnode) * 3 + comp] >= 0)
              cactive[static_cast<std::size_t>(cnode) * 3 + comp] = nc++;
        }
    if (nc == 0) break;

    // Prolongation P (fine active rows x coarse active cols): each fine active
    // DOF interpolates from up to 8 coarse nodes (same component). Coarse nodes
    // that are inactive (fixed/void) are dropped from the stencil (weight 0), the
    // standard Dirichlet/void treatment; the coincident-node identity rows keep P
    // full column rank, so A_c = P^T A P stays SPD.
    std::vector<Trip> ptrips;
    ptrips.reserve(static_cast<std::size_t>(f.n) * 8);
    for (int fc = 0; fc < f.nz; ++fc)
      for (int fb = 0; fb < f.ny; ++fb)
        for (int fa = 0; fa < f.nx; ++fa) {
          const int fnode = f.node_index(fa, fb, fc);
          int hasActive = 0;
          for (int comp = 0; comp < 3; ++comp)
            if (f.active[static_cast<std::size_t>(fnode) * 3 + comp] >= 0)
              hasActive = 1;
          if (!hasActive) continue;
          int ia[2], ib[2], ic[2];
          double wa[2], wb[2], wc[2];
          const int na = axis_weights(fa, ia, wa);
          const int nb = axis_weights(fb, ib, wb);
          const int ncz = axis_weights(fc, ic, wc);
          for (int comp = 0; comp < 3; ++comp) {
            const int row =
                f.active[static_cast<std::size_t>(fnode) * 3 + comp];
            if (row < 0) continue;
            for (int x = 0; x < na; ++x)
              for (int y = 0; y < nb; ++y)
                for (int z = 0; z < ncz; ++z) {
                  const int cnode = (ic[z] * cny + ib[y]) * cnx + ia[x];
                  const int col =
                      cactive[static_cast<std::size_t>(cnode) * 3 + comp];
                  if (col < 0) continue;  // inactive coarse node -> weight 0
                  ptrips.emplace_back(row, col, wa[x] * wb[y] * wc[z]);
                }
          }
        }
    SpMat P(f.n, nc);
    P.setFromTriplets(ptrips.begin(), ptrips.end());
    P.makeCompressed();

    // Galerkin coarse operator A_c = P^T A P. The assembled path materialises the
    // product stepwise (plain Eigen sparse*sparse, byte-for-byte unchanged); the
    // matrix-free path uses the column-blocked frugal form to bound the A*P peak.
    SpMat Ac;
    if (frugal) {
      Ac = galerkin_pt_a_p_frugal(f.A, P);
    } else {
      const SpMat AP = f.A * P;        // n x nc
      Ac = P.transpose() * AP;         // nc x nc, symmetric
    }
    Ac.makeCompressed();

    levels.back().P = std::move(P);

    Level coarse;
    coarse.nx = cnx;
    coarse.ny = cny;
    coarse.nz = cnz;
    coarse.n = nc;
    coarse.A = std::move(Ac);
    coarse.Dinv = inverse_diagonal(coarse.A);
    coarse.active = std::move(cactive);
    levels.push_back(std::move(coarse));

    // Small enough for a direct coarse solve. `deepest` (sweep A's "maximum the
    // builder allows") suppresses this stop so coarsening continues until an
    // axis structurally blocks — a smaller, cheaper bottom solve, more levels.
    if (nc <= dof_cap && !t.deepest) break;
  }

  // Reject a hierarchy too shallow to help, or whose coarsest level is still too
  // big for a direct factorisation (the caller falls back to Jacobi-CG).
  if (static_cast<int>(levels.size()) < kMinLevels) return {};
  if (levels.back().n > dof_cap) return {};

  // Point-block smoother data, built only when that smoother is selected (so
  // the shipped path allocates none of it). The coarsest level is solved
  // directly and never smoothed, hence is skipped.
  if (point_block)
    for (std::size_t i = 0; i + 1 < levels.size(); ++i)
      levels[i].pbd = build_block_diag(levels[i].A, levels[i].active);

  // Factor the coarsest operator for the exact bottom solve.
  Level& bottom = levels.back();
  bottom.coarsest = true;
  bottom.chol = std::make_shared<Eigen::SimplicialLDLT<SpMat>>();
  bottom.chol->compute(bottom.A);
  if (bottom.chol->info() != Eigen::Success) return {};  // fall back
  return levels;
}

// The HYBRID sub-hierarchy (task: hybrid-amg-coarsening-probe): levels 1.. built
// from A1 and a caller-supplied list of PROLONGATORS instead of by halving the
// grid. Never reached unless a harness installed a coarse-space hook; production
// calls build_hierarchy above, unchanged.
//
// Only the coarse SPACES come from outside. Every operator is still this file's
// own Galerkin product A_c = P^T A P (the same frugal, column-blocked one the
// matrix-free path already uses), the restriction is still R = P^T, and the
// bottom level is still factored here — so the cycle stays symmetric positive
// definite and remains a valid CG preconditioner whatever aggregation produced
// the P's. Returns {} on ANY malformed input, and the caller then falls back to
// the geometric builder: a hook cannot make the solver do something unsound, at
// worst it declines to help.
//
// Algebraic levels carry no node grid. `nx/ny/nz` and `active` stay unset on
// them, which is safe because the cycle reads only A, Dinv, P and chol —
// `active` is consulted solely by build_block_diag, and the POINT-BLOCK smoother
// (which needs a nodal structure a general aggregation does not have) is
// REFUSED on this path rather than approximated.
std::vector<Level> build_hierarchy_from_prolongators(
    const SpMat& A1, int cnx, int cny, int cnz, std::vector<int> cactive,
    const std::vector<fea_detail::MgCoo>& Ps) {
  const fea_detail::MgTuning& t = g_mg_tuning;
  if (Ps.empty()) return {};
  if (t.smoother != fea_detail::MgSmoother::ScalarJacobi) return {};

  std::vector<Level> levels;
  Level one;
  one.nx = cnx;
  one.ny = cny;
  one.nz = cnz;
  one.n = static_cast<int>(A1.cols());
  one.A = A1;
  one.Dinv = inverse_diagonal(A1);
  one.active = std::move(cactive);
  levels.push_back(std::move(one));

  for (const fea_detail::MgCoo& coo : Ps) {
    const Level& f = levels.back();
    // Shape and content are CHECKED, not trusted.
    if (coo.rows != f.n || coo.cols <= 0 || coo.cols >= f.n) return {};
    if (coo.row.size() != coo.col.size() || coo.row.size() != coo.val.size())
      return {};
    if (coo.val.empty()) return {};
    std::vector<Trip> trips;
    trips.reserve(coo.val.size());
    for (std::size_t k = 0; k < coo.val.size(); ++k) {
      const int r = coo.row[k], c = coo.col[k];
      if (r < 0 || r >= coo.rows || c < 0 || c >= coo.cols) return {};
      trips.emplace_back(r, c, coo.val[k]);
    }
    SpMat P(coo.rows, coo.cols);
    P.setFromTriplets(trips.begin(), trips.end());
    P.makeCompressed();

    SpMat Ac = galerkin_pt_a_p_frugal(f.A, P);
    Ac.makeCompressed();
    levels.back().P = std::move(P);

    Level coarse;
    coarse.n = coo.cols;
    coarse.A = std::move(Ac);
    coarse.Dinv = inverse_diagonal(coarse.A);
    levels.push_back(std::move(coarse));
  }

  // The same two acceptance rules the geometric builder applies.
  if (static_cast<int>(levels.size()) < kMinLevels) return {};
  if (levels.back().n > t.coarse_dof_cap) return {};

  Level& bottom = levels.back();
  bottom.coarsest = true;
  bottom.chol = std::make_shared<Eigen::SimplicialLDLT<SpMat>>();
  bottom.chol->compute(bottom.A);
  if (bottom.chol->info() != Eigen::Success) return {};
  return levels;
}

// One smoother sweep. SCALAR damped Jacobi — x <- x + omega * Dinv .* (b - A x)
// — is the shipped path and the only one a default-tuned process takes; the
// point-block branch applies the per-node 3x3 inverse to the same residual.
inline void jacobi_sweep(const Level& L, const Vec& b, Vec& x, const MgOpts& o) {
  const Vec r = b - L.A * x;
  if (o.point_block && !L.pbd.empty()) {
    block_apply(L.pbd, o.omega, r, x);
    return;
  }
  x += o.omega * (L.Dinv.array() * r.array()).matrix();
}

// Recursive symmetric gamma-cycle: return an approximate solution of A_l x = b.
// gamma == 1 is the V-cycle (shipped); gamma == 2 the W-cycle, which repeats the
// coarse-grid correction — recomputing the residual between repetitions — before
// post-smoothing. Equal pre/post smoothing (a self-adjoint smoother) + R = P^T +
// an SPD coarse solve keep the cycle a symmetric positive-definite operator at
// every gamma, so it stays a valid CG preconditioner. `global_level` is this
// level's depth in the WHOLE hierarchy (the matrix-free path's coarse vector
// starts at global level 1), which is what decides whether the extra coarse
// smoothing applies.
Vec v_cycle(const std::vector<Level>& levels, int l, const Vec& b,
            const MgOpts& o, int global_level) {
  const Level& L = levels[static_cast<std::size_t>(l)];
  if (L.coarsest) return L.chol->solve(b);

  Vec x = Vec::Zero(L.n);
  const int npre = sweeps_at(o.pre, o, global_level);
  const int npost = sweeps_at(o.post, o, global_level);
  for (int s = 0; s < npre; ++s) jacobi_sweep(L, b, x, o);

  for (int g = 0; g < o.gamma; ++g) {
    const Vec r = b - L.A * x;
    const Vec bc = L.P.transpose() * r;            // restrict residual (R = P^T)
    const Vec ec = v_cycle(levels, l + 1, bc, o, global_level + 1);
    x += L.P * ec;                                  // prolongate + correct
  }

  for (int s = 0; s < npost; ++s) jacobi_sweep(L, b, x, o);
  return x;
}

// MG-preconditioned CG on A x = b (A == levels[0].A). Stops on relative residual
// ||b - A x|| / ||b|| <= tol (matching Eigen's CG criterion). Returns false and
// leaves diagnostics in *iters/*resid if it does not converge within max_it or
// the iterate goes non-finite (the caller then falls back).
bool mgpcg(const std::vector<Level>& levels, const Vec& b, double tol,
           int max_it, Vec& x, int& iters, double& resid) {
  const SpMat& A = levels[0].A;
  const double bnorm = b.norm();
  iters = 0;
  resid = 0.0;
  if (!(bnorm > 0.0)) {          // zero RHS -> zero solution, trivially converged
    x = Vec::Zero(A.cols());
    return true;
  }
  const double threshold = tol * bnorm;

  const MgOpts opts = mg_opts_now();
  x = Vec::Zero(A.cols());
  Vec r = b;                              // r = b - A*0
  Vec z = v_cycle(levels, 0, r, opts, 0);  // z = M^{-1} r
  Vec p = z;
  double rz = r.dot(z);
  if (!std::isfinite(rz)) return false;

  const auto deadline = mg_attempt_deadline(kMgAttemptWallGuardSec);
  for (int k = 1; k <= max_it; ++k) {
    // Wall-clock safety net (handoff 128): bail this attempt to the exact
    // Jacobi-CG fallback if it has run past the guard. `iters` already reflects
    // the cycles done, so mg_cycles_attempted is honest on the guarded exit.
    if (std::chrono::steady_clock::now() > deadline) return false;
    const Vec Ap = A * p;
    const double pAp = p.dot(Ap);
    if (!(pAp > 0.0) || !std::isfinite(pAp)) return false;  // breakdown -> fall back
    const double alpha = rz / pAp;
    x += alpha * p;
    r -= alpha * Ap;
    iters = k;
    const double rn = r.norm();
    resid = rn / bnorm;
    if (rn <= threshold) return x.allFinite();
    Vec znew = v_cycle(levels, 0, r, opts, 0);
    const double rznew = r.dot(znew);
    if (!std::isfinite(rznew)) return false;
    const double beta = rznew / rz;
    p = znew + beta * p;
    rz = rznew;
    z.swap(znew);
  }
  return false;  // hit the iteration cap without converging
}

// Jacobi-preconditioned CG on the survivor system (Kgg, rg) — the exact fallback,
// numerically identical to fea_solve_cg's inner solve. Throws std::runtime_error
// on non-convergence (same guard as fea_solve_cg).
Vec jacobi_cg_fallback(const SpMat& Kgg, const Vec& rg, double tolerance,
                       int max_iterations, CgInfo* info) {
  Eigen::ConjugateGradient<SpMat, Eigen::Lower | Eigen::Upper,
                           Eigen::DiagonalPreconditioner<double>>
      cg;
  cg.setTolerance(tolerance);
  if (max_iterations > 0) cg.setMaxIterations(max_iterations);
  cg.compute(Kgg);
  if (cg.info() != Eigen::Success)
    throw std::runtime_error("fea_solve_mgcg: preconditioner setup failed on K_ff");
  const Vec xg = cg.solve(rg);
  if (info) {
    info->iterations = static_cast<int>(cg.iterations());
    info->residual = cg.error();
    info->converged = (cg.info() == Eigen::Success) && xg.allFinite();
    info->used_multigrid = false;
    info->mg_levels = 0;
  }
  if (cg.info() != Eigen::Success || !xg.allFinite())
    throw SolverNonConvergence(
        "fea_solve_mgcg: CG did not reach the requested tolerance within "
        "max_iterations",
        info ? info->iterations : static_cast<int>(cg.iterations()),
        info ? info->residual : cg.error());
  return xg;
}

// Solve the assembled, BC-reduced system with MG-preconditioned CG, falling back
// to Jacobi-CG when a multigrid hierarchy is not applicable or does not converge.
// Mirrors solve_reduced_cg's void-gate + scatter so the result matches
// fea_solve_cg exactly.
FeaSolution solve_reduced_mgcg(const ReducedSystem& s, const VoxelGrid& grid,
                               double tolerance, int max_iterations,
                               CgInfo* info) {
  const int nf = static_cast<int>(s.freedofs.size());

  CgInfo diag;
  diag.converged = true;  // no free DOFs -> trivially converged

  Vec u = s.up;
  if (nf > 0) {
    // --- M3.1 void-DOF safety gate (identical to the Jacobi-CG path) ---------
    std::vector<int> kept;
    try {
      kept = fea_detail::void_dof_survivors(s.Kff, s.rf, "fea_solve_mgcg");
    } catch (...) {
      diag.converged = false;
      diag.iterations = 0;
      diag.residual = 0.0;
      if (info) *info = diag;
      throw;
    }
    const int ng = static_cast<int>(kept.size());

    // Reduce onto the surviving (non-void) free DOFs -> SPD operator Kgg, rg.
    SpMat Kgg;
    Vec rg;
    if (ng != nf) {
      SpMat Q(ng, nf);
      std::vector<Trip> qtrips;
      qtrips.reserve(static_cast<std::size_t>(ng));
      for (int r = 0; r < ng; ++r) qtrips.emplace_back(r, kept[r], 1.0);
      Q.setFromTriplets(qtrips.begin(), qtrips.end());
      const SpMat KQt = s.Kff * Q.transpose();
      Kgg = Q * KQt;
      Kgg.makeCompressed();
      rg = Q * s.rf;
    } else {
      Kgg = s.Kff;
      rg = s.rf;
    }

    // Active-DOF map on the fine node grid: (node*3+comp) -> survivor id (== row
    // of Kgg). The survivor id r maps back to global DOF s.freedofs[kept[r]], from
    // which the node and component are recovered. The map lives on the parity-
    // padded INDEX-SPACE node grid (identical to the real grid whenever the
    // grid already coarsens — tasks multigrid-odd-axis-cliff /
    // multigrid-deep-block-pad); the virtual pad nodes stay -1, so the
    // hierarchy involves exactly the real active DOFs.
    const int nnx = grid.nx + 1, nny = grid.ny + 1, nnz = grid.nz + 1;
    int pex, pey, pez;
    mg_effective_extents(
        grid.nx, grid.ny, grid.nz, pex, pey, pez,
        mg_unpadded_stop_active(grid.nx, grid.ny, grid.nz, ng, [&](int r) {
          return s.freedofs[static_cast<std::size_t>(kept[static_cast<std::size_t>(r)])];
        }));
    const int pnnx = pex + 1, pnny = pey + 1, pnnz = pez + 1;
    std::vector<int> active(static_cast<std::size_t>(pnnx) * pnny * pnnz * 3, -1);
    for (int r = 0; r < ng; ++r) {
      const int gdof = s.freedofs[static_cast<std::size_t>(kept[r])];
      const int node = gdof / 3;
      const int comp = gdof % 3;
      const int a = node % nnx;
      const int b = (node / nnx) % nny;
      const int c = node / (nnx * nny);
      const std::size_t pnode =
          (static_cast<std::size_t>(c) * pnny + b) * pnnx + a;
      active[pnode * 3 + comp] = r;
    }

    const int cap = max_iterations > 0 ? max_iterations
                                       : std::max(1000, 2 * ng);

    // The assembled hierarchy IS the whole hierarchy (level 0 is A0 itself), so
    // the tuning's total depth request passes straight through. 0 — the shipped
    // value — is the cap-driven depth this call has always produced.
    std::vector<Level> levels =
        build_hierarchy(Kgg, pnnx, pnny, pnnz, std::move(active),
                        /*frugal=*/false, g_mg_tuning.max_levels,
                        /*global_level0=*/0);
    diag.hier_built = !levels.empty();  // fallback-mode diagnostics (handoff 128)

    bool solved = false;
    Vec xg;
    if (!levels.empty()) {
      // Cap MG-CG at a modest budget: if it hasn't converged by then, geometric
      // multigrid is not helping on this operator (adversarial contrast) and the
      // Jacobi-CG fallback below will be faster. Never exceed the caller's cap.
      const int mg_cap = std::min(cap, kMgIterBudget);
      int it = 0;
      double res = 0.0;
      const bool ok = mgpcg(levels, rg, tolerance, mg_cap, xg, it, res);
      diag.mg_cycles_attempted = it;
      if (ok) {
        diag.iterations = it;
        diag.residual = res;
        diag.converged = true;
        diag.used_multigrid = true;
        diag.mg_levels = static_cast<int>(levels.size());
        solved = true;
      }
      // MG did not converge / broke down -> fall through to the Jacobi-CG fallback.
    }

    if (!solved) {
      // Exact fallback: numerically identical to fea_solve_cg's inner solve.
      // Reports the Jacobi attempt in *info (used_multigrid=false); throws on
      // non-convergence just like fea_solve_cg.
      try {
        xg = jacobi_cg_fallback(Kgg, rg, tolerance, cap, &diag);
      } catch (...) {
        if (info) *info = diag;
        throw;
      }
    }

    for (int r = 0; r < ng; ++r) u[s.freedofs[static_cast<std::size_t>(kept[r])]] = xg[r];
  }

  if (info) *info = diag;

  FeaSolution sol;
  sol.u.assign(u.data(), u.data() + s.ndof);
  return sol;
}

// ===========================================================================
// Matrix-free geometric multigrid (handoff: matrix-free multigrid).
//
// The FINEST level is MATRIX-FREE: its matvecs, residuals and damped-Jacobi
// smoother use fea_detail's element-by-element apply (mf_apply_full via
// MatfreeReduced::apply_kgg) and matrix-free Jacobi diagonal — the assembled
// fine operator A0 (the sparse K that OOMs on the ~623k-voxel design box) is
// NEVER built. Only the (>=8x smaller) COARSE operators are assembled.
//
// STEP 0 coarse-operator strategy (see docs/handoffs/078): matrix-free GALERKIN
// via an element-local triple product. The level-1 operator A1 = P0^T A0 P0 is
// formed by projecting each solid element's reference block factor*Ke through
// the trilinear prolongation restricted to that element's <=24 local coarse
// DOFs, then scattering the small projected block. This reproduces the assembled
// Galerkin A1 DOF-for-DOF (to summation roundoff) WITHOUT ever assembling A0, so
// it keeps Galerkin's robustness under the SIMP soft-void modulus contrast
// (rho_min^p high contrast) — the documented reason Galerkin was chosen over
// rediscretisation — while removing the fine matrix. Levels 2.. are the ordinary
// assembled Galerkin products on the (small) A1 via the shared build_hierarchy.
// The V-cycle structure (equal pre/post damped-Jacobi, R = P0^T, exact coarse
// solve) is preserved, so the preconditioner stays SPD and CG-valid.
// ===========================================================================

using fea_detail::MatfreeReduced;
using fea_detail::MfCubElem;
using fea_detail::MfElem;
using fea_detail::MfLatticeArrays;

// Single-precision Eigen types for the mixed-precision V-cycle (handoff 092).
using SpMatF = Eigen::SparseMatrix<float>;
using VecF = Eigen::Matrix<float, Eigen::Dynamic, 1>;

// A matrix-free multigrid hierarchy: level 0 is the matrix-free fine operator
// `m`; levels 1.. are the assembled `coarse` Levels (coarse[0] == level 1).
struct MfHierarchy {
  const MatfreeReduced* m = nullptr;  // fine (level 0), matrix-free
  Vec fine_dinv;                      // 1/diag(A0) at the fine level
  SpMat P0;                           // prolongation level1 -> fine (ng x nc1)
  std::vector<Level> coarse;          // assembled levels 1..L (coarse[0]==lvl 1)
  // FP32 copies for the mixed-precision V-cycle (handoff 092): built only when
  // mixed precision is enabled at build time, empty otherwise. The coarse hierarchy
  // (coarse[]) stays FP64 — only the FINE apply / smoother / restrict / prolong go
  // single precision, so these mirror just the fine-level operators.
  SpMatF P0f;                         // FP32 prolongation for restrict/prolong
  VecF fine_dinv_f;                   // FP32 fine Jacobi inverse diagonal
  // Point-block smoother data for the FINE (matrix-free) level: EMPTY on the
  // shipped scalar path. Coarse levels carry their own on Level::pbd.
  BlockDiag fine_pbd;
  int levels() const { return 1 + static_cast<int>(coarse.size()); }
};

// Preallocated scratch for the matrix-free V-cycle + MG-CG, sized once per solve
// and reused across every iteration so the numerically-hot path performs NO
// per-iteration heap allocation (handoff 079's named lever). Every buffer is
// written in full before it is read, so reuse is bit-for-bit identical to the
// previous allocate-fresh-each-call code — the arithmetic and its ordering are
// unchanged; only the storage is recycled.
struct MfScratch {
  // Fine-level (ng) work vectors.
  Vec Ax;    // A0 * x from the fine matvec / jacobi sweep
  Vec vr;    // V-cycle fine residual b - A0 x
  Vec prol;  // P0 * ec (prolongated coarse correction)
  Vec Ap;    // MG-CG: A0 * p
  Vec zc;    // MG-CG: preconditioned residual (z / znew are ping-ponged here)
  // Coarse (nc) work vectors.
  Vec bc;    // restricted residual P0^T r (also the FP64 coarse RHS in mixed mode)
  Vec ec;    // coarse-grid correction (FP64, from the exact coarse solve)

  // Mixed-precision (FP32) V-cycle scratch (handoff 092), sized only when the
  // mixed path is used so the FP64 path allocates none of it. `bc`/`ec` above are
  // reused as the FP64 hand-off buffers for the (still FP64) coarse direct solve.
  VecF bf, xf, Axf, vrf, prolf;  // fine-level (ng) FP32 work
  VecF bcf, ecf;                 // coarse-level (nc) FP32 work

  void resize(int ng, int nc) {
    Ax.resize(ng); vr.resize(ng); prol.resize(ng); Ap.resize(ng); zc.resize(ng);
    bc.resize(nc); ec.resize(nc);
  }
  void resize_f(int ng, int nc) {
    bf.resize(ng); xf.resize(ng); Axf.resize(ng); vrf.resize(ng); prolf.resize(ng);
    bcf.resize(nc); ecf.resize(nc);
  }
};

// Fine-level matrix-free matvec y = A0 x (restricted to the kept DOFs), writing
// into the caller-owned `y` (reused across calls). Eigen vectors store their
// entries contiguously, so apply_kgg_raw drives the element apply straight off
// x.data()/y.data() with NO marshalling copies (the previous version allocated
// two std::vectors and an output Vec every call).
inline void mf_fine_matvec(const MfHierarchy& H, const Vec& x, Vec& y) {
  const int n = H.m->ng;
  y.resize(n);
  H.m->apply_kgg_raw(x.data(), y.data());
}

// One fine-level smoother sweep, matrix-free: x <- x + omega*Dinv.*(b-A0 x) on
// the shipped scalar path, or the per-node 3x3 block inverse applied to the same
// residual when the point-block smoother is selected. Either way exactly ONE
// operator apply per sweep — the sweep count is the honest cost currency.
inline void mf_jacobi_sweep(const MfHierarchy& H, MfScratch& S, const Vec& b,
                            Vec& x, const MgOpts& o) {
  mf_fine_matvec(H, x, S.Ax);
  if (o.point_block && !H.fine_pbd.empty()) {
    S.vr = b - S.Ax;
    block_apply(H.fine_pbd, o.omega, S.vr, x);
    return;
  }
  x += o.omega * (H.fine_dinv.array() * (b - S.Ax).array()).matrix();
}

// Symmetric V-cycle with a matrix-free finest level, writing the result into the
// caller-owned `x` (reused). The coarse-grid correction reuses the assembled
// v_cycle on the coarse hierarchy, so this is a valid SPD preconditioner (equal
// pre/post smoothing, R = P0^T, exact coarse solve).
void mf_v_cycle(const MfHierarchy& H, MfScratch& S, const Vec& b, Vec& x,
                const MgOpts& o) {
  x.setZero(H.m->ng);
  for (int s = 0; s < o.pre; ++s) mf_jacobi_sweep(H, S, b, x, o);

  // gamma == 1 is the shipped V-cycle: one coarse-grid correction. gamma == 2
  // repeats it against a freshly recomputed fine residual (the W-cycle).
  for (int g = 0; g < o.gamma; ++g) {
    mf_fine_matvec(H, x, S.Ax);
    S.vr = b - S.Ax;                            // fine residual
    S.bc.noalias() = H.P0.transpose() * S.vr;   // restrict (R = P0^T)
    S.ec = v_cycle(H.coarse, 0, S.bc, o, 1);    // coarse-grid correction
    S.prol.noalias() = H.P0 * S.ec;             // prolongate + correct
    x += S.prol;
  }

  for (int s = 0; s < o.post; ++s) mf_jacobi_sweep(H, S, b, x, o);
}

// MIXED-PRECISION V-cycle (handoff 092). Same symmetric structure as mf_v_cycle
// (equal pre/post damped-Jacobi, R = P0^T, exact coarse solve) but the FINE level
// — apply, Jacobi smoother, restriction and prolongation — runs in FP32; only the
// coarse direct solve stays FP64. "The format is converted when entering and
// exiting the V-cycle" (Kronbichler et al. 2019): the double residual `b` is cast
// to float on entry and the float correction is cast back to double on exit, so to
// the OUTER FP64 CG this is just a (slightly sloppier) SPD preconditioner. Larger
// FP32 round-off costs CG iterations, never accuracy — the outer loop's true FP64
// residual test is the correctness guarantee. Determinism is preserved: the FP32
// apply keeps the 8-colour fixed-order accumulation (bit-identical across threads),
// and the SpMV/coarse solve are single-threaded, so the whole cycle is
// reproducible run-to-run.
//
// The component tuning reaches this path too (same sweep counts, same gamma,
// same weight) so the two V-cycles cannot drift apart, but its FINE smoother
// stays SCALAR: no FP32 point-block data is built, and mixed precision is
// production-blocked anyway (handoff 132 D) and unused by the component sweep.
void mf_v_cycle_mixed(const MfHierarchy& H, MfScratch& S, const Vec& b, Vec& x,
                      const MgOpts& o) {
  const int ng = H.m->ng;
  const float omega = static_cast<float>(o.omega);
  S.bf = b.cast<float>();                       // convert on entry
  S.xf.setZero(ng);
  for (int s = 0; s < o.pre; ++s) {
    H.m->apply_kgg_raw_f32(S.xf.data(), S.Axf.data());
    S.xf += omega * (H.fine_dinv_f.array() * (S.bf - S.Axf).array()).matrix();
  }
  for (int g = 0; g < o.gamma; ++g) {
    H.m->apply_kgg_raw_f32(S.xf.data(), S.Axf.data());
    S.vrf = S.bf - S.Axf;                          // fine residual (FP32)
    S.bcf.noalias() = H.P0f.transpose() * S.vrf;   // restrict (R = P0^T), FP32 SpMV
    S.bc = S.bcf.cast<double>();                   // hand off to the FP64 coarse solve
    S.ec = v_cycle(H.coarse, 0, S.bc, o, 1);       // coarse-grid correction (FP64)
    S.ecf = S.ec.cast<float>();
    S.prolf.noalias() = H.P0f * S.ecf;             // prolongate (FP32 SpMV) + correct
    S.xf += S.prolf;
  }
  for (int s = 0; s < o.post; ++s) {
    H.m->apply_kgg_raw_f32(S.xf.data(), S.Axf.data());
    S.xf += omega * (H.fine_dinv_f.array() * (S.bf - S.Axf).array()).matrix();
  }
  x = S.xf.cast<double>();                        // convert on exit
}

// MG-preconditioned CG with the matrix-free finest level. Identical algorithm
// and stopping criterion to mgpcg (||b - A x|| / ||b|| <= tol), only the fine
// matvec and preconditioner are matrix-free. Returns false (with diagnostics) on
// non-convergence within max_it or a non-finite iterate -> caller falls back.
// All work vectors come from `S` (sized once), so the loop heap-allocates nothing.
bool mf_mgpcg(const MfHierarchy& H, MfScratch& S, const Vec& b, double tol,
              int max_it, Vec& x, int& iters, double& resid, bool mixed,
              fea_detail::RecycleReport* rec = nullptr,
              const Vec* x0 = nullptr) {
  // The ONLY thing `mixed` changes is which V-cycle preconditions the residual:
  // FP32 (mf_v_cycle_mixed) vs FP64 (mf_v_cycle). Every quantity that defines
  // convergence — r, x, p, rz, alpha, beta, the residual norm and the stopping
  // test below — is FP64 regardless. A sloppier preconditioner costs iterations,
  // not accuracy; this outer FP64 loop is the correctness guarantee.
  const MgOpts opts = mg_opts_now();
  auto precondition = [&](const Vec& rr, Vec& zz) {
    if (mixed) mf_v_cycle_mixed(H, S, rr, zz, opts);
    else mf_v_cycle(H, S, rr, zz, opts);
  };
  const int n = H.m->ng;
  const double bnorm = b.norm();
  iters = 0;
  resid = 0.0;
  if (!(bnorm > 0.0)) {          // zero RHS -> zero solution, trivially converged
    x = Vec::Zero(n);
    return true;
  }
  const double threshold = tol * bnorm;

  // Krylov recycling (handoff 133): the SPD additive coarse correction wrapping
  // the V-cycle. Recycling is OUTSIDE the preconditioner, so the FP64 and FP32
  // V-cycles are both untouched and both keep whatever they do today. Inert (and
  // allocation-free) when recycling is off.
  fea_detail::RecycleSession recycle(
      n, H.m->invdiag.data(),
      [&H](const double* xin, double* yout) { H.m->apply_kgg_raw(xin, yout); },
      fea_detail::rc_wrap_multigrid());
  if (rec != nullptr) {
    rec->dim = recycle.dim();
    rec->setup_matvecs += recycle.setup_matvecs();
  }

  // WARM START (task 2026-08-10-plsm-production, S3): x0 == nullptr is the
  // pre-feature path, byte-for-byte — `x = 0` and `r = b - A*0 = b`, with no
  // matvec spent. With a guess, one extra fine matvec buys the true initial
  // residual; everything after this is the identical recurrence, and the
  // stopping test below is still ||r|| <= tol*||b|| — relative to the RHS, not
  // to the initial residual — so a warm solve satisfies the same criterion a
  // cold one does.
  Vec r(n);
  if (x0 != nullptr && x0->size() == n && x0->allFinite()) {
    x = *x0;
    mf_fine_matvec(H, x, S.Ap);
    r = b - S.Ap;
  } else {
    x = Vec::Zero(n);
    r = b;                                // r = b - A*0
  }
  Vec z(n);
  precondition(r, z);                      // z = M^{-1} r
  recycle.augment(r.data(), z.data());     // + U E^-1 U^T r
  Vec p = z;
  double rz = r.dot(z);
  if (!std::isfinite(rz)) return false;

  const auto deadline = mg_attempt_deadline(kMgAttemptWallGuardSec);
  for (int k = 1; k <= max_it; ++k) {
    // Wall-clock safety net (handoff 128): bail to the exact Jacobi-CG fallback
    // if this attempt has run past the guard (see mgpcg for the rationale).
    if (std::chrono::steady_clock::now() > deadline) return false;
    // THE SOLVE DEADLINE (task 2026-08-03-preflight-feasibility-and-divergence,
    // guard 3). Disarmed by default. Bail the SAME way the guard above does —
    // to the exact Jacobi-CG fallback, whose own deadline poll then throws
    // SolverDeadlineExceeded. Bailing rather than throwing here keeps this
    // function's "false means fall back" contract intact.
    {
      const double sd = fea_detail::mf_solve_deadline();
      if (sd > 0.0 && (k % fea_detail::kSolveDeadlinePollIters) == 0 &&
          fea_detail::mf_steady_ms() >= sd)
        return false;
    }
    mf_fine_matvec(H, p, S.Ap);           // A p is FP64 (defines the residual)
    // Sample this direction with its already-computed image (no extra matvec).
    recycle.observe(k - 1, p.data(), S.Ap.data());
    const double pAp = p.dot(S.Ap);
    if (!(pAp > 0.0) || !std::isfinite(pAp)) return false;  // breakdown
    const double alpha = rz / pAp;
    x += alpha * p;
    r -= alpha * S.Ap;
    iters = k;
    const double rn = r.norm();
    resid = rn / bnorm;
    if (rn <= threshold) {
      const bool ok = x.allFinite();
      // Rebuild the carried basis only from a solve that reached tolerance.
      if (ok) recycle.commit();
      return ok;
    }
    precondition(r, S.zc);               // znew = M^{-1} r (reused buffer)
    recycle.augment(r.data(), S.zc.data());  // + U E^-1 U^T r
    const double rznew = r.dot(S.zc);
    if (!std::isfinite(rznew)) return false;
    const double beta = rznew / rz;
    p = S.zc + beta * p;
    rz = rznew;
  }
  return false;  // hit the iteration cap without converging
}

// Build the matrix-free multigrid hierarchy from the matrix-free fine operator
// `m` whose kept DOFs sit on the node grid (nnx,nny,nnz). Returns false (leaving
// `out` unusable) if a usable hierarchy cannot be built (fine not 2x-divisible,
// or the coarse operator not factorable) — the caller then falls back to the
// matrix-free Jacobi-CG. The FINE operator A0 is never assembled: A1 is formed
// by an element-local Galerkin triple product, all coarser levels by build_hierarchy.
// Every level's DOF count, finest first, recorded by BOTH hierarchy builders so
// a V-cycle can be priced in DOF-weighted operator applies whichever shape ran
// (task: algebraic-level1-coarsening, bar AH5). Pure observation.
void record_hierarchy_dims(const MatfreeReduced& m,
                           const std::vector<Level>& coarse) {
  g_mg_last_level_dims.clear();
  g_mg_last_level_dims.push_back(m.ng);  // the matrix-free fine level
  for (const Level& L : coarse) g_mg_last_level_dims.push_back(L.n);
}

// Defined below build_mf_hierarchy; declared here because both hierarchy shapes
// use them. See their definitions for what they do and why they are shared.
SpMat galerkin_a1_from_prolong(
    const MatfreeReduced& m, const std::vector<int>& active,
    const std::vector<std::vector<std::pair<int, double>>>& prolong, int nc,
    bool allow_color_cache);
void mf_build_point_block_fine(const MatfreeReduced& m,
                               const std::vector<int>& active,
                               const fea_detail::MgTuning& tune,
                               MfHierarchy& out);
bool build_mf_hierarchy_algebraic(const MatfreeReduced& m, int nnx, int nny,
                                  int nnz, MfHierarchy& out);

bool build_mf_hierarchy(const MatfreeReduced& m, int nnx, int nny, int nnz,
                        MfHierarchy& out) {
  // ALGEBRAIC LEVEL-1 COARSENING (task: algebraic-level1-coarsening), DISARMED
  // by default. When armed, level 1 is an AGGREGATION of the fine operator
  // rather than a halving of the fine grid — the space PR 283 measured at
  // 56.3293 % capture against the geometric 1.5954 % on the maintainer's dilute
  // field. A refusal (aggregation declined, coarsening control rejected a level,
  // the byte cap would be exceeded) falls straight through to the geometric
  // builder below, which is untouched. With the flag off — the library default,
  // and what every reference run sees — this `if` is the only added instruction
  // and the rest of this function is byte-for-byte the shipped path.
  if (g_mg_alg_level1 && build_mf_hierarchy_algebraic(m, nnx, nny, nnz, out))
    return true;

  const fea_detail::MgTuning& tune = g_mg_tuning;
  const int fex = nnx - 1, fey = nny - 1, fez = nnz - 1;  // fine element dims
  // Parity pad (task: multigrid-odd-axis-cliff / multigrid-deep-block-pad): a
  // grid the coarsening rule rejects — odd fine axis or all-even deep block —
  // used to fail this gate outright; the whole run then rode Jacobi-CG. The
  // hierarchy is
  // instead built on the padded INDEX SPACE extents; the virtual high-side
  // nodes are inactive everywhere below, so P0's rows, A1 and every coarse
  // operator involve exactly the real active DOFs. Grids that already coarsen
  // leave (pex,pey,pez) == (fex,fey,fez) and this function byte-identical.
  int pex, pey, pez;
  mg_effective_extents(fex, fey, fez, pex, pey, pez,
                       mg_unpadded_stop_active(fex, fey, fez, m.ng, [&](int r) {
                         return m.kept_global[static_cast<std::size_t>(r)];
                       }));
  if ((pex & 1) || (pey & 1) || (pez & 1)) return false;
  const int cex = pex / 2, cey = pey / 2, cez = pez / 2;
  if (cex < kMinCoarseElems || cey < kMinCoarseElems || cez < kMinCoarseElems)
    return false;
  const int cnx = cex + 1, cny = cey + 1, cnz = cez + 1;

  // Fine active map: global DOF (node*3+comp) -> kept id (0..ng-1), or -1.
  std::vector<int> active(static_cast<std::size_t>(m.ndof), -1);
  for (int kg = 0; kg < m.ng; ++kg)
    active[static_cast<std::size_t>(m.kept_global[static_cast<std::size_t>(kg)])] =
        kg;

  auto fnode_index = [&](int a, int b, int c) { return (c * nny + b) * nnx + a; };

  // Coarse (level-1) active DOFs: active iff the coincident fine node-DOF is.
  // A coarse node whose coincident fine node lies in the virtual pad (beyond
  // the real node grid) has no fine DOF and stays inactive; on an unpadded
  // grid the bounds test never fires and the enumeration is byte-identical.
  std::vector<int> cactive(static_cast<std::size_t>(cnx) * cny * cnz * 3, -1);
  int nc = 0;
  for (int c = 0; c < cnz; ++c)
    for (int b = 0; b < cny; ++b)
      for (int a = 0; a < cnx; ++a) {
        if (2 * a >= nnx || 2 * b >= nny || 2 * c >= nnz) continue;  // pad node
        const int fnode = fnode_index(2 * a, 2 * b, 2 * c);
        const int cnode = (c * cny + b) * cnx + a;
        for (int comp = 0; comp < 3; ++comp)
          if (active[static_cast<std::size_t>(fnode) * 3 + comp] >= 0)
            cactive[static_cast<std::size_t>(cnode) * 3 + comp] = nc++;
      }
  if (nc == 0) return false;

  // Prolongation P0 (fine kept rows x coarse cols) + per-kept-DOF coarse weight
  // list `prolong` (the rows of P0, used by the element-local Galerkin below).
  // Identical trilinear stencil to build_hierarchy's fine-level P.
  std::vector<Trip> ptrips;
  ptrips.reserve(static_cast<std::size_t>(m.ng) * 8);
  std::vector<std::vector<std::pair<int, double>>> prolong(
      static_cast<std::size_t>(m.ng));
  for (int fc = 0; fc < nnz; ++fc)
    for (int fb = 0; fb < nny; ++fb)
      for (int fa = 0; fa < nnx; ++fa) {
        const int fnode = fnode_index(fa, fb, fc);
        int hasActive = 0;
        for (int comp = 0; comp < 3; ++comp)
          if (active[static_cast<std::size_t>(fnode) * 3 + comp] >= 0)
            hasActive = 1;
        if (!hasActive) continue;
        int ia[2], ib[2], ic[2];
        double wa[2], wb[2], wc[2];
        const int na = axis_weights(fa, ia, wa);
        const int nb = axis_weights(fb, ib, wb);
        const int ncz = axis_weights(fc, ic, wc);
        for (int comp = 0; comp < 3; ++comp) {
          const int row = active[static_cast<std::size_t>(fnode) * 3 + comp];
          if (row < 0) continue;
          for (int x = 0; x < na; ++x)
            for (int y = 0; y < nb; ++y)
              for (int z = 0; z < ncz; ++z) {
                const int cnode = (ic[z] * cny + ib[y]) * cnx + ia[x];
                const int col = cactive[static_cast<std::size_t>(cnode) * 3 + comp];
                if (col < 0) continue;  // inactive coarse node -> weight 0
                const double w = wa[x] * wb[y] * wc[z];
                ptrips.emplace_back(row, col, w);
                prolong[static_cast<std::size_t>(row)].emplace_back(col, w);
              }
        }
      }
  SpMat P0(m.ng, nc);
  P0.setFromTriplets(ptrips.begin(), ptrips.end());
  P0.makeCompressed();
  std::vector<Trip>().swap(ptrips);  // P0 is built; free the triplet scratch

  SpMat A1 = galerkin_a1_from_prolong(m, active, prolong, nc,
                                      /*allow_color_cache=*/true);
  std::vector<std::vector<std::pair<int, double>>>().swap(prolong);  // done with W

  // Coarser levels 2.. via the shared assembled Galerkin builder, seeded at A1.
  // Frugal (column-blocked) coarse products keep the design-box peak in budget.
  // A TOTAL depth cap of N leaves N-1 levels for this sub-hierarchy (level 0 is
  // the matrix-free fine one); 0 keeps the shipped, cap-driven depth.
  const int sub_cap = tune.max_levels > 0 ? tune.max_levels - 1 : 0;
  std::vector<Level> coarse;
  // The coarse-space seam (task: hybrid-amg-coarsening-probe). A harness may
  // supply the prolongators for levels 2.. from A1 by ALGEBRAIC aggregation
  // instead of by halving the grid. Nothing below the `if` runs — and nothing is
  // even copied out of the solver — unless a hook is installed, which no
  // production path does; a hook that declines or returns a hierarchy this file
  // rejects falls straight through to the geometric builder.
  if (g_mg_coarse_hook) {
    fea_detail::MgCoarseSeam seam;
    seam.n1 = static_cast<int>(A1.cols());
    seam.a1_outer = A1.outerIndexPtr();
    seam.a1_inner = A1.innerIndexPtr();
    seam.a1_val = A1.valuePtr();
    seam.p0.rows = static_cast<int>(P0.rows());
    seam.p0.cols = static_cast<int>(P0.cols());
    for (int j = 0; j < P0.outerSize(); ++j)
      for (SpMat::InnerIterator it(P0, j); it; ++it) {
        seam.p0.row.push_back(static_cast<int>(it.row()));
        seam.p0.col.push_back(static_cast<int>(it.col()));
        seam.p0.val.push_back(it.value());
      }
    seam.cnx = cnx;
    seam.cny = cny;
    seam.cnz = cnz;
    seam.cactive = &cactive;
    coarse = build_hierarchy_from_prolongators(A1, cnx, cny, cnz, cactive,
                                               g_mg_coarse_hook(seam));
  }
  if (coarse.empty())
    coarse = build_hierarchy(A1, cnx, cny, cnz, cactive,
                             /*frugal=*/true, sub_cap,
                             /*global_level0=*/1);
  if (coarse.empty()) {
    // A1 alone could not seed a >=2-level sub-hierarchy. Use A1 as the sole
    // (directly factored) coarse level if small enough, giving a 2-level
    // matrix-free cycle (fine matrix-free + A1 direct); else no usable hierarchy.
    if (static_cast<int>(A1.cols()) > tune.coarse_dof_cap) return false;
    Level only;
    only.nx = cnx;
    only.ny = cny;
    only.nz = cnz;
    only.n = static_cast<int>(A1.cols());
    only.A = A1;
    only.Dinv = inverse_diagonal(A1);
    only.active = cactive;
    only.coarsest = true;
    only.chol = std::make_shared<Eigen::SimplicialLDLT<SpMat>>();
    only.chol->compute(only.A);
    if (only.chol->info() != Eigen::Success) return false;
    coarse.push_back(std::move(only));
  }

  out.m = &m;
  out.fine_dinv = Eigen::Map<const Vec>(m.invdiag.data(),
                                        static_cast<Eigen::Index>(m.invdiag.size()));
  out.P0 = std::move(P0);
  out.coarse = std::move(coarse);
  record_hierarchy_dims(m, out.coarse);
  mf_build_point_block_fine(m, active, tune, out);
  return true;
}

// The ELEMENT-LOCAL Galerkin product A1 = P0^T A0 P0, formed WITHOUT assembling
// A0 — shared by the GEOMETRIC hierarchy (whose P0 is the trilinear halving
// stencil) and the ALGEBRAIC one (task: algebraic-level1-coarsening, whose P0 is
// an aggregation prolongator). It reads P0 only as `prolong`, the per-kept-fine-
// DOF list of (coarse column, weight) pairs, so it never cared HOW those rows
// were produced; factoring it out is what lets the algebraic level-1 space reuse
// the exact arithmetic the geometric path has always used.
//
// Per element: gather its distinct local coarse DOFs, build the 24 x mloc
// local prolongation W (rows of P0 for the element's kept fine DOFs), and
// scatter W^T (factor*Ke) W. Summing these over all elements yields exactly
// P0^T A0 P0 (A0 = sum_e factor_e S_e^T Ke S_e).
//
// `allow_color_cache` MUST be false for a non-geometric P0. The colour cache
// below is sound only because the trilinear stencil is parity-based and
// translation-invariant, so every element of a colour has the same W; an
// aggregation prolongator has no such property and a cached block would be
// simply wrong. See the cache's own note.
//
// LOCAL BLOCK WIDTH. The geometric stencil gives every element exactly 2x2x2
// coarse nodes = 24 coarse DOFs, so this pass historically used fixed 24x24
// stack arrays. An aggregation can put an element's 8 nodes in up to 8 different
// aggregates of up to 6 modes each — 48 coarse DOFs — so the scratch is sized
// from the measured maximum `mloc` instead. The arithmetic, the loop order and
// the summation order are UNCHANGED; only the row stride differs, so A1 is
// bit-identical to the fixed-array version on the geometric path.
SpMat galerkin_a1_from_prolong(
    const MatfreeReduced& m, const std::vector<int>& active,
    const std::vector<std::vector<std::pair<int, double>>>& prolong, int nc,
    bool allow_color_cache) {
  // ASSEMBLY — TWO-PASS CSR (handoff 085 follow-up). Naively streaming each
  // element's <=kDof^2 = 576 (i,j,v) triplets into a single array is ~576*elements
  // ~= 359M triplets ~= 5.5 GB at the design box (the measured OOM 079 avoided). 079
  // instead accumulated in place via A1.coeffRef, which is memory-bounded but pays an
  // insert cost: the FIRST touch of each (i,j) inserts into a sorted sparse column
  // and shifts its tail, and the column is pre-reserved at the full 81-wide stencil.
  // The two-pass CSR keeps 079's bounded memory, drops that over-reservation, and
  // removes the insert-shifting:
  //   Pass 0  cache each element's distinct coarse DOFs (cds) once (CSR ecds).
  //   Pass 1  SYMBOLIC: build the exact CSC structure (colptr + row-sorted rowidx)
  //           via an inverse map (coarse DOF -> elements) and a column mark, so each
  //           (i,j) is discovered once with O(1) dedup — no triplet array, no insert.
  //           A1 is then created at EXACTLY this structure (values 0), and the scratch
  //           colptr/rowidx freed, so no second nnz-sized array is copied into Eigen.
  //   Pass 2  NUMERIC: recompute each element's block (same W/KW/W^T KW as before) and
  //           add v straight into A1's OWN value array by BINARY SEARCH over A1's
  //           sorted inner indices — a pure search, never an insertion.
  // Pass 2 loops elements in the same order and adds the same nonzero v's to each
  // (i,j) in the same order coeffRef did, so A1 is BIT-FOR-BIT identical to 079's —
  // same values, and the same pattern (every structural (i,j) receives a nonzero
  // contribution; verified by the unchanged nnz). The 078 iteration-count parity
  // (18 == 18) is thus preserved by construction, not merely to roundoff. NOTE: the
  // build is dominated by the element block arithmetic below (~73% of build time,
  // measured), which this assembly change does not touch; coeffRef was ~2 s of it.
  constexpr int kDof = Hex8Stiffness::kDof;  // 24
  // CUBIC LATTICE (multiscale production wiring): the Galerkin product runs
  // over BOTH element lists — the iso elements first (indices [0, niso), the
  // path below unchanged so a cubic-free build is bit-identical), then the
  // cubic elements (indices [niso, nelems)), whose projected block is
  // W^T (a*K_A + b*K_B + c*K_C) W — the coarse-block decomposition PR 252
  // proved identical to the assembled Galerkin product.
  const int niso = static_cast<int>(m.elems.size());
  const int ncub = static_cast<int>(m.cub_elems.size());
  const int nelems = niso + ncub;
  const auto elem_edof = [&](int e) -> const int* {
    return e < niso ? m.elems[static_cast<std::size_t>(e)].edof
                    : m.cub_elems[static_cast<std::size_t>(e - niso)].edof;
  };

  // Pass 0: per-element distinct coarse DOFs (CSR ecds_off/ecds), same discovery
  // order the old per-element loop used, so the projected blocks are identical.
  std::vector<int> ecds_off;
  ecds_off.reserve(static_cast<std::size_t>(nelems) + 1);
  ecds_off.push_back(0);
  std::vector<int> ecds;
  ecds.reserve(static_cast<std::size_t>(nelems) * 8);
  {
    std::vector<int> cds;
    cds.reserve(kDof);
    for (int e = 0; e < nelems; ++e) {
      const int* edof = elem_edof(e);
      cds.clear();
      for (int r = 0; r < kDof; ++r) {
        const int kgr = active[static_cast<std::size_t>(edof[r])];
        if (kgr < 0) continue;
        for (const auto& pr : prolong[static_cast<std::size_t>(kgr)]) {
          bool found = false;
          for (int t : cds)
            if (t == pr.first) { found = true; break; }
          if (!found) cds.push_back(pr.first);
        }
      }
      for (int c : cds) ecds.push_back(c);
      ecds_off.push_back(static_cast<int>(ecds.size()));
    }
  }

  // Pass 1a: inverse map coarse DOF -> elements touching it (CSR inv_off/inv), the
  // column view the symbolic dedup needs.
  std::vector<int> inv_off(static_cast<std::size_t>(nc) + 1, 0);
  for (int e = 0; e < nelems; ++e)
    for (int k = ecds_off[static_cast<std::size_t>(e)];
         k < ecds_off[static_cast<std::size_t>(e) + 1]; ++k)
      ++inv_off[static_cast<std::size_t>(ecds[static_cast<std::size_t>(k)]) + 1];
  for (int j = 0; j < nc; ++j) inv_off[static_cast<std::size_t>(j) + 1] += inv_off[static_cast<std::size_t>(j)];
  std::vector<int> inv(ecds.size());
  {
    std::vector<int> cur(inv_off.begin(), inv_off.end());
    for (int e = 0; e < nelems; ++e)
      for (int k = ecds_off[static_cast<std::size_t>(e)];
           k < ecds_off[static_cast<std::size_t>(e) + 1]; ++k)
        inv[static_cast<std::size_t>(cur[static_cast<std::size_t>(ecds[static_cast<std::size_t>(k)])]++)] = e;
  }

  // Pass 1b: symbolic structure. A column mark (monotone j needs no per-column
  // reset within a sweep) discovers each distinct row once. First sweep counts
  // nnz/col -> colptr; second fills rowidx, then sorts each column's rows.
  std::vector<int> colptr(static_cast<std::size_t>(nc) + 1, 0);
  std::vector<int> mark(static_cast<std::size_t>(nc), -1);
  for (int j = 0; j < nc; ++j) {
    int cnt = 0;
    for (int p = inv_off[static_cast<std::size_t>(j)]; p < inv_off[static_cast<std::size_t>(j) + 1]; ++p) {
      const int e = inv[static_cast<std::size_t>(p)];
      for (int k = ecds_off[static_cast<std::size_t>(e)];
           k < ecds_off[static_cast<std::size_t>(e) + 1]; ++k) {
        const int i = ecds[static_cast<std::size_t>(k)];
        if (mark[static_cast<std::size_t>(i)] != j) { mark[static_cast<std::size_t>(i)] = j; ++cnt; }
      }
    }
    colptr[static_cast<std::size_t>(j) + 1] = cnt;
  }
  for (int j = 0; j < nc; ++j) colptr[static_cast<std::size_t>(j) + 1] += colptr[static_cast<std::size_t>(j)];
  const int a1nnz = colptr[static_cast<std::size_t>(nc)];
  std::vector<int> rowidx(static_cast<std::size_t>(a1nnz));
  std::fill(mark.begin(), mark.end(), -1);
  for (int j = 0; j < nc; ++j) {
    int w = colptr[static_cast<std::size_t>(j)];
    for (int p = inv_off[static_cast<std::size_t>(j)]; p < inv_off[static_cast<std::size_t>(j) + 1]; ++p) {
      const int e = inv[static_cast<std::size_t>(p)];
      for (int k = ecds_off[static_cast<std::size_t>(e)];
           k < ecds_off[static_cast<std::size_t>(e) + 1]; ++k) {
        const int i = ecds[static_cast<std::size_t>(k)];
        if (mark[static_cast<std::size_t>(i)] != j) {
          mark[static_cast<std::size_t>(i)] = j;
          rowidx[static_cast<std::size_t>(w++)] = i;
        }
      }
    }
    std::sort(rowidx.begin() + colptr[static_cast<std::size_t>(j)],
              rowidx.begin() + w);
  }
  std::vector<int>().swap(inv);       // symbolic done; free the column view
  std::vector<int>().swap(inv_off);
  std::vector<int>().swap(mark);

  // Build A1's STRUCTURE from the symbolic CSC (row-sorted, all values 0), then
  // free the scratch colptr/rowidx and accumulate straight into A1's OWN value
  // storage in Pass 2 — no second nnz-sized values array, so peak stays near the
  // final operator (unlike a separate CSC that is then copied into Eigen). Insertion
  // is in increasing (col, row) order into an exact per-column reservation, so it is
  // O(1) amortised (no shifting — the very cost the coeffRef path paid).
  SpMat A1(nc, nc);
  {
    Eigen::VectorXi cnt(nc);
    for (int j = 0; j < nc; ++j)
      cnt[j] = colptr[static_cast<std::size_t>(j) + 1] - colptr[static_cast<std::size_t>(j)];
    A1.reserve(cnt);
    for (int j = 0; j < nc; ++j)
      for (int k = colptr[static_cast<std::size_t>(j)];
           k < colptr[static_cast<std::size_t>(j) + 1]; ++k)
        A1.insert(rowidx[static_cast<std::size_t>(k)], j) = 0.0;
  }
  A1.makeCompressed();
  std::vector<int>().swap(rowidx);   // structure now lives in A1; free the scratch
  std::vector<int>().swap(colptr);

  // Pass 2: numeric. Recompute each element block (W/KW/W^T KW, unchanged) and add v
  // into A1's value array by binary search over A1's (sorted) inner indices — a pure
  // search, never an insertion. The element loop order and the per-(i,j) add order
  // match the old coeffRef path exactly, so A1 is BIT-IDENTICAL to 079's. Every
  // structural (i,j) receives a nonzero contribution (verified: the resulting nnz
  // equals the coeffRef path's), so no explicit zeros are introduced.
  //
  // GALERKIN BLOCK CACHE (handoff 090, opt-in via fea_set_matfree_galerkin_block
  // _cache, default OFF). The block S = W^T Ke W formed here is purely GEOMETRIC:
  // W comes from the trilinear prolongation stencil and Ke is the single reference
  // element stiffness — the element's modulus enters only below, as `el.factor *
  // S`. Since axis_weights is parity-based and translation-invariant, every
  // element whose 24 fine DOFs are all free AND whose 8 coarse nodes are all
  // active (mloc == kDof; see below) has the SAME W — and hence the same S — as
  // any other element of the same (i,j,k) parity, i.e. of the same COLOUR (the key
  // m.elems is already sorted by). Such elements are the interior majority, and on
  // the design box ~94% of them are the soft void the optimizer may grow into: the
  // build was recomputing a handful of identical blocks ~638,000 times. Measured
  // (090): this pass 6.32 s -> 2.25 s, the build 7.81 s -> 3.73 s, on the real
  // 96x80x96 case; what is left of the pass is the scatter, not the arithmetic.
  //
  // mloc == kDof is exactly the genericity test. An element's 8 nodes span 2 coarse
  // indices per axis whatever its parity (an even fine index maps to 1 coarse node,
  // an odd one to 2, and the union over {i, i+1} is 2 either way), so its coarse
  // support is always 2x2x2 nodes x 3 components = 24 coarse DOFs. mloc is the
  // count of DISTINCT coarse DOFs actually discovered, so mloc < kDof iff some
  // coarse DOF was inactive (dropped by `col < 0` in the P0 build); mloc == kDof
  // therefore certifies that no stencil entry was dropped. Combined with every
  // kg[r] >= 0 (no fine row zeroed by a fixed/void DOF), W is fully determined by
  // the colour. Elements failing either test — the BC-fixed and void-gated ones at
  // the boundary — take the unchanged full per-element path.
  //
  // BIT-IDENTICAL: the cached S is the same arithmetic on the same inputs, each
  // element still scales by its OWN el.factor, and the element loop order and the
  // per-(i,j) add order are untouched — so A1, the V-cycle and the iteration count
  // are unchanged. This saves compute; it does not approximate. Nothing is skipped
  // or frozen, so growth into the void is entirely unaffected.
  //
  // The cache is GEOMETRY-ONLY and `allow_color_cache` is how that is enforced:
  // an aggregation prolongator's W depends on which aggregates the element's
  // nodes landed in, which is emphatically NOT a function of the element's
  // parity, so on the algebraic path the caller passes false and every element
  // takes the full per-element path.
  {
    const int* Aouter = A1.outerIndexPtr();
    const int* Ainner = A1.innerIndexPtr();
    double* Aval = A1.valuePtr();
    // Coarse-local width. The geometric stencil always gives exactly kDof; an
    // aggregation can give more (up to 8 aggregates x 6 modes), so the scratch is
    // sized from the measured maximum rather than assumed. Row stride is `mcap`;
    // the arithmetic below is otherwise the historical fixed-array code verbatim.
    int mcap = 0;
    for (int e = 0; e < nelems; ++e)
      mcap = std::max(mcap, ecds_off[static_cast<std::size_t>(e) + 1] -
                                ecds_off[static_cast<std::size_t>(e)]);
    if (mcap < 1) mcap = 1;
    std::vector<double> Wbuf(static_cast<std::size_t>(kDof) * mcap, 0.0);
    std::vector<double> KWbuf(static_cast<std::size_t>(kDof) * mcap, 0.0);
    std::vector<double> Sbuf(static_cast<std::size_t>(mcap) * mcap, 0.0);
    double* const W = Wbuf.data();    // W[r * mcap + cl]
    double* const KW = KWbuf.data();  // KW[r * mcap + cl]
    double* const S = Sbuf.data();    // S[cl * mcap + dl]
    int kg[kDof];

    const bool use_cache = allow_color_cache &&
                           fea_detail::mf_galerkin_block_cache_enabled() &&
                           static_cast<int>(m.color_offsets.size()) ==
                               fea_detail::kNumColors + 1;
    std::vector<double> cacheS;
    std::vector<char> cache_valid;
    if (use_cache) {
      cacheS.assign(
          static_cast<std::size_t>(fea_detail::kNumColors) * mcap * mcap, 0.0);
      cache_valid.assign(static_cast<std::size_t>(fea_detail::kNumColors), 0);
    }
    int color = 0;  // m.elems is colour-sorted; walk the colour ranges alongside e

    // Per-element COMBINED cubic block scratch (row-major, matching m.Ke's
    // access pattern below): Kcomb = a*K_A + b*K_B + c*K_C, the same fuse the
    // apply kernel performs, formed only for cubic elements.
    double Kcomb[kDof][kDof];

    for (int e = 0; e < nelems; ++e) {
      const bool is_cubic = e >= niso;
      if (use_cache && !is_cubic)
        while (color + 1 < fea_detail::kNumColors &&
               e >= m.color_offsets[static_cast<std::size_t>(color) + 1])
          ++color;
      const int cb = ecds_off[static_cast<std::size_t>(e)];
      const int mloc = ecds_off[static_cast<std::size_t>(e) + 1] - cb;
      if (mloc == 0) continue;
      const int* edof = elem_edof(e);
      for (int r = 0; r < kDof; ++r)
        kg[r] = active[static_cast<std::size_t>(edof[r])];

      // The colour cache is an ISO-only optimisation: a cubic element's block
      // depends on its own (a,b,c), so it is never generic.
      bool generic = use_cache && !is_cubic && mloc == kDof;
      if (generic)
        for (int r = 0; r < kDof; ++r)
          if (kg[r] < 0) { generic = false; break; }

      const bool hit = generic && cache_valid[static_cast<std::size_t>(color)] != 0;
      if (hit) {
        const double* src =
            &cacheS[static_cast<std::size_t>(color) * mcap * mcap];
        for (int cl = 0; cl < mloc; ++cl)
          for (int dl = 0; dl < mloc; ++dl)
            S[cl * mcap + dl] = src[cl * mcap + dl];
      } else {
        if (is_cubic) {
          const MfCubElem& cel = m.cub_elems[static_cast<std::size_t>(e - niso)];
          for (int r = 0; r < kDof; ++r)
            for (int c = 0; c < kDof; ++c)
              Kcomb[r][c] = cel.a * m.KA(r, c) + cel.b * m.KB(r, c) +
                            cel.c * m.KC(r, c);
        }
        for (int r = 0; r < kDof; ++r)
          for (int cl = 0; cl < mloc; ++cl) W[r * mcap + cl] = 0.0;
        for (int r = 0; r < kDof; ++r) {
          if (kg[r] < 0) continue;
          for (const auto& pr : prolong[static_cast<std::size_t>(kg[r])]) {
            int idx = 0;
            while (ecds[static_cast<std::size_t>(cb + idx)] != pr.first) ++idx;
            W[r * mcap + idx] += pr.second;
          }
        }
        for (int r = 0; r < kDof; ++r)
          for (int cl = 0; cl < mloc; ++cl) {
            double s = 0.0;
            if (is_cubic) {
              for (int c = 0; c < kDof; ++c)
                s += Kcomb[r][c] * W[c * mcap + cl];
            } else {
              for (int c = 0; c < kDof; ++c) s += m.Ke(r, c) * W[c * mcap + cl];
            }
            KW[r * mcap + cl] = s;
          }
        for (int cl = 0; cl < mloc; ++cl)
          for (int dl = 0; dl < mloc; ++dl) {
            double s = 0.0;
            for (int r = 0; r < kDof; ++r)
              s += W[r * mcap + cl] * KW[r * mcap + dl];
            S[cl * mcap + dl] = s;
          }
        if (generic) {  // first generic element of this colour seeds the cache
          double* dst = &cacheS[static_cast<std::size_t>(color) * mcap * mcap];
          for (int cl = 0; cl < mloc; ++cl)
            for (int dl = 0; dl < mloc; ++dl)
              dst[cl * mcap + dl] = S[cl * mcap + dl];
          cache_valid[static_cast<std::size_t>(color)] = 1;
        }
      }

      // The cubic block already carries its coefficients; its scatter factor is
      // 1. The iso path keeps el.factor * S untouched.
      const double factor =
          is_cubic ? 1.0 : m.elems[static_cast<std::size_t>(e)].factor;
      for (int cl = 0; cl < mloc; ++cl) {
        const int i = ecds[static_cast<std::size_t>(cb + cl)];
        for (int dl = 0; dl < mloc; ++dl) {
          const double v = factor * S[cl * mcap + dl];
          if (v == 0.0) continue;
          const int j = ecds[static_cast<std::size_t>(cb + dl)];
          int lo = Aouter[j], hi = Aouter[j + 1];
          while (lo < hi) {  // binary search: Ainner[.] sorted, i present
            const int mid = (lo + hi) >> 1;
            if (Ainner[mid] < i) lo = mid + 1; else hi = mid;
          }
          Aval[lo] += v;
        }
      }
    }
  }
  return A1;
}

// THE ALGEBRAIC HIERARCHY (task: algebraic-level1-coarsening). Level 0 stays
// matrix-free and untouched; level 1 is an AGGREGATION of the fine operator
// instead of a halving of the fine grid, and levels 2.. are aggregations of the
// assembled A1.
//
// WHY THIS SHAPE. PR 283 measured that the geometric level-1 space captures
// 1.5954 % of the exact solution's energy on the maintainer's dilute field
// (99.2959 % on a healthy control), and that EVERY space below level 1 is a
// subspace of it — so the fix has to be level 1 itself. Aggregating from the
// fine operator lifts that to 56.3293 % at a SMALLER coarse dimension and
// converges in 86 PCG iterations where the shipped V-cycle stagnates at 300.
//
// *** A0 IS NEVER ASSEMBLED. *** The aggregation streams the strength graph off
// the production element table (see algebraic_coarsen.cpp) and the level-1
// operator is formed by the SAME element-local Galerkin product the geometric
// path uses — `galerkin_a1_from_prolong`, which reads P0 only as its rows and so
// never cared how they were produced. PR 230 priced fine-level assembly at
// 20-35 GB at 8.44M DOF; nothing here goes near it.
//
// EVERYTHING THAT MAKES THE CYCLE SOUND IS UNCHANGED. Only the coarse SPACES are
// algebraic: the Galerkin products, R = P^T and the bottom factorisation are
// this file's own, so the cycle stays SPD and remains a valid CG preconditioner
// whatever the aggregation produced — and the outer FP64 CG's residual test
// still defines convergence, so a different coarse space can only change the
// ITERATION COUNT, never the answer.
//
// REFUSALS ARE FREE. Any decline — a system too small, a non-scalar smoother,
// the coarsening control rejecting a level, the byte cap, a chain that never
// reaches the direct-solve cap, a bottom that will not factor — returns false
// and the caller builds the geometric hierarchy exactly as it always has.
bool build_mf_hierarchy_algebraic(const MatfreeReduced& m, int nnx, int nny,
                                  int nnz, MfHierarchy& out) {
  const fea_detail::MgTuning& tune = g_mg_tuning;
  fea_detail::AlgCoarsenStats st;

  // The POINT-BLOCK smoother needs a nodal structure a general aggregation does
  // not have below level 1, so it is REFUSED here rather than approximated —
  // the same rule build_hierarchy_from_prolongators applies.
  if (tune.smoother != fea_detail::MgSmoother::ScalarJacobi) {
    st.refused = true;
    st.refuse_reason = "point-block smoother is not available on algebraic levels";
    g_mg_alg_stats = st;
    return false;
  }
  if (m.ng <= 0 || nnx <= 0 || nny <= 0 || nnz <= 0) {
    // Publish the refusal rather than leaving the PREVIOUS build's numbers
    // standing: an observability field that silently goes stale is worse than
    // one that is absent, because it reads as this run's answer.
    st.refused = true;
    st.refuse_reason = "degenerate system or node grid";
    g_mg_alg_stats = st;
    return false;
  }

  // Fine active map: global DOF (node*3+comp) -> kept id, or -1. Same map the
  // geometric path builds, and the only fine-level bookkeeping either needs.
  std::vector<int> active(static_cast<std::size_t>(m.ndof), -1);
  for (int kg = 0; kg < m.ng; ++kg)
    active[static_cast<std::size_t>(m.kept_global[static_cast<std::size_t>(kg)])] =
        kg;

  std::vector<std::vector<std::pair<int, double>>> prolong;
  int nc = 0;
  std::vector<int> coarse_block;
  std::vector<double> bcoarse;
  if (!fea_detail::alg_level1_prolongator(m, active, nnx, nny, nnz, prolong, nc,
                                          coarse_block, bcoarse, st)) {
    g_mg_alg_stats = st;
    return false;
  }
  const int naggs = st.naggregates;

  // P0 from the aggregation's rows — the same object the geometric path builds,
  // differing only in what its rows say.
  std::vector<Trip> ptrips;
  {
    std::size_t nnzP = 0;
    for (const auto& row : prolong) nnzP += row.size();
    ptrips.reserve(nnzP);
  }
  for (int r = 0; r < m.ng; ++r)
    for (const auto& pr : prolong[static_cast<std::size_t>(r)])
      ptrips.emplace_back(r, pr.first, pr.second);
  SpMat P0(m.ng, nc);
  P0.setFromTriplets(ptrips.begin(), ptrips.end());
  P0.makeCompressed();
  std::vector<Trip>().swap(ptrips);

  const double t_gal = fea_detail::mf_steady_ms();
  // allow_color_cache=false: the colour cache is sound only for the parity-based
  // trilinear stencil (see the cache's note); an aggregation's W is not a
  // function of element colour and a cached block would be wrong.
  SpMat A1 = galerkin_a1_from_prolong(m, active, prolong, nc,
                                      /*allow_color_cache=*/false);
  st.t_coarse_ms += fea_detail::mf_steady_ms() - t_gal;
  std::vector<std::vector<std::pair<int, double>>>().swap(prolong);

  std::vector<fea_detail::MgCoo> Ps = fea_detail::alg_coarse_prolongators(
      static_cast<int>(A1.cols()), A1.outerIndexPtr(), A1.innerIndexPtr(),
      A1.valuePtr(), coarse_block, naggs, bcoarse, st);

  // Algebraic levels carry no node grid, so (nx,ny,nz) and `active` stay unset
  // on them. build_hierarchy_from_prolongators (PR 283) is the consumer: it
  // still forms every coarse operator by its OWN Galerkin product, still uses
  // R = P^T, still factors its own bottom level, and CHECKS rather than trusts
  // every prolongator's shape — so an aggregation cannot make the cycle unsound.
  std::vector<Level> coarse;
  if (!Ps.empty())
    coarse = build_hierarchy_from_prolongators(
        A1, /*cnx=*/0, /*cny=*/0, /*cnz=*/0, std::vector<int>(), Ps);

  if (coarse.empty()) {
    // No chain below level 1. If A1 is small enough to be factored directly,
    // that is still a usable TWO-LEVEL cycle (matrix-free fine + A1 direct) —
    // exactly the fallback the geometric builder takes in the same situation,
    // and on a small grid it is the ordinary outcome rather than a failure.
    // Otherwise there is no algebraic hierarchy and the geometric builder runs.
    if (static_cast<int>(A1.cols()) > tune.coarse_dof_cap) {
      st.refused = true;
      if (st.refuse_reason.empty())
        st.refuse_reason = "solver rejected the algebraic prolongator chain";
      g_mg_alg_stats = st;
      return false;
    }
    Level only;
    only.n = static_cast<int>(A1.cols());
    only.A = A1;
    only.Dinv = inverse_diagonal(A1);
    only.coarsest = true;
    only.chol = std::make_shared<Eigen::SimplicialLDLT<SpMat>>();
    only.chol->compute(only.A);
    if (only.chol->info() != Eigen::Success) {
      st.refused = true;
      st.refuse_reason = "algebraic level-1 operator would not factor";
      g_mg_alg_stats = st;
      return false;
    }
    st.refuse_reason.clear();  // a 2-level cycle is a RESULT, not a refusal
    coarse.push_back(std::move(only));
  }

  st.levels = 1 + static_cast<int>(coarse.size());  // + the matrix-free level 0
  st.bytes += static_cast<std::size_t>(P0.nonZeros()) *
              (sizeof(double) + sizeof(int));
  st.refused = false;
  g_mg_alg_stats = st;

  out.m = &m;
  out.fine_dinv = Eigen::Map<const Vec>(
      m.invdiag.data(), static_cast<Eigen::Index>(m.invdiag.size()));
  out.P0 = std::move(P0);
  out.coarse = std::move(coarse);
  record_hierarchy_dims(m, out.coarse);
  mf_build_point_block_fine(m, active, tune, out);
  return true;
}

// FINE-level point-block smoother data (and the FP32 copies), built only when
// those options are selected — the shipped path skips both blocks entirely.
// Factored out of build_mf_hierarchy alongside the Galerkin product so the
// geometric and algebraic hierarchy shapes share one copy; the body is the
// historical code verbatim, so the shipped path is byte-identical.
//
// The point-block data is built by the same element sweep
// mf_build_reduced runs for the scalar diagonal, but keeping the whole 3x3
// NODAL block instead of just Ke(r,r): a local index r carries component r%3
// of node edof[r]/3, so two local indices sharing a node contribute to that
// node's block at (r%3, c%3). Summed over elements this is exactly the 3x3
// diagonal block of A0 — the fine operator is never assembled to get it.
void mf_build_point_block_fine(const MatfreeReduced& m,
                               const std::vector<int>& active,
                               const fea_detail::MgTuning& tune,
                               MfHierarchy& out) {
  if (tune.smoother == fea_detail::MgSmoother::PointBlockJacobi) {
    constexpr int kDofL = Hex8Stiffness::kDof;
    const std::size_t nnodes_full = static_cast<std::size_t>(m.ndof) / 3;
    std::vector<double> blockfull(nnodes_full * 9, 0.0);
    for (const MfElem& el : m.elems)
      for (int r = 0; r < kDofL; ++r)
        for (int c = 0; c < kDofL; ++c) {
          if (el.edof[r] / 3 != el.edof[c] / 3) continue;
          blockfull[static_cast<std::size_t>(el.edof[r] / 3) * 9 +
                    static_cast<std::size_t>(r % 3) * 3 +
                    static_cast<std::size_t>(c % 3)] += el.factor * m.Ke(r, c);
        }
    for (const MfCubElem& el : m.cub_elems)
      for (int r = 0; r < kDofL; ++r)
        for (int c = 0; c < kDofL; ++c) {
          if (el.edof[r] / 3 != el.edof[c] / 3) continue;
          blockfull[static_cast<std::size_t>(el.edof[r] / 3) * 9 +
                    static_cast<std::size_t>(r % 3) * 3 +
                    static_cast<std::size_t>(c % 3)] +=
              el.a * m.KA(r, c) + el.b * m.KB(r, c) + el.c * m.KC(r, c);
        }
    // Compress to one entry per node that owns at least one KEPT DOF, using the
    // same active map the prolongation was built from.
    for (std::size_t nd = 0; nd < nnodes_full; ++nd) {
      int d[3];
      bool present[3];
      bool any = false;
      for (int c = 0; c < 3; ++c) {
        d[c] = active[nd * 3 + static_cast<std::size_t>(c)];
        present[c] = d[c] >= 0;
        any = any || present[c];
      }
      if (!any) continue;
      double inv[9];
      invert_node_block(&blockfull[nd * 9], present, inv);
      for (int c = 0; c < 3; ++c) out.fine_pbd.dof.push_back(d[c]);
      for (int k = 0; k < 9; ++k) out.fine_pbd.inv.push_back(inv[k]);
    }
  }

  // FP32 copies for the mixed-precision V-cycle, built only when enabled (handoff
  // 092). This composes cleanly with the Galerkin block cache (090): that cache
  // lives entirely in the FP64 coarse-operator build above (A1..LDLT), which the
  // mixed path leaves untouched — it only rounds the already-built fine P0 and
  // fine Jacobi diagonal to float. Cache and FP32 are orthogonal; both may be on.
  if (fea_detail::mf_mixed_precision_enabled()) {
    out.P0f = out.P0.cast<float>();
    out.fine_dinv_f = out.fine_dinv.cast<float>();
  }
}

// Matrix-free MG-CG solve, falling back to the exact matrix-free Jacobi-CG when
// a hierarchy is not applicable or MG does not converge. Mirrors
// solve_reduced_mgcg's fallback discipline and scatter, but the FINE level is
// never assembled. `elem_youngs` selects the graded path when non-null.
FeaSolution solve_mgcg_matfree(const VoxelGrid& grid, double youngs_modulus,
                               double poisson,
                               const std::vector<DirichletBC>& bcs,
                               const std::vector<NodalLoad>& loads,
                               double tolerance, int max_iterations, CgInfo* info,
                               const std::vector<double>* elem_youngs,
                               const std::vector<char>* active_mask,
                               const MfLatticeArrays* lattice = nullptr,
                               const FeaSolution* initial_guess = nullptr) {
  // Build the reduced, void-gated matrix-free system (throws + sets *info on a
  // void-gate rejection, exactly like solve_reduced_mgcg's gate). `active_mask`
  // (active-domain phase 1) restricts WHICH solid voxels contribute an element;
  // everything below — the void gate, the kept-DOF numbering, the Jacobi
  // diagonal, this hierarchy build and every V-cycle — then operates on the
  // surviving system unchanged and exactly. Null = the pre-feature path.
  // `lattice` (multiscale production wiring) selects the composite
  // isotropic-or-cubic operator; every stage below is operator-agnostic and
  // needs no per-stage lattice handling beyond the mixed-precision guard.
  // Per-solve phase timing (task 2026-08-02-iteration-phase-timing): the reduced
  // build, the HIERARCHY build (the expensive part the 127 latch exists to skip),
  // the V-cycle loop and the Jacobi fallback are timed separately, because a
  // solve's `iterations` count describes only the last of those.
  const double t_entry = fea_detail::mf_steady_ms();
  const long long mv_entry = fea_matvec_count();
  MatfreeReduced m = fea_detail::mf_build_reduced(
      grid, youngs_modulus, poisson, bcs, loads, elem_youngs,
      lattice != nullptr ? "fea_solve_cg_lattice_matfree"
                         : "fea_solve_mgcg_matfree",
      info, active_mask, lattice);
  const double t_built = fea_detail::mf_steady_ms();

  CgInfo diag;
  diag.converged = true;  // no free DOFs -> trivially converged
  diag.t_build_ms = t_built - t_entry;

  std::vector<double> u = m.up;
  if (m.ng > 0) {
    const int nnx = grid.nx + 1, nny = grid.ny + 1, nnz = grid.nz + 1;
    const int cap =
        max_iterations > 0 ? max_iterations : std::max(1000, 2 * m.ng);

    // Per-run stagnation latch (handoff 127): once MG has stagnated on
    // kMgLatchThreshold consecutive solves this run, stop even BUILDING the
    // hierarchy (the build is the expensive part) — go straight to Jacobi. The
    // latch is reset per run by the driver; a converging solve clears it below.
    MfHierarchy H;
    // MEASUREMENT-ONLY re-arm (see g_mg_rearm_period). Unreachable when the
    // period is 0, which is the production default, so the shipped path below
    // reads exactly as it did: try_mg = !g_mg_latched.
    bool rearmed_this_solve = false;
    if (g_mg_latched && g_mg_rearm_period > 0 &&
        ++g_mg_latched_solves >= g_mg_rearm_period) {
      g_mg_latched = false;
      g_mg_latched_solves = 0;
      // One stagnation re-latches; see the comment at the declaration.
      g_mg_consecutive_stagnations = kMgLatchThreshold - 1;
      rearmed_this_solve = true;
      ++g_mg_rearm_attempts;
    }
    const bool try_mg = !g_mg_latched;
    const double t_h0 = fea_detail::mf_steady_ms();
    const bool have_h = try_mg && build_mf_hierarchy(m, nnx, nny, nnz, H);
    // 0 when the latch short-circuited the build — which is exactly the reading
    // a latched rung needs: the hierarchy cost is NOT where its wall time went.
    diag.t_mg_build_ms = try_mg ? fea_detail::mf_steady_ms() - t_h0 : 0.0;
    // Fallback-mode diagnostics (handoff 128): whether a hierarchy built this
    // solve, and how many MG-CG cycles it attempted. hier_built==false when the
    // grid is not coarsenable (build-rejection) OR the 127 latch skipped the build.
    diag.hier_built = have_h;

    std::vector<double> xkept(static_cast<std::size_t>(m.ng), 0.0);
    // WARM START (task 2026-08-10-plsm-production, S3). `m.kept_global[k]` is the
    // GLOBAL dof the kept index k stands for, so a previous solution on the same
    // grid seeds the reduced vector by a gather and nothing else. A guess of the
    // wrong length is IGNORED rather than diagnosed: the caller holds a solution
    // from a grid it may since have changed, a silently-cold solve is correct,
    // and throwing here would turn an accelerator into a failure mode. Null (the
    // default) leaves xkept at zero — the pre-feature path, byte-for-byte.
    bool warm = false;
    if (initial_guess != nullptr && initial_guess->u.size() == u.size()) {
      warm = true;
      for (int k = 0; k < m.ng; ++k) {
        const double g =
            initial_guess
                ->u[static_cast<std::size_t>(m.kept_global[static_cast<std::size_t>(k)])];
        if (!std::isfinite(g)) { warm = false; break; }
        xkept[static_cast<std::size_t>(k)] = g;
      }
      if (!warm)
        std::fill(xkept.begin(), xkept.end(), 0.0);
    }
    // Krylov recycling accounting for THIS solve (handoff 133). A solve that
    // attempts MG-CG and then falls back to Jacobi-CG pays the k setup matvecs
    // twice; the report ACCUMULATES them so the charged cost is honest.
    fea_detail::RecycleReport rec;
    bool solved = false;
    const double t_mg0 = fea_detail::mf_steady_ms();
    if (have_h) {
      Vec rgv = Eigen::Map<const Vec>(m.rg.data(),
                                      static_cast<Eigen::Index>(m.ng));
      const int mg_cap = std::min(cap, kMgIterBudget);
      Vec xg;
      int it = 0;
      double res = 0.0;
      MfScratch scratch;
      scratch.resize(m.ng, static_cast<int>(H.P0.cols()));
      // Mixed-precision V-cycle (handoff 092) when enabled: try the FP32-V-cycle
      // MG-CG first; if the sloppier preconditioner fails to reach tol within the
      // budget, RETRY the exact FP64 MG-CG on the same hierarchy before the Jacobi
      // fallback below — never ship an unconverged result (fallback discipline of
      // 078/079). When mixed precision is OFF this is exactly the prior FP64 call.
      // The FP32 V-cycle carries no cubic pass (apply_kgg_raw_f32's tripwire),
      // so a cubic system always preconditions in FP64 — mixed precision is
      // production-blocked anyway (handoff 132 D).
      const bool mixed = fea_detail::mf_mixed_precision_enabled() &&
                         H.fine_dinv_f.size() == m.ng && !m.has_cubic;
      if (mixed) scratch.resize_f(m.ng, static_cast<int>(H.P0.cols()));
      // The warm guess, as an Eigen vector the MG-CG loop can start from.
      // Held here (not inside mf_mgpcg) so the FP64 RETRY after a failed mixed
      // attempt starts from the SAME guess rather than from the failed iterate.
      Vec x0;
      if (warm) x0 = Eigen::Map<const Vec>(xkept.data(),
                                           static_cast<Eigen::Index>(m.ng));
      const Vec* x0p = warm ? &x0 : nullptr;
      bool ok = mf_mgpcg(H, scratch, rgv, tolerance, mg_cap, xg, it, res, mixed,
                         &rec, x0p);
      if (!ok && mixed)
        ok = mf_mgpcg(H, scratch, rgv, tolerance, mg_cap, xg, it, res,
                      /*mixed=*/false, &rec, x0p);
      // Cycles this solve burned on MG-CG (the last attempt's count when a mixed
      // attempt was retried in FP64): honest whether it converged or stagnated.
      diag.mg_cycles_attempted = it;
      if (ok) {
        for (int k = 0; k < m.ng; ++k) xkept[static_cast<std::size_t>(k)] = xg[k];
        diag.iterations = it;
        diag.residual = res;
        diag.converged = true;
        diag.used_multigrid = true;
        diag.mg_levels = H.levels();
        solved = true;
      }
      // MG did not converge / broke down -> fall through to the exact fallback.
    }
    // The V-cycle loop's wall, whether it carried or stagnated (0 when no
    // hierarchy was attempted at all).
    diag.t_mg_ms = have_h ? fea_detail::mf_steady_ms() - t_mg0 : 0.0;

    // Latch bookkeeping (handoff 127): only when a hierarchy was actually built
    // and attempted. A converging solve clears the counter (so a healthy run never
    // latches and is bit-identical); a stagnated one advances it, latching MG off
    // for the rest of the run once kMgLatchThreshold consecutive stagnations pile
    // up. A build-FAILURE (never coarsenable) is neither — leave the counter alone.
    if (have_h) {
      if (solved) {
        g_mg_consecutive_stagnations = 0;
        // Measurement accounting only (0 in production): a re-armed retry that
        // CARRIED is the single observation the re-arm question turns on.
        if (rearmed_this_solve) ++g_mg_rearm_carries;
      } else if (++g_mg_consecutive_stagnations >= kMgLatchThreshold) {
        g_mg_latched = true;
      }
    }

    if (!solved) {
      // Exact matrix-free fallback (Jacobi-CG). Reports the Jacobi attempt in
      // *info (used_multigrid=false); throws on non-convergence, parity with
      // fea_solve_cg and the assembled fea_solve_mgcg fallback. This is the
      // high-contrast stagnation regime the two-level GenEO preconditioner targets;
      // the context lets an installed hook (default none => byte-identical) build
      // its coarse basis / decomposition for THIS system.
      fea_detail::MfSolveContext pc;
      pc.grid = &grid;
      pc.elem_youngs = elem_youngs;
      pc.youngs_modulus = youngs_modulus;
      pc.poisson = poisson;
      // Lattice fields (multiscale production wiring): GenEO assembles its
      // local operators from the true composite blocks AND keys its moduli
      // fingerprint on these — a tensor-only design change must refresh the
      // held coarse operator, never silently reuse it.
      if (lattice != nullptr) pc.lattice = *lattice;
      fea_detail::MfCgTimes tm;
      fea_detail::mf_cg_solve(m, tolerance, cap, xkept, diag.iterations,
                              diag.residual, diag.converged, &rec, &pc, &tm);
      diag.used_multigrid = false;
      diag.mg_levels = 0;
      diag.recycle_dim = rec.dim;
      diag.recycle_setup_matvecs = rec.setup_matvecs;
      diag.t_cg_ms = tm.cg_ms;
      diag.t_geneo_setup_ms = tm.geneo_setup_ms;
      diag.t_geneo_apply_ms = tm.geneo_apply_ms;
      diag.t_recycle_ms = tm.recycle_ms;
      {
        // GenEO two-level diagnostics for THIS fallback solve (all 0 when the
        // deflation is off or never engaged — the library default).
        fea_detail::geneo_fill_cg_info(diag, fea_detail::geneo_last_report());
      }
      diag.t_total_ms = fea_detail::mf_steady_ms() - t_entry;
      diag.matvecs = fea_matvec_count() - mv_entry;
      if (info) *info = diag;
      if (!diag.converged)
        throw SolverNonConvergence(
            "fea_solve_mgcg_matfree: CG did not reach the requested tolerance "
            "within max_iterations",
            diag.iterations, diag.residual);
    }

    diag.recycle_dim = rec.dim;
    diag.recycle_setup_matvecs = rec.setup_matvecs;

    for (int k = 0; k < m.ng; ++k)
      u[static_cast<std::size_t>(m.kept_global[static_cast<std::size_t>(k)])] =
          xkept[static_cast<std::size_t>(k)];
  }

  diag.t_total_ms = fea_detail::mf_steady_ms() - t_entry;
  diag.matvecs = fea_matvec_count() - mv_entry;
  if (info) *info = diag;

  FeaSolution sol;
  sol.u = std::move(u);
  return sol;
}

// --- Memory evidence (diagnostic) ------------------------------------------
// Total nonzeros stored across the ASSEMBLED operators of the multigrid
// hierarchy each solver builds, for a solid or graded grid. For the assembled
// fea_solve_mgcg this INCLUDES the fine operator A0 (the big one); for the
// matrix-free path only the coarse operators are assembled (the fine level
// stores just the 576-double reference Ke). The gap — and how it widens with
// grid size — demonstrates the fine matrix is absent on the matrix-free path.
std::size_t assembled_hierarchy_nonzeros(const VoxelGrid& grid,
                                         double youngs_modulus, double poisson,
                                         const std::vector<DirichletBC>& bcs,
                                         const std::vector<NodalLoad>& loads,
                                         const std::vector<double>* elem_youngs) {
  ReducedSystem s = fea_detail::assemble_reduced(
      grid, elem_youngs != nullptr ? 1.0 : youngs_modulus, poisson, bcs, loads,
      "assembled_hierarchy_nonzeros", elem_youngs);
  const int nf = static_cast<int>(s.freedofs.size());
  if (nf == 0) return 0;
  std::vector<int> kept =
      fea_detail::void_dof_survivors(s.Kff, s.rf, "assembled_hierarchy_nonzeros");
  const int ng = static_cast<int>(kept.size());

  SpMat Kgg;
  if (ng != nf) {
    SpMat Q(ng, nf);
    std::vector<Trip> qtrips;
    qtrips.reserve(static_cast<std::size_t>(ng));
    for (int r = 0; r < ng; ++r) qtrips.emplace_back(r, kept[r], 1.0);
    Q.setFromTriplets(qtrips.begin(), qtrips.end());
    Kgg = Q * s.Kff * Q.transpose();
    Kgg.makeCompressed();
  } else {
    Kgg = s.Kff;
  }

  const int nnx = grid.nx + 1, nny = grid.ny + 1, nnz = grid.nz + 1;
  std::vector<int> active(static_cast<std::size_t>(nnx) * nny * nnz * 3, -1);
  for (int r = 0; r < ng; ++r) {
    const int gdof = s.freedofs[static_cast<std::size_t>(kept[r])];
    active[static_cast<std::size_t>(gdof)] = r;
  }
  std::vector<Level> levels =
      build_hierarchy(Kgg, nnx, nny, nnz, active, /*frugal=*/false,
                      g_mg_tuning.max_levels, /*global_level0=*/0);
  if (levels.empty())
    return static_cast<std::size_t>(Kgg.nonZeros());  // fallback: only Kgg
  std::size_t total = 0;
  for (const Level& L : levels) total += static_cast<std::size_t>(L.A.nonZeros());
  return total;
}

std::size_t matfree_hierarchy_nonzeros(const VoxelGrid& grid,
                                       double youngs_modulus, double poisson,
                                       const std::vector<DirichletBC>& bcs,
                                       const std::vector<NodalLoad>& loads,
                                       const std::vector<double>* elem_youngs) {
  MatfreeReduced m = fea_detail::mf_build_reduced(
      grid, youngs_modulus, poisson, bcs, loads, elem_youngs,
      "matfree_hierarchy_nonzeros", nullptr);
  if (m.ng == 0) return 0;
  MfHierarchy H;
  const int nnx = grid.nx + 1, nny = grid.ny + 1, nnz = grid.nz + 1;
  if (!build_mf_hierarchy(m, nnx, nny, nnz, H)) return 0;  // no assembled ops
  std::size_t total = 0;  // fine level (level 0) is matrix-free: 0 assembled nnz
  for (const Level& L : H.coarse)
    total += static_cast<std::size_t>(L.A.nonZeros());
  return total;
}

}  // namespace

// --- Component tuning accessors (task: multigrid-component-sweep) ------------
// Production never calls the setter, so mg_tuning() returns the shipped recipe
// and every solve above takes exactly the path it took before this task. The
// static_asserts near g_mg_tuning bind the header's defaults to the constants
// this file's V-cycle is documented against; tests/unit/test_mg_tuning.cpp
// re-asserts them against literals so a coordinated drift still fails.
namespace fea_detail {

const MgTuning& mg_tuning() { return g_mg_tuning; }
void mg_set_tuning(const MgTuning& t) { g_mg_tuning = t; }
void mg_reset_tuning() { g_mg_tuning = MgTuning{}; }

// --- Coarse-space seam accessors (task: hybrid-amg-coarsening-probe) ---------
// Production never installs a hook, so `mg_coarse_space_hook_installed()` is
// false and build_mf_hierarchy's seam block is never entered.
MgCoarseSpaceHook mg_set_coarse_space_hook(MgCoarseSpaceHook hook) {
  MgCoarseSpaceHook prev = g_mg_coarse_hook;
  g_mg_coarse_hook = std::move(hook);
  return prev;
}
bool mg_coarse_space_hook_installed() {
  return static_cast<bool>(g_mg_coarse_hook);
}

// --- Algebraic level-1 accessors (task: algebraic-level1-coarsening) ---------
const AlgCoarsenStats& mg_algebraic_level1_stats() { return g_mg_alg_stats; }
void mg_reset_algebraic_level1_stats() { g_mg_alg_stats = AlgCoarsenStats{}; }

}  // namespace fea_detail

// Per-run multigrid stagnation latch (handoff 127, Amendment 2). The driver
// calls the reset once at the start of a run so consecutive-stagnation counting
// starts fresh; the getter is for tests/diagnostics. Thread-local: valid on the
// thread that issues the run's solves. Off the matrix-free multigrid path these
// are inert (nothing reads the latch).
void fea_matfree_reset_mg_stagnation_latch() {
  g_mg_consecutive_stagnations = 0;
  g_mg_latched = false;
  g_mg_latched_solves = 0;
  g_mg_rearm_attempts = 0;
  g_mg_rearm_carries = 0;
}

bool fea_matfree_mg_stagnation_latched() { return g_mg_latched; }

// The MEASUREMENT-ONLY latch re-arm period (task
// solver-speed-arm-and-diagnose; closes handoff
// 2026-07-27-mg-stagnation-phase0 §7's named gap). Production never calls this
// setter — 0 is the default and no production caller exists — so the shipped
// latch policy is unchanged and every production artifact is byte-identical.
// The period deliberately SURVIVES fea_matfree_reset_mg_stagnation_latch()
// (which the driver calls at run start and which clears the latch state and the
// re-arm counters), for the same reason the GenEO probe config survives
// fea_reset_geneo_basis: a harness sets the posture around a run and must not
// have it erased by the run's own start. See the declaration for the semantics
// of a re-armed attempt.
void fea_matfree_set_mg_rearm_period(int period) {
  g_mg_rearm_period = period > 0 ? period : 0;
  g_mg_latched_solves = 0;
}

int fea_matfree_mg_rearm_period() { return g_mg_rearm_period; }
long long fea_matfree_mg_rearm_attempts() { return g_mg_rearm_attempts; }
long long fea_matfree_mg_rearm_carries() { return g_mg_rearm_carries; }

// Parity-pad mode (task: multigrid-odd-axis-cliff). Production never calls the
// setter (AUTO is the default); tests use OFF to exercise the legacy rejection
// path with its assertions intact, and FORCE to prove on a fully-coarsenable
// control grid that the pad is bit-identical. Thread-local like the latch.
void fea_set_mg_parity_pad_mode(int mode) {
  g_mg_parity_pad_mode =
      (mode == kMgPadOff || mode == kMgPadForce) ? mode : kMgPadAuto;
}

int fea_mg_parity_pad_mode() { return g_mg_parity_pad_mode; }

// --- Algebraic level-1 coarsening: the arming dial and its report ------------
// The LIBRARY default is OFF (g_mg_alg_level1's initialiser, tripwired by the
// static_assert beside it), so a process that never calls this setter takes the
// geometric hierarchy on every solve and is byte-identical to before this
// feature existed.
bool fea_set_mg_algebraic_level1(bool enable) {
  const bool prev = g_mg_alg_level1;
  g_mg_alg_level1 = enable;
  return prev;
}
bool fea_mg_algebraic_level1_enabled() { return g_mg_alg_level1; }

MgAlgebraicLevel1Info fea_mg_algebraic_level1_info() {
  const fea_detail::AlgCoarsenStats& s = g_mg_alg_stats;
  MgAlgebraicLevel1Info out;
  out.fine_dofs = s.fine_dofs;
  out.fine_nodes = s.fine_nodes;
  out.aggregates = s.naggregates;
  out.coarse_dim = s.coarse_dim;
  out.levels = s.levels;
  out.fine_nnz_per_row = s.fine_nnz_per_row;
  out.bytes = static_cast<unsigned long long>(s.bytes);
  out.setup_ms = s.t_incidence_ms + s.t_strength_ms + s.t_aggregate_ms +
                 s.t_tentative_ms + s.t_coarse_ms;
  out.armed = g_mg_alg_level1;
  out.refused = s.refused;
  // Copied as a VALUE (the header's contract) — the caller may outlive the next
  // build, which would overwrite the solver's own string.
  const std::size_t cap = sizeof(out.refuse_reason) - 1;
  const std::size_t n = std::min(cap, s.refuse_reason.size());
  std::memcpy(out.refuse_reason, s.refuse_reason.data(), n);
  out.refuse_reason[n] = '\0';
  out.level_count = static_cast<int>(
      std::min(s.level_dims.size(),
               sizeof(out.level_dim) / sizeof(out.level_dim[0])));
  for (int i = 0; i < out.level_count; ++i)
    out.level_dim[i] = s.level_dims[static_cast<std::size_t>(i)];
  return out;
}

void fea_mg_reset_algebraic_level1_info() {
  fea_detail::mg_reset_algebraic_level1_stats();
}

int fea_mg_last_hierarchy_dims(int* out, int cap) {
  const int n = static_cast<int>(g_mg_last_level_dims.size());
  if (out != nullptr)
    for (int i = 0; i < n && i < cap; ++i)
      out[i] = g_mg_last_level_dims[static_cast<std::size_t>(i)];
  return n;
}

FeaSolution fea_solve_mgcg(const VoxelGrid& grid, double youngs_modulus,
                           double poisson, const std::vector<DirichletBC>& bcs,
                           const std::vector<NodalLoad>& loads, double tolerance,
                           int max_iterations, CgInfo* info) {
  ReducedSystem s = fea_detail::assemble_reduced(grid, youngs_modulus, poisson,
                                                 bcs, loads, "fea_solve_mgcg");
  return solve_reduced_mgcg(s, grid, tolerance, max_iterations, info);
}

FeaSolution fea_solve_mgcg(const VoxelGrid& grid,
                           const std::vector<double>& youngs_per_voxel,
                           double poisson, const std::vector<DirichletBC>& bcs,
                           const std::vector<NodalLoad>& loads, double tolerance,
                           int max_iterations, CgInfo* info) {
  ReducedSystem s = fea_detail::assemble_reduced(
      grid, 1.0, poisson, bcs, loads, "fea_solve_mgcg", &youngs_per_voxel);
  return solve_reduced_mgcg(s, grid, tolerance, max_iterations, info);
}

// --- Matrix-free multigrid entry points (opt-in, default OFF) --------------

FeaSolution fea_solve_mgcg_matfree(const VoxelGrid& grid, double youngs_modulus,
                                   double poisson,
                                   const std::vector<DirichletBC>& bcs,
                                   const std::vector<NodalLoad>& loads,
                                   double tolerance, int max_iterations,
                                   CgInfo* info) {
  return solve_mgcg_matfree(grid, youngs_modulus, poisson, bcs, loads, tolerance,
                            max_iterations, info, nullptr, nullptr);
}

FeaSolution fea_solve_mgcg_matfree(const VoxelGrid& grid,
                                   const std::vector<double>& youngs_per_voxel,
                                   double poisson,
                                   const std::vector<DirichletBC>& bcs,
                                   const std::vector<NodalLoad>& loads,
                                   double tolerance, int max_iterations,
                                   CgInfo* info,
                                   const std::vector<char>* active_mask,
                                   const FeaSolution* initial_guess) {
  return solve_mgcg_matfree(grid, 1.0, poisson, bcs, loads, tolerance,
                            max_iterations, info, &youngs_per_voxel, active_mask,
                            nullptr, initial_guess);
}

// Matrix-free CUBIC LATTICE solve (multiscale production wiring): the composite
// isotropic-or-cubic system of fea_solve_cg_lattice on the FULL matrix-free
// accelerator stack — multigrid-first (Galerkin coarse operators decomposed
// over the three reference blocks), exact matrix-free Jacobi-CG fallback with
// GenEO two-level deflation and Krylov recycling exactly as the scalar
// production solver runs them. Same solution within `tolerance` as the
// assembled path; a different iteration route, never a different answer (every
// preconditioner term is SPD and the stopping test is unchanged).
FeaSolution fea_solve_cg_lattice_matfree(
    const VoxelGrid& grid, const std::vector<double>& youngs_per_voxel,
    const std::vector<char>& lattice_mask, const std::vector<double>& lattice_c11,
    const std::vector<double>& lattice_c12, const std::vector<double>& lattice_c44,
    double poisson, const std::vector<DirichletBC>& bcs,
    const std::vector<NodalLoad>& loads, double tolerance, int max_iterations,
    CgInfo* info, const std::vector<char>* active_mask) {
  MfLatticeArrays lat;
  lat.mask = &lattice_mask;
  lat.c11 = &lattice_c11;
  lat.c12 = &lattice_c12;
  lat.c44 = &lattice_c44;
  return solve_mgcg_matfree(grid, 1.0, poisson, bcs, loads, tolerance,
                            max_iterations, info, &youngs_per_voxel, active_mask,
                            &lat);
}

std::size_t fea_mgcg_assembled_operator_nonzeros(
    const VoxelGrid& grid, double youngs_modulus, double poisson,
    const std::vector<DirichletBC>& bcs, const std::vector<NodalLoad>& loads) {
  return assembled_hierarchy_nonzeros(grid, youngs_modulus, poisson, bcs, loads,
                                      nullptr);
}

std::size_t fea_matfree_mgcg_assembled_operator_nonzeros(
    const VoxelGrid& grid, double youngs_modulus, double poisson,
    const std::vector<DirichletBC>& bcs, const std::vector<NodalLoad>& loads) {
  return matfree_hierarchy_nonzeros(grid, youngs_modulus, poisson, bcs, loads,
                                    nullptr);
}

}  // namespace topopt
