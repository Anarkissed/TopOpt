// E2.2 + E2.3 (plan.md §B6 notes 26, 25): the "- Lattice faces" mode and No lattice on a
// face region, on one 60 x 20 x 20 mm bar latticed as the part ("Lattice the original
// part", mode lattice_part, so no optimizer runs). Growth is off: with it on, lattice_part
// latticed the whole auto-derived growth box (reported to TO-core, 2026-11-04).
//
// §1 the parse: whole_part is a boolean; an include carrying a setting is refused in that
//    mode until per-region grading (E3); fit with whole_part has no include to fit.
// §2 today's rule, the control: an include on the top face limits the lattice to it.
// §3 whole_part: the same include no longer limits it; the whole part is latticed, voxel
//    for voxel the same as with no regions.
// §4 No lattice on the top face's region (an exclude of kind "region", E2.3): its prism
//    stays solid, in both modes, by the same voxel count.
// §5 E2.5, two regions on one face: a 10 mm prism at density 0.75 and a 16 mm one at 0.88
//    on the top face. Where they overlap the DEEPER owns the voxel, whichever is declared
//    first (ruling 4's tie to the lower id alone gave the overlap to the first declared).
//    Control: the 10 mm region alone is laid at its own 0.75.
// §6 E2.5 at the parse: with two regions on a protected face, the DEEPEST must equal the
//    protection depth; one deeper or shallower than the protection is still refused.
#include "topopt/job.hpp"
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

std::string job_json(int left, int right, int top, const std::string& lattice_extra,
                     const std::string& grading_extra = "", const std::string& loads_extra = "") {
  return "{\"model\": \"lattice_regions_bar.stl\", \"material\": \"PLA\", "
         "\"mode\": \"lattice_part\", \"resolution\": 24, "
         "\"loads\": {\"minimize_plastic\": true, \"build_dir\": [0, 0, 1], "
         "\"anchor_face_ids\": [" + std::to_string(left) + "], \"groups\": [{\"face_ids\": [" +
         std::to_string(right) + "], \"force\": [0, 300, 0]}], "
         "\"face_regions\": [{\"id\": 100, \"name\": \"Top\", \"add\": [" +
         std::to_string(top) + "]}]" + loads_extra + "}, "
         "\"lattice\": {\"topology\": \"octet\", \"skin\": \"none\", "
         "\"require_lattice_void_reaches_exterior\": false" + lattice_extra + "}, "
         "\"grading\": {\"topology\": \"octet\", \"cell_mm\": 4.0, "
         "\"min_extrudable_width_mm\": 0.45" + grading_extra + "}, "
         "\"output\": {\"report\": \"report.json\", \"mesh_format\": \"stl\", "
         "\"mesh_prefix\": \"variant\"}}";
}

const std::string kTopInclude =
    ", \"regions\": [{\"role\": \"include\", \"kind\": \"region\", \"region_id\": 100, "
    "\"geometry\": {\"depth_mm\": 6.0}}]";
// A top-face prism (kind "face", the app's form): origin on the face, normal into the part.
std::string top_prism(int top, double depth, double rho) {
  char b[400];
  std::snprintf(b, sizeof(b),
                "{\"role\": \"include\", \"kind\": \"face\", \"face_id\": %d, %s"
                "\"geometry\": {\"origin\": [30, 10, 20], \"normal\": [0, 0, -1], "
                "\"half_u_mm\": 30, \"half_w_mm\": 10, \"depth_mm\": %g}}",
                top, rho > 0.0 ? ("\"relative_density\": " + std::to_string(rho) + ", ").c_str() : "",
                depth);
  return b;
}

const std::string kTopExclude =
    ", \"regions\": [{\"role\": \"exclude\", \"kind\": \"region\", \"region_id\": 100, "
    "\"geometry\": {\"depth_mm\": 4.0}}]";

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

// The number after `"key": ` at or after `from` (NaN when absent or null).
double num_after(const std::string& s, const std::string& key, std::size_t from = 0) {
  const std::size_t k = s.find("\"" + key + "\": ", from);
  if (k == std::string::npos) return std::numeric_limits<double>::quiet_NaN();
  const std::size_t v = k + key.size() + 4;
  if (s.compare(v, 4, "null") == 0) return std::numeric_limits<double>::quiet_NaN();
  return std::strtod(s.c_str() + v, nullptr);
}

}  // namespace

