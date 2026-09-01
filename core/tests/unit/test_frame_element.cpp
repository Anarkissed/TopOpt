// The 2-node spatial frame element (organic-lattice beam FEA).
//
// Every claim frame2_stiffness makes in fea.hpp is a check here that can fail.
// The two that matter most, because both were REAL BUGS caught by exactly these
// controls during development:
//
//   * STRESS, not just displacement. A first implementation recovered the bending
//     moment from end ROTATIONS alone, dropping the transverse-displacement terms.
//     Tip deflection came out EXACT while the root stress was 150x high. A smoke
//     test on displacement alone would have passed it.
//   * TIMOSHENKO vs EULER-BERNOULLI. Dropping shear overstates stubby-member
//     stiffness. On the M2 lattice that was a 2.5x error in PEAK STRESS at both
//     3 mm and 6 mm cells, because the worst-loaded strut is always a short one.
//
// No third-party framework (ARCHITECTURE §4): the self-contained CHECK harness.
// Public API only (topopt/fea.hpp).

#include "topopt/fea.hpp"

#include <algorithm>

#include <array>
#include <cmath>
#include <cstdio>
#include <stdexcept>
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

constexpr double kE = 2300.0;    // MPa
constexpr double kNu = 0.35;
constexpr double kShearK = 0.9;  // circular section
double shear_modulus() { return kE / (2.0 * (1.0 + kNu)); }

// Solve K u = f on the FREE dof of a single element clamped at node 0, by dense
// Gaussian elimination. 6 free dof (node 1) — small enough to be exact and
// dependency-free.
std::array<double, 6> solve_free_node(const topopt::FrameStiffness& K,
                                      const std::array<double, 6>& f) {
  double A[6][7];
  for (int i = 0; i < 6; ++i) {
    for (int j = 0; j < 6; ++j) A[i][j] = K(6 + i, 6 + j);
    A[i][6] = f[i];
  }
  for (int c = 0; c < 6; ++c) {
    int piv = c;
    for (int r = c + 1; r < 6; ++r)
      if (std::fabs(A[r][c]) > std::fabs(A[piv][c])) piv = r;
    for (int j = 0; j <= 6; ++j) std::swap(A[c][j], A[piv][j]);
    for (int r = 0; r < 6; ++r) {
      if (r == c) continue;
      const double m = A[r][c] / A[c][c];
      for (int j = c; j <= 6; ++j) A[r][j] -= m * A[c][j];
    }
  }
  std::array<double, 6> u{};
  for (int i = 0; i < 6; ++i) u[i] = A[i][6] / A[i][i];
  return u;
}

void test_symmetry_and_rigid_body() {
  const double r = 1.0, L = 10.0;
  const double A = M_PI * r * r, I = M_PI * r * r * r * r / 4.0;
  const topopt::FrameStiffness K = topopt::frame2_stiffness(
      kE, shear_modulus(), A, I, I, 2.0 * I, L, kShearK);

  double worst_asym = 0.0;
  for (int i = 0; i < 12; ++i)
    for (int j = 0; j < 12; ++j)
      worst_asym = std::max(worst_asym, std::fabs(K(i, j) - K(j, i)));
  CHECK(worst_asym < 1e-9, "frame element stiffness is symmetric");

  // A RIGID TRANSLATION must produce no force: each translational column-triple
  // sums to zero across the two nodes.
  for (int c = 0; c < 3; ++c) {
    double s = 0.0;
    for (int i = 0; i < 12; ++i) s += K(i, c) + K(i, 6 + c);
    CHECK(std::fabs(s) < 1e-9 * std::fabs(K(c, c)),
          "rigid translation produces no nodal force");
  }
  // Diagonal is positive definite-ish: every dof must have stiffness.
  for (int i = 0; i < 12; ++i) CHECK(K(i, i) > 0.0, "every dof carries stiffness");
}

