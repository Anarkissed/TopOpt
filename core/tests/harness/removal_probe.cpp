// removal_probe.cpp — measurement harness (NOT a CI test) for the element-removal
// task. Reconstructs the real design-box case through the PRODUCTION
// expand_design_domain path (handoff 090), then answers STEP 0a with numbers:
//   * the ACTUAL initial density of the grow region under Option 2
//     (freeze_imported_part=false) — is it rho_min, or the rung's rescaled vf?
//   * how the REMOVABLE fraction (Active voxels with physical rho <= rho_t)
//     EVOLVES across a rung, at iterations 1/20/60/140, for rho_t in {1e-3,1e-2,
//     1e-1} — that curve IS the saving, and it also pins down WHEN peak memory
//     (which scales with the active-DOF count) actually occurs.
//
// Read-only: it drives simp_optimize (MMA updater = the production path, which
// SKIPS Heaviside — handoff 066) and inspects the per-iteration analysis density
// via the keyframe callback. The density trajectory is solver-independent physics
// (mma_probe.cpp); the curve uses the production matrix-free multigrid + 090 block
// cache on a smaller, proportionally-identical grid (JacobiCG does not converge on
// the full 2.29M-DOF ~1e-9-contrast system in tractable time).
//
// Build (standalone, not wired to CTest):
//   c++ -std=c++17 -O3 -I core/include core/tests/harness/removal_probe.cpp \
//       build-probe/libtopopt.a -pthread -o build-probe/removal_probe

#include <atomic>
#include <cmath>
#include <cstdio>
#include <string>
#include <vector>

#include "topopt/fea.hpp"
#include "topopt/pipeline.hpp"
#include "topopt/simp.hpp"
#include "topopt/voxel.hpp"

using namespace topopt;

namespace {

// An L-bracket part like the M7.dom growth gate, at unit spacing so the design
// box (world units) maps 1:1 to voxels. Fixture on the top of the vertical arm,
// Load on the end of the horizontal arm.
VoxelGrid l_bracket(std::vector<DirichletBC>& bcs, int arm, int span, int ny,
                    int t, double h) {
  VoxelGrid g;
  g.nx = span;
  g.ny = ny;
  g.nz = arm;
  g.spacing = h;
  g.origin = Vec3{0.0, 0.0, 0.0};
  g.tags.assign(static_cast<std::size_t>(span) * ny * arm, VoxelTag::Empty);
  for (int k = 0; k < arm; ++k)
    for (int j = 0; j < ny; ++j)
      for (int i = 0; i < span; ++i)
        if (i < t || k < t) g.set_tag(i, j, k, VoxelTag::Interior);
  for (int j = 0; j < ny; ++j)
    for (int i = 0; i < t; ++i) g.set_tag(i, j, arm - 1, VoxelTag::Fixture);
  for (int k = 0; k < t; ++k)
    for (int j = 0; j < ny; ++j) g.set_tag(span - 1, j, k, VoxelTag::Load);
  bcs.clear();
  for (int b = 0; b <= ny; ++b)
    for (int a = 0; a <= t; ++a) {
      const int node = fea_node_index(g, a, b, arm);
      bcs.push_back({node, 0, 0.0});
      bcs.push_back({node, 1, 0.0});
      bcs.push_back({node, 2, 0.0});
    }
  return g;
}

std::size_t count_mask(const DesignMask& m, const VoxelGrid& g, MaskValue v) {
  std::size_t n = 0;
  for (std::size_t idx = 0; idx < m.size(); ++idx)
    if (g.tags[idx] != VoxelTag::Empty && m[idx] == v) ++n;
  return n;
}

}  // namespace

