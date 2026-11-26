// Stage 5 (faster solves), S-05: the per-element energy and sensitivity loop of
// simp_compliance (core/src/simp/to_solve.cpp) runs on every matrix-free worker.
// Each element writes only its own term, and the compliance is summed serially
// in ascending voxel order, so the result must not depend on the thread count.
//
// Checks, on a graded density with void, solved by the matrix-free multigrid
// (the production solver) and by Jacobi-CG:
//   * compliance and every sensitivity are IDENTICAL BYTES at 1, 3 and 6 threads;
//   * the compliance equals f . u (the energy identity) to 1e-9;
//   * one sensitivity matches a central finite difference of the compliance.

#include "topopt/fea.hpp"
#include "topopt/simp.hpp"
#include "topopt/voxel.hpp"

#include <cmath>
#include <cstdio>
#include <cstring>
#include <vector>

using namespace topopt;

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

VoxelGrid make_grid(int nx, int ny, int nz) {
  VoxelGrid g;
  g.nx = nx;
  g.ny = ny;
  g.nz = nz;
  g.spacing = 1.0;
  g.origin = Vec3{0.0, 0.0, 0.0};
  g.tags.assign(static_cast<std::size_t>(nx) * ny * nz, VoxelTag::Interior);
  return g;
}

// A bracket-like density: dense near the support and the load, graded and
// partly void in between.
std::vector<double> density_field(const VoxelGrid& g) {
  std::vector<double> rho(g.voxel_count());
  for (int k = 0; k < g.nz; ++k)
    for (int j = 0; j < g.ny; ++j)
      for (int i = 0; i < g.nx; ++i) {
        const double x = (i + 0.5) / g.nx, z = (k + 0.5) / g.nz, y = (j + 0.5) / g.ny;
        double r = 0.5 + 0.45 * std::sin(7.0 * x + 2.0 * y) * std::cos(5.0 * z);
        if (z < 0.15 || z > 0.85) r = 1.0;
        rho[g.index(i, j, k)] = std::fmin(1.0, std::fmax(0.001, r));
      }
  return rho;
}

void supports_and_load(const VoxelGrid& g, std::vector<DirichletBC>& bcs,
                       std::vector<NodalLoad>& loads) {
  for (int j = 0; j <= g.ny; ++j)
    for (int i = 0; i <= g.nx; ++i)
      for (int c = 0; c < 3; ++c) bcs.push_back({fea_node_index(g, i, j, 0), c, 0.0});
  for (int j = 0; j <= g.ny; ++j)
    for (int i = 0; i <= g.nx; ++i)
      loads.push_back({fea_node_index(g, i, j, g.nz), 0, 0.02});
}

bool same(const SimpCompliance& a, const SimpCompliance& b) {
  return std::memcmp(&a.compliance, &b.compliance, sizeof(double)) == 0 &&
         a.dcompliance.size() == b.dcompliance.size() &&
         std::memcmp(a.dcompliance.data(), b.dcompliance.data(),
                     a.dcompliance.size() * sizeof(double)) == 0;
}

}  // namespace

int main() {
  const VoxelGrid g = make_grid(20, 12, 24);
  const std::vector<double> rho = density_field(g);
  std::vector<DirichletBC> bcs;
  std::vector<NodalLoad> loads;
  supports_and_load(g, bcs, loads);
  SimpParams p;
  p.youngs_modulus = 1000.0;
  p.poisson = 0.39;
  p.penalty = 3.0;
  p.density_min = 1e-3;

  const int prev = fea_set_matfree_threads(1);
  for (SolverKind kind : {SolverKind::MultigridCG_Matfree, SolverKind::JacobiCG}) {
    const char* name = kind == SolverKind::JacobiCG ? "Jacobi-CG" : "matrix-free multigrid";
    std::vector<SimpCompliance> r;
    for (int t : {1, 3, 6}) {
      fea_set_matfree_threads(t);
      fea_matfree_reset_mg_stagnation_latch();
      r.push_back(simp_compliance(g, p, rho, bcs, loads, 1e-10, 0, nullptr, nullptr, kind));
    }
    CHECK(same(r[0], r[1]) && same(r[0], r[2]),
          "compliance and sensitivities are identical bytes at 1, 3 and 6 threads");
    // The energy identity: compliance == f . u for the system solved.
    double fu = 0.0;
    for (const NodalLoad& l : loads) fu += l.value * r[0].solution.at(l.node, l.component);
    const double rel = std::fabs(r[0].compliance - fu) / std::fabs(fu);
    CHECK(rel < 1e-9, "compliance equals f . u");
    // One sensitivity against a central finite difference.
    const std::size_t e = g.index(10, 6, 12);
    const double h = 1e-5;
    std::vector<double> rp = rho, rm = rho;
    rp[e] += h;
    rm[e] -= h;
    fea_matfree_reset_mg_stagnation_latch();
    const double cp = simp_compliance(g, p, rp, bcs, loads, 1e-12, 0, nullptr, nullptr, kind).compliance;
    fea_matfree_reset_mg_stagnation_latch();
    const double cm = simp_compliance(g, p, rm, bcs, loads, 1e-12, 0, nullptr, nullptr, kind).compliance;
    const double fd = (cp - cm) / (2.0 * h);
    const double an = r[0].dcompliance[e];
    const double ferr = std::fabs(fd - an) / std::fmax(1e-30, std::fabs(an));
    CHECK(ferr < 1e-4, "a sensitivity matches its central finite difference");
    std::printf("%s: compliance %.12g, f.u rel diff %.1e, FD rel err %.1e, threads 1/3/6 %s\n",
                name, r[0].compliance, rel, ferr,
                same(r[0], r[1]) && same(r[0], r[2]) ? "identical" : "DIFFER");
  }
  fea_set_matfree_threads(prev);
  std::printf("%d checks, %d failures\n", g_checks, g_failures);
  return g_failures == 0 ? 0 : 1;
}
