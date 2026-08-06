// sdf_geometry.hpp — the Ježek/Kopačka/Isoz/Gabriel/Šotola/Maršálek/Rybanský/
// Halama SDF geometry-extraction pipeline, "Smooth geometry extraction from SIMP
// topology optimization: Signed distance function approach with volume
// preservation", Advances in Engineering Software (2025), arXiv:2512.06976,
// specialised to a REGULAR hexahedral grid.
//
// MEASUREMENT CODE, NOT PRODUCTION. Nothing in core/src or core/include calls
// this; it exists so task 2026-08-05-smoothing-sdf-geometry-extraction can put a
// number on the method before anyone decides whether to port it. Whether any of
// it becomes production is the maintainer's decision AFTER the number exists.
//
// *** WHY THIS IS A PORT AND NOT THE REFERENCE IMPLEMENTATION. *** The paper's
// reference implementation is rho2sdf.jl (MIT, v0.1.0). It cannot be driven from
// the maintainer's density field as it stands: `Sign_Detection_HEX8`
// (src/SignedDistances/SignDetection.jl:29) builds its candidate list with
//
//     candidate_elements = [el for el in 1:nel if is_point_inside_aabb(x, ...)]
//
// inside a loop over every grid point — an O(n_grid x n_elements) scan. The
// maintainer's run is 468,224 elements and the SDF grid at the paper's own
// recommended spacing is 487,620 points, so that line alone is 2.3e11 AABB
// tests. The full record of what was tried, and what the reference WAS run on,
// is in the handoff's S1 and in evidence/.../julia_reference/.
//
// So the pipeline below is a port. Everything it does differently from the
// reference is because the grid is regular, and every such simplification is
// named at its site. The port is cross-checked against rho2sdf.jl itself on a
// case small enough for the reference to finish
// (evidence/.../julia_reference/crosscheck_result.txt).
//
// THE PIPELINE, in the paper's own order (§4):
//   4.1  element densities -> NODAL densities by a least-squares linear fit over
//        the centres of the elements sharing each node.
//   4.1  the boundary is the ISOCONTOUR of the shape-function interpolation of
//        that nodal field at a threshold rho_t chosen so the enclosed volume
//        equals the raw design's volume.
//   4.2  a discrete SIGNED DISTANCE FUNCTION on a regular Cartesian grid:
//        distance to that isocontour, sign from the interpolated density.
//   4.3  RBF smoothing with Gaussian basis functions, scaling parameter B equal
//        to the grid spacing, plus a UNIFORM SHIFT c solved so the zero level
//        encloses the target volume.
//   4.4  re-extraction of the surface.

#pragma once

#include "topopt/mesh.hpp"
#include "topopt/voxel.hpp"

#include <algorithm>
#include <atomic>
#include <cmath>
#include <cstdio>
#include <limits>
#include <thread>
#include <vector>

namespace topopt {
namespace sdfgeom {

// ── a small parallel-for, so the sweeps finish ───────────────────────────────
template <typename F>
void parallel_for(std::size_t n, const F& body) {
  const unsigned hw = std::max(1u, std::thread::hardware_concurrency());
  const std::size_t nt = std::min<std::size_t>(hw, std::max<std::size_t>(1, n));
  if (nt <= 1) {
    for (std::size_t i = 0; i < n; ++i) body(i);
    return;
  }
  std::vector<std::thread> ts;
  ts.reserve(nt);
  std::atomic<std::size_t> next{0};
  const std::size_t chunk = std::max<std::size_t>(1, n / (nt * 16));
  for (std::size_t t = 0; t < nt; ++t) {
    ts.emplace_back([&]() {
      for (;;) {
        const std::size_t b = next.fetch_add(chunk);
        if (b >= n) return;
        const std::size_t e = std::min(n, b + chunk);
        for (std::size_t i = b; i < e; ++i) body(i);
      }
    });
  }
  for (auto& t : ts) t.join();
}

// ── a scalar field sampled on a regular POINT lattice ────────────────────────
//
// `n*` are POINT counts, and sample (i,j,k) sits at origin + (i,j,k)*h exactly.
// Both the nodal density field and the SDF are this shape. Note the contrast
// with VoxelGrid, whose field samples are voxel CENTRES — the conversion is
// `mc_origin()` below and it is the only place the two conventions meet.
struct Lattice {
  int nx = 0, ny = 0, nz = 0;
  double h = 0.0;
  Vec3 origin{0.0, 0.0, 0.0};
  std::vector<double> v;

