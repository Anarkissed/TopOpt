// L3/L4 EVIDENCE for the lattice grading law (handoff 2026-07-29-lattice-grading-law).
//
// Runs the production law (grading.hpp) on the maintainer's own L-bracket and reports
// what it produces (bar L3): the density + cell-size field summary, the resulting strut
// diameters, and the cells-per-member at the thinnest LATTICED member — plus, when a
// member is too thin for any printable cell to hold the cells-per-member floor, how much
// of the part stays SOLID (bar L4), read straight off the report the law returns.
//
// It then closes the loop end to end: it feeds the posture the law produced back into
// analyze_fixed_design (the SAME certification engine production uses) and confirms the
// composite certifies — a real margin, no throw — which is the operational form of bar
// L2 (the law never emits a point the gate cannot certify).
//
// Standalone, NOT in CTest (like the other lattice probes). Build + run:
//   cmake -S . -B build -DTOPOPT_USE_OCCT=OFF -DTOPOPT_BUILD_TESTS=OFF && \
//     cmake --build build --target topopt -j
//   c++ -std=c++17 -O2 -I include tests/harness/lattice_grading_probe.cpp \
//       build/libtopopt.a -o build/grading_probe
//   TOPOPT_LATTICE_CSV_DIR=<dir> ./build/grading_probe

#include <array>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <limits>
#include <string>
#include <vector>

#include "topopt/analyze.hpp"
#include "topopt/fea.hpp"
#include "topopt/grading.hpp"
#include "topopt/lattice.hpp"
#include "topopt/materials.hpp"
#include "topopt/simp.hpp"
#include "topopt/voxel.hpp"

using namespace topopt;

