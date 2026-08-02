// recycle_reassess_modes.inc — the measurement modes. Included by
// recycle_reassess.cpp (one TU; the split is for readability, the way
// geneo_disarm_gate / geneo_standing_probe do it).

// ===========================================================================
// regime — THE THREE FIXTURE CLASSES, pinned and characterised before anything
// is graded. The whole task turns on keeping them apart: PR 248's "cheap, never
// harmful" was a single verdict over a posture that no longer exists, and a
// single verdict is exactly what this mode exists to prevent being written
// again.
// ===========================================================================
int mode_regime(const std::string& dir) {
  const int n = env_i("TOPOPT_RRA_N", 32);
  const double dil = env_d("TOPOPT_RRA_DIL", 0.25);
  const double vf = env_d("TOPOPT_RRA_VF", 0.50);
  const int iters = env_i("TOPOPT_RRA_ITERS", 4);
  std::printf("\n===== REGIME — the three fixture classes =====\n");
  FILE* fp = std::fopen((dir + "/regime.csv").c_str(), "w");
  if (fp)
    std::fprintf(fp, "class,iter,cg_iters,used_mg,hier_built,rec_dim,"
                     "setup_matvecs,solve_s,cg_ms,recycle_ms\n");

  struct Cls { const char* name; bool latched; };
  const Cls classes[2] = {{"(a) LATCHED  ", true}, {"(b) HEALTHY MG", false}};
  for (const Cls& cl : classes) {
    const Case C = make_bracket(n, dil, vf, cl.latched);
    std::printf("\n  %s  %s\n", cl.name, C.label.c_str());
    for (const bool rec : {false, true}) {
      Posture p = rec ? posture_on() : posture_off();
      const Run R = trajectory(rec ? "on" : "off", C, iters, p, false);
      int mn = 1 << 30, mx = 0;
      int mg = 0, hb = 0;
      for (const Rec& r : R.its) {
        mn = std::min(mn, r.cg);
        mx = std::max(mx, r.cg);
        mg += r.used_mg ? 1 : 0;
        hb += r.hier_built ? 1 : 0;
      }
      std::printf("    recycling %-3s : CG total %-8lld (min %-6d max %-6d)  "
                  "used_mg %d/%zu  hier_built %d/%zu  setup_mv %-4lld  "
                  "wall %7.2f s  DOF-work %.3e\n",
                  rec ? "ON" : "OFF", R.cg_total, mn, mx, mg, R.its.size(), hb,
                  R.its.size(), R.setup_mv_total, R.wall, dof_work(R));
      if (fp)
        for (const Rec& r : R.its)
          std::fprintf(fp, "%s recycling=%s,%d,%d,%d,%d,%d,%d,%.5f,%.3f,%.3f\n",
                       cl.name, rec ? "on" : "off", r.iter, r.cg,
                       r.used_mg ? 1 : 0, r.hier_built ? 1 : 0, r.rec_dim,
                       r.rec_setup_mv, r.solve_s, r.cg_ms, r.recycle_ms);
    }
  }
  // (c) is measured in mode `cert`; named here so the three classes are listed
  // together and no reader is left wondering where the third one went.
  std::printf("\n  (c) CERTIFICATION — measured in mode `cert` (one tight solve "
              "on a FIXED design,\n      warm-basis as production leaves it and "
              "cold-basis as an analyze job runs it).\n");
  if (fp) std::fclose(fp);
  return 0;
}

