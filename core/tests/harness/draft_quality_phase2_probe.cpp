// draft_quality_phase2_probe.cpp — the Phase-2 DESIGN-SPACE escalation trigger
// (handoff 2026-07-26-draft-quality-phase2). Phase 1 (handoff 2026-07-25) shipped a
// compliance-gap escalation trigger and MEASURED it not to separate: a genuinely
// diverged rung can share the certified compliance (gap≈0, a MISS) while a converged
// rung differs slightly in it (a false alarm). Phase 2 replaces the scalar gap with
// a self-contained DESIGN-SPACE probe: at a rung's loose plateau take ONE extra tight
// probe solve, seeded from the rung's own converged loose design, and measure the
// fraction of solid voxels whose printed<->void classification moves. This harness
// validates the bars:
//
//   D1  the probe SEPARATES the two Phase-1 counterexamples (diverged low-gap rung
//       vs converged high-gap rung). If it does not, report and STOP — no threshold
//       is fitted here.
//   D2  NEGATIVE CONTROL FIRST (tight vs tighter): the probe floor, before any signal.
//   D3  probe cost < 5% of the rung it protects (measured, printed).
//   D4  the win across THREE grid sizes (trend, stated plainly).
//   D7  grid dims + solid-voxel count in every design-difference row.
//
// Two postures are exercised because Phase-1's numbers were measured on core BEFORE
// active-domain arming (handoff 187) merged: AD-OFF (simp.active_domain_band = 0,
// matching Phase-1's pre-187 solve) and AD-ON (production, the maintainer's posture).
// Build as for the other draft harnesses (see BUILD.md).

#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <string>
#include <vector>

#include "topopt/materials.hpp"
#include "topopt/pipeline.hpp"
#include "topopt/production.hpp"
#include "topopt/settings.hpp"
#include "topopt/simp.hpp"
#include "topopt/voxel.hpp"

using namespace topopt;

namespace {

constexpr double kIso = 0.5;

// L-bracket generator, identical to draft_quality_divergence_probe.cpp (Phase 1), so
// the grids and load case match the counterexamples exactly.
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

Material fdm_material() {
  Material m;
  m.youngs_modulus_mpa = 3500.0; m.yield_strength_mpa = 55.0;
  m.density_g_cm3 = 1.24; m.z_knockdown = 0.55; m.poisson = 0.33; m.family = "fdm";
  return m;
}

struct ClassDiff { long long flips = 0; long long ref_solid = 0; double frac = 0.0; };
ClassDiff class_diff(const std::vector<double>& ref, const std::vector<double>& b) {
  ClassDiff d;
  if (ref.size() != b.size() || ref.empty()) return d;
  for (std::size_t i = 0; i < ref.size(); ++i) {
    const bool ra = ref[i] > kIso, rb = b[i] > kIso;
    if (ra) ++d.ref_solid;
    if (ra != rb) ++d.flips;
  }
  d.frac = d.ref_solid > 0 ? double(d.flips) / double(d.ref_solid) : 0.0;
  return d;
}

struct RungOut {
  double vf = 0.0; long long cg = 0; int iters = 0;
  double compliance = 0.0; bool accepted = false;
  std::vector<double> density;
  double gap = -1.0, probe_flip = -1.0; long long probe_cg = 0;
  int escalated = 0;
};
struct RunOut {
  std::vector<RungOut> rungs;
  std::vector<double> terminal_density;
  long long total_cg = 0;
  double wall_s = 0.0;
};

struct Cfg {
  double cg_tol = 1e-8;
  bool draft = false;
  double loose = 1e-3;
  bool ad = true;            // active-domain armed (production) vs off (Phase-1 posture)
  bool warm = false;         // warm_start_inherit
  double design_flip = 0.0;  // >0 arms the Phase-2 design trigger
  int probe_iters = 1;
  double c_gap = 1e30;       // Phase-1 gap threshold (used only when design_flip<=0)
};

RunOut run(const Cfg& cfg, const VoxelGrid& part, const std::vector<DirichletBC>& bcs,
           const std::vector<NodalLoad>& loads, const SettingsRules& rules,
           const Material& material, const DesignBox& box,
           const std::vector<double>& ladder) {
  MinimizePlasticOptions o;
  configure_production_options(o);
  if (!cfg.ad) o.simp.active_domain_band = 0;  // match Phase-1's pre-187 solve
  o.volume_fraction_ladder = ladder;
  o.margin_stop = 0.0;
  o.external_loads = loads;
  o.gravity = 9810.0 * 1e-9;
  o.gravity_direction = Vec3{0.0, 0.0, -1.0};
  o.infill_percent = 100.0;
  o.design_box = box;
  o.warm_start_inherit = cfg.warm;
  o.simp.cg_tolerance = cfg.cg_tol;
  o.draft_quality = cfg.draft;
  o.draft_loose_tol = cfg.loose;
  o.draft_escalation_c_gap = cfg.c_gap;
  // A finite design_flip (incl. the 1e30 "measure but never fire" sentinel) arms the
  // design trigger; the Phase-1 gap path is used only when design_flip < 0.
  o.draft_use_design_trigger = cfg.design_flip >= 0.0;
  o.draft_escalation_design_flip = cfg.design_flip;
  o.draft_probe_iters = cfg.probe_iters;

  RunOut out;
  std::vector<long long> cg_per_rung; std::vector<int> iters_per_rung;
  o.on_iteration = [&](std::size_t rung, std::size_t, const SimpIterationObservation& ob) {
    auto grow = [&](auto& v){ if (rung >= v.size()) v.resize(rung + 1, 0); };
    grow(cg_per_rung); grow(iters_per_rung);
    cg_per_rung[rung] += ob.cg_iterations; ++iters_per_rung[rung];
  };
  const auto t0 = std::chrono::steady_clock::now();
  const MinimizePlasticResult r = minimize_plastic(part, material, "fdm", bcs, rules, o);
  out.wall_s = std::chrono::duration<double>(std::chrono::steady_clock::now() - t0).count();
  for (std::size_t i = 0; i < r.evaluated.size(); ++i) {
    const auto& v = r.evaluated[i];
    RungOut row;
    row.vf = v.requested_volume_fraction;
    row.cg = i < cg_per_rung.size() ? cg_per_rung[i] : 0;
    row.iters = i < iters_per_rung.size() ? iters_per_rung[i] : 0;
    row.compliance = v.optimization.compliance;
    row.accepted = v.accepted;
    row.density = v.optimization.physical_density;
    if (i < r.draft_rung_c_gap.size()) row.gap = r.draft_rung_c_gap[i];
    if (i < r.draft_rung_escalated.size()) row.escalated = r.draft_rung_escalated[i];
    if (i < r.draft_rung_probe_flip.size()) row.probe_flip = r.draft_rung_probe_flip[i];
    if (i < r.draft_rung_probe_cg.size()) row.probe_cg = r.draft_rung_probe_cg[i];
    out.total_cg += row.cg;
    out.rungs.push_back(std::move(row));
  }
  if (!r.evaluated.empty())
    out.terminal_density = r.evaluated.back().optimization.physical_density;
  return out;
}

long long grid_solid_count(const VoxelGrid& g) {
  long long n = 0;
  for (int k = 0; k < g.nz; ++k)
    for (int j = 0; j < g.ny; ++j)
      for (int i = 0; i < g.nx; ++i)
        if (g.solid(i, j, k)) ++n;
  return n;
}

}  // namespace