void test_cantilever_against_closed_form() {
  // Tip-loaded cantilever: delta = P L^3/(3 E I) + P L/(k G A), root moment = P L.
  const double r = 1.0, L = 50.0, P = 10.0;
  const double A = M_PI * r * r, I = M_PI * r * r * r * r / 4.0;
  const double G = shear_modulus();

  // Euler-Bernoulli first (shear_k <= 0), so the bending term is checked alone.
  const topopt::FrameStiffness Keb =
      topopt::frame2_stiffness(kE, G, A, I, I, 2.0 * I, L, -1.0);
  std::array<double, 6> f{};
  f[2] = -P;  // load along local z at the free node
  const std::array<double, 6> ueb = solve_free_node(Keb, f);
  const double d_bend = P * L * L * L / (3.0 * kE * I);
  CHECK(std::fabs(std::fabs(ueb[2]) - d_bend) < 1e-9 * d_bend,
        "Euler-Bernoulli tip deflection equals P L^3/(3 E I)");

  // Timoshenko adds exactly the shear term.
  const topopt::FrameStiffness Kt =
      topopt::frame2_stiffness(kE, G, A, I, I, 2.0 * I, L, kShearK);
  const std::array<double, 6> ut = solve_free_node(Kt, f);
  const double d_shear = P * L / (kShearK * G * A);
  CHECK(std::fabs(std::fabs(ut[2]) - (d_bend + d_shear)) < 1e-9 * (d_bend + d_shear),
        "Timoshenko tip deflection equals bending + P L/(k G A)");
  CHECK(std::fabs(ut[2]) > std::fabs(ueb[2]),
        "shear flexibility makes the element SOFTER, never stiffer");

  // ★ THE STRESS CONTROL. Recover end forces as f_local = K u_local and read the
  // ROOT bending moment. This is the check that caught a 150x stress error behind
  // an exact displacement.
  std::array<double, 12> u12{};
  for (int i = 0; i < 6; ++i) u12[6 + i] = ueb[i];
  double m_root = 0.0;
  for (int j = 0; j < 12; ++j) m_root += Keb(4, j) * u12[j];  // ry at node 0
  CHECK(std::fabs(std::fabs(m_root) - P * L) < 1e-9 * P * L,
        "root bending moment equals P L (end forces, not end rotations)");
}

void test_peak_stress_from_end_forces() {
  // ★ THE 150x BUG, ASSERTED. Cantilever: root stress must be M r / I = P L r / I.
  const double r = 1.0, L = 50.0, P = 10.0;
  const double A = M_PI * r * r, I = M_PI * r * r * r * r / 4.0;
  const double G = shear_modulus();
  const topopt::FrameStiffness K =
      topopt::frame2_stiffness(kE, G, A, I, I, 2.0 * I, L, -1.0);
  std::array<double, 6> f{};
  f[2] = -P;
  const std::array<double, 6> u = solve_free_node(K, f);
  std::array<double, 12> u12{};
  for (int i = 0; i < 6; ++i) u12[static_cast<std::size_t>(6 + i)] = u[static_cast<std::size_t>(i)];
  const double got = topopt::frame_member_peak_stress(K, u12, r);
  const double want = P * L * r / I;
  CHECK(std::fabs(got - want) < 1e-9 * want,
        "peak stress equals the closed-form root bending stress P L r / I");

  // Pure tension: sigma = P/A, no bending term.
  std::array<double, 6> ft{};
  ft[0] = P;
  const std::array<double, 6> ut = solve_free_node(K, ft);
  std::array<double, 12> ut12{};
  for (int i = 0; i < 6; ++i) ut12[static_cast<std::size_t>(6 + i)] = ut[static_cast<std::size_t>(i)];
  CHECK(std::fabs(topopt::frame_member_peak_stress(K, ut12, r) - P / A) < 1e-9 * P / A,
        "pure tension gives exactly P/A");

  // A rigid translation is stress-free.
  std::array<double, 12> rigid{};
  for (int n = 0; n < 2; ++n) rigid[static_cast<std::size_t>(6 * n + 1)] = 0.7;
  CHECK(topopt::frame_member_peak_stress(K, rigid, r) < 1e-9,
        "a rigid translation produces no stress");

  bool threw = false;
  try { topopt::frame_member_peak_stress(K, u12, 0.0); }
  catch (const std::invalid_argument&) { threw = true; }
  CHECK(threw, "refuses a zero radius");
}

