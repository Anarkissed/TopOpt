// beta_schedule_probe.cpp — β-CONTINUATION SCHEDULE, PHASE 0 (measurement only).
//
// The question (task 2026-07-26-beta-schedule-phase0): PR 193 showed 44-59% of
// outer iterations run AFTER the topology settles — they are the Heaviside
// β-projection continuation crisping the boundary, so NOT waste. PR 203 showed the
// iteration COUNT is set by the plateau detector and the β-continuation STRUCTURE,
// not the move limit. So the β schedule (1→2→4→8→16→32) IS the iteration budget.
// Nobody has measured whether it is the RIGHT schedule. This probe does.
//
// READ-ONLY / NO PRODUCTION CHANGE. It drives the ACTUAL production configuration
// (configure_production_options: matrix-free MG, min_feature 2.5 mm, MMA,
// conditional gray-gate projection @ Mnd>0.07, Krylov recycle, AUTO active-domain
// band) on the production ladder {0.68,0.52,0.38,0.26}. Every schedule ALTERNATIVE
// is expressed through EXISTING SimpOptions knobs that flow through the driver
// (opt = options.simp) — the continuation start β (mma_projection_beta0), the cap
// (mma_projection_beta_max) and the plateau-advance detector (mma_plateau_window /
// _tol / _flat_windows). NO core source is modified; the ×2 doubling factor is the
// one thing hard-coded in simp.cpp, so schedules with a different geometric ratio
// are BRACKETED with beta0-shift + single-jump runs (jump16/jump32/start4) rather
// than run directly — that gap is called out for Phase 1.
//
// Per iteration it captures, through the two byte-identity-safe observer hooks
// (handoff 114): compliance, design max|Δρ|, achieved vf, CG iters + mg telemetry
// (B5), active_fraction, plateau verdict, β this iter, infeasible verdict; and from
// the pinned PHYSICAL density each iteration: max/mean|Δρ_phys|, FRACTION OF SOLID
// VOXELS CHANGING CLASSIFICATION (B3), the discreteness measure design_discreteness_mnd
// (the gray-fraction the projection exists to reduce) and min_feature_violations
// (the min-feature measure the projection exists to reduce). Grid dims + solid count
// travel with every fraction (B1/B3).
//
// Q0/B1 NEGATIVE CONTROL FIRST: the SHIPPED schedule is run at cg_tolerance 1e-8
// (baseline) and 1e-9 (control) to establish the BASIN FLOOR — the class-change
// fraction between two should-agree runs. Every cross-schedule design difference is
// reported as a multiple of that floor.
//
// Build (standalone; NOT wired into CTest):
//   c++ -std=c++17 -O2 -I include -I /opt/homebrew/include/eigen3 \
//     -DSETTINGS_RULES_PATH="\"$PWD/src/settings/rules.json\"" \
//     tests/harness/beta_schedule_probe.cpp build/libtopopt.a -o beta_schedule_probe
// Run:  BS_CSV_DIR=<dir> [BS_SCHEDULES=base,cap16,...] [BS_CONTROL=1] ./beta_schedule_probe
// Grid is env-tunable: OP_SPAN / OP_NY / OP_ARM / OP_T / OP_H, OP_BOX / OP_BOXMULT.

#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
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
constexpr double kIso = 0.5;  // classification threshold (printed vs void)

int envi(const char* k, int d) { const char* v = std::getenv(k); return v ? std::atoi(v) : d; }
double envf(const char* k, double d) { const char* v = std::getenv(k); return v ? std::atof(v) : d; }

// The thin L-bracket the 080/082/ladder gates and cg_tol_probe build (identical to
// outer_iter_probe). Two arms of thickness t meeting at a corner; anchored on the
// top of one arm, tip-loaded on the end of the other.
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

// One schedule variant, expressed ENTIRELY through existing SimpOptions knobs.
struct Schedule {
  std::string name;
  double beta0;        // mma_projection_beta0
  double beta_max;     // mma_projection_beta_max
  int flat_windows;    // mma_plateau_flat_windows (-1 = production default)
  double plateau_tol;  // mma_plateau_tol (<0 = production default)
};

