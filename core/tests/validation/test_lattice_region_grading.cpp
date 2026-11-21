// E3 (plan.md §B7): an include region's own grading, on one 60 x 20 x 20 mm bar latticed
// as the part (lattice_part, growth off) in the "- Lattice faces" mode, with one 10 mm
// region on the top face carrying the setting under test. Every number is read from the
// receipt's lattice_regions (the grading law's own range for the region's voxels).
//
// §1 the parse: the band both or neither, inside the type's band, not with a stated
//    density; nothing of this on an exclude; the grading mode's words; the shape grade
//    may not contradict the mode; the label.
// §2 the band: the region's densities lie in [0.5, 0.7]; the part's elsewhere.
// §3 "off": one density, the region's graded peak (its "stress" grade's maximum).
// §4 the demand exponent: 3 grades the region lighter than the part's curve.
// §5 the shape grade on the region alone: a graded band (ruling 2; it was a solid beam).
// §6 control: "stress" names the part's own grading, so the file is byte for byte the
//    file of the same region with no grading of its own.
// §7 ruling 11-06: "off" with no density searches for the LIGHTEST one density that
//    certifies, its graded peak the upper bound. Here (the whole part latticed) even the
//    peak does not certify, so §3's peak stands and the receipt says why, by label. On
//    the region alone over the solid bar (no whole_part), the solid carries the load:
//    the search goes below the peak, certified, and the part is lighter for it.
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
  return "{\"model\": \"lattice_grading_bar.stl\", \"material\": \"PLA\", "
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

// The top-face region with `extra` keys (a JSON fragment ending in ", " or empty).
std::string top_region(int top, const std::string& extra) {
  return "{\"role\": \"include\", \"kind\": \"face\", \"face_id\": " + std::to_string(top) +
         ", \"label\": \"Top\", " + extra +
         "\"geometry\": {\"origin\": [30, 10, 20], \"normal\": [0, 0, -1], "
         "\"half_u_mm\": 30, \"half_w_mm\": 10, \"depth_mm\": 10}}";
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

// The number after `"key": ` at or after `from` (NaN when absent or null).
double num_after(const std::string& s, const std::string& key, std::size_t from = 0) {
  const std::size_t k = s.find("\"" + key + "\": ", from);
  if (k == std::string::npos) return std::numeric_limits<double>::quiet_NaN();
  const std::size_t v = k + key.size() + 4;
  if (s.compare(v, 4, "null") == 0) return std::numeric_limits<double>::quiet_NaN();
  return std::strtod(s.c_str() + v, nullptr);
}


struct Region { long long voxels = -1; double lo = 0, hi = 0; double mass = 0; std::string stl, receipt; };

}  // namespace

