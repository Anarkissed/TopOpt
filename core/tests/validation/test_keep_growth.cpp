// KEEP regions on a GROWTH run (ruling 2026-10-27 02:13). A keep region reaches past
// its face, into the air, so the export's voxel skin there is cut and the face comes out
// exact. On a growth run (Redesign to strengthen, a design box) the optimizer can grow
// material right onto that face, and the cut must spare it: only the part's own voxel
// skin goes, every printed voxel whose centre lies outside the part stays, joined to the
// exact face.
//
// Through run_job, Redesign to strengthen, on a bar (40 x 10.6 x 10.6 mm, its faces off
// the voxel planes) held at one end, 50 N down on the other, the design box over and
// under it only. Keep regions: the top face (min/max form, 2 mm in, 1.9 mm out) and one
// side face, which nothing can grow onto (oriented form). For every version:
//   (a) every printed voxel grown in the top region's outward band is inside the file,
//       so the growth there is kept and joined to the face;
//   (b) the untouched side face is on the CAD plane to 0.0000 mm;
//   (c) one closed shell;
//   (d) strengthen verified each version on that file (its verified margin).

#include "topopt/job.hpp"
#include "topopt/materials.hpp"
#include "topopt/mesh.hpp"
#include "topopt/part.hpp"
#include "topopt/settings.hpp"
#include "topopt/step.hpp"
#include "topopt/stl.hpp"

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
constexpr double kDepth = 2.0, kReach = 1.9;  // into the part / out into the air

Vec3 sub(const Vec3& a, const Vec3& b) { return {a.x - b.x, a.y - b.y, a.z - b.z}; }
double dot(const Vec3& a, const Vec3& b) { return a.x * b.x + a.y * b.y + a.z * b.z; }
Vec3 cross(const Vec3& a, const Vec3& b) {
  return {a.y * b.z - a.z * b.y, a.z * b.x - a.x * b.z, a.x * b.y - a.y * b.x};
}

