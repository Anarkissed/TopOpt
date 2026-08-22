// graded_cell_size_probe.cpp — VALIDATION harness for the GRADED CELL SIZE study
// (handoff 2026-07-28-graded-cell-size-phase0). Read-only, NOT a CI test.
//
// THE IDEA (maintainer's): grow the octet cell with the density grade — 8mm toward
// 16mm+ as relative density falls toward 0.05 — so struts stay printable at low
// density instead of thinning below what a 0.4mm nozzle can lay.
//
// THE PHYSICS TO VERIFY FIRST: the homogenized stiffness of a strut lattice is
// SCALE-INVARIANT — E/Es depends on RELATIVE DENSITY and TOPOLOGY only (dimensionless).
// If that holds, cell size costs NOTHING in the certification tensor, and PR 234's
// low-density floor is a PRINTABILITY limit at fixed cell size, not a model limit.
//
//   C1  PROVE scale invariance: homogenize octet at the SAME relative density with
//       cell sizes 4/8/16/32 mm; show the cubic tensor is identical to the library's
//       own accuracy. (Self-check B1: solid recovers E_solid to 4 digits.)
//   C2  THE CEILING: homogenization needs ~3 cells across a member. Measure the
//       homogenization error vs a resolved reference as cells-per-member falls
//       5,3,2,1,0.5. Where it exceeds +-2.4% (the library's validated band) is the
//       ceiling on cell growth — the deliverable.
//   C3  CROSS with member width: for members of 5, 9.4 and 20 mm, the largest cell
//       that stays inside the ceiling. (Verifies the ceiling is truly dimensionless.)
//   C5  CONFORMAL WARP: homogenize a continuously STRETCHED cell (the dominant mode
//       of a graded-size warp); report the distortion at which the tensor stops
//       applying (>2.4%). Implementation delta is reasoned in the handoff.
//   C4  DYADIC transition + C6 resolved comparison live in a second file section.
//
// Reuses PR 198's periodic homogenization and PR 220's resolved apparent-modulus,
// both ported verbatim from lattice_density_band_probe.cpp so the self-check and the
// truths are the same instruments.
//
// Build (from core/):
//   cmake -S . -B build -DTOPOPT_USE_OCCT=OFF -DTOPOPT_BUILD_TESTS=OFF && \
//     cmake --build build --target topopt -j
//   c++ -std=c++17 -O2 -I include -I /opt/homebrew/include/eigen3 \
//       tests/harness/graded_cell_size_probe.cpp build/libtopopt.a -o build/gcs_probe
// CSV sink: TOPOPT_LATTICE_CSV_DIR. Section gate: TOPOPT_GCS_ONLY=self|c1|c2|c3|c5.

#include <Eigen/Dense>
#include <Eigen/IterativeLinearSolvers>
#include <Eigen/Sparse>

#include <array>
#include <chrono>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <sstream>
#include <string>
#include <vector>

#include "topopt/fea.hpp"
#include "topopt/lattice.hpp"
#include "topopt/voxel.hpp"

using namespace topopt;

