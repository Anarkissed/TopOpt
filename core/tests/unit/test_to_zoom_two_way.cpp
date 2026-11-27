// TO rebuild, graded-voxels side piece: the TWO-WAY non-intrusive global-local loop
// AROUND the unchanged solver (Gosselet et al. 2018, Algorithm 1 with Aitken;
// Whitcomb 1991), measured against a full fine solve. A MEASURING test: prints
// tables; returns 0 unless something fails to solve.
//
// The coarse model (voxel H) is solved with loads f + p, p living on the coarse
// nodes of the box boundary Gamma (box faces interior to the model only). The box is
// re-voxelised at h = H / r from the true shape and solved with the coarse field
// interpolated trilinearly onto its Gamma nodes. Its reaction there, carried back by
// the transpose of that interpolation (lambda_F), is compared with the coarse zone's
// own reaction (lambda_A = K_A u_G on the box's coarse voxels): r = lambda_A -
// lambda_F - p, p <- p + omega r (Aitken or omega = 1).
//
// Every call is to the public solver API (fea.hpp, stress_measure.hpp): nothing in
// the solver is changed. Long-only (never in the default suite).
#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstdio>
#include <functional>
#include <map>
#include <stdexcept>
#include <vector>

#include "topopt/fea.hpp"
#include "topopt/stress_measure.hpp"
#include "topopt/voxel.hpp"

using topopt::CgInfo;
using topopt::DirichletBC;
using topopt::FeaSolution;
using topopt::NodalLoad;
using topopt::SolverRunState;
using topopt::SolverSettings;
using topopt::Vec3;
using topopt::VoxelGrid;
using topopt::VoxelTag;

