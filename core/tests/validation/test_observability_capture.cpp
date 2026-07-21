// Handoff 114 — THE ONE RULE (observability edition), proven on the REAL driver:
// a minimize_plastic run with the per-iteration CSV + density snapshots captured
// produces a BYTE-IDENTICAL design to the same run with capture off. Also
// exercises the full capture path end-to-end: the CSV row count equals the total
// optimizer iterations, the schema round-trips, and every rung boundary snapshot
// is written and reads back within float16.
//
// Drives minimize_plastic (Eigen), so it is Eigen-gated like the other optimizer
// gates; the real settings rule table is injected. Builds its part in code (no
// fixture), reusing the cantilever-bracket pattern of test_minimize_plastic.

#include <cmath>
#include <cstddef>
#include <cstdio>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <sstream>
#include <string>
#include <vector>

#include "topopt/fea.hpp"
#include "topopt/materials.hpp"
#include "topopt/observability.hpp"
#include "topopt/pipeline.hpp"
#include "topopt/settings.hpp"
#include "topopt/voxel.hpp"

#ifndef SETTINGS_RULES_PATH
#error "SETTINGS_RULES_PATH must be injected"
#endif
#ifndef EXPORT_TMP_DIR
#define EXPORT_TMP_DIR "."
#endif

using namespace topopt;

namespace {
int g_checks = 0, g_failures = 0;
void check(bool ok, const char* what) {
  ++g_checks;
  if (!ok) {
    ++g_failures;
    std::fprintf(stderr, "FAIL: %s\n", what);
  }
}

VoxelGrid cantilever_bracket(std::vector<DirichletBC>& bcs, double h = 2.0) {
  const int nx = 16, ny = 4, nz = 4;
  VoxelGrid g;
  g.nx = nx;
  g.ny = ny;
  g.nz = nz;
  g.spacing = h;
  g.origin = Vec3{0.0, 0.0, 0.0};
  g.tags.assign(static_cast<std::size_t>(nx) * ny * nz, VoxelTag::Interior);
  for (int k = 0; k < nz; ++k)
    for (int j = 0; j < ny; ++j) g.set_tag(0, j, k, VoxelTag::Fixture);
  bcs.clear();
  for (int c = 0; c <= nz; ++c)
    for (int b = 0; b <= ny; ++b) {
      const int n = fea_node_index(g, 0, b, c);
      bcs.push_back({n, 0, 0.0});
      bcs.push_back({n, 1, 0.0});
      bcs.push_back({n, 2, 0.0});
    }
  return g;
}

Material fdm_material() {
  Material m;
  m.youngs_modulus_mpa = 3500.0;
  m.yield_strength_mpa = 0.02;
  m.density_g_cm3 = 1.24;
  m.z_knockdown = 0.55;
  m.poisson = 0.33;
  m.family = "fdm";
  return m;
}

MinimizePlasticOptions base_options() {
  MinimizePlasticOptions o;
  o.volume_fraction_ladder = {0.6, 0.4};
  o.margin_stop = 0.0;  // run the full ladder (both rungs) — no margin variance
  o.gravity = 9.81;
  o.gravity_direction = Vec3{0.0, 0.0, -1.0};
  o.simp.max_iterations = 14;  // small cap: fast, still multi-iteration
  return o;
}

bool bit_equal(const std::vector<double>& a, const std::vector<double>& b) {
  return a.size() == b.size() &&
         std::memcmp(a.data(), b.data(), a.size() * sizeof(double)) == 0;
}

std::string read_all(const std::string& p) {
  std::ifstream in(p, std::ios::binary);
  std::ostringstream ss;
  ss << in.rdbuf();
  return ss.str();
}
}  // namespace

