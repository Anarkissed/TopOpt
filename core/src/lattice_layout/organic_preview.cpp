// Organic preview (brief L2): the weave handed over as runs (item 2), the two qualities of a lay for the preview
// (item 3), and the Auto Sweep limits (item 4). Declared in lattice_layout_organic.hpp.
#include <algorithm>
#include <array>
#include <cmath>
#include <cstring>
#include <limits>
#include <utility>

#include "topopt/lattice_layout_organic.hpp"

namespace topopt::lattice_layout {
namespace {
double dist3(const Vec3& a, const Vec3& b) {
  return std::sqrt((a.x - b.x) * (a.x - b.x) + (a.y - b.y) * (a.y - b.y) + (a.z - b.z) * (a.z - b.z));
}
std::uint8_t marks_of(const Bar& b) {
  return static_cast<std::uint8_t>((b.level_tie ? kRunLevelTie : 0) | (b.brace ? kRunBrace : 0) |
                                   (b.support ? kRunSupport : 0) | (b.net ? kRunNet : 0));
}
// Item 2's thinning, one run: Douglas-Peucker on the points, a point kept when an original point between two kept ones
// lies further than `tol` from their segment or its width is more than 5 % off the width interpolated there.
void thin(WeaveRun& r, double tol) {
  const std::size_t n = r.points.size();
  if (!(tol > 0.0) || n < 3) return;
  std::vector<char> keep(n, 0);
  keep[0] = keep[n - 1] = 1;
  std::vector<double> cl(n, 0.0);   // length along the run
  for (std::size_t k = 1; k < n; ++k) cl[k] = cl[k - 1] + dist3(r.points[k - 1], r.points[k]);
  std::vector<std::pair<std::size_t, std::size_t>> stack{{0, n - 1}};
  while (!stack.empty()) {
    const auto [i, j] = stack.back();
    stack.pop_back();
    if (j <= i + 1) continue;
    const Vec3& a = r.points[i];
    const Vec3& b = r.points[j];
    const Vec3 d{b.x - a.x, b.y - a.y, b.z - a.z};
    const double l2 = d.x * d.x + d.y * d.y + d.z * d.z;
    const double L = cl[j] - cl[i];
    double worst = -1.0;
    std::size_t at = i;
    for (std::size_t k = i + 1; k < j; ++k) {
      const Vec3& q = r.points[k];
      const double t = l2 > 0.0 ? std::clamp(((q.x - a.x) * d.x + (q.y - a.y) * d.y + (q.z - a.z) * d.z) / l2, 0.0, 1.0) : 0.0;
      const double dd = dist3(q, Vec3{a.x + d.x * t, a.y + d.y * t, a.z + d.z * t});
      const double u = L > 0.0 ? (cl[k] - cl[i]) / L : 0.0;
      const double wi = r.width_mm[i] + (r.width_mm[j] - r.width_mm[i]) * u;
      const double score = std::fabs(r.width_mm[k] - wi) > 0.05 * wi ? std::numeric_limits<double>::infinity() : dd / tol;
      if (score > worst) { worst = score; at = k; }
    }
    if (worst > 1.0) {
      keep[at] = 1;
      stack.push_back({i, at});
      stack.push_back({at, j});
    }
  }
  WeaveRun t;
  t.region = r.region; t.marks = r.marks; t.end_a = r.end_a; t.end_b = r.end_b;
  for (std::size_t k = 0; k < n; ++k)
    if (keep[k]) {
      t.points.push_back(r.points[k]);
      t.width_mm.push_back(r.width_mm[k]);
      t.spacing_mm.push_back(r.spacing_mm[k]);
    }
  r = std::move(t);
}
}  // namespace

std::vector<WeaveRun> weave_runs(const Bars& bars, const std::vector<int>& weave_regions, double tolerance_mm) {
  std::vector<WeaveRun> runs;
  const Bar* prev = nullptr;
  for (const Bar& b : bars.bars) {
    const bool weave = std::find(weave_regions.begin(), weave_regions.end(), b.region) != weave_regions.end();
    if (b.link || !weave) { prev = nullptr; continue; }
    const std::uint8_t m = marks_of(b);
    if (prev && prev->strand == b.strand && prev->region == b.region && runs.back().marks == m &&
        dist3(runs.back().points.back(), b.a) < 1e-6) {
      WeaveRun& r = runs.back();
      r.width_mm.back() = 0.5 * (r.width_mm.back() + b.width);
      r.points.push_back(b.b);
      r.width_mm.push_back(b.width);
      r.spacing_mm.push_back(b.cell);
      r.end_b = b.end_b;
    } else {
      WeaveRun r;
      r.region = b.region;
      r.marks = m;
      r.end_a = b.end_a;
      r.end_b = b.end_b;
      r.points = {b.a, b.b};
      r.width_mm = {b.width, b.width};
      r.spacing_mm = {b.cell, b.cell};
      runs.push_back(std::move(r));
    }
    prev = &b;
  }
  for (WeaveRun& r : runs) thin(r, tolerance_mm);
  return runs;
}

OrganicPreview lay_organic_preview(Session& session, const Settings& settings, const TensorField& field,
                                   const OrganicAsk& ask, const OrganicPreviewAsk& preview, int threads,
                                   const std::atomic<bool>* stop) {
  OrganicPreview out;
  out.quality = preview.quality;
  out.outcome = preview.quality == PreviewQuality::Draft ? session.lay_organic_draft(settings, field, ask, threads, stop)
                                                         : session.lay_organic(settings, field, ask, threads, stop);
  if (out.outcome.cancelled) return out;
  std::vector<int> regions;
  for (const Layout::Weave& w : out.outcome.layout.weave) regions.push_back(w.region);
  out.runs = weave_runs(out.outcome.bars, regions, preview.tolerance_mm);
  return out;
}

std::vector<std::uint8_t> pack_weave_runs(const std::vector<WeaveRun>& runs) {
  std::size_t bytes = 0;
  for (const WeaveRun& r : runs) bytes += 12 + 20 * r.points.size();
  std::vector<std::uint8_t> out(bytes, 0);
  std::size_t at = 0;
  auto put = [&](const void* p, std::size_t n) { std::memcpy(out.data() + at, p, n); at += n; };
  for (const WeaveRun& r : runs) {
    const std::uint32_t n = static_cast<std::uint32_t>(r.points.size());
    const std::int32_t region = r.region;
    const std::uint8_t head[4] = {r.marks, static_cast<std::uint8_t>(r.end_a), static_cast<std::uint8_t>(r.end_b), 0};
    put(&n, 4); put(&region, 4); put(head, 4);
    for (std::size_t k = 0; k < r.points.size(); ++k) {
      const float v[5] = {static_cast<float>(r.points[k].x), static_cast<float>(r.points[k].y),
                          static_cast<float>(r.points[k].z), static_cast<float>(r.width_mm[k]),
                          static_cast<float>(r.spacing_mm[k])};
      put(v, sizeof v);
    }
  }
  return out;
}

namespace {
// The least width over all directions of a set of points in a plane: the narrowest caliper of their convex hull.
double narrowest_width(std::vector<std::array<double, 2>> p) {
  std::sort(p.begin(), p.end());
  p.erase(std::unique(p.begin(), p.end()), p.end());
  if (p.size() < 3) return 0.0;
  auto cross = [](const std::array<double, 2>& o, const std::array<double, 2>& a, const std::array<double, 2>& b) {
    return (a[0] - o[0]) * (b[1] - o[1]) - (a[1] - o[1]) * (b[0] - o[0]);
  };
  std::vector<std::array<double, 2>> h(2 * p.size());
  std::size_t k = 0;
  for (std::size_t i = 0; i < p.size(); ++i) {
    while (k >= 2 && cross(h[k - 2], h[k - 1], p[i]) <= 0.0) --k;
    h[k++] = p[i];
  }
  for (std::size_t i = p.size() - 1, t = k + 1; i-- > 0;) {
    while (k >= t && cross(h[k - 2], h[k - 1], p[i]) <= 0.0) --k;
    h[k++] = p[i];
  }
  h.resize(k - 1);
  if (h.size() < 3) return 0.0;
  double best = std::numeric_limits<double>::infinity();
  for (std::size_t i = 0; i < h.size(); ++i) {
    const auto& a = h[i];
    const auto& b = h[(i + 1) % h.size()];
    const double len = std::hypot(b[0] - a[0], b[1] - a[1]);
    if (!(len > 0.0)) continue;
    double far = 0.0;
    for (const auto& q : h) far = std::max(far, std::fabs(cross(a, b, q)) / len);
    best = std::min(best, far);
  }
  return std::isfinite(best) ? best : 0.0;
}
}  // namespace

std::vector<SweepLimits> organic_sweep_limits(const Domain& domain, double line_mm) {
  std::vector<SweepLimits> out;
  const double line = line_mm > 0.0 ? line_mm : domain.spec().bead_mm;
  const double thinnest = 2.0 * line;
  // The engine's smallest printable Organic spacing: the tracer's own print floor, t x sqrt(3 pi) / 2 with t the
  // thinnest strut (organic_lattice.cpp, spacing_print_floor_mm). (The octet's open-look floor, C14, is a cube cell's,
  // 4.74 mm at a 0.45 mm line: it would refuse the brief's own D = 18 example.)
  const double floor_cell = 0.5 * thinnest * std::sqrt(3.0 * 3.14159265358979323846);
  auto lines = [&](double x) { return std::max(1.0, std::round(x / line)) * line; };
  auto half = [&](double x) { return std::max(std::round(x * 2.0) / 2.0, std::ceil(floor_cell * 2.0) / 2.0); };
  for (const Region& r : domain.spec().regions) {
    if (r.role != Role::Lattice || !r.weave) continue;
    SweepLimits s;
    s.region = r.id;
    if (!r.is_shell()) {
      const ClearanceGeometry& g = r.prism;
      std::vector<std::array<double, 2>> pts;
      for (const auto& loop : g.outline_uv)
        for (const auto& q : loop) pts.push_back(q);
      if (pts.empty()) pts = {{g.u_lo, g.w_lo}, {g.u_hi, g.w_lo}, {g.u_hi, g.w_hi}, {g.u_lo, g.w_hi}};
      s.depth_mm = g.depth;
      s.mouth_width_mm = narrowest_width(pts);
      s.measured = s.depth_mm > 0.0 && s.mouth_width_mm > 0.0;
    }
    if (s.measured) {
      s.d_mm = std::min(s.depth_mm, s.mouth_width_mm);
      s.strut_lower_mm = lines(std::max(thinnest, s.d_mm * kSweepStrutLower));
      s.strut_upper_mm = lines(std::max(s.strut_lower_mm, s.d_mm * kSweepStrutUpper));
      s.strut_auto_mm = lines(0.5 * (s.strut_lower_mm + s.strut_upper_mm));
      s.cell_lower_mm = half(s.d_mm * kSweepCellLower);
      s.cell_upper_mm = half(s.d_mm * kSweepCellUpper);
      s.cell_auto_mm = half(0.5 * (s.cell_lower_mm + s.cell_upper_mm));
    }
    out.push_back(s);
  }
  return out;
}

}  // namespace topopt::lattice_layout
