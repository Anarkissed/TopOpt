// C1 ADDENDUM (maintainer, 2026-10-07): ANGLED PRESSES. A press may state a direction,
// and may span 2+ ADJACENT face regions (an edge or a corner) as ONE footprint: one
// frame, one stack. Frames, column counts, exit links and the side rule on a cube; the
// refusals; and conflicts / handover against a top press.

#include "topopt/flexible/faces.hpp"
#include "topopt/flexible/field.hpp"

#include <cmath>
#include <cstdio>
#include <functional>
#include <stdexcept>
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

static const double kPi = 3.14159265358979323846;
static const Vec3 kZ{0, 0, 1};

static bool veq(const Vec3& a, const Vec3& b, double tol = 1e-9) {
  return std::fabs(a.x - b.x) <= tol && std::fabs(a.y - b.y) <= tol && std::fabs(a.z - b.z) <= tol;
}
static Vec3 unit(Vec3 v) {
  const double n = std::sqrt(v.x * v.x + v.y * v.y + v.z * v.z);
  return {v.x / n, v.y / n, v.z / n};
}
static std::vector<char> all_solid(const VoxelGrid& g) {
  std::vector<char> m(g.voxel_count(), 0);
  for (std::size_t i = 0; i < g.tags.size(); ++i) m[i] = g.tags[i] != VoxelTag::Empty;
  return m;
}
static double share(const Stack& s, int region_id) {
  for (const StackLink& l : s.exit_regions)
    if (l.id == region_id) return l.area_fraction;
  return 0.0;
}
static bool refused(const std::function<void()>& f, std::vector<std::string> needles) {
  try {
    f();
  } catch (const FlexibleError& e) {
    for (const std::string& n : needles)
      if (std::string(e.what()).find(n) == std::string::npos) {
        std::fprintf(stderr, "  (message lacks \"%s\": %s)\n", n.c_str(), e.what());
        return false;
      }
    return true;
  } catch (...) {
    return false;
  }
  std::fprintf(stderr, "  (accepted)\n");
  return false;
}

// Face ids: 0 bottom, 1 top, 2 front -Y, 3 right +X, 4 back +Y, 5 left -X; region = 100 + id.
struct Cube {
  StepModel m = box(60, 60, 60);
  VoxelGrid g = voxelize(m.mesh, 60);  // 1 mm voxels
  std::vector<ResolvedFaceRegion> rs = resolve_face_regions(m, one_region_per_face());
  std::vector<char> lat = all_solid(g);
  Stack press(std::vector<int> ids, const Vec3* dir, double pitch = 1.0) const {
    std::vector<const ResolvedFaceRegion*> fp;
    for (int id : ids) fp.push_back(&region(rs, id));
    return build_press_stack(m, fp, rs, g, lat, 0, kZ, pitch, dir);
  }
};

static void test_edge_and_corner(const Cube& c) {
  // EDGE: top + right pressed together along (-1, 0, -1)/√2.
  const Vec3 de = unit({-1, 0, -1});
  const Stack e = c.press({101, 103}, &de);
  CHECK(veq(e.frame.load, de), "edge: the load is the stated direction");
  CHECK(std::fabs(e.frame.build_angle_deg - 45.0) < 1e-9 && e.frame.side,
        "edge at 45 degrees from Z: a side press (R6)");
  CHECK(e.footprint_region_ids == std::vector<int>({101, 103}) && e.press_direction_given,
        "the footprint names both regions; the direction is recorded");
  const double area = 60.0 * 60.0 * std::sqrt(2.0);  // two 60x60 faces seen at 45 degrees
  CHECK(std::fabs(e.columns.size() - area) <= 0.02 * area, "edge: columns cover 60 x 84.9 mm");
  CHECK(std::fabs(e.frame.u_extent_mm - 60.0 * std::sqrt(2.0)) < 1e-6 &&
            std::fabs(e.frame.v_extent_mm - 60.0) < 1e-6 && veq(e.frame.x_axis, unit({1, 0, -1})),
        "edge: X is the long (84.9 mm) direction across the edge, Y along it");
  CHECK(std::fabs(share(e, 100) - 0.5) < 0.03 && std::fabs(share(e, 105) - 0.5) < 0.03 &&
            e.exit_unresolved_fraction == 0.0,
        "edge: the other end is the bottom and the left face, half each");

  // CORNER: top + right + back along -(1, 1, 1)/√3.
  const Vec3 dc = unit({-1, -1, -1});
  const Stack k = c.press({101, 103, 104}, &dc);
  CHECK(veq(k.frame.load, dc) && std::fabs(k.frame.build_angle_deg - std::acos(1.0 / std::sqrt(3.0)) * 180.0 / kPi) < 1e-9 &&
            k.frame.side,
        "corner at 54.74 degrees: load stated, side press");
  const double hex = 3.0 * 3600.0 / std::sqrt(3.0);  // three faces at cos = 1/√3
  CHECK(std::fabs(k.columns.size() - hex) <= 0.02 * hex, "corner: columns cover the projected hexagon");
  CHECK(std::fabs(share(k, 100) - 1.0 / 3) < 0.03 && std::fabs(share(k, 105) - 1.0 / 3) < 0.03 &&
            std::fabs(share(k, 102) - 1.0 / 3) < 0.03,
        "corner: the other end is bottom, left and front, a third each");
  CHECK(k.frame.principal_axis_tied, "a regular hexagon has no longest direction: the tie rule");

  // Without a direction, an edge press pushes along the union's inward normal (equal
  // faces: the bisector).
  const Stack en = c.press({101, 103}, nullptr);
  CHECK(veq(en.frame.load, de, 1e-12) && !en.press_direction_given,
        "edge, no direction: the area-weighted inward normal of the union");
}

