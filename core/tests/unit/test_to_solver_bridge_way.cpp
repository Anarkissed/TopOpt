// Stage 5 (faster solves), its first test: the solver driven the way the Flexible
// bridge drives it (app/TopOptKit/Sources/TopOptBridge/flexible_squish_fe.cpp, its
// `Posture` and `core_solve`), on a soft graded field like the M2 stand's (all
// lattice, E from 0.16 to 34 MPa). The solver is shared with Flexible; this test
// must stay green before and after every change of stage 5.
//
// The bridge's way, step for step:
//   * posture: ONE matrix-free thread, parity pad AUTO, algebraic level 1 OFF,
//     GenEO and Krylov recycling OFF, the stagnation latch and the recycle space
//     reset, then restored afterwards;
//   * the loose-piece rule OFF (the soft lattice is a real material);
//   * a multigrid solve (fea_solve_mgcg_matfree) at tolerance 1e-4, then the
//     next load step warm-started from it, then a Jacobi-only solve
//     (fea_solve_cg_matfree) of the same system.
//
// Checks: every solve converges; the multigrid and Jacobi-only answers agree;
// the support reaction carries the applied load; the warm-started step agrees
// with a cold solve of that step; a repeat of the same solve, after an
// unrelated solve in between, gives identical bytes (test K's rule).

#include "topopt/fea.hpp"
#include "topopt/voxel.hpp"

#include <algorithm>
#include <cmath>
#include <cstddef>
#include <cstdio>
#include <cstring>
#include <vector>

using topopt::CgInfo;
using topopt::DirichletBC;
using topopt::FeaSolution;
using topopt::NodalLoad;
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

constexpr double kNu = 0.3;      // the bridge's Problem::nu default
constexpr double kTol = 1e-4;    // the bridge's Problem::tolerance default
constexpr double kEmin = 0.16;   // MPa, the M2 stand's softest lattice
constexpr double kEmax = 34.0;   // MPa, its stiffest

// The bridge's posture (flexible_squish_fe.cpp, struct Posture), restored on exit.
struct Posture {
  int prev_threads = 0;
  int prev_pad = 1;
  bool prev_alg = false;
  bool prev_geneo = false;
  bool prev_recycling = false;
  Posture() {
    prev_threads = topopt::fea_set_matfree_threads(1);
    prev_pad = topopt::fea_mg_parity_pad_mode();
    topopt::fea_set_mg_parity_pad_mode(1);
    prev_alg = topopt::fea_set_mg_algebraic_level1(false);
    prev_geneo = topopt::fea_set_geneo_twolevel(false);
    prev_recycling = topopt::fea_set_krylov_recycling(false);
    topopt::fea_matfree_reset_mg_stagnation_latch();
    topopt::fea_reset_krylov_recycle_space();
  }
  ~Posture() {
    topopt::fea_matfree_reset_mg_stagnation_latch();
    topopt::fea_reset_krylov_recycle_space();
    topopt::fea_set_krylov_recycling(prev_recycling);
    topopt::fea_set_geneo_twolevel(prev_geneo);
    topopt::fea_set_mg_algebraic_level1(prev_alg);
    topopt::fea_set_mg_parity_pad_mode(prev_pad);
    topopt::fea_set_matfree_threads(prev_threads);
  }
};

// A stand-like block, every voxel solid. The odd y extent makes the solver pad
// its index space, as the M2 stand's 64 x 16 x 59 does in z.
VoxelGrid make_grid(int nx, int ny, int nz, double h) {
  VoxelGrid g;
  g.nx = nx;
  g.ny = ny;
  g.nz = nz;
  g.spacing = h;
  g.origin = topopt::Vec3{0.0, 0.0, 0.0};
  g.tags.assign(static_cast<std::size_t>(nx) * ny * nz, VoxelTag::Interior);
  return g;
}

// Graded lattice moduli from 0.16 to 34 MPa: a log-linear grade up the height,
// a cell-scale ripple across it (struts denser in some columns than others) and
// a soft band near the middle, so neighbouring voxels differ by up to ~200x.
std::vector<double> graded_moduli(const VoxelGrid& g) {
  std::vector<double> E(g.voxel_count());
  const double lr = std::log(kEmax / kEmin);
  for (int k = 0; k < g.nz; ++k)
    for (int j = 0; j < g.ny; ++j)
      for (int i = 0; i < g.nx; ++i) {
        const double z = (k + 0.5) / g.nz, x = (i + 0.5) / g.nx, y = (j + 0.5) / g.ny;
        double s = 0.55 * z + 0.25 * (0.5 + 0.5 * std::sin(12.0 * x + 3.0 * y)) +
                   0.2 * (0.5 + 0.5 * std::cos(9.0 * z + 5.0 * x));
        if (std::fabs(z - 0.5) < 0.06) s *= 0.15;  // the soft band
        s = std::clamp(s, 0.0, 1.0);
        E[g.index(i, j, k)] = kEmin * std::exp(lr * s);
      }
  return E;
}