// ===========================================================================
// AG1 — THE HONEST A/B, IN TODAY'S POSTURE.
//
// Recycling ON vs OFF, GenEO armed with the engagement gate exactly as PR 278
// ships it, on the latched path and the healthy-multigrid path REPORTED
// SEPARATELY AND NEVER AVERAGED. Whole trajectories alternate in ABBA order
// inside one process, so stationary host load hits both postures equally and
// cancels; the ABBA order cancels linear drift. Both bars are printed: the
// deterministic DOF-weighted work, and the median per-solve wall with its
// spread.
// ===========================================================================
namespace {
void ab_report(const char* cls, const Pool& ON, const Pool& OFF, FILE* fp) {
  const double mon = median(ON.solve_s), mof = median(OFF.solve_s);
  const double won = pool_dof_work(ON), wof = pool_dof_work(OFF);
  std::printf("\n  %s — STEADY STATE, pooled:\n", cls);
  auto line = [&](const char* nm, const Pool& P) {
    std::printf("    %-3s  median/solve %7.3f s (spread %s)  CG median %6.0f  "
                "CG total %-8lld setup_mv %-5lld  phases(ms) cg %8.1f  "
                "recycle %7.1f\n",
                nm, median(P.solve_s), spread(P.solve_s).c_str(),
                median(P.cg_iters), P.cg_total, P.setup_mv, median(P.cg_ms),
                median(P.rec_ms));
  };
  line("ON", ON);
  line("OFF", OFF);
  const double rec = median(ON.rec_ms), cg = median(ON.cg_ms);
  std::printf("    DOF-WEIGHTED WORK  ON %.4e   OFF %.4e   = %.3fx %s\n", won,
              wof, wof > 0 ? won / wof : 0.0,
              won < wof ? "LESS work with recycling" : "MORE work with recycling");
  std::printf("    WALL per solve     ON %7.3f s  OFF %7.3f s  = %.3fx %s\n",
              mon, mof, mof > 0 ? mon / mof : 0.0,
              mon < mof ? "FASTER with recycling" : "SLOWER with recycling");
  std::printf("    recycle share of the ON solve's timed phases: %.1f%%\n",
              (rec + cg) > 0 ? 100.0 * rec / (rec + cg) : 0.0);
  if (fp)
    std::fprintf(fp, "%s,%.5f,%.5f,%.6e,%.6e,%lld,%lld,%.3f,%.3f\n", cls, mon,
                 mof, won, wof, ON.cg_total, OFF.cg_total, median(ON.rec_ms),
                 median(OFF.rec_ms));
}
}  // namespace

int mode_ab(const std::string& dir) {
  const int n = env_i("TOPOPT_RRA_N", 32);
  const double dil = env_d("TOPOPT_RRA_DIL", 0.25);
  const double vf = env_d("TOPOPT_RRA_VF", 0.50);
  const int iters = env_i("TOPOPT_RRA_ITERS", 8);
  const int reps = env_i("TOPOPT_RRA_REPS", 3);
  const int skip = env_i("TOPOPT_RRA_SKIP", 1);  // the bootstrap solve

  FILE* fp = std::fopen((dir + "/ab.csv").c_str(), "w");
  if (fp)
    std::fprintf(fp, "class,wall_on_s,wall_off_s,dofwork_on,dofwork_off,"
                     "cg_on,cg_off,recycle_ms_on,recycle_ms_off\n");
  FILE* raw = std::fopen((dir + "/ab_raw.csv").c_str(), "w");
  if (raw)
    std::fprintf(raw, "class,posture,block,iter,cg_iters,used_mg,solve_s,cg_ms,"
                      "recycle_ms,setup_matvecs\n");

  int rc = 0;
  struct Cls { const char* name; bool latched; };
  for (const Cls& cl : {Cls{"(a) LATCHED", true}, Cls{"(b) HEALTHY-MG", false}}) {
    const Case C = make_bracket(n, dil, vf, cl.latched);
    std::printf("\n===== AG1 A/B — %s =====\n  %s\n  %d ABBA blocks x %d design "
                "iterations, GenEO ARMED with the shipped engagement gate\n",
                cl.name, C.label.c_str(), reps, iters);
    Pool ON, OFF;
    std::vector<double> u_on, u_off;
    for (int b = 0; b < reps; ++b) {
      const bool on_first = (b % 2) == 0;   // ABBA
      for (int k = 0; k < 2; ++k) {
        const bool do_on = (k == 0) == on_first;
        const Run R = trajectory(do_on ? "on" : "off", C, iters,
                                 do_on ? posture_on() : posture_off(), false);
        absorb(do_on ? ON : OFF, R, skip);
        if (do_on && u_on.empty()) u_on = R.u_final;
        if (!do_on && u_off.empty()) u_off = R.u_final;
        std::printf("    block %d: %-3s wall %7.2f s  CG %-8lld setup_mv %-5lld"
                    "  load %.2f\n",
                    b + 1, do_on ? "ON" : "OFF", R.wall, R.cg_total,
                    R.setup_mv_total, load_avg_1m());
        if (raw)
          for (const Rec& r : R.its)
            std::fprintf(raw, "%s,%s,%d,%d,%d,%d,%.5f,%.3f,%.3f,%d\n", cl.name,
                         do_on ? "on" : "off", b + 1, r.iter, r.cg,
                         r.used_mg ? 1 : 0, r.solve_s, r.cg_ms, r.recycle_ms,
                         r.rec_setup_mv);
      }
    }
    ab_report(cl.name, ON, OFF, fp);
    // On the healthy path the session is constructed with allowed == false, so
    // ON and OFF should not merely agree to tolerance — they should be the SAME
    // ARITHMETIC. Checked, not assumed.
    if (!cl.latched) {
      std::printf("    healthy-path identity: fields %s, CG totals %s\n",
                  bit_equal(u_on, u_off) ? "BIT-IDENTICAL" : "DIFFER",
                  ON.cg_total == OFF.cg_total ? "equal" : "DIFFER");
      if (!bit_equal(u_on, u_off) || ON.cg_total != OFF.cg_total) rc = 1;
    }
  }
  if (fp) std::fclose(fp);
  if (raw) std::fclose(raw);
  std::printf("\n  host 1-min load average at end: %.2f\n", load_avg_1m());
  return rc;
}

