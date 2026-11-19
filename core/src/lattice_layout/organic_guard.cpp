// Rule OG5 (brief E9; the owner, 2026-11-19, on vine bits showing through his bottom protected face: "That CAN'T
// happen"): no Organic bar outside the part or through protected solid. Declared in lattice_layout_organic.hpp.
#include <algorithm>
#include <array>
#include <cmath>
#include <map>
#include <vector>

#include "topopt/lattice_layout_organic.hpp"

namespace topopt::lattice_layout {
namespace {

double dist3(const Vec3& a, const Vec3& b) { return std::sqrt((a.x - b.x) * (a.x - b.x) + (a.y - b.y) * (a.y - b.y) + (a.z - b.z) * (a.z - b.z)); }
Vec3 at_t(const Vec3& a, const Vec3& d, double t) { return {a.x + d.x * t, a.y + d.y * t, a.z + d.z * t}; }

// 'L' lattice (of any region), 'O' outside the part, 'S' any solid (protected skin, kept solid, rim, cover, ...).
char cls(const Domain::Probe& probe, const Vec3& p) {
  const Where w = probe.where(p);
  if (w.lattice()) return 'L';
  return w.why == Why::Outside ? 'O' : 'S';
}

struct Span { double t0, t1; char c; };

}  // namespace

double solid_run_on(const Domain::Probe& probe, const Vec3& entry, const Vec3& dir, double width, double line_mm) {
  // Rule 2: min(its width, the solid's thickness along the bar there less its radius less a line width), never under 0.
  const double r = 0.5 * width;
  double th = 0.0;
  while (th < 50.0 && cls(probe, at_t(entry, dir, th + 0.02)) == 'S') th += 0.02;
  const double most = std::max(0.0, std::min(width, th - r - line_mm));
  // Rule 3: in a Protect skin, its tube also stays a line width inside the part's surface (a bar entering a skin
  // slantwise would otherwise come nearer the protected face than the thickness along it tells).
  double t = 0.0;
  while (t + 0.02 <= most + 1e-12) {
    const Vec3 q = at_t(entry, dir, t + 0.02);
    if (probe.where(q).why == Why::ProtectSkin && probe.part().depth(q) < r + line_mm) break;
    t += 0.02;
  }
  return t < most - 0.02 ? t : most;
}

std::size_t guard_bars(Bars& bars, const Domain& domain, const std::vector<int>& weave_regions, double line_mm,
                       GuardReport* report, bool drop_cut_free) {
  GuardReport rep;
  const Domain::Probe probe = domain.probe();
  const double step = 0.1, tol = 1e-3;
  constexpr double kShortest = 0.05;   // mm: a piece shorter than this is not kept
  const std::size_t n0 = bars.bars.size();
  std::vector<char> keep(n0, 1);
  std::vector<Bar> extra;
  auto weave = [&](const Bar& b) {
    return b.net || b.support || std::find(weave_regions.begin(), weave_regions.end(), b.region) != weave_regions.end();
  };
  // (0) A joint or landing a hair outside the part (within 1.5 mm): moved in, toward the mean of its bars' other ends,
  // just past where the part begins; every bar ending there moved with it, so a joint stays one joint.
  {
    std::map<std::array<double, 3>, std::vector<std::pair<std::size_t, int>>> ends;
    for (std::size_t i = 0; i < n0; ++i) {
      const Bar& b = bars.bars[i];
      if (!weave(b)) continue;
      if (!(b.relief_a > 0.0)) ends[{b.a.x, b.a.y, b.a.z}].push_back({i, 0});
      if (!(b.relief_b > 0.0)) ends[{b.b.x, b.b.y, b.b.z}].push_back({i, 1});
    }
    for (const auto& [key, users] : ends) {
      const Vec3 p{key[0], key[1], key[2]};
      if (cls(probe, p) != 'O') continue;
      Vec3 m{0.0, 0.0, 0.0};
      for (const auto& [i, e] : users) {
        const Bar& b = bars.bars[i];
        const Vec3& q = e ? b.a : b.b;
        const double l = dist3(p, q);
        if (l > 0.0) m = {m.x + (q.x - p.x) / l, m.y + (q.y - p.y) / l, m.z + (q.z - p.z) / l};
      }
      const double ml = std::sqrt(m.x * m.x + m.y * m.y + m.z * m.z);
      if (!(ml > 1e-9)) continue;
      m = {m.x / ml, m.y / ml, m.z / ml};
      double in = -1.0;
      for (double t = 0.02; t <= 1.5; t += 0.02)
        if (cls(probe, at_t(p, m, t)) != 'O') { in = t; break; }
      if (in < 0.0) continue;
      double lo = in - 0.02, hi = in;
      for (int it = 0; it < 12; ++it) {
        const double mid = 0.5 * (lo + hi);
        (cls(probe, at_t(p, m, mid)) == 'O' ? lo : hi) = mid;
      }
      const Vec3 q = at_t(p, m, hi + tol);
      for (const auto& [i, e] : users) (e ? bars.bars[i].b : bars.bars[i].a) = q;
      ++rep.ends_moved_in;
    }
  }
  auto note = [&](std::vector<Vec3>& at, const Bar& b) {
    if (at.size() < 20) at.push_back({0.5 * (b.a.x + b.b.x), 0.5 * (b.a.y + b.b.y), 0.5 * (b.a.z + b.b.z)});
  };
  for (std::size_t i = 0; i < n0; ++i) {
    const Bar& bar = bars.bars[i];
    if (!weave(bar)) continue;
    const double L = dist3(bar.a, bar.b);
    if (!(L > 0.0)) continue;
    const Vec3 d{(bar.b.x - bar.a.x) / L, (bar.b.y - bar.a.y) / L, (bar.b.z - bar.a.z) / L};
    // OG2 / OG2b: the relief carried past an open face is not judged here.
    const double t_lo = std::min(bar.relief_a, L), t_hi = std::max(t_lo, L - bar.relief_b);
    // The spans of the centre line by what it lies in, the changes found to 1/256 of a step.
    std::vector<Span> spans;
    const int ns = std::max(2, static_cast<int>(std::ceil((t_hi - t_lo) / step)));
    char prev = cls(probe, at_t(bar.a, d, t_lo));
    double start = t_lo, tprev = t_lo;
    for (int k = 1; k <= ns; ++k) {
      const double t = t_lo + (t_hi - t_lo) * k / ns;
      const char c = cls(probe, at_t(bar.a, d, t));
      if (c != prev) {
        double lo = tprev, hi = t;
        for (int it = 0; it < 8; ++it) {
          const double m = 0.5 * (lo + hi);
          (cls(probe, at_t(bar.a, d, m)) == prev ? lo : hi) = m;
        }
        spans.push_back({start, lo, prev});
        start = lo;
        prev = c;
      }
      tprev = t;
    }
    spans.push_back({start, t_hi, prev});
    bool any_bad = false;
    for (const Span& s : spans) any_bad = any_bad || s.c != 'L';
    if (!any_bad) continue;
    // How far past an entry into solid at `t` (going `dir`) the bar may run on: min(width, the solid's thickness along
    // the bar minus its radius minus one line width), never under 0.
    const double r = 0.5 * bar.width;
    (void)r;
    auto run_on = [&](double t, double dir) {
      return solid_run_on(probe, at_t(bar.a, d, t), Vec3{d.x * dir, d.y * dir, d.z * dir}, bar.width, line_mm);
    };
    // The kept pieces: the lattice spans, each carried on into a solid span beside it by run_on (cut short by the span).
    struct Piece { double t0, t1; bool ext0, ext1; };   // ext: that end was moved off where it was
    std::vector<Piece> pieces;
    bool outside = false, in_solid = false;
    for (std::size_t k = 0; k < spans.size(); ++k) {
      if (spans[k].c == 'O') outside = true;
      if (spans[k].c == 'S') in_solid = true;
      if (spans[k].c != 'L') continue;
      Piece p{spans[k].t0, spans[k].t1, false, false};
      if (k > 0 && spans[k - 1].c == 'S') {
        const double ro = std::min(run_on(spans[k].t0, -1.0), spans[k].t0 - spans[k - 1].t0);
        p.t0 = spans[k].t0 - ro;
      } else if (k > 0) {   // outside before it: stop just inside the part
        p.t0 = spans[k].t0 + tol;
      }
      if (k + 1 < spans.size() && spans[k + 1].c == 'S') {
        const double ro = std::min(run_on(spans[k].t1, 1.0), spans[k + 1].t1 - spans[k].t1);
        p.t1 = spans[k].t1 + ro;
      } else if (k + 1 < spans.size()) {
        p.t1 = spans[k].t1 - tol;
      }
      if (k == 0 && t_lo > 0.0) p.t0 = 0.0;              // the relief stays on
      if (k + 1 == spans.size() && t_hi < L) p.t1 = L;
      p.ext0 = p.t0 > 1e-9;
      p.ext1 = p.t1 < L - 1e-9;
      if (p.t1 - p.t0 >= kShortest) pieces.push_back(p);   // a sliver of a bar is no bar
    }
    // Unchanged when the one piece is the whole bar (a run-on within the rule).
    if (pieces.size() == 1 && !pieces[0].ext0 && !pieces[0].ext1) continue;
    const std::string kind = bar.net ? "net" : bar.support ? "support" : bar.link ? "link" : bar.level_tie ? "tie" : bar.brace ? "brace" : "strand";
    if (pieces.empty()) {
      keep[i] = 0;
      ++rep.in_solid_removed;
      ++rep.by_kind[kind];
      note(rep.removed_at, bar);
      continue;
    }
    if (outside) { ++rep.outside_cut; note(rep.outside_at, bar); }
    else if (in_solid) { ++rep.in_solid_cut; note(rep.in_solid_at, bar); }
    ++rep.by_kind[kind];
    const Bar orig = bar;
    auto make = [&](const Piece& p) {
      Bar x = orig;
      x.a = at_t(orig.a, d, p.t0);
      x.b = at_t(orig.a, d, p.t1);
      if (p.ext0) {
        x.end_a = cls(probe, x.a) == 'S' ? Bar::End::Solid : Bar::End::Surface;
        x.into_a = -1;
        x.relief_a = x.proud_a = 0.0;
      }
      if (p.ext1) {
        x.end_b = cls(probe, x.b) == 'S' ? Bar::End::Solid : Bar::End::Surface;
        x.into_b = -1;
        x.relief_b = x.proud_b = 0.0;
      }
      return x;
    };
    // After additions: a piece left with a free end by the cut (a new end in no solid) is not kept.
    std::vector<Bar> made;
    for (const Piece& p : pieces) {
      Bar x = make(p);
      const bool free_end = (p.ext0 && x.end_a == Bar::End::Surface) || (p.ext1 && x.end_b == Bar::End::Surface);
      if (drop_cut_free && free_end) { ++rep.cut_dropped; continue; }
      made.push_back(x);
    }
    if (made.empty()) { keep[i] = 0; continue; }
    bars.bars[i] = made[0];
    for (std::size_t k = 1; k < made.size(); ++k) extra.push_back(made[k]);
  }
  // A bar removed whole leaves its neighbours ending where it began: an end of theirs at that point, in solid, is now an
  // end in the solid (Solid), not a joint left alone (which the drop would eat back).
  if (std::find(keep.begin(), keep.end(), 0) != keep.end()) {
    std::map<std::array<double, 3>, char> gone_ends;
    for (std::size_t i = 0; i < n0; ++i)
      if (!keep[i]) {
        const Bar& b = bars.bars[i];
        for (const Vec3& p : {b.a, b.b})
          if (cls(probe, p) == 'S') gone_ends[{p.x, p.y, p.z}] = 1;
      }
    for (std::size_t i = 0; i < n0; ++i) {
      if (!keep[i]) continue;
      Bar& b = bars.bars[i];
      if (b.end_a == Bar::End::Node && gone_ends.count({b.a.x, b.a.y, b.a.z})) { b.end_a = Bar::End::Solid; b.into_a = -1; }
      if (b.end_b == Bar::End::Node && gone_ends.count({b.b.x, b.b.y, b.b.z})) { b.end_b = Bar::End::Solid; b.into_b = -1; }
    }
  }
  // Removed bars out, with every Joined end that pointed at a bar moved to its new place (or nowhere).
  std::size_t removed = 0;
  bool any_removed = false;
  for (char k : keep) any_removed = any_removed || !k;
  if (any_removed || !extra.empty()) {
    std::vector<int> now(n0, -1);
    std::vector<Bar> out;
    out.reserve(n0 + extra.size());
    for (std::size_t i = 0; i < n0; ++i)
      if (keep[i]) { now[i] = static_cast<int>(out.size()); out.push_back(bars.bars[i]); }
      else ++removed;
    for (Bar& x : extra) out.push_back(x);
    for (Bar& b : out) {
      if (b.into_a >= 0) b.into_a = b.into_a < static_cast<int>(n0) ? now[static_cast<std::size_t>(b.into_a)] : -1;
      if (b.into_b >= 0) b.into_b = b.into_b < static_cast<int>(n0) ? now[static_cast<std::size_t>(b.into_b)] : -1;
    }
    bars.bars = std::move(out);
  }
  if (report) {
    report->outside_cut += rep.outside_cut;
    report->in_solid_cut += rep.in_solid_cut;
    report->in_solid_removed += rep.in_solid_removed;
    report->ends_moved_in += rep.ends_moved_in;
    report->cut_dropped += rep.cut_dropped;
    for (const auto& [k, v] : rep.by_kind) report->by_kind[k] += v;
    for (const Vec3& p : rep.outside_at) if (report->outside_at.size() < 20) report->outside_at.push_back(p);
    for (const Vec3& p : rep.in_solid_at) if (report->in_solid_at.size() < 20) report->in_solid_at.push_back(p);
    for (const Vec3& p : rep.removed_at) if (report->removed_at.size() < 20) report->removed_at.push_back(p);
  }
  return rep.outside_cut + rep.in_solid_cut + rep.in_solid_removed + rep.ends_moved_in + rep.cut_dropped;
}

}  // namespace topopt::lattice_layout
