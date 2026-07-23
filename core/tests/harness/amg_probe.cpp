// amg_probe.cpp — AMG Phase-0 feasibility harness (handoff 131). NOT a CI test,
// NOT wired into CTest, NOT linked into any production path. It answers ONE
// question with numbers: does an ALGEBRAIC (operator-following) multigrid
// contract on the pathology geometric multigrid stagnates on?
//
// It drives the standalone smoothed-aggregation prototype in `amg_sa.hpp`
// against the EXACT SAME linear systems the production solver sees — the
// BC-reduced, void-gated K_gg built by `fea_detail::mf_build_reduced`, the same
// object `fea_solve_mgcg_matfree` solves — so a comparison against the geometric
// baseline is apples-to-apples by construction, not by reconstruction.
//
// ---------------------------------------------------------------------------
// THE BARS, STATED BEFORE ANY MEASUREMENT (the 125 Amdahl rule)
//   R1 STAGNATION REGIME  (occ ~0.4 + clearance bore, real padded extents):
//        GO iff the sustained overall V-cycle contraction is <= ~0.5.
//   R2 BUILD-REJECTION REGIME (extents `mg_grid_coarsenable` refuses):
//        GO iff AMG BUILDS a hierarchy there AND contracts (same <= ~0.5 bar).
//   R3 HEALTHY REGIME (geometric MG carries in ~11-40 cycles):
//        AMG within ~2x of geometric's cycle count, else record a REGIME SPLIT
//        (AMG only where geometric fails) rather than a general replacement.
//   R4 COSTS: setup seconds per hierarchy vs solve seconds saved; per-cycle
//        time; hierarchy memory vs the geometric coarse-operator footprint.
//   R5 DETERMINISM: two independent (setup + solve) runs must produce
//        BIT-IDENTICAL residual histories. Asserted on every case.
//
// ---------------------------------------------------------------------------
// FIXTURE GEOMETRY (the 125 family, re-derived — 125's `mg_extents.cpp` lived in
// a session scratchpad and was never committed, so the rule below is stated
// explicitly here and the reproduction is validated by the GEOMETRIC baseline
// showing 125's signature, not by matching 125's voxel counts digit-for-digit):
//
//   * A design box of (ex, ey, ez) elements at spacing h.
//   * The PART is a centred rectangular prism of round(occ*ex) x round(occ*ey)
//     x ez elements — a column spanning the full box height, floating in an
//     otherwise EMPTY design-box expanse. `occ` = 1.0 fills the box.
//   * A CLEARANCE BORE of radius (hole * min(ex,ey)/2) along `hole_axis`,
//     centred on the box centre, is REMOVED (VoxelTag::Empty — the production
//     clearance is a removed element, not a soft cell: 125 §1b, simp.cpp maps
//     FrozenVoid -> Empty). Its size is a property of the BOX, not the part, so
//     the same bore is punched at every occ (matching 125's constant `nvoid`).
//   * Design density is UNIFORM rho (default 0.5) — the ITERATION-0 field. 125
//     §1a established the stagnation begins there; a developed design is not
//     required and only makes it worse.
//   * BCs: all three components of every part node on the z=0 face that a solid
//     element touches. LOAD: a transverse (+x) shear resultant spread over the
//     part nodes on the z=ez face — bending, the low-energy mode a coarse grid
//     loses first.
//
// ---------------------------------------------------------------------------
// THERMAL PROTOCOL (113). Cycle counts, contraction factors, aggregate counts,
// nnz and residual histories are DETERMINISTIC — captured once, exact. Only
// wall-clock is thermally contaminated; where wall-clock is the claim it is the
// MEDIAN of interleaved repeats with the min/max band printed, and it is always
// labelled as a single-threaded PROTOTYPE cost.
//
// ---------------------------------------------------------------------------
// BUILD (standalone; the library must be built Release first):
//   cmake -S core -B core/build -DCMAKE_BUILD_TYPE=Release
//   cmake --build core/build --target topopt -j8
//   c++ -std=c++17 -O2 -I core/include -I core/src/fea \
//       core/tests/harness/amg_probe.cpp core/build/libtopopt.a -o amg_probe
// RUN:  ./amg_probe <mode>     (modes: extents | correctness | stagnation |
//                               reject | healthy | costs | all)

#include <algorithm>
#include <array>
#include <chrono>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <string>
#include <vector>

#include "topopt/coarsen.hpp"
#include "topopt/fea.hpp"
#include "topopt/voxel.hpp"

#include "fea_matfree.hpp"  // internal: fea_detail::mf_build_reduced

#include "amg_sa.hpp"

using namespace topopt;

namespace {

constexpr double kE0 = 3500.0;   // FDM PLA modulus (MPa), materials.json
constexpr double kNu = 0.33;
constexpr double kH = 1.0;       // voxel edge (mm)
constexpr int kSimpP = 3;

double now_s() {
  using clock = std::chrono::steady_clock;
  return std::chrono::duration<double>(clock::now().time_since_epoch()).count();
}

double median_of(std::vector<double> v) {
  if (v.empty()) return 0.0;
  std::sort(v.begin(), v.end());
  return v[v.size() / 2];
}

// ---------------------------------------------------------------------------
// Fixtures
// ---------------------------------------------------------------------------
struct Fixture {
  std::string name;
  int ex = 0, ey = 0, ez = 0;
  double occ = 1.0;
  double hole = 0.0;   // bore radius as a fraction of min(ex,ey)/2; 0 = none
  int hole_axis = 2;   // 0=x, 1=y, 2=z
  double rho = 0.5;
  // Density pattern inside the part:
  //   0 = UNIFORM rho — the ITERATION-0 field (125 §1a: the stagnation already
  //       begins here, so it is the right first probe).
  //   1 = LATTICE — a deterministic synthetic stand-in for a DEVELOPED SIMP
  //       design, later in the solve sequence: thin axial columns on an 8-voxel
  //       pitch (2 voxels thick) plus a tie layer every 16 in z, at rho=1.0,
  //       with rho=0.02 elsewhere. E = rho^3 E0 makes that a ~1.25e5 modulus
  //       contrast carried on sub-coarse-cell members — the geometry a coarse
  //       grid cannot represent AND the contrast together.
  //       It is SYNTHETIC and deterministic, NOT optimizer output; see the
  //       handoff's scope note. It exists so the sequence is sampled at more
  //       than one point without an hours-long optimizer run.
  int pattern = 0;
};

struct System {
  VoxelGrid grid;
  std::vector<double> youngs;  // per voxel
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
          continue;  // removed element (the production clearance is a HOLE)
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
          const double r = (col || tie) ? 1.0 : 0.02;
          S.youngs[g.index(i, j, k)] = std::pow(r, kSimpP) * kE0;
        }
  }

  // Node "touched by a solid element" mask, so BCs and loads never land on a
  // void DOF (which the M3.1 gate would reject).
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
  const double total_fx = 100.0;  // N, transverse shear -> bending
  if (!top.empty()) {
    const double per = total_fx / static_cast<double>(top.size());
    for (int nd : top) S.loads.push_back({nd, 0, per});
  }
  return S;
}

