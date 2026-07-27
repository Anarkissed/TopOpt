// width_aware_gate — the before/after gate table for the width-aware accept-gate
// knockdown (handoff 2026-07-26-width-aware-knockdown, bars K2/K4/K6). STANDALONE,
// NOT wired into CTest (the sanctioned active_domain_gate / knockdown_probe pattern:
// build against libtopopt.a, run by hand).
//
// It runs the reduction ladder ONCE on an in-code fixture with margin_stop lowered
// so the walk evaluates EVERY rung (not stopping at the first rejection), then
// re-gates each converged rung under BOTH knockdown postures via analyze_fixed_design
// — the OFF scalar `worst_case·f^1.5` and the ON width-aware composite — at the real
// margin_stop. That isolates the ONE thing this PR changes (the gate), apples to
// apples, per rung, and names every verdict flip with its sign.
//
// Two fixtures:
//   * a member-scale cantilever (thin ribs) — where the walls rescue the gate and
//     verdicts FLIP to accept (less conservative, the intended direction);
//   * an envelope-scale solid block — where the local thickness saturates the cap,
//     f_wall → 0, and the ON gate == the OFF gate (caution on thick sections KEPT,
//     bar K4).
//
// Build:  c++ -std=c++17 -O2 -I include -I /opt/homebrew/include/eigen3 \
//           tests/harness/width_aware_gate.cpp build/libtopopt.a -o build/width_aware_gate
// Run:    ./build/width_aware_gate   (optional: TOPOPT_WA_INFILL, TOPOPT_WA_LOOPS)

#include "topopt/analyze.hpp"
#include "topopt/fea.hpp"
#include "topopt/materials.hpp"
#include "topopt/pipeline.hpp"
#include "topopt/report.hpp"
#include "topopt/settings.hpp"
#include "topopt/simp.hpp"
#include "topopt/voxel.hpp"

#include <chrono>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <string>
#include <vector>

using namespace topopt;

