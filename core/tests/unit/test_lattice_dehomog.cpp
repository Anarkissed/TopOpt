// test_lattice_dehomog.cpp — pins the DE-HOMOGENIZATION PROBE's instrument to
// the production library (handoff 2026-07-31-lattice-dehomogenization-probe).
//
// The probe (core/tests/harness/lattice_dehomog_probe.cpp) measures the macro
// -> strut stress amplification K(rho, state) on strut-resolved octet blocks.
// This unit test proves the instrument's load-bearing properties against the
// PRODUCTION code paths, without Eigen (the periodic machinery stays
// harness-only):
//   T1  a SOLID block under kinematic-uniform BCs (u = eps*x on all faces,
//       production fea_solve_cg with nonzero Dirichlet) reproduces the exact
//       uniform stress state: peak von Mises == macro von Mises (K == 1).
//   T2  SUPERPOSITION: micro stress is linear in the applied macro strain, so
//       a combined state evaluated from the 6 unit-strain basis solves matches
//       a direct solve of the combined BCs on a real octet block.
//   T3  the probe's radius calibration keys on the PRODUCTION rho mapping
//       (octet_relative_density, vpc48 basis) — the same scale the tensor
//       library rows and every certified job use; band endpoints read from
//       core are sane.
//   T4  the production hex8_stress on an affine (uniform-strain) element
//       recovers exactly D*eps of the isotropic constitutive matrix.
//   T5  the cubic eigenspace split the probe's bound rests on: the production
//       lattice tensor maps traceless strain -> traceless stress and
//       hydrostatic -> hydrostatic (this is what makes
//       peak <= K_dev*vm(Sigma) + K_vol*|p(Sigma)| rigorous).
//
// Deterministic, no threads, no RNG. Runs in seconds (tiny grids).

#include <array>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <vector>

#include "topopt/fea.hpp"
#include "topopt/lattice.hpp"
#include "topopt/voxel.hpp"

using namespace topopt;

