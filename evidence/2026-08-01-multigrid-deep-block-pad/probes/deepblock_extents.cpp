// P1 — re-run PR #151's case under today's latch + budget-300 (task:
// multigrid-deep-block-pad).
//
// PR #151's finding (handoff 122/127): the production res-128 design-box job
// solved on grid 232x64x216 (all-even, deep-blocked). #151 escalated the
// design-box pad to force a coarsenable 240x64x224 — MG then BUILT a hierarchy
// and STAGNATED on the high-contrast thin-part-in-empty-expanse + clearance
// field, falling back anyway, and paying the hierarchy build + the full
// (then-100) cycle budget on EVERY solve: forcing the build was measurably
// HARMFUL. That measurement predates kMgIterBudget 100 -> 300 (handoff 128)
// and the per-run stagnation latch (127 Amendment 2, kMgLatchThreshold=3).
//
// This probe re-creates handoff 125's occ x hole factorial — the reproduction
// of exactly that stagnation regime — at PR #151's own extents 232x64x216
// (which mg_pad_target pads to 240x64x224, the very grid #151 escalated to)
// and measures, per field:
//   pad OFF (today): hierarchy rejected, Jacobi-CG carries, wall recorded;
//   pad AUTO (the lifted gate): hierarchy builds on the padded index space —
//     either MG carries (win) or it stagnates (tax = build + 300 cycles).
// Then the LATCH TAX block: consecutive solves on the worst stagnating field,
// pad AUTO, to show the latch stops paying for doomed builds after 3 solves.
//
// Geometry (125 §1b): the part is a slab spanning the full x axis, its y/z
// extents scaled by `occ` (centered); the rest of the box is Empty design-box
// expanse. The clearance hole is a REMOVED-ELEMENT cylinder along y through
// the slab (the FrozenVoid -> Empty mapping of minimize_plastic). The active
// field is uniform gray rho=0.5 -> E = 0.125*E0 (125 §1b: geometry, not
// contrast, drives the stagnation).
#include "topopt/coarsen.hpp"
#include "topopt/fea.hpp"
#include "topopt/voxel.hpp"

#include <chrono>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <vector>

using namespace topopt;

namespace {

struct Case {
  const char* name;
  double occ;    // slab y/z extents as a fraction of the box
  double hole;   // cylinder radius as a fraction of the slab z half-extent (0 = none)
};

VoxelGrid make_field(int ex, int ey, int ez, double occ, double hole,
                     std::vector<double>& youngs, std::vector<DirichletBC>& bcs,
                     std::vector<NodalLoad>& loads) {
  VoxelGrid g;
  g.nx = ex; g.ny = ey; g.nz = ez;
  g.spacing = 1.7053;
  g.origin = Vec3{0, 0, 0};
  g.tags.assign(static_cast<std::size_t>(ex) * ey * ez, VoxelTag::Empty);

  const int sy = std::max(2, static_cast<int>(ey * occ));
  const int sz = std::max(2, static_cast<int>(ez * occ));
  const int y0 = (ey - sy) / 2, z0 = (ez - sz) / 2;
  // Clearance cylinder along y, centered in the slab's x/z cross-section.
  const double cx = ex / 2.0, cz = z0 + sz / 2.0;
  const double r = hole > 0.0 ? hole * (sz / 2.0) : -1.0;

  const double e_gray = 0.125 * 3500.0;  // rho=0.5, p=3, E0=3500
  youngs.assign(g.voxel_count(), 0.0);
  for (int k = z0; k < z0 + sz; ++k)
    for (int j = y0; j < y0 + sy; ++j)
      for (int i = 0; i < ex; ++i) {
        if (r > 0.0) {
          const double dx = i + 0.5 - cx, dz = k + 0.5 - cz;
          if (dx * dx + dz * dz <= r * r) continue;  // removed element (hole)
        }
        g.tags[g.index(i, j, k)] = VoxelTag::Interior;
        youngs[g.index(i, j, k)] = e_gray;
      }

  // Clamp every node on the x=0 plane of the slab; load the far x end in -z.
  bcs.clear();
  loads.clear();
  for (int c = z0; c <= z0 + sz; ++c)
    for (int b = y0; b <= y0 + sy; ++b) {
      const int n0 = fea_node_index(g, 0, b, c);
      for (int k = 0; k < 3; ++k) bcs.push_back({n0, k, 0.0});
      loads.push_back({fea_node_index(g, ex, b, c), 2, -1.0e-2});
    }
  return g;
}

long long solids(const VoxelGrid& g) {
  long long n = 0;
  for (auto t : g.tags) n += (t == VoxelTag::Interior) ? 1 : 0;
  return n;
}

}  // namespace

