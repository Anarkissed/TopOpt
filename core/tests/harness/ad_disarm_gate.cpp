// ad_disarm_gate.cpp — the before/after measurement harness for DISARMING the
// ACTIVE DOMAIN production band (task: active-domain-disarm, handoff
// docs/handoffs/2026-08-01-active-domain-disarm.md). NOT a CI test; standalone,
// a sibling of active_domain_gate.cpp / active_domain_escape.cpp / the draft_*
// harnesses, and it deliberately reuses that harness's fixture verbatim so the
// disarm table is comparable, row for row, with the ARMING table it reverses.
//
// It answers the two questions the disarm needs answered, and nothing else.
//
//   MODE `gate` — THE FULL GATE TABLE, BEFORE AND AFTER, EVERY RUNG.
//     Three postures of the SAME production ladder on the SAME fixture:
//       OFF  = active_domain_band 0   (the DISARMED posture — what ships after)
//       ON   = active_domain_band -1  (AUTO — the ARMED posture, what ships now)
//       CTL  = active_domain_band 0 under a 1e-9 RELATIVE LOAD PERTURBATION
//     each run TWICE (determinism), compared in memory at full double precision.
//     CTL is the NEGATIVE-CONTROL FLOOR (the 2026-08-01 multiscale-wiring I3
//     discipline): a physically meaningless 1e-9 nudge to the load vector, whose
//     effect on the design is pure iteration-route noise. Any ON-vs-OFF motion at
//     or below that floor is noise; anything ABOVE it is a real difference the
//     flip causes, and this harness REPORTS it rather than rounding it away.
//     Reported per rung: verdict, margin OFF -> ON, dM/M, mean/max |drho|,
//     PRINTED-class flips (#{rho > kIso=0.5}, the shipped-part classification) and
//     5-class flips (void / low-gray / mid / high-gray / solid), each against the
//     control's own count on the same rung.
//
//   MODES `dims` / `padinert` / `odd` / `stag` — THE COST, RE-MEASURED AGAINST
//   THE ODD-AXIS FIX. Every prior AD measurement (PR 209, the 2026-07-27 arming
//   review, PR 248) predates the odd-axis parity pad
//   (2026-07-31-multigrid-odd-axis-cliff), which turned multigrid ON for grids
//   a single odd axis used to reject outright. If AD's cost was measured in a
//   Jacobi-dominated world that the pad has since made healthy, the disarm is
//   resting on stale numbers and the maintainer must be told. These four modes
//   settle that, in order:
//     `dims`     — which grids can even BE odd. expand_design_domain rounds every
//                  axis up to kDesignBoxCoarsenAlign = 8, so a design-box grid is
//                  all-even by construction; the mode sweeps box heights and
//                  prints the solved grid for each, rather than asserting it.
//     `padinert` — the arming gate fixture under pad mode 0 (legacy) vs 1 (today),
//                  AD off and AD on: bit-identical or not.
//     `odd`      — the class the pad ACTUALLY rescued (odd axis => no design box):
//                  2x2 over pad mode x AD, with the AD active fraction and latch
//                  reported, so "can AD even engage there" is measured.
//     `stag`     — the +26% coin-flip regime (48x32x48, Jacobi by STAGNATION, not
//                  by odd axes) re-measured on today's build, AD off vs on, at a
//                  fixed identical optimizer length, with the GenEO counters.
//
// Build (standalone; NOT wired into CTest):
//   c++ -std=c++17 -O2 -I core/include -I /opt/homebrew/include/eigen3 \
//     -DSETTINGS_RULES_PATH="\"$PWD/core/src/settings/rules.json\"" \
//     core/tests/harness/ad_disarm_gate.cpp build/libtopopt.a -o /tmp/addg
// Run (TOPOPT_ADD_DIR selects the evidence directory; default ./ad_disarm):
//   dims | gate | padinert [N] | odd [N] | stag [N]

#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <stdexcept>
#include <memory>
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

using namespace topopt;

