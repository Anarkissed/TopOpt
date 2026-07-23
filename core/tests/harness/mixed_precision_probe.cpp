// mixed_precision_probe.cpp — measurement harness (NOT a CI test) for handoff 132.
//
// THE GATE for the MIXED-PRECISION production flip (113 §D): prove the FP32 V-cycle
// preconditioner costs NO ITERATION-COUNT REGRESSION on a full production ladder,
// in BOTH phases the conditional-projection gate (123) produces.
//
// Why iteration count is the gate and not wall-clock. Mixed precision does not
// change what CG converges to — the outer solver, its true residual and its
// convergence test are FP64, so the only thing a sloppier preconditioner can spend
// is ITERATIONS. That makes the iteration count the exact quantity at risk, and it
// is DETERMINISTIC: captured once, exact, immune to the ±30% thermal band that
// makes wall-clock unquotable on this box (113 §Thermals). Wall-clock is still
// reported, as the median of interleaved repeats with its min/max band, but the
// iteration ratio is the claim.
//
// FOUR MODES, fully crossed and INTERLEAVED (fp64/fp32 × gate/forced) so thermal
// drift cannot bias one precision:
//   gate-fp64   : production config, conditional threshold 0.07  — the shipping baseline.
//   gate-fp32   : same + mixed precision            — the flip, natural gate behaviour.
//   forced-fp64 : conditional threshold ~0 (projection fires on EVERY rung).
//   forced-fp32 : same + mixed precision.
// The "forced" pair exists because the gate's whole point is that projection fires
// only on gray rungs: if the fixture happens to converge crisp, the natural pair
// would measure the grayscale phase ONLY and the gate would be vacuous on the
// fired-projection phase. Forcing the threshold to ~0 guarantees the projected
// phase is measured under both precisions. Every mode reports iterations split by
// phase using the per-iteration observer's beta (123): beta == 0 is the GRAY phase,
// beta > 0 is the FIRED-PROJECTION phase.
//
// It also reports the multigrid share (cg_used_multigrid) per mode, because mixed
// precision lives ONLY in the matrix-free multigrid V-cycle: a run that fell back
// to Jacobi-CG would show a flat, meaningless "no regression" and the gate would
// prove nothing. mg_frac must be non-trivial for the row to count.
//
// Build (standalone; NOT wired into CTest):
//   c++ -std=c++17 -O2 -I include -I /opt/homebrew/include/eigen3 \
//     -DSETTINGS_RULES_PATH="\"$PWD/src/settings/rules.json\"" \
//     tests/harness/mixed_precision_probe.cpp build/libtopopt.a -o mixed_precision_probe

#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstdio>
#include <cstdlib>
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

// Wall repeats. rep 0 supplies ALL the deterministic data (iterations, CG iters,
// margins, designs); rep 1 is the determinism self-check; further reps only widen
// the wall-clock band, which is explicitly NOT the claim here (113 §Thermals). 2 is
// the minimum that keeps every guarantee; override with TOPOPT_MP_PROBE_REPS.
int reps() {
  const char* v = std::getenv("TOPOPT_MP_PROBE_REPS");
  const int n = v ? std::atoi(v) : 2;
  return n >= 2 ? n : 2;
}

// The L-bracket the 080/082/ladder gates build (test_ladder_rung_count /
// cg_tol_probe), parameterised so this probe can run it at a MULTIGRID-CAPABLE
// scale. The 8x8x3 tiny variant the sibling probes use cannot coarsen, so it would
// fall back to Jacobi-CG and never execute a V-cycle at all.
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

double max_abs_diff(const std::vector<double>& a, const std::vector<double>& b) {
  if (a.size() != b.size() || a.empty()) return -1.0;
  double m = 0.0;
  for (std::size_t i = 0; i < a.size(); ++i) m = std::max(m, std::fabs(a[i] - b[i]));
  return m;
}
double mean_abs_diff(const std::vector<double>& a, const std::vector<double>& b) {
  if (a.size() != b.size() || a.empty()) return -1.0;
  double s = 0.0;
  for (std::size_t i = 0; i < a.size(); ++i) s += std::fabs(a[i] - b[i]);
  return s / static_cast<double>(a.size());
}
double median(std::vector<double> v) {
  std::sort(v.begin(), v.end());
  return v.empty() ? 0.0 : v[v.size() / 2];
}

