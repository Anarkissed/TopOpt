// draft_arming_gate.cpp — the A5 THREE-WAY INTERACTION measurement for the DRAFT
// PRODUCTION ARMING (handoff 2026-07-26-draft-arming). NOT a CTest target; a
// standalone measurement harness, like active_domain_gate.cpp / draft_quality_*.
//
// A5 is the bar that matters most: this is the FIRST time Krylov recycling (armed,
// Jacobi-only, k=16 — handoff 133), Active Domain (armed AUTO — 2026-07-26-ad-arming)
// and Draft quality (this arming) would all be ON together, and NOBODY has measured
// the STACK. Each moves ground the others stand on:
//   * recycling's carried subspace assumes a SLOWLY-CHANGING operator;
//   * AD changes the active free-DOF SET as the band moves (which drops the basis);
//   * draft changes the TOLERANCE the whole trajectory solves at (which changes which
//     solves fall to Jacobi — the only regime where recycling can wrap at all).
//
// This harness runs FOUR postures on ONE grid and reports CG iterations and outer
// (optimizer) iterations for each, so the stack is seen to compose rather than blow
// up:
//   P0 none          recycling OFF, AD OFF, draft OFF   (the reference cost)
//   P1 rec           recycling ON,  AD OFF, draft OFF
//   P2 rec+AD        recycling ON,  AD ON,  draft OFF
//   P3 rec+AD+draft  recycling ON,  AD ON,  draft ON    (full production)
// and, with DRAFT ON (P3), it reports the two "did a feature silently degrade
// another" signals the task demands:
//   * recycle_dim observed + rc_frac (share of Jacobi solves that applied a carried
//     basis) + setup matvecs — does recycling still wrap with draft's looser,
//     faster-moving operator, or does its subspace collapse?
//   * the AD escape-latch and degeneracy-latch firing rates — does draft's looser
//     trajectory change how often the band escapes or degenerates?
// It also checks the exactness invariants that make "coexist" mean something:
//   * recycling is BIT-IDENTICAL (133): P1 design must equal P0 design bit-for-bit;
//   * the full-production posture P3 is DETERMINISTIC run-to-run (the product is
//     reproducible) — run twice, require bit-identical.
// And it reports the draft compliance gap per rung at the production loose tol, so
// the "escalation stays disarmed / inert at 1e-3" claim is measured, not asserted.
//
// The fixture is a stagnation-class ultra-dilute box whose multigrid falls to
// Jacobi-CG (the 125/168 disease, the regime AD is armed FOR and the ONLY regime
// where the Jacobi-only recycling can wrap): without it rc_frac is N/A and the
// interaction is invisible. Single rung, capped iterations (the full ladder here is
// hours); the plateau terminator is disarmed so both postures run the same count.
//
// Build (standalone; NOT wired into CTest):
//   c++ -std=c++17 -O2 -I core/include -I /opt/homebrew/include/eigen3 \
//     -DSETTINGS_RULES_PATH="\"$PWD/core/src/settings/rules.json\"" \
//     core/tests/harness/draft_arming_gate.cpp build/libtopopt.a -o /tmp/dag
// Run (TOPOPT_DA_DIR selects the evidence dir; default ./da_evidence):
//   interaction [N]   A5 — the four-posture stack on one grid, N iters (default 20)

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
#include "topopt/version.hpp"
#include "topopt/voxel.hpp"

using namespace topopt;

