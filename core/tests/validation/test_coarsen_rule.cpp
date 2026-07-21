// Coarsenability rule + adaptive design-box padding (handoff:
// multigrid-coarsenability-padding). The geometric-multigrid solver rejects a
// hierarchy whose coarsest level exceeds kMgCoarseDofCap and silently falls back
// to Jacobi-CG (thousands of iterations instead of ~10). A fixed multiple-of-8
// pad guarantees only 3 coarsenings, enough at res ~64 but NOT at res ~128 with a
// design box: there the coarsest of 3 levels still holds tens of thousands of
// DOFs, so multigrid fell back on every iteration of a real 128^3 run.
//
// expand_design_domain now sizes the pad from topopt/coarsen.hpp — the SAME rule
// the solver enforces — so the pad is always sufficient. This test proves:
//   (1) THE RULE: mg_grid_coarsenable / required_coarsen_align agree with the
//       solver's actual behaviour, and the align GROWS above 8 only when 8 is
//       insufficient (byte-identical dims otherwise);
//   (2) BYTE-IDENTITY: extra padding (align-8 vs align-16 on a case coarsenable
//       at both) does not change the design SPACE, the solved field, the achieved
//       volume fraction, or the design bytes (the 079 precedent);
//   (3) THE FLIP: a large design-box grid that a fixed-8 pad leaves NON-
//       coarsenable is padded to a coarsenable grid, and the matrix-free
//       multigrid solver ENGAGES (used_multigrid == true) on the ~1e-9-contrast
//       field instead of falling back.

#include "topopt/coarsen.hpp"
#include "topopt/fea.hpp"
#include "topopt/materials.hpp"
#include "topopt/pipeline.hpp"
#include "topopt/settings.hpp"
#include "topopt/simp.hpp"
#include "topopt/voxel.hpp"

#include <cmath>
#include <cstddef>
#include <cstdio>
#include <vector>

using topopt::CgInfo;
using topopt::DesignBox;
using topopt::DesignDomain;
using topopt::DirichletBC;
using topopt::MaskValue;
using topopt::NodalLoad;
using topopt::SimpOptimizeResult;
using topopt::SimpOptions;
using topopt::SimpParams;
using topopt::SolverKind;
using topopt::Vec3;
using topopt::VoxelGrid;
using topopt::VoxelTag;

static int g_failures = 0;
static int g_checks = 0;

#define CHECK(cond, msg)                                           \
  do {                                                             \
    ++g_checks;                                                    \
    if (!(cond)) {                                                 \
      ++g_failures;                                                \
      std::fprintf(stderr, "FAIL (line %d): %s\n", __LINE__, msg); \
    }                                                              \
  } while (0)

namespace {

VoxelGrid solid_block(int nx, int ny, int nz) {
  VoxelGrid g;
  g.nx = nx; g.ny = ny; g.nz = nz;
  g.spacing = 1.0;
  g.origin = Vec3{0, 0, 0};
  g.tags.assign(static_cast<std::size_t>(nx) * ny * nz, VoxelTag::Interior);
  return g;
}

// Clamp the part k=0 face, load its k=nz top face in -z, remapped onto `d`.
void remapped_bcs_loads(const VoxelGrid& part, const DesignDomain& d,
                        std::vector<DirichletBC>& bcs,
                        std::vector<NodalLoad>& loads) {
  bcs.clear();
  loads.clear();
  auto pnode = [&](int a, int b, int c) {
    return topopt::fea_node_index(part, a, b, c);
  };
  for (int b = 0; b <= part.ny; ++b)
    for (int a = 0; a <= part.nx; ++a) {
      const int rn = topopt::remap_node_to_domain(part, d, pnode(a, b, 0));
      bcs.push_back({rn, 0, 0.0});
      bcs.push_back({rn, 1, 0.0});
      bcs.push_back({rn, 2, 0.0});
    }
  for (int b = 0; b <= part.ny; ++b)
    for (int a = 0; a <= part.nx; ++a)
      loads.push_back(
          {topopt::remap_node_to_domain(part, d, pnode(a, b, part.nz)), 2, -1.0e-2});
}

// Count the design-space voxels by mask, over the SOLID (non-Empty) voxels only.
// The mask defaults to Active everywhere, so the high-side Empty padding carries
// mask==Active but is ignored by the optimizer (tag==Empty -> no element, no DOF);
// counting only solid voxels isolates the true design space, which the padding
// must not change.
void mask_histogram(const DesignDomain& d, int& active, int& frozen_solid,
                    int& frozen_void) {
  active = frozen_solid = frozen_void = 0;
  const VoxelGrid& g = d.grid;
  for (int k = 0; k < g.nz; ++k)
    for (int j = 0; j < g.ny; ++j)
      for (int i = 0; i < g.nx; ++i) {
        if (!g.solid(i, j, k)) continue;  // Empty padding / out-of-box
        const MaskValue m = d.mask[g.index(i, j, k)];
        if (m == MaskValue::Active) ++active;
        else if (m == MaskValue::FrozenSolid) ++frozen_solid;
        else if (m == MaskValue::FrozenVoid) ++frozen_void;
      }
}

}  // namespace