void test_axial_and_torsion() {
  const double r = 1.0, L = 20.0, P = 7.0, T = 3.0;
  const double A = M_PI * r * r, I = M_PI * r * r * r * r / 4.0, J = 2.0 * I;
  const double G = shear_modulus();
  const topopt::FrameStiffness K =
      topopt::frame2_stiffness(kE, G, A, I, I, J, L, kShearK);
  std::array<double, 6> f{};
  f[0] = P;
  CHECK(std::fabs(solve_free_node(K, f)[0] - P * L / (A * kE)) < 1e-9 * P * L / (A * kE),
        "axial extension equals P L /(A E)");
  std::array<double, 6> t{};
  t[3] = T;
  CHECK(std::fabs(solve_free_node(K, t)[3] - T * L / (G * J)) < 1e-9 * T * L / (G * J),
        "twist equals T L /(G J)");
}

void test_subdivision_is_discretisation_independent() {
  // The tracer emits ~0.85 mm segments whatever the cell size, so struts arrive
  // pre-subdivided into stubby pieces. Shear flexibility is additive along the
  // length, so N short Timoshenko elements must give the SAME answer as one long
  // one. If per-element phi were applied wrongly this would drift with N.
  const double r = 1.0, L = 5.0, P = 10.0;
  const double A = M_PI * r * r, I = M_PI * r * r * r * r / 4.0;
  const double G = shear_modulus();
  const double exact = P * L * L * L / (3.0 * kE * I) + P * L / (kShearK * G * A);

  for (int n : {1, 4, 20}) {
    const double le = L / n;
    // assemble the chain: 6*(n+1) dof, clamp node 0, load the tip along z
    const int nd = 6 * (n + 1);
    std::vector<double> Kg(static_cast<std::size_t>(nd) * nd, 0.0);
    const topopt::FrameStiffness ke =
        topopt::frame2_stiffness(kE, G, A, I, I, 2.0 * I, le, kShearK);
    for (int e = 0; e < n; ++e)
      for (int a = 0; a < 12; ++a)
        for (int b = 0; b < 12; ++b)
          Kg[static_cast<std::size_t>(6 * e + a) * nd + (6 * e + b)] += ke(a, b);
    // eliminate the clamped node
    const int nf = nd - 6;
    std::vector<double> M(static_cast<std::size_t>(nf) * (nf + 1), 0.0);
    for (int i = 0; i < nf; ++i)
      for (int j = 0; j < nf; ++j)
        M[static_cast<std::size_t>(i) * (nf + 1) + j] =
            Kg[static_cast<std::size_t>(6 + i) * nd + (6 + j)];
    M[static_cast<std::size_t>(nf - 6 + 2) * (nf + 1) + nf] = -P;
    for (int c = 0; c < nf; ++c) {
      int piv = c;
      for (int rr = c + 1; rr < nf; ++rr)
        if (std::fabs(M[static_cast<std::size_t>(rr) * (nf + 1) + c]) >
            std::fabs(M[static_cast<std::size_t>(piv) * (nf + 1) + c]))
          piv = rr;
      for (int j = 0; j <= nf; ++j)
        std::swap(M[static_cast<std::size_t>(c) * (nf + 1) + j],
                  M[static_cast<std::size_t>(piv) * (nf + 1) + j]);
      for (int rr = 0; rr < nf; ++rr) {
        if (rr == c) continue;
        const double m = M[static_cast<std::size_t>(rr) * (nf + 1) + c] /
                         M[static_cast<std::size_t>(c) * (nf + 1) + c];
        for (int j = c; j <= nf; ++j)
          M[static_cast<std::size_t>(rr) * (nf + 1) + j] -=
              m * M[static_cast<std::size_t>(c) * (nf + 1) + j];
      }
    }
    const double tip = M[static_cast<std::size_t>(nf - 6 + 2) * (nf + 1) + nf] /
                       M[static_cast<std::size_t>(nf - 6 + 2) * (nf + 1) + (nf - 6 + 2)];
    CHECK(std::fabs(std::fabs(tip) - exact) < 1e-6 * exact,
          "subdivision into stubby elements reproduces the closed form");
  }
}

