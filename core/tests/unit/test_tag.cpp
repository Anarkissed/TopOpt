// Unit tests for STEP face -> voxel tagging (ROADMAP M1.6).
//
// No third-party test framework is available (ARCHITECTURE §4 locks the
// dependency set), so this reuses the self-contained CHECK harness style from
// test_step.cpp. Tests exercise the public API only (topopt/step.hpp,
// topopt/voxel.hpp) — OCCT never appears here. It drives the committed STEP cube
// fixture, so it needs OCCT (like step_import) and runs in every CI build.
//
// The cube fixture is the human-authored ground truth in
// core/tests/fixtures/step/expected_values.json (bbox min (-5, -5.384615385, 0)
// max (5, 4.615384615, 10); 6 planar B-rep faces). Voxelized at resolution 10 it
// tiles to a 10x10x10 grid of unit voxels that exactly fills the solid. Tagging
// one full-cross-section face must select exactly the one-voxel-thick slab of
// voxels against it — the task's success criterion.

#include "topopt/mesh.hpp"
#include "topopt/step.hpp"
#include "topopt/voxel.hpp"

#include <cmath>
#include <cstdio>
#include <stdexcept>
#include <string>

using topopt::bounding_box;
using topopt::import_step_file;
using topopt::StepModel;
using topopt::tag_step_face;
using topopt::Vec3;
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
  return std::string(STEP_FIXTURE_DIR) + "/" + name;
}

// The face id whose tessellation triangles all sit on the plane z == target
// (within eps). For the cube that uniquely picks the top face (z==10) or the
// bottom face (z==0) — the two full-cross-section faces perpendicular to +Z.
// Returns -1 if none matches. Uses model.triangle_face (the M1.6 addition).
static int face_on_z_plane(const StepModel& m, double target, double eps) {
  for (int fid = 0; fid < m.face_count; ++fid) {
    bool any = false, all = true;
    for (std::size_t t = 0; t < m.mesh.triangles.size(); ++t) {
      if (m.triangle_face[t] != fid) continue;
      any = true;
      for (int corner = 0; corner < 3; ++corner) {
        const Vec3& v = m.mesh.vertices[m.mesh.triangles[t][corner]];
        if (std::fabs(v.z - target) > eps) all = false;
      }
    }
    if (any && all) return fid;
  }
  return -1;
}

