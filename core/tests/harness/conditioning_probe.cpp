// conditioning_probe.cpp — measurement harness (NOT a CI test) for the
// 2026-07-28 "conditioning Stage 0" handoff. READ-ONLY: it measures and
// recommends; it changes no production default (bar B3). Both levers OFF, this
// program never runs — the shipping path is byte-identical to origin/main (B1).
//
// It probes the two cheapest conditioning levers named in the task, NEITHER of
// which touches production:
//
//   LEVER A — stiffness rescaling (Wang, de Sturler & Paulino, IJNME 69, 2007).
//     Symmetric diagonal scaling S = diag(K)^(-1/2); the rescaled operator S·K·S
//     has condition number ~ the constant-density problem. We MEASURE its effect
//     as the CG-iteration change, and — the key finding — whether it is anything
//     the production solver does not ALREADY do (its CG is Jacobi/diagonally
//     preconditioned, which is algebraically the same Krylov space as
//     unpreconditioned CG on S·K·S). See §Lever A note at the bottom / handoff.
//
//   LEVER B — raise the density floor rho_min. In this codebase the floor is
//     SimpParams::density_min (default 1e-3) and the SIMP law is
//     E(rho)=clamp(rho,density_min,1)^p·E0, so the STIFFNESS contrast the solver
//     actually sees is density_min^p = (1e-3)^3 = 1e-9 at the terminal penalty
//     p=3 — THIS is the task's "we use 1e-9". Raising the stiffness floor to a
//     target contrast c means density_min = c^(1/p). The sweep {1e-9,1e-8,1e-7,
//     1e-6,1e-5} contrast maps to density_min {1.00e-3, 2.15e-3, 4.64e-3, 1.00e-2,
//     2.15e-2}. Each row prints BOTH so nothing is hidden.
//
// FIXTURE. The stagnation the production MG hierarchy actually suffers is the
// "occ0.4+hole" whole-domain design-box case (multigrid.cpp §latch: "the
// genuinely pathological end ... does not converge even at 2000 cycles"). We
// reproduce it: a cantilever design box (all voxels design variables) with a
// carved hole, clamped face, tip traction. Baseline simp_optimize at each ladder
// rung {0.68,0.52,0.38,0.26} gives the real dilute high-contrast physical density
// the certification solve faces; that field, re-floored per contrast, is the
// operator we condition-measure.
//
// WHAT IS MEASURED (per rung, per contrast), all at FIXED geometry so the
// conditioning effect is isolated from any design change:
//   * CG iterations to a fixed relative tol 1e-8 — the task-sanctioned kappa
//     proxy (iters ~ sqrt(kappa)), for THREE operators on the SAME system:
//       - unpreconditioned CG on K           (raw conditioning)
//       - Jacobi CG on K                     (= production; = Lever A rescaled)
//       - unpreconditioned CG on S·K·S       (Lever A applied explicitly)
//     The last two coincide by construction — that IS the Lever A finding.
//   * A Lanczos kappa estimate (theta_max/theta_min of the k-step tridiagonal),
//     computed on the assembled reduced K — cheap, corroborates the CG proxy.
//   * The production MG path (fea_solve_mgcg_matfree): used_multigrid,
//     hier_built, mg_cycles_attempted — carry vs stagnate (S3), and S5 (combo).
//
// S4 (design cost) is a SEPARATE phase: it re-RUNS simp_optimize per rung at each
// density_min (the only lever that changes the design), and reports the fraction
// of solid voxels changing classification vs the 1e-9 baseline, with per-rung
// gate verdicts via analyze_fixed_design and the SIGN of every change (B2). The
// negative control (1e-9 vs 1e-8) runs first to set the basin floor.
//
// Build (standalone; NOT wired into CTest):
//   c++ -std=c++17 -O2 -I include -I /opt/homebrew/include/eigen3 \
//     -DSETTINGS_RULES_PATH="\"$PWD/src/settings/rules.json\"" \
//     tests/harness/conditioning_probe.cpp build-cond/libtopopt.a -o cond_probe
//
// Env:
//   TOPOPT_COND_CSV_DIR   dir for CSV sinks (else stdout only)
//   TOPOPT_COND_NX/NY/NZ  fixture dims (default 32x16x32; multiples of 8)
//   TOPOPT_COND_PHASE     cond|design|combo|all (default all)

#include <Eigen/Dense>
#include <Eigen/Sparse>

#include <algorithm>
#include <array>
#include <chrono>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <string>
#include <vector>

#include "topopt/analyze.hpp"
#include "topopt/fea.hpp"
#include "topopt/materials.hpp"
#include "topopt/production.hpp"
#include "topopt/report.hpp"
#include "topopt/settings.hpp"
#include "topopt/simp.hpp"
#include "topopt/voxel.hpp"

using namespace topopt;

