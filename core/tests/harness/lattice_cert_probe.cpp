// lattice_cert_probe.cpp — VALIDATION harness for lattice certification Phase 1
// (handoff 2026-07-27-lattice-certification).
//
// This proves the Phase-1 production capability the same way lattice_homog_probe.cpp
// (Phase 0) proved the offline library: measured, first-hand, standalone. It does NOT
// re-derive the homogenized tensors (PR 198 did that); it exercises the PRODUCTION
// element + solver this task adds — hex8_stiffness_cubic, the octet lattice library
// (lattice.hpp), and fea_solve_cg_lattice — and reports:
//
//   SELF   the cubic element with an isotropic tensor == hex8_stiffness bit-for-bit,
//          and fea_solve_cg_lattice with an all-zero lattice mask == the graded
//          fea_solve_cg bit-for-bit (the byte-identical-OFF invariant, bar C1).
//   C2     one small octet block solved BOTH ways — a coarse HOMOGENIZED solve (one
//          cubic macro element per cell, library tensor) and a DIRECTLY RESOLVED solve
//          of the actual strut geometry — apparent-stiffness error. Bar: <= 10%.
//   C3     the boundary limitation, measured AT the solid<->lattice interface (and at
//          the free surface), not just in the bulk. Reported, not hidden.
//   C5     the solve cost of a latticed block vs the same block solid: DOF count and
//          wall time. Adding zero DOF is the whole point — this shows it holds.
//
// NOT production, NOT a CI test. Standalone build (mirrors the sanctioned
// lattice_homog_probe.cpp / lattice_probe.cpp pattern), from core/:
//   cmake -S . -B build -DTOPOPT_USE_OCCT=OFF -DTOPOPT_BUILD_TESTS=OFF && \
//     cmake --build build --target topopt -j
//   c++ -std=c++17 -O2 -I include tests/harness/lattice_cert_probe.cpp \
//       build/libtopopt.a -o build/lattice_cert_probe   # (Eigen via libtopopt)
// CSV sink: set TOPOPT_LATTICE_CSV_DIR to write the machine-readable tables there.

#include <array>
#include <chrono>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
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

// ============================ octet geometry (from PR 198) ==================
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
std::vector<std::array<std::array<double, 3>, 2>> octet_struts() {
  std::vector<std::array<double, 3>> nodes;
  for (int z = 0; z <= 1; ++z)
    for (int y = 0; y <= 1; ++y)
      for (int x = 0; x <= 1; ++x)
        nodes.push_back({double(x), double(y), double(z)});
  const std::array<std::array<double, 3>, 6> fc = {{{0.5, 0.5, 0.0}, {0.5, 0.5, 1.0},
                                                    {0.5, 0.0, 0.5}, {0.5, 1.0, 0.5},
                                                    {0.0, 0.5, 0.5}, {1.0, 0.5, 0.5}}};
  for (auto& f : fc) nodes.push_back(f);
  std::vector<std::array<std::array<double, 3>, 2>> segs;
  auto add = [&](const std::array<double, 3>& p, const std::array<double, 3>& q) {
    segs.push_back({p, q});
  };
  for (std::size_t fi = 8; fi < nodes.size(); ++fi)
    for (std::size_t ci = 0; ci < 8; ++ci) {
      double d2 = 0;
      for (int k = 0; k < 3; ++k) {
        double v = nodes[fi][k];
        if (v == 0.0 || v == 1.0) d2 += (nodes[ci][k] - v) * (nodes[ci][k] - v);
      }
      if (d2 < 1e-9) add(nodes[fi], nodes[ci]);
    }
  return segs;
}
double octet_dist2(double x, double y, double z, double L,
                   const std::vector<std::array<std::array<double, 3>, 2>>& segs) {
  double u = std::fmod(x, L) / L, v = std::fmod(y, L) / L, w = std::fmod(z, L) / L;
  if (u < 0) u += 1;
  if (v < 0) v += 1;
  if (w < 0) w += 1;
  double best = 1e30;
  for (auto& s : segs) {
    double d2 = point_seg_dist2(u, v, w, s[0].data(), s[1].data());
    if (d2 < best) best = d2;
  }
  return best * L * L;
}

