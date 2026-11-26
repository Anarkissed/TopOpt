// TO rebuild stage 1: what the stage switch (TOPOPT_FACE_LOADS) does to the
// LATTICE strength check (reviewer's ruling 2026-11-25; the set LatticeReview
// named, TORebuildGroup 2026-11-25). Three made jobs, none of the maintainer's:
//
//   A  a box on the grid, lattice from its whole top face to a depth that is a
//      whole number of voxels, held on the whole bottom, loaded on the whole
//      top. THE CONTROL: the switch should change nothing beyond rounding.
//   B  a 56 x 56 x 32 mm box ON the grid with one top edge chamfered (about 38
//      degrees): the chamfer is the loaded face, with a protected skin 1.3 mm
//      deep (not a whole number of voxels). The lattice region is the top face,
//      three 8 mm cells deep, so whole cells exist and earn credit
//      (LatticeReview, 2026-11-25: a cell is whole only when all 27 of its
//      sample points are lattice, and the cells follow the model's axes).
//   C  job B with Organic (traced), so the frame-of-beams check runs.
//
// Each job runs twice in this process: switch off, then `face`. Printed per
// job: every number of the result's "strength" block that differs, the
// verdicts, the bar count and a hash of the laid file's bytes.
//
// THE RULE HELD HERE: the switch moves the check's loads and protected solid and
// must NOT move the laid lattice, so the bar count and the file's bytes must be
// IDENTICAL off and on. That fails the test in either form. Everything else is
// measured and printed for the stage report.
#include <algorithm>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <filesystem>
#include <fstream>
#include <functional>
#include <map>
#include <sstream>
#include <string>
#include <vector>

#include "topopt/face_overrides.hpp"
#include "topopt/lattice_file_strength.hpp"
#include "topopt/lattice_layout_file.hpp"
#include "topopt/lattice_layout_organic.hpp"
#include "topopt/step.hpp"
#include "topopt/stl.hpp"

using namespace topopt;
using namespace topopt::lattice_layout;

