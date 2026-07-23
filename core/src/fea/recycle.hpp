// Internal (non-installed) header: KRYLOV SUBSPACE RECYCLING / DEFLATION for the
// FEA solve sequence. Shared by the two matrix-free CG loops it wraps —
// matfree.cpp (mf_cg_solve, the Jacobi-preconditioned regime) and multigrid.cpp
// (mf_mgpcg, the V-cycle-preconditioned regime).
//
// Deliberately Eigen-FREE, like the rest of the matrix-free stack: the only
// storage is a handful of contiguous float/double arrays and small dense k x k
// blocks handled by the fixed-order dense kernels in recycle.cpp.
//
// ===========================================================================
// WHY (the problem this exists to solve)
// ===========================================================================
// A SIMP/MMA run solves K(rho_i) u = f once per optimizer iteration, and
// K(rho_{i+1}) is a TINY perturbation of K(rho_i). Today every solve starts from
// scratch: CG re-discovers, from zero, the same handful of slowly-converging
// error directions it just spent thousands of iterations resolving. In this
// codebase those directions are not generic — they are the near-rigid-body
// motions of weakly-connected solid regions produced by the near-void material
// that dominates design-box runs (handoff 125: 4.5k-44k CG iterations/solve on
// the stand-class fixture, the Jacobi-regime disease).
//
// Recycling keeps a small, fixed-dimension subspace of exactly those directions
// between solves and removes them from CG's workload.
//
// Published in and FOR topology optimization:
//   * Wang, de Sturler & Paulino 2007 (IJNME 69:2441) — recycling Krylov spaces
//     across the TO solve sequence (RMINRES), plus the density-ratio rescaling.
//   * Parks, de Sturler, Mackey, Johnson & Maiti 2006 (SISC 28:1651) — GCRO-DR:
//     ~50% iteration cuts on sequences of slowly-changing systems.
//   * Jonsthovel, van Gijzen, Vuik & Scarpas 2012 — deflated PCG on high-contrast
//     composites with near-void inclusions: the small eigenvalues even SA-AMG
//     leaves behind; 2.8x, and non-convergent -> convergent cases.
//   * Gaul, Gutknecht, Liesen & Nabben 2013 (SIMAX 34:495) — recycling with a
//     FIXED subspace IS deflation. That equivalence is what makes a deterministic
//     implementation possible at all: fix the subspace for the duration of a
//     solve and the method is a plain SPD-preconditioned CG.
//
// ===========================================================================
// WHAT IT DOES — the additive two-level (coarse-space) form
// ===========================================================================
// Given a recycle basis U (n x k, carried between solves) we precondition with
//
//     M_rec^{-1} r  =  M^{-1} r  +  U E^{-1} (U^T r),      E = U^T A U   (k x k)
//
// where M^{-1} is WHICHEVER preconditioner the existing solve path already runs
// (matrix-free Jacobi, FP64 V-cycle, FP32 V-cycle) — recycling wraps it from the
// OUTSIDE and never replaces it. E is formed once per solve with k exact FP64
// matvecs (charged: CgInfo::recycle_setup_matvecs).
//
// EXACTNESS IS UNCONDITIONAL, and that is why this form was chosen over the
// projected/deflated (DPCG) form. M^{-1} is SPD and U E^{-1} U^T is symmetric
// positive semi-definite for ANY U with SPD E, so M_rec^{-1} is SPD for any U
// whatsoever. PCG with an SPD preconditioner converges to the true solution of
// A x = b, and the stopping test is unchanged (the same relative residual
// ||b - A x|| / ||b|| <= tolerance on the same recursively-updated r). A stale,
// noisy or outright useless recycle space can therefore cost ITERATIONS but can
// never change the answer. The projected form, by contrast, relies on an
// invariant (r stays orthogonal to U) that a rounded or inconsistent A*U would
// silently break. This technique changes the route, not the answer.
//
// SPECTRAL EFFECT. If (theta, u) is a generalized eigenpair A u = theta D u
// (D = the Jacobi diagonal, the metric used for the extraction below), then
//     (D^{-1} + u (u^T A u)^{-1} u^T) A u = theta u + u,
// i.e. a small theta is lifted to theta + 1 while the rest of the spectrum is
// untouched: exactly Frank & Vuik's deflation effect, obtained additively.
//
// ===========================================================================
// THE UPDATE RULE (documented here per the task; determinism by construction)
// ===========================================================================
// The subspace is extracted from CG's OWN Lanczos process, at no extra matvec
// cost, and rebuilt on a fixed per-solve cycle:
//
// 1. HARVEST. During a harvesting solve the loop hands us its search direction
//    p_j together with the operator image A p_j it has ALREADY computed for the
//    step length (the `tmp`/`Ap` buffer). Both are stored as float. Sampling is a
//    deterministic decimating ring of m slots: store when (iter % stride == 0),
//    and double `stride` each time the ring wraps. That keeps the sample spread
//    over the WHOLE solve (a 44k-iteration solve stores ~m*log2(44k/m) columns,
//    not 44k) with no dependence on the unknown final iteration count, on
//    threading, or on timing.
//
// 2. RAYLEIGH-RITZ over the UNION. The candidate basis is
//        B = [ U (the k carried columns) | P (the m harvested directions) ]
//    and we solve the small generalized symmetric eigenproblem
//        (B^T A B) y = theta (B^T D B) y,     D = the Jacobi diagonal,
//    keeping the k SMALLEST theta. Both small matrices are formed EXACTLY (no
//    A-conjugacy is assumed of the harvested directions — the finite-precision
//    loss of conjugacy over thousands of iterations is real): B^T A B uses the
//    stored A*B columns, B^T D B is a diagonally-weighted Gram. The metric is D
//    rather than the identity because CG sees the spectrum of M^{-1} A, and
//    targeting the small eigenvalues of the PENCIL (A, D) is what makes the
//    +1 lift above land on the modes that actually slow the iteration down.
//
// 3. NEW BASIS. u_i = B y_i / sqrt(theta_i), so the rebuilt U satisfies
//    U^T A U = I at the moment of extraction — E stays well conditioned for the
//    next solve, and no separate orthogonalization pass is needed (the
//    eigenvectors of the reduced pencil are A- and D-orthogonal by construction).
//    A fixed-order modified Gram-Schmidt would be a no-op on them; what IS kept
//    is the fixed-order rank guard: the Cholesky of B^T D B runs unpivoted in
//    ascending column order and any column that fails the pivot test is dropped
//    IN THAT ORDER, so a rank-deficient candidate set degrades identically every
//    run.
//
// DETERMINISM BY CONSTRUCTION. Fixed k, fixed m, fixed traversal order, fixed
// chunked accumulation order in every inner product (chunk size is a compile-time
// constant), unpivoted fixed-order Cholesky, cyclic-Jacobi eigensolver with a
// fixed sweep order and a fixed iteration bound, stable index-tiebroken selection
// of the k smallest Ritz values. No atomics, no threading, no randomness, no
// wall-clock input anywhere in this module. Two runs of the same job produce
// bit-identical recycle bases, hence bit-identical residual histories.
//
// LIFETIME. The carried space is thread-local and STICKY across solves; the
// driver resets it at a run/rung boundary (fea_reset_krylov_recycle_space). The
// space is also dropped automatically whenever the free-DOF count n changes (a
// resolution change makes the old columns meaningless).
//
// MEMORY, stated honestly. Between solves the footprint is k float columns:
// 4*k*n bytes (fea_krylov_recycle_bytes reports it). A REBUILD solve peaks at
// 2*(k + m) float columns — U and A*U, plus the sample's p and A p — i.e. 16*k*n
// bytes at the default m = k. That peak, not the carried basis, is the binding
// memory number, and a longer rebuild cycle reduces how OFTEN it is paid, not how
// large it is. (Handoff 133 measured a longer cycle and REJECTED it on iterations
// anyway: a 4-solve-old basis was worth almost nothing.)
// Everything is float: the basis is a preconditioner ingredient, where precision
// buys convergence rate and nothing else — E is still formed from exact FP64
// matvecs applied to the promoted columns, so it is exactly consistent with the
// U actually used.

