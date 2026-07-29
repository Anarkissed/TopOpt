// geneo_twolevel_probe_part2.inc — included at the end of geneo_twolevel_probe.cpp.
// Fixture + extraction + the two-level preconditioner + the measurement modes.

namespace {

Material fdm_material() {
  Material m;
  m.youngs_modulus_mpa = kE0; m.yield_strength_mpa = 55.0; m.density_g_cm3 = 1.24;
  m.z_knockdown = 0.55; m.poisson = kNu; m.family = "fdm";
  return m;
}

// L-bracket-in-a-design-box, the canonical stagnation fixture (== deflation_probe /
// draft_arming_gate): a thin part in a box drawn ~2x its bbox so the analysis grid is
// void-heavy and the high-contrast multigrid falls to Jacobi-CG. `hole_frac` removes a
// cylindrical clearance hole (hard Empty) — the 125 near-disconnection ingredient.
VoxelGrid l_bracket(std::vector<DirichletBC>& bcs, int arm, int span, int ny, int t,
                    double h, double hole_frac) {
  VoxelGrid g;
  g.nx = span; g.ny = ny; g.nz = arm; g.spacing = h; g.origin = Vec3{0,0,0};
  g.tags.assign(static_cast<std::size_t>(span) * ny * arm, VoxelTag::Empty);
  const double cz = arm * 0.55, cy = ny * 0.5, rr = hole_frac * arm;
  for (int k = 0; k < arm; ++k)
    for (int j = 0; j < ny; ++j)
      for (int i = 0; i < span; ++i) {
        if (!(i < t || k < t)) continue;         // L shape
        if (rr > 0) { const double dz=k+0.5-cz, dy=j+0.5-cy; if (std::sqrt(dz*dz+dy*dy) < rr) continue; }
        g.set_tag(i, j, k, VoxelTag::Interior);
      }
  auto solid = [&](int i,int j,int k){ if(i<0||j<0||k<0||i>=span||j>=ny||k>=arm) return false; return g.tag(i,j,k)!=VoxelTag::Empty; };
  for (int k=0;k<arm;++k) for (int j=0;j<ny;++j) for (int i=0;i<span;++i){ if(!solid(i,j,k))continue;
    if(!solid(i-1,j,k)||!solid(i+1,j,k)||!solid(i,j-1,k)||!solid(i,j+1,k)||!solid(i,j,k-1)||!solid(i,j,k+1)) g.set_tag(i,j,k,VoxelTag::Surface); }
  for (int j=0;j<ny;++j) for (int i=0;i<t;++i) g.set_tag(i,j,arm-1,VoxelTag::Fixture);
  bcs.clear();
  for (int b=0;b<=ny;++b) for (int a=0;a<=t;++a){ const int n=fea_node_index(g,a,b,arm);
    bcs.push_back({n,0,0.0}); bcs.push_back({n,1,0.0}); bcs.push_back({n,2,0.0}); }
  for (int k=0;k<t;++k) for (int j=0;j<ny;++j) g.set_tag(span-1,j,k,VoxelTag::Load);
  return g;
}

// Reconstruct BCs/loads on the (expanded) solved grid from its stamped tags.
void bcs_loads_from_tags(const VoxelGrid& g, std::vector<DirichletBC>& bcs,
                         std::vector<NodalLoad>& loads, const Vec3& traction) {
  bcs.clear();
  std::vector<char> pinned(static_cast<std::size_t>(fea_node_count(g)), 0);
  for (int k=0;k<g.nz;++k) for (int j=0;j<g.ny;++j) for (int i=0;i<g.nx;++i){
    if (g.tag(i,j,k)!=VoxelTag::Fixture) continue;
    for (int dk=0;dk<=1;++dk) for (int dj=0;dj<=1;++dj) for (int di=0;di<=1;++di){
      const int node=fea_node_index(g,i+di,j+dj,k+dk); if(pinned[node])continue; pinned[node]=1;
      bcs.push_back({node,0,0.0}); bcs.push_back({node,1,0.0}); bcs.push_back({node,2,0.0}); } }
  loads = traction_loads(g, VoxelTag::Load, traction);
}

std::vector<double> penalized_youngs(const VoxelGrid& g, const std::vector<double>& density) {
  std::vector<double> y(g.voxel_count(), 0.0);
  for (int k=0;k<g.nz;++k) for (int j=0;j<g.ny;++j) for (int i=0;i<g.nx;++i){
    if(!g.solid(i,j,k))continue; const std::size_t e=g.index(i,j,k);
    const double rho=std::min(1.0,std::max(kRhoMinProd,density[e])); y[e]=std::pow(rho,kSimpP)*kE0; }
  return y;
}

// Fraction of solid voxels whose PRINTED classification (rho > iso) differs between
// two density fields (P4 metric).
double class_flip_fraction(const VoxelGrid& g, const std::vector<double>& a,
                           const std::vector<double>& b, long long& solid_out, long long& flips_out) {
  long long solid=0, flips=0;
  for (int k=0;k<g.nz;++k) for (int j=0;j<g.ny;++j) for (int i=0;i<g.nx;++i){
    if(!g.solid(i,j,k))continue; const std::size_t e=g.index(i,j,k); ++solid;
    if ((a[e]>kIso) != (b[e]>kIso)) ++flips; }
  solid_out=solid; flips_out=flips; return solid? (double)flips/solid : 0.0;
}

// ---------------------------------------------------------------------------
// A developed stagnating field: build the expanded (design-box) grid via the
// production solved-grid helper, then develop it with the production OC recipe.
// Snapshots every iteration are kept for the per-iteration (P2) and amortization
// (P6) measurements. The field is cached to disk (keyed by dims+vf+iters).
// ---------------------------------------------------------------------------
struct DevelopedCase {
  VoxelGrid grid;
  std::vector<DirichletBC> bcs;
  std::vector<NodalLoad> loads;
  std::vector<std::vector<double>> snaps;   // physical density per OC iteration
  double vf = 0.0;
};

// The make_big_stagnation-style DILUTE, PADDED design box (48x32x48 for the canonical
// arm=span=24, ny=6, h=1 fixture): the void-heavy surround whose high-contrast
// multigrid falls to Jacobi-CG (handoff 125/168). Scales with the part.
DesignBox stagnation_box(int arm, int span, int ny, int /*t*/, double h) {
  DesignBox box;
  box.min = Vec3{-span*h*0.5, -arm*h*0.54, -arm*h*0.5};
  box.max = Vec3{ span*h*1.5, ny*h + arm*h*0.54, arm*h*1.5};
  return box;
}

DevelopedCase develop_case(int arm, int span, int ny, int t, double h, double hole_frac,
                           double vf, int iters, const Vec3& traction, const DesignBox& box) {
  DevelopedCase D; D.vf = vf;
  std::vector<DirichletBC> pbcs;
  VoxelGrid part = l_bracket(pbcs, arm, span, ny, t, h, hole_frac);
  const std::vector<NodalLoad> ploads = traction_loads(part, VoxelTag::Load, traction);
  // Expand onto the design box exactly as the production ladder does (same overload,
  // kDesignBoxCoarsenAlign=8) and REMAP the part BCs/loads by node offset — the
  // pipeline's own remap, not a tag re-scan (the expanded grid buries the load face).
  // freeze=false makes the whole padded box one Active designable domain, so the OC
  // develop produces the thin, dilute structure whose high-contrast MG stagnates.
  DesignDomain domain = expand_design_domain(part, box, {}, /*freeze_part=*/false,
                                             kDesignBoxCoarsenAlign);
  D.grid = domain.grid;
  D.bcs.clear();
  for (const DirichletBC& b : pbcs)
    D.bcs.push_back({remap_node_to_domain(part, domain, b.node), b.component, b.value});
  D.loads.clear();
  for (const NodalLoad& l : ploads)
    D.loads.push_back({remap_node_to_domain(part, domain, l.node), l.component, l.value});

  const VoxelGrid& g = D.grid;
  SimpParams params; params.youngs_modulus=kE0; params.poisson=kNu;
  params.penalty=(double)kSimpP; params.density_min=kRhoMinProd;
  const DensityFilter f = make_density_filter(g, physical_filter_radius(2.5, g.spacing));
  std::vector<double> x = simp_uniform_density(g, vf);
  fea_matfree_reset_mg_stagnation_latch();
  for (int it=0; it<iters; ++it) {
    const std::vector<double> xp = f.filter_density(x);
    const SimpCompliance c = simp_compliance(g, params, xp, D.bcs, D.loads, kCertTol, 0,
                                             nullptr, nullptr, SolverKind::MultigridCG_Matfree);
    x = oc_update(g, f, x, c.dcompliance, vf, 0.2, kRhoMinProd);
    D.snaps.push_back(f.filter_density(x));
  }
  return D;
}

// ---------------------------------------------------------------------------
// Develop a stagnating field through the REAL production ladder (minimize_plastic):
// the min-feature filter + Heaviside projection create the thin, near-disconnecting
// members whose high-contrast multigrid stagnates (the field a bare OC does not
// produce). Cached to disk so the (expensive) development is paid once.
// ---------------------------------------------------------------------------
bool cache_load(const std::string& path, VoxelGrid& g, std::vector<double>& rho,
                std::vector<DirichletBC>& bcs, std::vector<NodalLoad>& loads) {
  FILE* f = std::fopen(path.c_str(), "rb"); if (!f) return false;
  int dims[3]; double sp; std::size_t nrho, nb, nl;
  bool ok = std::fread(dims,sizeof(int),3,f)==3 && std::fread(&sp,sizeof(double),1,f)==1;
  g.nx=dims[0]; g.ny=dims[1]; g.nz=dims[2]; g.spacing=sp; g.origin=Vec3{0,0,0};
  g.tags.resize(static_cast<std::size_t>(dims[0])*dims[1]*dims[2]);
  ok = ok && std::fread(g.tags.data(),sizeof(VoxelTag),g.tags.size(),f)==g.tags.size();
  ok = ok && std::fread(&nrho,sizeof nrho,1,f)==1; rho.resize(nrho);
  ok = ok && std::fread(rho.data(),sizeof(double),nrho,f)==nrho;
  ok = ok && std::fread(&nb,sizeof nb,1,f)==1; bcs.resize(nb);
  ok = ok && std::fread(bcs.data(),sizeof(DirichletBC),nb,f)==nb;
  ok = ok && std::fread(&nl,sizeof nl,1,f)==1; loads.resize(nl);
  ok = ok && std::fread(loads.data(),sizeof(NodalLoad),nl,f)==nl;
  std::fclose(f); return ok;
}
void cache_save(const std::string& path, const VoxelGrid& g, const std::vector<double>& rho,
                const std::vector<DirichletBC>& bcs, const std::vector<NodalLoad>& loads) {
  FILE* f = std::fopen(path.c_str(), "wb"); if (!f) return;
  int dims[3]={g.nx,g.ny,g.nz}; double sp=g.spacing; std::size_t nrho=rho.size(),nb=bcs.size(),nl=loads.size();
  std::fwrite(dims,sizeof(int),3,f); std::fwrite(&sp,sizeof(double),1,f);
  std::fwrite(g.tags.data(),sizeof(VoxelTag),g.tags.size(),f);
  std::fwrite(&nrho,sizeof nrho,1,f); std::fwrite(rho.data(),sizeof(double),nrho,f);
  std::fwrite(&nb,sizeof nb,1,f); std::fwrite(bcs.data(),sizeof(DirichletBC),nb,f);
  std::fwrite(&nl,sizeof nl,1,f); std::fwrite(loads.data(),sizeof(NodalLoad),nl,f);
  std::fclose(f);
}

DevelopedCase develop_pipeline(int arm, int span, int ny, int t, double h, double vf,
                               int max_iters, const Vec3& traction, const DesignBox& box,
                               const std::string& cache_path) {
  DevelopedCase D; D.vf = vf;
  std::vector<DirichletBC> pbcs;
  VoxelGrid part = l_bracket(pbcs, arm, span, ny, t, h, 0.0);
  const std::vector<NodalLoad> ploads = traction_loads(part, VoxelTag::Load, traction);
  DesignDomain domain = expand_design_domain(part, box, {}, /*freeze_part=*/false, kDesignBoxCoarsenAlign);
  D.grid = domain.grid;
  for (const DirichletBC& b : pbcs) D.bcs.push_back({remap_node_to_domain(part,domain,b.node), b.component, b.value});
  for (const NodalLoad& l : ploads) D.loads.push_back({remap_node_to_domain(part,domain,l.node), l.component, l.value});

  std::vector<double> rho;
  if (!cache_path.empty()) {
    VoxelGrid cg; std::vector<DirichletBC> cb; std::vector<NodalLoad> cl;
    if (cache_load(cache_path, cg, rho, cb, cl) && rho.size()==D.grid.voxel_count()) {
      std::printf("   [cache hit %s]\n", cache_path.c_str());
      D.snaps.push_back(rho); return D;
    }
  }
  MinimizePlasticOptions o; configure_production_options(o);
  o.volume_fraction_ladder = {vf}; o.margin_stop = 0.0;
  o.external_loads = ploads;  // pipeline remaps part-indexed loads itself
  o.gravity = 0.0; o.gravity_direction = Vec3{0,0,-1}; o.infill_percent = 100.0;
  o.design_box = box; o.freeze_imported_part = false;
  o.simp.max_iterations = max_iters; o.simp.mma_plateau_window = 0; o.simp.change_tol = 0.0;
  SettingsRules rules = load_settings_rules_file(SETTINGS_RULES_PATH);
  const Material material = fdm_material();
  fea_set_krylov_recycling(false); fea_reset_krylov_recycle_space();
  MinimizePlasticResult r = minimize_plastic(part, material, "fdm", pbcs, rules, o);
  D.grid = r.solved_grid;
  if (!r.evaluated.empty() && r.evaluated.back().optimization.physical_density.size()==D.grid.voxel_count())
    rho = r.evaluated.back().optimization.physical_density;
  else rho.assign(D.grid.voxel_count(), vf);
  D.snaps.push_back(rho);
  if (!cache_path.empty()) cache_save(cache_path, D.grid, rho, D.bcs, D.loads);
  return D;
}

// ======================================================================================
// THE TWO-LEVEL PRECONDITIONER (task piece 4)
// ======================================================================================
enum class LocalSolveKind { Jacobi, InnerCG };
struct TwoLevelCfg {
  int core = 8, ov = 1, block_m = 20;
  double lambda_cut = 0.05;
  LocalSolveKind local = LocalSolveKind::Jacobi;
  int local_iters = 4;          // Jacobi sweeps OR inner-CG iterations
  double jacobi_omega = 0.6;
  int tail_inner_cg = 0;        // if >0: subdomains whose LOBPCG kept>=tail_kept get inner-CG w/ this cap
  int tail_kept = 3;
  int coarse_dense_cap = 6000;  // dense-factor V^T A V below this; inner-CG above
  int coarse_inner_iters = 40;  // inner-CG coarse solve cap (large N_t / production extents)
  bool with_coarse = true;      // additive coarse (GenEO deflation) term — the winner
  bool with_local = false;      // additive local Schwarz term — measured USELESS with
                                // inexact local solves (see handoff §local-term); OFF by default
};

// A coarse column stored sparsely in KEPT-DOF (reduced) coordinates.
struct CoarseCol { std::vector<int> idx; std::vector<double> val; };
// A resident subdomain solver: its LocalOp + the active-DOF <-> kept-DOF map.
struct SubSolver {
  LocalOp L;
  std::vector<int> loc_of_active;   // active index -> local DOF
  std::vector<int> kept_of_active;  // active index -> reduced kept DOF
  int nact = 0;
  int kept_modes = 0;               // #LOBPCG modes < cut (tail flag)
};

class TwoLevel {
 public:
  TwoLevelCfg cfg;
  // telemetry
  int nsub = 0, Nt = 0, ng = 0;
  long long fine_dof = 0;
  double build_ms = 0, basis_mb = 0, subops_mb = 0, coarse_assemble_ms = 0, coarse_factor_ms = 0;
  double coarse_cond = 0; bool coarse_dense = false; int coarse_dim = 0;
  int lob_iters_med = 0, lob_iters_max = 0, tail_subs = 0;
  int modes_med = 0, modes_max = 0;
  long long apply_calls = 0;
  double peak_build_rss_mb = 0;

