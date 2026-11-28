// margins.cpp -- the strength check's margin on core's own fixtures, per type, BEFORE and AFTER the low-density laws
// (evidence/2026-11-25-strut-laws-low-density). The same job the type matrix runs (core/tests/validation/
// test_lattice_types_matrix.cpp on claude/notes28-celltypes-core): the new engine's file job (run_file_job) with the
// CLI's strength check, two lines of 0.45 mm, held on the bottom face and loaded on a side (20 N; the round plate's
// load goes on its top), resolution 40, PLA, safety 1.5. Run once on a library built from the tree before the law
// commit and once after; reproduce.sh step 4 builds and runs it.
//   margins <fixtures dir> <materials.json> <rules.json> <out dir>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <filesystem>
#include <fstream>
#include <limits>
#include <string>
#include <vector>

#include "topopt/lattice.hpp"
#include "topopt/lattice_file_strength.hpp"
#include "topopt/lattice_layout_file.hpp"
#include "topopt/face_overrides.hpp"

using namespace topopt;
using namespace topopt::lattice_layout;

namespace {
double num_after(const std::string& s, const std::string& key, std::size_t from = 0) {
  const std::size_t k = s.find("\"" + key + "\": ", from);
  if (k == std::string::npos) return std::numeric_limits<double>::quiet_NaN();
  const std::size_t v = k + key.size() + 4;
  if (s.compare(v, 4, "null") == 0) return std::numeric_limits<double>::quiet_NaN();
  return std::strtod(s.c_str() + v, nullptr);
}
std::string str_after(const std::string& s, const std::string& key, std::size_t from = 0) {
  const std::size_t k = s.find("\"" + key + "\": \"", from);
  if (k == std::string::npos) return "";
  const std::size_t v = k + key.size() + 5;
  return s.substr(v, s.find('"', v) - v);
}
int face_with_normal(const StepModel& m, double nx, double ny, double nz) {
  int best = -1;
  double best_off = -1e300;
  for (int f = 0; f < m.face_count; ++f) {
    const StepFaceInfo& fi = m.faces[static_cast<std::size_t>(f)];
    if (fi.kind != StepSurfaceKind::Plane ||
        fi.plane_normal.x * nx + fi.plane_normal.y * ny + fi.plane_normal.z * nz <= 0.99)
      continue;
    const double o = fi.plane_origin.x * nx + fi.plane_origin.y * ny + fi.plane_origin.z * nz;
    if (o > best_off) { best_off = o; best = f; }
  }
  return best;
}
int face_by_triangles(const StepModel& m, double nx, double ny, double nz) {
  std::vector<double> area(static_cast<std::size_t>(m.face_count), 0.0);
  for (std::size_t t = 0; t < m.mesh.triangles.size() && t < m.triangle_face.size(); ++t) {
    const int f = m.triangle_face[t];
    if (f < 0 || f >= m.face_count) continue;
    const Vec3& a = m.mesh.vertices[static_cast<std::size_t>(m.mesh.triangles[t][0])];
    const Vec3& b = m.mesh.vertices[static_cast<std::size_t>(m.mesh.triangles[t][1])];
    const Vec3& c = m.mesh.vertices[static_cast<std::size_t>(m.mesh.triangles[t][2])];
    const Vec3 u{b.x - a.x, b.y - a.y, b.z - a.z}, w{c.x - a.x, c.y - a.y, c.z - a.z};
    const Vec3 n{u.y * w.z - u.z * w.y, u.z * w.x - u.x * w.z, u.x * w.y - u.y * w.x};
    const double l = std::sqrt(n.x * n.x + n.y * n.y + n.z * n.z);
    if (!(l > 0.0)) continue;
    if ((n.x * nx + n.y * ny + n.z * nz) / l >= 0.99) area[static_cast<std::size_t>(f)] += 0.5 * l;
  }
  int best = -1;
  for (int f = 0; f < m.face_count; ++f)
    if (area[static_cast<std::size_t>(f)] > 0.0 &&
        (best < 0 || area[static_cast<std::size_t>(f)] > area[static_cast<std::size_t>(best)]))
      best = f;
  return best;
}
struct Fixture { std::string name, path; int top = -1, bottom = -1, side = -1; };
struct Case { std::string tag; const Fixture* fx; double cell_mm; bool whole; double dial; };
std::string layout_json(const std::string& type, const Case& c) {
  char dial[32];
  std::snprintf(dial, sizeof dial, "%.2f", c.dial);
  std::string s = "{\"min_strut_lines\": 2, \"bead_mm\": 0.45, \"topology\": \"" + type +
                  "\", \"algorithm\": \"default_grade\", \"cell_max_mm\": 8, \"min_cells_across\": 1, \"dial\": " + dial + ", ";
  if (c.cell_mm > 0) s += "\"cell_mm\": " + std::to_string(c.cell_mm) + ", ";
  else s += "\"cell_mm\": 0, \"cell_search\": true, \"stretch_edges\": true, ";
  s += "\"skin\": true, ";
  if (c.whole) s += "\"all_lattice\": true";
  else
    s += "\"region_ids\": [1], \"region_no_lattice\": [0], \"region_depth_mm\": [6], \"region_expand_mm\": [0], "
         "\"region_face_counts\": [1], \"region_faces\": [" + std::to_string(c.fx->top) + "]";
  return s + "}";
}
std::string strength_job(const std::string& type, const Case& c) {
  return "{\"model\": \"" + c.fx->path + "\", \"material\": \"PLA\", \"mode\": \"lattice_part\", \"resolution\": 40, "
         "\"loads\": {\"minimize_plastic\": true, \"safety_margin\": 1.5, \"build_dir\": [0, 0, 1], "
         "\"anchor_face_ids\": [" + std::to_string(c.fx->bottom) + "], \"groups\": [{\"face_ids\": [" +
         std::to_string(c.fx->side) + "], \"force\": [0, 0, -20]}]}, "
         "\"lattice\": {\"topology\": \"" + type + "\", \"require_lattice_void_reaches_exterior\": false}, "
         "\"grading\": {\"topology\": \"" + type + "\", \"cell_mm\": 8, \"min_extrudable_width_mm\": 0.45, "
         "\"intent\": \"structural\"}, "
         "\"output\": {\"report\": \"report.json\", \"mesh_format\": \"stl\", \"mesh_prefix\": \"variant\"}}";
}
}  // namespace

