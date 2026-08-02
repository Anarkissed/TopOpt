// algebraic_coarsen.hpp — ALGEBRAIC LEVEL-1 COARSENING for the matrix-free
// multigrid hierarchy (task: algebraic-level1-coarsening). Internal, not part of
// the public topopt/ API, and — like fea_matfree.hpp — deliberately Eigen-FREE:
// the assembled level-1 operator crosses this boundary as raw CSC pointers, so
// nothing here needs a sparse-matrix type.
//
// WHY IT EXISTS
//   PR 280 swept 25 configurations of the shipped geometric V-cycle on the
//   maintainer's real dilute field and got ZERO convergences, with levels
//   2/3/4/5/MAX all producing an IDENTICAL 4,841 applies. PR 283 then measured
//   the cause directly: the GEOMETRIC level-1 coarse space, range(P0), captures
//   1.5954 % of the exact solution's energy on that field (99.2959 % on a healthy
//   control). Every space built BELOW level 1 is a subspace of range(P0), so that
//   1.5954 % is a hard ceiling — PR 283 walked an algebraic level 2 up to 18,688
//   of level 1's 18,738 dimensions and read 1.5952 %.
//
//   PR 283's §4 pointed the same instrument ONE LEVEL UP and found the fix:
//   aggregating from the FINE operator instead of halving it lifts level-1
//   capture to 56.3293 % at a SMALLER coarse dimension (13,140 vs 18,738), and
//   that hierarchy converges in 86 PCG iterations where the shipped V-cycle
//   stagnates at 300 and falls back to a 3,636-iteration Jacobi-CG.
//
//   This header is that level-1 space, built as PRODUCTION code.
//
// *** THE CONSTRAINT THAT MUST NOT SLIP: A0 IS NEVER ASSEMBLED. ***
//   PR 230 priced fine-level assembly at 20-35 GB on an 8.44M-DOF job, and the
//   matrix-free level 0 is the only reason that job fits at all. Every setup
//   quantity below is streamed ELEMENT-LOCALLY off the production element table
//   (`MatfreeReduced::elems` / `cub_elems`) through a node->element incidence
//   list, one node row at a time, in O(1) extra memory per node:
//     * the node-block strength graph          (alg_strength_graph)
//     * the fine operator's true nnz/row       (same pass, for the growth rule)
//   and the level-1 operator A1 = P0^T A0 P0 is formed by the element-local
//   triple product multigrid.cpp ALREADY uses for the geometric P0 — this header
//   only supplies the prolongator ROWS, in exactly the form that product reads.
//   Nothing here ever holds a fine-level matrix.
//
//   The prolongator is UNSMOOTHED (P = T). That is not a simplification: PR 230
//   §6d and PR 283 §4 both measured unsmoothed beating smoothed on every axis
//   here (86 vs 243 iterations, 45.6 vs 149.8 MB, 0.6 vs 7.7 s setup), and
//   forming T needs only the aggregation — never A's rows — so it is the variant
//   that fits a matrix-free fine level natively. Smoothing would require A*T,
//   which is the one setup quantity that would push toward materialising A0.
//
// DETERMINISM
//   Ascending traversal everywhere, smallest-index tie-breaks, sorted column
//   emission, fixed summation order. No power iteration, no random start, no
//   thread-id or address dependence. Two setups on the same input are
//   bit-identical; test_mg_algebraic_level1 asserts it.

#pragma once

#include <cstddef>
#include <string>
#include <vector>

#include "topopt/coarsen.hpp"  // kMgCoarseDofCap — the solver's own bottom cap

#include "fea_matfree.hpp"  // MatfreeReduced, MgCoo

