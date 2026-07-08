// M6.1 export round-trip test for the 3MF (primary) format.
//
// The task: "3MF export (lib3mf) + STL export. Round-trip: export -> re-import
// -> V3 properties hold, volume within 0.5%." This file covers the 3MF path and
// is compiled only when lib3mf is found (like the OCCT-gated STEP tests and the
// Eigen-gated FEA tests); the STL half lives in the always-built test_export.cpp.
//
// "V3 properties hold" on a re-imported *mesh* means the two mesh-level Gate V3
// properties (ARCHITECTURE §7): watertight (closed + 2-manifold) and exactly one
// connected component; the other two V3 gates are voxel-grid properties, not
// re-checkable from a bare triangle mesh (see the note in test_export.cpp).
//
// No third-party test framework (ARCHITECTURE §4): the self-contained CHECK
// harness. Public API only (topopt/threemf.hpp) — lib3mf itself is not named.

#include "topopt/mesh.hpp"
#include "topopt/threemf.hpp"
#include "topopt/voxel.hpp"

#include <cmath>
#include <cstddef>
#include <cstdio>
#include <string>
#include <vector>

using topopt::check_watertight;
using topopt::count_components;
using topopt::marching_cubes;
using topopt::read_3mf_file;
using topopt::signed_volume;
using topopt::ThreeMfError;
using topopt::TriangleMesh;
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

static std::string tmp_path(const std::string& name) {
  return std::string(EXPORT_TMP_DIR) + "/" + name;
}

static VoxelGrid solid_grid(int nx, int ny, int nz, double h) {
  VoxelGrid g;
  g.nx = nx;
  g.ny = ny;
  g.nz = nz;
  g.spacing = h;
  g.origin = Vec3{0.0, 0.0, 0.0};
  g.tags.assign(static_cast<std::size_t>(nx) * ny * nz, VoxelTag::Interior);
  return g;
}

static void check_roundtrip(const TriangleMesh& original,
                            const TriangleMesh& got, int want_components,
                            const char* label) {
  const WatertightReport w = check_watertight(got);
  CHECK(w.watertight, label);  // V3 gate 1
  CHECK(w.boundary_edges == 0 && w.non_manifold_edges == 0, label);
  CHECK(count_components(got) == want_components, label);  // V3 gate 2
  CHECK(!got.triangles.empty(), label);
  CHECK(got.triangles.size() == original.triangles.size(), label);
  CHECK(got.vertices.size() == original.vertices.size(), label);
  const double v_orig = std::fabs(signed_volume(original));
  const double v_got = std::fabs(signed_volume(got));
  CHECK(v_orig > 0.0, label);
  // ROADMAP M6.1: "volume within 0.5%".
  CHECK(std::fabs(v_got - v_orig) <= 0.005 * v_orig, label);
}

int main() {
  // Solid block surface (non-unit spacing so volume is not a trivial 1.0 scale).
  VoxelGrid block = solid_grid(6, 4, 3, 2.0);
  std::vector<double> block_d(block.voxel_count(), 1.0);
  const TriangleMesh block_mesh = marching_cubes(block, block_d, 0.5);
  CHECK(check_watertight(block_mesh).watertight,
        "precondition: solid block surface is watertight");
  CHECK(count_components(block_mesh) == 1,
        "precondition: solid block surface is one component");

  // --- 3MF round-trip on the solid block -------------------------------------
  {
    const std::string path = tmp_path("roundtrip_block.3mf");
    topopt::write_3mf_file(path, block_mesh);
    const TriangleMesh reread = read_3mf_file(path);
    check_roundtrip(block_mesh, reread, 1, "3MF block round-trip");
  }

  // --- 3MF round-trip on a genus-1 (through-hole) body -----------------------
  {
    const int n = 8;
    VoxelGrid g = solid_grid(n, n, n, 1.0);
    std::vector<double> d(g.voxel_count(), 1.0);
    for (int k = 0; k < n; ++k) d[g.index(n / 2, n / 2, k)] = 0.0;  // z-channel
    const TriangleMesh holed = marching_cubes(g, d, 0.5);
    CHECK(check_watertight(holed).watertight,
          "precondition: holed block surface is watertight");
    const std::string path = tmp_path("roundtrip_holed.3mf");
    topopt::write_3mf_file(path, holed);
    check_roundtrip(holed, read_3mf_file(path), 1,
                    "3MF holed block round-trip (genus 1, one component)");
  }

  // --- Error path: writing under a non-existent directory throws ThreeMfError -
  {
    bool threw = false;
    try {
      topopt::write_3mf_file(tmp_path("no_such_subdir/x.3mf"), block_mesh);
    } catch (const ThreeMfError&) {
      threw = true;
    }
    CHECK(threw, "3MF write to a non-existent directory throws ThreeMfError");
  }

  // --- Error path: reading a missing file throws ThreeMfError ----------------
  {
    bool threw = false;
    try {
      (void)read_3mf_file(tmp_path("does_not_exist.3mf"));
    } catch (const ThreeMfError&) {
      threw = true;
    }
    CHECK(threw, "3MF read of a missing file throws ThreeMfError");
  }

  if (g_failures == 0) {
    std::printf("3MF export round-trip (M6.1): all %d checks passed\n",
                g_checks);
    return 0;
  }
  std::fprintf(stderr, "3MF export round-trip (M6.1): %d/%d checks FAILED\n",
               g_failures, g_checks);
  return 1;
}
