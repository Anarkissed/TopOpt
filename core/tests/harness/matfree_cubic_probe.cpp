// matfree_cubic_probe — CAN THE MATRIX-FREE KERNEL CARRY A PER-VOXEL CUBIC
// TENSOR?  (probe, 2026-07-30-matfree-cubic-probe)
//
// Today the ONLY path that carries per-voxel cubic tensors is the assembled
// Jacobi-CG fea_solve_cg_lattice (assembly.cpp), and analyze.cpp:164 assembles a
// latticed certification REGARDLESS of solver_kind — so a lattice-aware solve
// cannot reach GenEO, multigrid, recycling or draft. This probe tests the
// hypothesis that would fix that: element stiffness is LINEAR in the
// constitutive matrix (Ke = ∫ B^T D B dV), and a cubic D decomposes as
//
//   D(C11,C12,C44) = C11*D_A + C12*D_B + C44*D_C
//     D_A = diag(1,1,1,0,0,0)   (normal-block diagonal)
//     D_B = normal-block off-diagonal ones
//     D_C = diag(0,0,0,1,1,1)   (shear-block diagonal)
//
// so  Ke(C11,C12,C44) = C11*K_A + C12*K_B + C44*K_C  with three FIXED 24x24
// reference blocks. If that holds, the matrix-free kernel needs three reference
// blocks instead of one and three per-voxel coefficients instead of one scalar.
//
// EVERYTHING here is HARNESS-SIDE: the production library is linked unmodified;
// the cubic matrix-free kernel lives in this file. No production constant is
// armed and no default changes. Bars (see the handoff):
//   d1 — the decomposition is exact (worst relative error over an admissible
//        sweep incl. the measured tensor-library rows of all 7 topologies)
//   d2 — a matrix-free cubic apply matches the assembled operator (<= 1e-12)
//        and a matrix-free cubic Jacobi-CG matches fea_solve_cg_lattice's field
//   d3 — measured apply-cost ratio, cubic vs scalar kernel (predicted ~3x),
//        CG-iteration-normalised (per-apply), not wall clock of a whole solve
//   d4 — the operator stays SPD and the accelerator FAMILY still engages:
//        Jacobi-CG baseline vs +Krylov recycling (the PRODUCTION RecycleSession,
//        operator-agnostic) vs +two-level Galerkin coarse correction (multigrid
//        family) vs +GenEO-style spectral coarse space, CG counts reported on a
//        void/lattice/solid contrast fixture
//   d5 — with NO cubic voxels the probe path reproduces today's matrix-free
//        apply AND solve bit-for-bit, and the memory cost at the 8.44M-DOF
//        production scale is reported (BLOCKED-STOP check)
//
// Build (from the repo root; machine of record Apple M2 Pro, Apple clang, -O2):
//   c++ -std=c++17 -O2 -I core/include -I core/src -I /opt/homebrew/include/eigen3 \
//       core/tests/harness/matfree_cubic_probe.cpp core/build/libtopopt.a \
//       -o core/build/matfree_cubic_probe
//   ./core/build/matfree_cubic_probe [d1|d2|d3|d4|d5|all] [evidence-dir]

#include <algorithm>
#include <array>
#include <chrono>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <functional>
#include <random>
#include <set>
#include <string>
#include <vector>

#include <Eigen/Dense>
#include <Eigen/Sparse>

#if defined(__ARM_NEON)
#include <arm_neon.h>
#elif defined(__SSE2__)
#include <emmintrin.h>
#endif

#include "topopt/fea.hpp"
#include "topopt/lattice.hpp"
#include "topopt/voxel.hpp"

#include "fea/fea_matfree.hpp"  // internal: MfElem, mf_build_elems, mf_apply_full
#include "fea/recycle.hpp"      // internal: the production RecycleSession

using namespace topopt;
using fea_detail::MfElem;
using SpMat = Eigen::SparseMatrix<double>;
using Trip = Eigen::Triplet<double>;

namespace {

constexpr int kDof = Hex8Stiffness::kDof;  // 24

FILE* open_csv(const std::string& dir, const char* name) {
  const std::string p = dir + "/" + name;
  FILE* f = std::fopen(p.c_str(), "w");
  if (!f) { std::fprintf(stderr, "cannot open %s\n", p.c_str()); std::exit(1); }
  return f;
}

// ---------------------------------------------------------------------------
// Reference integrator — an exact code copy of hex_element.cpp's static
// integrate_hex8 (same Gauss order, same accumulation order), so blocks built
// here from 0/1 D-matrices are on the production integrator's arithmetic.
// ---------------------------------------------------------------------------
constexpr double kXi[8] = {-1, +1, +1, -1, -1, +1, +1, -1};
constexpr double kEta[8] = {-1, -1, +1, +1, -1, -1, +1, +1};
constexpr double kZeta[8] = {-1, -1, -1, -1, +1, +1, +1, +1};

Hex8Stiffness integrate_hex8_ref(const double D[6][6], double h) {
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
          const double xa = kXi[a], ea = kEta[a], za = kZeta[a];
          const double dNdxi = 0.125 * xa * (1.0 + eta * ea) * (1.0 + zeta * za);
          const double dNdeta = 0.125 * ea * (1.0 + xi * xa) * (1.0 + zeta * za);
          const double dNdzeta = 0.125 * za * (1.0 + xi * xa) * (1.0 + eta * ea);
          dNdx[a] = dnat_to_dx * dNdxi;
          dNdy[a] = dnat_to_dx * dNdeta;
          dNdz[a] = dnat_to_dx * dNdzeta;
        }
        double B[6][24] = {};
        for (int a = 0; a < 8; ++a) {
          const int cx = 3 * a, cy = 3 * a + 1, cz = 3 * a + 2;
          B[0][cx] = dNdx[a];
          B[1][cy] = dNdy[a];
          B[2][cz] = dNdz[a];
          B[3][cx] = dNdy[a];
          B[3][cy] = dNdx[a];
          B[4][cy] = dNdz[a];
          B[4][cz] = dNdy[a];
          B[5][cx] = dNdz[a];
          B[5][cz] = dNdx[a];
        }
        double DB[6][24];
        for (int r = 0; r < 6; ++r)
          for (int col = 0; col < 24; ++col) {
            double s = 0.0;
            for (int m = 0; m < 6; ++m) s += D[r][m] * B[m][col];
            DB[r][col] = s;
          }
        for (int r = 0; r < 24; ++r)
          for (int col = 0; col < 24; ++col) {
            double s = 0.0;
            for (int m = 0; m < 6; ++m) s += B[m][r] * DB[m][col];
            Ke.k[static_cast<std::size_t>(r) * 24 + col] += s * detJ;
          }
      }
  return Ke;
}

// The three fixed reference blocks of the decomposition, at element size h.
struct RefBlocks {
  Hex8Stiffness KA, KB, KC;
};
RefBlocks build_ref_blocks(double h) {
  double DA[6][6] = {}, DB[6][6] = {}, DC[6][6] = {};
  DA[0][0] = DA[1][1] = DA[2][2] = 1.0;
  DB[0][1] = DB[0][2] = DB[1][0] = DB[1][2] = DB[2][0] = DB[2][1] = 1.0;
  DC[3][3] = DC[4][4] = DC[5][5] = 1.0;
  RefBlocks b;
  b.KA = integrate_hex8_ref(DA, h);
  b.KB = integrate_hex8_ref(DB, h);
  b.KC = integrate_hex8_ref(DC, h);
  return b;
}

// ---------------------------------------------------------------------------
// The PROBE cubic matrix-free kernel. Mirrors matfree.cpp's apply structure
// (column-major reference blocks, contiguous AXPY, 8-colour element table) with
// THREE blocks and per-element coefficients (a,b,c) = (C11,C12,C44).
// Scalar (isotropic) elements go through the PRODUCTION mf_apply_full
// UNCHANGED; cubic elements are a second coloured list applied on top. With an
// empty cubic list the apply IS the production apply, bit for bit (bar d5).
// ---------------------------------------------------------------------------
// Exact copy of matfree.cpp's SIMD AXPY (2-wide, plain mul+add, never FMA) so
// the probe kernel's arithmetic structure matches the production kernel and the
// d3 cost ratio compares like against like.
inline void axpy24(double* acc, double w, const double* col) {
#if defined(__ARM_NEON)
  const float64x2_t wv = vdupq_n_f64(w);
  for (int r = 0; r < kDof; r += 2) {
    float64x2_t a = vld1q_f64(acc + r);
    a = vaddq_f64(a, vmulq_f64(wv, vld1q_f64(col + r)));  // mul+add, no FMA
    vst1q_f64(acc + r, a);
  }
#elif defined(__SSE2__)
  const __m128d wv = _mm_set1_pd(w);
  for (int r = 0; r < kDof; r += 2) {
    __m128d a = _mm_loadu_pd(acc + r);
    a = _mm_add_pd(a, _mm_mul_pd(wv, _mm_loadu_pd(col + r)));  // mul+add, no FMA
    _mm_storeu_pd(acc + r, a);
  }
#else
  for (int r = 0; r < kDof; ++r) acc[r] += w * col[r];
#endif
}

