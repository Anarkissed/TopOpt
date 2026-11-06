// E2.4 (ruling 11-06 (1)): outer_finish "none", the OPEN lattice. The app's None and
// Covered both sent "shell" (the default), so None was never open.
//
// Open, the cells the part's free surface cuts form a weaker boundary layer (Onck,
// Andrews & Gibson 2001), so the certificate gives them no credit (the safe floor:
// void in the solve, the load path re-walked on the rest), and a lattice that does not
// certify that way is refused by its region's label.
//
// §1 the key at the parse: "none" with skin none, rim or diagrid; "skin" still needs
//    diagrid; an unknown value lists "none".
// §2 a 6 mm lattice layer under the top face, "shell" against "none": no shell in the
//    open file (fewer triangles, no enclosed shell volume), the cut cells counted, and
//    the open margin never above the covered one.
// §3 a lattice layer at the LOADED end, open: the load sits on cut cells, no load path
//    is left, and the refusal names the region by its label.
// §4 an analyze job, the whole bar latticed open: the re-certification floors the cut
//    cells too, and does not accept.
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

// A 60 x 20 x 20 mm bar.
TriangleMesh bar() {
  TriangleMesh m;
  const double L = 60.0, W = 20.0, H = 20.0;
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

// Anchored at x = 0, 300 N in +y on the free end. Growth off.
std::string job_json(const Faces& f, const std::string& mode, const std::string& lattice_extra) {
  const std::string anchor = "[" + std::to_string(f.left) + "]";
  return "{\"model\": \"lattice_open_bar.stl\", \"material\": \"PLA\", \"mode\": \"" + mode +
         "\", \"resolution\": 24, "
         "\"loads\": {\"minimize_plastic\": true, \"build_dir\": [0, 0, 1], "
         "\"anchor_face_ids\": " + anchor + ", \"groups\": [{\"face_ids\": [" +
         std::to_string(f.right) + "], \"force\": [0, 300, 0]}]}, "
         "\"lattice\": {\"topology\": \"octet\", \"require_lattice_void_reaches_exterior\": "
         "false" + lattice_extra + "}, "
         "\"grading\": {\"topology\": \"octet\", \"cell_mm\": 4.0, "
         "\"min_extrudable_width_mm\": 0.45, \"intent\": \"structural\"}, "
         "\"output\": {\"report\": \"report.json\", \"mesh_format\": \"stl\", "
         "\"mesh_prefix\": \"variant\"}}";
}

// A face include: a `depth` mm layer under face `face_id` (outward normal `n`, centre `o`).
std::string region(int face_id, const char* label, const char* origin, const char* normal,
                   double hu, double hw, double depth) {
  char b[500];
  std::snprintf(b, sizeof b,
                ", \"regions\": [{\"role\": \"include\", \"kind\": \"face\", \"face_id\": %d, "
                "\"label\": \"%s\", \"geometry\": {\"origin\": %s, \"normal\": %s, "
                "\"half_u_mm\": %g, \"half_w_mm\": %g, \"depth_mm\": %g}}]",
                face_id, label, origin, normal, hu, hw, depth);
  return b;
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
  std::ifstream in(p, std::ios::binary);
  std::stringstream ss;
  ss << in.rdbuf();
  return ss.str();
}

double num_after(const std::string& s, const std::string& key, std::size_t from = 0) {
  const std::size_t k = s.find("\"" + key + "\": ", from);
  if (k == std::string::npos) return std::numeric_limits<double>::quiet_NaN();
  const std::size_t v = k + key.size() + 4;
  if (s.compare(v, 4, "null") == 0) return std::numeric_limits<double>::quiet_NaN();
  return std::strtod(s.c_str() + v, nullptr);
}

bool has(const std::string& s, const std::string& w) { return s.find(w) != std::string::npos; }

struct Run { std::string receipt; long long stl_bytes = -1; };
Run lattice_part(const std::string& dir, const std::string& tag, const std::string& json) {
  Run out;
  const std::string folder = dir + "/lattice_open_" + tag;
  std::filesystem::remove_all(folder);
  std::ofstream(dir + "/lattice_open_" + tag + ".json") << json;
  try {
    const MaterialLibrary materials = load_materials_file(MATERIALS_JSON_PATH);
    const SettingsRules rules = load_settings_rules_file(SETTINGS_RULES_PATH);
    const JobDescription job = load_job_file(dir + "/lattice_open_" + tag + ".json");
    (void)lattice_variant_job(job, dir, folder, materials, rules);
  } catch (const std::exception& e) {
    std::printf("  (%s refused: %s)\n", tag.c_str(), e.what());
  }
  if (std::filesystem::exists(folder))
    for (const auto& e : std::filesystem::directory_iterator(folder)) {
      const std::string n = e.path().filename().string();
      if (n.size() > 20 && n.compare(n.size() - 20, 20, "_lattice.report.json") == 0)
        out.receipt = read_file(e.path().string());
      if (n.size() > 12 && n.compare(n.size() - 12, 12, "_lattice.stl") == 0)
        out.stl_bytes = static_cast<long long>(std::filesystem::file_size(e.path()));
    }
  return out;
}

}  // namespace

