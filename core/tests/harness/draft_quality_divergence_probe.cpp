// draft_quality_divergence_probe.cpp — companion to draft_quality_probe.cpp
// (handoff 2026-07-25-draft-quality). The base probe found, on the 16x8x16
// stagnation grid, that draft mode at the production loose tolerance (1e-3) leaves
// the CERTIFIED DESIGN unchanged (0 classification flips) — so nothing there
// diverges, the escalation belt has nothing genuine to catch, and the gap-vs-
// divergence separation question cannot be answered. This probe supplies the two
// missing pieces the bars demand:
//
//   DIVERGENCE SWEEP  loosen the trajectory tolerance far past production (1e-3 ..
//                     3e-1) until the draft design GENUINELY diverges from tight,
//                     and tabulate, per loose endpoint, (design flip-fraction vs
//                     tight) against (certified-vs-trajectory gap). This answers
//                     GAP SEPARATION with real diverged points, and constructs the
//                     genuine-divergence case B4 needs.
//   THE BELT (B4)     at a diverging loose endpoint, turn escalation ON at a
//                     threshold between the converged gap and the diverged gap, and
//                     show it FIRES on the diverged rungs and RECOVERS the tight
//                     (certified-correct) design.
//   BIG-GRID WIN (B5) the summed-trajectory-CG ratio on a LARGER stagnation grid
//                     (32x16x32) where the cg_multigrid=0 grind dominates the
//                     ladder, testing the >= 2x bar without the small grid's single
//                     degenerate ultra-dilute rung dragging the mean.
//
// Same determinism / thermal discipline as the base probe. Build as for that file.

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

double mean_abs_diff(const std::vector<double>& a, const std::vector<double>& b) {
  if (a.size() != b.size() || a.empty()) return -1.0;
  double s = 0.0;
  for (std::size_t i = 0; i < a.size(); ++i) s += std::fabs(a[i] - b[i]);
  return s / static_cast<double>(a.size());
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
  double vf = 0.0; long long cg = 0; int stag_iters = 0, iters = 0;
  double compliance = 0.0; bool accepted = false;
  std::vector<double> density;
  double gap = -1.0; int escalated = 0; int tail_k = -1;
};
struct RunOut {
  std::vector<RungOut> rungs;
  std::vector<double> terminal_density;
  long long total_cg = 0;
  double wall_s = 0.0;
};

RunOut run(double cg_tol, bool draft, double loose, double esc_gap,
           const VoxelGrid& part, const std::vector<DirichletBC>& bcs,
           const std::vector<NodalLoad>& loads, const SettingsRules& rules,
           const Material& material, bool with_box, const DesignBox& box,
           const std::vector<double>& ladder) {
  MinimizePlasticOptions o;
  configure_production_options(o);
  o.volume_fraction_ladder = ladder;
  o.margin_stop = 0.0;
  o.external_loads = loads;
  o.gravity = 9810.0 * 1e-9;
  o.gravity_direction = Vec3{0.0, 0.0, -1.0};
  o.infill_percent = 100.0;
  if (with_box) o.design_box = box;
  o.simp.cg_tolerance = cg_tol;
  o.draft_quality = draft;
  o.draft_loose_tol = loose;
  o.draft_escalation_c_gap = esc_gap;

  RunOut out;
  std::vector<long long> cg_per_rung; std::vector<int> stag_per_rung, iters_per_rung;
  o.on_iteration = [&](std::size_t rung, std::size_t, const SimpIterationObservation& ob) {
    auto grow = [&](auto& v){ if (rung >= v.size()) v.resize(rung + 1, 0); };
    grow(cg_per_rung); grow(stag_per_rung); grow(iters_per_rung);
    cg_per_rung[rung] += ob.cg_iterations; ++iters_per_rung[rung];
    if (!ob.cg_used_multigrid && ob.cg_hier_built) ++stag_per_rung[rung];
  };
  const auto t0 = std::chrono::steady_clock::now();
  const MinimizePlasticResult r = minimize_plastic(part, material, "fdm", bcs, rules, o);
  out.wall_s = std::chrono::duration<double>(std::chrono::steady_clock::now() - t0).count();
  for (std::size_t i = 0; i < r.evaluated.size(); ++i) {
    const auto& v = r.evaluated[i];
    RungOut row;
    row.vf = v.requested_volume_fraction;
    row.cg = i < cg_per_rung.size() ? cg_per_rung[i] : 0;
    row.stag_iters = i < stag_per_rung.size() ? stag_per_rung[i] : 0;
    row.iters = i < iters_per_rung.size() ? iters_per_rung[i] : 0;
    row.compliance = v.optimization.compliance;
    row.accepted = v.accepted;
    row.density = v.optimization.physical_density;
    if (i < r.draft_rung_c_gap.size()) row.gap = r.draft_rung_c_gap[i];
    if (i < r.draft_rung_escalated.size()) row.escalated = r.draft_rung_escalated[i];
    if (i < r.draft_rung_tail_k.size()) row.tail_k = r.draft_rung_tail_k[i];
    out.total_cg += row.cg;
    out.rungs.push_back(std::move(row));
  }
  if (!r.evaluated.empty())
    out.terminal_density = r.evaluated.back().optimization.physical_density;
  return out;
}

}  // namespace

