// mma_probe.cpp — measurement harness (NOT a CI test). Drives simp_optimize on
// self-weight cantilever / box geometries under MMA and prints the per-iteration
// compliance history + timing so the plateau rule can be characterised against
// the true converged value. Modes: `cost` (64^3 s/iter, matrix-free MG-CG — the
// production solver, STEP 1); `curve` (raw compliance curves, STEP 3); `ladder`
// (4-rung wall + iteration counts, STEP 4). `curve`/`ladder` use the fast cached
// JacobiCG — the compliance CURVE and the iteration COUNTS are solver-independent
// physics, and matrix-free rebuilds its MG hierarchy every solve (far slower at
// these sub-64^3 sizes); the 64^3 production s/iter is measured with matrix-free.
//
// This file lives under tests/harness and is compiled standalone (see the
// one-off c++ line in the handoff); it is not wired into CTest.

#include <chrono>
#include <cmath>
#include <cstdio>
#include <string>
#include <vector>

#include "topopt/fea.hpp"
#include "topopt/simp.hpp"
#include "topopt/voxel.hpp"

using namespace topopt;

namespace {

VoxelGrid make_cantilever(int nx, int ny, int nz, double h,
                          std::vector<DirichletBC>& bcs) {
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

struct Case {
  std::string name;
  int nx, ny, nz;
  double vf;
  double gravity;      // self-weight scale
  bool point_load;     // add a concentrated tip load (heavily-loaded case)
  double tip_scale;    // magnitude of tip load relative to self-weight total
};

void run_case(const Case& cs, int cap, double plateau_tol, int plateau_window,
              SolverKind solver, bool time_it) {
  std::vector<DirichletBC> bcs;
  VoxelGrid g = make_cantilever(cs.nx, cs.ny, cs.nz, 2.0, bcs);

  SimpParams params;
  params.youngs_modulus = 3500.0;
  params.poisson = 0.33;
  params.penalty = 3.0;

  const double density = 1.24e-3;  // g/mm^3-ish scale used by tests
  std::vector<NodalLoad> loads =
      self_weight_loads(g, density, cs.gravity, Vec3{0, 0, -1});

  if (cs.point_load) {
    // Concentrated downward load at the free-tip mid-face node — a heavily
    // loaded case where compliance is dominated by a single member path.
    double total_w = 0.0;
    for (const auto& nl : loads) total_w += std::fabs(nl.value);
    const int n = fea_node_index(g, cs.nx, cs.ny / 2, cs.nz / 2);
    loads.push_back({n, 2, -cs.tip_scale * total_w});
  }

  DesignMask mask = make_active_mask(g);

  SimpOptions opt;
  opt.volume_fraction = cs.vf;
  opt.filter_radius = 1.5;
  opt.move = 0.2;
  opt.updater = SimpUpdater::MMA;
  opt.solver = solver;
  opt.max_iterations = cap;
  opt.change_tol = 0.0;  // never fire on change_tol; we study the raw curve
  opt.cg_tolerance = 1e-8;
  opt.mma_plateau_window = plateau_window;  // 0 disables plateau (raw curve)
  opt.mma_plateau_tol = plateau_tol;

  auto t0 = std::chrono::steady_clock::now();
  SimpOptimizeResult r = simp_optimize(g, params, bcs, loads, opt, mask);
  auto t1 = std::chrono::steady_clock::now();
  double secs = std::chrono::duration<double>(t1 - t0).count();

  std::printf("CASE %s  grid=%dx%dx%d vf=%.3f grav=%.3g%s\n", cs.name.c_str(),
              cs.nx, cs.ny, cs.nz, cs.vf, cs.gravity,
              cs.point_load ? " +tip" : "");
  std::printf("  iters=%d converged=%d compliance=%.6e vf_ach=%.4f\n",
              r.iterations, (int)r.converged, r.compliance, r.volume_fraction);
  if (time_it && r.iterations > 0)
    std::printf("  wall=%.2fs  s/iter=%.3f\n", secs,
                secs / r.iterations);
  // Full compliance curve (compliance at START of each iteration).
  std::printf("  curve:");
  for (std::size_t i = 0; i < r.history.size(); ++i) {
    std::printf(" %.6e", r.history[i].compliance);
  }
  std::printf("\n");
  std::fflush(stdout);
}

}  // namespace

int main(int argc, char** argv) {
  std::string mode = argc > 1 ? argv[1] : "cost";

  if (mode == "probe") {
    // Investigate ONE ladder rung's raw curve: n^3 self-weight cube at a given
    // vf, plateau OFF, high cap. argv[2]=n, argv[3]=vf. JacobiCG.
    int n = argc > 2 ? std::atoi(argv[2]) : 24;
    double vf = argc > 3 ? std::atof(argv[3]) : 0.2;
    std::vector<DirichletBC> bcs;
    VoxelGrid g = make_cantilever(n, n, n, 2.0, bcs);
    SimpParams params;
    params.youngs_modulus = 3500.0; params.poisson = 0.33; params.penalty = 3.0;
    std::vector<NodalLoad> loads =
        self_weight_loads(g, 1.24e-3, 1.0, Vec3{0, 0, -1});
    DesignMask mask = make_active_mask(g);
    SimpOptions opt;
    opt.volume_fraction = vf;
    opt.filter_radius = 1.5;
    opt.move = 0.2;
    opt.updater = SimpUpdater::MMA;
    opt.solver = SolverKind::JacobiCG;
    opt.max_iterations = 250;
    opt.change_tol = 0.0;
    opt.cg_tolerance = 1e-8;
    opt.mma_plateau_window = 0;  // raw curve
    SimpOptimizeResult r = simp_optimize(g, params, bcs, loads, opt, mask);
    std::printf("CASE probe_%dcube_vf%.2f  grid=%dx%dx%d vf=%.3f\n", n, vf,
                n, n, n, vf);
    std::printf("  iters=%d compliance=%.6e\n", r.iterations, r.compliance);
    std::printf("  curve:");
    for (const auto& h : r.history) std::printf(" %.6e", h.compliance);
    std::printf("\n");
    return 0;
  }

  if (mode == "ladder") {
    // STEP 4 — measured wall time for a full 4-rung ladder (4 independent
    // simp_optimize rungs at descending vf, exactly as minimize_plastic drives
    // them), matrix-free MG-CG. argv[2]=n (cube edge), argv[3]="plateau"|"cap60".
    int n = argc > 2 ? std::atoi(argv[2]) : 48;
    std::string cfg = argc > 3 ? argv[3] : "plateau";
    const std::vector<double> ladder = {0.5, 0.4, 0.3, 0.2};
    std::vector<DirichletBC> bcs;
    VoxelGrid g = make_cantilever(n, n, n, 2.0, bcs);
    SimpParams params;
    params.youngs_modulus = 3500.0; params.poisson = 0.33; params.penalty = 3.0;
    std::vector<NodalLoad> loads =
        self_weight_loads(g, 1.24e-3, 1.0, Vec3{0, 0, -1});
    DesignMask mask = make_active_mask(g);
    double total = 0.0;
    std::printf("LADDER n=%d cfg=%s (matfree)\n", n, cfg.c_str());
    for (double vf : ladder) {
      SimpOptions opt;
      opt.volume_fraction = vf;
      opt.filter_radius = 1.5;
      opt.move = 0.2;
      opt.updater = SimpUpdater::MMA;
      opt.solver = SolverKind::MultigridCG_Matfree;
      opt.cg_tolerance = 1e-8;
      if (cfg == "cap60") {
        opt.max_iterations = 60;
        opt.change_tol = 0.0;
        opt.mma_plateau_window = 0;  // pre-fix: cap terminates
      } else {
        opt.max_iterations = 200;     // raised safety cap (default)
        opt.mma_plateau_window = 10;  // plateau terminates (production default)
        opt.mma_plateau_tol = 1e-3;
      }
      auto t0 = std::chrono::steady_clock::now();
      SimpOptimizeResult r = simp_optimize(g, params, bcs, loads, opt, mask);
      double s = std::chrono::duration<double>(
                     std::chrono::steady_clock::now() - t0).count();
      total += s;
      std::printf("  rung vf=%.2f  it=%d converged=%d  c=%.6e  wall=%.1fs\n",
                  vf, r.iterations, (int)r.converged, r.compliance, s);
      std::fflush(stdout);
    }
    std::printf("  LADDER TOTAL wall=%.1fs (%.2f min)\n", total, total / 60.0);
    return 0;
  }

  if (mode == "cost") {
    // STEP 1 — s/iter at 64^3, matrix-free MG-CG, a few iters is enough to time.
    Case c{"cost64", 64, 64, 64, 0.30, 1.0, false, 0.0};
    run_case(c, 6, 1e-3, 0, SolverKind::MultigridCG_Matfree, true);
  } else if (mode == "curve") {
    // STEP 3 — full raw compliance curves (plateau disabled) at a high cap on
    // several geometries, matrix-free MG-CG. Cap passed as argv[2], case name
    // (or "all") as argv[3]. Timed per case (also feeds STEP 4 cost).
    int cap = argc > 2 ? std::atoi(argv[2]) : 200;
    std::string which = argc > 3 ? argv[3] : "all";
    std::vector<Case> cases = {
        {"cantilever_64x4x32", 64, 4, 32, 0.26, 1.0, false, 0.0},
        {"blocky_24x24x12", 24, 24, 12, 0.40, 1.0, false, 0.0},
        {"tiploaded_64x8x16", 64, 8, 16, 0.30, 0.2, true, 4.0},
    };
    // The compliance CURVE (all STEP 3 needs) is solver-independent physics, so
    // use the fast cached-assembly JacobiCG here — matrix-free rebuilds the MG
    // hierarchy every solve and is far slower at these sub-64^3 sizes. STEP 1/4
    // production timing uses matrix-free MG-CG at 64^3 (mode "cost").
    for (const auto& cs : cases)
      if (which == "all" || which == cs.name)
        run_case(cs, cap, 1e-3, 0, SolverKind::MultigridCG_Matfree, true);
  }
  return 0;
}