// ---------------------------------------------------------------------------
// The reduced system, as CSR, assembled from the EXACT production element table
// and void gate (fea_detail::mf_build_reduced). This is K_gg DOF-for-DOF —
// the same operator `fea_solve_mgcg_matfree` applies matrix-free.
//
// Structure comes from the node adjacency (so the columns of each row are
// naturally sorted: reduced DOF indices ascend with the global DOF index, which
// ascends with node index); values are accumulated element by element in the
// element table's fixed (colour-sorted) order, so the assembly is deterministic.
// ---------------------------------------------------------------------------
struct Reduced {
  amg::Csr A;
  std::vector<double> rhs;
  std::vector<int> dof2node;   // reduced DOF -> compact node index
  int nnodes = 0;
  std::vector<int> kept_global;
  int ndof_full = 0;
  double assemble_seconds = 0.0;
};

Reduced assemble_reduced_csr(const System& S) {
  using namespace topopt::fea_detail;
  const double t0 = now_s();
  CgInfo dummy;
  MatfreeReduced m = mf_build_reduced(S.grid, 0.0, kNu, S.bcs, S.loads,
                                      &S.youngs, "amg_probe", &dummy);
  Reduced R;
  R.rhs = m.rg;
  R.kept_global = m.kept_global;
  R.ndof_full = m.ndof;
  const int ng = m.ng;

  // reduced index of a global DOF (-1 if not kept)
  std::vector<int> red_of(static_cast<std::size_t>(m.ndof), -1);
  for (int gi = 0; gi < ng; ++gi)
    red_of[static_cast<std::size_t>(m.kept_global[static_cast<std::size_t>(gi)])] = gi;

  // compact node numbering (kept_global ascends => node ids ascend)
  R.dof2node.assign(static_cast<std::size_t>(ng), 0);
  {
    int last = -1, cnt = -1;
    for (int gi = 0; gi < ng; ++gi) {
      const int nd = m.kept_global[static_cast<std::size_t>(gi)] / 3;
      if (nd != last) {
        ++cnt;
        last = nd;
      }
      R.dof2node[static_cast<std::size_t>(gi)] = cnt;
    }
    R.nnodes = cnt + 1;
  }
  // compact node -> grid node id
  std::vector<int> node_grid(static_cast<std::size_t>(R.nnodes), 0);
  for (int gi = 0; gi < ng; ++gi)
    node_grid[static_cast<std::size_t>(R.dof2node[static_cast<std::size_t>(gi)])] =
        m.kept_global[static_cast<std::size_t>(gi)] / 3;

  // node adjacency from the element table
  std::vector<std::vector<int>> nadj(static_cast<std::size_t>(R.nnodes));
  {
    // compact node index of a grid node (-1 if absent)
    std::vector<int> cnode(static_cast<std::size_t>(m.ndof / 3), -1);
    for (int a = 0; a < R.nnodes; ++a)
      cnode[static_cast<std::size_t>(node_grid[static_cast<std::size_t>(a)])] = a;
    for (const MfElem& el : m.elems) {
      int cn[8];
      for (int a = 0; a < 8; ++a)
        cn[a] = cnode[static_cast<std::size_t>(el.edof[3 * a] / 3)];
      for (int a = 0; a < 8; ++a) {
        if (cn[a] < 0) continue;
        for (int b = 0; b < 8; ++b)
          if (cn[b] >= 0) nadj[static_cast<std::size_t>(cn[a])].push_back(cn[b]);
      }
    }
    for (auto& v : nadj) {
      std::sort(v.begin(), v.end());
      v.erase(std::unique(v.begin(), v.end()), v.end());
    }
  }

  // kept DOF slots per compact node (ascending component), contiguous in the
  // reduced numbering because kept_global ascends
  std::vector<int> node_first(static_cast<std::size_t>(R.nnodes), -1);
  std::vector<int> node_cnt(static_cast<std::size_t>(R.nnodes), 0);
  for (int gi = 0; gi < ng; ++gi) {
    const int a = R.dof2node[static_cast<std::size_t>(gi)];
    if (node_first[static_cast<std::size_t>(a)] < 0)
      node_first[static_cast<std::size_t>(a)] = gi;
    node_cnt[static_cast<std::size_t>(a)]++;
  }

  // CSR structure
  amg::Csr& A = R.A;
  A.nrow = ng;
  A.ncol = ng;
  A.rowptr.assign(static_cast<std::size_t>(ng) + 1, 0);
  for (int gi = 0; gi < ng; ++gi) {
    const int a = R.dof2node[static_cast<std::size_t>(gi)];
    amg::i64 w = 0;
    for (int b : nadj[static_cast<std::size_t>(a)])
      w += node_cnt[static_cast<std::size_t>(b)];
    A.rowptr[gi + 1] = w;
  }
  for (int gi = 0; gi < ng; ++gi) A.rowptr[gi + 1] += A.rowptr[gi];
  A.col.resize(static_cast<std::size_t>(A.rowptr[ng]));
  A.val.assign(static_cast<std::size_t>(A.rowptr[ng]), 0.0);
  for (int gi = 0; gi < ng; ++gi) {
    const int a = R.dof2node[static_cast<std::size_t>(gi)];
    amg::i64 w = A.rowptr[gi];
    for (int b : nadj[static_cast<std::size_t>(a)])
      for (int t = 0; t < node_cnt[static_cast<std::size_t>(b)]; ++t)
        A.col[static_cast<std::size_t>(w++)] =
            node_first[static_cast<std::size_t>(b)] + t;
  }

  // values, element by element in the table's fixed order
  {
    const int kDof = Hex8Stiffness::kDof;
    std::vector<amg::i64> base(static_cast<std::size_t>(kDof) * 8, 0);
    for (const MfElem& el : m.elems) {
      int rrow[24];
      for (int r = 0; r < kDof; ++r)
        rrow[r] = red_of[static_cast<std::size_t>(el.edof[r])];
      // per (local row, target node) base position in the CSR row
      for (int r = 0; r < kDof; ++r) {
        if (rrow[r] < 0) continue;
        const amg::i64 lo = A.rowptr[rrow[r]], hi = A.rowptr[rrow[r] + 1];
        for (int nb = 0; nb < 8; ++nb) {
          const int c0 = rrow[3 * nb];
          const int c1 = rrow[3 * nb + 1];
          const int c2 = rrow[3 * nb + 2];
          const int any = c0 >= 0 ? c0 : (c1 >= 0 ? c1 : c2);
          if (any < 0) {
            base[static_cast<std::size_t>(r) * 8 + nb] = -1;
            continue;
          }
          // first kept DOF index of that node
          const int nfirst =
              node_first[static_cast<std::size_t>(R.dof2node[static_cast<std::size_t>(any)])];
          const auto it = std::lower_bound(A.col.begin() + lo, A.col.begin() + hi, nfirst);
          base[static_cast<std::size_t>(r) * 8 + nb] = it - A.col.begin();
        }
      }
      for (int r = 0; r < kDof; ++r) {
        if (rrow[r] < 0) continue;
        for (int c = 0; c < kDof; ++c) {
          const int cr = rrow[c];
          if (cr < 0) continue;
          const int nb = c / 3;
          const amg::i64 bpos = base[static_cast<std::size_t>(r) * 8 + nb];
          const int nfirst = node_first[static_cast<std::size_t>(
              R.dof2node[static_cast<std::size_t>(cr)])];
          A.val[static_cast<std::size_t>(bpos + (cr - nfirst))] +=
              el.factor * m.Ke(r, c);
        }
      }
    }
  }
  R.assemble_seconds = now_s() - t0;
  return R;
}

