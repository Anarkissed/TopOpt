// C2 batch B1a (reviewer's ruling 2026-10-24 08:45): items 7, 25, 27, the 9(b) mask, the
// 8(a) run per Q2, 24, and the edited-pieces points 1 and 2. Red first.
//
//  7     "no include region = no lattice": a block flag; the run refuses with a code.
//  25    a face's column grid runs EDGE TO EDGE: a cell the face only partly covers is a
//        column with its exact area, so the areas sum to the face.
//  27    a press that fails to stack is a CODED refusal (press_stack_failed), not a throw.
//  9(b)  the Flexible lattice mask reaches the part's surface: an Empty voxel (its centre
//        just outside the part) with a lattice 6-neighbour joins it, unless it touches,
//        face to face, a solid voxel that is not lattice (the inside-corner exception).
//        This is the app's rule (FlexibleLatticeField.swift:836-852).
//  8(a)  a column's lattice is the RUN unbroken from its entry, as the app's bridge measures
//        it (flexible_bridge.cpp:686-734): a leading off-lattice stretch of at most two
//        voxels is travel; a hole of at most one voxel's diagonal is crossed; anything longer
//        ends it. A face's run is on its OWN include regions; a press's is on the job's mask.
//  24    a press is only the columns that enter its lattice: its weight, and the map its
//        curves span, are over those columns.
//  P1    two pieces of ONE face in one press are pressed together (they used to be refused).
//  P2    a press's pieces are adjacent when their CLIPPED footprints share an edge, not
//        when their CAD faces do.

#include "topopt/flexible/faces.hpp"
#include "topopt/flexible/field.hpp"
#include "topopt/flexible/job_block.hpp"
#include "topopt/flexible/run.hpp"
#include "topopt/face_overrides.hpp"
#include "topopt/job.hpp"
#include "topopt/voxel.hpp"

#include <cmath>
#include <cstdio>
#include <filesystem>
#include <fstream>
#include <functional>
#include <sstream>
#include <string>
#include <vector>

#include "flexible_test_boxes.hpp"

using namespace topopt;
using namespace topopt::flexible;
using flexible_test::box;
using flexible_test::one_region_per_face;
using flexible_test::region;
namespace fs = std::filesystem;

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

// RE-PINNED (C2 B1b): the current version is pinned in test_flexible_b1b; B1a's meaning holds
// from 3 on.
static_assert(kPressApiVersion >= 3, "B1a: the press API version");

static const Vec3 kZ{0, 0, 1};

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

// A mask on `g`: 1 where pred(voxel centre) holds and the voxel is solid.
static std::vector<char> mask_where(const VoxelGrid& g, const std::function<bool(const Vec3&)>& pred) {
  std::vector<char> m(g.voxel_count(), 0);
  for (int k = 0; k < g.nz; ++k)
    for (int j = 0; j < g.ny; ++j)
      for (int i = 0; i < g.nx; ++i)
        if (g.solid(i, j, k) && pred(g.voxel_center(i, j, k))) m[g.index(i, j, k)] = 1;
  return m;
}

// ── 8(a): the run, its two tolerances ───────────────────────────────────────────
static void test_run() {
  const StepModel m = box(40, 40, 30);
  const VoxelGrid g = voxelize(m.mesh, 40, VoxelTies::Watertight);  // 1 mm voxels
  const std::vector<ResolvedFaceRegion> rs = resolve_face_regions(m, one_region_per_face());
  auto top_run = [&](const std::vector<char>& mask) {
    const Stack s = build_stack(m, region(rs, 101), rs, g, mask, 0, kZ, 1.0);
    double lo = 1e300, hi = -1e300;
    for (const StackColumn& c : s.columns) {
      lo = std::min(lo, c.lattice_mm);
      hi = std::max(hi, c.lattice_mm);
    }
    return std::make_pair(lo, hi);
  };
  // Two prisms on one column, solid between: the run is the top prism's alone.
  {
    const auto r = top_run(mask_where(g, [](const Vec3& p) { return p.z > 22 || p.z < 10; }));
    std::printf("  run, two prisms with solid between: %.3f..%.3f mm (the whole-column count would be 18)\n", r.first,
                r.second);
    CHECK(std::fabs(r.first - 8) < 0.26 && std::fabs(r.second - 8) < 0.26,
          "8(a): a column's lattice is the run from its entry: the top prism's 8 mm, not 8 + 10");
  }
  // (i) a leading off-lattice stretch of up to two voxels is travel; three is not.
  {
    const auto r = top_run(mask_where(g, [](const Vec3& p) { return p.z < 28.5; }));  // 1.5 mm below the top
    CHECK(r.first > 29.5, "8(a)(i): a 1.5 mm leading gap is travel: the run is the whole column");
    const auto r3 = top_run(mask_where(g, [](const Vec3& p) { return p.z < 27; }));   // 3 mm below
    CHECK(r3.second == 0.0, "8(a)(i): a 3 mm leading gap (more than two voxels): no run");
  }
  // (ii) a hole of at most one voxel's diagonal is crossed; a 3 mm hole ends the run.
  {
    const auto r1 = top_run(mask_where(g, [](const Vec3& p) { return !(p.z > 20 && p.z < 21); }));
    CHECK(r1.first > 29.5, "8(a)(ii): a one-voxel hole inside the lattice is crossed");
    const auto r3 = top_run(mask_where(g, [](const Vec3& p) { return !(p.z > 18 && p.z < 21); }));
    CHECK(std::fabs(r3.first - 9) < 0.26, "8(a)(ii): a 3 mm hole ends the run (9 mm, from the top to z = 21)");
  }
}

