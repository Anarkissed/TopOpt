// amg_lean_probe.cpp — AMG Phase-1 measurement harness. NOT a CI test, NOT wired
// into CTest, NOT linked into any production path. It is the SECOND measurement
// handoff 131 §5e asked for, and it answers three questions with numbers:
//
//   [1] Does the 131 §5d carry-where-geometric-fails property SURVIVE a rebuild
//       whose fine level is fully matrix-free (no assembled fine K, 078's
//       property restored)? 131's 23-103x outer-iteration win is the thing that
//       must not evaporate.
//   [2] Can COARSENING CONTROL cure the 131 §2d developed-field collapse
//       (coarsening ratio 10.6x -> 1.35x, coarse operators 100 % dense, setup
//       6.7x, memory 3.3 GB)? Cured, or declared incurable, with the table.
//   [3] MEMORY, with a hard number: is peak AMG memory <= 2x the matfree
//       baseline at real extents?
//
// ---------------------------------------------------------------------------
// THE BARS, STATED BEFORE ANY MEASUREMENT (they are the task's, verbatim in
// substance; the baseline number each is measured against is printed FIRST by
// `./amg_lean_probe memory`):
//
//   B1 MEMORY      peak AMG memory <= 2.0x the matrix-free baseline at real
//                  extents. Baseline = what the production geometric matrix-free
//                  hierarchy stores (fea_matfree_mgcg_assembled_operator_nonzeros
//                  x 12 bytes — the SAME estimator 131 §6c used for its 88.9 MB),
//                  and it is printed before any AMG number.
//   B2 CARRY       the 131 §5d property must survive: on every fixture where the
//                  geometric path cannot converge, lean AMG builds and carries,
//                  with an outer-iteration win in the 131 band.
//   B3 END-TO-END  on DEVELOPED fields, lean AMG total (setup + solve) >= 1.0x
//                  the current solver's total, i.e. NO REGRESSION.
//   B4 DETERMINISM bit-identical twice-run: two independent setups and two
//                  independent solves, memcmp on the operators and on the
//                  residual histories.
//
//   ANY bar failed = honest NO-GO with the table. The Phase-2 wiring sketch is
//   not written unless all four pass.
//
// ---------------------------------------------------------------------------
// FIXTURES
//   * The 131 family, re-derived by the identical rule (the fixture builder here
//     is a copy of amg_probe.cpp's, so the Phase-0 tables stay comparable and
//     amg_probe.cpp is not edited — this lane adds files only).
//   * PLUS the ULTRA-DILUTE fixture from ACTIVE DOMAIN Phase 0 (handoff 134
//     §1a/§2, `active_domain_probe.cpp:dilute_box`): a 48x32x48 box with an
//     L-bracket part at 2.05 % fill (48.8x dilution), carrying a REAL
//     OC-developed density field (40 iterations at the part-relative rung
//     vf 0.26, production filter radius, the same recipe 134's committed
//     `ultradilute_stdout.txt` capture used). It is the production complaint's
//     shape and it is the one fixture here whose developed field is optimizer
//     output rather than a synthetic lattice.
//
// ---------------------------------------------------------------------------
// THERMAL PROTOCOL (113). Cycle counts, contraction factors, aggregate counts,
// nnz, memory bytes and residual histories are DETERMINISTIC. Wall-clock is not;
// where it is the claim it is a median of interleaved repeats with the band.
//
// NOTE ON THE COMPARISON'S FAIRNESS, stated up front: unlike 131, the fine level
// here uses the PRODUCTION threaded matrix-free apply, so fine-level work is on
// the same footing as the geometric baseline. The setup's aggregation, Galerkin
// and coarse-level kernels are still single-threaded prototype code.
//
// BUILD (standalone; the library must be built Release first):
//   cmake -S core -B core/build -DCMAKE_BUILD_TYPE=Release
//   cmake --build core/build --target topopt -j8
//   c++ -std=c++17 -O2 -I core/include -I core/src/fea \
//       core/tests/harness/amg_lean_probe.cpp core/build/libtopopt.a -o amg_lean_probe
// RUN: ./amg_lean_probe <mode>
//   modes: verify | correctness | memory | memsweep | nullspace | coarsening |
//          stagnation | developed | ultradilute | determinism | all

#include <algorithm>
#include <array>
#include <chrono>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <limits>
#include <string>
#include <vector>

#include <sys/resource.h>
#include <mach/mach.h>

#include "topopt/coarsen.hpp"
#include "topopt/fea.hpp"
#include "topopt/simp.hpp"
#include "topopt/voxel.hpp"

#include "fea_matfree.hpp"

#include "amg_lean.hpp"

using namespace topopt;

