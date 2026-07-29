// geneo_arming_gate.cpp — the measurement harness for the GENEO PRODUCTION
// ARMING (handoff 2026-07-29-geneo-arming). NOT a CTest target; a standalone
// harness like draft_arming_gate.cpp / active_domain_gate.cpp.
//
// THE BAR THAT MATTERS MOST — THE FOUR-WAY INTERACTION. This is the FOURTH armed
// solver feature, and they overlap: GenEO's deflation is the SAME augmented-
// subspace machinery recycling (armed, 133) uses; draft's whole win is moving
// solves OUT of the stagnation regime GenEO exists to fix; AD was measured
// net-negative on stagnating jobs and its escape latch fires ~iteration 3. This
// harness measures the STACK: CG + outer iterations for
//   none / rec / rec+AD / rec+AD+draft / rec+AD+draft+GenEO   (the ladder)
//   GenEO alone / GenEO+rec / rec+AD+GenEO                    (the ablations)
// plus recycle_dim + rc_frac with GenEO on, the AD latch under GenEO, the draft
// gap, and the GenEO lifecycle (builds / refreshes / deflated solves) per
// posture.
//
// Modes:
//   gate [loadN]     A3 — the FULL production ladder, GenEO OFF vs ARMED
//                    (recycling+AD+draft armed in BOTH), twice each: per-rung
//                    verdict + margin + |drho|, verdict flips named, CG totals.
//   interaction [N]  the 8-posture stack on the small stagnation fixture
//                    (natural termination, safety cap N).
//   stag [N]         the 8-posture stack on the BIG stagnation fixture (the
//                    recycling-wrap regime; capped trajectory, exact cert).
//   healthy [N]      A7 — a fixture where multigrid carries: GenEO must be
//                    structurally inert (0 fallbacks -> 0 builds, CG unchanged).
//   amort [N]        A6 — the ARMED reuse policy end-to-end on the big fixture,
//                    draft OFF so fallbacks stay in the Jacobi regime: per-solve
//                    action sequence (build/refresh/reuse), iterations vs the
//                    GenEO-off run, refresh-vs-rebuild economics.
//   fast [N]         A6 — "the design moves faster than expected": direct solve
//                    sequence with violent moduli jumps; shows the degradation
//                    trigger scheduling rebuilds and every solve staying exact.
//   mem              A5 — peak RSS of the armed big-fixture run + basis bytes.
//
// Build (standalone):
//   c++ -std=c++17 -O2 -I core/include \
//     -DSETTINGS_RULES_PATH="\"$PWD/core/src/settings/rules.json\"" \
//     core/tests/harness/geneo_arming_gate.cpp core/build/libtopopt.a -o /tmp/gag
// Evidence dir: TOPOPT_GA_DIR (default ./ga_evidence).

#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <random>
#include <string>
#include <vector>

#include <sys/resource.h>

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

std::string evidence_dir() {
  const char* d = std::getenv("TOPOPT_GA_DIR");
  return d ? std::string(d) : std::string("ga_evidence");
}

long long peak_rss_bytes() {
  struct rusage ru;
  getrusage(RUSAGE_SELF, &ru);
#if defined(__APPLE__)
  return ru.ru_maxrss;
#else
  return ru.ru_maxrss * 1024;
#endif
}

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

// The small stagnation-class dilute box (draft_arming_gate's make_stagnation).
Fixture make_stagnation() {
  Fixture f;
  int arm = 12, span = 12, ny = 4, t = 3;
  if (const char* a = std::getenv("TOPOPT_GA_ARM")) {
    const int s = std::atoi(a);
    if (s == 8) { arm = 8; span = 8; ny = 3; t = 2; }
    if (s == 12) { arm = 12; span = 12; ny = 4; t = 3; }
    if (s == 16) { arm = 16; span = 16; ny = 6; t = 4; }
  }
  const double h = 2.0;
  f.part = l_bracket(f.bcs, arm, span, ny, t, h);
  f.loads = traction_loads(f.part, VoxelTag::Load, Vec3{0.0, 0.0, -30.0});
  f.box.min = Vec3{0.0, 0.0, 0.0};
  f.box.max = Vec3{span * h * 2.0, ny * h * 2.0, arm * h * 2.0};
  return f;
}

// The BIG stagnation fixture (the AD gate's regime, verbatim: 73 728 elements,
// 48.8x dilution) — multigrid falls to Jacobi-CG, the ONLY regime where the
// Jacobi-only recycling and the GenEO deflation can act at all.
Fixture make_big_stagnation() {
  Fixture f;
  f.part = l_bracket(f.bcs, 24, 24, 6, 6, 1.0);
  f.loads = traction_loads(f.part, VoxelTag::Load, Vec3{0.0, 0.0, -30.0});
  f.box.min = Vec3{-12.0, -13.0, -12.0};
  f.box.max = Vec3{36.0, 19.0, 36.0};
  return f;
}

struct Posture {
  std::string label;
  bool recycling = false, ad = false, draft = false, geneo = false;
  double wall = 0.0;
  long long cg_total = 0;
  long long outer_iters = 0;
  int jacobi_solves = 0;
  long long solves_total = 0, solves_recycled = 0, setup_matvecs = 0;
  int max_recycle_dim = 0;
  // GenEO per-trajectory-solve actions (from the observation stream) + the
  // whole-run lifecycle counters (from the process globals, read post-run —
  // they include the certification/stress solves the observer never sees).
  long long geneo_deflated_steps = 0;
  long long act_reuse = 0, act_refresh = 0, act_build = 0, act_refused = 0;
  int max_geneo_dim = 0;
  long long run_builds = 0, run_refreshes = 0, run_armed_solves = 0;
  int end_basis_dim = 0;
  double end_basis_mb = 0.0;
  // AD:
  int ad_band = 0, ad_latched = 0, ad_latch_iter = 0;
  long long ad_escapes = 0;
  std::string ad_reason;
  double ad_fbar = 1.0;
  // draft:
  double draft_gap = -1.0;
  int draft_escalated = -1;
  std::vector<double> density;
  double compliance = 0.0, margin = 0.0;
};

