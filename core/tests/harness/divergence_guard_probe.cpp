// CALIBRATION HARNESS for the two DIVERGENCE guards (task
// 2026-08-03-preflight-feasibility-and-divergence, guards 2 and 3).
//
// It prints, for the two trajectories the constants have to separate, the exact
// per-iteration numbers the guards key on:
//
//   A. THE CORPSE — the recorded 96³ design-box run (tests/fixtures/infeasible/
//      iterations_96_designbox.csv, handoff 131's fixture) and the maintainer's
//      own 10-hour run (evidence/2026-08-03-preflight-feasibility-and-divergence/
//      maintainer-job/iterations.csv), replayed from disk.
//   B. THE LIVE FORMING TRANSIENT — the 24x5x6 cantilever at vf 0.03 that runs
//      ~8770x above its own start and then RECOVERS. This is the measured
//      counter-example that killed an earlier two-conjunct predicate, and it is
//      the thing an immediate (single-iteration) trip is most likely to murder.
//
// The columns are: compliance, the LEVEL ratio c[i]/c[0], the STEP ratio
// c[i]/c[i-1], and the CG count. A constant is only defensible if the corpse and
// the transient are separated on the columns the guard actually reads — this
// harness is how that separation was measured rather than assumed.
//
//   cmake --build build --target divergence_guard_probe
//   ./build/divergence_guard_probe [extra-iterations.csv ...]

#include "topopt/fea.hpp"
#include "topopt/materials.hpp"
#include "topopt/pipeline.hpp"
#include "topopt/settings.hpp"
#include "topopt/simp.hpp"
#include "topopt/voxel.hpp"

#include <algorithm>
#include <cstdio>
#include <cstddef>
#include <fstream>
#include <map>
#include <sstream>
#include <string>
#include <vector>

using topopt::DirichletBC;
using topopt::Material;
using topopt::MinimizePlasticOptions;
using topopt::SettingsRules;
using topopt::SimpUpdater;
using topopt::Vec3;
using topopt::VoxelGrid;
using topopt::VoxelTag;

namespace {

struct Row {
  double compliance = 0.0;
  int cg = 0;
  double total_ms = -1.0;
};

// Parse an iterations.csv by header name into per-rung traces.
std::map<int, std::vector<Row>> load_csv(const std::string& path) {
  std::ifstream in(path);
  if (!in) {
    std::fprintf(stderr, "cannot open %s\n", path.c_str());
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
  const int i_rung = col("rung"), i_c = col("compliance"), i_cg = col("cg_iters");
  const int i_tot = col("total_ms");
  if (i_rung < 0 || i_c < 0 || i_cg < 0) return {};
  std::map<int, std::vector<Row>> out;
  while (std::getline(in, line)) {
    if (line.empty()) continue;
    std::vector<std::string> f;
    std::stringstream ls(line);
    std::string cell;
    while (std::getline(ls, cell, ',')) f.push_back(cell);
    const int need = std::max(std::max(i_rung, i_c), i_cg);
    if (static_cast<int>(f.size()) <= need) continue;
    Row r;
    r.compliance = std::stod(f[static_cast<std::size_t>(i_c)]);
    r.cg = std::stoi(f[static_cast<std::size_t>(i_cg)]);
    if (i_tot >= 0 && static_cast<int>(f.size()) > i_tot)
      r.total_ms = std::stod(f[static_cast<std::size_t>(i_tot)]);
    out[std::stoi(f[static_cast<std::size_t>(i_rung)])].push_back(r);
  }
  return out;
}

void print_trace(const char* label, const std::vector<Row>& t) {
  if (t.empty()) return;
  const double c0 = t[0].compliance;
  const int cg0 = t[0].cg;
  const double t0 = t[0].total_ms;
  std::printf("\n=== %s (%zu iterations) ===\n", label, t.size());
  std::printf("%5s %16s %12s %12s %9s %9s %12s\n", "iter", "compliance",
              "c[i]/c[0]", "c[i]/c[i-1]", "cg", "cg/cg[0]", "ms/ms[0]");
  double peak_level = 0.0, peak_step = 0.0;
  for (std::size_t i = 0; i < t.size(); ++i) {
    const double level = c0 > 0.0 ? t[i].compliance / c0 : 0.0;
    const double step =
        i > 0 && t[i - 1].compliance > 0.0 ? t[i].compliance / t[i - 1].compliance : 1.0;
    peak_level = std::max(peak_level, level);
    peak_step = std::max(peak_step, step);
    std::printf("%5zu %16.6g %12.4g %12.4g %9d %9.3g %12.4g\n", i + 1,
                t[i].compliance, level, step, t[i].cg,
                cg0 > 0 ? static_cast<double>(t[i].cg) / cg0 : 0.0,
                (t0 > 0.0 && t[i].total_ms >= 0.0) ? t[i].total_ms / t0 : -1.0);
  }
  std::printf("-> peak LEVEL ratio %.6g, peak STEP ratio %.6g\n", peak_level,
              peak_step);
}

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

}  // namespace

int main(int argc, char** argv) {
  // --- A. the recorded corpses -------------------------------------------
  {
    const std::map<int, std::vector<Row>> traces =
        load_csv(std::string(INFEASIBLE_FIXTURE_DIR) +
                 "/iterations_96_designbox.csv");
    for (const auto& kv : traces) {
      char label[64];
      std::snprintf(label, sizeof(label), "96^3 design-box run, rung %d", kv.first);
      print_trace(label, kv.second);
    }
  }
  for (int a = 1; a < argc; ++a) {
    const std::map<int, std::vector<Row>> traces = load_csv(argv[a]);
    for (const auto& kv : traces) {
      char label[256];
      std::snprintf(label, sizeof(label), "%s, rung %d", argv[a], kv.first);
      print_trace(label, kv.second);
    }
  }

  // --- B. the LIVE forming transient -------------------------------------
  {
    const SettingsRules rules =
        topopt::load_settings_rules_file(SETTINGS_RULES_PATH);
    const Material mat = fdm_material();
    std::vector<DirichletBC> bcs;
    const VoxelGrid g = cantilever_bar(bcs);
    MinimizePlasticOptions o = base_options(g);
    o.volume_fraction_ladder = {0.6, 0.03};
    // DISARM every early stop so the whole trajectory is observed, including the
    // iterations a guard would have ended it on. This is a measurement, not a run.
    o.simp.infeasible_window = 0;
    std::map<int, std::vector<Row>> live;
    o.on_iteration = [&](std::size_t rung, std::size_t,
                         const topopt::SimpIterationObservation& ob) {
      Row r;
      r.compliance = ob.compliance;
      r.cg = ob.cg_iterations;
      r.total_ms = ob.phases.total_ms;
      live[static_cast<int>(rung)].push_back(r);
    };
    (void)minimize_plastic(g, mat, "PLA", bcs, rules, o);
    for (const auto& kv : live) {
      char label[64];
      std::snprintf(label, sizeof(label),
                    "LIVE cantilever vf{0.6,0.03}, rung %d", kv.first);
      print_trace(label, kv.second);
    }
  }
  return 0;
}
