// TO rebuild stage 1, M6 (TOReview's question, handed to LatticeReview 2026-11-25): on the strength check's own grid,
// how the PROTECTED skin and the LATTICE cubes meet, with the stage switch (TOPOPT_FACE_LOADS) off and `face`.
//
//   LATTICE: lattice_layout::lattice_credit(layout, domain, bars, left_out_at, CreditGrid, &in_part, threads), the call
//            run_lattice_file_strength makes, on the strength job's grid (build_production_loadcase's part grid, which
//            strength_setup solves on: no design box); a cube is lattice when cell[e] >= 0 (credited or not).
//   PROTECTED: the job's face protection as build_production_loadcase freezes it: mask_face_by_stage(grid, model, face,
//            FrozenSolid, region_depth_layers(depth, h), depth, mask), which follows the switch.
// Among the part's solid cubes: protected only, lattice only, BOTH, NEITHER; BOTH and NEITHER split into those within
// one voxel of the skin's inner boundary (centre at |distance from the protected face - depth| <= h, over the face)
// and elsewhere.
//
// Jobs, made as test_to_stage1_lattice_check.cpp makes them at 6c5ff9eb: A (32 x 32 x 16 mm box on the grid, cells
// from the top face 8 mm deep, no protection: the control) and B (the chamfered box, cells from the top face 24 mm
// deep, the chamfer loaded with a 1.3 mm skin). Pins nothing: a run that does not complete is a failure.
#include <algorithm>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <filesystem>
#include <fstream>
#include <sstream>
#include <string>
#include <vector>

#include "topopt/face_region.hpp"
#include "topopt/face_overrides.hpp"
#include "topopt/job.hpp"
#include "topopt/lattice_file_strength.hpp"
#include "topopt/lattice_layout_file.hpp"
#include "topopt/loadcase.hpp"
#include "topopt/step.hpp"
#include "topopt/stl.hpp"
#include "topopt/voxel.hpp"

using namespace topopt;
using namespace topopt::lattice_layout;

