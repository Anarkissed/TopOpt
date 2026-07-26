// active_domain_escape.cpp — the feasibility measurement for the ACTIVE DOMAIN
// escape-latch amendment (docs/handoffs/2026-07-25-ad-escape-latch.md). NOT a CI
// test; standalone, like its neighbours active_domain_gate.cpp /
// active_domain_probe.cpp, and built from the PUBLIC topopt API + the read-only
// 117 observability hooks. NO production code is changed by this file.
//
// THE FINDING IT RECORDS. PR 168 (active-domain phase 1) shipped a restricted-
// analysis mask, default OFF. Its growth-invariant measurement found 0 escapes on
// a healthy trajectory and 6 979 on a stagnating one. An "escape" is an element
// OUTSIDE the active band that takes material — material the mask silently
// suppresses, so the design diverges from the full-domain answer with nothing
// saying so. The escape-latch amendment asks for a per-run latch that trips on the
// FIRST escape and reverts to the full domain.
//
// The prerequisite was a DETECTOR that fires on the LIVE restricted path without
// the full-domain work the band exists to avoid. The initial hypothesis was that
// this is impossible (the restriction zeroes out-of-band sensitivities, so the
// design can never grow there and the escape is only a full-domain counterfactual
// — a Blocked outcome). THIS HARNESS MEASURED THAT HYPOTHESIS AND REFUTED IT: on
// the stagnating fixture the LIVE restricted trajectory escapes its own band 8 114
// times (more than the 6 979 full-domain counterfactual), because the density
// filter (radius rmin) spreads in-band growth past the band edge and the mask
// self-heals a step too late. So the escape IS visible on the live field the
// optimizer already produces, the detector is a single O(N) scan, and the latch
// is BUILDABLE. The latch shipped in simp.cpp; this harness now measures its
// production behaviour on the two fixtures:
//
//   [FULL]  the counterfactual escapes on the band=0 reference (reproduces 168).
//   [B2/B3] the PRODUCTION band=4 run with the escape latch ON: healthy never
//           latches; stagnation latches at the first live escape and reverts.
//   [B5]    the drho between the production field entering the latch iteration and
//           the full-domain reference there — the damage done before detection.
//   [B6]    the detector's own O(N) cost, timed directly, as a % of one solve.
//   DISTANCE the shell histogram of the full-domain escapes — why a cheap
//           'boundary shell' detector could not have worked and the whole-field
//           scan is the right one.
//
// Build (standalone; NOT wired into CTest):
//   c++ -std=c++17 -O2 -I core/include -I /opt/homebrew/include/eigen3 \
//     -DSETTINGS_RULES_PATH="\"$PWD/core/src/settings/rules.json\"" \
//     core/tests/harness/active_domain_escape.cpp build/libtopopt.a -o /tmp/ade
// Run (TOPOPT_AD_DIR selects the evidence directory; default ./ad_escape):
//   escape [healthy_iters] [stag_iters]   the whole measurement (default 60 40)
//   healthy [iters] | stag [.. ..]        one fixture only
//   cost                                  isolated back-to-back solve timing

#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <string>
#include <vector>

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

constexpr double kRhoMin = 1e-3;
constexpr double kThresh = 1.5 * kRhoMin;  // the mask's core rule, verbatim

std::string evidence_dir() {
  const char* d = std::getenv("TOPOPT_AD_DIR");
  return d ? std::string(d) : std::string("ad_escape");
}

Material fdm_material() {
  Material m;
  m.youngs_modulus_mpa = 3500.0;
  m.yield_strength_mpa = 55.0;
  m.density_g_cm3 = 1.24;
  m.z_knockdown = 0.55;
  m.poisson = 0.33;
  m.family = "fdm";
  return m;
}

