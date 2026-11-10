// E3's last item (plan.md §B7): an include region's own CELL WINDOW (cell_min_mm,
// cell_max_mm), on the swept plan. The region's voxels take only the part's ladder cells
// (grading cell_min_mm x 2^L) inside its window; a cell the window leaves with no
// printable level stays solid (reject reason 3, cells_dropped_by_window).
//
// §1 the keys at the parse: swept only; a window holding none of the ladder's cells and
//    an inverted window are refused, naming the region.
// §2 the bar latticed through as two regions, left and right half, swept 1.6-6.4 mm:
//    without windows (the control) and with "Left" held to 3.2 mm and "Right" to 1.6 mm.
//    "Left" (1.6-6.4 mm in the control) takes only 3.2 mm cells. "Right" (6.4 mm in the
//    control: under this light load its density prints at no finer cell) is left with no
//    printable cell in its window, so all of it stays solid, counted by window.
#include "topopt/job.hpp"
#include "topopt/loadcase.hpp"
#include "topopt/materials.hpp"
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

// A 60 x 40 x 40 mm bar. (60 x 20 x 20 until ruling 11-09 (2), the grid's outside read as
// void: a 20 mm bar then holds no 6.4 mm cell -- octet needs 32 mm across for 5 of them --
// and the control's "Right" latticed nothing. It did before only because the member width
// read the bar's own faces, which are the grid's edge, as more material.)
TriangleMesh bar() {
  TriangleMesh m;
  const double L = 60.0, W = 40.0, H = 40.0;
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
    if (fi.plane_normal.x * nx + fi.plane_normal.y * ny + fi.plane_normal.z * nz > 0.99)
      return f;
  }
  return -1;
}

struct Faces { int left = -1, top = -1, right = -1; };

// Two include regions under the top face, left and right half, the bar's full depth.
// `left_extra` / `right_extra` are each region's own keys. Growth off; light load.
std::string job_json(const Faces& f, const std::string& left_extra,
                     const std::string& right_extra, const std::string& cell_mode) {
  const std::string anchor = "[" + std::to_string(f.left) + "]";
  char regions[900];
  std::snprintf(regions, sizeof regions,
                ", \"regions\": ["
                "{\"role\": \"include\", \"kind\": \"face\", \"face_id\": %d, \"label\": \"Left\", "
                "\"geometry\": {\"origin\": [15, 20, 40], \"normal\": [0, 0, -1], "
                "\"half_u_mm\": 15, \"half_w_mm\": 20, \"depth_mm\": 40}%s}, "
                "{\"role\": \"include\", \"kind\": \"face\", \"face_id\": %d, \"label\": \"Right\", "
                "\"geometry\": {\"origin\": [45, 20, 40], \"normal\": [0, 0, -1], "
                "\"half_u_mm\": 15, \"half_w_mm\": 20, \"depth_mm\": 40}%s}]",
                f.top, left_extra.c_str(), f.top, right_extra.c_str());
  const std::string cells = cell_mode == "swept"
                                ? "\"cell_mode\": \"swept\", \"cell_min_mm\": 1.6, \"cell_max_mm\": 6.4"
                                : "\"cell_mm\": 4.0";
  return "{\"model\": \"lattice_window_bar.stl\", \"material\": \"PLA\", \"mode\": "
         "\"lattice_part\", \"resolution\": 48, "
         "\"loads\": {\"minimize_plastic\": true, \"build_dir\": [0, 0, 1], "
         "\"anchor_face_ids\": " + anchor + ", \"groups\": [{\"face_ids\": [" +
         std::to_string(f.top) + "], \"force\": [0, 0, -30]}]}, "
         "\"lattice\": {\"topology\": \"octet\", \"skin\": \"none\", "
         "\"require_lattice_void_reaches_exterior\": false" + std::string(regions) + "}, "
         "\"grading\": {\"topology\": \"octet\", " + cells +
         ", \"min_extrudable_width_mm\": 0.45}, "
         "\"output\": {\"report\": \"report.json\", \"mesh_format\": \"stl\", "
         "\"mesh_prefix\": \"variant\"}}";
}

bool refused_with(const std::string& json, const std::string& words) {
  try {
    (void)parse_job(json);
  } catch (const JobError& e) {
    const bool ok = std::string(e.what()).find(words) != std::string::npos;
    if (!ok) std::printf("  (refused, but with: %s)\n", e.what());
    return ok;
  }
  return false;
}

std::string read_file(const std::string& p) {
  std::ifstream in(p);
  std::stringstream ss;
  ss << in.rdbuf();
  return ss.str();
}

// The [lo, hi] after "cell_mm_graded" in the region labelled `label` (NaN when absent).
std::pair<double, double> cells_of(const std::string& r, const std::string& label) {
  const double nan = std::numeric_limits<double>::quiet_NaN();
  const std::size_t at = r.find("\"label\": \"" + label + "\"");
  if (at == std::string::npos) return {nan, nan};
  const std::size_t end = r.find("}}", at);
  const std::size_t k = r.find("\"cell_mm_graded\": [", at);
  if (k == std::string::npos || k > end) return {nan, nan};
  char* p = nullptr;
  const double lo = std::strtod(r.c_str() + k + 19, &p);
  const double hi = std::strtod(p + 1, nullptr);
  return {lo, hi};
}

