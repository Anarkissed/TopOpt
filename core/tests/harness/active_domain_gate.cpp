// active_domain_gate.cpp — the measurement harness for ACTIVE DOMAIN phase 1
// (docs/handoffs/2026-07-23-active-domain-phase-1.md). NOT a CI test; standalone,
// like its neighbours cg_tol_probe.cpp / mma_probe.cpp / active_domain_probe.cpp.
//
// It exists because the Phase 0 handoff (134) closed with two measurements it
// could not afford, and made BOTH gating for any production flip:
//
//   STEP 1 — THE SHARED CAPTURE. One CONVERGED, FULL-LENGTH, ultra-dilute run of
//     the real production driver (configure_production_options + the production
//     reduction ladder + MMA + matrix-free multigrid), with the 117 observability
//     flags on: per-iteration CSV, density snapshots, run_info.json. Handoff 134
//     §1c/§5 names its absence "the single biggest gap": both of its real CLI
//     captures at 1.7% fill were compromised (one by the 125 stagnation at ~3
//     min/iteration, one by under-resolution), so its only ultra-dilute evidence
//     was a harness OC loop, not a driver MMA ladder.
//
//   STEP 2 — THE GATE. The SAME fixture run with the band ON (k = 4) and OFF,
//     each TWICE, compared in memory at full double precision: design motion
//     (mean/max |drho|), certified compliance and margin, gate verdicts, and the
//     honest cost accounting (wall clock AND CG iterations, so the 1.4-2.0x
//     CG-iteration penalty 134 §4a discovered is charged, not hidden).
//
// WHY IN ONE PROCESS. The design-motion comparison is the whole gate and it lives
// at ~1e-6; the committed density snapshots are float16 (~5e-4 quantisation), so
// a post-hoc comparison from disk could not see it. The four runs therefore
// happen here, and the |drho| is computed on the driver's own double vectors.
//
// THE FIXTURE. The l-bracket voxel part of handoff 134's probe (24x6x24 grid,
// 528 solid voxels) inside a design box that expands the analysis grid to
// 32x24x32 = 24 576 elements — 2.15% part fill, 46.5x dilution: the SAME
// ultra-dilute CLASS 134 measured its 49x correctness numbers on, now driven
// through minimize_plastic instead of a harness OC loop. It is a synthetic part
// rather than a STEP import for one reason: at this dilution a STEP-imported
// l-bracket needs either a 0.9M-element grid (to keep the filter radius above
// its 1.5-voxel floor) or a grid too coarse to represent its 8 mm plate — 134
// §1c hit exactly that wall, twice. Everything downstream of the part is the
// production driver, unmodified.
//
// Build (standalone; NOT wired into CTest):
//   c++ -std=c++17 -O2 -I core/include -I /opt/homebrew/include/eigen3 \
//     -DSETTINGS_RULES_PATH="\"$PWD/core/src/settings/rules.json\"" \
//     core/tests/harness/active_domain_gate.cpp build/libtopopt.a -o /tmp/adg
// Run (TOPOPT_AD_DIR selects the evidence directory; default ./ad_evidence):
//   probe          fixture dims / fill / dilution + a 6-iteration timing sample
//   capture        STEP 1 only: the shared capture (band OFF, snapshots on)
//   gate           STEP 2 only: OFF x2 vs ON x2, no snapshots
//   length [N]     rung 0 with the 086 plateau DISARMED, N iterations (default
//                  250), ON vs OFF: |drho| as a FUNCTION of iteration — the
//                  accumulation axis 134 §2d could only extrapolate
//   all            capture then gate

#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <memory>
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
  const char* d = std::getenv("TOPOPT_AD_DIR");
  return d ? std::string(d) : std::string("ad_evidence");
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

// The thin L-bracket of handoff 134's probe, verbatim (same shape as
// cg_tol_probe.cpp's fixture): a vertical arm and a horizontal span of thickness
// `t`, clamped across the arm's top, loaded at the span's tip.
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
};