void test_shear_bending_ratio_criterion() {
  // chi = 2.25 (r/L)^2 at nu = 0.35, k = 0.9  ->  chi = 0.5 at L/r = 2.12.
  const double chi_unit = topopt::frame_shear_bending_ratio(kE, kNu, 1.0, 1.0, kShearK);
  CHECK(std::fabs(chi_unit - 2.25) < 1e-9, "chi(r=L) is 2.25 at nu=0.35, k=0.9");
  const double L_thresh = 1.0 * std::sqrt(2.25 / 0.5);
  CHECK(std::fabs(L_thresh - 2.1213203) < 1e-6, "chi = 0.5 at L/r = 2.121");
  CHECK(topopt::frame_shear_bending_ratio(kE, kNu, 0.5, 0.83, kShearK) > 0.5,
        "the MEASURED worst M2 strut (0.83 mm, r 0.5) needs shear correction");
  CHECK(topopt::frame_shear_bending_ratio(kE, kNu, 0.5, 2.56, kShearK) < 0.5,
        "the MEDIAN M2 strut (2.56 mm) does not — judge on the WORST, not the median");
  // chi falls as the strut lengthens
  CHECK(topopt::frame_shear_bending_ratio(kE, kNu, 0.5, 10.0, kShearK) <
            topopt::frame_shear_bending_ratio(kE, kNu, 0.5, 5.0, kShearK),
        "chi decreases monotonically with strut length");
}

void test_refusals() {
  const double A = 1.0, I = 1.0, G = shear_modulus();
  bool threw = false;
  try { topopt::frame2_stiffness(0.0, G, A, I, I, 2 * I, 1.0, kShearK); }
  catch (const std::invalid_argument&) { threw = true; }
  CHECK(threw, "refuses a non-positive Young's modulus");
  threw = false;
  try { topopt::frame2_stiffness(kE, G, A, I, I, 2 * I, 0.0, kShearK); }
  catch (const std::invalid_argument&) { threw = true; }
  CHECK(threw, "refuses a zero length");
  threw = false;
  try { topopt::frame2_stiffness(kE, G, 0.0, I, I, 2 * I, 1.0, kShearK); }
  catch (const std::invalid_argument&) { threw = true; }
  CHECK(threw, "refuses a zero area");
}

// ── THE TIE ─────────────────────────────────────────────────────────────────

void test_tie_weights() {
  const topopt::Vec3 org{1.0, 2.0, 3.0};
  const double h = 2.0;
  // partition of unity, everywhere -- inside, on a face, and outside
  for (const topopt::Vec3& p : {topopt::Vec3{1.0, 2.0, 3.0},
                                topopt::Vec3{2.0, 3.0, 4.0},
                                topopt::Vec3{3.0, 4.0, 5.0},
                                topopt::Vec3{0.0, 9.9, -4.0}}) {
    const topopt::FrameSolidTie t = topopt::frame_solid_tie(p, org, h);
    double sum = 0.0;
    for (double w : t.weight) sum += w;
    CHECK(std::fabs(sum - 1.0) < 1e-12, "tie weights are a partition of unity");
  }
  // the origin corner is 1-hot on corner 0
  const topopt::FrameSolidTie c0 = topopt::frame_solid_tie(org, org, h);
  CHECK(std::fabs(c0.weight[0] - 1.0) < 1e-12 && c0.inside,
        "a point AT the origin corner ties entirely to that corner");
  // the far corner is 1-hot on corner 7
  const topopt::FrameSolidTie c7 =
      topopt::frame_solid_tie(topopt::Vec3{org.x + h, org.y + h, org.z + h}, org, h);
  CHECK(std::fabs(c7.weight[7] - 1.0) < 1e-12, "the far corner ties to corner 7");
  // the centre is even
  const topopt::FrameSolidTie cc = topopt::frame_solid_tie(
      topopt::Vec3{org.x + h / 2, org.y + h / 2, org.z + h / 2}, org, h);
  for (double w : cc.weight)
    CHECK(std::fabs(w - 0.125) < 1e-12, "the centre ties evenly to all eight corners");
  // OUTSIDE must be reported, not silently extrapolated
  CHECK(!topopt::frame_solid_tie(topopt::Vec3{org.x - 0.1, org.y, org.z}, org, h).inside,
        "a point outside the element reports inside == false");
  bool threw = false;
  try { topopt::frame_solid_tie(org, org, 0.0); }
  catch (const std::invalid_argument&) { threw = true; }
  CHECK(threw, "refuses a zero element size");
}

