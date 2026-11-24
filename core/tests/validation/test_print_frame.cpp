// P2, his print orientation (spec 2c): "rotate at the door" (print_frame.hpp).
//
// THE TEST: an L-bracket whose X, Y and Z extents all differ (40 x 24 x 30 mm), an Organic area on its plate with a
// No-lattice zone in it, a made-up stress tensor that varies along every axis and has every shear, and a strength job
// (held on the plate's underside, loaded on the wall's top), run through the lattice file job twice, as the CLI runs it:
//   A  the job with "print_frame": {"up": [1, 0, 0]};
//   B  the SAME job on a copy of everything turned BY HAND so +X goes to +Z (this file's own turn, written apart from
//      print_frame.cpp: the part, the zone, the tensor, the strength job's load, service and build direction), with no
//      print frame.
// For an axis turn the engines see the very same numbers, so A and B must make the SAME 3MF (byte for byte), the same
// strut_margins.bin, the same fields.bin and the same report once B's positions are turned back by hand. If any engine
// read an input the door did not turn, A and B differ here.
// The mutation guard: A again with each input left unturned (g_print_frame_test_skip) must differ from B.
// And: A's report says its frame; its layers are the part's X extent in layers; its first layer is the face whose
// outward normal is -X; the strength check's build direction is the up; a job with no frame has no "print_frame" key.
#include <algorithm>
#include <array>
#include <chrono>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <map>
#include <cstdlib>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <functional>
#include <set>
#include <sstream>
#include <string>
#include <vector>

#include "../../src/flexible/json.hpp"
#include "topopt/face_overrides.hpp"
#include "topopt/lattice_file_strength.hpp"
#include "topopt/lattice_layout_file.hpp"
#include "topopt/print_frame.hpp"
#include "topopt/stl.hpp"

using namespace topopt;
using namespace topopt::lattice_layout;
namespace sj = topopt::flexible::json;