namespace {

constexpr double kE = 3500.0;   // PLA solid modulus (materials.json), MPa
constexpr double kNu = 0.33;    // PLA Poisson
constexpr double kStrain = 1e-3;

// ============================ octet geometry ================================
// Reference octet struts in the UNIT cube [0,1]^3 (PR 198 / PR 201 node set).
double point_seg_dist2(double px, double py, double pz, const double a[3],
                       const double b[3]) {
  double ab[3] = {b[0] - a[0], b[1] - a[1], b[2] - a[2]};
  double ap[3] = {px - a[0], py - a[1], pz - a[2]};
  double denom = ab[0] * ab[0] + ab[1] * ab[1] + ab[2] * ab[2];
  double t = denom > 0 ? (ap[0] * ab[0] + ap[1] * ab[1] + ap[2] * ab[2]) / denom : 0.0;
  t = t < 0 ? 0 : (t > 1 ? 1 : t);
  double c[3] = {a[0] + t * ab[0], a[1] + t * ab[1], a[2] + t * ab[2]};
  double d[3] = {px - c[0], py - c[1], pz - c[2]};
  return d[0] * d[0] + d[1] * d[1] + d[2] * d[2];
}
using Seg = std::array<std::array<double, 3>, 2>;
std::vector<Seg> octet_struts() {
  std::vector<std::array<double, 3>> nodes;
  for (int z = 0; z <= 1; ++z)
    for (int y = 0; y <= 1; ++y)
      for (int x = 0; x <= 1; ++x)
        nodes.push_back({double(x), double(y), double(z)});
  const std::array<std::array<double, 3>, 6> fc = {{{0.5, 0.5, 0.0}, {0.5, 0.5, 1.0},
                                                    {0.5, 0.0, 0.5}, {0.5, 1.0, 0.5},
                                                    {0.0, 0.5, 0.5}, {1.0, 0.5, 0.5}}};
  for (auto& f : fc) nodes.push_back(f);
  std::vector<Seg> segs;
  for (std::size_t fi = 8; fi < nodes.size(); ++fi)
    for (std::size_t ci = 0; ci < 8; ++ci) {
      double d2 = 0;
      for (int k = 0; k < 3; ++k) {
        double v = nodes[fi][k];
        if (v == 0.0 || v == 1.0) d2 += (nodes[ci][k] - v) * (nodes[ci][k] - v);
      }
      if (d2 < 1e-9) segs.push_back({nodes[fi], nodes[ci]});
    }
  return segs;
}

// Physical squared distance from (x,y,z) to the nearest octet strut of a cell
// lattice with per-axis cell sizes (Lx,Ly,Lz) and lattice origin `org`. The strut
// is a physical cylinder: we map the query point into the local unit cell, scale
// BOTH the point and the reference segment endpoints by the per-axis cell size, and
// take the ordinary physical point-segment distance. For Lx==Ly==Lz this is exactly
// the isotropic octet_dist2 of the density-band probe. Per-axis sizes let a cell be
// STRETCHED (the conformal-warp mode of C5) while the printed strut radius stays a
// true physical thickness.
double octet_dist2_box(double x, double y, double z, double Lx, double Ly, double Lz,
                       const Vec3& org, const std::vector<Seg>& segs) {
  auto frac = [](double p, double L) { double u = std::fmod(p, L) / L; return u < 0 ? u + 1 : u; };
  double u = frac(x - org.x, Lx), v = frac(y - org.y, Ly), w = frac(z - org.z, Lz);
  double px = u * Lx, py = v * Ly, pz = w * Lz;
  double best = 1e30;
  for (auto& s : segs) {
    double a[3] = {s[0][0] * Lx, s[0][1] * Ly, s[0][2] * Lz};
    double b[3] = {s[1][0] * Lx, s[1][1] * Ly, s[1][2] * Lz};
    double d2 = point_seg_dist2(px, py, pz, a, b);
    if (d2 < best) best = d2;
  }
  return best;
}

// Isotropic single-family octet block: ncx*ncy*ncz cells of edge L, vpc voxels per
// cell (cubic voxels h=L/vpc), strut radius `r` (mm). (== density-band build_octet.)
VoxelGrid build_octet(double L, double r, int ncx, int ncy, int ncz, int vpc) {
  VoxelGrid g;
  g.nx = ncx * vpc; g.ny = ncy * vpc; g.nz = ncz * vpc;
  g.spacing = L / vpc; g.origin = Vec3{0, 0, 0};
  g.tags.assign(static_cast<std::size_t>(g.nx) * g.ny * g.nz, VoxelTag::Empty);
  auto segs = octet_struts();
  for (int k = 0; k < g.nz; ++k)
    for (int j = 0; j < g.ny; ++j)
      for (int i = 0; i < g.nx; ++i) {
        Vec3 c = g.voxel_center(i, j, k);
        if (octet_dist2_box(c.x, c.y, c.z, L, L, L, Vec3{0, 0, 0}, segs) < r * r)
          g.set_tag(i, j, k, VoxelTag::Interior);
      }
  return g;
}

// A STRETCHED single octet cell L x L x (aspect*L), cubic voxels h=L/vpc. Radius r
// physical. The periodic box stays rectangular (orthotropic), so the existing
// periodic homogenizer applies directly — this is the conformal-warp cell of C5.
VoxelGrid build_octet_stretched(double L, double aspect, double r, int vpc) {
  VoxelGrid g;
  const double h = L / vpc;
  g.nx = vpc; g.ny = vpc; g.nz = std::max(1, (int)std::lround(aspect * vpc));
  g.spacing = h; g.origin = Vec3{0, 0, 0};
  const double Lz = g.nz * h;   // achieved stretched height (integer voxels)
  g.tags.assign(static_cast<std::size_t>(g.nx) * g.ny * g.nz, VoxelTag::Empty);
  auto segs = octet_struts();
  for (int k = 0; k < g.nz; ++k)
    for (int j = 0; j < g.ny; ++j)
      for (int i = 0; i < g.nx; ++i) {
        Vec3 c = g.voxel_center(i, j, k);
        if (octet_dist2_box(c.x, c.y, c.z, L, L, Lz, Vec3{0, 0, 0}, segs) < r * r)
          g.set_tag(i, j, k, VoxelTag::Interior);
      }
  return g;
}

// A member (bar) whose transverse cross-section is `cells_across` x `cells_across`
// octet cells of edge S, and whose long axis has `m_long` cells; cubic voxels
// h=S/vpc; strut radius r. cells_across may be fractional (<1): the transverse
// window is CENTERED on a cell centre (u=0.5) so a partial member samples a
// symmetric slab (the representative choice; sub-1-cell placement dependence is the
// finding itself, reported separately). Long axis = z (axis 2).
VoxelGrid build_member(double S, double r, double cells_across, int m_long, int vpc) {
  VoxelGrid g;
  const double h = S / vpc;
  const double W = cells_across * S;               // physical transverse width
  g.nx = std::max(1, (int)std::lround(W / h));
  g.ny = g.nx;
  g.nz = m_long * vpc;
  g.spacing = h; g.origin = Vec3{0, 0, 0};
  g.tags.assign(static_cast<std::size_t>(g.nx) * g.ny * g.nz, VoxelTag::Empty);
  auto segs = octet_struts();
  // Integer cells_across: aligned origin -> the member is whole n x n cells with free
  // surfaces at cell faces (the standard RVE-convergence test). Sub-cell (<1) members:
  // centre the window on a cell centre so it samples the octahedral core (the best-case
  // connected slice; the sub-cell breakdown is placement-robust and reported as such).
  const bool integer_cells = std::fabs(cells_across - std::lround(cells_across)) < 1e-6;
  double off = (cells_across >= 1.0 || integer_cells) ? 0.0 : (0.5 * S - 0.5 * W);
  // ★ WHERE THE CUT FALLS. At a FRACTIONAL width the cross-section slices cells, and
  // which part of the cell it keeps is a free choice this probe must not make silently
  // — it is the first objection to any fractional measurement. TOPOPT_GCS_MEMBER_PHASE
  // shifts the window within one cell (0 = aligned, 0.5 = centred on a cell centre).
  if (const char* ph = std::getenv("TOPOPT_GCS_MEMBER_PHASE"))
    off += std::atof(ph) * S;
  const Vec3 org{-off, -off, 0.0};                 // (frac subtracts org)
  for (int k = 0; k < g.nz; ++k)
    for (int j = 0; j < g.ny; ++j)
      for (int i = 0; i < g.nx; ++i) {
        Vec3 c = g.voxel_center(i, j, k);
        if (octet_dist2_box(c.x, c.y, c.z, S, S, S, org, segs) < r * r)
          g.set_tag(i, j, k, VoxelTag::Interior);
      }
  // ── ★★ A SKIN ON THE CUT FACES ─────────────────────────────────────────────
  // Trimming a lattice to a member SEVERS struts at the four lateral surfaces, and a
  // severed strut is mass that carries no bending load — which is the mechanism behind
  // the phase sensitivity this sweep measures. A skin re-ties those cut ends, which is
  // exactly what Aremu et al. say a net-skin is for. Two modes, on purpose:
  //   1 SOLID  a shell of thickness `t` on the four lateral faces. Not what anyone
  //            ships — it is the UPPER BOUND. If a solid skin cannot recover the
  //            stiffness, no lighter skin will, and the experiment stops there.
  //   2 NET    struts of the lattice's own radius lying IN each face plane on the
  //            octet's own node pitch (S/2), phase-locked to the lattice through the
  //            same `org`. This is the diagrid/net-skin, and it is what production
  //            actually emits.
  // The skin ADDS MASS the homogenized tensor does not know about, so the reported
  // rho moves and the error may go NEGATIVE — the macro model then UNDER-predicts,
  // which is the conservative direction. Both are reported; neither is hidden.
  const int skin = std::getenv("TOPOPT_GCS_SKIN") ? std::atoi(std::getenv("TOPOPT_GCS_SKIN")) : 0;
  if (skin > 0) {
    const double t = (std::getenv("TOPOPT_GCS_SKIN_T")
                          ? std::atof(std::getenv("TOPOPT_GCS_SKIN_T")) : 2.0) * r;
    const double pitch = 0.5 * S;
    auto near_line = [&](double v, double o) {
      const double u = v + o;                       // into lattice coordinates
      const double d = std::fabs(u - pitch * std::round(u / pitch));
      return d < r;
    };
    for (int k = 0; k < g.nz; ++k)
      for (int j = 0; j < g.ny; ++j)
        for (int i = 0; i < g.nx; ++i) {
          if (g.tags[(std::size_t)(k * g.ny + j) * g.nx + i] != VoxelTag::Empty) continue;
          Vec3 c = g.voxel_center(i, j, k);
          const bool on_x = c.x < t || c.x > W - t;
          const bool on_y = c.y < t || c.y > W - t;
          if (!on_x && !on_y) continue;             // interior: never skinned
          if (skin == 1) { g.set_tag(i, j, k, VoxelTag::Interior); continue; }
          // NET: in the face plane, a grid of struts on the node pitch. On an x-face
          // the in-plane axes are y and z; on a y-face they are x and z.
          const bool hit = (on_x && (near_line(c.y, off) || near_line(c.z, 0.0))) ||
                           (on_y && (near_line(c.x, off) || near_line(c.z, 0.0)));
          if (hit) g.set_tag(i, j, k, VoxelTag::Interior);
        }
  }
  return g;
}

double volume_fraction(const VoxelGrid& g) {
  return double(g.solid_count()) / double(g.voxel_count());
}
// One macro (homogenized) element per cell: ncx*ncy*ncz elements of edge L, all solid.
VoxelGrid macro_grid(double L, int ncx, int ncy, int ncz) {
  VoxelGrid g;
  g.nx = ncx; g.ny = ncy; g.nz = ncz; g.spacing = L; g.origin = Vec3{0, 0, 0};
  g.tags.assign((std::size_t)ncx * ncy * ncz, VoxelTag::Interior);
  return g;
}
double calibrate_octet_r(double L, double target_vf, int vpc) {
  double lo = 0.0005 * L, hi = 0.45 * L;
  for (int it = 0; it < 34; ++it) {
    double mid = 0.5 * (lo + hi);
    VoxelGrid g = build_octet(L, mid, 1, 1, 1, vpc);
    (volume_fraction(g) < target_vf ? lo : hi) = mid;
  }
  return 0.5 * (lo + hi);
}

// ============================ uniaxial apparent modulus =====================
// Displacement-controlled uniaxial test (verbatim from lattice_density_band_probe).
double apparent_E(const VoxelGrid& g, const std::vector<double>& elem_youngs,
                  int axis, double* solve_ms = nullptr, long* ndof_out = nullptr) {
  const int N[3] = {g.nx, g.ny, g.nz};
  const double h = g.spacing;
  const int t1 = (axis + 1) % 3, t2 = (axis + 2) % 3;
  std::vector<char> issolid((std::size_t)fea_node_count(g), 0);
  for (int k = 0; k < g.nz; ++k)
    for (int j = 0; j < g.ny; ++j)
      for (int i = 0; i < g.nx; ++i)
        if (g.solid(i, j, k))
          for (int n : fea_element_nodes(g, i, j, k)) issolid[n] = 1;
  const double delta = kStrain * (N[axis] * h);
  std::vector<DirichletBC> bcs;
  std::vector<std::array<int, 3>> maxface;
  int pinA = -1, pinB = -1;
  double pinB_t1 = -1;
  long minA = 1L << 60;
  const int nt1 = N[t1], nt2 = N[t2];
  auto make_coord = [&](int fi, int c1, int c2) {
    std::array<int, 3> co{};
    co[axis] = fi; co[t1] = c1; co[t2] = c2; return co;
  };
  for (int c2 = 0; c2 <= nt2; ++c2)
    for (int c1 = 0; c1 <= nt1; ++c1) {
      auto lo = make_coord(0, c1, c2);
      int nlo = fea_node_index(g, lo[0], lo[1], lo[2]);
      if (issolid[nlo]) {
        bcs.push_back({nlo, axis, 0.0});
        long key = (long)c1 + (long)c2 * (nt1 + 1);
        if (key < minA) { minA = key; pinA = nlo; }
        if (c1 > pinB_t1) { pinB_t1 = c1; pinB = nlo; }
      }
      auto hi = make_coord(N[axis], c1, c2);
      int nhi = fea_node_index(g, hi[0], hi[1], hi[2]);
      if (issolid[nhi]) { bcs.push_back({nhi, axis, delta}); maxface.push_back({nhi, c1, c2}); }
    }
  if (pinA >= 0) { bcs.push_back({pinA, t1, 0.0}); bcs.push_back({pinA, t2, 0.0}); }
  if (pinB >= 0 && pinB != pinA) bcs.push_back({pinB, t2, 0.0});
  if (ndof_out) *ndof_out = 3L * fea_node_count(g);

  FeaSolution sol;
  static const double rtol = [] { const char* s = std::getenv("TOPOPT_GCS_RESTOL"); return s ? std::atof(s) : 1e-6; }();
  static const int rmax = [] { const char* s = std::getenv("TOPOPT_GCS_RESMAXIT"); return s ? std::atoi(s) : 40000; }();
  static const bool use_mg = [] { const char* s = std::getenv("TOPOPT_GCS_MG"); return !s || std::string(s) != "0"; }();
  auto t0 = std::chrono::steady_clock::now();
  try {
    if (use_mg)
      sol = fea_solve_mgcg_matfree(g, elem_youngs, kNu, bcs, {}, rtol, rmax, nullptr, nullptr);
    else
      sol = fea_solve_cg(g, elem_youngs, kNu, bcs, {}, rtol, rmax, nullptr, nullptr);
  } catch (const std::exception& e) {
    std::fprintf(stderr, "  [apparent_E axis %d unconverged: %s]\n", axis, e.what());
    return -1.0;
  }
  auto t1c = std::chrono::steady_clock::now();
  if (solve_ms) *solve_ms = std::chrono::duration<double, std::milli>(t1c - t0).count();

  double Fsum = 0.0;
  std::vector<double> react(3L * fea_node_count(g), 0.0);
  const Hex8Stiffness KeIso1 = hex8_stiffness(1.0, kNu, h);
  for (int k = 0; k < g.nz; ++k)
    for (int j = 0; j < g.ny; ++j)
      for (int i = 0; i < g.nx; ++i) {
        if (!g.solid(i, j, k)) continue;
        const std::size_t e = g.index(i, j, k);
        const std::array<int, 8> en = fea_element_nodes(g, i, j, k);
        std::array<double, 24> ue{};
        int edof[24];
        for (int a = 0; a < 8; ++a)
          for (int c = 0; c < 3; ++c) { edof[3 * a + c] = 3 * en[a] + c; ue[3 * a + c] = sol.at(en[a], c); }
        Hex8Stiffness Ke = KeIso1;
        const double f = elem_youngs[e];
        for (auto& v : Ke.k) v *= f;
        for (int r = 0; r < 24; ++r) {
          double s = 0;
          for (int c = 0; c < 24; ++c) s += Ke(r, c) * ue[c];
          react[edof[r]] += s;
        }
      }
  for (auto& m : maxface) Fsum += react[3 * m[0] + axis];
  const double A = (nt1 * h) * (nt2 * h);
  return std::fabs(Fsum) / (A * kStrain);
}
double resolved_E(const VoxelGrid& g, int axis, double* ms = nullptr, long* nd = nullptr) {
  std::vector<double> ey(g.voxel_count(), 0.0);
  for (std::size_t e = 0; e < g.voxel_count(); ++e) if (g.tags[e] != VoxelTag::Empty) ey[e] = kE;
  return apparent_E(g, ey, axis, ms, nd);
}

// ============================ periodic homogenization (PR 198) ==============
std::array<double, 576> ref_ke(double h) {
  Hex8Stiffness K = hex8_stiffness(kE, kNu, h);
  std::array<double, 576> out{};
  for (int i = 0; i < 576; ++i) out[i] = K.k[i];
  return out;
}
constexpr int kOff[8][3] = {{0,0,0},{1,0,0},{1,1,0},{0,1,0},{0,0,1},{1,0,1},{1,1,1},{0,1,1}};
std::array<std::array<double, 6>, 24> element_chi0(double h) {
  std::array<std::array<double, 6>, 24> chi0{};
  for (int a = 0; a < 8; ++a) {
    double X = kOff[a][0] * h, Y = kOff[a][1] * h, Z = kOff[a][2] * h;
    int dx = 3 * a, dy = 3 * a + 1, dz = 3 * a + 2;
    chi0[dx][0] = X; chi0[dy][1] = Y; chi0[dz][2] = Z;
    chi0[dx][3] = Y; chi0[dy][4] = Z; chi0[dz][5] = X;
  }
  return chi0;
}
using SpMat = Eigen::SparseMatrix<double>;
using Trip = Eigen::Triplet<double>;
struct HomogResult { double CH[6][6] = {}; int cg_iters_max = 0; bool converged = true; double solve_ms = 0; };
HomogResult homogenize(const VoxelGrid& grid, const std::vector<int>& cases, double cg_tol = 1e-9) {
  HomogResult R;
  const int nx = grid.nx, ny = grid.ny, nz = grid.nz;
  const double h = grid.spacing;
  const long Np = (long)nx * ny * nz;
  const long nd = 3 * Np;
  auto ke = ref_ke(h);
  auto chi0 = element_chi0(h);
  auto pid = [&](int a, int b, int c) -> long {
    int aa = a % nx, bb = b % ny, cc = c % nz;
    return ((long)cc * ny + bb) * nx + aa;
  };
  std::vector<Trip> trips;
  trips.reserve((std::size_t)grid.solid_count() * 24 * 24);
  Eigen::MatrixXd F = Eigen::MatrixXd::Zero(nd, 6);
  std::vector<char> touched((std::size_t)nd, 0);
  for (int k = 0; k < nz; ++k)
    for (int j = 0; j < ny; ++j)
      for (int i = 0; i < nx; ++i) {
        if (!grid.solid(i, j, k)) continue;
        long gd[24];
        for (int a = 0; a < 8; ++a) {
          long p = pid(i + kOff[a][0], j + kOff[a][1], k + kOff[a][2]);
          gd[3 * a] = 3 * p; gd[3 * a + 1] = 3 * p + 1; gd[3 * a + 2] = 3 * p + 2;
        }
        for (int r = 0; r < 24; ++r) {
          touched[gd[r]] = 1;
          for (int c = 0; c < 24; ++c) trips.emplace_back((int)gd[r], (int)gd[c], ke[r * 24 + c]);
          for (int J : cases) {
            double f = 0;
            for (int c = 0; c < 24; ++c) f += ke[r * 24 + c] * chi0[c][J];
            F(gd[r], J) += f;
          }
        }
      }
  std::vector<char> pinned((std::size_t)nd, 0);
  pinned[0] = pinned[1] = pinned[2] = 1;
  for (long d = 0; d < nd; ++d) if (!touched[d]) pinned[d] = 1;
  SpMat K((int)nd, (int)nd);
  K.setFromTriplets(trips.begin(), trips.end());
  trips.clear(); trips.shrink_to_fit();
  for (int c = 0; c < K.outerSize(); ++c)
    for (SpMat::InnerIterator it(K, c); it; ++it)
      if (pinned[it.row()] || pinned[it.col()]) it.valueRef() = (it.row() == it.col()) ? 1.0 : 0.0;
  K.prune(0.0);
  for (long d = 0; d < nd; ++d) if (pinned[d]) for (int J : cases) F(d, J) = 0.0;
  Eigen::ConjugateGradient<SpMat, Eigen::Lower | Eigen::Upper> cg;
  cg.setTolerance(cg_tol);
  cg.setMaxIterations((int)std::min<long>(nd * 2, 200000));
  cg.compute(K);
  auto t0 = std::chrono::steady_clock::now();
  Eigen::MatrixXd X = Eigen::MatrixXd::Zero(nd, 6);
  for (int J : cases) {
    Eigen::VectorXd x = cg.solve(F.col(J));
    X.col(J) = x;
    R.cg_iters_max = std::max(R.cg_iters_max, (int)cg.iterations());
    if (cg.info() != Eigen::Success) R.converged = false;
  }
  auto t1 = std::chrono::steady_clock::now();
  R.solve_ms = std::chrono::duration<double, std::milli>(t1 - t0).count();
  const double vol = (double)nx * ny * nz * h * h * h;
  for (int k = 0; k < nz; ++k)
    for (int j = 0; j < ny; ++j)
      for (int i = 0; i < nx; ++i) {
        if (!grid.solid(i, j, k)) continue;
        long gd[24];
        for (int a = 0; a < 8; ++a) {
          long p = pid(i + kOff[a][0], j + kOff[a][1], k + kOff[a][2]);
          gd[3 * a] = 3 * p; gd[3 * a + 1] = 3 * p + 1; gd[3 * a + 2] = 3 * p + 2;
        }
        for (int J : cases) {
          double diffJ[24];
          for (int r = 0; r < 24; ++r) diffJ[r] = chi0[r][J] - X(gd[r], J);
          double kd[24];
          for (int r = 0; r < 24; ++r) { double s = 0; for (int c = 0; c < 24; ++c) s += ke[r * 24 + c] * diffJ[c]; kd[r] = s; }
          for (int I = 0; I < 6; ++I) { double s = 0; for (int r = 0; r < 24; ++r) s += chi0[r][I] * kd[r]; R.CH[I][J] += s / vol; }
        }
      }
  return R;
}
struct Cubic { double C11 = 0, C12 = 0, C44 = 0, zener = 0, E100 = 0; };
Cubic cubic_of(const HomogResult& R) {
  Cubic c;
  c.C11 = R.CH[0][0];
  c.C12 = 0.5 * (R.CH[1][0] + R.CH[2][0]);
  c.C44 = R.CH[3][3];
  double d = c.C11 - c.C12;
  c.zener = d != 0 ? 2.0 * c.C44 / d : 0.0;
  double den = c.C11 + c.C12;
  c.E100 = den != 0 ? d * (c.C11 + 2 * c.C12) / den : 0.0;
  return c;
}
double E100_of(double C11, double C12) {
  double d = C11 - C12, den = C11 + C12;
  return den != 0 ? d * (C11 + 2 * C12) / den : 0.0;
}
// Full 6x6 homogenized tensor (for the stretched/orthotropic cell of C5). Returns
// the directional Young's moduli E_x,E_y,E_z from the compliance diagonal.
struct Ortho { double Ex, Ey, Ez, Gyz, Gzx, Gxy; };
Ortho ortho_of(const HomogResult& R) {
  // Invert the 6x6 upper-left symmetric stiffness to compliance; E_i = 1/S_ii.
  Eigen::Matrix<double, 6, 6> C;
  for (int i = 0; i < 6; ++i) for (int j = 0; j < 6; ++j) C(i, j) = 0.5 * (R.CH[i][j] + R.CH[j][i]);
  Eigen::Matrix<double, 6, 6> S = C.inverse();
  return {1.0 / S(0, 0), 1.0 / S(1, 1), 1.0 / S(2, 2),
          1.0 / S(3, 3), 1.0 / S(4, 4), 1.0 / S(5, 5)};
}

// ============================ env helpers ===================================
std::vector<double> env_doubles(const char* key, const std::vector<double>& def) {
  const char* s = std::getenv(key);
  if (!s) return def;
  std::vector<double> out; std::stringstream ss(s); std::string tok;
  while (std::getline(ss, tok, ',')) if (!tok.empty()) out.push_back(std::atof(tok.c_str()));
  return out.empty() ? def : out;
}
std::vector<int> env_ints(const char* key, const std::vector<int>& def) {
  const char* s = std::getenv(key);
  if (!s) return def;
  std::vector<int> out; std::stringstream ss(s); std::string tok;
  while (std::getline(ss, tok, ',')) if (!tok.empty()) out.push_back(std::atoi(tok.c_str()));
  return out.empty() ? def : out;
}
std::vector<double> env_dbls(const char* key, const std::vector<double>& def) {
  const char* s = std::getenv(key);
  if (!s) return def;
  std::vector<double> out; std::stringstream ss(s); std::string tok;
  while (std::getline(ss, tok, ',')) if (!tok.empty()) out.push_back(std::atof(tok.c_str()));
  return out.empty() ? def : out;
}
int env_int(const char* key, int def) { const char* s = std::getenv(key); return s ? std::atoi(s) : def; }
double env_dbl(const char* key, double def) { const char* s = std::getenv(key); return s ? std::atof(s) : def; }
FILE* csv_open(const std::string& name) {
  const char* dir = std::getenv("TOPOPT_LATTICE_CSV_DIR");
  if (!dir) return nullptr;
  std::string path = std::string(dir) + "/" + name;
  FILE* f = std::fopen(path.c_str(), "w");
  if (f) std::printf("  [writing %s]\n", path.c_str());
  return f;
}

// ================================ B1 SELF CHECK ============================
void SELF_checks() {
  std::printf("\n===== SELF (bar B1) — instrument recovers E_solid to 4 digits =====\n");
  for (double L : {4.0, 8.0, 16.0, 32.0}) {
    VoxelGrid g = build_octet(L, 1e9, 1, 1, 1, 16);  // huge r -> all solid
    if (volume_fraction(g) < 0.999999) { std::printf("  L=%-4.0f NOT fully solid\n", L); continue; }
    Cubic c = cubic_of(homogenize(g, {0, 3}, 1e-11));
    double relE = (c.E100 - kE) / kE;
    std::printf("  L=%-5.0fmm solid cell: E100=%.4f MPa (E_solid=%.1f)  rel=%+.6f  Zener=%.4f -> %s\n",
                L, c.E100, kE, relE, c.zener,
                std::fabs(relE) < 1e-4 ? "PASS (4 digits)" : "CHECK");
  }
  const double cc = kE / ((1 + kNu) * (1 - 2 * kNu));
  const double C11 = cc * (1 - kNu), C12 = cc * kNu, C44 = kE / (2 * (1 + kNu));
  Hex8Stiffness Kiso = hex8_stiffness(kE, kNu, 1.7);
  Hex8Stiffness Kcub = hex8_stiffness_cubic(C11, C12, C44, 1.7);
  double maxabs = 0;
  for (int i = 0; i < 576; ++i) maxabs = std::max(maxabs, std::fabs(Kiso.k[i] - Kcub.k[i]));
  std::printf("  cubic(iso tensor) vs hex8_stiffness: max|dK|=%.3e -> %s\n",
              maxabs, maxabs == 0.0 ? "BIT-IDENTICAL" : (maxabs < 1e-9 ? "within 1e-9" : "MISMATCH"));
}

// ================================ C1 ======================================
// PROVE the tensor is scale-invariant: same relative density (same r/L, same vpc)
// at cell sizes 4/8/16/32 mm -> identical cubic tensor. The physical strut DIAMETER
// scales with L (the printability payoff), the tensor does not.
void C1_scale_invariance() {
  std::printf("\n===== C1 — tensor scale-invariance: octet at cells 4/8/16/32 mm =====\n");
  std::vector<double> Ls = env_doubles("TOPOPT_GCS_C1_LS", {4, 8, 16, 32});
  std::vector<double> vfs = env_doubles("TOPOPT_GCS_C1_VFS", {0.20, 0.40});
  std::vector<int> vpcs = env_ints("TOPOPT_GCS_C1_VPCS", {16, 24, 32});
  FILE* csv = csv_open("c1_scale_invariance.csv");
  if (csv) std::fprintf(csv, "target_vf,vpc,cell_mm,rho,strut_diam_mm,vox_per_strut,C11,C12,C44,zener,E100,"
                             "E100_rel_dev_vs_L8,C11_rel_dev,C12_rel_dev,C44_rel_dev\n");
  for (double tvf : vfs) {
    for (int vpc : vpcs) {
      std::printf("\n  target rho=%.2f, vpc=%d:\n", tvf, vpc);
      std::printf("    %-8s %-8s %-11s %-9s %-11s %-11s %-11s %-8s %-11s\n",
                  "cell_mm", "rho", "strut_d_mm", "vox/str", "C11", "C12", "C44", "Zener", "E100");
      // r/L fixed across L: calibrate once at L=8 then scale by L.
      double rL = calibrate_octet_r(8.0, tvf, vpc) / 8.0;
      std::vector<Cubic> results; std::vector<double> rhos, diams;
      for (double L : Ls) {
        double r = rL * L;
        VoxelGrid g = build_octet(L, r, 1, 1, 1, vpc);
        double rho = volume_fraction(g);
        Cubic c = cubic_of(homogenize(g, {0, 1, 2, 3, 4, 5}, 1e-10));
        double diam = 2 * r, vps = 2 * r * vpc / L;
        results.push_back(c); rhos.push_back(rho); diams.push_back(diam);
        std::printf("    %-8.1f %-8.4f %-11.4f %-9.2f %-11.3f %-11.3f %-11.3f %-8.4f %-11.3f\n",
                    L, rho, diam, vps, c.C11, c.C12, c.C44, c.zener, c.E100);
      }
      // deviation vs the L=8 reference (index of 8 in Ls, else 0)
      int ref = 0; for (std::size_t i = 0; i < Ls.size(); ++i) if (Ls[i] == 8.0) ref = (int)i;
      double maxdev = 0;
      for (std::size_t i = 0; i < results.size(); ++i) {
        double d = std::fabs(results[i].E100 - results[ref].E100) / results[ref].E100;
        maxdev = std::max(maxdev, d);
        if (csv) std::fprintf(csv, "%.2f,%d,%.1f,%.4f,%.4f,%.3f,%.3f,%.3f,%.3f,%.4f,%.3f,%.2e,%.2e,%.2e,%.2e\n",
                              tvf, vpc, Ls[i], rhos[i], diams[i], 2 * rL * Ls[i] * vpc / Ls[i], /*vps*/
                              results[i].C11, results[i].C12, results[i].C44, results[i].zener, results[i].E100,
                              d,
                              std::fabs(results[i].C11 - results[ref].C11) / results[ref].C11,
                              std::fabs(results[i].C12 - results[ref].C12) / results[ref].C12,
                              std::fabs(results[i].C44 - results[ref].C44) / results[ref].C44);
      }
      std::printf("    -> max |E100 deviation| across 4x cell-size range = %.3e  (%s)\n",
                  maxdev, maxdev < 1e-3 ? "SCALE-INVARIANT to CG precision" : "deviation present");
      std::printf("    -> strut diameter spans %.3f..%.3f mm (%.1fx) at IDENTICAL tensor.\n",
                  diams.front(), diams.back(), diams.back() / diams.front());
    }
  }
  if (csv) std::fclose(csv);
  std::printf("\n  READ: at fixed r/L and vpc the voxel occupancy pattern is IDENTICAL for every cell\n"
              "  size (voxel centres map to the same unit-cell fractions), and the hex8 homogenization\n"
              "  is exactly a uniform mesh SCALING -> CH is invariant by construction (algebra: Ke~h,\n"
              "  chi0~h, solve x~h, CH=(1/vol)chi0.Ke.(chi0-x) ~ h^3/h^3 = 1). Any residual is CG tol.\n");
}

// ================================ C2 ======================================
// THE CEILING. Homogenized prediction of a member's axial modulus = E100 (the bulk
// periodic tensor, size-independent for a continuum uniaxial). Resolved reference =
// apparent modulus of the actual strutted member, cross-section cells_across^2 cells,
// m_long cells long, FREE lateral surfaces. As cells_across falls, free-surface /
// finite-size softening grows -> that IS the homogenization (scale-separation) error.
// Report where |E100 - E_resolved|/E_resolved exceeds +-2.4% (library's band).
void C2_cells_per_member() {
  std::printf("\n===== C2 — homogenization error vs CELLS-PER-MEMBER (the ceiling) =====\n");
  const int vpc = env_int("TOPOPT_GCS_C2_VPC", 16);
  const int m_long = env_int("TOPOPT_GCS_C2_MLONG", 6);
  const double S = env_dbl("TOPOPT_GCS_C2_CELL", 5.0);       // cell size (mm); scale-free by C1
  std::vector<double> vfs = env_doubles("TOPOPT_GCS_C2_VFS", {0.30});
  std::vector<double> cpm = env_doubles("TOPOPT_GCS_C2_CPM", {5, 4, 3, 2, 1, 0.5});
  std::printf("  cell S=%.1f mm, vpc=%d, %d cells long, axial (free lateral surfaces).\n", S, vpc, m_long);
  std::printf("  bar: |E100_periodic - E_resolved|/E_resolved <= 2.4%% (library's validated band).\n\n");
  FILE* csv = csv_open("c2_cells_per_member.csv");
  if (csv) std::fprintf(csv, "target_vf,rho,cells_across,cell_mm,strut_diam_mm,vox_per_strut,"
                             "E100_periodic_MPa,E_resolved_MPa,homog_err_pct,resolved_dof,resolved_ms,verdict\n");
  for (double tvf : vfs) {
    double r = calibrate_octet_r(S, tvf, vpc);
    // bulk periodic truth (single cell, this vpc) — the homogenized prediction
    double E100 = cubic_of(homogenize(build_octet(S, r, 1, 1, 1, vpc), {0, 3}, 1e-9)).E100;
    double diam = 2 * r, vps = 2 * r * vpc / S;
    std::printf("  target rho=%.2f: E100_periodic=%.2f MPa, strut d=%.3f mm (%.1f vox/strut)\n",
                tvf, E100, diam, vps);
    std::printf("    %-12s %-8s %-13s %-13s %-11s %-8s\n",
                "cells_across", "rho", "E_resolved", "E100_periodic", "homog_err%", "verdict");
    for (double nc : cpm) {
      VoxelGrid m = build_member(S, r, nc, m_long, vpc);
      double rho_m = volume_fraction(m);
      double ms = 0; long dof = 0;
      double eR = resolved_E(m, 2, &ms, &dof);
      // A sub-cell member can percolate so weakly that eR collapses toward 0: that is
      // "homogenization is meaningless here", not a small error — report DISCONNECTED.
      const bool disconnected = !(eR > 0.02 * E100);
      double err = disconnected ? NAN : 100.0 * (E100 - eR) / eR;
      bool go = std::isfinite(err) && std::fabs(err) <= 2.4;
      const char* verdict = disconnected ? "DISCONNECTED" : (go ? "GO" : "NO-GO");
      std::printf("    %-12.2f %-8.4f %-13.2f %-13.2f %-+11.2f %-8s\n",
                  nc, rho_m, eR, E100, disconnected ? NAN : err, verdict);
      if (csv) std::fprintf(csv, "%.2f,%.4f,%.2f,%.2f,%.4f,%.2f,%.4f,%.4f,%.2f,%ld,%.0f,%s\n",
                            tvf, rho_m, nc, S, diam, vps, E100, eR, disconnected ? NAN : err, dof, ms, verdict);
    }
    std::printf("\n");
  }
  if (csv) std::fclose(csv);
  std::printf("  READ: the smallest cells_across whose |homog_err| <= 2.4%% is the CEILING (minimum\n"
              "  cells per member). Cell growth that pushes a member below it leaves the certifiable band.\n"
              "  Axial (RVE-convergence) is the ROBUST lower bound; bending stresses the surface layer\n"
              "  harder and needs MORE cells -> the true structural ceiling is >= this one.\n");
}

// ============================ transverse (bending) stiffness ================
// Guided-cantilever transverse stiffness along z: clamp z=0 (all DOF), prescribe
// u_x=delta and u_z=0 on the z=top face (no tip rotation), u_y free; K = sum(Fx_top)/delta.
// Displacement-controlled at BOTH ends -> no rigid modes -> well-conditioned (unlike the
// free-surface axial column). `lattice` selects the cubic-tensor material for the
// homogenized macro grid; otherwise per-element Es for the resolved struts.
double transverse_K(const VoxelGrid& g, const std::vector<double>& ey,
                    const std::vector<char>& mask, const std::vector<double>& c11,
                    const std::vector<double>& c12, const std::vector<double>& c44,
                    bool lattice, double* ms = nullptr, long* nd = nullptr) {
  const double h = g.spacing;
  std::vector<char> issolid((std::size_t)fea_node_count(g), 0);
  for (int k = 0; k < g.nz; ++k)
    for (int j = 0; j < g.ny; ++j)
      for (int i = 0; i < g.nx; ++i)
        if (g.solid(i, j, k)) for (int n : fea_element_nodes(g, i, j, k)) issolid[n] = 1;
  const double delta = kStrain * (g.nz * h) * 2.0;   // a modest transverse drive
  std::vector<DirichletBC> bcs;
  std::vector<int> topnodes;
  for (int j = 0; j <= g.ny; ++j)
    for (int i = 0; i <= g.nx; ++i) {
      int nb = fea_node_index(g, i, j, 0);
      if (issolid[nb]) { bcs.push_back({nb, 0, 0.0}); bcs.push_back({nb, 1, 0.0}); bcs.push_back({nb, 2, 0.0}); }
      int nt = fea_node_index(g, i, j, g.nz);
      if (issolid[nt]) { bcs.push_back({nt, 0, delta}); bcs.push_back({nt, 2, 0.0}); topnodes.push_back(nt); }
    }
  if (nd) *nd = 3L * fea_node_count(g);
  FeaSolution sol;
  static const double rtol = [] { const char* s = std::getenv("TOPOPT_GCS_RESTOL"); return s ? std::atof(s) : 1e-6; }();
  auto t0 = std::chrono::steady_clock::now();
  try {
    if (lattice) sol = fea_solve_cg_lattice(g, ey, mask, c11, c12, c44, kNu, bcs, {}, 1e-7, 40000, nullptr);
    else sol = fea_solve_cg(g, ey, kNu, bcs, {}, rtol, 40000, nullptr, nullptr);
  } catch (const std::exception& e) { std::fprintf(stderr, "  [transverse_K unconverged: %s]\n", e.what()); return -1.0; }
  if (ms) *ms = std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - t0).count();
  std::vector<double> react(3L * fea_node_count(g), 0.0);
  const Hex8Stiffness KeIso1 = hex8_stiffness(1.0, kNu, h);
  for (int k = 0; k < g.nz; ++k)
    for (int j = 0; j < g.ny; ++j)
      for (int i = 0; i < g.nx; ++i) {
        if (!g.solid(i, j, k)) continue;
        const std::size_t e = g.index(i, j, k);
        const std::array<int, 8> en = fea_element_nodes(g, i, j, k);
        std::array<double, 24> ue{}; int edof[24];
        for (int a = 0; a < 8; ++a) for (int c = 0; c < 3; ++c) { edof[3*a+c] = 3*en[a]+c; ue[3*a+c] = sol.at(en[a], c); }
        Hex8Stiffness Ke;
        if (lattice && !mask.empty() && mask[e]) Ke = hex8_stiffness_cubic(c11[e], c12[e], c44[e], h);
        else { Ke = KeIso1; const double f = ey[e]; for (auto& v : Ke.k) v *= f; }
        for (int rr = 0; rr < 24; ++rr) { double s = 0; for (int c = 0; c < 24; ++c) s += Ke(rr, c) * ue[c]; react[edof[rr]] += s; }
      }
  double Fx = 0; for (int n : topnodes) Fx += react[3 * n + 0];
  return std::fabs(Fx) / delta;
}
// C2b — BENDING ceiling. Resolved guided-cantilever transverse stiffness vs the
// homogenized macro model (1 cubic element per cell = the finest a homogenized lattice
// can legitimately be meshed). Error vs cells-across is the bending scale-separation.
void C2b_bending() {
  std::printf("\n===== C2b — BENDING ceiling: transverse stiffness, resolved vs homogenized macro =====\n");
  const int vpc = env_int("TOPOPT_GCS_C2B_VPC", 12);
  const double S = env_dbl("TOPOPT_GCS_C2B_CELL", 5.0);
  const double tvf = env_dbl("TOPOPT_GCS_C2B_VF", 0.30);
  const int Lb = env_int("TOPOPT_GCS_C2B_LB", 6);      // cantilever length in cells
  std::vector<int> ncs = env_ints("TOPOPT_GCS_C2B_NC", {1, 2, 3, 4});
  double r = calibrate_octet_r(S, tvf, vpc);
  // Tensor at the ACHIEVED rho (voxel quantization makes achieved != target), and use
  // the periodic-homogenized tensor at THIS vpc so the only difference resolved-vs-homog
  // is scale separation, not a density or resolution mismatch.
  double rho_cell = volume_fraction(build_octet(S, r, 1, 1, 1, vpc));
  Cubic pt = cubic_of(homogenize(build_octet(S, r, 1, 1, 1, vpc), {0, 1, 2, 3, 4, 5}, 1e-9));
  CubicTensor Ct{pt.C11, pt.C12, pt.C44};
  std::printf("  cell S=%.1f mm, vpc=%d, cantilever %d cells long. periodic tensor at achieved rho=%.3f: C11=%.1f C12=%.1f C44=%.1f\n",
              S, vpc, Lb, rho_cell, Ct.C11, Ct.C12, Ct.C44);
  std::printf("  homogenized macro = %s-per-cell cubic elements (finest legitimate homogenized mesh).\n", "1");
  std::printf("    %-12s %-8s %-13s %-13s %-11s %-8s\n", "cells_across", "rho", "K_resolved", "K_homog_macro", "bend_err%", "verdict");
  FILE* csv = csv_open("c2b_bending.csv");
  if (csv) std::fprintf(csv, "cells_across,rho,K_resolved,K_homog_macro,bend_err_pct,resolved_dof,resolved_ms,verdict\n");
  auto segs = octet_struts();
  for (int nc : ncs) {
    // resolved cantilever: nc x nc cells cross-section, Lb cells long (z)
    VoxelGrid g = build_octet(S, r, nc, nc, Lb, vpc);
    double rho = volume_fraction(g);
    std::vector<double> ey(g.voxel_count(), 0.0);
    for (std::size_t e = 0; e < g.voxel_count(); ++e) if (g.tags[e] != VoxelTag::Empty) ey[e] = kE;
    double msR = 0; long ndR = 0;
    double Kres = transverse_K(g, ey, {}, {}, {}, {}, false, &msR, &ndR);
    // homogenized macro: nc x nc x Lb cubic elements
    VoxelGrid mg = macro_grid(S, nc, nc, Lb);
    std::vector<double> mey(mg.voxel_count(), kE);
    std::vector<char> mask(mg.voxel_count(), 1);
    std::vector<double> mc11(mg.voxel_count(), Ct.C11), mc12(mg.voxel_count(), Ct.C12), mc44(mg.voxel_count(), Ct.C44);
    double Khom = transverse_K(mg, mey, mask, mc11, mc12, mc44, true);
    double err = (Kres > 0 && Khom > 0) ? 100.0 * (Khom - Kres) / Kres : NAN;
    bool go = std::isfinite(err) && std::fabs(err) <= 2.4;
    std::printf("    %-12d %-8.4f %-13.3f %-13.3f %-+11.2f %-8s\n",
                nc, rho, Kres, Khom, err, Kres <= 0 ? "SOLVE-FAIL" : (go ? "GO" : "NO-GO"));
    if (csv) std::fprintf(csv, "%d,%.4f,%.4f,%.4f,%.2f,%ld,%.0f,%s\n",
                          nc, rho, Kres, Khom, err, ndR, msR, Kres <= 0 ? "SOLVE-FAIL" : (go ? "GO" : "NO-GO"));
  }
  if (csv) std::fclose(csv);
  std::printf("  READ: the smallest cells_across with |bend_err|<=2.4%% is the BENDING ceiling. This is the\n"
              "  binding structural number (>= the axial ceiling) because bending loads the section's outer\n"
              "  cells hardest and the homogenized continuum cannot be meshed finer than one cell.\n");
}


