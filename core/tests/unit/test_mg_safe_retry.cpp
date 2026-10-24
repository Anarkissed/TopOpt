// TRIPWIRE for the SAFE-SMOOTHER RETRY (thin-wall solver cure S3 + S5 gate +
// arm G; see g_mg_safe_retry in src/fea/multigrid.cpp).
//
// The shipped V-cycle smooths with damped Jacobi at omega = 0.6, which is safe
// only while lambda_max(D^-1 A) <= 2/omega = 3.33. A hex8 at nu = 0.38 already
// exceeds that inside ONE element (~7.3), so on the maintainer's Carriage Arms
// the cycle was indefinite and the residual grew to 30 over the budget. The
// retry runs only after the shipped MG-CG has stalled. This file proves:
//
//   S3   lambda_max(D_l1^-1 A) <= 1 on every smoothed level of a heterogeneous
//        hierarchy, and the l1 V-cycle is positive definite (D4: Rayleigh(BA) in
//        (0, 2), rho_A(I - BA) < 1) — RED CONTROL: the shipped omega on the same
//        hierarchy has omega * lambda_max > 2.
//   S5   a solve the shipped path converges is BIT-IDENTICAL with the retry on
//        and off, and the retry never engages on it.
//   G    on a field of floating specks in 1e-9 filler, the census finds exactly
//        the planted specks (keeping anchored, loaded, full-modulus and big
//        islands), the cap refuses a checkerboard, and — RED CONTROL — the gated
//        l1 solve WITHOUT the drop does not converge while WITH it it does, to
//        the same compliance as the exact Jacobi fallback.
//   latch a latched run goes straight to the safe path.
//
// Same self-contained CHECK harness as the other unit tests.

#include "topopt/fea.hpp"
#include "topopt/voxel.hpp"

#include "fea/fea_matfree.hpp"

#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <vector>

using topopt::CgInfo;
using topopt::DirichletBC;
using topopt::FeaSolution;
using topopt::NodalLoad;
using topopt::Vec3;
using topopt::VoxelGrid;
using topopt::VoxelTag;

namespace {

int g_failures = 0;

void check(bool ok, const char* what) {
  if (!ok) {
    std::printf("FAIL: %s\n", what);
    ++g_failures;
  } else {
    std::printf("ok:   %s\n", what);
  }
}

VoxelGrid make_grid(int nx, int ny, int nz) {
  VoxelGrid g;
  g.nx = nx;
  g.ny = ny;
  g.nz = nz;
  g.spacing = 1.0;
  g.origin = Vec3{0, 0, 0};
  g.tags.assign(static_cast<std::size_t>(nx) * ny * nz, VoxelTag::Interior);
  return g;
}

void clamp_x0(const VoxelGrid& g, std::vector<DirichletBC>& bcs) {
  bcs.clear();
  for (int c = 0; c <= g.nz; ++c)
    for (int b = 0; b <= g.ny; ++b) {
      const int nd = topopt::fea_node_index(g, 0, b, c);
      for (int k = 0; k < 3; ++k) bcs.push_back({nd, k, 0.0});
    }
}

double dot_load(const FeaSolution& u, const std::vector<NodalLoad>& loads) {
  double s = 0.0;
  for (const NodalLoad& l : loads) s += l.value * u.at(l.node, l.component);
  return s;
}

bool bit_identical(const FeaSolution& a, const FeaSolution& b) {
  return a.u.size() == b.u.size() &&
         std::memcmp(a.u.data(), b.u.data(), a.u.size() * sizeof(double)) == 0;
}

// The arm-G fixture: a 4x4 solid beam (E = 1) along x through the middle of a
// 1e-9 filler box, clamped at x = 0 and loaded at its tip, with single-voxel
// grey specks (E = 0.5) planted on a lattice that keeps every speck at least
// one voxel away from the beam and from each other.
struct SpeckField {
  VoxelGrid g;
  std::vector<double> ey;
  std::vector<DirichletBC> bcs;
  std::vector<NodalLoad> loads;
  int specks = 0;
};

bool in_beam(int j, int k) { return j >= 6 && j < 10 && k >= 6 && k < 10; }

SpeckField make_speck_field(bool with_specks) {
  SpeckField F;
  F.g = make_grid(32, 16, 16);
  const double E0 = 1000.0;
  F.ey.assign(F.g.voxel_count(), 1e-9 * E0);
  for (int k = 0; k < F.g.nz; ++k)
    for (int j = 0; j < F.g.ny; ++j)
      for (int i = 0; i < F.g.nx; ++i) {
        const std::size_t e = F.g.index(i, j, k);
        if (in_beam(j, k)) {
          F.ey[e] = E0;
        } else if (with_specks && i >= 2 && (i % 4) == 2 && (j % 4) == 1 &&
                   (k % 4) == 1 && !(j >= 4 && j < 12 && k >= 4 && k < 12)) {
          F.ey[e] = 0.5 * E0;
          ++F.specks;
        }
      }
  clamp_x0(F.g, F.bcs);
  for (int c = 6; c <= 10; ++c)
    for (int b = 6; b <= 10; ++b)
      F.loads.push_back({topopt::fea_node_index(F.g, F.g.nx, b, c), 2, -1.0});
  return F;
}

}  // namespace

