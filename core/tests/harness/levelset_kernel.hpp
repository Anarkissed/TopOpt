// levelset_kernel.hpp — ★ A SHIM. THE FIELD KERNEL ITSELF NOW LIVES IN CORE.
//
// PR 324 lifted the level-set field kernel out of `levelset_probe.cpp` into this
// header so `plsm_probe` could use it without a second implementation existing.
// Task 2026-08-10-plsm-production moved it ONE STEP FURTHER OUT — into
// `core/include/topopt/plsm_kernel.hpp` — because the PRODUCTION parametric
// optimiser needs the same six functions, and a production copy of the Heaviside
// would be a SECOND SMOOTHING LAW in the repository.
//
// WHAT IS STILL DEFINED HERE, because it could not move:
//
//   Dims             the harness's x-fastest grid index
//   now_s, kPi, kFar the harness's clock and its two constants
//
// WHAT IS NOW AN ALIAS (bodies in `topopt::plsm_*`, and nothing here can drift
// from them):
//
//   heaviside        GridapTopOpt's H_eta — rho = H_eta(-phi), H(0) = 0.5 exactly
//   dheaviside       its derivative DH_eta, the surface delta
//   grad_mag         |grad phi|, central differences
//   eikonal_update   the Godunov update for |grad d| = 1
//   fast_sweep       8-direction 3D fast sweeping
//   reinitialise     re-make phi a signed distance, keeping its zero set
//
// WHAT IS DELIBERATELY NOT IN EITHER FILE: the optimiser's velocity, the
// Hilbertian extension, the volume bisection, the HJ advection and the
// certification all stay in levelset_probe.cpp, because `plsm_probe` does not
// optimise anything — R5 of PR 324 forbids it — and a header that offered them
// would invite it to.
//
// The move is verified rather than asserted: `evidence/.../s0_kernel_move/`
// holds a 3-iteration `--gridap-auto min` trajectory from BEFORE PR 324's move,
// and `evidence/2026-08-10-plsm-production/s0_core_move` re-runs it on this tree
// and diffs `iterations.csv`. They are identical or the move is wrong.
//
// It is included INSIDE an anonymous namespace and so has no include guard that
// would be meaningful across translation units; the guard below is the ordinary
// double-inclusion one. `topopt/plsm_kernel.hpp` is therefore included at FILE
// SCOPE by every includer, so core's kernel keeps EXTERNAL linkage and the
// harness and production share one definition.

#ifndef TOPOPT_TESTS_HARNESS_LEVELSET_KERNEL_HPP_
#define TOPOPT_TESTS_HARNESS_LEVELSET_KERNEL_HPP_

#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstddef>
#include <vector>


constexpr double kPi = 3.14159265358979323846;
// Larger than any distance on his part (the grid is ~218 x 53 x 201 mm), so an
// unreached cell is unambiguously "far" and the sweep's min() always improves.
constexpr double kFar = 1e30;

double now_s() {
  return std::chrono::duration<double>(
             std::chrono::steady_clock::now().time_since_epoch())
      .count();
}

// ── the grid index, x-fastest then y then z: core's own ordering ────────────
struct Dims {
  int nx = 0, ny = 0, nz = 0;
  std::size_t at(int i, int j, int k) const {
    return static_cast<std::size_t>(i) +
           static_cast<std::size_t>(nx) *
               (static_cast<std::size_t>(j) +
                static_cast<std::size_t>(ny) * static_cast<std::size_t>(k));
  }
  std::size_t count() const {
    return static_cast<std::size_t>(nx) * static_cast<std::size_t>(ny) *
           static_cast<std::size_t>(nz);
  }
};

// ── ★ EVERYTHING BELOW IS AN ALIAS. THE KERNEL ITSELF NOW LIVES IN CORE. ────
//
// Task 2026-08-10-plsm-production moved the six field functions one step further
// out — into `core/include/topopt/plsm_kernel.hpp` — because the PRODUCTION
// parametric optimiser needs them, and a production copy would be a SECOND
// SMOOTHING LAW in the repository. `Dims`, `now_s`, `kPi` and `kFar` stay here:
// they are the harness's own index type and clock, not part of the kernel.
//
// The bodies are `topopt::plsm_*` and nothing here can drift from them. The move
// is verified rather than asserted: `evidence/2026-08-10-plsm-production/`
// re-runs PR 324's own 3-iteration `--gridap-auto min` trajectory and diffs it
// against the pre-move copy in `s0_kernel_move/before`.

inline double heaviside(double s, double eta) {
  return topopt::plsm_heaviside(s, eta);
}

inline double dheaviside(double t, double eta) {
  return topopt::plsm_dheaviside(t, eta);
}

inline double grad_mag(const Dims& d, const std::vector<double>& phi, int i, int j,
                       int k, double h) {
  return topopt::plsm_grad_mag(d.nx, d.ny, d.nz, phi, i, j, k, h);
}

inline double eikonal_update(double a, double b, double c, double h) {
  return topopt::plsm_eikonal_update(a, b, c, h);
}

inline void fast_sweep(const Dims& d, std::vector<double>& mag,
                       const std::vector<char>& frozen, double h, int passes) {
  topopt::plsm_fast_sweep(d.nx, d.ny, d.nz, mag, frozen, h, passes);
}

inline void reinitialise(const Dims& d, std::vector<double>& phi, double h,
                         int passes, bool russo_smereka = false) {
  topopt::plsm_reinitialise(d.nx, d.ny, d.nz, phi, h, passes, russo_smereka);
}

#endif  // TOPOPT_TESTS_HARNESS_LEVELSET_KERNEL_HPP_