int main(int argc, char** argv) {
  if (argc < 5) { std::fprintf(stderr, "usage: margins <fixtures> <materials.json> <rules.json> <out>\n"); return 2; }
  const std::string fixtures = std::filesystem::absolute(argv[1]).string(), out = argv[4];
  std::filesystem::create_directories(out);
  const StrengthCheck check = lattice_file_strength_check(argv[2], argv[3]);
  Fixture cube{"cube", fixtures + "/step/cube.step"}, plate{"plate", fixtures + "/mesh/filleted_bore_plate.stl"};
  for (Fixture* f : {&cube, &plate}) {
    const StepModel m = import_part_file_resolved(f->path);
    f->top = face_with_normal(m, 0, 0, 1);
    f->bottom = face_with_normal(m, 0, 0, -1);
    f->side = face_with_normal(m, 1, 0, 0);
    if (f->top < 0) f->top = face_by_triangles(m, 0, 0, 1);
    if (f->bottom < 0) f->bottom = face_by_triangles(m, 0, 0, -1);
    if (f->side < 0) f->side = f->top;
  }
  // The matrix's two Structural cube cases (str-typed-whole-cube is its `credit` case), the plate latticed whole at
  // the cell its 6 mm holds, and the engine's thinnest strut (the dial at 1 %, two lines) on the plate's largest cell.
  const std::vector<Case> cases = {
      {"cube-typed5-whole", &cube, 5.0, true, 0.45},  {"cube-auto-face", &cube, 0.0, false, 0.45},
      {"plate-typed6-whole", &plate, 6.0, true, 0.45}, {"plate-auto-whole", &plate, 0.0, true, 0.45},
      {"plate-typed6-thinnest", &plate, 6.0, true, 0.01},
  };
  std::printf("type,case,ok,strength_ran,cells,cells_credited,cells_no_credit,margin_worst_case,strut_margin_worst_case,"
              "strut_out_of_regime,law_is_types_own,not_certified_reason\n");
  for (const char* type : {"octet", "bcc", "diamond", "sc"}) {
    for (const Case& c : cases) {
      const std::string folder = out + "/" + type + "-" + c.tag;
      std::filesystem::remove_all(folder);
      std::filesystem::create_directories(folder);
      std::ofstream(folder + "/strength_job.json") << strength_job(type, c);
      std::ofstream(folder + "/job.json")
          << "{\"mode\": \"lattice_file\", \"model\": \"" + c.fx->path +
                 "\", \"output\": \"lattice.stl\", \"strength_job\": \"strength_job.json\", \"layout\": " +
                 layout_json(type, c) + "}";
      const FileResult r = run_file_job(folder + "/job.json", folder, 0, nullptr, &check);
      const std::string& j = r.strength_json;
      const std::size_t at = j.find("\"strut\": {");
      const double sm = at == std::string::npos ? std::numeric_limits<double>::quiet_NaN()
                                                : num_after(j, "margin_worst_case", at);
      const bool oor = at != std::string::npos && j.find("\"out_of_regime\": true", at) != std::string::npos;
      const std::string law = at == std::string::npos ? "" : str_after(j, "law", at);
      std::printf("%s,%s,%d,%d,%zu,%.0f,%.0f,%.4f,%.4f,%d,%d,\"%s\"\n", type, c.tag.c_str(), r.ok ? 1 : 0,
                  r.strength_ran ? 1 : 0, r.cells, num_after(j, "cells_credited"), num_after(j, "cells_no_credit"),
                  num_after(j, "margin_worst_case"), sm, oor ? 1 : 0,
                  law.rfind(std::string(type) + "'s own", 0) == 0 || law.rfind("the full octet", 0) == 0 ? 1 : 0,
                  str_after(j, "not_certified_reason").c_str());
      std::fflush(stdout);
    }
  }
  return 0;
}
