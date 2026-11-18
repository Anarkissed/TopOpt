// Lattice rebuild, Organic stage 1b: the owner's Traced placement through the new engine (O3, O4).
// See lattice_layout_organic.hpp. The old tracer is called as it is and nothing after it in the old path.
#include "topopt/lattice_layout_organic.hpp"

#include <algorithm>
#include <array>
#include <map>
#include <chrono>
#include <cmath>
#include <limits>
#include <memory>
#include <stdexcept>
#include <tuple>

#include "topopt/grading.hpp"
#include "topopt/lattice.hpp"
#include "topopt/organic_lattice.hpp"
#include "topopt/voxel.hpp"

namespace topopt::lattice_layout {
namespace {

double dist(const Vec3& a, const Vec3& b) {
  return std::sqrt((a.x - b.x) * (a.x - b.x) + (a.y - b.y) * (a.y - b.y) + (a.z - b.z) * (a.z - b.z));
}
double to_segment(const Vec3& p, const Vec3& a, const Vec3& b) {
  const Vec3 d{b.x - a.x, b.y - a.y, b.z - a.z};
  const double l2 = d.x * d.x + d.y * d.y + d.z * d.z;
  const double t =
      l2 > 0.0 ? std::clamp(((p.x - a.x) * d.x + (p.y - a.y) * d.y + (p.z - a.z) * d.z) / l2, 0.0, 1.0) : 0.0;
  return dist(p, Vec3{a.x + d.x * t, a.y + d.y * t, a.z + d.z * t});
}

// O4: a strand's free end, run on along its own last segment (from `from` through `end`) by at most one spacing, to
// the edge of the region's lattice: read every twentieth of a millimetre from the end itself, then the edge found to
// a millionth of a millimetre. The end is moved to the edge; where the part's solid lies past it, on by its own width
// more (S11), so that weave_bars, whose end function (finish_bar_ends) tags it, finds it Solid with its run-in made.
// Past the edge the part's surface (Surface: on the surface) or another region's lattice (Loose) leaves it at the
// edge. With no edge within one spacing the end is left where it is. The end never leaves the part.
void run_on(const Domain::Probe& probe, int region, const Vec3& from, Vec3& end, double width, double spacing) {
  const double len = dist(from, end);
  if (!(len > 0.0) || !(spacing > 0.0)) return;
  const Vec3 d{(end.x - from.x) / len, (end.y - from.y) / len, (end.z - from.z) / len};
  auto at = [&](double s) { return Vec3{end.x + d.x * s, end.y + d.y * s, end.z + d.z * s}; };
  auto held = [&](double s) {
    const Where w = probe.where(at(s));
    return w.lattice() && w.id == region;
  };
  constexpr double kRead = 0.05;   // mm
  const int steps = static_cast<int>(std::floor(spacing / kRead + 1e-9));
  for (int k = 0; k <= steps; ++k) {
    const double s = k * kRead;
    if (held(s)) continue;
    if (k == 0) return;   // the end is already past the edge: weave_bars cuts it there
    double in = s - kRead, out = s;
    while (out - in > 1e-6) {
      const double m = 0.5 * (in + out);
      if (held(m)) in = m; else out = m;
    }
    const Where past = probe.where(at(in + 3.0 * 0.02));   // as finish_bar_ends reads past an end
    const bool solid = past.why != Why::Outside && !past.lattice();
    end = at(solid ? in + width : in);
    return;
  }
}

}  // namespace

bool TensorField::empty() const {
  const std::size_t n = static_cast<std::size_t>(std::max(0, nx)) * static_cast<std::size_t>(std::max(0, ny)) *
                        static_cast<std::size_t>(std::max(0, nz));
  return n == 0 || !(spacing > 0.0) || voigt.size() != 6 * n;
}

std::vector<std::size_t> straighten_points(const std::vector<Vec3>& points, double tolerance_mm) {
  const std::size_t n = points.size();
  std::vector<std::size_t> kept;
  if (n <= 2) {
    for (std::size_t i = 0; i < n; ++i) kept.push_back(i);
    return kept;
  }
  // The fewest points: the shortest chain from the first point to the last, where i -> j is allowed when every point
  // between them lies within the tolerance of the straight line from i to j. Each point's best is taken from the
  // lowest i that gives it, so the answer is fixed.
  const std::size_t none = std::numeric_limits<std::size_t>::max();
  std::vector<std::size_t> count(n, none), prev(n, none);
  count[0] = 0;
  for (std::size_t j = 1; j < n; ++j)
    for (std::size_t i = 0; i < j; ++i) {
      if (count[i] == none || count[i] + 1 >= count[j]) continue;
      bool fits = true;
      for (std::size_t k = i + 1; k < j && fits; ++k) fits = to_segment(points[k], points[i], points[j]) <= tolerance_mm;
      if (!fits) continue;
      count[j] = count[i] + 1;
      prev[j] = i;
    }
  for (std::size_t j = n - 1; j != none; j = prev[j]) kept.push_back(j);
  std::reverse(kept.begin(), kept.end());
  return kept;
}

// O12 and O13: the old run's own spacing field for an ordinary Traced job (run_job.cpp, run_organic_step, with a cell
// window; its density from grade_lattice, Aesthetic intent). What the old run does, step by step:
//   1. grade_lattice gives each latticed voxel rho = lo + (hi - lo) * u^(g * w), u = von Mises / the 95th percentile
//      of the region's von Mises held to 0 .. 1, g the job's demand_exponent, w = 2 (on the geometry path w is always 2;
//      on the analyze path it follows minimize_plastic: 2 on, 0.5 off); lo and hi the aesthetic band (2 x octet's
//      rho_min and its rho_max), inside the certifiable band, so no clamp acts.
//   2. run_organic_step stretches it over the latticed voxels, f = (rho - rho_lo) / (rho_hi - rho_lo) (0 when they are
//      equal), f = f^e with e = 2 (minimize_plastic on) or 0.5 (off), and d = cell_max - (cell_max - cell_min) * f. The
//      band ends lo and hi cancel in that stretch, so no material number is needed: f = ((g - g_lo) / span)^2 with
//      g = u^(2 g). Here both exponents are 2, fixed (minimize_plastic on, the app's default; the owner's rule is that
//      minimize_plastic has no bearing on the lattice).
//   3. The floors: a voxel is traced only where rho > 0 and d > 0 (always, here); the shape fit never goes under
//      cell_min; the tracer raises the spacing to its print floor (0.5 t sqrt(3 pi)) and to one voxel, as it does here.
//   4. Shape fit (grading.organic_shape_fit, on unless the job turns it off), see the header: cap = min(W / N*, 2 k h),
//      held to cell_min, and the spacing takes the cap where it is smaller.
// Where it is not the old run: a whole-synthesised wall takes the window's middle there (there is no made-up stress
// on this path); a stated reference (reference_mpa) replaces the percentile (the old run has no such key).
// Structural (not built here): rho = rho_max * (s / s_max)^g (s_max the region's highest von Mises, not a percentile)
// held to octet's band [rho_min, rho_max], so every voxel under (rho_min / rho_max)^(1/g) of the peak sits at rho_min,
// the widest end; then the same stretch and exponent e.
namespace {
// O12, O13 as before (with L1); `solid`, when given, receives per voxel: 1 inside the part and lattice of no region,
// 2 inside and lattice of a region, 0 outside.
OrganicSpacing spacing_core(const Domain& domain, int region, const TensorField& field, const OrganicAsk& ask,
                            std::vector<char>* solid) {
  OrganicSpacing out;
  if (field.empty()) return out;
  if (ask.spacing_mm != 0.0 && !(ask.spacing_mm > 0.0 && std::isfinite(ask.spacing_mm)))
    throw std::invalid_argument("organic_spacing: spacing_mm must be above 0 (or 0 for the range)");
  const bool one = ask.spacing_mm > 0.0;
  const double lo = one ? ask.spacing_mm : ask.spacing_min_mm, hi = one ? ask.spacing_mm : ask.spacing_max_mm;
  if (!one && !(lo > 0.0 && std::isfinite(lo)))
    throw std::invalid_argument("organic_spacing: spacing_min_mm must be above 0");
  if (!one && !(hi >= lo && std::isfinite(hi)))
    throw std::invalid_argument("organic_spacing: spacing_max_mm must be at least spacing_min_mm");
  if (!one && !(ask.spacing_exponent > 0.0 && std::isfinite(ask.spacing_exponent)))
    throw std::invalid_argument("organic_spacing: spacing_exponent must be above 0");
  const std::size_t n = static_cast<std::size_t>(field.nx) * field.ny * field.nz;
  out.candidate.assign(n, 0);
  out.spacing_mm.assign(n, 0.0);
  out.stress_f.assign(n, 0.0);   // M
  if (solid) solid->assign(n, 0);
  std::vector<char> weave_ids;   // by region id: is it a weave region
  for (const Region& r : domain.spec().regions)
    if (r.role == Role::Lattice && r.weave && r.id >= 0) {
      if (static_cast<std::size_t>(r.id) >= weave_ids.size()) weave_ids.resize(static_cast<std::size_t>(r.id) + 1, 0);
      weave_ids[static_cast<std::size_t>(r.id)] = 1;
    }
  const Domain::Probe probe = domain.probe();
  std::vector<double> vm(n, 0.0);
  std::vector<char> weave(n, 0), in_part(n, 0);
  std::vector<double> seen;
  for (int k = 0; k < field.nz; ++k)
    for (int j = 0; j < field.ny; ++j)
      for (int i = 0; i < field.nx; ++i) {
        const Vec3 c{field.origin.x + (i + 0.5) * field.spacing, field.origin.y + (j + 0.5) * field.spacing,
                     field.origin.z + (k + 0.5) * field.spacing};
        const Where w = probe.where(c);
        const std::size_t e = field.index(i, j, k);
        in_part[e] = w.why != Why::Outside;
        if (solid) (*solid)[e] = in_part[e] ? (w.lattice() ? 2 : 1) : 0;   // L2: 1 solid, 2 lattice of a region, 0 outside
        const bool of_weave = w.lattice() && (w.id == region || (w.id >= 0 && static_cast<std::size_t>(w.id) <
                                                                                     weave_ids.size() &&
                                                                 weave_ids[static_cast<std::size_t>(w.id)]));
        if (!of_weave) continue;
        weave[e] = 1;
        const double* t = &field.voigt[6 * e];
        const double a = t[0] - t[1], b = t[1] - t[2], d = t[2] - t[0];
        vm[e] = std::sqrt(std::max(0.0, 0.5 * (a * a + b * b + d * d) + 3.0 * (t[3] * t[3] + t[4] * t[4] + t[5] * t[5])));
        seen.push_back(vm[e]);
        if (w.id != region) continue;
        out.candidate[e] = 1;
        ++out.candidates;
      }
  if (out.candidates == 0) return out;
  if (one || hi == lo) {
    for (std::size_t e = 0; e < n; ++e)
      if (out.candidate[e]) out.spacing_mm[e] = lo;
    return out;
  }
  // O12: the reference, then g per weave voxel and its least and greatest over the weave.
  double ref = ask.reference_mpa;
  if (!(ref > 0.0)) {
    std::sort(seen.begin(), seen.end());
    const double q = std::clamp(ask.percentile, 0.0, 1.0);
    ref = seen[static_cast<std::size_t>(std::floor(q * static_cast<double>(seen.size() - 1)))];
  }
  out.reference_mpa = ref;
  const double g_exp = ask.spacing_exponent * kAestheticOpenExponent;   // the grading law's u^(g * w)
  std::vector<double> g(n, 0.0);
  double g_lo = 0.0, g_hi = 0.0;
  bool any = false;
  for (std::size_t e = 0; e < n; ++e) {
    if (!weave[e]) continue;
    const double u = grading_demand_fraction(GradingIntent::Aesthetic, vm[e], ref, 1.0);
    g[e] = std::pow(u, g_exp);
    g_lo = any ? std::min(g_lo, g[e]) : g[e];
    g_hi = any ? std::max(g_hi, g[e]) : g[e];
    any = true;
  }
  const double span = g_hi - g_lo;
  for (std::size_t e = 0; e < n; ++e) {
    if (!out.candidate[e]) continue;
    double f = span > 0.0 ? (g[e] - g_lo) / span : 0.0;
    f = std::pow(std::min(1.0, std::max(0.0, f)), kAestheticOpenExponent);   // run_organic_step's f_exponent, on
    out.spacing_mm[e] = hi - (hi - lo) * f;
    out.stress_f[e] = f;   // M: O12's measure, kept
  }
  if (!ask.shape_fit) return out;
  // O13: the steps to the weave's outline (two passes over the faces' neighbours; a voxel on the grid's face is one
  // step from it), and the part's member width.
  const int nx = field.nx, ny = field.ny, nz = field.nz;
  const long long big = 1LL << 30;
  std::vector<long long> steps(n, big);
  for (int k = 0; k < nz; ++k)
    for (int j = 0; j < ny; ++j)
      for (int i = 0; i < nx; ++i) {
        const std::size_t e = field.index(i, j, k);
        if (!weave[e]) steps[e] = 0;
        else if (i == 0 || j == 0 || k == 0 || i == nx - 1 || j == ny - 1 || k == nz - 1) steps[e] = 1;
      }
  for (int k = 0; k < nz; ++k)
    for (int j = 0; j < ny; ++j)
      for (int i = 0; i < nx; ++i) {
        const std::size_t e = field.index(i, j, k);
        if (i) steps[e] = std::min(steps[e], steps[field.index(i - 1, j, k)] + 1);
        if (j) steps[e] = std::min(steps[e], steps[field.index(i, j - 1, k)] + 1);
        if (k) steps[e] = std::min(steps[e], steps[field.index(i, j, k - 1)] + 1);
      }
  for (int k = nz - 1; k >= 0; --k)
    for (int j = ny - 1; j >= 0; --j)
      for (int i = nx - 1; i >= 0; --i) {
        const std::size_t e = field.index(i, j, k);
        if (i + 1 < nx) steps[e] = std::min(steps[e], steps[field.index(i + 1, j, k)] + 1);
        if (j + 1 < ny) steps[e] = std::min(steps[e], steps[field.index(i, j + 1, k)] + 1);
        if (k + 1 < nz) steps[e] = std::min(steps[e], steps[field.index(i, j, k + 1)] + 1);
      }
  VoxelGrid grid;
  grid.nx = nx;
  grid.ny = ny;
  grid.nz = nz;
  grid.spacing = field.spacing;
  grid.origin = field.origin;
  grid.tags.assign(n, VoxelTag::Interior);
  std::vector<double> part(n, 0.0);
  for (std::size_t e = 0; e < n; ++e) part[e] = in_part[e] ? 1.0 : 0.0;
  const std::vector<double> width = local_member_thickness_mm(grid, part, 0.5, 32);
  const double n_star = lattice_cells_per_member_min(LatticeTopology::Octet);
  for (std::size_t e = 0; e < n; ++e) {
    if (!out.candidate[e]) continue;
    const double w = width[e];
    const double cap_member = (w > 0.0 && std::isfinite(w)) ? w / n_star : std::numeric_limits<double>::infinity();
    // L1: Grade to shape as a variable (shape_reach 1: as before; 0: no outline cap).
    const double cap_outline = ask.shape_reach > 0.0 ? (2.0 / ask.shape_reach) * static_cast<double>(steps[e]) * field.spacing
                                                     : std::numeric_limits<double>::infinity();
    double cap = ask.member_cap ? std::min(cap_member, cap_outline) : cap_outline;   // J1
    if (cap < lo) cap = lo;
    if (!(cap > 0.0) || !(cap < out.spacing_mm[e])) continue;
    out.spacing_mm[e] = cap;
    ++out.shape_fit_tightened;
  }
  return out;
}
}  // namespace

OrganicSpacing organic_spacing(const Domain& domain, int region, const TensorField& field, const OrganicAsk& ask) {
  if (!ask.hold_parts) return spacing_core(domain, region, field, ask, nullptr);
  std::vector<char> solid;
  OrganicSpacing out = spacing_core(domain, region, field, ask, &solid);
  if (out.candidates == 0) return out;
  // L2 a (brief G15): the FLOATING PIECES, layer by layer from the bed, for the whole part (+z is up: the file job's
  // build direction). Solid = inside the part and lattice of no region. In the lowest layer holding any voxel of the
  // part every solid voxel is grounded; in each layer above, the solid voxels fall into groups (touching by a side or
  // a corner within the layer), and a group is grounded when any of its voxels has a grounded solid voxel among the 9
  // of the layer below. Floating = solid and not grounded; floating voxels touching in any way (26) are one piece; a
  // piece under 20 mm3 is ignored (counted). Per kept piece, against THIS region's candidates: its underside (voxels
  // with a candidate straight below) and its sides (voxels with a candidate beside them in the same layer, 4 sides).
  const int nx = field.nx, ny = field.ny, nz = field.nz;
  const double h = field.spacing;
  const std::size_t n = solid.size();
  std::vector<char> in_part(n, 0);
  for (std::size_t e = 0; e < n; ++e) { in_part[e] = solid[e] != 0; solid[e] = solid[e] == 1; }
  std::vector<char> grounded(n, 0);
  {
    int k0 = -1;
    for (int k = 0; k < nz && k0 < 0; ++k)
      for (int j = 0; j < ny && k0 < 0; ++j)
        for (int i = 0; i < nx && k0 < 0; ++i)
          if (in_part[field.index(i, j, k)]) k0 = k;
    if (k0 >= 0) {
      for (int j = 0; j < ny; ++j)
        for (int i = 0; i < nx; ++i) grounded[field.index(i, j, k0)] = solid[field.index(i, j, k0)];
      std::vector<int> group(static_cast<std::size_t>(nx) * ny, -1);
      std::vector<std::array<int, 2>> stack;
      for (int k = k0 + 1; k < nz; ++k) {
        std::fill(group.begin(), group.end(), -1);
        int groups = 0;
        for (int j = 0; j < ny; ++j)
          for (int i = 0; i < nx; ++i) {
            if (!solid[field.index(i, j, k)] || group[static_cast<std::size_t>(j) * nx + i] >= 0) continue;
            std::vector<std::array<int, 2>> members;
            bool held = false;
            stack.assign(1, {i, j});
            group[static_cast<std::size_t>(j) * nx + i] = groups;
            while (!stack.empty()) {
              const std::array<int, 2> c = stack.back();
              stack.pop_back();
              members.push_back(c);
              for (int dj = -1; dj <= 1; ++dj)
                for (int di = -1; di <= 1; ++di) {
                  const int a = c[0] + di, bb = c[1] + dj;
                  if (a < 0 || bb < 0 || a >= nx || bb >= ny) continue;
                  if (!held && grounded[field.index(a, bb, k - 1)]) held = true;
                  if (!solid[field.index(a, bb, k)] || group[static_cast<std::size_t>(bb) * nx + a] >= 0) continue;
                  group[static_cast<std::size_t>(bb) * nx + a] = groups;
                  stack.push_back({a, bb});
                }
            }
            if (held)
              for (const auto& c : members) grounded[field.index(c[0], c[1], k)] = 1;
            ++groups;
          }
      }
    }
  }
  std::vector<char> seen(n, 0);
  for (int k = 0; k < nz; ++k)
    for (int j = 0; j < ny; ++j)
      for (int i = 0; i < nx; ++i) {
        const std::size_t e0 = field.index(i, j, k);
        if (!solid[e0] || grounded[e0] || seen[e0]) continue;
        std::vector<std::array<int, 3>> stack{{i, j, k}}, all;
        seen[e0] = 1;
        while (!stack.empty()) {
          const std::array<int, 3> c = stack.back();
          stack.pop_back();
          all.push_back(c);
          for (int dk = -1; dk <= 1; ++dk)
            for (int dj = -1; dj <= 1; ++dj)
              for (int di = -1; di <= 1; ++di) {
                const int a = c[0] + di, bb = c[1] + dj, cc = c[2] + dk;
                if (a < 0 || bb < 0 || cc < 0 || a >= nx || bb >= ny || cc >= nz) continue;
                const std::size_t f = field.index(a, bb, cc);
                if (!solid[f] || grounded[f] || seen[f]) continue;
                seen[f] = 1;
                stack.push_back({a, bb, cc});
              }
        }
        const double volume = static_cast<double>(all.size()) * h * h * h;
        if (volume < 20.0) { ++out.hold_small_patches; continue; }
        std::sort(all.begin(), all.end(), [](const std::array<int, 3>& p, const std::array<int, 3>& q) {
          return std::make_tuple(p[2], p[0], p[1]) < std::make_tuple(q[2], q[0], q[1]);
        });
        OrganicSpacing::HoldPatch P;
        P.volume_mm3 = volume;
        P.lo = {1e300, 1e300, 1e300};
        P.hi = {-1e300, -1e300, -1e300};
        for (const auto& c : all) {
          const Vec3 lo{field.origin.x + c[0] * h, field.origin.y + c[1] * h, field.origin.z + c[2] * h};
          P.centres.push_back({lo.x + 0.5 * h, lo.y + 0.5 * h, lo.z + 0.5 * h});
          out.hold_centres.push_back(P.centres.back());
          P.lo = {std::min(P.lo.x, lo.x), std::min(P.lo.y, lo.y), std::min(P.lo.z, lo.z)};
          P.hi = {std::max(P.hi.x, lo.x + h), std::max(P.hi.y, lo.y + h), std::max(P.hi.z, lo.z + h)};
          if (c[2] > 0 && out.candidate[field.index(c[0], c[1], c[2] - 1)]) {
            P.bottoms.push_back({lo.x + 0.5 * h, lo.y + 0.5 * h, lo.z});
            P.plan_mm2 += h * h;
          }
          bool side = false;
          for (const auto& d : {std::array<int, 2>{1, 0}, std::array<int, 2>{-1, 0}, std::array<int, 2>{0, 1}, std::array<int, 2>{0, -1}}) {
            const int a = c[0] + d[0], bb = c[1] + d[1];
            if (a >= 0 && bb >= 0 && a < nx && bb < ny && out.candidate[field.index(a, bb, c[2])]) side = true;
          }
          if (side) { P.sides.push_back(P.centres.back()); P.side_mm2 += h * h; }
        }
        out.hold_patches.push_back(std::move(P));
      }
  // L2 b: every candidate within part_reach_mm of the centre of ANY voxel of a kept piece takes the tightest spacing
  // (a candidate is counted for the first piece that reaches it).
  out.hold_reach_mm = ask.part_reach_mm;
  const bool one = ask.spacing_mm > 0.0;
  const double tight = one ? ask.spacing_mm : ask.spacing_min_mm;
  const double R = ask.part_reach_mm, R2 = R * R;
  const int r = static_cast<int>(std::ceil(R / h));
  std::vector<char> zone(n, 0);
  for (OrganicSpacing::HoldPatch& P : out.hold_patches)
    for (const Vec3& c : P.centres) {
      const int ci = static_cast<int>(std::floor((c.x - field.origin.x) / h)), cj = static_cast<int>(std::floor((c.y - field.origin.y) / h)),
                ck = static_cast<int>(std::floor((c.z - field.origin.z) / h));
      for (int k = std::max(0, ck - r); k <= std::min(nz - 1, ck + r); ++k)
        for (int j = std::max(0, cj - r); j <= std::min(ny - 1, cj + r); ++j)
          for (int i = std::max(0, ci - r); i <= std::min(nx - 1, ci + r); ++i) {
            const std::size_t e = field.index(i, j, k);
            if (!out.candidate[e] || zone[e]) continue;
            const double dx = field.origin.x + (i + 0.5) * h - c.x, dy = field.origin.y + (j + 0.5) * h - c.y,
                         dz = field.origin.z + (k + 0.5) * h - c.z;
            if (dx * dx + dy * dy + dz * dz > R2) continue;
            zone[e] = 1;
            ++out.hold_zone;
            ++P.zone;
            if (out.spacing_mm[e] > tight) { out.spacing_mm[e] = tight; ++out.hold_tightened; ++P.tightened; }
          }
    }
  return out;
}

std::vector<Strand> trace_strands(const Domain& domain, int region, const TensorField& field, const OrganicAsk& ask,
                                  OrganicTraceStats* stats) {
  std::vector<Strand> out;
  if (stats) *stats = OrganicTraceStats{};
  if (field.empty()) return out;
  {   // Q2 (brief G24): refused as grow_strands refuses it (I)
    const double thinnest = domain.spec().bead_mm * domain.spec().min_strut_lines;
    const double light = ask.width_mm > 0.0 ? ask.width_mm : thinnest;
    if (!(std::isfinite(ask.width_heavy_mm) && (ask.width_heavy_mm == 0.0 || ask.width_heavy_mm >= light - 1e-12)))
      throw std::invalid_argument("trace_strands: width_heavy_mm must be 0 or at least the strand width");
  }
  const std::size_t n = static_cast<std::size_t>(field.nx) * field.ny * field.nz;
  // The tracer reads only nx, ny, nz, spacing and origin of the grid; its tags must be sized to the grid (its voxel
  // count is the tags' size) though what is in them is never read.
  VoxelGrid grid;
  grid.nx = field.nx;
  grid.ny = field.ny;
  grid.nz = field.nz;
  grid.spacing = field.spacing;
  grid.origin = field.origin;
  grid.tags.assign(n, VoxelTag::Interior);
  // The candidates (voxels whose centre is lattice of the weave region) and the spacing asked of each (O12).
  const Domain::Probe probe = domain.probe();
  const OrganicSpacing asked = organic_spacing(domain, region, field, ask);
  if (asked.candidates == 0) return out;
  const std::vector<char>& candidate = asked.candidate;
  const std::vector<double>& spacing = asked.spacing_mm;
  OrganicParams params;
  params.min_extrudable_width_mm = domain.spec().bead_mm * domain.spec().min_strut_lines;
  params.strut_diameter_mm = ask.width_mm;
  params.bead_is_stated = true;   // no calibration: the width is the width
  params.build_dir = ask.build_dir;
  // As the old run sets them for a Traced job with its defaults (run_job.cpp, run_organic_step): the overhang clamp off
  // (organic_overhang_angle_deg 0), ties transferred with full swirl (read by Grown only), curve ends that leave the
  // region anchored (anchor_at_region_boundary, the tracer's default), families, ratios and limits the tracer's own.
  params.overhang_angle_deg = 0.0;
  params.transfer_ties = true;
  params.tie_swirl = 1.0;
  const OrganicLattice lat = trace_organic_lattice(grid, candidate, field.voigt, spacing, nullptr, params);
  if (stats) {
    stats->candidates = asked.candidates;
    stats->reference_mpa = asked.reference_mpa;
    double sum = 0.0;
    bool any = false;
    for (std::size_t e = 0; e < n; ++e) {
      if (!candidate[e]) continue;
      const double v = lat.spacing_used_mm[e];
      stats->spacing_smallest_mm = any ? std::min(stats->spacing_smallest_mm, v) : v;
      stats->spacing_largest_mm = any ? std::max(stats->spacing_largest_mm, v) : v;
      sum += v;
      any = true;
    }
    stats->spacing_mean_mm = sum / static_cast<double>(asked.candidates);
    stats->spacing_median_mm = lat.report.achieved_spacing_median_mm;
  }

  // The spacing the tracer used under a point; 0 off its candidates.
  auto spacing_at = [&](const Vec3& p) {
    const int i = static_cast<int>(std::floor((p.x - field.origin.x) / field.spacing));
    const int j = static_cast<int>(std::floor((p.y - field.origin.y) / field.spacing));
    const int k = static_cast<int>(std::floor((p.z - field.origin.z) / field.spacing));
    if (i < 0 || j < 0 || k < 0 || i >= field.nx || j >= field.ny || k >= field.nz) return 0.0;
    return lat.spacing_used_mm[field.index(i, j, k)];
  };
  auto smallest_spacing = [&](const std::vector<Vec3>& pts) {
    double s = 0.0;
    for (const Vec3& p : pts) {
      const double v = spacing_at(p);
      if (v > 0.0) s = s > 0.0 ? std::min(s, v) : v;
    }
    return s > 0.0 ? s : (ask.spacing_mm > 0.0 ? ask.spacing_mm : ask.spacing_min_mm);   // (never off the candidates:
                                                                                         // a curve's points are on them)
  };
  auto strand_of = [&](const std::vector<Vec3>& traced, double radius) {
    Strand s;
    s.region = region;
    s.spacing_mm = smallest_spacing(traced);
    const double width = 2.0 * radius;
    // O3: the fewest points within a tenth of its width of the traced line.
    for (std::size_t i : straighten_points(traced, 0.1 * width)) s.points.push_back(traced[i]);
    s.width_mm.assign(s.points.size(), width);
    return s;
  };
  for (const OrganicCurve& cv : lat.curves) {
    if (cv.points.size() < 2) continue;
    Strand s = strand_of(cv.points, cv.radius_mm);
    // O4: both free ends run on.
    const std::size_t last = s.points.size() - 1;
    run_on(probe, region, s.points[1], s.points[0], s.width_mm[0], s.spacing_mm);
    run_on(probe, region, s.points[last - 1], s.points[last], s.width_mm[last], s.spacing_mm);
    out.push_back(std::move(s));
  }
  const std::size_t curves = out.size();   // R: the curves come first, then the connectors
  for (const OrganicConnector& cn : lat.connectors) out.push_back(strand_of({cn.a, cn.b}, cn.radius_mm));
  // R: the light width (the tracer's own, before Q2), for the level ties.
  const double light_w = out.empty() ? params.min_extrudable_width_mm : out.front().width_mm.front();
  // Q2 (brief G24): strut thickness by stress, I1's rule on every point handed back (the tracer, O3 and O4 used the
  // light width): w + (width_heavy_mm - w) x u(p), w the point's own width, u(p) O12's stress share at p's voxel over
  // the reference the spacing used (the Grower's share()); 0 off the field or with a reference of 0.
  auto share = [&](const Vec3& p) {
      const int i = static_cast<int>(std::floor((p.x - field.origin.x) / field.spacing));
      const int j = static_cast<int>(std::floor((p.y - field.origin.y) / field.spacing));
      const int k = static_cast<int>(std::floor((p.z - field.origin.z) / field.spacing));
      if (i < 0 || j < 0 || k < 0 || i >= field.nx || j >= field.ny || k >= field.nz) return 0.0;
      const double* t = &field.voigt[6 * field.index(i, j, k)];
      const double a = t[0] - t[1], b = t[1] - t[2], d = t[2] - t[0];
      const double vm =
          std::sqrt(std::max(0.0, 0.5 * (a * a + b * b + d * d) + 3.0 * (t[3] * t[3] + t[4] * t[4] + t[5] * t[5])));
      return grading_demand_fraction(GradingIntent::Aesthetic, vm, asked.reference_mpa, 1.0);
    };
  if (ask.width_heavy_mm > 0.0) {
    for (Strand& s : out)
      for (std::size_t q = 0; q < s.points.size(); ++q)
        s.width_mm[q] = s.width_mm[q] + (ask.width_heavy_mm - s.width_mm[q]) * share(s.points[q]);
  }
  // R (brief G26): the level ties, after the curves, connectors and Q2's widths, before Q3's supports and the path; each
  // tie point gets the curves' width rule (Q2 when on, else the light width).
  if (ask.tie_level) {
    const std::size_t first_tie = out.size();
    lay_traced_level_ties(domain, region, field, ask, asked, curves, light_w, out, stats);
    if (ask.width_heavy_mm > 0.0)
      for (std::size_t t = first_tie; t < out.size(); ++t)
        for (std::size_t q = 0; q < out[t].points.size(); ++q)
          out[t].width_mm[q] = out[t].width_mm[q] + (ask.width_heavy_mm - out[t].width_mm[q]) * share(out[t].points[q]);
  }
  if (stats && ask.hold_parts) stats->hold_patches = asked.hold_patches;   // Q3: for hold_up_weave (L2 d)
  return out;
}

WeaveBraceAsk organic_brace_ask(const Domain& domain, const TensorField& field, const OrganicAsk& ask,
                                const std::vector<std::pair<int, double>>& references) {
  WeaveBraceAsk b;
  if (!(ask.unbraced_max > 0.0)) return b;
  b.unbraced_max = ask.unbraced_max;
  b.light_mm = ask.width_mm > 0.0 ? ask.width_mm : domain.spec().bead_mm * domain.spec().min_strut_lines;
  b.layer_mm = ask.layer_mm;
  b.link_width = ask.link_width;
  if (ask.width_heavy_mm > 0.0) {   // I1 / Q2's rule: light + (heavy - light) x u(p), u over the region's reference
    const std::vector<std::pair<int, double>> refs = references;   // T fix: computed once, by the region's own spacing
    const double light = b.light_mm, heavy = ask.width_heavy_mm;
    const TensorField* f = &field;
    b.width_at = [refs, light, heavy, f](int region, const Vec3& p) {
      double ref = 0.0;
      for (const auto& rr : refs) if (rr.first == region) ref = rr.second;
      const TensorField& field = *f;
      const int i = static_cast<int>(std::floor((p.x - field.origin.x) / field.spacing));
      const int j = static_cast<int>(std::floor((p.y - field.origin.y) / field.spacing));
      const int k = static_cast<int>(std::floor((p.z - field.origin.z) / field.spacing));
      double u = 0.0;
      if (!(i < 0 || j < 0 || k < 0 || i >= field.nx || j >= field.ny || k >= field.nz)) {
        const double* t = &field.voigt[6 * field.index(i, j, k)];
        const double a = t[0] - t[1], bb = t[1] - t[2], d = t[2] - t[0];
        const double vm =
            std::sqrt(std::max(0.0, 0.5 * (a * a + bb * bb + d * d) + 3.0 * (t[3] * t[3] + t[4] * t[4] + t[5] * t[5])));
        u = grading_demand_fraction(GradingIntent::Aesthetic, vm, ref, 1.0);
      }
      return light + (heavy - light) * u;
    };
  }
  return b;
}

Outcome Session::lay_organic(const Settings& settings, const TensorField& field, const OrganicAsk& ask, int threads,
                             const std::atomic<bool>* stop) {
  return lay_organic_with(settings, field, ask, threads, stop, false);
}

Outcome Session::lay_organic_draft(const Settings& settings, const TensorField& field, const OrganicAsk& ask,
                                   int threads, const std::atomic<bool>* stop) {
  return lay_organic_with(settings, field, ask, threads, stop, true);
}

Outcome Session::lay_organic_with(const Settings& settings, const TensorField& field, const OrganicAsk& ask,
                                  int threads, const std::atomic<bool>* stop, bool draft) {
  if (stop && stop->load(std::memory_order_relaxed)) {
    Outcome none;
    none.cancelled = true;
    return none;
  }
  // OR30: the Finish is the regular lattices' own. Rim and Covered are "where" settings of the domain the weave is
  // traced and laid in (their solid cuts the strands as any solid does); Skin lays the net skin (O16).
  ready_domain(settings);
  WeaveFinish finish;
  // S (brief G28): the cut at crossings judges by the light width (the growth's and the tracer's), never by I1 / Q2's.
  finish.light_mm = ask.width_mm > 0.0 ? ask.width_mm : domain_->spec().bead_mm * domain_->spec().min_strut_lines;
  finish.layer_mm = ask.layer_mm;
  finish.link_width = ask.link_width;   // S8
  finish.draft = draft;                 // brief L2, item 3
  const auto t0 = std::chrono::steady_clock::now();
  std::vector<Strand> strands;
  double smallest = 0.0, largest = 0.0, sum = 0.0;
  std::size_t candidates = 0;
  std::shared_ptr<GrowReport> grown;
  std::vector<std::pair<int, double>> references;   // T fix: each weave region's O12 reference, as computed once   // G1: Grown in place of Traced; the spacing stats are then O12's, as asked
  for (const Region& r : domain_->spec().regions) {
    if (r.role != Role::Lattice || !r.weave) continue;
    OrganicTraceStats st;
    std::vector<Strand> traced;
    // O16, the net skin's reach: Traced, the trace's own median spacing (as the old run); Grown, which has no trace, the
    // median of the spacing field over the region's candidates (the field it is laid with). LatticeReview's ruling 2
    // (2026-11-15) asked the field's median for both; on the made-up cube it changed Traced's net from 5,145 struts
    // (12,626 mm) to 5,932 (24,424 mm), so Traced keeps its own until that is ruled on.
    const OrganicSpacing sp =
        ask.mode == OrganicMode::Grown ? organic_spacing(*domain_, r.id, field, ask) : OrganicSpacing{};
    double median = 0.0;
    {
      std::vector<double> all;
      for (std::size_t e = 0; e < sp.candidate.size(); ++e)
        if (sp.candidate[e]) all.push_back(sp.spacing_mm[e]);
      if (!all.empty()) {
        std::sort(all.begin(), all.end());
        median = all[all.size() / 2];
      }
    }
    if (ask.mode == OrganicMode::Grown) {
      GrowReport one;
      traced = grow_strands(*domain_, r.id, field, ask, &one, &sp);   // T fix: the spacing computed once, above
      if (!grown) grown = std::make_shared<GrowReport>();
      grown->add(one);
      for (std::size_t e = 0; e < sp.candidate.size(); ++e) {
        if (!sp.candidate[e]) continue;
        const double v = sp.spacing_mm[e];
        st.spacing_smallest_mm = st.candidates ? std::min(st.spacing_smallest_mm, v) : v;
        st.spacing_largest_mm = st.candidates ? std::max(st.spacing_largest_mm, v) : v;
        st.spacing_mean_mm += v;
        ++st.candidates;
      }
      if (st.candidates) st.spacing_mean_mm /= static_cast<double>(st.candidates);
    } else {
      traced = trace_strands(*domain_, r.id, field, ask, &st);
    }
    const double reach = ask.mode == OrganicMode::Grown ? median : st.spacing_median_mm;
    if (settings.skin && reach > 0.0) finish.net_reach.push_back({r.id, reach});   // O16
    if (ask.mode == OrganicMode::Grown) finish.arrived.push_back(r.id);   // G11: a vine that reached the surface
    if (ask.mode == OrganicMode::Grown && ask.prune) finish.prune.push_back({r.id, median});   // J2
    // L2 d; Q3 (brief G24): Traced lays the same supports, from the floating pieces its own trace's spacing found.
    const std::vector<OrganicSpacing::HoldPatch>& patches = ask.mode == OrganicMode::Grown ? sp.hold_patches : st.hold_patches;
    if (ask.hold_parts && !patches.empty()) {
      WeaveHold hold;
      hold.region = r.id;
      hold.spacing_min_mm = ask.spacing_mm > 0.0 ? ask.spacing_mm : ask.spacing_min_mm;
      hold.width_mm = ask.width_mm > 0.0 ? ask.width_mm : domain_->spec().bead_mm * domain_->spec().min_strut_lines;
      hold.layer_mm = ask.layer_mm;
      hold.depth_mm = r.is_shell() ? r.shell_depth_mm : r.prism.depth;
      hold.grid_mm = field.spacing;
      hold.support_mm = ask.part_support_mm;
      hold.to_floor = ask.part_to_floor;
      for (const OrganicSpacing::HoldPatch& P : patches) hold.patches.push_back({P.bottoms, P.plan_mm2, P.lo, P.hi});
      finish.hold.push_back(std::move(hold));
    }
    if (st.candidates > 0) {
      smallest = candidates ? std::min(smallest, st.spacing_smallest_mm) : st.spacing_smallest_mm;
      largest = candidates ? std::max(largest, st.spacing_largest_mm) : st.spacing_largest_mm;
      sum += st.spacing_mean_mm * static_cast<double>(st.candidates);
      candidates += st.candidates;
    }
    references.push_back({r.id, ask.mode == OrganicMode::Grown ? sp.reference_mpa : st.reference_mpa});   // T fix
    strands.insert(strands.end(), std::make_move_iterator(traced.begin()), std::make_move_iterator(traced.end()));
  }
  finish.brace = organic_brace_ask(*domain_, field, ask, references);   // T (off unless unbraced_max)
  const double ms_trace = std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - t0).count();
  Outcome out = lay_with(settings, &strands, threads, stop, &finish);
  if (!out.cancelled) {
    out.organic_references = references;   // brief E2
    // Brief E2, item 9: the width floors, last, only with the strut width on a Sweep.
    if (!ask.floors.empty() && ask.width_heavy_mm > 0.0)
      out.floors_widened = apply_width_floors(out.bars, ask.floors, ask.width_heavy_mm, finish.light_mm, ask.link_width,
                                              &out.floor_links_widened);
    out.strands = strands.size();
    out.ms_trace = ms_trace;
    out.spacing_smallest_mm = smallest;
    out.spacing_largest_mm = largest;
    out.spacing_mean_mm = candidates ? sum / static_cast<double>(candidates) : 0.0;
    out.grown = grown;
  }
  return out;
}