// Per-rung tallies, split by the conditional gate's two phases via observed beta.
struct RungRow {
  double vf = 0.0;
  int iters = 0;             // outer MMA iterations (total)
  int gray_iters = 0;        // iterations with beta == 0 (GRAY phase)
  int proj_iters = 0;        // iterations with beta >  0 (FIRED-PROJECTION phase)
  long long cg_iters = 0;    // summed trajectory CG iters (total)
  long long gray_cg = 0;     // ... in the gray phase
  long long proj_cg = 0;     // ... in the fired-projection phase
  long long mg_steps = 0;    // steps whose solve actually ran MG-CG
  long long steps = 0;       // steps observed
  double achieved = 0.0;
  double margin = 0.0;
  double compliance = 0.0;
  bool accepted = false;
  bool projection_fired = false;
  std::vector<double> density;
};

struct ModeResult {
  std::vector<RungRow> rungs;
  std::vector<double> terminal_density;
  double wall_median = 0.0, wall_min = 0.0, wall_max = 0.0;
  int total_iters = 0, gray_iters = 0, proj_iters = 0;
  long long total_cg = 0, gray_cg = 0, proj_cg = 0;
  long long mg_steps = 0, steps = 0;
  double repeat_max_drho = 0.0;  // determinism self-check (rep0 vs rep1) — must be 0
};

// One deterministic run + reps() wall repeats under the ACTUAL production config.
// `mixed` is the flip under test; `mnd_threshold` selects gate vs forced.
ModeResult run_mode(bool mixed, double mnd_threshold, const VoxelGrid& part,
                    const std::vector<DirichletBC>& bcs,
                    const std::vector<NodalLoad>& loads,
                    const SettingsRules& rules, const Material& material) {
  auto make_opts = [&]() {
    MinimizePlasticOptions o;
    configure_production_options(o);   // matrix-free MG + cache + threads + precision
    o.volume_fraction_ladder = production_reduction_ladder();
    o.margin_stop = 1.5;
    o.external_loads = loads;
    o.gravity = 9810.0 * 1e-9;
    o.gravity_direction = Vec3{0.0, 0.0, -1.0};
    o.infill_percent = 100.0;
    o.conditional_mma_projection_mnd_threshold = mnd_threshold;
    return o;
  };

  ModeResult mr;
  std::vector<double> walls;
  for (int rep = 0; rep < reps(); ++rep) {
    MinimizePlasticOptions o = make_opts();
    // The ONE toggled knob. configure_production_options now arms mixed precision,
    // so the FP64 baseline is produced by explicitly turning it back OFF — i.e. the
    // baseline is the pre-flip production path, reproduced exactly.
    fea_set_matfree_mixed_precision(mixed);
    // The 127 per-run stagnation latch is thread-local and STICKY: reset it at the
    // start of every run, or a latched earlier mode silently changes a later one.
    fea_matfree_reset_mg_stagnation_latch();

    std::vector<RungRow> live;
    o.on_iteration = [&](std::size_t rung, std::size_t /*count*/,
                         const SimpIterationObservation& obs) {
      if (rung >= live.size()) live.resize(rung + 1);
      RungRow& row = live[rung];
      row.cg_iters += obs.cg_iterations;
      row.steps += 1;
      if (obs.cg_used_multigrid) row.mg_steps += 1;
      if (obs.beta > 0.0) {          // 123: beta > 0 <=> this step is PROJECTING
        row.proj_iters += 1;
        row.proj_cg += obs.cg_iterations;
        row.projection_fired = true;
      } else {
        row.gray_iters += 1;
        row.gray_cg += obs.cg_iterations;
      }
    };

    const auto t0 = std::chrono::steady_clock::now();
    const MinimizePlasticResult r =
        minimize_plastic(part, material, "fdm", bcs, rules, o);
    const auto t1 = std::chrono::steady_clock::now();
    walls.push_back(std::chrono::duration<double>(t1 - t0).count());

    if (rep == 0) {
      for (std::size_t i = 0; i < r.evaluated.size(); ++i) {
        const auto& v = r.evaluated[i];
        RungRow row = i < live.size() ? live[i] : RungRow{};
        row.vf = v.requested_volume_fraction;
        row.iters = v.optimization.iterations;
        row.achieved = v.optimization.volume_fraction;
        row.margin = v.report.margin.worst_case;
        row.compliance = v.optimization.compliance;
        row.accepted = v.accepted;
        row.density = v.optimization.physical_density;
        mr.rungs.push_back(row);
        mr.total_iters += row.iters;
        mr.gray_iters += row.gray_iters;
        mr.proj_iters += row.proj_iters;
        mr.total_cg += row.cg_iters;
        mr.gray_cg += row.gray_cg;
        mr.proj_cg += row.proj_cg;
        mr.mg_steps += row.mg_steps;
        mr.steps += row.steps;
      }
      if (!r.evaluated.empty())
        mr.terminal_density = r.evaluated.back().optimization.physical_density;
    } else if (rep == 1 && !mr.terminal_density.empty() && !r.evaluated.empty()) {
      // A second run of the SAME mode must reproduce the terminal design bit for
      // bit, else the fp64-vs-fp32 comparison is measuring noise, not precision.
      mr.repeat_max_drho = max_abs_diff(
          mr.terminal_density, r.evaluated.back().optimization.physical_density);
    }
  }
  mr.wall_median = median(walls);
  mr.wall_min = *std::min_element(walls.begin(), walls.end());
  mr.wall_max = *std::max_element(walls.begin(), walls.end());
  return mr;
}