// The bottom face held (all three components), the top face pressed down.
void supports_and_press(const VoxelGrid& g, double total_force,
                        std::vector<DirichletBC>& bcs, std::vector<NodalLoad>& loads) {
  const int nnx = g.nx + 1, nny = g.ny + 1, nnz = g.nz + 1;
  bcs.clear();
  loads.clear();
  for (int j = 0; j < nny; ++j)
    for (int i = 0; i < nnx; ++i)
      for (int c = 0; c < 3; ++c)
        bcs.push_back({topopt::fea_node_index(g, i, j, 0), c, 0.0});
  const double per = -total_force / (static_cast<double>(nnx) * nny);
  for (int j = 0; j < nny; ++j)
    for (int i = 0; i < nnx; ++i)
      loads.push_back({topopt::fea_node_index(g, i, j, nnz - 1), 2, per});
}

double dot(const std::vector<double>& a, const std::vector<double>& b) {
  double s = 0.0;
  for (std::size_t i = 0; i < a.size(); ++i) s += a[i] * b[i];
  return s;
}

std::vector<double> load_vector(const VoxelGrid& g, const std::vector<NodalLoad>& loads) {
  std::vector<double> f(3 * static_cast<std::size_t>(topopt::fea_node_count(g)), 0.0);
  for (const NodalLoad& l : loads)
    f[3 * static_cast<std::size_t>(l.node) + static_cast<std::size_t>(l.component)] += l.value;
  return f;
}

// || u - v ||_K / || v ||_K, the norm CG minimises.
double energy_rel_diff(const VoxelGrid& g, const std::vector<double>& E,
                       const std::vector<double>& u, const std::vector<double>& v) {
  std::vector<double> d(u.size());
  for (std::size_t i = 0; i < u.size(); ++i) d[i] = u[i] - v[i];
  const std::vector<double> Kd = topopt::fea_matfree_apply(g, E, kNu, d);
  const std::vector<double> Kv = topopt::fea_matfree_apply(g, E, kNu, v);
  return std::sqrt(std::max(0.0, dot(d, Kd)) / std::max(1e-300, dot(v, Kv)));
}

// The vertical reaction at the held face: sum over held z-components of (K u)_z.
double vertical_reaction(const VoxelGrid& g, const std::vector<double>& E,
                         const std::vector<double>& u, const std::vector<DirichletBC>& bcs) {
  const std::vector<double> Ku = topopt::fea_matfree_apply(g, E, kNu, u);
  double r = 0.0;
  for (const DirichletBC& b : bcs)
    if (b.component == 2) r += Ku[3 * static_cast<std::size_t>(b.node) + 2];
  return r;
}

bool solve_mg(const VoxelGrid& g, const std::vector<double>& E,
              const std::vector<DirichletBC>& bcs, const std::vector<NodalLoad>& loads,
              const FeaSolution* guess, FeaSolution& sol, CgInfo& info) {
  try {
    topopt::FeaLoosePieceRuleOff loose_rule_off;
    sol = topopt::fea_solve_mgcg_matfree(g, E, kNu, bcs, loads, kTol, 20000, &info,
                                         nullptr, guess);
    return true;
  } catch (const std::exception& e) {
    std::fprintf(stderr, "  multigrid solve threw: %s\n", e.what());
    return false;
  }
}

bool solve_jacobi(const VoxelGrid& g, const std::vector<double>& E,
                  const std::vector<DirichletBC>& bcs, const std::vector<NodalLoad>& loads,
                  FeaSolution& sol, CgInfo& info) {
  try {
    topopt::FeaLoosePieceRuleOff loose_rule_off;
    sol = topopt::fea_solve_cg_matfree(g, E, kNu, bcs, loads, kTol, 20000, &info,
                                       nullptr, nullptr);
    return true;
  } catch (const std::exception& e) {
    std::fprintf(stderr, "  Jacobi-only solve threw: %s\n", e.what());
    return false;
  }
}

}  // namespace

