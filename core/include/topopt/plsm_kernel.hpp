// plsm_kernel.hpp — THE LEVEL-SET FIELD KERNEL, in core.
//
// The smoothed Heaviside the ersatz is built from, its derivative (the surface
// delta the shape derivative is weighted by), the gradient magnitude, and the
// Eikonal fast-sweeping reinitialisation.
//
// ★ THIS FILE IS A MOVE OUT OF `core/tests/harness/levelset_kernel.hpp`, NOT A
// REWRITE — the same move `plsm_basis.hpp` is, for the same reason: the
// PRODUCTION optimiser needs these six functions, and a production copy of them
// would be a second smoothing law in the repository. That harness header is now
// a SHIM for exactly these six and keeps only what could not move (`Dims`,
// `now_s`, `kPi`, `kFar` — the harness's own index type and clock).
//
// ★ THE HEAVISIDE IS GRIDAPTOPOPT'S, VERBATIM, AND SO IS ITS DERIVATIVE.
// GridapTopOpt, src/Utilities.jl:
//     H_eta(t, eta)  = 1/2 (1 + t/eta + sin(pi t/eta)/pi)   for |t| <= eta
//     DH_eta(t, eta) = 1/(2 eta) (1 + cos(pi t/eta))        for |t| <= eta, else 0
// DH is exactly d/dt of H, which is the consistency this file relies on: there is
// no second smoothing law anywhere.
//
// Takes three plain ints rather than a grid type, for the same reason
// `plsm_basis.hpp` does: the harness has `Dims`, core has `VoxelGrid`, and one
// implementation has to serve both without either learning about the other.

#ifndef TOPOPT_PLSM_KERNEL_HPP_
#define TOPOPT_PLSM_KERNEL_HPP_

#include <algorithm>
#include <cmath>
#include <cstddef>
#include <vector>

