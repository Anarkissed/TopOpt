// cg_tol_probe.cpp — measurement harness (NOT a CI test) for handoff 129.
//
// The 110-template design-difference table for the `cg_tolerance_loose`
// production flip. Drives minimize_plastic on TWO fixtures under the ACTUAL
// production configuration (configure_production_options — matrix-free MG +
// Galerkin cache + conditional projection + physical min-feature), toggling ONLY
// the adaptive early CG tolerance (handoff 128), and prints, per rung:
//   iterations-to-termination (outer MMA), summed trajectory CG iters,
//   wall-clock, achieved fraction, worst-case margin, accept/reject (gate verdict).
// Then the terminal-design difference loose-vs-tight (mean AND max |Δρ|).
//
// Two modes:
//   tight  : cg_tolerance_loose = 0 — the shipping path (byte-identical baseline).
//   loose  : cg_tolerance_loose = 1e-3 — the proposed production value (128 §B).
//
// Fixtures:
//   1. L-BRACKET LOADCASE  — external tip load (the 080/082/ladder-gate part).
//   2. DESIGN-BOX          — the same L-bracket PART inside a snug whole-domain
//                            design box (test_designbox_reduction's device repro),
//                            the whole-domain regime where MG stagnation / cold
//                            Jacobi grind — and thus the loose-CG payoff — lives.
//
// THERMAL PROTOCOL (113): iteration/CG-iteration counts, margins, achieved
// fractions, gate verdicts and |Δρ| are DETERMINISTIC — captured once, exact, no
// thermal noise. Wall-clock is thermally contaminated (±~30% on this box, 113
// §Thermals) so it is measured as the MEDIAN of REPS interleaved repeats and the
// min/max band is printed; treat the CG-iter ratio, not the wall ratio, as the
// cost claim. Modes are interleaved (tight,loose,tight,loose,…) so thermal drift
// does not bias one mode.
//
// Build (standalone; NOT wired into CTest):
//   c++ -std=c++17 -O2 -I include -I /opt/homebrew/include/eigen3 \
//     -DSETTINGS_RULES_PATH="\"$PWD/src/settings/rules.json\"" \
//     tests/harness/cg_tol_probe.cpp build/libtopopt.a -o cg_tol_probe

#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstdio>
#include <string>
#include <vector>

// Optional CSV sink: if TOPOPT_CG_PROBE_CSV_DIR is set, write per-fixture ladder
// CSVs there (rung granularity, every mode) for the handoff evidence. stdout is
// always the human table; the CSV is the machine-readable citation.
#include <cstdlib>

#include "topopt/materials.hpp"
#include "topopt/pipeline.hpp"
#include "topopt/production.hpp"
#include "topopt/settings.hpp"
#include "topopt/simp.hpp"
#include "topopt/voxel.hpp"

using namespace topopt;

