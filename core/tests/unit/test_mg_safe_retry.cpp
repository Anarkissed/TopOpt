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
//   G    THE CONNECTION RULE (ruling 2026-10-25): on a field of floating specks
//        in 1e-9 filler the census finds exactly the planted specks (FACE-connected
//        pieces touching no support or load: a frozen speck, a 32-voxel blob and
//        a speck hinged to the beam by an edge are loose, a loaded speck is not), there is
//        no cap (a stride-2 checkerboard is cleaned, with the majority warning),
//        and EVERY solve — no permit needed, a forbid changes nothing — solves the
//        specks at the floor: it converges on multigrid to the exact system's
//        compliance, where — RED CONTROL — the exact field needs >= 5x the MG
//        cycles. (The stall-dependent sections below run on the EXACT speck field
//        through the test-only switch, RuleOff.)
//   latch a latched run goes straight to the safe path.
//   B    a safe attempt that breaks down before its first update reports its
//        starting residual: not productive, seeds nothing, advances the latch.
//   A    the fallback's start is judged on the system it solves — one system
//        now: a capped retry's residual is the same number on both.
//   C    ... and better than a COLD start (in the fallback's own 2-norm and in
//        energy); a warm start worse than zero in both is not used either, so
//        a stopped retry can never leave the fallback worse off than cold.
//   W    the l1 retry itself starts from the better of the warm guess and
//        zero (same exact-system test), so a warm start far worse than zero
//        no longer stops the retry short of a convergence it reaches cold.
//   F    such a COLD-START retry gets a longer first progress window: from
//        zero its residual rises before it falls (the demo L-bracket's first
//        safe solve, a committed fixture).
//   L    the [mg-safe] stderr lines are bounded per run (first N, then one
//        summary per M attempts) and the bound changes no number.
//   D    the certified final compliance solves (simp_optimize, its masked /
//        SEMDOT overload, plsm_optimize) run under a forbid scope, the
//        trajectory solves under a permit — and since the connection rule every
//        one of them runs the loose-piece census all the same.
//
// Same self-contained CHECK harness as the other unit tests.

#include "topopt/fea.hpp"
#include "topopt/plsm.hpp"
#include "topopt/simp.hpp"
#include "topopt/voxel.hpp"

#include "fea/fea_matfree.hpp"

#include <cctype>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <fstream>
#include <numeric>
#include <sstream>
#include <string>
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

// THE CONNECTION RULE takes every speck of the speck field out of the system, so
// that field no longer stalls the shipped MG (it converges in ~96 cycles). The
// safe-retry / fallback machinery below (B, C, W, L, latch) is exercised on the
// EXACT speck field — the specks at their true modulus, the system every solve
// of it saw before the rule — through the test-only switch, scoped.
struct RuleOff {
  RuleOff() { topopt::fea_detail::mg_test_loose_rule(false); }
  ~RuleOff() { topopt::fea_detail::mg_test_loose_rule(true); }
  RuleOff(const RuleOff&) = delete;
  RuleOff& operator=(const RuleOff&) = delete;
};

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

