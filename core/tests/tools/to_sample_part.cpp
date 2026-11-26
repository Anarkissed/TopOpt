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
// Writes sample_bracket_a.stl and job.json (PLA, res 96, 50 % infill, six
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

int main(int argc, char** argv) {
  if (argc < 2) {
    std::printf("usage: %s <folder>\n", argv[0]);
    return 2;
  }
  const std::string dir = argv[1];
  const std::vector<double> xs = {0, 2, 18, 20, 60, 80, 100};
  const std::vector<double> ys = {0, 15, 17, 33, 35, 50};
  const std::vector<double> zs = {0, 3, 7, 10, 50, 70, 73};
  const TriangleMesh mesh = cells_mesh(xs, ys, zs, [&](int i, int j, int k) {
    const double x = 0.5 * (xs[static_cast<std::size_t>(i)] + xs[static_cast<std::size_t>(i) + 1]);
    const double y = 0.5 * (ys[static_cast<std::size_t>(j)] + ys[static_cast<std::size_t>(j) + 1]);
    const double z = 0.5 * (zs[static_cast<std::size_t>(k)] + zs[static_cast<std::size_t>(k) + 1]);
    if (x < 80 && z < 10) return true;                        // base
    if (x < 20 && z > 10 && z < 70) return true;              // upright
    if (x > 20 && x < 60 && z > 10 && z < 50) return true;    // corner fill
    if (x > 2 && x < 18 && y > 17 && y < 33 && z > 70) return true;   // boss
    if (x > 80 && y > 15 && y < 35 && z > 3 && z < 7) return true;    // tab
    return false;
  });
  const std::string stl = dir + "/sample_bracket_a.stl";
  write_stl_file(stl, mesh, StlFormat::Binary);
  const StepModel m = import_part_file_resolved(stl);
  const int base_under = face_at(m, 0, 0, -1, 0.0);
  const int tab_top = face_at(m, 0, 0, 1, 7.0);
  const int boss_top = face_at(m, 0, 0, 1, 73.0);
  std::printf("faces %d: base underside %d, tab top %d, boss top %d\n", m.face_count, base_under,
              tab_top, boss_top);
  if (base_under < 0 || tab_top < 0 || boss_top < 0) return 1;
  std::ofstream(dir + "/job.json")
      << "{\"model\": \"sample_bracket_a.stl\", \"material\": \"PLA\", \"mode\": \"minimize_plastic\", "
         "\"resolution\": 96, \"plsm\": {\"enabled\": true}, "
         "\"loads\": {\"minimize_plastic\": true, \"safety_margin\": 1.5, \"build_dir\": [0, 0, 1], "
         "\"infill_percent\": 50, \"wall_loops\": 6, \"wall_line_width_mm\": 0.45, \"layer_height_mm\": 0.2, "
         "\"anchor_face_ids\": [" << base_under << ", " << tab_top << "], "
         "\"groups\": [{\"face_ids\": [" << boss_top << "], \"force\": [300, 0, -260]}]}, "
         "\"output\": {\"report\": \"report.json\", \"mesh_format\": \"stl\", \"mesh_prefix\": \"variant\"}}\n";
  std::printf("wrote %s and %s/job.json\n", stl.c_str(), dir.c_str());
  return 0;
}