namespace {

const double kE = 3500.0, kNu = 0.33;

Material pla() {
  Material m;
  m.youngs_modulus_mpa = kE; m.yield_strength_mpa = 50.0;
  m.density_g_cm3 = 1.24; m.z_knockdown = 0.8; m.poisson = kNu; m.family = "fdm";
  return m;
}

// The L-bracket of handoff 134's probe, EMBEDDED in a `pad`-voxel Empty margin on all
// six faces. The margin is not cosmetic: the local-member-thickness measure needs a
// surrounding void to see a member's true 3D width — a bracket flush to the grid box
// reads as infinitely thick in the flush directions (its ny width vanishes). arm/span
// legs `t` voxels thick, `ny` wide, clamped at the top of the arm, loaded on the far
// face of the span. `h` scales it to physical mm.
VoxelGrid l_bracket(std::vector<DirichletBC>& bcs, std::vector<NodalLoad>& loads,
                    int arm, int span, int ny, int t, double h, double fz,
                    int pad = 3) {
  VoxelGrid g;
  g.nx = span + 2 * pad; g.ny = ny + 2 * pad; g.nz = arm + 2 * pad; g.spacing = h;
  g.origin = Vec3{0, 0, 0};
  g.tags.assign(static_cast<std::size_t>(g.nx) * g.ny * g.nz, VoxelTag::Empty);
  auto P = [pad](int i, int j, int k) { return std::array<int, 3>{i + pad, j + pad, k + pad}; };
  for (int k = 0; k < arm; ++k)
    for (int j = 0; j < ny; ++j)
      for (int i = 0; i < span; ++i)
        if (i < t || k < t) { auto q = P(i, j, k); g.set_tag(q[0], q[1], q[2], VoxelTag::Interior); }
  for (int j = 0; j < ny; ++j)
    for (int i = 0; i < t; ++i) { auto q = P(i, j, arm - 1); g.set_tag(q[0], q[1], q[2], VoxelTag::Fixture); }
  for (int k = 0; k < t; ++k)
    for (int j = 0; j < ny; ++j) { auto q = P(span - 1, j, k); g.set_tag(q[0], q[1], q[2], VoxelTag::Load); }
  bcs.clear();
  for (int b = 0; b <= ny; ++b)
    for (int a = 0; a <= t; ++a) {
      const int node = fea_node_index(g, a + pad, b + pad, arm + pad);
      bcs.push_back({node, 0, 0.0});
      bcs.push_back({node, 1, 0.0});
      bcs.push_back({node, 2, 0.0});
    }
  // Distribute a downward tip force over the load face's nodes.
  loads.clear();
  for (int k = 0; k <= t; ++k)
    for (int j = 0; j <= ny; ++j)
      loads.push_back({fea_node_index(g, span + pad, j + pad, k + pad), 2, fz});
  return g;
}

std::vector<double> density_of(const VoxelGrid& g) {
  std::vector<double> d(g.voxel_count(), 0.0);
  for (std::size_t i = 0; i < d.size(); ++i)
    if (g.tags[i] != VoxelTag::Empty) d[i] = 1.0;
  return d;
}

const char* yn(bool b) { return b ? "yes" : "no"; }
std::string finite_or(double v, const char* alt) {
  if (!std::isfinite(v)) return alt;
  char buf[64]; std::snprintf(buf, sizeof buf, "%.3f", v); return buf;
}

FILE* g_csv = nullptr;

void run_specimen(const std::string& name, VoxelGrid g,
                  const std::vector<DirichletBC>& bcs,
                  const std::vector<NodalLoad>& loads, double target_cell_mm,
                  double min_width_mm) {
  const std::vector<double> density = density_of(g);

  // 1. Solve the SOLID design for the demand (von Mises) field.
  FeaSolution sol = fea_solve_cg(g, kE, kNu, bcs, loads, 1e-8, 0, nullptr);
  const std::vector<double> demand = fea_von_mises_field(g, kE, kNu, sol);

  // 2. Grade.
  GradingLawParams gp;
  gp.topology = LatticeTopology::Octet;
  gp.target_cell_size_mm = target_cell_mm;
  gp.min_extrudable_width_mm = min_width_mm;
  gp.demand_exponent = 1.0;
  const GradedField gf = grade_lattice(g, density, demand, nullptr, gp);

  // 3. Report (L3 / L4).
  std::printf("\n===== %s (%dx%dx%d @ %.2f mm) =====\n", name.c_str(), g.nx, g.ny,
              g.nz, g.spacing);
  std::printf("  limits READ from core: band rho [%.5f, %.5f], cells/member floor %.1f\n",
              gf.band_rho_min, gf.band_rho_max, gf.cells_per_member_floor);
  std::printf("  target cell %.3f mm -> chosen %.3f mm (printability floor %.3f mm, floored: %s)\n",
              target_cell_mm, gf.cell_size_mm, gf.printability_floor_mm,
              yn(gf.cell_size_floored));
  std::printf("  region candidates: %zu   latticed: %zu   SOLID fallback (L4): %zu\n",
              gf.region_voxels, gf.latticed_voxels, gf.solid_fallback_voxels);
  if (gf.region_ungradeable) {
    std::printf("  >> L4: REGION UNGRADEABLE — no printable cell holds the floor in any\n"
                "     member; the whole region stays SOLID. (This is the honest answer\n"
                "     for a member thinner than floor x printability-floor cell.)\n");
  } else {
    std::printf("  density field: rho in [%.4f, %.4f]  (clamped to the band)\n",
                gf.rho_min_used, gf.rho_max_used);
    std::printf("  strut diameter: [%.3f, %.3f] mm   (min extrudable %.3f mm; any below: %s)\n",
                gf.min_strut_diameter_mm, gf.max_strut_diameter_mm,
                min_width_mm, yn(gf.any_strut_below_min));
    std::printf("  thinnest latticed member: %s mm  ->  cells/member %s  (floor %.1f)\n",
                finite_or(gf.min_member_width_mm, "inf(>cap)").c_str(),
                finite_or(gf.min_cells_per_member, "inf").c_str(),
                gf.cells_per_member_floor);
  }

  // 4. L2 end to end: the produced posture certifies through the real engine.
  Material mat = pla();
  SimpParams params; params.youngs_modulus = kE; params.poisson = kNu; params.penalty = 3.0;
  const Vec3 build_dir{0, 0, 1};
  KnockdownSpec kd;
  const double part_solid = static_cast<double>(g.solid_count());
  FixedDesignAnalysis solid = analyze_fixed_design(
      g, params, density, bcs, loads, mat, build_dir, 1e-8, 0, SolverKind::JacobiCG,
      0.0, kd, true, part_solid);
  if (gf.latticed_voxels > 0) {
    FixedDesignAnalysis comp = analyze_fixed_design(
        g, params, density, bcs, loads, mat, build_dir, 1e-8, 0, SolverKind::JacobiCG,
        0.0, kd, true, part_solid, &gf.posture);
    std::printf("  CERTIFY (L2, end to end): posture consumed -> lattice_certified=%s, "
                "margin %.4f (solid %.4f), mass %.2f g (solid %.2f g)\n",
                yn(comp.lattice_certified), comp.margin.worst_case,
                solid.margin.worst_case, comp.mass_grams, solid.mass_grams);
  } else {
    std::printf("  CERTIFY: nothing latticed -> the design is the solid part "
                "(margin %.4f, mass %.2f g).\n",
                solid.margin.worst_case, solid.mass_grams);
  }

  if (g_csv)
    std::fprintf(g_csv,
                 "%s,%d,%d,%d,%.3f,%.5f,%.5f,%.1f,%.3f,%.3f,%d,%zu,%zu,%zu,%.4f,%.4f,"
                 "%.3f,%.3f,%s,%s,%d\n",
                 name.c_str(), g.nx, g.ny, g.nz, g.spacing, gf.band_rho_min,
                 gf.band_rho_max, gf.cells_per_member_floor, gf.cell_size_mm,
                 gf.printability_floor_mm, gf.cell_size_floored ? 1 : 0,
                 gf.region_voxels, gf.latticed_voxels, gf.solid_fallback_voxels,
                 gf.rho_min_used, gf.rho_max_used, gf.min_strut_diameter_mm,
                 gf.max_strut_diameter_mm,
                 finite_or(gf.min_member_width_mm, "inf").c_str(),
                 finite_or(gf.min_cells_per_member, "inf").c_str(),
                 gf.region_ungradeable ? 1 : 0);
}

}  // namespace

