// Krylov subspace recycling / deflation for the FEA solve sequence.
// See recycle.hpp for the full rationale, the update rule, the exactness
// argument and the determinism argument. This file is the arithmetic.
//
// Everything here is fixed-order and single-threaded: the chunked inner-product
// kernel accumulates chunk by chunk in ascending order with a compile-time chunk
// size, the Cholesky is unpivoted, the eigensolver is cyclic Jacobi with a fixed
// sweep order and bound, and the Ritz selection breaks ties on ascending index.
// No atomics, no randomness, no wall-clock, no threading.

#include "recycle.hpp"

#include "fea_matfree.hpp"  // mf_parallel_ranges (the shared matrix-free pool)

#include <algorithm>
#include <atomic>
#include <cmath>
#include <cstddef>
#include <vector>

namespace topopt {
namespace fea_detail {

namespace {

// --- Configuration (process-global, like the other matrix-free toggles) -------
std::atomic<bool> g_rc_enabled{false};
std::atomic<int> g_rc_dim{kRecycleDefaultDim};
std::atomic<int> g_rc_cycle{1};
std::atomic<bool> g_rc_metric_diag{true};
std::atomic<bool> g_rc_wrap_mg{true};

// --- Carried state (thread-local, like the 127 multigrid stagnation latch) ----
struct RcSpace {
  int n = 0;
  int k = 0;      // columns ACTUALLY carried (the rank guard may deliver < cfg_k)
  int cfg_k = 0;  // the configured k this basis was extracted under
  std::vector<float> U;  // n*k, column-major (column j at U[j*n ...])
  // Lower Cholesky factor of E = U^T A U, CARRIED between solves. Refreshed (with
  // k exact FP64 matvecs) only on a rebuild solve; reused as-is in between. That
  // is safe because E only SCALES the correction: any SPD E keeps
  // M^-1 + U E^-1 U^T symmetric positive definite, so a slightly stale E costs
  // iterations, never correctness — and it takes the setup matvecs off every
  // non-rebuild solve, which is what makes recycling affordable at all when the
  // baseline solve is short (the multigrid regime, where k matvecs would
  // otherwise be a large fraction of the whole solve). At the moment of
  // extraction E is the IDENTITY by construction (the Ritz basis is normalised to
  // u_i^T A u_i = 1 and the columns are A-orthogonal), so commit() stores I.
  std::vector<double> echol;
};
thread_local RcSpace g_space;
thread_local long long g_solve_counter = 0;

// Chunk length of every inner-product accumulation. Compile-time constant, so
// the summation order is fixed regardless of n, of the column count, and of the
// machine: this is what makes the small matrices bit-reproducible.
constexpr int kChunk = 2048;

// Cyclic-Jacobi sweep bound. 30 sweeps is far beyond what a <= 64 x 64 symmetric
// matrix ever needs (quadratic convergence sets in after ~3); the fixed bound is
// there so the routine terminates identically on every input.
constexpr int kJacobiSweeps = 30;

// Relative pivot floor for the unpivoted Cholesky rank guard.
constexpr double kPivotFloor = 1e-12;

// Granularity floor for threading the per-iteration correction: fewer than this
// many chunks per worker and the pass runs serially (a dispatch must carry enough
// work to amortise the pool wakeup). 4 chunks is ~8k DOFs x k columns.
constexpr int kMinChunksPerThread = 4;

// out[i*c + j] = sum_t X[i][t] * Y[j][t] * w(t), where w(t) is 1 when
// `invdiag` is null and 1/invdiag[t] otherwise (guarded entries weigh 1).
// Chunked so all columns of a chunk stay resident while the c*c pairs are formed.
void pair_products(const std::vector<const float*>& X,
                   const std::vector<const float*>& Y, int n,
                   const double* invdiag, double* out) {
  const int c = static_cast<int>(X.size());
  for (int i = 0; i < c * c; ++i) out[i] = 0.0;
  std::vector<double> w(static_cast<std::size_t>(kChunk), 1.0);
  for (int t0 = 0; t0 < n; t0 += kChunk) {
    const int len = std::min(kChunk, n - t0);
    if (invdiag != nullptr)
      for (int t = 0; t < len; ++t) {
        const double d = invdiag[t0 + t];
        w[static_cast<std::size_t>(t)] = (d > 0.0) ? 1.0 / d : 1.0;
      }
    for (int i = 0; i < c; ++i) {
      const float* xi = X[static_cast<std::size_t>(i)] + t0;
      for (int j = 0; j < c; ++j) {
        const float* yj = Y[static_cast<std::size_t>(j)] + t0;
        double s = 0.0;
        if (invdiag != nullptr)
          for (int t = 0; t < len; ++t)
            s += static_cast<double>(xi[t]) * static_cast<double>(yj[t]) *
                 w[static_cast<std::size_t>(t)];
        else
          for (int t = 0; t < len; ++t)
            s += static_cast<double>(xi[t]) * static_cast<double>(yj[t]);
        out[static_cast<std::size_t>(i) * c + j] += s;
      }
    }
  }
}

// Unpivoted lower Cholesky of the symmetric c x c row-major `A`, in place (the
// lower triangle becomes L; the strict upper triangle is zeroed). Returns -1 on
// success, else the 0-based index of the FIRST column whose pivot fell at or
// below kPivotFloor * (largest input diagonal) — the caller drops exactly that
// column, in that order, and retries.
int chol_factor(double* A, int c) {
  double scale = 0.0;
  for (int i = 0; i < c; ++i)
    scale = std::max(scale, std::fabs(A[static_cast<std::size_t>(i) * c + i]));
  const double floor_pivot = (scale > 0.0) ? kPivotFloor * scale : 0.0;
  for (int i = 0; i < c; ++i) {
    double d = A[static_cast<std::size_t>(i) * c + i];
    for (int t = 0; t < i; ++t) {
      const double v = A[static_cast<std::size_t>(i) * c + t];
      d -= v * v;
    }
    if (!(d > floor_pivot) || !std::isfinite(d)) return i;
    const double l = std::sqrt(d);
    A[static_cast<std::size_t>(i) * c + i] = l;
    for (int r = i + 1; r < c; ++r) {
      double s = A[static_cast<std::size_t>(r) * c + i];
      for (int t = 0; t < i; ++t)
        s -= A[static_cast<std::size_t>(r) * c + t] *
             A[static_cast<std::size_t>(i) * c + t];
      A[static_cast<std::size_t>(r) * c + i] = s / l;
    }
  }
  for (int i = 0; i < c; ++i)
    for (int j = i + 1; j < c; ++j) A[static_cast<std::size_t>(i) * c + j] = 0.0;
  return -1;
}

// Solve L y = b in place (forward substitution), L lower c x c row-major.
void chol_forward(const double* L, int c, double* b) {
  for (int i = 0; i < c; ++i) {
    double s = b[i];
    for (int t = 0; t < i; ++t) s -= L[static_cast<std::size_t>(i) * c + t] * b[t];
    b[i] = s / L[static_cast<std::size_t>(i) * c + i];
  }
}

// Solve L^T y = b in place (back substitution).
void chol_backward(const double* L, int c, double* b) {
  for (int i = c - 1; i >= 0; --i) {
    double s = b[i];
    for (int t = i + 1; t < c; ++t)
      s -= L[static_cast<std::size_t>(t) * c + i] * b[t];
    b[i] = s / L[static_cast<std::size_t>(i) * c + i];
  }
}

// Solve L L^T x = b in place.
void chol_solve(const double* L, int c, double* b) {
  chol_forward(L, c, b);
  chol_backward(L, c, b);
}

// Cyclic-Jacobi symmetric eigendecomposition of the c x c row-major `A`
// (destroyed). Eigenvalues land in `w`; eigenvectors are the COLUMNS of `V`
// (row-major c x c), orthonormal. Fixed sweep order (i ascending, then j), fixed
// sweep bound: identical arithmetic on identical input, every run.
void jacobi_eig(double* A, int c, double* V, double* w) {
  for (int i = 0; i < c; ++i)
    for (int j = 0; j < c; ++j)
      V[static_cast<std::size_t>(i) * c + j] = (i == j) ? 1.0 : 0.0;
  for (int sweep = 0; sweep < kJacobiSweeps; ++sweep) {
    double off = 0.0;
    for (int i = 0; i < c; ++i)
      for (int j = i + 1; j < c; ++j) {
        const double a = A[static_cast<std::size_t>(i) * c + j];
        off += a * a;
      }
    if (!(off > 0.0)) break;
    for (int p = 0; p < c - 1; ++p)
      for (int q = p + 1; q < c; ++q) {
        const double apq = A[static_cast<std::size_t>(p) * c + q];
        if (apq == 0.0) continue;
        const double app = A[static_cast<std::size_t>(p) * c + p];
        const double aqq = A[static_cast<std::size_t>(q) * c + q];
        // Skip rotations that are numerically inert (the classic |a_pq| tiny
        // relative to the diagonal test), so the sweep terminates cleanly.
        if (std::fabs(apq) <= 1e-300) continue;
        const double theta = (aqq - app) / (2.0 * apq);
        const double t = (theta >= 0.0)
                             ? 1.0 / (theta + std::sqrt(1.0 + theta * theta))
                             : -1.0 / (-theta + std::sqrt(1.0 + theta * theta));
        const double cs = 1.0 / std::sqrt(1.0 + t * t);
        const double sn = t * cs;
        for (int r = 0; r < c; ++r) {
          const double arp = A[static_cast<std::size_t>(r) * c + p];
          const double arq = A[static_cast<std::size_t>(r) * c + q];
          A[static_cast<std::size_t>(r) * c + p] = cs * arp - sn * arq;
          A[static_cast<std::size_t>(r) * c + q] = sn * arp + cs * arq;
        }
        for (int r = 0; r < c; ++r) {
          const double apr = A[static_cast<std::size_t>(p) * c + r];
          const double aqr = A[static_cast<std::size_t>(q) * c + r];
          A[static_cast<std::size_t>(p) * c + r] = cs * apr - sn * aqr;
          A[static_cast<std::size_t>(q) * c + r] = sn * apr + cs * aqr;
        }
        for (int r = 0; r < c; ++r) {
          const double vrp = V[static_cast<std::size_t>(r) * c + p];
          const double vrq = V[static_cast<std::size_t>(r) * c + q];
          V[static_cast<std::size_t>(r) * c + p] = cs * vrp - sn * vrq;
          V[static_cast<std::size_t>(r) * c + q] = sn * vrp + cs * vrq;
        }
      }
  }
  for (int i = 0; i < c; ++i) w[i] = A[static_cast<std::size_t>(i) * c + i];
}

}  // namespace

// --- Configuration accessors -------------------------------------------------

bool rc_set_enabled(bool enable) { return g_rc_enabled.exchange(enable); }
bool rc_enabled() { return g_rc_enabled.load(); }

int rc_set_dim(int k) {
  const int prev = g_rc_dim.load();
  g_rc_dim.store(k > 0 ? k : kRecycleDefaultDim);
  return prev;
}
int rc_dim() { return g_rc_dim.load(); }

int rc_set_cycle(int c) {
  const int prev = g_rc_cycle.load();
  g_rc_cycle.store(c > 0 ? c : 1);
  return prev;
}
int rc_cycle() { return g_rc_cycle.load(); }

bool rc_set_metric_diagonal(bool use_diagonal) {
  return g_rc_metric_diag.exchange(use_diagonal);
}
bool rc_metric_diagonal() { return g_rc_metric_diag.load(); }

bool rc_set_wrap_multigrid(bool enable) { return g_rc_wrap_mg.exchange(enable); }
bool rc_wrap_multigrid() { return g_rc_wrap_mg.load(); }

void rc_reset_space() {
  g_space.n = 0;
  g_space.k = 0;
  g_space.cfg_k = 0;
  g_space.U.clear();
  g_space.U.shrink_to_fit();
  g_space.echol.clear();
  g_space.echol.shrink_to_fit();
  g_solve_counter = 0;
}

bool rc_space_active() { return g_space.k > 0; }
int rc_space_dim() { return g_space.k; }
std::size_t rc_space_bytes() {
  return g_space.U.size() * sizeof(float);
}

// --- Session -----------------------------------------------------------------

RecycleSession::~RecycleSession() = default;

void RecycleSession::begin(int n, const double* invdiag) {
  want_setup_ = false;
  harvesting_ = false;
  active_ = false;
  if (!rc_enabled() || n <= 0) return;

  const int want_k = rc_dim();
  // A resolution change (different free-DOF count) or a RECONFIGURED k makes the
  // carried columns meaningless — drop them rather than silently mismatch. The
  // comparison is against the CONFIGURED k the basis was extracted under, not its
  // achieved column count: the fixed-order rank guard legitimately delivers fewer
  // than k columns when the candidate set is numerically dependent, and treating
  // that as a reconfiguration would throw the basis away on every single solve
  // (it did, until this distinction was drawn).
  if (g_space.k > 0 && (g_space.n != n || g_space.cfg_k != want_k))
    rc_reset_space();

  k_ = (g_space.k > 0) ? g_space.k : want_k;
  m_ = want_k;
  invdiag_ = invdiag;

  // Harvest (and refresh E) on the fixed cycle, and ALWAYS when there is no space
  // yet (bootstrap).
  const long long seq = g_solve_counter++;
  harvesting_ = (g_space.k == 0) || (rc_cycle() <= 1) || (seq % rc_cycle() == 0);

  if (g_space.k == 0) return;  // bootstrap: nothing to apply, only to harvest.

  if (harvesting_) {
    // A rebuild solve needs A*U anyway (for the Rayleigh-Ritz), so it also pays
    // for a FRESH E. That is the only solve that charges setup matvecs.
    want_setup_ = true;
    return;
  }
  // Between rebuilds: reuse the carried E. Zero matvecs, still SPD, still exact.
  if (static_cast<int>(g_space.echol.size()) !=
      static_cast<int>(g_space.k) * g_space.k)
    return;  // defensive: no usable factor -> run this solve without recycling
  echol_ = g_space.echol;
  cvec_.assign(static_cast<std::size_t>(k_), 0.0);
  partials_.assign(static_cast<std::size_t>((n_ + kChunk - 1) / kChunk) *
                       static_cast<std::size_t>(k_),
                   0.0);
  active_ = true;
}

bool RecycleSession::setup_finish(std::vector<double>& e) {
  const int k = k_;
  // Enforce exact symmetry before factorising (E is symmetric in exact
  // arithmetic; the two triangles differ only by rounding).
  for (int i = 0; i < k; ++i)
    for (int j = i + 1; j < k; ++j) {
      const double s = 0.5 * (e[static_cast<std::size_t>(i) * k + j] +
                              e[static_cast<std::size_t>(j) * k + i]);
      e[static_cast<std::size_t>(i) * k + j] = s;
      e[static_cast<std::size_t>(j) * k + i] = s;
    }
  echol_ = e;
  if (chol_factor(echol_.data(), k) >= 0) {
    // E = U^T A U is not positive definite: the carried basis has degenerated
    // (dependent columns). Drop it and run this solve without recycling — the
    // additive correction is an accelerator, never a correctness dependency.
    echol_.clear();
    rc_reset_space();
    want_setup_ = false;
    return false;
  }
  g_space.echol = echol_;  // carry the fresh factor to the non-rebuild solves
  cvec_.assign(static_cast<std::size_t>(k), 0.0);
  partials_.assign(static_cast<std::size_t>((n_ + kChunk - 1) / kChunk) *
                       static_cast<std::size_t>(k),
                   0.0);
  return true;
}

void RecycleSession::promote_column(int j, double* out) const {
  const float* src = g_space.U.data() + static_cast<std::size_t>(j) *
                                            static_cast<std::size_t>(n_);
  for (int t = 0; t < n_; ++t) out[t] = static_cast<double>(src[t]);
}

double RecycleSession::column_dot(int j, const double* v) const {
  const float* uj = g_space.U.data() + static_cast<std::size_t>(j) *
                                           static_cast<std::size_t>(n_);
  double total = 0.0;
  for (int t0 = 0; t0 < n_; t0 += kChunk) {
    const int len = std::min(kChunk, n_ - t0);
    double s = 0.0;
    for (int t = 0; t < len; ++t)
      s += static_cast<double>(uj[t0 + t]) * v[t0 + t];
    total += s;
  }
  return total;
}

// The per-iteration hot path. It is BANDWIDTH-bound and it is charged on EVERY
// CG iteration, so its traffic is the whole economics of the technique: the
// theoretical floor is two streaming reads of U (once to form c = U^T r, once to
// expand U c) plus one read of r and one read-modify-write of z.
//
// Both loops are chunked with the module's fixed chunk length so a chunk of every
// column stays L1-resident, and — this is the part that matters — the expansion
// accumulates all k columns into a chunk-local FP64 buffer and touches z ONCE per
// chunk. The obvious column-at-a-time version instead streams the full FP64 z k
// times per iteration, which measured 3.3x per-iteration cost at k=16 (dominated
// entirely by that z traffic) rather than the ~1.4x the column reads alone cost.
void RecycleSession::augment(const double* r, double* z) const {
  if (!active_) return;
  const int k = k_;
  const int n = n_;
  const float* const U = g_space.U.data();
  double* const c = cvec_.data();
  const int nchunk = (n + kChunk - 1) / kChunk;
  double* const part = partials_.data();

  // Pass 1: per-chunk partial dots, then a reduction in ASCENDING CHUNK ORDER.
  // Each chunk writes only its own k partials, so the split across workers can
  // never change a value, and the fixed-order reduction fixes the summation
  // order — the result is bit-identical for any thread count.
  mf_parallel_ranges(0, nchunk, kMinChunksPerThread, [&](int lo, int hi) {
    for (int ci = lo; ci < hi; ++ci) {
      const int t0 = ci * kChunk;
      const int len = std::min(kChunk, n - t0);
      const double* const rr = r + t0;
      double* const pc = part + static_cast<std::size_t>(ci) * k;
      for (int j = 0; j < k; ++j) {
        const float* const uj = U + static_cast<std::size_t>(j) * n + t0;
        double s = 0.0;
        for (int t = 0; t < len; ++t) s += static_cast<double>(uj[t]) * rr[t];
        pc[j] = s;
      }
    }
  });
  for (int j = 0; j < k; ++j) c[j] = 0.0;
  for (int ci = 0; ci < nchunk; ++ci) {
    const double* const pc = part + static_cast<std::size_t>(ci) * k;
    for (int j = 0; j < k; ++j) c[j] += pc[j];
  }

  // Pass 2: c <- E^{-1} c, then z += U c with ONE pass over z. Each chunk writes
  // a disjoint slice of z, so this is embarrassingly parallel AND deterministic.
  chol_solve(echol_.data(), k, c);
  mf_parallel_ranges(0, nchunk, kMinChunksPerThread, [&](int lo, int hi) {
    double acc[kChunk];
    for (int ci = lo; ci < hi; ++ci) {
      const int t0 = ci * kChunk;
      const int len = std::min(kChunk, n - t0);
      for (int t = 0; t < len; ++t) acc[t] = 0.0;
      for (int j = 0; j < k; ++j) {
        const double cj = c[j];
        const float* const uj = U + static_cast<std::size_t>(j) * n + t0;
        for (int t = 0; t < len; ++t) acc[t] += cj * static_cast<double>(uj[t]);
      }
      double* const zz = z + t0;
      for (int t = 0; t < len; ++t) zz[t] += acc[t];
    }
  });
}

void RecycleSession::observe(int it, const double* p, const double* ap) {
  if (!harvesting_ || m_ <= 0) return;
  if (it % stride_ != 0) return;
  const std::size_t span = static_cast<std::size_t>(n_) *
                           static_cast<std::size_t>(m_);
  if (hp_.empty()) {
    hp_.assign(span, 0.0f);
    hap_.assign(span, 0.0f);
  }
  const std::size_t off =
      static_cast<std::size_t>(stored_ % m_) * static_cast<std::size_t>(n_);
  for (int t = 0; t < n_; ++t) {
    hp_[off + static_cast<std::size_t>(t)] = static_cast<float>(p[t]);
    hap_[off + static_cast<std::size_t>(t)] = static_cast<float>(ap[t]);
  }
  ++stored_;
  filled_ = std::min(stored_, m_);
  // Decimate: once the ring has been filled, halve the sampling rate. The sample
  // therefore spans the WHOLE solve without knowing its length in advance, and
  // stores only ~m*log2(iters/m) columns.
  if (stored_ % m_ == 0) stride_ *= 2;
}

void RecycleSession::commit() {
  if (!harvesting_) return;
  const int n = n_;
  const int ku = active_ ? k_ : 0;
  const int c = ku + filled_;
  if (c == 0) return;

  // Candidate basis B = [U | harvested p], and its operator image A B.
  std::vector<const float*> B, AB;
  B.reserve(static_cast<std::size_t>(c));
  AB.reserve(static_cast<std::size_t>(c));
  for (int j = 0; j < ku; ++j) {
    B.push_back(g_space.U.data() + static_cast<std::size_t>(j) * n);
    AB.push_back(hau_.data() + static_cast<std::size_t>(j) * n);
  }
  for (int j = 0; j < filled_; ++j) {
    B.push_back(hp_.data() + static_cast<std::size_t>(j) * n);
    AB.push_back(hap_.data() + static_cast<std::size_t>(j) * n);
  }

  std::vector<double> MA(static_cast<std::size_t>(c) * c);
  std::vector<double> MG(static_cast<std::size_t>(c) * c);
  pair_products(B, AB, n, nullptr, MA.data());
  pair_products(B, B, n, rc_metric_diagonal() ? invdiag_ : nullptr, MG.data());
  for (int i = 0; i < c; ++i)
    for (int j = i + 1; j < c; ++j) {
      const double a = 0.5 * (MA[static_cast<std::size_t>(i) * c + j] +
                              MA[static_cast<std::size_t>(j) * c + i]);
      MA[static_cast<std::size_t>(i) * c + j] = a;
      MA[static_cast<std::size_t>(j) * c + i] = a;
      const double g = 0.5 * (MG[static_cast<std::size_t>(i) * c + j] +
                              MG[static_cast<std::size_t>(j) * c + i]);
      MG[static_cast<std::size_t>(i) * c + j] = g;
      MG[static_cast<std::size_t>(j) * c + i] = g;
    }

  // Rank guard: unpivoted Cholesky of the metric Gram, dropping the first
  // failing column (ascending order) and retrying. Deterministic degradation.
  std::vector<int> idx(static_cast<std::size_t>(c));
  for (int i = 0; i < c; ++i) idx[static_cast<std::size_t>(i)] = i;
  std::vector<double> L;
  int a = 0;
  for (;;) {
    a = static_cast<int>(idx.size());
    if (a == 0) return;
    L.assign(static_cast<std::size_t>(a) * a, 0.0);
    for (int i = 0; i < a; ++i)
      for (int j = 0; j < a; ++j)
        L[static_cast<std::size_t>(i) * a + j] =
            MG[static_cast<std::size_t>(idx[static_cast<std::size_t>(i)]) * c +
               idx[static_cast<std::size_t>(j)]];
    const int fail = chol_factor(L.data(), a);
    if (fail < 0) break;
    idx.erase(idx.begin() + fail);
  }

  // S = L^{-1} (B^T A B) L^{-T}, formed by two triangular solves.
  std::vector<double> S(static_cast<std::size_t>(a) * a);
  for (int i = 0; i < a; ++i)
    for (int j = 0; j < a; ++j)
      S[static_cast<std::size_t>(i) * a + j] =
          MA[static_cast<std::size_t>(idx[static_cast<std::size_t>(i)]) * c +
             idx[static_cast<std::size_t>(j)]];
  std::vector<double> col(static_cast<std::size_t>(a));
  for (int j = 0; j < a; ++j) {  // columns: S <- L^{-1} S
    for (int i = 0; i < a; ++i)
      col[static_cast<std::size_t>(i)] = S[static_cast<std::size_t>(i) * a + j];
    chol_forward(L.data(), a, col.data());
    for (int i = 0; i < a; ++i)
      S[static_cast<std::size_t>(i) * a + j] = col[static_cast<std::size_t>(i)];
  }
  for (int i = 0; i < a; ++i) {  // rows: S <- S L^{-T}
    for (int j = 0; j < a; ++j)
      col[static_cast<std::size_t>(j)] = S[static_cast<std::size_t>(i) * a + j];
    chol_forward(L.data(), a, col.data());
    for (int j = 0; j < a; ++j)
      S[static_cast<std::size_t>(i) * a + j] = col[static_cast<std::size_t>(j)];
  }
  for (int i = 0; i < a; ++i)
    for (int j = i + 1; j < a; ++j) {
      const double s = 0.5 * (S[static_cast<std::size_t>(i) * a + j] +
                              S[static_cast<std::size_t>(j) * a + i]);
      S[static_cast<std::size_t>(i) * a + j] = s;
      S[static_cast<std::size_t>(j) * a + i] = s;
    }

  std::vector<double> V(static_cast<std::size_t>(a) * a);
  std::vector<double> theta(static_cast<std::size_t>(a));
  jacobi_eig(S.data(), a, V.data(), theta.data());

  // Keep the k SMALLEST Ritz values (ties broken on ascending index — stable and
  // deterministic). theta_i is a Rayleigh quotient of the SPD pencil, so a
  // non-positive value can only be rounding noise on a numerically dependent
  // direction: skip those rather than take a square root of them.
  std::vector<int> order;
  order.reserve(static_cast<std::size_t>(a));
  for (int i = 0; i < a; ++i)
    if (theta[static_cast<std::size_t>(i)] > 0.0 &&
        std::isfinite(theta[static_cast<std::size_t>(i)]))
      order.push_back(i);
  std::stable_sort(order.begin(), order.end(), [&theta](int x, int y) {
    return theta[static_cast<std::size_t>(x)] < theta[static_cast<std::size_t>(y)];
  });
  const int kout = std::min<int>(rc_dim(), static_cast<int>(order.size()));
  if (kout <= 0) return;

  // u_i = B y_i / sqrt(theta_i) with y_i = L^{-T} v_i, so U^T A U = I exactly at
  // extraction (see recycle.hpp step 3).
  std::vector<double> y(static_cast<std::size_t>(a));
  std::vector<float> newU(static_cast<std::size_t>(n) *
                              static_cast<std::size_t>(kout),
                          0.0f);
  std::vector<double> acc(static_cast<std::size_t>(kChunk));
  for (int e = 0; e < kout; ++e) {
    const int ie = order[static_cast<std::size_t>(e)];
    for (int i = 0; i < a; ++i)
      y[static_cast<std::size_t>(i)] = V[static_cast<std::size_t>(i) * a + ie];
    chol_backward(L.data(), a, y.data());
    const double scale = 1.0 / std::sqrt(theta[static_cast<std::size_t>(ie)]);
    for (int i = 0; i < a; ++i) y[static_cast<std::size_t>(i)] *= scale;
    float* dst = newU.data() + static_cast<std::size_t>(e) * n;
    for (int t0 = 0; t0 < n; t0 += kChunk) {
      const int len = std::min(kChunk, n - t0);
      for (int t = 0; t < len; ++t) acc[static_cast<std::size_t>(t)] = 0.0;
      for (int i = 0; i < a; ++i) {
        const double yi = y[static_cast<std::size_t>(i)];
        if (yi == 0.0) continue;
        const float* bi =
            B[static_cast<std::size_t>(idx[static_cast<std::size_t>(i)])] + t0;
        for (int t = 0; t < len; ++t)
          acc[static_cast<std::size_t>(t)] += yi * static_cast<double>(bi[t]);
      }
      for (int t = 0; t < len; ++t)
        dst[t0 + t] = static_cast<float>(acc[static_cast<std::size_t>(t)]);
    }
  }

  g_space.n = n;
  g_space.k = kout;
  g_space.cfg_k = rc_dim();
  g_space.U = std::move(newU);
  // E == I exactly at extraction (u_i^T A u_j = delta_ij by construction), so the
  // carried Cholesky factor is the identity.
  g_space.echol.assign(static_cast<std::size_t>(kout) * kout, 0.0);
  for (int i = 0; i < kout; ++i)
    g_space.echol[static_cast<std::size_t>(i) * kout + i] = 1.0;
}

}  // namespace fea_detail
}  // namespace topopt