namespace {

// The shipped export threshold (minimize_plastic.cpp kIso). A voxel crossing it
// changes the PART, which is why it gets its own flip count.
constexpr double kIso = 0.5;

std::string evidence_dir() {
  const char* d = std::getenv("TOPOPT_ADD_DIR");
  return d ? std::string(d) : std::string("ad_disarm");
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

// The thin L-bracket of handoff 134's probe, VERBATIM from
// active_domain_gate.cpp (same shape as cg_tol_probe.cpp's fixture): a vertical
// arm and a horizontal span of thickness `t`, clamped across the arm's top,
// loaded at the span's tip. Copied rather than shared so this harness stays
// standalone like every other harness in this directory.
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
  VoxelGrid part;
  std::vector<DirichletBC> bcs;
  std::vector<NodalLoad> loads;
  DesignBox box;
  bool has_box = true;  // false => the solved grid IS the part grid (no expansion)
};

// HEALTHY — the arming gate fixture, byte-for-byte the box
// active_domain_gate.cpp's Regime::Healthy uses: the part expands the analysis
// grid to 32x24x32 = 24 576 elements against 528 solid voxels (46.5x dilution,
// 2.15% fill, rmin = 2.5 voxels -> AUTO band k = 4). The gate table below is
// therefore directly comparable to the arming table it reverses.
Fixture healthy_fixture() {
  Fixture f;
  f.part = l_bracket(f.bcs, /*arm*/ 14, /*span*/ 14, /*ny*/ 4, /*t*/ 6, /*h*/ 1.0);
  f.loads = traction_loads(f.part, VoxelTag::Load, Vec3{0.0, 0.0, -30.0});
  f.box.min = Vec3{-9.0, -10.0, -9.0};
  f.box.max = Vec3{23.0, 14.0, 23.0};
  return f;
}

// STAGNATION — the 48x32x48 ultra-dilute box active_domain_gate.cpp's
// Regime::Stagnation uses, verbatim: the 49x-class size that reproduces the 125
// multigrid stagnation (the hierarchy BUILDS and then stops contracting, so the
// solver falls back to Jacobi-CG). This is the regime the +26% coin-flip was
// measured in, and it is a DIFFERENT mechanism from the odd-axis cliff.
Fixture stagnation_fixture() {
  Fixture f;
  f.part = l_bracket(f.bcs, /*arm*/ 24, /*span*/ 24, /*ny*/ 6, /*t*/ 6, /*h*/ 1.0);
  f.loads = traction_loads(f.part, VoxelTag::Load, Vec3{0.0, 0.0, -30.0});
  f.box.min = Vec3{-12.0, -13.0, -12.0};
  f.box.max = Vec3{36.0, 19.0, 36.0};
  return f;
}

// ODD-AXIS — a fixture with NO DESIGN BOX and an odd axis, which is the only
// shape an odd axis can take in this codebase.
//
// WHY IT HAS NO BOX. expand_design_domain rounds EVERY axis up to a multiple of
// kDesignBoxCoarsenAlign = 8 (voxelize.cpp), so a design-box grid is always
// all-even and the odd-axis cliff can never touch it — `dims` measures this. An
// odd axis therefore only ever reaches the solver on a grid the driver did NOT
// expand: the imported part's own voxelization, which is exactly the shape of
// the real 128x31x118 run that motivated the parity pad.
//
// The L-bracket is built directly at 33x25x33 (two odd axes) with a thin wall,
// so it is sparse inside its own bounding grid. Note what this fixture CANNOT
// be: ultra-dilute. Without a box the design domain is the part's own non-Empty
// voxels, so the active-domain band's denominator is the part itself and the
// band covers it from iteration 1. That is a property of the code, not of this
// fixture — and the `odd` mode measures it rather than asserting it.
Fixture odd_axis_fixture() {
  Fixture f;
  f.part = l_bracket(f.bcs, /*arm*/ 33, /*span*/ 33, /*ny*/ 25, /*t*/ 5, /*h*/ 1.0);
  f.loads = traction_loads(f.part, VoxelTag::Load, Vec3{0.0, 0.0, -30.0});
  f.has_box = false;
  return f;
}

// A copy of a fixture whose loads are scaled by (1 + eps): the NEGATIVE CONTROL.
// A 1e-9 relative nudge is far below any physical meaning and far below the
// solver's own 1e-8 relative-residual basin, so whatever design motion it
// produces is the floor of pure iteration-route noise on this fixture.
Fixture perturbed(const Fixture& f, double eps) {
  Fixture c = f;
  for (NodalLoad& l : c.loads) l.value *= (1.0 + eps);
  return c;
}

MinimizePlasticOptions base_options(const Fixture& f, int band,
                                    bool single_rung = false, int cap = 0) {
  MinimizePlasticOptions o;
  configure_production_options(o);  // the PRODUCTION config, unmodified
  o.volume_fraction_ladder = production_reduction_ladder();
  o.margin_stop = 1.5;
  o.external_loads = f.loads;
  o.gravity = 9810.0 * 1e-9;
  o.gravity_direction = Vec3{0.0, 0.0, -1.0};
  o.infill_percent = 100.0;
  if (f.has_box) o.design_box = f.box;
  // The ONE variable. configure_production_options has already set this to the
  // production constant; overriding it here is what makes OFF/ON comparable in
  // one process and independent of which way the constant currently points.
  o.simp.active_domain_band = band;
  // `single_rung` + `cap` restrict a probe to rung 0 at a FIXED optimizer
  // length, applied IDENTICALLY to both postures, so a CG comparison in a
  // stagnating regime is not confounded by a different number of iterations.
  if (single_rung) o.volume_fraction_ladder = {production_reduction_ladder()[0]};
  if (cap > 0) o.simp.max_iterations = cap;
  return o;
}

// Everything one ladder produced that the disarm compares.
struct RunRecord {
  std::string label;
  double wall = 0.0;
  long long cg_total = 0;
  long long iters_total = 0;
  int mg_fallback_solves = 0;
  long long solves_total = 0;
  long long geneo_armed_solves = 0;
  long long geneo_basis_builds = 0;
  int grid_nx = 0, grid_ny = 0, grid_nz = 0;
  bool used_multigrid = false;
  std::vector<double> rung_vf;
  std::vector<std::vector<double>> rung_density;  // full double precision
  std::vector<double> rung_compliance;
  std::vector<double> rung_margin;
  std::vector<double> rung_printed_fraction;
  std::vector<int> rung_iterations;
  std::vector<int> rung_accepted;
  std::vector<int> rung_infeasible;
  std::vector<double> rung_active_fraction_mean;
  std::vector<int> rung_latched;
  std::vector<int> rung_band_resolved;
  std::vector<long long> rung_escape_count;
  std::vector<int> rung_latch_iter;
  std::vector<std::string> rung_latch_reason;
  std::string terminal_recommendation;
};

RunRecord run_ladder(const char* label, const Fixture& f, int band,
                     const SettingsRules& rules, const Material& material,
                     int pad_mode, bool single_rung = false, int cap = 0) {
  MinimizePlasticOptions o = base_options(f, band, single_rung, cap);

  // The pad mode is thread-local and sticky; set it on the thread that issues
  // the solves, immediately before the run, and restore it after.
  const int prev_pad = fea_mg_parity_pad_mode();
  fea_set_mg_parity_pad_mode(pad_mode);
  // GenEO counters are cumulative since the last reset; reset so each cell of
  // the table reports ITS OWN builds, not the process total.
  fea_reset_geneo_basis();

  RunRecord r;
  r.label = label;
  long long cg_total = 0, iters_total = 0, solves = 0;
  int fallbacks = 0;
  o.on_iteration = [&](std::size_t, std::size_t, const SimpIterationObservation& obs) {
    cg_total += obs.cg_iterations;
    ++iters_total;
    ++solves;
    if (!obs.cg_used_multigrid) ++fallbacks;
  };

  const auto t0 = std::chrono::steady_clock::now();
  const MinimizePlasticResult res =
      minimize_plastic(f.part, material, "fdm", f.bcs, rules, o);
  r.wall = std::chrono::duration<double>(std::chrono::steady_clock::now() - t0).count();
  r.cg_total = cg_total;
  r.iters_total = iters_total;
  r.solves_total = solves;
  r.mg_fallback_solves = fallbacks;
  r.geneo_armed_solves = fea_geneo_armed_solves();
  r.geneo_basis_builds = fea_geneo_basis_builds();
  r.grid_nx = res.solved_grid.nx;
  r.grid_ny = res.solved_grid.ny;
  r.grid_nz = res.solved_grid.nz;
  r.used_multigrid = res.used_multigrid;
  fea_set_mg_parity_pad_mode(prev_pad);

  for (const MinimizePlasticVariant& v : res.evaluated) {
    r.rung_vf.push_back(v.requested_volume_fraction);
    r.rung_density.push_back(v.optimization.physical_density);
    r.rung_compliance.push_back(v.optimization.compliance);
    r.rung_margin.push_back(v.report.margin.worst_case);
    r.rung_printed_fraction.push_back(v.report.printed_fraction);
    r.rung_iterations.push_back(v.optimization.iterations);
    r.rung_accepted.push_back(v.accepted ? 1 : 0);
    r.rung_infeasible.push_back(v.infeasible ? 1 : 0);
    r.rung_active_fraction_mean.push_back(v.optimization.active_fraction_mean);
    r.rung_latched.push_back(v.optimization.active_domain_latched ? 1 : 0);
    r.rung_band_resolved.push_back(v.optimization.active_domain_band);
    r.rung_escape_count.push_back(v.optimization.active_domain_escape_count);
    r.rung_latch_iter.push_back(v.optimization.active_domain_latch_iteration);
    r.rung_latch_reason.push_back(v.optimization.active_domain_latch_reason);
  }
  if (!res.report.variants.empty()) {
    const SlicerSettings& st = res.report.variants.back().settings;
    r.terminal_recommendation =
        st.family + " walls=" + std::to_string(st.walls) +
        " top=" + std::to_string(st.top_layers) +
        " bottom=" + std::to_string(st.bottom_layers) +
        " infill=" + std::to_string(st.infill_percent) + "%" + st.infill_pattern +
        (st.warning.empty() ? "" : " warning:" + st.warning);
  }

  std::printf("  [%s] grid %dx%dx%d  mg=%s  %.1f s wall, %lld iterations, "
              "%lld CG, %d/%lld Jacobi-fallback solves, geneo armed=%lld "
              "builds=%lld, %zu rungs\n",
              label, r.grid_nx, r.grid_ny, r.grid_nz,
              r.used_multigrid ? "carried" : "NOT-carried", r.wall,
              r.iters_total, r.cg_total, r.mg_fallback_solves, r.solves_total,
              r.geneo_armed_solves, r.geneo_basis_builds, r.rung_vf.size());
  for (std::size_t i = 0; i < r.rung_vf.size(); ++i)
    std::printf("    rung %zu vf=%.2f iters=%3d %s%s margin=%.10g "
                "printed=%.6f compliance=%.12g  f_bar=%.4f  k=%d%s\n",
                i, r.rung_vf[i], r.rung_iterations[i],
                r.rung_accepted[i] ? "accept" : "REJECT",
                r.rung_infeasible[i] ? " INFEASIBLE" : "", r.rung_margin[i],
                r.rung_printed_fraction[i], r.rung_compliance[i],
                r.rung_active_fraction_mean[i], r.rung_band_resolved[i],
                r.rung_latched[i] ? "  LATCHED" : "");
  return r;
}

// --- the comparison quantities -------------------------------------------

// Five design classes, the 2026-08-01 I3 shape adapted to a scalar SIMP field:
// void / low-gray / mid-gray / high-gray / solid. The interior edges are the
// grayness bands the min-feature and projection machinery reason about; the
// count that decides the PART is the separate printed flip below.
int class_of(double r) {
  if (r <= 0.01) return 0;
  if (r < 0.3) return 1;
  if (r <= 0.7) return 2;
  if (r < 0.99) return 3;
  return 4;
}

struct Delta {
  double mean_abs = 0.0;
  double max_abs = 0.0;
  std::size_t class_flips = 0;
  std::size_t printed_flips = 0;
  std::size_t n = 0;
};

Delta compare(const std::vector<double>& a, const std::vector<double>& b) {
  Delta d;
  if (a.size() != b.size() || a.empty()) return d;
  d.n = a.size();
  double s = 0.0;
  for (std::size_t e = 0; e < a.size(); ++e) {
    const double v = std::fabs(a[e] - b[e]);
    s += v;
    d.max_abs = std::max(d.max_abs, v);
    if (class_of(a[e]) != class_of(b[e])) ++d.class_flips;
    if ((a[e] > kIso) != (b[e] > kIso)) ++d.printed_flips;
  }
  d.mean_abs = s / static_cast<double>(a.size());
  return d;
}

bool bit_identical(const RunRecord& a, const RunRecord& b) {
  if (a.rung_density.size() != b.rung_density.size()) return false;
  for (std::size_t i = 0; i < a.rung_density.size(); ++i) {
    if (a.rung_density[i] != b.rung_density[i]) return false;
    if (a.rung_compliance[i] != b.rung_compliance[i]) return false;
    if (a.rung_margin[i] != b.rung_margin[i]) return false;
    if (a.rung_iterations[i] != b.rung_iterations[i]) return false;
    if (a.rung_accepted[i] != b.rung_accepted[i]) return false;
  }
  return true;
}

double rel(double from, double to) {
  if (!std::isfinite(from) || !std::isfinite(to) || from == 0.0) return 0.0;
  return std::fabs(to - from) / std::fabs(from);
}

const char* verdict(const RunRecord& r, std::size_t i) {
  if (r.rung_infeasible[i]) return "INFEASIBLE";
  return r.rung_accepted[i] ? "ACCEPT" : "REJECT";
}

// --- mode: gate -----------------------------------------------------------

int mode_gate(const std::string& dir, const SettingsRules& rules,
              const Material& material) {
  const Fixture f = healthy_fixture();
  const Fixture fc = perturbed(f, 1e-9);

  std::printf("\n===== THE GATE TABLE — DISARMED (OFF) vs ARMED (ON) vs the "
              "1e-9 NEGATIVE CONTROL =====\n");
  std::printf("  OFF = active_domain_band 0 (what ships AFTER the flip)\n");
  std::printf("  ON  = active_domain_band -1 AUTO (what ships BEFORE)\n");
  std::printf("  CTL = band 0, loads x (1 + 1e-9) — the noise floor\n\n");

  const RunRecord off1 = run_ladder("off#1", f, 0, rules, material, 1);
  const RunRecord off2 = run_ladder("off#2", f, 0, rules, material, 1);
  const RunRecord on1 = run_ladder("on#1  AUTO", f, -1, rules, material, 1);
  const RunRecord on2 = run_ladder("on#2  AUTO", f, -1, rules, material, 1);
  const RunRecord ctl1 = run_ladder("ctl#1 1e-9", fc, 0, rules, material, 1);
  const RunRecord ctl2 = run_ladder("ctl#2 1e-9", fc, 0, rules, material, 1);

  std::printf("\n===== DETERMINISM =====\n");
  std::printf("  twice-run bit-identical:  OFF %s   ON %s   CTL %s\n",
              bit_identical(off1, off2) ? "YES" : "NO",
              bit_identical(on1, on2) ? "YES" : "NO",
              bit_identical(ctl1, ctl2) ? "YES" : "NO");

  const std::size_t n =
      std::min({off1.rung_vf.size(), on1.rung_vf.size(), ctl1.rung_vf.size()});
  bool same_rungs = off1.rung_vf.size() == on1.rung_vf.size();
  bool same_verdicts = same_rungs;
  bool ctl_same_verdicts = off1.rung_vf.size() == ctl1.rung_vf.size();
  for (std::size_t i = 0; i < n; ++i) {
    if (off1.rung_accepted[i] != on1.rung_accepted[i] ||
        off1.rung_infeasible[i] != on1.rung_infeasible[i])
      same_verdicts = false;
    if (off1.rung_accepted[i] != ctl1.rung_accepted[i] ||
        off1.rung_infeasible[i] != ctl1.rung_infeasible[i])
      ctl_same_verdicts = false;
  }

  std::printf("\n===== EVERY RUNG — VERDICT + MARGIN =====\n");
  std::printf("  rung   vf   verdict OFF->ON        margin OFF          "
              "margin ON           dM/M       | CTL margin         dM/M(ctl)\n");
  for (std::size_t i = 0; i < n; ++i)
    std::printf("   %zu    %.2f  %-10s -> %-10s %.12g  %.12g  %.4e | %.12g  "
                "%.4e\n",
                i, off1.rung_vf[i], verdict(off1, i), verdict(on1, i),
                off1.rung_margin[i], on1.rung_margin[i],
                rel(off1.rung_margin[i], on1.rung_margin[i]),
                ctl1.rung_margin[i],
                rel(off1.rung_margin[i], ctl1.rung_margin[i]));

  std::printf("\n===== EVERY RUNG — DESIGN MOTION vs THE CONTROL FLOOR =====\n");
  std::printf("  rung  elems | ON vs OFF: mean|drho|  max|drho|  class-flips  "
              "printed-flips | CTL vs OFF: mean|drho|  max|drho|  class-flips  "
              "printed-flips\n");
  double worst_margin_rel = 0.0, worst_ctl_margin_rel = 0.0;
  std::size_t on_flips = 0, ctl_flips = 0, on_pflips = 0, ctl_pflips = 0;
  for (std::size_t i = 0; i < n; ++i) {
    const Delta d_on = compare(on1.rung_density[i], off1.rung_density[i]);
    const Delta d_ctl = compare(ctl1.rung_density[i], off1.rung_density[i]);
    worst_margin_rel =
        std::max(worst_margin_rel, rel(off1.rung_margin[i], on1.rung_margin[i]));
    worst_ctl_margin_rel = std::max(
        worst_ctl_margin_rel, rel(off1.rung_margin[i], ctl1.rung_margin[i]));
    on_flips += d_on.class_flips;
    ctl_flips += d_ctl.class_flips;
    on_pflips += d_on.printed_flips;
    ctl_pflips += d_ctl.printed_flips;
    std::printf("   %zu   %5zu |            %.4e  %.4e  %10zu  %13zu |"
                "             %.4e  %.4e  %10zu  %13zu\n",
                i, d_on.n, d_on.mean_abs, d_on.max_abs, d_on.class_flips,
                d_on.printed_flips, d_ctl.mean_abs, d_ctl.max_abs,
                d_ctl.class_flips, d_ctl.printed_flips);
  }

  std::printf("\n===== THE FLOOR TEST =====\n");
  std::printf("  gate verdicts   OFF vs ON : %s\n",
              same_verdicts ? "IDENTICAL" : "*** DIFFERENT ***");
  std::printf("  gate verdicts   OFF vs CTL: %s\n",
              ctl_same_verdicts ? "IDENTICAL" : "*** DIFFERENT ***");
  std::printf("  terminal recommendation OFF \"%s\"\n                      ON  "
              "\"%s\"\n                      CTL \"%s\"\n",
              off1.terminal_recommendation.c_str(),
              on1.terminal_recommendation.c_str(),
              ctl1.terminal_recommendation.c_str());
  std::printf("  WORST dM/M        ON %.4e   vs control floor %.4e   -> %s\n",
              worst_margin_rel, worst_ctl_margin_rel,
              worst_margin_rel > worst_ctl_margin_rel ? "ABOVE the floor"
                                                      : "at/below the floor");
  std::printf("  TOTAL class-flips ON %zu    vs control floor %zu           "
              "-> %s\n",
              on_flips, ctl_flips,
              on_flips > ctl_flips ? "ABOVE the floor" : "at/below the floor");
  std::printf("  TOTAL printed-flips ON %zu  vs control floor %zu           "
              "-> %s\n",
              on_pflips, ctl_pflips,
              on_pflips > ctl_pflips ? "ABOVE the floor" : "at/below the floor");

  std::printf("\n===== COST (this fixture, healthy multigrid) =====\n");
  std::printf("  CG iterations   OFF %lld -> ON %lld  (%.4fx)\n", off1.cg_total,
              on1.cg_total,
              off1.cg_total ? double(on1.cg_total) / double(off1.cg_total) : 0.0);
  std::printf("  wall            OFF %.1f s -> ON %.1f s  (%.3fx)\n", off1.wall,
              on1.wall, off1.wall > 0.0 ? on1.wall / off1.wall : 0.0);
  std::printf("  optimizer iters OFF %lld -> ON %lld\n", off1.iters_total,
              on1.iters_total);
  std::printf("  Jacobi fallback OFF %d  ON %d   (of %lld / %lld solves)\n",
              off1.mg_fallback_solves, on1.mg_fallback_solves,
              off1.solves_total, on1.solves_total);
  std::printf("  GenEO           OFF armed=%lld builds=%lld  ON armed=%lld "
              "builds=%lld\n",
              off1.geneo_armed_solves, off1.geneo_basis_builds,
              on1.geneo_armed_solves, on1.geneo_basis_builds);
  std::printf("  ARMED latch     ");
  for (std::size_t i = 0; i < on1.rung_latched.size(); ++i)
    std::printf("rung%zu k=%d %s@%d esc=%lld%s  ", i, on1.rung_band_resolved[i],
                on1.rung_latched[i] ? "LATCHED" : "held",
                on1.rung_latch_iter[i], on1.rung_escape_count[i],
                on1.rung_latched[i] ? "" : "");
  std::printf("\n");
  for (std::size_t i = 0; i < on1.rung_latched.size(); ++i)
    if (on1.rung_latched[i])
      std::printf("    rung %zu latch reason: %s\n", i,
                  on1.rung_latch_reason[i].c_str());

  // CSVs — the durable record.
  const std::string gt = dir + "/gate_table.csv";
  if (FILE* fp = std::fopen(gt.c_str(), "w")) {
    std::fprintf(fp,
                 "rung,vf,off_verdict,on_verdict,ctl_verdict,off_margin,"
                 "on_margin,ctl_margin,dM_M_on,dM_M_ctl,off_compliance,"
                 "on_compliance,off_printed,on_printed,off_iters,on_iters,"
                 "on_f_bar,on_band_resolved,on_latched,on_latch_iter,"
                 "on_escape_count\n");
    for (std::size_t i = 0; i < n; ++i)
      std::fprintf(fp,
                   "%zu,%.4f,%s,%s,%s,%.12g,%.12g,%.12g,%.6e,%.6e,%.12g,%.12g,"
                   "%.6f,%.6f,%d,%d,%.6f,%d,%d,%d,%lld\n",
                   i, off1.rung_vf[i], verdict(off1, i), verdict(on1, i),
                   verdict(ctl1, i), off1.rung_margin[i], on1.rung_margin[i],
                   ctl1.rung_margin[i], rel(off1.rung_margin[i], on1.rung_margin[i]),
                   rel(off1.rung_margin[i], ctl1.rung_margin[i]),
                   off1.rung_compliance[i], on1.rung_compliance[i],
                   off1.rung_printed_fraction[i], on1.rung_printed_fraction[i],
                   off1.rung_iterations[i], on1.rung_iterations[i],
                   on1.rung_active_fraction_mean[i], on1.rung_band_resolved[i],
                   on1.rung_latched[i], on1.rung_latch_iter[i],
                   on1.rung_escape_count[i]);
    std::fclose(fp);
    std::printf("\n  wrote %s\n", gt.c_str());
  }
  const std::string fl = dir + "/flips.csv";
  if (FILE* fp = std::fopen(fl.c_str(), "w")) {
    std::fprintf(fp, "rung,comparison,elements,n_class_flips,n_printed_flips,"
                     "max_drho,mean_drho\n");
    for (std::size_t i = 0; i < n; ++i) {
      const Delta d_on = compare(on1.rung_density[i], off1.rung_density[i]);
      const Delta d_ctl = compare(ctl1.rung_density[i], off1.rung_density[i]);
      std::fprintf(fp, "%zu,control_1e-9_vs_off,%zu,%zu,%zu,%.3e,%.3e\n", i,
                   d_ctl.n, d_ctl.class_flips, d_ctl.printed_flips, d_ctl.max_abs,
                   d_ctl.mean_abs);
      std::fprintf(fp, "%zu,armed_on_vs_off,%zu,%zu,%zu,%.3e,%.3e\n", i, d_on.n,
                   d_on.class_flips, d_on.printed_flips, d_on.max_abs,
                   d_on.mean_abs);
    }
    std::fclose(fp);
    std::printf("  wrote %s\n", fl.c_str());
  }
  return 0;
}

// --- mode: padinert -------------------------------------------------------
//
// Could the odd-axis parity pad (2026-07-31) have changed ANY prior AD
// measurement? Only if it engaged, and it engages only when a FINE AXIS IS ODD.
// Every fixture the AD arming and the 2026-07-27 review measured on is a
// design-box fixture, and `dims` shows those are all-even by construction. This
// closes the loop by MEASUREMENT rather than by that argument: run the arming
// gate fixture under pad mode 0 (legacy) and pad mode 1 (AUTO, today's default),
// AD off and AD on, and require the pairs to be BIT-IDENTICAL. If they are, the
// pad is provably inert on this class and no pre-262 AD number needs re-taking.
int mode_padinert(const std::string& dir, const SettingsRules& rules,
                  const Material& material, int iters) {
  const Fixture f = healthy_fixture();
  std::printf("\n===== IS THE PARITY PAD INERT ON THE AD FIXTURE CLASS? =====\n");
  std::printf("  The arming gate fixture (design box -> align-8 -> all-even "
              "grid), pad 0 vs pad 1.\n");
  // Rung 0 at a fixed length is SUFFICIENT and is the honest scope: the parity
  // pad is a hierarchy-construction choice made at the FIRST solve of a run. If
  // it engaged at all, the very first solve would differ and the fields would
  // diverge immediately; there is nothing it could do on rung 1 that it did not
  // already do on iteration 1. A bit-identical %d-iteration rung is therefore a
  // complete answer, and it costs a twelfth of the full ladder.
  std::printf("  Rung 0, %d iterations, identical in all four cells.\n\n", iters);
  const RunRecord p0_off = run_ladder("pad0/AD-off", f, 0, rules, material, 0, true, iters);
  const RunRecord p1_off = run_ladder("pad1/AD-off", f, 0, rules, material, 1, true, iters);
  const RunRecord p0_on = run_ladder("pad0/AD-on ", f, -1, rules, material, 0, true, iters);
  const RunRecord p1_on = run_ladder("pad1/AD-on ", f, -1, rules, material, 1, true, iters);
  const bool id_off = bit_identical(p0_off, p1_off);
  const bool id_on = bit_identical(p0_on, p1_on);
  std::printf("\n  pad 0 vs pad 1, AD OFF: %s   (CG %lld vs %lld)\n",
              id_off ? "BIT-IDENTICAL" : "*** DIFFERENT ***", p0_off.cg_total,
              p1_off.cg_total);
  std::printf("  pad 0 vs pad 1, AD ON : %s   (CG %lld vs %lld)\n",
              id_on ? "BIT-IDENTICAL" : "*** DIFFERENT ***", p0_on.cg_total,
              p1_on.cg_total);
  std::printf("\n  => the parity pad is %s on the AD fixture class.\n",
              (id_off && id_on) ? "INERT" : "NOT inert");
  const std::string p = dir + "/pad_inert.csv";
  if (FILE* fp = std::fopen(p.c_str(), "w")) {
    std::fprintf(fp, "cell,pad_mode,active_domain_band,grid,mg_carried,cg_total,"
                     "wall_s,bit_identical_to_pad1\n");
    const RunRecord* rs[4] = {&p0_off, &p1_off, &p0_on, &p1_on};
    const int pads[4] = {0, 1, 0, 1};
    const int bands[4] = {0, 0, -1, -1};
    const char* names[4] = {"pad0/AD-off", "pad1/AD-off", "pad0/AD-on",
                            "pad1/AD-on"};
    const char* ident[4] = {id_off ? "yes" : "no", "-", id_on ? "yes" : "no",
                            "-"};
    for (int i = 0; i < 4; ++i)
      std::fprintf(fp, "%s,%d,%d,%dx%dx%d,%d,%lld,%.2f,%s\n", names[i], pads[i],
                   bands[i], rs[i]->grid_nx, rs[i]->grid_ny, rs[i]->grid_nz,
                   rs[i]->used_multigrid ? 1 : 0, rs[i]->cg_total, rs[i]->wall,
                   ident[i]);
    std::fclose(fp);
    std::printf("  wrote %s\n", p.c_str());
  }
  return (id_off && id_on) ? 0 : 1;
}

// --- mode: odd ------------------------------------------------------------
//
// The class 262 ACTUALLY rescued: an odd-axis grid, which in this codebase only
// occurs with NO design box (see `dims`). 2x2 over pad mode x AD, on today's
// build. It answers two things at once: what the pad buys on the class it was
// built for, and whether AD can even engage there.
int mode_odd(const std::string& dir, const SettingsRules& rules,
             const Material& material, int iters) {
  const Fixture f = odd_axis_fixture();
  std::printf("\n===== THE ODD-AXIS CLASS — pad x AD =====\n");
  std::printf("  No design box, so the solved grid IS the part grid (odd axes "
              "survive).\n");
  std::printf("  pad 0 = the pre-262 world (hierarchy rejected, Jacobi-CG "
              "carries).\n");
  std::printf("  pad 1 = today (parity-padded index space, multigrid "
              "carries).\n");
  // Rung 0 at a FIXED length in all four cells. A cost comparison across a
  // posture that changes the trajectory must hold the optimizer length equal, or
  // the CG totals are comparing different amounts of work.
  std::printf("  Rung 0, %d iterations, identical in all four cells.\n\n", iters);

  struct Cell { const char* label; int pad; int band; };
  const Cell cells[4] = {{"pad0/AD-off", 0, 0},
                         {"pad0/AD-on ", 0, -1},
                         {"pad1/AD-off", 1, 0},
                         {"pad1/AD-on ", 1, -1}};
  std::vector<RunRecord> res;
  for (const Cell& c : cells)
    res.push_back(
        run_ladder(c.label, f, c.band, rules, material, c.pad, true, iters));

  std::printf("\n===== THE 2x2 =====\n");
  std::printf("  cell         mg           CG        wall(s)  opt-iters  "
              "jacobi/solves  geneo armed  geneo builds  AD f_bar  AD latched\n");
  for (std::size_t i = 0; i < res.size(); ++i) {
    const RunRecord& r = res[i];
    double fbar = 0.0;
    int latched = 0;
    for (std::size_t k = 0; k < r.rung_vf.size(); ++k) {
      fbar += r.rung_active_fraction_mean[k];
      latched += r.rung_latched[k];
    }
    if (!r.rung_vf.empty()) fbar /= double(r.rung_vf.size());
    std::printf("  %-12s %-12s %-9lld %-8.1f %-10lld %5d/%-8lld %-12lld "
                "%-13lld %-9.4f %d/%zu\n",
                cells[i].label, r.used_multigrid ? "carried" : "NOT-carried",
                r.cg_total, r.wall, r.iters_total, r.mg_fallback_solves,
                r.solves_total, r.geneo_armed_solves, r.geneo_basis_builds,
                fbar, latched, r.rung_vf.size());
  }
  auto ratio = [](long long a, long long b) {
    return a ? double(b) / double(a) : 0.0;
  };
  std::printf("\n  AD effect, pad OFF (pre-262 Jacobi world): CG %lld -> %lld "
              "(%.4fx)\n",
              res[0].cg_total, res[1].cg_total,
              ratio(res[0].cg_total, res[1].cg_total));
  std::printf("  AD effect, pad ON  (post-262 MG world)  : CG %lld -> %lld "
              "(%.4fx)\n",
              res[2].cg_total, res[3].cg_total,
              ratio(res[2].cg_total, res[3].cg_total));
  std::printf("  the pad itself     (AD off)             : CG %lld -> %lld "
              "(%.4fx)\n",
              res[0].cg_total, res[2].cg_total,
              ratio(res[0].cg_total, res[2].cg_total));
  for (std::size_t i = 0; i < res.size(); ++i)
    for (std::size_t k = 0; k < res[i].rung_latched.size(); ++k)
      if (res[i].rung_latched[k])
        std::printf("    [%s] rung %zu LATCHED @iter %d: %s\n", cells[i].label, k,
                    res[i].rung_latch_iter[k],
                    res[i].rung_latch_reason[k].c_str());

  const std::string p = dir + "/odd_axis.csv";
  if (FILE* fp = std::fopen(p.c_str(), "w")) {
    std::fprintf(fp, "cell,pad_mode,active_domain_band,grid,mg_carried,cg_total,"
                     "wall_s,opt_iters,jacobi_solves,solves_total,"
                     "geneo_armed_solves,geneo_basis_builds,ad_fbar_mean,"
                     "ad_rungs_latched,rungs,verdicts\n");
    for (std::size_t i = 0; i < res.size(); ++i) {
      const RunRecord& r = res[i];
      double fbar = 0.0;
      int latched = 0;
      std::string v;
      for (std::size_t k = 0; k < r.rung_vf.size(); ++k) {
        fbar += r.rung_active_fraction_mean[k];
        latched += r.rung_latched[k];
        v += (k ? "|" : "");
        v += verdict(r, k);
      }
      if (!r.rung_vf.empty()) fbar /= double(r.rung_vf.size());
      std::fprintf(fp, "%s,%d,%d,%dx%dx%d,%d,%lld,%.2f,%lld,%d,%lld,%lld,%lld,"
                       "%.6f,%d,%zu,%s\n",
                   cells[i].label, cells[i].pad, cells[i].band, r.grid_nx,
                   r.grid_ny, r.grid_nz, r.used_multigrid ? 1 : 0, r.cg_total,
                   r.wall, r.iters_total, r.mg_fallback_solves, r.solves_total,
                   r.geneo_armed_solves, r.geneo_basis_builds, fbar, latched,
                   r.rung_vf.size(), v.c_str());
    }
    std::fclose(fp);
    std::printf("\n  wrote %s\n", p.c_str());
  }
  return 0;
}

// --- mode: stag -----------------------------------------------------------
//
// The +26% coin-flip regime, re-measured on TODAY's build. The 48x32x48
// ultra-dilute box falls back to Jacobi-CG by STAGNATION (the hierarchy builds
// and stops contracting) — a mechanism the parity pad does not touch. Rung 0
// only, capped identically in both postures, so the comparison is CG at equal
// optimizer length. GenEO counters included: this is where deflation actually
// engages, so it is where AD's mask churn can invalidate the moduli fingerprint
// and force basis rebuilds.
int mode_stag(const std::string& dir, const SettingsRules& rules,
              const Material& material, int iters) {
  const Fixture f = stagnation_fixture();
  std::printf("\n===== THE STAGNATION REGIME, RE-MEASURED TODAY (rung 0, %d "
              "iterations, both postures) =====\n",
              iters);
  const RunRecord off =
      run_ladder("stag/AD-off", f, 0, rules, material, 1, /*single_rung=*/true,
                 iters);
  const RunRecord on =
      run_ladder("stag/AD-on ", f, -1, rules, material, 1, /*single_rung=*/true,
                 iters);
  std::printf("\n  CG            OFF %lld -> ON %lld  (%.4fx)\n", off.cg_total,
              on.cg_total,
              off.cg_total ? double(on.cg_total) / double(off.cg_total) : 0.0);
  std::printf("  wall          OFF %.1f s -> ON %.1f s\n", off.wall, on.wall);
  std::printf("  Jacobi solves OFF %d/%lld -> ON %d/%lld\n",
              off.mg_fallback_solves, off.solves_total, on.mg_fallback_solves,
              on.solves_total);
  std::printf("  GenEO         OFF armed=%lld builds=%lld -> ON armed=%lld "
              "builds=%lld\n",
              off.geneo_armed_solves, off.geneo_basis_builds,
              on.geneo_armed_solves, on.geneo_basis_builds);
  for (std::size_t k = 0; k < on.rung_latched.size(); ++k)
    std::printf("  AD rung %zu: k=%d f_bar=%.4f %s@%d escapes=%lld %s\n", k,
                on.rung_band_resolved[k], on.rung_active_fraction_mean[k],
                on.rung_latched[k] ? "LATCHED" : "held", on.rung_latch_iter[k],
                on.rung_escape_count[k], on.rung_latch_reason[k].c_str());
  const std::string p = dir + "/stagnation.csv";
  if (FILE* fp = std::fopen(p.c_str(), "w")) {
    std::fprintf(fp, "posture,active_domain_band,grid,cg_total,wall_s,opt_iters,"
                     "jacobi_solves,solves_total,geneo_armed_solves,"
                     "geneo_basis_builds,ad_fbar,ad_latched,ad_escapes\n");
    const RunRecord* rs[2] = {&off, &on};
    const int bands[2] = {0, -1};
    const char* names[2] = {"AD-off", "AD-on"};
    for (int i = 0; i < 2; ++i)
      std::fprintf(fp, "%s,%d,%dx%dx%d,%lld,%.2f,%lld,%d,%lld,%lld,%lld,%.6f,%d,"
                       "%lld\n",
                   names[i], bands[i], rs[i]->grid_nx, rs[i]->grid_ny,
                   rs[i]->grid_nz, rs[i]->cg_total, rs[i]->wall,
                   rs[i]->iters_total, rs[i]->mg_fallback_solves,
                   rs[i]->solves_total, rs[i]->geneo_armed_solves,
                   rs[i]->geneo_basis_builds,
                   rs[i]->rung_active_fraction_mean.empty()
                       ? 0.0
                       : rs[i]->rung_active_fraction_mean[0],
                   rs[i]->rung_latched.empty() ? 0 : rs[i]->rung_latched[0],
                   rs[i]->rung_escape_count.empty()
                       ? 0LL
                       : rs[i]->rung_escape_count[0]);
    std::fclose(fp);
    std::printf("\n  wrote %s\n", p.c_str());
  }
  return 0;
}

// --- mode: dims -----------------------------------------------------------

void print_plan(const char* label, const Fixture& f) {
  MinimizePlasticOptions probe = base_options(f, 0);
  const VoxelGrid solved = minimize_plastic_solved_grid(f.part, probe);
  const MgCoarsenPlan plan = mg_coarsen_plan(solved.nx, solved.ny, solved.nz);
  int px = 0, py = 0, pz = 0;
  const int pad_levels = mg_pad_target(solved.nx, solved.ny, solved.nz, px, py, pz);
  std::printf("  %-12s solved grid %3dx%3dx%3d = %d elements  "
              "coarsenable(legacy)=%-3s levels=%d  |  padded index space "
              "%3dx%3dx%3d levels=%d\n",
              label, solved.nx, solved.ny, solved.nz,
              solved.nx * solved.ny * solved.nz, plan.accepted ? "YES" : "NO",
              plan.levels, px, py, pz, pad_levels);
}

}  // namespace