Fixture make_fixture() {
  Fixture f;
  f.part = l_bracket(f.bcs, /*arm*/ 14, /*span*/ 14, /*ny*/ 4, /*t*/ 6, /*h*/ 1.0);
  f.loads = traction_loads(f.part, VoxelTag::Load, Vec3{0.0, 0.0, -30.0});
  // Chosen so minimize_plastic's expansion lands on 32x24x32 = 24 576 elements
  // against the part's 528 solid voxels: 46.5x dilution, 2.15% fill — the 49x
  // CLASS handoff 134 measured its correctness numbers at. The part sits inside
  // the box, not at a face.
  //
  // WHY NOT BIGGER. 134's own 49x fixture is 73 728 elements, and this campaign
  // was FIRST run at exactly that size. It reproduces the 125 stagnation
  // immediately (measured: iterations 3/4/6 of rung 0 fall back to Jacobi-CG at
  // 5 056 / 12 746 / 17 151 CG iterations, ~25 s/iteration) — which is the honest
  // production regime and is REPORTED as such in the handoff, but puts four
  // full-length rungs plus a four-rung capture at ~11 h of wall clock. Element
  // count was traded down (~3x) to buy the FULL LENGTH the gate is stated on;
  // dilution, spacing (1.0 mm), the filter radius (rmin = 2.5 voxels, so auto
  // band = 4) and the entire production configuration are unchanged, and those
  // are the axes this feature's error and win both scale with (134 §2e/§4b).
  f.box.min = Vec3{-9.0, -10.0, -9.0};
  f.box.max = Vec3{23.0, 14.0, 23.0};
  return f;
}

// `single_rung` restricts the ladder to rung 0 (vf 0.68). The GATE is stated as
// "a FULL-LENGTH MMA rung at production dilution" — full LENGTH, one rung — and
// at this dilution one rung is already ~150 MMA iterations of a solve that the
// 125 stagnation drives into Jacobi-CG. The CAPTURE runs the whole ladder.
MinimizePlasticOptions base_options(const Fixture& f, int band,
                                    bool single_rung = false) {
  MinimizePlasticOptions o;
  configure_production_options(o);  // the PRODUCTION config, unmodified
  o.volume_fraction_ladder = production_reduction_ladder();
  if (single_rung) o.volume_fraction_ladder = {production_reduction_ladder()[0]};
  o.margin_stop = 1.5;
  o.external_loads = f.loads;
  o.gravity = 9810.0 * 1e-9;
  o.gravity_direction = Vec3{0.0, 0.0, -1.0};
  o.infill_percent = 100.0;
  o.design_box = f.box;
  o.simp.active_domain_band = band;  // 0 = OFF, 4 = the gate's band
  return o;
}

// Everything one ladder produced that the gate compares.
struct RunRecord {
  std::string label;
  double wall = 0.0;
  long long cg_total = 0;
  long long iters_total = 0;
  int mg_fallback_solves = 0;
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
  std::vector<std::string> rung_latch_reason;
  std::string terminal_recommendation;
};