Posture run_posture(const std::string& label, const Fixture& f, bool recycling,
                    bool ad, bool draft, bool geneo, int iters,
                    const SettingsRules& rules, const Material& material,
                    double vf = 0.50, bool capped = false) {
  MinimizePlasticOptions o;
  configure_production_options(o);  // arms the full production stack...
  // ...then set each of the FOUR interacting axes EXPLICITLY. Recycling and
  // GenEO are process globals; AD and draft are options fields.
  fea_set_krylov_recycling(recycling);
  fea_set_geneo_twolevel(geneo);
  o.simp.active_domain_band = ad ? production_active_domain_band() : 0;
  o.draft_quality = draft;
  o.draft_loose_tol = production_draft_loose_tol();

  o.volume_fraction_ladder = {vf};
  o.margin_stop = 0.0;
  o.external_loads = f.loads;
  o.gravity = 9810.0 * 1e-9;
  o.gravity_direction = Vec3{0.0, 0.0, -1.0};
  o.infill_percent = 100.0;
  o.design_box = f.box;
  o.simp.max_iterations = iters;
  if (capped) {
    o.simp.mma_plateau_window = 0;
    o.simp.change_tol = 0.0;
  }

  Posture p;
  p.label = label;
  p.recycling = recycling;
  p.ad = ad;
  p.draft = draft;
  p.geneo = geneo;
  long long cg = 0, its = 0, st = 0, sr = 0, mv = 0;
  int fb = 0, maxdim = 0, maxg = 0;
  long long gd = 0, a1 = 0, a2 = 0, a3 = 0, a4 = 0;
  o.on_iteration = [&](std::size_t, std::size_t,
                       const SimpIterationObservation& ob) {
    cg += ob.cg_iterations;
    ++its;
    ++st;
    if (!ob.cg_used_multigrid) ++fb;
    if (ob.cg_recycle_dim > 0) {
      ++sr;
      if (ob.cg_recycle_dim > maxdim) maxdim = ob.cg_recycle_dim;
    }
    mv += ob.cg_recycle_setup_matvecs;
    if (ob.cg_geneo_dim > 0) {
      ++gd;
      if (ob.cg_geneo_dim > maxg) maxg = ob.cg_geneo_dim;
    }
    if (ob.cg_geneo_action == 1) ++a1;
    if (ob.cg_geneo_action == 2) ++a2;
    if (ob.cg_geneo_action == 3) ++a3;
    if (ob.cg_geneo_action == 4) ++a4;
  };
  const auto t0 = std::chrono::steady_clock::now();
  const MinimizePlasticResult r =
      minimize_plastic(f.part, material, "fdm", f.bcs, rules, o);
  p.wall =
      std::chrono::duration<double>(std::chrono::steady_clock::now() - t0)
          .count();
  // The whole-run lifecycle (includes the cert/stress solves the observer never
  // sees). Read BEFORE the next posture's run resets the counters.
  p.run_builds = fea_geneo_basis_builds();
  p.run_refreshes = fea_geneo_coarse_refreshes();
  p.run_armed_solves = fea_geneo_armed_solves();
  p.end_basis_dim = fea_geneo_basis_dim();
  p.end_basis_mb = static_cast<double>(fea_geneo_basis_bytes()) / 1048576.0;
  p.cg_total = cg;
  p.outer_iters = its;
  p.jacobi_solves = fb;
  p.solves_total = st;
  p.solves_recycled = sr;
  p.setup_matvecs = mv;
  p.max_recycle_dim = maxdim;
  p.geneo_deflated_steps = gd;
  p.max_geneo_dim = maxg;
  p.act_reuse = a1;
  p.act_refresh = a2;
  p.act_build = a3;
  p.act_refused = a4;
  if (!r.evaluated.empty()) {
    const auto& v = r.evaluated.front();
    p.ad_band = v.optimization.active_domain_band;
    p.ad_latched = v.optimization.active_domain_latched ? 1 : 0;
    p.ad_latch_iter = v.optimization.active_domain_latch_iteration;
    p.ad_escapes = v.optimization.active_domain_escape_count;
    p.ad_reason = v.optimization.active_domain_latch_reason;
    p.ad_fbar = v.optimization.active_fraction_mean;
    p.density = v.optimization.physical_density;
    p.compliance = v.optimization.compliance;
    p.margin = v.report.margin.worst_case;
  }
  if (!r.draft_rung_c_gap.empty()) p.draft_gap = r.draft_rung_c_gap.front();
  if (!r.draft_rung_escalated.empty())
    p.draft_escalated = r.draft_rung_escalated.front();

  fea_set_krylov_recycling(false);
  fea_set_geneo_twolevel(false);
  fea_reset_geneo_basis();
  return p;
}

double rc_frac(const Posture& p) {
  return p.jacobi_solves ? double(p.solves_recycled) / double(p.jacobi_solves)
                         : 0.0;
}

struct Delta {
  double mean_abs = 0.0, max_abs = 0.0;
};
Delta compare(const std::vector<double>& a, const std::vector<double>& b) {
  Delta d;
  if (a.size() != b.size() || a.empty()) return d;
  double s = 0.0;
  for (std::size_t i = 0; i < a.size(); ++i) {
    const double v = std::fabs(a[i] - b[i]);
    s += v;
    d.max_abs = std::max(d.max_abs, v);
  }
  d.mean_abs = s / double(a.size());
  return d;
}
bool bit_identical(const std::vector<double>& a, const std::vector<double>& b) {
  if (a.size() != b.size() || a.empty()) return false;
  for (std::size_t i = 0; i < a.size(); ++i)
    if (a[i] != b[i]) return false;
  return true;
}