// ── 9(b): the surface fill ───────────────────────────────────────────────────────
static void test_surface_fill() {
  // His pad at Balanced: 100 x 100 x 20 mm at res 96 is 19.2 voxels tall, so the top layer's
  // centres (z = 20.31) lie outside the part and core leaves it Empty.
  const StepModel pad = import_part_file_resolved(std::string(FLEXIBLE_FIXTURE_DIR) + "/his_pad_1021/model.stl");
  const VoxelGrid g = voxelize(pad.mesh, 96, VoxelTies::Watertight);
  std::vector<char> mask = mask_where(g, [](const Vec3&) { return true; });
  long long top_empty = 0;
  for (int j = 0; j < g.ny; ++j)
    for (int i = 0; i < g.nx; ++i) top_empty += !g.solid(i, j, g.nz - 1);
  const SurfaceFill f = flexible_fill_surface(g, mask);
  std::printf("  surface fill on his pad at res 96: %lld added (the top layer: %lld Empty), %lld refused\n", f.added,
              top_empty, f.refused_at_inside_corner);
  CHECK(top_empty == 96LL * 96 && f.added == top_empty, "9(b): his pad's empty top layer joins the lattice (9,216)");
  CHECK(f.refused_at_inside_corner == 0, "9(b): a whole-part lattice has no inside corner to refuse");

  // The inside-corner exception, on a hand-built grid (1 mm voxels, 40 x 4 x 30): a base slab
  // z < 10 latticed for x < 30, a SOLID wall (not lattice) x >= 30 up to z = 30, and the base's
  // partial top layer (k = 10) Empty. The fill voxel at i = 29 touches the wall's voxel at
  // i = 30 face to face, so it is not added; the rest of the layer is.
  VoxelGrid g2;
  g2.nx = 40;
  g2.ny = 4;
  g2.nz = 30;
  g2.spacing = 1.0;
  g2.origin = {0, 0, 0};
  g2.tags.assign(static_cast<std::size_t>(g2.nx) * g2.ny * g2.nz, VoxelTag::Empty);  // voxel_count() IS tags.size()
  for (int k = 0; k < g2.nz; ++k)
    for (int j = 0; j < g2.ny; ++j)
      for (int i = 0; i < g2.nx; ++i)
        if ((i < 30 && k < 10) || i >= 30) g2.tags[g2.index(i, j, k)] = VoxelTag::Interior;
  std::vector<char> m2(g2.voxel_count(), 0);
  for (int k = 0; k < 10; ++k)
    for (int j = 0; j < g2.ny; ++j)
      for (int i = 0; i < 30; ++i) m2[g2.index(i, j, k)] = 1;
  const std::vector<char> before = m2;
  const SurfaceFill f2 = flexible_fill_surface(g2, m2);
  bool touches_solid = false;
  for (std::size_t v = 0; v < m2.size(); ++v) {
    if (!m2[v] || before[v]) continue;
    const int i = static_cast<int>(v % g2.nx), j = static_cast<int>((v / g2.nx) % g2.ny),
              k = static_cast<int>(v / (static_cast<std::size_t>(g2.nx) * g2.ny));
    const int d[6][3] = {{1, 0, 0}, {-1, 0, 0}, {0, 1, 0}, {0, -1, 0}, {0, 0, 1}, {0, 0, -1}};
    for (const auto& o : d) {
      const int a = i + o[0], b = j + o[1], c = k + o[2];
      if (a < 0 || b < 0 || c < 0 || a >= g2.nx || b >= g2.ny || c >= g2.nz) continue;
      if (g2.solid(a, b, c) && !before[g2.index(a, b, c)]) touches_solid = true;
    }
  }
  std::printf("  inside corner: %lld added, %lld refused\n", f2.added, f2.refused_at_inside_corner);
  CHECK(f2.added == 29 * 4 && f2.refused_at_inside_corner == 4 && !touches_solid,
        "9(b): no fill voxel touches, face to face, a solid voxel that is not lattice (the inside-corner exception)");
}

