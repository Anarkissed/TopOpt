// alg_level1_gate.cpp — THE ARMING GATE for algebraic level-1 coarsening
// (task: algebraic-level1-coarsening).
//
// NOT a CI test, NOT in CTest. It runs the FULL PRODUCTION LADDER twice — the
// algebraic level-1 coarse space DISARMED and ARMED, with the rest of the
// production stack (recycling, GenEO, draft, the Galerkin cache, the P-core
// pin) armed identically in both — and answers the four bars a production
// arming decision needs:
//
//   AH4  THE LATCH SHOULD STOP FIRING. PR 280's baseline stagnates on every
//        configuration and `kMgLatchThreshold` fires at design iteration 3,
//        after which the whole run rides Jacobi-CG. This reports stagnating
//        solves per rung and whether the latch fires, in each posture. It is
//        the HEADLINE: the goal is MULTIGRID STAYING ALIVE, not a wall ratio.
//   AH7  FULL GATE TABLE, before and after, every rung, verdict + margin, plus
//        voxel-classification flips charged against a 1e-9 NEGATIVE-CONTROL
//        FLOOR (PR 248's discipline). The control runs FIRST and establishes
//        what "the same answer, computed twice" already costs, so a flip count
//        below it is noise and one above it is real. ANY VERDICT FLIP IS A
//        BLOCKED-STOP and this prints it as one.
//   AH9  THE DOWNSTREAM PREDICTION. If multigrid becomes healthy, GenEO's
//        ski-rental gate (PR 278) should rarely or never engage, and the
//        recycler — which PR 282 established is STRUCTURALLY ABSENT on the
//        healthy multigrid path — should simply disappear. Both are counted.
//   AH11 WALL on the maintainer's regime, with host load recorded beside it
//        (PR 277's discipline: a shared host makes wall indicative, not
//        evidence), and CG iterations as the load-independent currency.
//
// THE FIXTURE is `make_stagnation` from the draft/GenEO arming gates, verbatim,
// so this task's gate table is directly comparable with theirs rather than
// measured on a fixture chosen to flatter it. Its regime is the dilute design
// box PR 280 indicted.
//
// BUILD (library built Release first):
//   cmake -S core -B core/build -DCMAKE_BUILD_TYPE=Release
//   cmake --build core/build --target topopt -j
//   c++ -std=c++17 -O2 -I core/include -I core/src -I /opt/homebrew/include/eigen3 \
//       -DSETTINGS_RULES_PATH="\"$PWD/core/src/settings/rules.json\"" \
//       core/tests/harness/alg_level1_gate.cpp core/build/libtopopt.a <OCCT libs> \
//       -o core/build/alg_level1_gate
// RUN: ./core/build/alg_level1_gate <gate|latch> [csvdir]

#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <string>
#include <vector>

#include <unistd.h>

#include "topopt/fea.hpp"
#include "topopt/materials.hpp"
#include "topopt/observability.hpp"
#include "topopt/pipeline.hpp"
#include "topopt/production.hpp"
#include "topopt/settings.hpp"
#include "topopt/simp.hpp"
#include "topopt/voxel.hpp"

using namespace topopt;

namespace {

void print_load(const char* when) {
  double la[3] = {0, 0, 0};
  if (getloadavg(la, 3) < 0) {
    std::printf("[load %s] unavailable\n", when);
    return;
  }
  std::printf("[load %s] 1m %.2f  5m %.2f  15m %.2f  (on %ld logical cores)\n",
              when, la[0], la[1], la[2], sysconf(_SC_NPROCESSORS_ONLN));
}

// --- the fixture, copied verbatim from geneo_arming_gate / draft_arming_gate --
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
  auto solid = [&](int i, int j, int k) {
    if (i < 0 || j < 0 || k < 0 || i >= span || j >= ny || k >= arm) return false;
    return g.tag(i, j, k) != VoxelTag::Empty;
  };
  for (int k = 0; k < arm; ++k)
    for (int j = 0; j < ny; ++j)
      for (int i = 0; i < span; ++i) {
        if (!solid(i, j, k)) continue;
        if (!solid(i - 1, j, k) || !solid(i + 1, j, k) || !solid(i, j - 1, k) ||
            !solid(i, j + 1, k) || !solid(i, j, k - 1) || !solid(i, j, k + 1))
          g.set_tag(i, j, k, VoxelTag::Surface);
      }
  for (int j = 0; j < ny; ++j)
    for (int i = 0; i < t; ++i) g.set_tag(i, j, arm - 1, VoxelTag::Fixture);
  bcs.clear();
  for (int b = 0; b <= ny; ++b)
    for (int a = 0; a <= t; ++a) {
      const int n = fea_node_index(g, a, b, arm);
      bcs.push_back({n, 0, 0.0});
      bcs.push_back({n, 1, 0.0});
      bcs.push_back({n, 2, 0.0});
    }
  for (int k = 0; k < t; ++k)
    for (int j = 0; j < ny; ++j) g.set_tag(span - 1, j, k, VoxelTag::Load);
  return g;
}

