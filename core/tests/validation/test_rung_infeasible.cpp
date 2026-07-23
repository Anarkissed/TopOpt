// Handoff 131 — RUNG-INFEASIBILITY FAST-FAIL.
//
// WHAT THIS GUARDS. A design-box run at 96³ (worker job e5ca9b258a9c4af7,
// 2026-07-22; its iterations.csv is committed verbatim as this test's fixture)
// severed its own structure on rung 2: compliance went 0.6568 -> 1.674e5 in one
// step and stayed there, flat to six significant figures, with ~43-44k CG
// iterations per solve, for all 31 iterations of that rung at ~9 minutes each.
// The corpse was then ACCEPTED (margin 680.9 — a structure that carries nothing
// has no stress) and exported as variant_038.stl, and rung 3 inherited it as its
// warm start and ground 27 more iterations at the same dead objective. ~8.5 hours
// spent optimizing a load path that no longer existed.
//
// The fix is a deterministic predicate over quantities the run already logs
// (simp.hpp rung_infeasible) plus the driver's response to it. This test proves
// five things, in order:
//
//   1. DETECTION, against the REAL trajectory at PRODUCTION thresholds: the
//      broken rung is caught at iteration 6 of 31.
//   2. NO FALSE POSITIVE on the same run's healthy rungs, and none on the rung
//      that inherited the corpse (which is exactly why inheritance must skip it).
//   3. NO FALSE POSITIVE on a LIVE violent forming transient — a low-vf rung that
//      runs far above its start with a big CG blow-up and then recovers. This is
//      not hypothetical: it is what a 24x5x6 cantilever at vf 0.03 actually does,
//      and an earlier two-conjunct version of the predicate killed it.
//   4. THE DRIVER'S RESPONSE: an infeasible rung is ended, never accepted, never
//      analysed, reported with its reason — and the ladder CONTINUES with the next
//      rung seeded from the last FEASIBLE field, never from the corpse.
//   5. BYTE-IDENTITY (THE ONE RULE): on a run where the signature never occurs,
//      arming the detector changes nothing at all.
//
// Eigen-gated in CMake like the other optimizer tests; the real settings table and
// the fixture CSV are injected by absolute path. No third-party framework — the
// same self-contained CHECK harness as its neighbours, public API only.

#include "topopt/fea.hpp"
#include "topopt/materials.hpp"
#include "topopt/pipeline.hpp"
#include "topopt/report.hpp"
#include "topopt/settings.hpp"
#include "topopt/simp.hpp"
#include "topopt/voxel.hpp"

#include <algorithm>
#include <cmath>
#include <cstddef>
#include <cstdio>
#include <fstream>
#include <limits>
#include <map>
#include <sstream>
#include <string>
#include <vector>

using topopt::DirichletBC;
using topopt::Material;
using topopt::MinimizePlasticOptions;
using topopt::MinimizePlasticResult;
using topopt::MinimizePlasticVariant;
using topopt::SettingsRules;
using topopt::SimpUpdater;
using topopt::Vec3;
using topopt::VoxelGrid;
using topopt::VoxelTag;
using topopt::rung_infeasible;

static int g_failures = 0;
static int g_checks = 0;

#define CHECK(cond, msg)                                           \
  do {                                                             \
    ++g_checks;                                                    \
    if (!(cond)) {                                                 \
      ++g_failures;                                                \
      std::fprintf(stderr, "FAIL (line %d): %s\n", __LINE__, msg); \
    }                                                              \
  } while (0)

