// lattice_dehomog_probe.cpp — DE-HOMOGENIZATION PROBE (handoff
// 2026-07-31-lattice-dehomogenization-probe): does macro stress predict strut
// stress?
//
// THE GAP. The lattice certification gate certifies STIFFNESS via the
// homogenized cubic tensor; every receipt carries strength_uncertified=1
// because the macro stress at a voxel is the CELL-AVERAGE while failure
// happens in a single strut at a stress concentration (PR 247 estimated the
// underprediction at ~25-44x on joint peaks but did not measure a usable law).
// This probe measures K(rho, state) = peak_strut_vm / macro_vm on a
// full-fidelity strut-resolved FEA of octet blocks under prescribed macro
// strain states, asks whether K is a usable function or scatter, separates
// interior from boundary/cut-strut populations, and applies the measured law
// to PR 255's certified multiscale designs.
//
// NOT production, NOT armed. The production library is linked UNMODIFIED.
// Geometry is the library's own basis: the LEGS-ONLY octet strut set
// (fc<->corner, exactly PR 198's octet_struts and the field inside the
// production octet_relative_density), voxelized cylinders. Strut radii are
// calibrated through the PRODUCTION octet_relative_density (vpc48 basis) so
// every K row keys on the same rho scale the tensor library rows carry.
//
// METHOD. Micro stress is LINEAR in the applied macro strain, so each fixture
// is solved once per unit Voigt strain column (6 solves) and EVERY macro
// strain state is then a superposition — including an EXACT worst case over
// all deviatoric states via a per-voxel 5x5 generalized eigenproblem
// (peak_vm^2 and macro_vm^2 are both quadratic forms in the strain vector).
// Cubic symmetry splits strain space into deviatoric (+) hydrostatic
// eigenspaces and pointwise von Mises is subadditive, so
//     peak_vm(any state) <= K_dev(rho) * vm(Sigma) + K_vol(rho) * |p(Sigma)|
// is a RIGOROUS bound within the model once K_dev is the exact deviatoric
// worst case and K_vol the hydrostatic ratio. The hydrostatic term is the
// proof that a scalar macro von Mises measure alone CANNOT certify strength:
// vm(Sigma_hydro) = 0 while the struts still load.
//
// FIXTURES.
//   periodic  1 cell, periodic BCs (Eigen; PR 198 formulation): the BULK law,
//             the N->inf limit of interior cells.
//   kubc      NxNxN cells, u = eps*x prescribed on ALL block faces
//             (production fea_solve_cg, nonzero Dirichlet): convergence of the
//             interior-cell peak toward the periodic value with N (J1).
//   sandwich  NxNxN cells, u = eps*x on the two x faces only, four lateral
//             faces FREE: the free-surface strut population (J4).
//   cut       sandwich with the top cell layer CUT at a generic fraction of
//             the cell (0.6): the cut-strut population PR 250/253 clipping
//             makes real and common (J4).
//
// Build (repo root; library first: cmake --build core/build --target topopt):
//   c++ -std=c++17 -O2 -I core/include -I /opt/homebrew/include/eigen3 \
//       core/tests/harness/lattice_dehomog_probe.cpp core/build/libtopopt.a \
//       -o core/build/lattice_dehomog_probe
//   ./core/build/lattice_dehomog_probe all <evidence-dir>
// Phases: selfcheck | bulk | blocks | boundary | fit | j6 | all
// (fit reads the CSVs bulk/boundary wrote; j6 reads kfit.csv + PR 255's
// p2_field_*.csv — pass the PR 255 evidence dir as the 3rd argument).
//
// DETERMINISM: no threads (fea_set_matfree_threads(1); Eigen CG and the
// assembled Jacobi-CG are sequential), no RNG except a fixed-seed integer LCG
// for the sampled strain states. Byte-identical rerun is bar J8.

#include <Eigen/Dense>
#include <Eigen/IterativeLinearSolvers>
#include <Eigen/SparseCore>

#include <algorithm>
#include <array>
#include <chrono>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <map>
#include <string>
#include <vector>

#include "topopt/analyze.hpp"
#include "topopt/fea.hpp"
#include "topopt/lattice.hpp"
#include "topopt/materials.hpp"
#include "topopt/simp.hpp"
#include "topopt/voxel.hpp"

using namespace topopt;

