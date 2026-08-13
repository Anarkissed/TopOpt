// test_face_region.cpp — the REGION layer (task 2026-08-14-face-regions §1).
//
// OCCT-FREE BY DESIGN. The fixture is a hand-built StepModel, so this runs in
// every configuration — the same reason face_region.cpp itself is OCCT-free.
//
// THE FIXTURE is a 10 mm cube whose +x wall is split in two by a horizontal
// edge at z = 9: a 90 mm^2 wall (face 3) and a 10 mm^2 BAND (face 6). The band
// is small and touches four larger faces — the exact shape of the maintainer's
// seven 16-voxel blend faces (41-47) beside his 10,554-voxel wall. The three
// side faces the split crosses are re-triangulated through the new vertices so
// the mesh carries NO T-junctions: edge adjacency is only meaningful on a
// welded mesh, and a T-junction would silently hide the very adjacency the
// blend filter reads.
//
// Voxelized at resolution 10 the cube tiles a 10x10x10 unit-voxel grid that
// exactly fills the solid, so every expected voxel count below is exact.
//
// ★ THE BAR THIS FILE EXISTS FOR is `identity_is_byte_for_byte`: a region with
// ONE member face and NO cuts must tag EXACTLY the voxels tag_step_face tags for
// that face, and mask EXACTLY what mask_step_face masks. That identity is what
// makes day one byte-identical (R1) — regions are not a new selection rule, they
// are the same rule with a second name.

#include "topopt/face_region.hpp"
#include "topopt/mesh.hpp"
#include "topopt/step.hpp"
#include "topopt/voxel.hpp"

#include <algorithm>
#include <cmath>
#include <cstdio>
#include <set>
#include <stdexcept>
#include <string>
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

