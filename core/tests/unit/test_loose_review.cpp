// THE INDEPENDENT REVIEW of claude/core-loose-pieces @ 4d67e43d (2026-10-26):
// five fixes, each pinned here, RED on 4d67e43d first.
//
//   R1  (HIGH) the safety net must not stop a legitimate fallback because of
//       GenEO's setup: its time never counts against the limit, and when the
//       build gives up (or is refused) plain CG CONTINUES. Here a GenEO
//       engagement that takes longer than a shortened test limit (a test hook
//       sleeps inside the setup span) — the solve must converge, not stop.
//       RED on 4d67e43d: SolverStopped right after the build stood down.
//   R2  (MEDIUM) a pause (the worker's SIGSTOP; steady_clock keeps running) is
//       not work: a gap between two polls longer than mf_pause_gap_ms moves the
//       deadline forward. Here a 400 ms simulated pause against a 150 ms limit.
//       RED on 4d67e43d: SolverStopped.
//   R3  (MEDIUM) reaching the iteration CAP is a SolverNonConvergence again (a
//       rejected rung, the search goes on), never a job stop: only the wall
//       clock throws SolverStopped. RED on 4d67e43d: SolverStopped at the cap.
//   R4  (MEDIUM-HIGH) certification must not overstate a margin: in CERTIFIED
//       solves (the FeaIslandDropForbid scopes) a piece is loose only if not
//       even 26-connected to an anchor or a load, so a 1-voxel diagonal
//       staircase neck (edge-only joints) between load and support is solved at
//       true stiffness and its stress is read — the same reading as with no
//       drop at all. RED on 4d67e43d: the stairs were solved as void (face rule)
//       and read zero stress.
//   R5  (LOW-MEDIUM) FeaLoosePieceRuleOff (thread-local, nestable) turns the
//       rule off for a non-SIMP caller (the Flexible squish FE): its solve is
//       bit-identical to the pre-rule system. RED on 4d67e43d: no such scope.

#include "topopt/analyze.hpp"
#include "topopt/fea.hpp"
#include "topopt/materials.hpp"
#include "topopt/simp.hpp"
#include "topopt/voxel.hpp"

#include "fea/fea_matfree.hpp"
#include "fea/geneo.hpp"

#include <cmath>
#include <cstdio>
#include <cstring>
#include <stdexcept>
#include <string>
#include <vector>

#ifndef TOPOPT_LOOSE_RULE_OFF_SCOPE
namespace topopt {
struct FeaLoosePieceRuleOff {};  // RED build: the scope does not exist yet
}  // namespace topopt
#endif

using topopt::CgInfo;
using topopt::DirichletBC;
using topopt::FeaSolution;
using topopt::NodalLoad;
using topopt::Vec3;
using topopt::VoxelGrid;
using topopt::VoxelTag;
namespace fd = topopt::fea_detail;

