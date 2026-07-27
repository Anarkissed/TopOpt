// adaptive_move_probe.cpp — ADAPTIVE MOVE LIMIT, PHASE 1 (measurement).
//
// Handoff 193 measured the MMA move limit PINNED at the fixed 0.2 in 24-36% of
// outer iterations (early forming phase + high-β stages) and named the adaptive
// move limit as the Phase-1 lever. This probe measures whether making the move
// adaptive (SimpOptions::adaptive_move, reusing the Svanberg oscillation sign)
// actually cuts outer iterations WITHOUT changing the certified part or the gate.
//
// It drives the ACTUAL production configuration (configure_production_options:
// matrix-free MG, min_feature 2.5 mm, MMA, conditional gray-gate projection,
// Krylov recycle, AUTO active-domain band) on the production ladder
// {0.68,0.52,0.38,0.26}, through the same READ-ONLY observer hooks that make a
// captured run byte-identical to an uncaptured one (handoff 114).
//
// Three runs per grid:
//   FIXED   — adaptive_move OFF, cg_tolerance 1e-8   (the shipping path)
//   CONTROL — adaptive_move OFF, cg_tolerance 1e-9   (M2 negative control: the
//             basin noise floor, tight-vs-tighter; every design difference below
//             is reported RELATIVE to it)
//   ADAPT   — adaptive_move ON,  cg_tolerance 1e-8   (the change under test)
//
// Bars reported (task 2026-07-26-adaptive-move):
//   M2 basin floor (FIXED vs CONTROL terminal class-change fraction, per rung)
//   M3 outer-iteration count per rung, FIXED vs ADAPT (the 20% bar)
//   M4 terminal design match: fraction of solid voxels changing classification
//      ADAPT vs FIXED, against the M2 floor (grid dims + solid count every row)
//   M5 gate verdicts (accepted + worst-case margin) per rung, FIXED vs ADAPT
//   M6 destabilization: move span, oscillation, plateau-firing iteration
//   M7 run this at three grid sizes (invoke with different OP_* env)
//
// Build (standalone; NOT wired into CTest):
//   c++ -std=c++17 -O2 -I include -I /opt/homebrew/include/eigen3 \
//     -DSETTINGS_RULES_PATH="\"$PWD/src/settings/rules.json\"" \
//     tests/harness/adaptive_move_probe.cpp build/libtopopt.a -o adaptive_move_probe
// Run:  AM_CSV_DIR=<dir> ./adaptive_move_probe
// Grid is env-tunable: OP_SPAN / OP_NY / OP_ARM / OP_T / OP_H (defaults below);
// OP_BOX=1 wraps the part in a whole-domain design box (the dilute marathon
// regime), OP_BOXMULT sets its x/z multiple (default 1.33).

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

int envi(const char* k, int d) { const char* v = std::getenv(k); return v ? std::atoi(v) : d; }
double envf(const char* k, double d) { const char* v = std::getenv(k); return v ? std::atof(v) : d; }

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

struct IterRec {
  int rung = 0, iter = 0;
  double compliance = 0.0, change = 0.0, beta = 0.0, move = 0.0, osc = -1.0;
  bool plateau = false;
};