// The thin L-bracket of handoff 134's probe, verbatim (identical to
// active_domain_gate.cpp's fixture).
VoxelGrid l_bracket(std::vector<DirichletBC>& bcs, int arm, int span, int ny,
                    int t, double h) {
  VoxelGrid g;
  g.nx = span; g.ny = ny; g.nz = arm; g.spacing = h;
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
        if (!solid(i-1,j,k)||!solid(i+1,j,k)||!solid(i,j-1,k)||!solid(i,j+1,k)||
            !solid(i,j,k-1)||!solid(i,j,k+1))
          g.set_tag(i, j, k, VoxelTag::Surface);
      }
  for (int j = 0; j < ny; ++j)
    for (int i = 0; i < t; ++i) g.set_tag(i, j, arm - 1, VoxelTag::Fixture);
  bcs.clear();
  for (int b = 0; b <= ny; ++b)
    for (int a = 0; a <= t; ++a) {
      const int node = fea_node_index(g, a, b, arm);
      bcs.push_back({node, 0, 0.0});
      bcs.push_back({node, 1, 0.0});
      bcs.push_back({node, 2, 0.0});
    }
  for (int k = 0; k < t; ++k)
    for (int j = 0; j < ny; ++j) g.set_tag(span - 1, j, k, VoxelTag::Load);
  return g;
}

struct Fixture {
  std::string name;
  VoxelGrid part;
  std::vector<DirichletBC> bcs;
  std::vector<NodalLoad> loads;
  DesignBox box;
};

// HEALTHY — the gate fixture: 32x24x32 = 24 576 elements, 46.5x dilution,
// multigrid carried on every solve. 168 measured 0 escapes here.
Fixture make_healthy() {
  Fixture f;
  f.name = "healthy_24576";
  f.part = l_bracket(f.bcs, /*arm*/ 14, /*span*/ 14, /*ny*/ 4, /*t*/ 6, /*h*/ 1.0);
  f.loads = traction_loads(f.part, VoxelTag::Load, Vec3{0.0, 0.0, -30.0});
  f.box.min = Vec3{-9.0, -10.0, -9.0};
  f.box.max = Vec3{23.0, 14.0, 23.0};
  return f;
}

// STAGNATION — the §7 regime: a larger box on a larger bracket, where the
// production multigrid stagnates, the objective diverges, and 168 measured
// thousands of full-domain escapes. Dims match the campaign that reproduced §7.
Fixture make_stagnation() {
  Fixture f;
  f.name = "stagnation";
  f.part = l_bracket(f.bcs, /*arm*/ 18, /*span*/ 18, /*ny*/ 5, /*t*/ 6, /*h*/ 1.0);
  f.loads = traction_loads(f.part, VoxelTag::Load, Vec3{0.0, 0.0, -30.0});
  f.box.min = Vec3{-11.0, -11.5, -11.0};
  f.box.max = Vec3{29.0, 16.5, 29.0};
  return f;
}

MinimizePlasticOptions base_options(const Fixture& f, int band,
                                    bool full_ladder = false) {
  MinimizePlasticOptions o;
  configure_production_options(o);
  o.volume_fraction_ladder =
      full_ladder ? production_reduction_ladder()
                  : std::vector<double>{production_reduction_ladder()[0]};
  o.margin_stop = 1.5;
  o.external_loads = f.loads;
  o.gravity = 9810.0 * 1e-9;
  o.gravity_direction = Vec3{0.0, 0.0, -1.0};
  o.infill_percent = 100.0;
  o.design_box = f.box;
  o.simp.active_domain_band = band;
  return o;
}

// [B2] Reproduce 168's ARMED gate run EXACTLY (full ladder, plateau + margin_stop
// as configure_production_options leaves them, band=4) and print the per-rung
// compliance/fraction the escape-latch amendment must not perturb. 168 committed
// these to gate/gate.csv + gate/on_run_info.json:
//   rung 0: on_compliance 4.63896055541, fraction_mean 0.4169650608, latched 0
//   rung 1: on_compliance 8.72664102474, fraction_mean 0.3943853269, latched 0
// The escape latch is read-only until it fires and never fires on this healthy
// fixture, so these must come back BIT-FOR-BIT.
void measure_gate168(const Fixture& f, const SettingsRules& rules,
                     const Material& material) {
  std::printf("\n===== [B2] 168 ARMED gate reproduction (band=4, full ladder) on "
              "%s =====\n", f.name.c_str());
  MinimizePlasticOptions o = base_options(f, 4, /*full_ladder=*/true);
  const MinimizePlasticResult r =
      minimize_plastic(f.part, material, "fdm", f.bcs, rules, o);
  std::printf("  rung | compliance          | fraction_mean | latched | "
              "escape_count\n");
  for (std::size_t i = 0; i < r.evaluated.size(); ++i) {
    const SimpOptimizeResult& opt = r.evaluated[i].optimization;
    std::printf("   %2zu  | %.17g | %.10f  |   %d     | %lld\n", i, opt.compliance,
                opt.active_fraction_mean, opt.active_domain_latched ? 1 : 0,
                opt.active_domain_escape_count);
  }
  std::printf("  168 committed: rung0 compliance 4.63896055541 fraction 0.4169650608; "
              "rung1 8.72664102474 fraction 0.3943853269 (both latched=0)\n");
  std::printf("  >>> BIT-IDENTICAL to those = the escape latch left the healthy "
              "armed run untouched (B2).\n");
}

