// surface_stiffness_probe — CAN SURFACE GEOMETRY ENTER THE SOLVE?
// (probe, 2026-07-31-surface-stiffness-probe)
//
// PR 253 established the accept gate is FINISH-BLIND: the posture never credits
// the diagrid skin (or the solid shell) because the solve integrates a per-VOXEL
// stiffness field and core has NO surface stiffness representation of any kind.
// This probe asks WHICH route could make surface material representable, and at
// what accuracy/cost — BEFORE anyone writes gate code.
//
//   K1  REFERENCE TRUTH: a 24x24x4 mm plate of octet lattice (cell 4 mm) with
//       the REAL diagrid skin from the production generator, strut-resolved:
//       every emitted element (observer tap) rasterized as a capsule into a fine
//       voxel grid and solved with the PRODUCTION solver. Six grip states:
//       in-plane tension X/Y, in-plane shear XY, through-thickness compression Z,
//       cantilever bending (tip Z), transverse shear ZX. Stiffness measure for
//       EVERY model, fine and coarse: K = 2 U / delta^2 under identical rigid
//       grips (prescribed displacements; U = strain energy).
//   K2  ROUTE A (homogenize into boundary voxels), three representability tiers:
//       A-iso   (isotropic volume-fraction smear — what a scalar modulus bump
//                could express today),
//       A-cubic (the Frobenius-closest CUBIC tensor add — what lat_c11/c12/c44
//                could express today),
//       A-aniso (the full anisotropic rod-Voigt smear — needs a general per-voxel
//                D, i.e. 21 coefficients; PR 252's linearity extends verbatim).
//   K3  ROUTE B (explicit elements): each skin chord an axial bar, endpoints
//       trilinearly EMBEDDED in the coarse hexes (K += W^T k_bar W, zero new
//       DOFs) — measured against K1 like Route A, plus the cost/disruption
//       analysis (linearity in D, matrix-free shape, multigrid/GenEO impact).
//   K4  GRADING: a graded skin radius (0.4 -> 0.9 mm across the plate), same
//       comparison — does the favoured route carry a VARYING radius?
//   K5  SHELL: the same machinery pointed at a solid shell wall (0.8 mm band on
//       the boundary — the printed two-wall skin of the exported mesh): does the
//       shell fall out of the same route?
//
// BARS — STATED BEFORE MEASUREMENT (printed to the log before any solve):
//   BAR-T  (total)       favoured route predicts total K within +-10% of the K1
//                        reference in EVERY state (the tensor library's own
//                        caveat scale — a surface credit cannot be more accurate
//                        than the interior model it rides on).
//   BAR-D  (delta)       the skin CONTRIBUTION Delta = K(skin) - K(base) within
//                        +-25% in every state where Delta_ref >= 5% of K_base
//                        (below that the delta drowns in reference noise).
//   BAR-C  (conservatism) the route must not OVER-credit: K_route <= 1.10 * K_ref
//                        in every state.
//
// EVERYTHING here is HARNESS-SIDE: the production library is linked UNMODIFIED;
// no constant armed, no gate touched, no fixture/materials change.
//
// Build (repo root; machine of record Apple M2 Pro, Apple clang, -O2):
//   c++ -std=c++17 -O2 -I core/include -I core/tests/harness \
//       -I /opt/homebrew/include/eigen3 \
//       core/tests/harness/surface_stiffness_probe.cpp core/build/libtopopt.a \
//       -o core/build/surface_stiffness_probe
//   ./core/build/surface_stiffness_probe all <evidence-dir>

#include <chrono>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <map>
#include <string>
#include <vector>

#include "surface_stiffness_model.hpp"

#include "topopt/fea.hpp"
#include "topopt/lattice.hpp"
#include "topopt/lattice_boundary.hpp"
#include "topopt/lattice_gen.hpp"
#include "topopt/mesh.hpp"
#include "topopt/voxel.hpp"

using namespace topopt;
using namespace surfstiff;

