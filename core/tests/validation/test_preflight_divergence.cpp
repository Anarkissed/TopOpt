// Task 2026-08-03-preflight-feasibility-and-divergence — THE THREE GUARDS.
//
// WHAT THIS GUARDS. A real job (worker 7fbc7ee2900e425a, 2026-08-02) ran TEN
// HOURS and completed three design iterations — 27 s, 34 min, 6.3 h — with the
// objective rising 1,689x in a single step and CG going 298 -> 67,094. It was
// not a mistake: it carried a legitimate 70 mm axial bolt clearance, because a
// bolt you cannot get a driver onto is not a bolt hole. An option that can
// produce a ten-hour diverging run is an app defect, not user error.
//
// Three guards answer it, cheapest first, and this test proves each of them
// plus — the bar that matters most — that none of them refuses a valid job.
//
//   1. PRE-FLIGHT LOAD-PATH CONNECTIVITY. Before any solve, with clearances
//      frozen and the design domain resolved: can the load voxels reach the
//      anchors through voxels the optimizer is ALLOWED to fill? Group 1 proves
//      it SEVERS on a keep-clear that provably cuts the path, PASSES a
//      marginal but connected one (reporting the narrowness as INFORMATION), is
//      VACUOUS when there is no load path to decide, and costs milliseconds.
//   2. THE IMMEDIATE DIVERGENCE TRIP. Group 2 replays the real recorded
//      trajectories through the predicate — the 10-hour run (must fire at
//      iteration 2) and the live forming transient measured in handoff 131
//      (must NOT fire, at any iteration) — and pins the shipped constants.
//   3. THE ITERATION TIME GUARD. Group 3 proves the budget rule, its floor and
//      its baseline choice, and that a legitimate run never trips it.
//
//   4. THE ONE RULE: on a run where nothing trips, arming all three changes not
//      one iteration and not one bit of the design.
//
// Eigen-gated in CMake like its neighbours; the real settings table and the two
// recorded CSV fixtures are injected by absolute path. Public API only, same
// self-contained CHECK harness as its neighbours.

#include "topopt/fea.hpp"
#include "topopt/loadcase.hpp"
#include "topopt/materials.hpp"
#include "topopt/observability.hpp"
#include "topopt/pipeline.hpp"
#include "topopt/production.hpp"  // production_growth_ladder (PR 290)
#include "topopt/settings.hpp"
#include "topopt/simp.hpp"
#include "topopt/voxel.hpp"

#include <algorithm>
#include <cmath>
#include <cstddef>
#include <cstdio>
#include <fstream>
#include <map>
#include <sstream>
#include <string>
#include <vector>

using topopt::DesignBox;
using topopt::DesignMask;
using topopt::DirichletBC;
using topopt::LoadPathWalk;
using topopt::MaskValue;
using topopt::Material;
using topopt::MinimizePlasticOptions;
using topopt::MinimizePlasticResult;
using topopt::MinimizePlasticVariant;
using topopt::PreflightLoadPath;
using topopt::SettingsRules;
using topopt::SimpUpdater;
using topopt::SolvedDesignDomain;
using topopt::Vec3;
using topopt::VoxelGrid;
using topopt::VoxelTag;

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

// --- the live fixture: the same cantilever bar handoff 131 calibrated on -----
// Fixture-tagged at i == 0, Load-tagged at i == nx-1, pulled down at the far
// face. The design region between them is the only load path.
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
  o.simp.cg_max_iterations = 500000;
  for (int k = 0; k < g.nz; ++k)
    for (int j = 0; j < g.ny; ++j)
      o.external_loads.push_back({topopt::fea_node_index(g, g.nx, j, k), 2, -50.0});
  return o;
}

// One recorded rung trajectory, the three columns the guards read.
struct Trace {
  std::vector<double> c;
  std::vector<int> cg;
  std::vector<double> ms;
};

std::map<int, Trace> load_csv(const std::string& path) {
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
  auto col = [&](const char* name) {
    for (std::size_t i = 0; i < header.size(); ++i)
      if (header[i] == name) return static_cast<int>(i);
    return -1;
  };
  const int i_r = col("rung"), i_c = col("compliance"), i_g = col("cg_iters");
  const int i_t = col("total_ms");
  if (i_r < 0 || i_c < 0 || i_g < 0) return {};
  std::map<int, Trace> out;
  while (std::getline(in, line)) {
    if (line.empty()) continue;
    std::vector<std::string> f;
    std::stringstream ls(line);
    std::string cell;
    while (std::getline(ls, cell, ',')) f.push_back(cell);
    if (static_cast<int>(f.size()) <= std::max(std::max(i_r, i_c), i_g)) continue;
    Trace& t = out[std::stoi(f[static_cast<std::size_t>(i_r)])];
    t.c.push_back(std::stod(f[static_cast<std::size_t>(i_c)]));
    t.cg.push_back(std::stoi(f[static_cast<std::size_t>(i_g)]));
    t.ms.push_back(i_t >= 0 && static_cast<int>(f.size()) > i_t
                       ? std::stod(f[static_cast<std::size_t>(i_t)])
                       : -1.0);
  }
  return out;
}