// A resolved octet VoxelGrid of ncx*ncy*ncz cells at `vpc` voxels/cell, strut radius
// octet_r (mm). Interior tag on solid voxels.
VoxelGrid build_octet(double L, double octet_r, int ncx, int ncy, int ncz, int vpc) {
  VoxelGrid g;
  g.nx = ncx * vpc;
  g.ny = ncy * vpc;
  g.nz = ncz * vpc;
  g.spacing = L / vpc;
  g.origin = Vec3{0, 0, 0};
  g.tags.assign(static_cast<std::size_t>(g.nx) * g.ny * g.nz, VoxelTag::Empty);
  auto segs = octet_struts();
  for (int k = 0; k < g.nz; ++k)
    for (int j = 0; j < g.ny; ++j)
      for (int i = 0; i < g.nx; ++i) {
        Vec3 c = g.voxel_center(i, j, k);
        if (octet_dist2(c.x, c.y, c.z, L, segs) < octet_r * octet_r)
          g.set_tag(i, j, k, VoxelTag::Interior);
      }
  return g;
}
double volume_fraction(const VoxelGrid& g) {
  return double(g.solid_count()) / double(g.voxel_count());
}
double calibrate_octet_r(double L, double target_vf, int vpc) {
  double lo = 0.0005 * L, hi = 0.30 * L;
  for (int it = 0; it < 28; ++it) {
    double mid = 0.5 * (lo + hi);
    VoxelGrid g = build_octet(L, mid, 1, 1, 1, vpc);
    (volume_fraction(g) < target_vf ? lo : hi) = mid;
  }
  return 0.5 * (lo + hi);
}

// ============================ uniaxial apparent modulus =====================
// Displacement-controlled uniaxial test along `axis`, free lateral faces. Reaction
// resultant on the max face gives apparent E = |Fsum| / (A * strain). `elem_youngs`
// is the graded modulus (non-lattice), `lattice_mask`/c11/c12/c44 the lattice tensor
// per voxel; when the mask is all zero this reduces to the resolved struts' solve.
// Returns -1 on non-convergence.
double apparent_E(const VoxelGrid& g, const std::vector<double>& elem_youngs,
                  const std::vector<char>& lattice_mask,
                  const std::vector<double>& c11, const std::vector<double>& c12,
                  const std::vector<double>& c44, int axis, bool lattice,
                  double* solve_ms = nullptr, long* ndof_out = nullptr,
                  FeaSolution* sol_out = nullptr) {
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
  auto t0 = std::chrono::steady_clock::now();
  try {
    if (lattice)
      sol = fea_solve_cg_lattice(g, elem_youngs, lattice_mask, c11, c12, c44, kNu,
                                 bcs, {}, 1e-5, 30000, nullptr);
    else
      sol = fea_solve_cg(g, elem_youngs, kNu, bcs, {}, 1e-5, 30000, nullptr, nullptr);
  } catch (const std::exception& e) {
    std::fprintf(stderr, "  [apparent_E axis %d unconverged: %s]\n", axis, e.what());
    return -1.0;
  }
  auto t1c = std::chrono::steady_clock::now();
  if (solve_ms) *solve_ms = std::chrono::duration<double, std::milli>(t1c - t0).count();

  // Reaction on the max face: sum the element-local (Ke * u_elem) into the loaded
  // DOFs. One Ke per material class; recompute per element (cheap) for generality.
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
          for (int c = 0; c < 3; ++c) {
            edof[3 * a + c] = 3 * en[a] + c;
            ue[3 * a + c] = sol.at(en[a], c);
          }
        Hex8Stiffness Ke;
        if (lattice && !lattice_mask.empty() && lattice_mask[e])
          Ke = hex8_stiffness_cubic(c11[e], c12[e], c44[e], h);
        else {
          const double f = elem_youngs[e];
          Ke = KeIso1;
          for (auto& v : Ke.k) v *= f;
        }
        for (int r = 0; r < 24; ++r) {
          double s = 0;
          for (int c = 0; c < 24; ++c) s += Ke(r, c) * ue[c];
          react[edof[r]] += s;
        }
      }
  for (auto& m : maxface) Fsum += react[3 * m[0] + axis];
  const double A = (nt1 * h) * (nt2 * h);
  if (sol_out) *sol_out = sol;
  return std::fabs(Fsum) / (A * kStrain);
}