static void test_tilted_single_face(const Cube& c) {
  const double a = 20.0 * kPi / 180.0;
  const Vec3 d{-std::sin(a), 0, -std::cos(a)};
  const Stack t = c.press({101}, &d);
  CHECK(veq(t.frame.load, d) && std::fabs(t.frame.build_angle_deg - 20.0) < 1e-9 && t.frame.side,
        "a top face pressed 20 degrees off Z is a side press");
  const double area = 3600.0 * std::cos(a);
  CHECK(std::fabs(t.columns.size() - area) <= 0.02 * area, "tilted: columns cover the projected face");
  CHECK(std::fabs(share(t, 105) - std::tan(a)) < 0.03 && std::fabs(share(t, 100) - (1 - std::tan(a))) < 0.03,
        "tilted: tan(20) of the columns leave through the left face, the rest the bottom");
  // No direction: exactly today's stack.
  const Stack p = c.press({101}, nullptr);
  const Stack b = build_stack(c.m, region(c.rs, 101), c.rs, c.g, c.lat, 0, kZ, 1.0);
  bool same = p.columns.size() == b.columns.size() && veq(p.frame.load, b.frame.load, 0) &&
              veq(p.frame.x_axis, b.frame.x_axis, 0) && p.frame.u_extent_mm == b.frame.u_extent_mm;
  for (std::size_t i = 0; same && i < p.columns.size(); ++i)
    same = p.columns[i].u_mm == b.columns[i].u_mm && p.columns[i].entry_t == b.columns[i].entry_t &&
           p.columns[i].exit_t == b.columns[i].exit_t && p.columns[i].lattice_mm == b.columns[i].lattice_mm;
  CHECK(same && !p.press_direction_given, "no direction, one region: identical to build_stack");
}

static void test_refusals(const Cube& c) {
  const Vec3 up{0, 0, 1}, edge_on{1, 0, 0};
  CHECK(refused([&] { c.press({101}, &up); }, {"101", "into the part"}),
        "an outward direction is refused, naming the region");
  CHECK(refused([&] { c.press({101}, &edge_on); }, {"101", "into the part"}),
        "an edge-on direction is refused");
  const Vec3 de = unit({-1, 0, -1});
  CHECK(refused([&] { c.press({101, 103}, &edge_on); }, {"101"}),
        "an edge press whose direction runs along the top face is refused, naming the top");
  CHECK(refused([&] { c.press({101, 100}, nullptr); }, {"101", "100", "adjacent"}),
        "a non-adjacent pair (top + bottom) is refused, naming both");
  // a multi-region footprint containing a cut sector: not supported yet
  std::vector<FaceRegionSpec> sp = one_region_per_face();
  FaceRegionSpec half;
  half.id = 200;
  half.add = {1};
  half.cuts = {RegionCut{{30, 0, 0}, {1, 0, 0}, false}};
  sp.push_back(half);
  const std::vector<ResolvedFaceRegion> rs2 = resolve_face_regions(c.m, sp);
  CHECK(refused([&] {
          build_press_stack(c.m, {&region(rs2, 200), &region(rs2, 103)}, rs2, c.g, c.lat, 0, kZ, 1.0, &de);
        }, {"200", "sector"}),
        "a multi-region press with a cut sector is refused (not yet supported)");
  // a cut sector pressed ALONE at an angle still works
  const Vec3 d{-std::sin(0.2), 0, -std::cos(0.2)};
  const Stack h = build_press_stack(c.m, {&region(rs2, 200)}, rs2, c.g, c.lat, 0, kZ, 1.0, &d);
  CHECK(veq(h.frame.load, unit(d)) && h.columns.size() > 0, "a single angled sector is pressed");
}

