// THE AESTHETIC THIN-WALL FLOOR (the maintainer's ruling 11-10 (i), given to LatticeReview,
// landing in LatticeTypes' code): "2 cells across, or 1 with 'Allow single-cell members'.
// Structural stays at 5. The run changes to match the preview. Aesthetic carries one plain
// line that thin walls aren't strength-checked."
//
// The app's preview already held an aesthetic wall to the hard floor (LatticeStageMode.
// cellsPerMemberFloor reads latticeAestheticCellsPerMemberHardFloor), while the run held it
// to the accuracy floor of 5 unless an allowable armed the adaptive rule -- so his aesthetic
// wall drew latticed and printed solid.
//
// The bar, octet at a 4 mm cell, 0.45 mm bead, lattice_part (the part latticed through):
// §1 one function: lattice_member_floor_cells is 5 Structural, 2 Aesthetic, 1 Aesthetic with
//    single-cell members AND a finish, 2 with single-cell and no finish; a type whose skinned
//    1-cell member is not measured (kelvin) stays at 2.
// §2 a 12 mm plate under Structural is refused (5 x 4 = 20 mm needed).
// §3 the same plate under Aesthetic is latticed (2 x 4 = 8 mm), and the receipt carries the
//    floor, the material under the accuracy floor, and the plain line.
// §4 a 6 mm plate under Aesthetic is refused (8 mm needed); with single-cell members and a
//    skin it is latticed (1 x 4 = 4 mm).
// §5 refusals in words: single-cell members under Structural; with no finish.
// §6 a Structural receipt carries no thin-walls line.
//
// The reviewer's four additions (ruling 11-10 (3), from LatticeReview's chunk 9), red first:
// §7 THE WIDTH BELOW A VOXEL. On a 2.5 mm grid a 9 mm plate read 10 mm (the levels move in
//    two-voxel steps and round up), so it cleared the 5-cell floor of a 2 mm cell (10 mm)
//    that it does not hold. Measured below a voxel it reads 9 mm: under 5 cells, over 2. The
//    same on the voxel model (a 3-voxel wall read 4), and on a plate lying at 30 degrees.
// §8 THE FORECAST GRADES THE JOB'S OWN INTENT: the 12 mm plate's Aesthetic forecast holds a
//    member to 2 cells and would lattice it (it forecast Structural, 5 cells, and nothing).
// §9 A JOB WITH NO GRADING BLOCK GETS THE PRINTABILITY FLOOR: a strut thinner than the
//    stated line is refused in words. (Its thin-wall floor: the lattice rebuild.)
// (The flat 2 / 1 floor with the adaptive key unarmed is §1-§4: no allowable is sent.)
#include "topopt/job.hpp"
#include "topopt/lattice.hpp"
#include "topopt/materials.hpp"
#include "topopt/mesh_distance.hpp"
#include "topopt/voxel.hpp"
#include "topopt/part.hpp"
#include "topopt/settings.hpp"
#include "topopt/stl.hpp"

#include <cmath>
#include <cstdio>
#include <filesystem>
#include <fstream>
#include <limits>
#include <sstream>
#include <string>
#include <vector>

using namespace topopt;

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

