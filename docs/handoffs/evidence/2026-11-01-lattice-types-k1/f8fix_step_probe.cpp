// Finding 8 fix probe: a gyroid block whose TRUE wall is graded PER VOXEL (piecewise constant, as a
// run grades), simplified to 0.02 mm. argv: cell size voxel rho_lo rho_hi [u = one uniform wall].
// NO_STEPS=1 in the environment turns TpmsGenOptions::true_wall_steps off (the stall). Built and
// linked like f8_simp_probe.cpp (the link line of test_mesh_simplify).
#include "topopt/lattice.hpp"
#include "topopt/lattice_boundary.hpp"
#include "topopt/lattice_gen.hpp"
#include "topopt/tpms_gen.hpp"
#include <chrono>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <string>
using namespace topopt;
struct Count : TriangleSink { long long n = 0; void add_triangle(const Vec3&, const Vec3&, const Vec3&) override { ++n; } };
int main(int argc, char** argv) {
  const double cell = atof(argv[1]), size = atof(argv[2]), vox = atof(argv[3]), rlo = atof(argv[4]), rhi = atof(argv[5]);
  const bool uniform = argc > 6;
  const LatticeTopology t = LatticeTopology::Gyroid;
  auto rho_at = [=](const Vec3& p) {
    if (uniform) return 0.5 * (rlo + rhi);
    const long i = (long)std::floor(p.x / vox), j = (long)std::floor(p.y / vox), k = (long)std::floor(p.z / vox);
    const unsigned long hsh = (unsigned long)(i * 73856093L ^ j * 19349663L ^ k * 83492791L);
    return rlo + (rhi - rlo) * ((hsh % 1000) / 999.0);
  };
  auto wall_at = [=](const Vec3& p) { return lattice_strut_diameter_mm(t, rho_at(p), cell); };
  const double wmin = lattice_strut_diameter_mm(t, rlo, cell);
  const int n = (int)(size / cell + 0.5);
  const double plate = 1.5;
  TpmsGenOptions o; o.min_wall_mm = wmin;
  o.max_deviation_mm = 0.02; o.bead_mm = 0.45; o.true_wall_mm = wall_at;
  o.wall_param_of = [t, cell](double w) { return lattice_sheet_wall_param_mm(t, w, cell); };
  o.true_wall_steps = std::getenv("NO_STEPS") == nullptr;
  const double h = wmin / 3.0;
  LatticeBoundary cube; cube.add_box(Vec3{-h, -h, 0.5 * plate}, Vec3{size + h, size + h, plate + size + h});
  TpmsRegion TR; TR.anchor = Vec3{0, 0, plate}; TR.nx = TR.ny = TR.nz = n; TR.cell_mm = cell; TR.boundary = &cube;
  TpmsWallField W; W.field = [=](const Vec3& p) { return lattice_sheet_wall_param_mm(t, wall_at(p), cell); };
  Count c;
  const auto t0 = std::chrono::steady_clock::now();
  const TpmsGenStats ts = generate_tpms(TpmsKind::Gyroid, TR, W, c, o);
  const double sec = std::chrono::duration<double>(std::chrono::steady_clock::now() - t0).count();
  std::printf("%s cell %.1f size %.0f voxel %.2f rho %.3f..%.3f h %.4f: DC %zu -> out %lld, %.1f s\n", uniform ? "UNIFORM" : "STEPPED", cell, size, vox, rlo, rhi, h, ts.dc.triangles, c.n, sec);
  const auto& s = ts.simplify;
  std::printf("   splits %lld collapses %lld rej dev %lld topo %lld flushes %lld; max out %.4f in %.4f, past max_in %lld of %lld; worst excess %.4f; cut %lld out %.4f in %.4f; step %lld out %.4f in %.4f outside band %lld worst %.5f; simplify %.1f s\n",
              s.splits, s.collapses, s.rejected_deviation, s.rejected_topology, s.flushes, s.max_out_measured_mm, s.max_in_measured_mm, s.samples_past_max_in, s.samples, s.worst_excess_mm, s.cut_samples, s.cut_max_out_mm, s.cut_max_in_mm, s.step_samples, s.step_max_out_mm, s.step_max_in_mm, s.step_samples_outside_band, s.step_worst_outside_band_mm, s.seconds);
}