void print_mode(const char* name, const ModeResult& m) {
  const double mg_frac =
      m.steps > 0 ? double(m.mg_steps) / double(m.steps) : 0.0;
  std::printf("[%-11s] rungs=%zu iters=%d (gray=%d proj=%d)  cg=%lld (gray=%lld proj=%lld)"
              "  mg_frac=%.2f  wall=%.2fs (%.2f-%.2f, med of %d)  repeat_max|drho|=%.2e\n",
              name, m.rungs.size(), m.total_iters, m.gray_iters, m.proj_iters,
              m.total_cg, m.gray_cg, m.proj_cg, mg_frac, m.wall_median,
              m.wall_min, m.wall_max, reps(), m.repeat_max_drho);
  for (const RungRow& r : m.rungs)
    std::printf("     vf=%.2f iters=%3d (gray=%3d proj=%3d) cg=%6lld (gray=%6lld proj=%6lld)"
                " mg=%lld/%lld achieved=%.4f margin=%.3f C=%.6g %s%s\n",
                r.vf, r.iters, r.gray_iters, r.proj_iters, r.cg_iters, r.gray_cg,
                r.proj_cg, r.mg_steps, r.steps, r.achieved, r.margin, r.compliance,
                r.accepted ? "accept" : "REJECT",
                r.projection_fired ? " [proj FIRED]" : "");
}