namespace {

TriangleMesh plate(double L, double W, double H) {
  TriangleMesh m;
  for (const Vec3& v : std::vector<Vec3>{{0, 0, 0}, {L, 0, 0}, {L, W, 0}, {0, W, 0},
                                         {0, 0, H}, {L, 0, H}, {L, W, H}, {0, W, H}})
    m.vertices.push_back(v);
  const int t[12][3] = {{0, 2, 1}, {0, 3, 2}, {4, 5, 6}, {4, 6, 7}, {0, 1, 5}, {0, 5, 4},
                        {3, 7, 6}, {3, 6, 2}, {0, 4, 7}, {0, 7, 3}, {1, 2, 6}, {1, 6, 5}};
  for (const auto& tri : t) m.triangles.push_back({tri[0], tri[1], tri[2]});
  return m;
}

int face_with_normal(const StepModel& m, double nx, double ny, double nz) {
  for (int f = 0; f < m.face_count; ++f) {
    const StepFaceInfo& fi = m.faces[static_cast<std::size_t>(f)];
    if (fi.kind != StepSurfaceKind::Plane) continue;
    if (fi.plane_normal.x * nx + fi.plane_normal.y * ny + fi.plane_normal.z * nz > 0.99) return f;
  }
  return -1;
}

std::string read_file(const std::string& p) {
  std::ifstream in(p, std::ios::binary);
  std::stringstream ss;
  ss << in.rdbuf();
  return ss.str();
}

double num_after(const std::string& s, const std::string& key) {
  const std::size_t k = s.find("\"" + key + "\": ");
  if (k == std::string::npos) return std::numeric_limits<double>::quiet_NaN();
  return std::strtod(s.c_str() + k + key.size() + 4, nullptr);
}

std::string job_json(const std::string& model, int anchor, int load, const std::string& intent,
                     const std::string& skin, const std::string& grading_extra) {
  return "{\"model\": \"" + model + "\", \"material\": \"PLA\", \"mode\": \"lattice_part\", "
         "\"resolution\": 48, \"loads\": {\"minimize_plastic\": true, \"build_dir\": [0, 0, 1], "
         "\"anchor_face_ids\": [" + std::to_string(anchor) + "], \"groups\": [{\"face_ids\": [" +
         std::to_string(load) + "], \"force\": [0, 0, -10]}]}, "
         "\"lattice\": {\"topology\": \"octet\", \"require_lattice_void_reaches_exterior\": false, "
         "\"skin\": \"" + skin + "\", \"outer_finish\": \"none\", \"emit_welded_stl\": false}, "
         "\"grading\": {\"topology\": \"octet\", \"cell_mm\": 4.0, \"min_extrudable_width_mm\": "
         "0.45, \"intent\": \"" + intent + "\"" + grading_extra + "}, "
         "\"output\": {\"report\": \"report.json\", \"mesh_format\": \"stl\", \"mesh_prefix\": "
         "\"wall\"}}";
}

struct Run {
  std::string refused, receipt, run_info;
};

Run run(const std::string& dir, const std::string& name, const std::string& json) {
  Run r;
  const std::string out = dir + "/" + name + "_run";
  std::filesystem::remove_all(out);
  std::ofstream(dir + "/" + name + ".json") << json;
  try {
    const MaterialLibrary materials = load_materials_file(MATERIALS_JSON_PATH);
    const SettingsRules rules = load_settings_rules_file(SETTINGS_RULES_PATH);
    const JobDescription job = load_job_file(dir + "/" + name + ".json");
    (void)lattice_variant_job(job, dir, out, materials, rules);
  } catch (const std::exception& e) {
    r.refused = e.what();
  }
  if (std::filesystem::exists(out))
    for (const auto& e : std::filesystem::directory_iterator(out)) {
      const std::string n = e.path().filename().string();
      if (n.size() > 20 && n.compare(n.size() - 20, 20, "_lattice.report.json") == 0)
        r.receipt = read_file(e.path().string());
      if (n == "run_info.json") r.run_info = read_file(e.path().string());
    }
  return r;
}

bool has(const std::string& h, const std::string& n) { return h.find(n) != std::string::npos; }

// A prism: the polygon `poly` (CCW in the y-z plane) extruded along x over [0, L].
TriangleMesh prism(const std::vector<std::pair<double, double>>& poly, double L) {
  TriangleMesh m;
  const int n = static_cast<int>(poly.size());
  for (double x : {0.0, L})
    for (const auto& [y, z] : poly) m.vertices.push_back({x, y, z});
  for (int i = 1; i + 1 < n; ++i) {
    m.triangles.push_back({0, i + 1, i});              // x = 0, normal -x
    m.triangles.push_back({n, n + i, n + i + 1});      // x = L, normal +x
  }
  for (int i = 0; i < n; ++i) {
    const int a = i, b = (i + 1) % n;
    m.triangles.push_back({a, b, n + b});
    m.triangles.push_back({a, n + b, n + a});
  }
  return m;
}

// A grid of `nx, ny, nz` voxels of `h` at the origin, solid where `inside` holds at the centre.
template <class F>
VoxelGrid grid_of(int nx, int ny, int nz, double h, F inside) {
  VoxelGrid g;
  g.nx = nx, g.ny = ny, g.nz = nz, g.spacing = h, g.origin = {0, 0, 0};
  g.tags.assign(static_cast<std::size_t>(nx) * ny * nz, VoxelTag::Empty);
  for (int k = 0; k < nz; ++k)
    for (int j = 0; j < ny; ++j)
      for (int i = 0; i < nx; ++i)
        if (inside(g.voxel_center(i, j, k))) g.set_tag(i, j, k, VoxelTag::Interior);
  return g;
}

// The width's range over the solid voxels whose centre satisfies `pick`.
template <class F>
std::pair<double, double> width_range(const VoxelGrid& g, const std::vector<double>& w, F pick) {
  double lo = 1e9, hi = -1e9;
  for (int k = 0; k < g.nz; ++k)
    for (int j = 0; j < g.ny; ++j)
      for (int i = 0; i < g.nx; ++i) {
        if (!g.solid(i, j, k) || !pick(g.voxel_center(i, j, k))) continue;
        const double v = w[g.index(i, j, k)];
        lo = std::min(lo, v), hi = std::max(hi, v);
      }
  return {lo, hi};
}

}  // namespace

