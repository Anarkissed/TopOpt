// Unit tests for traction_loads (ROADMAP M7.6-core / MOD-F1 D7): a uniform
// surface traction over the exposed faces of a tagged region, distributed as
// consistent nodal loads (never a centroid point force). No third-party test
// framework (ARCHITECTURE §4); the same self-contained CHECK harness and
// in-code grids as test_assembly.cpp, exercising only the public API
// (topopt/fea.hpp, topopt/voxel.hpp).
//
// The central checks:
//   * a single solid voxel loaded on all six free faces splits the force to its
//     eight corner nodes 1/8 each (each corner shares 3 of the 6 faces, each
//     face contributes 1/4) — an exact hand-checkable distribution across all
//     three force components;
//   * a full tagged face plane on a block sums its nodal loads back to the
//     applied resultant and spreads it over many nodes (not a point load);
//   * a fully-interior tagged voxel (no exposed face) and an absent tag both
//     throw, rather than silently producing no load.

#include "topopt/fea.hpp"
#include "topopt/voxel.hpp"

#include <algorithm>
#include <array>
#include <cmath>
#include <cstddef>
#include <cstdio>
#include <stdexcept>
#include <vector>

using topopt::NodalLoad;
using topopt::traction_loads;
using topopt::Vec3;
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

// A dense solid grid of nx*ny*nz cubic voxels, edge `h`, origin at 0. Every
// voxel is Interior (solid) unless a test re-tags it.
VoxelGrid make_solid_grid(int nx, int ny, int nz, double h) {
  VoxelGrid g;
  g.nx = nx;
  g.ny = ny;
  g.nz = nz;
  g.spacing = h;
  g.origin = topopt::Vec3{0.0, 0.0, 0.0};
  g.tags.assign(static_cast<std::size_t>(nx) * ny * nz, VoxelTag::Interior);
  return g;
}

bool near(double a, double b, double tol) { return std::fabs(a - b) <= tol; }

// Sum the nodal loads per component: {sum_x, sum_y, sum_z}.
std::array<double, 3> load_sum(const std::vector<NodalLoad>& loads) {
  std::array<double, 3> s{0.0, 0.0, 0.0};
  for (const auto& l : loads) s[static_cast<std::size_t>(l.component)] += l.value;
  return s;
}

bool throws_invalid(const VoxelGrid& g, VoxelTag tag, Vec3 f) {
  try {
    traction_loads(g, tag, f);
  } catch (const std::invalid_argument&) {
    return true;
  } catch (...) {
    return false;
  }
  return false;
}

}  // namespace

