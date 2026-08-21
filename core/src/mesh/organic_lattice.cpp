// ★ THE ORGANIC LATTICE TRACER (task 2026-08-21-organic-lattice, §1 and §2).
// The header states the method, the evidence and every fixed order; this file is the
// arithmetic. Nothing here reads a job, a file or a clock.

#include "topopt/organic_lattice.hpp"

#include <algorithm>
#include <array>
#include <cmath>
#include <cstddef>
#include <functional>
#include <map>
#include <stdexcept>
#include <utility>
#include <vector>

#include "topopt/lattice_boundary.hpp"
#include "topopt/lattice_gen.hpp"

namespace topopt {
namespace {

// ── small vector helpers (local; the generator's own live in lattice_gen.cpp) ────
Vec3 vadd(const Vec3& a, const Vec3& b) { return {a.x + b.x, a.y + b.y, a.z + b.z}; }
Vec3 vsub(const Vec3& a, const Vec3& b) { return {a.x - b.x, a.y - b.y, a.z - b.z}; }
Vec3 vmul(const Vec3& a, double s) { return {a.x * s, a.y * s, a.z * s}; }
double vdot(const Vec3& a, const Vec3& b) {
  return a.x * b.x + a.y * b.y + a.z * b.z;
}
Vec3 vcross(const Vec3& a, const Vec3& b) {
  return {a.y * b.z - a.z * b.y, a.z * b.x - a.x * b.z, a.x * b.y - a.y * b.x};
}
double vlen(const Vec3& a) { return std::sqrt(vdot(a, a)); }
Vec3 vunit(const Vec3& a) {
  const double L = vlen(a);
  return L > 0.0 ? vmul(a, 1.0 / L) : Vec3{0.0, 0.0, 0.0};
}

// ── ★ A DETERMINISTIC SYMMETRIC 3x3 EIGENSOLVE (§1a) ────────────────────────────
// CYCLIC JACOBI with a FIXED sweep count and a FIXED pivot order (01, 02, 12). Chosen
// over the closed-form trigonometric solution deliberately: the analytic form loses
// orthogonality near a degenerate pair, and a degenerate pair is exactly where a
// stress field spends its time (any point in near-hydrostatic or near-uniaxial
// stress). Jacobi is unconditionally stable, produces an orthonormal frame BY
// CONSTRUCTION (it is a product of plane rotations), and 12 sweeps is far past
// convergence for a 3x3.
//
// 468,000 of these is milliseconds — §1(a) says so, and it is why the cost note in the
// handoff is about the TRACING, not about this.
void jacobi_eigen(const double m[6], double eval[3], Vec3 evec[3]) {
  // A, symmetric, from Voigt [xx,yy,zz,xy,yz,zx] with TRUE shear.
  double a[3][3] = {{m[0], m[3], m[5]}, {m[3], m[1], m[4]}, {m[5], m[4], m[2]}};
  double v[3][3] = {{1, 0, 0}, {0, 1, 0}, {0, 0, 1}};
  static const int pq[3][2] = {{0, 1}, {0, 2}, {1, 2}};
  for (int sweep = 0; sweep < 12; ++sweep) {
    for (int t = 0; t < 3; ++t) {
      const int p = pq[t][0], q = pq[t][1];
      const double apq = a[p][q];
      if (std::fabs(apq) <= 1e-300) continue;
      const double theta = 0.5 * (a[q][q] - a[p][p]) / apq;
      const double sgn = theta >= 0.0 ? 1.0 : -1.0;
      const double tt = sgn / (std::fabs(theta) + std::sqrt(theta * theta + 1.0));
      const double c = 1.0 / std::sqrt(tt * tt + 1.0);
      const double s = tt * c;
      for (int k = 0; k < 3; ++k) {
        const double akp = a[k][p], akq = a[k][q];
        a[k][p] = c * akp - s * akq;
        a[k][q] = s * akp + c * akq;
      }
      for (int k = 0; k < 3; ++k) {
        const double apk = a[p][k], aqk = a[q][k];
        a[p][k] = c * apk - s * aqk;
        a[q][k] = s * apk + c * aqk;
      }
      for (int k = 0; k < 3; ++k) {
        const double vkp = v[k][p], vkq = v[k][q];
        v[k][p] = c * vkp - s * vkq;
        v[k][q] = s * vkp + c * vkq;
      }
    }
  }
  // Rank by |eigenvalue| DESCENDING; ties broken by ASCENDING COLUMN INDEX, which is
  // what makes the frame reproducible on a hydrostatic voxel.
  int idx[3] = {0, 1, 2};
  const double lam[3] = {a[0][0], a[1][1], a[2][2]};
  std::stable_sort(idx, idx + 3, [&lam](int x, int y) {
    return std::fabs(lam[x]) > std::fabs(lam[y]);
  });
  for (int r = 0; r < 3; ++r) {
    const int c = idx[r];
    eval[r] = lam[c];
    Vec3 e = vunit(Vec3{v[0][c], v[1][c], v[2][c]});
    // ★ SIGN CANONICALISATION. An eigenvector's sign is arbitrary; leaving it so makes
    // the direction field a LINE field whose sign flips voxel to voxel, and the traced
    // curve then depends on the traversal that produced it. Fix it: the component of
    // LARGEST magnitude is made positive, ties broken by the LOWEST index.
    int big = 0;
    const double comp[3] = {e.x, e.y, e.z};
    for (int k = 1; k < 3; ++k)
      if (std::fabs(comp[k]) > std::fabs(comp[big])) big = k;
    if (comp[big] < 0.0) e = vmul(e, -1.0);
    evec[r] = e;
  }
}

// Where the top two |eigenvalues| are this close the principal FRAME is not
// determined: the two directions can swap between neighbouring voxels. §6(d) says
// NAME IT AND COUNT IT, and build no combing pass here.
constexpr double kOrganicDegenerateRatio = 0.98;

// ── the uniform hash used for every proximity query ─────────────────────────────
// A fixed bucket grid over the part's bounding box, cell = the largest query radius
// the run will ever make, so a query touches at most 27 buckets. No RNG, no rehash,
// insertion order preserved inside a bucket.
struct SampleHash {
  Vec3 lo{0, 0, 0};
  double cell = 1.0;
  int nx = 1, ny = 1, nz = 1;
  std::vector<std::vector<std::pair<int, int>>> buckets;  // (curve, point)

