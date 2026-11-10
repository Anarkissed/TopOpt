// Ruling 11-08 (B): a strength law for each of the other eight types, measured the PR 259
// way (tests/harness/lattice_dehomog_probe.cpp, TOPOPT_DEHOMOG_TYPE) and certified from
// its OWN table, never octet's.
//
// The bar is latticed through ("Lattice the original part", skin none), so no solid voxel
// carries the load and ruling 11-06 2(a) certifies the lattice from its strut law alone.
// Before (B) every type but octet read "Not certified: ... has no measured strut-strength
// law". 11 cells across, so no type sits under its cells-per-member floor.
//
// §1 each of the eight: the receipt is written, the strut law is in the gate, the margin
//    is finite, and it never says it has no law.
// §2 each law is its own: measured, and not octet's numbers; and it is its evidence,
//    TRANSCRIBED: every row of evidence/2026-11-09-lattice-type-strut-laws/<type>/kfit.csv's
//    *_cert columns is reproduced exactly at its anchor, and the law spans exactly the
//    first and last row. A silent table edit (or a re-run not carried into the table)
//    breaks here.
// §3 octet is unchanged: gated by PR 259's table, as before.
//
// ★ §1 AND §3's LATTICE RUNS ARE LONG (about 2.4 h on the honest 44 mm bar) and run only when
// TOPOPT_LONG_TESTS=1: in full on every change to a type's law, and on the daily full suite;
// the push that changes a law names that full pass (its SHA, 9/9 types). §2 runs every time.
// TOPOPT_STRUT_LAW_TYPES (a comma list) runs only those types: one process per type, side by
// side, takes the full pass from about 2.4 h to its slowest type.
#include "topopt/job.hpp"
#include "topopt/loadcase.hpp"
#include "topopt/materials.hpp"
#include "topopt/observability.hpp"
#include "topopt/part.hpp"
#include "topopt/settings.hpp"
#include "topopt/stl.hpp"
#include "topopt/strut_strength.hpp"

#include <cctype>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <unistd.h>
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