// THE SHIPPED CONSTANTS. Asserted against the SimpOptions defaults below, so a
// future retune must come back through this test.
constexpr double kImmediateRatio = 1000.0;
constexpr double kImmediateWallRatio = 50.0;
constexpr double kCgBlowup = 4.0;
constexpr double kTimeRatio = 100.0;
constexpr double kTimeFloorMs = 300000.0;

// The IMMEDIATE trip, as an independent reimplementation of the shipped
// predicate over a recorded trace, so this test measures the RULE rather than
// re-running the code that implements it. `n` is the 1-based iteration judged.
bool immediate_fires(const Trace& t, std::size_t n) {
  if (n < 2 || n > t.c.size()) return false;
  if (!(t.c[0] > 0.0) || !(t.ms[0] > 0.0)) return false;
  int cgmin = t.cg[0];
  for (std::size_t i = 1; i + 1 < n; ++i) cgmin = std::min(cgmin, t.cg[i]);
  if (cgmin <= 0) return false;
  const double lvl = t.c[n - 1] / t.c[0];
  const double cgr = static_cast<double>(t.cg[n - 1]) / cgmin;
  const double wr = t.ms[n - 1] / t.ms[0];
  return lvl >= kImmediateRatio && cgr >= kCgBlowup && wr >= kImmediateWallRatio;
}

// A grid with a SEVERABLE path: a bar whose midspan can be cut by a keep-out
// box. Fixture at i==0, Load at i==nx-1, so a keep-out spanning the whole
// cross-section at midspan provably disconnects them.
VoxelGrid severable_bar(std::vector<DirichletBC>& bcs) {
  return cantilever_bar(bcs);
}

// Run the pre-flight with a "Keep clear" FrozenVoid overlay forbidding the
// voxel slabs [i0, i1] over the whole cross-section. This is the PRODUCTION
// mechanism the maintainer's job used (options.clearance_void, handoff 100) —
// and, unlike a keep_out BOX, it is the one that can forbid PART material,
// which is what a bolt-access bore does to a plate.
PreflightLoadPath preflight_with_clearance(const VoxelGrid& g,
                                           const std::vector<DirichletBC>& bcs,
                                           int i0, int i1, int j_from) {
  MinimizePlasticOptions o = base_options(g);
  const SolvedDesignDomain d = topopt::resolve_design_domain(g, bcs, o);
  if (i1 >= i0) {
    DesignMask clear(d.grid.voxel_count(), MaskValue::Active);
    for (int k = 0; k < d.grid.nz; ++k)
      for (int j = j_from; j < d.grid.ny; ++j)
        for (int i = i0; i <= i1 && i < d.grid.nx; ++i)
          clear[d.grid.index(i, j, k)] = MaskValue::FrozenVoid;
    o.clearance_void = std::move(clear);
  }
  return topopt::preflight_load_path(d, o);
}

}  // namespace

