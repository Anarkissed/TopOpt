// Finding 8 probe: a sheet sample cube contoured as today and with bounded simplification.
#include "topopt/lattice.hpp"
#include "topopt/lattice_boundary.hpp"
#include "topopt/lattice_gen.hpp"
#include "topopt/tpms_gen.hpp"
#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <map>
#include <string>
#include <tuple>
using namespace topopt;
struct Count : TriangleSink {
  long long n = 0, inner = 0; double lo = 0, hi = 0, zlo = 0, zhi = 0;
  std::map<std::tuple<double,double,double>, int> vid;
  std::map<std::pair<int,int>, int> edges;
  int id(const Vec3& p) { auto k = std::make_tuple(p.x, p.y, p.z); auto it = vid.find(k); if (it != vid.end()) return it->second; int i = (int)vid.size(); vid[k] = i; return i; }
  void add_triangle(const Vec3& a, const Vec3& b, const Vec3& c) override {
    ++n; int i = id(a), j = id(b), k = id(c);
    const double cx = (a.x + b.x + c.x) / 3, cy = (a.y + b.y + c.y) / 3, cz = (a.z + b.z + c.z) / 3;
    if (cx >= lo && cx < hi && cy >= lo && cy < hi && cz >= zlo && cz < zhi) ++inner;
    for (auto e : {std::make_pair(i,j), std::make_pair(j,k), std::make_pair(k,i)}) ++edges[{std::min(e.first,e.second), std::max(e.first,e.second)}];
  }
};
int main(int argc, char** argv) {
  const std::string id = argv[1]; const double cell = atof(argv[2]), size = atof(argv[3]), rho = atof(argv[4]), dev = atof(argv[5]);
  const LatticeTopology t = lattice_topology_from_id(id);
  const double wall = lattice_strut_diameter_mm(t, rho, cell);
  const int n = (int)(size / cell + 0.5);
  const double s = cell / 8.0, plate = 1.5;
  TpmsGenOptions o; o.min_wall_mm = wall; o.dc_cell_mm = std::min(wall / 3.0, argc > 6 ? cell / atof(argv[6]) : 1e9);
  o.max_deviation_mm = dev; o.bead_mm = 0.42; o.true_wall_mm = [wall](const Vec3&) { return wall; }; o.wall_param_of = [t, cell](double w) { return lattice_sheet_wall_param_mm(t, w, cell); }; if (argc > 7) o.bead_mm = atof(argv[7]);
  const double h = o.dc_cell_mm;
  LatticeBoundary cube; cube.add_box(Vec3{-h, -h, 0.5 * plate}, Vec3{size + h, size + h, plate + size + h});
  TpmsRegion TR; TR.anchor = Vec3{-s, -s, plate - s}; TR.nx = TR.ny = TR.nz = n + 1; TR.cell_mm = cell; TR.boundary = &cube;
  TpmsWallField W; W.uniform_mm = lattice_sheet_wall_param_mm(t, wall, cell);
  Count c; c.lo = cell; c.hi = size - cell; c.zlo = plate + cell; c.zhi = plate + size - cell;
  const auto t0 = std::chrono::steady_clock::now();
  const TpmsGenStats ts = generate_tpms(id == "gyroid" ? TpmsKind::Gyroid : TpmsKind::SchwarzD, TR, W, c, o);
  const double sec = std::chrono::duration<double>(std::chrono::steady_clock::now() - t0).count();
  long long bad = 0; for (auto& e : c.edges) if (e.second != 2) ++bad;
  const double cells = (size / cell) * (size / cell) * (size / cell);
  std::printf("%s cell %.0f size %.0f rho %.3f wall %.3f h %.4f dev %.3f: DC %zu -> out %lld tris (%.0f / cell), edges not used twice %lld, %.1f s\n",
              id.c_str(), cell, size, rho, wall, h, dev, ts.dc.triangles, c.n, c.n / cells, bad, sec);
  const double ic = (size / cell - 2) * (size / cell - 2) * (size / cell - 2);
  if (ic > 0) std::printf("   interior cells %.0f: %lld triangles, %.0f per cell\n", ic, c.inner, c.inner / ic);
  if (ts.simplified)
    std::printf("   splits %lld, collapses %lld, rejected dev %lld topo %lld, flushes %lld; measured max out %.4f in %.4f mm, past max_in %lld of %lld samples; simplify %.1f s\n",
                ts.simplify.splits, ts.simplify.collapses, ts.simplify.rejected_deviation, ts.simplify.rejected_topology, ts.simplify.flushes,
                ts.simplify.max_out_measured_mm, ts.simplify.max_in_measured_mm, ts.simplify.samples_past_max_in, ts.simplify.samples, ts.simplify.seconds); std::printf("   cut samples %lld max out %.4f in %.4f; worst sheet excess %.4f at (%.3f, %.3f, %.3f)\n", ts.simplify.cut_samples, ts.simplify.cut_max_out_mm, ts.simplify.cut_max_in_mm, ts.simplify.worst_excess_mm, ts.simplify.worst_at.x, ts.simplify.worst_at.y, ts.simplify.worst_at.z);
}