// ── J2 (brief G12): the pruning of a Grown area's weave bars ──────────────────────
namespace {
using JKey = std::array<long long, 3>;
JKey jkey(const Vec3& p) {   // as bars.cpp's key_of (kSame 1e-5 mm)
  return {std::llround(p.x / 1e-5), std::llround(p.y / 1e-5), std::llround(p.z / 1e-5)};
}
double jlen(const Bar& b) { return std::sqrt((b.b.x - b.a.x) * (b.b.x - b.a.x) + (b.b.y - b.a.y) * (b.b.y - b.a.y) + (b.b.z - b.a.z) * (b.b.z - b.a.z)); }
double jto(const Vec3& p, const Vec3& a, const Vec3& b) {
  const Vec3 d{b.x - a.x, b.y - a.y, b.z - a.z};
  const double l2 = d.x * d.x + d.y * d.y + d.z * d.z;
  const double t = l2 > 0.0 ? std::max(0.0, std::min(1.0, ((p.x - a.x) * d.x + (p.y - a.y) * d.y + (p.z - a.z) * d.z) / l2)) : 0.0;
  const double x = p.x - a.x - d.x * t, y = p.y - a.y - d.y * t, z = p.z - a.z - d.z * t;
  return std::sqrt(x * x + y * y + z * z);
}
void jkeep(Bars& bars, const std::vector<char>& keep) {   // as bars.cpp's keep_only
  std::vector<int> now(bars.bars.size(), -1);
  std::vector<Bar> left;
  for (std::size_t i = 0; i < bars.bars.size(); ++i) {
    if (!keep[i]) { ++bars.dropped; continue; }
    now[i] = static_cast<int>(left.size());
    left.push_back(bars.bars[i]);
  }
  for (Bar& b : left) {
    if (b.into_a >= 0) b.into_a = b.into_a < static_cast<int>(now.size()) ? now[static_cast<std::size_t>(b.into_a)] : -1;
    if (b.into_b >= 0) b.into_b = b.into_b < static_cast<int>(now.size()) ? now[static_cast<std::size_t>(b.into_b)] : -1;
  }
  bars.bars.swap(left);
}
}  // namespace

