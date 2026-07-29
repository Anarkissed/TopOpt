// geneo_twolevel_probe_part3.inc — measurement modes (included by part2 before main).
// Same TU: sees every helper above (TwoLevel, develop_pipeline, solve_reduced, ...).

namespace {

// Fixture selector (env-overridable). Default = the 48x32x48-class dilute L-bracket
// whose real-ladder field stagnates (multigrid -> Jacobi-CG), the tractable stand-in
// for the maintainer's 128^3 vf-0.26 rung.
struct FixtureSpec { int arm, span, ny, t; double h, vf; int iters; };
FixtureSpec fixture_from_env() {
  FixtureSpec s{24,24,6,6,1.0,0.26,30};
  if (std::getenv("TL_ARM")) s.arm = std::atoi(std::getenv("TL_ARM"));
  if (std::getenv("TL_SPAN")) s.span = std::atoi(std::getenv("TL_SPAN"));
  if (std::getenv("TL_NY")) s.ny = std::atoi(std::getenv("TL_NY"));
  if (std::getenv("TL_T")) s.t = std::atoi(std::getenv("TL_T"));
  if (std::getenv("TL_VF")) s.vf = std::atof(std::getenv("TL_VF"));
  if (std::getenv("TL_ITERS")) s.iters = std::atoi(std::getenv("TL_ITERS"));
  return s;
}

DevelopedCase load_stag(const std::string& dir) {
  const FixtureSpec s = fixture_from_env();
  const DesignBox box = stagnation_box(s.arm,s.span,s.ny,s.t,s.h);
  char cache[512]; std::snprintf(cache,sizeof cache,"%s/stag_%d_%d_%d_%d_vf%02d_it%d.bin",
                                 dir.c_str(),s.arm,s.span,s.ny,s.t,(int)(s.vf*100),s.iters);
  DevelopedCase D = develop_pipeline(s.arm,s.span,s.ny,s.t,s.h,s.vf,s.iters,Vec3{0,0,-30},box,cache);
  return D;
}

// A production OC stepper seeded from a physical-density field, to generate a short
// run of consecutive design states (per-iteration solves for P2, drift for P6).
struct Developer {
  const VoxelGrid* g=nullptr; DensityFilter f; SimpParams params;
  const std::vector<DirichletBC>* bcs=nullptr; const std::vector<NodalLoad>* loads=nullptr;
  std::vector<double> x; double vf=0.26;
  void init(const VoxelGrid& G, const std::vector<DirichletBC>& B, const std::vector<NodalLoad>& L,
            const std::vector<double>& seed, double vfrac) {
    g=&G; bcs=&B; loads=&L; vf=vfrac;
    params.youngs_modulus=kE0; params.poisson=kNu; params.penalty=(double)kSimpP; params.density_min=kRhoMinProd;
    f = make_density_filter(G, physical_filter_radius(2.5, G.spacing));
    x = seed;
  }
  std::vector<double> physical() const { return f.filter_density(x); }
  std::vector<double> step() {
    const std::vector<double> xp = f.filter_density(x);
    fea_matfree_reset_mg_stagnation_latch();
    const SimpCompliance c = simp_compliance(*g, params, xp, *bcs, *loads, kCertTol, 0,
                                             nullptr, nullptr, SolverKind::MultigridCG_Matfree);
    x = oc_update(*g, f, x, c.dcompliance, vf, 0.2, kRhoMinProd);
    return f.filter_density(x);
  }
};

// Build the reduced matrix-free operator for a physical density on grid g.
MatfreeReduced build_reduced(const VoxelGrid& g, const std::vector<double>& rho,
                             const std::vector<DirichletBC>& bcs, const std::vector<NodalLoad>& loads,
                             std::vector<double>& ey_out) {
  ey_out = penalized_youngs(g, rho);
  CgInfo info;
  return mf_build_reduced(g, kE0, kNu, bcs, loads, &ey_out, "twolevel_probe", &info);
}

TwoLevelCfg cfg_from_env() {
  TwoLevelCfg c;
  if (std::getenv("TL_CORE")) c.core = std::atoi(std::getenv("TL_CORE"));
  if (std::getenv("TL_OV")) c.ov = std::atoi(std::getenv("TL_OV"));
  if (std::getenv("TL_CUT")) c.lambda_cut = std::atof(std::getenv("TL_CUT"));
  if (std::getenv("TL_LOCAL")) c.local = std::atoi(std::getenv("TL_LOCAL")) ? LocalSolveKind::InnerCG : LocalSolveKind::Jacobi;
  if (std::getenv("TL_LITERS")) c.local_iters = std::atoi(std::getenv("TL_LITERS"));
  if (std::getenv("TL_TAILCG")) c.tail_inner_cg = std::atoi(std::getenv("TL_TAILCG"));
  if (std::getenv("TL_CDENSE")) c.coarse_dense_cap = std::atoi(std::getenv("TL_CDENSE"));
  if (std::getenv("TL_LOCALTERM")) c.with_local = true;   // ablation: enable local Schwarz
  if (std::getenv("TL_NOLOCAL")) c.with_local = false;
  if (std::getenv("TL_NOCOARSE")) c.with_coarse = false;
  return c;
}

// ===================================================================================
int mode_selfcheck(const std::string& dir) {
  (void)dir; int fail=0;
  std::printf("=== SELFCHECK (two-level preconditioner) ===\n");
  // (1) default OFF: no hook installed (P1 tripwire).
  {
    const bool inst = fea_detail::mf_precond_hook_installed();
    std::printf("  hook installed by default: %d  %s\n", inst, !inst?"PASS":"FAIL");
    if (inst) ++fail;
    std::printf("  kMatfreeExternalPrecondDefaultOff=%d  %s\n",
                (int)topopt::kMatfreeExternalPrecondDefaultOff, topopt::kMatfreeExternalPrecondDefaultOff?"PASS":"FAIL");
    if (!topopt::kMatfreeExternalPrecondDefaultOff) ++fail;
  }
  // (2) SPD-consistency + effectiveness on a SMALL, FAST, HIGH-CONTRAST system built by
  //     hand (no slow ladder develop): a thin solid bar (rho=1) through an otherwise
  //     near-void (rho_min) box — contrast 1e9, the near-void surround gives Jacobi-CG
  //     the near-null modes it grinds on. Two-level PCG must converge to the SAME field
  //     (any SPD additive precond only changes iters) and in FEWER iterations.
  {
    const int nx=std::getenv("TL_NX")?std::atoi(std::getenv("TL_NX")):24;
    const int ny=std::getenv("TL_NY")?std::atoi(std::getenv("TL_NY")):8;
    const int nz=std::getenv("TL_NZ")?std::atoi(std::getenv("TL_NZ")):24;
    VoxelGrid g; g.nx=nx; g.ny=ny; g.nz=nz; g.spacing=1.0; g.origin=Vec3{0,0,0};
    g.tags.assign((std::size_t)nx*ny*nz, VoxelTag::Interior);
    std::vector<DirichletBC> bcs; std::vector<NodalLoad> loads;
    for (int c=0;c<=nz;++c) for (int b=0;b<=ny;++b){ int nd=fea_node_index(g,0,b,c); bcs.push_back({nd,0,0.0}); bcs.push_back({nd,1,0.0}); bcs.push_back({nd,2,0.0}); }
    for (int b=0;b<=ny;++b) loads.push_back({fea_node_index(g,nx,b,0),2,-100.0/(ny+1)});
    // NEAR-DISCONNECTION: solid block almost severed by a near-void slot at mid-span,
    // joined only by a thin central bridge. The relative motion of the two halves is a
    // near-null mode (tiny eigenvalue) — the mode Jacobi-CG grinds on for thousands of
    // iterations and the GenEO coarse space is built to capture. This is the regime the
    // two-level preconditioner exists for.
    std::vector<double> rho((std::size_t)nx*ny*nz, 1.0);   // solid block
    const int i0 = nx/2;
    for (int b=0;b<ny;++b) for (int k=0;k<nz;++k) {
      const bool bridge = (b>=ny/2-1 && b<=ny/2) && (k>=nz/2-1 && k<=nz/2);
      if (!bridge) rho[g.index(i0,b,k)] = kRhoMinProd;      // near-void slot except the bridge
    }
    std::vector<double> ey; MatfreeReduced m = build_reduced(g, rho, bcs, loads, ey);
    MfSolveContext ctx; ctx.grid=&g; ctx.elem_youngs=&ey; ctx.youngs_modulus=kE0; ctx.poisson=kNu;
    const int cap = 60000;
    std::vector<double> xref(m.ng,0.0); int it0; double e0; bool c0;
    fea_matfree_reset_mg_stagnation_latch();
    mf_cg_solve(m, kCertTol, cap, xref, it0, e0, c0, nullptr, &ctx);
    TwoLevelCfg c = cfg_from_env(); if (c.core>8) c.core=8;
    TwoLevel tl; tl.build(g, ey, m, c);
    std::vector<double> x2(m.ng,0.0); int it1; double e1; bool c1;
    { HookGuard hg(&tl); mf_cg_solve(m, kCertTol, cap, x2, it1, e1, c1, nullptr, &ctx); }
    double num=0,den=0; for (int i=0;i<m.ng;++i){ num=std::max(num,std::abs(x2[i]-xref[i])); den=std::max(den,std::abs(xref[i])); }
    const double rel = den>0? num/den : 0.0;
    std::printf("  system ng=%d  Jacobi-CG=%d it (conv %d, res %.1e)  two-level=%d it (conv %d, res %.1e)\n",
                m.ng, it0, c0, e0, it1, c1, e1);
    std::printf("  same-answer max|du|/max|u|=%.2e   iter reduction=%.1fx   %s\n",
                rel, it1>0?(double)it0/it1:0.0, (c0&&c1&&rel<1e-6)?"PASS":"FAIL");
    if (!(c0&&c1&&rel<1e-6)) ++fail;
    std::printf("  coarse: Nt=%d dense=%d cond=%.2e  nsub=%d  basis=%.1fMB subops=%.1fMB  LOBPCG it med/max=%d/%d modes med/max=%d/%d\n",
                tl.Nt, (int)tl.coarse_dense, tl.coarse_cond, tl.nsub, tl.basis_mb, tl.subops_mb,
                tl.lob_iters_med, tl.lob_iters_max, tl.modes_med, tl.modes_max);
    if (tl.coarse_dense && !(tl.coarse_cond>0)) { std::printf("  coarse not SPD! FAIL\n"); ++fail; }
  }
  std::printf("SELFCHECK: %s\n", fail==0?"ALL PASS":"FAILURES");
  return fail;
}

// ===================================================================================
// P2 — THE headline. On the stagnating rung: baseline Jacobi-CG vs two-level PCG,
// per optimizer iteration. Reports CG iterations (the currency), wall, and RSS.
int mode_p2(const std::string& dir) {
  FILE* csv = open_csv(dir, "p2_iters.csv");
  if (csv) std::fprintf(csv, "iter,ng,jacobi_cg,twolevel_cg,ratio,jac_wall_s,tl_wall_s,jac_res,tl_res,Nt,build_s\n");
  DevelopedCase D = load_stag(dir);
  const VoxelGrid& g = D.grid;
  std::printf("## P2 stagnating rung: grid %dx%dx%d (%zu vox, %zu solid), vf=%.2f\n",
              g.nx,g.ny,g.nz,g.voxel_count(),g.solid_count(),D.vf);
  Developer dev; dev.init(g, D.bcs, D.loads, D.snaps.back(), D.vf);
  std::vector<double> rho = D.snaps.back();
  const TwoLevelCfg cfg = cfg_from_env();
  const int nsnap = std::getenv("TL_SNAPS")?std::atoi(std::getenv("TL_SNAPS")):4;
  std::printf("   cfg core=%d ov=%d cut=%.2f local=%s liters=%d tailcg=%d\n",
              cfg.core,cfg.ov,cfg.lambda_cut, cfg.local==LocalSolveKind::InnerCG?"innerCG":"jacobi",
              cfg.local_iters, cfg.tail_inner_cg);
  std::printf("\n iter   ng     Jacobi-CG   two-level   ratio   Nt   build(s)  jacW(s) tlW(s)\n");
  const double rss0 = peak_rss_bytes()/1048576.0;
  for (int it=0; it<nsnap; ++it) {
    if (it>0) rho = dev.step();
    std::vector<double> ey; MatfreeReduced m = build_reduced(g, rho, D.bcs, D.loads, ey);
    // baseline: production Jacobi-CG (no hook)
    SolveResult jr = solve_reduced(m, kCertTol, 0, nullptr, g, ey);
    // two-level
    const double tb = now_ms();
    TwoLevel tl; tl.build(g, ey, m, cfg);
    const double build_s = (now_ms()-tb)/1e3;
    SolveResult tr = solve_reduced(m, kCertTol, 0, &tl, g, ey);
    const double ratio = tr.iters>0? (double)jr.iters/tr.iters : 0.0;
    std::printf("  %3d %6d   %8d   %8d   %5.1fx  %4d  %7.2f  %6.1f %6.1f  %s\n",
                it, m.ng, jr.iters, tr.iters, ratio, tl.Nt, build_s, jr.wall_ms/1e3, tr.wall_ms/1e3,
                (jr.converged&&tr.converged)?"":"(!conv)");
    if (csv) std::fprintf(csv, "%d,%d,%d,%d,%.3f,%.3f,%.3f,%.2e,%.2e,%d,%.3f\n",
                          it,m.ng,jr.iters,tr.iters,ratio,jr.wall_ms/1e3,tr.wall_ms/1e3,jr.residual,tr.residual,tl.Nt,build_s);
    if (it==0) {
      std::printf("   G2 MEMORY: basis=%.1f MB  subdomain-ops=%.1f MB  process peak RSS=%.0f MB (baseline %.0f MB)\n",
                  tl.basis_mb, tl.subops_mb, peak_rss_bytes()/1048576.0, rss0);
      std::printf("   coarse: Nt=%d dense=%d cond=%.2e  nsub=%d tail=%d  LOBPCG iters med/max=%d/%d modes med/max=%d/%d\n",
                  tl.Nt,(int)tl.coarse_dense,tl.coarse_cond,tl.nsub,tl.tail_subs,tl.lob_iters_med,tl.lob_iters_max,tl.modes_med,tl.modes_max);
    }
  }
  if (csv) std::fclose(csv);
  return 0;
}

// ===================================================================================
// CONTROL (P4) — negative control FIRST: Jacobi-CG at tight vs tighter tolerance sets
// the solve-level basin floor; then two-level at tight vs Jacobi at tight must be
// within it. Reports max|du|/max|u| and printed-classification flips over solid voxels.
int mode_control(const std::string& dir) {
  DevelopedCase D = load_stag(dir);
  const VoxelGrid& g = D.grid;
  std::vector<double> rho = D.snaps.back();
  std::vector<double> ey; MatfreeReduced m = build_reduced(g, rho, D.bcs, D.loads, ey);
  MfSolveContext ctx; ctx.grid=&g; ctx.elem_youngs=&ey; ctx.youngs_modulus=kE0; ctx.poisson=kNu;
  auto solve = [&](double tol, TwoLevel* tl, std::vector<double>& x, int& it){ x.assign(m.ng,0.0);
    double e; bool c; fea_matfree_reset_mg_stagnation_latch();
    if (tl){ HookGuard hg(tl); mf_cg_solve(m,tol,0,x,it,e,c,nullptr,&ctx);} else mf_cg_solve(m,tol,0,x,it,e,c,nullptr,&ctx); };
  auto reldiff = [&](const std::vector<double>& a, const std::vector<double>& b){ double n=0,d=0;
    for (int i=0;i<m.ng;++i){ n=std::max(n,std::abs(a[i]-b[i])); d=std::max(d,std::abs(a[i])); } return d>0?n/d:0.0; };
  std::printf("## CONTROL (same-answer floor) grid %dx%dx%d ng=%d\n", g.nx,g.ny,g.nz,m.ng);
  std::vector<double> u_tight, u_tighter, u_2l; int i0,i1,i2;
  solve(1e-8, nullptr, u_tight, i0);
  solve(1e-9, nullptr, u_tighter, i1);
  const double floor = reldiff(u_tighter, u_tight);
  TwoLevel tl; tl.build(g, ey, m, cfg_from_env());
  solve(1e-8, &tl, u_2l, i2);
  const double twol = reldiff(u_2l, u_tight);
  std::printf("   NEG CONTROL (Jacobi 1e-9 vs 1e-8): max|du|/max|u| = %.3e   [%d vs %d it]  <-- basin floor\n", floor, i1, i0);
  std::printf("   TWO-LEVEL  (2L 1e-8 vs Jacobi 1e-8): max|du|/max|u| = %.3e   [%d vs %d it]\n", twol, i2, i0);
  std::printf("   => two-level solve field is within the basin floor: %s\n",
              (twol <= std::max(floor, 1e-7)*5.0)?"YES (same answer at the solve level)":"NO");
  return 0;
}

// ===================================================================================
// AMORT (P6) — reuse policy. Build the basis at state 0, then REUSE it for the next N
// consecutive design states vs REBUILDING it each state. Report iterations saved vs
// rebuild cost, and the coarse-subspace drift that would trigger a refresh.
int mode_amort(const std::string& dir) {
  FILE* csv = open_csv(dir, "amort.csv");
  if (csv) std::fprintf(csv,"state,ng,reused_cg,rebuilt_cg,jacobi_cg,build_s\n");
  DevelopedCase D = load_stag(dir);
  const VoxelGrid& g = D.grid;
  Developer dev; dev.init(g, D.bcs, D.loads, D.snaps.back(), D.vf);
  const TwoLevelCfg cfg = cfg_from_env();
  const int N = std::getenv("TL_GAP")?std::atoi(std::getenv("TL_GAP")):5;
  std::printf("## AMORT grid %dx%dx%d: reuse a state-0 basis over %d consecutive states\n", g.nx,g.ny,g.nz,N);
  std::vector<double> rho = dev.physical();
  std::vector<double> ey0; MatfreeReduced m0 = build_reduced(g, rho, D.bcs, D.loads, ey0);
  const double tb=now_ms(); TwoLevel tl0; tl0.build(g, ey0, m0, cfg); const double build0=(now_ms()-tb)/1e3;
  std::printf("   state-0 basis build=%.2f s  Nt=%d\n", build0, tl0.Nt);
  if (csv) { std::fclose(csv); csv = open_csv(dir, "amort.csv");
    std::fprintf(csv,"state,ng,jacobi_cg,rebuilt_cg,reused_cg,rebuild_s,refresh_s\n"); }
  std::printf("\n state  ng     Jacobi  rebuilt  reused   rebuild(s) refresh(s)\n");
  for (int s=0; s<=N; ++s) {
    if (s>0) rho = dev.step();
    std::vector<double> ey; MatfreeReduced m = build_reduced(g, rho, D.bcs, D.loads, ey);
    SolveResult jr = solve_reduced(m, kCertTol, 0, nullptr, g, ey);
    // REUSED: keep state-0's expensive LOBPCG basis, REFRESH only the cheap coarse
    // operator V^T A_s V for state s (N_t matvecs + a small dense factor).
    const double tr=now_ms(); tl0.refresh_coarse(m); const double refresh_s=(now_ms()-tr)/1e3;
    SolveResult rr = solve_reduced(m, kCertTol, 0, &tl0, g, ey);
    // REBUILT: a fresh basis (full LOBPCG) for state s.
    const double tb2=now_ms(); TwoLevel tls; tls.build(g, ey, m, cfg); const double bs=(now_ms()-tb2)/1e3;
    SolveResult fr = solve_reduced(m, kCertTol, 0, &tls, g, ey);
    std::printf("  %4d %6d %7d %7d %7d   %8.2f  %8.3f\n", s, m.ng, jr.iters, fr.iters, rr.iters, bs, refresh_s);
    if (csv) std::fprintf(csv,"%d,%d,%d,%d,%d,%.3f,%.4f\n", s,m.ng,jr.iters,fr.iters,rr.iters,bs,refresh_s);
  }
  std::printf("   READ: 'reused' keeps the state-0 LOBPCG basis, refreshing only the cheap coarse\n"
              "   operator (refresh << rebuild). If reused stays near rebuilt, the eigensolve\n"
              "   amortizes across design iterations — the Alexandersen-Lazarov property.\n");
  if (csv) std::fclose(csv);
  return 0;
}

// ===================================================================================
// HEALTHY (P7) — a rung where geometric multigrid CARRIES. Show the two-level route is
// SLOWER there than MG-CG (so arming it always would regress; conditional-on-stagnation
// arming is the right posture — which the hook's Jacobi-CG-only placement gives for free).
int mode_healthy(const std::string& dir) {
  (void)dir;
  // A near-solid, well-connected block: MG carries. Domain-filling cantilever.
  const int nx=32,ny=16,nz=32; VoxelGrid g; g.nx=nx; g.ny=ny; g.nz=nz; g.spacing=1.0; g.origin=Vec3{0,0,0};
  g.tags.assign((std::size_t)nx*ny*nz, VoxelTag::Interior);
  std::vector<DirichletBC> bcs; std::vector<NodalLoad> loads;
  for (int c=0;c<=nz;++c) for (int b=0;b<=ny;++b){ int nd=fea_node_index(g,0,b,c); bcs.push_back({nd,0,0.0}); bcs.push_back({nd,1,0.0}); bcs.push_back({nd,2,0.0}); }
  std::vector<int> tip; for (int b=0;b<=ny;++b) tip.push_back(fea_node_index(g,nx,b,0));
  for (int nd:tip) loads.push_back({nd,2,-100.0/tip.size()});
  std::vector<double> rho(g.voxel_count(), 0.6);
  std::vector<double> ey; MatfreeReduced m = build_reduced(g, rho, bcs, loads, ey);
  std::printf("## HEALTHY grid %dx%dx%d rho=0.6 (well-connected; MG carries)\n", nx,ny,nz);
  // MG-CG (production path)
  CgInfo info; fea_matfree_reset_mg_stagnation_latch();
  const double t0=now_ms(); FeaSolution sol = fea_solve_mgcg_matfree(g, ey, kNu, bcs, loads, kCertTol, 0, &info); (void)sol;
  std::printf("   MG-CG: used_multigrid=%d cycles=%d  wall=%.2f s\n", info.used_multigrid, info.iterations, (now_ms()-t0)/1e3);
  // Jacobi-CG and two-level (on the same operator)
  SolveResult jr = solve_reduced(m, kCertTol, 0, nullptr, g, ey);
  TwoLevel tl; tl.build(g, ey, m, cfg_from_env());
  SolveResult tr = solve_reduced(m, kCertTol, 0, &tl, g, ey);
  std::printf("   Jacobi-CG: %d it (%.2f s)   two-level: %d it (%.2f s, +%.2fs build, Nt=%d)\n",
              jr.iters, jr.wall_ms/1e3, tr.iters, tr.wall_ms/1e3, tl.build_ms/1e3, tl.Nt);
  std::printf("   READ: where MG carries (%d cycles), the two-level Jacobi-regime route is far more\n"
              "   expensive than the V-cycle — so it must be armed ONLY on stagnation (the hook lives\n"
              "   on the Jacobi-CG fallback, so healthy rungs never invoke it).\n", info.iterations);
  return 0;
}

// ===================================================================================
// DET (P8) — determinism: build+solve twice, require identical CG iters and FNV.
int mode_det(const std::string& dir) {
  DevelopedCase D = load_stag(dir);
  const VoxelGrid& g = D.grid; std::vector<double> ey; MatfreeReduced m = build_reduced(g, D.snaps.back(), D.bcs, D.loads, ey);
  auto run = [&](std::uint64_t& hh, int& iters){ TwoLevel tl; tl.build(g, ey, m, cfg_from_env());
    std::vector<double> x(m.ng,0.0); int it; double e; bool c;
    MfSolveContext ctx; ctx.grid=&g; ctx.elem_youngs=&ey; ctx.youngs_modulus=kE0; ctx.poisson=kNu;
    fea_matfree_reset_mg_stagnation_latch();
    { HookGuard hg(&tl); mf_cg_solve(m,kCertTol,0,x,it,e,c,nullptr,&ctx); }
    Fnv f; for (double v:x) f.add_d(v); hh=f.h; iters=it; };
  std::uint64_t h1,h2; int i1,i2; run(h1,i1); run(h2,i2);
  std::printf("## DET grid %dx%dx%d ng=%d\n", g.nx,g.ny,g.nz,m.ng);
  std::printf("   run1: iters=%d fnv=%016llx\n   run2: iters=%d fnv=%016llx\n", i1,(unsigned long long)h1,i2,(unsigned long long)h2);
  const bool ok = (i1==i2)&&(h1==h2);
  std::printf("   => %s\n", ok?"DETERMINISTIC (identical)":"NON-DETERMINISTIC (FAIL)");
  return ok?0:1;
}

// ===================================================================================
// BYTEID (P1) — the production library is byte-identical with the hook off. Runs the
// full production ladder twice with NO hook installed and hashes densities/compliance/
// margins/accepts; asserts the hook is never installed. (The cross-build comparison to
// a stashed pre-change binary is driven by the reproduce script; this proves the
// in-process default-off invariant + run determinism.)
int mode_byteid(const std::string& dir) {
  (void)dir;
  const FixtureSpec s{16,16,4,4,1.0,0.30,8};
  std::vector<DirichletBC> pbcs;
  VoxelGrid part = l_bracket(pbcs, s.arm,s.span,s.ny,s.t,s.h,0.0);
  const std::vector<NodalLoad> ploads = traction_loads(part, VoxelTag::Load, Vec3{0,0,-30});
  const DesignBox box = stagnation_box(s.arm,s.span,s.ny,s.t,s.h);
  auto run_hash = [&](){ MinimizePlasticOptions o; configure_production_options(o);
    o.volume_fraction_ladder={s.vf,s.vf*0.7}; o.margin_stop=0.0; o.external_loads=ploads;
    o.gravity=0.0; o.gravity_direction=Vec3{0,0,-1}; o.infill_percent=100.0; o.design_box=box;
    o.freeze_imported_part=false; o.simp.max_iterations=s.iters;
    SettingsRules rules = load_settings_rules_file(SETTINGS_RULES_PATH); const Material mat=fdm_material();
    fea_set_krylov_recycling(false); fea_reset_krylov_recycle_space();
    MinimizePlasticResult r = minimize_plastic(part, mat, "fdm", pbcs, rules, o);
    Fnv f; for (const auto& v : r.evaluated){ for (double d : v.optimization.physical_density) f.add_d(d);
      f.add_d(v.optimization.compliance); f.add_d(v.report.margin.worst_case); f.add_d(v.report.margin_effective);
      f.add_i(v.accepted?1:0); } return std::make_pair(f.h, r.evaluated.size()); };
  std::printf("## BYTEID full production ladder, hook OFF (P1)\n");
  const bool inst_before = fea_detail::mf_precond_hook_installed();
  auto [h1,n1] = run_hash();
  auto [h2,n2] = run_hash();
  const bool inst_after = fea_detail::mf_precond_hook_installed();
  std::printf("   hook installed: before=%d after=%d (must be 0/0)\n", inst_before, inst_after);
  std::printf("   run1: rungs=%zu fnv=%016llx\n   run2: rungs=%zu fnv=%016llx\n",
              n1,(unsigned long long)h1,n2,(unsigned long long)h2);
  const bool ok = (h1==h2)&&(n1==n2)&&!inst_before&&!inst_after;
  std::printf("   => %s (write this fnv to evidence; compare against a stashed pre-change build)\n",
              ok?"DETERMINISTIC + HOOK OFF":"FAIL");
  return ok?0:1;
}

// ===================================================================================
// HARD — a CONTROLLED scalability sweep on a synthetic MANY-near-disconnection
// high-contrast system (a 3D checkerboard of solid cells joined only at shared
// nodes — the Jonsthovel et al. high-contrast composite). The number of near-null
// modes grows with the grid, so Jacobi-CG's iteration count blows up while the
// two-level's stays bounded (contrast/mode-count independence). No slow develop —
// this isolates the preconditioner's scaling from the field-generation cost.
VoxelGrid checker_system(int n, int cs, std::vector<DirichletBC>& bcs,
                         std::vector<NodalLoad>& loads, std::vector<double>& rho) {
  VoxelGrid g; g.nx=n; g.ny=n; g.nz=n; g.spacing=1.0; g.origin=Vec3{0,0,0};
  g.tags.assign((std::size_t)n*n*n, VoxelTag::Interior);
  bcs.clear(); loads.clear();
  for (int c=0;c<=n;++c) for (int b=0;b<=n;++b){ int nd=fea_node_index(g,0,b,c); bcs.push_back({nd,0,0.0}); bcs.push_back({nd,1,0.0}); bcs.push_back({nd,2,0.0}); }
  for (int b=0;b<=n;++b) for (int c=0;c<=n;++c) loads.push_back({fea_node_index(g,n,b,c),2,-100.0/((n+1.0)*(n+1.0))});
  rho.assign((std::size_t)n*n*n, 1.0);
  for (int k=0;k<n;++k) for (int j=0;j<n;++j) for (int i=0;i<n;++i){
    const int I=i/cs, J=j/cs, K=k/cs;
    if (((I+J+K)&1)!=0) rho[g.index(i,j,k)] = kRhoMinProd;   // near-void cell
  }
  // keep the fixed and loaded faces solid so the load path exists
  for (int b=0;b<n;++b) for (int c=0;c<n;++c){ rho[g.index(0,b,c)]=1.0; rho[g.index(n-1,b,c)]=1.0; }
  return g;
}
int mode_hard(const std::string& dir) {
  FILE* csv = open_csv(dir, "hard_scaling.csv");
  if (csv) std::fprintf(csv,"n,ng,jacobi_cg,twolevel_cg,ratio,Nt,build_s,jac_s,tl_s,cond\n");
  const int cs = std::getenv("TL_CELL")?std::atoi(std::getenv("TL_CELL")):4;
  const int cap = std::getenv("TL_MAXIT")?std::atoi(std::getenv("TL_MAXIT")):200000;
  std::printf("## HARD checkerboard high-contrast composite, cell=%d, contrast 1e9\n", cs);
  std::printf("\n   n     ng     Jacobi-CG   two-level   ratio    Nt   build(s) jac(s) tl(s)  cond\n");
  std::vector<int> sizes = {16,24,32,40};
  if (std::getenv("TL_SIZES")) { sizes.clear(); char* p=std::getenv("TL_SIZES"); for (char* t=std::strtok(p,",");t;t=std::strtok(nullptr,",")) sizes.push_back(std::atoi(t)); }
  for (int n : sizes) {
    std::vector<DirichletBC> bcs; std::vector<NodalLoad> loads; std::vector<double> rho;
    VoxelGrid g = checker_system(n, cs, bcs, loads, rho);
    std::vector<double> ey; MatfreeReduced m = build_reduced(g, rho, bcs, loads, ey);
    SolveResult jr = solve_reduced(m, kCertTol, cap, nullptr, g, ey);
    const double tb=now_ms(); TwoLevel tl; tl.build(g, ey, m, cfg_from_env()); const double bs=(now_ms()-tb)/1e3;
    SolveResult tr = solve_reduced(m, kCertTol, cap, &tl, g, ey);
    const double ratio = tr.iters>0?(double)jr.iters/tr.iters:0.0;
    std::printf("  %3d %7d   %8d   %8d   %5.1fx  %4d  %7.2f %6.1f %6.1f  %.1e\n",
                n, m.ng, jr.iters, tr.iters, ratio, tl.Nt, bs, jr.wall_ms/1e3, tr.wall_ms/1e3, tl.coarse_cond);
    if (csv) std::fprintf(csv,"%d,%d,%d,%d,%.2f,%d,%.2f,%.2f,%.2f,%.3e\n",n,m.ng,jr.iters,tr.iters,ratio,tl.Nt,bs,jr.wall_ms/1e3,tr.wall_ms/1e3,tl.coarse_cond);
  }
  std::printf("   READ: if the Jacobi column grows faster than the two-level column as n grows,\n"
              "   the two-level route is mode-count/contrast independent — the GenEO promise.\n");
  if (csv) std::fclose(csv);
  return 0;
}

// ===================================================================================
// P4-DESIGN — run the FULL production ladder twice (stock vs two-level-armed) and report
// the DESIGN difference as the fraction of solid voxels flipping printed-classification,
// with grid dims + solid count, plus per-rung compliance/margin/accept. A provider hook
// builds the two-level ONCE per solve (fingerprint-cached on the moduli) so the whole
// optimization runs on the two-level solver wherever it stagnates to Jacobi-CG.
struct ProviderHook {
  TwoLevelCfg cfg; TwoLevel tl; std::uint64_t fp=0; bool have=false; long long builds=0;
  static std::uint64_t fingerprint(const MatfreeReduced& m, const MfSolveContext& ctx) {
    Fnv f; f.add_i(m.ng);
    const auto& e = *ctx.elem_youngs;
    for (std::size_t i=0;i<e.size(); i += 997) f.add_d(e[i]);   // strided sample
    return f.h;
  }
  void operator()(const MatfreeReduced& m, const MfSolveContext& ctx, const double* r, double* z) {
    const std::uint64_t h = fingerprint(m, ctx);
    if (!have || h!=fp) { tl.build(*ctx.grid, *ctx.elem_youngs, m, cfg); fp=h; have=true; ++builds; }
    tl.apply(r, z);
  }
};

int mode_p4(const std::string& dir) {
  const FixtureSpec s = fixture_from_env();
  std::vector<DirichletBC> pbcs;
  VoxelGrid part = l_bracket(pbcs, s.arm,s.span,s.ny,s.t,s.h,0.0);
  const std::vector<NodalLoad> ploads = traction_loads(part, VoxelTag::Load, Vec3{0,0,-30});
  const DesignBox box = stagnation_box(s.arm,s.span,s.ny,s.t,s.h);
  auto run = [&](double tol, ProviderHook* prov, MinimizePlasticResult& r){
    MinimizePlasticOptions o; configure_production_options(o);
    o.volume_fraction_ladder={s.vf}; o.margin_stop=0.0; o.external_loads=ploads;
    o.gravity=0.0; o.gravity_direction=Vec3{0,0,-1}; o.infill_percent=100.0; o.design_box=box;
    o.freeze_imported_part=false; o.simp.max_iterations=s.iters; o.simp.cg_tolerance=tol;
    SettingsRules rules = load_settings_rules_file(SETTINGS_RULES_PATH); const Material mat=fdm_material();
    fea_set_krylov_recycling(false); fea_reset_krylov_recycle_space();
    MfPrecondHook prev;
    if (prov) prev = fea_detail::mf_set_precond_hook([prov](const MatfreeReduced& m, const MfSolveContext& c, const double* rr, double* zz){ (*prov)(m,c,rr,zz); });
    r = minimize_plastic(part, mat, "fdm", pbcs, rules, o);
    if (prov) fea_detail::mf_set_precond_hook(prev);
  };
  std::printf("## P4-DESIGN full ladder stock vs two-level, fixture arm=%d span=%d ny=%d t=%d vf=%.2f iters=%d\n",
              s.arm,s.span,s.ny,s.t,s.vf,s.iters);
  MinimizePlasticResult ra, rb, rc; ProviderHook prov; prov.cfg = cfg_from_env();
  const double t0=now_ms(); run(kCertTol, nullptr, ra);      std::printf("   stock (Jacobi/MG) done %.1fs\n",(now_ms()-t0)/1e3);
  const double t1=now_ms(); run(kCertTol, &prov, rb);         std::printf("   two-level armed done %.1fs (%lld basis builds)\n",(now_ms()-t1)/1e3, prov.builds);
  const double t2=now_ms(); run(kCertTol*0.1, nullptr, rc);   std::printf("   neg control (tol 1e-9) done %.1fs\n",(now_ms()-t2)/1e3);
  const VoxelGrid& g = ra.solved_grid;
  std::printf("\n rung  grid          solid    flips(2L vs stock)   flips(1e-9 vs stock=floor)  gate(stock/2L)\n");
  for (std::size_t i=0;i<ra.evaluated.size() && i<rb.evaluated.size() && i<rc.evaluated.size(); ++i) {
    const auto& va=ra.evaluated[i]; const auto& vb=rb.evaluated[i]; const auto& vc=rc.evaluated[i];
    long long solid=0, fab=0, fac=0;
    const double fr_ab = class_flip_fraction(g, va.optimization.physical_density, vb.optimization.physical_density, solid, fab);
    const double fr_ac = class_flip_fraction(g, va.optimization.physical_density, vc.optimization.physical_density, solid, fac);
    std::printf("  %3zu  %2dx%2dx%2d   %7lld   %.3e (%lld)      %.3e (%lld)          %d/%d\n",
                i, g.nx,g.ny,g.nz, solid, fr_ab, fab, fr_ac, fac, (int)va.accepted, (int)vb.accepted);
    std::printf("       compliance stock=%.6e 2L=%.6e  margin stock=%.4f 2L=%.4f\n",
                va.optimization.compliance, vb.optimization.compliance, va.report.margin.worst_case, vb.report.margin.worst_case);
  }
  std::printf("   READ: two-level-vs-stock voxel flips must be <= the neg-control (1e-9-vs-1e-8) floor,\n"
              "   and gate verdicts identical — the two-level solver yields the SAME certified design.\n");
  (void)dir; return 0;
}

int geneo_tl_dispatch(const std::string& mode, const std::string& dir) {
  if (mode=="selfcheck") return mode_selfcheck(dir);
  if (mode=="hard")      return mode_hard(dir);
  if (mode=="p4design")  return mode_p4(dir);
  if (mode=="p2")        return mode_p2(dir);
  if (mode=="control")   return mode_control(dir);
  if (mode=="amort")     return mode_amort(dir);
  if (mode=="healthy")   return mode_healthy(dir);
  if (mode=="det")       return mode_det(dir);
  if (mode=="byteid")    return mode_byteid(dir);
  std::printf("usage: geneo_twolevel_probe <selfcheck|stag|p2|control|amort|healthy|det|byteid> [csvdir]\n");
  return 2;
}

}  // namespace