// ===========================================================================
// AG1(c) — THE CERTIFICATION SOLVES.
//
// A certification solve is not a trajectory solve. It is ONE tight solve on a
// design the carried basis was never harvested from, and it comes in two shapes
// that behave differently and must not be pooled:
//   WARM  the rung's certification, run right after the trajectory with the
//         basis production leaves in place (krylov_recycle_reset_per_rung=false).
//   COLD  an `analyze` job: minimize_plastic/analyze resets the space at entry,
//         so a single solve runs with NO basis to apply and can only PAY the
//         harvest and the Rayleigh-Ritz. There is no mechanism by which
//         recycling can help here — the question is only how much it costs.
// ===========================================================================
int mode_cert(const std::string& dir) {
  const int n = env_i("TOPOPT_RRA_N", 32);
  const double dil = env_d("TOPOPT_RRA_DIL", 0.25);
  const double vf = env_d("TOPOPT_RRA_VF", 0.50);
  const int iters = env_i("TOPOPT_RRA_ITERS", 6);
  const int reps = env_i("TOPOPT_RRA_REPS", 3);
  FILE* fp = std::fopen((dir + "/cert.csv").c_str(), "w");
  if (fp)
    std::fprintf(fp, "class,shape,posture,block,cg_iters,used_mg,setup_matvecs,"
                     "solve_s,cg_ms,recycle_ms\n");

  struct Cls { const char* name; bool latched; };
  for (const Cls& cl : {Cls{"(a) LATCHED", true}, Cls{"(b) HEALTHY-MG", false}}) {
    const Case C = make_bracket(n, dil, vf, cl.latched);
    std::printf("\n===== AG1(c) CERTIFICATION SOLVES — %s =====\n  %s\n",
                cl.name, C.label.c_str());
    const DensityFilter filt =
        make_density_filter(C.grid, physical_filter_radius(2.5, C.grid.spacing));

    // The design to certify: the trajectory's own output, produced ONCE with
    // recycling off so the design being certified is the same field in every
    // posture below (recycling changes the route, never the answer — but this
    // removes even the tolerance-level difference from the comparison).
    const Run traj = trajectory("seed", C, iters, posture_off(), false);
    std::vector<double> xcert = filt.filter_density(traj.x_final);

    struct Shot { double solve_s, cg_ms, rec_ms; int cg, mv; bool mg; };
    auto cert_once = [&](bool warm, bool rec) {
      Posture p = rec ? posture_on() : posture_off();
      apply_posture(p, C);  // resets the space
      if (warm) {
        // Reproduce production: the basis is whatever the trajectory left.
        // Re-run the trajectory in THIS posture, then certify without resetting.
        std::vector<double> x = simp_uniform_density(C.grid, C.vf);
        for (int it = 0; it < iters; ++it) {
          SimpParams pa;
          pa.youngs_modulus = kE0; pa.poisson = kNu;
          pa.penalty = penalty_at(it); pa.density_min = kRhoMin;
          const SimpCompliance c = simp_compliance(
              C.grid, pa, filt.filter_density(x), C.bcs, C.loads, kTol, 0,
              nullptr, nullptr, SolverKind::MultigridCG_Matfree);
          x = oc_update(C.grid, filt, x, c.dcompliance, C.vf, 0.2, kRhoMin);
        }
      }
      SimpParams pa;
      pa.youngs_modulus = kE0; pa.poisson = kNu;
      pa.penalty = 3.0; pa.density_min = kRhoMin;
      const double ts = now_s();
      const SimpCompliance c =
          simp_compliance(C.grid, pa, xcert, C.bcs, C.loads, kTol, 0, nullptr,
                          nullptr, SolverKind::MultigridCG_Matfree);
      Shot s{now_s() - ts, c.cg.t_cg_ms, c.cg.t_recycle_ms, c.cg.iterations,
             c.cg.recycle_setup_matvecs, c.cg.used_multigrid};
      clear_posture();
      return s;
    };

    for (const bool warm : {false, true}) {
      std::vector<double> on_s, off_s;
      long long on_cg = 0, off_cg = 0, on_mv = 0;
      double on_rec = 0.0;
      for (int b = 0; b < reps; ++b) {
        const bool on_first = (b % 2) == 0;
        for (int k = 0; k < 2; ++k) {
          const bool do_on = (k == 0) == on_first;
          const Shot s = cert_once(warm, do_on);
          (do_on ? on_s : off_s).push_back(s.solve_s);
          (do_on ? on_cg : off_cg) += s.cg;
          if (do_on) { on_mv += s.mv; on_rec += s.rec_ms; }
          if (fp)
            std::fprintf(fp, "%s,%s,%s,%d,%d,%d,%d,%.5f,%.3f,%.3f\n", cl.name,
                         warm ? "warm" : "cold", do_on ? "on" : "off", b + 1,
                         s.cg, s.mg ? 1 : 0, s.mv, s.solve_s, s.cg_ms,
                         s.rec_ms);
        }
      }
      const double mon = median(on_s), mof = median(off_s);
      const double won = double(on_cg + on_mv) * double(C.ndof);
      const double wof = double(off_cg) * double(C.ndof);
      std::printf("  %-4s basis : CG ON %-6lld OFF %-6lld  setup_mv %-4lld  "
                  "recycle %6.1f ms\n"
                  "              DOF-work %.4e vs %.4e = %.3fx   "
                  "wall %.3f s vs %.3f s = %.3fx %s\n",
                  warm ? "WARM" : "COLD", on_cg, off_cg, on_mv,
                  on_rec / std::max(1, reps), won, wof, wof > 0 ? won / wof : 0,
                  mon, mof, mof > 0 ? mon / mof : 0,
                  mon < mof ? "FASTER" : "SLOWER");
    }
  }
  if (fp) std::fclose(fp);
  std::printf("\n  host 1-min load average at end: %.2f\n", load_avg_1m());
  return 0;
}

