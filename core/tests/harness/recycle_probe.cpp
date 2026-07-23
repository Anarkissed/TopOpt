// recycle_probe.cpp — measurement harness (NOT a CI test) for handoff 133:
// KRYLOV SUBSPACE RECYCLING / DEFLATION.
//
// THE GATE, stated before anything was measured (the task's bars):
//   (a) EXACTNESS  — recycled and plain PCG converge to the same answer:
//                    mean|drho| at solver-noise level (<= 1e-4), margins within
//                    0.1%, gate verdicts IDENTICAL. This technique changes the
//                    ROUTE, not the answer; a larger delta means the
//                    implementation is wrong, not that a trade is on offer.
//   (b) PERFORMANCE— >= 15% total-CG-iteration reduction on BOTH regimes:
//                    a healthy-multigrid fixture AND a void-heavy Jacobi-regime
//                    fixture in the stand-class shape. The void number is
//                    reported separately; that is the one that matters.
//   (c) DETERMINISM— twice-run bit-identical designs and iteration histories.
//   (d) HONEST ACCOUNTING — the setup matvecs recycling charges are counted as
//                    work and reported; the per-iteration correction overhead is
//                    measured separately by rc_cost (see the handoff recipe) and
//                    charged in the NET column. Iterations are the deterministic
//                    signal; wall-clock is NOT the claim (handoff 132's finding).
//
// TWO FIXTURES, deliberately chosen to sit in the two regimes handoff 125 named:
//   mg   : the 132 probe's L-bracket at 48 x 16 x 48 — multigrid-COARSENABLE, so
//          MG carries and the V-cycle is the preconditioner recycling wraps.
//   void : the same L-bracket inside a LARGE design box with a clearance hole —
//          the 125/131 stand-class disease (mostly-empty expanse + a hole through
//          a thin part), where the V-cycle stagnates, the 127 latch turns MG off,
//          and the run grinds in Jacobi-CG. That is the 4.5k-44k-iterations-per-
//          solve regime this technique exists for.
// Each fixture asserts its regime (mg_frac) before its numbers are allowed to
// count, so neither table can be silently vacuous.
//
// MODES: baseline (recycling OFF) + a k sweep {8, 16, 24} + a rebuild-cycle sweep
// + the LIFETIME comparison (reset per rung vs carried across rungs and across
// the conditional-projection gray->beta boundary).
//
// Build (standalone; NOT wired into CTest):
//   c++ -std=c++17 -O2 -I include -I /opt/homebrew/opt/eigen/include/eigen3 \
//     -DSETTINGS_RULES_PATH="\"$PWD/src/settings/rules.json\"" \
//     tests/harness/recycle_probe.cpp build/libtopopt.a -o recycle_probe
// Run:  ./recycle_probe mg     (healthy-multigrid regime)
//       ./recycle_probe void   (void-heavy Jacobi regime)

#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>

#include "topopt/coarsen.hpp"
#include "topopt/fea.hpp"
#include "topopt/materials.hpp"
#include "topopt/pipeline.hpp"
#include "topopt/production.hpp"
#include "topopt/settings.hpp"
#include "topopt/simp.hpp"
#include "topopt/voxel.hpp"

// Internal research knob: the Rayleigh-Ritz extraction METRIC (Wang, de Sturler &
// Paulino 2007 density-ratio rescaling). Not public API — the probe reaches into
// the library's internal header deliberately, so the claim "our diagonal
// application already IS the 2007 rescaling" can be measured, not asserted.
#include "recycle.hpp"

using namespace topopt;

