// M3.5 property test — marching cubes (threshold 0.5) + cleanup + the Gate V3
// property suite (ARCHITECTURE §7 V3). Lives in tests/property/ per
// ARCHITECTURE §3 ("Watertightness, connectivity, min-feature-size").
//
// The four §7 V3 gates are:
//   1. Mesh watertight (closed, 2-manifold).
//   2. Exactly one connected component (of the cleaned mesh).
//   3. All Load/Fixture voxels retained at density >= 0.9.
//   4. Minimum feature size >= 2 voxels.
//
// Coverage strategy: each gate's check is exercised with controlled synthetic
// fields that make it both PASS and FAIL (so a broken check is caught), plus a
// genuine end-to-end run of check_v3 on a real SIMP optimizer output for the two
// gates the M3.4 loop satisfies emergently (watertight + single component). The
// retention and min-feature gates are NOT asserted on raw optimizer output: at
// M3.5 retention is emergent (ROADMAP M3.7 makes Load/Fixture voxels structural)
// and SIMP designs at this resolution contain sub-2-voxel features — asserting
// those gates on raw output would be asserting behaviour the optimizer does not
// yet provide. They are covered by the synthetic pass/fail cases instead.
//
// No third-party test framework (ARCHITECTURE §4); same self-contained CHECK
// harness as test_gate_v2.cpp, public API only.

#include "topopt/fea.hpp"
#include "topopt/mesh.hpp"
#include "topopt/simp.hpp"
#include "topopt/voxel.hpp"

#include <cmath>
#include <cstddef>
#include <cstdio>
#include <vector>

using topopt::DirichletBC;
using topopt::NodalLoad;
using topopt::SimpOptimizeResult;
using topopt::SimpOptions;
using topopt::SimpParams;
using topopt::TriangleMesh;
using topopt::V3Report;
using topopt::Vec3;
using topopt::VoxelGrid;
using topopt::VoxelTag;
using topopt::WatertightReport;

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

// A grid whose voxels are all Interior (a full design domain), unit spacing.
VoxelGrid solid_grid(int nx, int ny, int nz, double h = 1.0) {
  VoxelGrid g;
  g.nx = nx;
  g.ny = ny;
  g.nz = nz;
  g.spacing = h;
  g.origin = Vec3{0.0, 0.0, 0.0};
  g.tags.assign(static_cast<std::size_t>(nx) * ny * nz, VoxelTag::Interior);
  return g;
}

}  // namespace