// ===========================================================================
// AG2 — WHERE DOES THE BILL GO?
//
// `recycle_ms` split into the phases a maintainer can actually act on. The
// mapping from phase to lever is the point of the mode:
//     setup_matvec + setup_other + commit  -> the CADENCE (AG4) can halve these
//     augment                              -> only the DIMENSION (AG3) or
//                                             disarming can touch this
//     observe                              -> the harvest sample
// The split is reconciled against the call site's own `recycle_ms` on every
// solve, so a reader can see that nothing is unattributed — the same closure
// property PR 273's residual column provides one level up.
// ===========================================================================
int mode_phases(const std::string& dir) {
  const int n = env_i("TOPOPT_RRA_N", 32);
  const double dil = env_d("TOPOPT_RRA_DIL", 0.25);
  const double vf = env_d("TOPOPT_RRA_VF", 0.50);
  const int iters = env_i("TOPOPT_RRA_ITERS", 8);
  // TOPOPT_RRA_WRAP=1 puts the same instrument on the MULTIGRID call site. That
  // site has no phase spans of its own — `recycle_ms` reads 0 there even when a
  // session is live, because only mf_cg_solve wraps its recycle calls in spans
  // (and multigrid.cpp is out of this task's scope). The instrument lives inside
  // recycle.cpp, so it sees BOTH call sites regardless.
  const bool wrap = env_i("TOPOPT_RRA_WRAP", 0) != 0;
  fea_detail::rc_set_phase_timing(true);

  FILE* fp = std::fopen((dir + "/phases.csv").c_str(), "w");
  if (fp)
    std::fprintf(fp, "class,iter,cg_iters,recycle_ms,begin_ms,setup_matvec_ms,"
                     "setup_other_ms,augment_ms,observe_ms,commit_ms,sum_ms,"
                     "augment_calls,observe_stores,setup_matvecs\n");

  struct Cls { const char* name; bool latched; };
  for (const Cls& cl : {Cls{"(a) LATCHED", true}, Cls{"(b) HEALTHY-MG", false}}) {
    const Case C = make_bracket(n, dil, vf, cl.latched);
    std::printf("\n===== AG2 PHASE SPLIT — %s%s =====\n  %s\n", cl.name,
                wrap ? "  [wrap_multigrid=1]" : "", C.label.c_str());
    Posture p = posture_on();
    p.wrap_mg = wrap;
    const Run R = trajectory("phases", C, iters, p, false);
    double tb = 0, tsm = 0, tso = 0, ta = 0, to = 0, tc = 0, trec = 0;
    long long ac = 0, os = 0, mv = 0, hs = 0;
    std::printf("    %-4s %-7s %9s | %8s %8s %8s %9s %8s %8s | %8s %6s\n",
                "it", "cg", "recycle", "begin", "setup_mv", "setup_o",
                "augment", "observe", "commit", "sum", "close");
    for (const Rec& r : R.its) {
      const RcPhaseTimes& p = r.ph;
      const double sum = p.begin_ms + p.setup_matvec_ms + p.setup_other_ms +
                         p.augment_ms + p.observe_ms + p.commit_ms;
      std::printf("    %-4d %-7d %9.1f | %8.1f %8.1f %8.1f %9.1f %8.1f %8.1f "
                  "| %8.1f %5.1f%%\n",
                  r.iter, r.cg, r.recycle_ms, p.begin_ms, p.setup_matvec_ms,
                  p.setup_other_ms, p.augment_ms, p.observe_ms, p.commit_ms,
                  sum, r.recycle_ms > 0 ? 100.0 * sum / r.recycle_ms : 0.0);
      tb += p.begin_ms; tsm += p.setup_matvec_ms; tso += p.setup_other_ms;
      ta += p.augment_ms; to += p.observe_ms; tc += p.commit_ms;
      trec += r.recycle_ms;
      ac += p.augment_calls; os += p.observe_stores; mv += p.setup_matvecs;
      hs += p.harvest_sessions;
      if (fp)
        std::fprintf(fp,
                     "%s,%d,%d,%.3f,%.3f,%.3f,%.3f,%.3f,%.3f,%.3f,%.3f,%lld,"
                     "%lld,%lld\n",
                     cl.name, r.iter, r.cg, r.recycle_ms, p.begin_ms,
                     p.setup_matvec_ms, p.setup_other_ms, p.augment_ms,
                     p.observe_ms, p.commit_ms, sum, p.augment_calls,
                     p.observe_stores, p.setup_matvecs);
    }
    const double tot = tb + tsm + tso + ta + to + tc;
    auto pct = [&](double v) { return tot > 0 ? 100.0 * v / tot : 0.0; };
    std::printf("\n    TOTALS  recycle_ms(call site) %.1f   sum(phases) %.1f   "
                "closure %.2f%%\n", trec, tot,
                trec > 0 ? 100.0 * tot / trec : 0.0);
    std::printf("      begin        %9.1f ms  %5.1f%%\n", tb, pct(tb));
    std::printf("      setup matvec %9.1f ms  %5.1f%%   (%lld matvecs)\n", tsm,
                pct(tsm), mv);
    std::printf("      setup other  %9.1f ms  %5.1f%%\n", tso, pct(tso));
    std::printf("      AUGMENT      %9.1f ms  %5.1f%%   (%lld calls, %.4f "
                "ms/call)\n", ta, pct(ta), ac, ac > 0 ? ta / double(ac) : 0.0);
    std::printf("      observe      %9.1f ms  %5.1f%%   (%lld stores)\n", to,
                pct(to), os);
    std::printf("      commit       %9.1f ms  %5.1f%%   (%lld harvest solves)\n",
                tc, pct(tc), hs);
    std::printf("\n    CADENCE-ADDRESSABLE (setup+commit) %5.1f%%   "
                "DIMENSION-ONLY (augment) %5.1f%%\n",
                pct(tsm + tso + tc), pct(ta));
  }
  if (fp) std::fclose(fp);
  fea_detail::rc_set_phase_timing(false);
  return 0;
}