std::vector<PruneCount> prune_weave(Bars& bars, const std::vector<std::pair<int, double>>& areas) {
  std::vector<PruneCount> out;
  for (const auto& a : areas) { PruneCount c; c.region = a.first; out.push_back(c); }
  auto area_of = [&](int region) {
    for (std::size_t k = 0; k < areas.size(); ++k) if (areas[k].first == region) return static_cast<int>(k);
    return -1;
  };
  const std::size_t n = bars.bars.size();
  std::vector<char> keep(n, 1);
  // J2a
  for (bool again = true, first = true; again; first = false) {
    again = false;
    std::map<JKey, int> at;
    for (std::size_t i = 0; i < n; ++i)
      if (keep[i]) { ++at[jkey(bars.bars[i].a)]; ++at[jkey(bars.bars[i].b)]; }
    std::vector<std::size_t> cut;
    for (std::size_t i = 0; i < n; ++i) {
      if (!keep[i]) continue;
      const Bar& b = bars.bars[i];
      if (b.net || area_of(b.region) < 0) continue;
      auto in_air = [&](Bar::End e, const Vec3& p, int into) {
        if (e == Bar::End::Solid || e == Bar::End::Surface) return false;
        if (e == Bar::End::Joined) return !(into >= 0 && into < static_cast<int>(n) && keep[static_cast<std::size_t>(into)]);
        return at[jkey(p)] < 2;
      };
      if (in_air(b.end_a, b.a, b.into_a) || in_air(b.end_b, b.b, b.into_b)) cut.push_back(i);
    }
    for (std::size_t i : cut) {
      keep[i] = 0;
      PruneCount& c = out[static_cast<std::size_t>(area_of(bars.bars[i].region))];
      c.supports_cut += bars.bars[i].support;   // L2
      ++c.bars_cut;
      c.cut_mm += jlen(bars.bars[i]);
      if (first) ++c.ends_cut;
      again = true;
    }
  }
  // J2b, per area
  for (std::size_t k = 0; k < areas.size(); ++k) {
    std::vector<std::size_t> mine;
    for (std::size_t i = 0; i < n; ++i) if (keep[i] && bars.bars[i].region == areas[k].first) mine.push_back(i);
    if (mine.empty()) continue;
    std::map<std::size_t, std::size_t> local;   // bar -> its place in mine
    for (std::size_t m = 0; m < mine.size(); ++m) local[mine[m]] = m;
    std::vector<std::size_t> parent(mine.size());
    for (std::size_t m = 0; m < mine.size(); ++m) parent[m] = m;
    auto find = [&](std::size_t i) { while (parent[i] != i) { parent[i] = parent[parent[i]]; i = parent[i]; } return i; };
    auto join = [&](std::size_t i, std::size_t j) { i = find(i); j = find(j); if (i != j) parent[std::max(i, j)] = std::min(i, j); };
    {   // shared end points, not when both bars end Solid there
      std::map<JKey, std::vector<std::pair<std::size_t, bool>>> ends;   // (place, Solid end)
      for (std::size_t m = 0; m < mine.size(); ++m) {
        const Bar& b = bars.bars[mine[m]];
        ends[jkey(b.a)].push_back({m, b.end_a == Bar::End::Solid});
        ends[jkey(b.b)].push_back({m, b.end_b == Bar::End::Solid});
      }
      for (const auto& e : ends)
        for (std::size_t x = 0; x < e.second.size(); ++x)
          for (std::size_t y = x + 1; y < e.second.size(); ++y)
            if (!(e.second[x].second && e.second[y].second)) join(e.second[x].first, e.second[y].first);
    }
    for (std::size_t m = 0; m < mine.size(); ++m) {   // a Joined end and the bar it ends in
      const Bar& b = bars.bars[mine[m]];
      for (int into : {b.end_a == Bar::End::Joined ? b.into_a : -1, b.end_b == Bar::End::Joined ? b.into_b : -1}) {
        if (into < 0) continue;
        const auto it = local.find(static_cast<std::size_t>(into));
        if (it != local.end()) join(m, it->second);
      }
    }
    {   // an end lying within half the other bar's width of it
      const double pitch = 2.0;
      auto slot = [&](double x) { return static_cast<long long>(std::floor(x / pitch)); };
      std::map<JKey, std::vector<std::size_t>> grid;
      double widest = 0.0;
      for (std::size_t m = 0; m < mine.size(); ++m) widest = std::max(widest, bars.bars[mine[m]].width);
      for (std::size_t m = 0; m < mine.size(); ++m) {
        const Bar& b = bars.bars[mine[m]];
        for (long long x = slot(std::min(b.a.x, b.b.x) - widest); x <= slot(std::max(b.a.x, b.b.x) + widest); ++x)
          for (long long y = slot(std::min(b.a.y, b.b.y) - widest); y <= slot(std::max(b.a.y, b.b.y) + widest); ++y)
            for (long long z = slot(std::min(b.a.z, b.b.z) - widest); z <= slot(std::max(b.a.z, b.b.z) + widest); ++z)
              grid[{x, y, z}].push_back(m);
      }
      for (std::size_t m = 0; m < mine.size(); ++m) {
        const Bar& b = bars.bars[mine[m]];
        for (const Vec3& p : {b.a, b.b}) {
          const auto it = grid.find({slot(p.x), slot(p.y), slot(p.z)});
          if (it == grid.end()) continue;
          for (std::size_t o : it->second) {
            if (o == m || find(o) == find(m)) continue;
            const Bar& c = bars.bars[mine[o]];
            if (jto(p, c.a, c.b) <= 0.5 * c.width) join(m, o);
          }
        }
      }
    }
    std::map<std::size_t, double> mm;
    std::map<std::size_t, char> holds_support;   // L2: a piece holding a support bar is never removed
    for (std::size_t m = 0; m < mine.size(); ++m) {
      mm[find(m)] += jlen(bars.bars[mine[m]]);
      if (bars.bars[mine[m]].support) holds_support[find(m)] = 1;
    }
    std::size_t largest = 0;
    double big = -1.0;
    for (const auto& g : mm) if (g.second > big) { big = g.second; largest = g.first; }
    const double floor_mm = 20.0 * areas[k].second;
    PruneCount& c = out[k];
    for (const auto& g : mm) {
      if (g.first == largest) continue;
      if (g.second < floor_mm && holds_support.count(g.first)) {
        ++c.pieces_held_by_support; c.held_by_support_mm += g.second;
      } else if (g.second < floor_mm) {
        ++c.pieces_removed; c.removed_mm += g.second;
        for (std::size_t m = 0; m < mine.size(); ++m) if (find(m) == g.first) keep[mine[m]] = 0;
      } else { ++c.pieces_apart; c.apart_mm += g.second; }
    }
  }
  jkeep(bars, keep);
  return out;
}