// The gate verdict for one fp64/fp32 pair. The BAR: no iteration-count regression —
// per phase and in total — beyond a small tolerance, with identical accept/reject
// verdicts and a comparable design.
void compare(const char* tag, const ModeResult& a /*fp64*/, const ModeResult& b /*fp32*/) {
  auto ratio = [](long long base, long long other) {
    return base > 0 ? double(other) / double(base) : 0.0;
  };
  bool verdicts_identical = a.rungs.size() == b.rungs.size();
  const std::size_t n = std::min(a.rungs.size(), b.rungs.size());
  double worst_margin_delta_pct = 0.0, worst_mean_drho = 0.0, worst_C_delta = 0.0;
  int last_accepted = -1;
  for (std::size_t i = 0; i < n; ++i) {
    if (a.rungs[i].accepted != b.rungs[i].accepted) verdicts_identical = false;
    if (a.rungs[i].projection_fired != b.rungs[i].projection_fired)
      verdicts_identical = false;
    if (a.rungs[i].accepted && b.rungs[i].accepted) {
      last_accepted = static_cast<int>(i);
      const double ma = a.rungs[i].margin;
      worst_margin_delta_pct = std::max(
          worst_margin_delta_pct,
          100.0 * std::fabs(b.rungs[i].margin - ma) /
              (std::fabs(ma) > 1e-12 ? std::fabs(ma) : 1.0));
      worst_mean_drho = std::max(
          worst_mean_drho, mean_abs_diff(a.rungs[i].density, b.rungs[i].density));
      const double ca = a.rungs[i].compliance;
      worst_C_delta = std::max(worst_C_delta,
                               std::fabs(ca) > 1e-30
                                   ? 100.0 * std::fabs(b.rungs[i].compliance - ca) / ca
                                   : 0.0);
    }
  }
  double ship_mean = 0.0, ship_max = 0.0, ship_vf = 0.0;
  if (last_accepted >= 0) {
    ship_vf = a.rungs[last_accepted].vf;
    ship_mean = mean_abs_diff(a.rungs[last_accepted].density,
                              b.rungs[last_accepted].density);
    ship_max = max_abs_diff(a.rungs[last_accepted].density,
                            b.rungs[last_accepted].density);
  }
  std::printf("  %-8s ITER fp32/fp64: total=%.3fx gray=%.3fx proj=%.3fx | "
              "CG total=%.3fx gray=%.3fx proj=%.3fx | wall=%.2fx | gate=%s | "
              "SHIPPED vf=%.2f mean|drho|=%.5f max=%.3f | worst-acc mean|drho|=%.5f "
              "margin_delta=%.2f%% C_delta=%.2f%%\n",
              tag, ratio(a.total_iters, b.total_iters),
              ratio(a.gray_iters, b.gray_iters), ratio(a.proj_iters, b.proj_iters),
              ratio(a.total_cg, b.total_cg), ratio(a.gray_cg, b.gray_cg),
              ratio(a.proj_cg, b.proj_cg),
              b.wall_median > 0 ? a.wall_median / b.wall_median : 0.0,
              verdicts_identical ? "OK" : "DIFF", ship_vf, ship_mean, ship_max,
              worst_mean_drho, worst_margin_delta_pct, worst_C_delta);
}

void write_csv(const char* name, const std::vector<std::string>& mode_names,
               const std::vector<const ModeResult*>& modes) {
  const char* dir = std::getenv("TOPOPT_MP_PROBE_CSV_DIR");
  if (!dir) return;
  const std::string path = std::string(dir) + "/" + name;
  FILE* f = std::fopen(path.c_str(), "w");
  if (!f) { std::fprintf(stderr, "WARN: cannot write %s\n", path.c_str()); return; }
  std::fprintf(f, "mode,rung_index,vf,iters,gray_iters,proj_iters,cg_iters,gray_cg,"
                  "proj_cg,mg_steps,steps,achieved,margin,compliance,accepted,"
                  "projection_fired,wall_median,repeat_max_drho\n");
  for (std::size_t m = 0; m < modes.size(); ++m) {
    const ModeResult& mr = *modes[m];
    for (std::size_t i = 0; i < mr.rungs.size(); ++i) {
      const RungRow& r = mr.rungs[i];
      std::fprintf(f, "%s,%zu,%.2f,%d,%d,%d,%lld,%lld,%lld,%lld,%lld,%.4f,%.4f,"
                      "%.6g,%d,%d,%.3f,%.2e\n",
                   mode_names[m].c_str(), i, r.vf, r.iters, r.gray_iters,
                   r.proj_iters, r.cg_iters, r.gray_cg, r.proj_cg, r.mg_steps,
                   r.steps, r.achieved, r.margin, r.compliance, r.accepted ? 1 : 0,
                   r.projection_fired ? 1 : 0, mr.wall_median, mr.repeat_max_drho);
    }
  }
  std::fclose(f);
  std::printf("  [wrote %s]\n", path.c_str());
}

}  // namespace

