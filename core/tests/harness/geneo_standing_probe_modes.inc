// geneo_standing_probe_modes.inc — the measurement modes. Included by
// geneo_standing_probe.cpp (one TU; the harness keeps the file split for
// readability the way geneo_twolevel_probe does).

namespace {

constexpr double kCertTol = 1e-8;
constexpr double kNu = 0.33;
constexpr double kE0 = 3500.0;
constexpr double kRhoMin = 1e-3;

// ===========================================================================
// THE OC TRAJECTORY — a real design sequence on the PINNED post-latch solve.
//
// Every iteration: filter -> SIMP moduli -> ONE matrix-free Jacobi-CG solve
// (simp_compliance routed through the matrix-free multigrid entry point, whose
// hierarchy is REJECTED here by pin_to_jacobi_fallback, so it lands in
// mf_cg_solve) -> OC update. That is exactly the solve sequence the latched run
// performs, with the moduli MOVING every iteration — which is what makes the
// GenEO coarse-operator refresh mandatory and therefore what decides the
// economics.
// ===========================================================================
struct OcCase {
  VoxelGrid grid;
  std::vector<DirichletBC> bcs;
  std::vector<NodalLoad> loads;
  double vf = 0.35;
  std::string label;
};

// The analysis grid directly: a wall-mount bracket's load path embedded in a
// dilute designable box, with 4 bolt clearances carved out as permanently void
// voxels (what a clearance IS), and an ODD z-axis so the multigrid hierarchy is
// rejected outright under pad mode 0.
OcCase oc_case() {
  int n = 24;
  if (const char* e = std::getenv("TOPOPT_GSP_N")) n = std::atoi(e);
  double dil = 0.5;
  if (const char* e = std::getenv("TOPOPT_GSP_DIL")) dil = std::atof(e);
  double vf = 0.35;
  if (const char* e = std::getenv("TOPOPT_GSP_VF")) vf = std::atof(e);

  OcCase C;
  C.vf = vf;
  VoxelGrid& g = C.grid;
  const int pad = std::max(1, int(n * dil));
  g.nx = n + pad;
  g.ny = std::max(6, n / 2);
  g.nz = n + pad;
  if (g.nz % 2 == 0) ++g.nz;  // ODD axis => hierarchy rejected under pad mode 0
  g.spacing = 1.5;
  g.origin = Vec3{0.0, 0.0, 0.0};
  g.tags.assign(static_cast<std::size_t>(g.nx) * g.ny * g.nz,
                VoxelTag::Interior);

  // Bolt clearances: 4 keep-outs through the wall plate, permanently void.
  const int cr = std::max(1, n / 12);
  const int cdepth = std::max(2, n / 5);
  const int yq[2] = {g.ny / 4, (3 * g.ny) / 4};
  const int zq[2] = {g.nz / 4, (3 * g.nz) / 4};
  for (int yc : yq)
    for (int zc : zq)
      for (int i = 0; i < cdepth; ++i)
        for (int j = yc - cr; j <= yc + cr; ++j)
          for (int k = zc - cr; k <= zc + cr; ++k)
            if (j >= 0 && j < g.ny && k >= 0 && k < g.nz)
              g.set_tag(i, j, k, VoxelTag::Empty);

  // Wall face fixed (x = 0), tip load at x = nx-1, bottom band, downward.
  for (int c = 0; c <= g.nz; ++c)
    for (int b = 0; b <= g.ny; ++b) {
      const int nd = fea_node_index(g, 0, b, c);
      C.bcs.push_back({nd, 0, 0.0});
      C.bcs.push_back({nd, 1, 0.0});
      C.bcs.push_back({nd, 2, 0.0});
    }
  const int tip_band = std::max(2, n / 8);
  for (int k = 0; k < tip_band; ++k)
    for (int j = 0; j < g.ny; ++j) g.set_tag(g.nx - 1, j, k, VoxelTag::Load);
  C.loads = traction_loads(g, VoxelTag::Load, Vec3{0.0, 0.0, -40.0});

  char buf[160];
  std::snprintf(buf, sizeof buf,
                "OC bracket %dx%dx%d (%zu voxels) vf=%.2f, 4 bolt clearances",
                g.nx, g.ny, g.nz, g.voxel_count(), vf);
  C.label = buf;
  return C;
}

struct OcIter {
  int iter = 0;
  int cg = 0;
  int used_mg = 0;
  int geneo_dim = 0;
  int geneo_action = 0;
  double solve_s = 0.0;
  double compliance = 0.0;
  double penalty = 0.0;
};

struct OcRun {
  std::string label;
  std::vector<OcIter> its;
  long long cg_total = 0;
  double wall = 0.0;
  double solve_s = 0.0;
  long long builds = 0, refreshes = 0, armed = 0, coarse_matvecs = 0;
  int basis_dim = 0;
  double basis_mb = 0.0;
  double build_s = 0.0, refresh_s = 0.0, apply_s = 0.0;
  long long peak_rss = 0;
  std::vector<double> x_final;
  bool ok = true;
};

// p-continuation schedule: the classic SIMP continuation, and the harness's
// CONTINUATION PARAMETER for W5b. `p_steps` iterations at each of p = 1, 2, 3.
double penalty_at(int it, int p_steps) {
  if (p_steps <= 0) return 3.0;
  const int stage = it / p_steps;
  if (stage == 0) return 1.0;
  if (stage == 1) return 2.0;
  return 3.0;
}

OcRun oc_run(const std::string& label, const OcCase& C, int iters,
             const GeneoProbeConfig& cfg, bool geneo, int p_steps,
             bool force_rebuild_on_continuation, bool trace = true) {
  pin_to_jacobi_fallback();
  fea_set_krylov_recycling(false);
  fea_reset_krylov_recycle_space();
  fea_set_geneo_twolevel(geneo);
  fea_reset_geneo_basis();
  fea_detail::geneo_set_probe_config(cfg);

  OcRun R;
  R.label = label;
  const DensityFilter filt =
      make_density_filter(C.grid, physical_filter_radius(2.5, C.grid.spacing));
  std::vector<double> x = simp_uniform_density(C.grid, C.vf);
  double last_p = -1.0;
  const double t0 = now_s();
  for (int it = 0; it < iters; ++it) {
    SimpParams params;
    params.youngs_modulus = kE0;
    params.poisson = kNu;
    params.penalty = penalty_at(it, p_steps);
    params.density_min = kRhoMin;
    if (force_rebuild_on_continuation && last_p >= 0.0 &&
        params.penalty != last_p)
      fea_detail::geneo_request_rebuild();
    last_p = params.penalty;

    const std::vector<double> xp = filt.filter_density(x);
    const double ts = now_s();
    SimpCompliance c;
    try {
      c = simp_compliance(C.grid, params, xp, C.bcs, C.loads, kCertTol, 0,
                          nullptr, nullptr, SolverKind::MultigridCG_Matfree);
    } catch (const std::exception& e) {
      std::printf("      it %-3d SOLVE FAILED: %s\n", it + 1, e.what());
      R.ok = false;
      break;
    }
    const double solve_s = now_s() - ts;
    OcIter rec;
    rec.iter = it + 1;
    rec.cg = c.cg.iterations;
    rec.used_mg = c.cg.used_multigrid ? 1 : 0;
    rec.geneo_dim = c.cg.geneo_dim;
    rec.geneo_action = c.cg.geneo_action;
    rec.solve_s = solve_s;
    rec.compliance = c.compliance;
    rec.penalty = params.penalty;
    R.its.push_back(rec);
    R.cg_total += rec.cg;
    R.solve_s += solve_s;
    if (trace)
      std::printf("      it %-3d p=%.0f cg=%-6d mg=%d geneo(N_t=%-5d act=%d) "
                  "%6.2f s\n",
                  rec.iter, rec.penalty, rec.cg, rec.used_mg, rec.geneo_dim,
                  rec.geneo_action, solve_s);
    x = oc_update(C.grid, filt, x, c.dcompliance, C.vf, 0.2, kRhoMin);
  }
  R.wall = now_s() - t0;
  R.builds = fea_geneo_basis_builds();
  R.refreshes = fea_geneo_coarse_refreshes();
  R.armed = fea_geneo_armed_solves();
  R.basis_dim = fea_geneo_basis_dim();
  R.basis_mb = static_cast<double>(fea_geneo_basis_bytes()) / 1048576.0;
  R.coarse_matvecs = fea_detail::geneo_probe_coarse_matvecs();
  R.build_s = fea_detail::geneo_probe_build_seconds();
  R.refresh_s = fea_detail::geneo_probe_refresh_seconds();
  R.apply_s = fea_detail::geneo_probe_apply_seconds();
  R.peak_rss = peak_rss_bytes();
  R.x_final = x;
  fea_set_geneo_twolevel(false);
  fea_reset_geneo_basis();
  fea_detail::geneo_set_probe_config(GeneoProbeConfig{});
  fea_set_mg_parity_pad_mode(1);
  return R;
}

double oc_mean_cg(const OcRun& R) {
  return R.its.empty() ? 0.0 : double(R.cg_total) / double(R.its.size());
}

void print_oc(const OcRun& R) {
  std::printf("  [%-26s] wall=%7.1f s (solve %7.1f s)  CG=%-7lld mean=%.0f  "
              "iters=%zu\n",
              R.label.c_str(), R.wall, R.solve_s, R.cg_total, oc_mean_cg(R),
              R.its.size());
  std::printf("      geneo: builds=%lld refreshes=%lld armed=%lld  N_t=%d "
              "basis=%.1f MB  coarse_matvecs=%lld\n"
              "      geneo wall: build=%.1f s  refresh=%.1f s  apply=%.1f s  "
              "(%.0f%% of run)  peak RSS=%.0f MB\n",
              R.builds, R.refreshes, R.armed, R.basis_dim, R.basis_mb,
              R.coarse_matvecs, R.build_s, R.refresh_s, R.apply_s,
              R.wall > 0 ? 100.0 * (R.build_s + R.refresh_s + R.apply_s) / R.wall
                         : 0.0,
              R.peak_rss / 1048576.0);
}

void write_oc_csv(const std::string& path, const OcRun& R) {
  FILE* fp = std::fopen(path.c_str(), "w");
  if (!fp) return;
  std::fprintf(fp,
               "iter,penalty,cg_iters,used_mg,geneo_dim,geneo_action,solve_s,"
               "compliance\n");
  for (const OcIter& x : R.its)
    std::fprintf(fp, "%d,%.1f,%d,%d,%d,%d,%.4f,%.10g\n", x.iter, x.penalty,
                 x.cg, x.used_mg, x.geneo_dim, x.geneo_action, x.solve_s,
                 x.compliance);
  std::fclose(fp);
  std::printf("  wrote %s\n", path.c_str());
}

double rel_u_diff(const std::vector<double>& a, const std::vector<double>& b) {
  if (a.size() != b.size() || a.empty()) return 1.0;
  double num = 0.0, den = 0.0;
  for (std::size_t i = 0; i < a.size(); ++i) {
    num = std::max(num, std::fabs(a[i] - b[i]));
    den = std::max(den, std::fabs(a[i]));
  }
  return den > 0 ? num / den : num;
}

GeneoProbeConfig standing_cfg() {
  GeneoProbeConfig c;
  c.trigger_iters = 0;  // arm on the FIRST fallback solve — the standing posture
  return c;
}

// ===========================================================================
// W0 — REGIME. Does the fixture sit at the OBSERVED operating point?
// The bar is the maintainer run's steady state: multigrid absent, every solve
// a matrix-free Jacobi-CG in the low hundreds of iterations (~275).
// ===========================================================================
int mode_regime(const SettingsRules& rules, const Material& material,
                const std::string& dir) {
  (void)rules;
  (void)material;
  const OcCase C = oc_case();
  int iters = 12;
  if (const char* e = std::getenv("TOPOPT_GSP_ITERS")) iters = std::atoi(e);
  std::printf("\n===== W0 OPERATING-POINT CHECK — %s =====\n", C.label.c_str());
  const OcRun R = oc_run("baseline (GenEO off)", C, iters, GeneoProbeConfig{},
                         /*geneo=*/false, /*p_steps=*/0, false);
  print_oc(R);
  write_oc_csv(dir + "/regime_iters.csv", R);
  int mg = 0, mn = 1 << 30, mx = 0;
  for (const OcIter& x : R.its) {
    if (x.used_mg) ++mg;
    mn = std::min(mn, x.cg);
    mx = std::max(mx, x.cg);
  }
  const double mean = oc_mean_cg(R);
  const bool matches = R.ok && mg == 0 && mean >= 120.0 && mean <= 600.0;
  std::printf("\n  multigrid ran on %d/%zu solves (target 0 — the latched run)\n",
              mg, R.its.size());
  std::printf("  Jacobi-CG per solve: mean %.0f, min %d, max %d  "
              "(target band [120,600]; the run's ~275)\n",
              mean, mn, mx);
  std::printf("\n===== OPERATING POINT %s =====\n",
              matches ? "REPRODUCED"
                      : "NOT REPRODUCED — retune TOPOPT_GSP_N / TOPOPT_GSP_DIL "
                        "/ TOPOPT_GSP_VF before believing anything downstream");
  return matches ? 0 : 1;
}

// ===========================================================================
// W1 + W2 — THE CHEAP TEST, AND THE AMORTISATION THAT DECIDES IT.
// ===========================================================================
int mode_w1(const SettingsRules& rules, const Material& material,
            const std::string& dir) {
  (void)rules;
  (void)material;
  const OcCase C = oc_case();
  int iters = 20;
  if (const char* e = std::getenv("TOPOPT_GSP_ITERS")) iters = std::atoi(e);
  std::printf("\n===== W1 — LATCHED JACOBI vs STANDING GENEO — %s =====\n",
              C.label.c_str());

  // THE TRUE BASELINE is GenEO OFF — the maintainer's latched run, where the
  // shipped trigger never fires because the solve converges at ~275 < 500.
  std::printf("\n  -- baseline: PLAIN latched Jacobi-CG (GenEO off) --\n");
  const OcRun base = oc_run("plain Jacobi (GenEO off)", C, iters,
                            GeneoProbeConfig{}, /*geneo=*/false, 0, false);
  print_oc(base);

  // What PRODUCTION does on this fixture today. On the maintainer's fixture this
  // is identical to the baseline (275 < 500 => never arms); here the fixture is
  // ABOVE the trigger, so it arms late — reported so the two are not confused.
  std::printf("\n  -- shipped: GenEO armed at the trigger (%d) --\n",
              fea_detail::kGeneoTriggerIters);
  const OcRun shipped = oc_run("shipped (trigger 500)", C, iters,
                               GeneoProbeConfig{}, /*geneo=*/true, 0, false);
  print_oc(shipped);
  write_oc_csv(dir + "/w1_shipped_iters.csv", shipped);

  std::printf("\n  -- standing: GenEO armed on the FIRST solve (trigger 0) --\n");
  const OcRun stand =
      oc_run("standing (trigger 0)", C, iters, standing_cfg(), true, 0, false);
  print_oc(stand);

  write_oc_csv(dir + "/w1_baseline_iters.csv", base);
  write_oc_csv(dir + "/w1_standing_iters.csv", stand);

  std::printf("\n===== W1 TABLE =====\n");
  std::printf("  %-24s %-10s %-10s %-11s %-11s %-9s\n", "posture", "CG total",
              "CG mean", "solve wall", "total wall", "builds");
  std::printf("  %-24s %-10lld %-10.0f %-11.1f %-11.1f %-9lld\n",
              "plain Jacobi (base)", base.cg_total, oc_mean_cg(base),
              base.solve_s, base.wall, base.builds);
  std::printf("  %-24s %-10lld %-10.0f %-11.1f %-11.1f %-9lld\n",
              "shipped (trigger 500)", shipped.cg_total, oc_mean_cg(shipped),
              shipped.solve_s, shipped.wall, shipped.builds);
  std::printf("  %-24s %-10lld %-10.0f %-11.1f %-11.1f %-9lld\n",
              "standing GenEO", stand.cg_total, oc_mean_cg(stand),
              stand.solve_s, stand.wall, stand.builds);
  std::printf("  ratio (standing / baseline): CG %.3fx    WALL %.3fx\n",
              base.cg_total ? double(stand.cg_total) / double(base.cg_total)
                            : 0.0,
              base.wall > 0 ? stand.wall / base.wall : 0.0);

  std::printf("\n===== W2 AMORTISATION =====\n");
  const double per_build =
      stand.builds > 0 ? double(stand.its.size()) / double(stand.builds) : 0.0;
  std::printf("  basis builds          : %lld\n", stand.builds);
  std::printf("  design iterations     : %zu\n", stand.its.size());
  std::printf("  design iters per build: %.1f   (DTU: 7 builds / 200 design "
              "iterations = 28.6)\n",
              per_build);
  std::printf("  coarse refreshes      : %lld — one per solve whose moduli "
              "moved, EACH costing N_t full matvecs\n",
              stand.refreshes);
  std::printf("  coarse matvecs total  : %lld   vs the entire baseline run's "
              "%lld CG iterations (ratio %.2fx)\n",
              stand.coarse_matvecs, base.cg_total,
              base.cg_total ? double(stand.coarse_matvecs) / double(base.cg_total)
                            : 0.0);
  std::printf("  GenEO wall split      : build %.1f s + refresh %.1f s + apply "
              "%.1f s = %.1f s of %.1f s (%.0f%%)\n",
              stand.build_s, stand.refresh_s, stand.apply_s,
              stand.build_s + stand.refresh_s + stand.apply_s, stand.wall,
              stand.wall > 0
                  ? 100.0 * (stand.build_s + stand.refresh_s + stand.apply_s) /
                        stand.wall
                  : 0.0);
  std::printf("  N_t=%d, basis %.1f MB, peak RSS %.0f MB\n", stand.basis_dim,
              stand.basis_mb, stand.peak_rss / 1048576.0);

  const bool wins = stand.wall < base.wall;
  std::printf("\n===== W1 VERDICT: standing GenEO %s latched Jacobi-CG on WALL "
              "(%.1f s vs %.1f s) =====\n",
              wins ? "BEATS" : "DOES NOT BEAT", stand.wall, base.wall);

  FILE* fp = std::fopen((dir + "/w1_summary.csv").c_str(), "w");
  if (fp) {
    std::fprintf(fp,
                 "posture,trigger_iters,cg_total,cg_mean,design_iters,solve_s,"
                 "wall_s,builds,refreshes,armed_solves,basis_dim,basis_mb,"
                 "coarse_matvecs,build_s,refresh_s,apply_s,peak_rss_mb\n");
    auto row = [&](const OcRun& r, int trig) {
      std::fprintf(fp,
                   "%s,%d,%lld,%.1f,%zu,%.2f,%.2f,%lld,%lld,%lld,%d,%.2f,%lld,"
                   "%.2f,%.2f,%.2f,%.0f\n",
                   r.label.c_str(), trig, r.cg_total, oc_mean_cg(r),
                   r.its.size(), r.solve_s, r.wall, r.builds, r.refreshes,
                   r.armed, r.basis_dim, r.basis_mb, r.coarse_matvecs,
                   r.build_s, r.refresh_s, r.apply_s, r.peak_rss / 1048576.0);
    };
    row(base, -1);  // GenEO off
    row(shipped, fea_detail::kGeneoTriggerIters);
    row(stand, 0);
    std::fclose(fp);
    std::printf("  wrote %s/w1_summary.csv\n", dir.c_str());
  }
  return 0;
}

// ===========================================================================
// W1b — THE SCALING THAT DECIDES IT (grid-size sweep).
//
// The standing posture's per-design-iteration overhead is the MANDATORY coarse-
// operator refresh, which costs N_t full matvecs. A CG iteration also costs ~one
// matvec. So the whole question is the ratio
//
//     N_t / k_jacobi     (refresh matvecs per baseline CG iteration)
//
// and those two numbers scale DIFFERENTLY:
//   * N_t ~ (modes per subdomain) x VOLUME / core^3   — grows with the VOLUME
//   * k_jacobi ~ grid DIAMETER                         — grows with the SIDE
// so the ratio grows ~quadratically in the linear grid size. A small fixture
// therefore FLATTERS standing GenEO, and a single-size measurement cannot be
// extrapolated. This mode measures the ratio at several sizes.
//
// The maintainer's operating point, for comparison, is known from two measured
// artifacts: the armed production run reported N_t = 7,588 and the observed
// latched solves ran at ~275 CG iterations => ratio 27.6.
// ===========================================================================
int mode_scale(const SettingsRules& rules, const Material& material,
               const std::string& dir) {
  (void)rules;
  (void)material;
  int iters = 4;
  if (const char* e = std::getenv("TOPOPT_GSP_ITERS")) iters = std::atoi(e);
  std::printf("\n===== W1b — HOW THE REFRESH PRICE SCALES AGAINST THE SOLVE "
              "=====\n");
  std::printf("  %-16s %-9s %-9s %-9s %-9s %-9s %-9s\n", "grid", "voxels",
              "k_jacobi", "N_t", "N_t/k", "k_geneo", "verdict");
  std::vector<std::string> sizes = {"16", "24", "32", "40"};
  if (const char* e = std::getenv("TOPOPT_GSP_SIZES")) {
    sizes.clear();
    std::string s(e), cur;
    for (char ch : s) {
      if (ch == ',') { if (!cur.empty()) sizes.push_back(cur); cur.clear(); }
      else cur.push_back(ch);
    }
    if (!cur.empty()) sizes.push_back(cur);
  }
  FILE* fp = std::fopen((dir + "/w1b_scaling.csv").c_str(), "w");
  if (fp)
    std::fprintf(fp, "n,nx,ny,nz,voxels,k_jacobi,Nt,Nt_over_k,k_geneo,"
                     "jacobi_solve_s,geneo_solve_s,refresh_s,build_s,pays\n");
  for (const std::string& sz : sizes) {
    setenv("TOPOPT_GSP_N", sz.c_str(), 1);
    const OcCase C = oc_case();
    const OcRun b = oc_run("jacobi", C, iters, GeneoProbeConfig{}, false, 0,
                           false, /*trace=*/false);
    const OcRun g = oc_run("standing", C, iters, standing_cfg(), true, 0, false,
                           /*trace=*/false);
    const double kb = oc_mean_cg(b), kg = oc_mean_cg(g);
    const double ratio = kb > 0 ? double(g.basis_dim) / kb : 0.0;
    const bool pays = g.wall < b.wall;
    char gridlbl[32];
    std::snprintf(gridlbl, sizeof gridlbl, "%dx%dx%d", C.grid.nx, C.grid.ny,
                  C.grid.nz);
    std::printf("  %-16s %-9zu %-9.0f %-9d %-9.2f %-9.0f %s\n", gridlbl,
                C.grid.voxel_count(), kb, g.basis_dim, ratio, kg,
                pays ? "standing WINS" : "standing LOSES");
    if (fp)
      std::fprintf(fp, "%s,%d,%d,%d,%zu,%.1f,%d,%.4f,%.1f,%.3f,%.3f,%.3f,%.3f,%d\n",
                   sz.c_str(), C.grid.nx, C.grid.ny, C.grid.nz,
                   C.grid.voxel_count(), kb, g.basis_dim, ratio, kg,
                   b.its.empty() ? 0.0 : b.solve_s / b.its.size(),
                   g.its.empty() ? 0.0 : g.solve_s / g.its.size(),
                   g.refresh_s, g.build_s, pays ? 1 : 0);
  }
  if (fp) {
    std::fclose(fp);
    std::printf("  wrote %s/w1b_scaling.csv\n", dir.c_str());
  }
  std::printf("\n  For scale: the MAINTAINER's run measured N_t = 7,588 at "
              "~275 latched Jacobi iterations => N_t/k = 27.6.\n"
              "  Standing GenEO can only pay when N_t/k is well under 1 — the "
              "refresh alone must cost less than the solve it replaces.\n");
  return 0;
}

// ===========================================================================
// Sweep plumbing (W3 / W4 / W5a): one OC trajectory per config, so the BASIS
// REUSE and the per-solve REFRESH are both exercised — the whole point.
// ===========================================================================
struct SweepRow {
  std::string label;
  double lambda_cut = 0.0;
  int core = 0, block_m = 0, weighting = 0;
  int Nt = 0;
  long long cg_total = 0;
  double cg_mean = 0.0;
  double basis_mb = 0.0;
  double build_s = 0.0, refresh_s = 0.0, apply_s = 0.0, wall = 0.0;
  long long coarse_matvecs = 0, builds = 0;
  int iters = 0;
  bool ok = true;
};

SweepRow sweep_config(const OcCase& C, int iters, const std::string& label,
                      const GeneoProbeConfig& cfg) {
  std::printf("\n  -- %s --\n", label.c_str());
  const OcRun R = oc_run(label, C, iters, cfg, /*geneo=*/true, 0, false);
  SweepRow r;
  r.label = label;
  r.lambda_cut = cfg.lambda_cut;
  r.core = cfg.core_cells;
  r.block_m = cfg.block_m;
  r.weighting = cfg.eig_weighting;
  r.Nt = R.basis_dim;
  r.cg_total = R.cg_total;
  r.cg_mean = oc_mean_cg(R);
  r.basis_mb = R.basis_mb;
  r.build_s = R.build_s;
  r.refresh_s = R.refresh_s;
  r.apply_s = R.apply_s;
  r.wall = R.wall;
  r.coarse_matvecs = R.coarse_matvecs;
  r.builds = R.builds;
  r.iters = static_cast<int>(R.its.size());
  r.ok = R.ok;
  print_oc(R);
  return r;
}

void report_sweep(const std::string& title, const std::vector<SweepRow>& rows,
                  const OcRun& baseline, const std::string& path) {
  // The number that decides it is the STEADY-STATE per-design-iteration cost:
  // the one-off eigensolve is amortised away, but the coarse-operator refresh
  // is paid on EVERY solve whose moduli moved — i.e. every design iteration.
  const int n = std::max<int>(1, static_cast<int>(baseline.its.size()));
  const double base_iter = baseline.wall / n;
  std::printf("\n===== %s =====\n", title.c_str());
  std::printf("  %-18s %-7s %-9s %-9s %-9s %-9s %-10s %-11s %-8s\n", "config",
              "N_t", "CG total", "CG mean", "basis MB", "build s",
              "refresh/it", "steady s/it", "vs base");
  std::printf("  %-18s %-7s %-9lld %-9.0f %-9s %-9s %-10s %-11.2f %-8s\n",
              "plain Jacobi", "-", baseline.cg_total, oc_mean_cg(baseline), "-",
              "-", "-", base_iter, "1.00x");
  for (const SweepRow& r : rows) {
    const int rn = std::max(1, r.iters);
    const double refresh_it = r.refresh_s / rn;
    // steady = whole trajectory minus the one-off build, per iteration.
    const double steady = (r.wall - r.build_s) / rn;
    std::printf("  %-18s %-7d %-9lld %-9.0f %-9.1f %-9.1f %-10.2f %-11.2f "
                "%-8.2fx%s\n",
                r.label.c_str(), r.Nt, r.cg_total, r.cg_mean, r.basis_mb,
                r.build_s, refresh_it, steady,
                base_iter > 0 ? steady / base_iter : 0.0,
                r.ok ? "" : "  [FAILED]");
  }
  std::printf("  (steady s/it = (trajectory wall - one-off eigensolve) / design "
              "iterations: the price once the basis is fully amortised.\n"
              "   'vs base' < 1.00x means standing GenEO pays at this size. "
              "Iteration count alone does NOT price this.)\n");
  FILE* fp = std::fopen(path.c_str(), "w");
  if (!fp) return;
  std::fprintf(fp,
               "config,lambda_cut,core_cells,block_m,weighting,Nt,cg_total,"
               "cg_mean,basis_mb,build_s,refresh_s,apply_s,wall_s,"
               "coarse_matvecs,builds,design_iters,steady_s_per_iter,ok\n");
  std::fprintf(fp, "plain_jacobi,,,,,0,%lld,%.1f,0,0,0,0,%.2f,0,0,%d,%.4f,1\n",
               baseline.cg_total, oc_mean_cg(baseline), baseline.wall, n,
               base_iter);
  for (const SweepRow& r : rows)
    std::fprintf(fp, "%s,%.6g,%d,%d,%d,%d,%lld,%.1f,%.2f,%.2f,%.2f,%.2f,%.2f,"
                     "%lld,%lld,%d,%.4f,%d\n",
                 r.label.c_str(), r.lambda_cut, r.core, r.block_m, r.weighting,
                 r.Nt, r.cg_total, r.cg_mean, r.basis_mb, r.build_s, r.refresh_s,
                 r.apply_s, r.wall, r.coarse_matvecs, r.builds, r.iters,
                 r.iters > 0 ? (r.wall - r.build_s) / r.iters : 0.0,
                 r.ok ? 1 : 0);
  std::fclose(fp);
  std::printf("  wrote %s\n", path.c_str());
}

int sweep_iters() {
  int iters = 10;
  if (const char* e = std::getenv("TOPOPT_GSP_SWEEP_ITERS"))
    iters = std::atoi(e);
  return iters;
}

// ===========================================================================
// W1c — THE INTERLEAVED BENCHMARK (the trustworthy wall-clock number).
//
// WHY THIS EXISTS. Wall time measured by running posture A to completion and
// THEN posture B is only valid on a quiet machine; this one was not (two
// unrelated xctest processes at ~100% CPU during the first battery, load
// average 15-38), and the same plain-Jacobi baseline came out at 1.14 s/solve
// in one run and 3.20 s/solve in another. Iteration counts, N_t and matvec
// counts are deterministic and unaffected; wall is not.
//
// So the wall comparison is made by ALTERNATING the two postures solve-by-solve
// on the SAME system within one process and reporting MEDIANS. Any load that is
// roughly stationary over a pair hits both postures equally and cancels.
//
// The moduli are perturbed between reps so every GenEO solve pays the coarse-
// operator REFRESH — i.e. each rep is a faithful steady-state design iteration,
// not a free re-solve of an unchanged system.
// ===========================================================================
double median(std::vector<double> v) {
  if (v.empty()) return 0.0;
  std::sort(v.begin(), v.end());
  const std::size_t n = v.size();
  return n % 2 ? v[n / 2] : 0.5 * (v[n / 2 - 1] + v[n / 2]);
}

int mode_bench(const SettingsRules& rules, const Material& material,
               const std::string& dir) {
  (void)rules;
  (void)material;
  const OcCase C = oc_case();
  int reps = 7;
  if (const char* e = std::getenv("TOPOPT_GSP_REPS")) reps = std::atoi(e);
  int dev = 8;
  if (const char* e = std::getenv("TOPOPT_GSP_DEV")) dev = std::atoi(e);
  GeneoProbeConfig cfg = standing_cfg();
  if (const char* e = std::getenv("TOPOPT_GSP_CORE"))
    cfg.core_cells = std::atoi(e);
  if (const char* e = std::getenv("TOPOPT_GSP_CUT"))
    cfg.lambda_cut = std::atof(e);

  std::printf("\n===== W1c — INTERLEAVED A/B BENCHMARK — %s =====\n",
              C.label.c_str());
  std::printf("  core=%d^3 cut=%.3f, %d reps, developed %d OC iterations\n",
              cfg.core_cells, cfg.lambda_cut, reps, dev);

  // Develop a real design first (GenEO off, so the FIELD is the reference one).
  const OcRun d0 = oc_run("develop", C, dev, GeneoProbeConfig{}, false, 0, false,
                          /*trace=*/false);
  const DensityFilter filt =
      make_density_filter(C.grid, physical_filter_radius(2.5, C.grid.spacing));
  const std::vector<double> xp = filt.filter_density(d0.x_final);
  SimpParams p;
  p.youngs_modulus = kE0;
  p.poisson = kNu;
  p.penalty = 3.0;
  p.density_min = kRhoMin;
  std::vector<double> emod0(C.grid.voxel_count(), 0.0);
  for (std::size_t i = 0; i < emod0.size(); ++i)
    emod0[i] = simp_youngs(p, xp[i]);

  pin_to_jacobi_fallback();
  fea_set_krylov_recycling(false);
  fea_reset_krylov_recycle_space();
  fea_reset_geneo_basis();
  fea_detail::geneo_set_probe_config(cfg);

  std::vector<double> tp, tg;
  std::vector<int> kp, kg;
  long long mv_before_steady = 0;
  double build_s = 0.0;
  int Nt = 0;
  double basis_mb = 0.0;
  std::printf("\n  %-5s %-11s %-11s %-9s %-9s %-9s\n", "rep", "plain s",
              "geneo s", "k_plain", "k_geneo", "geneo act");
  for (int r = 0; r < reps; ++r) {
    // Perturb the design slightly: a real design iteration moves every modulus,
    // which is what forces the mandatory coarse-operator refresh.
    std::vector<double> emod(emod0.size());
    const double s = 1.0 + 0.01 * (r + 1);
    for (std::size_t i = 0; i < emod0.size(); ++i) emod[i] = emod0[i] * s;

    CgInfo ip, ig;
    fea_set_geneo_twolevel(false);  // basis is NOT reset — it survives for B
    const double t0 = now_s();
    fea_solve_mgcg_matfree(C.grid, emod, kNu, C.bcs, C.loads, kCertTol, 0, &ip);
    const double t1 = now_s();
    fea_set_geneo_twolevel(true);
    const double b0 = fea_detail::geneo_probe_build_seconds();
    fea_solve_mgcg_matfree(C.grid, emod, kNu, C.bcs, C.loads, kCertTol, 0, &ig);
    const double t2 = now_s();
    const double this_build = fea_detail::geneo_probe_build_seconds() - b0;
    build_s += this_build;
    Nt = fea_geneo_basis_dim();
    basis_mb = static_cast<double>(fea_geneo_basis_bytes()) / 1048576.0;
    std::printf("  %-5d %-11.3f %-11.3f %-9d %-9d %d%s\n", r + 1, t1 - t0,
                t2 - t1, ip.iterations, ig.iterations, ig.geneo_action,
                ig.geneo_action == 3 ? "  (BUILD — excluded from medians)" : "");
    if (ig.geneo_action == 3) {
      // The build rep is not steady state; exclude it from the medians and note
      // its one-off cost separately.
      mv_before_steady = fea_detail::geneo_probe_coarse_matvecs();
      continue;
    }
    tp.push_back(t1 - t0);
    tg.push_back(t2 - t1);
    kp.push_back(ip.iterations);
    kg.push_back(ig.iterations);
  }
  fea_set_geneo_twolevel(false);
  const long long mv_total = fea_detail::geneo_probe_coarse_matvecs();
  const double refresh_s = fea_detail::geneo_probe_refresh_seconds();
  const double apply_s = fea_detail::geneo_probe_apply_seconds();
  fea_reset_geneo_basis();
  fea_detail::geneo_set_probe_config(GeneoProbeConfig{});
  fea_set_mg_parity_pad_mode(1);

  const double mp = median(tp), mg = median(tg);
  double kpm = 0, kgm = 0;
  for (int v : kp) kpm += v;
  for (int v : kg) kgm += v;
  if (!kp.empty()) kpm /= kp.size();
  if (!kg.empty()) kgm /= kg.size();

  std::printf("\n===== W1c RESULT (medians over %zu steady-state reps) =====\n",
              tp.size());
  std::printf("  plain Jacobi-CG : %.3f s   %.0f iterations\n", mp, kpm);
  std::printf("  standing GenEO  : %.3f s   %.0f iterations   N_t=%d, "
              "basis %.1f MB\n",
              mg, kgm, Nt, basis_mb);
  std::printf("  ITERATIONS: %.3fx   WALL: %.3fx   => standing GenEO %s\n",
              kpm > 0 ? kgm / kpm : 0.0, mp > 0 ? mg / mp : 0.0,
              mg < mp ? "PAYS" : "DOES NOT PAY");
  std::printf("\n  deterministic accounting (matvec-equivalents per design "
              "iteration — load-independent):\n");
  std::printf("    plain          : %.0f matvecs (one per CG iteration)\n", kpm);
  const double refresh_mv =
      tp.empty() ? 0.0
                 : double(mv_total - mv_before_steady) / double(tp.size());
  std::printf("    standing       : %.0f refresh matvecs + %.0f CG matvecs = "
              "%.0f, plus %.0f deflation applies\n",
              refresh_mv, kgm, refresh_mv + kgm, kgm);
  std::printf("    one-off build  : %.1f s total (amortised over the run)\n",
              build_s);
  std::printf("    refresh wall %.2f s / apply wall %.2f s across all reps\n",
              refresh_s, apply_s);

  FILE* fp = std::fopen((dir + "/w1c_interleaved_bench.csv").c_str(), "w");
  if (fp) {
    std::fprintf(fp, "core_cells,lambda_cut,Nt,basis_mb,reps,"
                     "plain_median_s,geneo_median_s,wall_ratio,"
                     "plain_iters,geneo_iters,iter_ratio,refresh_matvecs_per_it,"
                     "build_s,refresh_s,apply_s\n");
    std::fprintf(fp, "%d,%.4g,%d,%.2f,%zu,%.4f,%.4f,%.4f,%.1f,%.1f,%.4f,%.1f,"
                     "%.2f,%.2f,%.2f\n",
                 cfg.core_cells, cfg.lambda_cut, Nt, basis_mb, tp.size(), mp, mg,
                 mp > 0 ? mg / mp : 0.0, kpm, kgm, kpm > 0 ? kgm / kpm : 0.0,
                 refresh_mv, build_s, refresh_s, apply_s);
    std::fclose(fp);
    std::printf("  wrote %s/w1c_interleaved_bench.csv\n", dir.c_str());
  }
  return 0;
}

// ===========================================================================
// W3 — EIGENVALUE CUT / BASIS DIMENSION.
// ===========================================================================
int mode_w3(const SettingsRules& rules, const Material& material,
            const std::string& dir) {
  (void)rules;
  (void)material;
  const OcCase C = oc_case();
  const int iters = sweep_iters();
  std::printf("\n===== W3 — EIGENVALUE CUT / BASIS DIMENSION SWEEP — %s =====\n",
              C.label.c_str());
  const OcRun base =
      oc_run("plain Jacobi", C, iters, GeneoProbeConfig{}, false, 0, false);
  print_oc(base);
  std::vector<SweepRow> rows;
  for (double cut : {0.002, 0.005, 0.01, 0.02, 0.05, 0.10}) {
    GeneoProbeConfig cfg = standing_cfg();
    cfg.lambda_cut = cut;
    char lbl[32];
    std::snprintf(lbl, sizeof lbl, "cut=%.3f", cut);
    rows.push_back(sweep_config(C, iters, lbl, cfg));
  }
  report_sweep("W3 TABLE — total wall vs basis dimension", rows, base,
               dir + "/w3_lambda_cut_sweep.csv");
  return 0;
}

// ===========================================================================
// W4 — AGGLOMERATE TILING.
// ===========================================================================
int mode_w4(const SettingsRules& rules, const Material& material,
            const std::string& dir) {
  (void)rules;
  (void)material;
  const OcCase C = oc_case();
  const int iters = sweep_iters();
  std::printf("\n===== W4 — AGGLOMERATE TILING SWEEP — %s =====\n",
              C.label.c_str());
  const OcRun base =
      oc_run("plain Jacobi", C, iters, GeneoProbeConfig{}, false, 0, false);
  print_oc(base);
  std::vector<SweepRow> rows;
  for (int core : {4, 8, 16}) {
    GeneoProbeConfig cfg = standing_cfg();
    cfg.core_cells = core;
    char lbl[32];
    std::snprintf(lbl, sizeof lbl, "core=%d^3", core);
    rows.push_back(sweep_config(C, iters, lbl, cfg));
  }
  report_sweep("W4 TABLE — tiling", rows, base, dir + "/w4_tiling_sweep.csv");
  return 0;
}

// ===========================================================================
// W5a — EIGENPROBLEM WEIGHTING.
// ===========================================================================
int mode_w5a(const SettingsRules& rules, const Material& material,
             const std::string& dir) {
  (void)rules;
  (void)material;
  const OcCase C = oc_case();
  const int iters = sweep_iters();
  std::printf("\n===== W5a — EIGENPROBLEM WEIGHTING — %s =====\n",
              C.label.c_str());
  const OcRun base =
      oc_run("plain Jacobi", C, iters, GeneoProbeConfig{}, false, 0, false);
  print_oc(base);
  std::vector<SweepRow> rows;
  for (int w : {0, 1}) {
    GeneoProbeConfig cfg = standing_cfg();
    cfg.eig_weighting = w;
    rows.push_back(sweep_config(
        C, iters, w == 0 ? "B=D A^Neu D" : "B=diag(K_agg)", cfg));
  }
  report_sweep("W5a TABLE — weighting", rows, base, dir + "/w5a_weighting.csv");
  return 0;
}

// ===========================================================================
// W5b — CONTINUATION-FORCED REBUILDS. The harness's continuation parameter is
// the SIMP penalty p (1 -> 2 -> 3), the classic schedule; every p step moves
// every modulus discontinuously, which is exactly the point DTU forced a
// rebuild at.
// ===========================================================================
int mode_w5b(const SettingsRules& rules, const Material& material,
             const std::string& dir) {
  (void)rules;
  (void)material;
  const OcCase C = oc_case();
  int iters = 18;
  if (const char* e = std::getenv("TOPOPT_GSP_ITERS")) iters = std::atoi(e);
  const int p_steps = std::max(1, iters / 3);
  std::printf("\n===== W5b — CONTINUATION-FORCED REBUILDS — %s =====\n",
              C.label.c_str());
  std::printf("  p-continuation: p=1 for iters 1-%d, p=2 for %d-%d, p=3 after\n",
              p_steps, p_steps + 1, 2 * p_steps);

  std::printf("\n  -- shipped rebuild policy (rebuild_factor=%.1f) --\n",
              fea_detail::kGeneoRebuildFactor);
  const OcRun policy = oc_run("shipped policy", C, iters, standing_cfg(), true,
                              p_steps, false);
  print_oc(policy);
  std::printf("\n  -- + forced rebuild at every p step --\n");
  const OcRun forced = oc_run("+ forced on p step", C, iters, standing_cfg(),
                              true, p_steps, true);
  print_oc(forced);
  write_oc_csv(dir + "/w5b_policy_iters.csv", policy);
  write_oc_csv(dir + "/w5b_forced_iters.csv", forced);

  std::vector<int> p_moves, rebuilds;
  double last = -1.0;
  for (const OcIter& x : policy.its) {
    if (last >= 0.0 && x.penalty != last) p_moves.push_back(x.iter);
    last = x.penalty;
    if (x.geneo_action == 3) rebuilds.push_back(x.iter);
  }
  std::printf("\n  continuation steps at iterations:");
  for (int i : p_moves) std::printf(" %d", i);
  if (p_moves.empty()) std::printf(" (none)");
  std::printf("\n  shipped policy REBUILT at iterations:");
  for (int i : rebuilds) std::printf(" %d", i);
  if (rebuilds.empty()) std::printf(" (never)");
  std::printf("\n");
  int caught = 0;
  for (int b : p_moves)
    for (int r : rebuilds)
      if (r >= b && r <= b + 2) { ++caught; break; }
  std::printf("  continuation points the SHIPPED policy caught (a rebuild "
              "within 2 iterations): %d/%zu\n",
              caught, p_moves.size());
  std::printf("\n  forcing them costs/saves: CG %lld -> %lld (%+lld), builds "
              "%lld -> %lld, WALL %.1f -> %.1f s (%+.1f s)\n",
              policy.cg_total, forced.cg_total,
              forced.cg_total - policy.cg_total, policy.builds, forced.builds,
              policy.wall, forced.wall, forced.wall - policy.wall);
  return 0;
}

// ===========================================================================
// W6 — CORRECTNESS: same converged u to solver tolerance, deterministic.
// ===========================================================================
struct DirectSolve {
  int iters = 0;
  bool converged = false;
  double residual = 0.0;
  int Nt = 0, action = 0;
  double wall = 0.0;
  std::vector<double> u;
};

DirectSolve direct_solve(const OcCase& C, const std::vector<double>& emod,
                         const GeneoProbeConfig& cfg, bool geneo) {
  pin_to_jacobi_fallback();
  fea_set_krylov_recycling(false);
  fea_reset_krylov_recycle_space();
  fea_set_geneo_twolevel(geneo);
  fea_reset_geneo_basis();
  fea_detail::geneo_set_probe_config(cfg);
  CgInfo info;
  DirectSolve d;
  const double t0 = now_s();
  const FeaSolution s = fea_solve_mgcg_matfree(C.grid, emod, kNu, C.bcs, C.loads,
                                               kCertTol, 0, &info);
  d.wall = now_s() - t0;
  d.iters = info.iterations;
  d.converged = info.converged;
  d.residual = info.residual;
  d.Nt = info.geneo_dim;
  d.action = info.geneo_action;
  d.u = s.u;
  fea_set_geneo_twolevel(false);
  fea_reset_geneo_basis();
  fea_detail::geneo_set_probe_config(GeneoProbeConfig{});
  fea_set_mg_parity_pad_mode(1);
  return d;
}

int mode_w6(const SettingsRules& rules, const Material& material,
            const std::string& dir) {
  (void)rules;
  (void)material;
  const OcCase C = oc_case();
  std::printf("\n===== W6 — CORRECTNESS AND DETERMINISM — %s =====\n",
              C.label.c_str());
  // Develop a real design first, then solve THAT system three ways.
  const int dev = 8;
  const OcRun d0 = oc_run("develop (GenEO off)", C, dev, GeneoProbeConfig{},
                          false, 0, false, /*trace=*/false);
  const DensityFilter filt =
      make_density_filter(C.grid, physical_filter_radius(2.5, C.grid.spacing));
  const std::vector<double> xp = filt.filter_density(d0.x_final);
  SimpParams p;
  p.youngs_modulus = kE0;
  p.poisson = kNu;
  p.penalty = 3.0;
  p.density_min = kRhoMin;
  std::vector<double> emod(C.grid.voxel_count(), 0.0);
  double emin = 1e300, emax = 0.0;
  for (std::size_t i = 0; i < emod.size(); ++i) {
    emod[i] = simp_youngs(p, xp[i]);
    if (C.grid.tags[i] != VoxelTag::Empty) {
      emin = std::min(emin, emod[i]);
      emax = std::max(emax, emod[i]);
    }
  }
  std::printf("  developed system after %d OC iterations; modulus contrast "
              "E_max/E_min = %.3g\n",
              dev, emin > 0 ? emax / emin : 0.0);

  const DirectSolve plain = direct_solve(C, emod, GeneoProbeConfig{}, false);
  const DirectSolve g1 = direct_solve(C, emod, standing_cfg(), true);
  const DirectSolve g2 = direct_solve(C, emod, standing_cfg(), true);
  std::printf("  plain Jacobi-CG : %d iters, converged=%d, rel.res=%.3e, "
              "%.2f s\n",
              plain.iters, plain.converged ? 1 : 0, plain.residual, plain.wall);
  std::printf("  standing GenEO  : %d iters, converged=%d, rel.res=%.3e, "
              "%.2f s, N_t=%d (action %d)\n",
              g1.iters, g1.converged ? 1 : 0, g1.residual, g1.wall, g1.Nt,
              g1.action);

  const double du = rel_u_diff(plain.u, g1.u);
  const bool exact = du <= 1e-5;
  std::printf("  max|u_geneo - u_plain| / max|u_plain| = %.3e   (bar 1e-5 at "
              "cg_tolerance=%.0e)   %s\n",
              du, kCertTol, exact ? "PASS" : "FAIL");
  bool det = g1.u.size() == g2.u.size() && g1.iters == g2.iters &&
             g1.Nt == g2.Nt;
  if (det)
    for (std::size_t i = 0; i < g1.u.size(); ++i)
      if (g1.u[i] != g2.u[i]) { det = false; break; }
  std::printf("  rerun bit-identical (u, iterations, N_t): %s\n",
              det ? "YES" : "NO");

  FILE* fp = std::fopen((dir + "/w6_correctness.csv").c_str(), "w");
  if (fp) {
    std::fprintf(fp, "check,value,bar,pass\n");
    std::fprintf(fp, "rel_u_diff,%.6e,1e-5,%d\n", du, exact ? 1 : 0);
    std::fprintf(fp, "deterministic,%d,1,%d\n", det ? 1 : 0, det ? 1 : 0);
    std::fprintf(fp, "plain_iters,%d,,\n", plain.iters);
    std::fprintf(fp, "geneo_iters,%d,,\n", g1.iters);
    std::fprintf(fp, "geneo_Nt,%d,,\n", g1.Nt);
    std::fprintf(fp, "plain_wall_s,%.4f,,\n", plain.wall);
    std::fprintf(fp, "geneo_wall_s,%.4f,,\n", g1.wall);
    std::fclose(fp);
    std::printf("  wrote %s/w6_correctness.csv\n", dir.c_str());
  }
  std::printf("\n===== W6 VERDICT: %s =====\n",
              (exact && det)
                  ? "coarse correction SPD and exact; deterministic"
                  : "CORRECTNESS REGRESSION — BLOCKED-STOP");
  return (exact && det) ? 0 : 1;
}

// ===========================================================================
// W7 — THE HONEST COMPARISON: what HEALTHY multigrid costs on the SAME work.
// Same fixture, same trajectory, multigrid ALLOWED (parity pad on, so the grid
// coarsens) — so the maintainer can see whether standing GenEO is competitive
// with working multigrid, or only with its absence.
// ===========================================================================
int mode_w7(const SettingsRules& rules, const Material& material,
            const std::string& dir) {
  (void)rules;
  (void)material;
  const OcCase C = oc_case();
  int iters = 12;
  if (const char* e = std::getenv("TOPOPT_GSP_ITERS")) iters = std::atoi(e);
  std::printf("\n===== W7 — HEALTHY MULTIGRID, FOR SCALE — %s =====\n",
              C.label.c_str());

  // Multigrid ALLOWED: parity pad AUTO (the production default) so the odd axis
  // is padded and a hierarchy is built. Everything else identical.
  fea_set_krylov_recycling(false);
  fea_reset_krylov_recycle_space();
  fea_set_geneo_twolevel(false);
  fea_reset_geneo_basis();
  fea_set_mg_parity_pad_mode(1);
  fea_matfree_reset_mg_stagnation_latch();

  const DensityFilter filt =
      make_density_filter(C.grid, physical_filter_radius(2.5, C.grid.spacing));
  std::vector<double> x = simp_uniform_density(C.grid, C.vf);
  long long cg = 0;
  int mg_solves = 0;
  double solve_s = 0.0;
  std::vector<OcIter> its;
  const double t0 = now_s();
  for (int it = 0; it < iters; ++it) {
    SimpParams params;
    params.youngs_modulus = kE0;
    params.poisson = kNu;
    params.penalty = 3.0;
    params.density_min = kRhoMin;
    const std::vector<double> xp = filt.filter_density(x);
    const double ts = now_s();
    SimpCompliance c;
    try {
      c = simp_compliance(C.grid, params, xp, C.bcs, C.loads, kCertTol, 0,
                          nullptr, nullptr, SolverKind::MultigridCG_Matfree);
    } catch (const std::exception& e) {
      std::printf("      it %-3d SOLVE FAILED: %s\n", it + 1, e.what());
      break;
    }
    const double s = now_s() - ts;
    solve_s += s;
    cg += c.cg.iterations;
    if (c.cg.used_multigrid) ++mg_solves;
    OcIter rec;
    rec.iter = it + 1;
    rec.cg = c.cg.iterations;
    rec.used_mg = c.cg.used_multigrid ? 1 : 0;
    rec.solve_s = s;
    rec.compliance = c.compliance;
    rec.penalty = 3.0;
    its.push_back(rec);
    std::printf("      it %-3d cg=%-6d mg=%d levels=%-2d cycles=%-4d %6.2f s\n",
                rec.iter, rec.cg, rec.used_mg, c.cg.mg_levels,
                c.cg.mg_cycles_attempted, s);
    x = oc_update(C.grid, filt, x, c.dcompliance, C.vf, 0.2, kRhoMin);
  }
  const double wall = now_s() - t0;
  std::printf("\n  multigrid carried on %d/%zu solves; CG total %lld "
              "(mean %.0f); solve wall %.1f s; total wall %.1f s\n",
              mg_solves, its.size(), cg,
              its.empty() ? 0.0 : double(cg) / double(its.size()), solve_s,
              wall);
  OcRun R;
  R.label = "healthy multigrid";
  R.its = its;
  R.cg_total = cg;
  R.wall = wall;
  R.solve_s = solve_s;
  write_oc_csv(dir + "/w7_healthy_mg_iters.csv", R);
  return 0;
}

}  // namespace
