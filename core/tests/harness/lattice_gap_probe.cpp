// lattice_gap_probe — PART 2 of the multiscale-lattice-feasibility PROBE
// (2026-07-31-multiscale-lattice-feasibility): the FORBIDDEN-INTERVAL
// feasibility question, on OCTET (the only generatable topology).
//
// THE PROBLEM. With the measured lattice material model C(rho) (harness header
// lattice_material_model.hpp) intermediate density is REALISABLE, so SIMP's
// rho^p penalisation comes out. But the certified band does not reach 0 or 1:
// the feasible set is {0} U [rho_lo, rho_hi] U {1} with TWO gaps (octet:
// (0, ~0.05) and (~0.90, 1) — read from core at runtime, never hardcoded).
// A gradient method can park voxels inside a gap, where the design is
// uncertifiable (the E5 gate REFUSES it) and unbuildable. This probe measures
// where each gap strategy actually parks voxels, on one fixed cantilever
// fixture, and takes the final designs to the REAL certification gate
// (analyze_fixed_design + LatticePosture) for a receipt.
//
// EVERYTHING is harness-side: production library linked UNMODIFIED; the
// optimizer loop below is the probe's own (OC update with the volume
// constraint enforced on the PHYSICAL density through the full
// filter->strategy chain); the in-loop solver is the PRODUCTION
// fea_solve_cg_lattice (per-voxel cubic tensor, assembled Jacobi-CG) whose
// CgInfo supplies the in-loop CG tables.
//
// STRATEGIES (each traced per iteration; occupancy classified at the end):
//   simp        classic SIMP rho^3 on the isotropic solid tensor — the
//               comparison baseline the task asks for. Its "gaps" are the same
//               intervals, interpreted against the same band.
//   s0_plain    the continuous C(rho) model as-is, no gap handling. The
//               null hypothesis: where does a gradient method park voxels
//               when nothing pushes them out of the gaps?
//   s2_gappen   gap-penalised model: inside each gap the tensor follows a
//               SIMP-like p=3 curve between the gap's endpoints (lower gap:
//               C(rho_lo)*(rho/rho_lo)^3; upper gap:
//               C(rho_hi) + (C_solid - C(rho_hi))*tau^3). In-band and at
//               0/1 it IS the measured model (C0 everywhere; the C1 kink at
//               the band edges is the strategy's price, logged). Gap
//               densities become structurally inefficient per unit mass, so
//               the optimizer is pushed to the gap endpoints — the same
//               mechanism that makes SIMP 0/1, applied ONLY where the design
//               is unrealisable.
//   s3_contin   continuation: 40 iterations continuous (s0), then 40 at gap
//               penalty p=3, then 40 at p=6 with a damped move limit — the
//               classic anneal, reaching the same measured model in-band.
//
// After each strategy: SNAP any voxel still inside a gap to the nearest
// feasible value (gap endpoint), re-solve at certification tolerance, and
// report the compliance/mass cost of feasibility. Then the GATE RECEIPT:
//   * the snapped design goes to analyze_fixed_design with a LatticePosture
//     whose relative_density is the per-voxel GRADED field — the receipt that
//     the gate structurally certifies a graded design;
//   * the UNSNAPPED s0 design goes to the same gate — the receipt that the E5
//     band gate REFUSES a design with gap voxels (LatticeDensityOutOfBand).
//
// Build (repo root):
//   c++ -std=c++17 -O2 -I core/include -I core/tests/harness \
//       core/tests/harness/lattice_gap_probe.cpp core/build/libtopopt.a \
//       -o core/build/lattice_gap_probe
//   ./core/build/lattice_gap_probe [evidence-dir]

#include <algorithm>
#include <array>
#include <cmath>
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

#include "lattice_material_model.hpp"

using namespace topopt;
using lmm::LatticeMaterialModel;