namespace {

constexpr int kReps = 3;              // wall repeats (thermal band)
constexpr double kLooseTol = 1e-3;    // the proposed production loose value (128 §B)

// The thin L-bracket the 080/082/ladder gates build (test_ladder_rung_count).
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

double mean_abs_diff(const std::vector<double>& a, const std::vector<double>& b) {
  if (a.size() != b.size() || a.empty()) return -1.0;
  double s = 0.0;
  for (std::size_t i = 0; i < a.size(); ++i) s += std::fabs(a[i] - b[i]);
  return s / static_cast<double>(a.size());
}
double max_abs_diff(const std::vector<double>& a, const std::vector<double>& b) {
  if (a.size() != b.size() || a.empty()) return -1.0;
  double m = 0.0;
  for (std::size_t i = 0; i < a.size(); ++i) m = std::max(m, std::fabs(a[i] - b[i]));
  return m;
}

double median(std::vector<double> v) {
  std::sort(v.begin(), v.end());
  return v.empty() ? 0.0 : v[v.size() / 2];
}

struct RungRow {
  double vf = 0.0;
  int iters = 0;
  long long cg_iters = 0;   // summed trajectory CG iters across the rung
  double achieved = 0.0;
  double margin = 0.0;
  double compliance = 0.0;
  bool accepted = false;
  std::vector<double> density;  // this rung's terminal physical density
};

struct ModeResult {
  std::vector<RungRow> rungs;
  std::vector<double> terminal_density;
  double wall_median = 0.0, wall_min = 0.0, wall_max = 0.0;
  long long total_cg = 0;
  int total_iters = 0;
  double repeat_max_drho = 0.0;  // determinism self-check (rep0 vs rep1), should be 0
};

// One deterministic run + REPS wall repeats. `loose_tol` is the cg_tolerance_loose
// endpoint (0 => disabled/tight, byte-identical baseline).
ModeResult run_mode(double loose_tol, const VoxelGrid& part,
                    const std::vector<DirichletBC>& bcs,
                    const std::vector<NodalLoad>& loads,
                    const SettingsRules& rules, const Material& material,
                    bool with_box, const DesignBox& box) {
  auto make_opts = [&]() {
    MinimizePlasticOptions o;
    // The ACTUAL production configuration — this is the flip under test.
    configure_production_options(o);
    o.volume_fraction_ladder = production_reduction_ladder();
    o.margin_stop = 1.5;
    o.external_loads = loads;         // empty => self-weight
    o.gravity = 9810.0 * 1e-9;
    o.gravity_direction = Vec3{0.0, 0.0, -1.0};
    o.infill_percent = 100.0;
    if (with_box) o.design_box = box;
    // The single toggled knob. tight => 0 (byte-identical baseline).
    o.simp.cg_tolerance_loose = loose_tol;
    return o;
  };

  ModeResult mr;
  std::vector<double> walls;
  for (int rep = 0; rep < kReps; ++rep) {
    MinimizePlasticOptions o = make_opts();
    // Per-rung CG-iter accumulator via the read-only per-iteration observer.
    std::vector<long long> cg_per_rung;
    o.on_iteration = [&](std::size_t rung, std::size_t /*count*/,
                         const SimpIterationObservation& obs) {
      if (rung >= cg_per_rung.size()) cg_per_rung.resize(rung + 1, 0);
      cg_per_rung[rung] += obs.cg_iterations;
    };

    const auto t0 = std::chrono::steady_clock::now();
    const MinimizePlasticResult r =
        minimize_plastic(part, material, "fdm", bcs, rules, o);
    const auto t1 = std::chrono::steady_clock::now();
    walls.push_back(std::chrono::duration<double>(t1 - t0).count());

    if (rep == 0) {  // deterministic data — capture once
      for (std::size_t i = 0; i < r.evaluated.size(); ++i) {
        const auto& v = r.evaluated[i];
        RungRow row;
        row.vf = v.requested_volume_fraction;
        row.iters = v.optimization.iterations;
        row.cg_iters = i < cg_per_rung.size() ? cg_per_rung[i] : 0;
        row.achieved = v.optimization.volume_fraction;
        row.margin = v.report.margin.worst_case;
        row.compliance = v.optimization.compliance;
        row.accepted = v.accepted;
        row.density = v.optimization.physical_density;
        mr.rungs.push_back(row);
        mr.total_cg += row.cg_iters;
        mr.total_iters += row.iters;
      }
      if (!r.evaluated.empty())
        mr.terminal_density = r.evaluated.back().optimization.physical_density;
    } else if (rep == 1 && !mr.terminal_density.empty() &&
               !r.evaluated.empty()) {
      // Determinism self-check: a second run of the SAME mode must reproduce the
      // terminal design bit-for-bit (max|drho| == 0), else the loose-vs-tight
      // comparison is measuring noise, not the tolerance.
      mr.repeat_max_drho =
          max_abs_diff(mr.terminal_density,
                       r.evaluated.back().optimization.physical_density);
    }
  }
  mr.wall_median = median(walls);
  mr.wall_min = *std::min_element(walls.begin(), walls.end());
  mr.wall_max = *std::max_element(walls.begin(), walls.end());
  return mr;
}

void print_mode(const char* name, const ModeResult& m) {
  std::printf("[%s] rungs=%zu total_iters=%d total_cg=%lld  wall=%.2fs (%.2f–%.2f, med of %d)  repeat_max|drho|=%.2e\n",
              name, m.rungs.size(), m.total_iters, m.total_cg,
              m.wall_median, m.wall_min, m.wall_max, kReps, m.repeat_max_drho);
  for (const RungRow& r : m.rungs)
    std::printf("    vf=%.2f  iters=%3d  cg=%6lld  achieved=%.4f  margin=%.3f  C=%.6g  %s\n",
                r.vf, r.iters, r.cg_iters, r.achieved, r.margin, r.compliance,
                r.accepted ? "accept" : "REJECT");
}

// Compare one loose-endpoint run against the tight baseline and print the
// bar-relevant deltas: per accepted rung, then the two summary rows the bar cares
// about (shipped part = last accepted rung; worst-across-accepted-rungs).
void compare(const char* tag, const ModeResult& tight, const ModeResult& loose) {
  const std::size_t n = std::min(tight.rungs.size(), loose.rungs.size());
  bool verdicts_identical = tight.rungs.size() == loose.rungs.size();
  double worst_margin_delta_pct = 0.0, worst_accepted_mean = 0.0, worst_C = 0.0;
  int last_accepted = -1;
  for (std::size_t i = 0; i < n; ++i) {
    if (tight.rungs[i].accepted != loose.rungs[i].accepted) verdicts_identical = false;
    const bool acc = tight.rungs[i].accepted && loose.rungs[i].accepted;
    if (acc) last_accepted = static_cast<int>(i);
    const double mt = tight.rungs[i].margin, ml = loose.rungs[i].margin;
    const double mdelta = 100.0 * std::fabs(ml - mt) /
                          (std::fabs(mt) > 1e-12 ? std::fabs(mt) : 1.0);
    const double mean_d = mean_abs_diff(tight.rungs[i].density, loose.rungs[i].density);
    const double ct = tight.rungs[i].compliance, cl = loose.rungs[i].compliance;
    const double cdelta = std::fabs(ct) > 1e-30 ? 100.0 * std::fabs(cl - ct) / ct : 0.0;
    if (acc) {
      worst_margin_delta_pct = std::max(worst_margin_delta_pct, mdelta);
      worst_accepted_mean = std::max(worst_accepted_mean, mean_d);
      worst_C = std::max(worst_C, cdelta);
    }
  }
  double ship_mean = 0.0, ship_max = 0.0;
  double ship_vf = 0.0;
  if (last_accepted >= 0) {
    const auto& tr = tight.rungs[last_accepted];
    const auto& lr = loose.rungs[last_accepted];
    ship_mean = mean_abs_diff(tr.density, lr.density);
    ship_max = max_abs_diff(tr.density, lr.density);
    ship_vf = tr.vf;
  }
  const double cg_ratio =
      loose.total_cg > 0 ? double(tight.total_cg) / double(loose.total_cg) : 0.0;
  std::printf("  %-6s cg_ratio=%.2fx  wall=%.2fs  gate=%s  | SHIPPED vf=%.2f mean|drho|=%.5f max=%.3f "
              "| worst-accepted mean|drho|=%.5f margin_delta=%.2f%% C_delta=%.2f%%\n",
              tag, cg_ratio, loose.wall_median, verdicts_identical ? "OK" : "DIFF",
              ship_vf, ship_mean, ship_max, worst_accepted_mean,
              worst_margin_delta_pct, worst_C);
}

// Write a per-fixture ladder CSV (one row per mode×rung) if a CSV dir is set.
void write_csv(const char* csv_name, const std::vector<std::string>& mode_names,
               const std::vector<const ModeResult*>& modes,
               const ModeResult& tight) {
  const char* dir = std::getenv("TOPOPT_CG_PROBE_CSV_DIR");
  if (!dir) return;
  const std::string path = std::string(dir) + "/" + csv_name;
  FILE* f = std::fopen(path.c_str(), "w");
  if (!f) { std::fprintf(stderr, "WARN: cannot write %s\n", path.c_str()); return; }
  std::fprintf(f, "mode,loose_tol,rung_index,vf,iters,cg_iters,achieved,margin,"
                  "compliance,accepted,mean_drho_vs_tight,max_drho_vs_tight,"
                  "margin_delta_pct_vs_tight,C_delta_pct_vs_tight,repeat_max_drho\n");
  for (std::size_t m = 0; m < modes.size(); ++m) {
    const ModeResult& mr = *modes[m];
    for (std::size_t i = 0; i < mr.rungs.size(); ++i) {
      const RungRow& r = mr.rungs[i];
      double mean_d = 0.0, max_d = 0.0, mdelta = 0.0, cdelta = 0.0;
      if (i < tight.rungs.size()) {
        mean_d = mean_abs_diff(tight.rungs[i].density, r.density);
        max_d = max_abs_diff(tight.rungs[i].density, r.density);
        const double mt = tight.rungs[i].margin;
        mdelta = 100.0 * std::fabs(r.margin - mt) /
                 (std::fabs(mt) > 1e-12 ? std::fabs(mt) : 1.0);
        const double ct = tight.rungs[i].compliance;
        cdelta = std::fabs(ct) > 1e-30 ? 100.0 * std::fabs(r.compliance - ct) / ct : 0.0;
      }
      std::fprintf(f, "%s,%s,%zu,%.2f,%d,%lld,%.4f,%.4f,%.6g,%d,%.6f,%.6f,%.4f,%.4f,%.2e\n",
                   mode_names[m].c_str(), mode_names[m] == "tight" ? "0" : mode_names[m].c_str(),
                   i, r.vf, r.iters, r.cg_iters, r.achieved, r.margin, r.compliance,
                   r.accepted ? 1 : 0, mean_d, max_d, mdelta, cdelta, mr.repeat_max_drho);
    }
  }
  std::fclose(f);
  std::printf("  [wrote %s]\n", path.c_str());
}

void run_fixture(const char* label, const char* csv_name, const VoxelGrid& part,
                 const std::vector<DirichletBC>& bcs,
                 const std::vector<NodalLoad>& loads, const SettingsRules& rules,
                 const Material& material, bool with_box, const DesignBox& box) {
  std::printf("\n===== %s (grid %dx%dx%d, %zu solid voxels%s) =====\n", label,
              part.nx, part.ny, part.nz, part.solid_count(),
              with_box ? ", whole-domain design box" : "");

  const ModeResult tight = run_mode(0.0, part, bcs, loads, rules, material,
                                    with_box, box);
  print_mode("tight ", tight);

  // Sweep the loose endpoint from mild (1e-6) to the proposed production 1e-3.
  const double sweep[] = {1e-6, 1e-5, 1e-4, kLooseTol};
  const char* names[] = {"1e-6", "1e-5", "1e-4", "1e-3"};
  std::vector<ModeResult> looses;
  for (double t : sweep)
    looses.push_back(run_mode(t, part, bcs, loads, rules, material, with_box, box));
  for (std::size_t i = 0; i < looses.size(); ++i)
    print_mode(names[i], looses[i]);

  std::printf("  --- design difference vs tight (bar: SHIPPED & worst-accepted mean|drho| <= 0.03, margin_delta <= 3%%, gate OK) ---\n");
  for (std::size_t i = 0; i < looses.size(); ++i)
    compare(names[i], tight, looses[i]);

  std::vector<std::string> mode_names = {"tight"};
  std::vector<const ModeResult*> modes = {&tight};
  for (std::size_t i = 0; i < looses.size(); ++i) {
    mode_names.push_back(names[i]);
    modes.push_back(&looses[i]);
  }
  write_csv(csv_name, mode_names, modes, tight);
}

}  // namespace