int main() {
  const std::string dir = TMP_DIR;
  write_stl_file(dir + "/lattice_open_bar.stl", bar(), StlFormat::Binary);
  const StepModel model = import_part(dir + "/lattice_open_bar.stl").model;
  Faces f;
  f.left = face_with_normal(model, -1, 0, 0);
  f.top = face_with_normal(model, 0, 0, 1);
  f.right = face_with_normal(model, 1, 0, 0);
  CHECK(f.left >= 0 && f.top >= 0 && f.right >= 0, "precondition: the bar's three faces");

  // ── §1 the key at the parse ─────────────────────────────────────────────────
  for (const char* skin : {"none", "rim", "diagrid"}) {
    const JobDescription j = parse_job(job_json(
        f, "lattice_part",
        std::string(", \"skin\": \"") + skin + "\", \"outer_finish\": \"none\""));
    CHECK(j.lattice.outer_finish == "none" && j.lattice.skin == skin,
          (std::string("§1 \"none\" parses with skin ") + skin).c_str());
  }
  CHECK(refused_with(job_json(f, "lattice_part", ", \"skin\": \"none\", \"outer_finish\": \"skin\""),
                     "needs skin \"diagrid\""),
        "§1 \"skin\" still needs the diagrid (control)");
  CHECK(refused_with(job_json(f, "lattice_part", ", \"outer_finish\": \"open\""),
                     "\"shell+skin\" or \"none\""),
        "§1 an unknown value is refused, listing \"none\"");

  // ── §2 a top layer, covered against open ───────────────────────────────────
  const std::string top = region(f.top, "Top layer", "[30, 10, 20]", "[0, 0, -1]", 30, 10, 6);
  const Run cov = lattice_part(dir, "covered", job_json(f, "lattice_part", ", \"skin\": \"none\"" + top));
  const Run opn = lattice_part(
      dir, "open", job_json(f, "lattice_part", ", \"skin\": \"none\", \"outer_finish\": \"none\"" + top));
  {
    const double mc = num_after(cov.receipt, "lattice_margin_effective");
    const double mo = num_after(opn.receipt, "lattice_margin_effective");
    const double cut = num_after(opn.receipt, "cut_cell_voxels");
    const double lat = num_after(opn.receipt, "latticed_voxels", opn.receipt.find("\"open_finish\""));
    std::printf("[open] covered: margin %.4f, %lld bytes; open: margin %.4f, %lld bytes, "
                "cut %.0f of %.0f latticed, accepted %s\n",
                mc, cov.stl_bytes, mo, opn.stl_bytes, cut, lat,
                has(opn.receipt, "\"lattice_accepted\": true") ? "true" : "false");
    CHECK(!cov.receipt.empty() && !opn.receipt.empty(), "§2 both receipts are written");
    CHECK(!has(cov.receipt, "\"open_finish\"") && has(opn.receipt, "\"outer_finish\": \"none\""),
          "§2 only the open receipt carries the open finish");
    CHECK(cov.stl_bytes > 0 && opn.stl_bytes > 0 && opn.stl_bytes < cov.stl_bytes,
          "§2 the open file has no shell: fewer triangles than the covered one");
    CHECK(num_after(opn.receipt, "shell_enclosed_volume_mm3") == 0.0,
          "§2 the open receipt encloses no shell volume");
    CHECK(cut > 0 && cut <= lat, "§2 the cut cells' voxels are counted, within the lattice");
    CHECK(std::isfinite(mo) && std::isfinite(mc) && mo <= mc * (1.0 + 1e-9),
          "§2 the open margin is never above the covered one (less credit)");
  }

  // ── §3 a layer at the loaded end, open ─────────────────────────────────────
  {
    const std::string end = region(f.right, "End pad", "[60, 10, 10]", "[-1, 0, 0]", 10, 10, 6);
    const Run r = lattice_part(
        dir, "endpad", job_json(f, "lattice_part", ", \"skin\": \"none\", \"outer_finish\": \"none\"" + end));
    const std::size_t at = r.receipt.find("\"refusal\": ");
    std::printf("[open] end pad: accepted %s; %s\n",
                has(r.receipt, "\"lattice_accepted\": true") ? "true" : "false",
                at == std::string::npos ? "(no refusal)" : r.receipt.substr(at, 260).c_str());
    CHECK(has(r.receipt, "\"lattice_accepted\": false"), "§3 the open end pad is not accepted");
    CHECK(has(r.receipt, "\"load_path_after\": false"), "§3 no load path is left");
    CHECK(has(r.receipt, "The open lattice in \\\"End pad\\\" does not certify open"),
          "§3 the refusal names the region by its label");
  }

  // ── §4 an analyze job, the whole bar latticed open ─────────────────────────
  {
    const std::string out = dir + "/lattice_open_an";
    std::filesystem::remove_all(out);
    std::ofstream(dir + "/lattice_open_an.json")
        << job_json(f, "analyze", ", \"skin\": \"none\", \"outer_finish\": \"none\"");
    const MaterialLibrary materials = load_materials_file(MATERIALS_JSON_PATH);
    const SettingsRules rules = load_settings_rules_file(SETTINGS_RULES_PATH);
    const JobDescription job = load_job_file(dir + "/lattice_open_an.json");
    (void)analyze_job(job, dir, out, materials, rules, "", {});
    const std::string ri = read_file(out + "/run_info.json");
    std::printf("[open] analyze: open cut voxels %.0f, accepted %s\n",
                num_after(ri, "recertified_open_cut_voxels"),
                has(ri, "\"recertified_accepted\": true") ? "true" : "false");
    CHECK(num_after(ri, "recertified_open_cut_voxels") > 0,
          "§4 the re-certification floors the cut cells");
    CHECK(has(ri, "\"recertified_accepted\": false"),
          "§4 the whole bar open, loaded on cut cells, does not accept");
  }

  std::printf("%s: %d checks, %d failures\n", g_failures ? "FAIL" : "PASS", g_checks,
              g_failures);
  return g_failures ? 1 : 0;
}