#pragma once

#include <cstddef>
#include <utility>
#include <vector>

namespace topopt {
namespace fea_detail {

// Default recycle dimension k, chosen from the measured sweep over {8, 16, 24} on
// both regime fixtures (handoff 133 §k-sweep). On the void-heavy production ladder
// k = 16 cut CG iterations 48.1% against 30.9% at k = 8, while k = 24 cut 55.4%
// but LOST the extra on per-iteration correction overhead — the correction costs
// ~8*k*n bytes of streaming traffic per iteration, so the win is not monotone in k
// once the overhead is charged. 16 is the measured optimum, not a round number.
constexpr int kRecycleDefaultDim = 16;

// --- Process-global configuration (public face: fea_set_krylov_recycling etc.)
bool rc_set_enabled(bool enable);   // returns the previous setting
bool rc_enabled();
int rc_set_dim(int k);              // recycle dimension k >= 1; returns previous
int rc_dim();
int rc_set_cycle(int c);            // rebuild the space every c-th solve; >= 1
int rc_cycle();

// EXTRACTION METRIC (research knob; internal, not part of the public API).
//
// The Rayleigh-Ritz that rebuilds the basis solves (B^T A B) y = theta (B^T M B) y.
// true (the DEFAULT) uses M = D, the Jacobi diagonal — which IS the density-ratio
// rescaling of Wang, de Sturler & Paulino 2007. Their point is that across a SIMP
// sequence the element moduli span many orders of magnitude, so an UNSCALED
// extraction ranks directions by raw magnitude rather than by how badly they slow
// the iteration; rescaling by the diagonal fixes that. PCG with M = D is
// identically CG on D^-1/2 A D^-1/2, so targeting the small eigenvalues of the
// PENCIL (A, D) targets the small eigenvalues of exactly the operator CG sees.
// The rescaling is therefore already delivered by construction, not bolted on.
// false selects the unscaled (identity-metric) extraction, so the claim can be
// MEASURED rather than asserted (handoff 133 reports both).
bool rc_set_metric_diagonal(bool use_diagonal);
bool rc_metric_diagonal();

// WRAP-THE-V-CYCLE. Public face: fea_set_krylov_recycle_wrap_multigrid.
// false (the DEFAULT, and the armed production posture) restricts the correction
// to the Jacobi-preconditioned loop; true wraps WHICHEVER preconditioner runs,
// including the multigrid V-cycle — the behaviour handoff 133 built and measured
// before the maintainer ruled on §10.
//
// WHY THE KNOB EXISTS: handoff 133 §10 measured the additive form REGRESSING in
// the healthy-multigrid regime. The mechanism is the +1 spectral lift. It is
// exactly right when M is weak (Jacobi: the deflated mode's preconditioned
// eigenvalue was near 0, so +1 lands it near 1) and WIDENS the spectrum when M is
// strong (a V-cycle: the mode was already near 1, so +1 lands it near 2). With
// this false the multigrid regime is baseline BY CONSTRUCTION — no session, no
// setup matvecs, no correction — so the two regimes are armed independently.
// Measured at exactly 1.000x with zero setup matvecs (handoff 133 §10).
bool rc_set_wrap_multigrid(bool enable);
bool rc_wrap_multigrid();

// --- Thread-local carried state (public face: fea_reset_krylov_recycle_space) --
void rc_reset_space();
bool rc_space_active();             // a usable basis is currently carried
int rc_space_dim();                 // its column count (0 when none)
std::size_t rc_space_bytes();       // its persistent footprint in bytes

// One solve's participation in recycling. Construct it inside a CG loop right
// after the reduced system is known; every method is a cheap no-op when
// recycling is off, so the call sites stay unconditional and readable.
//
// Call order:
//   RecycleSession s(n, invdiag, applyA);   // k setup matvecs (charged)
//   ... per CG iteration, after the base preconditioner produced z from r:
//   s.augment(r, z);                        // z += U E^-1 (U^T r)
//   s.observe(iter, p, Ap);                 // sample this direction (free)
//   ... at the end, only if the solve is one we trust:
//   s.commit();                             // Rayleigh-Ritz -> new carried U
class RecycleSession {
 public:
  // `apply_a(x, y)` must compute y = A x over n doubles; it is the SAME operator
  // the CG loop iterates with. `invdiag` is the Jacobi inverse diagonal of A on
  // the same n DOFs (the metric D = 1/invdiag for the Ritz extraction) — it may
  // be null, in which case the identity metric is used.
  //
  // Setup runs only when recycling is enabled AND a carried basis matches n. It
  // costs k matvecs; if the resulting E = U^T A U is not positive definite the
  // carried basis is dropped and the session falls back to inactive (the solve
  // then runs exactly as it would without recycling).
  // `allowed` lets a call site opt OUT entirely (see rc_set_wrap_multigrid): with
  // it false the session is completely inert — no state touched, no matvecs, no
  // allocation — so that solve is byte-identical to a recycling-off one.
  template <typename ApplyA>
  RecycleSession(int n, const double* invdiag, ApplyA&& apply_a,
                 bool allowed = true)
      : n_(n) {
    if (!allowed) return;
    begin(n, invdiag);
    if (want_setup_) setup(std::forward<ApplyA>(apply_a));
  }
  ~RecycleSession();