// One fixed-length rung-0 trajectory, capturing the physical density every
// iteration (the field the mask and the escape test read). The 086 plateau and
// change-stop are disarmed so ON and OFF walk the SAME number of steps.
struct Trajectory {
  std::vector<std::vector<double>> field;  // per iteration, physical density
  double wall = 0.0;
  long long cg = 0;
  int latched_at = 0;              // active_domain_latch_iteration (0 = never)
  bool latched = false;
  long long escape_count = 0;      // escapes at the moment the escape latch fired
  std::string latch_reason;
};

Trajectory run_traj(const Fixture& f, int band, int iters,
                    const SettingsRules& rules, const Material& material) {
  MinimizePlasticOptions o = base_options(f, band);
  o.simp.mma_plateau_window = 0;
  o.simp.change_tol = 0.0;
  o.simp.max_iterations = iters;
  Trajectory t;
  o.on_iteration = [&](std::size_t, std::size_t, const SimpIterationObservation& obs) {
    t.cg += obs.cg_iterations;
  };
  o.on_density_snapshot = [&](const DensitySnapshotEvent& ev) {
    if (!ev.density || ev.boundary) return;
    t.field.push_back(*ev.density);
  };
  const auto t0 = std::chrono::steady_clock::now();
  const MinimizePlasticResult r =
      minimize_plastic(f.part, material, "fdm", f.bcs, rules, o);
  t.wall = std::chrono::duration<double>(std::chrono::steady_clock::now() - t0).count();
  // The 168 degeneracy latch (>=85% for 5 iters) reports through the result; a
  // run that latched there is not a clean band trajectory and we say so.
  if (!r.evaluated.empty()) {
    const SimpOptimizeResult& opt = r.evaluated.front().optimization;
    t.latched = opt.active_domain_latched;
    t.latched_at = opt.active_domain_latch_iteration;
    t.escape_count = opt.active_domain_escape_count;
    t.latch_reason = opt.active_domain_latch_reason;
  }
  return t;
}

// Count escapes on a trajectory by 168's growth-invariant definition: derive the
// band from the analysis grid + the field at iteration i, and count out-of-band
// elements that field i+1 raises above the active threshold. `first_escape` is
// the 1-based iteration index (of field i+1) at which the first escape appears,
// 0 if none.
struct EscapeCount {
  long long total = 0;
  int first_escape_iter = 0;
  double worst_out = 0.0;
};

EscapeCount count_escapes(const VoxelGrid& analysis,
                          const std::vector<std::vector<double>>& field,
                          int band) {
  EscapeCount ec;
  for (std::size_t i = 0; i + 1 < field.size(); ++i) {
    const std::vector<char> m = active_domain_mask(analysis, field[i], kRhoMin, band);
    long long here = 0;
    for (std::size_t e = 0; e < field[i + 1].size(); ++e)
      if (field[i + 1][e] > kThresh && m[e] == 0) {
        ++here;
        ec.worst_out = std::max(ec.worst_out, field[i + 1][e]);
      }
    if (here > 0) {
      ec.total += here;
      if (ec.first_escape_iter == 0) ec.first_escape_iter = int(i + 2);  // field i+1
    }
  }
  return ec;
}

