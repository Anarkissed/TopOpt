// Unit tests for the shape-aware clearance rasterizer (handoff 100).
//
// mask_clearance_region derives a FrozenVoid keep-out from a B-rep face's exact
// axis/radius/normal (StepFaceInfo). Its math needs no OCCT — it consumes an
// already-populated StepModel — so this builds a SYNTHETIC cylinder + plane
// model by hand and asserts the swept-cylinder / bounded-slab semantics and the
// precedence guard (part material is never voided). Same self-contained CHECK
// harness as the other unit tests (ARCHITECTURE §4 locks the dependency set).

#include "topopt/clearance.hpp"
#include "topopt/mesh.hpp"
#include "topopt/step.hpp"
#include "topopt/voxel.hpp"

#include <cstdio>

using topopt::ClearanceKind;
using topopt::ClearanceParams;
using topopt::ClearanceRasterResult;
using topopt::DesignMask;
using topopt::mask_clearance_region;
using topopt::MaskValue;
using topopt::StepFaceInfo;
using topopt::StepModel;
using topopt::StepSurfaceKind;
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

// An all-Empty cubic grid of `n` voxels per side, unit spacing, origin at 0.
static VoxelGrid make_grid(int n) {
  VoxelGrid g;
  g.nx = g.ny = g.nz = n;
  g.spacing = 1.0;
  g.origin = Vec3{0.0, 0.0, 0.0};
  g.tags.assign(static_cast<std::size_t>(n) * n * n, VoxelTag::Empty);
  return g;
}

// A synthetic 2-face model: face 0 a cylinder (axis ∥ Z at (8,8), r=2, span
// z∈[4,12]); face 1 a plane (outward +X normal at x=12, outline y∈[4,8] z∈[4,8]).
static StepModel make_model() {
  StepModel m;
  m.face_count = 2;
  m.faces.resize(2);
  m.faces[0].kind = StepSurfaceKind::Cylinder;
  m.faces[0].cylinder_radius_mm = 2.0;
  m.faces[0].axis_point = Vec3{8.0, 8.0, 0.0};
  m.faces[0].axis_dir = Vec3{0.0, 0.0, 1.0};
  m.faces[1].kind = StepSurfaceKind::Plane;
  m.faces[1].plane_normal = Vec3{1.0, 0.0, 0.0};
  m.faces[1].plane_origin = Vec3{12.0, 6.0, 6.0};

  // Face 0 tessellation: one triangle whose vertices pin the axial span [4,12].
  m.mesh.vertices = {
      Vec3{8.0, 8.0, 4.0}, Vec3{10.0, 8.0, 4.0}, Vec3{8.0, 8.0, 12.0},
      // Face 1 tessellation: the plane outline rectangle x=12, y∈[4,8], z∈[4,8].
      Vec3{12.0, 4.0, 4.0}, Vec3{12.0, 8.0, 4.0}, Vec3{12.0, 4.0, 8.0},
      Vec3{12.0, 8.0, 8.0}};
  m.mesh.triangles = {{0, 1, 2}, {3, 4, 5}, {4, 6, 5}};
  m.triangle_face = {0, 1, 1};
  return m;
}