namespace {

VoxelGrid cantilever(std::vector<DirichletBC>& bcs, int nx, int ny, int nz,
                     double h) {
  VoxelGrid g;
  g.nx = nx; g.ny = ny; g.nz = nz; g.spacing = h;
  g.tags.assign(static_cast<std::size_t>(nx) * ny * nz, VoxelTag::Interior);
  for (int k = 0; k < nz; ++k)
    for (int j = 0; j < ny; ++j) g.set_tag(0, j, k, VoxelTag::Fixture);
  bcs.clear();
  for (int c = 0; c <= nz; ++c)
    for (int b = 0; b <= ny; ++b) {
      const int n = fea_node_index(g, 0, b, c);
      bcs.push_back({n, 0, 0.0});
      bcs.push_back({n, 1, 0.0});
      bcs.push_back({n, 2, 0.0});
    }
  return g;
}

// A synthetic (large) yield so the cm-scale self-weight margins land in the
// flip band ~[2,9] — self-weight on a real cm plastic part gives an astronomically
// large margin, so test_minimize_plastic does the same in-code-material trick. NOT
// a materials.json edit; it only positions the margins where a verdict flip is
// visible. worst_case ∝ yield/gravity, so either knob slides the band.
double g_yield = 4.0e6;
double g_gravity = 300.0;

Material fdm_material() {
  Material m;
  m.youngs_modulus_mpa = 3500.0;
  m.yield_strength_mpa = g_yield;
  m.density_g_cm3 = 1.24;
  m.z_knockdown = 0.55;
  m.poisson = 0.33;
  m.family = "fdm";
  return m;
}

const char* verdict(bool ok) { return ok ? "ACCEPT" : "reject"; }

// Re-gate one converged rung under a KnockdownSpec and return its analysis.
FixedDesignAnalysis regate(const VoxelGrid& g, const SimpParams& params,
                           const std::vector<double>& rho,
                           const std::vector<DirichletBC>& bcs,
                           const std::vector<NodalLoad>& loads,
                           const Material& mat, const Vec3& build_dir,
                           double margin_stop, const KnockdownSpec& k) {
  const bool lp = load_path_connected(g, rho, 0.5);
  return analyze_fixed_design(g, params, rho, bcs, loads, mat, build_dir, 1e-6,
                              50000, SolverKind::JacobiCG, margin_stop, k, lp,
                              static_cast<double>(g.solid_count()));
}

void run_fixture(const char* name, VoxelGrid g, std::vector<DirichletBC> bcs,
                 double infill, int loops, double line_mm) {
  const Material mat = fdm_material();
  SettingsRules rules = load_settings_rules_file(SETTINGS_RULES_PATH);

  SimpParams params;
  params.youngs_modulus = mat.youngs_modulus_mpa;
  params.poisson = mat.poisson;
  params.penalty = 3.0;

  MinimizePlasticOptions opt;
  opt.volume_fraction_ladder = {0.8, 0.6, 0.45, 0.35, 0.25};
  opt.margin_stop = 0.0;             // walk EVERY rung (re-gated below at 1.5)
  opt.gravity = g_gravity;           // strong self-weight so stress is non-trivial
  opt.gravity_direction = Vec3{0.0, 0.0, -1.0};
  opt.infill_percent = infill;
  opt.simp.max_iterations = 40;      // cheap; the gate change is what we measure

  const MinimizePlasticResult res =
      minimize_plastic(g, mat, "fdm", bcs, rules, opt);

  const Vec3 build_dir{0.0, 0.0, 1.0};
  const std::vector<NodalLoad> loads =
      self_weight_loads(res.solved_grid, mat.density_g_cm3, opt.gravity,
                        opt.gravity_direction);

  KnockdownSpec off;
  off.infill_knockdown = infill_margin_knockdown(infill);
  KnockdownSpec on = off;
  on.width_aware = true;
  on.infill_percent = infill;
  on.wall_thickness_mm = static_cast<double>(loops) * line_mm;

  const double margin_stop = 1.5;

  std::printf(
      "\n=== %s | infill %.0f%% (f^1.5=%.4f) | %d wall loops × %.2f mm | "
      "spacing %.2f mm ===\n",
      name, infill, off.infill_knockdown, loops, line_mm, g.spacing);
  std::printf(
      "  %-4s %-6s | %-10s | %-9s %-7s | %-9s %-7s | %s\n", "rung", "vf",
      "worst_case", "eff(OFF)", "verdict", "eff(ON)", "verdict", "sign");

  double t_off_ms = 0.0, t_on_ms = 0.0;
  int n_gated = 0;
  for (std::size_t r = 0; r < res.evaluated.size(); ++r) {
    const MinimizePlasticVariant& v = res.evaluated[r];
    if (v.infeasible) continue;
    const std::vector<double>& rho = v.optimization.physical_density;

    auto t0 = std::chrono::steady_clock::now();
    const FixedDesignAnalysis a_off =
        regate(res.solved_grid, params, rho, bcs, loads, mat, build_dir,
               margin_stop, off);
    auto t1 = std::chrono::steady_clock::now();
    const FixedDesignAnalysis a_on =
        regate(res.solved_grid, params, rho, bcs, loads, mat, build_dir,
               margin_stop, on);
    auto t2 = std::chrono::steady_clock::now();
    t_off_ms += std::chrono::duration<double, std::milli>(t1 - t0).count();
    t_on_ms += std::chrono::duration<double, std::milli>(t2 - t1).count();
    ++n_gated;

    const char* sign =
        a_on.margin_effective > a_off.margin_effective * 1.0001 ? "LESS-cons"
        : a_on.margin_effective < a_off.margin_effective * 0.9999 ? "MORE-cons"
                                                                  : "unchanged";
    const char* flip = (a_off.accepted != a_on.accepted) ? " <== FLIP" : "";
    std::printf(
        "  %-4zu %-6.3f | %-10.4f | %-9.4f %-7s | %-9.4f %-7s | %s%s\n", r + 1,
        v.requested_volume_fraction, a_off.margin.worst_case,
        a_off.margin_effective, verdict(a_off.accepted), a_on.margin_effective,
        verdict(a_on.accepted), sign, flip);
  }
  std::printf(
      "  cost: OFF gate %.1f ms/rung, ON gate %.1f ms/rung (+%.1f ms = the local-"
      "thickness pass), over %d rungs\n",
      n_gated ? t_off_ms / n_gated : 0.0, n_gated ? t_on_ms / n_gated : 0.0,
      n_gated ? (t_on_ms - t_off_ms) / n_gated : 0.0, n_gated);
}

// K6 — the local-thickness pass cost, in ISOLATION, vs one gate solve. Builds a
// dense-ish random-but-deterministic field on an N³ grid and times
// local_member_thickness_mm (the ONLY new per-gate work) against a full
// analyze_fixed_design solve on the same grid.
void cost_probe(int N) {
  std::vector<DirichletBC> bcs;
  VoxelGrid g = cantilever(bcs, N, N, N, 2.0);
  // A blocky pseudo-random solid field (deterministic), ~60% dense, so the
  // thickness transform has real members to resolve (not a trivial all-void).
  std::vector<double> rho(static_cast<std::size_t>(N) * N * N, 0.0);
  for (int k = 0; k < N; ++k)
    for (int j = 0; j < N; ++j)
      for (int i = 0; i < N; ++i) {
        const unsigned h = (i * 73856093u) ^ (j * 19349663u) ^ (k * 83492791u);
        rho[g.index(i, j, k)] = ((h >> 4) % 10u) < 6u ? 1.0 : 0.0;  // ~60%
      }
  const Material mat = fdm_material();
  SimpParams params;
  params.youngs_modulus = mat.youngs_modulus_mpa;
  params.poisson = mat.poisson;
  params.penalty = 3.0;
  const Vec3 build_dir{0.0, 0.0, 1.0};
  const std::vector<NodalLoad> loads =
      self_weight_loads(g, mat.density_g_cm3, 300.0, Vec3{0.0, 0.0, -1.0});

  auto t0 = std::chrono::steady_clock::now();
  const std::vector<double> tau =
      local_member_thickness_mm(g, rho, 0.5, 32);  // kWidthAwareThicknessCapVoxels
  auto t1 = std::chrono::steady_clock::now();
  KnockdownSpec off;
  off.infill_knockdown = infill_margin_knockdown(30.0);
  const FixedDesignAnalysis a =
      regate(g, params, rho, bcs, loads, mat, build_dir, 1.5, off);
  auto t2 = std::chrono::steady_clock::now();
  (void)tau; (void)a;
  const double t_thick =
      std::chrono::duration<double, std::milli>(t1 - t0).count();
  const double t_gate =
      std::chrono::duration<double, std::milli>(t2 - t1).count();
  std::printf(
      "  N=%-4d (%d voxels): thickness pass %.1f ms | one gate FEA solve %.1f ms "
      "| thickness = %.1f%% of the solve\n",
      N, N * N * N, t_thick, t_gate, 100.0 * t_thick / t_gate);
}

}  // namespace