struct CubElem {
  double a = 0.0, b = 0.0, c = 0.0;  // C11, C12, C44
  int edof[kDof];
};

// Build the coloured cubic element table from a lattice mask + tensor arrays
// (same colouring rule as mf_build_elems, grid-scan order within a colour).
std::vector<CubElem> build_cubic_elems(const VoxelGrid& grid,
                                       const std::vector<char>& mask,
                                       const std::vector<double>& c11,
                                       const std::vector<double>& c12,
                                       const std::vector<double>& c44,
                                       std::vector<int>* offsets) {
  std::vector<CubElem> buckets[fea_detail::kNumColors];
  for (int k = 0; k < grid.nz; ++k)
    for (int j = 0; j < grid.ny; ++j)
      for (int i = 0; i < grid.nx; ++i) {
        if (!grid.solid(i, j, k)) continue;
        const std::size_t e = grid.index(i, j, k);
        if (!mask[e]) continue;
        CubElem el;
        el.a = c11[e];
        el.b = c12[e];
        el.c = c44[e];
        const std::array<int, 8> en = fea_element_nodes(grid, i, j, k);
        for (int a = 0; a < 8; ++a)
          for (int c = 0; c < 3; ++c) el.edof[3 * a + c] = 3 * en[a] + c;
        const int color = (i & 1) | ((j & 1) << 1) | ((k & 1) << 2);
        buckets[color].push_back(el);
      }
  std::vector<CubElem> elems;
  if (offsets) offsets->assign(fea_detail::kNumColors + 1, 0);
  for (int color = 0; color < fea_detail::kNumColors; ++color) {
    if (offsets) (*offsets)[color] = static_cast<int>(elems.size());
    elems.insert(elems.end(), buckets[color].begin(), buckets[color].end());
  }
  if (offsets) (*offsets)[fea_detail::kNumColors] = static_cast<int>(elems.size());
  return elems;
}

inline void build_colmajor(const Hex8Stiffness& Ke, double* cm) {
  for (int r = 0; r < kDof; ++r)
    for (int c = 0; c < kDof; ++c)
      cm[static_cast<std::size_t>(c) * kDof + r] =
          Ke.k[static_cast<std::size_t>(r) * kDof + c];
}

inline void apply_one_cubic(const CubElem& el, const double* KAcm,
                            const double* KBcm, const double* KCcm,
                            const std::vector<double>& x,
                            std::vector<double>& y) {
  alignas(16) double ul[kDof];
  alignas(16) double ra[kDof], rb[kDof], rc[kDof];
  for (int r = 0; r < kDof; ++r) {
    ul[r] = x[static_cast<std::size_t>(el.edof[r])];
    ra[r] = rb[r] = rc[r] = 0.0;
  }
  for (int c = 0; c < kDof; ++c) {
    const double w = ul[c];
    axpy24(ra, w, &KAcm[static_cast<std::size_t>(c) * kDof]);
    axpy24(rb, w, &KBcm[static_cast<std::size_t>(c) * kDof]);
    axpy24(rc, w, &KCcm[static_cast<std::size_t>(c) * kDof]);
  }
  for (int r = 0; r < kDof; ++r)
    y[static_cast<std::size_t>(el.edof[r])] +=
        el.a * ra[r] + el.b * rb[r] + el.c * rc[r];
}

// Single-block twin of apply_one_cubic (same gather/scatter, ONE reference
// block, coefficient a as the scalar factor). Used only by the d3 benchmark to
// separate the 3-block cost from any probe-vs-production codegen difference.
inline void apply_one_scalar_probe(const CubElem& el, const double* KAcm,
                                   const std::vector<double>& x,
                                   std::vector<double>& y) {
  alignas(16) double ul[kDof];
  alignas(16) double ra[kDof];
  for (int r = 0; r < kDof; ++r) {
    ul[r] = x[static_cast<std::size_t>(el.edof[r])];
    ra[r] = 0.0;
  }
  for (int c = 0; c < kDof; ++c)
    axpy24(ra, ul[c], &KAcm[static_cast<std::size_t>(c) * kDof]);
  for (int r = 0; r < kDof; ++r)
    y[static_cast<std::size_t>(el.edof[r])] += el.a * ra[r];
}

void scalar_probe_apply(const std::vector<CubElem>& elems,
                        const std::vector<int>& offsets, const Hex8Stiffness& Ke,
                        std::vector<double>& x, std::vector<double>& y) {
  std::fill(y.begin(), y.end(), 0.0);
  alignas(16) double KAcm[kDof * kDof];
  build_colmajor(Ke, KAcm);
  const std::function<void(int, int)> body = [&](int lo, int hi) {
    for (int i = lo; i < hi; ++i)
      apply_one_scalar_probe(elems[static_cast<std::size_t>(i)], KAcm, x, y);
  };
  for (int color = 0; color < fea_detail::kNumColors; ++color)
    fea_detail::mf_parallel_ranges(offsets[static_cast<std::size_t>(color)],
                                   offsets[static_cast<std::size_t>(color) + 1],
                                   1024, body);
}

// Combined-block VARIANT (d3 only): per element, form the combined column-major
// block a*K_A + b*K_B + c*K_C once (576 fused ops), then run the standard
// single-block sweep. Same result up to roundoff; different register/flop
// tradeoff — one accumulator instead of three.
inline void apply_one_cubic_combined(const CubElem& el, const double* KAcm,
                                     const double* KBcm, const double* KCcm,
                                     double* Kcomb, const std::vector<double>& x,
                                     std::vector<double>& y) {
  for (int t = 0; t < kDof * kDof; ++t)
    Kcomb[t] = el.a * KAcm[t] + el.b * KBcm[t] + el.c * KCcm[t];
  alignas(16) double ul[kDof];
  alignas(16) double ra[kDof];
  for (int r = 0; r < kDof; ++r) {
    ul[r] = x[static_cast<std::size_t>(el.edof[r])];
    ra[r] = 0.0;
  }
  for (int c = 0; c < kDof; ++c)
    axpy24(ra, ul[c], &Kcomb[static_cast<std::size_t>(c) * kDof]);
  for (int r = 0; r < kDof; ++r)
    y[static_cast<std::size_t>(el.edof[r])] += ra[r];
}

void cubic_apply_combined(const std::vector<CubElem>& elems,
                          const std::vector<int>& offsets, const RefBlocks& B,
                          const std::vector<double>& x, std::vector<double>& y) {
  std::fill(y.begin(), y.end(), 0.0);
  alignas(16) double KAcm[kDof * kDof], KBcm[kDof * kDof], KCcm[kDof * kDof];
  build_colmajor(B.KA, KAcm);
  build_colmajor(B.KB, KBcm);
  build_colmajor(B.KC, KCcm);
  const std::function<void(int, int)> body = [&](int lo, int hi) {
    alignas(16) double Kcomb[kDof * kDof];
    for (int i = lo; i < hi; ++i)
      apply_one_cubic_combined(elems[static_cast<std::size_t>(i)], KAcm, KBcm,
                               KCcm, Kcomb, x, y);
  };
  for (int color = 0; color < fea_detail::kNumColors; ++color)
    fea_detail::mf_parallel_ranges(offsets[static_cast<std::size_t>(color)],
                                   offsets[static_cast<std::size_t>(color) + 1],
                                   1024, body);
}

// Cubic-only pass: y += sum over cubic elements (NOT zeroed — call after the
// scalar pass). Colour-by-colour, threaded on the production worker pool with
// the production granularity floor, so it inherits the determinism argument.
void cubic_apply_add(const std::vector<CubElem>& elems,
                     const std::vector<int>& offsets, const RefBlocks& B,
                     const std::vector<double>& x, std::vector<double>& y) {
  alignas(16) double KAcm[kDof * kDof], KBcm[kDof * kDof], KCcm[kDof * kDof];
  build_colmajor(B.KA, KAcm);
  build_colmajor(B.KB, KBcm);
  build_colmajor(B.KC, KCcm);
  const std::function<void(int, int)> body = [&](int lo, int hi) {
    for (int i = lo; i < hi; ++i)
      apply_one_cubic(elems[static_cast<std::size_t>(i)], KAcm, KBcm, KCcm, x, y);
  };
  for (int color = 0; color < fea_detail::kNumColors; ++color)
    fea_detail::mf_parallel_ranges(offsets[static_cast<std::size_t>(color)],
                                   offsets[static_cast<std::size_t>(color) + 1],
                                   1024, body);
}