namespace {

const std::string kDir = std::string(TMP_DIR) + "/to_stage1_lattice_check";

std::string slurp(const std::string& p) {
  std::ifstream f(p, std::ios::binary);
  std::ostringstream s;
  s << f.rdbuf();
  return s.str();
}
void write(const std::string& path, const std::string& text) { std::ofstream(path) << text; }

struct Turn {
  double m[3][3];
  Vec3 operator()(const Vec3& v) const {
    return {m[0][0] * v.x + m[0][1] * v.y + m[0][2] * v.z, m[1][0] * v.x + m[1][1] * v.y + m[1][2] * v.z,
            m[2][0] * v.x + m[2][1] * v.y + m[2][2] * v.z};
  }
};
Turn turn(double deg_z, double deg_x) {
  const double pi = std::acos(-1.0), a = deg_z * pi / 180.0, b = deg_x * pi / 180.0;
  const double ca = std::cos(a), sa = std::sin(a), cb = std::cos(b), sb = std::sin(b);
  // Rx(b) * Rz(a)
  return {{{ca, -sa, 0.0}, {cb * sa, cb * ca, -sb}, {sb * sa, sb * ca, cb}}};
}

TriangleMesh box(double L, double W, double H, const Turn& t) {
  TriangleMesh m;
  for (const Vec3& v : std::vector<Vec3>{{0, 0, 0}, {L, 0, 0}, {L, W, 0}, {0, W, 0},
                                         {0, 0, H}, {L, 0, H}, {L, W, H}, {0, W, H}})
    m.vertices.push_back(t(v));
  const int tri[12][3] = {{0, 2, 1}, {0, 3, 2}, {4, 5, 6}, {4, 6, 7}, {0, 1, 5}, {0, 5, 4},
                          {3, 7, 6}, {3, 6, 2}, {0, 4, 7}, {0, 7, 3}, {1, 2, 6}, {1, 6, 5}};
  for (const auto& x : tri) m.triangles.push_back({x[0], x[1], x[2]});
  return m;
}

// A 56 x 56 x 32 mm box on the grid with one top edge cut off by a flat chamfer
// (9 mm in, 7 mm down, about 38 degrees: more than the 35 degrees at which the
// mesh importer splits two faces, or the chamfer would join the top): every face lies on the grid except the
// chamfer, which is the loaded face. Outward-facing triangles.
TriangleMesh chamfered_box() {
  const double L = 56, W = 56, H = 32, in = 9, down = 7;
  // The profile in x-z, counter-clockwise seen from -y.
  const double px[5] = {0, L, L, L - in, 0}, pz[5] = {0, 0, H - down, H, H};
  TriangleMesh m;
  for (int y = 0; y < 2; ++y)
    for (int i = 0; i < 5; ++i) m.vertices.push_back({px[i], y ? W : 0.0, pz[i]});
  for (int i = 0; i < 5; ++i) {  // the five sides
    const int a = i, b = (i + 1) % 5;
    m.triangles.push_back({a, b + 5, b});
    m.triangles.push_back({a, a + 5, b + 5});
  }
  for (int i = 1; i + 1 < 5; ++i) {  // the two ends, as fans
    m.triangles.push_back({0, i, i + 1});          // y = 0, normal -y
    m.triangles.push_back({5, 5 + i + 1, 5 + i});  // y = W, normal +y
  }
  return m;
}

int face_with_normal(const StepModel& m, const Vec3& n) {
  for (int f = 0; f < m.face_count; ++f) {
    const StepFaceInfo& fi = m.faces[static_cast<std::size_t>(f)];
    if (fi.kind == StepSurfaceKind::Plane &&
        fi.plane_normal.x * n.x + fi.plane_normal.y * n.y + fi.plane_normal.z * n.z > 0.99)
      return f;
  }
  return -1;
}

struct Faces { int top = -1, bottom = -1, side = -1; };

std::string file_job(const std::string& model, const Faces& f, const std::string& extra, int depth_mm = 8,
                     const std::string& topology = "octet") {
  return "{\"mode\": \"lattice_file\", \"model\": \"" + model + "\", \"output\": \"lattice.stl\", "
         "\"strength_job\": \"strength_job.json\", "
         "\"layout\": {\"min_strut_lines\": 2, \"region_ids\": [1], \"region_no_lattice\": [0], "
         "\"region_depth_mm\": [" + std::to_string(depth_mm) + "], \"region_expand_mm\": [0], \"region_face_counts\": [1], "
         "\"region_faces\": [" + std::to_string(f.top) + "], \"topology\": \"" + topology + "\", "
         "\"algorithm\": \"uniform\", \"cell_max_mm\": 8, \"min_cells_across\": 1" + extra + "}}";
}
std::string strength_job(const std::string& model, const Faces& f, int load_face, const std::string& protect,
                         const std::string& topology = "octet") {
  return "{\"model\": \"" + model + "\", \"material\": \"PLA\", \"mode\": \"lattice_part\", \"resolution\": 40, "
         "\"loads\": {\"minimize_plastic\": true, \"safety_margin\": 1.5, \"build_dir\": [0, 0, 1], "
         "\"anchor_face_ids\": [" + std::to_string(f.bottom) + "], \"groups\": [{\"face_ids\": [" +
         std::to_string(load_face) + "], \"force\": [0, 0, -20]}]" + protect + "}, "
         "\"lattice\": {\"topology\": \"" + topology + "\", \"require_lattice_void_reaches_exterior\": false}, "
         "\"grading\": {\"topology\": \"" + topology + "\", \"cell_mm\": 8, \"min_extrudable_width_mm\": 0.45, "
         "\"intent\": \"structural\"}, "
         "\"output\": {\"report\": \"report.json\", \"mesh_format\": \"stl\", \"mesh_prefix\": \"variant\"}}";
}

struct Result {
  bool ok = false;
  std::size_t bars = 0;
  std::size_t file_hash = 0;
  std::string strength;  // the "strength" block's text
  std::string code, why;
};

Result run(const std::string& tag, const std::string& mode, const std::string& job, const std::string& sjob) {
  if (mode.empty()) unsetenv("TOPOPT_FACE_LOADS"); else setenv("TOPOPT_FACE_LOADS", mode.c_str(), 1);
  const std::string folder = kDir + "/" + tag + (mode.empty() ? "_off" : "_" + mode);
  std::filesystem::remove_all(folder);
  std::filesystem::create_directories(folder);
  write(kDir + "/" + tag + "_job.json", job);
  write(kDir + "/strength_job.json", sjob);
  const StrengthCheck check = lattice_file_strength_check(MATERIALS_JSON_PATH, SETTINGS_RULES_PATH);
  const FileResult r = run_file_job(kDir + "/" + tag + "_job.json", folder, 0, nullptr, &check);
  unsetenv("TOPOPT_FACE_LOADS");
  Result x;
  x.ok = r.ok;
  x.bars = r.bars;
  x.code = r.code;
  x.why = r.why;
  // The laid lattice's own bytes: the STL for cells; for a weave the bar list
  // (its file is a 3MF, which carries random ids on every write).
  std::string laid = slurp(folder + "/lattice.stl");
  if (laid.empty()) laid = slurp(folder + "/bars.bin");
  if (laid.empty()) x.ok = false;  // nothing to compare is a failed run, not a pass
  x.file_hash = std::hash<std::string>{}(laid);
  const std::string json = slurp(folder + "/" + kFileResultName);
  const std::size_t a = json.find("\n  \"strength\": {");
  if (a != std::string::npos) {
    const std::size_t b = json.find("\n  },\n", a);
    x.strength = b == std::string::npos ? json.substr(a) : json.substr(a, b - a + 5);
  }
  std::printf("[%s %s] ok %d code %s why %s bars %zu strength ran %d accepted %d\n", tag.c_str(),
              mode.empty() ? "off" : mode.c_str(), r.ok, r.code.c_str(), r.why.c_str(), r.bars, r.strength_ran,
              r.strength_accepted);
  return x;
}

// Every `"key": value` of a block, in order of appearance; a repeated key gets #2, #3...
std::vector<std::pair<std::string, std::string>> pairs(const std::string& b) {
  std::vector<std::pair<std::string, std::string>> out;
  std::map<std::string, int> seen;
  for (std::size_t at = b.find('"'); at != std::string::npos;) {
    const std::size_t end = b.find('"', at + 1);
    if (end == std::string::npos) break;
    if (b.compare(end, 3, "\": ") == 0) {
      const std::string key = b.substr(at + 1, end - at - 1);
      std::size_t v = end + 3, e = v;
      if (b[v] == '"') {
        e = b.find('"', v + 1);
        e = e == std::string::npos ? b.size() : e + 1;
      } else {
        while (e < b.size() && b[e] != ',' && b[e] != '\n' && b[e] != '}' && b[e] != ']') ++e;
      }
      const std::string val = b.substr(v, e - v);
      if (!val.empty() && val[0] != '{' && val[0] != '[') {
        const int n = ++seen[key];
        out.push_back({n == 1 ? key : key + "#" + std::to_string(n), val});
      }
      at = b.find('"', e);
    } else {
      at = b.find('"', end + 1);
    }
  }
  return out;
}

// How many values of the strength block differ between two runs (timings left out).
int differing(const Result& a, const Result& b) {
  const auto pa = pairs(a.strength), pb = pairs(b.strength);
  std::map<std::string, std::string> bm(pb.begin(), pb.end());
  int n = pa.size() == pb.size() ? 0 : 1;
  for (const auto& kv : pa) {
    // Timings, and the frame solve's own residual (about 1e-10, solver noise that
    // moves by several per cent between two identical runs).
    static const char* timing[] = {"seconds", "_ms", "ms", "voxel_solve", "frame", "frame_assemble",
                                   "frame_solve", "after_frame", "peak", "residual"};
    bool skip = false;
    for (const char* t : timing)
      if (kv.first == t || kv.first.find("seconds") != std::string::npos ||
          kv.first.find("_ms") != std::string::npos)
        skip = true;
    if (skip) continue;
    const auto it = bm.find(kv.first);
    // The Organic frame solve is not bit-repeatable (its tiny bar forces move in
    // the tenth digit between two identical runs: seen 2026-11-25, and named to
    // LatticeReview), so numbers are compared to six digits here. A real reach of
    // the switch moves margins by per cent, not by 1e-9.
    if (it != bm.end() && it->second != kv.second) {
      char* ea = nullptr;
      char* eb = nullptr;
      const double x = std::strtod(kv.second.c_str(), &ea), y = std::strtod(it->second.c_str(), &eb);
      if (ea != kv.second.c_str() && eb != it->second.c_str() &&
          std::fabs(x - y) <= 1e-6 * std::max(std::fabs(x), std::fabs(y)))
        continue;
    }
    if (it == bm.end() || it->second != kv.second) {
      ++n;
      std::printf("    %-40s %s | %s\n", kv.first.c_str(), kv.second.c_str(),
                  it == bm.end() ? "(absent)" : it->second.c_str());
    }
  }
  return n;
}

int compare(const std::string& tag, const Result& off, const Result& on) {
  int failures = 0;
  if (!off.ok || !on.ok) {
    std::printf("[%s] a run did not complete (off: %s %s; face: %s %s)\n", tag.c_str(), off.code.c_str(),
                off.why.c_str(), on.code.c_str(), on.why.c_str());
    return 1;
  }
  const bool same_lay = off.bars == on.bars && off.file_hash == on.file_hash;
  std::printf("[%s] laid lattice: bars %zu / %zu, file hash %zx / %zx  %s\n", tag.c_str(), off.bars, on.bars,
              off.file_hash, on.file_hash, same_lay ? "IDENTICAL" : "DIFFERENT (the switch moved the lattice)");
  if (!same_lay) ++failures;
  const auto a = pairs(off.strength), b = pairs(on.strength);
  std::map<std::string, std::string> bm(b.begin(), b.end());
  int differ = 0;
  for (const auto& kv : a) {
    const auto it = bm.find(kv.first);
    const std::string other = it == bm.end() ? "(absent)" : it->second;
    if (other == kv.second) continue;
    if (kv.first.find("seconds") != std::string::npos || kv.first.find("_ms") != std::string::npos) continue;
    ++differ;
    std::printf("[%s]   %-44s off %-22s face %s\n", tag.c_str(), kv.first.c_str(), kv.second.c_str(), other.c_str());
  }
  std::printf("[%s] strength block: %zu values, %d differ\n", tag.c_str(), a.size(), differ);
  return failures;
}

}  // namespace

