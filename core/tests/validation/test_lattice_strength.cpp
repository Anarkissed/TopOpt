// Install 3: the strength check of the new engine's lattice file (rule V4; lattice_file_strength.hpp).
// A made 30 x 30 x 12 block (an STL the test writes), lattice under its top face, held on its bottom face and loaded
// on one side face, through the file job as the CLI runs it (run_file_job with the CLI's check):
// §1 a light load: checked and accepted; the block carries every name the app reads; fields.bin beside it.
// §2 the thinnest struts and a heavy load: checked, NOT accepted, with the old diagnosis (verdict "fail"); the
//    thinnest struts under a load the solid carries easily and the struts do not: verdict "solid_only" (V5).
// §3 no strength_job: no block, no fields.bin, and the same file (byte for byte) as with the check.
// §4 a cut cell and a cell that lost a bar the file left out get no credit (lattice_credit).
// §5 a type with no strut law (Bccz): its strut margins are null, it is uncertified, and it cannot fully pass.
// Each fail says why (V5): solid_margin (§2 heavy), load_on_open_lattice (§2, a load on cut cells), no_load_path (§5b).
// §6 a strength job that cannot be read, is not lattice_part, or is of another part: refused, no file.
#include <algorithm>
#include <tuple>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <limits>
#include <sstream>
#include <string>
#include <vector>

#include "../../src/flexible/json.hpp"   // reads the result and docs/strength-check/variables.json
#include "topopt/face_overrides.hpp"
#include "topopt/lattice_file_strength.hpp"
#include "topopt/lattice_layout_file.hpp"
#include "topopt/lattice.hpp"
#include "topopt/stl.hpp"
#include "topopt/strut_strength.hpp"

using namespace topopt;
using namespace topopt::lattice_layout;