int main() {
  const std::string dir = TMP_DIR;
  const auto oct = LatticeTopology::Octet;

  // ── §1 one function ────────────────────────────────────────────────────────
  CHECK(lattice_member_floor_cells(oct, false, false, true) == 5.0, "§1 Structural: 5");
  CHECK(lattice_member_floor_cells(oct, false, true, true) == 5.0,
        "§1 Structural ignores single-cell members");
  CHECK(lattice_member_floor_cells(oct, true, false, true) == 2.0, "§1 Aesthetic: 2");
  CHECK(lattice_member_floor_cells(oct, true, true, true) == 1.0,
        "§1 Aesthetic with single-cell members and a finish: 1");
  CHECK(lattice_member_floor_cells(oct, true, true, false) == 2.0,
        "§1 single-cell members with no finish stay at 2");
  CHECK(lattice_member_floor_cells(LatticeTopology::Kelvin, true, true, true) == 2.0,
        "§1 a type whose skinned 1-cell member is not measured stays at 2");
  CHECK(lattice_member_floor_cells(oct, true, false, false) ==
            aesthetic_cells_per_member_hard_floor(oct, false),
        "§1 the preview's function and the run's agree");

  auto part = [&](const std::string& name, double W) {
    write_stl_file(dir + "/" + name + ".stl", plate(60.0, W, 30.0), StlFormat::Binary);
    const StepModel m = import_part(dir + "/" + name + ".stl").model;
    return std::make_pair(face_with_normal(m, 0, 0, -1), face_with_normal(m, 0, 0, 1));
  };

  // ── §2 a 12 mm plate under Structural ──────────────────────────────────────
  const auto [b12, t12] = part("thin_wall_12", 12.0);
  CHECK(b12 >= 0 && t12 >= 0, "precondition: the 12 mm plate's bottom and top");
  const Run st = run(dir, "thin_wall_12_structural",
                     job_json("thin_wall_12.stl", b12, t12, "structural", "none", ""));
  std::printf("[thin-wall] §2 12 mm, Structural: %s\n",
              st.refused.empty() ? "(written)" : st.refused.substr(0, 400).c_str());
  CHECK(has(st.refused, "could lattice NONE") && has(st.refused, "under the 20 mm that 5 cells"),
        "§2 a 12 mm plate under Structural is refused: 5 cells of 4 mm need 20 mm");

  // ── §3 the same plate under Aesthetic ──────────────────────────────────────
  const Run ae = run(dir, "thin_wall_12_aesthetic",
                     job_json("thin_wall_12.stl", b12, t12, "aesthetic", "none", ""));
  if (!ae.refused.empty()) std::printf("[thin-wall] §3 refused: %s\n", ae.refused.c_str());
  const double lat = num_after(ae.receipt, "latticed_voxels");
  const double below = num_after(ae.receipt, "below_accuracy_floor_voxels");
  std::printf("[thin-wall] §3 12 mm, Aesthetic: latticed %.0f, under the accuracy floor %.0f, "
              "floor %.0f\n", lat, below, num_after(ae.receipt, "member_floor_cells"));
  CHECK(ae.refused.empty() && lat > 0, "§3 the same plate under Aesthetic is latticed");
  CHECK(num_after(ae.receipt, "member_floor_cells") == 2.0 &&
            num_after(ae.receipt, "accuracy_floor_cells") == 5.0,
        "§3 the receipt names the floor it held (2) beside the accuracy floor (5)");
  CHECK(below > 0, "§3 and counts the latticed material under the accuracy floor");
  CHECK(has(ae.receipt, kAestheticThinWallsLine) && has(ae.run_info, kAestheticThinWallsLine),
        "§3 the receipt and run_info carry the plain line: thin walls are not strength-checked");

  // ── §4 a 6 mm plate: 2 cells refuse, 1 cell with a skin lattices ────────────
  const auto [b6, t6] = part("thin_wall_6", 6.0);
  const Run a6 = run(dir, "thin_wall_6_aesthetic",
                     job_json("thin_wall_6.stl", b6, t6, "aesthetic", "none", ""));
  std::printf("[thin-wall] §4 6 mm, Aesthetic: %s\n",
              a6.refused.empty() ? "(written)" : a6.refused.substr(0, 400).c_str());
  CHECK(has(a6.refused, "could lattice NONE") && has(a6.refused, "under the 8 mm that 2 cells"),
        "§4 a 6 mm plate under Aesthetic is refused: 2 cells of 4 mm need 8 mm");
  const Run s6 = run(dir, "thin_wall_6_single",
                     job_json("thin_wall_6.stl", b6, t6, "aesthetic", "diagrid",
                              ", \"single_cell_members\": true"));
  if (!s6.refused.empty()) std::printf("[thin-wall] §4 single-cell refused: %s\n", s6.refused.c_str());
  std::printf("[thin-wall] §4 6 mm, single-cell members + skin: latticed %.0f, floor %.0f\n",
              num_after(s6.receipt, "latticed_voxels"), num_after(s6.receipt, "member_floor_cells"));
  CHECK(s6.refused.empty() && num_after(s6.receipt, "latticed_voxels") > 0 &&
            num_after(s6.receipt, "member_floor_cells") == 1.0,
        "§4 with single-cell members and a skin it is latticed, at a floor of 1 cell");

  // ── §5 refusals ────────────────────────────────────────────────────────────
  auto parse_refusal = [&](const std::string& name, const std::string& json) {
    std::ofstream(dir + "/" + name + ".json") << json;
    try {
      (void)load_job_file(dir + "/" + name + ".json");
    } catch (const std::exception& e) {
      return std::string(e.what());
    }
    return std::string();
  };
  CHECK(has(parse_refusal("thin_wall_single_structural",
                          job_json("thin_wall_6.stl", b6, t6, "structural", "diagrid",
                                   ", \"single_cell_members\": true")),
            "is an Aesthetic setting"),
        "§5 single-cell members under Structural are refused in words");
  CHECK(has(parse_refusal("thin_wall_single_bare",
                          job_json("thin_wall_6.stl", b6, t6, "aesthetic", "none",
                                   ", \"single_cell_members\": true")),
            "needs a finish"),
        "§5 single-cell members with no finish are refused in words");

  // ── §6 Structural keeps its receipt ────────────────────────────────────────
  const auto [b40, t40] = part("thin_wall_24", 24.0);
  const Run s24 = run(dir, "thin_wall_24_structural",
                      job_json("thin_wall_24.stl", b40, t40, "structural", "none", ""));
  CHECK(s24.refused.empty() && !has(s24.receipt, "thin_walls") &&
            !has(s24.run_info, kAestheticThinWallsLine),
        "§6 a Structural receipt carries no thin-walls line");

  // ── §7 the width below a voxel ─────────────────────────────────────────────
  {
    const double h = 2.5, cell = 2.0, five = 5.0 * cell, two = 2.0 * cell;
    // A 9 mm plate (y 0-9), 60 x 30 mm, on a 2.5 mm grid from its corner: centres at y 1.25,
    // 3.75, 6.25 and 8.75, so the deepest lies 3.75 mm in and the levels read 2 x 2 x 2.5.
    const TriangleMesh pm = plate(60.0, 9.0, 30.0);
    const MeshDistance md(pm);
    const VoxelGrid g = grid_of(24, 4, 12, h, [](const Vec3& c) { return c.y < 9.0; });
    const std::vector<double> rho(g.voxel_count(), 1.0);
    auto mid = [](const Vec3& c) { return std::fabs(c.x - 30.0) < 15.0 && std::fabs(c.z - 15.0) < 6.0; };
    const auto old_w = width_range(g, lattice_member_width_mm(g, rho, 0.5, 32, five, cell, &md), mid);
    const auto new_w = width_range(
        g, lattice_member_width_mm(g, rho, 0.5, 32, five, cell, &md, nullptr, nullptr, five + 3 * h), mid);
    std::printf("[thin-wall] §7 9 mm plate on a 2.5 mm grid: the levels read %.3f-%.3f mm, below a "
                "voxel %.3f-%.3f mm\n", old_w.first, old_w.second, new_w.first, new_w.second);
    CHECK(old_w.first >= five, "§7 red: the levels read the 9 mm plate as 10 mm, clearing 5 cells");
    CHECK(std::fabs(new_w.first - 9.0) < 0.02 && std::fabs(new_w.second - 9.0) < 0.02,
          "§7 below a voxel the 9 mm plate reads 9 mm");
    CHECK(new_w.second < five && new_w.first >= two,
          "§7 so it is under the 5-cell floor and over the 2-cell one");
    // The voxel model: a wall 3 voxels thick (7.5 mm) read 4 voxels (10 mm).
    const VoxelGrid s = grid_of(24, 5, 12, h, [](const Vec3& c) { return c.y < 7.5; });
    const std::vector<double> rs(s.voxel_count(), 1.0);
    const auto s_old = width_range(s, lattice_member_width_mm(s, rs, 0.5, 32, five, cell), mid);
    const auto s_new = width_range(
        s, lattice_member_width_mm(s, rs, 0.5, 32, five, cell, nullptr, nullptr, nullptr, five + 3 * h), mid);
    std::printf("[thin-wall] §7 a 3-voxel wall on the voxel model: the levels read %.3f-%.3f mm, "
                "below a voxel %.3f-%.3f mm\n", s_old.first, s_old.second, s_new.first, s_new.second);
    CHECK(s_old.first >= five, "§7 red: a 3-voxel wall (7.5 mm) read 4 voxels (10 mm)");
    CHECK(std::fabs(s_new.first - 7.5) < 1e-6 && std::fabs(s_new.second - 7.5) < 1e-6,
          "§7 below a voxel it reads its 7.5 mm");
    // An EVEN count: 4 voxels (10 mm), whose ridge lies between two voxel centres.
    const VoxelGrid s4 = grid_of(24, 6, 12, h, [](const Vec3& c) { return c.y < 10.0; });
    const std::vector<double> r4(s4.voxel_count(), 1.0);
    const auto s4_new = width_range(
        s4, lattice_member_width_mm(s4, r4, 0.5, 32, 4.0 * five, cell, nullptr, nullptr, nullptr,
                                    4.0 * five + 3 * h), mid);
    std::printf("[thin-wall] §7 a 4-voxel wall on the voxel model: below a voxel %.6f-%.6f mm\n",
                s4_new.first, s4_new.second);
    CHECK(std::fabs(s4_new.first - 10.0) < 1e-6 && std::fabs(s4_new.second - 10.0) < 1e-6,
          "§7 an even count reads its own 10 mm too (the ridge between two centres)");
    // A 7 mm plate lying at 30 degrees in x-y: its own thickness wherever it lies on the grid.
    const double a = 30.0 * 3.14159265358979323846 / 180.0, ca = std::cos(a), sa = std::sin(a);
    TriangleMesh tm = plate(80.0, 7.0, 30.0);
    for (Vec3& v : tm.vertices) {
      const double x = v.x - 40.0, y = v.y - 3.5;
      v = {40.0 + ca * x - sa * y, 30.0 + sa * x + ca * y, v.z};
    }
    const MeshDistance tmd(tm);
    const VoxelGrid t = grid_of(32, 24, 12, h, [&](const Vec3& c) { return tmd.signed_distance(c) > 0.0; });
    const std::vector<double> rt(t.voxel_count(), 1.0);
    auto tmid = [&](const Vec3& c) {
      return std::fabs(ca * (c.x - 40.0) + sa * (c.y - 30.0)) < 20.0 && std::fabs(c.z - 15.0) < 6.0;
    };
    const auto t_new = width_range(
        t, lattice_member_width_mm(t, rt, 0.5, 32, five, cell, &tmd, nullptr, nullptr, five + 3 * h), tmid);
    std::printf("[thin-wall] §7 a 7 mm plate at 30 degrees: below a voxel %.3f-%.3f mm\n", t_new.first,
                t_new.second);
    CHECK(t_new.second <= 7.0 + 1e-6 && t_new.first > 7.0 - 0.1,
          "§7 a 7 mm plate at 30 degrees reads 7 mm (never wider, within 0.1 mm)");
  }

  // ── §8 the forecast grades the job's own intent ─────────────────────────────
  {
    const std::string fj = job_json("thin_wall_12.stl", b12, t12, "aesthetic", "none", "");
    std::string j = fj;
    j.replace(j.find("\"emit_welded_stl\": false"), 24, "\"emit_welded_stl\": false, \"forecast_only\": true");
    const Run f = run(dir, "thin_wall_12_forecast", j);
    const std::string fc = read_file(dir + "/thin_wall_12_forecast_run/lattice_forecast.json");
    std::printf("[thin-wall] §8 forecast, 12 mm Aesthetic: floor %.0f, would lattice %.0f %s\n",
                num_after(fc, "cells_per_member_floor"), num_after(fc, "would_lattice_voxels"),
                f.refused.c_str());
    CHECK(num_after(fc, "cells_per_member_floor") == 2.0,
          "§8 the forecast holds an Aesthetic member to 2 cells, as the run does");
    CHECK(num_after(fc, "would_lattice_voxels") > 0,
          "§8 and forecasts the plate the run lattices (it forecast nothing at 5 cells)");
  }

  // ── §9 a job with no grading block gets the floors ─────────────────────────
  {
    // An L along x: a 16 mm leg (y 0-16, z 0-30) and a 6 mm one (y 16-40, z 0-6).
    write_stl_file(dir + "/thin_wall_l.stl",
                   prism({{0, 0}, {40, 0}, {40, 6}, {16, 6}, {16, 30}, {0, 30}}, 60.0),
                   StlFormat::Binary);
    const StepModel lm = import_part(dir + "/thin_wall_l.stl").model;
    const int lb = face_with_normal(lm, 0, 0, -1), lt = face_with_normal(lm, 0, 0, 1);
    auto ungraded = [&](const std::string& extra) {
      return "{\"model\": \"thin_wall_l.stl\", \"material\": \"PLA\", \"mode\": \"lattice_part\", "
             "\"resolution\": 48, \"loads\": {\"minimize_plastic\": true, \"build_dir\": [0, 0, 1], "
             "\"anchor_face_ids\": [" + std::to_string(lb) + "], \"groups\": [{\"face_ids\": [" +
             std::to_string(lt) + "], \"force\": [0, 0, -10]}]}, "
             "\"lattice\": {\"topology\": \"octet\", \"cell_mm\": 4.0, \"strut_radius_mm\": 0.6, "
             "\"require_lattice_void_reaches_exterior\": false, \"skin\": \"none\", "
             "\"outer_finish\": \"none\", \"emit_welded_stl\": false" + extra + "}, "
             "\"output\": {\"report\": \"report.json\", \"mesh_format\": \"stl\", "
             "\"mesh_prefix\": \"l\"}}";
    };
    CHECK(lb >= 0 && lt >= 0, "precondition: the L's bottom and top");
    // (The ungraded THIN-WALL floor is built and disarmed -- run_job.cpp says why; its checks
    // land with it armed, in the lattice rebuild. The printability floor is armed here.)
    std::string thin = ungraded(", \"min_extrudable_width_mm\": 0.45");
    thin.replace(thin.find("\"strut_radius_mm\": 0.6"), 22, "\"strut_radius_mm\": 0.2");
    CHECK(has(parse_refusal("thin_wall_l_strut", thin), "would not print"),
          "§9 an ungraded strut thinner than the stated line is refused in words");
  }

  std::printf("%s: %d checks, %d failures\n", g_failures == 0 ? "PASS" : "FAIL", g_checks,
              g_failures);
  return g_failures == 0 ? 0 : 1;
}
