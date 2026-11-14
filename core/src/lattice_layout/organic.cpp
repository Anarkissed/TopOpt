// Lattice rebuild, Organic stage 1b: the owner's Traced placement through the new engine (O3, O4).
// See lattice_layout_organic.hpp. The old tracer is called as it is and nothing after it in the old path.
#include "topopt/lattice_layout_organic.hpp"

#include <algorithm>
#include <cmath>
#include <limits>

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

std::vector<Strand> trace_strands(const Domain& domain, int region, const TensorField& field, const OrganicAsk& ask) {
  std::vector<Strand> out;
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
  // The candidates: voxels whose centre is lattice of the weave region.
  const Domain::Probe probe = domain.probe();
  std::vector<char> candidate(n, 0);
  std::vector<double> spacing(n, 0.0);
  std::size_t candidates = 0;
  for (int k = 0; k < field.nz; ++k)
    for (int j = 0; j < field.ny; ++j)
      for (int i = 0; i < field.nx; ++i) {
        const Where w = probe.where(grid.voxel_center(i, j, k));
        if (!w.lattice() || w.id != region) continue;
        const std::size_t e = field.index(i, j, k);
        candidate[e] = 1;
        spacing[e] = ask.spacing_mm;
        ++candidates;
      }
  if (candidates == 0) return out;
  OrganicParams params;
  params.min_extrudable_width_mm = domain.spec().bead_mm * domain.spec().min_strut_lines;
  params.strut_diameter_mm = ask.width_mm;
  params.bead_is_stated = true;   // no calibration: the width is the width
  params.build_dir = ask.build_dir;
  const OrganicLattice lat = trace_organic_lattice(grid, candidate, field.voigt, spacing, nullptr, params);

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
    return s > 0.0 ? s : ask.spacing_mm;   // (never off the candidates: a curve's points are all on them)
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
  ready_domain(settings);
  std::vector<Strand> strands;
  for (const Region& r : domain_->spec().regions) {
    if (r.role != Role::Lattice || !r.weave) continue;
    std::vector<Strand> traced = trace_strands(*domain_, r.id, field, ask);
    strands.insert(strands.end(), std::make_move_iterator(traced.begin()), std::make_move_iterator(traced.end()));
  }
  return lay_with(settings, &strands, threads, stop);
}

}  // namespace topopt::lattice_layout