namespace topopt {
namespace fea_detail {

// ---------------------------------------------------------------------------
// THE NAMED RECIPE CONSTANTS, with their derivations.
// ---------------------------------------------------------------------------

// Vanek strength threshold. PR 283 §4 swept it and measured theta 0.02 the
// winner on BOTH axes that matter: 56.3293 % capture at coarse dim 13,140 and 86
// PCG iterations, against theta 0.08's 61.7518 % capture but 292 iterations. That
// inversion is the finding behind this number — capture is necessary, not
// sufficient: theta 0.08 captures MORE and converges SLOWER because its
// hierarchy degrades below level 1 (level 3 rejected on coarsening ratio, bottom
// level 8,544 smoothed rather than solved). A good level-1 space still needs a
// working stack under it, and 0.02 is the setting that produces one.
constexpr double kAlgStrengthTheta = 0.02;

// The near-nullspace dimension: the 6 rigid-body modes of 3D elasticity.
constexpr int kAlgNullspaceDim = 6;

// Columns whose norm falls below this fraction of their pre-orthogonalisation
// norm are DROPPED from an aggregate's block (an aggregate with fewer rows than
// 6 cannot support 6 independent modes). Standard smoothed-aggregation practice;
// the same value amg_sa.hpp's measured path used.
constexpr double kAlgQrDropTol = 1e-10;

// COARSENING CONTROL — the admission rule applied at EVERY level including
// level 1. PR 230 §2d measured the failure this bounds: without it the coarsening
// ratio collapses down the hierarchy (10.6x -> 5.1x -> 3.1x -> 1.35x) and the
// coarse operators fill in until a level is 100 % dense, which is what made
// setup explode 6.7x and memory go to 3.3 GB.
constexpr double kAlgMinCoarseningRatio = 2.0;
constexpr double kAlgMaxNnzPerRow = 400.0;
constexpr double kAlgMaxLevelDensity = 0.10;
constexpr double kAlgMaxStencilGrowth = 8.0;

// The bottom level is factored directly by the SOLVER's own SimplicialLDLT (this
// header never factors anything), so this cap must match the one
// build_hierarchy_from_prolongators enforces — kMgCoarseDofCap. Named here so
// the aggregation stops at a level the solver will actually accept rather than
// handing it a chain it is going to reject.
constexpr int kAlgCoarseDofCapMirror = kMgCoarseDofCap;

constexpr int kAlgMaxLevels = 12;

// *** THE MEMORY CAP — refuse-and-fall-back, PR 248's kGeneoMaxBasisMB shape. ***
// The aggregation REFUSES (and the solver falls straight through to the shipped
// geometric builder) rather than allocating past this. See the handoff's AH3 for
// the measured scaling this is set from; the precedent for the shape — measure,
// then cap rather than OOM on the maintainer's real job — is PR 248's 2048 MB
// GenEO basis cap. Counted over what the ALGEBRAIC path ADDS: the prolongator
// rows, the strength graph, the incidence list and every coarse operator. Level 1
// itself is production's cost either way and is NOT charged here.
constexpr std::size_t kAlgMaxCoarseBytes =
    static_cast<std::size_t>(2048) * 1024 * 1024;

// ---------------------------------------------------------------------------
// What a build reports. Pure observation — no solver decision reads these except
// `refused`, and every field is exact (counts and byte totals), so they are
// load-independent evidence.
// ---------------------------------------------------------------------------
struct AlgCoarsenStats {
  int fine_dofs = 0;
  int fine_nodes = 0;
  int naggregates = 0;   // level-1 aggregates
  int coarse_dim = 0;    // level-1 coarse DOFs (< 6 * naggregates when modes drop)
  int levels = 0;        // total, INCLUDING the matrix-free level 0
  double fine_nnz_per_row = 0.0;  // the fine operator's, never stored
  std::size_t bytes = 0;          // what the algebraic path ADDS
  // Per-phase setup wall, milliseconds. Reported beside DOF-weighted work in the
  // handoff because a shared host makes wall indicative, not evidence.
  double t_incidence_ms = 0.0, t_strength_ms = 0.0, t_aggregate_ms = 0.0,
         t_tentative_ms = 0.0, t_coarse_ms = 0.0;
  bool refused = false;
  std::string refuse_reason;
  // Every level's dimension, finest (level 1) first, for the handoff's tables.
  std::vector<int> level_dims;
};

// ---------------------------------------------------------------------------
// LEVEL 1 — the algebraic prolongator, off the matrix-free element table.
//
// `active` is build_mf_hierarchy's fine map (global DOF -> kept id, or -1).
// `nnx/nny/nnz` are the FINE node-grid extents, used only to place nodes for the
// rigid-body modes (coordinates enter the modes only through their centroid-
// relative, half-diagonal-normalised values, so the grid spacing cancels and unit
// spacing is used).
//
// On success fills `prolong` — for each kept fine DOF, the (coarse column,
// weight) pairs of that row of P0, EXACTLY the form multigrid.cpp's element-local
// Galerkin already reads — plus `nc` (coarse dimension), `coarse_block` (coarse
// DOF -> its aggregate) and `bcoarse` (nc x 6 coarse near-nullspace, row-major),
// which levels 2.. are seeded from.
//
// Returns FALSE on any refusal (the coarsening control rejected level 1, the
// byte cap would be exceeded, or the system is too small to coarsen). The caller
// then builds the geometric hierarchy exactly as it always has; a refusal can
// only decline to help, never make the solver do something unsound.
// ---------------------------------------------------------------------------
bool alg_level1_prolongator(
    const MatfreeReduced& m, const std::vector<int>& active, int nnx, int nny,
    int nnz, std::vector<std::vector<std::pair<int, double>>>& prolong, int& nc,
    std::vector<int>& coarse_block, std::vector<double>& bcoarse,
    AlgCoarsenStats& st);

// ---------------------------------------------------------------------------
// LEVELS 2.. — prolongators from the ASSEMBLED level-1 operator, returned in the
// finest-first order build_hierarchy_from_prolongators (multigrid.cpp, PR 283)
// consumes: entry i maps level (2+i) -> level (1+i), so entry 0 has n1 rows.
//
// A1 arrives as raw COLUMN-compressed storage (`a1_outer` / `a1_inner` /
// `a1_val`, n1 columns). A1 is symmetric, so reading it as CSR gives the same
// matrix — the same licence MgCoarseSeam takes.
//
// An EMPTY return means "no usable chain below level 1". The caller must treat
// that as a refusal of the WHOLE algebraic hierarchy rather than shipping a
// two-level cycle whose bottom is 13k DOFs: level 1 alone is far above
// kMgCoarseDofCap and could not be factored.
// ---------------------------------------------------------------------------
std::vector<MgCoo> alg_coarse_prolongators(int n1, const int* a1_outer,
                                           const int* a1_inner,
                                           const double* a1_val,
                                           const std::vector<int>& coarse_block,
                                           int naggs,
                                           const std::vector<double>& bcoarse,
                                           AlgCoarsenStats& st);

// The LAST algebraic build's report on this thread (defined in multigrid.cpp,
// which owns the thread-local). Observation only — no solver decision reads it.
const AlgCoarsenStats& mg_algebraic_level1_stats();
void mg_reset_algebraic_level1_stats();

}  // namespace fea_detail
}  // namespace topopt