static void test_conflicts() {
  const StepModel m = box(60, 60, 60);
  const VoxelGrid g = voxelize(m.mesh, 30);  // 2 mm
  const std::vector<ResolvedFaceRegion> rs = resolve_face_regions(m, one_region_per_face());
  const std::vector<char> lat = all_solid(g);
  const Stack top = build_press_stack(m, {&region(rs, 101)}, rs, g, lat, 0, kZ, 2.0, nullptr);
  // A vertical EDGE press (right + back) crossing the top press: 90 degrees apart, so a
  // handover, found and blended.
  const Vec3 dv = unit({-1, -1, 0});
  const Stack edge = build_press_stack(m, {&region(rs, 103), &region(rs, 104)}, rs, g, lat, 0, kZ, 2.0, &dv);
  CHECK(find_stack_conflicts(g, lat, {&top, &edge}).empty(), "top + vertical edge: not the same axis");
  const FlexibleData d = load_flexible_data(FLEXIBLE_MATERIALS_JSON_PATH);
  const CurveSet s = curve_set(d, "varioshore_tpu", 220, "gyroid").set;
  const BuildParams bp{"gyroid", 1, 0.42};
  SquishMap mp;
  mp.mode = "both";
  mp.x_x = mp.y_x = {0, 1};
  mp.x_y = mp.y_y = {1, 1};
  mp.deepest_squish_mm = 6;
  const FaceDesign dt = design_face(s, top, mp, 30 * 9.81, nullptr, bp,
                                    tier_band(d.catalogue.error_bands, s.tier, false, 1));
  mp.deepest_squish_mm = 10;
  const FaceDesign de = design_face(s, edge, mp, 40 * 9.81, nullptr, bp,
                                    tier_band(d.catalogue.error_bands, s.tier, true, 1));
  CHECK(dt.ok > 0 && de.ok > 0, "both presses design");
  const DensityField f = assemble_density_field(g, lat, {{&top, &dt}, {&edge, &de}}, bp);
  bool pair = f.handovers.size() == 1 && f.handovers[0].face_a == 101 && f.handovers[0].face_b == 103 &&
              f.handovers[0].overlap_mm3 > 0 && f.handovers[0].blended_mm3 > 0 &&
              f.handovers[0].blended_mm3 < f.handovers[0].overlap_mm3;
  CHECK(pair, "the edge press and the top press overlap: one handover pair, blended");
  // An edge press only 11 degrees off Z over the top stack: the SAME axis (15 degrees),
  // so one profile per stack refuses it.
  const Vec3 dn = unit({-0.2, 0, -1});
  const Stack steep = build_press_stack(m, {&region(rs, 101), &region(rs, 103)}, rs, g, lat, 0, kZ, 2.0, &dn);
  const Stack bottom = build_press_stack(m, {&region(rs, 100)}, rs, g, lat, 0, kZ, 2.0, nullptr);
  const std::vector<StackConflict> cf = find_stack_conflicts(g, lat, {&steep, &bottom});
  CHECK(cf.size() == 1 && cf[0].axis_angle_deg < 15.0, "an angled press within 15 degrees of a loaded bottom: refused");
}

int main() {
  const Cube c;
  test_edge_and_corner(c);
  test_tilted_single_face(c);
  test_refusals(c);
  test_conflicts();
  std::printf("test_flexible_press: %d checks, %d failures\n", g_checks, g_failures);
  return g_failures == 0 ? 0 : 1;
}