int main() {
  // =========================================================================
  // Group 1 — marching cubes + cleanup correctness (synthetic scalar fields).
  // =========================================================================

  // 1a. A wholly-void field yields an empty mesh (nothing to close).
  {
    VoxelGrid g = solid_grid(4, 4, 4);
    std::vector<double> d(g.voxel_count(), 0.0);
    TriangleMesh m = topopt::marching_cubes(g, d, 0.5);
    CHECK(m.empty(), "MC: empty field -> empty mesh");
    CHECK(topopt::count_components(m) == 0, "MC: empty mesh has 0 components");
  }

  // 1b. A solid block: closed, 2-manifold, single component, positive volume,
  // and a bounding box spanning [0, n*h] on each axis (the padded background
  // closes the surface at the voxel-centre-plus-half boundary).
  {
    const int nx = 6, ny = 4, nz = 3;
    const double h = 2.0;
    VoxelGrid g = solid_grid(nx, ny, nz, h);
    std::vector<double> d(g.voxel_count(), 1.0);
    TriangleMesh m = topopt::marching_cubes(g, d, 0.5);
    WatertightReport w = topopt::check_watertight(m);
    CHECK(!m.empty(), "MC: solid block produces a non-empty mesh");
    CHECK(w.watertight, "MC: solid block is watertight (closed, 2-manifold)");
    CHECK(w.boundary_edges == 0, "MC: solid block has no boundary edges");
    CHECK(w.non_manifold_edges == 0, "MC: solid block has no non-manifold edges");
    CHECK(topopt::count_components(m) == 1, "MC: solid block is one component");
    const double vol = std::fabs(topopt::signed_volume(m));
    const double box = nx * h * ny * h * nz * h;  // full padded extent
    CHECK(vol > 0.5 * box && vol <= box,
          "MC: solid-block volume is a chamfered box (0.5*box < V <= box)");
    Vec3 mn{1e9, 1e9, 1e9}, mx{-1e9, -1e9, -1e9};
    topopt::bounding_box(m, mn, mx);
    const double eps = 1e-9;
    CHECK(std::fabs(mn.x) < eps && std::fabs(mn.y) < eps &&
              std::fabs(mn.z) < eps,
          "MC: solid-block mesh min corner is the grid origin");
    CHECK(std::fabs(mx.x - nx * h) < eps && std::fabs(mx.y - ny * h) < eps &&
              std::fabs(mx.z - nz * h) < eps,
          "MC: solid-block mesh max corner spans the full grid extent");

    // Honesty check for gate 1: removing one triangle opens the shell, so the
    // watertight gate must then report boundary edges (it is not a smoke test).
    TriangleMesh open = m;
    open.triangles.pop_back();
    WatertightReport wopen = topopt::check_watertight(open);
    CHECK(!wopen.watertight && wopen.boundary_edges > 0,
          "MC: deleting a triangle makes the watertight gate fail");
  }

  // 1c. A block with a through-hole (genus 1) stays watertight and one
  // component — a hole changes genus, not connectedness.
  {
    const int n = 8;
    VoxelGrid g = solid_grid(n, n, n);
    std::vector<double> d(g.voxel_count(), 1.0);
    for (int k = 0; k < n; ++k) d[g.index(n / 2, n / 2, k)] = 0.0;
    TriangleMesh m = topopt::marching_cubes(g, d, 0.5);
    WatertightReport w = topopt::check_watertight(m);
    CHECK(w.watertight, "MC: holed block is watertight");
    CHECK(topopt::count_components(m) == 1, "MC: holed block is one component");
  }

  // 1d. Two disjoint blocks: the raw marching-cubes output has two shells;
  // keep_largest_component reduces it to a single watertight shell.
  {
    const int nx = 10, ny = 3, nz = 3;
    VoxelGrid g = solid_grid(nx, ny, nz);
    std::vector<double> d(g.voxel_count(), 0.0);
    for (int k = 0; k < nz; ++k)
      for (int j = 0; j < ny; ++j)
        for (int i = 0; i < nx; ++i)
          if (i < 3 || i > 6) d[g.index(i, j, k)] = 1.0;  // gap at i=3..6
    TriangleMesh raw = topopt::marching_cubes(g, d, 0.5);
    CHECK(topopt::count_components(raw) == 2,
          "cleanup: two disjoint blocks give a 2-component raw mesh");
    TriangleMesh clean = topopt::keep_largest_component(raw);
    CHECK(topopt::count_components(clean) == 1,
          "cleanup: keep_largest_component leaves one component");
    CHECK(topopt::check_watertight(clean).watertight,
          "cleanup: the kept component is still watertight");
    CHECK(!clean.triangles.empty() &&
              clean.triangles.size() < raw.triangles.size(),
          "cleanup: the kept component drops the smaller shell's triangles");
  }

  // =========================================================================
  // Group 2 — min_feature_violations (gate 4) on controlled occupancies.
  // =========================================================================

  // 2a. A solid 4x4x4 block: every voxel sits in a solid 2x2x2 block.
  {
    VoxelGrid g = solid_grid(4, 4, 4);
    std::vector<double> d(g.voxel_count(), 1.0);
    CHECK(topopt::min_feature_violations(g, d, 0.5) == 0,
          "min-feature: solid block has 0 violations");
  }
  // 2b. A 1-voxel-thick plate (one z-layer solid): every solid voxel is a
  // sub-2-voxel feature, so all of them violate.
  {
    const int nx = 5, ny = 6, nz = 3;
    VoxelGrid g = solid_grid(nx, ny, nz);
    std::vector<double> d(g.voxel_count(), 0.0);
    int solid = 0;
    for (int j = 0; j < ny; ++j)
      for (int i = 0; i < nx; ++i) {
        d[g.index(i, j, 1)] = 1.0;  // middle layer only
        ++solid;
      }
    CHECK(topopt::min_feature_violations(g, d, 0.5) == solid,
          "min-feature: a 1-voxel-thick plate violates on every voxel");
  }
  // 2c. A 2-voxel-thick slab (two z-layers solid): thick enough everywhere.
  {
    const int nx = 4, ny = 4, nz = 4;
    VoxelGrid g = solid_grid(nx, ny, nz);
    std::vector<double> d(g.voxel_count(), 0.0);
    for (int k = 1; k <= 2; ++k)
      for (int j = 0; j < ny; ++j)
        for (int i = 0; i < nx; ++i) d[g.index(i, j, k)] = 1.0;
    CHECK(topopt::min_feature_violations(g, d, 0.5) == 0,
          "min-feature: a 2-voxel-thick slab has 0 violations");
  }
  // 2d. A single isolated solid voxel violates (thin in all directions).
  {
    VoxelGrid g = solid_grid(3, 3, 3);
    std::vector<double> d(g.voxel_count(), 0.0);
    d[g.index(1, 1, 1)] = 1.0;
    CHECK(topopt::min_feature_violations(g, d, 0.5) == 1,
          "min-feature: a single isolated voxel is one violation");
  }

  // =========================================================================
  // Group 3 — Load/Fixture retention gate (gate 3) + the full-suite verdict
  // on controlled designs.
  // =========================================================================

  // 3a. A solid design with tagged Load/Fixture voxels all at density 1 passes
  // ALL FOUR gates: this is a genuine end-to-end check_v3 positive verdict.
  {
    VoxelGrid g = solid_grid(4, 4, 4);
    g.set_tag(0, 0, 0, VoxelTag::Fixture);
    g.set_tag(0, 3, 3, VoxelTag::Fixture);
    g.set_tag(3, 3, 3, VoxelTag::Load);
    std::vector<double> d(g.voxel_count(), 1.0);
    V3Report r = topopt::check_v3(g, d, 0.5);
    CHECK(r.load_fixture_voxels == 3,
          "retention: all tagged Load/Fixture voxels are counted");
    CHECK(r.gate_load_fixture_retained() && r.min_load_fixture_density >= 0.9,
          "retention: solid tagged voxels pass the >= 0.9 gate");
    CHECK(r.gate_watertight() && r.gate_single_component() &&
              r.gate_min_feature(),
          "check_v3: solid design passes the mesh + min-feature gates");
    CHECK(r.passes, "check_v3: solid tagged design passes all four V3 gates");
  }
  // 3b. Dropping one tagged voxel below 0.9 fails only the retention gate.
  {
    VoxelGrid g = solid_grid(4, 4, 4);
    g.set_tag(0, 0, 0, VoxelTag::Fixture);
    g.set_tag(3, 3, 3, VoxelTag::Load);
    std::vector<double> d(g.voxel_count(), 1.0);
    d[g.index(3, 3, 3)] = 0.4;  // a load voxel optimized away
    V3Report r = topopt::check_v3(g, d, 0.5);
    CHECK(!r.gate_load_fixture_retained(),
          "retention: a tagged voxel below 0.9 fails the gate");
    CHECK(std::fabs(r.min_load_fixture_density - 0.4) < 1e-9,
          "retention: reports the minimum tagged density");
    CHECK(!r.passes, "check_v3: a retention failure fails the overall verdict");
  }
  // 3c. With no tagged voxels the retention gate is vacuously satisfied.
  {
    VoxelGrid g = solid_grid(4, 4, 4);
    std::vector<double> d(g.voxel_count(), 1.0);
    V3Report r = topopt::check_v3(g, d, 0.5);
    CHECK(r.load_fixture_voxels == 0 && r.gate_load_fixture_retained(),
          "retention: no tagged voxels -> gate vacuously true");
  }

  // =========================================================================
  // Group 4 — the property suite on a real SIMP optimizer output. The M3.4
  // loop satisfies the two mesh gates (watertight + single component) on every
  // output; those are asserted here. Retention/min-feature are reported (and
  // covered synthetically above), not asserted on raw output.
  // =========================================================================
  {
    const int nx = 24, ny = 8, nz = 8;
    VoxelGrid g = solid_grid(nx, ny, nz, 1.0);
    // Tag the clamped root face as Fixture and the loaded tip face as Load.
    for (int k = 0; k < nz; ++k)
      for (int j = 0; j < ny; ++j) {
        g.set_tag(0, j, k, VoxelTag::Fixture);
        g.set_tag(nx - 1, j, k, VoxelTag::Load);
      }
    std::vector<DirichletBC> bcs;
    for (int c = 0; c <= nz; ++c)
      for (int b = 0; b <= ny; ++b) {
        const int n = topopt::fea_node_index(g, 0, b, c);
        bcs.push_back({n, 0, 0.0});
        bcs.push_back({n, 1, 0.0});
        bcs.push_back({n, 2, 0.0});
      }
    std::vector<NodalLoad> loads;
    const double fz = -1.0 / static_cast<double>((ny + 1) * (nz + 1));
    for (int c = 0; c <= nz; ++c)
      for (int b = 0; b <= ny; ++b)
        loads.push_back({topopt::fea_node_index(g, nx, b, c), 2, fz});

    SimpParams p;
    p.youngs_modulus = 1.0;
    p.poisson = 0.3;
    p.penalty = 3.0;
    p.density_min = 0.001;
    SimpOptions opt;
    opt.volume_fraction = 0.5;
    opt.filter_radius = 1.5;
    opt.move = 0.2;
    opt.max_iterations = 60;
    opt.change_tol = 0.0;
    opt.cg_tolerance = 1e-8;

    const SimpOptimizeResult res = topopt::simp_optimize(g, p, bcs, loads, opt);
    const V3Report r = topopt::check_v3(g, res.physical_density, 0.5);

    std::printf(
        "[cantilever 24x8x8 vf=0.50] watertight=%d comps(raw=%d,clean=%d) "
        "tris=%zu | retained=%d(min=%.3f,n=%d) min_feature_violations=%d\n",
        static_cast<int>(r.gate_watertight()), r.mesh_components_raw,
        r.mesh_components, r.mesh.triangles.size(),
        static_cast<int>(r.load_fixture_retained), r.min_load_fixture_density,
        r.load_fixture_voxels, r.min_feature_violations);

    CHECK(!r.mesh.triangles.empty(),
          "V3(output): the extracted design mesh is non-empty");
    CHECK(r.gate_watertight(),
          "V3(output): optimizer output mesh is watertight");
    CHECK(r.gate_single_component(),
          "V3(output): cleaned optimizer output mesh is one component");
    CHECK(r.load_fixture_voxels == 2 * ny * nz,
          "V3(output): all tagged Load/Fixture voxels are scanned");
  }

  if (g_failures == 0) {
    std::printf("gate v3 property suite: all %d checks passed\n", g_checks);
    return 0;
  }
  std::fprintf(stderr, "gate v3 property suite: %d/%d checks FAILED\n",
               g_failures, g_checks);
  return 1;
}
