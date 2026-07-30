#pragma once

// surface_stiffness_model — HARNESS-ONLY numerics for the surface-stiffness
// probe (2026-07-31-surface-stiffness-probe): can surface geometry (the diagrid
// skin, the solid shell) enter the solve, and by which route?
//
// Everything in this header is harness-side. The production library is linked
// UNMODIFIED; nothing here is armed, exported or reachable from production code.
// The pieces:
//
//   * integrate_hex8_general — the SAME 2x2x2 Gauss integrator as production
//     hex_element.cpp (an exact code copy, the same copy discipline as
//     matfree_cubic_probe.cpp), but taking an ARBITRARY symmetric 6x6 D. For a
//     cubic D it must reproduce hex8_stiffness_cubic bit-for-bit (pinned by
//     test_surface_stiffness_model.cpp) — so every harness element is on the
//     production element's arithmetic.
//   * D6 builders/projections — isotropic and cubic D, plus the Frobenius
//     (least-squares) projections of a general D onto the cubic and isotropic
//     subspaces. Voigt order [xx,yy,zz,gxy,gyz,gzx], ENGINEERING shear — the
//     hex8_stiffness contract.
//   * Capsule + rasterize_solid — the strut-resolved reference geometry: every
//     generator-emitted element (segment + radius; a ball has a == b) becomes a
//     capsule, a fine voxel is solid iff its centre is inside any capsule.
//     Deterministic fixed-order sweep.
//   * rod_smear_accumulate — Route A: each chord contributes the classic
//     slender-rod (Voigt/affine) stiffness E*A*len/V * (m m^T) to the coarse
//     voxels its centreline crosses, with m = [nx^2,ny^2,nz^2,nxny,nynz,nznx]
//     (the engineering-shear-consistent rank-1 rod tensor). This IS the
//     "homogenize the surface layer into the voxels it touches" route, derived
//     from the actual chords (pitch, radius and normal enter through the chord
//     list itself), so a graded radius and an arbitrary surface orientation are
//     handled by construction.
//   * TrussCoupling — Route B: each chord becomes an explicit 2-node axial bar
//     (stiffness EA/L, the pin-jointed model of the strut net) whose endpoints
//     are EMBEDDED in the coarse hex containing them by trilinear weights:
//     K_add = W^T k_bar W, a symmetric PSD addition on the existing voxel-grid
//     DOFs — zero new DOFs.
//   * CoarseModel — a small assembled solver (Eigen SimplicialLDLT) over a
//     coarse voxel grid with a general per-voxel D6 plus optional embedded
//     bars, prescribed-displacement BCs, and the strain energy 1/2 u^T K u.
//     The probe's stiffness measure for every model, fine and coarse, is
//     K_state = 2 U / delta^2 under identical grip BCs.
//
// Determinism: no RNG, no threads, fixed traversal orders everywhere.

#include <algorithm>
#include <array>
#include <cmath>
#include <cstdint>
#include <stdexcept>
#include <vector>

#include <Eigen/Dense>
#include <Eigen/Sparse>
#include <Eigen/SparseCholesky>

#include "topopt/fea.hpp"
#include "topopt/mesh.hpp"