// Run one ladder. `csv_path` (optional) receives the 117 per-iteration CSV;
// `snapshot_dir` (optional) receives float16 density snapshots.
RunRecord run_ladder(const char* label, const Fixture& f, int band,
                     const SettingsRules& rules, const Material& material,
                     const std::string& csv_path,
                     const std::string& snapshot_dir, int snapshot_every,
                     int snapshot_cap, const std::string& run_info_path,
                     bool single_rung = false) {
  MinimizePlasticOptions o = base_options(f, band, single_rung);

  RunRecord r;
  r.label = label;

  std::unique_ptr<IterationCsvWriter> csv;
  if (!csv_path.empty()) csv = std::make_unique<IterationCsvWriter>(csv_path);
  std::unique_ptr<SnapshotCapture> snaps;
  if (!snapshot_dir.empty())
    snaps = std::make_unique<SnapshotCapture>(snapshot_dir, snapshot_every,
                                              snapshot_cap);

  long long cg_total = 0, iters_total = 0;
  int fallbacks = 0;
  o.on_iteration = [&](std::size_t rung, std::size_t, const SimpIterationObservation& obs) {
    cg_total += obs.cg_iterations;
    ++iters_total;
    if (!obs.cg_used_multigrid) ++fallbacks;
    if (csv) csv->append(rung, obs);
  };
  if (snaps)
    o.on_density_snapshot = [&](const DensitySnapshotEvent& ev) {
      if (!ev.density || !ev.grid) return;
      snaps->capture(*ev.grid, *ev.density, ev.rung_index, ev.iteration,
                     ev.boundary);
    };

  const auto t0 = std::chrono::steady_clock::now();
  const MinimizePlasticResult res =
      minimize_plastic(f.part, material, "fdm", f.bcs, rules, o);
  r.wall = std::chrono::duration<double>(std::chrono::steady_clock::now() - t0).count();
  r.cg_total = cg_total;
  r.iters_total = iters_total;
  r.mg_fallback_solves = fallbacks;

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
    r.rung_latch_reason.push_back(v.optimization.active_domain_latch_reason);
  }
  if (!res.report.variants.empty())
  {
    const SlicerSettings& st = res.report.variants.back().settings;
    r.terminal_recommendation =
        st.family + " walls=" + std::to_string(st.walls) +
        " top=" + std::to_string(st.top_layers) +
        " bottom=" + std::to_string(st.bottom_layers) +
        " infill=" + std::to_string(st.infill_percent) + "%" + st.infill_pattern +
        (st.warning.empty() ? "" : " warning:" + st.warning);
  }

  if (!run_info_path.empty()) {
    RunInfo info;
    info.cli_version = version();
    info.fingerprint = "harness:active_domain_gate";
    info.mode = "minimize_plastic";
    info.material = "PLA-class fdm (harness Material)";
    info.resolution = res.solved_grid.nx;
    info.load_source = "loadcase";
    info.solver = "MultigridCG_Matfree";
    info.cg_multigrid = res.used_multigrid;
    info.mg_levels = 0;
    info.cg_multigrid_observed = true;
    info.mg_mode = res.used_multigrid
                       ? "carried"
                       : (res.mg_hierarchy_ever_built ? "stagnated-latched"
                                                      : "build-rejected");
    info.mg_mode_observed = true;
    info.galerkin_block_cache = fea_matfree_galerkin_block_cache_enabled();
    info.mixed_precision = fea_matfree_mixed_precision_enabled();
    info.matfree_threads = fea_matfree_thread_count();
    info.krylov_recycling = fea_krylov_recycling_enabled();
    info.krylov_recycle_dim = fea_krylov_recycle_dim();
    info.krylov_recycle_wrap_multigrid = fea_krylov_recycle_wrap_multigrid();
    info.projection = !o.simp.projection.empty();
    info.conditional_mma_projection_mnd_threshold =
        o.conditional_mma_projection_mnd_threshold;
    info.conditional_projection_fired.assign(
        res.conditional_projection_fired.begin(),
        res.conditional_projection_fired.end());
    info.conditional_projection_rung_mnd = res.rung_grayscale_mnd;
    info.infeasible_compliance_ratio = o.simp.infeasible_compliance_ratio;
    info.infeasible_cg_blowup = o.simp.infeasible_cg_blowup;
    info.infeasible_flat_tol = o.simp.infeasible_flat_tol;
    info.infeasible_window = o.simp.infeasible_window;
    info.rung_infeasible.assign(res.rung_infeasible.begin(),
                                res.rung_infeasible.end());
    info.active_domain_band = band;
    for (const MinimizePlasticVariant& v : res.evaluated) {
      info.active_domain_latched.push_back(
          v.optimization.active_domain_latched ? 1 : 0);
      info.active_domain_latch_reason.push_back(
          v.optimization.active_domain_latch_reason);
      info.active_domain_fraction_mean.push_back(
          v.optimization.active_fraction_mean);
    }
    info.min_feature_mm = o.min_feature_mm;
    info.margin_stop = o.margin_stop;
    info.infill_percent = o.infill_percent;
    info.has_design_box = true;
    info.ladder = o.volume_fraction_ladder;
    info.created_wall_ms = wall_clock_ms();
    info.iteration_csv = !csv_path.empty();
    info.density_snapshots = !snapshot_dir.empty();
    info.snapshot_every = snapshot_every;
    info.snapshot_cap = snapshot_cap;
    write_run_info(run_info_path, info);
  }

  std::printf("  [%s] %.1f s wall, %lld iterations, %lld CG iterations, "
              "%d Jacobi-fallback solves, %zu rungs\n",
              label, r.wall, r.iters_total, r.cg_total, r.mg_fallback_solves,
              r.rung_vf.size());
  for (std::size_t i = 0; i < r.rung_vf.size(); ++i)
    std::printf("    rung %zu vf=%.2f iters=%3d %s%s margin=%.4g "
                "printed=%.4f compliance=%.10g  f_bar=%.4f%s\n",
                i, r.rung_vf[i], r.rung_iterations[i],
                r.rung_accepted[i] ? "accept" : "REJECT",
                r.rung_infeasible[i] ? " INFEASIBLE" : "", r.rung_margin[i],
                r.rung_printed_fraction[i], r.rung_compliance[i],
                r.rung_active_fraction_mean[i],
                r.rung_latched[i] ? "  LATCHED" : "");
  return r;
}