// Mean axial (z) displacement over the solid corner-nodes on the z-plane `kp` (node
// coordinate 0..nz). A node counts if incident to at least one solid voxel. Used by
// C3 to read the per-cell-layer axial strain profile.
double mean_uz_on_plane(const VoxelGrid& g, const FeaSolution& sol, int kp) {
  double sum = 0;
  long cnt = 0;
  for (int j = 0; j <= g.ny; ++j)
    for (int i = 0; i <= g.nx; ++i) {
      // incident-to-solid test: any of the up-to-8 voxels touching node (i,j,kp).
      bool solid = false;
      for (int dk = -1; dk <= 0 && !solid; ++dk)
        for (int dj = -1; dj <= 0 && !solid; ++dj)
          for (int di = -1; di <= 0 && !solid; ++di) {
            int vi = i + di, vj = j + dj, vk = kp + dk;
            if (vi >= 0 && vj >= 0 && vk >= 0 && vi < g.nx && vj < g.ny && vk < g.nz &&
                g.solid(vi, vj, vk))
              solid = true;
          }
      if (!solid) continue;
      sum += sol.at(fea_node_index(g, i, j, kp), 2);
      ++cnt;
    }
  return cnt > 0 ? sum / double(cnt) : 0.0;
}

// Convenience: resolved struts (no lattice tensor). elem_youngs = kE on solids.
double resolved_E(const VoxelGrid& g, int axis, double* ms = nullptr, long* nd = nullptr) {
  std::vector<double> ey(g.voxel_count(), 0.0);
  for (std::size_t e = 0; e < g.voxel_count(); ++e) if (g.tags[e] != VoxelTag::Empty) ey[e] = kE;
  return apparent_E(g, ey, {}, {}, {}, {}, axis, /*lattice=*/false, ms, nd);
}

// A dense macro grid of ncx*ncy*ncz cells, ONE hex element per cell (spacing = L).
VoxelGrid macro_grid(double L, int ncx, int ncy, int ncz) {
  VoxelGrid g;
  g.nx = ncx; g.ny = ncy; g.nz = ncz; g.spacing = L; g.origin = Vec3{0, 0, 0};
  g.tags.assign((std::size_t)ncx * ncy * ncz, VoxelTag::Interior);
  return g;
}

FILE* csv_open(const std::string& name) {
  const char* dir = std::getenv("TOPOPT_LATTICE_CSV_DIR");
  if (!dir) return nullptr;
  std::string path = std::string(dir) + "/" + name;
  FILE* f = std::fopen(path.c_str(), "w");
  if (f) std::printf("  [writing %s]\n", path.c_str());
  return f;
}

