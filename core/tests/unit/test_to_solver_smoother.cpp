// Stage 5 (faster solves), B-05: the stable smoothers behind TOPOPT_SOLVER.
//
// Today's damped Jacobi uses a fixed weight 0.6, which only settles while the
// level's lambda_max(D^-1 A) stays under 3.33; his parts measure 4.4 to 9.9, so
// the shipped cycle grows the error, latches off and every solve runs on the
// l1 retry (stage file, section 1). Stage 5 adds two smoothers that are stable
// whatever lambda is: Jacobi weighted F / lambda per level, and 4th-kind
// Chebyshev of degree K. Both are selected by the stage switch TOPOPT_SOLVER
// ("jacobi:F", "cheb:K"); unset, the solver is today's, byte for byte.
//
// Two blocks, both with a graded modulus (ripple and a soft band, neighbours up
// to ~200x apart): Poisson 0.3 (lambda about 3: today's weight is stable) and
// Poisson 0.39, his material's, where today's weight is past its bound.
//
// Checks, for every setting at three values each (Jacobi F = 1.0 / 1.333 / 1.6,
// Chebyshev K = 2 / 3 / 4):
//   * the solve converges ON MULTIGRID, without the l1 safe retry;
//   * the answer matches a tight Jacobi-CG reference in the energy norm;
//   * a repeat after an unrelated solve gives identical bytes (test K);
//   * the switch is inert unset, at "today" and at a value it does not
//     understand (identical bytes to today's solver), and the caller's tuning
//     is back after every switched solve.

#include "topopt/fea.hpp"
#include "topopt/voxel.hpp"

#include "fea/fea_matfree.hpp"

#include <algorithm>
#include <cmath>
#include <cstddef>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
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

constexpr double kTol = 1e-4;

// One thread, no algebraic level, no GenEO or recycling, latches reset; the
// safe retry ON (as production), so a stall would show as an engagement.
struct Posture {
  int prev_threads = 0;
  bool prev_alg = false, prev_geneo = false, prev_recycling = false;
  bool prev_safe = false;
  Posture() {
    prev_threads = topopt::fea_set_matfree_threads(1);
    prev_alg = topopt::fea_set_mg_algebraic_level1(false);
    prev_geneo = topopt::fea_set_geneo_twolevel(false);
    prev_recycling = topopt::fea_set_krylov_recycling(false);
    prev_safe = topopt::fea_matfree_mg_safe_retry_enabled();
    topopt::fea_matfree_set_mg_safe_retry(true);
    topopt::fea_matfree_reset_mg_stagnation_latch();
    topopt::fea_matfree_reset_mg_safe_failures();
    unsetenv("TOPOPT_SOLVER");
  }
  ~Posture() {
    unsetenv("TOPOPT_SOLVER");
    topopt::fea_matfree_reset_mg_stagnation_latch();
    topopt::fea_matfree_reset_mg_safe_failures();
    topopt::fea_matfree_set_mg_safe_retry(prev_safe);
    topopt::fea_set_krylov_recycling(prev_recycling);
    topopt::fea_set_geneo_twolevel(prev_geneo);
    topopt::fea_set_mg_algebraic_level1(prev_alg);
    topopt::fea_set_matfree_threads(prev_threads);
  }
};

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

std::vector<double> graded_moduli(const VoxelGrid& g, double emin, double emax) {
  std::vector<double> E(g.voxel_count());
  const double lr = std::log(emax / emin);
  for (int k = 0; k < g.nz; ++k)
    for (int j = 0; j < g.ny; ++j)
      for (int i = 0; i < g.nx; ++i) {
        const double z = (k + 0.5) / g.nz, x = (i + 0.5) / g.nx, y = (j + 0.5) / g.ny;
        double s = 0.55 * z + 0.25 * (0.5 + 0.5 * std::sin(12.0 * x + 3.0 * y)) +
                   0.2 * (0.5 + 0.5 * std::cos(9.0 * z + 5.0 * x));
        if (std::fabs(z - 0.5) < 0.06) s *= 0.15;
        s = std::clamp(s, 0.0, 1.0);
        E[g.index(i, j, k)] = emin * std::exp(lr * s);
      }
  return E;
}

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

double energy_rel_diff(const VoxelGrid& g, const std::vector<double>& E, double nu,
                       const std::vector<double>& u, const std::vector<double>& v) {
  std::vector<double> d(u.size());
  for (std::size_t i = 0; i < u.size(); ++i) d[i] = u[i] - v[i];
  const std::vector<double> Kd = topopt::fea_matfree_apply(g, E, nu, d);
  const std::vector<double> Kv = topopt::fea_matfree_apply(g, E, nu, v);
  return std::sqrt(std::max(0.0, dot(d, Kd)) / std::max(1e-300, dot(v, Kv)));
}

struct Case {
  const char* name;
  VoxelGrid g;
  std::vector<double> E;
  double nu;
  std::vector<DirichletBC> bcs;
  std::vector<NodalLoad> loads;
};

// One multigrid solve with TOPOPT_SOLVER = `setting` (nullptr = unset).
struct Run {
  bool ok = false;
  FeaSolution sol;
  CgInfo info;
  long long safe_engagements = 0;  // l1 retries this solve ran
};