// For the full-domain escapes, how far BEYOND the band edge do they land? An
// element out-of-band at width `band` is at Chebyshev distance >= band+1 from the
// core; its shell = (smallest r with mask(field,r)[e]==1) - band. Shell 1 is the
// first out-of-band ring (the only one a boundary-shell detector could see).
// Returns a histogram indexed by shell (index 0 unused), capped at kMaxShell.
constexpr int kMaxShell = 16;
std::vector<long long> escape_shell_histogram(
    const VoxelGrid& analysis,
    const std::vector<std::vector<double>>& field, int band) {
  std::vector<long long> hist(kMaxShell + 2, 0);
  for (std::size_t i = 0; i + 1 < field.size(); ++i) {
    // Which elements escape at i+1 (out-of-band at `band`, above threshold)?
    const std::vector<char> mband = active_domain_mask(analysis, field[i], kRhoMin, band);
    bool any = false;
    for (std::size_t e = 0; e < field[i + 1].size(); ++e)
      if (field[i + 1][e] > kThresh && mband[e] == 0) { any = true; break; }
    if (!any) continue;
    // Grow the band from field[i] and find the shell each escape first enters.
    std::vector<char> covered = mband;  // already covers <= band
    for (int r = band + 1; r <= band + kMaxShell; ++r) {
      const std::vector<char> mr = active_domain_mask(analysis, field[i], kRhoMin, r);
      for (std::size_t e = 0; e < field[i + 1].size(); ++e)
        if (field[i + 1][e] > kThresh && mband[e] == 0 && !covered[e] && mr[e]) {
          ++hist[r - band];
          covered[e] = 1;
        }
    }
    // Anything still uncovered is beyond kMaxShell.
    for (std::size_t e = 0; e < field[i + 1].size(); ++e)
      if (field[i + 1][e] > kThresh && mband[e] == 0 && !covered[e])
        ++hist[kMaxShell + 1];
  }
  return hist;
}