namespace {

// ---------------------------------------------------------------------------
// Fixture (fixed for every strategy — the comparison is like against like).
// ---------------------------------------------------------------------------
constexpr int kNx = 48, kNy = 24, kNz = 6;
constexpr double kSpacing = 1.0;    // mm
constexpr double kEs = 3500.0;      // PLA (materials.json)
constexpr double kNu = 0.33;
constexpr double kVolFrac = 0.35;
constexpr double kMove = 0.2;
constexpr double kFilterRadius = 1.5;  // voxels (ARCHITECTURE §4 floor)
constexpr int kIters = 120;            // per strategy (s3: 40+40+40)
constexpr double kCgTolLoop = 1e-6;    // in-loop solve
constexpr double kCgTolCert = 1e-8;    // final / certification solve
constexpr double kEpsFloor = 1e-6;     // additive void floor, eps * C_solid
constexpr double kTipLoadTotal = -200.0;  // N, -y at the free-end mid-height line

// Occupancy classification tolerances (documented in the handoff): a voxel is
// VOID at rho <= 1e-3, SOLID at rho >= 1 - 1e-3; the band test uses the core
// endpoints with 1e-9 slack; everything else is in a gap.
constexpr double kVoidTol = 1e-3;

VoxelGrid make_grid() {
  VoxelGrid g;
  g.nx = kNx; g.ny = kNy; g.nz = kNz;
  g.spacing = kSpacing;
  g.origin = Vec3{0, 0, 0};
  g.tags.assign(static_cast<std::size_t>(kNx) * kNy * kNz, VoxelTag::Interior);
  return g;
}

void make_bcs_loads(const VoxelGrid& g, std::vector<DirichletBC>& bcs,
                    std::vector<NodalLoad>& loads) {
  // Root face x = 0 fully fixed.
  for (int j = 0; j < g.ny; ++j)
    for (int k = 0; k < g.nz; ++k) {
      const std::array<int, 8> en = fea_element_nodes(g, 0, j, k);
      for (int n : {en[0], en[3], en[4], en[7]})
        for (int c = 0; c < 3; ++c) bcs.push_back({n, c, 0.0});
    }
  std::sort(bcs.begin(), bcs.end(), [](const DirichletBC& a, const DirichletBC& b) {
    return a.node != b.node ? a.node < b.node : a.component < b.component;
  });
  bcs.erase(std::unique(bcs.begin(), bcs.end(),
                        [](const DirichletBC& a, const DirichletBC& b) {
                          return a.node == b.node && a.component == b.component;
                        }),
            bcs.end());
  // Tip load: the mid-height node line of the free end (x = nx plane,
  // y = ny/2, all z), total kTipLoadTotal in -y split evenly.
  std::vector<int> tip;
  for (int k = 0; k <= g.nz; ++k) {
    const int node = ((k * (g.ny + 1)) + g.ny / 2) * (g.nx + 1) + g.nx;
    tip.push_back(node);
  }
  for (int n : tip)
    loads.push_back({n, 1, kTipLoadTotal / static_cast<double>(tip.size())});
}

// ---------------------------------------------------------------------------
// The three reference element blocks of PR 252's exact decomposition
// Ke = C11*KA + C12*KB + C44*KC, recovered from the PRODUCTION
// hex8_stiffness_cubic by exact linear combination (every argument triplet is
// admissible, so this never re-implements the integrator).
// ---------------------------------------------------------------------------
struct RefBlocks {
  Hex8Stiffness KA, KB, KC;
};
RefBlocks build_ref_blocks(double h) {
  const Hex8Stiffness K101 = hex8_stiffness_cubic(1, 0, 1, h);
  const Hex8Stiffness K201 = hex8_stiffness_cubic(2, 0, 1, h);
  const Hex8Stiffness K102 = hex8_stiffness_cubic(1, 0, 2, h);
  const Hex8Stiffness K211 = hex8_stiffness_cubic(2, 1, 1, h);
  RefBlocks b;
  for (int i = 0; i < Hex8Stiffness::kDof * Hex8Stiffness::kDof; ++i) {
    b.KA.k[i] = K201.k[i] - K101.k[i];
    b.KC.k[i] = K102.k[i] - K101.k[i];
    b.KB.k[i] = K211.k[i] - 2.0 * b.KA.k[i] - b.KC.k[i];
  }
  // Sanity: recompose an octet mid-band tensor and compare against the
  // production element (PR 252 proved 8.5e-16; this guards the recovery).
  const CubicTensor t = lattice_cubic_tensor(LatticeTopology::Octet, 0.3, kEs);
  const Hex8Stiffness Kref = hex8_stiffness_cubic(t.C11, t.C12, t.C44, h);
  double worst = 0.0, scale = 0.0;
  for (int i = 0; i < 576; ++i) {
    const double r = t.C11 * b.KA.k[i] + t.C12 * b.KB.k[i] + t.C44 * b.KC.k[i];
    worst = std::max(worst, std::fabs(r - Kref.k[i]));
    scale = std::max(scale, std::fabs(Kref.k[i]));
  }
  if (worst > 1e-10 * scale) {
    std::fprintf(stderr, "reference-block recovery failed: %.3e\n", worst / scale);
    std::exit(1);
  }
  return b;
}

// ---------------------------------------------------------------------------
// Strategy = the map rho -> (cubic triplet, its rho-derivative).
// ---------------------------------------------------------------------------
using MaterialFn = std::function<void(double rho, double C[3], double D[3])>;

MaterialFn simp_material(const LatticeMaterialModel& m) {
  return [&m](double rho, double C[3], double D[3]) {
    const double r = std::clamp(rho, 0.0, 1.0);
    const double s = kEpsFloor + (1.0 - kEpsFloor) * r * r * r;
    const double ds = 3.0 * (1.0 - kEpsFloor) * r * r;
    for (int i = 0; i < 3; ++i) {
      C[i] = s * m.solid[i];
      D[i] = ds * m.solid[i];
    }
  };
}

MaterialFn plain_material(const LatticeMaterialModel& m) {
  return [&m](double rho, double C[3], double D[3]) {
    m.eval_components(std::clamp(rho, 0.0, 1.0), C, D);
    for (int i = 0; i < 3; ++i) C[i] += kEpsFloor * m.solid[i];
  };
}

// Gap-penalised model: measured in-band, SIMP-like p-curves ONLY inside the
// two gaps (C0 at all four gap endpoints; C1 kink at rho_lo / rho_hi).
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

// ---------------------------------------------------------------------------
// Occupancy classification.
// ---------------------------------------------------------------------------
struct Occupancy {
  std::size_t n_void = 0, lower_gap = 0, band = 0, upper_gap = 0, solid = 0;
};
Occupancy classify(const std::vector<double>& rho, double lo, double hi) {
  Occupancy o;
  for (double r : rho) {
    if (r <= kVoidTol) ++o.n_void;
    else if (r < lo - 1e-9) ++o.lower_gap;
    else if (r <= hi + 1e-9) ++o.band;
    else if (r < 1.0 - kVoidTol) ++o.upper_gap;
    else ++o.solid;
  }
  return o;
}

// ---------------------------------------------------------------------------
// One compliance solve + element energy triplets for sensitivities.
// ---------------------------------------------------------------------------
struct SolveOut {
  double compliance = 0.0;
  int cg_iters = 0;
  std::vector<double> qA, qB, qC;  // per-element u^T K_X u
  FeaSolution sol;
  bool ok = false;
};

SolveOut solve_design(const VoxelGrid& g, const RefBlocks& blocks,
                      const MaterialFn& mat, const std::vector<double>& rho,
                      const std::vector<DirichletBC>& bcs,
                      const std::vector<NodalLoad>& loads, double tol) {
  const std::size_t n = g.voxel_count();
  std::vector<double> c11(n), c12(n), c44(n), youngs(n, 1.0);
  std::vector<char> mask(n, 1);
  double C[3], D[3];
  for (std::size_t e = 0; e < n; ++e) {
    mat(rho[e], C, D);
    c11[e] = C[0]; c12[e] = C[1]; c44[e] = C[2];
  }
  SolveOut out;
  CgInfo info;
  try {
    out.sol = fea_solve_cg_lattice(g, youngs, mask, c11, c12, c44, kNu, bcs,
                                   loads, tol, 40000, &info);
  } catch (const std::exception& ex) {
    std::fprintf(stderr, "solve failed: %s\n", ex.what());
    return out;
  }
  out.cg_iters = info.iterations;
  for (const NodalLoad& l : loads)
    out.compliance += l.value * out.sol.u[3 * l.node + l.component];
  out.qA.assign(n, 0.0);
  out.qB.assign(n, 0.0);
  out.qC.assign(n, 0.0);
  constexpr int kDof = Hex8Stiffness::kDof;
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
            ra += blocks.KA.k[off + s] * ue[s];
            rb += blocks.KB.k[off + s] * ue[s];
            rc += blocks.KC.k[off + s] * ue[s];
          }
          qa += ue[r] * ra;
          qb += ue[r] * rb;
          qc += ue[r] * rc;
        }
        const std::size_t e = g.index(i, j, k);
        out.qA[e] = qa; out.qB[e] = qb; out.qC[e] = qc;
      }
  out.ok = true;
  return out;
}