// Relative TRUE residual ||f - K u|| / ||f|| over the free DOFs (fresh
// operator apply; not the CG recurrence's running residual).
double true_rel(const VoxelGrid& g, const std::vector<double>& ey,
                const std::vector<DirichletBC>& bcs,
                const std::vector<NodalLoad>& loads, const FeaSolution& u,
                double nu) {
  std::vector<double> ku = topopt::fea_matfree_apply(g, ey, nu, u.u);
  std::vector<double> f(ku.size(), 0.0);
  for (const NodalLoad& l : loads)
    f[static_cast<std::size_t>(3 * l.node + l.component)] += l.value;
  std::vector<char> fixed(ku.size(), 0);
  for (const DirichletBC& b : bcs)
    fixed[static_cast<std::size_t>(3 * b.node + b.component)] = 1;
  double rn = 0, bn = 0;
  for (std::size_t i = 0; i < ku.size(); ++i) {
    if (fixed[i]) continue;
    rn += (f[i] - ku[i]) * (f[i] - ku[i]);
    bn += f[i] * f[i];
  }
  return std::sqrt(rn / bn);
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
  // G: the census — THE CONNECTION RULE (ruling 2026-10-25; FACE connectivity,
  // ruling 2026-10-26). A piece is a face-connected component of the solid
  // voxels; it is LOOSE iff it touches no
  // Dirichlet / loaded node, whatever its size, frozen or not. (Before the rule:
  // 6-connected, <= 27 voxels, isolated, unfrozen, <= 5 % of the elements.)
  // ---------------------------------------------------------------------------
  {
    SpeckField F = make_speck_field(true);
    auto C = topopt::fea_detail::mg_island_census(F.g, F.ey, F.bcs, F.loads);
    std::printf("      census: pieces=%d loose=%d (%lld vox) frozen_loose=%d "
                "majority=%d specks planted=%d\n",
                C.pieces, C.unanchored, C.unanchored_voxels, C.frozen_loose,
                C.majority_loose ? 1 : 0, F.specks);
    check(C.droppable == F.specks && C.droppable_voxels == F.specks &&
              static_cast<int>(C.drop.size()) == F.specks,
          "G: the census finds exactly the planted specks");
    check(C.pieces == F.specks + 1, "G: the beam is the one anchored piece");

    // Connection rules: a speck at full modulus (frozen proxy) is LOOSE (and
    // counted frozen); a speck on a loaded node is anchored; a 4x4x2 = 32-voxel
    // blob is LOOSE (no size rule); a speck that only EDGE-touches the beam is a
    // hinge, carries no load, and is LOOSE too (the face rule).
    SpeckField K = F;
    const std::size_t e_frozen = K.g.index(2, 1, 1);
    K.ey[e_frozen] = 1000.0;
    const std::size_t e_loaded = K.g.index(6, 1, 1);
    K.loads.push_back({topopt::fea_node_index(K.g, 6, 1, 1), 0, 1e-3});
    std::vector<std::size_t> blob;
    for (int k = 12; k < 14; ++k)
      for (int j = 12; j < 16; ++j)
        for (int i = 20; i < 24; ++i) {
          K.ey[K.g.index(i, j, k)] = 500.0;
          blob.push_back(K.g.index(i, j, k));
        }
    const std::size_t e_hinge = K.g.index(20, 5, 5);
    K.ey[e_hinge] = 500.0;
    auto CK = topopt::fea_detail::mg_island_census(K.g, K.ey, K.bcs, K.loads);
    bool frozen_dropped = false, loaded_kept = true, hinge_dropped = false,
         beam_kept = true;
    std::size_t blob_dropped = 0;
    for (int e : CK.drop) {
      const std::size_t u = static_cast<std::size_t>(e);
      if (u == e_frozen) frozen_dropped = true;
      if (u == e_loaded) loaded_kept = false;
      if (u == e_hinge) hinge_dropped = true;
      for (std::size_t b : blob) blob_dropped += (u == b) ? 1 : 0;
      const int j = (e / K.g.nx) % K.g.ny, k = e / (K.g.nx * K.g.ny);
      if (in_beam(j, k)) beam_kept = false;
    }
    check(frozen_dropped && CK.frozen_loose >= 1 && blob_dropped == blob.size() &&
              loaded_kept && hinge_dropped && beam_kept,
          "G: a frozen speck, a 32-voxel blob and a speck edge-hinged to the beam are "
          "LOOSE (no size / frozen / hinge keep); a loaded speck is anchored");

    // A registered frozen mask only decides the frozen COUNT: the masked grey
    // speck is loose like the rest and counted; the full-modulus design speck is
    // loose and NOT counted (the mask, not the modulus, says what is frozen).
    {
      std::vector<char> keep(K.g.voxel_count(), 0);
      const std::size_t e_masked = K.g.index(10, 1, 1);
      keep[e_masked] = 1;
      topopt::FeaIslandKeepMask scope(&keep);
      auto CM = topopt::fea_detail::mg_island_census(K.g, K.ey, K.bcs, K.loads);
      bool masked_dropped = false, full_dropped = false;
      for (int e : CM.drop) {
        if (static_cast<std::size_t>(e) == e_masked) masked_dropped = true;
        if (static_cast<std::size_t>(e) == e_frozen) full_dropped = true;
      }
      check(masked_dropped && full_dropped && CM.frozen_loose == 1,
            "G: with a frozen mask registered, the masked speck is loose and is the "
            "one counted frozen");
    }
    // REVIEWER RULING 2026-10-24: no clearance / keep-out adjacency rule. A speck
    // next to a clearance voxel (FrozenVoid: Empty in the analysis grid, no
    // element) is loose like any other.
    {
      SpeckField C2 = F;
      std::vector<char> keep(C2.g.voxel_count(), 0);
      const std::size_t e_speck = C2.g.index(14, 1, 1);
      const std::size_t e_clear = C2.g.index(15, 2, 1);  // edge-neighbour
      C2.g.tags[e_clear] = VoxelTag::Empty;
      keep[e_clear] = 1;
      topopt::FeaIslandKeepMask scope(&keep);
      auto CC2 = topopt::fea_detail::mg_island_census(C2.g, C2.ey, C2.bcs, C2.loads);
      bool dropped = false;
      for (int e : CC2.drop)
        if (static_cast<std::size_t>(e) == e_speck) dropped = true;
      check(dropped && CC2.droppable == F.specks,
            "G: a speck next to a clearance (FrozenVoid / Empty) voxel is loose "
            "(no clearance-adjacency rule)");
    }

    // No cap: isolated single-voxel specks on a stride-2 lattice (no shared node
    // between any two) are 1/8 of the elements and almost all of the solid —
    // every one that touches no clamped node is loose, and the run says that
    // more than half its solid is loose (a warning, never a refusal to clean).
    VoxelGrid cg = make_grid(16, 16, 16);
    std::vector<double> cey(cg.voxel_count());
    for (int k = 0; k < 16; ++k)
      for (int j = 0; j < 16; ++j)
        for (int i = 0; i < 16; ++i)
          cey[cg.index(i, j, k)] =
              ((i % 2 == 0 && j % 2 == 0 && k % 2 == 0) ? 0.5 : 1e-9) * 1000.0;
    cey[cg.index(0, 0, 0)] = 1000.0;
    std::vector<DirichletBC> cb;
    clamp_x0(cg, cb);
    auto CC = topopt::fea_detail::mg_island_census(cg, cey, cb, {});
    std::printf("      stride-2 specks: loose=%d (%lld vox of %lld elements, %lld "
                "solid) majority=%d\n",
                CC.unanchored, CC.unanchored_voxels, CC.elements, CC.solid,
                CC.majority_loose ? 1 : 0);
    // 512 specks; the 64 in the i = 0 layer touch the clamped x = 0 nodes.
    check(CC.unanchored == 512 - 64 && static_cast<int>(CC.drop.size()) == 448 &&
              CC.majority_loose,
          "G: no cap — every loose speck goes, and 'more than half the solid is "
          "loose' is reported");
  }

  // ---------------------------------------------------------------------------
  // G: the solve with the loose specks out (THE CONNECTION RULE, every solve, no
  // permit needed) vs the EXACT system (RED CONTROL: the rule switched off by the
  // test-only switch, i.e. the specks at their true modulus).
  // ---------------------------------------------------------------------------
  {
    SpeckField F = make_speck_field(true);
    const double tol = 1e-8;

    // Reference: the EXACT system, retry OFF -> Jacobi fallback.
    topopt::fea_detail::mg_test_loose_rule(false);
    topopt::fea_matfree_reset_mg_stagnation_latch();
    topopt::fea_matfree_set_mg_safe_retry(false);
    CgInfo ref_info;
    const FeaSolution ref =
        topopt::fea_solve_mgcg_matfree(F.g, F.ey, nu, F.bcs, F.loads, tol, 0, &ref_info);
    topopt::fea_matfree_set_mg_safe_retry(true);
    std::printf("      exact, shipped only: used_mg=%d hier=%d cycles=%d (Jacobi its=%d "
                "res=%.3e)\n",
                ref_info.used_multigrid ? 1 : 0, ref_info.hier_built ? 1 : 0,
                ref_info.mg_cycles_attempted, ref_info.iterations, ref_info.residual);
    check(ref_info.hier_built && !ref_info.used_multigrid && ref_info.converged,
          "G: the shipped MG stalls on the EXACT speck field (Jacobi fallback converges)");

    // RED CONTROL: the exact system with the l1 retry.
    topopt::fea_matfree_reset_mg_stagnation_latch();
    CgInfo nod;
    const FeaSolution u_nod =
        topopt::fea_solve_mgcg_matfree(F.g, F.ey, nu, F.bcs, F.loads, tol, 0, &nod);
    const long long eng_nod = topopt::fea_matfree_mg_safe_engagements();
    const long long car_nod = topopt::fea_matfree_mg_safe_carries();
    std::printf("      exact, l1 retry: used_mg=%d cycles=%d engaged=%lld carried=%lld\n",
                nod.used_multigrid ? 1 : 0, nod.mg_cycles_attempted, eng_nod, car_nod);
    check(eng_nod == 1 && nod.converged, "G: on the exact field the l1 retry engages");
    check(topopt::fea_matfree_last_dropped_islands().empty(),
          "G: with the rule off (test switch) nothing is taken out");
    topopt::fea_detail::mg_test_loose_rule(true);

    // THE RULE: no permit held.
    topopt::fea_matfree_reset_mg_stagnation_latch();
    CgInfo dr;
    const FeaSolution u_dr =
        topopt::fea_solve_mgcg_matfree(F.g, F.ey, nu, F.bcs, F.loads, tol, 0, &dr);
    const std::vector<int> dropped = topopt::fea_matfree_last_dropped_islands();
    const double c_ref = dot_load(ref, F.loads), c_dr = dot_load(u_dr, F.loads);
    std::printf("      rule: used_mg=%d cycles=%d (shipped+safe) its=%d engaged=%lld "
                "dropped=%zu compliance %.10g vs exact %.10g (rel %.2e)\n",
                dr.used_multigrid ? 1 : 0, dr.mg_cycles_attempted, dr.iterations,
                topopt::fea_matfree_mg_safe_engagements(), dropped.size(), c_dr, c_ref,
                std::fabs(c_dr - c_ref) / std::fabs(c_ref));
    check(dr.used_multigrid && dr.converged,
          "G: with the loose specks out the solve converges on multigrid");
    check(!nod.used_multigrid || nod.mg_cycles_attempted >= 5 * dr.mg_cycles_attempted,
          "G RED CONTROL: with the specks in, MG needs >= 5x the cycles or never "
          "carries (speck tail)");
    check(static_cast<int>(dropped.size()) == F.specks &&
              topopt::fea_matfree_last_dropped_floor_youngs() == 1e-9 * 1000.0,
          "G: exactly the specks were solved at the floor modulus");
    check(std::fabs(c_dr - c_ref) <= 1e-6 * std::fabs(c_ref),
          "G: the solve's compliance matches the exact solve (<= 1e-6)");

    // Neither scope changes what is solved any more: a forbid (the certified
    // solves') does not keep the specks in, and no permit is needed.
    topopt::fea_matfree_reset_mg_stagnation_latch();
    {
      topopt::FeaIslandDropPermit permit;
      topopt::FeaIslandDropForbid forbid;
      CgInfo fi;
      const FeaSolution uf =
          topopt::fea_solve_mgcg_matfree(F.g, F.ey, nu, F.bcs, F.loads, tol, 0, &fi);
      check(static_cast<int>(topopt::fea_matfree_last_dropped_islands().size()) ==
                    F.specks &&
                bit_identical(uf, u_dr),
            "G: under a FeaIslandDropForbid the loose specks are out all the same "
            "(the rule holds in every solve, certified ones included)");
    }

    // Determinism: the solve is bit-reproducible.
    topopt::fea_matfree_reset_mg_stagnation_latch();
    CgInfo ai;
    const FeaSolution again =
        topopt::fea_solve_mgcg_matfree(F.g, F.ey, nu, F.bcs, F.loads, tol, 0, &ai);
    check(bit_identical(again, u_dr), "determinism: the solve is bit-reproducible");
  }

  // ---------------------------------------------------------------------------
  // B (breakdown): a safe attempt that breaks down BEFORE its first update —
  // either early return of the MG-PCG (non-finite r.z; zero p.Ap at k = 1) —
  // reports its STARTING residual (1 on a cold start), not 0. So it is NOT
  // productive, seeds nothing, and ADVANCES the safe-path latch counter (never
  // resets it): three in a row latch the safe path off. The exact fallback
  // still converges. RED before the fix: res read 0, i.e. "improved" and
  // "productive", the counter stayed 0 and the safe path never latched.
  // ---------------------------------------------------------------------------
  {
    SpeckField F = make_speck_field(true);
    RuleOff exact;  // the EXACT speck field: the stall this machinery is for
    const double tol = 1e-8;
    topopt::fea_matfree_reset_mg_stagnation_latch();
    const int modes[3] = {1, 2, 2};
    bool reports_ok = true, fallback_ok = true;
    for (int s = 0; s < 3; ++s) {
      topopt::fea_detail::mg_safe_test_force_breakdown(modes[s]);
      CgInfo bi;
      {
        topopt::FeaIslandDropPermit permit;
        topopt::fea_solve_mgcg_matfree(F.g, F.ey, nu, F.bcs, F.loads, tol, 0, &bi);
      }
      const topopt::fea_detail::MgSafeAttemptReport R =
          topopt::fea_detail::mg_last_safe_attempt();
      std::printf("      breakdown mode %d: seq=%lld cycles=%d res=%.3e r0=%.3e "
                  "seeded=%d productive=%d failures=%d latched=%d fallback its=%d\n",
                  modes[s], R.seq, R.cycles, R.res, R.r0, R.seeded_fallback ? 1 : 0,
                  R.productive ? 1 : 0, R.consecutive_failures,
                  topopt::fea_matfree_mg_safe_latched() ? 1 : 0, bi.iterations);
      reports_ok = reports_ok && R.seq == s + 1 && !R.converged && R.cycles == 0 &&
                   R.res == 1.0 && !R.seeded_fallback && !R.productive &&
                   R.consecutive_failures == s + 1;
      fallback_ok = fallback_ok && bi.converged && !bi.used_multigrid;
    }
    topopt::fea_detail::mg_safe_test_force_breakdown(0);
    check(reports_ok,
          "B: an immediate breakdown reports its starting residual (1), is not "
          "productive, seeds nothing, and advances the latch counter 1, 2, 3");
    check(topopt::fea_matfree_mg_safe_latched(),
          "B: three consecutive breakdowns latch the safe path off");
    check(fallback_ok, "B: the exact Jacobi-CG fallback still converges each time");
  }

  // ---------------------------------------------------------------------------
  // LATCH: three shipped stalls latch the shipped attempt off; the fourth solve
  // goes straight to the safe path (no shipped cycles burned). On the EXACT
  // speck field (see RuleOff).
  // ---------------------------------------------------------------------------
  {
    SpeckField F = make_speck_field(true);
    RuleOff exact;
    const double tol = 1e-8;
    topopt::fea_matfree_reset_mg_stagnation_latch();
    CgInfo last;
    for (int s = 0; s < 4; ++s)
      topopt::fea_solve_mgcg_matfree(F.g, F.ey, nu, F.bcs, F.loads, tol, 0, &last);
    check(topopt::fea_matfree_mg_stagnation_latched() && last.used_multigrid &&
              last.mg_cycles_attempted == last.iterations &&
              topopt::fea_matfree_mg_safe_carries() == 4,
          "latch: a latched run skips the shipped attempt and carries on the safe path");
  }

  // ---------------------------------------------------------------------------
  // A (one system): the Jacobi-CG fallback's start is judged on the system it
  // solves. Before the connection rule the safe retry could solve an
  // island-DROPPED system while the fallback solved the exact one, so a capped
  // retry's iterate had to be re-judged there (it could be far worse). Now every
  // path solves the system with the loose pieces out: a capped retry's residual
  // is the SAME number on the fallback's system, and an iterate that improved on
  // its start seeds the fallback. (Cycle cap 10 via max_iterations: the shipped
  // attempt stops at 10 cycles too, so the retry engages even with the specks
  // out; the capped fallback then throws, which is expected here.) POSITIVE
  // CONTROL on the exact field (RuleOff): an improving capped iterate seeds.
  // ---------------------------------------------------------------------------
  {
    SpeckField F = make_speck_field(true);
    const double tol = 1e-8;
    const int cap = 10;
    auto capped_solve = [&](bool rule) {
      topopt::fea_detail::mg_test_loose_rule(rule);
      topopt::fea_matfree_reset_mg_stagnation_latch();
      CgInfo ci;
      bool threw = false;
      try {
        topopt::fea_solve_mgcg_matfree(F.g, F.ey, nu, F.bcs, F.loads, tol, cap, &ci);
      } catch (const topopt::SolverNonConvergence&) {
        threw = true;
      }
      topopt::fea_detail::mg_test_loose_rule(true);
      const topopt::fea_detail::MgSafeAttemptReport R =
          topopt::fea_detail::mg_last_safe_attempt();
      std::printf("      capped (%d) %s: cycles=%d res=%.9e r0=%.3e | fallback's system "
                  "res=%.9e r0=%.3e | dropped=%d seeded=%d productive=%d (fallback "
                  "threw=%d)\n",
                  cap, rule ? "rule" : "exact", R.cycles, R.res, R.r0, R.res_exact,
                  R.r0_exact, R.dropped ? 1 : 0, R.seeded_fallback ? 1 : 0,
                  R.productive ? 1 : 0, threw ? 1 : 0);
      return R;
    };
    const auto D = capped_solve(true);
    check(D.seq == 1 && D.dropped && !D.converged && D.cycles == cap &&
              D.res < D.r0 && std::fabs(D.res_exact - D.res) <= 1e-6 * D.res &&
              D.r0_exact == D.r0,
          "A: with the loose specks out, a capped retry's residual is the same "
          "number on the fallback's system (one system; the recurrence's vs a "
          "fresh apply's, to 1e-6)");
    check(D.seeded_fallback,
          "A: ... so an iterate that improved on its start seeds the fallback");
    const auto N = capped_solve(false);
    check(!N.dropped && !N.converged && N.res_exact >= 0.0 &&
              N.res_exact < N.r0_exact && N.seeded_fallback,
          "A POSITIVE CONTROL (exact field): an iterate better on the fallback's "
          "system still seeds");
  }

  // ---------------------------------------------------------------------------
  // C (cold-start guard, CI core-linux cli_demo 2026-10-24): a PLSM warm start
  // can be FAR worse than zero — the previous design's field moves a region
  // that has since turned solid, and the demo L-bracket's warm starts measured
  // exact rel res 1e8-1e10. The safe retry's iterate then beats the warm start
  // (the old seeding test) while still being thousands of times worse than a
  // COLD start in the fallback's own stopping norm (demo: 1.7e3-3e4), and the
  // Jacobi-CG fallback seeded with it needed 33k-92k iterations against ~13k
  // cold, "converged" with a true residual up to 1.6e-1 at tol 1e-4, and on
  // Linux ran past its 124,362-iteration cap (rel res 0.0253) — rung 2
  // rejected. Here: warm = the exact field with the beam's tip half lifted
  // rigidly (its root face then carries the near-rigid forces), the retry
  // stopped short at 5 / 2 cycles (test hook), seeds of exact rel res 3.4e4 /
  // 1.6e7 (below the warm start's, far above a cold start's 1). Since W the
  // retry itself starts cold from such a warm start, so its stopped iterates
  // are 3.9 / 24 (still worse than a cold start, and the guard still holds).
  //   C1: with the solve capped 10 % above the COLD fallback's own count, the
  //       solve must converge — RED before the fix: the seeded fallback needed
  //       ~8,000 iterations and threw at the cap — and it must be the cold
  //       fallback bit-for-bit (the iterate is not handed over and the warm
  //       start, worse than zero in both norms, is not used either).
  //   C2: uncapped, the fallback's answer must meet the tolerance on a FRESH
  //       residual (<= 2 tol) — RED before the fix: the seeded fallback
  //       stopped on its recurrence at a true residual 77x the tolerance.
  //   POSITIVE CONTROL: an iterate better than a cold start in both norms
  //       (exact rel res 0.15; 2.5e-3 since W) still seeds.
  // ---------------------------------------------------------------------------
  {
    SpeckField F = make_speck_field(true);
    RuleOff exact;  // the EXACT speck field: the stall this machinery is for
    const double tol = 1e-8;
    topopt::fea_matfree_reset_mg_stagnation_latch();
    topopt::fea_matfree_set_mg_safe_retry(false);
    CgInfo ci;
    const FeaSolution ustar =
        topopt::fea_solve_mgcg_matfree(F.g, F.ey, nu, F.bcs, F.loads, 1e-10, 0, &ci);
    topopt::fea_matfree_reset_mg_stagnation_latch();
    CgInfo cc;
    const FeaSolution ucold =
        topopt::fea_solve_mgcg_matfree(F.g, F.ey, nu, F.bcs, F.loads, tol, 0, &cc);
    topopt::fea_matfree_set_mg_safe_retry(true);
    const int n_cold = cc.iterations;
    std::printf("      cold reference: used_mg=%d Jacobi its=%d true rel res %.3e\n",
                cc.used_multigrid ? 1 : 0, n_cold, true_rel(F.g, F.ey, F.bcs, F.loads, ucold, nu));
    auto lifted = [&](double lift) {
      FeaSolution w = ustar;
      for (int c = 6; c <= 10; ++c)
        for (int b = 6; b <= 10; ++b)
          for (int i = 16; i <= F.g.nx; ++i)
            w.u[static_cast<std::size_t>(3 * topopt::fea_node_index(F.g, i, b, c) + 2)] += lift;
      return w;
    };
    struct Out {
      topopt::fea_detail::MgSafeAttemptReport R;
      CgInfo info;
      FeaSolution u;
      bool threw = false;
    };
    auto warm_solve = [&](double lift, int safe_cycles, int cap) {
      Out o;
      const FeaSolution w = lifted(lift);
      topopt::fea_matfree_reset_mg_stagnation_latch();
      topopt::fea_detail::mg_safe_test_max_cycles(safe_cycles);
      try {
        o.u = topopt::fea_solve_mgcg_matfree(F.g, F.ey, nu, F.bcs, F.loads, tol, cap,
                                             &o.info, nullptr, &w);
      } catch (const topopt::SolverNonConvergence&) {
        o.threw = true;
      }
      topopt::fea_detail::mg_safe_test_max_cycles(0);
      o.R = topopt::fea_detail::mg_last_safe_attempt();
      std::printf("      lift %.0e, retry %d cycles, cap %d: exact rel res %.3e (retry "
                  "start %.3e) seeded=%d | fallback its=%d res=%.3e threw=%d true "
                  "rel res %.3e\n",
                  lift, safe_cycles, cap, o.R.res_exact, o.R.r0_exact,
                  o.R.seeded_fallback ? 1 : 0, o.info.iterations, o.info.residual,
                  o.threw ? 1 : 0,
                  o.threw ? -1.0 : true_rel(F.g, F.ey, F.bcs, F.loads, o.u, nu));
      return o;
    };
    const int cap = n_cold + n_cold / 10;
    const Out c1 = warm_solve(1e3, 5, cap);
    check(c1.R.seq == 1 && !c1.R.converged && c1.R.cold_start &&
              c1.R.r0_exact == 1.0 && c1.R.res_exact > 1.0,
          "C setup: the retry starts cold from a warm start worse than zero (W) and "
          "its stopped iterate is worse than a cold start (exact rel res > 1)");
    check(!c1.R.seeded_fallback, "C1: an iterate worse than a cold start never seeds");
    check(!c1.threw && c1.info.converged && c1.info.iterations == n_cold &&
              bit_identical(c1.u, ucold),
          "C1: the fallback converges within 10 % of the cold count — it IS the cold "
          "fallback, bit-for-bit");
    const Out c2 = warm_solve(1e5, 2, 0);
    check(!c2.threw && !c2.R.seeded_fallback &&
              true_rel(F.g, F.ey, F.bcs, F.loads, c2.u, nu) <= 2.0 * tol,
          "C2: the fallback's answer meets the tolerance on a FRESH residual (no "
          "false convergence from a huge start)");
    const Out cp = warm_solve(1e1, 60, 0);
    check(!cp.threw && cp.R.seeded_fallback && cp.R.res_exact < 1.0 &&
              cp.info.converged,
          "C POSITIVE CONTROL: an iterate better than a cold start still seeds");
  }

  // ---------------------------------------------------------------------------
  // W (the RETRY's own start, CI core-linux cli_demo 2026-10-25): C keeps a
  // warm start worse than zero out of the FALLBACK, but the l1 retry itself
  // still started from it. From exact rel res 1e8-1e10 its stopping test
  // (||r|| <= tol ||b||) asks for 12-14 orders of reduction, so on the demo 7
  // of 14 retries stopped short, none of their iterates beat a cold start
  // ("0 seeded"), and the cold Jacobi-CG fallback ran out its cap at rel res
  // 8.21e-4 on Linux (rung 2 rejected). The retry must start from the better
  // of the warm guess and zero, judged on the exact system in the same two
  // norms (rel res > 1 AND J > 0 => cold).
  //   W:  warm = the exact field with the beam's tip lifted 1e5 (far worse than
  //       zero in both norms), the retry capped 10 % above the COLD retry's own
  //       cycle count: it must converge, and it must BE the cold retry
  //       bit-for-bit (same cycles, same field). RED before the fix: from the
  //       warm start it did not converge within the cap.
  //   POSITIVE CONTROL: a warm start better than zero (lift 1e-3) is still
  //       used: the retry converges in fewer cycles than from cold.
  // ---------------------------------------------------------------------------
  {
    SpeckField F = make_speck_field(true);
    RuleOff exact;  // the EXACT speck field: the stall this machinery is for
    const double tol = 1e-8;
    topopt::fea_matfree_reset_mg_stagnation_latch();
    topopt::fea_matfree_set_mg_safe_retry(false);
    CgInfo ci;
    const FeaSolution ustar =
        topopt::fea_solve_mgcg_matfree(F.g, F.ey, nu, F.bcs, F.loads, 1e-10, 0, &ci);
    topopt::fea_matfree_set_mg_safe_retry(true);
    auto lifted = [&](double lift) {
      FeaSolution w = ustar;
      for (int c = 6; c <= 10; ++c)
        for (int b = 6; b <= 10; ++b)
          for (int i = 16; i <= F.g.nx; ++i)
            w.u[static_cast<std::size_t>(3 * topopt::fea_node_index(F.g, i, b, c) + 2)] += lift;
      return w;
    };
    // J(w) = w'Kw/2 - f'w over the free DOFs (w is 0 on the clamped ones).
    auto energy = [&](const FeaSolution& w) {
      const std::vector<double> kw = topopt::fea_matfree_apply(F.g, F.ey, nu, w.u);
      double J = 0.5 * std::inner_product(w.u.begin(), w.u.end(), kw.begin(), 0.0);
      for (const NodalLoad& l : F.loads) J -= l.value * w.at(l.node, l.component);
      return J;
    };
    struct Out {
      topopt::fea_detail::MgSafeAttemptReport R;
      CgInfo info;
      FeaSolution u;
    };
    auto solve = [&](const FeaSolution* w, int safe_cycles, const char* what) {
      Out o;
      topopt::fea_matfree_reset_mg_stagnation_latch();
      topopt::fea_detail::mg_safe_test_max_cycles(safe_cycles);
      {
        topopt::FeaIslandDropPermit permit;
        o.u = topopt::fea_solve_mgcg_matfree(F.g, F.ey, nu, F.bcs, F.loads, tol, 0,
                                             &o.info, nullptr, w);
      }
      topopt::fea_detail::mg_safe_test_max_cycles(0);
      o.R = topopt::fea_detail::mg_last_safe_attempt();
      std::printf("      %s: retry %s in %d cycles (cap %d), r0=%.3e exact r0=%.3e | "
                  "used_mg=%d its=%d\n",
                  what, o.R.converged ? "CONVERGED" : "stopped", o.R.cycles,
                  safe_cycles, o.R.r0, o.R.r0_exact, o.info.used_multigrid ? 1 : 0,
                  o.info.iterations);
      return o;
    };
    const Out cold = solve(nullptr, 0, "cold");
    const int n_l1 = cold.R.cycles;
    const int cap = n_l1 + n_l1 / 10;
    const FeaSolution wbad = lifted(1e5);
    const double bad_rel = true_rel(F.g, F.ey, F.bcs, F.loads, wbad, nu);
    const double bad_J = energy(wbad);
    std::printf("      warm (lift 1e5): exact rel res %.3e, J %.3e\n", bad_rel, bad_J);
    const Out wb = solve(&wbad, cap, "warm worse than zero");
    check(cold.R.seq == 1 && cold.R.converged && cold.info.used_multigrid &&
              bad_rel > 1e3 && bad_J > 0.0,
          "W setup: the cold retry converges; the lifted warm start is far worse "
          "than zero (rel res > 1e3, J > 0)");
    check(wb.R.converged && wb.R.cold_start && wb.info.used_multigrid &&
              wb.R.cycles == n_l1 && bit_identical(wb.u, cold.u),
          "W: a warm start worse than zero in both norms is NOT the retry's start — "
          "it converges within 10 % of the cold count and IS the cold retry, "
          "bit-for-bit");
    const FeaSolution wgood = lifted(1e-3);
    const double good_rel = true_rel(F.g, F.ey, F.bcs, F.loads, wgood, nu);
    std::printf("      warm (lift 1e-3): exact rel res %.3e, J %.3e\n", good_rel,
                energy(wgood));
    const Out wg = solve(&wgood, 0, "warm better than zero");
    check(good_rel < 1.0 && wg.R.seq == 1 && wg.R.converged && !wg.R.cold_start &&
              wg.R.cycles < n_l1 && wg.R.r0_exact < 1.0,
          "W POSITIVE CONTROL: a warm start better than zero is still the retry's "
          "start (fewer cycles than cold)");
  }

  // ---------------------------------------------------------------------------
  // F (cold-start FIRST window, demo L-bracket 2026-10-25): from zero the l1
  // MG-PCG residual 2-norm RISES before it falls on the demo's self-weighted
  // PLSM field, so the 600-cycle first progress window (best rel res <= 0.9 x
  // the start's) stopped a cold-start retry at rel res 7.26 that converges in
  // ~1,330 cycles; on the demo three such stops latched the safe path off. A
  // cold-start retry's first window is kSafeColdFirstWindow (2500) cycles;
  // later windows and the 6000-cycle cap are unchanged, and a warm-start
  // retry keeps 600 (its checkpoints are the multiples of 600, as before).
  // Fixture: tests/fixtures/mg_safe/demo_lbracket_selfweight_solve1.txt (the
  // demo's first safe solve, moduli quantized to 1/8 decade). Warm guess: the
  // whole part lifted 1e3 (far worse than zero in both norms -> cold start).
  //   F: the cold-start retry CONVERGES, in more than 600 and fewer than 2500
  //      cycles. RED before the fix: it stopped at 600 cycles (rel res ~7.4)
  //      and the solve fell to ~6,500 Jacobi-CG iterations.
  // ---------------------------------------------------------------------------
  {
    VoxelGrid g;
    std::vector<double> ey;
    std::vector<DirichletBC> bcs;
    std::vector<NodalLoad> loads;
    double poisson = 0.0, ftol = 0.0;
    bool parsed = false;
    {
      std::ifstream in(std::string(MG_SAFE_FIXTURE_DIR) +
                       "/demo_lbracket_selfweight_solve1.txt");
      std::string line, key;
      double spacing = 0.0, emax = 0.0, node_w = 0.0;
      int lpd = 0, nbc = -1;
      std::vector<int> bcijk;
      std::vector<double> nodal;
      while (in && std::getline(in, line)) {
        if (line.empty() || line[0] == '#') continue;
        std::istringstream ls(line);
        if (nbc >= 0 && static_cast<int>(bcijk.size()) < 3 * nbc) {
          int v;
          while (ls >> v) bcijk.push_back(v);
          continue;
        }
        if (!std::isdigit(static_cast<unsigned char>(line[0]))) {
          ls >> key;
          if (key == "grid") {
            ls >> g.nx >> g.ny >> g.nz;
            g.origin = Vec3{0, 0, 0};
            g.tags.assign(static_cast<std::size_t>(g.nx) * g.ny * g.nz, VoxelTag::Empty);
            ey.assign(g.tags.size(), 0.0);
          } else if (key == "spacing") ls >> spacing;
          else if (key == "poisson") ls >> poisson;
          else if (key == "tolerance") ls >> ftol;
          else if (key == "emax") ls >> emax;
          else if (key == "levels_per_decade") ls >> lpd;
          else if (key == "node_weight") ls >> node_w;
          else if (key == "bc") ls >> nbc;
          continue;
        }
        int k = 0, j = 0, x0 = 0;
        std::string cells;
        ls >> k >> j >> x0 >> cells;
        for (std::size_t c = 0; c < cells.size(); ++c) {
          if (cells[c] == '.') continue;
          const std::size_t e = g.index(x0 + static_cast<int>(c), j, k);
          g.tags[e] = VoxelTag::Interior;
          ey[e] = emax * std::pow(10.0, -static_cast<double>(cells[c] - '0') / lpd);
        }
      }
      g.spacing = spacing;
      nodal.assign(static_cast<std::size_t>(topopt::fea_node_count(g)), 0.0);
      for (int k = 0; k < g.nz; ++k)
        for (int j = 0; j < g.ny; ++j)
          for (int i = 0; i < g.nx; ++i)
            if (g.solid(i, j, k))
              for (int c = 0; c < 2; ++c)
                for (int b = 0; b < 2; ++b)
                  for (int a = 0; a < 2; ++a)
                    nodal[static_cast<std::size_t>(
                        topopt::fea_node_index(g, i + a, j + b, k + c))] += node_w;
      for (std::size_t n = 0; n < nodal.size(); ++n)
        if (nodal[n] != 0.0) loads.push_back({static_cast<int>(n), 2, nodal[n]});
      for (std::size_t q = 0; q + 2 < bcijk.size(); q += 3)
        for (int c = 0; c < 3; ++c)
          bcs.push_back(
              {topopt::fea_node_index(g, bcijk[q], bcijk[q + 1], bcijk[q + 2]), c, 0.0});
      parsed = g.nx == 48 && nbc == 196 && static_cast<int>(bcs.size()) == 3 * nbc &&
               lpd > 0 && emax > 0.0 && !loads.empty();
    }
    std::size_t part = 0;
    for (double v : ey) part += v > 0.0 ? 1 : 0;
    std::printf("      fixture: %dx%dx%d, %zu part voxels, %zu loads, %zu bcs, nu %.2f, "
                "tol %.0e\n", g.nx, g.ny, g.nz, part, loads.size(), bcs.size(), poisson,
                ftol);
    check(parsed && part == 17112, "F setup: the demo fixture parses (17,112 part voxels)");
    if (parsed) {
      FeaSolution w;
      w.u.assign(static_cast<std::size_t>(3 * topopt::fea_node_count(g)), 0.0);
      for (std::size_t n = 0; n < w.u.size() / 3; ++n) w.u[3 * n + 2] = 1e3;
      topopt::fea_matfree_reset_mg_stagnation_latch();
      CgInfo fi;
      bool threw = false;
      try {
        topopt::FeaIslandDropPermit permit;
        topopt::fea_solve_mgcg_matfree(g, ey, poisson, bcs, loads, ftol, 0, &fi,
                                       nullptr, &w);
      } catch (const topopt::SolverNonConvergence&) {
        threw = true;
      }
      const topopt::fea_detail::MgSafeAttemptReport R =
          topopt::fea_detail::mg_last_safe_attempt();
      std::printf("      cold-start retry: %s in %d cycles, rel res %.3e | used_mg=%d "
                  "its=%d threw=%d\n",
                  R.converged ? "CONVERGED" : "stopped", R.cycles, R.res,
                  fi.used_multigrid ? 1 : 0, fi.iterations, threw ? 1 : 0);
      check(R.seq == 1 && R.cold_start,
            "F setup: the lifted warm guess is worse than zero -> the retry starts cold");
      check(!threw && R.converged && fi.used_multigrid && R.cycles > 600 &&
                R.cycles < 2500,
            "F: the cold-start retry runs past the 600-cycle first window and "
            "converges (600 < cycles < 2500)");
    }
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
          "G: a second anchored + loaded 6-voxel body is NOT loose (never dropped)");

    const double tol = 1e-8;
    topopt::fea_matfree_reset_mg_stagnation_latch();
    topopt::fea_matfree_set_mg_safe_retry(false);
    CgInfo ri;
    FeaSolution ref;
    {
      RuleOff exact;  // the reference is the EXACT system (specks in)
      ref = topopt::fea_solve_mgcg_matfree(F.g, F.ey, nu, F.bcs, F.loads, tol, 0, &ri);
    }
    topopt::fea_matfree_set_mg_safe_retry(true);
    topopt::fea_matfree_reset_mg_stagnation_latch();
    CgInfo di;
    const FeaSolution u =
        topopt::fea_solve_mgcg_matfree(F.g, F.ey, nu, F.bcs, F.loads, tol, 0, &di);
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

  // ---------------------------------------------------------------------------
  // L (log bound): a latched run takes the safe path on every solve, so the
  // per-solve [mg-safe] line must be bounded. With the periods overridden to
  // (first 1, then a summary per 2), six safe attempts print 1 full line and 2
  // summaries, with 1 attempt pending (flushed at the next reset / thread
  // exit). The same six solves with every line printed (first 100) give
  // BIT-IDENTICAL fields and the same cycle counts: the bound changes nothing
  // but stderr. (Shipped periods: 5 / 50.)
  // ---------------------------------------------------------------------------
  {
    SpeckField F = make_speck_field(true);
    RuleOff exact;  // the EXACT speck field: the stall this machinery is for
    const double tol = 1e-8;
    auto six = [&](int first, int every, std::vector<FeaSolution>& us,
                   std::vector<int>& its) {
      topopt::fea_matfree_reset_mg_stagnation_latch();  // flushes a pending tail
      topopt::fea_detail::mg_safe_test_log_periods(first, every);
      topopt::FeaIslandDropPermit permit;
      for (int s = 0; s < 6; ++s) {
        CgInfo ci;
        us.push_back(
            topopt::fea_solve_mgcg_matfree(F.g, F.ey, nu, F.bcs, F.loads, tol, 0, &ci));
        its.push_back(ci.iterations);
      }
      return topopt::fea_detail::mg_safe_log_counts();
    };
    std::vector<FeaSolution> ua, ub;
    std::vector<int> ia, ib;
    const auto CA = six(1, 2, ua, ia);
    std::printf("      log (1, 2): lines=%lld summaries=%lld pending=%d engaged=%lld\n",
                CA.lines, CA.summaries, CA.pending,
                topopt::fea_matfree_mg_safe_engagements());
    const auto CB = six(100, 100, ub, ib);
    std::printf("      log (100, 100): lines=%lld summaries=%lld pending=%d\n",
                CB.lines, CB.summaries, CB.pending);
    topopt::fea_matfree_reset_mg_stagnation_latch();
    topopt::fea_detail::mg_safe_test_log_periods(0, 0);  // shipped 5 / 50
    check(CA.lines == 1 && CA.summaries == 2 && CA.pending == 1,
          "L: six safe attempts under (1, 2) print 1 full line + 2 summaries");
    check(CB.lines == 6 && CB.summaries == 0 && CB.pending == 0,
          "L: under (100, 100) every attempt prints its full line");
    bool same = ua.size() == ub.size() && ia == ib;
    for (std::size_t q = 0; same && q < ua.size(); ++q)
      same = bit_identical(ua[q], ub[q]);
    check(same, "L: the log bound changes no number (fields bit-identical, same cycles)");
  }

  // ---------------------------------------------------------------------------
  // D (certified solves): the FINAL compliance of simp_optimize, of its masked
  // overload (here with SEMDOT on) and of plsm_optimize is wrapped in a
  // FeaIslandDropForbid and the trajectory solves in a permit; the scopes are
  // still observed per solve (mg_island_permit_stats: trajectory permitted, the
  // LAST — the final compliance — not). Since THE CONNECTION RULE the scopes no
  // longer change what is solved: EVERY solve, the certified one included, runs
  // the loose-piece census (mg_loose_stats().scanned == all solves), because a
  // loose piece carries no load in a certified solve either.
  // ---------------------------------------------------------------------------
  {
    const VoxelGrid g = make_grid(12, 6, 6);
    topopt::SimpParams params;
    params.youngs_modulus = 1000.0;
    params.poisson = 0.3;
    std::vector<DirichletBC> bcs;
    clamp_x0(g, bcs);
    std::vector<NodalLoad> loads;
    for (int c = 2; c <= 4; ++c)
      loads.push_back({topopt::fea_node_index(g, g.nx, 3, c), 2, -1.0});
    const topopt::DesignMask mask(g.voxel_count(), topopt::MaskValue::Active);
    auto stats_line = [](const char* what) {
      const topopt::fea_detail::MgIslandPermitStats S =
          topopt::fea_detail::mg_island_permit_stats();
      std::printf("      %s: solves permitted=%lld not permitted=%lld, last "
                  "(final compliance) permitted=%d\n",
                  what, S.permitted, S.not_permitted, S.last_permitted ? 1 : 0);
      // THE CONNECTION RULE holds in every one of them, the certified final
      // solve included: each ran the loose-piece census.
      const topopt::fea_detail::MgLooseStats& L = topopt::fea_detail::mg_loose_stats();
      std::printf("      %s: solves that ran the loose-piece census=%lld of %lld\n", what,
                  L.scanned, S.permitted + S.not_permitted);
      return S.permitted >= 1 && S.not_permitted >= 1 && !S.last_permitted &&
             L.scanned == S.permitted + S.not_permitted;
    };

    topopt::SimpOptions o;
    o.solver = topopt::SolverKind::MultigridCG_Matfree;
    o.volume_fraction = 0.4;
    o.max_iterations = 3;
    topopt::fea_matfree_reset_mg_stagnation_latch();
    const topopt::SimpOptimizeResult r1 = topopt::simp_optimize(g, params, bcs, loads, o);
    const bool ok1 = stats_line("simp_optimize");
    check(!r1.non_convergent && !r1.infeasible && r1.compliance > 0.0 && ok1,
          "D: simp_optimize's final compliance solve forbids the island drop "
          "(trajectory solves permit it)");

    topopt::SimpOptions os = o;
    os.semdot = true;
    os.updater = topopt::SimpUpdater::MMA;
    topopt::fea_matfree_reset_mg_stagnation_latch();
    const topopt::SimpOptimizeResult r2 =
        topopt::simp_optimize(g, params, bcs, loads, os, mask);
    const bool ok2 = stats_line("simp_optimize masked + SEMDOT");
    check(!r2.non_convergent && !r2.infeasible && r2.compliance > 0.0 && ok2,
          "D: the masked / SEMDOT overload's final compliance solve forbids the "
          "island drop");

    topopt::PlsmOptions po;
    po.knots = topopt::PlsmKnots{2.0, 2.0, 2.0};
    po.seed = "holes";
    po.max_iterations = 3;
    topopt::fea_matfree_reset_mg_stagnation_latch();
    const topopt::PlsmRunResult r3 =
        topopt::plsm_optimize(g, params, bcs, loads, o, mask, po);
    const bool ok3 = stats_line("plsm_optimize");
    check(!r3.optimization.non_convergent && r3.optimization.compliance > 0.0 && ok3,
          "D: plsm_optimize's final compliance solve forbids the island drop");
  }

  if (g_failures == 0) std::printf("mg_safe_retry: all checks passed\n");
  else std::printf("mg_safe_retry: %d check(s) FAILED\n", g_failures);
  return g_failures == 0 ? 0 : 1;
}