namespace {

int g_failures = 0;
void check(bool ok, const char* what) {
  std::printf("%s %s\n", ok ? "ok:  " : "FAIL:", what);
  if (!ok) ++g_failures;
}

constexpr double kE0 = 1000.0;
constexpr double kNu = 0.38;

// An 8^3 box of floor material (1e-9 E0) clamped at x = 0, holding a 2 x 2 bar
// its tip load anchors but only the floor supports: plain Jacobi-CG needs ~880
// iterations to 1e-14 here, past GenEO's 500-iteration trigger.
struct Bar {
  VoxelGrid g;
  std::vector<double> ey;
  std::vector<DirichletBC> bcs;
  std::vector<NodalLoad> loads;
};
Bar make_bar() {
  Bar B;
  B.g.nx = B.g.ny = B.g.nz = 8;
  B.g.spacing = 1.0;
  B.g.origin = Vec3{0, 0, 0};
  B.g.tags.assign(512, VoxelTag::Interior);
  B.ey.assign(512, 1e-9 * kE0);
  for (int i = 2; i < 8; ++i)
    for (int k = 3; k < 5; ++k)
      for (int j = 3; j < 5; ++j) B.ey[B.g.index(i, j, k)] = kE0;
  for (int c = 0; c <= 8; ++c)
    for (int b = 0; b <= 8; ++b)
      for (int d = 0; d < 3; ++d)
        B.bcs.push_back({topopt::fea_node_index(B.g, 0, b, c), d, 0.0});
  for (int c = 3; c <= 5; ++c)
    for (int b = 3; b <= 5; ++b)
      B.loads.push_back({topopt::fea_node_index(B.g, 8, b, c), 2, -1.0});
  return B;
}

struct Outcome {
  bool converged = false, stopped = false, nonconv = false;
  int iterations = 0;
  std::string what;
};
Outcome solve(const Bar& B, double tol, int cap, bool plain) {
  Outcome o;
  topopt::fea_matfree_reset_mg_stagnation_latch();
  topopt::fea_matfree_set_mg_safe_retry(false);
  try {
    CgInfo ci;
    if (plain)
      topopt::fea_solve_cg_matfree(B.g, B.ey, kNu, B.bcs, B.loads, tol, cap, &ci);
    else
      topopt::fea_solve_mgcg_matfree(B.g, B.ey, kNu, B.bcs, B.loads, tol, cap, &ci);
    o.converged = ci.converged;
    o.iterations = ci.iterations;
  } catch (const topopt::SolverNonConvergence& e) {
    o.nonconv = true;
    o.what = e.what();
  } catch (const std::runtime_error& e) {
    o.what = e.what();
    o.stopped = o.what.rfind("stopped: the solver did not converge", 0) == 0;
  }
  topopt::fea_matfree_set_mg_safe_retry(true);
  return o;
}
void show(const char* tag, const Outcome& o) {
  std::printf("      %s: converged=%d (its %d) stopped=%d nonconvergence=%d %s\n", tag,
              o.converged ? 1 : 0, o.iterations, o.stopped ? 1 : 0, o.nonconv ? 1 : 0,
              o.what.c_str());
}

bool bit_identical(const std::vector<double>& a, const std::vector<double>& b) {
  return a.size() == b.size() &&
         std::memcmp(a.data(), b.data(), a.size() * sizeof(double)) == 0;
}

}  // namespace