int main() {
  const double nu = 0.38;  // PA12-CF, the material of the stalled job

  // ---------------------------------------------------------------------------
  // S3: smoother safety on a heterogeneous hierarchy (+ red control).
  // ---------------------------------------------------------------------------
  {
    VoxelGrid g = make_grid(16, 16, 16);
    std::vector<double> ey(g.voxel_count());
    std::uint32_t s = 12345u;
    for (double& v : ey) {
      s = s * 1664525u + 1013904223u;
      const int dec = static_cast<int>((s >> 8) % 7u);  // 1e0 .. 1e-6
      v = 1000.0 * std::pow(10.0, -dec);
    }
    std::vector<DirichletBC> bcs;
    clamp_x0(g, bcs);
    std::vector<NodalLoad> loads;
    for (int b = 0; b <= g.ny; ++b)
      loads.push_back({topopt::fea_node_index(g, g.nx, b, 0), 2, -1.0});
    const auto P = topopt::fea_detail::mg_smoother_probe(g, nu, bcs, loads, ey,
                                                         200, 40);
    check(P.built && P.levels >= 3, "S3: heterogeneous hierarchy builds (>= 3 levels)");
    bool l1_ok = !P.lambda_l1.empty();
    std::printf("      lambda_max(D^-1 A):   ");
    for (double v : P.lambda_jacobi) std::printf(" %.4f", v);
    std::printf("\n      lambda_max(D_l1^-1 A):");
    for (double v : P.lambda_l1) {
      std::printf(" %.4f", v);
      l1_ok = l1_ok && v <= 1.0 + 1e-9 && v > 0.0;
    }
    std::printf("\n      V-cycle shipped: rho=%.4g rayleigh=%.4g ; l1: rho=%.4g rayleigh=%.4g\n",
                P.rho_shipped, P.rayleigh_shipped, P.rho_l1, P.rayleigh_l1);
    check(l1_ok, "S3: lambda_max(D_l1^-1 A) <= 1 on every smoothed level");
    bool red = !P.lambda_jacobi.empty();
    for (double v : P.lambda_jacobi) red = red && 0.6 * v > 2.0;
    check(red, "S3 RED CONTROL: shipped omega=0.6 has omega*lambda_max > 2 on every level");
    check(P.rayleigh_l1 > 0.0 && P.rayleigh_l1 < 2.0 && P.rho_l1 < 1.0,
          "S3/D4: the l1 V-cycle is positive definite and contracts");
    check(P.rayleigh_shipped < 0.0 || P.rho_shipped > 1.0,
          "D4 RED CONTROL: the shipped V-cycle is indefinite / divergent here");
  }

  // ---------------------------------------------------------------------------
  // S5: bit-identity of a solve the shipped path converges.
  // ---------------------------------------------------------------------------
  {
    SpeckField F = make_speck_field(false);
    // Make it healthy: fill the filler with solid.
    for (double& v : F.ey) v = 1000.0;
    topopt::fea_matfree_reset_mg_stagnation_latch();
    topopt::fea_matfree_set_mg_safe_retry(true);
    CgInfo on;
    FeaSolution a;
    {
      topopt::FeaIslandDropPermit permit;
      a = topopt::fea_solve_mgcg_matfree(F.g, F.ey, nu, F.bcs, F.loads, 1e-8, 0, &on);
    }
    const long long eng = topopt::fea_matfree_mg_safe_engagements();
    topopt::fea_matfree_reset_mg_stagnation_latch();
    topopt::fea_matfree_set_mg_safe_retry(false);
    CgInfo off;
    const FeaSolution b =
        topopt::fea_solve_mgcg_matfree(F.g, F.ey, nu, F.bcs, F.loads, 1e-8, 0, &off);
    topopt::fea_matfree_set_mg_safe_retry(true);
    check(on.used_multigrid && on.converged && eng == 0,
          "S5: a healthy solve converges on the shipped path; the retry never engages");
    check(bit_identical(a, b) && on.iterations == off.iterations,
          "S5: retry ON is BIT-IDENTICAL to retry OFF on a converging solve");
    check(topopt::fea_matfree_last_dropped_islands().empty(),
          "S5: nothing is reported dropped on a converging solve");
    // S7: the once-per-run lambda log ran on solve `a` (first after a reset)
    // and not on `c` (same run, already logged). It must be invisible: same
    // field bit-for-bit, same iteration AND matvec counts.
    CgInfo again;
    const FeaSolution c =
        topopt::fea_solve_mgcg_matfree(F.g, F.ey, nu, F.bcs, F.loads, 1e-8, 0, &again);
    check(bit_identical(a, c) && on.iterations == again.iterations &&
              on.matvecs == again.matvecs,
          "S7: the shipped-path lambda log changes nothing (field, iterations, matvecs)");
  }

  // ---------------------------------------------------------------------------
  // G: the island census and its keep rules.
  // ---------------------------------------------------------------------------
  {
    SpeckField F = make_speck_field(true);
    auto C = topopt::fea_detail::mg_island_census(F.g, F.ey, F.bcs, F.loads);
    std::printf("      census: pieces=%d unanchored=%d droppable=%d (%lld vox) "
                "kept_frozen=%d kept_big=%d capped=%d specks planted=%d\n",
                C.pieces, C.unanchored, C.droppable, C.droppable_voxels,
                C.kept_frozen, C.kept_big, C.capped ? 1 : 0, F.specks);
    check(C.droppable == F.specks && C.droppable_voxels == F.specks && !C.capped,
          "G: the census finds exactly the planted specks");
    check(C.pieces == F.specks + 1, "G: the beam is the one anchored piece");

    // Keep rules: a speck at full modulus (frozen proxy) is kept; a speck on a
    // loaded node is anchored; a 4x4x2 = 32-voxel blob is kept as too big.
    SpeckField K = F;
    const std::size_t e_frozen = K.g.index(2, 1, 1);
    K.ey[e_frozen] = 1000.0;
    const std::size_t e_loaded = K.g.index(6, 1, 1);
    K.loads.push_back({topopt::fea_node_index(K.g, 6, 1, 1), 0, 1e-3});
    for (int k = 12; k < 14; ++k)
      for (int j = 12; j < 16; ++j)
        for (int i = 20; i < 24; ++i) K.ey[K.g.index(i, j, k)] = 500.0;
    // A speck that only EDGE-touches the beam (a hinge) is part of that body.
    const std::size_t e_hinge = K.g.index(20, 5, 5);
    K.ey[e_hinge] = 500.0;
    auto CK = topopt::fea_detail::mg_island_census(K.g, K.ey, K.bcs, K.loads);
    bool none_kept_dropped = true;
    for (int e : CK.drop)
      if (static_cast<std::size_t>(e) == e_frozen ||
          static_cast<std::size_t>(e) == e_loaded ||
          static_cast<std::size_t>(e) == e_hinge ||
          K.ey[static_cast<std::size_t>(e)] >= 1000.0)
        none_kept_dropped = false;
    check(CK.kept_frozen >= 1 && CK.kept_big >= 1 && CK.kept_hinged >= 1 &&
              none_kept_dropped,
          "G: frozen (full-modulus), loaded, hinged and big islands are never dropped");

    // With the run's frozen mask registered, the mask decides (not the modulus):
    // a full-modulus DESIGN speck is droppable, a masked grey speck is kept.
    {
      std::vector<char> keep(K.g.voxel_count(), 0);
      const std::size_t e_masked = K.g.index(10, 1, 1);
      keep[e_masked] = 1;
      topopt::FeaIslandKeepMask scope(&keep);
      auto CM = topopt::fea_detail::mg_island_census(K.g, K.ey, K.bcs, K.loads);
      bool masked_kept = true, full_dropped = false;
      for (int e : CM.drop) {
        if (static_cast<std::size_t>(e) == e_masked) masked_kept = false;
        if (static_cast<std::size_t>(e) == e_frozen) full_dropped = true;
      }
      check(masked_kept && full_dropped && CM.kept_frozen == 1,
            "G: a registered frozen mask keeps exactly its islands");
    }
    // A speck whose 26-neighbourhood holds a CLEARANCE voxel (FrozenVoid in the
    // mask, Empty in the analysis grid) is kept too.
    {
      SpeckField C2 = F;
      std::vector<char> keep(C2.g.voxel_count(), 0);
      const std::size_t e_speck = C2.g.index(14, 1, 1);
      const std::size_t e_clear = C2.g.index(15, 2, 1);  // edge-neighbour
      C2.g.tags[e_clear] = VoxelTag::Empty;
      keep[e_clear] = 1;
      topopt::FeaIslandKeepMask scope(&keep);
      auto CC2 = topopt::fea_detail::mg_island_census(C2.g, C2.ey, C2.bcs, C2.loads);
      bool kept = true;
      for (int e : CC2.drop)
        if (static_cast<std::size_t>(e) == e_speck) kept = false;
      check(kept && CC2.kept_hinged == 1 && CC2.droppable == F.specks - 1,
            "G: a speck touching a clearance (FrozenVoid) voxel is never dropped");
    }

    // Cap: isolated single-voxel specks on a stride-2 lattice (no shared node
    // between any two) are 1/8 of the elements -> the cap refuses them all.
    VoxelGrid cg = make_grid(16, 16, 16);
    std::vector<double> cey(cg.voxel_count());
    for (int k = 0; k < 16; ++k)
      for (int j = 0; j < 16; ++j)
        for (int i = 0; i < 16; ++i)
          cey[cg.index(i, j, k)] =
              ((i % 2 == 0 && j % 2 == 0 && k % 2 == 0) ? 0.5 : 1e-9) * 1000.0;
    cey[cg.index(0, 0, 0)] = 1000.0;  // Emax sits on an anchored voxel, so the
                                      // specks are not full-modulus (not frozen)
    std::vector<DirichletBC> cb;
    clamp_x0(cg, cb);
    auto CC = topopt::fea_detail::mg_island_census(cg, cey, cb, {});
    std::printf("      stride-2 specks: droppable=%d (%lld vox of %lld elements) capped=%d\n",
                CC.droppable, CC.droppable_voxels, CC.elements, CC.capped ? 1 : 0);
    check(CC.capped && CC.drop.empty() && CC.droppable > 0,
          "G: the cap refuses a field whose islands exceed 5 % of the elements");
  }

  // ---------------------------------------------------------------------------
  // G: the gated solve, with and without the drop (RED CONTROL), vs the exact
  // Jacobi fallback.
  // ---------------------------------------------------------------------------
  {
    SpeckField F = make_speck_field(true);
    const double tol = 1e-8;

    // Reference: shipped path with the retry OFF -> Jacobi fallback (exact).
    topopt::fea_matfree_reset_mg_stagnation_latch();
    topopt::fea_matfree_set_mg_safe_retry(false);
    CgInfo ref_info;
    const FeaSolution ref =
        topopt::fea_solve_mgcg_matfree(F.g, F.ey, nu, F.bcs, F.loads, tol, 0, &ref_info);
    topopt::fea_matfree_set_mg_safe_retry(true);
    std::printf("      shipped: used_mg=%d hier=%d cycles=%d (Jacobi its=%d res=%.3e)\n",
                ref_info.used_multigrid ? 1 : 0, ref_info.hier_built ? 1 : 0,
                ref_info.mg_cycles_attempted, ref_info.iterations, ref_info.residual);
    check(ref_info.hier_built && !ref_info.used_multigrid && ref_info.converged,
          "G: the shipped MG stalls on the speck field (Jacobi fallback converges)");

    // RED CONTROL: gated l1 retry WITHOUT the drop (no permit).
    topopt::fea_matfree_reset_mg_stagnation_latch();
    CgInfo nod;
    const FeaSolution u_nod =
        topopt::fea_solve_mgcg_matfree(F.g, F.ey, nu, F.bcs, F.loads, tol, 0, &nod);
    const long long eng_nod = topopt::fea_matfree_mg_safe_engagements();
    const long long car_nod = topopt::fea_matfree_mg_safe_carries();
    std::printf("      l1 retry, no drop: used_mg=%d safe cycles=%d engaged=%lld carried=%lld\n",
                nod.used_multigrid ? 1 : 0, nod.iterations, eng_nod, car_nod);
    check(eng_nod == 1 && nod.converged, "G: the gated l1 retry engages without the drop");
    check(topopt::fea_matfree_last_dropped_islands().empty(),
          "G: nothing is dropped without a permit");

    // With the drop.
    topopt::fea_matfree_reset_mg_stagnation_latch();
    CgInfo dr;
    FeaSolution u_dr;
    {
      topopt::FeaIslandDropPermit permit;
      u_dr = topopt::fea_solve_mgcg_matfree(F.g, F.ey, nu, F.bcs, F.loads, tol, 0, &dr);
    }
    const auto& dropped = topopt::fea_matfree_last_dropped_islands();
    const double c_ref = dot_load(ref, F.loads), c_dr = dot_load(u_dr, F.loads);
    std::printf("      l1 retry + drop: used_mg=%d safe cycles=%d dropped=%zu "
                "compliance %.10g vs Jacobi %.10g (rel %.2e)\n",
                dr.used_multigrid ? 1 : 0, dr.iterations, dropped.size(), c_dr, c_ref,
                std::fabs(c_dr - c_ref) / std::fabs(c_ref));
    check(dr.used_multigrid && dr.converged &&
              topopt::fea_matfree_mg_safe_carries() == 1,
          "G: with the specks dropped the gated l1 MG-PCG converges");
    // RED CONTROL: the specks' near-rigid modes are what the l1 cycle grinds on.
    // Without the drop it either never carries or needs >= 5x the cycles.
    check(!nod.used_multigrid || nod.iterations >= 5 * dr.iterations,
          "G RED CONTROL: without the drop the gated l1 MG needs >= 5x the cycles "
          "(speck tail)");
    check(static_cast<int>(dropped.size()) == F.specks &&
              topopt::fea_matfree_last_dropped_floor_youngs() == 1e-9 * 1000.0,
          "G: exactly the specks were solved at the floor modulus");
    check(std::fabs(c_dr - c_ref) <= 1e-6 * std::fabs(c_ref),
          "G: the dropped solve's compliance matches the exact solve (<= 1e-6)");

    // A forbid overrides any permit.
    topopt::fea_matfree_reset_mg_stagnation_latch();
    {
      topopt::FeaIslandDropPermit permit;
      topopt::FeaIslandDropForbid forbid;
      CgInfo fi;
      topopt::fea_solve_mgcg_matfree(F.g, F.ey, nu, F.bcs, F.loads, tol, 0, &fi);
      check(topopt::fea_matfree_last_dropped_islands().empty(),
            "G: a FeaIslandDropForbid overrides a permit (certification)");
    }

    // LATCH: three shipped stalls latch the shipped attempt off; the fourth
    // solve goes straight to the safe path (no shipped cycles burned).
    topopt::fea_matfree_reset_mg_stagnation_latch();
    CgInfo last;
    {
      topopt::FeaIslandDropPermit permit;
      for (int s = 0; s < 4; ++s)
        topopt::fea_solve_mgcg_matfree(F.g, F.ey, nu, F.bcs, F.loads, tol, 0, &last);
    }
    check(topopt::fea_matfree_mg_stagnation_latched() && last.used_multigrid &&
              last.mg_cycles_attempted == last.iterations &&
              topopt::fea_matfree_mg_safe_carries() == 4,
          "latch: a latched run skips the shipped attempt and carries on the safe path");
    // Determinism: the latched safe solve reproduces the first safe solve.
    FeaSolution again;
    topopt::fea_matfree_reset_mg_stagnation_latch();
    {
      topopt::FeaIslandDropPermit permit;
      CgInfo ai;
      again = topopt::fea_solve_mgcg_matfree(F.g, F.ey, nu, F.bcs, F.loads, tol, 0, &ai);
    }
    check(bit_identical(again, u_dr), "determinism: the safe solve is bit-reproducible");
  }

  // ---------------------------------------------------------------------------
  // G: a SECOND, separate, anchored and loaded body survives the drop — even a
  // tiny one (6 voxels, under the 27-voxel size cap). This is the reviewer's
  // case of a split part (the second Carriage Arm carries its own anchors and
  // load): arm G only ever touches islands with NO anchor, NO load and NO
  // frozen voxel, so such a body is solved at its true modulus.
  // ---------------------------------------------------------------------------
  {
    SpeckField F = make_speck_field(true);
    std::vector<std::size_t> body;
    // A 6-voxel bar at j = 3, k = 15, i = 0..5: its nodes share none with a
    // speck (a speck touching a loaded node would itself count as anchored).
    {
      const int j = 3, k = 15;
      for (int i = 0; i < 6; ++i) {
          const std::size_t e = F.g.index(i, j, k);
          F.ey[e] = 1000.0;  // touches the clamped x = 0 face: anchored
          body.push_back(e);
      }
    }
    const std::size_t nload0 = F.loads.size();
    for (int c = 15; c <= 16; ++c)
      for (int b = 3; b <= 4; ++b)
        F.loads.push_back({topopt::fea_node_index(F.g, 6, b, c), 2, -0.05});
    auto C = topopt::fea_detail::mg_island_census(F.g, F.ey, F.bcs, F.loads);
    bool body_kept = true;
    for (int e : C.drop)
      for (std::size_t b : body)
        if (static_cast<std::size_t>(e) == b) body_kept = false;
    check(body_kept && C.droppable == F.specks && C.pieces == F.specks + 2,
          "G: a second anchored + loaded 6-voxel body is NOT an island (never dropped)");

    const double tol = 1e-8;
    topopt::fea_matfree_reset_mg_stagnation_latch();
    topopt::fea_matfree_set_mg_safe_retry(false);
    CgInfo ri;
    const FeaSolution ref =
        topopt::fea_solve_mgcg_matfree(F.g, F.ey, nu, F.bcs, F.loads, tol, 0, &ri);
    topopt::fea_matfree_set_mg_safe_retry(true);
    topopt::fea_matfree_reset_mg_stagnation_latch();
    CgInfo di;
    FeaSolution u;
    {
      topopt::FeaIslandDropPermit permit;
      u = topopt::fea_solve_mgcg_matfree(F.g, F.ey, nu, F.bcs, F.loads, tol, 0, &di);
    }
    // The second body's own load work, solved vs exact.
    double w_ref = 0.0, w_u = 0.0;
    for (std::size_t q = nload0; q < F.loads.size(); ++q) {
      w_ref += F.loads[q].value * ref.at(F.loads[q].node, F.loads[q].component);
      w_u += F.loads[q].value * u.at(F.loads[q].node, F.loads[q].component);
    }
    std::printf("      second body: load work %.10g (dropped solve) vs %.10g (exact), "
                "dropped %zu voxels, used_mg=%d\n",
                w_u, w_ref, topopt::fea_matfree_last_dropped_islands().size(),
                di.used_multigrid ? 1 : 0);
    check(di.used_multigrid &&
              static_cast<int>(topopt::fea_matfree_last_dropped_islands().size()) ==
                  F.specks &&
              std::fabs(w_u - w_ref) <= 1e-6 * std::fabs(w_ref),
          "G: the second body is solved at its true stiffness (load work matches exact)");
  }

  if (g_failures == 0) std::printf("mg_safe_retry: all checks passed\n");
  else std::printf("mg_safe_retry: %d check(s) FAILED\n", g_failures);
  return g_failures == 0 ? 0 : 1;
}
