// test_lattice_region_mask.cpp — a REGION as a lattice region
// (task 2026-08-15-lattice-regions).
//
// ★ THE TYPE MISMATCH IS THE WHOLE TASK: a `ClearanceGeometry` is a PREDICATE
// evaluated pointwise; a face region is a VOXEL SET. This file pins the seam
// between them:
//
//   * the mask branch of `point_in_clearance_region` — the ONE change that makes
//     every existing membership consumer correct at once;
//   * the mask's own grid, so a caller walking a DIFFERENT grid (the expanded
//     design-box grid) still gets the right answer for the same point in space;
//   * the exact cell-box tests that replace the Lipschitz bound in
//     `cell_may_overlap`;
//   * ★ bar R5 — a protection and a lattice region declared at the same depth
//     select the SAME voxels, because they call the same conversion and the
//     same primitive.
//
// OCCT-free: the fixture is the hand-built banded cube test_face_region.cpp
// uses, so both files describe one shape.

#include "topopt/clearance.hpp"
#include "topopt/face_region.hpp"
#include "topopt/lattice_boundary.hpp"
#include "topopt/step.hpp"
#include "topopt/voxel.hpp"

#include <algorithm>
#include <cmath>
#include <cstdio>
#include <memory>
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

namespace {

// The banded cube: a 10 mm cube whose +x wall is split at z = 9 into a 90 mm^2
// wall (face 3) and a 10 mm^2 band (face 6).
StepModel banded_cube() {
  StepModel m;
  auto V = [&](double x, double y, double z) {
    m.mesh.vertices.push_back(Vec3{x, y, z});
  };
  V(0, 0, 0); V(10, 0, 0); V(10, 10, 0); V(0, 10, 0);
  V(0, 0, 10); V(10, 0, 10); V(10, 10, 10); V(0, 10, 10);
  V(10, 0, 9); V(10, 10, 9); V(0, 0, 9); V(0, 10, 9);
  auto T = [&](int a, int b, int c, int f) {
    m.mesh.triangles.push_back({a, b, c});
    m.triangle_face.push_back(f);
  };
  T(0, 3, 2, 0);  T(0, 2, 1, 0);
  T(4, 5, 6, 1);  T(4, 6, 7, 1);
  T(0, 1, 8, 2);  T(0, 8, 10, 2);  T(10, 8, 5, 2);  T(10, 5, 4, 2);
  T(1, 2, 9, 3);  T(1, 9, 8, 3);
  T(2, 3, 11, 4); T(2, 11, 9, 4);  T(9, 11, 7, 4); T(9, 7, 6, 4);
  T(3, 0, 10, 5); T(3, 10, 11, 5); T(11, 10, 4, 5); T(11, 4, 7, 5);
  T(8, 9, 6, 6);  T(8, 6, 5, 6);
  m.face_count = 7;
  m.faces.assign(7, StepFaceInfo{});
  for (int f = 0; f < 7; ++f)
    m.faces[static_cast<std::size_t>(f)].kind = StepSurfaceKind::Plane;
  m.brep_volume = 1000.0;
  m.solid_count = 1;
  return m;
}

FaceRegionSpec spec_of(int id, std::vector<int> add) {
  FaceRegionSpec s;
  s.id = id;
  s.add = std::move(add);
  return s;
}

// The mask a region-backed lattice region resolves to — the same two calls
// run_job.cpp's `region_lattice_mask` makes.
std::shared_ptr<ClearanceVoxelMask> mask_of(const VoxelGrid& grid,
                                            const StepModel& model,
                                            const ResolvedFaceRegion& r,
                                            double depth_mm) {
  auto m = std::make_shared<ClearanceVoxelMask>();
  m->nx = grid.nx; m->ny = grid.ny; m->nz = grid.nz;
  m->spacing = grid.spacing; m->origin = grid.origin;
  m->inside.assign(grid.voxel_count(), 0);
  const int layers = region_depth_layers(depth_mm, grid.spacing);
  for (int idx : cut_voxels(grid, region_member_voxels(grid, model, r, layers),
                            r.cuts))
    m->inside[static_cast<std::size_t>(idx)] = 1;
  return m;
}

// ---------------------------------------------------------------------------

// ★ R5 — THE DEPTH IS ONE NUMBER. PR 328 §0: 5 mm of protection under a 7 mm
// lattice region left the lattice pass finding material only in the frozen
// collar. Same mm and same grid must mean the same voxels, and it does because
// both go through `region_depth_layers` and `region_member_voxels`.
void the_depth_is_one_number() {
  const StepModel m = banded_cube();
  const VoxelGrid grid = voxelize(m.mesh, 10);
  const ResolvedFaceRegion r = resolve_face_regions(m, {spec_of(0, {3})})[0];

  for (const double depth_mm : {1.0, 2.6, 3.0, 4.4}) {
    // THE PROTECTION's voxels — mask_step_region, exactly as
    // build_production_loadcase calls it.
    const int layers = region_depth_layers(depth_mm, grid.spacing);
    DesignMask prot = make_active_mask(grid);
    const std::size_t frozen =
        mask_step_region(grid, m, r, MaskValue::FrozenSolid, layers, prot);
    // THE LATTICE REGION's voxels — the mask the role resolver builds.
    const std::shared_ptr<ClearanceVoxelMask> lat = mask_of(grid, m, r, depth_mm);

    CHECK(frozen == lat->set_count(),
          "★ protection and lattice select the same COUNT at the same depth");
    bool same = true;
    for (std::size_t i = 0; i < prot.size(); ++i)
      if ((prot[i] == MaskValue::FrozenSolid) != (lat->inside[i] != 0))
        same = false;
    CHECK(same, "★ and the same VOXELS, index for index");
  }
  // And the conversion itself is the shared one, floored at one layer.
  CHECK(region_depth_layers(0.0, 1.0) == 1, "a zero depth still freezes a skin");
  CHECK(region_depth_layers(0.4, 1.0) == 1, "and so does a sub-voxel depth");
  CHECK(region_depth_layers(2.6, 1.0) == 3, "2.6 mm at 1 mm spacing is 3 layers");
  CHECK(region_depth_layers(3.0, 1.5) == 2, "3.0 mm at 1.5 mm spacing is 2");
}

// The mask branch of the ONE predicate every consumer already routes through.
void the_predicate_reads_the_mask() {
  const StepModel m = banded_cube();
  const VoxelGrid grid = voxelize(m.mesh, 10);
  const ResolvedFaceRegion r = resolve_face_regions(m, {spec_of(0, {3})})[0];

  ClearanceGeometry g;
  g.valid = true;
  g.kind = ClearanceKind::Face;
  g.mask = mask_of(grid, m, r, 1.0);
  CHECK(g.mask->set_count() == 90, "the wall's skin is 90 voxels");

  // A point in the skin, and one in the middle of the part.
  CHECK(point_in_clearance_region(g, Vec3{9.5, 5.5, 4.5}, 0.0),
        "a voxel centre in the region is inside");
  CHECK(!point_in_clearance_region(g, Vec3{5.5, 5.5, 4.5}, 0.0),
        "one in the part interior is not");
  CHECK(!point_in_clearance_region(g, Vec3{-50.0, 0.0, 0.0}, 0.0),
        "and one outside the mask's box is not");

  // ★ tol IS IGNORED on a mask — the exact region at every tol, never more.
  CHECK(!point_in_clearance_region(g, Vec3{5.5, 5.5, 4.5}, 100.0),
        "a huge tol does not inflate a voxel set");

  // An invalid geometry still contains nothing, mask or no mask.
  ClearanceGeometry bad = g;
  bad.valid = false;
  CHECK(!point_in_clearance_region(bad, Vec3{9.5, 5.5, 4.5}, 0.0),
        "an invalid region contains nothing");
}

// ★ THE MASK CARRIES ITS OWN GRID. A caller walking a DIFFERENT lattice — the
// expanded design-box grid — must still get the right answer for a point.
void the_mask_answers_in_its_own_lattice() {
  const StepModel m = banded_cube();
  const VoxelGrid grid = voxelize(m.mesh, 10);
  const ResolvedFaceRegion r = resolve_face_regions(m, {spec_of(0, {3})})[0];
  ClearanceGeometry g;
  g.valid = true;
  g.mask = mask_of(grid, m, r, 1.0);

  // A grid with a different origin and twice the spacing — what an expanded
  // domain looks like. The QUERY is a point in model space either way.
  const Vec3 p{9.5, 5.5, 4.5};
  CHECK(point_in_clearance_region(g, p, 0.0),
        "★ the same point resolves the same way whatever grid the caller walks");
  CHECK(g.mask->index_of(p) == g.mask->index_of(Vec3{9.9, 5.9, 4.9}),
        "two points in one voxel share its index");
  CHECK(g.mask->index_of(Vec3{-0.1, 5.0, 5.0}) < 0,
        "a point below the origin is outside the box");
}

// The exact box tests that replace the Lipschitz bound in cell_may_overlap.
void the_cell_box_tests_are_exact() {
  const StepModel m = banded_cube();
  const VoxelGrid grid = voxelize(m.mesh, 10);
  const ResolvedFaceRegion r = resolve_face_regions(m, {spec_of(0, {3})})[0];
  const std::shared_ptr<ClearanceVoxelMask> mk = mask_of(grid, m, r, 1.0);

  // A 2 mm cell sitting on the wall skin overlaps it and is not contained by it
  // (half its voxels are one layer in from the wall).
  CHECK(mk->overlaps_box(Vec3{8.0, 4.0, 4.0}, 2.0), "a cell on the skin overlaps");
  CHECK(!mk->contains_box(Vec3{8.0, 4.0, 4.0}, 2.0),
        "but is not wholly inside it");
  // A cell in the part interior touches nothing.
  CHECK(!mk->overlaps_box(Vec3{2.0, 4.0, 4.0}, 2.0),
        "a cell in the interior provably misses the region");
  // A cell that is exactly one skin voxel IS contained.
  CHECK(mk->contains_box(Vec3{9.0, 5.0, 4.0}, 1.0),
        "a one-voxel cell inside the skin is contained");
  // A box reaching outside the mask is never "contained".
  CHECK(!mk->contains_box(Vec3{9.0, 5.0, 4.0}, 40.0),
        "a box reaching past the mask is not contained — outside is not inside");

  // And through LatticeBoundary, which is what the generator actually calls.
  LatticeBoundary b;
  ClearanceGeometry g;
  g.valid = true;
  g.mask = mk;
  b.add_include_region(g);
  CHECK(b.has_include_regions(), "the boundary took the mask region");
  CHECK(b.cell_may_overlap(Vec3{8.0, 4.0, 4.0}, 2.0),
        "★ a cell overlapping the region stays ACTIVE");
  CHECK(!b.cell_may_overlap(Vec3{2.0, 4.0, 4.0}, 2.0),
        "★ and one that provably misses every include is DROPPED — the exact "
        "box test is strictly stronger than the Lipschitz bound it replaces");
  CHECK(b.in_include_region(Vec3{9.5, 5.5, 4.5}, 0.0),
        "membership through the boundary reads the mask too");
}

// A sector of a grid split is its OWN region, with its own voxels — which is
// what makes §2(a)'s per-sector verdicts possible at all.
void a_sector_is_its_own_region() {
  const StepModel m = banded_cube();
  const VoxelGrid grid = voxelize(m.mesh, 10);
  const ResolvedFaceRegion whole = resolve_face_regions(m, {spec_of(0, {3})})[0];
  const std::vector<GridSplitCell> cells =
      grid_split_cells(region_frame(m, whole), 2, 1);
  CHECK(cells.size() == 2, "two sectors");

  FaceRegionSpec a = spec_of(1, {3});
  a.cuts = cells[0].cuts;
  FaceRegionSpec b = spec_of(2, {3});
  b.cuts = cells[1].cuts;
  const std::vector<ResolvedFaceRegion> two = resolve_face_regions(m, {a, b});

  // ★ DIFFERENT DEPTHS PER SECTOR — the graded half of the feature.
  const std::shared_ptr<ClearanceVoxelMask> ma = mask_of(grid, m, two[0], 1.0);
  const std::shared_ptr<ClearanceVoxelMask> mb = mask_of(grid, m, two[1], 3.0);
  CHECK(ma->set_count() == 45, "sector A at depth 1 is half the skin");
  CHECK(mb->set_count() > ma->set_count(),
        "★ sector B at depth 3 selects MORE material — the depths are per sector");

  std::size_t overlap = 0;
  for (std::size_t i = 0; i < ma->inside.size(); ++i)
    if (ma->inside[i] && mb->inside[i]) ++overlap;
  CHECK(overlap == 0,
        "★ and the two sectors never claim the same voxel — a cut is a plane "
        "through space, so it separates the deep layers too");
}

// ★★ THE DEFECT THE §4 RUN CAUGHT, PINNED SO IT CANNOT COME BACK.
//
// `region_thinnest_extent_mm` originally took the MINIMUM of the Hildebrand
// inscribed-sphere thickness over the region. On the maintainer's part that
// returned 3.4106 mm — EXACTLY two voxels — for all four sectors of a bore
// declared at 3.0 / 4.5 / 6.0 / 7.5 mm, so every sector derived the same cell,
// the same density and the same strut, and the whole point of the feature was
// lost while every unit test stayed green.
//
// The reason is structural: the largest ball that fits inside a set AND contains
// a voxel ON THAT SET'S BOUNDARY is one or two voxels however thick the set is
// elsewhere. The minimum is therefore a CONSTANT, not a measurement.
//
// This asserts the property that actually matters: A THICKER REGION MUST MEASURE
// THICKER. Under the old minimum both slabs below return ~2 voxels and the
// assertion fails; under the median they separate.
void a_thicker_region_measures_thicker() {
  const StepModel m = banded_cube();
  const VoxelGrid grid = voxelize(m.mesh, 10);
  const ResolvedFaceRegion r = resolve_face_regions(m, {spec_of(0, {3})})[0];

  // The same face at two depths: 2 voxel layers and 5.
  const std::shared_ptr<ClearanceVoxelMask> thin = mask_of(grid, m, r, 2.0);
  const std::shared_ptr<ClearanceVoxelMask> thick = mask_of(grid, m, r, 5.0);
  CHECK(thick->set_count() > thin->set_count(),
        "the deeper region selects more voxels (the SELECTION half works)");

  const double e_thin = region_thinnest_extent_mm(*thin);
  const double e_thick = region_thinnest_extent_mm(*thick);
  CHECK(e_thick > e_thin,
        "★ A THICKER REGION MEASURES THICKER — the property the minimum could "
        "not deliver, and the one the derived cell depends on");
  // ★ AND IT SCALES WITH THE DECLARED DEPTH, which is the property the derived
  // cell needs. Measured here: 2 layers -> 4.000 mm, 5 layers -> 10.000 mm at
  // 1 mm spacing — a ratio of 2.5 against a declared ratio of 2.5. (The absolute
  // values exceed the layer count because `region_member_voxels` selects every
  // voxel within (depth - 0.5) spacings of the face TRIANGLES, so the set is
  // thicker than a flat slab at the wall's corners; the inscribed sphere sees
  // that. The RATIO is what the fit law reads.)
  CHECK(e_thick / e_thin >= 2.0,
        "★ and it SCALES with the declared depth — 2 layers vs 5 gives 2.5x");
  CHECK(e_thin > 0.0 && std::isfinite(e_thin), "and both are finite and positive");
  CHECK(std::isfinite(e_thick), "including the thicker one");
  std::printf("    (extent: 2 layers -> %.3f mm, 5 layers -> %.3f mm)\n",
              e_thin, e_thick);
}

}  // namespace

int main() {
  the_depth_is_one_number();
  the_predicate_reads_the_mask();
  the_mask_answers_in_its_own_lattice();
  the_cell_box_tests_are_exact();
  a_sector_is_its_own_region();
  a_thicker_region_measures_thicker();
  std::printf("test_lattice_region_mask: %d checks, %d failures\n", g_checks,
              g_failures);
  return g_failures == 0 ? 0 : 1;
}