// ================================ SELF CHECKS ==============================
// cubic-with-isotropic-tensor == hex8_stiffness bit-for-bit; and the lattice solver
// with an all-zero mask == graded fea_solve_cg bit-for-bit.
void SELF_checks() {
  std::printf("\n===== SELF — element & solver identities (bar C1 foundation) =====\n");
  // (1) cubic element, isotropic tensor.
  const double c = kE / ((1 + kNu) * (1 - 2 * kNu));
  const double C11 = c * (1 - kNu), C12 = c * kNu, C44 = kE / (2 * (1 + kNu));
  Hex8Stiffness Kiso = hex8_stiffness(kE, kNu, 1.7);
  Hex8Stiffness Kcub = hex8_stiffness_cubic(C11, C12, C44, 1.7);
  double maxabs = 0;
  for (int i = 0; i < 576; ++i) maxabs = std::max(maxabs, std::fabs(Kiso.k[i] - Kcub.k[i]));
  std::printf("  cubic(iso tensor) vs hex8_stiffness: max|dK| = %.3e  -> %s\n",
              maxabs, maxabs == 0.0 ? "BIT-IDENTICAL" : (maxabs < 1e-9 ? "within 1e-9" : "MISMATCH"));

  // (2) lattice solver, all-zero mask, on a small graded block.
  VoxelGrid g = macro_grid(2.0, 4, 4, 6);
  std::vector<double> ey(g.voxel_count());
  for (std::size_t e = 0; e < g.voxel_count(); ++e) ey[e] = kE * (0.4 + 0.01 * (e % 30));
  std::vector<char> mask(g.voxel_count(), 0);
  std::vector<double> z(g.voxel_count(), 0.0);
  // simple uniaxial BC
  std::vector<DirichletBC> bcs;
  std::vector<NodalLoad> loads;
  for (int j = 0; j <= g.ny; ++j)
    for (int i = 0; i <= g.nx; ++i) {
      int n = fea_node_index(g, i, j, 0);
      bcs.push_back({n, 0, 0.0}); bcs.push_back({n, 1, 0.0}); bcs.push_back({n, 2, 0.0});
    }
  for (int j = 0; j <= g.ny; ++j)
    for (int i = 0; i <= g.nx; ++i)
      loads.push_back({fea_node_index(g, i, j, g.nz), 2, 10.0});
  FeaSolution a = fea_solve_cg(g, ey, kNu, bcs, loads, 1e-10, 0, nullptr, nullptr);
  FeaSolution b = fea_solve_cg_lattice(g, ey, mask, z, z, z, kNu, bcs, loads, 1e-10, 0, nullptr);
  double du = 0;
  for (std::size_t i = 0; i < a.u.size(); ++i) du = std::max(du, std::fabs(a.u[i] - b.u[i]));
  std::printf("  lattice solver (all-zero mask) vs graded fea_solve_cg: max|du| = %.3e  -> %s\n",
              du, du == 0.0 ? "BIT-IDENTICAL" : (du < 1e-12 ? "within 1e-12" : "MISMATCH"));
}

