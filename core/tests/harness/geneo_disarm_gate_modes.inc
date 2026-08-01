// geneo_disarm_gate_modes.inc — the measurement modes. Included by
// geneo_disarm_gate.cpp (one TU; the split is for readability, the way
// geneo_standing_probe / geneo_twolevel_probe do it).

// ===========================================================================
// regime — the TWO operating points this task must separate.
//
// The whole rule stands or falls on telling these apart, so they are pinned and
// reported before anything is graded:
//   LATCHED       the maintainer's rung-3 state: multigrid absent, plain
//                 Jacobi-CG in the high hundreds per solve.
//   CATASTROPHIC  PR 248's stagnation band, 1,685-41,063 plain CG in a SINGLE
//                 solve — the regime GenEO was armed for and must keep.
// ===========================================================================
int mode_regime(const std::string& dir) {
  std::printf("\n===== REGIME — the two operating points, measured plain =====\n");
  FILE* fp = std::fopen((dir + "/regime.csv").c_str(), "w");
  if (fp) std::fprintf(fp, "n,dil,vf,voxels,N_t,iters,cg_min,cg_max,cg_mean\n");
  struct Pt { int n; double dil, vf; int iters; };
  // The GRID is held nearly fixed and only the DILUTION OF THE DESIGN is varied.
  // That is deliberate: N_t (the refresh price) scales with the grid VOLUME while
  // the plain iteration count scales with conditioning, so moving vf isolates the
  // conditioning axis and lets one small grid cover BOTH regimes with the same
  // N_t. Growing the grid instead would raise N_t alongside the difficulty and
  // measure nothing about the gate.
  const std::vector<Pt> pts = {
      {32, 0.25, 0.50, 4},
      {32, 0.25, 0.20, 4},
      {32, 0.25, 0.08, 4},
      {32, 0.25, 0.03, 4},
  };
  struct SPt { int arm; double dil, vf; int iters; };
  const std::vector<SPt> spts = {
      {24, 0.50, 0.05, 3},
      {24, 0.50, 0.02, 3},
      {32, 0.50, 0.02, 3},
  };
  for (const Pt& p : pts) {
    const Case C = make_case(p.n, p.dil, p.vf);
    const Run R = trajectory("plain", C, p.iters, Posture::Plain, false, false);
    int mn = 1 << 30, mx = 0;
    for (const Rec& r : R.its) { mn = std::min(mn, r.cg); mx = std::max(mx, r.cg); }
    const double mean = R.its.empty() ? 0 : double(R.cg_total) / R.its.size();
    // N_t for this grid: one throwaway ARMED solve builds the basis and reports it.
    const Run one = trajectory("nt", C, 1, Posture::Armed, false, false);
    const int nt = one.its.empty() ? 0 : one.its[0].dim;
    std::printf("  n=%-3d dil=%.2f vf=%.2f  %-7zu voxels  N_t=%-6d : plain CG "
                "min=%-6d max=%-6d mean=%-7.0f   threshold ~= %d\n",
                p.n, p.dil, p.vf, C.grid.voxel_count(), nt, mn, mx, mean,
                static_cast<int>(2 * nt + 500 + 2 * 200));
    if (fp)
      std::fprintf(fp, "%d,%.2f,%.2f,%zu,%d,%d,%d,%d,%.1f\n", p.n, p.dil, p.vf,
                   C.grid.voxel_count(), nt, p.iters, mn, mx, mean);
  }
  std::printf("\n  -- the STAGNATION class: a SOLID part pinned inside a "
              "near-void box --\n");
  for (const SPt& p : spts) {
    const Case C = make_stagnation_case(p.arm, p.dil, p.vf);
    const Run R = trajectory("plain", C, p.iters, Posture::Plain, false, false);
    int mn = 1 << 30, mx = 0;
    for (const Rec& r : R.its) { mn = std::min(mn, r.cg); mx = std::max(mx, r.cg); }
    const double mean = R.its.empty() ? 0 : double(R.cg_total) / R.its.size();
    const Run one = trajectory("nt", C, 1, Posture::Armed, false, false);
    const int nt = one.its.empty() ? 0 : one.its[0].dim;
    std::printf("  arm=%-3d dil=%.2f vf=%.2f  %-7zu voxels  N_t=%-6d : plain CG "
                "min=%-6d max=%-6d mean=%-7.0f   threshold ~= %d\n",
                p.arm, p.dil, p.vf, C.grid.voxel_count(), nt, mn, mx, mean,
                static_cast<int>(2 * nt + 500 + 2 * 200));
    if (fp)
      std::fprintf(fp, "%d,%.2f,%.2f,%zu,%d,%d,%d,%d,%.1f\n", p.arm, p.dil,
                   p.vf, C.grid.voxel_count(), nt, p.iters, mn, mx, mean);
  }
  if (fp) std::fclose(fp);
  std::printf("\n  A row whose plain CG mean is WELL ABOVE its threshold is the\n"
              "  CATASTROPHIC regime (the gate must still engage); one well below\n"
              "  is the LATCHED regime (the gate must decline).\n");
  return 0;
}