namespace {

constexpr double kPenalty = 3.0;       // production terminal penalty
constexpr double kCgTol = 1e-8;        // production penalized-solve CG tolerance
constexpr int kLanczosSteps = 400;     // Lanczos steps for the kappa estimate

// The five stiffness contrasts the task sweeps (E_min/E0). density_min = c^(1/p).
const double kContrast[] = {1e-9, 1e-8, 1e-7, 1e-6, 1e-5};
const char* kContrastName[] = {"1e-9", "1e-8", "1e-7", "1e-6", "1e-5"};

double density_min_for_contrast(double contrast) {
  return std::pow(contrast, 1.0 / kPenalty);
}

Material fdm_material() {
  Material m;
  m.youngs_modulus_mpa = 3500.0;
  m.yield_strength_mpa = 55.0;
  m.density_g_cm3 = 1.24;
  m.z_knockdown = 0.55;
  m.poisson = 0.33;
  m.family = "fdm";
  return m;
}

int env_int(const char* k, int dflt) {
  const char* v = std::getenv(k);
  return v ? std::atoi(v) : dflt;
}

// --- Fixture: whole-domain cantilever design box with a carved hole ----------
// Every voxel is a design variable (Interior) EXCEPT the hole (Empty). The x=0
// face is clamped (Fixture + Dirichlet on every node of that face); a downward
// tip traction loads the far (x=nx-1) face. This is the occ0.4+hole regime the
// production MG hierarchy stagnates on.
VoxelGrid design_box_fixture(int nx, int ny, int nz, double h,
                             std::vector<DirichletBC>& bcs) {
  VoxelGrid g;
  g.nx = nx;
  g.ny = ny;
  g.nz = nz;
  g.spacing = h;
  g.origin = Vec3{0.0, 0.0, 0.0};
  g.tags.assign(static_cast<std::size_t>(nx) * ny * nz, VoxelTag::Interior);

  // A rectangular through-hole (in y) near the cantilever's neutral-ish zone —
  // the "hole" that wrecks geometric coarsening. ~centered in x, upper-mid z.
  const int hx0 = nx * 5 / 16, hx1 = nx * 9 / 16;
  const int hz0 = nz * 9 / 16, hz1 = nz * 13 / 16;
  for (int k = hz0; k < hz1; ++k)
    for (int j = 0; j < ny; ++j)
      for (int i = hx0; i < hx1; ++i) g.set_tag(i, j, k, VoxelTag::Empty);

  // Clamp the whole x=0 face.
  bcs.clear();
  for (int c = 0; c <= nz; ++c)
    for (int b = 0; b <= ny; ++b) {
      const int node = fea_node_index(g, 0, b, c);
      bcs.push_back({node, 0, 0.0});
      bcs.push_back({node, 1, 0.0});
      bcs.push_back({node, 2, 0.0});
    }
  // Tag the far face as Load (bottom half in z, so the tip pulls a lever arm).
  for (int k = 0; k < nz / 2; ++k)
    for (int j = 0; j < ny; ++j)
      if (g.tag(nx - 1, j, k) != VoxelTag::Empty)
        g.set_tag(nx - 1, j, k, VoxelTag::Load);
  return g;
}

// The 8 corner node indices of element (i,j,k), in hex8_stiffness DOF order
// (assembly.cpp fea_element_nodes: bottom CCW then top CCW).
std::array<int, 8> elem_nodes(const VoxelGrid& g, int i, int j, int k) {
  return {fea_node_index(g, i, j, k),         fea_node_index(g, i + 1, j, k),
          fea_node_index(g, i + 1, j + 1, k), fea_node_index(g, i, j + 1, k),
          fea_node_index(g, i, j, k + 1),     fea_node_index(g, i + 1, j, k + 1),
          fea_node_index(g, i + 1, j + 1, k + 1),
          fea_node_index(g, i, j + 1, k + 1)};
}

// E(rho) = clamp(rho, density_min, 1)^p * E0, per solid voxel; 0 for Empty.
std::vector<double> youngs_from_density(const VoxelGrid& g,
                                        const std::vector<double>& rho,
                                        double density_min, double E0) {
  std::vector<double> y(g.voxel_count(), 0.0);
  for (int k = 0; k < g.nz; ++k)
    for (int j = 0; j < g.ny; ++j)
      for (int i = 0; i < g.nx; ++i) {
        const int e = g.index(i, j, k);
        if (g.tag(i, j, k) == VoxelTag::Empty) continue;
        double r = rho.empty() ? 1.0 : rho[e];
        r = std::min(1.0, std::max(density_min, r));
        y[e] = std::pow(r, kPenalty) * E0;
      }
  return y;
}

// --- Assembled reduced K over free DOFs (for Lanczos kappa + raw/rescaled CG) -
using SpMat = Eigen::SparseMatrix<double>;
using Vec = Eigen::VectorXd;

struct Reduced {
  SpMat A;           // reduced stiffness over free DOFs (SPD)
  Vec rhs;           // reduced load vector
  int ndof = 0;
};

Reduced assemble_reduced(const VoxelGrid& g, const std::vector<double>& youngs,
                         double nu, double h,
                         const std::vector<DirichletBC>& bcs,
                         const std::vector<NodalLoad>& loads) {
  const int nnode = fea_node_count(g);
  const int gdof = 3 * nnode;

  // Node active iff attached to a non-Empty voxel.
  std::vector<char> node_active(nnode, 0);
  for (int k = 0; k < g.nz; ++k)
    for (int j = 0; j < g.ny; ++j)
      for (int i = 0; i < g.nx; ++i) {
        if (g.tag(i, j, k) == VoxelTag::Empty) continue;
        for (int n : elem_nodes(g, i, j, k)) node_active[n] = 1;
      }

  std::vector<char> constrained(gdof, 0);
  for (const auto& bc : bcs) constrained[3 * bc.node + bc.component] = 1;

  // Map global DOF -> free DOF index (-1 if constrained/inactive).
  std::vector<int> gto(gdof, -1);
  int ndof = 0;
  for (int n = 0; n < nnode; ++n) {
    if (!node_active[n]) continue;
    for (int c = 0; c < 3; ++c) {
      const int gd = 3 * n + c;
      if (!constrained[gd]) gto[gd] = ndof++;
    }
  }

  const Hex8Stiffness Ke = hex8_stiffness(1.0, nu, h);  // K(E)=E*Ke
  std::vector<Eigen::Triplet<double>> trips;
  trips.reserve(static_cast<std::size_t>(ndof) * 24);
  for (int k = 0; k < g.nz; ++k)
    for (int j = 0; j < g.ny; ++j)
      for (int i = 0; i < g.nx; ++i) {
        const int e = g.index(i, j, k);
        if (g.tag(i, j, k) == VoxelTag::Empty) continue;
        const double E = youngs[e];
        if (!(E > 0.0)) continue;
        const std::array<int, 8> nn = elem_nodes(g, i, j, k);
        for (int a = 0; a < 8; ++a)
          for (int ca = 0; ca < 3; ++ca) {
            const int gr = gto[3 * nn[a] + ca];
            if (gr < 0) continue;
            const int lr = 3 * a + ca;
            for (int b = 0; b < 8; ++b)
              for (int cb = 0; cb < 3; ++cb) {
                const int gc = gto[3 * nn[b] + cb];
                if (gc < 0) continue;
                const double v = E * Ke(lr, 3 * b + cb);
                if (v != 0.0)
                  trips.emplace_back(gr, gc, v);
              }
          }
      }
  Reduced R;
  R.ndof = ndof;
  R.A.resize(ndof, ndof);
  R.A.setFromTriplets(trips.begin(), trips.end());
  R.rhs = Vec::Zero(ndof);
  for (const auto& ld : loads) {
    const int gd = 3 * ld.node + ld.component;
    if (gd >= 0 && gd < gdof && gto[gd] >= 0) R.rhs[gto[gd]] += ld.value;
  }
  return R;
}

// Unpreconditioned CG; returns iterations to reach relative residual `tol`.
// The count SATURATES at `cap` (returned as the cap) — raw unpreconditioned CG on
// the 1e-9-contrast system genuinely needs ~sqrt(kappa) iterations, which we only
// need to know EXCEEDS Jacobi's count by orders, not resolve exactly.
int cg_iters(const SpMat& A, const Vec& b, double tol, bool jacobi,
             int cap = 40000) {
  const int n = A.rows();
  Vec x = Vec::Zero(n);
  Vec r = b;  // x0 = 0
  Vec Minv;
  if (jacobi) {
    Minv = A.diagonal();
    for (int i = 0; i < n; ++i) Minv[i] = Minv[i] != 0.0 ? 1.0 / Minv[i] : 1.0;
  }
  Vec z = jacobi ? (Minv.array() * r.array()).matrix() : r;
  Vec p = z;
  double rz = r.dot(z);
  const double bnorm = b.norm();
  if (bnorm == 0.0) return 0;
  int it = 0;
  for (; it < cap; ++it) {
    if (r.norm() <= tol * bnorm) break;
    Vec Ap = A * p;
    const double alpha = rz / p.dot(Ap);
    x += alpha * p;
    r -= alpha * Ap;
    Vec znew = jacobi ? (Minv.array() * r.array()).matrix() : r;
    const double rznew = r.dot(znew);
    const double beta = rznew / rz;
    p = znew + beta * p;
    rz = rznew;
    z = znew;
  }
  return it;
}

// Lanczos kappa estimate: k steps -> tridiagonal (alpha,beta) -> Ritz spread.
double lanczos_kappa(const SpMat& A, int steps, double* lmin_out,
                     double* lmax_out) {
  const int n = A.rows();
  steps = std::min(steps, n);
  Vec v = Vec::Zero(n);
  for (int i = 0; i < n; ++i) v[i] = std::sin(0.9 * i + 1.0);  // deterministic
  v /= v.norm();
  Vec vprev = Vec::Zero(n);
  std::vector<double> alpha, beta;
  double bprev = 0.0;
  for (int j = 0; j < steps; ++j) {
    Vec w = A * v;
    const double a = v.dot(w);
    w -= a * v + bprev * vprev;
    // One reorthogonalization pass against the previous two (local) — cheap.
    w -= (w.dot(v)) * v;
    const double b = w.norm();
    alpha.push_back(a);
    if (b < 1e-14 * std::fabs(a) || j + 1 == steps) break;
    beta.push_back(b);
    vprev = v;
    v = w / b;
    bprev = b;
  }
  const int m = static_cast<int>(alpha.size());
  Eigen::MatrixXd T = Eigen::MatrixXd::Zero(m, m);
  for (int i = 0; i < m; ++i) {
    T(i, i) = alpha[i];
    if (i + 1 < m) {
      T(i, i + 1) = beta[i];
      T(i + 1, i) = beta[i];
    }
  }
  Eigen::SelfAdjointEigenSolver<Eigen::MatrixXd> es(T);
  const double lmin = es.eigenvalues()(0);
  const double lmax = es.eigenvalues()(m - 1);
  if (lmin_out) *lmin_out = lmin;
  if (lmax_out) *lmax_out = lmax;
  return (lmin > 0.0) ? lmax / lmin : -1.0;
}

double median(std::vector<double> v) {
  if (v.empty()) return 0.0;
  std::sort(v.begin(), v.end());
  return v[v.size() / 2];
}

// --- SimpOptions mirroring the production penalized solve (config-faithful) ---
SimpOptions production_like_opts(double vf, double filter_radius) {
  SimpOptions o;
  o.updater = SimpUpdater::MMA;               // production default
  o.solver = SolverKind::MultigridCG_Matfree;  // production penalized solver
  o.volume_fraction = vf;
  o.filter_radius = filter_radius;
  o.cg_tolerance = kCgTol;
  o.max_iterations = 200;
  // TOPOPT_COND_MAXITER caps the baseline optimize for the large stagnation-hunt
  // grids. A partially-converged dilute field is if anything HARDER for geometric
  // MG (grayer interfaces, less coherent), so it is a valid — conservative —
  // stagnation probe; it is only used to source the fixed operator, never for a
  // design claim (S4 always runs the field to convergence).
  if (const char* m = std::getenv("TOPOPT_COND_MAXITER")) {
    const int cap = std::atoi(m);
    if (cap > 0) o.max_iterations = cap;
  }
  return o;
}

const std::vector<double>& ladder() {
  static const std::vector<double> l = production_reduction_ladder();
  return l;
}

FILE* csv_open(const char* name) {
  const char* dir = std::getenv("TOPOPT_COND_CSV_DIR");
  if (!dir) return nullptr;
  const std::string path = std::string(dir) + "/" + name;
  FILE* f = std::fopen(path.c_str(), "w");
  if (!f) std::fprintf(stderr, "WARN: cannot write %s\n", path.c_str());
  else std::printf("  [csv %s]\n", path.c_str());
  return f;
}

// ---------------------------------------------------------------------------
struct RungField {
  double vf = 0.0;
  std::vector<double> rho;  // baseline (density_min=1e-3) terminal physical density
  double achieved = 0.0;
};

// Baseline optimize per rung -> the real dilute fields the solver faces.
std::vector<RungField> baseline_fields(const VoxelGrid& g,
                                       const std::vector<DirichletBC>& bcs,
                                       const std::vector<NodalLoad>& loads,
                                       const Material& mat, double filter_radius) {
  SimpParams params;
  params.youngs_modulus = mat.youngs_modulus_mpa;
  params.poisson = mat.poisson;
  params.penalty = kPenalty;
  params.density_min = density_min_for_contrast(1e-9);  // = 1e-3, the baseline

  std::vector<RungField> out;
  for (double vf : ladder()) {
    SimpOptions o = production_like_opts(vf, filter_radius);
    RungField rf;
    rf.vf = vf;
    try {
      SimpOptimizeResult r = simp_optimize(g, params, bcs, loads, o);
      rf.rho = r.physical_density;
      rf.achieved = r.volume_fraction;
    } catch (const std::exception& e) {
      std::fprintf(stderr, "  baseline vf=%.2f FAILED: %s\n", vf, e.what());
    }
    out.push_back(rf);
    std::printf("  baseline rung vf=%.2f achieved=%.4f solid_frac=%.3f\n", vf,
                rf.achieved,
                rf.rho.empty() ? 0.0
                               : (double)std::count_if(rf.rho.begin(),
                                                       rf.rho.end(),
                                                       [](double d) {
                                                         return d > 0.5;
                                                       }) /
                                     (double)rf.rho.size());
  }
  return out;
}

// =========================== PHASE cond (S1/S2/S3) ==========================
void phase_cond(const VoxelGrid& g, const std::vector<DirichletBC>& bcs,
                const std::vector<NodalLoad>& loads, const Material& mat,
                double filter_radius, const std::vector<RungField>& fields) {
  std::printf("\n========== PHASE cond — conditioning at FIXED geometry ==========\n");
  std::printf("grid %dx%dx%d  spacing=%.3f  solid_voxels=%zu\n", g.nx, g.ny, g.nz,
              g.spacing, g.solid_count());
  const double E0 = mat.youngs_modulus_mpa, nu = mat.poisson, h = g.spacing;

  FILE* f = csv_open("cond_sweep.csv");
  if (f)
    std::fprintf(f,
                 "rung_vf,contrast,density_min,ndof,"
                 "cg_unprecond,cg_jacobi,cg_rescaled,"
                 "kappa_lanczos,lambda_min,lambda_max,"
                 "mg_used,mg_hier_built,mg_cycles,mg_cg_iters,mg_converged\n");

  for (const RungField& rf : fields) {
    if (rf.rho.empty()) continue;
    std::printf("\n-- rung vf=%.2f (achieved %.3f) --\n", rf.vf, rf.achieved);
    std::printf("   %-6s %-9s | %8s %8s %8s | %10s | %4s %5s %7s %8s\n",
                "contr", "dmin", "cg_raw", "cg_jac", "cg_resc", "kappa",
                "mgOK", "hier", "cycles", "mg_cg");
    for (std::size_t ci = 0; ci < 5; ++ci) {
      const double contrast = kContrast[ci];
      const double dmin = density_min_for_contrast(contrast);
      const std::vector<double> youngs =
          youngs_from_density(g, rf.rho, dmin, E0);

      // Assembled reduced K for raw/rescaled CG + Lanczos. In FAST mode skip the
      // raw + explicit-rescaled CG (their behaviour is fully characterised at the
      // small scale) and keep only Jacobi + Lanczos + the production MG path — so
      // the large stagnation-hunting grid stays tractable.
      const bool fast = std::getenv("TOPOPT_COND_FAST") != nullptr;
      Reduced R = assemble_reduced(g, youngs, nu, h, bcs, loads);
      const int cg_raw = fast ? -1 : cg_iters(R.A, R.rhs, kCgTol, /*jacobi=*/false);
      const int cg_jac = cg_iters(R.A, R.rhs, kCgTol, /*jacobi=*/true);
      int cg_resc = -1;
      if (!fast) {
        // Lever A explicit: unpreconditioned CG on S·K·S, S=diag(K)^(-1/2).
        Vec d = R.A.diagonal();
        Vec s = Vec::Ones(R.ndof);
        for (int i = 0; i < R.ndof; ++i)
          s[i] = d[i] > 0.0 ? 1.0 / std::sqrt(d[i]) : 1.0;
        SpMat S(R.ndof, R.ndof);
        std::vector<Eigen::Triplet<double>> st;
        st.reserve(R.ndof);
        for (int i = 0; i < R.ndof; ++i) st.emplace_back(i, i, s[i]);
        S.setFromTriplets(st.begin(), st.end());
        SpMat SKS = (S * R.A * S).pruned();
        Vec Sb = (s.array() * R.rhs.array()).matrix();
        cg_resc = cg_iters(SKS, Sb, kCgTol, /*jacobi=*/false);
      }

      double lmin = 0, lmax = 0;
      const double kappa = lanczos_kappa(R.A, kLanczosSteps, &lmin, &lmax);

      // Production MG path — reset the per-run stagnation latch so each solve
      // is an independent measurement.
      fea_matfree_reset_mg_stagnation_latch();
      CgInfo mg{};
      bool mg_conv = false;
      try {
        fea_solve_mgcg_matfree(g, youngs, nu, bcs, loads, kCgTol, 0, &mg);
        mg_conv = true;
      } catch (const SolverNonConvergence& e) {
        mg.iterations = e.iterations;
        mg.residual = e.residual;
      } catch (const std::exception&) {
      }

      std::printf(
          "   %-6s %-9.2e | %8d %8d %8d | %10.3e | %4d %5d %7d %8d\n",
          kContrastName[ci], dmin, cg_raw, cg_jac, cg_resc, kappa,
          mg.used_multigrid ? 1 : 0, mg.hier_built ? 1 : 0,
          mg.mg_cycles_attempted, mg.iterations);
      std::fflush(stdout);
      if (f)
        std::fprintf(f, "%.2f,%s,%.6e,%d,%d,%d,%d,%.6e,%.6e,%.6e,%d,%d,%d,%d,%d\n",
                     rf.vf, kContrastName[ci], dmin, R.ndof, cg_raw, cg_jac,
                     cg_resc, kappa, lmin, lmax, mg.used_multigrid ? 1 : 0,
                     mg.hier_built ? 1 : 0, mg.mg_cycles_attempted, mg.iterations,
                     mg_conv ? 1 : 0);
    }
  }
  if (f) std::fclose(f);
}

// =========================== PHASE combo (S5) ===============================
void phase_combo(const VoxelGrid& g, const std::vector<DirichletBC>& bcs,
                 const std::vector<NodalLoad>& loads, const Material& mat,
                 const std::vector<RungField>& fields) {
  std::printf("\n========== PHASE combo (S5) — rescaling + rho_min=1e-6 ==========\n");
  // Rescaling in production == the Jacobi/diagonal preconditioner the matrix-free
  // CG already applies (its `invdiag`). So "rescaling + 1e-6" is measured as the
  // production MG-matfree path (which sits on that Jacobi smoother) at the raised
  // floor. We report the deepest rung (the one that stagnates hardest).
  const double E0 = mat.youngs_modulus_mpa, nu = mat.poisson;
  for (const RungField& rf : fields) {
    if (rf.rho.empty()) continue;
    std::printf("\n-- rung vf=%.2f --\n", rf.vf);
    for (double contrast : {1e-9, 1e-6}) {
      const double dmin = density_min_for_contrast(contrast);
      const std::vector<double> youngs = youngs_from_density(g, rf.rho, dmin, E0);
      fea_matfree_reset_mg_stagnation_latch();
      CgInfo mg{};
      bool conv = false;
      try {
        fea_solve_mgcg_matfree(g, youngs, nu, bcs, loads, kCgTol, 0, &mg);
        conv = true;
      } catch (const SolverNonConvergence& e) {
        mg.iterations = e.iterations;
        mg.residual = e.residual;
      } catch (const std::exception&) {
      }
      std::printf("   contrast=%.0e dmin=%.2e : mg_used=%d hier=%d cycles=%d "
                  "cg_iters=%d converged=%d\n",
                  contrast, dmin, mg.used_multigrid ? 1 : 0,
                  mg.hier_built ? 1 : 0, mg.mg_cycles_attempted, mg.iterations,
                  conv ? 1 : 0);
    }
  }
}

// =========================== PHASE upsample (S5 scaling) ====================
// The clean, fast S5 test: take the CONVERGED deep-rung field and nearest-
// neighbour UPSAMPLE it to larger grids (the SAME design at higher resolution),
// then ask whether the production MG carries at contrast 1e-9 vs 1e-6 as the grid
// grows into the stagnation regime. No re-optimize at large size (which itself
// stagnates and is the bottleneck) — just the MG solve on a fixed, faithful
// dilute high-contrast field. The MG fallback is capped so a stagnating solve
// returns promptly (mg_used=0 / converged=0 == stagnation reproduced).
void phase_upsample(const Material& mat, double h) {
  std::printf("\n========== PHASE upsample (S5 scaling) — does the floor rescue MG carry? ==========\n");
  const int bx = 16, by = 8, bz = 16;  // base grid (fast to optimize)
  std::vector<DirichletBC> bbcs;
  VoxelGrid base = design_box_fixture(bx, by, bz, h, bbcs);
  const std::vector<NodalLoad> bloads =
      traction_loads(base, VoxelTag::Load, Vec3{0.0, 0.0, -30.0});
  const double filter_radius = std::max(1.5, 2.5 / h);
  const double E0 = mat.youngs_modulus_mpa, nu = mat.poisson;

  // Converged deep-rung (0.26) field at the base resolution.
  SimpParams params;
  params.youngs_modulus = E0;
  params.poisson = nu;
  params.penalty = kPenalty;
  params.density_min = density_min_for_contrast(1e-9);
  SimpOptions o = production_like_opts(0.26, filter_radius);
  o.max_iterations = 200;  // fully converge the base field
  SimpOptimizeResult base_r = simp_optimize(base, params, bbcs, bloads, o);
  const std::vector<double>& rho0 = base_r.physical_density;
  std::printf("  base 16x8x16 deep-rung achieved=%.3f\n", base_r.volume_fraction);

  const int caps = 20000;  // MG fallback iteration cap (stagnation returns promptly)
  FILE* f = csv_open("upsample_s5.csv");
  if (f) std::fprintf(f, "factor,nx,ny,nz,ndof_solids,contrast,density_min,mg_used,hier,cycles,cg_iters,converged\n");

  std::printf("   %-6s %-12s | %-8s | %5s %5s %7s %8s %6s\n", "factor", "grid",
              "contrast", "mgOK", "hier", "cycles", "cg_iters", "conv");
  for (int factor : {1, 2, 3, 4}) {
    const int nx = bx * factor, ny = by * factor, nz = bz * factor;
    VoxelGrid g;
    g.nx = nx; g.ny = ny; g.nz = nz; g.spacing = h; g.origin = Vec3{0, 0, 0};
    g.tags.assign(static_cast<std::size_t>(nx) * ny * nz, VoxelTag::Interior);
    std::vector<double> rho(g.voxel_count(), 0.0);
    // Nearest-neighbour map fine (i,j,k) -> coarse (i/factor,...).
    for (int k = 0; k < nz; ++k)
      for (int j = 0; j < ny; ++j)
        for (int i = 0; i < nx; ++i) {
          const int ci = i / factor, cj = j / factor, ck = k / factor;
          const VoxelTag ct = base.tag(ci, cj, ck);
          if (ct == VoxelTag::Empty) { g.set_tag(i, j, k, VoxelTag::Empty); continue; }
          rho[g.index(i, j, k)] = rho0[base.index(ci, cj, ck)];
        }
    // BCs (clamp x=0 face) + load (tag far-face bottom half) at fine resolution.
    std::vector<DirichletBC> bcs;
    for (int c = 0; c <= nz; ++c)
      for (int b = 0; b <= ny; ++b) {
        const int node = fea_node_index(g, 0, b, c);
        bcs.push_back({node, 0, 0.0});
        bcs.push_back({node, 1, 0.0});
        bcs.push_back({node, 2, 0.0});
      }
    for (int k = 0; k < nz / 2; ++k)
      for (int j = 0; j < ny; ++j)
        if (g.tag(nx - 1, j, k) != VoxelTag::Empty)
          g.set_tag(nx - 1, j, k, VoxelTag::Load);
    const std::vector<NodalLoad> loads =
        traction_loads(g, VoxelTag::Load, Vec3{0.0, 0.0, -30.0});

    for (double contrast : {1e-9, 1e-6}) {
      const double dmin = density_min_for_contrast(contrast);
      const std::vector<double> youngs = youngs_from_density(g, rho, dmin, E0);
      fea_matfree_reset_mg_stagnation_latch();
      CgInfo mg{};
      bool conv = false;
      try {
        fea_solve_mgcg_matfree(g, youngs, nu, bcs, loads, kCgTol, caps, &mg);
        conv = true;
      } catch (const SolverNonConvergence& e) {
        mg.iterations = e.iterations;
      } catch (const std::exception&) {}
      std::printf("   x%-5d %2dx%2dx%2d | %-8.0e | %5d %5d %7d %8d %6d\n", factor,
                  nx, ny, nz, contrast, mg.used_multigrid ? 1 : 0,
                  mg.hier_built ? 1 : 0, mg.mg_cycles_attempted, mg.iterations,
                  conv ? 1 : 0);
      std::fflush(stdout);
      if (f)
        std::fprintf(f, "%d,%d,%d,%d,%zu,%.0e,%.6e,%d,%d,%d,%d,%d\n", factor, nx,
                     ny, nz, g.solid_count(), contrast, dmin,
                     mg.used_multigrid ? 1 : 0, mg.hier_built ? 1 : 0,
                     mg.mg_cycles_attempted, mg.iterations, conv ? 1 : 0);
    }
  }
  if (f) std::fclose(f);
}

// =========================== PHASE design (S4) ==============================
void phase_design(const VoxelGrid& g, const std::vector<DirichletBC>& bcs,
                  const std::vector<NodalLoad>& loads, const Material& mat,
                  double filter_radius) {
  std::printf("\n========== PHASE design (S4) — design cost of raising rho_min ==========\n");
  std::printf("grid %dx%dx%d  solid_voxels=%zu\n", g.nx, g.ny, g.nz,
              g.solid_count());
  const Vec3 build_dir{0.0, 0.0, 1.0};
  KnockdownSpec knock;  // solid (infill_knockdown=1) — pure strength gate

  // classification: a solid voxel is one with physical density > 0.5.
  auto classify = [](const std::vector<double>& rho) {
    std::vector<char> c(rho.size(), 0);
    for (std::size_t i = 0; i < rho.size(); ++i) c[i] = rho[i] > 0.5 ? 1 : 0;
    return c;
  };

  FILE* f = csv_open("design_cost.csv");
  if (f)
    std::fprintf(f,
                 "rung_vf,contrast,density_min,is_negctrl,nx,ny,nz,"
                 "solid_baseline,solid_variant,changed_voxels,frac_changed,"
                 "margin_baseline,margin_variant,margin_sign,"
                 "accepted_baseline,accepted_variant,compliance_variant\n");

  for (double vf : ladder()) {
    std::printf("\n-- rung vf=%.2f --\n", vf);
    // Baseline (contrast 1e-9) design + certification.
    SimpParams pbase;
    pbase.youngs_modulus = mat.youngs_modulus_mpa;
    pbase.poisson = mat.poisson;
    pbase.penalty = kPenalty;
    pbase.density_min = density_min_for_contrast(1e-9);
    SimpOptions o = production_like_opts(vf, filter_radius);
    o.max_iterations = 200;  // S4 is a DESIGN claim: always converge (ignore MAXITER)

    std::vector<double> rho_base;
    double margin_base = 0.0;
    bool acc_base = false;
    int solid_base = 0;
    try {
      SimpOptimizeResult rb = simp_optimize(g, pbase, bcs, loads, o);
      rho_base = rb.physical_density;
      FixedDesignAnalysis a = analyze_fixed_design(
          g, pbase, rho_base, bcs, loads, mat, build_dir, kCgTol, 0,
          SolverKind::MultigridCG_Matfree, /*margin_stop=*/1.5, knock,
          /*load_path_ok=*/true, /*part_solid=*/(double)g.solid_count());
      margin_base = a.margin.worst_case;
      acc_base = a.accepted;
    } catch (const std::exception& e) {
      std::fprintf(stderr, "  baseline vf=%.2f FAILED: %s\n", vf, e.what());
      continue;
    }
    const std::vector<char> cbase = classify(rho_base);
    solid_base = (int)std::count(cbase.begin(), cbase.end(), (char)1);

    std::printf("   %-8s %-9s %-4s | %8s %8s %7s | %8s %8s %4s\n", "contrast",
                "dmin", "ctl", "solidB", "solidV", "changed", "marginB",
                "marginV", "acc");
    // Sweep: 1e-8 (neg control) first, then 1e-7, 1e-6, 1e-5.
    for (std::size_t ci = 1; ci < 5; ++ci) {
      const double contrast = kContrast[ci];
      const double dmin = density_min_for_contrast(contrast);
      const bool negctrl = (ci == 1);
      SimpParams pv = pbase;
      pv.density_min = dmin;
      std::vector<double> rho_v;
      double margin_v = 0.0, compl_v = 0.0;
      bool acc_v = false;
      try {
        SimpOptimizeResult rv = simp_optimize(g, pv, bcs, loads, o);
        rho_v = rv.physical_density;
        compl_v = rv.compliance;
        FixedDesignAnalysis a = analyze_fixed_design(
            g, pv, rho_v, bcs, loads, mat, build_dir, kCgTol, 0,
            SolverKind::MultigridCG_Matfree, 1.5, knock, true,
            (double)g.solid_count());
        margin_v = a.margin.worst_case;
        acc_v = a.accepted;
      } catch (const std::exception& e) {
        std::fprintf(stderr, "  variant contrast=%s FAILED: %s\n",
                     kContrastName[ci], e.what());
        continue;
      }
      const std::vector<char> cv = classify(rho_v);
      int changed = 0;
      for (std::size_t i = 0; i < cv.size(); ++i)
        if (cv[i] != cbase[i]) ++changed;
      const int solid_v = (int)std::count(cv.begin(), cv.end(), (char)1);
      // frac of SOLID voxels changing classification (denominator = baseline solids)
      const double frac = solid_base > 0 ? (double)changed / (double)solid_base : 0.0;
      const int msign = margin_v > margin_base ? 1 : (margin_v < margin_base ? -1 : 0);

      std::printf("   %-8s %-9.2e %-4s | %8d %8d %7d | %8.4f %8.4f %4s\n",
                  kContrastName[ci], dmin, negctrl ? "NEG" : "", solid_base,
                  solid_v, changed, margin_base, margin_v,
                  acc_v ? "acc" : "REJ");
      if (f)
        std::fprintf(f,
                     "%.2f,%s,%.6e,%d,%d,%d,%d,%d,%d,%d,%.6f,%.6f,%.6f,%d,%d,%d,%.6g\n",
                     vf, kContrastName[ci], dmin, negctrl ? 1 : 0, g.nx, g.ny,
                     g.nz, solid_base, solid_v, changed, frac, margin_base,
                     margin_v, msign, acc_base ? 1 : 0, acc_v ? 1 : 0, compl_v);
    }
  }
  if (f) std::fclose(f);
}

}  // namespace