int main() {
  std::filesystem::remove_all(kDir);
  std::filesystem::create_directories(kDir);
  int failures = 0;

  // 32 x 32 x 16 mm at resolution 40: voxel 0.8 mm, so the 8 mm lattice depth is ten voxels.
  const Turn none = turn(0.0, 0.0);
  write_stl_file(kDir + "/box.stl", box(32, 32, 16, none), StlFormat::Binary);
  write_stl_file(kDir + "/tilted.stl", chamfered_box(), StlFormat::Binary);
  auto faces = [&](const std::string& file, const Turn& t) {
    const StepModel m = import_part_file_resolved(kDir + "/" + file);
    Faces f;
    f.top = face_with_normal(m, t({0, 0, 1}));
    f.bottom = face_with_normal(m, t({0, 0, -1}));
    f.side = face_with_normal(m, t({1, 0, 0}));
    std::printf("%s faces: top %d bottom %d side %d (of %d)\n", file.c_str(), f.top, f.bottom, f.side, m.face_count);
    return f;
  };
  const Faces fa = faces("box.stl", none);
  Faces fb = faces("tilted.stl", none);
  {
    // Job B's loaded face is the chamfer (normal (7, 0, 9) / 11.4).
    const StepModel m = import_part_file_resolved(kDir + "/tilted.stl");
    const double n = std::sqrt(7.0 * 7.0 + 9.0 * 9.0);
    fb.side = face_with_normal(m, {7.0 / n, 0.0, 9.0 / n});
    std::printf("chamfer face %d\n", fb.side);
  }
  if (fa.top < 0 || fa.bottom < 0 || fb.top < 0 || fb.bottom < 0 || fb.side < 0) {
    std::printf("a face was not found\n");
    return 1;
  }

  // Organic follows a stress result: a made, uniform one over the tilted box's
  // bounding box (mostly along z, some along x), the same for both switch values.
  {
    Vec3 lo{1e300, 1e300, 1e300}, hi{-1e300, -1e300, -1e300};
    for (const Vec3& v : chamfered_box().vertices) {
      lo = {std::min(lo.x, v.x), std::min(lo.y, v.y), std::min(lo.z, v.z)};
      hi = {std::max(hi.x, v.x), std::max(hi.y, v.y), std::max(hi.z, v.z)};
    }
    TensorField tf;
    tf.spacing = 1.0;
    tf.origin = {lo.x - 1.0, lo.y - 1.0, lo.z - 1.0};
    tf.nx = static_cast<int>(std::ceil(hi.x - lo.x)) + 2;
    tf.ny = static_cast<int>(std::ceil(hi.y - lo.y)) + 2;
    tf.nz = static_cast<int>(std::ceil(hi.z - lo.z)) + 2;
    const std::size_t n = static_cast<std::size_t>(tf.nx) * tf.ny * tf.nz;
    tf.voigt.assign(6 * n, 0.0);
    for (std::size_t e = 0; e < n; ++e) { tf.voigt[6 * e + 2] = 3.0; tf.voigt[6 * e] = 1.0; }
    if (!write_tensor_file(kDir + "/stress.tensor", tf)) {
      std::printf("the made stress result was not written\n");
      return 1;
    }
  }
  // For the reviewer's table (ruling 2026-11-26, condition e): one more Organic
  // job, loaded ON the weave (the box turned 17 / 9 degrees, region the top, the
  // top loaded), and one sheet job (gyroid on the control box). Either may not
  // exist on this base (sheets on the new engine are on #362's branch); a job
  // whose plain run does not complete is reported and skipped, not failed.
  const Turn turned = turn(17.0, 9.0);
  write_stl_file(kDir + "/turned.stl", box(56, 56, 24, turned), StlFormat::Binary);
  const Faces ft = faces("turned.stl", turned);
  {
    Vec3 lo{1e300, 1e300, 1e300}, hi{-1e300, -1e300, -1e300};
    for (const Vec3& v : box(56, 56, 24, turned).vertices) {
      lo = {std::min(lo.x, v.x), std::min(lo.y, v.y), std::min(lo.z, v.z)};
      hi = {std::max(hi.x, v.x), std::max(hi.y, v.y), std::max(hi.z, v.z)};
    }
    TensorField tf;
    tf.spacing = 1.0;
    tf.origin = {lo.x - 1.0, lo.y - 1.0, lo.z - 1.0};
    tf.nx = static_cast<int>(std::ceil(hi.x - lo.x)) + 2;
    tf.ny = static_cast<int>(std::ceil(hi.y - lo.y)) + 2;
    tf.nz = static_cast<int>(std::ceil(hi.z - lo.z)) + 2;
    const std::size_t n = static_cast<std::size_t>(tf.nx) * tf.ny * tf.nz;
    tf.voigt.assign(6 * n, 0.0);
    for (std::size_t e = 0; e < n; ++e) { tf.voigt[6 * e + 2] = 3.0; tf.voigt[6 * e] = 1.0; }
    write_tensor_file(kDir + "/stress_turned.tensor", tf);
  }
  struct Job { const char* tag; std::string file, strength; };
  const std::string protect =
      ", \"face_protections\": [{\"face_id\": " + std::to_string(fb.side) + ", \"depth_mm\": 1.3}]";
  const std::string weave = ", \"region_weave\": [true], \"organic_spacing_mm\": 4, \"organic_width_mm\": 0.9";
  std::string organic_job = file_job("tilted.stl", fb, weave, 24);
  organic_job.replace(organic_job.find("\"layout\""), 8, "\"tensor\": \"stress.tensor\", \"layout\"");
  const std::vector<Job> jobs = {
      {"A_control", file_job("box.stl", fa, ""), strength_job("box.stl", fa, fa.top, "")},
      {"B_off_grid", file_job("tilted.stl", fb, "", 24), strength_job("tilted.stl", fb, fb.side, protect)},
      {"C_organic", organic_job, strength_job("tilted.stl", fb, fb.side, protect)},
  };
  std::vector<Job> all = jobs;
  if (ft.top >= 0 && ft.bottom >= 0) {
    std::string d = file_job("turned.stl", ft, weave);
    d.replace(d.find("\"layout\""), 8, "\"tensor\": \"stress_turned.tensor\", \"layout\"");
    all.push_back({"D_organic_on_lattice", d, strength_job("turned.stl", ft, ft.top, "")});
  }
  all.push_back({"S_sheet_gyroid", file_job("box.stl", fa, "", 8, "gyroid"),
                 strength_job("box.stl", fa, fa.top, "", "gyroid")});
  const std::size_t required = jobs.size();  // A to C must run; D and S may be absent here
  for (std::size_t ji = 0; ji < all.size(); ++ji) {
    const Job& j = all[ji];
    const Result off = run(j.tag, "", j.file, j.strength);
    if (ji >= required && !off.ok) {
      std::printf("[%s] not made on this base (%s %s); skipped\n", j.tag, off.code.c_str(), off.why.c_str());
      continue;
    }
    const Result on = run(j.tag, "face", j.file, j.strength);
    failures += compare(j.tag, off, on);
    // STAGE 2's switch (TOPOPT_STRENGTH) must not reach the lattice strength check
    // at all (reviewer's ruling 2026-11-26, condition (b) and the table of (e)):
    // the same job with stage 1 off and stage 2 on, a typed 1.8 mm reading.
    setenv("TOPOPT_STRENGTH", "size", 1);
    setenv("TOPOPT_STRESS_READING_MM", "1.8", 1);
    const Result s2 = run((std::string(j.tag) + "_stage2").c_str(), "", j.file, j.strength);
    unsetenv("TOPOPT_STRENGTH");
    unsetenv("TOPOPT_STRESS_READING_MM");
    const int moved = differing(off, s2);
    std::printf("[%s] stage 2 switch on, stage 1 off: %d strength value(s) differ from off, bars %zu / %zu  %s\n",
                j.tag, moved, off.bars, s2.bars,
                moved == 0 && off.bars == s2.bars && off.file_hash == s2.file_hash ? "UNTOUCHED"
                                                                                  : "REACHED (it must not be)");
    if (moved != 0 || off.bars != s2.bars || off.file_hash != s2.file_hash) ++failures;
  }
  std::printf("[stage 1 lattice check] %d failure(s)\n", failures);
  return failures == 0 ? 0 : 1;
}
