// flexible_squish_fe.cpp — ONE squeeze group's squish as a 3D displacement field (task
// 2026-09-29-flexible-screens, round 5 batch G). See flexible_squish_fe.hpp and the header
// section "BATCH G" of FlexibleBridge.hpp.
//
// ★ WHAT IS THE APP'S AND WHAT IS CORE'S. Core's: the grid (the scene's own voxelize), the
// squish curves (curve_set / stress_at), the frames and stacks (the pressures' columns), the
// face regions' voxels (cut_voxels) and the SOLVER (fea_solve_mgcg_matfree, graded, with its
// matrix-free apply for the reaction check). The app's (here): the per-voxel modulus law, the
// coarsening rule, the loads by column pressure, the boundary conditions (held rests, the
// linked other end, or inertia relief + 3-2-1 for a squeeze nothing rests against), the rigid
// removal and the extension of the field outside the solid. Core brief (handoff): a
// flexible::squish_field API that owns all of this.
//
// ★ POSTURE. The matrix-free ApplyPool is process-global and "assumes applies are not issued
// concurrently" (matfree.cpp): the display solve runs with ONE thread (restored after), under a
// bridge mutex (never two at once), with the parity pad AUTO, the algebraic level 1 OFF, the
// stagnation latch and the Krylov recycle space reset (thread-local; GCD reuses threads) and a
// deadline armed (disarmed after). Every failure is a value (ok = false, core's words).

#include "flexible_squish_fe.hpp"

#include <algorithm>
#include <array>
#include <cmath>
#include <cstdint>
#include <limits>
#include <mutex>
#include <stdexcept>
#include <string>
#include <utility>
#include <vector>

#include "topopt/fea.hpp"
#include "topopt/flexible/squish.hpp"
#include "topopt/observability.hpp"

namespace topoptbridge {
namespace squishfe {
namespace {

namespace fx = topopt::flexible;
using topopt::Vec3;

// The reference strain of a voxel no stack of this group presses: below core's first tabulated
// strain, where row_stress is linear from (0, 0) — the INITIAL modulus.
constexpr double kEpsRef = 0.05;
constexpr double kEpsMin = 0.02;
// Iacob's specimen: 12.5 mm high, 1.6 mm of skins — core's loader converts nominal to core strain
// by 12.5 / 10.9 (data.cpp). Used ONLY by the test control 256 (the law read on the nominal axis).
constexpr double kNominalToCore = 12.5 / 10.9;
// ★ THE SOLVE IS BOUNDED BY WORK TOO, not only by its deadline. Core polls the deadline once every
// 256 CG iterations, so a solve that crawls (a loaded or slow device) could run far past its 20 s
// budget (measured: ~150 s under heavy CPU load) before the poll. Core gives multigrid at most 300
// V-cycles whatever the cap, then restarts Jacobi-CG from zero; the cap bounds THAT. A fixed 600
// failed the M2 stand (64 × 16 × 59, 13 287 elements, all lattice, E 0.16–34 MPa): multigrid
// stagnates there and Jacobi-CG needs 2 556 iterations for 1e-4. So the cap is a WORK budget —
// elements × Jacobi-CG iterations, ~4 s of Jacobi on an M2 Pro — never under 600 (his pad: 939;
// the M2 stand: 3 763). Past it core's non-convergence is a value (the column squish plays).
constexpr int kMinIterations = 600;
constexpr int kMaxIterationsCap = 20000;
constexpr double kIterationWork = 5.0e7;
int iteration_cap(long long elements) {
  const double by_work = kIterationWork / static_cast<double>(std::max<long long>(elements, 1));
  return static_cast<int>(std::clamp(by_work, static_cast<double>(kMinIterations), static_cast<double>(kMaxIterationsCap)));
}

enum Control : int {
  kPoissonZero = 1,
  kAnchorPatch = 2,
  kIgnoreCuts = 4,
  kUniformPressure = 8,
  kUniformE = 16,
  kLatticeSolid = 32,
  kNoExtension = 64,
  kRollerRest = 128,
  kNominalStrain = 256,
  kOtherAnchors = 512,
  kUnprojected = 1024,
  kBondedRests = 2048,
  kLongSolve = 4096,
  kFixedCap = 8192,
  kKeepGlobals = 16384,
};

std::mutex g_squish_fe_mu;

Vec3 add(const Vec3& a, const Vec3& b) { return {a.x + b.x, a.y + b.y, a.z + b.z}; }
Vec3 sub(const Vec3& a, const Vec3& b) { return {a.x - b.x, a.y - b.y, a.z - b.z}; }
Vec3 mul(const Vec3& a, double s) { return {a.x * s, a.y * s, a.z * s}; }
double dot(const Vec3& a, const Vec3& b) { return a.x * b.x + a.y * b.y + a.z * b.z; }
Vec3 cross(const Vec3& a, const Vec3& b) {
  return {a.y * b.z - a.z * b.y, a.z * b.x - a.x * b.z, a.x * b.y - a.y * b.x};
}
double norm(const Vec3& a) { return std::sqrt(dot(a, a)); }
double comp(const Vec3& a, int c) { return c == 0 ? a.x : (c == 1 ? a.y : a.z); }

// ── the law (§1.2) ─────────────────────────────────────────────────────────────────────
struct Law {
  bool relative = false;  // shape only (or the curve set refused): E_s = 1, E_lat = max(ρ, .05)²
  fx::CurveSet set;
  double es = 1.0;

  double lattice(double rho, double strain, int control) const {
    if (relative) {
      const double r = std::max(rho, 0.05);
      return r * r;
    }
    const double r = std::min(std::max(rho, set.density_min()), set.density_max());
    const double lim = set.strain_limit();
    const double eps = strain > 0.0 ? std::min(std::max(strain, kEpsMin), lim) : kEpsRef;
    // control 256: the table's NOMINAL strain axis (no skin correction) — the wrong law
    const double at = (control & kNominalStrain) ? std::min(eps * kNominalToCore, lim) : eps;
    const fx::StressResult s = fx::stress_at(set, at, r);
    return s.ok && s.stress_mpa > 0.0 ? s.stress_mpa / eps : 0.0;
  }