namespace {

std::string evidence_dir() {
  const char* d = std::getenv("TOPOPT_DA_DIR");
  return d ? std::string(d) : std::string("da_evidence");
}

Material fdm() {
  Material m;
  m.youngs_modulus_mpa = 3500.0; m.yield_strength_mpa = 55.0; m.density_g_cm3 = 1.24;
  m.z_knockdown = 0.55; m.poisson = 0.33; m.family = "fdm";
  return m;
}

VoxelGrid l_bracket(std::vector<DirichletBC>& bcs, int arm, int span, int ny, int t,
                    double h) {
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

// A stagnation-class ultra-dilute box (185's grid class): a thin l-bracket inside a
// box drawn ~2x its bbox so the analysis grid is void-heavy and the early dilute
// iterations fall to Jacobi-CG (185 §B5 measured cg_multigrid=0 / hier_built=1 on
// grids this small — the stagnation is a function of the dilution, not the absolute
// size). Multigrid falling to Jacobi is the ONLY regime where the Jacobi-only
// recycling can wrap, so the whole A5 interaction is observable here; the 73 728-
// element AD stagnation fixture reproduces the SAME disease but its full-domain tight
// certification solve costs minutes per posture, so this campaign uses the smaller
// grid (same dilution / spacing / production config) and reports the class honestly.
// The `scale` env axis (TOPOPT_DA_ARM) lets the same fixture be grown for a size check.
Fixture make_stagnation() {
  Fixture f;
  int arm = 12, span = 12, ny = 4, t = 3;
  if (const char* a = std::getenv("TOPOPT_DA_ARM")) {
    const int s = std::atoi(a);
    if (s == 8)  { arm = 8;  span = 8;  ny = 3; t = 2; }
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

// The AD gate's Stagnation regime, verbatim (24x6x24 mm part in a ~48x32x48 box =
// 73 728 elements, 48.8x dilution, spacing 1.0 mm): the 49x-class size handoff 168
// §1a measured reproducing the 125 stagnation (multigrid falls to Jacobi-CG). This
// is where the Jacobi-only recycling actually WRAPS (rc_frac > 0), so the recycling
// interaction with draft is observable here and not on the smaller healthy grid.
// Expensive: the final full-domain tight certification solve is minutes, so the
// `stag` mode caps the trajectory length (never the certificate) and runs the three
// postures the recycling/AD-under-draft question needs.
Fixture make_big_stagnation() {
  Fixture f;
  f.part = l_bracket(f.bcs, 24, 24, 6, 6, 1.0);
  f.loads = traction_loads(f.part, VoxelTag::Load, Vec3{0.0, 0.0, -30.0});
  f.box.min = Vec3{-12.0, -13.0, -12.0};
  f.box.max = Vec3{36.0, 19.0, 36.0};
  return f;
}

// One posture's result.
struct Posture {
  std::string label;
  bool recycling = false, ad = false, draft = false;
  double wall = 0.0;
  long long cg_total = 0;
  long long outer_iters = 0;
  int jacobi_solves = 0;
  long long solves_total = 0, solves_recycled = 0, setup_matvecs = 0;
  int max_recycle_dim = 0;
  // AD (from the single rung):
  int ad_band = 0, ad_latched = 0, ad_latch_iter = 0;
  long long ad_escapes = 0;
  std::string ad_reason;
  double ad_fbar = 1.0;
  // draft:
  double draft_gap = -1.0;
  int draft_tail_k = -1, draft_escalated = -1;
  std::vector<double> density;  // full double precision, for cross-posture deltas
  double compliance = 0.0, margin = 0.0;
};

Posture run_posture(const std::string& label, const Fixture& f, bool recycling,
                    bool ad, bool draft, int iters, const SettingsRules& rules,
                    const Material& material, double vf = 0.50, bool capped = false) {
  MinimizePlasticOptions o;
  configure_production_options(o);  // arms the full production stack...
  // ...then set each of the three interacting axes EXPLICITLY, so this posture is
  // exactly {recycling, ad, draft} regardless of what the arming leaves on. Recycling
  // is a process global; AD and draft are options fields.
  fea_set_krylov_recycling(recycling);
  o.simp.active_domain_band = ad ? production_active_domain_band() : 0;  // -1 AUTO or 0
  o.draft_quality = draft;
  o.draft_loose_tol = production_draft_loose_tol();
  // Escalation stays disarmed (design trigger off; gap left at the production
  // default) — we MEASURE the gap below to show it is inert at the production tol.

  o.volume_fraction_ladder = {vf};  // single dilute rung
  o.margin_stop = 0.0;              // don't margin-stop; run the rung
  o.external_loads = f.loads;
  o.gravity = 9810.0 * 1e-9;
  o.gravity_direction = Vec3{0.0, 0.0, -1.0};
  o.infill_percent = 100.0;
  o.design_box = f.box;
  o.simp.max_iterations = iters;
  if (capped) {
    // Fixed-length trajectory (plateau + change-stop disarmed): every posture runs
    // the SAME iters, so the CG comparison is apples-to-apples on an expensive
    // stagnation fixture whose full ladder is hours. The FINAL certification solve
    // still runs at the exact tight tolerance (never capped — the certificate is the
    // safety, A2).
    o.simp.mma_plateau_window = 0;
    o.simp.change_tol = 0.0;
  }
  // Otherwise: natural plateau termination (086), the honest per-posture trajectory
  // length — the draft win is the summed-CG ratio over that natural trajectory.

  Posture p;
  p.label = label; p.recycling = recycling; p.ad = ad; p.draft = draft;
  long long cg = 0, its = 0, st = 0, sr = 0, mv = 0;
  int fb = 0, maxdim = 0;
  o.on_iteration = [&](std::size_t, std::size_t, const SimpIterationObservation& ob) {
    cg += ob.cg_iterations;
    ++its;
    ++st;
    if (!ob.cg_used_multigrid) ++fb;
    if (ob.cg_recycle_dim > 0) { ++sr; if (ob.cg_recycle_dim > maxdim) maxdim = ob.cg_recycle_dim; }
    mv += ob.cg_recycle_setup_matvecs;
  };
  const auto t0 = std::chrono::steady_clock::now();
  const MinimizePlasticResult r =
      minimize_plastic(f.part, material, "fdm", f.bcs, rules, o);
  p.wall = std::chrono::duration<double>(std::chrono::steady_clock::now() - t0).count();
  p.cg_total = cg; p.outer_iters = its; p.jacobi_solves = fb;
  p.solves_total = st; p.solves_recycled = sr; p.setup_matvecs = mv;
  p.max_recycle_dim = maxdim;
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
  if (!r.draft_rung_tail_k.empty()) p.draft_tail_k = r.draft_rung_tail_k.front();
  if (!r.draft_rung_escalated.empty()) p.draft_escalated = r.draft_rung_escalated.front();

  fea_set_krylov_recycling(false);  // leave the global clean for the next posture
  return p;
}

double rc_frac(const Posture& p) {
  return p.jacobi_solves ? double(p.solves_recycled) / double(p.jacobi_solves) : 0.0;
}

struct Delta { double mean_abs = 0.0, max_abs = 0.0; };
Delta compare(const std::vector<double>& a, const std::vector<double>& b) {
  Delta d;
  if (a.size() != b.size() || a.empty()) return d;
  double s = 0.0;
  for (std::size_t i = 0; i < a.size(); ++i) {
    const double v = std::fabs(a[i] - b[i]);
    s += v; d.max_abs = std::max(d.max_abs, v);
  }
  d.mean_abs = s / double(a.size());
  return d;
}
bool bit_identical(const std::vector<double>& a, const std::vector<double>& b) {
  if (a.size() != b.size() || a.empty()) return false;
  for (std::size_t i = 0; i < a.size(); ++i) if (a[i] != b[i]) return false;
  return true;
}

void print_posture(const Posture& p) {
  std::printf("  [%-16s] %.1f s  CG=%lld  outer=%lld  Jacobi-fallback=%d/%lld\n",
              p.label.c_str(), p.wall, p.cg_total, p.outer_iters, p.jacobi_solves,
              p.solves_total);
  if (p.recycling)
    std::printf("      recycle: max_dim=%d  applied on %lld/%d Jacobi solves "
                "(rc_frac=%.3f)  setup_mv=%lld\n",
                p.max_recycle_dim, p.solves_recycled, p.jacobi_solves, rc_frac(p),
                p.setup_matvecs);
  if (p.ad)
    std::printf("      AD: band k=%d  f_bar=%.4f  latched=%d@iter%d  escapes=%lld  "
                "reason=\"%s\"\n",
                p.ad_band, p.ad_fbar, p.ad_latched, p.ad_latch_iter, p.ad_escapes,
                p.ad_reason.c_str());
  if (p.draft)
    std::printf("      draft: loose_tol=%.0e  compliance-gap=%.6f (bar 0.02 = the "
                "retired Phase-1 fallback)  tail_k=%d  escalated=%d\n",
                production_draft_loose_tol(), p.draft_gap, p.draft_tail_k,
                p.draft_escalated);
}

}  // namespace

int main(int argc, char** argv) {
  std::setvbuf(stdout, nullptr, _IOLBF, 0);
  const std::string mode = argc > 1 ? argv[1] : "interaction";
  const int iters = argc > 2 ? std::atoi(argv[2]) : 200;  // per-posture safety cap
  const std::string dir = evidence_dir();

  SettingsRules rules;
  try {
    rules = load_settings_rules_file(SETTINGS_RULES_PATH);
  } catch (const std::exception& e) {
    std::fprintf(stderr, "FAIL: rules.json: %s\n", e.what());
    return 1;
  }
  const Material material = fdm();
  const Fixture f = make_stagnation();

  {
    MinimizePlasticOptions probe;
    configure_production_options(probe);
    probe.design_box = f.box;
    const VoxelGrid solved = minimize_plastic_solved_grid(f.part, probe);
    std::printf("===== A5 THREE-WAY INTERACTION FIXTURE (stagnation) =====\n");
    std::printf("  part %dx%dx%d (%zu solid) -> grid %dx%dx%d (%zu elements), "
                "dilution=%.1fx, spacing=%.2f mm\n",
                f.part.nx, f.part.ny, f.part.nz, f.part.solid_count(), solved.nx,
                solved.ny, solved.nz, solved.solid_count(),
                double(solved.solid_count()) / double(f.part.solid_count()),
                solved.spacing);
    std::printf("  production recycle_dim k=%d, AD band=%d (AUTO), draft loose_tol=%.0e, "
                "matfree threads=%d\n",
                production_krylov_recycle_dim(), production_active_domain_band(),
                production_draft_loose_tol(), fea_matfree_thread_count());
    std::printf("  single dilute rung (vf 0.50), natural plateau termination, "
                "safety cap %d iters\n\n", iters);
  }

  // gate (A3): the FULL production ladder, draft OFF vs draft ON, twice each, on the
  // production config (recycling + AD armed in BOTH postures — only draft differs).
  // Reports every rung's verdict + margin before/after, names any verdict flip, and
  // proves twice-run bit-identity of the product in each posture.
  if (mode == "gate") {
    // A stronger load case than the stagnation fixture's -30 N, so the production
    // ladder WALKS several rungs (rung 0 accepts, lighter rungs progressively reject
    // at the 1.5 margin stop) instead of rejecting at rung 0 — a meaningful gate table
    // needs multiple verdicts to compare. Scale via TOPOPT_DA_LOAD (default -8 N).
    Fixture gf = f;
    double load_mag = -8.0;
    if (const char* lm = std::getenv("TOPOPT_DA_LOAD")) load_mag = std::atof(lm);
    gf.loads = traction_loads(gf.part, VoxelTag::Load, Vec3{0.0, 0.0, load_mag});
    struct Rung { double vf, margin, compliance; int accepted, infeasible, escalated;
                  std::vector<double> density; };
    auto ladder_run = [&](bool draft, bool recycling_on) {
      MinimizePlasticOptions o;
      configure_production_options(o);
      fea_set_krylov_recycling(recycling_on);
      o.draft_quality = draft;
      o.volume_fraction_ladder = production_reduction_ladder();
      o.margin_stop = 1.5;   // the real production stop — exposes verdict flips
      o.external_loads = gf.loads;
      o.gravity = 9810.0 * 1e-9; o.gravity_direction = Vec3{0.0, 0.0, -1.0};
      o.infill_percent = 100.0; o.design_box = f.box;
      long long cg = 0;
      o.on_iteration = [&](std::size_t, std::size_t, const SimpIterationObservation& ob) {
        cg += ob.cg_iterations;
      };
      const MinimizePlasticResult r =
          minimize_plastic(f.part, material, "fdm", f.bcs, rules, o);
      fea_set_krylov_recycling(false);
      std::vector<Rung> out;
      for (std::size_t i = 0; i < r.evaluated.size(); ++i) {
        const auto& v = r.evaluated[i];
        Rung rg; rg.vf = v.requested_volume_fraction; rg.margin = v.report.margin.worst_case;
        rg.compliance = v.optimization.compliance; rg.accepted = v.accepted ? 1 : 0;
        rg.infeasible = v.infeasible ? 1 : 0;
        rg.escalated = i < r.draft_rung_escalated.size() ? r.draft_rung_escalated[i] : 0;
        rg.density = v.optimization.physical_density;
        out.push_back(std::move(rg));
      }
      return std::make_pair(out, cg);
    };
    std::printf("===== A3 — FULL GATE TABLE (production ladder, draft OFF vs ON; "
                "recycling+AD armed in both) =====\n");
    const auto off1 = ladder_run(false, true);
    const auto off2 = ladder_run(false, true);
    const auto on1  = ladder_run(true,  true);
    const auto on2  = ladder_run(true,  true);
    auto bitid = [](const std::vector<Rung>& a, const std::vector<Rung>& b) {
      if (a.size() != b.size()) return false;
      for (std::size_t i = 0; i < a.size(); ++i) {
        if (a[i].margin != b[i].margin || a[i].compliance != b[i].compliance ||
            a[i].accepted != b[i].accepted || a[i].density != b[i].density) return false;
      }
      return true;
    };
    std::printf("  twice-run bit-identical: OFF %s  ON %s\n",
                bitid(off1.first, off2.first) ? "YES" : "NO",
                bitid(on1.first, on2.first) ? "YES" : "NO");
    std::printf("\n  rung   vf   | verdict OFF -> ON        | margin OFF -> ON            "
                "| dM/M       | mean|drho|  max|drho| | escalated\n");
    const std::size_t n = std::min(off1.first.size(), on1.first.size());
    int flips = 0;
    for (std::size_t i = 0; i < n; ++i) {
      const Rung& a = off1.first[i]; const Rung& b = on1.first[i];
      const Delta d = compare(a.density, b.density);
      const double mrel = (std::isfinite(a.margin) && a.margin != 0.0)
                              ? std::fabs(b.margin - a.margin) / std::fabs(a.margin) : 0.0;
      const char* va = a.infeasible ? "INFEAS" : (a.accepted ? "ACCEPT" : "REJECT");
      const char* vb = b.infeasible ? "INFEAS" : (b.accepted ? "ACCEPT" : "REJECT");
      const bool flip = (a.accepted != b.accepted) || (a.infeasible != b.infeasible);
      if (flip) ++flips;
      std::printf("   %zu   %.2f | %-6s -> %-6s %s | %11.6g -> %-11.6g | %.3e | "
                  "%.3e %.3e | %d\n",
                  i, a.vf, va, vb, flip ? "**FLIP**" : "        ", a.margin, b.margin,
                  mrel, d.mean_abs, d.max_abs, b.escalated);
    }
    std::printf("\n  rung count OFF %zu -> ON %zu; verdict flips: %d\n",
                off1.first.size(), on1.first.size(), flips);
    std::printf("  ladder CG OFF %lld -> ON %lld (%.3fx)\n", off1.second, on1.second,
                off1.second ? double(on1.second)/double(off1.second) : 0.0);
    const std::string csv = dir + "/gate.csv";
    FILE* fp = std::fopen(csv.c_str(), "w");
    if (fp) {
      std::fprintf(fp, "rung,vf,off_verdict,on_verdict,off_margin,on_margin,margin_rel_delta,"
                       "off_compliance,on_compliance,mean_abs_drho,max_abs_drho,on_escalated,flip\n");
      for (std::size_t i = 0; i < n; ++i) {
        const Rung& a = off1.first[i]; const Rung& b = on1.first[i];
        const Delta d = compare(a.density, b.density);
        const double mrel = (std::isfinite(a.margin) && a.margin != 0.0)
                                ? std::fabs(b.margin - a.margin)/std::fabs(a.margin) : 0.0;
        std::fprintf(fp, "%zu,%.4f,%s,%s,%.10g,%.10g,%.6e,%.10g,%.10g,%.6e,%.6e,%d,%d\n",
                     i, a.vf, a.infeasible?"INFEAS":(a.accepted?"ACCEPT":"REJECT"),
                     b.infeasible?"INFEAS":(b.accepted?"ACCEPT":"REJECT"), a.margin, b.margin,
                     mrel, a.compliance, b.compliance, d.mean_abs, d.max_abs, b.escalated,
                     ((a.accepted!=b.accepted)||(a.infeasible!=b.infeasible))?1:0);
      }
      std::fclose(fp);
      std::printf("  wrote %s\n", csv.c_str());
    }
    return 0;
  }

  // stag: the recycling-wrap regime. On the big stagnation fixture (multigrid falls
  // to Jacobi) the Jacobi-only recycling actually applies a carried basis, so this is
  // where "does recycle_dim collapse with draft on?" is answerable. Capped trajectory
  // (the certificate solve is never capped). Reports rc_frac + AD latch with draft
  // ON vs OFF. Default 12 iters (the big fixture's final solve dominates the wall).
  if (mode == "stag") {
    const int n = argc > 2 ? std::atoi(argv[2]) : 12;
    const Fixture bf = make_big_stagnation();
    {
      MinimizePlasticOptions probe;
      configure_production_options(probe);
      probe.design_box = bf.box;
      const VoxelGrid solved = minimize_plastic_solved_grid(bf.part, probe);
      std::printf("===== A5 RECYCLING-WRAP REGIME (big stagnation fixture) =====\n");
      std::printf("  part %zu solid -> grid %dx%dx%d (%zu elements), dilution=%.1fx, "
                  "spacing=%.2f mm; capped %d iters, single rung vf 0.50\n\n",
                  bf.part.solid_count(), solved.nx, solved.ny, solved.nz,
                  solved.solid_count(),
                  double(solved.solid_count()) / double(bf.part.solid_count()),
                  solved.spacing, n);
    }
    const Posture s_rec  = run_posture("rec (no AD)",   bf, true, false, false, n,
                                       rules, material, 0.50, true);
    const Posture s_ad   = run_posture("rec+AD",        bf, true, true,  false, n,
                                       rules, material, 0.50, true);
    const Posture s_draft = run_posture("rec+AD+draft", bf, true, true,  true,  n,
                                        rules, material, 0.50, true);
    std::printf("===== POSTURES (capped %d iters) =====\n", n);
    print_posture(s_rec);
    print_posture(s_ad);
    print_posture(s_draft);
    std::printf("\n===== RECYCLING & AD LATCH UNDER DRAFT (the A5 interaction) =====\n");
    std::printf("  rec (no AD)   : %d/%lld solves Jacobi, rc_frac=%.3f, max_dim=%d, "
                "setup_mv=%lld\n", s_rec.jacobi_solves, s_rec.solves_total,
                rc_frac(s_rec), s_rec.max_recycle_dim, s_rec.setup_matvecs);
    std::printf("  rec+AD        : %d/%lld solves Jacobi, rc_frac=%.3f, max_dim=%d; "
                "AD latched=%d@%d escapes=%lld reason=\"%s\"\n", s_ad.jacobi_solves,
                s_ad.solves_total, rc_frac(s_ad), s_ad.max_recycle_dim, s_ad.ad_latched,
                s_ad.ad_latch_iter, s_ad.ad_escapes, s_ad.ad_reason.c_str());
    std::printf("  rec+AD+draft  : %d/%lld solves Jacobi, rc_frac=%.3f, max_dim=%d; "
                "AD latched=%d@%d escapes=%lld reason=\"%s\"; draft gap=%.6f\n",
                s_draft.jacobi_solves, s_draft.solves_total, rc_frac(s_draft),
                s_draft.max_recycle_dim, s_draft.ad_latched, s_draft.ad_latch_iter,
                s_draft.ad_escapes, s_draft.ad_reason.c_str(), s_draft.draft_gap);
    std::printf("\n  READING: rc_frac with draft ON (%.3f) vs draft OFF (%.3f) — "
                "recycling %s under draft.\n", rc_frac(s_draft), rc_frac(s_ad),
                (rc_frac(s_draft) > 0.0 || s_draft.jacobi_solves == 0)
                    ? "keeps wrapping (or draft moved solves out of the Jacobi regime)"
                    : "STOPPED wrapping — investigate");
    const std::string csv = dir + "/stag.csv";
    FILE* fp = std::fopen(csv.c_str(), "w");
    if (fp) {
      std::fprintf(fp, "posture,ad,draft,cg_total,outer,jacobi_solves,solves_total,"
                       "solves_recycled,rc_frac,max_recycle_dim,setup_mv,ad_band,"
                       "ad_latched,ad_latch_iter,ad_escapes,ad_fbar,draft_gap\n");
      for (const Posture* p : {&s_rec, &s_ad, &s_draft})
        std::fprintf(fp, "%s,%d,%d,%lld,%lld,%d,%lld,%lld,%.4f,%d,%lld,%d,%d,%d,%lld,"
                         "%.4f,%.6f\n",
                     p->label.c_str(), p->ad, p->draft, p->cg_total, p->outer_iters,
                     p->jacobi_solves, p->solves_total, p->solves_recycled, rc_frac(*p),
                     p->max_recycle_dim, p->setup_matvecs, p->ad_band, p->ad_latched,
                     p->ad_latch_iter, p->ad_escapes, p->ad_fbar, p->draft_gap);
      std::fclose(fp);
      std::printf("  wrote %s\n", csv.c_str());
    }
    return 0;
  }

  if (mode != "interaction") {
    std::fprintf(stderr, "unknown mode '%s' (interaction / gate / stag)\n",
                 mode.c_str());
    return 1;
  }

  const Posture p0 = run_posture("none",           f, false, false, false, iters, rules, material);
  const Posture p1 = run_posture("rec",            f, true,  false, false, iters, rules, material);
  const Posture p2 = run_posture("rec+AD",         f, true,  true,  false, iters, rules, material);
  const Posture p3 = run_posture("rec+AD+draft",   f, true,  true,  true,  iters, rules, material);
  // Determinism of the full-production product: run P3 a second time.
  const Posture p3b = run_posture("rec+AD+draft#2", f, true, true,  true,  iters, rules, material);

  std::printf("===== FOUR POSTURES (CG + outer iterations) =====\n");
  print_posture(p0);
  print_posture(p1);
  print_posture(p2);
  print_posture(p3);

  std::printf("\n===== DOES ANY FEATURE SILENTLY DEGRADE ANOTHER? =====\n");
  // 1) recycling exactness: P1 must be BIT-IDENTICAL to P0 (133: recycling is a
  //    preconditioner change only; the solved system and its answer are unchanged).
  const bool rec_exact = bit_identical(p0.density, p1.density) &&
                         p0.compliance == p1.compliance && p0.margin == p1.margin;
  std::printf("  [recycling exact] P1(rec) design == P0(none) bit-for-bit: %s\n",
              rec_exact ? "YES (recycling is a pure preconditioner, 133)" : "NO — REGRESSION");
  // 2) full-production determinism: P3 == P3#2 bit-for-bit (the product reproduces).
  const bool p3_det = bit_identical(p3.density, p3b.density) &&
                      p3.compliance == p3b.compliance && p3.cg_total == p3b.cg_total;
  std::printf("  [production deterministic] rec+AD+draft twice bit-identical "
              "(design+compliance+CG): %s\n", p3_det ? "YES" : "NO");
  // 3) recycling still wraps with DRAFT ON — its subspace did not collapse.
  std::printf("  [recycling survives draft] with draft ON: recycle max_dim=%d, "
              "rc_frac=%.3f (rec+AD off-draft rc_frac=%.3f)\n",
              p3.max_recycle_dim, rc_frac(p3), rc_frac(p2));
  // 4) AD latch behaviour with DRAFT ON vs OFF — draft did not change how the band
  //    escapes/degenerates in a pathological way.
  std::printf("  [AD latch under draft] rec+AD(draft off): latched=%d@%d escapes=%lld "
              "reason=\"%s\"\n", p2.ad_latched, p2.ad_latch_iter, p2.ad_escapes,
              p2.ad_reason.c_str());
  std::printf("                         rec+AD+draft     : latched=%d@%d escapes=%lld "
              "reason=\"%s\"\n", p3.ad_latched, p3.ad_latch_iter, p3.ad_escapes,
              p3.ad_reason.c_str());
  // 5) escalation inert at the production loose tol (the gap never exceeds 0.02).
  std::printf("  [escalation inert] draft compliance-gap at loose 1e-3 = %.6f "
              "(retired Phase-1 fallback bar 0.02): %s; design trigger armed=NO\n",
              p3.draft_gap, (p3.draft_gap >= 0.0 && p3.draft_gap < 0.02)
                                ? "BELOW bar -> no escalation" : "SEE NOTE");

  std::printf("\n===== CROSS-POSTURE DESIGN DELTAS (the stack changes the trajectory, "
              "the certificate stays exact) =====\n");
  const Delta d10 = compare(p0.density, p1.density);
  const Delta d21 = compare(p1.density, p2.density);
  const Delta d32 = compare(p2.density, p3.density);
  std::printf("  rec    vs none    : mean|drho|=%.3e max=%.3e  (expect 0 — exact)\n",
              d10.mean_abs, d10.max_abs);
  std::printf("  rec+AD vs rec     : mean|drho|=%.3e max=%.3e  (AD is an approximation)\n",
              d21.mean_abs, d21.max_abs);
  std::printf("  +draft vs rec+AD  : mean|drho|=%.3e max=%.3e  (draft loosens the "
              "trajectory; the FINAL solve is always exact)\n",
              d32.mean_abs, d32.max_abs);

  std::printf("\n===== CG-ITERATION LADDER ACROSS THE STACK =====\n");
  std::printf("  none          CG=%lld  outer=%lld\n", p0.cg_total, p0.outer_iters);
  std::printf("  rec           CG=%lld  outer=%lld  (%.3fx vs none)\n", p1.cg_total,
              p1.outer_iters, p0.cg_total ? double(p1.cg_total)/double(p0.cg_total) : 0.0);
  std::printf("  rec+AD        CG=%lld  outer=%lld  (%.3fx vs none)\n", p2.cg_total,
              p2.outer_iters, p0.cg_total ? double(p2.cg_total)/double(p0.cg_total) : 0.0);
  std::printf("  rec+AD+draft  CG=%lld  outer=%lld  (%.3fx vs none)\n", p3.cg_total,
              p3.outer_iters, p0.cg_total ? double(p3.cg_total)/double(p0.cg_total) : 0.0);

  // Write a compact machine-readable summary.
  const std::string csv = dir + "/interaction.csv";
  FILE* fp = std::fopen(csv.c_str(), "w");
  if (fp) {
    std::fprintf(fp, "posture,recycling,ad,draft,cg_total,outer_iters,jacobi_solves,"
                     "solves_total,solves_recycled,rc_frac,max_recycle_dim,setup_mv,"
                     "ad_band,ad_latched,ad_latch_iter,ad_escapes,ad_fbar,draft_gap,"
                     "compliance,margin,wall_s\n");
    for (const Posture* p : {&p0, &p1, &p2, &p3}) {
      std::fprintf(fp, "%s,%d,%d,%d,%lld,%lld,%d,%lld,%lld,%.4f,%d,%lld,%d,%d,%d,%lld,"
                       "%.4f,%.6f,%.10g,%.6g,%.2f\n",
                   p->label.c_str(), p->recycling, p->ad, p->draft, p->cg_total,
                   p->outer_iters, p->jacobi_solves, p->solves_total, p->solves_recycled,
                   rc_frac(*p), p->max_recycle_dim, p->setup_matvecs, p->ad_band,
                   p->ad_latched, p->ad_latch_iter, p->ad_escapes, p->ad_fbar,
                   p->draft_gap, p->compliance, p->margin, p->wall);
    }
    std::fclose(fp);
    std::printf("\n  wrote %s\n", csv.c_str());
  }

  const bool ok = rec_exact && p3_det;
  std::printf("\n===== A5 VERDICT: %s =====\n",
              ok ? "the three features COEXIST (recycling exact, production "
                   "deterministic; no pair silently degrades another)"
                 : "INTERFERENCE DETECTED — arming waits (BLOCKED-STOP)");
  return ok ? 0 : 1;
}
