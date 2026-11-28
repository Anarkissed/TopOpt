// test_to_stage4_mma — stage 4a: the level-set optimiser's MMA step with m
// constraints at once (core/include/topopt/plsm_mma.hpp, plsm_mma_update_m).
//
// Checks (one line each, PASS / FAIL with the numbers):
//  (a)  SAME BYTES: plsm_mma_update_m with m = 1 against plsm_mma_update, n = 50
//       and 500, five iterations with the asymptote history carried; x and the
//       state compared bitwise. (m = 1 is DELEGATED to the old function: a Newton
//       dual cannot reproduce a bisection to the last bit.)
//  (a2) the m-dimensional dual solver itself (plsm_mma_update_general, no
//       delegation) at m = 1 agrees with the bisection to 1e-6 of the range.
//  (b1) Svanberg's five-variable cantilever (one constraint), optimum in < 30
//       iterations to 1e-3, through the general entry point (delegated) AND
//       through the general solver.
//  (b2) a two-constraint problem with both constraints active, < 60 iterations.
//  (b3) the same with constraint 2 made slack: lambda_2 = 0, one-constraint answer.
//  (c)  m = 3, one constraint infeasible at the start: the violation falls
//       monotonically over the first 10 iterations, no NaN.

#include <cmath>
#include <cstdio>
#include <cstring>
#include <functional>
#include <random>
#include <vector>

#include "topopt/plsm_mma.hpp"

using topopt::PlsmMmaMInfo;
using topopt::PlsmMmaState;
using Vec = std::vector<double>;

static int g_fail = 0;
static void report(const char* name, bool ok, const char* fmt, double a = 0,
                   double b = 0, double c = 0, double d = 0) {
  std::printf("%-5s %s  ", name, ok ? "PASS" : "FAIL");
  std::printf(fmt, a, b, c, d);
  std::printf("\n");
  if (!ok) ++g_fail;
}

static bool same_bytes(const Vec& a, const Vec& b) {
  return a.size() == b.size() &&
         (a.empty() || std::memcmp(a.data(), b.data(), a.size() * sizeof(double)) == 0);
}

// A problem: objective and its gradient, m constraints and their gradients.
struct Problem {
  std::function<double(const Vec&)> f;
  std::function<Vec(const Vec&)> df;
  std::vector<std::function<double(const Vec&)>> g;
  std::vector<std::function<Vec(const Vec&)>> dg;
};

// Run `iters` MMA iterations; returns the iterate history (x_0 .. x_iters).
static std::vector<Vec> run(const Problem& P, Vec x, double xmin, double xmax,
                            double move, int iters, bool general,
                            std::vector<PlsmMmaMInfo>* infos = nullptr) {
  PlsmMmaState st;
  std::vector<Vec> hist{x};
  for (int it = 1; it <= iters; ++it) {
    Vec gv;
    std::vector<Vec> dgv;
    for (std::size_t i = 0; i < P.g.size(); ++i) {
      gv.push_back(P.g[i](x));
      dgv.push_back(P.dg[i](x));
    }
    PlsmMmaMInfo info;
    x = general ? topopt::plsm_mma_update_general(st, it, x, P.df(x), dgv, gv,
                                                  xmin, xmax, move, &info)
                : topopt::plsm_mma_update_m(st, it, x, P.df(x), dgv, gv, xmin,
                                            xmax, move, &info);
    if (infos) infos->push_back(info);
    hist.push_back(x);
  }
  return hist;
}

static double max_rel(const Vec& x, const Vec& ref) {
  double r = 0.0;
  for (std::size_t k = 0; k < x.size(); ++k)
    r = std::max(r, std::fabs(x[k] - ref[k]) / std::fabs(ref[k]));
  return std::isfinite(r) ? r : 1e300;
}

// First iteration at which x is within `tol` relative of `ref` (and stays there
// to the end of the history); -1 if never.
static int first_within(const std::vector<Vec>& hist, const Vec& ref, double tol) {
  int first = -1;
  for (std::size_t k = 0; k < hist.size(); ++k) {
    if (max_rel(hist[k], ref) <= tol) {
      if (first < 0) first = static_cast<int>(k);
    } else {
      first = -1;
    }
  }
  return first;
}

