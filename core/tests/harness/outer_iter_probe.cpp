// outer_iter_probe.cpp — OUTER-ITERATION count, PHASE 0 (measurement only).
//
// The question (task 2026-07-26-outer-iterations-phase0): every speed win so far
// cuts COST PER SOLVE; none cuts HOW MANY SOLVES a rung takes. Before adding
// another per-solve trick, MEASURE whether the ladder's rungs stop too late —
// i.e. whether the design has stopped changing MATERIALLY well before the
// plateau detector actually terminates the rung.
//
// READ-ONLY. It drives the ACTUAL production configuration
// (configure_production_options: matrix-free MG, min_feature 2.5 mm, MMA,
// conditional gray-gate projection, Krylov recycle, AUTO active-domain band) on a
// production-RESEMBLING L-bracket ladder (NOT an 8x3x8 toy — task bar B2), and
// captures per-iteration state through the two READ-ONLY observer hooks that make
// a captured run byte-identical to an uncaptured one (handoff 114):
//   * on_iteration      -> SimpIterationObservation: compliance, design max|drho|,
//                          achieved vf, CG iters, mg_used/hier_built/mg_levels,
//                          active_fraction, plateau verdict, beta, infeasible.
//   * on_density_snapshot -> the pinned PHYSICAL density each iteration, from which
//                          we compute, vs the SAME rung's previous iteration:
//                            max|d rho_phys|, mean|d rho_phys| (over solid voxels),
//                            and the FRACTION OF SOLID VOXELS CHANGING CLASSIFICATION
//                            (rho crossing 0.5). Grid dims + solid_count travel with
//                            every fraction (task bar B1).
//
// Q0 NEGATIVE CONTROL FIRST (task bar): the ladder is run TWICE under identical
// production config except cg_tolerance = 1e-8 (baseline) vs 1e-9 (control). Two
// runs that SHOULD agree give the BASIN NOISE FLOOR: the fraction of solid voxels
// whose classification differs between them at each rung's terminal design. Every
// "materially changed" judgement in Q1 is made against THAT floor, never an
// imported constant.
//
// Build (standalone; NOT wired into CTest):
//   c++ -std=c++17 -O2 -I include -I /opt/homebrew/include/eigen3 \
//     -DSETTINGS_RULES_PATH="\"$PWD/src/settings/rules.json\"" \
//     tests/harness/outer_iter_probe.cpp build/libtopopt.a -o outer_iter_probe
// Run:  OUTER_PROBE_CSV_DIR=<dir> ./outer_iter_probe
// Grid is env-tunable: OP_SPAN / OP_NY / OP_ARM / OP_T / OP_H (defaults below).

#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstdint>
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
constexpr double kIso = 0.5;  // classification threshold (printed vs void)

int envi(const char* k, int d) { const char* v = std::getenv(k); return v ? std::atoi(v) : d; }
double envf(const char* k, double d) { const char* v = std::getenv(k); return v ? std::atof(v) : d; }

// The thin L-bracket the 080/082/ladder gates and cg_tol_probe build. Two arms
// of thickness t meeting at a corner; anchored on the top of one arm, tip-loaded
// on the end of the other. Solid fraction ~ 1-((arm-t)/arm)^2. At the production-
// resembling 48x16x48/t=12 this is ~16k solid voxels — the "full production
// ladder" scale handoff 132 measured on, not a toy.
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

// One captured optimizer iteration: the observation (on_iteration) MERGED with the
// consecutive-iteration physical-density deltas (on_density_snapshot).
struct IterRec {
  int rung = 0, iter = 0;
  // from on_iteration (SimpIterationObservation)
  double compliance = 0.0, change_design = 0.0, vf = 0.0, active_frac = 1.0, beta = 0.0;
  int cg_iters = 0, mg_levels = 0, cycles = 0;
  bool mg_used = false, hier_built = false, plateau = false, infeasible = false;
  // computed from the physical field vs the SAME rung's previous iteration
  double max_dphys = -1.0, mean_dphys = -1.0, class_frac = -1.0;
  long long class_count = -1, solid = 0;
};

struct RunCapture {
  std::vector<IterRec> recs;                    // all iters, all rungs, in order
  std::vector<std::vector<double>> rung_terminal;  // per-rung converged physical density
  std::vector<int> rung_iters;                  // outer iters each rung ran
  std::vector<double> rung_vf, rung_margin, rung_compliance;
  std::vector<int> rung_accepted;
  int solved_nx = 0, solved_ny = 0, solved_nz = 0;
  long long solved_solid = 0;
  VoxelGrid solved_grid;   // the grid the optimizer actually solved on (part or expanded box)
  double wall = 0.0;
};