// ── 25: the column grid runs edge to edge ────────────────────────────────────────
static void test_edge_to_edge() {
  const StepModel pad = import_part_file_resolved(std::string(FLEXIBLE_FIXTURE_DIR) + "/his_pad_1021/model.stl");
  const VoxelGrid g = voxelize(pad.mesh, 96, VoxelTies::Watertight);  // 1.0417 mm
  // the 100 x 20 side face whose normal is -X
  int side = -1;
  for (int f = 0; f < pad.face_count; ++f)
    if (pad.faces[static_cast<std::size_t>(f)].plane_normal.x < -0.99) side = f;
  std::vector<FaceRegionSpec> sp;
  FaceRegionSpec s;
  s.id = 7;
  s.add = {side};
  sp.push_back(s);
  const std::vector<ResolvedFaceRegion> rs = resolve_face_regions(pad, sp);
  const std::vector<char> mask = mask_where(g, [](const Vec3&) { return true; });
  const Stack st = build_stack(pad, region(rs, 7), rs, g, mask, 0, kZ, g.spacing);
  double area = 0.0;
  int far = 0;
  for (const StackColumn& c : st.columns) {
    area += c.area_mm2;
    if (c.iv == st.nv - 1 || c.iu == st.nu - 1) ++far;
  }
  std::printf("  edge to edge: face %d, %zu columns on a %d x %d grid, area %.6f mm2 (the face: 2000), %d in the far rows\n",
              side, st.columns.size(), st.nu, st.nv, area, far);
  CHECK(side >= 0 && std::fabs(area - 2000.0) < 1e-6, "25: the columns' areas sum to the face (2000 mm2)");
  CHECK(std::fabs(st.footprint_area_mm2 - 2000.0) < 1e-6, "25: footprint_mm2 is the face's area");
  CHECK(far > 0, "25: the far row (centre past the face's edge) is kept as a partial column");
}

// ── P1 + P2: edited pieces in a press ─────────────────────────────────────────────
static void test_pieces() {
  const StepModel m = box(60, 60, 20);
  const VoxelGrid g = voxelize(m.mesh, 60, VoxelTies::Watertight);
  std::vector<FaceRegionSpec> sp = one_region_per_face();
  auto sector = [&](int id, int face, std::vector<RegionCut> cuts) {
    FaceRegionSpec r;
    r.id = id;
    r.add = {face};
    r.cuts = cuts;
    sp.push_back(r);
  };
  sector(201, 1, {RegionCut{{30, 0, 0}, {-1, 0, 0}, true}});   // top x < 30
  sector(202, 1, {RegionCut{{30, 0, 0}, {1, 0, 0}, false}});   // top x >= 30
  sector(203, 1, {RegionCut{{40, 0, 0}, {-1, 0, 0}, true}});   // top x < 40 (overlaps 202)
  sector(204, 1, {RegionCut{{20, 0, 0}, {-1, 0, 0}, true}});   // top x < 20 (does not reach +X)
  const std::vector<ResolvedFaceRegion> rs = resolve_face_regions(m, sp);
  const std::vector<char> lat = mask_where(g, [](const Vec3&) { return true; });
  const Vec3 down{0, 0, -1};
  // P1: the two halves of the top, one press: the whole top's columns.
  Stack both;
  bool ok = true;
  try {
    both = build_press_stack(m, {&region(rs, 201), &region(rs, 202)}, rs, g, lat, 0, kZ, 1.0, &down);
  } catch (const std::exception& e) {
    ok = false;
    std::fprintf(stderr, "  (%s)\n", e.what());
  }
  CHECK(ok && both.columns.size() == 3600, "P1: two halves of one face in one press: the whole top (3,600 columns)");
  CHECK(refused([&] { build_press_stack(m, {&region(rs, 203), &region(rs, 202)}, rs, g, lat, 0, kZ, 1.0, &down); },
                {"203", "202", "overlap"}),
        "P1: two pieces of one face that overlap inside one press are refused, naming both");
  // P2: a top piece that does not reach the +X face is not adjacent to it.
  const Vec3 edge{-1, 0, -1};
  CHECK(refused([&] { build_press_stack(m, {&region(rs, 204), &region(rs, 103)}, rs, g, lat, 0, kZ, 1.0, &edge); },
                {"204", "103", "adjacent"}),
        "P2: a piece whose clipped footprint does not touch the other's is not adjacent (their faces are)");
  ok = true;
  try {
    build_press_stack(m, {&region(rs, 202), &region(rs, 103)}, rs, g, lat, 0, kZ, 1.0, &edge);
  } catch (const std::exception& e) {
    ok = false;
    std::fprintf(stderr, "  (%s)\n", e.what());
  }
  CHECK(ok, "P2: a top piece that reaches the +X edge is adjacent to the +X face");
}