// ── (a) the same bytes ─────────────────────────────────────────────────────
// A plsm-like problem: signed coefficients in [-2, 2], a compliance-like
// objective sum w exp(-x) (dc < 0, material helps) and a volume sum v x - V
// that starts slightly violated so the constraint is active.
static void check_a(std::size_t n, unsigned seed) {
  std::mt19937_64 rng(seed);
  std::uniform_real_distribution<double> U01(0.0, 1.0);
  Vec x0(n), w(n), v(n);
  for (std::size_t e = 0; e < n; ++e) {
    x0[e] = -1.0 + 2.0 * U01(rng);
    w[e] = 0.1 + U01(rng);
    v[e] = 0.2 + U01(rng);
  }
  double vsum = 0.0, vx = 0.0;
  for (std::size_t e = 0; e < n; ++e) { vsum += v[e]; vx += v[e] * x0[e]; }
  const double target = vx - 0.1 * vsum;
  auto dc = [&](const Vec& x) { Vec d(n); for (std::size_t e = 0; e < n; ++e) d[e] = -w[e] * std::exp(-x[e]); return d; };
  auto g0 = [&](const Vec& x) { double s = 0; for (std::size_t e = 0; e < n; ++e) s += v[e] * x[e]; return s - target; };

  PlsmMmaState s_old, s_new, s_gen;
  Vec xo = x0, xn = x0, xg = x0;
  bool same = true, delegated = true;
  double gen_diff = 0.0;
  const double xmin = -2.0, xmax = 2.0, move = 0.1;
  for (int it = 1; it <= 5; ++it) {
    xo = topopt::plsm_mma_update(s_old, it, xo, dc(xo), v, g0(xo), xmin, xmax, move);
    PlsmMmaMInfo info;
    xn = topopt::plsm_mma_update_m(s_new, it, xn, dc(xn), {v}, {g0(xn)}, xmin, xmax, move, &info);
    delegated = delegated && info.delegated;
    same = same && same_bytes(xo, xn) && same_bytes(s_old.low, s_new.low) &&
           same_bytes(s_old.upp, s_new.upp) && same_bytes(s_old.xold1, s_new.xold1) &&
           same_bytes(s_old.xold2, s_new.xold2);
    // The general solver on the SAME input as the old step (so the comparison
    // is of one step, not of drifting trajectories).
    PlsmMmaState sg = s_gen;
    Vec xgi = xg;
    PlsmMmaState so_copy = sg;
    Vec ref = topopt::plsm_mma_update(so_copy, it, xgi, dc(xgi), v, g0(xgi), xmin, xmax, move);
    Vec got = topopt::plsm_mma_update_general(sg, it, xgi, dc(xgi), {v}, {g0(xgi)}, xmin, xmax, move);
    for (std::size_t e = 0; e < n; ++e)
      gen_diff = std::max(gen_diff, std::fabs(ref[e] - got[e]) / (xmax - xmin));
    s_gen = so_copy;
    xg = ref;
  }
  char name[16];
  std::snprintf(name, sizeof name, "(a)");
  std::printf("      n = %zu, seed %u\n", n, seed);
  report(name, same && delegated,
         "m=1 general entry vs plsm_mma_update, 5 iterations: x and asymptotes bitwise equal = %g, delegated = %g",
         same ? 1.0 : 0.0, delegated ? 1.0 : 0.0);
  report("(a2)", gen_diff <= 1e-6,
         "m-dim Newton dual at m=1 vs bisection: max |dx| / range over 5 steps = %.3e (bar 1e-6)",
         gen_diff);
}