namespace surfstiff {

using topopt::Hex8Stiffness;
using topopt::Vec3;

constexpr int kDof = Hex8Stiffness::kDof;  // 24

// ---------------------------------------------------------------------------
// A symmetric 6x6 constitutive matrix, Voigt [xx,yy,zz,gxy,gyz,gzx],
// engineering shear.
// ---------------------------------------------------------------------------
struct D6 {
  double m[6][6] = {};
  void add(const D6& o, double s = 1.0) {
    for (int i = 0; i < 6; ++i)
      for (int j = 0; j < 6; ++j) m[i][j] += s * o.m[i][j];
  }
};

inline D6 d6_isotropic(double E, double nu) {
  D6 d;
  const double c = E / ((1.0 + nu) * (1.0 - 2.0 * nu));
  const double G = E / (2.0 * (1.0 + nu));
  for (int i = 0; i < 3; ++i)
    for (int j = 0; j < 3; ++j) d.m[i][j] = (i == j) ? c * (1.0 - nu) : c * nu;
  for (int i = 3; i < 6; ++i) d.m[i][i] = G;
  return d;
}

inline D6 d6_cubic(double C11, double C12, double C44) {
  D6 d;
  for (int i = 0; i < 3; ++i)
    for (int j = 0; j < 3; ++j) d.m[i][j] = (i == j) ? C11 : C12;
  for (int i = 3; i < 6; ++i) d.m[i][i] = C44;
  return d;
}

// Frobenius (least-squares) projection onto the cubic subspace: the closest
// cubic D is the pattern-entry means (the three cubic basis matrices are
// mutually orthogonal under the Frobenius inner product).
struct CubicFit {
  double C11 = 0.0, C12 = 0.0, C44 = 0.0;
};
inline CubicFit project_cubic(const D6& d) {
  CubicFit c;
  c.C11 = (d.m[0][0] + d.m[1][1] + d.m[2][2]) / 3.0;
  c.C12 = (d.m[0][1] + d.m[0][2] + d.m[1][2] + d.m[1][0] + d.m[2][0] +
           d.m[2][1]) /
          6.0;
  c.C44 = (d.m[3][3] + d.m[4][4] + d.m[5][5]) / 3.0;
  return c;
}

// ---------------------------------------------------------------------------
// Reference integrator — exact code copy of hex_element.cpp's static
// integrate_hex8 (same Gauss order, same accumulation order), taking a general
// D. Pinned bit-for-bit against hex8_stiffness_cubic for cubic D by the unit
// test.
// ---------------------------------------------------------------------------
constexpr double kXiN[8] = {-1, +1, +1, -1, -1, +1, +1, -1};
constexpr double kEtaN[8] = {-1, -1, +1, +1, -1, -1, +1, +1};
constexpr double kZetaN[8] = {-1, -1, -1, -1, +1, +1, +1, +1};

inline Hex8Stiffness integrate_hex8_general(const D6& D, double h) {
  const double gp = 1.0 / std::sqrt(3.0);
  const double pts[2] = {-gp, +gp};
  const double half = h / 2.0;
  const double detJ = half * half * half;
  const double dnat_to_dx = 2.0 / h;
  Hex8Stiffness Ke;
  for (int ig = 0; ig < 2; ++ig)
    for (int jg = 0; jg < 2; ++jg)
      for (int kg = 0; kg < 2; ++kg) {
        const double xi = pts[ig];
        const double eta = pts[jg];
        const double zeta = pts[kg];
        double dNdx[8], dNdy[8], dNdz[8];
        for (int a = 0; a < 8; ++a) {
          const double xa = kXiN[a], ea = kEtaN[a], za = kZetaN[a];
          const double dNdxi = 0.125 * xa * (1.0 + eta * ea) * (1.0 + zeta * za);
          const double dNdeta = 0.125 * ea * (1.0 + xi * xa) * (1.0 + zeta * za);
          const double dNdzeta = 0.125 * za * (1.0 + xi * xa) * (1.0 + eta * ea);
          dNdx[a] = dnat_to_dx * dNdxi;
          dNdy[a] = dnat_to_dx * dNdeta;
          dNdz[a] = dnat_to_dx * dNdzeta;
        }
        double B[6][kDof] = {};
        for (int a = 0; a < 8; ++a) {
          const int c0 = 3 * a;
          B[0][c0 + 0] = dNdx[a];
          B[1][c0 + 1] = dNdy[a];
          B[2][c0 + 2] = dNdz[a];
          B[3][c0 + 0] = dNdy[a];
          B[3][c0 + 1] = dNdx[a];
          B[4][c0 + 1] = dNdz[a];
          B[4][c0 + 2] = dNdy[a];
          B[5][c0 + 0] = dNdz[a];
          B[5][c0 + 2] = dNdx[a];
        }
        double DB[6][kDof];
        for (int r = 0; r < 6; ++r)
          for (int c = 0; c < kDof; ++c) {
            double s = 0.0;
            for (int t = 0; t < 6; ++t) s += D.m[r][t] * B[t][c];
            DB[r][c] = s;
          }
        for (int r = 0; r < kDof; ++r)
          for (int c = 0; c < kDof; ++c) {
            double s = 0.0;
            for (int t = 0; t < 6; ++t) s += B[t][r] * DB[t][c];
            Ke.k[static_cast<std::size_t>(r) * kDof + c] += s * detJ;
          }
      }
  return Ke;
}

// ---------------------------------------------------------------------------
// Capsules (the generator's emitted solids, reduced to segment + radius).
// ---------------------------------------------------------------------------
struct Capsule {
  Vec3 a, b;
  double r = 0.0;
};

inline double dist2_point_segment(const Vec3& p, const Vec3& a, const Vec3& b) {
  const double abx = b.x - a.x, aby = b.y - a.y, abz = b.z - a.z;
  const double apx = p.x - a.x, apy = p.y - a.y, apz = p.z - a.z;
  const double len2 = abx * abx + aby * aby + abz * abz;
  double t = 0.0;
  if (len2 > 0.0) {
    t = (apx * abx + apy * aby + apz * abz) / len2;
    t = std::min(1.0, std::max(0.0, t));
  }
  const double dx = apx - t * abx, dy = apy - t * aby, dz = apz - t * abz;
  return dx * dx + dy * dy + dz * dz;
}

// Mark fine voxels solid whose CENTRE lies inside any capsule. `solid` has
// nx*ny*nz entries, x-fastest (the VoxelGrid convention); entries are OR-ed in,
// so successive calls union capsule sets. Deterministic per-capsule bbox sweep.
inline void rasterize_solid(const std::vector<Capsule>& caps, const Vec3& origin,
                            double h, int nx, int ny, int nz,
                            std::vector<char>& solid) {
  if (solid.size() != static_cast<std::size_t>(nx) * ny * nz)
    throw std::invalid_argument("rasterize_solid: bad solid size");
  for (const Capsule& c : caps) {
    const double r = c.r;
    const double lox = std::min(c.a.x, c.b.x) - r, hix = std::max(c.a.x, c.b.x) + r;
    const double loy = std::min(c.a.y, c.b.y) - r, hiy = std::max(c.a.y, c.b.y) + r;
    const double loz = std::min(c.a.z, c.b.z) - r, hiz = std::max(c.a.z, c.b.z) + r;
    const int i0 = std::max(0, (int)std::floor((lox - origin.x) / h - 0.5));
    const int i1 = std::min(nx - 1, (int)std::ceil((hix - origin.x) / h - 0.5));
    const int j0 = std::max(0, (int)std::floor((loy - origin.y) / h - 0.5));
    const int j1 = std::min(ny - 1, (int)std::ceil((hiy - origin.y) / h - 0.5));
    const int k0 = std::max(0, (int)std::floor((loz - origin.z) / h - 0.5));
    const int k1 = std::min(nz - 1, (int)std::ceil((hiz - origin.z) / h - 0.5));
    const double r2 = r * r;
    for (int k = k0; k <= k1; ++k)
      for (int j = j0; j <= j1; ++j)
        for (int i = i0; i <= i1; ++i) {
          const Vec3 p{origin.x + (i + 0.5) * h, origin.y + (j + 0.5) * h,
                       origin.z + (k + 0.5) * h};
          if (dist2_point_segment(p, c.a, c.b) <= r2)
            solid[(static_cast<std::size_t>(k) * ny + j) * nx + i] = 1;
        }
  }
}

// ---------------------------------------------------------------------------
// Route A — rod-Voigt smear. Walk each chord's centreline in fixed steps and
// add E * A * dlen / V_vox * (m m^T) to the containing coarse voxel's delta-D.
// Balls (a == b) contribute an ISOTROPIC blob of their volume fraction (they
// are joints, not rods; their stiffness has no direction).
// ---------------------------------------------------------------------------
inline void rod_smear_accumulate(const std::vector<Capsule>& chords, double Es,
                                 double nu_ball, const Vec3& origin, double h,
                                 int nx, int ny, int nz, std::vector<D6>& dD) {
  if (dD.size() != static_cast<std::size_t>(nx) * ny * nz)
    throw std::invalid_argument("rod_smear_accumulate: bad dD size");
  const double Vvox = h * h * h;
  const int kSteps = 64;  // fixed subdivision: deterministic, ~0.06 mm on a 4 mm chord
  for (const Capsule& c : chords) {
    const double dx = c.b.x - c.a.x, dy = c.b.y - c.a.y, dz = c.b.z - c.a.z;
    const double len = std::sqrt(dx * dx + dy * dy + dz * dz);
    if (len <= 1e-12) {
      // Ball: isotropic blob, volume 4/3 pi r^3 smeared into its voxel.
      const int i = std::min(nx - 1, std::max(0, (int)std::floor((c.a.x - origin.x) / h)));
      const int j = std::min(ny - 1, std::max(0, (int)std::floor((c.a.y - origin.y) / h)));
      const int k = std::min(nz - 1, std::max(0, (int)std::floor((c.a.z - origin.z) / h)));
      const double vol = 4.0 / 3.0 * M_PI * c.r * c.r * c.r;
      D6 blob = d6_isotropic(Es, nu_ball);
      dD[(static_cast<std::size_t>(k) * ny + j) * nx + i].add(blob, vol / Vvox);
      continue;
    }
    const double nxu = dx / len, nyu = dy / len, nzu = dz / len;
    const double m[6] = {nxu * nxu, nyu * nyu, nzu * nzu,
                         nxu * nyu, nyu * nzu, nzu * nxu};
    const double A = M_PI * c.r * c.r;
    const double w_per_step = Es * A * (len / kSteps) / Vvox;
    for (int s = 0; s < kSteps; ++s) {
      const double t = (s + 0.5) / kSteps;
      const double px = c.a.x + t * dx, py = c.a.y + t * dy, pz = c.a.z + t * dz;
      const int i = std::min(nx - 1, std::max(0, (int)std::floor((px - origin.x) / h)));
      const int j = std::min(ny - 1, std::max(0, (int)std::floor((py - origin.y) / h)));
      const int k = std::min(nz - 1, std::max(0, (int)std::floor((pz - origin.z) / h)));
      D6& d = dD[(static_cast<std::size_t>(k) * ny + j) * nx + i];
      for (int r = 0; r < 6; ++r)
        for (int ccol = 0; ccol < 6; ++ccol)
          d.m[r][ccol] += w_per_step * m[r] * m[ccol];
    }
  }
}

// Per-voxel volume fraction of a capsule set (chord walk on the same fixed
// subdivision — the A-iso variant's phi and the accounting basis; soup basis,
// overlaps not deducted).
inline void volume_fraction_accumulate(const std::vector<Capsule>& caps,
                                       const Vec3& origin, double h, int nx,
                                       int ny, int nz, std::vector<double>& phi) {
  if (phi.size() != static_cast<std::size_t>(nx) * ny * nz)
    throw std::invalid_argument("volume_fraction_accumulate: bad phi size");
  const double Vvox = h * h * h;
  const int kSteps = 64;
  for (const Capsule& c : caps) {
    const double dx = c.b.x - c.a.x, dy = c.b.y - c.a.y, dz = c.b.z - c.a.z;
    const double len = std::sqrt(dx * dx + dy * dy + dz * dz);
    if (len <= 1e-12) {
      const int i = std::min(nx - 1, std::max(0, (int)std::floor((c.a.x - origin.x) / h)));
      const int j = std::min(ny - 1, std::max(0, (int)std::floor((c.a.y - origin.y) / h)));
      const int k = std::min(nz - 1, std::max(0, (int)std::floor((c.a.z - origin.z) / h)));
      phi[(static_cast<std::size_t>(k) * ny + j) * nx + i] +=
          4.0 / 3.0 * M_PI * c.r * c.r * c.r / Vvox;
      continue;
    }
    const double A = M_PI * c.r * c.r;
    for (int s = 0; s < 64; ++s) {
      const double t = (s + 0.5) / 64.0;
      const double px = c.a.x + t * dx, py = c.a.y + t * dy, pz = c.a.z + t * dz;
      const int i = std::min(nx - 1, std::max(0, (int)std::floor((px - origin.x) / h)));
      const int j = std::min(ny - 1, std::max(0, (int)std::floor((py - origin.y) / h)));
      const int k = std::min(nz - 1, std::max(0, (int)std::floor((pz - origin.z) / h)));
      phi[(static_cast<std::size_t>(k) * ny + j) * nx + i] += A * (len / kSteps) / Vvox;
    }
  }
}

// ---------------------------------------------------------------------------
// Route B — explicit axial bars with trilinearly embedded endpoints.
// ---------------------------------------------------------------------------
struct EmbeddedEnd {
  int node[8];       // the 8 corner-node ids of the containing coarse hex
  double w[8];       // trilinear weights (partition of unity)
};

// Trilinear embedding of point p into the coarse grid (clamped to the grid).
inline EmbeddedEnd embed_point(const Vec3& p, const Vec3& origin, double h,
                               int nx, int ny, int nz,
                               int (*node_id)(int, int, int, int, int),
                               int gnx, int gny) {
  const double fx = std::min((double)nx - 1e-9, std::max(0.0, (p.x - origin.x) / h));
  const double fy = std::min((double)ny - 1e-9, std::max(0.0, (p.y - origin.y) / h));
  const double fz = std::min((double)nz - 1e-9, std::max(0.0, (p.z - origin.z) / h));
  const int i = std::min(nx - 1, (int)std::floor(fx));
  const int j = std::min(ny - 1, (int)std::floor(fy));
  const int k = std::min(nz - 1, (int)std::floor(fz));
  const double u = fx - i, v = fy - j, w = fz - k;
  EmbeddedEnd e{};
  int idx = 0;
  for (int dk = 0; dk <= 1; ++dk)
    for (int dj = 0; dj <= 1; ++dj)
      for (int di = 0; di <= 1; ++di) {
        e.node[idx] = node_id(i + di, j + dj, k + dk, gnx, gny);
        e.w[idx] = (di ? u : 1.0 - u) * (dj ? v : 1.0 - v) * (dk ? w : 1.0 - w);
        ++idx;
      }
  return e;
}

// ---------------------------------------------------------------------------
// The coarse assembled model: per-voxel general D6 + optional embedded bars,
// prescribed-displacement solve, strain energy.
// ---------------------------------------------------------------------------
struct CoarseModel {
  Vec3 origin{0, 0, 0};
  double h = 1.0;
  int nx = 0, ny = 0, nz = 0;
  std::vector<D6> D;  // per voxel, x-fastest