// ── the run: 7, 27, 24 ───────────────────────────────────────────────────────────
static std::string read(const std::string& p) {
  std::ifstream in(p, std::ios::binary);
  std::ostringstream s;
  s << in.rdbuf();
  return s.str();
}

static const std::string kOut = std::string(FLEXIBLE_TMP_DIR) + "/flexible_b1a_test";

static FlexibleRunResult run_on(const std::string& name, const std::string& job_dir, const std::string& text) {
  const JobDescription j = parse_job(text);
  return run_flexible_job(j, job_dir, kOut + "/" + name, FLEXIBLE_MATERIALS_JSON_PATH,
                          FlexibleProvenance{"test", "test", "now"});
}

// A job on his pad's STL: one face region per pseudo-face (ids 100 + face), `faces` the
// flexible faces array, `extra` more flexible-block keys, `regions` the flexible regions.
static std::string pad_job(int res, const std::string& faces, const std::string& extra = "",
                           const std::string& regions = "", const std::string& more_face_regions = "") {
  std::string fr;
  for (int f = 0; f < 6; ++f)
    fr += (f ? "," : "") + std::string("{\"id\":") + std::to_string(100 + f) + ",\"add\":[" + std::to_string(f) + "]}";
  fr += more_face_regions;
  return "{\"model\":\"model.stl\",\"material\":\"varioshore_tpu\",\"mode\":\"analyze\",\"resolution\":" +
         std::to_string(res) +
         ",\"output\":{\"report\":\"r.json\",\"mesh_format\":\"stl\",\"mesh_prefix\":\"v\"},"
         "\"loads\":{\"face_regions\":[" + fr + "]},"
         "\"flexible\":{\"material_id\":\"varioshore_tpu\",\"nozzle_temp_c\":220,\"topology\":\"gyroid\","
         "\"feel\":\"springy\",\"beads_per_wall\":1,\"min_extrudable_width_mm\":0.42" +
         (regions.empty() ? "" : ",\"regions\":[" + regions + "]") + extra + ",\"faces\":" + faces + "}}";
}

static std::string loaded(int region, const std::string& more = "") {
  return "{\"face_region_id\":" + std::to_string(region) + more +
         ",\"role\":\"loaded\",\"weight_n\":100,\"deepest_squish_mm\":2,\"mode\":\"both\","
         "\"curve_x\":[[0,1],[1,1]],\"curve_y\":[[0,1],[1,1]],\"skin_on\":true}";
}