// ===========================================================================
// AA1 — THE 41,063 CASE STILL WINS.
//
// A genuinely catastrophic solve, three postures, WALL and iterations. Reported
// as an INTERLEAVED comparison of ARMED vs GATED (same binary, alternating, so
// machine load cancels) plus the plain baseline. If the gate kills the rescue,
// the rule is wrong and this mode says so.
// ===========================================================================
int mode_aa1(const std::string& dir) {
  const int n = env_i("TOPOPT_GDG_ARM", 24);
  const double dil = env_d("TOPOPT_GDG_DIL", 0.5);
  const double vf = env_d("TOPOPT_GDG_VF", 0.02);
  const int iters = env_i("TOPOPT_GDG_ITERS", 5);
  const Case C = make_stagnation_case(n, dil, vf);
  std::printf("\n===== AA1 — THE RESCUE CASE — %s =====\n", C.label.c_str());

  const Run plain = trajectory("plain", C, iters, Posture::Plain, false, true);
  std::printf("  [%-46s] CG=%-8lld mean=%-7.0f wall=%7.1f s\n",
              posture_name(Posture::Plain), plain.cg_total,
              double(plain.cg_total) / plain.its.size(), plain.wall);
  const Run armed = trajectory("armed", C, iters, Posture::Armed, false, true);
  std::printf("  [%-46s] CG=%-8lld mean=%-7.0f wall=%7.1f s  builds=%lld "
              "refresh=%lld armed=%lld declined=%lld\n",
              posture_name(Posture::Armed), armed.cg_total,
              double(armed.cg_total) / armed.its.size(), armed.wall,
              armed.builds, armed.refreshes, armed.armed, armed.declined);
  const Run gated = trajectory("gated", C, iters, Posture::Gated, false, true);
  std::printf("  [%-46s] CG=%-8lld mean=%-7.0f wall=%7.1f s  builds=%lld "
              "refresh=%lld armed=%lld declined=%lld\n",
              posture_name(Posture::Gated), gated.cg_total,
              double(gated.cg_total) / gated.its.size(), gated.wall,
              gated.builds, gated.refreshes, gated.armed, gated.declined);

  write_csv(dir + "/aa1_plain.csv", plain);
  write_csv(dir + "/aa1_armed.csv", armed);
  write_csv(dir + "/aa1_gated.csv", gated);

  std::vector<double> ps, as, gs;
  for (const Rec& r : plain.its) ps.push_back(r.solve_s);
  for (const Rec& r : armed.its) as.push_back(r.solve_s);
  for (const Rec& r : gated.its) gs.push_back(r.solve_s);
  const double mp = median(ps), ma = median(as), mg = median(gs);
  std::printf("\n  median s/solve : plain %.3f | armed %.3f (%.2fx) | "
              "gated %.3f (%.2fx)\n",
              mp, ma, mp > 0 ? ma / mp : 0.0, mg, mp > 0 ? mg / mp : 0.0);

  long long engaged = 0, armed_engaged = 0;
  for (const Rec& r : gated.its)
    if (r.action == 1 || r.action == 2 || r.action == 3) ++engaged;
  for (const Rec& r : armed.its)
    if (r.action == 1 || r.action == 2 || r.action == 3) ++armed_engaged;
  std::printf("\n  engaged rows: ARMED %lld/%zu, GATED %lld/%zu\n",
              armed_engaged, armed.its.size(), engaged, gated.its.size());
  // A fixture on which the PRE-CHANGE posture never engaged either is not a
  // rescue case at all — it never reached kGeneoTriggerIters, so there is
  // nothing for a gate to kill. Saying so is the honest verdict; calling it a
  // failure of the rule would be reading a null result as a negative one.
  if (armed_engaged == 0) {
    std::printf("\n===== AA1 INCONCLUSIVE — this fixture never reaches the "
                "%d-iteration trigger in ANY posture (max plain CG %d), so "
                "GenEO never armed before the change either. Not a rescue "
                "case. Use `aa1prod`. =====\n",
                fea_geneo_trigger_iters(),
                [&] { int mx = 0; for (const Rec& r : plain.its) mx = std::max(mx, r.cg); return mx; }());
    return 2;
  }
  const bool still_arms = engaged > 0;
  const bool still_wins = mg < mp;
  std::printf("  still arms: %s; beats plain in WALL: %s (%.3f vs %.3f s)\n",
              still_arms ? "YES" : "NO", still_wins ? "YES" : "NO", mg, mp);
  std::printf("\n===== AA1 %s =====\n",
              (still_arms && still_wins)
                  ? "PASS — the rescue survives the gate"
                  : "FAIL — the gate killed the rescue case; the rule is wrong");
  return (still_arms && still_wins) ? 0 : 1;
}

