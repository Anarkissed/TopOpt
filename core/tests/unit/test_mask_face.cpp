// M3.7 mask_step_face test — the M1.6 slab selection generalized with a voxel
// depth, writing a design mask (separate array) instead of grid tags.
//
// Drives the committed STEP cube fixture (like test_tag): voxelized at
// resolution 10 it tiles a 10x10x10 unit-voxel grid that exactly fills the
// solid. Selecting the top face:
//   * depth 1 must reproduce tag_step_face's one-voxel slab (top layer only);
//   * depth 2 must select the top two layers;
//   * the grid's tags must be untouched (the mask is a separate array).
//
// No third-party test framework (ARCHITECTURE §4); same self-contained CHECK
// harness and cube fixture as test_tag.cpp, public API only.

#include "topopt/mesh.hpp"
#include "topopt/step.hpp"
#include "topopt/voxel.hpp"

#include <cmath>
#include <cstddef>
#include <cstdio>
#include <stdexcept>
#include <string>

using topopt::bounding_box;
using topopt::DesignMask;
using topopt::import_step_file;
using topopt::make_active_mask;
using topopt::mask_step_face;
using topopt::MaskValue;
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

// The face id whose tessellation triangles all sit on the plane z == target.
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
  Vec3 lo, hi;
  bounding_box(m.mesh, lo, hi);
  const int top = face_on_z_plane(m, hi.z, 1e-6);  // z == 10 face
  CHECK(top >= 0, "found the +Z (top) cube face");

  // === depth 1 reproduces the M1.6 one-voxel slab ============================
  {
    VoxelGrid g = voxelize(m.mesh, 10);
    const int top_k = g.nz - 1;
    DesignMask mask = make_active_mask(g);
    const std::size_t n = mask_step_face(g, m, top, MaskValue::FrozenVoid, 1, mask);
    CHECK(n == static_cast<std::size_t>(g.nx) * g.ny,
          "depth 1: selects exactly one full cross-section slab");

    bool exact = true;
    std::size_t set = 0;
    for (int k = 0; k < g.nz; ++k)
      for (int j = 0; j < g.ny; ++j)
        for (int i = 0; i < g.nx; ++i) {
          const bool frozen = mask[g.index(i, j, k)] == MaskValue::FrozenVoid;
          if (frozen) ++set;
          if (frozen != (k == top_k)) exact = false;
        }
    CHECK(exact, "depth 1: masked voxels are exactly the top (k==nz-1) layer");
    CHECK(set == n, "depth 1: reported count matches the mask entries set");

    // depth 1 selects the SAME voxel set tag_step_face(M1.6) tags.
    VoxelGrid gt = voxelize(m.mesh, 10);
    const std::size_t nt = tag_step_face(gt, m, top, VoxelTag::Load);
    CHECK(nt == n, "depth 1: same count as tag_step_face");
    bool same_set = true;
    for (int k = 0; k < g.nz; ++k)
      for (int j = 0; j < g.ny; ++j)
        for (int i = 0; i < g.nx; ++i) {
          const bool frozen = mask[g.index(i, j, k)] == MaskValue::FrozenVoid;
          const bool tagged = gt.tag(i, j, k) == VoxelTag::Load;
          if (frozen != tagged) same_set = false;
        }
    CHECK(same_set, "depth 1: same voxel set as the M1.6 slab selection");

    // The mask is a SEPARATE array: the grid's tags were not modified.
    bool tags_untouched = true;
    for (VoxelTag t : g.tags)
      if (t != VoxelTag::Interior && t != VoxelTag::Surface)
        tags_untouched = false;
    CHECK(tags_untouched, "depth 1: grid tags are untouched (mask is separate)");
  }

  // === depth 2 selects the top two voxel layers =============================
  {
    VoxelGrid g = voxelize(m.mesh, 10);
    DesignMask mask = make_active_mask(g);
    const std::size_t n =
        mask_step_face(g, m, top, MaskValue::FrozenSolid, 2, mask);
    CHECK(n == 2u * static_cast<std::size_t>(g.nx) * g.ny,
          "depth 2: selects two full cross-section slabs");

    bool exact = true;
    for (int k = 0; k < g.nz; ++k)
      for (int j = 0; j < g.ny; ++j)
        for (int i = 0; i < g.nx; ++i) {
          const bool frozen = mask[g.index(i, j, k)] == MaskValue::FrozenSolid;
          const bool in_top_two = (k >= g.nz - 2);
          if (frozen != in_top_two) exact = false;
        }
    CHECK(exact, "depth 2: masked voxels are exactly the top two layers");
  }

  // === argument validation ==================================================
  {
    VoxelGrid g = voxelize(m.mesh, 10);
    DesignMask mask = make_active_mask(g);
    auto throws_invalid = [&](int face_id, int depth, std::size_t mask_size) {
      DesignMask mm(mask_size, MaskValue::Active);
      try {
        mask_step_face(g, m, face_id, MaskValue::FrozenVoid, depth, mm);
      } catch (const std::invalid_argument&) {
        return true;
      }
      return false;
    };
    CHECK(throws_invalid(top, 0, g.voxel_count()), "depth 0 rejected");
    CHECK(throws_invalid(top, -1, g.voxel_count()), "negative depth rejected");
    CHECK(throws_invalid(-1, 1, g.voxel_count()), "negative face_id rejected");
    CHECK(throws_invalid(m.face_count, 1, g.voxel_count()),
          "face_id == face_count rejected");
    CHECK(throws_invalid(top, 1, g.voxel_count() - 1),
          "wrong-size mask rejected");
  }

  if (g_failures == 0) {
    std::printf("mask_step_face (M3.7): all %d checks passed\n", g_checks);
    return 0;
  }
  std::fprintf(stderr, "mask_step_face (M3.7): %d/%d checks FAILED\n", g_failures,
               g_checks);
  return 1;
}