// ============================ C2c — FRACTIONAL cells across ==================
// ★ WHY THIS EXISTS. `aesthetic_cells_per_member_hard_floor` is 2.0 and the ONLY
// reason it is 2 rather than something smaller is that C2b measured whole cells:
// {1, 2, 3, 4} -> {+48.5, +8.5, +4.1, +2.59}%. The maintainer's parts routinely want
// larger cells than 2-across allows, and 8.5% -> 48.5% is a 5.7x jump across one
// step, so a 1.5 cannot be interpolated — the curve is least linear exactly there.
// This measures it instead.
//
// SAME quantity as C2b: transverse (bending) stiffness of a resolved octet member
// against the homogenized continuum carrying the periodic cubic tensor at the same
// density. TWO differences, both forced by the fractional width:
//
//   1. the member comes from `build_member`, which admits a fractional cells_across
//      (C2b used build_octet and whole cells). At 1.5 the cross-section cuts cells.
//   2. the macro continuum CANNOT be meshed at one element per cell when the width is
//      not a whole number of cells. So the macro side is solved at SEVERAL element
//      sizes and all of them are reported. If they agree, the error is scale
//      separation; if they do not, the macro mesh is doing the talking and the number
//      is not about cells-per-member at all. Reporting one of them would hide that.
void C2c_fractional_bending() {
  std::printf("\n===== C2c — BENDING error at FRACTIONAL cells across a member =====\n");
  const int vpc = env_int("TOPOPT_GCS_C2C_VPC", 12);
  const double S = env_dbl("TOPOPT_GCS_C2C_CELL", 5.0);
  const double tvf = env_dbl("TOPOPT_GCS_C2C_VF", 0.30);
  const int Lb = env_int("TOPOPT_GCS_C2C_LB", 6);
  const std::vector<double> as =
      env_dbls("TOPOPT_GCS_C2C_A", {1.0, 1.25, 1.5, 1.75, 2.0, 2.5, 3.0});
  const std::vector<int> ns = env_ints("TOPOPT_GCS_C2C_N", {1, 2, 4});
  const double r = calibrate_octet_r(S, tvf, vpc);
  const double rho_cell = volume_fraction(build_octet(S, r, 1, 1, 1, vpc));
  Cubic pt = cubic_of(homogenize(build_octet(S, r, 1, 1, 1, vpc), {0, 1, 2, 3, 4, 5}, 1e-9));
  CubicTensor Ct{pt.C11, pt.C12, pt.C44};
  std::printf("  cell S=%.1f mm, vpc=%d, cantilever %d cells long, periodic rho=%.4f\n",
              S, vpc, Lb, rho_cell);
  std::printf("  C11=%.1f C12=%.1f C44=%.1f  (the SAME tensor for every row: only the\n"
              "  width in cells changes, so the column is scale separation alone)\n",
              Ct.C11, Ct.C12, Ct.C44);
  std::printf("    %-8s %-9s %-9s %-12s", "a(cells)", "rho_mem", "rho/cell", "K_resolved");
  for (int n : ns) std::printf(" %-9s %-9s", "K_mac", "err%");
  std::printf("\n");
  FILE* csv = csv_open("c2c_fractional_bending.csv");
  if (csv) {
    std::fprintf(csv, "cells_across,rho_member,rho_cell,K_resolved");
    for (int n : ns) std::fprintf(csv, ",K_macro_n%d,err_pct_n%d", n, n);
    std::fprintf(csv, ",connected\n");
  }
  for (double a : as) {
    VoxelGrid g = build_member(S, r, a, Lb, vpc);
    const double rho = volume_fraction(g);
    std::vector<double> ey(g.voxel_count(), 0.0);
    for (std::size_t e = 0; e < g.voxel_count(); ++e)
      if (g.tags[e] != VoxelTag::Empty) ey[e] = kE;
    double msR = 0; long ndR = 0;
    const double Kres = transverse_K(g, ey, {}, {}, {}, {}, false, &msR, &ndR);
    std::printf("    %-8.2f %-9.4f %-9.3f %-12.4f", a, rho, rho / rho_cell, Kres);
    if (csv) std::fprintf(csv, "%.2f,%.4f,%.4f,%.4f", a, rho, rho_cell, Kres);
    for (int n : ns) {
      // Macro continuum of the SAME physical bar: cross-section (a*S)^2, length Lb*S,
      // meshed with cubes of edge (a*S)/n.
      const double elem = a * S / double(n);
      const int nz = std::max(1, (int)std::lround(Lb * S / elem));
      VoxelGrid mg = macro_grid(elem, n, n, nz);
      std::vector<double> mey(mg.voxel_count(), kE);
      std::vector<char> mask(mg.voxel_count(), 1);
      std::vector<double> c11(mg.voxel_count(), Ct.C11), c12(mg.voxel_count(), Ct.C12),
          c44(mg.voxel_count(), Ct.C44);
      const double Kh = transverse_K(mg, mey, mask, c11, c12, c44, true);
      const double err = (Kres > 0 && Kh > 0) ? 100.0 * (Kh - Kres) / Kres : NAN;
      std::printf(" %-9.4f %-+9.2f", Kh, err);
      if (csv) std::fprintf(csv, ",%.4f,%.2f", Kh, err);
    }
    std::printf("  %s\n", Kres > 0 ? "" : "<- DISCONNECTED / SOLVE-FAIL");
    if (csv) std::fprintf(csv, ",%d\n", Kres > 0 ? 1 : 0);
  }
  if (csv) std::fclose(csv);
  std::printf("  READ: `rho/cell` is the member's density against the periodic cell's. It drifts at\n"
              "  fractional widths because the cross-section CUTS cells, and that drift is part of\n"
              "  the error - it is 'as deployed', the same convention C2b used.\n"
              "  A fractional floor is only defensible if the err%% columns AGREE across macro\n"
              "  meshes. Where they disagree, the number is about the macro mesh, not the lattice.\n");
}