// ===========================================================================
// AG3 / AG4 — THE TWO SWEEPS.
//
// Both are run as ROUND-ROBIN interleavings with the setting order REVERSED on
// alternate repeats, which is the ABBA discipline generalised past two arms: a
// stationary load hits every setting equally and a linear drift cancels between
// the forward and backward passes. Every row carries both bars.
// ===========================================================================
namespace {
struct SweepRow {
  std::string name;
  Posture p;
  Pool pool;
};

void run_sweep(const char* title, const Case& C, std::vector<SweepRow>& rows,
               int iters, int reps, int skip, const std::string& csv) {
  std::printf("\n===== %s =====\n  %s\n  %d round-robin repeats x %d design "
              "iterations (order reversed on alternate repeats)\n",
              title, C.label.c_str(), reps, iters);
  for (int b = 0; b < reps; ++b) {
    const bool fwd = (b % 2) == 0;
    for (std::size_t q = 0; q < rows.size(); ++q) {
      SweepRow& row = rows[fwd ? q : rows.size() - 1 - q];
      const Run R = trajectory(row.name, C, iters, row.p, false);
      absorb(row.pool, R, skip);
      std::printf("    rep %d  %-10s wall %7.2f s  CG %-8lld setup_mv %-5lld  "
                  "load %.2f\n",
                  b + 1, row.name.c_str(), R.wall, R.cg_total, R.setup_mv_total,
                  load_avg_1m());
    }
  }
  FILE* fp = std::fopen(csv.c_str(), "w");
  if (fp)
    std::fprintf(fp, "setting,cg_total,setup_matvecs,dofwork,wall_median_s,"
                     "cg_ms_median,recycle_ms_median,recycle_share_pct\n");
  // The baseline row is the first one; every ratio is against it.
  const double base_w = pool_dof_work(rows.front().pool);
  const double base_t = median(rows.front().pool.solve_s);
  std::printf("\n  %-10s %10s %10s %13s %8s %10s %10s %9s %8s\n", "setting",
              "CG total", "setup_mv", "DOF-work", "vs base", "wall/solve",
              "vs base", "recycle", "rec share");
  for (const SweepRow& row : rows) {
    const double w = pool_dof_work(row.pool);
    const double t = median(row.pool.solve_s);
    const double rec = median(row.pool.rec_ms), cg = median(row.pool.cg_ms);
    std::printf("  %-10s %10lld %10lld %13.4e %7.3fx %9.3f s %7.3fx %8.1f ms "
                "%7.1f%%\n",
                row.name.c_str(), row.pool.cg_total, row.pool.setup_mv, w,
                base_w > 0 ? w / base_w : 0.0, t, base_t > 0 ? t / base_t : 0.0,
                rec, (rec + cg) > 0 ? 100.0 * rec / (rec + cg) : 0.0);
    if (fp)
      std::fprintf(fp, "%s,%lld,%lld,%.6e,%.5f,%.3f,%.3f,%.2f\n",
                   row.name.c_str(), row.pool.cg_total, row.pool.setup_mv, w, t,
                   cg, rec, (rec + cg) > 0 ? 100.0 * rec / (rec + cg) : 0.0);
  }
  if (fp) std::fclose(fp);
  std::printf("  host 1-min load average at end: %.2f\n", load_avg_1m());
}
}  // namespace

