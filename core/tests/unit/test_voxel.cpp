// Unit tests for the solid voxelizer (ROADMAP M1.5).
//
// No third-party test framework is available (ARCHITECTURE §4 locks the
// dependency set), so this reuses the self-contained CHECK harness style from
// test_stl.cpp. Tests exercise the public API only (topopt/voxel.hpp) and drive
// it with the committed STL fixtures via import_stl_file, so the test needs no
// OCCT and runs in every build.
//
// Golden geometry facts (cube edge 10 mm at bbox 0..10; sphere mesh volume
// 4047.044792044954 mm^3, bbox +/-10) are the human-authored ground truth in
// core/tests/fixtures/stl/expected_values.json. They are cited here as literals;
// the tests assert against them and do not edit the fixture.

#include "topopt/mesh.hpp"
#include "topopt/stl.hpp"
#include "topopt/voxel.hpp"

#include <cmath>
#include <cstdio>
#include <stdexcept>
#include <string>
#include <vector>

using topopt::import_stl_file;
using topopt::signed_volume;
using topopt::TriangleMesh;
using topopt::VoxelGrid;
using topopt::VoxelTag;
using topopt::voxelize;

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

static std::string fixture(const std::string& name) {
  return std::string(STL_FIXTURE_DIR) + "/" + name;
}