// ================================ C3 ======================================
// Cross the ceiling with member WIDTH. By C1 the ceiling is dimensionless (a cells-
// per-member number N*), so the largest cell for a member of width W is W/N*. This
// VERIFIES that by measuring the homogenization error at a FIXED cells-per-member
// (e.g. 3) for members of width 5, 9.4, 20 mm — the error must be the SAME (scale-
// invariant), which is what lets one number serve every width.
void C3_width_cross() {
  std::printf("\n===== C3 — ceiling x member WIDTH (5 / 9.4 / 20 mm) =====\n");
  const int vpc = env_int("TOPOPT_GCS_C3_VPC", 16);
  const int m_long = env_int("TOPOPT_GCS_C3_MLONG", 6);
  const double tvf = env_dbl("TOPOPT_GCS_C3_VF", 0.30);
  std::vector<double> widths = env_doubles("TOPOPT_GCS_C3_W", {5.0, 9.4, 20.0});
  std::vector<double> nstars = env_doubles("TOPOPT_GCS_C3_NSTARS", {2, 3});
  std::printf("  PART A — verify the ceiling is scale-invariant: fixed cells_across=3, vary width.\n");
  std::printf("    %-8s %-9s %-9s %-13s %-13s %-11s\n", "W_mm", "cell_mm", "rho", "E_resolved", "E100_periodic", "homog_err%");
  FILE* csv = csv_open("c3_width_cross.csv");
  if (csv) std::fprintf(csv, "part,W_mm,cells_across,cell_mm,strut_diam_mm,rho,E100_periodic,E_resolved,homog_err_pct\n");
  const double fixed_cpm = env_dbl("TOPOPT_GCS_C3_CPM", 3.0);
  for (double W : widths) {
    double S = W / fixed_cpm;                       // cell size to put `fixed_cpm` cells across W
    double r = calibrate_octet_r(S, tvf, vpc);
    double E100 = cubic_of(homogenize(build_octet(S, r, 1, 1, 1, vpc), {0, 3}, 1e-9)).E100;
    VoxelGrid m = build_member(S, r, fixed_cpm, m_long, vpc);
    double rho_m = volume_fraction(m), eR = resolved_E(m, 2);
    double err = eR > 0 ? 100.0 * (E100 - eR) / eR : NAN;
    std::printf("    %-8.1f %-9.3f %-9.4f %-13.2f %-13.2f %-+11.2f\n", W, S, rho_m, eR, E100, err);
    if (csv) std::fprintf(csv, "A,%.2f,%.2f,%.3f,%.4f,%.4f,%.4f,%.4f,%.2f\n",
                          W, fixed_cpm, S, 2 * r, rho_m, E100, eR, err);
  }
  std::printf("\n  PART B — the deliverable table: largest cell size per width for each candidate ceiling N*.\n");
  std::printf("    (largest printable-and-certifiable cell = W / N*)\n");
  std::printf("    %-8s", "W_mm");
  for (double ns : nstars) std::printf("  N*=%-4.1f->S<=", ns);
  std::printf("\n");
  for (double W : widths) {
    std::printf("    %-8.1f", W);
    for (double ns : nstars) std::printf("      %-8.2f mm", W / ns);
    std::printf("\n");
    if (csv) for (double ns : nstars) std::fprintf(csv, "B,%.2f,%.1f,%.3f,,,,,\n", W, ns, W / ns);
  }
  if (csv) std::fclose(csv);
  std::printf("  READ: Part A confirms the error at 3 cells-across is the SAME regardless of physical\n"
              "  width -> one ceiling number serves all widths. Part B turns C2's ceiling N* into the\n"
              "  per-width max cell size. A thin rib (9.4 mm) at N*=3 caps the cell at ~3.1 mm — SMALLER\n"
              "  than the 8 mm base the grade wants to grow FROM (see handoff BLOCKED-STOP).\n");
}