Run solve(const Case& c, const char* setting) {
  Run r;
  if (setting != nullptr) setenv("TOPOPT_SOLVER", setting, 1);
  else unsetenv("TOPOPT_SOLVER");
  topopt::fea_matfree_reset_mg_stagnation_latch();
  topopt::fea_matfree_reset_mg_safe_failures();
  const long long e0 = topopt::fea_matfree_mg_safe_engagements();
  try {
    topopt::FeaLoosePieceRuleOff loose_rule_off;
    r.sol = topopt::fea_solve_mgcg_matfree(c.g, c.E, c.nu, c.bcs, c.loads, kTol, 20000,
                                           &r.info, nullptr, nullptr);
    r.ok = true;
  } catch (const std::exception& e) {
    std::fprintf(stderr, "  %s %s threw: %s\n", c.name, setting ? setting : "(today)",
                 e.what());
  }
  r.safe_engagements = topopt::fea_matfree_mg_safe_engagements() - e0;
  unsetenv("TOPOPT_SOLVER");
  return r;
}

bool same_bytes(const FeaSolution& a, const FeaSolution& b) {
  return a.u.size() == b.u.size() &&
         std::memcmp(a.u.data(), b.u.data(), a.u.size() * sizeof(double)) == 0;
}

bool tuning_is_default() {
  const topopt::fea_detail::MgTuning& t = topopt::fea_detail::mg_tuning();
  const topopt::fea_detail::MgTuning d;
  return t.smoother == d.smoother && t.omega == d.omega &&
         t.omega_over_lambda == d.omega_over_lambda && t.cheb_degree == d.cheb_degree &&
         t.lambda_safety == d.lambda_safety && t.lambda_iters == d.lambda_iters;
}

}  // namespace

int main() {
  Posture posture;
  std::vector<Case> cases;
  {
    Case c{"graded block, Poisson 0.3", make_grid(32, 9, 30, 1.5), {}, 0.3, {}, {}};
    c.E = graded_moduli(c.g, 0.16, 34.0);
    supports_and_press(c.g, 40.0, c.bcs, c.loads);
    cases.push_back(std::move(c));
  }
  {
    Case c{"graded block, Poisson 0.39", make_grid(24, 16, 24, 1.4), {}, 0.39, {}, {}};
    c.E = graded_moduli(c.g, 1.6, 1600.0);
    supports_and_press(c.g, 50.0, c.bcs, c.loads);
    cases.push_back(std::move(c));
  }

  const char* settings[] = {"jacobi:1.0", "jacobi:1.333", "jacobi:1.6",
                            "cheb:2",     "cheb:3",       "cheb:4"};

  for (const Case& c : cases) {
    std::printf("%s: grid %d x %d x %d\n", c.name, c.g.nx, c.g.ny, c.g.nz);
    // The reference: Jacobi-only CG to 1e-10.
    FeaSolution ref;
    CgInfo rinfo;
    bool ref_ok = false;
    try {
      topopt::FeaLoosePieceRuleOff loose_rule_off;
      ref = topopt::fea_solve_cg_matfree(c.g, c.E, c.nu, c.bcs, c.loads, 1e-10, 400000,
                                         &rinfo, nullptr, nullptr);
      ref_ok = true;
    } catch (const std::exception& e) {
      std::fprintf(stderr, "  reference threw: %s\n", e.what());
    }
    CHECK(ref_ok, "the tight Jacobi-CG reference converges");
    if (!ref_ok) continue;

    const Run today = solve(c, nullptr);
    CHECK(today.ok, "today's solver solves the block");
    std::printf("  today:        %s, %d iterations, %lld l1 retries\n",
                today.info.used_multigrid ? "multigrid" : "Jacobi-CG fallback",
                today.info.iterations, today.safe_engagements);

    for (const char* s : settings) {
      const Run r = solve(c, s);
      CHECK(r.ok, "the stage-5 smoother converges");
      CHECK(r.info.used_multigrid, "the stage-5 smoother converges ON MULTIGRID");
      CHECK(r.safe_engagements == 0, "the stage-5 smoother never needs the l1 retry");
      CHECK(tuning_is_default(), "the caller's tuning is back after a switched solve");
      const double d = r.ok ? energy_rel_diff(c.g, c.E, c.nu, r.sol.u, ref.u) : 1.0;
      CHECK(d < 5e-3, "the stage-5 answer matches the tight reference (energy norm)");
      std::printf("  %-12s  %s, %d iterations, %lld l1 retries, energy diff %.2e\n", s,
                  r.info.used_multigrid ? "multigrid" : "Jacobi-CG fallback",
                  r.info.iterations, r.safe_engagements, d);
    }

    // Test K: a repeat after an unrelated solve gives identical bytes.
    const Run a = solve(c, "cheb:2");
    const Run other = solve(c, "jacobi:1.6");
    const Run b = solve(c, "cheb:2");
    CHECK(a.ok && other.ok && b.ok && same_bytes(a.sol, b.sol) &&
              a.info.iterations == b.info.iterations,
          "a repeat after an unrelated solve gives identical bytes");

    // The switch is inert unset, at "today" and at values it does not understand.
    const Run t2 = solve(c, "today");
    const Run bad1 = solve(c, "jacobi:2.5");
    const Run bad2 = solve(c, "chebyshev");
    CHECK(today.ok && t2.ok && same_bytes(today.sol, t2.sol),
          "TOPOPT_SOLVER=today is today's solver, byte for byte");
    CHECK(today.ok && bad1.ok && same_bytes(today.sol, bad1.sol),
          "an out-of-range weight runs today's solver, byte for byte");
    CHECK(today.ok && bad2.ok && same_bytes(today.sol, bad2.sol),
          "an unknown value runs today's solver, byte for byte");
    CHECK(tuning_is_default(), "the tuning is the default after every solve");
  }

  std::printf("%d checks, %d failures\n", g_checks, g_failures);
  return g_failures == 0 ? 0 : 1;
}
