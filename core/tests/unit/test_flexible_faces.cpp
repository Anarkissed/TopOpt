// F5 of task 2026-09-28-flexible-squish-maths: face frames (R13) and stacks (M13):
// load direction, principal axis, rotation, extents, the normal-spread and side
// flags, the sweep to the linked other end, and a split (cut) face.

#include "topopt/flexible/faces.hpp"
#include "topopt/flexible/error.hpp"

#include <cmath>
#include <cstdio>
#include <string>
#include <vector>

#include "flexible_test_boxes.hpp"

using namespace topopt;
using namespace topopt::flexible;
using flexible_test::box;
using flexible_test::one_region_per_face;
using flexible_test::region;

static int g_failures = 0;
static int g_checks = 0;

#define CHECK(cond, msg)                                            \
  do {                                                              \
    ++g_checks;                                                     \
    if (!(cond)) {                                                  \
      ++g_failures;                                                 \
      std::fprintf(stderr, "FAIL (line %d): %s\n", __LINE__, msg);  \
    }                                                               \
  } while (0)

static bool veq(const Vec3& a, const Vec3& b, double tol = 1e-12) {
  return std::fabs(a.x - b.x) <= tol && std::fabs(a.y - b.y) <= tol &&
         std::fabs(a.z - b.z) <= tol;
}

static std::vector<int> tris_of(const StepModel& m, int face) {
  std::vector<int> out;
  for (std::size_t t = 0; t < m.triangle_face.size(); ++t)
    if (m.triangle_face[t] == face) out.push_back(static_cast<int>(t));
  return out;
}

static const Vec3 kBuildZ{0, 0, 1};

static void test_top_frame() {
  const StepModel m = box(100, 60, 20);
  FaceFrame f = face_frame(m.mesh, tris_of(m, 1), 0, kBuildZ);
  CHECK(f.valid, "top face frame valid");
  CHECK(veq(f.load, {0, 0, -1}), "top face: load points INTO the part (-Z)");
  CHECK(veq(f.x_axis, {1, 0, 0}), "X = the face's long (100 mm) direction, signed +X");
  CHECK(veq(f.y_axis, {0, -1, 0}), "Y = load × X");
  CHECK(std::fabs(f.u_extent_mm - 100) < 1e-9 && std::fabs(f.v_extent_mm - 60) < 1e-9,
        "extents 100 x 60");
  CHECK(std::fabs(f.area_mm2 - 6000) < 1e-9 && std::fabs(f.projected_area_mm2 - 6000) < 1e-9,
        "area 6000 mm²");
  CHECK(f.normal_spread_deg < 1e-9 && !f.normal_spread_flag, "a flat face has no spread");
  CHECK(!f.side && f.build_angle_deg < 1e-9, "a top face is not a side stack");
  CHECK(!f.principal_axis_tied, "a 100x60 face has a longest direction");
  // (u, v) round trip and corner convention
  double u = 0, v = 0;
  f.to_uv({0, 60, 20}, u, v);
  CHECK(std::fabs(u) < 1e-9 && std::fabs(v) < 1e-9, "(0,60) is the (u,v) origin corner");
  f.to_uv({100, 0, 20}, u, v);
  CHECK(std::fabs(u - 100) < 1e-9 && std::fabs(v - 60) < 1e-9, "(100,0) is the far corner");
  const Vec3 p = f.from_uv(25, 10);
  f.to_uv(p, u, v);
  CHECK(std::fabs(u - 25) < 1e-9 && std::fabs(v - 10) < 1e-9, "from_uv/to_uv round trip");

  // Rotation in 90° steps about the load.
  FaceFrame r = face_frame(m.mesh, tris_of(m, 1), 90, kBuildZ);
  CHECK(veq(r.x_axis, {0, -1, 0}) && veq(r.y_axis, {-1, 0, 0}), "rotate 90: X' = Y, Y' = -X");
  CHECK(std::fabs(r.u_extent_mm - 60) < 1e-9 && std::fabs(r.v_extent_mm - 100) < 1e-9,
        "rotate 90 swaps the extents");
  FaceFrame r180 = face_frame(m.mesh, tris_of(m, 1), 180, kBuildZ);
  CHECK(veq(r180.x_axis, {-1, 0, 0}) && veq(r180.y_axis, {0, 1, 0}), "rotate 180 flips both");
  FaceFrame r270 = face_frame(m.mesh, tris_of(m, 1), 270, kBuildZ);
  CHECK(veq(r270.x_axis, {0, 1, 0}) && veq(r270.y_axis, {1, 0, 0}), "rotate 270");
  bool threw = false;
  try {
    face_frame(m.mesh, tris_of(m, 1), 45, kBuildZ);
  } catch (const FlexibleError&) {
    threw = true;
  }
  CHECK(threw, "a 45° rotation is refused (90° steps only)");

  // A square face has no longest direction: the +X rule decides, and says so.
  const StepModel sq = box(100, 100, 20);
  FaceFrame s = face_frame(sq.mesh, tris_of(sq, 1), 0, kBuildZ);
  CHECK(s.principal_axis_tied && veq(s.x_axis, {1, 0, 0}), "square top: X = model +X, tied");
  // Bottom face: load +Z, X still the long axis.
  FaceFrame b = face_frame(m.mesh, tris_of(m, 0), 0, kBuildZ);
  CHECK(veq(b.load, {0, 0, 1}) && veq(b.x_axis, {1, 0, 0}) && veq(b.y_axis, {0, 1, 0}),
        "bottom face: load +Z, X +X, Y = load × X = +Y");
}

