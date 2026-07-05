// M3.3 validation: a 2D-equivalent MBB slice reproduces the classic Sigmund
// 99-line MBB result pattern using the density filter + Optimality-Criteria
// update (ROADMAP M3.3: "Density filter (radius >= 1.5 voxels) + Optimality
// Criteria update. 2D-equivalent slice reproduces the classic 99-line MBB
// result pattern"). Lives in tests/validation/ per ARCHITECTURE §3 ("analytical
// benchmarks (beam theory, MBB, cantilever)").
//
// This drives the M3.3 operators (make_density_filter, oc_update) together with
// the M3.2 penalized compliance (simp_compliance) in a fixed-length SIMP loop.
// The volume-fraction-targeted loop *with convergence criteria* and the
// fixture-based compliance gate (V2) are M3.4; here we run a fixed number of
// iterations and assert structural properties of the resulting design that are
// the signature of the classic MBB solution and that a broken filter / OC step
// would not produce:
//   * the optimizer substantially reduces compliance from the uniform start,
//   * the volume constraint is met on the physical (filtered) density,
//   * the design is nearly black/white (penalization drives discreteness),
//   * a mid-span I-section forms (solid top+bottom chords, void neutral axis),
//   * material is retained under the load and at the support.
//
// No third-party test framework (ARCHITECTURE §4); the same self-contained CHECK
// harness as the other tests, public API only.

#include "topopt/fea.hpp"
#include "topopt/simp.hpp"
#include "topopt/voxel.hpp"

#include <algorithm>
#include <cmath>
#include <cstddef>
#include <cstdio>
#include <vector>

using topopt::DensityFilter;
using topopt::DirichletBC;
using topopt::NodalLoad;
using topopt::SimpCompliance;
using topopt::SimpParams;
using topopt::VoxelGrid;
using topopt::VoxelTag;

static int g_failures = 0;
static int g_checks = 0;

#define CHECK(cond, msg)                                            \
  do {                                                             \
    ++g_checks;                                                    \
    if (!(cond)) {                                                 \
      ++g_failures;                                                \
      std::fprintf(stderr, "FAIL (line %d): %s\n", __LINE__, msg); \
    }                                                              \
  } while (0)

namespace {

VoxelGrid solid_grid(int nx, int ny, int nz, double h) {
  VoxelGrid g;
  g.nx = nx;
  g.ny = ny;
  g.nz = nz;
  g.spacing = h;
  g.origin = topopt::Vec3{0.0, 0.0, 0.0};
  g.tags.assign(static_cast<std::size_t>(nx) * ny * nz, VoxelTag::Interior);
  return g;
}

}  // namespace

