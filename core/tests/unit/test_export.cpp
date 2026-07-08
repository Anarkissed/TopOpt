// M6.1 export round-trip test for the STL (secondary) format.
//
// The task: "3MF export (lib3mf) + STL export. Round-trip: export -> re-import
// -> V3 properties hold, volume within 0.5%." The 3MF half lives in test_3mf.cpp
// (gated on lib3mf); this file covers the pure-C++/std STL path, so it builds and
// runs in every configuration.
//
// "V3 properties hold" on a re-imported *mesh* means the two mesh-level Gate V3
// properties (ARCHITECTURE §7): watertight (closed + 2-manifold) and exactly one
// connected component. The other two V3 gates (Load/Fixture retention, min
// feature size) are properties of the voxel grid + density field, not of a bare
// re-imported triangle mesh, so they are not re-checkable here (see check_v3 in
// test_v3.cpp, which asserts all four on optimizer output).
//
// The meshes under test are marching-cubes surfaces of solid voxel grids — the
// same "printable body" the pipeline exports — so the round-trip exercises real
// export input, not a hand-built triangle soup. No third-party test framework
// (ARCHITECTURE §4): the self-contained CHECK harness from test_v3.cpp.

#include "topopt/mesh.hpp"
#include "topopt/stl.hpp"
#include "topopt/voxel.hpp"

#include <cmath>
#include <cstddef>
#include <cstdio>
#include <string>
#include <vector>

using topopt::check_watertight;
using topopt::count_components;
using topopt::import_stl_file;
using topopt::marching_cubes;
using topopt::read_stl_file;
using topopt::signed_volume;
using topopt::StlError;
using topopt::StlFormat;
using topopt::StlMesh;
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

// A grid whose voxels are all Interior, given spacing.
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

// Assert the V3 mesh-level properties + volume-within-0.5% on `got` relative to
// the pre-export `original`. `label` names the scenario in failure messages.
static void check_roundtrip(const TriangleMesh& original,
                            const TriangleMesh& got, int want_components,
                            const char* label) {
  const WatertightReport w = check_watertight(got);
  CHECK(w.watertight, label);  // V3 gate 1
  CHECK(w.boundary_edges == 0 && w.non_manifold_edges == 0, label);
  CHECK(count_components(got) == want_components, label);  // V3 gate 2
  CHECK(!got.triangles.empty(), label);
  CHECK(got.triangles.size() == original.triangles.size(), label);
  const double v_orig = std::fabs(signed_volume(original));
  const double v_got = std::fabs(signed_volume(got));
  CHECK(v_orig > 0.0, label);
  // ROADMAP M6.1: "volume within 0.5%".
  CHECK(std::fabs(v_got - v_orig) <= 0.005 * v_orig, label);
}

int main() {
  // A solid block's marching-cubes surface: watertight, single component. Use a
  // non-unit spacing so the volume comparison is not trivially 1.0-scaled.
  VoxelGrid block = solid_grid(6, 4, 3, 2.0);
  std::vector<double> block_d(block.voxel_count(), 1.0);
  const TriangleMesh block_mesh = marching_cubes(block, block_d, 0.5);
  CHECK(check_watertight(block_mesh).watertight,
        "precondition: solid block surface is watertight");
  CHECK(count_components(block_mesh) == 1,
        "precondition: solid block surface is one component");

  // --- Binary STL round-trip -------------------------------------------------
  {
    const std::string path = tmp_path("roundtrip_block_bin.stl");
    topopt::write_stl_file(path, block_mesh, StlFormat::Binary);
    StlMesh reread = read_stl_file(path);
    CHECK(reread.format == StlFormat::Binary,
          "binary: written file is detected as binary");
    check_roundtrip(block_mesh, reread.mesh, 1, "binary block round-trip");
  }

  // --- ASCII STL round-trip --------------------------------------------------
  {
    const std::string path = tmp_path("roundtrip_block_ascii.stl");
    topopt::write_stl_file(path, block_mesh, StlFormat::Ascii);
    StlMesh reread = read_stl_file(path);
    CHECK(reread.format == StlFormat::Ascii,
          "ascii: written file is detected as ascii");
    check_roundtrip(block_mesh, reread.mesh, 1, "ascii block round-trip");
    // ASCII writes full double precision, so the volume is reproduced far more
    // tightly than the 0.5% requirement (near machine precision).
    const double v_orig = std::fabs(signed_volume(block_mesh));
    const double v_got = std::fabs(signed_volume(reread.mesh));
    CHECK(std::fabs(v_got - v_orig) <= 1e-9 * v_orig,
          "ascii: full-precision volume round-trips near-exactly");
  }

  // --- Default format is binary ----------------------------------------------
  {
    const std::string path = tmp_path("roundtrip_default.stl");
    topopt::write_stl_file(path, block_mesh);  // no format argument
    CHECK(read_stl_file(path).format == StlFormat::Binary,
          "default export format is binary");
  }

  // --- import_stl_file (watertight-enforcing entry point) accepts the file ---
  {
    const std::string path = tmp_path("roundtrip_import.stl");
    topopt::write_stl_file(path, block_mesh, StlFormat::Binary);
    // import_stl_file throws unless the mesh is watertight; a successful return
    // is itself the assertion that the exported file re-imports watertight.
    const TriangleMesh imported = import_stl_file(path);
    check_roundtrip(block_mesh, imported, 1, "import_stl_file round-trip");
  }

  // --- A genus-1 (through-hole) body also round-trips watertight, 1 component -
  {
    const int n = 8;
    VoxelGrid g = solid_grid(n, n, n, 1.0);
    std::vector<double> d(g.voxel_count(), 1.0);
    for (int k = 0; k < n; ++k) d[g.index(n / 2, n / 2, k)] = 0.0;  // z-channel
    const TriangleMesh holed = marching_cubes(g, d, 0.5);
    CHECK(check_watertight(holed).watertight,
          "precondition: holed block surface is watertight");
    const std::string path = tmp_path("roundtrip_holed.stl");
    topopt::write_stl_file(path, holed, StlFormat::Binary);
    check_roundtrip(holed, read_stl_file(path).mesh, 1,
                    "holed block round-trip (genus 1, one component)");
  }

  // --- Error path: an unwritable path throws StlError ------------------------
  {
    bool threw = false;
    try {
      topopt::write_stl_file(tmp_path("no_such_subdir/x.stl"), block_mesh);
    } catch (const StlError&) {
      threw = true;
    }
    CHECK(threw, "write to a non-existent directory throws StlError");
  }

  if (g_failures == 0) {
    std::printf("STL export round-trip (M6.1): all %d checks passed\n",
                g_checks);
    return 0;
  }
  std::fprintf(stderr, "STL export round-trip (M6.1): %d/%d checks FAILED\n",
               g_failures, g_checks);
  return 1;
}