struct Fixture {
  VoxelGrid part;
  std::vector<DirichletBC> bcs;
  std::vector<NodalLoad> loads;
  DesignBox box;
};

Fixture make_stagnation() {
  Fixture f;
  int arm = 12, span = 12, ny = 4, t = 3;
  if (const char* a = std::getenv("TOPOPT_GA_ARM")) {
    const int s = std::atoi(a);
    if (s == 8) { arm = 8; span = 8; ny = 3; t = 2; }
    if (s == 12) { arm = 12; span = 12; ny = 4; t = 3; }
    if (s == 16) { arm = 16; span = 16; ny = 6; t = 4; }
    if (s == 24) { arm = 24; span = 24; ny = 6; t = 6; }
  }
  const double h = 2.0;
  f.part = l_bracket(f.bcs, arm, span, ny, t, h);
  f.loads = traction_loads(f.part, VoxelTag::Load, Vec3{0.0, 0.0, -30.0});
  f.box.min = Vec3{0.0, 0.0, 0.0};
  f.box.max = Vec3{span * h * 2.0, ny * h * 2.0, arm * h * 2.0};
  return f;
}

// The material, copied verbatim from geneo_arming_gate / draft_arming_gate so
// the gate tables are comparable.
Material fdm() {
  Material m;
  m.youngs_modulus_mpa = 3500.0;
  m.yield_strength_mpa = 55.0;
  m.density_g_cm3 = 1.24;
  m.z_knockdown = 0.55;
  m.poisson = 0.33;
  m.family = "fdm";
  return m;
}

struct Delta {
  double mean_abs = 0.0, max_abs = 0.0;
};
Delta compare(const std::vector<double>& a, const std::vector<double>& b) {
  Delta d;
  const std::size_t n = std::min(a.size(), b.size());
  for (std::size_t i = 0; i < n; ++i) {
    const double x = std::fabs(a[i] - b[i]);
    d.mean_abs += x;
    d.max_abs = std::max(d.max_abs, x);
  }
  if (n) d.mean_abs /= static_cast<double>(n);
  return d;
}

struct Rung {
  double vf = 0, margin = 0, compliance = 0;
  int accepted = 0, infeasible = 0;
  std::vector<double> density;
};

struct LadderResult {
  std::vector<Rung> rungs;
  long long cg = 0;
  long long solves = 0;
  int stagnating_solves = 0;   // built a hierarchy but did not carry
  bool latched = false;
  long long geneo_builds = 0, geneo_refreshes = 0, geneo_armed = 0,
            geneo_declined = 0;
  long long recycled_solves = 0;
  int max_recycle_dim = 0;
  double wall = 0.0;
  int alg_aggregates = 0, alg_coarse_dim = 0, alg_levels = 0;
  double alg_added_mb = 0.0;
  bool alg_refused = false;
  std::string alg_refuse_reason;
  // Per-rung stagnation, so AH4 can be read rung by rung rather than as a
  // single run total that hides where the latch fired.
  std::vector<int> stag_by_rung;
  std::vector<int> solves_by_rung;
  // The solved grid's shape and solid mask, so the classification flips are
  // charged over the SAME voxel set in every posture.
  int solved_nx = 0, solved_ny = 0, solved_nz = 0;
  std::vector<char> solid;
};