  struct Bar {
    Vec3 a, b;
    double EA = 0.0;  // axial rigidity E*A
  };
  std::vector<Bar> bars;

  int node_count() const { return (nx + 1) * (ny + 1) * (nz + 1); }
  static int node_id_static(int a, int b, int c, int gnx, int gny) {
    return (c * (gny + 1) + b) * (gnx + 1) + a;
  }
  int node_id(int a, int b, int c) const {
    return node_id_static(a, b, c, nx, ny);
  }

  // Prescribed displacement on a node set: comp-wise values (all three
  // components prescribed on every grip node — a rigid grip).
  struct Grip {
    std::vector<int> nodes;
    double ux = 0.0, uy = 0.0, uz = 0.0;
  };

  // Nodes within `band` of the plane {axis-coordinate == value} (band 0: the
  // exact plane; coarse nodes are exact multiples of h from origin).
  std::vector<int> plane_nodes(int axis, double value, double band = 0.0) const {
    std::vector<int> out;
    for (int c = 0; c <= nz; ++c)
      for (int b = 0; b <= ny; ++b)
        for (int a = 0; a <= nx; ++a) {
          const double x[3] = {origin.x + a * h, origin.y + b * h,
                               origin.z + c * h};
          if (std::abs(x[axis] - value) <= band + 1e-9)
            out.push_back(node_id(a, b, c));
        }
    return out;
  }