namespace {

// ── fixture constants ───────────────────────────────────────────────────────
constexpr double kCell = 4.0;   // mm
constexpr int kCellsX = 6, kCellsY = 6, kCellsZ = 1;
constexpr double kLx = kCellsX * kCell;  // 24
constexpr double kLy = kCellsY * kCell;  // 24
constexpr double kLz = kCellsZ * kCell;  // 4
constexpr double kEs = 3500.0;  // PLA, the library's measurement modulus
constexpr double kNu = 0.33;
constexpr double kRhoTarget = 0.26;    // PR 253's E2E working density
constexpr double kWidthMm = 0.8;       // stated extrusion width -> skin clamp
constexpr double kDelta = 0.01;        // grip displacement, mm (linear anyway)
constexpr double kShellT = 0.8;        // solid shell wall thickness (two 0.4 walls)
constexpr double kTol = 1e-8;          // solver tolerance, both paths

FILE* open_csv(const std::string& dir, const char* name) {
  const std::string p = dir + "/" + name;
  FILE* f = std::fopen(p.c_str(), "w");
  if (!f) { std::fprintf(stderr, "cannot open %s\n", p.c_str()); std::exit(1); }
  return f;
}

double solve_rho_radius() {
  // Invert octet_relative_density(kCell, r) == kRhoTarget by bisection.
  // Cached: each octet_relative_density call voxelizes a vpc48 cell.
  static const double cached = [] {
    double lo = 0.05, hi = 1.9;
    for (int it = 0; it < 60; ++it) {
      const double mid = 0.5 * (lo + hi);
      if (octet_relative_density(kCell, mid) < kRhoTarget) lo = mid; else hi = mid;
    }
    return 0.5 * (lo + hi);
  }();
  return cached;
}

double graded_radius_at(double x) {
  const double t = std::min(1.0, std::max(0.0, x / kLx));
  return 0.4 + 0.5 * t;  // 0.4 -> 0.9 mm across the plate
}

// ── generator tap: collect every emitted element as a capsule ───────────────
struct ElementSets {
  std::vector<Capsule> base;   // InteriorStrut + Node + AnchorNode
  std::vector<Capsule> skin;   // SkinStrut + RimStrut + RimTorusChord
  LatticeGenStats stats;
};

ElementSets collect_elements(bool graded) {
  LatticeBoundary B;
  B.add_box({0, 0, 0}, {kLx, kLy, kLz});

  LatticeRegion R;
  R.origin = {0, 0, 0};
  R.nx = kCellsX; R.ny = kCellsY; R.nz = kCellsZ;
  R.cell_mm = kCell;
  R.boundary = &B;

  LatticeRadiusField G;
  G.nseg = 8;
  if (graded)
    G.field = [](Vec3 p) { return graded_radius_at(p.x); };
  else
    G.uniform_mm = solve_rho_radius();

  LatticeSkinSpec S;
  S.mode = LatticeSkinMode::Diagrid;
  S.min_radius_mm = lattice_skin_min_radius_mm(kWidthMm);
  S.freeform = false;  // analytic box faces — the PR 250 diagrid

  ElementSets out;
  LatticeGenObserver obs;
  obs.on_element = [&](LatticeGenElement kind, const Vec3& a, const Vec3& b,
                       double r) {
    Capsule c{a, b, r};
    switch (kind) {
      case LatticeGenElement::InteriorStrut:
      case LatticeGenElement::Node:
      case LatticeGenElement::AnchorNode:
        out.base.push_back(c);
        break;
      case LatticeGenElement::SkinStrut:
      case LatticeGenElement::RimStrut:
      case LatticeGenElement::RimTorusChord:
        out.skin.push_back(c);
        break;
    }
  };
  MeshSink ms;
  out.stats = generate_lattice(LatticeGenTopology::Octet, R, G, ms, S, &obs);
  return out;
}

// ── grip states ─────────────────────────────────────────────────────────────
struct State {
  const char* name;
  int axis;          // grip plane normal axis (0=x, 1=y, 2=z)
  double lo, hi;     // the two grip plane coordinates
  Vec3 disp;         // displacement of the hi grip (lo grip fixed at 0)
  // VOLUMETRIC clamp depth (mm): every solid-attached node within `band` of
  // the grip plane is rigidly prescribed. Nonzero for the in-plane/bending
  // states because the boundary clip ERODES all struts a radius away from the
  // grip faces — a zero-thickness plane grip's contact area with the base
  // vanishes as h -> 0 (a resolution artifact that inflates the skin delta).
  // The through-thickness states keep plane grips (band 0): platen-on-skin
  // contact IS the physical question there; their slower h-convergence is
  // reported with the ladder.
  double band;
};

std::vector<State> states() {
  const double b = kCell / 2.0;  // 2 mm: half a cell, grips interior + skin
  return {
      {"S1_tension_x", 0, 0.0, kLx, {kDelta, 0, 0}, b},
      {"S2_tension_y", 1, 0.0, kLy, {0, kDelta, 0}, b},
      {"S3_shear_xy", 0, 0.0, kLx, {0, kDelta, 0}, b},
      {"S4_compress_z", 2, 0.0, kLz, {0, 0, -kDelta}, 0.0},
      {"S5_bend_tipz", 0, 0.0, kLx, {0, 0, kDelta}, b},
      {"S6_shear_zx", 2, 0.0, kLz, {kDelta, 0, 0}, 0.0},
  };
}

// ── fine (strut-resolved) model ─────────────────────────────────────────────
struct FineResult {
  double K = 0.0;        // 2U/delta^2
  int iters = 0;
  bool used_mg = false;
  long long solid = 0;   // solid voxel count
};

struct FineModel {
  VoxelGrid grid;
  std::vector<double> youngs;
  std::vector<char> solid;
  long long nsolid = 0;

  static FineModel build(const std::vector<char>& solid_in, double h) {
    FineModel m;
    m.grid.nx = (int)std::llround(kLx / h);
    m.grid.ny = (int)std::llround(kLy / h);
    m.grid.nz = (int)std::llround(kLz / h);
    m.grid.spacing = h;
    m.grid.origin = {0, 0, 0};
    m.grid.tags.assign((std::size_t)m.grid.nx * m.grid.ny * m.grid.nz,
                       VoxelTag::Empty);
    m.youngs.assign(m.grid.tags.size(), 0.0);
    m.solid = solid_in;
    for (std::size_t e = 0; e < m.solid.size(); ++e)
      if (m.solid[e]) {
        m.grid.tags[e] = VoxelTag::Interior;
        m.youngs[e] = kEs;
        ++m.nsolid;
      }
    return m;
  }