void test_tie_reproduces_a_linear_field() {
  // A tie is only legitimate if it reproduces a LINEAR displacement field exactly:
  // that is what makes it a constraint rather than an interpolation guess.
  const topopt::Vec3 org{0.0, 0.0, 0.0};
  const double h = 1.7;
  auto field = [](const topopt::Vec3& q) {
    return 0.3 + 1.1 * q.x - 0.7 * q.y + 2.4 * q.z;   // arbitrary affine
  };
  const topopt::Vec3 p{0.31 * h, 0.62 * h, 0.19 * h};
  const topopt::FrameSolidTie t = topopt::frame_solid_tie(p, org, h);
  double interp = 0.0;
  int n = 0;
  for (int kz = 0; kz < 2; ++kz)
    for (int jy = 0; jy < 2; ++jy)
      for (int ix = 0; ix < 2; ++ix)
        interp += t.weight[static_cast<std::size_t>(n++)] *
                  field(topopt::Vec3{org.x + ix * h, org.y + jy * h, org.z + kz * h});
  CHECK(std::fabs(interp - field(p)) < 1e-12,
        "the tie reproduces a linear field exactly");
}

// Rank of a dense symmetric matrix by elimination with partial pivoting.
int matrix_rank(std::vector<double> M, int n, double tol) {
  int rank = 0;
  std::vector<char> used(static_cast<std::size_t>(n), 0);
  for (int c = 0; c < n; ++c) {
    int piv = -1;
    double best = tol;
    for (int r = 0; r < n; ++r) {
      if (used[static_cast<std::size_t>(r)]) continue;
      const double v = std::fabs(M[static_cast<std::size_t>(r) * n + c]);
      if (v > best) { best = v; piv = r; }
    }
    if (piv < 0) continue;
    used[static_cast<std::size_t>(piv)] = 1;
    ++rank;
    for (int r = 0; r < n; ++r) {
      if (r == piv) continue;
      const double m = M[static_cast<std::size_t>(r) * n + c] /
                       M[static_cast<std::size_t>(piv) * n + c];
      if (m == 0.0) continue;
      for (int j = 0; j < n; ++j)
        M[static_cast<std::size_t>(r) * n + j] -=
            m * M[static_cast<std::size_t>(piv) * n + j];
    }
  }
  return rank;
}