namespace {

const std::string kDir = std::string(TMP_DIR) + "/to_stage1_lattice_masks";

void write(const std::string& path, const std::string& text) { std::ofstream(path) << text; }

TriangleMesh plain_box(double L, double W, double H) {
  TriangleMesh m;
  for (const Vec3& v : std::vector<Vec3>{{0, 0, 0}, {L, 0, 0}, {L, W, 0}, {0, W, 0},
                                         {0, 0, H}, {L, 0, H}, {L, W, H}, {0, W, H}})
    m.vertices.push_back(v);
  const int tri[12][3] = {{0, 2, 1}, {0, 3, 2}, {4, 5, 6}, {4, 6, 7}, {0, 1, 5}, {0, 5, 4},
                          {3, 7, 6}, {3, 6, 2}, {0, 4, 7}, {0, 7, 3}, {1, 2, 6}, {1, 6, 5}};
  for (const auto& x : tri) m.triangles.push_back({x[0], x[1], x[2]});
  return m;
}
// As test_to_stage1_lattice_check.cpp at 6c5ff9eb: 56 x 56 x 32 mm, one top edge chamfered 9 mm in, 7 mm down.
TriangleMesh chamfered_box() {
  const double L = 56, W = 56, H = 32, in = 9, down = 7;
  const double px[5] = {0, L, L, L - in, 0}, pz[5] = {0, 0, H - down, H, H};
  TriangleMesh m;
  for (int y = 0; y < 2; ++y)
    for (int i = 0; i < 5; ++i) m.vertices.push_back({px[i], y ? W : 0.0, pz[i]});
  for (int i = 0; i < 5; ++i) {
    const int a = i, b = (i + 1) % 5;
    m.triangles.push_back({a, b + 5, b});
    m.triangles.push_back({a, a + 5, b + 5});
  }
  for (int i = 1; i + 1 < 5; ++i) {
    m.triangles.push_back({0, i, i + 1});
    m.triangles.push_back({5, 5 + i + 1, 5 + i});
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

std::string file_job(const std::string& model, const Faces& f, int depth_mm) {
  return "{\"mode\": \"lattice_file\", \"model\": \"" + model + "\", \"output\": \"lattice.stl\", "
         "\"strength_job\": \"strength_job.json\", "
         "\"layout\": {\"min_strut_lines\": 2, \"region_ids\": [1], \"region_no_lattice\": [0], "
         "\"region_depth_mm\": [" + std::to_string(depth_mm) + "], \"region_expand_mm\": [0], \"region_face_counts\": [1], "
         "\"region_faces\": [" + std::to_string(f.top) + "], \"topology\": \"octet\", "
         "\"algorithm\": \"uniform\", \"cell_max_mm\": 8, \"min_cells_across\": 1}}";
}
std::string strength_job(const std::string& model, const Faces& f, int load_face, const std::string& protect) {
  return "{\"model\": \"" + model + "\", \"material\": \"PLA\", \"mode\": \"lattice_part\", \"resolution\": 40, "
         "\"loads\": {\"minimize_plastic\": true, \"safety_margin\": 1.5, \"build_dir\": [0, 0, 1], "
         "\"anchor_face_ids\": [" + std::to_string(f.bottom) + "], \"groups\": [{\"face_ids\": [" +
         std::to_string(load_face) + "], \"force\": [0, 0, -20]}]" + protect + "}, "
         "\"lattice\": {\"topology\": \"octet\", \"require_lattice_void_reaches_exterior\": false}, "
         "\"grading\": {\"topology\": \"octet\", \"cell_mm\": 8, \"min_extrudable_width_mm\": 0.45, "
         "\"intent\": \"structural\"}, "
         "\"output\": {\"report\": \"report.json\", \"mesh_format\": \"stl\", \"mesh_prefix\": \"variant\"}}";
}

// The protected face as a plane patch: a point on it, its outward normal, and a test that a point's foot on the plane
// lies on the face (the face's own triangles, within 1e-6 mm).
struct Patch {
  Vec3 p{}, n{};
  std::vector<std::array<Vec3, 3>> tris;
  bool over(const Vec3& q) const {
    const double d = (q.x - p.x) * n.x + (q.y - p.y) * n.y + (q.z - p.z) * n.z;
    const Vec3 f{q.x - d * n.x, q.y - d * n.y, q.z - d * n.z};
    for (const auto& t : tris) {
      bool in = true;
      for (int e = 0; e < 3 && in; ++e) {
        const Vec3& a = t[static_cast<std::size_t>(e)];
        const Vec3& b = t[static_cast<std::size_t>((e + 1) % 3)];
        const Vec3 ab{b.x - a.x, b.y - a.y, b.z - a.z}, af{f.x - a.x, f.y - a.y, f.z - a.z};
        const Vec3 c{ab.y * af.z - ab.z * af.y, ab.z * af.x - ab.x * af.z, ab.x * af.y - ab.y * af.x};
        in = c.x * n.x + c.y * n.y + c.z * n.z >= -1e-6;
      }
      if (in) return true;
    }
    return false;
  }
  double depth(const Vec3& q) const { return -((q.x - p.x) * n.x + (q.y - p.y) * n.y + (q.z - p.z) * n.z); }
};
Patch patch_of(const StepModel& m, int face) {
  Patch P;
  const StepFaceInfo& fi = m.faces[static_cast<std::size_t>(face)];
  P.n = fi.plane_normal;
  for (std::size_t t = 0; t < m.triangle_face.size(); ++t)
    if (m.triangle_face[t] == face) {
      const auto& tr = m.mesh.triangles[t];
      P.tris.push_back({m.mesh.vertices[static_cast<std::size_t>(tr[0])], m.mesh.vertices[static_cast<std::size_t>(tr[1])],
                        m.mesh.vertices[static_cast<std::size_t>(tr[2])]});
    }
  if (!P.tris.empty()) P.p = P.tris[0][0];
  return P;
}

struct Counts {
  bool ok = false;
  std::size_t solid = 0, prot_only = 0, lat_only = 0, both = 0, neither = 0;
  std::size_t both_edge = 0, both_else = 0, neither_edge = 0, neither_else = 0, protected_all = 0, lattice_all = 0;
  double h = 0.0;
};

Counts measure(const std::string& tag, const std::string& mode, const std::string& job, const std::string& sjob,
               int protect_face, double protect_mm) {
  if (mode.empty()) unsetenv("TOPOPT_FACE_LOADS"); else setenv("TOPOPT_FACE_LOADS", mode.c_str(), 1);
  const std::string folder = kDir + "/" + tag + (mode.empty() ? "_off" : "_" + mode);
  std::filesystem::remove_all(folder);
  std::filesystem::create_directories(folder);
  write(kDir + "/" + tag + "_job.json", job);
  write(kDir + "/strength_job.json", sjob);
  Counts out;
  const StrengthCheck real = lattice_file_strength_check(MATERIALS_JSON_PATH, SETTINGS_RULES_PATH);
  StrengthCheck check = real;
  // While the file job's session and outcome are alive: the strength job's grid, its protected skin, the lattice.
  check.run = [&](const StrengthAsk& ask) {
    const JobDescription sj = load_job_file(ask.job_path, 1.5);
    const StepModel model = import_part_file_resolved(kDir + "/" + sj.model);
    const ProductionRunSetup setup = build_production_loadcase(model, sj.resolution, production_loadcase_from_job(sj, model));
    const VoxelGrid& g = setup.grid;
    const std::size_t nv = g.voxel_count();
    std::vector<char> in_part(nv, 0);
    for (int k = 0; k < g.nz; ++k)
      for (int j = 0; j < g.ny; ++j)
        for (int i = 0; i < g.nx; ++i) in_part[g.index(i, j, k)] = g.solid(i, j, k) ? 1 : 0;
    CreditGrid cg;
    cg.origin = g.origin;
    cg.spacing = g.spacing;
    cg.nx = g.nx;
    cg.ny = g.ny;
    cg.nz = g.nz;
    const LatticeCredit credit = lattice_credit(ask.outcome->layout, *ask.session->domain(), ask.outcome->bars,
                                                ask.made->left_out_at, cg, &in_part, ask.threads);
    DesignMask mask = make_active_mask(g);
    Patch P;
    if (protect_face >= 0) {
      mask_face_by_stage(g, model, protect_face, MaskValue::FrozenSolid, region_depth_layers(protect_mm, g.spacing),
                         protect_mm, mask);
      P = patch_of(model, protect_face);
    }
    const double h = g.spacing;
    out.h = h;
    for (int k = 0; k < g.nz; ++k)
      for (int j = 0; j < g.ny; ++j)
        for (int i = 0; i < g.nx; ++i) {
          const std::size_t e = g.index(i, j, k);
          if (!in_part[e]) continue;
          ++out.solid;
          const bool prot = mask[e] == MaskValue::FrozenSolid, lat = credit.cell[e] >= 0;
          out.protected_all += prot;
          out.lattice_all += lat;
          const Vec3 c{g.origin.x + (i + 0.5) * h, g.origin.y + (j + 0.5) * h, g.origin.z + (k + 0.5) * h};
          const bool edge = protect_face >= 0 && P.over(c) && std::fabs(P.depth(c) - protect_mm) <= h;
          if (prot && lat) { ++out.both; ++(edge ? out.both_edge : out.both_else); }
          else if (prot) ++out.prot_only;
          else if (lat) ++out.lat_only;
          else { ++out.neither; ++(edge ? out.neither_edge : out.neither_else); }
        }
    return real.run(ask);
  };
  const FileResult r = run_file_job(kDir + "/" + tag + "_job.json", folder, 0, nullptr, &check);
  unsetenv("TOPOPT_FACE_LOADS");
  out.ok = r.ok && r.strength_ran && out.solid > 0;
  std::printf("[%s %s] ok %d code %s bars %zu\n", tag.c_str(), mode.empty() ? "off" : mode.c_str(), r.ok,
              r.code.c_str(), r.bars);
  return out;
}

void row(const std::string& tag, const std::string& mode, const Counts& c) {
  std::printf("%-3s %-5s | voxel %.3f | solid %7zu | protected %6zu lattice %7zu | prot only %6zu | lat only %7zu | "
              "BOTH %5zu (at inner boundary %5zu, elsewhere %5zu) | NEITHER %6zu (at inner boundary %5zu, elsewhere %6zu)\n",
              tag.c_str(), mode.empty() ? "off" : mode.c_str(), c.h, c.solid, c.protected_all, c.lattice_all,
              c.prot_only, c.lat_only, c.both, c.both_edge, c.both_else, c.neither, c.neither_edge, c.neither_else);
  std::fflush(stdout);
}

}  // namespace

int main() {
  std::filesystem::remove_all(kDir);
  std::filesystem::create_directories(kDir);
  int failures = 0;
  write_stl_file(kDir + "/box.stl", plain_box(32, 32, 16), StlFormat::Binary);
  write_stl_file(kDir + "/chamfer.stl", chamfered_box(), StlFormat::Binary);
  Faces fa, fb;
  {
    const StepModel a = import_part_file_resolved(kDir + "/box.stl");
    fa.top = face_with_normal(a, {0, 0, 1});
    fa.bottom = face_with_normal(a, {0, 0, -1});
    const StepModel b = import_part_file_resolved(kDir + "/chamfer.stl");
    fb.top = face_with_normal(b, {0, 0, 1});
    fb.bottom = face_with_normal(b, {0, 0, -1});
    const double n = std::sqrt(7.0 * 7.0 + 9.0 * 9.0);
    fb.side = face_with_normal(b, {7.0 / n, 0.0, 9.0 / n});
  }
  if (fa.top < 0 || fa.bottom < 0 || fb.top < 0 || fb.bottom < 0 || fb.side < 0) {
    std::printf("a face was not found\n");
    return 1;
  }
  const std::string protect =
      ", \"face_protections\": [{\"face_id\": " + std::to_string(fb.side) + ", \"depth_mm\": 1.3}]";
  std::printf("[M6] the strength grid's solid cubes: protected skin x lattice cubes\n");
  for (const std::string mode : {"", "face"}) {
    const Counts a = measure("A", mode, file_job("box.stl", fa, 8), strength_job("box.stl", fa, fa.top, ""), -1, 0.0);
    if (!a.ok) ++failures;
    row("A", mode, a);
  }
  for (const std::string mode : {"", "face"}) {
    const Counts b = measure("B", mode, file_job("chamfer.stl", fb, 24),
                             strength_job("chamfer.stl", fb, fb.side, protect), fb.side, 1.3);
    if (!b.ok) ++failures;
    row("B", mode, b);
  }
  std::printf("[to stage1 lattice masks] %d failure(s)\n", failures);
  return failures == 0 ? 0 : 1;
}
