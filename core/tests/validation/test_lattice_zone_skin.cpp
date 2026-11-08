// Skin per zone (reviewer's ruling 11-08 (1) + (2b)): lattice.regions[].skin.
//
// "diagrid" is Skin: the freeform diagrid woven over the zone's own surface, a chord laid
// where its midpoint lies in the zone and an anchor ball where its landing does. "none"
// lays no skin in the zone. Absent, the zone takes the part's lattice.skin. "rim" is
// refused by the zone's name: today's rim is laid only where two flat CAD faces meet, and a
// run's lattice surface has none (M4), so it would come out empty.
//
// §1 the key at the parse: "diagrid" and "none" parse; "rim" is refused in plain words
//    with the zone's name; an unknown value lists the two; a sheet's zone cannot ask for
//    the diagrid (R8, by name); organic lays no cell skin, so its zones cannot ask for one;
//    an exclude region has no lattice to dress.
// §2 the whole bar latticed covered with no skin, "Top" (the top right 10 mm) with Skin:
//    the woven skin lands in Top and nowhere else, and the receipt says so per zone.
// §3 the converse: the whole bar woven (shell+skin), "Top" with none: Top lays nothing,
//    the rest is still woven, and fewer chords than the whole bar woven.
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

struct Faces { int left = -1, top = -1, bottom = -1; };

// Anchored at x = 0, 30 N down on the bottom face. Growth off.
std::string job_json(const Faces& f, const std::string& topology, const std::string& lattice_extra,
                     const std::string& grading_extra = "") {
  return "{\"model\": \"lattice_zone_skin_bar.stl\", \"material\": \"PLA\", \"mode\": "
         "\"lattice_part\", \"resolution\": 24, "
         "\"loads\": {\"minimize_plastic\": true, \"build_dir\": [0, 0, 1], "
         "\"anchor_face_ids\": [" + std::to_string(f.left) + "], \"groups\": [{\"face_ids\": [" +
         std::to_string(f.bottom) + "], \"force\": [0, 0, -30]}]}, "
         "\"lattice\": {\"topology\": \"" + topology + "\", "
         "\"require_lattice_void_reaches_exterior\": false" + lattice_extra + "}, "
         "\"grading\": {\"topology\": \"" + topology + "\", \"cell_mm\": 4.0, "
         "\"min_extrudable_width_mm\": 0.45, \"intent\": \"structural\"" + grading_extra + "}, "
         "\"output\": {\"report\": \"report.json\", \"mesh_format\": \"stl\", "
         "\"mesh_prefix\": \"variant\"}}";
}

// The whole part latticed at the part's skin and finish, with "Top" (the top right 10 mm)
// stating `zone_extra` (e.g. ", \"skin\": \"diagrid\"").
std::string zoned(const Faces& f, const std::string& part, const std::string& zone_extra,
                  const std::string& role = "include") {
  char b[700];
  std::snprintf(b, sizeof b,
                "%s, \"whole_part\": true, \"regions\": [{\"role\": \"%s\", \"kind\": \"face\", "
                "\"face_id\": %d, \"label\": \"Top\"%s, \"geometry\": {\"origin\": [45, 10, 20], "
                "\"normal\": [0, 0, -1], \"half_u_mm\": 15, \"half_w_mm\": 10, \"depth_mm\": 10}}]",
                part.c_str(), role.c_str(), f.top, zone_extra.c_str());
  return b;
}

std::string refusal(const std::string& json) {
  try {
    (void)parse_job(json);
  } catch (const JobError& e) {
    return e.what();
  }
  return "";
}
bool has(const std::string& s, const std::string& w) { return s.find(w) != std::string::npos; }
bool refused_with(const std::string& json, const std::vector<std::string>& words) {
  const std::string why = refusal(json);
  bool ok = !why.empty();
  for (const std::string& w : words) ok = ok && has(why, w);
  if (!ok) std::printf("  (%s)\n", why.empty() ? "not refused" : why.c_str());
  return ok;
}

std::string read_file(const std::string& p) {
  std::ifstream in(p, std::ios::binary);
  std::stringstream ss;
  ss << in.rdbuf();
  return ss.str();
}

