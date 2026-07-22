// Coarsenability rule + design-box padding + multigrid stagnation guard
// (handoff 122/127). The geometric-multigrid solver rejects a hierarchy whose
// coarsest level exceeds kMgCoarseDofCap and falls back to Jacobi-CG. PR #151
// tried to fix a production res-128 fallback by ESCALATING the design-box pad to
// force coarsenability; a real run disproved the premise (its grid was already
// coarsenable, yet MG stagnated and fell back anyway). The walk-back removed the
// escalation and added a stagnation fast-fail + latch. This test proves:
//   (1) THE RULE: mg_grid_coarsenable matches the solver's coarsest-DOF cap (the
//       rule is TRUE and retained; it just no longer sizes the pad);
//   (2) BYTE-IDENTITY: extra padding (a deeper alignment floor) does not change
//       the design SPACE, the solved field, the achieved volume fraction, or the
//       design bytes (the 079 precedent);
//   (4) LOUD-FALLBACK REPORTING: minimize_plastic reports used_multigrid honestly
//       (true on a coarsenable run, false when MG never engaged);
//   (5) STAGNATION LATCH: a synthetic stagnating field makes MG fall back on every
//       solve and, after a few in a row, latches MG off for the run (skipping the
//       doomed hierarchy build); a healthy solve is unaffected (bit-identical) —
//       the latch is inert unless MG actually stagnates.

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
using topopt::fea_matfree_mg_stagnation_latched;
using topopt::fea_matfree_reset_mg_stagnation_latch;
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
  // (1) THE RULE — mg_grid_coarsenable matches the solver's coarsest-DOF cap.
  // The rule is TRUE and retained (documentation + future gate); PR #151's error
  // was ACTING on it to escalate the design-box pad, which the walk-back removed.
  // ---------------------------------------------------------------------------
  using topopt::mg_grid_coarsenable;

  // A grid that coarsens under the DOF cap at plain align-8.
  CHECK(mg_grid_coarsenable(96, 80, 96), "96x80x96 is coarsenable");
  // A multiple of 8 that is NOT deeply 2-divisible on one axis (104 = 8*13)
  // leaves the coarsest of its 3 halvings over the DOF cap -> NOT coarsenable.
  CHECK(!mg_grid_coarsenable(104, 104, 104),
        "104^3 is NOT coarsenable at its own extents (coarsest > DOF cap)");
  CHECK(!mg_grid_coarsenable(184, 104, 128),
        "184x104x128 (y=104 depth-3 limiter) is NOT coarsenable");
  // An odd axis never coarsens at all.
  CHECK(!mg_grid_coarsenable(41, 40, 40), "an odd axis is never coarsenable");
  // The real production job: at the FIXED align-8 floor its grid is 232x64x216
  // (NOT coarsenable). PR #151's escalation grew it to 240x64x224 (coarsenable) —
  // where MG BUILT a hierarchy, then STAGNATED and fell back anyway. So neither
  // grid gets multigrid: the true failure is convergence, not coarsenability
  // (see part (5)), which is why the escalation was withdrawn.
  CHECK(!mg_grid_coarsenable(232, 64, 216),
        "232x64x216 (production grid at fixed align-8) is NOT coarsenable");
  CHECK(mg_grid_coarsenable(240, 64, 224),
        "240x64x224 (#151's escalated grid) IS coarsenable — yet MG stagnated there");
  CHECK(mg_grid_coarsenable(112, 112, 112), "112^3 is coarsenable");

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

  // ---------------------------------------------------------------------------
  // (5) STAGNATION LATCH (Amendment 2) — a high-contrast checkerboard field on a
  // COARSENABLE grid makes the matrix-free MG build a hierarchy then stagnate
  // (fall back to Jacobi). After kMgLatchThreshold consecutive stagnations the run
  // latches MG off — the doomed hierarchy build is skipped thereafter. A healthy
  // (solid) solve is unaffected — MG engages and the latch never arms — proving the
  // guard is inert unless MG actually stagnates.
  // ---------------------------------------------------------------------------
  {
    // Coarsenable, cheap, and the 1e-9 checkerboard stagnates past the MG budget.
    // n MATTERS: geometric MG degrades with grid size on this maximally-incoherent
    // field, so the fixture must be large enough to stagnate past kMgIterBudget.
    // At the handoff-128 budget of 300, a 16^3 checker CARRIES (converges in ~118
    // cycles — it was in the borderline band the raise exists to rescue) while 32^3
    // still stagnates (hits the 300-cycle budget, falls back). Use 32 so the latch
    // fixture keeps stagnating; bump it if the budget is raised again.
    const int n = 32;
    const VoxelGrid gg = solid_block(n, n, n);
    const int nnx = n + 1, nny = n + 1, nnz = n + 1;
    auto nid = [&](int a, int b, int c) { return (c * nny + b) * nnx + a; };
    std::vector<DirichletBC> sbcs;
    std::vector<NodalLoad> sloads;
    for (int c = 0; c < nnz; ++c)
      for (int b = 0; b < nny; ++b) {
        for (int k = 0; k < 3; ++k) sbcs.push_back({nid(0, b, c), k, 0.0});
        sloads.push_back({nid(n, b, c), 1, -1.0});
      }
    // A checkerboard 1e-9-contrast modulus (the MG-adversarial regime) and a
    // uniform-solid modulus (healthy) on the SAME grid/BCs/loads.
    std::vector<double> ey_checker(gg.voxel_count()), ey_solid(gg.voxel_count());
    for (int k = 0; k < n; ++k)
      for (int j = 0; j < n; ++j)
        for (int i = 0; i < n; ++i) {
          const std::size_t e = gg.index(i, j, k);
          ey_solid[e] = 1000.0;
          ey_checker[e] = (((i + j + k) & 1) ? 1e-9 : 1.0) * 1000.0;
        }
    auto solve = [&](const std::vector<double>& ey, CgInfo& info) {
      return topopt::fea_solve_mgcg_matfree(gg, ey, 0.3, sbcs, sloads, 1e-6, 0,
                                            &info);
    };

    CHECK(mg_grid_coarsenable(n, n, n), "the stagnation fixture grid is coarsenable");

    // Healthy baseline: MG engages, converges, and the latch never arms (inert).
    fea_matfree_reset_mg_stagnation_latch();
    CgInfo h0;
    solve(ey_solid, h0);
    CHECK(h0.used_multigrid && h0.converged,
          "healthy solid field: MG engages and converges");
    CHECK(!fea_matfree_mg_stagnation_latched(),
          "a converging solve never arms the latch (inert on healthy solves)");

    // Stagnating field: MG builds but never contracts -> fast-fail to Jacobi on
    // EVERY solve, and after kMgLatchThreshold in a row the run latches MG off.
    fea_matfree_reset_mg_stagnation_latch();
    for (int s = 0; s < 4; ++s) {
      CgInfo si;
      solve(ey_checker, si);
      CHECK(!si.used_multigrid,
            "stagnating field: MG falls back to Jacobi-CG every solve");
      CHECK(si.converged,
            "the Jacobi fallback still converges (correctness certificate intact)");
    }
    CHECK(fea_matfree_mg_stagnation_latched(),
          "after N consecutive stagnations the run latches MG off (skips the build)");

    // The latch does not leak past a run: a reset re-arms MG, and a healthy solve
    // engages it again. (The driver calls this reset at the start of every run.)
    fea_matfree_reset_mg_stagnation_latch();
    CgInfo h1;
    solve(ey_solid, h1);
    CHECK(h1.used_multigrid && !fea_matfree_mg_stagnation_latched(),
          "reset re-arms MG; the latch never leaks across runs");
    std::printf("[coarsen] stagnation guard: healthy used_mg=%d, checker used_mg=0, "
                "latched after 3 stagnations\n", h1.used_multigrid);
  }

  if (g_failures == 0)
    std::printf("coarsen_rule: all %d checks passed\n", g_checks);
  else
    std::fprintf(stderr, "coarsen_rule: %d/%d checks FAILED\n", g_failures,
                 g_checks);
  return g_failures == 0 ? 0 : 1;
}