// 6 rigid-body modes, the elasticity near-nullspace: 3 translations + 3
// rotations about the active region's centroid, rotations scaled by the region's
// half-diagonal so all six columns are O(1).
std::vector<double> rigid_body_modes(const System& S, const Reduced& R) {
  const int ng = R.A.nrow;
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
    coords(R.kept_global[static_cast<std::size_t>(gi)] / 3, x, y, z);
    sx += x;
    sy += y;
    sz += z;
  }
  const double inv = 1.0 / static_cast<double>(ng);
  const double cx = sx * inv, cy = sy * inv, cz = sz * inv;
  double L = 0.0;
  for (int gi = 0; gi < ng; ++gi) {
    double x, y, z;
    coords(R.kept_global[static_cast<std::size_t>(gi)] / 3, x, y, z);
    L = std::max(L, std::sqrt((x - cx) * (x - cx) + (y - cy) * (y - cy) +
                              (z - cz) * (z - cz)));
  }
  if (L <= 0.0) L = 1.0;

  std::vector<double> B(static_cast<std::size_t>(ng) * 6, 0.0);
  for (int gi = 0; gi < ng; ++gi) {
    const int gd = R.kept_global[static_cast<std::size_t>(gi)];
    const int comp = gd % 3;
    double x, y, z;
    coords(gd / 3, x, y, z);
    const double X = (x - cx) / L, Y = (y - cy) / L, Z = (z - cz) / L;
    double* row = &B[static_cast<std::size_t>(gi) * 6];
    row[comp] = 1.0;                        // translations
    if (comp == 1) row[3] = -Z;             // rot about x
    if (comp == 2) row[3] = Y;
    if (comp == 0) row[4] = Z;              // rot about y
    if (comp == 2) row[4] = -X;
    if (comp == 0) row[5] = -Y;             // rot about z
    if (comp == 1) row[5] = X;
  }
  return B;
}

// ---------------------------------------------------------------------------
// Geometric baseline (the production entry point) + Jacobi baseline
// ---------------------------------------------------------------------------
struct GeoResult {
  bool ran = false;
  bool used_mg = false;
  bool hier_built = false;
  int mg_levels = 0;
  int cycles = 0;
  int iterations = 0;
  double residual = 0.0;
  double seconds = 0.0;
  std::string error;
};

GeoResult geometric_baseline(const System& S, double tol, int max_it) {
  GeoResult g;
  CgInfo info;
  // MUST reset 127's per-run stagnation latch before every baseline solve.
  // The latch is thread-local and STICKY: after kMgLatchThreshold=3 consecutive
  // stagnated solves it stops BUILDING the hierarchy at all for the rest of the
  // process, and production resets it once per run (minimize_plastic.cpp). A
  // harness that solves many fixtures in one process is not "a run" — without
  // this reset the latch leaks across fixtures and a later HEALTHY fixture
  // reports hier_built=0 (build skipped) when its grid is perfectly fine.
  // Observed live: three interleaved repeats of the stagnating fixture latched
  // it, and the next fixture's geometric baseline reported hier=0/used_mg=0.
  // (Which is also a clean confirmation that the 127 latch does what it says.)
  fea_matfree_reset_mg_stagnation_latch();
  const double t0 = now_s();
  try {
    fea_solve_mgcg_matfree(S.grid, S.youngs, kNu, S.bcs, S.loads, tol, max_it,
                           &info);
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
    fea_solve_cg_matfree(S.grid, S.youngs, kNu, S.bcs, S.loads, tol, max_it,
                         &info);
    g.ran = true;
  } catch (const std::exception& e) {
    g.error = e.what();
  }
  g.seconds = now_s() - t0;
  g.iterations = info.iterations;
  g.residual = info.residual;
  return g;
}

