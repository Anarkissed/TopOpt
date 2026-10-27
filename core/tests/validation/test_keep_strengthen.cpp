// PROTECT on a GROWTH run (ruling 2026-10-27 03:57): a protected surface comes out as
// the exact CAD AND nothing grows within its reach. A protected hole's own air stays
// open; the band a keep region reaches past a protected face stays empty. The keep
// regions' air is a Keep Clear (build_clearance_overlay), so the export's plain cut
// only ever removes voxel skin and the file is the design strengthen certified.
//
// Through run_job, Redesign to strengthen, on a bar (40 x 10.6 x 10.6 mm, built with
// Manifold, a vertical bore r 2.5 at mid-span) held at one end, 50 N down on the other,
// the design box over and under it. Keep regions: the bore (r 2.5 + 2, 1.9 mm past
// each open end, oriented form) and the top face (min/max form, 2 mm in, 1.9 mm out).
//   (0) control, the same run unprotected: growth enters the bore and the top band;
//   (a) protected, no printed voxel centred in either region outside the part, in
//       every version's design (and strengthen's Keep Clear count is 0);
//   (b) the bore's fitted diameter within 0.05 mm of the CAD and round;
//   (c) the top face on the CAD plane within 0.02 mm;
//   (d) one closed shell per version;
//   (e) every version strengthen verified has its own file, verified (a version
//       accepted on its verified margin with its in-loop margin under the gate had no
//       file before: in loop 1.32, verified 2.43, target 1.5 here).

#include "topopt/job.hpp"
#include "topopt/materials.hpp"
#include "topopt/mesh.hpp"
#include "topopt/part.hpp"
#include "topopt/settings.hpp"
#include "topopt/step.hpp"
#include "topopt/stl.hpp"

#include <manifold/manifold.h>

#include <algorithm>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <fstream>
#include <limits>
#include <map>
#include <string>
#include <utility>
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

constexpr double kX = 40.0, kY = 10.6, kZ = 10.6;
constexpr double kBoreX = 20.0, kBoreY = 5.3, kBoreR = 2.5;
constexpr double kDepth = 2.0, kReach = 1.9;  // into the part / out into the air

Vec3 sub(const Vec3& a, const Vec3& b) { return {a.x - b.x, a.y - b.y, a.z - b.z}; }
double dot(const Vec3& a, const Vec3& b) { return a.x * b.x + a.y * b.y + a.z * b.z; }
Vec3 cross(const Vec3& a, const Vec3& b) {
  return {a.y * b.z - a.z * b.y, a.z * b.x - a.x * b.z, a.x * b.y - a.y * b.x};
}

TriangleMesh build_part() {
  using manifold::Manifold;
  const Manifold bar = Manifold::Cube({kX, kY, kZ}) -
                       Manifold::Cylinder(3.0 * kZ, kBoreR, -1.0, 128, true)
                           .Translate({kBoreX, kBoreY, 0.5 * kZ});
  const manifold::MeshGL g = bar.GetMeshGL();
  TriangleMesh out;
  for (std::size_t v = 0; v < g.NumVert(); ++v)
    out.vertices.push_back({g.vertProperties[v * g.numProp], g.vertProperties[v * g.numProp + 1],
                            g.vertProperties[v * g.numProp + 2]});
  for (std::size_t t = 0; t < g.NumTri(); ++t)
    out.triangles.push_back({static_cast<int>(g.triVerts[3 * t]),
                             static_cast<int>(g.triVerts[3 * t + 1]),
                             static_cast<int>(g.triVerts[3 * t + 2])});
  return out;
}

int face_facing(const StepModel& model, double nx, double ny, double nz) {
  for (int f = 0; f < model.face_count; ++f) {
    const Vec3& n = model.faces[static_cast<std::size_t>(f)].plane_normal;
    if (model.faces[static_cast<std::size_t>(f)].kind == StepSurfaceKind::Plane &&
        n.x * nx + n.y * ny + n.z * nz > 0.99)
      return f;
  }
  return -1;
}