int main() {
  StepModel m = import_step_file(fixture("cube.step"));

  // === the per-triangle face map is well formed (M1.6 importer addition) ====
  {
    CHECK(m.triangle_face.size() == m.mesh.triangles.size(),
          "triangle_face is parallel to mesh.triangles");
    CHECK(m.mesh.triangles.size() == 12, "cube tessellates to 12 triangles");
    CHECK(m.face_count == 6, "cube has 6 B-rep faces");
    // Every triangle's face id is in range, and each of the 6 planar faces
    // contributes exactly 2 triangles.
    int per_face[6] = {0, 0, 0, 0, 0, 0};
    bool in_range = true;
    for (std::size_t t = 0; t < m.triangle_face.size(); ++t) {
      const int f = m.triangle_face[t];
      if (f < 0 || f >= 6) in_range = false;
      else ++per_face[f];
    }
    CHECK(in_range, "every triangle_face id is in [0, face_count)");
    bool two_each = true;
    for (int f = 0; f < 6; ++f)
      if (per_face[f] != 2) two_each = false;
    CHECK(two_each, "each of the 6 cube faces owns exactly 2 triangles");
  }

  Vec3 lo, hi;
  bounding_box(m.mesh, lo, hi);

  const int top = face_on_z_plane(m, hi.z, 1e-6);   // z == 10 face
  const int bottom = face_on_z_plane(m, lo.z, 1e-6); // z == 0 face
  CHECK(top >= 0, "found the +Z (top) cube face");
  CHECK(bottom >= 0, "found the -Z (bottom) cube face");
  CHECK(top != bottom, "top and bottom are distinct faces");

  // === tag the top face as LOAD: exactly the top voxel slab =================
  {
    VoxelGrid g = voxelize(m.mesh, 10);
    CHECK(g.nz >= 1, "cube grid has at least one z layer");
    const int top_k = g.nz - 1;  // voxels against the max-z face

    const std::size_t n = tag_step_face(g, m, top, VoxelTag::Load);
    CHECK(n == static_cast<std::size_t>(g.nx) * g.ny,
          "top-face tag count == one full cross-section slab");

    // "Exactly the expected slab": a voxel is Load iff it is in the top layer.
    bool exact = true;
    std::size_t load_count = 0;
    for (int k = 0; k < g.nz; ++k)
      for (int j = 0; j < g.ny; ++j)
        for (int i = 0; i < g.nx; ++i) {
          const bool is_load = g.tag(i, j, k) == VoxelTag::Load;
          if (is_load) ++load_count;
          if (is_load != (k == top_k)) exact = false;
          if (is_load) CHECK(g.solid(i, j, k), "a Load voxel is still solid");
        }
    CHECK(exact, "Load voxels are exactly the top (k==nz-1) slab, nothing else");
    CHECK(load_count == n, "reported count matches the tags actually set");
    CHECK(g.tag(0, 0, 0) != VoxelTag::Load, "a bottom-layer voxel is not Load");
  }

  // === tag the bottom face as FIXTURE: exactly the bottom slab, distinct tag =
  {
    VoxelGrid g = voxelize(m.mesh, 10);
    const std::size_t n = tag_step_face(g, m, bottom, VoxelTag::Fixture);
    CHECK(n == static_cast<std::size_t>(g.nx) * g.ny,
          "bottom-face tag count == one full cross-section slab");

    bool exact = true;
    for (int k = 0; k < g.nz; ++k)
      for (int j = 0; j < g.ny; ++j)
        for (int i = 0; i < g.nx; ++i) {
          const bool is_fix = g.tag(i, j, k) == VoxelTag::Fixture;
          if (is_fix != (k == 0)) exact = false;
          // Fixture is a distinct tag from Load.
          if (is_fix) CHECK(g.tag(i, j, k) != VoxelTag::Load,
                            "Fixture and Load are distinct tags");
        }
    CHECK(exact, "Fixture voxels are exactly the bottom (k==0) slab");
  }

  // === Load and Fixture on the same grid do not collide =====================
  {
    VoxelGrid g = voxelize(m.mesh, 10);
    const std::size_t nl = tag_step_face(g, m, top, VoxelTag::Load);
    const std::size_t nf = tag_step_face(g, m, bottom, VoxelTag::Fixture);
    std::size_t load = 0, fix = 0;
    for (int k = 0; k < g.nz; ++k)
      for (int j = 0; j < g.ny; ++j)
        for (int i = 0; i < g.nx; ++i) {
          if (g.tag(i, j, k) == VoxelTag::Load) ++load;
          else if (g.tag(i, j, k) == VoxelTag::Fixture) ++fix;
        }
    CHECK(load == nl && fix == nf,
          "top LOAD and bottom FIXTURE slabs coexist without overwriting");
    CHECK(load == fix, "both slabs are the same size on a cube");
  }

  // === argument validation ==================================================
  {
    VoxelGrid g = voxelize(m.mesh, 10);

    auto throws_invalid = [&](int face_id, VoxelTag tag) {
      try {
        tag_step_face(g, m, face_id, tag);
      } catch (const std::invalid_argument&) {
        return true;
      }
      return false;
    };

    CHECK(throws_invalid(top, VoxelTag::Surface),
          "tag must be Load or Fixture (Surface rejected)");
    CHECK(throws_invalid(top, VoxelTag::Interior),
          "tag must be Load or Fixture (Interior rejected)");
    CHECK(throws_invalid(-1, VoxelTag::Load), "negative face_id rejected");
    CHECK(throws_invalid(m.face_count, VoxelTag::Load),
          "face_id == face_count rejected");
  }

  if (g_failures == 0) {
    std::printf("face tag: all %d checks passed\n", g_checks);
    return 0;
  }
  std::fprintf(stderr, "face tag: %d/%d checks FAILED\n", g_failures, g_checks);
  return 1;
}