void measure_fixture(const Fixture& f, int iters, const SettingsRules& rules,
                     const Material& material, FILE* csv) {
  std::printf("\n===== FIXTURE %s (%d iterations, rung 0) =====\n",
              f.name.c_str(), iters);
  MinimizePlasticOptions probe = base_options(f, 0);
  const VoxelGrid analysis = minimize_plastic_solved_grid(f.part, probe);
  const double rmin = physical_filter_radius(probe.min_feature_mm, analysis.spacing);
  const int band = active_domain_auto_band(rmin);
  std::printf("  analysis grid %dx%dx%d (%zu elements), dilution %.1fx, "
              "rmin=%.3f, auto band=%d\n",
              analysis.nx, analysis.ny, analysis.nz, analysis.solid_count(),
              double(analysis.solid_count()) / double(f.part.solid_count()),
              rmin, band);

  std::printf("  running FULL-domain (band=0) reference trajectory ...\n");
  const Trajectory full = run_traj(f, 0, iters, rules, material);
  std::printf("    %zu iterations captured, %.1f s, %lld CG\n",
              full.field.size(), full.wall, full.cg);
  std::printf("  running PRODUCTION (band=%d, escape latch ON) trajectory ...\n", band);
  const Trajectory prod = run_traj(f, band, iters, rules, material);
  std::printf("    %zu iterations captured, %.1f s, %lld CG\n",
              prod.field.size(), prod.wall, prod.cg);

  // [FULL] the counterfactual escapes (168's growth-invariant definition on the
  // full-domain trajectory) — the material the optimizer would want outside the
  // band. Reproduces 168: 0 on a healthy run, thousands on a stagnating one.
  const EscapeCount ef = count_escapes(analysis, full.field, band);
  std::printf("\n  --- [FULL] counterfactual escapes (168 growth invariant) ---\n");
  std::printf("    %lld escapes, first at iter %d, worst out-of-band rho %.6f\n",
              ef.total, ef.first_escape_iter, ef.worst_out);

  // [B2 / B3] THE PRODUCTION LATCH OUTCOME. The escape latch reads the live field
  // and the stored previous band — no full-domain solve — and trips on the first
  // escape. Healthy: never fires (byte-identity checked separately against 168).
  // Stagnation: fires at the first live escape and reverts to the full domain.
  std::printf("\n  --- [B2/B3] PRODUCTION escape latch (live detection) ---\n");
  if (prod.latched) {
    std::printf("    LATCHED at iteration %d, escape_count=%lld\n",
                prod.latched_at, prod.escape_count);
    std::printf("    reason: %s\n", prod.latch_reason.c_str());
  } else {
    std::printf("    never latched over %zu iterations (escape_count=%lld) — the "
                "band held; run stays byte-identical to 168's armed mask\n",
                prod.field.size(), prod.escape_count);
  }

  // [B5] CHARGE THE DAMAGE. If the latch fired at Lit, the design entering Lit had
  // already been moved by the (Lit-1) restricted steps before detection. Report
  // the drho between the production field entering the latch iteration and the
  // full-domain reference at the same point. No pass threshold — the bar is that
  // it is measured and printed.
  double b5_mean = 0.0, b5_max = 0.0;
  int b5_iter = 0;
  if (prod.latched && prod.latched_at >= 2) {
    // Field ENTERING iteration Lit = the field after (Lit-1) updates = index Lit-2.
    const std::size_t idx = static_cast<std::size_t>(prod.latched_at) - 2;
    if (idx < prod.field.size() && idx < full.field.size()) {
      b5_iter = prod.latched_at;
      const std::size_t m = std::min(prod.field[idx].size(), full.field[idx].size());
      for (std::size_t e = 0; e < m; ++e) {
        const double d = std::fabs(prod.field[idx][e] - full.field[idx][e]);
        b5_mean += d;
        b5_max = std::max(b5_max, d);
      }
      if (m > 0) b5_mean /= double(m);
    }
  }
  std::printf("\n  --- [B5] damage before detection (drho vs full domain at the "
              "latch iteration) ---\n");
  if (b5_iter > 0)
    std::printf("    at iteration %d: mean|drho|=%.6e, max|drho|=%.6e  "
                "(134's OC-based estimate was mean|drho| ~3.6e-6)\n",
                b5_iter, b5_mean, b5_max);
  else
    std::printf("    (no escape latch fired on this fixture — no damage to charge)\n");

  // [B6] DETECTION COST. The detector is a single O(N) scan of the live field
  // against the stored previous mask. Time it directly and compare to one solve.
  const std::vector<double>& probe_field =
      prod.field.empty() ? full.field.front() : prod.field.front();
  const std::vector<char> probe_mask =
      active_domain_mask(analysis, probe_field, kRhoMin, band);
  const int reps = 2000;
  const auto d0 = std::chrono::steady_clock::now();
  volatile long long sink = 0;
  for (int r = 0; r < reps; ++r)
    sink += active_domain_escape_count(analysis, probe_field, probe_mask, kRhoMin);
  const double det_s =
      std::chrono::duration<double>(std::chrono::steady_clock::now() - d0).count() / reps;
  (void)sink;
  const double solve_s =
      full.wall / double(std::max<std::size_t>(1, full.field.size()));
  std::printf("\n  --- [B6] DETECTION COST (the live O(N) scan, %d reps) ---\n", reps);
  std::printf("    detector %.3e s/iter, solve %.3e s/iter -> %.4f%% of one solve\n",
              det_s, solve_s, solve_s > 0 ? 100.0 * det_s / solve_s : 0.0);

  // DISTANCE — shell histogram of the full-domain escapes (kept as context: it is
  // why a cheap 'boundary shell' detector could NOT have worked, and why the
  // whole-field O(N) scan is the right detector).
  const std::vector<long long> hist = escape_shell_histogram(analysis, full.field, band);
  long long tot = 0;
  for (long long h : hist) tot += h;
  std::printf("\n  --- FULL-domain escape DISTANCE beyond band edge (shells) ---\n");
  if (tot == 0) {
    std::printf("    (no full-domain escapes to bin)\n");
  } else {
    for (int s = 1; s <= kMaxShell + 1; ++s)
      if (hist[s] > 0)
        std::printf("    shell %2d %s: %lld (%.1f%%)\n", s,
                    s > kMaxShell ? "+" : " ", hist[s],
                    100.0 * double(hist[s]) / double(tot));
    std::printf("    beyond the first shell: %.1f%% — a boundary-shell detector "
                "would miss them; the O(N) whole-field scan does not\n",
                100.0 * double(tot - hist[1]) / double(tot));
  }

  if (csv)
    std::fprintf(csv,
                 "%s,%d,%zu,%lld,%d,%d,%d,%lld,%.6e,%.6e,%.4e,%.4e\n",
                 f.name.c_str(), band, analysis.solid_count(), ef.total,
                 ef.first_escape_iter, prod.latched ? 1 : 0, prod.latched_at,
                 prod.escape_count, b5_mean, b5_max, det_s, solve_s);
}