int main() {
  std::setvbuf(stdout, nullptr, _IONBF, 0);  // unbuffered: watch progress live
  SettingsRules rules;
  try { rules = load_settings_rules_file(SETTINGS_RULES_PATH); }
  catch (const std::exception& e) { std::fprintf(stderr, "rules: %s\n", e.what()); return 1; }
  const Material material = fdm_material();
  const double h = 2.0;

  // Grid S (16x8x16), Phase-1's stagnation grid + ladder.
  std::vector<DirichletBC> Sbcs;
  VoxelGrid Spart = l_bracket(Sbcs, 8, 8, 3, 2, h);
  const std::vector<NodalLoad> Sload = traction_loads(Spart, VoxelTag::Load, Vec3{0,0,-30});
  DesignBox Sbox; Sbox.min = Vec3{0,0,0}; Sbox.max = Vec3{8*h*2.0, 3*h*2.0, 8*h*2.0};
  const std::vector<double> Sladder = {0.50, 0.35, 0.24};

  MinimizePlasticOptions Sdims; Sdims.design_box = Sbox;
  VoxelGrid Sg = minimize_plastic_solved_grid(Spart, Sdims);
  const long long S_solid = grid_solid_count(Sg);
  std::printf("grid S solved = %dx%dx%d (%zu vox, %lld solid)\n",
              Sg.nx, Sg.ny, Sg.nz, Sg.voxel_count(), S_solid);

  auto Srun = [&](const Cfg& c){ return run(c, Spart, Sbcs, Sload, rules, material, Sbox, Sladder); };

  // A full per-posture pass: D2 negative-control FLOOR first, then the tight
  // baseline (the cross-run "truth"), then the D1 gap-vs-probe-vs-truth sweep, then
  // D3 probe cost. Run for the production posture (AD-on, fast) FIRST so the critical
  // separation verdict prints early, then the AD-off posture that matches Phase-1's
  // pre-187 solve for the faithful counterexample reproduction.
  auto posture_pass = [&](const char* tag, bool ad){
    std::printf("\n==================== POSTURE: %s ====================\n", tag);

    // --- D2 NEGATIVE CONTROL FIRST ---
    std::printf("\n#### D2 NEGATIVE CONTROL FIRST (%s) ####\n", tag);
    std::printf(" the probe floor = classification flip of a tight probe on an ALREADY-tight design\n");
    std::printf(" posture           | grid (solid) | per-rung probe flip (probe_cg)\n");
    auto print_floor = [&](const char* name, const RunOut& d){
      std::printf(" %-17s | %dx%dx%d (%lld) | ", name, Sg.nx, Sg.ny, Sg.nz, S_solid);
      for (std::size_t i = 0; i < d.rungs.size(); ++i)
        std::printf("r%zu %.4f (%lld)  ", i, d.rungs[i].probe_flip, d.rungs[i].probe_cg);
      std::printf("\n");
    };
    Cfg ctl; ctl.ad = ad; ctl.draft = true; ctl.design_flip = 1e30; ctl.probe_iters = 1;
    // The probe reports flip(step@loose_tol, step@cert). The FLOOR is that with the
    // loose tol set barely above cert (1e-7 vs 1e-8) — pure FEA-tolerance noise, the
    // tight-vs-tighter control. Production 1e-3 is a separate known-robust reference
    // (Phase 1 proved 1e-3 leaves the shipped design classification-identical), NOT
    // part of the floor.
    Cfg ctl_tt = ctl; ctl_tt.loose = 1e-7;      // tight-vs-tighter => the floor
    Cfg ctl_prod = ctl; ctl_prod.loose = 1e-3;  // production loose, robust reference
    RunOut floor_tt = Srun(ctl_tt);
    RunOut floor_prod = Srun(ctl_prod);
    print_floor("tight-vs-tighter", floor_tt);
    print_floor("production 1e-3", floor_prod);
    double floor_max = 0.0;
    for (auto& r : floor_tt.rungs) if (r.probe_flip > floor_max) floor_max = r.probe_flip;
    std::printf(" >> NEGATIVE-CONTROL FLOOR (tight-vs-tighter) = %.4f\n", floor_max);

    // --- tight baseline = the cross-run divergence "truth" (warm ON, matching the sweep) ---
    Cfg tb; tb.ad = ad; tb.draft = false; tb.warm = true;
    RunOut tight_ref = Srun(tb);
    std::printf(" tight baseline (warm ON) total_cg=%lld  [AD-off Phase-1 ref = 95303]\n",
                tight_ref.total_cg);

    // --- D1 GAP vs PROBE vs TRUTH sweep (warm ON = the counterexample posture) ---
    std::printf("\n#### D1 GAP-vs-PROBE-vs-TRUTH SWEEP (%s, warm ON) ####\n", tag);
    std::printf(" floor=%.4f   grid %dx%dx%d (%lld solid). truth = flip of draft[i] vs tight[i].\n",
                floor_max, Sg.nx, Sg.ny, Sg.nz, S_solid);
    std::printf(" loose | rung | gap     | probe   | truth (flip vs tight[i]) | probe fires? | gap fires(.02)?\n");
    const double sweep[] = {1e-3, 1e-2, 3e-2, 1e-1, 3e-1, 5e-1};
    for (double lt : sweep) {
      Cfg c; c.ad = ad; c.draft = true; c.warm = true; c.loose = lt;
      c.design_flip = 1e30;  // measure the probe, do not fire
      RunOut d = Srun(c);
      for (std::size_t i = 0; i < d.rungs.size(); ++i) {
        ClassDiff truth = (i < tight_ref.rungs.size())
            ? class_diff(tight_ref.rungs[i].density, d.rungs[i].density) : ClassDiff{};
        const bool probe_fires = d.rungs[i].probe_flip > floor_max;
        const bool gap_fires = d.rungs[i].gap > 0.02;
        std::printf(" %.0e |  r%zu  | %.5f | %.5f | %.4f (%lld/%lld) | %-3s | %-3s\n",
                    lt, i, d.rungs[i].gap, d.rungs[i].probe_flip,
                    truth.frac, truth.flips, truth.ref_solid,
                    probe_fires ? "YES" : "no", gap_fires ? "YES" : "no");
      }
    }

    // --- D3 PROBE COST at the loosest endpoint ---
    std::printf("\n#### D3 PROBE COST (%s, warm ON, loose 5e-1) ####\n", tag);
    Cfg cost_c; cost_c.ad = ad; cost_c.draft = true; cost_c.warm = true; cost_c.loose = 5e-1;
    cost_c.design_flip = 1e30;
    RunOut cost = Srun(cost_c);
    std::printf(" grid %dx%dx%d (%lld solid). rung | rung_cg | probe_cg | probe/rung %% (bar < 5%%)\n",
                Sg.nx, Sg.ny, Sg.nz, S_solid);
    long long tot_rcg = 0, tot_pcg = 0;
    for (std::size_t i = 0; i < cost.rungs.size(); ++i) {
      const double pct = cost.rungs[i].cg > 0 ? 100.0 * double(cost.rungs[i].probe_cg)/double(cost.rungs[i].cg) : 0.0;
      tot_rcg += cost.rungs[i].cg; tot_pcg += cost.rungs[i].probe_cg;
      std::printf("  r%zu  | %7lld | %8lld | %.2f%%\n", i, cost.rungs[i].cg, cost.rungs[i].probe_cg, pct);
    }
    std::printf(" >> TOTAL probe/ladder = %.2f%% (%lld / %lld)\n",
                tot_rcg>0?100.0*double(tot_pcg)/double(tot_rcg):0.0, tot_pcg, tot_rcg);
  };

  posture_pass("AD-on (production, post-187)", true);
  posture_pass("AD-off (Phase-1 pre-187 solve)", false);

  std::printf("\n########## DONE (grid-S bars). ##########\n");
  return 0;
}