// ===========================================================================
// AA2 — THE 215-ITERATION TAX IS GONE.
//
// The latched reproduction. ARMED (pre-change) vs GATED (post-change), same
// binary. Reports wall PER DESIGN ITERATION before and after, and what fraction
// of that iteration is still accelerator overhead — the number PR 273 measured
// at 87.9 %.
// ===========================================================================
int mode_aa2(const std::string& dir) {
  const int n = env_i("TOPOPT_GDG_N", 32);
  const double dil = env_d("TOPOPT_GDG_DIL", 0.25);
  const double vf = env_d("TOPOPT_GDG_VF", 0.50);
  const int iters = env_i("TOPOPT_GDG_ITERS", 10);
  const bool recyc = env_i("TOPOPT_GDG_RECYCLE", 1) != 0;
  const Case C = make_case(n, dil, vf);
  std::printf("\n===== AA2 — THE LATCHED TAX — %s (recycling %s) =====\n",
              C.label.c_str(), recyc ? "ON" : "off");

  std::printf("\n  -- ARMED (pre-change) --\n");
  const Run armed = trajectory("armed", C, iters, Posture::Armed, recyc, true);
  std::printf("\n  -- GATED (post-change) --\n");
  const Run gated = trajectory("gated", C, iters, Posture::Gated, recyc, true);
  write_csv(dir + "/aa2_armed.csv", armed);
  write_csv(dir + "/aa2_gated.csv", gated);

  // STEADY STATE = every iteration after the first basis build, which is a
  // one-off per structure and is reported separately rather than smeared into
  // the per-iteration number it would distort.
  auto steady = [](const Run& R) {
    std::size_t first = 0;
    for (std::size_t i = 0; i < R.its.size(); ++i)
      if (R.its[i].action == 3) first = i + 1;
    return first;
  };
  const std::size_t s0 = std::max(steady(armed), steady(gated));

  struct Agg {
    double solve = 0, cg = 0, geneo_setup = 0, geneo_apply = 0, recycle = 0;
    double cgi = 0;
    int nrows = 0;
  };
  auto agg = [&](const Run& R) {
    Agg a;
    std::vector<double> sv;
    for (std::size_t i = s0; i < R.its.size(); ++i) {
      const Rec& r = R.its[i];
      sv.push_back(r.solve_s);
      a.cg += r.cg_ms;
      a.geneo_setup += r.geneo_setup_ms;
      a.geneo_apply += r.geneo_apply_ms;
      a.recycle += r.recycle_ms;
      a.cgi += r.cg;
      ++a.nrows;
    }
    a.solve = median(sv);
    if (a.nrows) {
      a.cg /= a.nrows; a.geneo_setup /= a.nrows;
      a.geneo_apply /= a.nrows; a.recycle /= a.nrows; a.cgi /= a.nrows;
    }
    return a;
  };
  const Agg A = agg(armed), G = agg(gated);

  auto report = [&](const char* name, const Agg& a) {
    const double tot = a.cg + a.geneo_setup + a.geneo_apply + a.recycle;
    std::printf("  %-8s median %7.3f s/solve  CG %6.0f iters | phases (ms): "
                "cg %7.1f (%4.1f%%)  geneo_setup %8.1f (%4.1f%%)  "
                "geneo_apply %7.1f (%4.1f%%)  recycle %6.1f (%4.1f%%)\n",
                name, a.solve, a.cgi, a.cg, tot > 0 ? 100 * a.cg / tot : 0,
                a.geneo_setup, tot > 0 ? 100 * a.geneo_setup / tot : 0,
                a.geneo_apply, tot > 0 ? 100 * a.geneo_apply / tot : 0,
                a.recycle, tot > 0 ? 100 * a.recycle / tot : 0);
  };
  std::printf("\n  STEADY STATE (iterations %zu..%zu — after the one-off basis "
              "build):\n", s0 + 1, armed.its.size());
  report("ARMED", A);
  report("GATED", G);

  const double atot = A.cg + A.geneo_setup + A.geneo_apply + A.recycle;
  const double gtot = G.cg + G.geneo_setup + G.geneo_apply + G.recycle;
  const double a_over = atot > 0 ? (A.geneo_setup + A.geneo_apply + A.recycle) / atot : 0;
  const double g_over = gtot > 0 ? (G.geneo_setup + G.geneo_apply + G.recycle) / gtot : 0;
  const double g_geneo = gtot > 0 ? (G.geneo_setup + G.geneo_apply) / gtot : 0;
  std::printf("\n  accelerator overhead as a share of the solve: "
              "ARMED %.1f%%  ->  GATED %.1f%%   (of which GenEO: %.1f%% -> %.1f%%)\n",
              100 * a_over, 100 * g_over,
              100 * (atot > 0 ? (A.geneo_setup + A.geneo_apply) / atot : 0),
              100 * g_geneo);
  std::printf("  wall per design iteration: %.3f s -> %.3f s  = %.2fx %s\n",
              A.solve, G.solve, A.solve > 0 ? A.solve / G.solve : 0.0,
              G.solve < A.solve ? "FASTER" : "SLOWER");
  std::printf("  gate decisions: armed=%lld declined=%lld refreshes=%lld "
              "(was armed=%lld declined=%lld refreshes=%lld)\n",
              gated.armed, gated.declined, gated.refreshes, armed.armed,
              armed.declined, armed.refreshes);
  return G.solve < A.solve ? 0 : 1;
}