// ================================ C5 ======================================
// CONFORMAL WARP feasibility for the TENSOR. A graded-cell warp stretches cells
// along the grade direction. Homogenize a cell stretched by aspect a=Sz/Sx (radius
// recalibrated to hold relative density) and report how far the effective moduli
// drift from the unstretched cubic tensor. Where the drift exceeds 2.4% the warped
// cell is no longer "close enough to periodic" for the homogenized cubic tensor to
// apply — the distortion limit the task asks for.
void C5_conformal_warp() {
  std::printf("\n===== C5 — conformal warp: tensor drift vs cell STRETCH (distortion limit) =====\n");
  const int vpc = env_int("TOPOPT_GCS_C5_VPC", 32);   // finer -> less rho quantization
  const double tvf = env_dbl("TOPOPT_GCS_C5_VF", 0.30);
  const double L = 5.0;
  std::vector<double> aspects = env_doubles("TOPOPT_GCS_C5_ASPECTS",
      {1.0, 1.02, 1.05, 1.08, 1.10, 1.15, 1.20, 1.30, 1.50, 2.0});
  // Recalibrate radius IN THE STRETCHED GEOMETRY so every aspect holds the SAME
  // achieved rho -> the tensor drift is pure DISTORTION, not a density confound (the
  // earlier bug: an unstretched ref at a different achieved rho made a 5% stretch look
  // like -15% when that was entirely the density difference).
  auto build_at = [&](double a, double* rho_out) {
    double lo = 0.0005 * L, hi = 0.45 * L, r = 0;
    for (int it = 0; it < 32; ++it) {
      double mid = 0.5 * (lo + hi);
      (volume_fraction(build_octet_stretched(L, a, mid, vpc)) < tvf ? lo : hi) = mid; r = mid;
    }
    VoxelGrid g = build_octet_stretched(L, a, r, vpc);
    if (rho_out) *rho_out = volume_fraction(g);
    const double htol = env_dbl("TOPOPT_GCS_HOMOG_TOL", 1e-8);
    return homogenize(g, {0, 1, 2, 3, 4, 5}, htol);
  };
  double rho0 = 0;
  Ortho ref = ortho_of(build_at(1.0, &rho0));       // reference = a=1.0, SAME builder/rho
  const double Eref = ref.Ez;                        // cubic: Ex==Ez at a=1
  std::printf("  base cell L=%.1f mm, rho=%.4f (matched across aspects), vpc=%d. reference E=%.2f MPa.\n",
              L, rho0, vpc, Eref);
  std::printf("  aspect a = grown cell height / base = a per-cell size change of (a-1) x 100%%.\n");
  std::printf("    %-8s %-8s %-10s %-10s %-9s %-11s %-11s %-10s\n",
              "aspect", "rho", "Ex", "Ez(grade)", "Ez/Ex", "Ez_drift%", "Ex_drift%", "verdict");
  FILE* csv = csv_open("c5_conformal_warp.csv");
  if (csv) std::fprintf(csv, "aspect,rho,Ex,Ey,Ez,Gyz,Gzx,Gxy,anisotropy_Ez_Ex,Ez_drift_pct,Ex_drift_pct,max_drift_pct,verdict\n");
  for (double a : aspects) {
    double rho = 0; Ortho o = ortho_of(build_at(a, &rho));
    double ez_drift = 100.0 * (o.Ez - Eref) / Eref;
    double ex_drift = 100.0 * (o.Ex - Eref) / Eref;
    double maxd = std::max(std::fabs(ez_drift), std::fabs(ex_drift));
    bool go = maxd <= 2.4;
    std::printf("    %-8.2f %-8.4f %-10.2f %-10.2f %-9.4f %-+11.2f %-+11.2f %-10s\n",
                a, rho, o.Ex, o.Ez, o.Ez / o.Ex, ez_drift, ex_drift, go ? "GO" : "NO-GO");
    if (csv) std::fprintf(csv, "%.3f,%.4f,%.4f,%.4f,%.4f,%.4f,%.4f,%.4f,%.4f,%.2f,%.2f,%.2f,%s\n",
                          a, rho, o.Ex, o.Ey, o.Ez, o.Gyz, o.Gzx, o.Gxy, o.Ez / o.Ex, ez_drift, ex_drift, maxd, go ? "GO" : "NO-GO");
  }
  if (csv) std::fclose(csv);
  std::printf("  READ: rho is held fixed, so drift is pure distortion. A stretched octet is ORTHOTROPIC:\n"
              "  Ez (grade dir) stiffens, Ex softens, and Ez/Ex departs 1.0. The aspect at which either\n"
              "  leaves +-2.4%% of the cubic E is the per-cell size change the homogenized tensor tolerates.\n");
}