  void build(const VoxelGrid& g, const std::vector<double>& emod, const MatfreeReduced& m,
             const TwoLevelCfg& c) {
    cfg = c; ng = m.ng; fine_dof = 3LL*fea_node_count(g);
    const double t0 = now_ms();
    K0_ = unit_k0(g.spacing);
    // global DOF -> kept index
    kept_of_gdof_.assign(static_cast<std::size_t>(3*fea_node_count(g)), -1);
    for (int kg=0; kg<m.ng; ++kg) kept_of_gdof_[static_cast<std::size_t>(m.kept_global[kg])] = kg;
    // The local operator is the reduced operator RESTRICTED to each agglomerate: a DOF
    // is eliminated iff it is not KEPT (i.e. Dirichlet-fixed OR void-gated), exactly the
    // set the reduced system drops. So each subdomain solve inherits the same Dirichlet
    // boundary as the global operator (classical additive Schwarz A_i = R_i A R_i^T) AND
    // drops the near-singular void DOFs — no bcs list needed, and this is derivable from
    // `m` alone, which lets a provider hook rebuild from the reduced system in-flight.
    std::vector<char> fixed(kept_of_gdof_.size(), 0);
    for (std::size_t gd=0; gd<kept_of_gdof_.size(); ++gd) if (kept_of_gdof_[gd] < 0) fixed[gd] = 1;

    const std::vector<Block> cores = tile_cores(g, cfg.core);
    const std::vector<double> W = build_pou_normaliser(g, cores, cfg.ov);
    nsub = static_cast<int>(cores.size());
    subs_.clear(); cols_.clear();
    // Each subdomain is INDEPENDENT (embarrassingly parallel, Phase-1 §G4): build its
    // LocalOp + capture-LOBPCG basis across threads into per-subdomain outputs, then
    // MERGE in fixed core order (deterministic: coarse-column order + subdomain order
    // are independent of thread scheduling).
    struct SubBuild { SubSolver S; std::vector<CoarseCol> cols; int iters=0, kept=0; long long bytes=0; bool ok=false; };
    std::vector<SubBuild> built(cores.size());
    std::atomic<std::size_t> next{0};
    const unsigned nth = std::max(1u, std::thread::hardware_concurrency());
    auto bworker = [&](){ for(;;){ const std::size_t si = next.fetch_add(1); if (si>=cores.size()) break;
      LocalOp L = build_local(g, emod, cores[si], cfg.ov, K0_, fixed, W);
      if (L.n < 24) continue;
      StopSpec stop; stop.lambda_cut = cfg.lambda_cut; stop.maxiter = 800;
      const int mm = std::min(cfg.block_m, L.n);
      LobpcgResult lob = lobpcg(L, mm, stop, 20260729u + static_cast<unsigned>(si));
      const int kept = count_below(lob.lambda, cfg.lambda_cut);
      SubBuild& b = built[si]; b.ok=true; b.iters=lob.iters; b.kept=kept;
      for (int cc=0; cc<kept; ++cc) { CoarseCol col;
        for (int d=0; d<L.n; ++d) { const int kgi = kept_of_gdof_[static_cast<std::size_t>(L.gdof[d])];
          if (kgi < 0) continue; col.idx.push_back(kgi); col.val.push_back(L.D[d]*lob.V(d,cc)); }
        if (!col.idx.empty()) b.cols.push_back(std::move(col)); }
      SubSolver& S = b.S; S.kept_modes = kept;
      for (int d=0; d<L.n; ++d) { const int kgi = kept_of_gdof_[static_cast<std::size_t>(L.gdof[d])];
        if (kgi < 0) continue; S.loc_of_active.push_back(d); S.kept_of_active.push_back(kgi); }
      S.nact = static_cast<int>(S.loc_of_active.size());
      b.bytes = L.bytes(); S.L = std::move(L);
    } };
    { std::vector<std::thread> pool; for (unsigned tI=0;tI<nth;++tI) pool.emplace_back(bworker);
      for (auto& th:pool) th.join(); }
    std::vector<int> lob_iters, modes;
    long long subbytes = 0, basisbytes = 0;
    for (std::size_t si=0; si<cores.size(); ++si) { SubBuild& b = built[si]; if (!b.ok) continue;
      lob_iters.push_back(b.iters); modes.push_back(b.kept);
      for (auto& col : b.cols) { basisbytes += (long long)col.idx.size()*(4+8); cols_.push_back(std::move(col)); }
      subbytes += b.bytes; if (b.kept >= cfg.tail_kept) ++tail_subs;
      subs_.push_back(std::move(b.S));
    }
    Nt = static_cast<int>(cols_.size());
    auto med=[&](std::vector<int> v){ if(v.empty())return 0; std::sort(v.begin(),v.end()); return v[v.size()/2]; };
    auto mx=[&](const std::vector<int>&v){ int r=0; for(int x:v)r=std::max(r,x); return r; };
    lob_iters_med=med(lob_iters); lob_iters_max=mx(lob_iters);
    modes_med=med(modes); modes_max=mx(modes);
    basis_mb = basisbytes/1048576.0; subops_mb = subbytes/1048576.0;

    build_coarse_operator(m);
    // scratch
    ccoarse_.assign(static_cast<std::size_t>(Nt), 0.0);
    build_ms = now_ms() - t0;
    peak_build_rss_mb = peak_rss_bytes()/1048576.0;
  }

