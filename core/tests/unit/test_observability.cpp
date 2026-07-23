// Handoff 114 — observability primitives (Eigen-free): the float16 codec, the
// per-iteration CSV schema (GOLDEN), density-snapshot round-trip, SnapshotCapture
// cadence + cap eviction, and the run version record. THE ONE RULE's design
// byte-identity is proven separately on the real driver in
// test_observability_capture (Eigen-gated).

#include <cmath>
#include <cstdint>
#include <cstdio>
#include <filesystem>
#include <fstream>
#include <sstream>
#include <string>
#include <vector>

#include "topopt/observability.hpp"
#include "topopt/voxel.hpp"

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

std::string read_all(const std::string& path) {
  std::ifstream in(path, std::ios::binary);
  std::ostringstream ss;
  ss << in.rdbuf();
  return ss.str();
}

VoxelGrid make_grid(int nx, int ny, int nz, double sp) {
  VoxelGrid g;
  g.nx = nx;
  g.ny = ny;
  g.nz = nz;
  g.spacing = sp;
  g.origin = Vec3{1.0, 2.0, 3.0};
  g.tags.assign(static_cast<std::size_t>(nx) * ny * nz, VoxelTag::Interior);
  return g;
}
}  // namespace

int main() {
  const std::string tmp = std::string(EXPORT_TMP_DIR) + "/obs_test";
  std::filesystem::create_directories(tmp);

  // --- float16 codec round-trip over [0,1] -----------------------------------
  {
    double max_err = 0.0;
    for (int i = 0; i <= 1000; ++i) {
      const float v = static_cast<float>(i) / 1000.0f;
      const float rt = half_to_float(float_to_half(v));
      max_err = std::max(max_err, static_cast<double>(std::fabs(rt - v)));
    }
    // half's step near 1.0 is 2^-11 ~ 4.88e-4; nearest-even round-trip stays
    // within half that plus fp slack.
    check(max_err <= 5e-4, "float16 round-trip max abs error within f16 over [0,1]");
    // Exact anchors.
    check(half_to_float(float_to_half(0.0f)) == 0.0f, "f16 0 -> 0");
    check(half_to_float(float_to_half(1.0f)) == 1.0f, "f16 1 -> 1");
    check(std::fabs(half_to_float(float_to_half(0.5f)) - 0.5f) < 1e-6, "f16 0.5");
  }

  // --- CSV schema (GOLDEN) ---------------------------------------------------
  {
    const std::string path = tmp + "/iterations.csv";
    {
      IterationCsvWriter w(path);
      SimpIterationObservation a;
      a.iteration = 1;
      a.compliance = 12.5;
      a.change = 0.2;
      a.volume_fraction = 0.68;
      a.cg_iterations = 14;
      a.cg_used_multigrid = true;
      a.plateau = false;
      a.cg_hier_built = true;         // handoff 128: MG carried -> hierarchy built
      a.cg_mg_cycles_attempted = 14;  // carried in 14 cycles
      w.append_at(0, a, 1000);

      SimpIterationObservation b;
      b.iteration = 2;
      b.compliance = 9.25;
      b.volume_fraction = 0.6801;
      b.cg_iterations = 4390;         // Jacobi fallback count
      b.cg_used_multigrid = false;    // fell back...
      b.cg_hier_built = true;         // ...after the hierarchy BUILT -> stagnation
      b.cg_mg_cycles_attempted = 300; // burned the full budget before bailing
      b.plateau = true;
      b.beta = 8.0;  // handoff 123: a projecting iteration carries its stage β
      b.infeasible = true;  // handoff 131: the rung ends on this row
      b.cg_recycle_dim = 16;  // handoff 133: a recycled Jacobi solve, k=16
      w.append_at(0, b, 1050);
      check(w.rows() == 2, "CSV writer counted 2 rows");
    }
    const std::string body = read_all(path);
    // Row a leaves beta at its default 0 (not projecting); row b sets β=8. Row a
    // is an MG-carried solve (hier_built=1, cycles=14); row b is a STAGNATION
    // fallback (cg_multigrid=0 but hier_built=1, cycles=300 = the full budget).
    // Row b also carries handoff 131's infeasible=1 (the rung-ending verdict) and
    // handoff 133's recycle_dim=16 (a Jacobi solve the recycle basis preconditioned);
    // row a leaves both at their default 0 — and note row a is the MG-carried solve,
    // where the armed Jacobi-only posture means recycle_dim is 0 BY DESIGN.
    const std::string expected =
        "rung,iter,wall_ms,compliance,achieved_vf,plateau,cg_iters,cg_multigrid,"
        "beta,hier_built,mg_cycles_attempted,infeasible,recycle_dim\n"
        "0,1,1000,12.5,0.680000,0,14,1,0,1,14,0,0\n"
        "0,2,1050,9.25,0.680100,1,4390,0,8,1,300,1,16\n";
    check(body == expected, "CSV golden: header + rows are byte-exact");
    // Schema string is the documented one.
    check(std::string(kIterationCsvHeader) ==
              "rung,iter,wall_ms,compliance,achieved_vf,plateau,cg_iters,"
              "cg_multigrid,beta,hier_built,mg_cycles_attempted,infeasible,recycle_dim",
          "CSV header constant matches documented schema");
  }

  // --- density snapshot round-trip -------------------------------------------
  {
    VoxelGrid g = make_grid(4, 3, 2, 2.5);
    std::vector<double> d(g.voxel_count());
    for (std::size_t i = 0; i < d.size(); ++i)
      d[i] = static_cast<double>(i) / static_cast<double>(d.size());  // [0,1)
    write_density_snapshot(tmp, "snap_test", g, d, /*rung=*/2, /*iter=*/30,
                           /*boundary=*/true);
    const std::vector<float> rt =
        read_density_f16(tmp + "/snap_test.f16", d.size());
    check(rt.size() == d.size(), "snapshot round-trip voxel count");
    double max_err = 0.0;
    for (std::size_t i = 0; i < d.size(); ++i)
      max_err = std::max(max_err,
                         std::fabs(static_cast<double>(rt[i]) - d[i]));
    check(max_err <= 5e-4, "snapshot write->read max abs error within f16");
    const std::string js = read_all(tmp + "/snap_test.json");
    check(js.find("\"dims\":[4,3,2]") != std::string::npos, "sidecar dims");
    check(js.find("\"spacing\":2.5") != std::string::npos, "sidecar spacing");
    check(js.find("\"rung\":2") != std::string::npos, "sidecar rung");
    check(js.find("\"iter\":30") != std::string::npos, "sidecar iter");
    check(js.find("\"boundary\":true") != std::string::npos, "sidecar boundary");
    check(js.find("\"dtype\":\"float16\"") != std::string::npos, "sidecar dtype");
  }

  // --- SnapshotCapture cadence + cap eviction --------------------------------
  {
    const std::string sdir = tmp + "/caps";
    std::filesystem::remove_all(sdir);
    VoxelGrid g = make_grid(3, 3, 3, 1.0);
    std::vector<double> d(g.voxel_count(), 0.4);
    SnapshotCapture cap(sdir, /*every_n=*/10, /*cap=*/2);
    // Non-boundary at iters 1..25: only 10 and 20 pass the every-10 cadence.
    for (int it = 1; it <= 25; ++it)
      cap.capture(g, d, /*rung=*/0, it, /*boundary=*/false);
    // A rung boundary always writes and is never evicted.
    cap.capture(g, d, /*rung=*/0, /*iter=*/26, /*boundary=*/true);
    check(cap.written() == 3, "capture wrote iters 10, 20 + boundary (3)");
    check(cap.evicted() == 0, "no eviction yet (cap=2, 2 per-iter snaps)");
    // A third per-iter snapshot (iter 30) triggers eviction of the oldest (10).
    cap.capture(g, d, /*rung=*/0, /*iter=*/30, /*boundary=*/false);
    check(cap.evicted() == 1, "cap exceeded -> oldest per-iter snapshot evicted");
    check(!std::filesystem::exists(sdir + "/snap_rung0_iter0010.f16"),
          "oldest per-iter snapshot file removed");
    check(std::filesystem::exists(sdir + "/snap_rung0_iter0026_boundary.f16"),
          "boundary snapshot retained through eviction");
    check(std::filesystem::exists(sdir + "/snap_rung0_iter0020.f16"),
          "newer per-iter snapshot retained");
    check(std::filesystem::exists(sdir + "/snap_rung0_iter0030.f16"),
          "newest per-iter snapshot retained");
  }

  // --- run version record ----------------------------------------------------
  {
    RunInfo info;
    info.cli_version = "0.1.0";
    info.fingerprint = "abc123def456";
    info.mode = "minimize_plastic";
    info.material = "PLA";
    info.resolution = 96;
    info.load_source = "self_weight";
    info.solver = "MultigridCG_Matfree";
    info.cg_multigrid = true;
    info.mg_levels = 4;
    info.cg_multigrid_observed = true;  // OBSERVED outcome -> emit the real values
    info.galerkin_block_cache = true;
    info.mixed_precision = false;
    info.matfree_threads = 6;
    info.krylov_recycling = true;      // handoff 133
    info.krylov_recycle_dim = 16;
    info.warm_start_inherit = false;
    info.warm_start_coarse = false;
    info.projection = false;
    info.min_feature_mm = 2.5;
    info.margin_stop = 1.5;
    info.infill_percent = 100.0;
    info.has_design_box = true;
    info.ladder = {0.68, 0.52, 0.38, 0.26};
    info.created_wall_ms = 1234567890123LL;
    info.iteration_csv = true;
    info.density_snapshots = false;
    info.snapshot_every = 10;
    info.snapshot_cap = 40;
    const std::string js = run_info_json(info);
    check(js.find("\"fingerprint\": \"abc123def456\"") != std::string::npos,
          "run_info fingerprint");
    check(js.find("\"solver\": \"MultigridCG_Matfree\"") != std::string::npos,
          "run_info solver");
    check(js.find("\"cg_multigrid\": true") != std::string::npos,
          "run_info cg_multigrid (observed MG outcome)");
    check(js.find("\"mg_levels\": 4") != std::string::npos, "run_info mg_levels");
    // Walk-back Amendment 1: before the outcome is observed, cg_multigrid /
    // mg_levels are null — an unfinished run asserts NOTHING about multigrid.
    RunInfo pending = info;
    pending.cg_multigrid_observed = false;
    const std::string pjs = run_info_json(pending);
    check(pjs.find("\"cg_multigrid\": null") != std::string::npos,
          "run_info cg_multigrid is null until observed");
    check(pjs.find("\"mg_levels\": null") != std::string::npos,
          "run_info mg_levels is null until observed");
    check(js.find("\"galerkin_block_cache\": true") != std::string::npos,
          "run_info galerkin cache");
    check(js.find("\"matfree_threads\": 6") != std::string::npos,
          "run_info threads");
    // Handoff 133 — the Krylov recycling echo is CONFIG, not an outcome, so it is
    // written up front and is never null: a run record must be able to rule the
    // accelerator OUT as well as in.
    check(js.find("\"krylov_recycling\": true") != std::string::npos,
          "run_info krylov recycling echo");
    check(js.find("\"krylov_recycle_dim\": 16") != std::string::npos,
          "run_info krylov recycle dimension echo");
    check(js.find("\"ladder\": [0.68, 0.52, 0.38, 0.26]") != std::string::npos,
          "run_info ladder echo");
    check(js.find("\"created_wall_ms\": 1234567890123") != std::string::npos,
          "run_info timestamp");
    // Also exercise the on-disk writer.
    write_run_info(tmp + "/run_info.json", info);
    check(read_all(tmp + "/run_info.json") == js, "write_run_info == run_info_json");
  }

  if (g_failures == 0) {
    std::printf("observability: all %d checks passed\n", g_checks);
    return 0;
  }
  std::fprintf(stderr, "observability: %d of %d checks FAILED\n", g_failures,
               g_checks);
  return 1;
}