// ---------------------------------------------------------------------------
// Reporting helpers
// ---------------------------------------------------------------------------
// Sustained overall contraction of the stationary V-cycle: the geometric mean
// of the per-cycle ratios over the LAST HALF of the recorded history (the
// asymptotic regime; the first cycles are transient). Reported alongside the
// whole-run mean so a decaying rate cannot hide behind a good first cycle.
struct Contraction {
  double overall = 0.0;   // (r_K/r_0)^(1/K)
  double sustained = 0.0; // geometric mean over the last half
  double worst = 0.0;     // worst single late cycle
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

bool histories_bit_identical(const std::vector<double>& a,
                             const std::vector<double>& b) {
  if (a.size() != b.size()) return false;
  return std::memcmp(a.data(), b.data(), a.size() * sizeof(double)) == 0;
}

struct AmgRun {
  amg::Hierarchy H;
  double setup_s = 0.0;
  amg::SolveStats stat;   // stationary V-cycle
  amg::SolveStats pcg;    // AMG-PCG
  double stat_s = 0.0, pcg_s = 0.0;
  bool deterministic = false;
};

AmgRun run_amg(const System& S, const Reduced& R, const std::vector<double>& B,
               const amg::Options& opt, double tol, int max_cycles,
               bool check_determinism) {
  AmgRun run;
  double t0 = now_s();
  run.H = amg::setup(R.A, R.dof2node, R.nnodes, 6, B, opt);
  run.setup_s = now_s() - t0;
  run.H.setup_seconds = run.setup_s;

  t0 = now_s();
  run.stat = amg::solve_stationary(run.H, 0, R.rhs, tol, max_cycles, opt);
  run.stat_s = now_s() - t0;

  t0 = now_s();
  run.pcg = amg::solve_pcg(run.H, R.rhs, tol, max_cycles * 4, opt);
  run.pcg_s = now_s() - t0;

  if (check_determinism) {
    // Independent SECOND setup from the same inputs, then a bit-compare of
    // (a) every operator and prolongator in the hierarchy and (b) a re-run of
    // the stationary residual history. Both are memcmp on raw doubles — the
    // assertion is BIT-identity, not agreement to a tolerance.
    amg::Hierarchy H2 = amg::setup(R.A, R.dof2node, R.nnodes, 6, B, opt);
    bool same = (H2.levels() == run.H.levels());
    for (int l = 0; same && l < H2.levels(); ++l) {
      const amg::Level& a = run.H.lv[static_cast<std::size_t>(l)];
      const amg::Level& b = H2.lv[static_cast<std::size_t>(l)];
      same = a.A.nrow == b.A.nrow && a.A.nnz() == b.A.nnz() &&
             a.P.nnz() == b.P.nnz() &&
             std::memcmp(a.A.val.data(), b.A.val.data(),
                         a.A.val.size() * sizeof(double)) == 0 &&
             std::memcmp(a.A.col.data(), b.A.col.data(),
                         a.A.col.size() * sizeof(int)) == 0 &&
             std::memcmp(a.P.val.data(), b.P.val.data(),
                         a.P.val.size() * sizeof(double)) == 0;
    }
    const int recheck = std::min(12, std::max(1, run.stat.cycles));
    const amg::SolveStats s2 =
        amg::solve_stationary(H2, 0, R.rhs, tol, recheck, opt);
    std::vector<double> head(run.stat.history.begin(),
                            run.stat.history.begin() +
                                std::min(run.stat.history.size(),
                                         s2.history.size()));
    std::vector<double> head2(s2.history.begin(),
                              s2.history.begin() + head.size());
    run.deterministic = same && histories_bit_identical(head, head2);
  }
  return run;
}

void print_hierarchy(const amg::Hierarchy& H) {
  std::printf("    level      n        nnz    nnz/row   aggregates\n");
  for (int l = 0; l < H.levels(); ++l) {
    const amg::Level& L = H.lv[static_cast<std::size_t>(l)];
    std::printf("    %5d %8d %10lld %8.1f %12d\n", l, L.A.nrow,
                static_cast<long long>(L.A.nnz()),
                L.A.nrow ? static_cast<double>(L.A.nnz()) / L.A.nrow : 0.0,
                L.naggregates);
  }
  std::printf("    coarsest n=%d dense-LDL^T=%s  hierarchy memory=%.1f MB\n",
              H.coarse_n, H.coarse_dense_ok ? "yes" : "NO",
              H.total_bytes / (1024.0 * 1024.0));
}

void print_case_header(const Fixture& f, const System& S, const Reduced& R) {
  std::printf(
      "\n== %-22s box %dx%dx%d occ %.2f bore %.2f(axis %c) rho %.2f\n",
      f.name.c_str(), f.ex, f.ey, f.ez, f.occ, f.hole,
      "xyz"[f.hole_axis], f.rho);
  std::printf(
      "   solid=%lld bore-removed=%lld empty-expanse=%lld | reduced DOF=%d "
      "nodes=%d nnz=%lld (%.0f MB) | geometric coarsenable(rule)=%s\n",
      S.nsolid, S.nbore, S.nempty, R.A.nrow, R.nnodes,
      static_cast<long long>(R.A.nnz()),
      R.A.bytes() / (1024.0 * 1024.0),
      mg_grid_coarsenable(S.grid.nx, S.grid.ny, S.grid.nz) ? "YES" : "NO");
  // The fine-matrix ASSEMBLY is a cost the matrix-free production path does not
  // pay at all (078 removed the assembled fine K precisely because it OOMs), so
  // it is reported separately and must be counted against AMG in §R4.
  std::printf("   fine-matrix CSR assembly: %.2fs (a cost the matrix-free "
              "geometric path does NOT pay)\n",
              R.assemble_seconds);
}

// Effective CG-accelerated contraction, defined exactly as 125 §1b's rho_eff so
// the numbers are directly comparable: rho_eff = tol^(1/iters).
double rho_eff(int iters, double tol) {
  if (iters <= 0) return 1.0;
  return std::pow(tol, 1.0 / iters);
}

// ---------------------------------------------------------------------------
// Modes
// ---------------------------------------------------------------------------
void mode_extents() {
  std::printf("Geometric-MG coarsenability of candidate design-box extents\n");
  std::printf("(mg_grid_coarsenable — coarsen.hpp, the solver's own rule)\n\n");
  const int cand[][3] = {
      {64, 64, 64},    {48, 48, 48},   {32, 32, 32},   {96, 96, 96},
      {192, 112, 128}, {184, 104, 128},{100, 96, 96},  {96, 88, 100},
      {120, 96, 96},   {96, 96, 100},  {88, 88, 88},   {104, 96, 96},
  };
  for (const auto& c : cand)
    std::printf("  %4dx%4dx%4d  coarsenable=%s\n", c[0], c[1], c[2],
                mg_grid_coarsenable(c[0], c[1], c[2]) ? "yes" : "NO");
}

// Correctness: a small HEALTHY system, AMG vs the library's reference solver.
void mode_correctness() {
  std::printf(
      "\n### CORRECTNESS — AMG-PCG vs the library's Jacobi-CG on a small "
      "healthy system\n");
  Fixture f;
  f.name = "correctness_16";
  f.ex = 16;
  f.ey = 16;
  f.ez = 16;
  f.occ = 1.0;
  f.hole = 0.0;
  f.rho = 1.0;
  System S = build_system(f);
  Reduced R = assemble_reduced_csr(S);
  print_case_header(f, S, R);

  // Reference: the library's matrix-free Jacobi-CG at a tight tolerance.
  CgInfo info;
  FeaSolution ref = fea_solve_cg_matfree(S.grid, S.youngs, kNu, S.bcs, S.loads,
                                         1e-12, 200000, &info);

  amg::Options opt;
  const std::vector<double> B = rigid_body_modes(S, R);
  amg::Hierarchy H = amg::setup(R.A, R.dof2node, R.nnodes, 6, B, opt);
  amg::SolveStats st = amg::solve_pcg(H, R.rhs, 1e-12, 500, opt);
  print_hierarchy(H);

  double maxu = 0.0, maxd = 0.0;
  for (int gi = 0; gi < R.A.nrow; ++gi) {
    const double u =
        ref.u[static_cast<std::size_t>(R.kept_global[static_cast<std::size_t>(gi)])];
    maxu = std::max(maxu, std::fabs(u));
    maxd = std::max(maxd,
                    std::fabs(u - st.solution[static_cast<std::size_t>(gi)]));
  }
  // Symmetry check on the assembled CSR (A must equal A^T exactly by
  // construction: each element scatter is symmetric).
  double asym = 0.0;
  {
    amg::Csr At = amg::transpose(R.A);
    for (amg::i64 p = 0; p < R.A.nnz(); ++p)
      asym = std::max(asym, std::fabs(R.A.val[static_cast<std::size_t>(p)] -
                                      At.val[static_cast<std::size_t>(p)]));
  }
  std::printf(
      "   reference Jacobi-CG: iters=%d resid=%.2e | AMG-PCG: cycles=%d "
      "resid=%.2e converged=%s\n",
      info.iterations, info.residual, st.cycles, st.final_rel,
      st.converged ? "yes" : "NO");
  std::printf("   max|u_ref|=%.6e  max|u_amg - u_ref|=%.3e  relative=%.3e\n",
              maxu, maxd, maxu > 0 ? maxd / maxu : 0.0);
  std::printf("   assembled-CSR symmetry max|A - A^T| = %.3e\n", asym);
  std::printf("   VERDICT: %s (bar: relative difference <= 1e-8)\n",
              (maxu > 0 && maxd / maxu <= 1e-8) ? "PASS" : "FAIL");
}

struct CaseReport {
  std::string name;
  int ndof = 0;
  bool geo_hier = false, geo_used = false;
  int geo_cycles = 0, geo_iters = 0;
  double geo_s = 0.0;
  int jac_iters = 0;
  double jac_s = 0.0;
  int amg_levels = 0;
  double amg_setup_s = 0.0;
  int amg_stat_cycles = 0;
  bool amg_stat_conv = false;
  Contraction amg_contr;
  int amg_pcg_cycles = 0;
  bool amg_pcg_conv = false;
  double amg_pcg_s = 0.0;
  double amg_mb = 0.0;
  bool determinism = false;
};

CaseReport run_case(const Fixture& f, double tol, int max_cycles,
                    int jacobi_cap, bool do_jacobi, const amg::Options& opt) {
  System S = build_system(f);
  Reduced R = assemble_reduced_csr(S);
  print_case_header(f, S, R);

  CaseReport rep;
  rep.name = f.name;
  rep.ndof = R.A.nrow;

  // The geometric MG budget/latch are the solver's own; `jacobi_cap` caps only
  // the Jacobi FALLBACK inside that call, so a stagnating case cannot run away
  // (the library's default cap is 2*ndof — hours at these sizes).
  GeoResult geo = geometric_baseline(S, tol, jacobi_cap);
  rep.geo_hier = geo.hier_built;
  rep.geo_used = geo.used_mg;
  rep.geo_cycles = geo.cycles;
  rep.geo_iters = geo.iterations;
  rep.geo_s = geo.seconds;
  std::printf(
      "   GEOMETRIC (fea_solve_mgcg_matfree): hier_built=%d used_mg=%d "
      "levels=%d mg_cycles=%d cg_iters=%d resid=%.2e  %.2fs%s%s\n",
      geo.hier_built ? 1 : 0, geo.used_mg ? 1 : 0, geo.mg_levels, geo.cycles,
      geo.iterations, geo.residual, geo.seconds, geo.error.empty() ? "" : "  ERROR: ",
      geo.error.c_str());
  if (geo.used_mg)
    std::printf("      -> geometric rho_eff (CG-accelerated) = %.3f\n",
                rho_eff(geo.cycles, tol));
  else
    std::printf(
        "      -> geometric FELL BACK (%s); contraction not reached within "
        "budget\n",
        geo.hier_built ? "STAGNATION: hierarchy built" : "BUILD-REJECTION");

  if (do_jacobi) {
    GeoResult jac = jacobi_baseline(S, tol, jacobi_cap);
    rep.jac_iters = jac.iterations;
    rep.jac_s = jac.seconds;
    std::printf("   JACOBI-CG baseline: iters=%d resid=%.2e %.2fs%s\n",
                jac.iterations, jac.residual, jac.seconds,
                jac.ran ? "" : "  (capped / did not converge)");
  }

  const std::vector<double> B = rigid_body_modes(S, R);
  AmgRun run = run_amg(S, R, B, opt, tol, max_cycles, true);
  print_hierarchy(run.H);
  rep.amg_levels = run.H.levels();
  rep.amg_setup_s = run.setup_s;
  rep.amg_mb = run.H.total_bytes / (1024.0 * 1024.0);
  rep.amg_stat_cycles = run.stat.cycles;
  rep.amg_stat_conv = run.stat.converged;
  rep.amg_contr = contraction_of(run.stat.history);
  rep.amg_pcg_cycles = run.pcg.cycles;
  rep.amg_pcg_conv = run.pcg.converged;
  rep.amg_pcg_s = run.pcg_s;
  rep.determinism = run.deterministic;

  std::printf(
      "   AMG stationary V-cycle: cycles=%d converged=%s final_rel=%.2e | "
      "contraction overall=%.3f sustained=%.3f worst=%.3f\n",
      run.stat.cycles, run.stat.converged ? "yes" : "NO", run.stat.final_rel,
      rep.amg_contr.overall, rep.amg_contr.sustained, rep.amg_contr.worst);
  std::printf("   AMG residual history (first 12): ");
  for (std::size_t i = 0; i < run.stat.history.size() && i < 12; ++i)
    std::printf("%.2e ", run.stat.history[i]);
  std::printf("\n");
  std::printf(
      "   AMG-PCG: cycles=%d converged=%s | setup %.2fs, solve %.2fs, "
      "%.3fs/cycle | memory %.1f MB\n",
      run.pcg.cycles, run.pcg.converged ? "yes" : "NO", run.setup_s, run.pcg_s,
      run.pcg.cycles ? run.pcg_s / run.pcg.cycles : 0.0, rep.amg_mb);
  std::printf("   DETERMINISM (2 independent setups, bit-compare of every "
              "level's A/P + the residual history): %s\n",
              run.deterministic ? "IDENTICAL" : "*** DIVERGED ***");

  // PER-LEVEL contraction: run the same stationary V-cycle on each level's OWN
  // system, using the sub-hierarchy below it. If contraction is good deep in the
  // hierarchy but poor at level 0, the fine level is where the method loses; if
  // it degrades monotonically with depth, the coarsening is losing the modes.
  // The right-hand side at level l is the fine RHS restricted through the P
  // chain, so every level is being asked about the SAME physical residual.
  {
    std::printf("   per-level sub-hierarchy contraction (stationary V-cycle on "
                "each level's own system):\n");
    std::vector<double> bl = R.rhs;
    for (int l = 0; l < run.H.levels(); ++l) {
      if (l > 0) {
        const amg::Level& prev = run.H.lv[static_cast<std::size_t>(l - 1)];
        std::vector<double> nb(static_cast<std::size_t>(prev.P.ncol), 0.0);
        prev.P.apply_transpose(bl.data(), nb.data());
        bl.swap(nb);
      }
      if (l + 1 >= run.H.levels()) {
        std::printf("      level %d (n=%8d): coarsest — solved directly\n", l,
                    run.H.lv[static_cast<std::size_t>(l)].A.nrow);
        break;
      }
      const amg::SolveStats s =
          amg::solve_stationary(run.H, l, bl, tol, std::min(40, max_cycles), opt);
      const Contraction c = contraction_of(s.history);
      std::printf(
          "      level %d (n=%8d): cycles=%3d converged=%-3s overall=%.3f "
          "sustained=%.3f\n",
          l, run.H.lv[static_cast<std::size_t>(l)].A.nrow, s.cycles,
          s.converged ? "yes" : "NO", c.overall, c.sustained);
    }
  }
  return rep;
}

void print_summary(const std::vector<CaseReport>& reps) {
  std::printf(
      "\n\n### SUMMARY TABLE\n"
      "%-22s %9s | %-26s | %-34s | %s\n",
      "case", "red.DOF", "GEOMETRIC", "AMG (V-cycle contraction)", "determ.");
  std::printf(
      "%-22s %9s | %5s %5s %6s %7s | %6s %8s %9s %8s | \n", "", "", "hier",
      "used", "cycles", "cg_it", "levels", "cycles", "sustained", "pcg_cyc");
  for (const CaseReport& r : reps)
    std::printf("%-22s %9d | %5d %5d %6d %7d | %6d %8d %9.3f %8d | %s\n",
                r.name.c_str(), r.ndof, r.geo_hier ? 1 : 0, r.geo_used ? 1 : 0,
                r.geo_cycles, r.geo_iters, r.amg_levels, r.amg_stat_cycles,
                r.amg_contr.sustained, r.amg_pcg_cycles,
                r.determinism ? "ok" : "DIVERGED");
}

// ---------------------------------------------------------------------------
// R4 — THE COSTS, honestly.
//
// AMG's known tax is SETUP: a hierarchy must be rebuilt whenever the operator
// changes, which in this codebase is EVERY MMA iteration (the SIMP modulus field
// moves), exactly as the geometric Galerkin build already is — handoff 090
// measured that build at ~48% of a solve and 112 re-measured it at ~66%. So the
// question is not "is AMG setup expensive" (it is) but "is AMG setup + AMG solve
// cheaper than geometric build + geometric stagnation + Jacobi grind".
//
// Wall-clock protocol (113): modes are INTERLEAVED and repeated; the median is
// reported with the min/max band. Cycle counts in the same table are exact.
// Everything here is single-threaded PROTOTYPE C++ measured against a library
// path that is multi-threaded and SIMD-tuned — the honest comparison is the
// CYCLE COUNT and the SETUP-VS-SOLVE RATIO, never the raw seconds.
// ---------------------------------------------------------------------------
void mode_costs(double tol, const amg::Options& base_opt) {
  std::printf(
      "\n\n### R4 — SETUP-VS-SOLVE ECONOMICS AND MEMORY\n"
      "Wall-clock: median of %d interleaved repeats, [min..max] band. "
      "Single-threaded prototype vs the threaded library path — read the "
      "RATIOS, not the seconds.\n",
      3);
  struct Item {
    Fixture f;
    const char* note;
  };
  std::vector<Item> items;
  {
    Fixture a;
    a.name = "stagnation(192x112x128)";
    a.ex = 192; a.ey = 112; a.ez = 128; a.occ = 0.40; a.hole = 0.40;
    items.push_back({a, "the 125 killer"});
    Fixture b;
    b.name = "healthy(48^3 solid)";
    b.ex = 48; b.ey = 48; b.ez = 48; b.occ = 1.0; b.hole = 0.0;
    items.push_back({b, "geometric carries"});
  }

  for (const Item& it : items) {
    System S = build_system(it.f);
    Reduced R = assemble_reduced_csr(S);
    print_case_header(it.f, S, R);
    const std::vector<double> B = rigid_body_modes(S, R);

    std::vector<double> geo_s, setup_s, solve_s;
    int geo_cycles = 0, geo_iters = 0, amg_cycles = 0;
    bool geo_used = false, geo_hier = false;
    for (int rep = 0; rep < 3; ++rep) {
      GeoResult g = geometric_baseline(S, tol, 20000);
      geo_s.push_back(g.seconds);
      geo_cycles = g.cycles;
      geo_iters = g.iterations;
      geo_used = g.used_mg;
      geo_hier = g.hier_built;

      double t0 = now_s();
      amg::Hierarchy H = amg::setup(R.A, R.dof2node, R.nnodes, 6, B, base_opt);
      setup_s.push_back(now_s() - t0);
      t0 = now_s();
      amg::SolveStats st = amg::solve_pcg(H, R.rhs, tol, 400, base_opt);
      solve_s.push_back(now_s() - t0);
      amg_cycles = st.cycles;
      if (rep == 0) {
        std::printf(
            "   AMG hierarchy memory %.1f MB over %d levels; grid-operator "
            "complexity = %.2f (sum nnz / fine nnz)\n",
            H.total_bytes / (1024.0 * 1024.0), H.levels(), [&] {
              double s = 0.0;
              for (const amg::Level& L : H.lv)
                s += static_cast<double>(L.A.nnz());
              return s / static_cast<double>(H.lv[0].A.nnz());
            }());
      }
    }
    const std::size_t geo_nnz = fea_matfree_mgcg_assembled_operator_nonzeros(
        S.grid, S.uniform_E, kNu, S.bcs, S.loads);
    std::printf(
        "   GEOMETRIC: hier=%d used_mg=%d mg_cycles=%d cg_iters=%d | wall "
        "%.2fs [%.2f..%.2f]\n",
        geo_hier ? 1 : 0, geo_used ? 1 : 0, geo_cycles, geo_iters,
        median_of(geo_s), *std::min_element(geo_s.begin(), geo_s.end()),
        *std::max_element(geo_s.begin(), geo_s.end()));
    std::printf(
        "   AMG:       pcg_cycles=%d | setup %.2fs [%.2f..%.2f]  solve %.2fs "
        "[%.2f..%.2f]  setup/(setup+solve)=%.0f%%\n",
        amg_cycles, median_of(setup_s),
        *std::min_element(setup_s.begin(), setup_s.end()),
        *std::max_element(setup_s.begin(), setup_s.end()), median_of(solve_s),
        *std::min_element(solve_s.begin(), solve_s.end()),
        *std::max_element(solve_s.begin(), solve_s.end()),
        100.0 * median_of(setup_s) / (median_of(setup_s) + median_of(solve_s)));
    std::printf(
        "   MEMORY: geometric matrix-free hierarchy stores %.1f MB of COARSE "
        "operators and NO fine matrix (078); this AMG needs the fine matrix "
        "assembled: %.1f MB for A0 alone.\n",
        geo_nnz * 12.0 / (1024.0 * 1024.0), R.A.bytes() / (1024.0 * 1024.0));

    // Unsmoothed aggregation: informs whether a matrix-free-compatible variant
    // (no explicit A needed to FORM P) is worth a Phase-1 look.
    amg::Options un = base_opt;
    un.smooth_prolongator = false;
    const double t0 = now_s();
    amg::Hierarchy Hu = amg::setup(R.A, R.dof2node, R.nnodes, 6, B, un);
    const double us = now_s() - t0;
    amg::SolveStats su = amg::solve_stationary(Hu, 0, R.rhs, tol, 60, un);
    amg::SolveStats pu = amg::solve_pcg(Hu, R.rhs, tol, 400, un);
    const Contraction cu = contraction_of(su.history);
    std::printf(
        "   VARIANT unsmoothed aggregation (P = T, no A needed to form P): "
        "setup %.2fs, stationary sustained contraction %.3f, pcg_cycles=%d, "
        "memory %.1f MB\n",
        us, cu.sustained, pu.cycles, Hu.total_bytes / (1024.0 * 1024.0));
  }
}

// ---------------------------------------------------------------------------
// FIXTURE HUNT — geometric baseline ONLY (fast: the library path is threaded
// and SIMD-tuned), over the occ x bore factorial at the real padded extents.
// This is 125 §1b's factorial re-run on THIS fixture rule, and it is what
// establishes that the AMG measurement is aimed at a genuinely stagnating
// system rather than at a fixture that merely looks like one.
// ---------------------------------------------------------------------------
void mode_hunt(double tol) {
  std::printf(
      "\n\n### FIXTURE HUNT — geometric MG over the occ x bore factorial at "
      "192x112x128 (125 §1b re-run on this harness's fixture rule)\n");
  std::printf(
      "   %-18s %10s %10s %6s %6s %8s %8s %9s\n", "case", "solid", "red.DOF",
      "hier", "usedMG", "mg_cyc", "cg_it", "rho_eff");
  const double occs[] = {1.0, 0.7, 0.5, 0.4, 0.3};
  const double bores[] = {0.0, 0.4, 0.6};
  for (double o : occs)
    for (double h : bores) {
      Fixture f;
      char name[64];
      std::snprintf(name, sizeof(name), "occ%.2f bore%.2f", o, h);
      f.name = name;
      f.ex = 192; f.ey = 112; f.ez = 128; f.occ = o; f.hole = h;
      System S = build_system(f);
      CgInfo probe;
      int ndof = 0;
      try {
        using namespace topopt::fea_detail;
        CgInfo d;
        MatfreeReduced m = mf_build_reduced(S.grid, 0.0, kNu, S.bcs, S.loads,
                                            &S.youngs, "hunt", &d);
        ndof = m.ng;
      } catch (const std::exception&) {
      }
      GeoResult g = geometric_baseline(S, tol, 20000);
      (void)probe;
      std::printf("   %-18s %10lld %10d %6d %6d %8d %8d %9.3f%s\n",
                  f.name.c_str(), S.nsolid, ndof, g.hier_built ? 1 : 0,
                  g.used_mg ? 1 : 0, g.cycles, g.iterations,
                  g.used_mg ? rho_eff(g.cycles, tol) : 1.0,
                  g.used_mg ? "" : "   <-- FALLBACK");
    }
}

// ---------------------------------------------------------------------------
// KNOB SENSITIVITY. The GO/NO-GO bar is a number, so it must not hinge on one
// arbitrary choice of smoother strength or strength threshold. This sweeps the
// three knobs that matter on the STAGNATION fixture and prints contraction for
// each, so the verdict can be read against the whole envelope rather than a
// single default.
// ---------------------------------------------------------------------------
void mode_sweep(double tol) {
  std::printf(
      "\n\n### KNOB SENSITIVITY on the stagnation fixture (the verdict must "
      "not rest on one arbitrary default)\n");
  Fixture f;
  f.name = "occ0.40+bore0.40";
  f.ex = 192; f.ey = 112; f.ez = 128; f.occ = 0.40; f.hole = 0.40;
  System S = build_system(f);
  Reduced R = assemble_reduced_csr(S);
  print_case_header(f, S, R);
  const std::vector<double> B = rigid_body_modes(S, R);

  struct Knob {
    const char* label;
    double theta;
    int sweeps;
    bool smooth;
  };
  const Knob knobs[] = {
      {"theta 0.08, 1 SGS, smoothed  (default)", 0.08, 1, true},
      {"theta 0.08, 2 SGS, smoothed", 0.08, 2, true},
      {"theta 0.08, 3 SGS, smoothed", 0.08, 3, true},
      {"theta 0.25, 1 SGS, smoothed", 0.25, 1, true},
      {"theta 0.25, 2 SGS, smoothed", 0.25, 2, true},
      {"theta 0.08, 2 SGS, UNsmoothed", 0.08, 2, false},
  };
  std::printf("   %-40s %8s %10s %10s %8s %8s\n", "configuration", "levels",
              "stat.cyc", "sustained", "pcg_cyc", "setup_s");
  for (const Knob& k : knobs) {
    amg::Options o;
    o.strength_theta = k.theta;
    o.pre_sweeps = k.sweeps;
    o.post_sweeps = k.sweeps;
    o.smooth_prolongator = k.smooth;
    const double t0 = now_s();
    amg::Hierarchy H = amg::setup(R.A, R.dof2node, R.nnodes, 6, B, o);
    const double su = now_s() - t0;
    amg::SolveStats st = amg::solve_stationary(H, 0, R.rhs, tol, 60, o);
    amg::SolveStats pc = amg::solve_pcg(H, R.rhs, tol, 400, o);
    const Contraction c = contraction_of(st.history);
    std::printf("   %-40s %8d %10d %10.3f %8d %8.1f\n", k.label, H.levels(),
                st.cycles, c.sustained, pc.cycles, su);
  }
}

}  // namespace