namespace {

constexpr double kE0 = 3500.0;
constexpr double kNu = 0.33;
constexpr double kH = 1.0;
constexpr int kSimpP = 3;
constexpr double kRhoMin = 1e-3;

double now_s() {
  using clock = std::chrono::steady_clock;
  return std::chrono::duration<double>(clock::now().time_since_epoch()).count();
}

// --- process memory, hard numbers -----------------------------------------
double peak_rss_mb() {
  struct rusage ru;
  getrusage(RUSAGE_SELF, &ru);
  return static_cast<double>(ru.ru_maxrss) / (1024.0 * 1024.0);  // bytes on macOS
}
double current_rss_mb() {
  mach_task_basic_info info;
  mach_msg_type_number_t count = MACH_TASK_BASIC_INFO_COUNT;
  if (task_info(mach_task_self(), MACH_TASK_BASIC_INFO,
                reinterpret_cast<task_info_t>(&info), &count) != KERN_SUCCESS)
    return 0.0;
  return static_cast<double>(info.resident_size) / (1024.0 * 1024.0);
}

// ---------------------------------------------------------------------------
// FIXTURES — the 131 family (rule copied verbatim from amg_probe.cpp so the
// Phase-0 tables are directly comparable; that file is NOT edited).
// ---------------------------------------------------------------------------
struct Fixture {
  std::string name;
  int ex = 0, ey = 0, ez = 0;
  double occ = 1.0;
  double hole = 0.0;
  int hole_axis = 2;
  double rho = 0.5;
  int pattern = 0;  // 0 = uniform (iteration 0), 1 = synthetic lattice (131 §2d)
};

struct System {
  VoxelGrid grid;
  std::vector<double> youngs;
  std::vector<DirichletBC> bcs;
  std::vector<NodalLoad> loads;
  long long nsolid = 0, nbore = 0, nempty = 0;
  double uniform_E = 0.0;
};

System build_system(const Fixture& f) {
  System S;
  VoxelGrid& g = S.grid;
  g.nx = f.ex;
  g.ny = f.ey;
  g.nz = f.ez;
  g.spacing = kH;
  g.origin = Vec3{0.0, 0.0, 0.0};
  g.tags.assign(static_cast<std::size_t>(f.ex) * f.ey * f.ez, VoxelTag::Empty);

  const int px = std::max(1, static_cast<int>(std::lround(f.occ * f.ex)));
  const int py = std::max(1, static_cast<int>(std::lround(f.occ * f.ey)));
  const int x0 = (f.ex - px) / 2, x1 = x0 + px;
  const int y0 = (f.ey - py) / 2, y1 = y0 + py;
  const double cx = 0.5 * f.ex, cy = 0.5 * f.ey, cz = 0.5 * f.ez;
  const double r = f.hole * 0.5 * std::min(f.ex, f.ey);
  const double r2 = r * r;

  for (int k = 0; k < f.ez; ++k)
    for (int j = 0; j < f.ey; ++j)
      for (int i = 0; i < f.ex; ++i) {
        const bool in_part = (i >= x0 && i < x1 && j >= y0 && j < y1);
        if (!in_part) {
          ++S.nempty;
          continue;
        }
        bool in_bore = false;
        if (r > 0.0) {
          const double vx = i + 0.5, vy = j + 0.5, vz = k + 0.5;
          double d2 = 0.0;
          if (f.hole_axis == 2)
            d2 = (vx - cx) * (vx - cx) + (vy - cy) * (vy - cy);
          else if (f.hole_axis == 1)
            d2 = (vx - cx) * (vx - cx) + (vz - cz) * (vz - cz);
          else
            d2 = (vy - cy) * (vy - cy) + (vz - cz) * (vz - cz);
          in_bore = (d2 <= r2);
        }
        if (in_bore) {
          ++S.nbore;
          continue;
        }
        g.set_tag(i, j, k, VoxelTag::Interior);
        ++S.nsolid;
      }

  S.uniform_E = std::pow(f.rho, kSimpP) * kE0;
  S.youngs.assign(g.tags.size(), S.uniform_E);
  if (f.pattern == 1) {
    for (int k = 0; k < f.ez; ++k)
      for (int j = 0; j < f.ey; ++j)
        for (int i = 0; i < f.ex; ++i) {
          if (g.tag(i, j, k) == VoxelTag::Empty) continue;
          const bool col = ((i - x0) % 8 < 2) && ((j - y0) % 8 < 2);
          const bool tie = (k % 16) < 2;
          const double rr = (col || tie) ? 1.0 : 0.02;
          S.youngs[g.index(i, j, k)] = std::pow(rr, kSimpP) * kE0;
        }
  }

  const int nn = fea_node_count(g);
  std::vector<char> touched(static_cast<std::size_t>(nn), 0);
  for (int k = 0; k < f.ez; ++k)
    for (int j = 0; j < f.ey; ++j)
      for (int i = 0; i < f.ex; ++i) {
        if (g.tag(i, j, k) == VoxelTag::Empty) continue;
        const std::array<int, 8> en = fea_element_nodes(g, i, j, k);
        for (int e : en) touched[static_cast<std::size_t>(e)] = 1;
      }
  for (int b = y0; b <= y1; ++b)
    for (int a = x0; a <= x1; ++a) {
      const int nd = fea_node_index(g, a, b, 0);
      if (!touched[static_cast<std::size_t>(nd)]) continue;
      S.bcs.push_back({nd, 0, 0.0});
      S.bcs.push_back({nd, 1, 0.0});
      S.bcs.push_back({nd, 2, 0.0});
    }
  std::vector<int> top;
  for (int b = y0; b <= y1; ++b)
    for (int a = x0; a <= x1; ++a) {
      const int nd = fea_node_index(g, a, b, f.ez);
      if (touched[static_cast<std::size_t>(nd)]) top.push_back(nd);
    }
  const double total_fx = 100.0;
  if (!top.empty()) {
    const double per = total_fx / static_cast<double>(top.size());
    for (int nd : top) S.loads.push_back({nd, 0, per});
  }
  return S;
}

// ---------------------------------------------------------------------------
// THE SHARED ULTRA-DILUTE FIXTURE — handoff 134 (ACTIVE DOMAIN Phase 0) §1a/§2,
// `active_domain_probe.cpp:dilute_box(48,32,48, arm=24, span=24, ny=6, t=6,
// h=1.0, tip=30.0)`. Reproduced here by the same rule; the committed capture it
// matches is `docs/handoffs/evidence/134/ultradilute_stdout.txt`
// ("box 48x32x48 = 73728 elements, part 1512 voxels (2.05% fill, 48.8x)").
// ---------------------------------------------------------------------------
System build_ultradilute() {
  const int bx = 48, by = 32, bz = 48;
  const int arm = 24, span = 24, ny = 6, t = 6;
  System S;
  VoxelGrid& g = S.grid;
  g.nx = bx;
  g.ny = by;
  g.nz = bz;
  g.spacing = 1.0;
  g.origin = Vec3{0.0, 0.0, 0.0};
  g.tags.assign(static_cast<std::size_t>(bx) * by * bz, VoxelTag::Interior);
  long long part = 0;
  for (int k = 0; k < arm && k < bz; ++k)
    for (int j = 0; j < ny && j < by; ++j)
      for (int i = 0; i < span && i < bx; ++i)
        if (i < t || k < t) {
          g.set_tag(i, j, k, VoxelTag::Surface);
          ++part;
        }
  for (int j = 0; j < ny && j < by; ++j)
    for (int i = 0; i < t && i < bx; ++i) g.set_tag(i, j, arm - 1, VoxelTag::Fixture);
  for (int b = 0; b <= ny && b <= by; ++b)
    for (int a = 0; a <= t && a <= bx; ++a) {
      const int node = fea_node_index(g, a, b, arm);
      S.bcs.push_back({node, 0, 0.0});
      S.bcs.push_back({node, 1, 0.0});
      S.bcs.push_back({node, 2, 0.0});
    }
  for (int k = 0; k < t && k < bz; ++k)
    for (int j = 0; j < ny && j < by; ++j) g.set_tag(span - 1, j, k, VoxelTag::Load);
  S.loads = traction_loads(g, VoxelTag::Load, Vec3{0.0, 0.0, -30.0});
  S.nsolid = static_cast<long long>(g.solid_count());
  S.nempty = 0;
  S.nbore = part;  // reused slot: part voxel count, printed by the caller
  S.uniform_E = kE0;
  S.youngs.assign(g.tags.size(), kE0);
  return S;
}

// Run the AD Phase-0 OC recipe and return the DEVELOPED physical density field
// (rung vf 0.26, part-relative; 2.5 mm physical filter; `iters` steps).
std::vector<double> develop_ultradilute(const System& S, long long part_voxels,
                                        int iters, int* cg_last) {
  SimpParams params;
  params.youngs_modulus = kE0;
  params.poisson = kNu;
  params.penalty = 3.0;
  params.density_min = kRhoMin;
  const double vf =
      0.26 * static_cast<double>(part_voxels) / static_cast<double>(S.grid.solid_count());
  const DensityFilter f =
      make_density_filter(S.grid, physical_filter_radius(2.5, S.grid.spacing));
  std::vector<double> x = simp_uniform_density(S.grid, vf);
  std::vector<double> xp;
  for (int it = 0; it < iters; ++it) {
    xp = f.filter_density(x);
    const SimpCompliance c =
        simp_compliance(S.grid, params, xp, S.bcs, S.loads, 1e-8, 0, nullptr,
                        nullptr, SolverKind::MultigridCG_Matfree);
    if (cg_last) *cg_last = c.cg.iterations;
    x = oc_update(S.grid, f, x, c.dcompliance, vf, 0.2, kRhoMin);
  }
  return f.filter_density(x);
}

// ---------------------------------------------------------------------------
// Baselines — the PRODUCTION entry points.
// ---------------------------------------------------------------------------
struct GeoResult {
  bool ran = false, used_mg = false, hier_built = false;
  int mg_levels = 0, cycles = 0, iterations = 0;
  double residual = 0.0, seconds = 0.0;
  std::string error;
};

GeoResult geometric_baseline(const System& S, double tol, int max_it) {
  GeoResult g;
  CgInfo info;
  // 127's per-run stagnation latch is thread-local and STICKY; a harness that
  // solves many fixtures in one process is not "a run" (131 §6f).
  fea_matfree_reset_mg_stagnation_latch();
  const double t0 = now_s();
  try {
    fea_solve_mgcg_matfree(S.grid, S.youngs, kNu, S.bcs, S.loads, tol, max_it, &info);
    g.ran = true;
  } catch (const std::exception& e) {
    g.error = e.what();
  }
  g.seconds = now_s() - t0;
  g.used_mg = info.used_multigrid;
  g.hier_built = info.hier_built;
  g.mg_levels = info.mg_levels;
  g.cycles = info.mg_cycles_attempted;
  g.iterations = info.iterations;
  g.residual = info.residual;
  return g;
}

GeoResult jacobi_baseline(const System& S, double tol, int max_it) {
  GeoResult g;
  CgInfo info;
  const double t0 = now_s();
  try {
    fea_solve_cg_matfree(S.grid, S.youngs, kNu, S.bcs, S.loads, tol, max_it, &info);
    g.ran = true;
  } catch (const std::exception& e) {
    g.error = e.what();
  }
  g.seconds = now_s() - t0;
  g.iterations = info.iterations;
  g.residual = info.residual;
  return g;
}

// The production geometric matrix-free hierarchy's stored footprint — the SAME
// estimator 131 §6c used to state 88.9 MB. This is B1's baseline.
double geo_hierarchy_mb(const System& S) {
  const std::size_t nnz = fea_matfree_mgcg_assembled_operator_nonzeros(
      S.grid, S.uniform_E, kNu, S.bcs, S.loads);
  return static_cast<double>(nnz) * 12.0 / (1024.0 * 1024.0);
}

// ---------------------------------------------------------------------------
// Rigid-body near-nullspace on the reduced system (same construction as 131).
// ---------------------------------------------------------------------------
std::vector<double> rigid_body_modes(const System& S,
                                     const fea_detail::MatfreeReduced& m) {
  const int ng = m.ng;
  const int nxp = S.grid.nx + 1, nyp = S.grid.ny + 1;
  auto coords = [&](int gnode, double& x, double& y, double& z) {
    const int a = gnode % nxp;
    const int b = (gnode / nxp) % nyp;
    const int c = gnode / (nxp * nyp);
    x = a * S.grid.spacing;
    y = b * S.grid.spacing;
    z = c * S.grid.spacing;
  };
  double sx = 0, sy = 0, sz = 0;
  for (int gi = 0; gi < ng; ++gi) {
    double x, y, z;
    coords(m.kept_global[static_cast<std::size_t>(gi)] / 3, x, y, z);
    sx += x;
    sy += y;
    sz += z;
  }
  const double inv = 1.0 / static_cast<double>(ng);
  const double cx = sx * inv, cy = sy * inv, cz = sz * inv;
  double L = 0.0;
  for (int gi = 0; gi < ng; ++gi) {
    double x, y, z;
    coords(m.kept_global[static_cast<std::size_t>(gi)] / 3, x, y, z);
    L = std::max(L, std::sqrt((x - cx) * (x - cx) + (y - cy) * (y - cy) +
                              (z - cz) * (z - cz)));
  }
  if (L <= 0.0) L = 1.0;
  std::vector<double> B(static_cast<std::size_t>(ng) * 6, 0.0);
  for (int gi = 0; gi < ng; ++gi) {
    const int gd = m.kept_global[static_cast<std::size_t>(gi)];
    const int comp = gd % 3;
    double x, y, z;
    coords(gd / 3, x, y, z);
    const double X = (x - cx) / L, Y = (y - cy) / L, Z = (z - cz) / L;
    double* row = &B[static_cast<std::size_t>(gi) * 6];
    row[comp] = 1.0;
    if (comp == 1) row[3] = -Z;
    if (comp == 2) row[3] = Y;
    if (comp == 0) row[4] = Z;
    if (comp == 2) row[4] = -X;
    if (comp == 0) row[5] = -Y;
    if (comp == 1) row[5] = X;
  }
  return B;
}

// ---------------------------------------------------------------------------
// Reporting
// ---------------------------------------------------------------------------
struct Contraction {
  double overall = 0.0, sustained = 0.0, worst = 0.0;
};

Contraction contraction_of(const std::vector<double>& h) {
  Contraction c;
  const int K = static_cast<int>(h.size()) - 1;
  if (K <= 0) return c;
  c.overall = std::pow(h.back() / h.front(), 1.0 / K);
  const int lo = std::max(1, K / 2);
  double acc = 0.0;
  int n = 0;
  for (int k = lo; k <= K; ++k) {
    if (h[static_cast<std::size_t>(k - 1)] <= 0.0) continue;
    const double ratio = h[static_cast<std::size_t>(k)] / h[static_cast<std::size_t>(k - 1)];
    acc += std::log(ratio);
    c.worst = std::max(c.worst, ratio);
    ++n;
  }
  c.sustained = n > 0 ? std::exp(acc / n) : c.overall;
  return c;
}

void print_hierarchy(const amglean::LeanHierarchy& H) {
  std::printf("    level      n        nnz    nnz/row   ratio   note\n");
  std::printf("    %5d %8d %10s %8.1f %7s   MATRIX-FREE (no A stored)\n", 0,
              H.fine.ng, "-", H.fine_nnz_per_row, "-");
  double prev = static_cast<double>(H.fine.ng);
  for (int l = 0; l < H.coarse.levels(); ++l) {
    const amg::Level& L = H.coarse.lv[static_cast<std::size_t>(l)];
    std::printf("    %5d %8d %10lld %8.1f %7.2f\n", l + 1, L.A.nrow,
                static_cast<long long>(L.A.nnz()),
                L.A.nrow ? static_cast<double>(L.A.nnz()) / L.A.nrow : 0.0,
                L.A.nrow ? prev / L.A.nrow : 0.0);
    prev = static_cast<double>(L.A.nrow);
  }
  std::printf(
      "    coarsest n=%d dense-LDL^T=%s | P0 %.1f MB + coarse ops %.1f MB + "
      "bookkeeping %.1f MB = AMG ADDS %.1f MB\n",
      H.coarse.coarse_n, H.coarse.coarse_dense_ok ? "yes" : "NO",
      H.P0.bytes() / (1024.0 * 1024.0),
      H.coarse.total_bytes / (1024.0 * 1024.0),
      H.fine.amg_bytes() / (1024.0 * 1024.0), H.amg_bytes / (1024.0 * 1024.0));
  for (const std::string& s : H.level_notes)
    std::printf("    NOTE: %s\n", s.c_str());
}

struct LeanRun {
  amglean::LeanHierarchy H;
  amg::SolveStats stat, pcg;
  double setup_s = 0.0, stat_s = 0.0, pcg_s = 0.0;
  double peak_rss_mb = 0.0;
};

LeanRun run_lean(const fea_detail::MatfreeReduced& m,
                 const std::vector<double>& B, const amglean::LeanOptions& o,
                 double tol, int max_cycles, bool do_stationary) {
  LeanRun r;
  const double rss0 = current_rss_mb();
  double t0 = now_s();
  r.H = amglean::lean_setup(m, B, 6, o, now_s);
  r.setup_s = now_s() - t0;
  r.peak_rss_mb = current_rss_mb() - rss0;
  if (do_stationary) {
    t0 = now_s();
    r.stat = amglean::lean_stationary(r.H, m.rg, tol, std::min(max_cycles, 60), o);
    r.stat_s = now_s() - t0;
  }
  t0 = now_s();
  r.pcg = amglean::lean_pcg(r.H, m.rg, tol, max_cycles, o);
  r.pcg_s = now_s() - t0;
  return r;
}

bool bit_identical(const std::vector<double>& a, const std::vector<double>& b) {
  if (a.size() != b.size()) return false;
  return std::memcmp(a.data(), b.data(), a.size() * sizeof(double)) == 0;
}

// Two independent setups + two independent solves, memcmp'd. B4.
bool determinism_check(const fea_detail::MatfreeReduced& m,
                       const std::vector<double>& B,
                       const amglean::LeanOptions& o, double tol, int cycles,
                       std::string* detail) {
  amglean::LeanHierarchy H1 = amglean::lean_setup(m, B, 6, o, now_s);
  amglean::LeanHierarchy H2 = amglean::lean_setup(m, B, 6, o, now_s);
  bool same = H1.levels() == H2.levels() && H1.P0.nnz() == H2.P0.nnz() &&
              std::memcmp(H1.P0.val.data(), H2.P0.val.data(),
                          H1.P0.val.size() * sizeof(double)) == 0 &&
              std::memcmp(H1.P0.col.data(), H2.P0.col.data(),
                          H1.P0.col.size() * sizeof(int)) == 0;
  for (int l = 0; same && l < H1.coarse.levels(); ++l) {
    const amg::Level& a = H1.coarse.lv[static_cast<std::size_t>(l)];
    const amg::Level& b = H2.coarse.lv[static_cast<std::size_t>(l)];
    same = a.A.nrow == b.A.nrow && a.A.nnz() == b.A.nnz() &&
           a.P.nnz() == b.P.nnz() &&
           std::memcmp(a.A.val.data(), b.A.val.data(),
                       a.A.val.size() * sizeof(double)) == 0 &&
           std::memcmp(a.A.col.data(), b.A.col.data(),
                       a.A.col.size() * sizeof(int)) == 0 &&
           std::memcmp(a.P.val.data(), b.P.val.data(),
                       a.P.val.size() * sizeof(double)) == 0;
  }
  const bool ops = same;
  const amg::SolveStats s1 = amglean::lean_pcg(H1, m.rg, tol, cycles, o);
  const amg::SolveStats s2 = amglean::lean_pcg(H2, m.rg, tol, cycles, o);
  const bool hist = bit_identical(s1.history, s2.history) &&
                    bit_identical(s1.solution, s2.solution);
  if (detail)
    *detail = std::string("operators ") + (ops ? "IDENTICAL" : "DIFFER") +
              ", residual history + solution " + (hist ? "IDENTICAL" : "DIFFER");
  return ops && hist;
}

fea_detail::MatfreeReduced reduce(const System& S) {
  CgInfo dummy;
  return fea_detail::mf_build_reduced(S.grid, 0.0, kNu, S.bcs, S.loads, &S.youngs,
                                      "amg_lean_probe", &dummy);
}

// ---------------------------------------------------------------------------
// One full fixture report.
// ---------------------------------------------------------------------------
void report_fixture(const std::string& label, const System& S, double tol,
                    const amglean::LeanOptions& o, bool with_stationary,
                    bool with_determinism, bool with_jacobi) {
  std::printf("\n== %s  %dx%dx%d | solid=%lld bore=%lld empty=%lld\n", label.c_str(),
              S.grid.nx, S.grid.ny, S.grid.nz, S.nsolid, S.nbore, S.nempty);
  const double geo_mb = geo_hierarchy_mb(S);

  const GeoResult g = geometric_baseline(S, 1e-6, 20000);
  std::printf(
      "   GEOMETRIC: hier_built=%d used_mg=%d levels=%d mg_cycles=%d cg_iters=%d "
      "resid=%.2e  %.2fs%s\n",
      g.hier_built ? 1 : 0, g.used_mg ? 1 : 0, g.mg_levels, g.cycles, g.iterations,
      g.residual, g.seconds, g.error.empty() ? "" : (" ERR: " + g.error).c_str());
  if (!g.used_mg)
    std::printf("      -> geometric %s\n",
                g.hier_built ? "FELL BACK (STAGNATION: hierarchy built)"
                             : "REFUSED TO BUILD (build rejection)");
  if (with_jacobi) {
    const GeoResult j = jacobi_baseline(S, 1e-6, 60000);
    std::printf("   JACOBI-CG baseline: iters=%d  %.2fs\n", j.iterations, j.seconds);
  }

  const fea_detail::MatfreeReduced m = reduce(S);
  const std::vector<double> B = rigid_body_modes(S, m);
  std::printf("   reduced DOF = %d | production matfree hierarchy = %.1f MB "
              "(B1 baseline)\n",
              m.ng, geo_mb);

  const LeanRun r = run_lean(m, B, o, tol, 400, with_stationary);
  print_hierarchy(r.H);
  if (with_stationary) {
    const Contraction c = contraction_of(r.stat.history);
    std::printf(
        "   LEAN stationary V-cycle: cycles=%d converged=%s | overall=%.3f "
        "sustained=%.3f worst=%.3f\n",
        r.stat.cycles, r.stat.converged ? "yes" : "NO", c.overall, c.sustained,
        c.worst);
  }
  const double rho_eff =
      r.pcg.cycles > 0 ? std::pow(tol, 1.0 / r.pcg.cycles) : 0.0;
  std::printf(
      "   LEAN-PCG: cycles=%d converged=%s resid=%.2e rho_eff=%.3f | setup "
      "%.2fs (strength %.2f agg %.2f prolong %.2f galerkin %.2f coarse %.2f), "
      "solve %.2fs, %.3fs/cycle\n",
      r.pcg.cycles, r.pcg.converged ? "yes" : "NO", r.pcg.final_rel, rho_eff,
      r.setup_s, r.H.setup_strength_s, r.H.setup_agg_s, r.H.setup_prolong_s,
      r.H.setup_galerkin_s, r.H.setup_coarse_s, r.pcg_s,
      r.pcg.cycles ? r.pcg_s / r.pcg.cycles : 0.0);
  std::printf(
      "   MEMORY: AMG adds %.1f MB vs matfree baseline %.1f MB = %.2fx  [B1 bar "
      "<= 2.00x: %s] | RSS delta over setup %.1f MB, process peak %.1f MB\n",
      r.H.amg_bytes / (1024.0 * 1024.0), geo_mb,
      geo_mb > 0 ? (r.H.amg_bytes / (1024.0 * 1024.0)) / geo_mb : 0.0,
      geo_mb > 0 && (r.H.amg_bytes / (1024.0 * 1024.0)) / geo_mb <= 2.0 ? "PASS"
                                                                       : "FAIL",
      r.peak_rss_mb, peak_rss_mb());
  const double amg_total = r.setup_s + r.pcg_s;
  std::printf("   END-TO-END: geometric %.2fs vs lean AMG %.2fs = %.2fx  [B3 bar "
              ">= 1.00x: %s]\n",
              g.seconds, amg_total, amg_total > 0 ? g.seconds / amg_total : 0.0,
              amg_total > 0 && g.seconds / amg_total >= 1.0 ? "PASS" : "FAIL");
  if (with_determinism) {
    std::string d;
    const bool ok = determinism_check(m, B, o, tol, std::min(12, std::max(1, r.pcg.cycles)), &d);
    std::printf("   DETERMINISM (B4): %s — %s\n", ok ? "IDENTICAL" : "MISMATCH",
                d.c_str());
  }
}

// ---------------------------------------------------------------------------
// Modes
// ---------------------------------------------------------------------------
int mode_correctness() {
  std::printf("\n===== [CORRECTNESS] lean AMG solves the RIGHT system =====\n");
  Fixture f;
  f.name = "solid16";
  f.ex = f.ey = f.ez = 16;
  f.occ = 1.0;
  const System S = build_system(f);
  const fea_detail::MatfreeReduced m = reduce(S);
  const std::vector<double> B = rigid_body_modes(S, m);
  const double tol = 1e-10;

  CgInfo info;
  std::vector<double> uref;
  fea_solve_cg_matfree(S.grid, S.youngs, kNu, S.bcs, S.loads, tol, 40000, &info);
  // Reference on the REDUCED system, through the library's own matrix-free CG.
  std::vector<double> xref(static_cast<std::size_t>(m.ng), 0.0);
  int it = 0;
  double err = 0.0;
  bool conv = false;
  fea_detail::mf_cg_solve(m, tol, 40000, xref, it, err, conv, nullptr);
  std::printf("   reference matrix-free Jacobi-CG: iters=%d resid=%.2e converged=%s\n",
              it, err, conv ? "yes" : "no");

  for (int smoothP = 0; smoothP < 2; ++smoothP) {
    amglean::LeanOptions o;
    o.smooth_prolongator = smoothP != 0;
    const LeanRun r = run_lean(m, B, o, tol, 400, false);
    double mx = 0.0, mxr = 0.0;
    for (int i = 0; i < m.ng; ++i) {
      mx = std::max(mx, std::fabs(xref[static_cast<std::size_t>(i)]));
      mxr = std::max(mxr, std::fabs(r.pcg.solution[static_cast<std::size_t>(i)] -
                                    xref[static_cast<std::size_t>(i)]));
    }
    std::printf(
        "   P=%-10s LEAN-PCG cycles=%d resid=%.2e | max|u_ref|=%.6e "
        "max|u_lean-u_ref|=%.3e relative=%.3e  VERDICT: %s (bar <= 1e-8)\n",
        smoothP ? "smoothed" : "unsmoothed", r.pcg.cycles, r.pcg.final_rel, mx,
        mxr, mx > 0 ? mxr / mx : 0.0,
        (mx > 0 && mxr / mx <= 1e-8) ? "PASS" : "FAIL");
  }
  return 0;
}

// ---------------------------------------------------------------------------
// [VERIFY] the three NEW element-local kernels against an assembled reference.
//
// This is the gate that makes the rebuild trustworthy: the strength graph, the
// A*T product behind prolongator smoothing, and the Galerkin triple product are
// the only pieces that classically need A's rows, and this mode proves each one
// agrees with the assembled computation on the SAME system. A is obtained here
// by applying the production matrix-free operator to unit vectors — no separate
// assembler, so nothing can drift.
// ---------------------------------------------------------------------------
int mode_verify() {
  std::printf(
      "\n===== [VERIFY] element-local kernels vs an assembled reference =====\n");
  Fixture f;
  f.name = "solid10";
  f.ex = f.ey = f.ez = 10;
  f.occ = 1.0;
  const System S = build_system(f);
  const fea_detail::MatfreeReduced m = reduce(S);
  const std::vector<double> B = rigid_body_modes(S, m);
  std::printf("   fixture %dx%dx%d, reduced DOF = %d\n", f.ex, f.ey, f.ez, m.ng);

  // Reference A, column by column, from the production matrix-free apply.
  amg::Csr A;
  A.nrow = A.ncol = m.ng;
  {
    std::vector<std::vector<std::pair<int, double>>> rows(
        static_cast<std::size_t>(m.ng));
    std::vector<double> e(static_cast<std::size_t>(m.ng), 0.0);
    std::vector<double> y(static_cast<std::size_t>(m.ng), 0.0);
    for (int j = 0; j < m.ng; ++j) {
      e[static_cast<std::size_t>(j)] = 1.0;
      m.apply_kgg_raw(e.data(), y.data());
      e[static_cast<std::size_t>(j)] = 0.0;
      for (int i = 0; i < m.ng; ++i)
        if (y[static_cast<std::size_t>(i)] != 0.0)
          rows[static_cast<std::size_t>(i)].emplace_back(j, y[static_cast<std::size_t>(i)]);
    }
    A.rowptr.assign(static_cast<std::size_t>(m.ng) + 1, 0);
    for (int i = 0; i < m.ng; ++i)
      A.rowptr[i + 1] = A.rowptr[i] + static_cast<amg::i64>(rows[static_cast<std::size_t>(i)].size());
    A.col.resize(static_cast<std::size_t>(A.rowptr[m.ng]));
    A.val.resize(static_cast<std::size_t>(A.rowptr[m.ng]));
    amg::i64 w = 0;
    for (int i = 0; i < m.ng; ++i)
      for (const auto& p : rows[static_cast<std::size_t>(i)]) {
        A.col[static_cast<std::size_t>(w)] = p.first;
        A.val[static_cast<std::size_t>(w)] = p.second;
        ++w;
      }
  }
  std::printf("   reference A built from %d matrix-free applies: nnz=%lld (%.1f/row)\n",
              m.ng, static_cast<long long>(A.nnz()),
              static_cast<double>(A.nnz()) / m.ng);

  amglean::FineMF F = amglean::build_fine(m);
  const double theta = 0.08;
  double npr = 0.0;
  const amg::NodeGraph g_lean = amglean::fine_strength_graph(F, theta, &npr);
  const amg::NodeGraph g_ref =
      amg::build_strength_graph(A, F.dof2node, F.nnodes, theta);
  const bool graph_same =
      g_lean.rowptr == g_ref.rowptr && g_lean.col == g_ref.col;
  std::printf("   [1] strength graph      : %s (%lld strong edges; nnz/row lean=%.1f ref=%.1f)\n",
              graph_same ? "IDENTICAL" : "DIFFER",
              static_cast<long long>(g_ref.rowptr.back()), npr,
              static_cast<double>(A.nnz()) / m.ng);

  std::vector<amg::i64> diagpos;
  std::vector<double> invd;
  amg::fill_diag(A, diagpos, invd);
  const double lam_ref = amg::gershgorin_dinva(A, diagpos);
  std::printf("   [2] Gershgorin lambda   : lean=%.10g ref=%.10g rel=%.2e %s\n",
              F.lam_dinva, lam_ref, std::fabs(F.lam_dinva - lam_ref) / lam_ref,
              std::fabs(F.lam_dinva - lam_ref) / lam_ref <= 1e-12 ? "PASS" : "FAIL");

  std::vector<int> agg;
  const int naggs = amg::aggregate(g_ref, agg);
  std::vector<double> Bc;
  std::vector<int> cagg;
  int ncoarse = 0;
  amg::Csr T = amg::build_tentative(agg, naggs, F.dof2node, m.ng, 6, B, Bc,
                                    ncoarse, cagg, 1e-10);
  std::printf("       aggregates=%d coarse DOF=%d\n", naggs, ncoarse);

  // [3] A*T
  {
    const amg::Csr AT_lean = amglean::fine_apply_to(F, T);
    amg::Csr AT_ref;
    AT_ref.nrow = A.nrow;
    AT_ref.ncol = T.ncol;
    AT_ref.rowptr.assign(static_cast<std::size_t>(A.nrow) + 1, 0);
    {
      amg::RowAccum acc;
      acc.resize(T.ncol);
      for (int i = 0; i < A.nrow; ++i) {
        acc.begin();
        for (amg::i64 p = A.rowptr[i]; p < A.rowptr[i + 1]; ++p)
          for (amg::i64 q = T.rowptr[A.col[p]]; q < T.rowptr[A.col[p] + 1]; ++q)
            acc.add(T.col[q], A.val[p] * T.val[q]);
        acc.flush(AT_ref.col, AT_ref.val);
        AT_ref.rowptr[i + 1] = static_cast<amg::i64>(AT_ref.col.size());
      }
    }
    double mx = 0.0, sc = 0.0;
    const bool pat = AT_lean.rowptr == AT_ref.rowptr && AT_lean.col == AT_ref.col;
    if (pat)
      for (std::size_t p = 0; p < AT_ref.val.size(); ++p) {
        mx = std::max(mx, std::fabs(AT_lean.val[p] - AT_ref.val[p]));
        sc = std::max(sc, std::fabs(AT_ref.val[p]));
      }
    std::printf("   [3] A*T (smoothing)     : pattern %s, max|diff|=%.3e relative=%.3e %s\n",
                pat ? "IDENTICAL" : "DIFFERS", mx, sc > 0 ? mx / sc : 0.0,
                (pat && sc > 0 && mx / sc <= 1e-12) ? "PASS" : "FAIL");
  }

  // [4] Galerkin, both prolongators
  for (int sp = 0; sp < 2; ++sp) {
    amg::Csr P = sp ? amglean::fine_smooth_prolongator(F, T, (4.0 / 3.0) / F.lam_dinva)
                    : T;
    amg::Csr Pt = amg::transpose(P);
    const amg::Csr Ac_ref = amg::galerkin(A, P, Pt);
    std::vector<int> cbase(static_cast<std::size_t>(naggs) + 1, 0);
    {
      std::vector<int> cnt(static_cast<std::size_t>(naggs), 0);
      for (int I = 0; I < ncoarse; ++I) cnt[static_cast<std::size_t>(cagg[static_cast<std::size_t>(I)])]++;
      for (int a = 0; a < naggs; ++a) cbase[a + 1] = cbase[a] + cnt[static_cast<std::size_t>(a)];
    }
    const amg::Csr Ac_lean = amglean::fine_galerkin(F, P, cagg, naggs, cbase);
    // The lean pattern is a structural SUPERSET (it emits the full aggregate
    // block, including entries that cancel to exactly zero); compare by value.
    double mx = 0.0, sc = 0.0;
    for (int i = 0; i < Ac_ref.nrow; ++i) {
      amg::i64 q = Ac_lean.rowptr[i];
      for (amg::i64 p = Ac_ref.rowptr[i]; p < Ac_ref.rowptr[i + 1]; ++p) {
        while (q < Ac_lean.rowptr[i + 1] && Ac_lean.col[q] < Ac_ref.col[p]) {
          mx = std::max(mx, std::fabs(Ac_lean.val[q]));
          ++q;
        }
        const double lv = (q < Ac_lean.rowptr[i + 1] && Ac_lean.col[q] == Ac_ref.col[p])
                              ? Ac_lean.val[q++]
                              : 0.0;
        mx = std::max(mx, std::fabs(lv - Ac_ref.val[p]));
        sc = std::max(sc, std::fabs(Ac_ref.val[p]));
      }
      while (q < Ac_lean.rowptr[i + 1]) {
        mx = std::max(mx, std::fabs(Ac_lean.val[q]));
        ++q;
      }
    }
    std::printf(
        "   [4] Galerkin P=%-10s: lean nnz=%lld ref nnz=%lld | max|diff|=%.3e "
        "relative=%.3e %s\n",
        sp ? "smoothed" : "unsmoothed", static_cast<long long>(Ac_lean.nnz()),
        static_cast<long long>(Ac_ref.nnz()), mx, sc > 0 ? mx / sc : 0.0,
        (sc > 0 && mx / sc <= 1e-12) ? "PASS" : "FAIL");
  }
  return 0;
}

int mode_memory() {
  std::printf(
      "\n===== [MEMORY] B1: peak AMG memory <= 2.0x the matfree baseline =====\n"
      "  Baseline = what the PRODUCTION geometric matrix-free hierarchy stores\n"
      "  (fea_matfree_mgcg_assembled_operator_nonzeros x 12 bytes — the same\n"
      "  estimator 131 §6c used for its 88.9 MB figure). Stated BEFORE any AMG\n"
      "  number, as the bar requires.\n\n");
  const std::vector<Fixture> fx = {
      {"stagnation192x112x128", 192, 112, 128, 0.40, 0.40, 2, 0.5, 0},
      {"stagnation100x96x96", 100, 96, 96, 0.40, 0.40, 2, 0.5, 0},
      {"healthy48", 48, 48, 48, 1.0, 0.0, 2, 0.5, 0},
  };
  std::printf("  %-24s %10s %14s %14s %14s %8s %s\n", "fixture", "red.DOF",
              "matfree base", "AMG unsmoothed", "AMG smoothed", "ratio", "B1");
  for (const Fixture& f : fx) {
    const System S = build_system(f);
    const double base = geo_hierarchy_mb(S);
    const fea_detail::MatfreeReduced m = reduce(S);
    const std::vector<double> B = rigid_body_modes(S, m);
    double mb[2] = {0.0, 0.0};
    for (int sp = 0; sp < 2; ++sp) {
      amglean::LeanOptions o;
      o.smooth_prolongator = sp != 0;
      const amglean::LeanHierarchy H = amglean::lean_setup(m, B, 6, o, now_s);
      mb[sp] = H.amg_bytes / (1024.0 * 1024.0);
    }
    std::printf("  %-24s %10d %11.1f MB %11.1f MB %11.1f MB %7.2fx %s\n",
                f.name.c_str(), m.ng, base, mb[0], mb[1],
                base > 0 ? mb[0] / base : 0.0,
                (base > 0 && mb[0] / base <= 2.0) ? "PASS" : "FAIL");
    std::fflush(stdout);
  }
  std::printf(
      "\n  (ratio and B1 verdict are for the UNSMOOTHED variant — the default\n"
      "   here, and the one 131 §6d identified as the matrix-free-native shape.)\n");
  return 0;
}

// B1 is a MEMORY bar, so if it fails the next question is whether any stated
// coarsening-control setting reaches it. This sweeps the knobs on the two R1
// fixtures and reports memory AND cycles together, so a memory win bought with a
// convergence loss cannot hide.
int mode_memsweep() {
  std::printf(
      "\n===== [MEMSWEEP] can coarsening control reach the B1 bar (<= 2.0x)? "
      "=====\n"
      "  Unsmoothed P throughout (the matrix-free-native variant). Memory is the\n"
      "  hierarchy AMG ADDS; the baseline is the production matfree hierarchy.\n");
  const std::vector<Fixture> fx = {
      {"stagnation192x112x128", 192, 112, 128, 0.40, 0.40, 2, 0.5, 0},
      {"stagnation100x96x96", 100, 96, 96, 0.40, 0.40, 2, 0.5, 0},
      {"LATTICE192x112x128 (developed)", 192, 112, 128, 0.40, 0.40, 2, 0.5, 1},
  };
  const double thetas[] = {0.02, 0.04, 0.08};  // 0.16+ is measured on the 48^3 lattice in `coarsening` — it degenerates there and costs a 75 s solve, so it is not repeated at real extents
  for (const Fixture& f : fx) {
    const System S = build_system(f);
    const double base = geo_hierarchy_mb(S);
    const fea_detail::MatfreeReduced m = reduce(S);
    const std::vector<double> B = rigid_body_modes(S, m);
    std::printf("\n  %s | reduced DOF %d | matfree baseline %.1f MB\n",
                f.name.c_str(), m.ng, base);
    std::printf("  %8s %8s %10s %10s %10s %9s %8s %8s %7s\n", "theta", "levels",
                "P0 MB", "coarse MB", "book MB", "AMG MB", "vs base", "cycles",
                "setup s");
    for (double th : thetas) {
      amglean::LeanOptions o;
      o.strength_theta = th;
      const double t0 = now_s();
      amglean::LeanHierarchy H = amglean::lean_setup(m, B, 6, o, now_s);
      const double su = now_s() - t0;
      const amg::SolveStats st = amglean::lean_pcg(H, m.rg, 1e-6, 400, o);
      const double mb = H.amg_bytes / (1024.0 * 1024.0);
      std::printf("  %8.2f %8d %10.1f %10.1f %10.1f %9.1f %7.2fx %8d%s %7.1f\n", th,
                  H.levels(), H.P0.bytes() / (1024.0 * 1024.0),
                  H.coarse.total_bytes / (1024.0 * 1024.0),
                  H.fine.amg_bytes() / (1024.0 * 1024.0), mb,
                  base > 0 ? mb / base : 0.0, st.cycles,
                  st.converged ? " " : "*", su);
      std::fflush(stdout);
    }
  }
  std::printf("\n  (* = did not converge within 400 cycles)\n");
  std::printf(
      "  'book MB' is the AMG-side bookkeeping (node->element incidence, the\n"
      "  reduced<->node maps and three ng-length work vectors). The production\n"
      "  solver pays its own equivalents; this column is charged to AMG anyway,\n"
      "  which is the conservative choice.\n");
  return 0;
}

// The near-nullspace size is the OTHER memory lever, and it is the one that
// trades directly against 131's central structural claim (rigid ROTATIONS are
// what a coarse grid loses on a thin ligament). k=6 is translations+rotations;
// k=3 is translations only, which makes P0 half as wide and every coarse
// operator ~4x smaller. This measures what that costs in cycles.
int mode_nullspace() {
  std::printf(
      "\n===== [B1 LEVERS] near-nullspace size x coarsening control, at REAL extents =====\n"
      "  The memory floor of an ALGEBRAIC hierarchy is P0: geometric MG's\n"
      "  prolongation is a stencil and costs nothing to store, AMG's must be\n"
      "  materialised. k sets its width.\n");
  const std::vector<Fixture> fx = {
      {"stagnation192x112x128", 192, 112, 128, 0.40, 0.40, 2, 0.5, 0},
      {"LATTICE192x112x128 (developed)", 192, 112, 128, 0.40, 0.40, 2, 0.5, 1},
      {"LATTICE solid_box_48 (developed)", 48, 48, 48, 1.0, 0.0, 2, 0.5, 1},
  };
  for (const Fixture& f : fx) {
    const System S = build_system(f);
    const double base = geo_hierarchy_mb(S);
    const fea_detail::MatfreeReduced m = reduce(S);
    const std::vector<double> B6 = rigid_body_modes(S, m);
    std::vector<double> B3(static_cast<std::size_t>(m.ng) * 3, 0.0);
    for (int i = 0; i < m.ng; ++i)
      for (int c = 0; c < 3; ++c)
        B3[static_cast<std::size_t>(i) * 3 + c] =
            B6[static_cast<std::size_t>(i) * 6 + c];
    std::printf("\n  %s | reduced DOF %d | matfree baseline %.1f MB\n",
                f.name.c_str(), m.ng, base);
    std::printf("  %4s %-14s %8s %10s %9s %8s %8s %8s %8s\n", "k", "control",
                "P0 MB", "coarse MB", "AMG MB", "vs base", "B1", "cycles",
                "setup s");
    for (int k : {6, 3})
      for (int tight = 0; tight < 2; ++tight) {
        amglean::LeanOptions o;
        if (tight) {
          o.min_coarsening_ratio = 4.0;
          o.max_nnz_per_row = 200.0;
          o.max_level_density = 0.02;
        }
        const double t0 = now_s();
        amglean::LeanHierarchy H =
            amglean::lean_setup(m, k == 6 ? B6 : B3, k, o, now_s);
        const double su = now_s() - t0;
        const amg::SolveStats st = amglean::lean_pcg(H, m.rg, 1e-6, 600, o);
        const double mb = H.amg_bytes / (1024.0 * 1024.0);
        std::printf("  %4d %-14s %8.1f %10.1f %9.1f %7.2fx %8s %8d%s %7.1f\n", k,
                    tight ? "TIGHT" : "default",
                    H.P0.bytes() / (1024.0 * 1024.0),
                    H.coarse.total_bytes / (1024.0 * 1024.0), mb,
                    base > 0 ? mb / base : 0.0,
                    (base > 0 && mb / base <= 2.0) ? "PASS" : "FAIL", st.cycles,
                    st.converged ? " " : "*", su);
        std::fflush(stdout);
      }
  }
  std::printf("\n  (* = did not converge within 600 cycles)\n");
  return 0;
}

int mode_stagnation() {
  std::printf(
      "\n===== [STAGNATION] B2 on the 131 R1 fixtures, ITERATION-0 field =====\n");
  const std::vector<Fixture> fx = {
      {"occ0.40+bore0.40 192x112x128", 192, 112, 128, 0.40, 0.40, 2, 0.5, 0},
      {"occ0.40+bore0.40 100x96x96", 100, 96, 96, 0.40, 0.40, 2, 0.5, 0},
  };
  amglean::LeanOptions o;
  for (const Fixture& f : fx) {
    const System S = build_system(f);
    report_fixture(f.name, S, 1e-6, o, true, true, true);
    std::fflush(stdout);
  }
  return 0;
}

int mode_developed() {
  std::printf(
      "\n===== [DEVELOPED] the 131 §2d fixtures — where a real run LIVES =====\n"
      "  Synthetic lattice field (131 §2d's rule verbatim): thin axial columns on\n"
      "  an 8-voxel pitch, 2 voxels thick, tie layer every 16 in z, rho=1.0 vs\n"
      "  0.02 => ~1.25e5 modulus contrast on sub-coarse-cell members.\n");
  const std::vector<Fixture> fx = {
      {"LATTICE occ0.40+bore0.40 192x112x128", 192, 112, 128, 0.40, 0.40, 2, 0.5, 1},
      {"LATTICE solid_box_48", 48, 48, 48, 1.0, 0.0, 2, 0.5, 1},
  };
  amglean::LeanOptions o;
  for (const Fixture& f : fx) {
    const System S = build_system(f);
    report_fixture(f.name, S, 1e-6, o, true, false, true);
    std::fflush(stdout);
  }
  return 0;
}

int mode_ultradilute(int iters) {
  std::printf(
      "\n===== [ULTRA-DILUTE] the shared ACTIVE-DOMAIN fixture (handoff 134 "
      "§1a/§2) =====\n");
  System S = build_ultradilute();
  const long long part = S.nbore;
  S.nbore = 0;
  std::printf(
      "  box 48x32x48 = %lld elements, part %lld voxels (%.2f%% fill, %.1fx "
      "dilution) — matches evidence/134/ultradilute_stdout.txt\n",
      S.nsolid, part, 100.0 * static_cast<double>(part) / static_cast<double>(S.nsolid),
      static_cast<double>(S.nsolid) / static_cast<double>(part));

  std::printf("  developing the field: %d OC iterations at part-relative rung "
              "vf 0.26, 2.5 mm filter, MultigridCG_Matfree, tol 1e-8 ...\n",
              iters);
  const double t0 = now_s();
  int cg_last = 0;
  const std::vector<double> rho = develop_ultradilute(S, part, iters, &cg_last);
  std::printf("  ... developed in %.1fs (last solve CG iters = %d)\n", now_s() - t0,
              cg_last);

  // Modulus field of the developed design: E = rho^p * E0 (SIMP).
  double gray = 0.0, solid_frac = 0.0;
  for (std::size_t i = 0; i < rho.size(); ++i) {
    if (S.grid.tags[i] == VoxelTag::Empty) continue;
    const double r = rho[i];
    if (r > 1.5 * kRhoMin && r < 0.3) gray += 1.0;
    if (r >= 0.3) solid_frac += 1.0;
    S.youngs[i] = std::max(std::pow(r, kSimpP) * kE0, 1e-9 * kE0);
  }
  std::printf("  developed field: %.2f%% of the domain above rho 0.3, %.2f%% gray "
              "(1.5*rho_min < rho < 0.3)\n",
              100.0 * solid_frac / static_cast<double>(S.nsolid),
              100.0 * gray / static_cast<double>(S.nsolid));
  S.uniform_E = kE0;  // for the baseline hierarchy estimator only

  amglean::LeanOptions o;
  report_fixture("ULTRA-DILUTE developed (OC 40)", S, 1e-6, o, true, true, true);
  return 0;
}

int mode_coarsening() {
  std::printf(
      "\n===== [COARSENING CONTROL] the 131 §2d disease: cured or incurable? "
      "=====\n"
      "  Rule under test (amg_lean.hpp:admit_level): a candidate coarse level is\n"
      "  ADMITTED iff (1) ratio >= min_ratio AND (2) EITHER n_coarse <=\n"
      "  coarse_dof_cap (small enough to BE the bottom, where a dense operator is\n"
      "  cheap and gets a direct solve) OR all of (2a) nnz/n <= max_nnz_per_row,\n"
      "  (2b) nnz/n^2 <= max_density, (2c) (nnz/n)/(parent nnz/n) <= max_growth.\n"
      "  A rejected candidate is DISCARDED and its parent becomes the bottom.\n"
      "  Phase 0 had only (1), at 1.15.\n");
  const Fixture f = {"LATTICE solid_box_48", 48, 48, 48, 1.0, 0.0, 2, 0.5, 1};
  const System S = build_system(f);
  const double base = geo_hierarchy_mb(S);
  const fea_detail::MatfreeReduced m = reduce(S);
  const std::vector<double> B = rigid_body_modes(S, m);
  const GeoResult g = geometric_baseline(S, 1e-6, 20000);
  std::printf(
      "\n  fixture: %s | reduced DOF %d | matfree baseline %.1f MB | geometric "
      "hier=%d used_mg=%d cycles=%d cg_iters=%d %.2fs\n",
      f.name.c_str(), m.ng, base, g.hier_built ? 1 : 0, g.used_mg ? 1 : 0, g.cycles,
      g.iterations, g.seconds);

  struct Cfg {
    const char* label;
    double theta;
    double min_ratio;
    double max_npr;
    double max_density;
    bool smooth;
  };
  const std::vector<Cfg> cfgs = {
      {"PHASE-0 SETTINGS (ratio 1.15, no caps)", 0.08, 1.15, 1e9, 1.0, true},
      {"phase-0 knobs, unsmoothed P", 0.08, 1.15, 1e9, 1.0, false},
      {"control ON  (ratio 2.0, 400 nz/row, 0.10)", 0.08, 2.0, 400.0, 0.10, false},
      {"control ON  + theta 0.02 (bigger aggs)", 0.02, 2.0, 400.0, 0.10, false},
      {"control ON  + theta 0.04", 0.04, 2.0, 400.0, 0.10, false},
      {"control ON  + theta 0.16", 0.16, 2.0, 400.0, 0.10, false},
      {"control TIGHT (ratio 4.0, 200 nz/row, 0.02)", 0.08, 4.0, 200.0, 0.02, false},
      {"control ON, smoothed P", 0.08, 2.0, 400.0, 0.10, true},
      {"control LOOSE (ratio 1.5, 1200 nz/row)", 0.08, 1.5, 1200.0, 0.30, false},
  };
  std::printf(
      "\n  %-42s %6s %8s %7s %9s %9s %9s %8s\n", "configuration", "levels",
      "worst nz/row", "cycles", "setup s", "solve s", "AMG MB", "vs base");
  for (const Cfg& c : cfgs) {
    amglean::LeanOptions o;
    o.strength_theta = c.theta;
    o.min_coarsening_ratio = c.min_ratio;
    o.max_nnz_per_row = c.max_npr;
    o.max_level_density = c.max_density;
    o.max_stencil_growth = c.max_density >= 1.0 ? 1e9 : 8.0;
    o.smooth_prolongator = c.smooth;
    const double t0 = now_s();
    amglean::LeanHierarchy H = amglean::lean_setup(m, B, 6, o, now_s);
    const double su = now_s() - t0;
    const double t1 = now_s();
    const amg::SolveStats st = amglean::lean_pcg(H, m.rg, 1e-6, 400, o);
    const double so = now_s() - t1;
    double worst = 0.0;
    for (int l = 0; l < H.coarse.levels(); ++l) {
      const amg::Level& L = H.coarse.lv[static_cast<std::size_t>(l)];
      if (L.A.nrow)
        worst = std::max(worst, static_cast<double>(L.A.nnz()) / L.A.nrow);
    }
    const double mb = H.amg_bytes / (1024.0 * 1024.0);
    std::printf("  %-42s %6d %8.0f %7d%s %9.2f %9.2f %9.1f %7.2fx\n", c.label,
                H.levels(), worst, st.cycles, st.converged ? " " : "*", su, so, mb,
                base > 0 ? mb / base : 0.0);
    for (const std::string& s : H.level_notes)
      std::printf("      NOTE: %s\n", s.c_str());
    std::fflush(stdout);
  }
  std::printf("  (* = did not converge within 400 cycles)\n");
  return 0;
}

int mode_determinism() {
  std::printf("\n===== [DETERMINISM] B4: bit-identical twice-run =====\n");
  const std::vector<Fixture> fx = {
      {"solid32", 32, 32, 32, 1.0, 0.0, 2, 0.5, 0},
      {"occ0.40+bore0.40 100x96x96", 100, 96, 96, 0.40, 0.40, 2, 0.5, 0},
      {"LATTICE solid_box_48", 48, 48, 48, 1.0, 0.0, 2, 0.5, 1},
  };
  bool all = true;
  for (const Fixture& f : fx) {
    const System S = build_system(f);
    const fea_detail::MatfreeReduced m = reduce(S);
    const std::vector<double> B = rigid_body_modes(S, m);
    for (int sp = 0; sp < 2; ++sp) {
      amglean::LeanOptions o;
      o.smooth_prolongator = sp != 0;
      std::string d;
      const bool ok = determinism_check(m, B, o, 1e-6, 20, &d);
      all = all && ok;
      std::printf("   %-32s P=%-10s : %s — %s\n", f.name.c_str(),
                  sp ? "smoothed" : "unsmoothed", ok ? "IDENTICAL" : "MISMATCH",
                  d.c_str());
      std::fflush(stdout);
    }
  }
  std::printf("   B4 VERDICT: %s\n", all ? "PASS" : "FAIL");
  return 0;
}

}  // namespace

int main(int argc, char** argv) {
  const std::string mode = argc > 1 ? argv[1] : "all";
  std::printf("AMG Phase 1 — memory-lean rebuild (fine level MATRIX-FREE).\n");
  std::printf("threads: mf_thread_count=%d | mode=%s\n",
              fea_detail::mf_thread_count(), mode.c_str());

  if (mode == "verify") return mode_verify();
  if (mode == "correctness") return mode_correctness();
  if (mode == "memory") return mode_memory();
  if (mode == "stagnation") return mode_stagnation();
  if (mode == "developed") return mode_developed();
  if (mode == "ultradilute") return mode_ultradilute(argc > 2 ? std::atoi(argv[2]) : 40);
  if (mode == "coarsening") return mode_coarsening();
  if (mode == "memsweep") return mode_memsweep();
  if (mode == "nullspace") return mode_nullspace();
  if (mode == "determinism") return mode_determinism();
  if (mode == "all") {
    mode_verify();
    mode_correctness();
    mode_determinism();
    mode_memory();
    mode_coarsening();
    mode_stagnation();
    mode_developed();
    mode_ultradilute(40);
    return 0;
  }
  std::fprintf(stderr, "unknown mode '%s'\n", mode.c_str());
  return 2;
}