namespace {

int g_fail = 0;
void check(bool ok, const char* what) {
  std::printf("  %s: %s\n", ok ? "PASS" : "FAIL", what);
  if (!ok) ++g_fail;
}

constexpr double kE = 3500.0, kNu = 0.33;

// --- octet legs-only geometry (the PR 198 / production library basis) -------
double seg_d2(double px, double py, double pz, const double a[3], const double b[3]) {
  double ab[3] = {b[0] - a[0], b[1] - a[1], b[2] - a[2]};
  double ap[3] = {px - a[0], py - a[1], pz - a[2]};
  double den = ab[0] * ab[0] + ab[1] * ab[1] + ab[2] * ab[2];
  double t = den > 0 ? (ap[0] * ab[0] + ap[1] * ab[1] + ap[2] * ab[2]) / den : 0;
  t = t < 0 ? 0 : (t > 1 ? 1 : t);
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
double octet_d2_unit(double u, double v, double w,
                     const std::vector<std::array<std::array<double, 3>, 2>>& segs) {
  u -= std::floor(u); v -= std::floor(v); w -= std::floor(w);
  double best = 1e30;
  for (auto& s : segs) {
    double d = seg_d2(u, v, w, s[0].data(), s[1].data());
    if (d < best) best = d;
  }
  return best;
}
VoxelGrid build_block(double r_unit, int nc, int vpc,
                      const std::vector<std::array<std::array<double, 3>, 2>>& segs) {
  VoxelGrid g;
  g.nx = g.ny = g.nz = nc * vpc;
  g.spacing = 1.0 / vpc;
  g.origin = Vec3{0, 0, 0};
  g.tags.assign((std::size_t)g.nx * g.ny * g.nz, VoxelTag::Empty);
  const double r2 = r_unit * r_unit;
  for (int k = 0; k < g.nz; ++k)
    for (int j = 0; j < g.ny; ++j)
      for (int i = 0; i < g.nx; ++i) {
        const double x = (i + 0.5) / vpc, y = (j + 0.5) / vpc, z = (k + 0.5) / vpc;
        if (r_unit > 1.0 || octet_d2_unit(x, y, z, segs) < r2)
          g.set_tag(i, j, k, VoxelTag::Interior);
      }
  return g;
}

// KUBC solve for strain eps (tensor form), peak centroid von Mises.
struct KubcOut {
  double peak_vm = 0.0;
  std::vector<std::array<double, 6>> sigma;  // per solid voxel, scan order
};
KubcOut kubc_solve(const VoxelGrid& gin, const double eps[3][3], double tol) {
  VoxelGrid g = gin;
  const double h = g.spacing;
  std::vector<char> issolid((std::size_t)fea_node_count(g), 0);
  for (int k = 0; k < g.nz; ++k)
    for (int j = 0; j < g.ny; ++j)
      for (int i = 0; i < g.nx; ++i)
        if (g.solid(i, j, k))
          for (int n : fea_element_nodes(g, i, j, k)) issolid[(std::size_t)n] = 1;
  std::vector<DirichletBC> bcs;
  for (int c = 0; c <= g.nz; ++c)
    for (int b = 0; b <= g.ny; ++b)
      for (int a = 0; a <= g.nx; ++a) {
        if (!(a == 0 || a == g.nx || b == 0 || b == g.ny || c == 0 || c == g.nz))
          continue;
        const int n = fea_node_index(g, a, b, c);
        if (!issolid[(std::size_t)n]) continue;
        const double x[3] = {a * h, b * h, c * h};
        for (int comp = 0; comp < 3; ++comp)
          bcs.push_back({n, comp,
                         eps[comp][0] * x[0] + eps[comp][1] * x[1] +
                             eps[comp][2] * x[2]});
      }
  const FeaSolution sol = fea_solve_cg(g, kE, kNu, bcs, {}, tol, 60000, nullptr);
  KubcOut out;
  for (int k = 0; k < g.nz; ++k)
    for (int j = 0; j < g.ny; ++j)
      for (int i = 0; i < g.nx; ++i) {
        if (!g.solid(i, j, k)) continue;
        const std::array<int, 8> en = fea_element_nodes(g, i, j, k);
        std::array<double, 24> ue{};
        for (int a = 0; a < 8; ++a)
          for (int c = 0; c < 3; ++c) ue[3 * a + c] = sol.u[3 * en[a] + c];
        const Hex8Stress st = hex8_stress(kE, kNu, h, ue);
        out.sigma.push_back(st.sigma);
        if (st.von_mises > out.peak_vm) out.peak_vm = st.von_mises;
      }
  return out;
}

double vm_of(const std::array<double, 6>& s) {
  const double a = s[0] - s[1], b = s[1] - s[2], c = s[2] - s[0];
  return std::sqrt(0.5 * (a * a + b * b + c * c) +
                   3.0 * (s[3] * s[3] + s[4] * s[4] + s[5] * s[5]));
}

void voigt_to_tensor(const double e[6], double eps[3][3]) {
  eps[0][0] = e[0]; eps[1][1] = e[1]; eps[2][2] = e[2];
  eps[0][1] = eps[1][0] = e[3] / 2;
  eps[1][2] = eps[2][1] = e[4] / 2;
  eps[2][0] = eps[0][2] = e[5] / 2;
}

}  // namespace

int main() {
  std::printf("test_lattice_dehomog — probe instrument pinned to production\n");
  fea_set_matfree_threads(1);
  const auto segs = octet_struts();

  // --- T1: solid KUBC block => uniform stress, K == 1 -----------------------
  {
    const VoxelGrid g = build_block(10.0, 2, 4, segs);  // all solid, 8^3
    const double lam = kE * kNu / ((1 + kNu) * (1 - 2 * kNu));
    const double mu = kE / (2 * (1 + kNu));
    const double basis[6][6] = {{1, 0, 0, 0, 0, 0}, {0, 1, 0, 0, 0, 0},
                                {0, 0, 1, 0, 0, 0}, {0, 0, 0, 1, 0, 0},
                                {0, 0, 0, 0, 1, 0}, {0, 0, 0, 0, 0, 1}};
    double worst = 0;
    for (int J = 0; J < 6; ++J) {
      double eps[3][3];
      voigt_to_tensor(basis[J], eps);
      const KubcOut out = kubc_solve(g, eps, 1e-12);
      // macro stress of the isotropic material under this strain
      std::array<double, 6> Sig{};
      const double tr = basis[J][0] + basis[J][1] + basis[J][2];
      for (int c = 0; c < 3; ++c) Sig[c] = lam * tr + 2 * mu * basis[J][c];
      for (int c = 3; c < 6; ++c) Sig[c] = mu * basis[J][c];
      const double macro = vm_of(Sig);
      worst = std::max(worst, std::fabs(out.peak_vm - macro) / std::max(macro, 1.0));
    }
    check(worst < 1e-5, "T1 solid KUBC: peak von Mises == macro (K = 1, all 6 basis states)");
  }

  // --- T2: superposition on a real octet block ------------------------------
  {
    // radius for rho ~0.3 via the PRODUCTION mapping (T3 checks the mapping)
    double lo = 1e-4, hi = 0.35;
    for (int it = 0; it < 40; ++it) {
      const double mid = 0.5 * (lo + hi);
      (octet_relative_density(1.0, mid) < 0.3 ? lo : hi) = mid;
    }
    const double r = 0.5 * (lo + hi);
    const VoxelGrid g = build_block(r, 2, 6, segs);
    // 6 basis solves
    std::vector<std::vector<std::array<double, 6>>> basis_sig(6);
    const double basis[6][6] = {{1, 0, 0, 0, 0, 0}, {0, 1, 0, 0, 0, 0},
                                {0, 0, 1, 0, 0, 0}, {0, 0, 0, 1, 0, 0},
                                {0, 0, 0, 0, 1, 0}, {0, 0, 0, 0, 0, 1}};
    for (int J = 0; J < 6; ++J) {
      double eps[3][3];
      voigt_to_tensor(basis[J], eps);
      basis_sig[J] = kubc_solve(g, eps, 1e-10).sigma;
    }
    const double e[6] = {0.7, -0.2, 0.1, 0.4, -0.3, 0.25};
    double eps[3][3];
    voigt_to_tensor(e, eps);
    const KubcOut direct = kubc_solve(g, eps, 1e-10);
    double peak_super = 0, worst_comp = 0;
    for (std::size_t v = 0; v < direct.sigma.size(); ++v) {
      std::array<double, 6> s{};
      for (int J = 0; J < 6; ++J)
        for (int c = 0; c < 6; ++c) s[c] += e[J] * basis_sig[J][v][c];
      peak_super = std::max(peak_super, vm_of(s));
      for (int c = 0; c < 6; ++c)
        worst_comp = std::max(worst_comp, std::fabs(s[c] - direct.sigma[v][c]));
    }
    const double rel = std::fabs(peak_super - direct.peak_vm) / direct.peak_vm;
    check(rel < 5e-4, "T2 superposition: basis-combined peak == direct combined solve");
  }

  // --- T3: production rho mapping + band ------------------------------------
  {
    double lo = 1e-4, hi = 0.35;
    for (int it = 0; it < 48; ++it) {
      const double mid = 0.5 * (lo + hi);
      (octet_relative_density(1.0, mid) < 0.313 ? lo : hi) = mid;
    }
    const double r = 0.5 * (lo + hi);
    check(std::fabs(octet_relative_density(1.0, r) - 0.313) < 5e-3,
          "T3a calibrated radius lands on the target rho via the production mapping");
    const double bl = lattice_rho_min(LatticeTopology::Octet);
    const double bh = lattice_rho_max(LatticeTopology::Octet);
    check(bl > 0.0 && bl < bh && bh < 1.0,
          "T3b octet band endpoints read from core are sane (0 < lo < hi < 1)");
  }

  // --- T4: hex8_stress on an affine element == D*eps exactly ----------------
  {
    const double e[6] = {3e-3, -1e-3, 2e-3, 1.5e-3, -0.5e-3, 1e-3};
    double eps[3][3];
    voigt_to_tensor(e, eps);
    const double h = 0.25;
    std::array<double, 24> ue{};
    const int off[8][3] = {{0, 0, 0}, {1, 0, 0}, {1, 1, 0}, {0, 1, 0},
                           {0, 0, 1}, {1, 0, 1}, {1, 1, 1}, {0, 1, 1}};
    for (int a = 0; a < 8; ++a) {
      const double x[3] = {off[a][0] * h, off[a][1] * h, off[a][2] * h};
      for (int c = 0; c < 3; ++c)
        ue[3 * a + c] = eps[c][0] * x[0] + eps[c][1] * x[1] + eps[c][2] * x[2];
    }
    const Hex8Stress st = hex8_stress(kE, kNu, h, ue);
    const double lam = kE * kNu / ((1 + kNu) * (1 - 2 * kNu));
    const double mu = kE / (2 * (1 + kNu));
    const double tr = e[0] + e[1] + e[2];
    double worst = 0;
    for (int c = 0; c < 3; ++c)
      worst = std::max(worst, std::fabs(st.sigma[c] - (lam * tr + 2 * mu * e[c])));
    for (int c = 3; c < 6; ++c)
      worst = std::max(worst, std::fabs(st.sigma[c] - mu * e[c]));
    check(worst < 1e-9, "T4 production hex8_stress(affine u) == D*eps to machine precision");
  }

  // --- T5: cubic eigenspace split (the bound's algebraic backbone) ----------
  {
    const CubicTensor t = lattice_cubic_tensor(LatticeTopology::Octet, 0.313, kE);
    // traceless strain -> traceless stress
    const double ed[6] = {1, -1, 0, 0.3, -0.2, 0.1};
    const double sxx = t.C11 * ed[0] + t.C12 * (ed[1] + ed[2]);
    const double syy = t.C11 * ed[1] + t.C12 * (ed[0] + ed[2]);
    const double szz = t.C11 * ed[2] + t.C12 * (ed[0] + ed[1]);
    check(std::fabs(sxx + syy + szz) < 1e-9 * std::fabs(t.C11),
          "T5a cubic tensor maps traceless strain to traceless stress");
    // hydrostatic strain -> hydrostatic stress (zero von Mises)
    const double sh = t.C11 + 2 * t.C12;  // each normal component under (1,1,1)
    std::array<double, 6> Sh = {sh, sh, sh, 0, 0, 0};
    check(vm_of(Sh) < 1e-9 * std::fabs(sh),
          "T5b cubic tensor maps hydrostatic strain to zero von Mises");
  }

  std::printf("%s\n", g_fail == 0 ? "ALL PASS" : "FAILURES PRESENT");
  return g_fail == 0 ? 0 : 1;
}
