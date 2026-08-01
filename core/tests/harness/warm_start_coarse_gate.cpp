// warm_start_coarse_gate.cpp — the before/after measurement harness for the
// COARSE-TO-FINE CASCADE (handoff 110 Part B, `warm_start_coarse`), for task
// `warm-start-coarse-experiment`, handoff
// docs/handoffs/2026-08-02-warm-start-coarse-experiment.md.
//
// NOT a CI test; standalone, a sibling of ad_disarm_gate.cpp, whose fixtures,
// negative-control discipline and comparison quantities it reuses VERBATIM so
// the two tables are readable side by side.
//
// THE QUESTION. On a real maintainer run (128^3, design box) multigrid
// stagnated on 3 of 65 design iterations and those 3 took 80% of the rung's
// wall. `warm_start_coarse` runs a res/2 pre-solve first, so the thrashing
// could in principle be done at ~1/8 the DOFs and the settled design prolonged
// onto the fine grid. This harness measures whether it is.
//
// WHAT IT MEASURES, per fixture, in ONE process at full double precision:
//   OFF  = warm_start_coarse false  (the shipped default)
//   ON   = warm_start_coarse true   (the lever)
//   CTL  = OFF under a 1e-9 RELATIVE LOAD PERTURBATION — the NEGATIVE-CONTROL
//          FLOOR (the 2026-08-01 multiscale-wiring I3 / PR 248 discipline).
//          A physically meaningless nudge, far below the solver's own 1e-8
//          basin, so whatever design motion it produces is pure iteration-route
//          noise. ON-vs-OFF motion at or below that floor is noise; above it is
//          real, and this harness REPORTS it rather than rounding it away.
// each run TWICE (determinism, AC7).
//
// AND, because this project was just burned by an iteration-count-only decision
// (GenEO — handoff 2026-08-02-iteration-phase-timing found 87.9% of a
// stagnating iteration is accelerator overhead the iteration counter cannot
// see), EVERY table carries ITERATIONS AND WALL, BOTH, ALWAYS (AC2), read off
// that task's own per-phase instrument via SimpIterationObservation::phases:
//   * stagnating iterations per rung (cg_used_multigrid == false) and the WALL
//     spent inside them,
//   * the iteration at which compliance settles,
//   * and the pre-solve's OWN iterations and wall on a SEPARATE line (AC3) —
//     a net win must be net OF the pre-solve.
//
// FIXTURES (all three from ad_disarm_gate.cpp, unmodified):
//   `stag`    48x32x48 ultra-dilute design box — multigrid STAGNATES. THE TARGET.
//   `healthy` 32x24x32 design box — multigrid carries. The honest control (AC6):
//             if the cascade helps only the stagnating case and costs this one,
//             that trade is reported, NOT averaged.
//   `nobox`   33x25x33, NO design box (AC6's second control).
//
// Build (standalone; NOT wired into CTest):
//   c++ -std=c++17 -O2 -I core/include -I /opt/homebrew/include/eigen3 \
//     -DSETTINGS_RULES_PATH="\"$PWD/core/src/settings/rules.json\"" \
//     core/tests/harness/warm_start_coarse_gate.cpp build/libtopopt.a -o /tmp/wscg
// Run:
//   /tmp/wscg <stag|healthy|nobox|all>      (TOPOPT_WSC_DIR selects the CSV dir)

#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <stdexcept>
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

// Compliance is "settled" once every later iteration of the rung stays within
// this RELATIVE band of the rung's final compliance. A definition, not a fit —
// printed with the table so it can be re-derived.
constexpr double kSettleTol = 0.10;

std::string evidence_dir() {
  const char* d = std::getenv("TOPOPT_WSC_DIR");
  return d ? std::string(d) : std::string("wsc_gate");
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

// --- fixtures: VERBATIM from ad_disarm_gate.cpp ---------------------------
// Copied rather than shared so this harness stays standalone like every other
// harness in this directory, and so the two tables describe the same geometry.

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
  bool has_box = true;
};