TriangleMesh bar() {
  TriangleMesh m;
  m.vertices = {{0, 0, 0}, {kX, 0, 0}, {kX, kY, 0}, {0, kY, 0},
                {0, 0, kZ}, {kX, 0, kZ}, {kX, kY, kZ}, {0, kY, kZ}};
  const int t[12][3] = {{0, 2, 1}, {0, 3, 2}, {4, 5, 6}, {4, 6, 7},
                        {0, 1, 5}, {0, 5, 4}, {3, 7, 6}, {3, 6, 2},
                        {0, 4, 7}, {0, 7, 3}, {1, 2, 6}, {1, 6, 5}};
  for (const auto& tri : t) m.triangles.push_back({tri[0], tri[1], tri[2]});
  return m;
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

// Every hit of the ray o + s*d (s > 0) on the mesh.
std::vector<double> ray_hits(const TriangleMesh& m, const Vec3& o, const Vec3& d) {
  std::vector<double> hits;
  for (const auto& t : m.triangles) {
    const Vec3& a = m.vertices[static_cast<std::size_t>(t[0])];
    const Vec3 e1 = sub(m.vertices[static_cast<std::size_t>(t[1])], a);
    const Vec3 e2 = sub(m.vertices[static_cast<std::size_t>(t[2])], a);
    const Vec3 p = cross(d, e2);
    const double det = dot(e1, p);
    if (std::fabs(det) < 1e-14) continue;
    const Vec3 s = sub(o, a);
    const double u = dot(s, p) / det;
    if (u < 0.0 || u > 1.0) continue;
    const Vec3 q = cross(s, e1);
    const double v = dot(d, q) / det;
    if (v < 0.0 || u + v > 1.0) continue;
    const double h = dot(e2, q) / det;
    if (h > 1e-9) hits.push_back(h);
  }
  return hits;
}

// Inside by parity along a slanted ray (no axis-aligned edge sits on it).
bool inside(const TriangleMesh& m, const Vec3& p) {
  return ray_hits(m, p, Vec3{0.1234, 0.2345, 0.9640}).size() % 2 == 1;
}

// The side face (+Y) as the file has it: rays in -Y over its middle, clear of the top
// and bottom growth by more than the 1.25 voxels the cut spares. Worst |y - kY|.
double side_face_worst(const TriangleMesh& m, int* misses) {
  double worst = 0.0;
  *misses = 0;
  for (double x = 1.5; x <= kX - 1.5 + 1e-9; x += 1.0)
    for (double z = 3.0; z <= kZ - 3.0 + 1e-9; z += 0.5) {
      const std::vector<double> h = ray_hits(m, Vec3{x, kY + 3.0, z}, Vec3{0.0, -1.0, 0.0});
      if (h.empty()) {
        ++*misses;
        continue;
      }
      worst = std::max(worst, std::fabs(kY + 3.0 - *std::min_element(h.begin(), h.end()) - kY));
    }
  return worst;
}

std::string keep_json() {
  char buf[1024];
  std::snprintf(buf, sizeof buf,
                "{\"shape\": \"box\", \"min\": [0, 0, %.6f], \"max\": [%.6f, %.6f, %.6f]}, "
                "{\"shape\": \"box\", \"center\": [%.6f, %.6f, %.6f], \"axes\": [[1, 0, 0], "
                "[0, 0, 1], [0, 1, 0]], \"half_extents_mm\": [%.6f, %.6f, %.6f]}",
                kZ - kDepth, kX, kY, kZ + kReach, 0.5 * kX, kY - kDepth + 0.5 * (kDepth + kReach),
                0.5 * kZ, 0.5 * kX, 0.5 * kZ, 0.5 * (kDepth + kReach));
  return buf;
}

std::vector<KeepRegion> parsed_keeps() {
  const std::string path = std::string(TMP_DIR) + "/keep_growth_job.json";
  std::ofstream(path) << "{\"model\": \"keep_growth_bar.stl\", \"material\": \"PLA\", "
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
  job.model = "keep_growth_bar.stl";
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
  job.has_design_box = true;  // over and under the bar only: nothing grows on its sides
  job.design_box.min = Vec3{0.0, 0.0, -3.0};
  job.design_box.max = Vec3{kX, kY, kZ + 3.0};
  job.keep_regions = keeps;
  job.bake_build_orientation = "off";  // the files in model coordinates
  job.output.report = "report.json";
  job.output.mesh_format = "stl";
  job.output.mesh_prefix = "variant";
  return job;
}

}  // namespace

