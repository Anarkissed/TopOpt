// Lattice rebuild, Organic stage 1b: the owner's Traced placement through the new engine (O3, O4).
// See lattice_layout_organic.hpp. The old tracer is called as it is and nothing after it in the old path.
#include "topopt/lattice_layout_organic.hpp"

#include <algorithm>
#include <chrono>
#include <cmath>
#include <limits>
#include <memory>
#include <stdexcept>

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
OrganicSpacing organic_spacing(const Domain& domain, int region, const TensorField& field, const OrganicAsk& ask) {
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
    const double cap_outline = 2.0 * static_cast<double>(steps[e]) * field.spacing;
    double cap = std::min(cap_member, cap_outline);
    if (cap < lo) cap = lo;
    if (!(cap > 0.0) || !(cap < out.spacing_mm[e])) continue;
    out.spacing_mm[e] = cap;
    ++out.shape_fit_tightened;
  }
  return out;
}

std::vector<Strand> trace_strands(const Domain& domain, int region, const TensorField& field, const OrganicAsk& ask,
                                  OrganicTraceStats* stats) {
  std::vector<Strand> out;
  if (stats) *stats = OrganicTraceStats{};
  if (field.empty()) return out;
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
  for (const OrganicConnector& cn : lat.connectors) out.push_back(strand_of({cn.a, cn.b}, cn.radius_mm));
  return out;
}

Outcome Session::lay_organic(const Settings& settings, const TensorField& field, const OrganicAsk& ask, int threads,
                             const std::atomic<bool>* stop) {
  if (stop && stop->load(std::memory_order_relaxed)) {
    Outcome none;
    none.cancelled = true;
    return none;
  }
  // O15: the Organic rim is a "where" setting of the domain the weave is laid in. The trace runs with the rim's band
  // IN (the old run's ruling G): its curves cross the band and are cut where the solid begins (weave_bars: Solid, run
  // in by their width), so they end embedded in the rim.
  bool any_weave = false;
  for (const Settings::RegionAsk& r : settings.regions) any_weave = any_weave || (r.weave && r.role == Role::Lattice);
  WeaveFinish finish;
  if (any_weave)
    finish.rim_mm = ask.rim_mm < 0.0 ? organic_rim_default_mm(settings.bead_mm, field.spacing) : ask.rim_mm;
  ready_domain(settings, finish.rim_mm);
  std::unique_ptr<Domain> without_rim;
  if (finish.rim_mm > 0.0) {
    DomainSpec spec = domain_->spec();
    spec.weave_rim_mm = 0.0;
    without_rim = std::make_unique<Domain>(*measure_, std::move(spec));
  }
  const Domain& trace_in = without_rim ? *without_rim : *domain_;
  const auto t0 = std::chrono::steady_clock::now();
  std::vector<Strand> strands;
  double smallest = 0.0, largest = 0.0, sum = 0.0;
  std::size_t candidates = 0;
  for (const Region& r : domain_->spec().regions) {
    if (r.role != Role::Lattice || !r.weave) continue;
    OrganicTraceStats st;
    std::vector<Strand> traced = trace_strands(trace_in, r.id, field, ask, &st);
    if (ask.net_skin && st.spacing_median_mm > 0.0) finish.net_reach.push_back({r.id, st.spacing_median_mm});   // O16
    if (st.candidates > 0) {
      smallest = candidates ? std::min(smallest, st.spacing_smallest_mm) : st.spacing_smallest_mm;
      largest = candidates ? std::max(largest, st.spacing_largest_mm) : st.spacing_largest_mm;
      sum += st.spacing_mean_mm * static_cast<double>(st.candidates);
      candidates += st.candidates;
    }
    strands.insert(strands.end(), std::make_move_iterator(traced.begin()), std::make_move_iterator(traced.end()));
  }
  const double ms_trace = std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - t0).count();
  Outcome out = lay_with(settings, &strands, threads, stop, &finish);
  if (!out.cancelled) {
    out.rim_mm = finish.rim_mm;
    out.strands = strands.size();
    out.ms_trace = ms_trace;
    out.spacing_smallest_mm = smallest;
    out.spacing_largest_mm = largest;
    out.spacing_mean_mm = candidates ? sum / static_cast<double>(candidates) : 0.0;
  }
  return out;
}

}  // namespace topopt::lattice_layout