// The unified probe apply: production scalar pass (zeroes y) + cubic pass.
struct CubicOperator {
  std::vector<MfElem> iso_elems;
  std::vector<int> iso_off;
  Hex8Stiffness Ke_iso;  // unit-modulus isotropic block (factor = per-voxel E)
  std::vector<CubElem> cub_elems;
  std::vector<int> cub_off;
  RefBlocks blocks;

  void apply_full(const std::vector<double>& x, std::vector<double>& y) const {
    fea_detail::mf_apply_full(iso_elems, iso_off, Ke_iso, x, y);
    cubic_apply_add(cub_elems, cub_off, blocks, x, y);
  }
};

// ---------------------------------------------------------------------------
// Mixed fixture: a beam grid with a void pocket, an isotropic (graded) region
// and a lattice band carrying real octet tensors. Clamped at x=0, loaded -z on
// the x=nx face.
// ---------------------------------------------------------------------------
struct Fixture {
  VoxelGrid grid;
  std::vector<double> youngs;   // per-voxel E, 0 on lattice voxels (analyze.cpp)
  std::vector<char> mask;       // lattice voxels
  std::vector<double> c11, c12, c44;
  std::vector<char> active;     // = !mask (for mf_build_elems on the iso list)
  std::vector<DirichletBC> bcs;
  std::vector<NodalLoad> loads;
};

Fixture make_fixture(int nx, int ny, int nz, bool with_void, bool with_soft,
                     double E = 3500.0) {
  Fixture f;
  VoxelGrid& g = f.grid;
  g.nx = nx; g.ny = ny; g.nz = nz;
  g.spacing = 1.7;
  g.tags.assign(static_cast<std::size_t>(nx) * ny * nz, VoxelTag::Interior);

  const std::size_t nv = g.voxel_count();
  f.youngs.assign(nv, 0.0);
  f.mask.assign(nv, 0);
  f.c11.assign(nv, 0.0);
  f.c12.assign(nv, 0.0);
  f.c44.assign(nv, 0.0);

  // Void pocket: an ellipsoid in the last third (genuine Empty voxels).
  const double vx = 0.83 * nx, vy = 0.5 * ny, vz = 0.5 * nz;
  const double rx = 0.10 * nx, ry = 0.28 * ny, rz = 0.28 * nz;
  // Lattice band: middle third of x, interior voxels (not touching the y/z
  // boundary so the load face and clamp face stay isotropic).
  const int lat_lo = nx / 3, lat_hi = 2 * nx / 3;

  std::mt19937 rng(20260730u);
  std::uniform_real_distribution<double> rho_d(0.20, 0.55);
  for (int k = 0; k < nz; ++k)
    for (int j = 0; j < ny; ++j)
      for (int i = 0; i < nx; ++i) {
        const std::size_t e = g.index(i, j, k);
        if (with_void) {
          const double dx = (i + 0.5 - vx) / rx, dy = (j + 0.5 - vy) / ry,
                       dz = (k + 0.5 - vz) / rz;
          if (dx * dx + dy * dy + dz * dz < 1.0) {
            g.tags[e] = VoxelTag::Empty;
            continue;
          }
        }
        if (i >= lat_lo && i < lat_hi) {
          f.mask[e] = 1;
          const double rho = rho_d(rng);
          const CubicTensor T =
              lattice_cubic_tensor(LatticeTopology::Octet, rho, E);
          f.c11[e] = T.C11;
          f.c12[e] = T.C12;
          f.c44[e] = T.C44;
        } else {
          // Graded isotropic: solid near the clamp; when requested, two full
          // SIMP-soft planes (the production rho_min^p = 1e-9 contrast) leave
          // the loaded distal block hanging on near-void material — the
          // near-rigid-mode stagnation disease the accelerators exist for.
          double ev = E;
          if (with_soft && i > lat_hi) {
            const bool soft_plane = (i == lat_hi + 2 || i == lat_hi + 3);
            ev = soft_plane
                     ? E * 1e-9
                     : E * (0.4 + 0.6 * ((i + 2 * j + 3 * k) % 5) / 4.0);
          }
          f.youngs[e] = ev;
        }
      }

  f.active.assign(nv, 1);
  for (std::size_t e = 0; e < nv; ++e) f.active[e] = f.mask[e] ? 0 : 1;

  // Clamp every node of the x=0 plane; load -z on every node of the x=nx plane.
  std::set<int> clamped, loaded;
  for (int k = 0; k < nz; ++k)
    for (int j = 0; j < ny; ++j) {
      if (g.solid(0, j, k)) {
        const std::array<int, 8> en = fea_element_nodes(g, 0, j, k);
        for (int a : {0, 3, 4, 7}) clamped.insert(en[a]);  // xi = -1 corners
      }
      if (g.solid(nx - 1, j, k)) {
        const std::array<int, 8> en = fea_element_nodes(g, nx - 1, j, k);
        for (int a : {1, 2, 5, 6}) loaded.insert(en[a]);  // xi = +1 corners
      }
    }
  for (int n : clamped)
    for (int c = 0; c < 3; ++c) f.bcs.push_back({n, c, 0.0});
  for (int n : loaded) f.loads.push_back({n, 2, -10.0 / loaded.size()});
  return f;
}

// Assemble the FULL (unreduced) composite stiffness exactly as
// assemble_reduced_lattice does per element: lattice voxel -> full cubic
// element; else factor * K_unit_iso. Returns ndof x ndof sparse K.
SpMat assemble_full_lattice(const Fixture& f, double poisson) {
  const VoxelGrid& g = f.grid;
  const int ndof = 3 * fea_node_count(g);
  const Hex8Stiffness Ke_iso = hex8_stiffness(1.0, poisson, g.spacing);
  std::vector<Trip> trips;
  trips.reserve(g.solid_count() * 576);
  for (int k = 0; k < g.nz; ++k)
    for (int j = 0; j < g.ny; ++j)
      for (int i = 0; i < g.nx; ++i) {
        if (!g.solid(i, j, k)) continue;
        const std::size_t e = g.index(i, j, k);
        const std::array<int, 8> en = fea_element_nodes(g, i, j, k);
        int edof[24];
        for (int a = 0; a < 8; ++a)
          for (int c = 0; c < 3; ++c) edof[3 * a + c] = 3 * en[a] + c;
        if (f.mask[e]) {
          const Hex8Stiffness Kc =
              hex8_stiffness_cubic(f.c11[e], f.c12[e], f.c44[e], g.spacing);
          for (int r = 0; r < 24; ++r)
            for (int c = 0; c < 24; ++c)
              trips.emplace_back(edof[r], edof[c], Kc(r, c));
        } else {
          const double factor = f.youngs[e];
          for (int r = 0; r < 24; ++r)
            for (int c = 0; c < 24; ++c)
              trips.emplace_back(edof[r], edof[c], factor * Ke_iso(r, c));
        }
      }
  SpMat K(ndof, ndof);
  K.setFromTriplets(trips.begin(), trips.end());
  return K;
}

// Build the probe cubic operator for a fixture (production scalar element table
// + probe cubic table + reference blocks).
CubicOperator build_cubic_operator(const Fixture& f, double poisson) {
  CubicOperator op;
  op.Ke_iso = hex8_stiffness(1.0, poisson, f.grid.spacing);
  op.iso_elems = fea_detail::mf_build_elems(f.grid, &f.youngs,
                                            "matfree_cubic_probe", &op.iso_off,
                                            &f.active);
  op.cub_elems =
      build_cubic_elems(f.grid, f.mask, f.c11, f.c12, f.c44, &op.cub_off);
  op.blocks = build_ref_blocks(f.grid.spacing);
  return op;
}

// ---------------------------------------------------------------------------
// Probe reduced system + Jacobi-CG mirroring mf_build_reduced / mf_cg_solve,
// with the operator pluggable and OPTIONAL additive corrections (the shape
// every accelerator on the production Jacobi-CG uses).
// ---------------------------------------------------------------------------
struct ProbeReduced {
  CubicOperator op;
  int ndof = 0, ng = 0;
  std::vector<int> kept_global;
  std::vector<double> rg, invdiag;
  mutable std::vector<double> xfull, yfull;

  void apply_kgg(const double* xg, double* yg) const {
    std::fill(xfull.begin(), xfull.end(), 0.0);
    for (int k = 0; k < ng; ++k)
      xfull[static_cast<std::size_t>(kept_global[k])] = xg[k];
    op.apply_full(xfull, yfull);
    for (int k = 0; k < ng; ++k)
      yg[k] = yfull[static_cast<std::size_t>(kept_global[k])];
  }
};