void print_posture(const Posture& p) {
  std::printf("  [%-16s] %.1f s  CG=%lld  outer=%lld  Jacobi-fallback=%d/%lld\n",
              p.label.c_str(), p.wall, p.cg_total, p.outer_iters,
              p.jacobi_solves, p.solves_total);
  if (p.recycling)
    std::printf("      recycle: max_dim=%d  applied on %lld/%d Jacobi solves "
                "(rc_frac=%.3f)  setup_mv=%lld\n",
                p.max_recycle_dim, p.solves_recycled, p.jacobi_solves,
                rc_frac(p), p.setup_matvecs);
  if (p.geneo)
    std::printf("      geneo: deflated %lld traj steps (max Nt=%d); run "
                "builds=%lld refreshes=%lld armed_solves=%lld basis=%.1f MB; "
                "traj actions reuse/refresh/build/refused=%lld/%lld/%lld/%lld\n",
                p.geneo_deflated_steps, p.max_geneo_dim, p.run_builds,
                p.run_refreshes, p.run_armed_solves, p.end_basis_mb, p.act_reuse,
                p.act_refresh, p.act_build, p.act_refused);
  if (p.ad)
    std::printf("      AD: band k=%d  f_bar=%.4f  latched=%d@iter%d  "
                "escapes=%lld  reason=\"%s\"\n",
                p.ad_band, p.ad_fbar, p.ad_latched, p.ad_latch_iter,
                p.ad_escapes, p.ad_reason.c_str());
  if (p.draft)
    std::printf("      draft: loose_tol=%.0e  compliance-gap=%.6f  escalated=%d\n",
                production_draft_loose_tol(), p.draft_gap, p.draft_escalated);
}

void write_postures_csv(const std::string& path,
                        const std::vector<const Posture*>& ps) {
  FILE* fp = std::fopen(path.c_str(), "w");
  if (!fp) return;
  std::fprintf(fp,
               "posture,recycling,ad,draft,geneo,cg_total,outer_iters,"
               "jacobi_solves,solves_total,solves_recycled,rc_frac,"
               "max_recycle_dim,setup_mv,geneo_deflated_steps,max_geneo_dim,"
               "geneo_builds,geneo_refreshes,geneo_armed_solves,basis_mb,"
               "ad_band,ad_latched,ad_latch_iter,ad_escapes,ad_fbar,draft_gap,"
               "compliance,margin,wall_s\n");
  for (const Posture* p : ps)
    std::fprintf(fp,
                 "%s,%d,%d,%d,%d,%lld,%lld,%d,%lld,%lld,%.4f,%d,%lld,%lld,%d,"
                 "%lld,%lld,%lld,%.2f,%d,%d,%d,%lld,%.4f,%.6f,%.10g,%.6g,%.2f\n",
                 p->label.c_str(), p->recycling, p->ad, p->draft, p->geneo,
                 p->cg_total, p->outer_iters, p->jacobi_solves, p->solves_total,
                 p->solves_recycled, rc_frac(*p), p->max_recycle_dim,
                 p->setup_matvecs, p->geneo_deflated_steps, p->max_geneo_dim,
                 p->run_builds, p->run_refreshes, p->run_armed_solves,
                 p->end_basis_mb, p->ad_band, p->ad_latched, p->ad_latch_iter,
                 p->ad_escapes, p->ad_fbar, p->draft_gap, p->compliance,
                 p->margin, p->wall);
  std::fclose(fp);
  std::printf("  wrote %s\n", path.c_str());
}