static void test_side_and_spread() {
  const StepModel m = box(100, 60, 20);
  FaceFrame f = face_frame(m.mesh, tris_of(m, 3), 0, kBuildZ);  // +X face
  CHECK(veq(f.load, {-1, 0, 0}), "+X face pushes along -X");
  CHECK(f.side && std::fabs(f.build_angle_deg - 90) < 1e-9, "a side face is a side stack");
  CHECK(veq(f.x_axis, {0, 1, 0}), "its long direction (60 mm, Y) is X");
  // Build direction matters: with build X, the +X face is NOT a side stack.
  FaceFrame fx = face_frame(m.mesh, tris_of(m, 3), 0, {1, 0, 0});
  CHECK(!fx.side, "the side flag follows the build direction");

  // A folded face: two triangles 40° apart -> flagged. 10° apart -> not.
  for (double deg : {40.0, 10.0}) {
    TriangleMesh t;
    const double a = deg * 3.14159265358979323846 / 180.0;
    t.vertices = {{0, 0, 0}, {10, 0, 0}, {10, 10, 0}, {0, 10, 0},
                  {-10 * std::cos(a), 10, 10 * std::sin(a)}, {-10 * std::cos(a), 0, 10 * std::sin(a)}};
    t.triangles = {{0, 1, 2}, {0, 2, 3}, {0, 3, 4}, {0, 4, 5}};
    FaceFrame ff = face_frame(t, {0, 1, 2, 3}, 0, kBuildZ);
    CHECK(ff.valid, "folded face frame valid");
    if (deg == 40.0)
      CHECK(ff.normal_spread_flag && ff.normal_spread_deg > 15.0, "40° fold flagged");
    else
      CHECK(!ff.normal_spread_flag && ff.normal_spread_deg < 30.0, "10° fold not flagged");
  }
  FaceFrame none = face_frame(m.mesh, {}, 0, kBuildZ);
  CHECK(!none.valid && !none.reason.empty(), "an empty face is invalid, with a reason");
}

static std::vector<char> all_solid(const VoxelGrid& g) {
  std::vector<char> mask(g.voxel_count(), 0);
  for (std::size_t i = 0; i < g.tags.size(); ++i) mask[i] = g.tags[i] != VoxelTag::Empty;
  return mask;
}