IterRec* find_or_make(RunCapture& c, int rung, int iter) {
  for (auto it = c.recs.rbegin(); it != c.recs.rend(); ++it)  // recent-first: O(1) typical
    if (it->rung == rung && it->iter == iter) return &*it;
  c.recs.push_back(IterRec{});
  c.recs.back().rung = rung; c.recs.back().iter = iter;
  return &c.recs.back();
}

// classification-change fraction + mean/max |drho| between two grid-indexed
// physical fields, over the grid's SOLID voxels only (Empty voxels are not design
// variables). Returns solid count via *solid_out.
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

// Terminal-design classification-change fraction between two SHOULD-AGREE runs
// (the Q0 basin floor), over the solved grid's solid voxels.
double terminal_class_frac(const VoxelGrid& g, const std::vector<double>& a,
                           const std::vector<double>& b, double& mean_d, double& max_d) {
  double cf; long long cc, sc;
  field_delta(g, a, b, max_d, mean_d, cf, cc, sc);
  return cf;
}

RunCapture run_ladder(double cg_tol, const VoxelGrid& part,
                      const std::vector<DirichletBC>& bcs,
                      const std::vector<NodalLoad>& loads, const SettingsRules& rules,
                      const Material& material, const DesignBox* box) {
  MinimizePlasticOptions o;
  configure_production_options(o);                 // the ACTUAL production posture
  o.volume_fraction_ladder = production_reduction_ladder();  // {0.68,0.52,0.38,0.26}
  o.margin_stop = 1.5;
  o.external_loads = loads;
  o.gravity = 9810.0 * 1e-9;
  o.gravity_direction = Vec3{0.0, 0.0, -1.0};
  o.infill_percent = 100.0;
  if (box) o.design_box = *box;                    // whole-domain design box (dilute regime)
  o.simp.cg_tolerance = cg_tol;                    // the ONLY knob toggled for Q0

  RunCapture cap;
  // Per-rung previous physical field for the consecutive-iteration delta.
  std::vector<std::vector<double>> prev_field(o.volume_fraction_ladder.size());

  o.on_iteration = [&](std::size_t rung, std::size_t /*count*/,
                       const SimpIterationObservation& ob) {
    IterRec* r = find_or_make(cap, (int)rung, ob.iteration);
    r->compliance = ob.compliance; r->change_design = ob.change; r->vf = ob.volume_fraction;
    r->active_frac = ob.active_fraction; r->beta = ob.beta;
    r->cg_iters = ob.cg_iterations; r->mg_levels = ob.cg_mg_levels;
    r->cycles = ob.cg_mg_cycles_attempted; r->mg_used = ob.cg_used_multigrid;
    r->hier_built = ob.cg_hier_built; r->plateau = ob.plateau; r->infeasible = ob.infeasible;
  };

  o.on_density_snapshot = [&](const DensitySnapshotEvent& ev) {
    if (!ev.density || !ev.grid) return;
    const std::size_t rung = ev.rung_index;
    if (ev.boundary) {                             // rung's converged density
      if (cap.rung_terminal.size() <= rung) cap.rung_terminal.resize(rung + 1);
      cap.rung_terminal[rung] = *ev.density;
      if (cap.solved_solid == 0) {
        cap.solved_nx = ev.grid->nx; cap.solved_ny = ev.grid->ny; cap.solved_nz = ev.grid->nz;
        cap.solved_solid = (long long)ev.grid->solid_count();
        cap.solved_grid = *ev.grid;
      }
      return;
    }
    IterRec* r = find_or_make(cap, (int)rung, ev.iteration);
    if (!prev_field[rung].empty()) {
      field_delta(*ev.grid, *ev.density, prev_field[rung], r->max_dphys, r->mean_dphys,
                  r->class_frac, r->class_count, r->solid);
    } else {
      r->solid = (long long)ev.grid->solid_count();
    }
    prev_field[rung] = *ev.density;                // keep for next iteration's delta
  };

  const auto t0 = std::chrono::steady_clock::now();
  const MinimizePlasticResult res = minimize_plastic(part, material, "fdm", bcs, rules, o);
  const auto t1 = std::chrono::steady_clock::now();
  cap.wall = std::chrono::duration<double>(t1 - t0).count();

  for (const auto& v : res.evaluated) {
    cap.rung_iters.push_back(v.optimization.iterations);
    cap.rung_vf.push_back(v.optimization.volume_fraction);
    cap.rung_margin.push_back(v.report.margin.worst_case);
    cap.rung_compliance.push_back(v.optimization.compliance);
    cap.rung_accepted.push_back(v.accepted ? 1 : 0);
  }
  return cap;
}