Fixture healthy_fixture() {
  Fixture f;
  f.part = l_bracket(f.bcs, /*arm*/ 14, /*span*/ 14, /*ny*/ 4, /*t*/ 6, /*h*/ 1.0);
  f.loads = traction_loads(f.part, VoxelTag::Load, Vec3{0.0, 0.0, -30.0});
  f.box.min = Vec3{-9.0, -10.0, -9.0};
  f.box.max = Vec3{23.0, 14.0, 23.0};
  return f;
}

Fixture stagnation_fixture() {
  Fixture f;
  f.part = l_bracket(f.bcs, /*arm*/ 24, /*span*/ 24, /*ny*/ 6, /*t*/ 6, /*h*/ 1.0);
  f.loads = traction_loads(f.part, VoxelTag::Load, Vec3{0.0, 0.0, -30.0});
  f.box.min = Vec3{-12.0, -13.0, -12.0};
  f.box.max = Vec3{36.0, 19.0, 36.0};
  return f;
}

Fixture odd_axis_fixture() {
  Fixture f;
  f.part = l_bracket(f.bcs, /*arm*/ 33, /*span*/ 33, /*ny*/ 25, /*t*/ 5, /*h*/ 1.0);
  f.loads = traction_loads(f.part, VoxelTag::Load, Vec3{0.0, 0.0, -30.0});
  f.has_box = false;
  return f;
}

// The NEGATIVE CONTROL: a 1e-9 relative nudge to the load vector, far below any
// physical meaning and far below the solver's own 1e-8 relative-residual basin.
Fixture perturbed(const Fixture& f, double eps) {
  Fixture c = f;
  for (NodalLoad& l : c.loads) l.value *= (1.0 + eps);
  return c;
}

MinimizePlasticOptions base_options(const Fixture& f, bool warm_coarse) {
  MinimizePlasticOptions o;
  configure_production_options(o);  // the PRODUCTION config, unmodified
  o.volume_fraction_ladder = production_reduction_ladder();
  o.margin_stop = 1.5;
  o.external_loads = f.loads;
  o.gravity = 9810.0 * 1e-9;
  o.gravity_direction = Vec3{0.0, 0.0, -1.0};
  o.infill_percent = 100.0;
  if (f.has_box) o.design_box = f.box;
  // THE ONE VARIABLE. Everything else is whatever production ships today —
  // in particular warm_start_inherit stays at its default (false), because on
  // a self-weight-shaped run that is exactly what production does (handoff 113
  // arms Part A for load-case runs only). Part B is measured ALONE here, which
  // is the posture a flip would actually ship on this path.
  o.warm_start_coarse = warm_coarse;
  return o;
}

// --- one run's record ------------------------------------------------------

struct RungRecord {
  double vf = 0.0;
  int iterations = 0;
  int accepted = 0;
  int infeasible = 0;
  double margin = 0.0;
  double compliance = 0.0;
  double printed_fraction = 0.0;
  std::vector<double> density;  // full double precision
  // AC1/AC2 — read off the per-phase instrument (handoff 2026-08-02-iteration-
  // phase-timing), accumulated by the on_iteration hook below.
  double wall_ms = 0.0;
  double stagnating_wall_ms = 0.0;
  int stagnating_iters = 0;
  int latched_iters = 0;
  double geneo_ms = 0.0;
  long long cg_iters = 0;
  long long matvecs = 0;
  int settle_iter = 0;
};

struct RunRecord {
  std::string label;
  double wall = 0.0;              // whole-ladder wall INCLUDING the pre-solve
  int grid_nx = 0, grid_ny = 0, grid_nz = 0;
  bool used_multigrid = false;
  long long geneo_basis_builds = 0;
  long long geneo_armed_solves = 0;
  // AC3 — the pre-solve's OWN cost, kept separate and never folded in.
  int pre_iterations = 0;
  double pre_ms = 0.0;
  long long pre_matvecs = 0;
  std::vector<RungRecord> rungs;