int mode_dim(const std::string& dir) {
  const int n = env_i("TOPOPT_RRA_N", 32);
  const double dil = env_d("TOPOPT_RRA_DIL", 0.25);
  const double vf = env_d("TOPOPT_RRA_VF", 0.50);
  const int iters = env_i("TOPOPT_RRA_ITERS", 8);
  const int reps = env_i("TOPOPT_RRA_REPS", 3);
  const int skip = env_i("TOPOPT_RRA_SKIP", 1);
  const Case C = make_bracket(n, dil, vf, true);
  std::vector<SweepRow> rows;
  for (const int k : {0, 4, 8, 16, 32}) {
    SweepRow r;
    r.name = k == 0 ? "k=0 (off)" : ("k=" + std::to_string(k));
    r.p = k == 0 ? posture_off() : posture_on();
    if (k > 0) r.p.dim = k;
    rows.push_back(r);
  }
  run_sweep("AG3 — RECYCLE DIMENSION SWEEP (latched path)", C, rows, iters, reps,
            skip, dir + "/dim.csv");
  return 0;
}

int mode_cycle(const std::string& dir) {
  const int n = env_i("TOPOPT_RRA_N", 32);
  const double dil = env_d("TOPOPT_RRA_DIL", 0.25);
  const double vf = env_d("TOPOPT_RRA_VF", 0.50);
  const int iters = env_i("TOPOPT_RRA_ITERS", 8);
  const int reps = env_i("TOPOPT_RRA_REPS", 3);
  const int skip = env_i("TOPOPT_RRA_SKIP", 1);
  const Case C = make_bracket(n, dil, vf, true);
  std::vector<SweepRow> rows;
  {
    SweepRow r;
    r.name = "off";
    r.p = posture_off();
    rows.push_back(r);
  }
  for (const int c : {1, 2, 4, 8}) {
    SweepRow r;
    r.name = "cycle=" + std::to_string(c);
    r.p = posture_on();
    r.p.cycle = c;
    rows.push_back(r);
  }
  run_sweep("AG4 — HARVEST CADENCE SWEEP (latched path; cycle=1 SHIPS)", C, rows,
            iters, reps, skip, dir + "/cycle.csv");
  return 0;
}

