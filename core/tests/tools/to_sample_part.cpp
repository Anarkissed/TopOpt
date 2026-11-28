// TO rebuild: a MADE sample part for the measurements his own parts cannot give
// (the maintainer, 2026-11-26: "I don't have any other parts I can think of. Can
// you design a sample?"). His reference parts are either mostly frozen (the
// stand: 77 %), too weak as drawn for a reduction run (Base, Pressing,
// PillowBlock), or a growth job (Stand v4); only Top Motor Mount is carved.
//
// "Sample bracket A": an L-bracket with a filled corner, nothing frozen but its
// fixed and loaded faces, and faces with very different thicknesses behind them:
//   base      80 x 50 x 10 mm, on the bed
//   upright   20 x 50 x 60 mm, standing on one end of the base
//   corner    40 x 50 x 40 mm of solid fill between them (what there is to carve)
//   boss      16 x 16 x 3 mm on top of the upright: THE LOADED FACE (its top)
//   tab       20 x 20 x 4 mm off the far end of the base, 3 mm up: a FIXED face
//             (its top) with 4 mm behind it
//   the base's underside: the other FIXED face, 10 to 70 mm behind it
// The load is 400 N on the boss, pushing along the base and down.
//
// Two more made parts follow the same pattern (B: a beam held at both ends; C: a
// hook); see kSamples. Writes the part's .stl and job.json (PLA, res 96, 50 % infill, six
// walls) into the folder given. Not a test: a tool, run by hand.
#include <cmath>
#include <cstdio>
#include <fstream>
#include <string>
#include <vector>

#include "topopt/face_overrides.hpp"
#include "topopt/mesh.hpp"
#include "topopt/step.hpp"
#include "topopt/stl.hpp"

using namespace topopt;

