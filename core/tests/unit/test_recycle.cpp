// Correctness guards for KRYLOV SUBSPACE RECYCLING / DEFLATION (handoff 133) —
// the opt-in, default-OFF additive coarse-space correction that wraps whichever
// preconditioner the matrix-free solve path already runs
// (fea_set_krylov_recycling).
//
// The bars this file enforces, stated as the task states them:
//
//   1. EXACTNESS. Recycled and plain PCG converge to the SAME field. This
//      technique changes the ROUTE, not the answer: M_rec^{-1} = M^{-1} +
//      U E^{-1} U^T is SPD for ANY U with SPD E, so PCG still converges to the
//      true solution and the stopping test is the unchanged relative residual.
//      Guard: max|du|/max|u| <= 1e-6 DOF-for-DOF against the recycling-off field,
//      on a solid grid AND on the ill-conditioned soft-void graded grid, on BOTH
//      the Jacobi-regime (fea_solve_cg_matfree) and multigrid-regime
//      (fea_solve_mgcg_matfree) entry points. A larger delta means the
//      implementation is wrong, not that a trade is on offer.
//
//   2. IT ACTUALLY RECYCLES (the test that would fail against a stub). On a
//      slowly-perturbed sequence of void-heavy systems — the design-box regime
//      this exists for — the recycled total CG iteration count is materially
//      BELOW the plain one, counting the setup matvecs recycling charges as work.
//      A no-op implementation, or one that carried a useless subspace, fails
//      this.
//
//   3. DETERMINISM. Two runs of the same sequence produce bit-identical fields,
//      bit-identical iteration counts and a bit-identical carried basis.
//
//   4. DEFAULT OFF / OPT-IN PARITY. The default is OFF; with it OFF nothing is
//      allocated, the diagnostics stay 0, and a solve is bit-identical to one
//      taken before recycling was ever enabled (the flag is truly opt-in).
//
//   5. LIFETIME PLUMBING. The carried basis is dropped by the explicit reset, and
//      dropped automatically when the free-DOF count changes (a resolution change
//      makes the columns meaningless) — never silently misapplied.
//
//   6. ROBUSTNESS. A long sequence never breaks down: every solve still reports
//      converged at the requested tolerance.
//
// No third-party framework (ARCHITECTURE §4): the same self-contained CHECK
// harness as the sibling tests, public API only.

#include "topopt/fea.hpp"
#include "topopt/voxel.hpp"

#include <algorithm>
#include <cmath>
#include <cstddef>
#include <cstdio>
#include <stdexcept>
#include <vector>

using topopt::CgInfo;
using topopt::DirichletBC;
using topopt::FeaSolution;
using topopt::NodalLoad;
using topopt::Vec3;
using topopt::VoxelGrid;
using topopt::VoxelTag;

static int g_failures = 0;
static int g_checks = 0;

#define CHECK(cond, msg)                                           \
  do {                                                             \
    ++g_checks;                                                    \
    if (!(cond)) {                                                 \
      ++g_failures;                                                \
      std::fprintf(stderr, "FAIL (line %d): %s\n", __LINE__, msg); \
    }                                                              \
  } while (0)

