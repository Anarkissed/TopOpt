// multiscale_to_probe — THE ACCELERATORS, THE COST AND THE DETERMINISM OF A
// MULTISCALE DESIGN LOOP (task multiscale-lattice-to, bars M6 / M7 / M8).
//
// PR 252 measured the cubic operator on ONE fixture, held still. A design loop
// changes the operator EVERY iteration: the three per-voxel cubic fields move
// with the density, so every accelerator that caches anything keyed on the
// operator is being asked a question PR 252 never asked it. This probe asks it.
//
// The production library is linked UNMODIFIED; nothing here is armed and no
// default changes. It drives the SAME public entry points a production run does
// (simp_optimize with SimpParams::lattice_material set), so what it measures is
// what a run pays.
//
//   m6  — CG counts and wall PER DESIGN ITERATION with the production stack
//         (matrix-free multigrid first, GenEO deflation on the Jacobi fallback,
//         Krylov recycling), multiscale vs the classic penalized loop; plus
//         multigrid engagement per iteration.
//   fp  — GENEO'S CUBIC FINGERPRINT, IN A LOOP. PR 257 fixed moduli_fingerprint
//         to hash the three cubic fields and the mask, and proved it on a
//         two-solve negative control. The loop question is different and
//         stronger: with the design moving every iteration, does every engaged
//         solve REFRESH the coarse operator (action 2/3) rather than silently
//         reuse a stale one (action 1)? And — the discriminating half, without
//         which "always refreshes" would be vacuous — does an UNCHANGED design
//         still reuse?
//   m7  — COST: DOF-weighted work (matvecs * free DOFs) and wall per design
//         iteration, multiscale vs two-step, on the same fixture and the same
//         iteration count. Reports the NET, which is what the maintainer pays,
//         against PR 252's ~2.4-2.7x per-apply expectation.
//   m8  — DETERMINISM: two identical runs produce bit-identical density fields,
//         compliance histories and CG counts.
//
// Build (from the repo root; machine of record Apple M2 Pro, Apple clang):
//   c++ -std=c++17 -O2 -I core/include -I core/src \
//       core/tests/harness/multiscale_to_probe.cpp build/libtopopt.a \
//       -o build/multiscale_to_probe
//   ./build/multiscale_to_probe [m6|fp|m7|m8|all] [evidence-dir]

#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <string>
#include <vector>

#include "topopt/fea.hpp"
#include "topopt/lattice.hpp"
#include "topopt/lattice_material.hpp"
#include "topopt/production.hpp"
#include "topopt/simp.hpp"
#include "topopt/voxel.hpp"

#include "fea/geneo.hpp"  // GeneoProbeConfig — harness-only gate override

using namespace topopt;