int main(int argc, char** argv) {
  std::setvbuf(stdout, nullptr, _IOLBF, 0);
  const std::string mode = argc > 1 ? argv[1] : "dims";
  const std::string dir = evidence_dir();
  SettingsRules rules;
  try {
    rules = load_settings_rules_file(SETTINGS_RULES_PATH);
  } catch (const std::exception& e) {
    std::fprintf(stderr, "FAIL: rules.json: %s\n", e.what());
    return 1;
  }
  const Material material = fdm_material();

  std::printf("ad_disarm_gate — mode=%s  evidence=%s\n", mode.c_str(),
              dir.c_str());
  std::printf("  production_active_domain_band() = %d  (the constant this task "
              "flips)\n",
              production_active_domain_band());

  if (mode == "dims") {
    std::printf("\n===== FIXTURE GRIDS + MULTIGRID COARSEN PLANS =====\n");
    print_plan("healthy", healthy_fixture());
    print_plan("stagnation", stagnation_fixture());
    print_plan("odd-axis", odd_axis_fixture());

    // THE STRUCTURAL POINT, MEASURED. expand_design_domain rounds every axis up
    // to kDesignBoxCoarsenAlign = 8, so NO design-box grid can carry an odd
    // axis, whatever box the user draws. Sweep the healthy fixture's box height
    // one millimetre at a time and print the solved ny: every one is even.
    std::printf("\n===== CAN A DESIGN-BOX GRID EVER BE ODD? (align = %d) =====\n",
                kDesignBoxCoarsenAlign);
    std::printf("  box y-extent (mm) -> solved grid\n");
    bool any_odd = false;
    for (int mm = 24; mm <= 33; ++mm) {
      Fixture f = healthy_fixture();
      f.box.max = Vec3{23.0, f.box.min.y + double(mm), 23.0};
      MinimizePlasticOptions probe = base_options(f, 0);
      const VoxelGrid g = minimize_plastic_solved_grid(f.part, probe);
      const bool odd = (g.nx % 2) || (g.ny % 2) || (g.nz % 2);
      any_odd = any_odd || odd;
      std::printf("   %2d              -> %3dx%3dx%3d   %s\n", mm, g.nx, g.ny,
                  g.nz, odd ? "ODD AXIS" : "all even");
    }
    std::printf("\n  => a design-box grid carried an odd axis in %s of the "
                "sweep.\n", any_odd ? "SOME" : "NONE");
    return 0;
  }
  if (mode == "gate") return mode_gate(dir, rules, material);
  if (mode == "padinert")
    return mode_padinert(dir, rules, material, argc > 2 ? std::atoi(argv[2]) : 10);
  if (mode == "odd")
    return mode_odd(dir, rules, material, argc > 2 ? std::atoi(argv[2]) : 25);
  if (mode == "stag")
    return mode_stag(dir, rules, material, argc > 2 ? std::atoi(argv[2]) : 12);
  std::fprintf(stderr,
               "unknown mode '%s' (dims | gate | padinert | odd | stag [N])\n",
               mode.c_str());
  return 2;
}