// The nearest hit of the ray o + s*d (s > 0) on the mesh, +inf when none.
double ray_hit(const TriangleMesh& m, const Vec3& o, const Vec3& d) {
  double best = std::numeric_limits<double>::infinity();
  for (const auto& t : m.triangles) {
    const Vec3& a = m.vertices[static_cast<std::size_t>(t[0])];
    const Vec3 e1 = sub(m.vertices[static_cast<std::size_t>(t[1])], a);
    const Vec3 e2 = sub(m.vertices[static_cast<std::size_t>(t[2])], a);
    const Vec3 p = cross(d, e2);
    const double det = dot(e1, p);
    if (std::fabs(det) < 1e-14) continue;
    const Vec3 s = sub(o, a);
    const double u = dot(s, p) / det;
    if (u < -1e-9 || u > 1.0 + 1e-9) continue;
    const Vec3 q = cross(s, e1);
    const double v = dot(d, q) / det;
    if (v < -1e-9 || u + v > 1.0 + 1e-9) continue;
    const double h = dot(e2, q) / det;
    if (h > 1e-9 && h < best) best = h;
  }
  return best;
}

// The bore as the file has it: 5 sections through the bar, 36 rays out from the axis
// each, a least-squares (Kasa) circle per section. Mean diameter, worst out-of-round
// (max - min distance from the fitted centre), and rays that hit nothing.
struct BoreFit {
  double diameter = 0.0;
  double out_of_round = 0.0;
  int misses = 0;
};
BoreFit fit_bore(const TriangleMesh& m) {
  BoreFit f;
  int sections = 0;
  for (double z : {1.5, 3.4, 5.3, 7.2, 9.1}) {
    std::vector<std::pair<double, double>> pts;
    for (int a = 0; a < 36; ++a) {
      const double th = (a + 0.5) * 2.0 * M_PI / 36.0;
      const double r = ray_hit(m, Vec3{kBoreX, kBoreY, z}, Vec3{std::cos(th), std::sin(th), 0.0});
      if (std::isfinite(r)) pts.push_back({r * std::cos(th), r * std::sin(th)});
      else ++f.misses;
    }
    if (pts.size() < 3) continue;
    double A[3][3] = {}, b[3] = {};
    for (const auto& p : pts) {
      const double row[3] = {p.first, p.second, 1.0};
      const double rhs = -(p.first * p.first + p.second * p.second);
      for (int i = 0; i < 3; ++i) {
        for (int j = 0; j < 3; ++j) A[i][j] += row[i] * row[j];
        b[i] += row[i] * rhs;
      }
    }
    for (int c = 0; c < 3; ++c)
      for (int r = 0; r < 3; ++r) {
        if (r == c) continue;
        const double k = A[r][c] / A[c][c];
        for (int j = 0; j < 3; ++j) A[r][j] -= k * A[c][j];
        b[r] -= k * b[c];
      }
    const double cx = -0.5 * b[0] / A[0][0], cy = -0.5 * b[1] / A[1][1];
    const double rad = std::sqrt(cx * cx + cy * cy - b[2] / A[2][2]);
    double lo = 1e9, hi = -1e9;
    for (const auto& p : pts) {
      const double r = std::hypot(p.first - cx, p.second - cy);
      lo = std::min(lo, r);
      hi = std::max(hi, r);
    }
    f.diameter += 2.0 * rad;
    f.out_of_round = std::max(f.out_of_round, hi - lo);
    ++sections;
  }
  if (sections > 0) f.diameter /= sections;
  return f;
}

// The top face as the file has it: rays straight down over it, clear of the bore's
// opening by 0.3 mm and of the edges by 0.5 mm. Worst |z - kZ| and misses.
double top_face_worst(const TriangleMesh& m, int* misses) {
  double worst = 0.0;
  *misses = 0;
  for (double x = 0.5; x <= kX - 0.5 + 1e-9; x += 0.5)
    for (double y = 0.5; y <= kY - 0.5 + 1e-9; y += 0.5) {
      if (std::hypot(x - kBoreX, y - kBoreY) < kBoreR + 0.3) continue;
      const double h = ray_hit(m, Vec3{x, y, kZ + 5.0}, Vec3{0.0, 0.0, -1.0});
      if (!std::isfinite(h)) {
        ++*misses;
        continue;
      }
      worst = std::max(worst, std::fabs(kZ + 5.0 - h - kZ));
    }
  return worst;
}

std::string keep_json() {
  char buf[1024];
  std::snprintf(buf, sizeof buf,
                "{\"shape\": \"cylinder\", \"axis_point\": [%.6f, %.6f, %.6f], \"axis_dir\": "
                "[0, 0, 1], \"radius_mm\": %.6f, \"half_length_mm\": %.6f}, "
                "{\"shape\": \"box\", \"min\": [0, 0, %.6f], \"max\": [%.6f, %.6f, %.6f]}",
                kBoreX, kBoreY, 0.5 * kZ, kBoreR + kDepth, 0.5 * kZ + kReach, kZ - kDepth, kX,
                kY, kZ + kReach);
  return buf;
}

