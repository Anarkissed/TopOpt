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
#include <limits>
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
      // active-domain phase 1: row a leaves active_fraction at its default 1.0
      // (the full domain ran); row b is a restricted solve at 18.8% active.
      b.active_fraction = 0.188;
      // Task 2026-08-02-iteration-phase-timing: row b also carries a PHASE
      // breakdown, pinned here so the accounting the CSV promises is a golden
      // fact and not a comment. The numbers are the anomaly's shape in miniature
      // — a 500 ms iteration whose linear solve is 480 ms, of which 400 ms is the
      // GenEO coarse-operator refresh that the 4390 cg_iters above cannot see —
      // with residual_ms = total - (filter+project+solve+update+analysis+observe)
      // = 500 - (5+2+480+8+1+1) = 3 ms, and the solver_* columns SUB-SPLITTING
      // solve_ms rather than adding to it. Row a leaves `phases` default, which
      // is how a run with no timing (or a platform that cannot answer the memory
      // question) reads: zeros for the spans, NEGATIVE for the memory columns.
      b.cg_geneo_dim = 2048;
      b.cg_geneo_action = 2;  // coarse operator REFRESHED for this system
      // The ENGAGEMENT GATE's decision on this row (handoff
      // 2026-08-02-geneo-disarm): the solve burned 4200 plain iterations against
      // a threshold of 4160 = 2*2048 + 0 + 2*32, i.e. it cleared the measured
      // price of the armed alternative and only then engaged. The pair (burn,
      // threshold) IS the decision, so pinning it here makes the CSV's promise
      // that a later reader can GRADE the decision a test rather than a comment.
      b.cg_geneo_burn = 4200;
      b.cg_geneo_threshold = 4160;
      b.phases.total_ms = 500.0;
      b.phases.tail_prev_ms = 4.0;
      b.phases.filter_ms = 5.0;
      b.phases.project_ms = 2.0;
      b.phases.solve_ms = 480.0;
      b.phases.fea_ms = 478.0;
      b.phases.sens_ms = 2.0;
      b.phases.update_ms = 8.0;
      b.phases.analysis_ms = 1.0;
      b.phases.observe_ms = 1.0;
      b.phases.residual_ms = 3.0;
      b.phases.solver_build_ms = 12.0;
      b.phases.solver_mg_build_ms = 0.0;  // latched: the build never ran
      b.phases.solver_mg_ms = 0.0;
      b.phases.solver_cg_ms = 60.0;
      b.phases.solver_geneo_setup_ms = 400.0;
      b.phases.solver_geneo_apply_ms = 6.0;
      b.phases.solver_recycle_ms = 0.5;
      b.phases.fea_solves = 1;
      b.phases.matvecs = 6438;
      b.phases.rss_mb = 1234.5;
      b.phases.peak_rss_mb = 1300.25;
      b.phases.compressed_mb = 0.0;
      b.phases.available_mb = 8192.0;
      b.phases.major_faults = 0;
      b.phases.swapins = 0;
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
    const std::string kHeader =
        "rung,iter,wall_ms,compliance,achieved_vf,plateau,cg_iters,cg_multigrid,"
        "beta,hier_built,mg_cycles_attempted,infeasible,recycle_dim,"
        "active_fraction,"
        "total_ms,tail_prev_ms,filter_ms,project_ms,solve_ms,fea_ms,sens_ms,"
        "update_ms,analysis_ms,observe_ms,residual_ms,"
        "solver_build_ms,mg_build_ms,mg_ms,cg_ms,geneo_setup_ms,geneo_apply_ms,"
        "recycle_ms,"
        "fea_solves,matvecs,geneo_dim,geneo_action,geneo_burn,geneo_threshold,"
        "rss_mb,peak_rss_mb,compressed_mb,available_mb,major_faults,swapins";
    const std::string expected =
        kHeader + "\n" +
        "0,1,1000,12.5,0.680000,0,14,1,0,1,14,0,0,1.000000,"
        "0.000,0.000,0.000,0.000,0.000,0.000,0.000,0.000,0.000,0.000,0.000,"
        "0.000,0.000,0.000,0.000,0.000,0.000,0.000,"
        "0,0,0,0,0,0,"
        "-1.00,-1.00,-1.00,-1.00,-1,-1\n"
        "0,2,1050,9.25,0.680100,1,4390,0,8,1,300,1,16,0.188000,"
        "500.000,4.000,5.000,2.000,480.000,478.000,2.000,8.000,1.000,1.000,"
        "3.000,"
        "12.000,0.000,0.000,60.000,400.000,6.000,0.500,"
        "1,6438,2048,2,4200,4160,"
        "1234.50,1300.25,0.00,8192.00,0,0\n";
    check(body == expected, "CSV golden: header + rows are byte-exact");
    // Schema string is the documented one.
    check(std::string(kIterationCsvHeader) == kHeader,
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

    // Lattice certification posture (handoff 2026-07-27-lattice-certification). A
    // non-latticed run (every current run) emits NO lattice key at all — its record is
    // byte-for-byte the pre-lattice record; a latticed run appends a "lattice" object.
    check(js.find("\"lattice\"") == std::string::npos,
          "run_info omits the lattice key entirely when no region is latticed");
    RunInfo latt = info;
    latt.lattice_present = true;
    latt.lattice_topology = "octet";
    latt.lattice_cell_size_mm = 8.0;
    latt.lattice_rho_min = 0.20;
    latt.lattice_rho_max = 0.45;
    latt.lattice_region_voxels = 4096;
    latt.lattice_strength_uncertified = true;
    const std::string ljs = run_info_json(latt);
    check(ljs.find("\"topology\": \"octet\"") != std::string::npos,
          "run_info lattice topology echoed");
    check(ljs.find("\"cell_size_mm\": 8") != std::string::npos,
          "run_info lattice cell size echoed");
    check(ljs.find("\"rho_min\": 0.2") != std::string::npos &&
          ljs.find("\"rho_max\": 0.45") != std::string::npos,
          "run_info lattice relative-density range echoed");
    check(ljs.find("\"region_voxels\": 4096") != std::string::npos,
          "run_info lattice region size echoed");
    check(ljs.find("\"strength_uncertified\": true") != std::string::npos,
          "run_info lattice strut-strength-uncertified flag echoed");
  }

  // Grading-law report (handoff 2026-07-29-lattice-grading-law). Absent => NO grading
  // key (byte-identical, bar L1); present => a trailing "grading" object with the
  // limits read from core, the L4 solid-fallback counts and the L3 printability report.
  {
    RunInfo base;
    base.fingerprint = "abc";
    check(run_info_json(base).find("\"grading\"") == std::string::npos,
          "run_info omits the grading key entirely when no grading block ran");
    RunInfo gr = base;
    gr.grading_present = true;
    gr.grading_topology = "octet";
    gr.grading_band_rho_min = 0.14764;
    gr.grading_band_rho_max = 0.59093;
    gr.grading_cells_per_member_floor = 5.0;
    gr.grading_cell_size_mm = 2.5;
    gr.grading_printability_floor_mm = 2.5;
    gr.grading_cell_size_floored = true;
    gr.grading_min_extrudable_width_mm = 0.4;
    gr.grading_rho_min_used = 0.14764;
    gr.grading_rho_max_used = 0.59093;
    gr.grading_region_voxels = 1000;
    gr.grading_latticed_voxels = 600;
    gr.grading_solid_fallback_voxels = 400;
    gr.grading_min_member_width_mm = 13.0;
    gr.grading_min_cells_per_member = 5.2;
    gr.grading_min_strut_diameter_mm = 0.4;
    gr.grading_max_strut_diameter_mm = 1.5;
    gr.grading_any_strut_below_min = false;
    gr.grading_region_ungradeable = false;
    const std::string gjs = run_info_json(gr);
    check(gjs.find("\"grading\": {") != std::string::npos, "grading object emitted");
    check(gjs.find("\"cells_per_member_floor\": 5") != std::string::npos,
          "grading floor (read from core) echoed");
    check(gjs.find("\"band_rho_max\": 0.59093") != std::string::npos,
          "grading band top (read from core) echoed");
    check(gjs.find("\"solid_fallback_voxels\": 400") != std::string::npos,
          "grading L4 solid-fallback count echoed");
    check(gjs.find("\"any_strut_below_min\": false") != std::string::npos,
          "grading printability honesty flag echoed");
    // +inf member width serializes as null (JSON has no infinity).
    RunInfo inf = gr;
    inf.grading_min_member_width_mm = std::numeric_limits<double>::infinity();
    inf.grading_min_cells_per_member = std::numeric_limits<double>::infinity();
    const std::string ijs = run_info_json(inf);
    check(ijs.find("\"min_member_width_mm\": null") != std::string::npos,
          "grading +inf member width serializes as null");
  }

  if (g_failures == 0) {
    std::printf("observability: all %d checks passed\n", g_checks);
    return 0;
  }
  std::fprintf(stderr, "observability: %d of %d checks FAILED\n", g_failures,
               g_checks);
  return 1;
}