ProbeReduced build_probe_reduced(const Fixture& f, double poisson) {
  ProbeReduced m;
  m.op = build_cubic_operator(f, poisson);
  const int ndof = 3 * fea_node_count(f.grid);
  m.ndof = ndof;
  m.xfull.assign(ndof, 0.0);
  m.yfull.assign(ndof, 0.0);

  std::vector<char> fixed(ndof, 0);
  for (const DirichletBC& bc : f.bcs) fixed[3 * bc.node + bc.component] = 1;
  std::vector<double> rhs(ndof, 0.0);
  for (const NodalLoad& l : f.loads) rhs[3 * l.node + l.component] += l.value;

  // Touched + Jacobi diagonal over BOTH element lists (the cubic diagonal is
  // a*KA(r,r) + b*KB(r,r) + c*KC(r,r); KB's diagonal is zero but is kept in the
  // sum for the structural point).
  std::vector<char> touched(ndof, 0);
  std::vector<double> diag(ndof, 0.0);
  for (const MfElem& el : m.op.iso_elems)
    for (int r = 0; r < kDof; ++r) {
      touched[el.edof[r]] = 1;
      diag[el.edof[r]] += el.factor * m.op.Ke_iso(r, r);
    }
  for (const CubElem& el : m.op.cub_elems)
    for (int r = 0; r < kDof; ++r) {
      touched[el.edof[r]] = 1;
      diag[el.edof[r]] += el.a * m.op.blocks.KA(r, r) +
                          el.b * m.op.blocks.KB(r, r) +
                          el.c * m.op.blocks.KC(r, r);
    }
  for (int d = 0; d < ndof; ++d) {
    if (fixed[d] || !touched[d]) continue;
    m.kept_global.push_back(d);
  }
  m.ng = static_cast<int>(m.kept_global.size());
  m.rg.resize(m.ng);
  m.invdiag.resize(m.ng);
  for (int k = 0; k < m.ng; ++k) {
    m.rg[k] = rhs[m.kept_global[k]];
    m.invdiag[k] = 1.0 / diag[m.kept_global[k]];
  }
  return m;
}

// Additive correction hook: z += C(r) applied after the base preconditioner —
// the exact shape recycle/GenEO corrections use on the production loop. `base`
// replaces the Jacobi preconditioner when set (the multigrid case).
struct ProbeCgResult {
  int iters = 0;
  double error = 0.0;
  bool converged = false;
};
ProbeCgResult probe_cg(
    const ProbeReduced& m, double tol, int max_iters, std::vector<double>& x,
    fea_detail::RecycleSession* recycle = nullptr,
    const std::function<void(const double*, double*)>& extra = nullptr,
    const std::function<void(const double*, double*)>& base = nullptr) {
  const int n = m.ng;
  auto dot = [n](const std::vector<double>& a, const std::vector<double>& b) {
    double s = 0.0;
    for (int i = 0; i < n; ++i) s += a[i] * b[i];
    return s;
  };
  auto precond = [&](const std::vector<double>& r, std::vector<double>& z) {
    if (base) {
      base(r.data(), z.data());
    } else {
      for (int i = 0; i < n; ++i) z[i] = m.invdiag[i] * r[i];
    }
    if (recycle) recycle->augment(r.data(), z.data());
    if (extra) extra(r.data(), z.data());
  };

  ProbeCgResult out;
  double rhsNorm2 = dot(m.rg, m.rg);
  if (rhsNorm2 == 0.0) { std::fill(x.begin(), x.end(), 0.0); out.converged = true; return out; }
  const double considerAsZero = std::numeric_limits<double>::min();
  double threshold = tol * tol * rhsNorm2;
  if (threshold < considerAsZero) threshold = considerAsZero;

  std::vector<double> residual(n), tmp(n);
  m.apply_kgg(x.data(), tmp.data());
  for (int i = 0; i < n; ++i) residual[i] = m.rg[i] - tmp[i];
  double residualNorm2 = dot(residual, residual);
  if (residualNorm2 < threshold) {
    out.error = std::sqrt(residualNorm2 / rhsNorm2);
    out.converged = true;
    return out;
  }
  std::vector<double> p(n), z(n);
  precond(residual, p);
  double absNew = dot(residual, p);
  int i = 0;
  while (i < max_iters) {
    m.apply_kgg(p.data(), tmp.data());
    if (recycle) recycle->observe(i, p.data(), tmp.data());
    const double alpha = absNew / dot(p, tmp);
    for (int q = 0; q < n; ++q) {
      x[q] += alpha * p[q];
      residual[q] -= alpha * tmp[q];
    }
    residualNorm2 = dot(residual, residual);
    if (residualNorm2 < threshold) break;
    precond(residual, z);
    const double absOld = absNew;
    absNew = dot(residual, z);
    const double beta = absNew / absOld;
    for (int q = 0; q < n; ++q) p[q] = z[q] + beta * p[q];
    ++i;
  }
  out.error = std::sqrt(residualNorm2 / rhsNorm2);
  out.iters = i;
  out.converged = out.error <= tol;
  if (out.converged && recycle) recycle->commit();
  return out;
}

double now_ms() {
  return std::chrono::duration<double, std::milli>(
             std::chrono::steady_clock::now().time_since_epoch())
      .count();
}

// ===========================================================================
// d1 — THE DECOMPOSITION IS EXACT
// ===========================================================================
int run_d1(const std::string& ev) {
  std::printf("=== d1: three-block decomposition exactness ===\n");
  FILE* csv = open_csv(ev, "d1_decomposition.csv");
  std::fprintf(csv, "source,C11,C12,C44,h,rel_err,integrator_bitmatch\n");

  double worst = 0.0;
  double worst_c11 = 0, worst_c12 = 0, worst_c44 = 0, worst_h = 0;
  long long n_cases = 0, n_bitmatch = 0;

  const double hs[4] = {0.5, 1.0, 1.7, 2.31};
  auto check = [&](const char* src, double C11, double C12, double C44,
                   double h, const RefBlocks& B) {
    const Hex8Stiffness Kc = hex8_stiffness_cubic(C11, C12, C44, h);
    // sanity: the harness integrator IS the production integrator
    double Dm[6][6] = {};
    Dm[0][0] = Dm[1][1] = Dm[2][2] = C11;
    Dm[0][1] = Dm[0][2] = Dm[1][0] = Dm[1][2] = Dm[2][0] = Dm[2][1] = C12;
    Dm[3][3] = Dm[4][4] = Dm[5][5] = C44;
    const Hex8Stiffness Kref = integrate_hex8_ref(Dm, h);
    const bool bitmatch =
        std::memcmp(Kc.k.data(), Kref.k.data(), sizeof(double) * 576) == 0;
    if (bitmatch) ++n_bitmatch;

    double scale = 0.0, err = 0.0;
    for (int t = 0; t < 576; ++t) {
      const double comb = C11 * B.KA.k[t] + C12 * B.KB.k[t] + C44 * B.KC.k[t];
      scale = std::max(scale, std::fabs(Kc.k[t]));
      err = std::max(err, std::fabs(Kc.k[t] - comb));
    }
    const double rel = err / scale;
    std::fprintf(csv, "%s,%.17g,%.17g,%.17g,%g,%.3e,%d\n", src, C11, C12, C44,
                 h, rel, bitmatch ? 1 : 0);
    if (rel > worst) {
      worst = rel;
      worst_c11 = C11; worst_c12 = C12; worst_c44 = C44; worst_h = h;
    }
    ++n_cases;
  };

  // 1. Every certifiable topology's measured band, both modulus scales.
  const LatticeTopology topos[7] = {
      LatticeTopology::Octet,   LatticeTopology::SimpleCubic,
      LatticeTopology::Bcc,     LatticeTopology::Fcc,
      LatticeTopology::Diamond, LatticeTopology::Kelvin,
      LatticeTopology::Rhombic};
  for (double h : hs) {
    const RefBlocks B = build_ref_blocks(h);
    for (LatticeTopology t : topos) {
      const double lo = lattice_rho_min(t), hi = lattice_rho_max(t);
      for (int s = 0; s < 12; ++s) {
        const double rho = lo + (hi - lo) * s / 11.0;
        for (double E : {1.0, 3500.0}) {
          const CubicTensor T = lattice_cubic_tensor(t, rho, E);
          check(lattice_topology_name(t), T.C11, T.C12, T.C44, h, B);
        }
      }
    }
    // 2. Random admissible tensors across magnitudes (fixed seed), incl.
    //    negative C12 down to the admissibility edge.
    std::mt19937 rng(7301u);
    std::uniform_real_distribution<double> lg(-3.0, 4.0);
    std::uniform_real_distribution<double> ratio12(-0.49, 0.98);
    std::uniform_real_distribution<double> lg44(-2.0, 1.0);
    for (int s = 0; s < 2000; ++s) {
      const double C11 = std::pow(10.0, lg(rng));
      const double C12 = C11 * ratio12(rng);
      const double C44 = C11 * std::pow(10.0, lg44(rng));
      check("random", C11, C12, C44, h, B);
    }
    // 3. The isotropic special case: D_iso == cubic(c(1-nu), c*nu, G).
    for (double E : {1.0, 3500.0})
      for (double nu : {0.05, 0.3, 0.45}) {
        const double cc = E / ((1.0 + nu) * (1.0 - 2.0 * nu));
        check("iso", cc * (1.0 - nu), cc * nu, E / (2.0 * (1.0 + nu)), h, B);
      }
  }
  std::fclose(csv);

  std::printf("cases: %lld  integrator bit-match (informational): %lld/%lld\n",
              n_cases, n_bitmatch, n_cases);
  std::printf("worst relative error: %.3e at C11=%.6g C12=%.6g C44=%.6g h=%g\n",
              worst, worst_c11, worst_c12, worst_c44, worst_h);
  const bool pass = worst <= 1e-13;
  std::printf("d1: %s (bar: worst rel err <= 1e-13)\n", pass ? "PASS" : "FAIL");
  return pass ? 0 : 1;
}

