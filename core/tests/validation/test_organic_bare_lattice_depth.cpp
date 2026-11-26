// OS19's companion (the lead, 2026-11-26): how deep a Solid finish under the loaded face must be for the interim
// guard (load_on_bare_lattice) to clear, on the check's own grid. A MADE coupon, 24 x 24 x H mm, base 4 mm, the weave
// region its top face 12 mm deep (Organic Traced on a made uniform stress result), the region's Solid finish
// (cover_mm) swept over 0, 0.5, 1, 1.5, 2, 2.5 and 3 of the check's voxels (resolution 40: 0.6 mm), held on the
// bottom, 20 N down on the top face; the stage switch off and `face`; two heights, the top on a node plane (H = 16)
// and half a voxel off it (H = 16.3). Printed per run: the verdict and reason, load_share, load_on_frame_n, and the
// result's solid_depth_needed_mm when the guard holds.
// Checks: with no finish the guard holds; at every depth at or past the one the result named, it clears.
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <filesystem>
#include <fstream>
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

const std::string kDir = std::string(TMP_DIR) + "/organic_bare_lattice_depth";
int g_checks = 0, g_failures = 0;
#define CHECK(c)                                                         \
  do {                                                                   \
    ++g_checks;                                                          \
    if (!(c)) {                                                          \
      ++g_failures;                                                      \
      std::printf("FAIL %s:%d  %s\n", __FILE__, __LINE__, #c);           \
    }                                                                    \
  } while (0)

std::string slurp(const std::string& p) {
  std::ifstream f(p, std::ios::binary);
  std::ostringstream s;
  s << f.rdbuf();
  return s.str();
}
void write(const std::string& path, const std::string& text) { std::ofstream(path) << text; }

TriangleMesh block(double L, double W, double H) {
  TriangleMesh m;
  for (const Vec3& v : std::vector<Vec3>{{0, 0, 0}, {L, 0, 0}, {L, W, 0}, {0, W, 0}, {0, 0, H}, {L, 0, H}, {L, W, H}, {0, W, H}})
    m.vertices.push_back(v);
  const int tri[12][3] = {{0, 2, 1}, {0, 3, 2}, {4, 5, 6}, {4, 6, 7}, {0, 1, 5}, {0, 5, 4},
                          {3, 7, 6}, {3, 6, 2}, {0, 4, 7}, {0, 7, 3}, {1, 2, 6}, {1, 6, 5}};
  for (const auto& x : tri) m.triangles.push_back({x[0], x[1], x[2]});
  return m;
}
int face_with_normal(const StepModel& m, const Vec3& n) {
  for (int f = 0; f < m.face_count; ++f) {
    const StepFaceInfo& fi = m.faces[static_cast<std::size_t>(f)];
    if (fi.kind == StepSurfaceKind::Plane && fi.plane_normal.x * n.x + fi.plane_normal.y * n.y + fi.plane_normal.z * n.z > 0.99)
      return f;
  }
  return -1;
}
std::string value_of(const std::string& s, const std::string& key, std::size_t from = 0) {
  const std::string k = "\"" + key + "\": ";
  const std::size_t a = s.find(k, from);
  if (a == std::string::npos) return "-";
  std::size_t v = a + k.size(), e = v;
  if (s[v] == '"') return s.substr(v + 1, s.find('"', v + 1) - v - 1);
  while (e < s.size() && s[e] != ',' && s[e] != '}' && s[e] != ']' && s[e] != '\n') ++e;
  return s.substr(v, e - v);
}

}  // namespace