int main(int argc, char** argv) {
  const int ex = argc > 1 ? std::atoi(argv[1]) : 232;
  const int ey = argc > 2 ? std::atoi(argv[2]) : 64;
  const int ez = argc > 3 ? std::atoi(argv[3]) : 216;
  const double tol = 1e-6;

  int px = 0, py = 0, pz = 0;
  const int L = mg_pad_target(ex, ey, ez, px, py, pz);
  std::printf("box %dx%dx%d: coarsenable=%d pad_target=%dx%dx%d depth=%d\n",
              ex, ey, ez, mg_grid_coarsenable(ex, ey, ez) ? 1 : 0, px, py, pz, L);

  const Case cases[] = {
      {"occ1.0_nohole", 1.0, 0.0},  {"occ1.0_hole0.4", 1.0, 0.4},
      {"occ0.7_hole0.4", 0.7, 0.4}, {"occ0.5_hole0.4", 0.5, 0.4},
      {"occ0.4_nohole", 0.4, 0.0},  {"occ0.4_hole0.4", 0.4, 0.4},
  };

  std::printf("%-16s %9s | %s\n", "case", "nsolid",
              "pad=0: hier mg cyc it wall | pad=1: hier mg cyc it lvl wall");
  for (const Case& c : cases) {
    std::vector<double> ey_field;
    std::vector<DirichletBC> bcs;
    std::vector<NodalLoad> loads;
    const VoxelGrid g = make_field(ex, ey, ez, c.occ, c.hole, ey_field, bcs, loads);
    std::printf("%-16s %9lld |", c.name, solids(g));
    std::fflush(stdout);
    for (int pad : {0, 1}) {
      fea_set_mg_parity_pad_mode(pad);
      fea_matfree_reset_mg_stagnation_latch();
      CgInfo info;
      const auto t0 = std::chrono::steady_clock::now();
      fea_solve_mgcg_matfree(g, ey_field, 0.33, bcs, loads, tol, 0, &info);
      const double wall =
          std::chrono::duration<double>(std::chrono::steady_clock::now() - t0)
              .count();
      if (pad == 0)
        std::printf(" hier=%d mg=%d cyc=%3d it=%5d %7.1fs |",
                    info.hier_built ? 1 : 0, info.used_multigrid ? 1 : 0,
                    info.mg_cycles_attempted, info.iterations, wall);
      else
        std::printf(" hier=%d mg=%d cyc=%3d it=%5d lvl=%d %7.1fs\n",
                    info.hier_built ? 1 : 0, info.used_multigrid ? 1 : 0,
                    info.mg_cycles_attempted, info.iterations, info.mg_levels,
                    wall);
      std::fflush(stdout);
    }
  }

  // LATCH TAX — the worst case FOR THE PAD specifically: a field where the
  // deep-block pad ENGAGES (dense active set, over the cap at the walk stop)
  // AND the padded hierarchy stagnates. The occ0.4+hole thin-ligament field
  // does not qualify: its active set is sparse enough that the UNPADDED build
  // already succeeds today (the actual-count gate leaves it alone). A
  // 1e-9-contrast checkerboard on a solid deep-blocked 60^3 (60 -> 30 -> 15,
  // bound 12288 > cap; pads to 64^3) stagnates the V-cycle (the
  // test_coarsen_rule (5) fixture regime at twice the size). One run, pad
  // AUTO: solves 1..3 pay build + budget then fall back; solves 4+ skip the
  // build (latched). The pad=0 reference is the same field solved once with
  // the pad off (today: straight Jacobi, no build).
  {
    const int n = 60;
    VoxelGrid g;
    g.nx = n; g.ny = n; g.nz = n;
    g.spacing = 1.0;
    g.origin = Vec3{0, 0, 0};
    g.tags.assign(static_cast<std::size_t>(n) * n * n, VoxelTag::Interior);
    std::vector<DirichletBC> bcs;
    std::vector<NodalLoad> loads;
    for (int c = 0; c <= n; ++c)
      for (int b = 0; b <= n; ++b) {
        const int n0 = fea_node_index(g, 0, b, c);
        for (int k = 0; k < 3; ++k) bcs.push_back({n0, k, 0.0});
        loads.push_back({fea_node_index(g, n, b, c), 1, -1.0});
      }
    std::vector<double> ey_field(g.voxel_count());
    for (int k = 0; k < n; ++k)
      for (int j = 0; j < n; ++j)
        for (int i = 0; i < n; ++i)
          ey_field[g.index(i, j, k)] = (((i + j + k) & 1) ? 1e-9 : 1.0) * 1000.0;

    fea_set_mg_parity_pad_mode(0);
    fea_matfree_reset_mg_stagnation_latch();
    {
      CgInfo info;
      const auto t0 = std::chrono::steady_clock::now();
      fea_solve_mgcg_matfree(g, ey_field, 0.33, bcs, loads, tol, 0, &info);
      const double wall =
          std::chrono::duration<double>(std::chrono::steady_clock::now() - t0)
              .count();
      std::printf("latch-tax checker 60^3 pad=0 reference: hier=%d mg=%d "
                  "it=%5d %7.1fs\n",
                  info.hier_built ? 1 : 0, info.used_multigrid ? 1 : 0,
                  info.iterations, wall);
      std::fflush(stdout);
    }
    fea_set_mg_parity_pad_mode(1);
    fea_matfree_reset_mg_stagnation_latch();
    std::printf("latch-tax checker 60^3 pad=1, 5 consecutive solves:\n");
    for (int s = 0; s < 5; ++s) {
      CgInfo info;
      const auto t0 = std::chrono::steady_clock::now();
      fea_solve_mgcg_matfree(g, ey_field, 0.33, bcs, loads, tol, 0, &info);
      const double wall =
          std::chrono::duration<double>(std::chrono::steady_clock::now() - t0)
              .count();
      std::printf("  solve %d: hier=%d mg=%d cyc=%3d it=%5d %7.1fs latched=%d\n",
                  s + 1, info.hier_built ? 1 : 0, info.used_multigrid ? 1 : 0,
                  info.mg_cycles_attempted, info.iterations, wall,
                  fea_matfree_mg_stagnation_latched() ? 1 : 0);
      std::fflush(stdout);
    }
  }
  return 0;
}
