// levelset_kernel.hpp — the level-set FIELD KERNEL, lifted out of
// `levelset_probe.cpp` VERBATIM so a second harness can use it without a second
// implementation of it existing anywhere.
//
// ★ THIS FILE IS A MOVE, NOT A REWRITE. Every declaration below was cut from
// levelset_probe.cpp and pasted here unchanged, comments included; that file now
// includes this one from inside its own anonymous namespace, so the functions
// keep the internal linkage they had. `plsm_probe.cpp` includes it the same way.
// The move is verified rather than asserted: `evidence/.../s0_kernel_move/`
// holds a 3-iteration `--gridap-auto min` trajectory from BEFORE the move and
// one from AFTER, and `reproduce.sh` diffs their `iterations.csv`. They are
// byte-identical or the move is wrong.
//
// WHAT IS IN HERE, and nothing else:
//
//   Dims             the x-fastest grid index, core's own ordering
//   heaviside        GridapTopOpt's H_eta — rho = H_eta(-phi), H(0) = 0.5 exactly
//   dheaviside       its derivative DH_eta, the surface delta
//   grad_mag         |grad phi|, central differences
//   eikonal_update   the Godunov update for |grad d| = 1
//   fast_sweep       8-direction 3D fast sweeping
//   reinitialise     re-make phi a signed distance, keeping its zero set
//
// WHAT IS DELIBERATELY NOT IN HERE: the optimiser. The velocity, the Hilbertian
// extension, the volume bisection, the HJ advection and the certification all
// stay in levelset_probe.cpp, because `plsm_probe` does not optimise anything —
// R5 forbids it — and a header that offered them would invite it to.
//
// It is included INSIDE an anonymous namespace and so has no include guard that
// would be meaningful across translation units; the guard below is the ordinary
// double-inclusion one.

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

// ── (b) THE SMOOTHED HEAVISIDE ──────────────────────────────────────────────
// C1, compactly supported on [-eta, eta], H(0) = 0.5 exactly. `s` is -phi, so
// s > 0 is inside the material.
double heaviside(double s, double eta) {
  if (s <= -eta) return 0.0;
  if (s >= eta) return 1.0;
  return 0.5 * (1.0 + s / eta + std::sin(kPi * s / eta) / kPi);
}

// ── (1) THE SURFACE DELTA: DH_eta, their DERIVATIVE of the same Heaviside ────
//
// GridapTopOpt, src/Utilities.jl:
//     H_eta(t, eta)  = 1/2 (1 + t/eta + sin(pi t/eta)/pi)   for |t| <= eta
//     DH_eta(t, eta) = 1/(2 eta) (1 + cos(pi t/eta))        for |t| <= eta, else 0
// and DH is exactly d/dt of H, which is the consistency this file relies on:
// `heaviside` above IS their H_eta, so the delta below is its own derivative and
// there is no second smoothing law anywhere in this program.
//
// DH is EVEN in t, so it does not matter whether it is evaluated at phi (their
// sign convention) or at -phi (the argument `heaviside` takes here). It is
// written at phi, as theirs is.
double dheaviside(double t, double eta) {
  if (t <= -eta || t >= eta) return 0.0;
  return (1.0 + std::cos(kPi * t / eta)) / (2.0 * eta);
}

// |grad phi|, central differences, one-sided at the box face. This is their
// `norm ∘ ∇(φ)`. After reinitialisation it is ~1 by construction — which is the
// point: it is carried anyway so the delta stays a correct surface measure on
// the iterations where phi has drifted from a true distance.
double grad_mag(const Dims& d, const std::vector<double>& phi, int i, int j,
                int k, double h) {
  const double xm = phi[d.at(i > 0 ? i - 1 : 0, j, k)];
  const double xp = phi[d.at(i + 1 < d.nx ? i + 1 : d.nx - 1, j, k)];
  const double ym = phi[d.at(i, j > 0 ? j - 1 : 0, k)];
  const double yp = phi[d.at(i, j + 1 < d.ny ? j + 1 : d.ny - 1, k)];
  const double zm = phi[d.at(i, j, k > 0 ? k - 1 : 0)];
  const double zp = phi[d.at(i, j, k + 1 < d.nz ? k + 1 : d.nz - 1)];
  // The divisor is the ACTUAL span sampled: 2h in the interior, h against a face
  // where the two reads collapsed onto the same cell.
  const double sx = (i > 0 && i + 1 < d.nx) ? 2.0 * h : h;
  const double sy = (j > 0 && j + 1 < d.ny) ? 2.0 * h : h;
  const double sz = (k > 0 && k + 1 < d.nz) ? 2.0 * h : h;
  const double gx = (xp - xm) / sx, gy = (yp - ym) / sy, gz = (zp - zm) / sz;
  return std::sqrt(gx * gx + gy * gy + gz * gz);
}

