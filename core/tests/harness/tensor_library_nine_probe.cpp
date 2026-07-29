// tensor_library_nine_probe.cpp — extend the homogenized cubic-tensor LIBRARY
// from octet-only to the remaining nine strut topologies (task
// 2026-07-29-tensor-library-nine).
//
// THE THESIS (from the task): this is a REPEAT, not research. PR 198 built the
// periodic-homogenization probe (self-checked to machine precision); PR 234/237
// established the validation method and extended octet's band. This harness runs
// that SAME pipeline nine more times, over a TABLE of topologies instead of the
// one hand-written octet cell.
//
// Two pieces are fused here, both copied operation-for-operation from committed code:
//   (1) the TOPOLOGY TABLE — the integer node-basis + bond machinery of the
//       strut-lattice family study (evidence/2026-07-27-strut-lattice-family/
//       strut_lattice_gen.cpp): sc, bcc, bccz, fcc, fccz, octet, diamond, kelvin,
//       rhombic, reentrant. Each lattice is (S, canonical struts) with integer
//       coordinates in units of L/S, so the geometry is exact and octet through
//       this generic driver must reproduce PR 198's octet cell.
//   (2) the PERIODIC HOMOGENIZATION — lattice_band_extend_probe.cpp's `homogenize`
//       verbatim (production hex8_stiffness element, periodic BC, cubic 2-case fast
//       path with the C12 average-stress form). Solid self-check recovers E_solid
//       to machine precision (bar B1).
//
// The only NEW code is the PERIODIC VOXELIZER: for a general topology a strut runs
// between integer lattice sites that may leave the [0,1)^3 cell, so the distance
// field replicates each canonical strut over the 27 integer-shift neighbourhood and
// takes the min — the exact periodic solid the generator tiles. For octet this
// reproduces build_octet's field (cross-checked by reproducing octet's library rows).
//
// TRUTH throughout is the periodic tensor of the RESOLVED unit cell (resolution-clean,
// no free surface); "validate a row" == "the periodic tensor has CONVERGED in vpc"
// (drift vs a finer reference < 2.4%, PR 234/237's bar) AND the strut is resolved
// (>= 6 voxels across its DIAMETER, PR 198's floor). B4: NO PRODUCTION CHANGE here —
// this is the OFFLINE library; validated rows are emitted for the wiring PR.
//
// Standalone build, from core/:
//   cmake -S . -B build -DTOPOPT_USE_OCCT=OFF -DTOPOPT_BUILD_TESTS=OFF && \
//     cmake --build build --target topopt -j
//   c++ -std=c++17 -O2 -I include -I /opt/homebrew/include/eigen3 \
//       tests/harness/tensor_library_nine_probe.cpp build/libtopopt.a \
//       -o build/tensor_library_nine_probe
//
// Subcommands (argv[1]); one process per topology so peak RSS / time is that case's:
//   list                              per-cell strut/node counts for every topology
//   self  <topo>                      B1: solid cell recovers E_solid to 4 digits
//   sweep <topo>                      density sweep + resolution convergence + Zener
//
// Env: TOPOPT_LATTICE_CSV_DIR (CSV sink), TOPOPT_TL_VFS (target-rho list),
//   TOPOPT_TL_VPCS (resolution ladder, default 48,64), TOPOPT_TL_DRIFT_TOL (2.4),
//   TOPOPT_TL_VPS_TARGET (vox/strut floor, 6), TOPOPT_TL_TOL (CG tol, 1e-8),
//   TOPOPT_TL_L (cell edge mm, 5), TOPOPT_TL_ZENER_TOL (cubic-validity Zener band, see T3).

#include <Eigen/IterativeLinearSolvers>
#include <Eigen/Sparse>

#include <sys/resource.h>

#include <algorithm>
#include <array>
#include <chrono>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <functional>
#include <set>
#include <sstream>
#include <string>
#include <vector>

#include "topopt/fea.hpp"
#include "topopt/lattice.hpp"
#include "topopt/voxel.hpp"

using namespace topopt;