// ===========================================================================
// AG5 — THE MULTIGRID INTERACTION.
//
// `krylov_recycle_wrap_multigrid` is false in production, and with it false the
// multigrid call site constructs its session with allowed == false: no state
// touched, no matvecs, no allocation, no correction. So on the healthy path
// recycling today is not cheap — it is ABSENT. This mode measures what flipping
// it costs on exactly the path PR 273/278 showed is worth 0.45 s/solve and where
// the campaign is now headed.
// ===========================================================================
int mode_wrapmg(const std::string& dir) {
  const int n = env_i("TOPOPT_RRA_N", 32);
  const double dil = env_d("TOPOPT_RRA_DIL", 0.25);
  const double vf = env_d("TOPOPT_RRA_VF", 0.50);
  const int iters = env_i("TOPOPT_RRA_ITERS", 8);
  const int reps = env_i("TOPOPT_RRA_REPS", 3);
  const int skip = env_i("TOPOPT_RRA_SKIP", 1);
  const Case C = make_bracket(n, dil, vf, false);  // HEALTHY
  std::vector<SweepRow> rows;
  {
    SweepRow r; r.name = "off"; r.p = posture_off(); rows.push_back(r);
  }
  {
    SweepRow r; r.name = "wrap=0"; r.p = posture_on(); rows.push_back(r);
  }
  {
    SweepRow r; r.name = "wrap=1"; r.p = posture_on(); r.p.wrap_mg = true;
    rows.push_back(r);
  }
  run_sweep("AG5 — WRAP-THE-V-CYCLE ON THE HEALTHY PATH", C, rows, iters, reps,
            skip, dir + "/wrapmg.csv");
  return 0;
}