void write_periter_csv(const std::string& path, const RunCapture& c, double cg_tol) {
  std::FILE* f = std::fopen(path.c_str(), "w");
  if (!f) { std::fprintf(stderr, "WARN: cannot write %s\n", path.c_str()); return; }
  std::fprintf(f, "cg_tol,rung,iter,compliance,change_design,max_dphys,mean_dphys,"
                  "class_frac,class_count,solid,cg_iters,mg_used,hier_built,mg_levels,"
                  "cycles,active_frac,beta,plateau,infeasible,vf\n");
  for (const IterRec& r : c.recs)
    std::fprintf(f, "%.0e,%d,%d,%.8g,%.6g,%.6g,%.6g,%.6g,%lld,%lld,%d,%d,%d,%d,%d,%.4f,%.3g,%d,%d,%.5f\n",
                 cg_tol, r.rung, r.iter, r.compliance, r.change_design, r.max_dphys,
                 r.mean_dphys, r.class_frac, r.class_count, r.solid, r.cg_iters,
                 r.mg_used, r.hier_built, r.mg_levels, r.cycles, r.active_frac, r.beta,
                 r.plateau, r.infeasible, r.vf);
  std::fclose(f);
  std::printf("  [wrote %s]\n", path.c_str());
}

// Per rung of `base`: the first iteration after which class_frac stays STRICTLY
// BELOW `floor` for the entire rest of the rung (the design has stopped changing
// MATERIALLY). Returns the pair (settle_iter, last_iter). settle_iter == last_iter
// means it was still material at the last step (no free win on this rung).
void analyse_rung(const RunCapture& base, int rung, double floor,
                  int& settle_iter, int& last_iter, int& material_iters_after,
                  double& last_class_frac) {
  std::vector<const IterRec*> rr;
  for (const IterRec& r : base.recs) if (r.rung == rung && r.class_frac >= 0.0) rr.push_back(&r);
  last_iter = rr.empty() ? 0 : rr.back()->iter;
  last_class_frac = rr.empty() ? -1.0 : rr.back()->class_frac;
  // settle = 1 + index of the LAST iteration whose class_frac >= floor.
  settle_iter = rr.empty() ? 0 : rr.front()->iter;
  int last_material = 0;
  for (const IterRec* r : rr) if (r->class_frac >= floor) last_material = r->iter;
  settle_iter = last_material;             // last materially-changing iteration
  material_iters_after = 0;                // material iters that came AFTER settle
  for (const IterRec* r : rr) if (r->iter > last_material && r->class_frac >= floor) ++material_iters_after;
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
  const char* csv_dir = std::getenv("OUTER_PROBE_CSV_DIR");
  const std::string dir = csv_dir ? csv_dir : ".";

  // Production-resembling L-bracket loadcase (handoff 132's "full production
  // ladder" scale, env-tunable). NOT a toy (task bar B2).
  const int span = envi("OP_SPAN", 48), ny = envi("OP_NY", 16),
            arm = envi("OP_ARM", 48), t = envi("OP_T", 12);
  const double h = envf("OP_H", 2.0);
  std::vector<DirichletBC> bcs;
  VoxelGrid part = l_bracket(bcs, arm, span, ny, t, h);
  const std::vector<NodalLoad> tip =
      traction_loads(part, VoxelTag::Load, Vec3{0.0, 0.0, -30.0});

  // Optional whole-domain DESIGN BOX (dilute regime — the 96^3 marathon posture).
  // OP_BOX=1 wraps the part in a box whose x/z extent is OP_BOXMULT x the part
  // (default 1.33), leaving the part in the corner where the L-bracket sits.
  DesignBox box; bool use_box = envi("OP_BOX", 0) != 0;
  const double bm = envf("OP_BOXMULT", 1.33);
  if (use_box) {
    box.min = Vec3{0, 0, 0};
    box.max = Vec3{span * h * bm, ny * h, arm * h * bm};
  }
  std::printf("== OUTER-ITERATION PHASE 0 ==  L-bracket %s grid=%dx%dx%d  "
              "solid=%zu voxels  h=%.1fmm  ladder={0.68,0.52,0.38,0.26}  MMA+matfreeMG (production)\n",
              use_box ? "DESIGN-BOX (whole-domain, dilute)" : "loadcase",
              part.nx, part.ny, part.nz, part.solid_count(), h);
  if (use_box) std::printf("   design box max=(%.0f,%.0f,%.0f)mm  (part=%.0fx%.0fx%.0fmm)\n",
              box.max.x, box.max.y, box.max.z, span*h, ny*h, arm*h);

  // Q0 FIRST: baseline (tight 1e-8) and negative control (1e-9). Should agree.
  std::printf("\n[Q0] running BASELINE cg_tol=1e-8 ...\n"); std::fflush(stdout);
  RunCapture base = run_ladder(1e-8, part, bcs, tip, rules, material, use_box ? &box : nullptr);
  std::printf("      done in %.1fs.  running NEGATIVE CONTROL cg_tol=1e-9 ...\n", base.wall);
  std::fflush(stdout);
  RunCapture ctrl = run_ladder(1e-9, part, bcs, tip, rules, material, use_box ? &box : nullptr);
  std::printf("      done in %.1fs.\n", ctrl.wall);

  write_periter_csv(dir + "/periter_cg1e-8.csv", base, 1e-8);
  write_periter_csv(dir + "/periter_cg1e-9.csv", ctrl, 1e-9);

  // Q0 floor: terminal class-change fraction baseline-vs-control, per rung.
  std::printf("\n[Q0] NEGATIVE-CONTROL BASIN FLOOR (1e-8 vs 1e-9 terminal design, per rung)\n");
  std::printf("     grid=%dx%dx%d solved-solid=%lld\n", base.solved_nx, base.solved_ny,
              base.solved_nz, base.solved_solid);
  double floor = 0.0, floor_mean = 0.0;
  const std::size_t nr = std::min(base.rung_terminal.size(), ctrl.rung_terminal.size());
  const VoxelGrid& solved = base.solved_grid;  // grid the optimizer solved on (part or box)
  for (std::size_t i = 0; i < nr; ++i) {
    if (base.rung_terminal[i].empty() || ctrl.rung_terminal[i].empty()) continue;
    double mean_d, max_d;
    const double cf = terminal_class_frac(solved, base.rung_terminal[i], ctrl.rung_terminal[i],
                                          mean_d, max_d);
    std::printf("     rung %zu vf=%.2f : class_change_frac=%.3e  mean|drho|=%.3e  max|drho|=%.3e"
                "   base_iters=%d ctrl_iters=%d\n",
                i, base.rung_vf.size() > i ? base.rung_vf[i] : 0.0, cf, mean_d, max_d,
                base.rung_iters.size() > i ? base.rung_iters[i] : -1,
                ctrl.rung_iters.size() > i ? ctrl.rung_iters[i] : -1);
    floor = std::max(floor, cf); floor_mean = std::max(floor_mean, mean_d);
  }
  std::printf("     => BASIN FLOOR (max over rungs): class_change_frac=%.3e  mean|drho|=%.3e\n",
              floor, floor_mean);

  // Q1: per rung, when did the design STOP CHANGING MATERIALLY (class_frac < floor
  // for the rest of the rung), vs where the rung actually stopped.
  std::printf("\n[Q1] STOPPING GAP — material-settle iteration vs actual stop, floor=%.3e\n", floor);
  std::printf("     rung  vf   actual_stop  material_settle  GAP  iters_after_settle  last_class_frac\n");
  for (std::size_t i = 0; i < base.rung_iters.size(); ++i) {
    int settle = 0, last = 0, after = 0; double lastcf = -1.0;
    analyse_rung(base, (int)i, floor, settle, last, after, lastcf);
    const int actual = base.rung_iters[i];
    std::printf("     %zu    %.2f    %3d          %3d              %3d     %3d                 %.3e  %s\n",
                i, base.rung_vf[i], actual, settle, actual - settle, after, lastcf,
                (actual - settle) > 0 ? "" : "(still moving at last iter)");
  }

  std::printf("\n[done] CSVs in %s\n", dir.c_str());
  return 0;
}