namespace {

constexpr double kE = 3500.0;
constexpr double kNu = 0.33;
constexpr double kH = 1.0;  // coarse voxel, mm
constexpr double kTol = 1e-10;
constexpr int kMaxIt = 20000;
constexpr int kLoopMax = 25;
constexpr double kLoopTol = 1e-4;

using Inside = std::function<bool(double, double, double)>;
using BcMaker = std::function<void(const VoxelGrid&, std::vector<DirichletBC>&, std::vector<NodalLoad>&)>;

double now_s() {
  return std::chrono::duration<double>(std::chrono::steady_clock::now().time_since_epoch()).count();
}

SolverSettings settings() {
  SolverSettings s = topopt::fea_current_solver_settings();
  s.matfree_threads = 1;
  return s;
}

struct Model {
  VoxelGrid g;
  std::vector<double> youngs, density;
  std::vector<DirichletBC> bcs;
  std::vector<NodalLoad> loads;
};

// A grid of nx x ny x nz voxels of edge h at `origin`, all-or-nothing by centre test.
void fill_grid(Model& m, int nx, int ny, int nz, double h, Vec3 origin, const Inside& inside) {
  m.g.nx = nx;
  m.g.ny = ny;
  m.g.nz = nz;
  m.g.spacing = h;
  m.g.origin = origin;
  const std::size_t n = static_cast<std::size_t>(nx) * ny * nz;
  m.g.tags.assign(n, VoxelTag::Empty);
  m.youngs.assign(n, 0.0);
  m.density.assign(n, 0.0);
  for (int k = 0; k < nz; ++k)
    for (int j = 0; j < ny; ++j)
      for (int i = 0; i < nx; ++i) {
        const Vec3 c = m.g.voxel_center(i, j, k);
        if (inside(c.x, c.y, c.z)) {
          const std::size_t v = m.g.index(i, j, k);
          m.g.tags[v] = VoxelTag::Interior;
          m.youngs[v] = kE;
          m.density[v] = 1.0;
        }
      }
}

// Traction on the face x = nx (total force `total` along component `comp`): each face
// element carries traction * area, a quarter to each of its nodes.
void tip_traction(const VoxelGrid& g, int comp, double total, std::vector<NodalLoad>& loads) {
  int faces = 0;
  for (int k = 0; k < g.nz; ++k)
    for (int j = 0; j < g.ny; ++j)
      if (g.solid(g.nx - 1, j, k)) ++faces;
  const double q = 0.25 * total / faces;
  for (int k = 0; k < g.nz; ++k)
    for (int j = 0; j < g.ny; ++j)
      if (g.solid(g.nx - 1, j, k))
        for (int dk = 0; dk < 2; ++dk)
          for (int dj = 0; dj < 2; ++dj)
            loads.push_back({topopt::fea_node_index(g, g.nx, j + dj, k + dk), comp, q});
}

void clamp_x0(const VoxelGrid& g, std::vector<DirichletBC>& bcs) {
  for (int c = 0; c <= g.nz; ++c)
    for (int b = 0; b <= g.ny; ++b)
      for (int comp = 0; comp < 3; ++comp)
        bcs.push_back({topopt::fea_node_index(g, 0, b, c), comp, 0.0});
}

FeaSolution solve(const Model& m, const std::vector<NodalLoad>& loads, const FeaSolution* guess,
                  SolverRunState* run, CgInfo* info) {
  return topopt::fea_solve_mgcg_matfree(m.g, m.youngs, kNu, m.bcs, loads, kTol, kMaxIt, info,
                                        nullptr, guess, settings(), run);
}

double max_disp(const std::vector<double>& u) {
  double mx = 0.0;
  for (std::size_t n = 0; n + 2 < u.size(); n += 3)
    mx = std::max(mx, std::sqrt(u[n] * u[n] + u[n + 1] * u[n + 1] + u[n + 2] * u[n + 2]));
  return mx;
}

struct Reading {
  double voxel = 0.0, carry = 0.0;
  std::size_t unresolved = 0;
};

// The box region in mm, with a margin of one coarse voxel off every Gamma face.
struct Region {
  double lo[3], hi[3];
  bool in(const Vec3& c) const {
    return c.x > lo[0] && c.x < hi[0] && c.y > lo[1] && c.y < hi[1] && c.z > lo[2] && c.z < hi[2];
  }
};

Reading read_stress(const Model& m, const FeaSolution& sol, const Region& reg) {
  Reading r;
  const std::vector<double> field = topopt::fea_von_mises_field(m.g, kE, kNu, sol);
  std::vector<char> only(field.size(), 0);
  for (int k = 0; k < m.g.nz; ++k)
    for (int j = 0; j < m.g.ny; ++j)
      for (int i = 0; i < m.g.nx; ++i)
        if (reg.in(m.g.voxel_center(i, j, k))) {
          const std::size_t v = m.g.index(i, j, k);
          only[v] = 1;
          if (m.density[v] > 0.0) r.voxel = std::max(r.voxel, field[v]);
        }
  const topopt::SurfaceCarry sc = topopt::stress_carried_to_surface(m.g, field, m.density, 1, &only);
  r.carry = sc.peak;
  r.unresolved = sc.unresolved;
  return r;
}

struct Case {
  const char* name;
  int nx, ny, nz;
  int b0[3], b1[3];  // the box in coarse voxels [b0, b1)
  Inside inside;
  BcMaker bc;
  double textbook;   // 0: none
  double far;        // the far stress for a ratio (0: none)
};

// Everything one loop needs: the coarse model, the zone operator, the box.
struct Setup {
  const Case* cs = nullptr;
  int r = 2;
  Model G;                       // coarse global
  std::vector<double> youngsA;   // coarse, only the box's voxels
  VoxelGrid gA;
  std::vector<int> gamma;        // coarse Gamma node ids
  std::map<int, int> gamma_at;   // node id -> slot
  Model B;                       // the fine box (bcs filled per solve)
  struct FineNode {
    int node;
    int nw;
    int slot[4];
    double w[4];
  };
  std::vector<FineNode> fine_gamma;
  Region reg;
  double fnorm = 0.0;
};

Setup make_setup(const Case& cs, int r) {
  Setup s;
  s.cs = &cs;
  s.r = r;
  fill_grid(s.G, cs.nx, cs.ny, cs.nz, kH, Vec3{0.0, 0.0, 0.0}, cs.inside);
  cs.bc(s.G.g, s.G.bcs, s.G.loads);
  {
    std::vector<double> f(3 * topopt::fea_node_count(s.G.g), 0.0);
    for (const NodalLoad& l : s.G.loads) f[3 * l.node + l.component] += l.value;
    double n2 = 0.0;
    for (double v : f) n2 += v * v;
    s.fnorm = std::sqrt(n2);
  }
  const int dims[3] = {cs.nx, cs.ny, cs.nz};
  bool lo_int[3], hi_int[3];
  for (int a = 0; a < 3; ++a) {
    lo_int[a] = cs.b0[a] > 0;
    hi_int[a] = cs.b1[a] < dims[a];
    s.reg.lo[a] = cs.b0[a] * kH + (lo_int[a] ? kH : 0.0);
    s.reg.hi[a] = cs.b1[a] * kH - (hi_int[a] ? kH : 0.0);
  }
  // The zone operator: the coarse grid with only the box's voxels solid.
  s.gA = s.G.g;
  s.youngsA = s.G.youngs;
  for (int k = 0; k < cs.nz; ++k)
    for (int j = 0; j < cs.ny; ++j)
      for (int i = 0; i < cs.nx; ++i) {
        const bool in = i >= cs.b0[0] && i < cs.b1[0] && j >= cs.b0[1] && j < cs.b1[1] &&
                        k >= cs.b0[2] && k < cs.b1[2];
        if (!in) {
          s.gA.tags[s.gA.index(i, j, k)] = VoxelTag::Empty;
          s.youngsA[s.gA.index(i, j, k)] = 0.0;
        }
      }
  const int nb[3] = {cs.b1[0] - cs.b0[0], cs.b1[1] - cs.b0[1], cs.b1[2] - cs.b0[2]};
  auto on_gamma = [&](int a, int b, int c, int scale) {
    return (a == 0 && lo_int[0]) || (a == scale * nb[0] && hi_int[0]) || (b == 0 && lo_int[1]) ||
           (b == scale * nb[1] && hi_int[1]) || (c == 0 && lo_int[2]) || (c == scale * nb[2] && hi_int[2]);
  };
  for (int c = 0; c <= nb[2]; ++c)
    for (int b = 0; b <= nb[1]; ++b)
      for (int a = 0; a <= nb[0]; ++a)
        if (on_gamma(a, b, c, 1)) {
          const int n = topopt::fea_node_index(s.G.g, cs.b0[0] + a, cs.b0[1] + b, cs.b0[2] + c);
          s.gamma_at[n] = static_cast<int>(s.gamma.size());
          s.gamma.push_back(n);
        }
  // The fine box.
  fill_grid(s.B, r * nb[0], r * nb[1], r * nb[2], kH / r,
            Vec3{cs.b0[0] * kH, cs.b0[1] * kH, cs.b0[2] * kH}, cs.inside);
  // Trilinear weights from the coarse face nodes (emulates the solver's file-local
  // axis_weights: a fine node on a coarse node takes it, otherwise the linear mix).
  auto axis = [r](int a, int* idx, double* w) {
    const int I = a / r, rem = a % r;
    if (rem == 0) {
      idx[0] = I;
      w[0] = 1.0;
      return 1;
    }
    idx[0] = I;
    w[0] = 1.0 - static_cast<double>(rem) / r;
    idx[1] = I + 1;
    w[1] = static_cast<double>(rem) / r;
    return 2;
  };
  for (int c = 0; c <= r * nb[2]; ++c)
    for (int b = 0; b <= r * nb[1]; ++b)
      for (int a = 0; a <= r * nb[0]; ++a) {
        if (!on_gamma(a, b, c, r)) continue;
        Setup::FineNode fn{};
        fn.node = topopt::fea_node_index(s.B.g, a, b, c);
        int ia[2], ib[2], ic[2];
        double wa[2], wb[2], wc[2];
        const int na = axis(a, ia, wa), nbb = axis(b, ib, wb), nc = axis(c, ic, wc);
        for (int x = 0; x < na; ++x)
          for (int y = 0; y < nbb; ++y)
            for (int z = 0; z < nc; ++z) {
              const int n = topopt::fea_node_index(s.G.g, cs.b0[0] + ia[x], cs.b0[1] + ib[y],
                                                   cs.b0[2] + ic[z]);
              const auto it = s.gamma_at.find(n);
              if (it == s.gamma_at.end()) throw std::logic_error("a fine Gamma node reads a coarse node off Gamma");
              fn.slot[fn.nw] = it->second;
              fn.w[fn.nw] = wa[x] * wb[y] * wc[z];
              ++fn.nw;
            }
        s.fine_gamma.push_back(fn);
      }
  return s;
}

struct BoxOut {
  FeaSolution uF;
  std::vector<double> lamF;  // on the coarse Gamma slots, 3 per slot
  int cg = 0;
};

BoxOut box_solve(Setup& s, const std::vector<double>& uG) {
  BoxOut o;
  s.B.bcs.clear();
  for (const Setup::FineNode& fn : s.fine_gamma)
    for (int comp = 0; comp < 3; ++comp) {
      double v = 0.0;
      for (int q = 0; q < fn.nw; ++q) v += fn.w[q] * uG[3 * s.gamma[fn.slot[q]] + comp];
      s.B.bcs.push_back({fn.node, comp, v});
    }
  SolverRunState fresh;
  CgInfo info;
  o.uF = solve(s.B, {}, nullptr, &fresh, &info);
  o.cg = info.iterations;
  const std::vector<double> Ku = topopt::fea_matfree_apply(s.B.g, s.B.youngs, kNu, o.uF.u);
  o.lamF.assign(3 * s.gamma.size(), 0.0);
  for (const Setup::FineNode& fn : s.fine_gamma)
    for (int comp = 0; comp < 3; ++comp)
      for (int q = 0; q < fn.nw; ++q) o.lamF[3 * fn.slot[q] + comp] += fn.w[q] * Ku[3 * fn.node + comp];
  return o;
}

std::vector<double> lambda_A(const Setup& s, const std::vector<double>& uG) {
  const std::vector<double> Ku = topopt::fea_matfree_apply(s.gA, s.youngsA, kNu, uG);
  std::vector<double> l(3 * s.gamma.size());
  for (std::size_t q = 0; q < s.gamma.size(); ++q)
    for (int comp = 0; comp < 3; ++comp) l[3 * q + comp] = Ku[3 * s.gamma[q] + comp];
  return l;
}

double dot(const std::vector<double>& a, const std::vector<double>& b) {
  double d = 0.0;
  for (std::size_t i = 0; i < a.size(); ++i) d += a[i] * b[i];
  return d;
}

struct LoopOut {
  bool converged = false;
  int iterations = 0;  // loop updates made (global solves = iterations + 1)
  int global_solves = 0, box_solves = 0;
  long cg_global = 0, cg_box = 0;
  double seconds = 0.0;
  double r0 = 0.0, rlast = 0.0;
  double umax0 = 0.0, umax = 0.0;
  Reading zoom1, box;  // iteration 0 (one-way) and the last
};

LoopOut run_loop(Setup& s, bool aitken, bool print) {
  LoopOut o;
  const double t0 = now_s();
  SolverRunState global_run;
  std::vector<double> p(3 * s.gamma.size(), 0.0), r_prev;
  double omega = 1.0;
  FeaSolution uG;
  bool have = false;
  if (print) std::printf("  %4s %12s %9s %12s %14s\n", "it", "|r|/|f|", "omega", "max |u_G| mm", "box peak vM");
  for (int it = 0; it <= kLoopMax; ++it) {
    std::vector<NodalLoad> loads = s.G.loads;
    for (std::size_t q = 0; q < s.gamma.size(); ++q)
      for (int comp = 0; comp < 3; ++comp)
        if (p[3 * q + comp] != 0.0) loads.push_back({s.gamma[q], comp, p[3 * q + comp]});
    CgInfo gi;
    uG = solve(s.G, loads, have ? &uG : nullptr, &global_run, &gi);
    have = true;
    ++o.global_solves;
    o.cg_global += gi.iterations;
    BoxOut bo = box_solve(s, uG.u);
    ++o.box_solves;
    o.cg_box += bo.cg;
    const std::vector<double> lA = lambda_A(s, uG.u);
    std::vector<double> r(p.size());
    for (std::size_t i = 0; i < r.size(); ++i) r[i] = lA[i] - bo.lamF[i] - p[i];
    const double rel = std::sqrt(dot(r, r)) / s.fnorm;
    const Reading rd = read_stress(s.B, bo.uF, s.reg);
    o.umax = max_disp(uG.u);
    o.box = rd;
    o.rlast = rel;
    if (it == 0) {
      o.r0 = rel;
      o.umax0 = o.umax;
      o.zoom1 = rd;
    }
    if (print)
      std::printf("  %4d %12.3e %9.4f %12.6f %14.4f\n", it, rel, omega, o.umax, rd.voxel);
    if (rel < kLoopTol) {
      o.converged = true;
      o.iterations = it;
      break;
    }
    o.iterations = it;
    if (aitken && it > 0) {
      std::vector<double> d(r.size());
      for (std::size_t i = 0; i < r.size(); ++i) d[i] = r[i] - r_prev[i];
      const double dd = dot(d, d);
      if (dd > 0.0) omega = -omega * dot(r_prev, d) / dd;
    }
    for (std::size_t i = 0; i < p.size(); ++i) p[i] += omega * r[i];
    r_prev = r;
  }
  o.seconds = now_s() - t0;
  return o;
}

int run_case(const Case& cs, bool with_identity) {
  int failures = 0;
  std::printf("\n==== %s: coarse %d x %d x %d voxels of %.1f mm, box [%d,%d) x [%d,%d) x [%d,%d)\n", cs.name,
              cs.nx, cs.ny, cs.nz, kH, cs.b0[0], cs.b1[0], cs.b0[1], cs.b1[1], cs.b0[2], cs.b1[2]);
  try {
    if (with_identity) {
      // The sign and identity check: a box at the SAME voxel as the coarse zone.
      Setup s1 = make_setup(cs, 1);
      std::printf("[identity] box at ratio 1 (the coarse zone itself), p = 0:\n");
      const LoopOut o1 = run_loop(s1, true, true);
      std::printf("[identity] |r|/|f| at iteration 0: %.3e (must be at solver tolerance)\n", o1.r0);
      if (!(o1.r0 < 1e-6)) {
        std::printf("[identity] FAILED: the residual does not vanish\n");
        ++failures;
      }
    }
    Setup s = make_setup(cs, 2);
    std::printf("Gamma: %zu coarse nodes, %zu fine nodes; fine box %d x %d x %d; |f| = %.4g N\n",
                s.gamma.size(), s.fine_gamma.size(), s.B.g.nx, s.B.g.ny, s.B.g.nz, s.fnorm);
    // (a) the coarse solve alone.
    double t = now_s();
    SolverRunState ra;
    CgInfo ia;
    const FeaSolution uA = solve(s.G, s.G.loads, nullptr, &ra, &ia);
    const double ta = now_s() - t;
    const Reading readA = read_stress(s.G, uA, s.reg);
    const double umaxA = max_disp(uA.u);
    // (b) and (c): the loop, with Aitken (printed) and without.
    std::printf("two-way loop, Aitken:\n");
    const LoopOut L = run_loop(s, true, true);
    std::printf("two-way loop, omega = 1 (no acceleration):\n");
    const LoopOut L1 = run_loop(s, false, true);
    // (d) the whole model at the fine voxel.
    Model F;
    fill_grid(F, 2 * cs.nx, 2 * cs.ny, 2 * cs.nz, kH / 2, Vec3{0.0, 0.0, 0.0}, cs.inside);
    cs.bc(F.g, F.bcs, F.loads);
    t = now_s();
    SolverRunState rf;
    CgInfo ifn;
    const FeaSolution uF = solve(F, F.loads, nullptr, &rf, &ifn);
    const double tf = now_s() - t;
    const Reading readF = read_stress(F, uF, s.reg);
    const double umaxF = max_disp(uF.u);

    auto ratio = [&](double v) { return cs.far > 0.0 ? v / cs.far : 0.0; };
    std::printf("\n[%s] table (stress in MPa; ratio = over the far stress where one applies)\n", cs.name);
    std::printf("%-30s %12s %11s %7s %11s %7s %6s %6s\n", "", "max |u| mm", "vM voxel", "ratio",
                "vM carried", "ratio", "unres", "iters");
    auto row = [&](const char* n, double u, const Reading& r, int iters) {
      std::printf("%-30s %12.6f %11.4f %7.3f %11.4f %7.3f %6zu %6d\n", n, u, r.voxel, ratio(r.voxel), r.carry,
                  ratio(r.carry), r.unresolved, iters);
    };
    row("(a) coarse alone", umaxA, readA, 0);
    row("(b) one-way zoom (iteration 0)", L.umax0, L.zoom1, 0);
    row(L.converged ? "(c) two-way, Aitken" : "(c) two-way, Aitken NOT CONV", L.umax, L.box, L.iterations);
    row(L1.converged ? "(c') two-way, omega = 1" : "(c') two-way, omega=1 NOT CONV", L1.umax, L1.box,
        L1.iterations);
    row("(d) whole model fine", umaxF, readF, 0);
    if (cs.textbook > 0.0) std::printf("    textbook (infinite plate): ratio %.2f\n", cs.textbook);
    std::printf("    gap (c) against (d): max |u| %+.2f %%, vM voxel %+.2f %%, vM carried %+.2f %%\n",
                100.0 * (L.umax / umaxF - 1.0), 100.0 * (L.box.voxel / readF.voxel - 1.0),
                100.0 * (L.box.carry / readF.carry - 1.0));
    std::printf("    gap (a) against (d): max |u| %+.2f %%; (b) against (d): vM voxel %+.2f %%, carried %+.2f %%\n",
                100.0 * (umaxA / umaxF - 1.0), 100.0 * (L.zoom1.voxel / readF.voxel - 1.0),
                100.0 * (L.zoom1.carry / readF.carry - 1.0));
    std::printf("    (e) the loop converges to a composite model (fine in the box, coarse outside), so (c) need not equal (d).\n");
    std::printf("[%s] cost: (a) 1 solve, %d CG its, %.3f s | loop Aitken: %d global + %d box solves, CG its %ld + %ld, %.3f s"
                " | loop omega=1: %d + %d solves, CG its %ld + %ld, %.3f s | (d) 1 solve, %d CG its, %.3f s\n",
                cs.name, ia.iterations, ta, L.global_solves, L.box_solves, L.cg_global, L.cg_box, L.seconds,
                L1.global_solves, L1.box_solves, L1.cg_global, L1.cg_box, L1.seconds, ifn.iterations, tf);
    std::printf("[%s] sizes: coarse %zu solid voxels, fine box %zu, whole fine %zu\n", cs.name,
                s.G.g.solid_count(), s.B.g.solid_count(), F.g.solid_count());
    std::fflush(stdout);
  } catch (const std::exception& e) {
    std::printf("[%s] FAILED to solve: %s\n", cs.name, e.what());
    ++failures;
  }
  return failures;
}

}  // namespace