  // Nodes within `band` of the grip plane that belong to at least one solid
  // voxel (band 0: the exact plane).
  std::vector<int> grip_nodes(int axis, double value, double band) const {
    const int nx = grid.nx, ny = grid.ny, nz = grid.nz;
    const double h = grid.spacing;
    std::vector<char> attached((std::size_t)(nx + 1) * (ny + 1) * (nz + 1), 0);
    for (int k = 0; k < nz; ++k)
      for (int j = 0; j < ny; ++j)
        for (int i = 0; i < nx; ++i) {
          if (!solid[((std::size_t)k * ny + j) * nx + i]) continue;
          for (int dk = 0; dk <= 1; ++dk)
            for (int dj = 0; dj <= 1; ++dj)
              for (int di = 0; di <= 1; ++di)
                attached[fea_node_index(grid, i + di, j + dj, k + dk)] = 1;
        }
    std::vector<int> out;
    for (int c = 0; c <= nz; ++c)
      for (int b = 0; b <= ny; ++b)
        for (int a = 0; a <= nx; ++a) {
          const double xyz[3] = {a * h, b * h, c * h};
          if (std::abs(xyz[axis] - value) > band + 1e-9) continue;
          const int n = fea_node_index(grid, a, b, c);
          if (attached[(std::size_t)n]) out.push_back(n);
        }
    return out;
  }