namespace topopt {

constexpr double kPlsmPi = 3.14159265358979323846;
// Larger than any distance on his part (the grid is ~218 x 53 x 201 mm), so an
// unreached cell is unambiguously "far" and the sweep's min() always improves.
constexpr double kPlsmFar = 1e30;

// x-fastest then y then z: core's own ordering, and the harness's.
inline std::size_t plsm_at(int nx, int ny, int i, int j, int k) {
  return static_cast<std::size_t>(i) +
         static_cast<std::size_t>(nx) *
             (static_cast<std::size_t>(j) +
              static_cast<std::size_t>(ny) * static_cast<std::size_t>(k));
}

// C1, compactly supported on [-eta, eta], H(0) = 0.5 exactly. `s` is -phi, so
// s > 0 is inside the material.
inline double plsm_heaviside(double s, double eta) {
  if (s <= -eta) return 0.0;
  if (s >= eta) return 1.0;
  return 0.5 * (1.0 + s / eta + std::sin(kPlsmPi * s / eta) / kPlsmPi);
}

// DH is EVEN in t, so it does not matter whether it is evaluated at phi (their
// sign convention) or at -phi. It is written at phi, as theirs is.
inline double plsm_dheaviside(double t, double eta) {
  if (t <= -eta || t >= eta) return 0.0;
  return (1.0 + std::cos(kPlsmPi * t / eta)) / (2.0 * eta);
}

// |grad phi|, central differences, one-sided at the box face. This is their
// `norm ∘ ∇(φ)`. After reinitialisation it is ~1 by construction — which is the
// point: it is carried anyway so the delta stays a correct surface measure on
// the iterations where phi has drifted from a true distance.
inline double plsm_grad_mag(int nx, int ny, int nz, const std::vector<double>& phi,
                            int i, int j, int k, double h) {
  const double xm = phi[plsm_at(nx, ny, i > 0 ? i - 1 : 0, j, k)];
  const double xp = phi[plsm_at(nx, ny, i + 1 < nx ? i + 1 : nx - 1, j, k)];
  const double ym = phi[plsm_at(nx, ny, i, j > 0 ? j - 1 : 0, k)];
  const double yp = phi[plsm_at(nx, ny, i, j + 1 < ny ? j + 1 : ny - 1, k)];
  const double zm = phi[plsm_at(nx, ny, i, j, k > 0 ? k - 1 : 0)];
  const double zp = phi[plsm_at(nx, ny, i, j, k + 1 < nz ? k + 1 : nz - 1)];
  // The divisor is the ACTUAL span sampled: 2h in the interior, h against a face
  // where the two reads collapsed onto the same cell.
  const double sx = (i > 0 && i + 1 < nx) ? 2.0 * h : h;
  const double sy = (j > 0 && j + 1 < ny) ? 2.0 * h : h;
  const double sz = (k > 0 && k + 1 < nz) ? 2.0 * h : h;
  const double gx = (xp - xm) / sx, gy = (yp - ym) / sy, gz = (zp - zm) / sz;
  return std::sqrt(gx * gx + gy * gy + gz * gz);
}

// The Godunov update at one cell, given the smallest |d| already known across
// each axis. Standard 3D form: try the 1-D solution, and only bring in the
// second and third axes when the candidate overtakes them.
inline double plsm_eikonal_update(double a, double b, double c, double h) {
  // sort ascending
  if (a > b) std::swap(a, b);
  if (b > c) std::swap(b, c);
  if (a > b) std::swap(a, b);

  double x = a + h;
  if (x <= b) return x;

  // two-axis solution
  const double s2 = 2.0 * h * h - (a - b) * (a - b);
  if (s2 < 0.0) return x;  // no real two-axis root; keep the one-axis value
  x = 0.5 * (a + b + std::sqrt(s2));
  if (x <= c) return x;

  // three-axis solution
  const double sum = a + b + c;
  const double disc = sum * sum - 3.0 * (a * a + b * b + c * c - h * h);
  if (disc < 0.0) return x;
  return (sum + std::sqrt(disc)) / 3.0;
}

// Fill |phi| by fast sweeping, holding the cells flagged in `frozen` (the
// interface band) at the values they already carry. 8 sweep directions in 3D,
// `passes` times over the whole set of 8.
inline void plsm_fast_sweep(int nx, int ny, int nz, std::vector<double>& mag,
                            const std::vector<char>& frozen, double h, int passes) {
  const int dirs[8][3] = {{1, 1, 1},   {-1, 1, 1},  {1, -1, 1},  {-1, -1, 1},
                          {1, 1, -1},  {-1, 1, -1}, {1, -1, -1}, {-1, -1, -1}};
  for (int p = 0; p < passes; ++p) {
    for (const auto& dir : dirs) {
      const int i0 = dir[0] > 0 ? 0 : nx - 1, i1 = dir[0] > 0 ? nx : -1;
      const int j0 = dir[1] > 0 ? 0 : ny - 1, j1 = dir[1] > 0 ? ny : -1;
      const int k0 = dir[2] > 0 ? 0 : nz - 1, k1 = dir[2] > 0 ? nz : -1;
      for (int k = k0; k != k1; k += dir[2])
        for (int j = j0; j != j1; j += dir[1])
          for (int i = i0; i != i1; i += dir[0]) {
            const std::size_t v = plsm_at(nx, ny, i, j, k);
            if (frozen[v]) continue;
            // The domain boundary is an OPEN boundary, not a wall: an
            // out-of-range neighbour contributes no constraint (kFar), so the
            // distance is measured to the interface and never to the box.
            const double ax =
                std::min(i > 0 ? mag[plsm_at(nx, ny, i - 1, j, k)] : kPlsmFar,
                         i + 1 < nx ? mag[plsm_at(nx, ny, i + 1, j, k)] : kPlsmFar);
            const double ay =
                std::min(j > 0 ? mag[plsm_at(nx, ny, i, j - 1, k)] : kPlsmFar,
                         j + 1 < ny ? mag[plsm_at(nx, ny, i, j + 1, k)] : kPlsmFar);
            const double az =
                std::min(k > 0 ? mag[plsm_at(nx, ny, i, j, k - 1)] : kPlsmFar,
                         k + 1 < nz ? mag[plsm_at(nx, ny, i, j, k + 1)] : kPlsmFar);
            const double cand = plsm_eikonal_update(ax, ay, az, h);
            if (cand < mag[v]) mag[v] = cand;
          }
    }
  }
}

// Re-make `phi` a signed distance, keeping its SIGN and its zero set. The band
// is pinned first by linear interpolation of phi's own crossings — so the
// interface does not drift while it is being re-distanced — and the sweep fills
// outward from there.
//
// `russo_smereka` replaces the along-axis crossing distance with the first-order
// PERPENDICULAR one |phi|/|grad phi| (J. Comput. Phys. 163:51-67, 2000), using
// the CENTRAL difference rather than their max — which is a stabiliser for their
// reinitialisation PDE and is BIASED used as a direct distance seed. PR 322
// measured the max shrinking the whole distance field. It applies only once phi
// genuinely IS a distance function; on a near-binary step seed it is not, and the
// edge ratio is what the seed needs.
inline void plsm_reinitialise(int nx, int ny, int nz, std::vector<double>& phi,
                              double h, int passes, bool russo_smereka = false) {
  const std::size_t n = static_cast<std::size_t>(nx) *
                        static_cast<std::size_t>(ny) *
                        static_cast<std::size_t>(nz);
  std::vector<char> frozen(n, 0);
  std::vector<double> mag(n, kPlsmFar);

  for (int k = 0; k < nz; ++k)
    for (int j = 0; j < ny; ++j)
      for (int i = 0; i < nx; ++i) {
        const std::size_t v = plsm_at(nx, ny, i, j, k);
        const double pv = phi[v];
        bool crosses = false;
        double best = kPlsmFar;
        const int off[6][3] = {{-1, 0, 0}, {1, 0, 0}, {0, -1, 0},
                               {0, 1, 0},  {0, 0, -1}, {0, 0, 1}};
        for (const auto& o : off) {
          const int ii = i + o[0], jj = j + o[1], kk = k + o[2];
          if (ii < 0 || ii >= nx || jj < 0 || jj >= ny || kk < 0 || kk >= nz)
            continue;
          const double pw = phi[plsm_at(nx, ny, ii, jj, kk)];
          if ((pv > 0.0) == (pw > 0.0)) continue;  // no crossing on this edge
          crosses = true;
          const double denom = std::fabs(pv) + std::fabs(pw);
          // A crossing with both ends at zero carries no sub-voxel information;
          // half a cell is the only defensible reading of it.
          const double t = denom > 0.0 ? std::fabs(pv) / denom : 0.5;
          best = std::min(best, t * h);
        }
        if (!crosses) continue;
        if (russo_smereka) {
          double g2 = 0.0;
          const int ax[3][3] = {{1, 0, 0}, {0, 1, 0}, {0, 0, 1}};
          for (const auto& a3 : ax) {
            const int im = i - a3[0], jm = j - a3[1], km = k - a3[2];
            const int ip = i + a3[0], jp = j + a3[1], kp = k + a3[2];
            const bool okm = im >= 0 && jm >= 0 && km >= 0;
            const bool okp = ip < nx && jp < ny && kp < nz;
            const double pm = okm ? phi[plsm_at(nx, ny, im, jm, km)] : pv;
            const double pp = okp ? phi[plsm_at(nx, ny, ip, jp, kp)] : pv;
            const double gc = (okm && okp) ? std::fabs(pp - pm) / 2.0
                                           : std::max(okp ? std::fabs(pp - pv) : 0.0,
                                                      okm ? std::fabs(pv - pm) : 0.0);
            g2 += gc * gc;
          }
          const double gmag = std::sqrt(g2);
          // The clamp is the degenerate case only: a cell whose neighbours are
          // all equal carries no direction, and the axis reading is all there is.
          if (gmag > 1e-30) best = std::min(best, std::fabs(pv) * h / gmag);
        }
        if (best < kPlsmFar) {
          frozen[v] = 1;
          mag[v] = best;
        }
      }

  plsm_fast_sweep(nx, ny, nz, mag, frozen, h, passes);

  for (std::size_t v = 0; v < n; ++v)
    phi[v] = (phi[v] > 0.0 ? 1.0 : -1.0) * (mag[v] >= kPlsmFar ? 1e6 : mag[v]);
}

}  // namespace topopt

#endif  // TOPOPT_PLSM_KERNEL_HPP_
