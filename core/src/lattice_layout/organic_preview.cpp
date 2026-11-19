// Organic preview (brief L2): the weave handed over as runs (item 2), the two qualities of a lay for the preview
// (item 3), and the Auto Sweep limits (item 4). Declared in lattice_layout_organic.hpp.
#include <algorithm>
#include <array>
#include <cmath>
#include <cstring>
#include <limits>
#include <stdexcept>
#include <utility>

#include "topopt/lattice_layout_file.hpp"   // OS16: the print check between rounds
#include "topopt/lattice_layout_organic.hpp"

namespace topopt::lattice_layout {
namespace {
double dist3(const Vec3& a, const Vec3& b) {
  return std::sqrt((a.x - b.x) * (a.x - b.x) + (a.y - b.y) * (a.y - b.y) + (a.z - b.z) * (a.z - b.z));
}
std::uint8_t marks_of(const Bar& b, bool relief) {
  return static_cast<std::uint8_t>((b.level_tie ? kRunLevelTie : 0) | (b.brace ? kRunBrace : 0) |
                                   (b.support ? kRunSupport : 0) | (b.net ? kRunNet : 0) |
                                   (relief && b.along_proud > 0.0 ? kRunAlong : 0));
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
  t.proud_mm = r.proud_mm;   // OG2b
  t.proud_a_mm = r.proud_a_mm; t.proud_b_mm = r.proud_b_mm; t.along_face = r.along_face;   // leg H
  for (std::size_t k = 0; k < n; ++k)
    if (keep[k]) {
      t.points.push_back(r.points[k]);
      t.width_mm.push_back(r.width_mm[k]);
      t.spacing_mm.push_back(r.spacing_mm[k]);
    }
  r = std::move(t);
}
// OJ6: Exact with relief laid: the bars as the file makes them flush (the print check run once); else the lay's.
Bars flushed_as_the_file(Session& session, OrganicPreview& out, const std::atomic<bool>* stop) {
  Bars shown = out.outcome.bars;
  if (out.quality == PreviewQuality::Draft) return shown;
  bool any = false;
  for (const Bar& b : shown.bars) any = any || b.along_proud > 0.0 || b.proud_a > 0.0 || b.proud_b > 0.0;
  if (!any) return shown;
  const PrintChecked pc = print_check_bars(session, out.outcome.layout, shown, file_options_for(FileOptions{}, true), stop);
  if (pc.ok) out.relief_flushed = clear_flushed_relief(shown, pc.made.relief_flushed_at);
  return shown;
}
}  // namespace

std::size_t clear_flushed_relief(Bars& bars, const std::vector<std::array<Vec3, 2>>& flushed) {
  std::size_t n = 0;
  for (const auto& f : flushed)
    for (Bar& b : bars.bars) {
      const bool same = (dist3(b.a, f[0]) < 1e-12 && dist3(b.b, f[1]) < 1e-12) || (dist3(b.a, f[1]) < 1e-12 && dist3(b.b, f[0]) < 1e-12);
      if (!same || !(b.along_proud > 0.0 || b.proud_a > 0.0 || b.proud_b > 0.0)) continue;
      if (b.relief_a > 0.0 || b.relief_b > 0.0) b = without_relief(Bars{{b}}).bars.front();
      b.along_proud = 0.0;
      b.along_face = -1;
      b.proud_a = b.proud_b = 0.0;
      ++n;
      break;
    }
  return n;
}

std::vector<WeaveRun> weave_runs(const Bars& bars, const std::vector<int>& weave_regions, double tolerance_mm,
                                 std::vector<std::vector<std::size_t>>* bar_of, bool relief_marks) {
  std::vector<WeaveRun> runs;
  if (bar_of) bar_of->clear();
  const Bar* prev = nullptr;
  for (const Bar& b : bars.bars) {
    const std::size_t at = static_cast<std::size_t>(&b - bars.bars.data());
    const bool weave = std::find(weave_regions.begin(), weave_regions.end(), b.region) != weave_regions.end();
    if (b.link || !weave) { prev = nullptr; continue; }
    const std::uint8_t m = marks_of(b, relief_marks);
    if (prev && prev->strand == b.strand && prev->region == b.region && runs.back().marks == m &&
        (!relief_marks || prev->along_face == b.along_face) && dist3(runs.back().points.back(), b.a) < 1e-6) {
      WeaveRun& r = runs.back();
      r.width_mm.back() = 0.5 * (r.width_mm.back() + b.width);
      r.points.push_back(b.b);
      r.width_mm.push_back(b.width);
      r.spacing_mm.push_back(b.cell);
      r.end_b = b.end_b;
      r.proud_b_mm = b.end_b == Bar::End::Surface ? b.proud_b : 0.0;   // leg H
      if (r.along_face < 0) r.along_face = b.along_face;
      r.proud_mm = std::max(r.proud_mm, b.along_proud);   // OG2b
      if (bar_of) bar_of->back().push_back(at);
    } else {
      WeaveRun r;
      r.region = b.region;
      r.marks = m;
      r.end_a = b.end_a;
      r.end_b = b.end_b;
      r.points = {b.a, b.b};
      r.width_mm = {b.width, b.width};
      r.spacing_mm = {b.cell, b.cell};
      r.proud_mm = b.along_proud;   // OG2b
      r.proud_a_mm = b.end_a == Bar::End::Surface ? b.proud_a : 0.0;   // leg H
      r.proud_b_mm = b.end_b == Bar::End::Surface ? b.proud_b : 0.0;
      r.along_face = b.along_face;
      runs.push_back(std::move(r));
      if (bar_of) bar_of->push_back({at});
    }
    prev = &b;
  }
  if (bar_of && tolerance_mm > 0.0) bar_of->clear();
  for (WeaveRun& r : runs) thin(r, tolerance_mm);
  return runs;
}

OrganicPreview lay_organic_preview(Session& session, const Settings& settings, const TensorField& field,
                                   const OrganicAsk& ask, const OrganicPreviewAsk& preview, int threads,
                                   const std::atomic<bool>* stop) {
  OrganicPreview out;
  out.quality = preview.quality;
  // OS16 (brief E4, leg 2): Exact replays additions with the file's print check between rounds, as the file job does
  // (the file's own print settings, the tubes route; a job that states others is replayed by the file job with those).
  OrganicAsk exact = ask;
  if (preview.quality != PreviewQuality::Draft && !exact.additions.empty() && !exact.print_check)
    exact.print_check = print_check_hook(session, file_options_for(FileOptions{}, true), stop);
  out.outcome = preview.quality == PreviewQuality::Draft ? session.lay_organic_draft(settings, field, ask, threads, stop)
                                                         : session.lay_organic(settings, field, exact, threads, stop);
  if (out.outcome.cancelled) return out;
  std::vector<int> regions;
  for (const Layout::Weave& w : out.outcome.layout.weave) regions.push_back(w.region);
  const Bars shown = flushed_as_the_file(session, out, stop);   // OJ6
  out.runs = weave_runs(shown, regions, preview.tolerance_mm, nullptr, true);   // leg H: the relief marks
  return out;
}

OrganicPreview lay_organic_preview(Session& session, const Settings& settings, const TensorField& field,
                                   const std::vector<OrganicGroup>& groups, const OrganicPreviewAsk& preview,
                                   int threads, const std::atomic<bool>* stop) {
  OrganicPreview out;
  out.quality = preview.quality;
  // OJ6: Exact replays a group list's additions with the file's print check between rounds, as the one-ask form does.
  std::vector<OrganicGroup> exact = groups;
  if (preview.quality != PreviewQuality::Draft && !exact.empty() && !exact.front().ask.additions.empty() &&
      !exact.front().ask.print_check)
    exact.front().ask.print_check = print_check_hook(session, file_options_for(FileOptions{}, true), stop);
  out.outcome = preview.quality == PreviewQuality::Draft
                    ? session.lay_organic_draft(settings, field, groups, threads, stop)
                    : session.lay_organic(settings, field, exact, threads, stop);
  if (out.outcome.cancelled) return out;
  std::vector<int> regions;
  for (const Layout::Weave& w : out.outcome.layout.weave) regions.push_back(w.region);
  const Bars shown = flushed_as_the_file(session, out, stop);   // OJ6
  out.runs = weave_runs(shown, regions, preview.tolerance_mm, nullptr, true);   // leg H: the relief marks
  return out;
}

std::vector<std::uint8_t> pack_weave_runs(const std::vector<WeaveRun>& runs, int version) {
  if (version != 1 && version != 2) throw std::invalid_argument("pack_weave_runs: version is 1 or 2");
  const bool v2 = version == 2;
  std::size_t bytes = v2 ? 8 : 0;
  for (const WeaveRun& r : runs) bytes += (v2 ? 28 : 12) + 20 * r.points.size();
  std::vector<std::uint8_t> out(bytes, 0);
  std::size_t at = 0;
  auto put = [&](const void* p, std::size_t n) { std::memcpy(out.data() + at, p, n); at += n; };
  if (v2) {
    const std::uint32_t ver = 2;
    put("WRN2", 4); put(&ver, 4);
  }
  for (const WeaveRun& r : runs) {
    const std::uint32_t n = static_cast<std::uint32_t>(r.points.size());
    const std::int32_t region = r.region;
    const std::uint8_t head[4] = {r.marks, static_cast<std::uint8_t>(r.end_a), static_cast<std::uint8_t>(r.end_b), 0};
    put(&n, 4); put(&region, 4); put(head, 4);
    if (v2) {   // leg H
      const float pa = static_cast<float>(r.proud_a_mm), pb = static_cast<float>(r.proud_b_mm), pm = static_cast<float>(r.proud_mm);
      const std::int32_t face = r.along_face;
      put(&pa, 4); put(&pb, 4); put(&face, 4); put(&pm, 4);
    }
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

// The limits' two roundings, shared by organic_sweep_limits and Session::sweep_limits_for (OP10): whole lines, at least
// one; the nearest 0.5 mm, never under the smallest printable cell of the thinnest strut (2 lines).
struct SweepRounding {
  double line = 0.0, thinnest = 0.0, floor_cell = 0.0;
  SweepRounding(const Domain& domain, double line_mm)
      : line(line_mm > 0.0 ? line_mm : domain.spec().bead_mm), thinnest(2.0 * line),
        // The engine's smallest printable Organic spacing: the tracer's own print floor, t x sqrt(3 pi) / 2 with t the
        // thinnest strut (organic_lattice.cpp, spacing_print_floor_mm). (The octet's open-look floor, C14, is a cube
        // cell's, 4.74 mm at a 0.45 mm line: it would refuse the brief's own D = 18 example.)
        floor_cell(0.5 * thinnest * std::sqrt(3.0 * 3.14159265358979323846)) {}
  double lines(double x) const { return std::max(1.0, std::round(x / line)) * line; }
  double half(double x) const { return std::max(std::round(x * 2.0) / 2.0, std::ceil(floor_cell * 2.0) / 2.0); }
};

std::vector<SweepLimits> organic_sweep_limits(const Domain& domain, double line_mm, double gap_lines) {
  std::vector<SweepLimits> out;
  const SweepRounding rd(domain, line_mm);
  // OG1 (brief E6): the gap, gap_lines x the line; the cell's lower end at least the thin strut + the gap (up to 0.5 mm).
  const double gap = gap_lines > 0.0 && std::isfinite(gap_lines) ? gap_lines * rd.line : 0.0;
  const double thinnest = rd.thinnest;
  auto lines = [&](double x) { return rd.lines(x); };
  auto half = [&](double x) { return rd.half(x); };
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
      if (gap > 0.0) {   // OG1
        s.gap_mm = gap;
        s.gap_cell_mm = std::ceil((s.strut_lower_mm + gap) * 2.0 - 1e-9) / 2.0;
        if (s.cell_lower_mm < s.gap_cell_mm) {
          s.cell_lower_mm = s.gap_cell_mm;
          s.cell_lower_by_gap = true;
        }
        s.cell_upper_mm = std::max(s.cell_upper_mm, s.cell_lower_mm);
      }
      s.cell_auto_mm = half(0.5 * (s.cell_lower_mm + s.cell_upper_mm));
    }
    out.push_back(s);
  }
  return out;
}

// OP5 (brief C1): the same limits before any lay, on the domain lay() would lay in.
std::vector<SweepLimits> Session::sweep_limits(const Settings& settings, double line_mm, double gap_lines) {
  ready_domain(settings);
  return organic_sweep_limits(*domain_, line_mm, gap_lines);
}

// OP10 (brief C2, E4; E7: per group): the union of the measured regions' limits among `regions`.
SweepLimitsUnion Session::sweep_limits_for(const Settings& settings, const std::vector<int>& regions, double line_mm,
                                           double gap_lines) {
  const std::vector<SweepLimits> all = sweep_limits(settings, line_mm, gap_lines);
  const SweepRounding rd(*domain_, line_mm);
  SweepLimitsUnion u;
  for (const int id : regions) {
    const SweepLimits* s = nullptr;
    for (const SweepLimits& x : all)
      if (x.region == id) s = &x;
    if (!s || !s->measured) {
      u.unmeasured.push_back(id);
      continue;
    }
    if (!u.measured) {
      u.strut_lower_mm = s->strut_lower_mm;
      u.strut_upper_mm = s->strut_upper_mm;
      u.cell_lower_mm = s->cell_lower_mm;
      u.cell_upper_mm = s->cell_upper_mm;
    }
    u.measured = true;
    u.strut_lower_mm = std::min(u.strut_lower_mm, s->strut_lower_mm);
    u.strut_upper_mm = std::max(u.strut_upper_mm, s->strut_upper_mm);
    u.cell_lower_mm = std::min(u.cell_lower_mm, s->cell_lower_mm);
    u.cell_upper_mm = std::max(u.cell_upper_mm, s->cell_upper_mm);
    u.gap_mm = s->gap_mm;   // OG1
    u.cell_lower_by_gap = u.cell_lower_by_gap || s->cell_lower_by_gap;
    u.measured_regions.push_back(id);
  }
  if (u.measured) {
    u.strut_auto_mm = rd.lines(0.5 * (u.strut_lower_mm + u.strut_upper_mm));
    u.cell_auto_mm = rd.half(0.5 * (u.cell_lower_mm + u.cell_upper_mm));
  }
  return u;
}

}  // namespace topopt::lattice_layout