int main() {
  const StepModel model = make_model();

  // === Bolt clearance: swept cylinder around a bore (no design box) =========
  // No box → the solved grid IS the part grid, offsets 0. margin 1 → keep-out
  // radius 3; axial 1 → swept z∈[3,13].
  {
    VoxelGrid grid = make_grid(16);
    VoxelGrid part = grid;  // all Empty (bore interior is void, as on the real part)
    DesignMask out(grid.voxel_count(), MaskValue::Active);
    ClearanceParams p;
    p.kind = ClearanceKind::Bolt;
    p.concentric_margin_mm = 1.0;
    p.axial_clearance_mm = 1.0;

    ClearanceRasterResult r =
        mask_clearance_region(grid, part, 0, 0, 0, model, 0, p, out);
    CHECK(r.region_in_grid, "bolt region intersects the grid");
    CHECK(r.voxels_frozen > 0, "bolt region freezes voxels");

    auto frozen = [&](int i, int j, int k) {
      return out[grid.index(i, j, k)] == MaskValue::FrozenVoid;
    };
    // On the axis, mid-span → inside the swept cylinder.
    CHECK(frozen(8, 8, 6), "bore-centre voxel is FrozenVoid");
    // Within the concentric margin (radial ~1.6) but outside the bore → cleared.
    CHECK(frozen(9, 8, 6), "concentric-margin voxel is FrozenVoid");
    // Beyond the keep-out radius (radial ~5) → untouched.
    CHECK(!frozen(13, 8, 6), "voxel outside keep-out radius stays Active");
    // Beyond the axial band (z ~ 15 > 13) → untouched.
    CHECK(!frozen(8, 8, 15), "voxel beyond axial clearance stays Active");
    // Just inside the extended axial band (z ~ 3.5) → cleared.
    CHECK(frozen(8, 8, 3), "voxel inside extended axial band is FrozenVoid");
  }

  // === Precedence: a concentric margin overlapping PART material ============
  // A part-solid voxel inside the margin ring must stay solid — FrozenSolid/part
  // WINS over clearance FrozenVoid (design 095 STEP 1c). This is the acceptance
  // guard: clearance forbids new growth, it never carves the part.
  {
    VoxelGrid grid = make_grid(16);
    VoxelGrid part = grid;
    // Mark a part voxel inside the keep-out ring solid: (10,8,6) sits at radial
    // ~2.06 from the axis (bore r=2, keep-out r=3) — squarely in the margin.
    part.set_tag(10, 8, 6, VoxelTag::Interior);
    DesignMask out(grid.voxel_count(), MaskValue::Active);
    ClearanceParams p;
    p.kind = ClearanceKind::Bolt;
    p.concentric_margin_mm = 1.0;
    p.axial_clearance_mm = 1.0;

    ClearanceRasterResult r =
        mask_clearance_region(grid, part, 0, 0, 0, model, 0, p, out);
    CHECK(out[grid.index(10, 8, 6)] != MaskValue::FrozenVoid,
          "part-solid voxel in the margin is NOT voided (part wins)");
    // Its void neighbour at the same radius on the other side IS still cleared,
    // proving the guard is per-voxel, not disabling the whole region.
    CHECK(out[grid.index(6, 8, 6)] == MaskValue::FrozenVoid,
          "void voxel in the margin is still cleared");
    CHECK(r.region_voxels > r.voxels_frozen,
          "the part voxel counts in the region but was not frozen");
  }

  // === Face clearance: a bounded slab extruded outward from a plane ==========
  // Outward +X slab, depth 2 → x∈[12,14], within the face outline y,z∈[4,8].
  {
    VoxelGrid grid = make_grid(16);
    VoxelGrid part = grid;
    DesignMask out(grid.voxel_count(), MaskValue::Active);
    ClearanceParams p;
    p.kind = ClearanceKind::Face;
    p.slab_depth_mm = 2.0;

    ClearanceRasterResult r =
        mask_clearance_region(grid, part, 0, 0, 0, model, 1, p, out);
    CHECK(r.region_in_grid, "face slab intersects the grid");
    auto frozen = [&](int i, int j, int k) {
      return out[grid.index(i, j, k)] == MaskValue::FrozenVoid;
    };
    // In front of the face, within the outline and slab depth → cleared.
    CHECK(frozen(13, 6, 6), "voxel in the outward slab is FrozenVoid");
    // Behind the face (x < 12) → untouched (the slab is one-sided/outward).
    CHECK(!frozen(11, 6, 6), "voxel behind the face stays Active");
    // Beyond the slab depth (x ~ 15.5 > 14) → untouched.
    CHECK(!frozen(15, 6, 6), "voxel beyond slab depth stays Active");
    // In front but outside the outline (y ~ 0.5 < 4) → untouched (bounded, not a
    // half-space — this is what lets a wrap-around gusset still grow).
    CHECK(!frozen(13, 0, 6), "voxel outside the face outline stays Active");
  }

  // === Honesty: a region entirely OUTSIDE the solved grid ===================
  // A bore whose axis sits far outside the grid touches no voxel: region_in_grid
  // is false and nothing is frozen, so the caller can SURFACE the no-op.
  {
    StepModel far = make_model();
    far.faces[0].axis_point = Vec3{100.0, 100.0, 0.0};
    VoxelGrid grid = make_grid(16);
    VoxelGrid part = grid;
    DesignMask out(grid.voxel_count(), MaskValue::Active);
    ClearanceParams p;
    p.kind = ClearanceKind::Bolt;
    p.concentric_margin_mm = 1.0;
    p.axial_clearance_mm = 1.0;

    ClearanceRasterResult r =
        mask_clearance_region(grid, part, 0, 0, 0, far, 0, p, out);
    CHECK(!r.region_in_grid, "out-of-grid region reports region_in_grid=false");
    CHECK(r.voxels_frozen == 0, "out-of-grid region freezes nothing");
  }

  // === Offset: solved grid larger than the part (design-box path) ===========
  // Simulate an expanded grid: the part sits at offset (2,2,2) inside a larger
  // solved grid. A part voxel at the offset location must still be protected.
  {
    VoxelGrid solved = make_grid(20);
    VoxelGrid part = make_grid(16);
    // The part's frame is shifted: its origin is the solved origin + offset*spacing.
    // Model coordinates are absolute, so shift the model's cylinder to sit over
    // the part. Easiest: keep the model fixed and place the part solid voxel at
    // the SOLVED location (10,8,6) → part index (8,6,4).
    part.set_tag(8, 6, 4, VoxelTag::Interior);
    DesignMask out(solved.voxel_count(), MaskValue::Active);
    ClearanceParams p;
    p.kind = ClearanceKind::Bolt;
    p.concentric_margin_mm = 1.0;
    p.axial_clearance_mm = 1.0;

    mask_clearance_region(solved, part, 2, 2, 2, model, 0, p, out);
    CHECK(out[solved.index(10, 8, 6)] != MaskValue::FrozenVoid,
          "offset part voxel is protected at its solved location");
    CHECK(out[solved.index(8, 8, 6)] == MaskValue::FrozenVoid,
          "a void voxel over the bore is still cleared on the expanded grid");
  }

  if (g_failures == 0) {
    std::printf("clearance: all %d checks passed\n", g_checks);
    return 0;
  }
  std::fprintf(stderr, "clearance: %d/%d checks FAILED\n", g_failures, g_checks);
  return 1;
}