std::vector<KeepRegion> parsed_keeps() {
  const std::string path = std::string(TMP_DIR) + "/keep_strengthen_job.json";
  std::ofstream(path) << "{\"model\": \"keep_strengthen_bar.stl\", \"material\": \"PLA\", "
                         "\"mode\": \"minimize_plastic\", \"resolution\": 32, "
                         "\"fixture_faces\": [{\"kind\": \"cylindrical\", \"radius_mm\": 3}], "
                         "\"gravity\": {\"direction\": [0, 0, -1], \"magnitude_mm_s2\": 9810}, "
                         "\"ladder\": [0.5], \"margin_stop\": 1.5, \"keep_regions\": ["
                      << keep_json()
                      << "], \"output\": {\"report\": \"r.json\", \"mesh_format\": \"stl\", "
                         "\"mesh_prefix\": \"v\"}}";
  return load_job_file(path).keep_regions;
}

JobDescription bar_job(const StepModel& model, const std::vector<KeepRegion>& keeps) {
  JobDescription job;
  job.model = "keep_strengthen_bar.stl";
  job.material = "PLA";
  job.mode = "minimize_plastic";
  job.resolution = 32;
  job.has_plsm = true;
  job.plsm_enabled = true;
  job.plsm_max_iterations = 6;
  job.loads.present = true;
  job.loads.minimize_plastic = false;  // growth
  job.loads.redesign = "strengthen";
  job.loads.anchor_face_ids = {face_facing(model, -1, 0, 0)};
  JobLoadGroup g;
  g.face_ids = {face_facing(model, 1, 0, 0)};
  g.force = Vec3{0.0, 0.0, -50.0};
  job.loads.groups.push_back(g);
  job.loads.build_dir = Vec3{0.0, 0.0, 1.0};
  job.has_design_box = true;  // over and under the bar
  job.design_box.min = Vec3{0.0, 0.0, -3.0};
  job.design_box.max = Vec3{kX, kY, kZ + 3.0};
  job.keep_regions = keeps;
  job.bake_build_orientation = "off";  // the files in model coordinates
  job.output.report = "report.json";
  job.output.mesh_format = "stl";
  job.output.mesh_prefix = "variant";
  return job;
}

// Printed voxels centred inside a keep region and outside the part, per accepted rung.
std::vector<long long> grown_in_regions(const RunJobResult& r, const TriangleMesh& part,
                                        const std::vector<KeepRegion>& keeps) {
  std::vector<long long> out;
  const VoxelGrid& g = r.pipeline.solved_grid;
  const VoxelGrid inside = voxelize_onto_grid(part, g);
  for (const MinimizePlasticVariant& v : r.pipeline.evaluated) {
    if (!v.accepted) continue;
    const std::vector<double>& rho = v.optimization.physical_density;
    long long n = 0;
    for (int k = 0; k < g.nz; ++k)
      for (int j = 0; j < g.ny; ++j)
        for (int i = 0; i < g.nx; ++i) {
          if (inside.solid(i, j, k) || rho[g.index(i, j, k)] < 0.5) continue;
          for (const KeepRegion& kr : keeps)
            if (kr.contains(g.voxel_center(i, j, k))) {
              ++n;
              break;
            }
        }
    out.push_back(n);
  }
  return out;
}

}  // namespace