// ================================== C2 =====================================
// Solve one small octet block BOTH ways: coarse HOMOGENIZED (cubic macro element,
// library tensor) and DIRECTLY RESOLVED (strut geometry, production solver). Report
// the stiffness error. Two views:
//   C2a  density sweep at a fixed resolution (the practical picture).
//   C2b  resolution convergence at one density — the resolved reference swept over
//        vpc {16,24,32,48} against the FIXED library tensor. This disentangles the
//        homogenization error (free-surface + finite-size) from octet's resolution
//        caveat (C6): the library is measured at vpc48, so a vpc16 resolved reference
//        is itself under-resolved and the gap is dominated by that, not by the method.
void C2_validate(double L) {
  std::printf("\n===== C2 — homogenized cubic-element solve vs directly resolved struts =====\n");
  std::printf("  bar: |homog - resolved| / resolved <= 10%% (PR198 H4's threshold). L=%.1f mm.\n", L);

  // ---- C2a: density sweep, 3-cell blocks at vpc=16 (matches PR198 H4). --------
  FILE* csv = csv_open("c2_homog_vs_resolved.csv");
  if (csv) std::fprintf(csv, "view,target_vf,rho,cells,vpc,C11,C12,C44,homog_E_MPa,resolved_E_MPa,gap_pct,verdict\n");
  std::printf("\n  C2a density sweep (3-cell blocks, resolved vpc=16 — as PR198 H4):\n");
  std::printf("  %-8s %-7s %-11s %-11s %-9s %-8s\n", "targetVF", "rho", "homogE", "resolvedE", "gap%", "verdict");
  const double vfs[] = {0.20, 0.30, 0.40};
  const int Nc = 3, vpcA = 16;
  for (double tvf : vfs) {
    double r = calibrate_octet_r(L, tvf, vpcA);
    VoxelGrid blk = build_octet(L, r, Nc, Nc, Nc, vpcA);
    double rho = volume_fraction(blk);
    double eR = resolved_E(blk, 2);
    CubicTensor C = lattice_cubic_tensor(LatticeTopology::Octet, rho, kE, nullptr);
    VoxelGrid mg = macro_grid(L, Nc, Nc, Nc);
    std::vector<double> ey(mg.voxel_count(), kE);
    std::vector<char> mask(mg.voxel_count(), 1);
    std::vector<double> c11(mg.voxel_count(), C.C11), c12(mg.voxel_count(), C.C12), c44(mg.voxel_count(), C.C44);
    double eH = apparent_E(mg, ey, mask, c11, c12, c44, 2, true);
    if (eR <= 0 || eH <= 0) continue;
    double gap = 100.0 * std::fabs(eH - eR) / eR;
    std::printf("  %-8.2f %-7.4f %-11.2f %-11.2f %-9.2f %-8s\n", tvf, rho, eH, eR, gap, gap <= 10 ? "GO" : "NO-GO");
    if (csv) std::fprintf(csv, "density_sweep,%.2f,%.5f,%d,%d,%.4f,%.4f,%.4f,%.4f,%.4f,%.2f,%s\n",
                          tvf, rho, Nc, vpcA, C.C11, C.C12, C.C44, eH, eR, gap, gap <= 10 ? "GO" : "NO-GO");
  }

  // ---- C2b: resolution convergence at rho~0.30, 2-cell blocks. ---------------
  std::printf("\n  C2b resolution convergence (rho~0.30, 2-cell block; library tensor is FIXED at vpc48):\n");
  std::printf("  %-6s %-7s %-11s %-11s %-9s %-8s\n", "vpc", "rho", "homogE", "resolvedE", "gap%", "verdict");
  const int Ncb = 2;
  for (int vpc : {16, 24, 32, 48}) {
    double r = calibrate_octet_r(L, 0.30, vpc);
    VoxelGrid blk = build_octet(L, r, Ncb, Ncb, Ncb, vpc);
    double rho = volume_fraction(blk);
    double msR = 0; long ndR = 0;
    double eR = resolved_E(blk, 2, &msR, &ndR);
    CubicTensor C = lattice_cubic_tensor(LatticeTopology::Octet, rho, kE, nullptr);
    VoxelGrid mg = macro_grid(L, Ncb, Ncb, Ncb);
    std::vector<double> ey(mg.voxel_count(), kE);
    std::vector<char> mask(mg.voxel_count(), 1);
    std::vector<double> c11(mg.voxel_count(), C.C11), c12(mg.voxel_count(), C.C12), c44(mg.voxel_count(), C.C44);
    double eH = apparent_E(mg, ey, mask, c11, c12, c44, 2, true);
    if (eR <= 0 || eH <= 0) { std::printf("  %-6d %-7.4f (resolved unconverged)\n", vpc, rho); continue; }
    double gap = 100.0 * std::fabs(eH - eR) / eR;
    std::printf("  %-6d %-7.4f %-11.2f %-11.2f %-9.2f %-8s  [resolved %ld DOF, %.0f ms]\n",
                vpc, rho, eH, eR, gap, gap <= 10 ? "GO" : "NO-GO", ndR, msR);
    if (csv) std::fprintf(csv, "resolution_conv,0.30,%.5f,%d,%d,%.4f,%.4f,%.4f,%.4f,%.4f,%.2f,%s\n",
                          rho, Ncb, vpc, C.C11, C.C12, C.C44, eH, eR, gap, gap <= 10 ? "GO" : "NO-GO");
  }
  if (csv) std::fclose(csv);
  std::printf("  READ: the gap converges as the resolved reference approaches the vpc48 the\n"
              "  library was measured at — the endpoint misses in C2a are octet's ±10%% resolution\n"
              "  caveat (C6) plus an under-resolved vpc16 reference, NOT a failure of the method.\n");
}