static int g_fail = 0, g_checks = 0;
#define CHECK(cond)                                                                        \
  do {                                                                                     \
    ++g_checks;                                                                            \
    if (!(cond)) { ++g_fail; std::printf("FAIL %s:%d  %s\n", __FILE__, __LINE__, #cond); } \
  } while (0)

namespace {

const std::string kDir = std::string(TMP_DIR) + "/lattice_strength";

std::string slurp(const std::string& p) {
  std::ifstream f(p, std::ios::binary);
  std::ostringstream s;
  s << f.rdbuf();
  return s.str();
}
bool has(const std::string& s, const std::string& w) { return s.find(w) != std::string::npos; }
bool exists(const std::string& p) { return std::filesystem::exists(p); }
// The number after "key": in `s` (from `from`); NaN for null or absent.
double num_after(const std::string& s, const std::string& key, std::size_t from = 0) {
  const std::size_t k = s.find("\"" + key + "\": ", from);
  if (k == std::string::npos) return std::numeric_limits<double>::quiet_NaN();
  const std::size_t v = k + key.size() + 4;
  if (s.compare(v, 4, "null") == 0) return std::numeric_limits<double>::quiet_NaN();
  return std::strtod(s.c_str() + v, nullptr);
}
// The `strength` block's text ("" when there is none).
std::string block(const std::string& result) {
  const std::size_t a = result.find("\n  \"strength\": {");
  if (a == std::string::npos) return {};
  const std::size_t b = result.find("\n  },\n", a);
  return b == std::string::npos ? std::string() : result.substr(a, b - a + 5);
}

TriangleMesh box(double L, double W, double H) {
  TriangleMesh m;
  for (const Vec3& v : std::vector<Vec3>{{0, 0, 0}, {L, 0, 0}, {L, W, 0}, {0, W, 0},
                                         {0, 0, H}, {L, 0, H}, {L, W, H}, {0, W, H}})
    m.vertices.push_back(v);
  const int t[12][3] = {{0, 2, 1}, {0, 3, 2}, {4, 5, 6}, {4, 6, 7}, {0, 1, 5}, {0, 5, 4},
                        {3, 7, 6}, {3, 6, 2}, {0, 4, 7}, {0, 7, 3}, {1, 2, 6}, {1, 6, 5}};
  for (const auto& tri : t) m.triangles.push_back({tri[0], tri[1], tri[2]});
  return m;
}

// A closed mesh of the filled cells of a grid (breaks xs, ys, zs; `full(i, j, k)` false outside the grid), outward.
template <class Full>
TriangleMesh cells_mesh(const std::vector<double>& xs, const std::vector<double>& ys, const std::vector<double>& zs, Full full) {
  const int nx = static_cast<int>(xs.size()), ny = static_cast<int>(ys.size()), nz = static_cast<int>(zs.size());
  TriangleMesh tm;
  const auto vid = [&](int i, int j, int k) { return (k * ny + j) * nx + i; };
  for (int k = 0; k < nz; ++k)
    for (int j = 0; j < ny; ++j)
      for (int i = 0; i < nx; ++i) tm.vertices.push_back({xs[static_cast<std::size_t>(i)], ys[static_cast<std::size_t>(j)], zs[static_cast<std::size_t>(k)]});
  const auto quad = [&](int q0, int q1, int q2, int q3) {
    tm.triangles.push_back({q0, q1, q2});
    tm.triangles.push_back({q0, q2, q3});
  };
  const auto in = [&](int i, int j, int k) { return i >= 0 && j >= 0 && k >= 0 && i < nx - 1 && j < ny - 1 && k < nz - 1 && full(i, j, k); };
  for (int i = 0; i + 1 < nx; ++i)
    for (int j = 0; j + 1 < ny; ++j)
      for (int k = 0; k + 1 < nz; ++k) {
        if (!in(i, j, k)) continue;
        if (!in(i - 1, j, k)) quad(vid(i, j, k), vid(i, j, k + 1), vid(i, j + 1, k + 1), vid(i, j + 1, k));
        if (!in(i + 1, j, k)) quad(vid(i + 1, j, k), vid(i + 1, j + 1, k), vid(i + 1, j + 1, k + 1), vid(i + 1, j, k + 1));
        if (!in(i, j - 1, k)) quad(vid(i, j, k), vid(i + 1, j, k), vid(i + 1, j, k + 1), vid(i, j, k + 1));
        if (!in(i, j + 1, k)) quad(vid(i, j + 1, k), vid(i, j + 1, k + 1), vid(i + 1, j + 1, k + 1), vid(i + 1, j + 1, k));
        if (!in(i, j, k - 1)) quad(vid(i, j, k), vid(i, j + 1, k), vid(i + 1, j + 1, k), vid(i + 1, j, k));
        if (!in(i, j, k + 1)) quad(vid(i, j, k + 1), vid(i + 1, j, k + 1), vid(i + 1, j + 1, k + 1), vid(i, j + 1, k + 1));
      }
  return tm;
}
// The face of `m` whose plane has normal (nx, ny, nz) and lies at `off` along it.
int face_at(const StepModel& m, double nx, double ny, double nz, double off) {
  for (int f = 0; f < m.face_count; ++f) {
    const StepFaceInfo& x = m.faces[static_cast<std::size_t>(f)];
    if (x.kind == StepSurfaceKind::Plane && x.plane_normal.x * nx + x.plane_normal.y * ny + x.plane_normal.z * nz > 0.99 &&
        std::fabs(x.plane_origin.x * nx + x.plane_origin.y * ny + x.plane_origin.z * nz - off) < 1e-6)
      return f;
  }
  return -1;
}

int face_with_normal(const StepModel& m, double nx, double ny, double nz) {
  for (int f = 0; f < m.face_count; ++f) {
    const StepFaceInfo& fi = m.faces[static_cast<std::size_t>(f)];
    if (fi.kind == StepSurfaceKind::Plane &&
        fi.plane_normal.x * nx + fi.plane_normal.y * ny + fi.plane_normal.z * nz > 0.99)
      return f;
  }
  return -1;
}

struct Faces { int top = -1, bottom = -1, side = -1; };

void write(const std::string& path, const std::string& text) { std::ofstream(path) << text; }

std::string file_job(const Faces& f, const std::string& extra, const std::string& topology = "octet",
                     const std::string& strength_job = "strength_job.json") {
  return "{\"mode\": \"lattice_file\", \"model\": \"block.stl\", \"output\": \"block_lattice.stl\"" +
         (strength_job.empty() ? std::string() : ", \"strength_job\": \"" + strength_job + "\"") +
         ", \"layout\": {\"min_strut_lines\": 2, \"region_ids\": [1], \"region_no_lattice\": [0], "
         "\"region_depth_mm\": [8], \"region_expand_mm\": [-2], \"region_face_counts\": [1], "
         "\"region_faces\": [" + std::to_string(f.top) + "], \"topology\": \"" + topology + "\", "
         "\"algorithm\": \"uniform\", \"cell_max_mm\": 8, \"min_cells_across\": 1" + extra + "}}";
}
std::string strength_job(const Faces& f, double newtons, const std::string& mode = "lattice_part",
                         const std::string& model = "block.stl", int load_face = -1,
                         const std::string& settings = "") {
  return "{\"model\": \"" + model + "\", \"material\": \"PLA\", \"mode\": \"" + mode + "\", "
         "\"resolution\": 40, "
         "\"loads\": {\"minimize_plastic\": true, \"safety_margin\": 1.5, \"build_dir\": [0, 0, 1], "
         "\"anchor_face_ids\": [" + std::to_string(f.bottom) + "], \"groups\": [{\"face_ids\": [" +
         std::to_string(load_face >= 0 ? load_face : f.side) + "], \"force\": [0, 0, " + std::to_string(-newtons) + "]}]}, "
         "\"lattice\": {\"topology\": \"octet\", \"require_lattice_void_reaches_exterior\": false}, "
         "\"grading\": {\"topology\": \"octet\", \"cell_mm\": 8, \"min_extrudable_width_mm\": 0.45, "
         "\"intent\": \"structural\"}, "
         "\"output\": {\"report\": \"report.json\", \"mesh_format\": \"stl\", \"mesh_prefix\": \"variant\"}" +
         (settings.empty() ? std::string() : ", \"strength_settings\": " + settings) + "}";
}

// The same job with the region reaching the block's edges: its cells divide the face exactly and none is cut, so a
// load on the top face lands on credited lattice only (a load on a cut cell's voxels has no path, as the old open
// finish has it).
std::string whole_cells(std::string job) {
  const std::string a = "\"region_expand_mm\": [-2]";
  const std::size_t at = job.find(a);
  if (at != std::string::npos) job.replace(at, a.size(), "\"region_expand_mm\": [0]");
  return job;
}

struct Run {
  FileResult r;
  std::string json, out;
};
Run run(const std::string& tag, const std::string& job, const std::string& sjob) {
  Run x;
  const std::string folder = kDir + "/" + tag;
  std::filesystem::remove_all(folder);
  std::filesystem::create_directories(folder);
  write(kDir + "/" + tag + "_job.json", job);
  if (!sjob.empty()) write(kDir + "/strength_job.json", sjob);
  const StrengthCheck check = lattice_file_strength_check(MATERIALS_JSON_PATH, SETTINGS_RULES_PATH);
  x.r = run_file_job(kDir + "/" + tag + "_job.json", folder, 0, nullptr, &check);
  x.json = slurp(folder + "/" + kFileResultName);
  x.out = folder;
  std::printf("[%s] ok %d code %s why %s %s\n", tag.c_str(), x.r.ok, x.r.code.c_str(), x.r.why.c_str(),
              x.r.detail.c_str());
  return x;
}

// Every name the app reads, in a block that ran.
void check_block_names(const std::string& b) {
  for (const char* k : {"\"accepted\": ", "\"struts_pass\": ", "\"verdict\": \"", "\"margin_worst_case\": ", "\"margin_in_plane\": ", "\"margin_interlayer\": ",
                        "\"safety_margin\": ", "\"not_certified\": ", "\"not_certified_reason\": ", "\"mass_grams\": ",
                        "\"max_effective_von_mises_mpa\": ", "\"max_interlayer_tension_mpa\": ", "\"cells_credited\": ",
                        "\"cells_no_credit\": ", "\"voxel_mm\": ", "\"build_direction\": {\"x\": ", "\"strut\": {\"law\": ",
                        "\"uncertified\": ", "\"gated\": ", "\"out_of_regime\": ", "\"regime_note\": ",
                        "\"fields\": \"fields.bin\"", "\"run_info\": {", "\"ms\": "}) {
    if (!has(b, k)) std::printf("  missing %s\n", k);
    CHECK(has(b, k));
  }
}

}  // namespace

int main() {
  std::filesystem::remove_all(kDir);
  std::filesystem::create_directories(kDir);
  write_stl_file(kDir + "/block.stl", box(30, 30, 12), StlFormat::Binary);
  write_stl_file(kDir + "/other.stl", box(40, 30, 12), StlFormat::Binary);
  Faces f;
  {
    const StepModel m = import_part_file_resolved(kDir + "/block.stl");
    f.top = face_with_normal(m, 0, 0, 1);
    f.bottom = face_with_normal(m, 0, 0, -1);
    f.side = face_with_normal(m, 1, 0, 0);
    std::printf("faces: top %d bottom %d side %d (of %d)\n", f.top, f.bottom, f.side, m.face_count);
  }
  CHECK(f.top >= 0 && f.bottom >= 0 && f.side >= 0);

  // ── §1 a light load: checked and accepted.
  const Run light = run("light", file_job(f, ""), strength_job(f, 20.0));
  CHECK(light.r.ok && light.r.strength_ran && light.r.strength_accepted);
  const std::string lb = block(light.json);
  std::printf("[light] strength block:\n%s\n", lb.c_str());
  CHECK(!lb.empty());
  check_block_names(lb);
  CHECK(has(lb, "\"accepted\": true"));
  CHECK(num_after(lb, "margin_worst_case") >= 1.5);
  CHECK(num_after(lb, "safety_margin") == 1.5);
  CHECK(num_after(lb, "cells_credited") > 0);
  CHECK(num_after(lb, "cells_no_credit") > 0);   // the region's outline cuts cells
  CHECK(num_after(lb, "z") == 1.0);              // the build direction the check used
  CHECK(has(lb, "\"law\": \"") && has(lb, "\"uncertified\": false"));   // octet has its law
  CHECK(has(lb, "\"struts_pass\": true") && has(lb, "\"verdict\": \"pass\""));
  CHECK(!has(lb, "\"diagnosis\""));
  CHECK(has(lb, "\"resolve_reproduces\": true"));   // the re-solve proof, written
  CHECK(num_after(lb, "resolve_margin_solid") > 0.0 && num_after(lb, "resolve_margin_again") > 0.0);
  CHECK(has(lb, "\"settings\": {"));
  CHECK(!has(lb, "\"scenario_fields\""));        // one load case: no scenario fields, as today
  CHECK(exists(light.out + "/fields.bin") && !exists(light.out + "/scenario_fields.bin"));

  // ── §2 the thinnest struts and a heavy load: checked, not accepted, with the old diagnosis.
  const Run heavy = run("heavy", file_job(f, ", \"dial\": 0"), strength_job(f, 40000.0));
  CHECK(heavy.r.ok && heavy.r.strength_ran && !heavy.r.strength_accepted);
  const std::string hb = block(heavy.json);
  check_block_names(hb);
  CHECK(has(hb, "\"accepted\": false"));
  CHECK(num_after(hb, "margin_worst_case") < 1.5);
  CHECK(has(hb, "\"diagnosis\": {"));
  CHECK(has(hb, "\"verdict\": \"fail\""));
  CHECK(has(hb, "\"fail_reason\": \"solid_margin\"") && !has(hb, "load_on_no_credit_n"));
  CHECK(!has(lb, "\"fail_reason\""));
  CHECK(exists(heavy.out + "/fields.bin"));
  {
    // A light load on the lattice's own face, where the region's outline cuts cells: the load lands on lattice given
    // no credit and has no path, so it fails, and says why, with the share of the load that landed there.
    const Run ol = run("open_load", file_job(f, ""), strength_job(f, 20.0, "lattice_part", "block.stl", f.top));
    const std::string ob = block(ol.json);
    CHECK(ol.r.ok && ol.r.strength_ran);
    CHECK(has(ob, "\"verdict\": \"fail\"") && has(ob, "\"fail_reason\": \"load_on_open_lattice\""));
    const double on = num_after(ob, "load_on_no_credit_n"), all = num_after(ob, "load_total_n");
    std::printf("[open_load] %.4g N of %.4g N on lattice with no credit\n", on, all);
    CHECK(on > 0.0 && all >= on && std::fabs(all - 20.0) < 1.0);
  }
  {
    // The thinnest struts under the light load give both margins; linear in the load, so a load between them makes
    // the solid keep its margin and the struts not.
    // Loaded on the lattice's own face (the top), so the load goes through the struts.
    const Run thin = run("thin_light", whole_cells(file_job(f, ", \"dial\": 0")),
                         strength_job(f, 20.0, "lattice_part", "block.stl", f.top));
    const std::string tb = block(thin.json);
    const double ms = num_after(tb, "margin_worst_case");
    const std::size_t st = tb.find("\"strut\": {");
    const double mt = st == std::string::npos ? std::nan("") : num_after(tb, "margin_worst_case", st);
    std::printf("[thin] solid margin %.4g, strut margin %.4g at 20 N\n", ms, mt);
    CHECK(ms > 2.0 * mt);
    const double load = 20.0 * std::sqrt(ms * mt) / 1.5;
    const Run so = run("solid_only", whole_cells(file_job(f, ", \"dial\": 0")),
                       strength_job(f, load, "lattice_part", "block.stl", f.top));
    const std::string sb = block(so.json);
    CHECK(so.r.ok && so.r.strength_ran);
    CHECK(has(sb, "\"accepted\": true") && has(sb, "\"struts_pass\": false") &&
          has(sb, "\"verdict\": \"solid_only\""));
    CHECK(exists(so.out + "/block_lattice.stl"));
  }

  // ── §3 no strength_job: no block, nothing of the check's, the same file.
  const Run none = run("none", file_job(f, "", "octet", ""), "");
  CHECK(none.r.ok && !none.r.strength_ran);
  for (const char* k : {"\"strength\"", "\"fields\"", "\"run_info\"", "\"diagnosis\"", "\"build_direction\"",
                        "\"margin_in_plane\""})
    CHECK(!has(none.json, k));
  CHECK(!exists(none.out + "/fields.bin"));
  CHECK(slurp(none.out + "/block_lattice.stl") == slurp(light.out + "/block_lattice.stl"));
  // Apart from the strength block and the times, the result is the one written with the check.
  {
    auto strip = [](std::string s) {
      const std::string b = block(s);
      if (!b.empty()) s.erase(s.find(b), b.size());
      const std::size_t m = s.find("  \"ms\": {");
      return m == std::string::npos ? s : s.substr(0, m);
    };
    std::string a = strip(none.json), b = strip(light.json);
    CHECK(a == b);
  }

  // ── §4 a cut cell and a cell that lost a bar get no credit.
  {
    StepModel m = import_part_file_resolved(kDir + "/block.stl");
    const FileJob job = parse_file_job(file_job(f, "", "octet", ""));
    Session session(std::move(m));
    const Outcome out = session.lay(job.settings);
    CHECK(!out.layout.cells.empty() && !out.bars.bars.empty());
    // A bar of a whole (uncut) cell, the one nearest the middle of the region: leave it out at its lowest point, as
    // the layer check would name it.
    std::size_t pick = out.bars.bars.size();
    double best = 1e300;
    for (std::size_t i = 0; i < out.bars.bars.size(); ++i) {
      const Bar& b = out.bars.bars[i];
      if (b.piece || b.skin) continue;
      const double mx = 0.5 * (b.a.x + b.b.x) - 15, my = 0.5 * (b.a.y + b.b.y) - 15, mz = 0.5 * (b.a.z + b.b.z) - 8;
      const double d = mx * mx + my * my + mz * mz;
      if (d < best) { best = d; pick = i; }
    }
    CHECK(pick < out.bars.bars.size());
    if (pick >= out.bars.bars.size()) {
      std::printf("lattice_strength: %d checks, %d failed\n", g_checks, g_fail);
      return 1;
    }
    const Bar& b = out.bars.bars[pick];
    const Vec3 low = b.a.z < b.b.z ? b.a : b.b;
    const std::vector<Vec3> left_out{{low.x, low.y, low.z - 0.5 * b.width}};
    CreditGrid g;
    g.origin = {-1, -1, -1};
    g.spacing = 0.5;
    g.nx = 64; g.ny = 64; g.nz = 28;
    const LatticeCredit none_out = lattice_credit(out.layout, *session.domain(), out.bars, {}, g);
    const LatticeCredit c = lattice_credit(out.layout, *session.domain(), out.bars, left_out, g);
    std::size_t cut = 0, cut_credited = 0;
    for (std::size_t i = 0; i < out.layout.cells.size(); ++i)
      if (out.layout.cells[i].cut) { ++cut; cut_credited += c.cell_credit[i]; }
    CHECK(cut > 0 && cut_credited == 0);
    CHECK(c.cut == cut);
    CHECK(c.lost_bar >= 1 && none_out.lost_bar == 0);
    CHECK(c.cells_no_credit == none_out.cells_no_credit + c.lost_bar);
    // A voxel of a no-credit cell is lattice (its cell named) and has no credit; a credited one has.
    std::size_t latticed = 0, credited = 0, uncredited = 0;
    for (std::size_t e = 0; e < c.cell.size(); ++e)
      if (c.cell[e] >= 0) {
        ++latticed;
        CHECK(c.credited[e] == c.cell_credit[static_cast<std::size_t>(c.cell[e])]);
        (c.credited[e] ? credited : uncredited) += 1;
      }
    std::printf("[credit] cells %zu: %zu credited, %zu no credit (cut %zu, lost a bar %zu, band %zu); voxels %zu "
                "latticed, %zu credited\n", out.layout.cells.size(), c.cells_credited, c.cells_no_credit, c.cut,
                c.lost_bar, c.out_of_band, latticed, credited);
    CHECK(credited > 0 && uncredited > 0);
    // Same answer on one thread.
    const LatticeCredit one = lattice_credit(out.layout, *session.domain(), out.bars, left_out, g, nullptr, 1);
    CHECK(one.cell == c.cell && one.credited == c.credited);
  }

  // ── §5 a type with no strut law: margins null, uncertified, never a full pass. The new engine lays none of the
  // three such types (Bccz, Fccz, Reentrant have no width bounds, R1), so the check is asked directly, of an octet
  // layout named Bccz: it has no density law either, so every cell is refused by the band and none is credited.
  {
    write(kDir + "/strength_job.json", strength_job(f, 20.0));
    StepModel m = import_part_file_resolved(kDir + "/block.stl");
    Vec3 lo{1e300, 1e300, 1e300}, hi{-1e300, -1e300, -1e300};
    for (const Vec3& v : m.mesh.vertices) {
      lo = {std::min(lo.x, v.x), std::min(lo.y, v.y), std::min(lo.z, v.z)};
      hi = {std::max(hi.x, v.x), std::max(hi.y, v.y), std::max(hi.z, v.z)};
    }
    Session session(std::move(m));
    Outcome out = session.lay(parse_file_job(file_job(f, "", "octet", "")).settings);
    out.layout.topology = LatticeTopology::Bccz;
    const FileReport made;
    StrengthAsk ask;
    ask.session = &session;
    ask.outcome = &out;
    ask.made = &made;
    ask.job_path = kDir + "/strength_job.json";
    ask.out_dir = kDir + "/bccz";
    std::filesystem::create_directories(ask.out_dir);
    ask.part_lo = lo;
    ask.part_hi = hi;
    const StrengthCheck check = lattice_file_strength_check(MATERIALS_JSON_PATH, SETTINGS_RULES_PATH);
    const StrengthDone d = check.run(ask);
    std::printf("[bccz] ok %d %s %s\n", d.ok, d.why.c_str(), d.detail.c_str());
    CHECK(d.ok);
    const std::string zb = d.json;
    CHECK(has(zb, "\"strut\": {\"law\": null"));
    CHECK(num_after(zb, "cells_credited") == 0.0);
    CHECK(has(zb, "\"uncertified\": true"));
    CHECK(has(zb, "\"accepted\": true") && has(zb, "\"struts_pass\": false") &&
          has(zb, "\"verdict\": \"solid_only\""));
    const std::size_t s = zb.find("\"strut\": {");
    CHECK(s != std::string::npos && has(zb.substr(s), "\"margin_in_plane\": null") &&
          has(zb.substr(s), "\"margin_worst_case\": null"));
  }

  // ── §5b no load path for another reason: a covered region across the whole block, every cell refused credit (the
  // layout named Bccz, as above), the load on the cover: the cover is printed, the lattice under it is empty, and
  // nothing joins the load to the supports. The cover is a 0.5 mm Protect
  // skin on the top face (Finish Covered would shell the sides too); it leaves a 7.5 mm wall, which four 7.5 mm cells
  // fill edge to edge, so no solid strip is left at the sides.
  {
    write(kDir + "/strength_job.json", strength_job(f, 20.0, "lattice_part", "block.stl", f.top));
    StepModel m = import_part_file_resolved(kDir + "/block.stl");
    Vec3 lo{1e300, 1e300, 1e300}, hi{-1e300, -1e300, -1e300};
    for (const Vec3& v : m.mesh.vertices) {
      lo = {std::min(lo.x, v.x), std::min(lo.y, v.y), std::min(lo.z, v.z)};
      hi = {std::max(hi.x, v.x), std::max(hi.y, v.y), std::max(hi.z, v.z)};
    }
    Session session(std::move(m));
    Outcome out = session.lay(parse_file_job(whole_cells(file_job(f, ", \"protect_ids\": [2], \"protect_depth_mm\": [0.5], \"protect_face_counts\": [1], "
                                             "\"protect_faces\": [" + std::to_string(f.top) + "]", "octet", ""))).settings);
    out.layout.topology = LatticeTopology::Bccz;
    const FileReport made;
    StrengthAsk ask;
    ask.session = &session;
    ask.outcome = &out;
    ask.made = &made;
    ask.job_path = kDir + "/strength_job.json";
    ask.out_dir = kDir + "/no_path";
    std::filesystem::create_directories(ask.out_dir);
    ask.part_lo = lo;
    ask.part_hi = hi;
    const StrengthCheck check = lattice_file_strength_check(MATERIALS_JSON_PATH, SETTINGS_RULES_PATH);
    const StrengthDone d = check.run(ask);
    std::printf("[no_path] ok %d %s %s\n", d.ok, d.why.c_str(), d.detail.c_str());
    CHECK(d.ok);
    CHECK(has(d.json, "\"verdict\": \"fail\"") && has(d.json, "\"fail_reason\": \"no_load_path\"") &&
          !has(d.json, "load_on_no_credit_n"));
    if (!has(d.json, "\"fail_reason\": \"no_load_path\"")) std::printf("%s\n", d.json.substr(0, 600).c_str());
  }

  // ── §7 the settings (strength_settings; docs/strength-check). The docs agree with the code: every {{key}} in the two
  // texts is a key of variables.json, the two texts have the same sections and every entry's section is one of them,
  // and the editable entries are exactly the check's settings, with its ranges.
  {
    namespace sj = topopt::flexible::json;
    const std::string docs = DOCS_DIR;
    const sj::Value vars = sj::parse(slurp(docs + "/variables.json"), "variables.json");
    std::vector<std::string> keys, sections;
    for (const sj::Value& e : vars.arr) {
      keys.push_back(sj::as_string(*sj::find(e, "key"), "key"));
      sections.push_back(sj::as_string(*sj::find(e, "section"), "section"));
    }
    CHECK(keys.size() == 100);   // 60 of Install 3, 24 of the Organic check (brief E2), 5 of strengthening by adding (E3a), 2 of the weak areas (E4), 8 of relief vines (E8, OS18 amended, OS18b)
    const auto headings = [](const std::string& t) {
      std::vector<std::string> h;
      std::istringstream in(t);
      for (std::string line; std::getline(in, line);)
        if (line.rfind("## ", 0) == 0) h.push_back(line.substr(3));
      return h;
    };
    const std::string simple = slurp(docs + "/simple.md"), maths = slurp(docs + "/maths.md");
    CHECK(!simple.empty() && !maths.empty());
    CHECK(headings(simple) == headings(maths));
    for (const std::string& sec : sections) {
      const auto h = headings(simple);
      if (std::find(h.begin(), h.end(), sec) == h.end()) std::printf("  section not in the texts: %s\n", sec.c_str());
      CHECK(std::find(h.begin(), h.end(), sec) != h.end());
    }
    for (const std::string* t : {&simple, &maths})
      for (std::size_t at = t->find("{{"); at != std::string::npos; at = t->find("{{", at + 2)) {
        const std::size_t end = t->find("}}", at);
        CHECK(end != std::string::npos);
        if (end == std::string::npos) break;
        const std::string k = t->substr(at + 2, end - at - 2);
        if (std::find(keys.begin(), keys.end(), k) == keys.end()) std::printf("  {{%s}} is not a key\n", k.c_str());
        CHECK(std::find(keys.begin(), keys.end(), k) != keys.end());
      }
    std::size_t editable = 0;
    for (const sj::Value& e : vars.arr) {
      const std::string k = sj::as_string(*sj::find(e, "key"), "key");
      const bool ed = sj::find(e, "editable")->boolean;
      const StrengthSettingSpec* sp = nullptr;
      for (const StrengthSettingSpec& x : strength_setting_specs())
        if (x.key == k) sp = &x;
      if (ed != (sp != nullptr)) std::printf("  %s: editable %d in the docs, %s in the code\n", k.c_str(), ed, sp ? "a setting" : "not one");
      CHECK(ed == (sp != nullptr));
      if (!ed || !sp) continue;
      ++editable;
      const sj::Value* mn = sj::find(e, "min");
      const sj::Value* mx = sj::find(e, "max");
      if (sp->kind == StrengthSettingSpec::Kind::Number || sp->kind == StrengthSettingSpec::Kind::Integer ||
          sp->kind == StrengthSettingSpec::Kind::PerMaterial) {
        CHECK(mn && mn->is_number() && mn->num == sp->min);
        CHECK(mx && mx->is_number() && mx->num == sp->max);
      }
      if (sp->kind == StrengthSettingSpec::Kind::Choice) {
        const sj::Value* ch = sj::find(e, "choices");
        CHECK(ch && ch->arr.size() == sp->choices.size());
        for (std::size_t i = 0; ch && i < ch->arr.size() && i < sp->choices.size(); ++i)
          CHECK(sj::find(ch->arr[i], "value")->num == sp->choices[i]);
      }
      if (sp->kind != StrengthSettingSpec::Kind::PerMaterial && sp->kind != StrengthSettingSpec::Kind::Bool) {
        const sj::Value* d = sj::find(e, "default");
        CHECK(d && d->is_number() && d->num == sp->def);
      }
    }
    CHECK(editable == strength_setting_specs().size());

    // Every editable key stated at its DEFAULT: the check is the one with none stated, number for number.
    std::string defaults = "{\"z_knockdown\": {\"PLA\": 0.55}";
    for (const StrengthSettingSpec& x : strength_setting_specs()) {
      if (x.kind == StrengthSettingSpec::Kind::PerMaterial) continue;
      defaults += ", \"" + x.key + "\": " +
                  (x.kind == StrengthSettingSpec::Kind::Bool ? std::string(x.def != 0.0 ? "true" : "false")
                                                             : [](double d) {
                                                                 char b[40];
                                                                 std::snprintf(b, sizeof b, "%.17g", d);
                                                                 return std::string(b);
                                                               }(x.def));
    }
    defaults += "}";
    const Run same = run("defaults", file_job(f, ""), strength_job(f, 20.0, "lattice_part", "block.stl", -1, defaults));
    CHECK(same.r.ok && same.r.strength_ran);
    const std::string db = block(same.json);
    for (const char* k : {"margin_worst_case", "margin_in_plane", "margin_interlayer", "mass_grams",
                          "max_effective_von_mises_mpa", "max_interlayer_tension_mpa", "resolve_margin_again"}) {
      const double x = num_after(db, k), y = num_after(lb, k);
      if (!(std::fabs(x - y) <= 1e-9 * std::fabs(y))) std::printf("  %s: %.12g stated at defaults, %.12g with none\n", k, x, y);
      CHECK(std::fabs(x - y) <= 1e-9 * std::fabs(y));
    }

    // Every editable key stated at another value it allows: accepted, and echoed as stated.
    const std::string others =
        "{\"z_knockdown\": {\"PLA\": 0.5}, \"safety_margin_floor\": 1.2, \"infill_exponent\": 2, \"infill_floor\": 0.01, "
        "\"width_aware_knockdown\": true, \"thickness_cap_voxels\": 16, \"load_path_connectivity\": 18, "
        "\"printed_threshold\": 0.4, \"void_floor\": 1e-8, \"cg_tolerance\": 1e-9, \"cg_max_iterations\": 100000, "
        "\"contact_rounds\": 3, \"sliding_share_max\": 0.1, \"bearing_stiffness\": 100000, "
        "\"bearing_tangent_fraction\": 0.001, \"scenario_weak_spring\": 1e-7, \"scenario_weak_spring_min_scale\": 0.1, "
        "\"scenario_unheld_share\": 0.1, \"part_box_tol_mm\": 0.2, \"part_box_tol_fraction\": 0.01, "
        "\"min_feature_warning_threshold\": 2}";
    const Run set = run("settings", file_job(f, ""), strength_job(f, 20.0, "lattice_part", "block.stl", -1, others));
    CHECK(set.r.ok && set.r.strength_ran);
    const sj::Value stated = sj::parse(others, "stated");
    const sj::Value result = sj::parse(set.json, "lattice_file.json");
    const sj::Value* got = sj::find(*sj::find(result, "strength"), "settings");
    CHECK(got != nullptr);
    if (got) {
      std::size_t echoed = 0;
      for (const auto& [k, v] : stated.obj) {
        const sj::Value* g = sj::find(*got, k);
        CHECK(g != nullptr);
        if (!g) continue;
        if (k == "z_knockdown") {
          CHECK(sj::find(*g, "PLA") && sj::find(*g, "PLA")->num == 0.5);
        } else if (v.is_bool()) {
          CHECK(g->is_bool() && g->boolean == v.boolean);
        } else {
          const bool eq = g->is_number() && std::fabs(g->num - v.num) <= 1e-12 * std::fabs(v.num);
          if (!eq) std::printf("  %s: stated %g, used %g\n", k.c_str(), v.num, g->is_number() ? g->num : -1.0);
          CHECK(eq);
        }
        ++echoed;
      }
      // Install 3's settings are its own; the Organic check's (sections "Organic: ...") are not read by it.
      std::size_t organic = 0;
      for (std::size_t i = 0; i < keys.size(); ++i) organic += sections[i].rfind("Organic", 0) == 0;
      CHECK(echoed + organic == strength_setting_specs().size());
      CHECK(got->obj.size() == 60);   // every variable of Install 3's docs, editable or not
      for (std::size_t i = 0; i < keys.size(); ++i)
        if (sections[i].rfind("Organic", 0) != 0) CHECK(sj::find(*got, keys[i]) != nullptr);
    }
    // The layer factor reaches the margin: 0.5 in place of PLA's 0.55 scales the layer margin by 0.5 / 0.55.
    const double il = num_after(lb, "margin_interlayer"), il2 = num_after(block(set.json), "margin_interlayer");
    std::printf("[settings] layer margin %.6g -> %.6g (ratio %.4f, expected %.4f)\n", il, il2, il2 / il, 0.5 / 0.55);
    CHECK(std::fabs(il2 / il - 0.5 / 0.55) < 0.01);

    // Refused, with one line and no file: a key it does not know, and a value out of its range.
    for (const auto& [tag, bad, word] : std::vector<std::tuple<const char*, std::string, const char*>>{
             {"unknown_setting", "{\"infill_exponant\": 2}", "infill_exponant"},
             {"out_of_range", "{\"infill_exponent\": 7}", "infill_exponent"},
             {"z_out_of_range", "{\"z_knockdown\": {\"PLA\": 0}}", "z_knockdown"},
             {"bad_choice", "{\"load_path_connectivity\": 8}", "load_path_connectivity"}}) {
      const Run x = run(tag, file_job(f, ""), strength_job(f, 20.0, "lattice_part", "block.stl", -1, bad));
      CHECK(!x.r.ok && x.r.code == "strength_settings_refused" && x.r.exit_code == 1);
      CHECK(has(x.r.why, word) && x.r.why.find('\n') == std::string::npos);
      CHECK(!exists(x.out + "/block_lattice.stl"));
    }
  }

  // ── §9 (brief E2, item 7) Organic: every lattice region a weave, checked as a frame of beams on the bars the file
  // holds; Install 3's block keys, the struts' numbers, the weakest struts, and strut_margins.bin (a float32 per bar).
  {
    TensorField tf;
    tf.spacing = 1.0;
    tf.nx = 30; tf.ny = 30; tf.nz = 12;
    tf.voigt.assign(6 * 30 * 30 * 12, 0.0);
    for (std::size_t e = 0; e < 30 * 30 * 12; ++e) { tf.voigt[6 * e + 2] = 3.0; tf.voigt[6 * e] = 1.0; }
    CHECK(write_tensor_file(kDir + "/stress.tensor", tf));
    std::string fj = file_job(f, ", \"region_weave\": [true], \"organic_spacing_mm\": 4, \"organic_width_mm\": 0.9");
    fj.replace(fj.find("\"layout\""), 8, "\"tensor\": \"stress.tensor\", \"layout\"");
    const Run org = run("organic", fj, strength_job(f, 20.0));
    CHECK(org.r.ok && org.r.strength_ran);
    const std::string b = block(org.json);
    check_block_names(b);
    for (const char* k : {"\"struts\": {\"judged\": ", "\"under_safety\": ", "\"under_one\": ", "\"smallest_margin\": ",
                          "\"buckling_failures\": ", "\"stubs\": ", "\"unjudged_mm\": ", "\"load_unheld_n\": ",
                          "\"weakest\": [", "\"strut_margins\": \"strut_margins.bin\"", "\"frame_link_stiffness\": "})
      CHECK(has(b, k));
    const std::string verdict = b.substr(b.find("\"verdict\": \"") + 12, 12);
    std::printf("[organic] verdict %s judged %.0f under_safety %.0f smallest %.4g\n", verdict.substr(0, verdict.find('"')).c_str(),
                num_after(b, "judged"), num_after(b, "under_safety"), num_after(b, "smallest_margin"));
    CHECK(has(verdict, "pass\"") || has(verdict, "fail\"") || has(verdict, "solid_only\""));
    CHECK(num_after(b, "judged") > 0);
    const std::string mb = slurp(org.out + "/strut_margins.bin");
    std::size_t judged_bars = 0;
    for (std::size_t i = 0; i + 4 <= mb.size(); i += 4) {
      float v;
      std::memcpy(&v, mb.data() + i, 4);
      judged_bars += !std::isnan(v);
    }
    std::printf("[organic] strut_margins.bin: %zu bars, %zu judged; file bars %zu\n", mb.size() / 4, judged_bars, org.r.bars);
    CHECK(mb.size() % 4 == 0 && mb.size() / 4 >= org.r.bars && judged_bars > 0);
    CHECK(exists(org.out + "/fields.bin"));
    // The Organic verdict (the lead's ruling of 2026-11-18): the solid's stress margin over its solid voxels; the load path
    // judged on the frame (Install 3's voxel load-path test not applied); each weakest strut says what drives its ends.
    CHECK(has(b, "\"solid_margin\": {\"worst_case\": ") && has(b, "\"loaded_nodes_undriven\": 0") && has(b, "\"ends\": [{\"at\": "));
    CHECK(!has(b, "\"fail_reason\": \"no_load_path\""));
    // passes_at_infill_percent: the lowest whole infill at which the solid's effective margin reaches the safety margin.
    CHECK(has(b, "\"passes_at_infill_percent\": ") && !has(b, "\"passes_at_infill_percent\": null"));
    {   // width_aware_knockdown is honoured as Install 3 honours it: at 20 % infill with two 0.45 mm walls the setting
        // changes the solid's effective margin (the walls rescue thin members).
      const auto sparse = [&](const std::string& settings) {
        std::string j = strength_job(f, 20.0, "lattice_part", "block.stl", -1, settings);
        j.replace(j.find("\"minimize_plastic\": true,"), 25,
                  "\"minimize_plastic\": true, \"infill_percent\": 20, \"wall_loops\": 2, \"wall_line_width_mm\": 0.45,");
        return j;
      };
      const std::string sb = block(run("organic_scalar", fj, sparse("{\"width_aware_knockdown\": false}")).json);
      const std::string wb2 = block(run("organic_wa", fj, sparse("{\"width_aware_knockdown\": true}")).json);
      std::printf("[organic width-aware] effective %.6g (scalar %.6g), passes at %.0f %% (scalar %.0f %%)\n",
                  num_after(wb2, "effective"), num_after(sb, "effective"), num_after(wb2, "passes_at_infill_percent"),
                  num_after(sb, "passes_at_infill_percent"));
      CHECK(has(wb2, "\"width_aware_knockdown\": 1") && num_after(wb2, "effective") > num_after(sb, "effective"));
    }
    {
      const Run heavy = run("organic_heavy", fj, strength_job(f, 2.0e6));
      const std::string hb2 = block(heavy.json);
      std::printf("[organic heavy] %s\n", hb2.substr(hb2.find("\"verdict\""), 120).c_str());
      CHECK(heavy.r.ok && has(hb2, "\"verdict\": \"fail\"") && has(hb2, "\"fail_reason\": \"solid_margin\""));
      CHECK(has(hb2, "\"passes_at_infill_percent\": null"));   // not even solid infill holds 2e6 N
    }

    // ── §17 (OS9 amended, the lead's ruling of 2026-11-19) an adrift part of the frame (no driven node) carries nothing
    // and is never by itself a reason to fail. The organic block's own lattice, checked with (a) one extra loose bar
    // lying 0.5 mm outside the loaded x = 30 face (near the load, adrift): no fail for it, listed with its place; and
    // (b) under a load on the top face, a lattice of loose bars only under it (adrift), with one strut from the floor
    // to one corner of the face: the load lands only near adrift nodes: no_load_path.
    {
      StepModel m = import_part_file_resolved(kDir + "/block.stl");
      Session session(std::move(m));
      const FileJob job = parse_file_job(fj);
      TensorField t17 = tf;
      const Outcome lay = session.lay_organic(job.settings, t17, job.organic, 0);
      const StrengthCheck check = lattice_file_strength_check(MATERIALS_JSON_PATH, SETTINGS_RULES_PATH);
      const auto check_with = [&](const std::string& tag, const Bars& bars, const std::string& sj) {
        write(kDir + "/strength_job.json", sj);
        StrengthAsk ask;
        ask.session = &session;
        ask.outcome = &lay;
        ask.job_path = kDir + "/strength_job.json";
        ask.out_dir = kDir + "/" + tag;
        std::filesystem::create_directories(ask.out_dir);
        ask.part_lo = {0, 0, 0};
        ask.part_hi = {30, 30, 12};
        ask.bars = &bars;
        ask.light_width_mm = 0.9;
        const StrengthDone d = check.run_organic(ask);
        CHECK(d.ok);
        return d.json;
      };
      const auto loose = [](Vec3 a, Vec3 b) {
        Bar x;
        x.a = a;
        x.b = b;
        x.width = 0.9;
        x.end_a = x.end_b = Bar::End::Loose;
        x.region = 1;
        return x;
      };
      Bars with_extra = lay.bars;
      with_extra.bars.push_back(loose({30.5, 10, 4}, {30.5, 15, 4}));
      with_extra.bars.push_back(loose({30.5, 15, 4}, {30.5, 20, 4}));
      const std::string ja = check_with("adrift_a", with_extra, strength_job(f, 20.0));
      const std::size_t fr = ja.find("\"adrift_parts\": [");
      std::printf("[adrift a] %s | %s\n", ja.substr(ja.find("\"verdict\""), 20).c_str(),
                  fr == std::string::npos ? "-" : ja.substr(fr, 220).c_str());
      CHECK(!has(ja, "\"fail_reason\": \"no_load_path\"") && num_after(ja, "adrift_total") >= 1.0 && fr != std::string::npos &&
            has(ja.substr(fr, 200), "\"centre\": [30.5, 15, 4]"));
      Bars only_adrift;
      for (double y = 3.0; y <= 27.0; y += 3.0)
        for (double x = 3.0; x < 27.0; x += 0.6) only_adrift.bars.push_back(loose({x, y, 11.6}, {x + 0.6, y, 11.6}));
      Bar post;
      post.a = {27.0, 27.0, 1.0};
      post.b = {27.0, 27.0, 11.6};
      post.width = 0.9;
      post.end_a = Bar::End::Solid;
      post.end_b = Bar::End::Loose;
      post.region = 1;
      only_adrift.bars.push_back(post);
      const std::string jb = check_with("adrift_b", only_adrift, strength_job(f, 20.0, "lattice_part", "block.stl", f.top));
      std::printf("[adrift b] %s; load on adrift %.4g N of %.4g N, loaded nodes undriven %.0f\n", jb.substr(jb.find("\"verdict\""), 60).c_str(),
                  num_after(jb, "load_on_adrift_n"), num_after(jb, "load_total_n"), num_after(jb, "loaded_nodes_undriven"));
      CHECK(has(jb, "\"fail_reason\": \"no_load_path\"") && num_after(jb, "load_on_adrift_n") > 0.01 * num_after(jb, "load_total_n"));
    }

    // ── §10 (brief E2, item 12) the strengthen rounds as one job: a heavy load (struts under the safety margin), the
    // width on a Sweep and the spacing a range; one round allowed. Then a job with nothing that follows the stress.
    const auto strengthen = [&](const std::string& tag, const std::string& extra, double newtons, const std::string& settings) {
      std::string j = file_job(f, extra);
      j.replace(j.find("\"layout\""), 8, "\"tensor\": \"stress.tensor\", \"layout\"");
      write(kDir + "/" + tag + "_job.json", j);
      write(kDir + "/strength_job.json", strength_job(f, newtons, "lattice_part", "block.stl", -1, settings));
      const std::string out = kDir + "/" + tag;
      std::filesystem::remove_all(out);
      std::filesystem::create_directories(out);
      const OrganicStrengthenResult r =
          run_organic_strengthen(kDir + "/" + tag + "_job.json", out, 0, MATERIALS_JSON_PATH, SETTINGS_RULES_PATH);
      std::printf("[%s] ok %d code %s rounds %d passing %d %s %s\n", tag.c_str(), r.ok, r.code.c_str(), r.rounds_fixed,
                  r.passing, r.why.c_str(), r.detail.c_str());
      return r;
    };
    const OrganicStrengthenResult sr =
        strengthen("strengthen", ", \"region_weave\": [true], \"organic_spacing_min_mm\": 3, \"organic_spacing_max_mm\": 6, "
                                 "\"organic_width_mm\": 0.9, \"organic_width_heavy_mm\": 1.8",
                   6000.0, "{\"strengthen_rounds\": 1, \"strengthen_mode\": \"rebuild\"}");
    const std::string sjson = slurp(kDir + "/strengthen/strengthen.json");
    std::printf("%s\n", sjson.substr(0, 1400).c_str());
    CHECK(sr.ok && (sr.code == "done" || sr.code == "limit"));
    CHECK(sr.rounds_fixed == 1 && sr.last_strengthened == "r1/strengthened.json");
    for (const char* x : {"/r0/strength.json", "/r0/strut_margins.bin", "/r0/fields.bin", "/r1/strengthened.json",
                          "/r1/stress.tensor", "/r1/floors.bin", "/r1/strength.json"})
      CHECK(exists(kDir + "/strengthen" + x));
    CHECK(has(sjson, "\"round\": 0") && has(sjson, "\"round\": 1") && has(sjson, "\"wrote\": {\"strengthened\": \"r1/strengthened.json\""));
    CHECK(num_after(sjson, "under_safety") > 0);   // round 0 had struts under the safety margin
    CHECK(has(sjson, "\"bars_geometry\": \"") && has(sjson, "\"struts_at_upper_width\": "));
    // The reference stated is the one the first lay resolved, and reads back as the same double.
    {
      TensorField back;
      OrganicAsk a;
      std::string why;
      CHECK(apply_strengthened(kDir + "/strengthen/r1/strengthened.json", back, a, &why));
      CHECK(a.reference_mpa > 0.0 && a.reference_mpa == num_after(sjson, "reference_mpa") && !a.floors.empty());
    }
    const OrganicStrengthenResult nv =
        strengthen("nothing", ", \"region_weave\": [true], \"organic_spacing_mm\": 4, \"organic_width_mm\": 0.9", 2500.0,
                   "{\"strengthen_mode\": 1}");
    CHECK(nv.ok && nv.code == "nothing_to_vary" && nv.rounds_fixed == 0);
    // Brief E4, item 1: strengthen_rounds 0 (the default) is 2 rounds for Traced in the rebuild mode, and SIX in the
    // additive mode (stopping as soon as nothing is under the safety margin: a light load stops at round 0).
    CHECK(num_after(slurp(kDir + "/nothing/strengthen.json"), "rounds_limit") == 2.0);
    {
      const OrganicStrengthenResult dr =
          strengthen("additive_default", ", \"region_weave\": [true], \"organic_spacing_mm\": 4, \"organic_width_mm\": 0.9", 20.0, "");
      const std::string dj = slurp(kDir + "/additive_default/strengthen.json");
      std::printf("[additive_default] rounds_limit %.0f\n", num_after(dj, "rounds_limit"));
      CHECK(dr.ok && has(dj, "\"mode\": \"additive\"") && num_after(dj, "rounds_limit") == 6.0);
    }

    // ── §11 (brief E3a) the additive mode, the default: the lattice is laid ONCE; each round adds (widening in place,
    // braces) and checks again; every bar of round 0 is kept (OS12); r<n>/strengthened.json (version 2) and its
    // additions.bin, given to the file job, lay the same lattice (its hash checked: a mismatch is refused); a job with
    // one strut width is widened too.
    const std::string sweep = ", \"region_weave\": [true], \"organic_spacing_min_mm\": 3, \"organic_spacing_max_mm\": 6, "
                              "\"organic_width_mm\": 0.9, \"organic_width_heavy_mm\": 1.8";
    // OS18 amended (2026-11-19): §11 pins the loop before OS18 (strengthen_paths 0: widening up to the cap and braces);
    // with paths on, its struts (at the upper width 0.9 already) go to the relief step instead of widening.
    const OrganicStrengthenResult ad = strengthen("additive", sweep, 6000.0, "{\"strengthen_rounds\": 3, \"strengthen_paths\": 0}");
    const std::string ajson = slurp(kDir + "/additive/strengthen.json");
    std::printf("%s\n", ajson.substr(0, 2400).c_str());
    CHECK(ad.ok && (ad.code == "done" || ad.code == "limit") && ad.rounds_fixed >= 1 && ad.old_bars_kept);
    CHECK(has(ajson, "\"mode\": \"additive\"") && has(ajson, "\"old_bars_kept\": true") && !has(ajson, "\"old_bars_kept\": false"));
    CHECK(has(ajson, "\"added\": {\"strengthened\": \"r1/strengthened.json\"") && num_after(ajson, "bars_widened") > 0);
    for (const char* x : {"/r0/strength.json", "/r0/struts_under.json", "/r1/strengthened.json", "/r1/additions.bin", "/r1/strength.json"})
      CHECK(exists(kDir + "/additive" + x));
    CHECK(!exists(kDir + "/additive/r1/stress.tensor") && !exists(kDir + "/additive/r1/floors.bin"));
    CHECK(has(slurp(kDir + "/additive/r0/struts_under.json"), "\"bars\": ["));
    {
      // Round 1's lattice in the check had this many bars; the file job given r1/strengthened.json lays the same.
      const std::size_t r1 = ajson.find("\"round\": 1");
      const double bars1 = num_after(ajson, "bars", r1);
      std::string j = file_job(f, sweep, "octet", "");
      j.replace(j.find("\"layout\""), 8, "\"tensor\": \"stress.tensor\", \"strengthened\": \"additive/r1/strengthened.json\", \"layout\"");
      write(kDir + "/replay_job.json", j);
      std::filesystem::remove_all(kDir + "/replay");
      std::filesystem::create_directories(kDir + "/replay");
      const FileResult rr = run_file_job(kDir + "/replay_job.json", kDir + "/replay");
      std::printf("[replay] ok %d code %s bars %zu (round 1: %.0f) %s\n", rr.ok, rr.code.c_str(), rr.bars, bars1, rr.detail.c_str());
      CHECK(rr.ok && static_cast<double>(rr.bars) == bars1);
      // The same additions on another lattice (a narrower spacing range): refused, nothing made.
      std::string k = file_job(f, ", \"region_weave\": [true], \"organic_spacing_min_mm\": 3, \"organic_spacing_max_mm\": 5, "
                                  "\"organic_width_mm\": 0.9, \"organic_width_heavy_mm\": 1.8", "octet", "");
      k.replace(k.find("\"layout\""), 8, "\"tensor\": \"stress.tensor\", \"strengthened\": \"additive/r1/strengthened.json\", \"layout\"");
      write(kDir + "/mismatch_job.json", k);
      std::filesystem::remove_all(kDir + "/mismatch");
      std::filesystem::create_directories(kDir + "/mismatch");
      const FileResult mm = run_file_job(kDir + "/mismatch_job.json", kDir + "/mismatch");
      std::printf("[mismatch] ok %d code %s %s\n", mm.ok, mm.code.c_str(), mm.detail.c_str());
      CHECK(!mm.ok && mm.code == "strengthened_mismatch" && !exists(kDir + "/mismatch/block_lattice.stl"));
    }
    // OS18 (brief E8, owed; amended 2026-11-19): strengthen_paths 0 against §11's additive job (paths on):
    // round 0's hash the same, and round 0's additions the same operations (kinds, counts) with every number within
    // 1e-9 (the strength solve is not repeatable to the last bit from run to run: two equal runs' widths differ by about
    // 3e-13 mm, so the next hashes cannot be pinned across runs).
    {
      const OrganicStrengthenResult off = strengthen("additive_paths_off", sweep, 6000.0, "{\"strengthen_rounds\": 1}");   // paths ON
      const std::string oj = slurp(kDir + "/additive_paths_off/strengthen.json");
      const std::size_t a0 = ajson.find("\"round\": 0, \"verdict\""), o0 = oj.find("\"round\": 0, \"verdict\"");
      const std::size_t pa = ajson.find("\"paths\": {", a0);
      const bool handed0 = num_after(ajson, "struts_handed", pa) > 0;
      const bool same0 = ajson.substr(ajson.find("\"hash\": \"", a0), 28) == oj.substr(oj.find("\"hash\": \"", o0), 28);
      Additions a, b;
      std::string why;
      const bool read = read_additions_file(kDir + "/additive/r1/additions.bin", a, &why) &&
                        read_additions_file(kDir + "/additive_paths_off/r1/additions.bin", b, &why);
      bool ops_same = read && !a.rounds.empty() && !b.rounds.empty() && a.rounds[0].ops.size() == b.rounds[0].ops.size();
      double most = 0.0;
      for (std::size_t k = 0; ops_same && k < a.rounds[0].ops.size(); ++k) {
        const AddOp &x = a.rounds[0].ops[k], &y = b.rounds[0].ops[k];
        ops_same = x.kind == y.kind && x.v.size() == y.v.size();
        for (std::size_t q = 0; ops_same && q < x.v.size(); ++q) most = std::max(most, std::fabs(x.v[q] - y.v[q]));
      }
      std::printf("[paths off] §11 handed to C in round 0: %d; round 0 hash the same %d; round 0 ops the same %d (most apart %.3g)\n",
                  handed0 ? 1 : 0, same0 ? 1 : 0, ops_same ? 1 : 0, most);
      // OS18 amended: §11 (paths on) now hands its struts over the limit to a relief step from round 0, so its round 0
      // additions differ from strengthen_paths 0's (the loop before OS18, pinned by §11's checks below with paths 0 and
      // by §18's paths_off); the lay itself is the same.
      CHECK(off.ok && same0);
    }
    const OrganicStrengthenResult one =
        strengthen("additive_one", ", \"region_weave\": [true], \"organic_spacing_mm\": 4, \"organic_width_mm\": 0.9", 6000.0,
                   "{\"strengthen_rounds\": 1, \"strengthen_paths\": 0}");
    const std::string ojson = slurp(kDir + "/additive_one/strengthen.json");
    CHECK(one.ok && one.code != "nothing_to_vary" && one.old_bars_kept);
    CHECK(one.rounds_fixed == 0 || num_after(ojson, "bars_widened") > 0);

    // ── §18 (brief E8, rule OS18) relief vines: the width cap at 1 (every weak strut is at the cap at once), two
    // rounds: struts are handed to C, braced at mid-span (bent ones) or given relief vines, every old bar kept, the
    // print check's count of vines it left out reported; the file job given r1/strengthened.json lays the same bars;
    // strengthen_paths 0: no vine, said so.
    {
      // A wider spacing (5 to 8 mm) than §11's, so that a vine has room beside a strut.
      const std::string roomy = ", \"region_weave\": [true], \"organic_spacing_min_mm\": 5, \"organic_spacing_max_mm\": 8, "
                                "\"organic_width_mm\": 0.9, \"organic_width_heavy_mm\": 1.2, \"organic_strand_keep\": 0.5";   // spacing off
      const OrganicStrengthenResult pr = strengthen("paths", roomy, 6000.0, "{\"strengthen_rounds\": 2, \"strengthen_width_cap\": 1.0}");
      const std::string pj = slurp(kDir + "/paths/strengthen.json");
      const std::size_t r0 = pj.find("\"round\": 0"), r1 = pj.find("\"round\": 1");
      const std::size_t pp = pj.find("\"paths\": {", r0);
      std::printf("[paths] %s\n", pp == std::string::npos ? "(no paths)" : pj.substr(pp, 420).c_str());
      std::printf("[paths] round 0: under safety %.0f, smallest margin %.4g; round 1: under safety %.0f, smallest margin %.4g\n",
                  num_after(pj, "under_safety", r0), num_after(pj, "smallest_margin", r0), num_after(pj, "under_safety", r1),
                  num_after(pj, "smallest_margin", r1));
      CHECK(pr.ok && pr.rounds_fixed >= 1 && pr.old_bars_kept && has(pj, "\"old_bars_kept\": true") && !has(pj, "\"old_bars_kept\": false"));
      CHECK(pp != std::string::npos && num_after(pj, "struts_handed", pp) > 0 &&
            num_after(pj, "relief_vines", pp) > 0 && num_after(pj, "mid_span_braces", pp) > 0 &&
            has(pj.substr(pp, 4000), "\"print_left_out\": "));
      // A vine's host in the next check: its margin there (the watched strut whose middle lies within 1 mm of its
      // middle), or past the watch (no longer watched). Counted: hosts, and those whose margin rose.
      const auto hosts_rose = [&](const std::string& tag) {
        namespace sj = topopt::flexible::json;
        const sj::Value doc = sj::parse(slurp(kDir + "/" + tag + "/strengthen.json"), "strengthen.json");
        const sj::Value* rounds = sj::find(doc, "rounds");
        const sj::Value* paths0 = rounds ? sj::find(*sj::find(rounds->arr[0], "added"), "paths") : nullptr;
        const sj::Value under1 = sj::parse(slurp(kDir + "/" + tag + "/r1/struts_under.json"), "struts_under.json");
        std::size_t hosts = 0, rose = 0;
        if (paths0)
          for (const sj::Value& v : sj::find(*paths0, "vines_at")->arr) {
            const auto& a = sj::find(v, "at")->arr;
            const double m0 = sj::find(v, "margin")->num;
            double best = 1e9, m1 = 1e9;
            for (const sj::Value& st : sj::find(under1, "struts")->arr) {
              const auto& b = sj::find(st, "at")->arr;
              const double dd = std::hypot(a[0].num - b[0].num, std::hypot(a[1].num - b[1].num, a[2].num - b[2].num));
              if (dd < best) { best = dd; m1 = sj::find(st, "margin")->num; }
            }
            ++hosts;
            rose += best > 1.0 || m1 > m0;
            std::printf("[%s] vine host at %.2f %.2f %.2f: margin %.3f -> %s\n", tag.c_str(), a[0].num, a[1].num, a[2].num, m0,
                        best > 1.0 ? "not watched" : std::to_string(m1).c_str());
          }
        return std::make_pair(hosts, rose);
      };
      {   // Many struts at once (every weak strut at the cap): counted, not every host need rise (they share the load).
        const auto hr = hosts_rose("paths");
        std::printf("[paths] vine hosts %zu, %zu stronger in round 1\n", hr.first, hr.second);
        CHECK(hr.first > 0);
      }
      // OS18 (owed): a strut braced at mid-span gets no vine in that round (one strut handed, every length braced).
      {
        const OrganicStrengthenResult br = strengthen("paths_braced", roomy, 6000.0,
            "{\"strengthen_rounds\": 1, \"strengthen_width_cap\": 1.0, \"strengthen_paths_max\": 1, \"strengthen_path_brace_min_mm\": 0}");
        const std::string bj = slurp(kDir + "/paths_braced/strengthen.json");
        const std::size_t bp = bj.find("\"paths\": {");
        std::printf("[paths braced] handed %.0f, mid-span braces %.0f, vines %.0f\n", num_after(bj, "struts_handed", bp),
                    num_after(bj, "mid_span_braces", bp), num_after(bj, "relief_vines", bp));
        CHECK(br.ok && bp != std::string::npos && num_after(bj, "struts_handed", bp) == 1 &&
              num_after(bj, "mid_span_braces", bp) == 1 && num_after(bj, "relief_vines", bp) == 0);
      }
      // ONE strut handed to C (strengthen_paths_max 1, no mid-span brace): it gets a vine and is stronger next round.
      {
        const OrganicStrengthenResult one_v = strengthen("paths_one", roomy, 6000.0,
            "{\"strengthen_rounds\": 1, \"strengthen_width_cap\": 1.0, \"strengthen_paths_max\": 1, \"strengthen_path_brace_min_mm\": 100}");
        const auto hr = hosts_rose("paths_one");
        CHECK(one_v.ok && one_v.old_bars_kept && hr.first == 1 && hr.second == 1);
      }
      // Replay: the file job given round 1's strengthened.json lays round 1's bars.
      const double bars1 = num_after(pj, "bars", r1);
      std::string j = file_job(f, roomy, "octet", "");
      j.replace(j.find("\"layout\""), 8, "\"tensor\": \"stress.tensor\", \"strengthened\": \"paths/r1/strengthened.json\", \"layout\"");
      write(kDir + "/paths_replay_job.json", j);
      std::filesystem::remove_all(kDir + "/paths_replay");
      std::filesystem::create_directories(kDir + "/paths_replay");
      const FileResult rr = run_file_job(kDir + "/paths_replay_job.json", kDir + "/paths_replay");
      std::printf("[paths replay] ok %d code %s bars %zu (round 1: %.0f) %s\n", rr.ok, rr.code.c_str(), rr.bars, bars1, rr.detail.c_str());
      CHECK(rr.ok && static_cast<double>(rr.bars) == bars1);
      const OrganicStrengthenResult po =
          strengthen("paths_off", roomy, 6000.0, "{\"strengthen_rounds\": 2, \"strengthen_width_cap\": 1.0, \"strengthen_paths\": 0}");
      const std::string oj = slurp(kDir + "/paths_off/strengthen.json");
      CHECK(po.ok && has(oj, "\"paths\": {\"on\": false, \"struts_handed\": 0") && num_after(oj, "relief_vines") == 0.0);

      // ── OS18 amended (the owner, 2026-11-19: "thicken to the limit, add vines, and only at the end if it is
      // impossible, thicken passed the limit"): the limit is the upper strut width (1.2 here), the cap 2 x that.
      namespace sj = topopt::flexible::json;
      const double limit = 1.2;
      const auto rounds_of = [&](const std::string& tag) {
        const sj::Value doc = sj::parse(slurp(kDir + "/" + tag + "/strengthen.json"), "strengthen.json");
        const sj::Value* rs = sj::find(doc, "rounds");
        return rs ? rs->arr : std::vector<sj::Value>{};
      };
      const auto paths_of = [&](const sj::Value& round) -> const sj::Value* {
        const sj::Value* added = sj::find(round, "added");
        return added ? sj::find(*added, "paths") : nullptr;
      };
      const auto num = [](const sj::Value* v, const char* k) { const sj::Value* x = v ? sj::find(*v, k) : nullptr; return x ? x->num : -1.0; };
      // The widest watched strut in round n's check, and whether each strut past the limit lies at a place an earlier
      // round named past the limit (within 1 mm).
      const auto widths_ok = [&](const std::string& tag, std::size_t* over, std::size_t* over_named, double* widest,
                                 std::size_t* over_past = nullptr) {
        const std::vector<sj::Value> rs = rounds_of(tag);
        std::vector<std::array<double, 3>> named;
        *over = *over_named = 0;
        *widest = 0.0;
        double past_so_far = 0.0;   // the struts named past the limit in the rounds before
        if (over_past) *over_past = 0;
        for (std::size_t n = 0; n < rs.size(); ++n) {
          std::size_t over_here = 0;
          if (n > 0) {
            const sj::Value su = sj::parse(slurp(kDir + "/" + tag + "/r" + std::to_string(n) + "/struts_under.json"), "struts_under.json");
            for (const sj::Value& st : sj::find(su, "struts")->arr) {
              const double w = sj::find(st, "width_max_mm")->num;
              *widest = std::max(*widest, w);
              if (!(w > limit + 1e-6)) continue;
              ++*over;
              ++over_here;
              const auto& a = sj::find(st, "at")->arr;
              bool named_here = false;
              for (const auto& q : named) named_here = named_here || std::hypot(a[0].num - q[0], std::hypot(a[1].num - q[1], a[2].num - q[2])) <= 1.0;
              *over_named += named_here;
            }
          }
          if (over_past && static_cast<double>(over_here) > past_so_far) *over_past += over_here;   // more than were named
          const sj::Value* p = paths_of(rs[n]);
          const sj::Value* past = p ? sj::find(*p, "past_limit") : nullptr;
          if (past) past_so_far += sj::find(*past, "struts")->num;
          if (past) for (const sj::Value& q : sj::find(*past, "at")->arr) named.push_back({q.arr[0].num, q.arr[1].num, q.arr[2].num});
        }
      };
      // The order on the many-strut block, three rounds: per round thickened within the limit, given a vine, a brace,
      // no_room, past the limit; no strut over the limit unless named past it in an earlier round.
      {
        const OrganicStrengthenResult od = strengthen("order", roomy, 6000.0, "{\"strengthen_rounds\": 3}");
        const std::vector<sj::Value> rs = rounds_of("order");
        for (std::size_t n = 0; n < rs.size(); ++n) {
          const sj::Value* p = paths_of(rs[n]);
          const sj::Value* st = sj::find(rs[n], "struts");
          std::printf("[order] round %zu: under safety %.0f, lattice %.1f mm3", n, num(st, "under_safety"), num(&rs[n], "lattice_mm3"));
          if (p) {
            const sj::Value* past = sj::find(*p, "past_limit");
            std::printf("; within the limit %.0f, vine %.0f, brace %.0f, no_room %.0f, waiting %.0f, out of vines %.0f, past the limit %.0f (widest %.3f)",
                        num(p, "within_limit"), num(p, "at_limit_vine"), num(p, "at_limit_brace"), num(p, "at_limit_no_room"),
                        num(p, "waiting"), num(p, "out_of_vines"), num(past, "struts"), num(past, "widest_mm"));
          }
          const sj::Value* vr = sj::find(rs[n], "vine_results");
          if (vr) {
            std::size_t rose = 0;
            for (const sj::Value& v : vr->arr) rose += sj::find(v, "after")->is_number() && sj::find(v, "after")->num > sj::find(v, "before")->num;
            std::printf("; last round's vines %zu, their strut stronger %zu", vr->arr.size(), rose);
          }
          std::printf("\n");
        }
        std::size_t over = 0, over_named = 0, over_past = 0;
        double widest = 0.0;
        widths_ok("order", &over, &over_named, &widest, &over_past);
        // A strut's middle moves when a vine or brace cuts it, and at most 20 places are listed a round: so the count is
        // held, a round's struts over the limit never more than the struts named past it in the rounds before.
        std::printf("[order] watched struts over the limit %zu (at a listed place %zu), rounds with more over it than named %zu; widest %.3f\n",
                    over, over_named, over_past, widest);
        CHECK(od.ok && od.old_bars_kept && !rs.empty() && paths_of(rs[0]) && num(paths_of(rs[0]), "at_limit_vine") > 0);
        CHECK(over_past == 0 && widest <= 2.0 * limit + 1e-6);
        // Walled-in struts (round 0: no vine could land): widened past the limit, counted, with places.
        const sj::Value* p0 = paths_of(rs[0]);
        const sj::Value* past0 = sj::find(*p0, "past_limit");
        std::printf("[order walled] round 0: no_room %.0f, past the limit %.0f (widest %.3f, places %zu)\n", num(p0, "at_limit_no_room"),
                    num(past0, "struts"), num(past0, "widest_mm"), sj::find(*past0, "at")->arr.size());
        CHECK(num(p0, "at_limit_no_room") > 0 && num(past0, "struts") >= num(p0, "at_limit_no_room") && num(past0, "widest_mm") > limit &&
              sj::find(*past0, "at")->arr.size() == std::min<std::size_t>(20, static_cast<std::size_t>(num(past0, "struts"))));
      }
      // One strut needing more than the limit: widened to the limit AND given a vine in the same round (round 1's check:
      // the strut no wider than the limit; the vine as wide).
      {
        const OrganicStrengthenResult o1 = strengthen("order_one", roomy, 6000.0,
            "{\"strengthen_rounds\": 1, \"strengthen_paths_max\": 1, \"strengthen_path_brace_min_mm\": 100}");
        const std::vector<sj::Value> rs = rounds_of("order_one");
        const sj::Value* p = rs.empty() ? nullptr : paths_of(rs[0]);
        std::size_t over = 0, over_named = 0;
        double widest = 0.0;
        widths_ok("order_one", &over, &over_named, &widest);
        std::printf("[order one] handed %.0f, vine %.0f, within the limit %.0f, waiting %.0f; round 1 widest watched strut %.3f (limit %.1f)\n",
                    num(p, "struts_handed"), num(p, "at_limit_vine"), num(p, "within_limit"), num(p, "waiting"), widest, limit);
        CHECK(o1.ok && o1.old_bars_kept && num(p, "struts_handed") == 1 && num(p, "at_limit_vine") == 1 && over == 0);
        // Replay: the file job given round 1's strengthened.json lays round 1's bars.
        std::string j = file_job(f, roomy, "octet", "");
        j.replace(j.find("\"layout\""), 8, "\"tensor\": \"stress.tensor\", \"strengthened\": \"order_one/r1/strengthened.json\", \"layout\"");
        write(kDir + "/order_replay_job.json", j);
        std::filesystem::remove_all(kDir + "/order_replay");
        std::filesystem::create_directories(kDir + "/order_replay");
        const FileResult rr = run_file_job(kDir + "/order_replay_job.json", kDir + "/order_replay");
        const double bars1 = num(&rs.back(), "bars");
        std::printf("[order replay] ok %d bars %zu (round 1: %.0f)\n", rr.ok, rr.bars, bars1);
        CHECK(rr.ok && static_cast<double>(rr.bars) == bars1);
      }
      // Leg I (OS18b): the struts' classes and the landings. Joint landing on (0.5 spacings, the default): landings moved
      // to a joint, every old bar kept, round 1's classes add up to its judged struts and its under-1.5 count; joint
      // landing off (0): none moved, as the order before.
      {
        const OrganicStrengthenResult sn = strengthen("snap", roomy, 6000.0, "{\"strengthen_rounds\": 1}");
        const std::vector<sj::Value> rs = rounds_of("snap");
        const sj::Value* p = rs.empty() ? nullptr : paths_of(rs[0]);
        const sj::Value* cls = rs.size() > 1 ? sj::find(rs[1], "classes") : nullptr;
        const sj::Value* lands = rs.size() > 1 ? sj::find(rs[1], "landings") : nullptr;
        double judged = 0.0, under = 0.0;
        if (cls)
          for (const char* k : {"untouched", "cut", "brace", "vine"}) {
            judged += num(sj::find(*cls, k), "judged");
            under += num(sj::find(*cls, k), "under");
          }
        std::printf("[snap] round 0: landings at a joint %.0f, a move dropped (it broke a rule) %.0f, vines %.0f; round 1: classes judged %.0f "
                    "(struts judged %.0f), under %.0f (under safety %.0f), under only because of new pieces %.0f; landings %.0f, within 0.15 "
                    "of a joint %.0f, landed-on worse %.0f\n", num(p, "landings_at_a_joint"), num(p ? sj::find(*p, "dropped") : nullptr, "snap_broke_a_rule"),
                    num(p, "relief_vines"), judged, num(sj::find(rs[1], "struts"), "judged"), under, num(sj::find(rs[1], "struts"), "under_safety"),
                    num(cls, "under_only_because_of_new_pieces"), num(lands, "count"), num(lands, "within_0_15_of_a_joint"), num(lands, "landed_on_worse"));
        CHECK(sn.ok && sn.old_bars_kept && num(p, "landings_at_a_joint") > 0 && cls && lands &&
              judged == num(sj::find(rs[1], "struts"), "judged") && under == num(sj::find(rs[1], "struts"), "under_safety") &&
              num(lands, "within_0_15_of_a_joint") > 0);
        const OrganicStrengthenResult so = strengthen("snap_off", roomy, 6000.0, "{\"strengthen_rounds\": 1, \"strengthen_path_snap_spacings\": 0}");
        const std::vector<sj::Value> ro = rounds_of("snap_off");
        const sj::Value* po = ro.empty() ? nullptr : paths_of(ro[0]);
        std::printf("[snap off] landings at a joint %.0f, vines %.0f\n", num(po, "landings_at_a_joint"), num(po, "relief_vines"));
        CHECK(so.ok && num(po, "landings_at_a_joint") == 0 && num(po, "relief_vines") > 0);
      }
      // The per-strut limit (1): no place gets a second vine; a strut still under the safety factor after its vine is
      // out of vines and goes past the limit.
      {
        const OrganicStrengthenResult op = strengthen("order_per", roomy, 6000.0,
            "{\"strengthen_rounds\": 3, \"strengthen_paths_per_strut\": 1, \"strengthen_path_brace_min_mm\": 100}");
        const std::vector<sj::Value> rs = rounds_of("order_per");
        std::vector<std::array<double, 3>> at;
        std::size_t again = 0;
        double out_of = 0.0, past_n = 0.0;
        for (const sj::Value& r : rs) {
          const sj::Value* p = paths_of(r);
          if (!p) continue;
          out_of += std::max(0.0, num(p, "out_of_vines"));
          past_n += std::max(0.0, num(sj::find(*p, "past_limit"), "struts"));
          for (const sj::Value& v : sj::find(*p, "vines_at")->arr) {
            const auto& a = sj::find(v, "at")->arr;
            for (const auto& q : at) again += std::hypot(a[0].num - q[0], std::hypot(a[1].num - q[1], a[2].num - q[2])) < 0.25;
            at.push_back({a[0].num, a[1].num, a[2].num});
          }
        }
        std::printf("[order per strut 1] vines %zu, a place given a second %zu; out of vines %.0f, past the limit %.0f\n", at.size(), again,
                    out_of, past_n);
        CHECK(op.ok && op.old_bars_kept && !at.empty() && again == 0 && past_n >= out_of);
      }
    }
  }

  // ── §12 (brief E4, item 2) the solid's weak spots, on made notched bars 40 x 10 x 12 (held on the x = 0 end, pulled
  // along x on the x = 40 end, an Organic weave 2 mm deep under the bottom face): one notch from the top gives one spot
  // at the notch, two notches two spots; a light load none; the plain text in each case.
  {
    // A closed mesh of the cells of a grid (x breaks, y 0..10, z breaks 0, 6, 12) less the cells named open.
    const auto notched = [](const std::vector<double>& xs, const std::vector<int>& open_x) {
      const std::vector<double> ys{0, 10}, zs{0, 6, 12};
      const int NX = static_cast<int>(xs.size()) - 1, NZ = 2;
      const auto full = [&](int i, int k) {
        if (i < 0 || i >= NX || k < 0 || k >= NZ) return false;
        return !(k == 1 && std::find(open_x.begin(), open_x.end(), i) != open_x.end());
      };
      TriangleMesh m;
      const auto vid = [&](int i, int j, int k) { return (k * 2 + j) * static_cast<int>(xs.size()) + i; };
      for (int k = 0; k < 3; ++k)
        for (int j = 0; j < 2; ++j)
          for (std::size_t i = 0; i < xs.size(); ++i) m.vertices.push_back({xs[i], ys[static_cast<std::size_t>(j)], zs[static_cast<std::size_t>(k)]});
      const auto quad = [&](int a, int b, int c, int d) {   // counter-clockwise seen from outside
        m.triangles.push_back({a, b, c});
        m.triangles.push_back({a, c, d});
      };
      for (int i = 0; i < NX; ++i)
        for (int k = 0; k < NZ; ++k) {
          if (!full(i, k)) continue;
          quad(vid(i, 0, k), vid(i + 1, 0, k), vid(i + 1, 0, k + 1), vid(i, 0, k + 1));          // y = 0
          quad(vid(i, 1, k), vid(i, 1, k + 1), vid(i + 1, 1, k + 1), vid(i + 1, 1, k));          // y = 10
          if (!full(i - 1, k)) quad(vid(i, 0, k), vid(i, 0, k + 1), vid(i, 1, k + 1), vid(i, 1, k));   // -x
          if (!full(i + 1, k)) quad(vid(i + 1, 0, k), vid(i + 1, 1, k), vid(i + 1, 1, k + 1), vid(i + 1, 0, k + 1));   // +x
          if (!full(i, k - 1)) quad(vid(i, 0, k), vid(i, 1, k), vid(i + 1, 1, k), vid(i + 1, 0, k));   // -z
          if (!full(i, k + 1)) quad(vid(i, 0, k + 1), vid(i + 1, 0, k + 1), vid(i + 1, 1, k + 1), vid(i, 1, k + 1));   // +z
        }
      return m;
    };
    write_stl_file(kDir + "/notch1.stl", notched({0, 18, 22, 40}, {1}), StlFormat::Binary);
    write_stl_file(kDir + "/notch2.stl", notched({0, 10, 14, 26, 30, 40}, {1, 3}), StlFormat::Binary);
    TensorField tf;
    tf.spacing = 1.0;
    tf.nx = 40; tf.ny = 10; tf.nz = 12;
    tf.voigt.assign(6 * 40 * 10 * 12, 0.0);
    for (std::size_t e = 0; e < 40 * 10 * 12; ++e) { tf.voigt[6 * e] = 3.0; tf.voigt[6 * e + 2] = 1.0; }
    CHECK(write_tensor_file(kDir + "/notch.tensor", tf));
    const auto face_at = [](const StepModel& m, Vec3 n, double off) {
      for (int fi = 0; fi < m.face_count; ++fi) {
        const StepFaceInfo& x = m.faces[static_cast<std::size_t>(fi)];
        if (x.kind == StepSurfaceKind::Plane && x.plane_normal.x * n.x + x.plane_normal.y * n.y + x.plane_normal.z * n.z > 0.99 &&
            std::fabs(x.plane_origin.x * n.x + x.plane_origin.y * n.y + x.plane_origin.z * n.z - off) < 1e-6)
          return fi;
      }
      return -1;
    };
    // The solid's block of a run of `model` pulled with `newtons` at `infill` %, with `settings` (strength_settings).
    const auto spots_run = [&](const std::string& tag, const std::string& model, double newtons, double infill,
                               const std::string& settings, const std::string& print = "") {
      const StepModel m = import_part_file_resolved(kDir + "/" + model);
      const int held = face_at(m, {-1, 0, 0}, 0.0), pulled = face_at(m, {1, 0, 0}, 40.0), bottom = face_at(m, {0, 0, -1}, 0.0);
      CHECK(held >= 0 && pulled >= 0 && bottom >= 0);
      const std::string fj =
          "{\"mode\": \"lattice_file\", \"model\": \"" + model + "\", \"output\": \"notch_lattice.stl\", \"strength_job\": \"" +
          tag + "_sj.json\", \"tensor\": \"notch.tensor\", \"layout\": {\"min_strut_lines\": 2, \"region_ids\": [1], "
          "\"region_no_lattice\": [0], \"region_depth_mm\": [2], \"region_expand_mm\": [-2], \"region_face_counts\": [1], "
          "\"region_faces\": [" + std::to_string(bottom) + "], \"topology\": \"octet\", \"algorithm\": \"uniform\", "
          "\"cell_max_mm\": 8, \"min_cells_across\": 1, \"region_weave\": [true], \"organic_spacing_mm\": 4, "
          "\"organic_width_mm\": 0.9}}";
      char inf[32];
      std::snprintf(inf, sizeof inf, "%g", infill);
      const std::string sj =
          "{\"model\": \"" + model + "\", \"material\": \"PLA\", \"mode\": \"lattice_part\", \"resolution\": 40, "
          "\"loads\": {\"minimize_plastic\": true, \"safety_margin\": 1.5, \"build_dir\": [0, 0, 1], \"infill_percent\": " +
          std::string(inf) + print + ", \"anchor_face_ids\": [" + std::to_string(held) + "], \"groups\": [{\"face_ids\": [" +
          std::to_string(pulled) + "], \"force\": [" + std::to_string(newtons) + ", 0, 0]}]}, "
          "\"lattice\": {\"topology\": \"octet\", \"require_lattice_void_reaches_exterior\": false}, "
          "\"grading\": {\"topology\": \"octet\", \"cell_mm\": 8, \"min_extrudable_width_mm\": 0.45, \"intent\": \"structural\"}, "
          "\"output\": {\"report\": \"report.json\", \"mesh_format\": \"stl\", \"mesh_prefix\": \"variant\"}, "
          "\"strength_settings\": " + settings + "}";
      write(kDir + "/" + tag + "_sj.json", sj);
      const Run x = run(tag, fj, "");
      CHECK(x.r.ok && x.r.strength_ran);
      const std::string b = block(x.json);
      const std::size_t a0 = b.find("\"solid_margin\": {");
      const std::size_t a1 = b.find("\n    \"margin_worst_case\"", a0);
      const std::string sm = a0 == std::string::npos ? std::string() : b.substr(a0, a1 - a0);
      std::printf("[%s] %s\n", tag.c_str(), sm.substr(0, 1500).c_str());
      return sm;
    };
    const std::string off = "{\"width_aware_knockdown\": false}";
    // A probe load; the margins are linear in it, so the loads below are set from it.
    const std::string probe = spots_run("notch_probe", "notch1.stl", 1000.0, 50.0, off);
    const double eff0 = num_after(probe, "effective"), raw0 = num_after(probe, "worst_case");
    CHECK(eff0 > 0.0 && raw0 > 0.0);
    // One notch, the worst place at 1.2 of effective margin (under 1.5): one spot, at the notch.
    const std::string one = spots_run("notch_one", "notch1.stl", 1000.0 * eff0 / 1.2, 50.0, off);
    CHECK(num_after(one, "spots_total") == 1.0);
    const double wx = num_after(one, "worst_at");
    {
      const std::size_t w = one.find("\"worst_at\": [");
      const double x = w == std::string::npos ? -1.0 : std::strtod(one.c_str() + w + 13, nullptr);
      std::printf("[notch_one] worst at x %.3g\n", x);
      CHECK(x > 16.0 && x < 24.0);   // at the notch (18 to 22)
    }
    (void)wx;
    CHECK(has(one, "\"kind\": \"inside_the_solid\"") && has(one, "\"advice\": \"Make this part of the model thicker, or print it denser.\""));
    const std::size_t sp1 = one.find("\"spots\": [");
    CHECK(sp1 != std::string::npos && num_after(one, "passes_at_infill_percent", sp1) == num_after(one, "passes_at_infill_percent"));
    CHECK(num_after(one, "effective_margin") == num_after(one, "effective"));   // the worst spot's worst voxel IS the solid's margin
    CHECK(has(one, "\"governs\": \"in_plane\"") && has(one, "\"passes_with_walls_credited\": "));
    CHECK(has(one, "\"field\": {\"file\": \"fields.bin\", \"block\": 2"));
    {
      char want[200];
      std::snprintf(want, sizeof want, "\"text\": \"The solid part does not certify at 50 %% infill. It would certify at %.0f %% infill. "
                    "The other way is to strengthen the marked area.\"", num_after(one, "passes_at_infill_percent"));
      CHECK(has(one, want));
    }
    // fields.bin's second block: the solid's effective margin per voxel; its least is the solid's margin.
    {
      const std::string fb = slurp(kDir + "/notch_one/fields.bin");
      std::int32_t dims[3], count = 0;
      std::memcpy(dims, fb.data() + 4, 12);
      std::memcpy(&count, fb.data() + 56, 4);
      const std::size_t nv = static_cast<std::size_t>(dims[0]) * dims[1] * dims[2];
      const std::size_t nn = static_cast<std::size_t>(dims[0] + 1) * (dims[1] + 1) * (dims[2] + 1);
      const std::size_t b2 = 64 + 48 + 4 * nv + 4 * 3 * nn;   // after the header and the first block
      CHECK(count == 2 && fb.size() == b2 + 48 + 4 * nv);
      double marker = 0.0;
      std::int64_t n = 0;
      std::memcpy(&marker, fb.data() + b2, 8);
      std::memcpy(&n, fb.data() + b2 + 24, 8);
      float least = std::numeric_limits<float>::infinity();
      for (std::size_t e = 0; e < nv && fb.size() >= b2 + 48 + 4 * nv; ++e) {
        float v;
        std::memcpy(&v, fb.data() + b2 + 48 + 4 * e, 4);
        if (!std::isnan(v)) least = std::min(least, v);
      }
      std::printf("[notch_one] fields.bin block 2: marker %g, %lld values, least %.6g\n", marker, static_cast<long long>(n), least);
      CHECK(marker == -1.0 && n == static_cast<std::int64_t>(nv));
      CHECK(std::fabs(least - num_after(one, "effective")) <= 1e-5 * num_after(one, "effective"));
    }
    // A light load: the solid certifies; no spots, no text.
    const std::string light2 = spots_run("notch_light", "notch1.stl", 1000.0 * eff0 / 3.0, 50.0, off);
    CHECK(!has(light2, "\"spots\"") && !has(light2, "\"text\"") && !has(light2, "spots_total") && has(light2, "\"field\": {"));
    // Two notches: two spots, one at each; with one shown: "the 1 worst of 2 marked areas".
    const std::string probe2 = spots_run("notch2_probe", "notch2.stl", 1000.0, 50.0, off);
    const double eff2 = num_after(probe2, "effective");
    const std::string two = spots_run("notch_two", "notch2.stl", 1000.0 * eff2 / 1.2, 50.0, off);
    CHECK(num_after(two, "spots_total") == 2.0 && has(two, "strengthen the 2 marked areas."));
    {
      std::vector<double> xs;
      for (std::size_t w = two.find("\"worst_at\": ["); w != std::string::npos; w = two.find("\"worst_at\": [", w + 1))
        xs.push_back(std::strtod(two.c_str() + w + 13, nullptr));
      std::sort(xs.begin(), xs.end());
      CHECK(xs.size() == 2 && xs.size() == 2 && xs[0] > 8 && xs[0] < 16 && xs[1] > 24 && xs[1] < 32);
    }
    const std::string two1 = spots_run("notch_two_one", "notch2.stl", 1000.0 * eff2 / 1.2, 50.0,
                                       "{\"width_aware_knockdown\": false, \"solid_spots_max\": 1}");
    CHECK(num_after(two1, "spots_total") == 2.0 && has(two1, "strengthen the 1 worst of 2 marked areas."));
    // No infill certifies it (the worst place at 1.0 of margin printed solid).
    const std::string heavy2 = spots_run("notch_heavy", "notch1.stl", 1000.0 * raw0 / 1.0, 50.0, off);
    {
      const double n = num_after(heavy2, "spots_total");
      CHECK(n >= 1.0 && has(heavy2, "\"text\": \"The solid part does not certify, even printed solid. Strengthen the " +
                                        (n == 1.0 ? std::string("marked area.") : std::to_string(static_cast<int>(n)) + " marked areas.") + "\""));
    }
    CHECK(has(heavy2, "\"passes_at_infill_percent\": null"));
    // At 20 % infill with two 0.45 mm walls and the walls not credited: crediting them certifies it, said once.
    const std::string walls_print = ", \"wall_loops\": 2, \"wall_line_width_mm\": 0.45";
    const std::string wprobe = spots_run("notch_wprobe", "notch1.stl", 1000.0, 20.0, off, walls_print);
    const double effw = num_after(wprobe, "effective");
    const std::string walls = spots_run("notch_walls", "notch1.stl", 1000.0 * effw / 1.2, 20.0, off, walls_print);
    CHECK(has(walls, "\"passes_with_walls_credited\": true") && has(walls, " Counting the printed walls as solid, it certifies.\""));
    // Brief E4, item 5: the walls are credited by default. The same bar and load, the setting not stated: it certifies
    // (no spots, no text); at a load where even with the walls it does not, the text says nothing about walls.
    const std::string wdef = spots_run("notch_walls_default", "notch1.stl", 1000.0 * effw / 1.2, 20.0, "{}", walls_print);
    std::printf("[walls default] effective %.6g, off %.6g\n", num_after(wdef, "effective"), num_after(walls, "effective"));
    CHECK(num_after(wdef, "effective") >= 1.5 && num_after(walls, "effective") < 1.5 && !has(wdef, "\"spots\"") && !has(wdef, "\"text\""));
    const double effon = num_after(spots_run("notch_won_probe", "notch1.stl", 1000.0, 20.0, "{}", walls_print), "effective");
    const std::string won = spots_run("notch_walls_on", "notch1.stl", 1000.0 * effon / 1.2, 20.0, "{}", walls_print);
    CHECK(num_after(won, "spots_total") >= 1.0 && has(won, "\"text\": ") && !has(won, "Counting the printed walls") &&
          has(won, "\"passes_with_walls_credited\": false"));
    // The sentences alone.
    CHECK(organic_solid_text(50, 81, false, 3, 3) ==
          "The solid part does not certify at 50 % infill. It would certify at 81 % infill. The other way is to strengthen "
          "the 3 marked areas.");
    CHECK(organic_solid_text(50, -1, false, 3, 3) == "The solid part does not certify, even printed solid. Strengthen the 3 marked areas.");
    CHECK(organic_solid_text(50, 81, true, 1, 1) ==
          "The solid part does not certify at 50 % infill. It would certify at 81 % infill. The other way is to strengthen "
          "the marked area. Counting the printed walls as solid, it certifies.");
    CHECK(organic_solid_text(37.5, 90, false, 20, 57) ==
          "The solid part does not certify at 37.5 % infill. It would certify at 90 % infill. The other way is to strengthen "
          "the 20 worst of 57 marked areas.");
  }

  // ── §13 (brief E4, item 5) Install 3's cube verdict credits the walls by default too: the light job's block at 20 %
  // infill with two 0.45 mm walls, under the load at which the walls NOT credited leave the solid at 1.2 of margin:
  // not stated, the setting is on (echoed) and the block is accepted; stated off, it fails on the solid's margin.
  {
    const auto at20 = [&](double newtons, const std::string& settings) {
      std::string j = strength_job(f, newtons, "lattice_part", "block.stl", -1, settings);
      j.replace(j.find("\"minimize_plastic\": true,"), 25,
                "\"minimize_plastic\": true, \"infill_percent\": 20, \"wall_loops\": 2, \"wall_line_width_mm\": 0.45,");
      return j;
    };
    const double N = 20.0 * num_after(lb, "margin_worst_case") * std::pow(0.2, 1.5) / 1.2;
    const std::string on = block(run("cube_walls_default", file_job(f, ""), at20(N, "")).json);
    const std::string off = block(run("cube_walls_off", file_job(f, ""), at20(N, "{\"width_aware_knockdown\": false}")).json);
    std::printf("[cube walls] %.4g N: default %s / off %s\n", N, on.substr(on.find("\"verdict\""), 40).c_str(),
                off.substr(off.find("\"verdict\""), 60).c_str());
    CHECK(has(on, "\"width_aware_knockdown\": true") && has(off, "\"width_aware_knockdown\": false"));
    CHECK(has(on, "\"accepted\": true") && !has(on, "\"fail_reason\": \"solid_margin\""));
    CHECK(has(off, "\"accepted\": false") && has(off, "\"fail_reason\": \"solid_margin\""));
  }

  // ── §14 (brief E4 leg 2, rule OS16) the strengthen job judges the bars the file writes. A made 40 x 10 x 20 block, the
  // weave 14 mm deep under its top face, the stress running round an axis 25 mm above the top (along y): its strands
  // are arches turned upside down, each dipping to a low point that would start in mid-air, which the print check
  // props with a leg (a sag); held on its bottom, pushed down on its x = 40 end. organic-strengthen (additive, one
  // round) and then the file job replaying its last additions: the last check of the one and the check of the other
  // agree strut for strut.
  {
    write_stl_file(kDir + "/pocket.stl", box(40, 10, 20), StlFormat::Binary);
    const StepModel pmodel = import_part_file_resolved(kDir + "/pocket.stl");
    const int wall = face_with_normal(pmodel, 0, 0, 1), bottom = face_with_normal(pmodel, 0, 0, -1),
              end = face_with_normal(pmodel, 1, 0, 0);
    CHECK(wall >= 0 && bottom >= 0 && end >= 0);
    {
      TensorField hf;
      hf.spacing = 0.5;
      hf.nx = 80; hf.ny = 20; hf.nz = 40;
      hf.voigt.assign(6 * static_cast<std::size_t>(hf.nx) * hf.ny * hf.nz, 0.0);
      for (int k = 0; k < hf.nz; ++k)
        for (int j = 0; j < hf.ny; ++j)
          for (int i = 0; i < hf.nx; ++i) {
            const double x = (i + 0.5) * hf.spacing - 20.0, z = (k + 0.5) * hf.spacing - 45.0, r = std::hypot(x, z);
            const double rx = x / r, rz = z / r, tx = -rz, tz = rx;
            double* v = &hf.voigt[6 * hf.index(i, j, k)];
            v[0] = 10 * tx * tx + rx * rx;
            v[1] = 1.0;
            v[2] = 10 * tz * tz + rz * rz;
            v[5] = 10 * tz * tx + rz * rx;
          }
      CHECK(write_tensor_file(kDir + "/pocket.tensor", hf));
    }
    const auto pocket_job = [&](const std::string& strengthened) {
      return "{\"mode\": \"lattice_file\", \"model\": \"pocket.stl\", \"output\": \"pocket_lattice.stl\", \"tensor\": \"pocket.tensor\", "
             "\"strength_job\": \"pocket_sj.json\"" + (strengthened.empty() ? std::string() : ", \"strengthened\": \"" + strengthened + "\"") +
             ", \"layout\": {\"region_ids\": [1], \"region_no_lattice\": [0], \"region_depth_mm\": [14], \"region_expand_mm\": [-2], "
             "\"region_face_counts\": [1], \"region_faces\": [" + std::to_string(wall) + "], \"region_weave\": [true], "
             "\"organic_spacing_min_mm\": 3, \"organic_spacing_max_mm\": 5, \"organic_width_mm\": 0.9, \"organic_width_heavy_mm\": 1.8}}";
    };
    const auto pocket_sj = [&](double newtons, const std::string& settings) {
      return "{\"model\": \"pocket.stl\", \"material\": \"PLA\", \"mode\": \"lattice_part\", \"resolution\": 40, "
             "\"loads\": {\"minimize_plastic\": true, \"safety_margin\": 1.5, \"build_dir\": [0, 0, 1], \"anchor_face_ids\": [" +
             std::to_string(bottom) + "], \"groups\": [{\"face_ids\": [" + std::to_string(end) + "], \"force\": [0, 0, " +
             std::to_string(-newtons) + "]}]}, \"lattice\": {\"topology\": \"octet\", \"require_lattice_void_reaches_exterior\": false}, "
             "\"grading\": {\"topology\": \"octet\", \"cell_mm\": 8, \"min_extrudable_width_mm\": 0.45, \"intent\": \"structural\"}, "
             "\"output\": {\"report\": \"report.json\", \"mesh_format\": \"stl\", \"mesh_prefix\": \"variant\"}, \"strength_settings\": " +
             settings + "}";
    };
    // A probe: the file job at 100 N; the struts' margins are linear in the load, so the load below puts the weakest at 0.8.
    write(kDir + "/pocket_sj.json", pocket_sj(100.0, "{}"));
    const Run probe = run("pocket_probe", pocket_job(""), "");
    const std::string pb = block(probe.json);
    const double m100 = num_after(pb, "smallest_margin");
    std::printf("[pocket] probe: smallest strut margin %.6g at 100 N; sags lifted %zu, legs %zu, left out at %zu places, posts %zu, "
                "mid-air starts found per pass %d\n", m100, probe.r.made.sags.lifted, probe.r.made.sags.legs,
                probe.r.made.left_out_at.size(), probe.r.made.posts.size(),
                probe.r.made.found_per_pass.empty() ? -1 : probe.r.made.found_per_pass.front());
    // The print check changes the bars here (a sag lifted or propped), and finds something to answer (a mid-air start).
    CHECK(probe.r.made.sagged != nullptr && probe.r.made.sags.changed());
    std::printf("[pocket] mid-air starts and one-ended overhangs found on the first pass: %d\n",
                probe.r.made.found_per_pass.empty() ? -1 : probe.r.made.found_per_pass.front());
    CHECK(m100 > 0.0);
    const double load = 100.0 * m100 / 0.8;
    write(kDir + "/pocket_sj.json", pocket_sj(load, "{\"strengthen_rounds\": 1}"));
    write(kDir + "/pocket_strengthen_job.json", pocket_job(""));
    std::filesystem::remove_all(kDir + "/pocket_strengthen");
    std::filesystem::create_directories(kDir + "/pocket_strengthen");
    const OrganicStrengthenResult ps = run_organic_strengthen(kDir + "/pocket_strengthen_job.json", kDir + "/pocket_strengthen", 0,
                                                              MATERIALS_JSON_PATH, SETTINGS_RULES_PATH);
    const std::string psj = slurp(kDir + "/pocket_strengthen/strengthen.json");
    std::printf("[pocket strengthen] ok %d code %s rounds %d %s %s\n", ps.ok, ps.code.c_str(), ps.rounds_fixed, ps.why.c_str(),
                ps.detail.c_str());
    CHECK(ps.ok && ps.rounds_fixed >= 1 && has(psj, "\"print_check\": "));
    if (ps.ok && ps.rounds_fixed >= 1) {
      const int last = ps.rounds_fixed;   // its last check, of the bars after the last round's additions and print check
      const std::string lastdir = kDir + "/pocket_strengthen/r" + std::to_string(last);
      const Run rep = run("pocket_replay", pocket_job("pocket_strengthen/r" + std::to_string(last) + "/strengthened.json"), "");
      CHECK(rep.r.ok && rep.r.strength_ran);
      const std::string a = slurp(lastdir + "/strength.json"), b = block(rep.json);
      const double ja = num_after(a, "judged"), jb = num_after(b, "judged"), sa = num_after(a, "smallest_margin"),
                   sb = num_after(b, "smallest_margin"), ua = num_after(a, "under_safety"), ub = num_after(b, "under_safety");
      std::printf("[pocket] strengthen's last check: judged %.0f, smallest %.12g, under %.0f; the file's: judged %.0f, smallest %.12g, under %.0f\n",
                  ja, sa, ua, jb, sb, ub);
      CHECK(ja == jb && ua == ub && std::fabs(sa - sb) <= 1e-9 * std::fabs(sa));
      // Strut for strut: every bar's margin (strut_margins.bin, one per bar of the bars the file is made of) the same.
      const std::string ma = slurp(lastdir + "/strut_margins.bin"), mb = slurp(rep.out + "/strut_margins.bin");
      std::size_t differ = 0, under_a = 0, under_b = 0;
      for (std::size_t i = 0; i + 4 <= ma.size() && ma.size() == mb.size(); i += 4) {
        float x, y;
        std::memcpy(&x, ma.data() + i, 4);
        std::memcpy(&y, mb.data() + i, 4);
        // The same struts judged, the same under the margin, each margin the same to float32's last places (the two
        // solves sum in another order: 1e-7 apart).
        differ += std::isnan(x) != std::isnan(y) || (x < 1.5f) != (y < 1.5f) ||
                  (!std::isnan(x) && x < 1e6f && std::fabs(x - y) > 1e-5f * std::fabs(x));   // above 1e6: an unstressed strut, noise
        under_a += x < 1.5f;
        under_b += y < 1.5f;
      }
      std::printf("[pocket] strut_margins.bin: %zu bars each (%zu), %zu differ; under the margin %zu and %zu\n", ma.size() / 4,
                  mb.size() / 4, differ, under_a, under_b);
      CHECK(!ma.empty() && ma.size() == mb.size() && differ == 0 && under_a == under_b);
    }
    // ── §15 (OS16 amended, the lead's ruling of 2026-11-19) the print check after a round does what it does after a lay
    // (leaves out, moves, props) and the job goes on; each round counts what it did among the bars that were there
    // before the round, and its hash is of the bars after it, so the file job replays to it. A column 10 x 10 x 20 with
    // an arm 20 mm long standing out of it 12 mm above the bed; the weave 6 mm deep under the arm's underside, open
    // there: its strands meet the underside in mid-air and the print check leaves some out. Held on the bed, the arm's
    // end pushed down; organic-strengthen (additive, two rounds), then the file job given its last round.
    {
      write_stl_file(kDir + "/arm.stl", cells_mesh({0, 10, 30}, {0, 10}, {0, 12, 20}, [](int i, int, int k) { return i == 0 || k == 1; }),
                     StlFormat::Binary);
      const StepModel amodel = import_part_file_resolved(kDir + "/arm.stl");
      const int under = face_at(amodel, 0, 0, -1, -12.0), floor = face_at(amodel, 0, 0, -1, 0.0), tip = face_at(amodel, 1, 0, 0, 30.0);
      CHECK(under >= 0 && floor >= 0 && tip >= 0);
      std::filesystem::copy_file(kDir + "/pocket.tensor", kDir + "/arm.tensor", std::filesystem::copy_options::overwrite_existing);
      const auto arm_job = [&](const std::string& strengthened) {
        return "{\"mode\": \"lattice_file\", \"model\": \"arm.stl\", \"output\": \"arm_lattice.stl\", \"tensor\": \"arm.tensor\", "
               "\"strength_job\": \"arm_sj.json\"" + (strengthened.empty() ? std::string() : ", \"strengthened\": \"" + strengthened + "\"") +
               ", \"layout\": {\"region_ids\": [1], \"region_no_lattice\": [0], \"region_depth_mm\": [6], \"region_expand_mm\": [0], "
               "\"region_face_counts\": [1], \"region_faces\": [" + std::to_string(under) + "], \"region_weave\": [true], "
               "\"organic_spacing_min_mm\": 3, \"organic_spacing_max_mm\": 5, \"organic_width_mm\": 0.9, \"organic_width_heavy_mm\": 1.8}}";
      };
      const auto arm_sj = [&](double newtons, const std::string& settings) {
        return "{\"model\": \"arm.stl\", \"material\": \"PLA\", \"mode\": \"lattice_part\", \"resolution\": 40, "
               "\"loads\": {\"minimize_plastic\": true, \"safety_margin\": 1.5, \"build_dir\": [0, 0, 1], \"anchor_face_ids\": [" +
               std::to_string(floor) + "], \"groups\": [{\"face_ids\": [" + std::to_string(tip) + "], \"force\": [0, 0, " +
               std::to_string(-newtons) + "]}]}, \"lattice\": {\"topology\": \"octet\", \"require_lattice_void_reaches_exterior\": false}, "
               "\"grading\": {\"topology\": \"octet\", \"cell_mm\": 8, \"min_extrudable_width_mm\": 0.45, \"intent\": \"structural\"}, "
               "\"output\": {\"report\": \"report.json\", \"mesh_format\": \"stl\", \"mesh_prefix\": \"variant\"}, \"strength_settings\": " +
               settings + "}";
      };
      write(kDir + "/arm_sj.json", arm_sj(100.0, "{}"));
      const Run ap = run("arm_probe", arm_job(""), "");
      const double am = num_after(block(ap.json), "smallest_margin");
      std::printf("[arm] probe: smallest strut margin %.6g at 100 N; the print check left struts out at %zu places\n", am,
                  ap.r.made.left_out_at.size());
      CHECK(ap.r.ok && am > 0.0 && !ap.r.made.left_out_at.empty());
      write(kDir + "/arm_sj.json", arm_sj(100.0 * am / 0.6, "{\"strengthen_rounds\": 2}"));
      write(kDir + "/arm_strengthen_job.json", arm_job(""));
      std::filesystem::remove_all(kDir + "/arm_strengthen");
      std::filesystem::create_directories(kDir + "/arm_strengthen");
      const OrganicStrengthenResult as = run_organic_strengthen(kDir + "/arm_strengthen_job.json", kDir + "/arm_strengthen", 0,
                                                                MATERIALS_JSON_PATH, SETTINGS_RULES_PATH);
      const std::string asj = slurp(kDir + "/arm_strengthen/strengthen.json");
      std::printf("[arm strengthen] ok %d code %s rounds %d %s %s\n", as.ok, as.code.c_str(), as.rounds_fixed, as.why.c_str(), as.detail.c_str());
      for (std::size_t at = asj.find("\"print_left_out\""); at != std::string::npos; at = asj.find("\"print_left_out\"", at + 1))
        std::printf("   %s\n", asj.substr(at, asj.find(", \"hash\"", at) - at).c_str());
      CHECK(as.ok && as.rounds_fixed >= 1 && has(asj, "\"print_left_out\": ") && has(asj, "\"print_moved\": ") &&
            has(asj, "\"print_added\": ") && !has(asj, "print_check_after_additions"));
      if (as.ok && as.rounds_fixed >= 1) {
        const std::string last = "arm_strengthen/r" + std::to_string(as.rounds_fixed);
        const double bars_last = num_after(asj, "bars", asj.find("\"round\": " + std::to_string(as.rounds_fixed)));
        const Run ar = run("arm_replay", arm_job(last + "/strengthened.json"), "");
        std::printf("[arm] replay: ok %d code %s, bars %zu (the last round's %.0f)\n", ar.r.ok, ar.r.code.c_str(), ar.r.bars, bars_last);
        CHECK(ar.r.ok && ar.r.code == "ok" && static_cast<double>(ar.r.bars) == bars_last);
      }
    }
  }

  // ── §16 (the lead's ruling, 2026-11-19) the print check props weave bars only. A made 40 x 10 x 20 block with a clip
  // tab of solid (x 15 to 25) standing 6 mm out of its y = 10 face at the top (z 16 to 20), its underside over air (the
  // layer check reads it as reaching 6 mm past what holds it); the weave 14 mm deep under the top face, inside the block. The tab's overhang is the part's own: counted
  // (`part_overhangs`), never propped (no post outside the part), never a reason the file is not clean.
  {
    const TriangleMesh tm = cells_mesh({0, 15, 25, 40}, {0, 10, 16}, {0, 16, 20}, [](int i, int j, int k) { return j == 0 || (i == 1 && k == 1); });
    write_stl_file(kDir + "/tab.stl", tm, StlFormat::Binary);
    const StepModel tmodel = import_part_file_resolved(kDir + "/tab.stl");
    const int top = face_at(tmodel, 0, 0, 1, 20.0);
    CHECK(top >= 0);
    std::filesystem::copy_file(kDir + "/pocket.tensor", kDir + "/tab.tensor", std::filesystem::copy_options::overwrite_existing);
    const std::string tj = "{\"mode\": \"lattice_file\", \"model\": \"tab.stl\", \"output\": \"tab_lattice.stl\", \"tensor\": \"tab.tensor\", "
                           "\"layout\": {\"region_ids\": [1], \"region_no_lattice\": [0], \"region_depth_mm\": [14], \"region_expand_mm\": [-2], "
                           "\"region_face_counts\": [1], \"region_faces\": [" + std::to_string(top) + "], \"region_weave\": [true], "
                           "\"organic_spacing_mm\": 4, \"organic_width_mm\": 0.9}}";
    const Run t = run("tab", tj, "");
    std::size_t outside = 0;
    for (const MeshSpec::Post& q : t.r.made.posts) outside += q.y > 10.0;
    std::printf("[tab] ok %d code %s; part overhangs %zu, posts %zu (%zu outside the block, under the tab), clean %d, found per pass %d\n",
                t.r.ok, t.r.code.c_str(), t.r.made.part_overhangs, t.r.made.posts.size(), outside, t.r.made.print_clean,
                t.r.made.found_per_pass.empty() ? -1 : t.r.made.found_per_pass.front());
    CHECK(t.r.ok && t.r.made.print_clean && t.r.made.part_overhangs > 0 && outside == 0);
    CHECK(has(t.json, "\"part_overhangs\": " + std::to_string(t.r.made.part_overhangs)));
  }

  // ── §8 the octet's strut law is the full octet's (2026-11-17): its span is the octet band, so no density in the band
  // is clamped; its lowest row is bulk only, so a credited cell under 0.10 gets no strut pass, with a plain note.
  {
    const LatticeTopology oct = LatticeTopology::Octet;
    CHECK(strut_law_rho_min(oct) == lattice_rho_min(oct) && strut_law_rho_max(oct) == lattice_rho_max(oct));
    CHECK(std::fabs(strut_law_rho_min(oct) - 0.04959) < 1e-12 && std::fabs(strut_law_rho_max(oct) - 0.90027) < 1e-12);
    bool c_lo = true, c_hi = true, c_mid = true;
    (void)strut_law_at(oct, lattice_rho_min(oct), &c_lo);
    (void)strut_law_at(oct, lattice_rho_max(oct), &c_hi);
    (void)strut_law_at(oct, 0.5 * (lattice_rho_min(oct) + lattice_rho_max(oct)), &c_mid);
    CHECK(!c_lo && !c_hi && !c_mid);
    CHECK(strut_law_bulk_only_below(oct) == 0.10);
    CHECK(strut_law_bulk_only_below(LatticeTopology::Fcc) == 0.0);
    // The lightest credited cell of a job's layout.
    const auto lightest = [&](const std::string& fj) {
      StepModel m = import_part_file_resolved(kDir + "/block.stl");
      Session session(std::move(m));
      const Outcome o = session.lay(parse_file_job(fj).settings);
      CreditGrid g;
      g.spacing = 1.0;
      g.nx = g.ny = g.nz = 1;
      const LatticeCredit c = lattice_credit(o.layout, *session.domain(), o.bars, {}, g);
      double lo = 1e300;
      for (std::size_t i = 0; i < c.cell_credit.size(); ++i)
        if (c.cell_credit[i]) lo = std::min(lo, c.cell_rho[i]);
      return lo;
    };
    const double rho_light = lightest(file_job(f, "", "octet", ""));
    // One-line struts 0.65 mm wide on the 8 mm cells: lighter than 0.10, inside the octet band.
    const auto one_line = [](std::string job) {
      const std::string a = "\"min_strut_lines\": 2";
      const std::size_t at = job.find(a);
      if (at != std::string::npos) job.replace(at, a.size(), "\"min_strut_lines\": 1");
      return job;
    };
    const std::string thin_extra = ", \"strut_width_mm\": 0.65";
    const double rho_thin = lightest(one_line(file_job(f, thin_extra, "octet", "")));
    std::printf("[octet law] lightest credited cell: default struts %.4f, one-line 0.65 mm struts %.4f\n", rho_light,
                rho_thin);
    // The pass example's cells are at or above 0.10, so its pass stands on measured boundary rows.
    CHECK(rho_light >= 0.10);
    CHECK(!has(lb, "lighter than"));
    // A layout with a cell under 0.10: its struts are out of regime, said plainly, and never pass.
    const std::string light_cells = one_line(file_job(f, thin_extra, "octet"));
    CHECK(rho_thin < 0.10 && rho_thin >= lattice_rho_min(oct));
    const Run low = run("low_density", light_cells, strength_job(f, 20.0));
    const std::string wb = block(low.json);
    const std::size_t st = wb.find("\"strut\": {");
    CHECK(low.r.ok && low.r.strength_ran && st != std::string::npos);
    if (st != std::string::npos) {
      CHECK(has(wb.substr(st), "\"out_of_regime\": true"));
      CHECK(has(wb.substr(st), "lighter than 0.1 of solid"));
    }
    CHECK(has(wb, "\"accepted\": true") && has(wb, "\"struts_pass\": false") && has(wb, "\"verdict\": \"solid_only\""));
  }

  // ── §6 refusals: no file, no block.
  {
    auto refused = [&](const char* tag, const std::string& sjob, const char* code, const char* detail) {
      Run x = run(tag, file_job(f, ""), sjob);
      CHECK(!x.r.ok && x.r.code == code && x.r.exit_code == 1);
      CHECK(!x.r.why.empty() && x.r.why.find('\n') == std::string::npos);
      CHECK(has(x.r.detail, detail));
      CHECK(!exists(x.out + "/block_lattice.stl") && !exists(x.out + "/fields.bin"));
      CHECK(!has(x.json, "\"strength\""));
    };
    refused("unreadable", "{", "strength_job_unreadable", "");
    refused("mode", strength_job(f, 20.0, "lattice_variant"), "strength_job_unreadable", "lattice_part");
    refused("other_part", strength_job(f, 20.0, "lattice_part", "other.stl"), "strength_job_unreadable",
            "not the lattice file's part");
    // No check in the build: refused before anything is laid.
    write(kDir + "/strength_job.json", strength_job(f, 20.0));
    write(kDir + "/nocheck_job.json", file_job(f, ""));
    std::filesystem::create_directories(kDir + "/nocheck");
    const FileResult r = run_file_job(kDir + "/nocheck_job.json", kDir + "/nocheck");
    CHECK(!r.ok && r.code == "strength_unavailable");
  }

  std::printf("lattice_strength: %d checks, %d failed\n", g_checks, g_fail);
  return g_fail ? 1 : 0;
}