// ===========================================================================
// bench — THE LOAD-ROBUST WALL COMPARISON.
//
// The machine of record is shared, and PR 275 already learned what that costs:
// the same plain baseline came out at 1.14 s/solve in one run and 3.20 s in
// another. Iteration counts, N_t, thresholds and gate decisions are
// DETERMINISTIC and unaffected; wall is not. So every wall claim in this handoff
// comes from HERE: the two postures are run as ALTERNATING whole trajectories in
// ABBA order inside one process, their per-solve walls pooled per posture, and
// MEDIANS reported. Stationary load hits both equally and cancels; the ABBA
// order cancels linear drift. The spread is reported too, so a reader can see
// how noisy the host was rather than take the median on faith.
// ===========================================================================
int mode_bench(const std::string& dir) {
  const int n = env_i("TOPOPT_GDG_N", 32);
  const double dil = env_d("TOPOPT_GDG_DIL", 0.25);
  const double vf = env_d("TOPOPT_GDG_VF", 0.50);
  const int iters = env_i("TOPOPT_GDG_ITERS", 8);
  const int reps = env_i("TOPOPT_GDG_REPS", 4);   // ABBA blocks
  const bool recyc = env_i("TOPOPT_GDG_RECYCLE", 1) != 0;
  const Case C = make_case(n, dil, vf);
  std::printf("\n===== BENCH — ALTERNATING ARMED/GATED — %s =====\n"
              "  %d ABBA blocks x %d design iterations, recycling %s\n",
              C.label.c_str(), reps, iters, recyc ? "ON" : "off");

  struct Pool {
    std::vector<double> solve_s, cg_ms, setup_ms, apply_ms, rec_ms, cg_iters;
    long long refreshes = 0, armedn = 0, declined = 0, builds = 0;
  };
  Pool PA, PG;
  auto absorb = [](Pool& P, const Run& R) {
    // Skip every iteration up to and including the one that BUILT the basis: a
    // one-off eigensolve per structure is not the steady-state cost this bar is
    // about, and it is reported separately rather than smeared into the median.
    std::size_t s0 = 0;
    for (std::size_t i = 0; i < R.its.size(); ++i)
      if (R.its[i].action == 3) s0 = i + 1;
    for (std::size_t i = s0; i < R.its.size(); ++i) {
      const Rec& r = R.its[i];
      P.solve_s.push_back(r.solve_s);
      P.cg_ms.push_back(r.cg_ms);
      P.setup_ms.push_back(r.geneo_setup_ms);
      P.apply_ms.push_back(r.geneo_apply_ms);
      P.rec_ms.push_back(r.recycle_ms);
      P.cg_iters.push_back(r.cg);
    }
    P.refreshes += R.refreshes;
    P.armedn += R.armed;
    P.declined += R.declined;
    P.builds += R.builds;
  };
  for (int b = 0; b < reps; ++b) {
    // ABBA: even blocks run armed-first, odd blocks gated-first.
    const bool armed_first = (b % 2) == 0;
    for (int k = 0; k < 2; ++k) {
      const bool do_armed = (k == 0) == armed_first;
      const Run R = trajectory(do_armed ? "armed" : "gated", C, iters,
                               do_armed ? Posture::Armed : Posture::Gated,
                               recyc, false);
      absorb(do_armed ? PA : PG, R);
      std::printf("  block %d: %-6s wall %7.2f s  CG %-8lld refresh=%lld "
                  "armed=%lld declined=%lld\n",
                  b + 1, do_armed ? "ARMED" : "GATED", R.wall, R.cg_total,
                  R.refreshes, R.armed, R.declined);
    }
  }

  auto spread = [](std::vector<double> v) {
    if (v.empty()) return std::string("-");
    std::sort(v.begin(), v.end());
    char buf[80];
    std::snprintf(buf, sizeof buf, "%.3f..%.3f", v.front(), v.back());
    return std::string(buf);
  };
  auto line = [&](const char* nm, const Pool& P) {
    std::printf("  %-6s median/solve %7.3f s (spread %s)  CG %6.0f  "
                "phases(ms) cg %7.1f  geneo_setup %8.1f  geneo_apply %7.1f  "
                "recycle %6.1f   refresh=%lld armed=%lld declined=%lld\n",
                nm, median(P.solve_s), spread(P.solve_s).c_str(),
                median(P.cg_iters), median(P.cg_ms), median(P.setup_ms),
                median(P.apply_ms), median(P.rec_ms), P.refreshes, P.armedn,
                P.declined);
  };
  std::printf("\n  STEADY STATE, pooled over %d blocks:\n", reps);
  line("ARMED", PA);
  line("GATED", PG);
  const double ma = median(PA.solve_s), mg = median(PG.solve_s);
  const double sa = median(PA.setup_ms) + median(PA.apply_ms) + median(PA.rec_ms);
  const double sg = median(PG.setup_ms) + median(PG.apply_ms) + median(PG.rec_ms);
  const double ta = sa + median(PA.cg_ms), tg = sg + median(PG.cg_ms);
  std::printf("\n  wall per design iteration : %.3f s (ARMED) -> %.3f s (GATED)"
              "  = %.2fx %s\n",
              ma, mg, mg > 0 ? ma / mg : 0.0, mg < ma ? "FASTER" : "SLOWER");
  std::printf("  accelerator overhead share: %.1f%% -> %.1f%%  "
              "(GenEO alone %.1f%% -> %.1f%%; recycle %.1f%% -> %.1f%%)\n",
              ta > 0 ? 100 * sa / ta : 0, tg > 0 ? 100 * sg / tg : 0,
              ta > 0 ? 100 * (median(PA.setup_ms) + median(PA.apply_ms)) / ta : 0,
              tg > 0 ? 100 * (median(PG.setup_ms) + median(PG.apply_ms)) / tg : 0,
              ta > 0 ? 100 * median(PA.rec_ms) / ta : 0,
              tg > 0 ? 100 * median(PG.rec_ms) / tg : 0);
  FILE* fp = std::fopen((dir + "/bench.csv").c_str(), "w");
  if (fp) {
    std::fprintf(fp, "posture,solve_s,cg_iters,cg_ms,geneo_setup_ms,"
                     "geneo_apply_ms,recycle_ms\n");
    auto dump = [&](const char* nm, const Pool& P) {
      for (std::size_t i = 0; i < P.solve_s.size(); ++i)
        std::fprintf(fp, "%s,%.5f,%.0f,%.3f,%.3f,%.3f,%.3f\n", nm, P.solve_s[i],
                     P.cg_iters[i], P.cg_ms[i], P.setup_ms[i], P.apply_ms[i],
                     P.rec_ms[i]);
    };
    dump("armed", PA);
    dump("gated", PG);
    std::fclose(fp);
    std::printf("  wrote %s/bench.csv\n", dir.c_str());
  }
  return mg < ma ? 0 : 1;
}