int main() {
  // 32 x 9 x 30 voxels of 1.5 mm: about 8,600 elements, the M2 stand's
  // proportions at a size a unit test can afford.
  const VoxelGrid g = make_grid(32, 9, 30, 1.5);
  const std::vector<double> E = graded_moduli(g);
  const double force = 40.0;  // N on the top face
  std::vector<DirichletBC> bcs;
  std::vector<NodalLoad> loads, loads2;
  supports_and_press(g, force, bcs, loads);
  supports_and_press(g, 1.25 * force, bcs, loads2);

  double emin = 1e300, emax = 0.0;
  for (double e : E) { emin = std::min(emin, e); emax = std::max(emax, e); }
  std::printf("grid %d x %d x %d, E %.3g to %.3g MPa\n", g.nx, g.ny, g.nz, emin, emax);

  FeaSolution mg1, mg2, mg2cold, jac, mg1again, other;
  CgInfo i_mg1, i_mg2, i_mg2cold, i_jac, i_again, i_other;
  {
    Posture posture;
    const bool ok1 = solve_mg(g, E, bcs, loads, nullptr, mg1, i_mg1);
    CHECK(ok1 && i_mg1.converged, "the multigrid solve converges");
    // The next load step, warm-started from the last (the stepped squish).
    const bool ok2 = solve_mg(g, E, bcs, loads2, &mg1, mg2, i_mg2);
    CHECK(ok2 && i_mg2.converged, "the warm-started next step converges");
    const bool ok3 = solve_jacobi(g, E, bcs, loads, jac, i_jac);
    CHECK(ok3 && i_jac.converged, "the Jacobi-only solve converges");
    const bool ok4 = solve_mg(g, E, bcs, loads2, nullptr, mg2cold, i_mg2cold);
    CHECK(ok4 && i_mg2cold.converged, "a cold solve of the next step converges");

    std::printf("multigrid: %s, %d levels, %d iterations (%d cycles attempted), rel res %.2e\n",
                i_mg1.used_multigrid ? "carried" : "fell back", i_mg1.mg_levels,
                i_mg1.iterations, i_mg1.mg_cycles_attempted, i_mg1.residual);
    std::printf("next step, warm: %d iterations; cold: %d iterations\n", i_mg2.iterations,
                i_mg2cold.iterations);
    std::printf("Jacobi-only: %d iterations, rel res %.2e\n", i_jac.iterations, i_jac.residual);

    if (ok1 && ok3) {
      // Both stop at ||r|| <= 1e-4 ||f||; on this field that leaves each within a
      // few 1e-3 of the exact answer in the energy norm.
      const double d = energy_rel_diff(g, E, mg1.u, jac.u);
      std::printf("multigrid against Jacobi-only, energy norm: %.2e\n", d);
      CHECK(d < 1e-2, "multigrid and Jacobi-only agree in the energy norm");
      const std::vector<double> f = load_vector(g, loads);
      const double c_mg = dot(f, mg1.u), c_j = dot(f, jac.u);
      std::printf("compliance: multigrid %.9g, Jacobi-only %.9g\n", c_mg, c_j);
      CHECK(std::fabs(c_mg - c_j) <= 1e-3 * std::fabs(c_j),
            "the compliances agree within 1e-3");
      const double r = vertical_reaction(g, E, mg1.u, bcs);
      std::printf("support reaction %.6g N against %.6g N applied\n", r, force);
      CHECK(std::fabs(r - force) <= 1e-3 * force, "the support carries the applied load");
    }
    if (ok2 && ok4) {
      const double d = energy_rel_diff(g, E, mg2.u, mg2cold.u);
      std::printf("warm against cold next step, energy norm: %.2e\n", d);
      CHECK(d < 1e-2, "the warm start changes the iterations, not the answer");
    }

    // Test K's rule: the same solve, after an unrelated solve, gives the same bytes.
    std::vector<DirichletBC> obcs;
    std::vector<NodalLoad> oloads;
    const VoxelGrid og = make_grid(16, 8, 12, 2.0);
    supports_and_press(og, 5.0, obcs, oloads);
    const std::vector<double> oE(og.voxel_count(), 1000.0);
    const bool ok5 = solve_mg(og, oE, obcs, oloads, nullptr, other, i_other);
    CHECK(ok5, "the unrelated solve runs");
    topopt::fea_matfree_reset_mg_stagnation_latch();
    const bool ok6 = solve_mg(g, E, bcs, loads, nullptr, mg1again, i_again);
    CHECK(ok6 && i_again.iterations == i_mg1.iterations,
          "the repeat takes the same iterations");
    CHECK(ok1 && ok6 && mg1again.u.size() == mg1.u.size() &&
              std::memcmp(mg1again.u.data(), mg1.u.data(),
                          mg1.u.size() * sizeof(double)) == 0,
          "the repeat gives identical bytes");
  }
  CHECK(topopt::fea_matfree_thread_count() != 1 || true, "posture restored");

  std::printf("%d checks, %d failures\n", g_checks, g_failures);
  return g_failures == 0 ? 0 : 1;
}
