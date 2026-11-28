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
#include <array>
#include <chrono>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <functional>
#include <string>
#include <map>
#include <stdexcept>
#include <vector>

#include "topopt/fea.hpp"
#include "topopt/mesh.hpp"
#include "topopt/stl.hpp"
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
                  SolverRunState* run, CgInfo* info, double tol = kTol) {
  return topopt::fea_solve_mgcg_matfree(m.g, m.youngs, kNu, m.bcs, loads, tol, kMaxIt, info,
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

// ======================================================================
// PART MODE (--part <stl> --res <N>): the loop on a real part's shape, with a stand-in
// load case, one box and three boxes, against the whole part at the fine voxel.
// ======================================================================
constexpr double kPartTol = 1e-6;  // every part-mode solve; the loop stops at 1e-3 of |r_0|
constexpr double kPartLoopTol = 1e-3;     // |r| / |r_0|
constexpr std::size_t kFineSkip = 2500000;  // solid voxels: skip the whole-fine reference above this

void model_from_grid(Model& m, VoxelGrid g) {
  m.g = std::move(g);
  const std::size_t n = m.g.voxel_count();
  m.youngs.assign(n, 0.0);
  m.density.assign(n, 0.0);
  for (std::size_t v = 0; v < n; ++v)
    if (m.g.tags[v] != VoxelTag::Empty) {
      m.youngs[v] = kE;
      m.density[v] = 1.0;
    }
  m.bcs.clear();
  m.loads.clear();
}

struct Stat3 {
  double peak = 0.0, p99 = 0.0, carry = 0.0;
  bool ok = false;
};

Stat3 read_region(const Model& m, const std::vector<double>& field, const Region& reg) {
  Stat3 s;
  std::vector<char> only(field.size(), 0);
  std::vector<double> vals;
  for (int k = 0; k < m.g.nz; ++k)
    for (int j = 0; j < m.g.ny; ++j)
      for (int i = 0; i < m.g.nx; ++i)
        if (reg.in(m.g.voxel_center(i, j, k))) {
          const std::size_t v = m.g.index(i, j, k);
          only[v] = 1;
          if (m.density[v] > 0.0) vals.push_back(field[v]);
        }
  if (vals.empty()) return s;
  std::sort(vals.begin(), vals.end());
  s.peak = vals.back();
  s.p99 = vals[static_cast<std::size_t>(0.99 * static_cast<double>(vals.size() - 1))];
  s.carry = topopt::stress_carried_to_surface(m.g, field, m.density, 1, &only).peak;
  s.ok = true;
  return s;
}

struct IBox {
  int b0[3], b1[3];
};

bool touch(const IBox& a, const IBox& b) {
  for (int q = 0; q < 3; ++q)
    if (a.b0[q] > b.b1[q] || b.b0[q] > a.b1[q]) return false;
  return true;
}

// The reading region of a box: the box minus one coarse voxel at each face inside the grid.
Region box_region(const VoxelGrid& g, const IBox& b) {
  const int dims[3] = {g.nx, g.ny, g.nz};
  const double o[3] = {g.origin.x, g.origin.y, g.origin.z};
  Region r;
  for (int a = 0; a < 3; ++a) {
    r.lo[a] = o[a] + b.b0[a] * g.spacing + (b.b0[a] > 0 ? g.spacing : 0.0);
    r.hi[a] = o[a] + b.b1[a] * g.spacing - (b.b1[a] < dims[a] ? g.spacing : 0.0);
  }
  return r;
}

struct PBox {
  IBox b;
  Model B;
  std::vector<Setup::FineNode> fine;
};

struct Multi {
  const Model* G = nullptr;
  std::vector<PBox> boxes;
  std::vector<int> gamma;
  std::map<int, int> at;
  VoxelGrid gA;
  std::vector<double> yA;
};

std::vector<char> live_nodes(const VoxelGrid& g) {
  std::vector<char> live(static_cast<std::size_t>(topopt::fea_node_count(g)), 0);
  for (int k = 0; k < g.nz; ++k)
    for (int j = 0; j < g.ny; ++j)
      for (int i = 0; i < g.nx; ++i)
        if (g.solid(i, j, k))
          for (int n : topopt::fea_element_nodes(g, i, j, k)) live[static_cast<std::size_t>(n)] = 1;
  return live;
}

Multi make_multi(const Model& G, const Model& F, const std::vector<char>& liveG, const std::vector<IBox>& boxes) {
  Multi M;
  M.G = &G;
  const int dims[3] = {G.g.nx, G.g.ny, G.g.nz};
  M.gA = G.g;
  M.yA.assign(G.youngs.size(), 0.0);
  std::fill(M.gA.tags.begin(), M.gA.tags.end(), VoxelTag::Empty);
  for (const IBox& ib : boxes) {
    PBox pb;
    pb.b = ib;
    bool lo_int[3], hi_int[3];
    int nb[3];
    for (int a = 0; a < 3; ++a) {
      lo_int[a] = ib.b0[a] > 0;
      hi_int[a] = ib.b1[a] < dims[a];
      nb[a] = ib.b1[a] - ib.b0[a];
    }
    for (int k = ib.b0[2]; k < ib.b1[2]; ++k)
      for (int j = ib.b0[1]; j < ib.b1[1]; ++j)
        for (int i = ib.b0[0]; i < ib.b1[0]; ++i) {
          const std::size_t v = G.g.index(i, j, k);
          M.gA.tags[v] = G.g.tags[v];
          M.yA[v] = G.youngs[v];
        }
    auto on_gamma = [&](int a, int b, int c, int scale) {
      return (a == 0 && lo_int[0]) || (a == scale * nb[0] && hi_int[0]) || (b == 0 && lo_int[1]) ||
             (b == scale * nb[1] && hi_int[1]) || (c == 0 && lo_int[2]) || (c == scale * nb[2] && hi_int[2]);
    };
    for (int c = 0; c <= nb[2]; ++c)
      for (int b = 0; b <= nb[1]; ++b)
        for (int a = 0; a <= nb[0]; ++a) {
          if (!on_gamma(a, b, c, 1)) continue;
          const int n = topopt::fea_node_index(G.g, ib.b0[0] + a, ib.b0[1] + b, ib.b0[2] + c);
          if (!liveG[static_cast<std::size_t>(n)] || M.at.count(n)) continue;
          M.at[n] = static_cast<int>(M.gamma.size());
          M.gamma.push_back(n);
        }
    // The fine box: cut from the whole fine voxelisation (nested: 8 fine per coarse).
    VoxelGrid bg;
    bg.nx = 2 * nb[0];
    bg.ny = 2 * nb[1];
    bg.nz = 2 * nb[2];
    bg.spacing = F.g.spacing;
    bg.origin = Vec3{G.g.origin.x + ib.b0[0] * G.g.spacing, G.g.origin.y + ib.b0[1] * G.g.spacing,
                     G.g.origin.z + ib.b0[2] * G.g.spacing};
    bg.tags.assign(static_cast<std::size_t>(bg.nx) * bg.ny * bg.nz, VoxelTag::Empty);
    for (int k = 0; k < bg.nz; ++k)
      for (int j = 0; j < bg.ny; ++j)
        for (int i = 0; i < bg.nx; ++i)
          bg.tags[bg.index(i, j, k)] = F.g.tag(2 * ib.b0[0] + i, 2 * ib.b0[1] + j, 2 * ib.b0[2] + k);
    model_from_grid(pb.B, std::move(bg));
    const VoxelGrid& B = pb.B.g;
    auto fine_touched = [&](int a, int b, int c) {
      for (int dk = -1; dk <= 0; ++dk)
        for (int dj = -1; dj <= 0; ++dj)
          for (int di = -1; di <= 0; ++di) {
            const int i = a + di, j = b + dj, k = c + dk;
            if (i >= 0 && j >= 0 && k >= 0 && i < B.nx && j < B.ny && k < B.nz && B.solid(i, j, k)) return true;
          }
      return false;
    };
    for (int c = 0; c <= B.nz; ++c)
      for (int b = 0; b <= B.ny; ++b)
        for (int a = 0; a <= B.nx; ++a) {
          if (!on_gamma(a, b, c, 2) || !fine_touched(a, b, c)) continue;
          Setup::FineNode fn{};
          fn.node = topopt::fea_node_index(B, a, b, c);
          int ia[2], ibb[2], ic[2];
          double wa[2], wb[2], wc[2];
          auto axis = [](int x, int* idx, double* w) {
            if (x % 2 == 0) {
              idx[0] = x / 2;
              w[0] = 1.0;
              return 1;
            }
            idx[0] = x / 2;
            idx[1] = x / 2 + 1;
            w[0] = w[1] = 0.5;
            return 2;
          };
          const int na = axis(a, ia, wa), nbn = axis(b, ibb, wb), nc = axis(c, ic, wc);
          double sum = 0.0;
          for (int x = 0; x < na; ++x)
            for (int y = 0; y < nbn; ++y)
              for (int z = 0; z < nc; ++z) {
                const int n = topopt::fea_node_index(G.g, ib.b0[0] + ia[x], ib.b0[1] + ibb[y], ib.b0[2] + ic[z]);
                const auto it = M.at.find(n);
                if (it == M.at.end()) continue;  // a coarse node no coarse voxel holds: left out
                fn.slot[fn.nw] = it->second;
                fn.w[fn.nw] = wa[x] * wb[y] * wc[z];
                sum += fn.w[fn.nw];
                ++fn.nw;
              }
          if (sum <= 0.0) continue;  // no live coarse node: the fine node stays free
          for (int q = 0; q < fn.nw; ++q) fn.w[q] /= sum;
          pb.fine.push_back(fn);
        }
    M.boxes.push_back(std::move(pb));
  }
  return M;
}

struct MultiOut {
  bool converged = false;
  int iterations = 0, global_solves = 0, box_solves = 0;
  long cg_global = 0, cg_box = 0;
  double t_global = 0.0, t_box = 0.0;
  FeaSolution uG, uG0;
  std::vector<FeaSolution> uF, uF0;
  bool out_of_time = false;
};

MultiOut run_multi(Multi& M, double budget_s) {
  MultiOut o;
  const double t_start = now_s();
  double last_it = 0.0;
  const Model& G = *M.G;
  SolverRunState global_run;
  std::vector<double> p(3 * M.gamma.size(), 0.0), r_prev;
  double omega = 1.0, r0 = 0.0;
  bool have = false;
  std::printf("  %4s %12s %9s %14s\n", "it", "|r|/|r_0|", "omega", "max |u_G| mm");
  for (int it = 0; it <= kLoopMax; ++it) {
    const double t_it = now_s();
    if (it > 0 && t_it - t_start + last_it > budget_s) {
      o.out_of_time = true;
      std::printf("  stopped by the time budget (%.0f s) before iteration %d\n", budget_s, it);
      break;
    }
    std::vector<NodalLoad> loads = G.loads;
    for (std::size_t q = 0; q < M.gamma.size(); ++q)
      for (int comp = 0; comp < 3; ++comp)
        if (p[3 * q + comp] != 0.0) loads.push_back({M.gamma[q], comp, p[3 * q + comp]});
    CgInfo gi;
    double t = now_s();
    FeaSolution prev = o.uG;
    o.uG = solve(G, loads, have ? &prev : nullptr, &global_run, &gi, kPartTol);
    o.t_global += now_s() - t;
    have = true;
    ++o.global_solves;
    o.cg_global += gi.iterations;
    std::vector<double> r(p.size(), 0.0);
    {
      const std::vector<double> Ku = topopt::fea_matfree_apply(M.gA, M.yA, kNu, o.uG.u);
      for (std::size_t q = 0; q < M.gamma.size(); ++q)
        for (int comp = 0; comp < 3; ++comp) r[3 * q + comp] = Ku[3 * M.gamma[q] + comp] - p[3 * q + comp];
    }
    o.uF.clear();
    t = now_s();
    for (PBox& pb : M.boxes) {
      pb.B.bcs.clear();
      for (const Setup::FineNode& fn : pb.fine)
        for (int comp = 0; comp < 3; ++comp) {
          double v = 0.0;
          for (int q = 0; q < fn.nw; ++q) v += fn.w[q] * o.uG.u[3 * M.gamma[fn.slot[q]] + comp];
          pb.B.bcs.push_back({fn.node, comp, v});
        }
      SolverRunState fresh;
      CgInfo bi;
      FeaSolution uF = solve(pb.B, {}, nullptr, &fresh, &bi, kPartTol);
      ++o.box_solves;
      o.cg_box += bi.iterations;
      const std::vector<double> Ku = topopt::fea_matfree_apply(pb.B.g, pb.B.youngs, kNu, uF.u);
      for (const Setup::FineNode& fn : pb.fine)
        for (int comp = 0; comp < 3; ++comp)
          for (int q = 0; q < fn.nw; ++q) r[3 * fn.slot[q] + comp] -= fn.w[q] * Ku[3 * fn.node + comp];
      o.uF.push_back(std::move(uF));
    }
    o.t_box += now_s() - t;
    const double nr = std::sqrt(dot(r, r));
    if (it == 0) {
      r0 = nr;
      o.uG0 = o.uG;
      o.uF0 = o.uF;
    }
    const double rel = r0 > 0.0 ? nr / r0 : 0.0;
    std::printf("  %4d %12.3e %9.4f %14.6f\n", it, rel, omega, max_disp(o.uG.u));
    std::fflush(stdout);
    last_it = now_s() - t_it;
    o.iterations = it;
    if (r0 == 0.0 || (it > 0 && rel < kPartLoopTol)) {
      o.converged = true;
      break;
    }
    if (it > 0) {
      std::vector<double> d(r.size());
      for (std::size_t i = 0; i < r.size(); ++i) d[i] = r[i] - r_prev[i];
      const double dd = dot(d, d);
      if (dd > 0.0) omega = -omega * dot(r_prev, d) / dd;
    }
    for (std::size_t i = 0; i < p.size(); ++i) p[i] += omega * r[i];
    r_prev = r;
  }
  return o;
}

void slab_bcs(Model& m, int L, int S, double thr_lo, double thr_hi) {
  const VoxelGrid& g = m.g;
  std::vector<char> clamp(static_cast<std::size_t>(topopt::fea_node_count(g)), 0), load = clamp;
  for (int k = 0; k < g.nz; ++k)
    for (int j = 0; j < g.ny; ++j)
      for (int i = 0; i < g.nx; ++i) {
        if (!g.solid(i, j, k)) continue;
        const Vec3 c = g.voxel_center(i, j, k);
        const double x = L == 0 ? c.x : L == 1 ? c.y : c.z;
        if (x < thr_lo)
          for (int n : topopt::fea_element_nodes(g, i, j, k)) clamp[static_cast<std::size_t>(n)] = 1;
        if (x > thr_hi)
          for (int n : topopt::fea_element_nodes(g, i, j, k)) load[static_cast<std::size_t>(n)] = 1;
      }
  int nl = 0;
  for (char c : load) nl += c ? 1 : 0;
  for (std::size_t n = 0; n < clamp.size(); ++n) {
    if (clamp[n])
      for (int comp = 0; comp < 3; ++comp) m.bcs.push_back({static_cast<int>(n), comp, 0.0});
    if (load[n]) m.loads.push_back({static_cast<int>(n), S, 10.0 / nl});
  }
  std::printf("  grid %d x %d x %d (voxel %.4f mm): %zu solid voxels, %zu clamped DOFs, %d loaded nodes\n", g.nx,
              g.ny, g.nz, g.spacing, g.solid_count(), m.bcs.size(), nl);
}

int run_part(const char* path, int res) {
  std::printf("[part] %s at --res %d\n", path, res);
  std::printf("[part] STAND-IN LOAD CASE (the owner's real load case needs the CLI's job setup, which a test cannot "
              "call): clamp the lowest 6 %% along the longest axis, 10 N along the shortest axis spread evenly over the "
              "nodes of the highest 6 %%. E = %.0f MPa, nu = %.2f, real stiffness.\n", kE, kNu);
  std::printf("[part] NOTE: all-or-nothing voxels by centre test: a coarse voxel and its 8 fine voxels need not hold "
              "the same material (the shapes differ between resolutions); volumes are printed below.\n");
  topopt::TriangleMesh mesh;
  try {
    mesh = topopt::read_stl_file(path).mesh;
  } catch (const std::exception& e) {
    std::printf("[part] FAILED to read the STL: %s\n", e.what());
    return 1;
  }
  double lo[3] = {1e300, 1e300, 1e300}, hi[3] = {-1e300, -1e300, -1e300};
  for (const Vec3& v : mesh.vertices) {
    const double c[3] = {v.x, v.y, v.z};
    for (int a = 0; a < 3; ++a) {
      lo[a] = std::min(lo[a], c[a]);
      hi[a] = std::max(hi[a], c[a]);
    }
  }
  int L = 0, S = 0;
  for (int a = 1; a < 3; ++a) {
    if (hi[a] - lo[a] > hi[L] - lo[L]) L = a;
    if (hi[a] - lo[a] < hi[S] - lo[S]) S = a;
  }
  const double ext = hi[L] - lo[L];
  const double thr_lo = lo[L] + 0.06 * ext, thr_hi = hi[L] - 0.06 * ext;
  std::printf("[part] %zu triangles; bounding box %.2f x %.2f x %.2f mm; longest axis %c, shortest %c\n",
              mesh.triangle_count(), hi[0] - lo[0], hi[1] - lo[1], hi[2] - lo[2], "xyz"[L], "xyz"[S]);
  int failures = 0;
  const double t_run = now_s();
  std::printf("[part] every solve at relative tolerance %.0e; loops stop at |r|/|r_0| < %.0e, 25 iterations, or a time budget (about 4 minutes a run)\n", kPartTol, kPartLoopTol);
  try {
    Model G, F;
    model_from_grid(G, topopt::voxelize(mesh, res));
    VoxelGrid fref;
    fref.nx = 2 * G.g.nx;
    fref.ny = 2 * G.g.ny;
    fref.nz = 2 * G.g.nz;
    fref.spacing = 0.5 * G.g.spacing;
    fref.origin = G.g.origin;
    fref.tags.assign(static_cast<std::size_t>(fref.nx) * fref.ny * fref.nz, VoxelTag::Empty);
    model_from_grid(F, topopt::voxelize_onto_grid(mesh, fref));
    mesh = topopt::TriangleMesh{};
    const double H = G.g.spacing, h = F.g.spacing;
    std::printf("[part] coarse:\n");
    slab_bcs(G, L, S, thr_lo, thr_hi);
    std::printf("[part] fine (same origin, half the voxel):\n");
    slab_bcs(F, L, S, thr_lo, thr_hi);
    const double volG = G.g.solid_count() * H * H * H, volF = F.g.solid_count() * h * h * h;
    std::printf("[part] solid volume: coarse %.1f mm3, fine %.1f mm3 (%+.2f %%)\n", volG, volF, 100.0 * (volF / volG - 1.0));
    const bool do_ref = F.g.solid_count() <= kFineSkip;
    if (!do_ref)
      std::printf("[part] the whole-fine reference has %zu solid voxels (> %zu): SKIPPED for this part\n",
                  F.g.solid_count(), kFineSkip);
    std::fflush(stdout);

    // (a) coarse alone.
    double t = now_s();
    SolverRunState ra;
    CgInfo ia;
    const FeaSolution uA = solve(G, G.loads, nullptr, &ra, &ia, kPartTol);
    const double ta = now_s() - t;
    const std::vector<double> fieldA = topopt::fea_von_mises_field(G.g, kE, kNu, uA);
    std::printf("[part] (a) coarse solve: %d CG its, %.2f s, converged %s\n", ia.iterations, ta, ia.converged ? "yes" : "NO");

    // The hot spots, clear of the slabs by more than 4 coarse voxels along the long axis.
    const int dims[3] = {G.g.nx, G.g.ny, G.g.nz};
    const double oL = L == 0 ? G.g.origin.x : L == 1 ? G.g.origin.y : G.g.origin.z;
    int cL = -1, fL = dims[L];
    for (int i = 0; i < dims[L]; ++i) {
      const double c = oL + (i + 0.5) * H;
      if (c < thr_lo) cL = i;
      if (c > thr_hi && fL == dims[L]) fL = i;
    }
    std::vector<std::pair<double, std::array<int, 3>>> cand;
    for (int k = 0; k < G.g.nz; ++k)
      for (int j = 0; j < G.g.ny; ++j)
        for (int i = 0; i < G.g.nx; ++i) {
          if (!G.g.solid(i, j, k)) continue;
          const int idx[3] = {i, j, k};
          if (idx[L] - cL <= 4 || fL - idx[L] <= 4) continue;
          cand.push_back({fieldA[G.g.index(i, j, k)], {i, j, k}});
        }
    std::sort(cand.begin(), cand.end(), [](const auto& a, const auto& b) { return a.first > b.first; });
    std::vector<std::array<int, 3>> spots;
    for (const auto& c : cand) {
      bool far = true;
      for (const auto& s : spots) {
        const double d = std::sqrt(double((c.second[0] - s[0]) * (c.second[0] - s[0]) +
                                          (c.second[1] - s[1]) * (c.second[1] - s[1]) +
                                          (c.second[2] - s[2]) * (c.second[2] - s[2])));
        if (d < 10.0) far = false;
      }
      if (far) {
        spots.push_back(c.second);
        std::printf("[part] hot spot %zu: coarse voxel (%d, %d, %d), von Mises %.3f MPa\n", spots.size(), c.second[0],
                    c.second[1], c.second[2], c.first);
      }
      if (spots.size() == 3) break;
    }
    if (spots.empty()) throw std::runtime_error("no hot spot clear of the slabs");
    const int ns = static_cast<int>(spots.size());
    std::vector<IBox> hb(spots.size());
    for (int s = 0; s < ns; ++s)
      for (int a = 0; a < 3; ++a) {
        int b0 = std::max(0, spots[s][a] - 6), b1 = std::min(dims[a], spots[s][a] + 7);
        if (a == L) {
          b0 = std::max(b0, cL + 2);
          b1 = std::min(b1, fL - 1);
        }
        hb[s].b0[a] = b0;
        hb[s].b1[a] = b1;
      }
    std::vector<Region> regs;
    for (const IBox& b : hb) regs.push_back(box_region(G.g, b));
    // Three boxes, merged where they overlap or touch.
    std::vector<IBox> merged = hb;
    for (bool again = true; again;) {
      again = false;
      for (std::size_t a = 0; a < merged.size() && !again; ++a)
        for (std::size_t b = a + 1; b < merged.size() && !again; ++b)
          if (touch(merged[a], merged[b])) {
            for (int q = 0; q < 3; ++q) {
              merged[a].b0[q] = std::min(merged[a].b0[q], merged[b].b0[q]);
              merged[a].b1[q] = std::max(merged[a].b1[q], merged[b].b1[q]);
            }
            merged.erase(merged.begin() + static_cast<long>(b));
            again = true;
          }
    }
    auto count_in = [](const Model& m, const IBox& b, int s) {
      std::size_t n = 0;
      for (int k = s * b.b0[2]; k < s * b.b1[2]; ++k)
        for (int j = s * b.b0[1]; j < s * b.b1[1]; ++j)
          for (int i = s * b.b0[0]; i < s * b.b1[0]; ++i)
            if (m.g.solid(i, j, k)) ++n;
      return n;
    };
    auto print_box = [&](const char* what, int s, const IBox& b) {
      const std::size_t nc = count_in(G, b, 1), nf = count_in(F, b, 2);
      std::printf("[part] %s %d: coarse [%d,%d) x [%d,%d) x [%d,%d); solid coarse %zu (%.1f mm3), fine %zu (%.1f mm3, "
                  "%.2f %% of the whole fine model)\n",
                  what, s + 1, b.b0[0], b.b1[0], b.b0[1], b.b1[1], b.b0[2], b.b1[2], nc, nc * H * H * H, nf,
                  nf * h * h * h, 100.0 * nf / static_cast<double>(F.g.solid_count()));
    };
    for (int s = 0; s < ns; ++s) print_box("box at hot spot", s, hb[s]);
    for (std::size_t s = 0; s < merged.size(); ++s) print_box("three-box run, box", static_cast<int>(s), merged[s]);
    std::fflush(stdout);

    const std::vector<char> liveG = live_nodes(G.g);
    struct Row {
      std::string name;
      double umax = 0.0;
      Stat3 st[3];
      bool have = false;
    };
    std::vector<Row> rows;
    auto inside_box = [](const IBox& b, const std::array<int, 3>& v) {
      for (int a = 0; a < 3; ++a)
        if (v[a] < b.b0[a] || v[a] >= b.b1[a]) return false;
      return true;
    };
    // Readings: a region inside a refined box is read from that box; otherwise from the coarse field.
    auto read_row = [&](const char* name, const FeaSolution& uG, const Multi* M, const std::vector<FeaSolution>* uF) {
      Row r;
      r.name = name;
      r.umax = max_disp(uG.u);
      r.have = true;
      const std::vector<double> fG = topopt::fea_von_mises_field(G.g, kE, kNu, uG);
      for (int s = 0; s < ns; ++s) {
        int bi = -1;
        if (M != nullptr)
          for (std::size_t b = 0; b < M->boxes.size(); ++b)
            if (inside_box(M->boxes[b].b, spots[s])) bi = static_cast<int>(b);
        if (bi < 0) {
          r.st[s] = read_region(G, fG, regs[s]);
        } else {
          const Model& B = M->boxes[static_cast<std::size_t>(bi)].B;
          const std::vector<double> fB = topopt::fea_von_mises_field(B.g, kE, kNu, (*uF)[static_cast<std::size_t>(bi)]);
          r.st[s] = read_region(B, fB, regs[s]);
        }
      }
      return r;
    };
    rows.push_back(read_row("(a) coarse alone", uA, nullptr, nullptr));

    // (d) the whole part at the fine voxel.
    double tf = 0.0;
    CgInfo ifn;
    Row rd;
    rd.name = "(d) whole fine";
    if (do_ref) {
      t = now_s();
      SolverRunState rf;
      const FeaSolution uF = solve(F, F.loads, nullptr, &rf, &ifn, kPartTol);
      tf = now_s() - t;
      const std::vector<double> fF = topopt::fea_von_mises_field(F.g, kE, kNu, uF);
      rd.umax = max_disp(uF.u);
      for (int s = 0; s < ns; ++s) rd.st[s] = read_region(F, fF, regs[s]);
      rd.have = true;
    }
    std::printf("[part] (d) whole fine solve: %s%d CG its, %.2f s, converged %s\n", do_ref ? "" : "(skipped) ", ifn.iterations, tf, ifn.converged ? "yes" : "NO");
    std::fflush(stdout);
    const double budget1 = std::max(30.0, (230.0 - (now_s() - t_run)) / 2.0);
    std::printf("[part] two-way loop, ONE box (hot spot 1), Aitken:\n");
    Multi M1 = make_multi(G, F, liveG, {hb[0]});
    std::printf("  Gamma: %zu coarse nodes, %zu fine nodes\n", M1.gamma.size(), M1.boxes[0].fine.size());
    const MultiOut o1 = run_multi(M1, budget1);
    const double budget3 = std::max(30.0, 230.0 - (now_s() - t_run));
    std::printf("[part] two-way loop, THREE boxes (%zu after merging), Aitken:\n", merged.size());
    Multi M3 = make_multi(G, F, liveG, merged);
    std::size_t nfine = 0;
    for (const PBox& pb : M3.boxes) nfine += pb.fine.size();
    std::printf("  Gamma: %zu coarse nodes, %zu fine nodes\n", M3.gamma.size(), nfine);
    const MultiOut o3 = run_multi(M3, budget3);
    rows.push_back(read_row("(b) one-way zoom (3 boxes, it 0)", o3.uG0, &M3, &o3.uF0));
    rows.push_back(read_row(o1.converged ? "(c1) two-way, one box" : o1.out_of_time ? "(c1) one box, OUT OF TIME" : "(c1) one box NOT CONVERGED", o1.uG, &M1, &o1.uF));
    rows.push_back(read_row(o3.converged ? "(c3) two-way, three boxes" : o3.out_of_time ? "(c3) three boxes, OUT OF TIME" : "(c3) three NOT CONVERGED", o3.uG, &M3, &o3.uF));


    rows.push_back(rd);
    std::printf("\n[part] table: largest displacement (mm); per hot-spot region: per-voxel peak / 99th percentile / "
                "carried-to-surface peak von Mises (MPa)\n");
    std::printf("%-34s %10s", "", "max|u|");
    for (int s = 0; s < ns; ++s) std::printf(" | %8s %8s %8s", ("pk" + std::to_string(s + 1)).c_str(),
                                             ("p99_" + std::to_string(s + 1)).c_str(), ("car" + std::to_string(s + 1)).c_str());
    std::printf("\n");
    for (const Row& r : rows) {
      if (!r.have) {
        std::printf("%-34s skipped\n", r.name.c_str());
        continue;
      }
      std::printf("%-34s %10.5f", r.name.c_str(), r.umax);
      for (int s = 0; s < ns; ++s) std::printf(" | %8.3f %8.3f %8.3f", r.st[s].peak, r.st[s].p99, r.st[s].carry);
      std::printf("\n");
    }
    if (rd.have) {
      std::printf("[part] gaps against (d), percent:\n");
      auto pc = [](double a, double b) { return b != 0.0 ? 100.0 * (a / b - 1.0) : 0.0; };
      for (std::size_t q = 0; q + 1 < rows.size(); ++q) {
        const Row& r = rows[q];
        std::printf("%-34s %+10.2f", r.name.c_str(), pc(r.umax, rd.umax));
        for (int s = 0; s < ns; ++s)
          std::printf(" | %+8.2f %+8.2f %+8.2f", pc(r.st[s].peak, rd.st[s].peak), pc(r.st[s].p99, rd.st[s].p99),
                      pc(r.st[s].carry, rd.st[s].carry));
        std::printf("\n");
      }
    }
    std::printf("[part] (c) converges to a composite model (fine in the boxes, coarse outside), so (c) need not equal (d). "
                "Regions not refined in a row are read from that row's coarse field.\n");
    std::printf("[part] COST: (a) %d CG its, %.2f s | one box: %d iterations, %d global solves (%ld CG its, %.2f s) + %d "
                "box solves (%ld CG its, %.2f s) | three boxes: %d iterations, %d global (%ld its, %.2f s) + %d box (%ld its, "
                "%.2f s) | (d) %s %d CG its, %.2f s\n",
                ia.iterations, ta, o1.iterations, o1.global_solves, o1.cg_global, o1.t_global, o1.box_solves, o1.cg_box,
                o1.t_box, o3.iterations, o3.global_solves, o3.cg_global, o3.t_global, o3.box_solves, o3.cg_box, o3.t_box,
                do_ref ? "" : "(skipped)", ifn.iterations, tf);
  } catch (const std::exception& e) {
    std::printf("[part] FAILED: %s\n", e.what());
    ++failures;
  }
  std::printf("[part] %d failure(s)\n", failures);
  return failures == 0 ? 0 : 1;
}

}  // namespace

int main(int argc, char** argv) {
  if (argc >= 2 && std::strcmp(argv[1], "--part") == 0) {
    if (argc < 3) {
      std::printf("usage: --part <stl> --res <N>\n");
      return 2;
    }
    int res = 48;
    for (int a = 3; a + 1 < argc; ++a)
      if (std::strcmp(argv[a], "--res") == 0) res = std::atoi(argv[a + 1]);
    return run_part(argv[2], res);
  }
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
