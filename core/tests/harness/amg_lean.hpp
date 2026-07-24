// amg_lean.hpp — MEMORY-LEAN smoothed/unsmoothed-aggregation AMG whose FINE
// level is fully MATRIX-FREE. Measurement harness only (AMG Phase 1): this
// header is NOT part of the library, is NOT compiled into libtopopt.a, and
// nothing in production includes it.
//
// WHY IT EXISTS
//   Handoff 131 (AMG Phase 0) answered "does AMG contract on our pathology?"
//   with yes — 7 of 7 fixtures geometric multigrid cannot converge — but its
//   prototype ASSEMBLED the fine matrix, i.e. put back exactly the object
//   handoff 078 removed because it OOMs on design-box grids. 131 §6c measured
//   the cost: 2 071.6 MB of hierarchy against the production matrix-free
//   hierarchy's 88.9 MB at 804 864 DOF — 23.3x. 131 §7a option A named the only
//   shippable shape: build the strength graph, the aggregation and the Galerkin
//   coarse operator ELEMENT-LOCALLY, so no assembled fine A ever exists.
//
//   This header is that shape, built and measured.
//
// WHAT IS AND IS NOT ASSEMBLED
//   * Level 0 (the fine level): NOTHING is assembled. The operator is the
//     production `fea_detail::MatfreeReduced` — the same element table
//     `fea_solve_mgcg_matfree` uses — and every fine-level operation goes
//     through its element-by-element `apply_kgg_raw`:
//       - the smoother (Chebyshev or damped Jacobi: matvec + the diagonal that
//         mf_build_reduced already computes for Jacobi-CG),
//       - the residual,
//       - the CG matvec.
//     The three SETUP quantities that classically need A's rows are obtained by
//     streaming the element table through a NODE->ELEMENT incidence list, one
//     node row at a time, in O(1) extra memory per node:
//       - the node-block strength graph (`fine_strength_graph`),
//       - the exact Gershgorin bound of D^-1 A (`fine_row_abs_sums`),
//       - the product A*T needed to SMOOTH the prolongator (`fine_apply_to`).
//     None of them ever materialises a fine matrix.
//   * The coarse operator A1 = P0^T A P0 is formed by the ELEMENT-LOCAL triple
//     product `fine_galerkin` — sum over elements of Pe^T Ke Pe, exactly the
//     trick 078/090 already pull for the geometric hierarchy.
//   * Levels >= 1 ARE assembled CSR (they are >= 8x smaller and the geometric
//     production hierarchy stores its coarse operators too). They reuse the
//     tested amg_sa.hpp kernels unchanged.
//
// THE UNSMOOTHED VARIANT IS FIRST CLASS, NOT A FOOTNOTE
//   131 §6d measured that dropping the prolongator smoothing (P = T) costs
//   1.76x the cycles but 12x less setup and 2.2x less memory, and STILL carries
//   the stagnating solve. Forming T needs only the aggregation — never A's rows
//   — so it is the variant that fits a matrix-free fine level natively.
//   `LeanOptions::smooth_prolongator` therefore DEFAULTS TO FALSE here (it
//   defaults to true in amg_sa.hpp), and both are measured.
//
// COARSENING CONTROL (the Phase-0 disease this must cure or declare incurable)
//   131 §2d measured the developed-field failure mode precisely: the coarsening
//   ratio collapses down the hierarchy (10.6x -> 5.1x -> 3.1x -> 1.35x) and the
//   coarse operators fill in until a level is 100 % dense, which is what makes
//   setup explode 6.7x and memory go to 3.3 GB. `admit_level()` below states the
//   rule that bounds it, and it is applied at EVERY level including level 1.
//
// DETERMINISM
//   Same discipline as amg_sa.hpp: ascending traversal everywhere, smallest-index
//   tie-breaks, sorted column emission, fixed summation order, closed-form
//   Gershgorin scaling (no power iteration, no random start). The one threaded
//   kernel is the production `mf_apply_full`, which is documented and tested
//   deterministic across thread counts (8-colour fixed-order scatter). The probe
//   asserts bit-identity of two independent setups and two independent solves.

#pragma once

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <stdexcept>
#include <string>
#include <vector>

#include "topopt/fea.hpp"

#include "fea_matfree.hpp"

#include "amg_sa.hpp"

namespace amglean {

using amg::Csr;
using amg::i64;
using amg::RowAccum;

// ---------------------------------------------------------------------------
// Options
// ---------------------------------------------------------------------------
struct LeanOptions {
  // --- aggregation -----------------------------------------------------
  double strength_theta = 0.08;
  // DEFAULT FALSE — see the header comment. 131 §6d is the reason.
  bool smooth_prolongator = false;
  double jacobi_omega_scale = 4.0 / 3.0;
  double qr_drop_tol = 1e-10;

  // --- COARSENING CONTROL (stated rule; see admit_level) ---------------
  // A candidate coarse level is ADMITTED iff
  //   (1) coarsening ratio n_fine / n_coarse >= min_coarsening_ratio,   AND
  //   (2) EITHER it is small enough to be the bottom (n_coarse <= coarse_dof_cap,
  //       where a dense operator is cheap and gets a direct solve), OR all of
  //         (2a) stencil     nnz/n                        <= max_nnz_per_row
  //         (2b) density     nnz/n^2                      <= max_level_density
  //         (2c) growth      (nnz/n)/(parent nnz/n)       <= max_stencil_growth
  // A rejected candidate is DISCARDED and its parent becomes the bottom level.
  //
  // Phase 0 (131) had only (1), at 1.15 — which is exactly why it tolerated the
  // §2d collapse: a 1.35x ratio and a level at 3600 nnz/row on 3600 rows
  // (100 % dense). (2a) names that number directly; (2b) catches the same
  // failure scale-free; (2c) catches the fill-in ramp before it completes.
  double min_coarsening_ratio = 2.0;
  double max_nnz_per_row = 400.0;
  double max_level_density = 0.10;
  double max_stencil_growth = 8.0;
  int coarse_dof_cap = 1200;
  int max_levels = 12;