// ===========================================================================
// AA4 — EXACTNESS + DETERMINISM.
//
// Disarming mid-run must not change the converged answer beyond solver
// tolerance, and the decision must be reproducible. The gate compares COUNTS and
// never a clock, so bit-identity across reruns is owed and asserted.
// ===========================================================================
int mode_aa4(const std::string& dir) {
  (void)dir;
  const int n = env_i("TOPOPT_GDG_N", 32);
  const double dil = env_d("TOPOPT_GDG_DIL", 0.25);
  const double vf = env_d("TOPOPT_GDG_VF", 0.50);
  const int iters = env_i("TOPOPT_GDG_ITERS", 6);
  const Case C = make_case(n, dil, vf);
  std::printf("\n===== AA4 — EXACTNESS + DETERMINISM — %s =====\n",
              C.label.c_str());

  // One DEVELOPED design, solved three ways — the fields must agree.
  const Run seed = trajectory("seed", C, iters, Posture::Plain, false, false);
  const DensityFilter filt =
      make_density_filter(C.grid, physical_filter_radius(2.5, C.grid.spacing));
  const std::vector<double> xp = filt.filter_density(seed.x_final);

  auto solve_once = [&](Posture p, bool warm_basis) {
    pin_to_jacobi_fallback();
    fea_set_krylov_recycling(false);
    fea_reset_krylov_recycle_space();
    reset_posture();
    set_posture(p);
    fea_reset_geneo_basis();
    SimpParams params;
    params.youngs_modulus = kE0;
    params.poisson = kNu;
    params.penalty = 3.0;
    params.density_min = kRhoMin;
    // `warm_basis` runs one throwaway solve first so a basis EXISTS and the gate
    // has a real decision to take — a gate with nothing held is not being tested.
    if (warm_basis)
      simp_compliance(C.grid, params, xp, C.bcs, C.loads, kTol, 0, nullptr,
                      nullptr, SolverKind::MultigridCG_Matfree);
    const SimpCompliance c =
        simp_compliance(C.grid, params, xp, C.bcs, C.loads, kTol, 0, nullptr,
                        nullptr, SolverKind::MultigridCG_Matfree);
    struct Out { std::vector<double> u; int iters; int action; int threshold; };
    Out o{c.solution.u, c.cg.iterations, c.cg.geneo_action,
          c.cg.geneo_threshold};
    reset_posture();
    fea_set_mg_parity_pad_mode(1);
    return o;
  };

  const auto never = solve_once(Posture::Plain, true);
  const auto always = solve_once(Posture::Armed, true);
  const auto gated = solve_once(Posture::Gated, true);
  const auto gated2 = solve_once(Posture::Gated, true);

  std::printf("  never-armed : %d iters (action %d)\n", never.iters, never.action);
  std::printf("  always-armed: %d iters (action %d)\n", always.iters, always.action);
  std::printf("  GATED       : %d iters (action %d, threshold %d)\n",
              gated.iters, gated.action, gated.threshold);

  const double d_never = rel_u_diff(never.u, gated.u);
  const double d_always = rel_u_diff(always.u, gated.u);
  const bool bitid = (gated.u == gated2.u) && gated.iters == gated2.iters &&
                     gated.action == gated2.action &&
                     gated.threshold == gated2.threshold;
  std::printf("\n  max|du|/max|u| vs never-armed : %.3e   (bar 1e-5)\n", d_never);
  std::printf("  max|du|/max|u| vs always-armed: %.3e   (bar 1e-5)\n", d_always);
  std::printf("  rerun bit-identical (field, iterations, action, threshold): %s\n",
              bitid ? "YES" : "NO");
  const bool ok = d_never <= 1e-5 && d_always <= 1e-5 && bitid;
  std::printf("\n===== AA4 %s =====\n", ok ? "PASS" : "FAIL");
  return ok ? 0 : 1;
}