// The banded cube described in the header comment. Face ids:
//   0 bottom (z=0)   1 top (z=10)   2 y=0   3 +x wall below z=9
//   4 y=10           5 x=0          6 +x BAND, z in [9,10]
StepModel banded_cube() {
  StepModel m;
  auto V = [&](double x, double y, double z) {
    m.mesh.vertices.push_back(Vec3{x, y, z});
  };
  V(0, 0, 0);    // 0
  V(10, 0, 0);   // 1
  V(10, 10, 0);  // 2
  V(0, 10, 0);   // 3
  V(0, 0, 10);   // 4
  V(10, 0, 10);  // 5
  V(10, 10, 10); // 6
  V(0, 10, 10);  // 7
  V(10, 0, 9);   // 8
  V(10, 10, 9);  // 9
  V(0, 0, 9);    // 10
  V(0, 10, 9);   // 11

  auto T = [&](int a, int b, int c, int face) {
    m.mesh.triangles.push_back({a, b, c});
    m.triangle_face.push_back(face);
  };
  T(0, 3, 2, 0);  T(0, 2, 1, 0);                            // bottom
  T(4, 5, 6, 1);  T(4, 6, 7, 1);                            // top
  T(0, 1, 8, 2);  T(0, 8, 10, 2);  T(10, 8, 5, 2);  T(10, 5, 4, 2);   // y=0
  T(1, 2, 9, 3);  T(1, 9, 8, 3);                            // +x wall
  T(2, 3, 11, 4); T(2, 11, 9, 4);  T(9, 11, 7, 4); T(9, 7, 6, 4);     // y=10
  T(3, 0, 10, 5); T(3, 10, 11, 5); T(11, 10, 4, 5); T(11, 4, 7, 5);   // x=0
  T(8, 9, 6, 6);  T(8, 6, 5, 6);                            // +x BAND

  m.face_count = 7;
  m.faces.assign(7, StepFaceInfo{});
  const Vec3 normals[7] = {{0, 0, -1}, {0, 0, 1}, {0, -1, 0}, {1, 0, 0},
                           {0, 1, 0},  {-1, 0, 0}, {1, 0, 0}};
  for (int f = 0; f < 7; ++f) {
    m.faces[static_cast<std::size_t>(f)].kind = StepSurfaceKind::Plane;
    m.faces[static_cast<std::size_t>(f)].plane_normal = normals[f];
  }
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

bool near(double a, double b, double tol) { return std::fabs(a - b) <= tol; }

// The grid indices carrying `tag`, ascending.
std::vector<std::size_t> tagged_indices(const VoxelGrid& g, VoxelTag tag) {
  std::vector<std::size_t> out;
  for (int k = 0; k < g.nz; ++k)
    for (int j = 0; j < g.ny; ++j)
      for (int i = 0; i < g.nx; ++i)
        if (g.tag(i, j, k) == tag) out.push_back(g.index(i, j, k));
  return out;
}

// ---------------------------------------------------------------------------

void measures() {
  const StepModel m = banded_cube();
  const std::vector<double> areas = face_areas_mm2(m);
  CHECK(areas.size() == 7, "one area per face");
  CHECK(near(areas[0], 100.0, 1e-9), "bottom is 100 mm^2");
  CHECK(near(areas[1], 100.0, 1e-9), "top is 100 mm^2");
  CHECK(near(areas[3], 90.0, 1e-9), "the +x wall below the band is 90 mm^2");
  CHECK(near(areas[6], 10.0, 1e-9), "the band is 10 mm^2");

  const std::vector<std::vector<int>> adj = face_adjacency(m);
  CHECK(adj.size() == 7, "one adjacency row per face");
  const std::set<int> band(adj[6].begin(), adj[6].end());
  CHECK(band == (std::set<int>{1, 2, 3, 4}),
        "the band touches the top, both sides and the wall below it — and NOT "
        "the bottom or the far wall");
  CHECK(std::find(adj[3].begin(), adj[3].end(), 6) != adj[3].end(),
        "adjacency is symmetric");
}

void filters() {
  const StepModel m = banded_cube();

  // ★ THE BLEND HEURISTIC: small AND adjacent to two larger faces. This is what
  // "select all fillets and chamfers" actually means — NOT a `kind` filter,
  // which would miss every flat chamfer and catch unrelated splines.
  RegionFilter blend;
  blend.max_area_mm2 = 20.0;
  blend.min_larger_neighbours = 2;
  blend.larger_ratio = 2.0;
  const std::vector<int> hit = match_region_filter(m, blend);
  CHECK(hit == (std::vector<int>{6}), "the blend filter matches the band alone");

  // Size alone is the same match here, but it is a WEAKER statement: it would
  // also catch a small isolated boss. The adjacency clause is what makes it a
  // blend rather than merely a small face.
  RegionFilter small;
  small.max_area_mm2 = 20.0;
  CHECK(match_region_filter(m, small) == (std::vector<int>{6}),
        "size alone also matches the band on this fixture");

  RegionFilter planes;
  planes.kind = "plane";
  CHECK(match_region_filter(m, planes).size() == 7, "every face is a plane");

  RegionFilter cyl;
  cyl.kind = "cylinder";
  CHECK(match_region_filter(m, cyl).empty(), "no cylinders on a cube");

  RegionFilter bores;
  bores.cylinder_radius_mm = 2.5;
  CHECK(match_region_filter(m, bores).empty(),
        "a radius signature matches nothing when nothing is a cylinder");

  // ★ AN ALL-UNSET FILTER MATCHES NOTHING. It is not "everything": a region
  // that silently swallowed the whole part would be the worst possible default.
  RegionFilter none;
  CHECK(match_region_filter(m, none).empty(), "an unset filter matches nothing");
}

void resolution_and_refusals() {
  const StepModel m = banded_cube();

  const std::vector<ResolvedFaceRegion> one =
      resolve_face_regions(m, {spec_of(0, {3})});
  CHECK(one.size() == 1 && one[0].member_faces == (std::vector<int>{3}),
        "a one-face region resolves to that face");
  CHECK(one[0].member_triangles.size() == 2, "the wall carries two triangles");
  CHECK(near(one[0].area_mm2, 90.0, 1e-9), "and 90 mm^2");

  // ★ UNION: two faces, ONE region, one member set — and NO analytic surface is
  // synthesised. model.faces is untouched; both members keep their own.
  const std::vector<ResolvedFaceRegion> u =
      resolve_face_regions(m, {spec_of(7, {3, 6})});
  CHECK(u[0].member_faces == (std::vector<int>{3, 6}), "the union holds both");
  CHECK(u[0].member_triangles.size() == 4, "and all four triangles");
  CHECK(near(u[0].area_mm2, 100.0, 1e-9), "areas add");

  // A filter-defined region, with a hand correction on top.
  FaceRegionSpec blend;
  blend.id = 1;
  blend.filter.max_area_mm2 = 20.0;
  blend.filter.min_larger_neighbours = 2;
  blend.add = {3};
  const std::vector<ResolvedFaceRegion> b = resolve_face_regions(m, {blend});
  CHECK(b[0].member_faces == (std::vector<int>{3, 6}),
        "filter match plus a tapped face");
  CHECK(b[0].filter_matched == 1, "the filter itself matched one");
  CHECK(!b[0].filter_drift_known, "no author count was recorded, so no drift");

  // ★ DRIFT IS REPORTED, NOT ABSORBED (§3c).
  blend.filter_matched_at_author = 3;
  const std::vector<ResolvedFaceRegion> d = resolve_face_regions(m, {blend});
  CHECK(d[0].filter_drift_known && d[0].filter_drift == -2,
        "a filter that matched 3 at authoring and 1 now reports -2");

  auto throws = [&](const std::vector<FaceRegionSpec>& s) {
    try {
      resolve_face_regions(m, s);
    } catch (const std::invalid_argument&) {
      return true;
    }
    return false;
  };
  CHECK(throws({spec_of(-1, {3})}), "a negative region id is refused");
  CHECK(throws({spec_of(0, {3}), spec_of(0, {6})}),
        "a repeated region id is refused");
  CHECK(throws({spec_of(0, {99})}), "an out-of-range member is refused");
  CHECK(throws({spec_of(0, {})}),
        "★ an EMPTY region is refused — it would tag nothing and report success");
  FaceRegionSpec bad_cut = spec_of(0, {3});
  bad_cut.cuts.push_back(RegionCut{});
  CHECK(throws({bad_cut}), "a zero cut normal is refused");
}

// ★ THE R1 BAR, at the primitive: a one-member zero-cut region IS its face.
void identity_is_byte_for_byte() {
  const StepModel m = banded_cube();
  VoxelGrid base = voxelize(m.mesh, 10);
  CHECK(base.nx == 10 && base.ny == 10 && base.nz == 10, "10^3 grid");

  const std::vector<ResolvedFaceRegion> r =
      resolve_face_regions(m, {spec_of(0, {6})});

  VoxelGrid a = base, b = base;
  const std::size_t by_face = tag_step_face(a, m, 6, VoxelTag::Load);
  const std::size_t by_region = tag_step_region(b, m, r[0], VoxelTag::Load);
  CHECK(by_face == 10, "the band tags its ten voxels");
  CHECK(by_face == by_region, "region and face tag the same COUNT");
  CHECK(tagged_indices(a, VoxelTag::Load) == tagged_indices(b, VoxelTag::Load),
        "★ region and face tag the same VOXELS, index for index");

  DesignMask ma = make_active_mask(base), mb = make_active_mask(base);
  const std::size_t fm =
      mask_step_face(base, m, 3, MaskValue::FrozenSolid, 3, ma);
  const std::size_t rm = mask_step_region(
      base, m, resolve_face_regions(m, {spec_of(0, {3})})[0],
      MaskValue::FrozenSolid, 3, mb);
  CHECK(fm == rm && ma == mb,
        "★ mask_step_region at depth 3 is mask_step_face at depth 3");
  // Three layers behind the 9x10 wall (270) plus the voxels the top row's
  // corner rounds in — mask_step_face measures distance to the TRIANGLES, not
  // depth along a normal, so a voxel diagonally past the wall's top edge is
  // within 2.5 edges of it. The point of the assertion is that the region
  // reproduces that number EXACTLY, corner cases included.
  CHECK(fm == 290, "mask_step_face's own depth-3 count on this wall");
}

void manual_split_partitions() {
  const StepModel m = banded_cube();
  const VoxelGrid grid = voxelize(m.mesh, 10);
  const ResolvedFaceRegion whole = resolve_face_regions(m, {spec_of(0, {3})})[0];
  const std::vector<int> vox = region_member_voxels(grid, m, whole, 1);
  CHECK(vox.size() == 90, "the wall is 90 voxels at resolution 10");

  // A manual cut at y = 5, normal +y: the two halves must partition it.
  RegionCut lo;
  lo.point = Vec3{10.0, 5.0, 4.5};
  lo.normal = Vec3{0.0, 1.0, 0.0};
  RegionCut hi = lo;
  hi.normal = Vec3{0.0, -1.0, 0.0};
  hi.strict = true;
  const std::vector<int> a = cut_voxels(grid, vox, {lo});
  const std::vector<int> b = cut_voxels(grid, vox, {hi});
  CHECK(a.size() == 45 && b.size() == 45, "an even cut splits 90 into 45/45");
  CHECK(a.size() + b.size() == vox.size(),
        "★ the two halves PARTITION the region — no voxel in both, none lost");
}

void grid_split_and_sliver() {
  const StepModel m = banded_cube();
  const VoxelGrid grid = voxelize(m.mesh, 10);
  const ResolvedFaceRegion whole = resolve_face_regions(m, {spec_of(0, {3})})[0];
  const std::vector<int> vox = region_member_voxels(grid, m, whole, 1);

  const RegionFrame frame = region_frame(m, whole);
  CHECK(frame.valid && !frame.cylindrical, "a planar wall gets the PCA frame");
  // The wall is 10 mm along y and 9 mm along z, so y is the principal axis.
  CHECK(near(std::fabs(frame.u.y), 1.0, 1e-6), "u is the long (y) axis");
  CHECK(near(std::fabs(frame.v.z), 1.0, 1e-6), "v is the short (z) axis");
  CHECK(near(frame.u_hi - frame.u_lo, 10.0, 1e-9), "u spans 10 mm");
  CHECK(near(frame.v_hi - frame.v_lo, 9.0, 1e-9), "v spans 9 mm");

  const std::vector<GridSplitCell> cells = grid_split_cells(frame, 2, 2);
  CHECK(cells.size() == 4, "2x2 is four cells");
  const std::vector<std::size_t> counts =
      grid_split_voxel_counts(grid, vox, cells);
  std::size_t total = 0;
  for (std::size_t c : counts) total += c;
  CHECK(total == vox.size(),
        "★ a grid split PARTITIONS: every member voxel lands in exactly one cell");

  const SliverVerdict ok = check_sliver(counts, cells, vox.size());
  CHECK(ok.ok, "2x2 over 90 voxels clears the floor");
  CHECK(ok.min_cell_voxels == 20, "the smallest cell holds 20");

  // ★ R5 — a 10x10 split of a 90-voxel wall REFUSES, with the number.
  const std::vector<GridSplitCell> many = grid_split_cells(frame, 10, 10);
  const std::vector<std::size_t> many_counts =
      grid_split_voxel_counts(grid, vox, many);
  const SliverVerdict bad = check_sliver(many_counts, many, vox.size());
  CHECK(!bad.ok, "10x10 over 90 voxels is refused");
  CHECK(bad.max_cells_budget == 5,
        "90 voxels over a floor of 16 buys at most five cells");
  CHECK(bad.reason.find("under the floor of 16") != std::string::npos,
        "the refusal names the floor");
  CHECK(bad.reason.find("at most 5 cells") != std::string::npos,
        "and names how many cells would fit");

  bool threw = false;
  try {
    grid_split_cells(frame, 0, 3);
  } catch (const std::invalid_argument&) {
    threw = true;
  }
  CHECK(threw, "n < 1 is refused");
}

// A union of blend faces around a bore gets CYLINDRICAL coordinates: n planes
// through the axis, m perpendicular to it. The fixture declares the two +x
// faces cylindrical about a shared y-axis — enough to drive the frame and the
// sector construction without a tessellated tube.
void cylindrical_frame() {
  StepModel m = banded_cube();
  for (int f : {3, 6}) {
    StepFaceInfo& i = m.faces[static_cast<std::size_t>(f)];
    i.kind = StepSurfaceKind::Cylinder;
    i.cylinder_radius_mm = 5.0;
    i.axis_point = Vec3{10.0, 0.0, 4.5};
    i.axis_dir = Vec3{0.0, 1.0, 0.0};
    i.plane_normal = Vec3{0.0, 0.0, 0.0};
  }
  const VoxelGrid grid = voxelize(m.mesh, 10);
  const ResolvedFaceRegion u = resolve_face_regions(m, {spec_of(0, {3, 6})})[0];
  const RegionFrame frame = region_frame(m, u);
  CHECK(frame.cylindrical, "★ shared-axis cylinders get cylindrical coordinates");
  CHECK(near(std::fabs(frame.axis_dir.y), 1.0, 1e-9), "about the y axis");
  CHECK(near(frame.axial_hi - frame.axial_lo, 10.0, 1e-9),
        "the axial span is the part's 10 mm");

  const std::vector<int> vox = region_member_voxels(grid, m, u, 1);
  CHECK(vox.size() == 100, "the two faces hold 100 voxels together");
  const std::vector<GridSplitCell> cells = grid_split_cells(frame, 4, 2);
  CHECK(cells.size() == 8, "4 sectors x 2 axial slabs");
  const std::vector<std::size_t> counts =
      grid_split_voxel_counts(grid, vox, cells);
  std::size_t total = 0;
  for (std::size_t c : counts) total += c;
  CHECK(total == vox.size(),
        "★ the sector/slab cells PARTITION too — the wrap is exact, no voxel "
        "counted twice at a boundary plane and none dropped");

  // A radius signature is the "all six bolt bores in one tap" filter.
  RegionFilter sig;
  sig.cylinder_radius_mm = 5.0;
  sig.cylinder_radius_tol_mm = 0.05;
  CHECK(match_region_filter(m, sig) == (std::vector<int>{3, 6}),
        "the radius signature grabs both cylinders");

  // A mixed union (one cylinder, one plane) CANNOT share an axis and falls back
  // to PCA — the case §4b says the UI must say out loud.
  const ResolvedFaceRegion mixed =
      resolve_face_regions(m, {spec_of(0, {1, 3})})[0];
  CHECK(!region_frame(m, mixed).cylindrical,
        "★ a mixed union falls back to PCA — 'equal' is then not intrinsic");
}

// ★ §6 — WHAT A GRID SPLIT UNLOCKS, asserted rather than claimed: two sectors of
// ONE face, frozen to DIFFERENT depths, freezing different material and never
// the same voxel twice. That is hand-authored grading on the protection side,
// with the optimiser deciding nothing.
void sectors_carry_their_own_depth() {
  const StepModel m = banded_cube();
  const VoxelGrid grid = voxelize(m.mesh, 10);
  const ResolvedFaceRegion whole = resolve_face_regions(m, {spec_of(0, {3})})[0];
  const RegionFrame frame = region_frame(m, whole);
  const std::vector<GridSplitCell> cells = grid_split_cells(frame, 2, 1);
  CHECK(cells.size() == 2, "two sectors across the long axis");

  FaceRegionSpec a = spec_of(1, {3});
  a.cuts = cells[0].cuts;
  FaceRegionSpec b = spec_of(2, {3});
  b.cuts = cells[1].cuts;
  const std::vector<ResolvedFaceRegion> two = resolve_face_regions(m, {a, b});

  DesignMask shallow = make_active_mask(grid), deep = make_active_mask(grid);
  const std::size_t na =
      mask_step_region(grid, m, two[0], MaskValue::FrozenSolid, 1, shallow);
  const std::size_t nb =
      mask_step_region(grid, m, two[1], MaskValue::FrozenSolid, 3, deep);
  CHECK(na == 45, "sector A at depth 1 freezes its own half of the skin");
  CHECK(nb > na, "★ sector B at depth 3 freezes DEEPER — the depths are per sector");

  std::size_t overlap = 0;
  for (std::size_t i = 0; i < shallow.size(); ++i)
    if (shallow[i] == MaskValue::FrozenSolid && deep[i] == MaskValue::FrozenSolid)
      ++overlap;
  CHECK(overlap == 0,
        "★ and the two sectors never claim the same voxel — the cut is a plane "
        "through space, so it separates the deep layers too, not just the skin");
}

void snap_candidates() {
  const StepModel m = banded_cube();
  const ResolvedFaceRegion whole = resolve_face_regions(m, {spec_of(0, {3})})[0];
  const std::vector<Vec3> snaps = manual_split_snap_normals(region_frame(m, whole));
  CHECK(snaps.size() == 4, "the rotate button cycles four snap candidates");
  CHECK(near(std::fabs(snaps[0].y), 1.0, 1e-6),
        "the DEFAULT cuts across the long axis");
  CHECK(near(std::fabs(snaps[1].z), 1.0, 1e-6), "then along it");
  CHECK(near(std::fabs(snaps[2].y * snaps[2].z), 0.5, 1e-6), "then 45 degrees");
}

}  // namespace

int main() {
  measures();
  filters();
  resolution_and_refusals();
  identity_is_byte_for_byte();
  manual_split_partitions();
  grid_split_and_sliver();
  cylindrical_frame();
  sectors_carry_their_own_depth();
  snap_candidates();
  std::printf("test_face_region: %d checks, %d failures\n", g_checks,
              g_failures);
  return g_failures == 0 ? 0 : 1;
}