double num_after(const std::string& s, const std::string& key, std::size_t from = 0) {
  if (from == std::string::npos) return std::numeric_limits<double>::quiet_NaN();
  const std::size_t k = s.find("\"" + key + "\": ", from);
  if (k == std::string::npos) return std::numeric_limits<double>::quiet_NaN();
  const std::size_t v = k + key.size() + 4;
  if (s.compare(v, 4, "null") == 0) return std::numeric_limits<double>::quiet_NaN();
  return std::strtod(s.c_str() + v, nullptr);
}

struct Run { std::string receipt; std::string refused; };
Run lattice_part(const std::string& dir, const std::string& tag, const std::string& json) {
  Run out;
  const std::string folder = dir + "/lattice_zone_skin_" + tag;
  std::filesystem::remove_all(folder);
  std::ofstream(dir + "/lattice_zone_skin_" + tag + ".json") << json;
  try {
    const MaterialLibrary materials = load_materials_file(MATERIALS_JSON_PATH);
    const SettingsRules rules = load_settings_rules_file(SETTINGS_RULES_PATH);
    const JobDescription job = load_job_file(dir + "/lattice_zone_skin_" + tag + ".json");
    (void)lattice_variant_job(job, dir, folder, materials, rules);
  } catch (const std::exception& e) {
    out.refused = e.what();
    std::printf("  (%s refused: %s)\n", tag.c_str(), e.what());
  }
  if (std::filesystem::exists(folder))
    for (const auto& e : std::filesystem::directory_iterator(folder)) {
      const std::string n = e.path().filename().string();
      if (n.size() > 20 && n.compare(n.size() - 20, 20, "_lattice.report.json") == 0)
        out.receipt = read_file(e.path().string());
    }
  return out;
}

// The receipt's row for the region labelled "Top".
std::size_t top_row(const std::string& receipt) {
  const std::size_t regs = receipt.find("\"lattice_regions\": [");
  if (regs == std::string::npos) return std::string::npos;
  return receipt.find("\"label\": \"Top\"", regs);
}

}  // namespace