  long long fine_matvecs() const {
    long long s = 0;
    for (const RungRecord& r : rungs) s += r.matvecs;
    return s;
  }

  double fine_wall_ms() const {
    double s = 0.0;
    for (const RungRecord& r : rungs) s += r.wall_ms;
    return s;
  }
  int fine_iters() const {
    int s = 0;
    for (const RungRecord& r : rungs) s += r.iterations;
    return s;
  }
  double stag_wall_ms() const {
    double s = 0.0;
    for (const RungRecord& r : rungs) s += r.stagnating_wall_ms;
    return s;
  }
  int stag_iters() const {
    int s = 0;
    for (const RungRecord& r : rungs) s += r.stagnating_iters;
    return s;
  }
};

// First 1-based iteration from which the rung stays within kSettleTol of its
// final compliance.
int settle_iteration(const std::vector<double>& c) {
  if (c.empty()) return 0;
  const double f = c.back();
  if (!std::isfinite(f) || f == 0.0) return static_cast<int>(c.size());
  int settled = static_cast<int>(c.size());
  for (int i = static_cast<int>(c.size()) - 1; i >= 0; --i) {
    if (std::fabs(c[i] - f) / std::fabs(f) <= kSettleTol) settled = i + 1;
    else break;
  }
  return settled;
}

RunRecord run_ladder(const char* label, const Fixture& f, bool warm_coarse,
                     const SettingsRules& rules, const Material& material) {
  MinimizePlasticOptions o = base_options(f, warm_coarse);
  fea_reset_geneo_basis();

  RunRecord r;
  r.label = label;

  // Per-rung accumulation off the per-phase instrument. The observation carries
  // its own phase breakdown, so "the wall spent in stagnating iterations" is a
  // SUM OF MEASURED DURATIONS, not a fraction inferred from a count.
  std::vector<std::vector<double>> rung_compliance;
  std::vector<RungRecord> live;
  o.on_iteration = [&](std::size_t rung, std::size_t,
                       const SimpIterationObservation& obs) {
    if (live.size() <= rung) { live.resize(rung + 1); rung_compliance.resize(rung + 1); }
    RungRecord& rr = live[rung];
    const double it_ms = obs.phases.total_ms + obs.phases.tail_prev_ms;
    rr.wall_ms += it_ms;
    rr.geneo_ms += obs.phases.solver_geneo_setup_ms +
                   obs.phases.solver_geneo_apply_ms;
    rr.cg_iters += obs.cg_iterations;
    rr.matvecs += obs.phases.matvecs;
    if (!obs.cg_used_multigrid) { ++rr.stagnating_iters; rr.stagnating_wall_ms += it_ms; }
    if (!obs.cg_hier_built) ++rr.latched_iters;
    rung_compliance[rung].push_back(obs.compliance);
  };

  const auto t0 = std::chrono::steady_clock::now();
  const MinimizePlasticResult res =
      minimize_plastic(f.part, material, "fdm", f.bcs, rules, o);
  r.wall = std::chrono::duration<double>(
               std::chrono::steady_clock::now() - t0).count();

  r.grid_nx = res.solved_grid.nx;
  r.grid_ny = res.solved_grid.ny;
  r.grid_nz = res.solved_grid.nz;
  r.used_multigrid = res.used_multigrid;
  r.geneo_basis_builds = fea_geneo_basis_builds();
  r.geneo_armed_solves = fea_geneo_armed_solves();
  r.pre_iterations = res.warm_start_coarse_iterations;
  r.pre_ms = res.warm_start_coarse_ms;
  r.pre_matvecs = res.warm_start_coarse_matvecs;

  for (std::size_t i = 0; i < res.evaluated.size(); ++i) {
    const MinimizePlasticVariant& v = res.evaluated[i];
    RungRecord rr = (i < live.size()) ? live[i] : RungRecord();
    rr.vf = v.requested_volume_fraction;
    rr.iterations = v.optimization.iterations;
    rr.accepted = v.accepted ? 1 : 0;
    rr.infeasible = v.infeasible ? 1 : 0;
    rr.margin = v.report.margin.worst_case;
    rr.compliance = v.optimization.compliance;
    rr.printed_fraction = v.report.printed_fraction;
    rr.density = v.optimization.physical_density;
    rr.settle_iter = (i < rung_compliance.size())
                         ? settle_iteration(rung_compliance[i]) : 0;
    r.rungs.push_back(std::move(rr));
  }

  std::printf("  [%-14s] grid %dx%dx%d  mg=%s  %.1f s TOTAL wall  "
              "(fine %.1f s / %d iters ; PRE-SOLVE %d iters %.1f s)  "
              "geneo builds=%lld armed=%lld\n",
              label, r.grid_nx, r.grid_ny, r.grid_nz,
              r.used_multigrid ? "carried" : "NOT-carried", r.wall,
              r.fine_wall_ms() / 1000.0, r.fine_iters(), r.pre_iterations,
              r.pre_ms / 1000.0, r.geneo_basis_builds, r.geneo_armed_solves);
  for (std::size_t i = 0; i < r.rungs.size(); ++i) {
    const RungRecord& rr = r.rungs[i];
    std::printf("    rung %zu vf=%.2f %-6s%s iters=%3d wall=%8.1f s | "
                "STAGNATING %2d it / %7.1f s (%5.1f%%) | latched %2d | "
                "GenEO %6.1f s | settle@%2d | margin=%.10g compliance=%.12g\n",
                i, rr.vf, rr.accepted ? "ACCEPT" : "REJECT",
                rr.infeasible ? " INFEAS" : "", rr.iterations,
                rr.wall_ms / 1000.0, rr.stagnating_iters,
                rr.stagnating_wall_ms / 1000.0,
                rr.wall_ms > 0 ? 100.0 * rr.stagnating_wall_ms / rr.wall_ms : 0.0,
                rr.latched_iters, rr.geneo_ms / 1000.0, rr.settle_iter,
                rr.margin, rr.compliance);
  }
  std::fflush(stdout);
  return r;
}