int main() {
  // Classic MBB half-beam: length nx along x, height ny along y, one voxel thick
  // (nz = 1) for a 2D-equivalent plane-strain slice. Standard Sigmund settings:
  // p = 3, volume fraction 0.5, filter radius 1.5 voxels, move limit 0.2.
  const int nx = 60, ny = 20, nz = 1;
  VoxelGrid g = solid_grid(nx, ny, nz, 1.0);

  SimpParams p;
  p.youngs_modulus = 1.0;  // E0 = 1 keeps sensitivities O(1) (Sigmund convention)
  p.poisson = 0.3;
  p.penalty = 3.0;
  p.density_min = 1e-3;
  const double volfrac = 0.5, radius = 1.5, move = 0.2;

  // Boundary conditions:
  //   * plane-strain slice: fix u_z on every node (no out-of-plane strain),
  //   * symmetry plane at x = 0 (beam mid-span): fix u_x on that face,
  //   * roller support at the bottom-right corner (x = nx, y = 0): fix u_y.
  // Together these remove all six rigid-body modes (see handoff 014's gate).
  std::vector<DirichletBC> bcs;
  for (int c = 0; c <= nz; ++c)
    for (int b = 0; b <= ny; ++b)
      for (int a = 0; a <= nx; ++a) {
        const int n = topopt::fea_node_index(g, a, b, c);
        bcs.push_back({n, 2, 0.0});                         // u_z = 0 (2D slice)
        if (a == 0) bcs.push_back({n, 0, 0.0});             // symmetry
        if (a == nx && b == 0) bcs.push_back({n, 1, 0.0});  // roller
      }
  // Downward (-y) load at the top of the symmetry plane (top-left corner), split
  // over the two z-layer nodes so the total is -1.
  std::vector<NodalLoad> loads;
  for (int c = 0; c <= nz; ++c)
    loads.push_back(
        {topopt::fea_node_index(g, 0, ny, c), 1, -1.0 / (nz + 1)});

  DensityFilter filter = topopt::make_density_filter(g, radius);
  std::vector<double> x = topopt::simp_uniform_density(g, volfrac);

  // Compliance of the uniform starting design (all densities = volfrac).
  const double c_init =
      topopt::simp_compliance(g, p, filter.filter_density(x), bcs, loads, 1e-6, 0)
          .compliance;

  // Fixed-length SIMP loop (convergence criteria are M3.4). Each iteration:
  // filter the design, solve the penalized compliance, OC-update the design.
  const int kIters = 60;
  double c_last = 0.0;
  for (int it = 0; it < kIters; ++it) {
    const std::vector<double> xPhys = filter.filter_density(x);
    SimpCompliance r = topopt::simp_compliance(g, p, xPhys, bcs, loads, 1e-6, 0);
    c_last = r.compliance;
    x = topopt::oc_update(g, filter, x, r.dcompliance, volfrac, move,
                          p.density_min);
    if (!r.cg.converged) {
      std::fprintf(stderr, "FAIL: penalized CG did not converge at it %d\n", it);
      ++g_failures;
      ++g_checks;
    }
  }
  const std::vector<double> xPhys = filter.filter_density(x);
  const double c_final =
      topopt::simp_compliance(g, p, xPhys, bcs, loads, 1e-6, 0).compliance;

  // ---- Global statistics of the final physical density field ----------------
  const double n_design = static_cast<double>(g.voxel_count());
  double vol = 0.0, mnd = 0.0, vmin = 1e30, vmax = -1e30;
  for (std::size_t e = 0; e < g.voxel_count(); ++e) {
    vol += xPhys[e];
    mnd += 4.0 * xPhys[e] * (1.0 - xPhys[e]);  // measure of non-discreteness
    vmin = std::min(vmin, xPhys[e]);
    vmax = std::max(vmax, xPhys[e]);
  }
  const double volfrac_final = vol / n_design;
  const double mnd_mean = mnd / n_design;  // 1.0 for the uniform 0.5 start

  // ---- Mid-span I-section: over the left (high-moment) strip, the top+bottom
  //      chord rows are solid and the neutral-axis rows are void ---------------
  const int strip = std::max(1, nx / 8);
  double chord = 0.0, neutral = 0.0;
  int nchord = 0, nneutral = 0;
  for (int i = 0; i < strip; ++i) {
    chord += xPhys[g.index(i, 0, 0)] + xPhys[g.index(i, ny - 1, 0)];
    nchord += 2;
    neutral += xPhys[g.index(i, ny / 2, 0)] + xPhys[g.index(i, ny / 2 - 1, 0)];
    nneutral += 2;
  }
  const double chord_mean = chord / nchord;
  const double neutral_mean = neutral / nneutral;
  const double load_corner = xPhys[g.index(0, ny - 1, 0)];
  const double support_corner = xPhys[g.index(nx - 1, 0, 0)];

  std::printf("MBB slice %dx%dx%d, %d SIMP iterations:\n", nx, ny, nz, kIters);
  std::printf("  compliance %.4g -> %.4g (ratio %.3f)\n", c_init, c_final,
              c_final / c_init);
  std::printf("  volume fraction %.5f (target %.2f)\n", volfrac_final, volfrac);
  std::printf("  discreteness Mnd %.4f (uniform start = 1.0)\n", mnd_mean);
  std::printf("  density range [%.4f, %.4f]\n", vmin, vmax);
  std::printf("  mid-span chord %.3f  neutral %.3f  load %.3f  support %.3f\n",
              chord_mean, neutral_mean, load_corner, support_corner);
  std::printf("  (last in-loop compliance %.4g)\n", c_last);

  // Pattern (top row = y max), for the handoff record.
  std::printf("  pattern:\n");
  for (int j = ny - 1; j >= 0; --j) {
    std::printf("  ");
    for (int i = 0; i < nx; ++i) {
      const double v = xPhys[g.index(i, j, 0)];
      std::putchar(v > 0.75 ? '#' : v > 0.5 ? '+' : v > 0.25 ? '.' : ' ');
    }
    std::putchar('\n');
  }

  // ---- Assertions: the classic MBB signature --------------------------------
  // 1. The optimizer substantially reduces compliance from the uniform start.
  CHECK(c_final < 0.5 * c_init,
        "MBB: optimized compliance is well below the uniform-design compliance");
  // 2. The volume constraint is met on the physical density (OC bisection).
  CHECK(std::fabs(volfrac_final - volfrac) < 5e-3,
        "MBB: physical volume fraction matches the target");
  // 3. The design is nearly black/white (SIMP penalization + filter), far more
  //    discrete than the fully-gray uniform start (Mnd = 1.0).
  CHECK(mnd_mean < 0.5, "MBB: design is substantially discrete (black/white)");
  // 4. Real voids and real solids formed (uniform start would be min=max=0.5).
  CHECK(vmin < 0.05, "MBB: genuine voids formed (min density near density_min)");
  CHECK(vmax > 0.95, "MBB: genuine solid formed (max density near 1)");
  // 5. Mid-span I-section: solid chords, void neutral axis, clear separation.
  CHECK(chord_mean > 0.8, "MBB: mid-span top/bottom chords are solid");
  CHECK(neutral_mean < 0.2, "MBB: mid-span neutral axis is void");
  CHECK(chord_mean - neutral_mean > 0.6,
        "MBB: mid-span shows a clear I-section (chord vs neutral separation)");
  // 6. Material retained where the load is applied and at the support.
  CHECK(load_corner > 0.8, "MBB: material retained under the load");
  CHECK(support_corner > 0.8, "MBB: material retained at the support");

  if (g_failures == 0) {
    std::printf("mbb validation: all %d checks passed\n", g_checks);
    return 0;
  }
  std::fprintf(stderr, "mbb validation: %d/%d checks FAILED\n", g_failures,
               g_checks);
  return 1;
}
