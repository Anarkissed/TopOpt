// Lattice rebuild, Organic stage 1b: the owner's Traced placement through the new engine (O3, O4).
// See lattice_layout_organic.hpp. The old tracer is called as it is and nothing after it in the old path.
#include "topopt/lattice_layout_organic.hpp"

#include <algorithm>
#include <array>
#include <map>
#include <chrono>
#include <cmath>
#include <cstdio>
#include <string>
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
void run_on(const Domain::Probe& probe, int region, const Vec3& from, Vec3& end, double width, double spacing,
            double line_mm) {
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
    end = at(solid ? in + solid_run_on(probe, at(in), d, width, line_mm) : in);   // OG5: within the solid's thickness
    return;
  }
}

double segments_apart(const Vec3& p1, const Vec3& q1, const Vec3& p2, const Vec3& q2);   // below (OP11)
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

// OG1 (brief E6): the local spacing at each strand point, its reason, and the gap rule's cap.
std::size_t organic_gap_cap(std::vector<Strand>& strands, std::size_t first, const TensorField& field,
                            const std::vector<double>& spacing, const std::vector<std::uint8_t>& why, double gap_mm,
                            double thinnest_mm) {
  std::size_t lowered = 0;
  const std::size_t n = static_cast<std::size_t>(std::max(0, field.nx)) * static_cast<std::size_t>(std::max(0, field.ny)) *
                        static_cast<std::size_t>(std::max(0, field.nz));
  const bool grid = !field.empty() && spacing.size() == n;
  // The voxel of p (its spacing above 0), else the smallest spacing above 0 of the 26 around it; n when none.
  auto voxel_of = [&](const Vec3& p) {
    if (!grid) return n;
    const int i = static_cast<int>(std::floor((p.x - field.origin.x) / field.spacing));
    const int j = static_cast<int>(std::floor((p.y - field.origin.y) / field.spacing));
    const int k = static_cast<int>(std::floor((p.z - field.origin.z) / field.spacing));
    auto inside = [&](int a, int b, int c) { return a >= 0 && b >= 0 && c >= 0 && a < field.nx && b < field.ny && c < field.nz; };
    if (inside(i, j, k) && spacing[field.index(i, j, k)] > 0.0) return field.index(i, j, k);
    std::size_t best = n;
    for (int dk = -1; dk <= 1; ++dk)
      for (int dj = -1; dj <= 1; ++dj)
        for (int di = -1; di <= 1; ++di) {
          if (!inside(i + di, j + dj, k + dk)) continue;
          const std::size_t e = field.index(i + di, j + dj, k + dk);
          if (spacing[e] > 0.0 && (best == n || spacing[e] < spacing[best])) best = e;
        }
    return best;
  };
  for (std::size_t t = first; t < strands.size(); ++t) {
    Strand& s = strands[t];
    const std::size_t m = s.points.size();
    s.local_mm.assign(m, 0.0);
    s.local_why.assign(m, 0);
    if (gap_mm > 0.0) s.cap_mm.assign(m, 0.0); else s.cap_mm.clear();
    for (std::size_t q = 0; q < m; ++q) {
      const std::size_t e = voxel_of(s.points[q]);
      if (e < n) {
        s.local_mm[q] = spacing[e];
        s.local_why[q] = e < why.size() ? why[e] : 0;
      } else {
        s.local_mm[q] = s.spacing_mm;   // off the field: the strand's own spacing, reason not known
      }
      if (!(gap_mm > 0.0)) continue;
      const double cap = std::max(thinnest_mm, s.local_mm[q] - gap_mm);
      s.cap_mm[q] = cap;
      if (q < s.width_mm.size() && s.width_mm[q] > cap) {
        s.width_mm[q] = cap;
        ++lowered;
      }
    }
  }
  return lowered;
}

std::size_t gap_broken(const Bars& bars) {
  std::size_t n = 0;
  for (const Bar& b : bars.bars) n += b.gap_cap_mm > 0.0 && b.width > b.gap_cap_mm + 1e-9;
  return n;
}

bool has_relief(const Bars& bars) {
  for (const Bar& b : bars.bars)
    if (b.relief_a > 0.0 || b.relief_b > 0.0) return true;
  return false;
}

Bars without_relief(const Bars& bars) {
  Bars out = bars;
  for (Bar& b : out.bars) {
    const double L = dist(b.a, b.b);
    if (!(L > 0.0)) continue;
    const Vec3 d{(b.b.x - b.a.x) / L, (b.b.y - b.a.y) / L, (b.b.z - b.a.z) / L};
    if (b.relief_a > 0.0) b.a = Vec3{b.a.x + d.x * b.relief_a, b.a.y + d.y * b.relief_a, b.a.z + d.z * b.relief_a};
    if (b.relief_b > 0.0) b.b = Vec3{b.b.x - d.x * b.relief_b, b.b.y - d.y * b.relief_b, b.b.z - d.z * b.relief_b};
    b.proud_a = b.proud_b = b.relief_a = b.relief_b = 0.0;
  }
  return out;
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
                            std::vector<char>* solid, const std::vector<int>* pool) {
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
  out.why.assign(n, 0);          // OG1
  constexpr std::uint8_t kUniform = static_cast<std::uint8_t>(SpacingWhy::Uniform),
                         kStress = static_cast<std::uint8_t>(SpacingWhy::Stress),
                         kShape = static_cast<std::uint8_t>(SpacingWhy::Shape);
  if (solid) solid->assign(n, 0);
  std::vector<char> weave_ids;   // by region id: is it a weave region
  for (const Region& r : domain.spec().regions)
    if (r.role == Role::Lattice && r.weave && r.id >= 0 &&
        (!pool || std::find(pool->begin(), pool->end(), r.id) != pool->end())) {   // OP11: a group's own weave
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
      if (out.candidate[e]) { out.spacing_mm[e] = lo; out.why[e] = kUniform; }
    return out;
  }
  if (!ask.follow_stress) {   // OP6, shape only: f = 0 and no reference (u = 0); O13 and L2 below as ever
    for (std::size_t e = 0; e < n; ++e)
      if (out.candidate[e]) { out.spacing_mm[e] = hi; out.why[e] = kUniform; }
  } else {
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
    out.why[e] = out.spacing_mm[e] < hi ? kStress : kUniform;   // OG1
  }
  }   // OP6
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
    out.why[e] = kShape;   // OG1
    ++out.shape_fit_tightened;
  }
  return out;
}
}  // namespace

OrganicSpacing organic_spacing(const Domain& domain, int region, const TensorField& field, const OrganicAsk& ask,
                               const std::vector<int>* pool) {
  if (!ask.hold_parts) return spacing_core(domain, region, field, ask, nullptr, pool);
  std::vector<char> solid;
  OrganicSpacing out = spacing_core(domain, region, field, ask, &solid, pool);
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
            if (out.spacing_mm[e] > tight) {
              out.spacing_mm[e] = tight;
              out.why[e] = static_cast<std::uint8_t>(SpacingWhy::Hold);   // OG1
              ++out.hold_tightened;
              ++P.tightened;
            }
          }
    }
  return out;
}