int main(int argc, char** argv) {
  // Grid dims are settable so the gate can be re-run at another size. The DEFAULT
  // 48 x 16 x 48 is chosen to be MULTIGRID-CAPABLE, which the coarsener's rule makes
  // a real constraint: it halves only while EVERY axis is even and stays >= 2, so an
  // odd extent on any axis rejects the hierarchy outright and the solve silently
  // falls back to Jacobi-CG. 48/16/48 -> 24/8/24 -> 12/4/12, a 3-level hierarchy
  // whose coarsest level (13*5*13 nodes, 2535 DOF bound) is inside the 6000 DOF cap.
  // This matters more than usual here: mixed precision lives ONLY in the V-cycle, so
  // on a non-coarsenable grid the fp64 and fp32 runs are the SAME code path and the
  // gate would report a perfect, meaningless 1.000x. (Measured: an earlier
  // 16 x 5 x 16 attempt — ny=5 odd — did exactly that, mg_frac=0.00 across all four
  // modes.) The precondition below refuses to run rather than report that.
  const int arm  = argc > 1 ? std::atoi(argv[1]) : 48;
  const int ny   = argc > 2 ? std::atoi(argv[2]) : 16;
  const int t    = argc > 3 ? std::atoi(argv[3]) : 12;
  const int span = arm;
  const double h = 2.0;

  if (!mg_grid_coarsenable(span, ny, arm)) {
    std::fprintf(stderr,
                 "FAIL: grid %dx%dx%d is NOT multigrid-coarsenable, so the FP32\n"
                 "      V-cycle would never execute and this gate would be vacuous.\n"
                 "      Every axis must be even (and stay >= 2 when halved).\n",
                 span, ny, arm);
    return 1;
  }

  SettingsRules rules;
  try {
    rules = load_settings_rules_file(SETTINGS_RULES_PATH);
  } catch (const std::exception& e) {
    std::fprintf(stderr, "FAIL: could not load rules.json: %s\n", e.what());
    return 1;
  }
  const Material material = fdm_material();

  std::vector<DirichletBC> bcs;
  VoxelGrid part = l_bracket(bcs, arm, span, ny, t, h);
  const std::vector<NodalLoad> tip =
      traction_loads(part, VoxelTag::Load, Vec3{0.0, 0.0, -30.0});

  std::printf("===== L-BRACKET LOADCASE (grid %dx%dx%d, %zu solid voxels, h=%.1fmm) =====\n",
              part.nx, part.ny, part.nz, part.solid_count(), h);
  // CONFIG ECHO — read AFTER arming, so this prints the state the runs below
  // actually execute under (reading it before configure_production_options would
  // report the library defaults and mislead).
  {
    MinimizePlasticOptions echo;
    configure_production_options(echo);
    std::printf("production config: threads=%d (production_matfree_thread_count=%d)"
                "  galerkin_cache=%d  mixed_precision=%d\n",
                fea_matfree_thread_count(), production_matfree_thread_count(),
                fea_matfree_galerkin_block_cache_enabled() ? 1 : 0,
                fea_matfree_mixed_precision_enabled() ? 1 : 0);
  }

  // INTERLEAVED so thermal drift cannot bias one precision: fp64,fp32,fp64,fp32.
  const double kGate = 0.07;   // the production conditional threshold (123)
  const double kForced = 1e-9; // fires projection on EVERY rung
  const ModeResult gate64   = run_mode(false, kGate,   part, bcs, tip, rules, material);
  const ModeResult gate32   = run_mode(true,  kGate,   part, bcs, tip, rules, material);
  const ModeResult forced64 = run_mode(false, kForced, part, bcs, tip, rules, material);
  const ModeResult forced32 = run_mode(true,  kForced, part, bcs, tip, rules, material);

  print_mode("gate-fp64",   gate64);
  print_mode("gate-fp32",   gate32);
  print_mode("forced-fp64", forced64);
  print_mode("forced-fp32", forced32);

  std::printf("\n  --- GATE: fp32/fp64 iteration ratio (bar: no regression, gate verdicts OK) ---\n");
  compare("gate",   gate64,   gate32);
  compare("forced", forced64, forced32);

  write_csv("mixed_precision_ladder.csv",
            {"gate-fp64", "gate-fp32", "forced-fp64", "forced-fp32"},
            {&gate64, &gate32, &forced64, &forced32});
  return 0;
}