int main() {
  const MaterialLibrary materials = load_materials_file(MATERIALS_JSON_PATH);
  const SettingsRules rules = load_settings_rules_file(SETTINGS_RULES_PATH);
  const std::string dir = TMP_DIR;
  const TriangleMesh cad = build_part();
  write_stl_file(dir + "/keep_strengthen_bar.stl", cad, StlFormat::Binary);
  const StepModel model = import_part(dir + "/keep_strengthen_bar.stl").model;
  const BoreFit bore_cad = fit_bore(cad);
  std::printf("[keep-strengthen] CAD bore diameter %.4f (out of round %.4f)\n",
              bore_cad.diameter, bore_cad.out_of_round);
  CHECK(face_facing(model, -1, 0, 0) >= 0 && face_facing(model, 1, 0, 0) >= 0,
        "precondition: the bar has its two end faces");
  try {
    const std::vector<KeepRegion> keeps = parsed_keeps();
    CHECK(keeps.size() == 2 && keeps[0].oriented && !keeps[1].oriented,
          "precondition: the bore region (oriented) and the top region (min/max) parse");

    // (0) the control: unprotected, growth goes into the bore and onto the top face.
    const RunJobResult ctl = run_job(bar_job(model, {}), dir, dir + "/keep_strengthen_ctl",
                                     materials, rules, false, RunObservability{});
    const std::vector<long long> ctl_grown = grown_in_regions(ctl, cad, keeps);
    long long ctl_max = 0;
    for (long long n : ctl_grown) ctl_max = std::max(ctl_max, n);
    std::printf("[keep-strengthen] control (unprotected): %zu version(s), printed voxels in "
                "the regions' air:", ctl_grown.size());
    for (long long n : ctl_grown) std::printf(" %lld", n);
    std::printf("\n");
    CHECK(ctl_max > 0, "(0) unprotected, growth enters the bore and the top band");

    const RunJobResult r = run_job(bar_job(model, keeps), dir, dir + "/keep_strengthen_out",
                                   materials, rules, false, RunObservability{});
    const std::vector<long long> grown = grown_in_regions(r, cad, keeps);
    CHECK(!grown.empty() && grown.size() == r.mesh_paths.size(),
          "precondition: a file for every accepted version");
    for (std::size_t n = 0; n < grown.size() && n < r.mesh_paths.size(); ++n) {
      const TriangleMesh f = read_stl_file(r.mesh_paths[n]).mesh;
      const BoreFit b = fit_bore(f);
      int misses = 0;
      const double worst = top_face_worst(f, &misses);
      std::map<std::pair<int, int>, int> uses;
      for (const auto& t : f.triangles)
        for (int e = 0; e < 3; ++e) {
          const int a = t[e], c = t[(e + 1) % 3];
          ++uses[{std::min(a, c), std::max(a, c)}];
        }
      int bad = 0;
      for (const auto& kv : uses) bad += kv.second != 2;
      const int bodies = count_components(f);
      std::printf("[keep-strengthen] version %zu: %lld printed voxels in the regions' air; "
                  "bore diameter %.4f (out of round %.4f, %d misses); top face worst %.4f "
                  "mm (%d misses); %d bodies, %d edges not on two triangles\n",
                  n + 1, grown[n], b.diameter, b.out_of_round, b.misses, worst, misses,
                  bodies, bad);
      CHECK(grown[n] == 0, "(a) nothing grows in a protected hole or in front of a face");
      CHECK(b.misses == 0 && std::fabs(b.diameter - bore_cad.diameter) <= 0.05 &&
                b.out_of_round <= bore_cad.out_of_round + 0.01,
            "(b) the bore is the CAD's: diameter within 0.05 mm, round");
      CHECK(misses == 0 && worst <= 0.02, "(c) the top face is on the CAD plane");
      CHECK(bodies == 1 && bad == 0, "(d) one closed shell");
    }
    // (e) + strengthen's own Keep Clear count. A version is written unless "unreachable"
    // or "merged"; its own fields come before its attempts'.
    int written = 0, verified = 0, clear = 0;
    for (std::size_t p = r.report_json.find("{\"version\": "); p != std::string::npos;
         p = r.report_json.find("{\"version\": ", p + 1)) {
      const std::size_t sp = r.report_json.find("\"status\": \"", p) + 11;
      const std::string st = r.report_json.substr(sp, r.report_json.find('"', sp) - sp);
      const double vm =
          std::atof(r.report_json.c_str() + r.report_json.find("\"verified_margin\": ", p) + 19);
      const std::size_t kp = r.report_json.find("\"keep_clear_voxels\": ", p);
      const long long kc = kp == std::string::npos ? -1 : std::atoll(r.report_json.c_str() + kp + 21);
      std::printf("[keep-strengthen] version status %s, verified margin %.4g, Keep Clear "
                  "voxels printed %lld\n", st.c_str(), vm, kc);
      if (st == "unreachable" || st == "merged") continue;
      ++written;
      verified += vm > 0.0;
      clear += kc == 0;
    }
    CHECK(written > 0 && written == static_cast<int>(r.mesh_paths.size()) &&
              verified == written,
          "(e) strengthen verified every written version");
    CHECK(clear == written, "(a) strengthen's Keep Clear check is clean on every version");
  } catch (const std::exception& e) {
    ++g_failures;
    std::fprintf(stderr, "FAIL: threw: %s\n", e.what());
  }

  if (g_failures == 0) {
    std::printf("keep strengthen: all %d checks passed\n", g_checks);
    return 0;
  }
  std::fprintf(stderr, "keep strengthen: %d/%d checks FAILED\n", g_failures, g_checks);
  return 1;
}