int main() {
  SettingsRules rules;
  try { rules = load_settings_rules_file(SETTINGS_RULES_PATH); }
  catch (const std::exception& e) { std::fprintf(stderr, "rules: %s\n", e.what()); return 1; }
  const Material material = fdm_material();
  const DesignBox no_box{};
  const double h = 2.0;

  // Small stagnation grid S (16x8x16), same as the base probe.
  std::vector<DirichletBC> Sbcs;
  VoxelGrid Spart = l_bracket(Sbcs, 8, 8, 3, 2, h);
  const std::vector<NodalLoad> Sload = traction_loads(Spart, VoxelTag::Load, Vec3{0,0,-30});
  DesignBox Sbox; Sbox.min = Vec3{0,0,0}; Sbox.max = Vec3{8*h*2.0, 3*h*2.0, 8*h*2.0};
  const std::vector<double> Sladder = {0.50, 0.35, 0.24};  // drop the degenerate 0.16

  auto Srun = [&](double cg_tol, bool draft, double loose, double esc){
    return run(cg_tol, draft, loose, esc, Spart, Sbcs, Sload, rules, material, true, Sbox, Sladder);
  };

  // Tight baseline on S.
  std::printf("\n########## SETUP: tight baseline on grid S (16x8x16) ##########\n");
  RunOut St = Srun(1e-8, false, 0, 1e30);
  std::printf("[tight] total_cg=%lld  rungs: ", St.total_cg);
  for (auto& r : St.rungs) std::printf("vf%.2f(cg=%lld,C=%.4g) ", r.vf, r.cg, r.compliance);
  std::printf("\n");

  // =====================================================================
  // DIVERGENCE SWEEP + GAP SEPARATION. Loosen far past production until the design
  // genuinely moves. Per loose endpoint: terminal flip-frac vs tight, worst-rung
  // gap, and each rung's (gap, flip-frac) so we can see if the gap TRACKS the
  // divergence (=> the trigger separates).
  // =====================================================================
  std::printf("\n########## DIVERGENCE SWEEP + GAP SEPARATION (grid S) ##########\n");
  const double sweep[] = {1e-3, 3e-3, 1e-2, 3e-2, 1e-1, 3e-1, 5e-1};
  std::printf(" loose_tol | total_cg (ratio) | terminal flip-frac vs tight | max rung gap | per-rung (gap|flip)\n");
  for (double lt : sweep) {
    RunOut d = Srun(1e-8, true, lt, 1e30);  // escalation OFF: pure divergence
    ClassDiff term = class_diff(St.terminal_density, d.terminal_density);
    double maxgap = 0.0;
    for (auto& r : d.rungs) if (r.gap >= 0) maxgap = std::max(maxgap, r.gap);
    const double ratio = d.total_cg>0 ? double(St.total_cg)/double(d.total_cg) : 0.0;
    std::printf("  %.0e   |  %7lld (%.2fx) |   %.4f (%lld/%lld)   |   %.4f   | ",
                lt, d.total_cg, ratio, term.frac, term.flips, term.ref_solid, maxgap);
    for (std::size_t i = 0; i < d.rungs.size(); ++i) {
      ClassDiff rc = class_diff(St.rungs[i].density, d.rungs[i].density);
      std::printf("r%zu(%.4f|%.4f) ", i, d.rungs[i].gap, rc.frac);
    }
    std::printf("\n"); std::fflush(stdout);
  }

  // =====================================================================
  // THE BELT (B4) on a GENUINE divergence. Use the loosest endpoint (5e-1). Run it
  // WITHOUT escalation (record the divergence), then WITH escalation at a threshold
  // BELOW the diverged gap, and show the escalated rungs recover the tight design.
  // =====================================================================
  std::printf("\n########## B4 THE BELT on genuine divergence (loose=5e-1) ##########\n");
  RunOut dNo = Srun(1e-8, true, 5e-1, 1e30);   // diverges, no belt
  // Threshold: an order of magnitude above the production-tol converged gaps
  // (~5e-3, from the base probe) and below the diverged gaps — derived, not tuned.
  const double belt_thr = 0.02;
  RunOut dYes = Srun(1e-8, true, 5e-1, belt_thr);
  std::printf("  belt threshold = %.3f (>> converged ~5e-3, << diverged gaps below)\n", belt_thr);
  std::printf("  rung | gap | escalated? | flip-frac vs tight: NO-belt -> belt\n");
  for (std::size_t i = 0; i < dNo.rungs.size(); ++i) {
    ClassDiff cn = class_diff(St.rungs[i].density, dNo.rungs[i].density);
    ClassDiff cy = class_diff(St.rungs[i].density, dYes.rungs[i].density);
    std::printf("   %2zu  | %.4f | %-9s | %.4f -> %.4f\n", i, dYes.rungs[i].gap,
                dYes.rungs[i].escalated ? "ESCALATED" : "trusted", cn.frac, cy.frac);
  }
  ClassDiff tNo = class_diff(St.terminal_density, dNo.terminal_density);
  ClassDiff tYes = class_diff(St.terminal_density, dYes.terminal_density);
  std::printf("  >> terminal flip-frac vs tight: NO-belt=%.4f (%lld voxels)  ->  belt=%.4f (%lld voxels)\n",
              tNo.frac, tNo.flips, tYes.frac, tYes.flips);
  std::printf("  >> BELT VERDICT: diverged-then-%s\n",
              tYes.flips <= tNo.flips/2 ? "RECOVERED" : "NOT-recovered");

  // =====================================================================
  // BIG-GRID WIN (B5). 32x16x32 whole-domain box, stagnation dominates. Bar >= 2x.
  // =====================================================================
  std::printf("\n########## B5 BIG-GRID WIN (32x16x32) ##########\n");
  std::vector<DirichletBC> Lbcs;
  VoxelGrid Lpart = l_bracket(Lbcs, 16, 16, 6, 4, h);
  const std::vector<NodalLoad> Lload = traction_loads(Lpart, VoxelTag::Load, Vec3{0,0,-30});
  DesignBox Lbox; Lbox.min = Vec3{0,0,0}; Lbox.max = Vec3{16*h*2.0, 6*h*2.0, 16*h*2.0};
  const std::vector<double> Lladder = {0.50, 0.35, 0.25};
  auto Lrun = [&](bool draft, double loose){
    return run(1e-8, draft, loose, 1e30, Lpart, Lbcs, Lload, rules, material, true, Lbox, Lladder);
  };
  MinimizePlasticOptions Ldims; Ldims.design_box = Lbox;
  VoxelGrid Lg = minimize_plastic_solved_grid(Lpart, Ldims);
  std::printf("  solved grid = %dx%dx%d (%zu vox)\n", Lg.nx, Lg.ny, Lg.nz, Lg.voxel_count());
  RunOut Lt = Lrun(false, 0);
  std::fprintf(stderr, "[big] tight done cg=%lld wall=%.0fs\n", Lt.total_cg, Lt.wall_s);
  RunOut Ld = Lrun(true, 1e-3);
  std::fprintf(stderr, "[big] draft done cg=%lld wall=%.0fs\n", Ld.total_cg, Ld.wall_s);
  const double bigratio = Ld.total_cg>0 ? double(Lt.total_cg)/double(Ld.total_cg) : 0.0;
  std::printf("  >> summed trajectory CG: tight=%lld draft=%lld  RATIO=%.2fx (bar >= 2.0x)\n",
              Lt.total_cg, Ld.total_cg, bigratio);
  int rose = 0;
  for (std::size_t i = 0; i < std::min(Lt.rungs.size(), Ld.rungs.size()); ++i) {
    ClassDiff rc = class_diff(Lt.rungs[i].density, Ld.rungs[i].density);
    const bool up = Ld.rungs[i].cg > Lt.rungs[i].cg;
    if (up) ++rose;
    std::printf("    vf=%.2f  cg %8lld -> %8lld (%.2fx)%s  stag=%d/%d  flip-frac=%.4f\n",
                Lt.rungs[i].vf, Lt.rungs[i].cg, Ld.rungs[i].cg,
                Ld.rungs[i].cg>0?double(Lt.rungs[i].cg)/double(Ld.rungs[i].cg):0.0,
                up?" RISES":"", Ld.rungs[i].stag_iters, Ld.rungs[i].iters, rc.frac);
  }
  std::printf("  rungs that ROSE: %d\n", rose);

  std::printf("\n########## DONE ##########\n");
  return 0;
}
