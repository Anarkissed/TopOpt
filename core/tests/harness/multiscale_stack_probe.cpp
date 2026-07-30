// multiscale_stack_probe — measurement harness for the MULTISCALE PRODUCTION
// WIRING (handoff 2026-08-01-multiscale-production-wiring).
//
// The production change under test: fea_solve_cg_lattice routes (opt-in,
// library default OFF, production ARMED) to the matrix-free cubic path —
// combined-block three-block kernel, Galerkin multigrid over the decomposed
// coarse blocks, GenEO deflation with the tensor-aware moduli fingerprint,
// Krylov recycling. This harness measures the bars the handoff reports:
//
//   I3  the gate table (verdict + margin) for certified designs, assembled
//       route vs armed matrix-free route, against a 1e-9 negative-control
//       perturbation floor; and design-field classification flips of the
//       accelerated loop against the same control floor.
//   I6  CG counts per design iteration for plain / +multigrid / +GenEO /
//       +recycling / full stack, in BOTH regimes (mild plain-lattice phase and
//       the sharpened p=3/p=6 gap-curve phases) of a real multiscale loop.
//   I7  the four-way interaction GenEO x recycling x draft x active-domain on
//       the cubic operator (2^4 grid, shortened schedule).
//   I8  per-apply cost of the cubic operator on this grid + the NET cost per
//       design iteration against the I6 iteration counts.
//   I9  memory: coefficient arrays + cubic element table + reference blocks on
//       this grid, projected to 8.44M DOF.
//   I10 determinism: byte-identical rerun (FNV over the final field and the
//       full CG trace) at every I6 configuration + the full four-way stack.
//
// The optimizer loop is the PR 255 probe's own OC loop (lattice_gap_probe
// shape) with the s3 continuation schedule (plain -> gap-penalty p=3 -> p=6),
// on the measured octet material model C(rho). The in-loop solver is the
// PRODUCTION matrix-free cubic path (public entry for MG configs; the internal
// mf_build_reduced/mf_cg_solve pair for the Jacobi-regime decomposition rows,
// which is where GenEO and recycling live in production).
//
// Build (repo root):
//   c++ -std=c++17 -O2 -I core/include -I core/src -I core/tests/harness \
//       core/tests/harness/multiscale_stack_probe.cpp core/build/libtopopt.a \
//       -o core/build/multiscale_stack_probe
//   ./core/build/multiscale_stack_probe [i3|i6|i7|i8|i9|all] [evidence-dir]

#include <algorithm>
#include <array>
#include <chrono>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <functional>
#include <string>
#include <vector>

#include "topopt/analyze.hpp"
#include "topopt/fea.hpp"
#include "topopt/lattice.hpp"
#include "topopt/materials.hpp"
#include "topopt/simp.hpp"
#include "topopt/voxel.hpp"

#include "fea/fea_matfree.hpp"
#include "fea/geneo.hpp"
#include "lattice_material_model.hpp"

using namespace topopt;
using lmm::LatticeMaterialModel;