  double voxel(double rho, double strain, double skin, int control) const {
    if (rho < 0.0 || (control & kLatticeSolid)) return es;
    const double f = std::min(1.0, std::max(0.0, skin));
    const double e = f * es + (1.0 - f) * lattice(rho, strain, control);
    return std::max(e, 1e-4 * es);
  }
};

Law make_law(const FlexSquishLaw& in, const fx::FlexibleData& data) {
  Law L;
  L.relative = in.shape_only;
  if (!L.relative) {
    const fx::CurveSetResult r = fx::curve_set(data, in.material_id, in.temp_c, in.topology);
    if (r.refusal.refused()) {
      L.relative = true;
    } else {
      L.set = r.set;
    }
  }
  if (L.relative) {
    L.es = 1.0;
    return L;
  }
  const auto it = data.catalogue.materials.find(in.material_id);
  if (it != data.catalogue.materials.end() && it->second.solid_youngs_modulus_mpa.known &&
      it->second.solid_youngs_modulus_mpa.value_mpa > 0.0) {
    L.es = it->second.solid_youngs_modulus_mpa.value_mpa;
  } else {
    // unknown solid modulus on a filament with curves: 20 × the firmest lattice's initial
    // modulus (NOT flagged in the solution; no current filament hits it)
    Law probe = L;
    probe.es = 1.0;
    L.es = 20.0 * probe.lattice(L.set.density_max(), 0.0, 0);
  }
  return L;
}

// ── core's point–triangle distance (face_region.cpp, copied verbatim so the slab is core's
// region_member_voxels to the rounding) with a bounding-box cull per triangle ─────────────
double point_tri_dist2(const Vec3& p, const Vec3& a, const Vec3& b, const Vec3& c) {
  auto axpy = [](const Vec3& base, double t, const Vec3& dir) {
    return Vec3{base.x + t * dir.x, base.y + t * dir.y, base.z + t * dir.z};
  };
  const Vec3 ab = sub(b, a);
  const Vec3 ac = sub(c, a);
  const Vec3 ap = sub(p, a);
  const double d1 = dot(ab, ap);
  const double d2 = dot(ac, ap);
  Vec3 q;
  if (d1 <= 0.0 && d2 <= 0.0) {
    q = a;
  } else {
    const Vec3 bp = sub(p, b);
    const double d3 = dot(ab, bp);
    const double d4 = dot(ac, bp);
    if (d3 >= 0.0 && d4 <= d3) {
      q = b;
    } else {
      const Vec3 cp = sub(p, c);
      const double d5 = dot(ab, cp);
      const double d6 = dot(ac, cp);
      const double vc = d1 * d4 - d3 * d2;
      const double vb = d5 * d2 - d1 * d6;
      const double va = d3 * d6 - d5 * d4;
      if (vc <= 0.0 && d1 >= 0.0 && d3 <= 0.0) {
        q = axpy(a, d1 / (d1 - d3), ab);
      } else if (d6 >= 0.0 && d5 <= d6) {
        q = c;
      } else if (vb <= 0.0 && d2 >= 0.0 && d6 <= 0.0) {
        q = axpy(a, d2 / (d2 - d6), ac);
      } else if (va <= 0.0 && (d4 - d3) >= 0.0 && (d5 - d6) >= 0.0) {
        q = axpy(b, (d4 - d3) / ((d4 - d3) + (d5 - d6)), sub(c, b));
      } else {
        const double denom = 1.0 / (va + vb + vc);
        q = axpy(axpy(a, vb * denom, ab), vc * denom, ac);
      }
    }
  }
  const Vec3 d = sub(p, q);
  return dot(d, d);
}

// region_member_voxels(grid, model, region, 1): the SOLID voxels whose centres lie within half a
// voxel of the region's member triangles (core's rule), ascending grid index.
std::vector<int> member_voxels(const topopt::VoxelGrid& g, const topopt::StepModel& model,
                               const std::vector<int>& triangles) {
  const double h = g.spacing;
  const double thr = 0.5 * h;
  const double thr2 = thr * thr;
  const double eps = 1e-9 * h * h;
  std::vector<char> hit(g.voxel_count(), 0);
  for (int t : triangles) {
    const auto& tri = model.mesh.triangles[static_cast<std::size_t>(t)];
    const Vec3& a = model.mesh.vertices[static_cast<std::size_t>(tri[0])];
    const Vec3& b = model.mesh.vertices[static_cast<std::size_t>(tri[1])];
    const Vec3& c = model.mesh.vertices[static_cast<std::size_t>(tri[2])];
    auto range = [&](double lo, double hi, double o, int n, int& i0, int& i1) {
      // voxel centres o + (i + ½)h within [lo − thr, hi + thr]
      i0 = std::max(0, static_cast<int>(std::floor((lo - thr - o) / h - 0.5)) - 1);
      i1 = std::min(n - 1, static_cast<int>(std::ceil((hi + thr - o) / h - 0.5)) + 1);
    };
    int i0, i1, j0, j1, k0, k1;
    range(std::min({a.x, b.x, c.x}), std::max({a.x, b.x, c.x}), g.origin.x, g.nx, i0, i1);
    range(std::min({a.y, b.y, c.y}), std::max({a.y, b.y, c.y}), g.origin.y, g.ny, j0, j1);
    range(std::min({a.z, b.z, c.z}), std::max({a.z, b.z, c.z}), g.origin.z, g.nz, k0, k1);
    for (int k = k0; k <= k1; ++k)
      for (int j = j0; j <= j1; ++j)
        for (int i = i0; i <= i1; ++i) {
          const std::size_t v = g.index(i, j, k);
          if (hit[v] || !g.solid(i, j, k)) continue;
          if (point_tri_dist2(g.voxel_center(i, j, k), a, b, c) <= thr2 + eps) hit[v] = 1;
        }
  }
  std::vector<int> out;
  for (std::size_t v = 0; v < hit.size(); ++v)
    if (hit[v]) out.push_back(static_cast<int>(v));
  return out;
}

bool passes(const std::vector<topopt::RegionCut>& cuts, const Vec3& p) {
  for (const auto& c : cuts) {
    const double s = dot(sub(p, c.point), c.normal);
    if (c.strict ? !(s > 0.0) : !(s >= 0.0)) return false;
  }
  return true;
}

// The area-weighted OUTWARD normal of `triangles` (the part is outward-wound) whose centroids
// pass `cuts`.
Vec3 outward_normal(const topopt::StepModel& model, const std::vector<int>& triangles,
                    const std::vector<topopt::RegionCut>& cuts) {
  Vec3 n{0, 0, 0};
  for (int t : triangles) {
    const auto& tri = model.mesh.triangles[static_cast<std::size_t>(t)];
    const Vec3& a = model.mesh.vertices[static_cast<std::size_t>(tri[0])];
    const Vec3& b = model.mesh.vertices[static_cast<std::size_t>(tri[1])];
    const Vec3& c = model.mesh.vertices[static_cast<std::size_t>(tri[2])];
    if (!cuts.empty() && !passes(cuts, mul(add(add(a, b), c), 1.0 / 3.0))) continue;
    n = add(n, cross(sub(b, a), sub(c, a)));
  }
  const double l = norm(n);
  return l > 0.0 ? mul(n, 1.0 / l) : Vec3{0, 0, 0};
}

// ── the FE grid (§1.1) ───────────────────────────────────────────────────────────────
struct FE {
  topopt::VoxelGrid g;
  std::vector<double> E;
  int c = 1;
  int nnx = 0, nny = 0, nnz = 0;  // node counts
  std::size_t nodes() const {
    return static_cast<std::size_t>(nnx) * static_cast<std::size_t>(nny) * static_cast<std::size_t>(nnz);
  }
  int node(int a, int b, int cc) const { return (cc * nny + b) * nnx + a; }
  Vec3 pos(int n) const {
    const int a = n % nnx, b = (n / nnx) % nny, cc = n / (nnx * nny);
    return {g.origin.x + a * g.spacing, g.origin.y + b * g.spacing, g.origin.z + cc * g.spacing};
  }
  bool solid(int i, int j, int k) const {
    return i >= 0 && j >= 0 && k >= 0 && i < g.nx && j < g.ny && k < g.nz && g.solid(i, j, k);
  }
};

const int kDir[6][3] = {{1, 0, 0}, {-1, 0, 0}, {0, 1, 0}, {0, -1, 0}, {0, 0, 1}, {0, 0, -1}};

// The four corner nodes of voxel (i, j, k)'s cell face in direction d.
std::array<int, 4> face_nodes(const FE& fe, int i, int j, int k, int d) {
  const int ax = d / 2, pos = (d % 2 == 0) ? 1 : 0;
  std::array<int, 4> out{};
  int n = 0;
  for (int s = 0; s < 2; ++s)
    for (int t = 0; t < 2; ++t) {
      int o[3] = {0, 0, 0};
      o[ax] = pos;
      o[(ax + 1) % 3] = s;
      o[(ax + 2) % 3] = t;
      out[static_cast<std::size_t>(n++)] = fe.node(i + o[0], j + o[1], k + o[2]);
    }
  return out;
}

// ── small dense solves ───────────────────────────────────────────────────────────────
// Gaussian elimination with partial pivoting on an n×n system (row-major). Returns the rank
// reached (n when solved).
int gauss(std::vector<double> A, std::vector<double>& b, int n) {
  double scale = 0.0;
  for (double v : A) scale = std::max(scale, std::fabs(v));
  const double tol = 1e-12 * std::max(scale, 1e-300);
  int rank = 0;
  for (int col = 0; col < n; ++col) {
    int piv = -1;
    double best = tol;
    for (int r = col; r < n; ++r)
      if (std::fabs(A[r * n + col]) > best) { best = std::fabs(A[r * n + col]); piv = r; }
    if (piv < 0) return rank;
    if (piv != col) {
      for (int k = 0; k < n; ++k) std::swap(A[col * n + k], A[piv * n + k]);
      if (!b.empty()) std::swap(b[col], b[piv]);
    }
    ++rank;
    for (int r = col + 1; r < n; ++r) {
      const double f = A[r * n + col] / A[col * n + col];
      if (f == 0.0) continue;
      for (int k = col; k < n; ++k) A[r * n + k] -= f * A[col * n + k];
      if (!b.empty()) b[r] -= f * b[col];
    }
  }
  if (!b.empty()) {
    for (int r = n - 1; r >= 0; --r) {
      double s = b[r];
      for (int k = r + 1; k < n; ++k) s -= A[r * n + k] * b[k];
      b[r] = s / A[r * n + r];
    }
  }
  return rank;
}

// The eigenvectors of a symmetric 6×6 matrix whose eigenvalues are (relatively) zero — the
// rigid modes a set of constraint rows leaves free. Cyclic Jacobi rotations.
std::vector<std::vector<double>> null_modes(std::vector<double> A) {
  std::vector<double> V(36, 0.0);
  for (int i = 0; i < 6; ++i) V[i * 6 + i] = 1.0;
  for (int sweep = 0; sweep < 60; ++sweep) {
    double off = 0.0;
    for (int p = 0; p < 6; ++p)
      for (int q = p + 1; q < 6; ++q) off += A[p * 6 + q] * A[p * 6 + q];
    if (off < 1e-30) break;
    for (int p = 0; p < 6; ++p)
      for (int q = p + 1; q < 6; ++q) {
        const double apq = A[p * 6 + q];
        if (std::fabs(apq) < 1e-300) continue;
        const double theta = (A[q * 6 + q] - A[p * 6 + p]) / (2.0 * apq);
        const double t = (theta >= 0 ? 1.0 : -1.0) / (std::fabs(theta) + std::sqrt(theta * theta + 1.0));
        const double c = 1.0 / std::sqrt(t * t + 1.0), sn = t * c;
        for (int k = 0; k < 6; ++k) {
          const double akp = A[k * 6 + p], akq = A[k * 6 + q];
          A[k * 6 + p] = c * akp - sn * akq;
          A[k * 6 + q] = sn * akp + c * akq;
        }
        for (int k = 0; k < 6; ++k) {
          const double apk = A[p * 6 + k], aqk = A[q * 6 + k];
          A[p * 6 + k] = c * apk - sn * aqk;
          A[q * 6 + k] = sn * apk + c * aqk;
        }
        for (int k = 0; k < 6; ++k) {
          const double vkp = V[k * 6 + p], vkq = V[k * 6 + q];
          V[k * 6 + p] = c * vkp - sn * vkq;
          V[k * 6 + q] = sn * vkp + c * vkq;
        }
      }
  }
  double top = 0.0;
  for (int i = 0; i < 6; ++i) top = std::max(top, A[i * 6 + i]);
  const double tol = 1e-8 * std::max(top, 1.0);
  std::vector<std::vector<double>> out;
  for (int i = 0; i < 6; ++i) {
    if (A[i * 6 + i] > tol) continue;
    std::vector<double> v(6);
    for (int k = 0; k < 6; ++k) v[static_cast<std::size_t>(k)] = V[k * 6 + i];
    out.push_back(v);
  }
  return out;
}

// ── the posture (RAII) ───────────────────────────────────────────────────────────────
// ★ A TOPOLOGY RUN LEAVES CORE'S PRODUCTION TOGGLES ARMED FOR THE PROCESS (found in the suite:
// configure_production_options arms the GenEO two-level deflation and Krylov recycling, and
// nothing disarms them). The squish sim's Jacobi-CG fallback then built a GenEO eigenbasis
// (LOBPCG) for its own system: 73 s on the M2 stand, which solves in 3.9 s without it. The
// posture pins both OFF for the sim and gives them back (control 16384 leaves them as found).
struct Posture {
  int prev_threads = 0;
  int prev_pad = 1;
  bool prev_alg = false;
  bool prev_geneo = false;
  bool prev_recycling = false;
  bool keep_globals = false;
  double prev_deadline = 0.0;
  explicit Posture(double deadline_abs_ms, bool keep = false) : keep_globals(keep) {
    prev_threads = topopt::fea_set_matfree_threads(1);
    prev_pad = topopt::fea_mg_parity_pad_mode();
    topopt::fea_set_mg_parity_pad_mode(1);
    prev_alg = topopt::fea_set_mg_algebraic_level1(false);
    if (!keep_globals) {
      prev_geneo = topopt::fea_set_geneo_twolevel(false);
      prev_recycling = topopt::fea_set_krylov_recycling(false);
    }
    topopt::fea_matfree_reset_mg_stagnation_latch();
    topopt::fea_reset_krylov_recycle_space();
    prev_deadline = topopt::fea_set_solve_deadline_ms(deadline_abs_ms);
  }
  ~Posture() {
    topopt::fea_set_solve_deadline_ms(prev_deadline);
    topopt::fea_matfree_reset_mg_stagnation_latch();
    topopt::fea_reset_krylov_recycle_space();
    if (!keep_globals) {
      topopt::fea_set_krylov_recycling(prev_recycling);
      topopt::fea_set_geneo_twolevel(prev_geneo);
    }
    topopt::fea_set_mg_algebraic_level1(prev_alg);
    topopt::fea_set_mg_parity_pad_mode(prev_pad);
    topopt::fea_set_matfree_threads(prev_threads);
  }
  Posture(const Posture&) = delete;
  Posture& operator=(const Posture&) = delete;
};

}  // namespace

int coarsen(int nx, int ny, int nz) {
  const long long box = static_cast<long long>(std::max(nx, 0)) * std::max(ny, 0) * std::max(nz, 0);
  if (box <= 120000) return 1;
  if (box <= 960000) return 2;
  return 4;
}

double modulus(const FlexSquishLaw& law, const fx::FlexibleData& data, double rho, double strain,
               double skin_frac, int control) {
  return make_law(law, data).voxel(rho, strain, skin_frac, control);
}

FlexSquishSolution solve(const Setup& s, const FlexSquishRequest& req, const fx::FlexibleData& data) {
  FlexSquishSolution out;
  const double t0 = topopt::steady_clock_ms();
  const topopt::VoxelGrid& sg = s.grid;
  const std::size_t nvox = sg.voxel_count();
  if (req.rho.size() != nvox || req.strain_op.size() != nvox || req.skin_frac.size() != nvox)
    throw std::invalid_argument("squish sim: the per-voxel arrays have " + std::to_string(req.rho.size()) + " / " +
                                std::to_string(req.strain_op.size()) + " / " + std::to_string(req.skin_frac.size()) +
                                " entries for a grid of " + std::to_string(nvox) + " voxels");
  if (s.pressed.empty()) throw std::invalid_argument("squish sim: no pressed face");
  if (s.model == nullptr) throw std::invalid_argument("squish sim: no part");
  const int control = req.control;
  out.resting_missing = s.resting_missing;

  // ── the law, per scene voxel ──
  const Law law = make_law(req.law, data);
  std::vector<double> Es(nvox, 0.0);
  double emin = std::numeric_limits<double>::infinity(), emax = 0.0, esum = 0.0;
  std::size_t esolid = 0;
  for (std::size_t v = 0; v < nvox; ++v) {
    if (sg.tags[v] == topopt::VoxelTag::Empty) continue;
    Es[v] = law.voxel(req.rho[v], req.strain_op[v], req.skin_frac[v], control);
    esum += Es[v];
    ++esolid;
  }
  if (control & kUniformE) {
    const double mean = esolid > 0 ? esum / static_cast<double>(esolid) : law.es;
    for (std::size_t v = 0; v < nvox; ++v)
      if (sg.tags[v] != topopt::VoxelTag::Empty) Es[v] = mean;
  }

  // ── the FE grid (§1.1): core's grid, coarsened by the rule ──
  FE fe;
  fe.c = req.coarsen > 0 ? req.coarsen : coarsen(sg.nx, sg.ny, sg.nz);
  const int c = fe.c;
  fe.g.nx = (sg.nx + c - 1) / c;
  fe.g.ny = (sg.ny + c - 1) / c;
  fe.g.nz = (sg.nz + c - 1) / c;
  fe.g.spacing = sg.spacing * c;
  fe.g.origin = sg.origin;
  fe.g.tags.assign(static_cast<std::size_t>(fe.g.nx) * fe.g.ny * fe.g.nz, topopt::VoxelTag::Empty);
  fe.E.assign(fe.g.tags.size(), 0.0);
  const double inv = 1.0 / static_cast<double>(c * c * c);
  for (int k = 0; k < fe.g.nz; ++k)
    for (int j = 0; j < fe.g.ny; ++j)
      for (int i = 0; i < fe.g.nx; ++i) {
        double sum = 0.0;
        bool any = false;
        for (int dk = 0; dk < c; ++dk)
          for (int dj = 0; dj < c; ++dj)
            for (int di = 0; di < c; ++di) {
              const int ii = i * c + di, jj = j * c + dj, kk = k * c + dk;
              if (ii >= sg.nx || jj >= sg.ny || kk >= sg.nz) continue;
              const std::size_t v = sg.index(ii, jj, kk);
              if (sg.tags[v] == topopt::VoxelTag::Empty) continue;
              any = true;
              sum += Es[v];
            }
        if (!any) continue;
        const std::size_t e = fe.g.index(i, j, k);
        fe.g.tags[e] = topopt::VoxelTag::Interior;
        fe.E[e] = std::max(sum * inv, 1e-4 * law.es);
        emin = std::min(emin, fe.E[e]);
        emax = std::max(emax, fe.E[e]);
        ++out.elements;
      }
  fe.nnx = fe.g.nx + 1;
  fe.nny = fe.g.ny + 1;
  fe.nnz = fe.g.nz + 1;
  const std::size_t N = fe.nodes();
  const double h = fe.g.spacing;
  out.coarsen = c;
  out.nx = fe.nnx;
  out.ny = fe.nny;
  out.nz = fe.nnz;
  out.spacing = h;
  out.origin[0] = fe.g.origin.x;
  out.origin[1] = fe.g.origin.y;
  out.origin[2] = fe.g.origin.z;
  out.e_min_mpa = std::isfinite(emin) ? emin : 0.0;
  out.e_max_mpa = emax;
  if (out.elements == 0) throw std::invalid_argument("squish sim: the part has no solid voxel");

  // nodal mass (solid voxels incident / 8) and which nodes a solid element owns
  std::vector<double> mass(N, 0.0);
  for (int k = 0; k < fe.g.nz; ++k)
    for (int j = 0; j < fe.g.ny; ++j)
      for (int i = 0; i < fe.g.nx; ++i) {
        if (!fe.g.solid(i, j, k)) continue;
        for (int dk = 0; dk < 2; ++dk)
          for (int dj = 0; dj < 2; ++dj)
            for (int di = 0; di < 2; ++di) mass[static_cast<std::size_t>(fe.node(i + di, j + dj, k + dk))] += 0.125;
      }
  out.solved.assign(N, 0);
  for (std::size_t n = 0; n < N; ++n) out.solved[n] = mass[n] > 0.0 ? 1 : 0;

  // ── the loads (§1.5): each pressed face's exposed cell faces, by column pressure ──
  std::vector<double> f(3 * N, 0.0);
  Vec3 applied{0, 0, 0};
  out.press_load_offsets.push_back(0);
  std::vector<int> pressedFaces;
  for (const Press& p : s.pressed)
    for (int face : p.region.member_faces) pressedFaces.push_back(face);
  for (std::size_t k = 0; k < s.pressed.size(); ++k) {
    const Press& P = s.pressed[k];
    const fx::Stack& st = P.stack;
    const std::vector<double>& pc = req.pressed[k].column_pressure_mpa;
    const Vec3 load = st.frame.load;
    double F = 0.0, A = 0.0;
    for (std::size_t col = 0; col < st.columns.size(); ++col) {
      const double pp = col < pc.size() ? std::max(0.0, pc[col]) : 0.0;
      F += pp * st.columns[col].area_mm2;
      A += st.columns[col].area_mm2;
    }
    const double mean = A > 0.0 ? F / A : 0.0;
    std::vector<int> slab = member_voxels(fe.g, *s.model, P.region.member_triangles);
    if (!(control & kIgnoreCuts)) slab = topopt::cut_voxels(fe.g, slab, P.region.cuts);
    std::vector<double> local(3 * N, 0.0);
    std::vector<int> touched;
    double raw = 0.0;
    for (int idx : slab) {
      const int i = idx % fe.g.nx, j = (idx / fe.g.nx) % fe.g.ny, kk = idx / (fe.g.nx * fe.g.ny);
      const Vec3 ctr = fe.g.voxel_center(i, j, kk);
      for (int d = 0; d < 6; ++d) {
        if (fe.solid(i + kDir[d][0], j + kDir[d][1], kk + kDir[d][2])) continue;
        const Vec3 n{static_cast<double>(kDir[d][0]), static_cast<double>(kDir[d][1]),
                     static_cast<double>(kDir[d][2])};
        const double facing = -dot(n, load);
        double w;
        if (control & kUnprojected) {
          if (facing < -1e-9) continue;
          w = h * h;
        } else {
          if (!(facing > 1e-9)) continue;
          w = h * h * facing;
        }
        const Vec3 at = add(ctr, mul(n, 0.5 * h));
        double pr = mean;
        if (!(control & kUniformPressure)) {
          double u = 0.0, v = 0.0;
          st.frame.to_uv(at, u, v);
          const int col = st.column_at(static_cast<int>(std::floor(u / st.pitch_mm)),
                                       static_cast<int>(std::floor(v / st.pitch_mm)));
          if (col >= 0 && static_cast<std::size_t>(col) < pc.size()) pr = std::max(0.0, pc[static_cast<std::size_t>(col)]);
        }
        raw += pr * w;
        const Vec3 fq = mul(load, 0.25 * pr * w);
        for (int nd : face_nodes(fe, i, j, kk, d)) {
          const std::size_t b = 3 * static_cast<std::size_t>(nd);
          if (local[b] == 0.0 && local[b + 1] == 0.0 && local[b + 2] == 0.0) touched.push_back(nd);
          local[b] += fq.x;
          local[b + 1] += fq.y;
          local[b + 2] += fq.z;
        }
      }
    }
    // renormalise to the force core designed the face for (MPa · mm² = N)
    const double scale = raw > 0.0 ? F / raw : 0.0;
    std::sort(touched.begin(), touched.end());
    touched.erase(std::unique(touched.begin(), touched.end()), touched.end());
    for (int nd : touched) {
      const std::size_t b = 3 * static_cast<std::size_t>(nd);
      const double x = local[b] * scale, y = local[b + 1] * scale, z = local[b + 2] * scale;
      if (x == 0.0 && y == 0.0 && z == 0.0) continue;
      f[b] += x;
      f[b + 1] += y;
      f[b + 2] += z;
      out.press_load_nodes.push_back(nd);
      out.press_load_xyz.push_back(x);
      out.press_load_xyz.push_back(y);
      out.press_load_xyz.push_back(z);
    }
    out.press_load_offsets.push_back(static_cast<int32_t>(out.press_load_nodes.size()));
    out.press_force_n.push_back(raw > 0.0 ? F : 0.0);
    out.press_raw_force_n.push_back(raw);
    applied = add(applied, mul(load, raw > 0.0 ? F : 0.0));
    out.applied_force_abs_n += raw > 0.0 ? F : 0.0;
  }
  out.applied_force_n[0] = applied.x;
  out.applied_force_n[1] = applied.y;
  out.applied_force_n[2] = applied.z;
  if (!(out.applied_force_abs_n > 0.0)) {
    out.failure = "no pressed face reaches a solid voxel of the sim's grid";
    return out;
  }

  // ── the boundary conditions (§1.4) ──
  std::vector<topopt::DirichletBC> bcs;
  std::vector<char> pinned(3 * N, 0);
  auto pin = [&](int node, int comp) {
    const std::size_t b = 3 * static_cast<std::size_t>(node) + static_cast<std::size_t>(comp);
    if (pinned[b]) return;
    pinned[b] = 1;
    bcs.push_back({node, comp, 0.0});
  };
  // The sole of a face: the corner nodes of the exposed cell faces of its slab voxels whose
  // outward axis normal is within ~73° of the face's outward normal.
  auto sole = [&](const std::vector<int>& triangles, const std::vector<topopt::RegionCut>& cuts,
                  std::vector<int>& nodes, Vec3& normal) {
    normal = outward_normal(*s.model, triangles, cuts);
    if (norm(normal) <= 0.0) return;
    std::vector<int> slab = member_voxels(fe.g, *s.model, triangles);
    slab = topopt::cut_voxels(fe.g, slab, cuts);
    for (int idx : slab) {
      const int i = idx % fe.g.nx, j = (idx / fe.g.nx) % fe.g.ny, kk = idx / (fe.g.nx * fe.g.ny);
      for (int d = 0; d < 6; ++d) {
        if (fe.solid(i + kDir[d][0], j + kDir[d][1], kk + kDir[d][2])) continue;
        const Vec3 n{static_cast<double>(kDir[d][0]), static_cast<double>(kDir[d][1]),
                     static_cast<double>(kDir[d][2])};
        if (dot(n, normal) <= 0.3) continue;
        for (int nd : face_nodes(fe, i, j, kk, d)) nodes.push_back(nd);
      }
    }
  };
  // ★ A REST GRIPS ONLY WHERE IT IS AN ANVIL (deviation from the design's "every rest bonded",
  // stated in the handoff): a resting face that a pressed stack of THIS group exits through
  // carries the group's load, so its friction holds it — bonded (x, y, z). A resting face nothing
  // of the group presses into slides — only its normal is held (frictionless; a side squeeze does
  // not glue the pad to the table it lies on). Control 2048 bonds every rest (the design's rule),
  // control 128 lets every rest slide.
  std::vector<int> anvilFaces;
  for (const Press& p : s.pressed)
    for (const fx::StackLink& l : p.stack.exit_faces)
      if (l.area_fraction >= 0.05 && std::find(pressedFaces.begin(), pressedFaces.end(), l.id) == pressedFaces.end())
        anvilFaces.push_back(l.id);
  auto hold = [&](const std::vector<int>& nodes, const Vec3& normal, bool bonded) {
    int ax = 0;
    if (std::fabs(normal.y) > std::fabs(comp(normal, ax))) ax = 1;
    if (std::fabs(normal.z) > std::fabs(comp(normal, ax))) ax = 2;
    for (int nd : nodes) {
      if (bonded) {
        pin(nd, 0);
        pin(nd, 1);
        pin(nd, 2);
      } else {
        pin(nd, ax);
      }
      out.held_nodes.push_back(nd);
    }
  };
  const bool balanced = norm(applied) <= 0.02 * out.applied_force_abs_n;
  std::string mode;
  if (control & kAnchorPatch) {
    // TEST CONTROL: a naive patch anchor — every DOF of the solid voxel nearest the grid's min
    // corner, no inertia relief, no rigid removal
    int best = -1;
    double bd = std::numeric_limits<double>::infinity();
    for (int k = 0; k < fe.g.nz; ++k)
      for (int j = 0; j < fe.g.ny; ++j)
        for (int i = 0; i < fe.g.nx; ++i) {
          if (!fe.g.solid(i, j, k)) continue;
          const double d = static_cast<double>(i) * i + static_cast<double>(j) * j + static_cast<double>(k) * k;
          if (d < bd) { bd = d; best = static_cast<int>(fe.g.index(i, j, k)); }
        }
    const int i = best % fe.g.nx, j = (best / fe.g.nx) % fe.g.ny, k = best / (fe.g.nx * fe.g.ny);
    for (int dk = 0; dk < 2; ++dk)
      for (int dj = 0; dj < 2; ++dj)
        for (int di = 0; di < 2; ++di)
          for (int cc = 0; cc < 3; ++cc) pin(fe.node(i + di, j + dj, k + dk), cc);
    mode = "patch";
  }
  if (mode.empty() && !s.resting.empty()) {
    for (const auto& r : s.resting) {
      std::vector<int> nodes;
      Vec3 n;
      sole(r.member_triangles, r.cuts, nodes, n);
      bool anvil = false;
      for (int face : r.member_faces)
        if (std::find(anvilFaces.begin(), anvilFaces.end(), face) != anvilFaces.end()) anvil = true;
      const bool bonded = (control & kRollerRest) ? false : ((control & kBondedRests) != 0 || anvil);
      hold(nodes, n, bonded);
    }
    if (!bcs.empty()) mode = "rest";
  }
  if (mode.empty() && !balanced) {
    // the linked other end of each pressed stack (core's anvil), not a face this group presses
    for (int face : anvilFaces) {
      std::vector<int> tris;
      for (std::size_t t = 0; t < s.model->triangle_face.size(); ++t)
        if (s.model->triangle_face[t] == face) tris.push_back(static_cast<int>(t));
      std::vector<int> nodes;
      Vec3 n;
      sole(tris, {}, nodes, n);
      hold(nodes, n, true);
    }
    if (!bcs.empty()) mode = "exit";
  }
  if (mode.empty()) mode = "free";
  std::sort(out.held_nodes.begin(), out.held_nodes.end());
  out.held_nodes.erase(std::unique(out.held_nodes.begin(), out.held_nodes.end()), out.held_nodes.end());
  const std::size_t heldCount = bcs.size();

  // ── the rigid modes the rests leave FREE (all six for a squeeze nothing rests against) ──
  // θ = [t; L·ω] (L the part's size, so the six coordinates weigh alike): a rigid motion moves
  // node n by ψ(θ)(x_n) = t + (θ_ω × r_n) / L, r about the mass centre.
  double msum = 0.0;
  Vec3 cm{0, 0, 0};
  Vec3 lo{1e300, 1e300, 1e300}, hi{-1e300, -1e300, -1e300};
  for (std::size_t n = 0; n < N; ++n) {
    if (mass[n] <= 0.0) continue;
    const Vec3 p = fe.pos(static_cast<int>(n));
    msum += mass[n];
    cm = add(cm, mul(p, mass[n]));
    lo = {std::min(lo.x, p.x), std::min(lo.y, p.y), std::min(lo.z, p.z)};
    hi = {std::max(hi.x, p.x), std::max(hi.y, p.y), std::max(hi.z, p.z)};
  }
  cm = mul(cm, 1.0 / msum);
  const Vec3 ext = sub(hi, lo);
  const double Ls = std::max({ext.x, ext.y, ext.z, 1e-9});
  auto row = [&](int node, int c, double out6[6]) {
    const Vec3 r = sub(fe.pos(node), cm);
    Vec3 e{0, 0, 0};
    if (c == 0) e.x = 1; else if (c == 1) e.y = 1; else e.z = 1;
    const Vec3 m = mul(cross(r, e), 1.0 / Ls);
    out6[0] = e.x; out6[1] = e.y; out6[2] = e.z; out6[3] = m.x; out6[4] = m.y; out6[5] = m.z;
  };
  auto psi = [&](const double* phi, int node) {
    const Vec3 r = sub(fe.pos(node), cm);
    return add(Vec3{phi[0], phi[1], phi[2]}, mul(cross(Vec3{phi[3], phi[4], phi[5]}, r), 1.0 / Ls));
  };
  std::vector<double> gram(36, 0.0);
  auto accumulate = [&](std::vector<double>& G, int node, int c) {
    double r6[6];
    row(node, c, r6);
    for (int a = 0; a < 6; ++a)
      for (int b = 0; b < 6; ++b) G[a * 6 + b] += r6[a] * r6[b];
  };
  for (std::size_t q = 0; q < heldCount; ++q) accumulate(gram, bcs[q].node, bcs[q].component);
  std::vector<std::vector<double>> freeModes = null_modes(gram);
  if (mode == "patch") freeModes.clear();
  out.free_modes = static_cast<int32_t>(freeModes.size());
  const int d = static_cast<int>(freeModes.size());

  if (d > 0) {
    // ★ INERTIA RELIEF on the free modes: the loads' share in them removed by the mass-weighted
    // rigid acceleration it would cause, so the loads are EXACTLY self-equilibrated there and the
    // pins below carry no reaction and bias nothing
    std::vector<double> Mg(static_cast<std::size_t>(d * d), 0.0), g(static_cast<std::size_t>(d), 0.0);
    for (std::size_t n = 0; n < N; ++n) {
      const Vec3 fn{f[3 * n], f[3 * n + 1], f[3 * n + 2]};
      if (mass[n] <= 0.0 && fn.x == 0.0 && fn.y == 0.0 && fn.z == 0.0) continue;
      std::vector<Vec3> ps(static_cast<std::size_t>(d));
      for (int i = 0; i < d; ++i) ps[static_cast<std::size_t>(i)] = psi(freeModes[static_cast<std::size_t>(i)].data(), static_cast<int>(n));
      for (int i = 0; i < d; ++i) {
        g[static_cast<std::size_t>(i)] += dot(fn, ps[static_cast<std::size_t>(i)]);
        if (mass[n] <= 0.0) continue;
        for (int j = 0; j < d; ++j) Mg[static_cast<std::size_t>(i * d + j)] += mass[n] * dot(ps[static_cast<std::size_t>(i)], ps[static_cast<std::size_t>(j)]);
      }
    }
    std::vector<double> a = g;
    gauss(Mg, a, d);
    for (std::size_t n = 0; n < N; ++n) {
      if (mass[n] <= 0.0) continue;
      Vec3 acc{0, 0, 0};
      for (int i = 0; i < d; ++i) acc = add(acc, mul(psi(freeModes[static_cast<std::size_t>(i)].data(), static_cast<int>(n)), a[static_cast<std::size_t>(i)]));
      f[3 * n] -= mass[n] * acc.x;
      f[3 * n + 1] -= mass[n] * acc.y;
      f[3 * n + 2] -= mass[n] * acc.z;
    }
    // ★ MINIMAL PINS: one DOF per free mode, each the candidate that constrains what is still free
    // most strongly (on the coarse multigrid nodes, indices % 4 == 0, where there are enough);
    // control 512 draws them from the other half of the part (another valid choice)
    const bool other = (control & kOtherAnchors) != 0;
    auto preferred = [&](int n) {
      const int a2 = n % fe.nnx, b2 = (n / fe.nnx) % fe.nny, c2 = n / (fe.nnx * fe.nny);
      return a2 % 4 == 0 && b2 % 4 == 0 && c2 % 4 == 0;
    };
    std::vector<int> cands;
    for (int pass = 0; pass < 2 && cands.size() < 8; ++pass) {
      cands.clear();
      for (std::size_t n = 0; n < N; ++n) {
        if (mass[n] <= 0.0 || (pass == 0 && !preferred(static_cast<int>(n)))) continue;
        const Vec3 p = fe.pos(static_cast<int>(n));
        if (other && p.x > cm.x) continue;
        cands.push_back(static_cast<int>(n));
      }
    }
    std::vector<double> G = gram;
    for (int k = 0; k < d; ++k) {
      const std::vector<std::vector<double>> still = null_modes(G);
      if (still.empty()) break;
      int bestNode = -1, bestComp = 0;
      double best = 0.0;
      for (int n : cands)
        for (int c2 = 0; c2 < 3; ++c2) {
          if (pinned[3 * static_cast<std::size_t>(n) + static_cast<std::size_t>(c2)]) continue;
          double r6[6];
          row(n, c2, r6);
          double proj = 0.0;
          for (const auto& v : still) {
            double x = 0.0;
            for (int q = 0; q < 6; ++q) x += r6[q] * v[static_cast<std::size_t>(q)];
            proj += x * x;
          }
          if (proj > best * (1.0 + 1e-9)) { best = proj; bestNode = n; bestComp = c2; }
        }
      if (bestNode < 0 || best < 1e-12) break;
      pin(bestNode, bestComp);
      accumulate(G, bestNode, bestComp);
    }
    if (!null_modes(G).empty()) {
      out.failure = "the squish sim found no stable anchoring for this squeeze";
      return out;
    }
  }
  out.bc_mode = mode;
  for (const auto& b : bcs) out.pinned_dofs.push_back(3 * b.node + b.component);

  std::vector<topopt::NodalLoad> loads;
  for (std::size_t q = 0; q < 3 * N; ++q)
    if (f[q] != 0.0) loads.push_back({static_cast<int>(q / 3), static_cast<int>(q % 3), f[q]});

  // ── the solve (§1.6): core's matrix-free MG-CG, under the posture ──
  out.setup_ms = topopt::steady_clock_ms() - t0;
  const double nu = (control & kPoissonZero) ? 0.0 : req.poisson;
  topopt::FeaSolution sol;
  {
    // control 4096: a reference solve (the budget lifted — the deadline still holds); control
    // 8192: the old fixed 600 (the red control of the work budget)
    out.max_iterations = (control & kLongSolve) ? kMaxIterationsCap
                         : (control & kFixedCap) ? kMinIterations
                                                 : iteration_cap(out.elements);
    const double tw = topopt::steady_clock_ms();
    std::lock_guard<std::mutex> lock(g_squish_fe_mu);
    // ★ THE DEADLINE STARTS HERE, once this sim holds the solver: it bounds the solve's OWN work.
    // Measured from the request, a sim queued behind another (a second stage model's, in the
    // suite) spent its whole 20 s waiting and began with none left — core then threw its deadline
    // at the first poll, and the M2 stand played the column squish. The wait is said in `wait_ms`.
    out.wait_ms = topopt::steady_clock_ms() - tw;
    const double deadline_abs = req.deadline_ms > 0.0 ? topopt::steady_clock_ms() + req.deadline_ms : 0.0;
    out.threads_before = topopt::fea_matfree_thread_count();
    out.geneo_before = topopt::fea_geneo_twolevel_enabled();
    {
      Posture posture(deadline_abs, (control & kKeepGlobals) != 0);
      out.threads_during = topopt::fea_matfree_thread_count();
      out.geneo_during = topopt::fea_geneo_twolevel_enabled();
      out.recycling_during = topopt::fea_krylov_recycling_enabled();
      if (deadline_abs > 0.0 && topopt::steady_clock_ms() >= deadline_abs) {
        out.failure = "the solve deadline passed before the squish sim's solve began (" +
                      std::to_string(static_cast<long long>(req.deadline_ms)) + " ms budget)";
      } else {
        const double ts = topopt::steady_clock_ms();
        // core fills `info` before it throws its non-convergence, so a failure says WHICH solver
        // gave up (the hierarchy never built, or the V-cycles stagnated and Jacobi-CG ran out). Its
        // deadline throws from INSIDE the recurrence, before `info` is filled: say the clock.
        topopt::CgInfo info;
        try {
          sol = topopt::fea_solve_mgcg_matfree(fe.g, fe.E, nu, bcs, loads, req.tolerance, out.max_iterations, &info, nullptr, nullptr);
        } catch (const topopt::SolverDeadlineExceeded& e) {
          out.failure = std::string(e.what()) + " (after " +
                        std::to_string(static_cast<long long>(topopt::steady_clock_ms() - ts)) + " ms of solving, at CG iteration " +
                        std::to_string(e.iterations) + ", residual " + std::to_string(e.residual) + ")";
        } catch (const topopt::SolverNonConvergence& e) {
          out.failure = std::string(e.what()) + " (multigrid " + (info.hier_built ? "built" : "not built") +
                        ", " + std::to_string(info.mg_cycles_attempted) + " V-cycles, then " +
                        std::to_string(info.iterations) + " Jacobi-CG iterations, residual " +
                        std::to_string(info.residual) + ")";
        } catch (const std::exception& e) {
          out.failure = e.what();
        }
        out.iterations = info.iterations;
        out.residual = info.residual;
        out.used_multigrid = info.used_multigrid;
        out.mg_levels = info.mg_levels;
        out.solve_ms = topopt::steady_clock_ms() - ts;
      }
    }
    out.threads_after = topopt::fea_matfree_thread_count();
    out.geneo_after = topopt::fea_geneo_twolevel_enabled();
  }
  if (!out.failure.empty()) return out;
  if (sol.u.size() != 3 * N) {
    out.failure = "the solver returned " + std::to_string(sol.u.size()) + " DOFs for " + std::to_string(3 * N);
    return out;
  }

  // ── the reactions: K u − f at the pinned DOFs (core's own matrix-free apply) ──
  {
    const std::vector<double> Ku = topopt::fea_matfree_apply(fe.g, fe.E, nu, sol.u);
    double r2 = 0.0;
    for (std::size_t q = 0; q < bcs.size(); ++q) {
      const auto& b = bcs[q];
      const std::size_t i = 3 * static_cast<std::size_t>(b.node) + static_cast<std::size_t>(b.component);
      const double r = Ku[i] - f[i];
      if (q < heldCount && mode != "patch") {
        out.held_reaction_n[b.component] += r;   // the rests (or the linked other end)
      } else {
        r2 += r * r;                              // the pins (the patch control's DOFs)
      }
    }
    out.anchor_reaction_n = std::sqrt(r2);
  }

  std::vector<double> u = std::move(sol.u);
  if (d > 0) {
    // ★ the mass-weighted best-fit motion in the FREE rigid modes removed (least squares), so the
    // pins' choice leaves no trace
    std::vector<double> Mg(static_cast<std::size_t>(d * d), 0.0), b(static_cast<std::size_t>(d), 0.0);
    for (std::size_t n = 0; n < N; ++n) {
      if (mass[n] <= 0.0) continue;
      const Vec3 un{u[3 * n], u[3 * n + 1], u[3 * n + 2]};
      std::vector<Vec3> ps(static_cast<std::size_t>(d));
      for (int i = 0; i < d; ++i) ps[static_cast<std::size_t>(i)] = psi(freeModes[static_cast<std::size_t>(i)].data(), static_cast<int>(n));
      for (int i = 0; i < d; ++i) {
        b[static_cast<std::size_t>(i)] += mass[n] * dot(un, ps[static_cast<std::size_t>(i)]);
        for (int j = 0; j < d; ++j) Mg[static_cast<std::size_t>(i * d + j)] += mass[n] * dot(ps[static_cast<std::size_t>(i)], ps[static_cast<std::size_t>(j)]);
      }
    }
    gauss(Mg, b, d);
    for (std::size_t n = 0; n < N; ++n) {
      if (mass[n] <= 0.0) continue;
      Vec3 rg{0, 0, 0};
      for (int i = 0; i < d; ++i) rg = add(rg, mul(psi(freeModes[static_cast<std::size_t>(i)].data(), static_cast<int>(n)), b[static_cast<std::size_t>(i)]));
      u[3 * n] -= rg.x;
      u[3 * n + 1] -= rg.y;
      u[3 * n + 2] -= rg.z;
    }
  }

  // ── the extension outside the solid (§1.7): each BFS layer the mean of its filled neighbours ──
  std::vector<char> filled(N, 0);
  for (std::size_t n = 0; n < N; ++n) filled[n] = out.solved[n];
  if (!(control & kNoExtension)) {
    std::vector<int> layer;
    for (std::size_t n = 0; n < N; ++n)
      if (!filled[n]) u[3 * n] = u[3 * n + 1] = u[3 * n + 2] = 0.0;
    for (;;) {
      layer.clear();
      for (std::size_t n = 0; n < N; ++n) {
        if (filled[n]) continue;
        const int a = static_cast<int>(n) % fe.nnx, b = (static_cast<int>(n) / fe.nnx) % fe.nny,
                  cc = static_cast<int>(n) / (fe.nnx * fe.nny);
        for (int d = 0; d < 6; ++d) {
          const int aa = a + kDir[d][0], bb = b + kDir[d][1], c2 = cc + kDir[d][2];
          if (aa < 0 || bb < 0 || c2 < 0 || aa >= fe.nnx || bb >= fe.nny || c2 >= fe.nnz) continue;
          if (filled[static_cast<std::size_t>(fe.node(aa, bb, c2))]) { layer.push_back(static_cast<int>(n)); break; }
        }
      }
      if (layer.empty()) break;
      std::vector<double> vals(3 * layer.size(), 0.0);
      for (std::size_t q = 0; q < layer.size(); ++q) {
        const int n = layer[q];
        const int a = n % fe.nnx, b = (n / fe.nnx) % fe.nny, cc = n / (fe.nnx * fe.nny);
        int cnt = 0;
        for (int d = 0; d < 6; ++d) {
          const int aa = a + kDir[d][0], bb = b + kDir[d][1], c2 = cc + kDir[d][2];
          if (aa < 0 || bb < 0 || c2 < 0 || aa >= fe.nnx || bb >= fe.nny || c2 >= fe.nnz) continue;
          const std::size_t m = static_cast<std::size_t>(fe.node(aa, bb, c2));
          if (!filled[m]) continue;
          vals[3 * q] += u[3 * m];
          vals[3 * q + 1] += u[3 * m + 1];
          vals[3 * q + 2] += u[3 * m + 2];
          ++cnt;
        }
        for (int k = 0; k < 3; ++k) vals[3 * q + k] /= std::max(cnt, 1);
      }
      for (std::size_t q = 0; q < layer.size(); ++q) {
        const std::size_t n = static_cast<std::size_t>(layer[q]);
        u[3 * n] = vals[3 * q];
        u[3 * n + 1] = vals[3 * q + 1];
        u[3 * n + 2] = vals[3 * q + 2];
        filled[n] = 1;
      }
    }
  } else {
    for (std::size_t n = 0; n < N; ++n)
      if (!filled[n]) u[3 * n] = u[3 * n + 1] = u[3 * n + 2] = 0.0;
  }

  out.u.resize(3 * N);
  for (std::size_t q = 0; q < 3 * N; ++q) out.u[q] = static_cast<float>(u[q]);
  out.ok = true;
  return out;
}

}  // namespace squishfe
}  // namespace topoptbridge
