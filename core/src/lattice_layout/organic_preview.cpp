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
  t.section = r.section;   // leg M
  // Leg M: every point where the file's ring width changes, or where the file splits the tube (a turn sharper than 60
  // degrees), is kept.
  if (r.ring_mm.size() == n)
    for (std::size_t k = 1; k + 1 < n; ++k) {
      if (r.ring_mm[k] != r.ring_mm[k - 1] || r.ring_mm[k] != r.ring_mm[k + 1]) keep[k] = 1;
      const Vec3 u{r.points[k].x - r.points[k - 1].x, r.points[k].y - r.points[k - 1].y, r.points[k].z - r.points[k - 1].z};
      const Vec3 v{r.points[k + 1].x - r.points[k].x, r.points[k + 1].y - r.points[k].y, r.points[k + 1].z - r.points[k].z};
      const double lu = std::sqrt(u.x * u.x + u.y * u.y + u.z * u.z), lv = std::sqrt(v.x * v.x + v.y * v.y + v.z * v.z);
      if (lu > 0.0 && lv > 0.0 && (u.x * v.x + u.y * v.y + u.z * v.z) / (lu * lv) < 0.5) keep[k] = 1;
    }
  for (std::size_t k = 0; k < n; ++k)
    if (keep[k]) {
      t.points.push_back(r.points[k]);
      t.width_mm.push_back(r.width_mm[k]);
      t.spacing_mm.push_back(r.spacing_mm[k]);
      if (r.ring_mm.size() == n) t.ring_mm.push_back(r.ring_mm[k]);
    }
  r = std::move(t);
}
// OJ6: Exact with relief laid: the bars as the file makes them flush (the print check run once); else the lay's.
Bars flushed_as_the_file(Session& session, OrganicPreview& out, const std::atomic<bool>* stop) {
  Bars shown = out.outcome.bars;
  if (out.quality == PreviewQuality::Draft) return shown;
  const FileOptions fo = file_options_for(FileOptions{}, true);
  bool any = false, domes = false;
  for (const Bar& b : shown.bars) {
    any = any || b.along_proud > 0.0 || b.proud_a > 0.0 || b.proud_b > 0.0;
    // leg U: a shallow run (a bridge) has domed ends in the file, which the print check may hold flat
    domes = domes || (fo.mesh.weave_bridge_domes && !b.net && bar_is_bridge(b, fo.mesh.bridge_rise));
  }
  if (!any && !domes) return shown;
  const PrintChecked pc = print_check_bars(session, out.outcome.layout, shown, fo, stop);
  if (pc.ok) {
    if (any) out.relief_flushed = clear_flushed_relief(shown, pc.made.relief_flushed_at);
    // Leg V (the drawing follows the print file): when the check's sag pass lifted joints or laid legs (O17, O18), the
    // runs are drawn from the bars the file is made of (lifted, legs after, the relief already made flush as the file
    // makes it), so a bar the lift made shallow is drawn as the file's bridge. The file's held-flat ends are then points
    // of those runs as they stand.
    if (pc.made.sagged) shown = *pc.made.sagged;
    out.flat_ends = pc.made.flat_domes_at;
  }
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
    const std::uint8_t sec = !bar_is_bridge(b, file_mesh_defaults().bridge_rise) ? 0 : file_mesh_defaults().weave_round_top ? 1 : 2;
    if (prev && prev->strand == b.strand && prev->region == b.region && runs.back().marks == m &&
        (!relief_marks || (prev->along_face == b.along_face && runs.back().section == sec)) &&
        dist3(runs.back().points.back(), b.a) < 1e-6) {
      WeaveRun& r = runs.back();
      r.width_mm.back() = 0.5 * (r.width_mm.back() + b.width);
      r.ring_mm.back() = std::max(r.ring_mm.back(), b.width);   // leg M: the file's ring at an inner point
      r.points.push_back(b.b);
      r.width_mm.push_back(b.width);
      r.ring_mm.push_back(b.width);
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
      r.ring_mm = {b.width, b.width};   // leg M
      r.section = sec;
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


// OV1 (ruling R9): the runs as the file sweeps them. The file's runs (no thinning, no relief split), cut into the tubes
// route's pieces exactly (weave_tubes.cpp: a change of section, a turn sharper than 60 degrees; zero-length segments
// dropped; the ring rule; the equal-area radius the file sweeps with), each round piece swept by sweep_centre_line (the
// span ending in solid held straight), then split where the preview's relief marks split a run (leg H: the along-face
// mark, the face). A swept run's section byte carries bit 2 (kSectionSwept); its points are the file's rings, not thinned.
std::vector<WeaveRun> swept_runs(const Bars& bars, const std::vector<int>& regions, const SweepAsk& sweep) {
  std::vector<std::vector<std::size_t>> bar_of;
  const std::vector<WeaveRun> file_runs = weave_runs(bars, regions, 0.0, &bar_of, false);
  const MeshSpec spec = file_mesh_defaults();
  const double kPi = 3.14159265358979323846;
  const double sharp = std::cos(60.0 * kPi / 180.0);
  auto unit = [](const Vec3& v) {
    const double l = std::sqrt(v.x * v.x + v.y * v.y + v.z * v.z);
    return l > 0.0 ? Vec3{v.x / l, v.y / l, v.z / l} : Vec3{0, 0, 0};
  };
  auto sub = [](const Vec3& a, const Vec3& b) { return Vec3{a.x - b.x, a.y - b.y, a.z - b.z}; };
  auto dot = [](const Vec3& a, const Vec3& b) { return a.x * b.x + a.y * b.y + a.z * b.z; };
  std::vector<WeaveRun> out;
  for (std::size_t q = 0; q < file_runs.size() && q < bar_of.size(); ++q) {
    const std::vector<std::size_t>& segs = bar_of[q];
    if (segs.empty()) continue;
    std::vector<Vec3> pts{bars.bars[segs[0]].a};
    std::vector<double> w;
    std::vector<int> kind;
    std::vector<std::size_t> seg_bar;   // per kept segment, its bar
    for (std::size_t s : segs) {
      const Bar& b = bars.bars[s];
      if (dist3(b.b, pts.back()) < 1e-9) continue;
      pts.push_back(b.b);
      w.push_back(b.width);
      kind.push_back(!bar_is_bridge(b, spec.bridge_rise) ? 0 : spec.weave_round_top ? 1 : 2);
      seg_bar.push_back(s);
    }
    if (pts.size() < 2) continue;
    const Bar::End ea = file_runs[q].end_a, eb = file_runs[q].end_b;
    std::size_t start = 0;
    for (std::size_t k = 1; k <= w.size(); ++k) {
      const bool last = k == w.size();
      const bool turn_split = !last && dot(unit(sub(pts[k], pts[k - 1])), unit(sub(pts[k + 1], pts[k]))) < sharp;
      const bool kind_split = !last && kind[k] != kind[k - 1];
      if (!last && !turn_split && !kind_split) continue;
      // The piece: points start..k, the file's ring widths.
      std::vector<Vec3> pp(pts.begin() + static_cast<std::ptrdiff_t>(start), pts.begin() + static_cast<std::ptrdiff_t>(k) + 1);
      std::vector<double> ring;
      for (std::size_t j = start; j <= k; ++j) ring.push_back(j == start ? w[start] : j == k ? w[k - 1] : std::max(w[j - 1], w[j]));
      const bool swept = kind[start] == 0 && sweep.on;
      double widest = 0.0;   // OS1 A: the piece's own sides, as the file's
      for (std::size_t j = start; j < k; ++j) widest = std::max(widest, w[j]);
      const double k_round = tube_round_factor(tube_sides_for(widest, spec));
      std::vector<Vec3> line = pp;
      std::vector<double> line_ring = ring;
      std::vector<std::size_t> at(pp.size());   // each piece point's place in `line`
      for (std::size_t i = 0; i < pp.size(); ++i) at[i] = i;
      if (swept && pp.size() >= 3) {
        std::vector<double> r;
        for (double x : ring) r.push_back(0.5 * x * k_round);
        std::vector<char> held(pp.size() - 1, 0);
        if (start == 0 && ea == Bar::End::Solid) held.front() = 1;
        if (last && eb == Bar::End::Solid) held.back() = 1;
        const SweptLine sl = sweep_centre_line(pp, r, sweep, &held);
        line = sl.p;
        line_ring.clear();
        for (double x : sl.r) line_ring.push_back(2.0 * x / k_round);
        std::size_t i = 0;
        for (std::size_t m = 0; m < sl.span.size(); ++m)
          if (sl.span[m] < 0) at[i++] = m;
      }
      // OS1 D: the file ends the piece where a mitred ring would fold (a real end: a ball, or a rounded end).
      std::vector<char> fold(line.size(), 0);
      if (spec.weave_fold_split && line.size() >= 3) {
        std::vector<double> corner(line.size());
        for (std::size_t m = 0; m < line.size(); ++m)
          corner[m] = 0.5 * line_ring[m] * (kind[start] == 0 ? k_round : 1.41421356237);
        for (std::size_t m : mitre_fold_splits(line, corner)) fold[m] = 1;
      }
      // Split where the preview's relief marks split a run (the along-face mark and the face, per bar): there the file's
      // tube goes on, so the run's end there is packed "continues" (kEndContinues), never a ball.
      std::size_t a = 0;
      for (std::size_t b = 1; b < pp.size(); ++b) {
        const Bar& here = bars.bars[seg_bar[start + b - 1]];
        const bool end = b + 1 == pp.size();
        if (!end) {
          const Bar& next = bars.bars[seg_bar[start + b]];
          if (marks_of(here, true) == marks_of(next, true) && here.along_face == next.along_face) continue;
        }
        const Bar& first = bars.bars[seg_bar[start + a]];
        WeaveRun r;
        r.region = first.region;
        r.marks = marks_of(first, true);
        r.section = static_cast<std::uint8_t>(kind[start] | (swept ? kSectionSwept : 0));
        const bool run_start = start + a == 0, run_end = last && end;
        r.end_a = run_start ? ea : Bar::End::Node;
        r.end_b = run_end ? eb : Bar::End::Node;
        r.proud_a_mm = run_start && ea == Bar::End::Surface ? first.proud_a : 0.0;
        r.proud_b_mm = run_end && eb == Bar::End::Surface ? here.proud_b : 0.0;
        r.along_face = first.along_face;
        for (std::size_t j = a; j < b; ++j) r.proud_mm = std::max(r.proud_mm, bars.bars[seg_bar[start + j]].along_proud);
        r.continues_a = !run_start && a > 0 && !fold[at[a]];
        r.continues_b = !run_end && !end && !fold[at[b]];
        for (std::size_t m = at[a]; m <= at[b]; ++m) {
          r.points.push_back(line[m]);
          r.ring_mm.push_back(line_ring[m]);
          r.width_mm.push_back(line_ring[m]);
          // the spacing of the bar the point lies on (a piece point: the bar after it, the last the bar before)
          std::size_t j = a;
          while (j + 1 < b && at[j + 1] <= m) ++j;
          r.spacing_mm.push_back(bars.bars[seg_bar[start + j]].cell);
          if (m > at[a] && m < at[b] && fold[m]) {   // OS1 D: ended here (both runs' ends real, Node)
            WeaveRun rest = r;
            rest.points = {line[m]};
            rest.ring_mm = {line_ring[m]};
            rest.width_mm = {line_ring[m]};
            rest.spacing_mm = {r.spacing_mm.back()};
            rest.end_a = Bar::End::Node;
            rest.continues_a = false;
            rest.proud_a_mm = 0.0;
            r.end_b = Bar::End::Node;
            r.continues_b = false;
            r.proud_b_mm = 0.0;
            out.push_back(std::move(r));
            r = std::move(rest);
          }
        }
        if (fold[at[b]] && !end) { r.continues_b = false; }
        out.push_back(std::move(r));
        a = b;
      }
      start = k;
    }
  }
  return out;
}

OrganicPreview lay_organic_preview(Session& session, const Settings& settings, const TensorField& field,
                                   const OrganicAsk& ask, const OrganicPreviewAsk& preview, int threads,
                                   const std::atomic<bool>* stop) {
  try {   // SB1: a stop during the print check answers "cancelled"; nothing non-std leaves
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
  out.runs = ask.sweep.on ? swept_runs(shown, regions, ask.sweep)   // OV1: the file's swept centre lines
                          : weave_runs(shown, regions, preview.tolerance_mm, nullptr, true);   // leg H: the relief marks
  return out;
  } catch (const LayCancelled&) {
    OrganicPreview none;
    none.quality = preview.quality;
    none.outcome.cancelled = true;
    return none;
  } catch (const std::exception&) {
    throw;
  } catch (...) {
    OrganicPreview none;
    none.quality = preview.quality;
    none.outcome.refused.push_back(core_stopped("The Organic preview could not be made"));
    return none;
  }
}

OrganicPreview lay_organic_preview(Session& session, const Settings& settings, const TensorField& field,
                                   const std::vector<OrganicGroup>& groups, const OrganicPreviewAsk& preview,
                                   int threads, const std::atomic<bool>* stop) {
  try {   // SB1: a stop during the print check answers "cancelled"; nothing non-std leaves
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
  // OV1: the sweep is the part's (the first group's ask, as the file job reads the job's own).
  const SweepAsk sweep = groups.empty() ? SweepAsk{} : groups.front().ask.sweep;
  out.runs = sweep.on ? swept_runs(shown, regions, sweep)
                      : weave_runs(shown, regions, preview.tolerance_mm, nullptr, true);   // leg H: the relief marks
  return out;
  } catch (const LayCancelled&) {
    OrganicPreview none;
    none.quality = preview.quality;
    none.outcome.cancelled = true;
    return none;
  } catch (const std::exception&) {
    throw;
  } catch (...) {
    OrganicPreview none;
    none.quality = preview.quality;
    none.outcome.refused.push_back(core_stopped("The Organic preview could not be made"));
    return none;
  }
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
    // OS1 F: version 2 packs a run end that continues the next (or previous) run's tube as kEndContinues.
    const std::uint8_t ea = v2 && r.continues_a ? kEndContinues : static_cast<std::uint8_t>(r.end_a);
    const std::uint8_t eb = v2 && r.continues_b ? kEndContinues : static_cast<std::uint8_t>(r.end_b);
    const std::uint8_t head[4] = {r.marks, ea, eb,
                                  static_cast<std::uint8_t>(v2 ? r.section : 0)};   // leg M: the section (version 2)
    put(&n, 4); put(&region, 4); put(head, 4);
    if (v2) {   // leg H
      const float pa = static_cast<float>(r.proud_a_mm), pb = static_cast<float>(r.proud_b_mm), pm = static_cast<float>(r.proud_mm);
      const std::int32_t face = r.along_face;
      put(&pa, 4); put(&pb, 4); put(&face, 4); put(&pm, 4);
    }
    for (std::size_t k = 0; k < r.points.size(); ++k) {
      const double wk = v2 && r.ring_mm.size() == r.points.size() ? r.ring_mm[k] : r.width_mm[k];   // leg M: the file's ring
      const float v[5] = {static_cast<float>(r.points[k].x), static_cast<float>(r.points[k].y),
                          static_cast<float>(r.points[k].z), static_cast<float>(wk),
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
  try {   // SB1: nothing but a std::exception or a refusal leaves this call
  ready_domain(settings);
  return organic_sweep_limits(*domain_, line_mm, gap_lines);
  } catch (const std::exception&) {
    throw;
  } catch (...) {   // LayCancelled too: no stop is watched here, so it cannot be one asked for
    throw SessionRefused(core_stopped("The Organic size limits could not be measured"));
  }
}

// OP10 (brief C2, E4; E7: per group): the union of the measured regions' limits among `regions`.
SweepLimitsUnion Session::sweep_limits_for(const Settings& settings, const std::vector<int>& regions, double line_mm,
                                           double gap_lines) {
  try {   // SB1: nothing but a std::exception or a refusal leaves this call
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
  } catch (const std::exception&) {
    throw;
  } catch (...) {   // LayCancelled too: no stop is watched here, so it cannot be one asked for
    throw SessionRefused(core_stopped("The Organic size limits could not be measured"));
  }
}

}  // namespace topopt::lattice_layout