  // Amortization (P6): REUSE this basis' expensive LOBPCG columns but REFRESH the cheap
  // coarse operator V^T A' V against a NEW system's operator `mprime` (N_t global matvecs
  // + a dense factor). The stale basis stays a valid deflation space for the perturbed
  // system; only the small coarse operator must track A' to stay consistent (an OLD
  // coarse operator applied to a NEW residual is not a deflation and can hurt).
  void refresh_coarse(const MatfreeReduced& mprime) { build_coarse_operator(mprime); }

  // z += M2^-1 r  (coarse + local additive Schwarz), reduced (kept) space, length ng.
  void apply(const double* r, double* z) {
    ++apply_calls;
    if (cfg.with_coarse) apply_coarse(r, z);
    if (cfg.with_local)  apply_local(r, z);
  }

 private:
  Eigen::Matrix<double,24,24> K0_;
  std::vector<int> kept_of_gdof_;
  std::vector<CoarseCol> cols_;
  std::vector<SubSolver> subs_;
  Eigen::LDLT<MatrixXd> coarse_ldlt_;
  MatrixXd coarse_dense_A_;   // kept for inner-CG coarse path
  std::vector<double> ccoarse_;
  const MatfreeReduced* mref_ = nullptr;

  void build_coarse_operator(const MatfreeReduced& m) {
    mref_ = &m;
    const double t0 = now_ms();
    MatrixXd Ac = MatrixXd::Zero(Nt, Nt);
    std::vector<double> vq(static_cast<std::size_t>(ng)), Avq(static_cast<std::size_t>(ng));
    for (int q=0; q<Nt; ++q) {
      std::fill(vq.begin(), vq.end(), 0.0);
      const CoarseCol& cq = cols_[q];
      for (std::size_t tt=0; tt<cq.idx.size(); ++tt) vq[cq.idx[tt]] = cq.val[tt];
      m.apply_kgg_raw(vq.data(), Avq.data());
      for (int p=0; p<Nt; ++p) { const CoarseCol& cp = cols_[p]; double dot=0;
        for (std::size_t tt=0; tt<cp.idx.size(); ++tt) dot += cp.val[tt]*Avq[cp.idx[tt]];
        Ac(p,q)=dot; }
    }
    Ac = 0.5*(Ac + Ac.transpose());
    coarse_assemble_ms = now_ms() - t0;
    coarse_dim = Nt;
    if (Nt <= cfg.coarse_dense_cap && Nt > 0) {
      const double t1 = now_ms();
      coarse_ldlt_.compute(Ac); coarse_factor_ms = now_ms() - t1; coarse_dense = true;
      Eigen::SelfAdjointEigenSolver<MatrixXd> es(Ac, Eigen::EigenvaluesOnly);
      const double lmin=es.eigenvalues()(0), lmax=es.eigenvalues()(Nt-1);
      coarse_cond = (lmin>0)? lmax/lmin : -1;
    } else { coarse_dense = false; }
    coarse_dense_A_ = std::move(Ac);  // retained for inner-CG coarse path / diagnostics
  }

