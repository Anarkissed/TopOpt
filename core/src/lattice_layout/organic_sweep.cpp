// Lattice rebuild, Organic: OV1, a vine is a swept curve (sweep_centre_line, lattice_layout.hpp). The one function the
// print file's tubes route (weave_tubes.cpp) and the preview's runs (organic_preview.cpp) both call, so the drawing and
// the file are the same shape. Pure geometry: no domain, no stress.
#include <algorithm>
#include <cmath>
#include <vector>

#include "topopt/lattice_layout.hpp"

namespace topopt::lattice_layout {
namespace {

constexpr double kPi = 3.14159265358979323846;
constexpr int kMostPieces = 64;   // per span (the app's own cap)

Vec3 add(const Vec3& a, const Vec3& b) { return {a.x + b.x, a.y + b.y, a.z + b.z}; }
Vec3 sub(const Vec3& a, const Vec3& b) { return {a.x - b.x, a.y - b.y, a.z - b.z}; }
Vec3 mul(const Vec3& a, double s) { return {a.x * s, a.y * s, a.z * s}; }
double dot(const Vec3& a, const Vec3& b) { return a.x * b.x + a.y * b.y + a.z * b.z; }
double len(const Vec3& a) { return std::sqrt(dot(a, a)); }

// The angle between two directions, radians (0 when either is zero).
double angle(const Vec3& a, const Vec3& b) {
  const double la = len(a), lb = len(b);
  if (!(la > 0.0) || !(lb > 0.0)) return 0.0;
  return std::acos(std::clamp(dot(a, b) / (la * lb), -1.0, 1.0));
}

// The nearest point of bar a-b to q.
Vec3 on_bar(const Vec3& q, const Vec3& a, const Vec3& b) {
  const Vec3 ab = sub(b, a);
  const double l2 = dot(ab, ab);
  const double t = l2 > 0.0 ? std::clamp(dot(sub(q, a), ab) / l2, 0.0, 1.0) : 0.0;
  return add(a, mul(ab, t));
}

// Centripetal Catmull-Rom (alpha 0.5, Barry-Goldman) between p1 and p2 at t in [0, 1].
Vec3 catmull(const Vec3& p0, const Vec3& p1, const Vec3& p2, const Vec3& p3, double t) {
  auto knot = [](double ti, const Vec3& a, const Vec3& b) { return ti + std::max(std::sqrt(len(sub(b, a))), 1e-4); };
  const double t0 = 0.0, t1 = knot(t0, p0, p1), t2 = knot(t1, p1, p2), t3 = knot(t2, p2, p3);
  const double u = t1 + (t2 - t1) * t;
  const Vec3 a1 = add(mul(p0, (t1 - u) / (t1 - t0)), mul(p1, (u - t0) / (t1 - t0)));
  const Vec3 a2 = add(mul(p1, (t2 - u) / (t2 - t1)), mul(p2, (u - t1) / (t2 - t1)));
  const Vec3 a3 = add(mul(p2, (t3 - u) / (t3 - t2)), mul(p3, (u - t2) / (t3 - t2)));
  const Vec3 b1 = add(mul(a1, (t2 - u) / (t2 - t0)), mul(a2, (u - t0) / (t2 - t0)));
  const Vec3 b2 = add(mul(a2, (t3 - u) / (t3 - t1)), mul(a3, (u - t1) / (t3 - t1)));
  return add(mul(b1, (t2 - u) / (t2 - t1)), mul(b2, (u - t1) / (t2 - t1)));
}

}  // namespace

SweptLine sweep_centre_line(const std::vector<Vec3>& p, const std::vector<double>& r, const SweepAsk& ask,
                            const std::vector<char>* straight) {
  SweptLine out;
  const std::size_t n = p.size();
  out.spans = n >= 2 ? n - 1 : 0;
  auto as_given = [&] {
    out.p = p;
    out.r = r;
    out.span.assign(n, -1);
    return out;
  };
  if (!ask.on || n < 3 || r.size() != n) return as_given();
  const std::size_t m_spans = n - 1;
  const double min_turn = ask.min_turn_deg * kPi / 180.0, max_turn = std::max(1e-3, ask.max_turn_deg * kPi / 180.0);
  auto held = [&](std::size_t j) { return straight && j < straight->size() && (*straight)[j]; };
  // Which inner points the curve passes through (false: a mitre). Ends are never curved through.
  std::vector<char> curve(n, 0);
  for (std::size_t i = 1; i + 1 < n; ++i) {
    const double th = angle(sub(p[i], p[i - 1]), sub(p[i + 1], p[i]));
    if (th < min_turn) { ++out.mitre_small_turn; continue; }
    if (held(i - 1) || held(i)) { ++out.mitre_straight_end; continue; }
    curve[i] = 1;
  }
  // Per span: its pieces (m) and its samples (m - 1 of them, pulled).
  std::vector<int> pieces(m_spans, 1);
  std::vector<std::vector<Vec3>> samples(m_spans);
  auto span_curved = [&](std::size_t j) { return curve[j] || curve[j + 1]; };
  auto make_span = [&](std::size_t j) {
    samples[j].clear();
    if (!span_curved(j) || pieces[j] < 2) return;
    const Vec3 &p1 = p[j], &p2 = p[j + 1];
    const Vec3 p0 = curve[j] ? p[j - 1] : sub(mul(p1, 2.0), p2);
    const Vec3 p3 = curve[j + 1] ? p[j + 2] : sub(mul(p2, 2.0), p1);
    double worst = 0.0;
    for (int k = 1; k < pieces[j]; ++k) {
      const Vec3 q = catmull(p0, p1, p2, p3, static_cast<double>(k) / pieces[j]);
      worst = std::max(worst, len(sub(q, on_bar(q, p1, p2))));
      samples[j].push_back(q);
    }
    if (worst > ask.max_offset_mm && worst > 0.0) {   // one factor for the whole span
      const double f = ask.max_offset_mm / worst;
      for (Vec3& q : samples[j]) {
        const Vec3 c = on_bar(q, p1, p2);
        q = add(c, mul(sub(q, c), f));
      }
    }
  };
  // First count of pieces: the span's length over max_piece_mm and its own turning (read off 32 trial pieces).
  auto first_count = [&](std::size_t j) {
    if (!span_curved(j)) return 1;
    const Vec3 &p1 = p[j], &p2 = p[j + 1];
    const Vec3 p0 = curve[j] ? p[j - 1] : sub(mul(p1, 2.0), p2);
    const Vec3 p3 = curve[j + 1] ? p[j + 2] : sub(mul(p2, 2.0), p1);
    double turn = 0.0;
    Vec3 prev = p1, prev_d{0, 0, 0};
    for (int k = 1; k <= 32; ++k) {
      const Vec3 q = k == 32 ? p2 : catmull(p0, p1, p2, p3, k / 32.0);
      const Vec3 d = sub(q, prev);
      if (k > 1) turn += angle(prev_d, d);
      prev = q;
      prev_d = d;
    }
    const int by_len = static_cast<int>(std::ceil(len(sub(p2, p1)) / std::max(1e-3, ask.max_piece_mm)));
    const int by_turn = static_cast<int>(std::ceil(turn / max_turn));
    return std::clamp(std::max({2, by_len, by_turn}), 2, kMostPieces);
  };
  // The assembled line, each point's span (-1 a piece point) and radius.
  auto assemble = [&] {
    out.p.clear();
    out.r.clear();
    out.span.clear();
    for (std::size_t j = 0; j < m_spans; ++j) {
      out.p.push_back(p[j]);
      out.r.push_back(r[j]);
      out.span.push_back(-1);
      const int m = static_cast<int>(samples[j].size()) + 1;
      for (int k = 1; k < m; ++k) {
        out.p.push_back(samples[j][static_cast<std::size_t>(k - 1)]);
        out.r.push_back(r[j] + (r[j + 1] - r[j]) * static_cast<double>(k) / m);
        out.span.push_back(static_cast<int>(j));
      }
    }
    out.p.push_back(p[n - 1]);
    out.r.push_back(r[n - 1]);
    out.span.push_back(-1);
  };
  // The piece point (index in p) each assembled point belongs to on its left: for mapping a check back to spans.
  for (std::size_t j = 0; j < m_spans; ++j) {
    pieces[j] = first_count(j);
    make_span(j);
  }
  for (int pass = 0; pass < 2 * static_cast<int>(n) + 8; ++pass) {
    assemble();
    // Every point of the line: its turn and the curve's radius there. A tight one makes its span's curved ends mitres;
    // one turning more than max_turn (not a mitre) gets its spans more pieces.
    std::vector<char> tighten(n, 0);
    std::vector<char> more(m_spans, 0);
    bool changed = false;
    std::size_t piece_at = 0;   // the index in p of the last piece point passed
    for (std::size_t k = 0; k < out.p.size(); ++k) {
      if (out.span[k] < 0) piece_at = (k == 0) ? 0 : piece_at + (k > 0 ? 1 : 0);
      if (k == 0 || k + 1 == out.p.size()) continue;
      const bool is_piece = out.span[k] < 0;
      const std::size_t i = piece_at;   // when is_piece: this point is p[i]
      if (is_piece && !curve[i]) continue;   // a mitre: any turn allowed (the rule keeps it a corner)
      const Vec3 din = sub(out.p[k], out.p[k - 1]), dout = sub(out.p[k + 1], out.p[k]);
      const double th = angle(din, dout);
      if (!(th > 1e-9)) continue;
      const double rad = 0.5 * (len(din) + len(dout)) / th;
      const std::size_t left = is_piece ? i - 1 : static_cast<std::size_t>(out.span[k]);
      const std::size_t right = is_piece ? i : static_cast<std::size_t>(out.span[k]);
      if (rad < ask.min_radius * out.r[k]) {
        if (curve[left]) tighten[left] = 1;
        if (left + 1 < n && curve[left + 1]) tighten[left + 1] = 1;
        if (curve[right]) tighten[right] = 1;
        if (right + 1 < n && curve[right + 1]) tighten[right + 1] = 1;
      } else if (th > max_turn * (1.0 + 1e-9)) {
        more[left] = 1;
        more[right] = 1;
      }
    }
    for (std::size_t i = 1; i + 1 < n; ++i)
      if (tighten[i] && curve[i]) {
        curve[i] = 0;
        ++out.mitre_tight;
        out.tight_at.push_back(p[i]);
        changed = true;
      }
    if (changed) {
      for (std::size_t j = 0; j < m_spans; ++j) {
        pieces[j] = first_count(j);
        make_span(j);
      }
      continue;
    }
    bool grew = false;
    for (std::size_t j = 0; j < m_spans; ++j)
      if (more[j] && span_curved(j) && pieces[j] < kMostPieces) {
        pieces[j] = std::min(kMostPieces, pieces[j] * 2);
        make_span(j);
        grew = true;
      }
    if (!grew) break;
  }
  assemble();
  for (std::size_t j = 0; j < m_spans; ++j) {
    if (!samples[j].empty()) ++out.spans_curved;
    for (const Vec3& q : samples[j]) out.largest_offset_mm = std::max(out.largest_offset_mm, len(sub(q, on_bar(q, p[j], p[j + 1]))));
  }
  return out;
}

}  // namespace topopt::lattice_layout