  std::size_t count() const {
    return static_cast<std::size_t>(nx) * ny * nz;
  }
  std::size_t idx(int i, int j, int k) const {
    return (static_cast<std::size_t>(k) * ny + j) * nx + i;
  }
  Vec3 point(int i, int j, int k) const {
    return Vec3{origin.x + i * h, origin.y + j * h, origin.z + k * h};
  }
  // `marching_cubes` places field sample m at origin_mc + (m+0.5)*spacing, i.e.
  // it reads samples as voxel CENTRES. Handing it this lattice therefore needs
  // the origin pushed back half a cell, and then sample (i,j,k) lands exactly on
  // point(i,j,k). Getting this wrong shifts the whole extracted surface by half
  // a cell, which is 0.81 mm on the maintainer's part — larger than the entire
  // effect being measured.
  Vec3 mc_origin() const {
    return Vec3{origin.x - 0.5 * h, origin.y - 0.5 * h, origin.z - 0.5 * h};
  }

  // Tri-linear sample; outside the lattice reads `outside`.
  double sample(const Vec3& p, double outside) const {
    const double fx = (p.x - origin.x) / h;
    const double fy = (p.y - origin.y) / h;
    const double fz = (p.z - origin.z) / h;
    if (fx < 0.0 || fy < 0.0 || fz < 0.0) return outside;
    if (fx > nx - 1 || fy > ny - 1 || fz > nz - 1) return outside;
    int i = std::min(nx - 2, std::max(0, static_cast<int>(std::floor(fx))));
    int j = std::min(ny - 2, std::max(0, static_cast<int>(std::floor(fy))));
    int k = std::min(nz - 2, std::max(0, static_cast<int>(std::floor(fz))));
    if (nx == 1) i = 0;
    if (ny == 1) j = 0;
    if (nz == 1) k = 0;
    const double tx = fx - i, ty = fy - j, tz = fz - k;
    const int i1 = std::min(i + 1, nx - 1), j1 = std::min(j + 1, ny - 1),
              k1 = std::min(k + 1, nz - 1);
    const double c00 = v[idx(i, j, k)] * (1 - tx) + v[idx(i1, j, k)] * tx;
    const double c10 = v[idx(i, j1, k)] * (1 - tx) + v[idx(i1, j1, k)] * tx;
    const double c01 = v[idx(i, j, k1)] * (1 - tx) + v[idx(i1, j, k1)] * tx;
    const double c11 = v[idx(i, j1, k1)] * (1 - tx) + v[idx(i1, j1, k1)] * tx;
    const double c0 = c00 * (1 - ty) + c10 * ty;
    const double c1 = c01 * (1 - ty) + c11 * ty;
    return c0 * (1 - tz) + c1 * tz;
  }
};

// ── §4.1  elemental densities -> nodal densities ─────────────────────────────
//
// The paper fits a linear polynomial rho(x) = a^T (1,x)^T to the densities of the
// elements sharing a node, in the least-squares sense (eq. 7-9), and evaluates it
// AT THE NODE.
//
// *** ON A REGULAR GRID THAT FIT IS THE ARITHMETIC MEAN, exactly. *** The design
// matrix rows are (1, c_e) for the element centres c_e sharing the node, and on a
// regular grid those centres are symmetric about the node: their centroid IS the
// node. For any least-squares linear fit the fitted value at the centroid of the
// design points equals the mean of the data — the normal equations' first row is
// exactly sum_e (a0 + a·c_e) = sum_e rho_e, and sum_e (c_e - node) = 0 kills the
// linear part. This holds for interior nodes (8 elements), face nodes (4),
// edge nodes (2) and corner nodes (1) alike, because each of those sets is still
// symmetric about the node in the directions it spans, and the fit is rank-
// deficient in the directions it does not span (which is exactly what the
// reference's `LamReduction` eigenvalue-truncation handles).
//
// So this function is the reference's `DenseInNodes` specialised, not
// approximated. The claim is CHECKED against rho2sdf.jl rather than asserted —
// see evidence/.../julia_reference/cross_check.txt.
//
// *** THE ONE-ELEMENT ZERO PAD, AND WHY IT IS NOT OPTIONAL. *** The FE domain
// stops at the design grid's outer wall, and a design that reaches that wall has
// its boundary THERE. The reference treats that case explicitly: a fully solid
// element at the domain boundary contributes its outer FACE to the isocontour
// (`process_boundary_faces!`, the paper's §4.2.1 case 2). Marching cubes has no
// such concept — it pads the sample array with background and closes the surface
// HALF A CELL beyond the last sample. Building the nodal lattice on the raw
// element grid therefore hangs the surface h/2 = 0.81 mm outside the part
// wherever it touches the wall, which on the maintainer's 20 mm plate is its
// whole top and bottom face. Measured: it cost 0.13 mm of all-vertex RMS and
// 0.37 mm of oblique max — larger than the entire effect being measured, and in
// the direction that would have made the method look like it damages the part.
//
// Padding the ELEMENT grid with one ring of zero-density elements first makes
// the two agree exactly: a boundary node then averages its 4 solid neighbours
// with 4 empty ones and reads 0.5, so the isocontour lands ON the wall, which is
// what the reference's boundary-face case produces.
inline Lattice nodal_from_elements(const VoxelGrid& g_in,
                                   const std::vector<double>& rho_in) {
  VoxelGrid g;
  g.nx = g_in.nx + 2;
  g.ny = g_in.ny + 2;
  g.nz = g_in.nz + 2;
  g.spacing = g_in.spacing;
  g.origin = Vec3{g_in.origin.x - g_in.spacing, g_in.origin.y - g_in.spacing,
                  g_in.origin.z - g_in.spacing};
  g.tags.assign(static_cast<std::size_t>(g.nx) * g.ny * g.nz, VoxelTag::Empty);
  std::vector<double> rho_e(g.tags.size(), 0.0);
  for (int k = 0; k < g_in.nz; ++k)
    for (int j = 0; j < g_in.ny; ++j)
      for (int i = 0; i < g_in.nx; ++i)
        rho_e[g.index(i + 1, j + 1, k + 1)] = rho_in[g_in.index(i, j, k)];

  Lattice nd;
  nd.nx = g.nx + 1;
  nd.ny = g.ny + 1;
  nd.nz = g.nz + 1;
  nd.h = g.spacing;
  nd.origin = g.origin;  // node (0,0,0) is the padded grid's minimum CORNER
  nd.v.assign(nd.count(), 0.0);
  parallel_for(nd.count(), [&](std::size_t n) {
    const int i = static_cast<int>(n % nd.nx);
    const int j = static_cast<int>((n / nd.nx) % nd.ny);
    const int k = static_cast<int>(n / (static_cast<std::size_t>(nd.nx) * nd.ny));
    double s = 0.0;
    int c = 0;
    for (int dk = -1; dk <= 0; ++dk)
      for (int dj = -1; dj <= 0; ++dj)
        for (int di = -1; di <= 0; ++di) {
          const int ei = i + di, ej = j + dj, ek = k + dk;
          if (ei < 0 || ej < 0 || ek < 0) continue;
          if (ei >= g.nx || ej >= g.ny || ek >= g.nz) continue;
          s += rho_e[g.index(ei, ej, ek)];
          ++c;
        }
    nd.v[n] = c ? s / c : 0.0;
  });
  return nd;
}

// ── volume enclosed by an isocontour of a lattice field ──────────────────────
//
// The reference's `calculate_isocontour_volume` / `calculate_volume_from_sdf`:
// a cell whose eight corner values are all below the level contributes nothing,
// one whose eight are all at or above it contributes its whole volume, and one
// the level crosses is integrated by Gauss-Legendre point counting on the
// tri-linear interpolant. `order` is the reference's `detailed_quad_order`.
double lattice_gauss_nodes(int order, std::vector<double>& gp,
                           std::vector<double>& w);

inline double iso_volume(const Lattice& L, double iso, int order) {
  std::vector<double> gp, w;
  lattice_gauss_nodes(order, gp, w);
  const double cellv = L.h * L.h * L.h;
  const std::size_t ncell = static_cast<std::size_t>(std::max(0, L.nx - 1)) *
                            std::max(0, L.ny - 1) * std::max(0, L.nz - 1);
  if (ncell == 0) return 0.0;
  const int cx = L.nx - 1, cy = L.ny - 1;
  const unsigned nthreads = std::max(1u, std::thread::hardware_concurrency());
  std::vector<double> partial(nthreads, 0.0);

  auto worker = [&](unsigned tid) {
    double acc = 0.0;
    for (std::size_t c = tid; c < ncell; c += nthreads) {
      const int i = static_cast<int>(c % cx);
      const int j = static_cast<int>((c / cx) % cy);
      const int k = static_cast<int>(c / (static_cast<std::size_t>(cx) * cy));
      double vv[8];
      int m = 0;
      for (int dk = 0; dk < 2; ++dk)
        for (int dj = 0; dj < 2; ++dj)
          for (int di = 0; di < 2; ++di)
            vv[m++] = L.v[L.idx(i + di, j + dj, k + dk)];
      double lo = vv[0], hi = vv[0];
      for (int q = 1; q < 8; ++q) {
        lo = std::fmin(lo, vv[q]);
        hi = std::fmax(hi, vv[q]);
      }
      if (hi < iso) continue;             // wholly outside
      if (lo >= iso) { acc += cellv; continue; }   // wholly inside

      const double jac = cellv / 8.0;
      const int n = static_cast<int>(gp.size());
      double add = 0.0;
      for (int kq = 0; kq < n; ++kq) {
        const double z = 0.5 * (gp[kq] + 1.0);
        for (int jq = 0; jq < n; ++jq) {
          const double y = 0.5 * (gp[jq] + 1.0);
          for (int iq = 0; iq < n; ++iq) {
            const double x = 0.5 * (gp[iq] + 1.0);
            const double c00 = vv[0] * (1 - x) + vv[1] * x;
            const double c10 = vv[2] * (1 - x) + vv[3] * x;
            const double c01 = vv[4] * (1 - x) + vv[5] * x;
            const double c11 = vv[6] * (1 - x) + vv[7] * x;
            const double d0 = c00 * (1 - y) + c10 * y;
            const double d1 = c01 * (1 - y) + c11 * y;
            if (d0 * (1 - z) + d1 * z >= iso) add += w[iq] * w[jq] * w[kq] * jac;
          }
        }
      }
      acc += add;
    }
    partial[tid] = acc;
  };

  std::vector<std::thread> ts;
  ts.reserve(nthreads);
  for (unsigned t = 0; t < nthreads; ++t) ts.emplace_back(worker, t);
  for (auto& t : ts) t.join();

  // Summed in a FIXED thread order, never atomically as they finish: a volume
  // that moves in its last digits run to run would make the bisections below
  // non-deterministic and the volume-preservation claim unfalsifiable.
  double total = 0.0;
  for (double x : partial) total += x;
  return total;
}

// Bisect for the level whose isocontour encloses `target`. Monotone decreasing
// in the level, so the bracket update is the reference's.
struct ThresholdResult {
  double level = 0.0;
  double volume = 0.0;
  double rel_err = 0.0;
  int iterations = 0;
};

inline ThresholdResult find_level_for_volume(const Lattice& L, double target,
                                             double lo, double hi, int order,
                                             double tol = 1e-6,
                                             int max_it = 60) {
  ThresholdResult best;
  best.rel_err = std::numeric_limits<double>::infinity();
  for (int it = 0; it < max_it; ++it) {
    const double mid = 0.5 * (lo + hi);
    const double vol = iso_volume(L, mid, order);
    const double err = std::fabs(vol - target) / std::fmax(target, 1e-300);
    if (err < best.rel_err) {
      best.level = mid;
      best.volume = vol;
      best.rel_err = err;
    }
    best.iterations = it + 1;
    if (err < tol) break;
    if (vol > target) lo = mid; else hi = mid;
  }
  return best;
}

// ── §4.2  the discrete signed distance function ──────────────────────────────
//
// DISTANCE. The reference solves eq. (11) — project the grid point onto the
// isocontour inside each candidate element, by Newton iteration on the local
// coordinates, and take the smallest. This port instead TESSELLATES the same
// isocontour finely and takes the exact point-to-triangle distance to that
// tessellation. Same surface, and the approximation is only the facet chord: it
// is bounded by the tessellation refinement and is MEASURED here rather than
// assumed (the probe reports the distance field's movement between refinement 4
// and refinement 8). The reason for the substitution is robustness — a Newton
// projection onto a tri-linear level set has to handle the saddle and
// multiple-root cases the paper devotes Appendix A.3 to, and a wrong root is a
// silent error in exactly the quantity being measured.
//
// SIGN. Exactly the paper's §4.2.2 and no substitution at all: interpolate the
// nodal density at the grid point and compare with rho_t. On a regular grid the
// "which element contains this point" step (the paper's eq. 15-16, and the line
// that makes the reference intractable here) is closed-form arithmetic.

// Flat CSR bins over triangles — one build, no per-cell vector<>.
class SurfBins {
 public:
  SurfBins(const TriangleMesh& m, double target_cell) : mesh_(&m) {
    if (m.triangles.empty()) return;
    Vec3 lo = m.vertices[0], hi = m.vertices[0];
    for (const Vec3& v : m.vertices) {
      lo.x = std::fmin(lo.x, v.x); hi.x = std::fmax(hi.x, v.x);
      lo.y = std::fmin(lo.y, v.y); hi.y = std::fmax(hi.y, v.y);
      lo.z = std::fmin(lo.z, v.z); hi.z = std::fmax(hi.z, v.z);
    }
    origin_ = lo;
    cell_ = std::fmax(target_cell, 1e-6);
    nx_ = std::max(1, static_cast<int>((hi.x - lo.x) / cell_) + 1);
    ny_ = std::max(1, static_cast<int>((hi.y - lo.y) / cell_) + 1);
    nz_ = std::max(1, static_cast<int>((hi.z - lo.z) / cell_) + 1);
    const std::size_t nb = static_cast<std::size_t>(nx_) * ny_ * nz_;
    std::vector<int> count(nb + 1, 0);
    auto visit = [&](std::size_t t, auto&& f) {
      const auto& tr = m.triangles[t];
      Vec3 tlo = m.vertices[static_cast<std::size_t>(tr[0])], thi = tlo;
      for (int q = 1; q < 3; ++q) {
        const Vec3& v = m.vertices[static_cast<std::size_t>(tr[q])];
        tlo.x = std::fmin(tlo.x, v.x); thi.x = std::fmax(thi.x, v.x);
        tlo.y = std::fmin(tlo.y, v.y); thi.y = std::fmax(thi.y, v.y);
        tlo.z = std::fmin(tlo.z, v.z); thi.z = std::fmax(thi.z, v.z);
      }
      for (int k = ci(tlo.z - lo.z, nz_); k <= ci(thi.z - lo.z, nz_); ++k)
        for (int j = ci(tlo.y - lo.y, ny_); j <= ci(thi.y - lo.y, ny_); ++j)
          for (int i = ci(tlo.x - lo.x, nx_); i <= ci(thi.x - lo.x, nx_); ++i)
            f(bidx(i, j, k));
    };
    for (std::size_t t = 0; t < m.triangles.size(); ++t)
      visit(t, [&](std::size_t b) { ++count[b + 1]; });
    start_.resize(nb + 1);
    start_[0] = 0;
    for (std::size_t b = 0; b < nb; ++b) start_[b + 1] = start_[b] + count[b + 1];
    items_.resize(static_cast<std::size_t>(start_[nb]));
    std::vector<int> cur(start_.begin(), start_.end() - 1);
    for (std::size_t t = 0; t < m.triangles.size(); ++t)
      visit(t, [&](std::size_t b) {
        items_[static_cast<std::size_t>(cur[b]++)] = static_cast<int>(t);
      });
  }

