// M3.7 passive-regions test — the per-voxel design mask (Active / FrozenSolid /
// FrozenVoid) applied through the mask-aware SIMP path (make_density_filter mask
// overload + simp_optimize mask overload).
//
// The contract asserted here:
//   * FrozenVoid ("keep-out"): the channel voxels come out empty (physical
//     density 0) and the constrained optimum is stiffer-material-starved, i.e.
//     compliance is worse than the unconstrained optimum at the same fraction;
//   * FrozenSolid ("keep-in"): the region stays full material (physical density
//     1) even where the unconstrained optimizer would thin it away;
//   * Load/Fixture voxels are implicitly FrozenSolid, so a real optimizer output
//     passes the §7 V3 Load/Fixture retention gate (structural, not emergent);
//   * the mask-aware density filter does not bleed across a mask boundary
//     (frozen voxels are excluded from an Active voxel's neighbourhood), and the
//     all-Active mask reproduces the plain filter bit-for-bit.
//
// No third-party test framework (ARCHITECTURE §4); same self-contained CHECK
// harness as test_v3.cpp, public API only. Drives simp_optimize, so Eigen-gated.

#include "topopt/fea.hpp"
#include "topopt/mesh.hpp"
#include "topopt/simp.hpp"
#include "topopt/voxel.hpp"

#include <cmath>
#include <cstddef>
#include <cstdio>
#include <vector>

using topopt::DesignMask;
using topopt::DensityFilter;
using topopt::DirichletBC;
using topopt::make_active_mask;
using topopt::make_density_filter;
using topopt::MaskValue;
using topopt::NodalLoad;
using topopt::SimpOptimizeResult;
using topopt::SimpOptions;
using topopt::SimpParams;
using topopt::V3Report;
using topopt::Vec3;
using topopt::VoxelGrid;
using topopt::VoxelTag;

static int g_failures = 0;
static int g_checks = 0;

#define CHECK(cond, msg)                                            \
  do {                                                             \
    ++g_checks;                                                    \
    if (!(cond)) {                                                 \
      ++g_failures;                                                \
      std::fprintf(stderr, "FAIL (line %d): %s\n", __LINE__, msg); \
    }                                                              \
  } while (0)

namespace {

// A clamped-root, tip-loaded cantilever grid of all-Interior voxels (unit
// spacing) — the same setup test_v3 / test_gate_v2 use, minus voxel tags.
VoxelGrid cantilever_grid(int nx, int ny, int nz) {
  VoxelGrid g;
  g.nx = nx;
  g.ny = ny;
  g.nz = nz;
  g.spacing = 1.0;
  g.origin = Vec3{0.0, 0.0, 0.0};
  g.tags.assign(static_cast<std::size_t>(nx) * ny * nz, VoxelTag::Interior);
  return g;
}

// Clamp all 3 DOF on the x=0 node face; total Fz = -1 spread over the x=nx face.
void cantilever_bcs_loads(const VoxelGrid& g, std::vector<DirichletBC>& bcs,
                          std::vector<NodalLoad>& loads) {
  for (int c = 0; c <= g.nz; ++c)
    for (int b = 0; b <= g.ny; ++b) {
      const int n = topopt::fea_node_index(g, 0, b, c);
      bcs.push_back({n, 0, 0.0});
      bcs.push_back({n, 1, 0.0});
      bcs.push_back({n, 2, 0.0});
    }
  const double fz = -1.0 / static_cast<double>((g.ny + 1) * (g.nz + 1));
  for (int c = 0; c <= g.nz; ++c)
    for (int b = 0; b <= g.ny; ++b)
      loads.push_back({topopt::fea_node_index(g, g.nx, b, c), 2, fz});
}

SimpParams cantilever_params() {
  SimpParams p;
  p.youngs_modulus = 1.0;
  p.poisson = 0.3;
  p.penalty = 3.0;
  p.density_min = 0.001;
  return p;
}

SimpOptions cantilever_options() {
  SimpOptions opt;
  opt.volume_fraction = 0.5;
  opt.filter_radius = 1.5;
  opt.move = 0.2;
  opt.max_iterations = 40;
  opt.change_tol = 0.0;  // run the full cap on these oscillating discrete designs
  opt.cg_tolerance = 1e-8;
  return opt;
}

// True iff `idx` appears in filter row `e` (the neighbour list of voxel e).
bool filter_row_has(const DensityFilter& f, std::size_t e, std::size_t idx) {
  for (std::size_t p = f.row_start[e]; p < f.row_start[e + 1]; ++p)
    if (f.neighbor[p] == idx) return true;
  return false;
}

}  // namespace