  FineResult run_state(const State& st) const {
    std::vector<DirichletBC> bcs;
    for (int n : grip_nodes(st.axis, st.lo, st.band))
      for (int c = 0; c < 3; ++c) bcs.push_back({n, c, 0.0});
    const double d[3] = {st.disp.x, st.disp.y, st.disp.z};
    for (int n : grip_nodes(st.axis, st.hi, st.band))
      for (int c = 0; c < 3; ++c) bcs.push_back({n, c, d[c]});
    std::vector<NodalLoad> loads;  // pure prescribed-displacement problem
    CgInfo info;
    const FeaSolution sol = fea_solve_mgcg_matfree(
        grid, youngs, kNu, bcs, loads, kTol, 0, &info, nullptr);
    // Strain energy, element by element (no global matrix), fixed order.
    const Hex8Stiffness Kunit = hex8_stiffness(1.0, kNu, grid.spacing);
    double U = 0.0;
    const int nx = grid.nx, ny = grid.ny, nz = grid.nz;
    for (int k = 0; k < nz; ++k)
      for (int j = 0; j < ny; ++j)
        for (int i = 0; i < nx; ++i) {
          const std::size_t e = ((std::size_t)k * ny + j) * nx + i;
          if (!solid[e]) continue;
          const std::array<int, 8> nn = fea_element_nodes(grid, i, j, k);
          double ue[24];
          for (int a = 0; a < 8; ++a)
            for (int c = 0; c < 3; ++c)
              ue[3 * a + c] = sol.u[(std::size_t)(3 * nn[(std::size_t)a] + c)];
          double acc = 0.0;
          for (int r = 0; r < 24; ++r) {
            double kr = 0.0;
            for (int c = 0; c < 24; ++c)
              kr += Kunit.k[(std::size_t)r * 24 + c] * ue[c];
            acc += ue[r] * kr;
          }
          U += 0.5 * kEs * acc;
        }
    FineResult res;
    res.K = 2.0 * U / (kDelta * kDelta);
    res.iters = info.iterations;
    res.used_mg = info.used_multigrid;
    res.solid = nsolid;
    return res;
  }
};

std::vector<char> raster_config(const std::vector<Capsule>& base,
                                const std::vector<Capsule>* skin, double h,
                                bool shell_band) {
  const int nx = (int)std::llround(kLx / h);
  const int ny = (int)std::llround(kLy / h);
  const int nz = (int)std::llround(kLz / h);
  std::vector<char> solid((std::size_t)nx * ny * nz, 0);
  rasterize_solid(base, {0, 0, 0}, h, nx, ny, nz, solid);
  if (skin) rasterize_solid(*skin, {0, 0, 0}, h, nx, ny, nz, solid);
  if (shell_band) {
    for (int k = 0; k < nz; ++k)
      for (int j = 0; j < ny; ++j)
        for (int i = 0; i < nx; ++i) {
          const double x = (i + 0.5) * h, y = (j + 0.5) * h, z = (k + 0.5) * h;
          const double dist = std::min({x, kLx - x, y, kLy - y, z, kLz - z});
          if (dist <= kShellT)
            solid[((std::size_t)k * ny + j) * nx + i] = 1;
        }
  }
  return solid;
}

// ── coarse model builders ───────────────────────────────────────────────────
constexpr double kHc = 1.0;  // coarse (certification-scale) voxel, mm

// rho_override >= 0: use that relative density everywhere instead of the
// labelled (declared-geometry) density — the K2b control that removes the
// legs-only-vs-full-octet labelling gap from the coarse base.
CoarseModel coarse_base(bool graded, double rho_override = -1.0) {
  CoarseModel m;
  m.origin = {0, 0, 0};
  m.h = kHc;
  m.nx = (int)std::llround(kLx / kHc);
  m.ny = (int)std::llround(kLy / kHc);
  m.nz = (int)std::llround(kLz / kHc);
  m.D.assign((std::size_t)m.nx * m.ny * m.nz, D6{});
  // The tensor depends only on the x column (uniform: on nothing) — hoist the
  // vpc48 voxelization octet_relative_density performs out of the voxel loop.
  std::vector<D6> per_column((std::size_t)m.nx);
  for (int i = 0; i < m.nx; ++i) {
    const double xc = (i + 0.5) * kHc;
    const double r = graded ? graded_radius_at(xc) : solve_rho_radius();
    const double rho =
        rho_override >= 0.0 ? rho_override : octet_relative_density(kCell, r);
    const CubicTensor T = lattice_cubic_tensor(LatticeTopology::Octet, rho, kEs);
    per_column[(std::size_t)i] = d6_cubic(T.C11, T.C12, T.C44);
    if (!graded) {
      per_column.assign((std::size_t)m.nx, per_column[0]);
      break;
    }
  }
  for (int k = 0; k < m.nz; ++k)
    for (int j = 0; j < m.ny; ++j)
      for (int i = 0; i < m.nx; ++i)
        m.D[((std::size_t)k * m.ny + j) * m.nx + i] = per_column[(std::size_t)i];
  return m;
}

double coarse_energy_K(const CoarseModel& m, const State& st) {
  CoarseModel::Grip fixed, moved;
  fixed.nodes = m.plane_nodes(st.axis, st.lo, st.band);
  moved.nodes = m.plane_nodes(st.axis, st.hi, st.band);
  moved.ux = st.disp.x; moved.uy = st.disp.y; moved.uz = st.disp.z;
  const double U = m.solve_energy(fixed, moved);
  return 2.0 * U / (kDelta * kDelta);
}

// Shell membrane smear (K5): sample each coarse voxel on a fixed sub-grid; a
// sample inside the shell band contributes the plane-stress membrane D of the
// NEAREST box face (in-plane isotropic), smeared by its volume share.
void shell_membrane_smear(std::vector<D6>& dD, const CoarseModel& m) {
  const int S = 8;  // 8^3 fixed samples per voxel
  const double sub = m.h / S;
  const double c = kEs / (1.0 - kNu * kNu);
  const double G = kEs / (2.0 * (1.0 + kNu));
  for (int k = 0; k < m.nz; ++k)
    for (int j = 0; j < m.ny; ++j)
      for (int i = 0; i < m.nx; ++i) {
        D6& d = dD[((std::size_t)k * m.ny + j) * m.nx + i];
        for (int sk = 0; sk < S; ++sk)
          for (int sj = 0; sj < S; ++sj)
            for (int si = 0; si < S; ++si) {
              const double x = i * m.h + (si + 0.5) * sub;
              const double y = j * m.h + (sj + 0.5) * sub;
              const double z = k * m.h + (sk + 0.5) * sub;
              const double dists[6] = {x, kLx - x, y, kLy - y, z, kLz - z};
              int amin = 0;
              for (int a = 1; a < 6; ++a)
                if (dists[a] < dists[amin]) amin = a;
              if (dists[amin] > kShellT) continue;
              const int nrm = amin / 2;  // 0=x,1=y,2=z face normal
              const double w = 1.0 / (S * S * S);
              // In-plane axes p,q for the face; Voigt shear slot of (p,q):
              // (x,y)->3, (y,z)->4, (z,x)->5.
              int p = (nrm + 1) % 3, q = (nrm + 2) % 3;
              int shear_slot = (p == 0 || q == 0)
                                   ? ((p == 1 || q == 1) ? 3 : 5)
                                   : 4;
              d.m[p][p] += w * c;
              d.m[q][q] += w * c;
              d.m[p][q] += w * kNu * c;
              d.m[q][p] += w * kNu * c;
              d.m[shear_slot][shear_slot] += w * G;
            }
      }
}

// Overlap (union) correction shared by K2/K4: rescale each coarse voxel's
// smear by (printed union volume)/(per-chord soup volume), the union measured
// on a skin-only fine raster (h=0.25) aggregated per coarse voxel. phi becomes
// the union fraction (A-iso's input); dD is scaled in place. Returns
// {soup_mm3, union_mm3}.
std::pair<double, double> apply_union_correction(
    const std::vector<Capsule>& skin, const CoarseModel& base,
    std::vector<D6>& dD, std::vector<double>& phi) {
  const double hu = 0.25;
  const int fx = (int)std::llround(kLx / hu), fy = (int)std::llround(kLy / hu),
            fz = (int)std::llround(kLz / hu);
  std::vector<char> s((std::size_t)fx * fy * fz, 0);
  rasterize_solid(skin, {0, 0, 0}, hu, fx, fy, fz, s);
  std::vector<double> uf(phi.size(), 0.0);
  const int per = (int)std::llround(kHc / hu);
  for (int k = 0; k < fz; ++k)
    for (int j = 0; j < fy; ++j)
      for (int i = 0; i < fx; ++i)
        if (s[((std::size_t)k * fy + j) * fx + i])
          uf[((std::size_t)(k / per) * base.ny + (j / per)) * base.nx +
             (i / per)] += (hu * hu * hu) / (kHc * kHc * kHc);
  double soup_tot = 0.0, union_tot = 0.0;
  for (std::size_t e = 0; e < phi.size(); ++e) {
    const double sc = phi[e] > 0.0 ? std::min(1.0, uf[e] / phi[e]) : 0.0;
    soup_tot += phi[e];
    union_tot += uf[e];
    phi[e] = uf[e];
    for (int r = 0; r < 6; ++r)
      for (int c = 0; c < 6; ++c) dD[e].m[r][c] *= sc;
  }
  const double v = kHc * kHc * kHc;
  return {soup_tot * v, union_tot * v};
}

}  // namespace