// A 60 x 44 x 44 mm bar: 11 cells of 4 mm across, over every type's cells-per-member
// floor (the largest is 10).
TriangleMesh bar() {
  TriangleMesh m;
  const double L = 60.0, W = 44.0, H = 44.0;
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

// test_lattice_scenarios' bar and scenarios: "light down" 30 N on the top, "heavy side"
// 300 N in +y on the free end, both anchored at x = 0. Growth off (lattice_part).
std::string job_json(const Faces& f, const std::string& mode, const std::string& topology,
                     const std::string& lattice_extra, const std::string& grading_extra) {
  const std::string anchor = "[" + std::to_string(f.left) + "]";
  const std::string light = "{\"name\": \"light down\", \"groups\": [{\"face_ids\": [" +
                            std::to_string(f.top) + "], \"force\": [0, 0, -30]}], "
                            "\"anchor_face_ids\": " + anchor + "}";
  const std::string heavy = "{\"name\": \"heavy side\", \"groups\": [{\"face_ids\": [" +
                            std::to_string(f.right) + "], \"force\": [0, 300, 0]}], "
                            "\"anchor_face_ids\": " + anchor + "}";
  // ★ ITS OWN BAR (found by the SOLID slice's gate, 11-10): this named
  // "lattice_no_solid_bar.stl", test_lattice_no_solid's 20 mm bar left in the shared build
  // folder, so it latticed that bar and not the 44 mm one below. The 20 mm bar held every
  // type's floor only because the grid's outside read as material (finding 4); read
  // honestly it is 20 mm, under most types' floors at a 4 mm cell, and the run refuses.
  return "{\"model\": \"type_strut_law_bar.stl\", \"material\": \"PLA\", \"mode\": \"" +
         mode + "\", \"resolution\": 24, "
         "\"loads\": {\"minimize_plastic\": true, \"build_dir\": [0, 0, 1], "
         "\"anchor_face_ids\": " + anchor + ", \"groups\": [{\"face_ids\": [" +
         std::to_string(f.top) + "], \"force\": [0, 0, -30]}], \"scenarios\": [" + light +
         ", " + heavy + "]}, "
         "\"lattice\": {\"topology\": \"" + topology + "\"" + lattice_extra + "}, "
         "\"grading\": {\"topology\": \"" + topology + "\", \"cell_mm\": 4.0, "
         "\"min_extrudable_width_mm\": 0.45" + grading_extra + "}, "
         "\"output\": {\"report\": \"report.json\", \"mesh_format\": \"stl\", "
         "\"mesh_prefix\": \"variant\"}}";
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

bool has(const std::string& s, const std::string& what) { return s.find(what) != std::string::npos; }

// The kfit.csv *_cert rows: {rho_lib, Kd_cert, Kv_cert, Kild_cert, Kilv_cert} per row, parsed
// from the same decimal strings the table carries (so an exact copy compares equal).
std::vector<std::vector<double>> kfit_cert_rows(const std::string& path) {
  std::vector<std::vector<double>> out;
  std::ifstream in(path);
  std::string line;
  if (!std::getline(in, line)) return out;
  std::vector<std::string> head;
  {
    std::stringstream hs(line);
    std::string c;
    while (std::getline(hs, c, ',')) head.push_back(c);
  }
  const char* want[] = {"rho_lib", "Kd_cert", "Kv_cert", "Kild_cert", "Kilv_cert"};
  std::vector<int> col;
  for (const char* w : want)
    for (std::size_t i = 0; i < head.size(); ++i)
      if (head[i] == w) col.push_back(static_cast<int>(i));
  if (col.size() != 5) return out;
  while (std::getline(in, line)) {
    if (line.empty()) continue;
    std::vector<std::string> cells;
    std::stringstream ls(line);
    std::string c;
    while (std::getline(ls, c, ',')) cells.push_back(c);
    std::vector<double> row;
    for (int k : col)
      row.push_back(k < static_cast<int>(cells.size()) ? std::strtod(cells[k].c_str(), nullptr)
                                                       : std::numeric_limits<double>::quiet_NaN());
    out.push_back(row);
  }
  return out;
}

// The lattice margin per_scenario lists for `name`.
double scenario_margin(const std::string& receipt, const std::string& name) {
  const std::size_t k = receipt.find("{\"name\": \"" + name + "\", \"lattice_margin\"");
  return k == std::string::npos ? std::numeric_limits<double>::quiet_NaN()
                                : num_after(receipt, "lattice_margin", k);
}

// Every bare word outside a string that JSON does not allow (inf, nan, ...).
std::string bare_words(const std::string& s) {
  std::string bad;
  bool in_str = false;
  for (std::size_t i = 0; i < s.size(); ++i) {
    const char c = s[i];
    if (in_str) {
      if (c == '\\') ++i;
      else if (c == '"') in_str = false;
      continue;
    }
    if (c == '"') { in_str = true; continue; }
    if (!std::isalpha(static_cast<unsigned char>(c))) continue;
    std::size_t j = i;
    while (j < s.size() && std::isalpha(static_cast<unsigned char>(s[j]))) ++j;
    const std::string w = s.substr(i, j - i);
    // An exponent's 'e' sits between digits ("1e-05").
    const bool exponent = (w == "e" || w == "E") && i > 0 &&
                          std::isdigit(static_cast<unsigned char>(s[i - 1]));
    if (w != "true" && w != "false" && w != "null" && !exponent) bad += w + " ";
    i = j - 1;
  }
  return bad;
}

// lattice_part on the bar. Returns the receipt ("" when none).
struct Lp { std::string receipt, refused; };
Lp lattice_part(const std::string& dir, const Faces& f, const std::string& topology) {
  Lp out;
  const std::string folder = dir + "/type_strut_law_" + topology;
  std::filesystem::remove_all(folder);
  const std::string j = job_json(
      f, "lattice_part", topology,
      ", \"skin\": \"none\", \"require_lattice_void_reaches_exterior\": false", "");
  std::ofstream(dir + "/type_strut_law_" + topology + ".json") << j;
  try {
    const MaterialLibrary materials = load_materials_file(MATERIALS_JSON_PATH);
    const SettingsRules rules = load_settings_rules_file(SETTINGS_RULES_PATH);
    const JobDescription job = load_job_file(dir + "/type_strut_law_" + topology + ".json");
    (void)lattice_variant_job(job, dir, folder, materials, rules);
  } catch (const std::exception& e) {
    out.refused = e.what();
    std::printf("  (%s refused: %s)\n", topology.c_str(), e.what());
  }
  if (std::filesystem::exists(folder))
    for (const auto& e : std::filesystem::directory_iterator(folder)) {
      const std::string n = e.path().filename().string();
      if (n.size() > 20 && n.compare(n.size() - 20, 20, "_lattice.report.json") == 0)
        out.receipt = read_file(e.path().string());
    }
  return out;
}

}  // namespace

int main() {
  const std::string dir = TMP_DIR;
  {  // written under a private name and renamed into place, so runs side by side (one type
     // each, TOPOPT_STRUT_LAW_TYPES below) never read a half-written bar
    const std::string mine = dir + "/type_strut_law_bar." + std::to_string(::getpid()) + ".stl";
    write_stl_file(mine, bar(), StlFormat::Binary);
    std::filesystem::rename(mine, dir + "/type_strut_law_bar.stl");
  }
  const StepModel model = import_part(dir + "/type_strut_law_bar.stl").model;
  Faces f;
  f.left = face_with_normal(model, -1, 0, 0);
  f.top = face_with_normal(model, 0, 0, 1);
  f.right = face_with_normal(model, 1, 0, 0);
  CHECK(f.left >= 0 && f.top >= 0 && f.right >= 0, "precondition: the bar's three faces");

  // ★ §1's NINE LATTICE RUNS ARE THE LONG HALF (option (b), the reviewer's call 11-10): on
  // the honest 44 mm bar -- the largest type floor is 10 cells, so every side must hold 10
  // -- they take about 2.4 h (measured: the first 3 types in 48 min). They run when
  // TOPOPT_LONG_TESTS=1: in full on every change to a type's law and on the daily full
  // suite. §2 (each law transcribed from its own evidence) runs every time, in seconds.
  const char* long_env = std::getenv("TOPOPT_LONG_TESTS");
  const bool long_runs = long_env != nullptr && std::string(long_env) == "1";
  if (!long_runs)
    std::printf("[type law] §1/§3's lattice runs skipped: set TOPOPT_LONG_TESTS=1 (about 2.4 h)\n");
  const char* types[] = {"sc", "bcc", "fcc", "diamond", "kelvin", "rhombic", "gyroid",
                         "schwarz_d", "octet"};
  // TOPOPT_STRUT_LAW_TYPES=bcc,kelvin runs only those types, so the long half can run one
  // type per process side by side (each type's job and output folder are its own).
  const char* only_env = std::getenv("TOPOPT_STRUT_LAW_TYPES");
  const std::string only = only_env != nullptr ? "," + std::string(only_env) + "," : "";
  for (const char* t : types) {
    const std::string id = t;
    if (!only.empty() && only.find("," + id + ",") == std::string::npos) continue;
    if (long_runs) {
    const Lp r = lattice_part(dir, f, id);
    const std::string& rc = r.receipt;
    const double m = num_after(rc, "lattice_margin_effective");
    const std::size_t w = rc.find("\"lattice_not_certified_reason\": ");
    std::printf("[type law] %-9s: lattice_voxels %.0f, margin %.4f, gated %s, accepted %s%s%s\n",
                t, num_after(rc, "lattice_voxels"), m,
                has(rc, "\"gated\": true") ? "true" : "false",
                has(rc, "\"lattice_accepted\": true") ? "true" : "false",
                w == std::string::npos ? "" : " -- ",
                w == std::string::npos ? "" : rc.substr(w + 32, 200).c_str());
    const std::string sec = id == "octet" ? "§3 " : "§1 ";
    CHECK(!rc.empty(), (sec + id + ": the receipt is written").c_str());
    CHECK(!has(rc, "no measured strut-strength law"),
          (sec + id + ": it does not say it has no strut law").c_str());
    CHECK(has(rc, "\"gated\": true") && has(rc, "\"strut_strength_uncertified\": false"),
          (sec + id + ": its strut law is in the gate").c_str());
    CHECK(std::isfinite(m), (sec + id + ": its lattice margin is finite").c_str());
    }

    const LatticeTopology topo = lattice_topology_from_id(id);
    const std::string sec = id == "octet" ? "§3 " : "§1 ";
    CHECK(strut_law_measured(topo), (sec + id + ": the type has a measured strut law").c_str());
    if (id != "octet" && strut_law_measured(topo)) {
      const double mid = 0.5 * (strut_law_rho_min(topo) + strut_law_rho_max(topo));
      const StrutLawK own = strut_law_at(topo, mid), oct = strut_law_at(mid);
      std::printf("           law at rho %.3f: Kd %.2f Kv %.2f (octet's %.2f %.2f)\n", mid,
                  own.Kd, own.Kv, oct.Kd, oct.Kv);
      CHECK(own.Kd != oct.Kd || own.Kv != oct.Kv,
            ("§2 " + id + ": its law is its own, not octet's").c_str());

      const auto rows = kfit_cert_rows(std::string(LAW_EVIDENCE_DIR) + "/" + id + "/kfit.csv");
      bool exact = !rows.empty();
      for (const auto& row : rows) {
        bool cl = true;
        const StrutLawK k = strut_law_at(topo, row[0], &cl);
        if (cl || k.Kd != row[1] || k.Kv != row[2] || k.Kild != row[3] || k.Kilv != row[4]) {
          exact = false;
          std::printf("           row rho %.5f: table Kd %.4f Kv %.4f Kild %.4f Kilv %.4f, "
                      "kfit %.4f %.4f %.4f %.4f\n", row[0], k.Kd, k.Kv, k.Kild, k.Kilv,
                      row[1], row[2], row[3], row[4]);
        }
      }
      std::printf("           kfit.csv: %zu rows, %s\n", rows.size(),
                  exact ? "every row reproduced exactly" : "NOT reproduced");
      CHECK(exact, ("§2 " + id + ": its table is its kfit.csv's *_cert rows, exactly").c_str());
      CHECK(!rows.empty() && strut_law_rho_min(topo) == rows.front()[0] &&
                strut_law_rho_max(topo) == rows.back()[0],
            ("§2 " + id + ": its law spans exactly the measured rows").c_str());
    }
  }
  std::printf("%s: %d checks, %d failures\n", g_failures ? "FAIL" : "PASS", g_checks, g_failures);
  return g_failures ? 1 : 0;
}