namespace {

// The L-bracket the 080/082/ladder gates build, parameterised so this probe can
// run it at a multigrid-capable scale (the tiny variant cannot coarsen).
VoxelGrid l_bracket(std::vector<DirichletBC>& bcs, int arm, int span, int ny,
                    int t, double h, double hole_frac) {
  VoxelGrid g;
  g.nx = span; g.ny = ny; g.nz = arm; g.spacing = h;
  g.origin = Vec3{0.0, 0.0, 0.0};
  g.tags.assign(static_cast<std::size_t>(span) * ny * arm, VoxelTag::Empty);
  // A clearance hole bored through the vertical arm (the 100/105 keep-clear
  // geometry in its simplest form) — this is the ingredient handoff 125 measured
  // as the one that kills V-cycle contraction once the domain is mostly empty.
  const double cz = arm * 0.55, cy = ny * 0.5, rr = hole_frac * arm;
  for (int k = 0; k < arm; ++k)
    for (int j = 0; j < ny; ++j)
      for (int i = 0; i < span; ++i) {
        if (!(i < t || k < t)) continue;
        if (hole_frac > 0.0) {
          const double dz = k + 0.5 - cz, dy = j + 0.5 - cy;
          if (std::sqrt(dz * dz + dy * dy) < rr) continue;
        }
        g.set_tag(i, j, k, VoxelTag::Interior);
      }
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

Material fdm_material() {
  Material m;
  m.youngs_modulus_mpa = 3500.0; m.yield_strength_mpa = 55.0;
  m.density_g_cm3 = 1.24; m.z_knockdown = 0.55; m.poisson = 0.33; m.family = "fdm";
  return m;
}

double mean_abs_diff(const std::vector<double>& a, const std::vector<double>& b) {
  if (a.size() != b.size() || a.empty()) return -1.0;
  double s = 0.0;
  for (std::size_t i = 0; i < a.size(); ++i) s += std::fabs(a[i] - b[i]);
  return s / static_cast<double>(a.size());
}
double max_abs_diff(const std::vector<double>& a, const std::vector<double>& b) {
  if (a.size() != b.size() || a.empty()) return -1.0;
  double m = 0.0;
  for (std::size_t i = 0; i < a.size(); ++i) m = std::max(m, std::fabs(a[i] - b[i]));
  return m;
}

struct RungRow {
  double vf = 0.0;
  int iters = 0;
  long long cg_iters = 0, gray_cg = 0, proj_cg = 0;
  long long setup_matvecs = 0;
  long long mg_steps = 0, steps = 0;
  long long recycled_steps = 0;   // steps where a basis actually preconditioned
  double achieved = 0.0, margin = 0.0, compliance = 0.0;
  bool accepted = false, projection_fired = false;
  std::vector<double> density;
};

struct ModeResult {
  std::string name;
  std::vector<RungRow> rungs;
  int total_iters = 0;
  long long total_cg = 0, gray_cg = 0, proj_cg = 0;
  long long setup_matvecs = 0;
  long long mg_steps = 0, steps = 0, recycled_steps = 0;
  double repeat_max_drho = -1.0;      // determinism self-check; must be 0
  bool repeat_iters_identical = true; // ... and the iteration history too
  double wall_median = 0.0;
};

struct Fixture {
  VoxelGrid part;
  std::vector<DirichletBC> bcs;
  std::vector<NodalLoad> loads;
  bool use_box = false;
  DesignBox box;
};

// One deterministic run + one repeat (the determinism self-check).
ModeResult run_mode(const std::string& name, bool recycling, int k, int cycle,
                    bool reset_per_rung, const Fixture& fx,
                    const SettingsRules& rules, const Material& material,
                    int reps) {
  ModeResult mr;
  mr.name = name;
  std::vector<double> walls;
  std::vector<int> first_iters;
  for (int rep = 0; rep < reps; ++rep) {
    MinimizePlasticOptions o;
    configure_production_options(o);
    o.volume_fraction_ladder = production_reduction_ladder();
    o.margin_stop = 1.5;
    o.external_loads = fx.loads;
    o.gravity = 9810.0 * 1e-9;
    o.gravity_direction = Vec3{0.0, 0.0, -1.0};
    o.infill_percent = 100.0;
    o.krylov_recycle_reset_per_rung = reset_per_rung;
    if (fx.use_box) o.design_box = fx.box;

    // The ONE toggled knob (configure_production_options may or may not arm it,
    // so the baseline is produced by explicitly turning it back OFF).
    fea_set_krylov_recycling(recycling);
    fea_set_krylov_recycle_dim(k > 0 ? k : 16);
    fea_set_krylov_recycle_cycle(cycle > 0 ? cycle : 1);
    fea_matfree_reset_mg_stagnation_latch();
    fea_reset_krylov_recycle_space();

    std::vector<RungRow> live;
    o.on_iteration = [&](std::size_t rung, std::size_t,
                         const SimpIterationObservation& obs) {
      if (rung >= live.size()) live.resize(rung + 1);
      RungRow& row = live[rung];
      row.cg_iters += obs.cg_iterations;
      row.setup_matvecs += obs.cg_recycle_setup_matvecs;
      row.steps += 1;
      if (obs.cg_used_multigrid) row.mg_steps += 1;
      if (obs.cg_recycle_dim > 0) row.recycled_steps += 1;
      if (obs.beta > 0.0) { row.proj_cg += obs.cg_iterations; row.projection_fired = true; }
      else row.gray_cg += obs.cg_iterations;
    };

    const auto t0 = std::chrono::steady_clock::now();
    const MinimizePlasticResult r =
        minimize_plastic(fx.part, material, "fdm", fx.bcs, rules, o);
    const auto t1 = std::chrono::steady_clock::now();
    walls.push_back(std::chrono::duration<double>(t1 - t0).count());
    fea_set_krylov_recycling(false);
    fea_reset_krylov_recycle_space();

    if (rep == 0) {
      for (std::size_t i = 0; i < r.evaluated.size(); ++i) {
        const auto& v = r.evaluated[i];
        RungRow row = i < live.size() ? live[i] : RungRow{};
        row.vf = v.requested_volume_fraction;
        row.iters = v.optimization.iterations;
        row.achieved = v.optimization.volume_fraction;
        row.margin = v.report.margin.worst_case;
        row.compliance = v.optimization.compliance;
        row.accepted = v.accepted;
        row.density = v.optimization.physical_density;
        mr.rungs.push_back(row);
        mr.total_iters += row.iters;
        mr.total_cg += row.cg_iters;
        mr.gray_cg += row.gray_cg;
        mr.proj_cg += row.proj_cg;
        mr.setup_matvecs += row.setup_matvecs;
        mr.mg_steps += row.mg_steps;
        mr.steps += row.steps;
        mr.recycled_steps += row.recycled_steps;
        first_iters.push_back(row.iters);
      }
    } else if (rep == 1) {
      // (c) DETERMINISM: the repeat must reproduce the design bit for bit and the
      // per-rung iteration history exactly.
      if (!mr.rungs.empty() && !r.evaluated.empty())
        mr.repeat_max_drho = max_abs_diff(mr.rungs.back().density,
                                          r.evaluated.back().optimization.physical_density);
      mr.repeat_iters_identical =
          (r.evaluated.size() == first_iters.size());
      for (std::size_t i = 0; mr.repeat_iters_identical && i < r.evaluated.size(); ++i)
        if (r.evaluated[i].optimization.iterations != first_iters[i])
          mr.repeat_iters_identical = false;
    }
  }
  std::sort(walls.begin(), walls.end());
  mr.wall_median = walls.empty() ? 0.0 : walls[walls.size() / 2];
  return mr;
}

void print_mode(const ModeResult& m) {
  const double mg_frac = m.steps > 0 ? double(m.mg_steps) / double(m.steps) : 0.0;
  const double rc_frac =
      m.steps > 0 ? double(m.recycled_steps) / double(m.steps) : 0.0;
  std::printf("[%-22s] rungs=%zu iters=%4d cg=%8lld (gray=%8lld proj=%8lld)"
              " setup_mv=%6lld mg_frac=%.2f rc_frac=%.2f wall=%.1fs"
              " repeat|drho|=%s iters_repeat=%s\n",
              m.name.c_str(), m.rungs.size(), m.total_iters, m.total_cg,
              m.gray_cg, m.proj_cg, m.setup_matvecs, mg_frac, rc_frac,
              m.wall_median,
              m.repeat_max_drho < 0.0 ? "n/a"
                                      : (m.repeat_max_drho == 0.0 ? "0" : "NONZERO"),
              m.repeat_iters_identical ? "same" : "DIFF");
  std::fflush(stdout);
}

// The (a)+(b) verdict for one baseline/recycled pair, in the 110 table shape.
void compare(const ModeResult& base, const ModeResult& rec, double overhead_per_iter) {
  bool verdicts_identical = base.rungs.size() == rec.rungs.size();
  const std::size_t n = std::min(base.rungs.size(), rec.rungs.size());
  double worst_margin_pct = 0.0, worst_mean_drho = 0.0, worst_C_pct = 0.0;
  int last_accepted = -1;
  for (std::size_t i = 0; i < n; ++i) {
    if (base.rungs[i].accepted != rec.rungs[i].accepted) verdicts_identical = false;
    if (base.rungs[i].projection_fired != rec.rungs[i].projection_fired)
      verdicts_identical = false;
    if (base.rungs[i].accepted && rec.rungs[i].accepted) {
      last_accepted = static_cast<int>(i);
      const double mb = base.rungs[i].margin;
      worst_margin_pct = std::max(worst_margin_pct,
          100.0 * std::fabs(rec.rungs[i].margin - mb) /
              (std::fabs(mb) > 1e-12 ? std::fabs(mb) : 1.0));
      worst_mean_drho = std::max(worst_mean_drho,
          mean_abs_diff(base.rungs[i].density, rec.rungs[i].density));
      const double cb = base.rungs[i].compliance;
      worst_C_pct = std::max(worst_C_pct,
          std::fabs(cb) > 1e-30 ? 100.0 * std::fabs(rec.rungs[i].compliance - cb) / cb : 0.0);
    }
  }
  double ship_mean = 0.0, ship_max = 0.0, ship_vf = 0.0;
  if (last_accepted >= 0) {
    ship_vf = base.rungs[last_accepted].vf;
    ship_mean = mean_abs_diff(base.rungs[last_accepted].density,
                              rec.rungs[last_accepted].density);
    ship_max = max_abs_diff(base.rungs[last_accepted].density,
                            rec.rungs[last_accepted].density);
  }
  const double cg_ratio = base.total_cg > 0
                              ? double(rec.total_cg) / double(base.total_cg) : 0.0;
  // NET work in matvec-equivalents: every recycled CG iteration also pays the
  // measured per-iteration correction overhead, and every setup matvec is work.
  const double net = base.total_cg > 0
      ? (double(rec.total_cg) * (1.0 + overhead_per_iter) +
         double(rec.setup_matvecs)) / double(base.total_cg)
      : 0.0;
  std::printf("  %-22s CG %.3fx (cut %5.1f%%) | NET(w/ovh %.2f) %.3fx (cut %5.1f%%)"
              " | gate=%s | SHIPPED vf=%.2f mean|drho|=%.6f max=%.4f |"
              " worst-acc mean|drho|=%.6f margin_d=%.3f%% C_d=%.3f%%\n",
              rec.name.c_str(), cg_ratio, 100.0 * (1.0 - cg_ratio),
              overhead_per_iter, net, 100.0 * (1.0 - net),
              verdicts_identical ? "IDENTICAL" : "DIFF", ship_vf, ship_mean,
              ship_max, worst_mean_drho, worst_margin_pct, worst_C_pct);
}

}  // namespace

int main(int argc, char** argv) {
  const std::string which = argc > 1 ? argv[1] : "mg";
  const int reps = std::getenv("TOPOPT_RC_REPS")
                       ? std::atoi(std::getenv("TOPOPT_RC_REPS")) : 2;
  // Measured per-iteration correction overhead at the swept default k, from the
  // rc_cost microbenchmark (handoff 133 §accounting). Overridable so the table
  // can be re-derived on another machine without editing the source.
  const double overhead = std::getenv("TOPOPT_RC_OVERHEAD")
                              ? std::atof(std::getenv("TOPOPT_RC_OVERHEAD")) : 0.0;

  SettingsRules rules;
  try {
    rules = load_settings_rules_file(SETTINGS_RULES_PATH);
  } catch (const std::exception& e) {
    std::fprintf(stderr, "FAIL: could not load rules.json: %s\n", e.what());
    return 1;
  }
  const Material material = fdm_material();

  Fixture fx;
  const double h = 2.0;
  if (which == "mg") {
    // Healthy-multigrid regime: the 132 probe's fixture, no box, no hole.
    const int arm = 48, ny = 16, t = 12;
    fx.part = l_bracket(fx.bcs, arm, arm, ny, t, h, 0.0);
    if (!mg_grid_coarsenable(arm, ny, arm)) {
      std::fprintf(stderr, "FAIL: mg fixture is not coarsenable — vacuous gate.\n");
      return 1;
    }
  } else {
    // Void-heavy Jacobi regime: a SMALL bracket with a clearance hole inside a
    // LARGE design box, so most of the domain is empty expanse. This is the
    // 125/131 stand-class shape: the V-cycle stops contracting, the 127 latch
    // turns MG off, and the run grinds in Jacobi-CG.
    const int arm = std::getenv("TOPOPT_RC_ARM") ? std::atoi(std::getenv("TOPOPT_RC_ARM")) : 16;
    const int ny = std::max(4, arm / 3);
    const int t = std::max(2, arm / 5);
    fx.part = l_bracket(fx.bcs, arm, arm, ny, t, h, 0.16);
    fx.use_box = true;
    fx.box.min = Vec3{0.0, 0.0, 0.0};
    fx.box.max = Vec3{arm * h * 2.0, ny * h * 2.0, arm * h * 1.5};
  }
  fx.loads = traction_loads(fx.part, VoxelTag::Load, Vec3{0.0, 0.0, -30.0});

  std::setvbuf(stdout, nullptr, _IOLBF, 0);
  std::printf("===== RECYCLING PROBE [%s] part %dx%dx%d, %zu solid voxels, h=%.1f%s =====\n",
              which.c_str(), fx.part.nx, fx.part.ny, fx.part.nz,
              fx.part.solid_count(), h, fx.use_box ? ", design box" : "");

  const ModeResult base =
      run_mode("baseline (off)", false, 0, 1, true, fx, rules, material, reps);
  print_mode(base);
  const double mg_frac =
      base.steps > 0 ? double(base.mg_steps) / double(base.steps) : 0.0;
  if (which == "mg" && mg_frac < 0.5)
    std::printf("  !! WARNING: mg_frac=%.2f — this is NOT the healthy-multigrid "
                "regime; the mg table would be vacuous.\n", mg_frac);
  if (which == "void" && mg_frac > 0.5)
    std::printf("  !! WARNING: mg_frac=%.2f — multigrid is CARRYING; this is NOT "
                "the Jacobi/void regime the void table claims.\n", mg_frac);

  struct Variant { const char* name; int k; int cycle; bool reset_per_rung;
                   bool metric_diag; bool wrap_mg; };
  const std::vector<Variant> variants = {
      {"k=8  cyc=1 rung-reset",   8, 1, true,  true,  true},
      {"k=16 cyc=1 rung-reset",  16, 1, true,  true,  true},
      {"k=24 cyc=1 rung-reset",  24, 1, true,  true,  true},
      {"k=16 cyc=4 rung-reset",  16, 4, true,  true,  true},
      {"k=16 cyc=1 carry-rungs", 16, 1, false, true,  true},
      // The arming candidate: restrict the correction to the Jacobi-preconditioned
      // loop, leaving the multigrid regime baseline BY CONSTRUCTION.
      {"k=16 jacobi-only",       16, 1, true,  true,  false},
      // Wang rescaling check: the SAME configuration with the UNSCALED (identity)
      // extraction metric. If the diagonal metric is doing the 2007 paper's work,
      // this row is measurably worse.
      {"k=16 no-rescale(ident)", 16, 1, true,  false, true},
  };
  // Optional variant filter (substring match) so a single row can be re-measured
  // without re-running the whole sweep: TOPOPT_RC_ONLY="no-rescale".
  const char* only = std::getenv("TOPOPT_RC_ONLY");
  std::vector<ModeResult> results;
  for (const Variant& v : variants) {
    if (only != nullptr && std::string(v.name).find(only) == std::string::npos)
      continue;
    fea_detail::rc_set_metric_diagonal(v.metric_diag);
    fea_detail::rc_set_wrap_multigrid(v.wrap_mg);
    results.push_back(
        run_mode(v.name, true, v.k, v.cycle, v.reset_per_rung, fx, rules, material, reps));
    fea_detail::rc_set_metric_diagonal(true);
    fea_detail::rc_set_wrap_multigrid(true);
    print_mode(results.back());
  }
  std::printf("--- verdicts vs baseline ---\n");
  for (const ModeResult& r : results) compare(base, r, overhead);
  return 0;
}