struct IterRec {
  int rung = 0, iter = 0;
  double compliance = 0.0, change_design = 0.0, vf = 0.0, active_frac = 1.0, beta = 0.0;
  int cg_iters = 0, mg_levels = 0, cycles = 0;
  bool mg_used = false, hier_built = false, plateau = false, infeasible = false;
  double max_dphys = -1.0, mean_dphys = -1.0, class_frac = -1.0;
  long long class_count = -1, solid = 0;
  // Two gray/min-feature measures per iter. The density_observer feeds the
  // UNPROJECTED filtered field (the mma_continuation path does not project xafter),
  // so `mnd`/`mfv` are the grayness of the underlying design x — which stays gray
  // because β-projection crisps via the H_β map, not by de-graying x. `mnd_proj`/
  // `mfv_proj` re-apply H_β at THIS iter's β (exactly project_solid), giving the
  // ANALYSIS/manufacturable field the projection actually produces — the field S1's
  // "gray-fraction the projection exists to improve" refers to. Equal in the β=0
  // grayscale phase (no projection).
  double mnd = -1.0, mnd_proj = -1.0;
  int mfv = -1, mfv_proj = -1;
  int draft = 0;           // B7: draft posture this run (0 = OFF, pinned)
  double traj_tol = 0.0;   // this iter's trajectory CG tol (== cg_tolerance under draft-off)
};

struct RunCapture {
  std::vector<IterRec> recs;
  std::vector<std::vector<double>> rung_terminal;   // per-rung converged physical density
  std::vector<int> rung_iters, rung_accepted, rung_fired;
  std::vector<double> rung_vf, rung_margin, rung_compliance, rung_beta_final, rung_mnd_final;
  std::vector<int> rung_mfv_final;
  int solved_nx = 0, solved_ny = 0, solved_nz = 0;
  long long solved_solid = 0;
  VoxelGrid solved_grid;
  double wall = 0.0;
};

IterRec* find_or_make(RunCapture& c, int rung, int iter) {
  for (auto it = c.recs.rbegin(); it != c.recs.rend(); ++it)
    if (it->rung == rung && it->iter == iter) return &*it;
  c.recs.push_back(IterRec{});
  c.recs.back().rung = rung; c.recs.back().iter = iter;
  return &c.recs.back();
}

void field_delta(const VoxelGrid& g, const std::vector<double>& cur,
                 const std::vector<double>& prev, double& max_d, double& mean_d,
                 double& class_frac, long long& class_count, long long& solid_out) {
  long long solid = 0, flipped = 0;
  double md = 0.0, sum = 0.0;
  for (int k = 0; k < g.nz; ++k)
    for (int j = 0; j < g.ny; ++j)
      for (int i = 0; i < g.nx; ++i) {
        if (!g.solid(i, j, k)) continue;
        const std::size_t e = g.index(i, j, k);
        ++solid;
        const double d = std::fabs(cur[e] - prev[e]);
        md = std::max(md, d); sum += d;
        if ((cur[e] > kIso) != (prev[e] > kIso)) ++flipped;
      }
  solid_out = solid;
  max_d = md;
  mean_d = solid ? sum / double(solid) : 0.0;
  class_count = flipped;
  class_frac = solid ? double(flipped) / double(solid) : 0.0;
}

// class-change fraction between two SHOULD-AGREE terminal designs (basin floor B1)
// OR between a variant terminal design and the shipped baseline (cross-schedule B3).
double terminal_class_frac(const VoxelGrid& g, const std::vector<double>& a,
                           const std::vector<double>& b, double& mean_d, double& max_d,
                           long long& flips, long long& solid) {
  double cf; field_delta(g, a, b, max_d, mean_d, cf, flips, solid);
  return cf;
}

