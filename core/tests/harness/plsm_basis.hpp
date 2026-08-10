// plsm_basis.hpp — ★ A SHIM. THE BASIS ITSELF NOW LIVES IN CORE.
//
// PR 324 lifted the parametric level-set basis out of `plsm_probe.cpp` into this
// header so `levelset_probe --plsm` could optimise over the same phi that
// `plsm_probe` fits, with one implementation and not two. Task
// 2026-08-10-plsm-production moved it ONE STEP FURTHER OUT — into
// `core/include/topopt/plsm_basis.hpp` — because the PRODUCTION optimiser has to
// fit and evaluate that same function, and a production path that carried its own
// copy of the basis would be exactly the two-implementations failure this header
// was created to prevent.
//
// ★ SO EVERY NAME BELOW IS AN ALIAS, NOT A DEFINITION. There is no basis, no
// lattice, no CSR, no normal-equation solve and no evaluation in this file: the
// bodies are `topopt::plsm_*` and nothing here can drift from them. The move is
// verified rather than asserted — `evidence/2026-08-10-plsm-production/s0_core_move`
// re-runs PR 324's own `--fit` sweep on this tree and diffs `fits.csv` against the
// pre-move copy in `evidence/2026-08-10-parametric-level-set/s0_basis_move`.
//
// WHAT STAYS HERE, and why it could not move:
//
//   occupancy       needs `heaviside` from `levelset_kernel.hpp`, which is the
//                   harness's own copy of GridapTopOpt's H_eta
//   inside_count    two-line helpers over a phi the harness already holds
//   match_offset
//
// It needs `Dims` from `levelset_kernel.hpp`, so that header is included FIRST by
// every file that includes this one.

#ifndef TOPOPT_TESTS_HARNESS_PLSM_BASIS_HPP_
#define TOPOPT_TESTS_HARNESS_PLSM_BASIS_HPP_

// ★ THESE ARE HERE FOR READABILITY AND ARE NOT LOAD-BEARING. This header is
// included from INSIDE an anonymous namespace, where a standard header must not
// be opened for the first time — libc++'s <thread> refers to ::std::chrono and
// would not find it. Every file that includes this one therefore includes the
// same set at FILE SCOPE first — INCLUDING <topopt/plsm_basis.hpp>, whose
// entities must have EXTERNAL linkage so the harness and core share one
// definition — so the guards below have already fired and these lines expand to
// nothing. If a new includer forgets, the compiler says so immediately and
// loudly; it cannot fail silently.
#include <algorithm>
#include <cmath>
#include <cstddef>
#include <thread>
#include <vector>

#include "topopt/plsm_basis.hpp"

// ── the aliases ─────────────────────────────────────────────────────────────
// PR 324's spellings, bound to core's definitions. Nothing is redefined.
using Basis = topopt::PlsmBasisKind;
using KnotLattice = topopt::PlsmKnotLattice;
using Csr = topopt::PlsmCsr;
using FitResult = topopt::PlsmFitResult;

using topopt::plsm_dot;
using topopt::plsm_evaluate;
using topopt::plsm_hw_threads;
using topopt::plsm_parallel_for;
using topopt::plsm_psi;
using topopt::plsm_psi_gaussian;
using topopt::plsm_psi_wendland;
using topopt::plsm_solve_normal;
using topopt::plsm_spmv;
using topopt::plsm_support_of;
using topopt::plsm_transpose;

// The PR 324 spellings the two probes call, each a one-line forward. The two
// that take `Dims` are the only reason these are functions rather than more
// using-declarations: core's basis takes three plain ints so that it depends on
// neither the harness's `Dims` nor core's `VoxelGrid`.
inline double psi_wendland(double r) { return topopt::plsm_psi_wendland(r); }
inline double psi_gaussian(double r) { return topopt::plsm_psi_gaussian(r); }
inline double psi(Basis b, double r) { return topopt::plsm_psi(b, r); }
inline int hw_threads(int want) { return topopt::plsm_hw_threads(want); }

inline KnotLattice make_lattice(const Dims& d, double dx, double dy, double dz,
                                double support) {
  return topopt::plsm_make_lattice(d.nx, d.ny, d.nz, dx, dy, dz, support);
}

