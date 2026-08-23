// ★ THE ORGANIC LATTICE TRACER (task 2026-08-21-organic-lattice, §1 and §2).
// The header states the method, the evidence and every fixed order; this file is the
// arithmetic. Nothing here reads a job, a file or a clock.

#include "topopt/organic_lattice.hpp"

#include <algorithm>
#include <array>
#include <cmath>
#include <cstddef>
#include <cstdio>
#include <cstdlib>
#include <functional>
#include <map>
#include <set>
#include <stdexcept>
#include <utility>
#include <unordered_map>
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
  // ★ IS ANY REGISTERED SAMPLE WITHIN `r` OF p? The coverage question: does a kept
  // curve already occupy this patch, or would discarding a stub here leave it empty?
  // `pts` is the caller's point store, because the hash keeps indices, not positions.
  bool any_within(const Vec3& p, double r,
                  const std::vector<OrganicCurve>& cvs) const {
    int i, j, k;
    coords(p, i, j, k);
    const int span = std::max(1, static_cast<int>(std::ceil(r / cell)));
    const double r2 = r * r;
    for (int dk = -span; dk <= span; ++dk)
      for (int dj = -span; dj <= span; ++dj)
        for (int di = -span; di <= span; ++di) {
          const int a = i + di, b = j + dj, c = k + dk;
          if (a < 0 || b < 0 || c < 0 || a >= nx || b >= ny || c >= nz) continue;
          for (const std::pair<int, int>& e : buckets[bindex(a, b, c)]) {
            if (e.first < 0 || static_cast<std::size_t>(e.first) >= cvs.size()) continue;
            const std::vector<Vec3>& cp = cvs[e.first].points;
            if (e.second < 0 || static_cast<std::size_t>(e.second) >= cp.size()) continue;
            const Vec3 d = vsub(cp[e.second], p);
            if (vdot(d, d) <= r2) return true;
          }
        }
    return false;
  }
};

