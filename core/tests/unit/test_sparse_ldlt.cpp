// Brief E2, item 1: the sparse symmetric solve as one call (sparse_ldlt.hpp). On a made frame of more than 20,000
// beams (a 30 x 30 x 9 grid of nodes, a beam along every grid line, the bottom layer held, the top layer pushed
// sideways and down), Accelerate's LDLT and Eigen's SimplicialLDLT give the same displacements to 1e-6, both pass the
// residual gate, and a factor predicted larger than the memory limit is refused before any numeric work.
#include "topopt/fea.hpp"
#include "topopt/sparse_ldlt.hpp"

#include <algorithm>
#include <array>
#include <cmath>
#include <cstdio>
#include <vector>

namespace {

int g_checks = 0, g_failures = 0;
#define CHECK(cond, msg)                                            \
  do {                                                             \
    ++g_checks;                                                    \
    if (!(cond)) {                                                 \
      ++g_failures;                                                \
      std::fprintf(stderr, "FAIL (line %d): %s\n", __LINE__, msg); \
    }                                                              \
  } while (0)

struct Frame {
  topopt::SymmetricLower k;
  std::vector<double> f;
  std::size_t beams = 0;
};

Frame made_frame() {
  const int NX = 30, NY = 30, NZ = 9;
  const double L = 2.0, d = 0.8, E = 1600.0, nu = 0.39;
  auto node = [&](int i, int j, int k) { return (k * NY + j) * NX + i; };
  const int nn = NX * NY * NZ;
  // free numbering: the bottom layer (k = 0) is held
  std::vector<int> fi(static_cast<std::size_t>(6 * nn), -1);
  int nf = 0;
  for (int n = 0; n < nn; ++n)
    if (n >= NX * NY)
      for (int c = 0; c < 6; ++c) fi[static_cast<std::size_t>(6 * n + c)] = nf++;
  Frame fr;
  fr.k.n = nf;
  fr.f.assign(static_cast<std::size_t>(nf), 0.0);
  const double r = 0.5 * d, A = M_PI * r * r, I = M_PI * r * r * r * r / 4.0, J = 2.0 * I;
  const double G = E / (2.0 * (1.0 + nu)), ks = 6.0 * (1.0 + nu) / (7.0 + 6.0 * nu);
  const topopt::FrameStiffness kl = topopt::frame2_stiffness(E, G, A, I, I, J, L, ks);
  auto add_beam = [&](int a, int b, const std::array<double, 3>& ex) {
    const std::array<double, 3> ref = std::fabs(ex[2]) < 0.9 ? std::array<double, 3>{0, 0, 1} : std::array<double, 3>{1, 0, 0};
    std::array<double, 3> ey{ref[1] * ex[2] - ref[2] * ex[1], ref[2] * ex[0] - ref[0] * ex[2], ref[0] * ex[1] - ref[1] * ex[0]};
    const double ny = std::sqrt(ey[0] * ey[0] + ey[1] * ey[1] + ey[2] * ey[2]);
    for (double& v : ey) v /= ny;
    const std::array<double, 3> ez{ex[1] * ey[2] - ex[2] * ey[1], ex[2] * ey[0] - ex[0] * ey[2], ex[0] * ey[1] - ex[1] * ey[0]};
    const std::array<std::array<double, 3>, 3> R{ex, ey, ez};
    double T[12][12] = {};
    for (int blk = 0; blk < 4; ++blk)
      for (int p = 0; p < 3; ++p)
        for (int q = 0; q < 3; ++q) T[3 * blk + p][3 * blk + q] = R[static_cast<std::size_t>(p)][static_cast<std::size_t>(q)];
    double KT[12][12] = {}, K[12][12] = {};
    for (int p = 0; p < 12; ++p)
      for (int q = 0; q < 12; ++q)
        for (int s = 0; s < 12; ++s) KT[p][q] += kl(p, s) * T[s][q];
    for (int p = 0; p < 12; ++p)
      for (int q = 0; q < 12; ++q)
        for (int s = 0; s < 12; ++s) K[p][q] += T[s][p] * KT[s][q];
    int dof[12];
    for (int c = 0; c < 6; ++c) {
      dof[c] = fi[static_cast<std::size_t>(6 * a + c)];
      dof[6 + c] = fi[static_cast<std::size_t>(6 * b + c)];
    }
    for (int p = 0; p < 12; ++p)
      for (int q = 0; q < 12; ++q) {
        const int rr = dof[p], cc = dof[q];
        if (rr < 0 || cc < 0 || rr < cc || K[p][q] == 0.0) continue;
        fr.k.row.push_back(rr);
        fr.k.col.push_back(cc);
        fr.k.val.push_back(K[p][q]);
      }
    ++fr.beams;
  };
  for (int k = 0; k < NZ; ++k)
    for (int j = 0; j < NY; ++j)
      for (int i = 0; i < NX; ++i) {
        if (i + 1 < NX) add_beam(node(i, j, k), node(i + 1, j, k), {1, 0, 0});
        if (j + 1 < NY) add_beam(node(i, j, k), node(i, j + 1, k), {0, 1, 0});
        if (k + 1 < NZ) add_beam(node(i, j, k), node(i, j, k + 1), {0, 0, 1});
      }
  for (int j = 0; j < NY; ++j)
    for (int i = 0; i < NX; ++i) {
      const int n = node(i, j, NZ - 1);
      fr.f[static_cast<std::size_t>(fi[static_cast<std::size_t>(6 * n + 0)])] = 0.05;
      fr.f[static_cast<std::size_t>(fi[static_cast<std::size_t>(6 * n + 2)])] = -0.1;
    }
  return fr;
}

void test_backends_agree() {
  const Frame fr = made_frame();
  std::printf("frame: %zu beams, %d free dofs, %zu lower entries\n", fr.beams, fr.k.n, fr.k.val.size());
  CHECK(fr.beams >= 20000, "the made frame has at least 20,000 beams");
  if (!topopt::sparse_ldlt_available(topopt::SparseLdltBackend::Eigen) ||
      !topopt::sparse_ldlt_available(topopt::SparseLdltBackend::Accelerate)) {
    std::printf("SKIP: this build has %s only\n",
                topopt::sparse_ldlt_available(topopt::SparseLdltBackend::Eigen) ? "Eigen" : "Accelerate");
    topopt::SparseLdltResult one = topopt::sparse_ldlt_solve(fr.k, fr.f);
    CHECK(one.ok, "the build's own backend solves the frame");
    return;
  }
  topopt::SparseLdltOptions oa, oe;
  oa.backend = topopt::SparseLdltBackend::Accelerate;
  oe.backend = topopt::SparseLdltBackend::Eigen;
  const topopt::SparseLdltResult a = topopt::sparse_ldlt_solve(fr.k, fr.f, oa);
  const topopt::SparseLdltResult e = topopt::sparse_ldlt_solve(fr.k, fr.f, oe);
  std::printf("Accelerate %s: residual %.3g, factor %.4f GB; Eigen %s: residual %.3g, factor %.4f GB\n",
              a.method.c_str(), a.residual, a.factor_gb, e.method.c_str(), e.residual, e.factor_gb);
  CHECK(a.ok && a.backend == "Accelerate" && a.method == "LDLT", "Accelerate's LDLT solves the frame and passes the gate");
  CHECK(e.ok && e.backend == "Eigen", "Eigen's SimplicialLDLT solves the frame and passes the gate");
  CHECK(a.x.size() == e.x.size(), "the same number of unknowns");
  double big = 0.0, diff = 0.0;
  for (std::size_t i = 0; i < a.x.size() && i < e.x.size(); ++i) {
    big = std::max(big, std::fabs(a.x[i]));
    diff = std::max(diff, std::fabs(a.x[i] - e.x[i]));
  }
  std::printf("largest displacement %.6g, largest difference %.3g (relative %.3g)\n", big, diff, big > 0 ? diff / big : 0.0);
  CHECK(big > 0.0 && diff <= 1e-6 * big, "the two backends agree to 1e-6");
  CHECK(e.factor_gb > 0.0 && a.factor_gb > 0.0, "both predict a factor size");
}

void test_too_large_is_refused() {
  const Frame fr = made_frame();
  for (const auto be : {topopt::SparseLdltBackend::Accelerate, topopt::SparseLdltBackend::Eigen}) {
    if (!topopt::sparse_ldlt_available(be)) continue;
    topopt::SparseLdltOptions o;
    o.backend = be;
    o.memory_limit_gb = 1e-6;
    const topopt::SparseLdltResult r = topopt::sparse_ldlt_solve(fr.k, fr.f, o);
    CHECK(r.symbolic_ok && r.too_large && !r.numeric_ok && !r.ok && r.x.empty(),
          "a factor predicted over the memory limit is refused before the numeric work");
  }
}

}  // namespace

int main() {
  test_backends_agree();
  test_too_large_is_refused();
  std::printf("%d checks, %d failures\n", g_checks, g_failures);
  return g_failures == 0 ? 0 : 1;
}