struct RunCapture {
  std::vector<IterRec> recs;
  std::vector<std::vector<double>> rung_terminal;
  std::vector<int> rung_iters;
  std::vector<double> rung_vf, rung_margin, rung_compliance;
  std::vector<int> rung_accepted;
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

// fraction of solid voxels whose printed/void classification differs between two
// grid-indexed physical fields (+ mean/max |drho|), over the grid's SOLID voxels.
void field_delta(const VoxelGrid& g, const std::vector<double>& a,
                 const std::vector<double>& b, double& max_d, double& mean_d,
                 double& class_frac, long long& solid_out) {
  long long solid = 0, flipped = 0;
  double md = 0.0, sum = 0.0;
  for (int k = 0; k < g.nz; ++k)
    for (int j = 0; j < g.ny; ++j)
      for (int i = 0; i < g.nx; ++i) {
        if (!g.solid(i, j, k)) continue;
        const std::size_t e = g.index(i, j, k);
        ++solid;
        const double d = std::fabs(a[e] - b[e]);
        md = std::max(md, d); sum += d;
        if ((a[e] > kIso) != (b[e] > kIso)) ++flipped;
      }
  solid_out = solid;
  max_d = md;
  mean_d = solid ? sum / double(solid) : 0.0;
  class_frac = solid ? double(flipped) / double(solid) : 0.0;
}

RunCapture run_ladder(double cg_tol, bool adaptive, const VoxelGrid& part,
                      const std::vector<DirichletBC>& bcs,
                      const std::vector<NodalLoad>& loads, const SettingsRules& rules,
                      const Material& material, const DesignBox* box) {
  MinimizePlasticOptions o;
  configure_production_options(o);
  o.volume_fraction_ladder = production_reduction_ladder();
  o.margin_stop = 1.5;
  o.external_loads = loads;
  o.gravity = 9810.0 * 1e-9;
  o.gravity_direction = Vec3{0.0, 0.0, -1.0};
  o.infill_percent = 100.0;
  if (box) o.design_box = *box;
  o.simp.cg_tolerance = cg_tol;
  o.simp.adaptive_move = adaptive;  // the ONLY knob the change under test toggles

  RunCapture cap;
  o.on_iteration = [&](std::size_t rung, std::size_t, const SimpIterationObservation& ob) {
    IterRec* r = find_or_make(cap, (int)rung, ob.iteration);
    r->compliance = ob.compliance; r->change = ob.change; r->beta = ob.beta;
    r->move = ob.move; r->osc = ob.osc_fraction; r->plateau = ob.plateau;
  };
  o.on_density_snapshot = [&](const DensitySnapshotEvent& ev) {
    if (!ev.density || !ev.grid) return;
    const std::size_t rung = ev.rung_index;
    if (ev.boundary) {
      if (cap.rung_terminal.size() <= rung) cap.rung_terminal.resize(rung + 1);
      cap.rung_terminal[rung] = *ev.density;
      if (cap.solved_solid == 0) {
        cap.solved_nx = ev.grid->nx; cap.solved_ny = ev.grid->ny; cap.solved_nz = ev.grid->nz;
        cap.solved_solid = (long long)ev.grid->solid_count();
        cap.solved_grid = *ev.grid;
      }
    }
  };

  const auto t0 = std::chrono::steady_clock::now();
  const MinimizePlasticResult res = minimize_plastic(part, material, "fdm", bcs, rules, o);
  cap.wall = std::chrono::duration<double>(std::chrono::steady_clock::now() - t0).count();
  for (const auto& v : res.evaluated) {
    cap.rung_iters.push_back(v.optimization.iterations);
    cap.rung_vf.push_back(v.optimization.volume_fraction);
    cap.rung_margin.push_back(v.report.margin.worst_case);
    cap.rung_compliance.push_back(v.optimization.compliance);
    cap.rung_accepted.push_back(v.accepted ? 1 : 0);
  }
  return cap;
}

// Per-rung move/oscillation summary of an ADAPT run (M6).
struct MoveStats { double mn = 1e9, mx = 0.0, mean = 0.0; int n = 0; double osc_mean = 0.0; int osc_n = 0; int plateau_iter = -1; };
MoveStats move_stats(const RunCapture& c, int rung) {
  MoveStats s;
  for (const IterRec& r : c.recs) {
    if (r.rung != rung) continue;
    s.mn = std::min(s.mn, r.move); s.mx = std::max(s.mx, r.move);
    s.mean += r.move; ++s.n;
    if (r.osc >= 0.0) { s.osc_mean += r.osc; ++s.osc_n; }
    if (r.plateau && s.plateau_iter < 0) s.plateau_iter = r.iter;
  }
  if (s.n) s.mean /= s.n;
  if (s.osc_n) s.osc_mean /= s.osc_n;
  if (s.n == 0) s.mn = 0.0;
  return s;
}

void write_csv(const std::string& path, const RunCapture& c, const char* tag) {
  std::FILE* f = std::fopen(path.c_str(), "w");
  if (!f) { std::fprintf(stderr, "WARN: cannot write %s\n", path.c_str()); return; }
  std::fprintf(f, "tag,rung,iter,compliance,change,beta,move,osc_fraction,plateau\n");
  for (const IterRec& r : c.recs)
    std::fprintf(f, "%s,%d,%d,%.8g,%.6g,%.3g,%.6g,%.6g,%d\n",
                 tag, r.rung, r.iter, r.compliance, r.change, r.beta, r.move, r.osc, r.plateau);
  std::fclose(f);
  std::printf("  [wrote %s]\n", path.c_str());
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
  const std::string dir = std::getenv("AM_CSV_DIR") ? std::getenv("AM_CSV_DIR") : ".";

  const int span = envi("OP_SPAN", 24), ny = envi("OP_NY", 8),
            arm = envi("OP_ARM", 24), t = envi("OP_T", 6);
  const double h = envf("OP_H", 2.0);
  std::vector<DirichletBC> bcs;
  VoxelGrid part = l_bracket(bcs, arm, span, ny, t, h);
  const std::vector<NodalLoad> tip =
      traction_loads(part, VoxelTag::Load, Vec3{0.0, 0.0, -30.0});

  DesignBox box; bool use_box = envi("OP_BOX", 0) != 0;
  const double bm = envf("OP_BOXMULT", 1.33);
  if (use_box) { box.min = Vec3{0,0,0}; box.max = Vec3{span*h*bm, ny*h, arm*h*bm}; }
  const DesignBox* bp = use_box ? &box : nullptr;

  std::printf("== ADAPTIVE MOVE PHASE 1 ==  L-bracket %s  part-grid=%dx%dx%d  "
              "solid=%zu  h=%.1fmm  ladder={0.68,0.52,0.38,0.26}  MMA+matfreeMG (production)\n",
              use_box ? "DESIGN-BOX (dilute)" : "loadcase", part.nx, part.ny, part.nz,
              part.solid_count(), h);

  std::printf("\n[run] FIXED (adaptive OFF, cg 1e-8) ...\n"); std::fflush(stdout);
  RunCapture fixed = run_ladder(1e-8, false, part, bcs, tip, rules, material, bp);
  std::printf("      %.1fs.  CONTROL (adaptive OFF, cg 1e-9) ...\n", fixed.wall); std::fflush(stdout);
  RunCapture ctrl = run_ladder(1e-9, false, part, bcs, tip, rules, material, bp);
  std::printf("      %.1fs.  ADAPT (adaptive ON, cg 1e-8) ...\n", ctrl.wall); std::fflush(stdout);
  RunCapture adapt = run_ladder(1e-8, true, part, bcs, tip, rules, material, bp);
  std::printf("      %.1fs.\n", adapt.wall);

  write_csv(dir + "/periter_fixed.csv", fixed, "fixed");
  write_csv(dir + "/periter_adapt.csv", adapt, "adapt");

  const VoxelGrid& g = fixed.solved_grid;
  const std::size_t nr = fixed.rung_iters.size();

  // M2 — negative-control basin floor (FIXED vs CONTROL).
  std::printf("\n[M2] BASIN FLOOR — FIXED(1e-8) vs CONTROL(1e-9) terminal design\n");
  std::printf("     solved grid=%dx%dx%d  solid=%lld\n", g.nx, g.ny, g.nz, fixed.solved_solid);
  double floor = 0.0;
  for (std::size_t i = 0; i < nr && i < ctrl.rung_terminal.size(); ++i) {
    if (fixed.rung_terminal[i].empty() || ctrl.rung_terminal[i].empty()) continue;
    double md, mean, cf; long long sc;
    field_delta(g, fixed.rung_terminal[i], ctrl.rung_terminal[i], md, mean, cf, sc);
    std::printf("     rung %zu vf=%.2f : class_frac=%.3e  mean|drho|=%.3e  max|drho|=%.3e  (solid=%lld)\n",
                i, fixed.rung_vf[i], cf, mean, md, sc);
    floor = std::max(floor, cf);
  }
  std::printf("     => BASIN FLOOR (max class_frac over rungs) = %.3e\n", floor);

  // M3 — outer-iteration count per rung, FIXED vs ADAPT.
  std::printf("\n[M3] OUTER ITERATIONS per rung — FIXED vs ADAPT (bar: >=20%% fewer)\n");
  std::printf("     rung  vf    fixed  adapt   delta   pct\n");
  int tot_f = 0, tot_a = 0;
  for (std::size_t i = 0; i < nr; ++i) {
    const int fi = fixed.rung_iters[i];
    const int ai = i < adapt.rung_iters.size() ? adapt.rung_iters[i] : -1;
    tot_f += fi; if (ai >= 0) tot_a += ai;
    const double pct = fi > 0 ? 100.0 * (fi - ai) / fi : 0.0;
    std::printf("     %zu     %.2f  %4d   %4d   %+4d   %+.1f%%\n", i, fixed.rung_vf[i], fi, ai, fi - ai, pct);
  }
  std::printf("     Σ           %4d   %4d   %+4d   %+.1f%%\n", tot_f, tot_a, tot_f - tot_a,
              tot_f > 0 ? 100.0 * (tot_f - tot_a) / tot_f : 0.0);

  // M4 — terminal design match ADAPT vs FIXED, against the M2 floor.
  std::printf("\n[M4] TERMINAL DESIGN — ADAPT vs FIXED class-change fraction (floor=%.3e)\n", floor);
  std::printf("     rung  vf    class_frac   mean|drho|   max|drho|   solid   verdict\n");
  for (std::size_t i = 0; i < nr && i < adapt.rung_terminal.size(); ++i) {
    if (fixed.rung_terminal[i].empty() || adapt.rung_terminal[i].empty()) continue;
    double md, mean, cf; long long sc;
    field_delta(g, fixed.rung_terminal[i], adapt.rung_terminal[i], md, mean, cf, sc);
    std::printf("     %zu     %.2f  %.3e   %.3e   %.3e   %5lld   %s\n", i, fixed.rung_vf[i],
                cf, mean, md, sc, cf <= floor ? "== within floor" : "DIFFERS (> floor)");
  }

  // M5 — gate verdicts (accepted + worst-case margin) per rung.
  std::printf("\n[M5] GATE VERDICTS per rung — FIXED vs ADAPT (must be identical)\n");
  std::printf("     rung  vf    fixed(acc,margin)   adapt(acc,margin)   match\n");
  for (std::size_t i = 0; i < nr; ++i) {
    const int fa = fixed.rung_accepted[i], aa = i < adapt.rung_accepted.size() ? adapt.rung_accepted[i] : -1;
    const double fm = fixed.rung_margin[i], amg = i < adapt.rung_margin.size() ? adapt.rung_margin[i] : -1;
    std::printf("     %zu     %.2f  (%d, %.3f)          (%d, %.3f)          %s\n",
                i, fixed.rung_vf[i], fa, fm, aa, amg, fa == aa ? "verdict OK" : "VERDICT DIFFERS");
  }

  // M6 — destabilization: move span / oscillation / plateau-firing iteration.
  std::printf("\n[M6] STABILITY — ADAPT move span, mean oscillation, plateau-firing iter (vs FIXED iters)\n");
  std::printf("     rung  vf    move[min..max] (mean)     osc_mean   adapt_iters  fixed_iters\n");
  for (std::size_t i = 0; i < nr; ++i) {
    MoveStats s = move_stats(adapt, (int)i);
    const int ai = i < adapt.rung_iters.size() ? adapt.rung_iters[i] : -1;
    std::printf("     %zu     %.2f  [%.3f..%.3f] (%.3f)   %.3f      %4d         %4d\n",
                i, fixed.rung_vf[i], s.mn, s.mx, s.mean, s.osc_mean, ai, fixed.rung_iters[i]);
  }

  std::printf("\n[done] CSVs in %s\n", dir.c_str());
  return 0;
}