static void test_stack() {
  StepModel m = box(100, 60, 20);
  const VoxelGrid g = voxelize(m.mesh, 100);  // spacing 1 mm
  const std::vector<ResolvedFaceRegion> rs = resolve_face_regions(m, one_region_per_face());
  const std::vector<char> lat = all_solid(g);
  const Stack s = build_stack(m, region(rs, 101), rs, g, lat, 0, kBuildZ, 1.0);
  CHECK(s.nu == 100 && s.nv == 60, "a 100 x 60 grid of 1 mm columns");
  CHECK(s.columns.size() == 6000, "every cell of the top face is a column");
  CHECK(std::fabs(s.footprint_area_mm2 - 6000) < 1e-6, "footprint 6000 mm²");
  bool heights = true;
  for (const StackColumn& c : s.columns)
    if (std::fabs(c.exit_t - c.entry_t - 20) > 1e-9 || std::fabs(c.lattice_mm - 20) > 0.51)
      heights = false;
  CHECK(heights, "every column runs 20 mm, all of it latticed");
  CHECK(std::fabs(s.stack_mm_max - 20) < 1e-9, "stack height 20 mm");
  CHECK(s.exit_faces.size() == 1 && s.exit_faces[0].id == 0 &&
            std::fabs(s.exit_faces[0].area_fraction - 1.0) < 1e-12,
        "the linked other end is the bottom face, 100 % of the area");
  CHECK(s.exit_regions.size() == 1 && s.exit_regions[0].id == 100,
        "... reported as region 100");
  CHECK(s.exit_unresolved_fraction == 0.0, "no column lost its exit");

  // A lattice region only 10 mm deep below the top: columns carry 10 mm of lattice.
  std::vector<char> half = lat;
  for (int k = 0; k < g.nz; ++k)
    for (int j = 0; j < g.ny; ++j)
      for (int i = 0; i < g.nx; ++i)
        if (g.voxel_center(i, j, k).z < 10.0) half[g.index(i, j, k)] = 0;
  const Stack h = build_stack(m, region(rs, 101), rs, g, half, 0, kBuildZ, 1.0);
  CHECK(std::fabs(h.lattice_mm_mean - 10) < 0.51 && std::fabs(h.stack_mm_max - 20) < 1e-9,
        "latticed length follows the lattice region, the stack runs through the part");

  // A side face: the stack runs across the part to the opposite side face.
  const Stack sd = build_stack(m, region(rs, 103), rs, g, lat, 0, kBuildZ, 1.0);
  CHECK(sd.frame.side, "the +X stack is a side stack");
  CHECK(sd.exit_faces.size() == 1 && sd.exit_faces[0].id == 5, "+X links to -X");
  CHECK(std::fabs(sd.stack_mm_max - 100) < 1e-9, "a 100 mm side stack");
  CHECK(sd.columns.size() == 60 * 20, "60 x 20 columns on the side");

  // A split sector: the top face cut at x >= 50 keeps the right half, and its
  // frame describes that half (50 x 60, so X is now the 60 mm direction).
  std::vector<FaceRegionSpec> specs = one_region_per_face();
  FaceRegionSpec cut;
  cut.id = 200;
  cut.add = {1};
  RegionCut c;
  c.point = {50, 0, 0};
  c.normal = {1, 0, 0};
  cut.cuts = {c};
  specs.push_back(cut);
  const std::vector<ResolvedFaceRegion> rs2 = resolve_face_regions(m, specs);
  const Stack hs = build_stack(m, region(rs2, 200), rs2, g, lat, 0, kBuildZ, 1.0);
  CHECK(hs.columns.size() == 3000, "the sector keeps half the columns");
  CHECK(std::fabs(hs.frame.u_extent_mm - 60) < 1.01 && std::fabs(hs.frame.v_extent_mm - 50) < 1.01,
        "the sector's frame is 60 x 50, from its own columns");
  bool right = true;
  for (const StackColumn& col : hs.columns) {
    const Vec3 p = hs.frame.from_uv(col.u_mm, col.v_mm);
    if (p.x < 50) right = false;
  }
  CHECK(right, "every sector column lies at x >= 50");

  bool threw = false;
  try {
    build_stack(m, region(rs, 101), rs, g, lat, 0, kBuildZ, 0.0);
  } catch (const FlexibleError&) {
    threw = true;
  }
  CHECK(threw, "pitch 0 refused");
  CHECK(std::fabs(axis_angle_deg({0, 0, 1}, {0, 0, -1})) < 1e-12 &&
            std::fabs(axis_angle_deg({0, 0, 1}, {1, 0, 0}) - 90) < 1e-12,
        "axis angle ignores the sign");
}

int main() {
  test_top_frame();
  test_side_and_spread();
  test_stack();
  std::printf("test_flexible_faces: %d checks, %d failures\n", g_checks, g_failures);
  return g_failures == 0 ? 0 : 1;
}
