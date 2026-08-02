// algebraic_coarsen.cpp — the implementation of the algebraic level-1 coarse
// space. See algebraic_coarsen.hpp for why it exists and for the invariant that
// governs every line below: A0 IS NEVER ASSEMBLED.
//
// The kernels are the ones PR 230 (amg_lean.hpp) and PR 283 measured, ported to
// production and generalised over BOTH production element tables (isotropic and
// cubic), so an armed lattice run coarsens by the same rule as a scalar one.

#include "algebraic_coarsen.hpp"

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <limits>

namespace topopt {
namespace fea_detail {
namespace {

using i64 = std::int64_t;

// ---------------------------------------------------------------------------
// The fine level's BOOKKEEPING. No matrix — only a node compaction and a
// node->element incidence list, which is what lets every setup quantity below be
// streamed element-locally one node row at a time.
//
// Elements are indexed 0..niso+ncub, isotropic first, exactly as
// build_mf_hierarchy's Galerkin pass indexes them, so the two agree on what
// "element e" means.
// ---------------------------------------------------------------------------
struct AlgFine {
  const MatfreeReduced* m = nullptr;
  int niso = 0, ncub = 0, nelems = 0;
  int ng = 0;       // reduced (kept) DOF count
  int nnodes = 0;   // compact node count (nodes owning >= 1 kept DOF)
  std::vector<int> dof2node;    // reduced DOF -> compact node
  std::vector<int> comp_red;    // 3*compact node + comp -> reduced DOF, or -1
  std::vector<int> node_grid;   // compact node -> grid node id
  std::vector<i64> nel_start;   // CSR over compact nodes
  std::vector<int> nel;         // incident element indices, ASCENDING
  std::vector<int> elem_cnode;  // element -> its 8 compact node ids (-1 if none)