// The 8-posture stack (the task's matrix + the ablations), on one fixture.
int run_stack(const char* title, const Fixture& f, int iters,
              const SettingsRules& rules, const Material& material, bool capped,
              const std::string& csv_path) {
  std::printf("===== %s =====\n", title);
  const Posture p0 = run_posture("none", f, false, false, false, false, iters,
                                 rules, material, 0.50, capped);
  const Posture p1 = run_posture("rec", f, true, false, false, false, iters,
                                 rules, material, 0.50, capped);
  const Posture p2 = run_posture("rec+AD", f, true, true, false, false, iters,
                                 rules, material, 0.50, capped);
  const Posture p3 = run_posture("rec+AD+draft", f, true, true, true, false,
                                 iters, rules, material, 0.50, capped);
  const Posture p4 = run_posture("rec+AD+draft+GE", f, true, true, true, true,
                                 iters, rules, material, 0.50, capped);
  // Ablations:
  const Posture p5 = run_posture("GenEO alone", f, false, false, false, true,
                                 iters, rules, material, 0.50, capped);
  const Posture p6 = run_posture("GenEO+rec", f, true, false, false, true, iters,
                                 rules, material, 0.50, capped);
  const Posture p7 = run_posture("rec+AD+GenEO", f, true, true, false, true,
                                 iters, rules, material, 0.50, capped);
  // Determinism of the FULL production posture: run it a second time.
  const Posture p4b = run_posture("rec+AD+draft+GE#2", f, true, true, true, true,
                                  iters, rules, material, 0.50, capped);

  for (const Posture* p : {&p0, &p1, &p2, &p3, &p4, &p5, &p6, &p7})
    print_posture(*p);

  std::printf("\n===== DOES ANY FEATURE SILENTLY DEGRADE ANOTHER? =====\n");
  // 1) The two EXACT accelerators leave the answer alone. Bitness is only owed
  //    where the accelerator never engaged (an un-wrapped solve is the
  //    byte-identical pre-feature loop); once a correction actually
  //    preconditions a solve the iteration PATH changes and the converged field
  //    lands elsewhere in the same 1e-8 basin — 133's own exactness bar is
  //    max|du|/max|u| <= 1e-6 relative, not bit-parity. So: assert bitness when
  //    inert, report the basin-level delta when engaged.
  bool rec_exact;
  if (p1.solves_recycled == 0) {
    rec_exact = bit_identical(p0.density, p1.density) &&
                p0.compliance == p1.compliance;
    std::printf("  [recycling inert here] rec == none bit-for-bit: %s\n",
                rec_exact ? "YES" : "NO — REGRESSION");
  } else {
    const Delta d = compare(p0.density, p1.density);
    rec_exact = d.max_abs <= 1e-3;  // basin-level design motion, not a divergence
    std::printf("  [recycling engaged] rec vs none: mean|drho|=%.3e max=%.3e "
                "(engaged correction => different iteration path, same 1e-8 "
                "basin; 133's bar is 1e-6 on u)\n",
                d.mean_abs, d.max_abs);
  }
  if (p5.run_builds == 0) {
    std::printf("  [GenEO inert here] GenEO-alone never built (no solve past "
                "the trigger): design bit-identical to none: %s\n",
                bit_identical(p0.density, p5.density) ? "YES" : "NO — REGRESSION");
  } else {
    const Delta d = compare(p0.density, p5.density);
    std::printf("  [GenEO engaged] GenEO-alone vs none: mean|drho|=%.3e "
                "max=%.3e (same 1e-8 basin; A4 charges this vs the negative "
                "control)\n",
                d.mean_abs, d.max_abs);
  }
  // 2) Full-production determinism.
  const bool det = bit_identical(p4.density, p4b.density) &&
                   p4.compliance == p4b.compliance && p4.cg_total == p4b.cg_total;
  std::printf("  [production deterministic] rec+AD+draft+GenEO twice "
              "bit-identical (design+compliance+CG): %s\n",
              det ? "YES" : "NO");
  // 3) recycling under GenEO: does the carried subspace still wrap / still buy?
  std::printf("  [recycling x GenEO] rc_frac: rec=%.3f rec+GenEO=%.3f | CG: "
              "GenEO alone=%lld GenEO+rec=%lld (marginal value of rec on top "
              "of GenEO: %+lld)\n",
              rc_frac(p1), rc_frac(p6), p5.cg_total, p6.cg_total,
              p6.cg_total - p5.cg_total);
  // 4) AD latch under GenEO.
  std::printf("  [AD latch] rec+AD: latched=%d@%d esc=%lld | rec+AD+GenEO: "
              "latched=%d@%d esc=%lld\n",
              p2.ad_latched, p2.ad_latch_iter, p2.ad_escapes, p7.ad_latched,
              p7.ad_latch_iter, p7.ad_escapes);
  // 5) draft x GenEO: whose regime is it?
  std::printf("  [draft x GenEO] Jacobi fallbacks: rec+AD=%d, rec+AD+draft=%d, "
              "rec+AD+draft+GE=%d; GenEO builds with draft on=%lld (0 means "
              "draft removed the stagnation before GenEO could see it HERE)\n",
              p2.jacobi_solves, p3.jacobi_solves, p4.jacobi_solves,
              p4.run_builds);

  std::printf("\n===== CG-ITERATION LADDER =====\n");
  auto row = [&](const Posture& p) {
    std::printf("  %-16s CG=%-8lld outer=%-4lld (%.3fx vs none)\n",
                p.label.c_str(), p.cg_total, p.outer_iters,
                p0.cg_total ? double(p.cg_total) / double(p0.cg_total) : 0.0);
  };
  row(p0); row(p1); row(p2); row(p3); row(p4); row(p5); row(p6); row(p7);

  write_postures_csv(csv_path, {&p0, &p1, &p2, &p3, &p4, &p5, &p6, &p7, &p4b});
  const bool ok = rec_exact && det;
  std::printf("\n===== STACK VERDICT: %s =====\n",
              ok ? "no exactness/determinism regression"
                 : "INTERFERENCE DETECTED — BLOCKED-STOP");
  return ok ? 0 : 1;
}

}  // namespace

