// The DKT plate-bending triangle (Batoz, Bathe & Ho 1980).
//
// The element is transcribed from the paper's Appendix A, which is nine-component
// vectors of hand-written algebra: a single mistyped subscript produces a matrix
// that still looks plausible. So the checks here are the ones a typo CANNOT pass --
// exact rigid-body modes, an exact constant-curvature patch test, and convergence to
// the closed-form thin-plate solutions the paper itself tabulates.
//
// No third-party framework (ARCHITECTURE §4). Public API only.

#include "topopt/fea.hpp"

#include <cmath>
#include <cstdio>
#include <stdexcept>
#include <algorithm>
#include <vector>

namespace {

int g_checks = 0;
int g_failures = 0;

#define CHECK(cond, msg)                                            \
  do {                                                             \
    ++g_checks;                                                    \
    if (!(cond)) {                                                 \
      ++g_failures;                                                \
      std::fprintf(stderr, "FAIL (line %d): %s\n", __LINE__, msg); \
    }                                                              \
  } while (0)

constexpr double kE = 10.92e6;   // the classic plate-benchmark modulus
constexpr double kNu = 0.3;

void test_symmetry_and_rigid_body_modes() {
  const double x[3] = {0.0, 2.0, 0.4};
  const double y[3] = {0.0, 0.3, 1.7};
  const topopt::DktStiffness K = topopt::dkt_stiffness(x, y, kE, kNu, 0.1);

  double asym = 0.0, scale = 0.0;
  for (int i = 0; i < 9; ++i)
    for (int j = 0; j < 9; ++j) {
      asym = std::max(asym, std::fabs(K(i, j) - K(j, i)));
      scale = std::max(scale, std::fabs(K(i, j)));
    }
  CHECK(asym < 1e-9 * scale, "DKT stiffness is symmetric");

  // ★ THE THREE RIGID-BODY MODES OF A PLATE: a uniform lift, and two tilts. Each
  // must produce ZERO nodal force. A mistyped coefficient in Appendix A almost
  // always breaks one of these, which is why they come first.
  auto force_from = [&](const double u[9], double f[9]) {
    for (int i = 0; i < 9; ++i) {
      f[i] = 0.0;
      for (int j = 0; j < 9; ++j) f[i] += K(i, j) * u[j];
    }
  };
  double f[9];
  // (a) uniform translation w = 1, no rotation
  const double lift[9] = {1, 0, 0, 1, 0, 0, 1, 0, 0};
  force_from(lift, f);
  double worst = 0.0;
  for (double v : f) worst = std::max(worst, std::fabs(v));
  CHECK(worst < 1e-6 * scale, "a uniform lift produces no force");

  // (b) and (c) the two rigid tilts. The paper's dof are (w, theta_x, theta_y) with
  // theta_x = dw/dy and theta_y = -dw/dx (its beta convention), so a plane
  // w = c1*x + c2*y has theta_x = c2, theta_y = -c1 at every node.
  for (int mode = 0; mode < 2; ++mode) {
    const double c1 = (mode == 0) ? 1.0 : 0.0;
    const double c2 = (mode == 0) ? 0.0 : 1.0;
    double tilt[9];
    for (int n = 0; n < 3; ++n) {
      tilt[3 * n + 0] = c1 * x[n] + c2 * y[n];
      tilt[3 * n + 1] = c2;
      tilt[3 * n + 2] = -c1;
    }
    force_from(tilt, f);
    worst = 0.0;
    for (double v : f) worst = std::max(worst, std::fabs(v));
    CHECK(worst < 1e-6 * scale,
          mode == 0 ? "a rigid tilt about y produces no force"
                    : "a rigid tilt about x produces no force");
    if (!(worst < 1e-6 * scale))
      std::fprintf(stderr, "   tilt %d residual force %.3e (scale %.3e)\n", mode, worst, scale);
  }
}

void test_constant_curvature_patch() {
  // ★ THE PATCH TEST. Impose a field of CONSTANT curvature -- w = (x^2)/2, so
  // kappa_xx = 1 and the others zero -- and the strain energy must equal the exact
  // value (1/2) kappa^T Db kappa * Area, for ANY triangle. This is the property that
  // makes the element converge, and it fails loudly on a transcription slip.
  const double t = 0.1;
  const double D = kE * t * t * t / (12.0 * (1.0 - kNu * kNu));
  const double tris[3][2][3] = {
      {{0.0, 1.0, 0.0}, {0.0, 0.0, 1.0}},        // right isoceles
      {{0.0, 2.3, 0.7}, {0.0, 0.4, 1.9}},        // scalene
      {{-1.0, 0.5, 1.4}, {2.0, -0.3, 1.1}}};     // arbitrary, off-origin
  for (int c = 0; c < 3; ++c) {
    const double* x = tris[c][0];
    const double* y = tris[c][1];
    const topopt::DktStiffness K = topopt::dkt_stiffness(x, y, kE, kNu, t);
    double u[9];
    for (int n = 0; n < 3; ++n) {
      u[3 * n + 0] = 0.5 * x[n] * x[n];   // w = x^2/2
      u[3 * n + 1] = 0.0;                 // theta_x = dw/dy = 0
      u[3 * n + 2] = -x[n];               // theta_y = -dw/dx = -x
    }
    double energy = 0.0;
    for (int i = 0; i < 9; ++i)
      for (int j = 0; j < 9; ++j) energy += 0.5 * u[i] * K(i, j) * u[j];
    const double area = 0.5 * std::fabs((x[2] - x[0]) * (y[0] - y[1]) -
                                        (x[0] - x[1]) * (y[2] - y[0]));
    const double exact = 0.5 * D * area;    // kappa_xx = 1, all else 0
    CHECK(std::fabs(energy - exact) < 1e-8 * exact,
          "constant-curvature patch test: strain energy is exact");
    if (!(std::fabs(energy - exact) < 1e-8 * exact))
      std::fprintf(stderr, "   tri %d: energy %.9e expected %.9e (ratio %.6f)\n",
                   c, energy, exact, energy / exact);
  }
}

void test_shell_membrane_is_exact() {
  // ★ THE MEMBRANE HALF. A constant-strain triangle stretched by a UNIFORM in-plane
  // strain must store exactly (1/2) eps^T Dm eps * t * A. Constant strain means the
  // CST is exact here, not convergent -- so any deviation is an assembly error.
  const double x[3] = {0.0, 2.0, 0.5}, y[3] = {0.0, 0.4, 1.6};
  const double t = 0.1, eps = 1e-3;
  const topopt::ShellStiffness K =
      topopt::shell3_stiffness(x, y, kE, kNu, t, 0.0);   // drilling OFF for this
  double u[18] = {};
  for (int n = 0; n < 3; ++n) u[6 * n + 0] = eps * x[n];  // u = eps*x, v = 0
  double energy = 0.0;
  for (int i = 0; i < 18; ++i)
    for (int j = 0; j < 18; ++j) energy += 0.5 * u[i] * K(i, j) * u[j];
  const double A = 0.5 * std::fabs((x[2]-x[0])*(y[0]-y[1]) - (x[0]-x[1])*(y[2]-y[0]));
  const double exact = 0.5 * (kE / (1.0 - kNu * kNu)) * eps * eps * t * A;
  CHECK(std::fabs(energy - exact) < 1e-9 * exact,
        "uniform membrane strain stores exactly the closed-form energy");
  if (!(std::fabs(energy - exact) < 1e-9 * exact))
    std::fprintf(stderr, "   membrane energy %.9e expected %.9e\n", energy, exact);
}

void test_shell_rigid_body_modes() {
  // Six rigid-body modes in 3D -- but this element is FLAT and returns LOCAL axes,
  // so in-plane translation (2), out-of-plane translation (1), the two tilts and the
  // drilling rotation must all be force-free. The drilling term is written zero-sum
  // precisely so a UNIFORM drill stays rigid; if it were a plain diagonal it would
  // not, and the element would resist a rotation it should not feel.
  const double x[3] = {0.0, 1.7, 0.3}, y[3] = {0.0, 0.2, 1.1};
  const topopt::ShellStiffness K = topopt::shell3_stiffness(x, y, kE, kNu, 0.1);
  double scale = 0.0;
  for (int i = 0; i < 18; ++i) scale = std::max(scale, std::fabs(K(i, i)));
  auto residual = [&](const double u[18]) {
    double w = 0.0;
    for (int i = 0; i < 18; ++i) {
      double f = 0.0;
      for (int j = 0; j < 18; ++j) f += K(i, j) * u[j];
      w = std::max(w, std::fabs(f));
    }
    return w;
  };
  const char* names[6] = {"translate u", "translate v", "translate w",
                          "tilt about y", "tilt about x", "DRILL (theta_z)"};
  for (int mode = 0; mode < 6; ++mode) {
    double u[18] = {};
    for (int n = 0; n < 3; ++n) {
      if (mode == 0) u[6 * n + 0] = 1.0;
      else if (mode == 1) u[6 * n + 1] = 1.0;
      else if (mode == 2) u[6 * n + 2] = 1.0;
      else if (mode == 3) { u[6 * n + 2] = x[n]; u[6 * n + 4] = -1.0; }
      else if (mode == 4) { u[6 * n + 2] = y[n]; u[6 * n + 3] = 1.0; }
      else u[6 * n + 5] = 1.0;
    }
    const double r = residual(u);
    CHECK(r < 1e-6 * scale, names[mode]);
    if (!(r < 1e-6 * scale))
      std::fprintf(stderr, "   mode '%s' residual %.3e (scale %.3e)\n", names[mode], r, scale);
  }
}

void test_drilling_does_not_change_the_physics() {
  // ★ THE DRILLING TERM IS A CRUTCH, NOT PHYSICS. Sweeping it over three orders of
  // magnitude must not move a real bending answer. If it did, the "small fictitious
  // stiffness" would be quietly stiffening the shell.
  const double x[3] = {0.0, 1.0, 0.0}, y[3] = {0.0, 0.0, 1.0};
  double energies[3];
  int at = 0;
  for (double f : {1e-4, 1e-3, 1e-2}) {
    const topopt::ShellStiffness K = topopt::shell3_stiffness(x, y, kE, kNu, 0.1, f);
    double u[18] = {};
    for (int n = 0; n < 3; ++n) {           // constant curvature about x
      u[6 * n + 2] = 0.5 * x[n] * x[n];
      u[6 * n + 4] = -x[n];
    }
    double e = 0.0;
    for (int i = 0; i < 18; ++i)
      for (int j = 0; j < 18; ++j) e += 0.5 * u[i] * K(i, j) * u[j];
    energies[at++] = e;
  }
  CHECK(std::fabs(energies[2] / energies[0] - 1.0) < 1e-12,
        "a 100x change in the drilling factor leaves bending energy identical");
  if (!(std::fabs(energies[2] / energies[0] - 1.0) < 1e-12))
    std::fprintf(stderr, "   energies %.9e %.9e %.9e\n", energies[0], energies[1], energies[2]);

  // and with drilling ON the theta_z block must not be singular
  const topopt::ShellStiffness K = topopt::shell3_stiffness(x, y, kE, kNu, 0.1);
  CHECK(K(5, 5) > 0.0 && K(11, 11) > 0.0 && K(17, 17) > 0.0,
        "drilling dof carry stiffness, so coplanar assembly is not singular");
}

// Rank by elimination, so the nullity can be asserted rather than inferred from a
// handful of named modes.
int matrix_rank(std::vector<double> M, int n, double tol) {
  int rank = 0;
  std::vector<char> used(static_cast<std::size_t>(n), 0);
  for (int c = 0; c < n; ++c) {
    int piv = -1; double best = tol;
    for (int r = 0; r < n; ++r) {
      if (used[static_cast<std::size_t>(r)]) continue;
      const double v = std::fabs(M[static_cast<std::size_t>(r) * n + c]);
      if (v > best) { best = v; piv = r; }
    }
    if (piv < 0) continue;
    used[static_cast<std::size_t>(piv)] = 1; ++rank;
    for (int r = 0; r < n; ++r) {
      if (r == piv) continue;
      const double m = M[static_cast<std::size_t>(r) * n + c] /
                       M[static_cast<std::size_t>(piv) * n + c];
      if (m == 0.0) continue;
      for (int j = 0; j < n; ++j)
        M[static_cast<std::size_t>(r) * n + j] -= m * M[static_cast<std::size_t>(piv) * n + j];
    }
  }
  return rank;
}

void test_shell_nullity_is_exactly_six() {
  // ★ THE CHECK THAT CAUGHT A REAL DEFECT, and the reason named-mode tests are not
  // enough. The membrane already represents in-plane rotation through u and v;
  // theta_z represents the SAME rotation. A drilling term that only couples the
  // theta_z values to each other leaves the DIFFERENCE between the two
  // representations free -- nullity 7, while six named rigid modes still came back
  // force-free. Only the rank test saw it. The fix is a field penalty on
  // (theta_z - omega) with omega the membrane's own rotation (Hughes-Brezzi); a
  // rank-1 form on the AVERAGE theta_z is not enough either (nullity 8).
  const double x[3] = {0.0, 3.0, 0.0}, y[3] = {0.0, 0.0, 3.0};
  const topopt::ShellStiffness K = topopt::shell3_stiffness(x, y, kE, kNu, 1.0);
  std::vector<double> M(18 * 18);
  double scale = 0.0;
  for (int i = 0; i < 18; ++i)
    for (int j = 0; j < 18; ++j) {
      M[static_cast<std::size_t>(i) * 18 + j] = K(i, j);
      if (i == j) scale = std::max(scale, std::fabs(K(i, j)));
    }
  const int rank = matrix_rank(M, 18, 1e-9 * scale);
  CHECK(rank == 12, "the shell has EXACTLY 6 rigid-body modes (rank 12 of 18)");
  if (rank != 12)
    std::fprintf(stderr, "   rank %d of 18 -> nullity %d (expected 6)\n", rank, 18 - rank);
}

void test_refusals() {
  const double x[3] = {0, 1, 0}, y[3] = {0, 0, 1};
  bool threw = false;
  try { topopt::dkt_stiffness(x, y, 0.0, kNu, 0.1); }
  catch (const std::invalid_argument&) { threw = true; }
  CHECK(threw, "refuses a non-positive modulus");
  threw = false;
  try { topopt::dkt_stiffness(x, y, kE, kNu, 0.0); }
  catch (const std::invalid_argument&) { threw = true; }
  CHECK(threw, "refuses a zero thickness");
  const double flat_x[3] = {0, 1, 2}, flat_y[3] = {0, 0, 0};
  threw = false;
  try { topopt::dkt_stiffness(flat_x, flat_y, kE, kNu, 0.1); }
  catch (const std::invalid_argument&) { threw = true; }
  CHECK(threw, "refuses a degenerate (zero-area) triangle");
}

}  // namespace

int main() {
  test_symmetry_and_rigid_body_modes();
  test_constant_curvature_patch();
  test_shell_nullity_is_exactly_six();
  test_shell_membrane_is_exact();
  test_shell_rigid_body_modes();
  test_drilling_does_not_change_the_physics();
  test_refusals();
  std::printf("test_dkt_plate: %d checks, %d failures\n", g_checks, g_failures);
  return g_failures == 0 ? 0 : 1;
}
