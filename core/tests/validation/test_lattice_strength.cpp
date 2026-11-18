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
    CHECK(keys.size() == 84);   // 60 of Install 3, 24 of the Organic check (brief E2)
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
      const std::string sb = block(run("organic_scalar", fj, sparse("")).json);
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
                   6000.0, "{\"strengthen_rounds\": 1}");
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
        strengthen("nothing", ", \"region_weave\": [true], \"organic_spacing_mm\": 4, \"organic_width_mm\": 0.9", 2500.0, "");
    CHECK(nv.ok && nv.code == "nothing_to_vary" && nv.rounds_fixed == 0);
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