int main(int argc, char** argv) {
  std::setvbuf(stdout, nullptr, _IOLBF, 0);  // line-buffered so a pipe shows progress
  const double h = 1.0;
  // Tuned so expand_design_domain (align-8) lands ~96x80x96 = 737,280 voxels,
  // matching 090's reconstruction of the maintainer's real padded grid.
  // Sized so part.solid_count() ~ 26,400 (090's real part = 4.1% of elements):
  // ny*t*(arm+span-t) = 24*10*(60+60-10) = 26,400.
  const int arm = 60, span = 60, ny = 24, t = 10;
  std::vector<DirichletBC> bcs;
  VoxelGrid part = l_bracket(bcs, arm, span, ny, t, h);

  DesignBox box;
  box.min = Vec3{0.0, 0.0, 0.0};
  box.max = Vec3{96.0, 80.0, 96.0};

  const DesignDomain domain =
      expand_design_domain(part, box, {}, /*freeze_part=*/false,
                           kDesignBoxCoarsenAlign);
  const VoxelGrid& G = domain.grid;
  const DesignMask& mask = domain.mask;

  const std::size_t nvox = G.voxel_count();
  const std::size_t nelem = G.solid_count();  // elements = non-Empty voxels
  const std::size_t n_active = count_mask(mask, G, MaskValue::Active);
  const std::size_t n_fsolid = count_mask(mask, G, MaskValue::FrozenSolid);
  const std::size_t n_fvoid = count_mask(mask, G, MaskValue::FrozenVoid);
  const double part_solid = static_cast<double>(part.solid_count());

  std::printf("=== RECONSTRUCTED DESIGN-BOX CASE (Option 2, freeze=false) ===\n");
  std::printf("part L-bracket: %dx%dx%d, solid voxels = %.0f\n", part.nx, part.ny,
              part.nz, part_solid);
  std::printf("expanded domain grid: %dx%dx%d = %zu voxels\n", G.nx, G.ny, G.nz,
              nvox);
  std::printf("elements (non-Empty)          : %zu\n", nelem);
  std::printf("  Active (grow region)        : %zu (%.1f%% of elements)\n",
              n_active, 100.0 * n_active / nelem);
  std::printf("  FrozenSolid (BC skin)       : %zu\n", n_fsolid);
  std::printf("  FrozenVoid                  : %zu\n", n_fvoid);
  std::printf("  Empty (align-8 padding, 0 el): %zu\n", nvox - nelem);
  std::printf("est. DOFs ~ 3*(nx+1)*(ny+1)*(nz+1) = %.0f\n",
              3.0 * (G.nx + 1) * (G.ny + 1) * (G.nz + 1));

  // Replicate minimize_plastic's part-relative frozen/active census exactly.
  double active_effective = 0.0, frozen_effective = 0.0;
  for (int k = 0; k < G.nz; ++k)
    for (int j = 0; j < G.ny; ++j)
      for (int i = 0; i < G.nx; ++i) {
        const std::size_t idx = G.index(i, j, k);
        const VoxelTag tg = G.tag(i, j, k);
        if (tg == VoxelTag::Load || tg == VoxelTag::Fixture ||
            mask[idx] == MaskValue::FrozenSolid) {
          frozen_effective += 1.0;
          continue;
        }
        if (mask[idx] != MaskValue::Active) continue;
        if (tg == VoxelTag::Empty) continue;
        active_effective += 1.0;
      }

  const double rho_min = 1e-3;
  std::printf("\n=== STEP 0a — INITIAL GROW-REGION DENSITY, per rung ===\n");
  std::printf("active_effective=%.0f frozen_effective=%.0f part_solid=%.0f\n",
              active_effective, frozen_effective, part_solid);
  std::printf("rho_min = %.0e\n", rho_min);
  const double ladder[3] = {0.7, 0.5, 0.3};
  for (double vf : ladder) {
    double sf = vf;
    if (active_effective > 0.0) {
      const double active_target = vf * part_solid - frozen_effective;
      sf = std::min(1.0, std::max(rho_min, active_target / active_effective));
    }
    std::printf("  rung vf=%.2f -> initial Active grey density = %.5f  (%s)\n",
                vf, sf,
                sf <= rho_min * 1.0000001 ? "== rho_min (floored)"
                                          : "grey, ABOVE rho_min");
  }

  if (argc > 1 && std::string(argv[1]) == "0a-only") return 0;

  // ==========================================================================
  // STEP 0a curve + peak-timing. The removable-fraction curve is scale-invariant
  // physics (the density TRAJECTORY, not the wall time — mma_probe.cpp), so it is
  // measured on a proportionally-identical, smaller domain (~32x24x32, part at the
  // same ~4% fraction, same rescaled grey ~0.011) with the production matrix-free
  // multigrid solver + 090 block cache. The 0a NUMBERS above are exact on the
  // real 96x80x96 grid. A JacobiCG run on the full 2.29M-DOF ~1e-9-contrast
  // system does not converge in tractable time (that is why 079 flipped to MG).
  // ==========================================================================
  fea_set_matfree_galerkin_block_cache(true);
  const int s_arm = 20, s_span = 20, s_ny = 8, s_t = 4;  // ~32x24x32 domain
  std::vector<DirichletBC> sbcs;
  VoxelGrid spart = l_bracket(sbcs, s_arm, s_span, s_ny, s_t, h);
  DesignBox sbox;
  sbox.min = Vec3{0.0, 0.0, 0.0};
  sbox.max = Vec3{32.0, 24.0, 32.0};
  const DesignDomain sdom = expand_design_domain(spart, sbox, {}, false,
                                                 kDesignBoxCoarsenAlign);
  const VoxelGrid& SG = sdom.grid;
  const DesignMask& smask = sdom.mask;
  const std::size_t s_nelem = SG.solid_count();
  std::size_t s_nactive = count_mask(smask, SG, MaskValue::Active);

  double s_active_eff = 0.0, s_frozen_eff = 0.0;
  for (std::size_t idx = 0; idx < smask.size(); ++idx) {
    const VoxelTag tg = SG.tags[idx];
    if (tg == VoxelTag::Load || tg == VoxelTag::Fixture ||
        smask[idx] == MaskValue::FrozenSolid) { s_frozen_eff += 1.0; continue; }
    if (smask[idx] != MaskValue::Active) continue;
    if (tg == VoxelTag::Empty) continue;
    s_active_eff += 1.0;
  }

  const double vf = 0.3;  // tightest rung -> most eventual void -> best case
  const double sf = std::min(1.0, std::max(rho_min,
      (vf * spart.solid_count() - s_frozen_eff) / s_active_eff));

  SimpParams params;
  params.youngs_modulus = 2000.0;
  params.poisson = 0.33;
  params.penalty = 3.0;
  params.density_min = rho_min;

  std::vector<DirichletBC> B;
  for (const DirichletBC& bc : sbcs)
    B.push_back({remap_node_to_domain(spart, sdom, bc.node), bc.component,
                 bc.value});
  const std::vector<NodalLoad> L =
      traction_loads(SG, VoxelTag::Load, Vec3{0.0, 0.0, -2.0e-4});

  SimpOptions opt;
  opt.updater = SimpUpdater::MMA;                    // production path (no Heaviside)
  opt.solver = SolverKind::MultigridCG_Matfree;      // production design-box solver
  opt.volume_fraction = sf;
  opt.filter_radius = 2.0;
  opt.move = 0.2;
  opt.max_iterations = 80;
  opt.change_tol = 0.0;                              // run the full budget
  opt.cg_tolerance = 1e-7;

  const double rt[3] = {1e-3, 1e-2, 1e-1};
  int iter = 0;
  std::printf("\n=== STEP 0a — REMOVABLE-FRACTION CURVE ===\n");
  std::printf("representative grid %dx%dx%d = %zu elems, Active=%zu, "
              "rung vf=%.2f, initial grey=%.5f\n",
              SG.nx, SG.ny, SG.nz, s_nelem, s_nactive, vf, sf);
  std::printf("removable = Active voxels with physical rho <= rho_t "
              "(peak memory ~ active-DOF count ~ (nelem - removable))\n");
  std::printf("%5s | %-22s | %-22s | %-22s\n", "iter", "rho_t=1e-3",
              "rho_t=1e-2", "rho_t=1e-1");
  std::printf("%5s | %9s %12s | %9s %12s | %9s %12s\n", "", "remov%",
              "act.elems", "remov%", "act.elems", "remov%", "act.elems");
  opt.keyframe_stride = 1;
  opt.keyframe = [&](const std::vector<double>& rho) {
    ++iter;
    // report every iteration (MMA plateaus early; keep the whole curve)
    char cols[3][48];
    for (int c = 0; c < 3; ++c) {
      std::size_t removable = 0;
      for (std::size_t idx = 0; idx < rho.size(); ++idx) {
        if (smask[idx] != MaskValue::Active) continue;
        if (SG.tags[idx] == VoxelTag::Empty) continue;
        if (rho[idx] <= rt[c]) ++removable;
      }
      std::snprintf(cols[c], sizeof(cols[c]), "%8.1f%% %12zu",
                    100.0 * removable / static_cast<double>(s_nactive),
                    s_nelem - removable);
    }
    std::printf("%5d | %-22s | %-22s | %-22s\n", iter, cols[0], cols[1], cols[2]);
  };

  SimpOptimizeResult res = simp_optimize(SG, params, B, L, opt, smask);
  std::printf("\nfinal: iters=%d compliance=%.6e converged=%d\n", res.iterations,
              res.compliance, res.converged ? 1 : 0);
  std::printf("CONVERGED-FIELD removable fraction (physical rho <= rho_t):\n");
  for (int c = 0; c < 3; ++c) {
    std::size_t removable = 0;
    for (std::size_t idx = 0; idx < res.physical_density.size(); ++idx) {
      if (smask[idx] != MaskValue::Active) continue;
      if (SG.tags[idx] == VoxelTag::Empty) continue;
      if (res.physical_density[idx] <= rt[c]) ++removable;
    }
    std::printf("  rho_t=%.0e : %6.1f%% removable  -> %zu active elems (of %zu)\n",
                rt[c], 100.0 * removable / static_cast<double>(s_nactive),
                s_nelem - removable, s_nelem);
  }
  fea_set_matfree_galerkin_block_cache(false);
  return 0;
}
