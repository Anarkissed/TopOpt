// Ruling 2 (2026-11-06): the shape grade is a GRADED BAND, built by the run the way the
// preview draws it -- not a solid outline.
//
// Red first: before this, core had no strength key and its shape grade was a solid
// outline beam, so a part with the shape grade on at strength -1 and +1 could not differ
// (the key was refused; without it the files were one file).
//
// The bar (60 x 20 x 20 mm) latticed whole (lattice_part), swept 1.6-6.4 mm, octet, a
// 0.45 mm line, the shape grade on with an 8 mm band, 30 N down on the top. Each band
// voxel's cell, density and strut are read from the run's own dump
// (TOPOPT_SHAPE_BAND_DUMP) and held to the preview's law (LatticeOctreeBake):
//   cells   the coarsest ladder cell S from the finest printable f to 6.4 mm with
//           distance + S/2 >= band (S - f) / (6.4 - f): within ONE ladder level for
//           every band voxel (the plan keeps a cell coarser where its other voxels need it
//           to print, and finer where the 2:1 balance or the member ceiling says so);
//   struts  rho = max(rho0, min(q, rho0 + (q - rho0)(1 - t) share amount)), share 1 on the
//           finest cell and 0.35 on a coarser one, amount 2^s; then a whole number of
//           line widths: up where the band's top allows, else down to the last whole
//           one that is still at least the law's own density; where neither is, the strut
//           keeps its raise and is counted (the band never thins a strut below its law).
// §1 the keys at the parse.
// §2 strength -1 against +1: different files, both certified; +1 lattices more of the
//    band (a stronger raise prints finer cells), so less of it stays solid.
// §3 the cells follow the preview's curve, within one level (and mostly exactly).
// §4 the struts: the preview's raise, then a whole number of line widths; never below
//    the law's own density (red on ac70b9b6: 260 / 264 band struts were snapped
//    DOWN, as far as 0.276 under the law).
// §5 the band is solid only where nothing prints, and the receipt says how much and where.
#include "topopt/job.hpp"
#include "topopt/lattice.hpp"
#include "topopt/materials.hpp"
#include "topopt/part.hpp"
#include "topopt/settings.hpp"
#include "topopt/stl.hpp"

#include <cmath>
#include <cstdio>
#include <cstdlib>
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

constexpr double kLine = 0.45, kCellMax = 6.4;

std::string job_json(int left, int top, const std::string& grading_extra) {
  return "{\"model\": \"lattice_band_bar.stl\", \"material\": \"PLA\", \"mode\": "
         "\"lattice_part\", \"resolution\": 48, "
         "\"loads\": {\"minimize_plastic\": true, \"build_dir\": [0, 0, 1], "
         "\"anchor_face_ids\": [" + std::to_string(left) + "], \"groups\": [{\"face_ids\": [" +
         std::to_string(top) + "], \"force\": [0, 0, -30]}]}, "
         "\"lattice\": {\"topology\": \"octet\", \"skin\": \"none\", "
         "\"require_lattice_void_reaches_exterior\": false}, "
         "\"grading\": {\"topology\": \"octet\", \"cell_mode\": \"swept\", \"cell_min_mm\": 1.6, "
         "\"cell_max_mm\": 6.4, \"min_extrudable_width_mm\": 0.45" + grading_extra + "}, "
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
  std::ifstream in(p, std::ios::binary);
  std::stringstream ss;
  ss << in.rdbuf();
  return ss.str();
}

double num_after(const std::string& s, const std::string& key, std::size_t from = 0) {
  const std::size_t k = s.find("\"" + key + "\": ", from);
  if (k == std::string::npos) return std::numeric_limits<double>::quiet_NaN();
  return std::strtod(s.c_str() + k + key.size() + 4, nullptr);
}

struct Row { double d, b, a, S, rho, strut, rho0, f; };
struct Run { std::string receipt, run_info, stl; std::vector<Row> rows; };

