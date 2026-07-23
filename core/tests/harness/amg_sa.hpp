// amg_sa.hpp — standalone smoothed-aggregation AMG prototype (handoff 131,
// Phase 0 feasibility). MEASUREMENT HARNESS ONLY — this header is NOT part of
// the library, is NOT compiled into libtopopt.a, and nothing in production
// includes it. It exists so the ONE Phase-0 question can be answered with
// numbers: does an algebraic (operator-following) coarsening contract on the
// pathology geometric multigrid stagnates on (handoff 125 §1b)?
//
// SCOPE / NON-GOALS
//   * In-house, dependency-free: standard library only. No Eigen, no hypre, no
//     ML/AMGX. (The library's public headers are Eigen-free per ARCHITECTURE §4;
//     this stays in that spirit.)
//   * Not tuned for speed. Straightforward CSR kernels, single-threaded.
//     Iteration counts and contraction factors are the deliverable; wall-clock
//     is reported honestly as a PROTOTYPE cost, never as a production estimate.
//
// DETERMINISM BY CONSTRUCTION (the task's hard requirement)
//   Every stage below is a fixed-order sequential loop over ascending indices:
//     * no threads, no atomics, no parallel reductions;
//     * no randomness anywhere — in particular the spectral radius that scales
//       the prolongator smoother is a closed-form GERSHGORIN bound, not a power
//       iteration from a random start;
//     * aggregation traverses nodes in ascending node index and breaks every
//       tie by smallest index (the rule is spelled out at `aggregate()`);
//     * every sparse accumulation emits its columns sorted ascending, and every
//       floating-point sum is formed in a fixed term order, so repeated runs are
//       BIT-identical, not merely "identical to tolerance".
//   `amg_probe.cpp` asserts this: it rebuilds the hierarchy and re-runs the
//   solve, then memcmp's the residual histories.
//
// THE METHOD (Vanek/Mandel/Brezina smoothed aggregation, elasticity flavour)
//   1. Node-level strength graph from the block norms of A (density-aware: a
//      near-void coupling is weak by construction, so aggregates follow the
//      OPERATOR, never the grid — the whole reason to try AMG here).
//   2. Greedy 3-phase aggregation on that graph (deterministic; see below).
//   3. Tentative prolongator T: the near-nullspace B (6 rigid-body modes for 3D
//      elasticity) restricted to each aggregate and orthonormalised by modified
//      Gram-Schmidt; the R factor becomes the coarse near-nullspace. This is the
//      structural difference from geometric MG: RIGID ROTATIONS ARE CARRIED
//      EXACTLY to the coarse level, so the low-energy bending modes of a thin
//      ligament stay representable there. Trilinear geometric prolongation
//      cannot do that once the ligament is thinner than a coarse cell (125 §1b).
//   4. Prolongator smoothing P = (I - w D^-1 A) T, w = 4/(3 lambda_max),
//      lambda_max = Gershgorin bound of D^-1 A.
//   5. Galerkin coarse operator A_c = P^T A P.
//   6. V-cycle, symmetric Gauss-Seidel smoothing, dense LDL^T at the coarsest.

#pragma once

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <stdexcept>
#include <string>
#include <utility>
#include <vector>

namespace amg {

using i64 = std::int64_t;

// ---------------------------------------------------------------------------
// CSR matrix. Columns within a row are ALWAYS sorted ascending (every builder
// below maintains that), which is what makes the kernels' summation order — and
// therefore the floating-point result — reproducible.
// ---------------------------------------------------------------------------
struct Csr {
  int nrow = 0;
  int ncol = 0;
  std::vector<i64> rowptr;  // nrow + 1
  std::vector<int> col;
  std::vector<double> val;

  i64 nnz() const { return rowptr.empty() ? 0 : rowptr.back(); }
  std::size_t bytes() const {
    return col.capacity() * sizeof(int) + val.capacity() * sizeof(double) +
           rowptr.capacity() * sizeof(i64);
  }