int main() {
  // ---------------------------------------------------------------------------
  // R1: GenEO's setup never counts; a build that gives up leaves plain CG going.
  // ---------------------------------------------------------------------------
  {
    const Bar B = make_bar();
    const bool was = fd::geneo_set_enabled(true);
    fd::geneo_reset();
    fd::mf_test_safety_net_ms(150.0);
    fd::mf_test_geneo_setup_sleep_ms() = 400.0;
    const Outcome o = solve(B, 1e-14, 0, false);
    fd::mf_test_geneo_setup_sleep_ms() = 0.0;
    fd::mf_test_safety_net_ms(0.0);
    const long long builds = fd::geneo_basis_builds();
    fd::geneo_reset();
    fd::geneo_set_enabled(was);
    show("R1 fallback, 400 ms GenEO setup vs a 150 ms limit", o);
    std::printf("      R1 GenEO builds: %lld\n", builds);
    check(o.converged && !o.stopped && !o.nonconv,
          "R1: a GenEO setup longer than the limit does not stop the fallback; "
          "plain CG continues and converges");
  }

  // ---------------------------------------------------------------------------
  // R2: a pause (a gap between polls > mf_pause_gap_ms) is not work.
  // ---------------------------------------------------------------------------
  {
    const Bar B = make_bar();
    fd::mf_test_safety_net_ms(150.0);
    const double gap0 = fd::mf_pause_gap_ms();
    fd::mf_pause_gap_ms() = 100.0;
    fd::mf_test_pause_at() = 100;
    fd::mf_test_pause_ms() = 400.0;
    const Outcome o = solve(B, 1e-14, 0, false);
    fd::mf_test_pause_at() = 0;
    fd::mf_test_pause_ms() = 0.0;
    fd::mf_pause_gap_ms() = gap0;
    fd::mf_test_safety_net_ms(0.0);
    show("R2 fallback, a 400 ms pause vs a 150 ms limit", o);
    check(o.converged && !o.stopped,
          "R2: a pause does not count against the limit (the deadline moves forward)");
    // POSITIVE CONTROL: the same 400 ms spent as one long stretch below the gap
    // threshold is work, and the limit still fires.
    fd::mf_test_safety_net_ms(150.0);
    fd::mf_pause_gap_ms() = 1e9;
    fd::mf_test_pause_at() = 100;
    fd::mf_test_pause_ms() = 400.0;
    const Outcome c = solve(B, 1e-14, 0, false);
    fd::mf_test_pause_at() = 0;
    fd::mf_test_pause_ms() = 0.0;
    fd::mf_pause_gap_ms() = gap0;
    fd::mf_test_safety_net_ms(0.0);
    show("R2 control, the same stretch counted as work", c);
    check(c.stopped, "R2 POSITIVE CONTROL: counted as work, the limit fires (SolverStopped)");
  }

  // ---------------------------------------------------------------------------
  // R3: the iteration cap is a SolverNonConvergence (a rejected rung), never a stop.
  // ---------------------------------------------------------------------------
  {
    const Bar B = make_bar();
    const Outcome a = solve(B, 1e-100, 0, false);
    const Outcome b = solve(B, 1e-100, 0, true);
    show("R3 MG fallback at its own cap", a);
    show("R3 plain Jacobi-CG at its own cap", b);
    check(a.nonconv && !a.stopped && b.nonconv && !b.stopped,
          "R3: reaching the iteration cap throws SolverNonConvergence (MG fallback and "
          "plain CG), not SolverStopped");
  }

  // ---------------------------------------------------------------------------
  // R4: a 1-voxel diagonal staircase neck is read at true stiffness in
  // certification (the 26-connected rule in certified solves).
  // ---------------------------------------------------------------------------
  {
    VoxelGrid g;
    g.nx = 16;
    g.ny = 16;
    g.nz = 2;
    g.spacing = 1.0;
    g.origin = Vec3{0, 0, 0};
    g.tags.assign(static_cast<std::size_t>(16 * 16 * 2), VoxelTag::Interior);
    std::vector<double> rho(g.voxel_count(), 0.05);  // void: E = 1.25e-4 E0
    auto put = [&](int i, int j) {
      for (int k = 0; k < 2; ++k) rho[g.index(i, j, k)] = 1.0;
    };
    for (int j = 0; j < 4; ++j)
      for (int i = 0; i < 4; ++i) put(i, j);            // support block
    for (int s = 4; s < 12; ++s) put(s, s);             // the staircase (edge joints)
    for (int j = 12; j < 16; ++j)
      for (int i = 12; i < 16; ++i) put(i, j);          // load block
    std::vector<DirichletBC> bcs;
    for (int c = 0; c <= 2; ++c)
      for (int b = 0; b <= 4; ++b)
        for (int d = 0; d < 3; ++d)
          bcs.push_back({topopt::fea_node_index(g, 0, b, c), d, 0.0});
    std::vector<NodalLoad> loads;
    for (int c = 0; c <= 2; ++c)
      for (int b = 12; b <= 16; ++b)
        loads.push_back({topopt::fea_node_index(g, 16, b, c), 0, 1.0});
    topopt::Material mat;
    mat.youngs_modulus_mpa = 3500.0;
    mat.yield_strength_mpa = 55.0;
    mat.density_g_cm3 = 1.24;
    mat.z_knockdown = 0.55;
    mat.poisson = 0.33;
    mat.family = "fdm";
    topopt::SimpParams params;
    params.youngs_modulus = mat.youngs_modulus_mpa;
    params.poisson = mat.poisson;
    topopt::KnockdownSpec kd;
    auto certify = [&](bool rule) {
      fd::mg_test_loose_rule(rule);
      topopt::fea_matfree_reset_mg_stagnation_latch();
      const topopt::FixedDesignAnalysis a = topopt::analyze_fixed_design(
          g, params, rho, bcs, loads, mat, Vec3{0, 0, 1}, 1e-8, 0,
          topopt::SolverKind::MultigridCG_Matfree, 0.0, kd, true,
          static_cast<double>(g.solid_count()));
      fd::mg_test_loose_rule(true);
      return a;
    };
    const topopt::FixedDesignAnalysis cert = certify(true);
    const std::size_t dropped = topopt::fea_matfree_last_dropped_islands().size();
    const topopt::FixedDesignAnalysis none = certify(false);
    double stair_cert = 0.0, stair_none = 0.0;
    for (int s = 4; s < 12; ++s) {
      stair_cert = std::max(stair_cert, cert.von_mises_field[g.index(s, s, 0)]);
      stair_none = std::max(stair_none, none.von_mises_field[g.index(s, s, 0)]);
    }
    std::printf("      R4 certified: max vm %.6g (stairs %.6g), %zu voxels at the floor, "
                "worst margin %.6g ; no drop: max vm %.6g (stairs %.6g), worst margin "
                "%.6g\n",
                cert.max_von_mises, stair_cert, dropped, cert.margin.worst_case,
                none.max_von_mises, stair_none, none.margin.worst_case);
    check(!cert.non_convergent && !none.non_convergent && stair_none > 0.0,
          "R4 setup: both certifications solve; the stairs carry stress with no drop");
    check(bit_identical(cert.von_mises_field, none.von_mises_field) &&
              cert.max_von_mises == none.max_von_mises && dropped == 0,
          "R4: the staircase neck is certified at true stiffness — the same stress "
          "field as with no drop (nothing at the floor)");
  }

  // ---------------------------------------------------------------------------
  // R5: FeaLoosePieceRuleOff gives the pre-rule system, bit-for-bit.
  // ---------------------------------------------------------------------------
  {
    Bar B = make_bar();
    // A stiff 2x2x2 block floating in the floor: loose under the rule.
    for (int k = 0; k < 2; ++k)
      for (int j = 0; j < 2; ++j)
        for (int i = 5; i < 7; ++i) B.ey[B.g.index(i, j, k)] = kE0;
    auto run = [&](int mode) {  // 0 = rule on, 1 = scope off, 2 = test switch off
      topopt::fea_matfree_reset_mg_stagnation_latch();
      CgInfo ci;
      FeaSolution u;
      if (mode == 1) {
        topopt::FeaLoosePieceRuleOff off;
        {
          topopt::FeaLoosePieceRuleOff nested;  // nestable
        }
        u = topopt::fea_solve_mgcg_matfree(B.g, B.ey, kNu, B.bcs, B.loads, 1e-10, 0, &ci);
      } else {
        if (mode == 2) fd::mg_test_loose_rule(false);
        u = topopt::fea_solve_mgcg_matfree(B.g, B.ey, kNu, B.bcs, B.loads, 1e-10, 0, &ci);
        fd::mg_test_loose_rule(true);
      }
      return std::make_pair(u, topopt::fea_matfree_last_dropped_islands().size());
    };
    const auto on = run(0);
    const auto off = run(1);
    const auto pre = run(2);
    std::printf("      R5 dropped: rule on %zu, FeaLoosePieceRuleOff %zu, pre-rule %zu\n",
                on.second, off.second, pre.second);
    check(on.second > 0 && off.second == 0 && bit_identical(off.first.u, pre.first.u),
          "R5: under FeaLoosePieceRuleOff the solve is the pre-rule system, bit-for-bit");
    const auto after = run(0);
    check(after.second == on.second && bit_identical(after.first.u, on.first.u),
          "R5: the scope restores the rule when it ends");
  }

  if (g_failures == 0) std::printf("loose_review: all checks passed\n");
  else std::printf("loose_review: %d check(s) FAILED\n", g_failures);
  return g_failures == 0 ? 0 : 1;
}