Run run(const std::string& dir, const std::string& tag, const std::string& json) {
  Run R;
  const std::string out = dir + "/lattice_band_" + tag, dump = dir + "/lattice_band_" + tag + ".dump";
  std::filesystem::remove_all(out);
  std::filesystem::remove(dump);
  std::ofstream(dir + "/lattice_band_" + tag + ".json") << json;
  setenv("TOPOPT_SHAPE_BAND_DUMP", dump.c_str(), 1);
  try {
    const MaterialLibrary materials = load_materials_file(MATERIALS_JSON_PATH);
    const SettingsRules rules = load_settings_rules_file(SETTINGS_RULES_PATH);
    (void)lattice_variant_job(load_job_file(dir + "/lattice_band_" + tag + ".json"), dir, out,
                              materials, rules);
  } catch (const std::exception& e) {
    std::printf("  (%s refused: %s)\n", tag.c_str(), e.what());
  }
  unsetenv("TOPOPT_SHAPE_BAND_DUMP");
  if (std::filesystem::exists(out))
    for (const auto& e : std::filesystem::directory_iterator(out)) {
      const std::string n = e.path().filename().string();
      if (n.size() > 20 && n.compare(n.size() - 20, 20, "_lattice.report.json") == 0)
        R.receipt = read_file(e.path().string());
      if (n.size() > 12 && n.compare(n.size() - 12, 12, "_lattice.stl") == 0)
        R.stl = read_file(e.path().string());
    }
  R.run_info = read_file(out + "/run_info.json");
  std::ifstream in(dump);
  std::string w;
  while (in >> w) {
    if (w != "BAND") { std::string line; std::getline(in, line); continue; }
    Row r;
    in >> r.d >> r.b >> r.a >> r.S >> r.rho >> r.strut >> r.rho0 >> r.f;
    if (r.d < r.b) R.rows.push_back(r);  // inside the band
  }
  return R;
}

bool has(const std::string& s, const std::string& w) { return s.find(w) != std::string::npos; }

}  // namespace