  // --- smoothers -------------------------------------------------------
  // Fine level is matrix-free, so no Gauss-Seidel is available there. Chebyshev
  // (degree >= 1) or damped Jacobi (degree 0), both driven by matvecs + D^-1.
  int fine_cheb_degree = 2;
  double fine_cheb_lo_frac = 0.125;  // smoothing interval [lo_frac*lam, 1.1*lam]
  int fine_pre = 1;                  // fine pre/post smoother applications
  int fine_post = 1;
  int pre_sweeps = 1;   // coarse-level symmetric Gauss-Seidel sweeps
  int post_sweeps = 1;
  int dense_bottom_cap = 4000;  // above this the bottom is smoothed, not solved
};

inline amg::Options sa_options(const LeanOptions& o) {
  amg::Options a;
  a.strength_theta = o.strength_theta;
  a.smooth_prolongator = o.smooth_prolongator;
  a.jacobi_omega_scale = o.jacobi_omega_scale;
  a.coarse_dof_cap = o.coarse_dof_cap;
  a.max_levels = o.max_levels;
  a.min_coarsening_ratio = o.min_coarsening_ratio;
  a.pre_sweeps = o.pre_sweeps;
  a.post_sweeps = o.post_sweeps;
  a.qr_drop_tol = o.qr_drop_tol;
  return a;
}

// THE COARSENING-CONTROL RULE, in one place so it can be quoted verbatim.
// `parent_nnz_per_row` <= 0 means "no parent constraint" (level 1 has a
// matrix-free parent whose nnz/row is the element-table stencil, supplied by the
// caller).
inline bool admit_level(const LeanOptions& o, i64 n_fine, i64 n_coarse, i64 nnz,
                        double parent_nnz_per_row, std::string* why) {
  if (n_coarse <= 0) {
    if (why) *why = "empty coarse space";
    return false;
  }
  const double ratio = static_cast<double>(n_fine) / static_cast<double>(n_coarse);
  if (ratio < o.min_coarsening_ratio) {
    if (why)
      *why = "coarsening ratio " + std::to_string(ratio) + " < " +
             std::to_string(o.min_coarsening_ratio);
    return false;
  }
  // A level small enough to BE the bottom is allowed to be dense: it gets a
  // direct dense LDL^T and costs O(n^2) doubles at n <= coarse_dof_cap.
  if (n_coarse <= o.coarse_dof_cap) return true;
  const double density =
      static_cast<double>(nnz) /
      (static_cast<double>(n_coarse) * static_cast<double>(n_coarse));
  const double npr = static_cast<double>(nnz) / static_cast<double>(n_coarse);
  if (npr > o.max_nnz_per_row) {
    if (why)
      *why = "stencil " + std::to_string(npr) + " nnz/row > " +
             std::to_string(o.max_nnz_per_row);
    return false;
  }
  if (density > o.max_level_density) {
    if (why)
      *why = "operator density " + std::to_string(density) + " > " +
             std::to_string(o.max_level_density);
    return false;
  }
  if (parent_nnz_per_row > 0.0 && npr > o.max_stencil_growth * parent_nnz_per_row) {
    if (why)
      *why = "stencil growth " + std::to_string(npr / parent_nnz_per_row) + "x > " +
             std::to_string(o.max_stencil_growth) + "x";
    return false;
  }
  return true;
}

// ---------------------------------------------------------------------------
// FineMF — the matrix-free fine level.
//
// It owns NO matrix. It owns the production reduced system (borrowed), the
// reduced<->node bookkeeping, and a node->element incidence list, which is what
// lets every setup quantity be streamed element-locally one node row at a time.
// ---------------------------------------------------------------------------
struct FineMF {
  const topopt::fea_detail::MatfreeReduced* m = nullptr;

  int ng = 0;       // reduced (kept) DOF count
  int nnodes = 0;   // compact node count
  std::vector<int> dof2node;    // reduced DOF -> compact node
  std::vector<int> comp_red;    // 3*compact node + comp -> reduced DOF, or -1
  std::vector<int> node_first;  // compact node -> its first reduced DOF
  std::vector<int> node_cnt;    // compact node -> kept component count
  std::vector<int> node_grid;   // compact node -> grid node id

  // node -> incident elements (indices into m->elems, ASCENDING)
  std::vector<i64> nel_start;
  std::vector<int> nel;
  // element -> its 8 compact node ids (-1 if that node has no kept DOF)
  std::vector<int> elem_cnode;

  std::vector<double> invdiag;  // ng, from mf_build_reduced (Jacobi diagonal)
  double lam_dinva = 0.0;       // Gershgorin bound of lambda_max(D^-1 A)

  mutable std::vector<double> s1, s2, s3;  // ng scratch, allocated once

  void apply(const double* x, double* y) const { m->apply_kgg_raw(x, y); }

  // Bytes this level costs. The element table and the reduced bookkeeping are
  // the production solver's OWN cost (mf_build_reduced builds them for the
  // geometric path too), so they are reported separately from `amg_bytes()`,
  // which is what AMG ADDS.
  std::size_t shared_bytes() const {
    return m->elems.capacity() * sizeof(topopt::fea_detail::MfElem) +
           m->kept_global.capacity() * sizeof(int) +
           m->invdiag.capacity() * sizeof(double) +
           m->up.capacity() * sizeof(double) + m->rg.capacity() * sizeof(double);
  }
  std::size_t amg_bytes() const {
    return dof2node.capacity() * sizeof(int) + comp_red.capacity() * sizeof(int) +
           node_first.capacity() * sizeof(int) + node_cnt.capacity() * sizeof(int) +
           node_grid.capacity() * sizeof(int) +
           nel_start.capacity() * sizeof(i64) + nel.capacity() * sizeof(int) +
           elem_cnode.capacity() * sizeof(int) +
           3 * static_cast<std::size_t>(ng) * sizeof(double);
  }
};

// One assembled node row of A, produced on demand from the element table.
// `nbr` is the sorted list of neighbour compact nodes; `blk` holds the 3x3
// block for each, row-major, INCLUDING components that are not kept (the caller
// masks them via comp_red).
struct NodeRowAccum {
  std::vector<int> mark;
  std::vector<int> slot;
  std::vector<int> nbr;
  std::vector<double> blk;
  int stamp = 0;