// Assemble one hex + one beam, tying `ties` of the beam's two nodes into the hex,
// and return the nullity of the free-floating system.
int tied_assembly_nullity(int ties, bool lock_axial_spin = false) {
  // ★ THE CHECK THAT WAS MISSING. A prototype of this coupling produced an EXACTLY
  // SINGULAR system on a real part, and without a rank test the cause took five
  // wrong guesses to chase. One hex + one beam tied into it is a free-floating body:
  // its nullity must be EXACTLY 6 (three translations, three rotations). More means
  // a spurious mechanism -- which is what an unconstrained beam ROTATION at a pinned
  // tie would produce if the beam's own stiffness did not restrain it.
  const double h = 1.7, E = 2300.0, nu = 0.35;
  const double G = E / (2.0 * (1.0 + nu));
  const double r = 0.5, L = 0.6;
  const double A = M_PI * r * r, I = M_PI * r * r * r * r / 4.0;

  const topopt::Hex8Stiffness Kh = topopt::hex8_stiffness(E, nu, h);
  const topopt::FrameStiffness Kb =
      topopt::frame2_stiffness(E, G, A, I, I, 2.0 * I, L, 0.9);

  // dof: [24 hex] [12 beam]; beam node 0 is tied INSIDE the hex, node 1 sticks out.
  const int N = 36;
  std::vector<double> K(static_cast<std::size_t>(N) * N, 0.0);
  for (int i = 0; i < 24; ++i)
    for (int j = 0; j < 24; ++j)
      K[static_cast<std::size_t>(i) * N + j] += Kh(i, j);
  for (int i = 0; i < 12; ++i)
    for (int j = 0; j < 12; ++j)
      K[static_cast<std::size_t>(24 + i) * N + (24 + j)] += Kb(i, j);

  // Slave the translations of the first `ties` beam nodes to the hex.
  const topopt::Vec3 org{0.0, 0.0, 0.0};
  const topopt::Vec3 pos[2] = {topopt::Vec3{0.3 * h, 0.5 * h, 0.5 * h},
                               topopt::Vec3{0.3 * h + L, 0.5 * h, 0.5 * h}};
  topopt::FrameSolidTie tie[2];
  for (int t = 0; t < 2; ++t) tie[t] = topopt::frame_solid_tie(pos[t], org, h);
  const int M = 36 - 3 * ties;
  std::vector<double> T(static_cast<std::size_t>(N) * M, 0.0);
  for (int i = 0; i < 24; ++i) T[static_cast<std::size_t>(i) * M + i] = 1.0;
  int col = 24;
  for (int nB = 0; nB < 2; ++nB) {
    if (nB < ties) {
      for (int c = 0; c < 3; ++c)
        for (int a = 0; a < 8; ++a)
          T[static_cast<std::size_t>(24 + 6 * nB + c) * M + (3 * a + c)] +=
              tie[nB].weight[static_cast<std::size_t>(a)];
    } else {
      for (int c = 0; c < 3; ++c)
        T[static_cast<std::size_t>(24 + 6 * nB + c) * M + col++] = 1.0;
    }
    for (int c = 3; c < 6; ++c)
      T[static_cast<std::size_t>(24 + 6 * nB + c) * M + col++] = 1.0;
  }

  std::vector<double> KT(static_cast<std::size_t>(N) * M, 0.0);
  for (int i = 0; i < N; ++i)
    for (int k = 0; k < N; ++k) {
      const double v = K[static_cast<std::size_t>(i) * N + k];
      if (v == 0.0) continue;
      for (int j = 0; j < M; ++j)
        KT[static_cast<std::size_t>(i) * M + j] += v * T[static_cast<std::size_t>(k) * M + j];
    }
  std::vector<double> Kr(static_cast<std::size_t>(M) * M, 0.0);
  for (int i = 0; i < M; ++i)
    for (int k = 0; k < N; ++k) {
      const double v = T[static_cast<std::size_t>(k) * M + i];
      if (v == 0.0) continue;
      for (int j = 0; j < M; ++j)
        Kr[static_cast<std::size_t>(i) * M + j] += v * KT[static_cast<std::size_t>(k) * M + j];
    }

  double scale = 0.0;
  for (int i = 0; i < M; ++i)
    scale = std::max(scale, std::fabs(Kr[static_cast<std::size_t>(i) * M + i]));
  if (lock_axial_spin) {
    // Pin the first beam node's rotation about the element axis (local x = global x
    // here, since the beam runs along x). If the residual mode really is the axial
    // spin, removing this one dof must take the nullity to exactly 6.
    int axial = -1, col2 = 24;
    for (int nB = 0; nB < 2; ++nB) {
      if (nB >= ties) col2 += 3;
      if (nB == 0) axial = col2;      // local rx of beam node 0
      col2 += 3;
    }
    for (int j = 0; j < M; ++j) {
      Kr[static_cast<std::size_t>(axial) * M + j] = 0.0;
      Kr[static_cast<std::size_t>(j) * M + axial] = 0.0;
    }
    Kr[static_cast<std::size_t>(axial) * M + axial] = scale;
  }
  return M - matrix_rank(Kr, M, 1e-9 * scale);
}