int main() {
  const int nx = 24, ny = 8, nz = 8;
  const SimpParams p = cantilever_params();
  const SimpOptions opt = cantilever_options();

  // =========================================================================
  // Baseline: the unconstrained optimum on the plain cantilever (no mask).
  // =========================================================================
  VoxelGrid g = cantilever_grid(nx, ny, nz);
  std::vector<DirichletBC> bcs;
  std::vector<NodalLoad> loads;
  cantilever_bcs_loads(g, bcs, loads);
  const SimpOptimizeResult base = topopt::simp_optimize(g, p, bcs, loads, opt);

  // =========================================================================
  // 1. FrozenVoid ("keep-out") channel: an interior box is forced empty. The
  // optimizer must route around it, so the channel comes out void and the
  // constrained optimum is worse (higher compliance) than the unconstrained one.
  // =========================================================================
  {
    DesignMask mask = make_active_mask(g);
    std::vector<std::size_t> channel;
    for (int k = 2; k < 6; ++k)
      for (int j = 2; j < 6; ++j)
        for (int i = 8; i < 16; ++i) {
          const std::size_t e = g.index(i, j, k);
          mask[e] = MaskValue::FrozenVoid;
          channel.push_back(e);
        }
    const SimpOptimizeResult res = topopt::simp_optimize(g, p, bcs, loads, opt, mask);

    bool all_void = true;
    for (std::size_t e : channel)
      if (res.physical_density[e] > 1e-12) all_void = false;
    CHECK(all_void, "FrozenVoid: every keep-out voxel ends at physical density 0");

    // The V3 mesh of the constrained design has the channel hollowed out — it is
    // still a printable single watertight body around the void.
    const V3Report r = topopt::check_v3(g, res.physical_density, 0.5);
    CHECK(r.gate_watertight(), "FrozenVoid: constrained design is watertight");
    CHECK(r.gate_single_component(),
          "FrozenVoid: constrained design is a single component");

    CHECK(res.compliance > base.compliance,
          "FrozenVoid: forcing a keep-out channel worsens compliance");
    std::printf("[FrozenVoid] base c=%.4f constrained c=%.4f channel=%zu\n",
                base.compliance, res.compliance, channel.size());
  }

  // =========================================================================
  // 2. FrozenSolid ("keep-in"): a low-stress region the unconstrained optimizer
  // thins away is pinned to full material and comes out at physical density 1.
  // =========================================================================
  {
    DesignMask mask = make_active_mask(g);
    std::vector<std::size_t> keep;
    // A block near the tip-top surface — low stress in a tip-loaded cantilever,
    // so the unconstrained optimum drives it toward void there.
    for (int k = nz - 2; k < nz; ++k)
      for (int j = 3; j < 5; ++j)
        for (int i = 18; i < 22; ++i)
          keep.push_back(g.index(i, j, k));
    for (std::size_t e : keep) mask[e] = MaskValue::FrozenSolid;

    const SimpOptimizeResult res = topopt::simp_optimize(g, p, bcs, loads, opt, mask);

    bool all_solid = true;
    double base_max = 0.0;  // how solid the unconstrained optimum left this block
    for (std::size_t e : keep) {
      if (std::fabs(res.physical_density[e] - 1.0) > 1e-9) all_solid = false;
      base_max = std::max(base_max, base.physical_density[e]);
    }
    CHECK(all_solid, "FrozenSolid: every keep-in voxel ends at physical density 1");
    // Bite: the pin actually changed the outcome — the unconstrained optimum did
    // NOT keep this block full (its densest voxel there is below the 0.9 gate).
    CHECK(base_max < 0.9,
          "FrozenSolid: the unconstrained optimum thinned this block (pin bites)");
    std::printf("[FrozenSolid] keep=%zu unconstrained max rho here=%.4f\n",
                keep.size(), base_max);
  }

  // =========================================================================
  // 3. Load/Fixture implicitly FrozenSolid: on a tagged cantilever the mask-aware
  // optimizer retains every Load/Fixture voxel at density >= 0.9 even with an
  // all-Active caller mask — the §7 V3 retention gate is now structural.
  // =========================================================================
  {
    VoxelGrid gt = cantilever_grid(nx, ny, nz);
    for (int k = 0; k < nz; ++k)
      for (int j = 0; j < ny; ++j) {
        gt.set_tag(0, j, k, VoxelTag::Fixture);
        gt.set_tag(nx - 1, j, k, VoxelTag::Load);
      }
    std::vector<DirichletBC> tbcs;
    std::vector<NodalLoad> tloads;
    cantilever_bcs_loads(gt, tbcs, tloads);

    const DesignMask mask = make_active_mask(gt);  // caller froze nothing
    const SimpOptimizeResult res =
        topopt::simp_optimize(gt, p, tbcs, tloads, opt, mask);
    const V3Report r = topopt::check_v3(gt, res.physical_density, 0.5);

    CHECK(r.load_fixture_voxels == 2 * ny * nz,
          "Load/Fixture: all tagged voxels are scanned by V3");
    CHECK(r.gate_load_fixture_retained() && r.min_load_fixture_density >= 0.9,
          "Load/Fixture: implicit FrozenSolid retains every tagged voxel >= 0.9");
    CHECK(r.gate_watertight() && r.gate_single_component(),
          "Load/Fixture: retained design is still a watertight single component");
    std::printf("[Load/Fixture] retained=%d min=%.4f n=%d\n",
                static_cast<int>(r.gate_load_fixture_retained()),
                r.min_load_fixture_density, r.load_fixture_voxels);
  }

  // =========================================================================
  // 4. Mask-aware filter: no bleed across a mask boundary, and the all-Active
  // mask reproduces the plain filter bit-for-bit.
  // =========================================================================
  {
    // A 1D strip of 5 voxels: freeze the middle one. Its Active neighbours must
    // not see it (no averaging across the boundary), yet the plain (maskless)
    // filter does include it. Do it for both frozen kinds.
    for (MaskValue frozen : {MaskValue::FrozenVoid, MaskValue::FrozenSolid}) {
      VoxelGrid s = cantilever_grid(5, 1, 1);
      DesignMask m = make_active_mask(s);
      const std::size_t mid = s.index(2, 0, 0);
      const std::size_t left = s.index(1, 0, 0);
      const std::size_t right = s.index(3, 0, 0);
      m[mid] = frozen;
      const DensityFilter fm = make_density_filter(s, 1.5, m);
      const DensityFilter fplain = make_density_filter(s, 1.5);

      CHECK(!filter_row_has(fm, left, mid) && !filter_row_has(fm, right, mid),
            "filter: a frozen voxel is excluded from its Active neighbours' rows");
      CHECK(filter_row_has(fplain, left, mid) && filter_row_has(fplain, right, mid),
            "filter: the plain filter DOES include the middle voxel (bite)");
      CHECK(fm.weight_sum[left] < fplain.weight_sum[left],
            "filter: dropping the frozen neighbour lowers the Active row weight");
      // The frozen voxel itself is not a design voxel: empty row, zero weight.
      CHECK(fm.row_start[mid] == fm.row_start[mid + 1] &&
                fm.weight_sum[mid] == 0.0,
            "filter: a frozen voxel has an empty filter row");
    }

    // All-Active mask == plain filter, bit-for-bit (the plain overload delegates).
    VoxelGrid g2 = cantilever_grid(6, 4, 3);
    const DensityFilter fa = make_density_filter(g2, 1.5, make_active_mask(g2));
    const DensityFilter fp = make_density_filter(g2, 1.5);
    bool identical = fa.voxel_count == fp.voxel_count &&
                     fa.row_start == fp.row_start && fa.neighbor == fp.neighbor &&
                     fa.weight == fp.weight && fa.weight_sum == fp.weight_sum;
    CHECK(identical, "filter: all-Active mask reproduces the plain filter exactly");
  }

  // =========================================================================
  // 5. Argument validation on the mask overloads.
  // =========================================================================
  {
    bool threw = false;
    try {
      DesignMask bad(g.voxel_count() - 1, MaskValue::Active);
      topopt::simp_optimize(g, p, bcs, loads, opt, bad);
    } catch (const std::invalid_argument&) {
      threw = true;
    }
    CHECK(threw, "simp_optimize: a wrong-size mask throws invalid_argument");

    threw = false;
    try {
      DesignMask bad(g.voxel_count() + 3, MaskValue::Active);
      topopt::make_density_filter(g, 1.5, bad);
    } catch (const std::invalid_argument&) {
      threw = true;
    }
    CHECK(threw, "make_density_filter: a wrong-size mask throws invalid_argument");
  }

  if (g_failures == 0) {
    std::printf("passive regions (M3.7): all %d checks passed\n", g_checks);
    return 0;
  }
  std::fprintf(stderr, "passive regions (M3.7): %d/%d checks FAILED\n",
               g_failures, g_checks);
  return 1;
}
