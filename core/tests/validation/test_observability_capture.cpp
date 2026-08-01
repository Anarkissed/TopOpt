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
#include <cstdlib>
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
  check(header == std::string(kIterationCsvHeader),
        "CSV header matches the documented schema");
  std::size_t data_rows = 0;
  int prev_rung = -1, prev_iter = 0;
  bool rows_ok = true;
  for (std::string line; std::getline(ss, line);) {
    if (line.empty()) continue;
    ++data_rows;
    int rung = -1, iter = -1, plateau = -1, cgit = -1, cgmg = -1;
    int hier = -1, mgcyc = -1, infeas = -1;
    long long wall = 0;
    double comp = 0, vf = -1, beta = -1;
    const int n = std::sscanf(
        line.c_str(), "%d,%d,%lld,%lf,%lf,%d,%d,%d,%lf,%d,%d,%d", &rung, &iter,
        &wall, &comp, &vf, &plateau, &cgit, &cgmg, &beta, &hier, &mgcyc, &infeas);
    if (n != 12) rows_ok = false;
    if (rung < 0 || rung >= 2) rows_ok = false;
    if (rung == prev_rung && iter != prev_iter + 1) rows_ok = false;  // monotone
    if (vf < 0.0 || vf > 1.0) rows_ok = false;
    if (plateau != 0 && plateau != 1) rows_ok = false;
    if (cgit < 0) rows_ok = false;
    if (beta < 0.0) rows_ok = false;  // 0 (not projecting) or a positive stage β
    // Handoff 128 — fallback diagnostics: hier_built is 0/1; cycles are >= 0 and
    // 0 whenever no hierarchy was built. On the JacobiCG default path (this test)
    // both are 0.
    if (hier != 0 && hier != 1) rows_ok = false;
    if (mgcyc < 0) rows_ok = false;
    if (hier == 0 && mgcyc != 0) rows_ok = false;
    // Handoff 131 — the rung-infeasibility verdict is 0/1, and this healthy
    // fixture never trips it, so every row must read 0.
    if (infeas != 0) rows_ok = false;
    prev_rung = rung;
    prev_iter = iter;
  }
  check(rows_ok, "every CSV row parses to 12 typed, in-range fields");
  check(data_rows == total_iters, "CSV data row count == total iterations");

  // --- PHASE ACCOUNTING (task 2026-08-02-iteration-phase-timing) -------------
  // The point of the residual column is that the accounting CLOSES: a reader
  // must be able to trust that total_ms minus the named phases IS residual_ms,
  // on real rows produced by a real run, not just in the golden fixture. Also
  // pinned here: EXACTLY ONE penalized FEA solve per design iteration — the
  // question "does more than one solve run while only one cg_iters is reported?"
  // answered on live data, since a second solve would be the whole finding.
  {
    auto split = [](const std::string& line) {
      std::vector<std::string> f;
      for (std::size_t b = 0, e; b <= line.size(); b = e + 1) {
        e = line.find(',', b);
        if (e == std::string::npos) e = line.size();
        f.push_back(line.substr(b, e - b));
      }
      return f;
    };
    // Columns are resolved BY NAME from kIterationCsvHeader, never by a
    // hard-coded index or count. The previous version pinned "42 columns" and
    // indices 14/32/36/37 in a comment; the moment a column was appended
    // (geneo_burn / geneo_threshold, handoff 2026-08-02-geneo-disarm) the row
    // count check tripped and reported it as the ACCOUNTING failing, which is a
    // different and much more alarming fact than "the schema grew". Resolving by
    // name means a new column cannot make this test lie about what broke.
    const std::vector<std::string> hdr = split(std::string(kIterationCsvHeader));
    auto col = [&](const char* name) {
      for (std::size_t i = 0; i < hdr.size(); ++i)
        if (hdr[i] == name) return i;
      return std::string::npos;
    };
    const std::size_t c_total = col("total_ms"), c_filter = col("filter_ms"),
                      c_project = col("project_ms"), c_solve = col("solve_ms"),
                      c_update = col("update_ms"),
                      c_analysis = col("analysis_ms"),
                      c_observe = col("observe_ms"),
                      c_residual = col("residual_ms"),
                      c_fea = col("fea_solves"), c_rss = col("rss_mb"),
                      c_peak = col("peak_rss_mb"), c_cg = col("cg_iters"),
                      c_gact = col("geneo_action"), c_gburn = col("geneo_burn"),
                      c_gthr = col("geneo_threshold");
    bool cols_ok = true;
    for (std::size_t c : {c_total, c_filter, c_project, c_solve, c_update,
                          c_analysis, c_observe, c_residual, c_fea, c_rss,
                          c_peak, c_cg, c_gact, c_gburn, c_gthr})
      if (c == std::string::npos) cols_ok = false;
    check(cols_ok, "every column this test reads is present in the schema");

    std::istringstream ps(body);
    std::string skip;
    std::getline(ps, skip);  // header
    bool acct_ok = true, solves_ok = true, mem_ok = true, gate_ok = true;
    std::size_t checked = 0;
    for (std::string line; std::getline(ps, line);) {
      if (line.empty()) continue;
      const std::vector<std::string> f = split(line);
      if (f.size() != hdr.size()) {
        acct_ok = false;
        break;
      }
      auto d = [&](std::size_t i) { return std::atof(f[i].c_str()); };
      const double total = d(c_total), filter = d(c_filter),
                   project = d(c_project), solve = d(c_solve),
                   update = d(c_update), analysis = d(c_analysis),
                   observe = d(c_observe), residual = d(c_residual);
      const double sum =
          filter + project + solve + update + analysis + observe + residual;
      // Every term is a difference of two reads of the SAME steady clock, so
      // the identity is exact up to the %.3f the CSV prints (7 terms x 0.0005).
      if (std::fabs(total - sum) > 0.005) acct_ok = false;
      if (std::atoll(f[c_fea].c_str()) != 1) solves_ok = false;
      // Memory columns are either a real measurement (>= 0) or the explicit
      // "unavailable" sentinel (< 0) — never a fabricated zero from a failed
      // syscall. peak >= current whenever both were answered.
      const double rss = d(c_rss), peak = d(c_peak);
      if (rss >= 0.0 && peak >= 0.0 && peak + 1e-9 < rss) mem_ok = false;
      // THE ENGAGEMENT GATE's decision must be legible on a LIVE row (handoff
      // 2026-08-02-geneo-disarm, bar AA5): a DECLINED solve (action 5) reports
      // the whole solve as its burn and a real, positive threshold it was graded
      // against. Vacuous on a run where GenEO never holds a basis — which is the
      // point: it costs nothing until there is a decision to check, and then it
      // catches a zero the way the multigrid entry point once reported one.
      const long long act = std::atoll(f[c_gact].c_str());
      if (act == 5) {
        if (std::atoll(f[c_gthr].c_str()) <= 0) gate_ok = false;
        if (std::atoll(f[c_gburn].c_str()) != std::atoll(f[c_cg].c_str()))
          gate_ok = false;
      }
      ++checked;
    }
    check(checked == data_rows && acct_ok,
          "every row's total_ms == filter+project+solve+update+analysis+"
          "observe+residual (the accounting closes)");
    check(solves_ok, "exactly ONE penalized FEA solve per design iteration");
    check(mem_ok, "peak RSS >= current RSS on every row that answered both");
    check(gate_ok,
          "every DECLINED solve reports a positive gate threshold and a burn "
          "equal to its own iteration count");
  }

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