std::vector<Strand> trace_strands(const Domain& domain, int region, const TensorField& field, const OrganicAsk& ask,
                                  OrganicTraceStats* stats, const std::vector<int>* pool) {
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
  const OrganicSpacing asked = organic_spacing(domain, region, field, ask, pool);
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
  params.test_ratio = ask.strand_keep;   // OG3 (brief E6, leg D): 0.5 = the tracer's own kOrganicTestRatio
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
    // OG5 at source (brief E9): the tracer reads its candidates at voxel centres, so a curve can wander past the region's
    // true edge into solid (or out of the part). It is cut there: each run of its points that lie in the region's
    // lattice is a strand of its own (a run of one point is none); a curve wholly inside is as before.
    std::vector<std::vector<Vec3>> runs(1);
    for (const Vec3& p : cv.points) {
      const Where w = probe.where(p);
      if (w.lattice() && w.id == region) runs.back().push_back(p);
      else if (!runs.back().empty()) runs.emplace_back();
    }
    for (const std::vector<Vec3>& pts : runs) {
      if (pts.size() < 2) continue;
      Strand s = strand_of(pts, cv.radius_mm);
      // O4: both free ends run on.
      const std::size_t last = s.points.size() - 1;
      run_on(probe, region, s.points[1], s.points[0], s.width_mm[0], s.spacing_mm, domain.spec().bead_mm);
      run_on(probe, region, s.points[last - 1], s.points[last], s.width_mm[last], s.spacing_mm, domain.spec().bead_mm);
      out.push_back(std::move(s));
    }
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
  std::size_t first_tie_of_traced = out.size();   // OG3: where the level ties begin
  if (ask.tie_level) {
    const std::size_t first_tie = out.size();
    lay_traced_level_ties(domain, region, field, ask, asked, curves, light_w, out, stats);
    if (ask.width_heavy_mm > 0.0)
      for (std::size_t t = first_tie; t < out.size(); ++t)
        for (std::size_t q = 0; q < out[t].points.size(); ++q)
          out[t].width_mm[q] = out[t].width_mm[q] + (ask.width_heavy_mm - out[t].width_mm[q]) * share(out[t].points[q]);
  }
  if (stats && ask.hold_parts) stats->hold_patches = asked.hold_patches;   // Q3: for hold_up_weave (L2 d)
  // OG3 (brief E6, leg D), with strand_keep above the tracer's old 0.5: a level tie is not laid where its tube would lie
  // within the gap (OG1's, gap_lines x the line; 1.5 lines when the gap is off) of a strand segment it does not join
  // (shares no point with) and under 20 degrees to it. Such tie segments are taken out; what is left of a tie stays as
  // ties (each stretch of two points or more). Links (made later, by the cut at crossings) stay as they are.
  if (ask.tie_level && ask.strand_keep > kOrganicTestRatio + 1e-12) {
    const double gap = (ask.gap_lines > 0.0 ? ask.gap_lines : kOrganicGapLinesDefault) * domain.spec().bead_mm;
    const double cos20 = std::cos(20.0 * 3.14159265358979323846 / 180.0);
    struct Seg { Vec3 a, b; double r; std::size_t strand; };
    std::vector<Seg> segs;
    for (std::size_t t = 0; t < out.size(); ++t)
      for (std::size_t q = 0; q + 1 < out[t].points.size(); ++q)
        segs.push_back({out[t].points[q], out[t].points[q + 1], 0.25 * (out[t].width_mm[q] + out[t].width_mm[q + 1]), t});
    const double cell = 4.0;
    std::map<std::array<long long, 3>, std::vector<std::size_t>> grid;
    auto cell_of = [&](double x) { return static_cast<long long>(std::floor(x / cell)); };
    for (std::size_t i = 0; i < segs.size(); ++i) {
      const Seg& g = segs[i];
      for (long long x = cell_of(std::min(g.a.x, g.b.x)); x <= cell_of(std::max(g.a.x, g.b.x)); ++x)
        for (long long y = cell_of(std::min(g.a.y, g.b.y)); y <= cell_of(std::max(g.a.y, g.b.y)); ++y)
          for (long long z = cell_of(std::min(g.a.z, g.b.z)); z <= cell_of(std::max(g.a.z, g.b.z)); ++z) grid[{x, y, z}].push_back(i);
    }
    auto same = [](const Vec3& p, const Vec3& q) { return dist(p, q) < 1e-6; };
    std::vector<Strand> kept(out.begin(), out.begin() + static_cast<std::ptrdiff_t>(first_tie_of_traced));
    for (std::size_t t = first_tie_of_traced; t < out.size(); ++t) {
      const Strand& tie = out[t];
      const std::size_t m = tie.points.size();
      std::vector<char> bad(m > 0 ? m - 1 : 0, 0);
      for (std::size_t q = 0; q + 1 < m; ++q) {
        const Vec3 &a = tie.points[q], &b = tie.points[q + 1];
        const double r = 0.25 * (tie.width_mm[q] + tie.width_mm[q + 1]);
        const Vec3 d1{b.x - a.x, b.y - a.y, b.z - a.z};
        const double l1 = std::sqrt(d1.x * d1.x + d1.y * d1.y + d1.z * d1.z);
        if (!(l1 > 0.0)) continue;
        const double reach = r + gap + 2.0;   // the widest a neighbour may be (its radius, under 2 mm)
        std::vector<std::size_t> near;
        for (long long x = cell_of(std::min(a.x, b.x) - reach); x <= cell_of(std::max(a.x, b.x) + reach); ++x)
          for (long long y = cell_of(std::min(a.y, b.y) - reach); y <= cell_of(std::max(a.y, b.y) + reach); ++y)
            for (long long z = cell_of(std::min(a.z, b.z) - reach); z <= cell_of(std::max(a.z, b.z) + reach); ++z) {
              auto it = grid.find({x, y, z});
              if (it != grid.end()) near.insert(near.end(), it->second.begin(), it->second.end());
            }
        std::sort(near.begin(), near.end());
        near.erase(std::unique(near.begin(), near.end()), near.end());
        for (std::size_t i : near) {
          const Seg& g = segs[i];
          if (g.strand == t) continue;
          if (same(g.a, a) || same(g.a, b) || same(g.b, a) || same(g.b, b)) continue;   // it joins it there
          const Vec3 d2{g.b.x - g.a.x, g.b.y - g.a.y, g.b.z - g.a.z};
          const double l2 = std::sqrt(d2.x * d2.x + d2.y * d2.y + d2.z * d2.z);
          if (!(l2 > 0.0) || std::fabs(d1.x * d2.x + d1.y * d2.y + d1.z * d2.z) / (l1 * l2) < cos20) continue;
          if (segments_apart(a, b, g.a, g.b) - r - g.r < gap) { bad[q] = 1; break; }
        }
      }
      Strand piece = tie;
      piece.points.clear();
      piece.width_mm.clear();
      auto flush_piece = [&] {
        if (piece.points.size() >= 2) kept.push_back(piece);
        piece.points.clear();
        piece.width_mm.clear();
      };
      for (std::size_t q = 0; q + 1 < m; ++q) {
        if (bad[q]) { flush_piece(); continue; }
        if (piece.points.empty()) { piece.points.push_back(tie.points[q]); piece.width_mm.push_back(tie.width_mm[q]); }
        piece.points.push_back(tie.points[q + 1]);
        piece.width_mm.push_back(tie.width_mm[q + 1]);
        if (stats) ++stats->og3_tie_segments_kept;
      }
      flush_piece();
      if (stats) for (char x : bad) stats->og3_tie_segments_cut += x;
    }
    out.swap(kept);
  }
  // OG1 (brief E6): each point's local spacing (the spacing the tracer used there) and what set it (the asked spacing's
  // reason, or the tracer's floor where it raised the asked spacing); with the gap on, the cap on every width (curves,
  // connectors and level ties alike).
  {
    std::vector<std::uint8_t> why(n, 0);
    for (std::size_t e = 0; e < n; ++e) {
      if (!candidate[e]) continue;
      why[e] = lat.spacing_used_mm[e] > spacing[e] + 1e-9 ? static_cast<std::uint8_t>(SpacingWhy::Floor) : asked.why[e];
    }
    const double gap = ask.gap_lines > 0.0 ? ask.gap_lines * domain.spec().bead_mm : 0.0;
    const std::size_t lowered =
        organic_gap_cap(out, 0, field, lat.spacing_used_mm, why, gap, domain.spec().bead_mm * domain.spec().min_strut_lines);
    if (stats) stats->gap_capped = lowered;
  }
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

namespace {
// OP11 (brief C2, E7): the one-ask lay is one group holding every weave region of the settings (in their order).
std::vector<OrganicGroup> one_group(const Settings& settings, const OrganicAsk& ask) {
  OrganicGroup g;
  g.ask = ask;
  for (const Settings::RegionAsk& r : settings.regions)
    if (r.weave && r.role == Role::Lattice) g.regions.push_back(r.id);
  return {g};
}
// The least distance between two segments.
double segments_apart(const Vec3& p1, const Vec3& q1, const Vec3& p2, const Vec3& q2) {
  const Vec3 d1{q1.x - p1.x, q1.y - p1.y, q1.z - p1.z}, d2{q2.x - p2.x, q2.y - p2.y, q2.z - p2.z};
  const Vec3 r{p1.x - p2.x, p1.y - p2.y, p1.z - p2.z};
  auto dot = [](const Vec3& u, const Vec3& v) { return u.x * v.x + u.y * v.y + u.z * v.z; };
  const double a = dot(d1, d1), e = dot(d2, d2), f = dot(d2, r);
  double s = 0.0, t = 0.0;
  if (a <= 1e-18 && e <= 1e-18) return dist(p1, p2);
  if (a <= 1e-18) {
    t = std::clamp(f / e, 0.0, 1.0);
  } else {
    const double c = dot(d1, r);
    if (e <= 1e-18) {
      s = std::clamp(-c / a, 0.0, 1.0);
    } else {
      const double bb = dot(d1, d2), den = a * e - bb * bb;
      s = den > 1e-18 ? std::clamp((bb * f - c * e) / den, 0.0, 1.0) : 0.0;
      t = (bb * s + f) / e;
      if (t < 0.0) { t = 0.0; s = std::clamp(-c / a, 0.0, 1.0); }
      else if (t > 1.0) { t = 1.0; s = std::clamp((bb - c) / a, 0.0, 1.0); }
    }
  }
  return dist(Vec3{p1.x + d1.x * s, p1.y + d1.y * s, p1.z + d1.z * s}, Vec3{p2.x + d2.x * t, p2.y + d2.y * t, p2.z + d2.z * t});
}
// OP11: bar pairs of different groups closer than the sum of their half widths (sweep over x).
std::size_t cross_group_touches(const Bars& bars, const std::vector<OrganicGroup>& groups) {
  struct Item { double lo, hi; std::size_t bar; int group; };
  std::vector<Item> items;
  for (std::size_t i = 0; i < bars.bars.size(); ++i) {
    const Bar& x = bars.bars[i];
    int g = -1;
    for (std::size_t k = 0; k < groups.size() && g < 0; ++k)
      if (std::find(groups[k].regions.begin(), groups[k].regions.end(), x.region) != groups[k].regions.end())
        g = static_cast<int>(k);
    if (g < 0) continue;
    items.push_back({std::min(x.a.x, x.b.x) - 0.5 * x.width, std::max(x.a.x, x.b.x) + 0.5 * x.width, i, g});
  }
  std::sort(items.begin(), items.end(), [](const Item& p, const Item& q) { return p.lo < q.lo || (p.lo == q.lo && p.bar < q.bar); });
  std::size_t n = 0;
  for (std::size_t i = 0; i < items.size(); ++i)
    for (std::size_t j = i + 1; j < items.size() && items[j].lo <= items[i].hi; ++j) {
      if (items[j].group == items[i].group) continue;
      const Bar& x = bars.bars[items[i].bar];
      const Bar& y = bars.bars[items[j].bar];
      if (segments_apart(x.a, x.b, y.a, y.b) < 0.5 * (x.width + y.width)) ++n;
    }
  return n;
}

// OG2 (brief E6): the relief. Per weave bar (not a net strut) end of kind Surface whose group asks for it, in bar order.
// The face there: the nearest triangle of the part as opened (its face id, StepModel::triangle_face); the outward normal:
// minus the gradient of the part's depth at the end (central differences, 0.05 mm). Left flush, in this order: the face
// is excluded; the normal points down against the build direction by more than 45 degrees; the end is 2 mm or less above
// the bed (the part's lowest point along the build direction), or the proud tip, less its cap's radius, would reach it;
// the bar leaves the surface at less than 20 degrees. Otherwise the end is carried on along its bar by p / cos, p =
// face_relief_mm x u, u in (0, 1] fixed by (strand, region).
struct TriFinder {
  const TriangleMesh* m = nullptr;
  Vec3 lo{};
  double cell = 2.0;
  int n[3] = {0, 0, 0};
  std::vector<std::vector<std::uint32_t>> at;
  explicit TriFinder(const TriangleMesh& mesh) : m(&mesh) {
    if (mesh.vertices.empty()) return;
    Vec3 hi = mesh.vertices.front();
    lo = hi;
    for (const Vec3& v : mesh.vertices) {
      lo = {std::min(lo.x, v.x), std::min(lo.y, v.y), std::min(lo.z, v.z)};
      hi = {std::max(hi.x, v.x), std::max(hi.y, v.y), std::max(hi.z, v.z)};
    }
    lo = {lo.x - 1.0, lo.y - 1.0, lo.z - 1.0};
    n[0] = std::max(1, static_cast<int>(std::ceil((hi.x + 1.0 - lo.x) / cell)));
    n[1] = std::max(1, static_cast<int>(std::ceil((hi.y + 1.0 - lo.y) / cell)));
    n[2] = std::max(1, static_cast<int>(std::ceil((hi.z + 1.0 - lo.z) / cell)));
    at.resize(static_cast<std::size_t>(n[0]) * n[1] * n[2]);
    for (std::size_t t = 0; t < mesh.triangles.size(); ++t) {
      Vec3 a = mesh.vertices[static_cast<std::size_t>(mesh.triangles[t][0])], b = a;
      for (int k = 1; k < 3; ++k) {
        const Vec3& v = mesh.vertices[static_cast<std::size_t>(mesh.triangles[t][static_cast<std::size_t>(k)])];
        a = {std::min(a.x, v.x), std::min(a.y, v.y), std::min(a.z, v.z)};
        b = {std::max(b.x, v.x), std::max(b.y, v.y), std::max(b.z, v.z)};
      }
      const int i0 = slot(a.x - lo.x, 0), i1 = slot(b.x - lo.x, 0), j0 = slot(a.y - lo.y, 1), j1 = slot(b.y - lo.y, 1),
                k0 = slot(a.z - lo.z, 2), k1 = slot(b.z - lo.z, 2);
      for (int k = k0; k <= k1; ++k)
        for (int j = j0; j <= j1; ++j)
          for (int i = i0; i <= i1; ++i) at[(static_cast<std::size_t>(k) * n[1] + j) * n[0] + i].push_back(static_cast<std::uint32_t>(t));
    }
  }
  int slot(double x, int a) const { return std::clamp(static_cast<int>(std::floor(x / cell)), 0, n[a] - 1); }
  static double to_tri(const Vec3& p, const Vec3& a, const Vec3& b, const Vec3& c) {
    auto sub = [](const Vec3& u, const Vec3& v) { return Vec3{u.x - v.x, u.y - v.y, u.z - v.z}; };
    auto dot = [](const Vec3& u, const Vec3& v) { return u.x * v.x + u.y * v.y + u.z * v.z; };
    const Vec3 ab = sub(b, a), ac = sub(c, a), ap = sub(p, a);
    const double d1 = dot(ab, ap), d2 = dot(ac, ap);
    if (d1 <= 0 && d2 <= 0) return dist(p, a);
    const Vec3 bp = sub(p, b);
    const double d3 = dot(ab, bp), d4 = dot(ac, bp);
    if (d3 >= 0 && d4 <= d3) return dist(p, b);
    const double vc = d1 * d4 - d3 * d2;
    if (vc <= 0 && d1 >= 0 && d3 <= 0) { const double v = d1 / (d1 - d3); return dist(p, Vec3{a.x + ab.x * v, a.y + ab.y * v, a.z + ab.z * v}); }
    const Vec3 cp = sub(p, c);
    const double d5 = dot(ab, cp), d6 = dot(ac, cp);
    if (d6 >= 0 && d5 <= d6) return dist(p, c);
    const double vb = d5 * d2 - d1 * d6;
    if (vb <= 0 && d2 >= 0 && d6 <= 0) { const double w = d2 / (d2 - d6); return dist(p, Vec3{a.x + ac.x * w, a.y + ac.y * w, a.z + ac.z * w}); }
    const double va = d3 * d6 - d5 * d4;
    if (va <= 0 && (d4 - d3) >= 0 && (d5 - d6) >= 0) {
      const double w = (d4 - d3) / ((d4 - d3) + (d5 - d6));
      return dist(p, Vec3{b.x + (c.x - b.x) * w, b.y + (c.y - b.y) * w, b.z + (c.z - b.z) * w});
    }
    const double den = 1.0 / (va + vb + vc), v = vb * den, w = vc * den;
    return dist(p, Vec3{a.x + ab.x * v + ac.x * w, a.y + ab.y * v + ac.y * w, a.z + ab.z * v + ac.z * w});
  }
  // The nearest triangle to p among those in p's cell (an end on the surface lies in its triangle's cell); -1 for none.
  long nearest(const Vec3& p) const {
    if (at.empty()) return -1;
    const std::size_t c = (static_cast<std::size_t>(slot(p.z - lo.z, 2)) * n[1] + slot(p.y - lo.y, 1)) * n[0] + slot(p.x - lo.x, 0);
    long best = -1;
    double bd = std::numeric_limits<double>::infinity();
    for (std::uint32_t t : at[c]) {
      const auto& q = m->triangles[t];
      const double d = to_tri(p, m->vertices[static_cast<std::size_t>(q[0])], m->vertices[static_cast<std::size_t>(q[1])],
                              m->vertices[static_cast<std::size_t>(q[2])]);
      if (d < bd) { bd = d; best = static_cast<long>(t); }
    }
    return best;
  }
};

double relief_share(int strand, int region) {   // u in (0, 1], fixed by the strand and its region (splitmix64)
  std::uint64_t x = (static_cast<std::uint64_t>(static_cast<std::uint32_t>(strand)) << 32) ^
                    static_cast<std::uint64_t>(static_cast<std::uint32_t>(region)) ^ 0x9E3779B97F4A7C15ULL;
  x = (x ^ (x >> 30)) * 0xBF58476D1CE4E5B9ULL;
  x = (x ^ (x >> 27)) * 0x94D049BB133111EBULL;
  x ^= x >> 31;
  return static_cast<double>((x >> 11) + 1) * (1.0 / 9007199254740992.0);
}

void lay_relief(Bars& bars, const StepModel& model, const PartMeasure& part, const std::vector<OrganicGroup>& groups,
                const std::vector<std::size_t>& first_strand, Outcome::Relief& rep, const std::vector<int>& covered = {}) {
  rep = Outcome::Relief{};
  const OrganicGroup* of_region_cache = nullptr;
  auto group_of = [&](int region) -> const OrganicGroup* {
    if (of_region_cache && std::find(of_region_cache->regions.begin(), of_region_cache->regions.end(), region) != of_region_cache->regions.end())
      return of_region_cache;
    for (const OrganicGroup& g : groups)
      if (std::find(g.regions.begin(), g.regions.end(), region) != g.regions.end()) return of_region_cache = &g;
    return nullptr;
  };
  bool any = false;
  for (const OrganicGroup& g : groups) any = any || g.ask.face_relief_mm > 0.0;
  if (!any) return;
  rep.faces_known = model.triangle_face.size() == model.mesh.triangles.size() && !model.mesh.triangles.empty();
  std::unique_ptr<TriFinder> finder;
  std::map<const OrganicGroup*, double> beds;   // the bed along each group's build direction
  const PartMeasure::Probe probe = part.probe();
  const Vec3 plo = part.lo(), phi = part.hi();
  const double kDown = std::cos(45.0 * 3.14159265358979323846 / 180.0), kAlong = std::sin(20.0 * 3.14159265358979323846 / 180.0);
  // OG2b (brief E6, leg B; the owner: "Depth variation means to not cut entirely along the plane!"): a weave bar (strands,
  // links, level ties, braces and supports alike; not a net strut) whose tube reaches the part's surface (the depth
  // along its line, read every 0.25 mm, under its radius) where the face is not excluded, its outward normal not down
  // more than 45 degrees and the place more than 2 mm above the bed, gets along_proud = face_relief_mm: its tube keeps
  // its own bulge out of the surface, cut only where it would stand more than that. No hash: the heights come from the
  // bars' own depths. The bar is not moved.
  for (Bar& b : bars.bars) {
    if (b.net) continue;
    if (std::find(covered.begin(), covered.end(), b.region) != covered.end()) continue;   // OJ2: Solid: no relief
    const OrganicGroup* g = group_of(b.region);
    if (!g || !(g->ask.face_relief_mm > 0.0)) continue;
    const OrganicAsk& ask = g->ask;
    const double r = 0.5 * b.width, L = dist(b.a, b.b);
    const Vec3 mid{0.5 * (b.a.x + b.b.x), 0.5 * (b.a.y + b.b.y), 0.5 * (b.a.z + b.b.z)};
    if (probe.depth(mid) > 0.5 * L + r) continue;   // nowhere on it within r of the surface
    const int k = std::max(1, static_cast<int>(std::ceil(L / 0.25)));
    double least = std::numeric_limits<double>::infinity();
    Vec3 at{};
    for (int q = 0; q <= k; ++q) {
      const double t = static_cast<double>(q) / k;
      const Vec3 p{b.a.x + (b.b.x - b.a.x) * t, b.a.y + (b.b.y - b.a.y) * t, b.a.z + (b.b.z - b.a.z) * t};
      const double d = probe.depth(p);
      if (d < least) { least = d; at = p; }
    }
    if (!(least < r)) continue;
    const double h = 0.05;
    Vec3 nrm{probe.depth(Vec3{at.x - h, at.y, at.z}) - probe.depth(Vec3{at.x + h, at.y, at.z}),
             probe.depth(Vec3{at.x, at.y - h, at.z}) - probe.depth(Vec3{at.x, at.y + h, at.z}),
             probe.depth(Vec3{at.x, at.y, at.z - h}) - probe.depth(Vec3{at.x, at.y, at.z + h})};
    const double nl = std::sqrt(nrm.x * nrm.x + nrm.y * nrm.y + nrm.z * nrm.z);
    const double ul = std::sqrt(ask.build_dir.x * ask.build_dir.x + ask.build_dir.y * ask.build_dir.y + ask.build_dir.z * ask.build_dir.z);
    if (!(nl > 0.0) || !(ul > 0.0)) continue;
    nrm = {nrm.x / nl, nrm.y / nl, nrm.z / nl};
    const Vec3 up{ask.build_dir.x / ul, ask.build_dir.y / ul, ask.build_dir.z / ul};
    if (nrm.x * up.x + nrm.y * up.y + nrm.z * up.z < -kDown) continue;
    auto found = beds.find(g);
    if (found == beds.end()) {
      double lowest = std::numeric_limits<double>::infinity();
      for (const Vec3& v : part.mesh().vertices) lowest = std::min(lowest, v.x * up.x + v.y * up.y + v.z * up.z);
      found = beds.emplace(g, lowest).first;
    }
    const Vec3 on{at.x + nrm.x * least, at.y + nrm.y * least, at.z + nrm.z * least};   // the surface there
    if (!(on.x * up.x + on.y * up.y + on.z * up.z - found->second > 2.0)) continue;
    int face = -1;   // leg H: the face it lies along, for the app's drawing (read whenever the model carries faces)
    if (rep.faces_known) {
      if (!finder) finder = std::make_unique<TriFinder>(model.mesh);
      const long t = finder->nearest(on);
      face = t >= 0 ? model.triangle_face[static_cast<std::size_t>(t)] : -1;
      if (std::find(ask.relief_exclude_faces.begin(), ask.relief_exclude_faces.end(), face) != ask.relief_exclude_faces.end())
        continue;
    }
    b.along_proud = ask.face_relief_mm;
    b.along_face = face;
    ++rep.along;
    rep.along_largest_mm = std::max(rep.along_largest_mm, b.along_proud);
  }
  for (Bar& b : bars.bars) {
    if (b.net) continue;
    for (int e = 0; e < 2; ++e) {
      if ((e == 0 ? b.end_a : b.end_b) != Bar::End::Surface) continue;
      if (std::find(covered.begin(), covered.end(), b.region) != covered.end()) continue;   // OJ2
      const OrganicGroup* g = group_of(b.region);
      if (!g || !(g->ask.face_relief_mm > 0.0)) continue;
      const OrganicAsk& ask = g->ask;
      ++rep.surface_ends;
      Vec3& end = e == 0 ? b.a : b.b;
      const Vec3& other = e == 0 ? b.b : b.a;
      if (rep.faces_known && !ask.relief_exclude_faces.empty()) {
        if (!finder) finder = std::make_unique<TriFinder>(model.mesh);
        const long t = finder->nearest(end);
        const int face = t >= 0 ? model.triangle_face[static_cast<std::size_t>(t)] : -1;
        if (std::find(ask.relief_exclude_faces.begin(), ask.relief_exclude_faces.end(), face) != ask.relief_exclude_faces.end()) {
          ++rep.flush_excluded;
          continue;
        }
      }
      const double h = 0.05;
      Vec3 nrm{probe.depth(Vec3{end.x - h, end.y, end.z}) - probe.depth(Vec3{end.x + h, end.y, end.z}),
               probe.depth(Vec3{end.x, end.y - h, end.z}) - probe.depth(Vec3{end.x, end.y + h, end.z}),
               probe.depth(Vec3{end.x, end.y, end.z - h}) - probe.depth(Vec3{end.x, end.y, end.z + h})};
      const double nl = std::sqrt(nrm.x * nrm.x + nrm.y * nrm.y + nrm.z * nrm.z);
      const double ul = std::sqrt(ask.build_dir.x * ask.build_dir.x + ask.build_dir.y * ask.build_dir.y + ask.build_dir.z * ask.build_dir.z);
      if (!(nl > 0.0) || !(ul > 0.0)) { ++rep.flush_along; continue; }
      nrm = {nrm.x / nl, nrm.y / nl, nrm.z / nl};
      const Vec3 up{ask.build_dir.x / ul, ask.build_dir.y / ul, ask.build_dir.z / ul};
      if (nrm.x * up.x + nrm.y * up.y + nrm.z * up.z < -kDown) { ++rep.flush_down; continue; }
      auto found = beds.find(g);
      if (found == beds.end()) {
        double lowest = std::numeric_limits<double>::infinity();
        for (const Vec3& v : part.mesh().vertices) lowest = std::min(lowest, v.x * up.x + v.y * up.y + v.z * up.z);
        found = beds.emplace(g, lowest).first;
      }
      const double bed = found->second;
      const double height = end.x * up.x + end.y * up.y + end.z * up.z - bed;
      if (!(height > 2.0)) { ++rep.flush_bed; continue; }
      const double L = dist(end, other);
      if (!(L > 0.0)) { ++rep.flush_along; continue; }
      const Vec3 d{(end.x - other.x) / L, (end.y - other.y) / L, (end.z - other.z) / L};
      const double c = d.x * nrm.x + d.y * nrm.y + d.z * nrm.z;
      if (!(c >= kAlong)) { ++rep.flush_along; continue; }
      // The strand's number within its group (OP11: a group laid alone or with others gives the same relief).
      const std::size_t gi = static_cast<std::size_t>(g - groups.data());
      const long first = gi < first_strand.size() ? static_cast<long>(first_strand[gi]) : 0L;
      const double p = ask.face_relief_mm * relief_share(static_cast<int>(b.strand - first), b.region);
      const double run = p / c;
      const Vec3 tip{end.x + d.x * run, end.y + d.y * run, end.z + d.z * run};
      const double r = 0.5 * b.width;
      if (!(tip.x * up.x + tip.y * up.y + tip.z * up.z - r - bed > 0.0)) { ++rep.flush_bed; continue; }
      end = tip;
      (e == 0 ? b.proud_a : b.proud_b) = p;
      (e == 0 ? b.relief_a : b.relief_b) = run;
      ++rep.proud;
      rep.largest_mm = std::max(rep.largest_mm, p);
      rep.grew_mm[0] = std::max(rep.grew_mm[0], plo.x - (tip.x - r));
      rep.grew_mm[1] = std::max(rep.grew_mm[1], tip.x + r - phi.x);
      rep.grew_mm[2] = std::max(rep.grew_mm[2], plo.y - (tip.y - r));
      rep.grew_mm[3] = std::max(rep.grew_mm[3], tip.y + r - phi.y);
      rep.grew_mm[4] = std::max(rep.grew_mm[4], plo.z - (tip.z - r));
      rep.grew_mm[5] = std::max(rep.grew_mm[5], tip.z + r - phi.z);
    }
  }
}

// OG1's diagnosis (Outcome::Tight) over the weave bars of `weave` (net struts left out).
Outcome::Tight tight_of(const Bars& bars, const std::vector<int>& weave, double line_mm) {
  Outcome::Tight t;
  t.line_mm = line_mm;
  for (const Bar& b : bars.bars) {
    if (b.net || std::find(weave.begin(), weave.end(), b.region) == weave.end()) continue;
    ++t.bars;
    const bool known = b.local_mm > 0.0;
    const double local = known ? b.local_mm : b.cell;
    if (!(local - b.width < line_mm)) continue;
    ++t.tight;
    t.supports += b.support;
    t.links += b.link;
    t.braces += b.brace;
    switch (known ? static_cast<SpacingWhy>(b.local_why) : (b.support ? SpacingWhy::Hold : SpacingWhy::None)) {
      case SpacingWhy::Stress: ++t.stress; break;
      case SpacingWhy::Shape: ++t.shape; break;
      case SpacingWhy::Hold: ++t.hold; break;
      case SpacingWhy::Floor: ++t.floor; break;
      case SpacingWhy::Uniform: ++t.uniform; break;
      default: ++t.unknown; break;
    }
  }
  return t;
}
}  // namespace

Outcome Session::lay_organic(const Settings& settings, const TensorField& field, const OrganicAsk& ask, int threads,
                             const std::atomic<bool>* stop) {
  return lay_organic_with(settings, field, one_group(settings, ask), threads, stop, false);
}

Outcome Session::lay_organic_draft(const Settings& settings, const TensorField& field, const OrganicAsk& ask,
                                   int threads, const std::atomic<bool>* stop) {
  return lay_organic_with(settings, field, one_group(settings, ask), threads, stop, true);
}

Outcome Session::lay_organic(const Settings& settings, const TensorField& field, const std::vector<OrganicGroup>& groups,
                             int threads, const std::atomic<bool>* stop) {
  return lay_organic_with(settings, field, groups, threads, stop, false);
}

Outcome Session::lay_organic_draft(const Settings& settings, const TensorField& field,
                                   const std::vector<OrganicGroup>& groups, int threads, const std::atomic<bool>* stop) {
  return lay_organic_with(settings, field, groups, threads, stop, true);
}

Outcome Session::lay_organic_with(const Settings& asked, const TensorField& field, const std::vector<OrganicGroup>& groups,
                                  int threads, const std::atomic<bool>* stop, bool draft) {
  if (stop && stop->load(std::memory_order_relaxed)) {
    Outcome none;
    none.cancelled = true;
    return none;
  }
  // OP7 (brief C2, E1; OP11, E7: per group): an ask validate_organic refuses comes back refused, every refusal listed,
  // before the domain is made (the kept domain, and what the caller holds of the last lay, stay as they were). With no
  // weave region the asks are not read (it is lay()).
  bool any_weave = false;
  for (const Settings::RegionAsk& r : asked.regions) any_weave = any_weave || (r.weave && r.role == Role::Lattice);
  if (any_weave) {
    std::vector<OrganicRefusal> refused = validate_organic_groups(asked, groups, &field);
    if (!refused.empty()) {
      Outcome no;
      no.refused = std::move(refused);
      return no;
    }
  }
  // OP9 (brief C2, E3): K1's flat floor from the ask, exactly as the file job copies it into the settings (Q1): the
  // floor lives in the domain ("where"), so the growth, the trace, the path and the net skin all see it. One floor for
  // the part: the first group's (validate_organic_groups refuses groups that differ).
  Settings settings = asked;
  if (!groups.empty() && groups.front().ask.bed_floor_mm > 0.0) {
    settings.bed_floor_mm = groups.front().ask.bed_floor_mm;
    settings.bed_up = groups.front().ask.build_dir;
  }
  // OR30: the Finish is the regular lattices' own. Rim and Covered are "where" settings of the domain the weave is
  // traced and laid in (their solid cuts the strands as any solid does); Skin lays the net skin (O16).
  ready_domain(settings);
  WeaveFinish finish;
  finish.draft = draft;                 // brief L2, item 3
  const auto t0 = std::chrono::steady_clock::now();
  std::vector<Strand> strands;
  double smallest = 0.0, largest = 0.0, sum = 0.0;
  std::size_t candidates = 0;
  std::shared_ptr<GrowReport> grown;
  std::vector<std::string> notes;
  std::vector<std::pair<int, double>> all_references;   // brief E2: every weave region's O12 reference, group by group
  std::size_t gap_capped = 0;                            // OG1
  // OP11 (brief C2, E7): each group in turn, on its own regions (in the domain's order) with its own ask; its spacing's
  // weave (the reference, the stretch, the outline) is its own regions only. One group: exactly the one-ask lay.
  for (const OrganicGroup& group : groups) {
    const OrganicAsk& ask = group.ask;
    const std::vector<int>* pool = &group.regions;
    WeaveFinish::Group gf;
    gf.first = strands.size();
    // S (brief G28): the cut at crossings judges by the light width (the growth's and the tracer's), never by I1 / Q2's.
    gf.light_mm = ask.width_mm > 0.0 ? ask.width_mm : domain_->spec().bead_mm * domain_->spec().min_strut_lines;
    gf.layer_mm = ask.layer_mm;
    gf.link_width = ask.link_width;   // S8
    std::vector<std::pair<int, double>> references;   // T fix: each weave region's O12 reference, as computed once
    for (const Region& r : domain_->spec().regions) {
      if (r.role != Role::Lattice || !r.weave) continue;
      if (std::find(group.regions.begin(), group.regions.end(), r.id) == group.regions.end()) continue;
      OrganicTraceStats st;
      std::vector<Strand> traced;
      // O16, the net skin's reach: Traced, the trace's own median spacing (as the old run); Grown, which has no trace,
      // the median of the spacing field over the region's candidates (the field it is laid with). LatticeReview's
      // ruling 2 (2026-11-15) asked the field's median for both; on the made-up cube it changed Traced's net from 5,145
      // struts (12,626 mm) to 5,932 (24,424 mm), so Traced keeps its own until that is ruled on.
      const OrganicSpacing sp =
          ask.mode == OrganicMode::Grown ? organic_spacing(*domain_, r.id, field, ask, pool) : OrganicSpacing{};
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
        gap_capped += one.gap_capped;   // OG1
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
        traced = trace_strands(*domain_, r.id, field, ask, &st, pool);
        gap_capped += st.gap_capped;   // OG1
      }
      const double reach = ask.mode == OrganicMode::Grown ? median : st.spacing_median_mm;
      // O16, per region (leg J item 1): the region's own Skin and width, else the part's.
      const Settings::RegionAsk* own = nullptr;
      for (const Settings::RegionAsk& ra : settings.regions)
        if (ra.id == r.id) own = &ra;
      const bool skin_here = own && own->skin ? *own->skin : settings.skin;
      finish.net_on = finish.net_on || skin_here;
      // A face closed by a cover (the area's Solid, or the part's Covered) carries no net: the cover is the finish there
      // (leg J fix: OJ2's open-face cover left the side walls open, and the net landed on them).
      if (skin_here && reach > 0.0 && !(domain_->cover_depth_mm(&r) > 0.0)) {
        finish.net_reach.push_back({r.id, reach});
        finish.net_width.push_back(own && own->skin_width_mm ? *own->skin_width_mm : settings.skin_spec.width_mm);
        finish.net_gap.push_back(ask.gap_lines > 0.0 ? ask.gap_lines * domain_->spec().bead_mm : domain_->spec().bead_mm);   // OJ7
      }
      if (ask.mode == OrganicMode::Grown) finish.arrived.push_back(r.id);   // G11: a vine that reached the surface
      if (ask.mode == OrganicMode::Grown && ask.prune) finish.prune.push_back({r.id, median});   // J2
      // L2 d; Q3 (brief G24): Traced lays the same supports, from the floating pieces its own trace's spacing found.
      const std::vector<OrganicSpacing::HoldPatch>& patches =
          ask.mode == OrganicMode::Grown ? sp.hold_patches : st.hold_patches;
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
    gf.brace = organic_brace_ask(*domain_, field, ask, references);   // T (off unless unbraced_max)
    all_references.insert(all_references.end(), references.begin(), references.end());
    gf.count = strands.size() - gf.first;
    finish.groups.push_back(std::move(gf));
    // OP8 (brief C2, E2): equal cell ends with a heavy end set: laid, and said (once).
    if (ask.spacing_mm == 0.0 && ask.spacing_max_mm == ask.spacing_min_mm &&
        (ask.width_heavy_mm > 0.0 || ask.wall_gap_heavy > 0.0 || ask.cross_gap_heavy > 0.0 || ask.tie_gap_heavy > 0.0) &&
        std::find(notes.begin(), notes.end(), std::string(kNoteEqualEnds)) == notes.end())
      notes.push_back(kNoteEqualEnds);
  }
  const double ms_trace = std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - t0).count();
  Outcome out = lay_with(settings, &strands, threads, stop, &finish);
  if (!out.cancelled) {
    // OG2 (brief E6): the ends carried proud of the open faces, on the bars as laid (before the floors and additions,
    // which are made on these bars).
    std::vector<std::size_t> firsts;
    for (const WeaveFinish::Group& gf : finish.groups) firsts.push_back(gf.first);
    std::vector<int> covered;   // OJ2 (ruling 2): depth variation is off on a face with a Solid finish
    for (const Region& rg : domain_->spec().regions)
      if (rg.weave && domain_->cover_depth_mm(&rg) > 0.0) covered.push_back(rg.id);
    lay_relief(out.bars, model_, *measure_, groups, firsts, out.relief, covered);
    out.organic_references = all_references;   // brief E2
    // Brief E2 and E3a (the strength check's floors and additions) are made for ONE ask (the file job's, and a preview
    // of it): they are read from a lay of one group (OP11); a lay of several groups does not apply them.
    const OrganicAsk ask = groups.empty() ? OrganicAsk{} : groups.front().ask;
    const double light_mm = finish.groups.empty() ? 0.0 : finish.groups.front().light_mm;
    const bool one = groups.size() == 1;
    // Brief E2, item 9: the width floors, last, only with the strut width on a Sweep. OJ4 (leg J item 4): the floors
    // (the first group's list: the strengthen job makes one for the whole lay) applied group by group, each to its own
    // regions with its own upper and light widths.
    if (one && !ask.floors.empty() && ask.width_heavy_mm > 0.0)
      out.floors_widened = apply_width_floors(out.bars, ask.floors, ask.width_heavy_mm, light_mm, ask.link_width,
                                              &out.floor_links_widened);
    if (!one && !ask.floors.empty())
      for (std::size_t g = 0; g < groups.size() && g < finish.groups.size(); ++g) {
        const OrganicAsk& ga = groups[g].ask;
        if (!(ga.width_heavy_mm > 0.0)) continue;
        std::size_t links = 0;
        out.floors_widened += apply_width_floors(out.bars, ask.floors, ga.width_heavy_mm, finish.groups[g].light_mm,
                                                 ga.link_width, &links, &groups[g].regions);
        out.floor_links_widened += links;
      }
    // OG5 (brief E9): the lay's bars were guarded before its drop (Session::lay_with); the floors may widen a bar, so
    // they are guarded again when they did (nothing is dropped here: a widened bar's run-on is only cut back).
    std::vector<int> weave_ids;
    for (const Layout::Weave& w : out.layout.weave) weave_ids.push_back(w.region);
    const double line_mm = domain_->spec().bead_mm;
    if (out.floors_widened > 0) guard_bars(out.bars, *domain_, weave_ids, line_mm, &out.guard);
    // Brief E3a: what strengthening by adding added, in order, each round's hash checked; a mismatch is refused. The
    // draft (no cut at crossings) is not the lattice they were made on: it shows the lay without them.
    if (!ask.additions.empty() && !draft) {
      AddContext c;
      c.light_mm = light_mm;
      c.layer_mm = ask.layer_mm;
      c.link_width = ask.link_width;
      if (!one)   // OJ4: each region with its group's widths
        for (std::size_t g = 0; g < groups.size() && g < finish.groups.size(); ++g)
          for (int rid : groups[g].regions)
            c.per_region[rid] = {finish.groups[g].light_mm, groups[g].ask.layer_mm, groups[g].ask.link_width};
      c.weave_regions = weave_ids;   // OG5: each round's bars guarded before its print check and hash
      c.line_mm = line_mm;
      c.guard = &out.guard;
      std::string why;
      // OS16: the print check before the first round, and (apply_additions) after each.
      if (ask.print_check) {
        const std::string w = ask.print_check(out.layout, out.bars);
        if (!w.empty()) why = "before round 1: " + w;
      }
      std::function<std::string(Bars&)> between;
      if (ask.print_check) between = [&](Bars& b) { return ask.print_check(out.layout, b); };
      if (why.empty() && apply_additions(out.bars, *domain_, ask.additions, c, &why, between)) {
        out.additions_rounds = ask.additions.rounds.size();
      } else {
        out.additions_refused = why;
        out.bars.bars.clear();
      }
    }
    out.strands = strands.size();
    out.ms_trace = ms_trace;
    out.spacing_smallest_mm = smallest;
    out.spacing_largest_mm = largest;
    out.spacing_mean_mm = candidates ? sum / static_cast<double>(candidates) : 0.0;
    out.grown = grown;
    out.notes = std::move(notes);
    if (groups.size() > 1) out.cross_group_touches = cross_group_touches(out.bars, groups);   // OP11
    // OG1 (brief E6): what the gap rule lowered, what the floors and additions broke of it, and the diagnosis.
    out.gap_capped = gap_capped;
    out.gap_broken = gap_broken(out.bars);
    std::vector<int> weave;
    for (const Layout::Weave& w : out.layout.weave) weave.push_back(w.region);
    out.tight = tight_of(out.bars, weave, domain_->spec().bead_mm);
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

// ── OP7 (brief C2, E1): one validation call for an Organic ask ─────────────────────────────────────────────────────
namespace {
// A number as the owner reads it: at most two decimals, no trailing zeros. `up`: rounded up to the hundredth (a
// smallest allowed value, so the number shown is itself allowed).
std::string plain_number(double x, bool up = false) {
  if (up) x = std::ceil(x * 100.0 - 1e-9) / 100.0;
  char b[48];
  std::snprintf(b, sizeof b, "%.2f", x);
  std::string t = b;
  while (!t.empty() && t.back() == '0') t.pop_back();
  if (!t.empty() && t.back() == '.') t.pop_back();
  return t == "-0" ? "0" : t;
}
std::string spacings(double x) { return plain_number(x) + (plain_number(x) == "1" ? " spacing" : " spacings"); }
bool any_weave(const Settings& s) {
  for (const Settings::RegionAsk& r : s.regions)
    if (r.weave && r.role == Role::Lattice) return true;
  return false;
}
double light_width(const Settings& s, const OrganicAsk& a) {
  const double thinnest = s.bead_mm * s.min_strut_lines;
  return a.width_mm > 0.0 && std::isfinite(a.width_mm) && a.width_mm >= thinnest - 1e-9 ? a.width_mm : thinnest;
}
}  // namespace

double organic_smallest_cell_mm(const Settings& settings, const OrganicAsk& ask) {
  return kSmallestCellFactor * light_width(settings, ask);
}

std::vector<OrganicRefusal> validate_organic(const Settings& settings, const OrganicAsk& a, const TensorField* field) {
  std::vector<OrganicRefusal> out;
  auto refuse = [&](const char* setting, const char* code, const std::string& text, double given) -> OrganicRefusal& {
    OrganicRefusal r;
    r.setting = setting;
    r.code = code;
    r.text = text;
    r.given = given;
    out.push_back(r);
    return out.back();
  };
  auto at_least = [](OrganicRefusal& r, double v) { r.has_min = true; r.allowed_min = v; };
  auto at_most = [](OrganicRefusal& r, double v) { r.has_max = true; r.allowed_max = v; };
  auto fin = [](double v) { return std::isfinite(v); };
  const bool grown = a.mode == OrganicMode::Grown;
  const double thinnest = settings.bead_mm * settings.min_strut_lines;
  if (!(fin(thinnest) && thinnest > 0.0))
    refuse("bead_mm", "no_thinnest_strut", "Line width: the printer's line width and strut lines must be above 0.",
           settings.bead_mm);
  // The cell size (O12).
  const bool one = a.spacing_mm > 0.0 && fin(a.spacing_mm);
  if (a.spacing_mm != 0.0 && !one)
    at_least(refuse("spacing_mm", "not_above_zero", "Cell size: the size must be above 0 mm.", a.spacing_mm), 0.0);
  bool range = false;
  if (a.spacing_mm == 0.0) {
    const bool lo_ok = fin(a.spacing_min_mm) && a.spacing_min_mm > 0.0;
    if (!lo_ok)
      at_least(refuse("spacing_min_mm", "not_above_zero", "Cell size: the small end must be above 0 mm.", a.spacing_min_mm),
               0.0);
    if (lo_ok && !(fin(a.spacing_max_mm) && a.spacing_max_mm >= a.spacing_min_mm))
      at_least(refuse("spacing_max_mm", "under_other_end",
                      "Cell size: the large end must be at least the small end (" + plain_number(a.spacing_min_mm) + " mm).",
                      a.spacing_max_mm),
               a.spacing_min_mm);
    if (!(fin(a.spacing_exponent) && a.spacing_exponent > 0.0))
      at_least(refuse("spacing_exponent", "not_above_zero", "Cell size: the grading strength must be above 0.",
                      a.spacing_exponent),
               0.0);
    // OP8 (brief C2, E2): a range whose two ends are equal is a range; the heavy ends then do not act (O12's measure
    // is 0 everywhere with one spacing) and are not refused.
    range = true;
  }
  // The struts.
  if (!(fin(a.width_mm) && a.width_mm >= 0.0))
    at_least(refuse("width_mm", "below_zero", "Strut thickness: the thin end must be 0 (the thinnest strut) or more.",
                    a.width_mm),
             0.0);
  else if (a.width_mm > 0.0 && thinnest > 0.0 && a.width_mm < thinnest - 1e-9)
    at_least(refuse("width_mm", "under_thinnest_strut",
                    "Strut thickness: the thin end must be at least " + plain_number(thinnest, true) +
                        " mm, the thinnest strut this printer makes.",
                    a.width_mm),
             thinnest);
  const double light = light_width(settings, a);
  if (!(fin(a.width_heavy_mm) && (a.width_heavy_mm == 0.0 || a.width_heavy_mm >= light - 1e-9)))
    at_least(refuse("width_heavy_mm", "under_other_end",
                    "Strut thickness: the thick end must be at least the thin end (" + plain_number(light) + " mm).",
                    a.width_heavy_mm),
             light);
  // OP7: the smallest printable cell, kSmallestCellFactor x the light width, in both modes (Traced raised it silently,
  // Grown laid it).
  // OG1: with the gap rule on, the larger of this floor and the gap's is the one refused (one refusal, below).
  const bool gap_on = fin(a.gap_lines) && a.gap_lines > 0.0 && a.gap_lines <= kOrganicGapLinesMax && fin(settings.bead_mm) &&
                      settings.bead_mm > 0.0;
  const double gap_floor_mm = gap_on ? light + a.gap_lines * settings.bead_mm : 0.0;
  {
    const double small = one ? a.spacing_mm : a.spacing_min_mm;
    const double floor_mm = kSmallestCellFactor * light;
    if (light > 0.0 && (one || a.spacing_mm == 0.0) && fin(small) && small > 0.0 && small < floor_mm - 1e-9 &&
        !(gap_floor_mm > floor_mm))
      at_least(refuse(one ? "spacing_mm" : "spacing_min_mm", "under_smallest_cell",
                      std::string(one ? "Cell size: the size" : "Cell size: the small end") + " must be at least " +
                          plain_number(floor_mm, true) + " mm, the smallest cell a " + plain_number(light) +
                          " mm strut can print.",
                      small),
               floor_mm);
  }
  // OG1 (brief E6): the gap rule. Its number of lines 0 (off) to 4; on, the small end of the cell size (or the one size)
  // at least the light width + the gap: the smallest cell that leaves a printable gap between two light struts.
  if (!(fin(a.gap_lines) && a.gap_lines >= 0.0 && a.gap_lines <= kOrganicGapLinesMax)) {
    OrganicRefusal& r = refuse("gap_lines", "out_of_range",
                               "Gap between struts: it must be from 0 (off) to 4 line widths.", a.gap_lines);
    at_least(r, 0.0);
    at_most(r, kOrganicGapLinesMax);
  } else if (a.gap_lines > 0.0 && light > 0.0 && fin(settings.bead_mm) && settings.bead_mm > 0.0) {
    const double small = one ? a.spacing_mm : a.spacing_min_mm;
    const double gap = a.gap_lines * settings.bead_mm;
    const double floor_mm = light + gap;
    if ((one || a.spacing_mm == 0.0) && fin(small) && small > 0.0 && small < floor_mm - 1e-9 &&
        floor_mm > kSmallestCellFactor * light)   // else the smallest printable cell is the larger, refused above
      at_least(refuse(one ? "spacing_mm" : "spacing_min_mm", "under_gap_cell",
                      std::string(one ? "Cell size: the size" : "Cell size: the small end") + " must be at least " +
                          plain_number(floor_mm, true) + " mm, the smallest cell that leaves a " + plain_number(gap) +
                          " mm gap between " + plain_number(light) + " mm struts.",
                      small),
               floor_mm);
  }
  // OG3 (brief E6, leg D): how close a traced curve may come to another of its family, 0.5 to 1 spacing.
  if (!(fin(a.strand_keep) && a.strand_keep >= 0.5 && a.strand_keep <= 1.0)) {
    OrganicRefusal& r = refuse("strand_keep", "out_of_range",
                               "Strand distance: it must be from 0.5 to 1 times the cell size.", a.strand_keep);
    at_least(r, 0.5);
    at_most(r, 1.0);
  }
  // OG2 (brief E6): the relief, 0 (off) to 1 mm; the faces left flush are the part's face ids (0 or more).
  if (!(fin(a.face_relief_mm) && a.face_relief_mm >= 0.0 && a.face_relief_mm <= kOrganicReliefMaxMm)) {
    OrganicRefusal& r = refuse("face_relief_mm", "out_of_range",
                               "Surface relief: it must be from 0 (off) to 1 mm.", a.face_relief_mm);
    at_least(r, 0.0);
    at_most(r, kOrganicReliefMaxMm);
  }
  for (const int f : a.relief_exclude_faces)
    if (f < 0) {
      at_least(refuse("relief_exclude_faces", "below_zero", "Surface relief: a face left flush must be one of the part's faces.",
                      f),
               0.0);
      break;
    }
  if (!(fin(a.link_width) && a.link_width >= 0.5 && a.link_width <= 2.0)) {
    OrganicRefusal& r = refuse("link_width", "out_of_range", "Link thickness: it must be from 0.5 to 2 times the thinner strut.",
                               a.link_width);
    at_least(r, 0.5);
    at_most(r, 2.0);
  }
  if (!(fin(a.unbraced_max) && (a.unbraced_max == 0.0 || (a.unbraced_max >= 4.0 && a.unbraced_max <= 40.0)))) {
    OrganicRefusal& r = refuse("unbraced_max", "out_of_range",
                               "Longest strut without a joint: it must be 0 (off) or from 4 to 40 strut widths.",
                               a.unbraced_max);
    at_least(r, 4.0);
    at_most(r, 40.0);
  }
  auto not_below_zero = [&](double v, const char* setting, const char* text) {
    if (!(fin(v) && v >= 0.0)) at_least(refuse(setting, "below_zero", text, v), 0.0);
  };
  auto above_zero = [&](double v, const char* setting, const char* text) {
    if (!(fin(v) && v > 0.0)) at_least(refuse(setting, "not_above_zero", text, v), 0.0);
  };
  auto a_number = [&](double v, const char* setting, const char* text) {
    if (!fin(v)) refuse(setting, "not_a_number", text, v);
  };
  not_below_zero(a.shape_reach, "shape_reach", "Grade to shape reach: it must be 0 or more.");
  not_below_zero(a.bed_floor_mm, "bed_floor_mm", "Flat floor: its height must be 0 (no floor) or more.");
  not_below_zero(a.part_reach_mm, "part_reach_mm", "Floating parts: the reach must be 0 mm or more.");
  not_below_zero(a.part_support_mm, "part_support_mm", "Floating parts: the support spacing must be 0 mm or more.");
  if (!(a.tie_swirl >= 0.0 && a.tie_swirl <= 1.0)) {
    OrganicRefusal& r = refuse("tie_swirl", "out_of_range", "Tie swirl: it must be from 0 to 1.", a.tie_swirl);
    at_least(r, 0.0);
    at_most(r, 1.0);
  }
  a_number(a.foot_gap, "foot_gap", "Seeds: the gap must be a number.");
  above_zero(a.void_ratio, "void_ratio", "Re-seeding: the bare distance must be above 0 spacings.");
  if (!(a.reseed_rounds >= 0 && a.reseed_rounds <= 100)) {
    OrganicRefusal& r = refuse("reseed_rounds", "out_of_range", "Re-seeding: the rounds must be from 0 to 100.",
                               a.reseed_rounds);
    at_least(r, 0.0);
    at_most(r, 100.0);
  }
  // The wall seeds' gap (M).
  a_number(a.wall_gap, "wall_gap", "Wall seed gap: the light end must be a number.");
  const std::string ranged = "needs the cell size as a range (a small and a large end).";
  if (!fin(a.wall_gap_heavy)) {
    refuse("wall_gap_heavy", "not_a_number", "Wall seed gap: the heavy end must be a number.", a.wall_gap_heavy);
  } else if (a.wall_gap_heavy > 0.0) {
    if (!(a.wall_gap > 0.0))
      refuse("wall_gap_heavy", "needs_light_end", "Wall seed gap: the heavy end needs the light end above 0 spacings.",
             a.wall_gap_heavy);
    else if (a.wall_gap_heavy > a.wall_gap)
      at_most(refuse("wall_gap_heavy", "over_light_end",
                     "Wall seed gap: the heavy end must be at most the light end (" + spacings(a.wall_gap) + ").",
                     a.wall_gap_heavy),
              a.wall_gap);
    if (!range) refuse("wall_gap_heavy", "needs_range", "Wall seed gap: the heavy end " + ranged, a.wall_gap_heavy);
  }
  // Crossing vines (F, N, O).
  if (!(a.wall_cross == 0 || a.wall_cross == 1 || a.wall_cross == 2)) {
    OrganicRefusal& r = refuse("wall_cross", "out_of_range",
                               "Crossing vines: the choice must be off, after the floor vines or before them.", a.wall_cross);
    at_least(r, 0.0);
    at_most(r, 2.0);
  }
  if (grown && a.wall_cross != 0 && !a.walls_out)
    refuse("wall_cross", "needs_wall_seeds", "Crossing vines need Wall seeds switched on.", a.wall_cross);
  if (grown && a.wall_cross != 0 && a.wall_connect)
    refuse("wall_cross", "with_wall_connect", "Crossing vines cannot be on while wall seeds join the vines.", a.wall_cross);
  if (!(fin(a.cross_gap) && a.cross_gap > 0.0))
    at_least(refuse("cross_gap", "not_above_zero", "Crossing gap: the light end must be above 0 spacings.", a.cross_gap),
             0.0);
  else if (a.cross_gap != 2.5 && a.wall_cross == 0)
    refuse("cross_gap", "needs_crossing_vines", "Crossing gap: it needs Crossing vines switched on.", a.cross_gap);
  if (!fin(a.cross_gap_heavy)) {
    refuse("cross_gap_heavy", "not_a_number", "Crossing gap: the heavy end must be a number.", a.cross_gap_heavy);
  } else if (a.cross_gap_heavy > 0.0) {
    if (a.wall_cross == 0)
      refuse("cross_gap_heavy", "needs_crossing_vines", "Crossing gap: the heavy end needs Crossing vines switched on.",
             a.cross_gap_heavy);
    if (fin(a.cross_gap) && a.cross_gap > 0.0 && a.cross_gap_heavy > a.cross_gap)
      at_most(refuse("cross_gap_heavy", "over_light_end",
                     "Crossing gap: the heavy end must be at most the light end (" + spacings(a.cross_gap) + ").",
                     a.cross_gap_heavy),
              a.cross_gap);
    if (!range) refuse("cross_gap_heavy", "needs_range", "Crossing gap: the heavy end " + ranged, a.cross_gap_heavy);
  }
  if (!(fin(a.cross_climb_max_deg) && a.cross_climb_max_deg >= 30.0 && a.cross_climb_max_deg <= 45.0)) {
    OrganicRefusal& r = refuse("cross_climb_max_deg", "out_of_range",
                               "Steepest crossing climb: it must be from 30 to 45 degrees.", a.cross_climb_max_deg);
    at_least(r, 30.0);
    at_most(r, 45.0);
  } else if (a.cross_climb_max_deg != 45.0 && a.wall_cross == 0) {
    refuse("cross_climb_max_deg", "needs_crossing_vines", "Steepest crossing climb: it needs Crossing vines switched on.",
           a.cross_climb_max_deg);
  }
  // Ties (G9, P).
  if (grown && a.tie_level && !a.ties) refuse("tie_level", "needs_ties", "Flat ties need Ties switched on.", 1.0);
  if (!(fin(a.tie_gap) && a.tie_gap > 0.0))
    at_least(refuse("tie_gap", "not_above_zero", "Flat tie gap: the light end must be above 0 spacings.", a.tie_gap), 0.0);
  else if (grown && a.tie_gap != 1.0 && !a.ties)
    refuse("tie_gap", "needs_ties", "Flat tie gap: it needs Ties switched on.", a.tie_gap);
  if (!fin(a.tie_gap_heavy)) {
    refuse("tie_gap_heavy", "not_a_number", "Flat tie gap: the heavy end must be a number.", a.tie_gap_heavy);
  } else if (a.tie_gap_heavy > 0.0) {
    if (grown && !a.ties)
      refuse("tie_gap_heavy", "needs_ties", "Flat tie gap: the heavy end needs Ties switched on.", a.tie_gap_heavy);
    if (fin(a.tie_gap) && a.tie_gap > 0.0 && a.tie_gap_heavy > a.tie_gap)
      at_most(refuse("tie_gap_heavy", "over_light_end",
                     "Flat tie gap: the heavy end must be at most the light end (" + spacings(a.tie_gap) + ").",
                     a.tie_gap_heavy),
              a.tie_gap);
    if (!range) refuse("tie_gap_heavy", "needs_range", "Flat tie gap: the heavy end " + ranged, a.tie_gap_heavy);
  }
  // Roots and top branches (G, H).
  not_below_zero(a.top_run, "top_run", "Top branches: the length must be 0 (off) or more.");
  not_below_zero(a.root_run, "root_run", "Roots: the length must be 0 (off) or more.");
  not_below_zero(a.run_gap, "run_gap", "Roots and top branches: the gap between them must be 0 or more.");
  if (!(a.run_max >= 1 && a.run_max <= 1000000)) {
    OrganicRefusal& r = refuse("run_max", "out_of_range", "Runs per end: it must be a whole number, 1 or more.", a.run_max);
    at_least(r, 1.0);
    at_most(r, 1e6);
  }
  above_zero(a.run_follow, "run_follow", "Roots and top branches: how firmly they turn must be above 0.");
  not_below_zero(a.run_pull, "run_pull", "Roots and top branches: the pull's reach must be 0 or more.");
  not_below_zero(a.run_seek, "run_seek", "Roots and top branches: the drift toward stronger stress must be 0 or more.");
  not_below_zero(a.run_min, "run_min", "Roots and top branches: the travel before they may join must be 0 or more.");
  a_number(a.root_gap, "root_gap", "Roots: the gap between roots must be a number.");
  // The print.
  {
    const double l = std::sqrt(a.build_dir.x * a.build_dir.x + a.build_dir.y * a.build_dir.y + a.build_dir.z * a.build_dir.z);
    if (!(fin(l) && l > 1e-9)) refuse("build_dir", "zero_direction", "Build direction: it must not be zero.", l);
  }
  above_zero(a.layer_mm, "layer_mm", "Layer height: it must be above 0 mm.");
  above_zero(a.seed_stride, "seed_stride", "Seeds: the seed spacing must be above 0.");
  if (field && field->empty() && any_weave(settings))
    refuse("stress", "no_stress_result",
           "Organic follows the part's stress, and there is no stress result yet. Run the stress check first.", 0.0);
  return out;
}

std::vector<OrganicRefusal> validate_organic_groups(const Settings& settings, const std::vector<OrganicGroup>& groups,
                                                    const TensorField* field) {
  std::vector<OrganicRefusal> out;
  for (std::size_t g = 0; g < groups.size(); ++g)
    for (OrganicRefusal r : validate_organic(settings, groups[g].ask, nullptr)) {
      r.group = static_cast<int>(g);
      out.push_back(std::move(r));
    }
  auto refuse = [&](int group, const char* code, const std::string& text, double given, const char* setting = "groups") {
    OrganicRefusal r;
    r.group = group;
    r.setting = setting;
    r.code = code;
    r.text = text;
    r.given = given;
    out.push_back(std::move(r));
  };
  auto is_weave = [&](int id) {
    for (const Settings::RegionAsk& r : settings.regions)
      if (r.id == id && r.weave && r.role == Role::Lattice) return true;
    return false;
  };
  // Leg J item 1 (the owner: "Rim should be hidden"): an Organic area's own Finish is None, Skin or Solid, never Rim.
  for (const Settings::RegionAsk& r : settings.regions)
    if (r.weave && r.role == Role::Lattice && r.rim_mm && *r.rim_mm != 0.0)
      refuse(-1, "rim_under_organic",
             "Organic area " + std::to_string(r.id) + " asks for a Rim finish; an Organic area's finish is None, Skin or Solid.",
             *r.rim_mm, "rim_mm");
  for (const Settings::RegionAsk& r : settings.regions) {
    if (!(r.weave && r.role == Role::Lattice)) continue;
    std::size_t in = 0;
    for (const OrganicGroup& g : groups) in += static_cast<std::size_t>(std::count(g.regions.begin(), g.regions.end(), r.id));
    if (in == 0)
      refuse(-1, "region_without_group", "Organic area " + std::to_string(r.id) + " is in no group of Organic settings.",
             r.id);
    else if (in > 1)
      refuse(-1, "region_in_two_groups",
             "Organic area " + std::to_string(r.id) + " is in more than one group of Organic settings.", r.id);
  }
  for (std::size_t g = 0; g < groups.size(); ++g) {
    if (groups[g].regions.empty())
      refuse(static_cast<int>(g), "empty_group", "A group of Organic settings has no area in it.", 0.0);
    for (const int id : groups[g].regions)
      if (!is_weave(id))
        refuse(static_cast<int>(g), "not_a_weave_region",
               "Area " + std::to_string(id) + " is in a group of Organic settings but is not an Organic area.", id);
    if (g > 0 && groups[g].ask.bed_floor_mm != groups.front().ask.bed_floor_mm)
      refuse(static_cast<int>(g), "floors_differ",
             "Flat floor: it is one height for the whole part, and this group's differs from the first group's (" +
                 plain_number(groups.front().ask.bed_floor_mm) + " mm).",
             groups[g].ask.bed_floor_mm, "bed_floor_mm");
  }
  if (field && field->empty() && any_weave(settings))
    refuse(-1, "no_stress_result",
           "Organic follows the part's stress, and there is no stress result yet. Run the stress check first.", 0.0,
           "stress");
  return out;
}

}  // namespace topopt::lattice_layout