// ===========================================================================
// AA6 — RECYCLING IS UNAFFECTED.
//
// PR 273 measured recycle setup at 7.2 % of a latched iteration. That is a
// separate cost with a separate owner. This mode reports it before and after and
// changes nothing about it. Note the SHARE necessarily RISES as GenEO's cost is
// removed from the denominator — the number that must not move is the ABSOLUTE
// per-solve cost and the setup-matvec count.
// ===========================================================================
int mode_aa6(const std::string& dir) {
  const int n = env_i("TOPOPT_GDG_N", 32);
  const double dil = env_d("TOPOPT_GDG_DIL", 0.25);
  const double vf = env_d("TOPOPT_GDG_VF", 0.50);
  const int iters = env_i("TOPOPT_GDG_ITERS", 8);
  const Case C = make_case(n, dil, vf);
  std::printf("\n===== AA6 — RECYCLING UNAFFECTED — %s =====\n", C.label.c_str());

  const Run armed = trajectory("armed", C, iters, Posture::Armed, true, false);
  const Run gated = trajectory("gated", C, iters, Posture::Gated, true, false);
  write_csv(dir + "/aa6_armed.csv", armed);
  write_csv(dir + "/aa6_gated.csv", gated);

  auto rec_stats = [](const Run& R, double& ms, long long& mv, double& share) {
    std::vector<double> v;
    double tot = 0;
    mv = 0;
    for (const Rec& r : R.its) {
      v.push_back(r.recycle_ms);
      mv += r.recycle_setup_matvecs;
      tot += r.cg_ms + r.geneo_setup_ms + r.geneo_apply_ms + r.recycle_ms;
    }
    ms = median(v);
    double rsum = 0;
    for (const Rec& r : R.its) rsum += r.recycle_ms;
    share = tot > 0 ? rsum / tot : 0.0;
  };
  double ams, gms, ash, gsh;
  long long amv, gmv;
  rec_stats(armed, ams, amv, ash);
  rec_stats(gated, gms, gmv, gsh);
  std::printf("  recycle setup matvecs : ARMED %lld  ->  GATED %lld  %s\n", amv,
              gmv, amv == gmv ? "(IDENTICAL)" : "(CHANGED — investigate)");
  std::printf("  recycle wall/solve    : ARMED %.1f ms  ->  GATED %.1f ms\n",
              ams, gms);
  std::printf("  recycle SHARE of solve: ARMED %.1f%%  ->  GATED %.1f%%   "
              "(the share rises because GenEO left the denominator; the "
              "absolute cost is the number that must not move)\n",
              100 * ash, 100 * gsh);
  return 0;
}