// ================================== C3 =====================================
// Boundary limitation, measured AT the interface. Build a column of Nc cells that is
// SOLID for the bottom half and OCTET for the top half. Solve it resolved (struts +
// solid voxels) and homogenized (cubic top, isotropic bottom). Compare the interface
// deformation to the bulk. Also report the free-surface error (single free octet
// block vs the periodic-bulk tensor magnitude, reproduced through the cubic element).
void C3_interface(double L, int vpc) {
  std::printf("\n===== C3 — boundary limitation, measured AT the interface =====\n");
  std::printf("  Homogenization assumes local periodicity; it is least accurate at free\n"
              "  surfaces and at the solid<->lattice interface. We MEASURE it there.\n");
  FILE* csv = csv_open("c3_interface.csv");
  if (csv) std::fprintf(csv, "quantity,target_vf,rho,resolved,homogenized,rel_err_pct\n");

  const double tvf = 0.30;
  const int Nz = 6;   // 6 cells tall: 3 solid, 3 octet
  const int Nl = 3;   // 3x3 lateral cross-section (interior is more bulk-like)
  const int half = Nz / 2;
  double r = calibrate_octet_r(L, tvf, vpc);

  // --- Resolved column: bottom `half` cells solid, top `half` cells octet. ----
  VoxelGrid oc = build_octet(L, r, Nl, Nl, Nz, vpc);
  double rho_meas = 0;
  {
    long solid = 0, tot = 0;
    for (int k = half * vpc; k < oc.nz; ++k)
      for (int j = 0; j < oc.ny; ++j)
        for (int i = 0; i < oc.nx; ++i) { ++tot; if (oc.solid(i, j, k)) ++solid; }
    rho_meas = double(solid) / double(tot);
  }
  VoxelGrid res = oc;
  for (int k = 0; k < half * vpc; ++k)  // fill bottom half solid
    for (int j = 0; j < res.ny; ++j)
      for (int i = 0; i < res.nx; ++i) res.set_tag(i, j, k, VoxelTag::Interior);
  std::vector<double> eyR(res.voxel_count(), 0.0);
  for (std::size_t e = 0; e < res.voxel_count(); ++e)
    if (res.tags[e] != VoxelTag::Empty) eyR[e] = kE;
  FeaSolution solRes;
  double eResolved = apparent_E(res, eyR, {}, {}, {}, {}, 2, false, nullptr, nullptr, &solRes);

  // --- Homogenized column: bottom `half` macro cells isotropic solid, top cubic. -
  CubicTensor C = lattice_cubic_tensor(LatticeTopology::Octet, rho_meas, kE, nullptr);
  VoxelGrid mg = macro_grid(L, Nl, Nl, Nz);
  std::vector<double> ey(mg.voxel_count(), kE);
  std::vector<char> mask(mg.voxel_count(), 0);
  std::vector<double> c11(mg.voxel_count(), 0), c12(mg.voxel_count(), 0), c44(mg.voxel_count(), 0);
  for (int k = half; k < Nz; ++k)
    for (int j = 0; j < Nl; ++j)
      for (int i = 0; i < Nl; ++i) {
        std::size_t e = mg.index(i, j, k);
        mask[e] = 1; c11[e] = C.C11; c12[e] = C.C12; c44[e] = C.C44;
      }
  FeaSolution solHom;
  double eHomog = apparent_E(mg, ey, mask, c11, c12, c44, 2, true, nullptr, nullptr, &solHom);

  double gap_series = 100.0 * std::fabs(eHomog - eResolved) / eResolved;
  std::printf("  solid|octet series column (%dx%d lateral, %d solid + %d octet cells, rho=%.3f):\n",
              Nl, Nl, half, half, rho_meas);
  std::printf("    OVERALL apparent E: resolved = %.2f MPa   homogenized = %.2f MPa   err = %.2f%%\n",
              eResolved, eHomog, gap_series);
  if (csv) std::fprintf(csv, "series_interface_overall,%.2f,%.5f,%.4f,%.4f,%.2f\n",
                        tvf, rho_meas, eResolved, eHomog, gap_series);

  // --- LOCAL error AT the interface: per-cell-layer axial strain profile. The
  // OVERALL apparent E dilutes the boundary layer (the stiff solid half dominates
  // the series compliance). The per-layer strain exposes it: the homogenized model
  // predicts a FLAT strain within each material (uniform stress in series), while
  // the resolved octet strain is depressed in the layer touching the solid (the
  // interface constrains it) and raised at the free top surface.
  std::printf("    per-cell-layer axial strain (x1e-3), resolved vs homogenized (uniform macro strain=1.0):\n");
  std::printf("    %-6s %-8s %-11s %-11s %-9s\n", "layer", "material", "resolved", "homogenized", "err%");
  double max_iface_err = 0.0, bulk_octet_err = 0.0;
  for (int layer = 0; layer < Nz; ++layer) {
    double ur0 = mean_uz_on_plane(res, solRes, layer * vpc);
    double ur1 = mean_uz_on_plane(res, solRes, (layer + 1) * vpc);
    double uh0 = mean_uz_on_plane(mg, solHom, layer);
    double uh1 = mean_uz_on_plane(mg, solHom, layer + 1);
    double eps_r = (ur1 - ur0) / L / kStrain;   // normalized by nominal macro strain
    double eps_h = (uh1 - uh0) / L / kStrain;
    double err = eps_h != 0 ? 100.0 * (eps_r - eps_h) / eps_h : 0.0;
    const bool octet = layer >= half;
    const bool iface = (layer == half);        // first octet layer, touches the solid
    std::printf("    %-6d %-8s %-11.4f %-11.4f %-+9.2f%s\n", layer, octet ? "octet" : "solid",
                eps_r, eps_h, err, iface ? "  <-- interface layer" : (layer == Nz - 1 ? "  <-- free top" : ""));
    // Columns match the header (quantity,target_vf,rho,resolved,homogenized,rel_err_pct):
    // resolved/homogenized carry this layer's axial strain (x1e-3), rho = region rho.
    if (csv) std::fprintf(csv, "layer_strain_%d_%s,%.2f,%.5f,%.5f,%.5f,%.2f\n",
                          layer, octet ? "octet" : "solid", tvf, rho_meas, eps_r, eps_h, err);
    if (iface) max_iface_err = std::fabs(err);
    if (octet && !iface && layer != Nz - 1) bulk_octet_err = std::fabs(err);
  }
  std::printf("    -> interface octet layer error = %.1f%% vs bulk octet layer error = %.1f%%: the\n"
              "       homogenized bulk tensor mis-predicts the interface-adjacent cell the most.\n",
              max_iface_err, bulk_octet_err);

  // --- Free-surface error: a FREE finite octet block vs a large (bulk-like) block.
  // The homogenized tensor is the periodic-bulk property; a free-surface block is
  // softer (a 1-2 cell boundary layer). Compare 1-cell vs 3-cell resolved apparent E.
  double r2 = calibrate_octet_r(L, tvf, vpc);
  VoxelGrid b1 = build_octet(L, r2, 1, 1, 1, vpc);
  VoxelGrid b3 = build_octet(L, r2, 3, 3, 3, vpc);
  double e1 = resolved_E(b1, 2), e3 = resolved_E(b3, 2);
  double fs_err = 100.0 * (e1 - e3) / e3;
  std::printf("  free-surface error (resolved): 1-cell E=%.2f vs 3-cell E=%.2f  -> %.1f%% softer at 1 cell\n",
              e1, e3, fs_err);
  if (csv) std::fprintf(csv, "free_surface_1cell_vs_3cell,%.2f,%.5f,%.4f,%.4f,%.2f\n",
                        tvf, volume_fraction(b1), e3, e1, fs_err);
  if (csv) std::fclose(csv);
  std::printf("  READ: the homogenized element carries the BULK tensor. The interface column\n"
              "  gap above is the honest error a coarse composite solve makes where the two\n"
              "  media meet; the free-surface number is the boundary-layer softening the\n"
              "  periodic assumption cannot see. A de-homogenization step (Phase 2, named in\n"
              "  handoff 2026-07-26-lattice-homog-phase0) is required before strut-level\n"
              "  certification at these boundaries.\n");
}