// ================================ B3 ======================================
// PRINTABILITY. The printed strut DIAMETER at each point of the density ramp,
// against a 0.4mm nozzle. This is the maintainer's motivation: at fixed cell size
// struts thin below extrudable as density falls; growing the cell keeps them fat.
// d(rho, S) is measured by calibrating the octet radius to rho at cell S.
void B3_printability() {
  std::printf("\n===== B3 — printed strut diameter along the density ramp (0.4mm nozzle) =====\n");
  const int vpc = env_int("TOPOPT_GCS_B3_VPC", 48);   // fine, for accurate diameter
  std::vector<double> Ss = env_doubles("TOPOPT_GCS_B3_CELLS", {4, 8, 16, 32});
  std::vector<double> rhos = env_doubles("TOPOPT_GCS_B3_RHOS",
      {0.05, 0.08, 0.10, 0.15, 0.20, 0.30, 0.40, 0.60});
  const double d_nozzle = 0.4;             // single-bead minimum
  const double d_reliable = 0.8;           // ~2 beads: reliably solid strut
  std::printf("  strut diameter d(rho, cell) in mm; extrudable floor: 1 bead=%.1f mm, reliable=%.1f mm.\n", d_nozzle, d_reliable);
  std::printf("  %-8s", "rho");
  for (double S : Ss) std::printf("  S=%-6.0fmm", S);
  std::printf("\n");
  FILE* csv = csv_open("b3_printability.csv");
  if (csv) { std::fprintf(csv, "rho"); for (double S : Ss) std::fprintf(csv, ",d_mm_cell%.0f", S); std::fprintf(csv, "\n"); }
  for (double rho : rhos) {
    std::printf("  %-8.2f", rho);
    if (csv) std::fprintf(csv, "%.2f", rho);
    for (double S : Ss) {
      double r = calibrate_octet_r(S, rho, vpc);
      double d = 2 * r;
      const char* flag = d < d_nozzle ? "x" : (d < d_reliable ? "~" : " ");
      std::printf("  %6.3f%-3s", d, flag);
      if (csv) std::fprintf(csv, ",%.4f", d);
    }
    std::printf("\n");
    if (csv) std::fprintf(csv, "\n");
  }
  if (csv) std::fclose(csv);
  std::printf("  (x = below 1-bead 0.4mm, unprintable;  ~ = 0.4-0.8mm, single-bead/unreliable)\n");
  std::printf("  READ: read DOWN a column to see a fixed cell thinning as rho falls, ACROSS a row to see\n"
              "  cell growth recovering diameter. This is the printability payoff C1 makes free in the tensor.\n");
}

// ============================ region fill (dyadic / graded) =================
// Fill the voxels of `g` whose centre z is in [z0,z1) with an octet pattern of cell
// size S (isotropic), lattice origin `org`, radius from `rfield(rho-controlling)`.
void fill_octet_slab(VoxelGrid& g, double S, double r, const Vec3& org, double z0, double z1,
                     const std::vector<Seg>& segs) {
  for (int k = 0; k < g.nz; ++k)
    for (int j = 0; j < g.ny; ++j)
      for (int i = 0; i < g.nx; ++i) {
        Vec3 c = g.voxel_center(i, j, k);
        if (c.z < z0 || c.z >= z1) continue;
        if (octet_dist2_box(c.x, c.y, c.z, S, S, S, org, segs) < r * r)
          g.set_tag(i, j, k, VoxelTag::Interior);
      }
}
double slab_rho(const VoxelGrid& g, double z0, double z1) {
  long s = 0, t = 0;
  for (int k = 0; k < g.nz; ++k)
    for (int j = 0; j < g.ny; ++j)
      for (int i = 0; i < g.nx; ++i) {
        Vec3 c = g.voxel_center(i, j, k);
        if (c.z < z0 || c.z >= z1) continue;
        ++t; if (g.solid(i, j, k)) ++s;
      }
  return t ? double(s) / double(t) : 0.0;
}
// von-Mises SCF localized to a z-band [zc-band, zc+band] vs far-field (the whole part).
double band_scf(const VoxelGrid& g, const FeaSolution& sol, double zc, double band, double* farfield_out) {
  std::vector<double> vm = fea_von_mises_field(g, kE, kNu, sol);
  double peak_band = 0, sum_all = 0; long n_all = 0;
  for (int k = 0; k < g.nz; ++k)
    for (int j = 0; j < g.ny; ++j)
      for (int i = 0; i < g.nx; ++i) {
        if (!g.solid(i, j, k)) continue;
        double v = vm[g.index(i, j, k)];
        sum_all += v; ++n_all;
        double z = g.voxel_center(i, j, k).z;
        if (std::fabs(z - zc) <= band && v > peak_band) peak_band = v;
      }
  double ff = n_all ? sum_all / double(n_all) : 0.0;
  if (farfield_out) *farfield_out = ff;
  return ff > 0 ? peak_band / ff : 0.0;
}