// ===========================================================================
// d2 — MATRIX-FREE CUBIC APPLY == ASSEMBLED OPERATOR (and the solve matches
//      fea_solve_cg_lattice)
// ===========================================================================
int run_d2(const std::string& ev) {
  std::printf("=== d2: matrix-free cubic apply vs assembled operator ===\n");
  const double nu = 0.3;
  Fixture f = make_fixture(24, 12, 12, /*void*/ true, /*soft*/ false);
  const int ndof = 3 * fea_node_count(f.grid);
  std::printf("fixture: %dx%dx%d, solid %zu (lattice %zu), ndof %d\n",
              f.grid.nx, f.grid.ny, f.grid.nz, f.grid.solid_count(),
              static_cast<std::size_t>(
                  std::count(f.mask.begin(), f.mask.end(), char(1))),
              ndof);

  const SpMat K = assemble_full_lattice(f, nu);
  const CubicOperator op = build_cubic_operator(f, nu);

  FILE* csv = open_csv(ev, "d2_operator_match.csv");
  std::fprintf(csv, "trial,threads,rel_l2,rel_max\n");
  std::mt19937 rng(424242u);
  std::normal_distribution<double> nd(0.0, 1.0);
  double worst_rel = 0.0;
  for (int trial = 0; trial < 10; ++trial) {
    std::vector<double> x(ndof), y_mf(ndof, 0.0);
    for (double& v : x) v = nd(rng);
    Eigen::Map<const Eigen::VectorXd> xe(x.data(), ndof);
    const Eigen::VectorXd y_asm = K * xe;
    op.apply_full(x, y_mf);
    double num = 0, den = 0, mx = 0, scale = 0;
    for (int d = 0; d < ndof; ++d) {
      const double diff = y_mf[d] - y_asm[d];
      num += diff * diff;
      den += y_asm[d] * y_asm[d];
      mx = std::max(mx, std::fabs(diff));
      scale = std::max(scale, std::fabs(y_asm[d]));
    }
    const double rel_l2 = std::sqrt(num / den), rel_max = mx / scale;
    std::fprintf(csv, "%d,default,%.3e,%.3e\n", trial, rel_l2, rel_max);
    worst_rel = std::max(worst_rel, std::max(rel_l2, rel_max));
  }

  // Thread-count determinism of the cubic pass: 1 vs 4 vs 8 bit-identical.
  bool det_ok = true;
  {
    std::vector<double> x(ndof);
    for (double& v : x) v = nd(rng);
    std::vector<double> y1(ndof, 0.0), yt(ndof, 0.0);
    const int prev = fea_detail::mf_set_thread_count(1);
    op.apply_full(x, y1);
    for (int t : {4, 8}) {
      fea_detail::mf_set_thread_count(t);
      op.apply_full(x, yt);
      if (std::memcmp(y1.data(), yt.data(), sizeof(double) * ndof) != 0)
        det_ok = false;
    }
    fea_detail::mf_set_thread_count(prev);
  }
  std::fclose(csv);
  std::printf("worst apply rel diff: %.3e (bar <= 1e-12); thread determinism: %s\n",
              worst_rel, det_ok ? "bit-identical 1/4/8" : "MISMATCH");

  // Solve: probe cubic Jacobi-CG vs the PRODUCTION fea_solve_cg_lattice.
  const double tol = 1e-10;
  CgInfo info;
  const FeaSolution ref = fea_solve_cg_lattice(
      f.grid, f.youngs, f.mask, f.c11, f.c12, f.c44, nu, f.bcs, f.loads, tol,
      200000, &info);
  ProbeReduced m = build_probe_reduced(f, nu);
  std::vector<double> xg(m.ng, 0.0);
  const ProbeCgResult r = probe_cg(m, tol, 200000, xg);
  std::vector<double> u(ndof, 0.0);
  for (int k = 0; k < m.ng; ++k) u[m.kept_global[k]] = xg[k];
  double num = 0, den = 0;
  for (int d = 0; d < ndof; ++d) {
    const double diff = u[d] - ref.u[d];
    num += diff * diff;
    den += ref.u[d] * ref.u[d];
  }
  const double rel_u = std::sqrt(num / den);
  std::printf("solve: production lattice CG %d iters; probe matrix-free cubic CG"
              " %d iters (converged=%d); field rel L2 diff %.3e\n",
              info.iterations, r.iters, r.converged ? 1 : 0, rel_u);
  const bool pass = worst_rel <= 1e-12 && det_ok && r.converged && rel_u <= 1e-6;
  std::printf("d2: %s\n", pass ? "PASS" : "FAIL");
  return pass ? 0 : 1;
}

// ===========================================================================
// d3 — THE COST RATIO, MEASURED (per-apply, CG-iteration-normalised work)
// ===========================================================================
int run_d3(const std::string& ev) {
  std::printf("=== d3: apply cost, cubic vs scalar kernel ===\n");
  const double nu = 0.3;
  const int n = 64;
  // All-solid grid; SAME grid and voxel count for both kernels.
  Fixture iso = make_fixture(n, n, n, /*void*/ false, /*soft*/ false);
  std::fill(iso.mask.begin(), iso.mask.end(), 0);
  std::fill(iso.active.begin(), iso.active.end(), 1);
  for (std::size_t e = 0; e < iso.youngs.size(); ++e)
    if (iso.youngs[e] == 0.0) iso.youngs[e] = 3500.0;

  Fixture cub = make_fixture(n, n, n, false, false);
  std::fill(cub.mask.begin(), cub.mask.end(), 1);
  std::fill(cub.active.begin(), cub.active.end(), 0);
  {
    const CubicTensor T = lattice_cubic_tensor(LatticeTopology::Octet, 0.3, 3500.0);
    std::fill(cub.c11.begin(), cub.c11.end(), T.C11);
    std::fill(cub.c12.begin(), cub.c12.end(), T.C12);
    std::fill(cub.c44.begin(), cub.c44.end(), T.C44);
    std::fill(cub.youngs.begin(), cub.youngs.end(), 0.0);
  }

  const CubicOperator op_iso = build_cubic_operator(iso, nu);
  const CubicOperator op_cub = build_cubic_operator(cub, nu);
  const int ndof = 3 * fea_node_count(iso.grid);
  std::printf("grid %d^3, %zu elements, ndof %d; iso list %zu, cubic list %zu\n",
              n, iso.grid.solid_count(), ndof, op_iso.iso_elems.size(),
              op_cub.cub_elems.size());

  std::mt19937 rng(99u);
  std::normal_distribution<double> nd(0.0, 1.0);
  std::vector<double> x(ndof), y(ndof, 0.0);
  for (double& v : x) v = nd(rng);

  FILE* csv = open_csv(ev, "d3_apply_cost.csv");
  std::fprintf(csv, "threads,kernel,median_ms,mean_ms,ratio_vs_scalar\n");

  // A probe-side SINGLE-block kernel over the same element set (a = per-voxel
  // E), isolating the 3-block cost from probe-vs-production codegen.
  std::vector<CubElem> scalar_elems;
  std::vector<int> scalar_off;
  {
    std::vector<double> cE(iso.grid.voxel_count(), 3500.0), z0(cE.size(), 0.0);
    std::vector<char> all(iso.grid.voxel_count(), 1);
    scalar_elems = build_cubic_elems(iso.grid, all, cE, z0, z0, &scalar_off);
    for (CubElem& el : scalar_elems) el.a = 3500.0;
  }
  const Hex8Stiffness Ke_unit = hex8_stiffness(1.0, nu, iso.grid.spacing);

  auto bench = [&](const std::function<void()>& apply) {
    for (int w = 0; w < 5; ++w) apply();
    std::vector<double> ts;
    for (int rep = 0; rep < 30; ++rep) {
      const double t0 = now_ms();
      apply();
      ts.push_back(now_ms() - t0);
    }
    std::sort(ts.begin(), ts.end());
    double mean = 0;
    for (double t : ts) mean += t;
    mean /= ts.size();
    return std::pair<double, double>(ts[ts.size() / 2], mean);
  };

  // Correctness of the combined-block variant vs the (d2-verified) 3-acc kernel.
  {
    std::vector<double> y3(ndof, 0.0), yc(ndof, 0.0);
    op_cub.apply_full(x, y3);
    cubic_apply_combined(op_cub.cub_elems, op_cub.cub_off, op_cub.blocks, x, yc);
    double mx = 0, scale = 0;
    for (int d = 0; d < ndof; ++d) {
      mx = std::max(mx, std::fabs(y3[d] - yc[d]));
      scale = std::max(scale, std::fabs(y3[d]));
    }
    std::printf("combined-block vs 3-acc kernel: rel max diff %.3e\n", mx / scale);
  }

  int rc = 0;
  for (int threads : {1, 0}) {  // 0 = auto (production default)
    const int prev = fea_detail::mf_set_thread_count(threads);
    const int eff = fea_detail::mf_thread_count();
    const auto s = bench([&] { op_iso.apply_full(x, y); });   // production scalar
    const auto sp = bench([&] {                               // probe scalar
      scalar_probe_apply(scalar_elems, scalar_off, Ke_unit, x, y);
    });
    const auto c = bench([&] { op_cub.apply_full(x, y); });   // probe cubic
    const auto cb = bench([&] {                               // combined-block variant
      cubic_apply_combined(op_cub.cub_elems, op_cub.cub_off, op_cub.blocks, x, y);
    });
    const double ratio_prod = c.first / s.first;
    const double ratio_probe = c.first / sp.first;
    std::fprintf(csv, "%d,scalar_production,%.4f,%.4f,1.0\n", eff, s.first, s.second);
    std::fprintf(csv, "%d,scalar_probe,%.4f,%.4f,%.3f\n", eff, sp.first, sp.second,
                 sp.first / s.first);
    std::fprintf(csv, "%d,cubic_probe,%.4f,%.4f,%.3f\n", eff, c.first, c.second,
                 ratio_prod);
    std::fprintf(csv, "%d,cubic_combined,%.4f,%.4f,%.3f\n", eff, cb.first,
                 cb.second, cb.first / s.first);
    std::printf("threads=%d: production scalar %.3f ms, probe scalar %.3f ms "
                "(parity %.2fx), cubic(3-acc) %.3f ms, cubic(combined) %.3f ms "
                "-> %.2fx / %.2fx vs production scalar\n",
                eff, s.first, sp.first, sp.first / s.first, c.first, cb.first,
                ratio_prod, cb.first / s.first);
    (void)ratio_probe;
    fea_detail::mf_set_thread_count(prev);
  }
  std::fclose(csv);
  std::printf("d3: measured (predicted ~3x; see handoff for interpretation)\n");
  return rc;
}