int main() {
  const std::string dir = TMP_DIR;
  write_stl_file(dir + "/lattice_band_bar.stl", bar(), StlFormat::Binary);
  const StepModel model = import_part(dir + "/lattice_band_bar.stl").model;
  const int left = face_with_normal(model, -1, 0, 0), top = face_with_normal(model, 0, 0, 1);
  CHECK(left >= 0 && top >= 0, "precondition: the bar's faces");
  const std::string band = ", \"shape_grade\": true, \"shape_grade_band_mm\": 8";

  // ── §1 the keys ─────────────────────────────────────────────────────────────
  CHECK(parse_job(job_json(left, top, band + ", \"shape_grade_strength\": -0.5"))
                .grading.shape_grade_strength == -0.5,
        "§1 the strength parses");
  CHECK(refused_with(job_json(left, top, ", \"shape_grade_strength\": 1"), "needs \"shape_grade\": true"),
        "§1 the strength needs the shape grade");
  CHECK(refused_with(job_json(left, top, band + ", \"shape_grade_strength\": 1.5"), "in [-1, 1]"),
        "§1 the strength lies in [-1, 1]");

  // ── §2 strength -1 against +1 ───────────────────────────────────────────────
  const Run m = run(dir, "m", job_json(left, top, band + ", \"shape_grade_strength\": -1"));
  const Run p = run(dir, "p", job_json(left, top, band + ", \"shape_grade_strength\": 1"));
  const double lm = num_after(m.run_info, "latticed_voxels"), lp = num_after(p.run_info, "latticed_voxels");
  std::printf("[band] -1: %.0f latticed, %zu band rows, %.3f g; +1: %.0f latticed, %zu band rows, "
              "%.3f g\n", lm, m.rows.size(), num_after(m.receipt, "lattice_mass_grams"), lp,
              p.rows.size(), num_after(p.receipt, "lattice_mass_grams"));
  CHECK(!m.stl.empty() && !p.stl.empty() && m.stl != p.stl,
        "§2 strength -1 and +1 write different files (red: the same file)");
  CHECK(has(m.receipt, "\"lattice_accepted\": true") && has(p.receipt, "\"lattice_accepted\": true"),
        "§2 both certify (on what the file holds)");
  CHECK(lp > lm, "§2 +1 lattices more of the band: its stronger raise prints finer cells");

  // ── §3 cells, §4 struts ─────────────────────────────────────────────────────
  const double q = std::min(num_after(p.receipt, "quilt_rho"), lattice_rho_max(LatticeTopology::Octet));
  for (const Run* R : {&m, &p}) {
    long long n = 0, exact = 0, one = 0, rho_ok = 0, multiple = 0, not_under = 0, off = 0;
    for (const Row& r : R->rows) {
      if (!(r.f > 0.0)) continue;
      ++n;
      // the preview's cell
      double Sp = r.f;
      for (double S = 2.0 * r.f; kCellMax > r.f && S <= kCellMax * (1.0 + 1e-9); S *= 2.0) {
        if (r.d + 0.5 * S >= r.b * (S - r.f) / (kCellMax - r.f) - 1e-9) Sp = S;
        else break;
      }
      if (std::fabs(r.S - Sp) < 1e-6) ++exact;
      if (r.S / Sp <= 2.0 + 1e-6 && Sp / r.S <= 2.0 + 1e-6) ++one;
      // the preview's raise, then the line width
      const double t = std::min(1.0, std::max(0.0, r.d / r.b));
      const double share = r.S <= r.f * (1.0 + 1e-9) ? 1.0 : 0.35;
      double e = r.rho0 < q ? std::max(r.rho0, std::min(q, r.rho0 + (q - r.rho0) * (1.0 - t) * share * r.a))
                            : r.rho0;
      const double dd = lattice_strut_diameter_mm(LatticeTopology::Octet, e, r.S);
      const double k = std::ceil(dd / kLine - 1e-9);
      double e2 = lattice_min_density_for_strut(LatticeTopology::Octet, r.S, k * kLine, 0.0);
      const double top = std::max(q, e);
      if (!(e2 > 0.0 && e2 >= e - 1e-12 && e2 <= top) && k > 1.0) {
        e2 = lattice_min_density_for_strut(LatticeTopology::Octet, r.S, (k - 1.0) * kLine, 0.0);
        if (!(e2 >= r.rho0 - 1e-12)) e2 = 0.0;  // down, but never under the law
      }
      if (e2 > 0.0 && e2 <= top) e = e2;
      else ++off;  // no whole width between the law and the band's top: the raise stands
      if (std::fabs(e - r.rho) < 1e-9) ++rho_ok;
      if (r.rho >= r.rho0 - 1e-9) ++not_under;
      if (std::fabs(r.strut / kLine - std::round(r.strut / kLine)) < 0.01 && r.strut >= kLine - 1e-9)
        ++multiple;
    }
    std::printf("[band] %s: %lld band voxels; cell = preview %lld, within one level %lld; strut = "
                "preview's raise %lld; whole line widths %lld; off a whole width %lld; never under "
                "the law %lld\n",
                R == &m ? "-1" : "+1", n, exact, one, rho_ok, multiple, off, not_under);
    CHECK(n > 1000, "§3 the band has voxels to compare");
    CHECK(one == n, "§3 every band cell is within one ladder level of the preview's");
    CHECK(exact >= n * 7 / 10, "§3 most band cells are the preview's exactly");
    CHECK(not_under == n, "§4 no band strut is thinner than its own law (the band only adds)");
    CHECK(rho_ok == n, "§4 every band strut is the preview's raise, to a whole line width");
    CHECK(multiple + off >= n && multiple >= n * 9 / 10,
          "§4 band struts are whole line widths, except where the next is past the band's top");
    CHECK(has(R->receipt, "\"off_line_width\": " + std::to_string(off) + ","),
          "§4 the receipt counts the struts left off a whole line width");
  }

  // ── §5 solid only where nothing prints ──────────────────────────────────────
  const std::size_t sb = p.receipt.find("\"shape_band\": {");
  std::printf("[band] +1 receipt: %s\n", sb == std::string::npos ? "(none)"
                                                                  : p.receipt.substr(sb, 240).c_str());
  CHECK(sb != std::string::npos && has(p.receipt, "\"solid_where_unprintable\": ") &&
            num_after(p.receipt, "solid_where_unprintable") < num_after(m.receipt, "solid_where_unprintable"),
        "§5 the receipt says where the band stays solid, and the stronger band leaves less solid");

  std::printf("%s: %d checks, %d failures\n", g_failures ? "FAIL" : "PASS", g_checks,
              g_failures);
  return g_failures ? 1 : 0;
}