int main() {
  std::filesystem::remove_all(kDir);
  std::filesystem::create_directories(kDir);
  const double h = 24.0 / 40.0;   // the check's voxel at resolution 40 on a 24 mm part
  for (const double H : {16.0, 16.3}) {
    const std::string model = H == 16.0 ? "on_plane.stl" : "off_plane.stl";
    write_stl_file(kDir + "/" + model, block(24, 24, H), StlFormat::Binary);
    const StepModel m = import_part_file_resolved(kDir + "/" + model);
    const int top = face_with_normal(m, {0, 0, 1}), bottom = face_with_normal(m, {0, 0, -1});
    CHECK(top >= 0 && bottom >= 0);
    {   // the made uniform stress result (TOReview's job C)
      TensorField tf;
      tf.spacing = 1.0;
      tf.origin = {-1.0, -1.0, -1.0};
      tf.nx = tf.ny = 26;
      tf.nz = static_cast<int>(std::ceil(H)) + 2;
      const std::size_t n = static_cast<std::size_t>(tf.nx) * tf.ny * tf.nz;
      tf.voigt.assign(6 * n, 0.0);
      for (std::size_t e = 0; e < n; ++e) { tf.voigt[6 * e + 2] = 3.0; tf.voigt[6 * e] = 1.0; }
      CHECK(write_tensor_file(kDir + "/stress.tensor", tf));
    }
    for (const std::string mode : {"", "face"}) {
      double named = -1.0;   // solid_depth_needed_mm from the bare run
      for (const double voxels : {0.0, 0.5, 1.0, 1.5, 2.0, 2.5, 3.0}) {
        const double cover = voxels * h;
        const std::string job =
            "{\"mode\": \"lattice_file\", \"model\": \"" + model + "\", \"output\": \"lattice.stl\", \"strength_job\": \"sj.json\", "
            "\"tensor\": \"stress.tensor\", \"layout\": {\"min_strut_lines\": 2, \"region_ids\": [1], \"region_no_lattice\": [0], "
            "\"region_depth_mm\": [" + std::to_string(H - 4.0) + "], \"region_expand_mm\": [0], \"region_face_counts\": [1], "
            "\"region_faces\": [" + std::to_string(top) + "], \"region_finish\": [{\"rim_mm\": 0, \"cover_mm\": " +
            std::to_string(cover) + "}], \"topology\": \"octet\", \"algorithm\": \"uniform\", \"cell_max_mm\": 8, "
            "\"min_cells_across\": 1, \"region_weave\": [true], \"organic_spacing_mm\": 4, \"organic_width_mm\": 0.9}}";
        const std::string sj =
            "{\"model\": \"" + model + "\", \"material\": \"PLA\", \"mode\": \"lattice_part\", \"resolution\": 40, "
            "\"loads\": {\"minimize_plastic\": true, \"safety_margin\": 1.5, \"build_dir\": [0, 0, 1], \"anchor_face_ids\": [" +
            std::to_string(bottom) + "], \"groups\": [{\"face_ids\": [" + std::to_string(top) + "], \"force\": [0, 0, -20]}]}, "
            "\"lattice\": {\"topology\": \"octet\", \"require_lattice_void_reaches_exterior\": false}, "
            "\"grading\": {\"topology\": \"octet\", \"cell_mm\": 8, \"min_extrudable_width_mm\": 0.45, \"intent\": \"structural\"}, "
            "\"output\": {\"report\": \"report.json\", \"mesh_format\": \"stl\", \"mesh_prefix\": \"variant\"}}";
        write(kDir + "/job.json", job);
        write(kDir + "/sj.json", sj);
        const std::string out = kDir + "/" + model.substr(0, model.size() - 4) + (mode.empty() ? "_off_" : "_face_") +
                                std::to_string(static_cast<int>(voxels * 10));
        std::filesystem::create_directories(out);
        if (mode.empty()) unsetenv("TOPOPT_FACE_LOADS"); else setenv("TOPOPT_FACE_LOADS", mode.c_str(), 1);
        const StrengthCheck check = lattice_file_strength_check(MATERIALS_JSON_PATH, SETTINGS_RULES_PATH);
        const FileResult r = run_file_job(kDir + "/job.json", out, 0, nullptr, &check);
        unsetenv("TOPOPT_FACE_LOADS");
        const std::string json = slurp(out + "/" + kFileResultName);
        const std::size_t sb = json.find("\n  \"strength\": {");
        const bool ran = r.strength_ran && sb != std::string::npos;
        const bool bare = ran && json.find("\"fail_reason\": \"load_on_bare_lattice\"", sb) != std::string::npos;
        const std::string need = bare ? value_of(json, "solid_depth_needed_mm", sb) : "-";
        const std::size_t fr = ran ? json.find("\"frame\": {", sb) : std::string::npos;
        std::printf("[sweep] H %.1f %-4s cover %.1f voxels (%.2f mm): ran %d bars %zu verdict %s reason %s load_share %s "
                    "load_on_frame_n %s solid_depth_needed_mm %s\n",
                    H, mode.empty() ? "off" : "face", voxels, cover, ran, r.bars, ran ? value_of(json, "verdict", sb).c_str() : "-",
                    bare ? "load_on_bare_lattice" : "-", fr != std::string::npos ? value_of(json, "load_share", fr).c_str() : "-",
                    fr != std::string::npos ? value_of(json, "load_on_frame_n", fr).c_str() : "-", need.c_str());
        // The top half a voxel off the node plane: with the switch off today's tagging may find no voxel for the top face
        // (the check then refuses the job, strength_failed); that run is printed, not judged.
        if (H != 16.0 && !ran) continue;
        CHECK(ran);
        const bool open = ran && json.find("\"fail_reason\": \"load_on_open_lattice\"", sb) != std::string::npos;
        if (voxels == 0.0) {
          CHECK(bare);   // the bare top face: the guard holds
          named = bare ? std::atof(need.c_str()) : -1.0;
          CHECK(named > 0.0);
        } else if (named > 0.0 && cover >= named - 1e-9) {
          CHECK(!bare && !open);   // at or past the named depth, the guard and the open-lattice test clear
        }
      }
    }
  }
  std::printf("organic_bare_lattice_depth: %d checks, %d failed\n", g_checks, g_failures);
  return g_failures == 0 ? 0 : 1;
}