namespace {

constexpr double kEs = 3500.0;  // PLA solid modulus (materials.json), MPa
constexpr double kNu = 0.33;    // PLA Poisson
constexpr double kYield = 55.0; // PLA yield (the gap probe's pla_material)
constexpr double kZKnock = 0.55;  // PLA z_knockdown (ratio-only in J7; see caveat)

// ---------------------------------------------------------------------------
// Octet geometry — verbatim the PR 198 legs-only strut set (the geometry the
// production tensor library and octet_relative_density are keyed on).
// ---------------------------------------------------------------------------
double point_seg_dist2(double px, double py, double pz, const double a[3],
                       const double b[3]) {
  double ab[3] = {b[0] - a[0], b[1] - a[1], b[2] - a[2]};
  double ap[3] = {px - a[0], py - a[1], pz - a[2]};
  double denom = ab[0] * ab[0] + ab[1] * ab[1] + ab[2] * ab[2];
  double t = denom > 0 ? (ap[0] * ab[0] + ap[1] * ab[1] + ap[2] * ab[2]) / denom : 0;
  t = std::max(0.0, std::min(1.0, t));
  double c[3] = {a[0] + t * ab[0], a[1] + t * ab[1], a[2] + t * ab[2]};
  double d[3] = {px - c[0], py - c[1], pz - c[2]};
  return d[0] * d[0] + d[1] * d[1] + d[2] * d[2];
}
std::vector<std::array<std::array<double, 3>, 2>> octet_struts() {
  std::vector<std::array<double, 3>> nodes;
  for (int z = 0; z <= 1; ++z)
    for (int y = 0; y <= 1; ++y)
      for (int x = 0; x <= 1; ++x) nodes.push_back({double(x), double(y), double(z)});
  const std::array<std::array<double, 3>, 6> fc = {{{0.5, 0.5, 0.0},
                                                    {0.5, 0.5, 1.0},
                                                    {0.5, 0.0, 0.5},
                                                    {0.5, 1.0, 0.5},
                                                    {0.0, 0.5, 0.5},
                                                    {1.0, 0.5, 0.5}}};
  for (auto& f : fc) nodes.push_back(f);
  std::vector<std::array<std::array<double, 3>, 2>> segs;
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
// Distance^2 to the strut set of the PERIODIC tiling, unit cell coordinates.
double octet_dist2_unit(double u, double v, double w,
                        const std::vector<std::array<std::array<double, 3>, 2>>& segs) {
  u -= std::floor(u); v -= std::floor(v); w -= std::floor(w);
  double best = 1e30;
  for (auto& s : segs) {
    double d2 = point_seg_dist2(u, v, w, s[0].data(), s[1].data());
    if (d2 < best) best = d2;
  }
  return best;
}

// The block grid: ncx x ncy x ncz cells, vpc voxels per cell edge; nz_vox may
// CUT the top cell layer (cut fixture). Cell edge = 1 mm (K is scale-free; the
// tensor is scale-invariant, PR 235).
VoxelGrid build_block(double r_unit, int ncx, int ncy, int vpc, int nz_vox,
                      const std::vector<std::array<std::array<double, 3>, 2>>& segs) {
  VoxelGrid g;
  g.nx = ncx * vpc;
  g.ny = ncy * vpc;
  g.nz = nz_vox;
  g.spacing = 1.0 / vpc;
  g.origin = Vec3{0, 0, 0};
  g.tags.assign((std::size_t)g.nx * g.ny * g.nz, VoxelTag::Empty);
  const double r2 = r_unit * r_unit;
  for (int k = 0; k < g.nz; ++k)
    for (int j = 0; j < g.ny; ++j)
      for (int i = 0; i < g.nx; ++i) {
        const double x = (i + 0.5) / vpc, y = (j + 0.5) / vpc, z = (k + 0.5) / vpc;
        if (octet_dist2_unit(x, y, z, segs) < r2)
          g.set_tag(i, j, k, VoxelTag::Interior);
      }
  return g;
}

// Median solid-run length along x (voxels per strut crossing) — the resolution
// indicator PR 198 used (rows under ~4 voxels/wall are under-resolved).
double median_wall_voxels(const VoxelGrid& g) {
  std::vector<int> runs;
  for (int k = 0; k < g.nz; ++k)
    for (int j = 0; j < g.ny; ++j) {
      int run = 0;
      for (int i = 0; i < g.nx; ++i) {
        if (g.solid(i, j, k)) ++run;
        else if (run > 0) { runs.push_back(run); run = 0; }
      }
      if (run > 0 && run < g.nx) runs.push_back(run);
    }
  if (runs.empty()) return 0;
  std::sort(runs.begin(), runs.end());
  return runs[runs.size() / 2];
}

// Calibrate the unit-cell strut radius so the PRODUCTION mapping
// octet_relative_density (vpc48 basis — the scale the tensor library rows and
// every certified job key on) lands on `target_rho`. Bisection, deterministic.
double calibrate_r_unit(double target_rho) {
  double lo = 1e-4, hi = 0.35;
  for (int it = 0; it < 48; ++it) {
    const double mid = 0.5 * (lo + hi);
    (octet_relative_density(1.0, mid) < target_rho ? lo : hi) = mid;
  }
  return 0.5 * (lo + hi);
}

// ---------------------------------------------------------------------------
// Voigt algebra. Order [xx,yy,zz,xy,yz,zx]; strain vectors carry ENGINEERING
// shear, stress vectors TRUE shear (the production hex8 conventions).
// ---------------------------------------------------------------------------
using M6 = Eigen::Matrix<double, 6, 6>;
using V6 = Eigen::Matrix<double, 6, 1>;
using M65 = Eigen::Matrix<double, 6, 5>;
using M5 = Eigen::Matrix<double, 5, 5>;
using V5 = Eigen::Matrix<double, 5, 1>;

// The von Mises quadratic form on TRUE-shear stress Voigt: vm^2 = s^T V s.
M6 vm_form() {
  M6 V = M6::Zero();
  for (int i = 0; i < 3; ++i)
    for (int j = 0; j < 3; ++j) V(i, j) = (i == j) ? 1.0 : -0.5;
  for (int i = 3; i < 6; ++i) V(i, i) = 3.0;
  return V;
}
double von_mises_of(const V6& s) {
  const double a = s(0) - s(1), b = s(1) - s(2), c = s(2) - s(0);
  return std::sqrt(std::max(0.0, 0.5 * (a * a + b * b + c * c) +
                                     3.0 * (s(3) * s(3) + s(4) * s(4) + s(5) * s(5))));
}
double pressure_of(const V6& s) { return (s(0) + s(1) + s(2)) / 3.0; }
// n.sigma.n for TRUE-shear stress Voigt.
double normal_traction(const V6& s, const double n[3]) {
  return s(0) * n[0] * n[0] + s(1) * n[1] * n[1] + s(2) * n[2] * n[2] +
         2 * s(3) * n[0] * n[1] + 2 * s(4) * n[1] * n[2] + 2 * s(5) * n[2] * n[0];
}

// Cubic 6x6 stiffness (engineering-shear strain -> true-shear stress).
M6 cubic_D(const CubicTensor& t) {
  M6 D = M6::Zero();
  for (int i = 0; i < 3; ++i)
    for (int j = 0; j < 3; ++j) D(i, j) = (i == j) ? t.C11 : t.C12;
  for (int i = 3; i < 6; ++i) D(i, i) = t.C44;
  return D;
}

// Basis of the 5D deviatoric strain subspace (traceless normals + shears).
M65 dev_basis() {
  M65 P = M65::Zero();
  const double s2 = 1.0 / std::sqrt(2.0), s6 = 1.0 / std::sqrt(6.0);
  P(0, 0) = s2;  P(1, 0) = -s2;
  P(0, 1) = s6;  P(1, 1) = s6;  P(2, 1) = -2.0 * s6;
  P(3, 2) = 1.0; P(4, 3) = 1.0; P(5, 4) = 1.0;
  return P;
}

// ---------------------------------------------------------------------------
// Macro strain states. K is homogeneous of degree 0, so magnitudes are free.
// ---------------------------------------------------------------------------
struct NamedState { const char* name; double e[6]; };
const std::vector<NamedState>& named_states() {
  static const std::vector<NamedState> s = {
      {"uni_x",      {1, 0, 0, 0, 0, 0}},
      {"uni_z",      {0, 0, 1, 0, 0, 0}},   // cubic-symmetry instrument check
      {"biax_xy",    {1, 1, 0, 0, 0, 0}},
      {"shear_xy",   {0, 0, 0, 1, 0, 0}},
      {"shear_diag", {1, -1, 0, 0, 0, 0}},  // 45deg-rotated shear (C' mode)
      {"uni_111",    {1.0 / 3, 1.0 / 3, 1.0 / 3, 2.0 / 3, 2.0 / 3, 2.0 / 3}},
      {"hydro",      {1, 1, 1, 0, 0, 0}},   // macro vm == 0: the vm-blind state
  };
  return s;
}

// Fixed-seed LCG for the sampled deviatoric states (deterministic).
struct Lcg {
  unsigned long long x = 0x9e3779b97f4a7c15ULL;
  double next() {  // uniform [-1, 1)
    x = x * 6364136223846793005ULL + 1442695040888963407ULL;
    return 2.0 * ((double)(x >> 11) * (1.0 / 9007199254740992.0)) - 1.0;
  }
};
// `count` deviatoric strain states normalized to unit macro vm (e^T Q e = 1).
std::vector<V6> sampled_dev_states(const M6& Q, int count) {
  Lcg rng;
  std::vector<V6> out;
  while ((int)out.size() < count) {
    V6 e;
    for (int i = 0; i < 6; ++i) e(i) = rng.next();
    const double tr = (e(0) + e(1) + e(2)) / 3.0;
    for (int i = 0; i < 3; ++i) e(i) -= tr;
    const double q = e.dot(Q * e);
    if (q < 1e-9) continue;
    out.push_back(e / std::sqrt(q));
  }
  return out;
}

// ---------------------------------------------------------------------------
// A solved fixture: geometry + the per-solid-voxel stress of the 6 unit-strain
// basis solves (S[v] column J = centroid Voigt stress under unit strain J).
// ---------------------------------------------------------------------------
enum class Pop { Interior, Grip, Free, Cut };
const char* pop_name(Pop p) {
  switch (p) {
    case Pop::Interior: return "interior";
    case Pop::Grip: return "grip";
    case Pop::Free: return "free_surface";
    case Pop::Cut: return "cut_layer";
  }
  return "?";
}

struct Fixture {
  VoxelGrid grid;
  int vpc = 0, ncx = 0, ncy = 0, ncz_whole = 0;  // whole-cell count per axis
  bool has_cut = false;                          // top partial layer present
  std::vector<std::size_t> vox;                  // linear ids of solid voxels
  std::vector<Pop> pop;                          // per solid voxel
  std::vector<Eigen::Matrix<double, 6, 6>> S;    // per solid voxel stress basis
  double rho_meas = 0.0, wall_vox = 0.0;
  int iters[6] = {0, 0, 0, 0, 0, 0};
  double resid[6] = {0, 0, 0, 0, 0, 0};
  bool ok = true;
  std::size_t dropped_floaters = 0;
};

// Classify a solid voxel of a FINITE block into a population. `kubc`: every
// face is prescribed => face-adjacent cells are Grip. Sandwich: x faces are
// grips, lateral faces Free; the top PARTIAL cell layer (cut fixture) is Cut.
Pop classify(const Fixture& f, int i, int j, int k, bool kubc) {
  const int ci = i / f.vpc, cj = j / f.vpc, ck = k / f.vpc;
  if (f.has_cut && ck >= f.ncz_whole) return Pop::Cut;
  const int nck = f.has_cut ? f.ncz_whole + 1 : f.ncz_whole;
  const bool xface = ci == 0 || ci == f.ncx - 1;
  const bool lateral = cj == 0 || cj == f.ncy - 1 || ck == 0 || ck == nck - 1;
  if (kubc) return (xface || lateral) ? Pop::Grip : Pop::Interior;
  if (xface) return Pop::Grip;
  if (lateral) return Pop::Free;
  return Pop::Interior;
}

// Drop solid voxels not 6-connected to any voxel owning a prescribed node
// (voxelization noise at a cut can orphan fragments; a floater is singular
// under CG). Returns the number dropped.
std::size_t drop_floaters(VoxelGrid& g, const std::vector<char>& seed_vox) {
  const std::size_t n = g.voxel_count();
  std::vector<char> seen(n, 0);
  std::vector<std::size_t> stack;
  for (std::size_t v = 0; v < n; ++v)
    if (seed_vox[v] && !seen[v]) { seen[v] = 1; stack.push_back(v); }
  const int di[6] = {1, -1, 0, 0, 0, 0}, dj[6] = {0, 0, 1, -1, 0, 0},
            dk[6] = {0, 0, 0, 0, 1, -1};
  while (!stack.empty()) {
    const std::size_t v = stack.back();
    stack.pop_back();
    const int k = (int)(v / ((std::size_t)g.nx * g.ny));
    const int j = (int)((v / g.nx) % g.ny);
    const int i = (int)(v % g.nx);
    for (int d = 0; d < 6; ++d) {
      const int ni = i + di[d], nj = j + dj[d], nk = k + dk[d];
      if (ni < 0 || nj < 0 || nk < 0 || ni >= g.nx || nj >= g.ny || nk >= g.nz)
        continue;
      const std::size_t u = g.index(ni, nj, nk);
      if (!seen[u] && g.solid(ni, nj, nk)) { seen[u] = 1; stack.push_back(u); }
    }
  }
  std::size_t dropped = 0;
  for (int k = 0; k < g.nz; ++k)
    for (int j = 0; j < g.ny; ++j)
      for (int i = 0; i < g.nx; ++i)
        if (g.solid(i, j, k) && !seen[g.index(i, j, k)]) {
          g.set_tag(i, j, k, VoxelTag::Empty);
          ++dropped;
        }
  return dropped;
}

// Solve one FINITE fixture with the PRODUCTION solver: for each of the 6 unit
// Voigt strains, prescribe u = eps*x on the boundary node set (all faces for
// kubc, the two x faces for sandwich/cut), Jacobi-CG, recover per-solid-voxel
// centroid stress with the PRODUCTION hex8_stress.
Fixture solve_finite(double r_unit, int N, int vpc, bool kubc, double cut_frac,
                     double cg_tol, int cg_cap) {
  const auto segs = octet_struts();
  Fixture f;
  f.vpc = vpc; f.ncx = N; f.ncy = N; f.ncz_whole = N;
  int nz_vox = N * vpc;
  if (cut_frac > 0.0) {
    f.has_cut = true;
    f.ncz_whole = N;  // N whole layers + one partial layer on top
    nz_vox = (int)std::lround((N + cut_frac) * vpc);
  }
  f.grid = build_block(r_unit, N, N, vpc, nz_vox, segs);
  VoxelGrid& g = f.grid;

  // Prescribed node set: solid nodes on the prescribed faces.
  const int nnx = g.nx + 1, nny = g.ny + 1, nnz = g.nz + 1;
  std::vector<char> issolid((std::size_t)fea_node_count(g), 0);
  for (int k = 0; k < g.nz; ++k)
    for (int j = 0; j < g.ny; ++j)
      for (int i = 0; i < g.nx; ++i)
        if (g.solid(i, j, k))
          for (int n : fea_element_nodes(g, i, j, k)) issolid[(std::size_t)n] = 1;
  auto on_prescribed_face = [&](int a, int b, int c) {
    if (a == 0 || a == g.nx) return true;
    if (!kubc) return false;
    return b == 0 || b == g.ny || c == 0 || c == g.nz;
  };
  // Voxels owning a prescribed node seed the connectivity flood fill.
  std::vector<char> seed(g.voxel_count(), 0);
  for (int k = 0; k < g.nz; ++k)
    for (int j = 0; j < g.ny; ++j)
      for (int i = 0; i < g.nx; ++i) {
        if (!g.solid(i, j, k)) continue;
        const int corn[8][3] = {{i, j, k},         {i + 1, j, k},
                                {i + 1, j + 1, k}, {i, j + 1, k},
                                {i, j, k + 1},     {i + 1, j, k + 1},
                                {i + 1, j + 1, k + 1}, {i, j + 1, k + 1}};
        for (auto& c : corn)
          if (on_prescribed_face(c[0], c[1], c[2])) { seed[g.index(i, j, k)] = 1; break; }
      }
  f.dropped_floaters = drop_floaters(g, seed);
  // Rebuild the solid-node set after the drop.
  std::fill(issolid.begin(), issolid.end(), 0);
  for (int k = 0; k < g.nz; ++k)
    for (int j = 0; j < g.ny; ++j)
      for (int i = 0; i < g.nx; ++i)
        if (g.solid(i, j, k))
          for (int n : fea_element_nodes(g, i, j, k)) issolid[(std::size_t)n] = 1;

  f.rho_meas = (double)g.solid_count() / (double)g.voxel_count();
  f.wall_vox = median_wall_voxels(g);

  // Solid voxel roster + populations.
  for (int k = 0; k < g.nz; ++k)
    for (int j = 0; j < g.ny; ++j)
      for (int i = 0; i < g.nx; ++i)
        if (g.solid(i, j, k)) {
          f.vox.push_back(g.index(i, j, k));
          f.pop.push_back(classify(f, i, j, k, kubc));
        }
  f.S.assign(f.vox.size(), Eigen::Matrix<double, 6, 6>::Zero());

  const double h = g.spacing;
  for (int J = 0; J < 6; ++J) {
    // Unit macro strain J as a displacement field u_i = eps_ij x_j
    // (tensor shear = gamma/2 on the off-diagonals).
    double eps[3][3] = {{0, 0, 0}, {0, 0, 0}, {0, 0, 0}};
    if (J < 3) eps[J][J] = 1.0;
    else if (J == 3) eps[0][1] = eps[1][0] = 0.5;
    else if (J == 4) eps[1][2] = eps[2][1] = 0.5;
    else             eps[2][0] = eps[0][2] = 0.5;
    std::vector<DirichletBC> bcs;
    for (int c = 0; c < nnz; ++c)
      for (int b = 0; b < nny; ++b)
        for (int a = 0; a < nnx; ++a) {
          if (!on_prescribed_face(a, b, c)) continue;
          const int n = fea_node_index(g, a, b, c);
          if (!issolid[(std::size_t)n]) continue;
          const double x[3] = {a * h, b * h, c * h};
          for (int comp = 0; comp < 3; ++comp) {
            const double u =
                eps[comp][0] * x[0] + eps[comp][1] * x[1] + eps[comp][2] * x[2];
            bcs.push_back({n, comp, u});
          }
        }
    CgInfo info;
    FeaSolution sol;
    try {
      sol = fea_solve_cg(g, kEs, kNu, bcs, {}, cg_tol, cg_cap, &info);
    } catch (const std::exception& ex) {
      std::fprintf(stderr, "  [finite solve J=%d FAILED: %s]\n", J, ex.what());
      f.ok = false;
      return f;
    }
    f.iters[J] = info.iterations;
    f.resid[J] = info.residual;
    // Centroid stress per solid voxel via the PRODUCTION element.
    std::size_t vi = 0;
    for (int k = 0; k < g.nz; ++k)
      for (int j = 0; j < g.ny; ++j)
        for (int i = 0; i < g.nx; ++i) {
          if (!g.solid(i, j, k)) continue;
          const std::array<int, 8> en = fea_element_nodes(g, i, j, k);
          std::array<double, 24> ue{};
          for (int a = 0; a < 8; ++a)
            for (int c = 0; c < 3; ++c) ue[3 * a + c] = sol.u[3 * en[a] + c];
          const Hex8Stress st = hex8_stress(kEs, kNu, h, ue);
          for (int c = 0; c < 6; ++c) f.S[vi](c, J) = st.sigma[(std::size_t)c];
          ++vi;
        }
  }
  return f;
}

// ---------------------------------------------------------------------------
// PERIODIC single cell (Eigen; the PR 198 formulation, all 6 columns), stress
// recovered with the PRODUCTION hex8_stress from the corrector fields. Also
// returns the measured homogenized tensor.
// ---------------------------------------------------------------------------
constexpr int kOff[8][3] = {{0, 0, 0}, {1, 0, 0}, {1, 1, 0}, {0, 1, 0},
                            {0, 0, 1}, {1, 0, 1}, {1, 1, 1}, {0, 1, 1}};
std::array<std::array<double, 6>, 24> element_chi0(double h) {
  std::array<std::array<double, 6>, 24> chi0{};
  for (int a = 0; a < 8; ++a) {
    const double X = kOff[a][0] * h, Y = kOff[a][1] * h, Z = kOff[a][2] * h;
    chi0[3 * a][0] = X;
    chi0[3 * a + 1][1] = Y;
    chi0[3 * a + 2][2] = Z;
    chi0[3 * a][3] = Y;
    chi0[3 * a + 1][4] = Z;
    chi0[3 * a + 2][5] = X;
  }
  return chi0;
}

struct Periodic {
  Fixture fx;      // pop all Interior; S filled from correctors
  M6 CH = M6::Zero();
  bool ok = true;
};

Periodic solve_periodic(double r_unit, int vpc, double cg_tol) {
  const auto segs = octet_struts();
  Periodic P;
  Fixture& f = P.fx;
  f.vpc = vpc; f.ncx = f.ncy = f.ncz_whole = 1;
  f.grid = build_block(r_unit, 1, 1, vpc, vpc, segs);
  VoxelGrid& g = f.grid;
  f.rho_meas = (double)g.solid_count() / (double)g.voxel_count();
  f.wall_vox = median_wall_voxels(g);

  const int nx = g.nx, ny = g.ny, nz = g.nz;
  const double h = g.spacing;
  const long Np = (long)nx * ny * nz, nd = 3 * Np;
  const Hex8Stiffness Kel = hex8_stiffness(kEs, kNu, h);
  const auto chi0 = element_chi0(h);
  auto pid = [&](int a, int b, int c) -> long {
    return ((long)(c % nz) * ny + (b % ny)) * nx + (a % nx);
  };
  std::vector<Eigen::Triplet<double>> trips;
  trips.reserve((std::size_t)g.solid_count() * 576);
  Eigen::MatrixXd F = Eigen::MatrixXd::Zero(nd, 6);
  std::vector<char> touched((std::size_t)nd, 0);
  for (int k = 0; k < nz; ++k)
    for (int j = 0; j < ny; ++j)
      for (int i = 0; i < nx; ++i) {
        if (!g.solid(i, j, k)) continue;
        long gd[24];
        for (int a = 0; a < 8; ++a) {
          const long p = pid(i + kOff[a][0], j + kOff[a][1], k + kOff[a][2]);
          gd[3 * a] = 3 * p; gd[3 * a + 1] = 3 * p + 1; gd[3 * a + 2] = 3 * p + 2;
        }
        for (int r = 0; r < 24; ++r) {
          touched[gd[r]] = 1;
          for (int c = 0; c < 24; ++c)
            trips.emplace_back((int)gd[r], (int)gd[c], Kel.k[r * 24 + c]);
          for (int J = 0; J < 6; ++J) {
            double s = 0;
            for (int c = 0; c < 24; ++c) s += Kel.k[r * 24 + c] * chi0[c][J];
            F(gd[r], J) += s;
          }
        }
      }
  std::vector<char> pinned((std::size_t)nd, 0);
  pinned[0] = pinned[1] = pinned[2] = 1;
  for (long d = 0; d < nd; ++d)
    if (!touched[d]) pinned[d] = 1;
  Eigen::SparseMatrix<double> K((int)nd, (int)nd);
  K.setFromTriplets(trips.begin(), trips.end());
  trips.clear();
  trips.shrink_to_fit();
  for (int c = 0; c < K.outerSize(); ++c)
    for (Eigen::SparseMatrix<double>::InnerIterator it(K, c); it; ++it)
      if (pinned[it.row()] || pinned[it.col()])
        it.valueRef() = (it.row() == it.col()) ? 1.0 : 0.0;
  K.prune(0.0);
  for (long d = 0; d < nd; ++d)
    if (pinned[d]) for (int J = 0; J < 6; ++J) F(d, J) = 0.0;
  Eigen::ConjugateGradient<Eigen::SparseMatrix<double>, Eigen::Lower | Eigen::Upper> cg;
  cg.setTolerance(cg_tol);
  cg.setMaxIterations((int)std::min<long>(nd * 2, 400000));
  cg.compute(K);
  Eigen::MatrixXd X = Eigen::MatrixXd::Zero(nd, 6);
  for (int J = 0; J < 6; ++J) {
    X.col(J) = cg.solve(F.col(J));
    f.iters[J] = (int)cg.iterations();
    f.resid[J] = cg.error();
    if (cg.info() != Eigen::Success) P.ok = false;
  }

  // CH (average-stress form) + per-voxel basis stress from the correctors,
  // recovered with the PRODUCTION element stress.
  const double vol = (double)nx * ny * nz * h * h * h;
  for (int k = 0; k < nz; ++k)
    for (int j = 0; j < ny; ++j)
      for (int i = 0; i < nx; ++i) {
        if (!g.solid(i, j, k)) continue;
        f.vox.push_back(g.index(i, j, k));
        f.pop.push_back(Pop::Interior);
      }
  f.S.assign(f.vox.size(), Eigen::Matrix<double, 6, 6>::Zero());
  std::size_t vi = 0;
  for (int k = 0; k < nz; ++k)
    for (int j = 0; j < ny; ++j)
      for (int i = 0; i < nx; ++i) {
        if (!g.solid(i, j, k)) continue;
        long gd[24];
        for (int a = 0; a < 8; ++a) {
          const long p = pid(i + kOff[a][0], j + kOff[a][1], k + kOff[a][2]);
          gd[3 * a] = 3 * p; gd[3 * a + 1] = 3 * p + 1; gd[3 * a + 2] = 3 * p + 2;
        }
        for (int J = 0; J < 6; ++J) {
          std::array<double, 24> ue{};
          for (int r = 0; r < 24; ++r) ue[(std::size_t)r] = chi0[r][J] - X(gd[r], J);
          const Hex8Stress st = hex8_stress(kEs, kNu, h, ue);
          for (int c = 0; c < 6; ++c) f.S[vi](c, J) = st.sigma[(std::size_t)c];
          // CH column J += volume-averaged stress of this element.
          for (int c = 0; c < 6; ++c)
            P.CH(c, J) += st.sigma[(std::size_t)c] * (h * h * h) / vol;
        }
        ++vi;
      }
  return P;
}

// ---------------------------------------------------------------------------
// Evaluation: peaks / quantiles / exact worst cases per population.
// ---------------------------------------------------------------------------
struct StateEval {
  double peak_vm = 0.0, p99_vm = 0.0, p999_vm = 0.0;
  double peak_il_z = 0.0;  // max over voxels of max(z.sigma.z, 0)
  std::size_t n = 0;
};

StateEval eval_state(const Fixture& f, const V6& e, Pop pop, bool any_pop) {
  StateEval ev;
  static thread_local std::vector<double> vals;
  vals.clear();
  const double nz[3] = {0, 0, 1};
  for (std::size_t v = 0; v < f.vox.size(); ++v) {
    if (!any_pop && f.pop[v] != pop) continue;
    const V6 s = f.S[v] * e;
    const double vm = von_mises_of(s);
    vals.push_back(vm);
    if (vm > ev.peak_vm) ev.peak_vm = vm;
    const double il = normal_traction(s, nz);
    if (il > ev.peak_il_z) ev.peak_il_z = il;
  }
  ev.n = vals.size();
  if (!vals.empty()) {
    std::sort(vals.begin(), vals.end());
    ev.p99_vm = vals[(std::size_t)((double)(vals.size() - 1) * 0.99)];
    ev.p999_vm = vals[(std::size_t)((double)(vals.size() - 1) * 0.999)];
  }
  return ev;
}

// Exact worst case over ALL deviatoric strain states, normalized to unit
// macro vm: K_dev = max_x sqrt(lambda_max( (S_x P)^T V (S_x P),  (D P)^T V (D P) )).
// Also the exact interlayer worst case max_x max_e (z.sigma_x.z)/vm(Sigma).
struct ExactDev {
  double K_dev = 0.0;
  double K_il_dev = 0.0;
  std::size_t argmax_vox = 0;
};
ExactDev exact_dev(const Fixture& f, const M6& Dlib, Pop pop, bool any_pop) {
  const M6 V = vm_form();
  const M65 P = dev_basis();
  const M5 B = (Dlib * P).transpose() * V * (Dlib * P);
  const Eigen::LLT<M5> llt(B);
  ExactDev out;
  const V6 vn = (V6() << 0, 0, 1, 0, 0, 0).finished();  // z.sigma.z selector
  for (std::size_t v = 0; v < f.vox.size(); ++v) {
    if (!any_pop && f.pop[v] != pop) continue;
    const M65 W = f.S[v] * P;
    const M5 A = W.transpose() * V * W;
    // M = L^-1 A L^-T ; lambda_max(M) = worst (peak_vm/macro_vm)^2 here.
    M5 M = llt.matrixL().solve(A);
    M = llt.matrixL().solve(M.transpose()).transpose();
    const Eigen::SelfAdjointEigenSolver<M5> es(M, Eigen::EigenvaluesOnly);
    const double lam = es.eigenvalues().maxCoeff();
    if (lam > out.K_dev * out.K_dev) {
      out.K_dev = std::sqrt(std::max(0.0, lam));
      out.argmax_vox = v;
    }
    // interlayer: max_e g^T y / sqrt(y^T B y) = || L^-1 g ||, g = P^T S^T vn.
    const V5 gvec = W.transpose() * vn;
    const V5 gl = llt.matrixL().solve(gvec);
    const double kil = gl.norm();
    if (kil > out.K_il_dev) out.K_il_dev = kil;
  }
  return out;
}

// Hydrostatic ratios: peak vm (and interlayer) per unit macro |pressure|.
struct VolRatios { double K_vol = 0.0, K_il_vol = 0.0; };
VolRatios vol_ratios(const Fixture& f, const M6& Dlib, Pop pop, bool any_pop) {
  const V6 eh = (V6() << 1, 1, 1, 0, 0, 0).finished();
  const V6 Sig = Dlib * eh;
  const double p = std::fabs(pressure_of(Sig));
  VolRatios out;
  if (p <= 0) return out;
  const double nz[3] = {0, 0, 1};
  for (std::size_t v = 0; v < f.vox.size(); ++v) {
    if (!any_pop && f.pop[v] != pop) continue;
    const V6 s = f.S[v] * eh;
    out.K_vol = std::max(out.K_vol, von_mises_of(s) / p);
    out.K_il_vol = std::max(out.K_il_vol, std::fabs(normal_traction(s, nz)) / p);
  }
  return out;
}

// Sampled deviatoric-state statistics of K (peak over population per state).
struct SampStats { double kmin = 0, kmed = 0, kp95 = 0, kmax = 0; int n = 0; };
SampStats sampled_stats(const Fixture& f, const M6& Dlib, Pop pop, bool any_pop,
                        int count) {
  const M6 V = vm_form();
  const M6 Q = Dlib.transpose() * V * Dlib;
  const auto states = sampled_dev_states(Q, count);
  std::vector<double> ks;
  ks.reserve(states.size());
  for (const V6& e : states) {
    double peak = 0;
    for (std::size_t v = 0; v < f.vox.size(); ++v) {
      if (!any_pop && f.pop[v] != pop) continue;
      const double vm = von_mises_of(f.S[v] * e);
      if (vm > peak) peak = vm;
    }
    ks.push_back(peak);  // states are unit-macro-vm, so K == peak
  }
  std::sort(ks.begin(), ks.end());
  SampStats st;
  st.n = (int)ks.size();
  if (!ks.empty()) {
    st.kmin = ks.front();
    st.kmed = ks[ks.size() / 2];
    st.kp95 = ks[(std::size_t)((double)(ks.size() - 1) * 0.95)];
    st.kmax = ks.back();
  }
  return st;
}

// Per-cell records for the boundary fixtures (named states): each cell's own
// average macro stress vs its own peak — the local law a certification would
// apply (it knows each voxel's macro Sigma).
struct CellRec {
  int ci, cj, ck;
  Pop cls;
  std::size_t n_solid;
  double avg_vm, peak_vm, K_cell, K_far;
};
std::vector<CellRec> per_cell(const Fixture& f, const V6& e, double macro_vm_far,
                              bool kubc) {
  const int nck = f.has_cut ? f.ncz_whole + 1 : f.ncz_whole;
  const std::size_t ncells = (std::size_t)f.ncx * f.ncy * nck;
  std::vector<V6> sum(ncells, V6::Zero());
  std::vector<double> peak(ncells, 0.0);
  std::vector<std::size_t> cnt(ncells, 0);
  std::vector<std::size_t> envel(ncells, 0);
  // envelope voxel count per cell (whole cells: vpc^3; cut layer: fewer).
  const VoxelGrid& g = f.grid;
  for (int k = 0; k < g.nz; ++k)
    for (int j = 0; j < g.ny; ++j)
      for (int i = 0; i < g.nx; ++i) {
        const std::size_t c =
            ((std::size_t)(k / f.vpc) * f.ncy + (j / f.vpc)) * f.ncx + (i / f.vpc);
        ++envel[c];
      }
  for (std::size_t v = 0; v < f.vox.size(); ++v) {
    const std::size_t idx = f.vox[v];
    const int k = (int)(idx / ((std::size_t)g.nx * g.ny));
    const int j = (int)((idx / g.nx) % g.ny);
    const int i = (int)(idx % g.nx);
    const std::size_t c =
        ((std::size_t)(k / f.vpc) * f.ncy + (j / f.vpc)) * f.ncx + (i / f.vpc);
    const V6 s = f.S[v] * e;
    sum[c] += s;
    ++cnt[c];
    const double vm = von_mises_of(s);
    if (vm > peak[c]) peak[c] = vm;
  }
  std::vector<CellRec> out;
  for (int ck = 0; ck < nck; ++ck)
    for (int cj = 0; cj < f.ncy; ++cj)
      for (int ci = 0; ci < f.ncx; ++ci) {
        const std::size_t c = ((std::size_t)ck * f.ncy + cj) * f.ncx + ci;
        if (cnt[c] == 0) continue;
        CellRec r;
        r.ci = ci; r.cj = cj; r.ck = ck;
        // classify by the cell's first voxel semantics (same rule as voxels)
        Fixture tmp = {};  // classify() needs only the shape fields
        tmp.vpc = f.vpc; tmp.ncx = f.ncx; tmp.ncy = f.ncy;
        tmp.ncz_whole = f.ncz_whole; tmp.has_cut = f.has_cut;
        r.cls = classify(tmp, ci * f.vpc, cj * f.vpc, ck * f.vpc, kubc);
        r.n_solid = cnt[c];
        const V6 avg = sum[c] / (double)envel[c];  // envelope average = macro
        r.avg_vm = von_mises_of(avg);
        r.peak_vm = peak[c];
        r.K_cell = r.avg_vm > 1e-12 ? r.peak_vm / r.avg_vm : -1.0;
        r.K_far = macro_vm_far > 1e-12 ? r.peak_vm / macro_vm_far : -1.0;
        out.push_back(r);
      }
  return out;
}

// ---------------------------------------------------------------------------
// CSV plumbing.
// ---------------------------------------------------------------------------
FILE* open_csv(const std::string& dir, const char* name, const char* header) {
  const std::string p = dir + "/" + name;
  FILE* f = std::fopen(p.c_str(), "w");
  if (!f) { std::fprintf(stderr, "cannot open %s\n", p.c_str()); std::exit(1); }
  std::fprintf(f, "%s\n", header);
  return f;
}

// The rho sweep: band endpoints READ FROM CORE (never hardcoded) + interior
// targets spanning the certifiable band.
std::vector<double> rho_sweep() {
  const double lo = lattice_rho_min(LatticeTopology::Octet);
  const double hi = lattice_rho_max(LatticeTopology::Octet);
  return {lo, 0.10, 0.157, 0.20, 0.313, 0.45, 0.60, 0.75, hi};
}

struct RhoCal {
  double target, r_unit, rho_lib;
};
RhoCal calibrate(double target) {
  RhoCal c;
  c.target = target;
  c.r_unit = calibrate_r_unit(target);
  c.rho_lib = octet_relative_density(1.0, c.r_unit);
  return c;
}

M6 lib_D(double rho_lib) {
  return cubic_D(lattice_cubic_tensor(LatticeTopology::Octet, rho_lib, kEs));
}

// ---------------------------------------------------------------------------
// PHASE: selfcheck — the instrument must be exact where the answer is known.
// ---------------------------------------------------------------------------
int phase_selfcheck(const std::string& ev) {
  std::printf("\n===== SELFCHECK — instrument honesty =====\n");
  FILE* csv = open_csv(ev, "selfcheck.csv", "check,value,bar,pass");
  int fails = 0;
  auto report = [&](const char* name, double val, double bar, bool pass) {
    std::printf("  %-42s %.3e  (bar %.1e)  %s\n", name, val, bar,
                pass ? "PASS" : "FAIL");
    std::fprintf(csv, "%s,%.6e,%.1e,%d\n", name, val, bar, pass ? 1 : 0);
    if (!pass) ++fails;
  };

  // S1: SOLID block under KUBC: every basis state must give a uniform field
  // whose peak vm equals the macro vm of the isotropic tensor (K = 1). The
  // affine field is exact for the discrete system too, so the only residue is
  // the CG stopping tolerance — the bar is set at that level, not looser.
  {
    Fixture s = solve_finite(10.0 /*radius floods the cell solid*/, 2, 8,
                             /*kubc=*/true, 0.0, 1e-12, 40000);
    const double lam = kEs * kNu / ((1 + kNu) * (1 - 2 * kNu));
    const double mu = kEs / (2 * (1 + kNu));
    CubicTensor iso{lam + 2 * mu, lam, mu};
    const M6 Diso = cubic_D(iso);
    double worst = 0;
    for (const auto& ns : named_states()) {
      V6 e;
      for (int i = 0; i < 6; ++i) e(i) = ns.e[i];
      const double macro = von_mises_of(Diso * e);
      const StateEval evl = eval_state(s, e, Pop::Interior, /*any=*/true);
      const double ref = std::max(macro, 1e-12);
      worst = std::max(worst, std::fabs(evl.peak_vm - macro) / std::max(ref, 1.0));
    }
    report("S1 solid KUBC peak==macro (K=1)", worst, 1e-5, worst < 1e-5);
  }

  // S2: superposition — a combined state evaluated by superposition matches a
  // direct solve of the combined BCs on a real octet block.
  {
    const RhoCal c = calibrate(0.313);
    Fixture f = solve_finite(c.r_unit, 2, 8, true, 0.0, 1e-9, 40000);
    V6 e;
    e << 0.7, -0.2, 0.1, 0.4, -0.3, 0.25;
    // direct: prescribe the combined affine field
    const auto segs = octet_struts();
    Fixture d;  // manual combined solve using the same machinery: reuse
    // solve_finite by rotating basis? simpler: evaluate via basis on f, then
    // compare against a 1-state fixture built from a scaled single strain --
    // instead solve directly here:
    {
      VoxelGrid g = f.grid;  // includes floater drop
      const double h = g.spacing;
      const int nnx = g.nx + 1, nny = g.ny + 1, nnz = g.nz + 1;
      std::vector<char> issolid((std::size_t)fea_node_count(g), 0);
      for (int k = 0; k < g.nz; ++k)
        for (int j = 0; j < g.ny; ++j)
          for (int i = 0; i < g.nx; ++i)
            if (g.solid(i, j, k))
              for (int n : fea_element_nodes(g, i, j, k)) issolid[(std::size_t)n] = 1;
      double eps[3][3] = {{e(0), e(3) / 2, e(5) / 2},
                          {e(3) / 2, e(1), e(4) / 2},
                          {e(5) / 2, e(4) / 2, e(2)}};
      std::vector<DirichletBC> bcs;
      for (int cc = 0; cc < nnz; ++cc)
        for (int b = 0; b < nny; ++b)
          for (int a = 0; a < nnx; ++a) {
            if (!(a == 0 || a == g.nx || b == 0 || b == g.ny || cc == 0 || cc == g.nz))
              continue;
            const int n = fea_node_index(g, a, b, cc);
            if (!issolid[(std::size_t)n]) continue;
            const double x[3] = {a * h, b * h, cc * h};
            for (int comp = 0; comp < 3; ++comp)
              bcs.push_back({n, comp, eps[comp][0] * x[0] + eps[comp][1] * x[1] +
                                          eps[comp][2] * x[2]});
          }
      CgInfo info;
      const FeaSolution sol = fea_solve_cg(g, kEs, kNu, bcs, {}, 1e-9, 40000, &info);
      double peak = 0;
      for (int k = 0; k < g.nz; ++k)
        for (int j = 0; j < g.ny; ++j)
          for (int i = 0; i < g.nx; ++i) {
            if (!g.solid(i, j, k)) continue;
            const std::array<int, 8> en = fea_element_nodes(g, i, j, k);
            std::array<double, 24> ue{};
            for (int a = 0; a < 8; ++a)
              for (int comp = 0; comp < 3; ++comp)
                ue[3 * a + comp] = sol.u[3 * en[a] + comp];
            peak = std::max(peak, hex8_stress(kEs, kNu, h, ue).von_mises);
          }
      const StateEval evl = eval_state(f, e, Pop::Interior, /*any=*/true);
      report("S2 superposition == direct combined solve",
             std::fabs(evl.peak_vm - peak) / peak, 5e-4,
             std::fabs(evl.peak_vm - peak) / peak < 5e-4);
    }
    (void)d; (void)segs;
  }

  // S3: the calibrated radius reproduces the PRODUCTION rho mapping.
  {
    const RhoCal c = calibrate(0.313);
    report("S3 |rho_lib - target| via production mapping",
           std::fabs(c.rho_lib - 0.313), 5e-3, std::fabs(c.rho_lib - 0.313) < 5e-3);
  }

  // S4: periodic solid cell recovers the isotropic tensor (H1 of PR 198).
  {
    Periodic P = solve_periodic(10.0, 6, 1e-11);
    const double lam = kEs * kNu / ((1 + kNu) * (1 - 2 * kNu));
    const double mu = kEs / (2 * (1 + kNu));
    const double e11 = std::fabs(P.CH(0, 0) - (lam + 2 * mu)) / (lam + 2 * mu);
    const double e12 = std::fabs(P.CH(0, 1) - lam) / lam;
    const double e44 = std::fabs(P.CH(3, 3) - mu) / mu;
    const double worst = std::max({e11, e12, e44});
    report("S4 periodic solid tensor (4 digits)", worst, 1e-4, worst < 1e-4);
  }

  // S6: the LAW'S CORE INEQUALITY, empirically: for a real octet cell,
  // peak_vm(any mixed state) <= K_dev*vm(Sigma) + K_vol*|p(Sigma)| where
  // K_dev is the exact deviatoric worst case and K_vol the hydrostatic ratio.
  // (Provable by subadditivity + the cubic eigenspace split; verified anyway.)
  {
    const RhoCal c = calibrate(0.313);
    Periodic P = solve_periodic(c.r_unit, 10, 1e-10);
    const M6 Dlib = lib_D(c.rho_lib);
    const ExactDev ed = exact_dev(P.fx, Dlib, Pop::Interior, true);
    const VolRatios vr = vol_ratios(P.fx, Dlib, Pop::Interior, true);
    Lcg rng;
    double worst_violation = -1e30;
    for (int t = 0; t < 64; ++t) {
      V6 e;
      for (int i = 0; i < 6; ++i) e(i) = rng.next();
      const V6 Sig = Dlib * e;
      const double bound = ed.K_dev * von_mises_of(Sig) +
                           vr.K_vol * std::fabs(pressure_of(Sig));
      const StateEval evl = eval_state(P.fx, e, Pop::Interior, true);
      worst_violation =
          std::max(worst_violation, (evl.peak_vm - bound) / std::max(bound, 1e-12));
    }
    report("S6 bound holds on 64 mixed states", worst_violation, 1e-9,
           worst_violation < 1e-9);
  }

  // S5: the band endpoints come from core (printed for the record).
  {
    const double lo = lattice_rho_min(LatticeTopology::Octet);
    const double hi = lattice_rho_max(LatticeTopology::Octet);
    std::printf("  band read from core: [%.5f, %.5f]\n", lo, hi);
    std::fprintf(csv, "S5_band_lo,%.6f,,1\nS5_band_hi,%.6f,,1\n", lo, hi);
    report("S5 band sane (0<lo<hi<1)", (lo > 0 && lo < hi && hi < 1) ? 0 : 1, 0.5,
           lo > 0 && lo < hi && hi < 1);
  }

  std::fclose(csv);
  std::printf("  selfcheck: %s\n", fails == 0 ? "ALL PASS" : "FAILURES");
  return fails;
}

// ---------------------------------------------------------------------------
// PHASE: bulk — the periodic law K(rho, state) across the band (J2, J3, J5).
// ---------------------------------------------------------------------------
std::size_t pop_count(const Fixture& fx, Pop pop, bool any_pop) {
  std::size_t n = 0;
  for (std::size_t v = 0; v < fx.vox.size(); ++v)
    if (any_pop || fx.pop[v] == pop) ++n;
  return n;
}

void write_state_rows(FILE* f, const char* fixture, const RhoCal& c, int N,
                      int vpc, const Fixture& fx, const M6& Dlib, Pop pop,
                      bool any_pop, const char* popname) {
  if (pop_count(fx, pop, any_pop) == 0) return;  // empty population: no rows
  for (const auto& ns : named_states()) {
    V6 e;
    for (int i = 0; i < 6; ++i) e(i) = ns.e[i];
    const V6 Sig = Dlib * e;
    const double mvm = von_mises_of(Sig);
    const double mp = pressure_of(Sig);
    const double nzv[3] = {0, 0, 1};
    const double mil = normal_traction(Sig, nzv);
    const StateEval evl = eval_state(fx, e, pop, any_pop);
    const double K = mvm > 1e-12 ? evl.peak_vm / mvm : -1.0;
    const double K99 = mvm > 1e-12 ? evl.p99_vm / mvm : -1.0;
    const double Kil = mil > 1e-12 ? evl.peak_il_z / mil : -1.0;
    std::fprintf(f,
                 "%s,%.5f,%.6f,%.5f,%.5f,%d,%d,%s,%s,%zu,"
                 "%.5f,%.5f,%.5f,%.4f,%.4f,%.4f,%.3f,%.3f,%.4f,%.3f\n",
                 fixture, c.target, c.r_unit, c.rho_lib, fx.rho_meas, N, vpc,
                 popname, ns.name, evl.n, mvm, mp, mil, evl.peak_vm, evl.p99_vm,
                 evl.p999_vm, K, K99, evl.peak_il_z, Kil);
  }
}

const char* kStateHeader =
    "fixture,rho_target,r_unit,rho_lib,rho_meas,N,vpc,population,state,n_vox,"
    "macro_vm,macro_p,macro_il_z,peak_vm,p99_vm,p999_vm,K_peak,K_p99,"
    "peak_il_z,K_il";

const char* kExactHeader =
    "fixture,rho_target,rho_lib,rho_meas,N,vpc,population,n_vox,wall_vox,"
    "K_dev_max,K_vol,K_il_dev,K_il_vol,samp_min,samp_med,samp_p95,samp_max,"
    "n_samp,cg_iters_max,cg_resid_max,dropped_floaters";

void write_exact_row(FILE* f, const char* fixture, const RhoCal& c, int N,
                     int vpc, const Fixture& fx, const M6& Dlib, Pop pop,
                     bool any_pop, const char* popname, int nsamp) {
  if (pop_count(fx, pop, any_pop) == 0) return;  // empty population: no row
  const ExactDev ed = exact_dev(fx, Dlib, pop, any_pop);
  const VolRatios vr = vol_ratios(fx, Dlib, pop, any_pop);
  const SampStats st = sampled_stats(fx, Dlib, pop, any_pop, nsamp);
  std::size_t n = 0;
  for (std::size_t v = 0; v < fx.vox.size(); ++v)
    if (any_pop || fx.pop[v] == pop) ++n;
  int itmax = 0;
  double rmax = 0;
  for (int J = 0; J < 6; ++J) {
    itmax = std::max(itmax, fx.iters[J]);
    rmax = std::max(rmax, fx.resid[J]);
  }
  std::fprintf(f,
               "%s,%.5f,%.5f,%.5f,%d,%d,%s,%zu,%.1f,"
               "%.4f,%.4f,%.4f,%.4f,%.3f,%.3f,%.3f,%.3f,%d,%d,%.2e,%zu\n",
               fixture, c.target, c.rho_lib, fx.rho_meas, N, vpc, popname, n,
               fx.wall_vox, ed.K_dev, vr.K_vol, ed.K_il_dev, vr.K_il_vol,
               st.kmin, st.kmed, st.kp95, st.kmax, st.n, itmax, rmax,
               fx.dropped_floaters);
}

void phase_bulk(const std::string& ev, bool fast) {
  std::printf("\n===== BULK LAW — periodic cell, band sweep (J2/J3/J5) =====\n");
  std::printf(
      "EXPECTATION STATED BEFORE MEASURING (J2): PR 247 measured the uniaxial\n"
      "strut/macro concentration at ~25x (rho 0.31) and ~44x (rho 0.20) on\n"
      "voxelized joint peaks at vpc32. If K ~ A/rho that implies A ~ 8:\n"
      "  expected K(uni) ~ 160 at rho 0.05, ~ 8-13 at rho 0.60-0.90.\n"
      "Shear states are expected WORSE per unit macro vm for a stretch-\n"
      "dominated lattice; hydrostatic macro vm is 0, so K_vm(hydro) = inf —\n"
      "the vol term must be reported per unit pressure instead.\n");
  FILE* states = open_csv(ev, "k_states_bulk.csv", kStateHeader);
  FILE* exact = open_csv(ev, "k_exact_bulk.csv", kExactHeader);
  FILE* tensor = open_csv(ev, "bulk_tensor.csv",
                          "rho_target,rho_lib,rho_meas,vpc,wall_vox,"
                          "C11_lib,C12_lib,C44_lib,C11_meas,C12_meas,C44_meas,"
                          "C11_drift_pct,C44_drift_pct");
  const int nsamp = fast ? 64 : 512;
  const int vpc_main = fast ? 16 : 32;
  const auto rhos = rho_sweep();
  for (double rt : rhos) {
    const RhoCal c = calibrate(rt);
    std::vector<int> vpcs = {vpc_main};
    if (!fast) {
      if (rt == rhos[3] || rt == rhos[5]) vpcs = {16, 24, 32, 40};  // vpc study
      if (rt <= 0.11 || rt == rhos[3] || rt == rhos[8]) vpcs.push_back(48);
    }
    for (int vpc : vpcs) {
      const auto t0 = std::chrono::steady_clock::now();
      Periodic P = solve_periodic(c.r_unit, vpc, 1e-9);
      const auto t1 = std::chrono::steady_clock::now();
      const M6 Dlib = lib_D(c.rho_lib);
      const CubicTensor tl = lattice_cubic_tensor(LatticeTopology::Octet, c.rho_lib, kEs);
      const double c11m = (P.CH(0, 0) + P.CH(1, 1) + P.CH(2, 2)) / 3.0;
      const double c12m = (P.CH(0, 1) + P.CH(0, 2) + P.CH(1, 2) + P.CH(1, 0) +
                           P.CH(2, 0) + P.CH(2, 1)) / 6.0;
      const double c44m = (P.CH(3, 3) + P.CH(4, 4) + P.CH(5, 5)) / 3.0;
      std::fprintf(tensor, "%.5f,%.5f,%.5f,%d,%.1f,%.3f,%.3f,%.3f,%.3f,%.3f,%.3f,%.2f,%.2f\n",
                   c.target, c.rho_lib, P.fx.rho_meas, vpc, P.fx.wall_vox,
                   tl.C11, tl.C12, tl.C44, c11m, c12m, c44m,
                   100.0 * (c11m / tl.C11 - 1.0), 100.0 * (c44m / tl.C44 - 1.0));
      write_state_rows(states, "periodic", c, 1, vpc, P.fx, Dlib, Pop::Interior,
                       true, "bulk");
      write_exact_row(exact, "periodic", c, 1, vpc, P.fx, Dlib, Pop::Interior,
                      true, "bulk", nsamp);
      std::fflush(states); std::fflush(exact); std::fflush(tensor);
      const ExactDev ed = exact_dev(P.fx, Dlib, Pop::Interior, true);
      const VolRatios vr = vol_ratios(P.fx, Dlib, Pop::Interior, true);
      std::printf("  rho %.3f vpc %2d (wall %.0f vox, %.1fs): K_dev=%.1f K_vol=%.1f  %s\n",
                  c.rho_lib, vpc, P.fx.wall_vox,
                  std::chrono::duration<double>(t1 - t0).count(), ed.K_dev,
                  vr.K_vol, P.ok ? "" : "<CG NOT CONVERGED>");
    }
  }
  std::fclose(states); std::fclose(exact); std::fclose(tensor);
}

// ---------------------------------------------------------------------------
// PHASE: blocks — KUBC finite blocks: interior-cell convergence toward the
// periodic bulk with N (J1).
// ---------------------------------------------------------------------------
void phase_blocks(const std::string& ev, bool fast) {
  std::printf("\n===== FINITE KUBC BLOCKS — N-convergence of the interior (J1) =====\n");
  FILE* states = open_csv(ev, "k_states_blocks.csv", kStateHeader);
  FILE* exact = open_csv(ev, "k_exact_blocks.csv", kExactHeader);
  struct Case { double rho; int N, vpc; };
  std::vector<Case> cases;
  if (fast) {
    cases = {{0.313, 2, 8}, {0.313, 3, 8}};
  } else {
    cases = {{0.20, 2, 16}, {0.20, 3, 16}, {0.20, 4, 16},
             {0.45, 2, 16}, {0.45, 3, 16}, {0.45, 4, 16},
             {0.20, 3, 24}};
  }
  for (const Case& cs : cases) {
    const RhoCal c = calibrate(cs.rho);
    const auto t0 = std::chrono::steady_clock::now();
    Fixture f = solve_finite(c.r_unit, cs.N, cs.vpc, /*kubc=*/true, 0.0,
                             1e-7, 120000);
    const auto t1 = std::chrono::steady_clock::now();
    if (!f.ok) { std::printf("  rho %.2f N%d SOLVE FAILED\n", cs.rho, cs.N); continue; }
    const M6 Dlib = lib_D(c.rho_lib);
    for (Pop p : {Pop::Interior, Pop::Grip}) {
      write_state_rows(states, "kubc", c, cs.N, cs.vpc, f, Dlib, p, false,
                       pop_name(p));
      write_exact_row(exact, "kubc", c, cs.N, cs.vpc, f, Dlib, p, false,
                      pop_name(p), 64);
    }
    std::fflush(states); std::fflush(exact);
    const ExactDev edI = exact_dev(f, Dlib, Pop::Interior, false);
    std::printf("  rho %.3f N%d vpc%d: interior K_dev=%.1f  (%.0fs, cg<=%d)\n",
                c.rho_lib, cs.N, cs.vpc, edI.K_dev,
                std::chrono::duration<double>(t1 - t0).count(),
                *std::max_element(f.iters, f.iters + 6));
  }
  std::fclose(states); std::fclose(exact);
}

// ---------------------------------------------------------------------------
// PHASE: boundary — sandwich (free lateral faces) + cut layer (J4, J7).
// ---------------------------------------------------------------------------
void phase_boundary(const std::string& ev, bool fast) {
  std::printf("\n===== BOUNDARY POPULATIONS — free surfaces and cut cells (J4) =====\n");
  FILE* states = open_csv(ev, "k_states_boundary.csv", kStateHeader);
  FILE* exact = open_csv(ev, "k_exact_boundary.csv", kExactHeader);
  FILE* cells = open_csv(ev, "k_cells.csv",
                         "fixture,rho_target,rho_lib,N,vpc,state,ci,cj,ck,class,"
                         "n_solid,cellavg_vm,cell_peak_vm,K_cell,K_far");
  struct Case { double rho; int N, vpc; double cut; };
  std::vector<Case> cases;
  if (fast) {
    cases = {{0.313, 3, 8, 0.0}, {0.313, 3, 8, 0.6}};
  } else {
    for (double r : rho_sweep()) cases.push_back({r, 4, 16, 0.0});
    cases.push_back({0.20, 4, 24, 0.0});   // resolution cross-check
    // The low band rhos are unusable at vpc16: the band floor disconnects
    // entirely (every voxel dropped as a floater) and 0.10 / 0.157 ALIAS onto
    // the same voxel set (rho_meas 0.119 — the vpc16 distance spectrum cannot
    // separate them; the fit's aliasing guard drops those rows). Re-measure the
    // three at N=3 vpc24 — still thin, flagged by wall_vox, but distinct and
    // connected.
    cases.push_back({rho_sweep()[0], 3, 24, 0.0});
    cases.push_back({0.10, 3, 24, 0.0});
    cases.push_back({0.157, 3, 24, 0.0});
    cases.push_back({0.20, 4, 16, 0.6});   // cut layer
    cases.push_back({0.313, 4, 16, 0.6});
    cases.push_back({0.60, 4, 16, 0.6});
  }
  for (const Case& cs : cases) {
    const RhoCal c = calibrate(cs.rho);
    const char* fixname = cs.cut > 0 ? "cut" : "sandwich";
    const auto t0 = std::chrono::steady_clock::now();
    Fixture f = solve_finite(c.r_unit, cs.N, cs.vpc, /*kubc=*/false, cs.cut,
                             1e-7, 160000);
    const auto t1 = std::chrono::steady_clock::now();
    if (!f.ok) {
      std::printf("  %s rho %.2f SOLVE FAILED\n", fixname, cs.rho);
      continue;
    }
    const M6 Dlib = lib_D(c.rho_lib);
    std::vector<Pop> pops = {Pop::Interior, Pop::Grip, Pop::Free};
    if (cs.cut > 0) pops.push_back(Pop::Cut);
    for (Pop p : pops) {
      write_state_rows(states, fixname, c, cs.N, cs.vpc, f, Dlib, p, false,
                       pop_name(p));
      write_exact_row(exact, fixname, c, cs.N, cs.vpc, f, Dlib, p, false,
                      pop_name(p), 64);
    }
    // Per-cell records for the named states (the local law).
    for (const auto& ns : named_states()) {
      V6 e;
      for (int i = 0; i < 6; ++i) e(i) = ns.e[i];
      const double mvm = von_mises_of(Dlib * e);
      for (const CellRec& r : per_cell(f, e, mvm, false))
        std::fprintf(cells, "%s,%.5f,%.5f,%d,%d,%s,%d,%d,%d,%s,%zu,%.4f,%.4f,%.3f,%.3f\n",
                     fixname, c.target, c.rho_lib, cs.N, cs.vpc, ns.name, r.ci,
                     r.cj, r.ck, pop_name(r.cls), r.n_solid, r.avg_vm, r.peak_vm,
                     r.K_cell, r.K_far);
    }
    std::fflush(states); std::fflush(exact); std::fflush(cells);
    const ExactDev edF = exact_dev(f, Dlib, Pop::Free, false);
    const ExactDev edI = exact_dev(f, Dlib, Pop::Interior, false);
    std::printf("  %s rho %.3f N%d vpc%d: K_dev free=%.1f interior=%.1f "
                "dropped=%zu (%.0fs, cg<=%d)\n",
                fixname, c.rho_lib, cs.N, cs.vpc, edF.K_dev, edI.K_dev,
                f.dropped_floaters,
                std::chrono::duration<double>(t1 - t0).count(),
                *std::max_element(f.iters, f.iters + 6));
  }
  std::fclose(states); std::fclose(exact); std::fclose(cells);
}

// ---------------------------------------------------------------------------
// PHASE: fit — read the exact-law CSVs, fit K(rho), residuals (J3), write the
// law table j6 consumes.
// ---------------------------------------------------------------------------
struct LawRow {
  double rho;                       // rho_lib
  double Kd_bulk = 0, Kv_bulk = 0, Kild_bulk = 0, Kilv_bulk = 0;
  double Kd_bnd = 0, Kv_bnd = 0, Kild_bnd = 0, Kilv_bnd = 0;  // max over free/cut/grip-free populations
  double wall_vox = 0;
  int vpc = 0;
};

std::vector<std::map<std::string, std::string>> read_csv(const std::string& path) {
  std::vector<std::map<std::string, std::string>> rows;
  FILE* f = std::fopen(path.c_str(), "r");
  if (!f) return rows;
  char line[4096];
  std::vector<std::string> hdr;
  bool first = true;
  while (std::fgets(line, sizeof line, f)) {
    std::vector<std::string> parts;
    std::string cur;
    for (char* p = line; *p; ++p) {
      if (*p == ',' ) { parts.push_back(cur); cur.clear(); }
      else if (*p != '\n' && *p != '\r') cur.push_back(*p);
    }
    parts.push_back(cur);
    if (first) { hdr = parts; first = false; continue; }
    if (parts.size() != hdr.size()) continue;
    std::map<std::string, std::string> row;
    for (std::size_t i = 0; i < hdr.size(); ++i) row[hdr[i]] = parts[i];
    rows.push_back(row);
  }
  std::fclose(f);
  return rows;
}
double num(const std::map<std::string, std::string>& r, const char* k) {
  auto it = r.find(k);
  return it == r.end() ? 0.0 : std::atof(it->second.c_str());
}

void phase_fit(const std::string& ev) {
  std::printf("\n===== FIT — is K a function or scatter? (J3) =====\n");
  const auto bulk = read_csv(ev + "/k_exact_bulk.csv");
  const auto bnd = read_csv(ev + "/k_exact_boundary.csv");
  if (bulk.empty()) { std::printf("  no bulk rows — run bulk first\n"); return; }

  // One law row per rho: bulk at the FINEST vpc measured for that rho (peak
  // stress grows with refinement at the voxelized joints, so the finest row is
  // the conservative choice; the 32->48 drift is the stated resolution error
  // bar), boundary = max over the free/cut populations at their resolution.
  // ALIASING GUARD: a coarse voxelization can land two different radii on the
  // SAME voxel set (measured: vpc16 cannot separate rho 0.10 from 0.157 — both
  // give rho_meas 0.119, the distance spectrum has a gap there). A row whose
  // measured density disagrees with its library rho by >15% is measuring a
  // different lattice than its K normalizer assumes — excluded from the law.
  auto aliased = [](const std::map<std::string, std::string>& r) {
    const double lib = num(r, "rho_lib"), meas = num(r, "rho_meas");
    return lib <= 0 || std::fabs(meas - lib) / lib > 0.15;
  };

  std::map<double, LawRow> law;
  for (const auto& r : bulk) {
    if (aliased(r)) continue;
    const double rho = num(r, "rho_lib");
    const int vpc = (int)num(r, "vpc");
    LawRow& L = law[rho];
    if (vpc >= L.vpc) {
      L.rho = rho;
      L.vpc = vpc;
      L.wall_vox = num(r, "wall_vox");
      L.Kd_bulk = num(r, "K_dev_max");
      L.Kv_bulk = num(r, "K_vol");
      L.Kild_bulk = num(r, "K_il_dev");
      L.Kilv_bulk = num(r, "K_il_vol");
    }
  }
  for (const auto& r : bnd) {
    const std::string pop = r.at("population");
    if (pop != "free_surface" && pop != "cut_layer") continue;
    if (num(r, "n_vox") <= 0 || num(r, "K_dev_max") <= 0) continue;  // e.g. the
    // fully-disconnected under-resolved low-rho voxelization (dropped floaters)
    if (aliased(r)) continue;
    const double rho = num(r, "rho_lib");
    // attach to the nearest law rho (calibration reproduces identical rho_lib)
    auto it = law.find(rho);
    if (it == law.end()) {
      double best = 1e9;
      for (auto& kv : law)
        if (std::fabs(kv.first - rho) < best) { best = std::fabs(kv.first - rho); it = law.find(kv.first); }
    }
    if (it == law.end()) continue;
    LawRow& L = it->second;
    L.Kd_bnd = std::max(L.Kd_bnd, num(r, "K_dev_max"));
    L.Kv_bnd = std::max(L.Kv_bnd, num(r, "K_vol"));
    L.Kild_bnd = std::max(L.Kild_bnd, num(r, "K_il_dev"));
    L.Kilv_bnd = std::max(L.Kilv_bnd, num(r, "K_il_vol"));
  }

  FILE* fit = open_csv(ev, "kfit.csv",
                       "rho_lib,vpc,wall_vox,Kd_bulk,Kv_bulk,Kild_bulk,Kilv_bulk,"
                       "Kd_bnd,Kv_bnd,Kild_bnd,Kilv_bnd,Kd_cert,Kv_cert,"
                       "Kild_cert,Kilv_cert");
  std::vector<std::array<double, 2>> pts;  // (ln rho, ln Kd_cert)
  for (auto& kv : law) {
    LawRow& L = kv.second;
    // The CERT law: the conservative envelope over every measured population.
    const double Kd = std::max(L.Kd_bulk, L.Kd_bnd);
    const double Kv = std::max(L.Kv_bulk, L.Kv_bnd);
    const double Kild = std::max(L.Kild_bulk, L.Kild_bnd);
    const double Kilv = std::max(L.Kilv_bulk, L.Kilv_bnd);
    std::fprintf(fit, "%.5f,%d,%.1f,%.4f,%.4f,%.4f,%.4f,%.4f,%.4f,%.4f,%.4f,"
                      "%.4f,%.4f,%.4f,%.4f\n",
                 L.rho, L.vpc, L.wall_vox, L.Kd_bulk, L.Kv_bulk, L.Kild_bulk,
                 L.Kilv_bulk, L.Kd_bnd, L.Kv_bnd, L.Kild_bnd, L.Kilv_bnd, Kd,
                 Kv, Kild, Kilv);
    if (Kd > 0) pts.push_back({std::log(L.rho), std::log(Kd)});
  }
  std::fclose(fit);

  // Power-law fit ln K = a + b ln rho over the envelope; residuals.
  if (pts.size() >= 3) {
    double sx = 0, sy = 0, sxx = 0, sxy = 0;
    for (auto& p : pts) { sx += p[0]; sy += p[1]; sxx += p[0] * p[0]; sxy += p[0] * p[1]; }
    const double n = (double)pts.size();
    const double b = (n * sxy - sx * sy) / (n * sxx - sx * sx);
    const double a = (sy - b * sx) / n;
    double worst = 0;
    for (auto& p : pts)
      worst = std::max(worst, std::fabs(std::exp(a + b * p[0]) / std::exp(p[1]) - 1.0));
    std::printf("  K_dev envelope ~ %.2f * rho^%.3f ; worst row deviation %.1f%%\n",
                std::exp(a), b, 100 * worst);
    std::printf("  (the LAW HANDED TO J6 is the per-rho TABLE, interpolated —\n"
                "   the power fit is descriptive only.)\n");
  }
  std::printf("  kfit.csv written (%zu rho rows)\n", law.size());
}

// ---------------------------------------------------------------------------
// PHASE: j6 — what would the gate have said about PR 255's certified designs?
// ---------------------------------------------------------------------------
double interp_col(const std::vector<std::array<double, 2>>& tab, double rho) {
  if (tab.empty()) return 0.0;
  if (rho <= tab.front()[0]) return tab.front()[1];
  if (rho >= tab.back()[0]) return tab.back()[1];
  for (std::size_t i = 0; i + 1 < tab.size(); ++i)
    if (rho <= tab[i + 1][0]) {
      const double t = (rho - tab[i][0]) / (tab[i + 1][0] - tab[i][0]);
      return tab[i][1] + t * (tab[i + 1][1] - tab[i][1]);
    }
  return tab.back()[1];
}

// PR 255 cantilever fixture (verbatim lattice_gap_probe.cpp constants).
namespace pr255 {
constexpr int kNx = 48, kNy = 24, kNz = 6;
constexpr double kSpacing = 1.0;
constexpr double kTipLoadTotal = -200.0;
constexpr double kVoidTol = 1e-3;

VoxelGrid make_grid() {
  VoxelGrid g;
  g.nx = kNx; g.ny = kNy; g.nz = kNz;
  g.spacing = kSpacing;
  g.origin = Vec3{0, 0, 0};
  g.tags.assign((std::size_t)kNx * kNy * kNz, VoxelTag::Interior);
  return g;
}
void make_bcs_loads(const VoxelGrid& g, std::vector<DirichletBC>& bcs,
                    std::vector<NodalLoad>& loads) {
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
  std::vector<int> tip;
  for (int k = 0; k <= g.nz; ++k)
    tip.push_back(((k * (g.ny + 1)) + g.ny / 2) * (g.nx + 1) + g.nx);
  for (int n : tip)
    loads.push_back({n, 1, kTipLoadTotal / (double)tip.size()});
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
  m.yield_strength_mpa = kYield;
  m.density_g_cm3 = 1.24;
  m.z_knockdown = kZKnock;
  m.poisson = kNu;
  m.family = "fdm";
  return m;
}
}  // namespace pr255

void phase_j6(const std::string& ev, const std::string& pr255_dir) {
  std::printf("\n===== J6 — PR 255's certified designs under the measured K =====\n");
  // The measured law.
  const auto fitrows = read_csv(ev + "/kfit.csv");
  if (fitrows.empty()) {
    std::printf("  kfit.csv missing — run fit first\n");
    return;
  }
  std::vector<std::array<double, 2>> Kd, Kv, Kild, Kilv;
  for (const auto& r : fitrows) {
    const double rho = num(r, "rho_lib");
    Kd.push_back({rho, num(r, "Kd_cert")});
    Kv.push_back({rho, num(r, "Kv_cert")});
    Kild.push_back({rho, num(r, "Kild_cert")});
    Kilv.push_back({rho, num(r, "Kilv_cert")});
  }
  auto bysort = [](std::vector<std::array<double, 2>>& t) {
    std::sort(t.begin(), t.end(),
              [](const std::array<double, 2>& a, const std::array<double, 2>& b) {
                return a[0] < b[0];
              });
  };
  bysort(Kd); bysort(Kv); bysort(Kild); bysort(Kilv);

  FILE* out = open_csv(ev, "j6_margins.csv",
                       "design,accepted_as_shipped,margin_reported,"
                       "lattice_voxels,max_macro_vm_lattice,max_strut_vm_bound,"
                       "argmax_rho,margin_strut,max_strut_il_bound,margin_il_strut,"
                       "margin_would_be,accept_would_be_at_0.5,ratio_vs_reported");
  FILE* rec = std::fopen((ev + "/j6_receipts.txt").c_str(), "w");

  const VoxelGrid g = pr255::make_grid();
  std::vector<DirichletBC> bcs;
  std::vector<NodalLoad> loads;
  pr255::make_bcs_loads(g, bcs, loads);
  const double lo = lattice_rho_min(LatticeTopology::Octet);
  const double hi = lattice_rho_max(LatticeTopology::Octet);
  const Material mat = pr255::pla_material();

  for (const char* name : {"s0_plain", "s2_gappen", "s3_contin"}) {
    const std::string path = pr255_dir + "/p2_field_" + name + ".csv";
    const auto rows = read_csv(path);
    if (rows.empty()) {
      std::printf("  %s: field CSV missing at %s — SKIPPED\n", name, path.c_str());
      std::fprintf(rec, "%s: field CSV missing (%s)\n", name, path.c_str());
      continue;
    }
    std::vector<double> rho(g.voxel_count(), 0.0);
    for (const auto& r : rows) {
      const int i = (int)num(r, "i"), j = (int)num(r, "j"), k = (int)num(r, "k");
      rho[g.index(i, j, k)] = num(r, "rho");
    }
    const std::vector<double> snapped = pr255::snap_to_feasible(rho, lo, hi);

    std::vector<double> density(g.voxel_count(), 0.0);
    LatticePosture post;
    post.topology = LatticeTopology::Octet;
    post.cell_size_mm = 4.0;
    post.mask.assign(g.voxel_count(), 0);
    post.relative_density.assign(g.voxel_count(), 0.0);
    for (std::size_t e = 0; e < snapped.size(); ++e) {
      if (snapped[e] <= 0.0) continue;
      density[e] = 1.0;
      if (snapped[e] < 1.0) {
        post.mask[e] = 1;
        post.relative_density[e] = snapped[e];
      }
    }
    SimpParams params;
    params.youngs_modulus = mat.youngs_modulus_mpa;
    params.poisson = mat.poisson;
    params.penalty = 3.0;
    const KnockdownSpec kd;
    FixedDesignAnalysis a;
    try {
      a = analyze_fixed_design(g, params, density, bcs, loads, mat,
                               Vec3{0, 0, 1}, 1e-8, 0, SolverKind::JacobiCG,
                               0.5, kd, true, (double)g.solid_count(), &post);
    } catch (const std::exception& e) {
      std::printf("  %s: analyze threw: %s\n", name, e.what());
      std::fprintf(rec, "%s: analyze threw: %s\n", name, e.what());
      continue;
    }

    // The de-homogenized bound per lattice voxel:
    //   strut_vm    <= Kd(rho)*vm(Sigma) + Kv(rho)*|p(Sigma)|
    //   strut n.s.n <= Kild(rho)*vm(Sigma) + Kilv(rho)*|p(Sigma)|
    double max_macro_vm = 0, max_bound = 0, max_il_bound = 0, argmax_rho = 0;
    std::size_t nlat = 0;
    for (std::size_t e = 0; e < snapped.size(); ++e) {
      if (!post.mask[e]) continue;
      ++nlat;
      V6 Sig;
      for (int c = 0; c < 6; ++c) Sig(c) = a.stress_tensor_field[6 * e + c];
      const double vm = von_mises_of(Sig);
      const double p = std::fabs(pressure_of(Sig));
      const double rv = post.relative_density[e];
      const double bound = interp_col(Kd, rv) * vm + interp_col(Kv, rv) * p;
      const double il = interp_col(Kild, rv) * vm + interp_col(Kilv, rv) * p;
      if (vm > max_macro_vm) max_macro_vm = vm;
      if (bound > max_bound) { max_bound = bound; argmax_rho = rv; }
      if (il > max_il_bound) max_il_bound = il;
    }
    const double margin_strut = max_bound > 0 ? kYield / max_bound : 1e30;
    const double margin_il = max_il_bound > 0
                                 ? (mat.z_knockdown * kYield) / max_il_bound
                                 : 1e30;
    const double margin_would_be =
        std::min({a.margin.worst_case, margin_strut, margin_il});
    const bool would_accept = margin_would_be >= 0.5 && a.accepted;
    std::fprintf(out, "%s,%d,%.4f,%zu,%.4f,%.3f,%.4f,%.4f,%.3f,%.4f,%.4f,%d,%.4f\n",
                 name, a.accepted ? 1 : 0, a.margin.worst_case, nlat,
                 max_macro_vm, max_bound, argmax_rho, margin_strut, max_il_bound,
                 margin_il, margin_would_be, would_accept ? 1 : 0,
                 margin_would_be / std::max(a.margin.worst_case, 1e-12));
    std::fprintf(rec,
                 "== %s ==\n"
                 "as shipped: %s, margin.worst_case=%.4f, margin_effective=%.4f, "
                 "lattice_voxels=%zu, strength_uncertified=%d\n"
                 "measured-K bound: max lattice macro vm=%.4f MPa -> "
                 "max strut vm bound=%.3f MPa (argmax rho=%.4f)\n"
                 "  strut vm margin      = %.4f\n"
                 "  strut interlayer     = %.3f MPa -> margin %.4f  "
                 "(z_knockdown=%.2f UNSOURCED — ratio is the finding, "
                 "ARCHITECTURE.md:118)\n"
                 "  margin would be      = %.4f  -> %s at margin_stop 0.5\n\n",
                 name, a.accepted ? "ACCEPTED" : "REJECTED", a.margin.worst_case,
                 a.margin_effective, a.lattice_voxels,
                 a.lattice_strength_uncertified ? 1 : 0, max_macro_vm, max_bound,
                 argmax_rho, margin_strut, max_il_bound, margin_il,
                 mat.z_knockdown, margin_would_be,
                 would_accept ? "STILL ACCEPTED" : "WOULD BE REJECTED");
    std::printf("  %s: shipped margin %.3f -> strut-bound margin %.4f (%s)\n",
                name, a.margin.worst_case, margin_would_be,
                would_accept ? "still accepted" : "WOULD BE REJECTED");
  }
  std::fclose(out);
  std::fclose(rec);
}

}  // namespace

int main(int argc, char** argv) {
  std::setvbuf(stdout, nullptr, _IONBF, 0);
  const std::string phase = argc > 1 ? argv[1] : "all";
  const std::string ev = argc > 2 ? argv[2] : ".";
  const std::string pr255_dir =
      argc > 3 ? argv[3] : "evidence/2026-07-31-multiscale-lattice-feasibility";
  const bool fast = std::getenv("TOPOPT_DEHOMOG_FAST") != nullptr;
  fea_set_matfree_threads(1);  // determinism (bar J8)

  std::printf("LATTICE DE-HOMOGENIZATION PROBE — octet band [%.5f, %.5f] "
              "(read from core)\n",
              lattice_rho_min(LatticeTopology::Octet),
              lattice_rho_max(LatticeTopology::Octet));
  if (fast) std::printf("  [FAST mode — reduced sets, development only]\n");

  int rc = 0;
  auto want = [&](const char* s) { return phase == "all" || phase == s; };
  if (want("selfcheck")) rc += phase_selfcheck(ev);
  if (want("bulk")) phase_bulk(ev, fast);
  if (want("blocks")) phase_blocks(ev, fast);
  if (want("boundary")) phase_boundary(ev, fast);
  if (want("fit")) phase_fit(ev);
  if (want("j6")) phase_j6(ev, pr255_dir);
  std::printf("\nDONE (rc=%d).\n", rc);
  return rc;
}
