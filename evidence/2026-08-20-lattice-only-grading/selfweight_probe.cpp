// MEASUREMENT-ONLY probe for task 2026-08-20-lattice-only-grading, §2(b) / bar R7.
//
// "The stress a lattice wall carries from its own mass is small — COMPUTE IT, do
// not assume it." This runs the part under GRAVITY ALONE, through core's own
// certification path (`analyze_fixed_design`), and reports the resulting von Mises
// distribution — then converts it to the number §2 actually needs: the stress in
// the STRUTS of a wall latticed at the band floor, and its utilisation.
//
// POSITIVE CONTROL, checked before any stress number is printed: the total applied
// body force must equal (voxel mass) x g. A self-weight probe whose load vector is
// wrong would report a beautifully precise, entirely fictional stress.
//
// Fixture: the lowest solid node layer, fully restrained — "the stand sits on the
// plate". Stated because it is a CHOICE: his declared anchor (face 18) is a raw
// B-rep id, and `fixture_faces` accepts only cylindrical selectors, so the
// declared anchor is not expressible in self-weight mode.

#include <algorithm>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <string>
#include <vector>

#include "topopt/analyze.hpp"
#include "topopt/fea.hpp"
#include "topopt/lattice.hpp"
#include "topopt/materials.hpp"
#include "topopt/part.hpp"
#include "topopt/simp.hpp"
#include "topopt/voxel.hpp"

using namespace topopt;

int main(int argc, char** argv) {
  if (argc < 4) {
    std::fprintf(stderr, "usage: %s <model.step> <resolution> <materials.json> [material]\n", argv[0]);
    return 2;
  }
  const std::string model = argv[1];
  const int resolution = std::atoi(argv[2]);
  const std::string materials_path = argv[3];
  const std::string mat_name = argc > 4 ? argv[4] : "PLA";

  const MaterialLibrary lib = load_materials_file(materials_path);
  const auto it = lib.find(mat_name);
  if (it == lib.end()) { std::fprintf(stderr, "no such material: %s\n", mat_name.c_str()); return 2; }
  const Material mat = it->second;

  const StepModel part = import_part_file(model);
  VoxelGrid grid = voxelize(part.mesh, resolution);
  std::vector<double> density(grid.voxel_count(), 0.0);
  std::size_t solid = 0;
  for (std::size_t i = 0; i < grid.tags.size(); ++i)
    if (grid.tags[i] != VoxelTag::Empty) { density[i] = 1.0; ++solid; }

  // ── consistent unit system: N, mm, MPa  =>  density in tonne/mm^3, g in mm/s^2
  const double rho_t_mm3 = mat.density_g_cm3 * 1e-9;
  const double g_mm_s2 = 9810.0;
  const std::vector<NodalLoad> loads =
      self_weight_loads(grid, rho_t_mm3, g_mm_s2, Vec3{0.0, 0.0, -1.0});

  const double mass_g = mat.density_g_cm3 * static_cast<double>(solid) *
                        grid.voxel_volume() * 1e-3;   // mm^3 * g/cm^3 -> g
  double applied = 0.0;
  for (const NodalLoad& l : loads) if (l.component == 2) applied += l.value;
  const double expect_n = -(mass_g * 1e-3) * 9.81;    // kg * m/s^2, downward
  std::printf("part: %d x %d x %d  spacing %.6f mm   solid voxels %zu   mass %.1f g\n",
              grid.nx, grid.ny, grid.nz, grid.spacing, solid, mass_g);
  std::printf("self-weight load: applied Fz %.6f N   expected %.6f N   rel err %.3e\n",
              applied, expect_n, std::fabs(applied - expect_n) / std::fabs(expect_n));
  if (std::fabs(applied - expect_n) / std::fabs(expect_n) > 1e-6) {
    std::fprintf(stderr, "REFUSING: the self-weight load vector does not equal the part's weight.\n");
    return 3;
  }

  // ── fixture: the lowest solid node layer ────────────────────────────────────
  int kmin = grid.nz;
  for (int k = 0; k < grid.nz; ++k) {
    bool any = false;
    for (int j = 0; j < grid.ny && !any; ++j)
      for (int i = 0; i < grid.nx && !any; ++i)
        if (grid.tags[grid.index(i, j, k)] != VoxelTag::Empty) any = true;
    if (any) { kmin = k; break; }
  }
  std::vector<DirichletBC> bcs;
  const int nxn = grid.nx + 1, nyn = grid.ny + 1;
  for (int j = 0; j <= grid.ny; ++j)
    for (int i = 0; i <= grid.nx; ++i) {
      const int node = (kmin * nyn + j) * nxn + i;
      for (int c = 0; c < 3; ++c) bcs.push_back(DirichletBC{node, c, 0.0});
    }
  std::printf("fixture: node layer k=%d, %zu constrained DOF\n", kmin, bcs.size());

  SimpParams sp;
  sp.youngs_modulus = mat.youngs_modulus_mpa;
  sp.poisson = mat.poisson;
  KnockdownSpec kd;
  const FixedDesignAnalysis a = analyze_fixed_design(
      grid, sp, density, bcs, loads, mat, Vec3{0.0, 0.0, 1.0}, 1e-8, 0,
      SolverKind::JacobiCG, 1.5, kd, /*load_path_ok=*/true,
      static_cast<double>(solid));

  if (a.non_convergent) { std::fprintf(stderr, "REFUSING: solve did not converge.\n"); return 3; }

  std::vector<double> vm;
  vm.reserve(solid);
  for (std::size_t e = 0; e < a.von_mises_field.size(); ++e)
    if (density[e] > 0.5) vm.push_back(a.von_mises_field[e]);
  std::sort(vm.begin(), vm.end());
  auto pc = [&](double q) { return vm[static_cast<std::size_t>(q * (vm.size() - 1))]; };

  const double allowable = mat.yield_strength_mpa / 1.5;
  std::printf("\n=== SELF-WEIGHT ONLY, solid part (MPa) ===\n");
  std::printf("  median   %.6g\n  p90      %.6g\n  p99      %.6g\n  PEAK     %.6g\n",
              pc(0.50), pc(0.90), pc(0.99), vm.back());
  std::printf("  margin (yield/peak) %.6g   required 1.5\n",
              mat.yield_strength_mpa / vm.back());
  std::printf("  peak utilisation vs allowable %.6g MPa : %.6g  (%.4f %%)\n",
              allowable, vm.back() / allowable, 100.0 * vm.back() / allowable);

  // ── what a LATTICED wall's struts actually carry ────────────────────────────
  // The homogenized (continuum) self-weight stress is ~unchanged by latticing to
  // relative density r: both the weight above a section and the section's load-
  // bearing area scale with r. The STRUT stress is the continuum stress divided
  // by the octet's strength knockdown, ~r^1.5 (Gibson-Ashby), which is the number
  // that must be compared against the allowable.
  const double r_lo = lattice_rho_min(LatticeTopology::Octet);
  std::printf("\n=== the same wall LATTICED at the band floor rho_min = %.5f ===\n", r_lo);
  for (double r : {r_lo, 0.10, 0.20}) {
    const double strut = vm.back() / std::pow(r, 1.5);
    std::printf("  rho %.5f : strut stress %.6g MPa   utilisation %.6g  (%.3f %%)\n",
                r, strut, strut / allowable, 100.0 * strut / allowable);
  }
  return 0;
}