void test_pinned_tie_mechanism() {
  // ★ THE PROPERTY THAT MATTERS, AND THE ONE A PROTOTYPE GOT WRONG. A pinned tie
  // transmits force but NOT moment, so a strut held at a SINGLE point can rotate
  // about it at zero energy: three spurious modes on top of the six rigid-body ones.
  // A prototype of this coupling produced an exactly singular system on a real part
  // and the cause took five wrong guesses to find, because nothing asserted this.
  const int one = tied_assembly_nullity(1);
  CHECK(one == 9,
        "ONE pinned tie leaves 9 modes: 6 rigid-body + 3 free spins about the tie");
  if (one != 9) std::fprintf(stderr, "  single-tie nullity %d (expected 9)\n", one);

  // Held at TWO points the spin is removed and only the rigid-body modes remain.
  // TWO ties remove the two transverse spins but NOT the third: a bar pinned at two
  // points can still rotate about the LINE JOINING THEM, and no translation-only tie
  // can resist that. 6 rigid-body + 1 axial spin.
  const int two = tied_assembly_nullity(2);
  CHECK(two == 7,
        "TWO pinned ties still leave an AXIAL SPIN about the line joining them");
  if (two != 7) std::fprintf(stderr, "  two-tie nullity %d (expected 7)\n", two);

  // Prove the residual mode IS the axial spin: lock that one rotation and the
  // nullity must fall to exactly the six rigid-body modes.
  const int locked = tied_assembly_nullity(2, /*lock_axial_spin=*/true);
  CHECK(locked == 6,
        "locking the axial rotation leaves EXACTLY 6 rigid-body modes");
  if (locked != 6) std::fprintf(stderr, "  locked nullity %d (expected 6)\n", locked);

  CHECK(one > two && two > locked, "each added restraint removes a mechanism");

  // CONSEQUENCE FOR CALLERS. With a pinned tie a lattice member needs, in order:
  // two tie points to stop it swinging, and a NON-COLLINEAR connection (in a real
  // network, the other struts meeting at its nodes) to stop it spinning about its
  // own axis. An isolated strut, or a chain of collinear struts tied only at its
  // ends, is a mechanism however well the rest of the model is built. Detect this
  // before solving rather than discovering it as a failed factorisation.
}