  bool empty() const { return items_.empty(); }

  // Exact unsigned distance: grow a Chebyshev box until the best distance found
  // cannot be beaten from outside it. PR 299's TriGrid uses the same argument.
  double distance(const Vec3& p, double give_up) const;

 private:
  int ci(double d, int n) const {
    const int v = static_cast<int>(std::floor(d / cell_));
    return v < 0 ? 0 : (v >= n ? n - 1 : v);
  }
  std::size_t bidx(int i, int j, int k) const {
    return (static_cast<std::size_t>(k) * ny_ + j) * nx_ + i;
  }
  const TriangleMesh* mesh_ = nullptr;
  Vec3 origin_;
  double cell_ = 1.0;
  int nx_ = 1, ny_ = 1, nz_ = 1;
  std::vector<int> start_;
  std::vector<int> items_;
};

struct SdfBuild {
  Lattice phi;              // the signed distance field
  double band_mm = 0.0;     // |phi| beyond this is clamped, not computed
  std::size_t band_points = 0;
  double wall_s = 0.0;
  std::size_t iso_tris = 0;
};

// Build the SDF of the isocontour {interp(nodal) == level} on a Cartesian grid of
// spacing B. `iso_refine` is the tessellation refinement used for the distance
// target (see the note above).
SdfBuild build_sdf(const Lattice& nodal, double level, double B, int iso_refine,
                   double band_cells);

// ── §4.3  Gaussian RBF smoothing ─────────────────────────────────────────────
//
// R(r) = exp(-(r/B)^2) with B equal to the grid spacing (paper §4.3.1). The
// reference truncates the kernel below 1e-3 (`RBFs_smoothing`'s `threshold`),
// which on a grid of spacing B puts every centre that can matter within
// sqrt(-ln 1e-3) = 2.6283 cells. On a REGULAR grid that makes the interaction
// matrix A a fixed 81-point CONVOLUTION STENCIL, so A never has to be stored:
// A*s is one stencil pass, and CG solves A s = phi matrix-free. That is the whole
// reason this runs at all at 487,620 grid points.
//
// TWO VARIANTS, both in the reference (`Is_interpolation`):
//   INTERPOLATION  — solve A s = phi, so the smoothed field reproduces phi
//                    exactly at the grid points. This is the reference's DEFAULT.
//   APPROXIMATION  — take s = phi, so the smoothed field is the Gaussian
//                    CONVOLUTION of phi. This is a genuine low-pass.
// The distinction matters more than the paper's text suggests and the probe
// reports both; see the handoff's S1.
enum class RbfMode { Interpolation, Approximation };

struct RbfResult {
  Lattice phi;          // on the fine lattice (spacing B / `fine`)
  int cg_iterations = 0;
  double cg_residual = 0.0;
  double wall_s = 0.0;
};

RbfResult rbf_smooth(const Lattice& phi, RbfMode mode, int fine,
                     double kernel_cutoff = 1e-3, int cg_max = 400,
                     double cg_tol = 1e-8);

// ── §4.3  the volume-preserving uniform shift ────────────────────────────────
struct ShiftResult {
  double c = 0.0;
  double volume = 0.0;
  double rel_err = 0.0;
  int iterations = 0;
};

// Solve for the uniform shift c such that {phi + c >= 0} encloses `target`.
ShiftResult volume_shift(const Lattice& phi, double target, int order = 9,
                         double tol = 1e-6, int max_it = 60);

}  // namespace sdfgeom
}  // namespace topopt
