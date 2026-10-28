// CORE LIST item KEEP (his answers of 2026-10-25; approved 03:58 with Manifold): a
// KEEP region is part of the model kept EXACTLY. The optimizer may not cut it up or
// dig into it (the part's voxels inside are frozen), and the export carries the
// part's own CAD geometry there, merged with the optimized material into ONE closed
// shell: (export - K) + (part ^ K grown 0.05 mm).
//
// Through run_job on the committed plate with a bore (24 x 16 x 4 mm, r 3), a keep
// cylinder of radius 7 around the bore:
//   (a) every CAD vertex inside the keep region is in the exported file (exact);
//       without the region, none is and the bore wall is off by up to a voxel;
//   (b) the file is one body and a closed 2-manifold (every edge on two triangles);
//   (c) the schema refuses a non-square cylinder and an unknown shape.
// Built only with Manifold (TOPOPT_HAVE_MANIFOLD); OCCT-free (a mesh part).

#include "topopt/job.hpp"
#include "topopt/materials.hpp"
#include "topopt/mesh.hpp"
#include "topopt/settings.hpp"
#include "topopt/stl.hpp"

#include <cmath>
#include <cstdio>
#include <fstream>
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

JobDescription plate_job(bool keep) {
  JobDescription job;
  job.model = "plate_bore.stl";
  job.material = "PLA";
  job.mode = "minimize_plastic";
  job.resolution = 32;
  job.has_plsm = true;
  job.plsm_enabled = true;
  job.plsm_max_iterations = 6;
  job.fixture_faces.push_back(JobFaceSelector{"cylindrical", 3.0});
  job.gravity.direction = Vec3{0.0, 0.0, -1.0};
  job.gravity.magnitude_mm_s2 = 9810.0;
  job.ladder = {0.5};
  job.margin_stop = 1.5;
  job.bake_build_orientation = "off";  // the file in model coordinates
  job.output.report = "report.json";
  job.output.mesh_format = "stl";
  job.output.mesh_prefix = "variant";
  if (keep) {
    KeepRegion k;
    k.cylinder = true;
    k.axis = 2;
    k.min = Vec3{-7.0, -7.0, 0.0};
    k.max = Vec3{7.0, 7.0, 4.0};
    job.keep_regions.push_back(k);
  }
  return job;
}

// CAD vertices strictly inside the keep cylinder that the file also carries.
std::pair<int, int> cad_vertices_kept(const TriangleMesh& cad, const TriangleMesh& file) {
  int inside = 0, found = 0;
  for (const Vec3& p : cad.vertices) {
    if (std::hypot(p.x, p.y) >= 6.9) continue;
    ++inside;
    for (const Vec3& q : file.vertices)
      if (std::fabs(p.x - q.x) < 1e-3 && std::fabs(p.y - q.y) < 1e-3 &&
          std::fabs(p.z - q.z) < 1e-3) {
        ++found;
        break;
      }
  }
  return {inside, found};
}

bool refused(const std::string& keep_json) {
  const std::string path = std::string(TMP_DIR) + "/keep_schema_job.json";
  std::ofstream(path) << "{\"model\": \"plate_bore.stl\", \"material\": \"PLA\", "
                         "\"mode\": \"minimize_plastic\", \"resolution\": 32, "
                         "\"fixture_faces\": [{\"kind\": \"cylindrical\", \"radius_mm\": 3}], "
                         "\"gravity\": {\"direction\": [0, 0, -1], \"magnitude_mm_s2\": 9810}, "
                         "\"ladder\": [0.5], \"margin_stop\": 1.5, \"keep_regions\": ["
                      << keep_json
                      << "], \"output\": {\"report\": \"r.json\", \"mesh_format\": \"stl\", "
                         "\"mesh_prefix\": \"v\"}}";
  try {
    (void)load_job_file(path);
    return false;
  } catch (const std::exception&) {
    return true;
  }
}

}  // namespace

int main() {
  const MaterialLibrary materials = load_materials_file(MATERIALS_JSON_PATH);
  const SettingsRules rules = load_settings_rules_file(SETTINGS_RULES_PATH);
  const std::string dir = MESH_FIXTURE_DIR;
  const TriangleMesh cad = read_stl_file(dir + "/plate_bore.stl").mesh;
  try {
    const RunJobResult with = run_job(plate_job(true), dir, std::string(TMP_DIR) + "/keep_on",
                                      materials, rules, false, RunObservability{});
    const RunJobResult without = run_job(plate_job(false), dir,
                                         std::string(TMP_DIR) + "/keep_off", materials, rules,
                                         false, RunObservability{});
    CHECK(with.mesh_paths.size() == 1 && without.mesh_paths.size() == 1,
          "precondition: one accepted variant each");
    if (with.mesh_paths.size() == 1 && without.mesh_paths.size() == 1) {
      const TriangleMesh fk = read_stl_file(with.mesh_paths[0]).mesh;
      const TriangleMesh fn = read_stl_file(without.mesh_paths[0]).mesh;
      const auto [in_k, found_k] = cad_vertices_kept(cad, fk);
      const auto [in_n, found_n] = cad_vertices_kept(cad, fn);
      std::printf("[keep] CAD vertices inside the keep region carried by the file: "
                  "%d/%d with KEEP, %d/%d without\n", found_k, in_k, found_n, in_n);
      CHECK(in_k > 0 && found_k == in_k, "(a) the kept region is the part's exact geometry");
      CHECK(found_n == 0, "(a) without KEEP the file is the voxel surface there");
      std::map<std::pair<int, int>, int> uses;
      for (const auto& t : fk.triangles)
        for (int e = 0; e < 3; ++e) {
          const int a = t[e], b = t[(e + 1) % 3];
          ++uses[{std::min(a, b), std::max(a, b)}];
        }
      int bad = 0;
      for (const auto& kv : uses) bad += kv.second != 2;
      std::printf("[keep] file: %zu triangles, %d bodies, %d edges not on exactly two "
                  "triangles\n", fk.triangles.size(), count_components(fk), bad);
      CHECK(count_components(fk) == 1 && bad == 0,
            "(b) one merged, closed 2-manifold shell");
    }
  } catch (const std::exception& e) {
    ++g_failures;
    std::fprintf(stderr, "FAIL: threw: %s\n", e.what());
  }
  CHECK(refused("{\"shape\": \"cylinder\", \"min\": [-7, -6, 0], \"max\": [7, 7, 4], \"axis\": 2}"),
        "(c) a cylinder whose cross-section is not square is refused");
  CHECK(refused("{\"shape\": \"sphere\", \"min\": [-7, -7, 0], \"max\": [7, 7, 4]}"),
        "(c) an unknown shape is refused");
  CHECK(!refused("{\"shape\": \"box\", \"min\": [-7, -7, 0], \"max\": [7, 7, 4]}"),
        "(c) a box parses");

  if (g_failures == 0) {
    std::printf("keep (item KEEP): all %d checks passed\n", g_checks);
    return 0;
  }
  std::fprintf(stderr, "keep (item KEEP): %d/%d checks FAILED\n", g_failures, g_checks);
  return 1;
}