  RecycleSession(const RecycleSession&) = delete;
  RecycleSession& operator=(const RecycleSession&) = delete;

  // True iff the additive coarse correction is live this solve.
  bool active() const { return active_; }
  // True iff this solve is a harvesting one (observe/commit will do work).
  bool harvesting() const { return harvesting_; }
  // Columns in use this solve (0 when inactive) and matvecs charged to setup.
  int dim() const { return active_ ? k_ : 0; }
  int setup_matvecs() const { return setup_matvecs_; }

  // z += U E^{-1} (U^T r), the additive coarse correction. No-op when inactive.
  void augment(const double* r, double* z) const;

  // Offer CG's search direction p and its operator image ap = A p at 0-based
  // iteration `it`. Stored only on the decimating ring's schedule; no-op when not
  // harvesting.
  void observe(int it, const double* p, const double* ap);

  // Rebuild the carried basis from [U | harvested]. Call ONLY after a solve that
  // reached its tolerance — a stagnated or broken-down solve's directions are not
  // evidence about the operator's slow modes. No-op when not harvesting.
  void commit();

 private:
  void begin(int n, const double* invdiag);
  bool setup_finish(std::vector<double>& e);  // shared tail of setup()

  // ONE column of A*U at a time, so setup never holds a k-column FP64 buffer:
  // the exact FP64 image feeds E immediately and is then kept only as float (and
  // only when this solve harvests, where commit() needs it for B^T A B).
  template <typename ApplyA>
  void setup(ApplyA&& apply_a) {
    const int n = n_, k = k_;
    std::vector<double> col(static_cast<std::size_t>(n));
    std::vector<double> aw(static_cast<std::size_t>(n));
    std::vector<double> e(static_cast<std::size_t>(k) * k, 0.0);
    if (harvesting_)
      hau_.assign(static_cast<std::size_t>(n) * static_cast<std::size_t>(k),
                  0.0f);
    for (int j = 0; j < k; ++j) {
      promote_column(j, col.data());
      apply_a(col.data(), aw.data());
      ++setup_matvecs_;
      for (int i = 0; i < k; ++i)
        e[static_cast<std::size_t>(i) * k + j] = column_dot(i, aw.data());
      if (harvesting_) {
        float* dst = hau_.data() + static_cast<std::size_t>(j) * n;
        for (int t = 0; t < n; ++t) dst[t] = static_cast<float>(aw[t]);
      }
    }
    active_ = setup_finish(e);
    if (!active_) hau_.clear();
  }