// Confined uniaxial-z apparent modulus of a resolved block (rollers on 4 lateral
// faces), for tall soft columns — verbatim confinement logic from density-band D4.
double confined_Ez(const VoxelGrid& g, FeaSolution* sol_out, double* ms = nullptr, long* nd = nullptr) {
  const int axis = 2, t1 = 0, t2 = 1;
  const double h = g.spacing;
  std::vector<char> issolid((std::size_t)fea_node_count(g), 0);
  for (int k = 0; k < g.nz; ++k)
    for (int j = 0; j < g.ny; ++j)
      for (int i = 0; i < g.nx; ++i)
        if (g.solid(i, j, k)) for (int n : fea_element_nodes(g, i, j, k)) issolid[n] = 1;
  const double delta = kStrain * (g.nz * h);
  std::vector<DirichletBC> bcs;
  std::vector<std::array<int, 3>> maxface;
  for (int c2 = 0; c2 <= g.ny; ++c2)
    for (int c1 = 0; c1 <= g.nx; ++c1) {
      int nlo = fea_node_index(g, c1, c2, 0);
      if (issolid[nlo]) bcs.push_back({nlo, axis, 0.0});
      int nhi = fea_node_index(g, c1, c2, g.nz);
      if (issolid[nhi]) { bcs.push_back({nhi, axis, delta}); maxface.push_back({nhi, c1, c2}); }
    }
  for (int k = 0; k <= g.nz; ++k)
    for (int c2 = 0; c2 <= g.ny; ++c2)
      for (int side = 0; side < 2; ++side) {
        int n = fea_node_index(g, side == 0 ? 0 : g.nx, c2, k);
        if (issolid[n]) bcs.push_back({n, t1, 0.0});
      }
  for (int k = 0; k <= g.nz; ++k)
    for (int c1 = 0; c1 <= g.nx; ++c1)
      for (int side = 0; side < 2; ++side) {
        int n = fea_node_index(g, c1, side == 0 ? 0 : g.ny, k);
        if (issolid[n]) bcs.push_back({n, t2, 0.0});
      }
  std::vector<double> ey(g.voxel_count(), 0.0);
  for (std::size_t e = 0; e < g.voxel_count(); ++e) if (g.tags[e] != VoxelTag::Empty) ey[e] = kE;
  if (nd) *nd = 3L * fea_node_count(g);
  static const double rtol = [] { const char* s = std::getenv("TOPOPT_GCS_RESTOL"); return s ? std::atof(s) : 1e-5; }();
  static const bool use_mg = [] { const char* s = std::getenv("TOPOPT_GCS_MG"); return !s || std::string(s) != "0"; }();
  FeaSolution sol;
  auto t0 = std::chrono::steady_clock::now();
  try {
    if (use_mg) sol = fea_solve_mgcg_matfree(g, ey, kNu, bcs, {}, rtol, 40000, nullptr, nullptr);
    else sol = fea_solve_cg(g, ey, kNu, bcs, {}, rtol, 40000, nullptr, nullptr);
  } catch (const std::exception& e) { std::fprintf(stderr, "  [confined_Ez unconverged: %s]\n", e.what()); return -1.0; }
  if (ms) *ms = std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - t0).count();
  double Fsum = 0.0;
  std::vector<double> react(3L * fea_node_count(g), 0.0);
  const Hex8Stiffness KeIso1 = hex8_stiffness(1.0, kNu, h);
  for (int k = 0; k < g.nz; ++k)
    for (int j = 0; j < g.ny; ++j)
      for (int i = 0; i < g.nx; ++i) {
        if (!g.solid(i, j, k)) continue;
        const std::array<int, 8> en = fea_element_nodes(g, i, j, k);
        std::array<double, 24> ue{}; int edof[24];
        for (int a = 0; a < 8; ++a) for (int c = 0; c < 3; ++c) { edof[3*a+c] = 3*en[a]+c; ue[3*a+c] = sol.at(en[a], c); }
        Hex8Stiffness Ke = KeIso1; for (auto& v : Ke.k) v *= kE;
        for (int rr = 0; rr < 24; ++rr) { double s = 0; for (int c = 0; c < 24; ++c) s += Ke(rr, c) * ue[c]; react[edof[rr]] += s; }
      }
  for (auto& m : maxface) Fsum += react[3 * m[0] + axis];
  const double A = (g.nx * h) * (g.ny * h);
  if (sol_out) *sol_out = sol;
  return std::fabs(Fsum) / (A * kStrain);
}

// ================================ C4 ======================================
// DYADIC transition: a fine octet (cell S) meeting a coarse octet (cell 2S) at the
// SAME relative density, sharing the interface plane. Because the coarse node set
// NESTS in the fine grid (2x refinement), the two connect at shared nodes with NO
// bridge struts — but only HALF the fine interface nodes carry a coarse strut, so
// load funnels through them. Measures whether the interface is a stress riser.
void C4_dyadic() {
  std::printf("\n===== C4 — DYADIC transition (cell S -> 2S), resolved =====\n");
  const int vpc = env_int("TOPOPT_GCS_C4_VPC", 16);       // voxels per FINE cell
  const double S = env_dbl("TOPOPT_GCS_C4_CELL", 5.0);
  const double tvf = env_dbl("TOPOPT_GCS_C4_VF", 0.30);
  const int kcoarse = env_int("TOPOPT_GCS_C4_KCOARSE", 2); // coarse cells per side (2S each)
  const int nfine_z = env_int("TOPOPT_GCS_C4_NFINEZ", 4);  // fine cells tall (below)
  const int ncoarse_z = env_int("TOPOPT_GCS_C4_NCOARSEZ", 2); // coarse cells tall (above)
  const double h = S / vpc;
  // transverse: coarse kcoarse cells of 2S == fine 2*kcoarse cells of S; width W
  const double W = kcoarse * 2 * S;
  auto segs = octet_struts();
  double r_fine = calibrate_octet_r(S, tvf, vpc);
  // Match the coarse cell to the fine cell's ACHIEVED rho (voxel quantization makes the
  // target unreliable), so the interface SCF reflects the CELL-SIZE step, not a density step.
  double rho_fine_target = volume_fraction(build_octet(S, r_fine, 1, 1, 1, vpc));
  double r_coarse = calibrate_octet_r(2 * S, rho_fine_target, 2 * vpc);
  VoxelGrid g;
  g.nx = (int)std::lround(W / h); g.ny = g.nx;
  const double z_if = nfine_z * S;               // interface height
  const double z_top = z_if + ncoarse_z * 2 * S;
  g.nz = (int)std::lround(z_top / h);
  g.spacing = h; g.origin = Vec3{0, 0, 0};
  g.tags.assign((std::size_t)g.nx * g.ny * g.nz, VoxelTag::Empty);
  fill_octet_slab(g, S, r_fine, Vec3{0, 0, 0}, 0.0, z_if, segs);            // fine below
  fill_octet_slab(g, 2 * S, r_coarse, Vec3{0, 0, 0}, z_if, z_top + 1, segs); // coarse above
  double rho_fine = slab_rho(g, 0.0, z_if), rho_coarse = slab_rho(g, z_if, z_top);
  std::printf("  fine cell S=%.1f (rho=%.3f, d=%.3f mm), coarse 2S=%.1f (rho=%.3f, d=%.3f mm).\n",
              S, rho_fine, 2 * r_fine, 2 * S, rho_coarse, 2 * r_coarse);
  std::printf("  block %dx%dx%d vox (W=%.1f mm, H=%.1f mm), interface at z=%.1f mm.\n",
              g.nx, g.ny, g.nz, W, z_top, z_if);
  FeaSolution sol; double ms = 0; long nd = 0;
  double Ez = confined_Ez(g, &sol, &ms, &nd);
  double ff = 0;
  double scf_if = band_scf(g, sol, z_if, S, &ff);
  // control: SCF within the pure-fine region (peak in a fine band away from interface)
  double scf_fine = band_scf(g, sol, 0.5 * z_if, S, nullptr);
  std::printf("  confined Ez = %.2f MPa (%ld DOF, %.0f ms).\n", Ez, nd, ms);
  std::printf("  SCF at interface (peak vM in +-1 cell / mean vM) = %.3f;  control SCF in fine bulk = %.3f\n",
              scf_if, scf_fine);
  std::printf("  interface stress riser = %.2fx the fine-bulk concentration.\n",
              scf_fine > 0 ? scf_if / scf_fine : 0.0);
  FILE* csv = csv_open("c4_dyadic.csv");
  if (csv) {
    std::fprintf(csv, "cell_fine_mm,cell_coarse_mm,rho_fine,rho_coarse,d_fine_mm,d_coarse_mm,Ez_MPa,scf_interface,scf_fine_control,dof,ms\n");
    std::fprintf(csv, "%.2f,%.2f,%.4f,%.4f,%.4f,%.4f,%.4f,%.4f,%.4f,%ld,%.0f\n",
                 S, 2 * S, rho_fine, rho_coarse, 2 * r_fine, 2 * r_coarse, Ez, scf_if, scf_fine, nd, ms);
    std::fclose(csv);
  }
  std::printf("  READ: coarse octet nodes NEST in the fine grid (2x), so the levels connect at shared\n"
              "  nodes with ZERO bridge struts and ZERO extra transition triangles; the coarse layer is\n"
              "  simply 8x fewer triangles per volume. The cost is that only half the fine interface nodes\n"
              "  meet a coarse strut -> the interface SCF above tells whether that funnelling matters.\n");
}

// ================================ C6 ======================================
// Resolved comparison of the two grading routes on ONE specimen with a real density
// grade. Both are height-graded octet COLUMNS (constant lateral cell size S0, so
// consecutive cells share interface nodes and struts stay connected by construction
// — PR 201's segment endpoints just move); they differ only in the z cell-height
// schedule:
//   DYADIC   : cell height jumps in factor-2 steps (S0, 2S0, 4S0) as density falls.
//   CONFORMAL: cell height grows smoothly cell-to-cell over the same total height.
// Same density profile rho(z), same specimen height. Reports confined stiffness, the
// stress concentration at each transition, and the printed strut diameter along the
// ramp (B3). Confined (rollers) so the soft low-density top is solvable.
struct CellPlan { double z0, z1, height, rho, radius, diam; };