int main() {
  int failures = 0;
  // CASE 0: a solid bar 24 x 6 x 6, clamped at x = 0, a transverse tip load; the box in
  // its middle across the whole section.
  Case c0{"CASE 0 bar", 24, 6, 6, {9, 0, 0}, {15, 6, 6},
          [](double x, double y, double z) { return x >= 0 && x <= 24 && y >= 0 && y <= 6 && z >= 0 && z <= 6; },
          [](const VoxelGrid& g, std::vector<DirichletBC>& bcs, std::vector<NodalLoad>& loads) {
            clamp_x0(g, bcs);
            tip_traction(g, 1, -10.0, loads);
          },
          0.0, 0.0};
  failures += run_case(c0, true);

  // CASE 1: a plate 48 x 24 x 4 under uniform tension (10 MPa along x), a through-hole
  // of radius 3 at the centre offset (0.29, -0.41); the box covers the hole + 3 voxels.
  const double hx = 24.0 + 0.29, hy = 12.0 - 0.41, hr = 3.0;
  Case c1{"CASE 1 plate with a hole", 48, 24, 4, {18, 5, 0}, {31, 18, 4},
          [=](double x, double y, double) { return std::hypot(x - hx, y - hy) > hr; },
          [](const VoxelGrid& g, std::vector<DirichletBC>& bcs, std::vector<NodalLoad>& loads) {
            for (int c = 0; c <= g.nz; ++c)
              for (int b = 0; b <= g.ny; ++b) bcs.push_back({topopt::fea_node_index(g, 0, b, c), 0, 0.0});
            bcs.push_back({topopt::fea_node_index(g, 0, 0, 0), 1, 0.0});
            bcs.push_back({topopt::fea_node_index(g, 0, 0, 0), 2, 0.0});
            bcs.push_back({topopt::fea_node_index(g, 0, g.ny, 0), 2, 0.0});
            const double area = g.ny * g.spacing * g.nz * g.spacing;
            tip_traction(g, 0, 10.0 * area, loads);
          },
          3.0, 10.0};
  failures += run_case(c1, false);

  // CASE 2: a beam 40 x 12 x 4, clamped at x = 0, loaded in -y at x = 40; a neck from
  // x = 15 to 25 whose true depth in y is 1.5 voxels (y in [5.3, 6.8]): the coarse
  // model sees 2 voxels, the fine one 3 half-voxels. The box covers the neck + 3.
  Case c2{"CASE 2 necked beam", 40, 12, 4, {12, 0, 0}, {28, 12, 4},
          [](double x, double y, double) {
            if (x > 15.0 && x < 25.0) return y > 5.3 && y < 6.8;
            return y >= 0.0 && y <= 12.0;
          },
          [](const VoxelGrid& g, std::vector<DirichletBC>& bcs, std::vector<NodalLoad>& loads) {
            clamp_x0(g, bcs);
            tip_traction(g, 1, -1.0, loads);
          },
          0.0, 0.0};
  failures += run_case(c2, false);

  std::printf("\n[zoom two-way] measure only: %d failure(s)\n", failures);
  return failures == 0 ? 0 : 1;
}