static void test_run_items() {
  std::error_code ec;
  fs::remove_all(kOut, ec);
  const std::string pad_dir = std::string(FLEXIBLE_FIXTURE_DIR) + "/his_pad_1021";
  const StepModel pad = import_part_file_resolved(pad_dir + "/model.stl");
  int top = -1;
  for (int f = 0; f < pad.face_count; ++f)
    if (pad.faces[static_cast<std::size_t>(f)].plane_normal.z > 0.99) top = f;
  const int top_region = 100 + top;

  // 7: his pad's Top at res 64 with no include region: 4,096 latticed columns (his number,
  // the positive control); with "no_lattice", a coded refusal and nothing latticed.
  {
    const FlexibleRunResult r = run_on("whole", pad_dir, pad_job(64, "[" + loaded(top_region) + "]"));
    const int lat = r.stacks.empty() ? -1 : r.stacks[0].latticed_columns;
    std::printf("  7: no include region, default: %d latticed columns\n", lat);
    CHECK(!r.refused && lat == 4096, "7: the default (whole part) keeps today's answer: 4,096 latticed columns");
    const FlexibleRunResult n =
        run_on("none", pad_dir, pad_job(64, "[" + loaded(top_region) + "]", ",\"no_include_region\":\"no_lattice\""));
    CHECK(n.refused && n.refusal_code == "no_lattice_region", "7: \"no_lattice\" with no include region: refused, coded");
    CHECK(fs::exists(kOut + "/none/run_info.json") && n.receipt_json.find("no_lattice_region") != std::string::npos,
          "7: the refusal writes the receipt");
    bool threw = false;
    try {
      parse_job(pad_job(64, "[" + loaded(top_region) + "]", ",\"no_include_region\":\"nothing\""));
    } catch (const JobError& e) {
      threw = std::string(e.what()).find("no_include_region") != std::string::npos;
    }
    CHECK(threw, "7: any other value is refused, naming the key");
  }

  // 27: a press that cannot stack (its direction points out of the part) is a CODED refusal.
  {
    FlexibleRunResult r;
    bool threw = false;
    try {
      r = run_on("outward", pad_dir, pad_job(64, "[" + loaded(top_region, ",\"press_direction\":[0,0,1]") + "]"));
    } catch (const std::exception& e) {
      threw = true;
      std::fprintf(stderr, "  (threw: %s)\n", e.what());
    }
    CHECK(!threw && r.refused && r.refusal_code == "press_stack_failed" &&
              r.refusal_reason.find(std::to_string(top_region)) != std::string::npos &&
              r.refusal_reason.find("into the part") != std::string::npos,
          "27: a press that fails to stack: refused with code press_stack_failed, its region and core's reason");
  }

  // 24: the Top pressed, its include region only the x < 50 half of it (depth 20): only the
  // half's columns are pressed, the weight is over them, and the map spans them.
  {
    const std::string half = ",{\"id\":120,\"add\":[" + std::to_string(top) +
                             "],\"cuts\":[{\"point\":[50,0,0],\"normal\":[-1,0,0],\"strict\":true}]}";
    const std::string reg =
        "{\"role\":\"include\",\"kind\":\"region\",\"region_id\":120,\"geometry\":{\"depth_mm\":20}}";
    const FlexibleRunResult r =
        run_on("half", pad_dir, pad_job(50, "[" + loaded(top_region) + "]", "", reg, half));
    const Stack* s = r.stacks.empty() ? nullptr : &r.stacks[0];
    std::printf("  24: %zu pressed columns, footprint %.1f mm2, %d over solid not pressed, map u %.1f..%.1f\n",
                s ? s->columns.size() : 0, s ? s->footprint_area_mm2 : 0.0, s ? s->over_solid_columns : -1,
                s ? s->map_u0 : 0.0, s ? s->map_u1 : 0.0);
    CHECK(s != nullptr && s->columns.size() == 1250 && std::fabs(s->footprint_area_mm2 - 5000.0) < 1e-6,
          "24: only the lattice half's columns are pressed (1,250 at 2 mm; 5,000 mm2)");
    CHECK(s != nullptr && s->over_solid_columns == 1250, "24: the solid half's columns are counted, not pressed");
    CHECK(s != nullptr && std::fabs((s->map_u1 - s->map_u0) - 50.0) < 1e-6,
          "24: the curves' map spans the lattice half (50 mm), not the face (100 mm)");
    CHECK(r.receipt_json.find("\"columns_over_solid_not_pressed\": 1250") != std::string::npos,
          "24: the receipt says how many columns were not pressed");
  }
}

int main() {
  std::setvbuf(stdout, nullptr, _IONBF, 0);
  test_run();
  test_surface_fill();
  test_edge_to_edge();
  test_pieces();
  test_run_items();
  std::printf("test_flexible_b1a: %d checks, %d failures\n", g_checks, g_failures);
  return g_failures == 0 ? 0 : 1;
}