int main() {
  const SettingsRules rules = load_settings_rules_file(SETTINGS_RULES_PATH);
  const Material mat = fdm_material();
  const std::string tmp = std::string(EXPORT_TMP_DIR) + "/obs_capture";
  std::filesystem::remove_all(tmp);
  std::filesystem::create_directories(tmp);

  // --- Run 1: capture OFF (baseline design) ----------------------------------
  std::vector<DirichletBC> bcs;
  VoxelGrid grid = cantilever_bracket(bcs);
  const MinimizePlasticResult off =
      minimize_plastic(grid, mat, "TEST_FDM", bcs, rules, base_options());

  // --- Run 2: capture ON (CSV + snapshots wired) -----------------------------
  MinimizePlasticOptions opt = base_options();
  IterationCsvWriter csv(tmp + "/iterations.csv");
  SnapshotCapture snaps(tmp + "/snapshots", /*every_n=*/3, /*cap=*/8);
  std::size_t on_iter_calls = 0;
  int boundaries = 0;
  opt.on_iteration = [&](std::size_t rung, std::size_t /*rungs*/,
                         const SimpIterationObservation& obs) {
    csv.append(rung, obs);
    ++on_iter_calls;
  };
  opt.on_density_snapshot = [&](const DensitySnapshotEvent& ev) {
    if (ev.boundary) ++boundaries;
    snaps.capture(*ev.grid, *ev.density, ev.rung_index, ev.iteration,
                  ev.boundary);
  };
  const MinimizePlasticResult on =
      minimize_plastic(grid, mat, "TEST_FDM", bcs, rules, opt);

  // --- THE ONE RULE: designs byte-identical ----------------------------------
  check(off.evaluated.size() == on.evaluated.size(),
        "same number of evaluated rungs with/without capture");
  bool all_equal = off.evaluated.size() == on.evaluated.size();
  std::size_t total_iters = 0;
  for (std::size_t i = 0; i < off.evaluated.size() && all_equal; ++i) {
    if (!bit_equal(off.evaluated[i].optimization.physical_density,
                   on.evaluated[i].optimization.physical_density))
      all_equal = false;
    if (!bit_equal(off.evaluated[i].optimization.design,
                   on.evaluated[i].optimization.design))
      all_equal = false;
    if (off.evaluated[i].optimization.compliance !=
        on.evaluated[i].optimization.compliance)
      all_equal = false;
    if (!on.evaluated[i].optimization.cancelled)
      total_iters += static_cast<std::size_t>(on.evaluated[i].optimization.iterations);
  }
  check(all_equal,
        "capture ON produces BYTE-IDENTICAL designs to capture OFF (THE ONE RULE)");

  // --- CSV: one row per optimizer iteration, schema round-trips --------------
  check(on_iter_calls == total_iters,
        "on_iteration fired once per optimizer iteration");
  check(csv.rows() == total_iters, "CSV wrote one row per iteration");
  const std::string body = read_all(tmp + "/iterations.csv");
  std::istringstream ss(body);
  std::string header;
  std::getline(ss, header);
  check(header ==
            "rung,iter,wall_ms,compliance,achieved_vf,plateau,cg_iters,"
            "cg_multigrid,beta",
        "CSV header matches the documented schema");
  std::size_t data_rows = 0;
  int prev_rung = -1, prev_iter = 0;
  bool rows_ok = true;
  for (std::string line; std::getline(ss, line);) {
    if (line.empty()) continue;
    ++data_rows;
    int rung = -1, iter = -1, plateau = -1, cgit = -1, cgmg = -1;
    long long wall = 0;
    double comp = 0, vf = -1, beta = -1;
    const int n =
        std::sscanf(line.c_str(), "%d,%d,%lld,%lf,%lf,%d,%d,%d,%lf", &rung, &iter,
                    &wall, &comp, &vf, &plateau, &cgit, &cgmg, &beta);
    if (n != 9) rows_ok = false;
    if (rung < 0 || rung >= 2) rows_ok = false;
    if (rung == prev_rung && iter != prev_iter + 1) rows_ok = false;  // monotone
    if (vf < 0.0 || vf > 1.0) rows_ok = false;
    if (plateau != 0 && plateau != 1) rows_ok = false;
    if (cgit < 0) rows_ok = false;
    if (beta < 0.0) rows_ok = false;  // 0 (not projecting) or a positive stage β
    prev_rung = rung;
    prev_iter = iter;
  }
  check(rows_ok, "every CSV row parses to 9 typed, in-range fields");
  check(data_rows == total_iters, "CSV data row count == total iterations");

  // --- snapshots: a boundary per evaluated rung, round-trips within f16 ------
  check(boundaries == static_cast<int>(off.evaluated.size()),
        "one boundary snapshot event per evaluated rung");
  check(snaps.written() >= static_cast<std::size_t>(boundaries),
        "snapshot writer wrote at least the boundary snapshots");
  // The terminal (last rung) boundary snapshot round-trips within f16.
  const VoxelGrid& sg = on.solved_grid;
  const std::size_t last = on.evaluated.size() - 1;
  char base[96];
  std::snprintf(base, sizeof(base), "snap_rung%zu_iter%04d_boundary", last,
                on.evaluated[last].optimization.iterations);
  const std::string f16 = tmp + "/snapshots/" + std::string(base) + ".f16";
  check(std::filesystem::exists(f16), "terminal boundary snapshot exists");
  if (std::filesystem::exists(f16)) {
    const std::vector<float> rt = read_density_f16(f16, sg.voxel_count());
    const std::vector<double>& ref =
        on.evaluated[last].optimization.physical_density;
    double max_err = 0.0;
    for (std::size_t i = 0; i < ref.size(); ++i)
      max_err = std::max(max_err, std::fabs(static_cast<double>(rt[i]) - ref[i]));
    check(max_err <= 5e-4, "terminal snapshot round-trips within float16");
  }

  if (g_failures == 0) {
    std::printf("observability_capture: all %d checks passed\n", g_checks);
    return 0;
  }
  std::fprintf(stderr, "observability_capture: %d of %d checks FAILED\n",
               g_failures, g_checks);
  return 1;
}