// ===========================================================================
// aa1prod — AA1 ON THE PRODUCTION PATH. THE LOAD-BEARING RESCUE MEASUREMENT.
//
// minimize_plastic over PR 248's big-stagnation design box (73,728 elements,
// 48.8x dilution), full production posture minus draft, ARMED vs GATED in ABBA
// order so machine load cancels. Per-iteration numbers come from PR 273's
// observation stream, so `solve_ms` is the optimiser's own measurement of the
// solve, not a harness stopwatch wrapped around it.
//
// The bar: on the solves that genuinely stagnate, GATED must still ENGAGE and
// must still beat the plain posture in WALL. If it does not, the rule is wrong.
// ===========================================================================
int mode_aa1prod(const std::string& dir) {
  const int iters = env_i("TOPOPT_GDG_ITERS", 12);
  const int reps = env_i("TOPOPT_GDG_REPS", 2);
  SettingsRules rules;
  try {
    rules = load_settings_rules_file(SETTINGS_RULES_PATH);
  } catch (const std::exception& e) {
    std::fprintf(stderr, "FAIL: rules.json: %s\n", e.what());
    return 1;
  }
  std::printf("\n===== AA1prod — THE RESCUE CASE ON THE PRODUCTION PATH =====\n"
              "  big-stagnation design box, %d capped iterations, %d ABBA "
              "blocks\n", iters, reps);

  struct Pool {
    std::vector<double> solve_ms, cg, cg_ms, setup, apply, rec;
    long long builds = 0, refresh = 0, armed = 0, declined = 0;
    long long engaged_rows = 0, rows = 0, fallback_rows = 0;
    double wall = 0.0;
  };
  Pool PP, PA, PG;
  auto absorb = [](Pool& P, const ProdRun& R) {
    for (const ProdIter& r : R.its) {
      ++P.rows;
      if (r.used_mg) continue;      // multigrid carried: GenEO cannot act at all
      ++P.fallback_rows;
      P.solve_ms.push_back(r.solve_ms);
      P.cg.push_back(r.cg);
      P.cg_ms.push_back(r.cg_ms);
      P.setup.push_back(r.setup_ms);
      P.apply.push_back(r.apply_ms);
      P.rec.push_back(r.rec_ms);
      if (r.action == 1 || r.action == 2 || r.action == 3) ++P.engaged_rows;
    }
    P.builds += R.builds; P.refresh += R.refreshes;
    P.armed += R.armed; P.declined += R.declined;
    P.wall += R.wall;
  };

  FILE* fp = std::fopen((dir + "/aa1prod.csv").c_str(), "w");
  if (fp)
    std::fprintf(fp, "block,posture,iter,used_mg,cg_iters,geneo_action,"
                     "geneo_dim,geneo_burn,geneo_threshold,solve_ms,cg_ms,"
                     "geneo_setup_ms,geneo_apply_ms,recycle_ms\n");
  for (int b = 0; b < reps; ++b) {
    const bool armed_first = (b % 2) == 0;
    Posture order[3] = {Posture::Plain, Posture::Armed, Posture::Gated};
    if (!armed_first) { order[1] = Posture::Gated; order[2] = Posture::Armed; }
    for (int k = 0; k < 3; ++k) {
      const ProdRun R = production_run(order[k], iters, rules);
      absorb(order[k] == Posture::Plain ? PP
             : order[k] == Posture::Armed ? PA : PG, R);
      const char* nm = order[k] == Posture::Plain ? "plain"
                       : order[k] == Posture::Armed ? "armed" : "gated";
      long long fb = 0;
      int mx = 0;
      for (const ProdIter& r : R.its) { if (!r.used_mg) ++fb; mx = std::max(mx, r.cg); }
      std::printf("  block %d %-6s: wall %7.1f s  CG total %-9lld max/solve "
                  "%-7d  fallback rows %lld/%zu  builds=%lld refresh=%lld "
                  "armed=%lld declined=%lld\n",
                  b + 1, nm, R.wall, R.cg_total, mx, fb, R.its.size(),
                  R.builds, R.refreshes, R.armed, R.declined);
      if (fp)
        for (std::size_t i = 0; i < R.its.size(); ++i) {
          const ProdIter& r = R.its[i];
          std::fprintf(fp, "%d,%s,%zu,%d,%d,%d,%d,%d,%d,%.3f,%.3f,%.3f,%.3f,"
                           "%.3f\n",
                       b + 1, nm, i, r.used_mg, r.cg, r.action, r.dim, r.burn,
                       r.threshold, r.solve_ms, r.cg_ms, r.setup_ms, r.apply_ms,
                       r.rec_ms);
        }
    }
  }
  if (fp) { std::fclose(fp); std::printf("  wrote %s/aa1prod.csv\n", dir.c_str()); }

  auto line = [&](const char* nm, const Pool& P) {
    std::printf("  %-6s fallback solves %lld/%lld  median CG %6.0f (max %6.0f) "
                " median solve %8.1f ms  [cg %7.1f  geneo %8.1f+%7.1f  rec "
                "%6.1f]  engaged %lld  builds=%lld refresh=%lld declined=%lld\n",
                nm, P.fallback_rows, P.rows, median(P.cg),
                P.cg.empty() ? 0.0 : *std::max_element(P.cg.begin(), P.cg.end()),
                median(P.solve_ms), median(P.cg_ms),
                median(P.setup), median(P.apply), median(P.rec), P.engaged_rows,
                P.builds, P.refresh, P.declined);
  };
  std::printf("\n  POOLED OVER %d BLOCKS (fallback solves only — a multigrid "
              "solve never enters GenEO):\n", reps);
  line("plain", PP);
  line("ARMED", PA);
  line("GATED", PG);

  const double mp = median(PP.solve_ms), ma = median(PA.solve_ms),
               mg = median(PG.solve_ms);
  std::printf("\n  median wall per FALLBACK solve: plain %.1f ms | ARMED %.1f ms"
              " (%.2fx) | GATED %.1f ms (%.2fx)\n",
              mp, ma, mp > 0 ? ma / mp : 0.0, mg, mp > 0 ? mg / mp : 0.0);
  const bool still_arms = PG.engaged_rows > 0 || PG.armed > 0;
  const bool still_wins = mg <= mp;
  std::printf("\n  GATED still engages: %s (%lld engaged rows, %lld armed "
              "solves)\n  GATED beats plain in WALL: %s\n",
              still_arms ? "YES" : "NO", PG.engaged_rows, PG.armed,
              still_wins ? "YES" : "NO");
  std::printf("\n===== AA1prod %s =====\n",
              still_arms ? "the rescue SURVIVES the gate"
                         : "the gate DECLINED every stagnating solve — read the "
                           "per-row CSV before concluding anything");
  return 0;
}