RunCapture run_ladder(const Schedule& sch, double cg_tol, const VoxelGrid& part,
                      const std::vector<DirichletBC>& bcs,
                      const std::vector<NodalLoad>& loads, const SettingsRules& rules,
                      const Material& material, const DesignBox* box) {
  MinimizePlasticOptions o;
  configure_production_options(o);                 // the ACTUAL production posture
  o.volume_fraction_ladder = production_reduction_ladder();
  o.margin_stop = 1.5;
  o.external_loads = loads;
  o.gravity = 9810.0 * 1e-9;
  o.gravity_direction = Vec3{0.0, 0.0, -1.0};
  o.infill_percent = 100.0;
  if (box) o.design_box = *box;
  o.simp.cg_tolerance = cg_tol;
  // B7 — DRAFT IS EXPLICITLY OFF for the headline β measurement. Do NOT rely on the
  // production default (a draft-arming PR may be in flight): an armed loose trajectory
  // tolerance changes CG counts and can shift which iterations reach the plateau, so a
  // β finding taken under draft-on would be about β AND draft together. Pinned false
  // here and echoed in EVERY CSV row (`draft` column) + the per-iter trajectory
  // tolerance (`traj_tol`), which under draft-off equals the tight cg_tolerance.
  o.draft_quality = false;
  // --- schedule knobs (existing SimpOptions fields; no production change) --------
  o.simp.mma_projection_beta0 = sch.beta0;
  o.simp.mma_projection_beta_max = sch.beta_max;
  if (sch.flat_windows >= 0) o.simp.mma_plateau_flat_windows = sch.flat_windows;
  if (sch.plateau_tol > 0.0) o.simp.mma_plateau_tol = sch.plateau_tol;

  RunCapture cap;
  std::vector<std::vector<double>> prev_field(o.volume_fraction_ladder.size());
  std::vector<double> rung_beta_seen(o.volume_fraction_ladder.size(), 0.0);

  o.on_iteration = [&](std::size_t rung, std::size_t /*count*/,
                       const SimpIterationObservation& ob) {
    IterRec* r = find_or_make(cap, (int)rung, ob.iteration);
    r->compliance = ob.compliance; r->change_design = ob.change; r->vf = ob.volume_fraction;
    r->active_frac = ob.active_fraction; r->beta = ob.beta;
    r->cg_iters = ob.cg_iterations; r->mg_levels = ob.cg_mg_levels;
    r->cycles = ob.cg_mg_cycles_attempted; r->mg_used = ob.cg_used_multigrid;
    r->hier_built = ob.cg_hier_built; r->plateau = ob.plateau; r->infeasible = ob.infeasible;
    r->traj_tol = ob.cg_trajectory_tol; r->draft = o.draft_quality ? 1 : 0;  // B7
    if (rung < rung_beta_seen.size()) rung_beta_seen[rung] = std::max(rung_beta_seen[rung], ob.beta);
  };

  o.on_density_snapshot = [&](const DensitySnapshotEvent& ev) {
    if (!ev.density || !ev.grid) return;
    const std::size_t rung = ev.rung_index;
    const DesignMask mask = make_active_mask(*ev.grid);
    const double mnd = design_discreteness_mnd(*ev.grid, *ev.density, mask);
    const int mfv = min_feature_violations(*ev.grid, *ev.density, kIso);
    if (ev.boundary) {                             // rung's converged density
      if (cap.rung_terminal.size() <= rung) cap.rung_terminal.resize(rung + 1);
      cap.rung_terminal[rung] = *ev.density;
      if (cap.rung_mnd_final.size() <= rung) { cap.rung_mnd_final.resize(rung + 1, -1.0);
        cap.rung_mfv_final.resize(rung + 1, -1); }
      cap.rung_mnd_final[rung] = mnd; cap.rung_mfv_final[rung] = mfv;
      if (cap.solved_solid == 0) {
        cap.solved_nx = ev.grid->nx; cap.solved_ny = ev.grid->ny; cap.solved_nz = ev.grid->nz;
        cap.solved_solid = (long long)ev.grid->solid_count();
        cap.solved_grid = *ev.grid;
      }
      return;
    }
    IterRec* r = find_or_make(cap, (int)rung, ev.iteration);
    r->mnd = mnd; r->mfv = mfv;
    // Projected (analysis) field at THIS iter's β (set by on_iteration, which fires
    // first). β==0 -> proj == unprojected, so the grayscale phase reports equal.
    const double beta_here = r->beta;
    if (beta_here > 0.0) {
      std::vector<double> proj = *ev.density;
      const VoxelGrid& g = *ev.grid;
      for (int k = 0; k < g.nz; ++k)
        for (int j = 0; j < g.ny; ++j)
          for (int i = 0; i < g.nx; ++i)
            if (g.solid(i, j, k)) {
              const std::size_t e = g.index(i, j, k);
              proj[e] = heaviside_project(proj[e], beta_here, kIso);  // eta = 0.5 (locked)
            }
      r->mnd_proj = design_discreteness_mnd(g, proj, mask);
      r->mfv_proj = min_feature_violations(g, proj, kIso);
    } else {
      r->mnd_proj = mnd; r->mfv_proj = mfv;
    }
    if (!prev_field[rung].empty()) {
      field_delta(*ev.grid, *ev.density, prev_field[rung], r->max_dphys, r->mean_dphys,
                  r->class_frac, r->class_count, r->solid);
    } else {
      r->solid = (long long)ev.grid->solid_count();
    }
    prev_field[rung] = *ev.density;
  };

  const auto t0 = std::chrono::steady_clock::now();
  const MinimizePlasticResult res = minimize_plastic(part, material, "fdm", bcs, rules, o);
  const auto t1 = std::chrono::steady_clock::now();
  cap.wall = std::chrono::duration<double>(t1 - t0).count();

  for (std::size_t i = 0; i < res.evaluated.size(); ++i) {
    const auto& v = res.evaluated[i];
    cap.rung_iters.push_back(v.optimization.iterations);
    cap.rung_vf.push_back(v.optimization.volume_fraction);
    cap.rung_margin.push_back(v.report.margin.worst_case);
    cap.rung_compliance.push_back(v.optimization.compliance);
    cap.rung_accepted.push_back(v.accepted ? 1 : 0);
    cap.rung_beta_final.push_back(i < rung_beta_seen.size() ? rung_beta_seen[i] : 0.0);
    // fired = the conditional gate continued this rung into β-projection (any β>0)
    cap.rung_fired.push_back((i < rung_beta_seen.size() && rung_beta_seen[i] > 0.0) ? 1 : 0);
  }
  return cap;
}