// Build a resolved column from a z-schedule of cells (lateral nl x nl of size S0).
VoxelGrid build_column(double S0, int nl, int vpc, const std::vector<CellPlan>& cells, double* Htot) {
  auto segs = octet_struts();
  const double h = S0 / vpc;
  double H = 0; for (auto& c : cells) H += c.height;
  if (Htot) *Htot = H;
  VoxelGrid g;
  g.nx = nl * vpc; g.ny = nl * vpc; g.nz = std::max(1, (int)std::lround(H / h));
  g.spacing = h; g.origin = Vec3{0, 0, 0};
  g.tags.assign((std::size_t)g.nx * g.ny * g.nz, VoxelTag::Empty);
  for (auto& c : cells)
    for (int k = 0; k < g.nz; ++k) {
      double zc = (k + 0.5) * h;
      if (zc < c.z0 || zc >= c.z1) continue;
      for (int j = 0; j < g.ny; ++j)
        for (int i = 0; i < g.nx; ++i) {
          Vec3 p = g.voxel_center(i, j, k);
          // local cell lattice: lateral S0, vertical c.height, origin at (0,0,c.z0)
          if (octet_dist2_box(p.x, p.y, p.z, S0, S0, c.height, Vec3{0, 0, c.z0}, segs) < c.radius * c.radius)
            g.set_tag(i, j, k, VoxelTag::Interior);
        }
    }
  return g;
}
// Calibrate radius so a single lateral-S0 x height cell hits target rho.
double calibrate_cell_r(double S0, double height, double target_rho, int vpc) {
  auto segs = octet_struts();
  const double h = S0 / vpc;
  int nx = vpc, nz = std::max(1, (int)std::lround(height / h));
  auto rho_at = [&](double r) {
    long s = 0, t = 0;
    for (int k = 0; k < nz; ++k)
      for (int j = 0; j < nx; ++j)
        for (int i = 0; i < nx; ++i) {
          double x = (i + 0.5) * h, y = (j + 0.5) * h, z = (k + 0.5) * h; ++t;
          if (octet_dist2_box(x, y, z, S0, S0, height, Vec3{0, 0, 0}, segs) < r * r) ++s;
        }
    return double(s) / double(t);
  };
  double lo = 0.0005 * S0, hi = 0.45 * S0;
  for (int it = 0; it < 30; ++it) { double mid = 0.5 * (lo + hi); (rho_at(mid) < target_rho ? lo : hi) = mid; }
  return 0.5 * (lo + hi);
}
void C6_resolved_routes() {
  std::printf("\n===== C6 — resolved DYADIC vs CONFORMAL graded column =====\n");
  const int vpc = env_int("TOPOPT_GCS_C6_VPC", 12);
  const int nl = env_int("TOPOPT_GCS_C6_NL", 2);
  const double S0 = env_dbl("TOPOPT_GCS_C6_CELL", 4.0);     // base lateral cell (mm)
  const double rho_hi = env_dbl("TOPOPT_GCS_C6_RHOHI", 0.60);
  const double rho_lo = env_dbl("TOPOPT_GCS_C6_RHOLO", 0.05);
  const int nsteps = env_int("TOPOPT_GCS_C6_NSTEPS", 8);     // z-cells (conformal); dyadic derived
  std::printf("  base lateral cell S0=%.1f mm, %dx%d lateral, vpc=%d. density grade %.2f (bottom) -> %.2f (top).\n",
              S0, nl, nl, vpc, rho_hi, rho_lo);
  auto segs = octet_struts();

  // DYADIC schedule: 3 bands by density, cell height = S0/2S0/4S0. Height per band
  // chosen so all three routes span a comparable total height. Density set at each
  // cell's centre from a linear rho(z) after the fact (report achieved).
  auto make_dyadic = [&]() {
    std::vector<CellPlan> cells; double z = 0;
    // 3 cells at S0 (high rho), 2 at 2S0 (mid), 1 at 4S0 (low) -> spans S0*(3+4+4)=11 S0
    struct Band { int n; double hgt; };
    std::vector<Band> bands = {{3, S0}, {2, 2 * S0}, {1, 4 * S0}};
    double Htot = 0; for (auto& b : bands) Htot += b.n * b.hgt;
    for (auto& b : bands)
      for (int i = 0; i < b.n; ++i) {
        double zc = z + 0.5 * b.hgt;
        double rho = rho_hi + (rho_lo - rho_hi) * (zc / Htot);
        double r = calibrate_cell_r(S0, b.hgt, rho, vpc);
        cells.push_back({z, z + b.hgt, b.hgt, rho, r, 2 * r});
        z += b.hgt;
      }
    return cells;
  };
  // CONFORMAL schedule: nsteps cells whose height grows smoothly so total height ==
  // dyadic total; density linear in z. Height_i chosen geometric so the last cell is
  // ~4x the first (matching the dyadic S0->4S0 span) but continuous.
  auto make_conformal = [&](double Htot) {
    std::vector<CellPlan> cells; double growth = std::pow(4.0, 1.0 / (nsteps - 1));
    double hsum = 0; std::vector<double> hs;
    for (int i = 0; i < nsteps; ++i) { double hi = std::pow(growth, i); hs.push_back(hi); hsum += hi; }
    double scale = Htot / hsum, z = 0;
    for (int i = 0; i < nsteps; ++i) {
      double hgt = hs[i] * scale, zc = z + 0.5 * hgt;
      double rho = rho_hi + (rho_lo - rho_hi) * (zc / Htot);
      double r = calibrate_cell_r(S0, hgt, rho, vpc);
      cells.push_back({z, z + hgt, hgt, rho, r, 2 * r});
      z += hgt;
    }
    return cells;
  };

  std::vector<CellPlan> dy = make_dyadic();
  double Htot = 0; for (auto& c : dy) Htot += c.height;
  std::vector<CellPlan> co = make_conformal(Htot);

  FILE* lcsv = csv_open("c6_layers.csv");
  if (lcsv) std::fprintf(lcsv, "route,cell_idx,z0,z1,height_mm,rho,strut_diam_mm,printable\n");
  auto dump_layers = [&](const char* route, const std::vector<CellPlan>& cs) {
    std::printf("  %s route: %zu cells, total H=%.1f mm\n", route, cs.size(), Htot);
    std::printf("    %-4s %-8s %-9s %-9s %-11s %-10s\n", "i", "z_mid", "height", "rho", "strut_d_mm", "printable");
    for (std::size_t i = 0; i < cs.size(); ++i) {
      const auto& c = cs[i];
      const char* pr = c.diam < 0.4 ? "NO(<0.4)" : (c.diam < 0.8 ? "marginal" : "yes");
      std::printf("    %-4zu %-8.2f %-9.3f %-9.4f %-11.4f %-10s\n", i, 0.5 * (c.z0 + c.z1), c.height, c.rho, c.diam, pr);
      if (lcsv) std::fprintf(lcsv, "%s,%zu,%.3f,%.3f,%.4f,%.4f,%.4f,%s\n", route, i, c.z0, c.z1, c.height, c.rho, c.diam, pr);
    }
  };
  dump_layers("DYADIC", dy);
  dump_layers("CONFORMAL", co);
  if (lcsv) std::fclose(lcsv);

  double Hd = 0, Hc = 0;
  VoxelGrid gd = build_column(S0, nl, vpc, dy, &Hd);
  VoxelGrid gc = build_column(S0, nl, vpc, co, &Hc);
  FeaSolution sd, sc; double msd = 0, msc = 0; long ndd = 0, ndc = 0;
  double Ed = confined_Ez(gd, &sd, &msd, &ndd);
  double Ec = confined_Ez(gc, &sc, &msc, &ndc);
  std::printf("\n  route      E_confined_MPa   peak/mean vM (whole)   SCF at worst transition   DOF    ms\n");
  // dyadic transition planes are the band boundaries; conformal has none sharp.
  double ff_d = 0, ff_c = 0;
  // Worst-transition SCF: for dyadic scan the two band interfaces; for conformal scan all cell interfaces.
  auto worst_scf = [&](const VoxelGrid& g, const FeaSolution& s, const std::vector<CellPlan>& cs, double* ffout) {
    double worst = 0, ff = 0;
    for (std::size_t i = 1; i < cs.size(); ++i) {
      double zc = cs[i].z0;
      double band = std::min(cs[i - 1].height, cs[i].height) * 0.5;
      double f = 0; double s2 = band_scf(g, s, zc, band, &f);
      if (s2 > worst) worst = s2; ff = f;
    }
    if (ffout) *ffout = ff;
    return worst;
  };
  double scf_d = worst_scf(gd, sd, dy, &ff_d);
  double scf_c = worst_scf(gc, sc, co, &ff_c);
  std::printf("  DYADIC     %-16.2f %-22s %-25.3f %-6ld %.0f\n", Ed, "-", scf_d, ndd, msd);
  std::printf("  CONFORMAL  %-16.2f %-22s %-25.3f %-6ld %.0f\n", Ec, "-", scf_c, ndc, msc);
  double dmin_d = 1e9, dmin_c = 1e9;
  for (auto& c : dy) dmin_d = std::min(dmin_d, c.diam);
  for (auto& c : co) dmin_c = std::min(dmin_c, c.diam);
  FILE* csv = csv_open("c6_summary.csv");
  if (csv) {
    std::fprintf(csv, "route,E_confined_MPa,worst_transition_scf,min_strut_diam_mm,total_H_mm,dof,ms\n");
    std::fprintf(csv, "dyadic,%.4f,%.4f,%.4f,%.2f,%ld,%.0f\n", Ed, scf_d, dmin_d, Hd, ndd, msd);
    std::fprintf(csv, "conformal,%.4f,%.4f,%.4f,%.2f,%ld,%.0f\n", Ec, scf_c, dmin_c, Hc, ndc, msc);
    std::fclose(csv);
  }
  std::printf("  min strut diameter: dyadic %.3f mm, conformal %.3f mm (0.4mm nozzle floor).\n", dmin_d, dmin_c);
  std::printf("  READ: same density grade, same height. Compare E (stiffness), worst-transition SCF\n"
              "  (dyadic's factor-2 jumps vs conformal's smooth growth), and where strut d drops below\n"
              "  printable. The route to ship is the one with lower SCF and printable struts throughout.\n");
}

}  // namespace

int main() {
  std::setvbuf(stdout, nullptr, _IONBF, 0);
  std::printf("GRADED CELL SIZE PROBE — E_solid=%.0f MPa nu=%.2f, octet.\n", kE, kNu);
  std::printf("cores: matfree=6. library max resolved rho=%.3f, min=%.3f.\n",
              lattice_rho_max(LatticeTopology::Octet), lattice_rho_min(LatticeTopology::Octet));
  fea_set_matfree_threads(6);
  const char* only = std::getenv("TOPOPT_GCS_ONLY");
  auto want = [&](const char* s) { return !only || std::string(only) == s; };
  if (want("self")) SELF_checks();
  if (want("c1")) C1_scale_invariance();
  if (want("c2")) C2_cells_per_member();
  if (want("c2b")) C2b_bending();
  if (want("c2c")) C2c_fractional_bending();
  if (want("c3")) C3_width_cross();
  if (want("b3")) B3_printability();
  if (want("c4")) C4_dyadic();
  if (want("c5")) C5_conformal_warp();
  if (want("c6")) C6_resolved_routes();
  std::printf("\nDONE.\n");
  return 0;
}