// ── L2 d, e (brief G14): supports from the undersides of floating parts ────────────────
std::vector<HoldPatchCount> hold_up_weave(Bars& bars, const Domain& domain, const std::vector<WeaveHold>& areas) {
  std::vector<HoldPatchCount> out;
  const Domain::Probe probe = domain.probe();
  auto d3 = [](const Vec3& a, const Vec3& b) { return std::sqrt((a.x - b.x) * (a.x - b.x) + (a.y - b.y) * (a.y - b.y) + (a.z - b.z) * (a.z - b.z)); };
  int strand_base = 0;
  for (const Bar& b : bars.bars) strand_base = std::max(strand_base, b.strand + 1);
  for (const WeaveHold& A : areas) {
    // The area's kept vine bars: their ends (with the bar's width) and the ends tagged Solid.
    std::vector<Vec3> verts, solid_ends;
    std::vector<double> vw;
    auto read_ends = [&]() {
      verts.clear(); vw.clear(); solid_ends.clear();
      for (const Bar& b : bars.bars) {
        if (b.region != A.region || b.net) continue;
        verts.push_back(b.a); vw.push_back(b.width);
        verts.push_back(b.b); vw.push_back(b.width);
        if (b.end_a == Bar::End::Solid) solid_ends.push_back(b.a);
        if (b.end_b == Bar::End::Solid) solid_ends.push_back(b.b);
      }
    };
    read_ends();
    const double g = A.grid_mm > 0.0 ? A.grid_mm : 1.0;
    auto ends_under = [&](const WeaveHold::Patch& P) {
      std::size_t n = 0;
      for (const Vec3& e : solid_ends)
        for (const Vec3& q : P.bottoms)
          if (std::fabs(e.x - q.x) <= 0.5 * g && std::fabs(e.y - q.y) <= 0.5 * g && std::fabs(e.z - q.z) <= g) { ++n; break; }
      return n;
    };
    const double smin = A.spacing_min_mm, Lh = A.layer_mm > 0.0 ? A.layer_mm : 0.2;
    std::vector<Strand> supports;
    std::vector<std::size_t> of_patch;
    std::vector<char> on_vertex;
    const std::size_t first = out.size();
    for (const WeaveHold::Patch& P : A.patches) {
      HoldPatchCount c;
      c.region = A.region; c.lo = P.lo; c.hi = P.hi; c.plan_mm2 = P.plan_mm2;
      c.ends_before = ends_under(P);
      std::vector<Vec3> pts = P.bottoms;
      std::sort(pts.begin(), pts.end(), [](const Vec3& a, const Vec3& b) { return std::make_tuple(a.z, a.x, a.y) < std::make_tuple(b.z, b.x, b.y); });
      std::vector<Vec3> kept;
      const double apart = A.support_mm > 0.0 ? A.support_mm : smin;   // organic_part_support_mm (0: spacing_min_mm)
      for (const Vec3& q : pts) {
        bool far = true;
        for (const Vec3& k : kept) far = far && d3(k, q) >= apart;
        if (far || kept.empty()) kept.push_back(q);
      }
      for (const Vec3& p : kept) {
        ++c.points;
        bool held = false;
        for (const Vec3& e : solid_ends) held = held || d3(e, p) <= 0.5 * smin;
        if (held) { ++c.held; continue; }
        // The bar ends that can matter: inside the 45 degree cone under p (and a little round it, for the joint test).
        std::vector<std::size_t> near;
        for (std::size_t i = 0; i < verts.size(); ++i) {
          const double dz = p.z - verts[i].z, hd = std::hypot(verts[i].x - p.x, verts[i].y - p.y);
          const double reach = A.to_floor ? 2.0 * A.depth_mm : A.depth_mm, slack = A.to_floor ? 4.0 : 2.0;
          if (dz > -2.0 && dz <= reach + 2.0 && hd <= std::max(0.0, dz) + slack) near.push_back(i);
        }
        std::vector<Vec3> path{p};
        Vec3 cur = p;
        double run = 0.0;
        bool entered = false;
        int ending = 0;   // 1 on a vine, 2 on solid, 3 on the floor, -1 left the area, -2 too long
        // (brief G15 heavier) to_floor: a vine vertex reached is a joint the support passes through; it ends only on
        // solid or the floor; leaving the area or running past twice the depth ends it at its last joint (or refuses it).
        std::vector<Vec3> joints;
        std::size_t last_joint = 0;   // path's size just after the last joint
        auto joined_at = [&](const Vec3& v) {
          for (const Vec3& q : joints) if (d3(q, v) < 1e-9) return true;
          return false;
        };
        const double most = A.to_floor ? 2.0 * A.depth_mm : A.depth_mm;
        for (;;) {
          std::size_t best = verts.size();
          double bd = std::numeric_limits<double>::infinity();
          for (std::size_t i : near) {
            const double dz = cur.z - verts[i].z;
            if (!(dz > 0.0)) continue;
            const double hd = std::hypot(verts[i].x - cur.x, verts[i].y - cur.y);
            if (hd > dz) continue;
            const double dd = std::hypot(hd, dz);
            if (dd < bd) { bd = dd; best = i; }
          }
          Vec3 next{cur.x, cur.y, cur.z - Lh};
          if (best < verts.size()) {
            const double hx = verts[best].x - cur.x, hy = verts[best].y - cur.y, hd = std::hypot(hx, hy);
            if (hd > 1e-9) {
              const double lean = std::min(Lh, hd);
              next.x += hx / hd * lean;
              next.y += hy / hd * lean;
            }
          }
          run += d3(cur, next);
          if (entered) {
            std::size_t hit = verts.size();
            double hb = std::numeric_limits<double>::infinity();
            for (std::size_t i : near) {
              if (A.to_floor && joined_at(verts[i])) continue;
              const double dd = d3(next, verts[i]);
              if (dd <= vw[i] && dd < hb) { hb = dd; hit = i; }
            }
            if (hit < verts.size()) {
              path.push_back(verts[hit]);
              if (!A.to_floor) { ending = 1; break; }
              joints.push_back(verts[hit]);
              last_joint = path.size();
              cur = verts[hit];
              if (run > most) { ending = -2; break; }
              continue;
            }
          }
          const Where w = probe.where(next);
          if (w.why == Why::Outside) { ending = -1; break; }
          if (w.lattice()) {
            if (w.id != A.region) { ending = -1; break; }
            entered = true;
          } else if (entered) {
            path.push_back(next);
            ending = w.why == Why::BedFloor ? 3 : 2;
            break;
          }
          if (run > most) { ending = -2; break; }
          path.push_back(next);
          cur = next;
        }
        if (A.to_floor && ending < 0 && !joints.empty()) {   // ends at its last joint, as a support ending on a vine
          path.resize(last_joint);
          ending = 1;
        }
        c.joints += A.to_floor ? (ending == 1 ? joints.size() - 1 : joints.size()) : 0;
        if (ending == -1) { ++c.refused_air; continue; }
        if (ending == -2) { ++c.refused_long; continue; }
        // One strand from its lower end up, its top at the hanging voxel's centre (in the solid), straight runs merged.
        std::vector<Vec3> up(path.rbegin(), path.rend());
        up.push_back({p.x, p.y, p.z + 0.5 * g});
        Strand st;
        st.region = A.region;
        st.spacing_mm = smin;
        for (std::size_t i = 0; i < up.size(); ++i) {
          if (!st.points.empty() && i + 1 < up.size() && !joined_at(up[i])) {   // a joint is never merged away
            const Vec3& a = st.points.back();
            const Vec3 d1{up[i].x - a.x, up[i].y - a.y, up[i].z - a.z}, d2{up[i + 1].x - up[i].x, up[i + 1].y - up[i].y, up[i + 1].z - up[i].z};
            const double l1 = d3(up[i], a), l2 = d3(up[i + 1], up[i]);
            if (l1 > 0.0 && l2 > 0.0 && std::fabs((d1.x * d2.x + d1.y * d2.y + d1.z * d2.z) / (l1 * l2) - 1.0) < 1e-9) continue;
          }
          st.points.push_back(up[i]);
        }
        st.width_mm.assign(st.points.size(), A.width_mm);
        supports.push_back(std::move(st));
        of_patch.push_back(out.size());
        on_vertex.push_back(ending == 1);
        (ending == 1 ? c.on_vine : ending == 3 ? c.on_floor : c.on_solid)++;
      }
      out.push_back(c);
    }
    if (!supports.empty()) {
      Bars sup = weave_bars(domain, supports, 1);
      const std::size_t base = bars.bars.size();
      // Each support's top end: tagged Solid when its top piece was dropped as a stub and the solid begins within its
      // width + half a grid step above it.
      std::vector<int> top_bar(supports.size(), -1);
      std::vector<char> top_is_b(supports.size(), 0);
      for (std::size_t q = 0; q < sup.bars.size(); ++q) {
        const Bar& b = sup.bars[q];
        const std::size_t si = static_cast<std::size_t>(b.strand);
        if (si >= supports.size()) continue;
        for (int e = 0; e < 2; ++e) {
          const Vec3& x = e ? b.b : b.a;
          const int t = top_bar[si];
          const double tz = t < 0 ? -1e300 : (top_is_b[si] ? sup.bars[static_cast<std::size_t>(t)].b.z : sup.bars[static_cast<std::size_t>(t)].a.z);
          if (x.z > tz) { top_bar[si] = static_cast<int>(q); top_is_b[si] = static_cast<char>(e); }
        }
      }
      for (std::size_t si = 0; si < supports.size(); ++si) {
        if (top_bar[si] < 0) continue;   // (with to_floor the top is still the support's highest end)
        Bar& b = sup.bars[static_cast<std::size_t>(top_bar[si])];
        Bar::End& kind = top_is_b[si] ? b.end_b : b.end_a;
        if (kind == Bar::End::Solid || kind == Bar::End::Surface) continue;
        const Vec3 x = top_is_b[si] ? b.b : b.a;
        bool solid_above = false;
        for (double t = 0.05; t <= A.width_mm + 0.5 * g + 1e-9 && !solid_above; t += 0.05) {
          const Where w = probe.where(Vec3{x.x, x.y, x.z + t});
          solid_above = w.why != Why::Outside && !w.lattice();
        }
        if (solid_above) { kind = Bar::End::Solid; ++out[of_patch[si]].top_retagged; }
        else ++out[of_patch[si]].top_open;
      }
      for (Bar& b : sup.bars) {
        const std::size_t si = static_cast<std::size_t>(b.strand);
        if (si < supports.size()) {
          if (on_vertex[si] && d3(b.a, supports[si].points.front()) < 1e-9) b.end_a = Bar::End::Node;
          HoldPatchCount& c = out[of_patch[si]];
          c.mm += d3(b.a, b.b);
          ++c.bars_laid;
          const int sn = static_cast<int>(si) + strand_base;
          c.strand_lo = c.strand_lo < 0 ? sn : std::min(c.strand_lo, sn);
          c.strand_hi = std::max(c.strand_hi, sn + 1);
        }
        b.support = true;
        b.strand += strand_base;
        if (b.into_a >= 0) b.into_a += static_cast<int>(base);
        if (b.into_b >= 0) b.into_b += static_cast<int>(base);
        bars.bars.push_back(b);
      }
      bars.stubs += sup.stubs;
      strand_base += static_cast<int>(supports.size());
    }
    read_ends();
    for (std::size_t q = first; q < out.size(); ++q) out[q].ends_after = ends_under(A.patches[q - first]);
  }
  return out;
}

}  // namespace topopt::lattice_layout