// Squared distance between two segments — the standard clamped-parameter solve.
// ONE implementation, shared by the tracer's connectivity report and the generator's,
// so the two can never disagree about what "touching" means.
double organic_segment_distance2(const Vec3& p1, const Vec3& q1, const Vec3& p2,
                                 const Vec3& q2) {
  const Vec3 d1 = vsub(q1, p1), d2 = vsub(q2, p2), r = vsub(p1, p2);
  const double a = vdot(d1, d1), e = vdot(d2, d2), f = vdot(d2, r);
  const double c = vdot(d1, r);
  double s, t;
  if (a <= 1e-18 && e <= 1e-18) return vdot(r, r);
  if (a <= 1e-18) { s = 0.0; t = std::min(1.0, std::max(0.0, f / e)); }
  else if (e <= 1e-18) { t = 0.0; s = std::min(1.0, std::max(0.0, -c / a)); }
  else {
    const double b = vdot(d1, d2);
    const double den = a * e - b * b;
    s = den > 1e-18 ? std::min(1.0, std::max(0.0, (b * f - c * e) / den)) : 0.0;
    t = (b * s + f) / e;
    if (t < 0.0) { t = 0.0; s = std::min(1.0, std::max(0.0, -c / a)); }
    else if (t > 1.0) { t = 1.0; s = std::min(1.0, std::max(0.0, (b - c) / a)); }
  }
  const Vec3 c1 = vadd(p1, vmul(d1, s)), c2 = vadd(p2, vmul(d2, t));
  return vdot(vsub(c1, c2), vsub(c1, c2));
}

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
  if (params.strut_diameter_field && params.strut_diameter_field->size() != n)
    throw std::invalid_argument(
        "trace_organic_lattice: strut_diameter_field size does not match the grid");
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
  // The relative density the CALLER asked for at voxel e, recovered from the (spacing,
  // bead) pair it handed in — the same coupling, read back. Used only by the bead
  // calibration below.
  auto spacing_mm_target_rho = [&](std::size_t e) {
    const double d = spacing_mm[e];
    const double t = params.strut_diameter_field ? (*params.strut_diameter_field)[e]
                                                 : params.strut_diameter_mm;
    return (d > 0.0 && t > 0.0) ? organic_density_at(d, t) : 0.0;
  };
  const double h = grid.spacing;
  const double t_strut = params.strut_diameter_mm > 0.0
                             ? params.strut_diameter_mm
                             : params.min_extrudable_width_mm;
  if (!(t_strut >= params.min_extrudable_width_mm))
    throw std::invalid_argument(
        "trace_organic_lattice: strut_diameter_mm is below the stated minimum "
        "extrudable width");
  const double r_strut = 0.5 * t_strut;
  // The bead at a point: the per-voxel field where one was supplied, else the scalar.
  // ALWAYS floored at the stated minimum extrudable width — the mass coupling may ask
  // for a thinner strut than the machine can lay, and printability is user input.
  const std::vector<double>* tfield = params.strut_diameter_field;
  auto bead_at_voxel = [&](std::size_t e) {
    const double t = tfield ? (*tfield)[e] : t_strut;
    return t > params.min_extrudable_width_mm ? t : params.min_extrudable_width_mm;
  };
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
  (void)d_print_floor_mm;
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
    // The printable floor on the separation is evaluated at THIS voxel's own bead:
    // d >= t*sqrt(3 pi)/2, below which three families put more solid through the box
    // than there is box.
    const double d_pf = 0.5 * bead_at_voxel(e) * std::sqrt(3.0 * M_PI);
    if (sp < d_pf) {
      sp = d_pf;
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
  enum class StopReason { LeftRegion, HitDTest, NoDirection, StepBudget,
                          TurnedTooFar, SelfRevisit };
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
    double turned = 0.0;          // accumulated unsigned turn angle (radians)
    Vec3 prev_dir = ref;
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
      // ★ ORBIT STOP. Past a full revolution of accumulated turning the curve is
      // going round rather than anywhere; the published algorithm stops it and so
      // does this one.
      {
        double cosang = vdot(prev_dir, dir);
        cosang = std::min(1.0, std::max(-1.0, cosang));
        turned += std::acos(cosang);
        prev_dir = dir;
        if (turned > kOrganicMaxTurnRevolutions * 2.0 * M_PI) {
          HT.stop = StopReason::TurnedTooFar;
          break;
        }
      }
      const Vec3 q = vadd(p, vmul(dir, dt));
      if (inside(q) < 0) {  // left the candidate set — §1(b)'s stop
        HT.stop = StopReason::LeftRegion;
        break;
      }
      // ★ CLOSED-LOOP STOP: within d_test of this curve's OWN trail, far enough back
      // that it is not the integrator's own footprint.
      {
        const std::size_t lag = static_cast<std::size_t>(std::max(
            2.0, kOrganicSelfRevisitLag / std::max(1e-9, params.step_ratio)));
        bool looped = false;
        if (HT.pts.size() > lag) {
          const double d2 = params.test_ratio * ds * params.test_ratio * ds;
          for (std::size_t t = 0; t + lag < HT.pts.size(); ++t) {
            const Vec3 w = vsub(q, HT.pts[t]);
            if (vdot(w, w) < d2) { looped = true; break; }
          }
        }
        if (looped) { HT.stop = StopReason::SelfRevisit; break; }
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
        case StopReason::TurnedTooFar: ++rep.stop_turned_too_far; break;
        case StopReason::SelfRevisit:  ++rep.stop_self_revisit;   break;
      }
      OrganicCurve cv;
      cv.family = family;
      cv.radius_mm = 0.5 * bead_at_voxel(static_cast<std::size_t>(se));
      // The BACKWARD half reversed and joined in front of the seed; the seed is the
      // first point of both halves, so it is dropped from one of them.
      for (std::size_t t = bwd.pts.size(); t-- > 1;) cv.points.push_back(bwd.pts[t]);
      for (const Vec3& q : fwd.pts) cv.points.push_back(q);
      cv.steps = fwd.steps + bwd.steps;
      cv.clamped_steps = fwd.clamped + bwd.clamped;
      // The BACKWARD half is reversed onto the front, so its stop is the curve's START.
      // Only an anchor when the export writes a shell for it to land on.
      cv.start_at_boundary =
          params.anchor_at_region_boundary && (bwd.stop == StopReason::LeftRegion);
      cv.end_at_boundary =
          params.anchor_at_region_boundary && (fwd.stop == StopReason::LeftRegion);
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
      // ── ★★ A STUB IS DISCARDED UNLESS IT IS THE ONLY THING COVERING ITS PATCH ──
      // Discarding curves shorter than one separation keeps the lattice from filling
      // with clutter, and in most of a part that is right. But where the direction
      // field is WEAK — the corner of a cube furthest from the load path — every curve
      // comes out short, so the rule discards ALL of them, and a discarded curve offers
      // no seeds, so the flood never reaches that region at all. Measured on the
      // maintainer's cube: 780 curves discarded against 361 kept, an 8 x 8 mm corner
      // column with NO MATERIAL from z = 4 upward, and an achieved spacing of 8.02 mm
      // against a 6.0 mm cap — the gap was not what the field asked for, it was what
      // was left after everything there was thrown away.
      //
      // So the test is no longer length alone: a short curve SURVIVES when no kept
      // curve of its own family already covers its midpoint. A grade may make a region
      // sparse; it may never make it absent.
      if (cv.points.size() < 2) { ++rep.curves_too_short; continue; }
      if (L < params.min_length_ratio * ds) {
        const Vec3 mid = cv.points[cv.points.size() / 2];
        // ★ REVERTED: keeping the stub here does not work, and the reason is worth
        // recording. A stub alone in an empty region is UNSUPPORTED BY CONSTRUCTION, so
        // the free-end prune and the mid-air pass delete it — 658 kept, 125 empty cells
        // against a 117 baseline, i.e. worse than doing nothing. Coverage cannot be
        // bought with material that the printability rules exist to remove. It is
        // bought instead by the FILL MAT, which is emitted as structure and reaches
        // into its neighbours so nothing downstream can call it loose.
        ++rep.curves_too_short;
        continue;
      }
      // ★ A COVERAGE STUB IS FILLER, NOT A SEEDING AUTHORITY. Registering its samples
      // marks its patch as occupied, so every later seed there is rejected as TOO CLOSE
      // — the stub blocks a real curve from ever being traced in the gap it was kept to
      // fill. Measured: registering them took the empty-cell count the wrong way, 117 ->
      // 152, while `curves_too_short` fell 780 -> 104 because far fewer were ever traced
      // at all. So a stub is emitted as geometry and otherwise invisible: it claims no
      // territory and offers no seeds.
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
        cn.pt_a = (u < v) ? ai : best_pt;
        cn.pt_b = (u < v) ? best_pt : ai;
        cn.a = (u < v) ? pu : pv;
        cn.b = (u < v) ? pv : pu;
        {
        const long long ce = inside(cn.a);
        cn.radius_mm = ce >= 0 ? 0.5 * bead_at_voxel(static_cast<std::size_t>(ce))
                               : 0.5 * bead_at_voxel(0);
      }
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
        const double resolve_mm =
            std::max(2.0 * cn.radius_mm, params.step_ratio * ds);
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

  // ── ★★ R3, MEASURED ON THE SOLIDS (see the header) ─────────────────────────
  // Union-find over every emitted segment, joined when the swept solids OVERLAP.
  // Bucketed by midpoint so the pair test is local; the bucket edge is the longest
  // segment plus twice the fattest radius, so any overlapping pair shares or
  // neighbours a bucket and none is missed.
  {
    struct Seg { Vec3 a, b; double r; double len; };
    std::vector<Seg> segs;
    for (const OrganicCurve& cv : out.curves)
      for (std::size_t t = 1; t < cv.points.size(); ++t)
        segs.push_back({cv.points[t - 1], cv.points[t], cv.radius_mm,
                        vlen(vsub(cv.points[t], cv.points[t - 1]))});
    for (const OrganicConnector& cn : out.connectors)
      segs.push_back({cn.a, cn.b, cn.radius_mm, cn.length_mm});
    rep.solid_segments = segs.size();
    if (!segs.empty()) {
      double reach = 0.0;
      for (const Seg& sg : segs) reach = std::max(reach, sg.len + 2.0 * sg.r);
      const double cell = std::max(reach, 1e-6);
      std::map<std::array<long long, 3>, std::vector<int>> grid_of;
      auto key = [cell](const Vec3& p) {
        return std::array<long long, 3>{
            static_cast<long long>(std::floor(p.x / cell)),
            static_cast<long long>(std::floor(p.y / cell)),
            static_cast<long long>(std::floor(p.z / cell))};
      };
      for (std::size_t i = 0; i < segs.size(); ++i) {
        const Vec3 mid = vmul(vadd(segs[i].a, segs[i].b), 0.5);
        grid_of[key(mid)].push_back(static_cast<int>(i));
      }
      std::vector<int> par(segs.size());
      for (std::size_t i = 0; i < par.size(); ++i) par[i] = static_cast<int>(i);
      std::function<int(int)> find = [&par](int a) {
        while (par[a] != a) { par[a] = par[par[a]]; a = par[a]; }
        return a;
      };
      // Squared distance between two segments — the standard clamped-parameter
      // solve, exact for the non-parallel case and correct at the clamps otherwise.
      auto seg_dist2 = organic_segment_distance2;
      for (const auto& kv : grid_of) {
        for (long long dz = -1; dz <= 1; ++dz)
          for (long long dy = -1; dy <= 1; ++dy)
            for (long long dx = -1; dx <= 1; ++dx) {
              const std::array<long long, 3> nk{kv.first[0] + dx, kv.first[1] + dy,
                                                kv.first[2] + dz};
              auto it = grid_of.find(nk);
              if (it == grid_of.end()) continue;
              for (int i : kv.second)
                for (int j : it->second) {
                  if (j <= i) continue;
                  const double touch = segs[i].r + segs[j].r;
                  if (seg_dist2(segs[i].a, segs[i].b, segs[j].a, segs[j].b) >
                      touch * touch)
                    continue;
                  const int ra = find(i), rb = find(j);
                  if (ra != rb) par[std::max(ra, rb)] = std::min(ra, rb);
                }
            }
      }
      std::map<int, double> comp_len;
      double total_len = 0.0;
      for (std::size_t i = 0; i < segs.size(); ++i) {
        comp_len[find(static_cast<int>(i))] += segs[i].len;
        total_len += segs[i].len;
      }
      rep.solid_components = comp_len.size();
      double biggest = 0.0;
      for (const auto& kv : comp_len) biggest = std::max(biggest, kv.second);
      rep.solid_largest_component_length_fraction =
          total_len > 0.0 ? biggest / total_len : 0.0;
      rep.solid_stranded_length_mm = total_len - biggest;
    }
  }

  // ── ★ §1(e2): TRIM DANGLING ENDS (see OrganicReport for why) ───────────────
  // Cut each curve back to its outermost connector. Ends that LEFT THE REGION are
  // kept — the boundary clip lands those on the shell, which anchors them. Iterated,
  // because trimming one curve can orphan its neighbour.
  for (rep.dangling_rounds = 0; rep.dangling_rounds < kOrganicTrimRounds;
       ++rep.dangling_rounds) {
    const std::size_t nc = out.curves.size();
    if (nc == 0) break;
    std::vector<int> lo(nc, -1), hi(nc, -1);
    for (const OrganicConnector& cn : out.connectors) {
      for (int side = 0; side < 2; ++side) {
        const int ci = side ? cn.curve_b : cn.curve_a;
        const int pt = side ? cn.pt_b : cn.pt_a;
        if (ci < 0 || static_cast<std::size_t>(ci) >= nc) continue;
        if (lo[ci] < 0 || pt < lo[ci]) lo[ci] = pt;
        if (hi[ci] < 0 || pt > hi[ci]) hi[ci] = pt;
      }
    }
    bool changed = false;
    std::vector<int> shift(nc, 0);      // how far each curve's start moved
    std::vector<char> drop(nc, 0);
    for (std::size_t ci = 0; ci < nc; ++ci) {
      OrganicCurve& cv = out.curves[ci];
      const int last = static_cast<int>(cv.points.size()) - 1;
      if (last < 1) { drop[ci] = 1; changed = true; continue; }
      if (lo[ci] < 0) {
        // No connector at all. It is held by nothing unless BOTH ends reach the
        // surface, in which case it is a strut spanning the part and is kept.
        if (!(cv.start_at_boundary && cv.end_at_boundary)) { drop[ci] = 1; changed = true; }
        continue;
      }
      const int keep_lo = cv.start_at_boundary ? 0 : lo[ci];
      const int keep_hi = cv.end_at_boundary ? last : hi[ci];
      if (keep_lo <= 0 && keep_hi >= last) continue;   // nothing to cut
      if (keep_hi - keep_lo < 1) { drop[ci] = 1; changed = true; continue; }
      double cut = 0.0;
      for (int t = 1; t <= keep_lo; ++t)
        cut += vlen(vsub(cv.points[t], cv.points[t - 1]));
      for (int t = keep_hi + 1; t <= last; ++t)
        cut += vlen(vsub(cv.points[t], cv.points[t - 1]));
      if (keep_lo > 0) ++rep.dangling_ends_trimmed;
      if (keep_hi < last) ++rep.dangling_ends_trimmed;
      rep.dangling_length_removed_mm += cut;
      cv.points.assign(cv.points.begin() + keep_lo, cv.points.begin() + keep_hi + 1);
      cv.length_mm -= cut;
      shift[ci] = keep_lo;
      changed = true;
    }
    if (!changed) break;
    // Compact: drop dead curves, remap the survivors, and drop connectors whose curve
    // went away or whose attachment fell outside what was kept.
    std::vector<int> remap(nc, -1);
    std::vector<OrganicCurve> keep;
    for (std::size_t ci = 0; ci < nc; ++ci) {
      if (drop[ci]) {
        rep.dangling_length_removed_mm += out.curves[ci].length_mm;
        ++rep.curves_dropped_dangling;
        continue;
      }
      remap[ci] = static_cast<int>(keep.size());
      keep.push_back(std::move(out.curves[ci]));
    }
    out.curves.swap(keep);
    std::vector<OrganicConnector> kc;
    for (OrganicConnector cn : out.connectors) {
      if (cn.curve_a < 0 || cn.curve_b < 0) continue;
      const int na = remap[cn.curve_a], nb = remap[cn.curve_b];
      if (na < 0 || nb < 0) continue;
      const int pa = cn.pt_a - shift[cn.curve_a], pb = cn.pt_b - shift[cn.curve_b];
      if (pa < 0 || pb < 0) continue;
      if (pa >= static_cast<int>(out.curves[na].points.size())) continue;
      if (pb >= static_cast<int>(out.curves[nb].points.size())) continue;
      cn.curve_a = na; cn.curve_b = nb; cn.pt_a = pa; cn.pt_b = pb;
      cn.a = out.curves[na].points[pa];
      cn.b = out.curves[nb].points[pb];
      cn.length_mm = vlen(vsub(cn.b, cn.a));
      if (!(cn.length_mm > 1e-9)) continue;
      kc.push_back(cn);
    }
    out.connectors.swap(kc);
  }
  // The connection counts are re-derived AFTER trimming, or R3 would report the
  // pre-trim graph.
  for (OrganicCurve& cv : out.curves) cv.connections = 0;
  for (const OrganicConnector& cn : out.connectors) {
    out.curves[cn.curve_a].connections += 1;
    out.curves[cn.curve_b].connections += 1;
  }
  rep.curves_kept = out.curves.size();
  rep.connectors = out.connectors.size();
  rep.total_curve_length_mm = 0.0;
  for (const OrganicCurve& cv : out.curves) rep.total_curve_length_mm += cv.length_mm;

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

  // ── ★★ CALIBRATE THE BEAD TO THE LENGTH ACTUALLY TRACED ────────────────────
  //
  // The mass coupling (organic_strut_diameter_for) assumes THREE PERFECTLY ORTHOGONAL
  // FAMILIES ON A BOX: one strut of each family through a d-cube, so
  // rho = 3 pi t^2 / (4 d^2). The traced lattice is not that. Curves bend, families
  // are not exactly orthogonal, thinning removes some and the connectors add length
  // the model never counted — so the REAL length per unit volume is higher than the
  // model's 3/d^2, and a bead sized from the model carries too much material.
  //
  // ★ MEASURED, ON A 40 mm CUBE AGAINST THE MAINTAINER'S OWN PRINTED COUPON: the
  // traced length came out 14,423 mm against the coupon's ~14,500 — the LAYOUT was
  // right — while the emitted solid was 16.0 % against the coupon's 6.05 %, because
  // the bead was ~0.8 mm where the coupon's is ~0.6 mm. Length right, thickness wrong.
  //
  // So the bead is re-derived from what was traced instead of from the model:
  //     rho = pi r^2 * L / V   =>   r = sqrt(rho * V / (pi * L))
  // with L the total emitted centreline length and V the candidate volume. One global
  // factor, applied to every radius, so the GRADE is untouched (all radii scale
  // together and their ratios are preserved) and only the mass moves. Reported, never
  // silent, and floored at the stated minimum extrudable width like everything else.
  {
    double traced_len = 0.0;
    for (const OrganicCurve& cv : out.curves) traced_len += cv.length_mm;
    for (const OrganicConnector& cn : out.connectors) traced_len += cn.length_mm;
    double target_vol = 0.0;   // the volume the grading law asked for
    double model_vol = 0.0;    // the volume the un-calibrated beads would emit
    const double vox = h * h * h;
    for (std::size_t e = 0; e < n; ++e)
      if (candidate[e]) target_vol += spacing_mm_target_rho(e) * vox;
    for (const OrganicCurve& cv : out.curves)
      model_vol += M_PI * cv.radius_mm * cv.radius_mm * cv.length_mm;
    for (const OrganicConnector& cn : out.connectors)
      model_vol += M_PI * cn.radius_mm * cn.radius_mm * cn.length_mm;
    // ★ THE NODE BALLS ARE A QUARTER OF THE EMITTED SOLID AND THE FIRST VERSION OF
    // THIS LEFT THEM OUT. One icosahedron per polyline vertex and two per connector,
    // measured at 1,816 mm^3 against 5,500 mm^3 of prism on the cube. They scale as
    // k^3 where the prisms scale as k^2, so the calibration is not a square root but
    // the root of k^2*P + k^3*N = target — solved by a few fixed-point steps, which
    // is deterministic and converges in three for any k near 1.
    double node_vol = 0.0;
    for (const OrganicCurve& cv : out.curves)
      node_vol += static_cast<double>(cv.points.size()) *
                  lattice_node_volume_mm3(cv.radius_mm);
    for (const OrganicConnector& cn : out.connectors)
      node_vol += 2.0 * lattice_node_volume_mm3(cn.radius_mm);
    rep.bead_calibration = 1.0;
    if (traced_len > 0.0 && model_vol > 0.0 && target_vol > 0.0) {
      double k = std::sqrt(target_vol / model_vol);
      for (int it = 0; it < 8; ++it) {
        const double f = k * k * model_vol + k * k * k * node_vol - target_vol;
        const double df = 2.0 * k * model_vol + 3.0 * k * k * node_vol;
        if (!(std::fabs(df) > 0.0)) break;
        const double kn = k - f / df;
        if (!(kn > 0.0) || !std::isfinite(kn)) break;
        k = kn;
      }
      // Never below the machine: the floor is user input and outranks the calibration.
      double kmin = 0.0;
      for (const OrganicCurve& cv : out.curves)
        kmin = std::max(kmin, params.min_extrudable_width_mm / (2.0 * cv.radius_mm));
      if (k < kmin) { k = kmin; rep.bead_calibration_floored = true; }
      rep.bead_calibration = k;
      for (OrganicCurve& cv : out.curves) cv.radius_mm *= k;
      for (OrganicConnector& cn : out.connectors) cn.radius_mm *= k;
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
    auto deposit = [&](const Vec3& a, const Vec3& b, double r) {
      const double area = M_PI * r * r;
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
        deposit(cv.points[t - 1], cv.points[t], cv.radius_mm);
    for (const OrganicConnector& cn : out.connectors)
      deposit(cn.a, cn.b, cn.radius_mm);

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
                                         int nseg,
                                         const LatticeGenObserver* obs,
                                         std::vector<OrganicSpan>* emitted_out) {
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
  auto same_point = [](const Vec3& a, const Vec3& b) {
    return a.x == b.x && a.y == b.y && a.z == b.z;
  };
  // Every span that reaches the sink, for the post-clip connectivity measurement.
  // ★ WHICH PASS EMITTED THIS SPAN. Attribution, not argument: when a defect shows up
  // in the file, the answer to "which pass made it" must be readable off the geometry
  // rather than reasoned about. This is the same discipline that found the clip-span
  // millimetre bug — the observer named the pass and one candidate was left.
  enum class Src { Curve, Connector, Tie, Net, Leg, Fill };
  struct EmittedSeg { Vec3 a, b; double r, len; bool anchor0 = false, anchor1 = false;
                      Src src = Src::Curve; };
  Src cur_src = Src::Curve;
  std::vector<EmittedSeg> emitted;
  auto emit_node_once = [&](const Vec3& p, double r) {
    // ★ THE SAME GUARD THE OCTET GENERATOR HOLDS, AND FOR THE SAME REASON
    // (lattice_gen.cpp, the interior-node loop): a node ball whose SOLID would breach
    // the eroded region is DROPPED. The clip certificate covers the strut — the swept
    // prism is inside by construction because the centreline was eroded by its own
    // radius — but a BALL at a clipped endpoint is a sphere of radius r about a point
    // the clip only guarantees is r from the surface along the segment, and near a
    // concave feature that is not the same thing.
    //
    // ★ THIS WAS A REAL DEFECT, CAUGHT BY THE CODEBASE'S OWN INVARIANT AND NOT BY ME.
    // Without it, `lattice-variant` refused the organic export outright: "190 of 34,776
    // lattice vertices lie OUTSIDE the solid shell written into the same file, the
    // worst by 0.1802 mm". That refusal is the no-protrusion bar (task
    // 2026-08-08-strut-clip-matches-shell) doing exactly what it exists for — the file
    // would have printed strut ends standing proud of the surface while the certificate
    // described the composite inside it.
    if (boundary && boundary->signed_distance(p) < r) {
      ++st.dropped_nodes;
      return;
    }
    lattice_emit_node(sink, p, r);
    if (obs && obs->on_element)
      obs->on_element(LatticeGenElement::Node, p, p, r);
    st.triangles += 20;  // an icosahedron is exactly 20 triangles
    ++st.nodes;
    st.volume_mm3 += lattice_node_volume_mm3(r);
  };
  // ★★ RECORD, DO NOT EMIT. Nothing reaches the sink until the span list is FINAL.
  // This is the change that made a zero-free-end bar reachable at all: the previous
  // shape of this function wrote each strut to the sink the moment it was clipped, so
  // every later pass could only APPEND (ties, ground legs) and never CUT. A whisker,
  // once written, was written. Emission now happens once, at the end, over the list
  // that survived the tie, the prune and the ground tie.
  auto record_span = [&](const Vec3& p0, const Vec3& p1, double r) -> EmittedSeg* {
    if (!(vlen(vsub(p1, p0)) > 0.0)) return nullptr;
    emitted.push_back({p0, p1, r, vlen(vsub(p1, p0)), false, false, cur_src});
    return &emitted.back();
  };
  auto span = [&](const Vec3& a, const Vec3& b, double r) {
    if (!boundary) { record_span(a, b, r); return; }
    // CLIPPED TO THE ALLOWED REGION ERODED BY THIS STRUT'S OWN RADIUS — the swept
    // SOLID stays inside the part, never just the centreline. Exactly the discipline
    // the octet generator holds, using the same predicate.
    long long uncertified = 0;
    const std::vector<LatticeClipSpan> keep =
        boundary->clip_segment(a, b, r, -1, -1, &uncertified);
    st.uncertified_spans_dropped += uncertified;
    if (keep.empty()) { ++st.dropped_segments; return; }
    // ★ `LatticeClipSpan::t0/t1` ARE ARC-LENGTH IN MILLIMETRES, not fractions — the
    // header says so ("0 at a, |b-a| at b"), and reading them as fractions is a real
    // bug I shipped and the codebase's own no-protrusion invariant caught: a whole
    // span comes back as t1 == |b-a|, so `a + (b-a)*t1` placed the far end |b-a| times
    // too far along and the strut ran straight out through the shell. It refused with
    // "70 of 32,916 lattice vertices lie OUTSIDE the solid shell ... emitted by the
    // interior strut pass". Scale by the UNIT direction, not by the segment vector.
    const double seg_len = vlen(vsub(b, a));
    if (!(seg_len > 0.0)) return;
    const Vec3 seg_dir = vmul(vsub(b, a), 1.0 / seg_len);
    const bool whole =
        keep.size() == 1 && keep[0].t0 <= 0.0 && keep[0].t1 >= seg_len;
    if (!whole) ++st.clipped_segments;
    for (const LatticeClipSpan& s : keep) {
      const Vec3 p0 = vadd(a, vmul(seg_dir, s.t0));
      const Vec3 p1 = vadd(a, vmul(seg_dir, s.t1));
      EmittedSeg* rec = record_span(p0, p1, r);
      // ★ ANCHOR BALLS AT THE CUT ENDS (bar B6's discipline, applied to organic).
      // A clipped end is where the strut meets the surface; the octet generator
      // dresses every one of them and organic dressed none. `emit_span` already
      // placed a node at p0/p1 unless the guard dropped it, so this counts the end as
      // a LANDING and as skin geometry — which is also what makes `outer_finish:
      // "skin"` legal for organic, since the M4 guard refuses a finish that emitted
      // nothing at all.
      if (rec) {
        rec->anchor0 = s.t0 > 0.0;
        rec->anchor1 = s.t1 < seg_len;
      }
    }
  };
  cur_src = Src::Curve;
  for (const OrganicCurve& cv : lat.curves) {
    for (std::size_t t = 1; t < cv.points.size(); ++t)
      span(cv.points[t - 1], cv.points[t], cv.radius_mm);
  }
  cur_src = Src::Connector;
  for (const OrganicConnector& cn : lat.connectors) {
    span(cn.a, cn.b, cn.radius_mm);
  }

  // ── ★★ NODE MERGE (kOrganicNodeMergeRatio states the citation) ──────────────
  // Endpoints within one bead of each other ARE one node. Snap them together before
  // anything else runs, so the tie pass, the prune and the net-skin all see joints
  // rather than near-misses. Spans the snap collapses to nothing are dropped.
  //
  // ★ THE GUARD: a snapped endpoint MOVES, and the clip certificate covered it where
  // it was. A cluster whose centroid is not at least its own radius inside the part is
  // left alone, because moving it there would push the swept solid through the surface
  // and the export's no-protrusion invariant would refuse the file — which is exactly
  // how the arc-length bug in this same function announced itself.
  if (!emitted.empty()) {
    struct Ep { std::size_t span; int end; };
    std::vector<Ep> eps;
    eps.reserve(emitted.size() * 2);
    double rmin_all = emitted.front().r;
    for (std::size_t i = 0; i < emitted.size(); ++i) {
      rmin_all = std::min(rmin_all, emitted[i].r);
      eps.push_back({i, 0});
      eps.push_back({i, 1});
    }
    auto ep_pos = [&](const Ep& e) { return e.end ? emitted[e.span].b : emitted[e.span].a; };
    const double mcell = std::max(kOrganicNodeMergeRatio * rmin_all, 1e-6);
    std::map<std::array<long long, 3>, std::vector<int>> mb;
    auto mkey = [mcell](const Vec3& p) {
      return std::array<long long, 3>{
          static_cast<long long>(std::floor(p.x / mcell)),
          static_cast<long long>(std::floor(p.y / mcell)),
          static_cast<long long>(std::floor(p.z / mcell))};
    };
    for (std::size_t i = 0; i < eps.size(); ++i) mb[mkey(ep_pos(eps[i]))].push_back(int(i));
    std::vector<int> mpar(eps.size());
    for (std::size_t i = 0; i < mpar.size(); ++i) mpar[i] = static_cast<int>(i);
    std::function<int(int)> mfind = [&mpar](int a) {
      while (mpar[a] != a) { mpar[a] = mpar[mpar[a]]; a = mpar[a]; }
      return a;
    };
    for (const auto& kv : mb)
      for (long long dz = -1; dz <= 1; ++dz)
        for (long long dy = -1; dy <= 1; ++dy)
          for (long long dx = -1; dx <= 1; ++dx) {
            auto it = mb.find({kv.first[0] + dx, kv.first[1] + dy, kv.first[2] + dz});
            if (it == mb.end()) continue;
            for (int i : kv.second)
              for (int j : it->second) {
                if (j <= i) continue;
                const Vec3 pi = ep_pos(eps[i]), pj = ep_pos(eps[j]);
                const double rr = kOrganicNodeMergeRatio *
                                  std::min(emitted[eps[i].span].r, emitted[eps[j].span].r);
                if (vlen(vsub(pi, pj)) > rr) continue;
                const int ra = mfind(i), rb = mfind(j);
                if (ra != rb) mpar[std::max(ra, rb)] = std::min(ra, rb);
              }
          }
    std::map<int, std::vector<int>> cluster;
    for (std::size_t i = 0; i < eps.size(); ++i) cluster[mfind(int(i))].push_back(int(i));
    for (const auto& kv : cluster) {
      if (kv.second.size() < 2) continue;
      Vec3 c{0, 0, 0};
      double rmin = emitted[eps[kv.second.front()].span].r;
      for (int i : kv.second) {
        const Vec3 p = ep_pos(eps[i]);
        c = vadd(c, p);
        rmin = std::min(rmin, emitted[eps[i].span].r);
      }
      c = vmul(c, 1.0 / static_cast<double>(kv.second.size()));
      if (boundary && boundary->signed_distance(c) < rmin) continue;   // would breach
      ++st.merge_clusters;
      for (int i : kv.second) {
        EmittedSeg& e = emitted[eps[i].span];
        (eps[i].end ? e.b : e.a) = c;
        ++st.nodes_merged;
      }
    }
    std::vector<EmittedSeg> mkeep;
    mkeep.reserve(emitted.size());
    for (EmittedSeg& e : emitted) {
      e.len = vlen(vsub(e.b, e.a));
      if (e.len <= 0.5 * e.r) { ++st.merge_degenerate_spans; continue; }
      mkeep.push_back(e);
    }
    emitted.swap(mkeep);
  }

  // ── ★★ CUT EVERYTHING BELOW THE BASE (kOrganicBaseDominanceFraction states why) ──
  // ★ IT RUNS FIRST, BEFORE EVERY REPAIR, AND THE ORDER IS THE WHOLE POINT.
  // Run last it was a disaster: the trim severs struts, so the part came apart into 13
  // pieces with nothing left to rejoin them, and the mid-air pass — which had already
  // finished — went on adding legs down to the ORIGINAL plate, rebuilding the very
  // scatter the trim had just removed. Cut the base first and every pass after it sees
  // one shape: the stranded-piece drop rejoins or discards what the cut separated, the
  // prune clears the ends it exposed, and the mid-air pass takes the CUT face as its
  // ground, so no leg reaches below it.
  if (!emitted.empty() && lat.trim_below_base && lat.layer_height_mm > 0.0) {
    double rmin = emitted.front().r;
    Vec3 lo = emitted.front().a, hi = emitted.front().a;
    for (const EmittedSeg& e : emitted) {
      rmin = std::min(rmin, e.r);
      for (const Vec3& p : {e.a, e.b}) {
        lo.x = std::min(lo.x, p.x - e.r); lo.y = std::min(lo.y, p.y - e.r);
        lo.z = std::min(lo.z, p.z - e.r);
        hi.x = std::max(hi.x, p.x + e.r); hi.y = std::max(hi.y, p.y + e.r);
        hi.z = std::max(hi.z, p.z + e.r);
      }
    }
    const double vxy = std::max(rmin, 1e-6), vz = lat.layer_height_mm;
    const int BX = static_cast<int>((hi.x - lo.x) / vxy) + 2;
    const int BY = static_cast<int>((hi.y - lo.y) / vxy) + 2;
    // Only the bottom of the part can hold the base, and searching the whole height
    // would let a narrow waist higher up masquerade as one.
    const int BZ = std::min(static_cast<int>((hi.z - lo.z) / vz) + 2,
                            static_cast<int>(0.25 * (hi.z - lo.z) / vz) + 2);
    if (static_cast<long long>(BX) * BY * BZ <= 120000000LL && BZ > 1) {
      auto bidx = [BX, BY](int i, int j, int k) {
        return (static_cast<std::size_t>(k) * BY + j) * BX + i;
      };
      std::vector<unsigned char> bo(static_cast<std::size_t>(BX) * BY * BZ, 0);
      for (const EmittedSeg& e : emitted) {
        const Vec3 ab = vsub(e.b, e.a);
        const double abab = vdot(ab, ab), r2 = e.r * e.r;
        const int i0 = std::max(0, int((std::min(e.a.x, e.b.x) - e.r - lo.x) / vxy));
        const int i1 = std::min(BX - 1, int((std::max(e.a.x, e.b.x) + e.r - lo.x) / vxy) + 1);
        const int j0 = std::max(0, int((std::min(e.a.y, e.b.y) - e.r - lo.y) / vxy));
        const int j1 = std::min(BY - 1, int((std::max(e.a.y, e.b.y) + e.r - lo.y) / vxy) + 1);
        const int k0 = std::max(0, int((std::min(e.a.z, e.b.z) - e.r - lo.z) / vz));
        const int k1 = std::min(BZ - 1, int((std::max(e.a.z, e.b.z) + e.r - lo.z) / vz) + 1);
        for (int k = k0; k <= k1; ++k)
          for (int j = j0; j <= j1; ++j)
            for (int i = i0; i <= i1; ++i) {
              const Vec3 c{lo.x + (i + 0.5) * vxy, lo.y + (j + 0.5) * vxy,
                           lo.z + (k + 0.5) * vz};
              const Vec3 ac = vsub(c, e.a);
              double t = abab > 0.0 ? vdot(ac, ab) / abab : 0.0;
              t = std::min(1.0, std::max(0.0, t));
              const Vec3 d = vsub(ac, vmul(ab, t));
              if (vdot(d, d) <= r2) bo[bidx(i, j, k)] = 1;
            }
      }
      // ★ THE AREA PROFILE FIRST. The base is where the cross-section becomes a real
      // slice of the body, and that is a question about AREA — stilts are a couple of
      // percent of the body's section however well connected they are among themselves.
      std::vector<long long> area(BZ, 0);
      long long area_max = 0;
      for (int k = 0; k < BZ; ++k) {
        for (int j = 0; j < BY; ++j)
          for (int i = 0; i < BX; ++i) area[k] += bo[bidx(i, j, k)];
        area_max = std::max(area_max, area[k]);
      }
      std::vector<int> lab(static_cast<std::size_t>(BX) * BY, 0);
      int base_k = -1;
      for (int k = 0; k < BZ && base_k < 0; ++k) {
        const long long cells = area[k];
        if (cells <= 0) continue;
        // Too thin to be the body's first layer: this is a stilt, cut it away.
        if (static_cast<double>(cells) <
            kOrganicBaseAreaFraction * static_cast<double>(area_max))
          continue;
        std::fill(lab.begin(), lab.end(), 0);
        int nl = 0; long long big = 0;
        for (int j = 0; j < BY; ++j)
          for (int i = 0; i < BX; ++i) {
            if (!bo[bidx(i, j, k)] || lab[static_cast<std::size_t>(j) * BX + i]) continue;
            ++nl;
            long long m = 0;
            std::vector<std::pair<int,int>> stk{{i, j}};
            lab[static_cast<std::size_t>(j) * BX + i] = nl;
            while (!stk.empty()) {
              const std::pair<int,int> c = stk.back(); stk.pop_back();
              ++m;
              for (int dj = -1; dj <= 1; ++dj)
                for (int di = -1; di <= 1; ++di) {
                  const int a2 = c.first + di, b2 = c.second + dj;
                  if (a2 < 0 || b2 < 0 || a2 >= BX || b2 >= BY) continue;
                  if (bo[bidx(a2, b2, k)] && !lab[static_cast<std::size_t>(b2) * BX + a2]) {
                    lab[static_cast<std::size_t>(b2) * BX + a2] = nl;
                    stk.push_back({a2, b2});
                  }
                }
            }
            big = std::max(big, m);
          }
        if (static_cast<double>(big) >=
            kOrganicBaseDominanceFraction * static_cast<double>(cells))
          base_k = k;
      }
      if (base_k > 0) {
        const double zbase = lo.z + base_k * vz;   // the base layer's FLOOR
        st.base_trim_found = true;
        st.base_trim_z_mm = zbase;
        std::vector<EmittedSeg> keep;
        keep.reserve(emitted.size());
        for (const EmittedSeg& e : emitted) {
          const double zlo = std::min(e.a.z, e.b.z), zhi = std::max(e.a.z, e.b.z);
          if (zhi <= zbase) {                       // wholly below: scrap
            ++st.base_trim_spans_cut;
            st.base_trim_length_mm += e.len;
            continue;
          }
          if (zlo >= zbase) { keep.push_back(e); continue; }
          // Straddles: keep the part at or above the base, drop the tail below it.
          EmittedSeg c = e;
          const double t = (zbase - e.a.z) / (e.b.z - e.a.z);
          const Vec3 cut = vadd(e.a, vmul(vsub(e.b, e.a), t));
          if (e.a.z < e.b.z) c.a = cut; else c.b = cut;
          c.len = vlen(vsub(c.b, c.a));
          if (c.len <= 0.5 * c.r) {                 // nothing meaningful survives
            ++st.base_trim_spans_cut;
            st.base_trim_length_mm += e.len;
            continue;
          }
          ++st.base_trim_spans_clipped;
          st.base_trim_length_mm += e.len - c.len;
          keep.push_back(c);
        }
        emitted.swap(keep);
        // ── ★★ AND NOW BUILD THE FOUNDATION (kOrganicBaseMatSpacingRatio) ───────
        // A crossed planar grid at the base plane, spanning whatever of the part's
        // cross-section is there. Emitted through `span` like everything else, so the
        // boundary clip decides its extent and it can never leave the part — the mat
        // takes the shape of the footprint without being told what that shape is.
        // ★ THE MAT CAN BE TURNED OFF, so the question "is the mat what holds this
        // together?" is answerable by running it both ways through the REAL weld
        // rather than by an endpoint-matching approximation, which is blind to two
        // struts that fuse in solid without sharing an endpoint — exactly how a mat
        // lying under a strut joins it.
        if (lat.base_mat && !std::getenv("TOPOPT_ORGANIC_NO_BASE_MAT")) {
          // The local separation at the base: use the median of what the tracer
          // achieved, which is the spacing this lattice is actually expressed in.
          double dsum = 0.0; std::size_t dn = 0; double rsum = 0.0;
          for (const EmittedSeg& e : emitted) {
            if (e.len > 0.0) { dsum += e.len; ++dn; rsum += e.r; }
          }
          double rmat = dn ? kOrganicBaseMatRadiusRatio * (rsum / dn) : 0.0;
          // ★ A MAT THINNER THAN THE RASTER THAT MESHES IT DOES NOT EXIST. Its height
          // is rmat (the weld takes the lower half), so below ~2 weld voxels it is
          // erased outright — measured, not feared: at 0.273 mm against a 0.28 mm
          // pitch the mat vanished from the slice completely. Raised rather than
          // silently dropped, and counted so the receipt says it happened.
          if (lat.weld_pitch_hint_mm > 0.0 && rmat > 0.0 &&
              rmat < 2.0 * lat.weld_pitch_hint_mm) {
            rmat = 2.0 * lat.weld_pitch_hint_mm;
            st.base_mat_radius_raised_for_raster = true;
          }
          // ★ THE PITCH IS THE MAT'S OWN BEAD, so neighbouring lines overlap and the
          // first layer is a continuous raft. Keyed to the lattice cell it was 4-6 mm
          // and the mat sliced as scattered fragments (18 struts over 40 mm).
          const double pitch = kOrganicBaseMatPitchPerDiameter * 2.0 * rmat;
          if (pitch > 0.0 && rmat > 0.0) {
            // ★★ THE MAT'S CENTRELINE SITS ON THE CUT PLANE, so the weld's planar cut
            // takes its lower half and the FIRST LAYER IS A FULL-WIDTH LINE.
            //
            // It used to sit one radius higher, to keep its solid off the plane rather
            // than hanging below — a fear that predates the planar cut in
            // `organic_weld`, which now removes anything under floor_z outright. With
            // the capsule raised, layer 1 sampled the very BOTTOM of the capsule, where
            // the half-width is zero: the first layer sliced as disconnected dots,
            // widening to crosses at layer 2. A first layer of dots is not a foundation.
            //
            // Centred on the plane, the cut face is the capsule's full diameter, and
            // the mat is only r tall instead of 2r — a thinner base as well as a
            // properly adhered one.
            const double zm = zbase;
            st.base_mat_z_mm = zm;
            cur_src = Src::Leg;          // structural: never pruned as a loose end
            const double x0 = lo.x, x1 = hi.x, y0 = lo.y, y1 = hi.y;

            // ★★ PADS UNDER THE TOUCHDOWNS, NOT A SLAB UNDER THE WHOLE PART. The mat
            // was laid across the entire footprint regardless of what stood on it —
            // seven layers of a full 40x40 square of which only part was ever built
            // upon, plastic and print time spent supporting nothing. Collect the points
            // where the lattice actually REACHES the base plane, and keep only mat
            // within reach of one.
            const double contact_z = zm + kOrganicBaseMatContactRadii * rmat;
            std::vector<std::array<double, 2>> touch;
            for (const EmittedSeg& e : emitted) {
              for (const Vec3& p : {e.a, e.b})
                if (p.z <= contact_z) touch.push_back({p.x, p.y});
            }
            st.base_mat_touchdowns = touch.size();
            std::fprintf(stderr,
                         "[base-mat] %zu touchdowns at z<=%.4f, pad %.3f mm, pitch "
                         "%.3f mm, footprint %.1fx%.1f mm\n",
                         touch.size(), contact_z, kOrganicBaseMatPadPitches * pitch,
                         pitch, hi.x - lo.x, hi.y - lo.y);
            const double pad = kOrganicBaseMatPadPitches * pitch;
            const double pad2 = pad * pad;
            // A point is padded if any touchdown is within `pad` of it. Bucketed by
            // `pad` so this is a neighbourhood test, not a scan of every touchdown.
            std::unordered_map<long long, std::vector<int>> tb;
            auto tkey = [&](double x, double y) {
              return (static_cast<long long>(std::floor(x / pad)) << 32) ^
                     static_cast<long long>(std::floor(y / pad)) ;
            };
            for (std::size_t i = 0; i < touch.size(); ++i)
              tb[tkey(touch[i][0], touch[i][1])].push_back(int(i));
            auto padded = [&](double x, double y) {
              const long long bx = static_cast<long long>(std::floor(x / pad));
              const long long by = static_cast<long long>(std::floor(y / pad));
              for (long long dx = -1; dx <= 1; ++dx)
                for (long long dy = -1; dy <= 1; ++dy) {
                  auto it = tb.find(((bx + dx) << 32) ^ (by + dy));
                  if (it == tb.end()) continue;
                  for (int i : it->second) {
                    const double ux = touch[i][0] - x, uy = touch[i][1] - y;
                    if (ux * ux + uy * uy <= pad2) return true;
                  }
                }
              return false;
            };
            // Walk each grid line and emit only the RUNS that are padded, so a line
            // crossing an empty stretch of footprint simply is not drawn there.
            const double step = std::max(rmat, 1e-3);
            auto emit_padded_line = [&](bool along_y, double fixed) {
              const double s0 = along_y ? y0 : x0, s1 = along_y ? y1 : x1;
              bool open = false;
              double run0 = s0;
              for (double t = s0; t <= s1 + step; t += step) {
                const double tc = std::min(t, s1);
                const bool in = (t <= s1) && (along_y ? padded(fixed, tc)
                                                      : padded(tc, fixed));
                if (in && !open) { open = true; run0 = tc; }
                else if (!in && open) {
                  open = false;
                  if (tc - run0 > step) {
                    const std::size_t before = emitted.size();
                    if (along_y) span({fixed, run0, zm}, {fixed, tc, zm}, rmat);
                    else         span({run0, fixed, zm}, {tc, fixed, zm}, rmat);
                    for (std::size_t q = before; q < emitted.size(); ++q) {
                      ++st.base_mat_struts;
                      st.base_mat_length_mm += emitted[q].len;
                    }
                  }
                }
              }
            };
            for (double x = x0; x <= x1; x += pitch) emit_padded_line(true, x);
            for (double y = y0; y <= y1; y += pitch) emit_padded_line(false, y);
          }
        }
      }
    }
  }

  // ══════════════════════════════════════════════════════════════════════════════
  // ★★★ THE REPAIRS ARE CYCLIC, SO THEY RUN TO A JOINT FIXED POINT ★★★
  //
  // Each repair below fixes one defect and CREATES another for a repair that has
  // already finished. Run once, in sequence, they chase each other forever:
  //
  //     tie          -> exposes free ends       -> prune
  //     prune        -> exposes mid-air starts  -> branch support
  //     support cut  -> exposes free ends       -> cleanup prune
  //     cut          -> shatters into fragments -> stranded drop
  //     stranded drop-> exposes mid-air starts  -> (back to the top)
  //
  // Every arrow was found the same way: a bar went green, the next one went red, and
  // I appended another terminal pass. That was FIVE fixes, each of which created the
  // next, and appending a sixth would have produced a sixth cascade. Measured on the
  // maintainer's cube, three bars could be made green at once but never four: mid-air
  // 0 / free ends 0 / converged came with 27 components; fixing components put
  // mid-air back to 344.
  //
  // The dependency is a CYCLE, so no ordering of a linear sequence terminates it. The
  // whole set iterates instead, and the numbers are only read at the fixed point —
  // the one state where every repair agrees there is nothing left to do.
  //
  // ★ IT TERMINATES because every repair is monotone in the thing it removes and the
  // budget bounds the rest: prune, cut and the stranded drop only ever DELETE, and the
  // three that add (tie, leg, branch) are each gated on a defect that its own addition
  // resolves. `fixed_point_converged` says whether the loop reached quiescence or ran
  // out of rounds — a spent budget is NOT convergence, which this file has already
  // mistaken once.
  bool fill_mat_done = false;
  bool slenderness_done = false;
  for (st.fixed_point_rounds = 0;
       st.fixed_point_rounds < kOrganicFixedPointRounds; ++st.fixed_point_rounds) {
    const std::size_t mutations_at_round_start = st.mutations;

    // ── ★★ §1(e3)+(e4) TIE, THEN CUT ────────────────────────────────────────────
    // Both passes run on the FINAL post-clip span list and BEFORE the ground tie, so
    // the legs the ground tie adds are never themselves pruned and never land on a
    // whisker that a later pass removes.
    //
    // ★ WHY BOTH. Tying GROWS: a tip with material in reach becomes a real joint, which
    // keeps the member and its stiffness. Pruning CUTS: a tip with nothing in reach, or
    // whose tie was clipped away by the boundary, is deleted. Tying alone cannot reach
    // zero — a tie is clipped like any other span, so it can be trimmed back to a stub
    // that is itself a free end. Pruning alone would throw away members that only needed
    // a joint. Tie first, cut what is left.
    //
    // ★ PRUNING CANNOT DISCONNECT THE LATTICE. A span that BRIDGES two parts of the
    // network has material at both tips by definition, so it is never a candidate. Only
    // tips are eroded, and eroding a tip cannot separate what remains.
    if (!emitted.empty()) {
      double longest = 0.0;
      for (const EmittedSeg& e : emitted) longest = std::max(longest, e.len + 2.0 * e.r);
      const double cell = std::max(longest, 1e-6);   // bucket edge only
      auto key = [cell](const Vec3& p) {
        return std::array<long long, 3>{
            static_cast<long long>(std::floor(p.x / cell)),
            static_cast<long long>(std::floor(p.y / cell)),
            static_cast<long long>(std::floor(p.z / cell))};
      };
      std::vector<unsigned char> alive(emitted.size(), 1);
      std::map<std::array<long long, 3>, std::vector<int>> bucket;
      auto rebuild = [&]() {
        bucket.clear();
        for (std::size_t i = 0; i < emitted.size(); ++i)
          if (alive[i])
            bucket[key(vmul(vadd(emitted[i].a, emitted[i].b), 0.5))].push_back(int(i));
      };
      rebuild();
      // ── ★★ IS THIS TIP SUPPORTED? ─────────────────────────────────────────────
      // ★ THE FIRST VERSION OF THIS TEST WAS "does any other span's solid contain the
      // tip", AND IT HAD A LOOPHOLE THAT SWALLOWED THE WHOLE BAR. Attribution found it:
      // dumping the final span list and correlating it with the dead ends the shipped
      // mesh actually shows, every one of the 19 survivors had SIX SPAN TIPS converging
      // on it. A bundle of near-parallel struts that all END at the same point supports
      // nothing whatsoever — but each tip sits inside its siblings' capsules, so the
      // containment test passed on all of them and the prune had nothing to cut.
      //
      // So support is about what the neighbouring span DOES at the contact, not merely
      // that it is there:
      //   INTERIOR contact — the tip lands on the BODY of another span (a T on a beam).
      //                      That span carries the load past the joint. Supported.
      //   TIP contact      — the other span ends here too. Supported only if it leads
      //                      AWAY (a polyline continuing along its curve, or a tie
      //                      heading off sideways), never if it folds back along the
      //                      same line, which is the bundle case above.
      auto tip_supported = [&](std::size_t i, const Vec3& tip, const Vec3& out) {
        const auto k0 = key(tip);
        for (long long dz = -1; dz <= 1; ++dz)
          for (long long dy = -1; dy <= 1; ++dy)
            for (long long dx = -1; dx <= 1; ++dx) {
              auto it = bucket.find({k0[0] + dx, k0[1] + dy, k0[2] + dz});
              if (it == bucket.end()) continue;
              for (int j : it->second) {
                if (static_cast<std::size_t>(j) == i || !alive[j]) continue;
                const EmittedSeg& e = emitted[j];
                const Vec3 ab = vsub(e.b, e.a);
                const double abab = vdot(ab, ab);
                double t = abab > 0.0 ? vdot(vsub(tip, e.a), ab) / abab : 0.0;
                t = std::min(1.0, std::max(0.0, t));
                const Vec3 q = vadd(e.a, vmul(ab, t));
                if (vdot(vsub(q, tip), vsub(q, tip)) > e.r * e.r) continue;
                const double da = vlen(vsub(q, e.a)), db = vlen(vsub(q, e.b));
                const double edge = 0.5 * e.r;
                if (da > edge && db > edge) return true;      // lands on the BODY
                const Vec3 far = (da <= db) ? e.b : e.a;      // this span's other end
                const Vec3 away = vsub(far, tip);
                const double an = vlen(away);
                if (!(an > 1e-9)) continue;
                if (vdot(vmul(away, 1.0 / an), out) > kOrganicFoldBackCos) return true;
              }
            }
        return false;
      };
      // The outward unit direction at a tip: from the span's other end towards it.
      auto tip_dir = [&](std::size_t i, int e) {
        const EmittedSeg& s2 = emitted[i];
        const Vec3 d = e ? vsub(s2.b, s2.a) : vsub(s2.a, s2.b);
        const double n = vlen(d);
        return n > 1e-9 ? vmul(d, 1.0 / n) : Vec3{0.0, 0.0, 1.0};
      };
      auto tip_covered = [&](std::size_t i, const Vec3& tip) {
        // kept for the callers that ask "is there anything here at all"
        const auto k0 = key(tip);
        for (long long dz = -1; dz <= 1; ++dz)
          for (long long dy = -1; dy <= 1; ++dy)
            for (long long dx = -1; dx <= 1; ++dx) {
              auto it = bucket.find({k0[0] + dx, k0[1] + dy, k0[2] + dz});
              if (it == bucket.end()) continue;
              for (int j : it->second) {
                if (static_cast<std::size_t>(j) == i || !alive[j]) continue;
                if (organic_segment_distance2(tip, tip, emitted[j].a, emitted[j].b) <=
                    emitted[j].r * emitted[j].r)
                  return true;
              }
            }
        return false;
      };
      (void)tip_covered;
      auto nearest_material = [&](std::size_t i, const Vec3& tip, double reach, Vec3& hit) {
        double best = reach * reach;
        bool found = false;
        const auto k0 = key(tip);
        const long long rings =
            static_cast<long long>(std::ceil(reach / std::max(cell, 1e-9))) + 1;
        for (long long dz = -rings; dz <= rings; ++dz)
          for (long long dy = -rings; dy <= rings; ++dy)
            for (long long dx = -rings; dx <= rings; ++dx) {
              auto it = bucket.find({k0[0] + dx, k0[1] + dy, k0[2] + dz});
              if (it == bucket.end()) continue;
              for (int j : it->second) {
                if (static_cast<std::size_t>(j) == i || !alive[j]) continue;
                const Vec3 ab = vsub(emitted[j].b, emitted[j].a);
                const double abab = vdot(ab, ab);
                double t = abab > 0.0 ? vdot(vsub(tip, emitted[j].a), ab) / abab : 0.0;
                t = std::min(1.0, std::max(0.0, t));
                const Vec3 q = vadd(emitted[j].a, vmul(ab, t));
                const double d2 = vdot(vsub(q, tip), vsub(q, tip));
                if (d2 < best) { best = d2; hit = q; found = true; }
              }
            }
        return found;
      };
      // The build plate supports a tip resting on it, so the lowest layer of the part is
      // exempt from BOTH passes below. The tolerance is one radius: a tip within its own
      // radius of the lowest material is touching the plate, not hanging over it.
      //
      // ★ THE TIE PASS NEEDS THIS TOO, and not having it was visible in a unit fixture:
      // six struts fanning up to a common apex were correctly cut, and then the tie pass
      // joined their six BASE points — every one of them already sitting on the plate —
      // to each other, leaving four struts of pure decoration behind. A tip the plate
      // holds up does not need tying to anything.
      double zmin = emitted.front().a.z;
      for (const EmittedSeg& e : emitted) zmin = std::min(zmin, std::min(e.a.z, e.b.z));
      auto on_plate = [&](const Vec3& p, double r) { return p.z - zmin <= r; };
      // ── the tie pass
      {
        struct Tie { Vec3 a, b; double r; };
        std::vector<Tie> ties;
        const std::size_t n_before = emitted.size();
        for (std::size_t i = 0; i < n_before; ++i)
          for (int e = 0; e < 2; ++e) {
            const Vec3 tip = e ? emitted[i].b : emitted[i].a;
            if (on_plate(tip, emitted[i].r) ||
                tip_supported(i, tip, tip_dir(i, e)))
              continue;
            ++st.free_ends_before_tie;
            // ★ THE REACH IS LOCAL, AND THAT IS THE WHOLE POINT. It was
            // `reach_hint` — the LONGEST span anywhere in the model — which let a tip
            // reach right across the lattice for something to hold on to. Every
            // whisker then found a partner, every whisker counted as "covered", and
            // the prune below had nothing to cut: 4 spans out of 14,601. Measured on
            // the shipped mesh the picture did not move at all (629 detected ends
            // before and after). A tie must never be longer than the member it
            // rescues, so the scale is that member: its own length plus its two ends.
            const double reach =
                kOrganicTieReachRatio * std::max(emitted[i].len + 2.0 * emitted[i].r,
                                                 4.0 * emitted[i].r);
            Vec3 hit{0, 0, 0};
            if (!nearest_material(i, tip, reach, hit)) { ++st.free_ends_unresolved; continue; }
            if (vlen(vsub(hit, tip)) <= 1e-9) continue;   // already touching
            ties.push_back({tip, hit, emitted[i].r});
          }
        cur_src = Src::Tie;
        for (const Tie& t : ties) {
          const std::size_t before = emitted.size();
          span(t.a, t.b, t.r);              // clipped exactly like everything else
          if (emitted.size() > before) {
            ++st.ties_added; ++st.mutations;
            st.tie_length_mm += vlen(vsub(t.b, t.a));
          }
        }
        alive.resize(emitted.size(), 1);
        rebuild();
      }
        // ── the prune, to a fixed point
      for (; st.prune_rounds < kOrganicPruneRounds; ++st.prune_rounds) {
        std::vector<std::size_t> doomed;
        for (std::size_t i = 0; i < emitted.size(); ++i) {
          if (!alive[i]) continue;
          for (int e = 0; e < 2; ++e) {
            const Vec3 tip = e ? emitted[i].b : emitted[i].a;
            if (on_plate(tip, emitted[i].r) ||
                tip_supported(i, tip, tip_dir(i, e)))
              continue;
            doomed.push_back(i);
            break;
          }
        }
        if (doomed.empty()) break;
        for (std::size_t i : doomed) {
          alive[i] = 0;
          ++st.pruned_spans; ++st.mutations;
          st.pruned_length_mm += emitted[i].len;
        }
        rebuild();
      }
      // Compact, so every pass below this point sees only what will be written.
      {
        std::vector<EmittedSeg> kept;
        kept.reserve(emitted.size());
        for (std::size_t i = 0; i < emitted.size(); ++i)
          if (alive[i]) kept.push_back(emitted[i]);
        emitted.swap(kept);
        alive.assign(emitted.size(), 1);
        rebuild();
      }
      // ── ★★ DROP WHAT IS NOT PART OF THE BODY ────────────────────────────────
      // The ground-tie repair below props a stranded piece up with a vertical leg down
      // to the plate. On a lattice that is the wrong answer and it LOOKS wrong: the
      // maintainer photographed the result — a single 0.42 mm pole standing ~30 mm tall
      // at a corner with a crumb on top, tied to nothing else. A 0.42 mm pole that tall
      // is not printable and the crumb it carries is worth nothing, so the piece is
      // DELETED instead. The leg survives only for a piece big enough to be worth
      // keeping (kOrganicStrandedKeepFraction of total length).
      if (!emitted.empty()) {
        std::vector<int> cp(emitted.size());
        for (std::size_t i = 0; i < cp.size(); ++i) cp[i] = static_cast<int>(i);
        std::function<int(int)> cf = [&cp](int a) {
          while (cp[a] != a) { cp[a] = cp[cp[a]]; a = cp[a]; }
          return a;
        };
        for (const auto& kv : bucket)
          for (long long dz = -1; dz <= 1; ++dz)
            for (long long dy = -1; dy <= 1; ++dy)
              for (long long dx = -1; dx <= 1; ++dx) {
                auto it = bucket.find({kv.first[0] + dx, kv.first[1] + dy,
                                       kv.first[2] + dz});
                if (it == bucket.end()) continue;
                for (int i : kv.second)
                  for (int j : it->second) {
                    if (j <= i) continue;
                    const double touch = emitted[i].r + emitted[j].r;
                    if (organic_segment_distance2(emitted[i].a, emitted[i].b,
                                                  emitted[j].a, emitted[j].b) >
                        touch * touch)
                      continue;
                    const int ra = cf(i), rb = cf(j);
                    if (ra != rb) cp[std::max(ra, rb)] = std::min(ra, rb);
                  }
              }
        std::map<int, double> len;
        double total = 0.0;
        for (std::size_t i = 0; i < emitted.size(); ++i) {
          len[cf(static_cast<int>(i))] += emitted[i].len;
          total += emitted[i].len;
        }
        int biggest = -1;
        double biggest_len = -1.0;
        for (const auto& kv : len)
          if (kv.second > biggest_len) { biggest_len = kv.second; biggest = kv.first; }
        std::vector<EmittedSeg> body;
        body.reserve(emitted.size());
        for (std::size_t i = 0; i < emitted.size(); ++i) {
          const int root = cf(static_cast<int>(i));
          if (root == biggest ||
              len[root] >= kOrganicStrandedKeepFraction * total) {
            body.push_back(emitted[i]);
          } else {
            ++st.stranded_spans_dropped; ++st.mutations;
            st.stranded_length_dropped_mm += emitted[i].len;
          }
        }
        for (const auto& kv : len)
          if (kv.first != biggest && kv.second < kOrganicStrandedKeepFraction * total)
            ++st.stranded_components_dropped;
        emitted.swap(body);
      }

      // The census is NOT taken here. The ground tie below still APPENDS legs, and a
      // number taken before the last pass that changes the list is a number about an
      // intermediate representation — exactly the mistake this file has made before. It
      // is taken at the very end, over the list that reaches the sink.
    }

    // ── ★★ THE GROUND-TIE REPAIR (OrganicGenStats states why) ──────────────────
    // Rasterise the emitted solids, flood from the lowest occupied layer, and tie every
    // unreached component down with a vertical leg from its own lowest voxel. Repeat.
    // This is graded_coupon.cpp's repair, on the POST-CLIP spans.
    if (!emitted.empty()) {
      double rmin = emitted.front().r;
      Vec3 lo = emitted.front().a, hi = emitted.front().a;
      for (const EmittedSeg& e : emitted) {
        rmin = std::min(rmin, e.r);
        for (const Vec3& p : {e.a, e.b}) {
          lo.x = std::min(lo.x, p.x - e.r); lo.y = std::min(lo.y, p.y - e.r);
          lo.z = std::min(lo.z, p.z - e.r);
          hi.x = std::max(hi.x, p.x + e.r); hi.y = std::max(hi.y, p.y + e.r);
          hi.z = std::max(hi.z, p.z + e.r);
        }
      }
      // One voxel per strut RADIUS: fine enough that a strut is never severed by the
      // raster (which would invent a floating piece), coarse enough to stay affordable.
      const double vx = std::max(rmin, 1e-6);
      const int RX = static_cast<int>(std::ceil((hi.x - lo.x) / vx)) + 2;
      const int RY = static_cast<int>(std::ceil((hi.y - lo.y) / vx)) + 2;
      const int RZ = static_cast<int>(std::ceil((hi.z - lo.z) / vx)) + 2;
      if (static_cast<long long>(RX) * RY * RZ <= 60000000LL) {
        std::vector<unsigned char> occ(static_cast<std::size_t>(RX) * RY * RZ, 0);
        auto ridx = [RX, RY](int i, int j, int k) {
          return (static_cast<std::size_t>(k) * RY + j) * RX + i;
        };
        auto stamp = [&](const EmittedSeg& e) {
          const Vec3 ab = vsub(e.b, e.a);
          const double abab = vdot(ab, ab);
          const double r2 = e.r * e.r;
          const int i0 = std::max(0, int((std::min(e.a.x, e.b.x) - e.r - lo.x) / vx));
          const int i1 = std::min(RX - 1, int((std::max(e.a.x, e.b.x) + e.r - lo.x) / vx) + 1);
          const int j0 = std::max(0, int((std::min(e.a.y, e.b.y) - e.r - lo.y) / vx));
          const int j1 = std::min(RY - 1, int((std::max(e.a.y, e.b.y) + e.r - lo.y) / vx) + 1);
          const int k0 = std::max(0, int((std::min(e.a.z, e.b.z) - e.r - lo.z) / vx));
          const int k1 = std::min(RZ - 1, int((std::max(e.a.z, e.b.z) + e.r - lo.z) / vx) + 1);
          for (int k = k0; k <= k1; ++k)
            for (int j = j0; j <= j1; ++j)
              for (int i = i0; i <= i1; ++i) {
                const Vec3 c{lo.x + (i + 0.5) * vx, lo.y + (j + 0.5) * vx,
                             lo.z + (k + 0.5) * vx};
                const Vec3 ac = vsub(c, e.a);
                double t = abab > 0.0 ? vdot(ac, ab) / abab : 0.0;
                t = std::min(1.0, std::max(0.0, t));
                const Vec3 d = vsub(ac, vmul(ab, t));
                if (vdot(d, d) <= r2) occ[ridx(i, j, k)] = 1;
              }
        };
        for (const EmittedSeg& e : emitted) stamp(e);
        // The GROUND: the lowest layer that holds any material.
        int ground = -1;
        for (int k = 0; k < RZ && ground < 0; ++k)
          for (int j = 0; j < RY && ground < 0; ++j)
            for (int i = 0; i < RX; ++i)
              if (occ[ridx(i, j, k)]) { ground = k; break; }
        std::vector<unsigned char> seen;
        auto flood = [&]() {
          seen.assign(occ.size(), 0);
          std::vector<int> st;
          if (ground < 0) return;
          for (int j = 0; j < RY; ++j)
            for (int i = 0; i < RX; ++i) {
              const std::size_t s0 = ridx(i, j, ground);
              if (occ[s0] && !seen[s0]) { seen[s0] = 1; st.push_back(int(s0)); }
            }
          const int di[6] = {1, -1, 0, 0, 0, 0}, dj[6] = {0, 0, 1, -1, 0, 0},
                    dk[6] = {0, 0, 0, 0, 1, -1};
          while (!st.empty()) {
            const int nn = st.back(); st.pop_back();
            const int i0 = nn % RX, j0 = (nn / RX) % RY, k0 = nn / (RX * RY);
            for (int d = 0; d < 6; ++d) {
              const int i = i0 + di[d], j = j0 + dj[d], k = k0 + dk[d];
              if (i < 0 || j < 0 || k < 0 || i >= RX || j >= RY || k >= RZ) continue;
              const std::size_t m = ridx(i, j, k);
              if (occ[m] && !seen[m]) { seen[m] = 1; st.push_back(int(m)); }
            }
          }
        };
        flood();
        for (std::size_t m = 0; m < occ.size(); ++m)
          if (occ[m] && !seen[m]) ++st.floating_voxels_before;

        for (; st.repair_rounds < kOrganicRepairRounds; ++st.repair_rounds) {
          long long fl = 0;
          for (std::size_t m = 0; m < occ.size(); ++m) if (occ[m] && !seen[m]) ++fl;
          if (fl == 0) break;
          std::vector<unsigned char> lab(occ.size(), 0);
          std::vector<EmittedSeg> legs;
          for (int k = 0; k < RZ; ++k)
            for (int j = 0; j < RY; ++j)
              for (int i = 0; i < RX; ++i) {
                const std::size_t s0 = ridx(i, j, k);
                if (!occ[s0] || seen[s0] || lab[s0]) continue;
                std::vector<int> stk{int(s0)}; lab[s0] = 1;
                int lk = k, li = i, lj = j;
                while (!stk.empty()) {
                  const int nn = stk.back(); stk.pop_back();
                  const int i0 = nn % RX, j0 = (nn / RX) % RY, k0 = nn / (RX * RY);
                  if (k0 < lk) { lk = k0; li = i0; lj = j0; }
                  const int di[6] = {1, -1, 0, 0, 0, 0}, dj[6] = {0, 0, 1, -1, 0, 0},
                            dk[6] = {0, 0, 0, 0, 1, -1};
                  for (int d = 0; d < 6; ++d) {
                    const int a = i0 + di[d], b = j0 + dj[d], c = k0 + dk[d];
                    if (a < 0 || b < 0 || c < 0 || a >= RX || b >= RY || c >= RZ) continue;
                    const std::size_t m = ridx(a, b, c);
                    if (occ[m] && !seen[m] && !lab[m]) { lab[m] = 1; stk.push_back(int(m)); }
                  }
                }
                // The leg: straight down from this component's lowest voxel to the
                // ground layer. Radius is the component's own strut radius (rmin is the
                // conservative choice — a leg is never fatter than the lattice it ties).
                const Vec3 top{lo.x + (li + 0.5) * vx, lo.y + (lj + 0.5) * vx,
                               lo.z + (lk + 0.5) * vx};
                const Vec3 bot{top.x, top.y, lo.z + (ground + 0.5) * vx};
                if (vlen(vsub(top, bot)) > 1e-9)
                  legs.push_back({top, bot, rmin, vlen(vsub(top, bot))});
              }
          if (legs.empty()) break;
          for (const EmittedSeg& L : legs) { stamp(L); ++st.repair_legs_added; ++st.mutations; }
          // The legs are GEOMETRY and must reach the file, not just the raster.
          cur_src = Src::Leg;
          for (const EmittedSeg& L : legs) span(L.a, L.b, L.r);
          flood();
        }
        for (std::size_t m = 0; m < occ.size(); ++m)
          if (occ[m] && !seen[m]) ++st.floating_voxels_after;
      }
    }


    // ── ★★ NOTHING MAY START IN MID-AIR ──────────────────────────────────────────
    // ★ CONNECTED IS NOT BUILDABLE. The ground tie asks "is every PIECE reachable from
    // the plate" — a question about the FINISHED solid. A printer never has the finished
    // solid: it lays layer k on layer k-1, so every island of material in a layer must
    // land on material already there. A strut can be rigidly connected and still have its
    // lowest point hanging in air, held only by struts printed LATER. The maintainer
    // WATCHED his printer extrude one into open space.
    //
    // ★ THE ORDER IS SUPPORT, THEN CUT, AND THE CALLER REFUSES ON ANY REMAINDER.
    //   1. a VERTICAL leg to the material below, or to the lowest legal centreline
    //   2. failing that, a DIAGONAL leg to the nearest supported material — at the
    //      part's bottom edge a vertical leg would have to breach the surface, and the
    //      clip deletes it, which is the `support_legs_impossible` case
    //   3. failing that, DELETE the spans that own the island. Material that cannot be
    //      supported must not be printed.
    // That set is closed, so `unsupported_cells_remaining` is 0 unless the geometry is
    // pathological — and run_job refuses to export when it is not.
    //
    // ★ TWO THINGS THE FIRST VERSION OF THIS GOT WRONG, BOTH IN THE MEASUREMENT:
    // (a) IT RASTERED AT THE STRUT RADIUS. The machine lays ~0.1 mm layers; a lowest
    //     point can clear a 0.26 mm layer test and still float for two real layers. The
    //     raster is now ANISOTROPIC — the layer height in Z, the strut radius in XY.
    // (b) IT SAMPLED CELL CENTRES. A thin diagonal strut can cross a cell without
    //     covering its centre, so the raster invented gaps between layers that do not
    //     exist. That is why the island count swung between 21 and 134 across cell
    //     sizes. Occupancy is now tested at the centre AND the eight corners.
    if (!emitted.empty()) {
      double rmin = emitted.front().r;
      Vec3 lo = emitted.front().a, hi = emitted.front().a;
      for (const EmittedSeg& e : emitted) {
        rmin = std::min(rmin, e.r);
        for (const Vec3& p : {e.a, e.b}) {
          lo.x = std::min(lo.x, p.x - e.r); lo.y = std::min(lo.y, p.y - e.r);
          lo.z = std::min(lo.z, p.z - e.r);
          hi.x = std::max(hi.x, p.x + e.r); hi.y = std::max(hi.y, p.y + e.r);
          hi.z = std::max(hi.z, p.z + e.r);
        }
      }
      const double vxy = std::max(rmin, 1e-6);
      const double vz = lat.layer_height_mm > 0.0 ? lat.layer_height_mm : vxy;
      st.support_layer_height_mm = vz;
      const int RX = static_cast<int>((hi.x - lo.x) / vxy) + 2;
      const int RY = static_cast<int>((hi.y - lo.y) / vxy) + 2;
      const int RZ = static_cast<int>((hi.z - lo.z) / vz) + 2;
      if (static_cast<long long>(RX) * RY * RZ <= 120000000LL) {
        auto ridx = [RX, RY](int i, int j, int k) {
          return (static_cast<std::size_t>(k) * RY + j) * RX + i;
        };
        std::vector<unsigned char> occ(static_cast<std::size_t>(RX) * RY * RZ, 0);
        std::vector<int> own(static_cast<std::size_t>(RX) * RY * RZ, -1);
        std::vector<unsigned char> live(emitted.size(), 1);
        auto seg_d2 = [](const Vec3& p, const EmittedSeg& e) {
          const Vec3 ab = vsub(e.b, e.a);
          const double abab = vdot(ab, ab);
          double t = abab > 0.0 ? vdot(vsub(p, e.a), ab) / abab : 0.0;
          t = std::min(1.0, std::max(0.0, t));
          const Vec3 d = vsub(vsub(p, e.a), vmul(ab, t));
          return vdot(d, d);
        };
        // ★ CONSERVATIVE OCCUPANCY: the cell is solid when the capsule reaches its centre
        // OR any of its eight corners. Centre-only under-marks a thin diagonal strut and
        // manufactures gaps the printer never sees.
        auto covers = [&](const EmittedSeg& e, int i, int j, int k) {
          const double r2 = e.r * e.r;
          const double cx = lo.x + (i + 0.5) * vxy, cy = lo.y + (j + 0.5) * vxy,
                       cz = lo.z + (k + 0.5) * vz;
          if (seg_d2({cx, cy, cz}, e) <= r2) return true;
          for (int sz = -1; sz <= 1; sz += 2)
            for (int sy = -1; sy <= 1; sy += 2)
              for (int sx = -1; sx <= 1; sx += 2)
                if (seg_d2({cx + sx * 0.5 * vxy, cy + sy * 0.5 * vxy, cz + sz * 0.5 * vz},
                           e) <= r2)
                  return true;
          return false;
        };
        auto stamp_all = [&]() {
          std::fill(occ.begin(), occ.end(), 0);
          std::fill(own.begin(), own.end(), -1);
          for (std::size_t si = 0; si < emitted.size(); ++si) {
            if (!live[si]) continue;
            const EmittedSeg& e = emitted[si];
            const int i0 = std::max(0, int((std::min(e.a.x, e.b.x) - e.r - lo.x) / vxy) - 1);
            const int i1 = std::min(RX - 1, int((std::max(e.a.x, e.b.x) + e.r - lo.x) / vxy) + 1);
            const int j0 = std::max(0, int((std::min(e.a.y, e.b.y) - e.r - lo.y) / vxy) - 1);
            const int j1 = std::min(RY - 1, int((std::max(e.a.y, e.b.y) + e.r - lo.y) / vxy) + 1);
            const int k0 = std::max(0, int((std::min(e.a.z, e.b.z) - e.r - lo.z) / vz) - 1);
            const int k1 = std::min(RZ - 1, int((std::max(e.a.z, e.b.z) + e.r - lo.z) / vz) + 1);
            for (int k = k0; k <= k1; ++k)
              for (int j = j0; j <= j1; ++j)
                for (int i = i0; i <= i1; ++i)
                  if (covers(e, i, j, k)) {
                    const std::size_t m = ridx(i, j, k);
                    occ[m] = 1;
                    if (own[m] < 0) own[m] = static_cast<int>(si);
                  }
          }
        };
        std::vector<int> lab(static_cast<std::size_t>(RX) * RY, 0);
        // One sweep: find every unsupported island, and hand back its cells.
        struct Island { int k; std::vector<std::pair<int,int>> cells; };
        auto find_islands = [&](std::vector<Island>& out, int& ground) {
          out.clear();
          ground = -1;
          for (int k = 0; k < RZ && ground < 0; ++k)
            for (int j = 0; j < RY && ground < 0; ++j)
              for (int i = 0; i < RX; ++i)
                if (occ[ridx(i, j, k)]) { ground = k; break; }
          if (ground < 0) return;
          for (int k = ground + 1; k < RZ; ++k) {
            std::fill(lab.begin(), lab.end(), 0);
            int nl = 0;
            for (int j = 0; j < RY; ++j)
              for (int i = 0; i < RX; ++i) {
                if (!occ[ridx(i, j, k)] || lab[static_cast<std::size_t>(j) * RX + i]) continue;
                ++nl;
                std::vector<std::pair<int,int>> stk{{i, j}}, cells;
                lab[static_cast<std::size_t>(j) * RX + i] = nl;
                while (!stk.empty()) {
                  const std::pair<int,int> c = stk.back(); stk.pop_back();
                  cells.push_back(c);
                  for (int dj = -1; dj <= 1; ++dj)
                    for (int di = -1; di <= 1; ++di) {
                      const int a2 = c.first + di, b2 = c.second + dj;
                      if (a2 < 0 || b2 < 0 || a2 >= RX || b2 >= RY) continue;
                      if (occ[ridx(a2, b2, k)] && !lab[static_cast<std::size_t>(b2) * RX + a2]) {
                        lab[static_cast<std::size_t>(b2) * RX + a2] = nl;
                        stk.push_back({a2, b2});
                      }
                    }
                }
                bool sup = false;
                for (const std::pair<int,int>& c : cells) {
                  for (int dj = -1; dj <= 1 && !sup; ++dj)
                    for (int di = -1; di <= 1 && !sup; ++di) {
                      const int a2 = c.first + di, b2 = c.second + dj;
                      if (a2 < 0 || b2 < 0 || a2 >= RX || b2 >= RY) continue;
                      if (occ[ridx(a2, b2, k - 1)]) sup = true;
                    }
                  if (sup) break;
                }
                if (!sup) out.push_back({k, cells});
              }
          }
        };
        std::vector<Island> isl;
        int ground = -1;
        for (int round = 0; round < kOrganicSupportRounds; ++round) {
          stamp_all();
          find_islands(isl, ground);
          if (isl.empty()) { st.support_converged = true; break; }
          if (round == 0)
            for (const Island& I : isl) {
              ++st.unsupported_islands_found;
              st.unsupported_cells_found += I.cells.size();
            }
          // ── ★★ BRANCHED SUPPORT (kOrganicBranchMergeRadiusRatio cites the source) ──
          // Every unsupported island becomes a branch TIP. The tips then descend one
          // layer at a time, together: at each step a tip may lean toward its nearest
          // neighbour and toward the nearest material below, tips that meet MERGE into
          // one trunk, and a branch stops the moment it touches lattice. What reaches
          // the bottom is a handful of trunks rather than one pillar per island.
          std::vector<std::pair<Vec3, Vec3>> legs;
          std::vector<std::size_t> doomed;
          {
            struct Tip { Vec3 p; int k; bool alive; };
            std::vector<Tip> tips;
            for (const Island& I : isl) {
              double xs = 0.0, ys = 0.0;
              for (const std::pair<int,int>& c : I.cells) {
                xs += lo.x + (c.first + 0.5) * vxy;
                ys += lo.y + (c.second + 0.5) * vxy;
              }
              const double n = static_cast<double>(I.cells.size());
              tips.push_back({{xs / n, ys / n, lo.z + (I.k + 0.5) * vz}, I.k, true});
              ++st.branch_seeds;
            }
            const double merge_r = kOrganicBranchMergeRadiusRatio * rmin;
            const double tan_tilt =
                std::tan(kOrganicBranchMaxTiltDeg * 3.14159265358979323846 / 180.0);
            // Descend. Every tip that is still alive steps down one layer per round.
            for (int step = 0; step < kOrganicBranchMaxSteps; ++step) {
              // ★ A DESCENDING SWEEP PLANE, WHICH IS WHY TREE SUPPORTS MERGE AT ALL.
              // Stepping every live tip each round keeps them at the heights they
              // started from, so two tips never share a layer and the merge test never
              // fires — measured: 176 seeds, ZERO merges. Only the tips at the current
              // highest layer move, so the rest wait for the plane to reach them and
              // the population gathers where it can coalesce.
              int kmax = -1;
              for (const Tip& t : tips)
                if (t.alive && t.k > ground) kmax = std::max(kmax, t.k);
              if (kmax < 0) break;
              // MERGE first: two tips within one merge radius are one trunk from here
              // down, and the survivor takes the midpoint.
              for (std::size_t i = 0; i < tips.size(); ++i) {
                if (!tips[i].alive) continue;
                for (std::size_t j = i + 1; j < tips.size(); ++j) {
                  if (!tips[j].alive || tips[j].k != tips[i].k) continue;   // same plane
                  if (vlen(vsub(tips[i].p, tips[j].p)) > merge_r) continue;
                  legs.push_back({tips[j].p, tips[i].p});
                  st.branch_length_mm += vlen(vsub(tips[j].p, tips[i].p));
                  tips[j].alive = false;
                  ++st.branch_merges;
                }
              }
              for (Tip& t : tips) {
                if (!t.alive || t.k != kmax) continue;
                const int nk = t.k - 1;
                const double zn = lo.z + (nk + 0.5) * vz;
                // Lean toward the nearest MATERIAL in the layer below, and toward the
                // nearest living neighbour. Both are capped by the tilt allowance.
                const int ci = static_cast<int>((t.p.x - lo.x) / vxy);
                const int cj = static_cast<int>((t.p.y - lo.y) / vxy);
                double bx = t.p.x, by = t.p.y, best = 1e30;
                const int R = 8;
                for (int dj = -R; dj <= R; ++dj)
                  for (int di = -R; di <= R; ++di) {
                    const int a2 = ci + di, b2 = cj + dj;
                    if (a2 < 0 || b2 < 0 || a2 >= RX || b2 >= RY) continue;
                    if (!occ[ridx(a2, b2, nk)]) continue;
                    const double cx = lo.x + (a2 + 0.5) * vxy;
                    const double cy = lo.y + (b2 + 0.5) * vxy;
                    const double d = (cx - t.p.x) * (cx - t.p.x) + (cy - t.p.y) * (cy - t.p.y);
                    if (d < best) { best = d; bx = cx; by = cy; }
                  }
                double tx = bx, ty = by;
                if (best > 1e29) {                       // nothing below: seek a neighbour
                  double nb = 1e30;
                  for (const Tip& o : tips) {
                    if (!o.alive || &o == &t) continue;
                    const double d = (o.p.x - t.p.x) * (o.p.x - t.p.x) +
                                     (o.p.y - t.p.y) * (o.p.y - t.p.y);
                    if (d < nb) { nb = d; tx = o.p.x; ty = o.p.y; }
                  }
                  if (nb > 1e29) { tx = t.p.x; ty = t.p.y; }
                }
                // Cap the lateral step by the tilt allowance for one layer.
                const double maxs = tan_tilt * vz;
                double dx = tx - t.p.x, dy = ty - t.p.y;
                const double dl = std::sqrt(dx * dx + dy * dy);
                if (dl > maxs && dl > 1e-12) { dx *= maxs / dl; dy *= maxs / dl; }
                Vec3 np{t.p.x + dx, t.p.y + dy, zn};
                if (boundary && boundary->signed_distance(np) < rmin) {
                  np.x = t.p.x; np.y = t.p.y;             // leaning would breach: go down
                  if (boundary->signed_distance(np) < rmin) { t.alive = false; continue; }
                }
                legs.push_back({t.p, np});
                st.branch_length_mm += vlen(vsub(np, t.p));
                t.p = np;
                t.k = nk;
                // ANCHOR ON THE MODEL: touched lattice, so this branch is done.
                const int ai = static_cast<int>((np.x - lo.x) / vxy);
                const int aj = static_cast<int>((np.y - lo.y) / vxy);
                if (ai >= 0 && aj >= 0 && ai < RX && aj < RY && occ[ridx(ai, aj, nk)]) {
                  t.alive = false;
                  ++st.branch_anchored_on_model;
                }
              }
            }
            for (const Tip& t : tips)
              if (t.k <= ground) ++st.branch_trunks;
            // ★ AND THE FALLBACK THE BRANCH REWRITE DROPPED. A tip that died without
            // anchoring and without reaching the ground supported nothing, and its
            // island is still hanging: 183 cells survived when branches replaced the
            // cut outright. Support if a branch can, CUT if it cannot — the set has to
            // stay closed or the refusal downstream has nothing to stand on.
            for (std::size_t ti = 0; ti < tips.size() && ti < isl.size(); ++ti) {
              if (tips[ti].k <= ground) continue;          // reached the base
              if (tips[ti].alive) continue;                // still going / anchored
              const Island& I = isl[ti];
              for (std::size_t si = 0; si < emitted.size(); ++si) {
                // ★ LEGS AND FILL ARE UNCUTTABLE, and for the same reason: both are
                // placed already anchored on material at both ends, so a cut can only
                // undo work that was correct when it was done. It also makes the loop
                // TERMINATE. The fill is an adding pass, and the termination argument
                // requires every adder to be gated on a defect its own addition
                // resolves. Cuttable fill is not: it fills a cell, the cut reopens it,
                // it fills again — 24 rounds and `converged` still false. Uncuttable
                // fill resolves the emptiness for good, so the next round finds nothing
                // to do and the loop quiesces.
                if (!live[si] || emitted[si].src == Src::Leg ||
                    emitted[si].src == Src::Fill) continue;
                bool touches = false;
                for (const std::pair<int,int>& c : I.cells)
                  if (covers(emitted[si], c.first, c.second, I.k)) { touches = true; break; }
                if (touches) { live[si] = 0; doomed.push_back(si); }
              }
            }
          }
          cur_src = Src::Leg;
          for (const std::pair<Vec3, Vec3>& L : legs) {
            const std::size_t before = emitted.size();
            span(L.first, L.second, rmin);
            live.resize(emitted.size(), 1);
            if (emitted.size() > before) {
              ++st.support_legs_added; ++st.mutations;
              st.support_leg_length_mm += vlen(vsub(L.second, L.first));
            }
          }
          for (std::size_t d : doomed) {
            ++st.support_spans_cut; ++st.mutations;
            st.support_cut_length_mm += emitted[d].len;
          }
        // ── ★★ A CUT LEAVES A DANGLING END, AND SOMETHING MUST CLEAN UP AFTER IT ──
          // The free-end prune ran BEFORE this pass, so every span cut here leaves the
          // stub it was attached to with a tip in open space. Measured: this pass cut 74
          // spans and `free_ends` went 0 -> 252 — the mid-air defect fixed by
          // reintroducing the defect the prune exists to remove. Erode the exposed tips
          // to a fixed point, with the SAME support rule the prune uses: a tip is held
          // when it lands on another live span's BODY, or meets a tip that leads away.
          if (!doomed.empty()) {
            double creach = 0.0;
            for (const EmittedSeg& e : emitted) creach = std::max(creach, e.len + 2.0 * e.r);
            const double ccell = std::max(creach, 1e-6);
            auto ckey = [ccell](const Vec3& p) {
              return std::array<long long, 3>{
                  static_cast<long long>(std::floor(p.x / ccell)),
                  static_cast<long long>(std::floor(p.y / ccell)),
                  static_cast<long long>(std::floor(p.z / ccell))};
            };
            double zfloor = emitted.front().a.z;
            for (const EmittedSeg& e : emitted)
              zfloor = std::min(zfloor, std::min(e.a.z, e.b.z));
            for (int cr = 0; cr < kOrganicPruneRounds; ++cr) {
              std::map<std::array<long long, 3>, std::vector<int>> cb;
              for (std::size_t i = 0; i < emitted.size(); ++i)
                if (live[i])
                  cb[ckey(vmul(vadd(emitted[i].a, emitted[i].b), 0.5))].push_back(int(i));
              std::vector<std::size_t> kill;
              for (std::size_t i = 0; i < emitted.size(); ++i) {
                if (!live[i]) continue;
                for (int e2 = 0; e2 < 2; ++e2) {
                  const Vec3 tip = e2 ? emitted[i].b : emitted[i].a;
                  if (tip.z - zfloor <= emitted[i].r) continue;      // on the plate
                  const Vec3 d0 = e2 ? vsub(emitted[i].b, emitted[i].a)
                                     : vsub(emitted[i].a, emitted[i].b);
                  const double dn = vlen(d0);
                  const Vec3 out = dn > 1e-9 ? vmul(d0, 1.0 / dn) : Vec3{0.0, 0.0, 1.0};
                  bool held = false;
                  const auto k0 = ckey(tip);
                  for (long long dz = -1; dz <= 1 && !held; ++dz)
                    for (long long dy = -1; dy <= 1 && !held; ++dy)
                      for (long long dx = -1; dx <= 1 && !held; ++dx) {
                        auto it = cb.find({k0[0] + dx, k0[1] + dy, k0[2] + dz});
                        if (it == cb.end()) continue;
                        for (int j : it->second) {
                          if (static_cast<std::size_t>(j) == i || !live[j]) continue;
                          const EmittedSeg& o = emitted[j];
                          const Vec3 ab = vsub(o.b, o.a);
                          const double abab = vdot(ab, ab);
                          double t = abab > 0.0 ? vdot(vsub(tip, o.a), ab) / abab : 0.0;
                          t = std::min(1.0, std::max(0.0, t));
                          const Vec3 q = vadd(o.a, vmul(ab, t));
                          if (vdot(vsub(q, tip), vsub(q, tip)) > o.r * o.r) continue;
                          const double da = vlen(vsub(q, o.a)), db = vlen(vsub(q, o.b));
                          if (da > 0.5 * o.r && db > 0.5 * o.r) { held = true; break; }
                          const Vec3 away = vsub((da <= db) ? o.b : o.a, tip);
                          const double an = vlen(away);
                          if (an > 1e-9 &&
                              vdot(vmul(away, 1.0 / an), out) > kOrganicFoldBackCos) {
                            held = true; break;
                          }
                        }
                      }
                  if (!held) { kill.push_back(i); break; }
                }
              }
              if (kill.empty()) break;
              for (std::size_t i : kill) {
                live[i] = 0;
                ++st.support_cleanup_pruned; ++st.mutations;
              }
            }
          }
          ++st.support_rounds;
          // ★ A ROUND THAT COULD NEITHER SUPPORT NOR CUT ANYTHING WILL NEVER DO BETTER.
          // Spinning to the round cap hides that; say it once and stop.
          if (legs.empty() && doomed.empty()) break;
        }
          // ══════════════════════════════════════════════════════════════════════
          // ★★★ VDI SLENDERNESS: PROP THE BARS THAT ARE TOO LONG FOR THEIR ANGLE ★★★
          //
          // ★ IT RUNS AFTER THE SUPPORT ROUNDS, NOT INSIDE THEM. Sited inside, it was
          // UNREACHABLE: that loop opens with `if (isl.empty()) break;` and this part
          // has no mid-air left, so the block never ran once — every statistic came
          // back byte-identical to the previous run on a freshly built binary, which
          // reads exactly like "checked, nothing to fix". Slenderness is not a mid-air
          // defect and must not be gated on one.
          //
          // ★ IT IS A NEW TRIGGER ON THE SAME MACHINERY, NOT A NEW PASS. Everything below —
          // legs, uncuttability, the cleanup prune, the fixed point — already exists
          // and already terminates. Adding a second reason to drop a leg reuses all of
          // it; adding a new adding-pass would have had to earn termination again, and
          // this file has already paid for that twice.
          //
          // ★ WHAT IT TARGETS, AND WHAT IT DELIBERATELY DOES NOT. A slicer paints an
          // overhang by the 45 deg SURFACE rule, which on the maintainer's cube called
          // 5934 of 9223 struts (64.3 %) overhanging. That rule is for surfaces; a
          // strut BRIDGES, and the standard for bars is VDI 3405-3-4: l/D <= 5 at the
          // critical angle, l/D <= 10 flat. By THAT rule only 197 struts (2.1 %) are in
          // violation. Chasing the paint would mean rebuilding 64 % of the lattice to
          // fix 2 % of it, so this pass is scoped to the 2 %.
          //
          // ★ WHY PROPPING AND NOT THICKENING OR MOVING. The worst case measured is a
          // 38.88 mm flat bar 1.12 mm across, l/D 34.7. Thickening it to reach l/D 10
          // needs D >= 3.89 mm, which is not a lattice any more. Moving its nodes
          // cannot help either — it is flat BY DESIGN, spanning a gap. Dividing it into
          // four propped pieces takes l/D to 8.7 and changes nothing else about it.
          // ★ AT QUIESCENCE ONLY. Run every round it judged geometry the later
          // passes were still changing and counted 1541 violations against the 197 the
          // shipped spans actually hold — the same defect the fill mat had at both ends
          // of this loop. `slenderness_done` makes it fire once, on the settled set.
          if (!slenderness_done && st.mutations == mutations_at_round_start) {
            slenderness_done = true;
            const double flat_cos =
                std::cos(kOrganicVdiFlatAngleDeg * M_PI / 180.0);
            std::vector<std::pair<Vec3, Vec3>> props;
            for (std::size_t si = 0; si < emitted.size(); ++si) {
              if (!live[si]) continue;
              const EmittedSeg& e = emitted[si];
              const double d = 2.0 * e.r;
              if (!(d > 0.0) || !(e.len > 0.0)) continue;
              const Vec3 u = vmul(vsub(e.b, e.a), 1.0 / e.len);
              // sin of the angle from the plate == |u.z| for a unit direction.
              const bool flat = std::fabs(u.z) < flat_cos;
              const double limit = flat ? kOrganicVdiSlendernessFlatMax
                                        : kOrganicVdiSlendernessMax;
              // ★★ THE LIMIT IS ON THE UNSUPPORTED SPAN, NOT THE WHOLE STRUT. A bar
              // lying across a bed of other struts is not a bridge of its own length —
              // it is a series of short ones. Measured on total length the pass called
              // 1541 struts slender and then found "nothing beneath" for every single
              // one of them, which is the contradiction that gave this away: material
              // was there, it just was not being counted as support. Walk the strut and
              // take the LONGEST unsupported run.
              const int NS = std::max(2, static_cast<int>(e.len / std::max(vz, 1e-6)));
              double run = 0.0, worst_run = 0.0;
              double run_t0 = 0.0, worst_t0 = 0.0, worst_t1 = 0.0;
              for (int q = 0; q <= NS; ++q) {
                const double t = static_cast<double>(q) / NS;
                const Vec3 pt = vadd(e.a, vmul(vsub(e.b, e.a), t));
                const int qi = static_cast<int>((pt.x - lo.x) / vxy);
                const int qj = static_cast<int>((pt.y - lo.y) / vxy);
                const int qk = static_cast<int>((pt.z - lo.z) / vz);
                bool held = false;
                if (qi >= 0 && qj >= 0 && qi < RX && qj < RY && qk - 1 >= 0)
                  held = occ[ridx(qi, qj, qk - 1)];
                if (held) { run = 0.0; run_t0 = t; }
                else {
                  run = (t - run_t0) * e.len;
                  if (run > worst_run) { worst_run = run; worst_t0 = run_t0; worst_t1 = t; }
                }
              }
              const double ld = worst_run / d;
              if (ld <= limit) continue;
              ++st.slenderness_violating;
              // How many equal pieces bring l/D under the limit, capped.
              int pieces = static_cast<int>(std::ceil(ld / limit));
              if (pieces > kOrganicSlendernessMaxProps) {
                ++st.slenderness_impossible;   // too slender to prop into shape
                continue;
              }
              bool any = false;
              for (int q = 1; q < pieces; ++q) {
                // Spaced along the UNSUPPORTED stretch — propping outside it would
                // put a leg where the strut is already held.
                const double t = worst_t0 + (worst_t1 - worst_t0) *
                                                (static_cast<double>(q) / pieces);
                const Vec3 mid = vadd(e.a, vmul(vsub(e.b, e.a), t));
                // Straight down to whatever is below — the same question the mid-air
                // pass asks, answered against the SAME raster, so a prop never claims
                // to land on something the support pass does not also see.
                const int pi = static_cast<int>((mid.x - lo.x) / vxy);
                const int pj = static_cast<int>((mid.y - lo.y) / vxy);
                const int pk = static_cast<int>((mid.z - lo.z) / vz);
                if (pi < 0 || pj < 0 || pi >= RX || pj >= RY) continue;
                int hit = ground;                       // the plate, if nothing sooner
                for (int kk = pk - 1; kk > ground; --kk) {
                  if (kk < 0) break;
                  if (occ[ridx(pi, pj, kk)]) { hit = kk; break; }
                }
                const double zf = lo.z + (hit + 0.5) * vz;
                if (!(zf < mid.z - e.r)) continue;   // nothing beneath to stand on
                props.push_back({mid, Vec3{mid.x, mid.y, zf}});
                ++st.slenderness_props_added;
                any = true;
              }
              if (any) ++st.slenderness_propped;
              else     ++st.slenderness_impossible;
            }
            cur_src = Src::Leg;   // structural: uncuttable, like every other leg
            for (const std::pair<Vec3, Vec3>& L : props) {
              const std::size_t before = emitted.size();
              span(L.first, L.second, rmin);
              live.resize(emitted.size(), 1);
              if (emitted.size() > before) {
                ++st.support_legs_added; ++st.mutations;
                st.support_leg_length_mm += vlen(vsub(L.second, L.first));
              }
            }
            // ★ REPORTED WHENEVER A VIOLATION IS SEEN, never only when a prop was
            // placed. Gated on props, a pass that found 197 violations and could prop
            // none printed nothing at all — indistinguishable from not running, which
            // is precisely the confusion this line exists to prevent.
            if (st.slenderness_violating > 0)
              std::fprintf(stderr,
                           "[vdi] %zu struts over l/D, %zu propped, %zu impossible, "
                           "%zu props\n",
                           st.slenderness_violating, st.slenderness_propped,
                           st.slenderness_impossible, st.slenderness_props_added);
          }

        // Drop what was cut, so the emission and every count below see only what ships.
        if (st.support_spans_cut > 0 || st.support_cleanup_pruned > 0) {
          std::vector<EmittedSeg> keep;
          keep.reserve(emitted.size());
          for (std::size_t i = 0; i < emitted.size(); ++i)
            if (live[i]) keep.push_back(emitted[i]);
          emitted.swap(keep);
          live.assign(emitted.size(), 1);
        }
        // ── ★★ AND THE STRANDED DROP RUNS AGAIN, BECAUSE THE CUTS SHATTERED IT ─────
        // The earlier stranded-piece drop ran BEFORE this pass, so it never saw what the
        // cuts here would sever: 627 spans removed and the cube came apart into 27
        // components. Every pass that CUTS must be followed by whatever repairs cutting
        // breaks — that is the same lesson as the free-end cleanup two blocks up, and
        // this is the fourth place in this file it applies.
        if (!emitted.empty()) {
          double sreach = 0.0;
          for (const EmittedSeg& e : emitted) sreach = std::max(sreach, e.len + 2.0 * e.r);
          const double scell = std::max(sreach, 1e-6);
          std::map<std::array<long long, 3>, std::vector<int>> sb;
          auto skey = [scell](const Vec3& p) {
            return std::array<long long, 3>{
                static_cast<long long>(std::floor(p.x / scell)),
                static_cast<long long>(std::floor(p.y / scell)),
                static_cast<long long>(std::floor(p.z / scell))};
          };
          for (std::size_t i = 0; i < emitted.size(); ++i)
            sb[skey(vmul(vadd(emitted[i].a, emitted[i].b), 0.5))].push_back(int(i));
          std::vector<int> sp(emitted.size());
          for (std::size_t i = 0; i < sp.size(); ++i) sp[i] = static_cast<int>(i);
          std::function<int(int)> sf = [&sp](int a) {
            while (sp[a] != a) { sp[a] = sp[sp[a]]; a = sp[a]; }
            return a;
          };
          for (const auto& kv : sb)
            for (long long dz = -1; dz <= 1; ++dz)
              for (long long dy = -1; dy <= 1; ++dy)
                for (long long dx = -1; dx <= 1; ++dx) {
                  auto it = sb.find({kv.first[0] + dx, kv.first[1] + dy, kv.first[2] + dz});
                  if (it == sb.end()) continue;
                  for (int i : kv.second)
                    for (int j : it->second) {
                      if (j <= i) continue;
                      const double touch = emitted[i].r + emitted[j].r;
                      if (organic_segment_distance2(emitted[i].a, emitted[i].b,
                                                    emitted[j].a, emitted[j].b) >
                          touch * touch)
                        continue;
                      const int ra = sf(i), rb = sf(j);
                      if (ra != rb) sp[std::max(ra, rb)] = std::min(ra, rb);
                    }
                }
          std::map<int, double> slen;
          double stotal = 0.0;
          for (std::size_t i = 0; i < emitted.size(); ++i) {
            slen[sf(static_cast<int>(i))] += emitted[i].len;
            stotal += emitted[i].len;
          }
          int sbig = -1; double sbl = -1.0;
          for (const auto& kv : slen)
            if (kv.second > sbl) { sbl = kv.second; sbig = kv.first; }
          std::vector<EmittedSeg> sbody;
          sbody.reserve(emitted.size());
          for (std::size_t i = 0; i < emitted.size(); ++i) {
            const int root = sf(static_cast<int>(i));
            if (root == sbig || slen[root] >= kOrganicStrandedKeepFraction * stotal)
              sbody.push_back(emitted[i]);
            else {
              ++st.stranded_spans_dropped; ++st.mutations;
              st.stranded_length_dropped_mm += emitted[i].len;
              ++st.support_post_stranded_dropped; ++st.mutations;
            }
          }
          emitted.swap(sbody);
        }
      } else {
        // ★ THE CHECK DID NOT RUN, which is NOT the same as passing. The caller
        // refuses on this rather than reading a zero that was never measured.
        st.support_grid_too_large = true;
      }
    }

    // ── ★★ THE FILL MAT — ONCE, ON THE CONVERGED GEOMETRY ───────────────────────
    // ★ IT RUNS WHEN EVERYTHING ELSE HAS SETTLED, AND ONLY ONCE. Three placements
    // were tried and the first two failed as mirror images of each other. BEFORE the
    // loop it saw 28 empty cells because the repairs had not run yet, and they then cut
    // material and opened new holes behind it: 104 empty against a 117 baseline. AFTER
    // the loop it saw the real holes and filled them — 33 empty — but nothing repaired
    // what it broke: 134 free ends, and still 84 once its arms grew to material rather
    // than stopping at a fixed reach.
    //
    // Putting it inside the loop as an ordinary pass did not work either, even with its
    // struts made uncuttable: it re-found the same ~58 empty cells every round and kept
    // adding struts that did not clear them, so `mutations` never settled — 24 rounds,
    // `converged` still false. A pass that cannot certify it resolved the defect it
    // fired on is not a fixed-point pass, and the loop's termination argument says so.
    //
    // Running it once at quiescence satisfies both ends. It reads the geometry that
    // ships, not an intermediate state; the loop then keeps turning, so the repairs
    // still run behind whatever it added; and it cannot iterate, so it cannot diverge.
    if (lat.fill_mat && !fill_mat_done) {
      fill_mat_done = true;
    // ★ IT IS A REPAIR LIKE THE OTHERS, so it belongs in the fixed point with them.
    // It was tried at both ends of the loop and both failed for the SAME reason, in
    // mirror image. Before the loop it saw only 28 empty cells because the repairs had
    // not run yet, and they then cut material and opened new holes behind it: 104 empty
    // against a 117 baseline. After the loop it saw the real holes and filled them —
    // 33 empty — but nothing repaired what IT broke, and its arms ended in open space:
    // 134 free ends, then 84 once the arms grew to material instead of a fixed reach.
    //
    // Neither end works because the dependency is the same CYCLE every other repair is
    // in: filling adds struts, added struts can be unsupported, repairing that cuts, and
    // cutting opens holes to fill. Running it inside the loop is not a compromise
    // between the two orderings — it is the only placement where the number that ships
    // is read at quiescence, which is the whole argument the loop was built on.
    //
    // ★ THE COUNTERS ACCUMULATE ACROSS ROUNDS, and that is only honest because fill
    // struts are UNCUTTABLE: nothing downstream removes them, so the running total is
    // what ships. Were they cuttable this would report coverage that is not in the
    // geometry — the same lie as a census easier to pass than the pass it audits.
    if (!emitted.empty() && lat.fill_mat) {
    double rsum = 0.0, lsum = 0.0;
    Vec3 lo = emitted.front().a, hi = emitted.front().a;
    for (const EmittedSeg& e : emitted) {
      rsum += e.r; lsum += e.len;
      for (const Vec3& p : {e.a, e.b}) {
        lo.x = std::min(lo.x, p.x); lo.y = std::min(lo.y, p.y); lo.z = std::min(lo.z, p.z);
        hi.x = std::max(hi.x, p.x); hi.y = std::max(hi.y, p.y); hi.z = std::max(hi.z, p.z);
      }
    }
    const double rfill = rsum / emitted.size();
    // The cell is the separation this lattice is expressed in: a gap wider than one
    // separation is a hole, anything smaller is just the grade being sparse.
    const double cell = lat.report.achieved_spacing_median_mm > 0.0
                            ? lat.report.achieved_spacing_median_mm
                            : (lsum / emitted.size());
    const int FX = static_cast<int>((hi.x - lo.x) / cell) + 1;
    const int FY = static_cast<int>((hi.y - lo.y) / cell) + 1;
    const int FZ = static_cast<int>((hi.z - lo.z) / cell) + 1;
    if (cell > 0.0 && static_cast<long long>(FX) * FY * FZ <= kOrganicFillMaxCells &&
        FX > 0 && FY > 0 && FZ > 0) {
      auto fidx = [FX, FY](int i, int j, int k) {
        return (static_cast<std::size_t>(k) * FY + j) * FX + i;
      };
      std::vector<unsigned char> full(static_cast<std::size_t>(FX) * FY * FZ, 0);
      for (const EmittedSeg& e : emitted) {
        const int n = std::max(2, static_cast<int>(e.len / (0.5 * cell)) + 1);
        for (int t = 0; t <= n; ++t) {
          const Vec3 p = vadd(e.a, vmul(vsub(e.b, e.a), double(t) / n));
          const int i = std::min(FX - 1, std::max(0, int((p.x - lo.x) / cell)));
          const int j = std::min(FY - 1, std::max(0, int((p.y - lo.y) / cell)));
          const int k = std::min(FZ - 1, std::max(0, int((p.z - lo.z) / cell)));
          full[fidx(i, j, k)] = 1;
        }
      }
      cur_src = Src::Leg;               // structural: the prune may not touch it
      for (int k = 0; k < FZ; ++k)
        for (int j = 0; j < FY; ++j)
          for (int i = 0; i < FX; ++i) {
            if (full[fidx(i, j, k)]) continue;
            const Vec3 c{lo.x + (i + 0.5) * cell, lo.y + (j + 0.5) * cell,
                         lo.z + (k + 0.5) * cell};
            // Only inside the part, and only where a strut of this radius fits.
            if (boundary && boundary->signed_distance(c) < rfill) continue;
            ++st.fill_mat_cells;
            // Three axis-aligned struts through the cell centre, each reaching PAST
            // the cell into whatever is around it. That is what makes them anchored
            // rather than loose — the lesson the coverage stub taught by failing.
            // ★ EACH ARM GROWS UNTIL IT HITS MATERIAL, rather than stopping at a
            // fixed reach and hoping. A fixed 1.5-cell arm ended in open space wherever
            // the neighbour happened to be further away, and those tips are free ends:
            // 134 of them, the exact defect the prune exists to remove. An arm that
            // stops ON material is anchored by construction; an arm that finds none
            // within the limit is not emitted at all.
            const int dirs[3][3] = {{1,0,0},{0,1,0},{0,0,1}};
            for (const int* d : dirs) {
              Vec3 ends[2];
              bool ok[2] = {false, false};
              for (int sgn = 0; sgn < 2; ++sgn) {
                const int step = sgn ? -1 : 1;
                for (int m = 1; m <= kOrganicFillMaxReachCells; ++m) {
                  const int a2 = i + d[0] * step * m;
                  const int b2 = j + d[1] * step * m;
                  const int c2 = k + d[2] * step * m;
                  if (a2 < 0 || b2 < 0 || c2 < 0 || a2 >= FX || b2 >= FY || c2 >= FZ)
                    break;
                  if (!full[fidx(a2, b2, c2)]) continue;
                  ends[sgn] = Vec3{lo.x + (a2 + 0.5) * cell, lo.y + (b2 + 0.5) * cell,
                                   lo.z + (c2 + 0.5) * cell};
                  ok[sgn] = true;
                  break;
                }
              }
              if (!ok[0] || !ok[1]) continue;      // not anchored both ends: skip it
              const std::size_t before = emitted.size();
              const Src saved_src = cur_src;
              cur_src = Src::Fill;
              span(ends[0], ends[1], rfill);
              cur_src = saved_src;
              for (std::size_t q = before; q < emitted.size(); ++q) {
                ++st.fill_mat_struts;
                ++st.mutations;   // else the loop calls quiescence mid-fill
                st.fill_mat_length_mm += emitted[q].len;
              }
            }
          }
    }
      if (st.mutations != mutations_at_round_start) continue;   // repair what it added
    }
    }

    if (st.mutations == mutations_at_round_start) {
      st.fixed_point_converged = true;
      break;
    }
  }


  // ══════════════════════════════════════════════════════════════════════════════
  // ★★★ THE FINISH, AFTER THE FIXED POINT — A LOOK, NEVER A REPAIR ★★★
  // The maintainer's ruling. It is OUTSIDE the loop above on purpose: inside it, the
  // finish would iterate with the structural passes and its joins would change what
  // they cut, which is exactly the "finish as structural intervention wearing an
  // aesthetic name" this was corrected for once already. Everything above is the
  // ALGORITHM and produces one lattice; `clean`, `rim` and `skin` share it byte for
  // byte, and differ only by what is added here.
  // ── the finish's own spatial index. It used to borrow the repair loop's, which is
  // precisely the coupling that let a "look" reach into the structure.
  if (!emitted.empty() && lat.net_skin_reach_mm > 0.0 &&
      lat.net_skin_finish != OrganicLattice::Finish::Clean) {
    double reach = 0.0;
    for (const EmittedSeg& e : emitted) reach = std::max(reach, e.len + 2.0 * e.r);
    const double cell = std::max(reach, 1e-6);
    auto key = [cell](const Vec3& p) {
      return std::array<long long, 3>{
          static_cast<long long>(std::floor(p.x / cell)),
          static_cast<long long>(std::floor(p.y / cell)),
          static_cast<long long>(std::floor(p.z / cell))};
    };
    std::vector<unsigned char> alive(emitted.size(), 1);
    std::map<std::array<long long, 3>, std::vector<int>> bucket;
    auto rebuild = [&]() {
      bucket.clear();
      for (std::size_t i = 0; i < emitted.size(); ++i)
        if (alive[i])
          bucket[key(vmul(vadd(emitted[i].a, emitted[i].b), 0.5))].push_back(int(i));
    };
    rebuild();
    double zfloor = emitted.front().a.z;
    for (const EmittedSeg& e : emitted)
      zfloor = std::min(zfloor, std::min(e.a.z, e.b.z));
    auto on_plate = [&](const Vec3& p, double r) { return p.z - zfloor <= r; };
    auto tip_dir = [&](std::size_t i, int e) {
      const EmittedSeg& s2 = emitted[i];
      const Vec3 d = e ? vsub(s2.b, s2.a) : vsub(s2.a, s2.b);
      const double n = vlen(d);
      return n > 1e-9 ? vmul(d, 1.0 / n) : Vec3{0.0, 0.0, 1.0};
    };
    auto tip_supported = [&](std::size_t i, const Vec3& tip, const Vec3& out) {
      const auto k0 = key(tip);
      for (long long dz = -1; dz <= 1; ++dz)
        for (long long dy = -1; dy <= 1; ++dy)
          for (long long dx = -1; dx <= 1; ++dx) {
            auto it = bucket.find({k0[0] + dx, k0[1] + dy, k0[2] + dz});
            if (it == bucket.end()) continue;
            for (int j : it->second) {
              if (static_cast<std::size_t>(j) == i || !alive[j]) continue;
              const EmittedSeg& e = emitted[j];
              const Vec3 ab = vsub(e.b, e.a);
              const double abab = vdot(ab, ab);
              double t = abab > 0.0 ? vdot(vsub(tip, e.a), ab) / abab : 0.0;
              t = std::min(1.0, std::max(0.0, t));
              const Vec3 q = vadd(e.a, vmul(ab, t));
              if (vdot(vsub(q, tip), vsub(q, tip)) > e.r * e.r) continue;
              const double da = vlen(vsub(q, e.a)), db = vlen(vsub(q, e.b));
              if (da > 0.5 * e.r && db > 0.5 * e.r) return true;
              const Vec3 away = vsub((da <= db) ? e.b : e.a, tip);
              const double an = vlen(away);
              if (an > 1e-9 && vdot(vmul(away, 1.0 / an), out) > kOrganicFoldBackCos)
                return true;
            }
          }
      return false;
    };
    (void)on_plate; (void)tip_supported; (void)tip_dir;
    if (std::getenv("TOPOPT_ORGANIC_SUPPORT_TRACE"))
      std::fprintf(stderr, "[finish] entered: spans=%zu reach=%.3f finish=%d\n",
                   emitted.size(), lat.net_skin_reach_mm,
                   static_cast<int>(lat.net_skin_finish));
  // ── ★★ THE BOUNDARY FINISH RUNS LAST, AND THAT IS THE POINT ────────────────
  // ★ A FINISH IS A LOOK, NOT A REPAIR. Everything above — the node merge, the tie,
  // the support prune, the stranded-piece drop — is the ALGORITHM, and it runs
  // identically whichever finish was asked for. The structural core of `clean`,
  // `rim` and `skin` is therefore the same lattice, byte for byte, and the three
  // files differ ONLY by the joins added below. That ordering is deliberate: when
  // the finish ran BEFORE the prune it changed what got cut (1,588 spans for clean
  // against 1,210 for skin), which made the finish a structural intervention
  // wearing an aesthetic name, and made "which finish prints better" a meaningful
  // question when it must not be one.
  alive.assign(emitted.size(), 1);
  rebuild();
  // ── ★★ THE NET-SKIN (organic's diagrid) ─────────────────────────────────────
    // Aremu et al. (Additive Manufacturing 13:1-13, 2017) name the defect and the cure:
    // trimming a lattice to a surface leaves "hanging" struts with a free end each, and
    // joining those ends into an EXTERNAL TWO-DIMENSIONAL LATTICE — a net-skin — braces
    // them without the mass of a full skin and without closing the surface.
    //
    // ★ IT IS 53 % OF WHAT THE EYE SEES. Measured on the shipped welded cube with a
    // detector that reads only the file (principal-axis one-sidedness, positive control:
    // 640 on the untied build, 269 on the coupon that PRINTED): 629 ends, of which 224
    // sit ON a cube face and another 109 within 1.5 mm of one. The interior remainder is
    // at the same density as the printed coupon. The octet path already fixes this half
    // with its diagrid and scores 13 per 100k vertices against organic's 151.
    //
    // MUTUAL nearest, exactly the discipline the connector pass uses: an edge exists
    // only when BOTH landings want it, which is what stops a crowded corner from growing
    // a hairball. Each join is CLIPPED like every other span, so it cannot leave the part.
    if (lat.net_skin_reach_mm > 0.0 &&
        lat.net_skin_finish != OrganicLattice::Finish::Clean) {
      // ★ IS THIS POINT ON AN EDGE OF THE PART? Read it off the boundary's own field:
      // step tangentially either side and compare surface normals. Across a flat face
      // they agree; across an edge they swing by the dihedral angle. No CAD faces, no
      // mesh topology, no new representation — just the clip the generator already has.
      auto sdf_normal = [&](const Vec3& q, double h) {
        const double d = 0.5 * h;
        Vec3 g{boundary->signed_distance({q.x + d, q.y, q.z}) -
                   boundary->signed_distance({q.x - d, q.y, q.z}),
               boundary->signed_distance({q.x, q.y + d, q.z}) -
                   boundary->signed_distance({q.x, q.y - d, q.z}),
               boundary->signed_distance({q.x, q.y, q.z + d}) -
                   boundary->signed_distance({q.x, q.y, q.z - d})};
        const double n = vlen(g);
        return n > 1e-12 ? vmul(g, 1.0 / n) : Vec3{0.0, 0.0, 0.0};
      };
      const double cos_edge =
          std::cos(kOrganicRimEdgeAngleDeg * 3.14159265358979323846 / 180.0);
      auto on_edge = [&](const Vec3& p, double r) {
        if (!boundary) return false;
        const double h = std::max(2.0 * r, 1e-4);
        const Vec3 n0 = sdf_normal(p, h);
        if (vlen(n0) < 0.5) return false;
        Vec3 t1 = std::fabs(n0.x) < 0.9 ? Vec3{1.0, 0.0, 0.0} : Vec3{0.0, 1.0, 0.0};
        t1 = vsub(t1, vmul(n0, vdot(t1, n0)));
        const double t1n = vlen(t1);
        if (!(t1n > 1e-9)) return false;
        t1 = vmul(t1, 1.0 / t1n);
        const Vec3 t2 = vcross(n0, t1);
        for (int k = 0; k < 4; ++k) {
          const Vec3 t = (k < 2) ? t1 : t2;
          const double sg = (k % 2) ? -1.0 : 1.0;
          const Vec3 n = sdf_normal(vadd(p, vmul(t, sg * 2.0 * h)), h);
          if (vlen(n) < 0.5) continue;
          if (vdot(n, n0) < cos_edge) return true;
        }
        return false;
      };
      cur_src = Src::Net;
      struct Landing { Vec3 p; double r; };
      std::vector<Landing> all;
      // ★ THE SURFACE NODES OF THE FINISHED LATTICE, not the clipped ends of the
      // traced one. The clip erodes by the strut's own radius, so a node sitting on
      // the surface reads signed_distance == r; anything within one half separation
      // of that is on the outer shell. Selecting them from the FINAL geometry is
      // what makes the finish independent of how much the prune took away — keyed
      // on leftovers it collapsed from 661 candidates to 121 for the same look.
      {
        const double band = lat.net_skin_reach_mm * kOrganicFinishBandRatio;
        for (const EmittedSeg& e : emitted)
          for (int k = 0; k < 2; ++k) {
            const Vec3 p = k ? e.b : e.a;
            if (boundary && boundary->signed_distance(p) > e.r + band) continue;
            all.push_back({p, e.r});
          }
        // the merge made coincident endpoints EQUAL, so exact dedup is enough
        std::sort(all.begin(), all.end(), [](const Landing& x, const Landing& y) {
          if (x.p.x != y.p.x) return x.p.x < y.p.x;
          if (x.p.y != y.p.y) return x.p.y < y.p.y;
          return x.p.z < y.p.z;
        });
        all.erase(std::unique(all.begin(), all.end(),
                              [](const Landing& x, const Landing& y) {
                                return x.p.x == y.p.x && x.p.y == y.p.y &&
                                       x.p.z == y.p.z;
                              }),
                  all.end());
      }
      // ★ THE TWO FILTERS THAT MAKE A FINISH VISIBLE. Without them the finish was
      // joining each surface node to the other end of a strut it was already
      // attached to: 1,889 of 2,615 joins duplicated an existing member endpoint
      // for endpoint, 83 % of a sample lay wholly inside existing material, and the
      // three finishes rendered as the same picture.
      auto pkey = [](const Vec3& p) { return std::array<double, 3>{p.x, p.y, p.z}; };
      std::set<std::pair<std::array<double, 3>, std::array<double, 3>>> joined_already;
      for (const EmittedSeg& e : emitted) {
        auto ka = pkey(e.a), kb = pkey(e.b);
        if (kb < ka) std::swap(ka, kb);
        joined_already.insert({ka, kb});
      }
      auto already = [&](const Vec3& a, const Vec3& b) {
        auto ka = pkey(a), kb = pkey(b);
        if (kb < ka) std::swap(ka, kb);
        return joined_already.count({ka, kb}) != 0;
      };
      // A join running THROUGH or ALONGSIDE existing struts is invisible either way.
      auto buried = [&](const Vec3& a, const Vec3& b) {
        const int N = 6;
        for (int k = 0; k <= N; ++k) {
          const Vec3 p = vadd(a, vmul(vsub(b, a), double(k) / N));
          bool inside = false;
          const auto k0 = key(p);
          for (long long dz = -1; dz <= 1 && !inside; ++dz)
            for (long long dy = -1; dy <= 1 && !inside; ++dy)
              for (long long dx = -1; dx <= 1 && !inside; ++dx) {
                auto it = bucket.find({k0[0] + dx, k0[1] + dy, k0[2] + dz});
                if (it == bucket.end()) continue;
                for (int j : it->second)
                  if (organic_segment_distance2(p, p, emitted[j].a, emitted[j].b) <=
                      emitted[j].r * emitted[j].r) { inside = true; break; }
              }
          if (!inside) return false;
        }
        return true;
      };
      std::vector<Landing> L;
      if (lat.net_skin_finish == OrganicLattice::Finish::Rim) {
        for (const Landing& d : all)
          if (on_edge(d.p, d.r)) L.push_back(d);
        st.net_skin_edge_landings = L.size();
      } else {
        L = all;
      }
      st.net_skin_landings = all.size();
      const double reach = lat.net_skin_reach_mm;
      const int deg = std::max(1, lat.net_skin_degree);
      if (L.size() >= 2) {
        const double ncell = std::max(reach, 1e-6);
        std::map<std::array<long long, 3>, std::vector<int>> lb;
        auto lkey = [ncell](const Vec3& p) {
          return std::array<long long, 3>{
              static_cast<long long>(std::floor(p.x / ncell)),
              static_cast<long long>(std::floor(p.y / ncell)),
              static_cast<long long>(std::floor(p.z / ncell))};
        };
        for (std::size_t i = 0; i < L.size(); ++i) lb[lkey(L[i].p)].push_back(int(i));
        // each landing's own shortlist, nearest first
        std::vector<std::vector<int>> want(L.size());
        for (std::size_t i = 0; i < L.size(); ++i) {
          std::vector<std::pair<double, int>> cand;
          const auto k0 = lkey(L[i].p);
          for (long long dz = -1; dz <= 1; ++dz)
            for (long long dy = -1; dy <= 1; ++dy)
              for (long long dx = -1; dx <= 1; ++dx) {
                auto it = lb.find({k0[0] + dx, k0[1] + dy, k0[2] + dz});
                if (it == lb.end()) continue;
                for (int j : it->second) {
                  if (static_cast<std::size_t>(j) == i) continue;
                  const double d = vlen(vsub(L[j].p, L[i].p));
                  if (d < kOrganicFinishMinSpanRatio * reach || d > reach) continue;
                  if (already(L[i].p, L[j].p)) continue;
                  const Vec3 ni = sdf_normal(L[i].p, 2.0 * L[i].r);
                  const Vec3 nj = sdf_normal(L[j].p, 2.0 * L[j].r);
                  if (vlen(ni) > 0.5 && vlen(nj) > 0.5 &&
                      vdot(ni, nj) < kOrganicFinishCoplanarCos)
                    continue;                       // would cut the corner
                  if (buried(L[i].p, L[j].p)) continue;
                  cand.push_back({d, j});
                }
              }
          std::sort(cand.begin(), cand.end(),
                    [](const std::pair<double, int>& a, const std::pair<double, int>& b) {
                      return a.first != b.first ? a.first < b.first : a.second < b.second;
                    });
          if (static_cast<int>(cand.size()) > deg) cand.resize(deg);
          for (const auto& c : cand) want[i].push_back(c.second);
        }
        std::vector<int> deg(L.size(), 0);
        for (std::size_t i = 0; i < L.size(); ++i)
          for (int j : want[i]) {
            if (static_cast<std::size_t>(j) < i) continue;          // each pair once
            const std::vector<int>& w = want[j];
            if (std::find(w.begin(), w.end(), static_cast<int>(i)) == w.end())
              continue;                                            // not mutual
            const std::size_t before = emitted.size();
            span(L[i].p, L[j].p, std::min(L[i].r, L[j].r));
            if (emitted.size() > before) {
              ++st.net_skin_members;
              st.net_skin_length_mm += vlen(vsub(L[j].p, L[i].p));
              ++deg[i];
              ++deg[j];
            }
          }
        // ★ THE FALLBACK, AND WHY IT IS NOT OPTIONAL. Mutual-nearest is what keeps a
        // crowded corner from growing a hairball, but it leaves the LONERS out: a
        // landing whose nearest neighbour already has closer friends is wanted by
        // nobody and stays hanging. Measured on the cube, the mutual pass alone joined
        // 489 of 648 landings and left 41 dead ends in the shipped mesh — every one of
        // them ON a face. So any landing still unjoined takes its single nearest
        // partner within twice the reach, mutual or not. One join is all a hanging
        // strut needs; the degree cap still bounds the crowded end.
        // ★ EVERY NODE NEEDS TWO. A net node with ONE join is a thread that just
        // stops — 839 of 2,173 on the cube (38.6 %), 64 % on the rim — and that is
        // what the surface dead-end count was reading. So the fallback runs while a
        // node is short of TWO, not merely while it has none.
        for (int want = 1; want <= 2; ++want)
         for (std::size_t i = 0; i < L.size(); ++i) {
          if (deg[i] >= want) continue;
          int best = -1;
          double bestd = 1.5 * reach;
          const auto k0 = lkey(L[i].p);
          for (long long dz = -2; dz <= 2; ++dz)
            for (long long dy = -2; dy <= 2; ++dy)
              for (long long dx = -2; dx <= 2; ++dx) {
                auto it = lb.find({k0[0] + dx, k0[1] + dy, k0[2] + dz});
                if (it == lb.end()) continue;
                for (int j : it->second) {
                  if (static_cast<std::size_t>(j) == i) continue;
                  const double d = vlen(vsub(L[j].p, L[i].p));
                  if (d < kOrganicFinishMinSpanRatio * reach || d >= bestd) continue;
                  if (already(L[i].p, L[j].p)) continue;
                  const Vec3 ni = sdf_normal(L[i].p, 2.0 * L[i].r);
                  const Vec3 nj = sdf_normal(L[j].p, 2.0 * L[j].r);
                  if (vlen(ni) > 0.5 && vlen(nj) > 0.5 &&
                      vdot(ni, nj) < kOrganicFinishCoplanarCos)
                    continue;
                  if (buried(L[i].p, L[j].p)) continue;
                  bestd = d;
                  best = j;
                }
              }
          if (best < 0) continue;
          const std::size_t before = emitted.size();
          span(L[i].p, L[best].p, std::min(L[i].r, L[best].r));
          if (emitted.size() > before) {
            ++st.net_skin_members;
            ++st.net_skin_fallback_members;
            st.net_skin_length_mm += bestd;
            ++deg[i];
            ++deg[best];
            joined_already.insert([&]{
              auto ka = pkey(L[i].p), kb = pkey(L[best].p);
              if (kb < ka) std::swap(ka, kb);
              return std::make_pair(ka, kb);
            }());
          }
        }
        for (std::size_t i = 0; i < L.size(); ++i) {
          if (deg[i] > 0) ++st.net_skin_landings_joined;
          if (deg[i] == 1) ++st.net_skin_degree_one;
        }
      }
    }

  // The finish must not introduce what the algorithm just removed. A join the
  // boundary clipped into a stub is pruned — but ONLY finish spans are eligible, so
  // this can never reach back into the structure above.
  {
    const std::size_t core_n = st.net_skin_members ? 0 : emitted.size();
    (void)core_n;
    alive.assign(emitted.size(), 1);
    rebuild();
    for (int round = 0; round < kOrganicPruneRounds; ++round) {
      std::vector<std::size_t> doomed;
      for (std::size_t i = 0; i < emitted.size(); ++i) {
        if (!alive[i] || emitted[i].src != Src::Net) continue;
        for (int e = 0; e < 2; ++e) {
          const Vec3 tip = e ? emitted[i].b : emitted[i].a;
          if (on_plate(tip, emitted[i].r) || tip_supported(i, tip, tip_dir(i, e)))
            continue;
          doomed.push_back(i);
          break;
        }
      }
      if (doomed.empty()) break;
      for (std::size_t i : doomed) {
        alive[i] = 0;
        ++st.net_skin_members_pruned;
      }
      rebuild();
    }
    std::vector<EmittedSeg> fkeep;
    fkeep.reserve(emitted.size());
    for (std::size_t i = 0; i < emitted.size(); ++i)
      if (alive[i]) fkeep.push_back(emitted[i]);
    emitted.swap(fkeep);
  }

  }

  // ── ★★ THE CENSUS, AT THE FIXED POINT AND NOWHERE ELSE ─────────────────────
  // Self-contained on purpose: it derives its own raster from the FINAL span list by
  // the same rule an outside probe would use, so it agrees with one BY CONSTRUCTION.
  // Sharing the repair loop's grid was wrong twice over — those bounds predate the
  // legs, and a number read mid-loop describes an intermediate state, not the file.
  if (!emitted.empty() && lat.layer_height_mm > 0.0) {
    double crmin = emitted.front().r;
    Vec3 clo = emitted.front().a, chi = emitted.front().a;
    for (const EmittedSeg& e : emitted) {
      crmin = std::min(crmin, e.r);
      for (const Vec3& p : {e.a, e.b}) {
        clo.x = std::min(clo.x, p.x - e.r); clo.y = std::min(clo.y, p.y - e.r);
        clo.z = std::min(clo.z, p.z - e.r);
        chi.x = std::max(chi.x, p.x + e.r); chi.y = std::max(chi.y, p.y + e.r);
        chi.z = std::max(chi.z, p.z + e.r);
      }
    }
    const double cxy = std::max(crmin, 1e-6), cz = lat.layer_height_mm;
    const int CX = static_cast<int>((chi.x - clo.x) / cxy) + 2;
    const int CY = static_cast<int>((chi.y - clo.y) / cxy) + 2;
    const int CZ = static_cast<int>((chi.z - clo.z) / cz) + 2;
    if (static_cast<long long>(CX) * CY * CZ <= 120000000LL) {
      auto ci = [CX, CY](int i, int j, int k) {
        return (static_cast<std::size_t>(k) * CY + j) * CX + i;
      };
      std::vector<unsigned char> co(static_cast<std::size_t>(CX) * CY * CZ, 0);
      for (const EmittedSeg& e : emitted) {
        const Vec3 ab = vsub(e.b, e.a);
        const double abab = vdot(ab, ab), r2 = e.r * e.r;
        const int i0 = std::max(0, int((std::min(e.a.x, e.b.x) - e.r - clo.x) / cxy) - 1);
        const int i1 = std::min(CX - 1, int((std::max(e.a.x, e.b.x) + e.r - clo.x) / cxy) + 1);
        const int j0 = std::max(0, int((std::min(e.a.y, e.b.y) - e.r - clo.y) / cxy) - 1);
        const int j1 = std::min(CY - 1, int((std::max(e.a.y, e.b.y) + e.r - clo.y) / cxy) + 1);
        const int k0 = std::max(0, int((std::min(e.a.z, e.b.z) - e.r - clo.z) / cz) - 1);
        const int k1 = std::min(CZ - 1, int((std::max(e.a.z, e.b.z) + e.r - clo.z) / cz) + 1);
        for (int k = k0; k <= k1; ++k)
          for (int j = j0; j <= j1; ++j)
            for (int i = i0; i <= i1; ++i) {
              bool hit = false;
              for (int sz = -1; sz <= 1 && !hit; sz += 2)
                for (int sy = -1; sy <= 1 && !hit; sy += 2)
                  for (int sx = -1; sx <= 1 && !hit; sx += 2) {
                    const Vec3 q{clo.x + (i + 0.5 + sx * 0.5) * cxy,
                                 clo.y + (j + 0.5 + sy * 0.5) * cxy,
                                 clo.z + (k + 0.5 + sz * 0.5) * cz};
                    const Vec3 ac = vsub(q, e.a);
                    double t = abab > 0.0 ? vdot(ac, ab) / abab : 0.0;
                    t = std::min(1.0, std::max(0.0, t));
                    const Vec3 d = vsub(ac, vmul(ab, t));
                    if (vdot(d, d) <= r2) hit = true;
                  }
              if (hit) co[ci(i, j, k)] = 1;
            }
      }
      int cg = -1;
      for (int k = 0; k < CZ && cg < 0; ++k)
        for (int j = 0; j < CY && cg < 0; ++j)
          for (int i = 0; i < CX; ++i)
            if (co[ci(i, j, k)]) { cg = k; break; }
      std::vector<int> cl(static_cast<std::size_t>(CX) * CY, 0);
      for (int k = cg + 1; k < CZ && cg >= 0; ++k) {
        std::fill(cl.begin(), cl.end(), 0);
        int nl = 0;
        for (int j = 0; j < CY; ++j)
          for (int i = 0; i < CX; ++i) {
            if (!co[ci(i, j, k)] || cl[static_cast<std::size_t>(j) * CX + i]) continue;
            ++nl;
            std::vector<std::pair<int,int>> stk{{i, j}}, cells;
            cl[static_cast<std::size_t>(j) * CX + i] = nl;
            while (!stk.empty()) {
              const std::pair<int,int> c = stk.back(); stk.pop_back();
              cells.push_back(c);
              for (int dj = -1; dj <= 1; ++dj)
                for (int di = -1; di <= 1; ++di) {
                  const int a2 = c.first + di, b2 = c.second + dj;
                  if (a2 < 0 || b2 < 0 || a2 >= CX || b2 >= CY) continue;
                  if (co[ci(a2, b2, k)] && !cl[static_cast<std::size_t>(b2) * CX + a2]) {
                    cl[static_cast<std::size_t>(b2) * CX + a2] = nl;
                    stk.push_back({a2, b2});
                  }
                }
            }
            bool sup = false;
            for (const std::pair<int,int>& c : cells) {
              for (int dj = -1; dj <= 1 && !sup; ++dj)
                for (int di = -1; di <= 1 && !sup; ++di) {
                  const int a2 = c.first + di, b2 = c.second + dj;
                  if (a2 < 0 || b2 < 0 || a2 >= CX || b2 >= CY) continue;
                  if (co[ci(a2, b2, k - 1)]) sup = true;
                }
              if (sup) break;
            }
            if (sup) continue;
            ++st.unsupported_islands_remaining;
            st.unsupported_cells_remaining += cells.size();
            st.unsupported_volume_mm3 +=
                static_cast<double>(cells.size()) * cxy * cxy * cz;
            if (std::getenv("TOPOPT_ORGANIC_SUPPORT_TRACE")) {
              double xs = 0.0, ys = 0.0;
              for (const std::pair<int,int>& c : cells) {
                xs += clo.x + (c.first + 0.5) * cxy;
                ys += clo.y + (c.second + 0.5) * cxy;
              }
              std::fprintf(stderr,
                  "[midair] region: %zu cells at z=%.3f mm, centre (%.2f, %.2f) mm\n",
                  cells.size(), clo.z + (k + 0.5) * cz,
                  xs / cells.size(), ys / cells.size());
            }
          }
      }
    } else {
      st.support_grid_too_large = true;
    }
  }


  // ── ★★ CONNECTEDNESS OF WHAT WAS WRITTEN (see OrganicGenStats). Same union-find
  // and the same exact segment-to-segment distance the tracer uses, run over the
  // POST-CLIP spans, so the number describes the file rather than the intent.
  if (!emitted.empty()) {
    double reach = 0.0;
    for (const EmittedSeg& e : emitted) reach = std::max(reach, e.len + 2.0 * e.r);
    const double cell = std::max(reach, 1e-6);
    const double reach_hint = reach;   // longest span + 2 radii: the local strut scale
    std::map<std::array<long long, 3>, std::vector<int>> bucket;
    auto key = [cell](const Vec3& p) {
      return std::array<long long, 3>{
          static_cast<long long>(std::floor(p.x / cell)),
          static_cast<long long>(std::floor(p.y / cell)),
          static_cast<long long>(std::floor(p.z / cell))};
    };
    for (std::size_t i = 0; i < emitted.size(); ++i)
      bucket[key(vmul(vadd(emitted[i].a, emitted[i].b), 0.5))]
          .push_back(static_cast<int>(i));
    // ── ★★ THE FREE-END CENSUS, ON THE FINAL LIST ────────────────────────────
    // Every pass that can add or remove a span has run. A tip is accounted for when it
    // lies inside another span's solid, or rests on the build plate (which supports
    // it). Anything else is a FREE END and is reported as one.
    {
      double zmin = emitted.front().a.z;
      for (const EmittedSeg& e : emitted) zmin = std::min(zmin, std::min(e.a.z, e.b.z));
      // ★ THE SAME TEST THE PRUNE USES, NOT A WEAKER ONE. It reported zero while the
      // shipped mesh still showed 19 dead ends, because it asked only whether anything
      // was there — and a bundle of struts co-terminating at one point satisfies that
      // about each other. A census must not be easier to pass than the pass it audits.
      auto supported = [&](std::size_t i, const Vec3& tip, const Vec3& out) {
        const auto k0 = key(tip);
        for (long long dz = -1; dz <= 1; ++dz)
          for (long long dy = -1; dy <= 1; ++dy)
            for (long long dx = -1; dx <= 1; ++dx) {
              auto it = bucket.find({k0[0] + dx, k0[1] + dy, k0[2] + dz});
              if (it == bucket.end()) continue;
              for (int j : it->second) {
                if (static_cast<std::size_t>(j) == i) continue;
                const EmittedSeg& e2 = emitted[j];
                const Vec3 ab = vsub(e2.b, e2.a);
                const double abab = vdot(ab, ab);
                double t = abab > 0.0 ? vdot(vsub(tip, e2.a), ab) / abab : 0.0;
                t = std::min(1.0, std::max(0.0, t));
                const Vec3 q = vadd(e2.a, vmul(ab, t));
                if (vdot(vsub(q, tip), vsub(q, tip)) > e2.r * e2.r) continue;
                const double da = vlen(vsub(q, e2.a)), db = vlen(vsub(q, e2.b));
                if (da > 0.5 * e2.r && db > 0.5 * e2.r) return true;
                const Vec3 away = vsub((da <= db) ? e2.b : e2.a, tip);
                const double an = vlen(away);
                if (!(an > 1e-9)) continue;
                if (vdot(vmul(away, 1.0 / an), out) > kOrganicFoldBackCos) return true;
              }
            }
        return false;
      };
      for (std::size_t i = 0; i < emitted.size(); ++i)
        for (int e = 0; e < 2; ++e) {
          const Vec3 tip = e ? emitted[i].b : emitted[i].a;
          const Vec3 d = e ? vsub(emitted[i].b, emitted[i].a)
                           : vsub(emitted[i].a, emitted[i].b);
          const double dn = vlen(d);
          const Vec3 out = dn > 1e-9 ? vmul(d, 1.0 / dn) : Vec3{0.0, 0.0, 1.0};
          if (supported(i, tip, out)) continue;
          if (tip.z - zmin <= emitted[i].r) { ++st.plate_contacts; continue; }
          ++st.free_ends;
          st.free_end_length_mm += emitted[i].len;
        }
    }

    std::vector<int> par(emitted.size());
    for (std::size_t i = 0; i < par.size(); ++i) par[i] = static_cast<int>(i);
    std::function<int(int)> find = [&par](int a) {
      while (par[a] != a) { par[a] = par[par[a]]; a = par[a]; }
      return a;
    };
    for (const auto& kv : bucket)
      for (long long dz = -1; dz <= 1; ++dz)
        for (long long dy = -1; dy <= 1; ++dy)
          for (long long dx = -1; dx <= 1; ++dx) {
            auto it = bucket.find({kv.first[0] + dx, kv.first[1] + dy,
                                   kv.first[2] + dz});
            if (it == bucket.end()) continue;
            for (int i : kv.second)
              for (int j : it->second) {
                if (j <= i) continue;
                const double touch = emitted[i].r + emitted[j].r;
                if (organic_segment_distance2(emitted[i].a, emitted[i].b,
                                              emitted[j].a, emitted[j].b) >
                    touch * touch)
                  continue;
                const int ra = find(i), rb = find(j);
                if (ra != rb) par[std::max(ra, rb)] = std::min(ra, rb);
              }
          }
    std::map<int, double> comp;
    double total = 0.0;
    for (std::size_t i = 0; i < emitted.size(); ++i) {
      comp[find(static_cast<int>(i))] += emitted[i].len;
      total += emitted[i].len;
    }
    st.emitted_components = comp.size();
    double biggest = 0.0;
    for (const auto& kv : comp) biggest = std::max(biggest, kv.second);
    st.emitted_largest_length_fraction = total > 0.0 ? biggest / total : 0.0;
    st.emitted_stranded_length_mm = total - biggest;
  }
  // ── ★★ EMISSION, ONCE, OVER THE FINAL LIST ──────────────────────────────────
  // Node-ball dedup is decided HERE rather than at record time: a polyline's interior
  // vertex is one span's end and the next span's start, so a ball goes at `a` only
  // when the previously emitted span did not already end there. Deciding it at
  // emission is also what keeps it correct after a prune, which can break a run in
  // the middle and turn an interior vertex back into a genuine end.
  {
    Vec3 last_b{0, 0, 0};
    bool have_last = false;
    for (const EmittedSeg& e : emitted) {
      lattice_emit_strut(sink, e.a, e.b, e.r, nseg);
      if (obs && obs->on_element)
        obs->on_element(LatticeGenElement::InteriorStrut, e.a, e.b, e.r);
      st.triangles += static_cast<std::uint64_t>(4 * nseg);
      ++st.struts;
      st.volume_mm3 += lattice_prism_volume_mm3(e.r, e.len, nseg);
      if (!have_last || !same_point(last_b, e.a)) emit_node_once(e.a, e.r);
      emit_node_once(e.b, e.r);
      have_last = true;
      last_b = e.b;
      note(2.0 * e.r);
      if (e.anchor0) { ++st.anchor_nodes; st.skin_triangles += 20; }
      if (e.anchor1) { ++st.anchor_nodes; st.skin_triangles += 20; }
    }
  }
  // ★ THE DUMP. Env-gated, off in production, and it writes the FINAL list — the same
  // one the emission loop above walked — so a coordinate in this file is a coordinate
  // in the STL.
  if (const char* dp = std::getenv("TOPOPT_ORGANIC_SPAN_DUMP")) {
    if (FILE* f = std::fopen(dp, "w")) {
      std::fprintf(f, "# src ax ay az bx by bz r anchor0 anchor1\n");
      const char* nm[6] = {"curve", "connector", "tie", "net", "leg", "fill"};
      for (const EmittedSeg& e : emitted)
        std::fprintf(f, "%s %.4f %.4f %.4f %.4f %.4f %.4f %.4f %d %d\n",
                     nm[static_cast<int>(e.src)], e.a.x, e.a.y, e.a.z, e.b.x, e.b.y,
                     e.b.z, e.r, e.anchor0 ? 1 : 0, e.anchor1 ? 1 : 0);
      std::fclose(f);
    }
  }
  if (emitted_out) {
    emitted_out->clear();
    emitted_out->reserve(emitted.size());
    for (const EmittedSeg& e : emitted) emitted_out->push_back({e.a, e.b, e.r});
  }
  return st;
}


// ────────────────────────────────────────────────────────────────────────────────
TriangleMesh organic_weld(const std::vector<OrganicSpan>& spans, double pitch_mm,
                          long long max_voxels, OrganicWeldStats& stats,
                          double floor_z) {
  stats = OrganicWeldStats{};
  if (spans.empty()) return TriangleMesh{};
  Vec3 lo = spans.front().a, hi = spans.front().a;
  double rmin = spans.front().r, rmax = spans.front().r;
  for (const OrganicSpan& sp : spans) {
    for (const Vec3& p : {sp.a, sp.b}) {
      lo.x = std::min(lo.x, p.x - sp.r); lo.y = std::min(lo.y, p.y - sp.r);
      lo.z = std::min(lo.z, p.z - sp.r);
      hi.x = std::max(hi.x, p.x + sp.r); hi.y = std::max(hi.y, p.y + sp.r);
      hi.z = std::max(hi.z, p.z + sp.r);
    }
    rmin = std::min(rmin, sp.r);
    rmax = std::max(rmax, sp.r);
  }
  // A quarter of the THINNEST strut's diameter resolves it; anything coarser aliases
  // the very struts the grade is expressed in.
  double pitch = pitch_mm > 0.0 ? pitch_mm : 0.5 * rmin;
  if (!(pitch > 0.0)) return TriangleMesh{};
  // One voxel of margin all round so marching cubes can close the surface.
  auto dims = [&](double p, int& nx, int& ny, int& nz) {
    nx = static_cast<int>(std::ceil((hi.x - lo.x) / p)) + 3;
    ny = static_cast<int>(std::ceil((hi.y - lo.y) / p)) + 3;
    nz = static_cast<int>(std::ceil((hi.z - lo.z) / p)) + 3;
  };
  int nx = 0, ny = 0, nz = 0;
  dims(pitch, nx, ny, nz);
  while (max_voxels > 0 &&
         static_cast<long long>(nx) * ny * nz > max_voxels) {
    pitch *= 1.25;   // fixed ratio, so the coarsening is reproducible
    dims(pitch, nx, ny, nz);
  }
  const Vec3 origin{lo.x - pitch, lo.y - pitch, lo.z - pitch};
  std::vector<double> field(static_cast<std::size_t>(nx) * ny * nz, 0.0);
  auto idx = [nx, ny](int i, int j, int k) {
    return (static_cast<std::size_t>(k) * ny + j) * nx + i;
  };
  // Rasterise each capsule exactly: over its bounding box, mark every voxel whose
  // CENTRE is within r of the segment. Exact test, fixed traversal, no sampling.
  for (const OrganicSpan& sp : spans) {
    const int i0 = std::max(0, static_cast<int>(std::floor(
        (std::min(sp.a.x, sp.b.x) - sp.r - origin.x) / pitch)));
    const int i1 = std::min(nx - 1, static_cast<int>(std::ceil(
        (std::max(sp.a.x, sp.b.x) + sp.r - origin.x) / pitch)));
    const int j0 = std::max(0, static_cast<int>(std::floor(
        (std::min(sp.a.y, sp.b.y) - sp.r - origin.y) / pitch)));
    const int j1 = std::min(ny - 1, static_cast<int>(std::ceil(
        (std::max(sp.a.y, sp.b.y) + sp.r - origin.y) / pitch)));
    const int k0 = std::max(0, static_cast<int>(std::floor(
        (std::min(sp.a.z, sp.b.z) - sp.r - origin.z) / pitch)));
    const int k1 = std::min(nz - 1, static_cast<int>(std::ceil(
        (std::max(sp.a.z, sp.b.z) + sp.r - origin.z) / pitch)));
    const double r2 = sp.r * sp.r;
    const Vec3 ab = vsub(sp.b, sp.a);
    const double abab = vdot(ab, ab);
    for (int k = k0; k <= k1; ++k)
      for (int j = j0; j <= j1; ++j)
        for (int i = i0; i <= i1; ++i) {
          const Vec3 c{origin.x + (i + 0.5) * pitch, origin.y + (j + 0.5) * pitch,
                       origin.z + (k + 0.5) * pitch};
          const Vec3 ac = vsub(c, sp.a);
          double t = abab > 0.0 ? vdot(ac, ab) / abab : 0.0;
          t = std::min(1.0, std::max(0.0, t));
          const Vec3 d = vsub(ac, vmul(ab, t));
          if (vdot(d, d) <= r2) field[idx(i, j, k)] = 1.0;
        }
  }
  // ── ★★ A FLAT BASE, CUT ON THE SOLID ────────────────────────────────────────
  // ★ A CENTRELINE TRIM CANNOT PRODUCE A FLAT FACE. Clipping a span at a plane leaves
  // the capsule's hemispherical CAP hanging a full radius beneath it, and the caps are
  // exactly the scattered dots the trim exists to remove: measured on the cube, the
  // base plane sat at z = 0.568 mm and material still reached z = 0.064 — 0.5 mm below
  // it, which is rmax. The cut has to be applied to the SOLID, which is here.
  if (floor_z > -1e29) {
    for (int k = 0; k < nz; ++k) {
      const double cz = origin.z + (k + 0.5) * pitch;
      if (cz >= floor_z) continue;
      for (int j = 0; j < ny; ++j)
        for (int i = 0; i < nx; ++i) field[idx(i, j, k)] = 0.0;
    }
  }
  long long occ = 0;
  for (double v : field) if (v > 0.5) ++occ;
  TriangleMesh welded = marching_cubes(nx, ny, nz, pitch, origin, field, 0.5);
  stats.components_before = count_components(welded);
  welded = keep_largest_component(welded);
  stats.components_after = count_components(welded);
  stats.sealed_cavities_filled = stats.components_before - stats.components_after;
  const WatertightReport wt = check_watertight(welded);
  stats.watertight = wt.watertight;
  stats.pitch_mm = pitch;
  stats.nx = nx; stats.ny = ny; stats.nz = nz;
  stats.occupied_voxels = occ;
  stats.triangles = welded.triangles.size();
  // ★ THE TRUE UNION VOLUME — overlaps DEDUCTED, unlike every soup-basis figure this
  // codebase reports. This is the number that is comparable to a welded coupon's.
  stats.volume_mm3 = std::fabs(signed_volume(welded));
  return welded;
}

}  // namespace topopt