namespace {

constexpr double kE = 3500.0;   // PLA solid modulus (materials.json), MPa
constexpr double kNu = 0.33;    // PLA Poisson

double peak_rss_mb() {
  struct rusage ru;
  getrusage(RUSAGE_SELF, &ru);
  return double(ru.ru_maxrss) / (1024.0 * 1024.0);  // bytes on macOS
}

// ======================= topology table (strut-lattice family) ==============
// Integer lattice coordinate (units of L/S). Ported verbatim from the family study.
struct IV { int x, y, z; };
bool operator==(IV a, IV b) { return a.x == b.x && a.y == b.y && a.z == b.z; }
bool operator<(IV a, IV b) {
  if (a.x != b.x) return a.x < b.x;
  if (a.y != b.y) return a.y < b.y;
  return a.z < b.z;
}
IV operator+(IV a, IV b) { return {a.x + b.x, a.y + b.y, a.z + b.z}; }
long dist2(IV a, IV b) {
  long dx = a.x - b.x, dy = a.y - b.y, dz = a.z - b.z;
  return dx * dx + dy * dy + dz * dz;
}
struct Seg {
  IV a, b;
  Seg canonicalized() const { return (b < a) ? Seg{b, a} : Seg{a, b}; }
};
bool operator<(Seg s, Seg t) {
  if (!(s.a == t.a)) return s.a < t.a;
  return s.b < t.b;
}
struct Lattice {
  std::string name, blurb;
  int S = 1;
  std::vector<Seg> struts;  // canonical: midpoint in [0,S)^3
};

bool midpoint_in_cell(const Seg& s, int S) {
  auto ok = [S](int a, int b) { int m2 = a + b; return m2 >= 0 && m2 < 2 * S; };
  return ok(s.a.x, s.b.x) && ok(s.a.y, s.b.y) && ok(s.a.z, s.b.z);
}
std::vector<Seg> canonical_from_pairs(const std::vector<IV>& basis, int S,
                                      const std::function<bool(IV, IV)>& bond) {
  std::vector<IV> pts;
  for (int dz = -1; dz <= 1; ++dz)
    for (int dy = -1; dy <= 1; ++dy)
      for (int dx = -1; dx <= 1; ++dx)
        for (IV n : basis)
          pts.push_back({n.x + dx * S, n.y + dy * S, n.z + dz * S});
  std::set<Seg> uniq;
  for (std::size_t i = 0; i < pts.size(); ++i)
    for (std::size_t j = i + 1; j < pts.size(); ++j) {
      if (!bond(pts[i], pts[j])) continue;
      Seg s{pts[i], pts[j]};
      if (midpoint_in_cell(s, S)) uniq.insert(s.canonicalized());
    }
  return {uniq.begin(), uniq.end()};
}
std::vector<IV> corners_only(int) { return {{0, 0, 0}}; }
std::vector<IV> bcc_basis(int S) { return {{0, 0, 0}, {S / 2, S / 2, S / 2}}; }
std::vector<IV> fcc_basis(int S) {
  int h = S / 2;
  return {{0, 0, 0}, {h, h, 0}, {h, 0, h}, {0, h, h}};
}
std::vector<IV> diamond_basis(int S) {
  int q = S / 4, h = S / 2;
  return {{0, 0, 0},       {h, h, 0},       {h, 0, h},       {0, h, h},
          {q, q, q},       {q, 3 * q, 3 * q}, {3 * q, q, 3 * q}, {3 * q, 3 * q, q}};
}
bool is_corner(IV p, int S) { return p.x % S == 0 && p.y % S == 0 && p.z % S == 0; }
bool vertical_edge(IV a, IV b, int S) {
  return is_corner(a, S) && is_corner(b, S) && a.x == b.x && a.y == b.y &&
         std::abs(a.z - b.z) == S;
}
std::vector<Seg> canonical_from_polyhedra(const std::vector<IV>& centres, int S,
                                          const std::vector<IV>& verts_rel,
                                          long edge_d2) {
  std::set<Seg> uniq;
  for (int dz = -1; dz <= 1; ++dz)
    for (int dy = -1; dy <= 1; ++dy)
      for (int dx = -1; dx <= 1; ++dx)
        for (IV c : centres) {
          IV C{c.x + dx * S, c.y + dy * S, c.z + dz * S};
          std::vector<IV> v;
          v.reserve(verts_rel.size());
          for (IV r : verts_rel) v.push_back(C + r);
          for (std::size_t i = 0; i < v.size(); ++i)
            for (std::size_t j = i + 1; j < v.size(); ++j)
              if (dist2(v[i], v[j]) == edge_d2) {
                Seg s{v[i], v[j]};
                if (midpoint_in_cell(s, S)) uniq.insert(s.canonicalized());
              }
        }
  return {uniq.begin(), uniq.end()};
}
std::vector<IV> trunc_oct_verts() {
  std::set<std::array<int, 3>> S;
  int base[3] = {0, 1, 2}, perm[3] = {0, 1, 2};
  do {
    for (int s1 = -1; s1 <= 1; s1 += 2)
      for (int s2 = -1; s2 <= 1; s2 += 2) {
        std::array<int, 3> p{};
        for (int k = 0; k < 3; ++k) {
          int val = base[perm[k]];
          p[k] = val == 0 ? 0 : val == 1 ? s1 : 2 * s2;
        }
        S.insert(p);
      }
  } while (std::next_permutation(perm, perm + 3));
  std::vector<IV> out;
  for (auto& p : S) out.push_back({p[0], p[1], p[2]});
  return out;
}
std::vector<IV> rhombic_dodec_verts() {
  std::vector<IV> v;
  for (int s = -2; s <= 2; s += 4) {
    v.push_back({s, 0, 0}); v.push_back({0, s, 0}); v.push_back({0, 0, s});
  }
  for (int a = -1; a <= 1; a += 2)
    for (int b = -1; b <= 1; b += 2)
      for (int c = -1; c <= 1; c += 2) v.push_back({a, b, c});
  return v;
}
Lattice build_reentrant() {
  Lattice L;
  L.name = "reentrant";
  L.blurb = "re-entrant/auxetic: waist nodes pulled inward -> concave walls";
  L.S = 4;
  IV corners[8];
  int k = 0;
  for (int z = 0; z <= 4; z += 4)
    for (int y = 0; y <= 4; y += 4)
      for (int x = 0; x <= 4; x += 4) corners[k++] = {x, y, z};
  struct Waist { IV p; int axis; int side; };
  std::vector<Waist> waists = {{{1, 2, 2}, 0, 0}, {{3, 2, 2}, 0, 4},
                               {{2, 1, 2}, 1, 0}, {{2, 3, 2}, 1, 4}};
  std::set<Seg> uniq;
  for (auto& w : waists)
    for (auto& c : corners) {
      int cc = w.axis == 0 ? c.x : c.y;
      if (cc == w.side) {
        Seg s{w.p, c};
        if (midpoint_in_cell(s, L.S)) uniq.insert(s.canonicalized());
      }
    }
  for (auto& a : corners)
    for (auto& b : corners)
      if (vertical_edge(a, b, L.S)) {
        Seg s{a, b};
        if (midpoint_in_cell(s, L.S)) uniq.insert(s.canonicalized());
      }
  L.struts.assign(uniq.begin(), uniq.end());
  return L;
}
Lattice make_lattice(const std::string& n) {
  Lattice L;
  L.name = n;
  if (n == "sc") {
    L.blurb = "simple cubic: 3 orthogonal edges/cell (2 horizontal, 1 vertical)";
    L.S = 2;
    L.struts = canonical_from_pairs(corners_only(L.S), L.S,
        [S = L.S](IV a, IV b) { return dist2(a, b) == (long)S * S; });
  } else if (n == "bcc") {
    L.blurb = "body-centred cubic: 8 body diagonals, all at 54.7 deg";
    L.S = 2;
    L.struts = canonical_from_pairs(bcc_basis(L.S), L.S,
        [](IV a, IV b) { return dist2(a, b) == 3; });
  } else if (n == "bccz") {
    L.blurb = "BCC + vertical struts (adds the 0-deg columns BCC lacks)";
    L.S = 2;
    L.struts = canonical_from_pairs(bcc_basis(L.S), L.S,
        [S = L.S](IV a, IV b) { return dist2(a, b) == 3 || vertical_edge(a, b, S); });
  } else if (n == "fcc") {
    L.blurb = "FCC struts: corner<->face-centre legs only";
    L.S = 2;
    L.struts = canonical_from_pairs(fcc_basis(L.S), L.S, [S = L.S](IV a, IV b) {
      return dist2(a, b) == 2 && (is_corner(a, S) != is_corner(b, S));
    });
  } else if (n == "fccz") {
    L.blurb = "FCC legs + vertical struts";
    L.S = 2;
    L.struts = canonical_from_pairs(fcc_basis(L.S), L.S, [S = L.S](IV a, IV b) {
      return (dist2(a, b) == 2 && (is_corner(a, S) != is_corner(b, S))) ||
             vertical_edge(a, b, S);
    });
  } else if (n == "octet") {
    L.blurb = "octet truss: all 12 FCC nearest-neighbour bonds";
    L.S = 2;
    L.struts = canonical_from_pairs(fcc_basis(L.S), L.S,
        [](IV a, IV b) { return dist2(a, b) == 2; });
  } else if (n == "diamond") {
    L.blurb = "diamond cubic: 4-valent open network, all struts at 54.7 deg";
    L.S = 4;
    L.struts = canonical_from_pairs(diamond_basis(L.S), L.S,
        [](IV a, IV b) { return dist2(a, b) == 3; });
  } else if (n == "kelvin") {
    L.blurb = "Kelvin cell (truncated octahedron / BCC Voronoi), 24 struts/cell";
    L.S = 4;
    std::vector<IV> centres = {{0, 0, 0}, {2, 2, 2}};
    L.struts = canonical_from_polyhedra(centres, L.S, trunc_oct_verts(), 2);
  } else if (n == "rhombic") {
    L.blurb = "rhombic dodecahedron (FCC Voronoi), 32 struts/cell, all 54.7 deg";
    L.S = 4;
    L.struts = canonical_from_polyhedra(fcc_basis(L.S), L.S, rhombic_dodec_verts(), 3);
  } else if (n == "reentrant") {
    L = build_reentrant();
  } else {
    std::fprintf(stderr, "unknown lattice '%s'\n", n.c_str());
    std::exit(2);
  }
  return L;
}
const std::vector<std::string>& all_lattices() {
  static const std::vector<std::string> v = {"sc",   "bcc",     "bccz",  "fcc",
                                             "fccz", "octet",   "diamond",
                                             "kelvin", "rhombic", "reentrant"};
  return v;
}

// ======================= periodic voxelizer (NEW) ===========================
// Fractional strut endpoints in unit-cell coords [0,1], with the 27 integer-shift
// periodic images precomputed so the distance field wraps like the tiled solid.
struct FStrut { double ax, ay, az, bx, by, bz; };
std::vector<FStrut> periodic_fstruts(const Lattice& lat) {
  std::vector<FStrut> out;
  const double inv = 1.0 / lat.S;
  for (const Seg& s : lat.struts)
    for (int dz = -1; dz <= 1; ++dz)
      for (int dy = -1; dy <= 1; ++dy)
        for (int dx = -1; dx <= 1; ++dx)
          out.push_back({s.a.x * inv + dx, s.a.y * inv + dy, s.a.z * inv + dz,
                         s.b.x * inv + dx, s.b.y * inv + dy, s.b.z * inv + dz});
  return out;
}
double point_seg_dist2(double px, double py, double pz, const FStrut& s) {
  double ex = s.bx - s.ax, ey = s.by - s.ay, ez = s.bz - s.az;
  double len2 = ex * ex + ey * ey + ez * ez;
  double t = len2 > 0 ? ((px - s.ax) * ex + (py - s.ay) * ey + (pz - s.az) * ez) / len2 : 0.0;
  t = t < 0 ? 0 : (t > 1 ? 1 : t);
  double dx = px - (s.ax + t * ex), dy = py - (s.ay + t * ey), dz = pz - (s.az + t * ez);
  return dx * dx + dy * dy + dz * dz;
}
// r_unit is the strut radius in UNIT-cell units (i.e. r_mm / L). Voxelize one cell.
VoxelGrid build_cell(const std::vector<FStrut>& fs, double L, int vpc, double r_unit) {
  VoxelGrid g;
  g.nx = g.ny = g.nz = vpc;
  g.spacing = L / vpc;
  g.origin = Vec3{0, 0, 0};
  g.tags.assign((std::size_t)vpc * vpc * vpc, VoxelTag::Empty);
  const double r2 = r_unit * r_unit * L * L;  // compare in mm^2
  for (int k = 0; k < vpc; ++k)
    for (int j = 0; j < vpc; ++j)
      for (int i = 0; i < vpc; ++i) {
        // voxel centre in unit-cell coords
        double x = (i + 0.5) / vpc, y = (j + 0.5) / vpc, z = (k + 0.5) / vpc;
        double best = 1e30;
        for (const FStrut& s : fs) {
          double d2 = point_seg_dist2(x, y, z, s);
          if (d2 < best) best = d2;
        }
        if (best * L * L < r2) g.set_tag(i, j, k, VoxelTag::Interior);
      }
  return g;
}
double volume_fraction(const VoxelGrid& g) {
  return double(g.solid_count()) / double(g.voxel_count());
}
// Bisection on MEASURED (voxelized) rho: get near the target so rows land distinctly;
// the achieved rho is always REPORTED, never assumed (the aliasing staircase).
double calibrate_r_unit(const std::vector<FStrut>& fs, double L, double target_vf, int vpc) {
  double lo = 0.0005, hi = 0.9;  // unit-cell radius bounds
  for (int it = 0; it < 34; ++it) {
    double mid = 0.5 * (lo + hi);
    VoxelGrid g = build_cell(fs, L, vpc, mid);
    (volume_fraction(g) < target_vf ? lo : hi) = mid;
  }
  return 0.5 * (lo + hi);
}
// The shortest canonical strut length in unit-cell units — the member whose
// diameter must be resolved (vox/strut = 2*r_unit*vpc). Reported per topology so
// the vpc target is honest to the thinnest member, not the average.
double min_strut_len_unit(const Lattice& lat) {
  double best = 1e30;
  const double inv = 1.0 / lat.S;
  for (const Seg& s : lat.struts) {
    double dx = (s.a.x - s.b.x) * inv, dy = (s.a.y - s.b.y) * inv, dz = (s.a.z - s.b.z) * inv;
    double l = std::sqrt(dx * dx + dy * dy + dz * dz);
    if (l < best) best = l;
  }
  return best;
}

// ======================= periodic homogenization (PR 198/234/237) ===========
std::array<double, 576> ref_ke(double h) {
  Hex8Stiffness K = hex8_stiffness(kE, kNu, h);
  std::array<double, 576> out{};
  for (int i = 0; i < 576; ++i) out[i] = K.k[i];
  return out;
}
constexpr int kOff[8][3] = {{0,0,0},{1,0,0},{1,1,0},{0,1,0},
                            {0,0,1},{1,0,1},{1,1,1},{0,1,1}};
std::array<std::array<double, 6>, 24> element_chi0(double h) {
  std::array<std::array<double, 6>, 24> chi0{};
  for (int a = 0; a < 8; ++a) {
    double X = kOff[a][0] * h, Y = kOff[a][1] * h, Z = kOff[a][2] * h;
    int dx = 3 * a, dy = 3 * a + 1, dz = 3 * a + 2;
    chi0[dx][0] = X; chi0[dy][1] = Y; chi0[dz][2] = Z;
    chi0[dx][3] = Y; chi0[dy][4] = Z; chi0[dz][5] = X;
  }
  return chi0;
}
using SpMat = Eigen::SparseMatrix<double>;
using Trip = Eigen::Triplet<double>;
struct HomogResult {
  double CH[6][6] = {};
  int cg_iters_max = 0;
  bool converged = true;
  double solve_ms = 0;
  long ndof = 0, ndof_active = 0;
};
HomogResult homogenize(const VoxelGrid& grid, const std::vector<int>& cases, double cg_tol) {
  HomogResult R;
  const int nx = grid.nx, ny = grid.ny, nz = grid.nz;
  const double h = grid.spacing;
  const long Np = (long)nx * ny * nz, nd = 3 * Np;
  R.ndof = nd;
  auto ke = ref_ke(h);
  auto chi0 = element_chi0(h);
  auto pid = [&](int a, int b, int c) -> long {
    int aa = a % nx, bb = b % ny, cc = c % nz;
    return ((long)cc * ny + bb) * nx + aa;
  };
  std::vector<Trip> trips;
  trips.reserve((std::size_t)grid.solid_count() * 24 * 24);
  Eigen::MatrixXd F = Eigen::MatrixXd::Zero(nd, 6);
  std::vector<char> touched((std::size_t)nd, 0);
  for (int k = 0; k < nz; ++k)
    for (int j = 0; j < ny; ++j)
      for (int i = 0; i < nx; ++i) {
        if (!grid.solid(i, j, k)) continue;
        long gd[24];
        for (int a = 0; a < 8; ++a) {
          long p = pid(i + kOff[a][0], j + kOff[a][1], k + kOff[a][2]);
          gd[3 * a] = 3 * p; gd[3 * a + 1] = 3 * p + 1; gd[3 * a + 2] = 3 * p + 2;
        }
        for (int r = 0; r < 24; ++r) {
          touched[gd[r]] = 1;
          for (int c = 0; c < 24; ++c) trips.emplace_back((int)gd[r], (int)gd[c], ke[r * 24 + c]);
          for (int J : cases) {
            double f = 0;
            for (int c = 0; c < 24; ++c) f += ke[r * 24 + c] * chi0[c][J];
            F(gd[r], J) += f;
          }
        }
      }
  std::vector<char> pinned((std::size_t)nd, 0);
  pinned[0] = pinned[1] = pinned[2] = 1;
  long active = 0;
  for (long d = 0; d < nd; ++d) { if (touched[d]) ++active; else pinned[d] = 1; }
  R.ndof_active = active;
  SpMat K((int)nd, (int)nd);
  K.setFromTriplets(trips.begin(), trips.end());
  trips.clear(); trips.shrink_to_fit();
  for (int c = 0; c < K.outerSize(); ++c)
    for (SpMat::InnerIterator it(K, c); it; ++it)
      if (pinned[it.row()] || pinned[it.col()]) it.valueRef() = (it.row() == it.col()) ? 1.0 : 0.0;
  K.prune(0.0);
  for (long d = 0; d < nd; ++d) if (pinned[d]) for (int J : cases) F(d, J) = 0.0;
  Eigen::ConjugateGradient<SpMat, Eigen::Lower | Eigen::Upper> cg;
  cg.setTolerance(cg_tol);
  cg.setMaxIterations((int)std::min<long>(nd * 2, 300000));
  cg.compute(K);
  auto t0 = std::chrono::steady_clock::now();
  Eigen::MatrixXd X = Eigen::MatrixXd::Zero(nd, 6);
  for (int J : cases) {
    Eigen::VectorXd x = cg.solve(F.col(J));
    X.col(J) = x;
    R.cg_iters_max = std::max(R.cg_iters_max, (int)cg.iterations());
    if (cg.info() != Eigen::Success) R.converged = false;
  }
  auto t1 = std::chrono::steady_clock::now();
  R.solve_ms = std::chrono::duration<double, std::milli>(t1 - t0).count();
  const double vol = (double)nx * ny * nz * h * h * h;
  for (int k = 0; k < nz; ++k)
    for (int j = 0; j < ny; ++j)
      for (int i = 0; i < nx; ++i) {
        if (!grid.solid(i, j, k)) continue;
        long gd[24];
        for (int a = 0; a < 8; ++a) {
          long p = pid(i + kOff[a][0], j + kOff[a][1], k + kOff[a][2]);
          gd[3 * a] = 3 * p; gd[3 * a + 1] = 3 * p + 1; gd[3 * a + 2] = 3 * p + 2;
        }
        for (int J : cases) {
          double diffJ[24];
          for (int r = 0; r < 24; ++r) diffJ[r] = chi0[r][J] - X(gd[r], J);
          double kd[24];
          for (int r = 0; r < 24; ++r) {
            double s = 0;
            for (int c = 0; c < 24; ++c) s += ke[r * 24 + c] * diffJ[c];
            kd[r] = s;
          }
          for (int I = 0; I < 6; ++I) {
            double s = 0;
            for (int r = 0; r < 24; ++r) s += chi0[r][I] * kd[r];
            R.CH[I][J] += s / vol;
          }
        }
      }
  return R;
}
// A cubic READING of the effective tensor PLUS the two symmetry diagnostics that
// decide whether that reading is honest (T3). Voigt order here is [xx,yy,zz,xy,yz,zx]
// (element_chi0: case3=du_x/dy=xy, 4=du_y/dz=yz, 5=du_z/dx=zx).
struct Cubic {
  double C11 = 0, C12 = 0, C44 = 0, zener = 0, E100 = 0, offcubic = 0;
  // Symmetry diagnostics: a z-privileged lattice (vertical struts on z only:
  // bccz/fccz, or z-column auxetic) is TETRAGONAL, not cubic — C33 != C11 and the
  // xy shear differs from the yz/zx shear. A single cubic (C11,C12,C44) tensor
  // CANNOT represent that, so these ratios are the generate-but-not-certify gate.
  double C33 = 0;      // CH[2][2], the z axial constant
  double C44_yz = 0;   // CH[4][4], the yz shear (== zx by x<->y symmetry)
  double axial_aniso = 0;   // |C33/C11 - 1|  (0 for a cubic lattice)
  double shear_aniso = 0;   // |C44_yz/C44_xy - 1| (0 for a cubic lattice)
};
// Needs a HomogResult solved over cases {0,2,3,4} (gives CH00,CH22,CH33,CH44 and the
// C12/C13 couplings). The 2-case fast path {0,3} leaves C33/C44_yz at 0.
Cubic cubic_of(const HomogResult& R, bool full = false) {
  Cubic c;
  c.C11 = R.CH[0][0];
  c.C12 = 0.5 * (R.CH[1][0] + R.CH[2][0]);
  c.C44 = R.CH[3][3];               // xy shear
  c.C33 = R.CH[2][2];               // z axial
  c.C44_yz = R.CH[4][4];            // yz shear
  double d = c.C11 - c.C12;
  c.zener = d != 0 ? 2.0 * c.C44 / d : 0.0;
  double den = c.C11 + c.C12;
  c.E100 = den != 0 ? d * (c.C11 + 2 * c.C12) / den : 0.0;
  c.axial_aniso = c.C11 != 0 ? std::fabs(c.C33 / c.C11 - 1.0) : 0.0;
  c.shear_aniso = c.C44 != 0 ? std::fabs(c.C44_yz / c.C44 - 1.0) : 0.0;
  if (full) {
    double m = 0;
    for (int I = 0; I < 3; ++I)
      for (int J = 3; J < 6; ++J) m = std::max(m, std::fabs(R.CH[I][J]));
    c.offcubic = m;
  }
  return c;
}
double E100_of(double C11, double C12) {
  double d = C11 - C12, den = C11 + C12;
  return den != 0 ? d * (C11 + 2 * C12) / den : 0.0;
}

// ======================= env helpers ========================================
std::vector<double> env_doubles(const char* key, const std::vector<double>& def) {
  const char* s = std::getenv(key);
  if (!s) return def;
  std::vector<double> out; std::stringstream ss(s); std::string tok;
  while (std::getline(ss, tok, ',')) if (!tok.empty()) out.push_back(std::atof(tok.c_str()));
  return out.empty() ? def : out;
}
std::vector<int> env_ints(const char* key, const std::vector<int>& def) {
  const char* s = std::getenv(key);
  if (!s) return def;
  std::vector<int> out; std::stringstream ss(s); std::string tok;
  while (std::getline(ss, tok, ',')) if (!tok.empty()) out.push_back(std::atoi(tok.c_str()));
  return out.empty() ? def : out;
}
double env_double(const char* key, double def) { const char* s = std::getenv(key); return s ? std::atof(s) : def; }

FILE* csv_open(const std::string& name) {
  const char* dir = std::getenv("TOPOPT_LATTICE_CSV_DIR");
  if (!dir) return nullptr;
  std::string path = std::string(dir) + "/" + name;
  FILE* f = std::fopen(path.c_str(), "w");
  if (f) std::printf("  [writing %s]\n", path.c_str());
  return f;
}

// ======================= one matched-rho periodic row =======================
struct Row {
  double rho = 0, r_unit = 0, vps = 0;
  double C11 = 0, C12 = 0, C44 = 0, C33 = 0, C44_yz = 0, E100 = 0, zener = 0;
  double axial_aniso = 0, shear_aniso = 0;
  long ndof = 0, ndof_active = 0;
  int cg_iters = 0;
  double solve_ms = 0, rss_mb = 0;
  bool converged = true;
};
Row solve_matched(const Lattice& lat, const std::vector<FStrut>& fs, double L,
                  double target_vf, int vpc, double tol) {
  Row rs;
  rs.r_unit = calibrate_r_unit(fs, L, target_vf, vpc);
  VoxelGrid cell = build_cell(fs, L, vpc, rs.r_unit);
  rs.rho = volume_fraction(cell);
  rs.vps = 2.0 * rs.r_unit * vpc;  // strut DIAMETER in voxels (unit-cell radius * vpc * 2)
  HomogResult R = homogenize(cell, {0, 2, 3, 4}, tol);  // C11,C33,C44xy,C44yz + couplings
  Cubic c = cubic_of(R);
  rs.C11 = c.C11; rs.C12 = c.C12; rs.C44 = c.C44; rs.C33 = c.C33; rs.C44_yz = c.C44_yz;
  rs.E100 = c.E100; rs.zener = c.zener;
  rs.axial_aniso = c.axial_aniso; rs.shear_aniso = c.shear_aniso;
  rs.ndof = R.ndof; rs.ndof_active = R.ndof_active; rs.cg_iters = R.cg_iters_max;
  rs.solve_ms = R.solve_ms; rs.rss_mb = peak_rss_mb(); rs.converged = R.converged;
  return rs;
}
// Piecewise-linear interpolation of E100 over the (rho -> E100) reference curve at
// query rho `q`. THIS is the band-extension's clean resolution metric: comparing the
// coarse row to the fine curve at the coarse row's OWN measured rho removes the
// density-landing (aliasing-staircase) artefact that otherwise swamps the signal for
// a steep, anisotropic E(rho). Points must be sorted ascending in rho.
double interp_curve(const std::vector<std::pair<double, double>>& curve, double q) {
  if (curve.empty()) return 0.0;
  if (q <= curve.front().first) return curve.front().second;
  if (q >= curve.back().first) return curve.back().second;
  std::size_t a = 0;
  while (a + 1 < curve.size() && curve[a + 1].first < q) ++a;
  double x0 = curve[a].first, y0 = curve[a].second;
  double x1 = curve[a + 1].first, y1 = curve[a + 1].second;
  double t = x1 > x0 ? (q - x0) / (x1 - x0) : 0.0;
  return y0 + t * (y1 - y0);
}

// ================================ modes =====================================
int mode_list() {
  std::printf("TENSOR-LIBRARY-NINE — per-cell strut tables (L=%.0f mm basis)\n",
              env_double("TOPOPT_TL_L", 5.0));
  std::printf("%-10s %3s %7s %10s  %s\n", "lattice", "S", "struts", "min_len/L", "description");
  for (const auto& n : all_lattices()) {
    Lattice L = make_lattice(n);
    std::printf("%-10s %3d %7zu %10.4f  %s\n", L.name.c_str(), L.S, L.struts.size(),
                min_strut_len_unit(L), L.blurb.c_str());
  }
  return 0;
}

void mode_self(const std::string& name, double L) {
  Lattice lat = make_lattice(name);
  auto fs = periodic_fstruts(lat);
  std::printf("\n===== SELF (bar B1) — %s solid cell recovers E_solid to 4 digits =====\n",
              name.c_str());
  FILE* csv = csv_open(name + "_self.csv");
  if (csv) std::fprintf(csv, "vpc,E100_MPa,rel_err,zener,offcubic,verdict\n");
  for (int vpc : {8, 16, 24}) {
    VoxelGrid g = build_cell(fs, L, vpc, 5.0);  // huge radius -> all solid
    if (volume_fraction(g) < 0.999999) { std::printf("  vpc%-3d NOT fully solid\n", vpc); continue; }
    Cubic c = cubic_of(homogenize(g, {0, 1, 2, 3, 4, 5}, 1e-11), true);
    double relE = (c.E100 - kE) / kE;
    bool pass = std::fabs(relE) < 1e-4;
    std::printf("  vpc%-3d solid: E100=%.4f MPa (E_solid=%.1f)  rel=%+.6f  Zener=%.4f  offcubic=%.2e -> %s\n",
                vpc, c.E100, kE, relE, c.zener, c.offcubic, pass ? "PASS" : "CHECK");
    if (csv) std::fprintf(csv, "%d,%.4f,%+.6e,%.4f,%.3e,%s\n", vpc, c.E100, relE, c.zener, c.offcubic, pass ? "PASS" : "CHECK");
  }
  if (csv) std::fclose(csv);
}

void mode_sweep(const std::string& name, double L) {
  Lattice lat = make_lattice(name);
  auto fs = periodic_fstruts(lat);
  std::vector<double> vfs = env_doubles("TOPOPT_TL_VFS",
      {0.10, 0.15, 0.20, 0.30, 0.40, 0.50, 0.60});
  std::vector<int> vpcs = env_ints("TOPOPT_TL_VPCS", {48, 64});
  const double drift_tol = env_double("TOPOPT_TL_DRIFT_TOL", 2.4);
  const double vps_target = env_double("TOPOPT_TL_VPS_TARGET", 6.0);
  const double tetra_tol = env_double("TOPOPT_TL_TETRA_TOL", 2.4);  // C33/C11 & shear band
  const double tol = env_double("TOPOPT_TL_TOL", 1e-8);
  const int vpc_row = vpcs.front();   // row resolution (matches octet library basis, 48)
  const int vpc_ref = vpcs.back();    // finest = convergence reference

  std::printf("\n===== SWEEP %s — density sweep + resolution convergence + symmetry =====\n",
              name.c_str());
  std::printf("  L=%.0f mm, %zu struts/cell, min strut len = %.4f L.\n",
              L, lat.struts.size(), min_strut_len_unit(lat));
  std::printf("  truth = periodic homogenization; row @ vpc%d vs reference curve @ vpc%d,\n"
              "  drift = row E100 vs the vpc%d curve interpolated to the ROW's own rho\n"
              "  (band-extension clean metric — removes the density-landing artefact).\n",
              vpc_row, vpc_ref, vpc_ref);
  std::printf("  VALIDATED := |drift| < %.1f%% AND vox/strut >= %.0f AND converged.\n",
              drift_tol, vps_target);
  std::printf("  CUBIC := axial |C33/C11-1| < %.1f%% AND shear |Cyz/Cxy-1| < %.1f%%\n"
              "  (else TETRAGONAL: a cubic (C11,C12,C44) tensor cannot represent it).\n\n",
              tetra_tol, tetra_tol);

  // Reference curve first (vpc_ref), sorted by measured rho.
  std::vector<Row> refs;
  for (double tvf : vfs) refs.push_back(solve_matched(lat, fs, L, tvf, vpc_ref, tol));
  std::vector<std::pair<double, double>> refE;
  for (const Row& r : refs) refE.push_back({r.rho, r.E100});
  std::sort(refE.begin(), refE.end());

  FILE* csv = csv_open(name + "_sweep.csv");
  if (csv) std::fprintf(csv, "target_vf,vpc_row,vpc_ref,rho_row,rho_ref,r_unit,vox_per_strut,"
                             "C11,C12,C44_xy,C33,C44_yz,E100_row_MPa,E100_ref_interp_MPa,drift_pct,"
                             "zener,axial_aniso_pct,shear_aniso_pct,cubic,ndof_active,cg_iters,"
                             "solve_ms,peak_rss_mb,converged,validated\n");
  std::printf("  %-6s %-8s %-7s %-8s %-8s %-8s %-7s %-7s %-6s %-6s %s\n",
              "vf", "rho", "vox/str", "E100", "drift%", "zener", "C33/C11", "Cyz/xy", "cubic", "cg", "row");

  double lo_valid = 1e9, hi_valid = -1e9, zmin = 1e9, zmax = -1e9;
  double max_axial = 0, max_shear = 0;
  int n_valid = 0;
  for (std::size_t i = 0; i < vfs.size(); ++i) {
    Row row = solve_matched(lat, fs, L, vfs[i], vpc_row, tol);
    Row& ref = refs[i];
    double e_ref_at_row = (vpc_ref == vpc_row) ? row.E100 : interp_curve(refE, row.rho);
    double drift = e_ref_at_row != 0 ? 100.0 * (row.E100 - e_ref_at_row) / e_ref_at_row : 0.0;
    bool cubic = row.axial_aniso * 100 < tetra_tol && row.shear_aniso * 100 < tetra_tol;
    bool valid = std::fabs(drift) < drift_tol && row.vps >= vps_target && row.converged;
    if (valid) { lo_valid = std::min(lo_valid, row.rho); hi_valid = std::max(hi_valid, row.rho); ++n_valid; }
    zmin = std::min(zmin, row.zener); zmax = std::max(zmax, row.zener);
    max_axial = std::max(max_axial, row.axial_aniso);
    max_shear = std::max(max_shear, row.shear_aniso);
    std::printf("  %-6.3f %-8.4f %-7.2f %-8.1f %-+8.2f %-8.3f %-7.3f %-7.3f %-6s %-6d %s\n",
                vfs[i], row.rho, row.vps, row.E100, drift, row.zener,
                row.C33 / row.C11, row.C44 != 0 ? row.C44_yz / row.C44 : 0.0,
                cubic ? "yes" : "NO", row.cg_iters, valid ? "VALID" : "-");
    if (csv) std::fprintf(csv, "%.3f,%d,%d,%.5f,%.5f,%.6f,%.3f,%.4f,%.4f,%.4f,%.4f,%.4f,%.4f,%.4f,%+.3f,"
                               "%.4f,%.3f,%.3f,%d,%ld,%d,%.0f,%.1f,%d,%d\n",
                          vfs[i], vpc_row, vpc_ref, row.rho, ref.rho, row.r_unit, row.vps,
                          row.C11, row.C12, row.C44, row.C33, row.C44_yz, row.E100, e_ref_at_row, drift,
                          row.zener, row.axial_aniso * 100, row.shear_aniso * 100, cubic ? 1 : 0,
                          row.ndof_active, row.cg_iters, row.solve_ms, row.rss_mb,
                          row.converged ? 1 : 0, valid ? 1 : 0);
  }
  if (csv) std::fclose(csv);
  bool topo_cubic = max_axial * 100 < tetra_tol && max_shear * 100 < tetra_tol;
  std::printf("\n  VALIDATED BAND: rho [%.4f, %.4f]  (%d of %zu rows: drift<%.1f%% & vox/strut>=%.0f)\n",
              n_valid ? lo_valid : 0.0, n_valid ? hi_valid : 0.0, n_valid, vfs.size(), drift_tol, vps_target);
  std::printf("  ZENER across sweep: [%.3f, %.3f]  (octet-legs reference 1.06-1.55).\n", zmin, zmax);
  std::printf("  SYMMETRY: max |C33/C11-1| = %.1f%%, max |Cyz/Cxy-1| = %.1f%%  ->  %s\n",
              max_axial * 100, max_shear * 100,
              topo_cubic ? "CUBIC (cubic tensor is exact; certifiable)"
                         : "*** TETRAGONAL — cubic library MISREPRESENTS it: generate-but-NOT-certify ***");
}

}  // namespace

int main(int argc, char** argv) {
  std::setvbuf(stdout, nullptr, _IONBF, 0);
  const double L = env_double("TOPOPT_TL_L", 5.0);
  if (argc < 2) {
    std::fprintf(stderr, "usage: %s {list|self <topo>|sweep <topo>}\n", argv[0]);
    return 2;
  }
  std::string cmd = argv[1];
  if (cmd == "list") return mode_list();
  if (argc < 3) { std::fprintf(stderr, "need a topology name\n"); return 2; }
  std::string topo = argv[2];
  std::printf("TENSOR-LIBRARY-NINE PROBE — E_solid=%.0f MPa nu=%.2f, %s, L=%.0f mm\n",
              kE, kNu, topo.c_str(), L);
  if (cmd == "self")  { mode_self(topo, L); std::printf("\nDONE.\n"); return 0; }
  if (cmd == "sweep") { mode_sweep(topo, L); std::printf("\nDONE.\n"); return 0; }
  std::fprintf(stderr, "unknown subcommand: %s\n", cmd.c_str());
  return 2;
}