  void resize(int nnodes) {
    mark.assign(static_cast<std::size_t>(nnodes), -1);
    slot.assign(static_cast<std::size_t>(nnodes), -1);
    stamp = 0;
  }
};

// Accumulate the assembled rows of node `a`. Elements are visited in ASCENDING
// element-table index and local indices ascend, so the floating-point summation
// order is fixed and the result is bit-reproducible.
inline void accumulate_node_row(const FineMF& F, int a, NodeRowAccum& W) {
  ++W.stamp;
  W.nbr.clear();
  W.blk.clear();
  const auto& Ke = F.m->Ke;
  for (i64 t = F.nel_start[static_cast<std::size_t>(a)];
       t < F.nel_start[static_cast<std::size_t>(a) + 1]; ++t) {
    const int e = F.nel[static_cast<std::size_t>(t)];
    const int* cn = &F.elem_cnode[static_cast<std::size_t>(e) * 8];
    int la = -1;
    for (int u = 0; u < 8; ++u)
      if (cn[u] == a) {
        la = u;
        break;
      }
    if (la < 0) continue;
    const double f = F.m->elems[static_cast<std::size_t>(e)].factor;
    for (int b = 0; b < 8; ++b) {
      const int cb = cn[b];
      if (cb < 0) continue;
      int s = W.slot[static_cast<std::size_t>(cb)];
      if (W.mark[static_cast<std::size_t>(cb)] != W.stamp) {
        W.mark[static_cast<std::size_t>(cb)] = W.stamp;
        s = static_cast<int>(W.nbr.size());
        W.slot[static_cast<std::size_t>(cb)] = s;
        W.nbr.push_back(cb);
        W.blk.resize(W.blk.size() + 9, 0.0);
      }
      double* dst = &W.blk[static_cast<std::size_t>(s) * 9];
      for (int r = 0; r < 3; ++r)
        for (int c = 0; c < 3; ++c) dst[r * 3 + c] += f * Ke(3 * la + r, 3 * b + c);
    }
  }
  // Emit in ascending neighbour order: sort the slots, permute the blocks.
  std::vector<int> order(W.nbr.size());
  for (std::size_t i = 0; i < order.size(); ++i) order[i] = static_cast<int>(i);
  std::sort(order.begin(), order.end(),
            [&](int x, int y) { return W.nbr[static_cast<std::size_t>(x)] <
                                       W.nbr[static_cast<std::size_t>(y)]; });
  std::vector<int> nb2(W.nbr.size());
  std::vector<double> bl2(W.blk.size());
  for (std::size_t i = 0; i < order.size(); ++i) {
    const std::size_t src = static_cast<std::size_t>(order[i]);
    nb2[i] = W.nbr[src];
    for (int q = 0; q < 9; ++q) bl2[i * 9 + q] = W.blk[src * 9 + q];
  }
  W.nbr.swap(nb2);
  W.blk.swap(bl2);
}

// ---------------------------------------------------------------------------
// Build the fine level from the production reduced system. NOTHING is
// assembled: only bookkeeping and a node->element incidence list.
// ---------------------------------------------------------------------------
inline FineMF build_fine(const topopt::fea_detail::MatfreeReduced& m) {
  FineMF F;
  F.m = &m;
  F.ng = m.ng;
  F.invdiag = m.invdiag;

  std::vector<int> red_of(static_cast<std::size_t>(m.ndof), -1);
  for (int gi = 0; gi < m.ng; ++gi)
    red_of[static_cast<std::size_t>(m.kept_global[static_cast<std::size_t>(gi)])] = gi;

  F.dof2node.assign(static_cast<std::size_t>(m.ng), 0);
  {
    int last = -1, cnt = -1;
    for (int gi = 0; gi < m.ng; ++gi) {
      const int nd = m.kept_global[static_cast<std::size_t>(gi)] / 3;
      if (nd != last) {
        ++cnt;
        last = nd;
      }
      F.dof2node[static_cast<std::size_t>(gi)] = cnt;
    }
    F.nnodes = cnt + 1;
  }
  F.node_grid.assign(static_cast<std::size_t>(F.nnodes), 0);
  F.node_first.assign(static_cast<std::size_t>(F.nnodes), -1);
  F.node_cnt.assign(static_cast<std::size_t>(F.nnodes), 0);
  for (int gi = 0; gi < m.ng; ++gi) {
    const int a = F.dof2node[static_cast<std::size_t>(gi)];
    F.node_grid[static_cast<std::size_t>(a)] =
        m.kept_global[static_cast<std::size_t>(gi)] / 3;
    if (F.node_first[static_cast<std::size_t>(a)] < 0)
      F.node_first[static_cast<std::size_t>(a)] = gi;
    F.node_cnt[static_cast<std::size_t>(a)]++;
  }
  F.comp_red.assign(static_cast<std::size_t>(F.nnodes) * 3, -1);
  for (int a = 0; a < F.nnodes; ++a) {
    const int gn = F.node_grid[static_cast<std::size_t>(a)];
    for (int c = 0; c < 3; ++c)
      F.comp_red[static_cast<std::size_t>(a) * 3 + c] =
          red_of[static_cast<std::size_t>(3 * gn + c)];
  }

  // grid node -> compact node
  std::vector<int> cnode(static_cast<std::size_t>(m.ndof / 3), -1);
  for (int a = 0; a < F.nnodes; ++a)
    cnode[static_cast<std::size_t>(F.node_grid[static_cast<std::size_t>(a)])] = a;

  const std::size_t ne = m.elems.size();
  F.elem_cnode.assign(ne * 8, -1);
  F.nel_start.assign(static_cast<std::size_t>(F.nnodes) + 1, 0);
  for (std::size_t e = 0; e < ne; ++e)
    for (int u = 0; u < 8; ++u) {
      const int gn = m.elems[e].edof[3 * u] / 3;
      const int a = cnode[static_cast<std::size_t>(gn)];
      F.elem_cnode[e * 8 + u] = a;
      if (a >= 0) F.nel_start[static_cast<std::size_t>(a) + 1]++;
    }
  for (int a = 0; a < F.nnodes; ++a) F.nel_start[a + 1] += F.nel_start[a];
  F.nel.resize(static_cast<std::size_t>(F.nel_start[F.nnodes]));
  {
    std::vector<i64> cur(F.nel_start.begin(), F.nel_start.end() - 1);
    for (std::size_t e = 0; e < ne; ++e)
      for (int u = 0; u < 8; ++u) {
        const int a = F.elem_cnode[e * 8 + u];
        if (a >= 0)
          F.nel[static_cast<std::size_t>(cur[static_cast<std::size_t>(a)]++)] =
              static_cast<int>(e);
      }
  }

  F.s1.assign(static_cast<std::size_t>(F.ng), 0.0);
  F.s2.assign(static_cast<std::size_t>(F.ng), 0.0);
  F.s3.assign(static_cast<std::size_t>(F.ng), 0.0);
  return F;
}

// ---------------------------------------------------------------------------
// Fine-level strength graph + exact Gershgorin bound, streamed element-locally.
// Same Vanek test as amg_sa.hpp: ||A_ab||_F >= theta * sqrt(||A_aa||_F ||A_bb||_F),
// applied on the squared norms so it stays in exact arithmetic.
// Also returns the fine operator's true nnz/row (needed by the stencil-growth
// rule, which has no assembled parent to read it from).
// ---------------------------------------------------------------------------
inline amg::NodeGraph fine_strength_graph(FineMF& F, double theta,
                                          double* nnz_per_row_out) {
  NodeRowAccum W;
  W.resize(F.nnodes);

  // Pass 1: the diagonal block norms only (self block, 8 elements max).
  std::vector<double> diag2(static_cast<std::size_t>(F.nnodes), 0.0);
  {
    const auto& Ke = F.m->Ke;
    for (int a = 0; a < F.nnodes; ++a) {
      double blk[9] = {0, 0, 0, 0, 0, 0, 0, 0, 0};
      for (i64 t = F.nel_start[static_cast<std::size_t>(a)];
           t < F.nel_start[static_cast<std::size_t>(a) + 1]; ++t) {
        const int e = F.nel[static_cast<std::size_t>(t)];
        const int* cn = &F.elem_cnode[static_cast<std::size_t>(e) * 8];
        int la = -1;
        for (int u = 0; u < 8; ++u)
          if (cn[u] == a) {
            la = u;
            break;
          }
        if (la < 0) continue;
        const double f = F.m->elems[static_cast<std::size_t>(e)].factor;
        for (int r = 0; r < 3; ++r)
          for (int c = 0; c < 3; ++c)
            blk[r * 3 + c] += f * Ke(3 * la + r, 3 * la + c);
      }
      double s = 0.0;
      for (int r = 0; r < 3; ++r) {
        if (F.comp_red[static_cast<std::size_t>(a) * 3 + r] < 0) continue;
        for (int c = 0; c < 3; ++c) {
          if (F.comp_red[static_cast<std::size_t>(a) * 3 + c] < 0) continue;
          s += blk[r * 3 + c] * blk[r * 3 + c];
        }
      }
      diag2[static_cast<std::size_t>(a)] = s;
    }
  }

  // Pass 2: full node rows -> strong neighbours + exact |A| row sums.
  const double th4 = theta * theta * theta * theta;
  amg::NodeGraph g;
  g.nnodes = F.nnodes;
  g.rowptr.assign(static_cast<std::size_t>(F.nnodes) + 1, 0);
  std::vector<int> flat;
  flat.reserve(static_cast<std::size_t>(F.nnodes) * 12);
  double lam = 0.0;
  i64 total_nnz = 0;
  for (int a = 0; a < F.nnodes; ++a) {
    accumulate_node_row(F, a, W);
    i64 keep = 0;
    for (std::size_t t = 0; t < W.nbr.size(); ++t) {
      const int b = W.nbr[t];
      const double* blk = &W.blk[t * 9];
      // structural nnz of this node's kept rows
      for (int r = 0; r < 3; ++r) {
        if (F.comp_red[static_cast<std::size_t>(a) * 3 + r] < 0) continue;
        for (int c = 0; c < 3; ++c)
          if (F.comp_red[static_cast<std::size_t>(b) * 3 + c] >= 0) ++total_nnz;
      }
      if (b == a) continue;
      double s = 0.0;
      for (int r = 0; r < 3; ++r) {
        if (F.comp_red[static_cast<std::size_t>(a) * 3 + r] < 0) continue;
        for (int c = 0; c < 3; ++c) {
          if (F.comp_red[static_cast<std::size_t>(b) * 3 + c] < 0) continue;
          s += blk[r * 3 + c] * blk[r * 3 + c];
        }
      }
      if (s <= 0.0) continue;
      const bool strong =
          theta <= 0.0 ||
          s * s >= th4 * diag2[static_cast<std::size_t>(a)] *
                       diag2[static_cast<std::size_t>(b)];
      if (strong) {
        flat.push_back(b);
        ++keep;
      }
    }
    g.rowptr[a + 1] = keep;
    // Gershgorin: max over rows of (sum_j |A_ij|) / A_ii.
    for (int r = 0; r < 3; ++r) {
      const int ir = F.comp_red[static_cast<std::size_t>(a) * 3 + r];
      if (ir < 0) continue;
      double abs_sum = 0.0, dia = 0.0;
      for (std::size_t t = 0; t < W.nbr.size(); ++t) {
        const int b = W.nbr[t];
        const double* blk = &W.blk[t * 9];
        for (int c = 0; c < 3; ++c) {
          if (F.comp_red[static_cast<std::size_t>(b) * 3 + c] < 0) continue;
          abs_sum += std::fabs(blk[r * 3 + c]);
          if (b == a && c == r) dia = blk[r * 3 + c];
        }
      }
      if (dia > 0.0) lam = std::max(lam, abs_sum / dia);
    }
  }
  for (int a = 0; a < F.nnodes; ++a) g.rowptr[a + 1] += g.rowptr[a];
  g.col = std::move(flat);
  F.lam_dinva = lam > 0.0 ? lam : 1.0;
  if (nnz_per_row_out)
    *nnz_per_row_out =
        F.ng > 0 ? static_cast<double>(total_nnz) / static_cast<double>(F.ng) : 0.0;
  return g;
}

// ---------------------------------------------------------------------------
// W = A * T, streamed element-locally one node row at a time. This is the ONLY
// place a prolongator SMOOTHING needs A, and it never assembles it.
// ---------------------------------------------------------------------------
inline Csr fine_apply_to(const FineMF& F, const Csr& T) {
  Csr Wm;
  Wm.nrow = F.ng;
  Wm.ncol = T.ncol;
  Wm.rowptr.assign(static_cast<std::size_t>(F.ng) + 1, 0);
  NodeRowAccum W;
  W.resize(F.nnodes);
  RowAccum acc;
  acc.resize(T.ncol);
  // Rows are emitted in ascending reduced-DOF order; node rows are contiguous.
  for (int a = 0; a < F.nnodes; ++a) {
    accumulate_node_row(F, a, W);
    for (int r = 0; r < 3; ++r) {
      const int ir = F.comp_red[static_cast<std::size_t>(a) * 3 + r];
      if (ir < 0) continue;
      acc.begin();
      for (std::size_t t = 0; t < W.nbr.size(); ++t) {
        const int b = W.nbr[t];
        const double* blk = &W.blk[t * 9];
        for (int c = 0; c < 3; ++c) {
          const int jc = F.comp_red[static_cast<std::size_t>(b) * 3 + c];
          if (jc < 0) continue;
          const double v = blk[r * 3 + c];
          if (v == 0.0) continue;
          for (i64 q = T.rowptr[jc]; q < T.rowptr[jc + 1]; ++q)
            acc.add(T.col[q], v * T.val[q]);
        }
      }
      acc.flush(Wm.col, Wm.val);
      Wm.rowptr[ir + 1] = static_cast<i64>(Wm.col.size());
    }
  }
  return Wm;
}

// P = T - (omega * D^-1) * (A T), merged row-wise from two column-sorted rows.
inline Csr fine_smooth_prolongator(const FineMF& F, const Csr& T, double omega) {
  const Csr AT = fine_apply_to(F, T);
  Csr P;
  P.nrow = T.nrow;
  P.ncol = T.ncol;
  P.rowptr.assign(static_cast<std::size_t>(P.nrow) + 1, 0);
  for (int i = 0; i < T.nrow; ++i) {
    const double s = -omega * F.invdiag[static_cast<std::size_t>(i)];
    i64 p = T.rowptr[i], q = AT.rowptr[i];
    const i64 pe = T.rowptr[i + 1], qe = AT.rowptr[i + 1];
    while (p < pe || q < qe) {
      const int cp = p < pe ? T.col[p] : std::numeric_limits<int>::max();
      const int cq = q < qe ? AT.col[q] : std::numeric_limits<int>::max();
      double v = 0.0;
      int c = 0;
      if (cp <= cq) {
        c = cp;
        v = T.val[p++];
        if (cq == cp) v += s * AT.val[q++];
      } else {
        c = cq;
        v = s * AT.val[q++];
      }
      if (v != 0.0) {
        P.col.push_back(c);
        P.val.push_back(v);
      }
    }
    P.rowptr[i + 1] = static_cast<i64>(P.col.size());
  }
  return P;
}

// ---------------------------------------------------------------------------
// A1 = P^T A P, formed ELEMENT-LOCALLY as sum_e Pe^T Ke_e Pe — the 078/090
// trick. No assembled fine A at any point.
//
// Symbolic phase: two coarse DOFs are connected iff their aggregates are both
// touched by the P-support of a common element. Coarse DOFs of one aggregate are
// contiguous, so every row of an aggregate shares one column pattern.
// Numeric phase: elements in ASCENDING table order, local indices ascending, so
// the summation order is fixed and A1 is bit-reproducible.
// ---------------------------------------------------------------------------
inline Csr fine_galerkin(const FineMF& F, const Csr& P,
                         const std::vector<int>& coarse_agg, int naggs,
                         const std::vector<int>& cbase) {
  const int ncoarse = P.ncol;
  const std::size_t ne = F.m->elems.size();
  const auto& Ke = F.m->Ke;

  // --- element -> touched aggregates (sorted unique) -------------------
  std::vector<i64> et_start(ne + 1, 0);
  std::vector<int> et;
  {
    std::vector<int> mark(static_cast<std::size_t>(naggs), -1);
    std::vector<int> tmp;
    et.reserve(ne * 4);
    for (std::size_t e = 0; e < ne; ++e) {
      tmp.clear();
      for (int u = 0; u < 8; ++u) {
        const int a = F.elem_cnode[e * 8 + u];
        if (a < 0) continue;
        for (int c = 0; c < 3; ++c) {
          const int i = F.comp_red[static_cast<std::size_t>(a) * 3 + c];
          if (i < 0) continue;
          for (i64 q = P.rowptr[i]; q < P.rowptr[i + 1]; ++q) {
            const int gagg = coarse_agg[static_cast<std::size_t>(P.col[q])];
            if (mark[static_cast<std::size_t>(gagg)] != static_cast<int>(e)) {
              mark[static_cast<std::size_t>(gagg)] = static_cast<int>(e);
              tmp.push_back(gagg);
            }
          }
        }
      }
      std::sort(tmp.begin(), tmp.end());
      for (int v : tmp) et.push_back(v);
      et_start[e + 1] = static_cast<i64>(et.size());
    }
  }

  // --- aggregate adjacency ---------------------------------------------
  std::vector<std::vector<int>> gadj(static_cast<std::size_t>(naggs));
  for (std::size_t e = 0; e < ne; ++e) {
    const i64 lo = et_start[e], hi = et_start[e + 1];
    for (i64 x = lo; x < hi; ++x)
      for (i64 y = lo; y < hi; ++y)
        gadj[static_cast<std::size_t>(et[static_cast<std::size_t>(x)])].push_back(
            et[static_cast<std::size_t>(y)]);
  }
  std::vector<int> gpref_flat;
  std::vector<i64> gpref_start(static_cast<std::size_t>(naggs) + 1, 0);
  for (int g = 0; g < naggs; ++g) {
    auto& v = gadj[static_cast<std::size_t>(g)];
    std::sort(v.begin(), v.end());
    v.erase(std::unique(v.begin(), v.end()), v.end());
    gpref_start[g + 1] = gpref_start[g] + static_cast<i64>(v.size());
  }

  // --- CSR structure ----------------------------------------------------
  Csr A1;
  A1.nrow = ncoarse;
  A1.ncol = ncoarse;
  A1.rowptr.assign(static_cast<std::size_t>(ncoarse) + 1, 0);
  std::vector<i64> gwidth(static_cast<std::size_t>(naggs), 0);
  for (int g = 0; g < naggs; ++g) {
    i64 w = 0;
    for (int gp : gadj[static_cast<std::size_t>(g)])
      w += cbase[gp + 1] - cbase[gp];
    gwidth[static_cast<std::size_t>(g)] = w;
  }
  for (int I = 0; I < ncoarse; ++I)
    A1.rowptr[I + 1] = gwidth[static_cast<std::size_t>(coarse_agg[static_cast<std::size_t>(I)])];
  for (int I = 0; I < ncoarse; ++I) A1.rowptr[I + 1] += A1.rowptr[I];
  A1.col.resize(static_cast<std::size_t>(A1.rowptr[ncoarse]));
  A1.val.assign(static_cast<std::size_t>(A1.rowptr[ncoarse]), 0.0);
  // per-aggregate prefix offsets into a row
  gpref_flat.assign(static_cast<std::size_t>(gpref_start[naggs]), 0);
  for (int g = 0; g < naggs; ++g) {
    i64 off = 0;
    const auto& v = gadj[static_cast<std::size_t>(g)];
    for (std::size_t t = 0; t < v.size(); ++t) {
      gpref_flat[static_cast<std::size_t>(gpref_start[g]) + t] = static_cast<int>(off);
      off += cbase[v[t] + 1] - cbase[v[t]];
    }
  }
  for (int I = 0; I < ncoarse; ++I) {
    const int g = coarse_agg[static_cast<std::size_t>(I)];
    i64 w = A1.rowptr[I];
    for (int gp : gadj[static_cast<std::size_t>(g)])
      for (int J = cbase[gp]; J < cbase[gp + 1]; ++J)
        A1.col[static_cast<std::size_t>(w++)] = J;
  }

  // --- numeric phase ----------------------------------------------------
  RowAccum acc;
  acc.resize(ncoarse);
  std::vector<int> rr(24);
  for (std::size_t e = 0; e < ne; ++e) {
    const double f = F.m->elems[e].factor;
    for (int u = 0; u < 8; ++u) {
      const int a = F.elem_cnode[e * 8 + u];
      for (int c = 0; c < 3; ++c)
        rr[static_cast<std::size_t>(3 * u + c)] =
            a < 0 ? -1 : F.comp_red[static_cast<std::size_t>(a) * 3 + c];
    }
    for (int r = 0; r < 24; ++r) {
      const int ir = rr[static_cast<std::size_t>(r)];
      if (ir < 0) continue;
      if (P.rowptr[ir] == P.rowptr[ir + 1]) continue;
      // u_r = sum_c f*Ke(r,c) * P[rr[c], :]
      acc.begin();
      for (int c = 0; c < 24; ++c) {
        const int jc = rr[static_cast<std::size_t>(c)];
        if (jc < 0) continue;
        const double v = f * Ke(r, c);
        if (v == 0.0) continue;
        for (i64 q = P.rowptr[jc]; q < P.rowptr[jc + 1]; ++q)
          acc.add(P.col[q], v * P.val[q]);
      }
      std::sort(acc.touched.begin(), acc.touched.end());
      // scatter P[ir,:]^T (x) u_r into A1
      for (i64 p = P.rowptr[ir]; p < P.rowptr[ir + 1]; ++p) {
        const int I = P.col[p];
        const double pv = P.val[p];
        if (pv == 0.0) continue;
        const int g = coarse_agg[static_cast<std::size_t>(I)];
        const auto& v = gadj[static_cast<std::size_t>(g)];
        const i64 rowbase = A1.rowptr[I];
        std::size_t k = 0;
        while (k < acc.touched.size()) {
          const int J0 = acc.touched[k];
          const int gj = coarse_agg[static_cast<std::size_t>(J0)];
          const auto it = std::lower_bound(v.begin(), v.end(), gj);
          const i64 base =
              rowbase +
              gpref_flat[static_cast<std::size_t>(gpref_start[g]) +
                         static_cast<std::size_t>(it - v.begin())];
          while (k < acc.touched.size() &&
                 coarse_agg[static_cast<std::size_t>(acc.touched[k])] == gj) {
            const int J = acc.touched[k];
            A1.val[static_cast<std::size_t>(base + (J - cbase[gj]))] +=
                pv * acc.acc[static_cast<std::size_t>(J)];
            ++k;
          }
        }
      }
    }
  }
  return A1;
}

// ---------------------------------------------------------------------------
// The hierarchy: a matrix-free level 0 + an assembled sub-hierarchy from A1.
// ---------------------------------------------------------------------------
struct LeanHierarchy {
  FineMF fine;
  Csr P0;
  amg::Hierarchy coarse;  // level 0 of `coarse` IS level 1 of the hierarchy
  int naggs0 = 0;
  double fine_nnz_per_row = 0.0;  // the fine operator's nnz/row, never stored
  double setup_seconds = 0.0;
  double setup_strength_s = 0.0, setup_agg_s = 0.0, setup_prolong_s = 0.0,
         setup_galerkin_s = 0.0, setup_coarse_s = 0.0;
  std::size_t amg_bytes = 0;     // what AMG ADDS over the production solver
  std::size_t shared_bytes = 0;  // what the production solver already pays
  std::vector<std::string> level_notes;
  int levels() const { return 1 + coarse.levels(); }