// ── ★ PHASE 4: THE BEAM-TO-SHELL TIE ────────────────────────────────────────
// The whole reason for the shell. A hex node has 3 translations and NO rotations, so
// a beam tied into solid can only be PINNED: it transmits force, not moment, and the
// tests above measure what that costs -- nullity 9 for one tie, 7 for two collinear
// ones. A SHELL node has rotations, so the joint can be properly BUILT IN, and the
// mechanism disappears.
int shell_tied_beam_nullity(int ties, bool weld_rotations) {
  const double E = 2300.0, nu = 0.35, G = E / (2.0 * (1.0 + nu));
  const double r = 0.5, L = 0.6, t = 1.0;
  const double A = M_PI * r * r, I = M_PI * r * r * r * r / 4.0;
  const double sx[3] = {0.0, 3.0, 0.0}, sy[3] = {0.0, 0.0, 3.0};

  const topopt::ShellStiffness Ks = topopt::shell3_stiffness(sx, sy, E, nu, t);
  const topopt::FrameStiffness Kb =
      topopt::frame2_stiffness(E, G, A, I, I, 2.0 * I, L, 0.9);

  // dof: [18 shell][12 beam]; the beam runs in the shell's plane from (0.5,0.5)
  const int N = 30;
  std::vector<double> K(static_cast<std::size_t>(N) * N, 0.0);
  for (int i = 0; i < 18; ++i)
    for (int j = 0; j < 18; ++j) K[static_cast<std::size_t>(i) * N + j] += Ks(i, j);
  for (int i = 0; i < 12; ++i)
    for (int j = 0; j < 12; ++j)
      K[static_cast<std::size_t>(18 + i) * N + (18 + j)] += Kb(i, j);

  // Tie the first `ties` beam nodes to shell node 0. With weld_rotations the beam's
  // ROTATIONS are slaved to the shell's rotational dof too -- the moment path a hex
  // simply does not have.
  const int per = weld_rotations ? 6 : 3;
  const int M = 30 - per * ties;
  std::vector<double> T(static_cast<std::size_t>(N) * M, 0.0);
  for (int i = 0; i < 18; ++i) T[static_cast<std::size_t>(i) * M + i] = 1.0;
  int col = 18;
  for (int nB = 0; nB < 2; ++nB)
    for (int c2 = 0; c2 < 6; ++c2) {
      const int row = 18 + 6 * nB + c2;
      if (nB < ties && c2 < per)
        T[static_cast<std::size_t>(row) * M + c2] = 1.0;   // onto shell node 0
      else
        T[static_cast<std::size_t>(row) * M + col++] = 1.0;
    }
  std::vector<double> KT(static_cast<std::size_t>(N) * M, 0.0), Kr(static_cast<std::size_t>(M) * M, 0.0);
  for (int i = 0; i < N; ++i)
    for (int k = 0; k < N; ++k) {
      const double v = K[static_cast<std::size_t>(i) * N + k];
      if (v == 0.0) continue;
      for (int j = 0; j < M; ++j)
        KT[static_cast<std::size_t>(i) * M + j] += v * T[static_cast<std::size_t>(k) * M + j];
    }
  for (int i = 0; i < M; ++i)
    for (int k = 0; k < N; ++k) {
      const double v = T[static_cast<std::size_t>(k) * M + i];
      if (v == 0.0) continue;
      for (int j = 0; j < M; ++j)
        Kr[static_cast<std::size_t>(i) * M + j] += v * KT[static_cast<std::size_t>(k) * M + j];
    }
  double scale = 0.0;
  for (int i = 0; i < M; ++i)
    scale = std::max(scale, std::fabs(Kr[static_cast<std::size_t>(i) * M + i]));
  return M - matrix_rank(Kr, M, 1e-9 * scale);
}

void test_shell_tie_removes_the_spin() {
  // A PINNED tie into the shell reproduces the hex behaviour: the beam still spins.
  const int pinned = shell_tied_beam_nullity(1, /*weld_rotations=*/false);
  CHECK(pinned > 6, "a PINNED tie into a shell still leaves spin modes");

  // WELDING the rotations -- possible only because a shell node HAS them -- removes
  // them. Six rigid-body modes and nothing else, from a SINGLE tie point: the
  // "three non-collinear ties per component" rule a pinned tie forces simply does
  // not apply to a moment-transferring joint.
  const int welded = shell_tied_beam_nullity(1, /*weld_rotations=*/true);
  CHECK(welded == 6,
        "a MOMENT-TRANSFERRING tie leaves exactly 6 rigid-body modes from ONE point");
  if (welded != 6)
    std::fprintf(stderr, "   welded nullity %d (expected 6), pinned was %d\n", welded, pinned);
  CHECK(welded < pinned, "welding the rotations strictly removes mechanisms");
}

}  // namespace

int main() {
  test_symmetry_and_rigid_body();
  test_cantilever_against_closed_form();
  test_peak_stress_from_end_forces();
  test_axial_and_torsion();
  test_subdivision_is_discretisation_independent();
  test_shear_bending_ratio_criterion();
  test_refusals();
  test_tie_weights();
  test_tie_reproduces_a_linear_field();
  test_pinned_tie_mechanism();
  test_shell_tie_removes_the_spin();
  std::printf("test_frame_element: %d checks, %d failures\n", g_checks, g_failures);
  return g_failures == 0 ? 0 : 1;
}