int main() {
  const char* dir = std::getenv("TOPOPT_LATTICE_CSV_DIR");
  if (dir) {
    std::string p = std::string(dir) + "/grading_bracket.csv";
    g_csv = std::fopen(p.c_str(), "w");
    if (g_csv)
      std::fprintf(g_csv,
                   "name,nx,ny,nz,h_mm,band_rho_min,band_rho_max,cpm_floor,cell_mm,"
                   "floor_mm,floored,region_vox,latticed_vox,solid_fallback_vox,"
                   "rho_min,rho_max,strut_min_mm,strut_max_mm,thin_member_mm,"
                   "min_cpm,region_ungradeable\n");
  }

  std::printf("Lattice grading law — L3/L4 evidence on the maintainer's L-bracket.\n"
              "0.4 mm nozzle (min extrudable strut width). Uniform cell per region.\n");

  std::vector<DirichletBC> bcs;
  std::vector<NodalLoad> loads;

  // (A) The maintainer's actual bracket: ~9.4 mm ribs (the project's recorded member
  // width) at 1 mm voxels. The honest result is BLOCKED-STOP — no printable cell holds
  // the floor in a rib this thin (floor 5 x printability-floor 2.52 mm = 12.6 mm needed,
  // > 9.4 mm), so the whole region stays SOLID (bar L4). This is PR 235's finding made
  // operational: cells cannot grow at all in this project's members.
  {
    VoxelGrid g = l_bracket(bcs, loads, /*arm*/ 20, /*span*/ 20, /*ny*/ 10, /*t*/ 9,
                            /*h*/ 1.0, /*fz*/ -30.0);
    run_specimen("A_maintainer_bracket_9p4mm", g, bcs, loads, /*cell*/ 2.0, 0.4);
  }

  // (B) A chunkier bracket — 16 mm-thick legs, 20 mm wide — where members DO clear
  // floor x floor-cell, so the law grades a real density + cell field and certifies it
  // (L3 + the end-to-end L2 proof). Surface voxels near the free faces are thinner and
  // fall back to solid, so both branches appear in one specimen.
  {
    VoxelGrid g = l_bracket(bcs, loads, /*arm*/ 30, /*span*/ 30, /*ny*/ 20, /*t*/ 16,
                            /*h*/ 1.0, /*fz*/ -20.0);
    run_specimen("B_thick_bracket", g, bcs, loads, /*cell*/ 2.0, 0.4);
  }

  // (C) The same chunky bracket with a LARGER requested cell (6 mm). Now floor x cell =
  // 30 mm exceeds even the 16-20 mm members, so more falls back to solid — showing the
  // cell-size/coverage trade the maintainer controls, all still certifiable.
  {
    VoxelGrid g = l_bracket(bcs, loads, /*arm*/ 30, /*span*/ 30, /*ny*/ 20, /*t*/ 16,
                            /*h*/ 1.0, /*fz*/ -20.0);
    run_specimen("C_thick_bracket_big_cell", g, bcs, loads, /*cell*/ 6.0, 0.4);
  }

  if (g_csv) std::fclose(g_csv);
  std::printf("\nDone.\n");
  return 0;
}