  // Assemble K (with bars), impose the two grips, solve, return the strain
  // energy 1/2 u^T K u. Deterministic: fixed triplet order, SimplicialLDLT.
  double solve_energy(const Grip& fixed, const Grip& moved) const {
    const int nn = node_count();
    const int ndof = 3 * nn;
    std::vector<Eigen::Triplet<double>> trips;
    trips.reserve(static_cast<std::size_t>(nx) * ny * nz * kDof * kDof / 2);
    // Voxel elements.
    for (int k = 0; k < nz; ++k)
      for (int j = 0; j < ny; ++j)
        for (int i = 0; i < nx; ++i) {
          const D6& d = D[(static_cast<std::size_t>(k) * ny + j) * nx + i];
          const Hex8Stiffness Ke = integrate_hex8_general(d, h);
          const int n[8] = {node_id(i, j, k),         node_id(i + 1, j, k),
                            node_id(i + 1, j + 1, k), node_id(i, j + 1, k),
                            node_id(i, j, k + 1),     node_id(i + 1, j, k + 1),
                            node_id(i + 1, j + 1, k + 1), node_id(i, j + 1, k + 1)};
          for (int r = 0; r < kDof; ++r)
            for (int ccol = 0; ccol < kDof; ++ccol) {
              const double v = Ke.k[static_cast<std::size_t>(r) * kDof + ccol];
              if (v == 0.0) continue;
              trips.emplace_back(3 * n[r / 3] + r % 3, 3 * n[ccol / 3] + ccol % 3, v);
            }
        }
    // Embedded bars: K_add = W^T k_bar W with k_bar the 6x6 axial bar.
    for (const Bar& bar : bars) {
      const double dx = bar.b.x - bar.a.x, dy = bar.b.y - bar.a.y,
                   dz = bar.b.z - bar.a.z;
      const double len = std::sqrt(dx * dx + dy * dy + dz * dz);
      if (len <= 1e-12) continue;
      const double nxu = dx / len, nyu = dy / len, nzu = dz / len;
      const double kax = bar.EA / len;
      const EmbeddedEnd ea = embed_point(bar.a, origin, h, nx, ny, nz,
                                         &CoarseModel::node_id_static, nx, ny);
      const EmbeddedEnd eb = embed_point(bar.b, origin, h, nx, ny, nz,
                                         &CoarseModel::node_id_static, nx, ny);
      // Bar force along n: k_bar couples (u_b - u_a).n. Expand
      // kax * (n (u_b-u_a))^2 / ... into the 48x48 quadratic form directly.
      const double n3[3] = {nxu, nyu, nzu};
      const EmbeddedEnd* ends[2] = {&ea, &eb};
      const double sgn[2] = {-1.0, +1.0};
      for (int e1 = 0; e1 < 2; ++e1)
        for (int p1 = 0; p1 < 8; ++p1)
          for (int c1 = 0; c1 < 3; ++c1) {
            const double g1 = sgn[e1] * ends[e1]->w[p1] * n3[c1];
            if (g1 == 0.0) continue;
            for (int e2 = 0; e2 < 2; ++e2)
              for (int p2 = 0; p2 < 8; ++p2)
                for (int c2 = 0; c2 < 3; ++c2) {
                  const double g2 = sgn[e2] * ends[e2]->w[p2] * n3[c2];
                  if (g2 == 0.0) continue;
                  trips.emplace_back(3 * ends[e1]->node[p1] + c1,
                                     3 * ends[e2]->node[p2] + c2, kax * g1 * g2);
                }
          }
    }
    Eigen::SparseMatrix<double> K(ndof, ndof);
    K.setFromTriplets(trips.begin(), trips.end());

    // Prescribed values.
    std::vector<char> is_fixed(static_cast<std::size_t>(ndof), 0);
    std::vector<double> uval(static_cast<std::size_t>(ndof), 0.0);
    auto apply = [&](const Grip& g) {
      for (int n : g.nodes) {
        const double v[3] = {g.ux, g.uy, g.uz};
        for (int c = 0; c < 3; ++c) {
          is_fixed[static_cast<std::size_t>(3 * n + c)] = 1;
          uval[static_cast<std::size_t>(3 * n + c)] = v[c];
        }
      }
    };
    apply(fixed);
    apply(moved);

    // Reduce: free DOFs solve K_ff u_f = -K_fc u_c.
    std::vector<int> free_of(static_cast<std::size_t>(ndof), -1);
    int nfree = 0;
    for (int d = 0; d < ndof; ++d)
      if (!is_fixed[static_cast<std::size_t>(d)]) free_of[static_cast<std::size_t>(d)] = nfree++;
    Eigen::VectorXd rhs = Eigen::VectorXd::Zero(nfree);
    std::vector<Eigen::Triplet<double>> ff;
    for (int col = 0; col < K.outerSize(); ++col)
      for (Eigen::SparseMatrix<double>::InnerIterator it(K, col); it; ++it) {
        const int r = static_cast<int>(it.row()), c = static_cast<int>(it.col());
        if (!is_fixed[static_cast<std::size_t>(r)] && !is_fixed[static_cast<std::size_t>(c)])
          ff.emplace_back(free_of[static_cast<std::size_t>(r)], free_of[static_cast<std::size_t>(c)], it.value());
        else if (!is_fixed[static_cast<std::size_t>(r)] && is_fixed[static_cast<std::size_t>(c)])
          rhs[free_of[static_cast<std::size_t>(r)]] -= it.value() * uval[static_cast<std::size_t>(c)];
      }
    Eigen::SparseMatrix<double> Kff(nfree, nfree);
    Kff.setFromTriplets(ff.begin(), ff.end());
    Eigen::SimplicialLDLT<Eigen::SparseMatrix<double>> ldlt(Kff);
    if (ldlt.info() != Eigen::Success)
      throw std::runtime_error("CoarseModel: LDLT factorization failed");
    const Eigen::VectorXd uf = ldlt.solve(rhs);
    Eigen::VectorXd u = Eigen::VectorXd::Zero(ndof);
    for (int d = 0; d < ndof; ++d)
      u[d] = is_fixed[static_cast<std::size_t>(d)] ? uval[static_cast<std::size_t>(d)]
                                                   : uf[free_of[static_cast<std::size_t>(d)]];
    return 0.5 * u.dot(K * u);
  }
};

}  // namespace surfstiff