const char* verdict(const Rung& r) {
  return r.infeasible ? "INFEAS" : (r.accepted ? "ACCEPT" : "REJECT");
}

}  // namespace

int main(int argc, char** argv) {
  const std::string mode = argc > 1 ? argv[1] : "gate";
  const std::string dir = argc > 2 ? argv[2] : ".";
  print_load("start");

  SettingsRules rules;
  try {
    rules = load_settings_rules_file(SETTINGS_RULES_PATH);
  } catch (const std::exception& e) {
    std::fprintf(stderr, "FAIL: rules.json: %s\n", e.what());
    return 1;
  }
  const Material material = fdm();
  const Fixture f = make_stagnation();
  std::printf("fixture: %dx%dx%d part, design box [%.1f %.1f %.1f]..[%.1f %.1f "
              "%.1f]\n",
              f.part.nx, f.part.ny, f.part.nz, f.box.min.x, f.box.min.y,
              f.box.min.z, f.box.max.x, f.box.max.y, f.box.max.z);

  // ONE ladder run. `armed` is the ONLY axis that differs between postures;
  // `cert_tol > 0` makes it the 1e-9 NEGATIVE CONTROL (disarmed, tighter
  // tolerance) whose flip count is the floor everything else is judged against.
  auto ladder_run = [&](bool armed, double cert_tol) {
    MinimizePlasticOptions o;
    configure_production_options(o);
    fea_set_mg_algebraic_level1(armed);
    if (cert_tol > 0.0) o.simp.cg_tolerance = cert_tol;
    o.volume_fraction_ladder = production_reduction_ladder();
    o.margin_stop = 1.5;
    o.external_loads = f.loads;
    o.gravity = 9810.0 * 1e-9;
    o.gravity_direction = Vec3{0.0, 0.0, -1.0};
    o.infill_percent = 100.0;
    o.design_box = f.box;

    LadderResult R;
    std::size_t cur_rung = static_cast<std::size_t>(-1);
    o.on_iteration = [&](std::size_t rung, std::size_t,
                         const SimpIterationObservation& ob) {
      if (rung != cur_rung) {
        cur_rung = rung;
        R.stag_by_rung.push_back(0);
        R.solves_by_rung.push_back(0);
      }
      R.cg += ob.cg_iterations;
      ++R.solves;
      if (!R.solves_by_rung.empty()) ++R.solves_by_rung.back();
      // STAGNATION, not fallback: a solve that BUILT a hierarchy and still did
      // not carry. A build-rejection is a different failure and must not be
      // counted as one (PR 128's distinction).
      if (ob.cg_hier_built && !ob.cg_used_multigrid) {
        ++R.stagnating_solves;
        if (!R.stag_by_rung.empty()) ++R.stag_by_rung.back();
      }
      if (ob.cg_recycle_dim > 0) {
        ++R.recycled_solves;
        R.max_recycle_dim = std::max(R.max_recycle_dim, ob.cg_recycle_dim);
      }
    };

    fea_matfree_reset_mg_stagnation_latch();
    fea_mg_reset_algebraic_level1_info();
    const auto t0 = std::chrono::steady_clock::now();
    const MinimizePlasticResult r =
        minimize_plastic(f.part, material, "fdm", f.bcs, rules, o);
    R.wall = std::chrono::duration<double>(std::chrono::steady_clock::now() - t0)
                 .count();
    R.latched = fea_matfree_mg_stagnation_latched();
    R.geneo_builds = fea_geneo_basis_builds();
    R.geneo_refreshes = fea_geneo_coarse_refreshes();
    R.geneo_armed = fea_geneo_armed_solves();
    R.geneo_declined = fea_geneo_declined_solves();
    {
      const MgAlgebraicLevel1Info a = fea_mg_algebraic_level1_info();
      R.alg_aggregates = a.aggregates;
      R.alg_coarse_dim = a.coarse_dim;
      R.alg_levels = a.levels;
      R.alg_added_mb = static_cast<double>(a.bytes) / (1024.0 * 1024.0);
      R.alg_refused = a.refused;
      R.alg_refuse_reason = a.refuse_reason;
    }
    for (const auto& v : r.evaluated) {
      Rung rg;
      rg.vf = v.requested_volume_fraction;
      rg.margin = v.report.margin.worst_case;
      rg.compliance = v.optimization.compliance;
      rg.accepted = v.accepted ? 1 : 0;
      rg.infeasible = v.infeasible ? 1 : 0;
      rg.density = v.optimization.physical_density;
      R.rungs.push_back(std::move(rg));
    }
    R.solved_nx = r.solved_grid.nx;
    R.solved_ny = r.solved_grid.ny;
    R.solved_nz = r.solved_grid.nz;
    R.solid.assign(r.solved_grid.voxel_count(), 0);
    for (int k = 0; k < r.solved_grid.nz; ++k)
      for (int j = 0; j < r.solved_grid.ny; ++j)
        for (int i = 0; i < r.solved_grid.nx; ++i)
          R.solid[r.solved_grid.index(i, j, k)] =
              r.solved_grid.solid(i, j, k) ? 1 : 0;
    // Leave the process in the disarmed state whatever this posture was.
    fea_set_mg_algebraic_level1(false);
    fea_reset_geneo_basis();
    return R;
  };

  std::printf("\n===== NEGATIVE CONTROL (disarmed, cg_tolerance 1e-9) — the "
              "basin floor everything below is charged against =====\n");
  const LadderResult ctl = ladder_run(false, 1e-9);
  std::printf("  %zu rungs, %lld CG, %d stagnating solves, latch %s, wall "
              "%.1f s\n",
              ctl.rungs.size(), ctl.cg, ctl.stagnating_solves,
              ctl.latched ? "FIRED" : "quiet", ctl.wall);

  std::printf("\n===== DISARMED (geometric level 1 — the shipped path) =====\n");
  const LadderResult off = ladder_run(false, 0.0);
  std::printf("  %zu rungs, %lld CG, %d stagnating solves of %lld, latch %s, "
              "wall %.1f s\n",
              off.rungs.size(), off.cg, off.stagnating_solves, off.solves,
              off.latched ? "FIRED" : "quiet", off.wall);

  std::printf("\n===== ARMED (algebraic level 1) =====\n");
  const LadderResult on = ladder_run(true, 0.0);
  std::printf("  %zu rungs, %lld CG, %d stagnating solves of %lld, latch %s, "
              "wall %.1f s\n",
              on.rungs.size(), on.cg, on.stagnating_solves, on.solves,
              on.latched ? "FIRED" : "quiet", on.wall);
  std::printf("  aggregation: %d aggregates, level-1 dim %d, %d levels, "
              "adds %.1f MB%s%s\n",
              on.alg_aggregates, on.alg_coarse_dim, on.alg_levels,
              on.alg_added_mb, on.alg_refused ? "  REFUSED: " : "",
              on.alg_refused ? on.alg_refuse_reason.c_str() : "");

  // ------------------------------------------------------------------
  // AH4 — THE HEADLINE: does the latch stop firing?
  // ------------------------------------------------------------------
  std::printf("\n===== AH4 — STAGNATION AND THE LATCH (the headline) =====\n");
  std::printf("  posture    | stagnating solves | of total | latch   | CG\n");
  std::printf("  disarmed   | %17d | %8lld | %-7s | %lld\n",
              off.stagnating_solves, off.solves, off.latched ? "FIRED" : "quiet",
              off.cg);
  std::printf("  ARMED      | %17d | %8lld | %-7s | %lld\n",
              on.stagnating_solves, on.solves, on.latched ? "FIRED" : "quiet",
              on.cg);
  std::printf("\n  per-rung stagnating solves:\n    disarmed:");
  for (std::size_t i = 0; i < off.stag_by_rung.size(); ++i)
    std::printf(" %d/%d", off.stag_by_rung[i], off.solves_by_rung[i]);
  std::printf("\n    ARMED   :");
  for (std::size_t i = 0; i < on.stag_by_rung.size(); ++i)
    std::printf(" %d/%d", on.stag_by_rung[i], on.solves_by_rung[i]);
  std::printf("\n");

  // ------------------------------------------------------------------
  // AH9 — the downstream predictions.
  // ------------------------------------------------------------------
  std::printf("\n===== AH9 — DOWNSTREAM PREDICTIONS =====\n");
  std::printf("  GenEO      | builds | refreshes | armed solves | declined\n");
  std::printf("  disarmed   | %6lld | %9lld | %12lld | %8lld\n",
              off.geneo_builds, off.geneo_refreshes, off.geneo_armed,
              off.geneo_declined);
  std::printf("  ARMED      | %6lld | %9lld | %12lld | %8lld\n",
              on.geneo_builds, on.geneo_refreshes, on.geneo_armed,
              on.geneo_declined);
  std::printf("  RECYCLER   | solves with a recycled subspace | max dim\n");
  std::printf("  disarmed   | %31lld | %7d\n", off.recycled_solves,
              off.max_recycle_dim);
  std::printf("  ARMED      | %31lld | %7d\n", on.recycled_solves,
              on.max_recycle_dim);
  std::printf("  (PR 282: the recycler is STRUCTURALLY absent on the healthy\n"
              "   multigrid path — mf_mgpcg constructs its session with\n"
              "   allowed = rc_wrap_multigrid(), pinned false — so a run whose\n"
              "   solves all carry should show ZERO recycled solves.)\n");

  // ------------------------------------------------------------------
  // AH7 — the gate table, and the classification flips vs the control floor.
  // ------------------------------------------------------------------
  std::printf("\n===== AH7 — FULL GATE TABLE (disarmed vs ARMED) =====\n");
  std::printf("  rung |     vf | disarmed          | ARMED             | "
              "margin rel delta\n");
  const std::size_t n = std::min(off.rungs.size(), on.rungs.size());
  int flips = 0;
  for (std::size_t i = 0; i < n; ++i) {
    const Rung& a = off.rungs[i];
    const Rung& b = on.rungs[i];
    const double mrel = (std::isfinite(a.margin) && a.margin != 0.0)
                            ? std::fabs(b.margin - a.margin) / std::fabs(a.margin)
                            : 0.0;
    const bool flip = std::string(verdict(a)) != verdict(b);
    if (flip) ++flips;
    std::printf("   %zu   | %.4f | %-6s %10.6f | %-6s %10.6f | %.3e%s\n", i,
                a.vf, verdict(a), a.margin, verdict(b), b.margin, mrel,
                flip ? "   *** VERDICT FLIP ***" : "");
  }
  if (off.rungs.size() != on.rungs.size())
    std::printf("  *** RUNG COUNT DIFFERS: disarmed %zu vs ARMED %zu ***\n",
                off.rungs.size(), on.rungs.size());
  std::printf("\n  VERDICT FLIPS: %d%s\n", flips,
              flips ? "   <<< BLOCKED-STOP >>>" : "   (none — the gate is clean)");

  // Classification flips over the SOLID voxels of the solved grid, with the
  // negative control FIRST so the reader sees the floor before the signal.
  auto flip_frac = [&](const std::vector<double>& a, const std::vector<double>& b,
                       const std::vector<char>& solid, long long& ns,
                       long long& fl) {
    ns = 0;
    fl = 0;
    const std::size_t m = std::min(std::min(a.size(), b.size()), solid.size());
    for (std::size_t e = 0; e < m; ++e) {
      if (!solid[e]) continue;
      ++ns;
      if ((a[e] > 0.5) != (b[e] > 0.5)) ++fl;
    }
    return ns ? static_cast<double>(fl) / static_cast<double>(ns) : 0.0;
  };
  std::printf("\n  classification flips over solid voxels (grid %dx%dx%d):\n",
              off.solved_nx, off.solved_ny, off.solved_nz);
  std::printf("  rung |  solid  | NEG CONTROL 1e-9 (the floor)      | ARMED vs "
              "disarmed\n");
  const std::size_t nc = std::min(n, ctl.rungs.size());
  for (std::size_t i = 0; i < nc; ++i) {
    long long s1 = 0, f1 = 0, s2 = 0, f2 = 0;
    const double fr_ctl =
        flip_frac(off.rungs[i].density, ctl.rungs[i].density, off.solid, s1, f1);
    const double fr_on =
        flip_frac(off.rungs[i].density, on.rungs[i].density, off.solid, s2, f2);
    const Delta dc = compare(off.rungs[i].density, ctl.rungs[i].density);
    const Delta dn = compare(off.rungs[i].density, on.rungs[i].density);
    std::printf("   %zu   | %7lld | %.3e (%lld) drho %.1e/%.1e | %.3e (%lld) "
                "drho %.1e/%.1e%s\n",
                i, s1, fr_ctl, f1, dc.mean_abs, dc.max_abs, fr_on, f2,
                dn.mean_abs, dn.max_abs,
                fr_on > fr_ctl ? "  ABOVE FLOOR" : "  within floor");
  }

  // ------------------------------------------------------------------
  // AH11 — wall, with the honest caveat attached.
  // ------------------------------------------------------------------
  std::printf("\n===== AH11 — WALL (host load recorded; CG is the "
              "load-independent currency) =====\n");
  std::printf("  disarmed %.1f s, %lld CG   ->   ARMED %.1f s, %lld CG   "
              "(wall %.3fx, CG %.3fx)\n",
              off.wall, off.cg, on.wall, on.cg,
              off.wall > 0 ? on.wall / off.wall : 0.0,
              off.cg ? static_cast<double>(on.cg) / static_cast<double>(off.cg)
                     : 0.0);

  const std::string csv = dir + "/gate.csv";
  if (FILE* fp = std::fopen(csv.c_str(), "w")) {
    std::fprintf(fp, "rung,vf,off_verdict,on_verdict,off_margin,on_margin,"
                     "margin_rel_delta,off_compliance,on_compliance,"
                     "mean_abs_drho,max_abs_drho,ctl_flip_frac,on_flip_frac,"
                     "verdict_flip\n");
    for (std::size_t i = 0; i < n; ++i) {
      const Rung& a = off.rungs[i];
      const Rung& b = on.rungs[i];
      const Delta d = compare(a.density, b.density);
      long long s1 = 0, f1 = 0, s2 = 0, f2 = 0;
      const double fr_ctl =
          i < ctl.rungs.size()
              ? flip_frac(a.density, ctl.rungs[i].density, off.solid, s1, f1)
              : 0.0;
      const double fr_on = flip_frac(a.density, b.density, off.solid, s2, f2);
      const double mrel = (std::isfinite(a.margin) && a.margin != 0.0)
                              ? std::fabs(b.margin - a.margin) / std::fabs(a.margin)
                              : 0.0;
      std::fprintf(fp, "%zu,%.4f,%s,%s,%.10g,%.10g,%.6e,%.10g,%.10g,%.6e,%.6e,"
                       "%.6e,%.6e,%d\n",
                   i, a.vf, verdict(a), verdict(b), a.margin, b.margin, mrel,
                   a.compliance, b.compliance, d.mean_abs, d.max_abs, fr_ctl,
                   fr_on, std::string(verdict(a)) != verdict(b) ? 1 : 0);
    }
    std::fclose(fp);
    std::printf("\nwrote %s\n", csv.c_str());
  }
  const std::string sum = dir + "/gate_summary.csv";
  if (FILE* fp = std::fopen(sum.c_str(), "w")) {
    std::fprintf(fp, "posture,rungs,cg,solves,stagnating,latched,wall_s,"
                     "geneo_builds,geneo_refreshes,geneo_armed,geneo_declined,"
                     "recycled_solves,alg_aggregates,alg_coarse_dim,alg_levels,"
                     "alg_added_mb\n");
    auto row = [&](const char* nm, const LadderResult& R) {
      std::fprintf(fp, "%s,%zu,%lld,%lld,%d,%d,%.3f,%lld,%lld,%lld,%lld,%lld,"
                       "%d,%d,%d,%.3f\n",
                   nm, R.rungs.size(), R.cg, R.solves, R.stagnating_solves,
                   R.latched ? 1 : 0, R.wall, R.geneo_builds, R.geneo_refreshes,
                   R.geneo_armed, R.geneo_declined, R.recycled_solves,
                   R.alg_aggregates, R.alg_coarse_dim, R.alg_levels,
                   R.alg_added_mb);
    };
    row("control_1e-9", ctl);
    row("disarmed", off);
    row("armed", on);
    std::fclose(fp);
    std::printf("wrote %s\n", sum.c_str());
  }

  print_load("end");
  return flips == 0 ? 0 : 1;
}