void write_periter_csv(const std::string& path, const RunCapture& c,
                       const std::string& sch, double cg_tol) {
  std::FILE* f = std::fopen(path.c_str(), "w");
  if (!f) { std::fprintf(stderr, "WARN: cannot write %s\n", path.c_str()); return; }
  std::fprintf(f, "schedule,cg_tol,rung,iter,compliance,change_design,max_dphys,mean_dphys,"
                  "class_frac,class_count,solid,cg_iters,mg_used,hier_built,mg_levels,"
                  "cycles,active_frac,beta,plateau,infeasible,vf,mnd,mfv,mnd_proj,mfv_proj,"
                  "draft,traj_tol\n");
  for (const IterRec& r : c.recs)
    std::fprintf(f, "%s,%.0e,%d,%d,%.8g,%.6g,%.6g,%.6g,%.6g,%lld,%lld,%d,%d,%d,%d,%d,%.4f,%.4g,%d,%d,%.5f,%.6g,%d,%.6g,%d,%d,%.2e\n",
                 sch.c_str(), cg_tol, r.rung, r.iter, r.compliance, r.change_design, r.max_dphys,
                 r.mean_dphys, r.class_frac, r.class_count, r.solid, r.cg_iters,
                 r.mg_used, r.hier_built, r.mg_levels, r.cycles, r.active_frac, r.beta,
                 r.plateau, r.infeasible, r.vf, r.mnd, r.mfv, r.mnd_proj, r.mfv_proj,
                 r.draft, r.traj_tol);
  std::fclose(f);
  std::printf("  [wrote %s : %zu iters, %.1fs]\n", path.c_str(), c.recs.size(), c.wall);
}

}  // namespace