int main() {
  // ---------------------------------------------------------------------------
  // (1) THE RULE — the predicate matches the solver's coarsest-DOF cap, and the
  // required alignment grows past 8 only when 8 is insufficient.
  // ---------------------------------------------------------------------------
  using topopt::mg_grid_coarsenable;
  using topopt::required_coarsen_align;
  using topopt::round_up_to;

  // res ~64 regime: coarsens fine at 8 (the 079 baseline).
  CHECK(mg_grid_coarsenable(96, 80, 96), "96x80x96 is coarsenable (res~64)");
  // res ~128 regime: a multiple of 8 that is NOT deeply 2-divisible on one axis
  // (104 = 8*13) leaves the coarsest of 3 levels over the DOF cap -> NOT
  // coarsenable. This is the exact class of the maintainer's 128^3 box run.
  CHECK(!mg_grid_coarsenable(104, 104, 104),
        "104^3 is NOT coarsenable at its own extents (coarsest > DOF cap)");
  CHECK(!mg_grid_coarsenable(184, 104, 128),
        "a res-128 box (184x104x128, y=104 depth-3 limiter) is NOT coarsenable");
  // An odd axis never coarsens at all.
  CHECK(!mg_grid_coarsenable(41, 40, 40), "an odd axis is never coarsenable");
  // Bumping the limiter axis to a deeper power-of-two multiple fixes it.
  CHECK(mg_grid_coarsenable(112, 112, 112), "112^3 (align-16) is coarsenable");
  CHECK(mg_grid_coarsenable(192, 112, 128),
        "192x112x128 (the align-16 pad of 184x104x128) is coarsenable");

  // required_coarsen_align: floor 8, grows only when needed.
  CHECK(required_coarsen_align(90, 78, 91, 8) == 8,
        "079 case (90x78x91) needs only align-8");
  CHECK(required_coarsen_align(104, 104, 104, 8) == 16,
        "104^3 needs align-16 (align-8 leaves coarsest over cap)");
  CHECK(required_coarsen_align(183, 100, 125, 8) == 16,
        "handoff-106 box (183x100x125) needs align-16");
  CHECK(required_coarsen_align(235, 128, 160, 8) == 8,
        "a deeply-2-divisible res-128 box already coarsens at align-8 (no over-pad)");
  // floor <= 1 disables rounding (legacy byte-identical path).
  CHECK(required_coarsen_align(90, 78, 91, 1) == 1, "floor 1 disables rounding");
  // The chosen align always yields a coarsenable padded grid.
  for (const int L : {104, 128, 183, 200, 235, 256}) {
    const int a = required_coarsen_align(L, L / 2 + 3, L - 7, 8);
    CHECK(mg_grid_coarsenable(round_up_to(L, a), round_up_to(L / 2 + 3, a),
                              round_up_to(L - 7, a)),
          "required_coarsen_align always returns a coarsenable alignment");
  }

  // ---------------------------------------------------------------------------
  // (2) BYTE-IDENTITY — the extra padding of a deeper alignment does not change
  // the design space, the solved field, the achieved vf, or the design bytes.
  // Small grid coarsenable at BOTH align-8 and align-16 (so both solve with MG /
  // JacobiCG identically); align chosen so 8 and 16 give DIFFERENT dims.
  // ---------------------------------------------------------------------------
  const VoxelGrid part = solid_block(8, 8, 8);
  DesignBox box;
  box.min = Vec3{-0.5, -0.5, -0.5};   // no low pad (offset 0)
  box.max = Vec3{16.5, 16.5, 16.5};   // grow to raw 17 -> align8=24, align16=32

  const DesignDomain d8 =
      topopt::expand_design_domain(part, box, {}, /*freeze_part=*/false, 8);
  const DesignDomain d16 =
      topopt::expand_design_domain(part, box, {}, /*freeze_part=*/false, 16);

  std::printf("[coarsen] d8 = %dx%dx%d  d16 = %dx%dx%d\n", d8.grid.nx, d8.grid.ny,
              d8.grid.nz, d16.grid.nx, d16.grid.ny, d16.grid.nz);

  // The alignments genuinely differ (the bump is exercised, not a no-op), the
  // deeper pad only GROWS the grid, and the part offset is untouched.
  CHECK(d8.grid.nx % 8 == 0 && d16.grid.nx % 16 == 0,
        "d8 dims are mult-of-8, d16 dims are mult-of-16");
  CHECK(d16.grid.nx > d8.grid.nx && d16.grid.ny > d8.grid.ny &&
            d16.grid.nz > d8.grid.nz,
        "the deeper alignment strictly grows the grid (bump exercised)");
  CHECK(d8.offset_i == d16.offset_i && d8.offset_j == d16.offset_j &&
            d8.offset_k == d16.offset_k,
        "the deeper pad leaves the part offset unchanged (high-side only)");

  // DESIGN SPACE is identical: the same count of Active design voxels and
  // FrozenSolid part voxels; the deeper pad only ADDS Empty (no-DOF) voxels.
  int a8, fs8, fv8, a16, fs16, fv16;
  mask_histogram(d8, a8, fs8, fv8);
  mask_histogram(d16, a16, fs16, fv16);
  CHECK(a8 == a16 && fs8 == fs16 && fv8 == fv16,
        "the design space (Active/FrozenSolid/FrozenVoid counts) is IDENTICAL");
  CHECK(d16.grid.voxel_count() > d8.grid.voxel_count(),
        "the deeper grid has more voxels (all the extra are Empty)");

  // Optimize both with the deterministic JacobiCG path and identical settings,
  // and compare the achieved vf and the design bytes over the COMMON region.
  SimpParams params;
  params.youngs_modulus = 2000.0;
  params.poisson = 0.30;
  params.penalty = 3.0;

  std::vector<DirichletBC> b8, b16;
  std::vector<NodalLoad> l8, l16;
  remapped_bcs_loads(part, d8, b8, l8);
  remapped_bcs_loads(part, d16, b16, l16);

  SimpOptions opt;
  opt.volume_fraction = 0.5;
  opt.filter_radius = 1.5;
  opt.move = 0.2;
  opt.max_iterations = 12;
  opt.change_tol = 0.0;      // run the full 12 iterations on both
  opt.cg_tolerance = 1e-10;
  opt.solver = SolverKind::JacobiCG;

  const SimpOptimizeResult r8 =
      topopt::simp_optimize(d8.grid, params, b8, l8, opt, d8.mask);
  const SimpOptimizeResult r16 =
      topopt::simp_optimize(d16.grid, params, b16, l16, opt, d16.mask);

  const double dvf = std::abs(r8.volume_fraction - r16.volume_fraction);
  // Compare physical_density voxel-for-voxel over the region present in BOTH
  // grids (indices < the smaller grid's extent on each axis). The design/part
  // voxels all live here; the differing high-side padding is Empty in both.
  double max_drho = 0.0;
  for (int k = 0; k < d8.grid.nz; ++k)
    for (int j = 0; j < d8.grid.ny; ++j)
      for (int i = 0; i < d8.grid.nx; ++i) {
        const double a = r8.physical_density[d8.grid.index(i, j, k)];
        const double b = r16.physical_density[d16.grid.index(i, j, k)];
        max_drho = std::max(max_drho, std::abs(a - b));
      }
  std::printf("[coarsen] byte-identity: |dvf|=%.3e  max|drho|=%.3e  "
              "(compliance %.10e vs %.10e)\n",
              dvf, max_drho, r8.compliance, r16.compliance);
  CHECK(r8.volume_fraction > 0.0 && r16.volume_fraction > 0.0,
        "both optimizes produced a positive achieved volume fraction");
  // Identical to solver tolerance (079 precedent: the reduced systems are the
  // same active DOFs / same K / same loads; only the DOF numbering differs by the
  // grid stride, so sums reassociate at the ULP level).
  CHECK(dvf < 1e-9, "achieved volume fraction is IDENTICAL across alignments");
  CHECK(max_drho < 1e-6, "design bytes are IDENTICAL across alignments (079)");

  // ---------------------------------------------------------------------------
  // (3) THE FLIP — a large design-box grid a fixed-8 pad would leave NON-
  // coarsenable is padded (via the same seam) to a coarsenable grid, and the
  // matrix-free multigrid ENGAGES on the ~1e-9-contrast field.
  // ---------------------------------------------------------------------------
  const VoxelGrid big_part = solid_block(100, 100, 100);
  DesignBox big_box;
  big_box.min = Vec3{-0.5, -0.5, -0.5};
  big_box.max = Vec3{103.5, 103.5, 103.5};  // raw 104 -> fixed-8 stays 104

  // A fixed multiple-of-8 pad would leave 104^3, which the solver CANNOT coarsen.
  CHECK(!mg_grid_coarsenable(104, 104, 104),
        "the fixed-8 pad (104^3) is NOT coarsenable — the silent-fallback bug");

  const DesignDomain big =
      topopt::expand_design_domain(big_part, big_box, {}, /*freeze_part=*/false, 8);
  std::printf("[coarsen] large box: fixed-8 -> 104^3 (fallback); adaptive -> "
              "%dx%dx%d\n", big.grid.nx, big.grid.ny, big.grid.nz);
  CHECK(mg_grid_coarsenable(big.grid.nx, big.grid.ny, big.grid.nz),
        "the adaptive pad makes the large grid coarsenable");

  // Solve the real ~1e-9-contrast field on the adaptive grid: multigrid ENGAGES.
  const double rho_min = 1e-3;  // rho_min^p = 1e-9 with p=3
  std::vector<double> ey(big.grid.voxel_count(), 0.0);
  for (int k = 0; k < big.grid.nz; ++k)
    for (int j = 0; j < big.grid.ny; ++j)
      for (int i = 0; i < big.grid.nx; ++i) {
        const std::size_t e = big.grid.index(i, j, k);
        if (!big.grid.solid(i, j, k)) continue;
        const double rho =
            (big.mask[e] == MaskValue::FrozenSolid) ? 1.0 : rho_min;
        ey[e] = std::pow(rho, params.penalty) * params.youngs_modulus;
      }
  std::vector<DirichletBC> bb;
  std::vector<NodalLoad> bl;
  remapped_bcs_loads(big_part, big, bb, bl);

  CgInfo big_info;
  const topopt::FeaSolution sol = topopt::fea_solve_mgcg_matfree(
      big.grid, ey, params.poisson, bb, bl, 1e-6, 0, &big_info);
  std::printf("[coarsen] adaptive-grid solve: used_mg=%d levels=%d iters=%d conv=%d\n",
              big_info.used_multigrid, big_info.mg_levels, big_info.iterations,
              big_info.converged);
  CHECK(big_info.used_multigrid,
        "THE FLIP: multigrid ENGAGES on the adaptively-padded large grid");
  CHECK(big_info.converged, "the multigrid solve converged");
  CHECK(big_info.iterations < 100,
        "multigrid converges in far fewer iterations than the Jacobi fallback");
  CHECK(sol.u.size() ==
            static_cast<std::size_t>(3) * topopt::fea_node_count(big.grid),
        "solution is sized to the adaptive grid");

  // ---------------------------------------------------------------------------
  // (4) LOUD-FALLBACK REPORTING — minimize_plastic aggregates the run's actual
  // multigrid engagement into MinimizePlasticResult::used_multigrid / mg_levels
  // (what run_info.json cg_multigrid and the CLI warning report). A coarsenable
  // grid engages MG; a non-coarsenable grid falls back on every solve and reports
  // it — no design box needed (the no-box self-weight path also carries the rule).
  // ---------------------------------------------------------------------------
  using topopt::Material;
  using topopt::MinimizePlasticOptions;
  using topopt::MinimizePlasticResult;
  using topopt::SettingsRules;

  Material mat;
  mat.youngs_modulus_mpa = 3500.0;
  mat.yield_strength_mpa = 0.02;
  mat.density_g_cm3 = 1.24;
  mat.z_knockdown = 0.55;
  mat.poisson = 0.33;
  mat.family = "fdm";
  // A single unbounded FDM band so recommend_settings matches any margin (this
  // test exercises the solver report, not the settings heuristic).
  SettingsRules rules;
  topopt::FdmBand band;
  band.unbounded = true;
  band.walls = 3;
  band.top_layers = 4;
  band.bottom_layers = 4;
  band.infill_percent = 20;
  band.infill_pattern = "grid";
  rules.fdm_bands.push_back(band);

  auto run_self_weight = [&](int n) {
    const VoxelGrid g = solid_block(n, n, n);
    const std::vector<int> fix = topopt::fea_tagged_nodes(g, VoxelTag::Fixture);
    // Clamp the z=0 face (no Fixture tags on this synthetic block).
    std::vector<DirichletBC> bcs;
    const int nnx = g.nx + 1, nny = g.ny + 1;
    for (int b = 0; b < nny; ++b)
      for (int a = 0; a < nnx; ++a) {
        const int node = (0 * nny + b) * nnx + a;
        for (int c = 0; c < 3; ++c) bcs.push_back({node, c, 0.0});
      }
    (void)fix;
    MinimizePlasticOptions o;
    o.volume_fraction_ladder = {0.6};
    o.margin_stop = 0.0;  // accept the single rung regardless of margin
    o.gravity = 1.0e6;
    o.gravity_direction = Vec3{0, 0, -1};
    o.simp.solver = SolverKind::MultigridCG_Matfree;
    o.simp.max_iterations = 24;
    o.simp.change_tol = 0.0;
    return topopt::minimize_plastic(g, mat, "PLA_test", bcs, rules, o);
  };

  // 32^3 coarsens (down to a 5^3-node coarsest under the DOF cap) -> MG engages.
  CHECK(mg_grid_coarsenable(32, 32, 32), "32^3 is coarsenable");
  const MinimizePlasticResult rc = run_self_weight(32);
  std::printf("[coarsen] self-weight 32^3: used_multigrid=%d mg_levels=%d\n",
              rc.used_multigrid, rc.mg_levels);
  CHECK(rc.used_multigrid,
        "REPORT: a coarsenable run reports used_multigrid=true");
  CHECK(rc.mg_levels >= 2, "REPORT: mg_levels is the observed hierarchy depth");

  // 30^3 is odd after one halving and the coarsest exceeds the cap -> MG can NEVER
  // build; every solve falls back, and the run reports it (the honesty guarantee).
  CHECK(!mg_grid_coarsenable(30, 30, 30), "30^3 is NOT coarsenable");
  const MinimizePlasticResult rf = run_self_weight(30);
  std::printf("[coarsen] self-weight 30^3: used_multigrid=%d mg_levels=%d\n",
              rf.used_multigrid, rf.mg_levels);
  CHECK(!rf.used_multigrid,
        "REPORT: a non-coarsenable run reports used_multigrid=false (loud fallback)");
  CHECK(rf.mg_levels == 0, "REPORT: mg_levels is 0 when MG never engaged");

  if (g_failures == 0)
    std::printf("coarsen_rule: all %d checks passed\n", g_checks);
  else
    std::fprintf(stderr, "coarsen_rule: %d/%d checks FAILED\n", g_failures,
                 g_checks);
  return g_failures == 0 ? 0 : 1;
}