// ---------------------------------------------------------------------------
// The probe's OC updater: volume constraint enforced on the PHYSICAL density
// (through the filter — the design chain is x --filter--> rho), lambda found
// by bisection. Standard OC half-power damping, move limit, bounds [0, 1].
// ---------------------------------------------------------------------------
std::vector<double> oc_step(const DensityFilter& filter,
                            const std::vector<double>& x,
                            const std::vector<double>& dc_dx,
                            const std::vector<double>& dv_dx, double vol_target,
                            double move) {
  const std::size_t n = x.size();
  std::vector<double> xn(n);
  auto try_lambda = [&](double lam) {
    for (std::size_t e = 0; e < n; ++e) {
      const double b = std::max(0.0, -dc_dx[e]) / (lam * std::max(dv_dx[e], 1e-30));
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
    if (try_lambda(lm) > vol_target) l1 = lm; else l2 = lm;
  }
  try_lambda(std::sqrt(l1 * l2));
  return xn;
}

// ---------------------------------------------------------------------------
// One strategy run: fixed iteration budget, per-iteration trace, final field.
// ---------------------------------------------------------------------------
struct Phase {
  MaterialFn mat;
  int iters;
  double move;
};

struct RunResult {
  std::vector<double> x;    // final design variables
  std::vector<double> rho;  // final physical density (filtered)
  double compliance = 0.0;
};

RunResult run_strategy(const char* name, const VoxelGrid& g,
                       const RefBlocks& blocks, const DensityFilter& filter,
                       const std::vector<Phase>& phases,
                       const std::vector<DirichletBC>& bcs,
                       const std::vector<NodalLoad>& loads, double lo, double hi,
                       FILE* trace) {
  const std::size_t n = g.voxel_count();
  const double vol_target = kVolFrac * static_cast<double>(n);
  RunResult res;
  res.x.assign(n, kVolFrac);
  int iter_global = 0;
  for (std::size_t ph = 0; ph < phases.size(); ++ph) {
    const Phase& phase = phases[ph];
    for (int it = 0; it < phase.iters; ++it, ++iter_global) {
      res.rho = filter.filter_density(res.x);
      const SolveOut s =
          solve_design(g, blocks, phase.mat, res.rho, bcs, loads, kCgTolLoop);
      if (!s.ok) { std::fprintf(stderr, "%s: solve failed, aborting\n", name); break; }
      res.compliance = s.compliance;
      // dc/drho_e = -(C11' qA + C12' qB + C44' qC); dV/drho_e = 1.
      std::vector<double> dc_drho(n), one(n, 1.0);
      double C[3], D[3];
      for (std::size_t e = 0; e < n; ++e) {
        phase.mat(res.rho[e], C, D);
        dc_drho[e] = -(D[0] * s.qA[e] + D[1] * s.qB[e] + D[2] * s.qC[e]);
      }
      const std::vector<double> dc_dx = filter.filter_sensitivity(dc_drho);
      const std::vector<double> dv_dx = filter.filter_sensitivity(one);
      const std::vector<double> xn =
          oc_step(filter, res.x, dc_dx, dv_dx, vol_target, phase.move);
      double change = 0.0;
      for (std::size_t e = 0; e < n; ++e)
        change = std::max(change, std::fabs(xn[e] - res.x[e]));
      res.x = xn;
      const Occupancy o = classify(res.rho, lo, hi);
      double vol = 0.0;
      for (double r : res.rho) vol += r;
      std::fprintf(trace, "%s,%zu,%d,%.8e,%.5f,%d,%zu,%zu,%zu,%zu,%zu,%.5f\n",
                   name, ph, iter_global, s.compliance,
                   vol / static_cast<double>(n), s.cg_iters, o.n_void,
                   o.lower_gap, o.band, o.upper_gap, o.solid, change);
      if ((iter_global + 1) % 20 == 0)
        std::printf("  %s iter %3d  c=%.4e  cg=%d  gaps(lo/up)=%zu/%zu\n", name,
                    iter_global + 1, s.compliance, s.cg_iters, o.lower_gap,
                    o.upper_gap);
    }
  }
  res.rho = filter.filter_density(res.x);
  return res;
}

// ---------------------------------------------------------------------------
// Snap-to-feasible + certification-tolerance re-solve.
// ---------------------------------------------------------------------------
std::vector<double> snap_to_feasible(const std::vector<double>& rho, double lo,
                                     double hi) {
  std::vector<double> out(rho.size());
  for (std::size_t e = 0; e < rho.size(); ++e) {
    const double r = rho[e];
    double s = r;
    if (r <= kVoidTol) s = 0.0;
    else if (r < lo) s = (r < lo / 2.0) ? 0.0 : lo;   // nearest of {0, lo}
    else if (r <= hi) s = r;                          // in band: keep (graded)
    else if (r >= 1.0 - kVoidTol) s = 1.0;
    else s = (r - hi < 1.0 - r) ? hi : 1.0;           // nearest of {hi, 1}
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

// The gate receipt: analyze_fixed_design on a snapped (feasible) graded field.
// Printed set = every voxel with rho > 0; lattice voxels (0 < rho < 1) carry
// the graded relative_density; solid voxels are plain solid.
void gate_receipt(const char* name, const VoxelGrid& g,
                  const std::vector<double>& rho_feasible,
                  const std::vector<DirichletBC>& bcs,
                  const std::vector<NodalLoad>& loads, FILE* out) {
  const std::size_t n = g.voxel_count();
  std::vector<double> density(n, 0.0);
  LatticePosture post;
  post.topology = LatticeTopology::Octet;
  post.cell_size_mm = 4.0;
  post.mask.assign(n, 0);
  post.relative_density.assign(n, 0.0);
  std::size_t printed = 0, latticed = 0;
  for (std::size_t e = 0; e < n; ++e) {
    if (rho_feasible[e] <= 0.0) continue;
    density[e] = 1.0;
    ++printed;
    if (rho_feasible[e] < 1.0) {
      post.mask[e] = 1;
      post.relative_density[e] = rho_feasible[e];
      ++latticed;
    }
  }
  const Material mat = pla_material();
  SimpParams params;
  params.youngs_modulus = mat.youngs_modulus_mpa;
  params.poisson = mat.poisson;
  params.penalty = 3.0;
  const Vec3 build_dir{0, 0, 1};
  const KnockdownSpec kd;
  std::fprintf(out, "== gate receipt: %s ==\n", name);
  std::fprintf(out, "printed voxels %zu  latticed %zu  solid %zu\n", printed,
               latticed, printed - latticed);
  try {
    const FixedDesignAnalysis a = analyze_fixed_design(
        g, params, density, bcs, loads, mat, build_dir, kCgTolCert, 0,
        SolverKind::JacobiCG, 0.5, kd, true,
        static_cast<double>(g.solid_count()), &post);
    std::fprintf(out,
                 "VERDICT: %s\n"
                 "lattice_certified=%d lattice_voxels=%zu rho_range=[%.4f,%.4f]\n"
                 "margin.worst_case=%.4f margin_effective=%.4f max_vm=%.3f\n"
                 "lattice_max_effective_vm=%.3f strength_uncertified=%d "
                 "non_convergent=%d\n",
                 a.accepted ? "ACCEPTED" : "REJECTED", a.lattice_certified ? 1 : 0,
                 a.lattice_voxels, a.lattice_rho_min, a.lattice_rho_max,
                 a.margin.worst_case, a.margin_effective, a.max_von_mises,
                 a.lattice_max_effective_vm, a.lattice_strength_uncertified ? 1 : 0,
                 a.non_convergent ? 1 : 0);
  } catch (const LatticeDensityOutOfBand& e) {
    std::fprintf(out,
                 "VERDICT: REFUSED (LatticeDensityOutOfBand)\n"
                 "offending rho=%.6f band=[%.4f,%.4f]\nmessage: %s\n",
                 e.rho, e.rho_min, e.rho_max, e.what());
  } catch (const std::exception& e) {
    std::fprintf(out, "VERDICT: THREW (%s)\n", e.what());
  }
  std::fprintf(out, "\n");
}

FILE* open_out(const std::string& dir, const char* name) {
  const std::string p = dir + "/" + name;
  FILE* f = std::fopen(p.c_str(), "w");
  if (!f) { std::fprintf(stderr, "cannot open %s\n", p.c_str()); std::exit(1); }
  return f;
}

}  // namespace

int main(int argc, char** argv) {
  const std::string ev = argc > 1 ? argv[1] : ".";
  const VoxelGrid g = make_grid();
  const RefBlocks blocks = build_ref_blocks(kSpacing);
  const DensityFilter filter = make_density_filter(g, kFilterRadius);
  std::vector<DirichletBC> bcs;
  std::vector<NodalLoad> loads;
  make_bcs_loads(g, bcs, loads);
  const LatticeMaterialModel model =
      lmm::build_lattice_material_model(LatticeTopology::Octet, kEs, kNu);
  const double lo = model.rho_lo, hi = model.rho_hi;  // read from core
  std::printf("octet band read from core: [%.5f, %.5f]\n", lo, hi);

  // The C1 kink the gap-penalised strategy introduces at the band edges
  // (its price — logged for the handoff).
  {
    const MaterialFn gp = gappen_material(model, 3.0);
    double Cl[3], Dl[3], Cr[3], Dr[3];
    gp(lo - 1e-9, Cl, Dl);
    gp(lo + 1e-9, Cr, Dr);
    std::printf("s2 kink at rho_lo: dC11 %.1f -> %.1f (x%.2f)\n", Dl[0], Dr[0],
                Dr[0] / Dl[0]);
    gp(hi - 1e-9, Cl, Dl);
    gp(hi + 1e-9, Cr, Dr);
    std::printf("s2 kink at rho_hi: dC11 %.1f -> %.1f (x%.2f)\n", Dl[0], Dr[0],
                Dr[0] / Dl[0]);
  }

  FILE* trace = open_out(ev, "p2_trace.csv");
  std::fprintf(trace, "strategy,phase,iter,compliance,vol_frac,cg_iters,"
                      "n_void,n_lower_gap,n_band,n_upper_gap,n_solid,change\n");

  struct Def {
    const char* name;
    std::vector<Phase> phases;
  };
  std::vector<Def> defs;
  defs.push_back({"simp", {{simp_material(model), kIters, kMove}}});
  defs.push_back({"s0_plain", {{plain_material(model), kIters, kMove}}});
  defs.push_back({"s2_gappen", {{gappen_material(model, 3.0), kIters, kMove}}});
  defs.push_back({"s3_contin",
                  {{plain_material(model), 40, kMove},
                   {gappen_material(model, 3.0), 40, kMove},
                   {gappen_material(model, 6.0), 40, 0.1}}});

  FILE* occ = open_out(ev, "p2_occupancy.csv");
  std::fprintf(occ, "strategy,n_void,n_lower_gap,n_band,n_upper_gap,n_solid,"
                    "gap_total,ramp_frac_lower,ramp_frac_upper,"
                    "compliance_1e8,vol_frac\n");
  FILE* hist = open_out(ev, "p2_histogram.csv");
  std::fprintf(hist, "strategy,bin_lo,bin_hi,count\n");
  FILE* snapf = open_out(ev, "p2_snap.csv");
  std::fprintf(snapf, "strategy,snapped_lower,snapped_upper,compliance_before,"
                      "compliance_after,compliance_delta_pct,vol_before,"
                      "vol_after,vol_delta_pct\n");
  FILE* gate = open_out(ev, "p2_gate_receipts.txt");

  std::vector<double> s0_unsnapped_rho;  // for the refusal receipt
  const std::size_t n = g.voxel_count();

  for (const Def& def : defs) {
    std::printf("== strategy %s ==\n", def.name);
    RunResult r = run_strategy(def.name, g, blocks, filter, def.phases, bcs,
                               loads, lo, hi, trace);
    // Final certification-tolerance solve of the raw field (the strategy's
    // own material curve, evaluated at its last phase).
    const MaterialFn& fin = def.phases.back().mat;
    const SolveOut before =
        solve_design(g, blocks, fin, r.rho, bcs, loads, kCgTolCert);
    const Occupancy o = classify(r.rho, lo, hi);
    double vol = 0.0;
    for (double x : r.rho) vol += x;
    // WHERE do gap voxels park? A gap voxel "sits on a ramp" if some
    // 6-neighbour differs by more than half that gap's width — i.e. it is a
    // point of the filter's void<->band (or band<->solid) transition layer,
    // not an interior region the optimizer chose. ramp_frac ~ 1 means the gap
    // population is the smoothing boundary, not a structural attractor.
    std::size_t ramp_lo = 0, ramp_up = 0, tot_lo = 0, tot_up = 0;
    for (int k = 0; k < g.nz; ++k)
      for (int j = 0; j < g.ny; ++j)
        for (int i = 0; i < g.nx; ++i) {
          const double x = r.rho[g.index(i, j, k)];
          const bool in_lower = x > kVoidTol && x < lo - 1e-9;
          const bool in_upper = x > hi + 1e-9 && x < 1.0 - kVoidTol;
          if (!in_lower && !in_upper) continue;
          const double half_gap = in_lower ? lo / 2.0 : (1.0 - hi) / 2.0;
          bool ramp = false;
          const int di[6] = {1, -1, 0, 0, 0, 0};
          const int dj[6] = {0, 0, 1, -1, 0, 0};
          const int dk[6] = {0, 0, 0, 0, 1, -1};
          for (int d = 0; d < 6 && !ramp; ++d) {
            const int ni = i + di[d], nj = j + dj[d], nk = k + dk[d];
            if (ni < 0 || nj < 0 || nk < 0 || ni >= g.nx || nj >= g.ny ||
                nk >= g.nz) continue;
            if (std::fabs(r.rho[g.index(ni, nj, nk)] - x) > half_gap) ramp = true;
          }
          if (in_lower) { ++tot_lo; if (ramp) ++ramp_lo; }
          else          { ++tot_up; if (ramp) ++ramp_up; }
        }
    const double rf_lo = tot_lo ? double(ramp_lo) / tot_lo : 0.0;
    const double rf_up = tot_up ? double(ramp_up) / tot_up : 0.0;
    std::fprintf(occ, "%s,%zu,%zu,%zu,%zu,%zu,%zu,%.4f,%.4f,%.8e,%.5f\n",
                 def.name, o.n_void, o.lower_gap, o.band, o.upper_gap, o.solid,
                 o.lower_gap + o.upper_gap, rf_lo, rf_up, before.compliance,
                 vol / static_cast<double>(n));
    std::printf("  ramp fraction: lower-gap %.1f%%  upper-gap %.1f%%\n",
                100 * rf_lo, 100 * rf_up);
    // Final field dump — the spatial evidence of where each strategy parked.
    {
      FILE* ff = open_out(ev, (std::string("p2_field_") + def.name + ".csv").c_str());
      std::fprintf(ff, "i,j,k,rho\n");
      for (int k = 0; k < g.nz; ++k)
        for (int j = 0; j < g.ny; ++j)
          for (int i = 0; i < g.nx; ++i)
            std::fprintf(ff, "%d,%d,%d,%.6f\n", i, j, k,
                         r.rho[g.index(i, j, k)]);
      std::fclose(ff);
    }
    for (int b = 0; b < 100; ++b) {
      const double blo = b / 100.0, bhi = (b + 1) / 100.0;
      std::size_t cnt = 0;
      for (double x : r.rho)
        if (x >= blo && (x < bhi || (b == 99 && x <= 1.0))) ++cnt;
      std::fprintf(hist, "%s,%.2f,%.2f,%zu\n", def.name, blo, bhi, cnt);
    }
    std::printf("  final: void %zu | lower-gap %zu | band %zu | upper-gap %zu "
                "| solid %zu\n", o.n_void, o.lower_gap, o.band, o.upper_gap,
                o.solid);

    if (std::strcmp(def.name, "s0_plain") == 0) s0_unsnapped_rho = r.rho;

    // Snap to the feasible set and price it (skip for the SIMP baseline —
    // its design lives on a different material law; its occupancy row above
    // is the comparison the task asks for).
    if (std::strcmp(def.name, "simp") != 0) {
      const std::vector<double> snapped = snap_to_feasible(r.rho, lo, hi);
      std::size_t sl = 0, su = 0;
      for (std::size_t e = 0; e < n; ++e) {
        if (r.rho[e] > kVoidTol && r.rho[e] < lo - 1e-9) ++sl;
        if (r.rho[e] > hi + 1e-9 && r.rho[e] < 1.0 - kVoidTol) ++su;
      }
      const SolveOut after =
          solve_design(g, blocks, plain_material(model), snapped, bcs, loads,
                       kCgTolCert);
      const SolveOut before_plain =
          solve_design(g, blocks, plain_material(model), r.rho, bcs, loads,
                       kCgTolCert);
      double vb = 0.0, va = 0.0;
      for (std::size_t e = 0; e < n; ++e) { vb += r.rho[e]; va += snapped[e]; }
      std::fprintf(snapf, "%s,%zu,%zu,%.8e,%.8e,%.3f,%.5f,%.5f,%.3f\n",
                   def.name, sl, su, before_plain.compliance, after.compliance,
                   100.0 * (after.compliance / before_plain.compliance - 1.0),
                   vb / n, va / n,
                   100.0 * (va / vb - 1.0));
      std::printf("  snap: %zu lower + %zu upper -> compliance %+.2f%%  "
                  "volume %+.2f%%\n", sl, su,
                  100.0 * (after.compliance / before_plain.compliance - 1.0),
                  100.0 * (va / vb - 1.0));
      gate_receipt((std::string(def.name) + " (snapped)").c_str(), g, snapped,
                   bcs, loads, gate);
    }
  }

  // The REFUSAL receipt: the unsnapped s0 field carries gap voxels; the E5
  // band gate must refuse it rather than certify a clamped tensor.
  if (!s0_unsnapped_rho.empty()) {
    std::vector<double> raw(n, 0.0);
    for (std::size_t e = 0; e < n; ++e)
      raw[e] = s0_unsnapped_rho[e] <= kVoidTol ? 0.0
               : s0_unsnapped_rho[e] >= 1.0 - kVoidTol ? 1.0
                                                       : s0_unsnapped_rho[e];
    gate_receipt("s0_plain UNSNAPPED (expect E5 refusal)", g, raw, bcs, loads,
                 gate);
  }

  std::fclose(trace);
  std::fclose(occ);
  std::fclose(hist);
  std::fclose(snapf);
  std::fclose(gate);
  std::printf("done — evidence in %s\n", ev.c_str());
  return 0;
}