std::string lattice_part(const std::string& dir, const std::string& tag, const std::string& json) {
  const std::string folder = dir + "/lattice_window_" + tag;
  std::filesystem::remove_all(folder);
  std::ofstream(dir + "/lattice_window_" + tag + ".json") << json;
  std::string receipt;
  try {
    const MaterialLibrary materials = load_materials_file(MATERIALS_JSON_PATH);
    const SettingsRules rules = load_settings_rules_file(SETTINGS_RULES_PATH);
    const JobDescription job = load_job_file(dir + "/lattice_window_" + tag + ".json");
    (void)lattice_variant_job(job, dir, folder, materials, rules);
  } catch (const std::exception& e) {
    std::printf("  (%s refused: %s)\n", tag.c_str(), e.what());
  }
  if (std::filesystem::exists(folder))
    for (const auto& e : std::filesystem::directory_iterator(folder)) {
      const std::string n = e.path().filename().string();
      if (n.size() > 20 && n.compare(n.size() - 20, 20, "_lattice.report.json") == 0)
        receipt = read_file(e.path().string());
    }
  return receipt;
}

}  // namespace

int main() {
  const std::string dir = TMP_DIR;
  write_stl_file(dir + "/lattice_window_bar.stl", bar(), StlFormat::Binary);
  const StepModel model = import_part(dir + "/lattice_window_bar.stl").model;
  Faces f;
  f.left = face_with_normal(model, -1, 0, 0);
  f.top = face_with_normal(model, 0, 0, 1);
  f.right = face_with_normal(model, 1, 0, 0);
  CHECK(f.left >= 0 && f.top >= 0 && f.right >= 0, "precondition: the bar's three faces");

  // ── §1 the keys at the parse ────────────────────────────────────────────────
  const std::string w32 = ", \"cell_min_mm\": 3.2, \"cell_max_mm\": 3.2";
  CHECK(parse_job(job_json(f, w32, "", "swept")).lattice.regions[0].cell_max_mm == 3.2,
        "§1 a window parses on the swept plan");
  CHECK(refused_with(job_json(f, w32, "", "fixed"),
                     "lattice region \"Left\": its own cell window (cell_min_mm, cell_max_mm) "
                     "needs the swept cell plan"),
        "§1 off the swept plan it is refused, naming the region");
  CHECK(refused_with(job_json(f, ", \"cell_min_mm\": 2.0, \"cell_max_mm\": 3.0", "", "swept"),
                     "lattice region \"Left\": its cell window [2, 3] mm holds none of the "
                     "part's ladder cells (1.6, 3.2, 6.4 mm"),
        "§1 a window holding no ladder cell is refused, listing the ladder");
  CHECK(refused_with(job_json(f, ", \"cell_min_mm\": 6.4, \"cell_max_mm\": 3.2", "", "swept"),
                     "needs cell_min_mm <= cell_max_mm"),
        "§1 an inverted window is refused");

  // ── §2 control against windows ──────────────────────────────────────────────
  // The control states a region exponent equal to the part's (1.0), so its receipt
  // carries the regions too.
  const std::string same = ", \"demand_exponent\": 1.0";
  const std::string ctl = lattice_part(dir, "control", job_json(f, same, same, "swept"));
  const std::string win = lattice_part(
      dir, "windows",
      job_json(f, same + w32, same + ", \"cell_min_mm\": 1.6, \"cell_max_mm\": 1.6", "swept"));
  const auto cl = cells_of(ctl, "Left"), cr = cells_of(ctl, "Right");
  const auto wl = cells_of(win, "Left"), wr = cells_of(win, "Right");
  std::printf("[window] control: Left %.2f-%.2f, Right %.2f-%.2f; windows: Left %.2f-%.2f, "
              "Right %.2f-%.2f\n", cl.first, cl.second, cr.first, cr.second, wl.first,
              wl.second, wr.first, wr.second);
  CHECK(std::isfinite(cl.first) && std::isfinite(cr.first), "§2 the control's regions report cells");
  CHECK(std::fabs(wl.first - 3.2) < 1e-6 && std::fabs(wl.second - 3.2) < 1e-6,
        "§2 \"Left\" takes only 3.2 mm cells");
  CHECK(!(std::fabs(cl.first - 3.2) < 1e-6 && std::fabs(cl.second - 3.2) < 1e-6),
        "§2 the control's \"Left\" is not 3.2 mm alone: the window moved its cells");
  CHECK(std::fabs(cr.first - 1.6) > 1e-6 &&
            win.find("\"label\": \"Right\", \"kind\": \"face\", \"latticed_voxels\": 0,") !=
                std::string::npos,
        "§2 \"Right\" prints no 1.6 mm cell (control coarser) and is left solid");
  const std::string wri = read_file(dir + "/lattice_window_windows/run_info.json");
  const std::string cri = read_file(dir + "/lattice_window_control/run_info.json");
  CHECK(wri.find("\"cells_dropped_by_window\": ") != std::string::npos &&
            cri.find("cells_dropped_by_window") == std::string::npos,
        "§2 the cells the window left solid are counted (the control has none)");
  CHECK(win.find("\"cell_min_mm\": 3.2, \"cell_max_mm\": 3.2") != std::string::npos,
        "§2 the receipt states the window");

  std::printf("%s: %d checks, %d failures\n", g_failures ? "FAIL" : "PASS", g_checks,
              g_failures);
  return g_failures ? 1 : 0;
}