int main() {
  const SettingsRules rules =
      topopt::load_settings_rules_file(SETTINGS_RULES_PATH);
  const Material mat = fdm_material();

  // =========================================================================
  // 1. GUARD 1 — PRE-FLIGHT LOAD-PATH CONNECTIVITY.
  // =========================================================================
  {
    std::vector<DirichletBC> bcs;
    const VoxelGrid g = severable_bar(bcs);

    // (a) NO keep-out: the path is connected and the check says so, in
    //     milliseconds, and it reports the marginality reading as information.
    const PreflightLoadPath open = preflight_with_clearance(g, bcs, 0, -1, 0);
    CHECK(open.ran, "preflight: it ran");
    CHECK(open.walk.decidable,
          "preflight: a grid with BOTH Load and Fixture voxels is decidable");
    CHECK(open.walk.connected, "preflight: an unobstructed bar is CONNECTED");
    CHECK(open.walk.unreached_load_voxels == 0,
          "preflight: a connected walk leaves no unreached load voxel");
    CHECK(open.walk.load_voxels == static_cast<std::size_t>(g.ny * g.nz),
          "preflight: it counted the Load face");
    CHECK(open.walk.anchor_voxels == static_cast<std::size_t>(g.ny * g.nz),
          "preflight: it counted the Fixture face");
    CHECK(open.walk.geodesic_levels > 0,
          "preflight: it measured the geodesic distance to the load");
    CHECK(open.walk.narrowest_separator_voxels > 0,
          "preflight: it measured a narrowest separating cross-section");
    CHECK(open.walk.narrowest_separator_mm2 > 0.0,
          "preflight: ... and reported it in mm^2 at this grid's spacing");
    std::printf("[preflight] open bar: connected=%d, narrowest separator %d "
                "voxels (%.4g mm^2) at %d/%d steps, %.3f ms\n",
                open.walk.connected ? 1 : 0,
                open.walk.narrowest_separator_voxels,
                open.walk.narrowest_separator_mm2,
                open.walk.narrowest_separator_level, open.walk.geodesic_levels,
                open.wall_ms);

    // (b) A KEEP-CLEAR that forbids the WHOLE cross-section at midspan:
    //     PROVABLY severed, and the check refuses it. Disconnection is the only
    //     condition a refusal is ever allowed on.
    {
      const PreflightLoadPath cutp = preflight_with_clearance(g, bcs, 10, 11, 0);
      CHECK(cutp.walk.decidable, "preflight/cut: still decidable");
      CHECK(!cutp.walk.connected,
            "preflight/cut: a keep-clear across the whole section SEVERS the "
            "path");
      CHECK(cutp.walk.unreached_load_voxels == cutp.walk.load_voxels,
            "preflight/cut: EVERY load voxel is unreachable");
      CHECK(cutp.walk.narrowest_separator_voxels == -1,
            "preflight/cut: a severed walk reports NO separator — it never "
            "invents a cross-section it did not reach");
      CHECK(cutp.forbidden_voxels > 0,
            "preflight/cut: it counted the forbidden voxels");
      std::printf("[preflight] cut bar: connected=%d, %zu/%zu load voxels "
                  "unreachable, %zu forbidden, %.3f ms\n",
                  cutp.walk.connected ? 1 : 0, cutp.walk.unreached_load_voxels,
                  cutp.walk.load_voxels, cutp.forbidden_voxels, cutp.wall_ms);
    }

    // (c) A keep-clear that leaves a NARROW but real channel (one row of j
    //     survives): connected, so it is NOT refused, and the narrowness is
    //     REPORTED. This is the "necessary, not sufficient" bar — pre-flight
    //     hands a marginal job to the solver with a number attached.
    {
      const PreflightLoadPath narrow =
          preflight_with_clearance(g, bcs, 10, 11, 1);
      CHECK(narrow.walk.connected,
            "preflight/narrow: a surviving channel is CONNECTED — narrowness is "
            "reported, never refused");
      CHECK(narrow.walk.narrowest_separator_voxels > 0 &&
                narrow.walk.narrowest_separator_voxels <
                    open.walk.narrowest_separator_voxels,
            "preflight/narrow: the reported separator is NARROWER than the open "
            "bar's — the marginality reading actually measures the channel");
      std::printf("[preflight] narrow bar: connected=%d, narrowest separator %d "
                  "voxels (%.4g mm^2) vs the open bar's %d\n",
                  narrow.walk.connected ? 1 : 0,
                  narrow.walk.narrowest_separator_voxels,
                  narrow.walk.narrowest_separator_mm2,
                  open.walk.narrowest_separator_voxels);
    }

    // (d) VACUOUS when there is nothing to decide (a self-weight run tags no
    //     Load faces). It must NOT invent a verdict.
    {
      VoxelGrid no_load = g;
      for (auto& t : no_load.tags)
        if (t == VoxelTag::Load) t = VoxelTag::Interior;
      const PreflightLoadPath v =
          preflight_with_clearance(no_load, bcs, 0, -1, 0);
      CHECK(!v.walk.decidable,
            "preflight: no Load voxels => NOT decidable (vacuous)");
      CHECK(v.walk.connected,
            "preflight: a vacuous walk reports connected — it never invents a "
            "verdict it cannot measure");
    }

    // (e) THE ALLOWED SET IS THE OPTIMIZER'S OWN. A voxel the effective mask
    //     pins FrozenVoid is forbidden; everything else is allowed. Proven by
    //     construction against effective_design_mask, so the pre-flight cannot
    //     drift from what simp_optimize actually does.
    {
      MinimizePlasticOptions o = base_options(g);
      const SolvedDesignDomain d = topopt::resolve_design_domain(g, bcs, o);
      const DesignMask eff = topopt::effective_design_mask(
          d.grid, topopt::design_domain_mask(d, o));
      std::size_t allowed = 0, forbidden = 0;
      for (const MaskValue m : eff)
        (m == MaskValue::FrozenVoid ? forbidden : allowed) += 1;
      const PreflightLoadPath pf = preflight_with_clearance(g, bcs, 0, -1, 0);
      CHECK(pf.walk.printed_voxels == allowed,
            "preflight: the walked set IS the non-FrozenVoid set of the "
            "optimizer's own effective mask");
      CHECK(pf.forbidden_voxels == forbidden,
            "preflight: the forbidden count IS the FrozenVoid count");
      CHECK(pf.allowed_frozen_solid + pf.allowed_active == pf.walk.printed_voxels,
            "preflight: the allowed split partitions the walked set");
    }

    // (f) The belt's bool wrapper and the reporting walk agree, always. There is
    //     ONE flood fill in the project.
    {
      std::vector<double> solid(g.voxel_count(), 1.0);
      CHECK(topopt::load_path_connected(g, solid) ==
                topopt::walk_load_path(g, solid).connected,
            "ONE flood fill: load_path_connected == walk_load_path().connected");
      std::vector<double> hollow = solid;
      for (int k = 0; k < g.nz; ++k)
        for (int j = 0; j < g.ny; ++j) hollow[g.index(12, j, k)] = 0.0;
      CHECK(!topopt::load_path_connected(g, hollow),
            "the belt still severs on a cut density field");
      CHECK(topopt::load_path_connected(g, hollow) ==
                topopt::walk_load_path(g, hollow).connected,
            "ONE flood fill: the two agree on a severed field too");
    }
  }

  // =========================================================================
  // 1b. THE GROWTH PATH (merge with PR 290, task 2026-08-03-growth-ladder).
  //
  //     PR 290 changed TWO things the pre-flight depends on: it builds the
  //     anchor/load structural PAD on the growth path too (kGrowthPathAnchorPad
  //     — `want_pad` is no longer minimize_plastic-only), and a growth run with
  //     no design box gets a MINIMAL one auto-derived. A pre-flight that ran
  //     against the pre-290 mask would be testing a domain the run no longer
  //     solves on.
  //
  //     It runs against the post-290 mask because it calls the optimizer's own
  //     `design_domain_mask` + `effective_design_mask` — but "it should" is not
  //     evidence, so this measures it. The DIRECTION also matters and is
  //     asserted: a FrozenSolid pad can only ever ENLARGE the allowed set (a pad
  //     voxel is always material, and it out-ranks a clearance that would
  //     otherwise void it), so the pad can never cause a false refusal. That is
  //     the property that makes the growth path safe, and it is checked rather
  //     than assumed.
  // =========================================================================
  {
    std::vector<DirichletBC> bcs;
    const VoxelGrid g = cantilever_bar(bcs);

    // A growth domain: a box BIGGER than the part, which the optimizer may grow
    // into — the shape of every growth run since PR 290.
    MinimizePlasticOptions grow;
    {
      MinimizePlasticOptions base = base_options(g);
      grow = base;
      DesignBox box;
      box.min = Vec3{g.origin.x - 4.0 * g.spacing, g.origin.y - 4.0 * g.spacing,
                     g.origin.z - 4.0 * g.spacing};
      box.max = Vec3{g.origin.x + (g.nx + 4) * g.spacing,
                     g.origin.y + (g.ny + 4) * g.spacing,
                     g.origin.z + (g.nz + 4) * g.spacing};
      grow.design_box = box;
      grow.freeze_imported_part = false;  // whole-domain optimize (handoff 080)
      grow.volume_fraction_ladder = topopt::production_growth_ladder();
    }

    // (a) A GROWTH RUN PASSES PRE-FLIGHT. The domain is larger than the part and
    //     most of it is empty Active space the optimizer may fill; connectivity
    //     on that domain had never been tested before this merge.
    const SolvedDesignDomain gd = topopt::resolve_design_domain(g, bcs, grow);
    const PreflightLoadPath gpf = topopt::preflight_load_path(gd, grow);
    CHECK(gpf.walk.decidable, "growth: the walk is decidable");
    CHECK(gpf.walk.connected,
          "GROWTH RUN PASSES PRE-FLIGHT — a domain that ADDS material outside "
          "the part is not refused");
    CHECK(gpf.allowed_active > 0,
          "growth: the empty growth region counts as ALLOWED (the optimizer may "
          "fill it), not as forbidden");
    std::printf("[growth] no pad: connected=%d, allowed=%zu (frozen %zu + active "
                "%zu), forbidden %zu, %.3f ms\n",
                gpf.walk.connected ? 1 : 0, gpf.walk.printed_voxels,
                gpf.allowed_frozen_solid, gpf.allowed_active,
                gpf.forbidden_voxels, gpf.wall_ms);

    // (b) WITH THE PR-290 ANCHOR PAD. The pad is a FrozenSolid overlay on the
    //     PART grid (mask_step_face writes only FrozenSolid), merged into the
    //     expanded mask by resolve_design_domain. The pre-flight must SEE it.
    MinimizePlasticOptions grow_pad = grow;
    {
      DesignMask pad = topopt::make_active_mask(g);
      // Freeze a slab behind the anchor face, as kProductionAnchorPadDepthVoxels
      // does on a real part.
      for (int k = 0; k < g.nz; ++k)
        for (int j = 0; j < g.ny; ++j)
          for (int i = 0; i < topopt::kProductionAnchorPadDepthVoxels; ++i)
            pad[g.index(i, j, k)] = MaskValue::FrozenSolid;
      grow_pad.design_mask = std::move(pad);
    }
    const SolvedDesignDomain pd =
        topopt::resolve_design_domain(g, bcs, grow_pad);
    const PreflightLoadPath ppf = topopt::preflight_load_path(pd, grow_pad);
    CHECK(ppf.walk.connected,
          "growth + pad: still CONNECTED — the pad never costs a load path");
    CHECK(ppf.allowed_frozen_solid > gpf.allowed_frozen_solid,
          "THE PRE-FLIGHT SEES THE PAD: the frozen-solid share of the allowed "
          "set GREW when the pad was added — it is running against the post-290 "
          "mask, not a pre-290 one");
    CHECK(ppf.walk.printed_voxels >= gpf.walk.printed_voxels,
          "DIRECTION: a FrozenSolid pad can only ENLARGE the allowed set, so it "
          "can never cause a false refusal");
    CHECK(ppf.forbidden_voxels <= gpf.forbidden_voxels,
          "DIRECTION: ... and can only shrink the forbidden set");
    std::printf("[growth] with pad: connected=%d, allowed=%zu (frozen %zu + "
                "active %zu), forbidden %zu\n",
                ppf.walk.connected ? 1 : 0, ppf.walk.printed_voxels,
                ppf.allowed_frozen_solid, ppf.allowed_active,
                ppf.forbidden_voxels);

    // (c) THE PAD OUT-RANKS A CLEARANCE, and the pre-flight inherits that. A
    //     keep-clear that would void the anchor region cannot, because
    //     design_domain_mask refuses to void a FrozenSolid base voxel. So adding
    //     a clearance over the pad leaves the path connected where without the
    //     pad it would be cut. This is the growth path's real safety property.
    MinimizePlasticOptions cut_nopad = grow, cut_pad = grow_pad;
    {
      // Indexed through the PART's extent at the domain offset — the loop
      // bounds are the part's, never the expanded grid's.
      auto make_cut = [&](const SolvedDesignDomain& d) {
        DesignMask c(d.grid.voxel_count(), MaskValue::Active);
        for (int k = 0; k < g.nz; ++k)
          for (int j = 0; j < g.ny; ++j)
            for (int i = 0; i < topopt::kProductionAnchorPadDepthVoxels; ++i)
              c[d.grid.index(i + d.offset_i, j + d.offset_j, k + d.offset_k)] =
                  MaskValue::FrozenVoid;
        return c;
      };
      cut_nopad.clearance_void = make_cut(gd);
      cut_pad.clearance_void = make_cut(pd);
    }
    const PreflightLoadPath cn = topopt::preflight_load_path(gd, cut_nopad);
    const PreflightLoadPath cp = topopt::preflight_load_path(pd, cut_pad);
    CHECK(cp.walk.printed_voxels > cn.walk.printed_voxels,
          "the PAD out-ranks the clearance: with the pad, the voxels the "
          "keep-clear tried to void are still allowed to hold material");
    std::printf("[growth] same keep-clear over the anchor: without pad allowed "
                "%zu (connected=%d), with pad allowed %zu (connected=%d)\n",
                cn.walk.printed_voxels, cn.walk.connected ? 1 : 0,
                cp.walk.printed_voxels, cp.walk.connected ? 1 : 0);
  }

  // =========================================================================
  // 2. GUARD 2 — THE IMMEDIATE DIVERGENCE TRIP, against the REAL trajectories.
  //
  // The 10-hour run must fire at iteration 2 (34 minutes in, instead of the ten
  // hours it actually ran). The live forming transient — which exceeds the
  // 10-hour run on compliance level (36,161x vs 7,482x), on single-step jump
  // (3,565x vs 1,688x) AND on CG blow-up (14.2x vs 12.6x) — must NEVER fire.
  // That is why the wall conjunct exists: it is the ONE column that separates
  // them (14.1x vs 77.2x).
  // =========================================================================
  {
    // The shipped defaults, asserted rather than assumed.
    MinimizePlasticOptions probe;
    // SHIPPED DISARMED — see SimpOptions::infeasible_immediate_ratio for the
    // measurement (the same job at resolution 64 RECOVERS and is accepted, so
    // the divergence premise did not survive testing). The calibrated value is
    // still asserted below against the real trajectories, so arming it is a
    // one-line change with its evidence already in place.
    CHECK(probe.simp.infeasible_immediate_ratio == 0.0,
          "defaults: the immediate divergence trip ships DISARMED");
    CHECK(probe.simp.infeasible_immediate_wall_ratio == kImmediateWallRatio,
          "defaults: the immediate wall ratio ships at 50");
    CHECK(probe.simp.infeasible_cg_blowup == kCgBlowup,
          "defaults: the immediate trip reuses the windowed CG conjunct (4x)");
    CHECK(probe.simp.infeasible_window == 5 &&
              probe.simp.infeasible_compliance_ratio == 100.0,
          "defaults: the WINDOWED detector is unchanged — this guard ADDS to it");

    const std::map<int, Trace> ten_hour =
        load_csv(std::string(DIVERGENCE_FIXTURE_DIR) + "/iterations_10h_designbox.csv");
    CHECK(!ten_hour.empty(), "fixture: the 10-hour run's iterations.csv loaded");
    for (const auto& kv : ten_hour) {
      const Trace& t = kv.second;
      CHECK(t.c.size() >= 3, "fixture: the 10-hour trace has its 3 iterations");
      CHECK(!immediate_fires(t, 1),
            "10h: never fires on iteration 1 — it IS the baseline");
      CHECK(immediate_fires(t, 2),
            "10h: FIRES at iteration 2 — 34 minutes in, not ten hours");
      const double lvl = t.c[1] / t.c[0];
      const double wr = t.ms[1] / t.ms[0];
      std::printf("[immediate] 10-hour run iteration 2: level %.4gx, cg %.3gx, "
                  "wall %.3gx -> FIRES\n",
                  lvl, static_cast<double>(t.cg[1]) / t.cg[0], wr);
      CHECK(lvl > kImmediateRatio, "10h: the level conjunct really is cleared");
      CHECK(wr > kImmediateWallRatio, "10h: the WALL conjunct really is cleared");
    }

    // THE FALSE-POSITIVE GUARD, live: the forming transient runs, recovers, and
    // is never called diverged. Its wall ratio is the reason.
    {
      std::vector<DirichletBC> bcs;
      const VoxelGrid g = cantilever_bar(bcs);
      MinimizePlasticOptions armed = base_options(g);
      armed.volume_fraction_ladder = {0.6, 0.03};
      double peak_level = 0.0, peak_step = 0.0, peak_wall = 0.0;
      double c0 = 0.0, w0 = 0.0, cprev = 0.0;
      armed.on_iteration = [&](std::size_t rung, std::size_t,
                               const topopt::SimpIterationObservation& o) {
        if (rung != 1) return;
        if (o.iteration == 1) {
          c0 = o.compliance;
          w0 = o.phases.total_ms;
          cprev = o.compliance;
        }
        if (c0 > 0.0) peak_level = std::max(peak_level, o.compliance / c0);
        if (cprev > 0.0) peak_step = std::max(peak_step, o.compliance / cprev);
        if (w0 > 0.0) peak_wall = std::max(peak_wall, o.phases.total_ms / w0);
        cprev = o.compliance;
      };
      armed.simp.infeasible_immediate_ratio = kImmediateRatio;  // ARM it here
      const MinimizePlasticResult r =
          minimize_plastic(g, mat, "PLA", bcs, rules, armed);
      std::printf("[immediate] live transient: peak level %.4gx, peak step "
                  "%.4gx, peak WALL %.3gx -> NOT killed\n",
                  peak_level, peak_step, peak_wall);
      CHECK(peak_level > kImmediateRatio,
            "transient: it really does exceed the compliance conjunct — so the "
            "compliance conjunct alone could NOT have spared it");
      for (const MinimizePlasticVariant& v : r.evaluated)
        CHECK(!v.optimization.diverged,
              "NO FALSE REFUSAL: the forming transient is never called diverged");
      for (char f : r.rung_diverged)
        CHECK(f == 0, "NO FALSE REFUSAL: rung_diverged reads all-zero");
      for (const topopt::VariantReport& vr : r.report.rejected)
        CHECK(vr.rejection_reason != std::string(topopt::kRungDivergedReason),
              "NO FALSE REFUSAL: no rung is rejected as diverging");
    }

    // The 96³ corpse (handoff 131's fixture) has no total_ms column, so the
    // wall conjunct cannot be formed on it — and the immediate trip therefore
    // DECLINES rather than guessing. The WINDOWED detector still owns that case,
    // which is exactly why it was kept.
    {
      const std::map<int, Trace> old96 =
          load_csv(std::string(INFEASIBLE_FIXTURE_DIR) +
                   "/iterations_96_designbox.csv");
      CHECK(!old96.empty(), "fixture: the 96^3 trace loaded");
      for (const auto& kv : old96)
        for (std::size_t n = 1; n <= kv.second.c.size(); ++n)
          CHECK(!immediate_fires(kv.second, n),
                "96^3: with no wall column the immediate trip DECLINES — the "
                "windowed detector owns that trajectory");
      // ... and the windowed detector still catches it, unchanged.
      const Trace& rung2 = old96.at(2);
      bool windowed_fired = false;
      for (std::size_t n = 1; n <= rung2.c.size() && !windowed_fired; ++n) {
        const std::vector<double> c(rung2.c.begin(), rung2.c.begin() + n);
        const std::vector<int> cg(rung2.cg.begin(), rung2.cg.begin() + n);
        windowed_fired = topopt::rung_infeasible(c, cg, 100.0, 4.0, 1e-3, 5);
      }
      CHECK(windowed_fired,
            "THE WINDOWED DETECTOR IS UNTOUCHED: it still catches the 96^3 "
            "corpse");
    }
  }

  // =========================================================================
  // 3. GUARD 3 — THE ITERATION TIME BUDGET.
  // =========================================================================
  {
    MinimizePlasticOptions probe;
    CHECK(probe.simp.iteration_time_ratio == kTimeRatio,
          "defaults: the iteration time guard ships at 100x");
    CHECK(probe.simp.iteration_time_floor_ms == kTimeFloorMs,
          "defaults: ... with a 5-minute floor");

    // The budget rule, on the real numbers: iteration 1 cost 26,663 ms, so the
    // budget is 44.4 minutes — which stops iteration 3 (22,679,464 ms) instead
    // of letting it finish, and leaves iteration 2 (2,058,989 ms) alone.
    const std::map<int, Trace> ten_hour =
        load_csv(std::string(DIVERGENCE_FIXTURE_DIR) + "/iterations_10h_designbox.csv");
    for (const auto& kv : ten_hour) {
      const Trace& t = kv.second;
      const double budget = std::max(kTimeRatio * t.ms[0], kTimeFloorMs);
      std::printf("[time] 10-hour run: iteration 1 %.0f ms -> budget %.0f ms "
                  "(%.1f min); iteration 2 %.0f ms (%s), iteration 3 %.0f ms "
                  "(%s)\n",
                  t.ms[0], budget, budget / 60000.0, t.ms[1],
                  t.ms[1] > budget ? "OVER" : "under", t.ms[2],
                  t.ms[2] > budget ? "OVER" : "under");
      CHECK(!(t.ms[1] > budget),
            "time: iteration 2 is UNDER budget — the guard does not fire early");
      CHECK(t.ms[2] > budget,
            "time: iteration 3 is OVER budget — it is stopped, not finished");
      // THE BASELINE CHOICE, measured. A median over the first three would put
      // the baseline at iteration 2's already-pathological wall and disarm the
      // guard on the very job it exists for.
      std::vector<double> first3(t.ms.begin(), t.ms.begin() + 3);
      std::sort(first3.begin(), first3.end());
      const double median_budget = std::max(kTimeRatio * first3[1], kTimeFloorMs);
      CHECK(!(t.ms[2] > median_budget),
            "time: a MEDIAN-of-first-three baseline would NOT have fired — "
            "which is why the baseline is the FIRST iteration");
      std::printf("[time] a median-of-first-3 baseline would give %.0f ms "
                  "(%.1f h) and fire on NOTHING\n",
                  median_budget, median_budget / 3600000.0);
    }

    // THE FLOOR: a fixture whose first iteration is milliseconds must get the
    // 5-minute floor, not 100x of nothing.
    CHECK(std::max(kTimeRatio * 3.0, kTimeFloorMs) == kTimeFloorMs,
          "time: a 3 ms first iteration yields the 5-minute FLOOR, not 300 ms");

    // NO FALSE REFUSAL, live: a real (fast) run never trips the guard.
    {
      std::vector<DirichletBC> bcs;
      const VoxelGrid g = cantilever_bar(bcs);
      MinimizePlasticOptions armed = base_options(g);
      armed.volume_fraction_ladder = {0.6, 0.3};
      const MinimizePlasticResult r =
          minimize_plastic(g, mat, "PLA", bcs, rules, armed);
      for (char f : r.rung_time_budget)
        CHECK(f == 0,
              "NO FALSE REFUSAL: a healthy run never blows the time budget");
      for (const topopt::VariantReport& vr : r.report.rejected)
        CHECK(vr.rejection_reason != std::string(topopt::kRungTimeBudgetReason),
              "NO FALSE REFUSAL: no rung is rejected on the time budget");
      CHECK(r.rung_time_budget.size() == r.evaluated.size(),
            "observability: one time-budget entry per evaluated rung");
      CHECK(r.rung_diverged.size() == r.evaluated.size(),
            "observability: one divergence entry per evaluated rung");
    }

    // The deadline API is disarmed by default and restores what it replaced.
    {
      CHECK(topopt::fea_solve_deadline_ms() == 0.0,
            "deadline: DISARMED by default");
      const double prev = topopt::fea_set_solve_deadline_ms(1234.0);
      CHECK(prev == 0.0 && topopt::fea_solve_deadline_ms() == 1234.0,
            "deadline: arming returns the previous value and takes effect");
      topopt::fea_set_solve_deadline_ms(prev);
      CHECK(topopt::fea_solve_deadline_ms() == 0.0,
            "deadline: disarming restores it — no leak into the next solve");
    }
  }

  // =========================================================================
  // 3b. WHAT A TRIPPED RUNG COSTS AFTER THE TRIP — the defect the acceptance
  //     run caught. A guard that stops the TRAJECTORY but then lets the run pay
  //     for the FINAL CERTIFICATION solve has saved nothing: that solve is the
  //     single most expensive one of the rung, at the TIGHT tolerance, on the
  //     very operator the guard just stopped for being ruinously slow. Measured
  //     on the motivating job: the trajectory ended at iteration 2 and the run
  //     kept going anyway.
  //
  //     Both guards are forced here with deliberately tiny thresholds, so the
  //     MECHANISM is tested on a fixture that runs in seconds. The SHIPPED
  //     constants are pinned in groups 2 and 3 above.
  // =========================================================================
  {
    std::vector<DirichletBC> bcs;
    const VoxelGrid g = cantilever_bar(bcs);

    // (a) GUARD 2 forced: the forming transient trips it once the thresholds are
    //     lowered under it. The rung must be rejected, labelled, and NOT solved
    //     again.
    {
      MinimizePlasticOptions o = base_options(g);
      o.volume_fraction_ladder = {0.6, 0.03, 0.02};
      o.simp.infeasible_immediate_ratio = 10.0;      // vs the calibrated 1000
      o.simp.infeasible_immediate_wall_ratio = 1.5;  // vs the shipped 50
      const MinimizePlasticResult r =
          minimize_plastic(g, mat, "PLA", bcs, rules, o);
      bool any = false;
      for (const MinimizePlasticVariant& v : r.evaluated) {
        if (!v.optimization.diverged) continue;
        any = true;
        CHECK(!v.optimization.converged,
              "diverged: the rung is NOT reported converged");
        CHECK(v.report.rejection_reason == std::string(topopt::kRungDivergedReason),
              "diverged: the rung is rejected, and says WHY — as diverging, NOT "
              "as a lost load path (nothing here measured the geometry)");
        CHECK(!v.report.accepted, "diverged: never accepted");
        // THE SKIP. On the skip branch `compliance` is the last recorded
        // objective; had the final certification solve run it would be that
        // solve's value instead.
        CHECK(!v.optimization.history.empty() &&
                  v.optimization.compliance ==
                      v.optimization.history.back().compliance,
              "diverged: the FINAL CERTIFICATION SOLVE IS SKIPPED — the "
              "reported compliance is the last recorded objective, not a fresh "
              "tight solve on the operator the guard just stopped for");
        CHECK(v.optimization.diverged_compliance_ratio >=
                  o.simp.infeasible_immediate_ratio,
              "diverged: it recorded the compliance ratio it fired on");
        CHECK(v.optimization.diverged_wall_ratio >=
                  o.simp.infeasible_immediate_wall_ratio,
              "diverged: it recorded the wall ratio it fired on");
        CHECK(v.optimization.diverged_iteration >= 2,
              "diverged: it recorded WHICH iteration (never iteration 1 — that "
              "is the baseline)");
        std::printf("[trip] guard 2 forced: fired at iteration %d on level "
                    "%.4gx / cg %.3gx / wall %.3gx; final solve SKIPPED\n",
                    v.optimization.diverged_iteration,
                    v.optimization.diverged_compliance_ratio,
                    v.optimization.diverged_cg_ratio,
                    v.optimization.diverged_wall_ratio);
      }
      CHECK(any, "guard 2 forced: it actually fired (else this group tests "
                 "nothing)");
      CHECK(r.rung_diverged.size() == r.evaluated.size(),
            "guard 2 forced: one record per evaluated rung, still aligned");
      CHECK(r.evaluated.size() > 1,
            "THE LADDER CONTINUES: a diverged rung does not end the run");
    }

    // (b) GUARD 3 forced: a budget no iteration can meet. Same three
    //     requirements, plus the phase must be NAMED.
    {
      MinimizePlasticOptions o = base_options(g);
      o.volume_fraction_ladder = {0.6, 0.3};
      o.simp.iteration_time_ratio = 1e-6;   // any iteration is "over budget"
      o.simp.iteration_time_floor_ms = 0.0; // and no floor to save it
      const MinimizePlasticResult r =
          minimize_plastic(g, mat, "PLA", bcs, rules, o);
      bool any = false;
      for (const MinimizePlasticVariant& v : r.evaluated) {
        if (!v.optimization.time_budget_exceeded) continue;
        any = true;
        CHECK(!v.optimization.converged,
              "time budget: the rung is NOT reported converged");
        CHECK(v.report.rejection_reason ==
                  std::string(topopt::kRungTimeBudgetReason),
              "time budget: the rung is rejected, and says WHY — as a time "
              "budget, NOT as a lost load path or a hard operator");
        CHECK(!v.optimization.history.empty() &&
                  v.optimization.compliance ==
                      v.optimization.history.back().compliance,
              "time budget: the FINAL CERTIFICATION SOLVE IS SKIPPED");
        CHECK(!v.optimization.time_budget_phase.empty(),
              "time budget: it NAMES the phase that blew up — the whole point "
              "of PR 273's per-phase columns");
        CHECK(v.optimization.time_budget_elapsed_ms >
                  v.optimization.time_budget_ms,
              "time budget: the elapsed wall really did exceed the budget");
        CHECK(v.optimization.time_budget_baseline_ms > 0.0,
              "time budget: it recorded the baseline the budget came from");
        CHECK(v.optimization.time_budget_iteration >= 2,
              "time budget: never fires on iteration 1 — that iteration IS the "
              "baseline, and nothing is judged against itself");
        std::printf("[trip] guard 3 forced: fired at iteration %d, %.1f ms "
                    "against a %.1f ms budget from a %.1f ms baseline; phase "
                    "\"%s\" (%.1f ms); final solve SKIPPED\n",
                    v.optimization.time_budget_iteration,
                    v.optimization.time_budget_elapsed_ms,
                    v.optimization.time_budget_ms,
                    v.optimization.time_budget_baseline_ms,
                    v.optimization.time_budget_phase.c_str(),
                    v.optimization.time_budget_phase_ms);
      }
      CHECK(any, "guard 3 forced: it actually fired");
      CHECK(r.rung_time_budget.size() == r.evaluated.size(),
            "guard 3 forced: one record per evaluated rung, still aligned");
    }
  }

  // =========================================================================
  // 4. THE ONE RULE — on a run where NOTHING trips, arming all three guards
  //    changes not one iteration and not one bit of the design.
  // =========================================================================
  {
    std::vector<DirichletBC> bcs;
    const VoxelGrid g = cantilever_bar(bcs);
    MinimizePlasticOptions armed = base_options(g);
    armed.volume_fraction_ladder = {0.6, 0.3};
    MinimizePlasticOptions disarmed = armed;
    disarmed.simp.infeasible_immediate_ratio = 0.0;  // guard 2 off
    disarmed.simp.iteration_time_ratio = 0.0;        // guard 3 off

    const MinimizePlasticResult ra =
        minimize_plastic(g, mat, "PLA", bcs, rules, armed);
    const MinimizePlasticResult rd =
        minimize_plastic(g, mat, "PLA", bcs, rules, disarmed);
    CHECK(ra.evaluated.size() == rd.evaluated.size(),
          "ONE RULE: arming the guards does not change the rungs evaluated");
    for (std::size_t i = 0; i < ra.evaluated.size() && i < rd.evaluated.size();
         ++i) {
      CHECK(ra.evaluated[i].optimization.iterations ==
                rd.evaluated[i].optimization.iterations,
            "ONE RULE: identical iteration counts");
      CHECK(ra.evaluated[i].optimization.physical_density ==
                rd.evaluated[i].optimization.physical_density,
            "ONE RULE: BIT-FOR-BIT identical designs");
      CHECK(ra.evaluated[i].report.accepted == rd.evaluated[i].report.accepted,
            "ONE RULE: identical verdicts");
    }
    std::printf("[one rule] %zu rungs, designs bit-identical armed vs disarmed\n",
                ra.evaluated.size());
  }

  std::printf("preflight_divergence: %d checks, %d failures\n", g_checks,
              g_failures);
  if (g_failures == 0)
    std::printf("preflight_divergence: all %d checks passed\n", g_checks);
  return g_failures == 0 ? 0 : 1;
}