namespace {

int g_fail = 0;
void check(bool ok, const char* msg) {
  std::printf("  [%s] %s\n", ok ? "PASS" : "FAIL", msg);
  if (!ok) ++g_fail;
}

double now_ms() {
  return std::chrono::duration<double, std::milli>(
             std::chrono::steady_clock::now().time_since_epoch())
      .count();
}

// FNV-1a over a double field — the repo's evidence fingerprint.
std::uint64_t fnv(const std::vector<double>& v) {
  std::uint64_t h = 1469598103934665603ULL;
  const unsigned char* p = reinterpret_cast<const unsigned char*>(v.data());
  for (std::size_t i = 0; i < v.size() * sizeof(double); ++i) {
    h ^= p[i];
    h *= 1099511628211ULL;
  }
  return h;
}

// The fixture: a cantilever sized so the multigrid hierarchy is real (every axis
// 2x-divisible to >= 3 levels) and the DOF count is in the same decade as a
// production rung's, so the accelerator behaviour is representative rather than
// a toy. Root face fixed, a downward tip line load at mid-height.
struct Fixture {
  VoxelGrid grid;
  std::vector<DirichletBC> bcs;
  std::vector<NodalLoad> loads;
  std::vector<char> region;  // every design voxel is latticed
};

Fixture make_cantilever(int nx, int ny, int nz, double spacing) {
  Fixture F;
  VoxelGrid& g = F.grid;
  g.nx = nx; g.ny = ny; g.nz = nz;
  g.spacing = spacing;
  g.origin = Vec3{0, 0, 0};
  g.tags.assign(static_cast<std::size_t>(nx) * ny * nz, VoxelTag::Interior);
  for (int k = 0; k < nz; ++k)
    for (int j = 0; j < ny; ++j) {
      const int n = fea_node_index(g, 0, j, k);
      for (int c = 0; c < 3; ++c) F.bcs.push_back({n, c, 0.0});
    }
  const int kmid = nz / 2;
  for (int j = 0; j <= ny; ++j)
    F.loads.push_back({fea_node_index(g, nx, j, kmid), 2, -200.0});
  F.region.assign(g.tags.size(), 1);
  return F;
}

SimpParams base_params(const LatticeMaterialModel* m,
                       const std::vector<char>* region) {
  SimpParams p;
  p.youngs_modulus = 3500.0;
  p.poisson = 0.33;
  p.penalty = 3.0;
  p.lattice_material = m;
  p.lattice_region = region;
  return p;
}

// One design loop, instrumented per iteration. `model == nullptr` is the classic
// penalized (two-step) loop; non-null is multiscale.
struct IterRow {
  int iteration = 0;
  double compliance = 0.0;
  int cg_iterations = 0;
  int used_multigrid = 0;
  int geneo_action = 0;
  int geneo_dim = 0;
  double solve_ms = 0.0;
  double sens_ms = 0.0;
  double total_ms = 0.0;
  long long matvecs = 0;
};

struct RunOut {
  std::vector<IterRow> rows;
  std::vector<double> density;
  double wall_ms = 0.0;
  long long free_dofs = 0;
};

RunOut design_loop(const Fixture& F, const LatticeMaterialModel* model,
                   int iterations, double vf, bool production_stack) {
  RunOut out;
  SimpOptions o;
  o.volume_fraction = vf;
  o.max_iterations = iterations;
  o.change_tol = 0.0;  // never stop early: every run does the SAME work
  o.filter_radius = 1.5;
  o.cg_tolerance = 1e-6;
  o.solver = production_stack ? SolverKind::MultigridCG_Matfree
                              : SolverKind::JacobiCG;
  long long last_matvecs = 0;
  double last_ms = now_ms();
  o.observe = [&](const SimpIterationObservation& obs) {
    IterRow r;
    r.iteration = obs.iteration;
    r.compliance = obs.compliance;
    r.cg_iterations = obs.cg_iterations;
    r.used_multigrid = obs.cg_used_multigrid ? 1 : 0;
    r.geneo_action = obs.cg_geneo_action;
    r.geneo_dim = obs.cg_geneo_dim;
    r.solve_ms = obs.phases.fea_ms;
    r.sens_ms = obs.phases.sens_ms;
    const double t = now_ms();
    r.total_ms = t - last_ms;
    last_ms = t;
    const long long mv = fea_matvec_count();
    r.matvecs = mv - last_matvecs;
    last_matvecs = mv;
    out.rows.push_back(r);
  };
  const SimpParams p = base_params(model, model ? &F.region : nullptr);
  fea_matvec_count_reset();
  fea_reset_krylov_recycle_space();
  fea_matfree_reset_mg_stagnation_latch();
  const double t0 = now_ms();
  const SimpOptimizeResult r =
      simp_optimize(F.grid, p, F.bcs, F.loads, o);
  out.wall_ms = now_ms() - t0;
  out.density = r.physical_density;
  return out;
}

void write_rows(const std::string& path, const char* label,
                const std::vector<IterRow>& rows) {
  if (path.empty()) return;
  std::FILE* f = std::fopen(path.c_str(), "w");
  if (!f) return;
  std::fprintf(f,
               "run,iteration,compliance,cg_iterations,used_multigrid,"
               "geneo_action,geneo_dim,solve_ms,sensitivity_ms,total_ms,matvecs\n");
  for (const IterRow& r : rows)
    std::fprintf(f, "%s,%d,%.10g,%d,%d,%d,%d,%.4f,%.4f,%.4f,%lld\n", label,
                 r.iteration, r.compliance, r.cg_iterations, r.used_multigrid,
                 r.geneo_action, r.geneo_dim, r.solve_ms, r.sens_ms, r.total_ms,
                 r.matvecs);
  std::fclose(f);
  std::printf("    wrote %s\n", path.c_str());
}

struct Stats {
  int n = 0, min = 0, max = 0;
  double mean = 0.0, total_ms = 0.0;
  long long matvecs = 0;
};
Stats summarize(const std::vector<IterRow>& rows) {
  Stats s;
  if (rows.empty()) return s;
  s.n = static_cast<int>(rows.size());
  s.min = rows[0].cg_iterations;
  s.max = rows[0].cg_iterations;
  double sum = 0.0;
  for (const IterRow& r : rows) {
    s.min = std::min(s.min, r.cg_iterations);
    s.max = std::max(s.max, r.cg_iterations);
    sum += r.cg_iterations;
    s.total_ms += r.total_ms;
    s.matvecs += r.matvecs;
  }
  s.mean = sum / s.n;
  return s;
}

std::string g_ev;
std::string ev(const char* name) { return g_ev.empty() ? "" : g_ev + "/" + name; }

// ── m6 / m7: the loop, multiscale vs two-step, on the production stack ───────
void bar_m6_m7() {
  std::printf("m6_m7 — accelerators and cost in a design loop\n");
  const Fixture F = make_cantilever(64, 16, 32, 1.0);
  const LatticeMaterialModel M =
      build_lattice_material_model(LatticeTopology::Octet, 3500.0, 0.33);
  constexpr int kIters = 40;
  constexpr double kVf = 0.35;

  // The production accelerator stack, armed exactly as configure_production_options
  // arms it — this probe measures what a production run pays, not a bespoke config.
  fea_set_matfree_cubic_lattice(production_matfree_cubic_lattice());
  fea_set_geneo_twolevel(production_geneo_twolevel());
  fea_set_krylov_recycle_dim(production_krylov_recycle_dim());

  const RunOut ms = design_loop(F, &M, kIters, kVf, /*production_stack=*/true);
  const RunOut ts = design_loop(F, nullptr, kIters, kVf, /*production_stack=*/true);

  const Stats sm = summarize(ms.rows), st = summarize(ts.rows);
  std::printf("    grid %dx%dx%d, %d design iterations, vf %.2f\n", F.grid.nx,
              F.grid.ny, F.grid.nz, kIters, kVf);
  std::printf("    %-12s  cg/iter min/mean/max   wall/iter    matvecs/iter\n", "");
  std::printf("    %-12s  %4d /%7.1f /%4d   %8.1f ms  %10.1f\n", "multiscale",
              sm.min, sm.mean, sm.max, sm.total_ms / std::max(1, sm.n),
              static_cast<double>(sm.matvecs) / std::max(1, sm.n));
  std::printf("    %-12s  %4d /%7.1f /%4d   %8.1f ms  %10.1f\n", "two-step",
              st.min, st.mean, st.max, st.total_ms / std::max(1, st.n),
              static_cast<double>(st.matvecs) / std::max(1, st.n));
  const double cg_ratio = st.mean > 0 ? sm.mean / st.mean : 0.0;
  const double wall_ratio = st.total_ms > 0 ? sm.total_ms / st.total_ms : 0.0;
  const double mv_ratio =
      st.matvecs > 0 ? static_cast<double>(sm.matvecs) / st.matvecs : 0.0;
  std::printf("    RATIOS multiscale/two-step: cg %.3fx  matvecs %.3fx  "
              "WALL %.3fx (the NET per design iteration)\n",
              cg_ratio, mv_ratio, wall_ratio);

  int mg_ms = 0, mg_ts = 0;
  for (const IterRow& r : ms.rows) mg_ms += r.used_multigrid;
  for (const IterRow& r : ts.rows) mg_ts += r.used_multigrid;
  std::printf("    multigrid engaged: multiscale %d/%d, two-step %d/%d\n", mg_ms,
              sm.n, mg_ts, st.n);
  check(mg_ms == sm.n,
        "multigrid engages on EVERY multiscale design iteration (the "
        "composite operator does not cost the hierarchy)");
  check(sm.n == kIters && st.n == kIters,
        "both loops ran the full iteration count (like-for-like cost)");
  // PR 252 measured the combined-block apply at 2.4-2.7x the scalar apply. The
  // NET per design iteration is a different (and smaller) number, because the
  // apply is not the whole iteration and the iteration counts differ; both are
  // reported rather than one standing in for the other.
  std::printf("    (PR 252 per-APPLY expectation: 2.4-2.7x; the wall ratio "
              "above is the NET per design ITERATION)\n");

  std::vector<IterRow> all = ms.rows;
  for (IterRow r : ts.rows) { r.iteration = -r.iteration; all.push_back(r); }
  write_rows(ev("m6_loop_multiscale.csv"), "multiscale", ms.rows);
  write_rows(ev("m6_loop_twostep.csv"), "twostep", ts.rows);

  if (!g_ev.empty()) {
    std::FILE* f = std::fopen(ev("m7_cost_summary.csv").c_str(), "w");
    if (f) {
      std::fprintf(f,
                   "run,iterations,cg_min,cg_mean,cg_max,wall_ms_total,"
                   "wall_ms_per_iter,matvecs_total,matvecs_per_iter\n");
      auto row = [&](const char* n, const Stats& s) {
        std::fprintf(f, "%s,%d,%d,%.4f,%d,%.3f,%.3f,%lld,%.1f\n", n, s.n, s.min,
                     s.mean, s.max, s.total_ms, s.total_ms / std::max(1, s.n),
                     s.matvecs, static_cast<double>(s.matvecs) / std::max(1, s.n));
      };
      row("multiscale", sm);
      row("twostep", st);
      std::fclose(f);
      std::printf("    wrote %s\n", ev("m7_cost_summary.csv").c_str());
    }
  }
}

// ── fp: GenEO's cubic fingerprint, in a loop ────────────────────────────────
//
// GenEO only engages on the Jacobi-CG fallback (it exists for the stagnating
// regime), so this bar drives that path directly rather than hoping a healthy
// multigrid run falls into it.
void bar_fingerprint() {
  std::printf("fp — GenEO's cubic moduli fingerprint, in a design loop\n");
  // ODD grid dimensions: the multigrid hierarchy is not built, so every solve
  // goes straight to the matrix-free Jacobi fallback where GenEO lives — the
  // SAME regime the maintainer's 128x31x118 part runs in (its run_info records
  // multigrid engaging on 0 of 400 iterations). test_matfree_cubic section 6
  // uses the same device for the same reason.
  const Fixture F = make_cantilever(33, 9, 17, 1.0);
  const LatticeMaterialModel M =
      build_lattice_material_model(LatticeTopology::Octet, 3500.0, 0.33);

  fea_set_matfree_cubic_lattice(true);
  fea_set_geneo_twolevel(true);
  fea_reset_geneo_basis();
  fea_reset_krylov_recycle_space();
  // Turn the parity pad OFF for this bar only. With it on (the shipped default)
  // an odd axis is rescued and multigrid solves the system, so there is no
  // fallback and GenEO never runs — which is exactly what happened on the first
  // attempt at this bar. Restored at the end.
  const int pad_was = fea_mg_parity_pad_mode();
  fea_set_mg_parity_pad_mode(0);
  // OPEN THE ENGAGEMENT GATE (harness-only, exactly as test_matfree_cubic and
  // test_geneo do). The shipped gate DECLINES a held basis whenever finishing
  // plain is cheaper — which is correct, and is what the production run does —
  // but it would mean the deflation never runs here and the fingerprint question
  // could not be asked at all. The gate decides WHETHER the coarse operator is
  // used; it never decides whether a used one may be STALE, so opening it is the
  // right way to interrogate staleness.
  {
    fea_detail::GeneoProbeConfig cfg;
    cfg.engage_threshold = 0;
    fea_detail::geneo_set_probe_config(cfg);
  }

  // A sequence of DIFFERENT designs. Densities move smoothly so all three cubic
  // fields move on every solve while the DOF set and the lattice mask are
  // untouched — exactly what a design loop does, and exactly the situation a
  // fingerprint blind to the tensors would misread as "nothing changed".
  const std::size_t n = F.grid.tags.size();
  std::vector<double> d(n, 0.35);
  const SimpParams p = base_params(&M, &F.region);
  auto solve = [&]() {
    return simp_compliance(F.grid, p, d, F.bcs, F.loads, 1e-6, 0, nullptr,
                           nullptr, SolverKind::MultigridCG_Matfree);
  };
  std::vector<int> actions;
  for (int it = 0; it < 6; ++it) {
    for (std::size_t e = 0; e < n; ++e)
      d[e] = 0.30 + 0.25 * std::sin(0.01 * static_cast<double>(e) + 0.7 * it);
    const SimpCompliance c = solve();
    actions.push_back(c.cg.geneo_action);
    std::printf("    moving design %d: cg=%d mg=%d geneo_action=%d dim=%d\n", it,
                c.cg.iterations, c.cg.used_multigrid ? 1 : 0, c.cg.geneo_action,
                c.cg.geneo_dim);
  }
  // ... then the SAME design twice. The discriminating half: without it,
  // "always refreshes" would satisfy the bar vacuously.
  const SimpCompliance r1 = solve();
  const SimpCompliance r2 = solve();
  fea_detail::geneo_set_probe_config(fea_detail::GeneoProbeConfig{});
  fea_set_mg_parity_pad_mode(pad_was);
  std::printf("    unchanged design: geneo_action=%d then %d\n",
              r1.cg.geneo_action, r2.cg.geneo_action);
  std::printf("    counters: basis_builds=%lld coarse_refreshes=%lld "
              "armed_solves=%lld declined=%lld\n",
              fea_geneo_basis_builds(), fea_geneo_coarse_refreshes(),
              fea_geneo_armed_solves(), fea_geneo_declined_solves());

  // action codes (fea.hpp): 0 = never engaged / no basis, 1 = REUSE,
  // 2 = coarse REFRESH, 3 = basis (re)BUILT, 4 = memory-refused,
  // 5 = declined by the engagement gate.
  int engaged_moving = 0, silent_reuse_while_moving = 0;
  for (std::size_t i = 0; i < actions.size(); ++i) {
    if (actions[i] == 0 || actions[i] == 4 || actions[i] == 5) continue;
    ++engaged_moving;
    if (actions[i] == 1) ++silent_reuse_while_moving;
  }
  std::printf("    engaged solves on a MOVING design: %d, of which silent "
              "reuse: %d\n", engaged_moving, silent_reuse_while_moving);
  if (engaged_moving == 0) {
    // Reported, never asserted away: a bar cannot be claimed from a run where
    // the mechanism under test never ran.
    std::printf("    NOTE: GenEO never engaged, so the in-loop fingerprint "
                "claim is NOT established by this run.\n");
    check(false,
          "GenEO engaged at least once, so the fingerprint claim is measured "
          "rather than assumed");
  } else {
    check(silent_reuse_while_moving == 0,
          "every engaged solve on a MOVING design REFRESHES or REBUILDS — it "
          "never silently reuses a coarse operator built for a different cubic "
          "field (PR 257's fix, now proven in a loop)");
    check(r1.cg.geneo_action == 1 || r2.cg.geneo_action == 1,
          "an UNCHANGED design REUSES — the fingerprint DISCRIMINATES rather "
          "than refreshing unconditionally");
  }

  if (!g_ev.empty()) {
    std::FILE* f = std::fopen(ev("m6_geneo_fingerprint.csv").c_str(), "w");
    if (f) {
      std::fprintf(f, "solve,design_changed,geneo_action\n");
      for (std::size_t i = 0; i < actions.size(); ++i)
        std::fprintf(f, "%zu,1,%d\n", i, actions[i]);
      std::fprintf(f, "%zu,0,%d\n", actions.size(), r1.cg.geneo_action);
      std::fprintf(f, "%zu,0,%d\n", actions.size() + 1, r2.cg.geneo_action);
      std::fclose(f);
      std::printf("    wrote %s\n", ev("m6_geneo_fingerprint.csv").c_str());
    }
  }
}

// ── sens: the COMPLIANCE sensitivity through the whole loop ─────────────────
//
// test_multiscale_material pins dC/drho (the MODEL's derivative) against central
// differences. This is the stronger, downstream question: does simp_compliance's
// dc/drho_e — the number the OC/MMA updater actually steers on — match central
// differences of simp_compliance's own compliance? A correct model wired to the
// wrong reference block, or a block paired with the wrong component, would pass
// the model bar and fail this one.
//
// Central differences on a SOLVED objective need the solve to be tighter than the
// perturbation's effect, so this runs at 1e-12 with h = 1e-5: the compliance is
// self-adjoint, so dc/drho is exact for the converged field and the residual is
// the solver tolerance, not a discretization error.
void bar_sensitivity() {
  std::printf("sens — dc/drho through simp_compliance vs central differences\n");
  const Fixture F = make_cantilever(8, 4, 4, 1.0);
  const LatticeMaterialModel M =
      build_lattice_material_model(LatticeTopology::Octet, 3500.0, 0.33);
  fea_set_matfree_cubic_lattice(false);  // the assembled reference path
  const SimpParams p = base_params(&M, &F.region);

  // A varied field spanning all three regimes (void bridge, band, solid bridge).
  const std::size_t n = F.grid.tags.size();
  std::vector<double> d(n);
  for (std::size_t e = 0; e < n; ++e)
    d[e] = 0.02 + 0.96 * static_cast<double>(e % 17) / 16.0;

  const double tol = 1e-12;
  const SimpCompliance c0 =
      simp_compliance(F.grid, p, d, F.bcs, F.loads, tol, 0);
  const double h = 1e-5;
  double worst = 0.0, worst_at = 0.0;
  int checked = 0;
  for (std::size_t e = 0; e < n; e += 7) {  // a fixed stride: deterministic sample
    if (d[e] - h <= 0.0 || d[e] + h >= 1.0) continue;
    std::vector<double> dp = d, dm = d;
    dp[e] += h;
    dm[e] -= h;
    const double cp = simp_compliance(F.grid, p, dp, F.bcs, F.loads, tol, 0).compliance;
    const double cm = simp_compliance(F.grid, p, dm, F.bcs, F.loads, tol, 0).compliance;
    const double fd = (cp - cm) / (2 * h);
    const double an = c0.dcompliance[e];
    const double denom = std::max(std::fabs(fd), std::fabs(an));
    const double err = denom > 0.0 ? std::fabs(fd - an) / denom : 0.0;
    if (err > worst) { worst = err; worst_at = d[e]; }
    ++checked;
  }
  std::printf("    %d sampled voxels, worst relative error %.3g (at rho %.4f)\n",
              checked, worst, worst_at);
  check(checked > 0, "the sensitivity sweep sampled at least one voxel");
  // 1e-6 is the honest bar: central differences of a solved objective carry
  // O(h^2) truncation plus the solver's own residual, and h = 1e-5 puts the
  // truncation floor near 1e-10 while the 1e-12 solves contribute ~1e-8.
  check(worst <= 1e-6,
        "simp_compliance's dc/drho matches central differences of its own "
        "compliance on the MULTISCALE path");

  // The classic path, unchanged, measured beside it so the bar is calibrated
  // against a sensitivity nobody doubts.
  const SimpParams pc = base_params(nullptr, nullptr);
  const SimpCompliance k0 = simp_compliance(F.grid, pc, d, F.bcs, F.loads, tol, 0);
  double kworst = 0.0;
  for (std::size_t e = 0; e < n; e += 7) {
    if (d[e] - h <= 0.0 || d[e] + h >= 1.0) continue;
    std::vector<double> dp = d, dm = d;
    dp[e] += h;
    dm[e] -= h;
    const double cp = simp_compliance(F.grid, pc, dp, F.bcs, F.loads, tol, 0).compliance;
    const double cm = simp_compliance(F.grid, pc, dm, F.bcs, F.loads, tol, 0).compliance;
    const double fd = (cp - cm) / (2 * h);
    const double an = k0.dcompliance[e];
    const double den = std::max(std::fabs(fd), std::fabs(an));
    if (den > 0.0) kworst = std::max(kworst, std::fabs(fd - an) / den);
  }
  std::printf("    calibration — the CLASSIC penalized path on the same fixture: "
              "worst %.3g\n", kworst);
}

// ── m8: determinism ─────────────────────────────────────────────────────────
void bar_m8() {
  std::printf("m8 — determinism of the multiscale loop\n");
  const Fixture F = make_cantilever(32, 16, 16, 1.0);
  const LatticeMaterialModel M =
      build_lattice_material_model(LatticeTopology::Octet, 3500.0, 0.33);
  fea_set_matfree_cubic_lattice(production_matfree_cubic_lattice());
  fea_set_geneo_twolevel(production_geneo_twolevel());
  fea_set_krylov_recycle_dim(production_krylov_recycle_dim());

  const RunOut a = design_loop(F, &M, 20, 0.35, true);
  const RunOut b = design_loop(F, &M, 20, 0.35, true);
  const std::uint64_t fa = fnv(a.density), fb = fnv(b.density);
  std::printf("    density FNV: %016llx vs %016llx\n",
              static_cast<unsigned long long>(fa),
              static_cast<unsigned long long>(fb));
  check(fa == fb, "two identical multiscale runs produce the SAME density field");
  bool same_cg = a.rows.size() == b.rows.size();
  bool same_c = same_cg;
  for (std::size_t i = 0; same_cg && i < a.rows.size(); ++i) {
    same_cg = same_cg && a.rows[i].cg_iterations == b.rows[i].cg_iterations;
    same_c = same_c && a.rows[i].compliance == b.rows[i].compliance;
  }
  check(same_cg, "CG iteration counts are identical iteration for iteration");
  check(same_c, "compliance history is identical iteration for iteration");

  // The PROJECTION is deterministic too — the mid-gap tie-break is fixed, so a
  // rerun snaps identically. Checked on the converged field itself.
  std::vector<double> p1 = a.density, p2 = b.density;
  const LatticeProjectionReport r1 =
      lattice_project_field(M, p1, nullptr, 1e-3, 1.0 - 1e-3, 0.0, 0.0);
  const LatticeProjectionReport r2 =
      lattice_project_field(M, p2, nullptr, 1e-3, 1.0 - 1e-3, 0.0, 0.0);
  check(p1 == p2 && r1.volume_delta == r2.volume_delta &&
            r1.projected_lower == r2.projected_lower &&
            r1.projected_upper == r2.projected_upper,
        "the feasible-set projection and its charge are deterministic");

  if (!g_ev.empty()) {
    std::FILE* f = std::fopen(ev("m8_determinism.txt").c_str(), "w");
    if (f) {
      std::fprintf(f,
                   "M8 — DETERMINISM (multiscale design loop, 32x16x16, 20 "
                   "iterations, production stack)\n"
                   "run A density FNV-1a: %016llx\n"
                   "run B density FNV-1a: %016llx\n"
                   "identical: %s\n"
                   "cg counts identical iteration-for-iteration: %s\n"
                   "compliance identical iteration-for-iteration: %s\n"
                   "projection charge identical: dV %.12g vs %.12g, "
                   "lower %zu vs %zu, upper %zu vs %zu\n",
                   static_cast<unsigned long long>(fa),
                   static_cast<unsigned long long>(fb),
                   fa == fb ? "YES" : "NO", same_cg ? "YES" : "NO",
                   same_c ? "YES" : "NO", r1.volume_delta, r2.volume_delta,
                   r1.projected_lower, r2.projected_lower, r1.projected_upper,
                   r2.projected_upper);
      std::fclose(f);
      std::printf("    wrote %s\n", ev("m8_determinism.txt").c_str());
    }
  }
}

}  // namespace

int main(int argc, char** argv) {
  const std::string which = argc > 1 ? argv[1] : "all";
  if (argc > 2) g_ev = argv[2];
  if (which == "all" || which == "m6" || which == "m7") bar_m6_m7();
  if (which == "all" || which == "sens") bar_sensitivity();
  if (which == "all" || which == "fp") bar_fingerprint();
  if (which == "all" || which == "m8") bar_m8();
  std::printf("%s\n", g_fail == 0 ? "ALL PASS" : "FAILURES");
  return g_fail == 0 ? 0 : 1;
}