// --- the comparison quantities: VERBATIM from ad_disarm_gate.cpp -----------

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

// Determinism (AC7): every number a verdict could rest on, to the byte.
bool bit_identical(const RunRecord& a, const RunRecord& b) {
  if (a.rungs.size() != b.rungs.size()) return false;
  for (std::size_t i = 0; i < a.rungs.size(); ++i) {
    if (a.rungs[i].density != b.rungs[i].density) return false;
    if (a.rungs[i].compliance != b.rungs[i].compliance) return false;
    if (a.rungs[i].margin != b.rungs[i].margin) return false;
    if (a.rungs[i].iterations != b.rungs[i].iterations) return false;
    if (a.rungs[i].accepted != b.rungs[i].accepted) return false;
  }
  return a.pre_iterations == b.pre_iterations;
}

const char* verdict(const RungRecord& r) {
  if (r.infeasible) return "INFEASIBLE";
  return r.accepted ? "ACCEPT" : "REJECT";
}

double pct(double from, double to) {
  if (from == 0.0) return 0.0;
  return 100.0 * (to - from) / from;
}

// --- one fixture, the whole table ------------------------------------------

int measure(const std::string& name, const Fixture& f, const std::string& dir,
            const SettingsRules& rules, const Material& material) {
  const Fixture fc = perturbed(f, 1e-9);

  std::printf("\n===== FIXTURE %s : warm_start_coarse OFF vs ON, "
              "with a 1e-9 NEGATIVE CONTROL =====\n", name.c_str());
  std::printf("  OFF = warm_start_coarse false (shipped default)\n");
  std::printf("  ON  = warm_start_coarse true  (handoff 110 Part B)\n");
  std::printf("  CTL = OFF, loads x (1 + 1e-9) — the noise floor\n\n");

  const RunRecord off1 = run_ladder("off#1", f, false, rules, material);
  const RunRecord off2 = run_ladder("off#2", f, false, rules, material);
  const RunRecord on1 = run_ladder("on#1", f, true, rules, material);
  const RunRecord on2 = run_ladder("on#2", f, true, rules, material);
  const RunRecord ctl1 = run_ladder("ctl#1 1e-9", fc, false, rules, material);
  const RunRecord ctl2 = run_ladder("ctl#2 1e-9", fc, false, rules, material);

  std::printf("\n  --- AC7 DETERMINISM (byte-identical rerun in each posture) ---\n");
  std::printf("    OFF twice : %s\n", bit_identical(off1, off2) ? "IDENTICAL" : "*** DIFFERS ***");
  std::printf("    ON  twice : %s\n", bit_identical(on1, on2) ? "IDENTICAL" : "*** DIFFERS ***");
  std::printf("    CTL twice : %s\n", bit_identical(ctl1, ctl2) ? "IDENTICAL" : "*** DIFFERS ***");

  // AC2/AC3 — iterations and wall, both, always, with the pre-solve charged.
  const double off_fine = off1.fine_wall_ms(), on_fine = on1.fine_wall_ms();
  const double on_charged = on_fine + on1.pre_ms;
  std::printf("\n  --- AC2/AC3 ITERATIONS AND WALL, BOTH (pre-solve CHARGED) ---\n");
  std::printf("    %-22s %10s %10s %10s\n", "", "OFF", "ON", "change");
  std::printf("    %-22s %10d %10d %+9.1f%%\n", "fine iterations",
              off1.fine_iters(), on1.fine_iters(),
              pct(off1.fine_iters(), on1.fine_iters()));
  std::printf("    %-22s %10s %10d %10s\n", "pre-solve iterations", "-",
              on1.pre_iterations, "");
  std::printf("    %-22s %10d %10d %+9.1f%%\n", "CHARGED iterations",
              off1.fine_iters(), on1.fine_iters() + on1.pre_iterations,
              pct(off1.fine_iters(), on1.fine_iters() + on1.pre_iterations));
  std::printf("    %-22s %10.1f %10.1f %+9.1f%%\n", "fine wall (s)",
              off_fine / 1000.0, on_fine / 1000.0, pct(off_fine, on_fine));
  std::printf("    %-22s %10s %10.1f %10s\n", "pre-solve wall (s)", "-",
              on1.pre_ms / 1000.0, "");
  std::printf("    %-22s %10.1f %10.1f %+9.1f%%   <== THE ANSWER\n",
              "CHARGED wall (s)", off_fine / 1000.0, on_charged / 1000.0,
              pct(off_fine, on_charged));
  std::printf("    %-22s %10d %10d %+9.1f%%\n", "stagnating iterations",
              off1.stag_iters(), on1.stag_iters(),
              pct(off1.stag_iters(), on1.stag_iters()));
  std::printf("    %-22s %10.1f %10.1f %+9.1f%%\n", "wall IN stagnation (s)",
              off1.stag_wall_ms() / 1000.0, on1.stag_wall_ms() / 1000.0,
              pct(off1.stag_wall_ms(), on1.stag_wall_ms()));
  // MATVECS — the DETERMINISTIC cost column. Wall on this host is measured
  // under whatever else is running; operator applies are not. If the wall row
  // and the matvec row disagree in SIGN, trust the matvec row and re-measure
  // wall on a quiet host — that is exactly the discipline handoff
  // 2026-07-29-geneo-arming got wrong in the other direction (it trusted an
  // iteration count and never priced the wall at all).
  std::printf("    %-22s %10lld %10lld %+9.1f%%   <== DETERMINISTIC\n",
              "fine matvecs", off1.fine_matvecs(), on1.fine_matvecs(),
              pct(static_cast<double>(off1.fine_matvecs()),
                  static_cast<double>(on1.fine_matvecs())));
  std::printf("    %-22s %10s %10lld %10s\n", "pre-solve matvecs", "-",
              on1.pre_matvecs, "");
  std::printf("    %-22s %10lld %10lld %+9.1f%%   <== THE ANSWER (det.)\n",
              "CHARGED matvecs", off1.fine_matvecs(),
              on1.fine_matvecs() + on1.pre_matvecs,
              pct(static_cast<double>(off1.fine_matvecs()),
                  static_cast<double>(on1.fine_matvecs() + on1.pre_matvecs)));

  // AC4/AC5 — the full gate table against the control floor.
  std::printf("\n  --- AC4/AC5 FULL GATE TABLE, EVERY RUNG, vs the 1e-9 FLOOR ---\n");
  std::printf("    %-4s %-6s %-19s %-11s %-11s | %-22s | %-22s\n", "rung", "vf",
              "verdict OFF -> ON", "margin OFF", "margin ON",
              "ON vs OFF mean|drho| max", "CTL floor mean|drho| max");
  int flips = 0;
  const std::size_t n = std::min(off1.rungs.size(), on1.rungs.size());
  for (std::size_t i = 0; i < n; ++i) {
    const Delta d_on = compare(off1.rungs[i].density, on1.rungs[i].density);
    const Delta d_ctl = (i < ctl1.rungs.size())
                            ? compare(off1.rungs[i].density, ctl1.rungs[i].density)
                            : Delta();
    const bool flip = off1.rungs[i].accepted != on1.rungs[i].accepted ||
                      off1.rungs[i].infeasible != on1.rungs[i].infeasible;
    if (flip) ++flips;
    std::printf("    %-4zu %-6.2f %-8s -> %-8s%s %-11.6g %-11.6g | %10.3e %10.3e | "
                "%10.3e %10.3e\n",
                i, off1.rungs[i].vf, verdict(off1.rungs[i]), verdict(on1.rungs[i]),
                flip ? " *FLIP*" : "       ", off1.rungs[i].margin,
                on1.rungs[i].margin, d_on.mean_abs, d_on.max_abs,
                d_ctl.mean_abs, d_ctl.max_abs);
  }
  if (off1.rungs.size() != on1.rungs.size()) {
    std::printf("    *** LADDER LENGTH DIFFERS: OFF %zu rungs, ON %zu rungs "
                "(a rung was reached in one posture and not the other) ***\n",
                off1.rungs.size(), on1.rungs.size());
    ++flips;
  }

  std::printf("\n    class/printed flips, and the floor's own count on the same rung:\n");
  for (std::size_t i = 0; i < n; ++i) {
    const Delta d_on = compare(off1.rungs[i].density, on1.rungs[i].density);
    const Delta d_ctl = (i < ctl1.rungs.size())
                            ? compare(off1.rungs[i].density, ctl1.rungs[i].density)
                            : Delta();
    std::printf("    rung %zu (%zu elements): ON class %zu printed %zu | "
                "CTL class %zu printed %zu  => %s\n",
                i, d_on.n, d_on.class_flips, d_on.printed_flips,
                d_ctl.class_flips, d_ctl.printed_flips,
                (d_on.max_abs <= d_ctl.max_abs) ? "AT/BELOW THE FLOOR (noise)"
                                                : "ABOVE THE FLOOR (real)");
  }

  std::printf("\n    --- AC5 CONVERGED COMPLIANCE PER RUNG (a faster run that "
              "lands on a worse design is not a win) ---\n");
  for (std::size_t i = 0; i < n; ++i)
    std::printf("    rung %zu vf=%.2f : OFF %.12g -> ON %.12g  (%+.3f%%)  | "
                "settle iter OFF %d -> ON %d | rung iters OFF %d -> ON %d\n",
                i, off1.rungs[i].vf, off1.rungs[i].compliance,
                on1.rungs[i].compliance,
                pct(off1.rungs[i].compliance, on1.rungs[i].compliance),
                off1.rungs[i].settle_iter, on1.rungs[i].settle_iter,
                off1.rungs[i].iterations, on1.rungs[i].iterations);

  std::printf("\n  VERDICT FLIPS ON THIS FIXTURE: %d %s\n", flips,
              flips ? "*** BLOCKED-STOP ***" : "(none)");

  // CSV for the evidence directory.
  const std::string csv = dir + "/" + name + "_gate.csv";
  if (FILE* fp = std::fopen(csv.c_str(), "w")) {
    std::fprintf(fp, "rung,vf,verdict_off,verdict_on,margin_off,margin_on,"
                     "compliance_off,compliance_on,iters_off,iters_on,"
                     "wall_s_off,wall_s_on,stag_iters_off,stag_iters_on,"
                     "stag_wall_s_off,stag_wall_s_on,settle_off,settle_on,"
                     "on_mean_drho,on_max_drho,ctl_mean_drho,ctl_max_drho,"
                     "on_printed_flips,ctl_printed_flips\n");
    for (std::size_t i = 0; i < n; ++i) {
      const Delta d_on = compare(off1.rungs[i].density, on1.rungs[i].density);
      const Delta d_ctl = (i < ctl1.rungs.size())
                              ? compare(off1.rungs[i].density, ctl1.rungs[i].density)
                              : Delta();
      std::fprintf(fp,
                   "%zu,%.4f,%s,%s,%.12g,%.12g,%.12g,%.12g,%d,%d,%.3f,%.3f,"
                   "%d,%d,%.3f,%.3f,%d,%d,%.6e,%.6e,%.6e,%.6e,%zu,%zu\n",
                   i, off1.rungs[i].vf, verdict(off1.rungs[i]),
                   verdict(on1.rungs[i]), off1.rungs[i].margin,
                   on1.rungs[i].margin, off1.rungs[i].compliance,
                   on1.rungs[i].compliance, off1.rungs[i].iterations,
                   on1.rungs[i].iterations, off1.rungs[i].wall_ms / 1000.0,
                   on1.rungs[i].wall_ms / 1000.0, off1.rungs[i].stagnating_iters,
                   on1.rungs[i].stagnating_iters,
                   off1.rungs[i].stagnating_wall_ms / 1000.0,
                   on1.rungs[i].stagnating_wall_ms / 1000.0,
                   off1.rungs[i].settle_iter, on1.rungs[i].settle_iter,
                   d_on.mean_abs, d_on.max_abs, d_ctl.mean_abs, d_ctl.max_abs,
                   d_on.printed_flips, d_ctl.printed_flips);
    }
    std::fprintf(fp, "# pre_solve_iterations,%d\n# pre_solve_wall_s,%.3f\n"
                     "# pre_solve_matvecs,%lld\n",
                 on1.pre_iterations, on1.pre_ms / 1000.0, on1.pre_matvecs);
    std::fprintf(fp, "# charged_matvecs_off,%lld\n# charged_matvecs_on,%lld\n",
                 off1.fine_matvecs(), on1.fine_matvecs() + on1.pre_matvecs);
    std::fprintf(fp, "# charged_wall_s_off,%.3f\n# charged_wall_s_on,%.3f\n",
                 off_fine / 1000.0, on_charged / 1000.0);
    std::fclose(fp);
    std::printf("  wrote %s\n", csv.c_str());
  }
  return flips;
}

}  // namespace

int main(int argc, char** argv) {
  const std::string mode = argc > 1 ? argv[1] : "stag";
  const std::string dir = evidence_dir();
  SettingsRules rules;
  try {
    rules = load_settings_rules_file(SETTINGS_RULES_PATH);
  } catch (const std::exception& e) {
    std::fprintf(stderr, "FAIL: rules.json: %s\n", e.what());
    return 1;
  }
  const Material material = fdm_material();

  int flips = 0;
  if (mode == "stag" || mode == "all")
    flips += measure("stag", stagnation_fixture(), dir, rules, material);
  if (mode == "healthy" || mode == "all")
    flips += measure("healthy", healthy_fixture(), dir, rules, material);
  if (mode == "nobox" || mode == "all")
    flips += measure("nobox", odd_axis_fixture(), dir, rules, material);

  std::printf("\n==== TOTAL VERDICT FLIPS ACROSS EVERY FIXTURE RUN: %d ====\n",
              flips);
  return 0;
}