static int g_fail = 0, g_checks = 0;
#define CHECK(cond)                                                                        \
  do {                                                                                     \
    ++g_checks;                                                                            \
    if (!(cond)) { ++g_fail; std::printf("FAIL %s:%d  %s\n", __FILE__, __LINE__, #cond); } \
  } while (0)

namespace {

const std::string kDir = std::string(TMP_DIR) + "/print_frame";
// The solve's own round-off: the same job run twice gives strut margins and stresses that differ in their last bits
// (measured: 1807.0250 against 1807.0251, float32; the threads' sums). The door is exact; a wrong turn moves numbers by
// far more than this.
constexpr double kTol = 1e-6;

std::string slurp(const std::string& p) {
  std::ifstream f(p, std::ios::binary);
  std::ostringstream s;
  s << f.rdbuf();
  return s.str();
}
void write(const std::string& path, const std::string& text) { std::ofstream(path) << text; }

// THIS FILE'S OWN TURN for up = +X (print = (-z, y, x); the part's lowest x is 0, so no base shift).
Vec3 hand(const Vec3& p) { return {0.0 - p.z, p.y, p.x}; }
Vec3 hand_back(const Vec3& q) { return {q.z, q.y, 0.0 - q.x}; }

// The L-bracket: a plate x 0..40, y 0..24, z 0..6, and a wall x 0..8 standing on it to z = 30 (cells_mesh of
// test_lattice_strength.cpp: a closed outward mesh of the filled cells of a grid).
TriangleMesh bracket() {
  const std::vector<double> xs{0, 8, 40}, ys{0, 24}, zs{0, 6, 30};
  const auto full = [](int i, int, int k) { return k == 0 || i == 0; };
  const int nx = 3, ny = 2, nz = 3;
  TriangleMesh tm;
  const auto vid = [&](int i, int j, int k) { return (k * ny + j) * nx + i; };
  for (int k = 0; k < nz; ++k)
    for (int j = 0; j < ny; ++j)
      for (int i = 0; i < nx; ++i) tm.vertices.push_back({xs[i], ys[j], zs[k]});
  const auto quad = [&](int a, int b, int c, int d) {
    tm.triangles.push_back({a, b, c});
    tm.triangles.push_back({a, c, d});
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

int face_at(const StepModel& m, const Vec3& n, double off) {
  for (int f = 0; f < m.face_count; ++f) {
    const StepFaceInfo& x = m.faces[static_cast<std::size_t>(f)];
    if (x.kind == StepSurfaceKind::Plane && x.plane_normal.x * n.x + x.plane_normal.y * n.y + x.plane_normal.z * n.z > 0.99 &&
        std::fabs(x.plane_origin.x * n.x + x.plane_origin.y * n.y + x.plane_origin.z * n.z - off) < 1e-6)
      return f;
  }
  return -1;
}

std::string v3s(const Vec3& v) {
  char b[160];
  std::snprintf(b, sizeof b, "[%.17g, %.17g, %.17g]", v.x, v.y, v.z);
  return b;
}

// The tensor: every component varies, every shear is there.
void tensor_at(const Vec3& c, double s[6]) {
  s[0] = 1.0 + 0.05 * c.x;
  s[1] = 2.0 + 0.03 * c.y;
  s[2] = 3.0 + 0.02 * c.z;
  s[3] = 0.4 + 0.01 * c.z;   // xy
  s[4] = -0.3 + 0.01 * c.x;  // yz
  s[5] = 0.2 + 0.01 * c.y;   // zx
}

struct Job {
  std::string model, tensor, strength, zone, extra;
  int top = -1, bottom = -1, wall_top = -1;
};
std::string file_job(const Job& j) {
  return "{\"mode\": \"lattice_file\", \"model\": \"" + j.model + "\", \"output\": \"part_lattice.stl\", \"strength_job\": \"" +
         j.strength + "\", \"tensor\": \"" + j.tensor + "\", \"file_format\": \"3mf\"" + j.extra +
         ", \"layout\": {\"min_strut_lines\": 2, \"region_ids\": [1, 2], \"region_no_lattice\": [0, 1], "
         "\"region_depth_mm\": [4, 0], \"region_expand_mm\": [-1, 0], \"region_face_counts\": [1, 0], "
         "\"region_faces\": [" + std::to_string(j.top) + "], \"region_zones\": [null, " + j.zone + "], "
         "\"region_weave\": [true, false], \"topology\": \"octet\", \"algorithm\": \"uniform\", \"cell_max_mm\": 8, "
         "\"min_cells_across\": 1, \"organic_spacing_mm\": 3, \"organic_width_mm\": 0.9}}";
}
std::string strength_job(const Job& j, const Vec3& force, const Vec3& service_up, bool state_up) {
  return "{\"model\": \"" + j.model + "\", \"material\": \"PLA\", \"mode\": \"lattice_part\", \"resolution\": 40, " +
         std::string(state_up ? "\"build_direction\": [0, 0, 1], " : "") +
         "\"loads\": {\"minimize_plastic\": true, \"safety_margin\": 1.5, \"build_dir\": " + v3s(service_up) + ", "
         "\"anchor_face_ids\": [" + std::to_string(j.bottom) + "], \"groups\": [{\"face_ids\": [" + std::to_string(j.wall_top) +
         "], \"force\": " + v3s(force) + "}]}, "
         "\"lattice\": {\"topology\": \"octet\", \"require_lattice_void_reaches_exterior\": false}, "
         "\"grading\": {\"topology\": \"octet\", \"cell_mm\": 8, \"min_extrudable_width_mm\": 0.45, \"intent\": \"structural\"}, "
         "\"output\": {\"report\": \"report.json\", \"mesh_format\": \"stl\", \"mesh_prefix\": \"variant\"}}";
}

struct Run {
  FileResult r;
  std::string json, out;
};
Run run(const std::string& tag, const std::string& job_name) {
  Run x;
  x.out = kDir + "/" + tag;
  std::filesystem::remove_all(x.out);
  std::filesystem::create_directories(x.out);
  const StrengthCheck check = lattice_file_strength_check(MATERIALS_JSON_PATH, SETTINGS_RULES_PATH);
  x.r = run_file_job(kDir + "/" + job_name, x.out, 0, nullptr, &check);
  x.json = slurp(x.out + "/" + kFileResultName);
  std::printf("[%s] ok %d code %s why %s %s\n", tag.c_str(), x.r.ok, x.r.code.c_str(), x.r.why.c_str(), x.r.detail.c_str());
  return x;
}

// ── B's report turned back BY HAND, key by key (every position and direction the report holds) ─────────────────────
const std::set<std::string> kPoints{"tight_at", "findings_at", "left_out_at", "outside_at", "in_solid_at", "removed_at",
                                    "worst_at", "centroid", "read_at", "drive_no_material_at", "centre", "at"};
const std::set<std::string> kSkipKeys{"ms", "times_ms", "memory_mb", "run_info", "ms_trace", "print_frame", "seconds"};

bool is_vec3(const sj::Value& v) {
  return v.is_array() && v.arr.size() == 3 && v.arr[0].is_number() && v.arr[1].is_number() && v.arr[2].is_number();
}
void set3(sj::Value& v, const Vec3& p) {
  v.arr[0].num = p.x;
  v.arr[1].num = p.y;
  v.arr[2].num = p.z;
}
Vec3 get3(const sj::Value& v) { return {v.arr[0].num, v.arr[1].num, v.arr[2].num}; }

void turn_back(sj::Value& v, const std::string& key) {
  if (v.is_object()) {
    if (key == "build_direction" && sj::find(v, "x")) {   // {"x":, "y":, "z":}: a direction
      Vec3 d{0, 0, 0};
      for (auto& kv : v.obj) (kv.first == "x" ? d.x : kv.first == "y" ? d.y : d.z) = kv.second.num;
      const Vec3 m = hand_back(d);
      for (auto& kv : v.obj) kv.second.num = kv.first == "x" ? m.x : kv.first == "y" ? m.y : m.z;
      return;
    }
    if (key == "box" && sj::find(v, "lo")) {
      Vec3 lo, hi;
      for (auto& kv : v.obj) (kv.first == "lo" ? lo : hi) = get3(kv.second);
      const Vec3 a = hand_back(lo), b = hand_back(hi);
      for (auto& kv : v.obj)
        set3(kv.second, kv.first == "lo" ? Vec3{std::min(a.x, b.x), std::min(a.y, b.y), std::min(a.z, b.z)}
                                         : Vec3{std::max(a.x, b.x), std::max(a.y, b.y), std::max(a.z, b.z)});
      return;
    }
    if (key == "box_grew_mm" || key == "file_box_grew_mm") {   // by axis, measured in print axes
      // print -x is model +z ... : model x = print z, model y = print y, model z = -print x
      std::map<std::string, double> p;
      for (auto& kv : v.obj) p[kv.first] = kv.second.num;
      const std::map<std::string, std::string> from{{"-x", "-z"}, {"+x", "+z"}, {"-y", "-y"}, {"+y", "+y"}, {"-z", "+x"}, {"+z", "-x"}};
      for (auto& kv : v.obj) kv.second.num = p[from.at(kv.first)];
      return;
    }
    for (auto& kv : v.obj) turn_back(kv.second, kv.first);
    return;
  }
  if (v.is_array()) {
    if ((key == "u" || key == "build_direction" || key == "up") && is_vec3(v)) { set3(v, hand_back(get3(v))); return; }
    if (kPoints.count(key) && is_vec3(v)) { set3(v, hand_back(get3(v))); return; }
    if (key == "posts") {   // [x, y, z_bottom, z_top] in the print frame: its two ends, turned back
      for (sj::Value& p : v.arr) {
        const Vec3 lo = hand_back({p.arr[0].num, p.arr[1].num, p.arr[2].num});
        const Vec3 hi = hand_back({p.arr[0].num, p.arr[1].num, p.arr[3].num});
        sj::Value q;
        q.type = sj::Value::Type::Array;
        for (double x : {lo.x, lo.y, lo.z, hi.x, hi.y, hi.z}) {
          sj::Value n;
          n.type = sj::Value::Type::Number;
          n.num = x;
          q.arr.push_back(n);
        }
        p = q;
      }
      return;
    }
    for (sj::Value& e : v.arr) turn_back(e, kPoints.count(key) ? key : key == "spots" || key == "weakest" || key == "ends" ||
                                                                         key == "adrift_parts" || key == "wall_refused_at" ? "" : key);
    return;
  }
}

// The two reports equal (numbers to 1e-9 relative), timing keys left out; the first difference printed.
bool same(const sj::Value& a, const sj::Value& b, const std::string& at, std::string* where) {
  if (a.type != b.type) { *where = at + " (type)"; return false; }
  if (a.is_number()) {
    const double d = std::fabs(a.num - b.num), m = std::max(std::fabs(a.num), std::fabs(b.num));
    if (!(d <= kTol * std::max(1e-3, m))) { *where = at + " " + std::to_string(a.num) + " vs " + std::to_string(b.num); return false; }
    return true;
  }
  if (a.is_string()) { if (a.str != b.str) { *where = at + " \"" + a.str + "\" vs \"" + b.str + "\""; return false; } return true; }
  if (a.is_bool()) { if (a.boolean != b.boolean) { *where = at; return false; } return true; }
  if (a.is_array()) {
    if (a.arr.size() != b.arr.size()) { *where = at + " (size " + std::to_string(a.arr.size()) + " vs " + std::to_string(b.arr.size()) + ")"; return false; }
    for (std::size_t i = 0; i < a.arr.size(); ++i)
      if (!same(a.arr[i], b.arr[i], at + "[" + std::to_string(i) + "]", where)) return false;
    return true;
  }
  if (a.is_object()) {
    std::vector<std::pair<std::string, const sj::Value*>> x, y;
    for (const auto& kv : a.obj) if (!kSkipKeys.count(kv.first)) x.push_back({kv.first, &kv.second});
    for (const auto& kv : b.obj) if (!kSkipKeys.count(kv.first)) y.push_back({kv.first, &kv.second});
    if (x.size() != y.size()) { *where = at + " (keys " + std::to_string(x.size()) + " vs " + std::to_string(y.size()) + ")"; return false; }
    for (std::size_t i = 0; i < x.size(); ++i) {
      if (x[i].first != y[i].first) { *where = at + "." + x[i].first + " vs " + y[i].first; return false; }
      if (!same(*x[i].second, *y[i].second, at + "." + x[i].first, where)) return false;
    }
    return true;
  }
  return true;
}

// fields.bin: A's (model frame) against B's (print frame) turned back by hand. Every block's values compared exactly.
bool fields_same(const std::string& a_path, const std::string& b_path, std::string* why) {
  const std::string a = slurp(a_path), b = slurp(b_path);
  if (a.size() != b.size() || a.size() < 64) { *why = "sizes " + std::to_string(a.size()) + " vs " + std::to_string(b.size()); return false; }
  std::int32_t da[3], db[3], ca = 0;
  double oa[3], ob[3], h = 0.0;
  std::memcpy(da, a.data() + 4, 12);
  std::memcpy(db, b.data() + 4, 12);
  std::memcpy(oa, a.data() + 16, 24);
  std::memcpy(ob, b.data() + 16, 24);
  std::memcpy(&h, a.data() + 40, 8);
  std::memcpy(&ca, a.data() + 56, 4);
  // model x = print z, model y = print y, model z = -print x
  if (da[0] != db[2] || da[1] != db[1] || da[2] != db[0]) { *why = "dims"; return false; }
  if (oa[0] != ob[2] || oa[1] != ob[1] || oa[2] != 0.0 - (ob[0] + h * db[0])) { *why = "origin"; return false; }
  const int nx = da[0], ny = da[1], nz = da[2];
  std::size_t p = 64;
  for (std::int32_t v = 0; v < ca; ++v) {
    std::int64_t cv = 0, ct = 0, cd = 0;
    std::memcpy(&cv, a.data() + p + 24, 8);
    std::memcpy(&ct, a.data() + p + 32, 8);
    std::memcpy(&cd, a.data() + p + 40, 8);
    if (a.compare(p, 24, b, p, 24) != 0) { *why = "block head"; return false; }
    p += 48;
    const auto f = [&](const std::string& s, std::size_t at_) { float x; std::memcpy(&x, s.data() + at_, 4); return x; };
    for (int k = 0; k < nz && cv; ++k)
      for (int j = 0; j < ny; ++j)
        for (int i = 0; i < nx; ++i) {   // model voxel (i, j, k) is print voxel (nz - 1 - k, j, i) of B's grid
          const std::size_t ea = (static_cast<std::size_t>(k) * ny + j) * nx + i;
          const std::size_t eb = (static_cast<std::size_t>(i) * db[1] + j) * db[0] + (db[0] - 1 - k);
          const float x = f(a, p + 4 * ea), y = f(b, p + 4 * eb);
          if (!(x == y || (std::isnan(x) && std::isnan(y)) || std::fabs(x - y) <= kTol * std::max(std::fabs(x), std::fabs(y)))) {
            *why = "voxel value";
            return false;
          }
        }
    p += 4 * static_cast<std::size_t>(cv) + 4 * static_cast<std::size_t>(ct);
    for (int k = 0; k <= nz && cd; ++k)
      for (int j = 0; j <= ny; ++j)
        for (int i = 0; i <= nx; ++i) {
          const std::size_t ea = (static_cast<std::size_t>(k) * (ny + 1) + j) * (nx + 1) + i;
          const std::size_t eb = (static_cast<std::size_t>(i) * (db[1] + 1) + j) * (db[0] + 1) + (db[0] - k);
          const Vec3 m = hand_back({f(b, p + 12 * eb), f(b, p + 12 * eb + 4), f(b, p + 12 * eb + 8)});
          const float ax = f(a, p + 12 * ea), ay = f(a, p + 12 * ea + 4), az = f(a, p + 12 * ea + 8);
          const auto near = [](double u, double w) { return u == w || std::fabs(u - w) <= kTol * std::max(std::fabs(u), std::fabs(w)) + 1e-12; };
          if (!near(ax, m.x) || !near(ay, m.y) || !near(az, m.z)) {
            *why = "node vector";
            return false;
          }
        }
    p += 4 * static_cast<std::size_t>(cd);
  }
  return true;
}

// A against B: the file, strut_margins.bin, fields.bin, the report.
bool a_matches_b(const Run& A, const Run& B, bool quiet = false) {
  bool ok = true;
  std::string why;
  const std::string fa = slurp(A.out + "/part_lattice.3mf"), fb = slurp(B.out + "/part_lattice.3mf");
  if (fa.empty() || fa != fb) { ok = false; if (!quiet) std::printf("  3MF differs (%zu vs %zu bytes)\n", fa.size(), fb.size()); }
  {   // per bar, its strut's margin: the same to kTol, and for struts that carry no load (a margin above 1e6 is
      // "unbounded": there the stress is the solver's round-off) only both unbounded
    const std::string ma = slurp(A.out + "/strut_margins.bin"), mb = slurp(B.out + "/strut_margins.bin");
    std::size_t differ = 0;
    if (ma.size() != mb.size() || ma.empty()) differ = 1;
    for (std::size_t i = 0; i + 4 <= ma.size() && ma.size() == mb.size(); i += 4) {
      float x, y;
      std::memcpy(&x, ma.data() + i, 4);
      std::memcpy(&y, mb.data() + i, 4);
      const bool same_bar = x == y || (std::isnan(x) && std::isnan(y)) || (x > 1e6f && y > 1e6f) ||
                            std::fabs(x - y) <= kTol * std::max(std::fabs(x), std::fabs(y));
      differ += !same_bar;
    }
    if (differ) {
      ok = false;
      if (!quiet) std::printf("  strut_margins.bin differs (%zu bars)\n", differ);
    }
  }
  if (!fields_same(A.out + "/fields.bin", B.out + "/fields.bin", &why)) {
    ok = false;
    if (!quiet) std::printf("  fields.bin differs: %s\n", why.c_str());
  }
  try {
    sj::Value ja = sj::parse(A.json, "A"), jb = sj::parse(B.json, "B");
    turn_back(jb, "");
    if (!same(ja, jb, "", &why)) {
      ok = false;
      if (!quiet) std::printf("  report differs at %s\n", why.c_str());
    }
  } catch (const std::exception& e) {
    ok = false;
    std::printf("  report not read: %s\n", e.what());
  }
  return ok;
}

}  // namespace

int main() {
  std::filesystem::remove_all(kDir);
  std::filesystem::create_directories(kDir);
  // ── unit: the six ups, the base, the round trips
  {
    for (const Vec3& up : {Vec3{0, 0, 1}, Vec3{0, 0, -1}, Vec3{1, 0, 0}, Vec3{-1, 0, 0}, Vec3{0, 1, 0}, Vec3{0, -1, 0}}) {
      PrintFrame f;
      CHECK(print_frame_for_up(up, f));
      const Vec3 z = f.dir_to_print(up);
      CHECK(z.x == 0.0 && z.y == 0.0 && z.z == 1.0);
      const std::array<double, 9> R = f.rotation_row_major();
      const double det = R[0] * (R[4] * R[8] - R[5] * R[7]) - R[1] * (R[3] * R[8] - R[5] * R[6]) + R[2] * (R[3] * R[7] - R[4] * R[6]);
      CHECK(det == 1.0);
      TriangleMesh m = bracket();
      print_frame_set_base(f, m);
      turn_mesh(f, m);
      double lo = 1e300;
      for (const Vec3& v : m.vertices) lo = std::min(lo, v.z);
      CHECK(lo == 0.0);
      const Vec3 p{3.5, -2.25, 7.0}, q = f.point_to_model(f.point_to_print(p));
      CHECK(q.x == p.x && q.y == p.y && q.z == p.z);
      double s[6] = {1, 2, 3, 4, 5, 6}, t[6];
      f.tensor_to_print(s, t);
      // R s R^T: the trace and the Frobenius norm are kept
      CHECK(t[0] + t[1] + t[2] == 6.0 && t[3] * t[3] + t[4] * t[4] + t[5] * t[5] == 77.0);
    }
    PrintFrame f;
    std::string why;
    CHECK(print_frame_for_up({1, 1, 0}, f, &why) && !f.exact);   // Phase 2: any up, a rotation
    CHECK(!print_frame_for_up({0, 0, 0}, f, &why));
    CHECK(print_frame_for_up({1, 0, 0}, f));
    const Vec3 a = f.point_to_print({1, 2, 3});
    const Vec3 b = hand({1, 2, 3});
    CHECK(a.x == b.x && a.y == b.y && a.z == b.z);   // the library's +X turn IS this file's
    double six[6] = {1, 2, 3, 4, 5, 6}, out[6];       // -x +x -y +y -z +z, print
    f.axis_six_to_model(six, out);
    // model x = print z: model -x/+x = print -z/+z; model y = print y; model z = -print x: model -z = print +x
    CHECK(out[0] == 5 && out[1] == 6 && out[2] == 3 && out[3] == 4 && out[4] == 2 && out[5] == 1);
    CHECK(print_frame_json(f) ==
          "{\"up\": [1, 0, 0], \"rotation_row_major\": [0, 0, -1, 0, 1, 0, 1, 0, 0], \"translation_mm\": [0, 0, 0]}");
  }

  // ── the part, A's inputs and B's (turned by hand)
  const TriangleMesh part = bracket();
  write_stl_file(kDir + "/part.stl", part, StlFormat::Binary);
  TriangleMesh turned = part;
  for (Vec3& v : turned.vertices) v = hand(v);
  write_stl_file(kDir + "/part_turned.stl", turned, StlFormat::Binary);
  Job a, b;
  a.model = "part.stl";
  b.model = "part_turned.stl";
  {
    const StepModel ma = import_part_file_resolved(kDir + "/part.stl"), mb = import_part_file_resolved(kDir + "/part_turned.stl");
    a.top = face_at(ma, {0, 0, 1}, 6.0);
    a.bottom = face_at(ma, {0, 0, -1}, 0.0);
    a.wall_top = face_at(ma, {0, 0, 1}, 30.0);
    b.top = face_at(mb, {-1, 0, 0}, 6.0);   // model +Z is print -X
    b.bottom = face_at(mb, {1, 0, 0}, 0.0);
    b.wall_top = face_at(mb, {-1, 0, 0}, 30.0);
    std::printf("faces A: top %d bottom %d wall %d (of %d); B: top %d bottom %d wall %d (of %d)\n", a.top, a.bottom,
                a.wall_top, ma.face_count, b.top, b.bottom, b.wall_top, mb.face_count);
    CHECK(a.top >= 0 && a.bottom >= 0 && a.wall_top >= 0);
    CHECK(b.top == a.top && b.bottom == a.bottom && b.wall_top == a.wall_top);   // the same faces, the same ids
  }
  // The tensor, and B's turned by hand: B's grid x is -A's z, y is y, z is A's x.
  {
    TensorField t;
    t.origin = {-2, -2, -2};
    t.spacing = 1.0;
    t.nx = 44; t.ny = 28; t.nz = 34;
    t.voigt.assign(6 * static_cast<std::size_t>(t.nx) * t.ny * t.nz, 0.0);
    for (int k = 0; k < t.nz; ++k)
      for (int j = 0; j < t.ny; ++j)
        for (int i = 0; i < t.nx; ++i)
          tensor_at({t.origin.x + i + 0.5, t.origin.y + j + 0.5, t.origin.z + k + 0.5}, &t.voigt[6 * t.index(i, j, k)]);
    CHECK(write_tensor_file(kDir + "/stress.tensor", t));
    TensorField u;
    u.spacing = 1.0;
    u.nx = t.nz; u.ny = t.ny; u.nz = t.nx;
    u.origin = {0.0 - (t.origin.z + t.spacing * t.nz), t.origin.y, t.origin.x};
    u.voigt.assign(t.voigt.size(), 0.0);
    // The file holds float32: B is made from what A's file holds.
    TensorField t32;
    CHECK(read_tensor_file(kDir + "/stress.tensor", t32));
    for (int k = 0; k < u.nz; ++k)
      for (int j = 0; j < u.ny; ++j)
        for (int i = 0; i < u.nx; ++i) {
          const double* s = &t32.voigt[6 * t32.index(k, j, t.nz - 1 - i)];
          double* o = &u.voigt[6 * u.index(i, j, k)];
          // print = (-z, y, x): xx' = zz, yy' = yy, zz' = xx, xy' = -zy, yz' = yx, zx' = -xz
          o[0] = s[2];
          o[1] = s[1];
          o[2] = s[0];
          o[3] = 0.0 - s[4];
          o[4] = s[3];
          o[5] = 0.0 - s[5];
        }
    CHECK(write_tensor_file(kDir + "/stress_turned.tensor", u));
  }
  a.tensor = "stress.tensor";
  b.tensor = "stress_turned.tensor";
  a.strength = "strength_a.json";
  b.strength = "strength_b.json";
  // The No-lattice zone in the plate's lattice, and B's turned by hand.
  a.zone = "{\"kind\": \"box\", \"centre\": [24, 12, 3], \"axes\": [[1, 0, 0], [0, 1, 0], [0, 0, 1]], \"half_mm\": [4, 5, 4]}";
  b.zone = "{\"kind\": \"box\", \"centre\": " + v3s(hand({24, 12, 3})) + ", \"axes\": [" + v3s(hand({1, 0, 0})) + ", " +
           v3s(hand({0, 1, 0})) + ", " + v3s(hand({0, 0, 1})) + "], \"half_mm\": [4, 5, 4]}";
  write(kDir + "/strength_a.json", strength_job(a, {0, 0, -50}, {0, 0, 1}, false));
  write(kDir + "/strength_b.json", strength_job(b, hand({0, 0, -50}), hand({0, 0, 1}), true));
  a.extra = ", \"print_frame\": {\"up\": [1, 0, 0]}";
  write(kDir + "/job_a.json", file_job(a));
  write(kDir + "/job_b.json", file_job(b));
  Job plain = a;
  plain.extra = "";
  write(kDir + "/job_plain.json", file_job(plain));

  // ── A and B
  const Run A = run("a", "job_a.json");
  const Run B = run("b", "job_b.json");
  CHECK(A.r.ok && B.r.ok && A.r.strength_ran && B.r.strength_ran);
  CHECK(A.r.weave_regions == 1 && A.r.bars > 0);
  const bool match = a_matches_b(A, B);
  std::printf("[A vs B] %s\n", match ? "the same" : "DIFFERENT");
  CHECK(match);

  // ── A's own facts
  {
    CHECK(A.json.find("\"print_frame\": {\"up\": [1, 0, 0], \"rotation_row_major\": [0, 0, -1, 0, 1, 0, 1, 0, 0], "
                      "\"translation_mm\": [0, 0, 0]}") != std::string::npos);
    const double layer = 0.2;
    std::printf("[A] layers %d first_layer_mm2 %.6g bed_contact_mm2 %.6g\n", A.r.made.layers.layers,
                A.r.made.layers.first_layer_mm2, A.r.made.bed_contact_mm2);
    CHECK(std::abs(A.r.made.layers.layers - static_cast<int>(std::lround(40.0 / layer))) <= 1);   // the X extent, in layers
    CHECK(std::fabs(A.r.made.layers.first_layer_mm2 - 24.0 * 30.0) < 0.02 * 720.0);   // the face whose normal is -X: 24 x 30
    CHECK(A.json.find("\"build_direction\": {\"x\": 1, \"y\": 0, \"z\": 0}") != std::string::npos);
    // The file stands on z = 0, its height the X extent.
    StepModel m3 = import_part_file_resolved(A.out + "/part_lattice.3mf");
    double lo = 1e300, hi = -1e300;
    for (const Vec3& v : m3.mesh.vertices) { lo = std::min(lo, v.z); hi = std::max(hi, v.z); }
    std::printf("[A] file z %.6g .. %.6g\n", lo, hi);
    CHECK(std::fabs(lo) < 1e-6 && std::fabs(hi - 40.0) < 1e-3);
  }
  // ── P4: the print orientation ranking: six candidates, as placed first (the frame's up, in the part's coordinates);
  // as placed, its guessed strength is the check's own (the solid's effective margin, the struts' smallest).
  {
    try {
      const sj::Value j = sj::parse(A.json, "A");
      const sj::Value* po = sj::find(j, "print_orientation");
      const sj::Value* st = sj::find(j, "strength");
      CHECK(po && st);
      if (po && st) {
        const sj::Value& cands = sj::require(*po, "candidates", "po");
        CHECK(cands.arr.size() >= 2);   // Phase 2: the hull's faces and edges
        const sj::Value& c0 = cands.arr.at(0);
        const sj::Value& up = sj::require(c0, "up", "c0");
        CHECK(up.arr.size() == 3 && up.arr[0].num == 1.0 && up.arr[1].num == 0.0 && up.arr[2].num == 0.0);
        CHECK(sj::require(c0, "as_placed", "c0").boolean);
        const sj::Value& s0 = sj::require(c0, "strength", "c0");
        const double solid = sj::require(s0, "solid", "s0").num;
        const double eff = sj::require(sj::require(*st, "solid_margin", "st"), "effective", "sm").num;
        const sj::Value& struts = sj::require(s0, "struts", "s0");
        const double smallest = sj::require(sj::require(*st, "struts", "st"), "smallest_margin", "ss").num;
        std::printf("[A] as placed: solid %.6g (check %.6g), struts %.6g (check %.6g); recommended %d, change %d\n", solid,
                    eff, struts.is_number() ? struts.num : -1.0, smallest,
                    static_cast<int>(sj::require(*po, "recommended", "po").num), sj::require(*po, "change", "po").boolean);
        CHECK(std::fabs(solid - eff) <= 1e-9 * std::max(1.0, eff));
        CHECK(!struts.is_number() || std::fabs(struts.num - smallest) <= 1e-9 * std::max(1.0, smallest));
        int offered = 0;
        for (const sj::Value& c : cands.arr) offered += sj::require(c, "offered", "c").boolean;
        CHECK(offered >= 1);
      }
    } catch (const std::exception& e) {
      CHECK(false);
      std::printf("  print_orientation not read: %s\n", e.what());
    }
  }
  // ── no frame: no "print_frame" key, and the file as the job made it before (its own up)
  {
    const Run P = run("plain", "job_plain.json");
    CHECK(P.r.ok && P.json.find("\"print_frame\"") == std::string::npos);
    CHECK(P.json.find("\"build_direction\": {\"x\": 0, \"y\": 0, \"z\": 1}") != std::string::npos);
  }

  // ── P3: standing on the plate's end (up = -X) the wall's inner face (24 x 24 mm) hangs 32 mm over the bed: the part's
  // own overhang, painted (only that face, only the solid's triangles), support on for it only (Tree (manual)); A, as
  // placed on the wall's end, has nothing to paint and its file carries no paint and no settings.
  {
    Job u = a;
    u.extra = ", \"print_frame\": {\"up\": [-1, 0, 0]}";
    write(kDir + "/job_u.json", file_job(u));
    const Run U = run("u", "job_u.json");
    std::printf("[U] ok %d slicer_supports %s places %zu painted %zu triangles, %.6g mm2, est %.6g mm3, base %zu\n", U.r.ok,
                U.json.find("\"slicer_supports\": \"painted\"") != std::string::npos ? "painted" : "not painted",
                U.r.part_overhang_places, U.r.painted.triangles, U.r.painted.area_mm2, U.r.painted.est_volume_mm3,
                U.r.made.base_triangles);
    CHECK(U.r.ok && U.json.find("\"slicer_supports\": \"painted\"") != std::string::npos);
    CHECK(U.r.painted.triangles > 0 && std::fabs(U.r.painted.area_mm2 - 24.0 * 24.0) < 1e-6);
    CHECK(std::fabs(U.r.painted.est_volume_mm3 - 24.0 * 24.0 * 32.0) < 24.0 * 24.0 * 1.0);   // to the bed, read every mm
    bool only_solid = true;
    for (std::size_t i = U.r.made.base_triangles; i < U.r.painted.painted.size(); ++i) only_solid = only_solid && !U.r.painted.painted[i];
    CHECK(only_solid);
    const std::string zip = slurp(U.out + "/part_lattice.3mf");
    CHECK(zip.find("Metadata/model_settings.config") != std::string::npos &&
          zip.find("Metadata/Slic3r_PE_model.config") != std::string::npos);
    // Every painted place is in the part's own coordinates: on the wall's inner face (x = 8), above the plate.
    for (const Vec3& p : U.r.painted.at) CHECK(std::fabs(p.x - 8.0) < 0.5 && p.z > 6.0 - 0.5);
    const std::string za = slurp(A.out + "/part_lattice.3mf");
    CHECK(A.json.find("\"slicer_supports\": \"off\"") != std::string::npos && za.find("Metadata/") == std::string::npos);
  }
  // ── a strengthening made standing another way is refused, never applied (strengthened.json's "print_up")
  {
    write(kDir + "/strengthened_flat.json", "{\"version\": 2, \"mode\": \"additive\", \"additions\": \"none.bin\"}");
    write(kDir + "/strengthened_x.json",
          "{\"version\": 2, \"mode\": \"additive\", \"additions\": \"none.bin\", \"print_up\": [1, 0, 0]}");
    Job s = a;
    s.extra = ", \"print_frame\": {\"up\": [1, 0, 0]}, \"strengthened\": \"strengthened_flat.json\"";
    write(kDir + "/job_s1.json", file_job(s));
    const Run S1 = run("s1", "job_s1.json");
    CHECK(!S1.r.ok && S1.r.code == "strengthened_mismatch");
    s.extra = ", \"strengthened\": \"strengthened_x.json\"";   // no frame, a strengthening made with one
    write(kDir + "/job_s2.json", file_job(s));
    const Run S2 = run("s2", "job_s2.json");
    CHECK(!S2.r.ok && S2.r.code == "strengthened_mismatch");
    s.extra = ", \"print_frame\": {\"up\": [1, 0, 0]}, \"strengthened\": \"strengthened_x.json\"";   // the same up: read on
    write(kDir + "/job_s3.json", file_job(s));
    const Run S3 = run("s3", "job_s3.json");
    CHECK(!S3.r.ok && S3.r.code == "strengthened_unreadable");   // (its additions file is not there: read, not refused for the up)
  }
  // ── PHASE 2 (his 11-23 evening: the 45 degree sides, and edges held by supports): ANY up. The bracket stood on the
  // edge between its underside and the plate's end (up = (-1, 0, 1)/sqrt2: both faces at 45 degrees), against a copy
  // turned BY HAND (a 45 degree turn about +Y, this file's own; the STL rounds it to float, the tensor written from the
  // same linear field at the turned places): no longer the same bytes (a rotation rounds), but the same lattice within a
  // stated tolerance: bars and strut volume within 5 %, the solid's margin within 3 %, the weakest strut's within 25 %
  // (the traced lay follows the stress lines, and a 1e-6 mm rounding of the part moves a few of them: measured 17 %),
  // the same verdicts, the same stand on the edge, and as few of the file's points inside the turned No-lattice zone;
  // the  // same verdicts, the same stand on the edge. Each input left unturned is caught by the same tolerance.
  {
    const double cq = 1.0 / std::sqrt(2.0);
    const auto rot = [&](const Vec3& p) { return Vec3{cq * p.x + cq * p.z, p.y, -cq * p.x + cq * p.z}; };
    double tz = 1e300;
    for (const Vec3& v : part.vertices) tz = std::min(tz, rot(v).z);
    tz = 0.0 - tz;
    const auto turn_g = [&](const Vec3& p) { const Vec3 q = rot(p); return Vec3{q.x, q.y, q.z + tz}; };
    TriangleMesh tg = part;
    for (Vec3& v : tg.vertices) v = turn_g(v);
    write_stl_file(kDir + "/part_g.stl", tg, StlFormat::Binary);
    {   // B_g's tensor: the same linear field, at each turned place, turned (R s R^T), on the grid a turn of A's grid
        // lands on (its box turned, the same pitch: the grid is the door's convention; the VALUES are this file's own)
      Vec3 lo{1e300, 1e300, 1e300}, hi{-1e300, -1e300, -1e300};
      for (int c = 0; c < 8; ++c) {
        const Vec3 v = turn_g({c & 1 ? 42.0 : -2.0, c & 2 ? 26.0 : -2.0, c & 4 ? 32.0 : -2.0});
        lo = {std::min(lo.x, v.x), std::min(lo.y, v.y), std::min(lo.z, v.z)};
        hi = {std::max(hi.x, v.x), std::max(hi.y, v.y), std::max(hi.z, v.z)};
      }
      TensorField u;
      u.spacing = 1.0;
      u.origin = lo;
      u.nx = std::max(1, static_cast<int>(std::ceil((hi.x - lo.x) - 1e-9)));
      u.ny = std::max(1, static_cast<int>(std::ceil((hi.y - lo.y) - 1e-9)));
      u.nz = std::max(1, static_cast<int>(std::ceil((hi.z - lo.z) - 1e-9)));
      u.voigt.assign(6 * static_cast<std::size_t>(u.nx) * u.ny * u.nz, 0.0);
      const double Rm[3][3] = {{cq, 0, cq}, {0, 1, 0}, {-cq, 0, cq}};
      for (int k = 0; k < u.nz; ++k)
        for (int j = 0; j < u.ny; ++j)
          for (int i = 0; i < u.nx; ++i) {
            const Vec3 q{u.origin.x + i + 0.5, u.origin.y + j + 0.5, u.origin.z + k + 0.5 - tz};
            Vec3 p{Rm[0][0] * q.x + Rm[1][0] * q.y + Rm[2][0] * q.z, Rm[0][1] * q.x + Rm[1][1] * q.y + Rm[2][1] * q.z,
                   Rm[0][2] * q.x + Rm[1][2] * q.y + Rm[2][2] * q.z};   // R^T q
            if (p.x < -2 || p.y < -2 || p.z < -2 || p.x > 42 || p.y > 26 || p.z > 32) continue;   // outside A's grid: 0
            // within half a voxel of A's box: A's edge voxels' value (the field at the nearest voxel centre's plane)
            p = {std::min(41.5, std::max(-1.5, p.x)), std::min(25.5, std::max(-1.5, p.y)), std::min(31.5, std::max(-1.5, p.z))};
            double s[6];
            tensor_at(p, s);
            const double S[3][3] = {{s[0], s[3], s[5]}, {s[3], s[1], s[4]}, {s[5], s[4], s[2]}};
            double T[3][3];
            for (int x = 0; x < 3; ++x)
              for (int y = 0; y < 3; ++y) {
                T[x][y] = 0.0;
                for (int m = 0; m < 3; ++m)
                  for (int nn = 0; nn < 3; ++nn) T[x][y] += Rm[x][m] * S[m][nn] * Rm[y][nn];
              }
            double* o = &u.voigt[6 * u.index(i, j, k)];
            o[0] = T[0][0]; o[1] = T[1][1]; o[2] = T[2][2]; o[3] = T[0][1]; o[4] = T[1][2]; o[5] = T[2][0];
          }
      CHECK(write_tensor_file(kDir + "/stress_g.tensor", u));
    }
    Job ag = a, bg = b;
    ag.extra = ", \"print_frame\": {\"up\": [-0.7071067811865476, 0, 0.7071067811865476]}";
    bg.model = "part_g.stl";
    bg.tensor = "stress_g.tensor";
    bg.strength = "strength_bg.json";
    bg.top = a.top;
    bg.bottom = a.bottom;
    bg.wall_top = a.wall_top;
    const auto rv = [&](const Vec3& d) { return rot(d); };
    bg.zone = "{\"kind\": \"box\", \"centre\": " + v3s(turn_g({24, 12, 3})) + ", \"axes\": [" + v3s(rv({1, 0, 0})) + ", " +
              v3s(rv({0, 1, 0})) + ", " + v3s(rv({0, 0, 1})) + "], \"half_mm\": [4, 5, 4]}";
    // a load that matters (3 kN): margins that mean something
    write(kDir + "/strength_bg.json", strength_job(bg, rv({0, 0, -3000}), rv({0, 0, 1}), true));
    write(kDir + "/strength_ag.json", strength_job(a, {0, 0, -3000}, {0, 0, 1}, false));
    ag.strength = "strength_ag.json";
    bg.extra = "";
    write(kDir + "/job_ag.json", file_job(ag));
    write(kDir + "/job_bg.json", file_job(bg));
    struct Facts { bool ok = false; double bars = 0, struts_mm3 = 0, solid = 0, smallest = 0; std::size_t in_zone = 0; std::string verdict; bool clean = false;
                   bool stand = false, stands = false; double band0 = 0, band1 = 0; std::size_t stand_tris = 0; };
    const auto facts = [&](const Run& x) {
      Facts f;
      f.ok = x.r.ok;
      if (!x.r.ok) return f;
      const sj::Value j = sj::parse(x.json, "x");
      f.bars = static_cast<double>(x.r.bars);
      f.struts_mm3 = x.r.made.mesh.struts_mm3 + x.r.made.shells.mm3;
      const sj::Value& st = sj::require(j, "strength", "j");
      f.solid = sj::require(sj::require(st, "solid_margin", "st"), "effective", "sm").num;
      f.smallest = sj::require(sj::require(st, "struts", "st"), "smallest_margin", "ss").num;
      f.verdict = sj::require(st, "verdict", "st").str;
      f.clean = x.r.made.print_clean;
      f.stand = x.r.stand_edge;
      f.stands = x.r.stand.stands;
      f.band0 = x.r.stand.band1_mm;
      f.band1 = x.r.stand.band2_mm;
      f.stand_tris = x.r.stand_triangles;
      {   // the file's points inside the turned No-lattice zone (1 mm in): few when the zone was turned with the
          // part (solid there), many when it was not (lattice tubes)
        const StepModel fm = import_part_file_resolved(x.out + "/part_lattice.3mf");
        const Vec3 zc = turn_g({24, 12, 3}), z0 = rot({1, 0, 0}), z1 = rot({0, 1, 0}), z2 = rot({0, 0, 1});
        const double hz[3] = {3.0, 4.0, 2.5};
        for (const Vec3& v : fm.mesh.vertices) {
          const Vec3 d{v.x - zc.x, v.y - zc.y, v.z - zc.z};
          f.in_zone += std::fabs(d.x * z0.x + d.y * z0.y + d.z * z0.z) < hz[0] && std::fabs(d.x * z1.x + d.y * z1.y + d.z * z1.z) < hz[1] &&
                       std::fabs(d.x * z2.x + d.y * z2.y + d.z * z2.z) < hz[2];
        }
      }
      return f;
    };
    const auto near = [](double u, double w, double rel) { return std::fabs(u - w) <= rel * std::max(std::fabs(u), std::fabs(w)) + 1e-9; };
    const auto close = [&](const Facts& x, const Facts& y, bool say) {
      const bool ok = x.ok && y.ok && near(x.bars, y.bars, 0.05) && near(x.struts_mm3, y.struts_mm3, 0.05) &&
                      near(x.solid, y.solid, 0.03) && near(x.smallest, y.smallest, 0.25) && x.verdict == y.verdict &&
                      std::fabs(static_cast<double>(x.in_zone) - static_cast<double>(y.in_zone)) <= 20.0 + 0.25 * static_cast<double>(y.in_zone) &&
                      x.clean == y.clean && x.stand == y.stand && x.stands == y.stands &&
                      std::fabs(x.band0 - y.band0) <= 1.0 && std::fabs(x.band1 - y.band1) <= 1.0;
      if (say)
        std::printf("  in the zone %zu / %zu, bars %.0f / %.0f, struts %.6g / %.6g mm3, solid %.4g / %.4g, struts' smallest %.4g / %.4g, verdict %s / %s, "
                    "clean %d / %d, stand %d / %d stands %d / %d, bands [%.3g %.3g] / [%.3g %.3g], stand triangles %zu / %zu\n",
                    x.in_zone, y.in_zone, x.bars, y.bars, x.struts_mm3, y.struts_mm3, x.solid, y.solid, x.smallest, y.smallest, x.verdict.c_str(),
                    y.verdict.c_str(), x.clean, y.clean, x.stand, y.stand, x.stands, y.stands, x.band0, x.band1, y.band0,
                    y.band1, x.stand_tris, y.stand_tris);
      return ok;
    };
    const Run AG = run("ag", "job_ag.json");
    const Run BG = run("bg", "job_bg.json");
    const Facts fa = facts(AG), fb = facts(BG);
    const bool g_ok = close(fa, fb, true);
    std::printf("[A_g vs B_g, up (-1, 0, 1)/sqrt2] %s\n", g_ok ? "within the tolerance" : "OUTSIDE the tolerance");
    CHECK(g_ok);
    CHECK(AG.json.find("\"rotation_row_major\": [0.7071067812, 0, 0.7071067812, 0, 1, 0, -0.7071067812, 0, 0.7071067812]") !=
          std::string::npos);
    // it rests on an edge: its stand supports painted, Tree (manual) in the file
    CHECK(fa.stand && fa.stands && fa.stand_tris > 0 && AG.json.find("\"slicer_supports\": \"painted\"") != std::string::npos);
    CHECK(slurp(AG.out + "/part_lattice.3mf").find("Metadata/model_settings.config") != std::string::npos);
    for (const auto& [bit, name] : std::vector<std::pair<unsigned, const char*>>{
             {kSkipTensor, "tensor"}, {kSkipZones, "zones"}, {kSkipStrengthJob, "strength job"}}) {
      g_print_frame_test_skip = bit;
      const Run M = run(std::string("g_skip_") + std::to_string(bit), "job_ag.json");
      g_print_frame_test_skip = 0;
      const bool differs = !close(facts(M), fb, true);
      std::printf("[general mutation: %s left unturned] %s\n", name, differs ? "differs (caught)" : "within (NOT caught)");
      CHECK(differs);
    }
  }
  // ── the resampling's cost and accuracy on a real tensor (PRINT_FRAME_TENSOR: a tensor.bin, read only; his stand's for
  // the report). Reported, not judged: the round trip (turned, then read back at the source's own voxel centres) and the
  // most tension across the layers for three ups (the field's turn leaves it unchanged in an exact resample).
  if (const char* path = std::getenv("PRINT_FRAME_TENSOR")) {
    TensorField t0;
    std::string why;
    if (read_tensor_file(path, t0, &why)) {
      for (const Vec3& up : {Vec3{0, 1, 1}, Vec3{1, 0, 1}, Vec3{1, 1, 1}}) {
        PrintFrame f;
        print_frame_for_up(up, f);
        const int n[3] = {t0.nx, t0.ny, t0.nz};
        int no[3];
        Vec3 oo;
        const auto c0 = std::chrono::steady_clock::now();
        const std::vector<double> r = turn_grid_values(f, true, n, t0.origin, t0.spacing, t0.voigt, 6, no, oo);
        const double ms = std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - c0).count();
        // read the turned field back at every source voxel centre (trilinear), turned back
        const auto vm = [](const double* s) {
          return std::sqrt(0.5 * ((s[0] - s[1]) * (s[0] - s[1]) + (s[1] - s[2]) * (s[1] - s[2]) + (s[2] - s[0]) * (s[2] - s[0])) +
                           3.0 * (s[3] * s[3] + s[4] * s[4] + s[5] * s[5]));
        };
        double vmax = 0.0;
        for (std::size_t e = 0; e < t0.voigt.size() / 6; ++e) vmax = std::max(vmax, vm(&t0.voigt[6 * e]));
        std::vector<double> errs;
        for (int k = 0; k < n[2]; ++k)
          for (int j = 0; j < n[1]; ++j)
            for (int i = 0; i < n[0]; ++i) {
              const double* s0 = &t0.voigt[6 * t0.index(i, j, k)];
              if (vm(s0) < 0.1 * vmax) continue;
              const Vec3 q = f.point_to_print({t0.origin.x + (i + 0.5) * t0.spacing, t0.origin.y + (j + 0.5) * t0.spacing,
                                               t0.origin.z + (k + 0.5) * t0.spacing});
              double g[3] = {(q.x - oo.x) / t0.spacing - 0.5, (q.y - oo.y) / t0.spacing - 0.5, (q.z - oo.z) / t0.spacing - 0.5};
              int i0[3];
              double w[3];
              for (int a2 = 0; a2 < 3; ++a2) {
                i0[a2] = std::min(std::max(0, static_cast<int>(std::floor(g[a2]))), no[a2] - 2);
                w[a2] = std::min(1.0, std::max(0.0, g[a2] - i0[a2]));
              }
              double s1[6] = {0, 0, 0, 0, 0, 0};
              for (int cc = 0; cc < 8; ++cc) {
                const int di = cc & 1, dj = (cc >> 1) & 1, dk = (cc >> 2) & 1;
                const double wt = (di ? w[0] : 1 - w[0]) * (dj ? w[1] : 1 - w[1]) * (dk ? w[2] : 1 - w[2]);
                const std::size_t e = 6 * ((static_cast<std::size_t>(i0[2] + dk) * no[1] + (i0[1] + dj)) * no[0] + (i0[0] + di));
                for (int c2 = 0; c2 < 6; ++c2) s1[c2] += wt * r[e + static_cast<std::size_t>(c2)];
              }
              errs.push_back(std::fabs(vm(s1) - vm(s0)) / vmax);   // von Mises is the same in any frame
            }
          std::sort(errs.begin(), errs.end());
        const double med = errs.empty() ? 0.0 : errs[errs.size() / 2], p95 = errs.empty() ? 0.0 : errs[errs.size() * 95 / 100];
        std::printf("[his tensor %d x %d x %d -> %d x %d x %d, up (%g, %g, %g)] %.1f ms; von Mises after the round trip, of the "
                    "largest: median %.3g, 95th %.3g, worst %.3g (%zu voxels above a tenth of it)\n",
                    n[0], n[1], n[2], no[0], no[1], no[2], up.x, up.y, up.z, ms, med, p95, errs.empty() ? 0.0 : errs.back(),
                    errs.size());
      }
    } else {
      std::printf("[his tensor] not read: %s\n", why.c_str());
    }
  }

  // ── the mutation guard: each input left unturned makes A differ from B
  for (const auto& [bit, name] : std::vector<std::pair<unsigned, const char*>>{
           {kSkipTensor, "tensor"}, {kSkipZones, "zones"}, {kSkipStrengthJob, "strength job"},
           {kSkipStrengthModel, "strength job's part"}, {kSkipReportBack, "report back"}}) {
    g_print_frame_test_skip = bit;
    const Run M = run(std::string("skip_") + std::to_string(bit), "job_a.json");
    g_print_frame_test_skip = 0;
    const bool differs = !M.r.ok || !a_matches_b(M, B, true);
    std::printf("[mutation: %s left unturned] %s\n", name, differs ? "differs (caught)" : "THE SAME (not caught)");
    CHECK(differs);
  }

  std::printf("%d checks, %d failed\n", g_checks, g_fail);
  return g_fail == 0 ? 0 : 1;
}