  void apply(const double* x, double* y) const {
    for (int i = 0; i < nrow; ++i) {
      double s = 0.0;
      for (i64 p = rowptr[i]; p < rowptr[i + 1]; ++p) s += val[p] * x[col[p]];
      y[i] = s;
    }
  }
  // y = A^T x (restriction with P, without materialising P^T).
  void apply_transpose(const double* x, double* y) const {
    for (int j = 0; j < ncol; ++j) y[j] = 0.0;
    for (int i = 0; i < nrow; ++i) {
      const double xi = x[i];
      if (xi == 0.0) continue;
      for (i64 p = rowptr[i]; p < rowptr[i + 1]; ++p) y[col[p]] += val[p] * xi;
    }
  }
};

inline Csr transpose(const Csr& A) {
  Csr T;
  T.nrow = A.ncol;
  T.ncol = A.nrow;
  T.rowptr.assign(static_cast<std::size_t>(T.nrow) + 1, 0);
  for (i64 p = 0; p < A.nnz(); ++p) T.rowptr[A.col[p] + 1]++;
  for (int i = 0; i < T.nrow; ++i) T.rowptr[i + 1] += T.rowptr[i];
  T.col.resize(static_cast<std::size_t>(A.nnz()));
  T.val.resize(static_cast<std::size_t>(A.nnz()));
  std::vector<i64> cursor(T.rowptr.begin(), T.rowptr.end() - 1);
  // Ascending source row => each transposed row's entries emerge sorted by
  // source row index, i.e. sorted columns. Deterministic without a sort.
  for (int i = 0; i < A.nrow; ++i)
    for (i64 p = A.rowptr[i]; p < A.rowptr[i + 1]; ++p) {
      const i64 d = cursor[A.col[p]]++;
      T.col[static_cast<std::size_t>(d)] = i;
      T.val[static_cast<std::size_t>(d)] = A.val[p];
    }
  return T;
}

// ---------------------------------------------------------------------------
// Sparse row accumulator: scatter into a dense workspace, remember the touched
// columns, emit them SORTED. The sort makes the emitted column order
// independent of scatter order; the values are summed in the (fixed, ascending
// source index) scatter order.
// ---------------------------------------------------------------------------
struct RowAccum {
  std::vector<double> acc;
  std::vector<int> mark;
  std::vector<int> touched;
  int stamp = 0;