// ── (f) REINITIALISATION: fast sweeping for the Eikonal |grad d| = 1 ────────
//
// The Godunov update at one cell, given the smallest |d| already known across
// each axis. Standard 3D form: try the 1-D solution, and only bring in the
// second and third axes when the candidate overtakes them.
double eikonal_update(double a, double b, double c, double h) {
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
void fast_sweep(const Dims& d, std::vector<double>& mag,
                const std::vector<char>& frozen, double h, int passes) {
  const int dirs[8][3] = {{1, 1, 1},   {-1, 1, 1},  {1, -1, 1},  {-1, -1, 1},
                          {1, 1, -1},  {-1, 1, -1}, {1, -1, -1}, {-1, -1, -1}};
  for (int p = 0; p < passes; ++p) {
    for (const auto& dir : dirs) {
      const int i0 = dir[0] > 0 ? 0 : d.nx - 1, i1 = dir[0] > 0 ? d.nx : -1;
      const int j0 = dir[1] > 0 ? 0 : d.ny - 1, j1 = dir[1] > 0 ? d.ny : -1;
      const int k0 = dir[2] > 0 ? 0 : d.nz - 1, k1 = dir[2] > 0 ? d.nz : -1;
      for (int k = k0; k != k1; k += dir[2])
        for (int j = j0; j != j1; j += dir[1])
          for (int i = i0; i != i1; i += dir[0]) {
            const std::size_t v = d.at(i, j, k);
            if (frozen[v]) continue;
            // The domain boundary is an OPEN boundary, not a wall: an
            // out-of-range neighbour contributes no constraint (kFar), so the
            // distance is measured to the interface and never to the box.
            const double ax =
                std::min(i > 0 ? mag[d.at(i - 1, j, k)] : kFar,
                         i + 1 < d.nx ? mag[d.at(i + 1, j, k)] : kFar);
            const double ay =
                std::min(j > 0 ? mag[d.at(i, j - 1, k)] : kFar,
                         j + 1 < d.ny ? mag[d.at(i, j + 1, k)] : kFar);
            const double az =
                std::min(k > 0 ? mag[d.at(i, j, k - 1)] : kFar,
                         k + 1 < d.nz ? mag[d.at(i, j, k + 1)] : kFar);
            const double cand = eikonal_update(ax, ay, az, h);
            if (cand < mag[v]) mag[v] = cand;
          }
    }
  }
}

// Re-make `phi` a signed distance, keeping its SIGN and its zero set. The band
// is pinned first by linear interpolation of phi's own crossings — so the
// interface does not drift while it is being re-distanced — and the sweep fills
// outward from there.
void reinitialise(const Dims& d, std::vector<double>& phi, double h, int passes,
                  bool russo_smereka = false) {
  const std::size_t n = d.count();
  std::vector<char> frozen(n, 0);
  std::vector<double> mag(n, kFar);

  for (int k = 0; k < d.nz; ++k)
    for (int j = 0; j < d.ny; ++j)
      for (int i = 0; i < d.nx; ++i) {
        const std::size_t v = d.at(i, j, k);
        const double pv = phi[v];
        bool crosses = false;
        double best = kFar;
        const int off[6][3] = {{-1, 0, 0}, {1, 0, 0}, {0, -1, 0},
                               {0, 1, 0},  {0, 0, -1}, {0, 0, 1}};
        for (const auto& o : off) {
          const int ii = i + o[0], jj = j + o[1], kk = k + o[2];
          if (ii < 0 || ii >= d.nx || jj < 0 || jj >= d.ny || kk < 0 ||
              kk >= d.nz)
            continue;
          const double pw = phi[d.at(ii, jj, kk)];
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
          // ── RUSSO-SMEREKA SUBCELL FIX (J. Comput. Phys. 163:51-67, 2000) ──
          //
          // ★ WHY THE EDGE RATIO IS NOT GOOD ENOUGH, AND WHY IT SHOWS UP IN THE
          // SUB-VOXEL METRIC. The `best` above is the smallest ALONG-AXIS
          // distance to a crossing. For an interface that runs obliquely through
          // the cell — which on this part is most of it — the axis distance
          // OVERESTIMATES the true perpendicular distance by up to sqrt(3). The
          // sweep then propagates that overestimate outward, and the whole field
          // ends up with |grad phi| < 1: measured RMS error 0.20 on the run of
          // record, against the reference's own reinitialisation tolerance of
          // 0.00645.
          //
          // That is not cosmetic. rho = H_eta(-phi) maps phi linearly through the
          // band, so a phi whose gradient is 20% wrong puts the iso-0.5 crossing
          // in the wrong place inside the cell — and "where the crossing sits
          // inside the cell" IS the sub-voxel measurement (`midpoint_share`).
          // PR 321's Gridap arm spread its crossings 0.5790 mm rms against our
          // 0.2601 on the same lattice with the same band, which is the
          // signature of a cleaner distance function.
          //
          // Russo-Smereka's fix replaces the axis distance with the FIRST-ORDER
          // PERPENDICULAR one, |phi| / |grad phi|, using a robust one-sided
          // gradient so a crossing on either side is seen:
          //
          //     D_i = h * phi_i / max(|phi_{i+1}-phi_{i-1}|/2,
          //                           |phi_{i+1}-phi_i|, |phi_i-phi_{i-1}|)
          //
          // generalised to 3D by taking that per axis and combining in L2. The
          // result is the distance to the LINEARISED interface through the cell,
          // which is exact for a plane and is what the sweep should propagate.
          double g2 = 0.0;
          const int ax[3][3] = {{1, 0, 0}, {0, 1, 0}, {0, 0, 1}};
          for (const auto& a3 : ax) {
            const int im = i - a3[0], jm = j - a3[1], km = k - a3[2];
            const int ip = i + a3[0], jp = j + a3[1], kp = k + a3[2];
            const bool okm = im >= 0 && jm >= 0 && km >= 0;
            const bool okp = ip < d.nx && jp < d.ny && kp < d.nz;
            const double pm = okm ? phi[d.at(im, jm, km)] : pv;
            const double pp = okp ? phi[d.at(ip, jp, kp)] : pv;
            // ★ CENTRAL, NOT THE MAX — AND THIS WAS MEASURED, NOT ASSUMED.
            // Russo-Smereka's Delta_i takes max(central, forward, backward),
            // but that is a STABILISER for their reinitialisation PDE, where an
            // over-large denominator damps the update. Used here as a direct
            // distance seed it is BIASED: at a kink the max overshoots the true
            // |grad phi|, so |phi|/|grad phi| undershoots the true distance, and
            // the sweep propagates the shortfall over the whole field. Measured
            // with the max, 6 iterations: interface area 28073 -> 26606 against
            // the baseline's 24057, and | |grad phi|-1 | rising 0.173 -> 0.190
            // against 0.171 — both the signature of a uniformly shrunk distance
            // field (phi too flat, so more cells fall inside the band). The
            // central difference is the unbiased estimate for the smooth field
            // this is applied to.
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
        if (best < kFar) {
          frozen[v] = 1;
          mag[v] = best;
        }
      }

  fast_sweep(d, mag, frozen, h, passes);

  for (std::size_t v = 0; v < n; ++v)
    phi[v] = (phi[v] > 0.0 ? 1.0 : -1.0) * (mag[v] >= kFar ? 1e6 : mag[v]);
}

#endif  // TOPOPT_TESTS_HARNESS_LEVELSET_KERNEL_HPP_