// ===========================================================================
// d4 — SPD + THE ACCELERATORS STILL ENGAGE
// ===========================================================================

// Trilinear 2:1 coarsening P over the kept DOFs (multigrid-family two-level).
SpMat build_coarsen_P(const Fixture& f, const ProbeReduced& m) {
  const VoxelGrid& g = f.grid;
  const int Nx = g.nx + 1, Ny = g.ny + 1, Nz = g.nz + 1;
  const int Cx = (Nx + 1) / 2, Cy = (Ny + 1) / 2, Cz = (Nz + 1) / 2;
  auto cid = [&](int i, int j, int k) { return (k * Cy + j) * Cx + i; };
  std::vector<Trip> trips;
  std::vector<int> kept_of_dof(m.ndof, -1);
  for (int k = 0; k < m.ng; ++k) kept_of_dof[m.kept_global[k]] = k;
  for (int k = 0; k < Nz; ++k)
    for (int j = 0; j < Ny; ++j)
      for (int i = 0; i < Nx; ++i) {
        const int node = fea_node_index(g, i, j, k);
        struct W { int c; double w; };
        auto axis = [](int v, int n, W* out) {
          if (v % 2 == 0) { out[0] = {v / 2, 1.0}; return 1; }
          int cnt = 0;
          out[cnt++] = {(v - 1) / 2, 0.5};
          if ((v + 1) / 2 < (n + 1) / 2) out[cnt++] = {(v + 1) / 2, 0.5};
          return cnt;
        };
        W wi[2], wj[2], wk[2];
        const int ni = axis(i, Nx, wi), nj = axis(j, Ny, wj), nk_ = axis(k, Nz, wk);
        for (int a = 0; a < ni; ++a)
          for (int b = 0; b < nj; ++b)
            for (int c = 0; c < nk_; ++c) {
              const double w = wi[a].w * wj[b].w * wk[c].w;
              const int cnode = cid(wi[a].c, wj[b].c, wk[c].c);
              for (int comp = 0; comp < 3; ++comp) {
                const int kd = kept_of_dof[3 * node + comp];
                if (kd >= 0)
                  trips.emplace_back(kd, 3 * cnode + comp, w);
              }
            }
      }
  SpMat P(m.ng, 3 * Cx * Cy * Cz);
  P.setFromTriplets(trips.begin(), trips.end());
  // Drop empty coarse columns (support entirely fixed/void).
  std::vector<int> colmap(P.cols(), -1);
  int nc = 0;
  for (int c = 0; c < P.cols(); ++c)
    if (P.col(c).nonZeros() > 0) colmap[c] = nc++;
  std::vector<Trip> t2;
  for (int c = 0; c < P.outerSize(); ++c)
    for (SpMat::InnerIterator it(P, c); it; ++it)
      t2.emplace_back(it.row(), colmap[c], it.value());
  SpMat P2(m.ng, nc);
  P2.setFromTriplets(t2.begin(), t2.end());
  return P2;
}