// COST — a crisp back-to-back full vs restricted solve on the SAME field, to
// confirm the trajectory-derived per-iteration cost with an isolated timing.
void measure_cost(const Fixture& f, const SettingsRules& rules,
                  const Material& material) {
  std::printf("\n===== COST (isolated back-to-back solve on a mid-trajectory field) "
              "on %s =====\n", f.name.c_str());
  MinimizePlasticOptions o = base_options(f, 0);
  const VoxelGrid g = minimize_plastic_solved_grid(f.part, o);
  const double rmin = physical_filter_radius(o.min_feature_mm, g.spacing);
  const int band = active_domain_auto_band(rmin);
  const DensityFilter filter = make_density_filter(g, rmin);

  // A representative mid-trajectory field: 20 quick full-domain iterations.
  Trajectory warm = run_traj(f, 0, 20, rules, material);
  const std::vector<double>& xphys = warm.field.back();

  SimpParams params;
  params.youngs_modulus = material.youngs_modulus_mpa;
  params.poisson = material.poisson;
  params.penalty = 3.0;
  params.density_min = kRhoMin;
  const SolverKind kind = SolverKind::MultigridCG_Matfree;
  const double tol = 1e-8;
  const std::vector<char> mask = active_domain_mask(g, xphys, kRhoMin, band);

  auto timed = [&](const std::vector<char>* m) {
    const auto t0 = std::chrono::steady_clock::now();
    SimpCompliance c = simp_compliance(g, params, xphys, f.bcs, f.loads, tol, 0,
                                       nullptr, nullptr, kind, m);
    const double w =
        std::chrono::duration<double>(std::chrono::steady_clock::now() - t0).count();
    std::printf("    %-11s wall %.4f s, %d CG iters, mg=%d\n",
                m ? "restricted" : "full", w, c.cg.iterations, c.cg.used_multigrid);
    return w;
  };
  // Warm both paths once (matfree hierarchy allocation), then time.
  timed(nullptr); timed(&mask);
  const double wf = timed(nullptr);
  const double wr = timed(&mask);
  long long active = 0;
  for (char v : mask) active += v ? 1 : 0;
  std::printf("    active fraction %.3f; a cadence-1 full audit adds a FULL solve "
              "(%.2fx the restricted solve) to every iteration\n",
              double(active) / double(std::max<std::size_t>(1, g.solid_count())),
              wr > 0 ? wf / wr : 0.0);
}

}  // namespace

int main(int argc, char** argv) {
  std::setvbuf(stdout, nullptr, _IOLBF, 0);
  const std::string mode = argc > 1 ? argv[1] : "escape";

  SettingsRules rules;
  try {
    rules = load_settings_rules_file(SETTINGS_RULES_PATH);
  } catch (const std::exception& e) {
    std::fprintf(stderr, "FAIL: rules.json: %s\n", e.what());
    return 1;
  }
  const Material material = fdm_material();
  std::printf("matfree threads = %d\n", fea_matfree_thread_count());

  if (mode == "cost") {
    measure_cost(make_healthy(), rules, material);
    measure_cost(make_stagnation(), rules, material);
    return 0;
  }

  if (mode == "gate168") {
    measure_gate168(make_healthy(), rules, material);
    return 0;
  }

  const int healthy_iters = argc > 2 ? std::atoi(argv[2]) : 60;
  const int stag_iters = argc > 3 ? std::atoi(argv[3]) : 40;

  const std::string dir = evidence_dir();
  const std::string csv_path = dir + "/escape_summary.csv";
  FILE* csv = std::fopen(csv_path.c_str(), "w");
  if (csv)
    std::fprintf(csv,
                 "fixture,band,elements,full_counterfactual_escapes,"
                 "full_first_iter,prod_latched,prod_latch_iter,prod_escape_count,"
                 "b5_mean_drho,b5_max_drho,detector_s_per_iter,solve_s_per_iter\n");

  if (mode == "escape" || mode == "healthy")
    measure_fixture(make_healthy(), healthy_iters, rules, material, csv);
  if (mode == "escape" || mode == "stag")
    measure_fixture(make_stagnation(), stag_iters, rules, material, csv);

  if (csv) { std::fclose(csv); std::printf("\nwrote %s\n", csv_path.c_str()); }
  return 0;
}