int main() {
  const std::string dir = TMP_DIR;
  write_stl_file(dir + "/lattice_zone_skin_bar.stl", bar(), StlFormat::Binary);
  const StepModel model = import_part(dir + "/lattice_zone_skin_bar.stl").model;
  Faces f;
  f.left = face_with_normal(model, -1, 0, 0);
  f.top = face_with_normal(model, 0, 0, 1);
  f.bottom = face_with_normal(model, 0, 0, -1);
  CHECK(f.left >= 0 && f.top >= 0 && f.bottom >= 0, "precondition: the bar's three faces");

  // ── §1 the key at the parse ─────────────────────────────────────────────────
  {
    const std::string none_part = ", \"skin\": \"none\"";
    for (const char* skin : {"diagrid", "none"}) {
      std::string why;
      try {
        const JobDescription j = parse_job(
            job_json(f, "octet", zoned(f, none_part, std::string(", \"skin\": \"") + skin + "\"")));
        CHECK(j.lattice.whole_part_includes.size() == 1 &&
                  j.lattice.whole_part_includes[0].skin == skin,
              (std::string("§1 a zone's skin \"") + skin + "\" parses").c_str());
      } catch (const JobError& e) {
        std::printf("  (%s)\n", e.what());
        CHECK(false, (std::string("§1 a zone's skin \"") + skin + "\" parses").c_str());
      }
    }
    CHECK(refused_with(job_json(f, "octet", zoned(f, none_part, ", \"skin\": \"rim\"")),
                       {"\"Top\"", "Rim", "two flat", "Skin"}),
          "§1 Rim on a zone is refused in plain words, with the zone's name");
    CHECK(refused_with(job_json(f, "octet", zoned(f, none_part, ", \"skin\": \"woven\"")),
                       {"\"Top\"", "\"diagrid\"", "\"none\""}),
          "§1 an unknown value is refused, listing the two");
    CHECK(refused_with(job_json(f, "gyroid", zoned(f, none_part, ", \"skin\": \"diagrid\"")),
                       {"\"Top\"", "sheet", "R8"}),
          "§1 a sheet's zone cannot ask for the diagrid (R8, by name)");
    CHECK(refused_with(job_json(f, "octet", zoned(f, none_part, ", \"skin\": \"diagrid\""),
                                ", \"algorithm\": \"organic\", "
                                "\"organic_structural_certification\": \"beam_network\""),
                       {"\"Top\"", "organic"}),
          "§1 organic lays no cell skin: its zones cannot ask for one");
    CHECK(refused_with(job_json(f, "octet",
                                ", \"skin\": \"none\", \"regions\": [{\"role\": \"exclude\", "
                                "\"kind\": \"face\", \"face_id\": " + std::to_string(f.top) +
                                ", \"label\": \"Top\", \"skin\": \"diagrid\", \"geometry\": "
                                "{\"origin\": [45, 10, 20], \"normal\": [0, 0, -1], "
                                "\"half_u_mm\": 15, \"half_w_mm\": 10, \"depth_mm\": 10}}]"),
                       {"\"skin\"", "exclude"}),
          "§1 an exclude region has no lattice to dress");
  }

  // ── §2 Skin on Top only ─────────────────────────────────────────────────────
  const Run woven = lattice_part(dir, "woven",
                                 job_json(f, "octet", ", \"skin\": \"diagrid\", \"outer_finish\": "
                                                      "\"shell+skin\", \"whole_part\": true"));
  const double woven_struts = num_after(woven.receipt, "skin_struts");
  const double woven_chords = num_after(woven.receipt, "skin_chords");
  {
    const Run r = lattice_part(dir, "top_skin",
                               job_json(f, "octet", zoned(f, ", \"skin\": \"none\"",
                                                          ", \"skin\": \"diagrid\"")));
    const std::size_t row = top_row(r.receipt);
    const double total = num_after(r.receipt, "skin_struts");
    const double in_top = num_after(r.receipt, "skin_struts", row);
    const double outside = num_after(r.receipt, "skin_struts", r.receipt.find("\"skin_outside_zones\""));
    std::printf("[zone skin] whole bar woven: %.0f skin struts, %.0f chords; Top woven only: "
                "%.0f in all, %.0f in Top, %.0f outside the zones\n",
                woven_struts, woven_chords, total, in_top, outside);
    CHECK(!woven.receipt.empty() && woven_struts > 0, "§2 control: the whole bar woven lays skin");
    CHECK(!r.receipt.empty(), "§2 the run writes its receipt");
    CHECK(row != std::string::npos && has(r.receipt.substr(row, 2000), "\"skin\": \"diagrid\""),
          "§2 Top's row says its skin is the diagrid");
    CHECK(in_top > 0 && total == in_top, "§2 the woven skin lands in Top and nowhere else");
    CHECK(outside == 0, "§2 the receipt counts nothing outside the zones");
    CHECK(total < woven_struts, "§2 fewer skin struts than the whole bar woven");
    CHECK(num_after(r.receipt, "skin_chords", row) > 0, "§2 Top's chords are counted");
  }

  // ── §3 the whole bar woven, Top with none ──────────────────────────────────
  {
    const Run r = lattice_part(dir, "top_none",
                               job_json(f, "octet", zoned(f, ", \"skin\": \"diagrid\", "
                                                             "\"outer_finish\": \"shell+skin\"",
                                                          ", \"skin\": \"none\"")));
    const std::size_t row = top_row(r.receipt);
    const double total = num_after(r.receipt, "skin_struts");
    const double chords = num_after(r.receipt, "skin_chords");
    std::printf("[zone skin] woven but Top none: %.0f skin struts (%.0f chords); Top: %.0f "
                "struts, %.0f anchor balls\n",
                total, chords, num_after(r.receipt, "skin_struts", row),
                num_after(r.receipt, "anchor_nodes", row));
    CHECK(row != std::string::npos && has(r.receipt.substr(row, 2000), "\"skin\": \"none\""),
          "§3 Top's row says it has no skin");
    CHECK(num_after(r.receipt, "skin_struts", row) == 0 &&
              num_after(r.receipt, "anchor_nodes", row) == 0,
          "§3 Top lays no skin strut and no anchor ball");
    CHECK(total > 0 && chords < woven_chords, "§3 the rest is woven, with fewer chords");
  }

  std::printf("%s: %d checks, %d failures\n", g_failures ? "FAIL" : "PASS", g_checks,
              g_failures);
  return g_failures ? 1 : 0;
}