int run_d4(const std::string& ev) {
  std::printf("=== d4: SPD + accelerators on the cubic matrix-free path ===\n");
  const double nu = 0.3;
  // Genuine void/lattice/solid contrast incl. SIMP-soft (1e-9) voxels.
  Fixture f = make_fixture(24, 12, 12, /*void*/ true, /*soft*/ true);
  ProbeReduced m = build_probe_reduced(f, nu);
  std::printf("fixture: %dx%dx%d ng=%d (void pocket + octet band + soft 1e-9 shells)\n",
              f.grid.nx, f.grid.ny, f.grid.nz, m.ng);

  // --- SPD, established on the assembled reduced operator ------------------
  const SpMat Kfull = assemble_full_lattice(f, nu);
  std::vector<Trip> trips;
  std::vector<int> kept_of_dof(m.ndof, -1);
  for (int k = 0; k < m.ng; ++k) kept_of_dof[m.kept_global[k]] = k;
  for (int c = 0; c < Kfull.outerSize(); ++c)
    for (SpMat::InnerIterator it(Kfull, c); it; ++it) {
      const int r2 = kept_of_dof[it.row()], c2 = kept_of_dof[it.col()];
      if (r2 >= 0 && c2 >= 0) trips.emplace_back(r2, c2, it.value());
    }
  SpMat Kgg(m.ng, m.ng);
  Kgg.setFromTriplets(trips.begin(), trips.end());
  double asym = 0.0;
  {
    SpMat KT = SpMat(Kgg.transpose());
    SpMat Dm = Kgg - KT;
    for (int c = 0; c < Dm.outerSize(); ++c)
      for (SpMat::InnerIterator it(Dm, c); it; ++it)
        asym = std::max(asym, std::fabs(it.value()));
  }
  Eigen::SimplicialLDLT<SpMat> ldlt(Kgg);
  double dmin = std::numeric_limits<double>::max(), dmax = 0.0;
  {
    const Eigen::VectorXd D = ldlt.vectorD();
    for (int i = 0; i < D.size(); ++i) {
      dmin = std::min(dmin, D[i]);
      dmax = std::max(dmax, D[i]);
    }
  }
  std::printf("SPD: max |K-K^T| = %.3e; LDLT pivots in [%.3e, %.3e] (all > 0: %s)\n",
              asym, dmin, dmax, dmin > 0 ? "yes" : "NO");
  const bool spd_ok = (ldlt.info() == Eigen::Success) && dmin > 0.0;

  FILE* csv = open_csv(ev, "d4_accelerators.csv");
  std::fprintf(csv, "config,solve,iters,converged\n");
  const double tol = 1e-8;
  const int cap = 400000;

  // --- baseline Jacobi-CG ---------------------------------------------------
  std::vector<double> x0(m.ng, 0.0);
  const ProbeCgResult base = probe_cg(m, tol, cap, x0);
  std::fprintf(csv, "jacobi,0,%d,%d\n", base.iters, base.converged);
  std::printf("baseline Jacobi-CG: %d iters (converged=%d)\n", base.iters,
              base.converged);

  // --- PRODUCTION Krylov recycling on a solve sequence ---------------------
  // The sequence perturbs the ISO moduli (an optimizer-like drift); the cubic
  // band stays fixed. RecycleSession is the production class, operator-agnostic.
  auto sequence = [&](bool with_recycle) {
    fea_reset_krylov_recycle_space();
    const bool prev = fea_set_krylov_recycling(with_recycle);
    std::vector<int> iters;
    for (int s = 0; s < 4; ++s) {
      Fixture fs = f;
      for (std::size_t e = 0; e < fs.youngs.size(); ++e)
        if (fs.youngs[e] > 0.0)
          fs.youngs[e] *= 1.0 + 0.01 * s * std::sin(0.37 * static_cast<double>(e % 97));
      ProbeReduced ms = build_probe_reduced(fs, nu);
      std::vector<double> xs(ms.ng, 0.0);
      fea_detail::RecycleSession rec(
          ms.ng, ms.invdiag.data(),
          [&ms](const double* xi, double* yo) { ms.apply_kgg(xi, yo); });
      const ProbeCgResult r = probe_cg(ms, tol, cap, xs, &rec);
      iters.push_back(r.converged ? r.iters : -1);
    }
    fea_set_krylov_recycling(prev);
    fea_reset_krylov_recycle_space();
    return iters;
  };
  const std::vector<int> seq_off = sequence(false);
  const std::vector<int> seq_on = sequence(true);
  std::printf("recycling (production RecycleSession), 4-solve sequence:\n");
  for (int s = 0; s < 4; ++s) {
    std::printf("  solve %d: off %d  on %d\n", s, seq_off[s], seq_on[s]);
    std::fprintf(csv, "recycle_off,%d,%d,1\n", s, seq_off[s]);
    std::fprintf(csv, "recycle_on,%d,%d,1\n", s, seq_on[s]);
  }

  // --- two-level Galerkin coarse correction (multigrid family) -------------
  const SpMat P = build_coarsen_P(f, m);
  const SpMat Ac = SpMat(P.transpose()) * Kgg * P;
  Eigen::SimplicialLDLT<SpMat> ldltc(Ac);
  std::printf("Galerkin coarse: %ld coarse DOFs, LDLT %s\n",
              static_cast<long>(Ac.rows()),
              ldltc.info() == Eigen::Success ? "ok" : "FAILED");
  // symmetric two-level V(1,1), damped Jacobi smoother — SPD preconditioner
  const double omega = 0.5;
  auto vcycle = [&](const double* r, double* z) {
    Eigen::Map<const Eigen::VectorXd> rv(r, m.ng);
    Eigen::VectorXd zv(m.ng);
    for (int i = 0; i < m.ng; ++i) zv[i] = omega * m.invdiag[i] * rv[i];
    Eigen::VectorXd r1 = rv - Kgg * zv;
    zv += P * ldltc.solve(SpMat(P.transpose()) * r1);
    Eigen::VectorXd r2 = rv - Kgg * zv;
    for (int i = 0; i < m.ng; ++i) zv[i] += omega * m.invdiag[i] * r2[i];
    Eigen::Map<Eigen::VectorXd>(z, m.ng) = zv;
  };
  std::vector<double> xmg(m.ng, 0.0);
  const ProbeCgResult mg = probe_cg(m, tol, cap, xmg, nullptr, nullptr, vcycle);
  std::fprintf(csv, "two_level_galerkin,0,%d,%d\n", mg.iters, mg.converged);
  std::printf("two-level Galerkin MG-CG: %d iters (converged=%d) vs %d Jacobi\n",
              mg.iters, mg.converged, base.iters);

  // --- GenEO spectral coarse space (the PRODUCTION pencil) -----------------
  // Mirrors geneo.cpp's formulation with the local operator assembled from the
  // TRUE composite blocks (iso factor*K0 + cubic 3-block): per overlapped
  // subdomain the NEUMANN local matrix A_i (element blocks of every element in
  // the overlapped tile, only globally-eliminated DOFs dropped), the GenEO
  // pencil  A_i v = lambda (D_i A_i D_i) v  with D_i the partition-of-unity
  // weights, modes below kGeneoLambdaCut = 0.05, coarse column = D_i * v.
  // Correction: z += V (V^T A V)^-1 V^T r against the TRUE global operator.
  // (geneo.cpp's own build_local reads scalar moduli + the single iso K0, so
  // production would need this same 3-block extension there — see the handoff.)
  std::vector<Eigen::VectorXd> Vcols;
  {
    const VoxelGrid& g = f.grid;
    const char* ce = std::getenv("MC_CORE");
    const char* oe = std::getenv("MC_OV");
    // kGeneoCoreCells = 8, kGeneoOverlap = 1: the ARMED production tiling.
    const int core = ce ? std::atoi(ce) : 8, ov = oe ? std::atoi(oe) : 1;
    const Hex8Stiffness Ke_iso = hex8_stiffness(1.0, nu, g.spacing);
    const RefBlocks& RB = m.op.blocks;
    struct Sub { int i0, i1, j0, j1, k0, k1; };
    std::vector<Sub> subs;
    for (int k0 = 0; k0 < g.nz; k0 += core)
      for (int j0 = 0; j0 < g.ny; j0 += core)
        for (int i0 = 0; i0 < g.nx; i0 += core)
          subs.push_back({std::max(0, i0 - ov), std::min(g.nx, i0 + core + ov),
                          std::max(0, j0 - ov), std::min(g.ny, j0 + core + ov),
                          std::max(0, k0 - ov), std::min(g.nz, k0 + core + ov)});
    // Kept-DOF list of each overlapped tile + the Boolean PoU (1/cover).
    auto sub_kept = [&](const Sub& s, std::vector<int>& kd) {
      std::set<int> dofs;
      for (int k = s.k0; k < s.k1; ++k)
        for (int j = s.j0; j < s.j1; ++j)
          for (int i = s.i0; i < s.i1; ++i) {
            if (!g.solid(i, j, k)) continue;
            const std::array<int, 8> en = fea_element_nodes(g, i, j, k);
            for (int a = 0; a < 8; ++a)
              for (int c = 0; c < 3; ++c) {
                const int kd2 = kept_of_dof[3 * en[a] + c];
                if (kd2 >= 0) dofs.insert(kd2);
              }
          }
      kd.assign(dofs.begin(), dofs.end());
    };
    std::vector<int> cover(m.ng, 0);
    for (const Sub& s : subs) {
      std::vector<int> kd;
      sub_kept(s, kd);
      for (int d : kd) ++cover[d];
    }
    const double cut = 0.05;  // kGeneoLambdaCut
    const int block_m = 20;   // kGeneoBlockM mode cap per subdomain
    int total_modes = 0;
    for (const Sub& s : subs) {
      std::vector<int> kd;
      sub_kept(s, kd);
      const int nl = static_cast<int>(kd.size());
      if (nl < 24) continue;
      std::vector<int> local_of(m.ng, -1);
      for (int t = 0; t < nl; ++t) local_of[kd[t]] = t;
      // Neumann local matrix from the composite element blocks.
      Eigen::MatrixXd Al = Eigen::MatrixXd::Zero(nl, nl);
      for (int k = s.k0; k < s.k1; ++k)
        for (int j = s.j0; j < s.j1; ++j)
          for (int i = s.i0; i < s.i1; ++i) {
            if (!g.solid(i, j, k)) continue;
            const std::size_t e = g.index(i, j, k);
            const std::array<int, 8> en = fea_element_nodes(g, i, j, k);
            int ld[24];
            for (int a = 0; a < 8; ++a)
              for (int c = 0; c < 3; ++c) {
                const int kd2 = kept_of_dof[3 * en[a] + c];
                ld[3 * a + c] = kd2 >= 0 ? local_of[kd2] : -1;
              }
            for (int r = 0; r < 24; ++r) {
              if (ld[r] < 0) continue;
              for (int c = 0; c < 24; ++c) {
                if (ld[c] < 0) continue;
                double kv;
                if (f.mask[e])
                  kv = f.c11[e] * RB.KA(r, c) + f.c12[e] * RB.KB(r, c) +
                       f.c44[e] * RB.KC(r, c);
                else
                  kv = f.youngs[e] * Ke_iso(r, c);
                Al(ld[r], ld[c]) += kv;
              }
            }
          }
      // PoU weights and B = D A D.
      Eigen::VectorXd Dl(nl);
      for (int t = 0; t < nl; ++t) Dl[t] = 1.0 / cover[kd[t]];
      Eigen::MatrixXd B = Dl.asDiagonal() * Al * Dl.asDiagonal();
      // Reduce onto range(B): B = U L U^T, Q = U_keep L_keep^-1/2 (B-orthonormal),
      // then the pencil is the standard problem Q^T A Q y = lambda y.
      Eigen::SelfAdjointEigenSolver<Eigen::MatrixXd> esB(B);
      const double bmax = esB.eigenvalues().maxCoeff();
      std::vector<int> keep;
      for (int q = 0; q < nl; ++q)
        if (esB.eigenvalues()[q] > 1e-12 * bmax) keep.push_back(q);
      if (keep.empty()) continue;
      Eigen::MatrixXd Q(nl, static_cast<int>(keep.size()));
      for (std::size_t t = 0; t < keep.size(); ++t)
        Q.col(t) = esB.eigenvectors().col(keep[t]) /
                   std::sqrt(esB.eigenvalues()[keep[t]]);
      Eigen::MatrixXd Ared = Q.transpose() * Al * Q;
      Ared = 0.5 * (Ared + Ared.transpose());
      Eigen::SelfAdjointEigenSolver<Eigen::MatrixXd> es(Ared);
      int taken = 0;
      for (int q = 0; q < es.eigenvalues().size() && taken < block_m; ++q) {
        if (es.eigenvalues()[q] >= cut) break;
        const Eigen::VectorXd v = Q * es.eigenvectors().col(q);
        Eigen::VectorXd col = Eigen::VectorXd::Zero(m.ng);
        for (int t = 0; t < nl; ++t) col[kd[t]] = Dl[t] * v[t];
        Vcols.push_back(col);
        ++taken;
        ++total_modes;
      }
    }
    std::printf("GenEO coarse space (production pencil): %zu subdomains, "
                "%d modes below cut %.2f\n",
                subs.size(), total_modes, cut);
  }
  ProbeCgResult ge;
  if (!Vcols.empty()) {
    const int Nt = static_cast<int>(Vcols.size());
    Eigen::MatrixXd V(m.ng, Nt);
    for (int q = 0; q < Nt; ++q) V.col(q) = Vcols[q];
    Eigen::MatrixXd AcV = Eigen::MatrixXd(Kgg * V);
    Eigen::MatrixXd Acc = V.transpose() * AcV;
    Acc = 0.5 * (Acc + Acc.transpose());
    Eigen::LDLT<Eigen::MatrixXd> cl(Acc);
    auto geneo_corr = [&](const double* r, double* z) {
      Eigen::Map<const Eigen::VectorXd> rv(r, m.ng);
      Eigen::VectorXd c = cl.solve(V.transpose() * rv);
      Eigen::Map<Eigen::VectorXd> zv(z, m.ng);
      zv += V * c;
    };
    std::vector<double> xg2(m.ng, 0.0);
    ge = probe_cg(m, tol, cap, xg2, nullptr, geneo_corr);
    std::fprintf(csv, "geneo_style,0,%d,%d\n", ge.iters, ge.converged);
    std::printf("GenEO-style two-level (Nt=%d): %d iters (converged=%d) vs %d Jacobi\n",
                Nt, ge.iters, ge.converged, base.iters);
  }
  std::fclose(csv);

  const bool pass = spd_ok && base.converged && mg.converged && mg.iters < base.iters &&
                    ge.converged && ge.iters < base.iters;
  std::printf("d4: %s (SPD + every accelerator family engages and cuts iterations)\n",
              pass ? "PASS" : "FAIL");
  return pass ? 0 : 1;
}