int main() {
  const MaterialLibrary materials = load_materials_file(MATERIALS_JSON_PATH);
  const SettingsRules rules = load_settings_rules_file(SETTINGS_RULES_PATH);
  const std::string dir = TMP_DIR;
  write_stl_file(dir + "/keep_growth_bar.stl", bar(), StlFormat::Binary);
  const StepModel model = import_part(dir + "/keep_growth_bar.stl").model;
  try {
    const std::vector<KeepRegion> keeps = parsed_keeps();
    CHECK(keeps.size() == 2 && !keeps[0].oriented && keeps[1].oriented,
          "precondition: the top region (min/max) and the side region (oriented) parse");
    const RunJobResult r = run_job(bar_job(model, keeps), dir, dir + "/keep_growth_out",
                                   materials, rules, false, RunObservability{});
    std::vector<const MinimizePlasticVariant*> accepted;
    for (const MinimizePlasticVariant& v : r.pipeline.evaluated)
      if (v.accepted) accepted.push_back(&v);
    CHECK(!accepted.empty() && accepted.size() == r.mesh_paths.size(),
          "precondition: a file for every accepted version");
    const VoxelGrid& g = r.pipeline.solved_grid;
    const VoxelGrid part = voxelize_onto_grid(bar(), g);  // the part's centre rule
    long long grown_total = 0;
    for (std::size_t n = 0; n < accepted.size() && n < r.mesh_paths.size(); ++n) {
      const std::vector<double>& rho = accepted[n]->optimization.physical_density;
      const TriangleMesh f = read_stl_file(r.mesh_paths[n]).mesh;
      // (a) printed voxels outside the part, centred in the top region's outward band
      long long grown = 0, kept = 0;
      for (int k = 0; k < g.nz; ++k)
        for (int j = 0; j < g.ny; ++j)
          for (int i = 0; i < g.nx; ++i) {
            const Vec3 c = g.voxel_center(i, j, k);
            if (part.solid(i, j, k) || rho[g.index(i, j, k)] < 0.5) continue;
            if (c.z <= kZ || c.z > kZ + kReach || c.x <= 0.0 || c.x >= kX || c.y <= 0.0 ||
                c.y >= kY)
              continue;
            ++grown;
            kept += inside(f, c);
          }
      grown_total += grown;
      int misses = 0;
      const double worst = side_face_worst(f, &misses);
      std::map<std::pair<int, int>, int> uses;
      for (const auto& t : f.triangles)
        for (int e = 0; e < 3; ++e) {
          const int a = t[e], b = t[(e + 1) % 3];
          ++uses[{std::min(a, b), std::max(a, b)}];
        }
      int bad = 0;
      for (const auto& kv : uses) bad += kv.second != 2;
      const int bodies = count_components(f);
      std::printf("[keep-growth] version %zu (vf %.4f): %lld printed voxels grown in the top "
                  "band, %lld inside the file; side face worst %.4f mm (%d misses); %d "
                  "bodies, %d edges not on two triangles\n",
                  n + 1, accepted[n]->report.volume_fraction, grown, kept, worst,
                  misses, bodies, bad);
      CHECK(kept == grown, "(a) the growth in the outward band is kept, joined to the face");
      CHECK(misses == 0 && worst <= 5e-5, "(b) the untouched side face is on the CAD plane");
      CHECK(bodies == 1 && bad == 0, "(c) one closed shell");
    }
    std::printf("[keep-growth] h %.4f: %lld grown voxels in the band over %zu version(s)\n",
                g.spacing, grown_total, accepted.size());
    CHECK(grown_total > 0, "precondition: material grows onto the protected top face");
    // (d) strengthen verified each written version on that file (run_job: v<k>_<n>.stl,
    // variant_export_model_mesh with the keep regions, then analyze_job). A version is
    // written unless "unreachable" or "merged"; its own verified_margin is the first one
    // after its "version" key (its attempts' come later).
    int written = 0, verified = 0;
    for (std::size_t p = r.report_json.find("{\"version\": "); p != std::string::npos;
         p = r.report_json.find("{\"version\": ", p + 1)) {
      const std::size_t sp = r.report_json.find("\"status\": \"", p) + 11;
      const std::string st = r.report_json.substr(sp, r.report_json.find('"', sp) - sp);
      const std::size_t mp = r.report_json.find("\"verified_margin\": ", p) + 19;
      const double vm = std::atof(r.report_json.c_str() + mp);
      std::printf("[keep-growth] version status %s, verified margin %.4g\n", st.c_str(), vm);
      if (st == "unreachable" || st == "merged") continue;
      ++written;
      verified += vm > 0.0;
    }
    CHECK(written > 0 && written == static_cast<int>(r.mesh_paths.size()) &&
              verified == written,
          "(d) strengthen verified every written version");
  } catch (const std::exception& e) {
    ++g_failures;
    std::fprintf(stderr, "FAIL: threw: %s\n", e.what());
  }

  if (g_failures == 0) {
    std::printf("keep growth: all %d checks passed\n", g_checks);
    return 0;
  }
  std::fprintf(stderr, "keep growth: %d/%d checks FAILED\n", g_failures, g_checks);
  return 1;
}