  void apply_coarse(const double* r, double* z) {
    if (Nt == 0) return;
    // c = V^T r
    for (int p=0;p<Nt;++p){ const CoarseCol& cp=cols_[p]; double s=0;
      for (std::size_t tt=0;tt<cp.idx.size();++tt) s += cp.val[tt]*r[cp.idx[tt]]; ccoarse_[p]=s; }
    VectorXd c(Nt); for (int p=0;p<Nt;++p) c(p)=ccoarse_[p];
    VectorXd cc;
    if (coarse_dense) cc = coarse_ldlt_.solve(c);
    else cc = coarse_inner_cg(c);
    // z += V cc
    for (int p=0;p<Nt;++p){ const CoarseCol& cp=cols_[p]; const double v=cc(p);
      for (std::size_t tt=0;tt<cp.idx.size();++tt) z[cp.idx[tt]] += v*cp.val[tt]; }
  }

  // Inner-CG on the dense coarse operator (Jacobi-preconditioned), capped — the
  // inexact coarse solve for N_t above the dense-factor budget (production extents).
  VectorXd coarse_inner_cg(const VectorXd& b) const {
    const int n = Nt; VectorXd x=VectorXd::Zero(n);
    VectorXd d(n); for (int i=0;i<n;++i) d(i)=coarse_dense_A_(i,i);
    VectorXd r=b, z(n); for (int i=0;i<n;++i) z(i)=r(i)/std::max(d(i),1e-300);
    VectorXd p=z; double rz=r.dot(z);
    for (int it=0; it<cfg.coarse_inner_iters; ++it) {
      VectorXd Ap = coarse_dense_A_*p; const double a=rz/std::max(p.dot(Ap),1e-300);
      x+=a*p; r-=a*Ap; if (r.norm() <= 1e-6*b.norm()) break;
      for (int i=0;i<n;++i) z(i)=r(i)/std::max(d(i),1e-300);
      const double rzn=r.dot(z); p = z + (rzn/std::max(rz,1e-300))*p; rz=rzn;
    }
    return x;
  }

