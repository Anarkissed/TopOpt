// Stage 5 (faster solves), B-06: the fine element product in the REDUCED system.
//
// MatfreeReduced::apply_kgg_raw now gathers and scatters through g2r (global DOF
// -> kept id, the spare slot ng for a fixed or void DOF) on ng+1 buffers, instead
// of copying x into and y out of two full-length vectors. Same elements, same
// colours, same per-element arithmetic, so the result must be IDENTICAL BYTES to
// the full-length path (mf_apply_full + gather), which stays for systems with
// cubic elements or springs.
//
// Checks, on a part that fills a fraction of its box (holes, a thin wall, fixed
// DOFs on the floor), at 1, 3 and 6 threads:
//   * the reduced path is taken (g2r built, no full-length scratch allocated);
//   * y from apply_kgg_raw equals the full-length product, byte for byte;
//   * the result does not depend on the thread count.

#include "topopt/fea.hpp"
#include "topopt/voxel.hpp"

#include "fea/fea_matfree.hpp"

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

int main() {
  // A 40 x 24 x 30 box holding a bracket: a base plate, a thin upright wall and a
  // hole through the plate, about a third of the box solid.
  VoxelGrid g;
  g.nx = 40;
  g.ny = 24;
  g.nz = 30;
  g.spacing = 1.0;
  g.origin = Vec3{0.0, 0.0, 0.0};
  g.tags.assign(static_cast<std::size_t>(g.nx) * g.ny * g.nz, VoxelTag::Empty);
  std::vector<double> E(g.voxel_count(), 0.0);
  for (int k = 0; k < g.nz; ++k)
    for (int j = 0; j < g.ny; ++j)
      for (int i = 0; i < g.nx; ++i) {
        const bool plate = k < 6 && !((i - 20) * (i - 20) + (j - 12) * (j - 12) < 25);
        const bool wall = i >= 18 && i < 20;  // two voxels thick, full height
        if (plate || wall) {
          g.tags[g.index(i, j, k)] = VoxelTag::Interior;
          E[g.index(i, j, k)] = 100.0 * (1.0 + 0.5 * std::sin(0.3 * i + 0.2 * j + 0.1 * k));
        }
      }
  std::vector<DirichletBC> bcs;
  for (int j = 0; j <= g.ny; ++j)
    for (int i = 0; i <= g.nx; ++i)
      for (int c = 0; c < 3; ++c) bcs.push_back({fea_node_index(g, i, j, 0), c, 0.0});
  std::vector<NodalLoad> loads{{fea_node_index(g, 19, 12, g.nz), 0, 1.0}};

  const fea_detail::MatfreeReduced m = fea_detail::mf_build_reduced(
      g, 1.0, 0.39, bcs, loads, &E, "test_to_solver_reduced_apply", nullptr, nullptr, nullptr);
  CHECK(!m.g2r.empty(), "the reduced-system apply is built for a plain isotropic system");
  CHECK(m.xfull.empty() && m.yfull.empty(), "no full-length scratch is allocated");
  CHECK(m.ng > 0 && m.ng < m.ndof / 2, "the part fills a fraction of its box");

  std::vector<double> x(static_cast<std::size_t>(m.ng));
  for (int k = 0; k < m.ng; ++k) x[static_cast<std::size_t>(k)] = std::sin(0.37 * k) + 0.25;

  // The full-length reference: scatter, mf_apply_full, gather.
  std::vector<double> xf(static_cast<std::size_t>(m.ndof), 0.0), yf(static_cast<std::size_t>(m.ndof), 0.0);
  for (int k = 0; k < m.ng; ++k) xf[static_cast<std::size_t>(m.kept_global[static_cast<std::size_t>(k)])] = x[static_cast<std::size_t>(k)];
  const int prev = fea_set_matfree_threads(1);
  fea_detail::mf_apply_full(m.elems, m.color_offsets, m.Ke, xf, yf);
  std::vector<double> yref(static_cast<std::size_t>(m.ng));
  for (int k = 0; k < m.ng; ++k) yref[static_cast<std::size_t>(k)] = yf[static_cast<std::size_t>(m.kept_global[static_cast<std::size_t>(k)])];

  for (int t : {1, 3, 6}) {
    fea_set_matfree_threads(t);
    std::vector<double> y(static_cast<std::size_t>(m.ng), -1.0);
    m.apply_kgg_raw(x.data(), y.data());
    const bool same = std::memcmp(y.data(), yref.data(), y.size() * sizeof(double)) == 0;
    CHECK(same, "the reduced apply equals the full-length product, byte for byte");
    std::printf("threads %d: reduced apply %s the full-length product\n", t, same ? "identical to" : "DIFFERS from");
  }
  fea_set_matfree_threads(prev);
  std::printf("%d checks, %d failures\n", g_checks, g_failures);
  return g_failures == 0 ? 0 : 1;
}