  void resize(int n) {
    acc.assign(static_cast<std::size_t>(n), 0.0);
    mark.assign(static_cast<std::size_t>(n), -1);
    touched.clear();
    stamp = 0;
  }
  void begin() {
    ++stamp;
    touched.clear();
  }
  void add(int j, double v) {
    if (mark[static_cast<std::size_t>(j)] != stamp) {
      mark[static_cast<std::size_t>(j)] = stamp;
      acc[static_cast<std::size_t>(j)] = v;
      touched.push_back(j);
    } else {
      acc[static_cast<std::size_t>(j)] += v;
    }
  }
  // Append the row to (col,val) sorted ascending. Exact zeros are dropped; no
  // magnitude filter is applied — dropping small entries would make the
  // Galerkin operator inexact and the measurement dishonest.
  void flush(std::vector<int>& out_col, std::vector<double>& out_val) {
    std::sort(touched.begin(), touched.end());
    for (int j : touched) {
      const double v = acc[static_cast<std::size_t>(j)];
      if (v == 0.0) continue;
      out_col.push_back(j);
      out_val.push_back(v);
    }
  }
};

// ---------------------------------------------------------------------------
// Options
// ---------------------------------------------------------------------------
struct Options {
  double strength_theta = 0.08;  // Vanek's classical elasticity default
  bool smooth_prolongator = true;
  double jacobi_omega_scale = 4.0 / 3.0;  // w = scale / lambda_max
  int coarse_dof_cap = 1200;              // stop coarsening below this
  int max_levels = 12;
  double min_coarsening_ratio = 1.15;  // stop if a level barely shrinks
  int pre_sweeps = 1;                  // symmetric GS sweeps (fwd+bwd each)
  int post_sweeps = 1;
  double qr_drop_tol = 1e-10;  // relative column-norm floor in the aggregate QR
};

// ---------------------------------------------------------------------------
// One level of the hierarchy.
// ---------------------------------------------------------------------------
struct Level {
  Csr A;
  Csr P;   // n_this x n_next
  Csr Pt;  // n_next x n_this
  std::vector<double> invdiag;
  std::vector<i64> diagpos;
  int naggregates = 0;
  // Work vectors, sized at setup and reused, so a solve allocates nothing.
  mutable std::vector<double> x, b, r, tmp;
};

struct Hierarchy {
  std::vector<Level> lv;
  std::vector<double> coarse_ldl;  // dense n x n, row-major, in-place LDL^T
  int coarse_n = 0;
  bool coarse_dense_ok = false;
  double setup_seconds = 0.0;
  std::size_t total_bytes = 0;
  int levels() const { return static_cast<int>(lv.size()); }
};

// ---------------------------------------------------------------------------
// Node-level strength graph.
//
// The DOFs of a 3D elasticity system come in per-node blocks (<= 3 kept
// components; a Dirichlet-fixed component is simply absent). The strength of
// the coupling between nodes a and b is the Frobenius norm of the block A[a][b]
// and the classical Vanek test is
//     ||A_ab||_F >= theta * sqrt( ||A_aa||_F * ||A_bb||_F ).
// This is the DENSITY-AWARE part: in a SIMP field the coupling through a
// near-void element is smaller than the solid couplings by the modulus ratio, so
// it fails the test and the aggregate stops at the material boundary. No grid
// arithmetic is consulted anywhere.
//
// Stored strengths are the SQUARED Frobenius norms, so the test is applied as
//     s_ab^2 >= theta^4 * s_aa * s_bb        (all quantities >= 0)
// which keeps it in exact arithmetic on the accumulated squares.
// ---------------------------------------------------------------------------
struct NodeGraph {
  int nnodes = 0;
  std::vector<i64> rowptr;  // nnodes+1
  std::vector<int> col;     // strong neighbours, sorted, self excluded
};

inline NodeGraph build_strength_graph(const Csr& A,
                                      const std::vector<int>& dof2node,
                                      int nnodes, double theta) {
  // Bucket rows by node (one contiguous pass per node afterwards).
  std::vector<i64> node_rowstart(static_cast<std::size_t>(nnodes) + 1, 0);
  for (int i = 0; i < A.nrow; ++i) node_rowstart[dof2node[static_cast<std::size_t>(i)] + 1]++;
  for (int a = 0; a < nnodes; ++a) node_rowstart[a + 1] += node_rowstart[a];
  std::vector<int> node_rows(static_cast<std::size_t>(A.nrow));
  {
    std::vector<i64> cur(node_rowstart.begin(), node_rowstart.end() - 1);
    for (int i = 0; i < A.nrow; ++i)
      node_rows[static_cast<std::size_t>(cur[dof2node[static_cast<std::size_t>(i)]]++)] = i;
  }

  std::vector<double> diag2(static_cast<std::size_t>(nnodes), 0.0);
  std::vector<std::vector<std::pair<int, double>>> rows(
      static_cast<std::size_t>(nnodes));
  {
    RowAccum acc;
    acc.resize(nnodes);
    for (int a = 0; a < nnodes; ++a) {
      acc.begin();
      for (i64 t = node_rowstart[a]; t < node_rowstart[a + 1]; ++t) {
        const int i = node_rows[static_cast<std::size_t>(t)];
        for (i64 p = A.rowptr[i]; p < A.rowptr[i + 1]; ++p)
          acc.add(dof2node[static_cast<std::size_t>(A.col[p])], A.val[p] * A.val[p]);
      }
      std::sort(acc.touched.begin(), acc.touched.end());
      auto& row = rows[static_cast<std::size_t>(a)];
      row.reserve(acc.touched.size());
      for (int b : acc.touched) {
        const double s = acc.acc[static_cast<std::size_t>(b)];
        if (b == a)
          diag2[static_cast<std::size_t>(a)] = s;
        else if (s > 0.0)
          row.emplace_back(b, s);
      }
    }
  }

  const double th4 = theta * theta * theta * theta;
  auto strong = [&](int a, const std::pair<int, double>& e) {
    if (theta <= 0.0) return true;
    const double rhs = th4 * diag2[static_cast<std::size_t>(a)] *
                       diag2[static_cast<std::size_t>(e.first)];
    return e.second * e.second >= rhs;
  };

  NodeGraph g;
  g.nnodes = nnodes;
  g.rowptr.assign(static_cast<std::size_t>(nnodes) + 1, 0);
  for (int a = 0; a < nnodes; ++a) {
    i64 keep = 0;
    for (const auto& e : rows[static_cast<std::size_t>(a)])
      if (strong(a, e)) ++keep;
    g.rowptr[a + 1] = keep;
  }
  for (int a = 0; a < nnodes; ++a) g.rowptr[a + 1] += g.rowptr[a];
  g.col.resize(static_cast<std::size_t>(g.rowptr[nnodes]));
  i64 w = 0;
  for (int a = 0; a < nnodes; ++a)
    for (const auto& e : rows[static_cast<std::size_t>(a)])
      if (strong(a, e)) g.col[static_cast<std::size_t>(w++)] = e.first;
  return g;
}

// ---------------------------------------------------------------------------
// THE AGGREGATION RULE (spelled out in full, as the task requires).
//
// Input: the strength graph G. It is symmetric by construction — ||A_ab||_F ==
// ||A_ba||_F for symmetric A, and the threshold is symmetric in (a,b).
// Output: agg[a] in [0, naggs) for every node a; every node ends up assigned.
//
//   PHASE 1 — root selection.
//     for a = 0 .. N-1 (ASCENDING):
//       if a is unassigned AND every strong neighbour of a is unassigned:
//         open a new aggregate; assign a and all its strong neighbours to it.
//     (A node with no strong neighbours trivially qualifies and opens a
//      singleton aggregate.)
//
//   PHASE 2 — enlargement.
//     Snapshot the phase-1 assignment first, so phase 2 never chains onto an
//     aggregate that phase 2 itself grew.
//     for a = 0 .. N-1 (ASCENDING):
//       if a is unassigned and has >= 1 strong neighbour assigned IN PHASE 1:
//         join the aggregate of the SMALLEST-INDEXED such neighbour.
//
//   PHASE 3 — leftovers.
//     for a = 0 .. N-1 (ASCENDING):
//       if a is still unassigned:
//         open a new aggregate holding a and every still-unassigned strong
//         neighbour of a.
//
// Ties break by smallest node index at every step; the sweep is ascending at
// every step; nothing consults a random source or a thread id. Aggregate ids are
// handed out in the order aggregates open, so the coarse numbering is a pure
// function of the graph.
// ---------------------------------------------------------------------------
inline int aggregate(const NodeGraph& g, std::vector<int>& agg) {
  const int N = g.nnodes;
  agg.assign(static_cast<std::size_t>(N), -1);
  int naggs = 0;

  for (int a = 0; a < N; ++a) {  // Phase 1
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

  const std::vector<int> phase1 = agg;  // Phase 2
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

  for (int a = 0; a < N; ++a) {  // Phase 3
    if (agg[static_cast<std::size_t>(a)] != -1) continue;
    const int id = naggs++;
    agg[static_cast<std::size_t>(a)] = id;
    for (i64 p = g.rowptr[a]; p < g.rowptr[a + 1]; ++p)
      if (agg[static_cast<std::size_t>(g.col[p])] == -1)
        agg[static_cast<std::size_t>(g.col[p])] = id;
  }
  return naggs;
}

// ---------------------------------------------------------------------------
// Tentative prolongator from the aggregation + near-nullspace B (nrow x k, row
// major). Per aggregate, the rows of B belonging to it are orthonormalised by
// MODIFIED Gram-Schmidt in ascending column order; the orthonormal columns form
// the aggregate's block of T and the triangular factor R becomes that
// aggregate's coarse near-nullspace rows.
//
// Columns whose norm falls below qr_drop_tol * (pre-orthogonalisation norm) are
// DROPPED: an aggregate with fewer rows than k cannot support k independent
// modes (a single-node aggregate with 3 DOFs supports at most 3 of the 6 rigid
// modes). The retained count is that aggregate's coarse block size, so the
// coarse system has a VARIABLE block size — normal for SA elasticity, and
// reported by the probe.
// ---------------------------------------------------------------------------
inline Csr build_tentative(const std::vector<int>& agg, int naggs,
                           const std::vector<int>& dof2node, int nrow, int k,
                           const std::vector<double>& B,
                           std::vector<double>& Bcoarse, int& ncoarse,
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
    const i64 m = start[a + 1] - start[a];
    q.assign(static_cast<std::size_t>(m) * k, 0.0);
    for (i64 t = 0; t < m; ++t) {
      const int i = rows_of[static_cast<std::size_t>(start[a] + t)];
      for (int c = 0; c < k; ++c)
        q[static_cast<std::size_t>(t) * k + c] = B[static_cast<std::size_t>(i) * k + c];
    }
    r.assign(static_cast<std::size_t>(k) * k, 0.0);
    col_map.assign(static_cast<std::size_t>(k), -1);
    int kept = 0;
    for (int c = 0; c < k; ++c) {
      double n0 = 0.0;
      for (i64 t = 0; t < m; ++t) {
        const double v = q[static_cast<std::size_t>(t) * k + c];
        n0 += v * v;
      }
      n0 = std::sqrt(n0);
      for (int d = 0; d < kept; ++d) {
        const int cd = col_map[static_cast<std::size_t>(d)];
        double dot = 0.0;
        for (i64 t = 0; t < m; ++t)
          dot += q[static_cast<std::size_t>(t) * k + cd] *
                 q[static_cast<std::size_t>(t) * k + c];
        r[static_cast<std::size_t>(d) * k + c] = dot;
        for (i64 t = 0; t < m; ++t)
          q[static_cast<std::size_t>(t) * k + c] -=
              dot * q[static_cast<std::size_t>(t) * k + cd];
      }
      double nrm = 0.0;
      for (i64 t = 0; t < m; ++t) {
        const double v = q[static_cast<std::size_t>(t) * k + c];
        nrm += v * v;
      }
      nrm = std::sqrt(nrm);
      if (n0 <= 0.0 || nrm <= drop_tol * n0) {
        for (i64 t = 0; t < m; ++t) q[static_cast<std::size_t>(t) * k + c] = 0.0;
        continue;  // dependent column: dropped
      }
      const double inv = 1.0 / nrm;
      for (i64 t = 0; t < m; ++t) q[static_cast<std::size_t>(t) * k + c] *= inv;
      r[static_cast<std::size_t>(kept) * k + c] = nrm;
      col_map[static_cast<std::size_t>(kept)] = c;
      ++kept;
    }
    keep[static_cast<std::size_t>(a)] = kept;
    std::vector<double> qc(static_cast<std::size_t>(m) * kept, 0.0);
    for (int d = 0; d < kept; ++d)
      for (i64 t = 0; t < m; ++t)
        qc[static_cast<std::size_t>(t) * kept + d] =
            q[static_cast<std::size_t>(t) * k + col_map[static_cast<std::size_t>(d)]];
    Q[static_cast<std::size_t>(a)] = std::move(qc);
    R[static_cast<std::size_t>(a)] = r;
  }

  std::vector<int> cbase(static_cast<std::size_t>(naggs) + 1, 0);
  for (int a = 0; a < naggs; ++a)
    cbase[a + 1] = cbase[a] + keep[static_cast<std::size_t>(a)];
  ncoarse = cbase[naggs];

  Bcoarse.assign(static_cast<std::size_t>(ncoarse) * k, 0.0);
  coarse_block.assign(static_cast<std::size_t>(ncoarse), 0);
  for (int a = 0; a < naggs; ++a)
    for (int d = 0; d < keep[static_cast<std::size_t>(a)]; ++d) {
      coarse_block[static_cast<std::size_t>(cbase[a] + d)] = a;
      for (int c = 0; c < k; ++c)
        Bcoarse[static_cast<std::size_t>(cbase[a] + d) * k + c] =
            R[static_cast<std::size_t>(a)][static_cast<std::size_t>(d) * k + c];
    }

  Csr T;
  T.nrow = nrow;
  T.ncol = ncoarse;
  T.rowptr.assign(static_cast<std::size_t>(nrow) + 1, 0);
  for (int i = 0; i < nrow; ++i)
    T.rowptr[i + 1] =
        keep[static_cast<std::size_t>(agg[static_cast<std::size_t>(dof2node[static_cast<std::size_t>(i)])])];
  for (int i = 0; i < nrow; ++i) T.rowptr[i + 1] += T.rowptr[i];
  T.col.resize(static_cast<std::size_t>(T.rowptr[nrow]));
  T.val.resize(static_cast<std::size_t>(T.rowptr[nrow]));
  for (int a = 0; a < naggs; ++a) {
    const int kept = keep[static_cast<std::size_t>(a)];
    const i64 m = start[a + 1] - start[a];
    for (i64 t = 0; t < m; ++t) {
      const int i = rows_of[static_cast<std::size_t>(start[a] + t)];
      i64 wpos = T.rowptr[i];
      for (int d = 0; d < kept; ++d) {
        T.col[static_cast<std::size_t>(wpos)] = cbase[a] + d;
        T.val[static_cast<std::size_t>(wpos)] =
            Q[static_cast<std::size_t>(a)][static_cast<std::size_t>(t) * kept + d];
        ++wpos;
      }
    }
  }
  return T;
}

// ---------------------------------------------------------------------------
// Prolongator smoothing: P = (I - w D^-1 A) T with
//     lambda_max(D^-1 A) <= max_i ( sum_j |A_ij| ) / A_ii     (Gershgorin)
// so w = jacobi_omega_scale / lambda_max is closed-form — no power iteration,
// hence no random start vector, hence deterministic.
// ---------------------------------------------------------------------------
inline double gershgorin_dinva(const Csr& A, const std::vector<i64>& diagpos) {
  double lam = 0.0;
  for (int i = 0; i < A.nrow; ++i) {
    double s = 0.0;
    for (i64 p = A.rowptr[i]; p < A.rowptr[i + 1]; ++p) s += std::fabs(A.val[p]);
    const double d = A.val[diagpos[static_cast<std::size_t>(i)]];
    if (d > 0.0) lam = std::max(lam, s / d);
  }
  return lam > 0.0 ? lam : 1.0;
}

inline Csr smooth_prolongator(const Csr& A, const std::vector<i64>& diagpos,
                              const Csr& T, double omega) {
  Csr P;
  P.nrow = T.nrow;
  P.ncol = T.ncol;
  P.rowptr.assign(static_cast<std::size_t>(P.nrow) + 1, 0);
  RowAccum acc;
  acc.resize(T.ncol);
  for (int i = 0; i < A.nrow; ++i) {
    acc.begin();
    for (i64 q = T.rowptr[i]; q < T.rowptr[i + 1]; ++q) acc.add(T.col[q], T.val[q]);
    const double s = -omega / A.val[diagpos[static_cast<std::size_t>(i)]];
    for (i64 p = A.rowptr[i]; p < A.rowptr[i + 1]; ++p) {
      const int j = A.col[p];
      const double wj = s * A.val[p];
      for (i64 q = T.rowptr[j]; q < T.rowptr[j + 1]; ++q)
        acc.add(T.col[q], wj * T.val[q]);
    }
    acc.flush(P.col, P.val);
    P.rowptr[i + 1] = static_cast<i64>(P.col.size());
  }
  return P;
}

// ---------------------------------------------------------------------------
// Galerkin coarse operator A_c = P^T A P, in two deterministic stages:
//   AP  = A * P      (row i of AP from row i of A and the P rows it touches)
//   A_c = P^T * AP   (row I of A_c from row I of P^T and the AP rows it touches)
// Sum order is fixed (ascending source index at both stages), so A_c is
// bit-reproducible.
// ---------------------------------------------------------------------------
inline Csr galerkin(const Csr& A, const Csr& P, const Csr& Pt) {
  Csr AP;
  AP.nrow = A.nrow;
  AP.ncol = P.ncol;
  AP.rowptr.assign(static_cast<std::size_t>(AP.nrow) + 1, 0);
  {
    RowAccum acc;
    acc.resize(P.ncol);
    for (int i = 0; i < A.nrow; ++i) {
      acc.begin();
      for (i64 p = A.rowptr[i]; p < A.rowptr[i + 1]; ++p) {
        const int j = A.col[p];
        const double a = A.val[p];
        for (i64 q = P.rowptr[j]; q < P.rowptr[j + 1]; ++q)
          acc.add(P.col[q], a * P.val[q]);
      }
      acc.flush(AP.col, AP.val);
      AP.rowptr[i + 1] = static_cast<i64>(AP.col.size());
    }
  }
  Csr Ac;
  Ac.nrow = P.ncol;
  Ac.ncol = P.ncol;
  Ac.rowptr.assign(static_cast<std::size_t>(Ac.nrow) + 1, 0);
  {
    RowAccum acc;
    acc.resize(P.ncol);
    for (int I = 0; I < Pt.nrow; ++I) {
      acc.begin();
      for (i64 p = Pt.rowptr[I]; p < Pt.rowptr[I + 1]; ++p) {
        const int i = Pt.col[p];
        const double pv = Pt.val[p];
        for (i64 q = AP.rowptr[i]; q < AP.rowptr[i + 1]; ++q)
          acc.add(AP.col[q], pv * AP.val[q]);
      }
      acc.flush(Ac.col, Ac.val);
      Ac.rowptr[I + 1] = static_cast<i64>(Ac.col.size());
    }
  }
  return Ac;
}

// ---------------------------------------------------------------------------
// Dense LDL^T for the coarsest level (SPD; Galerkin preserves SPD for full-rank
// P). Returns false if a non-positive pivot appears, in which case the caller
// falls back to extra smoothing at the bottom.
// ---------------------------------------------------------------------------
inline bool dense_ldlt(std::vector<double>& M, int n) {
  for (int j = 0; j < n; ++j) {
    double d = M[static_cast<std::size_t>(j) * n + j];
    for (int k = 0; k < j; ++k) {
      const double l = M[static_cast<std::size_t>(j) * n + k];
      d -= l * l * M[static_cast<std::size_t>(k) * n + k];
    }
    if (!(d > 0.0) || !std::isfinite(d)) return false;
    M[static_cast<std::size_t>(j) * n + j] = d;
    for (int i = j + 1; i < n; ++i) {
      double s = M[static_cast<std::size_t>(i) * n + j];
      for (int k = 0; k < j; ++k)
        s -= M[static_cast<std::size_t>(i) * n + k] *
             M[static_cast<std::size_t>(j) * n + k] *
             M[static_cast<std::size_t>(k) * n + k];
      M[static_cast<std::size_t>(i) * n + j] = s / d;
    }
  }
  return true;
}

inline void dense_ldlt_solve(const std::vector<double>& M, int n,
                             std::vector<double>& x) {
  for (int i = 0; i < n; ++i) {  // L y = b
    double s = x[static_cast<std::size_t>(i)];
    for (int k = 0; k < i; ++k)
      s -= M[static_cast<std::size_t>(i) * n + k] * x[static_cast<std::size_t>(k)];
    x[static_cast<std::size_t>(i)] = s;
  }
  for (int i = 0; i < n; ++i)  // D z = y
    x[static_cast<std::size_t>(i)] /= M[static_cast<std::size_t>(i) * n + i];
  for (int i = n - 1; i >= 0; --i) {  // L^T x = z
    double s = x[static_cast<std::size_t>(i)];
    for (int k = i + 1; k < n; ++k)
      s -= M[static_cast<std::size_t>(k) * n + i] * x[static_cast<std::size_t>(k)];
    x[static_cast<std::size_t>(i)] = s;
  }
}

// ---------------------------------------------------------------------------
// Setup
// ---------------------------------------------------------------------------
inline void fill_diag(const Csr& A, std::vector<i64>& diagpos,
                      std::vector<double>& invdiag) {
  diagpos.assign(static_cast<std::size_t>(A.nrow), -1);
  invdiag.assign(static_cast<std::size_t>(A.nrow), 0.0);
  for (int i = 0; i < A.nrow; ++i) {
    for (i64 p = A.rowptr[i]; p < A.rowptr[i + 1]; ++p)
      if (A.col[p] == i) {
        diagpos[static_cast<std::size_t>(i)] = p;
        invdiag[static_cast<std::size_t>(i)] = 1.0 / A.val[p];
        break;
      }
    if (diagpos[static_cast<std::size_t>(i)] < 0)
      throw std::runtime_error("amg: missing structural diagonal at row " +
                               std::to_string(i));
  }
}

// `dof2node0` / `nnodes0` describe the FINE level. Every coarser level
// aggregates on its own block structure: each coarse DOF belongs to the
// aggregate block the tentative prolongator produced it from.
inline Hierarchy setup(const Csr& A0, const std::vector<int>& dof2node0,
                       int nnodes0, int k, const std::vector<double>& B0,
                       const Options& opt) {
  Hierarchy H;
  Csr A = A0;
  std::vector<int> dof2node = dof2node0;
  int nnodes = nnodes0;
  std::vector<double> B = B0;

  for (int level = 0; level < opt.max_levels; ++level) {
    Level L;
    L.A = std::move(A);
    fill_diag(L.A, L.diagpos, L.invdiag);
    L.x.assign(static_cast<std::size_t>(L.A.nrow), 0.0);
    L.b.assign(static_cast<std::size_t>(L.A.nrow), 0.0);
    L.r.assign(static_cast<std::size_t>(L.A.nrow), 0.0);
    L.tmp.assign(static_cast<std::size_t>(L.A.nrow), 0.0);

    if (L.A.nrow <= opt.coarse_dof_cap || level + 1 == opt.max_levels) {
      H.total_bytes += L.A.bytes();
      H.lv.push_back(std::move(L));
      break;
    }

    const NodeGraph g =
        build_strength_graph(L.A, dof2node, nnodes, opt.strength_theta);
    std::vector<int> agg;
    const int naggs = aggregate(g, agg);

    std::vector<double> Bc;
    std::vector<int> dof2node_c;
    int ncoarse = 0;
    Csr T = build_tentative(agg, naggs, dof2node, L.A.nrow, k, B, Bc, ncoarse,
                            dof2node_c, opt.qr_drop_tol);

    if (ncoarse <= 0 || static_cast<double>(L.A.nrow) <
                            opt.min_coarsening_ratio * static_cast<double>(ncoarse)) {
      L.naggregates = naggs;  // coarsening stalled: make this the bottom
      H.total_bytes += L.A.bytes();
      H.lv.push_back(std::move(L));
      break;
    }

    if (opt.smooth_prolongator) {
      const double lam = gershgorin_dinva(L.A, L.diagpos);
      L.P = smooth_prolongator(L.A, L.diagpos, T, opt.jacobi_omega_scale / lam);
    } else {
      L.P = std::move(T);
    }
    L.Pt = transpose(L.P);
    L.naggregates = naggs;

    Csr Ac = galerkin(L.A, L.P, L.Pt);

    H.total_bytes += L.A.bytes() + L.P.bytes() + L.Pt.bytes();
    A = std::move(Ac);
    dof2node = std::move(dof2node_c);
    nnodes = naggs;
    B = std::move(Bc);
    H.lv.push_back(std::move(L));
  }

  const Level& C = H.lv.back();
  H.coarse_n = C.A.nrow;
  if (H.coarse_n > 0 && H.coarse_n <= 4000) {
    H.coarse_ldl.assign(static_cast<std::size_t>(H.coarse_n) * H.coarse_n, 0.0);
    for (int i = 0; i < C.A.nrow; ++i)
      for (i64 p = C.A.rowptr[i]; p < C.A.rowptr[i + 1]; ++p)
        H.coarse_ldl[static_cast<std::size_t>(i) * H.coarse_n + C.A.col[p]] = C.A.val[p];
    H.coarse_dense_ok = dense_ldlt(H.coarse_ldl, H.coarse_n);
    if (!H.coarse_dense_ok) {
      H.coarse_ldl.clear();
      H.coarse_ldl.shrink_to_fit();
    }
    H.total_bytes += H.coarse_ldl.capacity() * sizeof(double);
  }
  return H;
}

// ---------------------------------------------------------------------------
// Symmetric Gauss-Seidel (forward then backward), ascending / descending row
// order. Single-threaded, so deterministic.
// ---------------------------------------------------------------------------
inline void sgs(const Level& L, const std::vector<double>& b,
                std::vector<double>& x, int sweeps) {
  const Csr& A = L.A;
  for (int s = 0; s < sweeps; ++s) {
    for (int i = 0; i < A.nrow; ++i) {
      double t = b[static_cast<std::size_t>(i)];
      for (i64 p = A.rowptr[i]; p < A.rowptr[i + 1]; ++p)
        if (A.col[p] != i) t -= A.val[p] * x[static_cast<std::size_t>(A.col[p])];
      x[static_cast<std::size_t>(i)] = t * L.invdiag[static_cast<std::size_t>(i)];
    }
    for (int i = A.nrow - 1; i >= 0; --i) {
      double t = b[static_cast<std::size_t>(i)];
      for (i64 p = A.rowptr[i]; p < A.rowptr[i + 1]; ++p)
        if (A.col[p] != i) t -= A.val[p] * x[static_cast<std::size_t>(A.col[p])];
      x[static_cast<std::size_t>(i)] = t * L.invdiag[static_cast<std::size_t>(i)];
    }
  }
}

// One V-cycle at `level`, solving A x = b; `x` on entry is the initial guess.
inline void vcycle(const Hierarchy& H, int level, const std::vector<double>& b,
                   std::vector<double>& x, const Options& opt) {
  const Level& L = H.lv[static_cast<std::size_t>(level)];
  const bool bottom = (level + 1 >= static_cast<int>(H.lv.size())) || L.P.ncol == 0;
  if (bottom) {
    if (H.coarse_dense_ok && L.A.nrow == H.coarse_n) {
      std::vector<double> rhs = b;
      dense_ldlt_solve(H.coarse_ldl, H.coarse_n, rhs);
      x = rhs;
    } else {
      sgs(L, b, x, opt.pre_sweeps + opt.post_sweeps + 8);
    }
    return;
  }

  sgs(L, b, x, opt.pre_sweeps);

  L.A.apply(x.data(), L.tmp.data());
  for (int i = 0; i < L.A.nrow; ++i)
    L.r[static_cast<std::size_t>(i)] =
        b[static_cast<std::size_t>(i)] - L.tmp[static_cast<std::size_t>(i)];

  const Level& Lc = H.lv[static_cast<std::size_t>(level + 1)];
  L.P.apply_transpose(L.r.data(), Lc.b.data());
  std::fill(Lc.x.begin(), Lc.x.end(), 0.0);
  vcycle(H, level + 1, Lc.b, Lc.x, opt);
  L.P.apply(Lc.x.data(), L.tmp.data());
  for (int i = 0; i < L.A.nrow; ++i)
    x[static_cast<std::size_t>(i)] += L.tmp[static_cast<std::size_t>(i)];

  sgs(L, b, x, opt.post_sweeps);
}

// ---------------------------------------------------------------------------
// Solves
// ---------------------------------------------------------------------------
struct SolveStats {
  int cycles = 0;
  bool converged = false;
  double final_rel = 0.0;
  std::vector<double> history;  // ||r_k||/||r_0||, k = 0..cycles
  std::vector<double> solution;
  double seconds = 0.0;
};

// Stationary V-cycle iteration — THE honest contraction measurement. No Krylov
// acceleration, so r_{k+1}/r_k IS the multigrid contraction factor, which is
// exactly what 125's "contraction -> 1.0" verdict is about.
//
// `start` selects the level whose own system is solved (0 = the fine system).
// Running it at start = 1, 2, ... gives the SUB-HIERARCHY contraction per level:
// where in the hierarchy contraction is (or is not) lost.
inline SolveStats solve_stationary(const Hierarchy& H, int start,
                                   const std::vector<double>& b, double tol,
                                   int max_cycles, const Options& opt) {
  const Level& L0 = H.lv[static_cast<std::size_t>(start)];
  const int n = L0.A.nrow;
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
  SolveStats st;
  const double b0 = norm(b);
  if (b0 == 0.0) {
    st.converged = true;
    st.history.push_back(0.0);
    return st;
  }
  st.history.push_back(1.0);
  for (int k = 0; k < max_cycles; ++k) {
    L0.A.apply(x.data(), Ax.data());
    for (int i = 0; i < n; ++i)
      r[static_cast<std::size_t>(i)] =
          b[static_cast<std::size_t>(i)] - Ax[static_cast<std::size_t>(i)];
    std::fill(e.begin(), e.end(), 0.0);
    vcycle(H, start, r, e, opt);
    for (int i = 0; i < n; ++i)
      x[static_cast<std::size_t>(i)] += e[static_cast<std::size_t>(i)];
    L0.A.apply(x.data(), Ax.data());
    for (int i = 0; i < n; ++i)
      r[static_cast<std::size_t>(i)] =
          b[static_cast<std::size_t>(i)] - Ax[static_cast<std::size_t>(i)];
    const double rel = norm(r) / b0;
    st.history.push_back(rel);
    st.cycles = k + 1;
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

// AMG-preconditioned CG on the fine level. Same relative-residual criterion the
// library's CG uses (sqrt(||r||^2/||b||^2) <= tol), so these cycle counts are
// directly comparable to the geometric MG-CG cycle counts in handoff 125.
inline SolveStats solve_pcg(const Hierarchy& H, const std::vector<double>& b,
                            double tol, int max_iters, const Options& opt) {
  const Level& L0 = H.lv[0];
  const int n = L0.A.nrow;
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
  SolveStats st;
  const double b2 = dot(b, b);
  if (b2 == 0.0) {
    st.converged = true;
    st.history.push_back(0.0);
    st.solution = x;
    return st;
  }
  const double bn = std::sqrt(b2);
  st.history.push_back(1.0);
  vcycle(H, 0, r, z, opt);
  p = z;
  double rz = dot(r, z);
  for (int k = 0; k < max_iters; ++k) {
    L0.A.apply(p.data(), Ap.data());
    const double pAp = dot(p, Ap);
    if (!(pAp > 0.0) || !std::isfinite(pAp)) break;
    const double alpha = rz / pAp;
    for (int i = 0; i < n; ++i) {
      x[static_cast<std::size_t>(i)] += alpha * p[static_cast<std::size_t>(i)];
      r[static_cast<std::size_t>(i)] -= alpha * Ap[static_cast<std::size_t>(i)];
    }
    const double rel = std::sqrt(dot(r, r)) / bn;
    st.history.push_back(rel);
    st.cycles = k + 1;
    st.final_rel = rel;
    if (rel <= tol) {
      st.converged = true;
      break;
    }
    std::fill(z.begin(), z.end(), 0.0);
    vcycle(H, 0, r, z, opt);
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

}  // namespace amg