  mutable std::vector<double> r, tmp, d, z;  // fine scratch
};

// Chebyshev (or damped-Jacobi at degree 0) smoothing on the matrix-free fine
// level. `x` is updated in place; only matvecs and D^-1 are used.
inline void fine_smooth(const LeanHierarchy& H, const std::vector<double>& b,
                        std::vector<double>& x, const LeanOptions& o, int reps) {
  const FineMF& F = H.fine;
  const int n = F.ng;
  const double hi = 1.1 * F.lam_dinva;
  const double lo = o.fine_cheb_lo_frac * hi;
  std::vector<double>& r = H.r;
  std::vector<double>& d = H.d;
  std::vector<double>& t = H.tmp;
  for (int rep = 0; rep < reps; ++rep) {
    if (o.fine_cheb_degree <= 0) {
      const double om = o.jacobi_omega_scale / F.lam_dinva;
      F.apply(x.data(), t.data());
      for (int i = 0; i < n; ++i)
        x[static_cast<std::size_t>(i)] +=
            om * F.invdiag[static_cast<std::size_t>(i)] *
            (b[static_cast<std::size_t>(i)] - t[static_cast<std::size_t>(i)]);
      continue;
    }
    const double theta = 0.5 * (hi + lo);
    const double delta = 0.5 * (hi - lo);
    const double sigma = theta / delta;
    double rho = 1.0 / sigma;
    F.apply(x.data(), t.data());
    for (int i = 0; i < n; ++i)
      r[static_cast<std::size_t>(i)] =
          b[static_cast<std::size_t>(i)] - t[static_cast<std::size_t>(i)];
    for (int i = 0; i < n; ++i)
      d[static_cast<std::size_t>(i)] = (1.0 / theta) *
                                       F.invdiag[static_cast<std::size_t>(i)] *
                                       r[static_cast<std::size_t>(i)];
    for (int k = 0; k < o.fine_cheb_degree; ++k) {
      for (int i = 0; i < n; ++i) x[static_cast<std::size_t>(i)] += d[static_cast<std::size_t>(i)];
      F.apply(d.data(), t.data());
      for (int i = 0; i < n; ++i) r[static_cast<std::size_t>(i)] -= t[static_cast<std::size_t>(i)];
      const double rho_new = 1.0 / (2.0 * sigma - rho);
      const double c1 = rho * rho_new, c2 = 2.0 * rho_new / delta;
      for (int i = 0; i < n; ++i)
        d[static_cast<std::size_t>(i)] =
            c1 * d[static_cast<std::size_t>(i)] +
            c2 * F.invdiag[static_cast<std::size_t>(i)] * r[static_cast<std::size_t>(i)];
      rho = rho_new;
    }
    for (int i = 0; i < n; ++i) x[static_cast<std::size_t>(i)] += d[static_cast<std::size_t>(i)];
  }
}

inline void lean_vcycle(const LeanHierarchy& H, const std::vector<double>& b,
                        std::vector<double>& x, const LeanOptions& o) {
  const FineMF& F = H.fine;
  const int n = F.ng;
  const amg::Options sa = sa_options(o);

  fine_smooth(H, b, x, o, o.fine_pre);
  F.apply(x.data(), H.tmp.data());
  for (int i = 0; i < n; ++i)
    H.r[static_cast<std::size_t>(i)] =
        b[static_cast<std::size_t>(i)] - H.tmp[static_cast<std::size_t>(i)];

  if (H.coarse.levels() > 0 && H.P0.ncol > 0) {
    const amg::Level& L1 = H.coarse.lv[0];
    H.P0.apply_transpose(H.r.data(), L1.b.data());
    std::fill(L1.x.begin(), L1.x.end(), 0.0);
    amg::vcycle(H.coarse, 0, L1.b, L1.x, sa);
    H.P0.apply(L1.x.data(), H.tmp.data());
    for (int i = 0; i < n; ++i)
      x[static_cast<std::size_t>(i)] += H.tmp[static_cast<std::size_t>(i)];
  }
  fine_smooth(H, b, x, o, o.fine_post);
}

// ---------------------------------------------------------------------------
// Setup
// ---------------------------------------------------------------------------
inline LeanHierarchy lean_setup(const topopt::fea_detail::MatfreeReduced& m,
                                const std::vector<double>& B0, int k,
                                const LeanOptions& o,
                                double (*clock_s)()) {
  LeanHierarchy H;
  const double t_all = clock_s();
  H.fine = build_fine(m);
  FineMF& F = H.fine;

  double t = clock_s();
  const amg::NodeGraph g = fine_strength_graph(F, o.strength_theta, &H.fine_nnz_per_row);
  H.setup_strength_s = clock_s() - t;

  t = clock_s();
  std::vector<int> agg;
  const int naggs = amg::aggregate(g, agg);
  H.naggs0 = naggs;
  H.setup_agg_s = clock_s() - t;

  t = clock_s();
  std::vector<double> Bc;
  std::vector<int> coarse_agg;
  int ncoarse = 0;
  Csr T = amg::build_tentative(agg, naggs, F.dof2node, F.ng, k, B0, Bc, ncoarse,
                               coarse_agg, o.qr_drop_tol);
  if (o.smooth_prolongator) {
    H.P0 = fine_smooth_prolongator(F, T, o.jacobi_omega_scale / F.lam_dinva);
  } else {
    H.P0 = std::move(T);
  }
  H.setup_prolong_s = clock_s() - t;

  // cbase: first coarse DOF of each aggregate (coarse DOFs of an aggregate are
  // contiguous by construction in build_tentative).
  std::vector<int> cbase(static_cast<std::size_t>(naggs) + 1, 0);
  {
    std::vector<int> cnt(static_cast<std::size_t>(naggs), 0);
    for (int I = 0; I < ncoarse; ++I) cnt[static_cast<std::size_t>(coarse_agg[static_cast<std::size_t>(I)])]++;
    for (int a = 0; a < naggs; ++a) cbase[a + 1] = cbase[a] + cnt[static_cast<std::size_t>(a)];
  }

  t = clock_s();
  Csr A1 = fine_galerkin(F, H.P0, coarse_agg, naggs, cbase);
  H.setup_galerkin_s = clock_s() - t;

  std::string why;
  if (!admit_level(o, F.ng, ncoarse, A1.nnz(), H.fine_nnz_per_row, &why)) {
    // Level 1 rejected: there is no hierarchy. Report it loudly; the caller
    // treats this as a build rejection, not a silent single-level V-cycle.
    H.level_notes.push_back("level 1 REJECTED by coarsening control: " + why);
    H.P0 = Csr();
    H.amg_bytes = F.amg_bytes();
    H.shared_bytes = F.shared_bytes();
    H.setup_seconds = clock_s() - t_all;
    H.r.assign(static_cast<std::size_t>(F.ng), 0.0);
    H.tmp.assign(static_cast<std::size_t>(F.ng), 0.0);
    H.d.assign(static_cast<std::size_t>(F.ng), 0.0);
    H.z.assign(static_cast<std::size_t>(F.ng), 0.0);
    return H;
  }

  // --- assembled sub-hierarchy from A1, with the same admission rule ----
  t = clock_s();
  {
    amg::Options sa = sa_options(o);
    sa.smooth_prolongator = o.smooth_prolongator;
    Csr A = std::move(A1);
    std::vector<int> d2n = coarse_agg;  // coarse DOF -> its aggregate block
    int nn = naggs;
    std::vector<double> B = Bc;
    for (int level = 0; level < o.max_levels; ++level) {
      amg::Level L;
      L.A = std::move(A);
      amg::fill_diag(L.A, L.diagpos, L.invdiag);
      L.x.assign(static_cast<std::size_t>(L.A.nrow), 0.0);
      L.b.assign(static_cast<std::size_t>(L.A.nrow), 0.0);
      L.r.assign(static_cast<std::size_t>(L.A.nrow), 0.0);
      L.tmp.assign(static_cast<std::size_t>(L.A.nrow), 0.0);
      const double parent_npr =
          L.A.nrow ? static_cast<double>(L.A.nnz()) / L.A.nrow : 0.0;

      if (L.A.nrow <= o.coarse_dof_cap || level + 1 == o.max_levels) {
        H.coarse.total_bytes += L.A.bytes();
        H.coarse.lv.push_back(std::move(L));
        break;
      }
      const amg::NodeGraph gc =
          amg::build_strength_graph(L.A, d2n, nn, o.strength_theta);
      std::vector<int> ac;
      const int na = amg::aggregate(gc, ac);
      std::vector<double> Bcc;
      std::vector<int> d2n_c;
      int nc = 0;
      Csr Tc = amg::build_tentative(ac, na, d2n, L.A.nrow, k, B, Bcc, nc, d2n_c,
                                    o.qr_drop_tol);
      Csr Pc;
      if (o.smooth_prolongator) {
        const double lam = amg::gershgorin_dinva(L.A, L.diagpos);
        Pc = amg::smooth_prolongator(L.A, L.diagpos, Tc, o.jacobi_omega_scale / lam);
      } else {
        Pc = std::move(Tc);
      }
      Csr Ptc = amg::transpose(Pc);
      Csr Ac = amg::galerkin(L.A, Pc, Ptc);
      std::string whyc;
      if (!admit_level(o, L.A.nrow, nc, Ac.nnz(), parent_npr, &whyc)) {
        H.level_notes.push_back("level " + std::to_string(level + 2) +
                                " REJECTED by coarsening control: " + whyc);
        L.naggregates = na;
        H.coarse.total_bytes += L.A.bytes();
        H.coarse.lv.push_back(std::move(L));
        break;
      }
      L.P = std::move(Pc);
      L.Pt = std::move(Ptc);
      L.naggregates = na;
      H.coarse.total_bytes += L.A.bytes() + L.P.bytes() + L.Pt.bytes();
      A = std::move(Ac);
      d2n = std::move(d2n_c);
      nn = na;
      B = std::move(Bcc);
      H.coarse.lv.push_back(std::move(L));
    }
    const amg::Level& C = H.coarse.lv.back();
    H.coarse.coarse_n = C.A.nrow;
    if (H.coarse.coarse_n > 0 && H.coarse.coarse_n <= o.dense_bottom_cap) {
      H.coarse.coarse_ldl.assign(
          static_cast<std::size_t>(H.coarse.coarse_n) * H.coarse.coarse_n, 0.0);
      for (int i = 0; i < C.A.nrow; ++i)
        for (i64 p = C.A.rowptr[i]; p < C.A.rowptr[i + 1]; ++p)
          H.coarse.coarse_ldl[static_cast<std::size_t>(i) * H.coarse.coarse_n +
                              C.A.col[p]] = C.A.val[p];
      H.coarse.coarse_dense_ok =
          amg::dense_ldlt(H.coarse.coarse_ldl, H.coarse.coarse_n);
      if (!H.coarse.coarse_dense_ok) {
        H.coarse.coarse_ldl.clear();
        H.coarse.coarse_ldl.shrink_to_fit();
      }
      H.coarse.total_bytes += H.coarse.coarse_ldl.capacity() * sizeof(double);
    } else {
      H.level_notes.push_back(
          "bottom level n=" + std::to_string(H.coarse.coarse_n) +
          " > dense cap: smoothed, not solved exactly");
    }
  }
  H.setup_coarse_s = clock_s() - t;

  H.amg_bytes = F.amg_bytes() + H.P0.bytes() + H.coarse.total_bytes;
  H.shared_bytes = F.shared_bytes();
  H.setup_seconds = clock_s() - t_all;

  H.r.assign(static_cast<std::size_t>(F.ng), 0.0);
  H.tmp.assign(static_cast<std::size_t>(F.ng), 0.0);
  H.d.assign(static_cast<std::size_t>(F.ng), 0.0);
  H.z.assign(static_cast<std::size_t>(F.ng), 0.0);
  return H;
}

// ---------------------------------------------------------------------------
// Solves — identical metrics to amg_sa.hpp so Phase-0 tables stay comparable.
// ---------------------------------------------------------------------------
inline amg::SolveStats lean_stationary(const LeanHierarchy& H,
                                       const std::vector<double>& b, double tol,
                                       int max_cycles, const LeanOptions& o) {
  const int n = H.fine.ng;
  std::vector<double> x(static_cast<std::size_t>(n), 0.0);
  std::vector<double> r(static_cast<std::size_t>(n), 0.0);
  std::vector<double> e(static_cast<std::size_t>(n), 0.0);
  std::vector<double> Ax(static_cast<std::size_t>(n), 0.0);
  auto norm = [&](const std::vector<double>& v) {
    double s = 0.0;
    for (int i = 0; i < n; ++i)
      s += v[static_cast<std::size_t>(i)] * v[static_cast<std::size_t>(i)];
    return std::sqrt(s);
  };
  amg::SolveStats st;
  const double b0 = norm(b);
  if (b0 == 0.0) {
    st.converged = true;
    st.history.push_back(0.0);
    return st;
  }
  st.history.push_back(1.0);
  for (int kk = 0; kk < max_cycles; ++kk) {
    H.fine.apply(x.data(), Ax.data());
    for (int i = 0; i < n; ++i)
      r[static_cast<std::size_t>(i)] =
          b[static_cast<std::size_t>(i)] - Ax[static_cast<std::size_t>(i)];
    std::fill(e.begin(), e.end(), 0.0);
    lean_vcycle(H, r, e, o);
    for (int i = 0; i < n; ++i) x[static_cast<std::size_t>(i)] += e[static_cast<std::size_t>(i)];
    H.fine.apply(x.data(), Ax.data());
    for (int i = 0; i < n; ++i)
      r[static_cast<std::size_t>(i)] =
          b[static_cast<std::size_t>(i)] - Ax[static_cast<std::size_t>(i)];
    const double rel = norm(r) / b0;
    st.history.push_back(rel);
    st.cycles = kk + 1;
    st.final_rel = rel;
    if (!std::isfinite(rel) || rel > 1e12) break;
    if (rel <= tol) {
      st.converged = true;
      break;
    }
  }
  st.solution = x;
  return st;
}

inline amg::SolveStats lean_pcg(const LeanHierarchy& H,
                                const std::vector<double>& b, double tol,
                                int max_iters, const LeanOptions& o) {
  const int n = H.fine.ng;
  std::vector<double> x(static_cast<std::size_t>(n), 0.0);
  std::vector<double> r = b;
  std::vector<double> z(static_cast<std::size_t>(n), 0.0);
  std::vector<double> p(static_cast<std::size_t>(n), 0.0);
  std::vector<double> Ap(static_cast<std::size_t>(n), 0.0);
  auto dot = [&](const std::vector<double>& a, const std::vector<double>& c) {
    double s = 0.0;
    for (int i = 0; i < n; ++i)
      s += a[static_cast<std::size_t>(i)] * c[static_cast<std::size_t>(i)];
    return s;
  };
  amg::SolveStats st;
  const double b2 = dot(b, b);
  if (b2 == 0.0) {
    st.converged = true;
    st.history.push_back(0.0);
    st.solution = x;
    return st;
  }
  const double bn = std::sqrt(b2);
  st.history.push_back(1.0);
  lean_vcycle(H, r, z, o);
  p = z;
  double rz = dot(r, z);
  for (int kk = 0; kk < max_iters; ++kk) {
    H.fine.apply(p.data(), Ap.data());
    const double pAp = dot(p, Ap);
    if (!(pAp > 0.0) || !std::isfinite(pAp)) break;
    const double alpha = rz / pAp;
    for (int i = 0; i < n; ++i) {
      x[static_cast<std::size_t>(i)] += alpha * p[static_cast<std::size_t>(i)];
      r[static_cast<std::size_t>(i)] -= alpha * Ap[static_cast<std::size_t>(i)];
    }
    const double rel = std::sqrt(dot(r, r)) / bn;
    st.history.push_back(rel);
    st.cycles = kk + 1;
    st.final_rel = rel;
    if (rel <= tol) {
      st.converged = true;
      break;
    }
    std::fill(z.begin(), z.end(), 0.0);
    lean_vcycle(H, r, z, o);
    const double rz_new = dot(r, z);
    const double beta = rz_new / rz;
    rz = rz_new;
    for (int i = 0; i < n; ++i)
      p[static_cast<std::size_t>(i)] =
          z[static_cast<std::size_t>(i)] + beta * p[static_cast<std::size_t>(i)];
  }
  st.solution = x;
  return st;
}

}  // namespace amglean