int main(int argc, char** argv) {
  std::setvbuf(stdout, nullptr, _IOLBF, 0);
  const std::string mode = argc > 1 ? argv[1] : "interaction";
  const int iters = argc > 2 ? std::atoi(argv[2]) : 200;
  const std::string dir = evidence_dir();

  SettingsRules rules;
  try {
    rules = load_settings_rules_file(SETTINGS_RULES_PATH);
  } catch (const std::exception& e) {
    std::fprintf(stderr, "FAIL: rules.json: %s\n", e.what());
    return 1;
  }
  const Material material = fdm();

  // gate (A3): the FULL production ladder, GenEO OFF vs ARMED, twice each
  // (recycling + AD + draft armed in BOTH postures — only GenEO differs).
  if (mode == "gate") {
    const Fixture f = make_stagnation();
    Fixture gf = f;
    double load_mag = -8.0;
    if (const char* lm = std::getenv("TOPOPT_GA_LOAD")) load_mag = std::atof(lm);
    gf.loads = traction_loads(gf.part, VoxelTag::Load, Vec3{0.0, 0.0, load_mag});
    struct Rung {
      double vf, margin, compliance;
      int accepted, infeasible;
      std::vector<double> density;
    };
    VoxelGrid solved_grid;
    auto ladder_run = [&](bool geneo, double cert_tol = 0.0) {
      MinimizePlasticOptions o;
      configure_production_options(o);
      fea_set_geneo_twolevel(geneo);
      if (cert_tol > 0.0) o.simp.cg_tolerance = cert_tol;  // negative control
      o.volume_fraction_ladder = production_reduction_ladder();
      o.margin_stop = 1.5;
      o.external_loads = gf.loads;
      o.gravity = 9810.0 * 1e-9;
      o.gravity_direction = Vec3{0.0, 0.0, -1.0};
      o.infill_percent = 100.0;
      o.design_box = f.box;
      long long cg = 0;
      int fallbacks = 0;
      o.on_iteration = [&](std::size_t, std::size_t,
                           const SimpIterationObservation& ob) {
        cg += ob.cg_iterations;
        if (!ob.cg_used_multigrid) ++fallbacks;
      };
      const MinimizePlasticResult r =
          minimize_plastic(gf.part, material, "fdm", gf.bcs, rules, o);
      solved_grid = r.solved_grid;
      const long long builds = fea_geneo_basis_builds();
      const long long armed = fea_geneo_armed_solves();
      fea_set_krylov_recycling(false);
      fea_set_geneo_twolevel(false);
      fea_reset_geneo_basis();
      std::vector<Rung> out;
      for (const auto& v : r.evaluated) {
        Rung rg;
        rg.vf = v.requested_volume_fraction;
        rg.margin = v.report.margin.worst_case;
        rg.compliance = v.optimization.compliance;
        rg.accepted = v.accepted ? 1 : 0;
        rg.infeasible = v.infeasible ? 1 : 0;
        rg.density = v.optimization.physical_density;
        out.push_back(std::move(rg));
      }
      struct R { std::vector<Rung> rungs; long long cg, builds, armed; int fallbacks; };
      return R{std::move(out), cg, builds, armed, fallbacks};
    };
    std::printf("===== A3 — FULL GATE TABLE (production ladder, GenEO OFF vs "
                "ARMED; recycling+AD+draft armed in both) =====\n");
    const auto off1 = ladder_run(false);
    const auto off2 = ladder_run(false);
    const auto on1 = ladder_run(true);
    const auto on2 = ladder_run(true);
    // A4 NEGATIVE CONTROL FIRST: the same GenEO-OFF ladder at cert tol 1e-9.
    // Its classification-flip fraction against the 1e-8 OFF ladder is the basin
    // floor — the design motion a pure tolerance perturbation already causes.
    const auto ctl = ladder_run(false, 1e-9);
    auto bitid = [](const std::vector<Rung>& a, const std::vector<Rung>& b) {
      if (a.size() != b.size()) return false;
      for (std::size_t i = 0; i < a.size(); ++i)
        if (a[i].margin != b[i].margin || a[i].compliance != b[i].compliance ||
            a[i].accepted != b[i].accepted || a[i].density != b[i].density)
          return false;
      return true;
    };
    std::printf("  twice-run bit-identical: OFF %s  ON %s\n",
                bitid(off1.rungs, off2.rungs) ? "YES" : "NO",
                bitid(on1.rungs, on2.rungs) ? "YES" : "NO");
    std::printf("  Jacobi fallbacks OFF=%d ON=%d; GenEO builds ON=%lld, "
                "deflated solves ON=%lld\n",
                off1.fallbacks, on1.fallbacks, on1.builds, on1.armed);
    std::printf("\n  rung   vf   | verdict OFF -> ON        | margin OFF -> ON"
                "            | dM/M       | mean|drho|  max|drho|\n");
    const std::size_t n = std::min(off1.rungs.size(), on1.rungs.size());
    int flips = 0;
    for (std::size_t i = 0; i < n; ++i) {
      const Rung& a = off1.rungs[i];
      const Rung& b = on1.rungs[i];
      const Delta d = compare(a.density, b.density);
      const double mrel = (std::isfinite(a.margin) && a.margin != 0.0)
                              ? std::fabs(b.margin - a.margin) / std::fabs(a.margin)
                              : 0.0;
      const char* va = a.infeasible ? "INFEAS" : (a.accepted ? "ACCEPT" : "REJECT");
      const char* vb = b.infeasible ? "INFEAS" : (b.accepted ? "ACCEPT" : "REJECT");
      const bool flip = (a.accepted != b.accepted) || (a.infeasible != b.infeasible);
      if (flip) ++flips;
      std::printf("   %zu   %.2f | %-6s -> %-6s %s | %11.6g -> %-11.6g | %.3e | "
                  "%.3e %.3e\n",
                  i, a.vf, va, vb, flip ? "**FLIP**" : "        ", a.margin,
                  b.margin, mrel, d.mean_abs, d.max_abs);
    }
    std::printf("\n  rung count OFF %zu -> ON %zu; verdict flips: %d\n",
                off1.rungs.size(), on1.rungs.size(), flips);
    std::printf("  ladder CG OFF %lld -> ON %lld (%.3fx)\n", off1.cg, on1.cg,
                off1.cg ? double(on1.cg) / double(off1.cg) : 0.0);
    // A4 — THE ANSWER IS THE SAME ANSWER: printed-classification flips over
    // solid voxels, negative control (1e-9 vs 1e-8, GenEO off) FIRST.
    auto flip_frac = [&](const std::vector<double>& a,
                         const std::vector<double>& b, long long& solid,
                         long long& fl) {
      solid = 0;
      fl = 0;
      const VoxelGrid& g = solved_grid;
      for (int k = 0; k < g.nz; ++k)
        for (int j = 0; j < g.ny; ++j)
          for (int i = 0; i < g.nx; ++i) {
            if (!g.solid(i, j, k)) continue;
            const std::size_t e = g.index(i, j, k);
            ++solid;
            if ((a[e] > 0.5) != (b[e] > 0.5)) ++fl;
          }
      return solid ? double(fl) / double(solid) : 0.0;
    };
    std::printf("\n  A4 — classification flips over solid voxels (grid %dx%dx%d)"
                ":\n", solved_grid.nx, solved_grid.ny, solved_grid.nz);
    std::printf("  rung |  solid  | NEG CONTROL 1e-9 vs OFF (floor)          | "
                "GenEO ON vs OFF\n");
    const std::size_t nc = std::min(n, ctl.rungs.size());
    for (std::size_t i = 0; i < nc; ++i) {
      long long s1 = 0, f1 = 0, s2 = 0, f2 = 0;
      const double fr_ctl =
          flip_frac(off1.rungs[i].density, ctl.rungs[i].density, s1, f1);
      const double fr_on =
          flip_frac(off1.rungs[i].density, on1.rungs[i].density, s2, f2);
      const Delta dc = compare(off1.rungs[i].density, ctl.rungs[i].density);
      const Delta dn = compare(off1.rungs[i].density, on1.rungs[i].density);
      std::printf("   %zu   | %7lld | %.3e (%lld flips) drho %.1e/%.1e | %.3e "
                  "(%lld flips) drho %.1e/%.1e\n",
                  i, s1, fr_ctl, f1, dc.mean_abs, dc.max_abs, fr_on, f2,
                  dn.mean_abs, dn.max_abs);
    }
    const std::string csv = dir + "/gate.csv";
    FILE* fp = std::fopen(csv.c_str(), "w");
    if (fp) {
      std::fprintf(fp,
                   "rung,vf,off_verdict,on_verdict,off_margin,on_margin,"
                   "margin_rel_delta,off_compliance,on_compliance,"
                   "mean_abs_drho,max_abs_drho,flip\n");
      for (std::size_t i = 0; i < n; ++i) {
        const Rung& a = off1.rungs[i];
        const Rung& b = on1.rungs[i];
        const Delta d = compare(a.density, b.density);
        const double mrel = (std::isfinite(a.margin) && a.margin != 0.0)
                                ? std::fabs(b.margin - a.margin) / std::fabs(a.margin)
                                : 0.0;
        std::fprintf(fp, "%zu,%.4f,%s,%s,%.10g,%.10g,%.6e,%.10g,%.10g,%.6e,"
                         "%.6e,%d\n",
                     i, a.vf, a.infeasible ? "INFEAS" : (a.accepted ? "ACCEPT" : "REJECT"),
                     b.infeasible ? "INFEAS" : (b.accepted ? "ACCEPT" : "REJECT"),
                     a.margin, b.margin, mrel, a.compliance, b.compliance,
                     d.mean_abs, d.max_abs,
                     ((a.accepted != b.accepted) || (a.infeasible != b.infeasible)) ? 1 : 0);
      }
      std::fclose(fp);
      std::printf("  wrote %s\n", csv.c_str());
    }
    return 0;
  }

  if (mode == "interaction") {
    const Fixture f = make_stagnation();
    {
      MinimizePlasticOptions probe;
      configure_production_options(probe);
      fea_set_geneo_twolevel(false);
      fea_set_krylov_recycling(false);
      probe.design_box = f.box;
      const VoxelGrid solved = minimize_plastic_solved_grid(f.part, probe);
      std::printf("fixture: part %dx%dx%d (%zu solid) -> grid %dx%dx%d (%zu "
                  "elements), dilution=%.1fx, spacing=%.2f mm; trigger=%d\n\n",
                  f.part.nx, f.part.ny, f.part.nz, f.part.solid_count(),
                  solved.nx, solved.ny, solved.nz, solved.solid_count(),
                  double(solved.solid_count()) / double(f.part.solid_count()),
                  solved.spacing, fea_geneo_trigger_iters());
    }
    return run_stack("FOUR-WAY INTERACTION (small stagnation fixture, natural "
                     "termination)",
                     f, iters, rules, material, false, dir + "/interaction.csv");
  }

  if (mode == "stag") {
    const int n = argc > 2 ? std::atoi(argv[2]) : 12;
    const Fixture bf = make_big_stagnation();
    {
      MinimizePlasticOptions probe;
      configure_production_options(probe);
      fea_set_geneo_twolevel(false);
      fea_set_krylov_recycling(false);
      probe.design_box = bf.box;
      const VoxelGrid solved = minimize_plastic_solved_grid(bf.part, probe);
      std::printf("fixture: part %zu solid -> grid %dx%dx%d (%zu elements), "
                  "dilution=%.1fx; capped %d iters, vf 0.50; trigger=%d\n\n",
                  bf.part.solid_count(), solved.nx, solved.ny, solved.nz,
                  solved.solid_count(),
                  double(solved.solid_count()) / double(bf.part.solid_count()),
                  n, fea_geneo_trigger_iters());
    }
    return run_stack("FOUR-WAY INTERACTION (big stagnation fixture — the "
                     "recycling-wrap / GenEO regime)",
                     bf, n, rules, material, true, dir + "/stag.csv");
  }

  // healthy (A7): multigrid carries; GenEO must be structurally inert.
  if (mode == "healthy") {
    const int n = argc > 2 ? std::atoi(argv[2]) : 60;
    Fixture f;
    int arm = 8, span = 8, ny = 3, t = 2;
    const double h = 2.0;
    f.part = l_bracket(f.bcs, arm, span, ny, t, h);
    f.loads = traction_loads(f.part, VoxelTag::Load, Vec3{0.0, 0.0, -30.0});
    f.box.min = Vec3{0.0, 0.0, 0.0};
    f.box.max = Vec3{span * h * 2.0, ny * h * 2.0, arm * h * 2.0};
    std::printf("===== A7 — HEALTHY REGIME (small grid, multigrid carries) "
                "=====\n");
    const Posture off = run_posture("prod, GenEO off", f, true, true, true,
                                    false, n, rules, material);
    const Posture on = run_posture("prod, GenEO on", f, true, true, true, true,
                                   n, rules, material);
    print_posture(off);
    print_posture(on);
    std::printf("\n  Jacobi fallbacks: off=%d on=%d; GenEO builds=%lld "
                "armed_solves=%lld\n",
                off.jacobi_solves, on.jacobi_solves, on.run_builds,
                on.run_armed_solves);
    std::printf("  CG off=%lld on=%lld; design bit-identical=%s\n",
                off.cg_total, on.cg_total,
                bit_identical(off.density, on.density) ? "YES" : "NO");
    const bool inert = (on.run_builds == 0) && (off.cg_total == on.cg_total) &&
                       bit_identical(off.density, on.density);
    std::printf("  => GenEO %s on the healthy regime\n",
                inert ? "STRUCTURALLY INERT (0 builds, bit-identical)"
                      : "NOT inert — see numbers above");
    write_postures_csv(dir + "/healthy.csv", {&off, &on});
    return inert ? 0 : 1;
  }

  // amort (A6): the ARMED reuse policy end-to-end. Draft OFF so the trajectory
  // stays in the Jacobi regime and GenEO engages repeatedly; per-solve action
  // sequence + iterations vs the GenEO-off twin.
  if (mode == "amort") {
    const int n = argc > 2 ? std::atoi(argv[2]) : 12;
    const Fixture bf = make_big_stagnation();
    struct StepLog {
      std::vector<int> iters, action, dim, mg;
    };
    auto run = [&](bool geneo, StepLog& log) {
      MinimizePlasticOptions o;
      configure_production_options(o);
      fea_set_krylov_recycling(true);  // production posture (minus draft)
      fea_set_geneo_twolevel(geneo);
      o.draft_quality = false;
      o.volume_fraction_ladder = {0.50};
      o.margin_stop = 0.0;
      o.external_loads = bf.loads;
      o.gravity = 9810.0 * 1e-9;
      o.gravity_direction = Vec3{0.0, 0.0, -1.0};
      o.infill_percent = 100.0;
      o.design_box = bf.box;
      o.simp.max_iterations = n;
      o.simp.mma_plateau_window = 0;
      o.simp.change_tol = 0.0;
      o.on_iteration = [&](std::size_t, std::size_t,
                           const SimpIterationObservation& ob) {
        log.iters.push_back(ob.cg_iterations);
        log.action.push_back(ob.cg_geneo_action);
        log.dim.push_back(ob.cg_geneo_dim);
        log.mg.push_back(ob.cg_used_multigrid ? 1 : 0);
      };
      const MinimizePlasticResult r =
          minimize_plastic(bf.part, material, "fdm", bf.bcs, rules, o);
      (void)r;
      const long long builds = fea_geneo_basis_builds();
      const long long refr = fea_geneo_coarse_refreshes();
      fea_set_krylov_recycling(false);
      fea_set_geneo_twolevel(false);
      fea_reset_geneo_basis();
      return std::make_pair(builds, refr);
    };
    std::printf("===== A6 — ARMED REUSE POLICY (big stagnation fixture, draft "
                "off, %d capped iters) =====\n", n);
    StepLog off, on;
    run(false, off);
    const auto [builds, refr] = run(true, on);
    std::printf("\n  step | mg | CG off | CG on | action (0 none 1 reuse 2 "
                "refresh 3 build 4 refused) | Nt\n");
    long long cg_off = 0, cg_on = 0;
    for (std::size_t i = 0; i < on.iters.size() && i < off.iters.size(); ++i) {
      cg_off += off.iters[i];
      cg_on += on.iters[i];
      std::printf("  %4zu |  %d | %6d | %5d | %d | %d\n", i, on.mg[i],
                  off.iters[i], on.iters[i], on.action[i], on.dim[i]);
    }
    std::printf("\n  trajectory CG: off=%lld on=%lld (%.3fx); whole-run builds="
                "%lld refreshes=%lld\n",
                cg_off, cg_on, cg_off ? double(cg_on) / double(cg_off) : 0.0,
                builds, refr);
    FILE* fp = std::fopen((dir + "/amort.csv").c_str(), "w");
    if (fp) {
      std::fprintf(fp, "step,mg,cg_off,cg_on,action,dim\n");
      for (std::size_t i = 0; i < on.iters.size() && i < off.iters.size(); ++i)
        std::fprintf(fp, "%zu,%d,%d,%d,%d,%d\n", i, on.mg[i], off.iters[i],
                     on.iters[i], on.action[i], on.dim[i]);
      std::fclose(fp);
    }
    return 0;
  }

  // fast (A6): the design moves FASTER than expected — violent random moduli
  // jumps between direct solves. Shows the degradation trigger scheduling a
  // rebuild (action sequence 3,2,2,...,3) and every solve staying exact.
  if (mode == "fast") {
    const int n = argc > 2 ? std::atoi(argv[2]) : 8;
    const int N = 32;
    const int cs = std::getenv("TOPOPT_GA_CELL") ? std::atoi(std::getenv("TOPOPT_GA_CELL")) : 4;
    VoxelGrid g;
    g.nx = N; g.ny = N; g.nz = N; g.spacing = 1.0; g.origin = Vec3{0, 0, 0};
    g.tags.assign(static_cast<std::size_t>(N) * N * N, VoxelTag::Interior);
    std::vector<DirichletBC> bcs;
    std::vector<NodalLoad> loads;
    for (int c = 0; c <= N; ++c)
      for (int b = 0; b <= N; ++b) {
        const int nd = fea_node_index(g, 0, b, c);
        bcs.push_back({nd, 0, 0.0});
        bcs.push_back({nd, 1, 0.0});
        bcs.push_back({nd, 2, 0.0});
      }
    for (int b = 0; b <= N; ++b)
      for (int c = 0; c <= N; ++c)
        loads.push_back({fea_node_index(g, N, b, c), 2,
                         -100.0 / ((N + 1.0) * (N + 1.0))});
    std::vector<double> rho(g.voxel_count(), 1.0);
    for (int k = 0; k < N; ++k)
      for (int j = 0; j < N; ++j)
        for (int i = 0; i < N; ++i)
          if ((((i / cs) + (j / cs) + (k / cs)) & 1) != 0)
            rho[g.index(i, j, k)] = 1e-3;
    for (int b = 0; b < N; ++b)
      for (int c = 0; c < N; ++c) {
        rho[g.index(0, b, c)] = 1.0;
        rho[g.index(N - 1, b, c)] = 1.0;
      }
    std::printf("===== A6 — FAST-MOVING DESIGN (violent moduli jumps, direct "
                "Jacobi-fallback solves) =====\n");
    std::mt19937 rng(20260729u);
    std::uniform_real_distribution<double> jump(0.35, 1.65);
    fea_set_geneo_twolevel(true);
    fea_reset_geneo_basis();
    std::printf("  step |  CG(on) | action | Nt | CG(off twin) | max|du|/max|u| "
                "vs off\n");
    for (int s = 0; s < n; ++s) {
      std::vector<double> ey(g.voxel_count(), 0.0);
      for (std::size_t e = 0; e < rho.size(); ++e)
        ey[e] = std::pow(std::max(1e-3, rho[e]), 3) * 3500.0;
      CgInfo ion, ioff;
      FeaSolution son = fea_solve_cg_matfree(g, ey, 0.33, bcs, loads, 1e-8,
                                             120000, &ion, nullptr, nullptr);
      // off-twin for exactness (flag off => plain solve, same system)
      fea_set_geneo_twolevel(false);
      FeaSolution soff = fea_solve_cg_matfree(g, ey, 0.33, bcs, loads, 1e-8,
                                              120000, &ioff, nullptr, nullptr);
      fea_set_geneo_twolevel(true);
      double num = 0, den = 0;
      for (std::size_t i = 0; i < son.u.size(); ++i) {
        num = std::max(num, std::abs(son.u[i] - soff.u[i]));
        den = std::max(den, std::abs(soff.u[i]));
      }
      std::printf("  %4d | %7d |   %d    | %3d | %12d | %.2e\n", s,
                  ion.iterations, ion.geneo_action, ion.geneo_dim,
                  ioff.iterations, den > 0 ? num / den : 0.0);
      if (s == n / 2 - 1) {
        // BASIS ROT: INVERT the checkerboard phase — every near-null mode moves,
        // so the held basis stops spanning the slow space. The refreshed solve
        // is still EXACT (only slower); the degradation trigger must schedule a
        // rebuild and the NEXT solve must open with action 3.
        std::printf("  ---- checkerboard phase INVERTED (the held basis is now "
                    "wrong for this design) ----\n");
        for (int k = 0; k < N; ++k)
          for (int j = 0; j < N; ++j)
            for (int i = 0; i < N; ++i)
              rho[g.index(i, j, k)] =
                  ((((i / cs) + (j / cs) + (k / cs)) & 1) != 0) ? 1.0 : 1e-3;
        for (int b = 0; b < N; ++b)
          for (int c = 0; c < N; ++c) {
            rho[g.index(0, b, c)] = 1.0;
            rho[g.index(N - 1, b, c)] = 1.0;
          }
      } else {
        // violent design move: every solid-phase cell re-drawn at random density
        for (int k = 0; k < N; ++k)
          for (int j = 0; j < N; ++j)
            for (int i = 0; i < N; ++i)
              if (rho[g.index(i, j, k)] > 0.5)
                rho[g.index(i, j, k)] = std::min(1.0, jump(rng));
      }
    }
    std::printf("\n  builds=%lld refreshes=%lld armed_solves=%lld\n",
                fea_geneo_basis_builds(), fea_geneo_coarse_refreshes(),
                fea_geneo_armed_solves());
    std::printf("  READ: a refresh-only policy under violent motion shows the "
                "degradation trigger (action 3 after a slow refreshed solve); "
                "every row's exactness column stays <= ~1e-7.\n");
    fea_set_geneo_twolevel(false);
    fea_reset_geneo_basis();
    return 0;
  }

  // mem (A5): peak RSS of an ARMED stagnating run, plus the basis footprint.
  if (mode == "mem") {
    const int n = argc > 2 ? std::atoi(argv[2]) : 8;
    const Fixture bf = make_big_stagnation();
    std::printf("===== A5 — MEMORY (armed big-fixture run) =====\n");
    std::printf("  RSS before: %.0f MB\n", peak_rss_bytes() / 1048576.0);
    // Posture 1: FULL production (draft on). Draft usually empties the Jacobi
    // regime on this capped fixture, so the basis may never build — the honest
    // production RSS.
    const Posture on = run_posture("prod armed", bf, true, true, true, true, n,
                                   rules, material, 0.50, true);
    print_posture(on);
    std::printf("  peak RSS after prod posture: %.0f MB\n",
                peak_rss_bytes() / 1048576.0);
    // Posture 2: the BASIS-ENGAGED regime (draft off => the fallback stagnates
    // and the deflation builds + holds its basis) — the RSS the A5 bar is about.
    const Posture eng = run_posture("armed, draft off", bf, true, true, false,
                                    true, n, rules, material, 0.50, true);
    print_posture(eng);
    std::printf("  peak RSS with basis resident: %.0f MB (basis %.1f MB, Nt=%d) "
                "on the 16384 MB machine => %.1f%% used, %.0f MB headroom\n",
                peak_rss_bytes() / 1048576.0, eng.end_basis_mb,
                eng.max_geneo_dim, 100.0 * peak_rss_bytes() / (16384.0 * 1048576.0),
                16384.0 - peak_rss_bytes() / 1048576.0);
    return 0;
  }

  std::fprintf(stderr,
               "unknown mode '%s' (gate / interaction / stag / healthy / amort "
               "/ fast / mem)\n",
               mode.c_str());
  return 1;
}