// ===========================================================================
// d5 — ALL-SCALAR IS BIT-IDENTICAL + the memory budget at production scale
// ===========================================================================
int run_d5(const std::string& ev) {
  std::printf("=== d5: all-scalar bit-identity + memory budget ===\n");
  const double nu = 0.3;
  // Graded all-scalar fixture (NO cubic voxels), incl. a void pocket.
  Fixture f = make_fixture(20, 14, 14, /*void*/ true, /*soft*/ true);
  std::fill(f.mask.begin(), f.mask.end(), 0);
  std::fill(f.active.begin(), f.active.end(), 1);
  for (std::size_t e = 0; e < f.youngs.size(); ++e) {
    f.c11[e] = f.c12[e] = f.c44[e] = 0.0;
    if (f.grid.tags[e] != VoxelTag::Empty && f.youngs[e] == 0.0)
      f.youngs[e] = 3500.0;
  }
  const int ndof = 3 * fea_node_count(f.grid);

  // Apply: probe path (cubic list EMPTY) vs production fea_matfree_apply.
  std::mt19937 rng(5u);
  std::normal_distribution<double> nd(0.0, 1.0);
  bool apply_bitid = true;
  const CubicOperator op = build_cubic_operator(f, nu);
  if (op.cub_elems.size() != 0) { std::printf("cubic list not empty!\n"); return 1; }
  for (int trial = 0; trial < 5; ++trial) {
    std::vector<double> x(ndof), y(ndof, 0.0);
    for (double& v : x) v = nd(rng);
    const std::vector<double> yprod = fea_matfree_apply(f.grid, f.youngs, nu, x);
    op.apply_full(x, y);
    if (std::memcmp(y.data(), yprod.data(), sizeof(double) * ndof) != 0)
      apply_bitid = false;
  }
  std::printf("apply, no cubic voxels: %s vs fea_matfree_apply (5 trials)\n",
              apply_bitid ? "BIT-IDENTICAL" : "MISMATCH");

  // Solve: probe CG vs production fea_solve_cg_matfree, bitwise on the field.
  const double tol = 1e-8;
  CgInfo info;
  const FeaSolution ref = fea_solve_cg_matfree(f.grid, f.youngs, nu, f.bcs,
                                               f.loads, tol, 400000, &info);
  ProbeReduced m = build_probe_reduced(f, nu);
  std::vector<double> xg(m.ng, 0.0);
  const ProbeCgResult r = probe_cg(m, tol, 400000, xg);
  std::vector<double> u(ndof, 0.0);
  for (int k = 0; k < m.ng; ++k) u[m.kept_global[k]] = xg[k];
  const bool solve_bitid =
      std::memcmp(u.data(), ref.u.data(), sizeof(double) * ndof) == 0;
  std::printf("solve, no cubic voxels: probe CG %d iters vs production %d; field %s\n",
              r.iters, info.iterations,
              solve_bitid ? "BIT-IDENTICAL" : "differs");

  // Memory budget at the production 8.44M-DOF scale (BLOCKED-STOP check).
  FILE* csv = open_csv(ev, "d5_memory_budget.csv");
  const double dof = 8.44e6;
  const double nodes = dof / 3.0;               // 2.813M nodes
  const double nvox = nodes;                    // elements ~ nodes on a big grid
  const double coeff_arrays = 3.0 * nvox * 8.0; // c11/c12/c44 per-voxel doubles
  const double elem_delta = nvox * (3 * 8.0 - 8.0); // (a,b,c) vs factor, worst case ALL cubic
  const double ref_blocks = 2.0 * 576 * 8.0;    // two EXTRA 24x24 blocks
  std::fprintf(csv, "item,bytes,mb\n");
  std::fprintf(csv, "coeff_arrays_per_voxel,%.0f,%.1f\n", coeff_arrays, coeff_arrays / 1048576.0);
  std::fprintf(csv, "elem_table_delta_all_cubic,%.0f,%.1f\n", elem_delta, elem_delta / 1048576.0);
  std::fprintf(csv, "extra_reference_blocks,%.0f,%.4f\n", ref_blocks, ref_blocks / 1048576.0);
  std::fclose(csv);
  std::printf("memory at 8.44M DOF (%.2fM voxels):\n", nvox / 1e6);
  std::printf("  three per-voxel coefficient arrays: %.1f MB\n", coeff_arrays / 1048576.0);
  std::printf("  element-table delta if ALL voxels cubic (+16 B/elem): %.1f MB\n",
              elem_delta / 1048576.0);
  std::printf("  two extra 24x24 reference blocks: %.1f KB\n", ref_blocks / 1024.0);
  std::printf("  (16 GB machine of record; GenEO basis cap alone is 2048 MB)\n");

  const bool pass = apply_bitid && solve_bitid;
  std::printf("d5: %s\n", pass ? "PASS" : "FAIL");
  return pass ? 0 : 1;
}

}  // namespace

int main(int argc, char** argv) {
  const std::string mode = argc > 1 ? argv[1] : "all";
  const std::string ev = argc > 2 ? argv[2] : ".";
  int rc = 0;
  if (mode == "d1" || mode == "all") rc |= run_d1(ev);
  if (mode == "d2" || mode == "all") rc |= run_d2(ev);
  if (mode == "d3" || mode == "all") rc |= run_d3(ev);
  if (mode == "d4" || mode == "all") rc |= run_d4(ev);
  if (mode == "d5" || mode == "all") rc |= run_d5(ev);
  return rc;
}