namespace {

template <class Full>
TriangleMesh cells_mesh(const std::vector<double>& xs, const std::vector<double>& ys,
                        const std::vector<double>& zs, Full full) {
  const int nx = static_cast<int>(xs.size()), ny = static_cast<int>(ys.size()),
            nz = static_cast<int>(zs.size());
  TriangleMesh tm;
  const auto vid = [&](int i, int j, int k) { return (k * ny + j) * nx + i; };
  for (int k = 0; k < nz; ++k)
    for (int j = 0; j < ny; ++j)
      for (int i = 0; i < nx; ++i)
        tm.vertices.push_back({xs[static_cast<std::size_t>(i)], ys[static_cast<std::size_t>(j)],
                               zs[static_cast<std::size_t>(k)]});
  const auto quad = [&](int a, int b, int c, int d) {
    tm.triangles.push_back({a, b, c});
    tm.triangles.push_back({a, c, d});
  };
  const auto in = [&](int i, int j, int k) {
    return i >= 0 && j >= 0 && k >= 0 && i < nx - 1 && j < ny - 1 && k < nz - 1 && full(i, j, k);
  };
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

// The planar face with outward normal (nx, ny, nz) lying at `off` along it.
int face_at(const StepModel& m, double nx, double ny, double nz, double off) {
  for (int f = 0; f < m.face_count; ++f) {
    const StepFaceInfo& x = m.faces[static_cast<std::size_t>(f)];
    if (x.kind == StepSurfaceKind::Plane &&
        x.plane_normal.x * nx + x.plane_normal.y * ny + x.plane_normal.z * nz > 0.99 &&
        std::fabs(x.plane_origin.x * nx + x.plane_origin.y * ny + x.plane_origin.z * nz - off) < 1e-6)
      return f;
  }
  return -1;
}

}  // namespace

// One made part: its mesh by a fill rule over a grid of breaks, its fixed and
// loaded faces by their plane, and the push on the loaded face.
struct Plane { double nx, ny, nz, off; };
struct Sample {
  const char* name;
  std::vector<double> xs, ys, zs;
  bool (*full)(double, double, double);
  std::vector<Plane> fixed;
  Plane loaded;
  double force[3];
};

// A: the L-bracket with a filled corner (see the top of this file).
bool full_a(double x, double y, double z) {
  if (x < 80 && z < 10) return true;                                 // base
  if (x < 20 && z > 10 && z < 70) return true;                       // upright
  if (x > 20 && x < 60 && z > 10 && z < 50) return true;             // corner fill
  if (x > 2 && x < 18 && y > 17 && y < 33 && z > 70) return true;    // boss
  if (x > 80 && y > 15 && y < 35 && z > 3 && z < 7) return true;     // tab
  return false;
}
// B: a beam held at both ends and pushed down in the middle. 120 x 30 x 24 mm,
// both END faces fixed (120 mm of material behind each: the thick case for the
// pad), a 20 x 20 x 3 mm boss on top at mid-span carrying 600 N straight down.
bool full_b(double x, double y, double z) {
  if (z < 24) return true;
  return x > 50 && x < 70 && y > 5 && y < 25;                        // boss
}
// C: a hook. A 20 x 20 mm stem hanging from its fixed TOP face (80 mm behind it),
// a 50 mm arm at the bottom, an upturned 10 mm tip; 25 N on the tip's top, down
// and outward, so the load is well off the stem's line. (Printed upright the stem
// hangs ACROSS the layers, the weak direction: at 250 N it stood at 0.40 as drawn,
// too weak to carve; at 25 N it has room.)
bool full_c(double x, double y, double z) {
  (void)y;
  if (x < 20) return true;                                           // stem, z 0..80
  if (z < 15 && x < 70) return true;                                 // arm
  return x > 60 && x < 70 && z < 35;                                 // tip
}

const Sample kSamples[] = {
    {"sample_bracket_a", {0, 2, 18, 20, 60, 80, 100}, {0, 15, 17, 33, 35, 50}, {0, 3, 7, 10, 50, 70, 73},
     full_a, {{0, 0, -1, 0.0}, {0, 0, 1, 7.0}}, {0, 0, 1, 73.0}, {300, 0, -260}},
    {"sample_beam_b", {0, 50, 70, 120}, {0, 5, 25, 30}, {0, 24, 27},
     full_b, {{-1, 0, 0, 0.0}, {1, 0, 0, 120.0}}, {0, 0, 1, 27.0}, {0, 0, -600}},
    {"sample_hook_c", {0, 20, 60, 70}, {0, 20}, {0, 15, 35, 80},
     full_c, {{0, 0, 1, 80.0}}, {0, 0, 1, 35.0}, {12, 0, -22}},
};

int main(int argc, char** argv) {
  if (argc < 2) {
    std::printf("usage: %s <folder> [a|b|c]   (default a)\n", argv[0]);
    return 2;
  }
  const std::string dir = argv[1];
  const char which = argc > 2 ? argv[2][0] : 'a';
  const Sample& sp = kSamples[which == 'b' ? 1 : which == 'c' ? 2 : 0];
  const TriangleMesh mesh = cells_mesh(sp.xs, sp.ys, sp.zs, [&](int i, int j, int k) {
    return sp.full(0.5 * (sp.xs[static_cast<std::size_t>(i)] + sp.xs[static_cast<std::size_t>(i) + 1]),
                   0.5 * (sp.ys[static_cast<std::size_t>(j)] + sp.ys[static_cast<std::size_t>(j) + 1]),
                   0.5 * (sp.zs[static_cast<std::size_t>(k)] + sp.zs[static_cast<std::size_t>(k) + 1]));
  });
  const std::string stl = dir + "/" + sp.name + ".stl";
  write_stl_file(stl, mesh, StlFormat::Binary);
  const StepModel m = import_part_file_resolved(stl);
  std::string anchors;
  for (const Plane& f : sp.fixed) {
    const int id = face_at(m, f.nx, f.ny, f.nz, f.off);
    if (id < 0) {
      std::printf("a fixed face was not found\n");
      return 1;
    }
    anchors += (anchors.empty() ? "" : ", ") + std::to_string(id);
  }
  const int loaded = face_at(m, sp.loaded.nx, sp.loaded.ny, sp.loaded.nz, sp.loaded.off);
  std::printf("%s: %d faces; fixed [%s], loaded %d\n", sp.name, m.face_count, anchors.c_str(), loaded);
  if (loaded < 0) return 1;
  std::ofstream(dir + "/job.json")
      << "{\"model\": \"" << sp.name << ".stl\", \"material\": \"PLA\", \"mode\": \"minimize_plastic\", "
         "\"resolution\": 96, \"plsm\": {\"enabled\": true}, "
         "\"loads\": {\"minimize_plastic\": true, \"safety_margin\": 1.5, \"build_dir\": [0, 0, 1], "
         "\"infill_percent\": 50, \"wall_loops\": 6, \"wall_line_width_mm\": 0.45, \"layer_height_mm\": 0.2, "
         "\"anchor_face_ids\": [" << anchors << "], "
         "\"groups\": [{\"face_ids\": [" << loaded << "], \"force\": [" << sp.force[0] << ", " << sp.force[1]
      << ", " << sp.force[2] << "]}]}, "
         "\"output\": {\"report\": \"report.json\", \"mesh_format\": \"stl\", \"mesh_prefix\": \"variant\"}}\n";
  std::printf("wrote %s and %s/job.json\n", stl.c_str(), dir.c_str());
  return 0;
}