  // Local additive Schwarz term: sum_i R_i^T A_i^-1 R_i r, each A_i^-1 INEXACT.
  // Threaded across subdomains via the SHARED persistent matrix-free pool
  // (mf_parallel_ranges) — NOT a per-apply std::thread spawn, which would create/join
  // nsub threads on every CG iteration. Each subdomain solves into its own slice of
  // out_buf_ (no shared writes), then a fixed-order serial scatter-add into z keeps
  // the overlap sums deterministic regardless of thread count.
  void apply_local(const double* r, double* z) {
    const int ns = static_cast<int>(subs_.size());
    if (out_off_.empty()) {
      out_off_.assign(ns+1, 0);
      for (int s=0;s<ns;++s) out_off_[s+1] = out_off_[s] + subs_[s].nact;
      out_buf_.assign(static_cast<std::size_t>(out_off_[ns]), 0.0);
    }
    fea_detail::mf_parallel_ranges(0, ns, 1, [&](int lo, int hi){
      for (int s=lo; s<hi; ++s) solve_subdomain(subs_[s], r, out_buf_.data()+out_off_[s]);
    });
    for (int s=0;s<ns;++s){ const SubSolver& S=subs_[s]; const double* ob=out_buf_.data()+out_off_[s];
      for (int a=0;a<S.nact;++a) z[S.kept_of_active[a]] += ob[a]; }
  }