int main() {
  double infill = 30.0;
  int loops = 5;
  if (const char* e = std::getenv("TOPOPT_WA_INFILL")) infill = std::atof(e);
  if (const char* e = std::getenv("TOPOPT_WA_LOOPS")) loops = std::atoi(e);
  if (const char* e = std::getenv("TOPOPT_WA_YIELD")) g_yield = std::atof(e);
  if (const char* e = std::getenv("TOPOPT_WA_GRAVITY")) g_gravity = std::atof(e);
  const double line_mm = 0.45;

  std::printf(
      "WIDTH-AWARE GATE TABLE (handoff 2026-07-26-width-aware-knockdown)\n"
      "Each rung's converged density re-gated under OFF (worst_case·f^1.5) and ON\n"
      "(per-voxel SHELL+CORE composite) at margin_stop=1.5. Sign is the ON vs OFF\n"
      "effective margin: LESS-cons = walls relieve (accept lighter); unchanged =\n"
      "thick region, no rescue (caution kept, bar K4).\n");

  std::string only;
  if (const char* e = std::getenv("TOPOPT_WA_ONLY")) only = e;

  if (only == "cost") {  // opt-in: the 56³ JacobiCG solve is minutes
    std::printf("\n=== K6 COST — local-thickness pass vs one gate FEA solve ===\n");
    cost_probe(24);
    cost_probe(40);
    cost_probe(56);
    return 0;
  }
  if (only.empty() || only == "member") {
    std::vector<DirichletBC> bcs;
    // Member-scale ribs: coarse spacing so an optimized rib is a few mm wide.
    VoxelGrid g = cantilever(bcs, 24, 6, 8, 3.0);
    run_fixture("MEMBER-SCALE cantilever (thin ribs)", g, bcs, infill, loops,
                line_mm);
  }
  if (only.empty() || only == "envelope") {
    std::vector<DirichletBC> bcs;
    // Envelope-scale solid: a chunky block, fine spacing → members exceed the
    // thickness cap → f_wall → 0 → ON == OFF (thick section unchanged).
    VoxelGrid g = cantilever(bcs, 16, 16, 16, 3.0);
    run_fixture("ENVELOPE-SCALE solid block (thick)", g, bcs, infill, loops,
                line_mm);
  }
  return 0;
}