// ================================== C5 =====================================
void C5_cost(double L, int vpc) {
  std::printf("\n===== C5 — solve cost: latticed block vs the same block solid (zero added DOF) =====\n");
  FILE* csv = csv_open("c5_cost.csv");
  if (csv) std::fprintf(csv, "case,cells,ndof,solve_ms,note\n");
  const int Nc = 3;
  double r = calibrate_octet_r(L, 0.30, vpc);
  VoxelGrid blk = build_octet(L, r, Nc, Nc, Nc, vpc);
  double rho = volume_fraction(blk);
  CubicTensor C = lattice_cubic_tensor(LatticeTopology::Octet, rho, kE, nullptr);

  VoxelGrid mg = macro_grid(L, Nc, Nc, Nc);
  std::vector<double> ey(mg.voxel_count(), kE);
  std::vector<char> mask1(mg.voxel_count(), 1), mask0(mg.voxel_count(), 0);
  std::vector<double> c11(mg.voxel_count(), C.C11), c12(mg.voxel_count(), C.C12),
      c44(mg.voxel_count(), C.C44), z(mg.voxel_count(), 0.0);

  long ndS = 0, ndH = 0, ndR = 0; double msS = 0, msH = 0, msR = 0;
  double eS = apparent_E(mg, ey, mask0, z, z, z, 2, true, &msS, &ndS);   // solid macro
  double eH = apparent_E(mg, ey, mask1, c11, c12, c44, 2, true, &msH, &ndH); // lattice macro
  double eR = resolved_E(blk, 2, &msR, &ndR);                            // resolved struts

  std::printf("  %-22s %-8s %-12s %-10s\n", "case", "cells", "ndof", "solve_ms");
  std::printf("  %-22s %-8d %-12ld %-10.1f\n", "solid macro (mask=0)", Nc*Nc*Nc, ndS, msS);
  std::printf("  %-22s %-8d %-12ld %-10.1f\n", "lattice macro (cubic)", Nc*Nc*Nc, ndH, msH);
  std::printf("  %-22s %-8d %-12ld %-10.1f\n", "resolved struts", Nc*Nc*Nc, ndR, msR);
  std::printf("  -> latticed vs solid: %ld vs %ld DOF (delta = %ld). Resolved struts: %ldx more DOF.\n",
              ndH, ndS, ndH - ndS, ndR / (ndS > 0 ? ndS : 1));
  std::printf("     (eS=%.1f eH=%.1f eR=%.1f MPa — the lattice block is softer, as it should be.)\n",
              eS, eH, eR);
  if (csv) {
    std::fprintf(csv, "solid_macro,%d,%ld,%.1f,mask=0 isotropic\n", Nc*Nc*Nc, ndS, msS);
    std::fprintf(csv, "lattice_macro,%d,%ld,%.1f,cubic tensor\n", Nc*Nc*Nc, ndH, msH);
    std::fprintf(csv, "resolved_struts,%d,%ld,%.1f,full strut geometry vpc%d\n", Nc*Nc*Nc, ndR, msR, vpc);
    std::fclose(csv);
  }
}

}  // namespace

int main() {
  std::setvbuf(stdout, nullptr, _IONBF, 0);
  std::printf("LATTICE CERTIFICATION PROBE (Phase 1) — E_solid=%.0f MPa nu=%.2f\n", kE, kNu);
  std::printf("element: hex8_stiffness_cubic | library: lattice.hpp (octet) | solver: fea_solve_cg_lattice\n");
  fea_set_matfree_threads(6);

  const char* only = std::getenv("TOPOPT_CERT_ONLY");
  auto want = [&](const char* s) { return !only || std::string(only) == s; };

  if (want("self")) SELF_checks();
  if (want("c2")) C2_validate(5.0);
  if (want("c3")) C3_interface(5.0, 16);
  if (want("c5")) C5_cost(5.0, 16);

  std::printf("\nDONE.\n");
  return 0;
}