namespace {

// The PRODUCTION thresholds (SimpOptions defaults). Groups 1-3 assert against
// these exact numbers, so a future retune must come back through this test.
constexpr double kRatio = 100.0;
constexpr double kBlowup = 4.0;
constexpr double kFlatTol = 1e-3;
constexpr int kWindow = 5;

// --- The committed real-run fixture --------------------------------------
// One rung's recorded per-iteration trajectory: the two columns the predicate
// consumes, in iteration order.
struct RungTrace {
  std::vector<double> compliance;
  std::vector<int> cg;
};

// Parse the committed iterations.csv (the schema in observability.hpp) into one
// trace per rung. Reads only the columns it needs, by header name, so a later
// column addition cannot silently shift what this test measures.
std::map<int, RungTrace> load_iteration_csv(const std::string& path) {
  std::ifstream in(path);
  if (!in) {
    std::fprintf(stderr, "FATAL: cannot open fixture %s\n", path.c_str());
    return {};
  }
  std::string line;
  if (!std::getline(in, line)) return {};
  std::vector<std::string> header;
  {
    std::stringstream hs(line);
    std::string col;
    while (std::getline(hs, col, ',')) header.push_back(col);
  }
  auto col_index = [&](const char* name) {
    for (std::size_t i = 0; i < header.size(); ++i)
      if (header[i] == name) return static_cast<int>(i);
    return -1;
  };
  const int i_rung = col_index("rung");
  const int i_comp = col_index("compliance");
  const int i_cg = col_index("cg_iters");
  if (i_rung < 0 || i_comp < 0 || i_cg < 0) {
    std::fprintf(stderr, "FATAL: fixture %s is missing a required column\n",
                 path.c_str());
    return {};
  }
  std::map<int, RungTrace> out;
  while (std::getline(in, line)) {
    if (line.empty()) continue;
    std::vector<std::string> f;
    std::stringstream ls(line);
    std::string cell;
    while (std::getline(ls, cell, ',')) f.push_back(cell);
    const int need = std::max(i_rung, std::max(i_comp, i_cg));
    if (static_cast<int>(f.size()) <= need) continue;
    RungTrace& t = out[std::stoi(f[static_cast<std::size_t>(i_rung)])];
    t.compliance.push_back(std::stod(f[static_cast<std::size_t>(i_comp)]));
    t.cg.push_back(std::stoi(f[static_cast<std::size_t>(i_cg)]));
  }
  return out;
}

// The 1-based iteration the predicate FIRST fires on when replayed prefix by
// prefix over a recorded trace, or -1 if it never fires. This is exactly how the
// live loop consumes it (one verdict per completed iteration).
int first_fire(const RungTrace& t, double ratio, double blowup, double flat,
               int window) {
  for (std::size_t n = 1; n <= t.compliance.size(); ++n) {
    const std::vector<double> c(t.compliance.begin(), t.compliance.begin() + n);
    const std::vector<int> g(t.cg.begin(), t.cg.begin() + n);
    if (rung_infeasible(c, g, ratio, blowup, flat, window))
      return static_cast<int>(n);
  }
  return -1;
}

// --- The live fixture -----------------------------------------------------
// A cantilever bar clamped and Fixture-tagged at i == 0 and Load-tagged at
// i == nx-1, pulled down at the far face. Both tagged faces are implicitly
// FrozenSolid (M1.6), so the design region between them is the only load path —
// the same topology as the production case, where a frozen skin brackets an
// active region. Small on purpose: 24 x 5 x 6.
VoxelGrid cantilever_bar(std::vector<DirichletBC>& bcs) {
  const int nx = 24, ny = 5, nz = 6;
  VoxelGrid g;
  g.nx = nx;
  g.ny = ny;
  g.nz = nz;
  g.spacing = 2.0;
  g.origin = Vec3{0.0, 0.0, 0.0};
  g.tags.assign(static_cast<std::size_t>(nx) * ny * nz, VoxelTag::Interior);
  for (int k = 0; k < nz; ++k)
    for (int j = 0; j < ny; ++j) {
      g.set_tag(0, j, k, VoxelTag::Fixture);
      g.set_tag(nx - 1, j, k, VoxelTag::Load);
    }
  bcs.clear();
  for (int c = 0; c <= nz; ++c)
    for (int b = 0; b <= ny; ++b) {
      const int n = topopt::fea_node_index(g, 0, b, c);
      bcs.push_back({n, 0, 0.0});
      bcs.push_back({n, 1, 0.0});
      bcs.push_back({n, 2, 0.0});
    }
  return g;
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

// The shared run configuration. `margin_stop = 0` accepts every rung that is
// analysed at all, so nothing but infeasibility can end the ladder early and the
// scenarios below measure exactly what they mean to. Warm-start inheritance is ON —
// it is the mechanism the corpse propagated through in the real run.
MinimizePlasticOptions base_options(const VoxelGrid& g) {
  MinimizePlasticOptions o;
  o.margin_stop = 0.0;
  o.gravity = 9810.0;
  o.gravity_direction = Vec3{0, 0, -1};
  o.warm_start_inherit = true;
  o.updater = SimpUpdater::MMA;
  o.simp.filter_radius = 1.5;
  o.simp.move = 0.2;
  o.simp.max_iterations = 40;
  o.simp.change_tol = 0.0;
  o.simp.cg_tolerance = 1e-8;
  // A generous CG cap so a non-convergence THROW can never preempt the honest
  // verdict — the production regime, where the cap is ~2 * 10^6 DOF, in miniature.
  o.simp.cg_max_iterations = 500000;
  for (int k = 0; k < g.nz; ++k)
    for (int j = 0; j < g.ny; ++j)
      o.external_loads.push_back({topopt::fea_node_index(g, g.nx, j, k), 2, -50.0});
  return o;
}

}  // namespace

int main() {
  // =========================================================================
  // 1 + 2. THE REAL 96³ TRAJECTORY, AT PRODUCTION THRESHOLDS.
  // =========================================================================
  {
    const std::map<int, RungTrace> traces =
        load_iteration_csv(std::string(INFEASIBLE_FIXTURE_DIR) +
                           "/iterations_96_designbox.csv");
    CHECK(traces.size() == 4, "fixture: the real run recorded 4 rungs");

    // Rung 0 (10.64 -> 1.67e-3 over 146 iterations) and rung 1 (1.37e-2 ->
    // 3.70e-3 over 45) are healthy descents. Neither may fire, ever.
    for (int r : {0, 1}) {
      const auto it = traces.find(r);
      if (it == traces.end()) { CHECK(false, "fixture: healthy rung present"); continue; }
      const int fire = first_fire(it->second, kRatio, kBlowup, kFlatTol, kWindow);
      CHECK(fire < 0, "real run: a HEALTHY rung never fires at production thresholds");
      std::printf("[real] rung %d: %zu iters, c %.6g -> %.6g, cg %d..%d — fire=%d\n",
                  r, it->second.compliance.size(), it->second.compliance.front(),
                  it->second.compliance.back(),
                  *std::min_element(it->second.cg.begin(), it->second.cg.end()),
                  *std::max_element(it->second.cg.begin(), it->second.cg.end()),
                  fire);
    }

    // Rung 2 is THE CORPSE. It must be caught, and caught EARLY: the earliest a
    // window+1 verdict is possible is iteration 6, and that is where it lands —
    // 25 iterations (~3.75 h at the measured ~9 min/iter) before the rung ended,
    // and 25 before the objective-plateau detector noticed at iteration 31.
    {
      const RungTrace& t = traces.at(2);
      const int fire = first_fire(t, kRatio, kBlowup, kFlatTol, kWindow);
      CHECK(fire == kWindow + 1,
            "real run: the SEVERED rung fires at the earliest possible iteration (6)");
      CHECK(static_cast<int>(t.compliance.size()) == 31,
            "fixture: the severed rung actually ran 31 iterations");
      std::printf("[real] rung 2 (severed): c[0]=%.6g -> %.6g (%.4gx), cg %d -> %d — "
                  "fire=%d of %zu iterations run\n",
                  t.compliance[0], t.compliance[1],
                  t.compliance[1] / t.compliance[0], t.cg[0], t.cg[1], fire,
                  t.compliance.size());

      // Each conjunct is load-bearing on this very trace: disarm any one of them
      // (by making its threshold unreachable) and the verdict must disappear.
      CHECK(first_fire(t, 1e9, kBlowup, kFlatTol, kWindow) < 0,
            "conjunct (1): an unreachable compliance ratio suppresses the verdict");
      CHECK(first_fire(t, kRatio, 1e9, kFlatTol, kWindow) < 0,
            "conjunct (2): an unreachable CG blow-up suppresses the verdict");
      CHECK(first_fire(t, kRatio, kBlowup, 0.0, kWindow) < 0,
            "conjunct (3): a zero flatness tolerance suppresses the verdict");
      CHECK(first_fire(t, kRatio, kBlowup, kFlatTol, 0) < 0,
            "window <= 0 DISARMS the detector entirely");
    }

    // Rung 3 is the rung that INHERITED the corpse. It ran 27 iterations at the
    // same dead objective — and the predicate CANNOT see it, because its own
    // starting compliance is already the dead value, so nothing is ever 100x
    // above it. This is the measurement behind the inheritance rule: not
    // inheriting a corpse is what keeps the NEXT rung detectable at all.
    {
      const RungTrace& t = traces.at(3);
      CHECK(first_fire(t, kRatio, kBlowup, kFlatTol, kWindow) < 0,
            "real run: a corpse-SEEDED rung is undetectable (start is already dead)");
      CHECK(t.compliance.front() > 1e5,
            "real run: the corpse-seeded rung started at the dead objective");
      std::printf("[real] rung 3 (corpse-seeded): starts at %.6g — undetectable, "
                  "%zu iterations wasted\n",
                  t.compliance.front(), t.compliance.size());
    }
  }

  // =========================================================================
  // 3. PURE-PREDICATE GUARDS on hand-built curves (no solve).
  // =========================================================================
  {
    const std::vector<double> flat_high(12, 1000.0);
    const std::vector<int> big_cg(12, 40000);
    std::vector<double> c = flat_high;
    std::vector<int> g = big_cg;
    c[0] = 1.0;   // start low -> the rest is 1000x above it
    g[0] = 1000;  // cheap first solve -> the rest is 40x above it
    CHECK(rung_infeasible(c, g, kRatio, kBlowup, kFlatTol, kWindow),
          "guard: a flat, 1000x, CG-blown curve fires");

    CHECK(!rung_infeasible({}, {}, kRatio, kBlowup, kFlatTol, kWindow),
          "guard: an empty history never fires");
    {
      const std::vector<double> c5(c.begin(), c.begin() + kWindow);
      const std::vector<int> g5(g.begin(), g.begin() + kWindow);
      CHECK(!rung_infeasible(c5, g5, kRatio, kBlowup, kFlatTol, kWindow),
            "guard: fewer than window+1 samples never fires (no baseline)");
    }
    {
      const std::vector<double> c6(c.begin(), c.begin() + kWindow + 1);
      const std::vector<int> g6(g.begin(), g.begin() + kWindow + 1);
      CHECK(rung_infeasible(c6, g6, kRatio, kBlowup, kFlatTol, kWindow),
            "guard: exactly window+1 samples is the earliest verdict");
    }
    {
      std::vector<double> mismatch(c.begin(), c.end() - 1);
      CHECK(!rung_infeasible(mismatch, g, kRatio, kBlowup, kFlatTol, kWindow),
            "guard: mismatched history lengths never fire");
    }
    {
      // ONE recovering iteration inside the window clears the verdict.
      std::vector<double> dip = c;
      dip[dip.size() - 3] = 50.0;
      CHECK(!rung_infeasible(dip, g, kRatio, kBlowup, kFlatTol, kWindow),
            "guard: a single sub-threshold iteration in the window clears it");
    }
    {
      // A monotone descent — the healthy shape — never fires however long.
      std::vector<double> desc;
      std::vector<int> cgd;
      double v = 1e6;
      for (int i = 0; i < 60; ++i) { desc.push_back(v); cgd.push_back(500); v *= 0.9; }
      CHECK(!rung_infeasible(desc, cgd, kRatio, kBlowup, kFlatTol, kWindow),
            "guard: a steadily descending curve never fires");
    }
    {
      // CONVERGENCE is flat too — but flat BELOW the start, so (1) blocks it.
      std::vector<double> conv(40, 1.0);
      std::vector<int> cgc(40, 500);
      conv[0] = 1e6;
      CHECK(!rung_infeasible(conv, cgc, kRatio, kBlowup, kFlatTol, kWindow),
            "guard: an ordinary converged plateau below the start never fires");
    }
    {
      // A non-finite objective is not a verdict this predicate makes.
      std::vector<double> nan_tail = c;
      nan_tail.back() = std::numeric_limits<double>::quiet_NaN();
      CHECK(!rung_infeasible(nan_tail, g, kRatio, kBlowup, kFlatTol, kWindow),
            "guard: a non-finite compliance never fires");
    }
  }

  const SettingsRules rules =
      topopt::load_settings_rules_file(SETTINGS_RULES_PATH);
  const Material mat = fdm_material();

  // =========================================================================
  // 4. LIVE FALSE-POSITIVE GUARD + BYTE-IDENTITY (THE ONE RULE).
  //
  // Ladder {0.6, 0.03} on the bar. Rung 1's forming phase is violent: measured,
  // it runs to ~8770x its own starting compliance with CG up 14x — clearing
  // conjuncts (1) and (2) outright — and then RECOVERS to below where it started.
  // The detector must NOT fire on it, and the whole run must be bit-for-bit what
  // it is with the detector disarmed.
  // =========================================================================
  {
    std::vector<DirichletBC> bcs;
    const VoxelGrid g = cantilever_bar(bcs);

    MinimizePlasticOptions armed = base_options(g);
    armed.volume_fraction_ladder = {0.6, 0.03};
    // (production defaults for the four infeasibility knobs — asserted, not assumed)
    CHECK(armed.simp.infeasible_compliance_ratio == kRatio &&
              armed.simp.infeasible_cg_blowup == kBlowup &&
              armed.simp.infeasible_flat_tol == kFlatTol &&
              armed.simp.infeasible_window == kWindow,
          "defaults: the detector ships ARMED at the calibrated thresholds");

    MinimizePlasticOptions disarmed = armed;
    disarmed.simp.infeasible_window = 0;  // the exact pre-131 predicate

    // Watch rung 1's trajectory so the guard reports what it actually survived.
    double peak_ratio = 0.0;
    double peak_cg_ratio = 0.0;
    double c0 = 0.0;
    int cg0 = 0;
    armed.on_iteration = [&](std::size_t rung, std::size_t,
                             const topopt::SimpIterationObservation& o) {
      if (rung != 1) return;
      if (o.iteration == 1) { c0 = o.compliance; cg0 = o.cg_iterations; }
      if (c0 > 0.0) peak_ratio = std::max(peak_ratio, o.compliance / c0);
      if (cg0 > 0)
        peak_cg_ratio =
            std::max(peak_cg_ratio, static_cast<double>(o.cg_iterations) / cg0);
    };

    const MinimizePlasticResult ra =
        minimize_plastic(g, mat, "PLA", bcs, rules, armed);
    const MinimizePlasticResult rd =
        minimize_plastic(g, mat, "PLA", bcs, rules, disarmed);

    std::printf("[transient] rung 1 peaked at %.4gx its start compliance with a "
                "%.3gx CG blow-up — and was NOT killed\n",
                peak_ratio, peak_cg_ratio);
    CHECK(peak_ratio > kRatio,
          "transient: the forming phase really does exceed the compliance conjunct");
    CHECK(peak_cg_ratio > kBlowup,
          "transient: the forming phase really does exceed the CG conjunct");

    for (const MinimizePlasticVariant& v : ra.evaluated)
      CHECK(!v.infeasible,
            "ONE RULE: no rung of the healthy/transient run is called infeasible");
    for (char f : ra.rung_infeasible)
      CHECK(f == 0, "ONE RULE: rung_infeasible reads all-zero on a healthy run");
    CHECK(ra.rung_infeasible.size() == ra.evaluated.size(),
          "rung_infeasible has exactly one entry per evaluated rung");
    CHECK(ra.report.rejected.empty(),
          "ONE RULE: nothing is rejected on the healthy run");

    // BYTE-IDENTITY: armed vs disarmed, same rungs, same iteration counts, and the
    // same designs bit-for-bit.
    CHECK(ra.evaluated.size() == rd.evaluated.size(),
          "ONE RULE: arming the detector does not change the rungs evaluated");
    bool identical = ra.evaluated.size() == rd.evaluated.size();
    for (std::size_t i = 0; identical && i < ra.evaluated.size(); ++i) {
      identical = ra.evaluated[i].optimization.iterations ==
                      rd.evaluated[i].optimization.iterations &&
                  ra.evaluated[i].optimization.physical_density ==
                      rd.evaluated[i].optimization.physical_density &&
                  ra.evaluated[i].optimization.compliance ==
                      rd.evaluated[i].optimization.compliance;
    }
    CHECK(identical,
          "ONE RULE: a run where the signature never occurs is BYTE-IDENTICAL "
          "with the detector armed and disarmed");
    std::printf("[one rule] %zu rungs, armed == disarmed bit-for-bit: %s\n",
                ra.evaluated.size(), identical ? "yes" : "NO");
  }

  // =========================================================================
  // 5. THE DRIVER'S RESPONSE, and the INHERITANCE RULE.
  //
  // Ladder {0.6, 0.001, 0.0005}: rungs 1 and 2 target the density floor, so their
  // design region cannot hold a load path at all and the objective sits frozen —
  // the signature, at this fixture's scale.
  //
  // SCALED THRESHOLDS, stated plainly. This 24x5x6 collapse is UNIFORM (every
  // design voxel at density_min), and a uniformly scaled operator is no worse
  // conditioned than a solid one — so CG does NOT blow up here the way it does on
  // the production grid's mixed frozen/collapsed field. The compliance conjuncts
  // are met (ratio ~3, spread ~3e-5); the CG conjunct is relaxed to 0.5 so it does
  // not veto. That relaxation is confined to THIS scenario: the production
  // calibration is proven on the real 96³ trajectory in group 1, not here. The
  // compliance ratio is still discriminating at this scale — rung 0 descends and
  // never approaches 2x its start — so the scenario cannot pass by firing on
  // everything.
  // =========================================================================
  {
    std::vector<DirichletBC> bcs;
    const VoxelGrid g = cantilever_bar(bcs);

    MinimizePlasticOptions o = base_options(g);
    o.simp.infeasible_compliance_ratio = 2.0;
    o.simp.infeasible_cg_blowup = 0.5;
    o.simp.infeasible_flat_tol = kFlatTol;   // production value: unrelaxed
    o.simp.infeasible_window = kWindow;      // production value: unrelaxed

    MinimizePlasticOptions three = o;
    three.volume_fraction_ladder = {0.6, 0.001, 0.0005};
    // First recorded compliance per rung — the baseline the predicate forms its
    // ratio against. Needed to show WHY the third rung is a blind spot.
    std::vector<double> rung_start_c(3, 0.0);
    three.on_iteration = [&](std::size_t rung, std::size_t,
                             const topopt::SimpIterationObservation& ob) {
      if (ob.iteration == 1 && rung < rung_start_c.size())
        rung_start_c[rung] = ob.compliance;
    };
    const MinimizePlasticResult r3 =
        minimize_plastic(g, mat, "PLA", bcs, rules, three);

    CHECK(r3.evaluated.size() == 3,
          "driver: an infeasible rung does NOT stop the ladder");
    CHECK(!r3.stopped_on_margin && !r3.cancelled,
          "driver: infeasibility is neither a margin stop nor a cancel");

    CHECK(!r3.evaluated[0].infeasible && r3.evaluated[0].accepted,
          "driver: the healthy heavy rung is unaffected and accepted");
    CHECK(r3.rung_infeasible.size() == 3 && r3.rung_infeasible[0] == 0,
          "driver: rung_infeasible mirrors the per-rung verdicts");

    {
      const MinimizePlasticVariant& v = r3.evaluated[1];
      CHECK(v.infeasible, "driver: the collapsed rung is flagged infeasible");
      CHECK(r3.rung_infeasible[1] == 1, "driver: run-level echo agrees per rung");
      CHECK(!v.accepted, "driver: an infeasible rung is NEVER accepted");
      CHECK(v.optimization.infeasible, "driver: the optimizer ended it, not the driver");
      CHECK(!v.optimization.converged, "driver: an infeasible rung never 'converged'");
      CHECK(v.optimization.infeasible_iteration == kWindow + 1,
            "driver: it ended at the earliest possible iteration");
      CHECK(v.optimization.iterations == kWindow + 1,
            "driver: and ran no iterations past it (fast FAIL)");
      // The analysis was SKIPPED — this is what stops a corpse being certified.
      CHECK(v.von_mises_field.empty() && v.displacement_field.empty() &&
                v.mesh().triangles.empty(),
            "driver: an infeasible rung is NOT analysed (no stress, no mesh)");
      CHECK(v.report.margin.worst_case == 0.0 && v.report.max_stress_mpa == 0.0,
            "driver: no fabricated margin is reported for it");
      CHECK(v.report.rejection_reason == std::string(topopt::kRungInfeasibleReason),
            "driver: the report line carries the honest reason");
      std::printf("[driver] rung 1: infeasible at iteration %d, reason \"%s\"\n",
                  v.optimization.infeasible_iteration,
                  v.report.rejection_reason.c_str());
    }

    // THE BLIND SPOT, stated as a test rather than left to be discovered. The
    // predicate is relative to THE RUNG'S OWN starting compliance, so it cannot see
    // a rung that is ALREADY dead at iteration 1 — nothing is ever 100x above a
    // value that is itself the dead one. Rung 2 here is exactly that: its target
    // 0.0005 is below density_min, so rescaling ANY seed to it lands the whole
    // design region on the floor before the first solve. (This is also why the real
    // run's rung 3 was undetectable — group 1 — and it is precisely the case the
    // inheritance rule exists to stop the ladder MANUFACTURING.) The honest fix for
    // a rung whose target collapses to the density floor is upstream, at the point
    // that target is computed; it is not this predicate's job and is not claimed.
    CHECK(!r3.evaluated[2].infeasible && r3.rung_infeasible[2] == 0,
          "blind spot: a rung born dead is NOT detected (documented limitation)");
    CHECK(rung_start_c[2] >= 0.5 * rung_start_c[1],
          "blind spot: ...because its own starting compliance is already dead");
    std::printf("[blind spot] rung starts: %.4g, %.4g, %.4g — rung 2 begins at the "
                "dead level, so no ratio to its own start can fire\n",
                rung_start_c[0], rung_start_c[1], rung_start_c[2]);

    // It is REPORTED, not silently dropped — and the report still validates.
    CHECK(r3.report.rejected.size() == 1,
          "report: the infeasible rung appears in rejected_variants");
    for (const topopt::VariantReport& vr : r3.report.rejected) {
      CHECK(!vr.accepted, "report: a rejected line declares accepted=false");
      CHECK(vr.rejection_reason == std::string(topopt::kRungInfeasibleReason),
            "report: with the infeasibility reason");
    }
    {
      bool valid = true;
      std::string json;
      try {
        json = topopt::job_report_json(r3.report);
        topopt::validate_job_report_json(json);
      } catch (const std::exception&) {
        valid = false;
      }
      CHECK(valid, "report: the assembled JobReport still validates");
      CHECK(json.find(topopt::kRungInfeasibleReason) != std::string::npos,
            "report: the reason survives into report.json");
    }

    // THE INHERITANCE RULE, proven by construction. Rung 2 above followed an
    // INFEASIBLE rung 1. If the corpse had seeded it, its result would depend on
    // rung 1. So run the SAME ladder with rung 1 REMOVED — {0.6, 0.0005} — where
    // the 0.0005 rung is provably seeded by rung 0. Everything else is identical,
    // and the optimizer is deterministic, so the two must agree bit-for-bit iff
    // the seed skipped the corpse and came from the last FEASIBLE rung.
    MinimizePlasticOptions two = o;
    two.volume_fraction_ladder = {0.6, 0.0005};
    const MinimizePlasticResult r2 =
        minimize_plastic(g, mat, "PLA", bcs, rules, two);

    CHECK(r2.evaluated.size() == 2, "inheritance: the control run evaluated 2 rungs");
    const bool same_seed_result =
        r3.evaluated.size() == 3 && r2.evaluated.size() == 2 &&
        r3.evaluated[2].optimization.iterations ==
            r2.evaluated[1].optimization.iterations &&
        r3.evaluated[2].optimization.physical_density ==
            r2.evaluated[1].optimization.physical_density &&
        r3.evaluated[2].optimization.compliance ==
            r2.evaluated[1].optimization.compliance;
    CHECK(same_seed_result,
          "INHERITANCE: the rung after an infeasible one is bit-for-bit the rung "
          "that follows the last FEASIBLE rung directly — the corpse seeded nothing");
    // ...and the corpse really was a different field, so the check above has teeth.
    CHECK(r3.evaluated[1].optimization.physical_density !=
              r3.evaluated[0].optimization.physical_density,
          "inheritance: the skipped corpse is genuinely a different field");
    std::printf("[inheritance] rung-after-corpse == rung-after-last-feasible: %s\n",
                same_seed_result ? "yes" : "NO");
  }

  if (g_failures == 0) {
    std::printf("rung_infeasible: all %d checks passed\n", g_checks);
    return 0;
  }
  std::fprintf(stderr, "rung_infeasible: %d/%d checks FAILED\n", g_failures,
               g_checks);
  return 1;
}