namespace {

// --------------------------------------------------------------------------
// Fixture: the PR 255 cantilever, deepened to 8 voxels in z so the matrix-free
// multigrid hierarchy builds (48x24x8 elements -> 24x12x4 -> ...). 33,075 DOF.
// --------------------------------------------------------------------------
constexpr int kNx = 48, kNy = 24, kNz = 8;
constexpr double kSpacing = 1.0;
constexpr double kEs = 3500.0;
constexpr double kNu = 0.33;
constexpr double kVolFrac = 0.35;
constexpr double kMove = 0.2;
constexpr double kFilterRadius = 1.5;
constexpr double kCgTolLoop = 1e-6;
constexpr double kCgTolDraft = 1e-3;   // the draft loose in-loop tolerance
constexpr double kCgTolCert = 1e-8;
constexpr double kEpsFloor = 1e-6;
constexpr double kTipLoadTotal = -200.0;
constexpr double kVoidTol = 1e-3;

struct Fnv {
  std::uint64_t h = 1469598103934665603ULL;
  void add(const void* p, std::size_t n) {
    const auto* b = static_cast<const unsigned char*>(p);
    for (std::size_t i = 0; i < n; ++i) {
      h ^= b[i];
      h *= 1099511628211ULL;
    }
  }
};

VoxelGrid make_grid() {
  VoxelGrid g;
  g.nx = kNx;
  g.ny = kNy;
  g.nz = kNz;
  g.spacing = kSpacing;
  g.origin = Vec3{0, 0, 0};
  g.tags.assign(static_cast<std::size_t>(kNx) * kNy * kNz, VoxelTag::Interior);
  return g;
}

void make_bcs_loads(const VoxelGrid& g, std::vector<DirichletBC>& bcs,
                    std::vector<NodalLoad>& loads, double load_scale = 1.0) {
  for (int j = 0; j < g.ny; ++j)
    for (int k = 0; k < g.nz; ++k) {
      const std::array<int, 8> en = fea_element_nodes(g, 0, j, k);
      for (int n : {en[0], en[3], en[4], en[7]})
        for (int c = 0; c < 3; ++c) bcs.push_back({n, c, 0.0});
    }
  std::sort(bcs.begin(), bcs.end(),
            [](const DirichletBC& a, const DirichletBC& b) {
              return a.node != b.node ? a.node < b.node
                                      : a.component < b.component;
            });
  bcs.erase(std::unique(bcs.begin(), bcs.end(),
                        [](const DirichletBC& a, const DirichletBC& b) {
                          return a.node == b.node && a.component == b.component;
                        }),
            bcs.end());
  std::vector<int> tip;
  for (int k = 0; k <= g.nz; ++k) {
    const int node = ((k * (g.ny + 1)) + g.ny / 2) * (g.nx + 1) + g.nx;
    tip.push_back(node);
  }
  for (int n : tip)
    loads.push_back(
        {n, 1, load_scale * kTipLoadTotal / static_cast<double>(tip.size())});
}

// --------------------------------------------------------------------------
// Material strategies (PR 255 shapes): plain C(rho) and gap-penalised p-curve.
// --------------------------------------------------------------------------
using MaterialFn = std::function<void(double rho, double C[3], double D[3])>;

MaterialFn plain_material(const LatticeMaterialModel& m) {
  return [&m](double rho, double C[3], double D[3]) {
    m.eval_components(std::clamp(rho, 0.0, 1.0), C, D);
    for (int i = 0; i < 3; ++i) C[i] += kEpsFloor * m.solid[i];
  };
}

MaterialFn gappen_material(const LatticeMaterialModel& m, double p) {
  return [&m, p](double rho, double C[3], double D[3]) {
    const double r = std::clamp(rho, 0.0, 1.0);
    if (r < m.rho_lo) {
      const double t = r / m.rho_lo;
      const double tp = std::pow(t, p);
      const double dtp = r > 0 ? p * tp / r : 0.0;
      for (int i = 0; i < 3; ++i) {
        C[i] = m.v_lo[i] * tp + kEpsFloor * m.solid[i];
        D[i] = m.v_lo[i] * dtp;
      }
      return;
    }
    if (r > m.rho_hi) {
      const double L = 1.0 - m.rho_hi;
      const double t = (r - m.rho_hi) / L;
      const double tp = std::pow(t, p);
      const double dtp = t > 0 ? p * tp / (t * L) : 0.0;
      for (int i = 0; i < 3; ++i) {
        C[i] = m.v_hi[i] + (m.solid[i] - m.v_hi[i]) * tp + kEpsFloor * m.solid[i];
        D[i] = (m.solid[i] - m.v_hi[i]) * dtp;
      }
      return;
    }
    m.eval_components(r, C, D);
    for (int i = 0; i < 3; ++i) C[i] += kEpsFloor * m.solid[i];
  };
}

// --------------------------------------------------------------------------
// Solver configuration for one loop run.
// --------------------------------------------------------------------------
struct SolverCfg {
  bool use_mg = false;       // multigrid-first (the public armed entry)
  bool use_geneo = false;    // GenEO deflation on the Jacobi regime
  bool use_recycle = false;  // Krylov recycling on the Jacobi regime
  bool draft = false;        // loose in-loop tolerance (1e-3 vs 1e-6)
  bool ad = false;           // active-domain band mask on the trajectory solves
};

// Per-solve diagnostics of one in-loop solve.
struct SolveDiag {
  int cg_iters = 0;
  int used_mg = 0;
  int geneo_action = 0;
  int geneo_dim = 0;
  int recycle_dim = 0;
};

struct SolveOut {
  double compliance = 0.0;
  SolveDiag diag;
  std::vector<double> qA, qB, qC;
  FeaSolution sol;
  bool ok = false;
};

// Active-domain band mask (harness mirror of the production trajectory band):
// material voxels (rho > 2*void tolerance) dilated by k = ceil(rmin) + 1 = 3
// in Chebyshev distance. Applied to trajectory solves only, never the cert.
std::vector<char> ad_band_mask(const VoxelGrid& g, const std::vector<double>& rho) {
  const int band = static_cast<int>(std::ceil(kFilterRadius)) + 1;
  std::vector<char> mat(g.voxel_count(), 0), mask(g.voxel_count(), 0);
  for (std::size_t e = 0; e < rho.size(); ++e) mat[e] = rho[e] > 2.0 * kVoidTol;
  for (int k = 0; k < g.nz; ++k)
    for (int j = 0; j < g.ny; ++j)
      for (int i = 0; i < g.nx; ++i) {
        bool near = false;
        for (int dk = -band; dk <= band && !near; ++dk)
          for (int dj = -band; dj <= band && !near; ++dj)
            for (int di = -band; di <= band && !near; ++di) {
              const int ni = i + di, nj = j + dj, nk = k + dk;
              if (ni < 0 || nj < 0 || nk < 0 || ni >= g.nx || nj >= g.ny ||
                  nk >= g.nz)
                continue;
              if (mat[g.index(ni, nj, nk)]) near = true;
            }
        mask[g.index(i, j, k)] = near ? 1 : 0;
      }
  return mask;
}

// One in-loop compliance solve on the matrix-free cubic operator.
SolveOut solve_design_mf(const VoxelGrid& g, const MaterialFn& mat,
                         const std::vector<double>& rho,
                         const std::vector<DirichletBC>& bcs,
                         const std::vector<NodalLoad>& loads, double tol,
                         const SolverCfg& cfg,
                         const std::vector<char>* active_mask) {
  const std::size_t n = g.voxel_count();
  std::vector<double> c11(n), c12(n), c44(n), youngs(n, 1.0);
  std::vector<char> mask(n, 1);
  double C[3], D[3];
  for (std::size_t e = 0; e < n; ++e) {
    mat(rho[e], C, D);
    c11[e] = C[0];
    c12[e] = C[1];
    c44[e] = C[2];
  }
  SolveOut out;
  const int ndof = 3 * fea_node_count(g);
  CgInfo info;
  try {
    if (cfg.use_mg) {
      out.sol = fea_solve_cg_lattice_matfree(g, youngs, mask, c11, c12, c44,
                                             kNu, bcs, loads, tol, 200000,
                                             &info, active_mask);
      out.diag.cg_iters = info.iterations;
      out.diag.used_mg = info.used_multigrid ? 1 : 0;
      out.diag.geneo_action = info.geneo_action;
      out.diag.geneo_dim = info.geneo_dim;
      out.diag.recycle_dim = info.recycle_dim;
    } else {
      // Jacobi-regime decomposition row: the internal pair the production
      // fallback runs, without the MG attempt.
      fea_detail::MfLatticeArrays lat;
      lat.mask = &mask;
      lat.c11 = &c11;
      lat.c12 = &c12;
      lat.c44 = &c44;
      fea_detail::MatfreeReduced m = fea_detail::mf_build_reduced(
          g, 1.0, kNu, bcs, loads, &youngs, "multiscale_stack_probe", &info,
          active_mask, &lat);
      std::vector<double> x(static_cast<std::size_t>(m.ng), 0.0);
      fea_detail::MfSolveContext ctx;
      ctx.grid = &g;
      ctx.elem_youngs = &youngs;
      ctx.poisson = kNu;
      ctx.lattice = lat;
      fea_detail::RecycleReport rec;
      int iters = 0;
      double err = 0.0;
      bool conv = false;
      fea_detail::mf_cg_solve(m, tol, 400000, x, iters, err, conv, &rec, &ctx);
      if (!conv) return out;
      out.sol.u.assign(m.up.begin(), m.up.end());
      for (int k = 0; k < m.ng; ++k)
        out.sol.u[static_cast<std::size_t>(
            m.kept_global[static_cast<std::size_t>(k)])] =
            x[static_cast<std::size_t>(k)];
      out.diag.cg_iters = iters;
      const fea_detail::GeneoReport gr = fea_detail::geneo_last_report();
      out.diag.geneo_action = gr.action;
      out.diag.geneo_dim = gr.dim;
      out.diag.recycle_dim = rec.dim;
    }
  } catch (const std::exception& ex) {
    std::fprintf(stderr, "solve failed: %s\n", ex.what());
    return out;
  }
  for (const NodalLoad& l : loads)
    out.compliance += l.value * out.sol.u[3 * l.node + l.component];

  // Element energies against the PRODUCTION reference blocks (sensitivities).
  Hex8Stiffness KA, KB, KC;
  fea_detail::hex8_cubic_reference_blocks(g.spacing, KA, KB, KC);
  out.qA.assign(n, 0.0);
  out.qB.assign(n, 0.0);
  out.qC.assign(n, 0.0);
  constexpr int kDof = Hex8Stiffness::kDof;
  (void)ndof;
  for (int k = 0; k < g.nz; ++k)
    for (int j = 0; j < g.ny; ++j)
      for (int i = 0; i < g.nx; ++i) {
        const std::array<int, 8> en = fea_element_nodes(g, i, j, k);
        double ue[kDof];
        for (int a = 0; a < 8; ++a)
          for (int c = 0; c < 3; ++c) ue[3 * a + c] = out.sol.u[3 * en[a] + c];
        double qa = 0.0, qb = 0.0, qc = 0.0;
        for (int r = 0; r < kDof; ++r) {
          double ra = 0.0, rb = 0.0, rc = 0.0;
          const std::size_t off = static_cast<std::size_t>(r) * kDof;
          for (int s = 0; s < kDof; ++s) {
            ra += KA.k[off + s] * ue[s];
            rb += KB.k[off + s] * ue[s];
            rc += KC.k[off + s] * ue[s];
          }
          qa += ue[r] * ra;
          qb += ue[r] * rb;
          qc += ue[r] * rc;
        }
        const std::size_t e = g.index(i, j, k);
        out.qA[e] = qa;
        out.qB[e] = qb;
        out.qC[e] = qc;
      }
  out.ok = true;
  return out;
}

// --------------------------------------------------------------------------
// OC updater (PR 255 probe's own).
// --------------------------------------------------------------------------
std::vector<double> oc_step(const DensityFilter& filter,
                            const std::vector<double>& x,
                            const std::vector<double>& dc_dx,
                            const std::vector<double>& dv_dx, double vol_target,
                            double move) {
  const std::size_t n = x.size();
  std::vector<double> xn(n);
  auto try_lambda = [&](double lam) {
    for (std::size_t e = 0; e < n; ++e) {
      const double b =
          std::max(0.0, -dc_dx[e]) / (lam * std::max(dv_dx[e], 1e-30));
      double v = x[e] * std::sqrt(b);
      v = std::clamp(v, x[e] - move, x[e] + move);
      xn[e] = std::clamp(v, 0.0, 1.0);
    }
    const std::vector<double> phys = filter.filter_density(xn);
    double vol = 0.0;
    for (double r : phys) vol += r;
    return vol;
  };
  double l1 = 1e-12, l2 = 1e12;
  for (int it = 0; it < 120 && (l2 - l1) / (l1 + l2) > 1e-6; ++it) {
    const double lm = std::sqrt(l1 * l2);
    if (try_lambda(lm) > vol_target) l1 = lm;
    else l2 = lm;
  }
  try_lambda(std::sqrt(l1 * l2));
  return xn;
}

struct Phase {
  const char* name;
  MaterialFn mat;
  int iters;
  double move;
};

struct RunResult {
  std::vector<double> rho;              // final physical density
  double compliance = 0.0;
  std::vector<SolveDiag> trace;         // one per solve
  std::vector<int> phase_of_iter;
  bool ok = true;
};

// One full loop run under a solver configuration. Resets all carried solver
// state at entry so runs are independent and reproducible.
RunResult run_loop(const VoxelGrid& g, const DensityFilter& filter,
                   const std::vector<Phase>& phases,
                   const std::vector<DirichletBC>& bcs,
                   const std::vector<NodalLoad>& loads, const SolverCfg& cfg,
                   FILE* trace_csv, const char* cfg_name) {
  fea_set_geneo_twolevel(cfg.use_geneo);
  fea_reset_geneo_basis();
  fea_set_krylov_recycling(cfg.use_recycle);
  fea_reset_krylov_recycle_space();
  fea_matfree_reset_mg_stagnation_latch();

  const std::size_t n = g.voxel_count();
  const double vol_target = kVolFrac * static_cast<double>(n);
  RunResult res;
  std::vector<double> x(n, kVolFrac);
  const double tol = cfg.draft ? kCgTolDraft : kCgTolLoop;
  int iter_global = 0;
  for (std::size_t ph = 0; ph < phases.size(); ++ph) {
    const Phase& phase = phases[ph];
    for (int it = 0; it < phase.iters; ++it, ++iter_global) {
      res.rho = filter.filter_density(x);
      std::vector<char> mask_store;
      const std::vector<char>* amask = nullptr;
      if (cfg.ad) {
        mask_store = ad_band_mask(g, res.rho);
        amask = &mask_store;
      }
      const SolveOut s =
          solve_design_mf(g, phase.mat, res.rho, bcs, loads, tol, cfg, amask);
      if (!s.ok) {
        std::fprintf(stderr, "%s: solve failed, aborting run\n", cfg_name);
        res.ok = false;
        break;
      }
      res.compliance = s.compliance;
      res.trace.push_back(s.diag);
      res.phase_of_iter.push_back(static_cast<int>(ph));
      std::vector<double> dc_drho(n), one(n, 1.0);
      double C[3], D[3];
      for (std::size_t e = 0; e < n; ++e) {
        phase.mat(res.rho[e], C, D);
        dc_drho[e] = -(D[0] * s.qA[e] + D[1] * s.qB[e] + D[2] * s.qC[e]);
      }
      const std::vector<double> dc_dx = filter.filter_sensitivity(dc_drho);
      const std::vector<double> dv_dx = filter.filter_sensitivity(one);
      x = oc_step(filter, x, dc_dx, dv_dx, vol_target, phase.move);
      if (trace_csv)
        std::fprintf(trace_csv, "%s,%s,%d,%.8e,%d,%d,%d,%d,%d\n", cfg_name,
                     phase.name, iter_global, s.compliance, s.diag.cg_iters,
                     s.diag.used_mg, s.diag.geneo_action, s.diag.geneo_dim,
                     s.diag.recycle_dim);
    }
    if (!res.ok) break;
  }
  res.rho = filter.filter_density(x);
  // Leave the globals as the library defaults for the next section.
  fea_set_geneo_twolevel(false);
  fea_reset_geneo_basis();
  fea_set_krylov_recycling(false);
  fea_reset_krylov_recycle_space();
  fea_matfree_reset_mg_stagnation_latch();
  return res;
}

std::vector<Phase> schedule(const LatticeMaterialModel& m, int a, int b, int c) {
  return {{"plain", plain_material(m), a, kMove},
          {"p3", gappen_material(m, 3.0), b, kMove},
          {"p6", gappen_material(m, 6.0), c, 0.1}};
}

std::vector<double> snap_to_feasible(const std::vector<double>& rho, double lo,
                                     double hi) {
  std::vector<double> out(rho.size());
  for (std::size_t e = 0; e < rho.size(); ++e) {
    const double r = rho[e];
    double s = r;
    if (r <= kVoidTol) s = 0.0;
    else if (r < lo) s = (r < lo / 2.0) ? 0.0 : lo;
    else if (r <= hi) s = r;
    else if (r >= 1.0 - kVoidTol) s = 1.0;
    else s = (r - hi < 1.0 - r) ? hi : 1.0;
    out[e] = s;
  }
  return out;
}

Material pla_material() {
  Material m;
  m.youngs_modulus_mpa = kEs;
  m.yield_strength_mpa = 55.0;
  m.density_g_cm3 = 1.24;
  m.z_knockdown = 0.55;
  m.poisson = kNu;
  m.family = "fdm";
  return m;
}

// Certify a snapped graded field through the REAL gate; returns a CSV row.
struct GateRow {
  std::string verdict;
  double margin_worst = 0.0, margin_eff = 0.0, max_vm = 0.0, lat_max_vm = 0.0;
  std::size_t lattice_voxels = 0;
  int non_conv = 0;
};

GateRow gate_certify(const VoxelGrid& g, const std::vector<double>& rho_feasible,
                     const std::vector<DirichletBC>& bcs,
                     const std::vector<NodalLoad>& loads) {
  const std::size_t n = g.voxel_count();
  std::vector<double> density(n, 0.0);
  LatticePosture post;
  post.topology = LatticeTopology::Octet;
  post.cell_size_mm = 4.0;
  post.mask.assign(n, 0);
  post.relative_density.assign(n, 0.0);
  for (std::size_t e = 0; e < n; ++e) {
    if (rho_feasible[e] <= 0.0) continue;
    density[e] = 1.0;
    if (rho_feasible[e] < 1.0) {
      post.mask[e] = 1;
      post.relative_density[e] = rho_feasible[e];
    }
  }
  const Material mat = pla_material();
  SimpParams params;
  params.youngs_modulus = mat.youngs_modulus_mpa;
  params.poisson = mat.poisson;
  params.penalty = 3.0;
  const Vec3 build_dir{0, 0, 1};
  const KnockdownSpec kd;
  GateRow row;
  try {
    const FixedDesignAnalysis a = analyze_fixed_design(
        g, params, density, bcs, loads, mat, build_dir, kCgTolCert, 0,
        SolverKind::JacobiCG, 0.5, kd, true,
        static_cast<double>(g.solid_count()), &post);
    row.verdict = a.accepted ? "ACCEPTED" : "REJECTED";
    row.margin_worst = a.margin.worst_case;
    row.margin_eff = a.margin_effective;
    row.max_vm = a.max_von_mises;
    row.lat_max_vm = a.lattice_max_effective_vm;
    row.lattice_voxels = a.lattice_voxels;
    row.non_conv = a.non_convergent ? 1 : 0;
  } catch (const LatticeDensityOutOfBand& e) {
    row.verdict = std::string("REFUSED_E5(rho=") + std::to_string(e.rho) + ")";
  } catch (const std::exception& e) {
    row.verdict = std::string("THREW(") + e.what() + ")";
  }
  return row;
}

FILE* open_out(const std::string& dir, const char* name) {
  const std::string p = dir + "/" + name;
  FILE* f = std::fopen(p.c_str(), "w");
  if (!f) {
    std::fprintf(stderr, "cannot open %s\n", p.c_str());
    std::exit(1);
  }
  return f;
}

double now_ms() {
  return std::chrono::duration<double, std::milli>(
             std::chrono::steady_clock::now().time_since_epoch())
      .count();
}

std::uint64_t fnv_rho(const std::vector<double>& rho) {
  Fnv f;
  f.add(rho.data(), rho.size() * sizeof(double));
  return f.h;
}
std::uint64_t fnv_trace(const std::vector<SolveDiag>& t) {
  Fnv f;
  for (const SolveDiag& d : t) f.add(&d, sizeof d);
  return f.h;
}

struct Ctx {
  VoxelGrid g;
  DensityFilter filter;
  std::vector<DirichletBC> bcs;
  std::vector<NodalLoad> loads;
  LatticeMaterialModel model;
};

Ctx make_ctx() {
  VoxelGrid g = make_grid();
  DensityFilter filter = make_density_filter(g, kFilterRadius);
  std::vector<DirichletBC> bcs;
  std::vector<NodalLoad> loads;
  make_bcs_loads(g, bcs, loads);
  return Ctx{std::move(g), std::move(filter), std::move(bcs), std::move(loads),
             lmm::build_lattice_material_model(LatticeTopology::Octet, kEs, kNu)};
}

// The five I6 configurations.
struct NamedCfg {
  const char* name;
  SolverCfg cfg;
};
std::vector<NamedCfg> i6_configs() {
  return {
      {"plain", {}},
      {"mg", {/*mg*/ true, false, false, false, false}},
      {"geneo", {false, /*geneo*/ true, false, false, false}},
      {"recycle", {false, false, /*recycle*/ true, false, false}},
      {"full", {/*mg*/ true, /*geneo*/ true, /*recycle*/ true, false, false}},
  };
}

void phase_summary(FILE* out, const char* cfg_name, const RunResult& r,
                   const std::vector<Phase>& phases) {
  for (std::size_t ph = 0; ph < phases.size(); ++ph) {
    long long total = 0;
    int mn = 1 << 30, mx = 0, cnt = 0, mg_solves = 0, geneo_solves = 0;
    for (std::size_t t = 0; t < r.trace.size(); ++t) {
      if (r.phase_of_iter[t] != static_cast<int>(ph)) continue;
      const int it = r.trace[t].cg_iters;
      total += it;
      mn = std::min(mn, it);
      mx = std::max(mx, it);
      ++cnt;
      mg_solves += r.trace[t].used_mg;
      geneo_solves += r.trace[t].geneo_action > 0 ? 1 : 0;
    }
    if (cnt == 0) continue;
    std::fprintf(out, "%s,%s,%d,%d,%.1f,%d,%lld,%d,%d\n", cfg_name,
                 phases[ph].name, cnt, mn,
                 static_cast<double>(total) / cnt, mx, total, mg_solves,
                 geneo_solves);
  }
}

// ===========================================================================
// I6 + I10: the five configurations, full s3 schedule, duplicated rerun.
// ===========================================================================
int run_i6(const std::string& ev, Ctx& ctx) {
  std::printf("=== I6: accelerators in the loop (both regimes) + I10 ===\n");
  const std::vector<Phase> phases = schedule(ctx.model, 40, 40, 40);
  FILE* trace = open_out(ev, "i6_traces.csv");
  std::fprintf(trace, "config,phase,iter,compliance,cg_iters,used_mg,"
                      "geneo_action,geneo_dim,recycle_dim\n");
  FILE* summary = open_out(ev, "i6_summary.csv");
  std::fprintf(summary, "config,phase,solves,cg_min,cg_mean,cg_max,cg_total,"
                        "mg_solves,geneo_engaged_solves\n");
  FILE* det = open_out(ev, "i10_determinism.csv");
  std::fprintf(det, "config,fnv_rho_run1,fnv_rho_run2,fnv_trace_run1,"
                    "fnv_trace_run2,match\n");
  FILE* fields = open_out(ev, "i6_final_fields.csv");
  std::fprintf(fields, "config,e,rho\n");

  int rc = 0;
  for (const NamedCfg& nc : i6_configs()) {
    std::printf("-- config %s --\n", nc.name);
    const double t0 = now_ms();
    RunResult r1 = run_loop(ctx.g, ctx.filter, phases, ctx.bcs, ctx.loads,
                            nc.cfg, trace, nc.name);
    const double t1 = now_ms();
    RunResult r2 = run_loop(ctx.g, ctx.filter, phases, ctx.bcs, ctx.loads,
                            nc.cfg, nullptr, nc.name);
    if (!r1.ok || !r2.ok) { rc = 1; continue; }
    phase_summary(summary, nc.name, r1, phases);
    const std::uint64_t h1 = fnv_rho(r1.rho), h2 = fnv_rho(r2.rho);
    const std::uint64_t t1h = fnv_trace(r1.trace), t2h = fnv_trace(r2.trace);
    const bool match = h1 == h2 && t1h == t2h;
    std::fprintf(det, "%s,%016llx,%016llx,%016llx,%016llx,%d\n", nc.name,
                 static_cast<unsigned long long>(h1),
                 static_cast<unsigned long long>(h2),
                 static_cast<unsigned long long>(t1h),
                 static_cast<unsigned long long>(t2h), match ? 1 : 0);
    if (!match) rc = 1;
    long long tot = 0;
    for (const SolveDiag& d : r1.trace) tot += d.cg_iters;
    std::printf("  total CG %lld, wall %.1f s, deterministic rerun: %s\n", tot,
                (t1 - t0) / 1000.0, match ? "byte-identical" : "MISMATCH");
    for (std::size_t e = 0; e < r1.rho.size(); ++e)
      if (r1.rho[e] > 1e-12)
        std::fprintf(fields, "%s,%zu,%.9f\n", nc.name, e, r1.rho[e]);
  }
  std::fclose(trace);
  std::fclose(summary);
  std::fclose(det);
  std::fclose(fields);
  return rc;
}

// ===========================================================================
// I7: the 2^4 four-way interaction on the cubic operator (shortened schedule).
// ===========================================================================
int run_i7(const std::string& ev, Ctx& ctx) {
  std::printf("=== I7: four-way interaction geneo x recycle x draft x AD ===\n");
  const std::vector<Phase> phases = schedule(ctx.model, 20, 20, 20);
  FILE* four = open_out(ev, "i7_fourway.csv");
  std::fprintf(four, "geneo,recycle,draft,ad,phase,solves,cg_mean,cg_total,"
                     "final_compliance,fnv_rho\n");
  FILE* det = open_out(ev, "i7_fullstack_determinism.csv");
  std::fprintf(det, "run,fnv_rho,fnv_trace\n");
  int rc = 0;
  for (int bits = 0; bits < 16; ++bits) {
    SolverCfg cfg;
    cfg.use_mg = true;  // production posture: MG-first; geneo/recycle on fallback
    cfg.use_geneo = bits & 1;
    cfg.use_recycle = bits & 2;
    cfg.draft = bits & 4;
    cfg.ad = bits & 8;
    char name[64];
    std::snprintf(name, sizeof name, "g%dr%dd%da%d", cfg.use_geneo ? 1 : 0,
                  cfg.use_recycle ? 1 : 0, cfg.draft ? 1 : 0, cfg.ad ? 1 : 0);
    std::printf("-- %s --\n", name);
    RunResult r = run_loop(ctx.g, ctx.filter, phases, ctx.bcs, ctx.loads, cfg,
                           nullptr, name);
    if (!r.ok) { rc = 1; continue; }
    for (std::size_t ph = 0; ph < phases.size(); ++ph) {
      long long total = 0;
      int cnt = 0;
      for (std::size_t t = 0; t < r.trace.size(); ++t) {
        if (r.phase_of_iter[t] != static_cast<int>(ph)) continue;
        total += r.trace[t].cg_iters;
        ++cnt;
      }
      if (cnt == 0) continue;
      std::fprintf(four, "%d,%d,%d,%d,%s,%d,%.1f,%lld,%.8e,%016llx\n",
                   cfg.use_geneo ? 1 : 0, cfg.use_recycle ? 1 : 0,
                   cfg.draft ? 1 : 0, cfg.ad ? 1 : 0, phases[ph].name, cnt,
                   static_cast<double>(total) / cnt, total, r.compliance,
                   static_cast<unsigned long long>(fnv_rho(r.rho)));
    }
    if (bits == 3) {  // geneo+recycle, no draft/AD: the armed production stack
      std::fprintf(det, "1,%016llx,%016llx\n",
                   static_cast<unsigned long long>(fnv_rho(r.rho)),
                   static_cast<unsigned long long>(fnv_trace(r.trace)));
      RunResult r2 = run_loop(ctx.g, ctx.filter, phases, ctx.bcs, ctx.loads,
                              cfg, nullptr, name);
      std::fprintf(det, "2,%016llx,%016llx\n",
                   static_cast<unsigned long long>(fnv_rho(r2.rho)),
                   static_cast<unsigned long long>(fnv_trace(r2.trace)));
      if (fnv_rho(r.rho) != fnv_rho(r2.rho)) rc = 1;
    }
  }
  std::fclose(four);
  std::fclose(det);
  return rc;
}

// ===========================================================================
// I3: the gate table, assembled route vs armed route vs negative control; and
// design-field flips of the accelerated loop against the control floor.
// ===========================================================================
int run_i3(const std::string& ev, Ctx& ctx) {
  std::printf("=== I3: gate table + classification flips vs control floor ===\n");
  const std::vector<Phase> phases = schedule(ctx.model, 40, 40, 40);
  const double lo = ctx.model.rho_lo, hi = ctx.model.rho_hi;

  // Designs: the plain loop's final field and the full-stack loop's final
  // field (snapped), plus the unsnapped refusal control.
  SolverCfg plain_cfg;
  SolverCfg full_cfg;
  full_cfg.use_mg = full_cfg.use_geneo = full_cfg.use_recycle = true;
  RunResult rp = run_loop(ctx.g, ctx.filter, phases, ctx.bcs, ctx.loads,
                          plain_cfg, nullptr, "plain");
  RunResult rf = run_loop(ctx.g, ctx.filter, phases, ctx.bcs, ctx.loads,
                          full_cfg, nullptr, "full");
  if (!rp.ok || !rf.ok) return 1;

  // Negative control: the SAME plain loop under a 1e-9 load perturbation.
  std::vector<DirichletBC> bcs_c;
  std::vector<NodalLoad> loads_c;
  make_bcs_loads(ctx.g, bcs_c, loads_c, 1.0 + 1e-9);
  RunResult rc_ctl = run_loop(ctx.g, ctx.filter, phases, bcs_c, loads_c,
                              plain_cfg, nullptr, "plain_ctl");
  if (!rc_ctl.ok) return 1;

  // Classification flips (void / lower-gap / band / upper-gap / solid).
  auto classify_of = [&](double r) {
    if (r <= kVoidTol) return 0;
    if (r < lo - 1e-9) return 1;
    if (r <= hi + 1e-9) return 2;
    if (r < 1.0 - kVoidTol) return 3;
    return 4;
  };
  auto flips = [&](const std::vector<double>& a, const std::vector<double>& b) {
    std::size_t nf = 0;
    double mx = 0, mean = 0;
    for (std::size_t e = 0; e < a.size(); ++e) {
      if (classify_of(a[e]) != classify_of(b[e])) ++nf;
      const double d = std::fabs(a[e] - b[e]);
      mx = std::max(mx, d);
      mean += d;
    }
    mean /= static_cast<double>(a.size());
    struct R { std::size_t nf; double mx, mean; };
    return R{nf, mx, mean};
  };
  const auto ctl = flips(rc_ctl.rho, rp.rho);
  const auto acc = flips(rf.rho, rp.rho);
  FILE* fl = open_out(ev, "i3_flips.csv");
  std::fprintf(fl, "comparison,n_class_flips,max_drho,mean_drho\n");
  std::fprintf(fl, "control_1e-9_vs_plain,%zu,%.3e,%.3e\n", ctl.nf, ctl.mx,
               ctl.mean);
  std::fprintf(fl, "fullstack_vs_plain,%zu,%.3e,%.3e\n", acc.nf, acc.mx,
               acc.mean);
  std::fclose(fl);
  std::printf("flips: control %zu (max|drho| %.3e) | full stack %zu "
              "(max|drho| %.3e)\n",
              ctl.nf, ctl.mx, acc.nf, acc.mx);

  // Gate table: each design, certified with the assembled route (toggle OFF),
  // the armed matrix-free route (toggle ON), and the assembled route under the
  // 1e-9 perturbed load (the margin control floor).
  FILE* gt = open_out(ev, "i3_gate_table.csv");
  std::fprintf(gt, "design,route,verdict,margin_worst,margin_effective,max_vm,"
                   "lattice_max_vm,lattice_voxels,non_convergent\n");
  struct Design {
    const char* name;
    std::vector<double> field;
  };
  std::vector<Design> designs;
  designs.push_back({"plain_snapped", snap_to_feasible(rp.rho, lo, hi)});
  designs.push_back({"fullstack_snapped", snap_to_feasible(rf.rho, lo, hi)});
  {
    // Unsnapped refusal control (gap voxels present): E5 must refuse on BOTH
    // routes — the band gate precedes the solve and is route-blind.
    std::vector<double> raw(rp.rho.size(), 0.0);
    for (std::size_t e = 0; e < rp.rho.size(); ++e)
      raw[e] = rp.rho[e] <= kVoidTol ? 0.0
               : rp.rho[e] >= 1.0 - kVoidTol ? 1.0 : rp.rho[e];
    designs.push_back({"plain_unsnapped", std::move(raw)});
  }
  const bool prev_route = fea_matfree_cubic_lattice_enabled();
  for (const Design& d : designs) {
    fea_set_matfree_cubic_lattice(false);
    const GateRow off = gate_certify(ctx.g, d.field, ctx.bcs, ctx.loads);
    fea_set_matfree_cubic_lattice(true);
    fea_reset_geneo_basis();
    fea_reset_krylov_recycle_space();
    fea_matfree_reset_mg_stagnation_latch();
    const GateRow armed = gate_certify(ctx.g, d.field, ctx.bcs, ctx.loads);
    fea_set_matfree_cubic_lattice(false);
    const GateRow ctlrow = gate_certify(ctx.g, d.field, bcs_c, loads_c);
    auto put = [&](const char* route, const GateRow& r) {
      std::fprintf(gt, "%s,%s,%s,%.9f,%.9f,%.6f,%.6f,%zu,%d\n", d.name, route,
                   r.verdict.c_str(), r.margin_worst, r.margin_eff, r.max_vm,
                   r.lat_max_vm, r.lattice_voxels, r.non_conv);
    };
    put("assembled_off", off);
    put("matfree_armed", armed);
    put("assembled_control_1e-9", ctlrow);
    std::printf("%s: OFF %s m=%.9f | ARMED %s m=%.9f | CTL m=%.9f\n", d.name,
                off.verdict.c_str(), off.margin_worst, armed.verdict.c_str(),
                armed.margin_worst, ctlrow.margin_worst);
  }
  fea_set_matfree_cubic_lattice(prev_route);
  std::fclose(gt);
  return 0;
}

// ===========================================================================
// I8 + I9: apply cost on this grid + memory.
// ===========================================================================
int run_i8_i9(const std::string& ev, Ctx& ctx) {
  std::printf("=== I8/I9: apply cost + memory on this grid ===\n");
  const VoxelGrid& g = ctx.g;
  const std::size_t n = g.voxel_count();
  const int ndof = 3 * fea_node_count(g);

  // All-cubic operator (octet 0.3) vs all-iso operator on the SAME grid.
  std::vector<double> youngs_iso(n, kEs), youngs_one(n, 1.0);
  std::vector<char> mask_all(n, 1), mask_none(n, 0);
  std::vector<double> c11(n), c12(n), c44(n), zero(n, 0.0);
  const CubicTensor T = lattice_cubic_tensor(LatticeTopology::Octet, 0.3, kEs);
  std::fill(c11.begin(), c11.end(), T.C11);
  std::fill(c12.begin(), c12.end(), T.C12);
  std::fill(c44.begin(), c44.end(), T.C44);

  std::vector<double> x(static_cast<std::size_t>(ndof));
  for (int d = 0; d < ndof; ++d)
    x[static_cast<std::size_t>(d)] = std::sin(0.01 * d) + 0.5;

  auto bench = [&](const std::function<void()>& apply) {
    for (int w = 0; w < 5; ++w) apply();
    std::vector<double> ts;
    for (int rep = 0; rep < 40; ++rep) {
      const double t0 = now_ms();
      apply();
      ts.push_back(now_ms() - t0);
    }
    std::sort(ts.begin(), ts.end());
    return ts[ts.size() / 2];
  };

  // Prebuilt element tables (the per-APPLY cost, PR 252's d3 discipline — the
  // build is once per solve, the apply once per CG iteration).
  std::vector<int> iso_off, cub_off;
  const std::vector<fea_detail::MfElem> iso_elems = fea_detail::mf_build_elems(
      g, &youngs_iso, "i8", &iso_off, nullptr);
  fea_detail::MfLatticeArrays lat;
  lat.mask = &mask_all;
  lat.c11 = &c11;
  lat.c12 = &c12;
  lat.c44 = &c44;
  const std::vector<fea_detail::MfCubElem> cub_elems =
      fea_detail::mf_build_cubic_elems(g, lat, "i8", &cub_off, nullptr);
  const Hex8Stiffness Ke_iso = hex8_stiffness(kEs, kNu, g.spacing);
  Hex8Stiffness KA, KB, KC;
  fea_detail::hex8_cubic_reference_blocks(g.spacing, KA, KB, KC);
  std::vector<double> y(static_cast<std::size_t>(ndof), 0.0);

  FILE* cost = open_out(ev, "i8_apply_cost.csv");
  std::fprintf(cost, "threads,kernel,median_ms,ratio_vs_scalar\n");
  for (int threads : {1, 0}) {
    const int prev = fea_set_matfree_threads(threads);
    const int eff = fea_matfree_thread_count();
    const double t_iso = bench(
        [&] { fea_detail::mf_apply_full(iso_elems, iso_off, Ke_iso, x, y); });
    const double t_cub = bench([&] {
      std::fill(y.begin(), y.end(), 0.0);
      fea_detail::mf_apply_cubic_add(cub_elems, cub_off, KA, KB, KC, x, y);
    });
    std::fprintf(cost, "%d,scalar,%.4f,1.0\n", eff, t_iso);
    std::fprintf(cost, "%d,cubic_combined,%.4f,%.3f\n", eff, t_cub,
                 t_cub / t_iso);
    std::printf("threads=%d: scalar %.3f ms, cubic %.3f ms -> %.2fx\n", eff,
                t_iso, t_cub, t_cub / t_iso);
    fea_set_matfree_threads(prev);
  }
  std::fclose(cost);

  // I9: memory on this grid + the 8.44M-DOF projection, from the REAL structs.
  FILE* mem = open_out(ev, "i9_memory.csv");
  const std::size_t cub_elem_bytes = sizeof(fea_detail::MfCubElem);
  const std::size_t iso_elem_bytes = sizeof(fea_detail::MfElem);
  const double coeff_this = 3.0 * static_cast<double>(n) * 8.0;
  const double table_this = static_cast<double>(n) * cub_elem_bytes;
  const double blocks = 3.0 * 576 * 8.0;
  const double nvox_prod = 8.44e6 / 3.0;
  std::fprintf(mem, "item,bytes_this_grid,mb_this_grid,mb_at_8.44M_dof\n");
  std::fprintf(mem, "coeff_arrays,%zu,%.2f,%.1f\n",
               static_cast<std::size_t>(coeff_this), coeff_this / 1048576.0,
               3.0 * nvox_prod * 8.0 / 1048576.0);
  std::fprintf(mem, "cubic_elem_table_all_cubic,%zu,%.2f,%.1f\n",
               static_cast<std::size_t>(table_this), table_this / 1048576.0,
               nvox_prod * cub_elem_bytes / 1048576.0);
  std::fprintf(mem, "elem_table_delta_vs_iso,%zu,%.2f,%.1f\n",
               static_cast<std::size_t>(n) * (cub_elem_bytes - iso_elem_bytes),
               static_cast<double>(n) * (cub_elem_bytes - iso_elem_bytes) /
                   1048576.0,
               nvox_prod * (cub_elem_bytes - iso_elem_bytes) / 1048576.0);
  std::fprintf(mem, "reference_blocks_extra,%zu,%.4f,%.4f\n",
               static_cast<std::size_t>(2.0 * 576 * 8.0), 2.0 * 576 * 8.0 / 1048576.0,
               2.0 * 576 * 8.0 / 1048576.0);
  std::fclose(mem);
  std::printf("MfCubElem = %zu B (MfElem %zu B); blocks %.1f KB; coeff arrays "
              "at 8.44M DOF: %.1f MB\n",
              cub_elem_bytes, iso_elem_bytes, blocks / 1024.0,
              3.0 * nvox_prod * 8.0 / 1048576.0);
  return 0;
}

}  // namespace

int main(int argc, char** argv) {
  const std::string mode = argc > 1 ? argv[1] : "all";
  const std::string ev = argc > 2 ? argv[2] : ".";
  Ctx ctx = make_ctx();
  std::printf("fixture %dx%dx%d (%d DOF), octet band [%.4f, %.4f]\n", kNx, kNy,
              kNz, 3 * fea_node_count(ctx.g), ctx.model.rho_lo,
              ctx.model.rho_hi);
  int rc = 0;
  if (mode == "i6" || mode == "all") rc |= run_i6(ev, ctx);
  if (mode == "i7" || mode == "all") rc |= run_i7(ev, ctx);
  if (mode == "i3" || mode == "all") rc |= run_i3(ev, ctx);
  if (mode == "i8" || mode == "i9" || mode == "all") rc |= run_i8_i9(ev, ctx);
  return rc;
}