int main() {
  const MaterialLibrary materials = load_materials_file(MATERIALS_JSON_PATH);
  const SettingsRules rules = load_settings_rules_file(SETTINGS_RULES_PATH);
  const std::string dir = TMP_DIR;
  write_stl_file(dir + "/lattice_regions_bar.stl", bar(), StlFormat::Binary);
  const StepModel model = import_part(dir + "/lattice_regions_bar.stl").model;
  const int left = face_with_normal(model, -1, 0, 0), top = face_with_normal(model, 0, 0, 1),
            right = face_with_normal(model, 1, 0, 0);
  CHECK(left >= 0 && top >= 0 && right >= 0, "precondition: the bar's three faces");

  // ── §1 the parse ────────────────────────────────────────────────────────────
  {
    const JobDescription j = parse_job(job_json(left, right, top, kTopInclude + ", \"whole_part\": true"));
    CHECK(j.lattice.whole_part && j.lattice.regions.empty() &&
              j.lattice.whole_part_includes.size() == 1,
          "§1 whole_part: the include leaves `regions` for `whole_part_includes`");
    const JobDescription k = parse_job(job_json(left, right, top, kTopInclude));
    CHECK(!k.lattice.whole_part && k.lattice.regions.size() == 1,
          "§1 absent: the include stays a limiting region (control)");
    CHECK(refused_with(job_json(left, right, top, ", \"whole_part\": 1"),
                       "\"whole_part\" must be a boolean"),
          "§1 whole_part must be a boolean");
    std::string dens = kTopInclude;
    dens.insert(dens.find("\"geometry\""), "\"relative_density\": 0.3, ");
    CHECK(refused_with(job_json(left, right, top, dens + ", \"whole_part\": true"),
                       "states \"relative_density\"; it is refused rather than dropped"),
          "§1 whole_part: an include's own density is refused until E3, not dropped");
    std::string fit = job_json(left, right, top, kTopInclude + ", \"whole_part\": true",
                               ", \"cell_mode\": \"fit\"");
    fit.erase(fit.find("\"cell_mm\": 4.0, "), std::string("\"cell_mm\": 4.0, ").size());
    CHECK(refused_with(fit, "needs at least one lattice region"),
          "§1 whole_part with fit: no include is left to fit, refused");
  }

  // ── §2-§4 four runs ─────────────────────────────────────────────────────────
  auto latticed = [&](const std::string& tag, const std::string& extra) -> long long {
    const std::string out = dir + "/lattice_regions_" + tag;
    std::ofstream(dir + "/lattice_regions_job.json") << job_json(left, right, top, extra);
    try {
      const JobDescription job = load_job_file(dir + "/lattice_regions_job.json");
      (void)lattice_variant_job(job, dir, out, materials, rules);
    } catch (const std::exception& e) {
      std::printf("  (%s refused: %s)\n", tag.c_str(), e.what());
      return -1;
    }
    for (const auto& e : std::filesystem::directory_iterator(out)) {
      const std::string n = e.path().filename().string();
      if (n.size() > 20 && n.compare(n.size() - 20, 20, "_lattice.report.json") == 0) {
        const std::string r = read_file(e.path().string());
        const double v = num_after(r, "latticed_voxels", r.find("\"grading\""));
        return std::isfinite(v) ? static_cast<long long>(v) : -1;
      }
    }
    return -1;
  };
  const long long all = latticed("all", "");
  const long long inc = latticed("include", kTopInclude);
  const long long inc_whole = latticed("include_whole", kTopInclude + ", \"whole_part\": true");
  const long long exc = latticed("exclude", kTopExclude);
  const long long exc_whole = latticed("exclude_whole", kTopExclude + ", \"whole_part\": true");
  std::printf("[lattice-regions] latticed voxels: whole %lld | top include %lld, with whole_part "
              "%lld | top excluded %lld, with whole_part %lld\n",
              all, inc, inc_whole, exc, exc_whole);
  CHECK(all > 0 && inc > 0, "precondition: both lattices are laid");
  CHECK(inc < all / 2, "§2 control: today's rule, the top include limits the lattice to it");
  CHECK(inc_whole == all,
        "§3 whole_part: the include no longer limits it; the whole part, voxel for voxel");
  CHECK(exc > 0 && exc < all, "§4 No lattice on the top region keeps its prism solid");
  CHECK(exc_whole == exc, "§4 the same cut in the whole-part mode");

  // ── §5 two regions on one face ──────────────────────────────────────────────
  {
    auto rho_range = [&](const std::string& tag, const std::string& regions,
                         double* lo, double* hi) {
      const std::string out = dir + "/lattice_regions_" + tag;
      std::string j = job_json(left, right, top, ", \"regions\": [" + regions + "]",
                               ", \"cell_mode\": \"fit\"");
      j.erase(j.find("\"cell_mm\": 4.0, "), std::string("\"cell_mm\": 4.0, ").size());
      std::ofstream(dir + "/lattice_regions_job.json") << j;
      *lo = *hi = std::numeric_limits<double>::quiet_NaN();
      try {
        (void)lattice_variant_job(load_job_file(dir + "/lattice_regions_job.json"), dir, out,
                                  materials, rules);
      } catch (const std::exception& e) {
        std::printf("  (%s refused: %s)\n", tag.c_str(), e.what());
        return;
      }
      for (const auto& e : std::filesystem::directory_iterator(out)) {
        const std::string n = e.path().filename().string();
        if (n.size() > 20 && n.compare(n.size() - 20, 20, "_lattice.report.json") == 0) {
          const std::string r = read_file(e.path().string());
          *lo = num_after(r, "rho_min_used", r.find("\"grading\""));
          *hi = num_after(r, "rho_max_used", r.find("\"grading\""));
        }
      }
    };
    const std::string shallow = top_prism(top, 10.0, 0.75), deep = top_prism(top, 16.0, 0.88);
    double a_lo, a_hi, b_lo, b_hi, c_lo, c_hi;
    rho_range("two_shallow_first", shallow + ", " + deep, &a_lo, &a_hi);
    rho_range("two_deep_first", deep + ", " + shallow, &b_lo, &b_hi);
    rho_range("shallow_alone", shallow, &c_lo, &c_hi);
    std::printf("[lattice-regions] two on one face: shallow first %.4f-%.4f, deep first "
                "%.4f-%.4f; the shallow one alone %.4f-%.4f\n",
                a_lo, a_hi, b_lo, b_hi, c_lo, c_hi);
    CHECK(std::fabs(c_lo - 0.75) < 1e-9 && std::fabs(c_hi - 0.75) < 1e-9,
          "§5 control: the 10 mm region alone is laid at its own 0.75");
    CHECK(std::fabs(a_lo - 0.88) < 1e-9 && std::fabs(a_hi - 0.88) < 1e-9,
          "§5 shallow declared first: the deeper region owns the overlap (0.88 throughout)");
    CHECK(a_lo == b_lo && a_hi == b_hi, "§5 the declaration order does not matter");
  }

  // ── §6 the depth tie on a protected face ────────────────────────────────────
  {
    const std::string prot16 = ", \"face_protections\": [{\"face_id\": " +
                               std::to_string(top) + ", \"depth_mm\": 16}]";
    const std::string prot12 = ", \"face_protections\": [{\"face_id\": " +
                               std::to_string(top) + ", \"depth_mm\": 12}]";
    const std::string two = ", \"regions\": [" + top_prism(top, 10.0, 0.0) + ", " +
                            top_prism(top, 16.0, 0.0) + "]";
    bool parsed = true;
    try {
      (void)parse_job(job_json(left, right, top, two, "", prot16));
    } catch (const JobError& e) {
      parsed = false;
      std::printf("  (refused: %s)\n", e.what());
    }
    CHECK(parsed, "§6 10 + 16 mm regions on a face protected 16 mm: the deepest matches, parses");
    CHECK(refused_with(job_json(left, right, top,
                                ", \"regions\": [" + top_prism(top, 10.0, 0.0) + "]", "", prot16),
                       "at two different depths"),
          "§6 control: one 10 mm region on a face protected 16 mm is still refused");
    CHECK(refused_with(job_json(left, right, top, two, "", prot12), "at two different depths"),
          "§6 10 + 16 mm on a face protected 12 mm: the deepest does not match, refused");
  }

  std::printf("%s: %d checks, %d failures\n", g_failures ? "FAIL" : "PASS", g_checks,
              g_failures);
  return g_failures ? 1 : 0;
}