int main() {
  const double tol = 1e-9;

  // --- Single voxel: exact 1/8-per-node distribution -----------------------
  // One solid voxel has six free faces (every neighbour is off-grid). A uniform
  // traction puts 1/4 of each face's force on each of its four corner nodes;
  // each of the eight cube corners is shared by three faces, so every node
  // carries 3/(6*4) = 1/8 of the resultant. Use (8,16,-24) so each node is a
  // round (1, 2, -3) and all three components are exercised.
  {
    VoxelGrid g = make_solid_grid(1, 1, 1, 1.0);
    g.set_tag(0, 0, 0, VoxelTag::Load);
    const Vec3 F{8.0, 16.0, -24.0};
    std::vector<NodalLoad> loads = traction_loads(g, VoxelTag::Load, F);

    // Exactly the 8 corner nodes, all three components each -> 24 entries.
    CHECK(loads.size() == 24, "single voxel: 8 nodes x 3 components = 24 loads");

    // Aggregate per node and assert every node is (1, 2, -3).
    const int nn = topopt::fea_node_count(g);
    std::vector<std::array<double, 3>> per(
        static_cast<std::size_t>(nn), std::array<double, 3>{0.0, 0.0, 0.0});
    for (const auto& l : loads)
      per[static_cast<std::size_t>(l.node)][static_cast<std::size_t>(l.component)] +=
          l.value;
    bool all_eighth = true;
    for (int n = 0; n < nn; ++n) {
      const auto& p = per[static_cast<std::size_t>(n)];
      if (!(near(p[0], 1.0, tol) && near(p[1], 2.0, tol) && near(p[2], -3.0, tol)))
        all_eighth = false;
    }
    CHECK(all_eighth, "single voxel: each of 8 nodes carries force/8 = (1,2,-3)");

    // And the nodal loads sum to the applied resultant.
    std::array<double, 3> s = load_sum(loads);
    CHECK(near(s[0], F.x, tol) && near(s[1], F.y, tol) && near(s[2], F.z, tol),
          "single voxel: nodal loads sum to applied force");
  }

  // --- Tagged face plane: sums to force, distributed (not a point load) -----
  // A 3x3x3 solid block with its whole +x boundary plane (i == 2) tagged Load.
  // The resultant must be recovered exactly by summing the nodal loads, and the
  // load must be spread across many nodes with no single node carrying it all.
  {
    VoxelGrid g = make_solid_grid(3, 3, 3, 2.0);
    for (int k = 0; k < g.nz; ++k)
      for (int j = 0; j < g.ny; ++j) g.set_tag(2, j, k, VoxelTag::Load);
    const Vec3 F{5.0, -7.0, 11.0};
    std::vector<NodalLoad> loads = traction_loads(g, VoxelTag::Load, F);

    std::array<double, 3> s = load_sum(loads);
    CHECK(near(s[0], F.x, tol) && near(s[1], F.y, tol) && near(s[2], F.z, tol),
          "face plane: nodal loads sum to applied force");

    // Distinct loaded nodes: the +x face alone is a 4x4 node patch (16 nodes),
    // so a genuine traction touches far more than one node (not a centroid
    // point force). No single node may carry the whole resultant either.
    std::vector<int> nodes;
    for (const auto& l : loads) nodes.push_back(l.node);
    std::sort(nodes.begin(), nodes.end());
    nodes.erase(std::unique(nodes.begin(), nodes.end()), nodes.end());
    CHECK(nodes.size() >= 16, "face plane: load distributed over many nodes");
    bool none_carries_all = true;
    const int nn = topopt::fea_node_count(g);
    std::vector<double> nx(static_cast<std::size_t>(nn), 0.0);
    for (const auto& l : loads)
      if (l.component == 0) nx[static_cast<std::size_t>(l.node)] += l.value;
    for (double v : nx)
      if (std::fabs(v) >= std::fabs(F.x)) none_carries_all = false;
    CHECK(none_carries_all, "face plane: no single node carries the whole force");
  }

  // --- Zero resultant: no spurious loads ------------------------------------
  {
    VoxelGrid g = make_solid_grid(2, 2, 2, 1.0);
    for (int k = 0; k < g.nz; ++k)
      for (int j = 0; j < g.ny; ++j) g.set_tag(1, j, k, VoxelTag::Load);
    std::vector<NodalLoad> loads =
        traction_loads(g, VoxelTag::Load, Vec3{0.0, 0.0, 0.0});
    CHECK(loads.empty(), "zero force: no nodal loads emitted");
  }

  // --- No exposed face -> throws --------------------------------------------
  // The centre voxel of a 3x3x3 solid is fully surrounded, so it has no free
  // face: a traction cannot be applied and the call must throw rather than
  // silently produce nothing.
  {
    VoxelGrid g = make_solid_grid(3, 3, 3, 1.0);
    g.set_tag(1, 1, 1, VoxelTag::Load);
    CHECK(throws_invalid(g, VoxelTag::Load, Vec3{1.0, 0.0, 0.0}),
          "interior-only tagged region (no free face) throws");
  }

  // --- Absent tag -> throws --------------------------------------------------
  {
    VoxelGrid g = make_solid_grid(2, 2, 2, 1.0);  // no voxel is Fixture
    CHECK(throws_invalid(g, VoxelTag::Fixture, Vec3{1.0, 0.0, 0.0}),
          "tag carried by no voxel throws (no faces to load)");
  }

  if (g_failures == 0) {
    std::fprintf(stderr, "traction_loads: all %d checks passed\n", g_checks);
    return 0;
  }
  std::fprintf(stderr, "traction_loads: %d/%d checks FAILED\n", g_failures,
               g_checks);
  return 1;
}