int main() {
  SettingsRules rules;
  try { rules = load_settings_rules_file(SETTINGS_RULES_PATH); }
  catch (const std::exception& e) {
    std::fprintf(stderr, "FAIL: could not load rules.json: %s\n", e.what());
    return 1;
  }
  const Material material = fdm_material();
  const char* csv_dir = std::getenv("BS_CSV_DIR");
  const std::string dir = csv_dir ? csv_dir : ".";

  const int span = envi("OP_SPAN", 48), ny = envi("OP_NY", 16),
            arm = envi("OP_ARM", 48), t = envi("OP_T", 12);
  const double h = envf("OP_H", 2.0);
  std::vector<DirichletBC> bcs;
  VoxelGrid part = l_bracket(bcs, arm, span, ny, t, h);
  const std::vector<NodalLoad> tip =
      traction_loads(part, VoxelTag::Load, Vec3{0.0, 0.0, -30.0});

  DesignBox box; bool use_box = envi("OP_BOX", 0) != 0;
  const double bm = envf("OP_BOXMULT", 1.33);
  if (use_box) {
    box.min = Vec3{0, 0, 0};
    box.max = Vec3{span * h * bm, ny * h, arm * h * bm};
  }
  const DesignBox* boxp = use_box ? &box : nullptr;

  // The SHIPPED schedule (base) and the alternatives. Every one differs from base
  // ONLY in existing knobs (beta0 / beta_max / plateau-advance).
  //                 name        beta0 beta_max flat_win plateau_tol
  const Schedule base  {"base",   1.0,  32.0,   -1,  -1.0};   // SHIPPED 1→2→4→8→16→32
  const std::vector<Schedule> alts = {
    base,
    {"cap16", 1.0, 16.0, -1, -1.0},   // S2: stop at 16 (1→2→4→8→16)
    {"cap8",  1.0,  8.0, -1, -1.0},   // stop even earlier (1→2→4→8)
    {"start4",4.0, 16.0, -1, -1.0},   // S3: skip the β=1,2 warmup (4→8→16)
    {"jump16",16.0,16.0, -1, -1.0},   // S3: single jump straight to 16 (no continuation)
    {"jump32",32.0,32.0, -1, -1.0},   // S3: single jump straight to 32
    {"aggr",  1.0, 32.0,  1,  3e-3},  // S3/S4: promote β sooner (1 flat window, looser tol)
  };

  // Which schedules to run this invocation (default all). Comma-separated names.
  std::vector<std::string> want;
  if (const char* s = std::getenv("BS_SCHEDULES")) {
    std::string cur;
    for (const char* p = s; ; ++p) {
      if (*p == ',' || *p == '\0') { if (!cur.empty()) want.push_back(cur); cur.clear(); if (!*p) break; }
      else cur.push_back(*p);
    }
  }
  auto wanted = [&](const std::string& n) {
    return want.empty() || std::find(want.begin(), want.end(), n) != want.end();
  };

  std::printf("== BETA-SCHEDULE PHASE 0 ==  L-bracket %s grid=%dx%dx%d  solid=%zu voxels  "
              "h=%.1fmm  ladder={0.68,0.52,0.38,0.26}  MMA+matfreeMG+condproj (production)\n",
              use_box ? "DESIGN-BOX (whole-domain, dilute)" : "loadcase",
              part.nx, part.ny, part.nz, part.solid_count(), h);
  if (use_box) std::printf("   design box max=(%.0f,%.0f,%.0f)mm  (part=%.0fx%.0fx%.0fmm)\n",
              box.max.x, box.max.y, box.max.z, span*h, ny*h, arm*h);

  // --- Q0 / B1: NEGATIVE CONTROL on the SHIPPED schedule (basin floor) -----------
  RunCapture base_cap, ctrl_cap;
  bool have_control = envi("BS_CONTROL", 1) != 0;
  std::printf("\n[Q0/B1] SHIPPED schedule, cg_tol=1e-8 (baseline) ...\n"); std::fflush(stdout);
  base_cap = run_ladder(base, 1e-8, part, bcs, tip, rules, material, boxp);
  write_periter_csv(dir + "/periter_base.csv", base_cap, "base", 1e-8);
  if (have_control) {
    std::printf("[Q0/B1] SHIPPED schedule, cg_tol=1e-9 (negative control) ...\n"); std::fflush(stdout);
    ctrl_cap = run_ladder(base, 1e-9, part, bcs, tip, rules, material, boxp);
    write_periter_csv(dir + "/periter_base_ctrl.csv", ctrl_cap, "base", 1e-9);
  }

  // --- summary CSV: one row per (schedule, rung) with gate verdict + cross-diff --
  std::FILE* sf = std::fopen((dir + "/summary.csv").c_str(), "w");
  std::fprintf(sf, "schedule,rung,vf,iters,accepted,fired,beta_final,margin,compliance,"
                   "mnd_final,mfv_final,class_frac_vs_base,flips_vs_base,solid,"
                   "solved_nx,solved_ny,solved_nz,wall_s,draft\n");
  auto emit_summary = [&](const RunCapture& c, const std::string& name) {
    const VoxelGrid& g = base_cap.solved_grid;
    for (std::size_t i = 0; i < c.rung_iters.size(); ++i) {
      double cf = -1.0, mean_d = 0, max_d = 0; long long flips = -1, solid = 0;
      if (i < c.rung_terminal.size() && i < base_cap.rung_terminal.size() &&
          !c.rung_terminal[i].empty() && !base_cap.rung_terminal[i].empty())
        cf = terminal_class_frac(g, c.rung_terminal[i], base_cap.rung_terminal[i],
                                 mean_d, max_d, flips, solid);
      std::fprintf(sf, "%s,%zu,%.2f,%d,%d,%d,%.4g,%.6g,%.8g,%.6g,%d,%.6g,%lld,%lld,%d,%d,%d,%.1f,0\n",
                   name.c_str(), i, i<c.rung_vf.size()?c.rung_vf[i]:0.0, c.rung_iters[i],
                   c.rung_accepted[i], c.rung_fired[i], c.rung_beta_final[i], c.rung_margin[i],
                   c.rung_compliance[i], i<c.rung_mnd_final.size()?c.rung_mnd_final[i]:-1.0,
                   i<c.rung_mfv_final.size()?c.rung_mfv_final[i]:-1, cf, flips,
                   c.solved_solid, c.solved_nx, c.solved_ny, c.solved_nz, c.wall);
    }
  };
  emit_summary(base_cap, "base");
  if (have_control) emit_summary(ctrl_cap, "base_ctrl");

  // --- run the alternative schedules (all at cg_tol=1e-8) ------------------------
  for (const Schedule& sch : alts) {
    if (sch.name == "base") continue;               // already run as the baseline
    if (!wanted(sch.name)) continue;
    std::printf("[schedule] %s  (beta0=%.0f beta_max=%.0f flat_win=%d tol=%.0e) ...\n",
                sch.name.c_str(), sch.beta0, sch.beta_max, sch.flat_windows, sch.plateau_tol);
    std::fflush(stdout);
    // A schedule can be INFEASIBLE (e.g. jumping straight to β=32 from a gray field
    // leaves a system CG cannot solve in budget — itself a finding for S3). Catch it
    // so one infeasible variant does not abort the whole probe / the other grids.
    try {
      RunCapture cap = run_ladder(sch, 1e-8, part, bcs, tip, rules, material, boxp);
      write_periter_csv(dir + "/periter_" + sch.name + ".csv", cap, sch.name, 1e-8);
      emit_summary(cap, sch.name);
    } catch (const std::exception& e) {
      std::printf("  [SCHEDULE %s FAILED — INFEASIBLE: %s]\n", sch.name.c_str(), e.what());
      std::fprintf(sf, "%s,-1,0,0,0,0,%g,0,0,0,0,-1,-1,%lld,%d,%d,%d,0,0\n",
                   sch.name.c_str(), sch.beta_max, base_cap.solved_solid,
                   base_cap.solved_nx, base_cap.solved_ny, base_cap.solved_nz);
      std::fflush(sf);
    }
  }
  std::fclose(sf);

  std::printf("\n[done] CSVs + summary.csv in %s\n", dir.c_str());
  return 0;
}