int main() {
  SettingsRules rules;
  try {
    rules = load_settings_rules_file(SETTINGS_RULES_PATH);
  } catch (const std::exception& e) {
    std::fprintf(stderr, "FAIL: could not load rules.json: %s\n", e.what());
    return 1;
  }
  const Material material = fdm_material();
  const DesignBox no_box{};

  // Fixture 1: the L-bracket LOADCASE (external tip load).
  {
    const int arm = 8, span = 8, ny = 3, t = 2;
    const double h = 2.0;
    std::vector<DirichletBC> bcs;
    VoxelGrid part = l_bracket(bcs, arm, span, ny, t, h);
    const std::vector<NodalLoad> tip =
        traction_loads(part, VoxelTag::Load, Vec3{0.0, 0.0, -30.0});
    run_fixture("L-BRACKET LOADCASE", "fixture1_l_bracket_loadcase.csv", part,
                bcs, tip, rules, material, /*with_box=*/false, no_box);
  }

  // Fixture 2: DESIGN-BOX — same L-bracket part, snug whole-domain box
  // (test_designbox_reduction's device repro), external tip load.
  {
    const int arm = 8, span = 8, ny = 3, t = 2;
    const double h = 2.0;
    std::vector<DirichletBC> bcs;
    VoxelGrid part = l_bracket(bcs, arm, span, ny, t, h);
    const std::vector<NodalLoad> tip =
        traction_loads(part, VoxelTag::Load, Vec3{0.0, 0.0, -30.0});
    DesignBox box;
    box.min = Vec3{0.0, 0.0, 0.0};
    box.max = Vec3{16.0, 6.0, 16.0};
    run_fixture("DESIGN-BOX (whole-domain)", "fixture2_design_box.csv", part,
                bcs, tip, rules, material, /*with_box=*/true, box);
  }

  return 0;
}