int main() {
  const MaterialLibrary materials = load_materials_file(MATERIALS_JSON_PATH);
  const SettingsRules rules = load_settings_rules_file(SETTINGS_RULES_PATH);
  const std::string dir = TMP_DIR;
  write_stl_file(dir + "/lattice_grading_bar.stl", bar(), StlFormat::Binary);
  const StepModel model = import_part(dir + "/lattice_grading_bar.stl").model;
  const int left = face_with_normal(model, -1, 0, 0), top = face_with_normal(model, 0, 0, 1),
            right = face_with_normal(model, 1, 0, 0);
  CHECK(left >= 0 && top >= 0 && right >= 0, "precondition: the bar's three faces");
  auto job_with = [&](const std::string& extra, const std::string& role = "include") {
    std::string r = top_region(top, extra);
    if (role != "include") r.replace(r.find("\"include\""), 9, "\"" + role + "\"");
    return job_json(left, right, top, ", \"whole_part\": true, \"regions\": [" + r + "]");
  };

  // ── §1 the parse ────────────────────────────────────────────────────────────
  {
    const JobDescription j = parse_job(job_with("\"rho_min\": 0.5, \"rho_max\": 0.7, "
                                                "\"grading\": \"shape\", "));
    const JobLatticeRegion& r = j.lattice.whole_part_includes.at(0);
    CHECK(r.label == "Top" && r.rho_min == 0.5 && r.rho_max == 0.7 && r.grading == "shape" &&
              r.shape_grade == 1,
          "§1 a region's band, mode and label parse; \"shape\" switches its shape grade on");
    CHECK(refused_with(job_with("\"rho_min\": 0.5, "), "come together"),
          "§1 the band is both ends or neither");
    CHECK(refused_with(job_with("\"rho_min\": 0.01, \"rho_max\": 0.5, "), "certifiable band"),
          "§1 a band leaving the type's certifiable band is refused, naming it");
    CHECK(refused_with(job_with("\"relative_density\": 0.4, \"rho_min\": 0.3, \"rho_max\": 0.5, "),
                       "One density or one band"),
          "§1 a stated density and a band together are refused");
    CHECK(refused_with(job_with("\"demand_exponent\": 2, ", "exclude"),
                       "an exclude region is kept SOLID"),
          "§1 an exclude region has no grading of its own");
    CHECK(refused_with(job_with("\"grading\": \"smooth\", "), "\"grading\" must be"),
          "§1 the grading mode's words");
    CHECK(refused_with(job_with("\"grading\": \"stress\", \"shape_grade\": true, "),
                       "says the opposite"),
          "§1 the shape grade may not contradict the mode");
  }

  // ── §2-§6 runs ──────────────────────────────────────────────────────────────
  auto run = [&](const std::string& tag, const std::string& extra) {
    Region g;
    const std::string out = dir + "/lattice_grading_" + tag;
    std::ofstream(dir + "/lattice_grading_job.json") << job_with(extra);
    try {
      (void)lattice_variant_job(load_job_file(dir + "/lattice_grading_job.json"), dir, out,
                                materials, rules);
    } catch (const std::exception& e) {
      std::printf("  (%s refused: %s)\n", tag.c_str(), e.what());
      return g;
    }
    for (const auto& e : std::filesystem::directory_iterator(out)) {
      const std::string n = e.path().filename().string();
      if (n.size() > 20 && n.compare(n.size() - 20, 20, "_lattice.report.json") == 0) {
        const std::string r = read_file(e.path().string());
        g.receipt = r;
        g.mass = num_after(r, "lattice_mass_grams");
        const std::size_t lr = r.find("\"lattice_regions\"");
        if (lr != std::string::npos) {
          g.voxels = static_cast<long long>(num_after(r, "latticed_voxels", lr));
          g.lo = num_after(r, "rho_min_graded", lr);
          g.hi = num_after(r, "rho_max_graded", lr);
        }
      }
      if (n.size() > 12 && n.compare(n.size() - 12, 12, "_lattice.stl") == 0)
        g.stl = read_file(e.path().string());
    }
    std::printf("[lattice-grading] %-7s region %lld voxels, graded %.4f-%.4f; mass %.3f g\n",
                tag.c_str(), g.voxels, g.lo, g.hi, g.mass);
    return g;
  };
  const Region plain = run("plain", "");
  const Region stress = run("stress", "\"grading\": \"stress\", ");
  const Region band = run("band", "\"rho_min\": 0.5, \"rho_max\": 0.7, ");
  const Region off = run("off", "\"grading\": \"off\", ");
  const Region exp3 = run("exp3", "\"demand_exponent\": 3, ");
  const Region shape = run("shape", "\"shape_grade\": true, \"shape_grade_band_mm\": 6, ");
  CHECK(stress.voxels > 0, "precondition: the region is latticed");

  CHECK(band.lo >= 0.5 - 1e-12 && band.hi <= 0.7 + 1e-12,
        "§2 the band: every density of the region lies in [0.5, 0.7]");
  CHECK(band.mass > plain.mass, "§2 the band raises the region, so the part is heavier");
  CHECK(off.lo == off.hi && std::fabs(off.hi - stress.hi) < 1e-12,
        "§3 off: one density, the region's own graded peak");
  CHECK(exp3.hi < stress.hi && exp3.mass < plain.mass,
        "§4 exponent 3: the region grades lighter than the part's curve");
  CHECK(shape.voxels > 0 && shape.receipt.find("\"shape_band\": {") != std::string::npos,
        "§5 the shape grade on the region: its band grades the region (ruling 2)");
  CHECK(!plain.stl.empty() && plain.stl == stress.stl,
        "§6 control: \"stress\" is the part's own grading, byte for byte");

  // ── §7 "off" with no density: the search ───────────────────────────────────
  {
    const std::string offr = read_file(dir + "/lattice_grading_off/" +
                                       [&] {
                                         for (const auto& e : std::filesystem::directory_iterator(
                                                  dir + "/lattice_grading_off"))
                                           if (e.path().filename().string().find("_lattice.report.json") !=
                                               std::string::npos)
                                             return e.path().filename().string();
                                         return std::string();
                                       }());
    CHECK(offr.find("\"law_certified\": false, \"refusal\": \"Region \\\"Top\\\" (grading off, "
                    "one density): the lattice does not certify even with it at its graded "
                    "peak") != std::string::npos,
          "§7 whole part: the peak does not certify, said by label");
    // The region alone, over a solid bar.
    auto layer_run = [&](const std::string& tag, const std::string& extra) {
      const std::string out = dir + "/lattice_grading_" + tag;
      std::filesystem::remove_all(out);
      std::ofstream(dir + "/lattice_grading_job.json")
          << job_json(left, right, top, ", \"regions\": [" + top_region(top, extra) + "]");
      std::string r;
      try {
        (void)lattice_variant_job(load_job_file(dir + "/lattice_grading_job.json"), dir, out,
                                  materials, rules);
        for (const auto& e : std::filesystem::directory_iterator(out))
          if (e.path().filename().string().find("_lattice.report.json") != std::string::npos)
            r = read_file(e.path().string());
      } catch (const std::exception& e) {
        std::printf("  (%s refused: %s)\n", tag.c_str(), e.what());
      }
      return r;
    };
    const std::string peak = layer_run("layer_stress", "\"grading\": \"stress\", ");
    const std::string lite = layer_run("layer_off", "\"grading\": \"off\", ");
    const std::size_t od = lite.find("\"one_density\": {");
    const double rho = num_after(lite, "rho", od), up = num_after(lite, "upper_bound_graded_peak", od),
                 fl = num_after(lite, "printable_floor", od);
    std::printf("[lattice-grading] layer off: one density %.4f (floor %.4f, peak %.4f), mass "
                "%.3f g vs graded %.3f g\n", rho, fl, up, num_after(lite, "lattice_mass_grams"),
                num_after(peak, "lattice_mass_grams"));
    CHECK(od != std::string::npos && lite.find("\"law_certified\": true", od) != std::string::npos,
          "§7 layer: the search certified a one density");
    CHECK(rho >= fl - 1e-12 && rho < up, "§7 layer: lighter than its graded peak, printable");
    CHECK(num_after(lite, "rho_min_graded") == rho && num_after(lite, "rho_max_graded") == rho,
          "§7 layer: the region is laid at that one density");
    CHECK(lite.find("\"lattice_accepted\": true") != std::string::npos,
          "§7 layer: the run's own certificate accepts it");

    // The whole part latticed under 35 N (300 N in §2-§6). The law search bisects (its
    // printable floor reads under the stop), its answer is refused on what the file holds,
    // and the shipped search bisects on whole passes up to a density the run accepts.
    {
      const std::string out = dir + "/lattice_grading_off_light";
      std::filesystem::remove_all(out);
      std::string j = job_with("\"grading\": \"off\", ");
      const std::string heavy = "\"force\": [0, 300, 0]";
      j.replace(j.find(heavy), heavy.size(), "\"force\": [0, 35, 0]");
      std::ofstream(dir + "/lattice_grading_job.json") << j;
      std::string r;
      try {
        (void)lattice_variant_job(load_job_file(dir + "/lattice_grading_job.json"), dir, out,
                                  materials, rules);
        for (const auto& e : std::filesystem::directory_iterator(out))
          if (e.path().filename().string().find("_lattice.report.json") != std::string::npos)
            r = read_file(e.path().string());
      } catch (const std::exception& e) {
        std::printf("  (off_light refused: %s)\n", e.what());
      }
      const std::size_t o = r.find("\"one_density\": {");
      const double rr = num_after(r, "rho", o), uu = num_after(r, "upper_bound_graded_peak", o),
                   ff = num_after(r, "printable_floor", o), tt = num_after(r, "trials", o);
      std::printf("[lattice-grading] whole part, 35 N, off: one density %.4f (floor %.4f, peak "
                  "%.4f), %.0f trials\n", rr, ff, uu, tt);
      const double law = num_after(r, "law_search_rho", o), sp = num_after(r, "shipped_passes", o);
      std::printf("[lattice-grading]   law answer %.4f, %.0f shipped pass(es), accepted %s\n", law,
                  sp, r.find("\"lattice_accepted\": true") != std::string::npos ? "true" : "false");
      CHECK(o != std::string::npos && law > ff && tt >= 3,
            "§7 bisection: the law search lands strictly above the printable floor");
      CHECK(sp >= 1 && rr > law && rr < uu,
            "§7 bisection: the shipped search lands between the law answer and the peak");
      CHECK(r.find("\"lattice_accepted\": true") != std::string::npos,
            "§7 bisection: the run's own certificate (what ships) accepts it");
    }
  }

  std::printf("%s: %d checks, %d failures\n", g_failures ? "FAIL" : "PASS", g_checks,
              g_failures);
  return g_failures ? 1 : 0;
}