int main(int argc, char** argv) {
  const std::string mode = argc > 1 ? argv[1] : "all";
  const double tol = 1e-6;  // 125's measurement tolerance
  amg::Options opt;
  std::vector<CaseReport> reps;

  std::setvbuf(stdout, nullptr, _IOLBF, 0);

  if (mode == "extents") {
    mode_extents();
    return 0;
  }
  if (mode == "correctness" || mode == "all") mode_correctness();

  if (mode == "stagnation" || mode == "all") {
    std::printf(
        "\n\n### R1 — THE STAGNATION REGIME (125's killer: thin part in an "
        "empty design box + a clearance bore, at the real padded extents)\n"
        "Bar stated before measuring: GO iff sustained V-cycle contraction "
        "<= ~0.5.\n");
    // MEMORY: fixture 1 (804 864 DOF) peaks around 4 GB and is the headline.
    // Fixtures 2 and 3 are CONTEXT and are progressively larger — 1 377 792 and
    // 7 805 952 reduced DOF. The assembled AMG path cannot hold the third on a
    // 16 GB machine (its fine CSR alone is ~7.8 GB), and that limit is itself a
    // Phase-1 finding, not a gap. Their GEOMETRIC baselines print before the AMG
    // work starts, so a memory-constrained box still gets those rows; use `hunt`
    // for the geometric factorial without any AMG at all.
    std::vector<Fixture> fs;
    Fixture a;
    a.name = "occ0.40+bore0.40";
    a.ex = 192; a.ey = 112; a.ez = 128; a.occ = 0.40; a.hole = 0.40; a.hole_axis = 2;
    fs.push_back(a);
    Fixture b = a;
    b.name = "occ0.40 nobore";
    b.hole = 0.0;
    fs.push_back(b);
    Fixture c = a;
    c.name = "occ1.00+bore0.40";
    c.occ = 1.0;
    fs.push_back(c);
    for (const Fixture& f : fs) reps.push_back(run_case(f, tol, 60, 40000, true, opt));
  }

  if (mode == "reject" || mode == "all") {
    std::printf(
        "\n\n### R2 — THE BUILD-REJECTION REGIME (extents the geometric "
        "builder refuses; AMG has no coarsenability arithmetic)\n"
        "Bar: GO iff AMG BUILDS and contracts (<= ~0.5) where the geometric "
        "hierarchy never builds.\n");
    // FIXTURE CHOICE — corrected after a measured surprise, recorded because it
    // refines the 122/125/127 record:
    //
    //   `mg_grid_coarsenable` (coarsen.hpp) bounds the coarse DOF count by
    //   3 * (coarse NODE count). The real builder (build_mf_hierarchy ->
    //   build_hierarchy) instead counts the ACTIVE coarse DOFs, and on a sparse
    //   active set (occ 0.40 + a bore) that is far below the bound. So a
    //   predicate `false` does NOT imply the solver refuses: measured directly,
    //   100x96x96 at occ 0.40 has coarsenable(rule)=NO yet hier_built=1.
    //   coarsen.hpp documents the `true` direction as conservative; the `false`
    //   direction is only a rejection PREDICTION when the active set is dense.
    //
    // A genuine build-rejection therefore needs a DENSE part on extents with a
    // shallow 2-adic depth. 52^3: 52->26->13(odd); the coarsest usable level has
    // 14^3 nodes = 8232 DOF > kMgCoarseDofCap(6000), so build_hierarchy returns
    // empty and A1 (59049 DOF) is far past the cap -> refusal. Same story at
    // 60^3 (60->30->15 odd, 16^3 nodes = 12288 DOF).
    std::vector<Fixture> fs;
    Fixture a;
    a.name = "reject52^3 solid";
    a.ex = 52; a.ey = 52; a.ez = 52; a.occ = 1.0; a.hole = 0.0;
    fs.push_back(a);
    Fixture b;
    b.name = "reject60^3+bore0.30";
    b.ex = 60; b.ey = 60; b.ez = 60; b.occ = 1.0; b.hole = 0.30; b.hole_axis = 2;
    fs.push_back(b);
    for (const Fixture& f : fs) reps.push_back(run_case(f, tol, 60, 40000, true, opt));
  }

  if (mode == "healthy" || mode == "all") {
    std::printf(
        "\n\n### R3 — A HEALTHY GEOMETRIC-MG CASE (the control: geometric "
        "carries in ~11-40 cycles)\n"
        "Bar: AMG within ~2x of geometric's cycle count, else record a REGIME "
        "SPLIT.\n");
    std::vector<Fixture> fs;
    Fixture a;
    a.name = "solid_box_48";
    a.ex = 48; a.ey = 48; a.ez = 48; a.occ = 1.0; a.hole = 0.0;
    fs.push_back(a);
    Fixture b;
    b.name = "solid_box_64";
    b.ex = 64; b.ey = 64; b.ez = 64; b.occ = 1.0; b.hole = 0.0;
    fs.push_back(b);
    Fixture c;
    c.name = "solid_box_64+bore";
    c.ex = 64; c.ey = 64; c.ez = 64; c.occ = 1.0; c.hole = 0.40; c.hole_axis = 2;
    fs.push_back(c);
    for (const Fixture& f : fs) reps.push_back(run_case(f, tol, 60, 40000, true, opt));
  }

  if (mode == "hunt") {
    mode_hunt(tol);
    return 0;
  }

  // A SECOND point on the solve sequence: the same stagnation geometry carrying
  // a DEVELOPED-design-like density field (thin lattice + ~1e5 modulus
  // contrast) instead of the iteration-0 uniform field.
  if (mode == "developed" || mode == "all") {
    std::printf(
        "\n\n### R1b — THE SAME GEOMETRY, LATER IN THE SOLVE SEQUENCE\n"
        "Synthetic developed-design density (documented lattice, deterministic; "
        "NOT optimizer output) on the stagnation fixture: thin sub-coarse-cell "
        "members AND ~1.25e5 modulus contrast together.\n");
    Fixture d;
    d.name = "occ0.40+bore0.40 LATTICE";
    d.ex = 192; d.ey = 112; d.ez = 128; d.occ = 0.40; d.hole = 0.40;
    d.pattern = 1;
    reps.push_back(run_case(d, tol, 60, 20000, true, opt));
    Fixture e;
    e.name = "solid_box_48 LATTICE";
    e.ex = 48; e.ey = 48; e.ez = 48; e.occ = 1.0; e.hole = 0.0; e.pattern = 1;
    reps.push_back(run_case(e, tol, 60, 20000, true, opt));
  }
  if (mode == "sweep" || mode == "all") mode_sweep(tol);
  if (mode == "costs" || mode == "all") mode_costs(tol, opt);

  if (!reps.empty()) print_summary(reps);
  return 0;
}