  // U column j (float, carried) -> `out` (n doubles).
  void promote_column(int j, double* out) const;
  // sum_t U[j][t] * v[t], chunked in the module's fixed accumulation order.
  double column_dot(int j, const double* v) const;

  int n_ = 0;
  int k_ = 0;
  bool want_setup_ = false;
  bool active_ = false;
  bool harvesting_ = false;
  int setup_matvecs_ = 0;
  const double* invdiag_ = nullptr;  // metric D = 1/invdiag (null => identity)

  // E^{-1} as a lower Cholesky factor (k x k, row-major lower triangle).
  std::vector<double> echol_;
  // Scratch for augment(), mutable so augment() stays const: the k-vector c, and
  // the per-chunk partial dots the threaded pass writes and the fixed-order
  // reduction then sums (this is what keeps augment bit-identical across thread
  // counts). The chunk-local expansion accumulator lives on the worker stack.
  mutable std::vector<double> cvec_;
  mutable std::vector<double> partials_;

  // Harvest storage: A*U (float, k columns) plus the decimating ring of m
  // (p, A p) pairs. All three exist only during a harvesting solve.
  std::vector<float> hau_;
  int m_ = 0;
  int stride_ = 1;
  int stored_ = 0;   // total stores so far (slot = stored_ % m_)
  int filled_ = 0;   // slots actually written (min(stored_, m_))
  std::vector<float> hp_;
  std::vector<float> hap_;
};

}  // namespace fea_detail
}  // namespace topopt