// ===========================================================================
// AG7 — CORRECTNESS. The augmented solve must remain EXACT.
//
// Recycling is an SPD additive preconditioner, so PCG's fixed point is
// unchanged and the stopping test is the same relative residual. That is an
// argument; this mode is the measurement. Same design, same tolerance, ON vs
// OFF, worst relative displacement deviation reported. Plus determinism: the
// same posture rerun in the same process must be BIT-identical, because nothing
// in the recycler reads a clock, a thread id or a random number.
// ===========================================================================
int mode_exact(const std::string& dir) {
  const int n = env_i("TOPOPT_RRA_N", 32);
  const double dil = env_d("TOPOPT_RRA_DIL", 0.25);
  const double vf = env_d("TOPOPT_RRA_VF", 0.50);
  const int iters = env_i("TOPOPT_RRA_ITERS", 6);
  FILE* fp = std::fopen((dir + "/exact.txt").c_str(), "w");
  int rc = 0;

  struct Cls { const char* name; bool latched; };
  for (const Cls& cl : {Cls{"(a) LATCHED", true}, Cls{"(b) HEALTHY-MG", false}}) {
    const Case C = make_bracket(n, dil, vf, cl.latched);
    std::printf("\n===== AG7 EXACTNESS + DETERMINISM — %s =====\n  %s\n",
                cl.name, C.label.c_str());
    const Run off = trajectory("off", C, iters, posture_off(), false);
    const Run on1 = trajectory("on-1", C, iters, posture_on(), false);
    const Run on2 = trajectory("on-2", C, iters, posture_on(), false);

    // THE SHARPEST FORM OF THE BAR: one solve, one design, two postures. The
    // trajectory comparison below lets six OC updates compound whatever the
    // first solve's tolerance-level difference was, so it answers "does the
    // optimizer end up somewhere else" — a different and looser question than
    // "is the augmented SOLVE exact". This answers the sharp one.
    {
      const DensityFilter filt = make_density_filter(
          C.grid, physical_filter_radius(2.5, C.grid.spacing));
      const Run seed = trajectory("seed", C, iters, posture_off(), false);
      const std::vector<double> xs = filt.filter_density(seed.x_final);
      auto one = [&](bool rec) {
        apply_posture(rec ? posture_on() : posture_off(), C);
        SimpParams pa;
        pa.youngs_modulus = kE0; pa.poisson = kNu;
        pa.penalty = 3.0; pa.density_min = kRhoMin;
        // A warm basis is the interesting case: an EMPTY one cannot change the
        // route at all, so it could not detect an exactness failure.
        if (rec)
          (void)simp_compliance(C.grid, pa, xs, C.bcs, C.loads, kTol, 0, nullptr,
                                nullptr, SolverKind::MultigridCG_Matfree);
        const SimpCompliance c =
            simp_compliance(C.grid, pa, xs, C.bcs, C.loads, kTol, 0, nullptr,
                            nullptr, SolverKind::MultigridCG_Matfree);
        clear_posture();
        return c;
      };
      const SimpCompliance a = one(false);
      const SimpCompliance b = one(true);
      const double du1 = rel_diff(b.solution.u, a.solution.u);
      const double dc1 = a.compliance != 0.0
                             ? std::fabs(b.compliance - a.compliance) /
                                   std::fabs(a.compliance)
                             : 0.0;
      std::printf("    SINGLE SOLVE, same design, warm basis:\n"
                  "      CG  OFF %-6d (resid %.3e)   ON %-6d (resid %.3e)\n"
                  "      worst relative displacement deviation : %.3e\n"
                  "      compliance relative deviation         : %.3e\n",
                  a.cg.iterations, a.cg.residual, b.cg.iterations,
                  b.cg.residual, du1, dc1);
      if (fp)
        std::fprintf(fp, "%s single_solve du=%.6e dc=%.6e cg_off=%d cg_on=%d "
                         "resid_off=%.6e resid_on=%.6e\n",
                     cl.name, du1, dc1, a.cg.iterations, b.cg.iterations,
                     a.cg.residual, b.cg.residual);
    }

    const double du = rel_diff(on1.u_final, off.u_final);
    const double dx = rel_diff(on1.x_final, off.x_final);
    const bool det_u = bit_equal(on1.u_final, on2.u_final);
    const bool det_x = bit_equal(on1.x_final, on2.x_final);
    const double dc = off.its.back().compliance > 0
                          ? std::fabs(on1.its.back().compliance -
                                      off.its.back().compliance) /
                                off.its.back().compliance
                          : 0.0;
    std::printf("    worst relative displacement deviation ON vs OFF : %.3e "
                "(CG tolerance %.0e)\n", du, kTol);
    std::printf("    worst relative density deviation                : %.3e\n",
                dx);
    std::printf("    final compliance relative deviation             : %.3e\n",
                dc);
    std::printf("    determinism (same posture rerun): u %s   x %s\n",
                det_u ? "BIT-IDENTICAL" : "DIFFERS",
                det_x ? "BIT-IDENTICAL" : "DIFFERS");
    std::printf("    CG totals: OFF %lld  ON %lld  (ON-1 vs ON-2 %s)\n",
                off.cg_total, on1.cg_total,
                on1.cg_total == on2.cg_total ? "equal" : "DIFFER");
    if (fp)
      std::fprintf(fp,
                   "%s du=%.6e dx=%.6e dc=%.6e det_u=%d det_x=%d cg_off=%lld "
                   "cg_on=%lld cg_on2=%lld\n",
                   cl.name, du, dx, dc, det_u ? 1 : 0, det_x ? 1 : 0,
                   off.cg_total, on1.cg_total, on2.cg_total);
    if (!det_u || !det_x) rc = 1;
    if (du > 1e-6) rc = 1;
  }
  if (fp) std::fclose(fp);
  return rc;
}