  void init(const Vec3& mn, const Vec3& mx, double c) {
    cell = c > 0.0 ? c : 1.0;
    lo = mn;
    nx = std::max(1, static_cast<int>(std::floor((mx.x - mn.x) / cell)) + 1);
    ny = std::max(1, static_cast<int>(std::floor((mx.y - mn.y) / cell)) + 1);
    nz = std::max(1, static_cast<int>(std::floor((mx.z - mn.z) / cell)) + 1);
    buckets.assign(static_cast<std::size_t>(nx) * ny * nz, {});
  }
  void coords(const Vec3& p, int& i, int& j, int& k) const {
    i = std::min(nx - 1, std::max(0, static_cast<int>(std::floor((p.x - lo.x) / cell))));
    j = std::min(ny - 1, std::max(0, static_cast<int>(std::floor((p.y - lo.y) / cell))));
    k = std::min(nz - 1, std::max(0, static_cast<int>(std::floor((p.z - lo.z) / cell))));
  }
  std::size_t bindex(int i, int j, int k) const {
    return (static_cast<std::size_t>(k) * ny + j) * nx + i;
  }
  void insert(const Vec3& p, int curve, int point) {
    int i, j, k;
    coords(p, i, j, k);
    buckets[bindex(i, j, k)].emplace_back(curve, point);
  }
};

}  // namespace

// ────────────────────────────────────────────────────────────────────────────────
OrganicLattice trace_organic_lattice(const VoxelGrid& grid,
                                     const std::vector<char>& candidate,
                                     const std::vector<double>& stress,
                                     const std::vector<double>& spacing_mm,
                                     const std::vector<double>* width_mm,
                                     const OrganicParams& params) {
  const std::size_t n = grid.voxel_count();
  if (candidate.size() != n)
    throw std::invalid_argument(
        "trace_organic_lattice: candidate size does not match the grid");
  if (stress.size() != 6 * n)
    throw std::invalid_argument(
        "trace_organic_lattice: stress tensor field must be 6 * voxel_count");
  if (spacing_mm.size() != n)
    throw std::invalid_argument(
        "trace_organic_lattice: spacing field size does not match the grid");
  if (width_mm && width_mm->size() != n)
    throw std::invalid_argument(
        "trace_organic_lattice: width field size does not match the grid");
  // ★ §2(c) — 0 MEANS UNSET AND MUST REFUSE. Printability is USER INPUT; defaulting
  // it here would put a number nobody stated into a printed part.
  if (!(params.min_extrudable_width_mm > 0.0))
    throw std::invalid_argument(
        "trace_organic_lattice: min_extrudable_width_mm is 0, which means UNSET — "
        "the minimum extrudable width is user input and this law will not default it");
  const Vec3 bdir = vunit(params.build_dir);
  if (!(vlen(bdir) > 0.5))
    throw std::invalid_argument(
        "trace_organic_lattice: build_dir must be a non-degenerate direction");
  if (params.families < 1 || params.families > 3)
    throw std::invalid_argument(
        "trace_organic_lattice: families must be 1, 2 or 3");

  OrganicLattice out;
  OrganicReport& rep = out.report;
  const double h = grid.spacing;
  const double t_strut = params.strut_diameter_mm > 0.0
                             ? params.strut_diameter_mm
                             : params.min_extrudable_width_mm;
  if (!(t_strut >= params.min_extrudable_width_mm))
    throw std::invalid_argument(
        "trace_organic_lattice: strut_diameter_mm is below the stated minimum "
        "extrudable width");
  const double r_strut = 0.5 * t_strut;
  rep.strut_diameter_mm = t_strut;
  rep.min_extrudable_width_mm = params.min_extrudable_width_mm;

  // ── §1(a): the principal frame, per candidate voxel, in voxel order ───────────
  std::vector<Vec3> dirf(3 * n, Vec3{0, 0, 0});
  std::vector<double> lam0(n, 0.0), lam1(n, 0.0), lam2(n, 0.0);
  std::vector<char> ok(n, 0);
  std::vector<double> dsep(n, 0.0);
  double sp_lo = 0.0, sp_hi = 0.0;
  bool sp_any = false;
  // ★ §2(d) — THE PRINTABLE FLOOR ON THE SEPARATION, and it is the coupling itself:
  // rho(d, t) = 3*pi*t^2 / (4 d^2) <= 1  =>  d >= t * sqrt(3 pi) / 2. Tighter than
  // that and the three families put more solid through the box than there is box.
  const double d_print_floor_mm = 0.5 * t_strut * std::sqrt(3.0 * M_PI);
  // ★ AND THE ONE THAT ACTUALLY BINDS ON A REAL PART: the tracer integrates a field
  // sampled at the VOXEL GRID, so it cannot resolve a separation finer than the grid.
  // Asking it to is not conservative, it is meaningless — the curves would all follow
  // the same interpolated direction and the "grade" would be an artefact of the
  // interpolation rather than of the stress.
  const double d_res_floor_mm = std::max(0.0, params.resolution_floor_voxels) * h;
  rep.spacing_print_floor_mm = d_print_floor_mm;
  rep.spacing_resolution_floor_mm = d_res_floor_mm;
  for (std::size_t e = 0; e < n; ++e) {
    if (!candidate[e]) continue;
    ++rep.candidate_voxels;
    double sp = spacing_mm[e];
    if (!(sp > 0.0) || !std::isfinite(sp))
      throw std::invalid_argument(
          "trace_organic_lattice: spacing_mm must be finite and > 0 on every "
          "candidate voxel");
    if (sp < d_print_floor_mm) {
      sp = d_print_floor_mm;
      ++rep.spacing_raised_for_print_voxels;
    }
    if (sp < d_res_floor_mm) {
      sp = d_res_floor_mm;
      ++rep.spacing_raised_for_resolution_voxels;
    }
    dsep[e] = sp;
    if (!sp_any) { sp_lo = sp_hi = sp; sp_any = true; }
    sp_lo = std::min(sp_lo, sp);
    sp_hi = std::max(sp_hi, sp);
    double m[6];
    for (int c = 0; c < 6; ++c) m[c] = stress[6 * e + c];
    double ev[3];
    Vec3 vec[3];
    jacobi_eigen(m, ev, vec);
    lam0[e] = ev[0];
    lam1[e] = ev[1];
    lam2[e] = ev[2];
    if (!(std::fabs(ev[0]) > 0.0)) {
      // A voxel carrying no stress at all has NO principal direction. It is not
      // traceable and it is COUNTED, never silently given an axis.
      ++rep.degenerate_voxels;
      continue;
    }
    if (std::fabs(ev[1]) >= kOrganicDegenerateRatio * std::fabs(ev[0]))
      ++rep.degenerate_voxels;  // traceable, but the frame is not determined (§6d)
    for (int f = 0; f < 3; ++f) dirf[3 * e + f] = vec[f];
    ok[e] = 1;
  }
  rep.requested_spacing_min_mm = sp_any ? sp_lo : 0.0;
  rep.requested_spacing_max_mm = sp_any ? sp_hi : 0.0;
  rep.degenerate_fraction =
      rep.candidate_voxels ? static_cast<double>(rep.degenerate_voxels) /
                                 static_cast<double>(rep.candidate_voxels)
                           : 0.0;
  out.mask.assign(n, 0);
  out.relative_density.assign(n, 0.0);
  out.spacing_used_mm.assign(n, 0.0);
  for (std::size_t e = 0; e < n; ++e)
    if (candidate[e]) out.spacing_used_mm[e] = dsep[e];
  if (rep.candidate_voxels == 0) return out;

  // ── the overhang cone (§2a/§2b) ──────────────────────────────────────────────
  const bool clamp_armed =
      params.overhang_angle_deg > 0.0 && params.overhang_angle_deg < 90.0;
  const double cos_cone =
      clamp_armed ? std::cos(params.overhang_angle_deg * M_PI / 180.0) : 0.0;
  rep.overhang_clamp_armed = clamp_armed;
  rep.overhang_angle_deg_used = clamp_armed ? params.overhang_angle_deg : 0.0;
  const double cos45 = std::cos(kOrganicTextbookOverhangDeg * M_PI / 180.0);

  auto voxel_of = [&](const Vec3& p, int& i, int& j, int& k) {
    i = static_cast<int>(std::floor((p.x - grid.origin.x) / h));
    j = static_cast<int>(std::floor((p.y - grid.origin.y) / h));
    k = static_cast<int>(std::floor((p.z - grid.origin.z) / h));
  };
  auto inside = [&](const Vec3& p) -> long long {
    int i, j, k;
    voxel_of(p, i, j, k);
    if (i < 0 || j < 0 || k < 0 || i >= grid.nx || j >= grid.ny || k >= grid.nz)
      return -1;
    const std::size_t e = grid.index(i, j, k);
    return candidate[e] ? static_cast<long long>(e) : -1;
  };

  // ── THE DIRECTION FIELD AT AN ARBITRARY POINT ───────────────────────────────
  // Trilinear over the eight surrounding VOXEL CENTRES, restricted to traceable
  // voxels and renormalised over the contributors, every contributor SIGN-ALIGNED to
  // `ref` first. Sign alignment is what makes a LINE field integrable: without it two
  // adjacent voxels holding the same axis with opposite signs interpolate to zero in
  // the middle. `flipped` reports whether any contributor had to be flipped — the
  // frame-swap tell §6(d) asks to be counted.
  auto field_dir = [&](const Vec3& p, int family, const Vec3& ref,
                       bool* flipped) -> Vec3 {
    const double fx = (p.x - grid.origin.x) / h - 0.5;
    const double fy = (p.y - grid.origin.y) / h - 0.5;
    const double fz = (p.z - grid.origin.z) / h - 0.5;
    const int i0 = static_cast<int>(std::floor(fx));
    const int j0 = static_cast<int>(std::floor(fy));
    const int k0 = static_cast<int>(std::floor(fz));
    const double tx = fx - i0, ty = fy - j0, tz = fz - k0;
    Vec3 acc{0, 0, 0};
    double wsum = 0.0;
    bool flip = false;
    for (int dk = 0; dk < 2; ++dk)
      for (int dj = 0; dj < 2; ++dj)
        for (int di = 0; di < 2; ++di) {
          const int i = i0 + di, j = j0 + dj, k = k0 + dk;
          if (i < 0 || j < 0 || k < 0 || i >= grid.nx || j >= grid.ny ||
              k >= grid.nz)
            continue;
          const std::size_t e = grid.index(i, j, k);
          if (!ok[e]) continue;
          const double w =
              (di ? tx : 1.0 - tx) * (dj ? ty : 1.0 - ty) * (dk ? tz : 1.0 - tz);
          if (!(w > 0.0)) continue;
          Vec3 d = dirf[3 * e + family];
          if (vdot(d, ref) < 0.0) { d = vmul(d, -1.0); flip = true; }
          acc = vadd(acc, vmul(d, w));
          wsum += w;
        }
    if (flipped) *flipped = flip;
    if (!(wsum > 0.0)) return Vec3{0, 0, 0};
    return vunit(acc);
  };

  // ── §2(a): PROJECT ONTO THE NEAREST IN-CONE DIRECTION, IN THE LOOP ───────────
  // NEVER a repair pass. The nearest in-cone direction to d keeps d's transverse
  // component and rotates toward the build axis until the cone angle is met exactly;
  // the sign of the axial term is d's own, so a curve heading up keeps heading up. A
  // purely transverse d takes +build_dir, a fixed choice.
  auto clamp_to_cone = [&](const Vec3& d, bool* moved) -> Vec3 {
    if (moved) *moved = false;
    if (!clamp_armed) return d;
    const double ax = vdot(d, bdir);
    if (std::fabs(ax) >= cos_cone) return d;
    Vec3 tr = vsub(d, vmul(bdir, ax));
    const double trl = vlen(tr);
    if (!(trl > 0.0)) return d;  // already along the axis; nothing to project
    tr = vmul(tr, 1.0 / trl);
    const double sgn = ax >= 0.0 ? 1.0 : -1.0;
    const double sin_cone = std::sqrt(std::max(0.0, 1.0 - cos_cone * cos_cone));
    if (moved) *moved = true;
    return vunit(vadd(vmul(bdir, sgn * cos_cone), vmul(tr, sin_cone)));
  };

  // ── the spacing structures ──────────────────────────────────────────────────
  const Vec3 bb_lo{grid.origin.x, grid.origin.y, grid.origin.z};
  const Vec3 bb_hi{grid.origin.x + grid.nx * h, grid.origin.y + grid.ny * h,
                   grid.origin.z + grid.nz * h};
  // ONE HASH PER FAMILY: separation is a WITHIN-family rule (§1c) and connection the
  // ACROSS-family one (§1d), so they must not share a structure.
  const double hash_cell = std::max(sp_hi * std::max(1.0, params.connect_ratio), h);
  std::array<SampleHash, 3> hash;
  for (int f = 0; f < 3; ++f) hash[f].init(bb_lo, bb_hi, hash_cell);

  auto dsep_at = [&](const Vec3& p) -> double {
    const long long e = inside(p);
    return e >= 0 ? dsep[static_cast<std::size_t>(e)] : 0.0;
  };

  std::vector<OrganicCurve> curves;

  // Nearest same-family sample to p, EXCLUDING curve `skip` — the self-exclusion that
  // lets a curve run without stopping on its own tail one step back.
  auto nearest_dist = [&](int family, const Vec3& p, int skip) -> double {
    const SampleHash& H = hash[family];
    int i, j, k;
    H.coords(p, i, j, k);
    double best = 1e300;
    for (int dk = -1; dk <= 1; ++dk)
      for (int dj = -1; dj <= 1; ++dj)
        for (int di = -1; di <= 1; ++di) {
          const int a = i + di, b = j + dj, c = k + dk;
          if (a < 0 || b < 0 || c < 0 || a >= H.nx || b >= H.ny || c >= H.nz)
            continue;
          for (const auto& s : H.buckets[H.bindex(a, b, c)]) {
            if (s.first == skip) continue;
            const double d = vlen(vsub(p, curves[s.first].points[s.second]));
            if (d < best) best = d;
          }
        }
    return best;
  };

  // ── §1(b): the trace ────────────────────────────────────────────────────────
  enum class StopReason { LeftRegion, HitDTest, NoDirection, StepBudget };
  struct HalfTrace {
    std::vector<Vec3> pts;
    long long steps = 0;
    long long clamped = 0;
    long long flips = 0;
    bool budget_hit = false;
    StopReason stop = StopReason::NoDirection;
  };
  auto trace_half = [&](const Vec3& seed, int family, double sign,
                        int self_index) -> HalfTrace {
    HalfTrace HT;
    Vec3 p = seed;
    const long long se = inside(p);
    if (se < 0) return HT;
    Vec3 ref = vmul(dirf[3 * static_cast<std::size_t>(se) + family], sign);
    if (!(vlen(ref) > 0.0)) return HT;
    HT.pts.push_back(p);
    int step = 0;
    for (; step < params.max_steps_per_curve; ++step) {
      const double ds = dsep_at(p);
      if (!(ds > 0.0)) { HT.stop = StopReason::LeftRegion; break; }
      const double dt = params.step_ratio * ds;
      bool f1 = false, f2 = false, f3 = false, f4 = false;
      const Vec3 k1 = field_dir(p, family, ref, &f1);
      if (!(vlen(k1) > 0.0)) { HT.stop = StopReason::NoDirection; break; }
      const Vec3 k2 = field_dir(vadd(p, vmul(k1, 0.5 * dt)), family, k1, &f2);
      const Vec3 k3 = field_dir(vadd(p, vmul(k2, 0.5 * dt)), family, k1, &f3);
      const Vec3 k4 = field_dir(vadd(p, vmul(k3, dt)), family, k1, &f4);
      Vec3 dir = vunit(vadd(vadd(vmul(k1, 1.0 / 6.0), vmul(k2, 1.0 / 3.0)),
                            vadd(vmul(k3, 1.0 / 3.0), vmul(k4, 1.0 / 6.0))));
      if (!(vlen(dir) > 0.0)) dir = k1;
      if (f1 || f2 || f3 || f4) ++HT.flips;
      bool moved = false;
      dir = clamp_to_cone(dir, &moved);
      if (moved) ++HT.clamped;
      const Vec3 q = vadd(p, vmul(dir, dt));
      if (inside(q) < 0) {  // left the candidate set — §1(b)'s stop
        HT.stop = StopReason::LeftRegion;
        break;
      }
      // ★ JOBARD-LEFER'S STOP RULE: within d_test of another curve of this family.
      if (nearest_dist(family, q, self_index) < params.test_ratio * ds) {
        HT.stop = StopReason::HitDTest;
        break;
      }
      HT.pts.push_back(q);
      ++HT.steps;
      p = q;
      ref = dir;
    }
    HT.budget_hit = step >= params.max_steps_per_curve;
    if (HT.budget_hit) HT.stop = StopReason::StepBudget;
    return HT;
  };

  // ── §1(c): the seed queue ───────────────────────────────────────────────────
  for (int family = 0; family < params.families; ++family) {
    // THE FIRST SEED: the traceable voxel with the largest |eigenvalue| for THIS
    // family, ties broken by ascending voxel index (§5a). Read off the cached
    // eigenvalues, so no second eigensolve and no chance of a different answer.
    std::size_t best_e = n;
    double best_mag = -1.0;
    for (std::size_t e = 0; e < n; ++e) {
      if (!ok[e]) continue;
      const double mag =
          std::fabs(family == 0 ? lam0[e] : family == 1 ? lam1[e] : lam2[e]);
      if (mag > best_mag) { best_mag = mag; best_e = e; }
    }
    if (best_e >= n) continue;
    std::vector<Vec3> queue;
    {
      const std::size_t layer = static_cast<std::size_t>(grid.nx) * grid.ny;
      const int k = static_cast<int>(best_e / layer);
      const int j = static_cast<int>((best_e % layer) / grid.nx);
      const int i = static_cast<int>(best_e % grid.nx);
      queue.push_back(Vec3{grid.origin.x + (i + 0.5) * h,
                           grid.origin.y + (j + 0.5) * h,
                           grid.origin.z + (k + 0.5) * h});
    }
    // ★ THE SWEEP CURSOR, AND WHY JOBARD-LEFER ALONE IS NOT ENOUGH HERE.
    //
    // Their algorithm grows the seed set ONLY from accepted curves, which is correct
    // in a connected 2D domain and WRONG on this part, twice over:
    //   * a curve DISCARDED as a stub offers no seeds, so its whole branch of the
    //     seed tree dies. Measured before this was added, on the maintainer's part:
    //     curves_per_family = [28, 534, 0] — the third principal family traced ZERO
    //     curves, because its first seed produced a stub and the queue then emptied.
    //   * his lattice is NINE declared regions, and a flood front cannot cross the
    //     solid between them. Whole regions would simply never be seeded.
    //
    // So when the queue is exhausted, a SWEEP in ASCENDING VOXEL INDEX looks for any
    // traceable voxel still further than d_sep from every curve of this family and
    // re-primes the flood there. The cursor is monotone — a voxel is tested once —
    // so the whole thing is one pass over the candidate set per family, and the order
    // is fixed, which is what keeps it deterministic (§5a).
    std::size_t qhead = 0;
    std::size_t sweep = 0;
    for (;;) {
      if (qhead >= queue.size()) {
        bool primed = false;
        for (; sweep < n; ++sweep) {
          if (!ok[sweep]) continue;
          const std::size_t layer = static_cast<std::size_t>(grid.nx) * grid.ny;
          const int sk = static_cast<int>(sweep / layer);
          const int sj = static_cast<int>((sweep % layer) / grid.nx);
          const int si = static_cast<int>(sweep % grid.nx);
          const Vec3 c{grid.origin.x + (si + 0.5) * h,
                       grid.origin.y + (sj + 0.5) * h,
                       grid.origin.z + (sk + 0.5) * h};
          if (nearest_dist(family, c, -1) < params.seed_ratio * dsep[sweep])
            continue;
          queue.push_back(c);
          ++sweep;
          primed = true;
          break;
        }
        if (!primed) break;  // the family is covered: no uncovered voxel remains
      }
      const Vec3 seed = queue[qhead++];
      if (static_cast<int>(curves.size()) >= params.max_curves) {
        rep.seed_budget_exhausted = true;
        break;
      }
      const long long se = inside(seed);
      if (se < 0 || !ok[static_cast<std::size_t>(se)]) {
        ++rep.seeds_outside_region;
        continue;
      }
      const double ds = dsep[static_cast<std::size_t>(se)];
      // A seed must be at least d_sep from every existing curve of its family.
      if (nearest_dist(family, seed, -1) < params.seed_ratio * ds) {
        ++rep.seeds_too_close;
        continue;
      }
      ++rep.seeds_traced;

      const int idx = static_cast<int>(curves.size());
      const HalfTrace fwd = trace_half(seed, family, +1.0, idx);
      const HalfTrace bwd = trace_half(seed, family, -1.0, idx);
      if (fwd.budget_hit || bwd.budget_hit) ++rep.step_budget_hits;
      for (const HalfTrace* ht : {&fwd, &bwd}) switch (ht->stop) {
        case StopReason::LeftRegion:  ++rep.stop_left_region;  break;
        case StopReason::HitDTest:    ++rep.stop_hit_d_test;   break;
        case StopReason::NoDirection: ++rep.stop_no_direction; break;
        case StopReason::StepBudget:  ++rep.stop_step_budget;  break;
      }
      OrganicCurve cv;
      cv.family = family;
      cv.radius_mm = r_strut;
      // The BACKWARD half reversed and joined in front of the seed; the seed is the
      // first point of both halves, so it is dropped from one of them.
      for (std::size_t t = bwd.pts.size(); t-- > 1;) cv.points.push_back(bwd.pts[t]);
      for (const Vec3& q : fwd.pts) cv.points.push_back(q);
      cv.steps = fwd.steps + bwd.steps;
      cv.clamped_steps = fwd.clamped + bwd.clamped;
      double L = 0.0;
      for (std::size_t t = 1; t < cv.points.size(); ++t)
        L += vlen(vsub(cv.points[t], cv.points[t - 1]));
      cv.length_mm = L;
      rep.total_steps += cv.steps;
      // Clamped at 1: a half-trace that aborts on its first iteration has still
      // evaluated the field and can have recorded a flip, so the raw ratio can exceed
      // 1 on a one-step curve. It is a FRACTION OF STEPS and is reported as one.
      if (cv.steps > 0)
        rep.max_frame_swap_fraction = std::max(
            rep.max_frame_swap_fraction,
            std::min(1.0, static_cast<double>(fwd.flips + bwd.flips) /
                              static_cast<double>(cv.steps)));
      if (cv.points.size() < 2 || L < params.min_length_ratio * ds) {
        ++rep.curves_too_short;
        continue;
      }
      // ACCEPTED. Register its samples, then offer the transverse seeds in the fixed
      // order (+e_a, -e_a, +e_b, -e_b) at stations one d_sep apart along the curve.
      for (std::size_t t = 0; t < cv.points.size(); ++t)
        hash[family].insert(cv.points[t], idx, static_cast<int>(t));
      const int stride = std::max(
          1, static_cast<int>(std::llround(1.0 / std::max(1e-9, params.step_ratio))));
      for (std::size_t t = 0; t < cv.points.size();
           t += static_cast<std::size_t>(stride)) {
        const long long pe = inside(cv.points[t]);
        if (pe < 0) continue;
        const std::size_t pu = static_cast<std::size_t>(pe);
        if (!ok[pu]) continue;
        const double sd = dsep[pu] * params.seed_ratio;
        const int fa = (family + 1) % 3, fb = (family + 2) % 3;
        const Vec3 ea = dirf[3 * pu + fa], eb = dirf[3 * pu + fb];
        const Vec3 offs[4] = {vmul(ea, sd), vmul(ea, -sd), vmul(eb, sd),
                              vmul(eb, -sd)};
        for (const Vec3& o : offs) {
          ++rep.seeds_offered;
          const Vec3 cand_pt = vadd(cv.points[t], o);
          if (inside(cand_pt) < 0) { ++rep.seeds_outside_region; continue; }
          queue.push_back(cand_pt);
        }
      }
      rep.curve_length_per_family_mm[family] += cv.length_mm;
      curves.push_back(std::move(cv));
      ++rep.curves_per_family[family];
    }
  }
  rep.curves_traced = curves.size();

  // ── §1(e): THIN BEFORE CONNECTING, IN DESCENDING LENGTH ─────────────────────
  // "delete a curve within a threshold of a like-oriented neighbour, processing in
  // order of DESCENDING LENGTH so long load paths survive". The spacing rule already
  // holds curves d_test apart at trace time, so this is a backstop against pairs
  // seeded before either had registered samples; the count MEASURES how often that
  // happened rather than assuming it never does.
  std::vector<int> order(curves.size());
  for (std::size_t t = 0; t < order.size(); ++t) order[t] = static_cast<int>(t);
  std::stable_sort(order.begin(), order.end(), [&curves](int a, int b) {
    return curves[a].length_mm > curves[b].length_mm;
  });
  std::vector<char> keep(curves.size(), 0);
  {
    std::array<SampleHash, 3> kept_hash;
    for (int f = 0; f < 3; ++f) kept_hash[f].init(bb_lo, bb_hi, hash_cell);
    auto near_kept = [&](int family, const Vec3& p) -> double {
      const SampleHash& H = kept_hash[family];
      int i, j, k;
      H.coords(p, i, j, k);
      double best = 1e300;
      for (int dk = -1; dk <= 1; ++dk)
        for (int dj = -1; dj <= 1; ++dj)
          for (int di = -1; di <= 1; ++di) {
            const int a = i + di, b = j + dj, c = k + dk;
            if (a < 0 || b < 0 || c < 0 || a >= H.nx || b >= H.ny || c >= H.nz)
              continue;
            for (const auto& s : H.buckets[H.bindex(a, b, c)]) {
              const double d = vlen(vsub(p, curves[s.first].points[s.second]));
              if (d < best) best = d;
            }
          }
      return best;
    };
    for (int ci : order) {
      const OrganicCurve& cv = curves[ci];
      std::size_t close = 0;
      for (const Vec3& p : cv.points) {
        const double ds = dsep_at(p);
        if (!(ds > 0.0)) continue;
        if (near_kept(cv.family, p) < params.thin_ratio * ds) ++close;
      }
      if (close * 2 > cv.points.size()) { ++rep.curves_thinned; continue; }
      keep[ci] = 1;
      for (std::size_t t = 0; t < cv.points.size(); ++t)
        kept_hash[cv.family].insert(cv.points[t], ci, static_cast<int>(t));
    }
  }
  // Compact, PRESERVING TRACE ORDER (not the thinning order) so the emitted file's
  // order is the trace order and stays stable under a change to the thinning rule.
  for (std::size_t t = 0; t < curves.size(); ++t)
    if (keep[t]) out.curves.push_back(curves[t]);
  rep.curves_kept = out.curves.size();
  for (const OrganicCurve& cv : out.curves) rep.total_curve_length_mm += cv.length_mm;

  // ── §1(d): CONNECT THE FAMILIES ─────────────────────────────────────────────
  // ★ THIS IS WHAT KEEPS THE LATTICE CONNECTED. There is no grid here, so no node is
  // inherited: connectivity is CONSTRUCTED, and R3 is the measurement of whether the
  // construction worked.
  //
  // Daynes step 5: where two curves of DIFFERENT families come within a threshold,
  // join them with a connector whose direction is the CROSS PRODUCT of their tangents
  // at the nearest points. That direction is not imposed — the shortest segment
  // between two curves is perpendicular to both tangents, which IS the cross product,
  // and `cross_deviation_deg` measures it rather than assuming it.
  //
  // ★ ONE CONNECTOR PER **NEAR-APPROACH**, NOT PER CURVE PAIR, and the difference is
  // the whole bar. The first version emitted one connector per (curve_a, curve_b)
  // pair: on the maintainer's part that produced 567 connectors for 562 curves, 469
  // curves with NO connection at all, and 470 connected components. Two long curves
  // that run alongside each other for 80 mm need bracing along their whole length,
  // not once. So each curve is walked at STATIONS one separation apart and joined to
  // its nearest other-family neighbour at each station, with a minimum spacing of one
  // d_sep between consecutive connectors on the same curve so the population stays
  // the same scale as the curve population.
  {
    std::array<SampleHash, 3> kh;
    for (int f = 0; f < 3; ++f) kh[f].init(bb_lo, bb_hi, hash_cell);
    for (std::size_t ci = 0; ci < out.curves.size(); ++ci)
      for (std::size_t t = 0; t < out.curves[ci].points.size(); ++t)
        kh[out.curves[ci].family].insert(out.curves[ci].points[t],
                                         static_cast<int>(ci), static_cast<int>(t));
    auto tangent = [](const OrganicCurve& C, int p) {
      const int lo = std::max(0, p - 1);
      const int hi = std::min(static_cast<int>(C.points.size()) - 1, p + 1);
      return vunit(vsub(C.points[hi], C.points[lo]));
    };
    double dev_sum = 0.0;
    const int stride = std::max(
        1, static_cast<int>(std::llround(1.0 / std::max(1e-9, params.step_ratio))));
    // Curves in index order, stations in order: a fixed traversal, so the connector
    // list is reproducible without any sort.
    for (std::size_t ci = 0; ci < out.curves.size(); ++ci) {
      const OrganicCurve& A = out.curves[ci];
      bool have_last = false;
      Vec3 last_at{0, 0, 0};
      for (std::size_t t = 0; t < A.points.size();
           t += static_cast<std::size_t>(stride)) {
        const Vec3& p = A.points[t];
        const double ds = dsep_at(p);
        if (!(ds > 0.0)) continue;
        // Keep consecutive connectors on this curve at least one separation apart —
        // otherwise a curve running alongside another accumulates a solid wall of
        // connectors instead of a lattice.
        if (have_last && vlen(vsub(p, last_at)) < ds) continue;
        const double R = params.connect_ratio * ds;
        double best = R;
        int best_curve = -1, best_pt = 0;
        for (int f = 0; f < params.families; ++f) {
          if (f == A.family) continue;
          const SampleHash& H = kh[f];
          int i, j, k;
          H.coords(p, i, j, k);
          for (int dk = -1; dk <= 1; ++dk)
            for (int dj = -1; dj <= 1; ++dj)
              for (int di = -1; di <= 1; ++di) {
                const int a = i + di, b = j + dj, c = k + dk;
                if (a < 0 || b < 0 || c < 0 || a >= H.nx || b >= H.ny || c >= H.nz)
                  continue;
                for (const auto& sm : H.buckets[H.bindex(a, b, c)]) {
                  const double d =
                      vlen(vsub(p, out.curves[sm.first].points[sm.second]));
                  // Strict <, over a fixed traversal, so the winner is reproducible.
                  if (d < best) { best = d; best_curve = sm.first; best_pt = sm.second; }
                }
              }
        }
        if (best_curve < 0) continue;
        // ★ REFINE TO THE MUTUAL NEAREST PAIR, and this is what restores Daynes'
        // cross-product direction. The station search above minimises over curve B for
        // a FIXED point on curve A, so the segment it finds is perpendicular to B's
        // tangent but NOT to A's — measured on the axis-aligned fixture, that reads as
        // a 78-degree mean deviation from the cross product, which is not a defect in
        // the construction but in where the endpoints were taken. Alternating the
        // minimisation a few times inside a LOCAL WINDOW lands on a mutual local
        // minimum, and the shortest segment between two curves is perpendicular to
        // BOTH tangents — which is exactly the cross product. Fixed window, fixed
        // iteration count, strict <: no search heuristic, nothing to make it drift.
        int ai = static_cast<int>(t), bi = best_pt;
        {
          const OrganicCurve& B = out.curves[best_curve];
          const int W = 2 * stride;
          for (int it = 0; it < 3; ++it) {
            int nb = bi;
            double db = vlen(vsub(A.points[ai], B.points[bi]));
            for (int q = std::max(0, bi - W);
                 q <= std::min(static_cast<int>(B.points.size()) - 1, bi + W); ++q) {
              const double d = vlen(vsub(A.points[ai], B.points[q]));
              if (d < db) { db = d; nb = q; }
            }
            bi = nb;
            int na = ai;
            double da = vlen(vsub(A.points[ai], B.points[bi]));
            for (int q = std::max(0, ai - W);
                 q <= std::min(static_cast<int>(A.points.size()) - 1, ai + W); ++q) {
              const double d = vlen(vsub(A.points[q], B.points[bi]));
              if (d < da) { da = d; na = q; }
            }
            ai = na;
          }
          best_pt = bi;
        }
        OrganicConnector cn;
        // Recorded with curve_a < curve_b so the graph edge reads the same whichever
        // end found it; `a`/`b` follow that ordering too.
        const int u = static_cast<int>(ci), v = best_curve;
        const Vec3 pu = A.points[ai], pv = out.curves[best_curve].points[best_pt];
        cn.curve_a = std::min(u, v);
        cn.curve_b = std::max(u, v);
        cn.a = (u < v) ? pu : pv;
        cn.b = (u < v) ? pv : pu;
        cn.radius_mm = r_strut;
        cn.length_mm = vlen(vsub(cn.b, cn.a));
        if (!(cn.length_mm > 1e-9)) continue;  // coincident: nothing to sweep
        const Vec3 ta = tangent(A, ai);
        const Vec3 tb = tangent(out.curves[best_curve], best_pt);
        const Vec3 x = vunit(vcross(ta, tb));
        const Vec3 seg = vunit(vsub(cn.b, cn.a));
        if (vlen(x) > 0.0) {
          double cosang = std::fabs(vdot(x, seg));
          cosang = std::min(1.0, std::max(0.0, cosang));
          cn.cross_deviation_deg = std::acos(cosang) * 180.0 / M_PI;
        }
        // The deviation is only MEANINGFUL where the two curves are further apart
        // than the polyline sampling can resolve — see the header's note on the
        // degenerate near-intersection case.
        const double resolve_mm = std::max(t_strut, params.step_ratio * ds);
        if (cn.length_mm > resolve_mm) {
          dev_sum += cn.cross_deviation_deg;
          ++rep.connectors_cross_measured;
          rep.max_connector_cross_deviation_deg =
              std::max(rep.max_connector_cross_deviation_deg, cn.cross_deviation_deg);
        } else {
          ++rep.connectors_shorter_than_strut;
        }
        out.curves[u].connections += 1;
        out.curves[v].connections += 1;
        out.connectors.push_back(cn);
        have_last = true;
        last_at = p;
      }
    }
    rep.connectors = out.connectors.size();
    rep.mean_connector_cross_deviation_deg =
        rep.connectors_cross_measured
            ? dev_sum / static_cast<double>(rep.connectors_cross_measured)
            : 0.0;
    std::vector<double> lens;
    lens.reserve(out.connectors.size());
    for (const OrganicConnector& cn : out.connectors) lens.push_back(cn.length_mm);
    if (!lens.empty()) {
      std::sort(lens.begin(), lens.end());  // full sort, never a sample
      rep.connector_min_length_mm = lens.front();
      rep.connector_max_length_mm = lens.back();
      rep.connector_median_length_mm = lens[lens.size() / 2];
    }
  }

  // ── R3: the connectivity measurement ────────────────────────────────────────
  for (const OrganicCurve& cv : out.curves) {
    if (cv.connections == 0) ++rep.curves_with_no_connection;
    if (cv.connections < 2) ++rep.curves_with_fewer_than_two_connections;
  }
  {
    std::vector<int> par(out.curves.size());
    for (std::size_t t = 0; t < par.size(); ++t) par[t] = static_cast<int>(t);
    std::function<int(int)> find = [&par](int a) {
      while (par[a] != a) { par[a] = par[par[a]]; a = par[a]; }
      return a;
    };
    for (const OrganicConnector& cn : out.connectors) {
      const int ra = find(cn.curve_a), rb = find(cn.curve_b);
      if (ra != rb) par[std::max(ra, rb)] = std::min(ra, rb);
    }
    std::map<int, std::size_t> comp;
    for (std::size_t t = 0; t < par.size(); ++t) ++comp[find(static_cast<int>(t))];
    rep.connected_components = comp.size();
    for (const auto& kv : comp)
      rep.largest_component_curves =
          std::max(rep.largest_component_curves, kv.second);
    rep.largest_component_fraction =
        out.curves.empty() ? 0.0
                           : static_cast<double>(rep.largest_component_curves) /
                                 static_cast<double>(out.curves.size());
  }

  // ── §2(b) / R6: the clamp's effect, and the 45-degree counterfactual ────────
  {
    long long csegs = 0, cout45 = 0, coutdef = 0;   // traced curve spans
    long long xsegs = 0, xout45 = 0, xoutdef = 0;   // connectors
    auto tally = [&](const Vec3& a, const Vec3& b, long long& segs,
                     long long& out45, long long& outdef) {
      const Vec3 d = vunit(vsub(b, a));
      if (!(vlen(d) > 0.0)) return;
      ++segs;
      // The 1e-9 is the ROUNDING of the clamp itself, not a budget: a clamped
      // direction lands on |dot| == cos(angle) to within the last bit of a unit
      // vector, and without it every clamped step would be reported as a violation
      // of the clamp that produced it.
      const double ax = std::fabs(vdot(d, bdir));
      if (ax < cos45 - 1e-9) ++out45;
      if (clamp_armed && ax < cos_cone - 1e-9) ++outdef;
    };
    // The clamp fraction is over the KEPT curves' steps — the geometry that was
    // actually emitted. `total_steps` counts every step ever traced, including the
    // stubs that were discarded, and dividing by it would understate the clamp.
    long long kept_steps = 0;
    for (const OrganicCurve& cv : out.curves) {
      rep.clamped_steps += cv.clamped_steps;
      kept_steps += cv.steps;
      if (cv.clamped_steps > 0) ++rep.curves_touched_by_clamp;
      for (std::size_t t = 1; t < cv.points.size(); ++t)
        tally(cv.points[t - 1], cv.points[t], csegs, cout45, coutdef);
    }
    for (const OrganicConnector& cn : out.connectors)
      tally(cn.a, cn.b, xsegs, xout45, xoutdef);
    const long long segs = csegs + xsegs;
    rep.segments_outside_45_fraction =
        segs ? static_cast<double>(cout45 + xout45) / static_cast<double>(segs) : 0.0;
    rep.segments_outside_default_fraction =
        segs ? static_cast<double>(coutdef + xoutdef) / static_cast<double>(segs)
             : 0.0;
    rep.curve_segments_outside_45_fraction =
        csegs ? static_cast<double>(cout45) / static_cast<double>(csegs) : 0.0;
    rep.connectors_outside_45_fraction =
        xsegs ? static_cast<double>(xout45) / static_cast<double>(xsegs) : 0.0;
    rep.clamped_step_fraction =
        kept_steps ? static_cast<double>(rep.clamped_steps) /
                         static_cast<double>(kept_steps)
                   : 0.0;
    rep.curves_touched_fraction =
        out.curves.empty() ? 0.0
                           : static_cast<double>(rep.curves_touched_by_clamp) /
                                 static_cast<double>(out.curves.size());
  }

  // ── R5: the ACHIEVED spacing, MEASURED from the geometry ───────────────────
  // For each kept curve, the distance from a station on it to the nearest point of a
  // DIFFERENT curve of the SAME family — the separation the layout actually achieved,
  // not the one that was requested. Stations one d_sep apart at a fixed stride, and a
  // FULL SORT for the median (§5b: never a sampled estimate).
  {
    std::array<SampleHash, 3> kh;
    for (int f = 0; f < 3; ++f) kh[f].init(bb_lo, bb_hi, hash_cell);
    for (std::size_t ci = 0; ci < out.curves.size(); ++ci)
      for (std::size_t t = 0; t < out.curves[ci].points.size(); ++t)
        kh[out.curves[ci].family].insert(out.curves[ci].points[t],
                                         static_cast<int>(ci), static_cast<int>(t));
    std::vector<double> seps;
    const int stride = std::max(
        1, static_cast<int>(std::llround(1.0 / std::max(1e-9, params.step_ratio))));
    for (std::size_t ci = 0; ci < out.curves.size(); ++ci) {
      const OrganicCurve& A = out.curves[ci];
      for (std::size_t t = 0; t < A.points.size();
           t += static_cast<std::size_t>(stride)) {
        const Vec3& p = A.points[t];
        const SampleHash& H = kh[A.family];
        int i, j, k;
        H.coords(p, i, j, k);
        double best = 1e300;
        for (int dk = -1; dk <= 1; ++dk)
          for (int dj = -1; dj <= 1; ++dj)
            for (int di = -1; di <= 1; ++di) {
              const int a = i + di, b = j + dj, c = k + dk;
              if (a < 0 || b < 0 || c < 0 || a >= H.nx || b >= H.ny || c >= H.nz)
                continue;
              for (const auto& s : H.buckets[H.bindex(a, b, c)]) {
                if (s.first == static_cast<int>(ci)) continue;
                const double d =
                    vlen(vsub(p, out.curves[s.first].points[s.second]));
                if (d < best) best = d;
              }
            }
        if (best < 1e299) seps.push_back(best);
      }
    }
    if (!seps.empty()) {
      std::sort(seps.begin(), seps.end());
      rep.achieved_spacing_min_mm = seps.front();
      rep.achieved_spacing_max_mm = seps.back();
      rep.achieved_spacing_median_mm = seps[seps.size() / 2];
    }
  }

  // ── §4(a): THE PER-VOXEL DENSITY. ALL THREE ALGORITHMS EMIT ONE. ───────────
  // ★ IT IS A HOMOGENISED DENSITY, NOT A PER-VOXEL OCCUPANCY, AND THE DIFFERENCE IS
  // THE WHOLE POINT. The first version of this measured the strut volume deposited in
  // each voxel alone and reported 0.159 where the analytic lattice density is 0.0191 —
  // an 8x error, and not a small one: at a 1 mm voxel and a 5 mm separation a voxel
  // either holds a bead or holds nothing, so a per-voxel figure is a BINARY OCCUPANCY
  // wearing a density's name. What the certification path consumes is a RELATIVE
  // DENSITY: the solid fraction of the lattice in a neighbourhood the size of its own
  // repeat. So the deposited volume is box-filtered over a window of the LOCAL
  // separation, which is the organic analogue of "one cell".
  //
  // The window is normalised by the CANDIDATE volume inside it, not by the whole box,
  // so a voxel near the region boundary is not reported thinner than it is merely for
  // sitting at the edge.
  //
  // Both sums come off SUMMED-AREA TABLES (3D prefix sums) in one fixed traversal —
  // exact, O(1) per query at any window size, no sampling anywhere (§5b).
  {
    std::vector<double> vol(n, 0.0);
    const double area = M_PI * r_strut * r_strut;
    auto deposit = [&](const Vec3& a, const Vec3& b) {
      const double L = vlen(vsub(b, a));
      if (!(L > 0.0)) return;
      const int m = std::max(1, static_cast<int>(std::ceil(L / (0.25 * h))));
      const double dl = L / m;
      for (int s = 0; s < m; ++s) {
        const double u = (s + 0.5) / m;
        const Vec3 p = vadd(a, vmul(vsub(b, a), u));
        int i, j, k;
        voxel_of(p, i, j, k);
        if (i < 0 || j < 0 || k < 0 || i >= grid.nx || j >= grid.ny ||
            k >= grid.nz)
          continue;
        vol[grid.index(i, j, k)] += area * dl;
      }
      rep.emitted_volume_mm3 += area * L;
    };
    for (const OrganicCurve& cv : out.curves)
      for (std::size_t t = 1; t < cv.points.size(); ++t)
        deposit(cv.points[t - 1], cv.points[t]);
    for (const OrganicConnector& cn : out.connectors) deposit(cn.a, cn.b);

    // Summed-area tables over (nx+1)(ny+1)(nz+1), inclusive prefix sums.
    const std::size_t sx = static_cast<std::size_t>(grid.nx) + 1;
    const std::size_t sy = static_cast<std::size_t>(grid.ny) + 1;
    const std::size_t sz = static_cast<std::size_t>(grid.nz) + 1;
    std::vector<double> sat_v(sx * sy * sz, 0.0), sat_c(sx * sy * sz, 0.0);
    auto S = [sx, sy](int i, int j, int k) {
      return (static_cast<std::size_t>(k) * sy + j) * sx + i;
    };
    for (int k = 1; k < static_cast<int>(sz); ++k)
      for (int j = 1; j < static_cast<int>(sy); ++j)
        for (int i = 1; i < static_cast<int>(sx); ++i) {
          const std::size_t e = grid.index(i - 1, j - 1, k - 1);
          const double add_v = vol[e];
          const double add_c = candidate[e] ? 1.0 : 0.0;
          sat_v[S(i, j, k)] = add_v + sat_v[S(i - 1, j, k)] + sat_v[S(i, j - 1, k)] +
                              sat_v[S(i, j, k - 1)] - sat_v[S(i - 1, j - 1, k)] -
                              sat_v[S(i - 1, j, k - 1)] - sat_v[S(i, j - 1, k - 1)] +
                              sat_v[S(i - 1, j - 1, k - 1)];
          sat_c[S(i, j, k)] = add_c + sat_c[S(i - 1, j, k)] + sat_c[S(i, j - 1, k)] +
                              sat_c[S(i, j, k - 1)] - sat_c[S(i - 1, j - 1, k)] -
                              sat_c[S(i - 1, j, k - 1)] - sat_c[S(i, j - 1, k - 1)] +
                              sat_c[S(i - 1, j - 1, k - 1)];
        }
    auto box = [&](const std::vector<double>& T, int i0, int j0, int k0, int i1,
                   int j1, int k1) {
      return T[S(i1, j1, k1)] - T[S(i0, j1, k1)] - T[S(i1, j0, k1)] -
             T[S(i1, j1, k0)] + T[S(i0, j0, k1)] + T[S(i0, j1, k0)] +
             T[S(i1, j0, k0)] - T[S(i0, j0, k0)];
    };

    const double vox = h * h * h;
    std::vector<double> rhos;
    for (int k = 0; k < grid.nz; ++k)
      for (int j = 0; j < grid.ny; ++j)
        for (int i = 0; i < grid.nx; ++i) {
          const std::size_t e = grid.index(i, j, k);
          if (!candidate[e]) continue;
          // HALF-WINDOW = half the local separation, so the window is one repeat of
          // the lattice across. At least one voxel either side, or the "homogenised"
          // figure degenerates back into the occupancy this block exists to avoid.
          const int rad = std::max(1, static_cast<int>(std::llround(0.5 * dsep[e] / h)));
          const int i0 = std::max(0, i - rad), i1 = std::min(grid.nx, i + rad + 1);
          const int j0 = std::max(0, j - rad), j1 = std::min(grid.ny, j + rad + 1);
          const int k0 = std::max(0, k - rad), k1 = std::min(grid.nz, k + rad + 1);
          const double v = box(sat_v, i0, j0, k0, i1, j1, k1);
          const double c = box(sat_c, i0, j0, k0, i1, j1, k1);
          if (!(v > 0.0) || !(c > 0.0)) continue;
          double rho = v / (c * vox);
          if (params.rho_max > 0.0 && rho > params.rho_max) {
            rho = params.rho_max;
            ++rep.rho_clamped_hi_voxels;
          }
          if (params.rho_min > 0.0 && rho < params.rho_min) {
            rho = params.rho_min;
            ++rep.rho_clamped_lo_voxels;
          }
          out.mask[e] = 1;
          out.relative_density[e] = rho;
          rhos.push_back(rho);
        }
    rep.latticed_voxels = rhos.size();
    if (!rhos.empty()) {
      std::sort(rhos.begin(), rhos.end());  // full sort, never a sample
      rep.rho_min_emitted = rhos.front();
      rep.rho_max_emitted = rhos.back();
      rep.rho_median_emitted = rhos[rhos.size() / 2];
    }
  }

  // ── §3(a) / R7: THE CURVE-CROSSING COUNT ───────────────────────────────────
  // curves_per_member(x) = member_width_mm(x) / spacing_mm(x): how many curves of one
  // family cross the member at x. The exact analogue of cells_per_member = W / S, and
  // it is reported UNDER ITS OWN NAME — the existing field keeps its own meaning
  // (§3a is explicit that overloading it would be wrong).
  if (width_mm) {
    std::vector<double> cpm;
    for (std::size_t e = 0; e < n; ++e) {
      if (!out.mask[e]) continue;
      const double w = (*width_mm)[e];
      const double d = dsep[e];
      if (!(d > 0.0) || !std::isfinite(w) || !(w > 0.0)) continue;
      cpm.push_back(w / d);
    }
    if (!cpm.empty()) {
      std::sort(cpm.begin(), cpm.end());  // full sort
      rep.min_curves_per_member = cpm.front();
      rep.median_curves_per_member = cpm[cpm.size() / 2];
      for (double c : cpm)
        if (c < kOrganicCurvesPerMemberFloor)
          ++rep.below_curves_per_member_floor_voxels;
      rep.curves_per_member_measured = true;
    }
  }
  return out;
}

// ────────────────────────────────────────────────────────────────────────────────
OrganicGenStats generate_organic_lattice(const OrganicLattice& lat,
                                         TriangleSink& sink,
                                         const LatticeBoundary* boundary,
                                         int nseg) {
  if (nseg < 3)
    throw std::invalid_argument("generate_organic_lattice: nseg must be >= 3");
  OrganicGenStats st;
  bool any = false;
  auto note = [&](double d) {
    if (!any) { st.min_strut_diameter_mm = st.max_strut_diameter_mm = d; any = true; }
    st.min_strut_diameter_mm = std::min(st.min_strut_diameter_mm, d);
    st.max_strut_diameter_mm = std::max(st.max_strut_diameter_mm, d);
  };
  // ★ THE SAME SWEPT SOLIDS THE OCTET GENERATOR EMITS, FROM THE SAME FUNCTIONS, so an
  // organic strut and a doubled strut are the same geometry at the same radius. That
  // is what stops a second strut law being born here — the app's already drifted
  // 1.4-1.7x by being re-derived once.
  // ★ ONE NODE BALL PER POINT, NOT ONE PER SPAN END. A polyline's interior vertex is
  // the end of one span and the start of the next, so emitting at both ends duplicates
  // it exactly — measured on the fixture: 11,364 balls for 5,682 spans, 227k of the
  // 409k triangles, and every duplicated ball welds into a non-manifold edge for
  // nothing. The octet generator avoids the same thing by cell-local ownership; here
  // the emission is sequential along a curve, so remembering the last point emitted is
  // all it takes. Reset per curve (and after a clip gap) so a genuine end still gets
  // its ball.
  bool have_last = false;
  Vec3 last_node{0, 0, 0};
  auto same_point = [](const Vec3& a, const Vec3& b) {
    return a.x == b.x && a.y == b.y && a.z == b.z;
  };
  auto emit_node_once = [&](const Vec3& p, double r) {
    lattice_emit_node(sink, p, r);
    st.triangles += 20;  // an icosahedron is exactly 20 triangles
    ++st.nodes;
    st.volume_mm3 += lattice_node_volume_mm3(r);
  };
  auto emit_span = [&](const Vec3& p0, const Vec3& p1, double r) {
    if (!(vlen(vsub(p1, p0)) > 0.0)) return;
    lattice_emit_strut(sink, p0, p1, r, nseg);
    st.triangles += static_cast<std::uint64_t>(4 * nseg);
    ++st.struts;
    st.volume_mm3 += lattice_prism_volume_mm3(r, vlen(vsub(p1, p0)), nseg);
    if (!have_last || !same_point(last_node, p0)) emit_node_once(p0, r);
    emit_node_once(p1, r);
    have_last = true;
    last_node = p1;
    note(2.0 * r);
  };
  auto span = [&](const Vec3& a, const Vec3& b, double r) {
    if (!boundary) { emit_span(a, b, r); return; }
    // CLIPPED TO THE ALLOWED REGION ERODED BY THIS STRUT'S OWN RADIUS — the swept
    // SOLID stays inside the part, never just the centreline. Exactly the discipline
    // the octet generator holds, using the same predicate.
    long long uncertified = 0;
    const std::vector<LatticeClipSpan> keep =
        boundary->clip_segment(a, b, r, -1, -1, &uncertified);
    st.uncertified_spans_dropped += uncertified;
    if (keep.empty()) { ++st.dropped_segments; return; }
    const bool whole =
        keep.size() == 1 && keep[0].t0 <= 0.0 && keep[0].t1 >= 1.0;
    if (!whole) ++st.clipped_segments;
    for (const LatticeClipSpan& s : keep) {
      // A clip GAP is a genuine end on both sides, so the run restarts.
      if (s.t0 > 0.0) have_last = false;
      const Vec3 p0 = vadd(a, vmul(vsub(b, a), s.t0));
      const Vec3 p1 = vadd(a, vmul(vsub(b, a), s.t1));
      emit_span(p0, p1, r);
    }
  };
  for (const OrganicCurve& cv : lat.curves) {
    have_last = false;  // a new curve starts a new run of shared points
    for (std::size_t t = 1; t < cv.points.size(); ++t)
      span(cv.points[t - 1], cv.points[t], cv.radius_mm);
  }
  for (const OrganicConnector& cn : lat.connectors) {
    have_last = false;  // each connector is its own two-ended run
    span(cn.a, cn.b, cn.radius_mm);
  }
  return st;
}

}  // namespace topopt