  // Solve A_i zl = rl inexactly on subdomain S's LOCAL dofs; rl gathered from r on the
  // active dofs (0 elsewhere), zl written to `out` on the active dofs.
  void solve_subdomain(const SubSolver& S, const double* r, double* out) const {
    const LocalOp& L = S.L; const int n = L.n;
    std::vector<double> rl(n, 0.0), zl(n, 0.0);
    for (int a=0;a<S.nact;++a) rl[S.loc_of_active[a]] = r[S.kept_of_active[a]];
    const bool use_cg = (cfg.local==LocalSolveKind::InnerCG) ||
                        (cfg.tail_inner_cg>0 && S.kept_modes>=cfg.tail_kept);
    const int iters = (cfg.tail_inner_cg>0 && S.kept_modes>=cfg.tail_kept) ? cfg.tail_inner_cg : cfg.local_iters;
    if (use_cg) local_inner_cg(L, rl.data(), zl.data(), iters);
    else        local_jacobi(L, rl.data(), zl.data(), iters);
    for (int a=0;a<S.nact;++a) out[a] = zl[S.loc_of_active[a]];
  }

  static void local_jacobi(const LocalOp& L, const double* rl, double* zl, int sweeps) {
    const int n=L.n; std::vector<double> Az(n);
    for (int s=0;s<sweeps;++s){ L.applyNeu(zl, Az.data());
      for (int i=0;i<n;++i) zl[i] += 0.6 * (rl[i]-Az[i]) / std::max(L.diagNeu[i],1e-300); }
  }
  static void local_inner_cg(const LocalOp& L, const double* rl, double* zl, int iters) {
    const int n=L.n; std::vector<double> Ap(n), rr(n), zz(n), p(n);
    for (int i=0;i<n;++i){ zl[i]=0.0; rr[i]=rl[i]; zz[i]=rr[i]/std::max(L.diagNeu[i],1e-300); p[i]=zz[i]; }
    double rz=0; for(int i=0;i<n;++i) rz+=rr[i]*zz[i];
    const double bnorm = [&]{ double s=0; for(int i=0;i<n;++i)s+=rl[i]*rl[i]; return std::sqrt(s); }();
    for (int it=0; it<iters; ++it) {
      L.applyNeu(p.data(), Ap.data());
      double pAp=0; for(int i=0;i<n;++i)pAp+=p[i]*Ap[i]; const double a=rz/std::max(pAp,1e-300);
      double rn2=0; for(int i=0;i<n;++i){ zl[i]+=a*p[i]; rr[i]-=a*Ap[i]; rn2+=rr[i]*rr[i]; }
      if (std::sqrt(rn2) <= 1e-6*std::max(bnorm,1e-300)) break;
      for(int i=0;i<n;++i) zz[i]=rr[i]/std::max(L.diagNeu[i],1e-300);
      double rzn=0; for(int i=0;i<n;++i)rzn+=rr[i]*zz[i]; const double b=rzn/std::max(rz,1e-300);
      for(int i=0;i<n;++i) p[i]=zz[i]+b*p[i]; rz=rzn;
    }
  }