int main(int argc, char** argv) {
  if (argc < 3) {
    std::fprintf(stderr, "usage: %s <k1|k2|k3|k4|k5|all> <evidence-dir>\n",
                 argv[0]);
    return 2;
  }
  const std::string phase = argv[1];
  const std::string ev = argv[2];
  const bool all = phase == "all";
  const auto t_start = std::chrono::steady_clock::now();

  std::printf("surface_stiffness_probe — bars stated BEFORE measurement:\n");
  std::printf("  BAR-T  total K within +-10%% of reference, every state\n");
  std::printf("  BAR-D  skin delta within +-25%% where delta_ref >= 5%% of base\n");
  std::printf("  BAR-C  no over-credit: K_route <= 1.10 * K_ref, every state\n\n");

  const double r_u = solve_rho_radius();
  const double rho_u = octet_relative_density(kCell, r_u);
  std::printf("fixture: plate %gx%gx%g mm, cell %g, uniform r=%.6f mm "
              "(rho=%.6f), skin clamp r>=%.3f mm\n",
              kLx, kLy, kLz, kCell, r_u, rho_u,
              lattice_skin_min_radius_mm(kWidthMm));

  // ── geometry from the REAL generator ──────────────────────────────────────
  const ElementSets uni = collect_elements(/*graded=*/false);
  const ElementSets grad = collect_elements(/*graded=*/true);
  std::printf("uniform: base elements %zu, skin elements %zu "
              "(gen: struts=%llu skin_struts=%llu rim=%llu landings=%llu)\n",
              uni.base.size(), uni.skin.size(),
              (unsigned long long)uni.stats.struts,
              (unsigned long long)uni.stats.skin_struts,
              (unsigned long long)uni.stats.rim_elements,
              (unsigned long long)uni.stats.landings);
  std::printf("graded:  base elements %zu, skin elements %zu\n\n",
              grad.base.size(), grad.skin.size());

  const std::vector<State> STS = states();

  // ── K1: strut-resolved reference, resolution ladder ───────────────────────
  // configs: base, skin (ladder h=0.5/0.25/0.2); gbase, gskin, shell (h=0.25).
  std::map<std::string, std::map<std::string, FineResult>> fine;  // [cfg][state]
  if (all || phase == "k1" || phase == "k2" || phase == "k3" || phase == "k4" ||
      phase == "k5") {
    FILE* f = open_csv(ev, "k1_reference.csv");
    std::fprintf(f, "h_mm,config,state,K_N_per_mm,cg_iters,used_multigrid,"
                    "solid_voxels,solid_fraction\n");
    struct Cfg {
      const char* name;
      const std::vector<Capsule>* base;
      const std::vector<Capsule>* skin;
      bool shell;
      std::vector<double> hs;
    };
    const std::vector<Cfg> cfgs = {
        {"base", &uni.base, nullptr, false, {0.5, 0.25, 0.2, 1.0 / 6.0}},
        {"skin", &uni.base, &uni.skin, false, {0.5, 0.25, 0.2, 1.0 / 6.0}},
        {"gbase", &grad.base, nullptr, false, {0.25}},
        {"gskin", &grad.base, &grad.skin, false, {0.25}},
        {"shell", &uni.base, nullptr, true, {0.25}},
    };
    for (const Cfg& cfg : cfgs) {
      for (double h : cfg.hs) {
        const std::vector<char> solid =
            raster_config(*cfg.base, cfg.skin, h, cfg.shell);
        const FineModel m = FineModel::build(solid, h);
        for (const State& st : STS) {
          const auto t0 = std::chrono::steady_clock::now();
          const FineResult r = m.run_state(st);
          const double dt =
              std::chrono::duration<double>(std::chrono::steady_clock::now() - t0)
                  .count();
          std::fprintf(f, "%.6g,%s,%s,%.12g,%d,%d,%lld,%.6f\n", h, cfg.name,
                       st.name, r.K, r.iters, r.used_mg ? 1 : 0, r.solid,
                       (double)r.solid / (double)m.solid.size());
          std::fflush(f);
          std::printf("k1 h=%.3g %-6s %-14s K=%.6g iters=%d mg=%d (%.1fs)\n", h,
                      cfg.name, st.name, r.K, r.iters, r.used_mg ? 1 : 0, dt);
          std::fflush(stdout);
          // Reference registry: finest h per config wins (hs ascending? no —
          // ordered as listed; register keyed on (cfg,h) then reduce below).
          const std::string key = std::string(cfg.name) + "@" +
                                  std::to_string(h);
          fine[key][st.name] = r;
        }
      }
    }
    std::fclose(f);
  }

  auto fine_K = [&](const std::string& cfg, double h,
                    const std::string& state) -> double {
    const std::string key = cfg + "@" + std::to_string(h);
    return fine.at(key).at(state).K;
  };

  // Reference resolutions: uniform configs h=1/6, graded/shell h=0.25.
  const double hRefU = 1.0 / 6.0, hRefG = 0.25;

  // ── K2/K3: routes on the coarse (1 mm) certification-scale grid ───────────
  if (all || phase == "k2" || phase == "k3") {
    // Route A smears + route B bars from the SAME element list.
    const CoarseModel base = coarse_base(false);
    std::vector<D6> dD((std::size_t)base.nx * base.ny * base.nz, D6{});
    rod_smear_accumulate(uni.skin, kEs, kNu, base.origin, kHc, base.nx, base.ny,
                         base.nz, dD);
    std::vector<double> phi((std::size_t)base.nx * base.ny * base.nz, 0.0);
    volume_fraction_accumulate(uni.skin, base.origin, kHc, base.nx, base.ny,
                               base.nz, phi);
    // OVERLAP (union) correction: at this landing density the diagrid is
    // several overlapping tube layers, so a per-chord (Voigt/soup) smear
    // injects material that does not exist in the printed union. This is the
    // same correction a production Route A would need — stated as part of
    // Route A's cost.
    const auto vols = apply_union_correction(uni.skin, base, dD, phi);
    std::printf("k2 overlap correction: skin soup volume %.1f mm3, union "
                "%.1f mm3 (ratio %.3f)\n",
                vols.first, vols.second,
                vols.first > 0 ? vols.second / vols.first : 0.0);

    auto with_delta = [&](int mode) {  // 0=iso, 1=cubic, 2=aniso
      CoarseModel m = base;
      for (std::size_t e = 0; e < m.D.size(); ++e) {
        if (mode == 0) {
          m.D[e].add(d6_isotropic(kEs, kNu), phi[e]);
        } else if (mode == 1) {
          const CubicFit c = project_cubic(dD[e]);
          if (c.C11 > 0.0) m.D[e].add(d6_cubic(c.C11, c.C12, c.C44));
        } else {
          m.D[e].add(dD[e]);
        }
      }
      return m;
    };
    CoarseModel mB = base;  // route B: explicit bars (per-chord soup areas)
    for (const Capsule& c : uni.skin) {
      const double dx = c.b.x - c.a.x, dy = c.b.y - c.a.y, dz = c.b.z - c.a.z;
      if (dx * dx + dy * dy + dz * dz <= 1e-24) continue;  // balls: joints
      mB.bars.push_back({c.a, c.b, kEs * M_PI * c.r * c.r});
    }
    // route B with the SAME union correction applied as one global area
    // dedup: EA scaled by union/soup (a per-member dedup is route B's
    // production analogue; the global scale bounds what it buys).
    CoarseModel mBu = base;
    const double bar_scale = vols.first > 0 ? vols.second / vols.first : 1.0;
    for (const CoarseModel::Bar& bb : mB.bars)
      mBu.bars.push_back({bb.a, bb.b, bb.EA * bar_scale});

    FILE* f = open_csv(ev, "k2_k3_routes.csv");
    std::fprintf(f,
                 "state,K_ref_base,K_ref_skin,delta_ref,K_coarse_base,"
                 "base_err_pct,K_A_iso,K_A_cubic,K_A_aniso,K_B_truss,"
                 "K_B_union,errT_A_iso_pct,errT_A_cubic_pct,errT_A_aniso_pct,"
                 "errT_B_pct,errT_B_union_pct,errD_A_iso_pct,errD_A_cubic_pct,"
                 "errD_A_aniso_pct,errD_B_pct,errD_B_union_pct\n");
    const CoarseModel mAi = with_delta(0), mAc = with_delta(1), mAa = with_delta(2);
    for (const State& st : STS) {
      const double Krb = fine_K("base", hRefU, st.name);
      const double Krs = fine_K("skin", hRefU, st.name);
      const double dref = Krs - Krb;
      const double K0 = coarse_energy_K(base, st);
      const double Ki = coarse_energy_K(mAi, st);
      const double Kc = coarse_energy_K(mAc, st);
      const double Ka = coarse_energy_K(mAa, st);
      const double Kb = coarse_energy_K(mB, st);
      const double Kbu = coarse_energy_K(mBu, st);
      auto pct = [](double a, double b) { return 100.0 * (a / b - 1.0); };
      auto dpct = [&](double Kv) {
        return dref != 0.0 ? 100.0 * ((Kv - K0) / dref - 1.0) : 0.0;
      };
      std::fprintf(f,
                   "%s,%.12g,%.12g,%.12g,%.12g,%.3f,%.12g,%.12g,%.12g,%.12g,"
                   "%.12g,%.3f,%.3f,%.3f,%.3f,%.3f,%.3f,%.3f,%.3f,%.3f,%.3f\n",
                   st.name, Krb, Krs, dref, K0, pct(K0, Krb), Ki, Kc, Ka, Kb,
                   Kbu, pct(Ki, Krs), pct(Kc, Krs), pct(Ka, Krs), pct(Kb, Krs),
                   pct(Kbu, Krs), dpct(Ki), dpct(Kc), dpct(Ka), dpct(Kb),
                   dpct(Kbu));
      std::printf("k2/k3 %-14s dref=%+.4g  errT%% iso=%+.1f cubic=%+.1f "
                  "aniso=%+.1f B=%+.1f Bu=%+.1f | errD%% iso=%+.1f "
                  "cubic=%+.1f aniso=%+.1f B=%+.1f Bu=%+.1f\n",
                  st.name, dref, pct(Ki, Krs), pct(Kc, Krs), pct(Ka, Krs),
                  pct(Kb, Krs), pct(Kbu, Krs), dpct(Ki), dpct(Kc), dpct(Ka),
                  dpct(Kb), dpct(Kbu));
      std::fflush(stdout);
    }
    std::fclose(f);

    // K2b CONTROL — how much of the routes' under-credit is the BASE being
    // wrong (the legs-only-vs-full-octet labelling gap) rather than the route?
    // Rebuild the coarse base at the MEASURED strut-resolved solid fraction
    // (rho from the base raster union at h=0.25) and re-test A-aniso and B on
    // it. Whatever under-credit SURVIVES an honest base is structural
    // (boundary-cell reconnection), not a base artifact.
    {
      const double hu = 0.25;
      const int fx = (int)std::llround(kLx / hu), fy = (int)std::llround(kLy / hu),
                fz = (int)std::llround(kLz / hu);
      std::vector<char> s((std::size_t)fx * fy * fz, 0);
      rasterize_solid(uni.base, {0, 0, 0}, hu, fx, fy, fz, s);
      long long cnt = 0;
      for (char c : s) cnt += c;
      const double rho2 = (double)cnt / (double)s.size();
      const CoarseModel base2 = coarse_base(false, rho2);
      CoarseModel mAa2 = base2;
      for (std::size_t e = 0; e < mAa2.D.size(); ++e) mAa2.D[e].add(dD[e]);
      CoarseModel mB2 = base2, mB2u = base2;
      for (const CoarseModel::Bar& bb : mB.bars) {
        mB2.bars.push_back(bb);
        mB2u.bars.push_back({bb.a, bb.b, bb.EA * bar_scale});
      }
      FILE* f2 = open_csv(ev, "k2b_corrected_base.csv");
      std::fprintf(f2,
                   "state,rho_measured,K_ref_base,K_ref_skin,delta_ref,"
                   "K_base2,base2_err_pct,K_A_aniso2,K_B2,K_B2_union,"
                   "errT_A2_pct,errT_B2_pct,errT_B2u_pct,errD_A2_pct,"
                   "errD_B2_pct,errD_B2u_pct\n");
      for (const State& st : STS) {
        const double Krb = fine_K("base", hRefU, st.name);
        const double Krs = fine_K("skin", hRefU, st.name);
        const double dref = Krs - Krb;
        const double K0 = coarse_energy_K(base2, st);
        const double Ka = coarse_energy_K(mAa2, st);
        const double Kb = coarse_energy_K(mB2, st);
        const double Kbu = coarse_energy_K(mB2u, st);
        auto pct = [](double a, double b) { return 100.0 * (a / b - 1.0); };
        auto dpct = [&](double Kv) {
          return dref != 0.0 ? 100.0 * ((Kv - K0) / dref - 1.0) : 0.0;
        };
        std::fprintf(f2,
                     "%s,%.6f,%.12g,%.12g,%.12g,%.12g,%.3f,%.12g,%.12g,%.12g,"
                     "%.3f,%.3f,%.3f,%.3f,%.3f,%.3f\n",
                     st.name, rho2, Krb, Krs, dref, K0, pct(K0, Krb), Ka, Kb,
                     Kbu, pct(Ka, Krs), pct(Kb, Krs), pct(Kbu, Krs), dpct(Ka),
                     dpct(Kb), dpct(Kbu));
        std::printf("k2b %-14s base2_err%%=%+.1f errD%% A2=%+.1f B2=%+.1f "
                    "B2u=%+.1f\n",
                    st.name, pct(K0, Krb), dpct(Ka), dpct(Kb), dpct(Kbu));
        std::fflush(stdout);
      }
      std::fclose(f2);
    }
  }

  // ── K4: graded skin radius ────────────────────────────────────────────────
  if (all || phase == "k4") {
    const CoarseModel gbase = coarse_base(true);
    std::vector<D6> dD((std::size_t)gbase.nx * gbase.ny * gbase.nz, D6{});
    rod_smear_accumulate(grad.skin, kEs, kNu, gbase.origin, kHc, gbase.nx,
                         gbase.ny, gbase.nz, dD);
    std::vector<double> gphi(dD.size(), 0.0);
    volume_fraction_accumulate(grad.skin, gbase.origin, kHc, gbase.nx,
                               gbase.ny, gbase.nz, gphi);
    const auto gvols = apply_union_correction(grad.skin, gbase, dD, gphi);
    std::printf("k4 overlap correction: graded skin soup %.1f mm3, union "
                "%.1f mm3 (ratio %.3f)\n",
                gvols.first, gvols.second,
                gvols.first > 0 ? gvols.second / gvols.first : 0.0);
    CoarseModel gAa = gbase;
    for (std::size_t e = 0; e < gAa.D.size(); ++e) gAa.D[e].add(dD[e]);
    CoarseModel gB = gbase;
    for (const Capsule& c : grad.skin) {
      const double dx = c.b.x - c.a.x, dy = c.b.y - c.a.y, dz = c.b.z - c.a.z;
      if (dx * dx + dy * dy + dz * dz <= 1e-24) continue;
      gB.bars.push_back({c.a, c.b, kEs * M_PI * c.r * c.r});
    }
    FILE* f = open_csv(ev, "k4_grading.csv");
    std::fprintf(f, "state,K_ref_gbase,K_ref_gskin,delta_ref,K_coarse_gbase,"
                    "K_gA_aniso,K_gB_truss,errT_gA_pct,errT_gB_pct,"
                    "errD_gA_pct,errD_gB_pct\n");
    for (const State& st : STS) {
      const double Krb = fine_K("gbase", hRefG, st.name);
      const double Krs = fine_K("gskin", hRefG, st.name);
      const double dref = Krs - Krb;
      const double K0 = coarse_energy_K(gbase, st);
      const double Ka = coarse_energy_K(gAa, st);
      const double Kb = coarse_energy_K(gB, st);
      auto pct = [](double a, double b) { return 100.0 * (a / b - 1.0); };
      auto dpct = [&](double Kv) {
        return dref != 0.0 ? 100.0 * ((Kv - K0) / dref - 1.0) : 0.0;
      };
      std::fprintf(f, "%s,%.12g,%.12g,%.12g,%.12g,%.12g,%.12g,%.3f,%.3f,"
                      "%.3f,%.3f\n",
                   st.name, Krb, Krs, dref, K0, Ka, Kb, pct(Ka, Krs),
                   pct(Kb, Krs), dpct(Ka), dpct(Kb));
      std::printf("k4 %-14s dref=%+.4g errT%% A=%+.1f B=%+.1f | errD%% "
                  "A=%+.1f B=%+.1f\n",
                  st.name, dref, pct(Ka, Krs), pct(Kb, Krs), dpct(Ka),
                  dpct(Kb));
      std::fflush(stdout);
    }
    std::fclose(f);
  }

  // ── K5: does the solid shell fall out of the same machinery? ──────────────
  if (all || phase == "k5") {
    const CoarseModel base = coarse_base(false);
    // A-iso for the shell: geometric volume fraction of the band per voxel.
    CoarseModel mIso = base, mAniso = base;
    {
      std::vector<D6> dD((std::size_t)base.nx * base.ny * base.nz, D6{});
      shell_membrane_smear(dD, base);
      for (std::size_t e = 0; e < mAniso.D.size(); ++e) mAniso.D[e].add(dD[e]);
      // iso: same volume share, isotropic add (trace-matched to the sampling).
      const int S = 8;
      const double sub = kHc / S;
      for (int k = 0; k < base.nz; ++k)
        for (int j = 0; j < base.ny; ++j)
          for (int i = 0; i < base.nx; ++i) {
            double share = 0.0;
            for (int sk = 0; sk < S; ++sk)
              for (int sj = 0; sj < S; ++sj)
                for (int si = 0; si < S; ++si) {
                  const double x = i * kHc + (si + 0.5) * sub;
                  const double y = j * kHc + (sj + 0.5) * sub;
                  const double z = k * kHc + (sk + 0.5) * sub;
                  if (std::min({x, kLx - x, y, kLy - y, z, kLz - z}) <= kShellT)
                    share += 1.0 / (S * S * S);
                }
            mIso.D[((std::size_t)k * base.ny + j) * base.nx + i].add(
                d6_isotropic(kEs, kNu), share);
          }
    }
    FILE* f = open_csv(ev, "k5_shell.csv");
    std::fprintf(f, "state,K_ref_base,K_ref_shell,delta_ref,K_coarse_base,"
                    "K_shell_iso,K_shell_aniso,errT_iso_pct,errT_aniso_pct,"
                    "errD_iso_pct,errD_aniso_pct\n");
    for (const State& st : STS) {
      const double Krb = fine_K("base", hRefG, st.name);
      const double Krs = fine_K("shell", hRefG, st.name);
      const double dref = Krs - Krb;
      const double K0 = coarse_energy_K(base, st);
      const double Ki = coarse_energy_K(mIso, st);
      const double Ka = coarse_energy_K(mAniso, st);
      auto pct = [](double a, double b) { return 100.0 * (a / b - 1.0); };
      auto dpct = [&](double Kv) {
        return dref != 0.0 ? 100.0 * ((Kv - K0) / dref - 1.0) : 0.0;
      };
      std::fprintf(f, "%s,%.12g,%.12g,%.12g,%.12g,%.12g,%.12g,%.3f,%.3f,"
                      "%.3f,%.3f\n",
                   st.name, Krb, Krs, dref, K0, Ki, Ka, pct(Ki, Krs),
                   pct(Ka, Krs), dpct(Ki), dpct(Ka));
      std::printf("k5 %-14s dref=%+.4g errT%% iso=%+.1f aniso=%+.1f | "
                  "errD%% iso=%+.1f aniso=%+.1f\n",
                  st.name, dref, pct(Ki, Krs), pct(Ka, Krs), dpct(Ki),
                  dpct(Ka));
      std::fflush(stdout);
    }
    std::fclose(f);
  }

  const double total_s =
      std::chrono::duration<double>(std::chrono::steady_clock::now() - t_start)
          .count();
  std::printf("\ndone in %.1f s\n", total_s);
  return 0;
}