  const int* edof(int e) const {
    return e < niso ? m->elems[static_cast<std::size_t>(e)].edof
                    : m->cub_elems[static_cast<std::size_t>(e - niso)].edof;
  }
  std::size_t bytes() const {
    return dof2node.capacity() * sizeof(int) + comp_red.capacity() * sizeof(int) +
           node_grid.capacity() * sizeof(int) +
           nel_start.capacity() * sizeof(i64) + nel.capacity() * sizeof(int) +
           elem_cnode.capacity() * sizeof(int);
  }
};

AlgFine build_alg_fine(const MatfreeReduced& m, const std::vector<int>& active) {
  AlgFine F;
  F.m = &m;
  F.ng = m.ng;
  F.niso = static_cast<int>(m.elems.size());
  F.ncub = static_cast<int>(m.cub_elems.size());
  F.nelems = F.niso + F.ncub;

  // kept_global is ascending, so DOFs of one node are contiguous: one pass
  // assigns compact node ids in ascending grid-node order.
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
  for (int gi = 0; gi < m.ng; ++gi)
    F.node_grid[static_cast<std::size_t>(
        F.dof2node[static_cast<std::size_t>(gi)])] =
        m.kept_global[static_cast<std::size_t>(gi)] / 3;

  F.comp_red.assign(static_cast<std::size_t>(F.nnodes) * 3, -1);
  for (int a = 0; a < F.nnodes; ++a) {
    const int gn = F.node_grid[static_cast<std::size_t>(a)];
    for (int c = 0; c < 3; ++c)
      F.comp_red[static_cast<std::size_t>(a) * 3 + c] =
          active[static_cast<std::size_t>(3 * gn + c)];
  }

  // grid node -> compact node (only for nodes that own a kept DOF)
  std::vector<int> cnode(static_cast<std::size_t>(m.ndof / 3), -1);
  for (int a = 0; a < F.nnodes; ++a)
    cnode[static_cast<std::size_t>(F.node_grid[static_cast<std::size_t>(a)])] = a;

  F.elem_cnode.assign(static_cast<std::size_t>(F.nelems) * 8, -1);
  F.nel_start.assign(static_cast<std::size_t>(F.nnodes) + 1, 0);
  for (int e = 0; e < F.nelems; ++e) {
    const int* ed = F.edof(e);
    for (int u = 0; u < 8; ++u) {
      const int a = cnode[static_cast<std::size_t>(ed[3 * u] / 3)];
      F.elem_cnode[static_cast<std::size_t>(e) * 8 + u] = a;
      if (a >= 0) F.nel_start[static_cast<std::size_t>(a) + 1]++;
    }
  }
  for (int a = 0; a < F.nnodes; ++a) F.nel_start[a + 1] += F.nel_start[a];
  F.nel.resize(static_cast<std::size_t>(F.nel_start[F.nnodes]));
  {
    std::vector<i64> cur(F.nel_start.begin(), F.nel_start.end() - 1);
    for (int e = 0; e < F.nelems; ++e)
      for (int u = 0; u < 8; ++u) {
        const int a = F.elem_cnode[static_cast<std::size_t>(e) * 8 + u];
        if (a >= 0)
          F.nel[static_cast<std::size_t>(cur[static_cast<std::size_t>(a)]++)] = e;
      }
  }
  return F;
}

// One assembled NODE ROW of A0, produced on demand from the element table and
// discarded immediately. `nbr` is the sorted list of neighbour compact nodes;
// `blk` holds each neighbour's 3x3 block row-major, INCLUDING components that are
// not kept (the caller masks them through comp_red).
//
// Elements are visited in ASCENDING table index and local indices ascend, so the
// floating-point summation order is fixed and the row is bit-reproducible.
struct NodeRowAccum {
  std::vector<int> mark, slot, nbr;
  std::vector<double> blk;
  int stamp = 0;
  std::vector<int> order;
  std::vector<int> nb2;
  std::vector<double> bl2;
  void resize(int nnodes) {
    mark.assign(static_cast<std::size_t>(nnodes), -1);
    slot.assign(static_cast<std::size_t>(nnodes), -1);
    stamp = 0;
  }
};

// Accumulate node `a`'s row. `self_only` restricts the work to the diagonal
// block, which is all the strength test's first pass needs.
void accumulate_node_row(const AlgFine& F, int a, NodeRowAccum& W,
                         bool self_only) {
  ++W.stamp;
  W.nbr.clear();
  W.blk.clear();
  const MatfreeReduced& m = *F.m;
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
    const bool is_cubic = e >= F.niso;
    const double f =
        is_cubic ? 1.0 : m.elems[static_cast<std::size_t>(e)].factor;
    const MfCubElem* cel =
        is_cubic ? &m.cub_elems[static_cast<std::size_t>(e - F.niso)] : nullptr;
    for (int b = 0; b < 8; ++b) {
      const int cb = cn[b];
      if (cb < 0) continue;
      if (self_only && cb != a) continue;
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
        for (int c = 0; c < 3; ++c) {
          const int rr = 3 * la + r, cc = 3 * b + c;
          // The cubic element's stiffness is the exact three-block
          // decomposition a*K_A + b*K_B + c*K_C (PR 252) — the same fuse the
          // production apply performs.
          dst[r * 3 + c] += is_cubic ? (cel->a * m.KA(rr, cc) +
                                        cel->b * m.KB(rr, cc) +
                                        cel->c * m.KC(rr, cc))
                                     : f * m.Ke(rr, cc);
        }
    }
  }
  // Emit in ascending neighbour order.
  W.order.resize(W.nbr.size());
  for (std::size_t i = 0; i < W.order.size(); ++i) W.order[i] = static_cast<int>(i);
  std::sort(W.order.begin(), W.order.end(), [&](int x, int y) {
    return W.nbr[static_cast<std::size_t>(x)] < W.nbr[static_cast<std::size_t>(y)];
  });
  W.nb2.resize(W.nbr.size());
  W.bl2.resize(W.blk.size());
  for (std::size_t i = 0; i < W.order.size(); ++i) {
    const std::size_t src = static_cast<std::size_t>(W.order[i]);
    W.nb2[i] = W.nbr[src];
    for (int q = 0; q < 9; ++q) W.bl2[i * 9 + q] = W.blk[src * 9 + q];
  }
  W.nbr.swap(W.nb2);
  W.blk.swap(W.bl2);
}

// A node-level strength graph in CSR form.
struct NodeGraph {
  int nnodes = 0;
  std::vector<i64> rowptr;
  std::vector<int> col;
  std::size_t bytes() const {
    return rowptr.capacity() * sizeof(i64) + col.capacity() * sizeof(int);
  }
};

// THE STRENGTH TEST (Vanek): b is a strong neighbour of a iff
//   ||A_ab||_F >= theta * sqrt(||A_aa||_F * ||A_bb||_F).
// Applied on the SQUARED norms (s*s >= theta^4 * d2_a * d2_b) so it stays in
// exact arithmetic — no square roots, no tolerance drift.
//
// Also returns the fine operator's true nnz/row, which the stencil-growth rule
// needs and which has no assembled parent to read it from.
NodeGraph alg_strength_graph(const AlgFine& F, double theta,
                             double* nnz_per_row_out) {
  NodeRowAccum W;
  W.resize(F.nnodes);

  // Pass 1: diagonal block Frobenius norms only.
  std::vector<double> diag2(static_cast<std::size_t>(F.nnodes), 0.0);
  for (int a = 0; a < F.nnodes; ++a) {
    accumulate_node_row(F, a, W, /*self_only=*/true);
    double s = 0.0;
    if (!W.nbr.empty()) {
      const double* blk = &W.blk[0];
      for (int r = 0; r < 3; ++r) {
        if (F.comp_red[static_cast<std::size_t>(a) * 3 + r] < 0) continue;
        for (int c = 0; c < 3; ++c) {
          if (F.comp_red[static_cast<std::size_t>(a) * 3 + c] < 0) continue;
          s += blk[r * 3 + c] * blk[r * 3 + c];
        }
      }
    }
    diag2[static_cast<std::size_t>(a)] = s;
  }

  // Pass 2: full node rows -> strong neighbours (+ the structural nnz count).
  const double th4 = theta * theta * theta * theta;
  NodeGraph g;
  g.nnodes = F.nnodes;
  g.rowptr.assign(static_cast<std::size_t>(F.nnodes) + 1, 0);
  std::vector<int> flat;
  flat.reserve(static_cast<std::size_t>(F.nnodes) * 12);
  i64 total_nnz = 0;
  for (int a = 0; a < F.nnodes; ++a) {
    accumulate_node_row(F, a, W, /*self_only=*/false);
    i64 keep = 0;
    for (std::size_t t = 0; t < W.nbr.size(); ++t) {
      const int b = W.nbr[t];
      const double* blk = &W.blk[t * 9];
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
      const bool strong = theta <= 0.0 ||
                          s * s >= th4 * diag2[static_cast<std::size_t>(a)] *
                                       diag2[static_cast<std::size_t>(b)];
      if (strong) {
        flat.push_back(b);
        ++keep;
      }
    }
    g.rowptr[a + 1] = keep;
  }
  for (int a = 0; a < F.nnodes; ++a) g.rowptr[a + 1] += g.rowptr[a];
  g.col = std::move(flat);
  if (nnz_per_row_out)
    *nnz_per_row_out =
        F.ng > 0 ? static_cast<double>(total_nnz) / static_cast<double>(F.ng) : 0.0;
  return g;
}

// ---------------------------------------------------------------------------
// THE AGGREGATION RULE, in full.
//
//   PHASE 1 — root selection. For a = 0..N-1 ASCENDING: if a is unassigned AND
//     every strong neighbour of a is unassigned, open a new aggregate holding a
//     and all its strong neighbours. (A node with no strong neighbours trivially
//     qualifies and opens a singleton.)
//   PHASE 2 — enlargement. Snapshot phase 1 first, so phase 2 never chains onto
//     an aggregate phase 2 itself grew. For a ASCENDING: an unassigned a with
//     >= 1 strong neighbour assigned IN PHASE 1 joins the aggregate of the
//     SMALLEST-INDEXED such neighbour.
//   PHASE 3 — leftovers. For a ASCENDING: a still-unassigned a opens a new
//     aggregate holding a and every still-unassigned strong neighbour of a.
//
// Ties break by smallest node index at every step; the sweep is ascending at
// every step; nothing consults a random source or a thread id. Aggregate ids are
// handed out in the order aggregates open, so the coarse numbering is a pure
// function of the graph.
// ---------------------------------------------------------------------------
int alg_aggregate(const NodeGraph& g, std::vector<int>& agg) {
  const int N = g.nnodes;
  agg.assign(static_cast<std::size_t>(N), -1);
  int naggs = 0;

  for (int a = 0; a < N; ++a) {
    if (agg[static_cast<std::size_t>(a)] != -1) continue;
    bool clean = true;
    for (i64 p = g.rowptr[a]; p < g.rowptr[a + 1]; ++p)
      if (agg[static_cast<std::size_t>(g.col[p])] != -1) {
        clean = false;
        break;
      }
    if (!clean) continue;
    const int id = naggs++;
    agg[static_cast<std::size_t>(a)] = id;
    for (i64 p = g.rowptr[a]; p < g.rowptr[a + 1]; ++p)
      agg[static_cast<std::size_t>(g.col[p])] = id;
  }

  const std::vector<int> phase1 = agg;
  for (int a = 0; a < N; ++a) {
    if (agg[static_cast<std::size_t>(a)] != -1) continue;
    int best = -1;
    for (i64 p = g.rowptr[a]; p < g.rowptr[a + 1]; ++p) {
      const int b = g.col[p];
      if (phase1[static_cast<std::size_t>(b)] == -1) continue;
      if (best == -1 || b < best) best = b;
    }
    if (best != -1)
      agg[static_cast<std::size_t>(a)] = phase1[static_cast<std::size_t>(best)];
  }

  for (int a = 0; a < N; ++a) {
    if (agg[static_cast<std::size_t>(a)] != -1) continue;
    const int id = naggs++;
    agg[static_cast<std::size_t>(a)] = id;
    for (i64 p = g.rowptr[a]; p < g.rowptr[a + 1]; ++p)
      if (agg[static_cast<std::size_t>(g.col[p])] == -1)
        agg[static_cast<std::size_t>(g.col[p])] = id;
  }
  return naggs;
}

// THE COARSENING-CONTROL RULE, in one place so it can be quoted verbatim. A
// candidate coarse level is ADMITTED iff
//   (1) coarsening ratio n_fine / n_coarse >= kAlgMinCoarseningRatio, AND
//   (2) EITHER it is small enough to be the bottom (n_coarse <= the solver's
//       direct-solve cap), OR all of
//         (2a) stencil  nnz/n                  <= kAlgMaxNnzPerRow
//         (2b) density  nnz/n^2                <= kAlgMaxLevelDensity
//         (2c) growth   (nnz/n)/(parent nnz/n) <= kAlgMaxStencilGrowth
// A rejected candidate is DISCARDED and its parent becomes the bottom level.
// `parent_nnz_per_row <= 0` means "no parent constraint".
bool admit_level(i64 n_fine, i64 n_coarse, i64 nnz, double parent_nnz_per_row,
                 std::string* why) {
  if (n_coarse <= 0) {
    if (why) *why = "empty coarse space";
    return false;
  }
  const double ratio =
      static_cast<double>(n_fine) / static_cast<double>(n_coarse);
  if (ratio < kAlgMinCoarseningRatio) {
    if (why)
      *why = "coarsening ratio " + std::to_string(ratio) + " < " +
             std::to_string(kAlgMinCoarseningRatio);
    return false;
  }
  if (n_coarse <= kAlgCoarseDofCapMirror) return true;
  const double npr = static_cast<double>(nnz) / static_cast<double>(n_coarse);
  const double density = npr / static_cast<double>(n_coarse);
  if (npr > kAlgMaxNnzPerRow) {
    if (why)
      *why = "stencil " + std::to_string(npr) + " nnz/row > " +
             std::to_string(kAlgMaxNnzPerRow);
    return false;
  }
  if (density > kAlgMaxLevelDensity) {
    if (why)
      *why = "operator density " + std::to_string(density) + " > " +
             std::to_string(kAlgMaxLevelDensity);
    return false;
  }
  if (parent_nnz_per_row > 0.0 && npr > kAlgMaxStencilGrowth * parent_nnz_per_row) {
    if (why)
      *why = "stencil growth " + std::to_string(npr / parent_nnz_per_row) +
             "x > " + std::to_string(kAlgMaxStencilGrowth) + "x";
    return false;
  }
  return true;
}

// THE TENTATIVE PROLONGATOR from an aggregation plus a near-nullspace B
// (nrow x k, row-major). Per aggregate, the rows of B belonging to it are
// orthonormalised by MODIFIED Gram-Schmidt in ascending column order; the
// orthonormal columns form that aggregate's block of T and the triangular factor
// R becomes its coarse near-nullspace rows.
//
// Columns whose norm falls below drop_tol * (pre-orthogonalisation norm) are
// DROPPED: an aggregate with fewer rows than k cannot support k independent
// modes (a single-node aggregate with 3 DOFs supports at most 3 of the 6 rigid
// modes). The retained count is that aggregate's coarse block size, so the coarse
// system has a VARIABLE block size — normal for SA elasticity, and reported.
//
// Emitted as ROWS (`rows_out[i]` = the (column, weight) pairs of row i), which is
// exactly the form multigrid.cpp's element-local Galerkin reads.
void alg_build_tentative(const std::vector<int>& agg, int naggs,
                         const std::vector<int>& dof2node, int nrow, int k,
                         const std::vector<double>& B,
                         std::vector<std::vector<std::pair<int, double>>>& rows_out,
                         std::vector<double>& bcoarse, int& ncoarse,
                         std::vector<int>& coarse_block, double drop_tol) {
  std::vector<i64> start(static_cast<std::size_t>(naggs) + 1, 0);
  for (int i = 0; i < nrow; ++i)
    start[agg[static_cast<std::size_t>(dof2node[static_cast<std::size_t>(i)])] + 1]++;
  for (int a = 0; a < naggs; ++a) start[a + 1] += start[a];
  std::vector<int> rows_of(static_cast<std::size_t>(nrow));
  {
    std::vector<i64> cur(start.begin(), start.end() - 1);
    for (int i = 0; i < nrow; ++i)
      rows_of[static_cast<std::size_t>(
          cur[agg[static_cast<std::size_t>(dof2node[static_cast<std::size_t>(i)])]]++)] = i;
  }

  std::vector<int> keep(static_cast<std::size_t>(naggs), 0);
  std::vector<std::vector<double>> Q(static_cast<std::size_t>(naggs));
  std::vector<std::vector<double>> R(static_cast<std::size_t>(naggs));
  std::vector<double> q, r;
  std::vector<int> col_map;
  for (int a = 0; a < naggs; ++a) {
    const i64 mrows = start[a + 1] - start[a];
    q.assign(static_cast<std::size_t>(mrows) * k, 0.0);
    for (i64 t = 0; t < mrows; ++t) {
      const int i = rows_of[static_cast<std::size_t>(start[a] + t)];
      for (int c = 0; c < k; ++c)
        q[static_cast<std::size_t>(t) * k + c] =
            B[static_cast<std::size_t>(i) * k + c];
    }
    r.assign(static_cast<std::size_t>(k) * k, 0.0);
    col_map.assign(static_cast<std::size_t>(k), -1);
    int kept = 0;
    for (int c = 0; c < k; ++c) {
      double n0 = 0.0;
      for (i64 t = 0; t < mrows; ++t) {
        const double v = q[static_cast<std::size_t>(t) * k + c];
        n0 += v * v;
      }
      n0 = std::sqrt(n0);
      for (int d = 0; d < kept; ++d) {
        const int cd = col_map[static_cast<std::size_t>(d)];
        double dot = 0.0;
        for (i64 t = 0; t < mrows; ++t)
          dot += q[static_cast<std::size_t>(t) * k + cd] *
                 q[static_cast<std::size_t>(t) * k + c];
        r[static_cast<std::size_t>(d) * k + c] = dot;
        for (i64 t = 0; t < mrows; ++t)
          q[static_cast<std::size_t>(t) * k + c] -=
              dot * q[static_cast<std::size_t>(t) * k + cd];
      }
      double nrm = 0.0;
      for (i64 t = 0; t < mrows; ++t) {
        const double v = q[static_cast<std::size_t>(t) * k + c];
        nrm += v * v;
      }
      nrm = std::sqrt(nrm);
      if (n0 <= 0.0 || nrm <= drop_tol * n0) {
        for (i64 t = 0; t < mrows; ++t) q[static_cast<std::size_t>(t) * k + c] = 0.0;
        continue;  // dependent column: dropped
      }
      const double inv = 1.0 / nrm;
      for (i64 t = 0; t < mrows; ++t) q[static_cast<std::size_t>(t) * k + c] *= inv;
      r[static_cast<std::size_t>(kept) * k + c] = nrm;
      col_map[static_cast<std::size_t>(kept)] = c;
      ++kept;
    }
    keep[static_cast<std::size_t>(a)] = kept;
    std::vector<double> qc(static_cast<std::size_t>(mrows) * kept, 0.0);
    for (int d = 0; d < kept; ++d)
      for (i64 t = 0; t < mrows; ++t)
        qc[static_cast<std::size_t>(t) * kept + d] =
            q[static_cast<std::size_t>(t) * k + col_map[static_cast<std::size_t>(d)]];
    Q[static_cast<std::size_t>(a)] = std::move(qc);
    R[static_cast<std::size_t>(a)] = r;
  }

  std::vector<int> cbase(static_cast<std::size_t>(naggs) + 1, 0);
  for (int a = 0; a < naggs; ++a)
    cbase[a + 1] = cbase[a] + keep[static_cast<std::size_t>(a)];
  ncoarse = cbase[naggs];

  bcoarse.assign(static_cast<std::size_t>(ncoarse) * k, 0.0);
  coarse_block.assign(static_cast<std::size_t>(ncoarse), 0);
  for (int a = 0; a < naggs; ++a)
    for (int d = 0; d < keep[static_cast<std::size_t>(a)]; ++d) {
      coarse_block[static_cast<std::size_t>(cbase[a] + d)] = a;
      for (int c = 0; c < k; ++c)
        bcoarse[static_cast<std::size_t>(cbase[a] + d) * k + c] =
            R[static_cast<std::size_t>(a)][static_cast<std::size_t>(d) * k + c];
    }

  rows_out.assign(static_cast<std::size_t>(nrow),
                  std::vector<std::pair<int, double>>());
  for (int a = 0; a < naggs; ++a) {
    const int kept = keep[static_cast<std::size_t>(a)];
    if (kept == 0) continue;
    const i64 mrows = start[a + 1] - start[a];
    for (i64 t = 0; t < mrows; ++t) {
      const int i = rows_of[static_cast<std::size_t>(start[a] + t)];
      std::vector<std::pair<int, double>>& row =
          rows_out[static_cast<std::size_t>(i)];
      row.reserve(static_cast<std::size_t>(kept));
      for (int d = 0; d < kept; ++d)
        row.emplace_back(cbase[a] + d,
                         Q[static_cast<std::size_t>(a)]
                          [static_cast<std::size_t>(t) * kept + d]);
    }
  }
}

// The 6 rigid-body modes on the fine kept DOFs: 3 translations + 3 rotations
// about the active centroid, the rotations scaled by the half-diagonal so all
// six columns are O(1).
//
// Node coordinates enter ONLY as centroid-relative values divided by that
// half-diagonal, so a uniform grid spacing cancels exactly and unit spacing is
// used — the modes are identical to ones built at the physical spacing.
std::vector<double> alg_rigid_body_modes(const AlgFine& F, int nnx, int nny) {
  const int n = F.ng;
  std::vector<double> X(static_cast<std::size_t>(n)), Y(static_cast<std::size_t>(n)),
      Z(static_cast<std::size_t>(n));
  std::vector<int> comp(static_cast<std::size_t>(n));
  double sx = 0, sy = 0, sz = 0;
  for (int i = 0; i < n; ++i) {
    const int gd = F.m->kept_global[static_cast<std::size_t>(i)];
    const int nd = gd / 3;
    const double a = nd % nnx;
    const double b = (nd / nnx) % nny;
    const double c = nd / (nnx * nny);
    X[static_cast<std::size_t>(i)] = a;
    Y[static_cast<std::size_t>(i)] = b;
    Z[static_cast<std::size_t>(i)] = c;
    comp[static_cast<std::size_t>(i)] = gd % 3;
    sx += a;
    sy += b;
    sz += c;
  }
  const double inv = n ? 1.0 / static_cast<double>(n) : 0.0;
  const double cx = sx * inv, cy = sy * inv, cz = sz * inv;
  double L = 0.0;
  for (int i = 0; i < n; ++i) {
    const double dx = X[static_cast<std::size_t>(i)] - cx;
    const double dy = Y[static_cast<std::size_t>(i)] - cy;
    const double dz = Z[static_cast<std::size_t>(i)] - cz;
    L = std::max(L, std::sqrt(dx * dx + dy * dy + dz * dz));
  }
  if (L <= 0.0) L = 1.0;
  std::vector<double> B(static_cast<std::size_t>(n) * kAlgNullspaceDim, 0.0);
  for (int i = 0; i < n; ++i) {
    const int q = comp[static_cast<std::size_t>(i)];
    const double dx = (X[static_cast<std::size_t>(i)] - cx) / L;
    const double dy = (Y[static_cast<std::size_t>(i)] - cy) / L;
    const double dz = (Z[static_cast<std::size_t>(i)] - cz) / L;
    double* r = &B[static_cast<std::size_t>(i) * kAlgNullspaceDim];
    r[q] = 1.0;                             // translations
    if (q == 0) { r[4] = dz; r[5] = -dy; }  // rot y, rot z
    if (q == 1) { r[3] = -dz; r[5] = dx; }  // rot x, rot z
    if (q == 2) { r[3] = dy; r[4] = -dx; }  // rot x, rot y
  }
  return B;
}

std::size_t prolong_bytes(
    const std::vector<std::vector<std::pair<int, double>>>& rows) {
  std::size_t b = rows.capacity() * sizeof(std::vector<std::pair<int, double>>);
  for (const auto& r : rows) b += r.capacity() * sizeof(std::pair<int, double>);
  return b;
}

// --- Assembled-level helpers for levels 2.. --------------------------------
// A minimal CSR, used only below level 1 where the operator IS assembled (those
// levels are >= 2x smaller and the geometric production hierarchy stores its
// coarse operators too).
struct Csr {
  int nrow = 0, ncol = 0;
  std::vector<i64> rowptr;
  std::vector<int> col;
  std::vector<double> val;
  i64 nnz() const { return rowptr.empty() ? 0 : rowptr.back(); }
  std::size_t bytes() const {
    return rowptr.capacity() * sizeof(i64) + col.capacity() * sizeof(int) +
           val.capacity() * sizeof(double);
  }
};

// Strength graph of an assembled level, blocked by `dof2blk` (coarse DOF -> its
// parent aggregate). Same Vanek test on the block norms, same squared-arithmetic
// form as the fine one.
NodeGraph assembled_strength_graph(const Csr& A, const std::vector<int>& dof2blk,
                                   int nblk, double theta) {
  std::vector<double> diag2(static_cast<std::size_t>(nblk), 0.0);
  // Block Frobenius norms, accumulated by walking A once per pass.
  std::vector<double> acc(static_cast<std::size_t>(nblk), 0.0);
  std::vector<int> touched;
  std::vector<int> seen(static_cast<std::size_t>(nblk), -1);
  // Pass 1: diagonal blocks.
  for (int i = 0; i < A.nrow; ++i) {
    const int bi = dof2blk[static_cast<std::size_t>(i)];
    for (i64 p = A.rowptr[i]; p < A.rowptr[i + 1]; ++p)
      if (dof2blk[static_cast<std::size_t>(A.col[p])] == bi)
        diag2[static_cast<std::size_t>(bi)] += A.val[p] * A.val[p];
  }
  const double th4 = theta * theta * theta * theta;
  NodeGraph g;
  g.nnodes = nblk;
  g.rowptr.assign(static_cast<std::size_t>(nblk) + 1, 0);
  std::vector<std::vector<int>> rows(static_cast<std::size_t>(nblk));
  // Pass 2: off-diagonal block norms, one block row at a time. Rows of a block
  // are contiguous by construction (build_tentative numbers them that way).
  int i = 0;
  while (i < A.nrow) {
    const int bi = dof2blk[static_cast<std::size_t>(i)];
    int j = i;
    while (j < A.nrow && dof2blk[static_cast<std::size_t>(j)] == bi) ++j;
    touched.clear();
    for (int rr = i; rr < j; ++rr)
      for (i64 p = A.rowptr[rr]; p < A.rowptr[rr + 1]; ++p) {
        const int bj = dof2blk[static_cast<std::size_t>(A.col[p])];
        if (seen[static_cast<std::size_t>(bj)] != bi) {
          seen[static_cast<std::size_t>(bj)] = bi;
          acc[static_cast<std::size_t>(bj)] = 0.0;
          touched.push_back(bj);
        }
        acc[static_cast<std::size_t>(bj)] += A.val[p] * A.val[p];
      }
    std::sort(touched.begin(), touched.end());
    for (int bj : touched) {
      if (bj == bi) continue;
      const double s = acc[static_cast<std::size_t>(bj)];
      if (s <= 0.0) continue;
      if (theta <= 0.0 || s * s >= th4 * diag2[static_cast<std::size_t>(bi)] *
                                       diag2[static_cast<std::size_t>(bj)])
        rows[static_cast<std::size_t>(bi)].push_back(bj);
    }
    i = j;
  }
  for (int b = 0; b < nblk; ++b)
    g.rowptr[b + 1] = g.rowptr[b] + static_cast<i64>(rows[static_cast<std::size_t>(b)].size());
  g.col.reserve(static_cast<std::size_t>(g.rowptr[nblk]));
  for (int b = 0; b < nblk; ++b)
    for (int v : rows[static_cast<std::size_t>(b)]) g.col.push_back(v);
  return g;
}

// Ac = P^T A P for an assembled level, row by row through a sparse accumulator.
Csr assembled_galerkin(const Csr& A, const Csr& P) {
  // AP = A * P
  Csr AP;
  AP.nrow = A.nrow;
  AP.ncol = P.ncol;
  AP.rowptr.assign(static_cast<std::size_t>(A.nrow) + 1, 0);
  std::vector<double> acc(static_cast<std::size_t>(P.ncol), 0.0);
  std::vector<int> touched;
  std::vector<char> hit(static_cast<std::size_t>(P.ncol), 0);
  for (int i = 0; i < A.nrow; ++i) {
    touched.clear();
    for (i64 p = A.rowptr[i]; p < A.rowptr[i + 1]; ++p) {
      const int j = A.col[p];
      const double v = A.val[p];
      if (v == 0.0) continue;
      for (i64 q = P.rowptr[j]; q < P.rowptr[j + 1]; ++q) {
        const int c = P.col[q];
        if (!hit[static_cast<std::size_t>(c)]) {
          hit[static_cast<std::size_t>(c)] = 1;
          acc[static_cast<std::size_t>(c)] = 0.0;
          touched.push_back(c);
        }
        acc[static_cast<std::size_t>(c)] += v * P.val[q];
      }
    }
    std::sort(touched.begin(), touched.end());
    for (int c : touched) {
      AP.col.push_back(c);
      AP.val.push_back(acc[static_cast<std::size_t>(c)]);
      hit[static_cast<std::size_t>(c)] = 0;
    }
    AP.rowptr[i + 1] = static_cast<i64>(AP.col.size());
  }
  // Ac = P^T * AP. For each coarse row I, sum the rows of AP weighted by
  // P[i, I], which needs P by COLUMN — so transpose P once and loop over I.
  Csr Ac;
  Ac.nrow = P.ncol;
  Ac.ncol = P.ncol;
  std::vector<std::vector<std::pair<int, double>>> build(
      static_cast<std::size_t>(P.ncol));
  {
    std::vector<std::vector<std::pair<int, double>>>& out = build;
    std::vector<int> rowtouch;
    std::vector<double> rowacc(static_cast<std::size_t>(P.ncol), 0.0);
    std::vector<char> rowhit(static_cast<std::size_t>(P.ncol), 0);
    std::vector<i64> tptr(static_cast<std::size_t>(P.ncol) + 1, 0);
    for (int i2 = 0; i2 < P.nrow; ++i2)
      for (i64 q = P.rowptr[i2]; q < P.rowptr[i2 + 1]; ++q)
        ++tptr[static_cast<std::size_t>(P.col[q]) + 1];
    for (int c = 0; c < P.ncol; ++c) tptr[c + 1] += tptr[c];
    std::vector<int> trow(static_cast<std::size_t>(tptr[P.ncol]));
    std::vector<double> tval(static_cast<std::size_t>(tptr[P.ncol]));
    {
      std::vector<i64> cur(tptr.begin(), tptr.end() - 1);
      for (int i2 = 0; i2 < P.nrow; ++i2)
        for (i64 q = P.rowptr[i2]; q < P.rowptr[i2 + 1]; ++q) {
          const std::size_t w =
              static_cast<std::size_t>(cur[static_cast<std::size_t>(P.col[q])]++);
          trow[w] = i2;
          tval[w] = P.val[q];
        }
    }
    for (int I = 0; I < P.ncol; ++I) {
      rowtouch.clear();
      for (i64 t = tptr[I]; t < tptr[I + 1]; ++t) {
        const int i2 = trow[static_cast<std::size_t>(t)];
        const double w = tval[static_cast<std::size_t>(t)];
        if (w == 0.0) continue;
        for (i64 p = AP.rowptr[i2]; p < AP.rowptr[i2 + 1]; ++p) {
          const int c = AP.col[p];
          if (!rowhit[static_cast<std::size_t>(c)]) {
            rowhit[static_cast<std::size_t>(c)] = 1;
            rowacc[static_cast<std::size_t>(c)] = 0.0;
            rowtouch.push_back(c);
          }
          rowacc[static_cast<std::size_t>(c)] += w * AP.val[p];
        }
      }
      std::sort(rowtouch.begin(), rowtouch.end());
      out[static_cast<std::size_t>(I)].reserve(rowtouch.size());
      for (int c : rowtouch) {
        out[static_cast<std::size_t>(I)].emplace_back(c,
                                                      rowacc[static_cast<std::size_t>(c)]);
        rowhit[static_cast<std::size_t>(c)] = 0;
      }
    }
  }
  Ac.rowptr.assign(static_cast<std::size_t>(Ac.nrow) + 1, 0);
  for (int I = 0; I < Ac.nrow; ++I)
    Ac.rowptr[I + 1] =
        Ac.rowptr[I] + static_cast<i64>(build[static_cast<std::size_t>(I)].size());
  Ac.col.reserve(static_cast<std::size_t>(Ac.rowptr[Ac.nrow]));
  Ac.val.reserve(static_cast<std::size_t>(Ac.rowptr[Ac.nrow]));
  for (int I = 0; I < Ac.nrow; ++I)
    for (const auto& kv : build[static_cast<std::size_t>(I)]) {
      Ac.col.push_back(kv.first);
      Ac.val.push_back(kv.second);
    }
  return Ac;
}

MgCoo rows_to_coo(const std::vector<std::vector<std::pair<int, double>>>& rows,
                  int nrow, int ncol) {
  MgCoo c;
  c.rows = nrow;
  c.cols = ncol;
  for (int i = 0; i < nrow; ++i)
    for (const auto& kv : rows[static_cast<std::size_t>(i)]) {
      c.row.push_back(i);
      c.col.push_back(kv.first);
      c.val.push_back(kv.second);
    }
  return c;
}

Csr rows_to_csr(const std::vector<std::vector<std::pair<int, double>>>& rows,
                int nrow, int ncol) {
  Csr P;
  P.nrow = nrow;
  P.ncol = ncol;
  P.rowptr.assign(static_cast<std::size_t>(nrow) + 1, 0);
  for (int i = 0; i < nrow; ++i)
    P.rowptr[i + 1] =
        P.rowptr[i] + static_cast<i64>(rows[static_cast<std::size_t>(i)].size());
  P.col.reserve(static_cast<std::size_t>(P.rowptr[nrow]));
  P.val.reserve(static_cast<std::size_t>(P.rowptr[nrow]));
  for (int i = 0; i < nrow; ++i)
    for (const auto& kv : rows[static_cast<std::size_t>(i)]) {
      P.col.push_back(kv.first);
      P.val.push_back(kv.second);
    }
  return P;
}

}  // namespace

// ---------------------------------------------------------------------------
bool alg_level1_prolongator(
    const MatfreeReduced& m, const std::vector<int>& active, int nnx, int nny,
    int /*nnz*/, std::vector<std::vector<std::pair<int, double>>>& prolong,
    int& nc, std::vector<int>& coarse_block, std::vector<double>& bcoarse,
    AlgCoarsenStats& st) {
  st = AlgCoarsenStats{};
  st.fine_dofs = m.ng;
  if (m.ng <= 0) {
    st.refused = true;
    st.refuse_reason = "empty reduced system";
    return false;
  }

  double t = mf_steady_ms();
  const AlgFine F = build_alg_fine(m, active);
  st.t_incidence_ms = mf_steady_ms() - t;
  st.fine_nodes = F.nnodes;

  t = mf_steady_ms();
  const NodeGraph g = alg_strength_graph(F, kAlgStrengthTheta, &st.fine_nnz_per_row);
  st.t_strength_ms = mf_steady_ms() - t;

  t = mf_steady_ms();
  std::vector<int> agg;
  const int naggs = alg_aggregate(g, agg);
  st.naggregates = naggs;
  st.t_aggregate_ms = mf_steady_ms() - t;

  t = mf_steady_ms();
  const std::vector<double> B = alg_rigid_body_modes(F, nnx, nny);
  std::vector<std::vector<std::pair<int, double>>> rows;
  int ncoarse = 0;
  alg_build_tentative(agg, naggs, F.dof2node, F.ng, kAlgNullspaceDim, B, rows,
                      bcoarse, ncoarse, coarse_block, kAlgQrDropTol);
  st.t_tentative_ms = mf_steady_ms() - t;
  st.coarse_dim = ncoarse;

  // The coarsening control, applied to level 1 like every other level. The
  // level-1 operator's nnz is not known until multigrid.cpp forms it, so only
  // the ratio half of the rule can be checked here; the solver's own
  // build_hierarchy_from_prolongators applies the remaining structural checks.
  std::string why;
  if (!admit_level(F.ng, ncoarse, /*nnz=*/0, /*parent=*/0.0, &why)) {
    st.refused = true;
    st.refuse_reason = "level 1 rejected by coarsening control: " + why;
    return false;
  }

  st.bytes = F.bytes() + g.bytes() + prolong_bytes(rows) +
             bcoarse.capacity() * sizeof(double) +
             coarse_block.capacity() * sizeof(int) +
             agg.capacity() * sizeof(int) + B.capacity() * sizeof(double);
  if (st.bytes > kAlgMaxCoarseBytes) {
    st.refused = true;
    st.refuse_reason = "level-1 setup " + std::to_string(st.bytes / (1024 * 1024)) +
                       " MB exceeds cap " +
                       std::to_string(kAlgMaxCoarseBytes / (1024 * 1024)) + " MB";
    return false;
  }

  prolong = std::move(rows);
  nc = ncoarse;
  st.level_dims.push_back(ncoarse);
  return true;
}

// ---------------------------------------------------------------------------
std::vector<MgCoo> alg_coarse_prolongators(int n1, const int* a1_outer,
                                           const int* a1_inner,
                                           const double* a1_val,
                                           const std::vector<int>& coarse_block,
                                           int naggs,
                                           const std::vector<double>& bcoarse,
                                           AlgCoarsenStats& st) {
  const double t0 = mf_steady_ms();
  std::vector<MgCoo> out;
  if (n1 <= 0 || a1_outer == nullptr) return out;

  // A1 arrives COLUMN-compressed; it is symmetric, so reading it as CSR is the
  // same matrix (the licence MgCoarseSeam already takes).
  Csr A;
  A.nrow = n1;
  A.ncol = n1;
  A.rowptr.assign(static_cast<std::size_t>(n1) + 1, 0);
  for (int j = 0; j < n1; ++j) A.rowptr[j + 1] = a1_outer[j + 1];
  A.col.assign(a1_inner, a1_inner + a1_outer[n1]);
  A.val.assign(a1_val, a1_val + a1_outer[n1]);

  std::vector<int> d2b = coarse_block;
  int nblk = naggs;
  std::vector<double> B = bcoarse;
  std::size_t bytes = 0;

  for (int level = 0; level < kAlgMaxLevels; ++level) {
    if (A.nrow <= kAlgCoarseDofCapMirror) break;  // small enough to be the bottom
    const double parent_npr =
        A.nrow ? static_cast<double>(A.nnz()) / A.nrow : 0.0;
    const NodeGraph gc =
        assembled_strength_graph(A, d2b, nblk, kAlgStrengthTheta);
    std::vector<int> ac;
    const int na = alg_aggregate(gc, ac);
    std::vector<std::vector<std::pair<int, double>>> rows;
    std::vector<double> Bc;
    std::vector<int> cblk;
    int ncn = 0;
    alg_build_tentative(ac, na, d2b, A.nrow, kAlgNullspaceDim, B, rows, Bc, ncn,
                        cblk, kAlgQrDropTol);
    if (ncn <= 0) break;
    const Csr P = rows_to_csr(rows, A.nrow, ncn);
    Csr Ac = assembled_galerkin(A, P);
    std::string why;
    if (!admit_level(A.nrow, ncn, Ac.nnz(), parent_npr, &why)) {
      st.refuse_reason = "level " + std::to_string(level + 2) +
                         " rejected by coarsening control: " + why;
      break;  // parent becomes the bottom; the chain so far still stands
    }
    bytes += P.bytes() + Ac.bytes();
    if (bytes > kAlgMaxCoarseBytes) {
      st.refuse_reason = "coarse levels " + std::to_string(bytes / (1024 * 1024)) +
                         " MB exceed cap";
      break;
    }
    out.push_back(rows_to_coo(rows, A.nrow, ncn));
    st.level_dims.push_back(ncn);
    A = std::move(Ac);
    d2b = std::move(cblk);
    nblk = na;
    B = std::move(Bc);
  }

  st.t_coarse_ms = mf_steady_ms() - t0;

  // The chain must reach a level the SOLVER will factor directly, or there is no
  // usable algebraic hierarchy: level 1 alone is far above kMgCoarseDofCap.
  if (out.empty() || A.nrow > kAlgCoarseDofCapMirror) {
    if (st.refuse_reason.empty())
      st.refuse_reason = "no coarse chain reached the " +
                         std::to_string(kAlgCoarseDofCapMirror) +
                         "-DOF direct-solve cap";
    st.refused = true;
    out.clear();
    // Keep level 1's own dimension; the levels below it did not survive.
    if (!st.level_dims.empty()) st.level_dims.resize(1);
    return out;
  }
  st.bytes += bytes;
  return out;
}

}  // namespace fea_detail
}  // namespace topopt