int main() {
  // ── (a) ──
  check_a(50, 11);
  check_a(50, 12);
  check_a(500, 13);
  check_a(500, 14);

  // ── (b1) Svanberg's cantilever ──
  // min 0.0624 sum x  s.t.  sum c_k / x_k^3 <= 1,  1 <= x <= 10, start x = 5.
  // KKT: 0.0624 = 3 lambda c_k / x_k^4  ->  x_k = c_k^(1/4) * S^(1/3),
  // S = sum c_k^(1/4) (the constraint active). Gives (6.016, 5.309, 4.494,
  // 3.502, 2.153), objective 1.340 as published.
  {
    const Vec c{61, 37, 19, 7, 1};
    double S = 0.0;
    for (double ck : c) S += std::pow(ck, 0.25);
    Vec xs(5);
    for (int k = 0; k < 5; ++k) xs[k] = std::pow(c[k], 0.25) * std::cbrt(S);
    const Vec published{6.016, 5.309, 4.494, 3.502, 2.153};
    Problem P;
    P.f = [](const Vec& x) { double s = 0; for (double v : x) s += v; return 0.0624 * s; };
    P.df = [](const Vec& x) { return Vec(x.size(), 0.0624); };
    P.g.push_back([c](const Vec& x) { double s = 0; for (int k = 0; k < 5; ++k) s += c[k] / (x[k] * x[k] * x[k]); return s - 1.0; });
    P.dg.push_back([c](const Vec& x) { Vec d(5); for (int k = 0; k < 5; ++k) d[k] = -3.0 * c[k] / std::pow(x[k], 4); return d; });
    for (int gen = 0; gen < 2; ++gen) {
      auto h = run(P, Vec(5, 5.0), 1.0, 10.0, 0.5, 40, gen == 1);
      const int k = first_within(h, xs, 1e-3);
      const Vec& xf = h.back();
      report("(b1)", k >= 0 && k < 30 && max_rel(xs, published) < 1e-3,
             gen ? "cantilever, general Newton dual: within 1e-3 at iteration %g; final max rel err %.2e; objective %.5f (published 1.340); x1 %.4f"
                 : "cantilever, m=1 entry (delegated): within 1e-3 at iteration %g; final max rel err %.2e; objective %.5f (published 1.340); x1 %.4f",
             k, max_rel(xf, xs), P.f(xf), xf[0]);
    }
  }

  // ── (b2) two constraints, both active ──
  // min x1 + x2 + x3  s.t.  g1 = sum a_k / x_k - 1 <= 0,  g2 = sum b_k / x_k - 1 <= 0,
  // a = (0.4, 0.8, 0.6), b = (0.05, 0.6, 1.95), 0.1 <= x <= 10, start x = 5.
  // Derivation: KKT stationarity 1 = (l1 a_k + l2 b_k) / x_k^2. Take the claim
  // x* = (1, 2, 3), l* = (2, 4): 2a + 4b = (0.8+0.2, 1.6+2.4, 1.2+7.8) = (1, 4, 9)
  // = x*^2  [OK]; g1(x*) = 0.4 + 0.4 + 0.2 - 1 = 0, g2(x*) = 0.05 + 0.3 + 0.65 - 1
  // = 0  [both active, multipliers > 0]. The problem is convex (1/x convex for
  // x > 0, linear objective), so KKT is sufficient: x* is THE optimum, f* = 6.
  // (Construction: chose x*, l1 + l2 = sum x* = 6, u_k = a_k/x_k with sum 1, then
  // v_k = (x_k - 2 u_k)/4 has sum 1 automatically.)
  const Vec a{0.4, 0.8, 0.6}, bb{0.05, 0.6, 1.95};
  auto make2 = [](const Vec& A, const Vec& B) {
    Problem P;
    P.f = [](const Vec& x) { return x[0] + x[1] + x[2]; };
    P.df = [](const Vec& x) { return Vec(x.size(), 1.0); };
    for (const Vec* co : {&A, &B}) {
      const Vec cc = *co;
      P.g.push_back([cc](const Vec& x) { double s = 0; for (int k = 0; k < 3; ++k) s += cc[k] / x[k]; return s - 1.0; });
      P.dg.push_back([cc](const Vec& x) { Vec d(3); for (int k = 0; k < 3; ++k) d[k] = -cc[k] / (x[k] * x[k]); return d; });
    }
    return P;
  };
  {
    Problem P = make2(a, bb);
    std::vector<PlsmMmaMInfo> inf;
    auto h = run(P, Vec(3, 5.0), 0.1, 10.0, 0.5, 80, false, &inf);
    const Vec xs{1.0, 2.0, 3.0};
    const int k = first_within(h, xs, 1e-3);
    const PlsmMmaMInfo& L = inf.back();
    report("(b2)", k >= 0 && k < 60,
           "two active constraints: within 1e-3 of (1,2,3) at iteration %g; final max rel err %.2e; multipliers (%.4f, %.4f), expected (2, 4)",
           k, max_rel(h.back(), xs), L.lambda[0] * L.obj_scale, L.lambda[1] * L.obj_scale);
  }

  // ── (b3) constraint 2 made slack ──
  // b' = b / 2. With g1 alone: x_k = sqrt(l a_k), and g1 = 0 gives sqrt(l) =
  // sum sqrt(a_j), so x_k = sqrt(a_k) * sum_j sqrt(a_j) = (1.4556, 2.0585, 1.7827).
  // There g2' = (1/2) sum b_k / x_k = 0.710 < 1: slack, so l2 must be 0.
  {
    Vec bh = bb;
    for (double& v : bh) v *= 0.5;
    Problem P = make2(a, bh);
    double Sa = 0.0;
    for (double ak : a) Sa += std::sqrt(ak);
    Vec xs(3);
    for (int k = 0; k < 3; ++k) xs[k] = std::sqrt(a[k]) * Sa;
    std::vector<PlsmMmaMInfo> inf;
    auto h = run(P, Vec(3, 5.0), 0.1, 10.0, 0.5, 80, false, &inf);
    const int k = first_within(h, xs, 1e-3);
    const PlsmMmaMInfo& L = inf.back();
    const double g2 = P.g[1](h.back());
    report("(b3)", k >= 0 && k < 60 && L.lambda[1] == 0.0 && g2 < 0.0,
           "slack constraint: within 1e-3 of one-constraint optimum at iteration %g; final err %.2e; lambda2 = %g; g2 = %.4f",
           k, max_rel(h.back(), xs), L.lambda[1], g2);
  }

  // ── (c) m = 3, one infeasible at the start ──
  // min sum x^2  s.t. the two constraints of (b2) and g3 = 1 - (x1+x2+x3)/12 <= 0;
  // start x = 3 (g1 = -0.4, g2 = -0.13 feasible; g3 = +0.25 infeasible), move 0.05
  // so feasibility takes several steps.
  {
    Problem P = make2(a, bb);
    P.f = [](const Vec& x) { double s = 0; for (double v : x) s += v * v; return s; };
    P.df = [](const Vec& x) { Vec d(x.size()); for (std::size_t k = 0; k < x.size(); ++k) d[k] = 2 * x[k]; return d; };
    P.g.push_back([](const Vec& x) { return 1.0 - (x[0] + x[1] + x[2]) / 12.0; });
    P.dg.push_back([](const Vec&) { return Vec(3, -1.0 / 12.0); });
    auto viol = [&](const Vec& x) { double s = 0; for (auto& gi : P.g) s += std::max(0.0, gi(x)); return s; };
    auto h = run(P, Vec(3, 3.0), 0.1, 10.0, 0.05, 40, false);
    // Monotone up to round-off: once the active g3 sits on its boundary the
    // iterates touch it from either side at the 1e-10 level, so a rise of up to
    // 1e-8 (the constraints are order 1) is not counted as a rise.
    bool mono = true, finite = true;
    double worst_rise = 0.0;
    std::printf("      violation:");
    for (int k = 0; k <= 10; ++k) {
      const double vk = viol(h[k]);
      std::printf(" %.2e", vk);
      for (double xv : h[k]) finite = finite && std::isfinite(xv);
      if (k > 0) worst_rise = std::max(worst_rise, vk - viol(h[k - 1]));
    }
    if (worst_rise > 1e-8) mono = false;
    std::printf("  (largest rise %.2e)", worst_rise);
    std::printf("\n");
    int feas = -1;
    for (std::size_t k = 0; k < h.size(); ++k) {
      for (double xv : h[k]) finite = finite && std::isfinite(xv);
      if (feas < 0 && viol(h[k]) <= 1e-9) feas = static_cast<int>(k);
    }
    report("(c)", mono && finite && viol(h[10]) < viol(h[0]),
           "m=3, infeasible start: violation %.4f -> %.4f after 10 steps (monotone, finite); feasible from iteration %g; final violation %.2e",
           viol(h[0]), viol(h[10]), feas, viol(h.back()));
  }

  std::printf("done: %d failure(s)\n", g_fail);
  return g_fail == 0 ? 0 : 1;
}