  // apply scratch
  std::vector<int> out_off_;
  mutable std::vector<double> out_buf_;
};

// Install `tl` as the process-global external preconditioner for the duration of a scope.
struct HookGuard {
  MfPrecondHook prev;
  explicit HookGuard(TwoLevel* tl) {
    prev = fea_detail::mf_set_precond_hook(
        [tl](const MatfreeReduced& m, const MfSolveContext&, const double* r, double* z){
          tl->apply(r, z); (void)m; });
  }
  ~HookGuard() { fea_detail::mf_set_precond_hook(prev); }
};

// One solve of the reduced system `m`, via the PRODUCTION mf_cg_solve. `tl` non-null =>
// the two-level correction is installed for this solve.
struct SolveResult { int iters=0; double residual=0; bool converged=false; double wall_ms=0; };
SolveResult solve_reduced(const MatfreeReduced& m, double tol, int maxit, TwoLevel* tl,
                          const VoxelGrid& g, const std::vector<double>& emod) {
  if (maxit<=0 && std::getenv("TL_MAXIT")) maxit = std::atoi(std::getenv("TL_MAXIT"));
  MfSolveContext ctx; ctx.grid=&g; ctx.elem_youngs=&emod; ctx.youngs_modulus=kE0; ctx.poisson=kNu;
  std::vector<double> x(static_cast<std::size_t>(m.ng), 0.0);
  SolveResult R; const double t0=now_ms();
  if (tl) { HookGuard hg(tl); mf_cg_solve(m, tol, maxit, x, R.iters, R.residual, R.converged, nullptr, &ctx); }
  else    {                   mf_cg_solve(m, tol, maxit, x, R.iters, R.residual, R.converged, nullptr, &ctx); }
  R.wall_ms = now_ms()-t0;
  return R;
}

// ======================================================================================
// Modes
// ======================================================================================
FILE* open_csv(const std::string& dir, const char* name) {
  return std::fopen((dir + "/" + name).c_str(), "w");
}

// STAG — feasibility: develop the fixture, confirm the single solve STAGNATES
// (used_multigrid=false via CgInfo, thousands of Jacobi-CG iters).
int mode_stag(const std::string& dir) {
  const int arm = std::getenv("TL_ARM")?std::atoi(std::getenv("TL_ARM")):24;
  const int span= std::getenv("TL_SPAN")?std::atoi(std::getenv("TL_SPAN")):24;
  const int ny  = std::getenv("TL_NY")?std::atoi(std::getenv("TL_NY")):6;
  const int t   = std::getenv("TL_T")?std::atoi(std::getenv("TL_T")):6;
  const double h= 1.0; const double vf = std::getenv("TL_VF")?std::atof(std::getenv("TL_VF")):0.26;
  const int iters = std::getenv("TL_ITERS")?std::atoi(std::getenv("TL_ITERS")):20;
  const double hole = std::getenv("TL_HOLE")?std::atof(std::getenv("TL_HOLE")):0.0;
  const bool pipeline = !std::getenv("TL_OC");   // default: real ladder; TL_OC=1 => bare OC
  const DesignBox box = stagnation_box(arm,span,ny,t,h);
  std::printf("## STAG l_bracket arm=%d span=%d ny=%d t=%d h=%.1f vf=%.2f develop=%d(%s) box=[%.0f,%.0f,%.0f]..[%.0f,%.0f,%.0f]\n",
              arm,span,ny,t,h,vf,iters,pipeline?"pipeline":"OC",box.min.x,box.min.y,box.min.z,box.max.x,box.max.y,box.max.z);
  const double tdev = now_ms();
  DevelopedCase D = pipeline ? develop_pipeline(arm,span,ny,t,h,vf,iters,Vec3{0,0,-30},box, dir + "/stag_cache.bin")
                             : develop_case(arm,span,ny,t,h,hole,vf,iters,Vec3{0,0,-30},box);
  const VoxelGrid& g = D.grid;
  std::printf("   solved grid %dx%dx%d (%zu vox, %zu solid), develop wall=%.1f s\n",
              g.nx,g.ny,g.nz,g.voxel_count(),g.solid_count(),(now_ms()-tdev)/1e3);
  const std::vector<double>& rho = D.snaps.back();
  std::vector<double> ey = penalized_youngs(g, rho);
  fea_matfree_reset_mg_stagnation_latch();
  CgInfo info;
  const double ts = now_ms();
  FeaSolution sol = fea_solve_mgcg_matfree(g, ey, kNu, D.bcs, D.loads, kCertTol, 0, &info);
  (void)sol;
  std::printf("   SOLVE: used_multigrid=%d hier_built=%d mg_cycles=%d iters=%d residual=%.2e conv=%d  wall=%.1f s\n",
              info.used_multigrid, info.hier_built, info.mg_cycles_attempted, info.iterations,
              info.residual, info.converged, (now_ms()-ts)/1e3);
  const bool stagnates = (!info.used_multigrid) && info.hier_built && info.iterations > 1000;
  std::printf("   => %s (Jacobi-CG baseline = %d iters)\n",
              stagnates?"STAGNATES (usable baseline)":"does NOT stagnate at this size", info.iterations);
  (void)dir;
  return stagnates?0:2;
}

}  // namespace

// Remaining measurement modes (selfcheck / p2 / control / amort / healthy / det /
// byteid) — same TU, so they see every helper above.
#include "geneo_twolevel_probe_part3.inc"

int main(int argc, char** argv) {
  const std::string mode = argc>1?argv[1]:"stag";
  const std::string dir  = argc>2?argv[2]:".";
  std::setvbuf(stdout, nullptr, _IOLBF, 0);
  if (mode=="stag") return mode_stag(dir);
  return geneo_tl_dispatch(mode, dir);
}
