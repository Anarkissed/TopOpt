// The Organic strength check repeats bit for bit (TOReview's finding of 2026-11-26: the same Organic job run twice in
// one process gave strength blocks that differed in about twelve weakest-strut forces in the tenth figure and in the
// frame solve's residual, the vines identical). A MADE coupon, 24 x 24 x 19 mm: a solid base 4 mm, the weave region
// its top face 15 mm deep with a Solid finish 3 mm thick (a lattice core 12 mm between solid), Organic Traced on a made
// uniform stress result, held on the bottom, 20 N down on the top. The same file job with its strength check runs
// twice in this process; the two strength blocks must be the same bytes once the clock and memory readings (the only
// things that may differ) are blanked. Then the same with the frame laid twice in a row in one Organic check is not
// needed: the second run starts from a fresh check of the same job.
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <filesystem>
#include <fstream>
#include <regex>
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

const std::string kDir = std::string(TMP_DIR) + "/organic_frame_repeat";

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

// The strength block with the clock and memory readings blanked: every number after a key that names milliseconds,
// seconds or megabytes.
std::string strength_block(const std::string& result) {
  const std::size_t a = result.find("\n  \"strength\": {");
  if (a == std::string::npos) return {};
  const std::size_t b = result.find("\n  },\n", a);
  std::string s = b == std::string::npos ? result.substr(a) : result.substr(a, b - a + 5);
  // The clock and memory blocks ("times_ms", "memory_mb", "run_info"): every number in them; and "ms" itself.
  for (const char* key : {"\"times_ms\": {", "\"memory_mb\": {", "\"run_info\": {"}) {
    const std::size_t at = s.find(key);
    if (at == std::string::npos) continue;
    int depth = 0;
    std::size_t e = at + std::string(key).size() - 1;
    for (; e < s.size(); ++e) {
      if (s[e] == '{') ++depth;
      if (s[e] == '}' && --depth == 0) break;
    }
    static const std::regex num(": -?[0-9][0-9.eE+-]*");
    s = s.substr(0, at) + std::regex_replace(s.substr(at, e - at), num, ": #") + s.substr(e);
  }
  static const std::regex ms("(\"ms\": )-?[0-9.eE+-]+");
  return std::regex_replace(s, ms, "$1#");
}

}  // namespace

int main() {
  std::filesystem::remove_all(kDir);
  std::filesystem::create_directories(kDir);
  write_stl_file(kDir + "/coupon.stl", block(24, 24, 19), StlFormat::Binary);
  const StepModel m = import_part_file_resolved(kDir + "/coupon.stl");
  const int top = face_with_normal(m, {0, 0, 1}), bottom = face_with_normal(m, {0, 0, -1});
  if (top < 0 || bottom < 0) return 1;
  {
    TensorField tf;
    tf.spacing = 1.0;
    tf.origin = {-1.0, -1.0, -1.0};
    tf.nx = tf.ny = 26;
    tf.nz = 21;
    const std::size_t n = static_cast<std::size_t>(tf.nx) * tf.ny * tf.nz;
    tf.voigt.assign(6 * n, 0.0);
    for (std::size_t e = 0; e < n; ++e) { tf.voigt[6 * e + 2] = 3.0; tf.voigt[6 * e] = 1.0; }
    if (!write_tensor_file(kDir + "/stress.tensor", tf)) return 1;
  }
  write(kDir + "/job.json",
        "{\"mode\": \"lattice_file\", \"model\": \"coupon.stl\", \"output\": \"lattice.stl\", \"strength_job\": \"sj.json\", "
        "\"tensor\": \"stress.tensor\", \"layout\": {\"min_strut_lines\": 2, \"region_ids\": [1], \"region_no_lattice\": [0], "
        "\"region_depth_mm\": [15], \"region_expand_mm\": [0], \"region_face_counts\": [1], \"region_faces\": [" +
            std::to_string(top) + "], \"region_finish\": [{\"rim_mm\": 0, \"cover_mm\": 3}], \"topology\": \"octet\", "
        "\"algorithm\": \"uniform\", \"cell_max_mm\": 8, \"min_cells_across\": 1, \"region_weave\": [true], "
        "\"organic_spacing_mm\": 4, \"organic_width_mm\": 0.9}}");
  write(kDir + "/sj.json",
        "{\"model\": \"coupon.stl\", \"material\": \"PLA\", \"mode\": \"lattice_part\", \"resolution\": 40, "
        "\"loads\": {\"minimize_plastic\": true, \"safety_margin\": 1.5, \"build_dir\": [0, 0, 1], \"anchor_face_ids\": [" +
            std::to_string(bottom) + "], \"groups\": [{\"face_ids\": [" + std::to_string(top) + "], \"force\": [0, 0, -20]}]}, "
        "\"lattice\": {\"topology\": \"octet\", \"require_lattice_void_reaches_exterior\": false}, "
        "\"grading\": {\"topology\": \"octet\", \"cell_mm\": 8, \"min_extrudable_width_mm\": 0.45, \"intent\": \"structural\"}, "
        "\"output\": {\"report\": \"report.json\", \"mesh_format\": \"stl\", \"mesh_prefix\": \"variant\"}}");
  // Review C2 A2: this test reads the rod (frame) check; the break check (C2, a 0.2 mm solve) is not asked here:
  // StrengthAsk::print left null, as for a cell lattice (plain ctest stays as light as before C2).
  const StrengthCheck check = [] {
    StrengthCheck c = lattice_file_strength_check(MATERIALS_JSON_PATH, SETTINGS_RULES_PATH);
    const auto real = c.run_organic;
    c.run_organic = [real](const StrengthAsk& a) {
      StrengthAsk b = a;
      b.print = nullptr;
      return real(b);
    };
    return c;
  }();
  std::string blocks[2];
  for (int run = 0; run < 2; ++run) {
    const std::string out = kDir + "/run" + std::to_string(run);
    std::filesystem::create_directories(out);
    const FileResult r = run_file_job(kDir + "/job.json", out, 0, nullptr, &check);
    blocks[run] = strength_block(slurp(out + "/" + kFileResultName));
    std::printf("[run %d] ok %d code %s bars %zu strength ran %d, block %zu bytes\n", run, r.ok, r.code.c_str(), r.bars,
                r.strength_ran, blocks[run].size());
  }
  int failures = 0;
  if (blocks[0].empty() || blocks[1].empty()) ++failures;
  if (blocks[0] != blocks[1]) {
    ++failures;
    // Where they part: each differing line, both ways.
    std::istringstream a(blocks[0]), b(blocks[1]);
    std::string la, lb;
    int shown = 0;
    while (std::getline(a, la) && std::getline(b, lb))
      if (la != lb && shown++ < 12) {
        std::size_t c = 0;
        while (c < la.size() && c < lb.size() && la[c] == lb[c]) ++c;
        const std::size_t from = c > 60 ? c - 60 : 0;
        std::printf("  differs at column %zu:\n    1: ...%s\n    2: ...%s\n", c, la.substr(from, 160).c_str(),
                    lb.substr(from, 160).c_str());
      }
  }
  std::printf("[organic frame repeat] the two strength blocks are %s\n", blocks[0] == blocks[1] ? "the SAME bytes" : "DIFFERENT");
  return failures == 0 ? 0 : 1;
}
