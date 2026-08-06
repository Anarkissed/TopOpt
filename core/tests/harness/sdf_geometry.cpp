// sdf_geometry.cpp — implementation of the arXiv:2512.06976 pipeline on a
// regular grid. See sdf_geometry.hpp for what each stage is and for every place
// this port differs from rho2sdf.jl.

#include "sdf_geometry.hpp"

#include <chrono>
#include <cstring>

namespace topopt {
namespace sdfgeom {
namespace {

using Clock = std::chrono::steady_clock;
double secs_since(const Clock::time_point& t) {
  return std::chrono::duration<double>(Clock::now() - t).count();
}

// Ericson, Real-Time Collision Detection §5.1.5 — the same closest-point-on-
// triangle routine PR 299's TriGrid uses, needed here for the SDF's own distance
// field (the METRIC's copy stays in stairstep_metric.hpp, untouched).
double dist2_point_triangle(const Vec3& p, const Vec3& a, const Vec3& b,
                            const Vec3& c) {
  const Vec3 ab{b.x - a.x, b.y - a.y, b.z - a.z};
  const Vec3 ac{c.x - a.x, c.y - a.y, c.z - a.z};
  const Vec3 ap{p.x - a.x, p.y - a.y, p.z - a.z};
  const double d1 = ab.x * ap.x + ab.y * ap.y + ab.z * ap.z;
  const double d2 = ac.x * ap.x + ac.y * ap.y + ac.z * ap.z;
  auto d2_to = [&](const Vec3& q) {
    const double dx = p.x - q.x, dy = p.y - q.y, dz = p.z - q.z;
    return dx * dx + dy * dy + dz * dz;
  };
  if (d1 <= 0.0 && d2 <= 0.0) return d2_to(a);
  const Vec3 bp{p.x - b.x, p.y - b.y, p.z - b.z};
  const double d3 = ab.x * bp.x + ab.y * bp.y + ab.z * bp.z;
  const double d4 = ac.x * bp.x + ac.y * bp.y + ac.z * bp.z;
  if (d3 >= 0.0 && d4 <= d3) return d2_to(b);
  const double vc = d1 * d4 - d3 * d2;
  if (vc <= 0.0 && d1 >= 0.0 && d3 <= 0.0) {
    const double v = d1 / (d1 - d3);
    return d2_to(Vec3{a.x + v * ab.x, a.y + v * ab.y, a.z + v * ab.z});
  }
  const Vec3 cp{p.x - c.x, p.y - c.y, p.z - c.z};
  const double d5 = ab.x * cp.x + ab.y * cp.y + ab.z * cp.z;
  const double d6 = ac.x * cp.x + ac.y * cp.y + ac.z * cp.z;
  if (d6 >= 0.0 && d5 <= d6) return d2_to(c);
  const double vb = d5 * d2 - d1 * d6;
  if (vb <= 0.0 && d2 >= 0.0 && d6 <= 0.0) {
    const double w = d2 / (d2 - d6);
    return d2_to(Vec3{a.x + w * ac.x, a.y + w * ac.y, a.z + w * ac.z});
  }
  const double va = d3 * d6 - d5 * d4;
  if (va <= 0.0 && (d4 - d3) >= 0.0 && (d5 - d6) >= 0.0) {
    const double w = (d4 - d3) / ((d4 - d3) + (d5 - d6));
    return d2_to(Vec3{b.x + w * (c.x - b.x), b.y + w * (c.y - b.y),
                      b.z + w * (c.z - b.z)});
  }
  const double denom = 1.0 / (va + vb + vc);
  const double v = vb * denom, w = vc * denom;
  return d2_to(Vec3{a.x + ab.x * v + ac.x * w, a.y + ab.y * v + ac.y * w,
                    a.z + ab.z * v + ac.z * w});
}

}  // namespace

// Gauss-Legendre nodes/weights on [-1,1] by Newton iteration on P_n. The
// reference gets these from FastGaussQuadrature; agreement to 1e-14 was checked
// against its published order-9 table before this was used.
double lattice_gauss_nodes(int order, std::vector<double>& gp,
                           std::vector<double>& w) {
  const int n = std::max(1, order);
  gp.assign(static_cast<std::size_t>(n), 0.0);
  w.assign(static_cast<std::size_t>(n), 0.0);
  const double pi = 3.14159265358979323846;
  for (int i = 0; i < (n + 1) / 2; ++i) {
    double x = std::cos(pi * (i + 0.75) / (n + 0.5));
    double dp = 0.0;
    for (int it = 0; it < 100; ++it) {
      double p0 = 1.0, p1 = 0.0;
      for (int j = 0; j < n; ++j) {
        const double p2 = p1;
        p1 = p0;
        p0 = ((2.0 * j + 1.0) * x * p1 - j * p2) / (j + 1.0);
      }
      dp = n * (x * p0 - p1) / (x * x - 1.0);
      const double dx = -p0 / dp;
      x += dx;
      if (std::fabs(dx) < 1e-15) break;
    }
    gp[static_cast<std::size_t>(i)] = -x;
    gp[static_cast<std::size_t>(n - 1 - i)] = x;
    const double ww = 2.0 / ((1.0 - x * x) * dp * dp);
    w[static_cast<std::size_t>(i)] = ww;
    w[static_cast<std::size_t>(n - 1 - i)] = ww;
  }
  return 0.0;
}

double SurfBins::distance(const Vec3& p, double give_up) const {
  if (!mesh_ || items_.empty()) return give_up;
  double best2 = std::numeric_limits<double>::infinity();
  double r = cell_;
  for (int iter = 0; iter < 64; ++iter) {
    const int i0 = ci(p.x - r - origin_.x, nx_), i1 = ci(p.x + r - origin_.x, nx_);
    const int j0 = ci(p.y - r - origin_.y, ny_), j1 = ci(p.y + r - origin_.y, ny_);
    const int k0 = ci(p.z - r - origin_.z, nz_), k1 = ci(p.z + r - origin_.z, nz_);
    for (int k = k0; k <= k1; ++k)
      for (int j = j0; j <= j1; ++j)
        for (int i = i0; i <= i1; ++i) {
          const std::size_t b = bidx(i, j, k);
          for (int q = start_[b]; q < start_[b + 1]; ++q) {
            const auto& tr =
                mesh_->triangles[static_cast<std::size_t>(items_[static_cast<std::size_t>(q)])];
            const double d2 = dist2_point_triangle(
                p, mesh_->vertices[static_cast<std::size_t>(tr[0])],
                mesh_->vertices[static_cast<std::size_t>(tr[1])],
                mesh_->vertices[static_cast<std::size_t>(tr[2])]);
            if (d2 < best2) best2 = d2;
          }
        }
    if (best2 <= r * r) break;          // exact: nothing outside the box can win
    if (r > give_up && best2 > give_up * give_up) return give_up;  // banded
    r *= 2.0;
  }
  return std::fmin(std::sqrt(best2), give_up);
}

SdfBuild build_sdf(const Lattice& nodal, double level, double B, int iso_refine,
                   double band_cells) {
  const auto t0 = Clock::now();
  SdfBuild out;

  // (i) the isocontour, tessellated. Same surface the reference projects onto
  // analytically; see the header note on why this port tessellates it instead.
  const TriangleMesh iso = marching_cubes_resampled(
      nodal.nx, nodal.ny, nodal.nz, nodal.h, nodal.mc_origin(), nodal.v, level,
      iso_refine, ResampleInterp::Trilinear);
  out.iso_tris = iso.triangles.size();
  if (iso.triangles.empty()) return out;

  // (ii) the Cartesian grid. Padded so the zero level is strictly interior and
  // the RBF stencil never reaches past the array.
  const double band = band_cells * B;
  const int pad = static_cast<int>(std::ceil(band_cells)) + 4;
  const double ex = (nodal.nx - 1) * nodal.h;
  const double ey = (nodal.ny - 1) * nodal.h;
  const double ez = (nodal.nz - 1) * nodal.h;
  Lattice& phi = out.phi;
  phi.h = B;
  phi.nx = static_cast<int>(std::ceil(ex / B)) + 1 + 2 * pad;
  phi.ny = static_cast<int>(std::ceil(ey / B)) + 1 + 2 * pad;
  phi.nz = static_cast<int>(std::ceil(ez / B)) + 1 + 2 * pad;
  phi.origin = Vec3{nodal.origin.x - pad * B, nodal.origin.y - pad * B,
                    nodal.origin.z - pad * B};
  phi.v.assign(phi.count(), 0.0);
  out.band_mm = band;

  const SurfBins bins(iso, std::fmax(B, 0.5 * nodal.h));

  std::atomic<std::size_t> banded{0};
  parallel_for(phi.count(), [&](std::size_t n) {
    const int i = static_cast<int>(n % phi.nx);
    const int j = static_cast<int>((n / phi.nx) % phi.ny);
    const int k = static_cast<int>(n / (static_cast<std::size_t>(phi.nx) * phi.ny));
    const Vec3 p = phi.point(i, j, k);
    // §4.2.2 sign: interpolate the nodal density here and compare with rho_t.
    // Outside the FE domain the sample reads 0, which is below any usable
    // threshold — the reference's "negative for nodes outside all elements".
    const double rho = nodal.sample(p, 0.0);
    const double d = bins.distance(p, band);
    if (d < band) banded.fetch_add(1, std::memory_order_relaxed);
    phi.v[n] = (rho >= level ? 1.0 : -1.0) * d;
  });
  out.band_points = banded.load();
  out.wall_s = secs_since(t0);
  return out;
}

namespace {

// The truncated-Gaussian stencil, in CELL units. On a regular grid of spacing B
// with the paper's B = h, R(r) = exp(-(r/B)^2) = exp(-|offset|^2), so the stencil
// is the same 81 entries at every grid point and for every B. That is what makes
// A applicable without ever being stored.
struct Stencil {
  std::vector<int> di, dj, dk;
  std::vector<double> w;
};

Stencil build_stencil(double cutoff) {
  const double rc = std::sqrt(-std::log(cutoff));  // 2.6283 for 1e-3
  const int R = static_cast<int>(std::floor(rc));
  Stencil s;
  for (int k = -R; k <= R; ++k)
    for (int j = -R; j <= R; ++j)
      for (int i = -R; i <= R; ++i) {
        const double r2 = static_cast<double>(i * i + j * j + k * k);
        if (r2 > rc * rc) continue;
        const double val = std::exp(-r2);
        if (val <= cutoff) continue;
        s.di.push_back(i);
        s.dj.push_back(j);
        s.dk.push_back(k);
        s.w.push_back(val);
      }
  return s;
}

void apply_A(const Lattice& L, const Stencil& s, const std::vector<double>& x,
             std::vector<double>& y) {
  y.assign(x.size(), 0.0);
  parallel_for(L.count(), [&](std::size_t n) {
    const int i = static_cast<int>(n % L.nx);
    const int j = static_cast<int>((n / L.nx) % L.ny);
    const int k = static_cast<int>(n / (static_cast<std::size_t>(L.nx) * L.ny));
    double acc = 0.0;
    for (std::size_t q = 0; q < s.w.size(); ++q) {
      const int a = i + s.di[q], b = j + s.dj[q], c = k + s.dk[q];
      if (a < 0 || b < 0 || c < 0) continue;
      if (a >= L.nx || b >= L.ny || c >= L.nz) continue;
      acc += s.w[q] * x[L.idx(a, b, c)];
    }
    y[n] = acc;
  });
}

double dotv(const std::vector<double>& a, const std::vector<double>& b) {
  double s = 0.0;
  for (std::size_t i = 0; i < a.size(); ++i) s += a[i] * b[i];
  return s;
}

}  // namespace

RbfResult rbf_smooth(const Lattice& phi, RbfMode mode, int fine,
                     double kernel_cutoff, int cg_max, double cg_tol) {
  const auto t0 = Clock::now();
  RbfResult out;
  const Stencil st = build_stencil(kernel_cutoff);

  // (i) the weights s.
  std::vector<double> s;
  if (mode == RbfMode::Approximation) {
    s = phi.v;  // the reference's `vec(raw_SDF)` — a Gaussian CONVOLUTION
  } else {
    // A s = phi, matrix-free CG. The reference calls IterativeSolvers.cg on the
    // sparse kernel matrix; same operator, same right-hand side.
    s.assign(phi.v.size(), 0.0);
    std::vector<double> r = phi.v, p = r, Ap;
    double rr = dotv(r, r);
    const double b0 = std::sqrt(std::fmax(rr, 1e-300));
    int it = 0;
    for (; it < cg_max; ++it) {
      apply_A(phi, st, p, Ap);
      const double pAp = dotv(p, Ap);
      if (!(pAp > 0.0)) break;  // truncation can cost positive-definiteness
      const double alpha = rr / pAp;
      for (std::size_t i = 0; i < s.size(); ++i) {
        s[i] += alpha * p[i];
        r[i] -= alpha * Ap[i];
      }
      const double rr2 = dotv(r, r);
      if (std::sqrt(rr2) <= cg_tol * b0) { rr = rr2; ++it; break; }
      const double beta = rr2 / rr;
      rr = rr2;
      for (std::size_t i = 0; i < p.size(); ++i) p[i] = r[i] + beta * p[i];
    }
    out.cg_iterations = it;
    out.cg_residual = std::sqrt(std::fmax(rr, 0.0)) / b0;
  }

  // (ii) evaluate the RBF sum on the fine lattice (spacing B/fine).
  const int f = std::max(1, fine);
  Lattice& g = out.phi;
  g.h = phi.h / f;
  g.nx = (phi.nx - 1) * f + 1;
  g.ny = (phi.ny - 1) * f + 1;
  g.nz = (phi.nz - 1) * f + 1;
  g.origin = phi.origin;
  g.v.assign(g.count(), 0.0);
  const double rc = std::sqrt(-std::log(kernel_cutoff));
  parallel_for(g.count(), [&](std::size_t n) {
    const int mi = static_cast<int>(n % g.nx);
    const int mj = static_cast<int>((n / g.nx) % g.ny);
    const int mk = static_cast<int>(n / (static_cast<std::size_t>(g.nx) * g.ny));
    const double u = static_cast<double>(mi) / f;   // position in COARSE cells
    const double v = static_cast<double>(mj) / f;
    const double w = static_cast<double>(mk) / f;
    const int i0 = std::max(0, static_cast<int>(std::ceil(u - rc)));
    const int i1 = std::min(phi.nx - 1, static_cast<int>(std::floor(u + rc)));
    const int j0 = std::max(0, static_cast<int>(std::ceil(v - rc)));
    const int j1 = std::min(phi.ny - 1, static_cast<int>(std::floor(v + rc)));
    const int k0 = std::max(0, static_cast<int>(std::ceil(w - rc)));
    const int k1 = std::min(phi.nz - 1, static_cast<int>(std::floor(w + rc)));
    double acc = 0.0;
    for (int k = k0; k <= k1; ++k) {
      const double dz = w - k, dz2 = dz * dz;
      for (int j = j0; j <= j1; ++j) {
        const double dy = v - j, dyz2 = dz2 + dy * dy;
        if (dyz2 > rc * rc) continue;
        for (int i = i0; i <= i1; ++i) {
          const double dx = u - i;
          const double r2 = dyz2 + dx * dx;
          if (r2 > rc * rc) continue;
          acc += s[phi.idx(i, j, k)] * std::exp(-r2);
        }
      }
    }
    g.v[n] = acc;
  });
  out.wall_s = secs_since(t0);
  return out;
}

ShiftResult volume_shift(const Lattice& phi, double target, int order,
                         double tol, int max_it) {
  double lo = phi.v.empty() ? 0.0 : phi.v[0], hi = lo;
  for (double x : phi.v) {
    lo = std::fmin(lo, x);
    hi = std::fmax(hi, x);
  }
  // {phi + c >= 0} == {phi >= -c}, so solving for the LEVEL and negating gives
  // the reference's `LS_Threshold`, which returns -th for exactly this reason.
  const ThresholdResult t = find_level_for_volume(phi, target, lo, hi, order,
                                                  tol, max_it);
  ShiftResult r;
  r.c = -t.level;
  r.volume = t.volume;
  r.rel_err = t.rel_err;
  r.iterations = t.iterations;
  return r;
}

}  // namespace sdfgeom
}  // namespace topopt