struct Delta {
  double mean_abs = 0.0;
  double max_abs = 0.0;
};

Delta compare(const std::vector<double>& a, const std::vector<double>& b) {
  Delta d;
  if (a.size() != b.size() || a.empty()) return d;
  double s = 0.0;
  for (std::size_t e = 0; e < a.size(); ++e) {
    const double v = std::fabs(a[e] - b[e]);
    s += v;
    d.max_abs = std::max(d.max_abs, v);
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

void write_gate_csv(const std::string& path, const RunRecord& off,
                    const RunRecord& on) {
  FILE* fp = std::fopen(path.c_str(), "w");
  if (!fp) return;
  std::fprintf(fp,
               "rung,vf,off_iters,on_iters,off_compliance,on_compliance,"
               "compliance_rel_delta,off_margin,on_margin,margin_rel_delta,"
               "off_accepted,on_accepted,off_printed,on_printed,"
               "mean_abs_drho,max_abs_drho,on_f_bar,on_latched\n");
  const std::size_t n = std::min(off.rung_vf.size(), on.rung_vf.size());
  for (std::size_t i = 0; i < n; ++i) {
    const Delta d = compare(off.rung_density[i], on.rung_density[i]);
    const double crel =
        off.rung_compliance[i] != 0.0
            ? std::fabs(on.rung_compliance[i] - off.rung_compliance[i]) /
                  std::fabs(off.rung_compliance[i])
            : 0.0;
    const double mrel =
        std::isfinite(off.rung_margin[i]) && off.rung_margin[i] != 0.0
            ? std::fabs(on.rung_margin[i] - off.rung_margin[i]) /
                  std::fabs(off.rung_margin[i])
            : 0.0;
    std::fprintf(fp,
                 "%zu,%.4f,%d,%d,%.12g,%.12g,%.6e,%.10g,%.10g,%.6e,%d,%d,"
                 "%.6f,%.6f,%.6e,%.6e,%.6f,%d\n",
                 i, off.rung_vf[i], off.rung_iterations[i], on.rung_iterations[i],
                 off.rung_compliance[i], on.rung_compliance[i], crel,
                 off.rung_margin[i], on.rung_margin[i], mrel,
                 off.rung_accepted[i], on.rung_accepted[i],
                 off.rung_printed_fraction[i], on.rung_printed_fraction[i],
                 d.mean_abs, d.max_abs, on.rung_active_fraction_mean[i],
                 on.rung_latched[i]);
  }
  std::fclose(fp);
}

// ---------------------------------------------------------------------------
// LENGTH — the accumulation axis handoff 134 §2d could not close.
//
// 134 measured |drho| over 40 OC steps and said plainly that 40 is not a
// production rung (150-250) and that its linear extrapolation to 250 "is not
// enough to ship on". This runs rung 0 with the 086 objective-plateau terminator
// DISARMED and change_tol at 0, so the rung runs a FIXED, long count under MMA
// at production dilution, capturing every iteration's physical density from both
// postures. It reports mean/max |drho| AS A FUNCTION OF ITERATION — the growth
// curve itself, not an extrapolation of one — plus the growth-invariant escape
// count on the full-domain trajectory at the same length.
struct LengthRun {
  std::vector<std::vector<double>> field;  // per iteration, physical density
};

LengthRun run_length(const char* label, const Fixture& f, int band, int iters,
                     const SettingsRules& rules, const Material& material,
                     double& wall_out, long long& cg_out) {
  MinimizePlasticOptions o = base_options(f, band, /*single_rung=*/true);
  o.simp.mma_plateau_window = 0;  // disarm the 086 plateau: run the full count
  o.simp.change_tol = 0.0;        // ...and never stop on design change either
  o.simp.max_iterations = iters;
  LengthRun r;
  long long cg = 0;
  o.on_iteration = [&](std::size_t, std::size_t, const SimpIterationObservation& obs) {
    cg += obs.cg_iterations;
  };
  o.on_density_snapshot = [&](const DensitySnapshotEvent& ev) {
    if (!ev.density || ev.boundary) return;
    r.field.push_back(*ev.density);
  };
  const auto t0 = std::chrono::steady_clock::now();
  minimize_plastic(f.part, material, "fdm", f.bcs, rules, o);
  wall_out = std::chrono::duration<double>(std::chrono::steady_clock::now() - t0).count();
  cg_out = cg;
  std::printf("  [%s] %d captured iterations, %.1f s, %lld CG iterations\n", label,
              int(r.field.size()), wall_out, cg);
  return r;
}

}  // namespace

int main(int argc, char** argv) {
  std::setvbuf(stdout, nullptr, _IOLBF, 0);
  const std::string mode = argc > 1 ? argv[1] : "all";
  const std::string dir = evidence_dir();

  SettingsRules rules;
  try {
    rules = load_settings_rules_file(SETTINGS_RULES_PATH);
  } catch (const std::exception& e) {
    std::fprintf(stderr, "FAIL: rules.json: %s\n", e.what());
    return 1;
  }
  const Material material = fdm_material();
  const Fixture f = make_fixture();

  {
    MinimizePlasticOptions probe = base_options(f, 0);
    const VoxelGrid solved = minimize_plastic_solved_grid(f.part, probe);
    std::printf("===== FIXTURE =====\n");
    std::printf("  part %dx%dx%d (%zu solid voxels) -> analysis grid %dx%dx%d "
                "(%zu elements)\n  fill=%.3f%%  dilution=%.1fx  spacing=%.2f mm  "
                "min_feature=%.2f mm -> rmin=%.3f voxels  auto band=%d\n",
                f.part.nx, f.part.ny, f.part.nz, f.part.solid_count(), solved.nx,
                solved.ny, solved.nz, solved.solid_count(),
                100.0 * double(f.part.solid_count()) / double(solved.solid_count()),
                double(solved.solid_count()) / double(f.part.solid_count()),
                solved.spacing, probe.min_feature_mm,
                physical_filter_radius(probe.min_feature_mm, solved.spacing),
                active_domain_auto_band(
                    physical_filter_radius(probe.min_feature_mm, solved.spacing)));
    std::printf("  ladder:");
    for (double v : probe.volume_fraction_ladder) std::printf(" %.2f", v);
    std::printf("   matfree threads=%d\n", fea_matfree_thread_count());
  }

  if (mode == "probe") {
    // A short timing sample so the full campaign can be budgeted honestly.
    Fixture pf = f;
    MinimizePlasticOptions o = base_options(pf, 0);
    o.simp.max_iterations = 6;
    o.volume_fraction_ladder = {0.68};
    long long cg = 0, its = 0;
    int fb = 0;
    o.on_iteration = [&](std::size_t, std::size_t, const SimpIterationObservation& obs) {
      cg += obs.cg_iterations;
      ++its;
      if (!obs.cg_used_multigrid) ++fb;
      std::printf("    iter %2d  cg=%5d  mg=%d  hier=%d  cycles=%d  "
                  "active=%.4f  compliance=%.6g\n",
                  obs.iteration, obs.cg_iterations, obs.cg_used_multigrid ? 1 : 0,
                  obs.cg_hier_built ? 1 : 0, obs.cg_mg_cycles_attempted,
                  obs.active_fraction, obs.compliance);
    };
    const auto t0 = std::chrono::steady_clock::now();
    minimize_plastic(pf.part, material, "fdm", pf.bcs, rules, o);
    const double wall =
        std::chrono::duration<double>(std::chrono::steady_clock::now() - t0).count();
    std::printf("  probe: %.1f s for %lld iterations (%.2f s/iter), %lld CG, "
                "%d Jacobi fallbacks\n",
                wall, its, its ? wall / double(its) : 0.0, cg, fb);
    return 0;
  }

  if (mode == "length") {
    const int iters = argc > 2 ? std::atoi(argv[2]) : 250;
    std::printf("\n===== LENGTH — |drho| accumulation over %d MMA iterations at "
                "production dilution (134 §2d) =====\n", iters);
    double w_off = 0.0, w_on = 0.0;
    long long cg_off = 0, cg_on = 0;
    const LengthRun off = run_length("length/off", f, 0, iters, rules, material,
                                     w_off, cg_off);
    const LengthRun on = run_length("length/on k=4", f, 4, iters, rules, material,
                                    w_on, cg_on);
    const std::size_t n = std::min(off.field.size(), on.field.size());

    // The growth-invariant escape count, on the FULL-DOMAIN trajectory, under
    // MMA, at this length: derive the band from iteration i's field and count
    // voxels iteration i+1 raises above the active threshold OUTSIDE it.
    MinimizePlasticOptions po = base_options(f, 0);
    const VoxelGrid solved = minimize_plastic_solved_grid(f.part, po);
    const double rho_min = 1e-3, thresh = 1.5e-3;
    long long escapes = 0;
    double worst_out = 0.0;
    for (std::size_t i = 0; i + 1 < off.field.size(); ++i) {
      const std::vector<char> m =
          active_domain_mask(solved, off.field[i], rho_min, 4);
      for (std::size_t e = 0; e < off.field[i + 1].size(); ++e)
        if (off.field[i + 1][e] > thresh && m[e] == 0) {
          ++escapes;
          worst_out = std::max(worst_out, off.field[i + 1][e]);
        }
    }

    const std::string path = dir + "/length/drho_vs_iteration.csv";
    FILE* fp = std::fopen(path.c_str(), "w");
    if (fp) std::fprintf(fp, "iter,mean_abs_drho,max_abs_drho\n");
    std::printf("\n  iter    mean|drho|    max|drho|\n");
    for (std::size_t i = 0; i < n; ++i) {
      const Delta d = compare(off.field[i], on.field[i]);
      if (fp)
        std::fprintf(fp, "%zu,%.6e,%.6e\n", i + 1, d.mean_abs, d.max_abs);
      const std::size_t step = i + 1;
      if (step % 25 == 0 || step == 1 || step == n)
        std::printf("  %4zu    %.4e   %.4e\n", step, d.mean_abs, d.max_abs);
    }
    if (fp) std::fclose(fp);
    std::printf("\n  GROWTH INVARIANT over %zu full-domain MMA steps at k=4: "
                "%lld escapes (worst out-of-band density %.6f)\n",
                off.field.size(), escapes, worst_out);
    std::printf("  cost: wall %.1f -> %.1f s (%.3fx), CG %lld -> %lld (%.3fx)\n",
                w_off, w_on, w_off > 0 ? w_on / w_off : 0.0, cg_off, cg_on,
                cg_off ? double(cg_on) / double(cg_off) : 0.0);
    std::printf("  wrote %s\n", path.c_str());
    return 0;
  }

  const bool want_capture = (mode == "all" || mode == "capture");
  const bool want_gate = (mode == "all" || mode == "gate");

  if (want_capture) {
    std::printf("\n===== STEP 1 — THE SHARED CAPTURE (band OFF, snapshots on) "
                "=====\n");
    run_ladder("capture/off", f, /*band=*/0, rules, material,
               dir + "/capture/iterations.csv", dir + "/capture/snapshots",
               /*every*/ 10, /*cap*/ 40, dir + "/capture/run_info.json");
  }

  if (!want_gate) return 0;

  // The FULL production ladder, not one rung: every rung runs to its own
  // production terminator (full LENGTH), and the ladder is what produces the
  // GATE VERDICTS — accept / reject / where the walk stops — that condition 3
  // requires to be identical. At this fixture size the whole ladder is ~70 s, so
  // there is no reason to compare less than the thing that ships.
  std::printf("\n===== STEP 2 — THE GATE (full ladder; k = 4 ON vs OFF, each "
              "twice) =====\n");
  const RunRecord off1 =
      run_ladder("gate/off#1", f, 0, rules, material,
                 dir + "/gate/off1_iterations.csv", "", 0, 0,
                 dir + "/gate/off_run_info.json");
  const RunRecord off2 =
      run_ladder("gate/off#2", f, 0, rules, material,
                 dir + "/gate/off2_iterations.csv", "", 0, 0, "");
  const RunRecord on1 =
      run_ladder("gate/on#1  k=4", f, 4, rules, material,
                 dir + "/gate/on1_iterations.csv", "", 0, 0,
                 dir + "/gate/on_run_info.json");
  const RunRecord on2 =
      run_ladder("gate/on#2  k=4", f, 4, rules, material,
                 dir + "/gate/on2_iterations.csv", "", 0, 0, "");

  std::printf("\n===== GATE VERDICT =====\n");
  const bool off_repeat = bit_identical(off1, off2);
  const bool on_repeat = bit_identical(on1, on2);
  std::printf("  twice-run bit-identical: OFF %s   ON %s\n",
              off_repeat ? "YES" : "NO", on_repeat ? "YES" : "NO");

  const bool same_rung_count = off1.rung_vf.size() == on1.rung_vf.size();
  bool same_verdicts = same_rung_count;
  if (same_rung_count)
    for (std::size_t i = 0; i < off1.rung_vf.size(); ++i)
      if (off1.rung_accepted[i] != on1.rung_accepted[i] ||
          off1.rung_infeasible[i] != on1.rung_infeasible[i])
        same_verdicts = false;
  std::printf("  gate verdicts identical: %s (%zu vs %zu rungs evaluated)\n",
              same_verdicts ? "YES" : "NO", off1.rung_vf.size(),
              on1.rung_vf.size());
  std::printf("  terminal recommendation: OFF \"%s\"  ON \"%s\"\n",
              off1.terminal_recommendation.c_str(),
              on1.terminal_recommendation.c_str());

  double worst_mean = 0.0, worst_max = 0.0, worst_margin_rel = 0.0;
  const std::size_t n = std::min(off1.rung_vf.size(), on1.rung_vf.size());
  std::printf("\n  rung   vf   f_bar  |  mean|drho|   max|drho| | dC/C       "
              "margin OFF -> ON            dM/M\n");
  for (std::size_t i = 0; i < n; ++i) {
    const Delta d = compare(off1.rung_density[i], on1.rung_density[i]);
    worst_mean = std::max(worst_mean, d.mean_abs);
    worst_max = std::max(worst_max, d.max_abs);
    const double crel =
        off1.rung_compliance[i] != 0.0
            ? std::fabs(on1.rung_compliance[i] - off1.rung_compliance[i]) /
                  std::fabs(off1.rung_compliance[i])
            : 0.0;
    double mrel = 0.0;
    if (std::isfinite(off1.rung_margin[i]) && off1.rung_margin[i] != 0.0 &&
        std::isfinite(on1.rung_margin[i]))
      mrel = std::fabs(on1.rung_margin[i] - off1.rung_margin[i]) /
             std::fabs(off1.rung_margin[i]);
    worst_margin_rel = std::max(worst_margin_rel, mrel);
    std::printf("   %zu    %.2f  %.4f |  %.4e  %.4e | %.3e  %14.6g -> %-14.6g %.4e\n",
                i, off1.rung_vf[i], on1.rung_active_fraction_mean[i], d.mean_abs,
                d.max_abs, crel, off1.rung_margin[i], on1.rung_margin[i], mrel);
  }
  std::printf("\n  WORST mean|drho| %.4e   (bar: 1e-4)\n", worst_mean);
  std::printf("  WORST max|drho|  %.4e\n", worst_max);
  std::printf("  WORST margin relative delta %.4e   (bar: 1e-3 = 0.1%%)\n",
              worst_margin_rel);

  // The honest cost accounting. The CG-iteration ratio is the DURABLE half (it
  // is deterministic); wall clock is thermally exposed and is reported beside it,
  // never instead of it.
  std::printf("\n  COST: wall  OFF %.1f s -> ON %.1f s  (%.3fx)\n", off1.wall,
              on1.wall, off1.wall > 0.0 ? on1.wall / off1.wall : 0.0);
  std::printf("        CG iterations  OFF %lld -> ON %lld  (%.3fx)\n",
              off1.cg_total, on1.cg_total,
              off1.cg_total ? double(on1.cg_total) / double(off1.cg_total) : 0.0);
  std::printf("        optimizer iterations  OFF %lld -> ON %lld\n",
              off1.iters_total, on1.iters_total);
  std::printf("        Jacobi-fallback solves  OFF %d  ON %d\n",
              off1.mg_fallback_solves, on1.mg_fallback_solves);
  double fbar = 0.0;
  for (std::size_t i = 0; i < n; ++i) fbar += on1.rung_active_fraction_mean[i];
  if (n) fbar /= double(n);
  std::printf("        mean f_bar %.4f  =>  134's 0.65/f law projects %.2fx "
              "per-solve\n",
              fbar, fbar > 0.0 ? 0.65 / fbar : 0.0);

  write_gate_csv(dir + "/gate/gate.csv", off1, on1);
  std::printf("\n  wrote %s/gate/gate.csv\n", dir.c_str());
  return 0;
}