inline void support_of(const KnotLattice& L, Basis b, double x, double y, double z,
                       std::vector<int>& idx, std::vector<double>& w) {
  topopt::plsm_support_of(L, b, x, y, z, idx, w);
}

inline Csr build_A(const Dims& d, const KnotLattice& L, Basis b, int threads) {
  return topopt::plsm_build_A(d.nx, d.ny, d.nz, L, b, threads);
}

inline Csr transpose(const Csr& A, int threads) {
  return topopt::plsm_transpose(A, threads);
}

inline void spmv(const Csr& M, const std::vector<double>& x,
                 std::vector<double>& y, int threads) {
  topopt::plsm_spmv(M, x, y, threads);
}

inline double dot(const std::vector<double>& a, const std::vector<double>& b) {
  return topopt::plsm_dot(a, b);
}

inline FitResult solve_normal(const Csr& A, const Csr& At,
                              const std::vector<double>& rhs_f,
                              const std::vector<double>& w, double lambda,
                              int max_iters, double tol, int threads) {
  return topopt::plsm_solve_normal(A, At, rhs_f, w, lambda, max_iters, tol,
                                   threads);
}

inline std::vector<double> evaluate(const KnotLattice& L, Basis b,
                                    const std::vector<double>& alpha, int nx,
                                    int ny, int nz, int factor, int threads) {
  return topopt::plsm_evaluate(L, b, alpha, nx, ny, nz, factor, threads);
}

// ── what could NOT move: the three helpers that need the harness's heaviside ──

// ρ = H_eta(-(φ + c)) — `levelset_kernel.hpp`'s OWN heaviside, the one the level
// set arms used, at the same eta. Nothing about the occupancy convention is
// re-decided here.
inline std::vector<double> occupancy(const std::vector<double>& phi, double offset,
                                     double eta,
                                     const std::vector<double>* fsolid = nullptr,
                                     const std::vector<double>* fvoid = nullptr,
                                     int factor = 1, const Dims* coarse = nullptr) {
  std::vector<double> occ(phi.size(), 0.0);
  for (std::size_t v = 0; v < phi.size(); ++v) {
    double p = phi[v] + offset;
    if (fsolid && fvoid && coarse) {
      // ★ THE FROZEN SET AS A BOOLEAN ON LEVEL SETS, NOT AS A STAMP. With
      // solid = {phi < 0}, UNION is `min` and INTERSECTION is `max`, so this is
      // "what the fit chose, PLUS the frozen material, MINUS the frozen void" —
      // exactly, and smoothly, with no tags surviving into the result.
      const int fx = coarse->nx * factor, fy = coarse->ny * factor;
      const int i = static_cast<int>(v % static_cast<std::size_t>(fx));
      const int j = static_cast<int>((v / static_cast<std::size_t>(fx)) %
                                    static_cast<std::size_t>(fy));
      const int k = static_cast<int>(v / (static_cast<std::size_t>(fx) *
                                          static_cast<std::size_t>(fy)));
      const std::size_t cv = coarse->at(i / factor, j / factor, k / factor);
      p = std::min(p, (*fsolid)[cv]);
      p = std::max(p, -(*fvoid)[cv]);
    }
    occ[v] = heaviside(-p, eta);
  }
  return occ;
}

inline std::size_t inside_count(const std::vector<double>& phi, double offset) {
  std::size_t c = 0;
  for (double p : phi)
    if (p + offset < 0.0) ++c;
  return c;
}

// The constant that makes the fit enclose the SOURCE's voxel count exactly. A
// rigid move of the level set: φ + c is still a signed distance, so nothing about
// the band or the ersatz changes with it.
inline double match_offset(const std::vector<double>& phi, std::size_t target) {
  double lo = -60.0, hi = 60.0;  // voxels; the part is 31 voxels across its thin axis
  // inside_count is non-increasing in the offset.
  for (int it = 0; it < 80; ++it) {
    const double mid = 0.5 * (lo + hi);
    if (inside_count(phi, mid) > target) lo = mid; else hi = mid;
  }
  return 0.5 * (lo + hi);
}

#endif  // TOPOPT_TESTS_HARNESS_PLSM_BASIS_HPP_