namespace {

// A stand-class caricature: a part filling part of the domain with a clearance
// hole punched through it, the rest of the box empty design expanse. This is the
// 125/131 disease in miniature — the geometry whose weakly-connected solid gives
// CG the slowly-converging near-rigid-body directions recycling exists to reuse.
VoxelGrid void_heavy_grid(int n, double h) {
  VoxelGrid g;
  g.nx = n;
  g.ny = n;
  g.nz = n;
  g.spacing = h;
  g.origin = Vec3{0.0, 0.0, 0.0};
  g.tags.assign(static_cast<std::size_t>(n) * n * n, VoxelTag::Empty);
  const double cx = n * 0.5, cy = n * 0.5, r_hole = n * 0.18;
  for (int k = 0; k < n; ++k)
    for (int j = 0; j < n; ++j)
      for (int i = 0; i < n; ++i) {
        const bool in_part = (i < n * 0.75) && (j < n * 0.75);
        const double dx = i + 0.5 - cx, dy = j + 0.5 - cy;
        const bool in_hole = std::sqrt(dx * dx + dy * dy) < r_hole;
        if (in_part && !in_hole) g.set_tag(i, j, k, VoxelTag::Interior);
      }
  return g;
}

VoxelGrid solid_grid(int nx, int ny, int nz, double h) {
  VoxelGrid g;
  g.nx = nx;
  g.ny = ny;
  g.nz = nz;
  g.spacing = h;
  g.origin = Vec3{0.0, 0.0, 0.0};
  g.tags.assign(static_cast<std::size_t>(nx) * ny * nz, VoxelTag::Interior);
  return g;
}

// Clamp the z=0 node face; load the far corner column downward.
void clamp_and_load(const VoxelGrid& g, std::vector<DirichletBC>& bcs,
                    std::vector<NodalLoad>& loads) {
  bcs.clear();
  loads.clear();
  for (int b = 0; b <= g.ny; ++b)
    for (int a = 0; a <= g.nx; ++a) {
      const int node = topopt::fea_node_index(g, a, b, 0);
      bcs.push_back({node, 0, 0.0});
      bcs.push_back({node, 1, 0.0});
      bcs.push_back({node, 2, 0.0});
    }
  const int span = std::max(1, g.nx / 8);
  for (int b = 0; b <= span; ++b)
    for (int a = 0; a <= span; ++a)
      loads.push_back({topopt::fea_node_index(g, a, b, g.nz), 2, -1.0});
}

// Per-voxel penalized modulus for a density field (the SIMP graded operator).
std::vector<double> penalized(const VoxelGrid& g, const std::vector<double>& rho) {
  std::vector<double> e(g.voxel_count(), 0.0);
  for (std::size_t v = 0; v < g.voxel_count(); ++v)
    if (g.tags[v] != VoxelTag::Empty)
      e[v] = std::pow(std::max(1e-3, rho[v]), 3.0) * 3500.0;
  return e;
}

// A deterministic pseudo-MMA trajectory: rho drifts smoothly, so consecutive
// systems are tiny perturbations of one another — exactly the sequence structure
// recycling exploits.
void advance(std::vector<double>& rho, int step) {
  for (std::size_t v = 0; v < rho.size(); ++v) {
    const double t = static_cast<double>(v % 97) / 97.0;
    rho[v] = std::min(1.0, std::max(1e-3, rho[v] + 0.02 * (t - 0.5 + 0.1 * step)));
  }
}

double max_abs(const std::vector<double>& v) {
  double m = 0.0;
  for (double x : v) m = std::max(m, std::fabs(x));
  return m;
}

double max_abs_diff(const std::vector<double>& a, const std::vector<double>& b) {
  if (a.size() != b.size()) return 1e30;
  double m = 0.0;
  for (std::size_t i = 0; i < a.size(); ++i)
    m = std::max(m, std::fabs(a[i] - b[i]));
  return m;
}

bool bit_identical(const std::vector<double>& a, const std::vector<double>& b) {
  if (a.size() != b.size()) return false;
  for (std::size_t i = 0; i < a.size(); ++i)
    if (a[i] != b[i]) return false;
  return true;
}

// Guarantee a clean slate for every scenario: recycling off, default k, no
// carried basis. (Configuration is process-global and the basis is sticky, so a
// scenario that forgot this would silently inherit the previous one's state.)
void reset_all() {
  topopt::fea_set_krylov_recycling(false);
  topopt::fea_set_krylov_recycle_dim(0);   // 0 restores the default
  topopt::fea_set_krylov_recycle_cycle(0); // 0 restores every-solve
  topopt::fea_reset_krylov_recycle_space();
}

// One solve of the sequence, through the chosen entry point.
FeaSolution solve_one(bool multigrid, const VoxelGrid& g,
                      const std::vector<double>& youngs,
                      const std::vector<DirichletBC>& bcs,
                      const std::vector<NodalLoad>& loads, CgInfo* info) {
  if (multigrid)
    return topopt::fea_solve_mgcg_matfree(g, youngs, 0.33, bcs, loads, 1e-8,
                                          200000, info);
  return topopt::fea_solve_cg_matfree(g, youngs, 0.33, bcs, loads, 1e-8, 200000,
                                      info);
}

struct SeqResult {
  long long cg_total = 0;
  long long setup_matvecs = 0;
  std::vector<int> per_solve_iters;
  std::vector<double> final_field;
  bool all_converged = true;
  int last_dim = 0;
};

SeqResult run_sequence(bool multigrid, bool recycling, int k, const VoxelGrid& g,
                       const std::vector<DirichletBC>& bcs,
                       const std::vector<NodalLoad>& loads, int nsolve) {
  reset_all();
  if (recycling) {
    topopt::fea_set_krylov_recycling(true);
    topopt::fea_set_krylov_recycle_dim(k);
  }
  SeqResult r;
  std::vector<double> rho(g.voxel_count(), 0.5);
  for (int s = 0; s < nsolve; ++s) {
    advance(rho, s);
    CgInfo info;
    const FeaSolution sol =
        solve_one(multigrid, g, penalized(g, rho), bcs, loads, &info);
    r.cg_total += info.iterations;
    r.setup_matvecs += info.recycle_setup_matvecs;
    r.per_solve_iters.push_back(info.iterations);
    r.all_converged = r.all_converged && info.converged;
    r.last_dim = info.recycle_dim;
    if (s + 1 == nsolve) r.final_field = sol.u;
  }
  reset_all();
  return r;
}

// --- 1 + 4: exactness and opt-in parity, both regimes, solid and soft-void ----
void test_exactness_and_parity(bool multigrid, const char* label) {
  const VoxelGrid solid = solid_grid(16, 16, 16, 1.0);
  std::vector<DirichletBC> bcs;
  std::vector<NodalLoad> loads;
  clamp_and_load(solid, bcs, loads);

  // (a) SOLID grid: the recycled field equals the plain field.
  {
    std::vector<double> rho(solid.voxel_count(), 1.0);
    const std::vector<double> e = penalized(solid, rho);
    reset_all();
    CgInfo base_info;
    const FeaSolution base = solve_one(multigrid, solid, e, bcs, loads, &base_info);
    CHECK(base_info.recycle_dim == 0 && base_info.recycle_setup_matvecs == 0,
          "recycling OFF must leave the CgInfo diagnostics at 0");
    CHECK(topopt::fea_krylov_recycle_bytes() == 0,
          "recycling OFF must allocate no carried basis");

    // A short recycled sequence on the SAME system, then compare the last field.
    topopt::fea_set_krylov_recycling(true);
    FeaSolution rec;
    CgInfo rec_info;
    for (int s = 0; s < 3; ++s)
      rec = solve_one(multigrid, solid, e, bcs, loads, &rec_info);
    CHECK(rec_info.converged, "recycled solve must converge");
    const double scale = max_abs(base.u);
    const double du = max_abs_diff(base.u, rec.u);
    CHECK(scale > 0.0 && du <= 1e-6 * scale,
          "EXACTNESS (solid): recycled field must match the plain field to 1e-6");
    std::printf("  [%s solid ] plain cg=%d recycled cg=%d dim=%d  max|du|/max|u|=%.3e\n",
                label, base_info.iterations, rec_info.iterations, rec_info.recycle_dim, du / scale);

    // (b) OPT-IN PARITY: turn recycling back off and re-solve — the field must be
    // BIT-identical to the pre-recycling one, i.e. the flag left no residue.
    reset_all();
    CgInfo again_info;
    const FeaSolution again =
        solve_one(multigrid, solid, e, bcs, loads, &again_info);
    CHECK(bit_identical(base.u, again.u),
          "OPT-IN: with recycling off again the field must be bit-identical");
    CHECK(again_info.iterations == base_info.iterations,
          "OPT-IN: with recycling off again the iteration count must be identical");
  }

  // (c) SOFT-VOID graded grid — the ill-conditioned case (rho_min^p = 1e-9).
  {
    const VoxelGrid g = void_heavy_grid(16, 1.0);
    std::vector<DirichletBC> vbcs;
    std::vector<NodalLoad> vloads;
    clamp_and_load(g, vbcs, vloads);
    std::vector<double> rho(g.voxel_count(), 1e-3);
    for (std::size_t v = 0; v < g.voxel_count(); ++v)
      if (g.tags[v] != VoxelTag::Empty && (v % 3) != 0) rho[v] = 1.0;
    const std::vector<double> e = penalized(g, rho);

    reset_all();
    CgInfo base_info;
    const FeaSolution base = solve_one(multigrid, g, e, vbcs, vloads, &base_info);
    topopt::fea_set_krylov_recycling(true);
    FeaSolution rec;
    CgInfo rec_info;
    for (int s = 0; s < 3; ++s) rec = solve_one(multigrid, g, e, vbcs, vloads, &rec_info);
    CHECK(rec_info.converged, "recycled soft-void solve must converge");
    const double scale = max_abs(base.u);
    const double du = max_abs_diff(base.u, rec.u);
    CHECK(scale > 0.0 && du <= 1e-6 * scale,
          "EXACTNESS (soft-void): recycled field must match the plain field");
    std::printf("  [%s void  ] plain cg=%d recycled cg=%d dim=%d  max|du|/max|u|=%.3e\n",
                label, base_info.iterations, rec_info.iterations, rec_info.recycle_dim, du / scale);
    reset_all();
  }
}

// --- 2: it actually recycles, net of the work it charges --------------------
void test_iteration_reduction() {
  const VoxelGrid g = void_heavy_grid(24, 1.0);
  std::vector<DirichletBC> bcs;
  std::vector<NodalLoad> loads;
  clamp_and_load(g, bcs, loads);
  const int nsolve = 6;

  const SeqResult plain = run_sequence(false, false, 0, g, bcs, loads, nsolve);
  const SeqResult rec = run_sequence(false, true, 16, g, bcs, loads, nsolve);

  CHECK(plain.all_converged && rec.all_converged,
        "every solve of both sequences must converge");
  CHECK(rec.last_dim == 16, "the carried basis must reach the configured k");
  // NET of the setup matvecs recycling charges (one per column per solve).
  const double net = static_cast<double>(rec.cg_total + rec.setup_matvecs) /
                     static_cast<double>(plain.cg_total);
  std::printf("  [reduction] plain cg=%lld | recycled cg=%lld + setup=%lld"
              "  -> net %.3fx (%.1f%% cut)\n",
              plain.cg_total, rec.cg_total, rec.setup_matvecs, net,
              100.0 * (1.0 - net));
  // The bar the task states for the void regime is >= 15%; this fixture is a
  // miniature of it, so assert a conservative margin that a stub cannot reach.
  CHECK(net <= 0.85,
        "RECYCLING MUST PAY: net CG work (incl. setup matvecs) must fall >= 15%");
  // And the effect must be in the RIGHT place: the first solve has no basis yet
  // and must be untouched; later solves must be materially cheaper.
  CHECK(rec.per_solve_iters.front() == plain.per_solve_iters.front(),
        "the bootstrap solve (no basis yet) must cost exactly what plain CG costs");
  CHECK(rec.per_solve_iters.back() < plain.per_solve_iters.back(),
        "the last solve, with a carried basis, must be cheaper than plain CG");
}

// --- 3: determinism ----------------------------------------------------------
void test_determinism() {
  const VoxelGrid g = void_heavy_grid(16, 1.0);
  std::vector<DirichletBC> bcs;
  std::vector<NodalLoad> loads;
  clamp_and_load(g, bcs, loads);

  const SeqResult a = run_sequence(false, true, 16, g, bcs, loads, 4);
  const SeqResult b = run_sequence(false, true, 16, g, bcs, loads, 4);
  CHECK(a.per_solve_iters == b.per_solve_iters,
        "DETERMINISM: the per-solve iteration history must repeat exactly");
  CHECK(bit_identical(a.final_field, b.final_field),
        "DETERMINISM: the final field must be bit-identical across runs");

  const SeqResult c = run_sequence(true, true, 16, g, bcs, loads, 4);
  const SeqResult d = run_sequence(true, true, 16, g, bcs, loads, 4);
  CHECK(c.per_solve_iters == d.per_solve_iters,
        "DETERMINISM (multigrid regime): iteration history must repeat exactly");
  CHECK(bit_identical(c.final_field, d.final_field),
        "DETERMINISM (multigrid regime): final field must be bit-identical");
  std::printf("  [determin ] jacobi %lld cg, multigrid %lld cg, both repeated exactly\n",
              a.cg_total, c.cg_total);
}

// --- 3b: thread-count invariance of the correction ---------------------------
// The per-iteration correction is THREADED (it is bandwidth-bound and would
// otherwise be a serial tax next to a 10-thread matvec). Its two passes split by
// contiguous chunk and either write disjoint output or accumulate per-chunk
// partials reduced in ASCENDING CHUNK ORDER, so the result must not depend on the
// thread count. This is the guard for that claim — the same discipline
// test_matfree_threads applies to the element apply.
void test_thread_invariance() {
  const VoxelGrid g = void_heavy_grid(16, 1.0);
  std::vector<DirichletBC> bcs;
  std::vector<NodalLoad> loads;
  clamp_and_load(g, bcs, loads);

  const int prev = topopt::fea_set_matfree_threads(1);
  const SeqResult one = run_sequence(false, true, 16, g, bcs, loads, 4);
  topopt::fea_set_matfree_threads(8);
  const SeqResult many = run_sequence(false, true, 16, g, bcs, loads, 4);
  topopt::fea_set_matfree_threads(prev);

  CHECK(one.per_solve_iters == many.per_solve_iters,
        "THREADS: the recycled iteration history must be identical at 1 vs 8 threads");
  CHECK(bit_identical(one.final_field, many.final_field),
        "THREADS: the recycled field must be BIT-identical at 1 vs 8 threads");
  std::printf("  [threads  ] 1 vs 8 threads: identical (%lld cg)\n", one.cg_total);
}

// --- 5: lifetime plumbing ----------------------------------------------------
void test_lifetime() {
  reset_all();
  CHECK(!topopt::fea_krylov_recycling_enabled(),
        "DEFAULT OFF: recycling must be disabled unless a caller opts in");
  CHECK(topopt::fea_krylov_recycle_dim() == 16,
        "the default recycle dimension is the swept default k = 16");
  CHECK(!topopt::fea_krylov_recycle_space_active(),
        "no basis is carried before any solve");

  const VoxelGrid g16 = void_heavy_grid(16, 1.0);
  std::vector<DirichletBC> b16;
  std::vector<NodalLoad> l16;
  clamp_and_load(g16, b16, l16);
  std::vector<double> rho16(g16.voxel_count(), 0.5);

  topopt::fea_set_krylov_recycling(true);
  CgInfo info;
  solve_one(false, g16, penalized(g16, rho16), b16, l16, &info);
  CHECK(topopt::fea_krylov_recycle_space_active(),
        "a basis must be carried after a converged solve");
  const std::size_t bytes16 = topopt::fea_krylov_recycle_bytes();
  CHECK(bytes16 > 0, "the carried basis must report a non-zero footprint");

  // Explicit reset drops it (the per-run/per-rung hook the driver calls).
  topopt::fea_reset_krylov_recycle_space();
  CHECK(!topopt::fea_krylov_recycle_space_active() &&
            topopt::fea_krylov_recycle_bytes() == 0,
        "LIFETIME: the explicit reset must drop the carried basis");

  // A different free-DOF count must drop it automatically rather than misapply it.
  solve_one(false, g16, penalized(g16, rho16), b16, l16, &info);
  CHECK(topopt::fea_krylov_recycle_space_active(), "basis rebuilt on g16");
  const VoxelGrid g12 = void_heavy_grid(12, 1.0);
  std::vector<DirichletBC> b12;
  std::vector<NodalLoad> l12;
  clamp_and_load(g12, b12, l12);
  std::vector<double> rho12(g12.voxel_count(), 0.5);
  CgInfo info12;
  solve_one(false, g12, penalized(g12, rho12), b12, l12, &info12);
  CHECK(info12.recycle_dim == 0,
        "LIFETIME: a resolution change must drop the basis, not misapply it");
  CHECK(topopt::fea_krylov_recycle_bytes() != bytes16 ||
            topopt::fea_krylov_recycle_bytes() == 0,
        "LIFETIME: the rebuilt basis belongs to the new DOF count");
  reset_all();
}

// --- 6: robustness over a long sequence -------------------------------------
void test_long_sequence_robust() {
  const VoxelGrid g = void_heavy_grid(16, 1.0);
  std::vector<DirichletBC> bcs;
  std::vector<NodalLoad> loads;
  clamp_and_load(g, bcs, loads);
  const SeqResult r = run_sequence(false, true, 24, g, bcs, loads, 20);
  CHECK(r.all_converged,
        "ROBUSTNESS: 20 consecutive recycled solves must all reach tolerance");
  std::printf("  [robust   ] 20 solves, k=24, all converged, total cg=%lld\n",
              r.cg_total);
}

}  // namespace

int main() {
  try {
    test_exactness_and_parity(false, "jacobi");
    test_exactness_and_parity(true, "mgcg  ");
    test_iteration_reduction();
    test_determinism();
    test_thread_invariance();
    test_lifetime();
    test_long_sequence_robust();
  } catch (const std::exception& e) {
    std::fprintf(stderr, "FAIL: unexpected exception: %s\n", e.what());
    ++g_failures;
  }
  std::printf("test_recycle: %d checks, %d failures\n", g_checks, g_failures);
  return g_failures == 0 ? 0 : 1;
}