int main() {
  std::setvbuf(stdout, nullptr, _IOLBF, 0);  // line-buffered: live progress
  const Material mat = fdm_material();
  const int nx = env_int("TOPOPT_COND_NX", 32);
  const int ny = env_int("TOPOPT_COND_NY", 16);
  const int nz = env_int("TOPOPT_COND_NZ", 32);
  const double h = 2.0;
  const char* phase = std::getenv("TOPOPT_COND_PHASE");
  const std::string ph = phase ? phase : "all";

  // Production derives the voxel filter radius from a physical min-feature length
  // (2.5 mm) and grid spacing; mirror that so the design is representative.
  const double filter_radius = std::max(1.5, 2.5 / h);

  std::vector<DirichletBC> bcs;
  VoxelGrid g = design_box_fixture(nx, ny, nz, h, bcs);
  const std::vector<NodalLoad> loads =
      traction_loads(g, VoxelTag::Load, Vec3{0.0, 0.0, -30.0});

  std::printf("conditioning_probe: grid %dx%dx%d solids=%zu (occ=%.3f) filter_r=%.2f phase=%s\n",
              nx, ny, nz, g.solid_count(),
              (double)g.solid_count() / (double)g.voxel_count(), filter_radius,
              ph.c_str());

  std::vector<RungField> fields;
  if (ph == "all" || ph == "cond" || ph == "combo") {
    std::printf("\n--- baseline simp_optimize per rung (density_min=1e-3 => contrast 1e-9) ---\n");
    fields = baseline_fields(g, bcs, loads, mat, filter_radius);
  }

  if (ph == "all" || ph == "cond") phase_cond(g, bcs, loads, mat, filter_radius, fields);
  if (ph == "all" || ph == "combo") phase_combo(g, bcs, loads, mat, fields);
  if (ph == "upsample") phase_upsample(mat, h);
  if (ph == "all" || ph == "design") phase_design(g, bcs, loads, mat, filter_radius);

  std::printf("\nconditioning_probe: done.\n");
  return 0;
}