int main() {
  // === cube_10mm.stl: exact voxel count and tag partition ==================
  // The 10 mm cube tiled at resolution 10 gives a 10x10x10 grid of unit voxels
  // that exactly fills the solid: every voxel is solid, so the count is exact.
  {
    TriangleMesh cube = import_stl_file(fixture("cube_10mm.stl"));
    VoxelGrid g = voxelize(cube, 10);

    CHECK(g.nx == 10 && g.ny == 10 && g.nz == 10, "cube grid is 10x10x10");
    CHECK(g.spacing == 1.0, "cube voxel edge is exactly 1 mm");
    CHECK(g.voxel_count() == 1000, "cube grid has 1000 cells");
    CHECK(g.solid_count() == 1000, "cube fills all 1000 voxels (exact count)");
    CHECK(g.solid_volume() == 1000.0, "cube voxel volume is exactly 1000 mm^3");

    // The origin corner voxel is on the boundary (out-of-grid neighbours),
    // a deep voxel is fully surrounded.
    CHECK(g.tag(0, 0, 0) == VoxelTag::Surface, "corner voxel is Surface");
    CHECK(g.tag(5, 5, 5) == VoxelTag::Interior, "central voxel is Interior");

    // Interior = the inner 8x8x8 block (indices 1..8); Surface = the shell.
    std::size_t interior = 0, surface = 0, empty = 0;
    for (int k = 0; k < g.nz; ++k)
      for (int j = 0; j < g.ny; ++j)
        for (int i = 0; i < g.nx; ++i) {
          switch (g.tag(i, j, k)) {
            case VoxelTag::Interior: ++interior; break;
            case VoxelTag::Surface: ++surface; break;
            case VoxelTag::Empty: ++empty; break;
            default: break;
          }
        }
    CHECK(interior == 512, "cube has 512 interior voxels (8^3)");
    CHECK(surface == 488, "cube has 488 surface voxels (shell)");
    CHECK(empty == 0, "cube grid has no empty voxels");
    CHECK(interior + surface == g.solid_count(),
          "interior + surface accounts for every solid voxel");

    // The grid stores a user tag per voxel (M1.6 will set LOAD/FIXTURE). Mark a
    // solid voxel UserTagged and read it back; it stays solid.
    g.set_tag(3, 4, 5, VoxelTag::UserTagged);
    CHECK(g.tag(3, 4, 5) == VoxelTag::UserTagged,
          "grid stores a user tag on a voxel");
    CHECK(g.solid(3, 4, 5), "a user-tagged voxel is still solid");
    CHECK(g.solid_count() == 1000,
          "retagging solid->UserTagged does not change the solid count");
  }

  // === sphere_r10mm.stl: voxelized volume within 2% at 128^3 ================
  {
    TriangleMesh sphere = import_stl_file(fixture("sphere_r10mm.stl"));
    const double mesh_volume = signed_volume(sphere);  // 4047.044792044954

    VoxelGrid g = voxelize(sphere, 128);
    CHECK(g.nx == 128 && g.ny == 128 && g.nz == 128,
          "sphere grid is 128x128x128");

    const double vox_volume = g.solid_volume();
    const double rel_err =
        std::fabs(vox_volume - mesh_volume) / std::fabs(mesh_volume);
    CHECK(rel_err < 0.02, "sphere voxel volume within 2% of the mesh volume");

    // A filled sphere has both a hollow interior and a boundary shell.
    std::size_t interior = 0, surface = 0;
    for (int k = 0; k < g.nz; ++k)
      for (int j = 0; j < g.ny; ++j)
        for (int i = 0; i < g.nx; ++i) {
          if (g.tag(i, j, k) == VoxelTag::Interior) ++interior;
          else if (g.tag(i, j, k) == VoxelTag::Surface) ++surface;
        }
    CHECK(interior > 0, "sphere has interior voxels");
    CHECK(surface > 0, "sphere has surface voxels");
    CHECK(interior + surface == g.solid_count(),
          "sphere solid voxels are all interior or surface");
    // The centre of the sphere is solid and interior; the very first voxel of
    // the grid (a bbox corner) is outside the sphere.
    CHECK(g.tag(64, 64, 64) == VoxelTag::Interior, "sphere centre is Interior");
    CHECK(g.tag(0, 0, 0) == VoxelTag::Empty, "sphere bbox corner is Empty");
  }

  // === resolution guard ====================================================
  {
    TriangleMesh cube = import_stl_file(fixture("cube_10mm.stl"));
    bool threw = false;
    try {
      voxelize(cube, 0);
    } catch (const std::invalid_argument&) {
      threw = true;
    }
    CHECK(threw, "voxelize rejects resolution < 1");
  }

  // === the CONNECTIVITY BELT: load_path_connected ==========================
  // Handoff 2026-07-23-gate-honesty-connectivity-rejection. A synthetic 8x1x1 bar,
  // Fixture at i == 0, Load at i == 7, so the load path is a single line of voxels
  // and CUTTING ONE of them is the whole experiment. Every case below is authored
  // in code (no fixture file) and the primitive is read-only, so this is a direct
  // statement about the rule, not about any optimizer's output.
  {
    auto bar = [](int nx) {
      VoxelGrid g;
      g.nx = nx; g.ny = 1; g.nz = 1;
      g.spacing = 1.0;
      g.origin = topopt::Vec3{0.0, 0.0, 0.0};
      g.tags.assign(static_cast<std::size_t>(nx), VoxelTag::Interior);
      g.set_tag(0, 0, 0, VoxelTag::Fixture);
      g.set_tag(nx - 1, 0, 0, VoxelTag::Load);
      return g;
    };
    const VoxelGrid g = bar(8);
    const std::vector<double> solid(8, 1.0);
    CHECK(topopt::load_path_connected(g, solid),
          "belt: an unbroken bar from Fixture to Load is connected");

    // THE FIRING CASE: one interior voxel carved below the iso. The Load face is
    // still fully printed (it is FrozenSolid in a real run) and every OTHER voxel
    // is solid — exactly the shape of the failure this belt exists for, where the
    // stress solve reports a severed structure carrying nothing and the margin
    // therefore looks superb.
    for (int cut = 1; cut + 1 < 8; ++cut) {
      std::vector<double> d = solid;
      d[static_cast<std::size_t>(cut)] = 0.4;  // below the 0.5 iso
      CHECK(!topopt::load_path_connected(g, d),
            "belt: a single sub-iso voxel anywhere along the bar severs it");
    }

    // A voxel AT the iso is not printed (the rule is strictly greater), and one
    // just above it is.
    {
      std::vector<double> at_iso = solid;
      at_iso[3] = 0.5;
      CHECK(!topopt::load_path_connected(g, at_iso),
            "belt: density exactly at the iso is NOT printed material");
      std::vector<double> above = solid;
      above[3] = 0.5000001;
      CHECK(topopt::load_path_connected(g, above),
            "belt: density just above the iso carries the path");
    }

    // A carved-away LOAD voxel is unreachable by construction — the load face was
    // stripped, which is the same failure seen from the other end.
    {
      std::vector<double> no_load = solid;
      no_load[7] = 0.0;
      CHECK(!topopt::load_path_connected(g, no_load),
            "belt: a load voxel that is not printed is not reachable");
      std::vector<double> no_anchor = solid;
      no_anchor[0] = 0.0;
      CHECK(!topopt::load_path_connected(g, no_anchor),
            "belt: an anchor voxel that is not printed anchors nothing");
    }

    // VACUOUS CASES — the belt reports connectivity, it never invents a verdict it
    // cannot measure. With no Load voxels (a self-weight run tags none) or no
    // Fixture voxels there is no load path to certify, so an ARBITRARILY carved
    // field passes: that is what keeps every self-weight fixture byte-identical.
    {
      VoxelGrid no_load_tags = bar(8);
      no_load_tags.set_tag(7, 0, 0, VoxelTag::Interior);
      std::vector<double> hollow(8, 0.0);
      CHECK(topopt::load_path_connected(no_load_tags, hollow),
            "belt: no Load voxels => vacuously connected (nothing to certify)");
      VoxelGrid no_fixture_tags = bar(8);
      no_fixture_tags.set_tag(0, 0, 0, VoxelTag::Interior);
      CHECK(topopt::load_path_connected(no_fixture_tags, hollow),
            "belt: no Fixture voxels => vacuously connected");
    }

    // ADJACENCY is 26-connected (node sharing), matching how two hex8 elements
    // that touch at a single corner still share that node and still transmit force
    // — so the belt never contradicts the FE model that produced the margin.
    {
      VoxelGrid d2;
      d2.nx = 2; d2.ny = 1; d2.nz = 2;
      d2.spacing = 1.0;
      d2.origin = topopt::Vec3{0.0, 0.0, 0.0};
      d2.tags.assign(4, VoxelTag::Interior);
      d2.set_tag(0, 0, 0, VoxelTag::Fixture);  // bottom-left
      d2.set_tag(1, 0, 1, VoxelTag::Load);     // top-right: corner contact only
      std::vector<double> diag(4, 0.0);
      diag[d2.index(0, 0, 0)] = 1.0;
      diag[d2.index(1, 0, 1)] = 1.0;
      CHECK(topopt::load_path_connected(d2, diag),
            "belt: corner-touching voxels share a node, so they are connected");
      // ...and a diagonal that does NOT touch is still severed.
      VoxelGrid far;
      far.nx = 3; far.ny = 1; far.nz = 3;
      far.spacing = 1.0;
      far.origin = topopt::Vec3{0.0, 0.0, 0.0};
      far.tags.assign(9, VoxelTag::Interior);
      far.set_tag(0, 0, 0, VoxelTag::Fixture);
      far.set_tag(2, 0, 2, VoxelTag::Load);
      std::vector<double> apart(9, 0.0);
      apart[far.index(0, 0, 0)] = 1.0;
      apart[far.index(2, 0, 2)] = 1.0;
      CHECK(!topopt::load_path_connected(far, apart),
            "belt: two printed blocks with a gap between them are severed");
    }

    // Size mismatch is an argument error, like every sibling field consumer.
    {
      bool threw = false;
      try {
        topopt::load_path_connected(g, std::vector<double>(3, 1.0));
      } catch (const std::invalid_argument&) {
        threw = true;
      }
      CHECK(threw, "belt: a density of the wrong size is rejected");
    }
  }

  if (g_failures == 0) {
    std::printf("voxelize: all %d checks passed\n", g_checks);
    return 0;
  }
  std::fprintf(stderr, "voxelize: %d/%d checks FAILED\n", g_failures, g_checks);
  return 1;
}
